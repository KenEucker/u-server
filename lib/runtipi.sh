#!/usr/bin/env bash
# lib/runtipi.sh - Runtipi adapter.
#
# ALL Runtipi-specific knowledge lives here. If upstream renames a release
# asset, moves its data directory, or changes an API route, this is the only
# file that should need editing.
#
# Verified against runtipi/runtipi @ v4.10.1 (2026-08). Key facts, each read
# from source rather than documentation:
#
#   * CLI binaries are assets on runtipi/runtipi releases, NOT runtipi/cli.
#     runtipi/cli holds the Go source but its releases lag (v4.2.1 vs v4.10.1).
#     Asset names: runtipi-cli-linux-{x86_64,aarch64}.tar.gz
#     (scripts/install.sh, and confirmed against the releases API)
#
#   * The dashboard's Traefik router binds Host(`${LOCAL_DOMAIN}`) — the BARE
#     domain, not a subdomain. Apps bind Host(`<localSubdomain>.${LOCAL_DOMAIN}`).
#     (docker-compose.prod.yml labels; traefik-labels.builder.ts)
#
#   * Settings live in <data>/state/settings.json and are validated as a
#     PARTIAL schema, so writing only the keys we care about is supported.
#     (common/helpers/env-helpers.ts:47, app.dto.ts settingsSchema)
#
#   * The CLI authenticates to the local API by minting an HS256 JWT with
#     subject "cli" from JWT_SECRET in <data>/.env. We reproduce that exactly,
#     which lets us drive endpoints the CLI has no subcommand for — notably
#     app installation. (runtipi/cli internal/utils/api.go)

[[ -n "${_US_RUNTIPI_SOURCED:-}" ]] && return 0
_US_RUNTIPI_SOURCED=1

# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"
# shellcheck source=lib/versions.sh
source "${US_LIB_DIR}/versions.sh"

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

us_runtipi_root() { printf '%s' "${RUNTIPI_ROOT:-/opt/runtipi}"; }
us_runtipi_cli() { printf '%s/runtipi-cli' "$(us_runtipi_root)"; }

# us_runtipi_data_dir - locate the runtime data directory.
# Detected rather than assumed: upstream has used both <root>/.internal and
# <root> directly depending on how the CLI was invoked.
us_runtipi_data_dir() {
  local root
  root="$(us_runtipi_root)"
  if [[ -d "${root}/.internal/state" || -f "${root}/.internal/.env" ]]; then
    printf '%s/.internal' "$root"
  elif [[ -d "${root}/state" || -f "${root}/.env" ]]; then
    printf '%s' "$root"
  else
    # Not yet initialised — this is where the CLI will create it.
    printf '%s/.internal' "$root"
  fi
}

us_runtipi_env_file() {
  local root
  root="$(us_runtipi_root)"
  # The CLI writes .env at the project root next to the binary.
  if [[ -f "${root}/.env" ]]; then
    printf '%s/.env' "$root"
  else
    printf '%s/.env' "$(us_runtipi_data_dir)"
  fi
}

us_runtipi_settings_file() { printf '%s/state/settings.json' "$(us_runtipi_data_dir)"; }
us_runtipi_traefik_dynamic_dir() { printf '%s/traefik/dynamic' "$(us_runtipi_data_dir)"; }
us_runtipi_appdata_dir() { printf '%s/app-data' "$(us_runtipi_data_dir)"; }
us_runtipi_repos_dir() { printf '%s/repos' "$(us_runtipi_data_dir)"; }

# ---------------------------------------------------------------------------
# Release assets
# ---------------------------------------------------------------------------

# us_runtipi_asset_name - map machine architecture to upstream asset naming.
us_runtipi_asset_name() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64 | amd64) printf 'runtipi-cli-linux-x86_64.tar.gz' ;;
    aarch64 | arm64) printf 'runtipi-cli-linux-aarch64.tar.gz' ;;
    *)
      us_error "Unsupported architecture '${machine}'. Runtipi publishes x86_64 and aarch64 only."
      return 1
      ;;
  esac
}

