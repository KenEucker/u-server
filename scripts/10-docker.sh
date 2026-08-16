#!/usr/bin/env bash
# scripts/10-docker.sh - Install and verify Docker Engine.
#
# Runnable standalone:  sudo scripts/10-docker.sh

US_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"
# shellcheck source=lib/config.sh
source "${US_LIB_DIR}/config.sh"
# shellcheck source=lib/versions.sh
source "${US_LIB_DIR}/versions.sh"
# shellcheck source=lib/docker.sh
source "${US_LIB_DIR}/docker.sh"

us_init "docker"
us_require_root
us_config_load

us_section "Docker Engine"

us_docker_install

# The invoking user usually wants to run docker without sudo afterwards.
# We add them to the docker group but do NOT switch the running session: group
# membership only applies to new logins, and silently re-execing would be
# surprising. Note the security implication rather than hiding it.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  if id -nG "$SUDO_USER" 2>/dev/null | grep -qw docker; then
    us_debug "${SUDO_USER} is already in the docker group"
  else
    us_run usermod -aG docker "$SUDO_USER"
    us_warn "Added ${SUDO_USER} to the 'docker' group."
    us_warn "That grants root-equivalent control of this host. Log out and back in for it to take effect."
  fi
fi

us_ok "Docker stage complete"
