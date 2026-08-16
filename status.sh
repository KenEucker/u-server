#!/usr/bin/env bash
# status.sh - Concise operational state of the platform.
#
# Read-only. Runs without root where Docker permits it.
# Exit status: 0 healthy, 1 something needs attention.

set -Eeuo pipefail

US_ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
US_LIB_DIR="${US_ROOT_DIR}/lib"
# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"
# shellcheck source=lib/config.sh
source "${US_LIB_DIR}/config.sh"
# shellcheck source=lib/versions.sh
source "${US_LIB_DIR}/versions.sh"
# shellcheck source=lib/docker.sh
source "${US_LIB_DIR}/docker.sh"
# shellcheck source=lib/runtipi.sh
source "${US_LIB_DIR}/runtipi.sh"
# shellcheck source=lib/adguard.sh
source "${US_LIB_DIR}/adguard.sh"

us_init "status"
us_config_load

problems=0
fail() {
  us_status_fail "$1"
  problems=$((problems + 1))
}

if ! docker info >/dev/null 2>&1; then
  if [[ "$(id -u)" -ne 0 ]]; then
    us_error "Cannot reach Docker as $(id -un). Try: sudo ./status.sh"
    exit 1
  fi
fi

printf '\nu-server status  (%s)\n' "$(us_timestamp)"
printf '%s\n' "-------------------------------------------------------"

# --- HOST ------------------------------------------------------------------
printf '\nHOST\n'
if docker info >/dev/null 2>&1; then
  us_status_ok "Docker $(us_docker_version)"
else
  fail "Docker is not responding"
fi

if us_docker_container_healthy runtipi; then
  us_status_ok "Runtipi $(us_version_installed runtipi 2>/dev/null || echo '')"
else
  fail "Runtipi is not healthy"
fi

if us_docker_container_healthy runtipi-reverse-proxy; then
  us_status_ok "Traefik"
else
  fail "Traefik is not healthy"
fi

if us_config_is_true "$INSTALL_ADGUARD"; then
  if us_adguard_reachable; then
    us_status_ok "AdGuard Home"
  else
    fail "AdGuard is not responding"
  fi

  if [[ -z "$(us_port_listener 53 udp || true)" ]]; then
    fail "Nothing is listening on 53/udp"
  else
    us_status_ok "DNS port 53/udp bound"
  fi
else
  us_status_skip "AdGuard not installed"
fi

# Disk pressure on the filesystem holding app data.
root_fs="${RUNTIPI_ROOT:-/opt/runtipi}"
[[ -d "$root_fs" ]] || root_fs="/"
use_pct="$(df -P "$root_fs" | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
avail="$(df -Ph "$root_fs" | awk 'NR==2{print $4}')"
if ((use_pct >= 90)); then
  fail "Disk ${use_pct}% used on $(df -P "$root_fs" | awk 'NR==2{print $6}') (${avail} free)"
elif ((use_pct >= 80)); then
  us_status_warn "Disk ${use_pct}% used (${avail} free)"
else
  us_status_ok "Disk ${use_pct}% used (${avail} free)"
fi

# --- DNS -------------------------------------------------------------------
printf '\nDNS\n'
if us_config_is_true "$INSTALL_ADGUARD"; then
  probe="status-$(date +%s).${LOCAL_DOMAIN}"
  for name in "$LOCAL_DOMAIN" "$DNS_DOMAIN" "$probe"; do
    if us_adguard_verify_resolution "$name"; then
      us_status_ok "${name} -> ${LAN_IP}"
    else
      fail "${name} does not resolve to ${LAN_IP}"
    fi
  done
else
  us_status_skip "wildcard DNS not managed here"
fi

# --- APPS ------------------------------------------------------------------
printf '\nAPPS\n'
if apps_json="$(us_runtipi_api GET "apps/installed" 2>/dev/null)"; then
  count="$(printf '%s' "$apps_json" | jq '.installed | length')"
  if ((count == 0)); then
    us_status_skip "no apps installed"
  else
    while IFS=$'\t' read -r urn state; do
      [[ -n "$urn" ]] || continue
      case "$state" in
        running) us_status_ok "${urn} (${state})" ;;
        stopped) us_status_skip "${urn} (${state})" ;;
        *)
          us_status_warn "${urn} (${state})"
          ;;
      esac
    done < <(printf '%s' "$apps_json" |
      jq -r '.installed[]? | "\(.app.urn)\t\(.app.status)"')
  fi
else
  us_status_warn "could not query the Runtipi API for installed apps"
fi

# --- ROUTES ----------------------------------------------------------------
printf '\nROUTES\n'
route_check() {
  local host="$1" code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 \
    -H "Host: ${host}" "http://${LAN_IP}/" 2>/dev/null || echo 000)"
  case "$code" in
    000) fail "http://${host} no response" ;;
    404) fail "http://${host} no route matched (404)" ;;
    2* | 3* | 401 | 403) us_status_ok "http://${host} (${code})" ;;
    *) us_status_warn "http://${host} (${code})" ;;
  esac
}

route_check "$LOCAL_DOMAIN"
us_config_is_true "$INSTALL_ADGUARD" && route_check "$DNS_DOMAIN"

# --- Summary ---------------------------------------------------------------
printf '\n'
if ((problems == 0)); then
  us_ok "Platform healthy."
  exit 0
fi
us_error "${problems} problem(s). Run ./doctor.sh for detail."
exit 1
