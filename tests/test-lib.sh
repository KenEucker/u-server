#!/usr/bin/env bash
# tests/test-lib.sh - Unit tests for the pure helper functions.
#
# Scope is deliberately honest: these cover the logic that can be tested
# without a host to install onto — version comparison, config derivation,
# validation, idempotent writes. Anything that needs Docker, Runtipi or DNS is
# verified by scripts/90-verify.sh and ./doctor.sh on a real machine, because
# pretending container infrastructure can be unit tested produces tests that
# pass while the server is broken.
#
#   ./tests/test-lib.sh

set -uo pipefail

US_ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
US_LIB_DIR="${US_ROOT_DIR}/lib"
export US_LIB_DIR US_ROOT_DIR

# Keep test output readable.
export US_LOG_LEVEL=error
export NO_COLOR=1

# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"
# shellcheck source=lib/versions.sh
source "${US_LIB_DIR}/versions.sh"

pass=0
fail=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  ok   %s\n' "$desc"
    ((pass++))
  else
    printf '  FAIL %s\n       expected: %q\n       actual:   %q\n' "$desc" "$expected" "$actual"
    ((fail++))
  fi
}

check_true() {
  local desc="$1"
  shift
  if "$@"; then
    printf '  ok   %s\n' "$desc"
    ((pass++))
  else
    printf '  FAIL %s (expected success)\n' "$desc"
    ((fail++))
  fi
}

check_false() {
  local desc="$1"
  shift
  if "$@"; then
    printf '  FAIL %s (expected failure)\n' "$desc"
    ((fail++))
  else
    printf '  ok   %s\n' "$desc"
    ((pass++))
  fi
}

# ---------------------------------------------------------------------------
printf '\nus_version_ge\n'
check_true  "4.10.1 >= 4.10.1"        us_version_ge "4.10.1" "4.10.1"
check_true  "4.10.1 >= 4.9.3"         us_version_ge "4.10.1" "4.9.3"
check_true  "v4.10.1 >= v4.9.3 (v prefix)" us_version_ge "v4.10.1" "v4.9.3"
check_false "4.9.3 >= 4.10.1"         us_version_ge "4.9.3" "4.10.1"
check_true  "28.0.0 >= 28.0.0"        us_version_ge "28.0.0" "28.0.0"
check_false "27.5.1 >= 28.0.0"        us_version_ge "27.5.1" "28.0.0"
# The classic string-comparison trap: 4.10 must sort above 4.9.
check_true  "4.10.0 >= 4.9.9 (numeric, not lexical)" us_version_ge "4.10.0" "4.9.9"

# ---------------------------------------------------------------------------
printf '\nus_is_valid_ipv4\n'
check_true  "192.168.8.10"    us_is_valid_ipv4 "192.168.8.10"
check_true  "10.0.0.1"        us_is_valid_ipv4 "10.0.0.1"
check_true  "255.255.255.255" us_is_valid_ipv4 "255.255.255.255"
check_false "256.1.1.1 (octet overflow)" us_is_valid_ipv4 "256.1.1.1"
check_false "192.168.8"       us_is_valid_ipv4 "192.168.8"
check_false "not-an-ip"       us_is_valid_ipv4 "not-an-ip"
check_false "empty"           us_is_valid_ipv4 ""

# ---------------------------------------------------------------------------
printf '\nus_config_is_true\n'
# shellcheck source=lib/config.sh
source "${US_LIB_DIR}/config.sh"
check_true  "'true'"  us_config_is_true "true"
check_true  "'TRUE'"  us_config_is_true "TRUE"
check_true  "'yes'"   us_config_is_true "yes"
check_true  "'1'"     us_config_is_true "1"
check_false "'false'" us_config_is_true "false"
check_false "empty"   us_config_is_true ""
check_false "'maybe'" us_config_is_true "maybe"

# ---------------------------------------------------------------------------
printf '\nus_config_subdomain_of\n'
LOCAL_DOMAIN="home.arpa"
check "nomad.home.arpa -> nomad"       "nomad"    "$(us_config_subdomain_of nomad.home.arpa)"
check "grafana.home.arpa -> grafana"   "grafana"  "$(us_config_subdomain_of grafana.home.arpa)"
check "bare label passes through"      "whoami"   "$(us_config_subdomain_of whoami)"
# A name outside LOCAL_DOMAIN is returned intact so validation can reject it
# with a useful message rather than silently truncating.
check "foreign domain kept intact"     "a.example.com" "$(us_config_subdomain_of a.example.com)"

# ---------------------------------------------------------------------------
printf '\nus_config_validate\n'
# Full config validation on a known-good set.
LAN_IP="192.168.8.10"
LOCAL_DOMAIN="home.arpa"
DNS_DOMAIN="dns.home.arpa"
NOMAD_DOMAIN="nomad.home.arpa"
MERIDIAN_DOMAIN="meridian.home.arpa"
WHOAMI_DOMAIN="whoami.home.arpa"
RUNTIPI_VERSION="stable"
NOMAD_VERSION="v1.34.0"
DNS_SUBDOMAIN=dns NOMAD_SUBDOMAIN=nomad
MERIDIAN_SUBDOMAIN=meridian WHOAMI_SUBDOMAIN=whoami

check_true "accepts a valid configuration" bash -c '
  source "'"${US_LIB_DIR}"'/config.sh" 2>/dev/null
  LAN_IP=192.168.8.10 LOCAL_DOMAIN=home.arpa
  DNS_SUBDOMAIN=dns NOMAD_SUBDOMAIN=nomad
  MERIDIAN_SUBDOMAIN=meridian WHOAMI_SUBDOMAIN=whoami
  RUNTIPI_VERSION=stable NOMAD_VERSION=stable
  us_config_validate >/dev/null 2>&1'

