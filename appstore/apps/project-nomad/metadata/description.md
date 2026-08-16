# Project NOMAD

An offline-first knowledge and education server. Wikipedia, books, courses,
maps and optional local AI, served from hardware you own, with no Internet
connection required after content is downloaded.

NOMAD presents a "Command Center" web UI from which you install and manage its
own catalogue of content services (Kiwix, Kolibri, ProtoMaps, Ollama, Qdrant,
CyberChef, FlatNotes and others).

## Elevated permissions — read before installing

This application mounts the host Docker socket:

    /var/run/docker.sock

**This grants the NOMAD container root-equivalent control of this host.** A
process that can reach the Docker API can start privileged containers, mount
any host path, and read or modify any file on the system.

This is not incidental — it is how NOMAD works. The Command Center creates,
starts, stops and removes the child containers for the content services you
install from within NOMAD. Removing the socket mount would leave the UI
functional but unable to install or manage anything.

It also mounts the host root filesystem read-only at `/host` (via the
disk-collector sidecar) to report storage capacity in the UI.

Install this only if you are comfortable with that level of trust. Unrelated
applications on this server remain isolated on their own Docker networks and
are not reachable from NOMAD's network.

## Who owns what

This package deliberately splits responsibility:

| Owner   | Responsible for                                                        |
|---------|------------------------------------------------------------------------|
| Runtipi | The NOMAD core stack: admin, MySQL, Redis, disk-collector. Start, stop, restart, update, backup. |
| NOMAD   | Everything NOMAD itself installs: child content containers and their data. |

Upstream's `updater` sidecar — which would recreate NOMAD's own containers by
running `docker compose up -d` against a compose file this deployment does not
have — is **not included**. Update the core stack from Runtipi instead.
Content and child services continue to be managed from within NOMAD's own UI.

## Storage

Application data lives under this app's Runtipi data directory:

    <app-data>/project-nomad/data/storage

NOMAD discovers that host path by inspecting its own container's
`/app/storage` mount, and rewrites child container bind mounts onto it. That
is why this package pins the container name `nomad_admin` and uses a bind
mount rather than a named volume.

If you relocate Runtipi's app-data directory, child services follow
automatically — no reconfiguration needed.

## First run

MySQL initialises on first start, so the Command Center may take a couple of
minutes to become reachable. Content downloads (map tiles, ZIM archives, AI
models) are started from within NOMAD and can be very large; none of them are
downloaded automatically at install time.
