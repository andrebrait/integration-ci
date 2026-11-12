#!/usr/bin/env bash
# publish-round.sh <dir> — publish a collect-round.sh directory to the fork. Runs no
# fork code: a blobless clone, the bundle, and pushes. Needs TOKEN (fork Contents and
# Workflows write), FORK, UPSTREAM and TAG. Pushes the rebased PR branches (leased),
# then integration to integration-candidate when the bundle carries it, and prints
# `sha=<integration sha>` for $GITHUB_OUTPUT in that case.
set -euo pipefail
dir="$(cd "${1:?usage: publish-round.sh <dir>}" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
[ -f "$dir/integration.bundle" ] || exit 0
repo="$(mktemp -d)"
cd "$repo"
git init -q
git remote add origin "https://x-access-token:$TOKEN@github.com/$FORK.git"
git remote add upstream "https://github.com/$UPSTREAM.git"
# Either remote serves any object a blobless clone lacks.
for r in origin upstream; do
	git config "remote.$r.promisor" true
	git config "remote.$r.partialclonefilter" blob:none
done
git fetch -q --filter=blob:none --no-tags upstream "refs/tags/$TAG:refs/tags/$TAG"
git bundle verify -q "$dir/integration.bundle"
git fetch -q "$dir/integration.bundle" 'refs/rebased/*:refs/rebased/*' 'refs/heads/integration:refs/heads/integration' 2>/dev/null ||
	git fetch -q "$dir/integration.bundle" 'refs/rebased/*:refs/rebased/*'
"$here/push-rebased.sh" "$dir/rebased.tsv"
if git rev-parse -q --verify refs/heads/integration >/dev/null; then
	sha="$(git rev-parse integration)"
	[ "$sha" = "$(jq -r .sha "$dir/round.json")" ]
	git push -q --force origin "integration:refs/heads/integration-candidate"
	echo "sha=$sha"
fi
