#!/usr/bin/env bash
# Real Git repositories, fake GitHub metadata: no network, builds, or deployment.
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
export VIEWS="$TMP/views"
: > "$VIEWS"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == pr\ list* ]]; then
	cat "$ROWS"
	exit 0
fi
[[ "$1 $2" == "pr view" ]] || exit 2
num="$3"
shift 3
repo="" fields=""
while (( $# )); do
	case "$1" in
		--repo) repo="$2" ;;
		--json) fields="$2" ;;
		--jq) ;;
		*) exit 2 ;;
	esac
	shift 2
done
[[ "$num" =~ ^[0-9]+$ ]] || exit 2
while IFS=$'\t' read -r fixture_repo fixture_num state title base; do
	[[ "$repo" == "$fixture_repo" && "$num" == "$fixture_num" ]] || continue
	case "$fields" in
		state,title) printf '%s\t%s\n' "$state" "$title" ;;
		state,baseRefName) printf '%s\t%s\n' "$state" "$base" ;;
		*) exit 2 ;;
	esac
	exit 0
done < "$VIEWS"
echo "Unexpected PR metadata query: $repo#$num ($fields)" >&2
exit 2
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

# Repository-qualified IDs must not collide with upstream numbers. The child
# carries its parent's original file, while integration adapts that parent.
git checkout -qb local-draft main
printf 'draft\n' > draft.txt
git add draft.txt
git commit -qm draft
git push -q fork local-draft
printf 'patched draft\n' > draft.txt
mkdir -p "$HOME/.config/integration/fixups/$SLUG/fork"
git diff --full-index > "$HOME/.config/integration/fixups/$SLUG/fork/repo#1-adapt.patch"
git restore draft.txt
git checkout -qb stacked-child second
printf 'child\n' > child.txt
git add child.txt
git commit -qm child
git push -q fork stacked-child
git checkout -q second
printf 'adapted parent\n' > second.txt
git diff --full-index > "$HOME/.config/integration/fixups/$SLUG/10-adapt.patch"
git restore second.txt
git checkout -q main
cat >> "$HOME/.config/integration/$SLUG.sh" <<'SH'
EXTRA_PRS='fork/repo#2=stacked-child fork/repo#1=local-draft 10=second 1=first'
STACKED_PRS='fork/repo#2:10'
SH
: > "$ROWS"
printf 'fixture/repo\t1\tOPEN\tFirst change\tmain\nfixture/repo\t10\tOPEN\tParent change\tmain\nfork/repo\t1\tOPEN\tFork draft\tmain\nfork/repo\t2\tOPEN\tStacked child\tmain\n' > "$VIEWS"
bash "$DRIVER" rebuild "$TMP/repo"
[[ "$(git rev-list --count "$BASE..integration")" == 4 ]]
[[ "$(cat "$TMP/integration/first.txt")" == first ]]
[[ "$(cat "$TMP/integration/second.txt")" == 'adapted parent' ]]
[[ "$(cat "$TMP/integration/draft.txt")" == 'patched draft' ]]
[[ "$(cat "$TMP/integration/child.txt")" == child ]]
SUBJECTS="$(git log --format=%s "$BASE..integration" | LC_ALL=C sort)"
[[ "$SUBJECTS" == $'PR #10: Parent change\nPR #1: First change\nPR fork/repo#1: Fork draft\nPR fork/repo#2: Stacked child' ]]
[[ "$(git log --reverse --format=%s "$BASE..integration")" == $'PR #1: First change\nPR #10: Parent change\nPR fork/repo#1: Fork draft\nPR fork/repo#2: Stacked child' ]]
[[ "$(git show --format= --name-only integration)" == child.txt ]]
[[ "$(git log --format=%s "$BASE..integration" -- second.txt)" == 'PR #10: Parent change' ]]
printf 'PASS: qualified IDs use their own metadata, literal fixup paths, and stacked child-only squashes\n'

# Closing fork #1 must not close upstream #1 or retain a completed fork squash.
printf 'fixture/repo\t1\tOPEN\tFirst change\tmain\nfixture/repo\t10\tOPEN\tParent change\tmain\nfork/repo\t1\tCLOSED\tFork draft\tmain\nfork/repo\t2\tOPEN\tStacked child\tmain\n' > "$VIEWS"
bash "$DRIVER" rebuild "$TMP/repo"
[[ "$(git rev-list --count "$BASE..integration")" == 3 ]]
[[ ! -e "$TMP/integration/draft.txt" ]]
[[ "$(cat "$TMP/integration/first.txt")" == first ]]
[[ "$(cat "$TMP/integration/second.txt")" == 'adapted parent' ]]
[[ "$(cat "$TMP/integration/child.txt")" == child ]]
[[ "$(git log --reverse --format=%s "$BASE..integration")" == $'PR #1: First change\nPR #10: Parent change\nPR fork/repo#2: Stacked child' ]]
printf 'PASS: closed qualified PR drops on a fresh rebuild without dropping same-number upstream PR\n'

# A qualified squash can be the only completed work in an interrupted pass.
# Later upstream #1 must not be mistaken for already-squashed fork/repo#1.
cat >> "$HOME/.config/integration/$SLUG.sh" <<'SH'
EXTRA_PRS='fork/repo#1=local-draft'
STACKED_PRS=''
SH
printf 'fork/repo\t1\tOPEN\tFork draft\tmain\n' > "$VIEWS"
bash "$DRIVER" rebuild "$TMP/repo"
[[ "$(git rev-list --count "$BASE..integration")" == 1 ]]
git -C "$TMP/integration" checkout -q --detach
printf 'resolved qualified draft\n' > "$TMP/integration/draft.txt"
git -C "$TMP/integration" add draft.txt
git -C "$TMP/integration" commit -q --amend --no-edit
RESOLVED="$(git -C "$TMP/integration" rev-parse HEAD)"
printf '1\tfirst\tFirst change\n2\tsecond\tSecond change\n' > "$ROWS"
bash "$DRIVER" rebuild "$TMP/repo"
git merge-base --is-ancestor "$RESOLVED" integration
[[ "$(git rev-list --count "$BASE..integration")" == 3 ]]
[[ "$(cat "$TMP/integration/draft.txt")" == 'resolved qualified draft' ]]
[[ "$(cat "$TMP/integration/first.txt")" == first ]]
[[ "$(cat "$TMP/integration/second.txt")" == second ]]
[[ "$(git log --reverse --format=%s "$BASE..integration")" == $'PR fork/repo#1: Fork draft\nPR #1: First change\nPR #2: Second change' ]]
printf 'PASS: interrupted qualified squash retains its resolution and exact repository-qualified identity\n'
