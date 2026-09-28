# integration-flow config for /root/git/codegraph
# Fork: andrebrait/codegraph of colbymchenry/codegraph.
FORK_REMOTE=origin
UPSTREAM=colbymchenry/codegraph
BRANCH=integration
BASE=upstream/main
UPSTREAM_MAIN_REF=upstream/main
BUILD_CMD='npm ci --no-audit --no-fund && npx vitest run __tests__/omp-extension.test.ts'
DEPLOY_CMD='omp plugin install "github:andrebrait/codegraph#${DEPLOY_SHA}"'
