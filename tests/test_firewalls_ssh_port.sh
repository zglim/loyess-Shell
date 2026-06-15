#!/bin/bash
#
# Regression tests for SSH port detection and firewall rule management
# in utils/firewalls.sh
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------- minimal test harness ----------
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAIL_MESSAGES=()

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    if [ "${expected}" = "${actual}" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAIL_MESSAGES+=("FAIL: ${msg} — expected '${expected}', got '${actual}'")
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    if printf '%s\n' "${haystack}" | grep -qF -e "${needle}"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAIL_MESSAGES+=("FAIL: ${msg} — '${needle}' not found in output")
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="$3"
    if ! printf '%s\n' "${haystack}" | grep -qF -e "${needle}"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAIL_MESSAGES+=("FAIL: ${msg} — '${needle}' should NOT be in output")
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

# ---------- setup / teardown ----------
TMPDIR_BASE=""
MOCK_BIN=""
SSHD_CONFIG=""

setup() {
    TMPDIR_BASE="$(mktemp -d)"
    MOCK_BIN="${TMPDIR_BASE}/bin"
    SSHD_CONFIG="${TMPDIR_BASE}/sshd_config"
    mkdir -p "${MOCK_BIN}"

    # Create mock firewall tools that log invocations
    local log_file="${TMPDIR_BASE}/fw_log"
    touch "${log_file}"

    # Mock firewall-cmd
    cat > "${MOCK_BIN}/firewall-cmd" << MOCK
#!/bin/bash
LOG="${TMPDIR_BASE}/fw_log"
echo "firewall-cmd \$*" >> "\${LOG}"
case "\$*" in
    *--list-ports*) cat "${TMPDIR_BASE}/fw_ports" 2>/dev/null || true ;;
    *--state*) echo "running" ;;
esac
exit 0
MOCK
    chmod +x "${MOCK_BIN}/firewall-cmd"

    # Mock ufw
    cat > "${MOCK_BIN}/ufw" << MOCK
#!/bin/bash
LOG="${TMPDIR_BASE}/fw_log"
echo "ufw \$*" >> "\${LOG}"
if [ "\$1" = "status" ]; then
    cat "${TMPDIR_BASE}/ufw_status" 2>/dev/null || true
fi
exit 0
MOCK
    chmod +x "${MOCK_BIN}/ufw"

    # Mock iptables / ip6tables
    for cmd in iptables ip6tables; do
        cat > "${MOCK_BIN}/${cmd}" << MOCK
#!/bin/bash
LOG="${TMPDIR_BASE}/fw_log"
echo "${cmd} \$*" >> "\${LOG}"
case "\$*" in
    *-L\ INPUT*) cat "${TMPDIR_BASE}/iptables_rules" 2>/dev/null || true ;;
esac
exit 0
MOCK
        chmod +x "${MOCK_BIN}/${cmd}"
    done

    # Mock systemctl (no-op)
    cat > "${MOCK_BIN}/systemctl" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "${MOCK_BIN}/systemctl"

    # Initialize empty state files
    touch "${TMPDIR_BASE}/fw_ports"
    touch "${TMPDIR_BASE}/ufw_status"
    touch "${TMPDIR_BASE}/iptables_rules"

    export PATH="${MOCK_BIN}:${PATH}"
}

teardown() {
    if [ -n "${TMPDIR_BASE}" ] && [ -d "${TMPDIR_BASE}" ]; then
        rm -rf "${TMPDIR_BASE}"
    fi
}

# ---------- helper: extract sshdPort from add_ssh_port logic ----------
# We replicate the detection logic to test it in isolation
detect_ssh_port() {
    local config_file="$1"
    local port
    port=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' "${config_file}" 2>/dev/null \
        | grep -vE '^[[:space:]]*#' \
        | head -n 1 \
        | sed -E 's/^[[:space:]]*Port[[:space:]]+([0-9]+).*/\1/' || true)
    if [ -z "${port}" ]; then
        port=22
    fi
    echo "${port}"
}

# ---------- source the real firewalls.sh (override sshd_config path) ----------
# We need to patch the hardcoded /etc/ssh/sshd_config path for testing.
# Create a wrapper that replaces it with our temp file.
source_firewalls_patched() {
    local patched
    patched="${TMPDIR_BASE}/firewalls_patched.sh"
    sed "s|/etc/ssh/sshd_config|${SSHD_CONFIG}|g" "${PROJECT_ROOT}/utils/firewalls.sh" > "${patched}"
    # Provide stubs for external deps that firewalls.sh may call
    check_sys() { return 1; }
    package_install() { true; }
    _echo() { true; }
    write_env_variable() { true; }
    Green="" suffix=""
    # shellcheck disable=SC1090
    source "${patched}"
}

# ================================================================
# TEST GROUP 1: SSH port detection from sshd_config
# ================================================================

test_custom_port_simple() {
    setup
    echo "Port 2222" > "${SSHD_CONFIG}"
    local result
    result="$(detect_ssh_port "${SSHD_CONFIG}")"
    assert_eq "2222" "${result}" "custom port 2222 detected"
    teardown
}

