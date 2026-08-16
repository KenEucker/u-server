#!/usr/bin/env bash
# lib/tls.sh - Local certificate authority for *.LOCAL_DOMAIN.
#
# WHY A LOCAL CA AND NOT LET'S ENCRYPT
# ------------------------------------
# Let's Encrypt will not issue for home.arpa, and no amount of configuration
# changes that. ACME requires a publicly-delegable name: HTTP-01 needs the CA's
# servers to reach the host over the Internet, and DNS-01 needs a TXT record in
# a zone rooted at the public DNS hierarchy. home.arpa is reserved by RFC 8375
# precisely so that it is *not* delegable, so neither challenge can ever
# succeed. Public ACME becomes possible only by giving up home.arpa for a
# domain you own — see docs/https.md, which spells out that trade.
#
# A local CA gets the same result on the LAN (a green padlock, no warning) at
# the cost of installing one certificate per client device, and it works with
# the WAN unplugged, which matters for docs/future-offline-design.md.
#
# WHAT THIS FILLS IN
# ------------------
# HTTPS is not something this file switches on. Runtipi already serves it:
#
#   * Every locally-exposed app gets a websecure router with `tls: true` and
#     NO certresolver, plus a `redirectscheme` middleware on the web router
#     (traefik-labels.builder.ts). The dashboard is labelled the same way
#     (docker-compose.prod.yml, dashboard-local-insecure/dashboard-local).
#     So http://<app>.<domain> already 301s to https, today, unconfigured.
#
#   * With no certresolver, those routers serve Traefik's DEFAULT certificate,
#     which Runtipi's shipped dynamic.yml points at:
#         tls.stores.default.defaultCertificate:
#           certFile: /etc/traefik/tls/cert.pem
#           keyFile:  /etc/traefik/tls/key.pem
#
#   * Runtipi fills those two files with a self-signed certificate for
#     DNS:*.<localDomain>,DNS:<localDomain> (app.service.ts). That is why a
#     stock install answers https and warns: the certificate is fine, it is
#     just signed by nobody.
#
# So the job is not "enable TLS". It is "make the certificate in that slot one
# your devices trust", which is a substitution, not a new mechanism. Nothing
# upstream is patched, forked, or worked around.
#
# WHY RUNTIPI LEAVES OUR CERTIFICATE ALONE
# ----------------------------------------
# generateTlsCertificates() skips regeneration only when ALL of these hold
# (app.service.ts):
#
#     <tls>/<localDomain>.txt exists
#     <tls>/cert.pem          exists
#     <tls>/key.pem           exists
#     openssl x509 -checkend 86400 -in cert.pem  says "will not expire"
#
# We satisfy all four. The marker file is the part that is easy to miss: leave
# it out and Runtipi overwrites our certificate with a self-signed one on the
# next restart, silently, and the only symptom is that browser warnings come
# back. The `-checkend 86400` clause is also why renewal runs at 30 days
# remaining rather than at the last minute — an expired-but-unreplaced
# certificate gets clobbered rather than merely expiring, which turns a
# calendar problem into a "why did my CA stop working" problem.
#
# Verified against runtipi/runtipi @ v4.10.1 (2026-08).

[[ -n "${_US_TLS_SOURCED:-}" ]] && return 0
_US_TLS_SOURCED=1

# shellcheck source=lib/common.sh
source "${US_LIB_DIR}/common.sh"
# shellcheck source=lib/runtipi.sh
source "${US_LIB_DIR}/runtipi.sh"

# ---------------------------------------------------------------------------
# Layout and policy
# ---------------------------------------------------------------------------
# The CA lives under /etc/u-server, NOT in Runtipi's data directory. Runtipi's
# tls folder is a slot we write into; it is reset by a Runtipi reinstall and
# wiped by --purge-data. The CA private key must outlive both, because every
# device that trusted it would otherwise have to be visited again.
US_TLS_CA_DIR="${US_CONF_DIR}/ca"
US_TLS_CA_KEY="${US_TLS_CA_DIR}/ca.key"
US_TLS_CA_CRT="${US_TLS_CA_DIR}/ca.crt"
US_TLS_CA_SRL="${US_TLS_CA_DIR}/ca.srl"
US_TLS_LEAF_KEY="${US_TLS_CA_DIR}/server.key"
US_TLS_LEAF_CRT="${US_TLS_CA_DIR}/server.crt"

