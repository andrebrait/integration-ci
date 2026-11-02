import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { ciState, cycle, diffPr, formatMessage, settings } from "./pr-watcher.mjs";
import { openStore } from "./store.mjs";

const snap = (over = {}) => ({
  state: "OPEN",
  title: "t",
  head: "aaaaaaaaaaaa",
  ci: "PENDING",
  items: [{ kind: "comment", id: "c1", author: "kvn", body: "hi", url: "u1" }],
  ...over,
});

test("a new watch records a baseline without events", () => {
  const { events, next } = diffPr(undefined, snap(), new Set());
  assert.deepEqual(events, []);
  assert.deepEqual(next.seen, ["c1"]);
});

test("reports unseen items except ignored authors", () => {
  const { next: prev } = diffPr(undefined, snap(), new Set());
  const items = [
    ...snap().items,
    { kind: "review", id: "r1", author: "roboomp", state: "COMMENTED", body: "", url: "u2" },
    { kind: "comment", id: "c2", author: "me", body: "mine", url: "u3" },
  ];
  const { events } = diffPr(prev, snap({ items }), new Set(["me"]));
  assert.deepEqual(events, ["- roboomp reviewed (COMMENTED): (inline comments only) u2"]);
});

test("an edit to a seen item is reported once, with the new body", () => {
  const { next: prev } = diffPr(undefined, snap(), new Set());
  const edited = [{ ...snap().items[0], body: "<!-- bot marker -->\nReview finished", edited: "2026-10-15T14:01:50Z" }];
  const { events, next } = diffPr(prev, snap({ items: edited }), new Set());
  assert.deepEqual(events, ["- kvn edited a comment: Review finished u1"]);
  assert.deepEqual(diffPr(next, snap({ items: edited }), new Set()).events, []);
  const again = [{ ...edited[0], edited: "2026-10-15T14:05:00Z" }];
  assert.equal(diffPr(next, snap({ items: again }), new Set()).events.length, 1);
});

test("a snapshot from before edit tracking takes edits as a baseline", () => {
  const items = [{ ...snap().items[0], edited: "2026-10-15T14:01:50Z" }];
  const { events } = diffPr({ seen: ["c1"], head: "aaaaaaaaaaaa", ci: "PENDING", state: "OPEN" }, snap({ items }), new Set());
  assert.deepEqual(events, []);
});

test("an ignored author's edit is not reported", () => {
  const { next: prev } = diffPr(undefined, snap(), new Set());
  const items = [{ ...snap().items[0], edited: "2026-10-15T14:01:50Z" }];
  assert.deepEqual(diffPr(prev, snap({ items }), new Set(["kvn"])).events, []);
});

test("CI is reported once per terminal result per head", () => {
  const { next: pending } = diffPr(undefined, snap(), new Set());
  const { events, next: green } = diffPr(pending, snap({ ci: "SUCCESS" }), new Set());
  assert.deepEqual(events, ["- CI SUCCESS on aaaaaaaaaa"]);
  assert.deepEqual(diffPr(green, snap({ ci: "SUCCESS" }), new Set()).events, []);
  // Same result on a new head is news.
  assert.deepEqual(diffPr(green, snap({ ci: "SUCCESS", head: "bbbbbbbbbbbb" }), new Set()).events, ["- CI SUCCESS on bbbbbbbbbb"]);
});

test("a rerun of the same head does not repeat its CI result", () => {
  const { next: green } = diffPr(diffPr(undefined, snap(), new Set()).next, snap({ ci: "SUCCESS" }), new Set());
  const { events: duringRerun, next: pending } = diffPr(green, snap({ ci: "PENDING" }), new Set());
  assert.deepEqual(duringRerun, []);
  assert.deepEqual(diffPr(pending, snap({ ci: "SUCCESS" }), new Set()).events, []);
  // A different result from the rerun is news.
  assert.deepEqual(diffPr(pending, snap({ ci: "FAILURE" }), new Set()).events, ["- CI FAILURE on aaaaaaaaaa"]);
});

