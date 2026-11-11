#!/usr/bin/env bash

# Run read-only maintenance checks for Hysteria2 and optional Xray servers.
# Installed usage: vpn-check [PUBLIC_IP] (hysteria-check remains an alias).
# Repository usage: bash scripts/check-status.sh [PUBLIC_IP_OR_DOMAIN]
#
# The script never restarts services, renews certificates, refreshes package
# metadata, installs updates, or changes configuration. Root is not required,
# although sudo may allow certificate and service details to be read.

set -uo pipefail

readonly SERVICE_NAME="hysteria-server"
readonly CONFIG_FILE="/etc/hysteria/config.yaml"
readonly HYSTERIA_BINARY="/usr/local/bin/hysteria"
readonly TARGET="${1:-}"
readonly TLS_WARNING_DAYS=30
readonly DISK_WARNING_PERCENT=80
readonly DISK_CRITICAL_PERCENT=90
readonly GREEN=$'\033[32m'
readonly CYAN=$'\033[36m'
readonly YELLOW=$'\033[33m'
readonly RED=$'\033[31m'
readonly RESET=$'\033[0m'

color_stdout=0
color_stderr=0

# Enable colors only for interactive output. Check stdout and stderr
# independently so redirecting either stream never adds escape sequences to it.
if [[ -z ${NO_COLOR+x} && ${TERM:-} != "dumb" ]]; then
  [[ -t 1 ]] && color_stdout=1
  [[ -t 2 ]] && color_stderr=1
fi

readonly color_stdout
readonly color_stderr

warnings=()
criticals=()

print_stdout_status() {
  local color=$1
  local label=$2
  local message=$3

  if [[ ${color_stdout} -eq 1 ]]; then
    printf '%s[%s]%s %s\n' "${color}" "${label}" "${RESET}" "${message}"
  else
    printf '[%s] %s\n' "${label}" "${message}"
  fi
}

print_stderr_status() {
  local color=$1
  local label=$2
  local message=$3

  if [[ ${color_stderr} -eq 1 ]]; then
    printf '%s[%s]%s %s\n' "${color}" "${label}" "${RESET}" "${message}" >&2
  else
    printf '[%s] %s\n' "${label}" "${message}" >&2
  fi
}

pass() {
  print_stdout_status "${GREEN}" "PASS" "$1"
}

info() {
  print_stdout_status "${CYAN}" "INFO" "$1"
}

warn() {
  print_stdout_status "${YELLOW}" "WARN" "$1"
  warnings+=("$1")
}

critical() {
  print_stderr_status "${RED}" "CRITICAL" "$1"
  criticals+=("$1")
}

print_findings() {
  local finding

  printf 'Findings:\n' >&2
  for finding in "${criticals[@]}"; do
    if [[ ${color_stderr} -eq 1 ]]; then
      printf -- '- %sCRITICAL:%s %s\n' "${RED}" "${RESET}" "${finding}" >&2
    else
      printf -- '- CRITICAL: %s\n' "${finding}" >&2
    fi
  done
  for finding in "${warnings[@]}"; do
    if [[ ${color_stderr} -eq 1 ]]; then
      printf -- '- %sWARNING:%s %s\n' "${YELLOW}" "${RESET}" "${finding}" >&2
    else
      printf -- '- WARNING: %s\n' "${finding}" >&2
    fi
  done
}

