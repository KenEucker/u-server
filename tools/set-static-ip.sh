#!/usr/bin/env bash
# tools/set-static-ip.sh - Give this host a static IPv4 address via netplan.
#
# Every *.home.arpa name resolves to one address, so that address must not
# move. There are two valid ways to guarantee that:
#
#   1. A DHCP reservation on your router.  Simpler, survives reinstalls, and
#      keeps all addressing in one place. Recommended, especially over WiFi.
#   2. A static address on the host.       What this script configures.
#
# Either is fine. Pick one — doing both (a reservation for a different address
# than the host statically claims) causes intermittent, confusing conflicts.
#
#   sudo ./tools/set-static-ip.sh                  interactive, uses current values
#   sudo ./tools/set-static-ip.sh --address 192.168.86.23/24 --gateway 192.168.86.1
#   sudo ./tools/set-static-ip.sh --dry-run        show the file, change nothing
#   sudo ./tools/set-static-ip.sh --revert         remove this script's config
#
# SAFETY
# ------
# Applying a bad network config over SSH locks you out. This script:
#   * writes an ADDITIVE override file, never redefining your existing
#     interface config (critical on WiFi, where redefining the interface
#     without its access-points block drops the association entirely)
#   * validates with `netplan generate` before applying anything
#   * re-reads the MERGED config and refuses if WiFi credentials vanished
#   * applies with `netplan try`, which auto-reverts after 120s unless you
#     confirm — so a mistake costs you two minutes, not a site visit

set -Eeuo pipefail

US_ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
US_LIB_DIR="${US_ROOT_DIR}/lib"
# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"
# shellcheck source=lib/config.sh
source "${US_LIB_DIR}/config.sh"

us_init "set-static-ip"

NETPLAN_FILE="/etc/netplan/90-${US_PROJECT_NAME}-static.yaml"

iface="" address="" gateway="" dns="" assume_yes=0 revert=0 timeout=120

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while (($#)); do
  case "$1" in
    --interface) iface="${2:?}"; shift 2 ;;
    --address) address="${2:?}"; shift 2 ;;
    --gateway) gateway="${2:?}"; shift 2 ;;
    --dns) dns="${2:?}"; shift 2 ;;
    --timeout) timeout="${2:?}"; shift 2 ;;
    --yes | -y) assume_yes=1; shift ;;
    --revert) revert=1; shift ;;
    --dry-run) US_DRY_RUN=1; export US_DRY_RUN; shift ;;
    -h | --help) usage ;;
    *) us_die "Unknown option: $1 (try --help)" ;;
  esac
done

[[ "$US_DRY_RUN" == "1" ]] || us_require_root
us_require_cmds ip
us_have netplan || us_die "netplan is not installed. This host does not use netplan; configure its network with whatever it does use."

us_config_load 2>/dev/null || true

# ---------------------------------------------------------------------------
# Revert
# ---------------------------------------------------------------------------
if ((revert)); then
  us_section "Reverting"
  if [[ ! -f "$NETPLAN_FILE" ]]; then
    us_ok "Nothing to revert; ${NETPLAN_FILE} does not exist."
    exit 0
  fi
  us_info "Removing ${NETPLAN_FILE}"
  us_run rm -f -- "$NETPLAN_FILE"
  us_run netplan generate
  us_info "Applying (the interface returns to whatever your other netplan files say)"
  us_run netplan apply
  us_ok "Reverted. Check with: ip -4 addr show"
  exit 0
fi

# ---------------------------------------------------------------------------
# Discover the current state
# ---------------------------------------------------------------------------
us_section "Current network state"

[[ -n "$iface" ]] || iface="${LAN_INTERFACE:-$(us_default_interface || true)}"
[[ -n "$iface" ]] || us_die "Could not determine an interface. Pass --interface."
ip link show "$iface" >/dev/null 2>&1 || us_die "Interface '${iface}' does not exist."

current_cidr="$(ip -4 -o addr show dev "$iface" 2>/dev/null |
  awk '{print $4; exit}')"
current_gw="$(ip -4 route show default dev "$iface" 2>/dev/null |
  awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
is_dhcp=0
ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'dynamic' && is_dhcp=1

# WiFi detection: the kernel exposes a `wireless` node for 802.11 devices.
is_wifi=0
[[ -d "/sys/class/net/${iface}/wireless" ]] && is_wifi=1

printf '  interface:  %s%s\n' "$iface" "$( ((is_wifi)) && printf ' (WiFi)')" >&2
printf '  address:    %s%s\n' "${current_cidr:-<none>}" "$( ((is_dhcp)) && printf ' (DHCP-assigned)')" >&2
printf '  gateway:    %s\n' "${current_gw:-<none>}" >&2

