#!/usr/bin/env bash
# scripts/00-preflight.sh - Validate the host before anything is changed.
#
# This stage is read-only with respect to the platform: the only thing it
# installs is the small set of tools the later stages need (curl, jq, ...).
# Anything that would produce a broken server is a hard failure here, while
# conditions that merely need explaining are warnings.
#
# Runnable standalone:  sudo scripts/00-preflight.sh

US_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"
# shellcheck source=lib/config.sh
source "${US_LIB_DIR}/config.sh"

us_init "preflight"
us_require_root
us_config_load

# Ubuntu releases with a current Docker Engine apt suite AND supported by
# Runtipi (64-bit Linux, Ubuntu 22.04+). Verified against
# docs.docker.com/engine/install/ubuntu (2026-08).
US_SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")

# Prerequisites every later stage relies on. dnsutils gives us dig, which the
# DNS verification stages use.
US_PREREQ_PACKAGES=(ca-certificates curl jq tar gnupg openssl dnsutils iproute2)

warnings=0

us_section "Preflight"

# --- Operating system ------------------------------------------------------
[[ -r /etc/os-release ]] || us_die "/etc/os-release is missing; cannot identify this OS."
# shellcheck disable=SC1091
. /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
  us_die "This installer targets Ubuntu Server. Detected ID='${ID:-unknown}'."
fi

version_supported=0
for v in "${US_SUPPORTED_UBUNTU[@]}"; do
  [[ "${VERSION_ID:-}" == "$v" ]] && version_supported=1
done

if ((version_supported)); then
  us_ok "Ubuntu ${VERSION_ID} (${UBUNTU_CODENAME:-${VERSION_CODENAME:-?}})"
else
  us_warn "Ubuntu ${VERSION_ID:-unknown} is not one of the verified releases (${US_SUPPORTED_UBUNTU[*]})."
  us_warn "Installation will continue, but Docker may not publish an apt suite for this release."
  warnings=$((warnings + 1))
fi

# --- Architecture ----------------------------------------------------------
arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$arch" in
  amd64 | x86_64) us_ok "Architecture ${arch}" ;;
  arm64 | aarch64)
    us_warn "Architecture ${arch}: Runtipi publishes aarch64 builds, but u-server is verified on amd64 only."
    warnings=$((warnings + 1))
    ;;
  *) us_die "Unsupported architecture '${arch}'. amd64/x86_64 is required." ;;
esac

# --- Virtualisation --------------------------------------------------------
# Explicitly non-fatal. The target hardware (e.g. a Lenovo ThinkCentre M73)
# may have VT-x disabled in firmware, and it does not matter: Docker Engine on
# Linux uses namespaces and cgroups, not hardware virtualisation.
if [[ -e /dev/kvm ]]; then
  us_info "Hardware virtualisation (KVM) is available."
else
  us_info "KVM is unavailable."
  us_info "Docker Engine does not require KVM. Continuing."
fi

# --- Memory ----------------------------------------------------------------
mem_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
mem_mb=$((mem_kb / 1024))
if ((mem_mb >= 3800)); then
  us_ok "Memory ${mem_mb} MiB"
else
  us_warn "Memory ${mem_mb} MiB is below the 4 GB Runtipi recommends."
  us_warn "Project NOMAD (MySQL + Redis + admin) will be tight on this machine."
  warnings=$((warnings + 1))
fi

# --- Disk ------------------------------------------------------------------
# Checked against the filesystem that will actually hold the data.
check_root="${RUNTIPI_ROOT:-/opt/runtipi}"
while [[ ! -d "$check_root" && "$check_root" != "/" ]]; do
  check_root="$(dirname "$check_root")"
done
avail_mb="$(df -Pm "$check_root" | awk 'NR==2{print $4}')"
if ((avail_mb >= 10240)); then
  us_ok "Free space on $(df -P "$check_root" | awk 'NR==2{print $6}'): $((avail_mb / 1024)) GiB"
else
  us_warn "Only $((avail_mb / 1024)) GiB free at ${check_root}; 10 GiB is the practical minimum."
  us_warn "Project NOMAD content (maps, ZIM archives, AI models) needs substantially more."
  warnings=$((warnings + 1))
