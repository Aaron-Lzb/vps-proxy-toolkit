#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "${fixture}"' EXIT
# Load production functions without executing host diagnostics.
sed '/^printf '\''VPN maintenance status/,$d' "${root}/scripts/check-status.sh" >"${fixture}/functions.sh"
# shellcheck disable=SC1091
source "${fixture}/functions.sh"
systemctl() {
  case "$1" in
    show) printf '%s\n' "${mock_load}" ;;
    is-active) return "${mock_active}" ;;
  esac
}
ss() { printf '%s\n' "${mock_socket}"; }
check_service_errors() { :; }
mock_load=not-found
mock_active=0
mock_socket='LISTEN 0 4096 *:443 *:* users:(("xray",pid=1,fd=3))'
output="$(check_xray)"
[[ ${output} == *'not installed; optional'* ]]
mock_load=loaded
output="$(check_xray 2>&1)"
[[ ${output} == *'[PASS] Xray: xray.service is active.'* ]]
[[ ${output} == *'local listener belongs to xray'* ]]
mock_active=1
output="$(check_xray 2>&1)"
[[ ${output} == *'[CRITICAL] Xray: installed service is not active.'* ]]
mock_load=''
output="$(check_xray)"
[[ ${output} == *'[WARN] Xray: service unit is unavailable'* ]]
mock_socket='LISTEN 0 4096 *:443 *:*'
output="$(check_listener_owner TCP xray)"
[[ ${output} == *'[WARN]'* && ${output} == *'ownership is unavailable'* ]]
mock_socket='UNCONN 0 0 *:443 *:* users:(("hysteria",pid=1,fd=3))'
output="$(check_listener_owner UDP hysteria)"
[[ ${output} == *'[PASS]'* ]]
output="$(check_listener_owner TCP xray 2>&1)"
[[ ${output} == *'[CRITICAL]'* ]]
mock_socket=''
output="$(check_listener_owner UDP hysteria 2>&1)"
[[ ${output} == *'[CRITICAL]'* ]]
printf 'VPN service and listener checks passed.\n'
mock_xray() { printf 'SENSITIVE TEST SENTINEL\n'; return "${mock_validation}"; }
mock_validation=0
output="$(check_xray_config mock_xray "${fixture}/functions.sh" 2>&1)"
[[ ${output} == *'[PASS]'* && ${output} != *SENTINEL* ]]
mock_validation=1
output="$(check_xray_config mock_xray "${fixture}/functions.sh" 2>&1)"
[[ ${output} == *'[CRITICAL]'* && ${output} != *SENTINEL* ]]
output="$(check_xray_config mock_xray "${fixture}/absent" 2>&1)"
[[ ${output} == *'[WARN]'* ]]
printf 'Configuration validation and output privacy checks passed.\n'
