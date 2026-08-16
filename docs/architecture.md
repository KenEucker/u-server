# Architecture

This document records what was verified upstream, what was decided as a
result, and why. Every claim about Runtipi, AdGuard or Docker below was read
from source or from official documentation, not from memory. File references
point at the code that establishes each fact.

Verified 2026-08 against Runtipi `v4.10.1`.

---

## 1. The separation that everything else follows from

```
Host infrastructure          Applications
-------------------          ------------
Docker Engine                ...anything you install
Runtipi                         from Runtipi's app store
Traefik
AdGuard Home (as an app)
DNS + routing policy
```

The host layer knows how to *run and reach* containers. It knows nothing about
what any particular container does.

Consequently there is **no application-specific logic in any installer stage**.
The installer ships no applications and registers no app store of its own; the
one app it installs, AdGuard, comes from the store Runtipi ships with and is
installed through the same generic API call any other app would use. Anything
else is installed from the dashboard afterwards and gets a working hostname,
DNS entry and TLS-ready route purely by existing.

---

## 2. Upstream findings that shaped the design

### 2.1 The Runtipi CLI ships from the platform repository

`runtipi/cli` holds the CLI's Go source, but its releases lag badly — it was
at `v4.2.1` while the platform was at `v4.10.1`. The actual binaries are
published as assets on **`runtipi/runtipi`** releases:

```
runtipi-cli-linux-x86_64.tar.gz
runtipi-cli-linux-aarch64.tar.gz
```

Confirmed from `scripts/install.sh` in `runtipi/runtipi` and from the releases
API, and independently corroborated by the CLI's own update command, which
fetches from `api.github.com/repos/runtipi/runtipi/releases/latest`
(`internal/commands/update.go`).

**Decision:** `lib/versions.sh` resolves against `runtipi/runtipi`. Resolving
against `runtipi/cli` would have installed a CLI several minor versions behind
the platform it manages.

Upstream publishes no checksum asset alongside these binaries, so there is no
published digest to verify. We record the SHA-256 of what we actually
installed in the manifest instead, which gives the future offline bundler
something to pin and makes later tampering detectable. Transport integrity is
TLS.

### 2.2 The dashboard binds the bare local domain

From `docker-compose.prod.yml`:

```yaml
traefik.http.routers.dashboard-local.rule: Host(`${LOCAL_DOMAIN}`)
```

while apps get (`traefik-labels.builder.ts:55`):

```
Host(`<localSubdomain>.${LOCAL_DOMAIN}`)
```

So `LOCAL_DOMAIN` is a **single knob driving two different things**: the
dashboard's hostname and the suffix every app hangs off. With
`LOCAL_DOMAIN=home.arpa`:

```
http://home.arpa         dashboard
http://dns.home.arpa     AdGuard Home
```

**Decision: use the apex as the dashboard address.** It is what upstream
binds, and the apex is genuinely claimable — `scripts/50-local-dns.sh` creates
an explicit `home.arpa → LAN_IP` rewrite alongside the wildcard, because
standard DNS wildcards do not cover the apex (RFC 4592) and resolvers differ
on how they treat wildcard *rewrites*. Setting both explicitly costs one line
and removes a class of confusing failure.

Upstream evidently intends this: Runtipi's TLS generation issues a certificate
covering both names (`app.service.ts:237`):

```
subjectAltName = `DNS:*.${localDomain},DNS:${localDomain}`
```

#### A `server.` hostname was built, then removed

An earlier revision also published the dashboard at `server.home.arpa`, since
the original brief specified that name. Because `LOCAL_DOMAIN` is one knob,
that name could only be *added*, never substituted — setting
`LOCAL_DOMAIN=server.home.arpa` would have moved every app to
`<app>.server.home.arpa`. So it was implemented as an extra Traefik router
through the file provider Runtipi already watches, forwarding to
`dashboard@docker`.

It worked, and it was still deleted: it bought a second name for something
already reachable at the apex, at the cost of a generated file, a config
variable, and a section of documentation explaining the compromise. The
capability remains available — see the note in `lib/runtipi.sh` and git
history — if a route Runtipi cannot express is ever genuinely needed.

`scripts/30-runtipi-config.sh` removes the file on hosts that received the
earlier version, so an upgrade converges rather than leaving a stale route.

### 2.3 App-store compose accepts arbitrary Docker keys

The app-store schema (`packages/common/src/schemas/compose-yaml.ts`) defines
services as:

```ts
const serviceObject = type({
  image: 'string',
  networks: ...optional(),
  ports: ...optional(),
  labels: ...optional(),
  'x-runtipi': xRuntipiService.optional(),
  '[string]': 'unknown',          // <- catch-all
});
```

