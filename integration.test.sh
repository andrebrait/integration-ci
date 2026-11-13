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
export VIEWS="$TMP/views" FORK_GIT="$TMP/fork.git" DISPATCHED="$TMP/dispatched"
: > "$VIEWS"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == api\ user* ]] && { [[ -z "${GH_NO_USER:-}" ]] || exit 2; echo fixture-user; exit 0; }
# A fork branch head comes from the bare fork repo; the slug must be FORK_REMOTE's path.
if [[ "$1" == api && "$2" == repos/*/branches/* ]]; then
	[[ "$2" == "repos/${FORK_GIT%.git}/branches/"* ]] || exit 2
	git --git-dir="$FORK_GIT" rev-parse --verify -q "refs/heads/${2#*/branches/}"
	exit
fi
if [[ "$*" == workflow\ run* ]]; then
	printf '%s\n' "$*" >> "$DISPATCHED"
	echo "fixture: no dispatch" >&2
	exit 1
fi
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

# SKIP_PRS leaves an open PR out of a rebuild, by its whole ID: skipping upstream #1 keeps fork/repo#2.
SKIP_PRS='1' bash "$DRIVER" rebuild "$TMP/repo"
[[ "$(git log --reverse --format=%s "$BASE..integration")" == $'PR #10: Parent change\nPR fork/repo#2: Stacked child' ]]
[[ ! -e "$TMP/integration/first.txt" ]]
bash "$DRIVER" rebuild "$TMP/repo"
[[ "$(git log --reverse --format=%s "$BASE..integration")" == $'PR #1: First change\nPR #10: Parent change\nPR fork/repo#2: Stacked child' ]]
printf 'PASS: SKIP_PRS leaves an open PR out of one rebuild only\n'

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

# CI mode: config, fixups and cache from INTEGRATION_* dirs, base from INTEGRATION_BASE,
# PR author without `gh api user`, and a locally rebased PR head under a ref prefix.
git -C "$TMP/repo" tag v1 main
printf 'later\n' > "$TMP/repo/later.txt"
git -C "$TMP/repo" add later.txt
git -C "$TMP/repo" commit -qm later
git -C "$TMP/repo" push -q upstream main v1
mkdir -p "$TMP/ci-config"
printf 'FORK_REMOTE=fork\nUPSTREAM=fixture/repo\nBRANCH=integration\nBASE=upstream/main\n' > "$TMP/ci-config/ci--repo.sh"
git -C "$TMP/repo" checkout -q -b rebased-first v1
printf 'rebased first\n' > "$TMP/repo/first.txt"
git -C "$TMP/repo" add first.txt
git -C "$TMP/repo" commit -qm 'first, rebased'
git -C "$TMP/repo" update-ref refs/rebased/first HEAD
git -C "$TMP/repo" checkout -q main
printf '1\tfirst\tFirst change\n' > "$ROWS"
GH_NO_USER=1 INTEGRATION_SLUG=ci--repo INTEGRATION_CONFIG_DIR="$TMP/ci-config" \
	INTEGRATION_CACHE_DIR="$TMP/ci-cache" INTEGRATION_BASE=v1 INTEGRATION_PR_AUTHOR=fixture-user \
	INTEGRATION_HEAD_PREFIX=refs/rebased bash "$DRIVER" rebuild "$TMP/repo"
[[ "$(git rev-parse integration~1)" == "$(git rev-parse v1)" ]]
[[ ! -e "$TMP/integration/later.txt" ]]
[[ "$(cat "$TMP/integration/first.txt")" == 'rebased first' ]]
git log -1 --format=%b integration | grep -qF "Squashed from fork/first ($(git rev-parse refs/rebased/first)) onto v1."
[[ -d "$TMP/ci-cache/ci--repo" ]]
printf 'PASS: CI overrides pick config, cache, base, PR author and a locally rebased PR head\n'

# CI rebase: every PR is moved onto the release tag past failures; a PR cut from a
# newer upstream replays only its own commits; a child of a failed parent is skipped.
cd "$TMP/repo"
git checkout -qb newer main
printf 'newer\n' > newer.txt
git add newer.txt
git commit -qm newer
git checkout -qb broken main
printf 'broken\n' > later.txt
git commit -qam broken
git checkout -qb broken-child broken
printf 'child\n' > broken-child.txt
git add broken-child.txt
git commit -qm broken-child
git checkout -q main
git push -q fork newer broken broken-child
printf 'STACKED_PRS=%s\n' "'22:21'" >> "$TMP/ci-config/ci--repo.sh"
printf '1\tfirst\tmain\n20\tnewer\tmain\n21\tbroken\tmain\n22\tbroken-child\tmain\n' > "$ROWS"
if INTEGRATION_SLUG=ci--repo INTEGRATION_CONFIG_DIR="$TMP/ci-config" INTEGRATION_CACHE_DIR="$TMP/ci-cache" \
	INTEGRATION_BASE=v1 INTEGRATION_PR_AUTHOR=fixture-user bash "$DRIVER" rebase "$TMP/repo"; then
	echo "FAIL: rebase with a conflicting PR reported success" >&2
	exit 1
fi
[[ "$(cut -f1,3 "$TMP/ci-cache/ci--repo/rebase.tsv")" == $'1\tunchanged\n20\trebased\n21\tfailed\n22\tskipped' ]]
! git rev-parse -q --verify refs/rebased/first >/dev/null
[[ "$(git rev-parse refs/rebased/newer~1)" == "$(git rev-parse v1)" ]]
[[ "$(git show refs/rebased/newer:newer.txt)" == newer ]]
! git rev-parse -q --verify refs/rebased/broken >/dev/null
printf 'PASS: CI rebase keeps going past a failed PR and replays only each PR'"'"'s own commits\n'

# heads: one row per carried PR with the fork's sha, after SKIP_PRS and closed EXTRA_PRS drop out.
printf "FORK_REMOTE=fork\nUPSTREAM=fixture/repo\nEXTRA_PRS='fork/repo#1=local-draft 10=second 11=left'\n" > "$TMP/ci-config/heads--repo.sh"
printf '20\tnewer\tmain\n2\tbroken\tmain\n1\tfirst\tmain\n' > "$ROWS"
printf 'fork/repo\t1\tOPEN\tFork draft\tmain\nfixture/repo\t10\tOPEN\tParent change\tmain\nfixture/repo\t11\tCLOSED\tLeft change\tmain\n' > "$VIEWS"
HEADS="$(SKIP_PRS=20 INTEGRATION_SLUG=heads--repo INTEGRATION_CONFIG_DIR="$TMP/ci-config" INTEGRATION_CACHE_DIR="$TMP/ci-cache" \
	INTEGRATION_PR_AUTHOR=fixture-user bash "$DRIVER" heads "$TMP/repo" 2>/dev/null)"
fork_sha() { git --git-dir="$FORK_GIT" rev-parse "refs/heads/$1"; }
[[ "$HEADS" == "$(printf '1\tfirst\t%s\n2\tbroken\t%s\n10\tsecond\t%s\nfork/repo#1\tlocal-draft\t%s' \
	"$(fork_sha first)" "$(fork_sha broken)" "$(fork_sha second)" "$(fork_sha local-draft)")" ]]
printf 'PASS: heads lists carried PRs with fork shas, honouring SKIP_PRS and EXTRA_PRS\n'

# CI_CONFIG_REF: build compares the config with that ref (default origin/main) before dispatching.
git init -q --bare "$TMP/cfg.git"
git init -q -b main "$TMP/cfg"
mkdir -p "$TMP/cfg/config" "$TMP/cfg/.github/workflows"
printf 'FORK_REMOTE=fork\nUPSTREAM=fixture/repo\nCI_REPO=fixture/ci\nCI_WORKFLOW=ci.yml\n' > "$TMP/cfg/config/cfg--repo.sh"
: > "$TMP/cfg/.github/workflows/ci.yml"
git -C "$TMP/cfg" add -A
git -C "$TMP/cfg" commit -qm main
git -C "$TMP/cfg" remote add origin "$TMP/cfg.git"
git -C "$TMP/cfg" push -q origin main
git -C "$TMP/cfg" checkout -qb fork-ci
printf '# fork-ci\n' >> "$TMP/cfg/config/cfg--repo.sh"
git -C "$TMP/cfg" commit -qam fork-ci
git -C "$TMP/cfg" push -q origin fork-ci
cfg_build() { INTEGRATION_SLUG=cfg--repo INTEGRATION_CONFIG_DIR="$TMP/cfg/config" INTEGRATION_CACHE_DIR="$TMP/ci-cache" \
	bash "$DRIVER" build-sha "$BASE" "$TMP/repo" 2>&1; }
: > "$DISPATCHED"
OUT="$(CI_CONFIG_REF=origin/fork-ci cfg_build)" && { echo "FAIL: fixture dispatch reported success" >&2; exit 1; }
[[ "$OUT" == *"dispatching ci.yml in fixture/ci failed"* && -s "$DISPATCHED" ]]
: > "$DISPATCHED"
OUT="$(cfg_build)" && { echo "FAIL: build against a config differing from origin/main succeeded" >&2; exit 1; }
[[ "$OUT" == *"differs from fixture/ci origin/main"* && ! -s "$DISPATCHED" ]]
printf '# unpushed\n' >> "$TMP/cfg/config/cfg--repo.sh"
git -C "$TMP/cfg" commit -qam unpushed
OUT="$(CI_CONFIG_REF=origin/fork-ci cfg_build)" && { echo "FAIL: build against a stale CI_CONFIG_REF succeeded" >&2; exit 1; }
[[ "$OUT" == *"differs from fixture/ci origin/fork-ci"* && ! -s "$DISPATCHED" ]]
printf 'PASS: build checks the config against CI_CONFIG_REF and refuses a stale one\n'

# Changelog driver: a rebase across an upstream release and archive keeps the PR's
# entry in [Unreleased] and leaves released sections exactly as upstream has them.
CL="$TMP/changelog"
git init -q -b main "$CL"
cd "$CL"
printf '# Changelog\n\n## [Unreleased]\n\n### Added\n\n- upstream entry\n\n## [1.0.0] - 2026-01-01\n\n### Added\n\n- archived entry\n' > CHANGELOG.md
git add CHANGELOG.md
git commit -qm base
git checkout -qb pr
printf '# Changelog\n\n## [Unreleased]\n\n### Added\n\n- upstream entry\n\n### Fixed\n\n- pr entry\n\n## [1.0.0] - 2026-01-01\n\n### Added\n\n- archived entry\n' > CHANGELOG.md
git commit -qam pr
git checkout -q main
printf '# Changelog\n\n## [Unreleased]\n\n## [1.1.0] - 2026-02-01\n\n### Added\n\n- upstream entry\n' > CHANGELOG.md
git commit -qam release
RELEASED="$(git show main:CHANGELOG.md | sed -n '/^## \[1.1.0\]/,$p')"
# Installed from config before any subcommand runs (an unknown one just exits 2).
CL_SLUG="${CL#/}"
printf "CHANGELOG_GLOB='CHANGELOG.md'\n" > "$HOME/.config/integration/${CL_SLUG//\//--}.sh"
bash "$DRIVER" no-such-command "$CL" >/dev/null 2>&1 || true
git checkout -q pr
git rebase -q main
[[ "$(sed -n '/^## \[1.1.0\]/,$p' CHANGELOG.md)" == "$RELEASED" ]]
[[ "$(sed -n '/^## \[Unreleased\]/,/^## \[1.1.0\]/p' CHANGELOG.md)" == $'## [Unreleased]\n\n### Fixed\n\n- pr entry\n\n## [1.1.0] - 2026-02-01' ]]
# A side that also edits a released section is not guessed at: the driver falls back
# to a plain three-way merge, so overlapping [Unreleased] edits stop on a conflict.
git checkout -qb rewrite main
sed -i 's/- upstream entry/- reworded upstream entry/; s/^## \[Unreleased\]$/## [Unreleased]\n\n### Fixed\n\n- other entry/' CHANGELOG.md
git commit -qam rewrite
! git rebase -q pr >/dev/null 2>&1
grep -q '^<<<<<<<' CHANGELOG.md
git rebase --abort
printf 'PASS: changelog driver keeps rebased entries in [Unreleased] and conflicts instead of unioning other edits\n'
