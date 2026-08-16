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
