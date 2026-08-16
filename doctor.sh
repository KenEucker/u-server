#!/usr/bin/env bash
# doctor.sh - Deep diagnostics.
#
# status.sh answers "is it healthy?". doctor.sh answers "why isn't it?".
# Read-only: it diagnoses and suggests, it never changes anything.
#
#   sudo ./doctor.sh            full report
#   sudo ./doctor.sh --versions only the version section

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
# shellcheck source=lib/adguard.sh
source "${US_LIB_DIR}/adguard.sh"
# shellcheck source=lib/nomad.sh
source "${US_LIB_DIR}/nomad.sh"

us_init "doctor"
us_config_load

only="${1:-}"
section() { printf '\n=== %s ===\n' "$1"; }
want() { [[ -z "$only" || "$only" == "--$1" ]]; }

printf 'u-server doctor  (%s)\n' "$(us_timestamp)"

# ---------------------------------------------------------------------------
if want host; then
  section "Host"
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  printf '  OS:            %s %s (%s)\n' "${NAME:-?}" "${VERSION_ID:-?}" "${UBUNTU_CODENAME:-?}"
  printf '  Kernel:        %s\n' "$(uname -r)"
  printf '  Architecture:  %s\n' "$(dpkg --print-architecture 2>/dev/null || uname -m)"
  printf '  Hostname:      %s\n' "$(hostname)"
  printf '  Uptime:        %s\n' "$(uptime -p 2>/dev/null || echo '?')"
  printf '  Memory:        %s\n' "$(free -h | awk 'NR==2{print $3 " used / " $2 " total"}')"
  printf '  KVM:           %s\n' "$([[ -e /dev/kvm ]] && echo 'available' || echo 'unavailable (not required)')"
  printf '  Load:          %s\n' "$(awk '{print $1", "$2", "$3}' /proc/loadavg)"
fi

# ---------------------------------------------------------------------------
if want versions; then
  section "Versions (policy / installed / available upstream)"
  if [[ -f "$US_MANIFEST_FILE" ]]; then
    printf '  manifest: %s\n\n' "$US_MANIFEST_FILE"
    jq -r '.components | to_entries[] | "  \(.key): \(.value.version) (installed \(.value.installed_at // "?"))"' \
      "$US_MANIFEST_FILE" 2>/dev/null || printf '  (unreadable)\n'
  else
    printf '  No manifest at %s — has install.sh run?\n' "$US_MANIFEST_FILE"
  fi

  printf '\n  Policies from configuration:\n'
  printf '    RUNTIPI_VERSION=%s\n' "$RUNTIPI_VERSION"
  printf '    NOMAD_VERSION=%s\n' "$NOMAD_VERSION"

  if us_have_internet; then
    printf '\n  Upstream stable releases:\n'
    printf '    runtipi:       %s\n' "$(us_gh_latest_stable "$US_RUNTIPI_REPO" 2>/dev/null || echo 'unavailable')"
    printf '    project-nomad: %s\n' "$(us_gh_latest_stable "$US_NOMAD_REPO" 2>/dev/null || echo 'unavailable')"
    printf '  (./update.sh --check compares these against what is installed)\n'
  else
    printf '\n  No Internet access; skipping upstream release lookup.\n'
    printf '  This is expected on an offline node and is not a fault.\n'
  fi
fi

# ---------------------------------------------------------------------------
if want ports; then
  section "Port bindings"
  for spec in "53 udp DNS" "53 tcp DNS" "80 tcp Traefik-HTTP" "443 tcp Traefik-HTTPS" "8080 tcp Traefik-dashboard"; do
    read -r port proto label <<<"$spec"
    holder="$(us_port_listener "$port" "$proto" || true)"
    if [[ -n "$holder" ]]; then
      printf '  %-5s/%-3s %-18s %s\n' "$port" "$proto" "$label" "$holder"
    else
      printf '  %-5s/%-3s %-18s (free)\n' "$port" "$proto" "$label"
    fi
  done
