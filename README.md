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
http://server.home.arpa     Runtipi dashboard
http://dns.home.arpa        AdGuard Home
http://nomad.home.arpa      Project NOMAD
http://whoami.home.arpa     routing test
```

## What this is

A **platform**. It installs the infrastructure that containerised applications
need — an engine to run them, a manager to install and supervise them, a proxy
to route to them, and DNS so their names resolve — and then treats every
application as an ordinary workload on top of it.

## What this is not

- **Not a Project NOMAD appliance.** NOMAD is one app installed from an app
  store. Nothing in the installer is shaped around it.
- **Not a Meridian appliance.** Meridian is a second app, shipped here as an
  honest scaffold because its upstream could not be identified. See
  [`appstore/apps/meridian/metadata/description.md`](appstore/apps/meridian/metadata/description.md).
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
 server.home.arpa  dns.home.arpa  nomad.home.arpa  whoami.home.arpa
      │              │                │                  │
   Runtipi        AdGuard         NOMAD core         any container
   dashboard                          │
                                      │ project-nomad_default
                                      ▼
                                NOMAD child apps
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
| `LAN_IP` | The address every `*.home.arpa` name resolves to. Must be static. Auto-detected if blank. |
| `LOCAL_DOMAIN` | `home.arpa` (RFC 8375). Do **not** use `.local` — that is mDNS. |
| `RUNTIPI_VERSION` / `NOMAD_VERSION` | `stable`, or an exact tag like `v4.10.1` |
| `INSTALL_ADGUARD` / `INSTALL_PROJECT_NOMAD` / `INSTALL_WHOAMI` | Which workloads to install |
| `ENABLE_LOCAL_HTTPS` | `false` for milestone 1; HTTP on the LAN |
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

Nothing is pinned permanently to today's releases: `./tools/resolve-versions.sh`
re-resolves app definitions against upstream, verifying that a published
release actually has a matching container image before writing it.

## Custom app store

App definitions live in [`appstore/apps/`](appstore/apps/). Runtipi requires
app stores to be HTTPS git repositories with `apps/` at the **root**, so
`tools/publish-appstore.sh` publishes that directory to a dedicated `appstore`
branch, which Runtipi consumes via its `/tree/<branch>` URL suffix.

```
./tools/validate-appstore.sh     # lint definitions (also runs in CI)
./tools/publish-appstore.sh      # publish to the appstore branch
```

## Adding an application

1. Create `appstore/apps/<id>/config.json` and `docker-compose.yml`. Copy
   [`whoami`](appstore/apps/whoami/) — it is deliberately minimal.
2. Mark the web service `x-runtipi: { is_main: true, internal_port: N }`.
3. Put persistent data under `${APP_DATA_DIR}/data/...` (a **host** path).
4. `./tools/validate-appstore.sh && ./tools/publish-appstore.sh`
5. Install it from the Runtipi dashboard, setting the local subdomain.

No DNS work, no Traefik config, no installer changes.

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

- **Project NOMAD mounts the Docker socket.** That is root-equivalent control
  of the host, and it is how NOMAD manages its own child services. The
  installer prints this warning before granting it, and the app description
  repeats it. Unrelated apps stay isolated on their own Docker networks.
- Application ports are **not** published to the LAN; Traefik is the entry
  point. NOMAD's HTTP port in particular is reachable only through the proxy.
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
| [docs/dns.md](docs/dns.md) | `home.arpa`, wildcards, the port-53 bootstrap, router setup |
| [docs/runtipi.md](docs/runtipi.md) | How Runtipi is used, and the dashboard-hostname compromise |
| [docs/project-nomad.md](docs/project-nomad.md) | NOMAD integration, ownership boundary, storage contract |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptom-first fault guide |
| [docs/future-offline-design.md](docs/future-offline-design.md) | Air-gap design and known Internet dependencies |

## Requirements

- Ubuntu Server 22.04, 24.04 or 26.04 LTS, amd64
- 4 GB RAM, 10 GB free disk (Project NOMAD content wants far more)
- A static LAN address
- **No KVM required.** Docker Engine on Linux does not use hardware
  virtualisation; preflight reports its absence as information, not an error.
  Older hardware such as a Lenovo ThinkCentre M73 Tiny is a supported target.
