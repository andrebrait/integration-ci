#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const STABLE_TAG = /^v\d+\.\d+\.\d+$/;

export async function checkRelease({ latest, previous, dispatch, save }) {
  const tag = (await latest()).trim();
  if (!STABLE_TAG.test(tag)) throw new Error(`unexpected stable release tag: ${JSON.stringify(tag)}`);
  if ((await previous()) === tag) return "unchanged";
  await dispatch(tag);
  await save(tag);
  return "dispatched";
}

function command(bin, args) {
  return execFileSync(bin, args, { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }).trim();
}

async function readState(path) {
  try {
    return (await readFile(path, "utf8")).trim();
  } catch (error) {
    if (error?.code === "ENOENT") return undefined;
    throw error;
  }
}

async function writeState(path, tag) {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp`;
  await writeFile(temporary, `${tag}\n`, { mode: 0o600 });
  await rename(temporary, path);
}

export async function main(env = process.env) {
  const gh = env.OMP_RELEASE_WATCH_GH || "gh";
  const upstream = env.OMP_RELEASE_WATCH_UPSTREAM || "can1357/oh-my-pi";
  const fork = env.OMP_RELEASE_WATCH_FORK || "ompweb-dev/oh-my-pi";
  const workflow = env.OMP_RELEASE_WATCH_WORKFLOW || "omp-auto.yml";
  const ref = env.OMP_RELEASE_WATCH_REF || "fork-ci";
  const state =
    env.OMP_RELEASE_WATCH_STATE ||
    join(env.XDG_STATE_HOME || join(env.HOME || homedir(), ".local", "state"), "omp-release-watcher", "tag");
  let latestTag;
  const result = await checkRelease({
    latest: async () => {
      latestTag = command(gh, ["api", `repos/${upstream}/releases/latest`, "--jq", ".tag_name"]);
      return latestTag;
    },
    previous: () => readState(state),
    dispatch: async (tag) => {
      command(gh, [
        "workflow",
        "run",
        workflow,
        "--repo",
        fork,
        "--ref",
        ref,
        "-f",
        `tag=${tag}`,
        "-f",
        "force=false",
      ]);
    },
    save: (tag) => writeState(state, tag),
  });
  process.stdout.write(
    result === "dispatched" ? `dispatched ${workflow} for ${latestTag}\n` : `latest release unchanged: ${latestTag}\n`,
  );
  return result;
}

if (fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((error) => {
    process.stderr.write(`omp-release-watcher: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
