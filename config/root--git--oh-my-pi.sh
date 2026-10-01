# integration-flow config for /root/git/oh-my-pi
FORK_REMOTE=origin
UPSTREAM=can1357/oh-my-pi
# Third-party PRs carried from our fork (rebased + fixed copy). See EXTRA_PRS in the integration script.
EXTRA_PRS='12229=carry/pr-12229'
BRANCH=integration
BASE=upstream/main
BUILD_CMD='bun install --frozen-lockfile && bun run build:native && bun check && bun --cwd=packages/coding-agent run build && packages/coding-agent/dist/omp --smoke-test'
FORMAT_CMD='bun install --frozen-lockfile >/dev/null && bun run fmt:tools'
TEST_CMD='PI_CODING_AGENT_DIR="$(mktemp -d /tmp/omp-integration-agent-XXXXXX)" bun test packages/agent/test/agent-loop.test.ts packages/coding-agent/test/extensions-runner.test.ts packages/coding-agent/test/agent-session-queued-steer-delivery.test.ts packages/coding-agent/test/agent-session-queued-policy.test.ts packages/coding-agent/test/agent-session-new-session-queued-steer.test.ts packages/coding-agent/test/rpc-queued-message.test.ts packages/coding-agent/test/skills.test.ts packages/coding-agent/test/skill-protocol-customdirs.test.ts packages/coding-agent/test/agent-session-video-attachment.test.ts packages/coding-agent/test/rpc-cancel-subagent.test.ts packages/coding-agent/test/rpc-steer-subagent.test.ts packages/coding-agent/test/task/structured-subagent.test.ts packages/coding-agent/test/task/wire-schema.test.ts packages/coding-agent/test/eval/agent-bridge-policy.test.ts'
# Keep admission ordering, detached drafts, hook chaining, and host RPC contracts covered across PR squashes.
TEST_CMD+=' packages/coding-agent/test/rpc-native-input.test.ts packages/coding-agent/test/rpc-input-frame.test.ts packages/coding-agent/test/rpc-prompt-result.test.ts packages/coding-agent/test/rpc-skill-command.test.ts packages/coding-agent/test/agent-session-prompt-dispatch-race.test.ts packages/coding-agent/test/agent-session-skill-image.test.ts packages/coding-agent/test/input-controller-input-events.test.ts packages/coding-agent/test/slash-commands/detached-draft.test.ts packages/coding-agent/test/slash-commands/mode-attachments.test.ts packages/coding-agent/test/hook-tool-wrapper-input.test.ts packages/coding-agent/test/ttsr-bridged-passive-context.test.ts packages/coding-agent/test/skillshare/discovery.test.ts packages/coding-agent/test/agent-session-queue-update-events.test.ts packages/coding-agent/test/agent-session-message-pipeline.test.ts packages/coding-agent/test/agent-session-extension-command-admission.test.ts packages/coding-agent/test/rpc-compatible-primitives.test.ts packages/coding-agent/test/rpc-extension-ui.test.ts packages/coding-agent/test/modes/controllers/event-controller-message-start.test.ts packages/coding-agent/test/modes/utils/render-initial-messages.test.ts packages/tui/test/tool-execution-memoization.test.ts'
TEST_CMD+=' packages/coding-agent/test/prefix-binding-tool-roster.test.ts packages/coding-agent/test/task/speculative-launch.test.ts packages/coding-agent/test/task/task-preflight.test.ts packages/coding-agent/test/sdk-active-selector.test.ts'
# Own process: upstream's issue-985 test calls Settings.init() without resetting a global
# instance left by agent-session-message-pipeline.test.ts, so it fails when co-run (upstream too).
TEST_CMD+=' && PI_CODING_AGENT_DIR="$(mktemp -d /tmp/omp-integration-agent-XXXXXX)" bun test packages/coding-agent/test/issue-985-subagent-auth-fallback.test.ts'
DEPLOY_CMD='set -e
rel="/opt/omp-patched/releases/${DEPLOY_SHA:0:10}"
mkdir -p "$rel"
cp "$BUILD_DIR/packages/coding-agent/dist/omp" "$rel/omp"
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
