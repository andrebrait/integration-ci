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

Non-goals: rebasing every open PR branch each round (`integration prs`);
building on every `upstream/main` commit; a host-side watcher;
Codex/ChatGPT-subscription credentials in CI.

## 1. Scheduled round (`.github/workflows/omp-auto.yml`)

Trigger: `schedule` (hourly) and `workflow_dispatch` (inputs `tag`,
optional, and `force`, boolean, to rebuild an already-released tag).
`concurrency: omp-auto` (no cancel), so two rounds never overlap.

The existing `omp.yml` already runs `BUILD_CMD` + `TEST_CMD`, builds every
binary, and smoke-tests them; the round reuses it through `workflow_call`
instead of testing twice. `omp.yml` builds a commit that must exist on
GitHub, so each candidate is pushed to the fork branch `integration-candidate`
first. A candidate is never released until `omp.yml` is green on it.

Jobs, in order:

1. `detect` (no secrets, `contents: read`): the latest stable upstream release
   tag (`gh release view -R can1357/oh-my-pi --json tagName`). Skip the round
   when `andrebrait/oh-my-pi` already has a release tagged `<tag>-int.*` and
   `force` is false. Output `tag`.
2. `rebuild` (no secrets, read-only token): clone `andrebrait/oh-my-pi` with
   remotes `origin` (fork) and `upstream` (`can1357/oh-my-pi`), check this
   repo out at `ci/`, create the `integration` worktree, and run
   `ci/integration rebuild` with the CI overrides from section 5 (base =
   `tag`). `rebuild` itself never pushes. Upload `integration.bundle` (the
   result, or the stopped state on failure) and, on failure, `failure.json`
   (`step: "rebuild"`, the script's last 200 log lines).
3. `candidate` (needs `rebuild` success; runs no fork code, no agent):
   secret `OMP_FORK_TOKEN`. Verify the bundle head, force-push it to the fork
   branch `integration-candidate`. Output `sha`. Rebased PR branches from the
   bundle are not pushed here; `release` pushes them after a green build.
4. `build` (`uses: ./.github/workflows/omp.yml`, inputs `repo`, `sha`): the
   existing pipeline, unchanged, plus a `workflow_call` trigger.
5. `repair` (when `rebuild` or `build` failed; one per round): see below.
   On success it uploads a new `integration.bundle` and `fixups.patch`.
6. `candidate-2` and `build-2`: the same as 3 and 4 for the repaired bundle.
7. `release` (needs the green `build` or `build-2`): section 2.
8. `fixups` (after a successful `repair` and green `build-2`): commit
   `fixups.patch` to this repo's `main` as `fixups(omp): <tag> repair` with
   the workflow's `GITHUB_TOKEN` (`contents: write`), so later rounds and
   manual runs start from it.
9. `escalate` (when `repair` or `build-2` failed): open one issue on this
   repo labelled `omp-auto`, titled `omp auto-integration failed for <tag>`,
   with the failing step, log tail, `repair-notes.md` and the run URL, using
   `GITHUB_TOKEN` with `issues: write`. If an open `omp-auto` issue for the
   same tag exists, comment there instead.

Job `repair`:

- Secrets: `OPENAI_API_KEY` and `ANTHROPIC_API_KEY`. Read-only token. No
  push credential.
- Input: the `rebuild` bundle and `failure.json`, or, when `build` failed,
  the candidate commit and `step: "build"` with the failed job's log tail
  (`gh run view --log-failed`).
- The agent binary is upstream's release `omp-linux-x64` for the round's tag,
  digest-checked against upstream's `SHA256SUMS.txt`, not the code under
  repair. Run headless: `omp -p --no-session --model openai/gpt-6-luna
  --thinking high --approval-mode yolo` with `ci/prompts/omp-repair.md` plus
  `failure.json`.
- When that run fails on a provider error (quota, billing, auth: omp exits
  non-zero before any commit and its output names the provider error), the
  job runs the same prompt once more with `--model
  anthropic/claude-haiku-5-5 --thinking medium`. A run that fails for any
  other reason does not retry. `repair-notes.md` records which model ran.
- The prompt tells the agent to finish the round with the `integration`
  script's own rules (resolve in the worktree, commit as `PR #N: <title>`,
  refresh `N-resolve.patch` / `N-*.patch` under `ci/config/fixups/...`,
  re-run `integration rebuild`), then run `BUILD_CMD` and `TEST_CMD`; never
  weaken or skip a test, never drop a PR; when a PR cannot be carried, stop
  and write why to `repair-notes.md`.
- `timeout-minutes: 120` (`BUILD_CMD` compiles the natives). Success means
  the agent exited 0, `BUILD_CMD` and `TEST_CMD` pass when the job re-runs
  them after the agent, and the worktree is clean.

Running out of both API budgets fails `repair`, which escalates; the human
then finishes the round locally with the subscription-backed omp and the
usual `integration` commands.

## 2. Fork release (job `release` in `omp-auto.yml`)

