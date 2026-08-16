# Runtipi

Runtipi is the application-management layer: it installs apps, supervises
their containers, generates Traefik routing, and provides the dashboard. This
project uses it **unmodified**.

Verified against `runtipi/runtipi` v4.10.1 (2026-08).

## What u-server does around it

| Concern | Handled by |
|---|---|
| Installing the CLI at an exact resolved version | `scripts/20-runtipi.sh` |
| Local domain, dashboard alias | `scripts/30-runtipi-config.sh` |
| Registering the custom app store | `scripts/60-appstore.sh` |
| All upstream-specific knowledge | `lib/runtipi.sh` (only this file) |

If upstream renames an asset, moves its data directory, or changes an API
route, `lib/runtipi.sh` is the only file that should need editing.

## Installation

Not `curl https://setup.runtipi.io | bash`. That script is fine at a terminal,
but it resolves "latest" itself, installs Docker with its own logic, and
leaves no record of what it chose. Instead:

1. Resolve the version policy to an exact tag (`lib/versions.sh`).
2. Look up the release asset by name, failing loudly if it is absent.
3. Download over TLS, record the SHA-256 of the artifact.
4. Extract and install the CLI.
5. `runtipi-cli start`.
6. Record the resolved version in the manifest.

### Release assets

The CLI binaries are published on **`runtipi/runtipi`** releases, *not*
`runtipi/cli`:

```
runtipi-cli-linux-x86_64.tar.gz
runtipi-cli-linux-aarch64.tar.gz
```

`runtipi/cli` carries the Go source but its own releases lag — `v4.2.1` while
the platform was `v4.10.1`. Resolving against it would install a CLI several
minor versions behind the platform it manages. The CLI's own `update` command
confirms this by fetching from `repos/runtipi/runtipi/releases/latest`.

If upstream renames these assets, `us_gh_asset_url` fails with the list of
assets that *do* exist, rather than guessing a URL and producing a confusing
404 later.

### Checksums

Upstream publishes no checksum asset alongside the CLI binaries. There is
therefore no published digest to verify against. We record the SHA-256 of what
we installed in the manifest, which gives the future offline bundler a value
to pin and makes later tampering detectable. Transport integrity is TLS.

## The dashboard hostname compromise

**This is the one place the architecture bends, so it is documented in full.**

Runtipi's dashboard router binds the **bare** local domain
(`docker-compose.prod.yml`):

```yaml
traefik.http.routers.dashboard-local.rule: Host(`${LOCAL_DOMAIN}`)
```

Apps bind a subdomain of it (`traefik-labels.builder.ts:55`):

```
Host(`<localSubdomain>.${LOCAL_DOMAIN}`)
```

With `LOCAL_DOMAIN=home.arpa` you natively get:

```
http://home.arpa         dashboard
http://nomad.home.arpa   Project NOMAD
```

but not `http://server.home.arpa`.

### What was rejected

| Approach | Why not |
|---|---|
| `LOCAL_DOMAIN=server.home.arpa` | Fixes the dashboard, breaks every app: they become `nomad.server.home.arpa`. Trading the common case for the rare one. |
| Edit the generated `dynamic.yml` | Runtipi rewrites it at boot (`app.service.ts:118-121`). Edits vanish, and it means fighting Runtipi for a file it owns. |
| Patch/fork Runtipi | Explicitly out of scope, and disproportionate to a hostname alias. |

### What was chosen

Keep `LOCAL_DOMAIN=home.arpa`, and add one extra router through the file
provider Runtipi's Traefik *already* watches:

```yaml
# /opt/runtipi/.internal/traefik/dynamic/u-server-dashboard.yml
http:
  routers:
    u-server-dashboard-alias:
      rule: "Host(`server.home.arpa`)"
      entryPoints: [web]
      service: "dashboard@docker"
```

This is legitimate because:

- `traefik.yml` configures a file provider on `/etc/traefik/dynamic` with
  `watch: true`.
- Runtipi writes **only** `dynamic.yml` into that directory and never prunes
  others, so a differently-named file is an extension point, not a conflict.
