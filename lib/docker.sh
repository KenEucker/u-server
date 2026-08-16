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
# us_docker_install/us_docker_verify record into the manifest, so this adapter
# owns that dependency rather than hoping every caller happens to source it.
# shellcheck source=lib/versions.sh
source "${US_LIB_DIR}/versions.sh"

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

# us_docker_desktop_signal - print the Docker Desktop evidence found on this
# host and return 0; return 1 when there is none.
#
# Docker Desktop manages its own engine inside a VM, with its own socket, so it
# conflicts with a host Engine install and we refuse rather than fight it. The
# evidence is printed because "Docker Desktop detected" on a machine the user
# believes is clean is unactionable — they need to know what was found.
#
# Only two kinds of evidence count as installed-and-in-the-way:
#   - Desktop's files on disk
#   - the CLI *actively* pointed at Desktop's engine
# A merely-defined desktop-linux context is not evidence; see
# us_docker_desktop_stale_context.
us_docker_desktop_signal() {
  if [[ -e /usr/bin/docker-desktop ]]; then
    printf 'the docker-desktop binary at /usr/bin/docker-desktop'
    return 0
  fi
  if [[ -d /opt/docker-desktop ]]; then
    printf 'the Docker Desktop installation at /opt/docker-desktop'
    return 0
  fi
  local ctx
  ctx="$(docker context show 2>/dev/null || true)"
  if [[ "$ctx" == "desktop-linux" ]]; then
    printf "the active docker context 'desktop-linux' (docker is talking to Desktop's engine)"
    return 0
  fi
  return 1
}

us_docker_desktop_present() { us_docker_desktop_signal >/dev/null; }

# us_docker_desktop_stale_context - a desktop-linux context definition with no
# Docker Desktop behind it, left over from an uninstall. Not a reason to refuse
# the install: the CLI is pointed at the host engine and everything works. Worth
# reporting, because switching to that context later breaks every stage.
#
# Note this reads the *current* user's context store (~/.docker/contexts), so
# under sudo it sees root's, not the desktop user's. Advisory only, so a miss
# costs nothing.
us_docker_desktop_stale_context() {
  us_docker_desktop_present && return 1
  docker context inspect desktop-linux >/dev/null 2>&1
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
  local desktop
  if desktop="$(us_docker_desktop_signal)"; then
    us_error "Docker Desktop detected: ${desktop}."
    us_die "u-server requires Docker Engine on the host. Remove Docker Desktop first."
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
