# u-server

Turn a clean Ubuntu Server into a general-purpose, LAN-local application host:
Docker Engine, Runtipi for application management, Traefik for routing, and
AdGuard Home answering `*.home.arpa`, so every service gets a real hostname
without editing `/etc/hosts` on a single client.

```
git clone <this-repository>
cd u-server

cp config/server.env.example server.env
nano server.env

sudo ./install.sh
```

Afterwards, from any LAN client using this server for DNS:

```
https://home.arpa           Runtipi dashboard
https://dns.home.arpa       AdGuard Home
```

Those are `https` because Traefik redirects `http` to it — that is Runtipi's
own routing, not a setting. Out of the box the certificate is self-signed, so
browsers warn; `ENABLE_LOCAL_HTTPS=true` replaces it with one your devices can
be told to trust. See [docs/https.md](docs/https.md).

Every application you install from Runtipi's app store gets its own
`<name>.home.arpa` on the same basis, with no further DNS work.

## What this is

A **platform**. It installs the infrastructure that containerised applications
need — an engine to run them, a manager to install and supervise them, a proxy
to route to them, and DNS so their names resolve — and then treats every
application as an ordinary workload on top of it.

## What this is not

- **Not an appliance for any particular application.** This installer ships no
  applications of its own and registers no app store of its own. Apps are
  installed from Runtipi's dashboard after the platform is up, and nothing in
  the installer is shaped around any of them.
- **Not an offline installer — yet.** This phase proves the architecture
  online. The design keeps the air-gapped path open; see
  [docs/future-offline-design.md](docs/future-offline-design.md).
- **Not a Runtipi fork.** Upstream is used unmodified.

## Architecture

```
                        LAN clients
                             │
                             │ DNS (router advertises this server)
                             ▼
                       AdGuard Home
                             │
                  *.home.arpa ──► 192.168.8.10
                             │
                             ▼
                          Traefik                    (Runtipi-managed)
                             │
      ┌──────────────┬───────┴────────┬──────────────────┐
      ▼              ▼                ▼                  ▼
   home.arpa     dns.home.arpa   app.home.arpa    other.home.arpa
      │              │                │                  │
   Runtipi        AdGuard        any container      any container
   dashboard
```

The division of labour is the important part, and it is what makes adding a
service cheap:

| Layer | Answers | Changes when you add an app? |
|---|---|---|
| AdGuard | hostname → **server IP** | No — one wildcard covers everything |
| Traefik | hostname → **container** | Automatically, from the app's registration |

Because `*.home.arpa` already resolves to this machine, a new web app needs a
Docker container and a registration. It never needs a DNS record.

## Host layout

| Path | Contents |
|---|---|
| `/opt/runtipi` | Runtipi CLI, state, app data (configurable via `RUNTIPI_ROOT`) |
| `/etc/u-server/config.env` | Effective configuration, copied at install |
| `/etc/u-server/secrets.env` | Generated secrets, `0600`, never in git |
| `/var/lib/u-server/installed-manifest.json` | What is actually installed |
| `/var/log/u-server/` | Per-stage installation logs |

## Configuration

Everything lives in `server.env` (from `config/server.env.example`). The
values you are most likely to change:

| Setting | Meaning |
|---|---|
| `LAN_IP` | The address every `*.home.arpa` name resolves to. Must not change — reserve it on your router or run `tools/set-static-ip.sh`. Auto-detected if blank. |
| `LAN_IP_IS_RESERVED` | Set true if `LAN_IP` is DHCP-assigned but reserved on your router. Preflight cannot detect a reservation, so this is you asserting it. See [docs/networking.md](docs/networking.md). |
| `LOCAL_DOMAIN` | `home.arpa` (RFC 8375). Do **not** use `.local` — that is mDNS. |
| `RUNTIPI_VERSION` | `stable`, or an exact tag like `v4.10.1` |
| `INSTALL_ADGUARD` | Whether to install AdGuard Home and the wildcard DNS it serves |
| `ENABLE_LOCAL_HTTPS` | Replace Runtipi's self-signed certificate with one from a local CA this installer creates. HTTPS itself is always on either way. |
| `MANAGE_FIREWALL` | `false` by default — this installer will not risk locking you out of SSH |

## Version resolution

The project separates three ideas that are easy to conflate:

```
desired policy      what server.env asks for      "stable"
resolved version    the exact tag chosen          v4.10.1
installed version   what is running on this node  v4.10.1
```

