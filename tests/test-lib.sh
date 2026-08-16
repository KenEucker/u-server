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
    pass=$((pass + 1))
  else
    printf '  FAIL %s\n       expected: %q\n       actual:   %q\n' "$desc" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

check_true() {
  local desc="$1"
  shift
  if "$@"; then
    printf '  ok   %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf '  FAIL %s (expected success)\n' "$desc"
    fail=$((fail + 1))
  fi
}

check_false() {
  local desc="$1"
  shift
  if "$@"; then
    printf '  FAIL %s (expected failure)\n' "$desc"
    fail=$((fail + 1))
  else
    printf '  ok   %s\n' "$desc"
    pass=$((pass + 1))
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
check "dns.home.arpa -> dns"           "dns"      "$(us_config_subdomain_of dns.home.arpa)"
check "grafana.home.arpa -> grafana"   "grafana"  "$(us_config_subdomain_of grafana.home.arpa)"
check "bare label passes through"      "media"    "$(us_config_subdomain_of media)"
# A name outside LOCAL_DOMAIN is returned intact so validation can reject it
# with a useful message rather than silently truncating.
check "foreign domain kept intact"     "a.example.com" "$(us_config_subdomain_of a.example.com)"

# ---------------------------------------------------------------------------
printf '\nus_config_validate\n'
# Full config validation on a known-good set.
LAN_IP="192.168.8.10"
LOCAL_DOMAIN="home.arpa"
DNS_DOMAIN="dns.home.arpa"
RUNTIPI_VERSION="stable"
DNS_SUBDOMAIN=dns

check_true "accepts a valid configuration" bash -c '
  source "'"${US_LIB_DIR}"'/config.sh" 2>/dev/null
  LAN_IP=192.168.8.10 LOCAL_DOMAIN=home.arpa
  DNS_SUBDOMAIN=dns RUNTIPI_VERSION=stable
  us_config_validate >/dev/null 2>&1'

# The service label must satisfy Runtipi's localSubdomain pattern; a dotted
# value means DNS_DOMAIN was not a single label under LOCAL_DOMAIN.
check_false "rejects a service label that is not a single label" bash -c '
  source "'"${US_LIB_DIR}"'/config.sh" 2>/dev/null
  LAN_IP=192.168.8.10 LOCAL_DOMAIN=home.arpa
  DNS_SUBDOMAIN=dns.example.com RUNTIPI_VERSION=stable
  us_config_validate >/dev/null 2>&1'

check_false "rejects .local as LOCAL_DOMAIN" bash -c '
  source "'"${US_LIB_DIR}"'/config.sh" 2>/dev/null
  LAN_IP=192.168.8.10 LOCAL_DOMAIN=home.local
  DNS_SUBDOMAIN=dns RUNTIPI_VERSION=stable
  us_config_validate >/dev/null 2>&1'

check_false "rejects an invalid LAN_IP" bash -c '
  source "'"${US_LIB_DIR}"'/config.sh" 2>/dev/null
  LAN_IP=999.1.1.1 LOCAL_DOMAIN=home.arpa
  DNS_SUBDOMAIN=dns RUNTIPI_VERSION=stable
  us_config_validate >/dev/null 2>&1'

check_false "rejects a malformed version policy" bash -c '
  source "'"${US_LIB_DIR}"'/config.sh" 2>/dev/null
  LAN_IP=192.168.8.10 LOCAL_DOMAIN=home.arpa
  DNS_SUBDOMAIN=dns RUNTIPI_VERSION=newest
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
printf '\nRuntipi app identity matching\n'
# shellcheck source=lib/runtipi.sh
source "${US_LIB_DIR}/runtipi.sh" 2>/dev/null

# These payloads are the reason this section exists. Matching only
# `.installed[].app.urn` made an installed, running AdGuard read as "never
# appeared" — a state the wait loop could not distinguish from a slow image
# pull, so it waited out the full timeout and then blamed the install. Runtipi
# has expressed app identity three ways across 4.x, and any of them must
# resolve to the same answer. If upstream adds a fourth, a test here fails
# before an operator loses fifteen minutes to a silent poll.
if us_have jq; then
  urn_shape='{"installed":[{"app":{"urn":"adguard:migrated","status":"running"}}]}'
  split_shape='{"installed":[{"app":{"appName":"adguard","appStoreSlug":"migrated","status":"running"}}]}'
  id_shape='{"installed":[{"app":{"id":"adguard:migrated","status":"starting"}}]}'
  bare_array='[{"app":{"urn":"adguard:migrated","status":"running"}}]'
  flat_shape='{"apps":[{"urn":"adguard:migrated","status":"running"}]}'

  check "status from an explicit urn field" "running" \
    "$(us_runtipi_app_status_from "$urn_shape" "adguard:migrated")"
  check "status from appName + appStoreSlug" "running" \
    "$(us_runtipi_app_status_from "$split_shape" "adguard:migrated")"
  check "status from an id that is the urn" "starting" \
    "$(us_runtipi_app_status_from "$id_shape" "adguard:migrated")"
  check "status from a bare array container" "running" \
    "$(us_runtipi_app_status_from "$bare_array" "adguard:migrated")"
  check "status from a flat record under .apps" "running" \
    "$(us_runtipi_app_status_from "$flat_shape" "adguard:migrated")"

  check_true "presence is detected via appName + appStoreSlug" \
    us_runtipi_app_present_in "$split_shape" "adguard:migrated"
  check_false "a different app is not a match" \
    us_runtipi_app_present_in "$split_shape" "grafana:migrated"

  # The store slug is discovered, not fixed, so the same app under a different
  # slug must be found by name — that is what stops a second install being
  # posted for an app Runtipi already has.
  check "recorded urn is found by app name" "adguard:migrated" \
    "$(us_runtipi_app_urn_from "$split_shape" "adguard")"
  check "recorded urn is found by name from a urn field" "adguard:migrated" \
    "$(us_runtipi_app_urn_from "$urn_shape" "adguard")"
  check "an uninstalled app yields no urn" "" \
    "$(us_runtipi_app_urn_from "$urn_shape" "grafana")"

  # Malformed or empty payloads must answer "absent", never error out: the
  # callers treat a non-answer as "keep waiting", and a jq crash there is
  # indistinguishable from an app that is genuinely missing.
  check "empty installed list yields no status" "" \
    "$(us_runtipi_app_status_from '{"installed":[]}' "adguard:migrated")"
  check "unrecognised shape yields no status" "" \
    "$(us_runtipi_app_status_from '{"something":"else"}' "adguard:migrated")"
  check "record with no identity yields no status" "" \
    "$(us_runtipi_app_status_from '{"installed":[{"app":{"status":"running"}}]}' "adguard:migrated")"
  check "non-JSON yields no status" "" \
    "$(us_runtipi_app_status_from 'not json at all' "adguard:migrated")"
else
  printf '  skip jq not installed; app identity matching not exercised\n'
fi

# ---------------------------------------------------------------------------
printf '\nTLS certificate naming\n'
# shellcheck source=lib/tls.sh
source "${US_LIB_DIR}/tls.sh" 2>/dev/null

# The whole point of normalising is that these two forms must compare equal.
# openssl PRINTS "IP Address:" when reading a certificate but only ACCEPTS
# "IP:" when writing one, and it preserves whatever order the extension was
# built in. Without normalisation the comparison never matches, the leaf is
# reissued on every single run, and Traefik is restarted every run with it.
check "desired SAN is canonical and sorted" \
  "DNS:*.home.arpa,DNS:home.arpa,IP:192.168.8.10" \
  "$(us_tls_desired_san home.arpa 192.168.8.10)"

check "openssl's read form normalises to the write form" \
  "DNS:*.home.arpa,DNS:home.arpa,IP:192.168.8.10" \
  "$(printf 'DNS:home.arpa, DNS:*.home.arpa, IP Address:192.168.8.10' | us_tls_san_normalise)"

check "ordering differences do not count as a change" \
  "$(us_tls_desired_san home.arpa 192.168.8.10)" \
  "$(printf '  IP Address:192.168.8.10,DNS:*.home.arpa,  DNS:home.arpa' | us_tls_san_normalise)"

# The apex must be listed explicitly: *.home.arpa does not match home.arpa in
# either DNS (RFC 4592) or TLS, and home.arpa is where the dashboard lives.
# This also pins that no IP is emitted when LAN_IP is unset.
check "apex is covered as well as the wildcard, with no IP" \
  "DNS:*.home.arpa,DNS:home.arpa" \
  "$(us_tls_desired_san home.arpa "")"

# ---------------------------------------------------------------------------
printf '\nTLS certificate issuance (real openssl)\n'
if us_have openssl && us_have date; then
  tlsdir="$(mktemp -d)"
  # Point the library at a scratch CA rather than /etc/u-server. These two are
  # read only from inside the lib/tls.sh functions under test, which shellcheck
  # cannot associate with the assignments here.
  # shellcheck disable=SC2034
  US_TLS_CA_DIR="$tlsdir"
  US_TLS_CA_KEY="${tlsdir}/ca.key"
  US_TLS_CA_CRT="${tlsdir}/ca.crt"
  # shellcheck disable=SC2034
  US_TLS_CA_SRL="${tlsdir}/ca.srl"
  US_TLS_LEAF_KEY="${tlsdir}/server.key"
  US_TLS_LEAF_CRT="${tlsdir}/server.crt"
  LOCAL_DOMAIN="home.arpa"
  US_DRY_RUN=0

  us_tls_ca_ensure >/dev/null 2>&1
  check_true "CA is created"              test -f "$US_TLS_CA_CRT"

  # A world-readable CA private key is the one file on this host that must not
  # be one, so it is worth asserting — but only where the filesystem can
  # express it. A Windows checkout reports 644 no matter what chmod was asked
  # for, and a test that always fails there is a test people learn to ignore.
  probe="${tlsdir}/.mode-probe"
  touch "$probe" && chmod 0600 "$probe"
  modes_observable=0
  if [[ "$(stat -c '%a' "$probe" 2>/dev/null)" == "600" ]]; then
    modes_observable=1
    check "CA key is private" "600" "$(stat -c '%a' "$US_TLS_CA_KEY")"
  else
    printf '  skip filesystem does not honour chmod; key permissions not exercised\n'
  fi

  # A CA that is not marked as one is silently rejected by some clients.
  check_true "CA is marked CA:TRUE" bash -c \
    "openssl x509 -noout -text -in '$US_TLS_CA_CRT' | grep -q 'CA:TRUE'"

  # Creating it twice must not replace it: every device that trusted the first
  # one would silently stop trusting the server.
  before="$(us_tls_fingerprint "$US_TLS_CA_CRT")"
  us_tls_ca_ensure >/dev/null 2>&1 || true
  check "rerunning never regenerates the CA" "$before" "$(us_tls_fingerprint "$US_TLS_CA_CRT")"

  us_tls_leaf_issue home.arpa 192.168.8.10 >/dev/null 2>&1
  check_true "leaf is issued"             test -f "$US_TLS_LEAF_CRT"
  ((modes_observable)) &&
    check "leaf key is private" "600" "$(stat -c '%a' "$US_TLS_LEAF_KEY")"
  check_true "leaf verifies against the CA" us_tls_signed_by "$US_TLS_LEAF_CRT" "$US_TLS_CA_CRT"
  check "leaf carries exactly the wanted names" \
    "$(us_tls_desired_san home.arpa 192.168.8.10)" \
    "$(us_tls_cert_san "$US_TLS_LEAF_CRT")"

  # A converged host must report no reason to reissue. If this regresses, every
  # install rerun silently bounces Traefik.
  check "a current leaf gives no reason to reissue" "" \
    "$(us_tls_leaf_reason home.arpa 192.168.8.10)"

  # ...but a changed LAN_IP or domain must be caught, or the server keeps
  # serving a certificate for a name it no longer answers to.
  # Defined as a function, not a `bash -c` string: check_true runs its argument
  # in THIS shell, and a subshell would not have the library sourced.
  needs_reissue() { [[ -n "$(us_tls_leaf_reason "$1" "${2:-}")" ]]; }
  check_true "a changed LAN_IP forces reissue" needs_reissue home.arpa 192.168.8.99
  check_true "a changed domain forces reissue" needs_reissue lab.arpa 192.168.8.10

  days="$(us_tls_days_remaining "$US_TLS_LEAF_CRT")"
  # Must stay under the 398-day cap Safari applies, and obviously be in the
  # future. 397 leaves no rounding room to get this wrong.
  in_range() { (($1 > 0 && $1 < 398)); }
  check_true "expiry is in the future and under the 398-day cap" in_range "$days"

  rm -rf "$tlsdir"
else
  printf '  skip openssl not installed; certificate issuance not exercised\n'
fi

# ---------------------------------------------------------------------------
printf '\nset -e safety\n'
# `((n++))` evaluates to the value BEFORE incrementing, and an arithmetic
# command whose result is 0 exits 1. Every counter in this repo starts at 0, so
# the first increment would abort the script under `set -Eeuo pipefail`.
#
# This bit for real: scripts/00-preflight.sh would have died on its first
# warning (e.g. "memory below 4 GB") instead of collecting it and continuing.
# The pattern is banned outright; use `n=$((n + 1))`, which always exits 0.
# Scanned across the shipped scripts. tests/ is excluded because this file
# deliberately contains the pattern, both in the prose above and in the
# demonstration below; comment lines are excluded for the same reason.
check "no ((var++)) in any shipped script" "" \
  "$(grep -rn -E '\(\([a-z_]+\+\+\)\)' --include='*.sh' "$US_ROOT_DIR" 2>/dev/null |
    grep -v '/\.git/' | grep -v '/tests/' | grep -vE ':[0-9]+:[[:space:]]*#' || true)"

# Demonstrates the trap itself, so the reason for the ban stays visible.
check_false "((n++)) really does exit non-zero when n is 0" \
  bash -c 'n=0; ((n++))'
check_true "n=\$((n + 1)) exits zero when n is 0" \
  bash -c 'n=0; n=$((n + 1))'

# ---------------------------------------------------------------------------
printf '\n%s\n' "-----------------------------"
printf 'passed: %d   failed: %d\n\n' "$pass" "$fail"
((fail == 0)) || exit 1
