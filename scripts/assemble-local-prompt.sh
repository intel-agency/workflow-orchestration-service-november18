#!/usr/bin/env bash
set -euo pipefail

# assemble-local-prompt.sh
#
# Assembles an orchestrator prompt for local testing.
#
# Modes:
#   Freeform:  -p "your prompt text"
#   Fixture:   -f test/fixtures/issues-opened.json
#
# Output: .assembled-orchestrator-prompt.md (default, override with -o)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROMPT_TEMPLATE="$REPO_ROOT/.github/workflows/prompts/orchestrator-agent-prompt.md"
OUTPUT_FILE="$REPO_ROOT/.assembled-orchestrator-prompt.md"

PROMPT_STRING=""
FIXTURE_FILE=""

usage() {
    local exit_code="${1:-1}"
    cat >&2 <<'EOF'
Usage: assemble-local-prompt.sh -p <prompt> | -f <fixture.json> [-o <output>]

  -p <prompt>     Freeform prompt string
  -f <fixture>    Path to a JSON event fixture file
  -o <output>     Output file path (default: .assembled-orchestrator-prompt.md)
  -h              Show this help

Examples:
  bash scripts/assemble-local-prompt.sh -p "say hello"
  bash scripts/assemble-local-prompt.sh -f test/fixtures/issues-opened.json
  bash scripts/assemble-local-prompt.sh -p "list issues" -o /tmp/my-prompt.md
EOF
    exit "$exit_code"
}

while getopts ":p:f:o:h" opt; do
    case $opt in
        p) PROMPT_STRING="$OPTARG" ;;
        f) FIXTURE_FILE="$OPTARG" ;;
        o) OUTPUT_FILE="$OPTARG" ;;
        h) usage 0 ;;
        *) usage ;;
    esac
done

if [[ -z "$PROMPT_STRING" && -z "$FIXTURE_FILE" ]]; then
    echo "ERROR: Either -p <prompt> or -f <fixture.json> is required" >&2
    usage
fi

if [[ -n "$PROMPT_STRING" && -n "$FIXTURE_FILE" ]]; then
    echo "ERROR: -p and -f are mutually exclusive" >&2
    usage
fi

# -----------------------------------------------------------------------
# Freeform mode — wrap user prompt with minimal context
# -----------------------------------------------------------------------
if [[ -n "$PROMPT_STRING" ]]; then
    cat > "$OUTPUT_FILE" <<PROMPT_EOF
# Orchestrator Agent Prompt — Local Invocation

## Context
- **Source**: Local manual dispatch
- **Timestamp**: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- **Repository**: $(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || echo "unknown")

## Prompt

$PROMPT_STRING
PROMPT_EOF

    echo "[assemble-local-prompt] Wrote freeform prompt to $OUTPUT_FILE ($(wc -c < "$OUTPUT_FILE") bytes)"
    exit 0
fi

# -----------------------------------------------------------------------
# Fixture mode — mimic CI prompt assembly
# -----------------------------------------------------------------------
if [[ ! -f "$FIXTURE_FILE" ]]; then
    echo "ERROR: Fixture file not found: $FIXTURE_FILE" >&2
    exit 1
fi

if [[ ! -f "$PROMPT_TEMPLATE" ]]; then
    echo "ERROR: Prompt template not found: $PROMPT_TEMPLATE" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for fixture mode" >&2
    exit 1
fi

# Extract event metadata from fixture
event_action=$(jq -r '.action // "unknown"' "$FIXTURE_FILE")
actor=$(jq -r '.sender.login // "local-user"' "$FIXTURE_FILE")
repo=$(jq -r '.repository.full_name // "local/repo"' "$FIXTURE_FILE")

# Determine event name from fixture filename (e.g. issues-opened.json → issues)
fixture_basename="$(basename "$FIXTURE_FILE" .json)"
event_name="${fixture_basename%%-*}"

# Build the context header
context_header="Event Name: ${event_name}
Action: ${event_action}
Actor: ${actor}
Repository: ${repo}
Ref: refs/heads/main
SHA: local-$(date +%s)"

# Read the prompt template
template_content=$(cat "$PROMPT_TEMPLATE")

# Assemble: template + event context + event JSON
{
    echo "$template_content"
    echo ""
    echo "## Event Context"
    echo ""
    echo '```'
    echo "$context_header"
    echo '```'
    echo ""
    echo "## __EVENT_DATA__"
    echo ""
    echo '```json'
    cat "$FIXTURE_FILE"
    echo '```'
} > "$OUTPUT_FILE"

echo "[assemble-local-prompt] Wrote fixture prompt to $OUTPUT_FILE ($(wc -c < "$OUTPUT_FILE") bytes)"
echo "[assemble-local-prompt]   event: ${event_name}, action: ${event_action}, actor: ${actor}"
