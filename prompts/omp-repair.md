# Repair one omp auto-integration round

You run unattended in GitHub Actions. Nobody will answer questions. Finish the
round or stop and explain why.

## The round

An omp release (tag in `failure.json`, field `tag`) is being rebuilt as the
release plus our carried pull requests, one squashed commit per PR. The round
stopped. `failure.json` (below) says where:

- `step: "rebuild"`: `integration rebuild` stopped (a conflict, a PR branch
  that does not replay onto the tag, a fixup that no longer applies, or
  `FORMAT_CMD` failing). `log` holds the script's last lines.
- `step: "build"`: the rebuilt branch failed `BUILD_CMD` or `TEST_CMD`.

## Layout

- `$GITHUB_WORKSPACE`: clone of `andrebrait/oh-my-pi`, remotes `origin`
  (the fork) and `upstream` (`can1357/oh-my-pi`). Do not commit here.
- `$GITHUB_WORKSPACE/ci`: checkout of `andrebrait/integration-ci`. The script
  is `ci/integration`; the config is `ci/config/root--git--oh-my-pi.sh`
  (`BUILD_CMD`, `TEST_CMD`, `FORMAT_CMD`, `EXTRA_PRS`, `STACKED_PRS`); fixups
  are under `ci/config/fixups/root--git--oh-my-pi/`.
- `$INTEGRATION_WT`: the `integration` worktree, where every squash happens.
- The environment already sets `INTEGRATION_SLUG`, `INTEGRATION_CONFIG_DIR`,
  `INTEGRATION_CACHE_DIR`, `INTEGRATION_BASE`, `INTEGRATION_PR_AUTHOR` and
  `INTEGRATION_HEAD_PREFIX=refs/rebased`. Run the script as
  `ci/integration rebuild "$GITHUB_WORKSPACE"`.

Start by running `ci/integration rebuild "$GITHUB_WORKSPACE"` once to see the
failure yourself.

## How to fix each kind of stop

Every PR is built on the release tag. Never base a PR on a newer upstream.

1. **A PR branch does not replay onto the tag** ("replaying ... failed"):
   every carried PR is a branch of the fork (our own PRs and the `EXTRA_PRS`
   carry branches). Rebase that branch onto the tag in a scratch worktree,
   resolving conflicts so the PR keeps its intent on this release:
   `git worktree add --detach /tmp/rb-<branch> origin/<branch>`, then
   `git -C /tmp/rb-<branch> rebase --onto <tag> <merge-base> HEAD`.
   Store the result as `git update-ref refs/rebased/<branch> <sha>` and
   re-run `rebuild`; it uses that ref instead of `origin/<branch>`. The
   workflow pushes the rebased branch after the build passes.
2. **A squash conflicts with the PRs before it**: resolve the conflict in
   `$INTEGRATION_WT`, apply the PR's fixups as the message says, then
   `git commit -m "PR #<N>: <title>" -m "Squashed from origin/<branch> (<sha of the head you used>) onto <tag>."`
   and re-run `rebuild`; it resumes with the next PR. Then save the exact
   resolution so the next run replays it: `N-resolve.patch` in the fixups
   directory, the diff from the conflicted file (with markers) to your
   resolved file, produced with `git diff --full-index`. The script checks
   its preimage hash, so generate it from the real marker file.
3. **A fixup no longer applies**: update `N-<name>.patch` so it applies to
   the squash and keeps its purpose; delete it when the PR or upstream now
   does what it did.
4. **`FORMAT_CMD` failed**: fix the cause in the squash, run the formatter,
   commit as in item 2.
5. **`BUILD_CMD` or `TEST_CMD` failed**: reproduce in `$INTEGRATION_WT`
   (`source ci/config/root--git--oh-my-pi.sh`, then `eval "$BUILD_CMD"` and
   `eval "$TEST_CMD"`). Fix the PR squash that broke it with a new or
   updated fixup patch `N-<short-name>.patch` (a `git diff --full-index` the
   squash applies with `git apply --3way`), then re-run `rebuild` from
   scratch (`git -C "$INTEGRATION_WT" checkout -q -B integration origin/integration`
   first) so the fixup is part of the squash.

After any fix, run `rebuild` until it completes, then run `BUILD_CMD` and
`TEST_CMD` in `$INTEGRATION_WT` and make them pass.

## Rules

- Never delete, skip, weaken or `.skip` a test, and never edit a test's
  expectations to match broken behaviour. Never drop a PR from the round
  (no `SKIP_PRS`, no editing `EXTRA_PRS`).
- Change only: commits on the `integration` branch, `refs/rebased/*`, and
  files under `ci/config/fixups/root--git--oh-my-pi/`. Do not edit the
  script, the config file or the workflows.
- Do not push anything and do not open pull requests or issues. The workflow
  publishes your result after an independent build passes.
- Write `$RUNNER_TEMP/repair-notes.md` before you exit: what stopped the
  round, what you changed and why, per PR. If you cannot finish, write why
  there, leave the worktree as it is, and exit non-zero.
- Finished means: `rebuild` completed, `BUILD_CMD` and `TEST_CMD` pass, and
  `git -C "$INTEGRATION_WT" status --porcelain` is empty.
