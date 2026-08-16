# Project NOMAD

Project NOMAD is an offline-first knowledge server. On this platform it is
**one application among others** — installed from the app store, routed by
Traefik, named by the same wildcard DNS as everything else.

It is not the parent of this server, and it does not manage unrelated
services. It manages its own child services; the host manages it.

Verified against `Crosstalk-Solutions/project-nomad` v1.34.0 (2026-08).

## Security: read this before installing

The package mounts the host Docker socket:

```
/var/run/docker.sock
```

**This grants NOMAD root-equivalent control of this host.** Anything that can
reach the Docker API can start privileged containers, mount any host path, and
read or write any file on the system.

This is not incidental — it is how NOMAD works. The Command Center creates,
starts, stops and removes the child containers for the content services you
install from within it. Remove the socket and the UI runs but can install
nothing.

The disk-collector sidecar additionally mounts the host root filesystem
read-only at `/host` to report storage capacity.

The installer prints this warning before granting access
(`scripts/70-project-nomad.sh`), and the app description repeats it in the
dashboard. Unrelated applications remain isolated on their own Docker networks
and are not reachable from NOMAD's.

## Ownership boundary

Two systems must not fight over the same containers.

| Owner | Responsible for |
|---|---|
| **Runtipi** | NOMAD's core stack — `admin`, `mysql`, `redis`, `disk-collector`. Start, stop, restart, version, backups. |
| **NOMAD** | Everything NOMAD installs — child content containers, their data, their lifecycle. |

To make that boundary real, the package **omits upstream's `updater`
sidecar**. That sidecar runs:

```bash
docker compose -p "$COMPOSE_PROJECT_NAME" -f /opt/project-nomad/compose.yml \
    pull / stop / rm / up -d
```

Under Runtipi that compose file does not exist, and even if it did, having two
systems recreate the same containers is a reliability problem, not a feature.

**Consequence:** update NOMAD's core from Runtipi (`sudo ./update.sh nomad`),
not from inside NOMAD. Content and child services are still managed entirely
from NOMAD's own UI — that half is untouched.

`dozzle` is also omitted: a convenience log viewer wanting a second Docker
socket mount, for something Runtipi already provides.

A regression test asserts the updater does not creep back in.

## Three upstream contracts

Full source references are at the top of `lib/nomad.sh`.

### 1. The child network name is hardcoded

```ts
// admin/app/services/docker_service.ts:34
public static NOMAD_NETWORK = 'project-nomad_default'
```

applied when NOMAD creates a container:

```ts
NetworkingConfig: { EndpointsConfig: { [DockerService.NOMAD_NETWORK]: {} } }
```

That name arises naturally from `docker compose` only when the project is
literally called `project-nomad`. Under Runtipi the project is
`<app>_<store>`, so the package forces the literal name:

```yaml
networks:
  nomad-internal:
    name: project-nomad_default
```

Without it, every child service NOMAD created would fail to attach to a
network that does not exist.

Do **not** pre-create this network by hand: Compose must create it, or it will
refuse to adopt a network lacking its labels.

### 2. Storage is resolved by self-inspection

`_resolveHostStorageRoot()` inspects the container named `nomad_admin`, finds
the bind mount whose destination is `/app/storage`, and uses that bind's
**host-side source** as the root for every child container's bind mounts.

This is what prevents the classic failure: a path that is valid inside the
NOMAD container and meaningless to the host Docker daemon that actually
creates the child containers.

Two requirements follow, both asserted by tests:

- `container_name: nomad_admin` is pinned.
- `/app/storage` is a **bind mount**, never a named volume — a named volume
  has no host path to hand to children.

Runtipi sets `APP_DATA_DIR` to a host path
(`<appDataPath>/app-data/<store>/<app>`), so:

```yaml
volumes:
  - ${APP_DATA_DIR}/data/storage:/app/storage
```

satisfies it. A pleasant consequence: relocate Runtipi's app-data directory
and every NOMAD child service follows automatically.

`NOMAD_STORAGE_PATH` is set to the same host path but is only a fallback for
when inspection fails.

### 3. Image version lines are independent

Project NOMAD release `v1.34.0` has a matching container image — but two traps
sit here:

- `ghcr.io`'s `tags/list` returns **100 tags by default** and this repository
  has 102, so a naive query silently hides the newest releases.
  `tools/resolve-versions.sh` pages with `?n=1000`.
- `project-nomad-disk-collector` is on a **completely separate version line**
  (newest `v1.31.1`). Pinning it to the NOMAD release version would reference
  an image that does not exist.

Each image is therefore resolved independently and verified to exist in the
registry before being written into the package.

## Installation

```bash
sudo ./install.sh                       # includes NOMAD if INSTALL_PROJECT_NOMAD=true
sudo scripts/70-project-nomad.sh        # or just this stage
```

The stage installs with `openPort: false` — NOMAD's HTTP port is **not**
published to the LAN. Traefik reaches it over the Docker network and serves it
at `nomad.home.arpa`.

First boot is slow: MySQL initialises before the admin container can become
healthy. The installer waits up to 15 minutes.

## Verification

`us_nomad_verify` (run by the install stage, `status.sh` and `doctor.sh`) checks:

| Check | Failure means |
|---|---|
| `nomad_admin` healthy | Core stack is not running |
| `nomad_mysql` healthy | Database unavailable; admin cannot start |
| `project-nomad_default` exists | NOMAD cannot create child services |
| Docker socket present in container | NOMAD cannot manage anything |
| `/app/storage` is a bind with a real host source | Child bind mounts would be invalid |
| UI answers `/api/health` | App-level failure |

## Child-service orchestration

The installer does **not** provision a child service automatically. NOMAD's
catalogue includes AI models, map datasets and ZIM archives that are tens of
gigabytes; an unattended installer must not start those downloads.

To verify child orchestration manually:

1. Open `http://nomad.home.arpa`.
2. Install a small, static service — **CyberChef** or **FlatNotes** are web
   apps with no large content download.
3. Confirm the container attached to NOMAD's network:

```bash
docker network inspect project-nomad_default
./doctor.sh --nomad
```

The new container should be listed alongside `nomad_admin`. That proves
Contracts 1 and 2 hold end to end: NOMAD created a container, attached it to
its network, and gave it host paths that exist.

## Updating

```bash
./update.sh --check       # installed vs app-definition vs upstream
sudo ./update.sh nomad
```

The update recreates the core containers via Runtipi (with a backup first).
Content and child services are unaffected — they live in NOMAD's storage and
on its own network.

To move to a newer upstream release, update the definition first:

```bash
./tools/resolve-versions.sh          # report
./tools/resolve-versions.sh --write  # apply
./tools/validate-appstore.sh
git commit -am "NOMAD vX.Y.Z" && ./tools/publish-appstore.sh
sudo ./update.sh nomad               # on each server, when you choose
```

A newer upstream release never changes a running server on its own.

## Data

```
<runtipi-app-data>/u-server/project-nomad/data/
├── storage/     NOMAD content, and the root child services bind into
├── mysql/       database
└── redis/       cache
```

`sudo ./uninstall.sh` preserves this. `--purge-data` deletes it irreversibly.
