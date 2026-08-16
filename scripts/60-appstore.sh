#!/usr/bin/env bash
# scripts/60-appstore.sh - Register the u-server app store and prove routing.
#
# Runtipi clones app stores with isomorphic-git over HTTP(S) and expects apps/
# at the repository ROOT (app-store-files-manager.ts joins
# <data>/repos/<slug>/apps). This repository keeps its definitions in
# appstore/apps/ so they sit alongside the installer, so the store is published
# to a dedicated branch where apps/ IS the root — see tools/publish-appstore.sh.
#
# Runtipi selects a branch with a /tree/<branch> URL suffix
# (repos.helpers.ts getRepoBaseUrlAndBranch), so one repository serves both.
#
# Runnable standalone:  sudo scripts/60-appstore.sh

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

us_init "appstore"
us_require_root
us_config_load

us_section "u-server app store"

# --- Work out the store URL ------------------------------------------------
# Falls back to this repository's own origin so the common case needs no
# configuration at all.
if [[ -z "$APPSTORE_URL" ]]; then
  origin="$(git -C "$US_ROOT_DIR" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$origin" ]]; then
    # Normalise SSH and .git forms to a plain https URL.
    origin="${origin%.git}"
    origin="${origin/git@github.com:/https://github.com/}"
    origin="${origin/ssh:\/\/git@github.com\//https://github.com/}"
    APPSTORE_URL="${origin}/tree/appstore"
    us_info "Derived APPSTORE_URL from git origin: ${APPSTORE_URL}"
  fi
fi

if [[ -z "$APPSTORE_URL" ]]; then
  us_warn "APPSTORE_URL is not set and no git origin was found."
  us_warn "Set APPSTORE_URL in server.env, or run tools/publish-appstore.sh, then rerun this stage."
  us_warn "Skipping app store registration; Project NOMAD cannot be installed without it."
  exit 0
fi

[[ "$US_DRY_RUN" == "1" ]] && {
  us_info "DRY-RUN: would register app store '${APPSTORE_SLUG}' -> ${APPSTORE_URL}"
  exit 0
}

us_runtipi_wait_api 120 || us_die "Runtipi API is not reachable."

# --- Warn if the branch is not actually published --------------------------
# Failing here with a clear message beats letting Runtipi fail on a clone.
branch="${APPSTORE_URL##*/tree/}"
base="${APPSTORE_URL%/tree/*}"
if [[ "$base" == https://* ]] && us_have git; then
  if ! git ls-remote --exit-code --heads "${base}.git" "$branch" >/dev/null 2>&1; then
    us_error "Branch '${branch}' does not exist at ${base}."
    us_error "Publish it first:  ./tools/publish-appstore.sh"
    us_die "App store branch is missing."
  fi
  us_ok "App store branch '${branch}' is published"
fi

us_runtipi_appstore_add "$APPSTORE_SLUG" "$APPSTORE_URL"
us_runtipi_appstore_pull

us_manifest_set_component appstore "registered" \
  "$(jq -nc --arg s "$APPSTORE_SLUG" --arg u "$APPSTORE_URL" '{slug: $s, url: $u}')"

# --- Prove the platform is service-agnostic --------------------------------
# whoami has no knowledge of u-server, NOMAD or Meridian. If it answers on its
# home.arpa name, any Docker application will.
if us_config_is_true "$INSTALL_WHOAMI"; then
  urn="$(us_runtipi_urn whoami "$APPSTORE_SLUG")"
  form="$(jq -nc --arg sub "$WHOAMI_SUBDOMAIN" \
    '{exposedLocal: true, localSubdomain: $sub, openPort: false}')"

  if us_runtipi_app_install "$urn" "$form"; then
    us_ok "Routing test app installed: http://${WHOAMI_DOMAIN}"
  else
    us_warn "The whoami test app failed to install; routing is unproven."
  fi
else
  us_info "INSTALL_WHOAMI is false; skipping the routing proof."
fi