# Where update-ca-certificates(8) expects a local anchor. Must end in .crt.
US_TLS_HOST_ANCHOR="/usr/local/share/ca-certificates/${US_PROJECT_NAME}-local-ca.crt"

US_TLS_RENEW_UNIT="${US_PROJECT_NAME}-tls-renew"

# 10 years. The CA is the thing humans have to install by hand on every phone,
# laptop and tablet they own; making that an annual chore would guarantee it
# stops being done. A long-lived CA with short-lived leaves is the standard
# shape for exactly this reason.
US_TLS_CA_DAYS="${US_TLS_CA_DAYS:-3650}"

# 397 days. Public CAs are capped at 398 by the CA/Browser Forum and Apple
# enforces it in Safari. That cap does not formally apply to a user-installed
# root, but sitting under it costs nothing and avoids discovering the hard way
# that some client applies the rule anyway.
US_TLS_LEAF_DAYS="${US_TLS_LEAF_DAYS:-397}"

# Reissue this far ahead of expiry. Comfortably more than the daily timer needs
# and far more than Runtipi's 24-hour clobber window.
US_TLS_RENEW_BEFORE_DAYS="${US_TLS_RENEW_BEFORE_DAYS:-30}"

# The filename the CA is suggested to be saved as on a client device.
#
# shellcheck disable=SC2034  # read by scripts/60-tls.sh, which sources this
# file; each file is analysed alone, so cross-file consumption is invisible.
# (A continuation line must not itself begin with the word shellcheck, or it is
# parsed as a second directive and the whole file fails to parse.)
US_TLS_EXPORTED_NAME="${US_PROJECT_NAME}-local-ca.crt"

# ---------------------------------------------------------------------------
# SAN handling (pure — unit tested in tests/test-lib.sh)
# ---------------------------------------------------------------------------

# us_tls_san_normalise - read a SAN list on stdin, print a canonical form.
#
# Exists so "what the certificate has" and "what it should have" can be
# compared as strings. openssl prints `IP Address:` when reading a certificate
# but only accepts `IP:` when writing one, and it preserves whatever order the
# extension was built in, so the two forms never compare equal by accident.
# Normalising both sides is what makes a changed LAN_IP or LOCAL_DOMAIN
# reissue the leaf instead of silently serving a certificate for the old name.
us_tls_san_normalise() {
  tr ',' '\n' |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      -e 's/^IP Address:/IP:/' |
    grep -E '^(DNS|IP):.+' |
    sort -u |
    paste -sd, -
}

# us_tls_desired_san <domain> [ip] - the SAN set a leaf must carry.
#
# The apex is listed alongside the wildcard because DNS wildcards do not cover
# it (RFC 4592) and neither do certificate wildcards — *.home.arpa does not
# match home.arpa, which is exactly where Runtipi's dashboard lives. The IP is
# included so https://<LAN_IP> works during diagnosis, when name resolution is
# often the thing under suspicion.
us_tls_desired_san() {
  local domain="$1" ip="${2:-}"
  {
    printf 'DNS:%s\n' "$domain"
    printf 'DNS:*.%s\n' "$domain"
    [[ -n "$ip" ]] && printf 'IP:%s\n' "$ip"
  } | us_tls_san_normalise
}

# us_tls_cert_san <cert-file> - the SAN set a certificate actually carries.
us_tls_cert_san() {
  local cert="$1"
  [[ -f "$cert" ]] || return 1
  openssl x509 -noout -ext subjectAltName -in "$cert" 2>/dev/null |
    grep -v 'Subject Alternative Name' |
    us_tls_san_normalise
}

# ---------------------------------------------------------------------------
# Certificate inspection
# ---------------------------------------------------------------------------

# us_tls_days_remaining <cert-file> - whole days until notAfter; negative once
# expired. Prints nothing and fails if the file is not a certificate.
us_tls_days_remaining() {
  local cert="$1" end end_s now
  [[ -f "$cert" ]] || return 1
  end="$(openssl x509 -noout -enddate -in "$cert" 2>/dev/null | cut -d= -f2-)" || return 1
  [[ -n "$end" ]] || return 1
  end_s="$(date -d "$end" +%s 2>/dev/null)" || return 1
  now="$(date +%s)"
  printf '%s' "$(((end_s - now) / 86400))"
}

