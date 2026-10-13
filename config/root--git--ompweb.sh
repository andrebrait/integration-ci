# integration-flow config for /root/git/ompweb
FORK_REMOTE=origin
UPSTREAM=kahme247/ompweb
BRANCH=deploy/integration
CI_REPO=andrebrait/integration-ci
CI_WORKFLOW=ompweb.yml
BASE=upstream/main
UPSTREAM_MAIN_REF=upstream/main
BUILD_CMD='npm ci --no-audit --no-fund && npm run build && npm run lint && npm test'
# Single omp-web on purpose: nginx routes UI and /api/ to 30185. A second
# omp-web on the same ~/.omp/agent (the retired ompweb-pwa) spawns competing
# omp children and omp forks the session file. ompweb-deploy preflights the
# release on a scratch port with a throwaway HOME, then restarts ompweb-api
# (killing running agent sessions; they verify on resume) and rolls back to
# the previous release if the restarted service is unhealthy.
DEPLOY_CMD='/opt/omp-deployment/bin/ompweb-deploy "$DEPLOY_SHA" "$BUILD_DIR"'
