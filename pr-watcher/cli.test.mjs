import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { cli } from "./pr-watcher.mjs";
import { openStore } from "./store.mjs";

const script = fileURLToPath(new URL("./pr-watcher.mjs", import.meta.url));
const tmp = () => mkdtempSync(join(tmpdir(), "pr-watcher-cli-"));
function harness() {
  const dir = tmp();
  const store = openStore(dir, { config: join(dir, "none.json"), state: join(dir, "none-state.json") });
  const io = { out: [], err: [] };
  const run = (...argv) => cli(argv, { store, out: (line) => io.out.push(line), err: (line) => io.err.push(line) });
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
  execFileSync(process.execPath, [link, "add", "a/b#7", "--session", "s7"], { env, cwd: tmpdir() });
  const listed = JSON.parse(execFileSync(process.execPath, [link, "list", "--json"], { env, encoding: "utf8" }));
  assert.deepEqual(listed.map((w) => w.pr), ["a/b#7"]);
});
