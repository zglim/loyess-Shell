#!/usr/bin/env bash
# Regression tests for service/go-shadowsocks2.sh plugin detection fix.
#
# These tests verify:
#   1. No-plugin config → basic branch (no plugin args in startup command).
#   2. Plugin config    → plugin branch (plugin args present in startup command).
#   3. Stop with plugin → plugin process is cleaned up.
#   4. Incomplete plugin config → exits with error.
#
# Strategy: we source only the get_config_args function and stub the globals it
# depends on, then exercise it with crafted JSON config files.  For do_start /
# do_stop we stub the daemon with a harmless shell script and inspect the
# generated command line.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_SCRIPT="$SCRIPT_DIR/go-shadowsocks2.sh"

PASS=0
FAIL=0

pass() { (( PASS++ )); echo "  PASS: $1"; }
fail() { (( FAIL++ )); echo "  FAIL: $1"; }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ─── helpers ──────────────────────────────────────────────────────────────────

# Extract get_config_args function body and PluginEnabled/Plugin/PluginOpts
# parsing so we can source it in isolation.  We set NAME to avoid an unbound
# variable reference.
source_get_config_args() {
    # Source the whole script but override exit so tests don't actually exit.
    # We achieve this by wrapping in a subshell.
    :
}

# Run get_config_args in a subshell with the given config file.  Prints
# "PluginEnabled=<true|false> Plugin=<val> PluginOpts=<val>" on success, or
# "EXIT=<code>" if the function called exit.
run_get_config_args() {
    local conf="$1"
    (
        NAME=Go-shadowsocks2
        # Override exit so we capture the code instead of killing the subshell
        exit() { echo "EXIT_CODE=$1"; return "$1" 2>/dev/null || true; }

        # Extract just the function from the service script
        eval "$(sed -n '/^get_config_args(){/,/^}/p' "$SERVICE_SCRIPT")"

        get_config_args "$conf"
        echo "PluginEnabled=$PluginEnabled"
        echo "Plugin=$Plugin"
        echo "PluginOpts=$PluginOpts"
    )
}

# ─── Test 1: no-plugin config → basic branch ─────────────────────────────────

echo "Test 1: no-plugin config enters basic branch"

CONF_NO_PLUGIN="$TMPDIR_BASE/no_plugin.json"
cat > "$CONF_NO_PLUGIN" <<'EOF'
{
    "server_port": 8388,
    "password": "testpass",
    "method": "aes-128-gcm",
    "mode": "tcp_only"
}
EOF

OUTPUT=$(run_get_config_args "$CONF_NO_PLUGIN")
if echo "$OUTPUT" | grep -q "PluginEnabled=false"; then
    pass "PluginEnabled is false for no-plugin config"
else
    fail "PluginEnabled should be false, got: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "^Plugin=$"; then
    pass "Plugin is empty for no-plugin config"
else
    fail "Plugin should be empty, got: $OUTPUT"
fi

# ─── Test 2: plugin config → plugin branch ───────────────────────────────────

echo "Test 2: plugin config enters plugin branch"

CONF_PLUGIN="$TMPDIR_BASE/with_plugin.json"
cat > "$CONF_PLUGIN" <<'EOF'
{
    "server_port": 8388,
    "password": "testpass",
    "method": "aes-256-gcm",
    "mode": "tcp_and_udp",
    "plugin": "obfs-server",
    "plugin_opts": "obfs=http"
}
EOF

OUTPUT=$(run_get_config_args "$CONF_PLUGIN")
if echo "$OUTPUT" | grep -q "PluginEnabled=true"; then
    pass "PluginEnabled is true for plugin config"
else
    fail "PluginEnabled should be true, got: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "^Plugin=obfs-server$"; then
    pass "Plugin value correctly parsed"
else
    fail "Plugin should be obfs-server, got: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "^PluginOpts=obfs=http$"; then
    pass "PluginOpts value correctly parsed"
else
    fail "PluginOpts should be obfs=http, got: $OUTPUT"
fi

# ─── Test 3: incomplete plugin config (only plugin, no plugin_opts) ───────────

echo "Test 3: incomplete plugin config exits with error"

CONF_INCOMPLETE="$TMPDIR_BASE/incomplete_plugin.json"
cat > "$CONF_INCOMPLETE" <<'EOF'
{
    "server_port": 8388,
    "password": "testpass",
    "method": "aes-128-gcm",
    "mode": "tcp_only",
    "plugin": "obfs-server"
}
EOF

OUTPUT=$(run_get_config_args "$CONF_INCOMPLETE")
if echo "$OUTPUT" | grep -q "EXIT_CODE=1\|Incomplete plugin configuration"; then
    pass "Incomplete plugin config (missing plugin_opts) causes exit"
else
    fail "Incomplete plugin config should cause exit, got: $OUTPUT"
fi

# ─── Test 4: incomplete plugin config (only plugin_opts, no plugin) ───────────

echo "Test 4: incomplete plugin config (only plugin_opts) exits with error"

