# workflow-orchestration-service Standalone Orchestration Service — Full Migration & Implementation Plan

> **Status:** Ready for Autonomous Implementation  
> **Architecture Guide:** workflow-orchestration-service Architecture Guide v3.2 (expected in `plan_docs/`)  
> **Last Updated:** 2026-03-28

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Target Architecture](#2-target-architecture)
3. [Existing Code Inventory](#3-existing-code-inventory)
4. [Phase 0 — Foundation & Dockerfile Consolidation](#4-phase-0--foundation--dockerfile-consolidation)
5. [Phase 1 — Server: Self-Contained Orchestration Service](#5-phase-1--server-self-contained-orchestration-service)
6. [Phase 2 — Client: Remote Prompt Script & Session Management](#6-phase-2--client-remote-prompt-script--session-management)
7. [Phase 3 — Client: Webhook Handler & Event Routing](#7-phase-3--client-webhook-handler--event-routing)
8. [Phase 4 — GitHub App Event Source Integration](#8-phase-4--github-app-event-source-integration)
9. [Phase 5 — Production Hardening & Observability](#9-phase-5--production-hardening--observability)
10. [Cross-Cutting Concerns](#10-cross-cutting-concerns)
11. [Agent Assignment Matrix](#11-agent-assignment-matrix)
12. [Risk Register](#12-risk-register)
13. [Appendix: File Migration Map](#13-appendix-file-migration-map)

---

## 1. Executive Summary

### Vision

Migrate the orchestration workflow agent from a GitHub Actions-embedded model to a **standalone, self-hosted, networked client/server service**. The server runs the full orchestration stack inside a Docker/DevContainer image. The client is a Python service that receives GitHub events via webhooks and dispatches prompts to the remote server using the existing `devcontainer-opencode.sh` shell bridge protocol.

### Key Insight — Existing Code Coverage

The workflow-orchestration-service codebase already provides substantial implementation coverage:

| Component | Existing Implementation | Location |
|-----------|------------------------|----------|
| Sentinel Orchestrator (polling, claiming, heartbeats, shell bridge) | **~90% complete** | `plan_docs/orchestrator_sentinel.py` |
| Webhook Notifier (FastAPI, HMAC verification, event triage) | **~80% complete** | `plan_docs/notifier_service.py` |
| Unified Work Item Model (Pydantic, credential scrubbing) | **~95% complete** | `plan_docs/src/models/work_item.py`, `scripts/WorkItemModel.py` |
| GitHub Queue (ITaskQueue, claim, heartbeat, status updates) | **~85% complete** | `plan_docs/src/queue/github_queue.py` |
| Shell Bridge (devcontainer lifecycle, prompt dispatch) | **100% complete** | `scripts/devcontainer-opencode.sh` |
| OpenCode Server Bootstrap | **100% complete** | `scripts/start-opencode-server.sh` |
| OpenCode Prompt Runner (auth, validation, model dispatch) | **100% complete** | `run_opencode_prompt.sh` |

The migration is primarily an **integration and packaging** effort — not a greenfield build.

### End-State Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                     ORCHESTRATION SERVER (Docker Container)                   │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────┐     │
│  │  Docker Image (self-contained)                                     │     │
│  │                                                                    │     │
│  │  /opt/orchestration/                                               │     │
│  │  ├── .opencode/agents/ (27 specialist agents)                      │     │
│  │  ├── .opencode/commands/ (20 command prompts)                      │     │
│  │  ├── opencode.json (model configs, MCP defs)                       │     │
│  │  ├── AGENTS.md (generic orchestration instructions)                │     │
│  │  ├── prompts/orchestrator-agent-prompt.md (match clauses)          │     │
│  │  ├── scripts/                                                      │     │
│  │  │   ├── devcontainer-opencode.sh (shell bridge)                   │     │
│  │  │   ├── start-opencode-server.sh (server bootstrap)               │     │
│  │  │   ├── assemble-orchestrator-prompt.sh                           │     │
│  │  │   └── resolve-image-tags.sh                                     │     │
│  │  └── run_opencode_prompt.sh (auth + agent invocation)              │     │
│  │                                                                    │     │
│  │  Runtimes: opencode CLI, .NET SDK 10, Bun, uv, Node.js            │     │
│  │  MCP: sequential-thinking, memory                                  │     │
│  │  Port: 4096 (opencode serve)                                       │     │
│  └────────────────────────────────────────────────────────────────────┘     │
│                                                                              │
└────────────────────────────────────┬─────────────────────────────────────────┘
                                     │
                          TCP :4096 (opencode attach)
                                     │
┌────────────────────────────────────┴─────────────────────────────────────────┐
│                     ORCHESTRATION CLIENT (Python Service)                     │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────┐     │
│  │  Webhook Handler (FastAPI)                                         │     │
│  │  ├── POST /webhooks/github  (HMAC-verified)                        │     │
│  │  ├── GET  /health                                                  │     │
│  │  └── Event triage → WorkItem → prompt dispatch                     │     │
│  └────────────────────────────────────────────────────────────────────┘     │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────┐     │
│  │  Sentinel Orchestrator (Polling Loop)                              │     │
│  │  ├── GitHub Issues polling (agent:queued label)                    │     │
│  │  ├── Assign-then-verify distributed locking                        │     │
│  │  ├── Shell bridge dispatch via devcontainer-opencode.sh            │     │
│  │  ├── Heartbeat comments (5-min interval)                           │     │
│  │  └── Status label lifecycle management                             │     │
│  └────────────────────────────────────────────────────────────────────┘     │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────┐     │
│  │  Shared Components                                                 │     │
│  │  ├── src/models/work_item.py (Pydantic WorkItem, scrub_secrets)    │     │
│  │  ├── src/queue/github_queue.py (ITaskQueue, GitHubQueue)           │     │
│  │  └── scripts/devcontainer-opencode.sh (shell bridge — local copy)  │     │
│  └────────────────────────────────────────────────────────────────────┘     │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
                                     │
                          HTTPS (GitHub App webhooks)
                                     │
┌────────────────────────────────────┴─────────────────────────────────────────┐
│                     GITHUB APP (Event Source)                                 │
│                                                                              │
│  Events: issues.labeled, issues.opened, pull_request.opened,                 │
│          pull_request.review_submitted, workflow_dispatch                     │
│  Webhook URL: https://<client-host>:8000/webhooks/github                     │
│  Secret: WEBHOOK_SECRET (HMAC SHA-256 verification)                          │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Design Principles

1. **Shell Bridge as Primary API** (ADR-07): The Sentinel interacts with the orchestration server exclusively via `devcontainer-opencode.sh`. No Docker SDK reimplementation.
2. **Polling-First Resiliency** (ADR-08): Webhook delivery is an optimization; polling ensures self-healing on restart.
3. **Provider-Agnostic Queue** (ADR-09): All queue interactions go through `ITaskQueue` ABC — GitHub today, Linear/Jira later.
4. **Option 2 Architecture**: Separate webhook handler service forwards events to the orchestration server. Better separation of concerns and independent scaling.
5. **Credential Scrubbing** (R-7): All output posted to GitHub is sanitized via `scrub_secrets()` before posting.

---

## 2. Target Architecture

### 2.1 Component Responsibilities

| Component | Role | Technology | Deployment |
|-----------|------|------------|------------|
| **Orchestration Server** | Runs `opencode serve`, executes orchestration workflows, manages agent delegation | Docker container, opencode CLI, MCP servers | Self-hosted Linux (or cloud VM) |
| **Orchestration Client** | Receives events, triages work items, dispatches prompts to server | Python 3.12, FastAPI, httpx, Pydantic | Self-hosted (same or different host) |
| **GitHub App** | Delivers repository events as webhooks | GitHub platform | GitHub cloud |

### 2.2 Network Topology

```
                    Internet
                       │
            ┌──────────┴──────────┐
            │    GitHub Cloud      │
            │  (Webhook delivery)  │
            └──────────┬──────────┘
                       │ HTTPS :443
                       ▼
            ┌─────────────────────┐
            │   Reverse Proxy     │  (nginx/Caddy — TLS termination)
            │   Port 443 → 8000   │
            └──────────┬──────────┘
                       │ HTTP :8000
                       ▼
            ┌─────────────────────┐
            │  Orchestration      │
            │  Client (FastAPI)   │──── polling ────▶ GitHub API
            │  Port 8000          │
            └──────────┬──────────┘
                       │ HTTP :4096
                       ▼
            ┌─────────────────────┐
            │  Orchestration      │
            │  Server (opencode)  │
            │  Port 4096          │
            └─────────────────────┘
```

### 2.3 Data Flow — Happy Path

```
1. GitHub App fires webhook → POST /webhooks/github (Client)
2. Client verifies HMAC SHA-256 signature
3. Client triages event → creates WorkItem
4. Client adds `agent:queued` label via GitHub API
5. Sentinel polling loop detects queued issue
6. Sentinel claims task (assign-then-verify pattern)
7. Sentinel updates label: agent:queued → agent:in-progress
8. Sentinel calls: devcontainer-opencode.sh prompt -p "<instruction>" -u <server-url>
9. Shell bridge invokes: opencode run --attach <server-url> --agent orchestrator "<prompt>"
10. Orchestrator agent executes workflow, delegates to specialists
11. On completion: Sentinel updates label → agent:success, posts summary comment
12. Sentinel resets environment, returns to polling
```

### 2.4 Data Flow — Sentinel Shell Bridge Detail

The Sentinel's `process_task()` method uses the shell bridge in a **three-stage lifecycle**:

```
Stage 1: Infrastructure Setup
  └─ devcontainer-opencode.sh up         (provisions/reconnects container)

Stage 2: Server Readiness
  └─ devcontainer-opencode.sh start      (ensures opencode serve is running)

Stage 3: Prompt Dispatch
  └─ devcontainer-opencode.sh prompt     (dispatches prompt to agent)
     └─ -p "<workflow instruction>"      (inline prompt text)
     └─ -u http://<server>:4096          (remote server URL)
     └─ -d /workspaces/<repo>            (server-side working dir)
```

This is **already implemented** in `orchestrator_sentinel.py` lines 130–175 (`process_task` method).

---

## 3. Existing Code Inventory

### 3.1 Python Modules (Ready for Integration)

#### `plan_docs/orchestrator_sentinel.py` — The Sentinel Orchestrator

**Status:** Implementation-complete for Phase 1 core logic.

| Feature | Status | Notes |
|---------|--------|-------|
| Configuration from env vars | ✅ Complete | `GITHUB_TOKEN`, `GITHUB_ORG`, `GITHUB_REPO`, `SENTINEL_BOT_LOGIN` |
| Signal handling (SIGTERM/SIGINT) | ✅ Complete | Graceful shutdown with `_shutdown_requested` flag |
| Shell bridge interface (`run_shell_command`) | ✅ Complete | Async subprocess with configurable timeout + kill |
| 3-stage task processing (`up` → `start` → `prompt`) | ✅ Complete | Full lifecycle with error classification |
| Heartbeat loop (5-min interval) | ✅ Complete | `asyncio.create_task` with `finally` cancellation |
| Polling with jittered exponential backoff | ✅ Complete | Handles HTTP 403/429, max backoff 960s |
| Entry point with env validation | ✅ Complete | Checks required vars, warns on missing `SENTINEL_BOT_LOGIN` |
| Subprocess hard timeout (95 min) | ✅ Complete | Safety net above `run_opencode_prompt.sh` ceiling |

**Required Changes for Migration:**
- Update `SHELL_BRIDGE_PATH` to point to the client's local copy of `devcontainer-opencode.sh`
- Add remote server URL configuration (`OPENCODE_SERVER_URL` env var)
- Pass `-u <server-url>` to the prompt command for remote server dispatch
- Add structured logging output to file (JSON-L format)

#### `plan_docs/notifier_service.py` — The Webhook Handler

**Status:** Implementation-complete for basic GitHub issue events.

| Feature | Status | Notes |
|---------|--------|-------|
| FastAPI application | ✅ Complete | Title: "workflow-orchestration-service Event Notifier" |
| HMAC SHA-256 webhook verification | ✅ Complete | Via `verify_signature` dependency |
| Environment validation (startup) | ✅ Complete | Fails fast if `WEBHOOK_SECRET` or `GITHUB_TOKEN` is placeholder |
| Issue opened event handling | ✅ Complete | Triages by title pattern and labels |
| Health check endpoint | ✅ Complete | `GET /health` |
| Dependency injection for queue | ✅ Complete | `get_queue()` returns `GitHubQueue` |

**Required Changes for Migration:**
- Add `issues.labeled` event handling (match current `orchestrator-agent.yml` trigger)
- Add `pull_request` event handling
- Add `workflow_dispatch` event handling
- Add prompt dispatch to remote server (integrate with Sentinel or direct shell bridge call)
- Add event payload forwarding to prompt assembly pipeline

#### `plan_docs/src/models/work_item.py` — Unified Work Item Model

**Status:** Complete. Production-ready.

| Feature | Status |
|---------|--------|
| `TaskType` enum (PLAN, IMPLEMENT, BUGFIX) | ✅ Complete |
| `WorkItemStatus` enum (7 states with GitHub label mapping) | ✅ Complete |
| `WorkItem` Pydantic model | ✅ Complete |
| `scrub_secrets()` credential sanitizer (8 patterns) | ✅ Complete |

**No changes required.** This module is the shared data contract.

#### `plan_docs/src/queue/github_queue.py` — GitHub-Backed Work Queue

**Status:** Complete. Production-ready.

| Feature | Status | Notes |
|---------|--------|-------|
| `ITaskQueue` ABC (add, fetch, update) | ✅ Complete | Strategy pattern for provider swapping |
| `GitHubQueue` implementation | ✅ Complete | Connection-pooled `httpx.AsyncClient` |
| `add_to_queue()` — label application | ✅ Complete | |
| `fetch_queued_tasks()` — polling | ✅ Complete | Single-repo; org-wide planned for future |
| `update_status()` — label lifecycle + comments | ✅ Complete | Includes `scrub_secrets()` |
| `claim_task()` — assign-then-verify locking | ✅ Complete | Full distributed lock implementation |
| `post_heartbeat()` — periodic status | ✅ Complete | |
| `close()` — connection pool cleanup | ✅ Complete | |

**No changes required.** This module is the shared queue implementation.

### 3.2 Shell Scripts (Ready for COPY into Dockerfile)

| Script | Purpose | Migration Action |
|--------|---------|-----------------|
| `scripts/devcontainer-opencode.sh` | Shell bridge — devcontainer lifecycle + prompt dispatch | COPY to `/opt/orchestration/scripts/` in server; local copy in client |
| `scripts/start-opencode-server.sh` | `opencode serve` daemon bootstrap with `setsid` | COPY to `/opt/orchestration/scripts/` in server |
| `scripts/assemble-orchestrator-prompt.sh` | Prompt assembly from template + event JSON | COPY to `/opt/orchestration/scripts/` in server |
| `run_opencode_prompt.sh` | Auth validation + `opencode run` invocation | COPY to `/opt/orchestration/` in server |
| `scripts/resolve-image-tags.sh` | Image tag resolution helpers | COPY to `/opt/orchestration/scripts/` in server |

### 3.3 Agent Definitions & Config (Ready for COPY into Dockerfile)

| Path | Contents | Count |
|------|----------|-------|
| `.opencode/agents/*.md` | Specialist agent definitions | 27 agents |
| `.opencode/commands/*.md` | Reusable command prompts | 20 commands |
| `opencode.json` | Model configs (GLM-5, GPT-5.4, Gemini 3), MCP server defs | 1 file |
| `.github/workflows/prompts/orchestrator-agent-prompt.md` | Match clauses / orchestration state machine | 1 file |
| `AGENTS.md` | Orchestration instructions (generic sections) | 1 file |

---

## 4. Phase 0 — Foundation & Dockerfile Consolidation

### 4.0 Objective

Update the Dockerfile to include all necessary files for a self-contained orchestration service image. This is primarily adding `COPY` statements and adjusting paths.

### 4.1 Tasks

#### P0-T1: Define Server Directory Structure

**Agent:** `devops-engineer`

Establish the canonical directory layout inside the Docker image:

```
/opt/orchestration/
├── .opencode/
│   ├── agents/          (27 specialist agent .md files)
│   ├── commands/        (20 command prompt .md files)
│   └── package.json     (MCP server dependencies)
├── prompts/
│   └── orchestrator-agent-prompt.md
├── scripts/
│   ├── devcontainer-opencode.sh
│   ├── start-opencode-server.sh
│   ├── assemble-orchestrator-prompt.sh
│   └── resolve-image-tags.sh
├── opencode.json
├── AGENTS.md
└── run_opencode_prompt.sh
```

**AC:**
- [ ] Directory structure documented and agreed upon
- [ ] All file paths are absolute and deterministic (no symlinks required at runtime)

#### P0-T2: Add COPY Directives to Dockerfile

**Agent:** `devops-engineer`

Add `COPY` statements to the existing Dockerfile for all workspace-root files needed by the orchestration service:

```dockerfile
# --- Orchestration Runtime ---
COPY .opencode/agents/    /opt/orchestration/.opencode/agents/
COPY .opencode/commands/  /opt/orchestration/.opencode/commands/
COPY .opencode/package.json /opt/orchestration/.opencode/package.json
COPY opencode.json        /opt/orchestration/opencode.json
COPY AGENTS.md            /opt/orchestration/AGENTS.md
COPY .github/workflows/prompts/orchestrator-agent-prompt.md \
                          /opt/orchestration/prompts/orchestrator-agent-prompt.md

# --- Scripts ---
COPY scripts/devcontainer-opencode.sh     /opt/orchestration/scripts/
COPY scripts/start-opencode-server.sh     /opt/orchestration/scripts/
COPY scripts/assemble-orchestrator-prompt.sh /opt/orchestration/scripts/
COPY scripts/resolve-image-tags.sh        /opt/orchestration/scripts/
COPY run_opencode_prompt.sh               /opt/orchestration/

# Ensure scripts are executable
RUN chmod +x /opt/orchestration/scripts/*.sh /opt/orchestration/run_opencode_prompt.sh
```

**AC:**
- [ ] `docker build` succeeds with no errors
- [ ] All files present at expected paths inside the image (verified by `docker run --rm <image> ls -la /opt/orchestration/`)
- [ ] Scripts are executable (`-x` permission set)
- [ ] Image size increase is documented (expected: minimal — these are text files)

#### P0-T3: Update Path References in Scripts

**Agent:** `developer`

Update hardcoded relative paths in scripts to work from `/opt/orchestration/`:

| Script | Change Required |
|--------|----------------|
| `run_opencode_prompt.sh` | No change needed — already uses `opencode run` with CLI args |
| `start-opencode-server.sh` | No change needed — uses `opencode serve` CLI |
| `devcontainer-opencode.sh` | Update internal references to use `$ORCHESTRATION_ROOT` env var (default: `/opt/orchestration`) |
| `assemble-orchestrator-prompt.sh` | Update template path to `$ORCHESTRATION_ROOT/prompts/orchestrator-agent-prompt.md` |

Add to Dockerfile:
```dockerfile
ENV ORCHESTRATION_ROOT=/opt/orchestration
```

**AC:**
- [ ] `ORCHESTRATION_ROOT` env var is set in the image
- [ ] All scripts resolve paths relative to `ORCHESTRATION_ROOT`
- [ ] `devcontainer-opencode.sh start` works when invoked from `/opt/orchestration/`
- [ ] `assemble-orchestrator-prompt.sh` correctly finds the prompt template

#### P0-T4: Install Python Dependencies in Image

**Agent:** `devops-engineer`

Add Python dependency installation for the client-side components that will run inside the container for testing:

```dockerfile
# Python dependencies for workflow-orchestration-service components
COPY requirements.txt /opt/orchestration/requirements.txt
RUN uv pip install --system -r /opt/orchestration/requirements.txt
```

Where `requirements.txt` contains:
```
fastapi>=0.115.0
httpx>=0.27.0
pydantic>=2.9.0
uvicorn[standard]>=0.30.0
```

**AC:**
- [ ] `requirements.txt` exists at workspace root
- [ ] `uv pip install` succeeds in the Docker build
- [ ] `python -c "import fastapi, httpx, pydantic, uvicorn"` succeeds inside the container

### 4.2 Phase 0 — Validation Plan

| # | Validation Step | Command | Expected Result |
|---|----------------|---------|-----------------|
| V0-1 | Docker image builds | `docker build -t orchestration-service:test .` | Exit 0, no errors |
| V0-2 | Files exist at expected paths | `docker run --rm orchestration-service:test find /opt/orchestration -type f \| sort` | All files listed |
| V0-3 | Scripts are executable | `docker run --rm orchestration-service:test ls -la /opt/orchestration/scripts/` | All `.sh` files have `-rwxr-xr-x` |
| V0-4 | Python imports succeed | `docker run --rm orchestration-service:test python -c "import fastapi, httpx, pydantic"` | Exit 0 |
| V0-5 | `ORCHESTRATION_ROOT` is set | `docker run --rm orchestration-service:test printenv ORCHESTRATION_ROOT` | `/opt/orchestration` |
| V0-6 | opencode CLI available | `docker run --rm orchestration-service:test opencode --version` | Version string output |
| V0-7 | Existing tests pass | `pwsh -NoProfile -File ./scripts/validate.ps1 -All` | All checks pass |

---

## 5. Phase 1 — Server: Self-Contained Orchestration Service

### 5.0 Objective

Verify the Docker image can start the opencode server, accept prompts, execute orchestration workflows, and exit cleanly — all self-contained, with no external repo checkout.

### 5.1 Tasks

#### P1-T1: Create Server Entrypoint Script

**Agent:** `devops-engineer`

Create `/opt/orchestration/scripts/entrypoint.sh` — the Docker `ENTRYPOINT` that:

1. Exports `GH_ORCHESTRATION_AGENT_TOKEN` under all required aliases
2. Validates required environment variables
3. Changes to the orchestration workspace directory
4. Starts `opencode serve` via `start-opencode-server.sh`
5. Tails the server log to stdout for Docker log collection

```bash
#!/usr/bin/env bash
set -euo pipefail

ORCHESTRATION_ROOT="${ORCHESTRATION_ROOT:-/opt/orchestration}"
cd "$ORCHESTRATION_ROOT"

# Export GitHub auth under all names
if [[ -n "${GH_ORCHESTRATION_AGENT_TOKEN:-}" ]]; then
    export GH_TOKEN="$GH_ORCHESTRATION_AGENT_TOKEN"
    export GITHUB_TOKEN="$GH_ORCHESTRATION_AGENT_TOKEN"
    export GITHUB_PERSONAL_ACCESS_TOKEN="$GH_ORCHESTRATION_AGENT_TOKEN"
fi

# Validate required secrets
for var in ZHIPU_API_KEY GH_ORCHESTRATION_AGENT_TOKEN; do
    if [[ -z "${!var:-}" ]]; then
        echo "FATAL: $var is not set" >&2
        exit 1
    fi
done

echo "[entrypoint] Starting opencode server..."
bash "$ORCHESTRATION_ROOT/scripts/start-opencode-server.sh"

echo "[entrypoint] Server started. Tailing log..."
exec tail -f /tmp/opencode-serve.log
```

Add to Dockerfile:
```dockerfile
COPY scripts/entrypoint.sh /opt/orchestration/scripts/entrypoint.sh
RUN chmod +x /opt/orchestration/scripts/entrypoint.sh
EXPOSE 4096
ENTRYPOINT ["/opt/orchestration/scripts/entrypoint.sh"]
```

**AC:**
- [ ] `docker run` starts the container and `opencode serve` begins listening on port 4096
- [ ] Server log output appears in `docker logs`
- [ ] Container exits cleanly on `docker stop` (SIGTERM propagates to opencode)
- [ ] Missing env vars produce clear error messages and non-zero exit

#### P1-T2: Validate Server Health Endpoint

**Agent:** `qa-test-engineer`

Verify the running server responds to health checks:

```bash
# From host
docker run -d --name orch-server \
  -p 4096:4096 \
  -e ZHIPU_API_KEY="$ZHIPU_API_KEY" \
  -e GH_ORCHESTRATION_AGENT_TOKEN="$GH_ORCHESTRATION_AGENT_TOKEN" \
  orchestration-service:test

# Wait for startup
sleep 15

# Health check
curl -s http://localhost:4096/ && echo "Server healthy"
```

**AC:**
- [ ] `curl http://localhost:4096/` returns a response within 30 seconds of container start
- [ ] Server PID file exists at `/tmp/opencode-serve.pid`
- [ ] Server log shows "opencode serve already running" on second invocation of `start-opencode-server.sh`

#### P1-T3: Test Prompt Execution (Canned Prompt)

**Agent:** `qa-test-engineer`

Execute a canned test prompt against the running server to verify end-to-end orchestration:

```bash
# Attach to running server and dispatch a test prompt
docker exec orch-server bash /opt/orchestration/run_opencode_prompt.sh \
  -a http://127.0.0.1:4096 \
  -d /opt/orchestration \
  -p "Analyze the workspace and list all agent definitions found in .opencode/agents/"
```

**AC:**
- [ ] `opencode run --attach` connects to the running server
- [ ] Orchestrator agent receives and processes the prompt
- [ ] Agent output appears in the exec session's stdout
- [ ] Server log records the session
- [ ] Exit code is 0 for successful execution

#### P1-T4: Test Container Lifecycle (Start/Stop/Restart)

**Agent:** `qa-test-engineer`

Verify the container handles lifecycle operations correctly:

| Scenario | Command | Expected |
|----------|---------|----------|
| Clean start | `docker run -d ...` | Server starts, port 4096 listening |
| Stop | `docker stop orch-server` | Graceful shutdown, exit 0 |
| Restart | `docker start orch-server` | Server resumes, port 4096 listening |
| Kill | `docker kill orch-server` | Immediate stop, pidfile stale |
| Start after kill | `docker start orch-server` | Stale pidfile cleaned, server restarts |
| Multiple prompts | Run 3 prompts sequentially | All succeed, no state leakage |

**AC:**
- [ ] All 6 lifecycle scenarios pass
- [ ] `start-opencode-server.sh` handles stale PID files (already implemented)
- [ ] No zombie processes after stop/restart cycles

#### P1-T5: Create Test Fixtures for Canned Prompts

**Agent:** `qa-test-engineer`

Create test prompt fixtures in `test/fixtures/` for automated validation:

| Fixture | Content | Purpose |
|---------|---------|---------|
| `test-prompt-list-agents.txt` | "List all agent definitions in .opencode/agents/" | Verify agent discovery |
| `test-prompt-health-check.txt` | "Report your status and available tools" | Verify MCP server connectivity |
| `test-prompt-noop.txt` | "Respond with: ORCHESTRATION_OK" | Minimal smoke test |

**AC:**
- [ ] Fixture files created in `test/fixtures/`
- [ ] Each fixture produces expected output when dispatched to the server
- [ ] Fixtures are reusable across all phases

### 5.2 Phase 1 — Validation Plan

| # | Validation Step | Command | Expected Result |
|---|----------------|---------|-----------------|
| V1-1 | Server starts and listens | `docker run -d -p 4096:4096 -e ... orchestration-service:test` + `curl localhost:4096` | HTTP response |
| V1-2 | Canned prompt executes | `docker exec orch-server bash /opt/orchestration/run_opencode_prompt.sh -a http://127.0.0.1:4096 -p "Respond: OK"` | Output contains agent response |
| V1-3 | Container stops gracefully | `docker stop orch-server` | Exit 0, no orphan processes |
| V1-4 | Container restarts cleanly | `docker start orch-server` + `curl localhost:4096` | Server resumes |
| V1-5 | Missing env var fails fast | `docker run --rm orchestration-service:test` (no env vars) | Non-zero exit, error message |
| V1-6 | Server log is accessible | `docker logs orch-server` | opencode serve log lines visible |
| V1-7 | Memory cache persists | Run prompt, stop, start, verify `.memory/` exists | Memory file preserved |
| V1-8 | Full validation suite | `pwsh -NoProfile -File ./scripts/validate.ps1 -All` | All checks pass |

---

## 6. Phase 2 — Client: Remote Prompt Script & Session Management

### 6.0 Objective

Build the client-side prompt dispatch capability. The client holds a local copy of `devcontainer-opencode.sh` and uses it to send prompts to the remote orchestration server. This phase produces the Sentinel Orchestrator as a running service.

### 6.1 Tasks

#### P2-T1: Create Client Project Structure

**Agent:** `developer`

Establish the client Python project:

```
client/
├── src/
│   ├── __init__.py
│   ├── models/
│   │   ├── __init__.py
│   │   └── work_item.py          (copy from plan_docs/src/models/)
│   ├── queue/
│   │   ├── __init__.py
│   │   └── github_queue.py       (copy from plan_docs/src/queue/)
│   ├── sentinel.py               (adapted from plan_docs/orchestrator_sentinel.py)
│   └── config.py                 (centralized configuration)
├── scripts/
│   └── devcontainer-opencode.sh  (local copy for remote dispatch)
├── pyproject.toml
├── requirements.txt
└── Dockerfile                    (optional — for containerized client)
```

**AC:**
- [ ] Client directory structure created
- [ ] All existing Python modules copied and import paths updated (`plan_docs.src` → `src`)
- [ ] `pyproject.toml` defines project metadata and dependencies
- [ ] `uv pip install -e .` succeeds in the client directory

#### P2-T2: Create Centralized Configuration Module

**Agent:** `developer`

Create `client/src/config.py` to centralize all configuration:

```python
"""Centralized configuration for the workflow-orchestration-client."""

import os
import sys

# --- Server Connection ---
OPENCODE_SERVER_URL = os.getenv("OPENCODE_SERVER_URL", "http://127.0.0.1:4096")
OPENCODE_SERVER_DIR = os.getenv("OPENCODE_SERVER_DIR", "/opt/orchestration")

# --- GitHub ---
GITHUB_TOKEN = os.getenv("GITHUB_TOKEN", "")
GITHUB_ORG = os.getenv("GITHUB_ORG", "")
GITHUB_REPO = os.getenv("GITHUB_REPO", "")

# --- Sentinel ---
SENTINEL_BOT_LOGIN = os.getenv("SENTINEL_BOT_LOGIN", "")
POLL_INTERVAL = int(os.getenv("POLL_INTERVAL", "60"))
MAX_BACKOFF = int(os.getenv("MAX_BACKOFF", "960"))
HEARTBEAT_INTERVAL = int(os.getenv("HEARTBEAT_INTERVAL", "300"))
SUBPROCESS_TIMEOUT = int(os.getenv("SUBPROCESS_TIMEOUT", "5700"))

# --- Webhook ---
WEBHOOK_SECRET = os.getenv("WEBHOOK_SECRET", "")
WEBHOOK_PORT = int(os.getenv("WEBHOOK_PORT", "8000"))

# --- Shell Bridge ---
SHELL_BRIDGE_PATH = os.getenv(
    "SHELL_BRIDGE_PATH",
    os.path.join(os.path.dirname(__file__), "..", "scripts", "devcontainer-opencode.sh")
)
```

**AC:**
- [ ] All configuration values sourced from environment variables with sensible defaults
- [ ] No hardcoded secrets
- [ ] Config module importable from all other modules

#### P2-T3: Adapt Sentinel for Remote Server Dispatch

**Agent:** `backend-developer`

Modify the Sentinel's shell bridge invocation in `sentinel.py` to pass the remote server URL:

**Current** (from `orchestrator_sentinel.py`):
```python
res_prompt = await run_shell_command(
    [SHELL_BRIDGE_PATH, "prompt", instruction],
    timeout=SUBPROCESS_TIMEOUT,
)
```

**Target** (remote dispatch):
```python
res_prompt = await run_shell_command(
    [
        SHELL_BRIDGE_PATH, "prompt",
        "-p", instruction,
        "-u", OPENCODE_SERVER_URL,
        "-d", OPENCODE_SERVER_DIR,
    ],
    timeout=SUBPROCESS_TIMEOUT,
)
```

This is the **critical integration point** — the Sentinel uses the same `devcontainer-opencode.sh` shell bridge, but now passes `-u` (server URL) to dispatch remotely instead of locally.

**Additional Changes:**
- Remove the `up` and `start` stages from `process_task()` — the server is already running independently
- Add a server health check before dispatching (HTTP GET to `OPENCODE_SERVER_URL`)
- Update the heartbeat message to include the remote server URL

**AC:**
- [ ] Sentinel connects to the remote orchestration server via shell bridge
- [ ] `devcontainer-opencode.sh prompt -p <instruction> -u <server-url>` invokes `opencode run --attach <server-url>`
- [ ] Prompt execution output is captured in the subprocess stdout/stderr
- [ ] Shell bridge exit code propagates correctly (0 = success, non-zero = error)
- [ ] Heartbeat comments include server URL and connection status

#### P2-T4: Add Server Health Check to Sentinel

**Agent:** `backend-developer`

Before dispatching a prompt, the Sentinel should verify the server is reachable:

```python
async def _check_server_health(self) -> bool:
    """Verify the orchestration server is reachable before dispatching."""
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(f"{OPENCODE_SERVER_URL}/")
            return resp.status_code == 200
    except Exception as exc:
        logger.warning(f"Server health check failed: {exc}")
        return False
```

If the health check fails, the Sentinel should:
1. Log a warning
2. Skip the current polling cycle
3. Apply backoff before retrying

**AC:**
- [ ] Health check runs before every prompt dispatch
- [ ] Failed health checks do not crash the Sentinel
- [ ] Backoff applies when the server is unreachable
- [ ] Server recovery is automatically detected on next poll

#### P2-T5: Test Remote Prompt Dispatch End-to-End

**Agent:** `qa-test-engineer`

Test the full client → server prompt dispatch flow:

1. Start the orchestration server container (Phase 1 image)
2. Run the Sentinel with a test issue pre-labeled `agent:queued`
3. Observe the Sentinel claim the issue, dispatch to the server, and update status

**Test Script:**
```bash
# 1. Start server
docker run -d --name orch-server -p 4096:4096 \
  -e ZHIPU_API_KEY="$ZHIPU_API_KEY" \
  -e GH_ORCHESTRATION_AGENT_TOKEN="$GH_ORCHESTRATION_AGENT_TOKEN" \
  orchestration-service:test

# 2. Create a test issue with agent:queued label
gh issue create --title "[Test] Sentinel dispatch test" \
  --body "Test issue for Sentinel dispatch validation" \
  --label "agent:queued"

# 3. Run sentinel (will poll, find issue, dispatch to server)
OPENCODE_SERVER_URL=http://localhost:4096 \
GITHUB_TOKEN="$GH_ORCHESTRATION_AGENT_TOKEN" \
GITHUB_ORG="intel-agency" \
GITHUB_REPO="workflow-orchestration-service" \
python client/src/sentinel.py
```

**AC:**
- [ ] Sentinel discovers the test issue
- [ ] Sentinel claims the issue (label changes to `agent:in-progress`)
- [ ] Sentinel dispatches prompt to remote server
- [ ] Server executes the orchestration workflow
- [ ] Sentinel updates the issue label to `agent:success` (or `agent:error` with diagnostics)
- [ ] Heartbeat comments appear during execution
- [ ] No credential leakage in GitHub comments (verified by `scrub_secrets` audit)

### 6.2 Phase 2 — Validation Plan

| # | Validation Step | Command | Expected Result |
|---|----------------|---------|-----------------|
| V2-1 | Client installs | `cd client && uv pip install -e .` | Exit 0 |
| V2-2 | Config loads from env | `python -c "from src.config import *; print(OPENCODE_SERVER_URL)"` | Prints URL |
| V2-3 | Shell bridge dispatches remotely | `bash client/scripts/devcontainer-opencode.sh prompt -p "test" -u http://localhost:4096` | opencode attaches to server |
| V2-4 | Sentinel polls and finds issue | Start sentinel, create queued issue | Issue discovered in logs |
| V2-5 | Sentinel claims issue | Observe GitHub API calls | Label changes, assignee set |
| V2-6 | Sentinel dispatches to server | Check server logs | Prompt received and processed |
| V2-7 | Sentinel updates final status | Check issue labels and comments | `agent:success` or `agent:error` |
| V2-8 | Heartbeat comments posted | Long-running prompt (>5 min) | Heartbeat comment visible |
| V2-9 | Credential scrubbing | Include fake secret in output | `***REDACTED***` in comment |
| V2-10 | Graceful shutdown | Send SIGTERM to sentinel | Current task finishes, clean exit |
| V2-11 | Full validation suite | `pwsh -NoProfile -File ./scripts/validate.ps1 -All` | All checks pass |

---

## 7. Phase 3 — Client: Webhook Handler & Event Routing

### 7.0 Objective

Integrate the FastAPI webhook handler into the client. The webhook receives GitHub events, triages them into WorkItems, and either enqueues them (for Sentinel pickup) or dispatches prompts directly to the server.

### 7.1 Tasks

#### P3-T1: Adapt Notifier Service for Client Integration

**Agent:** `backend-developer`

Move `notifier_service.py` into the client project and update for the full event set:

```python
# client/src/notifier.py
```

**Changes from existing `notifier_service.py`:**

| Change | Detail |
|--------|--------|
| Import paths | `plan_docs.src.models` → `src.models` |
| Event coverage | Add `issues.labeled`, `pull_request.*`, `workflow_dispatch` |
| Queue integration | Use shared `GitHubQueue` instance (not per-request) |
| Config | Import from `src.config` instead of reading `os.environ` directly |

**AC:**
- [ ] All events from current `orchestrator-agent.yml` triggers are handled
- [ ] HMAC verification rejects invalid signatures (test with wrong secret)
- [ ] Valid events create WorkItems and add `agent:queued` label
- [ ] Invalid/unmapped events return `{"status": "ignored"}`
- [ ] Health endpoint returns `{"status": "online"}`

#### P3-T2: Add Event Type Handlers

**Agent:** `backend-developer`

Implement handlers for each GitHub event type that maps to the current orchestrator-agent workflow triggers:

```python
# Event routing table
EVENT_HANDLERS = {
    ("issues", "labeled"): handle_issue_labeled,
    ("issues", "opened"): handle_issue_opened,
    ("pull_request", "opened"): handle_pr_opened,
    ("pull_request", "review_submitted"): handle_pr_review,
    ("workflow_dispatch", None): handle_workflow_dispatch,
}
```

Each handler:
1. Extracts relevant fields from the payload
2. Determines the `TaskType` (PLAN, IMPLEMENT, BUGFIX)
3. Constructs a `WorkItem`
4. Adds `agent:queued` label via the queue

**AC:**
- [ ] `issues.labeled` handler matches current workflow trigger behavior
- [ ] `workflow_dispatch` handler accepts custom input parameters
- [ ] Each handler produces a correctly typed `WorkItem`
- [ ] Unmapped event/action combinations are gracefully ignored
- [ ] Test fixtures exist for each event type in `test/fixtures/`

#### P3-T3: Integrate Prompt Assembly Pipeline

**Agent:** `backend-developer`

The webhook handler needs to assemble the structured orchestrator prompt — the same pipeline currently in `assemble-orchestrator-prompt.sh`:

1. Read template from `prompts/orchestrator-agent-prompt.md`
2. Prepend structured event context (event name, action, actor, repo, ref, SHA)
3. Append raw event JSON
4. Write to assembled prompt file
5. Dispatch via shell bridge

**Implementation approach** — call `assemble-orchestrator-prompt.sh` from Python:

```python
async def assemble_and_dispatch(event_name: str, event_json: str):
    """Assemble the orchestrator prompt and dispatch to the server."""
    # Write event JSON to temp file
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
        f.write(event_json)
        event_file = f.name

    try:
        # Assemble prompt using existing shell script
        result = await run_shell_command([
            "bash", ASSEMBLE_SCRIPT,
            "--event-name", event_name,
            "--event-json-file", event_file,
        ])

        if result.returncode != 0:
            raise RuntimeError(f"Prompt assembly failed: {result.stderr}")

        # Dispatch assembled prompt to server
        prompt_path = ".assembled-orchestrator-prompt.md"
        result = await run_shell_command([
            SHELL_BRIDGE_PATH, "prompt",
            "-f", prompt_path,
            "-u", OPENCODE_SERVER_URL,
            "-d", OPENCODE_SERVER_DIR,
        ], timeout=SUBPROCESS_TIMEOUT)

        return result
    finally:
        os.unlink(event_file)
```

**AC:**
- [ ] Prompt assembly produces the same output as the GitHub Actions workflow
- [ ] `__EVENT_DATA__` placeholder is correctly substituted
- [ ] Assembled prompt includes event context header + raw JSON
- [ ] Dispatch succeeds with the assembled prompt file

#### P3-T4: Implement Dual-Mode Operation

**Agent:** `backend-developer`

The client should support two operation modes simultaneously:

1. **Webhook Mode** — FastAPI server receives events and dispatches immediately
2. **Polling Mode** — Sentinel polls for `agent:queued` issues (handles missed webhooks)

Both modes run concurrently in the same process:

```python
# client/src/main.py

import asyncio
import uvicorn
from src.notifier import app
from src.sentinel import Sentinel
from src.queue.github_queue import GitHubQueue
from src.config import *

async def main():
    """Run webhook server and sentinel polling loop concurrently."""
    queue = GitHubQueue(GITHUB_TOKEN, GITHUB_ORG, GITHUB_REPO)
    sentinel = Sentinel(queue)

    # Run both concurrently
    server = uvicorn.Server(uvicorn.Config(app, host="0.0.0.0", port=WEBHOOK_PORT))

    try:
        await asyncio.gather(
            server.serve(),
            sentinel.run_forever(),
        )
    finally:
        await queue.close()
```

**AC:**
- [ ] Both webhook server and sentinel run in the same process
- [ ] Webhook events trigger immediate queue additions
- [ ] Sentinel picks up queued items even if webhook delivery fails
- [ ] Graceful shutdown stops both components
- [ ] No race conditions between webhook handler and sentinel on the same issue

#### P3-T5: Create Client Dockerfile

**Agent:** `devops-engineer`

Create an optional Dockerfile for containerized client deployment:

```dockerfile
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl bash docker.io && rm -rf /var/lib/apt/lists/*

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app
COPY requirements.txt .
RUN uv pip install --system -r requirements.txt

COPY . .

EXPOSE 8000
CMD ["python", "-m", "src.main"]
```

**AC:**
- [ ] Client container builds successfully
- [ ] Webhook endpoint accessible on port 8000
- [ ] Client can reach the server container (Docker networking)
- [ ] `docker-compose.yml` orchestrates both server and client containers

#### P3-T6: Create Docker Compose for Local Development

**Agent:** `devops-engineer`

```yaml
# docker-compose.yml
services:
  orchestration-server:
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - "4096:4096"
    environment:
      - ZHIPU_API_KEY
      - KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY
      - GH_ORCHESTRATION_AGENT_TOKEN
    volumes:
      - server-memory:/opt/orchestration/.memory

  orchestration-client:
    build:
      context: ./client
    ports:
      - "8000:8000"
    environment:
      - OPENCODE_SERVER_URL=http://orchestration-server:4096
      - GITHUB_TOKEN
      - GITHUB_ORG
      - GITHUB_REPO
      - WEBHOOK_SECRET
      - SENTINEL_BOT_LOGIN
    depends_on:
      - orchestration-server

volumes:
  server-memory:
```

**AC:**
- [ ] `docker compose up` starts both services
- [ ] Client can reach server via `orchestration-server:4096`
- [ ] Webhook requests to `localhost:8000` are processed
- [ ] `docker compose down` stops both cleanly
- [ ] `.memory/` volume persists across restarts

### 7.2 Phase 3 — Validation Plan

| # | Validation Step | Command | Expected Result |
|---|----------------|---------|-----------------|
| V3-1 | Webhook rejects bad signature | `curl -X POST localhost:8000/webhooks/github -H "X-Hub-Signature-256: sha256=invalid" -d '{}'` | HTTP 401 |
| V3-2 | Webhook accepts valid event | Send signed `issues.labeled` payload | HTTP 200, `{"status": "accepted"}` |
| V3-3 | Issue gets `agent:queued` label | Check issue labels after webhook | Label present |
| V3-4 | Sentinel picks up webhook-queued issue | Watch sentinel logs | Issue discovered and claimed |
| V3-5 | Prompt assembly produces valid prompt | Diff assembled prompt vs. Actions workflow output | Structurally identical |
| V3-6 | `workflow_dispatch` event handled | Send dispatch payload | WorkItem created with correct type |
| V3-7 | Unknown events ignored | Send `star.created` event | HTTP 200, `{"status": "ignored"}` |
| V3-8 | Docker compose runs both services | `docker compose up` | Both healthy, can communicate |
| V3-9 | End-to-end: webhook → server → result | Send issue event, observe issue lifecycle | Labels: queued → in-progress → success |
| V3-10 | Health endpoints | `curl localhost:8000/health` | `{"status": "online"}` |
| V3-11 | Full validation suite | `pwsh -NoProfile -File ./scripts/validate.ps1 -All` | All checks pass |

---

## 8. Phase 4 — GitHub App Event Source Integration

### 8.0 Objective

Create and configure a GitHub App that delivers repository events to the client's webhook endpoint. This replaces the GitHub Actions `on: issues` trigger.

### 8.1 Tasks

#### P4-T1: Create GitHub App Specification

**Agent:** `github-expert`

Define the GitHub App configuration:

| Setting | Value |
|---------|-------|
| App Name | `workflow-orchestration-service Orchestration Bot` |
| Webhook URL | `https://<client-host>/webhooks/github` |
| Webhook Secret | (generated, stored as `WEBHOOK_SECRET`) |
| Homepage URL | Repo URL |
| Permissions (Repository) | Issues: Read & Write, Pull Requests: Read & Write, Contents: Read & Write, Metadata: Read |
| Permissions (Organization) | Members: Read |
| Subscribe to Events | Issues, Pull Request, Workflow Dispatch |

**AC:**
- [ ] GitHub App created in the organization
- [ ] Webhook secret generated and stored securely
- [ ] App installed on the target repository
- [ ] Webhook deliveries visible in App settings

#### P4-T2: Configure Webhook Delivery Endpoint

**Agent:** `devops-engineer`

Set up the public-facing webhook endpoint:

**Option A — Direct (development):**
- Use `ngrok` or `cloudflared` tunnel for development
- `ngrok http 8000` → public URL → configure in GitHub App

**Option B — Production:**
- Reverse proxy (nginx/Caddy) with TLS termination
- DNS record pointing to the server host
- Let's Encrypt certificate (auto-renewal)

**AC:**
- [ ] GitHub App webhook URL is publicly reachable
- [ ] TLS is configured (HTTPS)
- [ ] Webhook deliveries show `200` response in GitHub App settings
- [ ] Invalid signatures are rejected (visible in client logs)

#### P4-T3: Test Event Delivery Pipeline

**Agent:** `qa-test-engineer`

Verify events flow from GitHub through the App to the client:

1. Install the App on a test repository
2. Create an issue with the `agent:queued` label
3. Observe: webhook delivery → client processing → Sentinel pickup → server dispatch

**AC:**
- [ ] Issue creation triggers webhook delivery
- [ ] Label addition triggers webhook delivery
- [ ] Client processes the event and creates a WorkItem
- [ ] Sentinel discovers and claims the work item
- [ ] Orchestration server executes the workflow
- [ ] Issue status labels update through the full lifecycle

#### P4-T4: Implement Webhook Retry Handling

**Agent:** `backend-developer`

GitHub retries failed webhook deliveries. The client must handle:

1. **Idempotency** — Same event delivered twice doesn't create duplicate work
2. **Ordering** — Out-of-order events don't corrupt state
3. **Timeout** — Respond within 10 seconds (GitHub's timeout)

```python
# Idempotency via delivery ID tracking
_processed_deliveries: set = set()  # In production, use Redis/disk

@app.post("/webhooks/github", dependencies=[Depends(verify_signature)])
async def handle_github_webhook(request: Request, ...):
    delivery_id = request.headers.get("X-GitHub-Delivery", "")
    if delivery_id in _processed_deliveries:
        return {"status": "duplicate", "delivery_id": delivery_id}
    _processed_deliveries.add(delivery_id)
    # ... process event ...
```

**AC:**
- [ ] Duplicate webhook deliveries are detected and ignored
- [ ] Idempotency tracking survives within the process lifetime
- [ ] Response time is under 10 seconds for all events
- [ ] Async dispatch (queue addition only, not full orchestration) keeps response fast

### 8.2 Phase 4 — Validation Plan

| # | Validation Step | Command | Expected Result |
|---|----------------|---------|-----------------|
| V4-1 | GitHub App webhook delivery | Create issue on installed repo | Delivery shows in App settings |
| V4-2 | Client receives real webhook | Check client logs | Event logged with correct type |
| V4-3 | HMAC verification with real secret | Check delivery response | HTTP 200 for valid, 401 for tampered |
| V4-4 | Idempotency on retry | Redeliver same webhook from App settings | `{"status": "duplicate"}` |
| V4-5 | End-to-end with real GitHub events | Create issue with label → full lifecycle | Labels cycle through all states |
| V4-6 | Webhook timeout compliance | Measure response time | < 10 seconds |
| V4-7 | Full validation suite | `pwsh -NoProfile -File ./scripts/validate.ps1 -All` | All checks pass |

---

## 9. Phase 5 — Production Hardening & Observability

### 9.0 Objective

Harden both server and client for production use. Add structured logging, metrics, alerting, resource limits, and operational runbooks.

### 9.1 Tasks

#### P5-T1: Structured Logging (JSON-L)

**Agent:** `backend-developer`

Replace basic `logging.StreamHandler` with structured JSON-L output:

```python
import json
import logging

class JSONFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({
            "timestamp": self.formatTime(record),
            "level": record.levelname,
            "sentinel_id": SENTINEL_ID,
            "message": record.getMessage(),
            "module": record.module,
            "function": record.funcName,
        })
```

**AC:**
- [ ] All log output is valid JSON-L
- [ ] Each log line includes timestamp, level, sentinel ID, and message
- [ ] Sentinel logs are parseable by standard log aggregation tools
- [ ] Server opencode logs are captured alongside sentinel structured logs

#### P5-T2: Resource Limits & Docker Security

**Agent:** `devops-engineer`

Add resource constraints to docker-compose:

```yaml
services:
  orchestration-server:
    deploy:
      resources:
        limits:
          cpus: '4.0'
          memory: 8G
        reservations:
          cpus: '2.0'
          memory: 4G
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp
    networks:
      - orchestration-net

  orchestration-client:
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G
    security_opt:
      - no-new-privileges:true
    networks:
      - orchestration-net

networks:
  orchestration-net:
    driver: bridge
```

**AC:**
- [ ] Server container cannot exceed 8GB memory
- [ ] Client container cannot exceed 1GB memory
- [ ] No privilege escalation possible
- [ ] Containers communicate only on the internal network
- [ ] Server filesystem is read-only (except `/tmp` and volumes)

#### P5-T3: Cost Guardrails (Budget Monitor)

**Agent:** `backend-developer`

Implement the budget monitoring from the development plan (Story 6):

```python
class BudgetMonitor:
    """Tracks LLM usage costs and enforces daily limits."""

    def __init__(self, daily_limit_usd: float = 50.0):
        self.daily_limit = daily_limit_usd
        self._credits_file = "/tmp/credits_used.json"

    async def check_budget(self) -> bool:
        """Returns True if within budget, False if limit exceeded."""
        # Read credits used from file
        # Compare against daily limit
        # Return budget status
        ...

    async def record_usage(self, cost_usd: float):
        """Record LLM API cost after a prompt execution."""
        ...
```

If budget is exceeded:
1. Label the current issue `agent:stalled-budget`
2. Post a comment explaining the budget limit
3. Pause the Sentinel polling loop
4. Log a warning

**AC:**
- [ ] Budget tracking persists across prompt executions
- [ ] Daily limit is configurable via env var
- [ ] Budget exceeded → Sentinel pauses, issue labeled
- [ ] Budget resets daily (UTC midnight)

#### P5-T4: Operational Runbook

**Agent:** `documentation-expert`

Create `docs/runbook.md` covering:

| Section | Content |
|---------|---------|
| Prerequisites | Required secrets, Docker, network requirements |
| Deployment | Step-by-step: build images, configure compose, start services |
| Configuration | All environment variables with descriptions and defaults |
| Health Checks | How to verify server and client are healthy |
| Troubleshooting | Common failure modes and resolutions |
| Log Analysis | How to read and search structured logs |
| Scaling | How to add more Sentinel instances |
| Backup & Recovery | Memory volume backup, state recovery |

**AC:**
- [ ] Runbook covers all operational scenarios
- [ ] Copy-pasteable commands for every operation
- [ ] Troubleshooting covers the top 10 expected failure modes
- [ ] Reviewed for accuracy against the implementation

#### P5-T5: Monitoring & Alerting

**Agent:** `devops-engineer`

Add basic monitoring endpoints and alerting:

| Endpoint | Method | Response |
|----------|--------|----------|
| `/health` | GET | `{"status": "online", "server_reachable": true, "last_poll": "...", "tasks_processed": N}` |
| `/metrics` | GET | Prometheus-compatible metrics (optional) |

Key metrics to track:
- Tasks processed (counter, by status)
- Prompt dispatch duration (histogram)
- Server health check failures (counter)
- Rate limit backoffs (counter)
- Active tasks (gauge)

**AC:**
- [ ] `/health` endpoint reflects actual system state
- [ ] Server unreachable is detectable via health check
- [ ] Metrics are exportable (Prometheus format or JSON)

### 9.2 Phase 5 — Validation Plan

| # | Validation Step | Command | Expected Result |
|---|----------------|---------|-----------------|
| V5-1 | Structured logs are valid JSON-L | `python -m json.tool < sentinel.log` | Each line parses |
| V5-2 | Resource limits enforced | Run memory-intensive prompt | Container killed at limit |
| V5-3 | Budget monitor pauses sentinel | Set limit to $0.01, run prompt | Sentinel pauses, issue labeled |
| V5-4 | Health check reflects state | Stop server, check `/health` | `server_reachable: false` |
| V5-5 | Read-only filesystem | Attempt write outside `/tmp` | Permission denied |
| V5-6 | Network isolation | Port scan from server → host | No unexpected ports reachable |
| V5-7 | Runbook accuracy | Follow deployment steps from scratch | System starts successfully |
| V5-8 | Full validation suite | `pwsh -NoProfile -File ./scripts/validate.ps1 -All` | All checks pass |

---

## 10. Cross-Cutting Concerns

### 10.1 Security

| Concern | Mitigation | Phase |
|---------|-----------|-------|
| Webhook spoofing | HMAC SHA-256 signature verification | P3 |
| Credential leakage | `scrub_secrets()` on all GitHub-posted content | All |
| Prompt injection via webhook | Only process verified GitHub payloads, never execute raw user input | P3, P4 |
| Container escape | No-new-privileges, resource limits, read-only filesystem | P5 |
| Network exposure | Internal Docker network, no host network access | P5 |
| Token scope | Minimum required scopes for each token | All |

### 10.2 Error Handling & Recovery

| Failure Mode | Detection | Recovery |
|-------------|-----------|----------|
| Server down | Health check failure | Sentinel backs off, retries |
| Webhook missed | Polling loop | Sentinel discovers `agent:queued` issues |
| Rate limited | HTTP 403/429 | Jittered exponential backoff (max 16 min) |
| Subprocess timeout | 95-min hard ceiling | Kill process, label `agent:error` |
| Sentinel crash | Process manager (systemd/Docker restart) | Restart, reconcile `agent:in-progress` |
| Memory corruption | Server restart | Volume-backed `.memory/` survives restart |
| Budget exceeded | Credits file check | Pause sentinel, label `agent:stalled-budget` |

### 10.3 Testing Strategy

| Level | Scope | Tool | Phase |
|-------|-------|------|-------|
| Unit | WorkItem model, scrub_secrets, config | pytest | P0 |
| Unit | GitHubQueue methods (mocked httpx) | pytest + respx | P2 |
| Integration | Shell bridge → opencode server | bash test scripts | P1 |
| Integration | Webhook → queue → sentinel → server | docker-compose + test fixtures | P3 |
| End-to-end | GitHub App → webhook → server → issue update | Real GitHub events | P4 |
| Load | Multiple concurrent issues | Locust or custom script | P5 |

### 10.4 Configuration Reference

| Variable | Required | Default | Phase | Description |
|----------|----------|---------|-------|-------------|
| `ZHIPU_API_KEY` | Yes | — | P0 | ZhipuAI GLM model access |
| `KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY` | Yes* | — | P0 | Kimi model access (*or other configured model) |
| `GH_ORCHESTRATION_AGENT_TOKEN` | Yes | — | P0 | Org PAT: repo, workflow, project, read:org |
| `OPENCODE_SERVER_URL` | No | `http://127.0.0.1:4096` | P2 | Orchestration server address |
| `OPENCODE_SERVER_DIR` | No | `/opt/orchestration` | P2 | Server-side working directory |
| `GITHUB_TOKEN` | Yes | — | P2 | GitHub API access for queue operations |
| `GITHUB_ORG` | Yes | — | P2 | GitHub organization name |
| `GITHUB_REPO` | Yes | — | P2 | Target repository name |
| `SENTINEL_BOT_LOGIN` | Recommended | — | P2 | Bot account login for assign-then-verify locking |
| `POLL_INTERVAL` | No | `60` | P2 | Seconds between polling cycles |
| `MAX_BACKOFF` | No | `960` | P2 | Maximum backoff on rate limits (seconds) |
| `HEARTBEAT_INTERVAL` | No | `300` | P2 | Seconds between heartbeat comments |
| `SUBPROCESS_TIMEOUT` | No | `5700` | P2 | Hard timeout for prompt execution (seconds) |
| `WEBHOOK_SECRET` | Yes | — | P3 | HMAC verification key |
| `WEBHOOK_PORT` | No | `8000` | P3 | Webhook server listen port |
| `SHELL_BRIDGE_PATH` | No | `./scripts/devcontainer-opencode.sh` | P2 | Path to shell bridge script |
| `ORCHESTRATION_ROOT` | No | `/opt/orchestration` | P0 | Root directory inside server container |
| `OPENCODE_SERVER_PORT` | No | `4096` | P1 | Server listen port |

---

## 11. Agent Assignment Matrix

This section maps each task to the specialist agent responsible for autonomous implementation.

### Phase 0 — Foundation

| Task | Agent | Dependencies | Estimated Complexity |
|------|-------|-------------|---------------------|
| P0-T1: Define server directory structure | `devops-engineer` | None | Low |
| P0-T2: Add COPY directives to Dockerfile | `devops-engineer` | P0-T1 | Low |
| P0-T3: Update path references in scripts | `developer` | P0-T2 | Medium |
| P0-T4: Install Python dependencies | `devops-engineer` | P0-T2 | Low |

### Phase 1 — Server

| Task | Agent | Dependencies | Estimated Complexity |
|------|-------|-------------|---------------------|
| P1-T1: Create server entrypoint script | `devops-engineer` | P0 complete | Medium |
| P1-T2: Validate server health endpoint | `qa-test-engineer` | P1-T1 | Low |
| P1-T3: Test prompt execution | `qa-test-engineer` | P1-T2 | Medium |
| P1-T4: Test container lifecycle | `qa-test-engineer` | P1-T1 | Medium |
| P1-T5: Create test fixtures | `qa-test-engineer` | None | Low |

### Phase 2 — Client Prompt Dispatch

| Task | Agent | Dependencies | Estimated Complexity |
|------|-------|-------------|---------------------|
| P2-T1: Create client project structure | `developer` | P1 complete | Medium |
| P2-T2: Create config module | `developer` | P2-T1 | Low |
| P2-T3: Adapt Sentinel for remote dispatch | `backend-developer` | P2-T1, P2-T2 | High |
| P2-T4: Add server health check | `backend-developer` | P2-T3 | Low |
| P2-T5: Test remote dispatch E2E | `qa-test-engineer` | P2-T3, P2-T4, P1 complete | High |

### Phase 3 — Webhook Handler

| Task | Agent | Dependencies | Estimated Complexity |
|------|-------|-------------|---------------------|
| P3-T1: Adapt notifier service | `backend-developer` | P2 complete | Medium |
| P3-T2: Add event type handlers | `backend-developer` | P3-T1 | Medium |
| P3-T3: Integrate prompt assembly | `backend-developer` | P3-T2 | High |
| P3-T4: Implement dual-mode operation | `backend-developer` | P3-T1, P2-T3 | High |
| P3-T5: Create client Dockerfile | `devops-engineer` | P3-T4 | Low |
| P3-T6: Create docker-compose | `devops-engineer` | P3-T5, P1-T1 | Medium |

### Phase 4 — GitHub App

| Task | Agent | Dependencies | Estimated Complexity |
|------|-------|-------------|---------------------|
| P4-T1: Create GitHub App spec | `github-expert` | P3 complete | Medium |
| P4-T2: Configure webhook endpoint | `devops-engineer` | P4-T1 | Medium |
| P4-T3: Test event delivery | `qa-test-engineer` | P4-T1, P4-T2 | Medium |
| P4-T4: Webhook retry handling | `backend-developer` | P3-T1 | Medium |

### Phase 5 — Production Hardening

| Task | Agent | Dependencies | Estimated Complexity |
|------|-------|-------------|---------------------|
| P5-T1: Structured logging | `backend-developer` | P2-T3 | Medium |
| P5-T2: Resource limits & security | `devops-engineer` | P3-T6 | Medium |
| P5-T3: Cost guardrails | `backend-developer` | P2-T3 | Medium |
| P5-T4: Operational runbook | `documentation-expert` | P5-T1, P5-T2 | Medium |
| P5-T5: Monitoring & alerting | `devops-engineer` | P5-T1 | Medium |

### Delegation Graph (Orchestrator → Specialists)

```
orchestrator
├── Phase 0: devops-engineer → developer → devops-engineer
│   └── Validation: qa-test-engineer
│
├── Phase 1: devops-engineer → qa-test-engineer (×4)
│   └── Validation: qa-test-engineer
│
├── Phase 2: developer (×2) → backend-developer (×2) → qa-test-engineer
│   └── Validation: qa-test-engineer
│
├── Phase 3: backend-developer (×4) → devops-engineer (×2)
│   └── Validation: qa-test-engineer
│
├── Phase 4: github-expert → devops-engineer → qa-test-engineer → backend-developer
│   └── Validation: qa-test-engineer
│
└── Phase 5: backend-developer (×2) → devops-engineer (×2) → documentation-expert
    └── Validation: qa-test-engineer
```

**Delegation depth:** Maximum 2 (orchestrator → specialist → sub-specialist), compliant with orchestrator constraints.

---

## 12. Risk Register

| ID | Risk | Probability | Impact | Mitigation | Phase |
|----|------|-------------|--------|------------|-------|
| R1 | `devcontainer-opencode.sh` remote dispatch fails silently | Medium | High | Add explicit connection test before prompt dispatch; log all shell bridge stderr | P2 |
| R2 | `setsid` behavior differs in Docker vs. devcontainer exec | Low | High | Test server bootstrap in both contexts during P1; fallback to `nohup` if needed | P1 |
| R3 | Rate limiting causes missed work items | Medium | Medium | Polling-first design ensures recovery; jittered backoff prevents API abuse | P2 |
| R4 | Webhook delivery fails during client downtime | Medium | Low | Sentinel polling picks up missed items; GitHub retries for 3 days | P3 |
| R5 | Concurrent Sentinels claim same issue | Low | Medium | Assign-then-verify pattern in `GitHubQueue.claim_task()` prevents double-claim | P2 |
| R6 | Credentials leak in agent output | Medium | Critical | `scrub_secrets()` applied to all GitHub-posted content; patterns cover all known key formats | All |
| R7 | Budget runaway during autonomous execution | Medium | High | Budget monitor with daily limit; `agent:stalled-budget` label halts processing | P5 |
| R8 | Server memory corruption across sessions | Low | Medium | Volume-backed `.memory/` with periodic snapshots; container restart clears transient state | P1 |
| R9 | `opencode run --attach` connection timeout on slow networks | Medium | Medium | Configurable timeout; health check before dispatch; retry with backoff | P2 |
| R10 | Prompt injection via crafted issue body | Low | High | Only process events from verified GitHub App; never execute raw user input as shell commands | P3, P4 |
| R11 | Docker image size bloat | Low | Low | Multi-stage build; text files add negligible size | P0 |
| R12 | Version skew between server image and client code | Medium | Medium | Tag both with matching version; add version handshake to health check | P5 |

---

## 13. Appendix: File Migration Map

### Files Moving INTO the Docker Image (Server)

| Source (this repo) | Destination (Docker image) | COPY Layer |
|-------------------|---------------------------|------------|
| `.opencode/agents/*.md` | `/opt/orchestration/.opencode/agents/` | Image |
| `.opencode/commands/*.md` | `/opt/orchestration/.opencode/commands/` | Image |
| `.opencode/package.json` | `/opt/orchestration/.opencode/package.json` | Image |
| `opencode.json` | `/opt/orchestration/opencode.json` | Image |
| `AGENTS.md` (generic sections) | `/opt/orchestration/AGENTS.md` | Image |
| `.github/workflows/prompts/orchestrator-agent-prompt.md` | `/opt/orchestration/prompts/orchestrator-agent-prompt.md` | Image |
| `scripts/devcontainer-opencode.sh` | `/opt/orchestration/scripts/devcontainer-opencode.sh` | Image |
| `scripts/start-opencode-server.sh` | `/opt/orchestration/scripts/start-opencode-server.sh` | Image |
| `scripts/assemble-orchestrator-prompt.sh` | `/opt/orchestration/scripts/assemble-orchestrator-prompt.sh` | Image |
| `scripts/resolve-image-tags.sh` | `/opt/orchestration/scripts/resolve-image-tags.sh` | Image |
| `run_opencode_prompt.sh` | `/opt/orchestration/run_opencode_prompt.sh` | Image |

### Files Moving INTO the Client Project

| Source (this repo) | Destination (client/) | Notes |
|-------------------|----------------------|-------|
| `plan_docs/orchestrator_sentinel.py` | `client/src/sentinel.py` | Adapted for remote dispatch |
| `plan_docs/notifier_service.py` | `client/src/notifier.py` | Expanded event coverage |
| `plan_docs/src/models/work_item.py` | `client/src/models/work_item.py` | No changes needed |
| `plan_docs/src/queue/github_queue.py` | `client/src/queue/github_queue.py` | No changes needed |
| `plan_docs/src/models/__init__.py` | `client/src/models/__init__.py` | No changes needed |
| `plan_docs/src/queue/__init__.py` | `client/src/queue/__init__.py` | No changes needed |
| `scripts/devcontainer-opencode.sh` | `client/scripts/devcontainer-opencode.sh` | Local copy for remote dispatch |
| `scripts/WorkItemModel.py` | — | Superseded by `src/models/work_item.py` |

### Files Staying in Template Repo

| File | Reason |
|------|--------|
| `.devcontainer/devcontainer.json` | Consumer config for template clones |
| `.github/workflows/orchestrator-agent.yml` | GitHub Actions trigger (template clones use this) |
| `.github/workflows/validate.yml` | Project CI |
| `.github/.labels.json` | Project labels |
| `AGENTS.local.md` (new, from split) | Project-specific agent instructions |
| `local_ai_instruction_modules/` | Project instruction overrides |
| `plan_docs/` | Project plan documents |
| `scripts/validate.ps1` | Project validation |
| `test/` (non-devcontainer tests) | Project test suite |

---

## Summary: Implementation Order for Autonomous Execution

```
Phase 0 (Foundation)     ──► Phase 1 (Server)        ──► Phase 2 (Client Dispatch)
  P0-T1 → P0-T2 →             P1-T1 → P1-T2 →             P2-T1 → P2-T2 →
  P0-T3 → P0-T4               P1-T3 → P1-T4 →             P2-T3 → P2-T4 →
  │                            P1-T5                        P2-T5
  │                            │                            │
  └── VALIDATE ────────────────└── VALIDATE ────────────────└── VALIDATE
                                                                    │
Phase 3 (Webhook)        ──► Phase 4 (GitHub App)    ──► Phase 5 (Production)
  P3-T1 → P3-T2 →             P4-T1 → P4-T2 →             P5-T1 → P5-T2 →
  P3-T3 → P3-T4 →             P4-T3 → P4-T4               P5-T3 → P5-T4 →
  P3-T5 → P3-T6                                            P5-T5
  │                            │                            │
  └── VALIDATE ────────────────└── VALIDATE ────────────────└── VALIDATE
```

**Each phase gate requires:**
1. All AC items checked off
2. All validation steps pass
3. `pwsh -NoProfile -File ./scripts/validate.ps1 -All` passes clean
4. No regressions in existing functionality

**The orchestrator MUST NOT proceed to the next phase until the current phase gate passes.**
