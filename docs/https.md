# HTTPS

Verified against `runtipi/runtipi` v4.10.1 (2026-08).

## The thing to understand first

**HTTPS is already on, and HTTP already redirects to it.** That is true of a
stock install, with `ENABLE_LOCAL_HTTPS=false`, before this project does
anything at all.

Runtipi gives every locally-exposed app two routers and a redirect
(`traefik-labels.builder.ts`):

```
routers.<app>-<store>-local-insecure.entrypoints  web
routers.<app>-<store>-local-insecure.middlewares  <app>-<store>-web-redirect
middlewares.<app>-<store>-web-redirect.redirectscheme.scheme  https

routers.<app>-<store>-local.entrypoints           websecure
routers.<app>-<store>-local.tls                   true
```

The dashboard is labelled the same way (`docker-compose.prod.yml`):

```yaml
traefik.http.routers.dashboard-local-insecure.middlewares: redirect-to-https
traefik.http.routers.dashboard-local.tls: true
```

So `http://home.arpa` is a 301 to `https://home.arpa`, and always was.

What is missing on a stock install is not encryption. It is a certificate
anyone trusts. Note that the local routers set `tls: true` with **no**
`certresolver` — unlike the internet-exposure routers, which use
`certresolver: myresolver`. A `tls: true` router with no resolver serves
Traefik's **default certificate**, which Runtipi's shipped `dynamic.yml` points
at two files:

```yaml
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/traefik/tls/cert.pem
        keyFile: /etc/traefik/tls/key.pem
```

and then fills with a self-signed pair covering
`DNS:*.<localDomain>,DNS:<localDomain>` (`app.service.ts`). That certificate is
cryptographically fine and signed by nobody, which is exactly what a browser
warns about.

`ENABLE_LOCAL_HTTPS=true` replaces the contents of those two files. It is a
substitution into a slot upstream already reserves — not a patch, not a fork,
and not a second TLS mechanism running alongside Runtipi's.

## Why not Let's Encrypt

Because `home.arpa` cannot be certified by any public CA, and no configuration
changes that.

ACME proves you control a name. Both challenges require the name to exist in
the public DNS hierarchy:

| Challenge | Needs |
|---|---|
| HTTP-01 | Let's Encrypt to reach `http://<name>/.well-known/acme-challenge/…` from the Internet |
| DNS-01 | a TXT record at `_acme-challenge.<name>` in a publicly delegated zone |

