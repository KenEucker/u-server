# Whoami — u-server routing test

A minimal Go HTTP server that prints the request it received.

This app exists to answer one question: **does an arbitrary containerised
application work on this platform without any special support?**

It has no dependency on Project NOMAD, Meridian, or anything u-server-specific.
It declares an image and an internal port. Everything else is provided by the
platform:

- `whoami.home.arpa` resolves because AdGuard answers `*.home.arpa` with the
  server's address — no per-service DNS record was created.
- Traefik routes the request to this container based on the `Host` header,
  because Runtipi generated router labels from the app's registration.
- The container is reachable without publishing a host port to the LAN.

Visit it and you will see the request headers echoed back, including the `Host`
header that Traefik matched on. If this page loads at its `home.arpa` name,
adding any other Docker application follows exactly the same path.

Safe to uninstall once you have seen it work.
