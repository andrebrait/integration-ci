# integration-flow config for /root/git/superpowers
# Fork: andrebrait/superpowers of obra/superpowers; PRs target dev.
FORK_REMOTE=origin
UPSTREAM=obra/superpowers
BRANCH=integration
BASE=upstream/dev
UPSTREAM_MAIN_REF=upstream/dev
BUILD_CMD='node --test tests/omp/test-omp-extension.mjs tests/pi/test-pi-extension.mjs'
DEPLOY_CMD='omp plugin install "github:andrebrait/superpowers#${DEPLOY_SHA}"'
