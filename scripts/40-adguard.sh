#!/usr/bin/env bash
# scripts/40-adguard.sh - Free port 53 and install AdGuard Home as a Runtipi app.
#
# PORT 53 AND THE BOOTSTRAP LOOP
# ------------------------------
# Ubuntu Server runs systemd-resolved, which binds a stub listener on
# 127.0.0.53:53. AdGuard needs :53 on all addresses, so the stub must go.
#
# The trap is that naively pointing the host at AdGuard at the same moment
# creates a loop: AdGuard is a container, pulling its image needs DNS, and DNS
# would be the container that has not started yet.
#
# So this is done in two phases:
#   here (40)  disable ONLY the stub listener and leave the host resolving
#              through systemd-resolved's real upstreams. Port 53 is freed and
#              the host never loses name resolution.
#   later (50) once AdGuard is verified answering, repoint the host at it with
#              the upstreams retained as FallbackDNS.
#
# Runnable standalone:  sudo scripts/40-adguard.sh

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

us_init "adguard"
us_require_root
us_config_load

us_section "AdGuard Home"

if ! us_config_is_true "$INSTALL_ADGUARD"; then
  us_info "INSTALL_ADGUARD is false; skipping."
  exit 0
fi

US_RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/60-${US_PROJECT_NAME}.conf"

# --- Phase 1: free port 53 -------------------------------------------------
free_port_53() {
  local holder
  holder="$(us_port_listener 53 udp || true)"

  if [[ -z "$holder" ]]; then
    us_ok "Port 53/udp is already free"
    return 0
  fi

  if [[ "$holder" == *docker* ]]; then
    us_ok "Port 53/udp is held by Docker (AdGuard already installed)"
    return 0
  fi

  if [[ "$holder" != *systemd-resolve* ]]; then
    us_die "Port 53/udp is held by '${holder}', which u-server will not touch. Stop it and rerun."
  fi

  if ! us_config_is_true "$DISABLE_RESOLVED_STUB"; then
    us_die "systemd-resolved holds port 53 but DISABLE_RESOLVED_STUB=false. Free it yourself and rerun."
  fi

  us_info "Disabling the systemd-resolved stub listener to free port 53"

  us_ensure_dir "$(dirname "$US_RESOLVED_DROPIN")" 0755
  # Only the stub listener is disabled here. DNS=/FallbackDNS= are left alone
  # so the host keeps resolving exactly as it did before this ran.
  us_write_if_changed "$US_RESOLVED_DROPIN" 0644 <<EOF || true
# Managed by ${US_PROJECT_NAME}.
# Frees port 53 for AdGuard Home by turning off systemd-resolved's stub
# listener on 127.0.0.53. Host name resolution continues through resolved's
# configured upstreams. scripts/50-local-dns.sh may add DNS= later.
[Resolve]
DNSStubListener=no
EOF

  if [[ "$US_DRY_RUN" == "1" ]]; then
    us_info "DRY-RUN: would restart systemd-resolved"
    return 0
  fi

  us_run systemctl restart systemd-resolved

  # With the stub gone, /etc/resolv.conf must list real upstreams rather than
  # 127.0.0.53, or the host loses DNS entirely.
  if [[ -f /run/systemd/resolve/resolv.conf ]]; then
    local target current
    target="/run/systemd/resolve/resolv.conf"
    current="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
    if [[ "$current" != "$target" ]]; then
      us_info "Pointing /etc/resolv.conf at ${target}"
      [[ -e /etc/resolv.conf ]] &&
        cp -a /etc/resolv.conf "/etc/resolv.conf.${US_PROJECT_NAME}.bak" 2>/dev/null || true
      us_run ln -sf "$target" /etc/resolv.conf
    fi
  fi

  # Prove the host can still resolve before continuing.
  if getent hosts github.com >/dev/null 2>&1; then
    us_ok "Host name resolution still works after freeing port 53"
  else
    us_warn "The host cannot resolve github.com after freeing port 53."
    us_warn "Check /etc/resolv.conf and 'resolvectl status'. Continuing, but image pulls may fail."
  fi

  local still
  still="$(us_port_listener 53 udp || true)"
  [[ -z "$still" ]] ||
    us_die "Port 53/udp is still held by '${still}' after restarting systemd-resolved."

  us_ok "Port 53/udp freed"
}

free_port_53

# --- Phase 2: install the app ---------------------------------------------
[[ "$US_DRY_RUN" == "1" ]] && {
  us_info "DRY-RUN: would install the adguard app"
  exit 0
}

us_runtipi_wait_api 120 || us_die "Runtipi API is not reachable."

# AdGuard comes from the official Runtipi app store (slug "migrated"/default),
# not from u-server's own store: there is no reason to fork an app that
# upstream already maintains. The URN's store component is discovered rather
# than assumed, since the default store slug has changed across Runtipi versions.
store_slug="$(us_runtipi_api GET "marketplace/all" 2>/dev/null |
  jq -r '.appStores[]? | select(.url | test("runtipi-appstore")) | .slug' | head -n1)"

if [[ -z "$store_slug" ]]; then
  us_warn "Could not identify the official Runtipi app store; falling back to 'migrated'."
  store_slug="migrated"
fi
us_debug "Official app store slug: ${store_slug}"

urn="$(us_runtipi_urn "$US_ADGUARD_APP_ID" "$store_slug")"

# openPort exposes the AdGuard admin UI on the host so this installer (and
# doctor.sh) can reach its control API directly at 127.0.0.1:8104.
# exposedLocal + localSubdomain put it behind Traefik at dns.home.arpa.
form="$(jq -nc \
  --arg sub "$DNS_SUBDOMAIN" \
  --argjson port "$US_ADGUARD_PORT" \
  '{exposedLocal: true, localSubdomain: $sub, openPort: true, port: $port}')"

if us_runtipi_app_install "$urn" "$form"; then
  us_ok "AdGuard Home installed and running"
else
  us_die "AdGuard installation failed. Check: docker logs runtipi"
fi

us_manifest_set_component adguard "app" \
  "$(jq -nc --arg u "$urn" --arg d "$DNS_DOMAIN" '{urn: $u, domain: $d}')"

us_info "AdGuard admin UI: http://${DNS_DOMAIN} (also http://${LAN_IP}:${US_ADGUARD_PORT})"
us_warn "AdGuard has no admin password by default. Set one in its UI before exposing this LAN to untrusted devices."