[RFC 8375](https://www.rfc-editor.org/rfc/rfc8375) reserves `home.arpa`
specifically so that it is **not** delegable — there is no registrar, no
authoritative nameserver you can point at, and no way to prove control of it to
anybody. Let's Encrypt will refuse the order outright. This is not a limitation
of this installer.

### What Let's Encrypt would actually require

Giving up `home.arpa`. If you own a public domain, you can set
`LOCAL_DOMAIN=lan.example.com`, obtain a wildcard for `*.lan.example.com` by
DNS-01 (the only challenge that works without exposing this host to the
Internet), and let AdGuard answer those names with your LAN address —
split-horizon DNS. Nothing needs to be port-forwarded.

The costs are real and worth stating plainly:

- Every app moves from `<app>.home.arpa` to `<app>.lan.example.com`. Runtipi
  has one `localDomain`; you cannot serve both.
- Renewal needs a DNS provider API credential on this host, and needs the WAN.
  A long WAN outage eventually costs you HTTPS, whereas a local CA does not
  care. That runs against [future-offline-design.md](future-offline-design.md).
- Your internal hostnames appear in Certificate Transparency logs, publicly and
  permanently. `*.lan.example.com` leaks little; per-app names leak your
  service inventory.

This project does not implement that path. If you want it, the mechanism is the
same one described below — the certificate slot does not care who issued what
you put in it.

## What `ENABLE_LOCAL_HTTPS=true` does

`scripts/60-tls.sh`, driven by `lib/tls.sh`:

1. **Creates a CA, once.** `/etc/u-server/ca/ca.key` (0600) and `ca.crt`,
   valid ten years, `CA:TRUE, pathlen:0`. Never regenerated on rerun — the
   same rule as generated secrets, and for a stronger reason: rotating it
   silently invalidates every device you configured by hand.
2. **Issues a server certificate**, valid 397 days, covering
   `DNS:<domain>`, `DNS:*.<domain>` and `IP:<LAN_IP>`. The apex is listed
   explicitly because `*.home.arpa` does not match `home.arpa` — in DNS
   ([RFC 4592](https://www.rfc-editor.org/rfc/rfc4592)) or in TLS — and the
   apex is where the dashboard lives.
3. **Installs it** into `<data>/traefik/tls/{cert,key}.pem` and restarts the
   proxy.
4. **Trusts the CA on this host**, so `curl` and the diagnostics stop needing
   `-k`.
5. **Installs a daily systemd timer** that reissues before expiry.

Everything is idempotent, and the timer re-runs the same stage, so there is one
code path rather than an install path and a renewal path that drift apart.

### The marker file

Runtipi regenerates its self-signed certificate on startup **unless** all of
these hold (`app.service.ts`, `generateTlsCertificates`):

```
<tls>/<localDomain>.txt   exists
<tls>/cert.pem            exists
<tls>/key.pem             exists
openssl x509 -checkend 86400 -in cert.pem   says "will not expire"
```

The stage writes that marker. Delete it and Runtipi overwrites your certificate
on its next restart, silently — the only symptom is that the warnings come
back. `./doctor.sh --tls` reports whether it is present.

The `-checkend 86400` clause is why renewal runs at **30 days** remaining
rather than at the last minute. Let the certificate get within 24 hours of
expiry and Runtipi does not merely let it expire, it replaces it.

## Installing the CA on your devices

This is the manual step, and it is the price of the whole approach. The
installer prints these instructions and the fingerprint at the end of the
stage. Copy the CA off the server:

```bash
scp you@192.168.8.10:/etc/u-server/ca/ca.crt u-server-local-ca.crt
```

| Platform | How |
|---|---|
| macOS | Open it, add to the login keychain, then **double-click it → Trust → "Always Trust"**. Adding it is not enough on its own. |
| iOS / iPadOS | AirDrop or mail it, install the profile, then enable it under Settings → General → About → **Certificate Trust Settings**. Two separate steps. |
| Windows | `certutil -addstore -f Root u-server-local-ca.crt` in an admin prompt |
| Linux | Copy to `/usr/local/share/ca-certificates/`, then `sudo update-ca-certificates` |
| Android | Settings → Security → Encryption & credentials → Install a certificate → **CA certificate** |
| Firefox | Keeps its own store regardless of the OS: Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import |

Check the SHA-256 the device shows against the one the installer printed:

```bash
openssl x509 -noout -fingerprint -sha256 -in /etc/u-server/ca/ca.crt
```

### What you are agreeing to

A CA your device trusts can vouch for **any** name, not just `home.arpa`. If
`/etc/u-server/ca/ca.key` is stolen, whoever holds it can impersonate any site
to every device you installed this on, for as long as it stays installed.

That is the deal a local CA makes, and it is why this is opt-in. Practical
consequences:

- Keep the key on the server. There is no reason to copy `ca.key` anywhere;
  only `ca.crt` ever leaves the machine.
- Do not install this CA on a device you do not control, or on a work machine
  whose policy forbids it.
- `pathlen:0` means the CA can sign server certificates and nothing else — it
  cannot mint further CAs. That bounds the damage; it does not eliminate it.

## Operating it

```bash
./status.sh                     reports days remaining and whether it verifies
./doctor.sh --tls               slot contents, chain, served issuer, timer state
sudo scripts/60-tls.sh          force a check now (idempotent)
systemctl status u-server-tls-renew.timer
```

### Renewal

A daily timer runs `scripts/60-tls.sh`, which does nothing until the
certificate is within 30 days of expiry. It is serialised against `install.sh`
through the same lock file, so a renewal that fires mid-install waits rather
than racing it.

The unit points at the stage script **in this repository**. Move or delete the
repo and renewal stops working. That is a deliberate trade — one copy of the
logic on the host rather than two that can drift — and it is not silent: the
unit enters a failed state, and both `status.sh` and `doctor.sh` report days
remaining, so it surfaces roughly 30 days before it could cause an outage.

### Changing LAN_IP or LOCAL_DOMAIN

Both are baked into the certificate. The stage compares the certificate's
actual names against the wanted ones on every run and reissues when they
differ, so `sudo ./install.sh` after an address change is sufficient. Devices
do **not** need the CA reinstalled — it is unchanged; only the certificate it
signed was replaced.

### Turning it off

Setting `ENABLE_LOCAL_HTTPS=false` stops the stage doing anything; it does not
revert. The existing certificate keeps working until it expires. To genuinely
go back to Runtipi's self-signed certificate:

```bash
sudo rm /opt/runtipi/.internal/traefik/tls/home.arpa.txt
sudo docker restart runtipi
```

Remove the CA from your devices' trust stores as well — a trusted CA whose key
still exists on a machine you have stopped thinking about is exactly the thing
you do not want.

### Replacing a compromised CA

There is no revocation here; nothing checks a CRL or OCSP for a local CA. The
only real remedy is to remove it from every device.

```bash
sudo rm -rf /etc/u-server/ca
sudo ./install.sh --stage 60-tls
```

That mints a new CA and a new certificate. Every device must then be visited
twice: once to remove the old CA, once to install the new one. Budget for that
before choosing this over living with browser warnings.
