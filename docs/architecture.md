# Architecture

This document records what was verified upstream, what was decided as a
result, and why. Every claim about Runtipi, Project NOMAD, AdGuard or Docker
below was read from source or from official documentation, not from memory.
File references point at the code that establishes each fact.

Verified 2026-08 against Runtipi `v4.10.1` and Project NOMAD `v1.34.0`.

---

## 1. The separation that everything else follows from

```
Host infrastructure          Applications
-------------------          ------------
Docker Engine                Project NOMAD
Runtipi                      Meridian
Traefik                      whoami
AdGuard Home (as an app)     ...anything else
DNS + routing policy
```

The host layer knows how to *run and reach* containers. It knows nothing about
what any particular container does. The test for whether this holds is the
`whoami` app: it is three lines of YAML, references nothing project-specific,
and gets a working hostname, DNS entry and TLS-ready route purely by existing.

Consequently there is **no NOMAD-specific or Meridian-specific logic in any
installer stage**. `scripts/70-project-nomad.sh` exists only to surface
NOMAD's elevated permissions before granting them and to verify two upstream
contracts; the installation itself is the same generic API call the `whoami`
app uses.

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
http://nomad.home.arpa   Project NOMAD
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
`nomad.server.home.arpa`. So it was implemented as an extra Traefik router
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

**Why this matters:** it means Project NOMAD's two hard requirements — a
specific container name and a specific network name — can be met inside a
normal app definition. No user-config override, no patched Runtipi.

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
`sudo ./install.sh` able to land NOMAD on `nomad.home.arpa` unattended.

### 2.5 App stores must be HTTPS git with `apps/` at the root

`app-store-files-manager.ts` resolves apps at
`path.join(dataDir, 'repos', slug, 'apps')`, and `repos.helpers.ts` clones
with `isomorphic-git` over an HTTP client — so `file://` and local paths do
not work. A branch can be selected with a `/tree/<branch>` suffix
(`getRepoBaseUrlAndBranch`).

**Decision:** keep definitions in `appstore/apps/` next to the installer that
deploys them, and publish them to a dedicated `appstore` branch where `apps/`
is the root (`tools/publish-appstore.sh`). One repository, both shapes.

---

## 3. Project NOMAD: three contracts

Recorded in full, with source references, at the top of `lib/nomad.sh`.

### Contract 1 — the child network name is hardcoded

```ts
public static NOMAD_NETWORK = 'project-nomad_default'   // docker_service.ts:34
```

applied when NOMAD creates containers:

```ts
NetworkingConfig: { EndpointsConfig: { [DockerService.NOMAD_NETWORK]: {} } }
```

That name only arises naturally when the compose project is literally called
`project-nomad`. Under Runtipi the project is `<app>_<store>`, so the package
declares the name explicitly:

```yaml
networks:
  nomad-internal:
    name: project-nomad_default
```

Without this, every child service NOMAD tried to create would fail to attach.

A drift check (`us_nomad_check_network_contract`) re-reads the upstream
constant and warns if it moves. It is advisory: a network hiccup must not
block an install.

### Contract 2 — storage is resolved by self-inspection

`_resolveHostStorageRoot()` inspects the container named `nomad_admin`, finds
the bind whose destination is `/app/storage`, and uses that bind's **host-side
source** as the root for child containers' bind mounts.

This is the mechanism that avoids the classic failure the brief warns about —
a path that is valid inside the container and meaningless to the host Docker
daemon. Two requirements follow, and both are asserted in `tests/test-lib.sh`:

- `container_name: nomad_admin` must be pinned.
- `/app/storage` must be a **bind**, not a named volume, so `Source` is a real
  host path.

Runtipi sets `APP_DATA_DIR` to a host path
(`<appDataPath>/app-data/<store>/<app>`, `app.helpers.ts:55`), so binding
`${APP_DATA_DIR}/data/storage:/app/storage` satisfies this. Relocating
Runtipi's app-data directory relocates child services automatically.

`NOMAD_STORAGE_PATH` is set to the same host path, but it is only the fallback
used when inspection fails.

### Contract 3 — the self-updater is omitted

`install/sidecar-updater/update-watcher.sh` runs:

```bash
docker compose -p "$COMPOSE_PROJECT_NAME" -f /opt/project-nomad/compose.yml \
    pull / stop / rm / up -d
```

Under Runtipi that compose file does not exist, and even if it did, two
systems would own the same containers.

**Ownership boundary:**

| Owner | Responsible for |
|---|---|
| Runtipi | NOMAD's core stack: admin, MySQL, Redis, disk-collector — lifecycle, version, backups |
| NOMAD | Everything NOMAD installs: child content containers and their data |

The `dozzle` log viewer is also omitted: it wants a second Docker socket mount
for functionality Runtipi already provides.

A regression test asserts the updater stays out of the package.

### A version-line trap worth recording

Project NOMAD release `v1.34.0` **does** have a matching container image — but
`ghcr.io`'s `tags/list` returns 100 tags by default and the repository has
102, so a naive query hides recent releases. Meanwhile
`project-nomad-disk-collector` is on an entirely independent version line
(newest `v1.31.1`) and must not be pinned to the NOMAD release version.

`tools/resolve-versions.sh` therefore pages with `?n=1000` and resolves each
image independently, verifying a tag exists in the registry before writing it.

---

## 4. DNS model

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

## 5. Networking and isolation

| Network | Purpose |
|---|---|
| `runtipi_tipi_main_network` | Traefik ↔ each app's main service |
| `<app>_<store>_network` | private, per-app, for multi-service apps |
| `project-nomad_default` | NOMAD admin ↔ its child services |

Only a service marked `is_main` joins the Traefik network, so an app's
database is reachable by its own app and nothing else. Unrelated applications
cannot reach each other. Application ports are not published to the LAN;
Traefik is the entry point.

---

## 6. Idempotency

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

## 7. Deliberate non-goals for this phase

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
- **No Meridian guess.** See the scaffold's description for what is needed.
