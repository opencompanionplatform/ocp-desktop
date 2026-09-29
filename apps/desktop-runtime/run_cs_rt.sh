#!/usr/bin/env bash
# Automated CS-RT (RUNTIME_API section 6) run against the real Godot bridge,
# headless. Linux/macOS companion to run_cs_rt.ps1 (Windows, proven green
# 2026-07-20: all 5 steps ok against the real OcpRuntimeBridge).
#
# UNVERIFIED as of 2026-07-20 -- nobody has run this on Linux or macOS yet.
#
# Prerequisites: ./build.sh already run for your platform (the extension
# shared library must be staged under godot/bin/...).
#
# Usage: ./run_cs_rt.sh --godot /path/to/godot [--timeout 30]

set -uo pipefail

GODOT_EXE=""
TIMEOUT=30

while [[ $# -gt 0 ]]; do
    case "$1" in
        --godot) GODOT_EXE="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        *) echo "Usage: $0 --godot /path/to/godot [--timeout seconds]"; exit 1 ;;
    esac
done

if [[ -z "$GODOT_EXE" || ! -x "$GODOT_EXE" ]]; then
    echo "Godot executable not found or not executable: '$GODOT_EXE'"
    exit 1
fi

cd "$(dirname "$0")"

export OCP_IPC_SOCKET="ocp-cs-rt-$$"
export OCP_IPC_TOKEN="$(head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
export CS_RT_TIMEOUT_S="$TIMEOUT"

echo "[run_cs_rt] socket: $OCP_IPC_SOCKET"

(cd .. && cargo build -p ocp-kernel --bin cs_rt_live)
if [[ $? -ne 0 ]]; then
    echo "cargo build failed"
    exit 1
fi

TEST_EXE="../target/debug/cs_rt_live"
echo "[run_cs_rt] starting cs_rt_live ($TEST_EXE)..."
"$TEST_EXE" > cs_rt_live.out.log 2> cs_rt_live.err.log &
TEST_PID=$!

echo "[run_cs_rt] starting Godot headless..."
"$GODOT_EXE" --headless --path godot > godot_headless.out.log 2> godot_headless.err.log &
GODOT_PID=$!

END=$((SECONDS + TIMEOUT + 15))
EXIT_CODE=1
FOUND=0
while [[ $SECONDS -lt $END ]]; do
    if ! kill -0 "$TEST_PID" 2>/dev/null; then
        wait "$TEST_PID"
        EXIT_CODE=$?
        FOUND=1
        break
    fi
    sleep 0.5
done

if [[ "$FOUND" -eq 0 ]]; then
    echo "cs_rt_live did not exit within the expected window; killing it"
    kill -9 "$TEST_PID" 2>/dev/null
fi
kill -9 "$GODOT_PID" 2>/dev/null

echo "----- cs_rt_live output -----"
cat cs_rt_live.out.log cs_rt_live.err.log 2>/dev/null
echo "----- Godot headless output -----"
cat godot_headless.out.log godot_headless.err.log 2>/dev/null
echo "-----------------------------"

if [[ "$EXIT_CODE" -eq 0 ]]; then
    echo "[run_cs_rt] PASS"
else
    echo "[run_cs_rt] FAIL (exit $EXIT_CODE)"
fi
exit "$EXIT_CODE"
