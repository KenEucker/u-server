#!/usr/bin/env bash
# lib/nomad.sh - Project NOMAD adapter.
#
# Everything u-server assumes about Project NOMAD's internals is stated here,
# with the upstream source location that establishes it, plus a drift check
# that re-verifies the assumption against upstream when the network is up.
#
# ---------------------------------------------------------------------------
# Contract 1: the child-service network name is hardcoded upstream
# ---------------------------------------------------------------------------
# admin/app/services/docker_service.ts:
#     public static NOMAD_NETWORK = 'project-nomad_default'
# and it is applied when NOMAD creates containers:
#     NetworkingConfig: { EndpointsConfig: { [DockerService.NOMAD_NETWORK]: {} } }
# gated on NODE_ENV === 'production'.
#
# That name arises naturally from `docker compose` only when the project is
# literally named "project-nomad". Under Runtipi the compose project is
# "<appName>_<appStoreSlug>", so the network would be named something else and
# every child container NOMAD created would fail to attach. The Runtipi package
# therefore declares the network with an explicit `name:` so the literal string
# exists regardless of the compose project name.
#
# ---------------------------------------------------------------------------
# Contract 2: host storage is resolved by self-inspection
# ---------------------------------------------------------------------------
# docker_service.ts _resolveHostStorageRoot() inspects the container named
# `nomad_admin` (falling back to matching its own hostname against a container
# id), finds the bind whose Destination is `/app/storage`, and uses that bind's
# host-side Source as the root for every child container's bind mounts.
#
# This is what keeps child bind mounts valid on the host even though NOMAD sees
# them at a different path inside its own container. Two consequences the
# Runtipi package must honour:
#   * container_name MUST be nomad_admin
#   * /app/storage MUST be a bind (not a named volume), so Source is a real path
# NOMAD_STORAGE_PATH is only the fallback used when inspection fails.
#
# ---------------------------------------------------------------------------
# Contract 3: the updater sidecar is omitted deliberately
# ---------------------------------------------------------------------------
# install/sidecar-updater/update-watcher.sh drives
#     docker compose -p "$COMPOSE_PROJECT_NAME" -f /opt/project-nomad/compose.yml \
#         pull / stop / rm / up -d
# i.e. it recreates NOMAD's own core containers from a compose file that does
# not exist under Runtipi. Shipping it would mean two systems owning the same
# containers. Runtipi owns the NOMAD core stack; NOMAD owns what it installs.
# See docs/project-nomad.md#ownership.

[[ -n "${_US_NOMAD_SOURCED:-}" ]] && return 0
_US_NOMAD_SOURCED=1

# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"

# The single source of truth for the contract above.
US_NOMAD_NETWORK="project-nomad_default"
US_NOMAD_ADMIN_CONTAINER="nomad_admin"
US_NOMAD_STORAGE_DEST="/app/storage"
US_NOMAD_APP_ID="project-nomad"

us_nomad_network_name() { printf '%s' "$US_NOMAD_NETWORK"; }

# us_nomad_check_network_contract
# Regression check: re-read the upstream constant and warn loudly if it moved.
# Advisory only — a transient network failure must never block an install.
us_nomad_check_network_contract() {
  local url found
  url="https://raw.githubusercontent.com/Crosstalk-Solutions/project-nomad/main/admin/app/services/docker_service.ts"

  us_have curl || return 0
  local src
  src="$(curl -fsS --max-time 15 "$url" 2>/dev/null)" || {
    us_debug "Could not fetch upstream docker_service.ts; skipping contract check"
    return 0
  }

  found="$(printf '%s' "$src" |
    sed -n "s/.*NOMAD_NETWORK[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" | head -n1)"

  if [[ -z "$found" ]]; then
    us_warn "Could not find NOMAD_NETWORK in upstream docker_service.ts."
    us_warn "Project NOMAD may have changed how it attaches child containers; review lib/nomad.sh."
    return 0
  fi

  if [[ "$found" != "$US_NOMAD_NETWORK" ]]; then
    us_warn "UPSTREAM DRIFT: Project NOMAD now uses network '${found}', u-server expects '${US_NOMAD_NETWORK}'."
    us_warn "Update US_NOMAD_NETWORK in lib/nomad.sh and the app store package, then reinstall the app."
    return 1
  fi

  us_ok "Upstream contract confirmed: NOMAD child network is '${found}'"
}

us_nomad_ensure_network() {
  us_docker_network_ensure "$US_NOMAD_NETWORK"
}

# ---------------------------------------------------------------------------
# Health verification
# ---------------------------------------------------------------------------

