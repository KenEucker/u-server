#!/usr/bin/env bash
# scripts/90-verify.sh - End-to-end verification of the installed platform.
#
# Checks the acceptance criteria directly rather than trusting that earlier
# stages reported success: DNS answers, Traefik routes, apps respond.
#
# Exit status: 0 all good, 1 something is broken.
#
# Runnable standalone:  sudo scripts/90-verify.sh

US_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"
# shellcheck source=lib/config.sh
source "${US_LIB_DIR}/config.sh"
# shellcheck source=lib/docker.sh
source "${US_LIB_DIR}/docker.sh"
# shellcheck source=lib/versions.sh
source "${US_LIB_DIR}/versions.sh"
# shellcheck source=lib/runtipi.sh
source "${US_LIB_DIR}/runtipi.sh"
# shellcheck source=lib/adguard.sh
source "${US_LIB_DIR}/adguard.sh"

us_init "verify"
us_config_load

failures=0
note_fail() {
  us_status_fail "$1"
  failures=$((failures + 1))
}

us_section "Verification"

# --- Host ------------------------------------------------------------------
printf '\nHOST\n' >&2
if docker info >/dev/null 2>&1; then
  us_status_ok "Docker Engine $(us_docker_version)"
else
  note_fail "Docker is not responding"
fi

if us_docker_container_healthy runtipi; then
  us_status_ok "Runtipi $(us_runtipi_installed_version 2>/dev/null || echo '')"
else
  note_fail "Runtipi container is not healthy"
fi

if us_docker_container_healthy runtipi-reverse-proxy; then
  us_status_ok "Traefik reverse proxy"
else
  note_fail "Traefik (runtipi-reverse-proxy) is not healthy"
fi

# --- DNS -------------------------------------------------------------------
printf '\nDNS\n' >&2
if us_config_is_true "$INSTALL_ADGUARD"; then
  if us_adguard_reachable; then
    us_status_ok "AdGuard control API"
  else
    note_fail "AdGuard is not responding on $(us_adguard_base_url)"
  fi

  # A random name proves the wildcard, not a cached specific record.
  probe="verify-$(date +%s).${LOCAL_DOMAIN}"
  for name in "$LOCAL_DOMAIN" "$DNS_DOMAIN" "$probe"; do
    if us_adguard_verify_resolution "$name"; then
      us_status_ok "${name} -> ${LAN_IP}"
    else
      note_fail "${name} did not resolve to ${LAN_IP}"
    fi
  done
else
  us_status_skip "AdGuard not installed (INSTALL_ADGUARD=false)"
fi

# --- Routing ---------------------------------------------------------------
# Host header is set explicitly and the request aimed at LAN_IP, so this tests
# Traefik rather than whatever the local resolver happens to do.
printf '\nROUTES\n' >&2
check_route() {
  local host="$1" label="$2" code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Host: ${host}" "http://${LAN_IP}/" 2>/dev/null || echo 000)"
  case "$code" in
    200 | 301 | 302 | 303 | 307 | 308 | 401 | 403)
      us_status_ok "http://${host} (HTTP ${code}) ${label}"
      ;;
    000)
      note_fail "http://${host} did not respond ${label}"
      ;;
    404)
      note_fail "http://${host} returned 404 — no Traefik route matched ${label}"
      ;;
    *)
      us_status_warn "http://${host} returned HTTP ${code} ${label}"
      ;;
  esac
}

check_route "$LOCAL_DOMAIN" "(Runtipi dashboard)"
us_config_is_true "$INSTALL_ADGUARD" && check_route "$DNS_DOMAIN" "(AdGuard)"

# --- Summary ---------------------------------------------------------------
printf '\n' >&2
if ((failures == 0)); then
  us_ok "All verification checks passed."
  exit 0
fi

us_error "${failures} verification check(s) failed."
us_error "Run ./doctor.sh for deeper diagnostics."
exit 1
