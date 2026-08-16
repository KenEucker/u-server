# Future offline design

**Nothing here is implemented.** This phase deliberately proves the
architecture online. The purpose of this document is to make sure today's
online installer does not quietly create obstacles for tomorrow's air-gapped
one — and to record the Internet dependencies discovered while building it,
while they are still fresh.

---

## Known Internet dependencies

Everything below was hit during implementation. Each is a thing the bundle
must carry or the installer must be able to skip.

### Installation time

| # | Dependency | Used by | Notes |
|---|---|---|---|
| 1 | Ubuntu archive (apt) | `00-preflight` | `ca-certificates curl jq tar gnupg openssl dnsutils iproute2` |
| 2 | `download.docker.com` apt repo + GPG key | `10-docker` | `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` |
| 3 | `api.github.com` releases API | `lib/versions.sh` | Resolving `stable` → exact tag, and asset lookup |
| 4 | `github.com` release asset | `20-runtipi` | `runtipi-cli-linux-<arch>.tar.gz` |
| 5 | Docker Hub | Runtipi core | `traefik`, `postgres:14`, `rabbitmq:4-alpine` |
| 6 | `ghcr.io` | Runtipi core | `ghcr.io/runtipi/runtipi` |
| 7 | `github.com` git clone (HTTPS) | `60-appstore` | The u-server app store branch, cloned by isomorphic-git |
| 8 | `github.com` git clone (HTTPS) | Runtipi bootstrap | Official `runtipi-appstore`, needed for the AdGuard app |
| 9 | Docker Hub | apps | `adguard/adguardhome`, `mysql:8.0`, `redis:7-alpine`, `traefik/whoami` |
| 10 | `ghcr.io` | Project NOMAD | `project-nomad`, `project-nomad-disk-collector` |
| 11 | `raw.githubusercontent.com` | `lib/nomad.sh` | Contract drift check — **already advisory**, fails soft |

### Runtime (after installation)

| Dependency | Impact when absent |
|---|---|
| AdGuard upstream resolvers | Internet name resolution fails. `*.home.arpa` is **unaffected** — rewrites are matched before forwarding. |
| NOMAD content downloads | User-initiated from NOMAD's UI; not an installer concern. |
| Runtipi update checks | Cosmetic "update available" indicator only. |

**The platform itself has no runtime Internet dependency.** Verified by
design: DNS, Traefik routing, Docker and every installed app keep working with
the WAN unplugged.

---

## Decisions already taken that help

These were made during this phase specifically to keep the offline path open.

### Resolution is separate from download

`lib/versions.sh` resolves versions and asset URLs; it performs no downloads
and no installation. A bundle builder can source it on an Internet-connected
machine, resolve exactly what an offline install would resolve, and enumerate
the payload — reusing the logic rather than reimplementing it.

### Everything is pinned to immutable tags

`tools/validate-appstore.sh` **fails CI** on any image without an explicit tag,
and on `:latest`. Mutable tags would make a bundle unreproducible: what you
saved and what a later install expects could differ silently.

### `pull_policy: always` was removed

Upstream's NOMAD compose sets `pull_policy: always` on three services. That
forces a registry round-trip on every start and would break an air-gapped node
even when the image is already loaded locally. The Runtipi package omits it.
**Any future app definition must do the same** — this is now a house rule.

### The image list already exists

`tools/list-required-images.sh` enumerates every image the platform needs,
from Runtipi's core compose plus every available app definition:

```bash
./tools/list-required-images.sh            # plain list, for docker save
./tools/list-required-images.sh --json     # with sources
./tools/list-required-images.sh --digests  # immutable digests
```

This is the seam `docker save` will consume. Keeping it accurate now means the
bundler is a new consumer, not a rewrite.

### The manifest records what was actually installed

`/var/lib/u-server/installed-manifest.json` holds resolved versions, the
artifact SHA-256, architecture and Ubuntu release. A bundle can be built to
match a known-good node exactly, and an offline install can be verified
against it.

