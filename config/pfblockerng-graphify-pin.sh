#!/usr/bin/env bash
# Pin pfBlockerNG devel to a deployed pfBlockerNG/graphify integration head.
# Usage: pfblockerng-graphify-pin.sh <sha> <version>
# Runs from graphify's POST_CMD. The sha must already be on the fork (integration
# pushes on every green build, before deploy). Mechanical: rewrite the pin on top
# of origin/devel, relock graphifyy only, commit (pre-commit refreshes graph.json),
# push devel, then fast-forward the main checkout.
# The commit is made in a scratch worktree so uncommitted work in the main
# checkout never blocks or leaks into it.
set -euo pipefail

sha="${1:?usage: $0 <sha> <version>}"
version="${2:?usage: $0 <sha> <version>}"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "pin: '$sha' is not a full sha" >&2; exit 2; }
repo="${PFB_REPO:-/root/git/pfBlockerNG}"
files=(pyproject.toml uv.lock tests/shell/agent_graphify_merge_driver_spec.sh)

git -C "$repo" fetch --quiet origin devel
wt="$(dirname "$repo")/.$(basename "$repo")_worktrees/graphify-pin"
git -C "$repo" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
git -C "$repo" worktree add --quiet --detach "$wt" origin/devel
trap 'git -C "$repo" worktree remove --force "$wt"' EXIT
cd "$wt"

old="$(grep -o 'pfBlockerNG/graphify@[0-9a-f]\{40\}' pyproject.toml | head -n1)"
old="${old#*@}"
[ -n "$old" ] || { echo "pin: no graphify pin found in pyproject.toml" >&2; exit 1; }
if [ "$old" = "$sha" ]; then
	echo "pin: pfBlockerNG devel already pins ${sha:0:8}"
else
	sed -i "s/$old/$sha/g" pyproject.toml tests/shell/agent_graphify_merge_driver_spec.sh
	uv lock --quiet --upgrade-package graphifyy
	git add -- "${files[@]}"
	git commit --quiet -m "agent: bump Graphify pin to integration head ${sha:0:8} ($version)"
	git push --quiet origin HEAD:refs/heads/devel
	echo "pin: pushed $(git rev-parse --short HEAD) to pfBlockerNG devel (${old:0:8} -> ${sha:0:8})"
fi

if [ "$(git -C "$repo" branch --show-current)" = devel ] && git -C "$repo" merge --ff-only --quiet origin/devel 2>/dev/null; then
	echo "pin: main checkout fast-forwarded to $(git -C "$repo" rev-parse --short HEAD)"
else
	echo "pin: main checkout not fast-forwarded (not on devel, or local edits overlap); run 'git pull --ff-only' there when ready" >&2
fi
