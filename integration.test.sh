#!/usr/bin/env bash
# Real Git repositories, fake GitHub listing: no network, builds, or deployment.
set -euo pipefail
DRIVER="$(cd "$(dirname "$0")" && pwd)/integration"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
export HOME="$TMP/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=IntegrationTest GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=IntegrationTest GIT_COMMITTER_EMAIL=test@example.invalid
mkdir -p "$HOME/.config/integration" "$TMP/bin"
export PATH="$TMP/bin:$PATH"
export ROWS="$TMP/rows"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == pr\ list* ]] || exit 2
cat "$ROWS"
SH
chmod +x "$TMP/bin/gh"
git init -q --bare "$TMP/upstream.git"
git init -q --bare "$TMP/fork.git"
git init -q -b main "$TMP/repo"
cd "$TMP/repo"
printf 'base\n' > base.txt
git add base.txt
git commit -qm base
BASE="$(git rev-parse HEAD)"
git remote add upstream "$TMP/upstream.git"
git remote add fork "$TMP/fork.git"
git push -q upstream main
git push -q fork main
git checkout -qb first
printf 'first\n' > first.txt
git add first.txt
git commit -qm first
git push -q fork first
git checkout -qb second main
printf 'second\n' > second.txt
git add second.txt
git commit -qm second
git push -q fork second
git checkout -q main
git branch integration
git push -q fork integration
git worktree add -q "$TMP/integration" integration
SLUG="${TMP#/}--repo"
SLUG="${SLUG//\//--}"
cat > "$HOME/.config/integration/$SLUG.sh" <<'SH'
FORK_REMOTE=fork
UPSTREAM=fixture/repo
BRANCH=integration
BASE=upstream/main
SH
printf '1\tfirst\tFirst change\n' > "$ROWS"
bash "$DRIVER" rebuild "$TMP/repo"
[[ "$(git rev-list --count "$BASE..integration")" == 1 ]]
# A completed pass must not resume obsolete PR squashes after GitHub closes one.
: > "$ROWS"
bash "$DRIVER" rebuild "$TMP/repo"
[[ "$(git rev-parse integration)" == "$BASE" ]]
[[ ! -e "$TMP/integration/first.txt" ]]
# A detached interrupted pass must still retain its already-resolved squashes.
printf '1\tfirst\tFirst change\n' > "$ROWS"
bash "$DRIVER" rebuild "$TMP/repo"
git -C "$TMP/integration" checkout -q --detach
printf 'resolved\n' > "$TMP/integration/first.txt"
git -C "$TMP/integration" add first.txt
git -C "$TMP/integration" commit -q --amend --no-edit
printf '2\tsecond\tSecond change\n' >> "$ROWS"
bash "$DRIVER" rebuild "$TMP/repo"
[[ "$(git rev-list --count "$BASE..integration")" == 2 ]]
[[ "$(cat "$TMP/integration/first.txt")" == resolved ]]
[[ "$(cat "$TMP/integration/second.txt")" == second ]]
printf 'PASS: completed rebuild starts fresh; detached interrupted rebuild resumes\n'

# Exact, reviewed conflict resolutions must work without any rerere cache.
git checkout -qb left main
printf 'left\n' > base.txt
git add base.txt
git commit -qm left
git push -q fork left
git checkout -qb right main
printf 'right\n' > base.txt
git add base.txt
git commit -qm right
git push -q fork right
git checkout -q main
printf '3\tleft\tLeft change\n4\tright\tRight change\n' > "$ROWS"
if bash "$DRIVER" rebuild "$TMP/repo"; then
	echo "FAIL: unreviewed conflict was accepted" >&2
	exit 1
fi
mkdir -p "$HOME/.config/integration/fixups/$SLUG"
RESOLUTION="$HOME/.config/integration/fixups/$SLUG/4-resolve.patch"
git init -q -b main "$TMP/resolution"
cp "$TMP/integration/base.txt" "$TMP/resolution/base.txt"
git -C "$TMP/resolution" add base.txt
git -C "$TMP/resolution" commit -qm preimage
PREIMAGE="$(git -C "$TMP/resolution" rev-parse HEAD:base.txt)"
printf 'left\nright\n' > "$TMP/resolution/base.txt"
PATCH="$(git -C "$TMP/resolution" diff --full-index)"
reset_fixture() {
	git -C "$TMP/integration" restore --source=HEAD --staged --worktree -- base.txt
	git -C "$TMP/integration" checkout -q -B integration main
}

# Reject a full hash mismatch without staging away the unresolved index.
reset_fixture
printf '%s\n' "${PATCH/$PREIMAGE/0000000000000000000000000000000000000000}" > "$RESOLUTION"
if bash "$DRIVER" rebuild "$TMP/repo"; then
	echo "FAIL: mismatched conflict preimage was accepted" >&2
	exit 1
fi
[[ -n "$(git -C "$TMP/integration" ls-files -u)" ]]

# Reject a patch that does not cover every unresolved path.
reset_fixture
printf '%s\n' "${PATCH//base.txt/missing.txt}" > "$RESOLUTION"
if bash "$DRIVER" rebuild "$TMP/repo"; then
	echo "FAIL: uncovered conflict was accepted" >&2
	exit 1
fi
[[ -n "$(git -C "$TMP/integration" ls-files -u)" ]]

# Exact marker preimages resolve strictly and preserve both PRs' behavior.
reset_fixture
printf '%s\n' "$PATCH" > "$RESOLUTION"
bash "$DRIVER" rebuild "$TMP/repo"
[[ -z "$(git -C "$TMP/integration" ls-files -u)" ]]
cmp "$TMP/integration/base.txt" "$TMP/resolution/base.txt"
printf 'PASS: exact conflict resolution succeeds; mismatched and uncovered preimages refuse\n'
