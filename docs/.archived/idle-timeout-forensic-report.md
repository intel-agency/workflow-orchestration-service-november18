# Idle Timeout Failure — Forensic Report

> **Date:** 2026-03-26  
> **Scope:** All orchestrator-agent workflow runs across deployed template clones  
> **Affected repos:** delta61, bravo74, kilo57. Also: juliet62 (2026-03-25)  
> **Pattern confirmed:** Yes — systemic idle timeout failures during subagent delegation

---

## 1. Executive Summary

The last **5 consecutive orchestrator failures** across 4 deployed template clones are all idle timeout kills. The opencode process is terminated with SIGTERM (exit 143) after 15 minutes of no client or server output. In every case, the agent stalls at the same orchestration phase: **subagent delegation during the `review-epic-prs` / `pr-approval-and-merge` step** (Step 2/4 of the per-epic orchestration sequence).

This is now a confirmed pattern, not isolated incidents.

---

## 2. Forensic Evidence

### 2.1 Failure Inventory

| # | Repo | Run ID | Date (UTC) | Orchestration Stage | Last Output Before Kill | Idle Duration | Exit |
|---|------|--------|------------|---------------------|------------------------|---------------|------|
| 1 | delta61 | 23604709619 | 2026-03-26 16:06 | `orchestration:epic-implemented` → review-epic-prs | Delegated to Code-Reviewer Agent (16:13:14) | 15m 11s | 143 |
| 2 | bravo74 | 23596917953 | 2026-03-26 13:29 | `orchestration:epic-implemented` → review-epic-prs | Delegated to Code-Reviewer for pr-approval-and-merge (13:36:40) | 15m 46s | 143 |
| 3 | kilo57 | 23591777285 | 2026-03-26 11:25 | `orchestration:epic-implemented` → review-epic-prs | Delegated to Github-Expert for PR #7 (11:31:12) | 16m 37s | 143 |
| 4 | kilo57 | 23580619888 | 2026-03-26 06:24 | Same as above | PR review delegation (~06:25) | ~19m | 143 |
| 5 | juliet62 | 23525004541 | 2026-03-25 04:31 | PR review delegation | Subagent dispatched (~04:37) | ~33m* | 143 |

\*juliet62 had server I/O activity (write_bytes) for the first ~5 min, so the idle timer reset. Still eventually timed out.

### 2.2 Other Failure Types (Non-Idle)

For completeness, the template repo's own most recent failure (run 23415797162, 2026-03-23) was **not** an idle timeout — it was a `GH_ORCHESTRATION_AGENT_TOKEN` missing the `read:org` scope. Quebec50's failure was a missing devcontainer image. These are unrelated to the idle timeout pattern.

### 2.3 Success Rate Context

Looking at the most recent clone repos:
- **delta61:** 1 failure / 5 runs = 20% failure rate (the failure was the latest run)
- **bravo74:** 1 failure / 5 runs = 20% failure rate  
- **kilo57:** 2 failures / 5 runs = 40% failure rate (consecutive retries of same step)
- **juliet62:** 1 failure / 5 runs = 20% failure rate

All failures occur at the PR review phase. Earlier phases (create-epic, implement-epic) succeed reliably.

---

## 3. Root Cause Analysis

### 3.1 Immediate Cause

The `review-epic-prs` workflow requires the orchestrator to delegate to a subagent (Code-Reviewer, Github-Expert, or Developer) via the opencode `Task` tool. When this delegation happens:

1. The orchestrator calls `Task` to spin up a subagent
2. The `opencode run` client **blocks silently** waiting for the server-side subagent to finish
3. During this blocking period, **no client stdout is produced**
4. The server-side subagent performs work but produces no log file output
5. The server process's `/proc/<pid>/io` write_bytes **initially increases** (the watchdog correctly detects this), but after the subagent finishes its LLM+tool work and begins waiting for an API response or stalls, **write_bytes stops increasing**
6. Both client output and server I/O are now stale → the idle watchdog fires the 15-minute timer → SIGTERM

