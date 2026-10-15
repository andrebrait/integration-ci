#!/usr/bin/env bash
# Pin zero-gx master to a deployed pfBlockerNG/graphify integration head.
# Usage: zero-gx-graphify-pin.sh <sha> <version>
# Runs from graphify's POST_CMD, after DEPLOY_CMD installed that head. zero-gx's CI rebuilds
# graphify-out/graph.json with the pin in tools/ensure-graphify.sh and fails on any difference,
# so the pin and the graph move together: rewrite the pin in a fresh clone, rebuild the graph
# with the deployed build, then open a PR and merge it. Needs no local zero-gx checkout.
set -euo pipefail

sha="${1:?usage: $0 <sha> <version>}"
version="${2:?usage: $0 <sha> <version>}"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "pin: '$sha' is not a full sha" >&2; exit 2; }
repo=BRAITG/zero-gx
branch="agent/graphify-pin-${sha:0:8}"
file=tools/ensure-graphify.sh

wt="$(mktemp -d)"
trap 'rm -rf "$wt"' EXIT
git clone --quiet "https://github.com/$repo.git" "$wt"
cd "$wt"

old="$(grep -o 'pfBlockerNG/graphify@[0-9a-f]\{40\}' "$file" | head -n1)"
old="${old#*@}"
[ -n "$old" ] || { echo "pin: no graphify pin found in $file" >&2; exit 1; }
if [ "$old" = "$sha" ]; then
	echo "pin: zero-gx master already pins ${sha:0:8}"
	exit 0
fi

git switch --quiet -c "$branch"
sed -i.orig "s/$old/$sha/" "$file" && rm "$file.orig"
PYTHONHASHSEED=0 graphify update . >&2
git add -- "$file" graphify-out/graph.json
# The hook would only repeat the rebuild above.
git commit --quiet --no-verify -m "chore: bump Graphify pin to integration head ${sha:0:8} ($version)"
git push --quiet -u origin "HEAD:refs/heads/$branch"
url="$(gh pr create --repo "$repo" --base master --head "$branch" \
	--title "chore: bump Graphify pin to integration head ${sha:0:8} ($version)" \
	--body "Automated pin bump from the integration deploy: ${old:0:8} -> ${sha:0:8} ($version), with graphify-out/graph.json rebuilt by that build.")"
gh pr merge "$url" --repo "$repo" --rebase --delete-branch
echo "pin: merged $url (${old:0:8} -> ${sha:0:8})"
