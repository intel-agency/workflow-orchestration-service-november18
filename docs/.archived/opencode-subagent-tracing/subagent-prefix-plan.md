# Subagent Activity Line Prefix Plan

**Source:** Run 62401037419 — `intel-agency/workflow-orchestration-queue-foxtrot86`
**Objective:** Add an identifiable prefix to subagent activity lines so they don't blend with `[watchdog]` and `Thinking:` output.

---

## Problem

The opencode CLI emits activity lines with Unicode symbols (`•`, `✓`, `→`, `%`, `⚙`) to stdout. These are streamed to CI via `tail -f "$OUTPUT_LOG"` in `run_opencode_prompt.sh`. Unlike `[server]` and `[watchdog]` lines, they have **no prefix**, making them hard to scan in the CI log.

### Current Output (as seen in CI)

```
[watchdog] client output idle 90s, server write I/O active — subagent likely running
[watchdog] recent server activity:
  | INFO ... service=session id=ses_xxx ...
• Execute project-setup workflow General Agent            ← no prefix
Thinking: Now I have the full project-setup workflow...   ← no prefix
→ Read .opencode/commands/orchestrate-dynamic-workflow.md ← no prefix
⚙ memory_read_graph Unknown                              ← no prefix
✓ Execute project-setup workflow General Agent            ← no prefix
[server] INFO  2026-03-28T05:39:14 +0ms service=session...
```

All unprefixed lines blend together: model text output, thinking, and tool/delegation activity are all visually indistinguishable.

## Subagent Line Types

Extracted from the actual log file (line numbers in `1_orchestrate.txt`):

| Symbol | Meaning | Count | Example | Has Agent Name? |
|---|---|---|---|---|
| `•` | Task delegated (start) | 7 | `• Post initial status update Github-Expert Agent` | Yes (at end) |
| `✓` | Task completed (done) | 12 | `✓ Post initial status update Github-Expert Agent` | Yes (at end) |
| `→` | File read | 4 | `→ Read .opencode/commands/orchestrate-dynamic-workflow.md` | No |
| `%` | Web fetch | 1 | `% WebFetch https://raw.githubusercontent.com/...` | No |
| `⚙` | MCP tool call | 6 | `⚙ memory_read_graph Unknown` | No |

All 30 lines originate from the opencode CLI binary output (not our scripts). They contain ANSI escape codes: `\e[0m<symbol> \e[0m<description>\e[90m <agent-name>\e[0m`.

## Where the Lines Flow

```
opencode run → stdout → $OUTPUT_LOG file → tail -f → CI stdout
```

The relevant code is in `run_opencode_prompt.sh` lines ~235-236:

```bash
tail -f "$OUTPUT_LOG" &
TAIL_PID=$!
```

This is the **only injection point** where we can add a prefix without modifying the opencode binary.

## Proposed Solution

### Option A: `[opencode]` prefix for all activity lines (Recommended)

Add a sed filter between `tail -f` and stdout to prefix lines containing the activity symbols:

```bash
# Before:
tail -f "$OUTPUT_LOG" &
TAIL_PID=$!

# After:
tail -f "$OUTPUT_LOG" | sed -u '/[•✓→⚙%]/s/^/[opencode] /' &
TAIL_PID=$!
```

**Result:**

```
[watchdog] client output idle 90s, server write I/O active — subagent likely running
[opencode] • Execute project-setup workflow General Agent
[opencode] → Read .opencode/commands/orchestrate-dynamic-workflow.md
[opencode] ⚙ memory_read_graph Unknown
Thinking: Now I have the full project-setup workflow...
[opencode] ✓ Execute project-setup workflow General Agent
[server] INFO  2026-03-28T05:39:14 +0ms service=session...
```

