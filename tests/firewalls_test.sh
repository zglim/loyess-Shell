#!/usr/bin/env bash
#
# Regression tests for the SSH-port protection logic in utils/firewalls.sh.
#
# Covered scenarios (see task requirements):
#   * get_ssh_port reads the real custom Port from sshd_config, tolerating
#     whitespace, tabs, indentation, case and inline/standalone comments.
#   * get_ssh_port falls back to 22 when no usable Port is configured.
#   * add_ssh_port across the firewall-cmd / ufw / iptables branches never
#     appends a duplicate rule when one already exists, and always adds the
#     rule on the detected real port when it is missing.
#
# Run: bash tests/firewalls_test.sh
set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "${ROOT_DIR}/utils/firewalls.sh"

PASS=0
FAIL=0

assert_eq(){
    local desc="$1" expected="$2" actual="$3"
    if [ "${expected}" = "${actual}" ]; then
        PASS=$((PASS + 1))
        printf 'ok   - %s\n' "${desc}"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL - %s (expected [%s], got [%s])\n' "${desc}" "${expected}" "${actual}"
    fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# --------------------------------------------------------------------------
# get_ssh_port: detection of the actually configured SSH port
# --------------------------------------------------------------------------
cfg="${TMP_DIR}/custom";    printf 'Port 2222\nPermitRootLogin no\n'       > "${cfg}"
assert_eq "reads plain custom Port"               "2222" "$(get_ssh_port "${cfg}")"

cfg="${TMP_DIR}/tab";       printf 'Port\t2233\n'                          > "${cfg}"
assert_eq "reads tab-separated Port"              "2233" "$(get_ssh_port "${cfg}")"

cfg="${TMP_DIR}/spaces";    printf 'Port     2244\n'                       > "${cfg}"
assert_eq "reads multi-space Port"                "2244" "$(get_ssh_port "${cfg}")"

cfg="${TMP_DIR}/indent";    printf '   Port 2200\n'                        > "${cfg}"
assert_eq "reads indented Port"                   "2200" "$(get_ssh_port "${cfg}")"

cfg="${TMP_DIR}/lower";     printf 'port 2255\n'                           > "${cfg}"
assert_eq "reads lowercase keyword"               "2255" "$(get_ssh_port "${cfg}")"

cfg="${TMP_DIR}/inline";    printf 'Port 2266 # primary listener\n'        > "${cfg}"
assert_eq "ignores inline trailing comment"       "2266" "$(get_ssh_port "${cfg}")"

cfg="${TMP_DIR}/firstwins"; printf '#Port 22\nPort 2277\nPort 2288\n'      > "${cfg}"
assert_eq "first active Port wins over commented" "2277" "$(get_ssh_port "${cfg}")"

cfg="${TMP_DIR}/commented"; printf '#Port 9999\n# Port 8888\nUsePAM yes\n' > "${cfg}"
assert_eq "fallback 22 when only commented Port"  "22"   "$(get_ssh_port "${cfg}")"

cfg="${TMP_DIR}/noport";    printf 'PermitRootLogin no\nUsePAM yes\n'      > "${cfg}"
assert_eq "fallback 22 when no Port configured"   "22"   "$(get_ssh_port "${cfg}")"

cfg="${TMP_DIR}/badvalue";  printf 'Port ssh-default\n'                    > "${cfg}"
assert_eq "fallback 22 on non-numeric Port value" "22"   "$(get_ssh_port "${cfg}")"

assert_eq "fallback 22 when config file missing"  "22"   "$(get_ssh_port "${TMP_DIR}/nope")"

# --------------------------------------------------------------------------
# add_ssh_port: per-firewall-tool dedup / no-miss behaviour
#
# Stubs below replace the host commands so behaviour is deterministic and
# independent of the machine running the tests.
# --------------------------------------------------------------------------

# Detected SSH port is injected via a stubbed lookup for branch tests.
get_ssh_port(){ printf '%s\n' "${STUB_SSH_PORT:-2222}"; }

# Record what add_firewall_rule would have opened, instead of touching the host.
add_firewall_rule(){ ADDED_RULES="${ADDED_RULES:-}${ADDED_RULES:+ }$1/$2"; }

# Listing-command stubs: print whatever the test pre-loaded for that tool.
firewall-cmd(){ case "$*" in *"--list-ports"*) printf '%s\n' "${STUB_FWCMD_OUT:-}" ;; esac; return 0; }
ufw(){          case "${1:-}" in status)       printf '%s\n' "${STUB_UFW_OUT:-}"   ;; esac; return 0; }
iptables(){     case "$*" in *"-L INPUT"*)     printf '%s\n' "${STUB_IPT_OUT:-}"   ;; esac; return 0; }
ip6tables(){ return 0; }

reset_stubs(){ STUB_FWCMD_OUT=''; STUB_UFW_OUT=''; STUB_IPT_OUT=''; ADDED_RULES=''; STUB_SSH_PORT=2222; }

# firewall-cmd: existing rule -> no duplicate
reset_stubs; FIREWALL_MANAGE_TOOL='firewall-cmd'; STUB_FWCMD_OUT='2222/tcp'
add_ssh_port
assert_eq "firewall-cmd: existing SSH rule not duplicated" "" "${ADDED_RULES}"

# firewall-cmd: missing rule -> added on real port
reset_stubs; FIREWALL_MANAGE_TOOL='firewall-cmd'
add_ssh_port
assert_eq "firewall-cmd: missing SSH rule added on real port" "2222/tcp" "${ADDED_RULES}"

# ufw: existing rule (port form) -> no duplicate
reset_stubs; FIREWALL_MANAGE_TOOL='ufw'; STUB_UFW_OUT='2222/tcp ALLOW Anywhere'
add_ssh_port
assert_eq "ufw: existing SSH rule not duplicated" "" "${ADDED_RULES}"

# ufw: existing rule (OpenSSH profile form) -> no duplicate
reset_stubs; FIREWALL_MANAGE_TOOL='ufw'; STUB_UFW_OUT='OpenSSH ALLOW Anywhere'
add_ssh_port
assert_eq "ufw: existing OpenSSH profile not duplicated" "" "${ADDED_RULES}"

# ufw: missing rule -> added on real port
reset_stubs; FIREWALL_MANAGE_TOOL='ufw'
add_ssh_port
assert_eq "ufw: missing SSH rule added on real port" "2222/tcp" "${ADDED_RULES}"

# iptables: existing rule (numeric port) -> no duplicate
reset_stubs; FIREWALL_MANAGE_TOOL='iptables'
STUB_IPT_OUT='1 ACCEPT tcp -- 0.0.0.0/0 0.0.0.0/0 tcp dpt:2222'
add_ssh_port
assert_eq "iptables: existing SSH rule not duplicated" "" "${ADDED_RULES}"

# iptables: default port 22 rendered as service name 'ssh' -> no duplicate
reset_stubs; FIREWALL_MANAGE_TOOL='iptables'; STUB_SSH_PORT=22
STUB_IPT_OUT='1 ACCEPT tcp -- 0.0.0.0/0 0.0.0.0/0 tcp dpt:ssh'
add_ssh_port
assert_eq "iptables: default port shown as ssh not duplicated" "" "${ADDED_RULES}"

# iptables: missing rule -> added on real port
reset_stubs; FIREWALL_MANAGE_TOOL='iptables'
add_ssh_port
assert_eq "iptables: missing SSH rule added on real port" "2222/tcp" "${ADDED_RULES}"

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
