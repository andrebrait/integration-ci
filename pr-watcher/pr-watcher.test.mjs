import assert from "node:assert/strict";
import { test } from "node:test";
import { diffPr, formatMessage } from "./pr-watcher.mjs";

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

test("CI is reported once per terminal result per head", () => {
  const { next: pending } = diffPr(undefined, snap(), new Set());
  const { events, next: green } = diffPr(pending, snap({ ci: "SUCCESS" }), new Set());
  assert.deepEqual(events, ["- CI SUCCESS on aaaaaaaaaa"]);
  assert.deepEqual(diffPr(green, snap({ ci: "SUCCESS" }), new Set()).events, []);
  // Same result on a new head is news.
  assert.deepEqual(diffPr(green, snap({ ci: "SUCCESS", head: "bbbbbbbbbbbb" }), new Set()).events, ["- CI SUCCESS on bbbbbbbbbb"]);
});

test("message never starts with a slash and names the PR", () => {
  const msg = formatMessage("can1357/oh-my-pi#14656", "x", ["- e"]);
  assert.ok(!msg.startsWith("/"));
  assert.match(msg, /pr:\/\/can1357\/oh-my-pi\/14656$/);
});
