#!/usr/bin/env bash
# uninstall.sh - Remove u-server's changes to this host.
#
# Defaults are conservative: application data is PRESERVED unless you ask for
# it to be destroyed, and Docker Engine is never removed (other things on this
# machine may depend on it).
#
#   sudo ./uninstall.sh                  stop and remove the platform, keep data
#   sudo ./uninstall.sh --purge-data     also delete application data (irreversible)
#   sudo ./uninstall.sh --dry-run        show what would be removed

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

purge_data=0
assume_yes=0

while (($#)); do
  case "$1" in
    --purge-data)
      purge_data=1
      shift
      ;;
    --dry-run)
      US_DRY_RUN=1
      export US_DRY_RUN
      shift
      ;;
    --yes | -y)
      assume_yes=1
      shift
      ;;
    -h | --help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) us_die "Unknown option: $1" ;;
  esac
done

us_init "uninstall"
[[ "$US_DRY_RUN" == "1" ]] || us_require_root
us_config_load

appdata="$(us_runtipi_appdata_dir 2>/dev/null || echo '?')"

us_section "Uninstall u-server"

cat >&2 <<EOF

  This will:
    - stop and remove Runtipi and all its application containers
    - remove the Runtipi installation at $(us_runtipi_root)
    - restore systemd-resolved's stub listener (host DNS returns to normal)
    - remove ${US_CONF_DIR}, ${US_STATE_DIR}

  This will NOT:
    - remove Docker Engine or any non-Runtipi container
    - change your router's DHCP/DNS settings
EOF

if ((purge_data)); then
  cat >&2 <<EOF

  --purge-data WAS GIVEN. Application data WILL BE DELETED:
      ${appdata}
  That includes Project NOMAD content, databases, and every app's data.
  This cannot be undone.
EOF
else
  cat >&2 <<EOF
    - delete application data (preserved at ${appdata})
EOF
fi

printf '\n' >&2

if [[ "$US_DRY_RUN" != "1" ]] && ((!assume_yes)); then
  read -rp "Type 'yes' to continue: " reply
  [[ "$reply" == "yes" ]] || {
    us_info "Aborted; nothing was changed."
    exit 0
  }
fi

# --- Stop the platform -----------------------------------------------------
if [[ -x "$(us_runtipi_cli)" ]]; then
  us_info "Stopping Runtipi"
  us_runtipi_stop || true
fi

# Remove the NOMAD child network if nothing is using it. Containers NOMAD
# created are the user's data plane, so we only remove the empty network.
if us_docker_network_exists "$(us_nomad_network_name)" 2>/dev/null; then
  if [[ -z "$(us_nomad_child_services)" ]]; then
    us_run docker network rm "$(us_nomad_network_name)" || true
  else
    us_warn "Network $(us_nomad_network_name) still has containers attached; leaving it."
    us_warn "Remove them from Docker manually if you want it gone."
  fi
fi

# --- Restore host DNS ------------------------------------------------------
dropin="/etc/systemd/resolved.conf.d/60-${US_PROJECT_NAME}.conf"
if [[ -f "$dropin" ]]; then
  us_info "Restoring systemd-resolved configuration"
  us_run rm -f "$dropin"
  us_run systemctl restart systemd-resolved || true
  if [[ -f /run/systemd/resolve/stub-resolv.conf ]]; then
    us_run ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  fi
  if [[ "$US_DRY_RUN" != "1" ]]; then
    getent hosts github.com >/dev/null 2>&1 &&
      us_ok "Host DNS restored" ||
      us_warn "Host cannot resolve github.com; check /etc/resolv.conf manually."
  fi
fi

# --- Remove files ----------------------------------------------------------
if ((purge_data)); then
  us_warn "Deleting application data at $(us_runtipi_root)"
  us_run rm -rf -- "$(us_runtipi_root)"
else
  # Keep the data, drop the binary, so a reinstall reuses existing app data.
  [[ -f "$(us_runtipi_cli)" ]] && us_run rm -f -- "$(us_runtipi_cli)"
  us_info "Application data preserved at ${appdata}"
fi

for d in "$US_CONF_DIR" "$US_STATE_DIR"; do
  [[ -d "$d" ]] && us_run rm -rf -- "$d"
done

us_info "Logs kept at ${US_LOG_DIR} (remove manually if you want them gone)."
us_ok "Uninstall complete."

((purge_data)) || {
  us_info "Application data was preserved. To reinstall over it:"
  us_info "    sudo ./install.sh"
}
