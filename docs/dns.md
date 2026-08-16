# DNS

The goal: every service on this server gets a real hostname, and adding a new
service never requires touching DNS.

## The two-layer model

```
AdGuard Home    hostname  ──►  server IP        set once, never again
Traefik         hostname  ──►  container        generated per app
```

A browser asking for `nomad.home.arpa` gets `192.168.8.10` from AdGuard — the
same answer it would get for `whoami.home.arpa`, or `anything-at-all.home.arpa`.
It then opens an HTTP connection to that address with `Host: nomad.home.arpa`,
and **Traefik** uses that header to pick the container.

This is why adding an app needs no DNS work: the wildcard already answers for
names nobody has invented yet.

## Why `home.arpa`

`home.arpa` is reserved by [RFC 8375](https://www.rfc-editor.org/rfc/rfc8375)
for exactly this purpose — non-unique names on a home network. It will never
be delegated on the public Internet, so it cannot collide with a real domain.

Do **not** use `.local`. That is reserved for mDNS/Bonjour
([RFC 6762](https://www.rfc-editor.org/rfc/rfc6762)). Using it for unicast DNS
produces resolution that works on some clients and mysteriously fails on
others — macOS and most Linux desktops route `.local` to mDNS regardless of
what your resolver says. `us_config_validate` rejects it.

## The rewrites

Two entries, not one:

| Rewrite | Why |
|---|---|
| `*.home.arpa → LAN_IP` | Every service hostname. |
| `home.arpa → LAN_IP` | The apex. A wildcard does **not** match the bare domain, and Runtipi's dashboard binds exactly that name. |

Both are created by `scripts/50-local-dns.sh` through AdGuard's control API,
not by editing `AdGuardHome.yaml`. That matters: AdGuard rewrites its config
file wholesale on shutdown, so hand-edits made while it runs are lost.

Verify at any time:

```bash
dig @192.168.8.10 nomad.home.arpa +short
dig @192.168.8.10 anything-random.home.arpa +short    # proves the wildcard
```

Both should return the server's address. `status.sh` and `doctor.sh` run
exactly this check with a randomised name, so a stale cache cannot make a
broken wildcard look healthy.

## Offline behaviour

AdGuard matches rewrites **before** forwarding anything upstream. With the WAN
unplugged:

- `*.home.arpa` — still resolves, answered locally
- every installed app — still reachable
- Traefik, Docker, databases — unaffected
- Internet names — fail, as they must

Local service resolution has no dependency on Internet connectivity. This is a
property of ordering inside AdGuard, not something the installer bolts on.

## The port-53 bootstrap problem

Ubuntu runs `systemd-resolved`, which binds a stub listener on `127.0.0.53:53`.
AdGuard needs `:53`. But naively pointing the host at AdGuard at the same
moment creates a circular dependency:

```
AdGuard is a container
  → pulling its image needs DNS
    → DNS is the container that hasn't started
```

The installer breaks this in two phases:

**Phase 1 — `scripts/40-adguard.sh`, before AdGuard exists**

Disable *only* the stub listener:

```ini
[Resolve]
DNSStubListener=no
```

and point `/etc/resolv.conf` at `/run/systemd/resolve/resolv.conf`, which
lists real upstream servers. Port 53 is now free and the host still resolves
normally. The stage verifies this by resolving `github.com` before continuing.

**Phase 2 — `scripts/50-local-dns.sh`, after AdGuard is verified answering**

Only once the wildcard is proven working, repoint the host at AdGuard:

```ini
[Resolve]
DNSStubListener=no
DNS=127.0.0.1
FallbackDNS=9.9.9.9 149.112.112.112
Domains=~home.arpa
```

`FallbackDNS` keeps the host resolving if the AdGuard container is ever
stopped. If the repoint fails to resolve, the stage **reverts** rather than
leaving the machine without DNS.

Container DNS is unaffected throughout: Runtipi gives containers `DNS_IP`
(default `9.9.9.9`), so image pulls never depend on AdGuard being up.

## Router configuration — the one manual step

The installer does not own your router. Set the DHCP-advertised DNS server for
LAN clients to this machine:

```
DNS server: 192.168.8.10
```

### Do not add a secondary public resolver

```
Primary   192.168.8.10
Secondary 8.8.8.8        ← breaks home.arpa, intermittently
```

Clients do **not** treat these as ordered "try the first, fall back to the
second". They treat them as interchangeable, and many query them in parallel
or rotate between them. When a query for `nomad.home.arpa` happens to go to
`8.8.8.8`, the answer is `NXDOMAIN` — authoritatively "this does not exist".

The result is the worst kind of fault: it works most of the time, fails
randomly, differs per device, and looks like an application bug. Some clients
even cache the negative answer.

A secondary buys nothing here anyway. AdGuard already forwards everything that
is not `home.arpa` to its own upstream resolvers, so Internet resolution is
already redundant *behind* AdGuard, where the redundancy belongs.

If you are worried about AdGuard being a single point of failure, the right
answers are a second AdGuard instance or a DHCP reservation you can change in
30 seconds — not a resolver that lies about your local names.

### Verifying a client

From a LAN client, after renewing its DHCP lease:

```bash
nslookup nomad.home.arpa
# should return 192.168.8.10, served by 192.168.8.10
```

If it returns NXDOMAIN, the client is still using an old resolver. Renew the
lease or reconnect the interface — clients cache DHCP-supplied DNS servers for
the lease duration.

## Common faults

| Symptom | Cause |
|---|---|
| Works on the server, not on clients | Router still advertises its own DNS. |
| Works for some names, fails for others | A secondary public resolver is configured. Remove it. |
| Intermittent per-device failures | Same cause. Some queries reach the public resolver. |
| Everything fails after a reboot | `LAN_IP` changed. It must be static or DHCP-reserved. |
| `.local` names don't resolve | Expected — `.local` is mDNS. Use `home.arpa`. |

`./doctor.sh` prints the full resolution path: `/etc/resolv.conf`,
`systemd-resolved` status, AdGuard's rewrite list, and live queries for each
service name plus a random one.
