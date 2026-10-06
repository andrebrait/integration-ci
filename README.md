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

## Installation

The script and configuration are used through two symlinks:

```sh
ln -sfn /root/git/integration-ci/config ~/.config/integration
ln -sfn /root/git/integration-ci/integration ~/.local/bin/integration
```
