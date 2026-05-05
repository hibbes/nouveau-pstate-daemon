#!/bin/bash
# Smoke test for bin/nouveau-pstate-wedge-handler. Mocks the udev env via
# environment variables and overrides the log + sticky paths for isolation.

set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
H="$ROOT/bin/nouveau-pstate-wedge-handler"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

LOG="$WORK/wedge.log"
STICKY="$WORK/wedged"

fail=0

run() {
    WEDGE_LOG_FILE="$LOG" WEDGE_STICKY_FILE="$STICKY" \
        ACTION="$1" SUBSYSTEM="$2" WEDGED="$3" DEVNAME="$4" "$H"
}

# 1. Matching event: ACTION=change SUBSYSTEM=drm WEDGED=rebind -> log + sticky
run change drm rebind /dev/dri/card0 || { echo "FAIL: matching event returned non-zero"; fail=1; }
[[ -s "$LOG" ]] || { echo "FAIL: log empty after match"; fail=1; }
[[ -f "$STICKY" ]] || { echo "FAIL: sticky file not created"; fail=1; }
grep -q "WEDGED=rebind" "$LOG" || { echo "FAIL: log missing WEDGED=rebind"; fail=1; }
grep -q "/dev/dri/card0" "$LOG" || { echo "FAIL: log missing DEVNAME"; fail=1; }
grep -q "/dev/dri/card0" "$STICKY" || { echo "FAIL: sticky missing DEVNAME"; fail=1; }

# 2. Non-matching ACTION: should no-op (exit 0, no new log entry)
lines_before=$(wc -l < "$LOG")
run remove drm rebind /dev/dri/card0 || { echo "FAIL: non-matching exit non-zero"; fail=1; }
lines_after=$(wc -l < "$LOG")
[[ "$lines_after" -eq "$lines_before" ]] || { echo "FAIL: non-matching ACTION still logged"; fail=1; }

# 3. Non-matching WEDGED value: should no-op
lines_before=$(wc -l < "$LOG")
run change drm bus-reset /dev/dri/card0 || { echo "FAIL: bus-reset exit non-zero"; fail=1; }
lines_after=$(wc -l < "$LOG")
[[ "$lines_after" -eq "$lines_before" ]] || { echo "FAIL: non-rebind WEDGED still logged"; fail=1; }

# 4. Missing required env: must exit non-zero (defensive)
WEDGE_LOG_FILE="$LOG" WEDGE_STICKY_FILE="$STICKY" "$H" && { echo "FAIL: missing env accepted"; fail=1; }

if [[ $fail -eq 0 ]]; then
    echo "PASS: all wedge-handler smoke tests"
    exit 0
else
    exit 1
fi
