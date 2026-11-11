#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "${fixture}"' EXIT
sed '/^printf '\''VPN maintenance status/,$d' "${root}/scripts/check-status.sh" >"${fixture}/functions.sh"
# shellcheck disable=SC1091
source "${fixture}/functions.sh"
command() { if [[ $1 == -v && $2 == vnstat && ${installed} == no ]]; then return 1; fi; builtin command "$@"; }
vnstat() { printf '%s\n' "${sample}"; return "${sample_status}"; }
ip() { printf '%s\n' 'default via 192.0.2.1 dev eth0'; }
systemctl() { return "${service_status}"; }
installed=no
sample=''
sample_status=0
service_status=0
output="$(check_network_traffic)"
[[ ${output} == *'[INFO]'*'not installed'* ]]
installed=yes
service_status=1
output="$(check_network_traffic)"
[[ ${output} == *'[WARN]'*'not active'* ]]
service_status=0
sample='1;eth0;2026-11-11;12.34 MiB;56.78 MiB;69.12 MiB;1 kbit/s;2026-11;1.25 GiB;2.50 GiB;3.75 GiB;1 kbit/s;1 GiB;2 GiB;3 GiB'
output="$(check_network_traffic)"
[[ ${output} == *'[PASS]'* && ${output} == *'today RX 12.34 MiB, TX 56.78 MiB'* && ${output} == *'this month RX 1.25 GiB, TX 2.50 GiB'* ]]
sample='eth0: No data. Timestamp of last update is same as of database creation.'
sample_status=1
output="$(check_network_traffic)"
[[ ${output} == *'[INFO]'*'no history yet'* && ${output} != *'[WARN]'* ]]
sample='database is unavailable'
output="$(check_network_traffic)"
[[ ${output} == *'[WARN]'*'cannot query'* ]]
sample='unexpected output'
sample_status=0
output="$(check_network_traffic)"
[[ ${output} == *'[WARN]'*'unrecognized'* ]]
printf 'vnStat diagnostic checks passed.\n'
