import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { checkRelease } from "./release-watcher.mjs";

const script = fileURLToPath(new URL("./release-watcher.mjs", import.meta.url));

function harness({ latest = "v18.20.3", previous, dispatchError } = {}) {
  const events = [];
  return {
    events,
    run: () =>
      checkRelease({
        latest: async () => latest,
        previous: async () => previous,
        dispatch: async (tag) => {
          events.push(["dispatch", tag]);
          if (dispatchError) throw dispatchError;
        },
        save: async (tag) => events.push(["save", tag]),
      }),
  };
}

test("dispatches a newly published stable release before persisting it", async () => {
  const watcher = harness();

  assert.equal(await watcher.run(), "dispatched");
  assert.deepEqual(watcher.events, [
    ["dispatch", "v18.20.3"],
    ["save", "v18.20.3"],
  ]);
});

test("does nothing when the latest release was already dispatched", async () => {
  const watcher = harness({ previous: "v18.20.3" });

  assert.equal(await watcher.run(), "unchanged");
  assert.deepEqual(watcher.events, []);
});

test("does not persist a release when workflow dispatch fails", async () => {
  const watcher = harness({ dispatchError: new Error("dispatch refused") });

  await assert.rejects(watcher.run(), /dispatch refused/);
  assert.deepEqual(watcher.events, [["dispatch", "v18.20.3"]]);
});

test("retries at-least-once after dispatch succeeds but state persistence fails", async () => {
  let dispatches = 0;
  let saves = 0;
  const run = () =>
    checkRelease({
      latest: async () => "v18.20.3",
      previous: async () => undefined,
      dispatch: async () => {
        dispatches++;
      },
      save: async () => {
        if (++saves === 1) throw new Error("disk full");
      },
    });

  await assert.rejects(run(), /disk full/);
  assert.equal(await run(), "dispatched");
  assert.equal(dispatches, 2);
});

test("rejects an unexpected latest-release tag", async () => {
  const watcher = harness({ latest: "nightly" });

  await assert.rejects(watcher.run(), /unexpected stable release tag/);
  assert.deepEqual(watcher.events, []);
});

test("CLI persists an accepted tag and then no-ops", () => {
  const dir = mkdtempSync(join(tmpdir(), "omp-release-watcher-"));
  const fakeGh = join(dir, "gh");
  const log = join(dir, "dispatch.jsonl");
  const state = join(dir, "state", "tag");
  writeFileSync(
    fakeGh,
    `#!/usr/bin/env node
import { appendFileSync } from "node:fs";
const args = process.argv.slice(2);
if (args[0] === "api") process.stdout.write("v18.20.3\\n");
else if (args[0] === "workflow") appendFileSync(process.env.FAKE_GH_LOG, JSON.stringify(args) + "\\n");
else process.exitCode = 2;
`,
  );
  chmodSync(fakeGh, 0o755);
  const env = {
    ...process.env,
    FAKE_GH_LOG: log,
    OMP_RELEASE_WATCH_GH: fakeGh,
    OMP_RELEASE_WATCH_STATE: state,
  };

  assert.match(execFileSync(process.execPath, [script], { env, encoding: "utf8" }), /dispatched .*v18\.20\.3/);
  assert.match(execFileSync(process.execPath, [script], { env, encoding: "utf8" }), /unchanged: v18\.20\.3/);
  assert.equal(readFileSync(state, "utf8"), "v18.20.3\n");
  const dispatches = readFileSync(log, "utf8").trim().split("\n").map(JSON.parse);
  assert.deepEqual(dispatches, [
    [
      "workflow",
      "run",
      "omp-sync.yml",
      "--repo",
      "ompweb-dev/oh-my-pi",
      "--ref",
      "oml",
      "-f",
      "tag=v18.20.3",
    ],
  ]);
});
