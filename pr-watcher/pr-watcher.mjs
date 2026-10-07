#!/usr/bin/env node
// Polls GitHub pull requests and notifies the omp session mapped to each one
// through omp-web's agent API. Config is re-read on every cycle (hot reload).
import { execFile } from "node:child_process";
import { mkdirSync, readFileSync, renameSync, watch, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const run = promisify(execFile);
const CONFIG = process.env.PR_WATCHER_CONFIG ?? join(homedir(), ".config/pr-watcher/config.json");
const STATE = process.env.PR_WATCHER_STATE ?? join(homedir(), ".local/state/pr-watcher/state.json");
const TERMINAL_CI = new Set(["SUCCESS", "FAILURE", "ERROR"]);
const FINISHED = new Set(["MERGED", "CLOSED"]);

const QUERY = `query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){
  state title
  comments(last:50){nodes{id author{login} body url}}
  reviews(last:50){nodes{id author{login} state body url}}
  commits(last:1){nodes{commit{oid statusCheckRollup{state}}}}}}}`;

const log = (...args) => console.log(new Date().toISOString(), ...args);

/** "owner/repo#123" → parts, or null. */
export function parsePr(ref) {
  const m = /^([\w.-]+)\/([\w.-]+)#(\d+)$/.exec(ref ?? "");
  return m ? { owner: m[1], name: m[2], number: Number(m[3]) } : null;
}

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
  const next = { seen: snap.items.map(i => i.id), head: snap.head, ci: snap.ci, state: snap.state };
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
  if (TERMINAL_CI.has(snap.ci) && (snap.ci !== prev.ci || snap.head !== prev.head)) {
    events.push(`- CI ${snap.ci} on ${snap.head.slice(0, 10)}`);
  }
  return { events, next };
}

export function formatMessage(ref, title, events) {
  const { owner, name, number } = parsePr(ref);
  // Never starts with "/": omp would treat it as a slash command.
  return [`PR update (pr-watcher): ${ref} "${title}"`, ...events, `Details: pr://${owner}/${name}/${number}`].join("\n");
}

class OmpWeb {
  #url;
  #cookie = "";
  constructor(url) {
    this.#url = url.replace(/\/$/, "");
  }
  async #login() {
    const password = process.env.OMP_WEB_PASSWORD;
    if (!password) return false;
    const res = await fetch(`${this.#url}/api/web-auth/session`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ password }),
    });
    if (!res.ok) throw new Error(`omp-web login failed: HTTP ${res.status}`);
    this.#cookie = res.headers.getSetCookie().map(c => c.split(";")[0]).join("; ");
    return true;
  }
  async #request(path, body) {
    for (let attempt = 0; ; attempt++) {
      const res = await fetch(`${this.#url}${path}`, {
        method: body ? "POST" : "GET",
        headers: { "content-type": "application/json", cookie: this.#cookie },
        body: body && JSON.stringify(body),
      });
      if (res.status === 401 && attempt === 0 && (await this.#login())) continue;
      const json = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(`omp-web ${path}: HTTP ${res.status} ${json.error ?? ""}`.trim());
      return json;
    }
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

const readJson = (file, fallback) => {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return fallback;
    throw error;
  }
};

const writeJson = (file, value) => {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(`${file}.tmp`, `${JSON.stringify(value, null, 2)}\n`);
  renameSync(`${file}.tmp`, file);
};

let lastGoodConfig = { watches: [] };
let self = "";

async function cycle() {
  try {
    lastGoodConfig = readJson(CONFIG, { watches: [] });
  } catch (error) {
    log(`config unreadable, keeping the previous one: ${error.message}`);
  }
  const config = lastGoodConfig;
  const ompweb = new OmpWeb(config.ompwebUrl ?? "http://127.0.0.1:30185");
  const state = readJson(STATE, {});
  const live = {};
  for (const watchEntry of config.watches ?? []) {
    const pr = parsePr(watchEntry.pr);
    if (!pr || !watchEntry.session) {
      log(`skipping invalid watch ${JSON.stringify(watchEntry)}`);
      continue;
    }
    const key = `${watchEntry.pr}->${watchEntry.session}`;
    live[key] = state[key];
    // Polled until merged or closed, so late bot re-reviews and human comments still arrive.
    // The final state change has already been delivered; remove the watch to clear it.
    if (FINISHED.has(state[key]?.state)) continue;
    try {
      const snap = await fetchPr(pr);
      const ignore = new Set([self, ...(config.ignoreAuthors ?? []), ...(watchEntry.ignoreAuthors ?? [])]);
      const { events, next } = diffPr(state[key], snap, ignore);
      if (events.length && !(await ompweb.notify(watchEntry.session, formatMessage(watchEntry.pr, snap.title, events)))) {
        log(`${key}: session busy with a shell command or compaction, retrying next cycle`);
        continue;
      }
      if (events.length) log(`${key}: delivered ${events.length} event(s)`);
      live[key] = next;
    } catch (error) {
      log(`${key}: ${error.message}`);
    }
  }
  // Dropping keys for removed watches means re-adding one starts from a fresh baseline.
  writeJson(STATE, live);
  return config.intervalSeconds ?? 60;
}

async function main() {
  self = (await run("gh", ["api", "user", "-q", ".login"])).stdout.trim();
  if (process.argv.includes("--once")) return void (await cycle());
  let timer;
  let running = false;
  const loop = async () => {
    clearTimeout(timer);
    if (running) return;
    running = true;
    const seconds = await cycle();
    running = false;
    timer = setTimeout(loop, seconds * 1000);
  };
  mkdirSync(dirname(CONFIG), { recursive: true });
  // Editors replace the file, so watch its directory; a burst of events coalesces into one cycle.
  let debounce;
  watch(dirname(CONFIG), () => {
    clearTimeout(debounce);
    debounce = setTimeout(loop, 500);
  });
  log(`watching ${CONFIG} as ${self}`);
  await loop();
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main();