- Secret `OMP_FORK_TOKEN`. Runs no fork code. Downloads the `omp-<target>`
  artifacts that the called `omp.yml` uploaded in the same run.
- Force-pushes the released commit to the fork branch `integration-release`.
- Tag `<upstream tag>-int.<sha7>` on that commit, e.g. `v18.18.9-int.95bee5c`.
  Marked latest on the fork.
- Notes: upstream's release body for `<upstream tag>`, then a
  `## Carried patches` section listing each `PR #N: <title>` squash (newest
  last) with a link to the PR.
- Assets named exactly like upstream's release: `omp-linux-x64`,
  `omp-linux-arm64`, `omp-darwin-x64`, `omp-darwin-arm64`,
  `omp-windows-x64.exe`, `omp-windows-arm64.exe`, plus `SHA256SUMS.txt` in
  `sha256sum` format.
- Keeps the newest 10 fork releases; older ones are deleted with their tags.

The existing `oh-my-pi` rolling release in this repo (`omp.yml`'s own
`publish` job) and manual `integration build` runs are unchanged.

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
| candidate, candidate-2 | no fork code, no agent | `OMP_FORK_TOKEN` | — |
| build, build-2 (`omp.yml`) | fork code | none (its `publish` job writes this repo's `oh-my-pi` release) | read; `publish`: `contents: write` |
| repair | fork code + LLM agent | `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` | read |
| release | no fork code, no agent | `OMP_FORK_TOKEN` | read |
| fixups | no fork code, no agent | none | `contents: write` |
| escalate | no fork code, no agent | none | `issues: write` |

A prompt injection from upstream or a carried PR can at most produce a
candidate: it reaches the fork's `integration-candidate` branch, but is
released only after `omp.yml` builds and tests it green. Fixup patches reach
`main` only after that same green build.

## 5. `integration` script changes

All overrides are environment variables; unset keeps today's host behaviour.

- `INTEGRATION_SLUG`: replaces the slug derived from the repository path, so a
  CI clone at any path reads `config/root--git--oh-my-pi.sh` and its fixups.
- `INTEGRATION_CONFIG_DIR`: replaces `~/.config/integration` (CI: `ci/config`).
- `INTEGRATION_CACHE_DIR`: replaces `~/.cache/integration` (CI:
  `$RUNNER_TEMP/integration-cache`).
- `INTEGRATION_BASE`: replaces the config's `BASE` (CI: the round's tag).
- `INTEGRATION_PR_AUTHOR`: replaces `gh api user --jq .login` in `pr_rows`
  (CI: `andrebrait`), because an Actions token cannot read `/user`.
- `INTEGRATION_HEAD_PREFIX`: when `<prefix>/<fork-branch>` exists, `rebuild`
  uses it as the PR head instead of `$FORK_REMOTE/<fork-branch>` (CI:
  `refs/rebased`), so a branch the agent rebased locally is built without
  being pushed first. Fetches never touch that prefix.

Every PR is built on the release tag; there is no fallback to a PR's own
newer base. A PR branch that does not replay onto the tag stops `rebuild`
like any conflict, and `repair` adapts it to the release in that round:

- Our own PRs (author `andrebrait`) and `EXTRA_PRS` carry branches: the agent
  rebases the PR branch onto the release tag, resolving conflicts, stores it
  as `refs/rebased/<branch>` in the bundle, and re-runs `rebuild` against it.
  After the round's build is green, `release` force-pushes each rebased
  branch to its fork branch with `--force-with-lease` against the sha the
  round started from (a branch you moved meanwhile is skipped and noted in
  the release notes). The PR on GitHub then shows the rebase.
- Other PRs (a third-party head that is not ours to push): the agent squashes
  the PR by hand onto the integration worktree (the script's resume path:
  `PR #N: <title>` with the usual `Squashed from` line). That adaptation
  lives only in this round's build.

Conflict resolutions in CI come only from the committed `N-resolve.patch`
files; the workflow keeps no rerere cache. The host's rerere cache and manual
runs are unchanged.

## 6. Testing

- Script: new cases in the existing `integration.test.sh` (real Git repos,
  `gh` stubbed on `PATH`): the overrides select config, cache and base; the
  PR author override replaces the `gh` login; a PR branch that does not replay
  onto the tag stops `rebuild` with its PR named in the log, and a hand squash
  committed in the worktree lets the next `rebuild` continue.
- Workflow: one `workflow_dispatch` round with `force=true` on the current tag
  (`v18.18.9`), observed end to end. It is also the first deploy candidate
  for the host: the release's `omp-linux-x64` replaces the manual
  `95bee5c0de` build after your go-ahead.
- omp-web: component and unit tests above, plus a manual install of the fork
  release on this host after your go-ahead.

## Rollout order

1. Script overrides and their tests (this repo).
2. `omp.yml` `workflow_call` trigger, `ci/prompts/omp-repair.md`,
   `omp-auto.yml`.
3. Secrets `OMP_FORK_TOKEN`, `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` (added
   2026-11-11); first dispatched round.
4. omp-web PR: omp update source (3), pre-release channel (3b), GitHub token
   (3c).
