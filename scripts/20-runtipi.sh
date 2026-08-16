#!/usr/bin/env bash
# scripts/20-runtipi.sh - Resolve, download and start Runtipi.
#
# Deliberately NOT `curl https://setup.runtipi.io | bash`. That script is fine
# for a human at a terminal, but it resolves "latest" itself, installs Docker
# with its own logic, and gives us no record of what was installed. We do the
# same work explicitly so the version is resolved once, recorded, and
# reproducible — and so the future offline bundler can reuse the resolution.
#
# Runnable standalone:  sudo scripts/20-runtipi.sh

US_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"
# shellcheck source=lib/config.sh
source "${US_LIB_DIR}/config.sh"
# shellcheck source=lib/versions.sh
source "${US_LIB_DIR}/versions.sh"
# shellcheck source=lib/docker.sh
source "${US_LIB_DIR}/docker.sh"
# shellcheck source=lib/runtipi.sh
source "${US_LIB_DIR}/runtipi.sh"

us_init "runtipi"
us_require_root
us_config_load

us_section "Runtipi"

us_have docker || us_die "Docker is not installed. Run scripts/10-docker.sh first."

# --- Resolve the exact version to install ----------------------------------
resolved="$(us_version_resolve runtipi "$RUNTIPI_VERSION" "$US_RUNTIPI_REPO")" ||
  us_die "Could not resolve a Runtipi version for policy '${RUNTIPI_VERSION}'."

us_info "Runtipi version policy '${RUNTIPI_VERSION}' resolved to ${resolved}"

# --- Install the CLI -------------------------------------------------------
us_ensure_dir "$(us_runtipi_root)" 0755
us_runtipi_fetch_cli "$resolved"

# --- Start -----------------------------------------------------------------
# `runtipi-cli start` is idempotent: it regenerates .env, brings the compose
# project up, and returns. Running it on an already-running node converges
# rather than duplicating anything.
if us_runtipi_is_running; then
  us_info "Runtipi is already running; running start to converge configuration."
fi

us_runtipi_start

if [[ "$US_DRY_RUN" != "1" ]]; then
  us_runtipi_wait_api 300 || us_die "Runtipi did not become ready."

  installed="$(us_runtipi_installed_version || printf '%s' "$resolved")"
  extra="$(jq -nc \
    --arg p "$RUNTIPI_VERSION" \
    --arg r "$(us_runtipi_root)" \
    --arg s "${US_RUNTIPI_ARTIFACT_SHA256:-}" \
    '{policy: $p, root: $r} + (if $s == "" then {} else {artifact_sha256: $s} end)')"
  us_manifest_set_component runtipi "$installed" "$extra"
  us_ok "Runtipi ${installed} is running"
fi
