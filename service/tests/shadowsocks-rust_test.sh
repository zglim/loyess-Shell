#!/usr/bin/env bash
#
# Regression tests for service/shadowsocks-rust.sh
#
# Focus: the nameserver detection / start-argument logic in get_config_args()
# and the PID/state consistency of do_start(). The tests stub out the real
# `ssservice` daemon and redirect all paths into a throwaway temp tree, so they
# need neither root nor a real shadowsocks-rust install (only bash, jq, ps).
#
# Scenarios covered:
#   1. config WITHOUT nameserver        -> starts, no --dns passed
#   2. config WITH    nameserver        -> starts, --dns <value> passed
#   3. nameserver present but empty ""   -> fails, no daemon, no dirty PID file
#   4. nameserver present, wrong type    -> fails, no daemon, no dirty PID file
#   5. nameserver present but null       -> fails, no dirty PID file
#   6. nameserver present, invalid JSON  -> fails, no dirty PID file
#
# Exit status is non-zero if any assertion fails.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$SCRIPT_DIR/shadowsocks-rust.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "Cannot find script under test: $SCRIPT" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "These tests require 'jq' to be installed." >&2
    exit 1
fi

BASE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ss-rust-test.XXXXXX")
cleanup() {
    # Kill any stub daemons we spawned (their argv0 contains BASE_TMP) and
    # remove the scratch tree.
    pkill -f "$BASE_TMP" >/dev/null 2>&1
    rm -rf "$BASE_TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi
}
assert_contains() {
    case "$1" in
        *"$2"*) ok "$3" ;;
        *)      bad "$3 (missing '$2' in: $1)" ;;
    esac
}
assert_not_contains() {
    case "$1" in
        *"$2"*) bad "$3 (unexpected '$2' in: $1)" ;;
        *)      ok "$3" ;;
    esac
}
assert_file_exists() {
    if [ -e "$1" ]; then ok "$2"; else bad "$2 (missing $1)"; fi
}
assert_file_absent() {
    if [ -e "$1" ]; then bad "$2 (unexpected $1)"; else ok "$2"; fi
}

# Per-test fixture: a fresh temp dir, a stub `ssservice`, and clean paths.
new_case() {
    CASE_DIR=$(mktemp -d "$BASE_TMP/case.XXXXXX")
    STUB="$CASE_DIR/ssservice"
    CONF="$CASE_DIR/config.json"
    PID_FILE="$CASE_DIR/ss.pid"
    LOG="$CASE_DIR/ss.log"
    ARGS_FILE="$STUB.args"

    # The stub records the exact arguments it was started with, then keeps
    # itself alive under its own path (so check_pid can find it) without
    # leaking a child process (so kill -9 is clean).
    cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
echo "$*" > "$0.args"
exec -a "$0" sleep 300
STUB_EOF
    chmod +x "$STUB"
}

run_start() {
    DAEMON="$STUB" CONF="$CONF" PID_DIR="$CASE_DIR" PID_FILE="$PID_FILE" LOG="$LOG" \
        bash "$SCRIPT" start 2>&1
}
run_stop() {
    DAEMON="$STUB" CONF="$CONF" PID_DIR="$CASE_DIR" PID_FILE="$PID_FILE" LOG="$LOG" \
        bash "$SCRIPT" stop >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
echo "[1] config without nameserver -> plain start, no --dns"
new_case
printf '{\n  "server": "0.0.0.0",\n  "server_port": 8388,\n  "password": "p",\n  "method": "aes-256-gcm"\n}\n' > "$CONF"
out=$(run_start); rc=$?
assert_eq "$rc" 0 "exits 0"
assert_contains "$out" "success" "reports success"
assert_file_exists "$ARGS_FILE" "daemon was launched"
args=$(cat "$ARGS_FILE" 2>/dev/null || true)
assert_not_contains "$args" "--dns" "no --dns argument passed"
assert_file_exists "$PID_FILE" "PID file written"
read -r livepid < "$PID_FILE" 2>/dev/null || livepid=""
if [ -n "$livepid" ] && kill -0 "$livepid" 2>/dev/null; then
    ok "recorded PID is alive"
else
    bad "recorded PID is alive"
fi
run_stop
assert_file_absent "$PID_FILE" "PID file removed after stop"

# ---------------------------------------------------------------------------
echo "[2] config with nameserver -> start carries --dns <value>"
new_case
printf '{\n  "server": "0.0.0.0",\n  "server_port": 8388,\n  "password": "p",\n  "method": "aes-256-gcm",\n  "nameserver": "1.1.1.1"\n}\n' > "$CONF"
out=$(run_start); rc=$?
assert_eq "$rc" 0 "exits 0"
assert_contains "$out" "success" "reports success"
assert_file_exists "$ARGS_FILE" "daemon was launched"
args=$(cat "$ARGS_FILE" 2>/dev/null || true)
assert_contains "$args" "--dns" "--dns flag passed"
assert_contains "$args" "1.1.1.1" "nameserver value passed"
assert_file_exists "$PID_FILE" "PID file written"
run_stop

# ---------------------------------------------------------------------------
echo "[3] nameserver present but empty -> fail, no daemon, no dirty PID"
new_case
printf '{\n  "method": "aes-256-gcm",\n  "nameserver": ""\n}\n' > "$CONF"
out=$(run_start); rc=$?
assert_eq "$rc" 1 "exits non-zero"
assert_contains "$out" "failed" "reports failure"
assert_file_absent "$ARGS_FILE" "daemon never launched"
assert_file_absent "$PID_FILE" "no dirty PID file left behind"

# ---------------------------------------------------------------------------
echo "[4] nameserver present but wrong type -> fail, no daemon, no dirty PID"
new_case
printf '{\n  "method": "aes-256-gcm",\n  "nameserver": 8888\n}\n' > "$CONF"
out=$(run_start); rc=$?
assert_eq "$rc" 1 "exits non-zero"
assert_contains "$out" "failed" "reports failure"
assert_file_absent "$ARGS_FILE" "daemon never launched"
assert_file_absent "$PID_FILE" "no dirty PID file left behind"

# ---------------------------------------------------------------------------
echo "[5] nameserver present but null -> fail, no dirty PID"
new_case
printf '{\n  "method": "aes-256-gcm",\n  "nameserver": null\n}\n' > "$CONF"
out=$(run_start); rc=$?
assert_eq "$rc" 1 "exits non-zero"
assert_contains "$out" "failed" "reports failure"
assert_file_absent "$PID_FILE" "no dirty PID file left behind"

# ---------------------------------------------------------------------------
echo "[6] nameserver declared but config is invalid JSON -> fail, no dirty PID"
new_case
printf '{ "nameserver": "1.1.1.1"  ' > "$CONF"   # deliberately truncated
out=$(run_start); rc=$?
assert_eq "$rc" 1 "exits non-zero"
assert_contains "$out" "failed" "reports failure"
assert_file_absent "$PID_FILE" "no dirty PID file left behind"

# ---------------------------------------------------------------------------
echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
