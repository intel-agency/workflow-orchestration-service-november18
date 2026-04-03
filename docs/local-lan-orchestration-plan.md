# Local & LAN-Local Opencode Server Devcontainer Orchestration

## Executive Summary

Enable running the full opencode server + devcontainer orchestration stack **locally** (developer workstation) and on the **LAN** (e.g. a dedicated Linux box / home lab), so prompts can be dispatched and validated interactively without waiting for GitHub Actions workflow runs.

---

## Current State — What Already Exists

### Devcontainer Infrastructure (✅ Complete)

| Component | Path | Status |
|-----------|------|--------|
| Consumer devcontainer config | `.devcontainer/devcontainer.json` | ✅ Pulls prebuild GHCR image, forwards port 4096, auto-starts opencode server via `postStartCommand` |
| Prebuild image | `ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer:main-latest` | ✅ Published, contains .NET SDK 10, Bun, uv, opencode CLI, MCP servers |
| Port forwarding | Port `4096` | ✅ Configured in `devcontainer.json` `forwardPorts` |
| Remote env passthrough | API keys, tokens | ✅ `remoteEnv` maps `localEnv:*` vars into the container |

### Opencode Server Lifecycle Scripts (✅ Complete)

| Script | Path | What It Does |
|--------|------|-------------|
| Server bootstrapper | `scripts/start-opencode-server.sh` | Starts `opencode serve` as a background daemon on `0.0.0.0:4096`, manages PID file, readiness polling, stale process cleanup, graceful shutdown. Already supports env overrides: `OPENCODE_SERVER_HOSTNAME`, `OPENCODE_SERVER_PORT`, `OPENCODE_SERVER_LOG`, `OPENCODE_SERVER_READY_TIMEOUT_SECS` |
| Devcontainer CLI wrapper | `scripts/devcontainer-opencode.sh` | Full lifecycle: `up`, `start`, `prompt`, `stop`, `down`. Handles devcontainer up, exec into the container to start the server, and dispatching prompts via `opencode run --attach` |
| Prompt runner (bash) | `run_opencode_prompt.sh` | Token validation, scope checking, constructs `opencode run --model zai-coding-plan/glm-5 --agent orchestrator --attach <url>` with full auth embedding |
| Prompt runner (pwsh) | `scripts/prompt.ps1` | PowerShell equivalent of `run_opencode_prompt.sh`, with basic auth credential embedding |
| Local prompt dispatcher (pwsh) | `scripts/prompt-local.ps1` | **The key local-use script**: calls `devcontainer-opencode.sh start` then `devcontainer-opencode.sh prompt`, resolves server-side workspace dir automatically. Supports `-Prompt` (inline) and `-File` (from file), `-SkipStart` for already-running containers |

### Prompt Assembly (✅ Complete)

| Component | Path | Status |
|-----------|------|--------|
| Prompt template | `.github/workflows/prompts/orchestrator-agent-prompt.md` | ✅ Template with `__EVENT_DATA__` placeholder |
| Prompt assembler | `scripts/assemble-orchestrator-prompt.sh` | ✅ Injects event metadata + JSON into template |
| Test fixtures | `test/fixtures/` | ✅ Sample webhook payloads for local testing |

### Agent & MCP Infrastructure (✅ Complete)

| Component | Path | Status |
|-----------|------|--------|
| Agent definitions | `.opencode/agents/` | ✅ 27 agent files (orchestrator, specialists) |
| MCP servers | `opencode.json` | ✅ Sequential thinking, memory server configured |
| MCP packages | `.opencode/package.json` | ✅ `@modelcontextprotocol/server-sequential-thinking`, `server-memory` |
| Commands | `.opencode/commands/` | ✅ 20 reusable command prompts |

### Testing Infrastructure (✅ Partial)

