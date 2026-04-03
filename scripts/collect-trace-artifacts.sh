#!/usr/bin/env bash
# collect-trace-artifacts.sh — Collect trace artifacts from the devcontainer and print job outcome summary.
# Called from the orchestrate job's always() steps.
#
# Required environment variables (set by GitHub Actions):
#   GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_NUMBER, GITHUB_SHA, GITHUB_REF
#
# Required arguments:
#   $1 — job status ("success", "failure", "cancelled")
#   $2 — event name (e.g. "issues")
#   $3 — event action (e.g. "labeled")
#   $4 — trigger label (may be empty)
#   $5 — actor
set -uo pipefail  # no -e: we don't want to abort on expected failures (missing files, etc.)

JOB_STATUS="${1:?Usage: $0 <job_status> <event_name> <event_action> <label> <actor>}"
EVENT_NAME="${2:?}"
EVENT_ACTION="${3:?}"
LABEL="${4:-N/A}"
ACTOR="${5:?}"

REPO="${GITHUB_REPOSITORY:?}"
RUN_ID="${GITHUB_RUN_ID:?}"
RUN_NUMBER="${GITHUB_RUN_NUMBER:?}"
SHA="${GITHUB_SHA:?}"
REF="${GITHUB_REF:?}"

# ── Collect trace artifacts ─────────────────────────────────────────
echo "::group::Trace artifact collection (runs on success AND failure)"
echo "Job status: ${JOB_STATUS}"
echo "Run outcome will be preserved in trace artifacts for post-mortem analysis"

mkdir -p /tmp/trace-artifacts

devcontainer exec \
  --workspace-folder . \
  --config .devcontainer/devcontainer.json \
  -- bash -c "
    mkdir -p /tmp/trace-bundle;
    cp ~/.local/share/opencode/log/*.log /tmp/trace-bundle/ 2>/dev/null || true;
    cp /tmp/opencode-serve.log /tmp/trace-bundle/opencode-serve.log 2>/dev/null || true;
    python3 scripts/trace-extract.py --scrub > /tmp/trace-bundle/subagent-traces.txt 2>&1 || true;
  "

devcontainer exec \
  --workspace-folder . \
  --config .devcontainer/devcontainer.json \
  -- bash -c "cat /tmp/trace-bundle/subagent-traces.txt" > /tmp/trace-artifacts/subagent-traces.txt 2>/dev/null || true

devcontainer exec \
  --workspace-folder . \
  --config .devcontainer/devcontainer.json \
  -- bash -c "tar -cf - -C /tmp/trace-bundle ." | tar -xf - -C /tmp/trace-artifacts/ 2>/dev/null || true

ARTIFACT_COUNT=$(find /tmp/trace-artifacts/ -maxdepth 1 -type f 2>/dev/null | wc -l)
echo "Trace artifacts collected: ${ARTIFACT_COUNT} files"
if [ "${ARTIFACT_COUNT}" -eq 0 ]; then
  echo "::warning::No trace artifacts found — devcontainer may not have started or logs were not produced"
else
  echo "Artifact listing:"
  ls -lhS /tmp/trace-artifacts/ 2>/dev/null
fi
echo "::endgroup::"

# ── Job outcome summary ─────────────────────────────────────────────
echo "========================================"
echo " ORCHESTRATOR JOB OUTCOME: ${JOB_STATUS}"
echo "========================================"
echo "Run:    #${RUN_NUMBER} (ID: ${RUN_ID})"
echo "Event:  ${EVENT_NAME}.${EVENT_ACTION}"
echo "Label:  ${LABEL}"
echo "Actor:  ${ACTOR}"
echo "Repo:   ${REPO}"
echo "Ref:    ${REF}"
echo "SHA:    ${SHA}"
if [ "${JOB_STATUS}" = "failure" ]; then
  echo "::error::Orchestrator job FAILED — check 'Post failure comment' step and trace artifacts for diagnostics"
elif [ "${JOB_STATUS}" = "success" ]; then
  echo "::notice::Orchestrator job completed successfully"
else
  echo "::warning::Orchestrator job ended with status: ${JOB_STATUS}"
fi
echo "========================================"
