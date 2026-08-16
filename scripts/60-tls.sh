#!/usr/bin/env bash
# scripts/60-tls.sh - Serve a certificate the LAN can be told to trust.
#
# This stage does not turn HTTPS on. Runtipi already serves it, and already
# redirects HTTP to it — see lib/tls.sh for the upstream labels that do so.
# What a stock install lacks is a certificate anyone trusts, which is why every
# service answers with a browser warning.
#
# So this stage substitutes the certificate in the slot Runtipi reserves:
#
#     1. create a local CA, once, and never again
#     2. issue a leaf for <domain>, *.<domain> and the LAN address
#     3. copy it into <data>/traefik/tls/{cert,key}.pem + the marker file
#        that stops Runtipi regenerating over it
#     4. trust the CA on this host, so diagnostics stop needing curl -k
#     5. install a daily timer that reissues before expiry
#
# Every step is idempotent, and the renewal timer re-runs this same script, so
# there is one code path rather than an install path and a renewal path that
# drift apart.
#
# The one manual step it cannot do for you is installing the CA on your
# devices. It prints what you need for that, including the fingerprint to
# check against.
#
# Runnable standalone:  sudo scripts/60-tls.sh

US_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"
# shellcheck source=lib/config.sh
source "${US_LIB_DIR}/config.sh"
# shellcheck source=lib/docker.sh
source "${US_LIB_DIR}/docker.sh"
# shellcheck source=lib/versions.sh
source "${US_LIB_DIR}/versions.sh"
# shellcheck source=lib/runtipi.sh
source "${US_LIB_DIR}/runtipi.sh"
# shellcheck source=lib/tls.sh
source "${US_LIB_DIR}/tls.sh"

us_init "tls"
us_require_root
us_config_load

us_section "Local HTTPS (${LOCAL_DOMAIN})"

# --- Opt-in ----------------------------------------------------------------
# Off by default. Generating a certificate authority is a real act with a real
# private key on a real machine, and it earns nothing until somebody installs
# it on a device. Doing that unasked would be a surprise, so the stage explains
# the current state and stops.
if ! us_config_is_true "$ENABLE_LOCAL_HTTPS"; then
  us_status_skip "ENABLE_LOCAL_HTTPS=false"
  cat >&2 <<EOF

  This does not mean services are served over plain HTTP. Runtipi routes every
  locally-exposed app through Traefik on both entrypoints and redirects the
  HTTP one to HTTPS, so http://${LOCAL_DOMAIN} already becomes https://${LOCAL_DOMAIN}.
  What you are seeing in a browser is Runtipi's self-signed certificate, which
  is valid but signed by nobody, hence the warning.

  To replace it with one your devices can be told to trust:

      ENABLE_LOCAL_HTTPS=true    in server.env, then  sudo ./install.sh

  Let's Encrypt cannot help here: ${LOCAL_DOMAIN} is not publicly delegable, so
  no ACME challenge can succeed against it. See docs/https.md.

EOF
  exit 0
fi

us_require_cmds openssl

[[ -x "$(us_runtipi_cli)" ]] ||
  us_die "Runtipi is not installed; run scripts/20-runtipi.sh first."

# --- 1. The CA -------------------------------------------------------------
# Returns 1 when the CA already existed, which is the common case and not an
# error. A newly created CA needs no special handling here: the leaf check
# below notices that any existing leaf no longer verifies against it.
us_tls_ca_ensure || true

# --- 2. The server certificate ---------------------------------------------
reason="$(us_tls_leaf_reason "$LOCAL_DOMAIN" "$LAN_IP")"
if [[ -n "$reason" ]]; then
  us_info "Issuing a server certificate (${reason})"
  us_tls_leaf_issue "$LOCAL_DOMAIN" "$LAN_IP"
else
  us_ok "Server certificate is current ($(us_tls_days_remaining "$US_TLS_LEAF_CRT") days left)"
fi

# --- 3. Hand it to Traefik -------------------------------------------------
# us_tls_install_to_runtipi returns 0 when it changed something. Only then is a
# proxy restart warranted; reruns of a converged host must not bounce Traefik.
if us_tls_install_to_runtipi "$LOCAL_DOMAIN"; then
  if [[ "$(us_docker_container_state "$US_RUNTIPI_PROXY_CONTAINER" || true)" == "running" ]]; then
    us_tls_reload_traefik
  else
    us_info "${US_RUNTIPI_PROXY_CONTAINER} is not running; it will pick the certificate up when it starts."
  fi
