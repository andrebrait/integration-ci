# integration-flow config for /root/git/ompweb
FORK_REMOTE=origin
UPSTREAM=kahme247/ompweb
BRANCH=deploy/integration
CI_REPO=andrebrait/integration-ci
CI_WORKFLOW=ompweb.yml
BASE=upstream/main
UPSTREAM_MAIN_REF=upstream/main
BUILD_CMD='npm ci --no-audit --no-fund && npm run build && npm run lint && npm test'
DEPLOY_CMD='set -e
short="${DEPLOY_SHA:0:12}"
rel="/opt/ompweb-patched/releases/$short"
[ -d "$rel" ] || /opt/omp-deployment/bin/ompweb-build "$DEPLOY_SHA" "$BUILD_DIR"
ln -sfn "$rel" /opt/ompweb-patched/current
sed -i "s|/opt/ompweb-patched/releases/[0-9a-f]\{12\}|/opt/ompweb-patched/releases/$short|g" /etc/systemd/system/ompweb-api.service
systemctl daemon-reload
# Single omp-web on purpose: nginx routes UI and /api/ to 30185. A second
# omp-web on the same ~/.omp/agent (the retired ompweb-pwa) spawns competing
# omp children and omp forks the session file. The restart kills running
# agent sessions; they verify on resume.
printf %s "$DEPLOY_SHA" > "$HOME/.cache/integration/root--git--ompweb/last-deploy"
systemctl restart ompweb-api
echo "ompweb deployed $short"
for port in 30185; do
	code=000
	for i in $(seq 1 30); do
		code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$port" 2>/dev/null) && [ "$code" != "000" ] && break
		sleep 1
	done
	echo "port $port: $code"
done'