| Test | Path | Status |
|------|------|--------|
| Server smoke test | `test/test-opencode-server.sh` | ✅ Starts devcontainer, verifies server bootstrapper, readiness check |
| Run diagnostic matrix | `test/test-opencode-run.sh` | ✅ Matrix test over credentials, agent casing, prompt transport |
| Prompt assembly test | `test/test-prompt-assembly.sh` | ✅ Validates prompt template substitution |
| Devcontainer build test | `test/test-devcontainer-build.sh` | ✅ Build verification |
| Devcontainer tools test | `test/test-devcontainer-tools.sh` | ✅ Tool availability check |

---

## What's NOT Ready / What's Missing

### 1. No `.env` or Local Secrets Management (❌ Missing)

**Problem**: Running locally requires `GH_ORCHESTRATION_AGENT_TOKEN`, `ZHIPU_API_KEY`, `KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY`, and optionally `OPENAI_API_KEY`, `GEMINI_API_KEY` to be exported in the host shell. There's no `.env` file, no `.env.example`, no setup script, and no documentation for how to configure these on a local machine.

**Impact**: First-time local setup is trial-and-error.

### 2. No LAN/Remote Access Configuration (❌ Missing)

**Problem**: The server binds to `0.0.0.0:4096` (good — listens on all interfaces), but:
- No basic auth is enabled by default — anyone on the LAN can dispatch prompts
- No TLS/HTTPS — credentials in `--attach` URLs are plaintext over HTTP
- No firewall guidance
- No hostname/mDNS/IP discovery documented
- `OPENCODE_SERVER_USERNAME`/`OPENCODE_SERVER_PASSWORD` env vars are plumbed through `devcontainer.json` `remoteEnv` but the server bootstrapper (`start-opencode-server.sh`) doesn't pass them to `opencode serve`

**Impact**: Insecure by default on LAN; auth env vars appear to be dead config.

### 3. No Quick-Start / Getting Started Documentation (❌ Missing)

**Problem**: No single document explains: "Here's how to run this locally in 5 steps and send your first prompt." The scripts exist but you have to read the source to understand the invocation flow.

### 4. No Local Prompt Templates for Manual Testing (❌ Missing)

**Problem**: `assemble-orchestrator-prompt.sh` is designed for CI — it expects positional args from GitHub Actions context. There's no local-friendly prompt assembly that lets you simulate an issue event or write a freeform prompt quickly.

**Impact**: You either have to write raw prompts or manually assemble the template, which is what `prompt-local.ps1` partially solves with `-Prompt "say hello"`, but there's no catalog of example test prompts.

### 5. No Health Check / Status Dashboard (❌ Missing)

**Problem**: Once the server is running, there's no easy way to check:
- Is it still alive?
- What model is it using?
- How many sessions are active?
- What's the server log tail?

`devcontainer-opencode.sh` can exec into the container, but there's no `status` command.

### 6. No Docker Compose Alternative (⚠️ Nice-to-have)

**Problem**: The `devcontainer` CLI is powerful but heavy for non-VS Code users. A `docker compose` file would let anyone spin up the server with `docker compose up -d` without installing `devcontainer` CLI or VS Code.

### 7. No Automatic GHCR Image Pull (⚠️ Partial)

**Problem**: `devcontainer up` handles pulling the image, but requires Docker login to GHCR first if the image is private. No script handles the `docker login ghcr.io` step for local use.

### 8. Server Auth Passthrough Incomplete (❌ Bug)

**Problem**: `devcontainer.json` plumbs `OPENCODE_SERVER_USERNAME` and `OPENCODE_SERVER_PASSWORD` from host → container, and `run_opencode_prompt.sh` supports `OPENCODE_AUTH_USER`/`OPENCODE_AUTH_PASS` for `--attach` URL credential embedding. However, `start-opencode-server.sh` does **not** pass `--username`/`--password` flags (or equivalent) to `opencode serve`. The auth chain has a gap: credentials are plumbed to the client side but the server side doesn't enforce them.

---

## Execution Plan