us_runtipi_installed_version() {
  local cli
  cli="$(us_runtipi_cli)"
  [[ -x "$cli" ]] || return 1
  # `runtipi-cli version` prints the CLI version; normalise to a leading v.
  local out
  out="$("$cli" version 2>/dev/null | tr -d '\r' | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1)" || return 1
  [[ -n "$out" ]] || return 1
  [[ "$out" == v* ]] || out="v${out}"
  printf '%s' "$out"
}

# us_runtipi_fetch_cli <version>
# Download + extract the CLI for an exact version. Idempotent: skips when the
# installed CLI already reports that version.
#
# Upstream publishes no per-asset checksum file alongside these releases (there
# is no .sha256 asset — verified against the releases API), so we cannot verify
# a published digest. We instead record the digest we actually installed in the
# manifest, which gives the future offline bundler something to pin against and
# makes tampering after the fact detectable. Transport security is TLS via curl.
us_runtipi_fetch_cli() {
  local version="$1" root cli asset url tmpdir sha
  root="$(us_runtipi_root)"
  cli="$(us_runtipi_cli)"

  local current
  if current="$(us_runtipi_installed_version 2>/dev/null)" && [[ "$current" == "$version" ]]; then
    us_ok "Runtipi CLI ${version} already installed"
    return 0
  fi
  [[ -n "${current:-}" ]] &&
    us_info "Runtipi CLI ${current} installed; switching to ${version}"

  asset="$(us_runtipi_asset_name)" || return 1
  us_info "Resolving asset ${asset} for ${US_RUNTIPI_REPO}@${version}"
  url="$(us_gh_asset_url "$US_RUNTIPI_REPO" "$version" "$asset")" || return 1

  if [[ "$US_DRY_RUN" == "1" ]]; then
    us_info "DRY-RUN: would download ${url} -> ${cli}"
    return 0
  fi

  us_ensure_dir "$root" 0755
  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand tmpdir now, on purpose
  trap "rm -rf '${tmpdir}'" RETURN

  us_info "Downloading ${url}"
  us_retry 3 5 curl -fsSL --max-time 300 -o "${tmpdir}/cli.tar.gz" "$url" ||
    us_die "Download failed: ${url}"

  sha="$(sha256sum "${tmpdir}/cli.tar.gz" | awk '{print $1}')"
  us_info "Downloaded artifact sha256=${sha}"

  tar -xzf "${tmpdir}/cli.tar.gz" -C "$tmpdir" ||
    us_die "Could not extract ${asset}; upstream archive layout may have changed."

  local extracted
  extracted="$(find "$tmpdir" -maxdepth 2 -type f -name 'runtipi-cli*' ! -name '*.tar.gz' | head -n1)"
  [[ -n "$extracted" ]] ||
    us_die "Archive ${asset} did not contain a runtipi-cli binary; upstream layout changed."

  install -m 0755 "$extracted" "$cli" || us_die "Could not install CLI to ${cli}"
  us_ok "Installed Runtipi CLI ${version} at ${cli}"

  US_RUNTIPI_ARTIFACT_SHA256="$sha"
  export US_RUNTIPI_ARTIFACT_SHA256
}

# ---------------------------------------------------------------------------
# Settings and environment
# ---------------------------------------------------------------------------

us_runtipi_env_get() {
  local key="$1" file
  file="$(us_runtipi_env_file)"
  [[ -f "$file" ]] || return 1
  local v
  v="$(awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file")"
  [[ -n "$v" ]] || return 1
  printf '%s' "$v"
}

# us_runtipi_settings_merge <json>
# Merge keys into state/settings.json. This is the supported configuration
# surface (the file is parsed with settingsSchema.partial()), so we never have
# to hand-edit generated files behind Runtipi's back.
us_runtipi_settings_merge() {
  local patch="$1" file tmp
  file="$(us_runtipi_settings_file)"

  if [[ "$US_DRY_RUN" == "1" ]]; then
    us_info "DRY-RUN: would merge into ${file}: ${patch}"
    return 0
  fi

  us_ensure_dir "$(dirname "$file")" 0755
  [[ -f "$file" ]] || printf '{}\n' >"$file"

  # Preserve any keys the operator set by hand; we only add/override ours.
  tmp="$(mktemp)"
  if ! jq --argjson p "$patch" '. * $p' "$file" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    us_die "Could not merge settings into ${file} (is it valid JSON?)."
  fi

  if cmp -s "$tmp" "$file"; then
    rm -f "$tmp"
    us_debug "Runtipi settings already correct"
    return 1
  fi

  cp -a "$file" "${file}.bak.$(date -u '+%Y%m%dT%H%M%SZ')"
  mv "$tmp" "$file"
  chmod 0644 "$file"
  us_ok "Updated ${file}"
  return 0
}

