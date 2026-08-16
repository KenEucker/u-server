#!/usr/bin/env bash
# lib/versions.sh - Version policy resolution and the installation manifest.
#
# The whole project distinguishes three things, and they must never be conflated:
#
#   desired policy   what server.env asks for       e.g. "stable" or "v4.10.1"
#   resolved version the exact tag chosen at run    e.g. "v4.10.1"
#   installed version what is actually on the node  e.g. "v4.10.1"
#
# "stable" is resolved ONCE, at first install, and then recorded. Rerunning
# install.sh reuses the recorded version — it does not silently upgrade a
# running node just because upstream published something newer. Upgrades go
# through ./update.sh, which compares recorded vs. available and acts only when
# told to.
#
# This module is intentionally free of any download or install side effects, so
# a future offline bundle builder can source it, resolve the exact same
# versions on an Internet-connected machine, and enumerate what to package.

[[ -n "${_US_VERSIONS_SOURCED:-}" ]] && return 0
_US_VERSIONS_SOURCED=1

# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"

# Upstream sources of truth. Centralised so an upstream move is a one-line fix.
#
# NOTE (verified 2026-08): the runtipi CLI binaries are published as assets on
# the runtipi/runtipi releases, NOT on runtipi/cli. The runtipi/cli repository
# carries the CLI *source* but its own releases lag well behind (v4.2.1 while
# runtipi/runtipi is at v4.10.1). Resolving against runtipi/cli would install a
# CLI several minor versions behind the platform. See docs/runtipi.md.
#
# Read by the stage scripts, doctor.sh and update.sh, all of which source this
# file. shellcheck analyses each file in isolation and cannot see that, hence
# the suppression.
# shellcheck disable=SC2034
US_RUNTIPI_REPO="runtipi/runtipi"

# ---------------------------------------------------------------------------
# GitHub API
# ---------------------------------------------------------------------------

# us_gh_api <path> - GET https://api.github.com/<path>.
# Honours GITHUB_TOKEN when present purely to dodge the 60/hour anonymous rate
# limit; the installer never requires credentials.
us_gh_api() {
  local path="$1"
  local url="https://api.github.com/${path#/}"
  local -a args=(-fsS --max-time 25 -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28')
  [[ -n "${GITHUB_TOKEN:-}" ]] && args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  us_retry 3 3 curl "${args[@]}" "$url"
}

# us_gh_latest_stable <owner/repo>
# Newest release that is neither a prerelease nor a draft.
#
# We deliberately do NOT use /releases/latest alone: that endpoint reflects the
# "latest" flag which upstream sets manually and has been observed pointing at
# unexpected releases. Instead we page /releases and take the first entry with
# prerelease=false && draft=false, which is the documented ordering (newest
# first). /releases/latest is used only as a fallback if that yields nothing.
us_gh_latest_stable() {
  local repo="$1" json tag

  if json="$(us_gh_api "repos/${repo}/releases?per_page=30" 2>/dev/null)"; then
    tag="$(printf '%s' "$json" |
      jq -r 'map(select(.prerelease == false and .draft == false))
             | .[0].tag_name // empty')"
    if [[ -n "$tag" && "$tag" != "null" ]]; then
      printf '%s' "$tag"
      return 0
    fi
  fi

  us_warn "Paged release listing yielded no stable release for ${repo}; trying /releases/latest"
  if json="$(us_gh_api "repos/${repo}/releases/latest" 2>/dev/null)"; then
    tag="$(printf '%s' "$json" | jq -r '.tag_name // empty')"
    if [[ -n "$tag" && "$tag" != "null" ]]; then
      printf '%s' "$tag"
      return 0
    fi
  fi

  us_error "Could not resolve a stable release for ${repo}."
  us_error "Check network access to api.github.com, or pin an exact version in server.env."
  return 1
}

# us_gh_asset_url <owner/repo> <tag> <asset-name>
# Resolves a release asset's download URL, failing loudly (not silently
# guessing a URL) if upstream renamed or dropped the asset.
us_gh_asset_url() {
  local repo="$1" tag="$2" asset="$3" json url
  json="$(us_gh_api "repos/${repo}/releases/tags/${tag}")" || return 1
  url="$(printf '%s' "$json" |
    jq -r --arg a "$asset" '.assets[]? | select(.name == $a) | .browser_download_url')"
  if [[ -z "$url" || "$url" == "null" ]]; then
    us_error "Release ${repo}@${tag} has no asset named '${asset}'."
    us_error "Assets actually present:"
    printf '%s' "$json" | jq -r '.assets[]?.name | "    - " + .' >&2 || true
    us_error "Upstream asset naming has probably changed; update lib/runtipi.sh."
    return 1
  fi
  printf '%s' "$url"
}

# ---------------------------------------------------------------------------
# Manifest: /var/lib/u-server/installed-manifest.json
# ---------------------------------------------------------------------------

