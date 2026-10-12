#!/usr/bin/env node
// Polls GitHub pull requests and notifies the omp session mapped to each one
// through omp-web's agent API. Watches live in the store (see store.mjs).
import { execFile } from "node:child_process";
import { realpathSync } from "node:fs";
import { promisify, parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import { dataDir, isLogin, isSession, openStore, parsePr } from "./store.mjs";

export { parsePr };

const run = promisify(execFile);
const TERMINAL_CI = new Set(["SUCCESS", "FAILURE", "ERROR"]);
const FINISHED = new Set(["MERGED", "CLOSED"]);

const QUERY = `query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){
  state title
  comments(last:50){nodes{id author{login} body url}}
  reviews(last:50){nodes{id author{login} state body url}}
  commits(last:1){nodes{commit{oid statusCheckRollup{state}}}}}}}`;

const log = (...args) => console.log(new Date().toISOString(), ...args);

async function fetchPr({ owner, name, number }) {
  const { stdout } = await run("gh", ["api", "graphql", "-f", `query=${QUERY}`, "-f", `owner=${owner}`, "-f", `name=${name}`, "-F", `number=${number}`]);
  const pr = JSON.parse(stdout).data.repository.pullRequest;
  const commit = pr.commits.nodes[0]?.commit;
  const item = kind => n => ({ kind, id: n.id, author: n.author?.login ?? "ghost", state: n.state, body: n.body, url: n.url });
  return {
    state: pr.state,
    title: pr.title,
    head: commit?.oid ?? "",
    ci: commit?.statusCheckRollup?.state ?? "NONE",
    items: [...pr.comments.nodes.map(item("comment")), ...pr.reviews.nodes.filter(n => n.state !== "PENDING").map(item("review"))],
  };
}

const excerpt = text => {
  const flat = (text ?? "").replace(/\s+/g, " ").trim();
  return flat.length > 300 ? `${flat.slice(0, 300)}…` : flat;
};

/**
 * Compares a PR snapshot with the last delivered state. `prev` undefined means
 * the watch is new: record a baseline and report nothing.
 */
export function diffPr(prev, snap, ignore) {
  // `ciReported` is the last delivered "<head>:<result>". A rerun on the same head
  // (e.g. after a base change) passes through PENDING, which must not make the
  // same result count as news again.
  const ciNow = TERMINAL_CI.has(snap.ci) ? `${snap.head}:${snap.ci}` : undefined;
  const ciReported = prev?.ciReported ?? (TERMINAL_CI.has(prev?.ci) ? `${prev.head}:${prev.ci}` : undefined);
  const next = { seen: snap.items.map(i => i.id), head: snap.head, ci: snap.ci, ciReported: ciNow ?? ciReported, state: snap.state };
  if (!prev) return { events: [], next };
  const seen = new Set(prev.seen);
  const events = [];
  for (const i of snap.items) {
    if (seen.has(i.id) || ignore.has(i.author)) continue;
    const what = i.kind === "review" ? `${i.author} reviewed (${i.state})` : `${i.author} commented`;
    const body = excerpt(i.body) || "(inline comments only)";
    events.push(`- ${what}: ${body} ${i.url}`);
  }
  if (snap.state !== prev.state) events.push(`- PR is now ${snap.state}`);
  if (ciNow && ciNow !== ciReported) events.push(`- CI ${snap.ci} on ${snap.head.slice(0, 10)}`);
  return { events, next };
}

export function formatMessage(ref, title, events) {
  const { owner, name, number } = parsePr(ref);
  // Never starts with "/": omp would treat it as a slash command.
  return [`PR update (pr-watcher): ${ref} "${title}"`, ...events, `Details: pr://${owner}/${name}/${number}`].join("\n");
}

class OmpWeb {
  #url;
  constructor(url) {
    this.#url = url.replace(/\/$/, "");
  }
  async #request(path, body) {
    const headers = { "content-type": "application/json" };
    // omp-web only holds this secret's SHA-256 (OMP_WEB_TRUSTED_HEADER_SHA256).
    const secret = process.env.OMP_WEB_TRUSTED_HEADER_SECRET;
    if (secret) headers["x-omp-web-auth"] = secret;
    const res = await fetch(`${this.#url}${path}`, {
      method: body ? "POST" : "GET",
      headers,
      body: body && JSON.stringify(body),
    });
    const json = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(`omp-web ${path}: HTTP ${res.status} ${json.error ?? ""}`.trim());
    return json;
  }
  /** Returns false when the session can't take a prompt right now (retry next cycle). */
  async notify(session, message) {
    const path = `/api/agent/${encodeURIComponent(session)}`;
    const { running, state } = await this.#request(path);
    if (running && (state?.isBashRunning || state?.isCompacting)) return false;
    // A plain prompt on a busy session fails and resets omp-web's run tracking,
    // so a busy session gets a follow-up; an idle or stopped one starts a turn.
    const busy = running && (state?.isStreaming || state?.isPromptRunning);
    await this.#request(path, { type: "prompt", message, ...(busy ? { streamingBehavior: "followUp" } : {}) });
    return true;
  }
}