fi

# --- 4. Trust it here ------------------------------------------------------
us_tls_trust_on_host || true

# --- 5. Keep it alive ------------------------------------------------------
us_tls_install_renew_timer "${US_ROOT_DIR}/scripts/60-tls.sh"

# --- Verify what is actually served ----------------------------------------
# The files being right and Traefik having loaded them are separate claims, and
# only the second is what a browser sees. Ask the socket.
if [[ "$US_DRY_RUN" != "1" ]]; then
  us_section "Verification"

  # Traefik needs a moment after a restart before it accepts connections.
  waited=0
  while ((waited < 30)); do
    us_tls_served_issuer "$LAN_IP" "$LOCAL_DOMAIN" >/dev/null 2>&1 && break
    sleep 2
    waited=$((waited + 2))
  done

  issuer="$(us_tls_served_issuer "$LAN_IP" "$LOCAL_DOMAIN" 2>/dev/null || true)"
  if [[ "$issuer" == *"${US_PROJECT_NAME} Local CA"* ]]; then
    us_status_ok "Traefik is serving the local CA's certificate"
  elif [[ -n "$issuer" ]]; then
    us_status_fail "Traefik is serving a certificate from: ${issuer}"
    us_warn "Expected the local CA. If this says the certificate is self-signed by"
    us_warn "the domain itself, Runtipi regenerated it — check that the marker file"
    us_warn "$(us_runtipi_tls_marker_file "$LOCAL_DOMAIN") still exists."
  else
    us_status_fail "Nothing answered TLS on ${LAN_IP}:443"
    us_warn "Check: docker ps | grep ${US_RUNTIPI_PROXY_CONTAINER}"
  fi

  # The end-to-end claim: a client holding the CA accepts the name without
  # being told to ignore anything. This host holds the CA as of step 4.
  if us_tls_https_trusted "$LAN_IP" "$LOCAL_DOMAIN"; then
    us_status_ok "https://${LOCAL_DOMAIN} verifies against the local CA"
  else
    us_status_warn "https://${LOCAL_DOMAIN} did not verify from this host"
    us_warn "Diagnose with:  openssl s_client -connect ${LAN_IP}:443 -servername ${LOCAL_DOMAIN}"
  fi
fi

us_manifest_set_component local_tls "local-ca" \
  "$(jq -nc \
    --arg d "$LOCAL_DOMAIN" \
    --arg ca "$US_TLS_CA_CRT" \
    --arg fp "$(us_tls_fingerprint "$US_TLS_CA_CRT" 2>/dev/null || printf 'unknown')" \
    --arg exp "$(us_tls_days_remaining "$US_TLS_LEAF_CRT" 2>/dev/null || printf 'unknown')" \
    '{domain: $d, ca: $ca, ca_sha256: $fp, leaf_days_remaining: $exp}')"

# --- What the operator has to do -------------------------------------------
if [[ "$US_DRY_RUN" == "1" ]]; then
  exit 0
fi

us_section "Install the CA on your devices"
cat >&2 <<EOF

  The server now presents a certificate signed by a CA that only this machine
  trusts. Until a device is given that CA, it will keep warning — correctly.

  Copy it from any machine on the LAN:

      scp <you>@${LAN_IP}:${US_TLS_CA_CRT} ${US_TLS_EXPORTED_NAME}

  Then install it as a trusted ROOT certificate:

      macOS     open it, add to the login keychain, then set it to
                "Always Trust" (double-click > Trust > When using this
                certificate: Always Trust). Adding it is not enough on its own.
      iOS       AirDrop or mail it, install the profile, then turn it on under
                Settings > General > About > Certificate Trust Settings.
      Windows   certutil -addstore -f Root ${US_TLS_EXPORTED_NAME}   (as admin)
      Linux     sudo cp ${US_TLS_EXPORTED_NAME} /usr/local/share/ca-certificates/
                sudo update-ca-certificates
      Android   Settings > Security > Encryption & credentials >
                Install a certificate > CA certificate
      Firefox   keeps its own store: Settings > Privacy & Security >
                Certificates > View Certificates > Authorities > Import

  Check the fingerprint matches what the device shows before trusting it:

      SHA-256  $(us_tls_fingerprint "$US_TLS_CA_CRT")

  This CA can vouch for any site name to a device that trusts it. That is the
  point, and it is also the risk: keep ${US_TLS_CA_KEY} on this
  machine, and do not install this CA on a device you do not control.

EOF
