import assert from "node:assert/strict";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { dataDir, openStore } from "./store.mjs";

const tmp = () => mkdtempSync(join(tmpdir(), "pr-watcher-"));
// Never import the real legacy files from a test.
const open = (dir, legacy = { config: join(dir, "none.json"), state: join(dir, "none-state.json") }) => openStore(dir, legacy);

test("dataDir honors PR_WATCHER_DATA_DIR, then XDG_STATE_HOME", () => {
  assert.equal(dataDir({ PR_WATCHER_DATA_DIR: "/d" }), "/d");
  assert.equal(dataDir({ XDG_STATE_HOME: "/x" }), "/x/pr-watcher");
  assert.match(dataDir({}), /\/\.local\/state\/pr-watcher$/);
});

test("add then list returns the watch with no snapshot", () => {
  const store = open(tmp());
  store.add("a/b#1", "s1", []);
  const [watch] = store.list();
  assert.equal(watch.pr, "a/b#1");
  assert.equal(watch.session, "s1");
  assert.deepEqual(watch.ignoreAuthors, []);
  assert.equal(watch.snapshot, undefined);
});

test("re-add keeps the snapshot and replaces ignoreAuthors", () => {
  const store = open(tmp());
  store.add("a/b#1", "s1", ["x"]);
  store.saveSnapshot("a/b#1", "s1", { seen: ["c1"] });
  store.add("a/b#1", "s1", ["y"]);
  const [watch] = store.list();
  assert.deepEqual(watch.snapshot, { seen: ["c1"] });
  assert.deepEqual(watch.ignoreAuthors, ["y"]);
});

test("remove with a session removes one; without, every watch of the PR", () => {
  const store = open(tmp());
  store.add("a/b#1", "s1", []);
  store.add("a/b#1", "s2", []);
  store.add("a/b#1", "s3", []);
  assert.equal(store.remove("a/b#1", "s1"), 1);
  assert.equal(store.remove("a/b#1"), 2);
  assert.equal(store.remove("a/b#1"), 0);
});

test("saveSnapshot on a removed watch returns false and does not recreate it", () => {
  const store = open(tmp());
  store.add("a/b#1", "s1", []);
  store.remove("a/b#1");
  assert.equal(store.saveSnapshot("a/b#1", "s1", { seen: [] }), false);
  assert.deepEqual(store.list(), []);
});

test("a second store on the same directory sees the first one's writes", () => {
  const dir = tmp();
  const first = open(dir);
  first.add("a/b#1", "s1", []);
  const second = open(dir);
  assert.equal(second.list().length, 1);
  second.saveSnapshot("a/b#1", "s1", { state: "OPEN" });
  assert.deepEqual(first.list()[0].snapshot, { state: "OPEN" });
});

function legacyFixture(dir) {
  const config = join(dir, "config.json");
  const state = join(dir, "state.json");
  writeFileSync(config, JSON.stringify({
    ompwebUrl: "http://x",
    watches: [
      { pr: "a/b#1", session: "s1" },
      { pr: "a/b#2", session: "s1" },
      { pr: "a/b#3", session: "s2", ignoreAuthors: ["bot[bot]"] },
      { pr: "not a pr", session: "s1" },
      { pr: "a/b#4" },
    ],
  }));
  writeFileSync(state, JSON.stringify({ "a/b#1->s1": { seen: ["c1"], state: "OPEN" }, "a/b#2->s1": { state: "MERGED" } }));
  return { config, state };
}

test("migration imports watches and snapshots, skips finished and invalid ones, renames the old files", () => {
  const dir = tmp();
  const legacy = legacyFixture(dir);
  const store = openStore(dir, legacy);
  const rows = store.list().map((w) => [w.pr, w.session, w.ignoreAuthors, w.snapshot]);
  assert.deepEqual(rows, [
    ["a/b#1", "s1", [], { seen: ["c1"], state: "OPEN" }],
    ["a/b#3", "s2", ["bot[bot]"], undefined],
  ]);
  assert.ok(existsSync(`${legacy.config}.migrated`) && existsSync(`${legacy.state}.migrated`));
  assert.ok(!existsSync(legacy.config) && !existsSync(legacy.state));
});

test("migration runs once: a recreated config is not imported again", () => {
  const dir = tmp();
  const legacy = legacyFixture(dir);
  openStore(dir, legacy).close();
  legacyFixture(dir);
  assert.equal(openStore(dir, legacy).list().length, 2);
});

test("two stores opened on a fresh directory import once", () => {
  const dir = tmp();
  const legacy = legacyFixture(dir);
  const first = openStore(dir, legacy);
  const second = openStore(dir, legacy);
  assert.equal(first.list().length, 2);
  assert.equal(second.list().length, 2);
});
