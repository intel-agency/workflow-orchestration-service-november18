#!/usr/bin/env bash
# test-watchdog-io-detection.sh — Unit tests for the idle watchdog's I/O
# detection logic extracted from run_opencode_prompt.sh.
#
# Tests exercise:
#  1. _read_server_io_split() function: awk pattern returning "read write" pair
#  2. Constants: IDLE_TIMEOUT_SECS (900), READ_ONLY_GRACE_SECS (1200)
#  3. Split activity-detection logic: write vs read change detection
#  4. Edge cases: missing /proc/io, empty pidfile, zero-byte counters
#
# The watchdog tracks read_bytes and write_bytes SEPARATELY:
#   - write_bytes changes → strong progress signal, resets idle timer fully
#   - read_bytes changes (writes flat) → weaker signal, grants READ_ONLY_GRACE
#   - Neither changes → truly idle, standard IDLE_TIMEOUT_SECS applies
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_ROOT/run_opencode_prompt.sh"

PASSED=0
FAILED=0

pass() { echo "  PASS: $1"; PASSED=$(( PASSED + 1 )); }
fail() { echo "  FAIL: $1"; FAILED=$(( FAILED + 1 )); }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$label"
    else
        fail "$label (expected='$expected', got='$actual')"
    fi
}

echo "=== Watchdog I/O Detection Tests ==="

# ---------------------------------------------------------------------------
# Test 1: IDLE_TIMEOUT_SECS is 900 (15 minutes)
# ---------------------------------------------------------------------------
timeout_val=$(grep -oP '^IDLE_TIMEOUT_SECS=\K[0-9]+' "$TARGET")
assert_eq "IDLE_TIMEOUT_SECS is 900" "900" "$timeout_val"

# ---------------------------------------------------------------------------
# Test 2: HARD_CEILING_SECS is 5400 (90 minutes)
# ---------------------------------------------------------------------------
ceiling_val=$(grep -oP '^HARD_CEILING_SECS=\K[0-9]+' "$TARGET")
assert_eq "HARD_CEILING_SECS is 5400" "5400" "$ceiling_val"

# ---------------------------------------------------------------------------
# Test 2b: READ_ONLY_GRACE_SECS is 1200 (20 minutes)
# ---------------------------------------------------------------------------
grace_val=$(grep -oP '^READ_ONLY_GRACE_SECS=\K[0-9]+' "$TARGET")
assert_eq "READ_ONLY_GRACE_SECS is 1200" "1200" "$grace_val"

# ---------------------------------------------------------------------------
# Test 3: awk split pattern returns "read write" pair correctly
# ---------------------------------------------------------------------------
awk_split_pattern='/^read_bytes:/{r=$2} /^write_bytes:/{w=$2} END{print r, w}'

result=$(echo -e "read_bytes: 1000\nwrite_bytes: 500" | awk "$awk_split_pattern")
assert_eq "awk split returns 'read write' pair" "1000 500" "$result"

result=$(echo -e "read_bytes: 0\nwrite_bytes: 0" | awk "$awk_split_pattern")
assert_eq "awk split handles zero bytes" "0 0" "$result"

result=$(echo -e "read_bytes: 4294967296\nwrite_bytes: 4294967296" | awk "$awk_split_pattern")
assert_eq "awk split handles large values (>4GB)" "4294967296 4294967296" "$result"

result=$(echo -e "rchar: 999\nwchar: 999\nsyscr: 10\nsyscw: 10\nread_bytes: 200\nwrite_bytes: 300\ncancelled_write_bytes: 50" | awk "$awk_split_pattern")
assert_eq "awk split ignores non-target lines in /proc/io" "200 300" "$result"

# ---------------------------------------------------------------------------
# Test 4: Split change detection logic
# ---------------------------------------------------------------------------
# Helper: extract read and write from awk output
_split() { echo "$1" | awk "$awk_split_pattern"; }

# Scenario 4a: write_bytes increased → write_active=true
prev=$(_split "$(echo -e "read_bytes: 1000\nwrite_bytes: 500")")
cur=$(_split "$(echo -e "read_bytes: 1000\nwrite_bytes: 700")")
prev_w=$(echo "$prev" | awk '{print $2}')
cur_w=$(echo "$cur" | awk '{print $2}')
if [[ "$cur_w" != "$prev_w" ]]; then
    pass "detects write activity when write_bytes changes"
else
    fail "detects write activity when write_bytes changes (prev=$prev_w cur=$cur_w)"
fi

# Scenario 4b: read_bytes increased, write_bytes unchanged → read_active=true, write_active=false
prev=$(_split "$(echo -e "read_bytes: 1000\nwrite_bytes: 500")")
cur=$(_split "$(echo -e "read_bytes: 2000\nwrite_bytes: 500")")
prev_r=$(echo "$prev" | awk '{print $1}')
cur_r=$(echo "$cur" | awk '{print $1}')
prev_w=$(echo "$prev" | awk '{print $2}')
cur_w=$(echo "$cur" | awk '{print $2}')
if [[ "$cur_r" != "$prev_r" && "$cur_w" == "$prev_w" ]]; then
    pass "detects read-only activity (reads changed, writes flat)"
