# integration-flow config for /root/git/ompweb
FORK_REMOTE=origin
UPSTREAM=kahme247/ompweb
BRANCH=deploy/integration
CI_REPO=andrebrait/integration-ci
CI_WORKFLOW=ompweb.yml
# Deploy the standalone linux-x64 binary (the bin-ompweb-linux-x64 artifact / *-linux-x64.zip),
# not the npm package: ompweb-build installs either layout and ompweb-run starts it.
CI_TARGET=linux-x64
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
# #342 (local daemon) is built on #339 (remote hosts); #344 (Bun runtime) on #342.
STACKED_PRS='344:342 342:339'
