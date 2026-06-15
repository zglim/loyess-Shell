#!/usr/bin/env bash
# Regression tests for nginx_start() in utils/start.sh
# Usage: bash utils/test_nginx_start.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

# ---------- helpers ----------

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        ((PASS++))
    else
        echo "  FAIL: $desc (expected=$expected, actual=$actual)"
        ((FAIL++))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $desc"
        ((PASS++))
    else
        echo "  FAIL: $desc (expected to contain '$needle' in: '$haystack')"
        ((FAIL++))
    fi
}

# Create a temp directory for each test scenario; cleaned up at exit.
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
ORIG_PATH="$PATH"

# setup_scenario MODE
#   MODE = start_ok | already_running | start_fail | no_binary | no_systemctl | no_mark
# Creates a mock environment and exports NGINX_BIN_PATH / WEB_INSTALL_MARK / PATH.
setup_scenario() {
    local mode="$1"
    local work="$TMPDIR_BASE/$mode"
    mkdir -p "$work/bin" "$work/mark"
    export PATH="$ORIG_PATH"

    # Always create the mark file (except no_mark scenario)
    if [ "$mode" != "no_mark" ]; then
        touch "$work/mark/.WebInstallMark"
    fi
    export WEB_INSTALL_MARK="$work/mark/.WebInstallMark"

    # nginx binary
    if [ "$mode" != "no_binary" ]; then
        touch "$work/bin/nginx"
        chmod +x "$work/bin/nginx"
    fi
    export NGINX_BIN_PATH="$work/bin/nginx"

    # Build a mock systemctl based on scenario
    local mock="$work/bin/systemctl"
    case "$mode" in
        start_ok)
            cat > "$mock" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
    *"is-active"*"nginx"*)
        STATE_FILE="$(dirname "$0")/../.nginx_started"
        if [ -f "$STATE_FILE" ]; then
            exit 0
        else
            touch "$STATE_FILE"
            exit 3
        fi
        ;;
    *"start"*"nginx"*)
        exit 0
        ;;
esac
MOCK
            ;;
        already_running)
            cat > "$mock" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
    *"is-active"*"nginx"*) exit 0 ;;
    *"start"*"nginx"*)     exit 0 ;;
esac
MOCK
            ;;
        start_fail)
            cat > "$mock" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
    *"is-active"*"nginx"*) exit 3 ;;
    *"start"*"nginx"*)     exit 1 ;;
esac
MOCK
            ;;
        no_binary)
            cat > "$mock" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
            ;;
        no_systemctl)
            rm -f "$mock"
            ;;
    esac
    [ -f "$mock" ] && chmod +x "$mock"

    # Prepend mock bin to PATH so our mock systemctl is found first
    export PATH="$work/bin:$PATH"
}

# ---------- tests ----------

run_test() {
    local mode="$1" expected_rc="$2" expected_msg="$3"
    setup_scenario "$mode"

    # Source start.sh in a subshell to isolate state
    output=$(
        bash -c '
            source "'"$SCRIPT_DIR"'/start.sh"
            nginx_start
            exit $?
        ' 2>&1
    )
    rc=$?

    assert_eq "[$mode] return code" "$expected_rc" "$rc"
    assert_contains "[$mode] output contains" "$expected_msg" "$output"
}

echo "=== nginx_start() regression tests ==="

echo ""
echo "--- Test 1: no WEB_INSTALL_MARK → skip silently (rc=0) ---"
run_test "no_mark" 0 ""

echo ""
echo "--- Test 2: nginx binary missing → fail with readable error ---"
run_test "no_binary" 1 "binary not found"

echo ""
echo "--- Test 3: systemctl missing → fail with readable error ---"
run_test "no_systemctl" 1 "systemctl not available"

echo ""
echo "--- Test 4: start succeeds → success message, rc=0 ---"
run_test "start_ok" 0 "Starting nginx success"

echo ""
echo "--- Test 5: already running → correct message, rc=0 ---"
run_test "already_running" 0 "already running"

echo ""
echo "--- Test 6: start fails → failed message, rc=1 ---"
run_test "start_fail" 1 "Starting nginx failed"

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