- The router points at `dashboard@docker` — the service Runtipi's own labels
  define — so it aliases rather than duplicates configuration. If Runtipi
  changes the dashboard's port or middleware, the alias follows automatically.
- Traefik's file provider hot-reloads, so no restart is needed.

**Result:** the dashboard answers on both names. `home.arpa` keeps working;
`server.home.arpa` is added.

The generator emits `websecure` + `tls` variants when `ENABLE_LOCAL_HTTPS=true`,
so this does not become a blocker later.

## Configuration surface

Runtipi's settings live at `<data>/state/settings.json` and are parsed with
`settingsSchema.partial()` (`env-helpers.ts:47`) — a **partial** schema, so
writing only the keys we care about is supported, not a hack.

`us_runtipi_settings_merge` merges with `jq` rather than overwriting, so
settings changed by hand in the dashboard survive an installer rerun.

Keys u-server sets:

| Key | Value |
|---|---|
| `localDomain` | `LOCAL_DOMAIN` |
| `listenIp`, `internalIp` | `LAN_IP` |

Changing `localDomain` requires a Runtipi restart, because the value is baked
into container labels when app compose files are generated. The stage detects
this and restarts only when the value actually changed.

## Driving the API

The CLI has no `install` command (`internal/commands/app.go` — start, stop,
uninstall, reset, backup, restore, update, start-all, stop-all only).
Installing an app requires form values, `exposedLocal` and `localSubdomain`,
which only the HTTP API accepts.

The CLI authenticates by minting an HS256 JWT with subject `cli` from
`JWT_SECRET` in Runtipi's `.env` (`internal/utils/api.go`). `us_runtipi_jwt`
reproduces that, so u-server uses the same supported local API:

```
POST /api/app-lifecycle/<urn>/install
{ "exposedLocal": true, "localSubdomain": "nomad", "openPort": false }
```

App identity is a URN: `<appName>:<appStoreSlug>`, e.g.
`project-nomad:u-server`.

`openPort: false` is deliberate for apps that should be reachable only through
Traefik — nothing is published to the LAN.

## App stores

Runtipi resolves apps at `<data>/repos/<slug>/apps`
(`app-store-files-manager.ts:29`) and clones with `isomorphic-git` over HTTP,
so:

- the URL must be **HTTPS** (`file://` and local paths will not work)
- `apps/` must be at the repository **root**
- a branch is selected with a `/tree/<branch>` suffix
  (`repos.helpers.ts:37-47`)

u-server keeps definitions in `appstore/apps/` beside the installer and
publishes them to an `appstore` branch where `apps/` is the root:

```bash
./tools/publish-appstore.sh
# registers as: https://github.com/<owner>/<repo>/tree/appstore
```

## App package format

Two files per app, plus metadata:

```
appstore/apps/<id>/
├── config.json              metadata, ports, form fields
├── docker-compose.yml       services + x-runtipi extensions
└── metadata/description.md  shown in the dashboard
```

`config.json` must have `id` equal to the directory name. `docker-compose.yml`
is normal Compose plus `x-runtipi`:

```yaml
services:
  app:
    image: example/app:v1.2.3      # always an immutable tag
    volumes:
      - ${APP_DATA_DIR}/data:/data # APP_DATA_DIR is a HOST path
    x-runtipi:
      is_main: true                # exactly one service
      internal_port: 8080          # what Traefik routes to
x-runtipi:
  schema_version: 2
```

Because the service schema has a catch-all (`'[string]': 'unknown'`), ordinary
Compose keys — `container_name`, `environment`, `depends_on`, `healthcheck` —
pass through, and a top-level `networks:` block is preserved.

> Do not confuse this with the camelCase `dynamic-compose-ark.ts` schema
> (`schemaVersion: 2`, `services` as an array). That one is for apps built
> through the UI's custom-app builder, not for app-store packages.

Validate before publishing:

```bash
./tools/validate-appstore.sh
```

This catches unpinned images, missing or duplicate `is_main`, missing
`internal_port`, id/directory mismatches, host-port collisions, and
undocumented socket or privileged usage. It also runs in CI.
