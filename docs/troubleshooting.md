# Troubleshooting

Start here:

```bash
./status.sh      # what is wrong
./doctor.sh      # why
```

`doctor.sh` accepts a section filter: `--dns`, `--traefik`, `--docker`,
`--runtipi`, `--nomad`, `--versions`, `--ports`, `--drift`, `--logs`.

Installation logs are in `/var/log/u-server/`, one file per stage.

---

## Installation

### A stage failed partway through

Resume from it — stages are idempotent, so nothing is duplicated:

```bash
sudo ./install.sh --from 40-adguard
```

Or run the single stage directly:

```bash
sudo scripts/40-adguard.sh
```

### "Port 80/tcp is in use"

Something else is serving HTTP. Find it:

```bash
sudo ss -lntp | grep ':80'
```

Common culprits: Apache, nginx, another reverse proxy. Stop and disable it —
Traefik must own 80 and 443.

### "LAN_IP is not assigned to any interface"

`LAN_IP` in `server.env` does not match this machine. Check:

```bash
ip -4 -o addr show scope global
```

Set the correct address, or leave `LAN_IP` blank for auto-detection.

### "Another u-server operation is already running"

A previous run died holding the lock, or one is genuinely running.

```bash
ls -l /var/lib/u-server/install.lock
sudo fuser -v /var/lib/u-server/install.lock   # is anything holding it?
```

If nothing holds it, the lock is released automatically when the process
exits; a stale file alone is harmless.

### "Docker Desktop detected"

u-server needs Docker Engine running directly on the host. Docker Desktop keeps
its engine in a VM behind its own socket, so Runtipi's containers cannot bind
the host's ports 53/80/443 — which is the whole point of this platform.

Preflight names what it found. Confirm it yourself:

```bash
ls -d /opt/docker-desktop /usr/bin/docker-desktop 2>/dev/null; docker context ls
```

If Docker Desktop really is installed, remove it and rerun:

```bash
sudo apt-get remove docker-desktop && docker context use default
```

If it is *not* installed and only a `desktop-linux` context is listed, that is a
leftover from an uninstall. Preflight only warns about it, but clear it anyway:

```bash
docker context rm desktop-linux
```

### The installer says my Ubuntu version is unverified