# us_runtipi_configure_local_domain
# Point Runtipi's local domain at LOCAL_DOMAIN so every app is routed at
# <subdomain>.<LOCAL_DOMAIN>.
#
# Returns 0 if settings actually changed, 1 if they were already correct, so
# the caller can restart Runtipi only when it is genuinely needed. Swallowing
# that distinction would restart the platform on every install rerun.
us_runtipi_configure_local_domain() {
  local patch rc=0
  patch="$(jq -nc \
    --arg ld "$LOCAL_DOMAIN" \
    --arg ip "$LAN_IP" \
    '{localDomain: $ld, listenIp: $ip, internalIp: $ip}')"
  us_runtipi_settings_merge "$patch" || rc=$?
  return "$rc"
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

us_runtipi_start() {
  local root cli
  root="$(us_runtipi_root)"
  cli="$(us_runtipi_cli)"
  [[ -x "$cli" ]] || us_die "Runtipi CLI not found at ${cli}; run scripts/20-runtipi.sh first."

  if [[ "$US_DRY_RUN" == "1" ]]; then
    us_info "DRY-RUN: would run ${cli} start (cwd ${root})"
    return 0
  fi

  us_info "Starting Runtipi (this pulls images on first run and can take several minutes)"
  # The CLI resolves its data directory from the working directory.
  ( cd "$root" && ./runtipi-cli start ) ||
    us_die "runtipi-cli start failed. See ${root}/logs/ and 'docker ps -a'."
}

us_runtipi_stop() {
  local root cli
  root="$(us_runtipi_root)"
  cli="$(us_runtipi_cli)"
  [[ -x "$cli" ]] || return 0
  ( cd "$root" && ./runtipi-cli stop ) || us_warn "runtipi-cli stop reported an error"
}

us_runtipi_is_running() {
  us_docker_container_healthy runtipi 2>/dev/null ||
    [[ "$(us_docker_container_state runtipi 2>/dev/null)" == "running" ]]
}

# ---------------------------------------------------------------------------
# Local API access
# ---------------------------------------------------------------------------

us_runtipi_api_base() {
  local ip port
  ip="$(us_runtipi_env_get INTERNAL_IP 2>/dev/null || printf '127.0.0.1')"
  port="$(us_runtipi_env_get NGINX_PORT 2>/dev/null || printf '80')"
  printf 'http://%s:%s/api' "$ip" "$port"
}

# _us_b64url - base64url without padding, as JWT requires.
_us_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# us_runtipi_jwt - mint the same token the CLI does.
# Mirrors runtipi/cli internal/utils/api.go CreateToken(): HS256, sub "cli",
# with iat/nbf/exp claims, signed with JWT_SECRET from Runtipi's .env.
us_runtipi_jwt() {
  local secret now exp header payload signing sig
  secret="$(us_runtipi_env_get JWT_SECRET)" ||
    us_die "JWT_SECRET not found in $(us_runtipi_env_file); is Runtipi initialised?"

  now="$(date +%s)"
  exp=$((now + 3600))

  header="$(printf '{"alg":"HS256","typ":"JWT"}' | _us_b64url)"
  payload="$(jq -nc --argjson n "$now" --argjson e "$exp" \
    '{sub:"cli", iat:$n, nbf:$n, exp:$e}' | _us_b64url)"
  signing="${header}.${payload}"

  sig="$(printf '%s' "$signing" |
    openssl dgst -sha256 -hmac "$secret" -binary | _us_b64url)"

  printf '%s.%s' "$signing" "$sig"
}

