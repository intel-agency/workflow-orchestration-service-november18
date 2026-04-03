#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 -f <file> | -p <prompt> [-a <url>] [-u <user>] [-P <pass>] [-d <dir>] [-l <log-level>] [-L]" >&2
    echo "  -f <file>       Read prompt from file" >&2
    echo "  -p <prompt>     Use prompt string directly" >&2
    echo "  -a <url>        Attach to a running opencode server (e.g. https://host:4096)" >&2
    echo "  -u <user>       Basic auth username (prefer env var OPENCODE_AUTH_USER)" >&2
    echo "  -P <pass>       Basic auth password (prefer env var OPENCODE_AUTH_PASS)" >&2
    echo "  -d <dir>        Working directory on the server (used with -a)" >&2
    echo "  -l <log-level>  opencode log level (DEBUG|INFO|WARN|ERROR), default: INFO" >&2
    echo "  -L              Enable --print-logs (disabled by default)" >&2
    echo "" >&2
    echo "  Credentials are resolved in order: flags > env vars OPENCODE_AUTH_USER / OPENCODE_AUTH_PASS" >&2
    exit 1
}

prompt=""
attach_url=""
auth_user="${OPENCODE_AUTH_USER:-}"   # prefer env vars — flags override if provided
auth_pass="${OPENCODE_AUTH_PASS:-}"
work_dir=""
log_level="INFO"
print_logs="--print-logs"
format_flag=()

while getopts ":f:p:a:u:P:d:l:L" opt; do
    case $opt in
        f) prompt=$(cat "$OPTARG") ;;
        p) prompt="$OPTARG" ;;
        a) attach_url="$OPTARG" ;;
        u) auth_user="$OPTARG" ;;
        P) auth_pass="$OPTARG" ;;
        d) work_dir="$OPTARG" ;;
        l) log_level="$OPTARG" ;;
        L) print_logs="--print-logs" ;;
        *) usage ;;
    esac
done

if [ -z "$prompt" ]; then
    usage
fi

if [[ -z "${ZHIPU_API_KEY:-}" ]]; then
    echo "::error::ZHIPU_API_KEY is not set" >&2
    exit 1
fi

if [[ -z "${KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY:-}" ]]; then
    echo "::error::KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY is not set" >&2
    exit 1
fi

# Authenticate GitHub CLI and set MCP-compatible token.
#
# Orchestrator runs require GH_ORCHESTRATION_AGENT_TOKEN — an org-level PAT with
# scopes: repo, workflow, project, read:org. No fallback to GITHUB_TOKEN.
if [[ -z "${GH_ORCHESTRATION_AGENT_TOKEN:-}" ]]; then
    echo "::error::GH_ORCHESTRATION_AGENT_TOKEN is not set — orchestrator execution requires this token" >&2
    echo "::error::Configure it as an org or repo secret with scopes: repo, workflow, project, read:org" >&2
    exit 1
fi
echo "Using GH_ORCHESTRATION_AGENT_TOKEN for authentication"

# Export under all names that tools (gh CLI, MCP servers, opencode) may read.
export GH_TOKEN="${GH_ORCHESTRATION_AGENT_TOKEN}"
export GITHUB_TOKEN="${GH_ORCHESTRATION_AGENT_TOKEN}"
export GITHUB_PERSONAL_ACCESS_TOKEN="${GH_ORCHESTRATION_AGENT_TOKEN}"
export OPENCODE_EXPERIMENTAL=1

# Validate the token is accepted by the API and check required scopes.
# --include surfaces response headers; X-OAuth-Scopes lists granted scopes.
# Use ||true to prevent set -e from exiting before we can capture/report the error.
_api_response=$(gh api rate_limit --include 2>&1) || true
if ! echo "${_api_response}" | grep -q '^HTTP'; then
    echo "::error::gh CLI token validation failed — unexpected response:" >&2
    echo "${_api_response}" >&2
    exit 1
fi
echo "gh CLI token validation succeeded"

