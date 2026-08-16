# Host addressing

Every `*.home.arpa` name resolves to a single address — `LAN_IP`. If that
address moves, every service name on the LAN points at nothing. So the one
hard requirement this platform places on your network is: **LAN_IP must not
change.**

There are exactly two good ways to guarantee that, and they are equally valid.

## Option 1: a DHCP reservation on your router (recommended)

Bind the server's MAC address to a fixed IP in your router's DHCP settings.
The host keeps using DHCP and simply always receives the same address.

Preferred because:

- Addressing stays in one place — the router — alongside the DNS setting you
  already have to configure there.
- It survives an OS reinstall without touching the server.
- On **WiFi** it is markedly safer: no risk of a bad config dropping the
  association on a link you may not be able to reach to fix.

## Option 2: a static address on the host

```bash
sudo ./tools/set-static-ip.sh
```

Use this when you do not control the router's DHCP, or you want the host's
address to be independent of it.

**Do not do both** with different values. A reservation for one address while
the host statically claims another produces intermittent, hard-to-diagnose
conflicts.

---

## Why preflight warns even when you *have* reserved it

This is a genuine limitation, not a bug you can configure away.

Preflight checks:

```bash
ip -4 addr show dev "$LAN_INTERFACE" | grep -q 'dynamic'
```

That detects the address arrived **via DHCP** — the kernel marks DHCP-assigned
addresses `dynamic` and gives them a lease lifetime.

A DHCP *reservation* is still delivered by DHCP. The address is still
`dynamic`. The reservation is entirely server-side state, and there is no DHCP
option that tells a client "this address is reserved for you." **The host
cannot know.**

So if you have correctly reserved the address, tell the installer:

```bash
LAN_IP_IS_RESERVED=true
```

Preflight then reports it as satisfied rather than warning. That setting is an
assertion by you, not something verified — which is the honest arrangement,
since verification is impossible from here.

---

## The WiFi complication

If your interface is wireless (`wlp*`, `wlx*`), read this before running the
static-IP tool.

Netplan configures a WiFi interface with an `access-points` block carrying the
SSID and passphrase. **An interface declared without that block will not
associate at all** — you lose the network entirely, on the very link you would
need to fix it.

`tools/set-static-ip.sh` handles this in three ways:

1. It writes an **additive override** (`/etc/netplan/90-u-server-static.yaml`)
   containing only addressing keys. Your existing netplan files, including
   their `access-points`, still apply and are merged with it.
2. Before applying, it re-reads the **merged** configuration via `netplan get`
   and refuses if `access-points` has disappeared. `netplan generate`
   succeeding does not prove the link will still associate.
3. If netplan does not currently define your WiFi interface at all — meaning
   the credentials live in NetworkManager rather than netplan — it **refuses**
   and prints the exact `nmcli` commands to set a static address on the
   existing connection profile instead.

A wireless link is also a questionable foundation for the machine serving DNS
to your whole LAN: when the WiFi drops, name resolution drops with it. Worth
considering wired if that is an option. Not a blocker — the platform works
fine over WiFi — but it is the sort of thing that turns into a confusing
outage months later.

---

## Safety when applying

Applying a bad network configuration over SSH locks you out. The tool:

- validates with `netplan generate` before applying anything, and deletes its
  own file if validation fails
- applies with **`netplan try`**, which waits for confirmation and
  **auto-reverts after 120 seconds** — so a mistake costs two minutes, not a
  trip to the machine
- backs up any previous version of its own file
- verifies afterwards that the address is present, is no longer DHCP-assigned,
  that the gateway answers, and that DNS still resolves

```bash
sudo ./tools/set-static-ip.sh --dry-run    # show the file, change nothing
sudo ./tools/set-static-ip.sh --revert     # remove it, return to previous behaviour
```

## Why the installer does not prompt for this

`00-preflight.sh` points at the tool but never prompts. `sudo ./install.sh`
must be able to run unattended; a blocking prompt mid-install would hang
automation and CI. Changing a host's network configuration is also exactly the
kind of invasive action that deserves a deliberate, separate invocation rather
than a `[y/N]` buried in a long install log.

## DNS on the link

The tool sets the interface's nameservers to **upstream public resolvers**, not
`127.0.0.1`. That is deliberate and matches the bootstrap ordering in
[dns.md](dns.md): the host must be able to resolve names before AdGuard
exists. `scripts/50-local-dns.sh` repoints the host at AdGuard later, through a
systemd-resolved drop-in, once the wildcard is verified working.

## If you lock yourself out anyway

From a console (not SSH):

```bash
sudo rm /etc/netplan/90-u-server-static.yaml
sudo netplan generate
sudo netplan apply
```

Or boot and let `netplan try`'s rollback do it for you — if you never confirmed,
the change was already reverted.