### Phase 1: Foundation — Local Single-Machine Orchestration

**Goal**: Any developer can run the full orchestration stack locally and send prompts.

#### Step 1.1: Create `.env.example` and Environment Setup Script

- Create `.env.example` with all required env vars (commented, with descriptions)
- Create `scripts/setup-local-env.sh` (bash) that:
  - Copies `.env.example` → `.env` if not exists
  - Validates all required vars are set
  - Optionally handles `docker login ghcr.io` via `gh auth token | docker login ghcr.io -u "$(gh api user --jq .login)" --password-stdin`
- `.env` already in `.gitignore`

**Files to create/modify**:
- `NEW` `.env.example`
- `NEW` `scripts/setup-local-env.sh`

**Acceptance Criteria**:
- [ ] `.env.example` exists and lists all required + optional env vars with descriptions
- [ ] `scripts/setup-local-env.sh` is executable and runs without error
- [ ] Running `setup-local-env.sh` on a fresh clone creates `.env` from `.env.example`
- [ ] Running it again (`.env` already exists) does NOT overwrite existing `.env`
- [ ] With required vars unset, the script reports which vars are missing
- [ ] `.env` is not tracked by git

**Validation Commands**:
```bash
# File exists and is executable
test -f .env.example && echo PASS || echo FAIL
test -x scripts/setup-local-env.sh && echo PASS || echo FAIL

# Creates .env from .env.example
rm -f .env && bash scripts/setup-local-env.sh --check-only 2>&1; echo "exit: $?"

# .env not tracked
git check-ignore .env && echo PASS || echo FAIL

# shellcheck passes
shellcheck scripts/setup-local-env.sh && echo PASS || echo FAIL
```

#### Step 1.2: Add `status` Command to `devcontainer-opencode.sh`

- Add a `status` subcommand that reports:
  - Container state (running/stopped/not found)
  - opencode server PID and readiness (curl health check)
  - Server log tail (last 20 lines)
  - Port binding verification
  - Memory file state

**Files to modify**:
- `EDIT` `scripts/devcontainer-opencode.sh` (add `status` case)

**Acceptance Criteria**:
- [ ] `devcontainer-opencode.sh status` returns exit 0 when container + server are running
- [ ] Reports container ID and state
- [ ] Reports server PID and health (up/down)
- [ ] Shows last 20 lines of server log
- [ ] Returns exit 1 with clear message when no container is found
- [ ] Does not modify any state (read-only operation)

**Validation Commands**:

```bash
# Script still passes shellcheck
shellcheck scripts/devcontainer-opencode.sh && echo PASS || echo FAIL

# 'status' appears in usage/help
bash scripts/devcontainer-opencode.sh 2>&1 | grep -q status && echo PASS || echo FAIL

# With no container running, exits non-zero with message
bash scripts/devcontainer-opencode.sh status 2>&1; echo "exit: $?"
```

#### Step 1.3: Add Local Prompt Assembly Helper

- Create `scripts/assemble-local-prompt.sh` that:
  - Accepts a fixture file (`-f test/fixtures/issues-opened.json`) or freeform prompt (`-p "do something"`)
  - For fixture mode: mimics CI prompt assembly using the template + fixture
  - For freeform mode: wraps the provided string with minimal context headers
  - Outputs `.assembled-orchestrator-prompt.md`
- Create sample prompt files in `test/fixtures/prompts/`:
  - `hello-world.txt` — minimal "say hello"
  - `list-issues.txt` — "list open issues and summarize them"
  - `create-epic.txt` — realistic orchestration command

**Files to create/modify**:
- `NEW` `scripts/assemble-local-prompt.sh`
- `NEW` `test/fixtures/prompts/hello-world.txt`
- `NEW` `test/fixtures/prompts/list-issues.txt`
- `NEW` `test/fixtures/prompts/create-epic.txt`