`stable` is resolved **once**, at first install, and recorded in the manifest.
Rerunning `install.sh` reuses the recorded version — it will not silently
upgrade a running server because upstream shipped something new that morning.

Upgrades are always deliberate:

```
./update.sh --check        # installed vs available, changes nothing
sudo ./update.sh runtipi   # upgrade, with before/after recorded
```

## Adding an application

1. Open the Runtipi dashboard at `http://home.arpa` and install the app from
   the app store Runtipi ships with.
2. Set its **local subdomain** during install — that is the `<name>` in
   `<name>.home.arpa`.

No DNS work, no Traefik config, no installer changes.

This installer registers no app store of its own. To serve your own app
definitions, point Runtipi at a store repository with `apps/` at its **root**
(Runtipi clones stores over HTTPS and reads apps from the repository root).

## Router setup — the one manual step

Set your router's DHCP **DNS server** for LAN clients to this machine's IP:

```
DNS server: 192.168.8.10
```

Set **only** that address. Do not add a public resolver as a secondary —
clients treat resolvers as interchangeable rather than ordered, so some
queries would go to a resolver that has never heard of `home.arpa`, and
service names would work intermittently. AdGuard already forwards
non-`home.arpa` queries upstream. Details in [docs/dns.md](docs/dns.md).

## Operating it

```
./status.sh              concise health: host, DNS, apps, routes
./doctor.sh              deep diagnostics: ports, networks, Traefik routers, drift
./update.sh --check      what upgrades are available
sudo ./install.sh        re-run any time; converges, never destroys
sudo ./uninstall.sh      remove the platform (keeps app data unless --purge-data)
```

Individual stages are independently runnable for debugging:

```
sudo scripts/20-runtipi.sh
sudo ./install.sh --from 40-adguard
sudo ./install.sh --dry-run
```

## Security

The platform aims to keep sharp edges visible rather than hidden.

- **Apps that mount the Docker socket hold root-equivalent control of the
  host.** Runtipi shows what an app requests before you install it; treat that
  mount as the privileged decision it is. Unrelated apps stay isolated on their
  own Docker networks.
- Application ports are **not** published to the LAN; Traefik is the entry
  point.
- **Every service is served over TLS and HTTP redirects to it**, by Runtipi's
  own routing. The default certificate is self-signed, so browsers warn — the
  encryption is real, the identity is unverified. `ENABLE_LOCAL_HTTPS=true`
  creates a local CA and issues a certificate for `*.home.arpa` from it; you
  then install that CA on each device once. A CA your devices trust can vouch
  for any name, so read [docs/https.md](docs/https.md) before enabling it.
  Let's Encrypt cannot issue for `home.arpa` — it is not delegable, so no ACME
  challenge can succeed.
- Secrets are generated at install into `/etc/u-server/secrets.env` (`0600`)
  and never regenerated on rerun. CI fails if credential-like files are
  tracked.
- The firewall is not modified unless you opt in with `MANAGE_FIREWALL=true`.
- AdGuard installs with no admin password. Set one before exposing the LAN to
  untrusted devices — `status.sh` and the installer both say so.

## Offline behaviour

Once installed, losing the WAN does not affect the platform. `home.arpa` names
are answered by a local rewrite that is matched *before* any upstream
forwarding, so DNS, routing, Docker, and every installed app keep working.
Only Internet name resolution degrades.

Installing *new* things still requires the Internet in this phase. See
[docs/future-offline-design.md](docs/future-offline-design.md).

## Documentation

| Document | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Design decisions and the upstream facts behind them |
| [docs/networking.md](docs/networking.md) | Host addressing, DHCP reservations vs. static IP, the WiFi caveat |
| [docs/dns.md](docs/dns.md) | `home.arpa`, wildcards, the port-53 bootstrap, router setup |
| [docs/runtipi.md](docs/runtipi.md) | How Runtipi is used, and the dashboard-hostname compromise |
| [docs/https.md](docs/https.md) | Why HTTPS is already on, why Let's Encrypt cannot work here, and the local CA |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptom-first fault guide |
| [docs/future-offline-design.md](docs/future-offline-design.md) | Air-gap design and known Internet dependencies |

## Requirements

- Ubuntu Server 22.04, 24.04 or 26.04 LTS, amd64
- 4 GB RAM, 10 GB free disk (content-heavy apps want far more)
- A static LAN address
- **No KVM required.** Docker Engine on Linux does not use hardware
  virtualisation; preflight reports its absence as information, not an error.
  Older hardware such as a Lenovo ThinkCentre M73 Tiny is a supported target.
