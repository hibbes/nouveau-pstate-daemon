#!/bin/bash
# Smoke test for bin/nv-pstate. Mocks PSTATE_FILE and LOG_FILE via env.
# Exit 0 on all-pass, 1 on any failure.

set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
NV="$ROOT/bin/nv-pstate"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PSTATE="$WORK/pstate"
LOG="$WORK/nouveau-pstate.log"
STATE="$WORK/state"
: > "$PSTATE"

fail=0

run() {
    PSTATE_FILE="$PSTATE" LOG_FILE="$LOG" STATE_FILE="$STATE" \
        DMESG_CHECK_DISABLE=1 "$NV" "$@"
}

# 1. valid pstate writes file
run 0e || { echo "FAIL: 0e write returned non-zero"; fail=1; }
[[ "$(cat "$PSTATE")" == "0e" ]] || { echo "FAIL: 0e not in PSTATE_FILE"; fail=1; }

# 2. another valid pstate
run 03 || { echo "FAIL: 03 write returned non-zero"; fail=1; }
[[ "$(cat "$PSTATE")" == "03" ]] || { echo "FAIL: 03 not in PSTATE_FILE"; fail=1; }

# 3. invalid pstate is rejected (nonzero exit, file unchanged)
run deadbeef && { echo "FAIL: invalid pstate accepted"; fail=1; }
[[ "$(cat "$PSTATE")" == "03" ]] || { echo "FAIL: PSTATE_FILE mutated by invalid input"; fail=1; }

# 4. STATE_FILE reflects last value
[[ "$(cat "$STATE")" == "03" ]] || { echo "FAIL: STATE_FILE not updated"; fail=1; }

# 5. log file received entries
[[ -s "$LOG" ]] || { echo "FAIL: LOG_FILE empty"; fail=1; }

# 6. duplicate write is debounced (no extra log line)
lines_before=$(wc -l < "$LOG")
run 03 || { echo "FAIL: idempotent 03 write returned non-zero"; fail=1; }
lines_after=$(wc -l < "$LOG")
[[ "$lines_after" -eq "$lines_before" ]] || { echo "FAIL: duplicate write not debounced (before=$lines_before after=$lines_after)"; fail=1; }

if [[ $fail -eq 0 ]]; then
    echo "PASS: all nv-pstate smoke tests"
    exit 0
else
    exit 1
fi
