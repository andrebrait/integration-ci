#!/usr/bin/env bash
# collect-round.sh <out-dir> [integration] — run at the root of a stage's fork clone.
# Packs what a stage produced for a publishing job that runs no fork code:
#   integration.bundle  refs/rebased/* (and refs/heads/integration when asked), minus the tag
#   rebased.tsv         one `rebased` row per refs/rebased/<branch> (push-rebased.sh format)
#   fixups.patch        changes under ci/config/fixups, new files included
#   round.json          tag and integration sha (when integration is included)
set -euo pipefail
out="${1:?usage: collect-round.sh <out-dir> [integration]}"
tag="${INTEGRATION_BASE:?}"
mkdir -p "$out"
mapfile -t refs < <(git for-each-ref --format='%(refname)' refs/rebased/)
: > "$out/rebased.tsv"
for ref in "${refs[@]}"; do
	b="${ref#refs/rebased/}"
	printf -- '-\t%s\trebased\t%s\t%s\n' "$b" "$(git rev-parse "origin/$b")" "$(git rev-parse "$ref")" >> "$out/rebased.tsv"
done
[ "${2:-}" != integration ] || refs+=(refs/heads/integration)
if [ "${#refs[@]}" -gt 0 ]; then
	git bundle create "$out/integration.bundle" "${refs[@]}" "^$tag"
fi
if [ "${2:-}" = integration ]; then
	jq -n --arg tag "$tag" --arg sha "$(git rev-parse integration)" '{tag: $tag, sha: $sha}' > "$out/round.json"
fi
git -C ci add -N config/fixups
git -C ci diff -- config/fixups > "$out/fixups.patch"
