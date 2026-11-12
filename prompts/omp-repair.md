# Repair one stage of an omp auto-integration round

You run unattended in GitHub Actions. Nobody will answer questions. Finish the
stage or stop and explain why.

## The round

An omp release (`tag` in `failure.json` below) is rebuilt as the release plus our
carried pull requests. A round has three stages, and one of them stopped
(`step` in `failure.json`):

1. `rebase`: every carried PR branch is rebased onto the release tag.
   `rebase` lists each PR as `unchanged`, `rebased`, `failed` or `skipped`
   (a stacked child of a failed parent). Branches that rebased were already
   pushed.
2. `integrate`: `integration rebuild` squashes every PR, in order, onto the tag
   as one commit each, applying fixups and resolution patches, then runs
   `FORMAT_CMD`.
3. `build`: the integrated branch failed `BUILD_CMD` or `TEST_CMD`.

`log` holds the tail of the failing output.

## Layout

- `$GITHUB_WORKSPACE`: clone of `andrebrait/oh-my-pi`, remotes `origin` (the
  fork) and `upstream` (`can1357/oh-my-pi`).
- `$GITHUB_WORKSPACE/ci`: checkout of `andrebrait/integration-ci`. The script is
  `ci/integration`; the config is `ci/config/root--git--oh-my-pi.sh`
  (`BUILD_CMD`, `TEST_CMD`, `FORMAT_CMD`, `EXTRA_PRS`, `STACKED_PRS`); fixups and
  resolutions live in `ci/config/fixups/root--git--oh-my-pi/`.
- `$INTEGRATION_WT`: the `integration` worktree, where squashes happen.
- The environment sets `INTEGRATION_SLUG`, `INTEGRATION_CONFIG_DIR`,
  `INTEGRATION_CACHE_DIR`, `INTEGRATION_BASE` (the tag), `INTEGRATION_PR_AUTHOR`
  and `INTEGRATION_HEAD_PREFIX=refs/rebased`. Run the script as
  `ci/integration <rebase|rebuild> "$GITHUB_WORKSPACE"`.

Start by re-running the failing stage once to see the failure yourself.

## What you may change

The workflow publishes exactly these after you exit, so they are your only
outputs:

- `refs/rebased/<branch>`: a PR branch rebased onto the tag. It is pushed to
  that branch of the fork (an open upstream PR moves with it). `rebuild` uses
  it instead of `origin/<branch>`.
- The `integration` branch in `$INTEGRATION_WT`.
- Files under `ci/config/fixups/root--git--oh-my-pi/`: committed to
  integration-ci so later rounds pass on their own.

Do not push, open pull requests or issues, or edit the script, the config file,
the prompts or the workflows.

## How to fix each stage

Every PR is built on the release tag. Never base a PR on a newer upstream.

### `rebase`

For each `failed` and `skipped` PR, parents first: rebase its branch onto the
tag (a stacked child onto its parent's new head) in a scratch worktree,
resolving conflicts so the PR keeps its intent on this release. Replay only the
PR's own commits, those after its merge base with `upstream/main`:

    git worktree add --detach /tmp/rb-<branch> origin/<branch>
    git -C /tmp/rb-<branch> rebase --onto <tag> "$(git merge-base upstream/main origin/<branch>)"
    git update-ref refs/rebased/<branch> "$(git -C /tmp/rb-<branch> rev-parse HEAD)"

Done when every carried PR is on the tag: `ci/integration rebase` would find
nothing left to do for the branches you rebased.

### `integrate`

- **A PR branch does not replay onto the tag**: rebase it as under `rebase`.
- **A squash conflicts with the PRs before it**: resolve it in
  `$INTEGRATION_WT`, then save the exact resolution as `N-resolve.patch`: the
  `git diff --full-index` from the conflicted file (with markers) to your
  resolved file. The script checks its preimage hash, so produce it from the
  real marker file. Re-run `rebuild` from scratch
  (`git -C "$INTEGRATION_WT" checkout -q -B integration origin/integration`
  first) to prove the patch replays.
- **A fixup no longer applies**: update `N-<name>.patch` so it applies to the
  squash and keeps its purpose; delete it when the PR or upstream now does
  what it did.
- **`FORMAT_CMD` failed**: fix the cause with a fixup patch, as above.

Done when a from-scratch `rebuild` completes.

### `build`

Reproduce in `$INTEGRATION_WT`: `source ci/config/root--git--oh-my-pi.sh`, then
`eval "$BUILD_CMD"` and `eval "$TEST_CMD"`. Fix the PR that broke it: change its
branch (`refs/rebased/<branch>`) when the PR itself is wrong on this release, or
add a fixup patch `N-<short-name>.patch` (a `git diff --full-index` that the
squash applies with `git apply --3way`) when the break comes from combining PRs.
Then re-run `rebuild` from scratch and both commands until they pass.

## Rules

- Never delete, skip, weaken or `.skip` a test, and never edit a test's
  expectations to match broken behaviour. Never drop a PR from the round (no
  `SKIP_PRS`, no editing `EXTRA_PRS`).
- Write `$RUNNER_TEMP/repair-notes.md` before you exit: what stopped the stage,
  what you changed and why, per PR. If you cannot finish, write why there and
  exit non-zero.
- The workflow checks your work by rebuilding from scratch from the saved
  branches and patches alone; anything that lives only in a worktree is lost.
