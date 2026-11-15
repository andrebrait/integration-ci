#!/usr/bin/env bash
# A repair artifact must replay added, modified, and deleted fixups together.
set -euo pipefail
collector="$(cd "$(dirname "$0")" && pwd)/collect-round.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
git init -q -b main "$tmp/round"
git init -q -b fork-ci "$tmp/round/ci"
cd "$tmp/round/ci"
mkdir -p config/fixups
printf 'obsolete\n' > config/fixups/deleted.patch
printf 'old\n' > config/fixups/modified.patch
printf 'staged old\n' > config/fixups/staged.patch
git add .
git commit -qm baseline
git clone -q . "$tmp/published"
rm config/fixups/deleted.patch
printf 'new\n' > config/fixups/modified.patch
printf 'staged new\n' > config/fixups/staged.patch
git add config/fixups/staged.patch
printf 'added\n' > config/fixups/added.patch
cd ..
INTEGRATION_BASE=unused bash "$collector" "$tmp/out"
git -C "$tmp/published" apply --index "$tmp/out/fixups.patch"
test ! -e "$tmp/published/config/fixups/deleted.patch"
cmp ci/config/fixups/modified.patch "$tmp/published/config/fixups/modified.patch"
cmp ci/config/fixups/staged.patch "$tmp/published/config/fixups/staged.patch"
cmp ci/config/fixups/added.patch "$tmp/published/config/fixups/added.patch"
echo 'PASS: repair artifact replays added, modified, staged, and deleted fixups'
