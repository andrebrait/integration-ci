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
# 4484: bercedev's GDScript + Godot scene/project extraction (umbrella Graphify-Labs/graphify#4483),
# squashed onto v8. It adds the `gdscript` extra and tests/test_gdscript.py used below; drop both
# here if the PR closes unmerged.
EXTRA_PRS='4484=carry/pr-4484'
# Install exactly the committed lockfile. Not `uv lock --check`: upstream release commits
# bump the version without relocking, which fails that check on plain upstream/v8.
BUILD_CMD='uv sync --frozen --extra leiden --extra gdscript'
# tests/pi.test.ts loads the real Pi guard extension (Node built-ins only) and drives the
# graphify CLI; point it at this commit's venv, not an installed copy.
TEST_CMD='uv run --frozen --extra leiden --extra gdscript pytest tests/test_backend_extras.py tests/test_pi_guard_install.py tests/test_hook_guard.py tests/test_hook_strict.py tests/test_semantic_origin_stamp.py tests/test_gdscript.py && GRAPHIFY_TEST_CLI="$PWD/.venv/bin/graphify" bun test tests/pi.test.ts'
DEPLOY_CMD='uv tool install --force --reinstall "graphifyy[leiden,gdscript] @ git+https://github.com/pfBlockerNG/graphify@${DEPLOY_SHA}"'
# pfBlockerNG takes no pin: its ensure-graphify.sh installs a PyPI floor only under GitHub
# Actions and keeps a direct-URL build at or above the floor everywhere else.
POST_CMD='ver="$(git -C "$REPO_DIR" show "$DEPLOY_SHA:pyproject.toml" | sed -n '\''s/^version = "\(.*\)"/\1/p'\'')" && for p in agents claude pi codex; do graphify install --platform $p; done && omp plugin install "$(graphify pi guard path)" && ~/.config/integration/leveret-graphify-pin.sh "$DEPLOY_SHA" "$ver"'