_granted_scopes=$(echo "${_api_response}" | grep -i '^X-OAuth-Scopes:' | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')
echo "Granted OAuth scopes: ${_granted_scopes:-<none>}"

# Tokenize the comma-space delimited scope string into an array.
IFS=', ' read -ra _scope_tokens <<< "${_granted_scopes}"

_required_scopes=("repo" "workflow" "project" "read:org")
_missing=()
for _scope in "${_required_scopes[@]}"; do
    _found=false
    for _token in "${_scope_tokens[@]}"; do
        [[ "${_token}" == "${_scope}" ]] && { _found=true; break; }
    done
    [[ "${_found}" == false ]] && _missing+=("${_scope}")
done

if [[ ${#_missing[@]} -gt 0 ]]; then
    echo "::error::GH_ORCHESTRATION_AGENT_TOKEN is missing required scopes: ${_missing[*]}" >&2
    echo "::error::Required: ${_required_scopes[*]}  |  Granted: ${_granted_scopes}" >&2
    exit 1
fi
echo "All required scopes verified: ${_required_scopes[*]}"

# Embed basic auth credentials into the attach URL if provided
if [[ -n "$attach_url" && -n "$auth_user" && -n "$auth_pass" ]]; then
    # Warn if credentials are being sent over plain HTTP
    if [[ "$attach_url" == http://* ]]; then
        echo "::warning::Basic auth credentials over http:// are sent in plaintext — use https://" >&2
    fi
    scheme="${attach_url%%://*}"
    rest="${attach_url#*://}"
    attach_url="${scheme}://${auth_user}:${auth_pass}@${rest}"
elif [[ ( -n "$auth_user" || -n "$auth_pass" ) && -z "$attach_url" ]]; then
    echo "::error::OPENCODE_AUTH_USER/PASS (or -u/-P) require -a <url>" >&2
    exit 1
fi

# When DEBUG_ORCHESTRATOR is set, crank up diagnostics
if [[ "${DEBUG_ORCHESTRATOR:-}" == "true" ]]; then
    log_level="DEBUG"
    format_flag=(--format json)
    echo "[debug] DEBUG_ORCHESTRATOR=true — enabling verbose output"
fi

# Build opencode args — optional flags only included when set
opencode_args=(
    run
    --model zai-coding-plan/glm-5
    --agent orchestrator
    --log-level "$log_level"
    --thinking
)
[[ -n "$print_logs"  ]] && opencode_args+=(--print-logs)
[[ ${#format_flag[@]} -gt 0 ]] && opencode_args+=("${format_flag[@]}")
[[ -n "$attach_url" ]] && opencode_args+=(--attach "$attach_url")
[[ -n "$work_dir"   ]] && opencode_args+=(--dir    "$work_dir")
opencode_args+=("$prompt")

# Always show concise info; verbose diagnostics only with DEBUG_ORCHESTRATOR
echo "Prompt: ${#prompt} chars | attach: ${attach_url:-local} | log-level: ${log_level}"
if [[ "${DEBUG_ORCHESTRATOR:-}" == "true" ]]; then
    echo "=== run_opencode_prompt.sh diagnostics ==="
    echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "PWD: $(pwd)"
    echo "opencode binary: $(which opencode 2>&1 || echo 'NOT FOUND')"
    echo "opencode version: $(opencode --version 2>&1 || echo 'UNKNOWN')"
    echo "Prompt first 200 chars: ${prompt:0:200}"
    echo "Prompt last 200 chars: ${prompt: -200}"
    echo "opencode args (excluding prompt):"
    for i in "${!opencode_args[@]}"; do
      if [[ $i -lt $(( ${#opencode_args[@]} - 1 )) ]]; then
        echo "  [$i] ${opencode_args[$i]}"
      else
        echo "  [$i] <prompt content, ${#prompt} chars>"
      fi
    done
    echo "=== end diagnostics ==="
fi

echo "Starting opencode at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Idle watchdog: kill opencode if it produces no output for IDLE_TIMEOUT_SECS.
# An active agent continuously emits tool calls, reasoning, etc. Sustained silence
# means it's stuck. This replaces a hard wall-clock timeout so long-running but
# actively-working agents aren't killed prematurely.
#
# IMPORTANT: When the orchestrator delegates to a subagent via the Task tool,
# the `opencode run` client blocks silently waiting for the server-side subagent
# to finish. During this time the client produces NO stdout, and the server log
# file (stdout/stderr of `opencode serve`) is NOT actively written either — it
# only contains startup messages. However the server PROCESS is busy (database
# writes, LLM API calls, tool execution). We detect this by reading the server
# process's cumulative I/O counters from /proc/<pid>/io.
#
# We track read_bytes and write_bytes SEPARATELY with different semantics:
#   - write_bytes changing → strong signal of genuine progress (DB writes, file
#     output, tool results). Resets the idle timer fully.
#   - read_bytes changing (but writes flat) → weaker signal. The process may be
#     ingesting API responses, streaming model tokens, or just background socket
#     reads. Grants a shorter READ_ONLY_GRACE period before treating as idle.
#   - Neither changing → truly idle.
#
# This avoids two failure modes:
#   1. write_bytes-only monitoring kills subagents doing network-heavy work
#      (PR reviews, API calls) where write_bytes plateaus for >15 min.
#   2. Summing read+write bytes makes idle detection impossible because
#      background socket reads increment read_bytes perpetually.
IDLE_TIMEOUT_SECS=900           # 15 minutes of total I/O silence → kill
READ_ONLY_GRACE_SECS=1200       # 20 minutes with reads-only (no writes) → kill
HARD_CEILING_SECS=5400  # 90-minute absolute safety net
OUTPUT_LOG=$(mktemp /tmp/opencode-output.XXXXXX)
SERVER_LOG="${OPENCODE_SERVER_LOG:-/tmp/opencode-serve.log}"
SERVER_PIDFILE="${OPENCODE_SERVER_PIDFILE:-/tmp/opencode-serve.pid}"
echo "Output log: $OUTPUT_LOG"
echo "Server log: $SERVER_LOG"
echo "Server PID file: $SERVER_PIDFILE (monitored for process I/O activity)"

set +e

# Start opencode with output redirected to a log file
echo "Launching: opencode ${opencode_args[*]:0:$(( ${#opencode_args[@]} - 1 ))} <prompt>"
stdbuf -oL -eL opencode "${opencode_args[@]}" > "$OUTPUT_LOG" 2>&1 &
OPENCODE_PID=$!
echo "opencode PID: $OPENCODE_PID"

# Verify the process actually started
sleep 1
if ! kill -0 "$OPENCODE_PID" 2>/dev/null; then
    echo "::error::opencode process $OPENCODE_PID died immediately after launch"
    echo "=== Output log contents ==="
    cat "$OUTPUT_LOG"
    echo "=== end output log ==="
    rm -f "$OUTPUT_LOG"
    exit 1
fi
echo "opencode process $OPENCODE_PID confirmed running after 1s"

# Stream the client log to stdout in real-time so CI can see it.
# Prefix subagent delegation events (•✓) and tool operations (→%⚙) so they
# are visually distinct from [server] / [watchdog] lines in the CI log.
# Use a FIFO to separate the 'tail -f' PID from the sed pipeline so we can kill
# 'tail -f' explicitly during cleanup. Without this, killing just the pipeline end
# (sed / TAIL_PID) leaves 'tail -f' orphaned with no EOF signal, holding the
# devcontainer exec cgroup open indefinitely. (Same pattern as server log tailer.)
OUTPUT_TAIL_RAW_PID=""
_output_pipe=$(mktemp -u /tmp/opencode-output-tail.XXXXXX)
mkfifo "$_output_pipe"
tail -f "$OUTPUT_LOG" > "$_output_pipe" 2>/dev/null &
OUTPUT_TAIL_RAW_PID=$!
sed -u -e '/[•✓]/s/^/[subagent] /' -e '/[→%⚙]/s/^/[agent] /' < "$_output_pipe" &
TAIL_PID=$!
rm -f "$_output_pipe"  # safe to remove after both ends are open

# Stream server-side subagent traces to CI stdout.
# The server runs at DEBUG with --print-logs, capturing subagent tool calls,
# session creation, and LLM requests. We tail it with a prefix so CI output
# clearly distinguishes server-side subagent activity from client output.
# We track the server log position so we only show NEW lines (not startup noise).
SERVER_TAIL_PID=""
SERVER_TAIL_RAW_PID=""  # PID of the 'tail -f' process (must be killed to avoid orphan)
# Patterns suppressed from server log streaming — these are per-token / init noise:
#   service=bus                  → one line per LLM token delta (message.part.delta/updated)
#   service=tool.registry        → tool init/teardown chatter on every session loop
#   service=permission           → permission ruleset evaluation (very verbose JSON blobs)
#   service=bash-tool            → bash shell initialisation line
#   service=provider             → provider init/found lines at startup (~9 lines per run)
#   service=lsp                  → LSP "touching file" on every file read
#   service=file.time            → file read timing per file access
#   service=snapshot             → snapshot hash lines emitted every LLM step
#   cwd=.*tracking               → follow-on cwd line paired with service=snapshot
#   service=session.processor    → process tick emitted every LLM step
#   service=session.compaction   → pruning log on compaction
#   service=session.prompt status= → resolveTools started/completed per step (keep step=N loop and exiting loop)
#   service=format               → formatter availability check (~27 lines per file write)
#   service=vcs                  → branch change tracking line per checkout
#   service=storage              → storage migration lines at startup
#   ruleset=[{"permission"       → terminal line of multi-line bash permission pre-check blob (huge JSON array)
#   action={"permission"         → terminal line of multi-line bash permission post-check blob
#   mcp stderr: .*running on     → MCP server startup "running on stdio" line
#   service=llm .*stream$        → LLM stream start per session step (one per step; step=N loop line already tracks this)
#   session\.prompt step=.*loop$ → Session prompt loop iteration (covered by Thinking: + [subagent] lines)
#   mcp stderr:\s*$              → Blank mcp stderr flush lines (no content)
_SERVER_LOG_NOISE='service=bus |service=tool\.registry |service=permission |service=bash-tool |service=provider |service=lsp |service=file\.time |service=snapshot |cwd=.*tracking|service=session\.processor |service=session\.compaction |service=session\.prompt status=|service=format |service=vcs |service=storage |ruleset=\[\{"permission|action=\{"permission|mcp stderr: .*running on|service=llm .*stream$|session\.prompt step=.*loop$|mcp stderr:\s*$'
if [[ -f "$SERVER_LOG" ]]; then
    _server_log_start_lines=$(wc -l < "$SERVER_LOG" 2>/dev/null || echo 0)
    # Use a FIFO to separate the 'tail -f' PID from the filter pipeline so we can
    # kill 'tail -f' explicitly during cleanup. Without this, killing only the last
    # pipeline member (sed) leaves 'tail -f' orphaned: since the setsid server keeps
    # writing to the log file indefinitely, the orphaned 'tail -f' has no EOF signal
    # and holds the devcontainer exec session open forever.
    _server_log_pipe=$(mktemp -u /tmp/opencode-server-tail.XXXXXX)
    mkfifo "$_server_log_pipe"
    tail -f -n +$(( _server_log_start_lines + 1 )) "$SERVER_LOG" 2>/dev/null > "$_server_log_pipe" &
    SERVER_TAIL_RAW_PID=$!
    grep -Ev "$_SERVER_LOG_NOISE" < "$_server_log_pipe" | grep -v '^\s*$' | sed -u 's/^/[server] /' &
    SERVER_TAIL_PID=$!
    rm -f "$_server_log_pipe"  # safe to remove after both ends are open
    echo "Server log tailer started (tail pid ${SERVER_TAIL_RAW_PID} filter pid ${SERVER_TAIL_PID}), streaming from line $(( _server_log_start_lines + 1 ))"
else
    echo "Server log not found at ${SERVER_LOG} — server-side traces will not be streamed"
fi

START_TIME=$(date +%s)
IDLE_KILLED=0
_prev_server_read=""            # tracks server process read_bytes
_prev_server_write=""           # tracks server process write_bytes
_last_write_time=$START_TIME    # last time write_bytes was observed changing
_last_read_time=$START_TIME     # last time read_bytes was observed changing

# _read_server_io_split: read cumulative read_bytes and write_bytes from the
# server process. Outputs "read_bytes write_bytes" (space-separated) via stdout;
# empty string if unavailable.
_read_server_io_split() {
    local pidfile="$SERVER_PIDFILE"
    if [[ -f "$pidfile" ]]; then
        local spid
        spid=$(cat "$pidfile" 2>/dev/null)
        if [[ -n "$spid" && -f "/proc/$spid/io" ]]; then
            awk '/^read_bytes:/{r=$2} /^write_bytes:/{w=$2} END{print r, w}' \
                "/proc/$spid/io" 2>/dev/null
            return
        fi
    fi
    echo ""
}

# Watchdog loop: check output freshness every 30 seconds
while kill -0 "$OPENCODE_PID" 2>/dev/null; do
    sleep 30

    # Hard ceiling safety net
    now=$(date +%s)
    elapsed=$(( now - START_TIME ))

    # Watchdog status — concise by default, verbose when debugging.
    log_size=$(wc -c < "$OUTPUT_LOG" 2>/dev/null || echo 0)
    log_lines=$(wc -l < "$OUTPUT_LOG" 2>/dev/null || echo 0)
    output_last_mod=$(stat -c %Y "$OUTPUT_LOG" 2>/dev/null || echo "$now")
    output_idle=$(( now - output_last_mod ))

    # --- Server activity detection (split read/write tracking) ---
    # read_bytes and write_bytes are tracked independently. write_bytes is the
    # primary progress signal; read_bytes provides a weaker "still alive" hint
    # with a shorter grace period to avoid masking genuine stalls.
    write_active=false
    read_active=false
    _cur_server_read=""
    _cur_server_write=""
    _io_split=$(_read_server_io_split)
    if [[ -n "$_io_split" ]]; then
        read _cur_server_read _cur_server_write <<< "$_io_split"

        # Detect write activity (strong progress signal)
        if [[ -n "$_prev_server_write" && "$_cur_server_write" != "$_prev_server_write" ]]; then
            write_active=true
            _last_write_time=$now
        fi

        # Detect read activity (weaker "alive" signal)
        if [[ -n "$_prev_server_read" && "$_cur_server_read" != "$_prev_server_read" ]]; then
            read_active=true
            _last_read_time=$now
        fi

        _prev_server_read="$_cur_server_read"
        _prev_server_write="$_cur_server_write"
    fi

    # Server log mtime as a secondary signal (only relevant when /proc/io unavailable)
    if [[ -f "$SERVER_LOG" ]]; then
        server_last_mod=$(stat -c %Y "$SERVER_LOG" 2>/dev/null || echo "$now")
        server_log_idle=$(( now - server_last_mod ))
    else
        server_log_idle=$output_idle
    fi

    # Determine effective server idle time using tiered read/write logic:
    #   - write_bytes active → definitely not idle (strong progress signal)
    #   - read_bytes active but writes flat → grant READ_ONLY_GRACE period
    #   - neither active → standard idle timeout (IDLE_TIMEOUT_SECS)
    #   - /proc/io unavailable → fall back to server log mtime
    write_idle=$(( now - _last_write_time ))
    read_idle=$(( now - _last_read_time ))
    server_io_active=false

    if [[ "$write_active" == true ]]; then
        # Writes happening → strong progress signal, not idle
        server_idle=0
        server_io_active=true
    elif [[ "$read_active" == true && $write_idle -lt $READ_ONLY_GRACE_SECS ]]; then
        # Reads happening, writes paused but within grace → still alive
        server_idle=0
        server_io_active=true
    elif [[ -n "$_cur_server_write" ]]; then
        # /proc/io is available but no qualifying activity this interval.
        # If reads are active but grace expired, use write_idle as the measure.
        # If neither active, use whichever has been idle longer.
        server_idle=$write_idle
    else
        # /proc/io not available at all — fall back to log mtime
        server_idle=$server_log_idle
    fi

    # The process is only truly idle when BOTH client output is stale
    # AND the server shows no activity.
    if [[ $output_idle -le $server_idle ]]; then
        idle=$output_idle
    else
        idle=$server_idle
    fi

    if [[ "${DEBUG_ORCHESTRATOR:-}" == "true" ]]; then
        echo "[watchdog] elapsed=${elapsed}s output_idle=${output_idle}s server_idle=${server_idle}s write_active=${write_active} read_active=${read_active} effective_idle=${idle}s log_size=${log_size}b log_lines=${log_lines} pid=$OPENCODE_PID read_bytes=${_cur_server_read:-n/a} write_bytes=${_cur_server_write:-n/a} write_idle=${write_idle:-n/a}s read_idle=${read_idle:-n/a}s"
    elif [[ $output_idle -ge 60 && "$server_io_active" == true ]]; then
        # Emit a brief note when client output is stale but server is active
        # (i.e. subagent delegation in progress) so CI isn't silent for minutes
        if [[ "$write_active" == true ]]; then
            echo "[watchdog] client output idle ${output_idle}s, server write I/O active (write_bytes=${_cur_server_write}) — subagent likely running"
        else
            echo "[watchdog] client output idle ${output_idle}s, server read I/O active (read_bytes=${_cur_server_read}, write_idle=${write_idle}s/${READ_ONLY_GRACE_SECS}s grace) — subagent likely running"
        fi
        # Surface the most recent server log activity in debug mode only.
        # (In normal mode, [subagent] prefixes on the client stream already
        # provide sufficient progress visibility.)
        if [[ "${DEBUG_ORCHESTRATOR:-}" == "true" && -f "$SERVER_LOG" ]]; then
            _recent=$(tail -20 "$SERVER_LOG" 2>/dev/null | grep -Ev "$_SERVER_LOG_NOISE" | grep -v '^$' | tail -3)
            if [[ -n "$_recent" ]]; then
                echo "[watchdog] recent server activity:"
                echo "$_recent" | sed 's/^/  | /'
            fi
        fi
    fi

    if [[ $elapsed -ge $HARD_CEILING_SECS ]]; then
        echo ""
        echo "::error::opencode hit ${HARD_CEILING_SECS}s hard ceiling; terminating"
        kill "$OPENCODE_PID" 2>/dev/null
        # Escalate to SIGKILL if SIGTERM doesn't work within 10s
        sleep 10
        if kill -0 "$OPENCODE_PID" 2>/dev/null; then
            echo "::warning::opencode did not exit after SIGTERM; sending SIGKILL"
            kill -9 "$OPENCODE_PID" 2>/dev/null
        fi
        IDLE_KILLED=1
        break
    fi

    # Idle detection: only trigger when BOTH client output and server are stale
    if [[ $idle -ge $IDLE_TIMEOUT_SECS ]]; then
        echo ""
        echo "::error::opencode idle for $(( idle / 60 ))m (no output from client or server); terminating"
        kill "$OPENCODE_PID" 2>/dev/null
        # Escalate to SIGKILL if SIGTERM doesn't work within 10s
        sleep 10
        if kill -0 "$OPENCODE_PID" 2>/dev/null; then
            echo "::warning::opencode did not exit after SIGTERM; sending SIGKILL"
            kill -9 "$OPENCODE_PID" 2>/dev/null
        fi
        IDLE_KILLED=1
        break
    fi
done

wait "$OPENCODE_PID" 2>/dev/null
OPENCODE_EXIT=$?
# Stop the client output tailer — must kill 'tail -f' (OUTPUT_TAIL_RAW_PID) explicitly.
# Killing only the filter pipeline end (TAIL_PID / sed) leaves 'tail -f' orphaned:
# the OUTPUT_LOG file only gets EOF when the opencode process exits, but after 'wait'
# it has already exited; however the FIFO has no writer once sed dies, so 'tail -f'
# would block-on-empty forever without an explicit kill.
if [[ -n "${OUTPUT_TAIL_RAW_PID:-}" ]]; then
    kill "$OUTPUT_TAIL_RAW_PID" 2>/dev/null
    wait "$OUTPUT_TAIL_RAW_PID" 2>/dev/null
fi
kill "$TAIL_PID" 2>/dev/null
wait "$TAIL_PID" 2>/dev/null
# Stop the server log tailer — must kill 'tail -f' (SERVER_TAIL_RAW_PID) explicitly.
# Killing only the filter pipeline end (SERVER_TAIL_PID / sed) leaves 'tail -f' orphaned:
# it has no EOF source since the setsid server log keeps growing, so it blocks forever
# and holds the devcontainer exec cgroup open.
if [[ -n "${SERVER_TAIL_RAW_PID:-}" ]]; then
    kill "$SERVER_TAIL_RAW_PID" 2>/dev/null
    wait "$SERVER_TAIL_RAW_PID" 2>/dev/null
fi
if [[ -n "${SERVER_TAIL_PID:-}" ]]; then
    kill "$SERVER_TAIL_PID" 2>/dev/null
    wait "$SERVER_TAIL_PID" 2>/dev/null
fi
# Final safety net: kill any remaining background jobs this script spawned
jobs -p | xargs -r kill 2>/dev/null || true
wait 2>/dev/null || true

echo ""
echo "opencode exit code: $OPENCODE_EXIT"

# When idle-killed, always dump server log tail (even without DEBUG_ORCHESTRATOR)
# so the CI log shows what the server was doing when the watchdog fired.
if [[ $IDLE_KILLED -eq 1 && -f "$SERVER_LOG" ]]; then
    echo "=== server log tail (last 80 lines before idle kill) ==="
    tail -n 80 "$SERVER_LOG" 2>/dev/null || true
    echo "=== end server log tail ==="
fi

if [[ "${DEBUG_ORCHESTRATOR:-}" == "true" ]]; then
    echo "=== opencode post-execution diagnostics ==="
    echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Idle killed: $IDLE_KILLED"
    echo "Output log file: $OUTPUT_LOG"
    if [[ -f "$OUTPUT_LOG" ]]; then
        echo "Output log size: $(wc -c < "$OUTPUT_LOG") bytes, $(wc -l < "$OUTPUT_LOG") lines"
        echo "=== Full output log contents ==="
        cat "$OUTPUT_LOG"
        echo ""
        echo "=== end output log ==="
    else
        echo "WARNING: Output log file $OUTPUT_LOG does not exist!"
    fi
    echo "Server log file: $SERVER_LOG"
    if [[ -f "$SERVER_LOG" ]]; then
        echo "Server log size: $(wc -c < "$SERVER_LOG") bytes, $(wc -l < "$SERVER_LOG") lines"
        echo "=== Full server log contents ==="
        cat "$SERVER_LOG"
        echo ""
        echo "=== end server log ==="
    else
        echo "Server log not found (opencode may be running in local mode)"
    fi
fi

rm -f "$OUTPUT_LOG"

set -e

# Exit non-zero on idle kill so the workflow properly reports failure.
# Previously this was `exit 0` which masked SIGTERM (143) as success,
# causing incomplete runs to appear as "succeeded" in GitHub Actions.
if [[ $IDLE_KILLED -eq 1 ]]; then
    exit 1
fi

exit ${OPENCODE_EXIT}
