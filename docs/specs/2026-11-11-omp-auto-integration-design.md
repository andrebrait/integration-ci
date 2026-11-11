# omp auto-integration: scheduled rebuilds, in-CI repair, fork releases, omp-web channel

## Goal

- Every new upstream omp release (`can1357/oh-my-pi` tag `vX.Y.Z`) gets a
  matching integration build without anyone at a terminal: the release plus our
  carried PRs, built, tested, and published as a release on
  `andrebrait/oh-my-pi`.
- A round that the `integration` script cannot finish mechanically (conflict,
  stale fixup, failing `bun check` or tests) is repaired by an omp agent inside
  the same workflow. A human sees an issue only when the agent also fails.
- omp-web can install those releases from its GUI: the omp update row gets a
  source, **Upstream** or **Custom**, per host.

Non-goals: rebasing or force-pushing our open upstream PR branches
(`integration prs`) in unattended rounds; building on every `upstream/main`
commit; a host-side watcher; Codex/ChatGPT-subscription credentials in CI.

## 1. Scheduled round (`.github/workflows/omp-auto.yml`)

Trigger: `schedule` (hourly) and `workflow_dispatch` (input `tag`, optional;
`force` boolean to rebuild an already-released tag).

Job `detect` (no secrets, `contents: read`):

- Latest upstream release tag: `gh release view -R can1357/oh-my-pi --json
  tagName` (stable releases only).
- Skip when `andrebrait/oh-my-pi` already has a release whose tag starts with
  `<tag>-int.` and `force` is false. Otherwise output `tag`.
- `concurrency: omp-auto` (no cancel), so two rounds never overlap.

Job `rebuild` (needs `detect`; secrets: none; token: read-only):

- Clone `andrebrait/oh-my-pi` with remotes `origin` (fork) and `upstream`
  (`can1357/oh-my-pi`), check out this repo at `ci/`.
- Run the existing script in CI mode: `integration rebuild` with
  `BASE=<tag>` (overrides `latest-tag`/`upstream/main`), config and fixups
  read from `ci/config`, cache and worktrees under `$RUNNER_TEMP`.
  Required script changes (section 5): path roots from env, `BASE` override,
  and a `--no-push` flag so the job never needs a write token.
- Then `BUILD_CMD` and `TEST_CMD` from the config, exactly as `omp.yml` runs
  them.
- On success: upload the integration branch as a git bundle artifact
  (`integration.bundle`) plus `round.json` (`tag`, `sha`, carried PR list).
- On failure: upload the worktree state as a bundle plus `failure.json`
  (step: `rebuild`, `format`, `check`, or `test`; PR number when the script
  names one; last 200 log lines) and mark the job failed.

Job `repair` (runs only when `rebuild` failed; at most one per round):

- Secrets: `ANTHROPIC_API_KEY` only. Token: read-only. No push credential.
- Restores the failed state from the bundle. The agent binary is upstream's
  release `omp-linux-x64` for the round's tag (digest-checked against
  `SHA256SUMS.txt`), not the code under repair. It runs headless:
  `omp -p --no-session --model anthropic/claude-haiku-5-5 --thinking medium
  --approval-mode yolo` with the prompt from `ci/prompts/omp-repair.md`
  (Handlebars-free plain file; the job appends `failure.json`).
- The prompt tells the agent: finish the round with the `integration` script's
  own rules (resolve in the worktree, commit as `PR #N: <title>`, refresh
  `N-resolve.patch` / `N-*.patch` under `ci/config/fixups/...`, re-run
  `integration rebuild`), then run `BUILD_CMD` and `TEST_CMD`; never weaken or
  skip a test, never drop a PR; when a PR cannot be carried, stop and write
  why to `repair-notes.md`.
- Limits: job `timeout-minutes: 90` (`BUILD_CMD` compiles the natives).
  Exactly one repair attempt per round.
- On success: upload the same artifacts as a successful `rebuild`, plus
  `fixups.patch` (the diff under `ci/config/fixups`) and `repair-notes.md`.
- On failure: upload `repair-notes.md` and the log.

Job `publish-branch` (needs `rebuild` or `repair` success; no fork code runs):

- Secret: `OMP_FORK_TOKEN`, a fine-grained PAT scoped to
  `andrebrait/oh-my-pi` only: Contents write (branch push and release
  create/delete). Writes to this repository use the workflow's own
  `GITHUB_TOKEN` with `contents: write`.