if ((!is_dhcp)) && [[ -n "$current_cidr" ]]; then
  us_ok "${iface} already has a statically-assigned address."
  us_info "Nothing to do unless you want to change it."
fi

# ---------------------------------------------------------------------------
# Work out what netplan currently knows
# ---------------------------------------------------------------------------
# `netplan get` returns the MERGED view of /{etc,lib,run}/netplan/*.yaml, which
# is what actually takes effect.
netplan_view=""
if netplan_view="$(netplan get all 2>/dev/null)" && [[ -n "$netplan_view" ]]; then
  us_debug "Read merged netplan configuration"
else
  netplan_view=""
  us_warn "Could not read the merged netplan config ('netplan get' unavailable or empty)."
fi

# Which top-level section does this interface belong under?
section="ethernets"
((is_wifi)) && section="wifis"

# Renderer must match whatever already manages the link, or netplan will hand
# the interface to a second manager and the two will fight over it.
renderer=""
if [[ -n "$netplan_view" ]]; then
  renderer="$(printf '%s' "$netplan_view" |
    awk '/^[[:space:]]*renderer:/ {print $2; exit}')"
fi
if [[ -z "$renderer" ]]; then
  if us_have nmcli && nmcli -t -f DEVICE,STATE device status 2>/dev/null |
    grep -q "^${iface}:connected"; then
    renderer="NetworkManager"
  else
    renderer="networkd"
  fi
fi
printf '  renderer:   %s\n' "$renderer" >&2

# The WiFi trap: if netplan does not already define this interface, its
# credentials live somewhere netplan cannot see (typically NetworkManager
# keyfiles). Adding a `wifis:` block would then be the ONLY definition, it
# would have no access-points, and the link would stop associating.
if ((is_wifi)) && ! printf '%s' "$netplan_view" | grep -q "^[[:space:]]*${iface}:"; then
  us_error "${iface} is a WiFi interface that netplan does not currently define."
  us_error "Its SSID and passphrase are managed elsewhere (probably NetworkManager)."
  us_error ""
  us_error "Writing a netplan wifis block here would become the only definition,"
  us_error "would carry no access-points, and this host would drop off the network."
  us_error ""
  us_error "Set a static address on the existing connection profile instead:"
  us_error ""
  if us_have nmcli; then
    conn="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null |
      awk -F: -v d="$iface" '$2==d {print $1; exit}')"
    us_error "    sudo nmcli connection modify '${conn:-<your-wifi>}' \\"
    us_error "        ipv4.method manual \\"
    us_error "        ipv4.addresses ${address:-${current_cidr:-192.168.86.23/24}} \\"
    us_error "        ipv4.gateway ${gateway:-${current_gw:-192.168.86.1}} \\"
    us_error "        ipv4.dns '9.9.9.9 149.112.112.112'"
    us_error "    sudo nmcli connection up '${conn:-<your-wifi>}'"
  fi
  us_error ""
  us_error "Or simply reserve ${current_cidr%%/*} on your router — equally valid,"
  us_error "and less to go wrong on a wireless link."
  exit 1
fi

