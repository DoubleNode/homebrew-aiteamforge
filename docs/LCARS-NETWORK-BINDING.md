# LCARS Dashboard Network Binding

**Which network interfaces your team's LCARS kanban dashboard listens on, and how to reach it from another machine over Tailscale.**

---

## Table of Contents

- [Overview](#overview)
- [The Four Modes](#the-four-modes)
- [Reaching a Dashboard From Another Machine](#reaching-a-dashboard-from-another-machine)
- [LCARS_TAILSCALE_IP Override](#lcars_tailscale_ip-override)
- [Fail-Closed Behaviour](#fail-closed-behaviour)
- [The `all` Escape Hatch](#the-all-escape-hatch)
- [Troubleshooting](#troubleshooting)

---

## Overview

Each team's LCARS server (`lcars-ui/server.py`, one process per team, one port
per team — this is separate from Fleet Monitor, covered in
[MULTI_MACHINE.md](MULTI_MACHINE.md)) decides which network interfaces to
listen on at startup, controlled by three environment variables:

| Variable | Purpose |
|---|---|
| `LCARS_BIND_MODE` | Which posture to use: `auto` (default), `loopback`, `tailscale`, or `all` |
| `LCARS_BIND_ALLOW_ALL_INTERFACES` | Second, separate confirmation required for `LCARS_BIND_MODE=all` |
| `LCARS_TAILSCALE_IP` | Pin the tailnet address explicitly instead of auto-detecting it |

Before this control existed, the server always bound `0.0.0.0` — every
interface. Anything on the same LAN (coffee shop wifi, hotel wifi, office
network) could reach the dashboard's TCP port directly, with only the
application-layer checks (API-key gate, Host/Origin allowlists) standing in
the way. The modes below add a network-layer control underneath those
checks — they do not replace it.

Set these in your shell profile (`~/.zshrc`, `~/.bashrc`) or in the
team-specific startup script before starting a team's LCARS server, then
restart it: `aiteamforge restart <team>` (or `aiteamforge restart` for all
teams).

---

## The Four Modes

### `auto` (default — no variable needs to be set)

Binds `127.0.0.1` (loopback), plus this machine's Tailscale IPv4 address if
one can be determined. If it cannot be determined — Tailscale isn't
installed, isn't logged in, or `tailscaled` isn't reachable — **the server
still starts, on loopback only.** This is the fail-closed default: the
degraded outcome is always a *narrower* bind, never wider. A `NOTICE` line is
printed to the server's log either way, so it's visible which posture you
actually got.

Use this when you mostly work locally and want cross-machine access
whenever Tailscale happens to be up, without the server refusing to start
when it isn't.

### `loopback`

`LCARS_BIND_MODE=loopback`

Binds `127.0.0.1` only. No cross-machine access at all, even if Tailscale is
running. Use this on a machine where the dashboard should never be reachable
from anywhere else — a shared/public machine, or simply "I don't need
cross-machine access and would rather not think about it."

### `tailscale`

`LCARS_BIND_MODE=tailscale`

Same address set as `auto` (loopback + tailnet IPv4) when detection
succeeds, but **refuses to start** (non-zero exit, `FATAL` in the log) if the
tailnet address cannot be determined. Use this when cross-machine dashboard
access is a hard requirement for your setup — a silent downgrade to
loopback-only would mean the team on the other machine gets "connection
refused" and has to go dig through logs to find out why. Failing loudly at
startup instead makes the misconfiguration impossible to miss.

### `all` (legacy escape hatch — not a supported posture)

`LCARS_BIND_MODE=all` **and** `LCARS_BIND_ALLOW_ALL_INTERFACES=1` (both
required)

Binds every interface (`0.0.0.0`) — the pre-hardening behaviour. Requires
two separate variables so a single typo can't silently re-open the whole
LAN. Setting `LCARS_BIND_MODE=all` alone refuses to start and tells you to
add the confirmation variable if you meant it. This mode is not a supported
posture going forward — if what you actually want is cross-machine access,
use `tailscale` instead; it gives you that without exposing the port to
everyone else on the LAN.

---

## Reaching a Dashboard From Another Machine

1. Both machines need Tailscale installed and connected to the same tailnet
   (see [MULTI_MACHINE.md § Tailscale Setup](MULTI_MACHINE.md#tailscale-setup)
   if you haven't set that up yet).
2. On the machine hosting the dashboard, use `LCARS_BIND_MODE=auto` (the
   default — no action needed) or `LCARS_BIND_MODE=tailscale` if you want
   startup to fail loudly when Tailscale isn't reachable, then start/restart
   the team: `aiteamforge restart <team>`.
3. Confirm the bind posture in the server's own log — every mode prints a
   `[LCARS][bind] posture: ...` line naming exactly what it's listening on:
   ```bash
   tail -20 ~/aiteamforge/logs/lcars-<team>.log | grep '\[LCARS\]\[bind\]'
   ```
4. From the other machine, browse to
   `http://<hosting-machine's-tailscale-name-or-ip>:<port>` — the same
   MagicDNS name or `100.x.y.z` address `tailscale status` shows for that
   machine.

If step 3's posture line only shows `127.0.0.1` when you expected a tailnet
address too, see [Troubleshooting](#troubleshooting) below.

---

## LCARS_TAILSCALE_IP Override

`LCARS_TAILSCALE_IP=100.x.y.z`

Pins the tailnet address instead of auto-detecting it — useful when
detection is unreliable in your environment, or you simply want to be
explicit. Works in both `auto` and `tailscale` mode, and works even when
Tailscale detection itself would fail (the override bypasses detection
entirely; it does not require `tailscaled` to be reachable at all).

The value must be an IPv4 address inside Tailscale's `100.64.0.0/10` CGNAT
range. Anything else — a LAN address, `0.0.0.0`, a typo — is treated as a
**hard configuration error** (refuses to start) rather than silently
ignored. If you set this variable you meant something specific by it;
guessing at what would be worse than stopping.

---

## Fail-Closed Behaviour

The property that matters most across every mode: **no code path widens the
bind on its own.** Detection failing, a timeout, an invalid value — every
one of those either narrows to a smaller address set than what was asked
for, or refuses to start. The only way to get the pre-hardening
all-interfaces behaviour is the explicit, two-variable `all` opt-in above.

Tailscale detection (the CLI, then a local-interface scan as a fallback) is
capped at a shared ~8 second budget total across both phases combined, so a
missing or hung `tailscale` installation degrades the startup posture
(narrower bind, or a `tailscale`-mode refusal) rather than making the whole
server appear hung to whatever's watching it start up.

**Caveat — Tailscale Funnel/Serve:** if you have `tailscale funnel` or
`tailscale serve` switched on for this port, it proxies to
`localhost:<port>` from inside the machine. A loopback-only bind is, from
the proxy's point of view, perfectly reachable — so binding to loopback does
**not** close a Funnel that's already on. Turning that off requires
`tailscale funnel off` at the Tailscale layer; no `LCARS_BIND_MODE` setting
can do it, because Funnel operates outside this process entirely.

---

## The `all` Escape Hatch

Documented above under [The Four Modes](#the-four-modes). Repeating the
core point because it's the one people reach for under time pressure: if the
goal is "reach this from another machine," `LCARS_BIND_MODE=tailscale`
almost always gets you there without the LAN-wide exposure `all` produces.
Reach for `all` only when you specifically need LAN-wide (not just tailnet)
access, understand that every other host on that LAN can attempt to reach
the port, and are relying on the API-key gate and Host/Origin checks as the
only remaining line of defense.

---

## Troubleshooting

**Dashboard works locally but not from another machine on the tailnet:**
- Check the posture line: `grep '\[LCARS\]\[bind\]' <log>`. If it shows
  loopback only, Tailscale detection didn't find an address. Confirm
  `tailscale status` on the hosting machine actually shows it connected.
- Try `LCARS_TAILSCALE_IP=<the address from tailscale status>` to bypass
  detection entirely and confirm that's the actual blocker.
- If you need startup to fail loudly instead of silently degrading next
  time this happens, switch to `LCARS_BIND_MODE=tailscale`.

**Server won't start at all after setting `LCARS_BIND_MODE`:**
- `FATAL: ... is not a valid mode` — check for a typo; valid values are
  `auto`, `loopback`, `tailscale`, `all` (case/whitespace tolerant).
- `FATAL: LCARS_BIND_MODE=all binds every interface ...` — you set `all`
  without also setting `LCARS_BIND_ALLOW_ALL_INTERFACES=1`. That's by
  design (see above), not a bug.
- `FATAL: LCARS_BIND_MODE=tailscale but this host's Tailscale IPv4 could
  not be determined` — Tailscale isn't reachable from this mode's strict
  requirement. Either fix Tailscale, set `LCARS_TAILSCALE_IP` explicitly, or
  drop to `auto`/`loopback` if cross-machine access isn't actually needed
  right now.

**General network troubleshooting** (Tailscale connectivity, firewall,
service discovery) is covered in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#lcars-server-running-but-not-accessible)
and [MULTI_MACHINE.md § Troubleshooting Network Issues](MULTI_MACHINE.md#troubleshooting-network-issues).
