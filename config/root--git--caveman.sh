# integration-flow config for /root/git/caveman
# Fork: andrebrait/caveman of JuliusBrussee/caveman; "origin" and "upstream" both point at JuliusBrussee/caveman.
FORK_REMOTE=fork
UPSTREAM=JuliusBrussee/caveman
BRANCH=integration
CI_REPO=andrebrait/integration-ci
CI_WORKFLOW=caveman.yml
BASE=upstream/main
UPSTREAM_MAIN_REF=upstream/main
BUILD_CMD='(cd packages/pi-extension && npm ci --no-audit --no-fund && npm test && npm run test:omp) && go test ./mcp/...'
# Publish the pi-extension build as an immutable fork release and install it into OMP as an
# ordinary package pinned by URL; nothing at runtime depends on this checkout.
DEPLOY_CMD='set -e
cd "$BUILD_DIR"
tgz="$(basename "$BUILD_DIR"/caveman-ai-pi-*.tgz)"
tag="pi-extension-integration-${DEPLOY_SHA:0:10}"
gh release view "$tag" --repo andrebrait/caveman >/dev/null 2>&1 ||
  gh release create "$tag" "$tgz" --repo andrebrait/caveman --target "$DEPLOY_SHA" --latest=false \
    --title "@caveman-ai/pi (integration ${DEPLOY_SHA:0:10})" \
    --notes "npm pack of packages/pi-extension at andrebrait/caveman integration $DEPLOY_SHA (base $DEPLOY_BASE). sha256 $(sha256sum "$tgz" | cut -d" " -f1)."
url="https://github.com/andrebrait/caveman/releases/download/$tag/$tgz"
[ "$(curl -fsSL "$url" | sha256sum | cut -d" " -f1)" = "$(sha256sum "$tgz" | cut -d" " -f1)" ]
omp install "@caveman-ai/pi@$url"
echo "installed @caveman-ai/pi from $url"'
