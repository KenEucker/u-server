#!/usr/bin/env bash
# lib/docker.sh - Docker Engine adapter.
#
# Follows Docker's current official Ubuntu apt-repository procedure
# (https://docs.docker.com/engine/install/ubuntu/, verified 2026-08), which
# now uses the deb822 .sources format rather than the older one-line
# /etc/apt/sources.list.d/docker.list entry.
#
# Explicitly NOT Docker Desktop, and nothing here requires KVM.

[[ -n "${_US_DOCKER_SOURCED:-}" ]] && return 0
_US_DOCKER_SOURCED=1

# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"

US_DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
US_DOCKER_SOURCES="/etc/apt/sources.list.d/docker.sources"
# Legacy path from the older documented procedure. If a previous install used
# it we remove it, otherwise apt reports a duplicate-source warning on rerun.
US_DOCKER_SOURCES_LEGACY="/etc/apt/sources.list.d/docker.list"

# Runtipi's own installer treats Docker < 28.0.0 as needing an upgrade, so we
# use the same floor. Checked with a comparison, not assumed.
US_DOCKER_MIN_VERSION="28.0.0"

us_docker_present() { us_have docker; }

us_docker_version() {
  docker version --format '{{.Server.Version}}' 2>/dev/null ||
    docker --version 2>/dev/null | sed -n 's/.*version \([0-9.]*\).*/\1/p'
}

us_docker_compose_version() {
  docker compose version --short 2>/dev/null
}

# us_docker_desktop_present - Docker Desktop manages its own engine in a VM and
# conflicts with a host Engine install; detect and refuse rather than fight it.
us_docker_desktop_present() {
  [[ -e /usr/bin/docker-desktop ]] ||
    [[ -d /opt/docker-desktop ]] ||
    { docker context inspect desktop-linux >/dev/null 2>&1; }
}

# us_docker_repo_configure - idempotent apt repository setup.
us_docker_repo_configure() {
  local codename arch
  codename="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
  arch="$(dpkg --print-architecture)"

  us_run install -m 0755 -d /etc/apt/keyrings

  if [[ ! -s "$US_DOCKER_KEYRING" ]]; then
    us_info "Fetching Docker apt signing key"
    if [[ "$US_DRY_RUN" != "1" ]]; then
      us_retry 3 3 curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o "$US_DOCKER_KEYRING" ||
        us_die "Could not download Docker's apt signing key."
      chmod a+r "$US_DOCKER_KEYRING"
    fi
  else
    us_debug "Docker apt key already present"
  fi

  if [[ -f "$US_DOCKER_SOURCES_LEGACY" ]]; then
    us_warn "Removing legacy ${US_DOCKER_SOURCES_LEGACY} (superseded by docker.sources)"
    us_run rm -f "$US_DOCKER_SOURCES_LEGACY"
  fi

  # `|| true` is required, not decorative: us_write_if_changed returns 1 to mean
  # "already correct", which under `set -e` would abort the run on every rerun
  # of an already-configured host.
  us_write_if_changed "$US_DOCKER_SOURCES" 0644 <<EOF || true
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: ${US_DOCKER_KEYRING}
EOF
  return 0
}

# us_docker_install - install Engine, CLI, containerd, buildx and the Compose
# plugin. Safe to rerun: apt is declarative and we skip when already satisfied.
us_docker_install() {
  if us_docker_desktop_present; then
    us_die "Docker Desktop detected. u-server requires Docker Engine on the host. Remove Docker Desktop first."
  fi

  if us_docker_present; then
    local v
    v="$(us_docker_version || true)"
    if [[ -n "$v" ]] && us_version_ge "$v" "$US_DOCKER_MIN_VERSION" &&
      us_docker_compose_version >/dev/null 2>&1; then
      us_ok "Docker ${v} already satisfies the >= ${US_DOCKER_MIN_VERSION} requirement"
      us_manifest_set_component docker "$v" \
        "$(jq -nc --arg c "$(us_docker_compose_version)" '{compose: $c}')"
      return 0
    fi
    us_info "Docker ${v:-unknown} present but below ${US_DOCKER_MIN_VERSION} or missing the Compose plugin; upgrading."
  fi

  us_docker_repo_configure

  us_info "Installing Docker Engine packages"
  us_run env DEBIAN_FRONTEND=noninteractive apt-get update
  us_run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  us_run systemctl enable --now docker

  [[ "$US_DRY_RUN" == "1" ]] && return 0

  us_docker_verify
}

# us_docker_verify - the three checks the brief asks for, plus a real workload.
us_docker_verify() {
  local v c
  v="$(us_docker_version)" || us_die "'docker version' failed after installation."
  c="$(us_docker_compose_version)" || us_die "'docker compose version' failed; the Compose plugin is missing."
  docker info >/dev/null 2>&1 || us_die "'docker info' failed; the daemon is not responding."

  us_ok "Docker Engine ${v}"
  us_ok "Docker Compose ${c}"

  if ! us_version_ge "$v" "$US_DOCKER_MIN_VERSION"; then
    us_warn "Docker ${v} is older than ${US_DOCKER_MIN_VERSION}, which Runtipi expects. Continuing, but Runtipi may misbehave."
  fi

  us_manifest_set_component docker "$v" "$(jq -nc --arg c "$c" '{compose: $c}')"
}

# us_docker_network_ensure <name> - create a user-defined bridge if absent.
# Used for Project NOMAD's hardcoded child-service network.
us_docker_network_ensure() {
  local name="$1"
  if docker network inspect "$name" >/dev/null 2>&1; then
    us_debug "Docker network '${name}' already exists"
    return 0
  fi
  us_info "Creating Docker network '${name}'"
  us_run docker network create "$name"
}

us_docker_network_exists() {
  docker network inspect "$1" >/dev/null 2>&1
}

us_docker_container_state() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null
}

# us_docker_container_healthy - true when healthy, or running with no
# healthcheck defined (absence of a healthcheck is not ill health).
us_docker_container_healthy() {
  local name="$1" health status
  status="$(us_docker_container_state "$name")" || return 1
  [[ "$status" == "running" ]] || return 1
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null)"
  [[ "$health" == "healthy" || "$health" == "none" ]]
}

# us_docker_images_of_compose <file...> - enumerate images a compose file uses.
# The future offline bundle builder calls this to decide what to `docker save`.
us_docker_images_of_compose() {
  local f
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    docker compose -f "$f" config --images 2>/dev/null || true
  done | sort -u
}