# us_runtipi_api <method> <path> [json-body]
# Prints the response body; returns non-zero on a non-2xx status.
us_runtipi_api() {
  local method="$1" path="$2" body="${3:-}"
  local base token url resp code
  base="$(us_runtipi_api_base)"
  token="$(us_runtipi_jwt)" || return 1
  url="${base}/${path#/}"

  local -a args=(-sS --max-time 120 -X "$method"
    -H "Authorization: Bearer ${token}"
    -H 'Content-Type: application/json'
    -w '\n%{http_code}')
  [[ -n "$body" ]] && args+=(-d "$body")

  resp="$(curl "${args[@]}" "$url" 2>&1)" || {
    us_error "API request failed: ${method} ${url}"
    return 1
  }

  code="${resp##*$'\n'}"
  local payload="${resp%$'\n'*}"

  if [[ "$code" =~ ^2 ]]; then
    printf '%s' "$payload"
    return 0
  fi

  us_error "API ${method} ${path} returned HTTP ${code}"
  [[ -n "$payload" ]] && us_error "  response: ${payload}"
  return 1
}

# us_runtipi_wait_api <timeout-seconds>
# Runtipi's start returns before the API is necessarily serving; poll health.
us_runtipi_wait_api() {
  local timeout="${1:-180}" waited=0 base
  base="$(us_runtipi_api_base)"
  us_info "Waiting for the Runtipi API at ${base} (timeout ${timeout}s)"
  while ((waited < timeout)); do
    if curl -fsS --max-time 5 -o /dev/null "${base}/health" 2>/dev/null; then
      us_ok "Runtipi API is responding"
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  us_error "Runtipi API did not become ready within ${timeout}s."
  us_error "Inspect: docker ps -a  /  docker logs runtipi"
  return 1
}

# ---------------------------------------------------------------------------
# App stores
# ---------------------------------------------------------------------------

us_runtipi_appstore_list() {
  us_runtipi_api GET "marketplace/all"
}

us_runtipi_appstore_exists() {
  local slug="$1" json
  json="$(us_runtipi_appstore_list 2>/dev/null)" || return 1
  printf '%s' "$json" | jq -e --arg s "$slug" '.appStores[]? | select(.slug == $s)' >/dev/null 2>&1
}

# us_runtipi_appstore_add <name> <url>
# Runtipi clones app stores with isomorphic-git over HTTP(S) and expects
# apps/ at the repository ROOT. A branch may be selected with the
# /tree/<branch> suffix (repos.helpers.ts getRepoBaseUrlAndBranch).
us_runtipi_appstore_add() {
  local name="$1" url="$2"

  if us_runtipi_appstore_exists "$name"; then
    us_ok "App store '${name}' already registered"
    return 0
  fi

  if [[ "$US_DRY_RUN" == "1" ]]; then
    us_info "DRY-RUN: would register app store ${name} -> ${url}"
    return 0
  fi

  us_info "Registering app store '${name}' -> ${url}"
  us_runtipi_api POST "marketplace/create" \
    "$(jq -nc --arg n "$name" --arg u "$url" '{name:$n, url:$u}')" >/dev/null ||
    us_die "Could not register app store '${name}'. Check that ${url} is reachable and has apps/ at its root."

  us_ok "Registered app store '${name}'"
}

us_runtipi_appstore_pull() {
  us_info "Refreshing app stores"
  us_runtipi_api POST "marketplace/pull" '{}' >/dev/null ||
    us_warn "App store refresh reported an error"
}

# ---------------------------------------------------------------------------
# Apps
# ---------------------------------------------------------------------------

# App identity is a URN: <appName>:<appStoreSlug>
us_runtipi_urn() { printf '%s:%s' "$1" "$2"; }

