import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { cli, ompHost } from "./pr-watcher.mjs";
import { openStore } from "./store.mjs";

const script = fileURLToPath(new URL("./pr-watcher.mjs", import.meta.url));
const tmp = () => mkdtempSync(join(tmpdir(), "pr-watcher-cli-"));
function harness() {
  const dir = tmp();
  const store = openStore(dir, { config: join(dir, "none.json"), state: join(dir, "none-state.json") });
  const io = { out: [], err: [] };
  const run = (...argv) => cli(argv, { store, out: (line) => io.out.push(line), err: (line) => io.err.push(line), host: () => io.host ?? null });
  return { dir, store, io, run };
}

test("add writes a validated watch", () => {
  const { store, run } = harness();
  assert.equal(run("add", "a/b#1", "--session", "s-1"), 0);
  assert.deepEqual(store.list().map((w) => [w.pr, w.session, w.ignoreAuthors]), [["a/b#1", "s-1", []]]);
});

test("add rejects an invalid PR, session or login with status 2 and writes nothing", () => {
  const { store, io, run } = harness();
  assert.equal(run("add", "a/b", "--session", "s1"), 2);
  assert.equal(run("add", "a/b#1"), 2);
  assert.equal(run("add", "a/b#1", "--session", "bad id"), 2);
  assert.equal(run("add", "a/b#1", "--session", "s1", "--ignore-author", "no spaces"), 2);
  assert.deepEqual(store.list(), []);
  assert.ok(io.err.length >= 4);
});

test("add accepts repeated --ignore-author, including bots", () => {
  const { store, run } = harness();
  assert.equal(run("add", "a/b#1", "--session", "s1", "--ignore-author", "kvn", "--ignore-author", "coderabbitai[bot]"), 0);
  assert.deepEqual(store.list()[0].ignoreAuthors, ["kvn", "coderabbitai[bot]"]);
});

test("add refuses a session run by a terminal omp and writes nothing; omp-web and plain shells are accepted", () => {
  const { store, io, run } = harness();
  io.host = "terminal";
  assert.equal(run("add", "a/b#1", "--session", "s1"), 2);
  assert.deepEqual(store.list(), []);
  assert.match(io.err.join("\n"), /only to omp-web sessions/);
  io.host = "omp-web";
  assert.equal(run("add", "a/b#1", "--session", "s1"), 0);
  io.host = null;
  assert.equal(run("add", "a/b#2", "--session", "s1"), 0);
  assert.equal(store.list().length, 2);
});

test("ompHost classifies the nearest omp ancestor", () => {
  const tree = (procs) => [(pid) => procs[pid][0].join("\0"), (pid) => procs[pid][1]];
  const host = (procs) => ompHost(10, ...tree(procs));
  const shell = [["/bin/bash", "-c", "pr-watcher add"], 11];
  assert.equal(host({ 10: shell, 11: [["/opt/omp/current/omp", "--mode", "rpc-ui", "--resume", "x"], 1] }), "omp-web");
  assert.equal(host({ 10: shell, 11: [["omp", "--mode=rpc-ui"], 1] }), "omp-web");
  assert.equal(host({ 10: shell, 11: [["omp", "--resume"], 12], 12: [["/usr/bin/zsh"], 1] }), "terminal");
  assert.equal(host({ 10: shell, 11: [["/usr/bin/zsh"], 1] }), null);
  assert.equal(ompHost(10, () => { throw new Error("no /proc"); }, () => 1), null);
});

test("remove reports what it removed and succeeds when nothing matches", () => {
  const { store, io, run } = harness();
  store.add("a/b#1", "s1", []);
  store.add("a/b#1", "s2", []);
  assert.equal(run("remove", "a/b#1", "--session", "s1"), 0);
  assert.equal(run("remove", "a/b#1"), 0);
  assert.equal(run("remove", "a/b#1"), 0);
  assert.deepEqual(io.out, ["removed 1 watch", "removed 1 watch", "no matching watch"]);
});

test("list prints one line per watch, or JSON", () => {
  const { store, io, run } = harness();
  store.add("a/b#1", "s1", ["kvn"]);
  store.saveSnapshot("a/b#1", "s1", { state: "OPEN" });
  store.add("a/b#2", "s2", []);
  assert.equal(run("list"), 0);
  assert.deepEqual(io.out, ["a/b#1  s1  ignore=kvn  OPEN", "a/b#2  s2  -  new"]);
  io.out.length = 0;
  assert.equal(run("list", "--json"), 0);
  assert.deepEqual(JSON.parse(io.out[0]).map((w) => w.pr), ["a/b#1", "a/b#2"]);
});

test("an unknown subcommand or option prints usage and returns 2", () => {
  const { io, run } = harness();
  assert.equal(run("frobnicate"), 2);
  assert.equal(run("list", "--bogus"), 2);
  assert.match(io.err.join("\n"), /usage: pr-watcher/);
});

test("run through a symlink from another directory, the CLI uses PR_WATCHER_DATA_DIR", () => {
  const data = tmp();
  const link = join(tmp(), "pr-watcher");
  symlinkSync(script, link);
  const env = { ...process.env, PR_WATCHER_DATA_DIR: data, PR_WATCHER_CONFIG: join(data, "none.json") };
  // Seeded here: a CLI `add` would depend on whether the suite runs inside a terminal omp.
  const store = openStore(data, { config: join(data, "none.json"), state: join(data, "none-state.json") });
  store.add("a/b#7", "s7", []);
  store.add("a/b#8", "s8", []);
  execFileSync(process.execPath, [link, "remove", "a/b#8"], { env, cwd: tmpdir() });
  const listed = JSON.parse(execFileSync(process.execPath, [link, "list", "--json"], { env, encoding: "utf8" }));
  assert.deepEqual(listed.map((w) => w.pr), ["a/b#7"]);
});
