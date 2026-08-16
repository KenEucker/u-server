#!/usr/bin/env bash
# tools/list-required-images.sh - Enumerate every container image this
# platform needs.
#
# This exists now, before any offline work, because it is the seam the future
# air-gapped bundler will build on: given this list, `docker save` produces the
# image payload. Keeping it accurate today means the bundler is a new consumer
# of existing logic rather than a rewrite.
#
#   ./tools/list-required-images.sh              plain list
#   ./tools/list-required-images.sh --json       machine-readable, with sources
#   ./tools/list-required-images.sh --digests    resolve to immutable digests
#                                                (requires docker + network)

set -Eeuo pipefail

US_ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
US_LIB_DIR="${US_ROOT_DIR}/lib"
# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"
# shellcheck source=lib/config.sh
source "${US_LIB_DIR}/config.sh"

us_init "list-images"
US_LOG_LEVEL=warn # keep stdout clean for piping

format=plain
case "${1:-}" in
  --json) format=json ;;
  --digests) format=digests ;;
  --help | -h)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

us_config_load 2>/dev/null || true

declare -a rows=()
add() { rows+=("${1}|${2}"); } # image|source

# ---------------------------------------------------------------------------
# Runtipi core
# ---------------------------------------------------------------------------
# Pinned in Runtipi's own docker-compose.prod.yml. Read from the installed
# instance when present so the list reflects reality rather than a guess.
runtipi_compose="$(us_runtipi_data_dir 2>/dev/null)/docker-compose.yml"
if [[ -f "$runtipi_compose" ]] && us_have docker; then
  while IFS= read -r img; do
    [[ -n "$img" ]] && add "$img" "runtipi-core"
  done < <(docker compose -f "$runtipi_compose" config --images 2>/dev/null || true)
else
  # Fallback: the images Runtipi's release compose is known to use. Versions
  # move with Runtipi releases, so the installed-instance path above is
  # authoritative whenever it is available.
  add "traefik:v3.6.12" "runtipi-core (fallback)"
  add "postgres:14" "runtipi-core (fallback)"
  add "rabbitmq:4-alpine" "runtipi-core (fallback)"
  add "ghcr.io/runtipi/runtipi:latest" "runtipi-core (fallback, tag set by CLI)"
fi

# ---------------------------------------------------------------------------
# App store definitions
# ---------------------------------------------------------------------------
extract_images() {
  # Deliberately simple: matches `image: value` at any indentation. The app
  # definitions in this repo are plain YAML with no anchors or templating.
  grep -hoE '^[[:space:]]*image:[[:space:]]*[^[:space:]#]+' "$1" 2>/dev/null |
    sed -E 's/^[[:space:]]*image:[[:space:]]*//'
}

for dir in "${US_ROOT_DIR}"/appstore/apps/*/; do
  app="$(basename "$dir")"
  compose="${dir}docker-compose.yml"
  [[ -f "$compose" ]] || continue
  available="$(jq -r '.available // true' "${dir}config.json" 2>/dev/null || echo true)"
  [[ "$available" == "true" ]] || continue
  while IFS= read -r img; do
    [[ -n "$img" ]] && add "$img" "app:${app}"
  done < <(extract_images "$compose")
done

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
case "$format" in
  plain)
    printf '%s\n' "${rows[@]}" | cut -d'|' -f1 | sort -u
    ;;
  json)
    printf '%s\n' "${rows[@]}" |
      jq -R -s 'split("\n") | map(select(length>0) | split("|") | {image: .[0], source: .[1]})
                | group_by(.image)
                | map({image: .[0].image, sources: map(.source) | unique})'
    ;;
  digests)
    us_have docker || us_die "--digests requires docker"
    printf '%s\n' "${rows[@]}" | cut -d'|' -f1 | sort -u | while IFS= read -r img; do
      # RepoDigests give the immutable content address a bundle should record.
      if digest="$(docker buildx imagetools inspect "$img" --format '{{.Manifest.Digest}}' 2>/dev/null)"; then
        printf '%s@%s\n' "${img%%:*}" "$digest"
      else
        printf '%s\t(digest unavailable — not pulled and registry unreachable)\n' "$img" >&2
        printf '%s\n' "$img"
      fi
    done
    ;;
esac