**Pros:**
- Simple one-line change
- Clear visual distinction: `[opencode]`, `[server]`, `[watchdog]` are all bracketed prefixes
- `Thinking:` lines and raw model output remain unprefixed (they don't contain those symbols)
- Matches the existing prefix convention

**Cons:**
- Doesn't differentiate between orchestrator-level vs subagent-level activity
- Agent name is still at the end rather than in the prefix

### Option B: `[subagent]` prefix for delegation lines, `[agent]` for tool calls

Use a more specific sed script to differentiate:

```bash
tail -f "$OUTPUT_LOG" | sed -u \
    -e '/[•✓]/s/^/[subagent] /' \
    -e '/[→%⚙]/s/^/[agent] /' &
TAIL_PID=$!
```

**Result:**

```
[subagent] • Execute project-setup workflow General Agent
[subagent] ✓ Execute project-setup workflow General Agent
[agent] → Read .opencode/commands/orchestrate-dynamic-workflow.md
[agent] ⚙ memory_read_graph Unknown
```

**Pros:**
- Distinguishes task delegations (`•`/`✓`) from tool operations (`→`/`%`/`⚙`)
- Makes grepping for subagent lifecycle trivial: `grep '\[subagent\]'`

**Cons:**
- Two separate prefixes add more visual noise
- `[agent]` is ambiguous (which agent?)
- `→`/`⚙` lines at the orchestrator level get `[agent]` even though they're not subagent actions

### Option C: Extract agent name into prefix (Complex)

Parse the agent name from `•`/`✓` lines and embed it:

```bash
tail -f "$OUTPUT_LOG" | sed -u \
    -e 's/\(.*[•✓].*\) \([A-Z][a-z]*\(-[A-Z][a-z]*\)* Agent\)$/[subagent:\2] \1/' \
    -e '/[→%⚙]/s/^/[agent] /' &
```

**Result:**

```
[subagent:Github-Expert Agent] • Post initial status update
[subagent:General Agent] • Execute project-setup workflow
[agent] → Read .opencode/commands/orchestrate-dynamic-workflow.md
```

**Pros:**
- Maximum information density: agent identity is in the prefix
- Trivial to grep: `grep '\[subagent:General Agent\]'`

**Cons:**
- Complex sed regex that's fragile with ANSI escape codes
- The agent name follows `\e[90m` (dim gray ANSI code) which makes regex matching harder
- Breaks if opencode changes its output format
- Harder to maintain and debug

---

## ✅ Implemented: Option B

**Option B (`[subagent]` / `[agent]` split)** was chosen over Option A. Rationale from REMARKS: the `[subagent]` prefix provides sufficient liveness/progress feedback on its own, making the `[watchdog] recent server activity:` echo redundant — so the two changes reinforce each other.

### Impact Assessment

| Aspect | Assessment |
|---|---|
| **Files changed** | 1 (`run_opencode_prompt.sh`) |
| **Lines changed** | 2 (replace `tail -f` line; update comment) |
| **Risk** | Very Low — sed filter only adds text, never removes |
| **Cleanup compatibility** | Compatible — `kill TAIL_PID` → SIGTERM sed → SIGPIPE tail |
| **Performance** | Negligible — sed is processing ~30 matches across a run |
| **Backwards compatibility** | None broken — only CI log appearance changes |

### Implemented Diff

```diff
--- a/run_opencode_prompt.sh
+++ b/run_opencode_prompt.sh
@@ -221,8 +221,10 @@
 echo "opencode process $OPENCODE_PID confirmed running after 1s"

-# Stream the client log to stdout in real-time so CI can see it
-tail -f "$OUTPUT_LOG" &
-TAIL_PID=$!
+# Stream the client log to stdout in real-time so CI can see it.
+# Prefix subagent delegation events (•✓) and tool operations (→%⚙) so they
+# are visually distinct from [server] / [watchdog] lines in the CI log.
+tail -f "$OUTPUT_LOG" | sed -u -e '/[•✓]/s/^/[subagent] /' -e '/[→%⚙]/s/^/[agent] /' &
+TAIL_PID=$!
```

### Result

```
[watchdog] client output idle 90s, server write I/O active — subagent likely running
[subagent] • Execute project-setup workflow General Agent
[agent] → Read .opencode/commands/orchestrate-dynamic-workflow.md
[agent] ⚙ memory_read_graph Unknown
Thinking: Now I have the full project-setup workflow...
[subagent] ✓ Execute project-setup workflow General Agent
[server] INFO  2026-03-28T05:39:14 +0ms service=session...
```

### Follow-up Considerations

- **FIFO safety**: If cleanup issues arise (orphaned `tail -f`), adopt the same FIFO pattern from the server log tailer (lines ~230-245). This is a known pattern in this codebase.
- **Prefix evolution**: If future needs demand agent-name-in-prefix, Option C can be pursued later with better knowledge of whether opencode's ANSI output format is stable.
- **Combined with trace filtering**: Implemented together with Plan 1 Phases 1-3 — see [trace-filtering-analysis-foxtrot86.md](trace-filtering-analysis-foxtrot86.md).


## **REMARKS**

Implement:
Plan 1:
- Phases 1-3

Notes: Leave `[watchdog]` in, OR replace with some kind of progress heartbeat (maybe summarize the line so its shorter/half-length — then it blends in to the rest of the log instead of obscuring it) Oh wait — nm the `[subagent]` prefixes will provide progress/not freezing feedback)

