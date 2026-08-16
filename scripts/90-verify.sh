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
# shellcheck source=lib/tls.sh
source "${US_LIB_DIR}/tls.sh"

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

# --- TLS -------------------------------------------------------------------
# Those routes answer 301 because Traefik redirects to HTTPS unconditionally,
# so what the TLS side presents is part of whether the platform works, not an
# optional extra.
printf '\nTLS\n' >&2
if ! us_config_is_true "$ENABLE_LOCAL_HTTPS"; then
  us_status_skip "local CA disabled; Traefik serves Runtipi's self-signed certificate"
  printf '    Browsers will warn on every service. See docs/https.md.\n' >&2
else
  if [[ -f "$US_TLS_CA_CRT" ]]; then
    us_status_ok "Local CA present ($(us_tls_days_remaining "$US_TLS_CA_CRT") days left)"
  else
    note_fail "ENABLE_LOCAL_HTTPS is true but there is no CA at ${US_TLS_CA_CRT}"
  fi

  if leaf_days="$(us_tls_days_remaining "$US_TLS_LEAF_CRT" 2>/dev/null)"; then
    # Under 1 day is the cliff: Runtipi's own -checkend 86400 test starts
    # failing there and it overwrites our certificate with a self-signed one.
    if ((leaf_days < 1)); then
      note_fail "Server certificate has under a day left; Runtipi will replace it with a self-signed one"
    elif ((leaf_days < US_TLS_RENEW_BEFORE_DAYS)); then
      us_status_warn "Server certificate expires in ${leaf_days} day(s); renewal is overdue"
      printf '    Check the timer:  systemctl status %s.timer\n' "$US_TLS_RENEW_UNIT" >&2
    else
      us_status_ok "Server certificate valid for ${leaf_days} more day(s)"
    fi
  else
    note_fail "No server certificate at ${US_TLS_LEAF_CRT}"
  fi

  issuer="$(us_tls_served_issuer "$LAN_IP" "$LOCAL_DOMAIN" 2>/dev/null || true)"
  if [[ "$issuer" == *"${US_PROJECT_NAME} Local CA"* ]]; then
    us_status_ok "Traefik is serving the local CA's certificate"
  elif [[ -n "$issuer" ]]; then
    note_fail "Traefik is serving a certificate issued by: ${issuer}"
    printf '    Expected the local CA. If Runtipi regenerated it, the marker file\n' >&2
    printf '    %s is missing.\n' "$(us_runtipi_tls_marker_file "$LOCAL_DOMAIN")" >&2
  else
    note_fail "Nothing answered TLS on ${LAN_IP}:443"
  fi

  if us_tls_https_trusted "$LAN_IP" "$LOCAL_DOMAIN"; then
    us_status_ok "https://${LOCAL_DOMAIN} verifies against the trust store"
  else
    us_status_warn "https://${LOCAL_DOMAIN} did not verify from this host"
  fi
fi

# --- Summary ---------------------------------------------------------------
printf '\n' >&2
if ((failures == 0)); then
  us_ok "All verification checks passed."
  exit 0
fi

us_error "${failures} verification check(s) failed."
us_error "Run ./doctor.sh for deeper diagnostics."
exit 1