test_no_port_defaults_to_22() {
    setup
    cat > "${SSHD_CONFIG}" << 'EOF'
# Some config without Port directive
PermitRootLogin no
PasswordAuthentication yes
EOF
    local result
    result="$(detect_ssh_port "${SSHD_CONFIG}")"
    assert_eq "22" "${result}" "no Port directive falls back to 22"
    teardown
}

test_empty_config_defaults_to_22() {
    setup
    : > "${SSHD_CONFIG}"
    local result
    result="$(detect_ssh_port "${SSHD_CONFIG}")"
    assert_eq "22" "${result}" "empty config falls back to 22"
    teardown
}

test_commented_port_ignored() {
    setup
    cat > "${SSHD_CONFIG}" << 'EOF'
#Port 3333
# Port 4444
PermitRootLogin no
EOF
    local result
    result="$(detect_ssh_port "${SSHD_CONFIG}")"
    assert_eq "22" "${result}" "commented Port lines are ignored"
    teardown
}

test_whitespace_before_port() {
    setup
    cat > "${SSHD_CONFIG}" << 'EOF'
   Port 5555
EOF
    local result
    result="$(detect_ssh_port "${SSHD_CONFIG}")"
    assert_eq "5555" "${result}" "leading whitespace before Port is handled"
    teardown
}

test_tab_before_port() {
    setup
    printf '\tPort\t6666\n' > "${SSHD_CONFIG}"
    local result
    result="$(detect_ssh_port "${SSHD_CONFIG}")"
    assert_eq "6666" "${result}" "tab-separated Port is handled"
    teardown
}

test_first_port_wins() {
    setup
    cat > "${SSHD_CONFIG}" << 'EOF'
Port 7777
Port 8888
EOF
    local result
    result="$(detect_ssh_port "${SSHD_CONFIG}")"
    assert_eq "7777" "${result}" "first Port directive wins (like sshd)"
    teardown
}

test_comment_with_space_before_hash() {
    setup
    cat > "${SSHD_CONFIG}" << 'EOF'
  # Port 9999
Port 1234
EOF
    local result
    result="$(detect_ssh_port "${SSHD_CONFIG}")"
    assert_eq "1234" "${result}" "indented comment is skipped, real Port is read"
    teardown
}

test_port_with_trailing_content() {
    setup
    cat > "${SSHD_CONFIG}" << 'EOF'
Port 4321 # custom port
EOF
    local result
    result="$(detect_ssh_port "${SSHD_CONFIG}")"
    assert_eq "4321" "${result}" "trailing comment after port number is handled"
    teardown
}

# ================================================================
# TEST GROUP 2: add_ssh_port with firewall-cmd backend
# ================================================================

test_firewall_cmd_adds_ssh_port() {
    setup
    echo "Port 2222" > "${SSHD_CONFIG}"
    source_firewalls_patched
    FIREWALL_MANAGE_TOOL="firewall-cmd"
    add_ssh_port
    local log
    log="$(cat "${TMPDIR_BASE}/fw_log")"
    assert_contains "${log}" "2222/tcp" "firewall-cmd adds custom SSH port 2222"
    teardown
}

test_firewall_cmd_skips_existing_ssh_port() {
    setup
    echo "Port 2222" > "${SSHD_CONFIG}"
    echo "2222/tcp" > "${TMPDIR_BASE}/fw_ports"
    source_firewalls_patched
    FIREWALL_MANAGE_TOOL="firewall-cmd"
    add_ssh_port
    local log
    log="$(cat "${TMPDIR_BASE}/fw_log")"
    # Should have listed ports but NOT added the port again
    assert_not_contains "${log}" "--add-port" "firewall-cmd does not duplicate existing SSH port"
    teardown
}

test_firewall_cmd_default_port_22() {
    setup
    echo "# no port here" > "${SSHD_CONFIG}"
    source_firewalls_patched
    FIREWALL_MANAGE_TOOL="firewall-cmd"
    add_ssh_port
    local log
    log="$(cat "${TMPDIR_BASE}/fw_log")"
    assert_contains "${log}" "22/tcp" "firewall-cmd adds default port 22 when not configured"
    teardown
}

# ================================================================
# TEST GROUP 3: add_ssh_port with ufw backend
# ================================================================

test_ufw_adds_ssh_port() {
    setup
    echo "Port 3322" > "${SSHD_CONFIG}"
    source_firewalls_patched
    FIREWALL_MANAGE_TOOL="ufw"
    add_ssh_port
    local log
    log="$(cat "${TMPDIR_BASE}/fw_log")"
    assert_contains "${log}" "3322/tcp" "ufw adds custom SSH port 3322"
    teardown
}

test_ufw_skips_when_openssh_present() {
    setup
    echo "Port 3322" > "${SSHD_CONFIG}"
    echo "OpenSSH                    ALLOW       Anywhere" > "${TMPDIR_BASE}/ufw_status"
    source_firewalls_patched
    FIREWALL_MANAGE_TOOL="ufw"
    add_ssh_port
    local log
    log="$(cat "${TMPDIR_BASE}/fw_log")"
    assert_not_contains "${log}" "allow" "ufw does not add rule when OpenSSH already present"
    teardown
}