# ---------------------------------------------------------------------------
# Decide the target configuration
# ---------------------------------------------------------------------------
[[ -n "$address" ]] || address="$current_cidr"
[[ -n "$address" ]] || us_die "No current address to keep. Pass --address 192.168.86.23/24."
[[ "$address" == */* ]] || us_die "--address must include a prefix, e.g. ${address}/24"

[[ -n "$gateway" ]] || gateway="$current_gw"
[[ -n "$gateway" ]] || us_die "Could not determine a gateway. Pass --gateway."

# DNS for the link. Deliberately upstream resolvers, NOT 127.0.0.1: this host
# must be able to resolve names before AdGuard exists, which is the same
# bootstrap ordering scripts/40-adguard.sh depends on. The host is repointed at
# AdGuard later, by scripts/50-local-dns.sh, via a systemd-resolved drop-in.
if [[ -z "$dns" ]]; then
  dns="$(printf '%s' "${ADGUARD_UPSTREAM_DNS:-}" | tr ' ' '\n' |
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | paste -sd, -)"
  [[ -n "$dns" ]] || dns="9.9.9.9,149.112.112.112"
fi
dns="${dns// /,}"

us_is_valid_ipv4 "${address%%/*}" || us_die "Invalid address: ${address}"
us_is_valid_ipv4 "$gateway" || us_die "Invalid gateway: ${gateway}"

us_section "Proposed configuration"
cat >&2 <<EOF
  interface:  ${iface}   (${section}, renderer ${renderer})
  address:    ${address}   static
  gateway:    ${gateway}
  nameservers:${dns}
  file:       ${NETPLAN_FILE}

  This file only ADDS addressing keys. Your existing netplan files — including
  any WiFi credentials — are left untouched and still apply.
EOF

if [[ "${address%%/*}" != "${LAN_IP:-}" && -n "${LAN_IP:-}" ]]; then
  us_warn "This address (${address%%/*}) differs from LAN_IP=${LAN_IP} in your config."
  us_warn "Update server.env to match, or *.${LOCAL_DOMAIN:-home.arpa} will point at the wrong host."
fi

# ---------------------------------------------------------------------------
# Write, validate, apply
# ---------------------------------------------------------------------------
render_config() {
  cat <<EOF
# Managed by ${US_PROJECT_NAME} (tools/set-static-ip.sh).
#
# Additive override: it sets addressing for ${iface} only. Any other netplan
# file defining this interface — WiFi access-points in particular — still
# applies and is merged with this.
#
# Remove with: sudo ./tools/set-static-ip.sh --revert
network:
  version: 2
  renderer: ${renderer}
  ${section}:
    ${iface}:
      dhcp4: false
      dhcp6: false
      addresses:
        - ${address}
      routes:
        - to: default
          via: ${gateway}
      nameservers:
        addresses: [${dns}]
EOF
}

if [[ "$US_DRY_RUN" == "1" ]]; then
  us_info "DRY-RUN: would write ${NETPLAN_FILE}:"
  render_config >&2
  exit 0
fi

if ((!assume_yes)); then
  printf '\n' >&2
  read -rp "Apply this configuration? netplan will auto-revert in ${timeout}s unless confirmed [y/N]: " reply
  [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]] || {
    us_info "Aborted; nothing was changed."
    exit 0
  }
fi

# Back up anything we are about to replace.
if [[ -f "$NETPLAN_FILE" ]]; then
  backup="${NETPLAN_FILE}.bak.$(date -u '+%Y%m%dT%H%M%SZ')"
  cp -a "$NETPLAN_FILE" "$backup"
  chmod 0600 "$backup"
  us_info "Previous version backed up to ${backup}"
fi

render_config >"$NETPLAN_FILE"
# 0600 or netplan warns that the file is world-readable; these files can carry
# WiFi passphrases, so the warning is a real one even though ours does not.
chmod 0600 "$NETPLAN_FILE"
us_ok "Wrote ${NETPLAN_FILE}"

if ! netplan generate 2>&1; then
  us_error "netplan rejected the generated configuration; removing it."
  rm -f -- "$NETPLAN_FILE"
  netplan generate >/dev/null 2>&1 || true
  us_die "Configuration invalid. Nothing was applied."
fi
us_ok "netplan generate: configuration is valid"

# The WiFi safety net: confirm the merged view still carries access-points.
# `netplan generate` succeeding does not prove the link will still associate.
if ((is_wifi)); then
  if netplan get all 2>/dev/null | grep -q 'access-points'; then
    us_ok "WiFi access-points still present in the merged configuration"
  else
    us_error "The merged configuration no longer contains any access-points."
    us_error "Applying this would drop ${iface} off the network. Removing the file."
    rm -f -- "$NETPLAN_FILE"
    netplan generate >/dev/null 2>&1 || true
    us_die "Refused to apply a configuration that would break WiFi."
  fi
fi

us_section "Applying"
cat >&2 <<EOF
  netplan will apply this and WAIT for confirmation.
  If you lose your connection, do nothing — it reverts automatically after
  ${timeout}s and the old address comes back.
EOF

if netplan try --timeout "$timeout"; then
  us_ok "Configuration accepted"
else
  us_error "netplan try did not confirm the configuration; it has been rolled back."
  us_error "The file at ${NETPLAN_FILE} is still on disk but not in effect."
  us_error "Fix or remove it: sudo ./tools/set-static-ip.sh --revert"
  exit 1
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
us_section "Verification"
new_cidr="$(ip -4 -o addr show dev "$iface" | awk '{print $4; exit}')"
if [[ "$new_cidr" == "$address" ]]; then
  us_status_ok "${iface} holds ${address}"
else
  us_status_fail "${iface} holds ${new_cidr:-<none>}, expected ${address}"
fi

if ip -4 addr show dev "$iface" | grep -q 'dynamic'; then
  us_status_fail "Address is still DHCP-assigned; the static config did not take effect"
else
  us_status_ok "Address is static (no DHCP lease)"
fi

if ping -c1 -W2 "$gateway" >/dev/null 2>&1; then
  us_status_ok "Gateway ${gateway} reachable"
else
  us_status_warn "Gateway ${gateway} did not answer ping (it may simply block ICMP)"
fi

if getent hosts github.com >/dev/null 2>&1; then
  us_status_ok "DNS resolution works"
else
  us_status_warn "Cannot resolve github.com — check nameservers"
fi

printf '\n' >&2
us_ok "Static address configured."
us_info "Set LAN_IP=${address%%/*} in server.env if it is not already, then rerun sudo ./install.sh"