else
    fail "detects read-only activity (prev_r=$prev_r cur_r=$cur_r prev_w=$prev_w cur_w=$cur_w)"
fi

# Scenario 4c: both unchanged (truly idle)
prev=$(_split "$(echo -e "read_bytes: 1000\nwrite_bytes: 500")")
cur=$(_split "$(echo -e "read_bytes: 1000\nwrite_bytes: 500")")
if [[ "$cur" == "$prev" ]]; then
    pass "reports no activity when both counters unchanged"
else
    fail "reports no activity when both counters unchanged (prev=$prev cur=$cur)"
fi

# Scenario 4d: both changed → both active
prev=$(_split "$(echo -e "read_bytes: 1000\nwrite_bytes: 500")")
cur=$(_split "$(echo -e "read_bytes: 2000\nwrite_bytes: 700")")
prev_r=$(echo "$prev" | awk '{print $1}')
cur_r=$(echo "$cur" | awk '{print $1}')
prev_w=$(echo "$prev" | awk '{print $2}')
cur_w=$(echo "$cur" | awk '{print $2}')
if [[ "$cur_r" != "$prev_r" && "$cur_w" != "$prev_w" ]]; then
    pass "detects dual activity when both counters change"
else
    fail "detects dual activity (prev_r=$prev_r cur_r=$cur_r prev_w=$prev_w cur_w=$cur_w)"
fi

# ---------------------------------------------------------------------------
# Test 5: _read_server_io_split function exists and uses correct awk pattern
# ---------------------------------------------------------------------------
if grep -q '_read_server_io_split()' "$TARGET"; then
    pass "_read_server_io_split function exists"
else
    fail "_read_server_io_split function exists"
fi

if grep -q 'awk.*read_bytes.*write_bytes.*END{print r, w}' "$TARGET"; then
    pass "_read_server_io_split uses split pattern"
else
    fail "_read_server_io_split uses split pattern"
fi

# ---------------------------------------------------------------------------
# Test 6: No stale references to old single-metric approaches
# ---------------------------------------------------------------------------
if grep -q '_read_server_write_bytes' "$TARGET"; then
    fail "no stale _read_server_write_bytes references"
else
    pass "no stale _read_server_write_bytes references"
fi

# The old summed approach function name
if grep -q '_read_server_io_bytes' "$TARGET"; then
    fail "no stale _read_server_io_bytes references"
else
    pass "no stale _read_server_io_bytes references"
fi

# Old summed variables
if grep -q '_prev_server_io' "$TARGET"; then
    fail "no stale _prev_server_io references"
else
    pass "no stale _prev_server_io references"
fi

if grep -q '_cur_server_io' "$TARGET"; then
    fail "no stale _cur_server_io references"
else
    pass "no stale _cur_server_io references"
fi

if grep -q '_last_server_io_time' "$TARGET"; then
    fail "no stale _last_server_io_time references"
else
    pass "no stale _last_server_io_time references"
fi

# ---------------------------------------------------------------------------
# Test 7: _read_server_io_split with simulated /proc/io via temp dir
# ---------------------------------------------------------------------------
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Create a fake pidfile and /proc-like structure
fake_pid=99999
echo "$fake_pid" > "$tmpdir/server.pid"
mkdir -p "$tmpdir/proc/$fake_pid"
cat > "$tmpdir/proc/$fake_pid/io" <<EOF
rchar: 123456
wchar: 78910
syscr: 100
syscw: 50
read_bytes: 4096
write_bytes: 8192
cancelled_write_bytes: 0
EOF

# Local replica of the function for testing
_read_server_io_split() {
    local pidfile="$tmpdir/server.pid"
    if [[ -f "$pidfile" ]]; then
        local spid
        spid=$(cat "$pidfile" 2>/dev/null)
        if [[ -n "$spid" && -f "$tmpdir/proc/$spid/io" ]]; then
            awk '/^read_bytes:/{r=$2} /^write_bytes:/{w=$2} END{print r, w}' \
                "$tmpdir/proc/$spid/io" 2>/dev/null
            return
        fi
    fi
    echo ""
}

result=$(_read_server_io_split)
assert_eq "function reads simulated /proc/io (read=4096 write=8192)" "4096 8192" "$result"

# Verify individual components
result_read=$(echo "$result" | awk '{print $1}')
result_write=$(echo "$result" | awk '{print $2}')
assert_eq "split read component" "4096" "$result_read"
assert_eq "split write component" "8192" "$result_write"

# Test with missing pidfile
rm -f "$tmpdir/server.pid"
result=$(_read_server_io_split)
assert_eq "function returns empty for missing pidfile" "" "$result"

# Test with missing /proc/io
echo "$fake_pid" > "$tmpdir/server.pid"
rm -f "$tmpdir/proc/$fake_pid/io"
result=$(_read_server_io_split)
assert_eq "function returns empty for missing /proc/io" "" "$result"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results: $PASSED passed, $FAILED failed ==="

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
echo "All watchdog I/O detection tests passed."