- Fetches the bundle, verifies its head equals `round.json`'s `sha`, and
  force-pushes it to `andrebrait/oh-my-pi` branch `integration-release`.
- When `repair` produced `fixups.patch`, commits it to this repo's `main` as
  `fixups(omp): <tag> repair` and pushes with `GITHUB_TOKEN`; later rounds then
  start from it.
- Calls `omp.yml` via `workflow_call` with `repo`, `sha`, and the new
  `release` inputs (section 2), passing `OMP_FORK_TOKEN` for the fork release.

Job `escalate` (runs when `repair` failed, or `rebuild` failed and `repair`
was skipped by error):

- Token: the workflow's `GITHUB_TOKEN` with `issues: write`. No PAT.
- Opens one issue on `andrebrait/integration-ci` labelled `omp-auto`, titled
  `omp auto-integration failed for <tag>`, with the step, PR, log tail,
  `repair-notes.md`, and the run URL. If an open `omp-auto` issue for the same
  tag exists, it comments there instead.

Running out of Claude credits fails `repair`, which escalates; the human then
finishes the round locally with the subscription-backed omp and the usual
`integration` commands.

## 2. Fork release (`omp.yml` + `publish.yml` extension)

`omp.yml` gains inputs `release_repo` (default empty) and `release_tag`.
When both are set, the `publish` job additionally creates a release on
`release_repo`:

- Tag `<upstream tag>-int.<sha7>` on the built commit, e.g.
  `v18.18.9-int.95bee5c`. Marked latest on the fork.
- Notes: upstream's release body for `<upstream tag>`, then a `## Carried
  patches` section listing each squash (`PR #N: <title>` with its link), taken
  from `round.json`.
- Assets named exactly like upstream's release (`omp-linux-x64`,
  `omp-darwin-arm64`, …, `omp-windows-x64.exe`) plus `SHA256SUMS.txt`, so a
  consumer verifies them the same way.
- Keeps the newest 10 fork releases; older ones are deleted with their tags.

The existing `oh-my-pi` rolling release in this repo and manual
`integration build` runs are unchanged.

## 3. omp-web update source (kahme247/ompweb PR)

