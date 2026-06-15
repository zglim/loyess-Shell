#!/usr/bin/env bash
#
# Regression tests for nginx_start() in utils/start.sh
#
# These tests stub out `systemctl` so they can run without a real systemd or
# nginx installation (e.g. on a developer laptop). They lock in the behaviour
# that was broken before: the start result is now derived from the *real*
# service state, and a failed start is propagated back to the caller as a
# non-zero return code instead of being silently swallowed.
#
# Covered scenarios:
#   1. nginx starts successfully        -> prints "success", returns 0
#   2. nginx fails to start             -> prints "failed",  returns non-zero
#   3. nginx is already running         -> returns 0, NOT misreported as failed
#   4. WEB_INSTALL_MARK absent          -> no-op, returns 0, no output
#   5. nginx binary missing             -> readable error, returns non-zero
#   6. systemctl unavailable            -> readable error, returns non-zero
#   7. caddy installed (precedence)     -> nginx defers, returns 0, no output

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=/dev/null
source "$REPO_ROOT/utils/start.sh"

PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

assert_rc_zero()     { if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2 (rc=$1)"; fi; }
assert_rc_nonzero()  { if [ "$1" -ne 0 ]; then pass "$2"; else fail "$2 (rc=$1)"; fi; }
assert_contains()    { case "$1" in *"$2"*) pass "$3";; *) fail "$3 (output: [$1])";; esac; }
assert_not_contains(){ case "$1" in *"$2"*) fail "$3 (output: [$1])";; *) pass "$3";; esac; }
assert_empty()       { if [ -z "$1" ]; then pass "$2"; else fail "$2 (output: [$1])"; fi; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TMP_BIN="$TMP_DIR/bin"
EMPTY_BIN="$TMP_DIR/emptybin"
mkdir -p "$TMP_BIN" "$EMPTY_BIN"

# Fake systemctl. Its view of the world is driven by two env vars:
#   FAKE_SYSTEMCTL_STATE_FILE : file holding "active" / "inactive"
#   FAKE_START_OUTCOME        : "success" makes `start` flip the state to active
cat > "$TMP_BIN/systemctl" <<'EOF'
#!/bin/sh
state_file="${FAKE_SYSTEMCTL_STATE_FILE}"
case "$1" in
    start)
        if [ "${FAKE_START_OUTCOME}" = "success" ]; then
            echo active > "$state_file"
        fi
        ;;
    is-active)
        if [ "$(cat "$state_file" 2>/dev/null)" = "active" ]; then
            echo active
        else
            echo inactive
        fi
        ;;
esac
exit 0
EOF
chmod +x "$TMP_BIN/systemctl"

export PATH="$TMP_BIN:$PATH"

STATE_FILE="$TMP_DIR/state"
export FAKE_SYSTEMCTL_STATE_FILE="$STATE_FILE"

WEB_MARK="$TMP_DIR/WebInstallMark"
NGINX_BIN="$TMP_DIR/nginx"
CADDY_BIN="$TMP_DIR/caddy"

# Globals consumed by nginx_start().
WEB_INSTALL_MARK="$WEB_MARK"
NGINX_BIN_PATH="$NGINX_BIN"
CADDY_BIN_PATH="$CADDY_BIN"

echo "== nginx_start regression tests =="

# 1. Successful start.
: > "$WEB_MARK"; : > "$NGINX_BIN"; rm -f "$CADDY_BIN"
echo inactive > "$STATE_FILE"
export FAKE_START_OUTCOME=success
out="$(nginx_start 2>&1)"; rc=$?
echo "- scenario: nginx starts successfully"
assert_rc_zero "$rc" "success returns 0"
assert_contains "$out" "success" "success output contains 'success'"

# 2. Failed start.
echo inactive > "$STATE_FILE"
export FAKE_START_OUTCOME=fail
out="$(nginx_start 2>&1)"; rc=$?
echo "- scenario: nginx fails to start"
assert_rc_nonzero "$rc" "failure returns non-zero"
assert_contains "$out" "failed" "failure output contains 'failed'"

# 3. Already running (must not be misreported as a failure).
echo active > "$STATE_FILE"
export FAKE_START_OUTCOME=fail
out="$(nginx_start 2>&1)"; rc=$?
echo "- scenario: nginx already running"
assert_rc_zero "$rc" "already-running returns 0"
assert_contains "$out" "already running" "already-running output is explicit"
assert_not_contains "$out" "failed" "already-running NOT misreported as failed"

# 4. WEB_INSTALL_MARK absent -> no-op.
WEB_INSTALL_MARK="$TMP_DIR/missing_mark"
out="$(nginx_start 2>&1)"; rc=$?
echo "- scenario: WEB_INSTALL_MARK absent (no-op)"
assert_rc_zero "$rc" "no web mark returns 0"
assert_empty "$out" "no web mark produces no output"
WEB_INSTALL_MARK="$WEB_MARK"

# 5. nginx binary missing while web masquerade is enabled (caddy absent).
: > "$WEB_MARK"; rm -f "$NGINX_BIN"; rm -f "$CADDY_BIN"
out="$(nginx_start 2>&1)"; rc=$?
echo "- scenario: nginx binary missing"
assert_rc_nonzero "$rc" "missing binary returns non-zero"
assert_contains "$out" "failed" "missing binary reports a failure"
: > "$NGINX_BIN"  # restore for later scenarios

# 6. systemctl unavailable (run with a PATH that has no systemctl).
: > "$WEB_MARK"; : > "$NGINX_BIN"; rm -f "$CADDY_BIN"
out="$( PATH="$EMPTY_BIN"; nginx_start 2>&1 )"; rc=$?
echo "- scenario: systemctl unavailable"
assert_rc_nonzero "$rc" "missing systemctl returns non-zero"
assert_contains "$out" "systemctl is not available" "missing systemctl gives readable error"

# 7. caddy installed -> nginx defers (no spurious nginx error).
: > "$WEB_MARK"; : > "$NGINX_BIN"; : > "$CADDY_BIN"
echo inactive > "$STATE_FILE"
out="$(nginx_start 2>&1)"; rc=$?
echo "- scenario: caddy installed (nginx defers)"
assert_rc_zero "$rc" "caddy present returns 0"
assert_empty "$out" "caddy present produces no nginx output"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
