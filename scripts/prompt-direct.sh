#!/usr/bin/env bash
set -euo pipefail

# prompt-direct.sh
#
# Run opencode DIRECTLY inside the devcontainer (no server required).
# This bypasses the opencode serve daemon entirely — opencode runs as a
# one-shot process and exits when the prompt is complete.
#
# Usage:
#   bash scripts/prompt-direct.sh -p "say hello"
#   bash scripts/prompt-direct.sh -f test/fixtures/prompts/hello-world.txt
#   bash scripts/prompt-direct.sh -f .assembled-orchestrator-prompt.md
#
# The devcontainer must already be running (use: bash scripts/devcontainer-opencode.sh up)

DEVCONTAINER_CONFIG="${DEVCONTAINER_CONFIG:-.devcontainer/devcontainer.json}"
WORKSPACE_FOLDER="${WORKSPACE_FOLDER:-.}"
MODEL="${OPENCODE_MODEL:-zai-coding-plan/glm-5}"
AGENT="${OPENCODE_AGENT:-orchestrator}"
LOG_LEVEL="${OPENCODE_LOG_LEVEL:-INFO}"

PROMPT_STRING=""
PROMPT_FILE=""

usage() {
    cat >&2 <<'EOF'
Usage: prompt-direct.sh -p <prompt> | -f <file> [options]

  -p <prompt>     Inline prompt string
  -f <file>       Path to prompt file (read from host, passed as string)
  -m <model>      Model (default: zai-coding-plan/glm-5, env: OPENCODE_MODEL)
  -a <agent>      Agent (default: orchestrator, env: OPENCODE_AGENT)
  -l <level>      Log level: DEBUG|INFO|WARN|ERROR (default: INFO)
  -c <config>     devcontainer.json path (default: .devcontainer/devcontainer.json)
  -w <dir>        Workspace folder (default: .)
  -h              Show this help

Examples:
  bash scripts/prompt-direct.sh -p "say hello"
  bash scripts/prompt-direct.sh -p "list open issues" -a orchestrator
  bash scripts/prompt-direct.sh -f test/fixtures/prompts/create-epic.txt
  bash scripts/prompt-direct.sh -p "say hello" -m zai-coding-plan/glm-4.7-flash
EOF
    exit 1
}

while getopts ":p:f:m:a:l:c:w:h" opt; do
    case $opt in
        p) PROMPT_STRING="$OPTARG" ;;
        f) PROMPT_FILE="$OPTARG" ;;
        m) MODEL="$OPTARG" ;;
        a) AGENT="$OPTARG" ;;
        l) LOG_LEVEL="$OPTARG" ;;
        c) DEVCONTAINER_CONFIG="$OPTARG" ;;
        w) WORKSPACE_FOLDER="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "$PROMPT_STRING" && -z "$PROMPT_FILE" ]]; then
    echo "ERROR: Either -p <prompt> or -f <file> is required" >&2
    usage
fi

# Resolve prompt content
if [[ -n "$PROMPT_FILE" ]]; then
    if [[ ! -f "$PROMPT_FILE" ]]; then
        echo "ERROR: Prompt file not found: $PROMPT_FILE" >&2
        exit 1
    fi
    PROMPT_STRING="$(cat "$PROMPT_FILE")"
fi

# Validate required env vars
for var in GH_ORCHESTRATION_AGENT_TOKEN ZHIPU_API_KEY KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is not set. Source your .env first:" >&2
        echo "  export \$(grep -v '^#' .env | grep -v '^\s*\$' | xargs)" >&2
        exit 1
    fi
done

# Check container is running
abs_workspace="$(cd "$WORKSPACE_FOLDER" && pwd)"
container_id="$(docker ps -q --filter "label=devcontainer.local_folder=${abs_workspace}")"
if [[ -z "$container_id" ]]; then
    echo "ERROR: No running devcontainer found. Start it first:" >&2
    echo "  bash scripts/devcontainer-opencode.sh up" >&2
    exit 1
fi

# Derive server-side working dir
CONTAINER_DIR="/workspaces/$(basename "$abs_workspace")"

echo "[prompt-direct] model: $MODEL | agent: $AGENT | log-level: $LOG_LEVEL"
echo "[prompt-direct] container: $container_id | dir: $CONTAINER_DIR"
echo "[prompt-direct] prompt: ${#PROMPT_STRING} chars"
echo "---"

devcontainer exec \
    --workspace-folder "$WORKSPACE_FOLDER" \
    --config "$DEVCONTAINER_CONFIG" \
    --remote-env ZHIPU_API_KEY="$ZHIPU_API_KEY" \
    --remote-env KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY="$KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY" \
    --remote-env GITHUB_TOKEN="$GH_ORCHESTRATION_AGENT_TOKEN" \
    --remote-env GITHUB_PERSONAL_ACCESS_TOKEN="$GH_ORCHESTRATION_AGENT_TOKEN" \
    --remote-env GH_ORCHESTRATION_AGENT_TOKEN="$GH_ORCHESTRATION_AGENT_TOKEN" \
    --remote-env GH_TOKEN="$GH_ORCHESTRATION_AGENT_TOKEN" \
    --remote-env OPENCODE_EXPERIMENTAL=1 \
    ${OPENAI_API_KEY:+--remote-env OPENAI_API_KEY="$OPENAI_API_KEY"} \
    ${GEMINI_API_KEY:+--remote-env GOOGLE_GENERATIVE_AI_API_KEY="$GEMINI_API_KEY"} \
    -- opencode run \
        --model "$MODEL" \
        --agent "$AGENT" \
        --log-level "$LOG_LEVEL" \
        --print-logs \
        --thinking \
        --dir "$CONTAINER_DIR" \
        "$PROMPT_STRING"
