#!/usr/bin/env bash
# on-failure-handler.sh — Dedicated failure handler for the orchestrator workflow.
# Runs in the on-failure job after the orchestrate job fails.
# Gathers context, posts a catch-all comment (if the in-job handler didn't already), and annotates the run.
#
# Required environment variables (set by GitHub Actions):
#   GH_TOKEN, GITHUB_REPOSITORY, GITHUB_SERVER_URL, GITHUB_RUN_ID, GITHUB_RUN_NUMBER
#
# Required arguments:
#   $1 — event name (e.g. "issues")
#   $2 — event action (e.g. "labeled")
#   $3 — trigger label name
#   $4 — actor
#   $5 — issue number (may be empty for non-issue events)
#   $6 — issue title  (may be empty for non-issue events)
set -euo pipefail

EVENT_NAME="${1:?Usage: $0 <event_name> <event_action> <label> <actor> [issue_number] [issue_title]}"
EVENT_ACTION="${2:?}"
LABEL="${3:?}"
ACTOR="${4:?}"
ISSUE_NUMBER="${5:-}"
ISSUE_TITLE="${6:-}"

REPO="${GITHUB_REPOSITORY:?}"
SERVER_URL="${GITHUB_SERVER_URL:?}"
RUN_ID="${GITHUB_RUN_ID:?}"
RUN_NUMBER="${GITHUB_RUN_NUMBER:?}"
RUN_URL="${SERVER_URL}/${REPO}/actions/runs/${RUN_ID}"

# ── Step 1: Gather context ──────────────────────────────────────────
echo "========================================"
echo " ON-FAILURE HANDLER"
echo " Orchestrate job failed — running"
echo " post-failure diagnostics"
echo "========================================"
echo "Run:    #${RUN_NUMBER} (ID: ${RUN_ID})"
echo "Event:  ${EVENT_NAME}.${EVENT_ACTION}"
echo "Label:  ${LABEL:-N/A}"
echo "Actor:  ${ACTOR}"
echo "Repo:   ${REPO}"
echo ""

echo "::group::Failed job details"
gh api \
  "repos/${REPO}/actions/runs/${RUN_ID}/jobs" \
  --jq '.jobs[] | select(.conclusion == "failure") | {name, conclusion, started_at, completed_at, html_url}' \
  2>/dev/null || echo "Could not fetch job details"
echo "::endgroup::"

STARTED="$(gh api "repos/${REPO}/actions/runs/${RUN_ID}" --jq '.run_started_at' 2>/dev/null || true)"
if [ -n "$STARTED" ]; then
  echo "Run started at: $STARTED"
fi

# ── Step 2: Post catch-all comment (with dedup) ─────────────────────
if [ "${EVENT_NAME}" = "issues" ] && [ -n "${ISSUE_NUMBER}" ]; then
  EXISTING_COMMENTS=$(gh api \
    "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" \
    --jq '[.[] | select(.body | contains("Orchestrator Run Failed") or contains("Orchestrator run failed"))] | length' \
    2>/dev/null || echo "0")

  if [ "${EXISTING_COMMENTS}" -gt 0 ]; then
    echo "::notice::In-job failure comment already posted — skipping duplicate from on-failure handler"
  else
    BODY=$(cat <<EOF
## :x: Orchestrator Workflow Failed (on-failure handler)

The orchestrator job failed **before** the agent execution step completed.
This typically means a setup failure (devcontainer build, image pull, prompt assembly, etc.).

| Field | Value |
|-------|-------|
| **Run** | [#${RUN_NUMBER}](${RUN_URL}) |
| **Trigger label** | \`${LABEL}\` |
| **Issue** | #${ISSUE_NUMBER} — ${ISSUE_TITLE} |
| **Event** | \`${EVENT_NAME}.${EVENT_ACTION}\` |

### Recovery
1. Check the [workflow run logs](${RUN_URL}) to identify which step failed
2. Fix the underlying issue (image not found, secret missing, etc.)
3. Remove and re-apply \`${LABEL}\` to retry
EOF
    )

    gh issue comment "${ISSUE_NUMBER}" \
      --repo "${REPO}" \
      --body "${BODY}"
    echo "::notice::On-failure handler posted catch-all comment to issue #${ISSUE_NUMBER}"
  fi
fi

# ── Step 3: Annotate the run ────────────────────────────────────────
echo "::error::ORCHESTRATOR FAILED — The 'orchestrate' job did not complete successfully."
echo "::error::Event: ${EVENT_NAME}.${EVENT_ACTION} | Label: ${LABEL:-N/A} | Run: #${RUN_NUMBER}"
echo "::error::Review the 'orchestrate' job logs and trace artifacts for root cause."
