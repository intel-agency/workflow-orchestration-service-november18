# Trace Output Filtering Analysis

**Source:** Run 62401037419 — `intel-agency/workflow-orchestration-queue-foxtrot86`
**Workflow:** `orchestrate-dynamic-workflow` / `project-setup`
**Log file:** 74,571 lines — successful run

## Current Filtering State

The `_SERVER_LOG_NOISE` pattern in `run_opencode_prompt.sh` already filters 17 categories:

```
service=bus | service=tool.registry | service=permission | service=bash-tool |
service=provider | service=lsp | service=file.time | service=snapshot |
cwd=.*tracking | service=session.processor | service=session.compaction |
service=session.prompt status= | service=format | service=vcs | service=storage |
ruleset=\[{"permission | action={"permission | mcp stderr: .*running on
```

## Line Type Census

| Category | Count | % of Total | Source |
|---|---|---|---|
| **Bare `INFO` lines (server log dump)** | 70,795 | 94.9% | End-of-run diagnostics step dumps full server log |
| Server content lines (`[server]` non-INFO/box) | 697 | 0.9% | Thought bubble content, PR body echo, etc. |
| `[server] INFO` (session/llm step lines) | 265 | 0.4% | LLM stream starts, session loop steps |
| `[server]` blank lines | 170 | 0.2% | Empty `[server]` lines between log blocks |
| `[watchdog]` lines | 108 | 0.1% | Idle monitoring heartbeats |
| Docker pull layer progress | 84 | 0.1% | `Pulling fs layer`, `Verifying Checksum`, `Pull complete` |
| Git commands/output | ~59 | 0.1% | `[command]/usr/bin/git ...` + output |
| Actions step metadata | ~176 | 0.2% | `env:`, `shell:`, `with:` + env var echoes |
| Actions `##[group/endgroup]` | 66 | 0.1% | Workflow job step grouping |
| **Agent activity** (•✓→⚙%) | ~30 | <0.1% | **Useful: subagent delegation visibility** |
| `Thinking:` lines | 16 | <0.1% | **Useful: model reasoning** |
| Thought boxes (`[server] ┌├└│💭`) | ~56 | 0.1% | **Useful: sequential thinking content** |
| Session create/exit (`[server] INFO service=session id=`) | ~26 | <0.1% | **Useful: subagent lifecycle** |
| `mcp stderr` lines | 30 | <0.1% | MCP server stderr output |
| Devcontainer CLI output | 6 | <0.1% | `@devcontainers/cli` lines |
| opencode startup status | 12 | <0.1% | Auth, prompt, launch status |
| Other | ~100 | 0.1% | Misc framework lines |

### Key `[server] INFO` Subtypes

| Subtype Pattern | Count | Description |
|---|---|---|
| `service=llm` | 251 | LLM stream start per session step |
| `session.prompt step=N ... loop` | 239 | Session prompt loop iteration |
| `service=mcp key=` | 38 | MCP server init/tool calls |
| `mcp stderr:` | 30 | MCP server stderr output |
| `session.prompt ... exiting loop` | 15 | Session prompt loop completion |
| `service=session id=` (create) | 11 | Subagent session creation |
| `session.prompt ... cancel` | ~10 | Session cancel/cleanup |
| `service=db` / `service=default` | 6 | Startup init |

---

## Candidate Types for Filtering

### Tier 1: High Irrelevance / Low Risk — **REMOVE**

Safe to filter; no forensic or progress-tracking value. High line count reduction.

| # | Line Type | Count | Why Irrelevant | Filter Pattern | Risk |
|---|---|---|---|---|---|
| 1 | **`[server] INFO service=llm ... stream`** | 251 | Repeated once per LLM step per session. Says "I'm starting an LLM call" with no content — just model/session IDs. The `session.prompt step=N` line already tells you the step number. | `service=llm .*stream$` added to `_SERVER_LOG_NOISE` | **Very Low** — The `step=N` lines already track loop progress. |
| 2 | **`[server] INFO ... session.prompt step=N ... loop`** | 239 | Emitted every prompt loop iteration. Extremely repetitive. If you have `Thinking:` and `⚙`/`•`/`✓` lines, you know what the agent is doing. | `session\.prompt step=.*loop$` added to `_SERVER_LOG_NOISE` | **Very Low** — `Thinking:` + agent activity lines cover this. |
| 3 | **`[server] INFO ... mcp stderr:`** (empty) | ~20 | Most are blank stderr flushes: `mcp stderr: ` with no content. Only the ones with actual error text have value. | Filter only empty: `mcp stderr: $` (blank) added to `_SERVER_LOG_NOISE` | **Low** — Keep non-empty stderr lines for error visibility. |
| 4 | **`[server]` (blank lines)** | 170 | Empty `[server]` prefix with no content. Visual spacers between log blocks. | `^\[server\]\s*$` (grep pattern in tail filter) | **Very Low** — Pure whitespace noise. |
| 5 | **`[watchdog] recent server activity:` + indented lines** | ~75 | The `recent server activity` block shows 1-3 `[server] INFO` lines you've already seen (or will see). Redundant echo. The main watchdog "subagent likely running" line is useful; the `recent server activity` details are not. | Suppress the `recent server activity:` header and its `  \|` indented line echoes in the watchdog block | **Low** — Keep the main watchdog idle message. Only remove the redundant "recent server activity" echo. |

**Tier 1 removal would eliminate ~755 lines (~1.0% of total, ~20% of non-dump lines).**

### Tier 2: Moderate Irrelevance / Low-Moderate Risk — **CONSIDER**