**Acceptance Criteria**:
- [ ] `assemble-local-prompt.sh -p "hello"` produces `.assembled-orchestrator-prompt.md`
- [ ] `assemble-local-prompt.sh -f test/fixtures/issues-opened.json` produces a prompt with event metadata
- [ ] Freeform mode output contains the user's prompt text
- [ ] Fixture mode output contains event name, action, actor, repo, and JSON payload
- [ ] Output file is valid markdown
- [ ] All sample prompt files exist and are non-empty
- [ ] Script is executable and passes shellcheck

**Validation Commands**:

```bash
# Script exists and is executable
test -x scripts/assemble-local-prompt.sh && echo PASS || echo FAIL

# Freeform mode produces output
rm -f .assembled-orchestrator-prompt.md
bash scripts/assemble-local-prompt.sh -p "test prompt"
test -s .assembled-orchestrator-prompt.md && echo PASS || echo FAIL
grep -q "test prompt" .assembled-orchestrator-prompt.md && echo PASS || echo FAIL
rm -f .assembled-orchestrator-prompt.md

# Fixture mode produces output
bash scripts/assemble-local-prompt.sh -f test/fixtures/issues-opened.json
test -s .assembled-orchestrator-prompt.md && echo PASS || echo FAIL
grep -q "issues" .assembled-orchestrator-prompt.md && echo PASS || echo FAIL
rm -f .assembled-orchestrator-prompt.md

# Sample prompts exist
test -s test/fixtures/prompts/hello-world.txt && echo PASS || echo FAIL
test -s test/fixtures/prompts/list-issues.txt && echo PASS || echo FAIL
test -s test/fixtures/prompts/create-epic.txt && echo PASS || echo FAIL

# shellcheck
shellcheck scripts/assemble-local-prompt.sh && echo PASS || echo FAIL
```

#### Step 1.4: Write Quick-Start Documentation

- Create `docs/local-orchestration-quickstart.md` covering:
  1. Prerequisites (Docker, devcontainer CLI, env vars)
  2. First-time setup (clone, env, GHCR login)
  3. Start the stack (one command)
  4. Send your first prompt (inline and file)
  5. Check status and logs
  6. Shut down
  7. Troubleshooting

**Files to create**:
- `NEW` `docs/local-orchestration-quickstart.md`

**Acceptance Criteria**:
- [ ] Document exists and is valid markdown (no lint errors)
- [ ] Contains all 7 sections listed above
- [ ] All script paths referenced in the doc actually exist in the repo
- [ ] All commands in the doc are copy-pasteable (no placeholders that would cause syntax errors)
- [ ] Cross-references the plan doc and relevant scripts

**Validation Commands**:

```bash
# File exists and is non-empty
test -s docs/local-orchestration-quickstart.md && echo PASS || echo FAIL

# Contains all expected sections
for section in "Prerequisites" "First-time" "Start" "prompt" "status" "Shut" "Troubleshoot"; do
  grep -qi "$section" docs/local-orchestration-quickstart.md && echo "PASS: $section" || echo "FAIL: $section"
done

# All referenced scripts exist
grep -oE 'scripts/[a-z0-9_-]+\.(sh|ps1)' docs/local-orchestration-quickstart.md | sort -u | while read f; do
  test -f "$f" && echo "PASS: $f" || echo "FAIL: $f missing"
done
```

---

### Phase 2: LAN-Local — Secure Multi-Machine Access

**Goal**: Run the devcontainer/server on a headless Linux box, dispatch prompts from other machines on the LAN.

#### Step 2.1: Enable Server-Side Authentication

- Modify `scripts/start-opencode-server.sh` to:
  - Read `OPENCODE_SERVER_USERNAME` and `OPENCODE_SERVER_PASSWORD` from env
  - Pass `--username` / `--password` to `opencode serve` when set
  - Log whether auth is enabled (without leaking credentials)
- Verify `run_opencode_prompt.sh` and `scripts/prompt.ps1` already handle embedding credentials in the attach URL (they do)

