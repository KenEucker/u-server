#!/usr/bin/env bash
# update.sh - Deliberate, explicit upgrades.
#
# "stable" as a version policy means "pick a sensible version at first
# install", NOT "upgrade everything whenever upstream ships". Rerunning
# install.sh never upgrades anything. Upgrades happen only here, only for the
# component you name, and are recorded before and after.
#
#   ./update.sh --check          what is installed vs available (read-only)
#   sudo ./update.sh runtipi     upgrade Runtipi
#   sudo ./update.sh nomad       upgrade the Project NOMAD app
#   sudo ./update.sh appstore    refresh app store definitions only
#   sudo ./update.sh --all       everything above, in order

set -Eeuo pipefail

US_ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
US_LIB_DIR="${US_ROOT_DIR}/lib"
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
# shellcheck source=lib/nomad.sh
source "${US_LIB_DIR}/nomad.sh"

usage() {
  cat <<EOF
u-server update

Usage:
  ./update.sh --check              Show installed vs available. Changes nothing.
  sudo ./update.sh runtipi         Upgrade Runtipi to the newest stable release.
  sudo ./update.sh nomad           Upgrade the Project NOMAD application.
  sudo ./update.sh appstore        Re-pull app store definitions.
  sudo ./update.sh --all           All of the above.

Options:
  --to <version>   With a component, upgrade to an exact version instead of stable.
  --dry-run        Show what would happen.
  -h, --help       This help.

Upgrades are never automatic. Configuration is backed up before changes, and
before/after versions are recorded in ${US_MANIFEST_FILE}.
EOF
}

target=""
to_version=""
do_check=0
do_all=0

while (($#)); do
  case "$1" in
    --check)
      do_check=1
      shift
      ;;
    --all)
      do_all=1
      shift
      ;;
    --to)
      to_version="${2:-}"
      shift 2
      ;;
    --dry-run)
      US_DRY_RUN=1
      export US_DRY_RUN
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    runtipi | nomad | appstore)
      target="$1"
      shift
      ;;
    *) us_die "Unknown argument: $1 (try --help)" ;;
  esac
done

us_init "update"
us_config_load

# ---------------------------------------------------------------------------
# --check : read-only comparison
# ---------------------------------------------------------------------------
if ((do_check)) || [[ -z "$target" && $do_all -eq 0 ]]; then
  printf '\nInstalled vs available\n'
  printf -- '-----------------------------------------------\n'

  if ! us_have_internet; then
    us_warn "No Internet access; only installed versions can be shown."
  fi

  ri="$(us_version_installed runtipi 2>/dev/null || echo 'not installed')"
  ra="$(us_have_internet && us_gh_latest_stable "$US_RUNTIPI_REPO" 2>/dev/null || echo 'unknown')"
  printf '  Runtipi\n    installed: %s\n    available: %s\n' "$ri" "$ra"
  [[ "$ri" != "$ra" && "$ra" != "unknown" ]] &&
    printf '    -> sudo ./update.sh runtipi\n'

  ni="$(us_version_installed project_nomad 2>/dev/null || echo 'not installed')"
  na="$(us_have_internet && us_gh_latest_stable "$US_NOMAD_REPO" 2>/dev/null || echo 'unknown')"
  nd="$(jq -r '.version' "${US_ROOT_DIR}/appstore/apps/project-nomad/config.json" 2>/dev/null || echo '?')"
  printf '\n  Project NOMAD\n    installed:            %s\n' "$ni"
  printf '    app definition (repo): %s\n    available upstream:    %s\n' "$nd" "$na"
  if [[ "$nd" != "$na" && "$na" != "unknown" ]]; then
    printf '    -> ./tools/resolve-versions.sh   (update the definition first)\n'
  elif [[ "$ni" != "$nd" ]]; then
    printf '    -> sudo ./update.sh nomad\n'
  fi

  di="$(us_version_installed docker 2>/dev/null || echo 'not installed')"
  printf '\n  Docker\n    installed: %s\n' "$di"
  printf '    (managed by apt: sudo apt update && sudo apt upgrade)\n'

  printf '\nNothing was changed.\n\n'
  ((do_check)) && exit 0
  exit 0
fi

# ---------------------------------------------------------------------------
# Mutating paths
# ---------------------------------------------------------------------------
[[ "$US_DRY_RUN" == "1" ]] || us_require_root
[[ "$US_DRY_RUN" == "1" ]] || us_acquire_lock

