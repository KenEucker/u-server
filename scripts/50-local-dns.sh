#!/usr/bin/env bash
# scripts/50-local-dns.sh - Make *.home.arpa resolve to this server.
#
# This is the stage that makes "add a service without touching DNS" true.
# A single wildcard rewrite answers every name under LOCAL_DOMAIN with LAN_IP;
# Traefik then decides which container serves each request by Host header.
#
#     AdGuard:  hostname          -> server IP        (one wildcard, forever)
#     Traefik:  hostname          -> service/container (per app, automatic)
#
# Rewrites are matched before any upstream forwarding, so home.arpa keeps
# resolving with the WAN unplugged. Losing the Internet degrades external name
# resolution only — never local service discovery.
#
# Runnable standalone:  sudo scripts/50-local-dns.sh

US_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"
# shellcheck source=lib/config.sh
source "${US_LIB_DIR}/config.sh"
# shellcheck source=lib/docker.sh
source "${US_LIB_DIR}/docker.sh"
# shellcheck source=lib/versions.sh
source "${US_LIB_DIR}/versions.sh"
# shellcheck source=lib/adguard.sh
source "${US_LIB_DIR}/adguard.sh"

us_init "local-dns"
us_require_root
us_config_load

us_section "Local DNS (${LOCAL_DOMAIN})"

if ! us_config_is_true "$INSTALL_ADGUARD"; then
  us_warn "INSTALL_ADGUARD is false, so nothing here can create the wildcard record."
  us_warn "Point *.${LOCAL_DOMAIN} at ${LAN_IP} on whatever resolver your LAN uses."
  exit 0
fi

[[ "$US_DRY_RUN" == "1" ]] && {
  us_info "DRY-RUN: would configure *.${LOCAL_DOMAIN} -> ${LAN_IP}"
  exit 0
}

us_adguard_wait 180 || us_die "AdGuard is not reachable; cannot configure DNS."

# --- Wildcard + apex -------------------------------------------------------
us_adguard_configure_wildcard
us_adguard_configure_upstreams

# --- Prove the wildcard actually works -------------------------------------
# A random name is the real test: it can only resolve via the wildcard, so a
# success here proves future services need no DNS work at all.
probe="us-probe-$(date +%s).${LOCAL_DOMAIN}"

verify_names() {
  local failed=0 name
  for name in "$LOCAL_DOMAIN" "$DNS_DOMAIN" "$probe"; do
    if us_adguard_verify_resolution "$name"; then
      us_status_ok "${name} -> ${LAN_IP}"
    else
      us_status_fail "${name} did not resolve to ${LAN_IP}"
      failed=1
    fi
  done
  return $failed
}

if verify_names; then
  us_ok "Wildcard DNS is working: any *.${LOCAL_DOMAIN} name resolves to ${LAN_IP}"
else
  us_error "Wildcard DNS verification failed."
  us_error "Check the Rewrites page in the AdGuard UI at http://${LAN_IP}:${US_ADGUARD_PORT}"
  us_die "Local DNS is not correct; refusing to repoint the host resolver at it."
fi

# --- Point the host itself at AdGuard --------------------------------------
# Only reached once AdGuard is verified answering, which is what keeps this
# from creating the bootstrap loop described in scripts/40-adguard.sh.
# FallbackDNS keeps the host resolving if the AdGuard container is ever down.
US_RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/60-${US_PROJECT_NAME}.conf"

fallbacks="$(printf '%s' "$ADGUARD_UPSTREAM_DNS" | tr ' ' '\n' |
  grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tr '\n' ' ' | sed 's/ $//')"
[[ -n "$fallbacks" ]] || fallbacks="9.9.9.9 149.112.112.112"

if us_write_if_changed "$US_RESOLVED_DROPIN" 0644 <<EOF
# Managed by ${US_PROJECT_NAME}.
#
# DNSStubListener=no frees port 53 for AdGuard Home.
# DNS=127.0.0.1 makes this host resolve ${LOCAL_DOMAIN} through its own
# AdGuard instance, so 'ping ${NOMAD_DOMAIN}' works on the server too.
# FallbackDNS keeps the host resolving if AdGuard is stopped.
[Resolve]
DNSStubListener=no
DNS=127.0.0.1
FallbackDNS=${fallbacks}
Domains=~${LOCAL_DOMAIN}
EOF
then
  us_run systemctl restart systemd-resolved

  # Verify, and roll back rather than leave the host unable to resolve.
  sleep 2
  if getent hosts "$LOCAL_DOMAIN" >/dev/null 2>&1; then
    us_ok "Host resolves ${LOCAL_DOMAIN} through AdGuard"
  else
    us_warn "Host could not resolve ${LOCAL_DOMAIN} after repointing the resolver."
    us_warn "Reverting to the stub-listener-only configuration."
    us_write_if_changed "$US_RESOLVED_DROPIN" 0644 <<EOF || true
# Managed by ${US_PROJECT_NAME}. Reverted: pointing the host at AdGuard broke
# resolution, so only the stub listener is disabled.
[Resolve]
DNSStubListener=no
EOF
    us_run systemctl restart systemd-resolved
  fi
else
  us_debug "Resolver configuration already current"
fi

# --- Router guidance -------------------------------------------------------
us_section "Router configuration required"
cat >&2 <<EOF
  DNS is now serving ${LOCAL_DOMAIN} on ${LAN_IP}, but LAN clients will not use
  it until your router tells them to.

  On your router's DHCP settings, set the DNS server for LAN clients to:

      ${LAN_IP}

  Set ONLY that address. Do not add a public resolver as a secondary:

      Primary   ${LAN_IP}
      Secondary 8.8.8.8        <-- do NOT do this

  Clients treat resolvers as interchangeable, not ordered, so some queries
  would go to 8.8.8.8, which has never heard of ${LOCAL_DOMAIN}. The result is
  service names that work intermittently and are painful to debug.

  AdGuard already forwards everything that is not ${LOCAL_DOMAIN} upstream,
  so a secondary resolver buys nothing. See docs/dns.md.
EOF

us_manifest_set_component local_dns "configured" \
  "$(jq -nc --arg d "$LOCAL_DOMAIN" --arg ip "$LAN_IP" '{wildcard: ("*." + $d), answer: $ip}')"