test("CI state leaves out review bots' checks: CodeRabbit and Kilo Code neither hold nor fail it", () => {
  const run = (name, app, status, conclusion = null) => ({ __typename: "CheckRun", name, status, conclusion, checkSuite: { app: { slug: app } } });
  const ci = (conclusion) => run("Verify", "github-actions", conclusion ? "COMPLETED" : "IN_PROGRESS", conclusion);
  const bots = [run("Kilo Code Review", "kilo-code-bot", "IN_PROGRESS"), run("CodeRabbit", "coderabbitai", "COMPLETED", "FAILURE")];
  assert.equal(ciState([ci("SUCCESS"), ...bots]), "SUCCESS");
  assert.equal(ciState([ci(null), ...bots]), "PENDING");
  assert.equal(ciState([ci("SUCCESS"), ci("FAILURE"), ...bots]), "FAILURE");
  assert.equal(ciState([ci("SUCCESS"), run("Lint", "github-actions", "COMPLETED", "SKIPPED"), run("Docs", "github-actions", "COMPLETED", "NEUTRAL")]), "SUCCESS");
  assert.equal(ciState([ci("SUCCESS"), run("Deploy", "github-actions", "COMPLETED", "CANCELLED")]), "FAILURE");
  assert.equal(ciState(bots), "NONE", "only review bots: no CI");
  assert.equal(ciState([]), "NONE");
  // Commit statuses: pending, error, and a review bot's status by its creator.
  const status = (context, state, login = "ci-bot") => ({ __typename: "StatusContext", context, state, creator: { login } });
  assert.equal(ciState([ci("SUCCESS"), status("legacy", "PENDING")]), "PENDING");
  assert.equal(ciState([ci("SUCCESS"), status("legacy", "ERROR")]), "ERROR");
  assert.equal(ciState([ci("SUCCESS"), status("CodeRabbit", "PENDING", "coderabbitai[bot]")]), "SUCCESS");
});

test("message never starts with a slash and names the PR", () => {
  const msg = formatMessage("can1357/oh-my-pi#14656", "x", ["- e"]);
  assert.ok(!msg.startsWith("/"));
  assert.match(msg, /pr:\/\/can1357\/oh-my-pi\/14656$/);
});

const tmpStore = () => {
  const dir = mkdtempSync(join(tmpdir(), "pr-watcher-cycle-"));
  return { dir, store: openStore(dir, { config: join(dir, "none.json"), state: join(dir, "none-state.json") }) };
};
const deps = (fetchPr, notify = async () => true) => ({ fetchPr, notify, self: "me", ignoreAuthors: [] });
const comment = (id, author = "kvn") => ({ kind: "comment", id, author, body: id, url: `u-${id}` });

test("settings apply defaults and parse the ignore list", () => {
  assert.deepEqual(settings({}), { ompwebUrl: "http://127.0.0.1:30185", intervalSeconds: 60, ignoreAuthors: [] });
  assert.deepEqual(settings({ PR_WATCHER_OMPWEB_URL: "http://h:1", PR_WATCHER_INTERVAL_SECONDS: "30", PR_WATCHER_IGNORE_AUTHORS: "a, b," }), { ompwebUrl: "http://h:1", intervalSeconds: 30, ignoreAuthors: ["a", "b"] });
});

test("settings fall back to 60 seconds for an invalid interval", () => {
  // Over a day: setTimeout would overflow its 32-bit delay and fire at once, a hot loop.
  for (const value of ["abc", "0", "-5", "1.5x", "86401", "3600000", "99999999999"]) assert.equal(settings({ PR_WATCHER_INTERVAL_SECONDS: value }).intervalSeconds, 60, value);
  assert.equal(settings({ PR_WATCHER_INTERVAL_SECONDS: "86400" }).intervalSeconds, 86400);
});

