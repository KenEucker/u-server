#!/usr/bin/env bash
# tools/validate-appstore.sh - Validate the app store before publishing it.
#
# Runtipi rejects a malformed app at install time, deep inside a container,
# with a message that is hard to trace back. Catching it here — and in CI —
# is much cheaper.
#
# Checks per app:
#   * config.json is valid JSON and has the required fields
#   * id matches its directory name (Runtipi resolves apps by directory)
#   * docker-compose.yml is valid YAML with x-runtipi.schema_version
#   * exactly one service is marked is_main, and it declares internal_port
#   * every image is pinned to an explicit tag (never :latest)
#   * supported_architectures is present and non-empty
#   * host ports declared in config.json do not collide across apps
#   * metadata/description.md exists
#
#   ./tools/validate-appstore.sh

set -Eeuo pipefail

US_ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
US_LIB_DIR="${US_ROOT_DIR}/lib"
# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"

us_init "validate-appstore"
us_require_cmds jq

APPSTORE_DIR="${US_ROOT_DIR}/appstore/apps"
[[ -d "$APPSTORE_DIR" ]] || us_die "No app store directory at ${APPSTORE_DIR}"

# yq is nice to have but not required; fall back to python3 for YAML parsing.
yaml_to_json() {
  local py
  if us_have yq; then
    yq -o=json '.' "$1"
    return
  fi
  for py in python3 python; do
    if us_have "$py" && "$py" -c 'import yaml' 2>/dev/null; then
      "$py" -c 'import sys,yaml,json; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$1"
      return
    fi
  done
  return 2
}

errors=0
warnings=0
declare -A used_ports=()

err() {
  us_status_fail "$1"
  ((errors++))
}
warn() {
  us_status_warn "$1"
  ((warnings++))
}

us_section "Validating app store"

shopt -s nullglob
app_dirs=("$APPSTORE_DIR"/*/)
((${#app_dirs[@]})) || us_die "No apps found in ${APPSTORE_DIR}"

for dir in "${app_dirs[@]}"; do
  app="$(basename "$dir")"
  printf '\n  %s\n' "$app"

  config="${dir}config.json"
  compose="${dir}docker-compose.yml"

  # --- config.json ---------------------------------------------------------
  if [[ ! -f "$config" ]]; then
    err "${app}: config.json is missing"
    continue
  fi
  if ! jq empty "$config" 2>/dev/null; then
    err "${app}: config.json is not valid JSON"
    continue
  fi

  id="$(jq -r '.id // empty' "$config")"
  [[ "$id" == "$app" ]] ||
    err "${app}: config.json id is '${id}' but the directory is '${app}' (they must match)"

  for field in name id available short_desc author source tipi_version version categories; do
    jq -e --arg f "$field" 'has($f)' "$config" >/dev/null 2>&1 ||
      err "${app}: config.json is missing required field '${field}'"
  done

  # A colon in the id would break URN parsing (<app>:<store>).
  [[ "$id" == *:* ]] && err "${app}: id must not contain a colon"

  arch_count="$(jq '.supported_architectures | length // 0' "$config" 2>/dev/null || echo 0)"
  ((arch_count > 0)) || err "${app}: supported_architectures is empty or missing"

  available="$(jq -r '.available' "$config")"

  # Host port collisions across apps in this store.
  port="$(jq -r '.port // empty' "$config")"
  if [[ -n "$port" ]]; then
    if [[ -n "${used_ports[$port]:-}" ]]; then
      err "${app}: port ${port} already used by '${used_ports[$port]}'"
    else
      used_ports[$port]="$app"
    fi
    if ((port < 1024 || port > 65535)); then
      err "${app}: port ${port} is outside the range Runtipi accepts (1024-65535)"
    fi
  fi

  # Secrets must never be literals in a tracked file.
  if jq -e '.form_fields[]? | select(.type != "random") | select(.env_variable | test("PASSWORD|SECRET|KEY|TOKEN"))' \
    "$config" >/dev/null 2>&1; then
    warn "${app}: a credential-looking form field is not type 'random'; confirm no secret is committed"
  fi

  # --- docker-compose.yml --------------------------------------------------
  if [[ ! -f "$compose" ]]; then
    if [[ "$available" == "false" ]]; then
      us_status_skip "${app}: no compose file (scaffold, available=false)"
    else
      err "${app}: docker-compose.yml is missing but available=true"
    fi
  else
    if json="$(yaml_to_json "$compose" 2>/dev/null)"; then
      schema="$(printf '%s' "$json" | jq -r '.["x-runtipi"].schema_version // empty')"
      if [[ -z "$schema" ]]; then
        err "${app}: docker-compose.yml has no top-level x-runtipi.schema_version"
      elif [[ "$schema" != "2" ]]; then
        warn "${app}: schema_version is ${schema}; 2 is current"
      fi

      main_count="$(printf '%s' "$json" |
        jq '[.services[]? | select(.["x-runtipi"].is_main == true)] | length')"
      case "$main_count" in
        1) : ;;
        0) err "${app}: no service is marked x-runtipi.is_main" ;;
        *) err "${app}: ${main_count} services are marked is_main (exactly one is allowed)" ;;
      esac

      if ((main_count == 1)); then
        iport="$(printf '%s' "$json" |
          jq -r '[.services[]? | select(.["x-runtipi"].is_main == true) | .["x-runtipi"].internal_port] | .[0] // empty')"
        [[ -n "$iport" ]] ||
          err "${app}: the is_main service does not declare internal_port (Traefik cannot route to it)"
      fi

      # Mutable tags make deployments irreproducible and break offline bundling.
      while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        if [[ "$image" != *:* ]] || [[ "$image" == *:latest ]]; then
          err "${app}: image '${image}' is unpinned; use an explicit immutable tag"
        fi
      done < <(printf '%s' "$json" | jq -r '.services[]?.image // empty')

      # Elevated permissions should be visible, not incidental.
      if printf '%s' "$json" | grep -q 'docker\.sock'; then
        warn "${app}: mounts the Docker socket (root-equivalent host access) — must be documented in metadata/description.md"
      fi
      if printf '%s' "$json" | jq -e '.services[]? | select(.privileged == true)' >/dev/null 2>&1; then
        warn "${app}: runs a privileged container — must be justified in metadata/description.md"
      fi
    else
      rc=$?
      if ((rc == 2)); then
        warn "${app}: neither yq nor python3 available; skipped YAML validation"
      else
        err "${app}: docker-compose.yml is not valid YAML"
      fi
    fi
  fi

  # --- metadata ------------------------------------------------------------
  [[ -f "${dir}metadata/description.md" ]] ||
    warn "${app}: metadata/description.md is missing"

  ((errors == 0)) && us_status_ok "${app}"
done

printf '\n'
if ((errors)); then
  us_error "${errors} error(s), ${warnings} warning(s). App store is NOT valid."
  exit 1
fi
us_ok "App store valid (${#app_dirs[@]} apps, ${warnings} warning(s))."
