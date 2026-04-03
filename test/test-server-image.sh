#!/usr/bin/env bash
set -euo pipefail

# Smoke test: build the orchestration-server image and verify the container
# remains up long enough for a health check on port 4096.
# Requires: docker

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE_NAME="orchestration-server"
CONTAINER_NAME="orchestration-server-smoke-$$"
HOST_PORT=14096

echo "=== Server Image Smoke Test ==="
echo ""

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is required but not found." >&2
    exit 1
fi

cleanup() {
    echo "--- Cleanup ---"
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm   "$CONTAINER_NAME" 2>/dev/null || true
    docker rmi  "$IMAGE_NAME"     2>/dev/null || true
}
trap cleanup EXIT

echo "--- Step 1: Building server image ---"
docker build -t "$IMAGE_NAME" -f "$REPO_ROOT/server/Dockerfile" "$REPO_ROOT"
echo ""

echo "--- Step 2: Starting server container (host port ${HOST_PORT} -> container port 4096) ---"
docker run -d --name "$CONTAINER_NAME" -p "${HOST_PORT}:4096" "$IMAGE_NAME"
echo ""

echo "--- Step 3: Waiting for server readiness on port ${HOST_PORT} (up to 60s) ---"
READY_TIMEOUT=60
READY_URL="http://127.0.0.1:${HOST_PORT}/"
deadline=$(( ${EPOCHSECONDS:-$(date +%s)} + READY_TIMEOUT ))
ready=0

while [[ ${EPOCHSECONDS:-$(date +%s)} -lt $deadline ]]; do
    if curl -s -o /dev/null --connect-timeout 2 "$READY_URL"; then
        ready=1
        break
    fi
    if ! docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" \
            --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
        echo "ERROR: Container exited before becoming ready." >&2
        docker logs "$CONTAINER_NAME" >&2 || true
        exit 1
    fi
    sleep 2
done

if [[ $ready -ne 1 ]]; then
    echo "ERROR: Timed out waiting ${READY_TIMEOUT}s for server on ${READY_URL}" >&2
    docker logs "$CONTAINER_NAME" >&2 || true
    exit 1
fi

echo "Server is ready and answering on ${READY_URL}"
echo ""

echo "--- Step 4: Verifying container is still running after health check ---"
if ! docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" \
        --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
    echo "ERROR: Container exited after health check passed." >&2
    exit 1
fi
echo "Container is still running."
echo ""

echo "=== Server image smoke test passed ==="
