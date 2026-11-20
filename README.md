# integration-ci

Tooling for the integration branches of André Brait's forks. An integration
branch is the upstream base plus one squashed commit per open pull request,
recreated from scratch on every rebuild so merged or closed pull requests drop
out automatically.

oh-my-pi is retired from this flow. Upstream release tags merge into
`ompweb-dev/oh-my-pi` branch `oml` (`.github/workflows/omp-sync.yml`); a push
to `oml` builds and publishes the fork release. New patches are ordinary
commits on `oml`. Closing an upstream pull request does not remove a patch
already on `oml`; removing one takes an explicit revert commit there.
`config/root--git--oh-my-pi.sh` exits rather than rebuild. The script below
still serves other projects.


## Contents

- `integration`: the driver script. Run `integration` with no arguments for
  usage; the comment block at the top of the script documents every
  subcommand and configuration key.
- `config/<slug>.sh`: per-project configuration, where the slug is the
  project's checkout path with `/` replaced by `--`
  (for example `root--git--oh-my-pi.sh`). Helper scripts called from a
  project's hooks live beside them.
- `.github/workflows/<project>.yml`: GitHub Actions workflows that build and
  test a dispatched integration commit. When a project's configuration sets
  `CI_REPO` and `CI_WORKFLOW`, `integration build` dispatches the workflow,
  waits for it, and downloads its artifact instead of building locally.

Repair artifacts include all fixup changes against the checked-out commit,
including staged changes and deletions. Run `bash scripts/collect-round.test.sh`
to verify that a publishing checkout can replay the complete repair.

## Downloads

Each project has one release named after it. The oh-my-pi release in this
repo is no longer updated; install omp from `ompweb-dev/oh-my-pi` releases
(`v<version>-int.<stamp>.g<sha7>`). Every green build of a project that still
uses this flow adds an asset named
`<project>-<UTC timestamp>-<commit>.zip`, for example
`ompweb-20261110T234907Z-e43f567871.zip`, and only the newest 10 are kept.
Each zip holds the build and a `RELEASE.md` naming the integration commit,
the upstream base, and the carried pull requests.

| Release | Zip contents |
| --- | --- |
| [`oh-my-pi`](https://github.com/andrebrait/integration-ci/releases/tag/oh-my-pi) | Retired. Fork releases on `ompweb-dev/oh-my-pi` replaced this row. |
| [`ompweb`](https://github.com/andrebrait/integration-ci/releases/tag/ompweb) | `npm pack` of `@kahme247/ompweb` plus its `package-lock.json`; pending retirement once omp-web's GUI pre-release channel deploys this host |

To install or update omp from the newest `ompweb-dev/oh-my-pi` release on macOS
arm64 or Linux x64/arm64, run `scripts/omp-fork-update`. It verifies the binary
against the release's `SHA256SUMS.txt` and replaces `${OMP_INSTALL:-~/.local/bin/omp}` atomically.

Builds run carried pull requests, including some by other authors. Only green
builds seed the build cache, but a passing pull request's code ships in the
build like any other change.

The oh-my-pi Darwin addon jobs prefetch Apple's SDK package with curl into
Bazel's `--distdir`, avoiding the Apple CDN's rejection of Bazel's downloader.
The URL and SHA256 come from the dispatched source's `sdk.bzl`. GitHub runners get
HTTP 403 from `swcdn.apple.com`, so the job first downloads
`<sha256>.pkg` from this repo's
[`apple-sdk`](https://github.com/andrebrait/integration-ci/releases/tag/apple-sdk)
release and only then falls back to Apple; the prefetch and Bazel both check the
hash. When `sdk.bzl` pins a new SDK, seed the mirror once, before dispatching:

```sh
f=$(grep -oP '^_URL = "\K[^"]+' bazel/toolchains/darwin/sdk.bzl)
h=$(grep -oP '^_SHA256 = "\K[^"]+' bazel/toolchains/darwin/sdk.bzl)
curl -fLo "$h.pkg" "$f" && echo "$h  $h.pkg" | sha256sum -c &&
  gh release upload apple-sdk "$h.pkg" -R andrebrait/integration-ci
```

Both macOS addons still use the Linux cross
toolchain, including the arm64 Foundation Models bridge, before platform smoke tests.

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
