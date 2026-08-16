#!/usr/bin/env bash
# tools/resolve-versions.sh - Synchronise app definitions with upstream releases.
#
# This is a DEVELOPMENT tool, not part of installation. It updates the app
# definitions in this repository; it never touches a running node. That
# separation is the whole point:
#
#     repository app definition   what this repo says to deploy   <- updated here
#     candidate upstream version  what upstream has published
#     installed node version      what is actually running        <- ./update.sh
#
# A newer upstream release therefore does not change any running server until
# somebody commits the change here, publishes the app store, and runs
# ./update.sh on that server.
#
#   ./tools/resolve-versions.sh            report what would change
#   ./tools/resolve-versions.sh --write    apply changes to app definitions
#
# A lesson encoded here: a GitHub release tag is NOT proof that a matching
# container image exists, and sidecar images can move on their own version
# line. Both are verified against the registry before anything is written.

set -Eeuo pipefail

US_ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
US_LIB_DIR="${US_ROOT_DIR}/lib"
# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"
# shellcheck source=lib/versions.sh
source "${US_LIB_DIR}/versions.sh"

us_init "resolve-versions"

write=0
[[ "${1:-}" == "--write" ]] && write=1

us_require_cmds curl jq

APPSTORE_DIR="${US_ROOT_DIR}/appstore/apps"
changes=0

# ---------------------------------------------------------------------------
# Registry helpers
# ---------------------------------------------------------------------------

# _registry_token <repo> - anonymous pull token for ghcr.io.
_ghcr_token() {
  curl -fsS "https://ghcr.io/token?scope=repository:${1}:pull&service=ghcr.io" |
    jq -r '.token // empty'
}

# ghcr_tag_exists <repo> <tag>
# Note the ?n=1000: the default page size is 100 and several of these
# repositories have more tags than that, which silently hides recent releases.
ghcr_tag_exists() {
  local repo="$1" tag="$2" token
  token="$(_ghcr_token "$repo")" || return 1
  [[ -n "$token" ]] || return 1
  curl -fsS -H "Authorization: Bearer ${token}" \
    "https://ghcr.io/v2/${repo}/tags/list?n=1000" 2>/dev/null |
    jq -e --arg t "$tag" '.tags | index($t) != null' >/dev/null 2>&1
}

# ghcr_latest_stable <repo> - newest vX.Y.Z tag actually present in the registry.
ghcr_latest_stable() {
  local repo="$1" token
  token="$(_ghcr_token "$repo")" || return 1
  curl -fsS -H "Authorization: Bearer ${token}" \
    "https://ghcr.io/v2/${repo}/tags/list?n=1000" 2>/dev/null |
    jq -r '.tags[]? | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' |
    sed 's/^v//' | sort -V | tail -n1 | sed 's/^/v/'
}

# ---------------------------------------------------------------------------
# Project NOMAD
# ---------------------------------------------------------------------------
resolve_nomad() {
  local dir="${APPSTORE_DIR}/project-nomad"
  local config="${dir}/config.json" compose="${dir}/docker-compose.yml"
  [[ -f "$config" ]] || {
    us_warn "No project-nomad definition; skipping."
    return 0
  }

  us_section "Project NOMAD"

  local current release image_tag
  current="$(jq -r '.version' "$config")"
  us_info "Definition currently pins: ${current}"

  release="$(us_gh_latest_stable "$US_NOMAD_REPO")" || {
    us_warn "Could not query upstream releases; skipping."
    return 0
  }
  us_info "Newest upstream release:   ${release}"

  # Verify the release tag actually exists as an image before trusting it.
  if ghcr_tag_exists "crosstalk-solutions/project-nomad" "$release"; then
    image_tag="$release"
    us_ok "Image ghcr.io/crosstalk-solutions/project-nomad:${release} exists"
  else
    us_warn "Release ${release} has no matching container image."
    image_tag="$(ghcr_latest_stable 'crosstalk-solutions/project-nomad')" || {
      us_error "Could not determine any usable image tag; leaving the definition alone."
      return 1
    }
    us_warn "Falling back to newest published image: ${image_tag}"
  fi

  # The disk-collector sidecar has its OWN version line and does not track the
  # NOMAD release. Resolving it separately is required, not defensive.
  local dc_tag dc_current
  dc_current="$(grep -oE 'project-nomad-disk-collector:[^ ]+' "$compose" | cut -d: -f2 || true)"
  dc_tag="$(ghcr_latest_stable 'crosstalk-solutions/project-nomad-disk-collector')" || dc_tag=""
  if [[ -n "$dc_tag" ]]; then
    us_info "disk-collector: pinned ${dc_current:-?}, newest published ${dc_tag}"
  fi

  if [[ "$image_tag" == "$current" && ( -z "$dc_tag" || "$dc_tag" == "$dc_current" ) ]]; then
    us_ok "Already current; nothing to change."
    return 0
  fi

  changes=1
  if ((!write)); then
    us_info "Would update: ${current} -> ${image_tag}"
    [[ -n "$dc_tag" && "$dc_tag" != "$dc_current" ]] &&
      us_info "Would update disk-collector: ${dc_current} -> ${dc_tag}"
    us_info "Rerun with --write to apply."
    return 0
  fi

  local tv
  tv="$(jq -r '.tipi_version' "$config")"
  local tmp
  tmp="$(mktemp)"
  jq --arg v "$image_tag" --argjson t "$((tv + 1))" --argjson u "$(date +%s)000" \
    '.version = $v | .tipi_version = $t | .updated_at = $u' "$config" >"$tmp"
  mv "$tmp" "$config"
  us_ok "config.json: version=${image_tag}, tipi_version=$((tv + 1))"

  sed -i "s|ghcr.io/crosstalk-solutions/project-nomad:[^ ]*|ghcr.io/crosstalk-solutions/project-nomad:${image_tag}|" "$compose"
  [[ -n "$dc_tag" ]] &&
    sed -i "s|ghcr.io/crosstalk-solutions/project-nomad-disk-collector:[^ ]*|ghcr.io/crosstalk-solutions/project-nomad-disk-collector:${dc_tag}|" "$compose"
  us_ok "docker-compose.yml image tags updated"

  us_warn "Review the diff, then:"
  us_warn "  ./tools/validate-appstore.sh"
  us_warn "  git commit && ./tools/publish-appstore.sh"
  us_warn "  sudo ./update.sh nomad     (on each server, when you choose to)"
}

# ---------------------------------------------------------------------------
# Runtipi (reported only: the installer resolves it at run time)
# ---------------------------------------------------------------------------
report_runtipi() {
  us_section "Runtipi"
  local latest
  latest="$(us_gh_latest_stable "$US_RUNTIPI_REPO" 2>/dev/null || echo unknown)"
  us_info "Newest upstream stable: ${latest}"
  us_info "No file to update: RUNTIPI_VERSION=stable is resolved at install time"
  us_info "and pinned per node in ${US_MANIFEST_FILE}."
}

resolve_nomad || true
report_runtipi

us_section "Summary"
if ((changes)); then
  if ((write)); then
    us_ok "App definitions updated. Commit and publish them."
  else
    us_warn "Updates are available. Rerun with --write to apply."
  fi
  exit 0
fi
us_ok "All app definitions are current."