# Read the certificate path from the tls.cert field used by this project.
discover_certificate_path() {
  awk '
    /^[[:space:]]*(#|$)/ { next }
    {
      current_indent = match($0, /[^[:space:]]/) - 1
      if (!in_tls && $0 ~ /^[[:space:]]*tls:[[:space:]]*(#.*)?$/) {
        in_tls = 1
        tls_indent = current_indent
        next
      }
      if (in_tls && current_indent <= tls_indent) {
        exit
      }
      if (in_tls && $0 ~ /^[[:space:]]*cert:[[:space:]]*/) {
        value = $0
        sub(/^[[:space:]]*cert:[[:space:]]*/, "", value)
        sub(/[[:space:]]+#.*$/, "", value)
        sub(/[[:space:]]+$/, "", value)
        print value
        exit
      }
    }
  ' "${CONFIG_FILE}"
}

# GNU date is expected on Ubuntu; the BSD form also supports local review.
date_to_epoch() {
  local date_value=$1
  local epoch

  if epoch="$(date -d "${date_value}" +%s 2>/dev/null)"; then
    printf '%s\n' "${epoch}"
    return 0
  fi

  if epoch="$(date -j -f '%b %e %T %Y %Z' "${date_value}" +%s 2>/dev/null)"; then
    printf '%s\n' "${epoch}"
    return 0
  fi

  return 1
}

is_ipv4() {
  local address=$1
  local -a address_octets
  local octet
  local octet_value

  [[ ${address} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  IFS=. read -r -a address_octets <<<"${address}"
  for octet in "${address_octets[@]}"; do
    octet_value=$((10#${octet}))
    [[ ${octet_value} -le 255 ]] || return 1
  done
}

# Reject private, link-local, documentation, benchmark, multicast, and other
# special-use ranges so a cloud-provider private address is never accepted as
# the VPS public IPv4 address.
is_public_ipv4() {
  local address=$1
  local -a address_octets
  local first
  local second
  local third

  is_ipv4 "${address}" || return 1
  IFS=. read -r -a address_octets <<<"${address}"
  first=$((10#${address_octets[0]}))
  second=$((10#${address_octets[1]}))
  third=$((10#${address_octets[2]}))

  ((first != 0 && first != 10 && first != 127 && first < 224)) || return 1
  ((first != 100 || second < 64 || second > 127)) || return 1
  ((first != 169 || second != 254)) || return 1
  ((first != 172 || second < 16 || second > 31)) || return 1
  ((first != 192 || second != 0 || (third != 0 && third != 2))) || return 1
  ((first != 192 || second != 88 || third != 99)) || return 1
  ((first != 192 || second != 168)) || return 1
  ((first != 198 || (second != 18 && second != 19))) || return 1
  ((first != 198 || second != 51 || third != 100)) || return 1
  ((first != 203 || second != 0 || third != 113)) || return 1
}

fetch_public_ipv4() {
  local endpoint=$1

  if command -v curl >/dev/null 2>&1; then
    if curl --ipv4 --fail --silent --connect-timeout 2 --max-time 3 "${endpoint}" 2>/dev/null; then
      return 0
    fi
  fi

  if command -v wget >/dev/null 2>&1; then
    if wget -4 --quiet --timeout=3 --tries=1 --output-document=- "${endpoint}" 2>/dev/null; then
      return 0
    fi
  fi

  return 1
}

detect_public_ipv4() {
  local candidate
  local endpoint

  for endpoint in "https://api.ipify.org" "https://checkip.amazonaws.com"; do
    if candidate="$(fetch_public_ipv4 "${endpoint}")"; then
      candidate="$(tr -d '[:space:]' <<<"${candidate}")"
      if is_public_ipv4 "${candidate}"; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    fi
  done

  return 1
}

check_listener_owner() {
  local protocol=$1 expected=$2 sockets
  if ! command -v ss >/dev/null 2>&1; then
    warn "${protocol} 443 ownership: ss is unavailable."
    return
  fi
  local flag=-t
  [[ ${protocol} == UDP ]] && flag=-u
  if ! sockets="$(ss -H -l -n -p "${flag}" 'sport = :443' 2>/dev/null)"; then
    warn "${protocol} 443 ownership: unable to inspect local sockets."
  elif [[ -z ${sockets} ]]; then
    critical "${protocol} 443: no local listener."
  elif [[ ${sockets} == *\"${expected}\"* ]]; then
    pass "${protocol} 443: local listener belongs to ${expected}; external reachability is not tested."
  elif [[ ${sockets} != *'users:('* ]]; then
    warn "${protocol} 443: listener exists, but process ownership is unavailable; use sudo."
  else
    critical "${protocol} 443: expected ${expected} process was not found."
  fi
}

check_service_errors() {
  local unit=$1 count
  if [[ ${EUID} -ne 0 ]] || ! command -v journalctl >/dev/null 2>&1; then
    warn "${unit} logs: unable to verify full journal access; use sudo with journalctl installed."
  elif count="$(journalctl -q -u "${unit}" --since '24 hours ago' -p err --no-pager -o json 2>/dev/null | awk 'END {print NR+0}')"; then
    if [[ ${count} -gt 0 ]]; then
      warn "${unit} logs: ${count} error-level entries in the available journal for the last 24 hours; review privately."
    else
      info "${unit} logs: no error-level entries in the available journal for the last 24 hours; retention may be incomplete."
    fi
  else
    warn "${unit} logs: journal could not be queried."
  fi
}

check_xray_config() {
  local binary=$1 config=$2
  if [[ ! -r ${config} ]]; then
    warn 'Xray configuration: standard configuration is missing or unreadable; use sudo or verify custom deployment paths.'
  elif "${binary}" run -test -config "${config}" >/dev/null 2>&1; then
    pass 'Xray configuration: standard config.json validation passed (not an end-to-end connection test).'
  else
    critical 'Xray configuration: validation failed; inspect privately. Diagnostic output was suppressed.'
  fi
}

check_xray() {
  local state version
  if ! command -v systemctl >/dev/null 2>&1 || ! state="$(systemctl show xray.service -p LoadState --value 2>/dev/null)"; then
    warn 'Xray: service installation could not be verified.'
    return
  fi
  if [[ ${state} == not-found ]]; then
    info 'Xray: not installed; optional for Hysteria2-only deployments.'
    return
  elif [[ ${state} != loaded ]]; then
    warn 'Xray: service unit is unavailable or not loaded.'
    return
  fi
  if systemctl is-active --quiet xray.service 2>/dev/null; then
    pass 'Xray: xray.service is active.'
  else
    critical 'Xray: installed service is not active.'
  fi
  check_listener_owner TCP xray
  if [[ ! -x /usr/local/bin/xray ]]; then
    warn 'Xray version/configuration: expected binary /usr/local/bin/xray is unavailable.'
  else
    version="$(/usr/local/bin/xray version 2>/dev/null | head -n 1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
    if [[ -n ${version} ]]; then
      info "Xray version: ${version}."
    else
      warn 'Xray version: unable to determine.'
    fi
    check_xray_config /usr/local/bin/xray /usr/local/etc/xray/config.json
  fi
  info 'Xray REALITY: no ordinary local TLS certificate check is applied.'
  check_service_errors xray.service
}

check_system_resources() {
  local value
  if [[ -r /proc/uptime ]]; then
    value="$(awk '{printf "%.0f", $1/3600}' /proc/uptime)"
    info "Uptime: approximately ${value} hour(s)."
  else
    warn 'Uptime: unavailable.'
  fi
  if [[ -r /proc/loadavg ]]; then
    value="$(awk '{print $1, $2, $3}' /proc/loadavg)"
    info "CPU load averages (1/5/15 minutes): ${value}; load is not CPU utilization."
  else
    warn 'CPU load: unavailable.'
  fi
  value="$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2; found=1} END {if(t>0 && found) printf "%.0f", (t-a)*100/t}' /proc/meminfo 2>/dev/null)"
  if [[ ${value} =~ ^[0-9]+$ ]]; then
    if ((value >= 90)); then warn "Memory: ${value}% used (MemAvailable basis)."; else pass "Memory: ${value}% used (MemAvailable basis)."; fi
  else
    warn 'Memory: available-memory statistics could not be read.'
  fi
  if ! command -v ip >/dev/null 2>&1; then
    warn 'Default IPv4 route: ip command unavailable.'
  elif value="$(ip -4 route show default 2>/dev/null)"; then
    if [[ -n ${value} ]]; then
      pass 'Default IPv4 route: present; external reachability is not tested.'
    else
      critical 'Default IPv4 route: absent.'
    fi
  else
    warn 'Default IPv4 route: unable to inspect.'
  fi
}

printf 'VPN maintenance status\n'
printf 'Read-only diagnostics; sudo may reveal additional details.\n\n'
printf 'Hysteria2 / TLS\n'

# 1. Hysteria2 systemd service state.
if ! command -v systemctl >/dev/null 2>&1; then
  warn "Service status: unable to determine because systemctl is unavailable."
else
  service_load_state="$(systemctl show "${SERVICE_NAME}.service" --property=LoadState --value 2>/dev/null)"
  service_show_status=$?

  if [[ ${service_show_status} -ne 0 ]]; then
    warn "Service status: systemd could not provide the service state."
  elif [[ ${service_load_state} == "not-found" || -z ${service_load_state} ]]; then
    critical "Service status: ${SERVICE_NAME}.service was not found."
  elif systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    pass "Service status: ${SERVICE_NAME}.service is active."
  else
    service_active_state="$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true)"
    critical "Service status: ${SERVICE_NAME}.service is ${service_active_state:-not active}."
  fi
fi

# 2. Local UDP 443 listener. This does not prove external reachability.
if ! command -v ss >/dev/null 2>&1; then
  warn "UDP 443: unable to inspect listeners because ss is unavailable."
elif socket_output="$(ss -H -lun 2>/dev/null)"; then
  if grep -Eq '(^|[[:space:]])[^[:space:]]*:443([[:space:]]|$)' <<<"${socket_output}"; then
    pass "UDP 443: a local listening socket was found."
  else
    critical "UDP 443: no local listening socket was found."
  fi
else
  warn "UDP 443: unable to inspect local listening sockets."
fi

# 3. Certificate used by the configured Hysteria2 server.
certificate_path=""
if [[ ! -e ${CONFIG_FILE} ]]; then
  critical "TLS certificate: ${CONFIG_FILE} was not found."
elif [[ ! -r ${CONFIG_FILE} ]]; then
  warn "TLS certificate: ${CONFIG_FILE} is unreadable; sudo may provide access."
else
  certificate_path="$(discover_certificate_path)"
  certificate_path="${certificate_path#\"}"
  certificate_path="${certificate_path%\"}"
  certificate_path="${certificate_path#\'}"
  certificate_path="${certificate_path%\'}"

  if [[ -z ${certificate_path} ]]; then
    critical "TLS certificate: no tls.cert path was found in ${CONFIG_FILE}."
  elif [[ ${certificate_path} != /* ]]; then
    critical "TLS certificate: the configured certificate path is not absolute."
  elif [[ ! -r ${certificate_path} ]]; then
    warn "TLS certificate: the configured certificate file is unreadable or missing; unable to verify."
  elif ! command -v openssl >/dev/null 2>&1; then
    warn "TLS certificate: unable to inspect it because openssl is unavailable."
  else
    certificate_end_line="$(openssl x509 -noout -enddate -in "${certificate_path}" 2>/dev/null)"
    certificate_read_status=$?
    certificate_end_date="${certificate_end_line#notAfter=}"

    if [[ ${certificate_read_status} -ne 0 || -z ${certificate_end_date} || ${certificate_end_date} == "${certificate_end_line}" ]]; then
      critical "TLS certificate: the configured certificate could not be parsed."
    elif certificate_end_epoch="$(date_to_epoch "${certificate_end_date}")"; then
      current_epoch="$(date +%s)"
      seconds_remaining=$((certificate_end_epoch - current_epoch))

      if [[ ${seconds_remaining} -le 0 ]]; then
        critical "TLS certificate: expired."
      else
        days_remaining=$((seconds_remaining / 86400))
        if [[ ${days_remaining} -le ${TLS_WARNING_DAYS} ]]; then
          warn "TLS certificate: valid, but only ${days_remaining} day(s) remain."
        else
          pass "TLS certificate: valid for approximately ${days_remaining} more day(s)."
        fi
      fi
    elif openssl x509 -checkend 0 -noout -in "${certificate_path}" >/dev/null 2>&1; then
      info "TLS certificate: valid, but remaining days could not be calculated."
    else
      critical "TLS certificate: expired or unreadable."
    fi
  fi
fi

# 4. Active Certbot systemd renewal timer. No renewal is attempted.
if ! command -v certbot >/dev/null 2>&1; then
  warn "Certbot renewal: certbot is unavailable."
elif ! command -v systemctl >/dev/null 2>&1; then
  warn "Certbot renewal: unable to inspect timers because systemctl is unavailable."
elif timer_units="$(systemctl list-unit-files --type=timer --no-legend --no-pager 2>/dev/null | awk '$1 ~ /certbot/ && $1 ~ /\.timer$/ { print $1 }')"; then
  if [[ -z ${timer_units} ]]; then
    warn "Certbot renewal: no Certbot systemd timer was found."
  else
    active_timer=""
    while IFS= read -r timer_unit; do
      if systemctl is-active --quiet "${timer_unit}" 2>/dev/null; then
        active_timer="${timer_unit}"
        break
      fi
    done <<<"${timer_units}"

    if [[ -n ${active_timer} ]]; then
      pass "Certbot renewal: ${active_timer} is active."
    else
      warn "Certbot renewal: Certbot timer unit(s) exist, but none are active."
    fi
  fi
else
  warn "Certbot renewal: systemd timer state could not be read."
fi

# 5. Pending Ubuntu security updates from existing local APT metadata only.
printf '\nSystem / Security\n'
os_id="unknown"
os_pretty_name="Unknown"
if [[ -r /etc/os-release ]]; then
  os_id="$(awk -F= '$1 == "ID" { value=$2; gsub(/^"|"$/, "", value); print value; exit }' /etc/os-release)"
  os_pretty_name="$(awk -F= '$1 == "PRETTY_NAME" { value=substr($0, index($0, "=") + 1); gsub(/^"|"$/, "", value); print value; exit }' /etc/os-release)"
fi

apt_metadata_found=0
if [[ -d /var/lib/apt/lists ]]; then
  for apt_metadata_file in /var/lib/apt/lists/*_Packages* /var/lib/apt/lists/*_InRelease; do
    if [[ -f ${apt_metadata_file} ]]; then
      apt_metadata_found=1
      break
    fi
  done
fi

if [[ ${os_id} != "ubuntu" ]]; then
  info "Security updates: not classified because this system is not detected as Ubuntu."
elif ! command -v apt >/dev/null 2>&1; then
  info "Security updates: unavailable because apt is not installed."
elif [[ ${apt_metadata_found} -eq 0 ]]; then
  info "Security updates: unavailable because local APT metadata was not found."
elif apt_output="$(apt list --upgradable 2>/dev/null)"; then
  security_update_count="$(awk 'NR > 1 && /-security/ { count++ } END { print count + 0 }' <<<"${apt_output}")"
  if [[ ${security_update_count} -gt 0 ]]; then
    warn "Security updates: ${security_update_count} pending update(s) shown by local APT metadata."
  else
    pass "Security updates: none shown by local APT metadata."
  fi
else
  info "Security updates: local APT metadata could not be read."
fi

# 6. Ubuntu/Debian reboot-required marker.
if [[ ${os_id} == "ubuntu" || ${os_id} == "debian" ]]; then
  if [[ -e /var/run/reboot-required ]]; then
    warn "Reboot: required by installed updates."
  else
    pass "Reboot: no reboot-required marker is present."
  fi
else
  info "Reboot: the Ubuntu/Debian reboot marker is not applicable."
fi

# 7. Root filesystem use.
disk_usage="$(df -P / 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"
if [[ ! ${disk_usage} =~ ^[0-9]+$ ]]; then
  warn "Root filesystem: usage could not be determined."
elif [[ ${disk_usage} -ge ${DISK_CRITICAL_PERCENT} ]]; then
  critical "Root filesystem: ${disk_usage}% used."
elif [[ ${disk_usage} -ge ${DISK_WARNING_PERCENT} ]]; then
  warn "Root filesystem: ${disk_usage}% used."
else
  pass "Root filesystem: ${disk_usage}% used."
fi

# 8. Operating system version.
info "Operating system: ${os_pretty_name:-Unknown}."

# 9. Locally installed Hysteria2 version. No network lookup is performed.
hysteria_command=""
if [[ -x ${HYSTERIA_BINARY} ]]; then
  hysteria_command="${HYSTERIA_BINARY}"
elif command -v hysteria >/dev/null 2>&1; then
  hysteria_command="$(command -v hysteria)"
fi

if [[ -z ${hysteria_command} ]]; then
  warn "Hysteria2 version: installed binary was not found."
elif hysteria_version_output="$("${hysteria_command}" version 2>&1)"; then
  hysteria_version="$(grep -Eom 1 'v?[0-9]+\.[0-9]+\.[0-9]+([+-][^[:space:]]+)?' <<<"${hysteria_version_output}")"
  if [[ -n ${hysteria_version} ]]; then
    info "Hysteria2 version: ${hysteria_version}."
  else
    info "Hysteria2 version: installed, but the version string was not recognized."
  fi
else
  info "Hysteria2 version: installed, but the version could not be determined."
fi

# 10. Detect or validate the public IPv4. Domain arguments retain the existing
# DNS-resolution behavior for backward compatibility.
printf '\nNetwork / Service logs\n'
if [[ -z ${TARGET} ]]; then
  if detect_public_ipv4 >/dev/null; then
    pass "Public IPv4: detected automatically."
  else
    critical "Public IPv4: automatic detection failed. Run: hysteria-check <PUBLIC_IP>"
  fi
elif is_public_ipv4 "${TARGET}"; then
  pass "Public IPv4: the manually supplied address is valid."
elif is_ipv4 "${TARGET}" || [[ ${TARGET} =~ ^[0-9.]+$ ]]; then
  critical "Public IPv4: the supplied address is invalid or not publicly routable."
elif ! command -v dig >/dev/null 2>&1; then
  warn "DNS resolution: unable to check the supplied domain because dig is unavailable."
elif dns_output="$(dig +short "${TARGET}" 2>/dev/null)"; then
  if [[ -n ${dns_output} ]]; then
    pass "DNS resolution: the supplied domain returned a record."
  else
    critical "DNS resolution: the supplied domain returned no records."
  fi
else
  critical "DNS resolution: lookup failed for the supplied domain."
fi

check_listener_owner UDP hysteria
check_service_errors hysteria-server.service
printf '\nXray / REALITY\n'
check_xray
printf '\nSystem / Network\n'
check_system_resources

printf '\n'
if [[ ${#criticals[@]} -gt 0 ]]; then
  if [[ ${color_stderr} -eq 1 ]]; then
    printf 'Overall status: %sCRITICAL (%d critical, %d warning)%s\n' "${RED}" "${#criticals[@]}" "${#warnings[@]}" "${RESET}" >&2
  else
    printf 'Overall status: CRITICAL (%d critical, %d warning)\n' "${#criticals[@]}" "${#warnings[@]}" >&2
  fi
  print_findings
  exit 1
fi

if [[ ${#warnings[@]} -gt 0 ]]; then
  if [[ ${color_stderr} -eq 1 ]]; then
    printf 'Overall status: %sATTENTION REQUIRED (%d warning)%s\n' "${YELLOW}" "${#warnings[@]}" "${RESET}" >&2
  else
    printf 'Overall status: ATTENTION REQUIRED (%d warning)\n' "${#warnings[@]}" >&2
  fi
  print_findings
  exit 1
fi

if [[ ${color_stdout} -eq 1 ]]; then
  printf 'Overall status: %sHEALTHY%s\n' "${GREEN}" "${RESET}"
else
  printf 'Overall status: HEALTHY\n'
fi
exit 0
