# integration-flow config for /root/git/oh-my-pi
FORK_REMOTE=origin
UPSTREAM=can1357/oh-my-pi
# PRs built on another open PR's branch (CHILD:PARENT). See STACKED_PRS in the integration script.
STACKED_PRS='14458:14148 14468:14166'
# Third-party PRs carried from our fork (rebased copy). See EXTRA_PRS in the integration script.
# 7851: szavadsky's per-role skill visibility; 12229: Xytronix's per-call task/eval model selector.
EXTRA_PRS='7851=carry/pr-7851 12229=carry/pr-12229'
BRANCH=integration
# build runs BUILD_CMD/TEST_CMD on GitHub Actions (.github/workflows/omp.yml sources this file).
CI_REPO=andrebrait/integration-ci
CI_WORKFLOW=omp.yml
# omp.yml builds every platform; this host deploys the linux-x64 binary.
CI_TARGET=linux-x64
BASE=upstream/main
BUILD_CMD='bun install --frozen-lockfile && bun run build:native && bun check && bun --cwd=packages/coding-agent run build && packages/coding-agent/dist/omp --smoke-test'
FORMAT_CMD='bun install --frozen-lockfile >/dev/null && bun run gen:compat && bun run fmt:tools'
TEST_CMD='PI_CODING_AGENT_DIR="$(mktemp -d /tmp/omp-integration-agent-XXXXXX)" bun test packages/agent/test/agent-loop.test.ts packages/coding-agent/test/extensions-runner.test.ts packages/coding-agent/test/agent-session-queued-steer-delivery.test.ts packages/coding-agent/test/agent-session-queued-policy.test.ts packages/coding-agent/test/agent-session-new-session-queued-steer.test.ts packages/coding-agent/test/rpc-queued-message.test.ts packages/coding-agent/test/skills.test.ts packages/coding-agent/test/skill-protocol-customdirs.test.ts packages/coding-agent/test/agent-session-video-attachment.test.ts packages/coding-agent/test/rpc-cancel-subagent.test.ts packages/coding-agent/test/rpc-steer-subagent.test.ts packages/coding-agent/test/task/structured-subagent.test.ts packages/coding-agent/test/task/wire-schema.test.ts packages/coding-agent/test/eval/agent-bridge-policy.test.ts'
# Keep admission ordering, detached drafts, hook chaining, and host RPC contracts covered across PR squashes.
TEST_CMD+=' packages/coding-agent/test/rpc-native-input.test.ts packages/coding-agent/test/rpc-input-frame.test.ts packages/coding-agent/test/rpc-prompt-result.test.ts packages/coding-agent/test/rpc-skill-command.test.ts packages/coding-agent/test/agent-session-prompt-dispatch-race.test.ts packages/coding-agent/test/agent-session-skill-image.test.ts packages/coding-agent/test/input-controller-input-events.test.ts packages/coding-agent/test/slash-commands/detached-draft.test.ts packages/coding-agent/test/slash-commands/mode-attachments.test.ts packages/coding-agent/test/hook-tool-wrapper-input.test.ts packages/coding-agent/test/ttsr-bridged-passive-context.test.ts packages/coding-agent/test/skillshare/discovery.test.ts packages/coding-agent/test/agent-session-queue-update-events.test.ts packages/coding-agent/test/agent-session-message-pipeline.test.ts packages/coding-agent/test/agent-session-extension-command-admission.test.ts packages/coding-agent/test/rpc-compatible-primitives.test.ts packages/coding-agent/test/rpc-extension-ui.test.ts packages/coding-agent/test/modes/controllers/event-controller-message-start.test.ts packages/coding-agent/test/modes/utils/render-initial-messages.test.ts packages/tui/test/tool-execution-memoization.test.ts'
TEST_CMD+=' packages/coding-agent/test/prefix-binding-tool-roster.test.ts packages/coding-agent/test/task/speculative-launch.test.ts packages/coding-agent/test/task/task-preflight.test.ts packages/coding-agent/test/sdk-active-selector.test.ts'
# PR #14365 (retry.preferSlowMode) contract tests.
TEST_CMD+=' packages/coding-agent/test/agent-session-retry-fallback.test.ts packages/coding-agent/test/sdk-model-selection.test.ts'
TEST_CMD+=' packages/catalog/test/compat-compile.test.ts'
# Carried PRs #7851 (per-role skill visibility) and #12229 (per-call task/eval model) contract tests.
TEST_CMD+=' packages/coding-agent/test/discovery/agent-fields.test.ts packages/coding-agent/test/task/agents.test.ts packages/coding-agent/test/task/role-routing.test.ts packages/coding-agent/test/eval/agent-bridge.test.ts packages/coding-agent/test/task/task-schema.test.ts packages/coding-agent/test/task/task-spawn.test.ts'
# Own process: upstream's issue-985 test calls Settings.init() without resetting a global
# instance left by agent-session-message-pipeline.test.ts, so it fails when co-run (upstream too).
TEST_CMD+=' && PI_CODING_AGENT_DIR="$(mktemp -d /tmp/omp-integration-agent-XXXXXX)" bun test packages/coding-agent/test/issue-985-subagent-auth-fallback.test.ts'
DEPLOY_CMD='set -e
rel="/opt/omp-patched/releases/${DEPLOY_SHA:0:10}"
mkdir -p "$rel"
# Copy beside, then rename over: redeploying the running sha would hit "Text file busy",
# and a rename leaves running processes on the old inode.
cp "$BUILD_DIR/omp" "$rel/omp.new"
mv -f "$rel/omp.new" "$rel/omp"
sha256sum "$rel/omp" | cut -d" " -f1 > "$rel/omp.sha256"
{
	echo "branch: integration"
	echo "sha: $DEPLOY_SHA"
	echo "upstream base: $DEPLOY_BASE"
	echo "built: $(date -u +%FT%TZ)"
	echo "sha256(omp): $(cat "$rel/omp.sha256")"
	echo "verify: bun check, downstream-patch tests, omp --smoke-test"
} > "$rel/RELEASE.md"
ln -sfn "$rel" /opt/omp-patched/current
echo "current -> $rel"'