fi

# ---------------------------------------------------------------------------
if want dns; then
  section "DNS resolution path"
  printf '  /etc/resolv.conf -> %s\n' "$(readlink -f /etc/resolv.conf 2>/dev/null || echo '(not a symlink)')"
  printf '  nameservers in use:\n'
  grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | sed 's/^/    /' || printf '    (none)\n'

  if us_have resolvectl; then
    printf '\n  systemd-resolved:\n'
    resolvectl status 2>/dev/null | sed -n '1,12p' | sed 's/^/    /' || true
    printf '    DNSStubListener drop-ins:\n'
    ls /etc/systemd/resolved.conf.d/ 2>/dev/null | sed 's/^/      /' || printf '      (none)\n'
  fi

  if us_config_is_true "$INSTALL_ADGUARD" && us_adguard_reachable; then
    printf '\n  AdGuard rewrites:\n'
    us_adguard_rewrite_list 2>/dev/null |
      jq -r '.[]? | "    \(.domain) -> \(.answer)"' || printf '    (none)\n'

    printf '\n  Resolution tests (querying %s directly):\n' "$LAN_IP"
    for n in "$LOCAL_DOMAIN" "$SERVER_DOMAIN" "$NOMAD_DOMAIN" "doctor-$(date +%s).${LOCAL_DOMAIN}"; do
      got="$(dig +short +timeout=3 "@${LAN_IP}" "$n" A 2>/dev/null | tail -n1)"
      printf '    %-40s %s\n' "$n" "${got:-<no answer>}"
    done

    printf '\n  Upstream (Internet) resolution test:\n'
    got="$(dig +short +timeout=5 "@${LAN_IP}" example.com A 2>/dev/null | tail -n1)"
    if [[ -n "$got" ]]; then
      printf '    example.com -> %s (upstream forwarding works)\n' "$got"
    else
      printf '    example.com -> no answer\n'
      printf '    Expected when the WAN is down. Local %s resolution is unaffected.\n' "$LOCAL_DOMAIN"
    fi
  fi
fi

# ---------------------------------------------------------------------------
if want docker; then
  section "Docker networks"
  docker network ls --format '  {{.Name}}\t{{.Driver}}\t{{.Scope}}' 2>/dev/null || printf '  (unavailable)\n'

  printf '\n  Isolation check:\n'
  if us_docker_network_exists "$(us_nomad_network_name)"; then
    printf '    %s exists (NOMAD child services)\n' "$(us_nomad_network_name)"
    members="$(docker network inspect "$(us_nomad_network_name)" \
      -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null)"
    printf '      members: %s\n' "${members:-<none>}"
  else
    printf '    %s missing — NOMAD cannot attach child services\n' "$(us_nomad_network_name)"
  fi

  section "Containers"
  docker ps -a --format '  {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null |
    sort || printf '  (unavailable)\n'

  section "Disk usage"
  df -Ph / "${RUNTIPI_ROOT:-/opt/runtipi}" 2>/dev/null | sed 's/^/  /' | sort -u
  printf '\n  Docker reclaimable:\n'
  docker system df 2>/dev/null | sed 's/^/    /' || printf '    (unavailable)\n'
fi