**Files to modify**:
- `EDIT` `scripts/start-opencode-server.sh` (pass auth flags to opencode serve)

#### Step 2.2: Add TLS Support (Self-Signed or Let's Encrypt)

- Create `scripts/generate-tls-cert.sh` that generates a self-signed cert for LAN use
- Modify `start-opencode-server.sh` to accept `OPENCODE_SERVER_TLS_CERT` and `OPENCODE_SERVER_TLS_KEY` env vars and pass `--tls-cert` / `--tls-key` to `opencode serve` when present
- Update `devcontainer.json` to plumb TLS env vars
- Document cert trust on client machines

**Files to create/modify**:
- `NEW` `scripts/generate-tls-cert.sh`
- `EDIT` `scripts/start-opencode-server.sh` (TLS flags)
- `EDIT` `.devcontainer/devcontainer.json` (TLS env vars in remoteEnv)
- `EDIT` `.env.example` (optional TLS vars)

#### Step 2.3: Docker Compose for Headless Deployment

- Create `docker-compose.yml` at repo root:
  - Service: `opencode-server`
  - Image: `ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer:main-latest`
  - Ports: `4096:4096`
  - Volumes: workspace bind mount, `.env` file, `.memory/` persistence
  - `command: bash ./scripts/start-opencode-server.sh`
  - Health check: `curl -f http://localhost:4096/`
- Create `docker-compose.override.yml.example` for LAN-specific overrides (hostname, TLS, auth)

**Files to create**:
- `NEW` `docker-compose.yml`
- `NEW` `docker-compose.override.yml.example`

#### Step 2.4: LAN Client Prompt Script

- Create `scripts/prompt-remote.ps1` and `scripts/prompt-remote.sh` that:
  - Take `-Server <hostname:port>` (or env `OPENCODE_REMOTE_SERVER`)
  - Handle TLS verification (trust self-signed cert or skip verify)
  - Embed auth credentials
  - Dispatch prompt via `opencode run --attach`
  - Don't require Docker or devcontainer CLI on the client machine — just `opencode` binary or plain HTTP

**Files to create**:
- `NEW` `scripts/prompt-remote.ps1`
- `NEW` `scripts/prompt-remote.sh`

#### Step 2.5: Network Documentation

- Add to `docs/local-orchestration-quickstart.md` a "LAN Access" section covering:
  - Server machine setup
  - Firewall rules (allow port 4096)
  - Client machine setup
  - Service discovery / IP addressing
  - Security considerations

---

### Phase 3: Production-Quality Hardening

**Goal**: Make the local/LAN deployment robust and operator-friendly.

#### Step 3.1: Systemd Service Unit (Linux)

- Create `deploy/opencode-orchestrator.service` — systemd unit that:
  - Runs `docker compose up` or direct `devcontainer up + start`
  - Auto-restarts on failure
  - Logs to journal
  - Loads env from `/etc/opencode-orchestrator/env`

**Files to create**:
- `NEW` `deploy/opencode-orchestrator.service`
- `NEW` `deploy/install-service.sh`

#### Step 3.2: Watchdog and Auto-Recovery

- Enhance `start-opencode-server.sh` with a lightweight watchdog loop:
  - Periodic health check (every 60s)
  - Auto-restart on crash
  - Log rotation
- Or create a separate `scripts/server-watchdog.sh`

#### Step 3.3: Log Aggregation and Tailing

- Add a `logs` subcommand to `devcontainer-opencode.sh`:
  - `logs` — tail the server log
  - `logs --follow` — follow mode
  - `logs --sessions` — list recent sessions with summaries

#### Step 3.4: Update AGENTS.md and Template Docs

- Add `local_orchestration` section to AGENTS.md `<available_tools>`
- Update `<testing>` with local orchestration smoke test commands
- Cross-reference from README

---

## Dependency Map