fi

# --- Prerequisite packages -------------------------------------------------
missing=()
for pkg_cmd in "curl:curl" "jq:jq" "tar:tar" "openssl:openssl" "dig:dnsutils" "ss:iproute2"; do
  cmd="${pkg_cmd%%:*}"
  us_have "$cmd" || missing+=("${pkg_cmd#*:}")
done

if ((${#missing[@]})); then
  us_info "Installing prerequisites: ${missing[*]}"
  us_run env DEBIAN_FRONTEND=noninteractive apt-get update
  us_run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${US_PREREQ_PACKAGES[@]}"
  us_require_cmds curl jq tar openssl
  us_ok "Prerequisites installed"
else
  us_ok "Prerequisites already present"
fi

# --- Host identity ---------------------------------------------------------
# Only acts when SERVER_HOSTNAME is explicitly set and actually differs. The
# shipped example leaves it blank precisely so a stock config never renames
# somebody's machine as a side effect of installing a platform.
#
# /etc/hosts is updated alongside hostnamectl: leaving the old name there
# produces "sudo: unable to resolve host" on every subsequent command.
if [[ -n "$SERVER_HOSTNAME" ]]; then
  current_hostname="$(hostname)"
  if [[ "$current_hostname" == "$SERVER_HOSTNAME" ]]; then
    us_ok "Hostname already ${SERVER_HOSTNAME}"
  else
    us_info "Setting hostname: ${current_hostname} -> ${SERVER_HOSTNAME}"
    us_run hostnamectl set-hostname "$SERVER_HOSTNAME"
    if [[ "$US_DRY_RUN" != "1" ]]; then
      # Replace the old name on the 127.0.1.1 line Ubuntu uses, or add one.
      if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
        sed -i -E "s|^(127\.0\.1\.1[[:space:]]+).*|\1${SERVER_HOSTNAME}|" /etc/hosts
      else
        printf '127.0.1.1\t%s\n' "$SERVER_HOSTNAME" >>/etc/hosts
      fi
      getent hosts "$SERVER_HOSTNAME" >/dev/null 2>&1 ||
        us_warn "${SERVER_HOSTNAME} does not resolve locally; check /etc/hosts."
    fi
    us_ok "Hostname set to ${SERVER_HOSTNAME}"
  fi
else
  us_debug "SERVER_HOSTNAME is blank; keeping $(hostname)"
fi

# --- Network ---------------------------------------------------------------
us_config_validate

if ip -4 addr show 2>/dev/null | grep -qw "$LAN_IP"; then
  us_ok "LAN_IP ${LAN_IP} is assigned to this host"
else
  us_error "LAN_IP ${LAN_IP} is not assigned to any interface on this host."
  us_error "Addresses found:"
  ip -4 -o addr show scope global 2>/dev/null | awk '{print "    " $2 " " $4}' >&2
  us_die "Fix LAN_IP in server.env, or configure the interface, then rerun."
fi

if [[ -n "$LAN_INTERFACE" ]]; then
  if ip link show "$LAN_INTERFACE" >/dev/null 2>&1; then
    us_ok "LAN_INTERFACE ${LAN_INTERFACE} exists"
  else
    us_warn "LAN_INTERFACE '${LAN_INTERFACE}' does not exist on this host."
    warnings=$((warnings + 1))
  fi
fi

# Every *.home.arpa name resolves to LAN_IP, so that address must not move.
#
# IMPORTANT LIMITATION: this detects that the address arrived via DHCP — the
# kernel flags it `dynamic` with a lease lifetime. It CANNOT detect a DHCP
# reservation on the router, because a reservation is still delivered by DHCP
# and is purely server-side state; no DHCP option tells the client "this is
# reserved for you". So a correctly-reserved address still looks dynamic here.
#
# A reservation is a perfectly good answer. Set LAN_IP_IS_RESERVED=true in
# server.env to say so and silence this.
if [[ -n "$LAN_INTERFACE" ]] &&
  ip -4 addr show dev "$LAN_INTERFACE" 2>/dev/null | grep -q 'dynamic'; then
  if us_config_is_true "$LAN_IP_IS_RESERVED"; then
    us_ok "${LAN_IP} is DHCP-assigned, declared reserved on the router (LAN_IP_IS_RESERVED=true)"
  else
    us_warn "${LAN_IP} was assigned by DHCP on ${LAN_INTERFACE}."
    us_warn "Every *.${LOCAL_DOMAIN} name resolves to it, so it must not change. Either:"
    us_warn "  - reserve it on your router, then set LAN_IP_IS_RESERVED=true in server.env"
    us_warn "  - or make it static:  sudo ./tools/set-static-ip.sh"
    us_warn "This host cannot see whether a reservation already exists, so if you have"
    us_warn "already reserved it, set LAN_IP_IS_RESERVED=true and this stops warning."
    warnings=$((warnings + 1))
  fi
fi

# --- Port conflicts --------------------------------------------------------
# 53 is handled separately by the DNS stage (systemd-resolved is expected).
for spec in "80:tcp:Traefik HTTP" "443:tcp:Traefik HTTPS" "8080:tcp:Traefik dashboard"; do
  port="${spec%%:*}"
  rest="${spec#*:}"
  proto="${rest%%:*}"
  what="${rest#*:}"
  holder="$(us_port_listener "$port" "$proto" || true)"
  if [[ -n "$holder" ]]; then
    # Runtipi's own proxy holding these on a rerun is expected, not a conflict.
    if [[ "$holder" == *docker* || "$holder" == *traefik* ]]; then
      us_ok "Port ${port}/${proto} held by Docker (existing install)"
    else
      us_error "Port ${port}/${proto} is in use by: ${holder}"
      us_error "  ${what} needs this port. Stop the conflicting service and rerun."
      us_die "Port conflict on ${port}/${proto}."
    fi
  else
    us_ok "Port ${port}/${proto} free"
  fi
done

# Port 53: report the situation; the DNS stage resolves it.
dns_holder="$(us_port_listener 53 udp || true)"
if [[ -n "$dns_holder" ]]; then
  if [[ "$dns_holder" == *systemd-resolve* ]]; then
    if us_config_is_true "$DISABLE_RESOLVED_STUB"; then
      us_info "Port 53 held by systemd-resolved; the DNS stage will free it (DISABLE_RESOLVED_STUB=true)."
    else
      us_error "Port 53 is held by systemd-resolved but DISABLE_RESOLVED_STUB=false."
      us_die "AdGuard cannot bind port 53. Set DISABLE_RESOLVED_STUB=true or free the port yourself."
    fi
  elif [[ "$dns_holder" == *docker* ]]; then
    us_ok "Port 53/udp held by Docker (existing AdGuard install)"
  else
    us_warn "Port 53/udp is held by: ${dns_holder}"
    us_warn "AdGuard will fail to start unless this is stopped."
    warnings=$((warnings + 1))
  fi
else
  us_ok "Port 53/udp free"
fi

# --- Docker state ----------------------------------------------------------
# shellcheck source=lib/docker.sh
source "${US_LIB_DIR}/docker.sh"

if desktop_signal="$(us_docker_desktop_signal)"; then
  us_error "Docker Desktop detected: ${desktop_signal}."
  us_error "u-server requires Docker Engine directly on the host: Desktop runs its"
  us_error "engine in a VM behind its own socket, which Runtipi's stack cannot use."
  us_error "Remove it, then rerun:"
  us_error "  sudo apt-get remove docker-desktop     # or the Desktop uninstaller"
  us_error "  docker context use default"
  us_die "Docker Desktop detected."
elif us_docker_desktop_stale_context; then
  us_warn "A 'desktop-linux' docker context is defined, but Docker Desktop is not installed."
  us_warn "Left over from an uninstall. Harmless now, but it breaks every stage if"
  us_warn "anything switches to it. Remove it:  docker context rm desktop-linux"
  warnings=$((warnings + 1))
fi

if us_docker_present; then
  us_ok "Docker present: $(us_docker_version || echo unknown)"
else
  us_info "Docker is not installed; the Docker stage will install it."
fi

# --- Summary ---------------------------------------------------------------
if ((warnings)); then
  us_warn "Preflight completed with ${warnings} warning(s)."
else
  us_ok "Preflight passed with no warnings."
fi
