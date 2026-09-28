# integration-flow config for /root/git/agent-skills
# Fork: andrebrait/agent-skills of addyosmani/agent-skills (draft PR #617).
FORK_REMOTE=origin
UPSTREAM=addyosmani/agent-skills
BRANCH=integration
BASE=upstream/main
UPSTREAM_MAIN_REF=upstream/main
BUILD_CMD='ln -sfn /root/.omp/plugins/node_modules node_modules && node --test scripts/omp-bootstrap-test.js && node scripts/validate-versions.js && node scripts/validate-versions-test.js && bash hooks/session-start-test.sh'
DEPLOY_CMD='omp plugin install "github:andrebrait/agent-skills#${DEPLOY_SHA}"'
