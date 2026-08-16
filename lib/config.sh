#!/usr/bin/env bash
# lib/config.sh - Load, validate and derive u-server configuration.
#
# Precedence (lowest to highest):
#   1. defaults in this file
#   2. /etc/u-server/config.env      (installed copy; survives repo deletion)
#   3. ./server.env                  (repo working copy; wins during install)
#   4. environment variables already set by the caller
#
# The repo copy winning over the installed copy is deliberate: editing
# server.env and rerunning install.sh is the documented way to change config.

[[ -n "${_US_CONFIG_SOURCED:-}" ]] && return 0
_US_CONFIG_SOURCED=1

# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"

US_INSTALLED_CONFIG="${US_CONF_DIR}/config.env"
US_SECRETS_FILE="${US_CONF_DIR}/secrets.env"

# _us_source_env <file>
# Sources a KEY=VALUE file without executing arbitrary code. We deliberately
# do not `source` it directly: these files are root-owned but may be edited by
# hand, and a stray backtick should not become code execution.
_us_source_env() {
  local file="$1" line key value
  [[ -f "$file" ]] || return 0
  us_debug "Loading config: ${file}"
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip blanks and comments.
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *=* ]] || continue

    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    # Strip one layer of matching quotes and trailing whitespace.
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" == \"*\" && ${#value} -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    fi

    printf -v "$key" '%s' "$value"
    export "${key?}"
  done <"$file"
}

# us_config_load [repo-server-env-path]
us_config_load() {
  local repo_env="${1:-${US_ROOT_DIR}/server.env}"

  _us_source_env "$US_INSTALLED_CONFIG"
  _us_source_env "$repo_env"
  # Secrets last: they are generated, never hand-edited.
  _us_source_env "$US_SECRETS_FILE"

  # ---- defaults --------------------------------------------------------
  LOCAL_DOMAIN="${LOCAL_DOMAIN:-home.arpa}"
  SERVER_HOSTNAME="${SERVER_HOSTNAME:-}"
  LAN_INTERFACE="${LAN_INTERFACE:-}"
  LAN_IP="${LAN_IP:-}"
  # Operator assertion that a DHCP-assigned LAN_IP is reserved on the router.
  # Preflight cannot detect a reservation, so this is the only way to say so.
  LAN_IP_IS_RESERVED="${LAN_IP_IS_RESERVED:-false}"

  # The Runtipi dashboard is reached at the LOCAL_DOMAIN apex itself — that is
  # what its own Traefik router binds — so there is no separate dashboard
  # hostname to configure.
  DNS_DOMAIN="${DNS_DOMAIN:-dns.${LOCAL_DOMAIN}}"

  RUNTIPI_VERSION="${RUNTIPI_VERSION:-stable}"
  RUNTIPI_ROOT="${RUNTIPI_ROOT:-/opt/runtipi}"

  INSTALL_ADGUARD="${INSTALL_ADGUARD:-true}"

  ADGUARD_UPSTREAM_DNS="${ADGUARD_UPSTREAM_DNS:-https://dns.quad9.net/dns-query 9.9.9.9 149.112.112.112}"
  DISABLE_RESOLVED_STUB="${DISABLE_RESOLVED_STUB:-true}"
  ENABLE_LOCAL_HTTPS="${ENABLE_LOCAL_HTTPS:-false}"
  MANAGE_FIREWALL="${MANAGE_FIREWALL:-false}"

  # ---- auto-detection --------------------------------------------------
  if [[ -z "$LAN_IP" ]]; then
    LAN_IP="$(us_primary_ipv4 || true)"
    [[ -n "$LAN_IP" ]] &&
      us_info "Auto-detected LAN_IP=${LAN_IP} (set it explicitly in server.env to pin it)"
  fi
  if [[ -z "$LAN_INTERFACE" ]]; then
    LAN_INTERFACE="$(us_default_interface || true)"
    [[ -n "$LAN_INTERFACE" ]] &&
      us_info "Auto-detected LAN_INTERFACE=${LAN_INTERFACE}"
  fi

  # ---- derived ---------------------------------------------------------
  # Runtipi routes apps at <localSubdomain>.<LOCAL_DOMAIN>, so we need the
  # single label, not the FQDN.
  DNS_SUBDOMAIN="$(us_config_subdomain_of "$DNS_DOMAIN")"

  export LOCAL_DOMAIN SERVER_HOSTNAME LAN_INTERFACE LAN_IP LAN_IP_IS_RESERVED
  export DNS_DOMAIN
  export DNS_SUBDOMAIN
  export RUNTIPI_VERSION RUNTIPI_ROOT
  export INSTALL_ADGUARD
  export ADGUARD_UPSTREAM_DNS DISABLE_RESOLVED_STUB ENABLE_LOCAL_HTTPS MANAGE_FIREWALL
}

