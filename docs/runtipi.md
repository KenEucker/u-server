# Runtipi

Runtipi is the application-management layer: it installs apps, supervises
their containers, generates Traefik routing, and provides the dashboard. This
project uses it **unmodified**.

Verified against `runtipi/runtipi` v4.10.1 (2026-08).

## What u-server does around it

| Concern | Handled by |
|---|---|
| Installing the CLI at an exact resolved version | `scripts/20-runtipi.sh` |
| Local domain configuration | `scripts/30-runtipi-config.sh` |
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

## The dashboard hostname

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
http://dns.home.arpa     AdGuard Home
```

The dashboard is therefore at the **apex**, and there is no setting to change
that independently: `LOCAL_DOMAIN` is one value feeding both rules, so any
`server.`-style name can be *added* alongside the apex but never substituted
for it. Setting `LOCAL_DOMAIN=server.home.arpa` would move every app to
`<app>.server.home.arpa`.

### The apex is properly claimed

Not a fallback — it is claimed deliberately on both layers:

- **DNS.** `scripts/50-local-dns.sh` creates two rewrites: `*.home.arpa` and
  `home.arpa`. Standard DNS wildcards do not cover the apex (RFC 4592), and
  resolvers differ on how they treat wildcard *rewrites*, so the apex is set
  explicitly rather than assumed.
- **Traefik.** Runtipi's own `dashboard-local` router already binds it.

Upstream clearly intends the apex to be used — Runtipi's TLS generation issues
a certificate covering both forms (`app.service.ts:237`):

```
subjectAltName = `DNS:*.${localDomain},DNS:${localDomain}`
```

so enabling `ENABLE_LOCAL_HTTPS` later covers `https://home.arpa` with no
extra work.

### A second hostname was built, then removed

The original brief asked for the dashboard at `server.home.arpa`, and that was
implemented: an extra router written into the Traefik file provider directory
Runtipi already watches (`/etc/traefik/dynamic`, `watch: true`), forwarding to
`dashboard@docker`. That is a legitimate extension point — Runtipi writes only
`dynamic.yml` there and never prunes other files — and it worked.

It was removed anyway. It bought a second name for something already reachable
at the apex, and charged a generated file, a config variable, a validation
branch and a documentation section for it. The alternatives were worse
(`LOCAL_DOMAIN=server.home.arpa` breaks every app; editing `dynamic.yml` loses
the edit at boot; forking Runtipi is out of scope), but "the best of several
poor options" is not the same as "worth doing".

`scripts/30-runtipi-config.sh` deletes the leftover file on hosts that got the
earlier version, so upgrading converges instead of leaving a stale route.

If a genuinely inexpressible route is ever needed, the mechanism is documented
in `lib/runtipi.sh` and the helper is recoverable from git history.

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
{ "exposedLocal": true, "localSubdomain": "dns", "openPort": false }
```

App identity is a URN: `<appName>:<appStoreSlug>`, e.g. `adguard:migrated`.

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

u-server registers **no** app store of its own. AdGuard comes from the official
store Runtipi ships with. To use your own definitions, add a store from the
dashboard pointing at a repository that satisfies the three rules above.

## App package format

If you do build your own store, two files per app, plus metadata:

```
apps/<id>/
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

Worth checking before you publish such a store: unpinned images, missing or
duplicate `is_main`, missing `internal_port`, id/directory mismatches, and
host-port collisions. Runtipi rejects a malformed app at install time, deep
inside a container, with a message that is hard to trace back.