### 3.2 Why Review Steps Specifically

The `pr-approval-and-merge` assignment is the most complex delegation in the 4-step sequence:
- It requires multi-phase work: CI verification, code review, comment resolution, approval, merge
- It involves external waits (CI checks completing, API calls)
- The subagent may need to fetch remote workflow assignment definitions (HTTP fetch)
- The subagent performs many sequential GitHub API calls that can individually take 10-30s

The implementation and creation steps (Steps 1 and epic creation) are simpler and complete within the idle window.

### 3.3 Why the Watchdog Kills Prematurely

The current watchdog (Issue #22 in workflow-issues-and-fixes.md was marked "Complete") uses a clever `/proc/<pid>/io` check to avoid premature kills during active subagent work. **However**, the fix only works when the server process is actively performing I/O (disk writes from SQLite, LLM response streaming, etc.). When the subagent is:

- Waiting for an upstream LLM API response (network I/O, not disk write_bytes)
- Waiting for GitHub API rate-limit cooldown
- In a "thinking" pause between tool calls
- Blocked on a slow `gh pr checks --watch` operation

...then `write_bytes` does NOT increase, and the watchdog interprets this as idleness.

**The fundamental issue:** `/proc/<pid>/io` write_bytes is a good proxy for "doing work" but NOT a perfect one. Network I/O (read_bytes from API responses, socket reads) is not reflected in write_bytes when the data is processed in memory without hitting disk.

---

## 4. Solutions with Pros/Cons

### Solution A: Increase IDLE_TIMEOUT_SECS to 30-45 Minutes

**Change:** Set `IDLE_TIMEOUT_SECS=2700` (45 min) in `run_opencode_prompt.sh`.

| Pros | Cons |
|------|------|
| Simplest possible fix — one line change | Doesn't fix the root cause; merely raises the bar |
| Immediately unblocks current failures | Truly stuck agents waste 45 min of runner time before kill |
| No behavior change for healthy runs | If subagent tasks grow longer, will need increasing again |
| Low risk of regressions | Higher Actions minute consumption on failures |

**Estimated impact:** Would have prevented 4/5 of the observed failures (juliet62's 33-min stall would still need >33m).

---

### Solution B: Add `/proc/<pid>/io` read_bytes Monitoring

**Change:** Extend `_read_server_write_bytes()` to also track `read_bytes` from `/proc/<pid>/io`. Consider the server active if **either** read_bytes or write_bytes changes.

| Pros | Cons |
|------|------|
| Catches network I/O activity (API responses being read) | Adds complexity to the watchdog loop |
| More accurate activity detection | read_bytes may spike from unrelated I/O (log reading, etc.) |
| Still uses the proven /proc/io mechanism | Doesn't help if agent is genuinely stuck (infinite wait) |
| Relatively small code change | May mask genuinely idle processes |

**Implementation:**

```bash
_read_server_io_bytes() {
    local pidfile="$SERVER_PIDFILE"
    if [[ -f "$pidfile" ]]; then
        local spid
        spid=$(cat "$pidfile" 2>/dev/null)
        if [[ -n "$spid" && -f "/proc/$spid/io" ]]; then
            awk '/^(read|write)_bytes:/{sum+=$2} END{print sum}' "/proc/$spid/io" 2>/dev/null
            return
        fi
    fi
    echo ""
}
```

---

### Solution C: Heartbeat File Protocol Between Server and Watchdog

**Change:** Have the opencode server (or a wrapper) periodically write a timestamp to a heartbeat file (e.g., `/tmp/opencode-heartbeat`). The watchdog checks this file's mtime instead of /proc/io.

| Pros | Cons |
|------|------|
| Definitive "I'm alive" signal from the process itself | Requires modifying opencode server behavior or wrapping it |
| Works regardless of I/O pattern | More moving parts / files to manage |
| Can be extended with status info (current agent, task) | opencode may not support custom heartbeat hooks |
| Independent of /proc filesystem quirks | If opencode itself stalls, heartbeat stops = correct detection |

**Feasibility concern:** opencode is a third-party CLI tool. Adding heartbeat output requires either a wrapper script that polls the process, or modifications to opencode itself (unlikely).

---

### Solution D: Monitor All Child Processes, Not Just Server PID

**Change:** Instead of checking only the server PID's I/O, check all descendant processes of the opencode process tree (subagent runtimes, tool executors, shell commands).

| Pros | Cons |
|------|------|
| Catches activity from spawned tool processes | Complex — need to walk /proc/<pid>/task or /proc/<pid>/children |
| More comprehensive activity picture | Process tree may be ephemeral (short-lived children) |
| Would detect `gh` CLI calls, `curl`, etc. in subagents | Performance overhead of scanning many PIDs every 30s |
| Addresses the specific failure mode observed | Linux-specific; fragile if process structure changes |

**Implementation sketch:**

```bash
_read_tree_write_bytes() {
    local root_pid="$1"
    local total=0
    for pid in $(pgrep -P "$root_pid" 2>/dev/null) "$root_pid"; do
        if [[ -f "/proc/$pid/io" ]]; then
            local wb
            wb=$(awk '/^write_bytes:/{print $2}' "/proc/$pid/io" 2>/dev/null)
            total=$(( total + ${wb:-0} ))
        fi
    done
    echo "$total"
}
```

---

### Solution E: Subagent Progress Streaming (Structured Output)

**Change:** Configure opencode to emit periodic structured status lines during subagent execution (e.g., via `--format json` or a custom log sink). The watchdog looks for these status lines in the output log instead of relying on raw file timestamps.

| Pros | Cons |
|------|------|
| Most accurate — watchdog sees actual agent progress | Requires opencode to support progress callbacks/streaming |
| Enables richer diagnostics (which subagent, which tool) | Format-dependent; may break with opencode updates |
| Could integrate with CI annotations | Significantly more complex implementation |
| Would enable better timeout tuning per-phase | May not be available in current opencode version |

**Feasibility concern:** opencode 1.2.24 with `--print-logs` already emits some output. The issue is that server-side subagent work is NOT printed to the client's stdout. This would require opencode architectural changes.

---

### Solution F: Tiered Timeout (Phase-Aware Watchdog)

**Change:** Pass the orchestration phase/step as an environment variable to the watchdog. Use longer timeouts for known-slow phases (PR review) and shorter timeouts for fast phases (labeling, commenting).

| Pros | Cons |
|------|------|
| Tailored behavior per orchestration stage | Requires phase detection logic in the workflow YAML |
| Short timeout still catches genuine stuck agents | Adds coupling between workflow steps and watchdog |
| Long timeout only applies where needed | Doesn't scale well as phases change |
| Reduces wasted runner time compared to Solution A | More configuration to maintain |

**Implementation:**

```yaml
env:
  IDLE_TIMEOUT_SECS: ${{ contains(github.event.label.name, 'epic-implemented') && '2700' || '900' }}
```

---

### Solution G: Combined Approach (Recommended)

Apply multiple solutions in layers:

1. **Immediate:** Increase `IDLE_TIMEOUT_SECS` from 900 to 1800 (30 min) — **Solution A**
2. **Short-term:** Add read_bytes monitoring alongside write_bytes — **Solution B**  
3. **Short-term:** Monitor full process tree instead of just server PID — **Solution D**
4. **Medium-term:** Implement tiered timeouts by orchestration phase — **Solution F**

| Pros | Cons |
|------|------|
| Defense in depth — each layer compensates for others' gaps | More total changes to implement and test |
| Immediate unblock + structural improvement | Incrementally more complex watchdog |
| Graduated rollout reduces risk | Requires testing each layer's interaction |

---

## 5. Recommendation

**Implement Solution G (Combined Approach)** in two phases:

### Phase 1 — Immediate Unblock (deploy today)

1. **Increase `IDLE_TIMEOUT_SECS` to 1800 (30 min)**  
   - One-line change in `run_opencode_prompt.sh`
   - Immediately prevents the 4/5 failures seen today
   - Reasoning: The PR review subagent has server `write_bytes` activity for the first ~5 minutes in observed runs. After that, a 15-min idle window fires. A 30-min window gives the subagent 25+ additional minutes to complete, which covers the observed range

2. **Add `read_bytes` to the I/O activity check (Solution B)**
   - Change `_read_server_write_bytes()` to sum both read and write bytes
   - Catches network-heavy work (API responses) that write_bytes misses
   - Small, testable change

### Phase 2 — Structural Hardening (next PR)

3. **Process tree I/O monitoring (Solution D)**
   - Monitor all child processes spawned by the opencode server
   - Catches `gh` CLI operations, `curl` fetches, etc. in subagents

4. **Tiered timeouts (Solution F)**
   - 15 min for simple phases (epic-ready, epic-reviewed)
   - 30 min for complex phases (epic-implemented → review-epic-prs)
   - Passed as env var from the workflow YAML based on the trigger label

### Why This Combination

- **Solution A** (increase timeout) is the minimum viable fix with zero risk
- **Solution B** (read_bytes) addresses the *specific* root cause: the watchdog misses network I/O activity
- **Solution D** (process tree) addresses the *structural* gap: subagent work happens in child processes not tracked by the current single-PID check
- **Solution F** (tiered timeouts) provides calibration: fast operations get tight watchdogs, slow operations get appropriate breathing room

### Why Not Other Solutions Alone

- **Solution C** (heartbeat file) is elegant but requires opencode changes we don't control
- **Solution E** (progress streaming) is ideal but blocked by opencode architecture limitations
- **Solution A alone** is a band-aid that will need raising again as orchestration grows more complex

---

## 6. Appendix: Raw Log Signatures

### Signature of an Idle Timeout Kill

```
[watchdog] client output idle XXs, server I/O active (write_bytes=NNNNN) — subagent likely running
...
[watchdog] client output idle XXs, server I/O active (write_bytes=NNNNN) — subagent likely running
...
<silence for 15 minutes>
...
##[error]opencode idle for 15m (no output from client or server); terminating
opencode exit code: 143
=== server log tail (last 80 lines before idle kill) ===
##[error]Process completed with exit code 1.
```

### Common Last Orchestrator Output Before Stall

```
"Let me delegate to the `code-reviewer` agent with the full context..."
"Now I have the `pr-approval-and-merge` workflow assignment..."
"Let me delegate to a specialist agent..."
✓ Check CI status for PR #N <Agent>
• PR #N approval and merge Github-Expert Agent
```

The orchestrator is consistently stalling at the moment it dispatches a subagent via the `Task` tool for PR review/merge operations.

---

## 7. Future Enhancement: Separate Read vs. Write Timeout Windows

### Motivation

Phase 1 sums `read_bytes + write_bytes` into a single I/O activity signal. This solved the immediate problem — network-heavy API reads were invisible to the write-only watchdog. However, treating reads and writes as equivalent loses diagnostic signal and prevents more nuanced idle detection.

`read_bytes` and `write_bytes` carry different semantic meaning:

| Metric | Typical activity | What it signals |
|--------|-----------------|-----------------|
| `write_bytes` increasing | Database writes, file output, log emission, tool results | Active *progress* — the process is producing output |
| `read_bytes` increasing | API response ingestion, model token streaming, file reads | Active *input* — the process is receiving data |
| `read_bytes` only (writes flat) | Polling a queue, retrying an API, reading logs in a loop | *Possible stall* — data is being consumed but nothing is being produced |
| `write_bytes` only (reads flat) | Dumping cached data, flushing buffers | Normal tail-end of a task |

### Implementation

Track `read_bytes` and `write_bytes` as separate variables with independent "last changed" timestamps:

```bash
_read_server_io_split() {
    local pidfile="$SERVER_PIDFILE"
    if [[ -f "$pidfile" ]]; then
        local spid
        spid=$(cat "$pidfile" 2>/dev/null)
        if [[ -n "$spid" && -f "/proc/$spid/io" ]]; then
            # Output "read_bytes write_bytes" as two space-separated values
            awk '/^read_bytes:/{r=$2} /^write_bytes:/{w=$2} END{print r, w}' \
                "/proc/$spid/io" 2>/dev/null
            return
        fi
    fi
    echo ""
}
```

Watchdog loop changes:

```bash
# Read split counters
read _cur_read _cur_write <<< "$(_read_server_io_split)"

# Detect read activity
if [[ -n "$_cur_read" && -n "$_prev_read" && "$_cur_read" != "$_prev_read" ]]; then
    read_active=true
    _last_read_time=$now
fi

# Detect write activity
if [[ -n "$_cur_write" && -n "$_prev_write" && "$_cur_write" != "$_prev_write" ]]; then
    write_active=true
    _last_write_time=$now
fi

_prev_read="$_cur_read"
_prev_write="$_cur_write"

# Tiered idle detection:
#   - If writes are active → definitely not idle (hard evidence of progress)
#   - If reads-only active → grant a separate, shorter grace window
#   - If neither active → standard idle timeout applies
read_only_idle=$(( now - _last_write_time ))

if [[ "$write_active" == true ]]; then
    server_idle=0
elif [[ "$read_active" == true && $read_only_idle -lt $READ_ONLY_GRACE_SECS ]]; then
    # Reads happening but no writes — give it a grace period before
    # treating as idle (may be ingesting a large API response)
    server_idle=0
elif [[ -n "$_cur_read" ]]; then
    server_idle=$(( now - _last_write_time ))
else
    server_idle=$server_log_idle
fi
```

### Advantages

1. **Read-only stall detection** — If `read_bytes` is climbing but `write_bytes` hasn't moved for `READ_ONLY_GRACE_SECS` (e.g. 10 minutes), the process may be stuck in a polling loop or infinite retry. The current summed approach masks this entirely — as long as *something* changes, the watchdog stays quiet. Separate tracking enables a "reads without writes" alarm.

2. **Diagnostic richness** — Debug log lines can show `read=X write=Y` instead of `io=Z`, enabling forensic analysis to distinguish between:
   - API-bound phases (reads >> writes): subagent ingesting model responses
   - Compute-bound phases (writes >> reads): generating code, running tools
   - Balanced I/O: normal productive execution
   - Read-only flat-line: potential hang during API retry loops

3. **Tunable grace windows** — Different timeout thresholds for different I/O patterns:
   - `WRITE_ACTIVE_TIMEOUT=1800` (30 min) — generous window when writes confirm progress
   - `READ_ONLY_GRACE_SECS=600` (10 min) — shorter leash when only reads are happening (likely waiting on external service, which should have its own timeout)
   - This prevents a process that's stuck polling an unresponsive API from consuming 30 minutes of CI time

4. **False-positive reduction** — The current summed approach can be fooled by background `read_bytes` from unrelated I/O (e.g., systemd journal reads, inotify, `/proc` self-reads). Write activity is a much stronger signal of genuine progress. Separating them lets the watchdog weight writes more heavily.

### Trade-offs

| Advantage | Cost |
|-----------|------|
| Catches read-only stalls that the sum approach misses | Adds ~15 lines to the watchdog loop |
| Better forensic data in debug logs | Two more tracking variables to maintain |
| Tunable grace window for read-only phases | One more constant (`READ_ONLY_GRACE_SECS`) to configure |
| Stronger progress signal from write activity | Slightly more complex idle-decision logic |

### Recommendation

Implement as a **Phase 2 enhancement** after Phase 1 has been validated in production. The current summed approach is correct for the immediate fix — it solved the root cause (invisible network reads). Separate tracking is an optimization that becomes valuable once we have baseline data showing the distribution of read-only vs. write-active phases in real orchestration runs.

