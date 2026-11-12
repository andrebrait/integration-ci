#!/usr/bin/env bash
# commit-fixups.sh <fixups.patch> <message> — run in a checkout of this repo whose
# `origin` can push main. Commits a stage's fixup/resolution changes so later rounds
# replay them without an agent. A patch that no longer applies to main fails the job.
set -euo pipefail
patch="${1:?usage: commit-fixups.sh <fixups.patch> <message>}"
[ -s "$patch" ] || { echo "commit-fixups: no fixup changes"; exit 0; }
git apply --index "$patch"
git -c user.name="omp auto-integration" -c user.email="omp-auto@users.noreply.github.com" commit -q -m "$2"
git push -q origin HEAD:main
echo "commit-fixups: pushed $(git rev-parse --short HEAD) to main"
