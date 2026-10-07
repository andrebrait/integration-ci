#!/usr/bin/env bash
# Pin leveret main to a deployed pfBlockerNG/graphify integration head.
# Usage: leveret-graphify-pin.sh <sha> <version>
# Runs from graphify's POST_CMD. The sha must already be on the fork (integration
# pushes on every green build, before deploy). Rewrites the pin in
# scripts/agent/ensure-graphify.sh and its shell spec on a scratch branch off
# origin/main, runs the shell suite, then opens a PR and rebase-merges it (the
# pre-commit hook refreshes graph.json). The scratch worktree keeps uncommitted
# work in the main checkout from blocking or leaking into the commit.
set -euo pipefail

sha="${1:?usage: $0 <sha> <version>}"
version="${2:?usage: $0 <sha> <version>}"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "pin: '$sha' is not a full sha" >&2; exit 2; }
repo="${LEVERET_REPO:-/root/git/leveret}"
files=(scripts/agent/ensure-graphify.sh tests/shell/agent_graphify_merge_driver_spec.sh)
branch="agent/graphify-pin-${sha:0:8}"

git -C "$repo" fetch --quiet origin main
wt="$(dirname "$repo")/.$(basename "$repo")_worktrees/graphify-pin"
git -C "$repo" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
git -C "$repo" worktree add --quiet -B "$branch" "$wt" origin/main
cleanup() {
	git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
	git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cd "$wt"

old="$(grep -o 'pfBlockerNG/graphify@[0-9a-f]\{40\}' scripts/agent/ensure-graphify.sh | head -n1)"
old="${old#*@}"
[ -n "$old" ] || { echo "pin: no graphify pin found in ensure-graphify.sh" >&2; exit 1; }
if [ "$old" = "$sha" ]; then
	echo "pin: leveret main already pins ${sha:0:8}"
	exit 0
fi

sed -i "s/$old/$sha/g" "${files[@]}"
sed -i "s/integration head at an immutable commit ([0-9.]*)/integration head at an immutable commit ($version)/" scripts/agent/ensure-graphify.sh
shellspec --shell "$(command -v dash)" tests/shell/ >&2
git add -- "${files[@]}"
git commit --quiet -m "agent: bump Graphify pin to integration head ${sha:0:8} ($version)"
git push --quiet -u origin "HEAD:refs/heads/$branch"
url="$(gh pr create --repo leveret-dev/leveret --base main --head "$branch" \
	--title "agent: bump Graphify pin to integration head ${sha:0:8} ($version)" \
	--body "Automated pin bump from integration deploy: ${old:0:8} -> ${sha:0:8} ($version). Shell suite green locally.")"
# From outside the checkout: inside it, --delete-branch also switches the worktree
# to main, which fails because the primary checkout already has main. Out here gh
# deletes only the remote branch; cleanup drops the local one.
(cd / && gh pr merge "$url" --repo leveret-dev/leveret --rebase --delete-branch)
echo "pin: merged $url (${old:0:8} -> ${sha:0:8})"

if [ "$(git -C "$repo" branch --show-current)" = main ] && git -C "$repo" pull --ff-only --quiet origin main 2>/dev/null; then
	echo "pin: main checkout fast-forwarded to $(git -C "$repo" rev-parse --short HEAD)"
else
	echo "pin: main checkout not fast-forwarded; run 'git pull --ff-only' there when ready" >&2
fi
