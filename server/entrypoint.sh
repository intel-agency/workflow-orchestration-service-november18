#!/usr/bin/env bash
set -euo pipefail

# Container PID 1 wrapper for the standalone orchestration-server image.
# Invokes scripts/start-opencode-server.sh to start opencode serve in the
# background, keeps PID 1 alive in the foreground, and forwards SIGTERM/SIGINT
# to the server process via the pidfile so `docker stop` shuts down cleanly.

OPENCODE_SERVER_PIDFILE="${OPENCODE_SERVER_PIDFILE:-/tmp/opencode-serve.pid}"

if [[ -z "${ZHIPU_API_KEY:-}" ]]; then
    echo "::error::ZHIPU_API_KEY is not set — this is required for opencode to call the ZhipuAI model API" >&2
    echo "::error::Set ZHIPU_API_KEY as an environment variable or in the .env file before starting the container" >&2
    exit 1
fi

if [[ -z "${GH_ORCHESTRATION_AGENT_TOKEN:-}" ]]; then
    echo "::error::GH_ORCHESTRATION_AGENT_TOKEN is not set — orchestrator execution requires this token" >&2
    echo "::error::Configure it as an org or repo secret with scopes: repo, workflow, project, read:org" >&2
    exit 1
fi

# Run the bootstrapper — exits 0 only when opencode serve is ready on its port.
bash scripts/start-opencode-server.sh

server_pid="$(cat "$OPENCODE_SERVER_PIDFILE")"

_shutdown() {
    echo "[entrypoint] received shutdown signal; forwarding to opencode serve (pid $server_pid)"
    kill -TERM "$server_pid" 2>/dev/null || true
    local i=0
    while kill -0 "$server_pid" 2>/dev/null && [[ $i -lt 30 ]]; do
        sleep 1
        i=$(( i + 1 ))
    done
    kill -9 "$server_pid" 2>/dev/null || true
    exit 0
}

trap _shutdown TERM INT

echo "[entrypoint] opencode serve running (pid $server_pid); container is ready"

# Keep PID 1 alive. sleep in a subshell so SIGTERM interrupts the wait
# and fires the trap immediately rather than waiting for the sleep to finish.
while kill -0 "$server_pid" 2>/dev/null; do
    sleep 1 &
    wait $!
done

echo "[entrypoint] opencode serve process exited unexpectedly; shutting down container" >&2
exit 1