us_tls_fingerprint() {
  local cert="$1"
  [[ -f "$cert" ]] || return 1
  openssl x509 -noout -fingerprint -sha256 -in "$cert" 2>/dev/null | cut -d= -f2-
}

# us_tls_signed_by <leaf> <ca> - does this CA actually vouch for this leaf?
# Catches the case where the CA was regenerated (or restored from a different
# host) while a leaf from the previous one was left in place.
us_tls_signed_by() {
  local leaf="$1" ca="$2"
  [[ -f "$leaf" && -f "$ca" ]] || return 1
  openssl verify -CAfile "$ca" "$leaf" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Creating the CA
# ---------------------------------------------------------------------------

us_tls_ca_exists() { [[ -f "$US_TLS_CA_KEY" && -f "$US_TLS_CA_CRT" ]]; }

# us_tls_ca_ensure
# Creates the CA once and never again — the same rule as us_secret_get_or_create,
# and for a stronger reason: rotating this key silently invalidates the trust
# every device on the LAN was configured with by hand. If it must be replaced,
# that is a deliberate act (docs/https.md), not something a rerun does.
us_tls_ca_ensure() {
  if us_tls_ca_exists; then
    us_ok "Local CA already present (${US_TLS_CA_CRT})"
    return 1
  fi

  if [[ "$US_DRY_RUN" == "1" ]]; then
    us_info "DRY-RUN: would create a local CA at ${US_TLS_CA_CRT}"
    return 0
  fi

  us_ensure_dir "$US_TLS_CA_DIR" 0755

  us_info "Creating a local certificate authority (valid ${US_TLS_CA_DAYS} days)"
  # -addext rather than a generated openssl.cnf: it needs no temporary file and
  # is the same mechanism upstream Runtipi uses, so there is one less way for
  # this to behave differently from the certificate it replaces.
  #
  # pathlen:0 says this CA may sign end-entity certificates and nothing else.
  # If the key is ever stolen it can still impersonate any site on this LAN,
  # but it cannot be used to mint further CAs, which keeps the blast radius
  # describable.
  #
  # The CN is what a device shows in its trust settings, so it names the
  # project and the domain rather than something generic like "Root CA" that
  # nobody can later identify or safely remove.
  openssl req -x509 -new -nodes \
    -newkey rsa:4096 -sha256 \
    -days "$US_TLS_CA_DAYS" \
    -keyout "$US_TLS_CA_KEY" \
    -out "$US_TLS_CA_CRT" \
    -subj "/O=${US_PROJECT_NAME}/CN=${US_PROJECT_NAME} Local CA (${LOCAL_DOMAIN})" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" ||
    us_die "Could not create the local CA. Is openssl installed and ${US_TLS_CA_DIR} writable?"

  chmod 0600 "$US_TLS_CA_KEY"
  chmod 0644 "$US_TLS_CA_CRT"

  us_ok "Created local CA: $(us_tls_fingerprint "$US_TLS_CA_CRT")"
  return 0
}

# ---------------------------------------------------------------------------
# Issuing the server certificate
# ---------------------------------------------------------------------------

# us_tls_leaf_reason <domain> <ip>
# Prints why the leaf needs reissuing, or nothing when it is fine. Returning
# the reason rather than a bare boolean is what lets the stage say "reissuing:
# LAN_IP changed" instead of reissuing wordlessly on every run and leaving the
# operator to guess whether that is normal.
us_tls_leaf_reason() {
  local domain="$1" ip="${2:-}" days want got

  [[ -f "$US_TLS_LEAF_CRT" && -f "$US_TLS_LEAF_KEY" ]] || {
    printf 'no certificate yet'
    return 0
  }

  if ! us_tls_signed_by "$US_TLS_LEAF_CRT" "$US_TLS_CA_CRT"; then
    printf 'not signed by the current CA'
    return 0
  fi

  want="$(us_tls_desired_san "$domain" "$ip")"
  got="$(us_tls_cert_san "$US_TLS_LEAF_CRT" 2>/dev/null || true)"
  if [[ "$want" != "$got" ]]; then
    printf 'names changed (have %s, want %s)' "${got:-none}" "$want"
    return 0
  fi

  if ! days="$(us_tls_days_remaining "$US_TLS_LEAF_CRT")"; then
    printf 'expiry could not be read'
    return 0
  fi
  if ((days < US_TLS_RENEW_BEFORE_DAYS)); then
    printf 'expires in %s day(s)' "$days"
    return 0
  fi

  return 0
}

# us_tls_leaf_issue <domain> <ip>
# Issues a fresh leaf signed by the CA. Unconditional: the caller decides
# whether it is needed, so that "should I?" and "do it" stay separable and the
# renewal timer can reuse both.
us_tls_leaf_issue() {
  local domain="$1" ip="${2:-}" csr ext san

  san="$(us_tls_desired_san "$domain" "$ip")"

  if [[ "$US_DRY_RUN" == "1" ]]; then
    us_info "DRY-RUN: would issue a certificate for ${san}"
    return 0
  fi

  us_tls_ca_exists || us_die "No local CA at ${US_TLS_CA_CRT}; cannot issue a certificate."
  us_ensure_dir "$US_TLS_CA_DIR" 0755

  csr="$(mktemp)"
  ext="$(mktemp)"
  # shellcheck disable=SC2064  # expand now, on purpose
  trap "rm -f '${csr}' '${ext}'" RETURN

  # serverAuth only. A certificate that can also authenticate clients or sign
  # code is a strictly larger thing to hand out than what Traefik needs.
  cat >"$ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${san}
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

  us_info "Issuing a certificate for ${san} (valid ${US_TLS_LEAF_DAYS} days)"

  openssl req -new -nodes \
    -newkey rsa:2048 -sha256 \
    -keyout "$US_TLS_LEAF_KEY" \
    -out "$csr" \
    -subj "/CN=${domain}" ||
    us_die "Could not create the certificate request for ${domain}."

  openssl x509 -req -sha256 \
    -in "$csr" \
    -CA "$US_TLS_CA_CRT" \
    -CAkey "$US_TLS_CA_KEY" \
    -CAserial "$US_TLS_CA_SRL" -CAcreateserial \
    -days "$US_TLS_LEAF_DAYS" \
    -extfile "$ext" \
    -out "$US_TLS_LEAF_CRT" ||
    us_die "Could not sign the certificate for ${domain}."

  chmod 0600 "$US_TLS_LEAF_KEY"
  chmod 0644 "$US_TLS_LEAF_CRT"

  # Prove the thing we just built is actually valid against the CA rather than
  # trusting that four openssl invocations all did what they were told.
  us_tls_signed_by "$US_TLS_LEAF_CRT" "$US_TLS_CA_CRT" ||
    us_die "The freshly issued certificate does not verify against ${US_TLS_CA_CRT}."

  us_ok "Issued certificate, valid $(us_tls_days_remaining "$US_TLS_LEAF_CRT") days"
}

# ---------------------------------------------------------------------------
# Installing into Runtipi's certificate slot
# ---------------------------------------------------------------------------

# us_tls_install_to_runtipi <domain>
# Copies the leaf into the two files Runtipi's dynamic.yml already points
# Traefik at, and writes the marker that stops Runtipi regenerating over them.
# Returns 0 when something changed (so the caller restarts Traefik), 1 when
# the files were already correct.
us_tls_install_to_runtipi() {
  local domain="$1" tls_dir marker changed=1
  tls_dir="$(us_runtipi_traefik_tls_dir)"
  marker="$(us_runtipi_tls_marker_file "$domain")"

  if [[ "$US_DRY_RUN" == "1" ]]; then
    us_info "DRY-RUN: would install the certificate into ${tls_dir}"
    return 0
  fi

  us_ensure_dir "$tls_dir" 0755

  # Compared by content, not copied blindly: an unchanged rerun must not
  # restart a healthy Traefik.
  if ! cmp -s "$US_TLS_LEAF_CRT" "${tls_dir}/cert.pem"; then
    install -m 0644 "$US_TLS_LEAF_CRT" "${tls_dir}/cert.pem" ||
      us_die "Could not write ${tls_dir}/cert.pem"
    changed=0
  fi
  if ! cmp -s "$US_TLS_LEAF_KEY" "${tls_dir}/key.pem"; then
    install -m 0600 "$US_TLS_LEAF_KEY" "${tls_dir}/key.pem" ||
      us_die "Could not write ${tls_dir}/key.pem"
    changed=0
  fi

  # The marker Runtipi tests for with isFile(). Its contents are never read, so
  # they are used to explain the file to whoever finds it.
  if [[ ! -f "$marker" ]]; then
    cat >"$marker" <<EOF
Managed by ${US_PROJECT_NAME}.

Runtipi treats the presence of this file, plus a cert.pem that is not within
24 hours of expiry, as "a certificate for ${domain} already exists" and skips
generating a self-signed one (app.service.ts, generateTlsCertificates).

Deleting this file makes Runtipi overwrite cert.pem and key.pem on its next
restart, and browser warnings come back. The certificate here is issued by the
local CA at ${US_TLS_CA_CRT} and renewed by ${US_TLS_RENEW_UNIT}.timer.
EOF
    chmod 0644 "$marker"
    changed=0
  fi

  if ((changed == 0)); then
    us_ok "Installed the certificate into ${tls_dir}"
  else
    us_debug "Runtipi certificate slot already current"
  fi
  return "$changed"
}

# us_tls_reload_traefik
# Traefik's file provider watches the dynamic *configuration*; it does not
# watch the bytes of the certificate files that configuration points at. So
# replacing cert.pem does nothing until the proxy re-reads it. A restart is
# used rather than touching dynamic.yml to fake a config change: it is a
# one-second blip on a container marked `restart: unless-stopped`, and it is
# unambiguous, which a watcher poke is not.
us_tls_reload_traefik() {
  us_info "Restarting ${US_RUNTIPI_PROXY_CONTAINER} to load the new certificate"
  us_run docker restart "$US_RUNTIPI_PROXY_CONTAINER" >/dev/null ||
    us_warn "Could not restart ${US_RUNTIPI_PROXY_CONTAINER}; the old certificate stays in use until it restarts."
}

# ---------------------------------------------------------------------------
# Host trust
# ---------------------------------------------------------------------------

# us_tls_trust_on_host
# Teaches this machine to trust its own CA. Not cosmetic: without it every
# curl, health check and diagnostic run from the server has to be told -k,
# which trains everyone to pass -k and hides the day the certificate really is
# wrong.
us_tls_trust_on_host() {
  if [[ "$US_DRY_RUN" == "1" ]]; then
    us_info "DRY-RUN: would install the CA into the host trust store"
    return 0
  fi

  if cmp -s "$US_TLS_CA_CRT" "$US_TLS_HOST_ANCHOR"; then
    us_debug "CA already in the host trust store"
    return 1
  fi

  us_have update-ca-certificates || {
    us_warn "update-ca-certificates not found; the host itself will not trust the local CA."
    return 1
  }

  us_ensure_dir "$(dirname "$US_TLS_HOST_ANCHOR")" 0755
  install -m 0644 "$US_TLS_CA_CRT" "$US_TLS_HOST_ANCHOR" ||
    us_die "Could not write ${US_TLS_HOST_ANCHOR}"
  us_run update-ca-certificates >/dev/null 2>&1 ||
    us_warn "update-ca-certificates reported an error; check ${US_TLS_HOST_ANCHOR}"
  us_ok "Host now trusts the local CA"
  return 0
}

us_tls_untrust_on_host() {
  [[ -f "$US_TLS_HOST_ANCHOR" ]] || return 0
  us_info "Removing the local CA from the host trust store"
  us_run rm -f -- "$US_TLS_HOST_ANCHOR"
  us_have update-ca-certificates &&
    us_run update-ca-certificates --fresh >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Renewal
# ---------------------------------------------------------------------------

# us_tls_install_renew_timer <stage-script-path>
# The leaf outlives any sensible install cadence, so renewal cannot depend on
# somebody rerunning install.sh. A daily timer re-runs the stage, which is
# idempotent and does nothing until the certificate is inside the renewal
# window.
#
# The unit points at the stage script in the repository. That is a real
# dependency — move or delete the repo and the timer fails — and it is chosen
# over copying the library into /usr/local so there is exactly one copy of this
# logic on the host. The failure is not silent: the unit goes into a failed
# state, and both status.sh and doctor.sh report the certificate's remaining
# days, so a broken timer surfaces 30 days before it can cause an outage.
us_tls_install_renew_timer() {
  # rewritten counts units whose content actually changed; us_write_if_changed
  # returns 0 for "wrote it" and 1 for "already identical".
  local stage="$1" rewritten=0 rc=0

  us_have systemctl || {
    us_warn "systemd not available; skipping the renewal timer."
    us_warn "Renew by hand before the certificate expires:  sudo ${stage}"
    return 0
  }

  us_write_if_changed "/etc/systemd/system/${US_TLS_RENEW_UNIT}.service" 0644 <<EOF || rc=$?
# Managed by ${US_PROJECT_NAME}. Renews the local TLS certificate.
[Unit]
Description=Renew the ${US_PROJECT_NAME} local TLS certificate
Documentation=file://${US_ROOT_DIR}/docs/https.md
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
# Serialised against install.sh through the same lock file, so a renewal that
# fires mid-install waits rather than racing it for Runtipi's state.
ExecStart=/usr/bin/flock -w 900 ${US_LOCK_FILE} /bin/bash ${stage}
EOF
  if ((rc == 0)); then rewritten=$((rewritten + 1)); fi

  rc=0
  us_write_if_changed "/etc/systemd/system/${US_TLS_RENEW_UNIT}.timer" 0644 <<EOF || rc=$?
# Managed by ${US_PROJECT_NAME}.
[Unit]
Description=Daily check of the ${US_PROJECT_NAME} local TLS certificate

[Timer]
OnCalendar=daily
# Spread the work off the stroke of midnight; nothing here is time-critical.
RandomizedDelaySec=1h
# Catch up after downtime rather than skipping a missed window.
Persistent=true

[Install]
WantedBy=timers.target
EOF
  if ((rc == 0)); then rewritten=$((rewritten + 1)); fi

  if ((rewritten > 0)); then
    us_run systemctl daemon-reload
  fi
  us_run systemctl enable --now "${US_TLS_RENEW_UNIT}.timer" >/dev/null 2>&1 ||
    us_warn "Could not enable ${US_TLS_RENEW_UNIT}.timer; renew by hand or investigate with: systemctl status ${US_TLS_RENEW_UNIT}.timer"
}

us_tls_remove_renew_timer() {
  us_have systemctl || return 0
  us_run systemctl disable --now "${US_TLS_RENEW_UNIT}.timer" >/dev/null 2>&1 || true
  us_run rm -f -- "/etc/systemd/system/${US_TLS_RENEW_UNIT}.timer" \
    "/etc/systemd/system/${US_TLS_RENEW_UNIT}.service"
  us_run systemctl daemon-reload || true
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

# us_tls_served_issuer <ip> <servername> - the issuer Traefik actually presents.
# Asks the socket rather than reading a file, because the file being right and
# the proxy having loaded it are different claims and only the second one is
# what a browser sees.
us_tls_served_issuer() {
  local ip="$1" name="$2"
  us_have openssl || return 1
  # Wrapped in timeout(1): s_client has no connect deadline of its own and will
  # sit there if 443 is filtered rather than closed. status.sh and doctor.sh
  # call this, and a diagnostic that hangs is worse than one that says nothing.
  timeout 8 openssl s_client -connect "${ip}:443" -servername "$name" </dev/null 2>/dev/null |
    openssl x509 -noout -issuer 2>/dev/null | cut -d= -f2-
}

# us_tls_https_trusted <ip> <name> - does an untrusting client accept the
# served certificate for this name? Uses the host trust store, which contains
# the CA once us_tls_trust_on_host has run, so this is the same check a LAN
# client performs after installing the CA.
us_tls_https_trusted() {
  local ip="$1" name="$2"
  curl -fsS --max-time 10 -o /dev/null \
    --resolve "${name}:443:${ip}" "https://${name}/" 2>/dev/null
}