test_ufw_skips_when_port_already_open() {
    setup
    echo "Port 3322" > "${SSHD_CONFIG}"
    echo "3322/tcp                   ALLOW       Anywhere" > "${TMPDIR_BASE}/ufw_status"
    source_firewalls_patched
    FIREWALL_MANAGE_TOOL="ufw"
    add_ssh_port
    local log
    log="$(cat "${TMPDIR_BASE}/fw_log")"
    assert_not_contains "${log}" "allow" "ufw does not duplicate when port already open"
    teardown
}

# ================================================================
# TEST GROUP 4: add_ssh_port with iptables backend
# ================================================================

test_iptables_adds_ssh_port() {
    setup
    echo "Port 4422" > "${SSHD_CONFIG}"
    source_firewalls_patched
    FIREWALL_MANAGE_TOOL="iptables"
    add_ssh_port
    local log
    log="$(cat "${TMPDIR_BASE}/fw_log")"
    assert_contains "${log}" "4422" "iptables adds custom SSH port 4422"
    teardown
}

test_iptables_skips_existing_ssh_rule() {
    setup
    echo "Port 4422" > "${SSHD_CONFIG}"
    echo "ACCEPT  tcp  --  0.0.0.0/0  0.0.0.0/0  tcp dpt:4422" > "${TMPDIR_BASE}/iptables_rules"
    source_firewalls_patched
    FIREWALL_MANAGE_TOOL="iptables"
    add_ssh_port
    local log
    log="$(cat "${TMPDIR_BASE}/fw_log")"
    assert_not_contains "${log}" "-I INPUT" "iptables does not duplicate existing SSH rule"
    teardown
}

test_iptables_skips_named_ssh_service() {
    setup
    echo "Port 4422" > "${SSHD_CONFIG}"
    echo "ACCEPT  tcp  --  0.0.0.0/0  0.0.0.0/0  tcp dpt:ssh" > "${TMPDIR_BASE}/iptables_rules"
    source_firewalls_patched
    FIREWALL_MANAGE_TOOL="iptables"
    add_ssh_port
    local log
    log="$(cat "${TMPDIR_BASE}/fw_log")"
    assert_not_contains "${log}" "-I INPUT" "iptables recognizes 'dpt:ssh' as existing SSH rule"
    teardown
}

# ================================================================
# TEST GROUP 5: config_firewall_logic ordering
# ================================================================

test_config_firewall_ssh_before_proxy() {
    setup
    echo "Port 5522" > "${SSHD_CONFIG}"
    source_firewalls_patched
    FIREWALL_MANAGE_TOOL="firewall-cmd"
    firewallNeedOpenPort="10808"
    # Mock firewall-cmd to always return empty port list (no existing rules)
    : > "${TMPDIR_BASE}/fw_ports"
    config_firewall_logic
    local log
    log="$(cat "${TMPDIR_BASE}/fw_log")"
    # Find line numbers for SSH port and proxy port additions
    local ssh_line proxy_line
    ssh_line=$(echo "${log}" | grep -n "add-port=5522" | head -1 | cut -d: -f1)
    proxy_line=$(echo "${log}" | grep -n "add-port=10808" | head -1 | cut -d: -f1)
    if [ -n "${ssh_line}" ] && [ -n "${proxy_line}" ]; then
        if [ "${ssh_line}" -lt "${proxy_line}" ]; then
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
            FAIL_MESSAGES+=("FAIL: SSH port should be added before proxy port")
        fi
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAIL_MESSAGES+=("FAIL: could not find SSH and proxy port additions in log")
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
    teardown
}

# ================================================================
# Run all tests
# ================================================================

echo "========================================"
echo " Running firewall SSH port regression tests"
echo "========================================"

# Group 1: SSH port detection
test_custom_port_simple
test_no_port_defaults_to_22
test_empty_config_defaults_to_22
test_commented_port_ignored
test_whitespace_before_port
test_tab_before_port
test_first_port_wins
test_comment_with_space_before_hash
test_port_with_trailing_content

# Group 2: firewall-cmd backend
test_firewall_cmd_adds_ssh_port
test_firewall_cmd_skips_existing_ssh_port
test_firewall_cmd_default_port_22

# Group 3: ufw backend
test_ufw_adds_ssh_port
test_ufw_skips_when_openssh_present
test_ufw_skips_when_port_already_open

# Group 4: iptables backend
test_iptables_adds_ssh_port
test_iptables_skips_existing_ssh_rule
test_iptables_skips_named_ssh_service

# Group 5: config_firewall_logic ordering
test_config_firewall_ssh_before_proxy

echo ""
echo "========================================"
echo " Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
echo "========================================"

if [ "${TESTS_FAILED}" -gt 0 ]; then
    echo ""
    echo "Failures:"
    for msg in "${FAIL_MESSAGES[@]}"; do
        echo "  ${msg}"
    done
    exit 1
fi

echo ""
echo "All tests passed!"
exit 0
