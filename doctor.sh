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
# shellcheck source=lib/tls.sh
source "${US_LIB_DIR}/tls.sh"

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

  if us_have_internet; then
    printf '\n  Upstream stable releases:\n'
    printf '    runtipi:       %s\n' "$(us_gh_latest_stable "$US_RUNTIPI_REPO" 2>/dev/null || echo 'unavailable')"
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
    for n in "$LOCAL_DOMAIN" "$DNS_DOMAIN" "doctor-$(date +%s).${LOCAL_DOMAIN}"; do
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
if want tls; then
  section "TLS"
  tls_dir="$(us_runtipi_traefik_tls_dir)"
  marker="$(us_runtipi_tls_marker_file "$LOCAL_DOMAIN")"

  printf '  ENABLE_LOCAL_HTTPS=%s\n' "$ENABLE_LOCAL_HTTPS"
  printf '\n  Every route redirects to HTTPS regardless of this setting — that is\n'
  printf '  Runtipi routing, not a choice made here. The setting only decides\n'
  printf '  whether the certificate is one your devices can be told to trust.\n'

  printf '\n  Certificate slot (%s):\n' "$tls_dir"
  for f in cert.pem key.pem; do
    if [[ -f "${tls_dir}/${f}" ]]; then
      printf '    %-10s present  (%s)\n' "$f" "$(stat -c '%a %U' "${tls_dir}/${f}" 2>/dev/null || echo '?')"
    else
      printf '    %-10s MISSING\n' "$f"
    fi
  done
  # Without this file Runtipi rewrites cert.pem with a self-signed certificate
  # on its next restart, and the only symptom is that the warnings return.
  if [[ -f "$marker" ]]; then
    printf '    %-10s present  (stops Runtipi regenerating over it)\n' "${marker##*/}"
  else
    printf '    %-10s MISSING  — Runtipi will overwrite cert.pem on next restart\n' "${marker##*/}"
  fi

  printf '\n  Local CA (%s):\n' "$US_TLS_CA_CRT"
  if [[ -f "$US_TLS_CA_CRT" ]]; then
    printf '    subject     %s\n' "$(openssl x509 -noout -subject -in "$US_TLS_CA_CRT" 2>/dev/null | cut -d= -f2-)"
    printf '    expires in  %s day(s)\n' "$(us_tls_days_remaining "$US_TLS_CA_CRT" 2>/dev/null || echo '?')"
    printf '    sha256      %s\n' "$(us_tls_fingerprint "$US_TLS_CA_CRT" 2>/dev/null || echo '?')"
    if [[ -f "$US_TLS_HOST_ANCHOR" ]]; then
      printf '    host trust  installed at %s\n' "$US_TLS_HOST_ANCHOR"
    else
      printf '    host trust  NOT installed (curl from this host needs -k)\n'
    fi
  else
    printf '    (none — ENABLE_LOCAL_HTTPS has never been turned on)\n'
  fi

  printf '\n  Server certificate (%s):\n' "$US_TLS_LEAF_CRT"
  if [[ -f "$US_TLS_LEAF_CRT" ]]; then
    printf '    names       %s\n' "$(us_tls_cert_san "$US_TLS_LEAF_CRT" 2>/dev/null || echo '?')"
    printf '    wanted      %s\n' "$(us_tls_desired_san "$LOCAL_DOMAIN" "$LAN_IP")"
    printf '    expires in  %s day(s)  (reissued below %s)\n' \
      "$(us_tls_days_remaining "$US_TLS_LEAF_CRT" 2>/dev/null || echo '?')" \
      "$US_TLS_RENEW_BEFORE_DAYS"
    if us_tls_signed_by "$US_TLS_LEAF_CRT" "$US_TLS_CA_CRT"; then
      printf '    chain       verifies against the local CA\n'
    else
      printf '    chain       DOES NOT verify against %s\n' "$US_TLS_CA_CRT"
    fi
  else
    printf '    (none)\n'
  fi

  # What a browser gets, which is the only claim that finally matters.
  printf '\n  Served on %s:443 (SNI %s):\n' "$LAN_IP" "$LOCAL_DOMAIN"
  served="$(us_tls_served_issuer "$LAN_IP" "$LOCAL_DOMAIN" 2>/dev/null || true)"
  printf '    issuer      %s\n' "${served:-<no TLS response>}"
  if us_tls_https_trusted "$LAN_IP" "$LOCAL_DOMAIN"; then
    printf '    trusted     yes, against the trust store on this host\n'
  else
    printf '    trusted     no — a client without the CA would warn\n'
  fi

  printf '\n  Renewal timer:\n'
  if us_have systemctl; then
    systemctl list-timers "${US_TLS_RENEW_UNIT}.timer" --all --no-pager 2>/dev/null |
      sed -n '1,3p' | sed 's/^/    /' || true
    state="$(systemctl is-failed "${US_TLS_RENEW_UNIT}.service" 2>/dev/null || true)"
    [[ "$state" == "failed" ]] &&
      printf '    LAST RUN FAILED: journalctl -u %s.service\n' "$US_TLS_RENEW_UNIT"
  else
    printf '    systemd not available; renewal must be run by hand.\n'
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
