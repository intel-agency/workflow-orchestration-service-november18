# MCP Memory Server Migration Plan

## From: `@modelcontextprotocol/server-memory` (JSONL, Node/npx)
## To: `mcp-memory-service` (SQLite-vec, Python/uvx)

**Status:** ~~IMPLEMENTED~~ **REVERTED (2026-04-02)** — cold-start package download (~2.5GB) blocked orchestrator; race condition fixed via instructions instead. See Section 13.  
**Date:** 2026-03-29  
**Author:** Copilot — research, plan, and implementation  
**Post-Implementation Update:** Revised with findings from first implementation run to serve as the reference guide for applying this migration to the template repo and future cloned instances.

---

## 1. Problem Statement

The current `@modelcontextprotocol/server-memory` has a **confirmed race condition** ([#2579](https://github.com/modelcontextprotocol/servers/issues/2579)) — concurrent processes writing to the same `memory.jsonl` file without locking or atomic writes corrupts the file, producing JSON parse errors like `"expecting value: line 1 column N"`.

**Impact:** Every opencode orchestration run spawns multiple agents (orchestrator + up to 6 concurrent subagents), each sharing the same memory MCP server process. Concurrent `saveGraph()` calls hit the unprotected `writeFile()` path, and the file gets corrupted mid-run.

**Fix status upstream:** The atomic write commit (`03ddb97`) was pushed to a feature branch but **never merged to `main`**. The real multi-instance fix (file locking, [PR #3286](https://github.com/modelcontextprotocol/servers/pull/3286)) is **still open**. The npm package `v2026.1.26` (latest) still uses plain `writeFile` with zero protection.

---

## 2. Setup Type Analysis

Based on the [mcp-memory-service wiki](https://github.com/doobidoo/mcp-memory-service/wiki), there are 4 setup types:

| Setup Type | Backend | Install Method | Concurrency Safety | Fits Our Use Case? |
|---|---|---|---|---|
| **PyPI + stdio** | SQLite-vec (default) | `pip install mcp-memory-service` / `uvx` | **YES** — SQLite WAL mode + `busy_timeout=15000` pragma, zero DB locks | **YES — recommended** |
| **PyPI + HTTP server** | SQLite-vec | `uv run memory server --http` | **YES** — same SQLite + HTTP coordinator | Overkill for MCP stdio |
| **Docker** | SQLite-vec | `docker-compose up` | **YES** | Redundant — already in devcontainer |
| **Cloudflare/Hybrid** | Cloudflare D1 + SQLite | env vars + API tokens | **YES** | Too complex, adds cloud dep |

### Recommendation: **PyPI + stdio (SQLite-vec backend)**

**Rationale:**
- SQLite-vec with WAL mode handles concurrent access correctly — this directly resolves the race condition
- `busy_timeout=15000` auto-configured in v8.9.0+ means concurrent writes queue rather than corrupt
- stdio transport is what opencode natively uses for MCP servers
- `uvx mcp-memory-service` works identically to `npx -y @modelcontextprotocol/server-memory` — zero-install ephemeral run via `uv` (already in the devcontainer)
- No HTTP server, OAuth, or external services needed
- The `.db` file is a SQLite database — can be cached in CI just like the current `.jsonl` file

---

## 3. API Surface Migration (Breaking Change)

This is the core complexity. The two servers expose **completely different MCP tools**.

### Tool Name Mapping

| Old Server Tool | New Server Tool | Semantic Equivalent? |
|---|---|---|
| `create_entities` | `store_memory` | **Partial** — old creates graph nodes; new stores text+tags |
| `create_relations` | *(no direct equivalent)* | New server has knowledge graph with typed edges, but API is different |
| `add_observations` | `store_memory` | Store additional facts → store a new memory |
| `delete_entities` | `delete_memory` | Delete by entity name → delete by content hash |
| `delete_observations` | `delete_memory` | Same |
| `delete_relations` | *(delete handled implicitly)* | Edge cleanup is automatic in v10.29.1 |
| `read_graph` | `retrieve_memory` / `search_by_tag` | Read all → retrieve by query or tag |
| `search_nodes` | `retrieve_memory` | Semantic search equivalent |
| `open_nodes` | `retrieve_memory` | Open specific → retrieve specific |

### Key MCP Tools Exposed by `mcp-memory-service`

From the integration guide and feature list:
- **`store_memory`** — store content with optional tags and memory_type
- **`retrieve_memory`** — semantic search for memories
- **`search_by_tag`** — tag-based retrieval
- **`delete_memory`** — remove by content hash
- **`check_database_health`** — health/diagnostics

### What Changes in Agent Instructions

The agent files currently instruct agents to:
1. **At task start:** `Call read_graph or search_nodes to load prior project context from memory`
2. **During work:** `Persist important findings via create_entities / add_observations`
3. **At completion:** `Store outcomes and lessons learned in the knowledge graph`

These will become:
1. **At task start:** `Call retrieve_memory or search_by_tag to load prior project context from memory`
2. **During work:** `Persist important findings via store_memory with relevant tags`
3. **At completion:** `Store outcomes and lessons learned via store_memory`

---

## 4. Scope of Changes

> **Implementation note:** The original plan underestimated scope. The actual migration touched **40 files** across 7 categories (not the ~24 originally estimated). Key discoveries are noted with ⚠️ below.

### 4.1 Configuration Files

| File | Change |
|---|---|
| `opencode.json` → `mcp.memory` | Replace `["npx", "-y", "@modelcontextprotocol/server-memory"]` command with `["uvx", "mcp-memory-service"]`; replace `environment` from `MEMORY_FILE_PATH` to `MCP_MEMORY_STORAGE_BACKEND`, `MCP_MEMORY_SQLITE_PATH`, and `MCP_MEMORY_SQLITE_PRAGMAS` |
| `opencode.json` → `permission.mcp_tool` | Replace all 9 `memory:*` tool permissions with 5 new ones: `memory:store_memory`, `memory:retrieve_memory`, `memory:search_by_tag`, `memory:delete_memory`, `memory:check_database_health` |
| `.devcontainer/devcontainer.json` | Replace single `MEMORY_FILE_PATH` env var with 3 new vars: `MCP_MEMORY_SQLITE_PATH=${containerWorkspaceFolder}/.memory/memory.db`, `MCP_MEMORY_STORAGE_BACKEND=sqlite_vec`, `MCP_MEMORY_SQLITE_PRAGMAS=busy_timeout=15000,journal_mode=WAL,synchronous=NORMAL` |
| ⚠️ `.factory/mcp.json` | Replace npx command+args with `uvx` + `mcp-memory-service` (Factory Droid MCP config) |
| ⚠️ `.qwen/settings.json` | Replace npx command+args with `uvx` + `mcp-memory-service` (Qwen Code MCP config) |
| ⚠️ `.opencode/package.json` | **Remove** the `@modelcontextprotocol/server-memory` npm dependency (no longer needed; keep `server-sequential-thinking`) |
| ⚠️ `docker-compose.yml` | Add `MCP_MEMORY_STORAGE_BACKEND`, `MCP_MEMORY_SQLITE_PATH=/opt/orchestration/.memory/memory.db`, and `MCP_MEMORY_SQLITE_PRAGMAS` env vars to the `orchestration-server` service |

#### ⚠️ CRITICAL: opencode.json schema restriction

The opencode.json schema does **NOT** support a separate `"args"` field on MCP server definitions. The `mcp-memory-service` PyPI README shows `uvx mcp-memory-service` as the full invocation (no subcommand needed for stdio mode). Use:

```json
"memory": {
  "type": "local",
  "command": ["uvx", "mcp-memory-service"],
  "environment": {
    "MCP_MEMORY_STORAGE_BACKEND": "sqlite_vec",
    "MCP_MEMORY_SQLITE_PATH": "${MCP_MEMORY_SQLITE_PATH}",
    "MCP_MEMORY_SQLITE_PRAGMAS": "busy_timeout=15000,journal_mode=WAL,synchronous=NORMAL"
  }
}
```

Do **NOT** add `"args": ["server"]` — this causes a schema validation error (`Property args is not allowed`). The command array alone is sufficient.

#### ⚠️ Database filename convention

Use `memory.db` (not `sqlite_vec.db`) as the database filename. This is simpler, consistent with the `.memory/` directory purpose, and avoids confusion. All paths should reference `.memory/memory.db`.

### 4.2 Workflow & Script Files

| File | Change |
|---|---|
| `.github/workflows/orchestrator-agent.yml` | Update "Seed memory file" step: change `memory.jsonl` check to `memory.db`; replace `wc -l`/`wc -c` with `stat -c%s` (binary file, line count is meaningless) |
| `scripts/devcontainer-opencode.sh` | Update status command diagnostic: change `MEMORY_FILE_PATH` env var to `MCP_MEMORY_SQLITE_PATH`; change default path from `memory.jsonl` to `memory.db`; replace `wc -l`/`wc -c` with `stat -c%s` for size reporting |
| ⚠️ `.github/workflows/prompts/orchestrator-agent-prompt.md` | **Critical** — this is the runtime prompt injected into every orchestration run. Contains `read_graph`, `add_observations`, `create_entities`, `search_nodes` references at 3 distinct locations (Step 1 startup, Step 3 guidance, and Final/completion section). All must be updated. |

### 4.3 Agent Instruction Files — `.opencode/agents/` (18 files)

All 18 files in `.opencode/agents/`:

```
agent-instructions-expert.md  backend-developer.md  cloud-infra-expert.md
code-reviewer.md  database-admin.md  debugger.md  developer.md
devops-engineer.md  documentation-expert.md  frontend-developer.md
github-expert.md  odbplusplus-expert.md  orchestrator.md  planner.md
product-manager.md  qa-test-engineer.md  researcher.md  ux-ui-designer.md
```

**Verified search-and-replace patterns (exact strings used in implementation):**

For all 17 non-orchestrator agents, each file has exactly 2 occurrences:
1. `Call \`read_graph\` or \`search_nodes\` to load prior project context from memory` → `Call \`retrieve_memory\` or \`search_by_tag\` to load prior project context from memory`
2. `Persist important findings via \`create_entities\` / \`add_observations\`` → `Persist important findings via \`store_memory\``

#### ⚠️ `orchestrator.md` has 5 ADDITIONAL occurrences beyond the standard 2

| Location | Old Pattern | New Pattern |
|---|---|---|
| Operating Procedure step 1 (MANDATORY STARTUP) | `Call \`read_graph\` or \`search_nodes\` to load prior project context` | `Call \`retrieve_memory\` or \`search_by_tag\` ...` |
| Operating Procedure step 12 (MANDATORY COMPLETION) | `Call \`create_entities\` / \`add_observations\` to persist task outcomes...to the knowledge graph` | `Call \`store_memory\` to persist task outcomes...to persistent memory` |
| Mandatory Tool Protocol section title + lines | `### Knowledge Graph Memory` + `read_graph or search_nodes` + `create_entities, add_observations, or create_relations` | `### Persistent Memory` + `retrieve_memory or search_by_tag` + `store_memory` |
| Protocol Compliance Checklist | `☐ \`read_graph\` / \`search_nodes\` was called` | `☐ \`retrieve_memory\` / \`search_by_tag\` was called` |
| Protocol Compliance Checklist | `☐ Important findings were persisted to the knowledge graph` | `☐ Important findings were persisted to persistent memory` |

### ⚠️ 4.3b Agent Instruction Files — `.factory/droids/` (18 files)

**This was NOT in the original plan.** The `.factory/droids/` directory mirrors `.opencode/agents/` for the Factory Droid CLI. The same 18 files exist with the same 2-pattern replacement, and `orchestrator.md` has the same 5 extra occurrences. **Do not skip this directory.**

```
agent-instructions-expert.md  backend-developer.md  cloud-infra-expert.md
code-reviewer.md  database-admin.md  debugger.md  developer.md
devops-engineer.md  documentation-expert.md  frontend-developer.md
github-expert.md  odbplusplus-expert.md  orchestrator.md  planner.md
product-manager.md  qa-test-engineer.md  researcher.md  ux-ui-designer.md
```

### 4.4 AGENTS.md (root-level instructions)

| Section | Change |
|---|---|
| `<protocol id="knowledge_graph_memory">` | Rename to `<protocol id="persistent_memory">`; update `<title>` from "Knowledge Graph Memory" to "Persistent Memory"; replace 9-tool `<tools>` block with 5 new tools; update `<required_usage_points>` text |
| `<agent_checklist>` | `Called read_graph / search_nodes` → `Called retrieve_memory / search_by_tag`; `Persisted important findings to knowledge graph memory` → `Persisted important findings to persistent memory` |
| `<agent_specific_guardrails>` (orchestrator rule) | `read_graph before every new task` → `retrieve_memory before every new task` |
| `<instruction id="memory_default_usage">` in `<tool_use_instructions>` | Update `<title>`, `<tools>` element (all 9 → 5 new), and `<guidance>` text to reference new tool names and protocol ID |
| `<tech_stack>` | `@modelcontextprotocol/server-memory` → `mcp-memory-service (SQLite-vec persistent memory via uvx)` |

### 4.5 Local Instruction Modules

| File | Change |
|---|---|
| `local_ai_instruction_modules/ai-development-instructions.md` | Lines referencing Memory Tool — update tool name list in parentheses and all 3 sub-bullets (task START, significant work, task END) |

---

## 5. Testing & CI Plan

### 5.1 Pre-Commit Validation (MANDATORY)

Run the full validation suite before every commit:

```bash
pwsh -NoProfile -File ./scripts/validate.ps1 -All
```

**Expected results from implementation run:**
- actionlint: PASS
- PSScriptAnalyzer: PASS
- JSON syntax: PASS (validates `opencode.json`, `.factory/mcp.json`, `.qwen/settings.json`, `.opencode/package.json`)
- gitleaks: PASS
- prompt-assembly tests: PASS (36/36)
- image-tag-logic tests: PASS
- watchdog-io-detection tests: PASS (23/23)

> **Note:** Pester tests may show `SecurityError` on Windows due to execution policy — this is a pre-existing issue, not related to the migration. CI runs on Linux where this doesn't apply.

### 5.2 Post-Implementation Grep Verification

After all edits, verify zero old tool name references remain in active files:

```bash
# Should return ONLY matches in docs/ and plan_docs/ (historical documentation)
grep -rn 'read_graph\|search_nodes\|create_entities\|add_observations\|create_relations\|delete_entities\|delete_observations\|delete_relations\|open_nodes' \
  --include='*.md' --include='*.json' --include='*.yml' --include='*.sh' \
  . | grep -v '/docs/' | grep -v '/plan_docs/' | grep -v '/.archived/'
```

This should return **zero results**. If any active file matches, fix it before committing.

Also verify no stale env vars or file paths:

```bash
grep -rn 'MEMORY_FILE_PATH\|memory\.jsonl' \
  --include='*.json' --include='*.yml' --include='*.sh' --include='*.ps1' \
  . | grep -v '/docs/' | grep -v '/plan_docs/'
```

### 5.3 New Test: Memory Server Smoke Test (optional)

Add a test that validates the memory server starts and responds to MCP protocol:

```bash
# test/test-memory-server.sh
# 1. Start mcp-memory-service via uvx in stdio mode
# 2. Send a store_memory request via stdin JSON-RPC
# 3. Verify success response
# 4. Send a retrieve_memory request
# 5. Verify the stored memory is returned
# 6. Verify the .db file exists and is valid SQLite
```

> **Note:** This test requires `uv`/`uvx` to be installed and network access for first-run package download. Consider gating behind a `HAS_UVX` check.

### 5.4 New Pester Test: Memory Server Config Validation (recommended)

```powershell
# test/Validate-MemoryServer.Tests.ps1
Describe 'Memory Server Configuration' {
    It 'opencode.json uses uvx mcp-memory-service' {
        $config = Get-Content opencode.json | ConvertFrom-Json
        $config.mcp.memory.command | Should -Be @('uvx', 'mcp-memory-service')
    }
    It 'opencode.json has correct permission entries' {
        $config = Get-Content opencode.json | ConvertFrom-Json
        $perms = $config.permission.mcp_tool
        $perms.'memory:store_memory' | Should -Be 'allow'
        $perms.'memory:retrieve_memory' | Should -Be 'allow'
        $perms.'memory:search_by_tag' | Should -Be 'allow'
        $perms.'memory:delete_memory' | Should -Be 'allow'
        $perms.'memory:check_database_health' | Should -Be 'allow'
    }
    It 'No agent file references old memory tool names' {
        $oldTools = 'read_graph|search_nodes|create_entities|add_observations|create_relations|delete_entities|delete_observations|delete_relations|open_nodes'
        $hits = Get-ChildItem .opencode/agents/*.md, .factory/droids/*.md |
            Select-String -Pattern $oldTools
        $hits | Should -BeNullOrEmpty
    }
    It 'devcontainer.json has MCP_MEMORY_SQLITE_PATH' {
        $dc = Get-Content .devcontainer/devcontainer.json | ConvertFrom-Json
        $dc.remoteEnv.MCP_MEMORY_SQLITE_PATH | Should -Not -BeNullOrEmpty
    }
}
```

### 5.5 Existing Test Updates

| Test | Change Needed |
|---|---|
| `test/validate-agents.ps1` | Add assertion: no agent file contains old tool names (see Pester test above) |
| CI workflow (`validate.yml`) | No changes needed — existing `-Test` switch picks up new Pester tests |

---

## 6. Local Usage (Windows / VS Code Insiders / Copilot)

### 6.1 OpenCode (local, non-devcontainer)

Same `opencode.json` config works locally. Requirements:
- `uv` installed locally (you already have it)
- First run of `uvx mcp-memory-service` downloads the package and ONNX model (~200MB one-time)
- Set `MCP_MEMORY_SQLITE_PATH` env var to a local path (e.g., `$HOME/.mcp-memory/memory.db`)

### 6.2 VS Code Insiders (Copilot Chat MCP)

VS Code Insiders supports MCP servers in `settings.json`:

```jsonc
// .vscode/settings.json or user settings
{
  "mcp": {
    "servers": {
      "memory": {
        "command": "uvx",
        "args": ["mcp-memory-service"],
        "env": {
          "MCP_MEMORY_STORAGE_BACKEND": "sqlite_vec",
          "MCP_MEMORY_SQLITE_PATH": "${workspaceFolder}/.memory/memory.db"
        }
      }
    }
  }
}
```

### 6.3 Shared DB Path (Optional)

For a shared experience across opencode + VS Code on the same machine, point both at the same `.db` file. SQLite WAL mode handles concurrent readers/writers safely.

---

## 7. Devcontainer / CI Changes

### Devcontainer Image

The devcontainer already has `uv` installed. `uvx mcp-memory-service` will download on first use. **No Dockerfile changes needed** (the Dockerfile lives in the external `intel-agency/workflow-orchestration-prebuild` repo).

However: first run downloads ONNX model (~200MB). For CI stability, consider:
- **Option A:** Accept cold-start cost (one-time per workflow run, cached by uv)
- **Option B:** Pre-install in the prebuild image (requires external repo change)

**Recommendation:** Option A for now. The uv cache will handle subsequent runs within the same devcontainer session.

### CI Cache Update

```yaml
# .github/workflows/orchestrator-agent.yml
# Cache path stays as .memory/ — the directory is the same, only the file inside changes
- name: Restore knowledge graph memory cache
  uses: actions/cache/restore@SHA # v4
  with:
    path: .memory/
    key: orchestrator-memory-${{ github.repository }}

- name: Seed memory file into devcontainer workspace
  run: |
    mkdir -p .memory
    if [ -f .memory/memory.db ]; then
      echo "Restored memory database: $(stat -c%s .memory/memory.db) bytes"
    else
      echo "No cached memory database found — starting fresh"
    fi
```

> **Note:** The cache `path: .memory/` and `key:` pattern remain unchanged — only the seed step diagnostic changes from `memory.jsonl`/`wc` to `memory.db`/`stat`. The cache save step (`actions/cache/save`) needs no changes since it saves the whole `.memory/` directory.

---

## 8. Rollback Plan

If the migration causes issues:
1. Revert `opencode.json` `mcp.memory` block to the old npx command
2. Revert agent files (git revert the commit)
3. Delete `.memory/memory.db`
4. Old `memory.jsonl` can be restored from CI cache

The migration is fully reversible in a single git revert.

---

## 9. Implementation Order (verified)

> The order below was verified during the first implementation. Phases are sequenced to minimize context-switching and maximize bulk-edit efficiency.

| Phase | Description | File Count | Notes |
|---|---|---|---|
| **Phase 1** | `opencode.json` — MCP server block + permission block | 1 | ⚠️ Do NOT add `"args"` field — put everything in `"command"` array |
| **Phase 2** | `.devcontainer/devcontainer.json` — env vars | 1 | Replace 1 env var with 3 |
| **Phase 3** | `AGENTS.md` — mandatory tool protocols, checklist, guardrails, tech_stack, tool_use_instructions | 1 | 6 distinct edit locations |
| **Phase 4** | `local_ai_instruction_modules/ai-development-instructions.md` | 1 | 1 edit location (Memory Tool bullet) |
| **Phase 5** | `.opencode/agents/*.md` — 17 non-orchestrator agents (2 replacements each) + orchestrator.md (7 replacements) | 18 | Use bulk find-and-replace; orchestrator.md needs separate, targeted edits |
| **Phase 6** | `.factory/droids/*.md` — same as Phase 5 but for Factory Droid agents | 18 | Mirror of Phase 5; identical patterns |
| **Phase 7** | `.github/workflows/orchestrator-agent.yml` — cache seed step | 1 | `memory.jsonl` → `memory.db`; `wc` → `stat` |
| **Phase 8** | `scripts/devcontainer-opencode.sh` — status diagnostic | 1 | `MEMORY_FILE_PATH` → `MCP_MEMORY_SQLITE_PATH`; `memory.jsonl` → `memory.db` |
| **Phase 9** | `.github/workflows/prompts/orchestrator-agent-prompt.md` — runtime prompt | 1 | 3 edit locations (startup, guidance, completion) |
| **Phase 10** | Ancillary configs: `.factory/mcp.json`, `.qwen/settings.json`, `.opencode/package.json`, `docker-compose.yml` | 4 | Easy bulk edits |
| **Phase 11** | Run `validate.ps1 -All` | - | Must pass before commit |
| **Phase 12** | Run grep verification (Section 5.2) | - | Zero active-file matches required |
| **Phase 13** | Add tests (Pester config validation, optional smoke test) | 1-2 new files | |

**Total files modified:** ~40 (18 + 18 agent files + ~7 config/workflow/script files)

---

## 10. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| ONNX model download fails in CI | Low | High (run fails) | uv caches aggressively; retry logic in workflow |
| Agent behavior changes | Medium | Medium | Tool names are only referenced in instruction text, not in code; agents adapt |
| `mcp-memory-service` MCP protocol incompatibility with opencode | Low | High | Test locally before pushing; opencode supports standard MCP stdio |
| CI cache miss on first run (no `.db` file) | Expected | Low | Same as current behavior with empty `.jsonl` |
| `uvx` not available in devcontainer | Very Low | High | `uv` is pre-installed in prebuild image; `uvx` is a `uv` subcommand |

---

## 11. Approval Checklist

- [x] Approved: Switch from `@modelcontextprotocol/server-memory` to `mcp-memory-service`
- [x] Approved: SQLite-vec backend via stdio (no HTTP server)
- [x] Approved: Full tool-name migration across all agent files + AGENTS.md
- [x] Approved: CI cache path change (`.memory/memory.jsonl` → `.memory/memory.db`)
- [ ] Pending: New tests added (Pester config validation + optional smoke test)
- [x] Approved: Local VS Code Insiders config recommendation

**Implementation completed in reference instance.** This plan is now the reference for porting to the template repo.

> ⚠️ **REVERTED 2026-04-02:** This migration was applied to the template repo and immediately reverted. Do not re-apply without resolving the cold-start package download problem (see Section 13).

---

## 12. Lessons Learned (Post-Implementation)

1. **Scope was significantly underestimated.** The original plan identified ~24 files. Actual count was **40 files** due to `.factory/droids/` mirror and ancillary configs (`.factory/mcp.json`, `.qwen/settings.json`, `.opencode/package.json`, `docker-compose.yml`, orchestrator-agent-prompt.md).

2. **Always grep the entire repo** before starting edits. The initial file list was built from known locations; the comprehensive grep revealed 4 additional config files and the entire `.factory/droids/` directory.

3. **`orchestrator.md` is special.** Both `.opencode/agents/orchestrator.md` and `.factory/droids/orchestrator.md` have ~7 edit locations each (vs. 2 for other agents). Treat as a separate edit pass.

4. **opencode.json schema is strict.** No `"args"` field allowed on MCP server definitions. The original `mcp-memory-service` README suggests `server` as a subcommand, but for opencode stdio mode, `["uvx", "mcp-memory-service"]` alone is the correct invocation.

5. **Use `memory.db` not `sqlite_vec.db`.** The original plan used `sqlite_vec.db` but `memory.db` is simpler and more maintainable. Be consistent across all files.

6. **Binary file diagnostics.** Replace `wc -l` / `wc -c` (line + byte count, meaningful for JSONL) with `stat -c%s` (byte size only, appropriate for SQLite binary).

7. **Documentation files are exempt.** The migration plan doc itself, archived docs, and plan_docs will still contain old tool names as historical references. This is correct — only active config, agent instructions, and runtime code need updating.

8. **Bulk-edit efficiency.** The 17 non-orchestrator agents in each directory (`.opencode/agents/` and `.factory/droids/`) have identical replacement patterns. Use multi-file find-and-replace tooling (34 replacements per directory can be batched into a single operation).

---

## 13. REVERSION — 2026-04-02

**Status: THIS MIGRATION WAS REVERTED.** The template repo was rolled back to `@modelcontextprotocol/server-memory` on 2026-04-02. See commits `69bb982`, `180859f`.

### Why It Was Reverted

#### Root cause: Cold-start package download (~2.5GB) blocks the orchestrator

`mcp-memory-service` uses `sentence-transformers` for semantic search, which pulls in the full PyTorch + ONNX + CUDA stack at runtime via `uvx`. On a cold devcontainer (no uv package cache), the first invocation downloads **~2.5GB** of packages before the MCP server can respond. This was observed in production:

- **Evidence:** Forensic analysis of run `intel-agency/convo-content-buddy-bravo61` workflow run `#23929140287`
- **Symptom:** 43-minute gap in all log output between 01:04:48 UTC and 01:47:46 UTC — the orchestrator was stuck waiting for `mcp-memory-service` to initialize
- **Result:** Watchdog killed the process at 01:47:46 (SIGTERM, exit 143, `IDLE_TIMEOUT_SECS=900`)
- **Zero useful work completed** — the entire workflow run failed before the orchestrator wrote a single line of output

This is a structural problem with any fresh clone of the template. GitHub Actions runners do not persist the uv package cache across workflow runs by default, and the devcontainer used here (sourced from the external prebuild image) also has no pre-installed `mcp-memory-service` packages.

#### The premise was wrong: the race condition fix was unnecessary

The original problem was concurrent subagent writes to `memory.jsonl` corrupting the file. The SQLite-WAL approach was valid, but the simpler fix is to enforce at the instruction level that **only the orchestrator writes to memory**. Subagents can read but never write — eliminating the concurrency entirely without any infrastructure change.

### What We Reverted To

| Aspect | Reverted back to |
|---|---|
| **Runtime** | `npx -y @modelcontextprotocol/server-memory` |
| **Backend** | JSONL file (`.memory/memory.jsonl`) |
| **Size** | ~30MB (Node.js package, no ML deps) |
| **Cold-start** | Near-instant (npx caches after first pull) |
| **Tools** | 9 knowledge-graph tools: `create_entities`, `add_observations`, `create_relations`, `delete_entities`, `delete_observations`, `delete_relations`, `read_graph`, `search_nodes`, `open_nodes` |
| **Env var** | `MEMORY_FILE_PATH=${containerWorkspaceFolder}/.memory/memory.jsonl` |

### How the Race Condition Was Fixed

Rather than replacing the server, the race condition is now prevented via agent instructions:

- **Orchestrator only** may call memory write tools (`create_entities`, `add_observations`, `create_relations`, `delete_entities`, `delete_observations`, `delete_relations`)
- **All subagents** are restricted to read-only tools (`read_graph`, `search_nodes`, `open_nodes`)
- Subagent files replace "persist findings via `create_entities`" with "report findings to the orchestrator for knowledge graph persistence"
- The write restriction is stated explicitly in:
  - Both `orchestrator.md` files (Knowledge Graph Memory section)
  - `orchestrator-agent-prompt.md` (MANDATORY COMPLETION section)
  - `AGENTS.md` (`mandatory_tool_protocols.persistent_memory` — new `<write_restriction>` element)
  - `local_ai_instruction_modules/ai-development-instructions.md`

Since the orchestrator is a single process (not parallelized), there is now only ever one writer at a time, and the race condition cannot occur.

### Files Changed in Reversion

Same 45 files as the original migration, applied in reverse. Validated with `pwsh -NoProfile -File ./scripts/validate.ps1 -All` — 8 pass, 0 fail.
