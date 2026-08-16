#!/usr/bin/env bash
# install.sh - Turn a clean Ubuntu Server into a u-server host.
#
#   cp config/server.env.example server.env
#   nano server.env
#   sudo ./install.sh
#
# Idempotent: rerunning converges configuration. It does not regenerate
# secrets, recreate databases, destroy application data, or upgrade components
# that are already installed (upgrades go through ./update.sh).

set -Eeuo pipefail

US_ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
US_LIB_DIR="${US_ROOT_DIR}/lib"
# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"
# shellcheck source=lib/config.sh
source "${US_LIB_DIR}/config.sh"
# shellcheck source=lib/versions.sh
source "${US_LIB_DIR}/versions.sh"

# Stage list. Each is independently runnable for debugging:
#   sudo scripts/20-runtipi.sh
US_STAGES=(
  "00-preflight"
  "10-docker"
  "20-runtipi"
  "30-runtipi-config"
  "40-adguard"
  "50-local-dns"
  "60-appstore"
  "70-project-nomad"
  "90-verify"
)

usage() {
  cat <<EOF
u-server installer

Usage: sudo ./install.sh [options]

Options:
  --dry-run             Show what would change without changing anything.
  --stage <name>        Run a single stage and stop (repeatable).
  --from <name>         Start at this stage and run the rest.
  --skip <name>         Skip a stage (repeatable).
  --list-stages         Print the stage list and exit.
  --config <path>       Use an alternative server.env (default: ./server.env).
  --verbose             Enable debug logging.
  -h, --help            Show this help.

Stages:
$(printf '  %s\n' "${US_STAGES[@]}")

Examples:
  sudo ./install.sh --dry-run
  sudo ./install.sh --from 40-adguard
  sudo ./install.sh --stage 90-verify
  sudo ./install.sh --skip 70-project-nomad

Configuration lives in ./server.env (copy config/server.env.example).
Logs are written to ${US_LOG_DIR}/.
EOF
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
declare -a only_stages=() skip_stages=()
from_stage=""
config_path=""

while (($#)); do
  case "$1" in
    --dry-run)
      US_DRY_RUN=1
      export US_DRY_RUN
      shift
      ;;
    --stage)
      [[ -n "${2:-}" ]] || us_die "--stage requires a value"
      only_stages+=("$2")
      shift 2
      ;;
    --from)
      [[ -n "${2:-}" ]] || us_die "--from requires a value"
      from_stage="$2"
      shift 2
      ;;
    --skip)
      [[ -n "${2:-}" ]] || us_die "--skip requires a value"
      skip_stages+=("$2")
      shift 2
      ;;
    --config)
      [[ -n "${2:-}" ]] || us_die "--config requires a value"
      config_path="$2"
      shift 2
      ;;
    --list-stages)
      printf '%s\n' "${US_STAGES[@]}"
      exit 0
      ;;
    --verbose)
      US_LOG_LEVEL=debug
      export US_LOG_LEVEL
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) us_die "Unknown option: $1 (try --help)" ;;
  esac
done

us_init "install"

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
[[ "$US_DRY_RUN" == "1" ]] || us_require_root

config_path="${config_path:-${US_ROOT_DIR}/server.env}"
if [[ ! -f "$config_path" && ! -f "$US_INSTALLED_CONFIG" ]]; then
  us_error "No configuration found."
  us_error "Create one first:"
  us_error "    cp config/server.env.example server.env"
  us_error "    nano server.env"
  exit 1
fi

us_config_load "$config_path"

us_section "u-server installation"
us_info "Repository:    ${US_ROOT_DIR}"
us_info "Configuration: ${config_path}"
us_info "Local domain:  ${LOCAL_DOMAIN}"
us_info "Server IP:     ${LAN_IP:-<unset>}"
[[ "$US_DRY_RUN" == "1" ]] && us_warn "DRY RUN — no changes will be made."

if [[ "$US_DRY_RUN" != "1" ]]; then
  us_acquire_lock
  us_ensure_dir "$US_LOG_DIR" 0750
  us_ensure_dir "$US_STATE_DIR" 0755
  us_manifest_init
fi

# ---------------------------------------------------------------------------
# Stage selection
# ---------------------------------------------------------------------------
declare -a run_stages=()

if ((${#only_stages[@]})); then
  run_stages=("${only_stages[@]}")
else
  started=0
  [[ -z "$from_stage" ]] && started=1
  for s in "${US_STAGES[@]}"; do
    [[ "$s" == "$from_stage" ]] && started=1
    ((started)) && run_stages+=("$s")
  done
  [[ -n "$from_stage" ]] && ((${#run_stages[@]} == 0)) &&
    us_die "Unknown stage for --from: ${from_stage}"
fi

should_skip() {
  local s="$1" k
  for k in "${skip_stages[@]+"${skip_stages[@]}"}"; do
    [[ "$k" == "$s" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
start_time="$(date +%s)"
declare -a completed=() skipped=()

for stage in "${run_stages[@]}"; do
  script="${US_ROOT_DIR}/scripts/${stage}.sh"
  [[ -f "$script" ]] || us_die "No such stage: ${stage} (expected ${script})"

  if should_skip "$stage"; then
    us_info "Skipping ${stage} (--skip)"
    skipped+=("$stage")
    continue
  fi

  # Stages run as child processes so one stage's strict-mode failure is
  # reported by this orchestrator rather than silently unwinding it, and so a
  # stage can equally be run standalone.
  if US_DRY_RUN="$US_DRY_RUN" US_LOG_LEVEL="$US_LOG_LEVEL" bash "$script"; then
    completed+=("$stage")
  else
    rc=$?
    us_error "Stage '${stage}' failed (exit ${rc})."
    us_error "Fix the cause, then resume with:"
    us_error "    sudo ./install.sh --from ${stage}"
    exit "$rc"
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ "$US_DRY_RUN" != "1" ]]; then
  us_config_persist
  us_manifest_set_host
fi

elapsed=$(($(date +%s) - start_time))

us_section "Installation complete"
us_ok "Stages run: ${completed[*]:-none}"
((${#skipped[@]})) && us_info "Skipped: ${skipped[*]}"
us_info "Elapsed: $((elapsed / 60))m $((elapsed % 60))s"

if [[ "$US_DRY_RUN" == "1" ]]; then
  us_info "Dry run finished; nothing was changed."
  exit 0
fi

cat >&2 <<EOF

  Service URLs (from any LAN client using this server for DNS):

      http://${LOCAL_DOMAIN}          Runtipi dashboard
      http://${SERVER_DOMAIN}         Runtipi dashboard (alias)
EOF
us_config_is_true "$INSTALL_ADGUARD" &&
  printf '      http://%s             AdGuard Home\n' "$DNS_DOMAIN" >&2
us_config_is_true "$INSTALL_PROJECT_NOMAD" &&
  printf '      http://%s           Project NOMAD\n' "$NOMAD_DOMAIN" >&2
us_config_is_true "$INSTALL_WHOAMI" &&
  printf '      http://%s          Routing test\n' "$WHOAMI_DOMAIN" >&2

cat >&2 <<EOF

  One manual step remains:

      Set your router's DHCP "DNS server" for LAN clients to ${LAN_IP}
      Set only that one address — see docs/dns.md for why a secondary
      public resolver breaks ${LOCAL_DOMAIN} intermittently.

  Then check the platform any time with:

      ./status.sh      concise health summary
      ./doctor.sh      deeper diagnostics
      ./update.sh --check    what upgrades are available

EOF