# Duplicate hostnames are a silent routing collision, so they must be rejected.
check_false "rejects duplicate service labels" bash -c '
  source "'"${US_LIB_DIR}"'/config.sh" 2>/dev/null
  LAN_IP=192.168.8.10 LOCAL_DOMAIN=home.arpa
  DNS_SUBDOMAIN=nomad NOMAD_SUBDOMAIN=nomad
  MERIDIAN_SUBDOMAIN=meridian WHOAMI_SUBDOMAIN=whoami
  RUNTIPI_VERSION=stable NOMAD_VERSION=stable
  us_config_validate >/dev/null 2>&1'

check_false "rejects .local as LOCAL_DOMAIN" bash -c '
  source "'"${US_LIB_DIR}"'/config.sh" 2>/dev/null
  LAN_IP=192.168.8.10 LOCAL_DOMAIN=home.local
  DNS_SUBDOMAIN=dns NOMAD_SUBDOMAIN=nomad
  MERIDIAN_SUBDOMAIN=meridian WHOAMI_SUBDOMAIN=whoami
  RUNTIPI_VERSION=stable NOMAD_VERSION=stable
  us_config_validate >/dev/null 2>&1'

check_false "rejects an invalid LAN_IP" bash -c '
  source "'"${US_LIB_DIR}"'/config.sh" 2>/dev/null
  LAN_IP=999.1.1.1 LOCAL_DOMAIN=home.arpa
  DNS_SUBDOMAIN=dns NOMAD_SUBDOMAIN=nomad
  MERIDIAN_SUBDOMAIN=meridian WHOAMI_SUBDOMAIN=whoami
  RUNTIPI_VERSION=stable NOMAD_VERSION=stable
  us_config_validate >/dev/null 2>&1'

check_false "rejects a malformed version policy" bash -c '
  source "'"${US_LIB_DIR}"'/config.sh" 2>/dev/null
  LAN_IP=192.168.8.10 LOCAL_DOMAIN=home.arpa
  DNS_SUBDOMAIN=dns NOMAD_SUBDOMAIN=nomad
  MERIDIAN_SUBDOMAIN=meridian WHOAMI_SUBDOMAIN=whoami
  RUNTIPI_VERSION=newest NOMAD_VERSION=stable
  us_config_validate >/dev/null 2>&1'

# ---------------------------------------------------------------------------
printf '\nus_write_if_changed (idempotency)\n'
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
target="${tmpdir}/out.conf"

printf 'hello\n' | us_write_if_changed "$target" 0644 >/dev/null 2>&1
check_true "creates the file"                 test -f "$target"
check      "writes the content"  "hello"      "$(cat "$target")"

# Second identical write must report "unchanged" (return 1) — that is what
# stops reruns from churning files and restarting healthy services.
printf 'hello\n' | us_write_if_changed "$target" 0644 >/dev/null 2>&1
check      "identical rewrite returns 1 (unchanged)" "1" "$?"

printf 'goodbye\n' | us_write_if_changed "$target" 0644 >/dev/null 2>&1
rc=$?
check      "changed rewrite returns 0"        "0" "$rc"
check      "content updated"     "goodbye"    "$(cat "$target")"
check_true "previous version backed up"       bash -c "ls '${tmpdir}'/out.conf.bak.* >/dev/null 2>&1"

# ---------------------------------------------------------------------------
printf '\nus_runtipi_asset_name\n'
# shellcheck source=lib/runtipi.sh
source "${US_LIB_DIR}/runtipi.sh" 2>/dev/null
uname() { printf 'x86_64'; }
check "x86_64 maps to the published asset" \
  "runtipi-cli-linux-x86_64.tar.gz" "$(us_runtipi_asset_name)"
uname() { printf 'aarch64'; }
check "aarch64 maps to the published asset" \
  "runtipi-cli-linux-aarch64.tar.gz" "$(us_runtipi_asset_name)"
uname() { printf 'riscv64'; }
check_false "unsupported architecture is rejected" us_runtipi_asset_name
unset -f uname

# ---------------------------------------------------------------------------
printf '\nProject NOMAD contract constants\n'
# shellcheck source=lib/nomad.sh
source "${US_LIB_DIR}/nomad.sh" 2>/dev/null
# These are contracts with upstream source, not preferences. If one changes,
# the app store package must change with it — see lib/nomad.sh.
check "child network name" "project-nomad_default" "$(us_nomad_network_name)"
check "admin container name" "nomad_admin" "$US_NOMAD_ADMIN_CONTAINER"
check "storage mount destination" "/app/storage" "$US_NOMAD_STORAGE_DEST"

# The app store package must actually honour those constants.
nomad_compose="${US_ROOT_DIR}/appstore/apps/project-nomad/docker-compose.yml"
check_true "package declares the literal child network name" \
  grep -q "name: project-nomad_default" "$nomad_compose"
check_true "package pins container_name: nomad_admin" \
  grep -q "container_name: nomad_admin" "$nomad_compose"
check_true "package binds /app/storage" \
  grep -q ":/app/storage" "$nomad_compose"
# Contract 3: the self-updater must stay out of the package.
check_false "package omits the upstream updater sidecar" \
  grep -q "sidecar-updater" "$nomad_compose"

# ---------------------------------------------------------------------------
printf '\n%s\n' "-----------------------------"
printf 'passed: %d   failed: %d\n\n' "$pass" "$fail"
((fail == 0)) || exit 1
