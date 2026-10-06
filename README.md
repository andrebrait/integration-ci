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

Every green omp build is published as a release: `omp-<sha10>` for that
integration commit (the newest 10 are kept) and `omp-latest` for the newest one.
Each holds a Linux x64 (glibc) `omp` binary, `omp.sha256`, and `RELEASE.md`
listing the upstream base and the carried pull requests.

```sh
curl -fLO https://github.com/andrebrait/integration-ci/releases/download/omp-latest/omp
curl -fLO https://github.com/andrebrait/integration-ci/releases/download/omp-latest/omp.sha256
sha256sum -c omp.sha256 && chmod +x omp
```

## Installation

The script and configuration are used through two symlinks:

```sh
ln -sfn /root/git/integration-ci/config ~/.config/integration
ln -sfn /root/git/integration-ci/integration ~/.local/bin/integration
```