# ---------------------------------------------------------------------------
if want traefik; then
  section "Traefik routing"
  # The API is enabled with insecure: true on :8080 (assets/traefik/traefik.yml).
  if routers="$(curl -fsS --max-time 8 "http://127.0.0.1:8080/api/http/routers" 2>/dev/null)"; then
    printf '  %-45s %-10s %s\n' "RULE" "STATUS" "SERVICE"
    printf '%s' "$routers" | jq -r '.[] | "  \(.rule[0:43])\t\(.status)\t\(.service)"' |
      column -t -s$'\t' 2>/dev/null || printf '%s' "$routers" | jq -r '.[] | "  \(.rule) \(.status) \(.service)"'

    printf '\n  Routers in error:\n'
    errs="$(printf '%s' "$routers" | jq -r '.[] | select(.status != "enabled") | "    \(.name): \(.error // "unknown")"')"
    printf '%s\n' "${errs:-    (none)}"
  else
    printf '  Traefik API not reachable on 127.0.0.1:8080.\n'
    printf '  Check: docker ps | grep reverse-proxy\n'
  fi
fi

# ---------------------------------------------------------------------------
if want runtipi; then
  section "Runtipi"
  printf '  Root:        %s\n' "$(us_runtipi_root)"
  printf '  Data dir:    %s\n' "$(us_runtipi_data_dir)"
  printf '  Env file:    %s\n' "$(us_runtipi_env_file)"
  printf '  CLI version: %s\n' "$(us_runtipi_installed_version 2>/dev/null || echo 'not installed')"
  printf '  LOCAL_DOMAIN: %s (configured: %s)\n' \
    "$(us_runtipi_env_get LOCAL_DOMAIN 2>/dev/null || echo '?')" "$LOCAL_DOMAIN"

  printf '\n  Traefik dynamic files managed here:\n'
  ls -1 "$(us_runtipi_traefik_dynamic_dir)" 2>/dev/null | sed 's/^/    /' || printf '    (none)\n'

  if us_runtipi_api GET "apps/installed" >/dev/null 2>&1; then
    printf '\n  Installed apps:\n'
    us_runtipi_api GET "apps/installed" 2>/dev/null |
      jq -r '.installed[]? | "    \(.app.urn)  \(.app.status)"' || true
    printf '\n  App stores:\n'
    us_runtipi_appstore_list 2>/dev/null |
      jq -r '.appStores[]? | "    \(.slug)  \(.url)  enabled=\(.enabled)"' || true
  else
    printf '\n  Runtipi API not reachable — cannot list apps.\n'
  fi
fi

# ---------------------------------------------------------------------------
if want nomad && us_config_is_true "$INSTALL_PROJECT_NOMAD"; then
  section "Project NOMAD"
  us_nomad_verify || true
  printf '\n  Upstream contract:\n'
  us_nomad_check_network_contract || true
  printf '\n  Child services:\n'
  children="$(us_nomad_child_services)"
  printf '%s\n' "${children:-    (none yet)}" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
if want drift; then
  section "Configuration drift"
  if [[ -f "$US_INSTALLED_CONFIG" && -f "${US_ROOT_DIR}/server.env" ]]; then
    # Compare effective values, not file text: comments and ordering differ
    # harmlessly between the repo copy and the installed copy.
    drift=0
    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      installed="$(awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$US_INSTALLED_CONFIG" | tr -d "'\"")"
      current="${!key:-}"
      if [[ "$installed" != "$current" ]]; then
        printf '  %-24s installed=%-24s current=%s\n' "$key" "${installed:-<unset>}" "${current:-<unset>}"
        drift=1
      fi
    done < <(grep -oE '^[A-Z_]+' "$US_INSTALLED_CONFIG" | sort -u)
    ((drift)) || printf '  No drift: server.env matches the installed configuration.\n'
    ((drift)) && printf '\n  Run: sudo ./install.sh   to converge.\n'
  else
    printf '  Nothing to compare (missing %s or server.env).\n' "$US_INSTALLED_CONFIG"
  fi
fi

# ---------------------------------------------------------------------------
if want logs; then
  section "Recent errors"
  if [[ -d "$US_LOG_DIR" ]]; then
    grep -h '\[ERROR\]' "$US_LOG_DIR"/*.log 2>/dev/null | tail -n 15 | sed 's/^/  /' ||
      printf '  (none)\n'
  else
    printf '  No log directory at %s\n' "$US_LOG_DIR"
  fi
fi

printf '\n'
