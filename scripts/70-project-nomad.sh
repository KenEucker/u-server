#!/usr/bin/env bash
# scripts/70-project-nomad.sh - Install Project NOMAD as a Runtipi application.
#
# NOMAD is treated here as exactly one workload among others. The only reason
# this stage exists at all, rather than being a line in the app store stage, is
# that NOMAD has two upstream contracts worth verifying explicitly (its
# hardcoded child network and its storage self-discovery) and elevated
# permissions worth surfacing before they are granted.
#
# Runnable standalone:  sudo scripts/70-project-nomad.sh

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
# shellcheck source=lib/nomad.sh
source "${US_LIB_DIR}/nomad.sh"

us_init "project-nomad"
us_require_root
us_config_load

us_section "Project NOMAD"

if ! us_config_is_true "$INSTALL_PROJECT_NOMAD"; then
  us_info "INSTALL_PROJECT_NOMAD is false; skipping."
  exit 0
fi

# --- Surface elevated permissions BEFORE granting them ---------------------
cat >&2 <<EOF

  WARNING: Project NOMAD requires access to the Docker socket.

  This application mounts /var/run/docker.sock. That grants the NOMAD
  container root-equivalent control of this host: anything able to reach the
  Docker API can start privileged containers and read or write any host path.

  This is how NOMAD works — it creates and manages the child content services
  you install from its Command Center. Without the socket the UI runs but can
  install nothing.

  It additionally mounts the host root filesystem read-only at /host to report
  disk capacity.

  Unrelated applications on this server stay isolated on their own Docker
  networks and are not reachable from NOMAD's network.

EOF

# --- Verify the upstream contract still holds ------------------------------
# Advisory: a drift warning is worth seeing, but a transient network failure
# must not block installation.
us_nomad_check_network_contract || true

[[ "$US_DRY_RUN" == "1" ]] && {
  us_info "DRY-RUN: would install ${US_NOMAD_APP_ID} at ${NOMAD_DOMAIN}"
  exit 0
}

us_runtipi_wait_api 120 || us_die "Runtipi API is not reachable."

us_runtipi_appstore_exists "$APPSTORE_SLUG" ||
  us_die "App store '${APPSTORE_SLUG}' is not registered. Run scripts/60-appstore.sh first."

# --- Install ---------------------------------------------------------------
# openPort:false deliberately. NOMAD's HTTP port is not published to the LAN;
# Traefik is the entry point, reaching it over the Docker network.
urn="$(us_runtipi_urn "$US_NOMAD_APP_ID" "$APPSTORE_SLUG")"
form="$(jq -nc --arg sub "$NOMAD_SUBDOMAIN" \
  '{exposedLocal: true, localSubdomain: $sub, openPort: false}')"

if ! us_runtipi_app_install "$urn" "$form"; then
  us_error "Project NOMAD failed to install."
  us_error "MySQL initialisation on first boot is slow; check whether it is still starting:"
  us_error "  docker ps -a | grep nomad"
  us_error "  docker logs nomad_admin"
  us_die "Installation failed."
fi

# --- Verify ----------------------------------------------------------------
us_section "Project NOMAD verification"

# The admin container can report healthy before the app finishes migrations.
sleep 5

if us_nomad_verify; then
  us_ok "Project NOMAD verified"
else
  us_warn "Project NOMAD installed but one or more checks failed (see above)."
  us_warn "Rerun ./doctor.sh after a minute; MySQL first-boot can delay readiness."
fi

# Child-service orchestration: report what exists rather than provisioning
# anything. Installing a child app would mean downloading content (ZIM
# archives, map tiles, AI models) that can be enormous — not something an
# installer should start unattended.
children="$(us_nomad_child_services)"
if [[ -n "$children" ]]; then
  us_ok "NOMAD child services currently attached to $(us_nomad_network_name):"
  printf '%s\n' "$children" | sed 's/^/      /' >&2
else
  us_info "No NOMAD child services yet — expected on a fresh install."
  us_info "To verify child orchestration manually, open http://${NOMAD_DOMAIN},"
  us_info "install the smallest available service (CyberChef or FlatNotes are"
  us_info "static web apps with no large downloads), then run:"
  us_info "    docker network inspect $(us_nomad_network_name)"
  us_info "The new container should appear attached to that network."
fi

us_manifest_set_component project_nomad "$(jq -r '.version' "${US_ROOT_DIR}/appstore/apps/project-nomad/config.json")" \
  "$(jq -nc --arg u "$urn" --arg d "$NOMAD_DOMAIN" --arg n "$(us_nomad_network_name)" \
    '{urn: $u, domain: $d, child_network: $n, docker_socket: true}')"

us_info "Project NOMAD Command Center: http://${NOMAD_DOMAIN}"
