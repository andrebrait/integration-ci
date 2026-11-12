#!/usr/bin/env bash
# push-rebased.sh <rebase.tsv> — run inside a clone whose `origin` can push to the fork.
# Force-pushes each `rebased` row's refs/rebased/<branch> to <branch>, leased on the
# sha the round started from, so a branch someone moved meanwhile is never overwritten.
# Rows: PR, branch, status, old sha, new sha (the `integration rebase` format).
set -euo pipefail
tsv="${1:?usage: push-rebased.sh <rebase.tsv>}"
[ -s "$tsv" ] || exit 0
while IFS=$'\t' read -r num branch status old new; do
	[ "$status" = rebased ] || continue
	[ "$(git rev-parse "refs/rebased/$branch")" = "$new" ] || { echo "push-rebased: refs/rebased/$branch is not $new" >&2; exit 1; }
	git push -q --force-with-lease="refs/heads/$branch:$old" origin "refs/rebased/$branch:refs/heads/$branch"
	echo "push-rebased: PR $num $branch -> ${new:0:10}"
done < "$tsv"