test("a new watch stores a baseline and notifies nothing", async () => {
  const { store } = tmpStore();
  store.add("a/b#1", "s1", []);
  const sent = [];
  await cycle(store, deps(async () => snap(), async (...args) => sent.push(args)));
  assert.deepEqual(sent, []);
  assert.deepEqual(store.list()[0].snapshot.seen, ["c1"]);
});

test("new activity is delivered and the snapshot advances", async () => {
  const { store } = tmpStore();
  store.add("a/b#1", "s1", []);
  await cycle(store, deps(async () => snap()));
  const sent = [];
  await cycle(store, deps(async () => snap({ items: [comment("c1"), comment("c2")] }), async (session, message) => sent.push([session, message]) > 0));
  assert.equal(sent.length, 1);
  assert.equal(sent[0][0], "s1");
  assert.match(sent[0][1], /kvn commented: c2/);
  assert.deepEqual(store.list()[0].snapshot.seen, ["c1", "c2"]);
});

test("a busy session keeps the old snapshot, so the update is retried", async () => {
  const { store } = tmpStore();
  store.add("a/b#1", "s1", []);
  await cycle(store, deps(async () => snap()));
  await cycle(store, deps(async () => snap({ items: [comment("c1"), comment("c2")] }), async () => false));
  assert.deepEqual(store.list()[0].snapshot.seen, ["c1"]);
});

test("per-watch and global ignore lists and the gh user are not reported", async () => {
  const { store } = tmpStore();
  store.add("a/b#1", "s1", ["bot"]);
  await cycle(store, deps(async () => snap()));
  const sent = [];
  const items = [comment("c1"), comment("c2", "bot"), comment("c3", "me"), comment("c4", "noisy")];
  await cycle(store, { ...deps(async () => snap({ items }), async (...args) => sent.push(args) > 0), ignoreAuthors: ["noisy"] });
  assert.deepEqual(sent, []);
});

test("a watch removed while its PR is fetched is not recreated", async () => {
  const { store } = tmpStore();
  store.add("a/b#1", "s1", []);
  await cycle(store, deps(async () => {
    store.remove("a/b#1");
    return snap();
  }));
  assert.deepEqual(store.list(), []);
});

test("a delivered merge notice ends the watch", async () => {
  const { store } = tmpStore();
  store.add("a/b#1", "s1", []);
  await cycle(store, deps(async () => snap()));
  const sent = [];
  await cycle(store, deps(async () => snap({ state: "MERGED" }), async (...args) => sent.push(args) > 0));
  assert.equal(sent.length, 1);
  assert.deepEqual(store.list(), []);
});

test("a watch added after its PR closed ends on its first cycle", async () => {
  const { store } = tmpStore();
  store.add("a/b#1", "s1", []);
  await cycle(store, deps(async () => snap({ state: "CLOSED" })));
  assert.deepEqual(store.list(), []);
});

test("a fetch error leaves that watch alone and the others proceed", async () => {
  const { store } = tmpStore();
  store.add("a/b#1", "s1", []);
  store.add("a/b#2", "s1", []);
  await cycle(store, deps(async ({ number }) => {
    if (number === 1) throw new Error("boom");
    return snap();
  }));
  const [first, second] = store.list();
  assert.equal(first.snapshot, undefined);
  assert.deepEqual(second.snapshot.seen, ["c1"]);
});

test("a corrupt snapshot is treated as a new watch", async () => {
  const { dir, store } = tmpStore();
  store.add("a/b#1", "s1", []);
  const raw = new DatabaseSync(join(dir, "pr-watcher.db"));
  raw.prepare("UPDATE watches SET snapshot = ?").run("{not json");
  raw.close();
  const sent = [];
  await cycle(store, deps(async () => snap(), async (...args) => sent.push(args) > 0));
  assert.deepEqual(sent, []);
  assert.deepEqual(store.list()[0].snapshot.seen, ["c1"]);
});
