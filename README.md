# integration-ci

Tooling for the integration branches of André Brait's forks. An integration
branch is the upstream base plus one squashed commit per open pull request,
recreated from scratch on every rebuild so merged or closed pull requests drop
out automatically.

## Contents

- `integration`: the driver script. Run `integration` with no arguments for
  usage; the comment block at the top of the script documents every
  subcommand and configuration key.
- `config/<slug>.sh`: per-project configuration, where the slug is the
  project's checkout path with `/` replaced by `--`
  (for example `root--git--oh-my-pi.sh`). Helper scripts called from a
  project's hooks, such as the graphify pin scripts, live beside them.
- `.github/workflows/<project>.yml`: GitHub Actions workflows that build and
  test a dispatched integration commit. When a project's configuration sets
  `CI_REPO` and `CI_WORKFLOW`, `integration build` dispatches the workflow,
  waits for it, and downloads its artifact instead of building locally.
- `pr-watcher/`: a service that polls pull requests and sends each one's
  activity to the omp session mapped to it. See [pr-watcher](#pr-watcher).

## Downloads

Each project has one release named after it (for example
[`oh-my-pi`](https://github.com/andrebrait/integration-ci/releases/tag/oh-my-pi)).
Every green build adds an asset named
`<project>-<UTC timestamp>-<commit>.zip`, for example
`caveman-20261006T211531Z-a95b7d5e4e.zip`, and only the newest 10 are kept.
oh-my-pi builds every platform, so it publishes one zip per platform instead:
`oh-my-pi-<UTC timestamp>-<commit>-<platform>.zip`. A commit is built and
published only once. Each zip holds the build and a `RELEASE.md` naming the
integration commit, the upstream base, and the carried pull requests.

| Release | Zip contents |
| --- | --- |
| [`oh-my-pi`](https://github.com/andrebrait/integration-ci/releases/tag/oh-my-pi) | `omp` (or `omp.exe`) for `linux-x64`, `linux-arm64`, `darwin-x64`, `darwin-arm64`, `win32-x64` or `win32-arm64`; each smoke-tested on its own platform. macOS builds are ad-hoc signed, not notarized: after a browser download, run `xattr -d com.apple.quarantine omp` once |
| [`caveman`](https://github.com/andrebrait/integration-ci/releases/tag/caveman) | `npm pack` of `@caveman-ai/pi` |
| [`codegraph`](https://github.com/andrebrait/integration-ci/releases/tag/codegraph) | `npm pack` of `@colbymchenry/codegraph` |
| [`superpowers`](https://github.com/andrebrait/integration-ci/releases/tag/superpowers) | `npm pack` of `superpowers` |
| [`ponytail`](https://github.com/andrebrait/integration-ci/releases/tag/ponytail) | `npm pack` of `@dietrichgebert/ponytail` |
| [`graphify`](https://github.com/andrebrait/integration-ci/releases/tag/graphify) | wheel and sdist of `graphifyy` |
| [`ompweb`](https://github.com/andrebrait/integration-ci/releases/tag/ompweb) | `npm pack` of `@kahme247/ompweb` plus its `package-lock.json` |

Builds run carried pull requests, including some by other authors. Only green
builds seed the build cache, but a passing pull request's code ships in the
build like any other change.

`<project>-latest.zip` (for oh-my-pi, `oh-my-pi-latest-<platform>.zip`) is always
a copy of the newest build, so its URL never changes:

```sh
curl -fLO https://github.com/andrebrait/integration-ci/releases/download/oh-my-pi/oh-my-pi-latest-darwin-arm64.zip
```

## Installation

The script and configuration are used through two symlinks:

```sh
ln -sfn /root/git/integration-ci/config ~/.config/integration
ln -sfn /root/git/integration-ci/integration ~/.local/bin/integration
```


## RTLPlayground

`config/Users--andre--git--RTLPlayground.sh` integrates all this account's open
upstream PRs, plus the listed third-party carries and fork-only drafts.
Install the symlinks above using `/Users/andre/git/integration-ci` on this host;
macOS needs Homebrew Bash and `brew install flock`. Keep `origin` and add the
upstream alias if absent:

```sh
git -C /Users/andre/git/RTLPlayground remote add upstream https://github.com/logicog/RTLPlayground.git
```

After feature edits are committed and pushed and the integration worktree is
clean, refresh PR/carry heads, recreate the integration, then publish it:

```sh
/opt/homebrew/bin/bash ~/.local/bin/integration prs /Users/andre/git/RTLPlayground
/opt/homebrew/bin/bash ~/.local/bin/integration rebuild /Users/andre/git/RTLPlayground
/opt/homebrew/bin/bash ~/.local/bin/integration push /Users/andre/git/RTLPlayground
```

For the first migration only, use `INTEGRATION_DROP_NON_PR=1` on `rebuild`
after preserving old integration-only changes in PR branches or config fixups.
The driver backs up the old branch. A completed rebuild starts from upstream
each pass; interrupted detached rebuilds resume after conflicts are resolved
and committed with the requested `PR #N:` (or `PR owner/repo#N:`) subject. Resolve cross-PR adaptations
in `config/fixups/Users--andre--git--RTLPlayground/N-name.patch`, not only in
integration commits. `588:600` intentionally composes the TX carries; third-party
authorship and original PR heads are preserved. Closed/merged carries drop out
only when GitHub reports them closed/merged, not because the carry lacks its own PR.

`EXTRA_PRS` and `STACKED_PRS` also take repo-qualified IDs, `owner/repo#N`, for
PRs in another repository (for example a draft opened in the fork); a bare `N`
still means `UPSTREAM#N`, so `2=carry/pr-2` and `andrebrait/RTLPlayground#2=draft-2`
can both be listed. A qualified ID is looked up in its own repository, and its
branch is the `FORK_REMOTE` copy that is rebased and squashed. A separate
third-party source head is never pushed. Stack with `andrebrait/RTLPlayground#2:589` or
`andrebrait/RTLPlayground#3:andrebrait/RTLPlayground#2`. A qualified squash is
committed as `PR andrebrait/RTLPlayground#2: title`, and its fixups and
`-resolve.patch` use the whole ID as the file prefix, nested by owner:
`config/fixups/Users--andre--git--RTLPlayground/andrebrait/RTLPlayground#2-resolve.patch`.
At one stack depth, bare IDs run before qualified ones, then by PR number.

`N-resolve.patch` is separate from ordinary fixups: it records the exact
conflict-marker preimages and reviewed resolutions using full-index hashes.
Every unresolved path must be covered, no other path may be changed, and every
preimage hash must match before anything is staged. Resolution uses strict
`git apply --index` (no three-way fallback); changed conflicts or leftover markers
stop for review. Capture marker blobs with `git hash-object -w` before resolving,
then generate the full-index diff between those blobs and the resolved files.
Ordinary `N-name.patch` fixups still run afterward with `git apply --3way`.
The warning-details draft's ordinary fixup also adapts the carries to upstream's
compile-time port bounds, preserves the host fixture profiles, and keeps the
SNMP-enabled integration within the internal RAM and code-bank limits.

There are deliberately no RTL build/test/deploy hooks or workflow. Do not use
`all`; build and validate firmware manually before publishing. Driver regression
check (temporary local Git fixtures, no network): `bash integration.test.sh`.

## pr-watcher

`pr-watcher/pr-watcher.mjs` polls GitHub pull requests through `gh` and
notifies the omp session mapped to each one by sending it a prompt through
omp-web's agent API (`POST /api/agent/<session id>`). It needs Node.js 24 or
newer, an authenticated `gh`, and a running omp-web.

- **Watches:** managed with the `pr-watcher` command, never by editing files.
  A session id is the omp session UUID, as shown in omp-web's URL.

  ```sh
  pr-watcher add OWNER/REPO#N --session ID [--ignore-author LOGIN]...
  pr-watcher remove OWNER/REPO#N [--session ID]   # every session when omitted
  pr-watcher list [--json]
  ```

  A new watch is picked up on the next cycle, which records a baseline: it
  reports only activity after that first poll (up to one interval after
  `add`). Invalid input exits with status 2 and adds or removes no watch.

  Only omp-web sessions can be watched. omp-web delivers by resuming the
  session in its own omp process, so a session open in a terminal omp would
  end up with two agents running on it. `add` therefore refuses, with status
  2, when it runs inside an omp process that omp-web did not start (any omp
  ancestor without `--mode rpc-ui`). Run from a plain shell, `add` cannot tell
  and accepts the watch. A session that omp-web started and that is later
  reopened in a terminal is not detected: remove its watch first.
- **What it reports:** new comments and reviews (except the `gh` user's own
  and ignored authors), edits to them (bots such as CodeRabbit post a finished
  review by editing an earlier comment), a terminal CI result (`SUCCESS`,
  `FAILURE`, `ERROR`) once per head commit, and the PR being merged or closed.
  Excerpts leave out HTML comments.
- **How long it watches:** every cycle until the PR is merged or closed, so
  bot re-reviews after a push and later maintainer or contributor comments
  are still delivered. Once the merged or closed notice is delivered, the watch
  ends by itself.
- **How it delivers:** an idle session starts a turn; a session in the middle
  of a turn gets the update as a follow-up; a session with no omp process is
  resumed by omp-web first. A session running a shell command or compacting is
  retried on the next cycle. An update counts as delivered only after omp-web
  accepts it, so a failed delivery is retried. Updates are appended to the
  conversation and never change the system prompt.
- **Data:** watches and delivery state live in one data directory and survive
  restarts. The service and the `pr-watcher` command must use the same one:
  keep the default, or set `PR_WATCHER_DATA_DIR` for both.
- **Settings** (environment, read at service start):

  | Variable | Default | Meaning |
  | --- | --- | --- |
  | `PR_WATCHER_DATA_DIR` | `${XDG_STATE_HOME:-~/.local/state}/pr-watcher` | Data directory |
  | `PR_WATCHER_OMPWEB_URL` | `http://127.0.0.1:30185` | omp-web base URL |
  | `PR_WATCHER_INTERVAL_SECONDS` | `60` | Poll interval |
  | `PR_WATCHER_IGNORE_AUTHORS` | empty | Comma-separated logins never reported |

- **Authentication:** the watcher sends `OMP_WEB_TRUSTED_HEADER_SECRET` as the
  `X-Omp-Web-Auth` header, and omp-web accepts requests whose header hashes to
  its `OMP_WEB_TRUSTED_HEADER_SHA256`. The unit reads the secret and the
  settings from `/opt/omp-deployment/pr-watcher.env` (mode `0600`), never
  omp-web's own environment file, so omp sessions cannot inherit the secret.

```sh
systemctl enable --now /root/git/integration-ci/pr-watcher/pr-watcher.service
ln -sfn /root/git/integration-ci/pr-watcher/pr-watcher.mjs ~/.local/bin/pr-watcher
journalctl -u pr-watcher -f
```

`pr-watcher --once` runs a single cycle; `node --test 'pr-watcher/*.test.mjs'`
runs the tests. The first open of the data directory, by the service or by any
`pr-watcher` command, imports the watches from the previous
`~/.config/pr-watcher/config.json` and its delivery state, then renames both
files with a `.migrated` suffix. Upgrade by restarting the service before
anything runs the new command: a previous-version service still running after
the import finds no watches. To roll back, stop the service, delete the data
directory, rename the `.migrated` files back and run the previous version;
watches added since are lost, and updates delivered since the import are
delivered again.
