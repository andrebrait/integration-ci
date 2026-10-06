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

## Downloads

Each project has one release named after it (for example
[`oh-my-pi`](https://github.com/andrebrait/integration-ci/releases/tag/oh-my-pi)).
Every green build adds an asset named
`<project>-<UTC timestamp>-<commit>.zip`, for example
`oh-my-pi-20261006T161502Z-c578419926.zip`, and only the newest 10 are kept.
Each zip holds the build and a
`RELEASE.md` naming the integration commit, the upstream base, and the carried
pull requests.

| Release | Zip contents |
| --- | --- |
| [`oh-my-pi`](https://github.com/andrebrait/integration-ci/releases/tag/oh-my-pi) | `omp` binary for Linux x64; needs glibc 2.39 or newer and a CPU with AVX2 (only the modern native addon is built) |
| [`caveman`](https://github.com/andrebrait/integration-ci/releases/tag/caveman) | `npm pack` of `@caveman-ai/pi` |
| [`codegraph`](https://github.com/andrebrait/integration-ci/releases/tag/codegraph) | `npm pack` of `@colbymchenry/codegraph` |
| [`superpowers`](https://github.com/andrebrait/integration-ci/releases/tag/superpowers) | `npm pack` of `superpowers` |
| [`ponytail`](https://github.com/andrebrait/integration-ci/releases/tag/ponytail) | `npm pack` of `@dietrichgebert/ponytail` |
| [`graphify`](https://github.com/andrebrait/integration-ci/releases/tag/graphify) | wheel and sdist of `graphifyy` |
| [`ompweb`](https://github.com/andrebrait/integration-ci/releases/tag/ompweb) | `npm pack` of `@kahme247/ompweb` plus its `package-lock.json` |

Builds run carried pull requests, including some by other authors. Only green
builds seed the build cache, but a passing pull request's code ships in the
build like any other change.

`<project>-latest.zip` is always a copy of the newest build, so its URL never
changes:

```sh
curl -fLO https://github.com/andrebrait/integration-ci/releases/download/oh-my-pi/oh-my-pi-latest.zip
```

## Installation

The script and configuration are used through two symlinks:

```sh
ln -sfn /root/git/integration-ci/config ~/.config/integration
ln -sfn /root/git/integration-ci/integration ~/.local/bin/integration
```