# us_config_subdomain_of <fqdn> - strip the .LOCAL_DOMAIN suffix.
# A name that is not under LOCAL_DOMAIN is a configuration error, because
# Runtipi can only route names it composes as <label>.<LOCAL_DOMAIN>.
us_config_subdomain_of() {
  local fqdn="$1"
  if [[ "$fqdn" == *".${LOCAL_DOMAIN}" ]]; then
    printf '%s' "${fqdn%".${LOCAL_DOMAIN}"}"
  else
    printf '%s' "$fqdn"
  fi
}

us_config_is_true() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# us_config_validate - fail fast on anything that would produce a broken host.
us_config_validate() {
  local errors=0

  if [[ -z "$LAN_IP" ]]; then
    us_error "LAN_IP is empty and could not be auto-detected. Set it in server.env."
    errors=$((errors + 1))
  elif ! us_is_valid_ipv4 "$LAN_IP"; then
    us_error "LAN_IP is not a valid IPv4 address: ${LAN_IP}"
    errors=$((errors + 1))
  fi

  if [[ "$LOCAL_DOMAIN" == *".local" || "$LOCAL_DOMAIN" == "local" ]]; then
    us_error "LOCAL_DOMAIN must not use .local (reserved for mDNS). Use home.arpa."
    errors=$((errors + 1))
  fi

  if [[ ! "$LOCAL_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    us_error "LOCAL_DOMAIN is not a valid domain name: ${LOCAL_DOMAIN}"
    errors=$((errors + 1))
  fi

  # Every service label must satisfy Runtipi's localSubdomain pattern. AdGuard
  # is the only service this installer routes, so there is one label to check
  # and nothing it can collide with.
  if [[ ! "$DNS_SUBDOMAIN" =~ ^[a-zA-Z0-9-]{1,63}$ ]]; then
    us_error "DNS_DOMAIN must be a single label under ${LOCAL_DOMAIN} (got label '${DNS_SUBDOMAIN}')."
    errors=$((errors + 1))
  fi

  if [[ "$RUNTIPI_VERSION" != "stable" && ! "$RUNTIPI_VERSION" =~ ^v?[0-9] ]]; then
    us_error "Version must be 'stable' or an exact tag like v4.10.1 (got '${RUNTIPI_VERSION}')."
    errors=$((errors + 1))
  fi

  ((errors == 0)) || us_die "Configuration invalid (${errors} error(s)). Nothing was changed."
  us_ok "Configuration valid (LAN_IP=${LAN_IP}, LOCAL_DOMAIN=${LOCAL_DOMAIN})"
}

# us_config_persist - copy the effective config to /etc/u-server/config.env so
# status/doctor/update work even if the repo is moved or deleted.
us_config_persist() {
  us_ensure_dir "$US_CONF_DIR" 0755
  {
    echo "# Generated by ${US_PROJECT_NAME} install.sh on $(us_timestamp)"
    echo "# Edit server.env in the repo and rerun install.sh instead of editing this."
    echo
    local k
    for k in SERVER_HOSTNAME LAN_INTERFACE LAN_IP LAN_IP_IS_RESERVED LOCAL_DOMAIN \
      DNS_DOMAIN RUNTIPI_VERSION RUNTIPI_ROOT \
      INSTALL_ADGUARD ADGUARD_UPSTREAM_DNS \
      DISABLE_RESOLVED_STUB ENABLE_LOCAL_HTTPS MANAGE_FIREWALL; do
      printf '%s=%q\n' "$k" "${!k}"
    done
  } | us_write_if_changed "$US_INSTALLED_CONFIG" 0644 || true
}

# us_secret_get_or_create <NAME> [bytes]
# Returns an existing secret or creates one. Never regenerates: rotating a
# secret on rerun would break every service already using it.
us_secret_get_or_create() {
  local name="$1" bytes="${2:-32}" value
  us_ensure_dir "$US_CONF_DIR" 0755
  if [[ -f "$US_SECRETS_FILE" ]]; then
    value="$(awk -F= -v k="$name" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$US_SECRETS_FILE")"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  fi
  value="$(us_gen_secret "$bytes")"
  touch "$US_SECRETS_FILE"
  chmod 0600 "$US_SECRETS_FILE"
  printf '%s=%s\n' "$name" "$value" >>"$US_SECRETS_FILE"
  us_info "Generated new secret ${name} (stored in ${US_SECRETS_FILE})"
  printf '%s' "$value"
}