```
Phase 1          Phase 2              Phase 3
─────────────────────────────────────────────────
1.1 .env setup ──→ 2.1 Server auth ──→ 3.1 Systemd
1.2 status cmd     2.2 TLS            3.2 Watchdog
1.3 local prompt   2.3 docker compose  3.3 Log tailing
1.4 quickstart ──→ 2.4 remote scripts  3.4 Docs update
                   2.5 LAN docs
```

Phase 1 steps are independent of each other and can be parallelized.
Phase 2 has a soft dependency: 2.1 (auth) should come before 2.3 (compose) and 2.4 (remote scripts).
Phase 3 depends on Phase 2 completion.

---

## Environment Variables Reference

| Variable | Required | Used By | Purpose |
|----------|----------|---------|---------|
| `GH_ORCHESTRATION_AGENT_TOKEN` | **Yes** | Server + client | GitHub PAT (scopes: repo, workflow, project, read:org) |
| `ZHIPU_API_KEY` | **Yes** | Server | ZhipuAI model access |
| `KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY` | **Yes** | Server | Kimi/Moonshot model access |
| `OPENAI_API_KEY` | Optional | Server | OpenAI model access |
| `GEMINI_API_KEY` | Optional | Server | Google Gemini model access |
| `OPENCODE_SERVER_HOSTNAME` | Optional | Server | Bind address (default: `0.0.0.0`) |
| `OPENCODE_SERVER_PORT` | Optional | Server | Listen port (default: `4096`) |
| `OPENCODE_SERVER_USERNAME` | Optional | Server + client | Basic auth username (LAN mode) |
| `OPENCODE_SERVER_PASSWORD` | Optional | Server + client | Basic auth password (LAN mode) |
| `OPENCODE_SERVER_TLS_CERT` | Optional | Server | TLS certificate path |
| `OPENCODE_SERVER_TLS_KEY` | Optional | Server | TLS private key path |

---

## Quick Validation Commands (Post-Implementation)

```bash
# Phase 1 — Local smoke test
./scripts/setup-local-env.sh            # first-time setup
bash scripts/devcontainer-opencode.sh up
bash scripts/devcontainer-opencode.sh start
bash scripts/devcontainer-opencode.sh status
bash scripts/devcontainer-opencode.sh prompt -p "say hello"
bash scripts/devcontainer-opencode.sh stop

# Phase 1 — PowerShell one-liner
./scripts/prompt-local.ps1 -Prompt "list open issues"

# Phase 2 — LAN client
./scripts/prompt-remote.ps1 -Server "192.168.1.100:4096" -Prompt "say hello"

# Phase 2 — Docker Compose headless
docker compose up -d
curl http://localhost:4096/
docker compose logs -f opencode-server
```

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| GHCR image is private; local `docker pull` fails without login | High | Blocks setup | `setup-local-env.sh` handles GHCR login automatically |
| `opencode serve` doesn't support `--username`/`--password` flags | Medium | Blocks LAN auth | Verify opencode serve CLI help; fallback: reverse proxy with nginx basic auth |
| `opencode serve` doesn't support TLS natively | Medium | Blocks LAN security | Fallback: TLS-terminating reverse proxy (caddy/nginx) in the compose stack |
| Port 4096 conflicts with other services | Low | Minor friction | Make port configurable (already is via env var) |
| Memory file path inside container vs. host doesn't persist | Medium | Loss of knowledge graph between restarts | Docker volume mount for `.memory/` (already bind-mounted via workspace) |

---

## Success Criteria

- [ ] A developer can go from fresh clone to running prompt in under 10 minutes
- [ ] `devcontainer-opencode.sh status` reports server health clearly
- [ ] Prompts dispatched locally produce the same orchestration behavior as CI
- [ ] LAN clients can securely connect with auth + TLS and dispatch prompts
- [ ] Server survives restarts and preserves knowledge graph memory
- [ ] Documentation is self-contained (no source-diving required)
