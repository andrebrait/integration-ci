# integration-flow config for /root/git/graphify
# Fork: pfBlockerNG/graphify of Graphify-Labs/graphify; base branch is v8.
FORK_REMOTE=origin
UPSTREAM=Graphify-Labs/graphify
BRANCH=integration
CI_REPO=andrebrait/integration-ci
CI_WORKFLOW=graphify.yml
BASE=upstream/v8
UPSTREAM_MAIN_REF=upstream/v8
# Third-party PRs carried from our fork (rebased + fixed copy). See EXTRA_PRS in the integration script.
# 3110: abhay-codes07's _origin=semantic stamp (Graphify-Labs/graphify#2843), rebased onto v8.
EXTRA_PRS='3110=carry/pr-3110'
# Install exactly the committed lockfile. Not `uv lock --check`: upstream release commits
# bump the version without relocking, which fails that check on plain upstream/v8.
BUILD_CMD='uv sync --frozen --extra leiden'
# tests/omp.test.ts imports omp's real modules (pinned to the release these tests were written
# against) and drives the graphify CLI; point it at this commit's venv, not an installed copy.
TEST_CMD='npm install --no-save --no-package-lock --no-audit --no-fund @oh-my-pi/pi-coding-agent@18.1.17 && uv run --frozen --extra leiden pytest tests/test_backend_extras.py tests/test_omp_install.py tests/test_hook_guard.py tests/test_hook_strict.py tests/test_semantic_origin_stamp.py && GRAPHIFY_TEST_CLI="$PWD/.venv/bin/graphify" bun test tests/omp.test.ts'
DEPLOY_CMD='uv tool install --force --reinstall "graphifyy[leiden] @ git+https://github.com/pfBlockerNG/graphify@${DEPLOY_SHA}"'
POST_CMD='ver="$(git -C "$REPO_DIR" show "$DEPLOY_SHA:pyproject.toml" | sed -n '\''s/^version = "\(.*\)"/\1/p'\'')" && for p in agents claude pi codex omp; do graphify install --platform $p; done && graphify omp install && ~/.config/integration/pfblockerng-graphify-pin.sh "$DEPLOY_SHA" "$ver" && ~/.config/integration/leveret-graphify-pin.sh "$DEPLOY_SHA" "$ver"'