# us_nomad_core_containers - the containers the Runtipi package is expected to
# run. Matched by name because the package pins container_name for the admin
# and Runtipi prefixes the rest with its compose project.
us_nomad_core_containers() {
  docker ps -a --format '{{.Names}}' 2>/dev/null |
    grep -E "^(${US_NOMAD_ADMIN_CONTAINER}|.*(nomad).*(mysql|redis|disk[-_]collector).*)$" || true
}

us_nomad_admin_running() {
  us_docker_container_healthy "$US_NOMAD_ADMIN_CONTAINER"
}

# us_nomad_verify_storage_binding
# Confirms Contract 2 holds on the live container: /app/storage must be a bind
# with a real host Source. A named volume here would silently give every child
# container an invalid host path.
us_nomad_verify_storage_binding() {
  local src type
  type="$(docker inspect -f \
    "{{range .Mounts}}{{if eq .Destination \"${US_NOMAD_STORAGE_DEST}\"}}{{.Type}}{{end}}{{end}}" \
    "$US_NOMAD_ADMIN_CONTAINER" 2>/dev/null)" || return 1
  src="$(docker inspect -f \
    "{{range .Mounts}}{{if eq .Destination \"${US_NOMAD_STORAGE_DEST}\"}}{{.Source}}{{end}}{{end}}" \
    "$US_NOMAD_ADMIN_CONTAINER" 2>/dev/null)" || return 1

  if [[ "$type" != "bind" ]]; then
    us_error "${US_NOMAD_STORAGE_DEST} is a '${type:-missing}' mount, not a bind."
    us_error "Child containers would receive host paths that do not exist. See lib/nomad.sh Contract 2."
    return 1
  fi
  if [[ -z "$src" || ! -d "$src" ]]; then
    us_error "${US_NOMAD_STORAGE_DEST} resolves to host path '${src:-<none>}', which does not exist."
    return 1
  fi

  us_debug "NOMAD host storage root: ${src}"
  printf '%s' "$src"
}

# us_nomad_verify_socket - the admin must be able to talk to the Docker API,
# otherwise it cannot manage its own child services at all.
us_nomad_verify_socket() {
  docker exec "$US_NOMAD_ADMIN_CONTAINER" \
    sh -c 'test -S /var/run/docker.sock' 2>/dev/null
}

# us_nomad_verify_http <url>
us_nomad_verify_http() {
  local url="${1:-http://127.0.0.1:8080/api/health}"
  curl -fsS --max-time 10 -o /dev/null "$url" 2>/dev/null
}

# us_nomad_verify - the full check set the brief asks for.
# Prints its own status lines; returns non-zero if any hard check failed.
us_nomad_verify() {
  local failures=0 storage

  if us_nomad_admin_running; then
    us_status_ok "NOMAD admin container (${US_NOMAD_ADMIN_CONTAINER}) is healthy"
  else
    us_status_fail "NOMAD admin container (${US_NOMAD_ADMIN_CONTAINER}) is not healthy"
    ((failures++))
  fi

  local db
  db="$(docker ps --format '{{.Names}}' | grep -E 'nomad.*mysql' | head -n1)"
  if [[ -n "$db" ]] && us_docker_container_healthy "$db"; then
    us_status_ok "NOMAD database (${db}) is healthy"
  else
    us_status_fail "NOMAD database container is not healthy"
    ((failures++))
  fi

  if us_docker_network_exists "$US_NOMAD_NETWORK"; then
    us_status_ok "Child-service network '${US_NOMAD_NETWORK}' exists"
  else
    us_status_fail "Child-service network '${US_NOMAD_NETWORK}' is missing — NOMAD cannot start child apps"
    ((failures++))
  fi

  if us_nomad_verify_socket; then
    us_status_ok "NOMAD has Docker socket access"
  else
    us_status_fail "NOMAD cannot reach /var/run/docker.sock — it cannot manage child services"
    ((failures++))
  fi

  if storage="$(us_nomad_verify_storage_binding)"; then
    us_status_ok "Host storage root resolves to ${storage}"
  else
    us_status_fail "NOMAD storage binding is invalid (see lib/nomad.sh Contract 2)"
    ((failures++))
  fi

  if us_nomad_verify_http "http://${NOMAD_DOMAIN}/api/health" ||
    us_nomad_verify_http; then
    us_status_ok "NOMAD UI/API is reachable"
  else
    us_status_warn "NOMAD UI/API did not answer /api/health (it may still be starting)"
  fi

  return $((failures > 0 ? 1 : 0))
}

# us_nomad_child_services - what NOMAD currently has running on its network.
# Used to demonstrate child orchestration without downloading anything large.
us_nomad_child_services() {
  docker network inspect "$US_NOMAD_NETWORK" \
    -f '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' 2>/dev/null |
    grep -v "^${US_NOMAD_ADMIN_CONTAINER}$" | grep -v '^$' || true
}