us_manifest_init() {
  us_ensure_dir "$US_STATE_DIR" 0755
  if [[ ! -f "$US_MANIFEST_FILE" ]]; then
    [[ "$US_DRY_RUN" == "1" ]] && return 0
    printf '{"schema_version":1,"components":{}}\n' >"$US_MANIFEST_FILE"
    chmod 0644 "$US_MANIFEST_FILE"
    us_debug "Initialised manifest ${US_MANIFEST_FILE}"
  fi
}

# us_manifest_get <jq-path> - e.g. us_manifest_get '.components.runtipi.version'
us_manifest_get() {
  [[ -f "$US_MANIFEST_FILE" ]] || return 1
  local out
  out="$(jq -r "${1} // empty" "$US_MANIFEST_FILE" 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}

# us_manifest_set_component <name> <version> [extra-json]
# Records what is actually installed, with a timestamp.
us_manifest_set_component() {
  local name="$1" version="$2" extra="${3:-{\}}"
  [[ "$US_DRY_RUN" == "1" ]] && {
    us_info "DRY-RUN: manifest ${name}=${version}"
    return 0
  }
  us_manifest_init
  local tmp
  tmp="$(mktemp)"
  jq --arg n "$name" --arg v "$version" --arg t "$(us_timestamp)" \
    --argjson e "$extra" \
    '.components[$n] = ({version:$v, installed_at:$t} + $e)' \
    "$US_MANIFEST_FILE" >"$tmp" && mv "$tmp" "$US_MANIFEST_FILE"
  chmod 0644 "$US_MANIFEST_FILE"
  us_debug "Manifest: ${name} = ${version}"
}

# us_manifest_set_host - environment facts, refreshed on every run.
us_manifest_set_host() {
  [[ "$US_DRY_RUN" == "1" ]] && return 0
  us_manifest_init
  local tmp
  tmp="$(mktemp)"
  jq \
    --arg t "$(us_timestamp)" \
    --arg ubuntu "$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-unknown}")" \
    --arg codename "$(. /etc/os-release 2>/dev/null && printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-unknown}}")" \
    --arg arch "$(dpkg --print-architecture 2>/dev/null || uname -m)" \
    --arg domain "${LOCAL_DOMAIN:-}" \
    --arg lanip "${LAN_IP:-}" \
    '.installed_at = $t
     | .ubuntu = $ubuntu
     | .ubuntu_codename = $codename
     | .architecture = $arch
     | .local_domain = $domain
     | .lan_ip = $lanip' \
    "$US_MANIFEST_FILE" >"$tmp" && mv "$tmp" "$US_MANIFEST_FILE"
  chmod 0644 "$US_MANIFEST_FILE"
}

# ---------------------------------------------------------------------------
# Policy resolution
# ---------------------------------------------------------------------------

# us_version_resolve <component> <policy> <owner/repo>
# Prints the exact version to use for this run.
#
#   policy = exact tag  -> that tag, always (an explicit pin is an instruction)
#   policy = stable     -> recorded version if the component is already
#                          installed, otherwise the newest upstream stable
#
# The "reuse recorded" branch is what stops `stable` from meaning
# "upgrade everything on every rerun".
us_version_resolve() {
  local component="$1" policy="$2" repo="$3" recorded

  if [[ "$policy" != "stable" ]]; then
    printf '%s' "$policy"
    return 0
  fi

  if recorded="$(us_manifest_get ".components.${component}.version" 2>/dev/null)"; then
    us_info "${component}: policy=stable, reusing installed ${recorded} (use ./update.sh to upgrade)"
    printf '%s' "$recorded"
    return 0
  fi

  us_info "${component}: policy=stable, resolving newest upstream release..."
  local tag
  tag="$(us_gh_latest_stable "$repo")" || return 1
  us_ok "${component}: resolved stable -> ${tag}"
  printf '%s' "$tag"
}

# us_version_available <component> <owner/repo>
# Newest upstream stable, ignoring what is installed. Used by ./update.sh --check.
us_version_available() {
  local component="$1" repo="$2"
  us_gh_latest_stable "$repo"
}

# us_version_installed <component>
us_version_installed() {
  us_manifest_get ".components.${1}.version"
}

# ---------------------------------------------------------------------------
# Capability detection helpers
# ---------------------------------------------------------------------------
# Preferred over version arithmetic. "Does this binary accept this flag?" is
# stable across upstream refactors in a way that "is it newer than 4.10.1?" is not.

# us_cli_supports <binary> <token> [args...]
# True when <token> appears in the command's help output.
us_cli_supports() {
  local bin="$1" token="$2"
  shift 2
  local help
  help="$("$bin" "${@:---help}" 2>&1 || true)"
  [[ "$help" == *"$token"* ]]
}

# us_version_ge <a> <b> - numeric-aware >= comparison, leading "v" tolerated.
# Reserved for the rare case where a genuine version gate is unavoidable;
# keep such gates in adapter modules, never scattered in stage scripts.
us_version_ge() {
  local a="${1#v}" b="${2#v}"
  [[ "$a" == "$b" ]] && return 0
  local first
  first="$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)"
  [[ "$first" == "$b" ]]
}
