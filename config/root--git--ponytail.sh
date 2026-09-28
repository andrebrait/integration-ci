# integration-flow config for /root/git/ponytail
# Fork: andrebrait/ponytail of DietrichGebert/ponytail. `integration` is the fork's
# default branch and the OMP marketplace source for ponytail@ponytail.
FORK_REMOTE=origin
UPSTREAM=DietrichGebert/ponytail
BRANCH=integration
BASE=upstream/main
UPSTREAM_MAIN_REF=upstream/main
BUILD_CMD='ln -sfn /root/.omp/plugins/node_modules node_modules && uv run -q --no-project --with pandas -- node --test tests/*.test.js && npm run test:omp'
DEPLOY_CMD='omp plugin marketplace update ponytail && omp plugin install ponytail@ponytail --force'
