#!/usr/bin/env bash
# FreeRDP interoperability smoke test against the headless ClawTank test server.
#
# Usage: tests/freerdp-smoke.sh <path/to/testserver>
# Needs FreeRDP 3 (xfreerdp3 / xfreerdp) and, for the full-session check, xvfb-run.
# Checks: (1) NLA succeeds with the right password, (2) NLA fails with a wrong one,
# (3) a full session starts, receives the test frame, and disconnects cleanly.
set -euo pipefail

server_bin="$1"
port="${PORT:-33891}"
user="smoke"
pass="smoke-pass-123"
freerdp="${FREERDP:-$(command -v xfreerdp3 || command -v xfreerdp || true)}"
[[ -n "$freerdp" ]] || { echo "error: FreeRDP (xfreerdp3) not found" >&2; exit 2; }

log="$(mktemp)"
"$server_bin" --port "$port" --user "$user" --password "$pass" >"$log" 2>&1 &
server_pid=$!
client_pid=""
cleanup() {
    [[ -n "$client_pid" ]] && kill "$client_pid" 2>/dev/null || true
    kill "$server_pid" 2>/dev/null || true
}
fail() {
    echo "FAIL: $*" >&2
    echo "---- server log ----" >&2
    cat "$log" >&2
    exit 1
}
trap cleanup EXIT

wait_for() { # pattern timeout_s
    for _ in $(seq 1 $(( $2 * 10 ))); do
        grep -q "$1" "$log" && return 0
        sleep 0.1
    done
    return 1
}

wait_for "EVENT listening" 10 || fail "server did not start"
common=(/v:127.0.0.1:"$port" /u:"$user" /cert:ignore)

echo "1/3 NLA with correct password"
"$freerdp" "${common[@]}" /p:"$pass" /auth-only || fail "auth-only with correct password failed"

echo "2/3 NLA with wrong password"
if "$freerdp" "${common[@]}" /p:wrong-password /auth-only; then
    fail "auth-only with wrong password succeeded"
fi

echo "3/3 full session"
xvfb-run -a "$freerdp" "${common[@]}" /p:"$pass" /size:1280x720 >/dev/null 2>&1 &
client_pid=$!
wait_for "EVENT connected" 20 || fail "session did not start"
wait_for "Sending test frame" 10 || fail "test frame was not sent"
sleep 2
kill "$client_pid"; wait "$client_pid" 2>/dev/null || true
client_pid=""
wait_for "EVENT disconnected" 10 || fail "disconnect not observed"

echo "PASS: FreeRDP connected with NLA, received the test frame, and disconnected"
