#!/usr/bin/env bash
# lib/logging.sh - Structured, greppable logging for u-server.
#
# Levels: DEBUG < INFO < OK/WARN < ERROR
# Every message goes to stderr (so stdout stays clean for machine-readable
# output) and, once us_log_open is called, is also appended to a logfile.
#
# Never sourced directly by the user; sourced via lib/common.sh.

# Guard against double-sourcing.
[[ -n "${_US_LOGGING_SOURCED:-}" ]] && return 0
_US_LOGGING_SOURCED=1

# ---------------------------------------------------------------------------
# Colour handling
# ---------------------------------------------------------------------------
# Colour only when stderr is a TTY and NO_COLOR is unset (https://no-color.org).
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  _US_C_RESET=$'\033[0m'
  _US_C_DIM=$'\033[2m'
  _US_C_RED=$'\033[31m'
  _US_C_GREEN=$'\033[32m'
  _US_C_YELLOW=$'\033[33m'
  _US_C_BLUE=$'\033[34m'
else
  _US_C_RESET='' _US_C_DIM='' _US_C_RED='' _US_C_GREEN='' _US_C_YELLOW='' _US_C_BLUE=''
fi

# US_LOG_LEVEL: debug|info|warn|error. Default info.
US_LOG_LEVEL="${US_LOG_LEVEL:-info}"

_us_level_num() {
  case "${1,,}" in
    debug) printf '10' ;;
    info) printf '20' ;;
    ok) printf '20' ;;
    warn) printf '30' ;;
    error) printf '40' ;;
    *) printf '20' ;;
  esac
}

# us_log_open <path>
# Begin appending all log output to <path>. Safe to call more than once.
# If the file cannot be created we warn and continue with console-only logging;
# losing the logfile must never abort an installation.
us_log_open() {
  local path="$1" dir
  dir="$(dirname -- "$path")"
  if ! mkdir -p -- "$dir" 2>/dev/null; then
    US_LOG_FILE=''
    us_warn "Cannot create log directory ${dir}; continuing without a logfile."
    return 0
  fi
  if ! touch -- "$path" 2>/dev/null; then
    US_LOG_FILE=''
    us_warn "Cannot write logfile ${path}; continuing without a logfile."
    return 0
  fi
  US_LOG_FILE="$path"
  # Logs can contain hostnames and paths; keep them root-readable only.
  chmod 0640 -- "$path" 2>/dev/null || true
  printf '\n===== %s :: %s :: pid=%s =====\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${US_COMPONENT:-u-server}" "$$" >>"$path"
}

# _us_emit <level> <colour> <message...>
_us_emit() {
  local level="$1" colour="$2"
  shift 2
  local msg="$*"

  local want cur
  want="$(_us_level_num "$level")"
  cur="$(_us_level_num "$US_LOG_LEVEL")"
  ((want < cur)) && return 0

  # Component tag lets a reader tell which stage produced a line.
  local tag=''
  [[ -n "${US_COMPONENT:-}" ]] && tag=" ${_US_C_DIM}(${US_COMPONENT})${_US_C_RESET}"

  printf '%s[%s]%s%s %s\n' "$colour" "$level" "$_US_C_RESET" "$tag" "$msg" >&2

  if [[ -n "${US_LOG_FILE:-}" ]]; then
    printf '%s [%s] (%s) %s\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "${US_COMPONENT:-u-server}" "$msg" \
      >>"$US_LOG_FILE" 2>/dev/null || true
  fi
}

us_debug() { _us_emit DEBUG "$_US_C_DIM" "$@"; }
us_info() { _us_emit INFO "$_US_C_BLUE" "$@"; }
us_ok() { _us_emit OK "$_US_C_GREEN" "$@"; }
us_warn() { _us_emit WARN "$_US_C_YELLOW" "$@"; }
us_error() { _us_emit ERROR "$_US_C_RED" "$@"; }

# us_section <title> - visual separator between installation stages.
us_section() {
  printf '\n%s==>%s %s%s%s\n' \
    "$_US_C_BLUE" "$_US_C_RESET" "${_US_C_BLUE}" "$*" "$_US_C_RESET" >&2
  if [[ -n "${US_LOG_FILE:-}" ]]; then
    printf '\n--- %s ---\n' "$*" >>"$US_LOG_FILE" 2>/dev/null || true
  fi
}

# Status markers used by status.sh / doctor.sh so their output stays aligned
# and machine-greppable.
us_status_ok() { printf '  %s[OK]%s   %s\n' "$_US_C_GREEN" "$_US_C_RESET" "$*"; }
us_status_warn() { printf '  %s[WARN]%s %s\n' "$_US_C_YELLOW" "$_US_C_RESET" "$*"; }
us_status_fail() { printf '  %s[FAIL]%s %s\n' "$_US_C_RED" "$_US_C_RESET" "$*"; }
us_status_skip() { printf '  %s[--]%s   %s\n' "$_US_C_DIM" "$_US_C_RESET" "$*"; }
