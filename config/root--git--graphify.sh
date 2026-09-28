# integration-flow config for /root/git/graphify
# Fork: pfBlockerNG/graphify of Graphify-Labs/graphify; base branch is v8.
FORK_REMOTE=origin
UPSTREAM=Graphify-Labs/graphify
BRANCH=integration
BASE=upstream/v8
UPSTREAM_MAIN_REF=upstream/v8
BUILD_CMD='uv lock --check'
TEST_CMD='ln -sfn /root/.omp/plugins/node_modules node_modules && uv run --frozen --extra leiden pytest tests/test_backend_extras.py tests/test_omp_install.py && bun test tests/omp.test.ts'
DEPLOY_CMD='uv tool install --force --reinstall "graphifyy[leiden] @ git+https://github.com/pfBlockerNG/graphify@${DEPLOY_SHA}"'
POST_CMD='for p in agents claude pi codex copilot omp; do graphify install --platform $p; done && graphify omp install && ~/.config/integration/pfblockerng-graphify-pin.sh "$DEPLOY_SHA" "$(sed -n '\''s/^version = "\(.*\)"/\1/p'\'' "$BUILD_DIR/pyproject.toml")"'
