#!/usr/bin/env bash
# lib/common.sh - Shared primitives for every u-server script.
#
# Source this first; it pulls in logging.sh and installs the error trap.
#
#   US_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${US_LIB_DIR}/common.sh"

[[ -n "${_US_COMMON_SOURCED:-}" ]] && return 0
_US_COMMON_SOURCED=1

# US_LIB_DIR / US_ROOT_DIR are resolved from this file's own location so that
# stages work whether invoked as ./install.sh or sudo scripts/20-runtipi.sh.
US_LIB_DIR="${US_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
US_ROOT_DIR="${US_ROOT_DIR:-$(cd -- "${US_LIB_DIR}/.." && pwd)}"
export US_LIB_DIR US_ROOT_DIR

# shellcheck source=lib/logging.sh
source "${US_LIB_DIR}/logging.sh"

# ---------------------------------------------------------------------------
# Project identity and well-known paths
# ---------------------------------------------------------------------------
# Neutral project slug, derived from the repository name. Deliberately not
# "nomad-*" or "meridian-*": those are workloads, not the platform.
US_PROJECT_NAME="u-server"
US_CONF_DIR="/etc/${US_PROJECT_NAME}"
US_STATE_DIR="/var/lib/${US_PROJECT_NAME}"
US_LOG_DIR="/var/log/${US_PROJECT_NAME}"
US_MANIFEST_FILE="${US_STATE_DIR}/installed-manifest.json"
US_LOCK_FILE="${US_STATE_DIR}/install.lock"
export US_PROJECT_NAME US_CONF_DIR US_STATE_DIR US_LOG_DIR US_MANIFEST_FILE

# US_DRY_RUN=1 makes us_run print instead of execute.
US_DRY_RUN="${US_DRY_RUN:-0}"

# ---------------------------------------------------------------------------
# Error trap
# ---------------------------------------------------------------------------
# Reports script, line, failing command and the component that was running.
# Installed by us_init; relies on `set -E` so it fires inside functions.
_us_on_error() {
  local exit_code=$1 line=$2 cmd=$3 src=$4
  us_error "Command failed (exit ${exit_code})"
  us_error "  script:    ${src}"
  us_error "  line:      ${line}"
  us_error "  command:   ${cmd}"
  us_error "  component: ${US_COMPONENT:-unknown}"
  [[ -n "${US_LOG_FILE:-}" ]] && us_error "  log:       ${US_LOG_FILE}"
  return "$exit_code"
}

# us_init <component-name>
# Sets strict mode, the error trap, and opens the component logfile.
us_init() {
  US_COMPONENT="${1:-u-server}"
  export US_COMPONENT
  set -Eeuo pipefail
  trap '_us_on_error "$?" "$LINENO" "$BASH_COMMAND" "${BASH_SOURCE[0]}"' ERR
  # Logfile is best-effort: non-root callers (status.sh) simply log to console.
  if [[ "$(id -u)" -eq 0 ]]; then
    us_log_open "${US_LOG_DIR}/${US_COMPONENT}.log"
  fi
}

# ---------------------------------------------------------------------------
# Guards and small helpers
# ---------------------------------------------------------------------------

us_die() {
  us_error "$@"
  exit 1
}

us_have() { command -v "$1" >/dev/null 2>&1; }

us_require_root() {
  [[ "$(id -u)" -eq 0 ]] ||
    us_die "This must be run as root. Try: sudo $0"
}