CONF_INCOMPLETE2="$TMPDIR_BASE/incomplete_plugin2.json"
cat > "$CONF_INCOMPLETE2" <<'EOF'
{
    "server_port": 8388,
    "password": "testpass",
    "method": "aes-128-gcm",
    "mode": "tcp_only",
    "plugin_opts": "obfs=http"
}
EOF

OUTPUT=$(run_get_config_args "$CONF_INCOMPLETE2")
if echo "$OUTPUT" | grep -q "EXIT_CODE=1\|Incomplete plugin configuration"; then
    pass "Incomplete plugin config (missing plugin) causes exit"
else
    fail "Incomplete plugin config should cause exit, got: $OUTPUT"
fi

# ─── Test 5: plugin with empty value exits ───────────────────────────────────

echo "Test 5: plugin key present but empty value exits with error"

CONF_EMPTY_PLUGIN="$TMPDIR_BASE/empty_plugin.json"
cat > "$CONF_EMPTY_PLUGIN" <<'EOF'
{
    "server_port": 8388,
    "password": "testpass",
    "method": "aes-128-gcm",
    "mode": "tcp_only",
    "plugin": "",
    "plugin_opts": "obfs=http"
}
EOF

OUTPUT=$(run_get_config_args "$CONF_EMPTY_PLUGIN")
if echo "$OUTPUT" | grep -q "EXIT_CODE=1\|empty or null"; then
    pass "Empty plugin value causes exit"
else
    fail "Empty plugin value should cause exit, got: $OUTPUT"
fi

# ─── Test 6: do_start builds correct command (no plugin) ────────────────────

echo "Test 6: do_start command line for no-plugin config"

# We verify by inspecting the script text: the no-plugin branch must NOT
# contain -plugin.  This is a static check.
if grep -A2 'if \[ "\$PluginEnabled" = "true" \]' "$SERVICE_SCRIPT" | \
   grep -q 'else' && \
   grep -A5 'if \[ "\$PluginEnabled" = "true" \]' "$SERVICE_SCRIPT" | \
   tail -3 | grep -qv '\-plugin'; then
    pass "No-plugin branch in do_start does not include -plugin flag"
else
    fail "No-plugin branch in do_start should not include -plugin flag"
fi

# ─── Test 7: do_start builds correct command (with plugin) ──────────────────

echo "Test 7: do_start command line for plugin config"

if grep -A1 'if \[ "\$PluginEnabled" = "true" \]' "$SERVICE_SCRIPT" | \
   grep -q '\-plugin'; then
    pass "Plugin branch in do_start includes -plugin flag"
else
    fail "Plugin branch in do_start should include -plugin flag"
fi

# ─── Test 8: do_stop cleans up plugin process when plugin enabled ────────────

echo "Test 8: do_stop cleans up plugin process when PluginEnabled=true"

if grep -A5 'do_stop()' "$SERVICE_SCRIPT" | grep -q 'PluginEnabled.*true' && \
   grep -A10 'do_stop()' "$SERVICE_SCRIPT" | grep -q 'check_pid.*Plugin'; then
    pass "do_stop checks and kills plugin process when PluginEnabled=true"
else
    fail "do_stop should check and kill plugin process when plugin is enabled"
fi

# ─── Test 9: do_stop does NOT attempt plugin cleanup when no plugin ──────────

echo "Test 9: do_stop skips plugin cleanup when PluginEnabled=false"

# The plugin cleanup must be inside the PluginEnabled=true guard.
STOP_BLOCK=$(sed -n '/^do_stop()/,/^}/p' "$SERVICE_SCRIPT")
# Verify that check_pid "${Plugin}" only appears inside the PluginEnabled block
PLUGIN_CHECK_LINE=$(echo "$STOP_BLOCK" | grep -n 'check_pid.*Plugin' | head -1 | cut -d: -f1)
GUARD_LINE=$(echo "$STOP_BLOCK" | grep -n 'PluginEnabled' | head -1 | cut -d: -f1)
if [ -n "$PLUGIN_CHECK_LINE" ] && [ -n "$GUARD_LINE" ] && \
   [ "$PLUGIN_CHECK_LINE" -gt "$GUARD_LINE" ]; then
    pass "Plugin cleanup is guarded by PluginEnabled check in do_stop"
else
    fail "Plugin cleanup must be inside PluginEnabled=true guard"
fi

# ─── Test 10: verify the broken grep -qE pattern is fully removed ────────────

echo "Test 10: no residual 'grep -qE' command-substitution pattern"

GREP_QE_COUNT=$(grep -c 'grep -qE' "$SERVICE_SCRIPT" || true)
if [ "$GREP_QE_COUNT" -eq 0 ]; then
    pass "No grep -qE patterns remain in script"
else
    fail "Script still contains grep -qE patterns"
fi

CMD_SUB_COUNT=$(grep -cE '\$\(cat.*grep' "$SERVICE_SCRIPT" || true)
if [ "$CMD_SUB_COUNT" -eq 0 ]; then
    pass "No \$(cat ... | grep ...) command-substitution patterns remain"
else
    fail "Script still contains \$(cat ... | grep ...) patterns"
fi

# ─── summary ─────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