Useful for deep forensics but not for progress tracking. Filter if log cleanliness is prioritized.

| # | Line Type | Count | Why Semi-Irrelevant | Filter Pattern | Risk |
|---|---|---|---|---|---|
| 6 | **`[server] INFO service=session id=... created`** | 11 | Subagent session creation. Contains slug, parentID, permissions JSON. Useful for forensic tracing but very verbose. | `service=session id=.*created$` | **Moderate** — Losing this means you can't trace parent-child session relationships post-mortem. **Recommendation: Keep** — but consider truncating the JSON permission blob. |
| 7 | **`[server] INFO ... session.prompt ... exiting loop`** | 15 | Session loop exits. Useful to know a subagent finished, but the `✓` agent-task-done line already signals this. | `session\.prompt.*exiting loop` | **Low-Moderate** — The `✓` line is more readable; this is the low-level confirmation. |
| 8 | **`[server] INFO ... session.prompt ... cancel`** | ~10 | Session cancellation lines. Similar to exiting loop but for cancelled sessions. | `session\.prompt.*cancel$` | **Low-Moderate** — Same reasoning as #7. |
| 9 | **Box-drawing borders** (`[server] ┌├└`) | 42 | The sequential thinking box borders. The content inside (thought text) is useful; the borders are decorative. | Cannot filter borders without losing thought content | **HIGH (skip)** — Parsing to keep content but strip borders is fragile. Don't touch. |
| 10 | **`[server] INFO ... service=mcp key=... found`** | ~8 | MCP server discovery lines at startup. One-time init noise. | `service=mcp key=.*found$` | **Low** — One-time lines, small count. |
| 11 | **`[server] INFO ... service=mcp key=... create().*created client`** | ~4 | MCP client creation confirmation. | `create.*successfully created client` | **Low** — One-time lines, very small count. |

**Tier 2 (items 7, 8, 10, 11 only) would eliminate ~37 additional lines.**

### Tier 3: Low Irrelevance / High Risk — **KEEP**

These contribute progress visibility or forensic value. Do not filter.

| # | Line Type | Count | Why Keep |
|---|---|---|---|
| 12 | **Agent activity (`• ✓ → ⚙ %`)** | ~30 | **Core progress visibility** — subagent task start/done, tool calls, file reads. This is the signal. |
| 13 | **`Thinking:` lines** | 16 | **Model reasoning visibility** — shows what the agent is considering. |
| 14 | **Thought box content** (`│ text`) | ~14 | **Sequential thinking content** — the actual analysis inside thought bubbles. |
| 15 | **`💭 Thought N/M` headers** | ~14 | **Thought progress** — shows thinking step count. |
| 16 | **`[watchdog] client output idle Ns, server ... — subagent likely running`** | ~33 | **Liveness signal** — confirms the system isn't hung during long subagent runs. |
| 17 | **opencode startup status lines** | 12 | **Bootstrap confirmation** — auth, launch, prompt delivery. |
| 18 | **`[server] INFO service=session id=... created`** | 11 | **Subagent lifecycle** — who spawned whom and when. |

---

## Recommended Implementation Plan

### Phase 1: Add to `_SERVER_LOG_NOISE` (Tier 1, items 1-3)

Add these patterns to the existing `_SERVER_LOG_NOISE` variable in `run_opencode_prompt.sh`:

```bash
# Existing patterns...
# NEW: suppress repetitive LLM stream start and session loop iteration lines
|service=llm .*stream$|session\.prompt step=.*loop$|mcp stderr: $
```

**Impact:** -510 lines, zero risk to progress visibility.

### Phase 2: Suppress `[server]` blank lines (Tier 1, item 4)

Add blank-line suppression to the `grep -Ev` filter pipe:

```bash
grep -Ev "$_SERVER_LOG_NOISE" < "$_server_log_pipe" | grep -v '^\s*$' | sed -u 's/^/[server] /'
```

**Impact:** -170 lines.

### Phase 3: Suppress watchdog `recent server activity:` echo (Tier 1, item 5)

In the watchdog block, remove or gate the `recent server activity` echo behind `DEBUG_ORCHESTRATOR`:

```bash
# Only show recent server activity in debug mode
if [[ "${DEBUG_ORCHESTRATOR:-}" == "true" && -f "$SERVER_LOG" ]]; then
    _recent=$(tail -20 "$SERVER_LOG" ... )
    ...
fi
```

**Impact:** -75 lines. The main `[watchdog] client output idle ...` message remains.

### Phase 4 (Optional): Tier 2 extras

Add `exiting loop|cancel$|service=mcp key=.*found$|successfully created client` to the noise filter for an additional ~37 lines removed.

---

## Summary

| Phase | Lines Removed | Cumulative | Risk |
|---|---|---|---|
| Phase 1 (LLM/step/mcp-empty) | ~510 | ~510 | Very Low |
| Phase 2 (blank server lines) | ~170 | ~680 | Very Low |
| Phase 3 (watchdog echo) | ~75 | ~755 | Low |
| Phase 4 (Tier 2 extras) | ~37 | ~792 | Low-Moderate |
| **Total non-dump lines remaining** | **~2,900** → **~2,145** | **~26% reduction** | |

> **Note:** The 70,795-line bare `INFO` block is the end-of-run diagnostics step that dumps the _entire_ server log. This is a separate concern — it's in a `##[group]` fold in the Actions UI and doesn't affect readability of the live run. If desired, that dump could be truncated or moved to artifact-only, but that's a different scope change.
