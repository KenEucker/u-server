#!/usr/bin/env bash
# lib/adguard.sh - AdGuard Home adapter.
#
# AdGuard runs as an ordinary Runtipi application (the official app store
# already ships `adguard`), so u-server does not install it natively. What
# this module owns is the DNS *policy*: making *.home.arpa resolve to LAN_IP.
#
# Configuration goes through AdGuard's documented HTTP control API rather than
# by editing AdGuardHome.yaml underneath a running process — hand-editing that
# file while AdGuard is up loses writes, because AdGuard rewrites it wholesale
# on shutdown.
#
# The wildcard rewrite is the entire reason a new web app needs no new DNS
# record: AdGuard answers every *.home.arpa name with LAN_IP, and Traefik then
# decides which container serves the request based on the Host header.

[[ -n "${_US_ADGUARD_SOURCED:-}" ]] && return 0
_US_ADGUARD_SOURCED=1

# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"

# AdGuard's Runtipi app id and its default host port (config.json "port": 8104).
US_ADGUARD_APP_ID="adguard"
US_ADGUARD_PORT="${US_ADGUARD_PORT:-8104}"

us_adguard_base_url() { printf 'http://127.0.0.1:%s' "$US_ADGUARD_PORT"; }

# _us_adguard_curl <method> <path> [body]
# The Runtipi adguard app seeds `users: []`, meaning no admin account and no
# authentication on the control API. We still send credentials when the
# operator has set them, so this keeps working after they add a password.
_us_adguard_curl() {
  local method="$1" path="$2" body="${3:-}"
  local -a args=(-sS --max-time 20 -X "$method" -H 'Content-Type: application/json' -w '\n%{http_code}')
  [[ -n "${ADGUARD_USERNAME:-}" ]] && args+=(-u "${ADGUARD_USERNAME}:${ADGUARD_PASSWORD:-}")
  [[ -n "$body" ]] && args+=(-d "$body")

  local resp code payload
  resp="$(curl "${args[@]}" "$(us_adguard_base_url)${path}" 2>&1)" || return 1
  code="${resp##*$'\n'}"
  payload="${resp%$'\n'*}"

  if [[ "$code" =~ ^2 ]]; then
    printf '%s' "$payload"
    return 0
  fi
  us_debug "AdGuard ${method} ${path} -> HTTP ${code}: ${payload}"
  return 1
}

us_adguard_reachable() {
  _us_adguard_curl GET /control/status >/dev/null 2>&1
}

# us_adguard_wait <timeout>
us_adguard_wait() {
  local timeout="${1:-120}" waited=0
  us_info "Waiting for the AdGuard control API on $(us_adguard_base_url)"
  while ((waited < timeout)); do
    us_adguard_reachable && {
      us_ok "AdGuard is responding"
      return 0
    }
    sleep 3
    waited=$((waited + 3))
  done
  us_error "AdGuard did not respond within ${timeout}s."
  us_error "Inspect: docker ps | grep adguard  /  docker logs <adguard container>"
  return 1
}

us_adguard_rewrite_list() {
  _us_adguard_curl GET /control/rewrite/list
}

us_adguard_rewrite_exists() {
  local domain="$1" answer="$2" json
  json="$(us_adguard_rewrite_list 2>/dev/null)" || return 1
  printf '%s' "$json" |
    jq -e --arg d "$domain" --arg a "$answer" \
      '.[]? | select(.domain == $d and .answer == $a)' >/dev/null 2>&1
}

# us_adguard_rewrite_ensure <domain> <answer>
# Idempotent. If the domain exists pointing somewhere else (e.g. LAN_IP
# changed) the stale entry is removed first rather than left to shadow the new
# one — AdGuard would otherwise keep answering with the old address.
us_adguard_rewrite_ensure() {
  local domain="$1" answer="$2" json existing

  if us_adguard_rewrite_exists "$domain" "$answer"; then
    us_ok "DNS rewrite already present: ${domain} -> ${answer}"
    return 0
  fi

  if [[ "$US_DRY_RUN" == "1" ]]; then
    us_info "DRY-RUN: would add DNS rewrite ${domain} -> ${answer}"
    return 0
  fi

  json="$(us_adguard_rewrite_list 2>/dev/null || printf '[]')"
  existing="$(printf '%s' "$json" | jq -r --arg d "$domain" \
    '.[]? | select(.domain == $d) | .answer')"

  local old
  while IFS= read -r old; do
    [[ -n "$old" ]] || continue
    us_warn "Removing stale rewrite ${domain} -> ${old}"
    _us_adguard_curl POST /control/rewrite/delete \
      "$(jq -nc --arg d "$domain" --arg a "$old" '{domain:$d, answer:$a}')" >/dev/null || true
  done <<<"$existing"

  us_info "Adding DNS rewrite ${domain} -> ${answer}"
  _us_adguard_curl POST /control/rewrite/add \
    "$(jq -nc --arg d "$domain" --arg a "$answer" '{domain:$d, answer:$a}')" >/dev/null ||
    us_die "Could not add the DNS rewrite ${domain} -> ${answer}."

  us_ok "DNS rewrite ${domain} -> ${answer}"
}

# us_adguard_configure_wildcard
# Two entries are required, not one:
#   *.home.arpa  covers every service hostname (nomad, dns, whoami, ...)
#   home.arpa    covers the apex, which the wildcard does NOT match and which
#                Runtipi's dashboard router binds natively.
us_adguard_configure_wildcard() {
  us_adguard_rewrite_ensure "*.${LOCAL_DOMAIN}" "$LAN_IP"
  us_adguard_rewrite_ensure "${LOCAL_DOMAIN}" "$LAN_IP"
}

# us_adguard_configure_upstreams
# Upstream resolvers are used only for names AdGuard cannot answer locally.
# Rewrites are matched before forwarding, so home.arpa keeps resolving with the
# WAN unplugged; upstream failures degrade Internet name resolution only.
us_adguard_configure_upstreams() {
  local -a upstreams=()
  read -r -a upstreams <<<"$ADGUARD_UPSTREAM_DNS"
  ((${#upstreams[@]})) || {
    us_warn "ADGUARD_UPSTREAM_DNS is empty; leaving AdGuard's upstreams untouched."
    return 0
  }

  if [[ "$US_DRY_RUN" == "1" ]]; then
    us_info "DRY-RUN: would set AdGuard upstreams: ${upstreams[*]}"
    return 0
  fi

  local body
  body="$(jq -nc --args '{upstream_dns: $ARGS.positional}' "${upstreams[@]}")"

  if _us_adguard_curl POST /control/dns_config "$body" >/dev/null 2>&1; then
    us_ok "AdGuard upstream resolvers set (${#upstreams[@]} entries)"
  else
    us_warn "Could not set AdGuard upstreams via the API; configure them in the AdGuard UI at http://${DNS_DOMAIN}"
  fi
}

# us_adguard_verify_resolution <name>
# Ask AdGuard directly, bypassing the host resolver, so we test the server
# rather than whatever /etc/resolv.conf happens to say.
us_adguard_verify_resolution() {
  local name="$1" expect="${2:-$LAN_IP}" got
  us_have dig || {
    us_warn "dig not available; skipping resolution check for ${name}"
    return 0
  }
  got="$(dig +short +timeout=3 +tries=2 "@${LAN_IP}" "$name" A 2>/dev/null | tail -n1)"
  if [[ "$got" == "$expect" ]]; then
    return 0
  fi
  us_debug "Resolution check ${name}: got '${got:-<none>}', expected '${expect}'"
  return 1
}
