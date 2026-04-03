# Local Orchestration Quick-Start Guide

Run the full opencode server + devcontainer orchestration stack on your local machine and dispatch prompts interactively — no GitHub Actions workflow runs required.

---

## 1. Prerequisites

| Tool | Required | Check |
|------|----------|-------|
| **Docker** (Docker Desktop or Docker Engine) | Yes | `docker --version` |
| **devcontainer CLI** | Yes | `devcontainer --version` |
| **gh CLI** | Recommended | `gh --version` |
| **jq** | For fixture-based prompts | `jq --version` |

Install the devcontainer CLI if you don't have it:

```bash
npm install -g @devcontainers/cli
```

---

## 2. First-Time Setup

### 2a. Clone the repo (if you haven't already)

```bash
git clone https://github.com/intel-agency/ai-new-workflow-app-template.git
cd ai-new-workflow-app-template
```

### 2b. Configure environment variables

```bash
bash scripts/setup-local-env.sh
```

This copies `.env.example` → `.env`. Edit `.env` and fill in your API keys:

```bash
# Open .env in your editor and add your keys:
# - GH_ORCHESTRATION_AGENT_TOKEN  (required)
# - ZHIPU_API_KEY                 (required)
# - KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY (required)
```

Re-run to validate:

```bash
bash scripts/setup-local-env.sh
```

### 2c. Login to GHCR (so Docker can pull the prebuild image)

```bash
bash scripts/setup-local-env.sh --ghcr-login
```

Or manually:

```bash
gh auth token | docker login ghcr.io -u "$(gh api user --jq .login)" --password-stdin
```

### 2d. Source your environment

Before starting the server, export the variables so the devcontainer can read them:

```bash
set -a; source .env; set +a
```

Or use the setup helper:

```bash
bash scripts/setup-local-env.sh
```

---

## 3. Start the Stack

### One command — start devcontainer + opencode server

```bash
bash scripts/devcontainer-opencode.sh up
bash scripts/devcontainer-opencode.sh start
```

Or use the PowerShell wrapper (which does both):

```powershell
./scripts/prompt-local.ps1 -Prompt "say hello"
# ^ This auto-starts the devcontainer + server if not already running
```

The devcontainer pulls the prebuild image from GHCR, starts the container, and the `postStartCommand` launches the opencode server on port 4096.

---

## 4. Send Your First Prompt

### Direct mode (recommended — no server needed)

```bash
bash scripts/prompt-direct.sh -p "Say hello and confirm you are operational."
```

From a file:

```bash
bash scripts/prompt-direct.sh -f test/fixtures/prompts/hello-world.txt
```

With a different model:

```bash
bash scripts/prompt-direct.sh -p "list open issues" -m zai-coding-plan/glm-4.7-flash
```

> **Direct mode** runs opencode as a one-shot process inside the devcontainer.
> It handles all env var passthrough automatically. No opencode server daemon needed.

### Server-attach mode (alternative — uses opencode serve daemon)

```bash
bash scripts/devcontainer-opencode.sh start   # start the server daemon
bash scripts/devcontainer-opencode.sh prompt -p "Say hello and confirm you are operational."
```

> **Note**: The server daemon may exit unexpectedly between start and prompt dispatch.
> If you see `"Session not found"` or `"failed to list agents"`, use direct mode instead.

### Using the local prompt assembler (fixture-based — simulates CI events)

```bash
# Assemble a prompt from a webhook fixture
bash scripts/assemble-local-prompt.sh -f test/fixtures/issues-opened.json

# Then dispatch it
bash scripts/devcontainer-opencode.sh prompt -f .assembled-orchestrator-prompt.md
```

### PowerShell (with auto-start)

```powershell
./scripts/prompt-local.ps1 -Prompt "list open issues and summarize them"
./scripts/prompt-local.ps1 -File test/fixtures/prompts/create-epic.txt
./scripts/prompt-local.ps1 -Prompt "list open issues" -SkipStart  # already running
```

### Sample prompts included

| File | Description |
|------|-------------|
| `test/fixtures/prompts/hello-world.txt` | Basic health check |
| `test/fixtures/prompts/list-issues.txt` | List and summarize open issues |
| `test/fixtures/prompts/create-epic.txt` | Full orchestration command (create-epic-v2) |

---

## 5. Check Status and Logs

```bash
bash scripts/devcontainer-opencode.sh status
```

This reports:
- Container state (running/stopped)
- Opencode server PID and health (UP/DOWN)
- Memory file state
- Last 20 lines of server log

---

## 6. Shut Down

### Stop (keeps container for fast restart)

```bash
bash scripts/devcontainer-opencode.sh stop
```

### Full teardown (removes container)

```bash
bash scripts/devcontainer-opencode.sh down
```

To restart after `stop`:

```bash
bash scripts/devcontainer-opencode.sh up
bash scripts/devcontainer-opencode.sh start
```

---

## 7. Troubleshooting

### "Devcontainer image not found"

The prebuild GHCR image must be accessible. Ensure you've logged into GHCR:

```bash
bash scripts/setup-local-env.sh --ghcr-login
docker pull ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer:main-latest
```

### "opencode is not installed or not on PATH"

This means the devcontainer image doesn't have opencode. Verify the image:

```bash
docker run --rm ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer:main-latest which opencode
```

### "GH_ORCHESTRATION_AGENT_TOKEN is not set"

Source your `.env` before starting:

```bash
set -a; source .env; set +a
```

Or use the setup helper:

```bash
bash scripts/setup-local-env.sh
```

### Server won't start / port conflict

Check if something else is using port 4096:

```bash
lsof -i :4096
# Or on systems without lsof:
# Linux: netstat -anp | grep 4096
# Windows: netstat -ano | findstr "4096"
```

Override the port:

```bash
export OPENCODE_SERVER_PORT=4097
```

### Prompt dispatched but no response

Check server health and logs:

```bash
bash scripts/devcontainer-opencode.sh status
```

Look for errors in the server log (shown by `status`). Common causes:
- API key is invalid or expired
- Model provider is down
- Token doesn't have required GitHub scopes

### How to verify token scopes

```bash
gh api rate_limit --include 2>&1 | grep -i 'X-OAuth-Scopes'
```

Required scopes: `repo`, `workflow`, `project`, `read:org`

---

## Architecture Overview

```
Host Machine                          Devcontainer (Docker)
─────────────                         ────────────────────
.env (API keys)                       opencode serve :4096
  │                                      ▲
  └─► devcontainer-opencode.sh ──up──►   │
                               ──start─► starts server
                               ──prompt► opencode run --attach http://127.0.0.1:4096
                               ──status► health check + logs
                               ──stop──► docker stop
```

---

## Related Files

| File | Purpose |
|------|---------|
| `scripts/prompt-direct.sh` | Direct-mode prompt dispatcher (recommended, no server) |
| `scripts/devcontainer-opencode.sh` | Main lifecycle CLI (up/start/prompt/status/stop/down) |
| `scripts/start-opencode-server.sh` | Server daemon bootstrapper (runs inside container) |
| `scripts/prompt-local.ps1` | PowerShell local prompt dispatcher |
| `scripts/assemble-local-prompt.sh` | Local prompt assembly from fixtures/freeform |
| `scripts/setup-local-env.sh` | First-time env setup |
| `.env.example` | Environment variable template |
| `.devcontainer/devcontainer.json` | Consumer devcontainer config |
| `docs/local-lan-orchestration-plan.md` | Full plan (Phases 1-3) |