us_require_cmds() {
  local missing=()
  local c
  for c in "$@"; do
    us_have "$c" || missing+=("$c")
  done
  ((${#missing[@]} == 0)) ||
    us_die "Missing required command(s): ${missing[*]}"
}

# us_run <cmd...> - execute, honouring --dry-run.
# stderr is deliberately NOT redirected: hiding it hides the cause of failures.
us_run() {
  if [[ "$US_DRY_RUN" == "1" ]]; then
    us_info "DRY-RUN: $*"
    return 0
  fi
  us_debug "exec: $*"
  "$@"
}

# us_retry <attempts> <delay-seconds> <cmd...>
# For network operations only. Never wrap idempotency-sensitive local work.
us_retry() {
  local attempts="$1" delay="$2"
  shift 2
  local n=1
  while true; do
    if "$@"; then
      return 0
    fi
    if ((n >= attempts)); then
      us_error "Command failed after ${attempts} attempt(s): $*"
      return 1
    fi
    us_warn "Attempt ${n}/${attempts} failed; retrying in ${delay}s: $*"
    sleep "$delay"
    ((n++))
  done
}

# ---------------------------------------------------------------------------
# Idempotency helpers
# ---------------------------------------------------------------------------

# us_write_if_changed <path> <mode> - content on stdin.
# Writes only when content actually differs, so reruns don't churn mtimes or
# trigger needless service reloads. Returns 0 if changed, 1 if identical.
us_write_if_changed() {
  local path="$1" mode="${2:-0644}" tmp
  tmp="$(mktemp)"
  cat >"$tmp"

  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    us_debug "Unchanged: ${path}"
    return 1
  fi

  if [[ "$US_DRY_RUN" == "1" ]]; then
    us_info "DRY-RUN: would write ${path}"
    if [[ -f "$path" ]]; then
      us_info "DRY-RUN: diff follows"
      diff -u "$path" "$tmp" >&2 || true
    fi
    rm -f "$tmp"
    return 0
  fi

  mkdir -p -- "$(dirname -- "$path")"
  # Back up the previous version once per change; cheap insurance during
  # convergence runs.
  [[ -f "$path" ]] && cp -a -- "$path" "${path}.bak.$(date -u '+%Y%m%dT%H%M%SZ')"
  mv -- "$tmp" "$path"
  chmod "$mode" -- "$path"
  us_ok "Wrote ${path}"
  return 0
}

# us_ensure_dir <path> [mode] [owner]
us_ensure_dir() {
  local path="$1" mode="${2:-0755}" owner="${3:-}"
  if [[ ! -d "$path" ]]; then
    us_run mkdir -p -- "$path"
    us_debug "Created ${path}"
  fi
  us_run chmod "$mode" -- "$path"
  [[ -n "$owner" ]] && us_run chown "$owner" -- "$path"
  return 0
}

# us_gen_secret [bytes] - URL-safe random secret.
# Callers must only invoke this when the secret does not already exist;
# regenerating secrets on rerun would break running services.
us_gen_secret() {
  local bytes="${1:-32}"
  openssl rand -hex "$bytes" 2>/dev/null ||
    head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# ---------------------------------------------------------------------------
# Single-instance lock
# ---------------------------------------------------------------------------
# Prevents two concurrent installs from racing on Docker/Runtipi state.
us_acquire_lock() {
  [[ "$US_DRY_RUN" == "1" ]] && return 0
  us_ensure_dir "$US_STATE_DIR" 0755
  exec {_US_LOCK_FD}>"$US_LOCK_FILE"
  if ! flock -n "$_US_LOCK_FD"; then
    us_die "Another ${US_PROJECT_NAME} operation is already running (lock: ${US_LOCK_FILE})."
  fi
}

# ---------------------------------------------------------------------------
# Networking / misc
# ---------------------------------------------------------------------------

us_is_valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o
  for o in ${ip//./ }; do
    ((o <= 255)) || return 1
  done
  return 0
}

# us_primary_ipv4 - best-guess LAN address (the source IP for default route).
us_primary_ipv4() {
  ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

# us_default_interface - interface backing the default route.
us_default_interface() {
  ip -4 route show default 2>/dev/null | awk '{print $5; exit}'
}

# us_port_listener <port> <proto> - who (if anyone) holds a port.
# Empty output means the port is free.
us_port_listener() {
  local port="$1" proto="${2:-tcp}" flag='-t'
  [[ "$proto" == "udp" ]] && flag='-u'
  ss -lnp "$flag" 2>/dev/null |
    awk -v p=":${port}\$" 'NR>1 && $4 ~ p {print $NF; exit}'
}

# us_have_internet - single fast reachability probe; used only to choose
# behaviour, never to gate local functionality.
us_have_internet() {
  curl -fsS --max-time 5 -o /dev/null https://api.github.com/ 2>/dev/null
}

us_timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