/** Service settings, read once at start. */
export function settings(env = process.env) {
  const interval = Number(env.PR_WATCHER_INTERVAL_SECONDS);
  return {
    ompwebUrl: env.PR_WATCHER_OMPWEB_URL || "http://127.0.0.1:30185",
    intervalSeconds: Number.isInteger(interval) && interval > 0 ? interval : 60,
    ignoreAuthors: (env.PR_WATCHER_IGNORE_AUTHORS ?? "").split(",").map((login) => login.trim()).filter(Boolean),
  };
}

/** One poll of every watch. Deliveries are recorded only after omp-web accepts them, so failures retry. */
export async function cycle(store, { fetchPr, notify, self, ignoreAuthors }) {
  for (const watch of store.list()) {
    const key = `${watch.pr}->${watch.session}`;
    try {
      const snap = await fetchPr(parsePr(watch.pr));
      const ignore = new Set([self, ...ignoreAuthors, ...watch.ignoreAuthors]);
      const { events, next } = diffPr(watch.snapshot, snap, ignore);
      if (events.length && !(await notify(watch.session, formatMessage(watch.pr, snap.title, events)))) {
        log(`${key}: session busy with a shell command or compaction, retrying next cycle`);
        continue;
      }
      if (events.length) log(`${key}: delivered ${events.length} event(s)`);
      // A watch removed meanwhile matches no row and stays removed.
      if (!store.saveSnapshot(watch.pr, watch.session, next)) continue;
      // Merged or closed: the final notice is out (or the watch began after it), so the watch ends.
      if (FINISHED.has(next.state)) {
        store.remove(watch.pr, watch.session);
        log(`${key}: PR ${next.state.toLowerCase()}, watch ended`);
      }
    } catch (error) {
      log(`${key}: ${error.message}`);
    }
  }
}

async function serve(once) {
  const config = settings();
  const store = openStore(dataDir());
  const ompweb = new OmpWeb(config.ompwebUrl);
  const self = (await run("gh", ["api", "user", "-q", ".login"])).stdout.trim();
  const deps = { fetchPr, notify: (session, message) => ompweb.notify(session, message), self, ignoreAuthors: config.ignoreAuthors };
  if (once) return void (await cycle(store, deps));
  log(`polling every ${config.intervalSeconds}s from ${dataDir()} as ${self}`);
  for (;;) {
    await cycle(store, deps);
    await new Promise((resolve) => setTimeout(resolve, config.intervalSeconds * 1000));
  }
}

const USAGE = `usage: pr-watcher [--once]
       pr-watcher add OWNER/REPO#N --session ID [--ignore-author LOGIN]...
       pr-watcher remove OWNER/REPO#N [--session ID]
       pr-watcher list [--json]`;

/** Watch management. Returns the exit status: 0 ok, 2 invalid input (nothing written). */
export function cli(argv, { store, out, err }) {
  let parsed;
  try {
    parsed = parseArgs({ args: argv, allowPositionals: true, options: { session: { type: "string" }, "ignore-author": { type: "string", multiple: true }, json: { type: "boolean" } } });
  } catch (error) {
    err(`${error.message}\n${USAGE}`);
    return 2;
  }
  const { positionals: [command, pr, ...extra], values } = parsed;
  const invalid = (message) => (err(`${message}\n${USAGE}`), 2);
  if (command === "list") {
    if (pr !== undefined) return invalid(`unexpected argument ${pr}`);
    const watches = store.list();
    if (values.json) out(JSON.stringify(watches));
    else for (const w of watches) out([w.pr, w.session, w.ignoreAuthors.length ? `ignore=${w.ignoreAuthors.join(",")}` : "-", w.snapshot?.state ?? "new"].join("  "));
    return 0;
  }
  if (command !== "add" && command !== "remove") return invalid(command ? `unknown command ${command}` : "missing command");
  if (!parsePr(pr) || extra.length) return invalid(`expected one OWNER/REPO#N, got ${[pr, ...extra].join(" ") || "nothing"}`);
  if (values.session !== undefined && !isSession(values.session)) return invalid(`invalid session id ${values.session}`);
  if (command === "remove") {
    const removed = store.remove(pr, values.session);
    out(removed ? `removed ${removed} watch${removed === 1 ? "" : "es"}` : "no matching watch");
    return 0;
  }
  if (values.session === undefined) return invalid("add needs --session");
  const ignore = values["ignore-author"] ?? [];
  const badLogin = ignore.find((login) => !isLogin(login));
  if (badLogin !== undefined) return invalid(`invalid login ${badLogin}`);
  store.add(pr, values.session, ignore);
  out(`watching ${pr} for ${values.session}`);
  return 0;
}

async function main(argv) {
  if (argv.length === 0 || (argv.length === 1 && argv[0] === "--once")) return serve(argv[0] === "--once");
  try {
    process.exitCode = cli(argv, { store: openStore(dataDir()), out: console.log, err: console.error });
  } catch (error) {
    console.error(`pr-watcher: ${error.message}`);
    process.exitCode = 1;
  }
}

// Resolved, because the CLI is usually run through a symlink on PATH.
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) await main(process.argv.slice(2));
