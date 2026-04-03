#!/usr/bin/env bash
# post-failure-comment.sh — Post an enriched failure diagnostic comment on the triggering issue.
# Called from the orchestrate job's "Post failure comment" step when the agent execution fails.
#
# Required environment variables (set by GitHub Actions):
#   GH_TOKEN, GITHUB_REPOSITORY, GITHUB_SERVER_URL, GITHUB_RUN_ID, GITHUB_RUN_NUMBER, GITHUB_SHA, GITHUB_REF
#
# Required arguments:
#   $1 — issue number
#   $2 — trigger label name
#   $3 — issue title
#   $4 — actor
#   $5 — event name (e.g. "issues")
#   $6 — event action (e.g. "labeled")
set -euo pipefail

ISSUE_NUMBER="${1:?Usage: $0 <issue_number> <label> <issue_title> <actor> <event_name> <event_action>}"
LABEL="${2:?}"
ISSUE_TITLE="${3:?}"
ACTOR="${4:?}"
EVENT_NAME="${5:?}"
EVENT_ACTION="${6:?}"

REPO="${GITHUB_REPOSITORY:?}"
SERVER_URL="${GITHUB_SERVER_URL:?}"
RUN_ID="${GITHUB_RUN_ID:?}"
RUN_NUMBER="${GITHUB_RUN_NUMBER:?}"
SHA="${GITHUB_SHA:?}"
REF="${GITHUB_REF:?}"
RUN_URL="${SERVER_URL}/${REPO}/actions/runs/${RUN_ID}"

echo "::error::Orchestrator agent step failed — posting diagnostic comment to issue #${ISSUE_NUMBER}"

BODY=$(cat <<EOF
## :x: Orchestrator Run Failed

| Field | Value |
|-------|-------|
| **Run** | [#${RUN_NUMBER}](${RUN_URL}) |
| **Trigger label** | \`${LABEL}\` |
| **Issue** | #${ISSUE_NUMBER} — ${ISSUE_TITLE} |
| **Actor** | ${ACTOR} |
| **Event** | \`${EVENT_NAME}.${EVENT_ACTION}\` |
| **Ref / SHA** | \`${REF}\` / \`${SHA}\` |

### Likely Cause
Agent idle timeout — opencode produced no client or server output for 15 minutes and was terminated (\`SIGTERM\`, exit 143).
When this happens the LLM prompt's own error-handling logic **does not execute** — the process is killed before it can react.

### Recovery Options
1. **Retry**: Remove and re-apply the \`${LABEL}\` label on this issue
2. **Manual**: Complete the stalled orchestration step by hand, then apply the next label in the sequence
3. **Debug**: Download [trace artifacts](${RUN_URL}#artifacts) and check the opencode session logs

### Workflow Context
- Idle watchdog: \`IDLE_TIMEOUT_SECS=900\` (15 min), \`HARD_CEILING_SECS=5400\` (90 min)
- The watchdog monitors **both** client stdout staleness and server \`/proc/<pid>/io\` write_bytes
- Kill sequence: \`SIGTERM\` → 10s grace → \`SIGKILL\`
EOF
)

gh issue comment "${ISSUE_NUMBER}" \
  --repo "${REPO}" \
  --body "${BODY}"

echo "::notice::Failure comment posted to issue #${ISSUE_NUMBER}"
