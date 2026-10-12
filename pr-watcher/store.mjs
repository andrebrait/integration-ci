// pr-watcher's persistent watches and delivery state: one SQLite database in
// the data directory, shared by the service and the CLI.
import { mkdirSync, readFileSync, renameSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

const FINISHED = new Set(["MERGED", "CLOSED"]);
const SESSION = /^[A-Za-z0-9_-]{1,80}$/;
const LOGIN = /^[A-Za-z0-9-]{1,39}(\[bot\])?$/;

/** "owner/repo#123" → parts, or null. */
export function parsePr(ref) {
  const m = /^([\w.-]+)\/([\w.-]+)#(\d+)$/.exec(ref ?? "");
  return m ? { owner: m[1], name: m[2], number: Number(m[3]) } : null;
}
export const isSession = (value) => typeof value === "string" && SESSION.test(value);
export const isLogin = (value) => typeof value === "string" && LOGIN.test(value);

export function dataDir(env = process.env) {
  return env.PR_WATCHER_DATA_DIR || join(env.XDG_STATE_HOME || join(homedir(), ".local/state"), "pr-watcher");
}

const readLegacy = (file) => {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return undefined;
    throw new Error(`cannot import ${file}: ${error.message}`);
  }
};

const parseJson = (text) => {
  try {
    return text == null ? undefined : JSON.parse(text);
  } catch {
    return undefined;
  }
};

/** Imports the pre-SQLite config.json watches and state.json snapshots. Runs inside the schema transaction. */
function importLegacy(db, legacy) {
  const config = readLegacy(legacy.config);
  const state = readLegacy(legacy.state) ?? {};
  if (!config) return false;
  const defaults = { ompwebUrl: ["http://127.0.0.1:30185", "PR_WATCHER_OMPWEB_URL"], intervalSeconds: [60, "PR_WATCHER_INTERVAL_SECONDS"] };
  for (const [key, [value, env]] of Object.entries(defaults)) {
    if (config[key] !== undefined && config[key] !== value) console.log(`config.json ${key}=${config[key]} is no longer read; set ${env}`);
  }
  if (config.ignoreAuthors?.length) console.log(`config.json ignoreAuthors is no longer read; set PR_WATCHER_IGNORE_AUTHORS=${config.ignoreAuthors.join(",")}`);
  const insert = db.prepare("INSERT OR IGNORE INTO watches (pr, session, ignore_authors, snapshot, added_at) VALUES (?, ?, ?, ?, ?)");
  for (const watch of config.watches ?? []) {
    if (!parsePr(watch?.pr) || !isSession(watch.session)) continue;
    const snapshot = state[`${watch.pr}->${watch.session}`];
    if (FINISHED.has(snapshot?.state)) continue;
    const ignore = (watch.ignoreAuthors ?? []).filter(isLogin);
    insert.run(watch.pr, watch.session, JSON.stringify(ignore), snapshot ? JSON.stringify(snapshot) : null, Date.now());
  }
  return true;
}

/**
 * Opens (creating if needed) the store in `dir`. The first open imports the
 * legacy files, then renames them to `*.migrated` for rollback.
 */
export function openStore(dir, legacy = {
  config: process.env.PR_WATCHER_CONFIG || join(homedir(), ".config/pr-watcher/config.json"),
  state: process.env.PR_WATCHER_STATE || join(dir, "state.json"),
}) {
  mkdirSync(dir, { recursive: true });
  const db = new DatabaseSync(join(dir, "pr-watcher.db"));
  db.exec("PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL;");
  if (db.prepare("PRAGMA user_version").get().user_version === 0) {
    db.exec("BEGIN IMMEDIATE");
    let imported = false;
    try {
      // Re-checked under the write lock: another process may have migrated meanwhile.
      if (db.prepare("PRAGMA user_version").get().user_version === 0) {
        db.exec(`CREATE TABLE watches (
          pr TEXT NOT NULL,
          session TEXT NOT NULL,
          ignore_authors TEXT NOT NULL,
          snapshot TEXT,
          added_at INTEGER NOT NULL,
          PRIMARY KEY (pr, session)
        ); PRAGMA user_version = 1;`);
        imported = importLegacy(db, legacy);
      }
      db.exec("COMMIT");
    } catch (error) {
      db.exec("ROLLBACK");
      db.close();
      throw error;
    }
    if (imported) {
      for (const file of [legacy.config, legacy.state]) {
        try {
          renameSync(file, `${file}.migrated`);
        } catch (error) {
          if (error.code !== "ENOENT") throw error;
        }
      }
    }
  }
  const select = db.prepare("SELECT pr, session, ignore_authors, snapshot, added_at FROM watches ORDER BY added_at, pr, session");
  const upsert = db.prepare(`INSERT INTO watches (pr, session, ignore_authors, snapshot, added_at) VALUES (?, ?, ?, NULL, ?)
    ON CONFLICT (pr, session) DO UPDATE SET ignore_authors = excluded.ignore_authors`);
  const removeOne = db.prepare("DELETE FROM watches WHERE pr = ? AND session = ?");
  const removeAll = db.prepare("DELETE FROM watches WHERE pr = ?");
  const update = db.prepare("UPDATE watches SET snapshot = ? WHERE pr = ? AND session = ?");
  return {
    list: () => select.all().map((row) => ({
      pr: row.pr,
      session: row.session,
      ignoreAuthors: parseJson(row.ignore_authors) ?? [],
      snapshot: parseJson(row.snapshot),
      addedAt: row.added_at,
    })),
    add: (pr, session, ignoreAuthors) => void upsert.run(pr, session, JSON.stringify(ignoreAuthors), Date.now()),
    remove: (pr, session) => Number((session === undefined ? removeAll.run(pr) : removeOne.run(pr, session)).changes),
    saveSnapshot: (pr, session, snapshot) => Number(update.run(JSON.stringify(snapshot), pr, session).changes) > 0,
    close: () => db.close(),
  };
}