# _US_JQ_APP - jq prelude for reading apps/installed.
#
# Matching on one hardcoded path (`.installed[].app.urn`) is what made an
# installed, running AdGuard look like it had never appeared: a field that
# moves reads as "no such app", which is indistinguishable from "not installed
# yet" and so waits out the entire timeout. Runtipi has expressed app identity
# several ways across 4.x — a `urn` field, an `id` that is itself the URN
# string, or appName and appStoreSlug as separate columns — and the container
# has been both `.installed` and a bare array. So accept all of them and match
# if ANY candidate identity matches. Being permissive here costs nothing: the
# URN is a local lookup key, not a security boundary.
#
#   _apps    -> one record per installed app, container shape notwithstanding
#   _urns    -> every candidate URN for a record (a stream, possibly empty)
#   _names   -> every candidate bare app name for a record
#   _status  -> the record's status, or "" if it has none
_US_JQ_APP='
def _apps:
  (if type == "object" then (.installed // .apps // empty) else . end)
  | if type == "array" then .[] else empty end;
def _rec: if (type == "object" and has("app")) then .app else . end;
def _urns:
  _rec
  | ( (.urn // empty),
      (if (((.appName // "") | tostring) != "" and ((.appStoreSlug // "") | tostring) != "")
         then ((.appName | tostring) + ":" + (.appStoreSlug | tostring))
         else empty end),
      (if ((.id? | type) == "string") then .id else empty end) )
  | tostring;
def _names:
  _rec
  | ( (.appName // empty),
      (((.urn // .id // "") | tostring | split(":") | .[0]) // empty) )
  | tostring | select(. != "");
def _status: _rec | ((.status // "") | tostring);
'

# The three readers below are pure: payload in, answer out, no I/O. That is
# what makes them testable against captured API shapes in tests/test-lib.sh --
# the matching rule is the part that broke, so it is the part that gets tests.

# us_runtipi_app_present_in <json> <urn> - is this app in the payload?
us_runtipi_app_present_in() {
  printf '%s' "$1" |
    jq -e --arg u "$2" "${_US_JQ_APP}"'_apps | select(any(_urns; . == $u))' >/dev/null 2>&1
}

# us_runtipi_app_status_from <json> <urn> - its status, or "" if absent.
us_runtipi_app_status_from() {
  printf '%s' "$1" | jq -r --arg u "$2" \
    "${_US_JQ_APP}"'first(_apps | select(any(_urns; . == $u)) | _status) // empty' \
    2>/dev/null || true
}

# us_runtipi_app_urn_from <json> <appName> - the URN this app is recorded
# under, whatever store it came from. Empty when it is not installed.
us_runtipi_app_urn_from() {
  printf '%s' "$1" | jq -r --arg n "$2" \
    "${_US_JQ_APP}"'first(_apps | select(any(_names; . == $n)) | (first(_urns) // "")) // empty' \
    2>/dev/null || true
}

us_runtipi_app_installed() {
  local urn="$1" json
  json="$(us_runtipi_api GET "apps/installed" 2>/dev/null)" || return 1
  us_runtipi_app_present_in "$json" "$urn"
}

us_runtipi_app_status() {
  local urn="$1" json
  json="$(us_runtipi_api GET "apps/installed" 2>/dev/null)" || return 1
  us_runtipi_app_status_from "$json" "$urn"
}

# us_runtipi_app_urn_for_name <appName>
# The URN an app is actually installed under, whatever store it came from.
# Prints nothing when the app is not installed. Exists because the store slug
# is discovered, not fixed: "adguard:migrated" and "adguard:default" are the
# same app, and telling them apart matters before posting a second install.
us_runtipi_app_urn_for_name() {
  local name="$1" json
  json="$(us_runtipi_api GET "apps/installed" 2>/dev/null)" || return 1
  us_runtipi_app_urn_from "$json" "$name"
}

# us_runtipi_app_install <urn> <form-json>
# There is deliberately no `runtipi app install` subcommand upstream, so this
# posts to the same endpoint the web UI uses. The form body accepts
# exposedLocal + localSubdomain, which is how an app lands on
# <subdomain>.<LOCAL_DOMAIN>. (app-lifecycle.controller.ts / app-lifecycle.dto.ts)
us_runtipi_app_install() {
  local urn="$1" form="$2"

  # Callers record the URN in the manifest, so they need the one that turned
  # out to be real, not the one that was guessed. Always set, always exported.
  US_RUNTIPI_RESOLVED_URN="$urn"
  export US_RUNTIPI_RESOLVED_URN

  if us_runtipi_app_installed "$urn"; then
    us_ok "App '${urn}' already installed"
    return 0
  fi

  # Same app under a different store slug. Posting another install would ask
  # Runtipi to add an app it already has; adopt the URN it recorded instead.
  # The app being present is the fact that matters — which store it came from
  # is bookkeeping, and Runtipi's answer is the authoritative one.
  local recorded
  recorded="$(us_runtipi_app_urn_for_name "${urn%%:*}" 2>/dev/null || true)"
  if [[ -n "$recorded" && "$recorded" != "$urn" ]]; then
    us_warn "'${urn%%:*}' is installed as '${recorded}', not '${urn}'."
    us_warn "The app store slug discovered here differs from the one Runtipi recorded."
    us_warn "Adopting '${recorded}' (status: $(us_runtipi_app_status "$recorded" 2>/dev/null || printf 'unknown'))."
    US_RUNTIPI_RESOLVED_URN="$recorded"
    return 0
  fi

  if [[ "$US_DRY_RUN" == "1" ]]; then
    us_info "DRY-RUN: would install ${urn} with ${form}"
    return 0
  fi

  us_info "Installing app '${urn}' (image pulls may take several minutes)"
  us_runtipi_api POST "app-lifecycle/${urn}/install" "$form" >/dev/null ||
    return 1

  # The endpoint is asynchronous: it queues work and returns a requestId.
  us_runtipi_app_wait_status "$urn" running 900
}

# _us_runtipi_installed_report <apps-installed-json>
# One "<urn>  <status>" line per installed app, for diagnostics. Falls back to
# a raw excerpt when the filter yields nothing, which is the signal that the
# response shape itself has moved rather than that no apps are installed.
_us_runtipi_installed_report() {
  local json="$1" report
  report="$(printf '%s' "$json" |
    jq -r "${_US_JQ_APP}"'_apps | "    \(first(_urns) // "<no identity>")  \(_status)"' \
      2>/dev/null || true)"
  if [[ -n "$report" ]]; then
    printf '%s' "$report"
  else
    printf '    (no app records found; raw response begins: %s)' "${json:0:300}"
  fi
}

# _us_runtipi_app_count <apps-installed-json> - how many app records parsed.
# Zero with a healthy API means the response shape is unreadable; non-zero
# with no match means the identity is wrong. Different faults, different fix.
_us_runtipi_app_count() {
  local n
  n="$(printf '%s' "$1" | jq -r "${_US_JQ_APP}"'[_apps] | length' 2>/dev/null || printf '0')"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# _us_runtipi_wait_decision <urn> <wanted>
# What to do when a wait gives up: retry, continue, or abort. Answered by
# US_ON_APP_WAIT_TIMEOUT when set, otherwise by asking, otherwise abort.
# Unattended runs must never block on a prompt nobody is there to answer.
_us_runtipi_wait_decision() {
  local urn="$1" want="$2" reply=""

  case "${US_ON_APP_WAIT_TIMEOUT:-}" in
    retry | continue | abort)
      us_info "US_ON_APP_WAIT_TIMEOUT=${US_ON_APP_WAIT_TIMEOUT}"
      printf '%s' "$US_ON_APP_WAIT_TIMEOUT"
      return 0
      ;;
    "") ;;
    *) us_warn "Ignoring unknown US_ON_APP_WAIT_TIMEOUT='${US_ON_APP_WAIT_TIMEOUT}'." ;;
  esac

  if [[ ! -t 0 ]]; then
    us_warn "Not attached to a terminal, so this cannot be asked interactively."
    us_warn "Rerun with US_ON_APP_WAIT_TIMEOUT=retry|continue|abort to decide up front."
    printf 'abort'
    return 0
  fi

  us_warn "Choose how to proceed:"
  us_warn "  r  retry   - watch '${urn}' for '${want}' again"
  us_warn "  c  continue- accept the app as-is and run the remaining stages"
  us_warn "  a  abort   - stop here (default)"
  read -r -p "  [r/c/a] " reply || reply=""
  case "${reply,,}" in
    r | retry) printf 'retry' ;;
    c | continue) printf 'continue' ;;
    *) printf 'abort' ;;
  esac
}

# _us_runtipi_poll_status <urn> <wanted> <timeout>
# 0 = reached <wanted>, 1 = entered a failure state, 2 = gave up waiting.
#
# The "gave up" case is deliberately not folded into failure. An app whose URN
# never matches reports an empty status, which is neither the wanted state nor
# a failure state; the original loop fell through both and waited out the full
# timeout in silence before blaming an install that had in fact succeeded. So
# this reports every state change, and stops early once continuing to wait is
# provably pointless rather than merely slow.
_us_runtipi_poll_status() {
  local urn="$1" want="$2" timeout="$3" waited=0 interval=5
  local json status last_seen="" api_failures=0 count=0

  # Runtipi creates the app row immediately and only then pulls images, so an
  # app absent from the list minutes after the install was accepted is an
  # identity mismatch, not a slow download. Waiting out 900s cannot fix that.
  local absent_budget="${US_APP_ABSENT_BUDGET:-180}"
  ((absent_budget > timeout)) && absent_budget="$timeout"

  while ((waited < timeout)); do
    if json="$(us_runtipi_api GET "apps/installed" 2>/dev/null)"; then
      api_failures=0
      status="$(us_runtipi_app_status_from "$json" "$urn")"
      count="$(_us_runtipi_app_count "$json")"
    else
      json=""
      status=""
      count=0
      api_failures=$((api_failures + 1))
      if ((api_failures == 3)); then
        us_warn "Cannot read apps/installed (3 consecutive failures); still trying."
      fi
    fi

    if [[ "$status" != "$last_seen" ]]; then
      us_info "App '${urn}': ${status:-not listed yet}"
      last_seen="$status"
    fi

    case "$status" in
      "$want")
        us_ok "App '${urn}' is ${want}"
        return 0
        ;;
      missing | *_error)
        us_error "App '${urn}' entered state '${status}'."
        us_error "Inspect: docker logs runtipi  (and ${RUNTIPI_ROOT}/logs/error.log)"
        return 1
        ;;
    esac

    if [[ -z "$status" ]] && ((waited >= absent_budget)) && [[ -n "$json" ]]; then
      us_error "'${urn}' is not among the ${count} app(s) Runtipi reports, ${waited}s after"
      us_error "the install was accepted. That is an identity mismatch, not a slow install."
      us_error "$(_us_runtipi_installed_report "$json")"
      return 2
    fi

    sleep "$interval"
    waited=$((waited + interval))
    if ((waited % 60 == 0)); then
      us_info "Waiting for '${urn}' to be ${want}: ${waited}s/${timeout}s (now: ${status:-not listed})"
    fi
  done

  us_error "App '${urn}' did not reach '${want}' within ${timeout}s (last state: ${last_seen:-never listed})."
  if [[ -n "${json:-}" ]]; then
    us_error "$(_us_runtipi_installed_report "$json")"
  fi
  return 2
}

# us_runtipi_app_wait_status <urn> <wanted> <timeout>
# Wraps the poll with a way out. Giving up offers retry / continue / abort so a
# watcher that cannot see the app never becomes a wall the operator has to kill
# the installer to get past. US_APP_WAIT_TIMEOUT overrides the timeout,
# US_ON_APP_WAIT_TIMEOUT answers the prompt for unattended runs.
us_runtipi_app_wait_status() {
  local urn="$1" want="$2" timeout="${US_APP_WAIT_TIMEOUT:-${3:-600}}" rc

  while true; do
    rc=0
    _us_runtipi_poll_status "$urn" "$want" "$timeout" || rc=$?
    ((rc == 2)) || return "$rc"

    case "$(_us_runtipi_wait_decision "$urn" "$want")" in
      retry)
        us_info "Watching '${urn}' again for up to ${timeout}s."
        ;;
      continue)
        us_warn "Continuing without confirming '${urn}' is ${want}, as instructed."
        us_warn "Verify with: sudo ./doctor.sh --runtipi"
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  done
}

us_runtipi_app_start() { us_runtipi_api POST "app-lifecycle/${1}/start" '{}' >/dev/null; }
us_runtipi_app_stop() { us_runtipi_api POST "app-lifecycle/${1}/stop" '{}' >/dev/null; }

# ---------------------------------------------------------------------------
# Traefik file-provider notes
# ---------------------------------------------------------------------------
# us_runtipi_traefik_dynamic_dir() above points at the directory Runtipi's
# Traefik watches with a file provider (watch: true, assets/traefik/traefik.yml).
# Runtipi only ever writes dynamic.yml into it (app.service.ts), so an
# additional, differently-named file there is a supported extension point for
# routes Runtipi cannot express — nothing upstream rewrites or prunes it.
#
# u-server does not currently need one. An earlier revision used this to
# publish the dashboard at a second hostname; that was removed once the
# LOCAL_DOMAIN apex proved sufficient. scripts/30-runtipi-config.sh still
# cleans up the file it used to write. See git history for the helper if a
# genuine need for a custom route appears.
