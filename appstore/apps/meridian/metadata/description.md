# Meridian — scaffold, not a working package

**This package is deliberately marked `"available": false` and will not
install.** It is a placeholder with the correct shape, not a guess at
Meridian's deployment.

## Why it is a scaffold

The brief asked for a Meridian package *if* its current deployment
requirements are discoverable, and a clearly marked scaffold otherwise.

They were not discoverable. "Meridian" is the name of many unrelated
projects — a news-brief AI aggregator, a marketing-mix modelling framework
from Google, an MMORPG, a Swift web server, a VLESS proxy deployer, an Emby
proxy panel, a CRDT sync engine, and more. None could be confirmed as the
intended application, and none matched the PHP/PostgreSQL/composer.json shape
the project brief described.

Inventing a `docker-compose.yml` here would have produced a package that looks
authoritative, installs, and is wrong. That is worse than an obvious gap.

## What to fill in

Once you point me at the actual repository, this becomes a normal package.
Determine from upstream — not from assumption:

| Question | Where to look |
|---|---|
| Which images, and what exact tags? | published registry, CI workflows |
| What internal HTTP port does the web service listen on? | Dockerfile `EXPOSE`, framework config |
| Which services are required? (db, cache, queue, workers) | upstream `compose.yaml` / `docker-compose.yml` |
| What environment variables are mandatory? | `.env.example` |
| Does it need a writable data directory? | volume mounts in upstream compose |
| Does it need migrations run on first boot or upgrade? | deployment docs, entrypoint script |
| Does it require elevated permissions? | any socket/privileged/device usage |

Then:

1. Write `docker-compose.yml` following the pattern in
   `appstore/apps/whoami/` (simple) or `appstore/apps/project-nomad/`
   (multi-service with dependencies and health checks).
2. Mark the main service with `x-runtipi: { is_main: true, internal_port: N }`.
3. Put persistent data under `${APP_DATA_DIR}/data/...` — that variable is a
   **host** path, which is what Docker needs for bind mounts.
4. Add `form_fields` of `"type": "random"` for every secret. Never commit a
   real credential.
5. Set `"available": true` and bump `tipi_version`.
6. Validate with `./tools/validate-appstore.sh`.
7. Set `INSTALL_MERIDIAN=true` in `server.env` and rerun `sudo ./install.sh`.

## What is already true

Nothing about the host platform needs to change to support Meridian. It will
get `meridian.home.arpa` through exactly the same wildcard DNS and Traefik
routing that every other app uses. There is no Meridian-specific logic in the
installer, and there should never be any — see `docs/architecture.md`.
