#!/usr/bin/env bash
# Regression tests for service/shadowsocks-rust.sh
# Covers:
#   1. No nameserver config -> normal start (no --dns)
#   2. Valid nameserver config -> start with --dns
#   3. Empty/invalid nameserver -> fail, no stale PID
#   4. do_start() branch logic (no broken command substitution)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/service/shadowsocks-rust.sh"
TMPDIR_BASE=$(mktemp -d)
PASS=0
FAIL=0
TOTAL=0

cleanup() {
    # Kill any leftover fake ssservice processes
    for pidfile in "$TMPDIR_BASE"/*/fake_daemon.pid; do
        if [ -f "$pidfile" ]; then
            kill "$(cat "$pidfile")" 2>/dev/null || true
        fi
    done
    # Also kill by process name pattern
    pkill -f "fake_ssservice_$$" 2>/dev/null || true
    rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

# ---------- helpers ----------

pass() {
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo "  FAIL: $1"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc (expected='$expected', actual='$actual')"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        pass "$desc"
    else
        fail "$desc (expected to contain '$needle')"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        fail "$desc (should NOT contain '$needle')"
    else
        pass "$desc"
    fi
}

# Set up a sandbox environment for testing.
# Creates a fake ssservice, config dir, and a wrapper script that sources
# the functions from the real script and runs do_start in isolation.
setup_sandbox() {
    local tdir="$1"
    mkdir -p "$tdir/etc/shadowsocks" "$tdir/var/log" "$tdir/var/run" "$tdir/bin"

    # Create a fake ssservice that records args and stays alive
    cat > "$tdir/bin/ssservice" <<'FAKE'
#!/usr/bin/env bash
echo "$@" >> "${SSSERVICE_LOG}"
# Stay alive so parent can detect us
sleep 60
FAKE
    chmod +x "$tdir/bin/ssservice"
}

# Source only the functions from the script under test, overriding globals
source_functions() {
    local tdir="$1"
    local conf="$2"

    DAEMON="$tdir/bin/ssservice"
    CONF="$conf"
    LOG="$tdir/var/log/shadowsocks-rust.log"
    PID_DIR="$tdir/var/run"
    PID_FILE="$tdir/var/run/shadowsocks-rust.pid"
    RET_VAL=0
    NameServer=""
    get_pid=""

    # Extract function definitions from the script under test
    eval "$(sed -n '/^get_config_args()/,/^}/p' "$SCRIPT_UNDER_TEST")"

    # Override check_pid for test environment
    check_pid() {
        get_pid=$(ps -ef | grep -v grep | grep "$DAEMON" | awk 'NR==1{print $2}') || true
    }

    # Override check_running for portability (no /proc on macOS)
    check_running() {
        if [ -e "$PID_FILE" ]; then
            if [ -r "$PID_FILE" ]; then
                read PID < "$PID_FILE"
                if kill -0 "$PID" 2>/dev/null; then
                    return 0
                else
                    rm -f "$PID_FILE"
                    return 1
                fi
            fi
        else
            return 2
        fi
    }

    eval "$(sed -n '/^do_start()/,/^}/p' "$SCRIPT_UNDER_TEST")"
    eval "$(sed -n '/^do_stop()/,/^}/p' "$SCRIPT_UNDER_TEST")"
}

# Helper: call get_config_args directly (not in subshell) and capture output to file
call_get_config_args() {
    local conf="$1"
    local outfile="$2"
    get_config_args "$conf" > "$outfile" 2>&1
    return $?
}

# Helper: run do_start in a child bash process to isolate side effects.
# The child process sources the functions and calls do_start, then reports
# results via files in the test directory.
run_do_start_isolated() {
    local tdir="$1"
    local conf="$2"
    local call_log="$3"

    bash <<WRAPPER
#!/usr/bin/env bash
SCRIPT_UNDER_TEST="$SCRIPT_UNDER_TEST"
DAEMON="$tdir/bin/ssservice"
CONF="$conf"
LOG="$tdir/var/log/shadowsocks-rust.log"
PID_DIR="$tdir/var/run"
PID_FILE="$tdir/var/run/shadowsocks-rust.pid"
RET_VAL=0
NameServer=""
get_pid=""
NAME="Shadowsocks-rust"
export SSSERVICE_LOG="$call_log"

eval "\$(sed -n '/^get_config_args()/,/^}/p' "\$SCRIPT_UNDER_TEST")"

check_pid() {
    get_pid=\$(ps -ef | grep -v grep | grep "\$DAEMON" | awk 'NR==1{print \$2}') || true
}

check_running() {
    if [ -e "\$PID_FILE" ]; then
        if [ -r "\$PID_FILE" ]; then
            read PID < "\$PID_FILE"
            if kill -0 "\$PID" 2>/dev/null; then
                return 0
            else
                rm -f "\$PID_FILE"
                return 1
            fi
        fi
    else
        return 2
    fi
}

eval "\$(sed -n '/^do_start()/,/^}/p' "\$SCRIPT_UNDER_TEST")"

do_start 2>&1
echo "\$RET_VAL" > "$tdir/ret_val.txt"
echo "\$?" > "$tdir/do_start_rc.txt"
WRAPPER
}

kill_test_daemons() {
    local tdir="$1"
    ps -ef | grep "$tdir/bin/ssservice" | grep -v grep | awk '{print $2}' | xargs kill 2>/dev/null || true
}

# ---------- Test: get_config_args ----------

test_get_config_args_no_nameserver() {
    echo "[Test] get_config_args: no nameserver field -> return 1"
    local tdir="$TMPDIR_BASE/t1"
    setup_sandbox "$tdir"
    local conf="$tdir/etc/shadowsocks/config.json"
    cat > "$conf" <<'EOF'
{
    "server": "0.0.0.0",
    "server_port": 8388,
    "password": "test",
    "method": "aes-256-gcm"
}
EOF
    source_functions "$tdir" "$conf"

    local outfile="$tdir/output.txt"
    call_get_config_args "$conf" "$outfile"
    local rc=$?
    local output
    output=$(cat "$outfile")

    assert_eq "return code should be 1 (not present)" "1" "$rc"
    assert_eq "NameServer should be empty" "" "$NameServer"
    assert_not_contains "no error message expected" "Error" "$output"
}

test_get_config_args_valid_nameserver() {
    echo "[Test] get_config_args: valid nameserver -> return 0"
    local tdir="$TMPDIR_BASE/t2"
    setup_sandbox "$tdir"
    local conf="$tdir/etc/shadowsocks/config.json"
    cat > "$conf" <<'EOF'
{
    "server": "0.0.0.0",
    "server_port": 8388,
    "password": "test",
    "method": "aes-256-gcm",
    "nameserver": "8.8.8.8"
}
EOF
    source_functions "$tdir" "$conf"

    local outfile="$tdir/output.txt"
    call_get_config_args "$conf" "$outfile"
    local rc=$?

    assert_eq "return code should be 0 (valid)" "0" "$rc"
    assert_eq "NameServer should be 8.8.8.8" "8.8.8.8" "$NameServer"
}

test_get_config_args_empty_nameserver() {
    echo "[Test] get_config_args: empty nameserver value -> return 2"
    local tdir="$TMPDIR_BASE/t3"
    setup_sandbox "$tdir"
    local conf="$tdir/etc/shadowsocks/config.json"
    cat > "$conf" <<'EOF'
{
    "server": "0.0.0.0",
    "server_port": 8388,
    "nameserver": ""
}
EOF
    source_functions "$tdir" "$conf"

    local outfile="$tdir/output.txt"
    call_get_config_args "$conf" "$outfile"
    local rc=$?
    local output
    output=$(cat "$outfile")

    assert_eq "return code should be 2 (error)" "2" "$rc"
    assert_contains "should mention empty" "empty" "$output"
}

test_get_config_args_null_nameserver() {
    echo "[Test] get_config_args: null nameserver -> return 2"
    local tdir="$TMPDIR_BASE/t4"
    setup_sandbox "$tdir"
    local conf="$tdir/etc/shadowsocks/config.json"
    cat > "$conf" <<'EOF'
{
    "server": "0.0.0.0",
    "server_port": 8388,
    "nameserver": null
}
EOF
    source_functions "$tdir" "$conf"

    local outfile="$tdir/output.txt"
    call_get_config_args "$conf" "$outfile"
    local rc=$?

    assert_eq "return code should be 2 (error)" "2" "$rc"
}

test_get_config_args_malformed_nameserver() {
    echo "[Test] get_config_args: object nameserver -> return 2"
    local tdir="$TMPDIR_BASE/t5"
    setup_sandbox "$tdir"
    local conf="$tdir/etc/shadowsocks/config.json"
    cat > "$conf" <<'EOF'
{
    "server": "0.0.0.0",
    "nameserver": {"host": "8.8.8.8"}
}
EOF
    source_functions "$tdir" "$conf"

    local outfile="$tdir/output.txt"
    call_get_config_args "$conf" "$outfile"
    local rc=$?
    local output
    output=$(cat "$outfile")

    assert_eq "return code should be 2 (malformed)" "2" "$rc"
    assert_contains "should mention malformed" "malformed" "$output"
}

test_get_config_args_tls_uri() {
    echo "[Test] get_config_args: tls:// URI nameserver -> return 0"
    local tdir="$TMPDIR_BASE/t6"
    setup_sandbox "$tdir"
    local conf="$tdir/etc/shadowsocks/config.json"
    cat > "$conf" <<'EOF'
{
    "server": "0.0.0.0",
    "nameserver": "tls://8.8.8.8"
}
EOF
    source_functions "$tdir" "$conf"

    local outfile="$tdir/output.txt"
    call_get_config_args "$conf" "$outfile"
    local rc=$?

    assert_eq "return code should be 0 (valid tls URI)" "0" "$rc"
    assert_eq "NameServer should be tls://8.8.8.8" "tls://8.8.8.8" "$NameServer"
}

# ---------- Test: do_start integration (via isolated subprocess) ----------

test_do_start_no_nameserver() {
    echo "[Test] do_start: no nameserver -> plain start, no --dns"
    local tdir="$TMPDIR_BASE/t7"
    setup_sandbox "$tdir"
    local conf="$tdir/etc/shadowsocks/config.json"
    local call_log="$tdir/ssservice_calls.log"
    cat > "$conf" <<'EOF'
{
    "server": "0.0.0.0",
    "server_port": 8388,
    "password": "test",
    "method": "aes-256-gcm"
}
EOF

    run_do_start_isolated "$tdir" "$conf" "$call_log"
    sleep 0.5

    if [ -f "$call_log" ]; then
        local call_args
        call_args=$(cat "$call_log")
        assert_not_contains "should NOT have --dns in args" "--dns" "$call_args"
        assert_contains "should have server -c" "server" "$call_args"
    else
        fail "ssservice was not called (no call log)"
    fi

    kill_test_daemons "$tdir"
}

test_do_start_with_nameserver() {
    echo "[Test] do_start: valid nameserver -> start with --dns"
    local tdir="$TMPDIR_BASE/t8"
    setup_sandbox "$tdir"
    local conf="$tdir/etc/shadowsocks/config.json"
    local call_log="$tdir/ssservice_calls.log"
    cat > "$conf" <<'EOF'
{
    "server": "0.0.0.0",
    "server_port": 8388,
    "password": "test",
    "method": "aes-256-gcm",
    "nameserver": "8.8.4.4"
}
EOF

    run_do_start_isolated "$tdir" "$conf" "$call_log"
    sleep 0.5

    if [ -f "$call_log" ]; then
        local call_args
        call_args=$(cat "$call_log")
        assert_contains "should have --dns in args" "--dns" "$call_args"
        assert_contains "should have nameserver value" "8.8.4.4" "$call_args"
    else
        fail "ssservice was not called (no call log)"
    fi

    kill_test_daemons "$tdir"
}

test_do_start_invalid_nameserver_no_start() {
    echo "[Test] do_start: empty nameserver -> fail, no start, no PID"
    local tdir="$TMPDIR_BASE/t9"
    setup_sandbox "$tdir"
    local conf="$tdir/etc/shadowsocks/config.json"
    local call_log="$tdir/ssservice_calls.log"
    cat > "$conf" <<'EOF'
{
    "server": "0.0.0.0",
    "server_port": 8388,
    "nameserver": ""
}
EOF

    local output
    output=$(run_do_start_isolated "$tdir" "$conf" "$call_log")
    sleep 0.3

    # ssservice should NOT have been called
    if [ -f "$call_log" ]; then
        fail "ssservice should NOT have been called"
    else
        pass "ssservice was not called"
    fi

    # No stale PID file
    if [ -f "$tdir/var/run/shadowsocks-rust.pid" ]; then
        fail "PID file should NOT exist after failed start"
    else
        pass "no stale PID file after failed start"
    fi

    assert_contains "should report failure" "failed" "$output"

    local ret_val=""
    if [ -f "$tdir/ret_val.txt" ]; then
        ret_val=$(cat "$tdir/ret_val.txt")
    fi
    assert_eq "RET_VAL should be 1" "1" "$ret_val"
}

test_do_start_null_nameserver_no_start() {
    echo "[Test] do_start: null nameserver -> fail, no start, no PID"
    local tdir="$TMPDIR_BASE/t10"
    setup_sandbox "$tdir"
    local conf="$tdir/etc/shadowsocks/config.json"
    local call_log="$tdir/ssservice_calls.log"
    cat > "$conf" <<'EOF'
{
    "server": "0.0.0.0",
    "server_port": 8388,
    "nameserver": null
}
EOF

    local output
    output=$(run_do_start_isolated "$tdir" "$conf" "$call_log")
    sleep 0.3

    if [ -f "$call_log" ]; then
        fail "ssservice should NOT have been called"
    else
        pass "ssservice was not called"
    fi

    if [ -f "$tdir/var/run/shadowsocks-rust.pid" ]; then
        fail "PID file should NOT exist after failed start"
    else
        pass "no stale PID file after failed start"
    fi

    local ret_val=""
    if [ -f "$tdir/ret_val.txt" ]; then
        ret_val=$(cat "$tdir/ret_val.txt")
    fi
    assert_eq "RET_VAL should be 1" "1" "$ret_val"
}

# ---------- Test: original bug is fixed ----------

test_grep_not_in_command_substitution() {
    echo "[Test] Source check: no broken \$(grep -q ...) pattern"
    if grep -qE '\$\(grep\s+-q' "$SCRIPT_UNDER_TEST"; then
        fail "still contains \$(grep -q ...) command substitution"
    else
        pass "no broken \$(grep -q ...) pattern found"
    fi
}

test_get_config_args_uses_return_not_exit() {
    echo "[Test] Source check: get_config_args uses return, not exit"
    local func_body
    func_body=$(sed -n '/^get_config_args()/,/^}/p' "$SCRIPT_UNDER_TEST")
    if echo "$func_body" | grep -qE '^\s*exit\s'; then
        fail "get_config_args still uses 'exit' instead of 'return'"
    else
        pass "get_config_args uses return codes"
    fi
}

test_do_start_has_pid_cleanup() {
    echo "[Test] Source check: do_start cleans PID on failure"
    local func_body
    func_body=$(sed -n '/^do_start()/,/^}/p' "$SCRIPT_UNDER_TEST")
    if echo "$func_body" | grep -q 'rm -f.*PID_FILE'; then
        pass "do_start has PID cleanup on failure"
    else
        fail "do_start missing PID cleanup on failure"
    fi
}

# ---------- Run all tests ----------

echo "=========================================="
echo " shadowsocks-rust.sh regression tests"
echo "=========================================="
echo ""

# get_config_args unit tests
test_get_config_args_no_nameserver
test_get_config_args_valid_nameserver
test_get_config_args_empty_nameserver
test_get_config_args_null_nameserver
test_get_config_args_malformed_nameserver
test_get_config_args_tls_uri

# do_start integration tests
test_do_start_no_nameserver
test_do_start_with_nameserver
test_do_start_invalid_nameserver_no_start
test_do_start_null_nameserver_no_start

# Source-level regression checks
test_grep_not_in_command_substitution
test_get_config_args_uses_return_not_exit
test_do_start_has_pid_cleanup

echo ""
echo "=========================================="
echo " Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "=========================================="

if [ $FAIL -gt 0 ]; then
    exit 1
fi
exit 0