### Stages are independently runnable and idempotent

An offline installer can reuse the same stages, substituting a local package
source. Nothing assumes stages run in one uninterrupted pass.

### Upstream is not forked

Runtipi runs unmodified. An offline variant will need to solve image loading
and app-store availability, but it starts from stock upstream rather than a
patch set that has to be rebased forever.

---

## Sketch of the bundle builder

Not built. This is the shape it should take.

```bash
./tools/build-offline-bundle.sh \
    --app project-nomad \
    --app whoami \
    --output ./u-server-bundle
```

1. Resolve versions with the **existing** `lib/versions.sh`.
2. Download `.deb` packages for Docker and prerequisites
   (`apt-get download` over a resolved dependency set, or `apt-offline`).
3. Download the resolved Runtipi CLI asset.
4. `docker pull` + `docker save` every image from
   `tools/list-required-images.sh --digests`.
5. Snapshot the u-server app store **and** the official Runtipi app store
   (needed for AdGuard) as plain directories.
6. Emit checksums and a manifest mirroring `installed-manifest.json`.

```
u-server-bundle/
├── manifest.json           resolved versions, digests, checksums
├── debs/                   docker-ce, containerd.io, prerequisites
├── cli/                    runtipi-cli-linux-x86_64.tar.gz
├── images/                 *.tar from docker save
├── appstores/
│   ├── u-server/           apps/ ...
│   └── runtipi/            apps/ ...
└── checksums.sha256
```

Then:

```bash
sudo ./install.sh --offline /media/usb/u-server-bundle
```

`--offline` would set a flag that makes each stage prefer bundle sources:
a local apt source, a local CLI archive, `docker load` instead of pull, and a
local app-store path.

---

## Problems that still need solving

Honest list. These are known-unknowns, not oversights.

### 1. App stores must be git over HTTPS

The hard one. `repos.helpers.ts` clones with `isomorphic-git` over an HTTP
client — `file://` will not work. Options, in rough order of preference:

- **Serve the snapshot from localhost over HTTP.** A tiny static git HTTP
  server (or `git http-backend`) on the appliance itself. Keeps Runtipi stock.
- Pre-seed `<data>/repos/<slug>/` directly and never trigger a pull. Works
  until something calls pull, then fails.
- Patch Runtipi to accept a local path. Rejected for now — forking is
  explicitly out of scope this phase.

This needs a decision before the offline phase starts.

### 2. Runtipi's own image pulls

`runtipi-cli start` brings up its compose project. With images pre-loaded via
`docker load` this should be satisfied locally, but Compose's pull behaviour
under a stock CLI needs verification on a genuinely disconnected machine
before being relied on.

### 3. The official app store is needed for AdGuard

AdGuard is intentionally consumed from upstream rather than forked. An offline
bundle must therefore snapshot the official store too — or vendor an AdGuard
definition into the u-server store, accepting the maintenance cost. Snapshot
first; vendor only if it proves painful.

### 4. apt dependency resolution

Docker's packages pull in transitive dependencies that vary by Ubuntu point
release. The bundle must be built on the **same** Ubuntu release as the
target, and the manifest already records `ubuntu` and `ubuntu_codename` so
this can be checked and refused with a clear message.

### 5. Time and TLS

A long-disconnected appliance can drift enough for certificate validation to
fail. Not a problem while everything is local, but relevant if the node is
ever reconnected to update.

---

## Rules for keeping this achievable

For anyone adding to this repository before the offline phase:

1. **Never use a mutable tag.** CI enforces it.
2. **Never add `pull_policy: always`.**
3. **Put new network fetches behind `lib/`**, so the offline variant has one
   place to intercept.
4. **Keep resolution separate from download.**
5. **Add new images to the app definitions**, not to ad-hoc `docker run`
   commands, so `list-required-images.sh` keeps seeing them.
6. **Update the dependency table above** when a new one appears.
