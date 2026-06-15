#!/usr/bin/env bash
# Regression test for service/go-shadowsocks2.sh plugin handling.
#
# It verifies that the single "is a plugin configured" decision (UsePlugin) made
# by get_config_args is honoured consistently by do_start and do_stop, covering:
#   1. plain go-shadowsocks2 config takes the basic (no-plugin) branch
#   2. config with plugin / plugin_opts takes the plugin branch
#   3. stopping a plugin deployment cleans up the plugin process
#   4. a half-configured plugin (plugin without plugin_opts) fails loudly
#
# The real daemon is never launched: the script is sourced and a few
# environment-sensitive helpers (nohup / kill / check_pid / check_running) are
# replaced with test doubles so the branch decisions and generated command line
# can be inspected on any platform without root or /proc.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/go-shadowsocks2.sh"

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq is required to run this test"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass(){ echo "PASS: $1"; PASS=$((PASS + 1)); }
fail(){ echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq(){ # desc expected actual
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$2], got [$3])"; fi
}
assert_contains(){ # desc haystack needle
    case "$2" in *"$3"*) pass "$1";; *) fail "$1 (missing [$3] in [$2])";; esac
}
assert_not_contains(){ # desc haystack needle
    case "$2" in *"$3"*) fail "$1 (unexpected [$3] in [$2])";; *) pass "$1";; esac
}

# --- config fixtures -------------------------------------------------------
BASE_CONF="$TMP/base.json"
cat > "$BASE_CONF" <<'JSON'
{
  "server_port": 8388,
  "password": "secret",
  "method": "aes-256-gcm",
  "mode": "tcp_and_udp"
}
JSON

PLUGIN_CONF="$TMP/plugin.json"
cat > "$PLUGIN_CONF" <<'JSON'
{
  "server_port": 8388,
  "password": "secret",
  "method": "aes-256-gcm",
  "mode": "tcp_and_udp",
  "plugin": "obfs-local",
  "plugin_opts": "obfs=http;obfs-host=www.bing.com"
}
JSON

BAD_CONF="$TMP/bad.json"   # plugin set but plugin_opts missing
cat > "$BAD_CONF" <<'JSON'
{
  "server_port": 8388,
  "password": "secret",
  "method": "aes-256-gcm",
  "mode": "tcp_and_udp",
  "plugin": "obfs-local"
}
JSON

# Provide a harmless DAEMON so sourcing does not `exit 0`, then load the script
# so its functions are available in this shell. The source guard in the target
# means dispatch/auto-init do not run on source.
DAEMON=/bin/echo
# shellcheck source=/dev/null
source "$TARGET"

# Replace environment-sensitive pieces with test doubles.
DAEMON="/usr/local/bin/go-shadowsocks2"
LOG="$TMP/log"
PID_FILE="$TMP/pid"
CAPTURED="$TMP/start_cmd"
KILLS="$TMP/kills"

nohup(){ printf '%s\n' "$*" > "$CAPTURED"; }   # capture the start command line
check_pid(){ GET_PID=4242; }                   # deterministic "found" plugin pid
kill(){ printf 'kill %s\n' "$*" >> "$KILLS"; } # record kills instead of sending

# === 1. get_config_args: plain config -> basic branch ======================
get_config_args "$BASE_CONF"
assert_eq "base config sets UsePlugin=0" "0" "$UsePlugin"
assert_eq "base config leaves Plugin empty" "" "$Plugin"

# === 2. get_config_args: plugin config -> plugin branch ====================
get_config_args "$PLUGIN_CONF"
assert_eq "plugin config sets UsePlugin=1" "1" "$UsePlugin"
assert_eq "plugin config parses plugin name" "obfs-local" "$Plugin"
assert_eq "plugin config parses plugin_opts" "obfs=http;obfs-host=www.bing.com" "$PluginOpts"

# === 3. do_start without plugin -> command omits plugin args ================
get_config_args "$BASE_CONF"
check_running(){ return 1; }   # force "not running" so do_start proceeds
: > "$CAPTURED"
do_start >/dev/null 2>&1
wait 2>/dev/null
START_BASE="$(cat "$CAPTURED")"
assert_not_contains "basic start omits -plugin" "$START_BASE" "-plugin"
assert_contains "basic start carries server url" "$START_BASE" "ss://AEAD_AES_256_GCM:secret@:8388"

# === 4. do_start with plugin -> command includes plugin args ===============
get_config_args "$PLUGIN_CONF"
: > "$CAPTURED"
do_start >/dev/null 2>&1
wait 2>/dev/null
START_PLUGIN="$(cat "$CAPTURED")"
assert_contains "plugin start carries -plugin" "$START_PLUGIN" "-plugin obfs-local"
assert_contains "plugin start carries -plugin-opts" "$START_PLUGIN" "-plugin-opts obfs=http;obfs-host=www.bing.com"

# === 5. do_stop with plugin -> plugin process is cleaned up ================
get_config_args "$PLUGIN_CONF"
check_running(){ return 0; }   # force "running" so do_stop enters cleanup
PID=111
: > "$KILLS"
do_stop >/dev/null 2>&1
STOP_PLUGIN="$(cat "$KILLS")"
assert_contains "plugin stop kills main process" "$STOP_PLUGIN" "111"
assert_contains "plugin stop kills plugin process" "$STOP_PLUGIN" "4242"

# === 6. do_stop without plugin -> no plugin cleanup attempted ==============
get_config_args "$BASE_CONF"
PID=222
: > "$KILLS"
do_stop >/dev/null 2>&1
STOP_BASE="$(cat "$KILLS")"
assert_contains "basic stop kills main process" "$STOP_BASE" "222"
assert_not_contains "basic stop skips plugin cleanup" "$STOP_BASE" "4242"

# === 7. invalid config (plugin without plugin_opts) -> clean failure =======
ERR="$(get_config_args "$BAD_CONF" 2>&1)"
RC=$?
assert_eq "invalid plugin config exits non-zero" "1" "$RC"
assert_contains "invalid plugin config reports plugin_opts" "$ERR" "plugin_opts"

echo "----"
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