backup_config() {
  local dest
  dest="${US_STATE_DIR}/backups/$(date -u '+%Y%m%dT%H%M%SZ')"
  [[ "$US_DRY_RUN" == "1" ]] && {
    us_info "DRY-RUN: would back up configuration to ${dest}"
    return 0
  }
  us_ensure_dir "$dest" 0700
  [[ -f "$US_INSTALLED_CONFIG" ]] && cp -a "$US_INSTALLED_CONFIG" "$dest/" || true
  [[ -f "$US_MANIFEST_FILE" ]] && cp -a "$US_MANIFEST_FILE" "$dest/" || true
  local settings
  settings="$(us_runtipi_settings_file)"
  [[ -f "$settings" ]] && cp -a "$settings" "$dest/" || true
  us_ok "Configuration backed up to ${dest}"
}

update_runtipi() {
  us_section "Updating Runtipi"
  local before after wanted

  before="$(us_version_installed runtipi 2>/dev/null || echo 'unknown')"

  if [[ -n "$to_version" ]]; then
    wanted="$to_version"
  else
    wanted="$(us_gh_latest_stable "$US_RUNTIPI_REPO")" ||
      us_die "Could not determine the newest stable Runtipi release."
  fi

  if [[ "$before" == "$wanted" ]]; then
    us_ok "Runtipi is already at ${wanted}; nothing to do."
    return 0
  fi

  us_info "Runtipi ${before} -> ${wanted}"
  backup_config

  if [[ "$US_DRY_RUN" == "1" ]]; then
    us_info "DRY-RUN: would run runtipi-cli update ${wanted}"
    return 0
  fi

  local root
  root="$(us_runtipi_root)"
  # The CLI's own update command handles replacing the binary and recreating
  # the stack; reimplementing that here would duplicate upstream logic.
  ( cd "$root" && ./runtipi-cli update "$wanted" ) ||
    us_die "runtipi-cli update failed. Previous version ${before} is recorded in the manifest."

  us_runtipi_wait_api 300 || us_warn "Runtipi did not report healthy after the update."

  after="$(us_runtipi_installed_version || echo "$wanted")"
  us_manifest_set_component runtipi "$after" \
    "$(jq -nc --arg p "$RUNTIPI_VERSION" --arg b "$before" '{policy: $p, previous_version: $b}')"
  us_ok "Runtipi updated: ${before} -> ${after}"
}

update_appstore() {
  us_section "Refreshing app stores"
  [[ "$US_DRY_RUN" == "1" ]] && {
    us_info "DRY-RUN: would pull app stores"
    return 0
  }
  us_runtipi_wait_api 60 || us_die "Runtipi API is not reachable."
  us_runtipi_appstore_pull
  us_ok "App store definitions refreshed"
}

update_nomad() {
  us_section "Updating Project NOMAD"

  us_config_is_true "$INSTALL_PROJECT_NOMAD" ||
    us_die "INSTALL_PROJECT_NOMAD is false; nothing to update."

  local urn before definition
  urn="$(us_runtipi_urn "$US_NOMAD_APP_ID" "$APPSTORE_SLUG")"
  before="$(us_version_installed project_nomad 2>/dev/null || echo 'unknown')"
  definition="$(jq -r '.version' "${US_ROOT_DIR}/appstore/apps/project-nomad/config.json")"

  us_info "Installed: ${before}   App definition in this repo: ${definition}"

  if [[ "$before" == "$definition" ]]; then
    us_ok "Project NOMAD already matches the app definition."
    us_info "To move to a newer upstream release, run ./tools/resolve-versions.sh first,"
    us_info "commit and publish the app store, then rerun this."
    return 0
  fi

  # NOMAD's own updater is deliberately absent from this package, so Runtipi is
  # the only thing that touches these containers. Its update path performs a
  # backup first (performBackup: true).
  us_warn "This recreates NOMAD's core containers. Content and child services are"
  us_warn "not affected: they live in NOMAD's own storage and on its own network."

  if [[ "$US_DRY_RUN" == "1" ]]; then
    us_info "DRY-RUN: would update ${urn} to ${definition}"
    return 0
  fi

  backup_config
  update_appstore

  us_runtipi_api PATCH "app-lifecycle/${urn}/update" '{"performBackup": true}' >/dev/null ||
    us_die "Project NOMAD update failed. Check: docker logs runtipi"

  us_runtipi_app_wait_status "$urn" running 900 ||
    us_die "Project NOMAD did not return to running after the update."

  us_manifest_set_component project_nomad "$definition" \
    "$(jq -nc --arg u "$urn" --arg b "$before" '{urn: $u, previous_version: $b}')"

  us_nomad_verify || us_warn "Post-update verification reported problems."
  us_ok "Project NOMAD updated: ${before} -> ${definition}"
}

if ((do_all)); then
  update_runtipi
  update_appstore
  us_config_is_true "$INSTALL_PROJECT_NOMAD" && update_nomad
else
  case "$target" in
    runtipi) update_runtipi ;;
    appstore) update_appstore ;;
    nomad) update_nomad ;;
    *) us_die "Nothing to do. Try --check or --help." ;;
  esac
fi

us_ok "Update complete. Run ./status.sh to confirm health."