22.04, 24.04 and 26.04 are verified. Others may work but Docker may not
publish an apt suite for them. Check
[docs.docker.com/engine/install/ubuntu](https://docs.docker.com/engine/install/ubuntu/).

---

## DNS

### `*.home.arpa` doesn't resolve from a client

Test the server directly first:

```bash
dig @192.168.8.10 anything.home.arpa +short
```

**Returns the server IP** → DNS works; the client is the problem. Its DHCP
lease still carries an old resolver. Renew the lease or reconnect. Verify with
`nslookup nomad.home.arpa` — check *which server* answered.

**Returns nothing** → AdGuard is not answering. See below.

### Names work sometimes, fail other times

Almost always a secondary public DNS server on the router:

```
Primary   192.168.8.10
Secondary 8.8.8.8        ← remove this
```

Clients treat resolvers as interchangeable, not ordered. Queries that reach
`8.8.8.8` get an authoritative NXDOMAIN for `home.arpa`, and some clients
cache it. Configure **only** the server's address. Full explanation in
[dns.md](dns.md).

### AdGuard won't start — port 53 in use

```bash
sudo ss -lnup | grep ':53'
```

If `systemd-resolved` holds it, the stub listener was not disabled. Check:

```bash
cat /etc/systemd/resolved.conf.d/60-u-server.conf   # expect DNSStubListener=no
sudo systemctl restart systemd-resolved
```

If something else holds it (dnsmasq, bind9, Pi-hole), stop and disable it —
the installer deliberately refuses to remove other DNS servers for you.

### The server itself can't resolve anything

```bash
cat /etc/resolv.conf
resolvectl status
```

Recover immediately:

```bash
sudo rm /etc/systemd/resolved.conf.d/60-u-server.conf
sudo systemctl restart systemd-resolved
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
```

Then rerun `sudo scripts/50-local-dns.sh`. That stage verifies resolution
after repointing and reverts itself if it broke — this path should be rare.

### `.local` names don't work

Expected. `.local` is mDNS (RFC 6762), not unicast DNS. Use `home.arpa`.

---

## Routing

### A name resolves but the browser shows 404

DNS is fine; Traefik has no matching route. Inspect its live routers:

```bash
./doctor.sh --traefik
```

Check whether the app is running and exposed locally:

```bash
./status.sh
```

If the app is running but has no local route, it was installed without
`exposedLocal`. Fix it in the dashboard: app → settings → enable the local
domain and set the subdomain.

### Connection refused / no response

Traefik is not running:

```bash
docker ps | grep reverse-proxy
docker logs runtipi-reverse-proxy
```

### `server.home.arpa` doesn't work

Expected — there is no such hostname. The Runtipi dashboard lives at the bare
local domain:

```
http://home.arpa
```

That is what Runtipi's own Traefik router binds, and `LOCAL_DOMAIN` is a
single value driving both the dashboard hostname and the app suffix, so a
`server.` name cannot be substituted for it (it would move every app to
`nomad.server.home.arpa`).

An early revision published `server.home.arpa` as an extra route; it was
removed. If you installed that version, `scripts/30-runtipi-config.sh` deletes
the leftover file on the next run.

### `home.arpa` itself doesn't resolve, but subdomains do

The apex rewrite is missing. DNS wildcards do not cover the apex, so it is a
separate entry:

```bash
dig @192.168.8.10 home.arpa +short        # should return the server IP
sudo scripts/50-local-dns.sh              # recreates both rewrites
```

### An app is reachable by IP:port but not by name

It was installed with `openPort: true` and no local domain. That publishes the
port to the LAN, which is usually not what you want — prefer the Traefik
route.

---

## Applications

### App stuck "installing"

Image pulls can be slow. Watch progress:

```bash
docker logs -f runtipi
```

Project NOMAD's first boot waits on MySQL initialisation and can take several
minutes.

### App store won't register

Runtipi needs an **HTTPS** git URL with `apps/` at the repository root.
`file://` and local paths do not work.

```bash
./tools/publish-appstore.sh        # publish the branch
git ls-remote --heads <origin> appstore   # confirm it exists
sudo ./install.sh --stage 60-appstore
```

### I changed an app definition and nothing happened

Runtipi caches its clone of the store. Publish, then re-pull:

```bash
./tools/validate-appstore.sh
./tools/publish-appstore.sh
sudo ./update.sh appstore
```

Also bump `tipi_version` in `config.json` — Runtipi uses it to detect changes.

---

## Project NOMAD

### Child services fail to start

Usually the hardcoded network is missing:

```bash
docker network inspect project-nomad_default
```

If absent, NOMAD cannot attach children. Reinstall the app so Compose recreates
it. Do **not** create it by hand — Compose refuses to adopt a network without
its labels.

### Child services start but their data is empty / in the wrong place

The storage contract is broken. Check:

```bash
./doctor.sh --nomad
docker inspect nomad_admin --format '{{json .Mounts}}'
```

`/app/storage` must be a **bind** with a real host `Source`. If it is a
volume, or the container is not named `nomad_admin`, NOMAD cannot resolve host
paths for child mounts. See [project-nomad.md](project-nomad.md).

### NOMAD says an update is available

Ignore it inside NOMAD. Runtipi owns the core stack here, and NOMAD's
self-updater is deliberately not installed. Update from the host:

```bash
./update.sh --check
sudo ./update.sh nomad
```

### `resolve-versions.sh` says a release has no image

Real, and worth knowing: a GitHub release does not guarantee a published
container image, and sidecars move on their own version lines. The tool falls
back to the newest tag that actually exists in the registry.

---

## Recovery

### Start over without losing data

```bash
sudo ./uninstall.sh          # keeps application data
sudo ./install.sh
```

### Configuration drift

```bash
./doctor.sh --drift          # compares server.env to the installed config
sudo ./install.sh            # converges
```

### Back up before a risky change

```bash
sudo tar czf ~/u-server-backup-$(date +%F).tar.gz \
  /etc/u-server /var/lib/u-server /opt/runtipi/.internal/state
```

Application data lives under Runtipi's app-data directory; include it if you
want a full restore.

### Everything is broken and I need the machine back

```bash
sudo ./uninstall.sh --purge-data --yes
```

This stops the platform, restores the host resolver, and removes u-server's
files. Docker Engine is left installed, and non-Runtipi containers are
untouched.
