#!/usr/bin/env bash
# scripts/30-runtipi-config.sh - Point Runtipi at the local domain.
#
# THE DASHBOARD HOSTNAME
# ----------------------
# Runtipi's dashboard router binds the BARE local domain:
#     traefik.http.routers.dashboard-local.rule: Host(`${LOCAL_DOMAIN}`)
# (docker-compose.prod.yml), while apps bind `<subdomain>.${LOCAL_DOMAIN}`
# (traefik-labels.builder.ts).
#
# So LOCAL_DOMAIN=home.arpa gives:
#     http://home.arpa        -> Runtipi dashboard
#     http://dns.home.arpa    -> AdGuard
#
# The apex is genuinely claimed, on both layers: scripts/50-local-dns.sh
# creates an explicit `home.arpa -> LAN_IP` rewrite alongside the wildcard
# (standard DNS wildcards do not cover the apex, and resolvers differ on how
# they treat wildcard rewrites, so it is set explicitly rather than assumed).
# Upstream clearly intends this too — Runtipi's TLS generation issues a
# certificate for both names: DNS:*.${localDomain},DNS:${localDomain}
# (app.service.ts:237).
#
# An earlier revision additionally published the dashboard at
# server.${LOCAL_DOMAIN} via a Traefik file-provider router. That was removed:
# it added a generated file and a documented compromise to buy a second name
# for something already reachable at the apex. LOCAL_DOMAIN is a single knob
# driving both the dashboard hostname and the app suffix, so a `server.` name
# can only be added, never substituted — and adding it earned nothing.
#
# The cleanup below removes that file if a previous install wrote it.
#
# Runnable standalone:  sudo scripts/30-runtipi-config.sh

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

us_init "runtipi-config"
us_require_root
us_config_load

us_section "Runtipi configuration"

[[ -x "$(us_runtipi_cli)" ]] ||
  us_die "Runtipi CLI not found. Run scripts/20-runtipi.sh first."

needs_restart=0

# --- Local domain ----------------------------------------------------------
current_domain="$(us_runtipi_env_get LOCAL_DOMAIN 2>/dev/null || printf '')"
us_info "Setting Runtipi local domain to ${LOCAL_DOMAIN} (currently: ${current_domain:-unset})"

# Returns 0 when settings actually changed, 1 when already correct.
if us_runtipi_configure_local_domain; then
  needs_restart=1
fi
[[ "$current_domain" == "$LOCAL_DOMAIN" ]] || needs_restart=1

# --- Remove the obsolete dashboard alias -----------------------------------
# Idempotent cleanup for hosts installed before the alias was dropped.
# Traefik's file provider watches this directory, so removing the file
# retires the route without a restart.
stale_alias="$(us_runtipi_traefik_dynamic_dir)/${US_PROJECT_NAME}-dashboard.yml"
if [[ -f "$stale_alias" ]]; then
  us_info "Removing the obsolete dashboard alias router (${stale_alias##*/})"
  us_info "The dashboard remains available at http://${LOCAL_DOMAIN}"
  us_run rm -f -- "$stale_alias"
fi

# --- Apply -----------------------------------------------------------------
# LOCAL_DOMAIN is baked into container labels when app compose files are
# generated, so a change requires Runtipi to regenerate and recreate. Restart
# only when the value actually changed — restarting a healthy platform on
# every install rerun is exactly the churn idempotency is meant to avoid.
if ((needs_restart)) && [[ "$US_DRY_RUN" != "1" ]]; then
  us_info "Local domain changed; restarting Runtipi to regenerate routing"
  us_runtipi_start
  us_runtipi_wait_api 300 || us_die "Runtipi did not come back after the domain change."
else
  us_ok "Local domain already correct; no restart needed"
fi

if [[ "$US_DRY_RUN" != "1" ]]; then
  effective="$(us_runtipi_env_get LOCAL_DOMAIN 2>/dev/null || printf '')"
  if [[ "$effective" == "$LOCAL_DOMAIN" ]]; then
    us_ok "Runtipi LOCAL_DOMAIN=${effective}"
  else
    us_warn "Runtipi reports LOCAL_DOMAIN='${effective}', expected '${LOCAL_DOMAIN}'."
    us_warn "Check $(us_runtipi_settings_file)"
  fi
  us_info "Dashboard: http://${LOCAL_DOMAIN}"
fi