Q:
- Will it get rid of these?: `2026-03-28T06:34:32.9520018Z INFO  2026-03-28T06:28:56 +0ms service=bus type=message.part.delta publishing`
- If we gate/rm the `[watchdog]` lines, will the corresponding `[subagent]` delegate output lines provide process-live feedback? If so do it — otherwise we need some kind of feedback that something is happening, and personally I like seeing how long its been in delegation for

Plan 2:
- Option A

Notes:
- add visual distinction to the agent name suffix, i.e. `(General agent)`) Note: agent type is capitalized, `agent` is not capitalized
- after Option A is proven in a few successful runs, I want Option B implemented.

Q:
- adopting FIFO pattern for cleanup issues (i.e. `tail -f`) — what is the issue exactly? Is it when the process didn't die and the workflow run hung/didn't stop when finished? If so — implement matching pattern here now. We already saw a critical issue from this problem, so it wouldn't make sense to assume it WON'T happen.

Defer:
- Plan 1 Ph4
- Plan 2 Opt B

---

## Implementation Status

| Item | Status | Notes |
|---|---|---|
| **Plan 2: Option B subagent prefixes** | ✅ Done | `[subagent]` for •/✓, `[agent]` for →/%/⚙ in `run_opencode_prompt.sh` — permanent choice |
| **Plan 2: FIFO cleanup for client tailer** | ✅ Done | Same FIFO pattern as server log tailer — `OUTPUT_TAIL_RAW_PID` killed explicitly on cleanup |
| **Plan 1 Phase 1: noise patterns** | ✅ Done | Added `service=llm.*stream$`, `session.prompt step=.*loop$`, `mcp stderr:\s*$` to `_SERVER_LOG_NOISE` (~510 lines removed) |
| **Plan 1 Phase 2: blank `[server]` lines** | ✅ Done | Added `grep -v '^\s*$'` to server log pipe (~170 lines removed) |
| **Plan 1 Phase 3: watchdog recent activity echo** | ✅ Done | Gated `recent server activity:` block behind `DEBUG_ORCHESTRATOR` (~75 lines removed in normal runs) |
| **Plan 1 Phase 4 (optional Tier 2 extras)** | ⏭️ Deferred | `exiting loop`, `cancel`, `mcp key=...found`, `created client` — not yet applied |
| Validation | ✅ Pass | `validate.ps1 -All` — all checks passed (2026-03-28) |

### Q&A

**Q: Will `service=bus` lines be removed?**
Yes. `service=bus` was already in `_SERVER_LOG_NOISE` before these changes (with a trailing space to avoid partial matches). Those lines (`service=bus type=message.part.delta publishing`) have always been filtered.

**Q: If we gate `[watchdog]` lines, do `[subagent]` prefixes provide sufficient liveness feedback?**
Partially. The `[subagent] • / ✓` lines show when a delegation starts and ends, but they appear on the *client* stdout which goes silent *during* subagent execution (because the orchestrator is blocked waiting for the server-side subagent). The `[watchdog]` heartbeat (`client output idle Ns, server write I/O active`) is emitted independently every 30s and is the only signal visible during a long silent delegation. **The `[watchdog]` main line is preserved** (Phase 3 only gated the redundant `recent server activity:` echo lines beneath it).

**Q: FIFO cleanup issue with `tail -f` — is it the hung workflow?**
Exactly. When we `kill TAIL_PID` (which is `sed`), `tail -f` is orphaned in the same pipe. Since `OUTPUT_LOG` is a regular file (not a socket), `tail -f` has no natural EOF signal after `opencode` exits unless we kill it explicitly. Without the FIFO, `tail -f` holds the devcontainer exec session cgroup open forever — the workflow job never finishes. This is the same root cause as the server log tailer bug (fixed with `setsid`). The FIFO pattern is now applied to the client tailer as well.