- Per-host setting in Settings → Hosts → OMP runtime: **Source**,
  `Upstream` (default, today's behaviour: `omp update`) or `Custom`, with a
  repository field (`owner/repo`, default empty, must be set for Custom).
  Stored with the host's settings; older daemons that lack it show only
  Upstream.
- Custom check: read the repository's latest release; its tag is the
  available version (`18.18.9-int.95bee5c`); the installed version is
  `omp --version` plus the build sha recorded beside the binary. Update is
  offered when the tag differs from the installed one.
- Custom install, on the host daemon: download `omp-<os>-<arch>` and
  `SHA256SUMS.txt` through the existing GitHub-only fetcher, verify the
  digest, write to `<omp dir>/releases/<tag>/omp`, run `omp --smoke-test`,
  then swap the `current` symlink atomically (or replace the binary in place
  when `OMP_WEB_OMP_BIN` is not a symlinked layout). Failure leaves the old
  binary in place.
- Version validators accept `X.Y.Z-int.<sha7>` for the Custom source.
- i18n en/ja/zh-CN(/zh-TW where present); tests for the check parser, digest
  mismatch, smoke-test failure rollback, and the setting round trip.

### 3b. omp-web's own update channel: pre-releases

`kahme247/ompweb` already publishes a GitHub pre-release for every commit on
`main` (tag `<UTC stamp>-<sha10>`, assets `ompweb-<os>-<arch>.tar.gz` /
`.zip` with GitHub sha256 digests, the same names as stable releases).

- Per-host setting beside the omp source: **ompweb channel**, `Stable`
  (default, today's npm/`v<semver>` check) or `Pre-release`.
- Pre-release check: newest pre-release of `kahme247/ompweb` by
  `published_at`; update offered when its sha10 differs from the running
  build's commit (the build already embeds its commit for the logo
  version display) and it is newer than the running build.
- Install reuses the existing binary path (`stageBinary`, digest
  verification, worker in its own systemd scope); validators accept the
  `<stamp>-<sha10>` tag for this channel.
- Deployment hook: a new optional env `OMP_WEB_SELF_UPDATE_CMD`. When set,
  the updater still downloads, verifies and unpacks the release, then runs
  the command with `OMP_WEB_UPDATE_SHA` (full commit sha) and
  `OMP_WEB_UPDATE_DIR` (unpacked directory) instead of swapping the binary
  itself, from the same systemd scope. This host sets it to
  `/opt/omp-deployment/bin/ompweb-deploy "$OMP_WEB_UPDATE_SHA"
  "$OMP_WEB_UPDATE_DIR"`; `ompweb-deploy` already accepts that binary layout
  (`ompweb-build`'s "binary" case) and does the release dir, probes and
  rollback. Unset keeps today's in-place binary update.
- Retiring integration-ci's `ompweb.yml` follows once this channel works on
  this host.

### 3c. GitHub token for omp-web's API calls

omp-web calls the GitHub API unauthenticated for release checks, release
notes, update downloads and (with `GITHUB_TOKEN`/`GH_TOKEN` from the
environment only) skill update checks. Unauthenticated calls share a limit of
60 requests per hour per IP; the new channels add more checks.

- Settings → Interface & Behavior (server-wide): **GitHub token**, a
  password field with a hint to create a fine-grained PAT with "Public
  repositories (read-only)" and no permissions. Save, Test (calls
  `GET /rate_limit` and shows the limit), Remove.
- Stored server-side in omp-web's data directory with mode `0600`; never
  sent back to the browser (the UI shows only "set" and the last 4
  characters). `GITHUB_TOKEN`/`GH_TOKEN` stay as a fallback when no token is
  saved.
- One helper, used by every GitHub API call in omp-web (`skill-updates`,
  `github-release-notes`, `hosts/update-worker`, the new channel checks),
  adds `Authorization: Bearer <token>` only for `api.github.com`; asset
  downloads that redirect to the CDN never receive the header.
- Linked hosts receive the token over the existing host link for their
  update checks; a host without it falls back to unauthenticated calls.
- A 401 from GitHub shows "GitHub token rejected" in Settings and retries
  unauthenticated, so a revoked token never blocks updates.

## 4. Secrets and trust

| Job | Runs | Secrets | Token |
|---|---|---|---|
| detect | no fork code | none | read |
| rebuild | fork + carried PRs | none | read |
| repair | fork code + LLM agent | `ANTHROPIC_API_KEY` | read |
| publish-branch | no fork code, no agent | `OMP_FORK_TOKEN` | `contents: write` (this repo) |
| escalate | no fork code, no agent | none | `issues: write` |
| omp.yml publish | no fork code | `OMP_FORK_TOKEN` (fork release) | `contents: write` (this repo's `oh-my-pi` release) |

A prompt injection from upstream or a carried PR can at most produce a patch;
that patch reaches the fork only through `publish-branch`, which requires the
bundle head to be the commit that passed `BUILD_CMD` and `TEST_CMD`.

## 5. `integration` script changes

- Path roots overridable by env: `INTEGRATION_CONFIG_DIR`,
  `INTEGRATION_CACHE_DIR`, `INTEGRATION_WORKTREES_DIR` (defaults unchanged).
- `INTEGRATION_BASE` overrides the config's `BASE`.
- `rebuild --no-push`: never pushes, never dispatches CI.
- The "config differs from origin/main" guard is skipped when the config dir
  is a checkout of `origin/main` itself (CI case).
- Host usage (`integration rebuild/build/deploy`) behaves exactly as today.

Conflict resolutions in CI come only from the committed `N-resolve.patch`
files; the workflow keeps no rerere cache. The host's rerere cache and manual
runs are unchanged.

## 6. Testing

- Script: a CI-mode dry run in a scratch clone against the current tag
  (`INTEGRATION_BASE=v18.18.9 integration rebuild --no-push`).
- Workflow: one `workflow_dispatch` round with `force=true` on the current
  tag, observed end to end (expected: rebuild fails on the known #14114
  `models.json` conflict, so `repair` runs; either it fixes it and a fork
  release appears, or an issue is opened).
- omp-web: component and unit tests above, plus a manual install of the fork
  release on this host after your go-ahead.

## Rollout order

1. Script changes + `omp-auto.yml` + prompt (this repo).
2. `omp.yml` release inputs.
3. You add the secrets `OMP_FORK_TOKEN` and `ANTHROPIC_API_KEY`; first dispatched round.
4. omp-web PR: omp update source (3), pre-release channel (3b), GitHub token (3c).