The catch-all means `container_name`, `volumes`, `environment`, `depends_on`
and `healthcheck` pass through to the generated compose file, and a top-level
`networks:` block is preserved (`compose.builder.ts` merges its own entries
into whatever is already there).

**Why this matters:** an app with hard requirements — a specific container
name, a specific network name — can be packaged as a normal app definition.
No user-config override, no patched Runtipi.

(There is a *second*, camelCase schema, `dynamic-compose-ark.ts`, with
`schemaVersion: 2` and a `services` array. That one is for apps created
through the UI's custom-app builder and does **not** apply to app-store
packages. Confusing the two produces packages Runtipi rejects.)

### 2.4 The CLI cannot install apps; the API can

`runtipi app` supports start, stop, uninstall, reset, backup, restore, update,
start-all and stop-all — but **not install** (`internal/commands/app.go`).
Installing requires form values, `exposedLocal` and `localSubdomain`, which
only the HTTP API accepts.

The CLI authenticates by minting an HS256 JWT with subject `cli` from
`JWT_SECRET` in Runtipi's `.env` (`internal/utils/api.go`). `lib/runtipi.sh`
reproduces exactly that (`us_runtipi_jwt`) and posts to
`POST /api/app-lifecycle/<urn>/install`.

**Decision:** use the same authenticated local API the CLI uses, rather than
driving a browser or shipping a patched CLI. This is what makes a single
`sudo ./install.sh` able to land AdGuard on `dns.home.arpa` unattended.

### 2.5 App stores must be HTTPS git with `apps/` at the root

`app-store-files-manager.ts` resolves apps at
`path.join(dataDir, 'repos', slug, 'apps')`, and `repos.helpers.ts` clones
with `isomorphic-git` over an HTTP client — so `file://` and local paths do
not work. A branch can be selected with a `/tree/<branch>` suffix
(`getRepoBaseUrlAndBranch`).

**Decision:** register no app store of our own. The installer uses the official
store Runtipi ships with, which is the one AdGuard comes from. A store of your
own is a separate repository with `apps/` at its root, added from the
dashboard — not something this installer publishes or manages.

---

## 3. DNS model

```
AdGuard:  hostname → server IP        one wildcard, set once
Traefik:  hostname → container        per app, generated automatically
```

Two rewrites are configured, not one:

| Rewrite | Covers |
|---|---|
| `*.home.arpa → LAN_IP` | every service hostname |
| `home.arpa → LAN_IP` | the apex, which a wildcard does not match, and which the dashboard binds |

AdGuard matches rewrites *before* forwarding upstream, which is what makes the
platform offline-tolerant: with the WAN unplugged, `home.arpa` still resolves
and only Internet names fail.

The port-53 bootstrap is handled in two phases specifically to avoid a
circular dependency — see [dns.md](dns.md).

---

## 4. Networking and isolation

| Network | Purpose |
|---|---|
| `runtipi_tipi_main_network` | Traefik ↔ each app's main service |
| `<app>_<store>_network` | private, per-app, for multi-service apps |

Only a service marked `is_main` joins the Traefik network, so an app's
database is reachable by its own app and nothing else. Unrelated applications
cannot reach each other. Application ports are not published to the LAN;
Traefik is the entry point.

---

## 5. Idempotency

Rerunning `install.sh` converges. The mechanisms:

- `us_write_if_changed` compares before writing, backs up on change, and
  returns "unchanged" so callers can avoid needless restarts. Tested.
- `us_secret_get_or_create` never regenerates an existing secret.
- Version policy `stable` reuses the recorded version once installed, so a
  rerun is not an upgrade.
- App installs check `us_runtipi_app_installed` first.
- Docker's apt repo is written in the current deb822 format, and the legacy
  `docker.list` is removed to prevent duplicate-source warnings.
- `settings.json` is *merged*, preserving keys set by hand.
- A `flock` guard prevents two concurrent runs racing.

What it will not do: regenerate secrets, recreate databases, delete app data,
remove unrelated containers, or upgrade a healthy component.

---

## 6. Deliberate non-goals for this phase

- **No offline bundle.** Designed for, not built. See
  [future-offline-design.md](future-offline-design.md).
- **No Runtipi fork.** Upstream unmodified; every integration point used is a
  supported one.
- **No HTTPS by default.** `ENABLE_LOCAL_HTTPS=false` keeps milestone 1 simple.
  Runtipi already generates a certificate covering `*.home.arpa` and
  `home.arpa`, so enabling it later is a settings change plus distributing the
  local CA to clients. Public ACME is never used for `home.arpa` — it is not
  delegable and the challenge cannot succeed.
- **No firewall changes by default.** `MANAGE_FIREWALL=false`. Reconfiguring a
  firewall on a remote machine is how people lose SSH access.
- **No applications bundled.** The installer builds the platform and installs
  AdGuard, because DNS is part of the platform. Everything else is yours to
  install from the dashboard.
