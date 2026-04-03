#!/usr/bin/env bash
set -euo pipefail

# setup-local-env.sh
#
# First-time local environment setup for opencode server orchestration.
#
# What it does:
#   1. Copies .env.example → .env (if .env doesn't exist)
#   2. Sources .env and validates required variables
#   3. Optionally logs into GHCR via gh CLI
#
# Usage:
#   bash scripts/setup-local-env.sh              # full setup
#   bash scripts/setup-local-env.sh --check-only  # validate env vars only
#   bash scripts/setup-local-env.sh --ghcr-login  # also docker-login to GHCR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_EXAMPLE="$REPO_ROOT/.env.example"
ENV_FILE="$REPO_ROOT/.env"

CHECK_ONLY=false
GHCR_LOGIN=false

for arg in "$@"; do
    case "$arg" in
        --check-only) CHECK_ONLY=true ;;
        --ghcr-login) GHCR_LOGIN=true ;;
        -h|--help)
            echo "Usage: $0 [--check-only] [--ghcr-login]"
            echo "  --check-only   Only validate environment variables (no file creation)"
            echo "  --ghcr-login   Also authenticate Docker to ghcr.io via gh CLI"
            exit 0
            ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

log() { echo "[setup-local-env] $*"; }

# -----------------------------------------------------------------------
# Step 1: Create .env from .env.example
# -----------------------------------------------------------------------
if [[ "$CHECK_ONLY" == false ]]; then
    if [[ -f "$ENV_FILE" ]]; then
        log ".env already exists — not overwriting"
    else
        if [[ ! -f "$ENV_EXAMPLE" ]]; then
            echo "ERROR: $ENV_EXAMPLE not found" >&2
            exit 1
        fi
        cp "$ENV_EXAMPLE" "$ENV_FILE"
        log "Created .env from .env.example — edit it to add your API keys"
    fi
fi

# -----------------------------------------------------------------------
# Step 2: Source .env and validate required variables
# -----------------------------------------------------------------------
if [[ -f "$ENV_FILE" ]]; then
    # Source only non-comment, non-empty lines as exports
    set -o allexport
    # shellcheck disable=SC1090
    source <(grep -v '^[[:space:]]*#' "$ENV_FILE" | grep -v '^[[:space:]]*$')
    set +o allexport
    log "Sourced $ENV_FILE"
fi

REQUIRED_VARS=(
    GH_ORCHESTRATION_AGENT_TOKEN
    ZHIPU_API_KEY
    KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY
)

missing=()
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        missing+=("$var")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    log "WARNING: The following required variables are not set:"
    for var in "${missing[@]}"; do
        echo "  - $var"
    done
    echo ""
    log "Edit .env and fill in the values, then re-run this script."
    if [[ "$CHECK_ONLY" == true ]]; then
        exit 1
    fi
else
    log "All required variables are set"
fi

# -----------------------------------------------------------------------
# Step 3: Optional GHCR login
# -----------------------------------------------------------------------
if [[ "$GHCR_LOGIN" == true ]]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "ERROR: gh CLI not found — install it from https://cli.github.com" >&2
        exit 1
    fi
    if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: docker not found" >&2
        exit 1
    fi
    log "Logging into ghcr.io via gh CLI..."
    gh auth token | docker login ghcr.io -u "$(gh api user --jq .login)" --password-stdin
    log "GHCR login successful"
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
# Helper to show "SET (N chars)" or "not set (optional)" without leaking values
_mask() {
    local val="${!1:-}"
    if [[ -n "$val" ]]; then echo "SET (${#val} chars)"; else echo "not set (optional)"; fi
}

echo ""
log "=== Environment Summary ==="
log "  GH_ORCHESTRATION_AGENT_TOKEN: $(_mask GH_ORCHESTRATION_AGENT_TOKEN)"
log "  ZHIPU_API_KEY:                $(_mask ZHIPU_API_KEY)"
log "  KIMI_CODE_..._API_KEY:        $(_mask KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY)"
log "  OPENAI_API_KEY:               $(_mask OPENAI_API_KEY)"
log "  GEMINI_API_KEY:               $(_mask GEMINI_API_KEY)"
log "  OPENCODE_SERVER_PORT:         ${OPENCODE_SERVER_PORT:-4096 (default)}"
echo ""
