#!/usr/bin/env python3

#
#  lcars_terminal.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""XACA-0161-003 — terminal-bridge primitives for the LCARS server.

This module holds everything the terminal reverse-proxy needs that is NOT
request dispatch: deterministic ttyd port derivation, the single-use ticket
store, the concurrent-session cap, the upstream handshake builder, and the
`select()`-based byte pump. `server.py` owns only the four route handlers and
the auth decisions; this file owns the mechanics, so the genuinely novel
socket-hijack code sits in one small, separately reviewable unit rather than
scattered through a 20,000-line handler.

WHY THIS EXISTS AT ALL, AND WHY IT IS PARANOID
==============================================
A web terminal is a root-equivalent remote shell. Per
`docs/xaca-0161-threat-model.md` §1.2 this is the highest-severity surface
this repository will have shipped. Two facts from
`docs/xaca-0161-terminal-bridge-evaluation.md` §5 make the default posture
actively dangerous:

  1. A WebSocket handshake is an HTTP **GET**, and `server.py`'s
     `_auth_gate()` is deliberately wired into `do_POST`/`do_PUT`/`do_PATCH`/
     `do_DELETE` ONLY. The upgrade therefore lands on the one dispatch path
     with no authentication at all.
  2. `_auth_gate()` **fails open** when no API key is configured. An
     unauthenticated dashboard is a bad day; an unauthenticated writable
     shell is an incident.

So this module and its callers in `server.py` fail CLOSED at every fork:

  * the feature is **off** unless `LCARS_TERMINAL_ENABLED=1` (a machine that
    has not opted in returns 404 and does not admit the routes exist);
  * every terminal route refuses to serve (503) when no API key resolves —
    a deliberate, documented divergence from `_auth_gate()`'s permissive
    default (evaluation §5 conclusion 3, §6.4 item 3);
  * the WebSocket route requires a single-use, short-TTL ticket that can
    only be minted through an authenticated POST;
  * unrecognised state (bad terminal name, absent upstream, malformed
    upgrade) is a refusal, never a best-effort pass-through.

AUTH SHAPE (evaluation §6.4 — implemented, not redesigned)
==========================================================
  mint    POST /api/terminal/ticket {"terminal": "engineering"}
          A POST, so it already traverses `_auth_gate()`. Root of trust.
  redeem  GET  /terminal/engineering/ws?ticket=<nonce>
          Validated with a constant-time compare and BURNED before any
          socket is hijacked. Single use, TTL seconds, bound to one
          terminal name.

The ticket rides in the query string because a browser cannot set headers on
a WebSocket handshake (evaluation §3.4) and ttyd already occupies the
`Sec-WebSocket-Protocol` slot with `tty`. That is a constraint, not a
preference.

TTYD CONTRACT (what XACA-0161-002 must start)
=============================================
One `ttyd` per terminal, bound to loopback only, base-path mounted so the
proxy can forward the request path verbatim:

    ttyd -p <ttyd_port_for(lcars_port, index)> -i lo0 \
         -b /terminal/<terminal> -W -m 4 -H X-WEBAUTH-USER \
         tmux -L <team> attach -t <team>-<terminal> -f ignore-size,active-pane

  * `-i lo0` — NOT the UNIX-domain socket the evaluation originally
    recommended: the 2026-08-26 device spike recorded in §1 of the
    evaluation found `tailscale serve` returns 502 against a UDS on this
    machine. Loopback preserves the property that matters (ttyd is
    unreachable from the LAN; the proxy is the only path in).
  * `-b /terminal/<terminal>` is REQUIRED. This proxy forwards the received
    path verbatim, so ttyd must answer on `/terminal/<terminal>/ws`.
  * `-H X-WEBAUTH-USER` is defence in depth: the proxy injects that header
    and strips any client-supplied copy, so a direct loopback caller that
    somehow reaches ttyd still fails ttyd's own check.
  * `-m 4` caps ttyd's clients; the proxy independently caps concurrent
    hijacked sessions (`LCARS_TERMINAL_MAX_SESSIONS`).
  * Do NOT pass `-a/--url-arg`: it turns the URL into a command-injection
    vector.

PORT DERIVATION
===============
Deterministic, collision-free across teams, and computed the same way by
Python and by shell (`python3 lcars_terminal.py port ...`). See
`ttyd_port_for()`.

PROXIED SURFACE, AND THE ONE THING IT CANNOT DO
===============================================
Three routes, matching what XACA-0161-002 starts ttyd to serve:

    /terminal/<name>/        ttyd index      buffered GET proxy
    /terminal/<name>/token   ttyd token      buffered GET proxy
    /terminal/<name>/ws      WebSocket       the ONLY socket hijack

`X-WEBAUTH-USER` is injected on ALL THREE, not just the upgrade. Measured
against live ttyd 1.7.7 on 2026-08-26 (independently reproduced here after
XACA-0161-002 reported it): with `-H X-WEBAUTH-USER`, ttyd answers **407** on
the index and on `/token` when the header is missing OR present-but-empty, and
200 with a non-empty value. `/ws` without it is dropped with no response at
all. Injecting only at the upgrade would leave the index 407ing and the page
would never load far enough to attempt a WebSocket.

The same measurement showed `/token` returns `{"token": ""}` when ttyd runs
without `-c`. ttyd's own token mechanism is therefore a **no-op**, and the
header is the whole of ttyd's side of the gate. Neither is the authentication:
the §6.4 ticket mint-and-burn is, and the header is defence in depth for the
case where something else on the box reaches loopback.

ALL THREE ROUTES REQUIRE A TICKET, and every ticket is single-use. A client
that wants index + token + socket mints three. That is deliberate and it is
NOT negotiable down to a reusable ticket "because three POSTs is clumsy" —
a ticket that survives its first use is a bearer credential for a shell,
sitting in a URL, in server logs, and in browser history.

THE CONSEQUENCE, STATED PLAINLY: an `<iframe src="/terminal/x/">` of ttyd's
own index CANNOT work under this design. ttyd's bundled JavaScript builds its
own WebSocket URL, and we do not control it, so it cannot attach a ticket —
the upgrade arrives ticketless and is refused. The index route is proxied
because ttyd serves it and 002 built to it, not because an iframe will work.
A functioning pane needs one of:

  (a) an LCARS-hosted xterm.js client that constructs
      `wss://…/terminal/<name>/ws?ticket=…` itself — no ttyd index involved;
  (b) an amendment to evaluation §6.4 moving the ticket to an `HttpOnly;
      SameSite=Strict; Path=/terminal/<name>/` cookie set at index-redeem
      time, which browsers DO send on a WebSocket handshake (§3.4 carrier 1).

(b) is a real design and arguably stronger than a query-string nonce, but it
is an AUTH REDESIGN and is not made here. Escalated to the orchestrator.
"""

from __future__ import annotations

import errno
import json
import os
import re
import secrets
import select
import socket
import sys
import threading
import time

# ---------------------------------------------------------------------------
# Port derivation
# ---------------------------------------------------------------------------

# Base of the ttyd port block. Chosen to sit far above the LCARS 8xxx band and
# far below macOS's ephemeral floor (49152, `sysctl net.inet.ip.portrange`), so
# a derived port can neither collide with a team dashboard nor be stolen by an
# outbound connection's ephemeral allocation. NOTE FOR ANY FUTURE PORT OFF THIS
# FLEET: Linux's default ephemeral floor is 32768, and the top of this block
# (36999, for lcars_port 8999) sits ABOVE it. That is safe here because the
# AITeamForge fleet is macOS-only, but a Linux host would need either a lower
# base or a raised `net.ipv4.ip_local_port_range`. Value and block size are the ones
# XACA-0161-002's launchd work allocates against — they are a SHARED contract,
# not a local preference. Changing either moves every ttyd on the fleet, so
# change them in both places or not at all (better: call this module's CLI from
# the shell side, which is why it exists).
TTYD_PORT_BASE = 21000

# Terminals per team. Academy's four is NOT representative: XACA-0161-002
# measured a fleet maximum of 7 (android, dns, firebase), so the block is 16 —
# double the observed high-water mark, leaving room for a team to grow without
# renumbering every derived port on the fleet. Exceeding it is an ERROR, not a
# wrap-around: a wrap would silently alias two teams' shells onto one port,
# which is the worst possible failure this feature has.
MAX_TERMINALS_PER_TEAM = 16

# The LCARS port band this formula is defined over. Every port in
# ~/.aiteamforge/team-paths.json sits inside it (measured 2026-08-26: 8180,
# 8203, 8234, 8240, 8260, 8280, 8320, 8340, 8360, 8400-8405). A port outside
# the band raises rather than folding modulo 1000 — two teams on 8203 and 9203
# must not share a shell port.
LCARS_PORT_MIN = 8000
LCARS_PORT_MAX = 8999

# Terminal names are used to build paths and index the board map. Same shape
# the rest of the server uses for identifier-ish path segments.
TERMINAL_NAME_RE = re.compile(r'^[a-zA-Z0-9_-]+$')

# Tickets are URL-safe base64 of >= 32 CSPRNG bytes (threat model §6.1).
TICKET_BYTES = 32
TICKET_RE = re.compile(r'^[A-Za-z0-9_-]{16,256}$')


class TerminalConfigError(ValueError):
    """Raised when a terminal cannot be resolved to a port. Always fatal to
    the request: callers must refuse, never guess a port."""


def ttyd_port_for(lcars_port: int, index: int) -> int:
    """Deterministic ttyd port for the `index`-th terminal of the team whose
    LCARS dashboard listens on `lcars_port`.

        ttyd_port = TTYD_PORT_BASE + (lcars_port - LCARS_PORT_MIN) * 16 + index

    Every input is validated and an out-of-range input RAISES. The formula is
    injective over its domain, so no two (team, terminal) pairs can ever land
    on the same port -- which is the only property that actually matters here,
    because a collision would attach one team's pane to another team's shell.
    """
    if not isinstance(lcars_port, int) or isinstance(lcars_port, bool):
        raise TerminalConfigError(f"lcars_port must be an int, got {type(lcars_port).__name__}")
    if not isinstance(index, int) or isinstance(index, bool):
        raise TerminalConfigError(f"index must be an int, got {type(index).__name__}")
    if not (LCARS_PORT_MIN <= lcars_port <= LCARS_PORT_MAX):
        raise TerminalConfigError(
            f"lcars_port {lcars_port} is outside the derivation band "
            f"{LCARS_PORT_MIN}-{LCARS_PORT_MAX}; the ttyd port formula is not "
            f"defined for it (widening the band changes every derived port)"
        )
    if not (0 <= index < MAX_TERMINALS_PER_TEAM):
        raise TerminalConfigError(
            f"terminal index {index} is outside 0-{MAX_TERMINALS_PER_TEAM - 1}; "
            f"a team may define at most {MAX_TERMINALS_PER_TEAM} terminals"
        )
    return TTYD_PORT_BASE + (lcars_port - LCARS_PORT_MIN) * MAX_TERMINALS_PER_TEAM + index


def terminal_names(board_terminals) -> list:
    """Sorted, shape-validated terminal names from a board's `terminals` map.

    Sorted -- NOT JSON insertion order. `json.load()` preserves key order, so
    insertion order would make every derived ttyd port depend on how someone
    happened to hand-edit the board file. Sorting makes the index a function of
    the NAME SET alone. Names failing TERMINAL_NAME_RE are dropped rather than
    sanitised: a name that cannot be a safe path segment has no valid port.
    """
    if not isinstance(board_terminals, dict):
        return []
    return sorted(
        name for name in board_terminals
        if isinstance(name, str) and TERMINAL_NAME_RE.match(name)
    )


def resolve_ttyd_port(lcars_port: int, board_terminals, terminal: str) -> int:
    """Port for one named terminal of one team. Raises TerminalConfigError if
    the name is not on the board (never invents a port for an unknown name --
    that would let a URL address an arbitrary loopback port)."""
    if not isinstance(terminal, str) or not TERMINAL_NAME_RE.match(terminal):
        raise TerminalConfigError("terminal name failed shape validation")
    names = terminal_names(board_terminals)
    if terminal not in names:
        raise TerminalConfigError(f"terminal {terminal!r} is not defined on this board")
    return ttyd_port_for(lcars_port, names.index(terminal))


# ---------------------------------------------------------------------------
# Environment-driven posture
# ---------------------------------------------------------------------------

def _env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    """Bounded int from env. A malformed or out-of-range value falls back to
    the default rather than raising into the request path -- but the default is
    always the SAFE end of the range, so a typo cannot widen anything."""
    raw = os.environ.get(name, '')
    try:
        value = int(str(raw).strip())
    except (TypeError, ValueError):
        return default
    if value < minimum or value > maximum:
        return default
    return value


def terminal_enabled() -> bool:
    """Master switch, default OFF.

    Opt-in rather than opt-out is the whole point: every machine in the fleet
    pulls this code, and none of them should grow a shell endpoint because a
    file landed on disk. `1` and nothing else enables it.
    """
    return os.environ.get('LCARS_TERMINAL_ENABLED', '').strip() == '1'


def max_sessions() -> int:
    """Concurrent hijacked sessions allowed, per server process.

    Evaluation §6.5 item 3: every hijacked connection pins a thread for its
    whole lifetime, on a server whose unbounded-thread creation is a recorded
    open issue. The existing no-cap posture is NOT permission to add long-lived
    connections to it, so this cap is mandatory and small by default.
    """
    return _env_int('LCARS_TERMINAL_MAX_SESSIONS', 4, 1, 32)


def ticket_ttl_seconds() -> int:
    """Ticket lifetime. Evaluation §6.4 says <= 30s; that is the default and
    the ceiling here is deliberately low."""
    return _env_int('LCARS_TERMINAL_TICKET_TTL', 30, 5, 120)


def idle_timeout_seconds() -> int:
    """Seconds of ZERO traffic in BOTH directions before a pane is torn down
    (threat model §6.5: "an idle timeout and an explicit teardown").

    This is emphatically NOT the inherited `LCARS_SOCKET_TIMEOUT` (30s), which
    `pump()` clears on both sockets -- see its docstring for what that timeout
    actually breaks (backpressure, not idleness) and why the evaluation's
    prediction needed correcting. An hour of two-way silence is a bound no
    interactive pane will hit: ttyd and libwebsockets exchange ping/pong
    frames, so an idle-but-alive pane is never traffic-free for that long.
    """
    return _env_int('LCARS_TERMINAL_IDLE_TIMEOUT', 3600, 60, 86400)


def ttyd_host() -> str:
    """Loopback address the ttyd daemons listen on. Overridable only to the
    IPv4/IPv6 loopback literals -- anything else falls back, so this knob can
    never be used to point the proxy at a remote host."""
    raw = os.environ.get('LCARS_TERMINAL_TTYD_HOST', '').strip()
    if raw in ('127.0.0.1', '::1', 'localhost'):
        return raw
    return '127.0.0.1'


def webauth_user() -> str:
    """Value injected as `X-WEBAUTH-USER` on the proxied handshake. ttyd
    performs NO validation of it (evaluation §3.1) -- its only job is to be
    non-empty, so ttyd started with `-H X-WEBAUTH-USER` refuses anything that
    did not come through this proxy."""
    raw = os.environ.get('LCARS_TERMINAL_WEBAUTH_USER', '').strip()
    if raw and TERMINAL_NAME_RE.match(raw):
        return raw
    return 'lcars'


# ---------------------------------------------------------------------------
# Ticket store
# ---------------------------------------------------------------------------

class TicketStore:
    """Single-use, short-TTL, terminal-bound nonces (evaluation §6.4).

    The comparison is constant-time via the `safe_equal` callable injected by
    `server.py` (its `_auth_safe_equal`, which hashes both sides first to
    remove the length oracle). Injection rather than import avoids a circular
    import AND avoids a second copy of a credential-comparison primitive.

    WHY REDEEM SCANS EVERY ENTRY. The obvious implementation is a dict lookup
    keyed by the ticket, but a dict lookup is not constant-time and leaks
    through hash-bucket behaviour -- which would make the constant-time compare
    decorative. Redeem therefore walks all live entries and compares each with
    `safe_equal`. The store is capped at a few dozen entries, so the scan is
    trivially cheap; correctness wins over a micro-optimisation here.
    """

    def __init__(self, safe_equal, ttl_provider=ticket_ttl_seconds, max_outstanding=64,
                 clock=time.monotonic):
        self._safe_equal = safe_equal
        self._ttl_provider = ttl_provider
        self._max_outstanding = max_outstanding
        self._clock = clock
        self._lock = threading.Lock()
        # ticket -> (terminal, expires_at)
        self._tickets = {}

    def _purge_locked(self):
        now = self._clock()
        for ticket in [t for t, (_term, exp) in self._tickets.items() if exp <= now]:
            del self._tickets[ticket]

    def mint(self, terminal: str) -> tuple:
        """Return (ticket, ttl_seconds) bound to `terminal`.

        Raises TerminalConfigError if the name fails shape validation -- the
        caller has already checked, but a ticket bound to an unvalidated name
        would be a stored path segment, so it is re-checked at the boundary.
        """
        if not isinstance(terminal, str) or not TERMINAL_NAME_RE.match(terminal):
            raise TerminalConfigError("terminal name failed shape validation")
        ttl = self._ttl_provider()
        ticket = secrets.token_urlsafe(TICKET_BYTES)
        with self._lock:
            self._purge_locked()
            if len(self._tickets) >= self._max_outstanding:
                # Bounded memory. Drop the soonest-to-expire rather than
                # refusing to mint: an operator hammering the mint endpoint is
                # authenticated by construction, so this is a resource bound,
                # not a security control.
                oldest = min(self._tickets, key=lambda t: self._tickets[t][1])
                del self._tickets[oldest]
            self._tickets[ticket] = (terminal, self._clock() + ttl)
        return ticket, ttl

    def redeem(self, presented, terminal: str) -> bool:
        """Validate AND burn. True exactly once per minted ticket.

        Every failure mode returns False with the same shape -- expired,
        unknown, wrong terminal, malformed. The caller emits one generic
        refusal so the client cannot distinguish "no such ticket" from "that
        ticket was for another terminal".
        """
        if not isinstance(presented, str) or not TICKET_RE.match(presented):
            return False
        if not isinstance(terminal, str) or not TERMINAL_NAME_RE.match(terminal):
            return False
        with self._lock:
            self._purge_locked()
            matched = None
            for candidate, (bound_terminal, _exp) in self._tickets.items():
                # Constant-time on the SECRET; the terminal binding is checked
                # after a match so a mismatched binding still burns nothing.
                if self._safe_equal(presented, candidate):
                    matched = (candidate, bound_terminal)
                    # No early break: breaking here would make the scan's
                    # duration depend on WHERE the match sat in the store.
            if matched is None:
                return False
            candidate, bound_terminal = matched
            # Burn unconditionally once the secret matched. A ticket presented
            # against the wrong terminal is a confused or hostile client and
            # must not get a second attempt with the right one.
            del self._tickets[candidate]
            return bound_terminal == terminal

    def outstanding(self) -> int:
        with self._lock:
            self._purge_locked()
            return len(self._tickets)


# ---------------------------------------------------------------------------
# Concurrent-session cap
# ---------------------------------------------------------------------------

class SessionLimiter:
    """Counts live hijacked sessions and refuses past the cap.

    Deliberately a counter rather than a semaphore: a semaphore's `acquire()`
    blocks, and a blocked acquire on this server would pin the very thread the
    cap exists to protect. Refusal is immediate.
    """

    def __init__(self, cap_provider=max_sessions):
        self._cap_provider = cap_provider
        self._lock = threading.Lock()
        self._active = 0

    def acquire(self) -> bool:
        cap = self._cap_provider()
        with self._lock:
            if self._active >= cap:
                return False
            self._active += 1
            return True

    def release(self):
        with self._lock:
            if self._active > 0:
                self._active -= 1

    @property
    def active(self) -> int:
        with self._lock:
            return self._active


# ---------------------------------------------------------------------------
# Upstream handshake
# ---------------------------------------------------------------------------

# Client headers forwarded verbatim to ttyd. An ALLOWLIST, not a hop-by-hop
# denylist: a denylist forwards anything a future client invents, and the two
# headers a WebSocket upgrade genuinely needs (`Upgrade`, `Connection`) are
# themselves hop-by-hop, so the usual denylist would strip exactly the wrong
# things. Notably absent: `Authorization`, `Cookie`, `X-API-Key` -- the LCARS
# credential must never be relayed to ttyd -- and `X-WEBAUTH-USER`, which this
# proxy sets itself and a client must never be able to supply.
WS_FORWARD_HEADERS = (
    'Upgrade',
    'Connection',
    'Sec-WebSocket-Key',
    'Sec-WebSocket-Version',
    'Sec-WebSocket-Protocol',
    'Sec-WebSocket-Extensions',
)

# Cap on the upstream response head. ttyd's 101 is a few hundred bytes; this
# bound stops a wedged or hostile upstream from growing the buffer without end.
MAX_UPSTREAM_HEAD_BYTES = 16384


class HandshakeError(Exception):
    """The client's upgrade request is not one this proxy will forward."""


def _header_value_is_safe(value) -> bool:
    """Reject CR/LF (and NUL) in any forwarded header value.

    This proxy builds the upstream request by string concatenation, so an
    un-checked value containing CRLF would let a client inject arbitrary
    headers -- including its own `X-WEBAUTH-USER`, defeating the ttyd-side
    check. Rejecting is correct here; stripping would silently forward a
    mangled value.
    """
    if not isinstance(value, str):
        return False
    return not any(ch in value for ch in ('\r', '\n', '\0'))


def is_websocket_upgrade(headers) -> bool:
    """True only for a well-formed WebSocket upgrade.

    The hijack is reachable ONLY through this check, so anything ambiguous is
    False: a plain GET that slipped onto the route must be refused before a
    socket is taken out of the handler's hands.
    """
    upgrade = (headers.get('Upgrade') or '').strip().lower()
    connection = (headers.get('Connection') or '').strip().lower()
    if upgrade != 'websocket':
        return False
    tokens = {tok.strip() for tok in connection.split(',')}
    if 'upgrade' not in tokens:
        return False
    key = (headers.get('Sec-WebSocket-Key') or '').strip()
    return bool(key)


def build_upstream_handshake(path: str, headers, upstream_host: str, upstream_port: int,
                             injected_user: str) -> bytes:
    """Reconstruct the upgrade request for ttyd.

    Reconstructed rather than replayed byte-for-byte, because
    `BaseHTTPRequestHandler` has already consumed and parsed the original off
    the wire -- and because a verbatim replay would forward the client's
    `Authorization`/`Cookie`/`X-WEBAUTH-USER` along with it. The query string
    is dropped entirely: it carried the ticket, and the ticket is a
    proxy-side secret that has no business reaching ttyd or its logs.
    """
    if not path.startswith('/') or not _header_value_is_safe(path):
        raise HandshakeError("upstream path failed validation")
    if not _header_value_is_safe(injected_user) or not injected_user:
        raise HandshakeError("injected auth-header value failed validation")

    lines = [f"GET {path} HTTP/1.1", f"Host: {upstream_host}:{upstream_port}"]
    for name in WS_FORWARD_HEADERS:
        value = headers.get(name)
        if value is None:
            continue
        value = value.strip()
        if not value:
            continue
        if not _header_value_is_safe(value):
            raise HandshakeError(f"header {name} failed validation")
        lines.append(f"{name}: {value}")
    # Injected LAST so a (rejected above, but belt-and-braces) duplicate from
    # the client cannot be the value ttyd reads first.
    lines.append(f"X-WEBAUTH-USER: {injected_user}")
    return ("\r\n".join(lines) + "\r\n\r\n").encode('latin-1', 'strict')


# Response headers relayed back from ttyd on the buffered (non-WebSocket)
# routes. An allowlist again: ttyd's `Server:` banner is version disclosure and
# any `Set-Cookie` it grew would be an unmanaged credential on the LCARS
# origin. Content-Length is recomputed from the body, never copied.
BUFFERED_RESPONSE_HEADERS = ('Content-Type', 'Cache-Control', 'Content-Encoding')

# Cap on a buffered proxied body. ttyd's index bundles xterm.js and is ~1-2 MB;
# 8 MB is generous headroom and still a bound.
MAX_BUFFERED_BODY_BYTES = 8 * 1024 * 1024


def proxy_buffered_get(host: str, port: int, path: str, injected_user: str,
                       timeout: float = 10.0, max_body: int = MAX_BUFFERED_BODY_BYTES):
    """GET one of ttyd's ordinary (non-upgrade) endpoints and return
    (status, [(header, value)], body).

    Nothing of the client's request is forwarded except the path -- no
    `Authorization`, no `Cookie`, no `X-API-Key`, no client-supplied
    `X-WEBAUTH-USER`. The proxy speaks to ttyd on its own behalf; the client's
    authority was already established by the ticket it burned to get here.

    Raises HandshakeError on a malformed path or an oversized body, OSError on
    a transport failure. Both become a 502 at the caller -- ttyd's own error
    text is never relayed.
    """
    if not path.startswith('/') or not _header_value_is_safe(path):
        raise HandshakeError("upstream path failed validation")
    if not injected_user or not _header_value_is_safe(injected_user):
        raise HandshakeError("injected auth-header value failed validation")

    import http.client  # local import: only the buffered routes need it

    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request('GET', path, headers={
            'Host': f'{host}:{port}',
            # Non-empty is the entire requirement -- ttyd 407s on a MISSING or
            # EMPTY value alike, and validates the content not at all.
            'X-WEBAUTH-USER': injected_user,
            'Accept': '*/*',
            'Connection': 'close',
        })
        resp = conn.getresponse()
        body = resp.read(max_body + 1)
        if len(body) > max_body:
            raise HandshakeError("upstream body exceeded cap")
        headers = [(name, resp.getheader(name))
                   for name in BUFFERED_RESPONSE_HEADERS
                   if resp.getheader(name)]
        return resp.status, headers, body
    finally:
        try:
            conn.close()
        except OSError:
            pass


def read_upstream_head(sock, max_bytes: int = MAX_UPSTREAM_HEAD_BYTES, timeout: float = 10.0):
    """Read ttyd's response head. Returns (head_bytes, status_code, residue).

    `residue` is whatever arrived after the blank line -- the first WebSocket
    frames, if ttyd was quick. It MUST be forwarded to the client after the
    head or the pane loses its opening bytes; that is the mirror image of the
    client-side buffered-`rfile` trap (evaluation §6.5 item 2).
    """
    sock.settimeout(timeout)
    buf = b''
    while b'\r\n\r\n' not in buf:
        if len(buf) > max_bytes:
            raise HandshakeError("upstream response head exceeded cap")
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            raise HandshakeError("upstream response head timed out")
        if not chunk:
            raise HandshakeError("upstream closed before completing the response head")
        buf += chunk
    head, _, residue = buf.partition(b'\r\n\r\n')
    head += b'\r\n\r\n'
    first_line = head.split(b'\r\n', 1)[0].decode('latin-1', 'replace')
    parts = first_line.split(' ')
    try:
        status = int(parts[1])
    except (IndexError, ValueError):
        raise HandshakeError(f"unparseable upstream status line: {first_line!r}")
    return head, status, residue


def connect_upstream(host: str, port: int, timeout: float = 5.0):
    """TCP connect to a ttyd. Raises OSError on failure -- the caller turns
    that into a 502 rather than leaking the reason to the client."""
    return socket.create_connection((host, port), timeout=timeout)


# ---------------------------------------------------------------------------
# The byte pump
# ---------------------------------------------------------------------------

def drain_buffered_reader(sock, rfile, chunk: int = 65536) -> bytes:
    """Return bytes already sitting in `rfile`'s buffer, without blocking.

    EVALUATION §6.5 ITEM 2 -- THE LATENT ONE. `StreamRequestHandler` hands the
    handler a buffered `rfile`; when a client pipelines bytes immediately after
    its handshake, those bytes are consumed off the socket by the header
    `readline()` and parked in the BufferedReader. `select()` on the RAW socket
    cannot see them, so the pump would block forever on data it already holds,
    or drop it.

    The drain works by putting the raw socket in non-blocking mode for exactly
    one `read1()`. Measured on CPython 3.14.5 (see
    tests/test_xaca0161_terminal_bridge.py::TestBufferedResidueDrain, which
    pins this behaviour rather than trusting it): with the socket non-blocking,
    `BufferedReader.read1()` returns the buffered bytes when the buffer holds
    any, and returns `b''` -- NOT an exception -- when it does not. Both
    branches are handled anyway, because this is the one place where being
    wrong is silent.
    """
    if rfile is None:
        return b''
    previous_timeout = None
    try:
        previous_timeout = sock.gettimeout()
    except OSError:
        pass
    try:
        sock.setblocking(False)
    except OSError:
        return b''
    try:
        data = rfile.read1(chunk)
        return data or b''
    except (BlockingIOError, InterruptedError):
        return b''
    except OSError as exc:
        if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
            return b''
        return b''
    except ValueError:
        # rfile already closed.
        return b''
    finally:
        try:
            sock.setblocking(True)
            if previous_timeout is not None:
                sock.settimeout(previous_timeout)
        except OSError:
            pass


def _shutdown_write(sock):
    """Half-close the write side (evaluation §6.5 item 7). Without this a peer
    never learns the other end is done and the pane sits in CLOSE_WAIT, leaking
    the thread the session cap exists to bound."""
    try:
        sock.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def _sendall(sock, data) -> bool:
    try:
        sock.sendall(data)
        return True
    except OSError:
        return False


def pump(client_sock, upstream_sock, initial_to_upstream: bytes = b'',
         initial_to_client: bytes = b'', idle_timeout=None, chunk: int = 65536):
    """Relay bytes between the hijacked client socket and ttyd until both ends
    close. Returns (bytes_client_to_upstream, bytes_upstream_to_client, reason).

    ONE thread, not two (evaluation §6.5 item 3). A reader thread per direction
    would double the per-pane thread cost on a server whose unbounded thread
    creation is already a recorded open issue; `select()` costs one.

    BOTH sockets get `settimeout(None)` first -- evaluation §6.5 item 1.

    CORRECTION TO §6.5 ITEM 1, MEASURED RATHER THAN INFERRED. The evaluation
    predicts (tagged [I]) that the inherited `LCARSHandler.timeout` (env
    `LCARS_SOCKET_TIMEOUT`, default 30s, applied to every connection by
    `StreamRequestHandler.setup()`) kills an IDLE pane after 30 seconds of no
    keystrokes. That is true of a naive blocking-`recv()` pump. It is NOT true
    of this one, and the difference was measured, not reasoned: a socket
    timeout does not fire while the thread is parked in `select()` -- it bites
    only a blocking `recv()`/`sendall()` call. A `select()`-gated `recv()`
    never blocks, so idleness alone never trips it. (Verified directly:
    `select([sock],[],[],5)` on a 2s-timeout socket returns after the full 5s
    with the socket still healthy.)

    So clearing the timeout is still REQUIRED, but for a different failure
    than the document predicts, and one that is worse because it is
    load-dependent: BACKPRESSURE. When a client stops draining -- an iPad on a
    weak link, a backgrounded PWA (§7.2), a burst of terminal output -- the
    client's receive window fills and `sendall()` blocks. With the inherited
    timeout still in place that raises after 30s and the pane is torn down
    mid-stream, intermittently, under exactly the conditions that make it
    hardest to reproduce. `settimeout(None)` is what stops that.

    `idle_timeout` then supplies the explicit teardown the threat model asks
    for (§6.5), measuring silence in BOTH directions via `select()`'s own
    timeout argument -- which does work.

    ONE MORE MEASURED FACT, because it will otherwise be misdiagnosed as a
    proxy bug: ttyd 1.7.7 (libwebsockets 5.0) runs its own validity check,
    logged as `lws_validity_cb: VALIDITY TIMEOUT EXPIRED ... (ping=5,
    hangup=10)`. It PINGs every 5s and closes the connection if no PONG
    arrives within 10s. A browser answers PING at the protocol layer with no
    application code involved, and this relay passes PING/PONG through
    untouched -- but any non-browser client (a test harness, a probe) that
    does not answer will be hung up on after ~10s and the symptom looks
    exactly like the proxy dropping the pane. A first pass at the idle soak
    for this subitem failed for precisely that reason.

    The same fact is why `idle_timeout` can safely sit at an hour: while ttyd
    is alive the connection is never traffic-free for more than ~5 seconds.
    """
    client_sock.settimeout(None)
    upstream_sock.settimeout(None)

    reason = 'closed'
    c2u = 0
    u2c = 0

    if initial_to_client and not _sendall(client_sock, initial_to_client):
        return c2u, u2c, 'client-write-failed'
    u2c += len(initial_to_client)

    if initial_to_upstream:
        if not _sendall(upstream_sock, initial_to_upstream):
            return c2u, u2c, 'upstream-write-failed'
        c2u += len(initial_to_upstream)

    client_open = True
    upstream_open = True

    while client_open or upstream_open:
        watch = []
        if client_open:
            watch.append(client_sock)
        if upstream_open:
            watch.append(upstream_sock)
        if not watch:
            break
        try:
            readable, _writable, errored = select.select(watch, [], watch, idle_timeout)
        except (OSError, ValueError):
            reason = 'select-failed'
            break
        if not readable and not errored:
            reason = 'idle-timeout'
            break
        if errored:
            reason = 'socket-error'
            break
        for sock in readable:
            try:
                data = sock.recv(chunk)
            except (ConnectionResetError, TimeoutError):
                data = b''
            except OSError:
                data = b''
            if sock is client_sock:
                if not data:
                    client_open = False
                    _shutdown_write(upstream_sock)
                    continue
                c2u += len(data)
                if not _sendall(upstream_sock, data):
                    reason = 'upstream-write-failed'
                    client_open = upstream_open = False
                    break
            else:
                if not data:
                    upstream_open = False
                    _shutdown_write(client_sock)
                    continue
                u2c += len(data)
                if not _sendall(client_sock, data):
                    reason = 'client-write-failed'
                    client_open = upstream_open = False
                    break
    return c2u, u2c, reason


# ---------------------------------------------------------------------------
# CLI -- one canonical port formula, callable from shell (XACA-0161-002)
# ---------------------------------------------------------------------------

def _cli(argv) -> int:
    """`python3 lcars_terminal.py port --board <path> --lcars-port N [--terminal NAME]`

    Exists so the launchd/startup work in XACA-0161-002 derives ports from THIS
    function rather than reimplementing the arithmetic in shell. Two
    implementations of a port formula is two implementations that drift, and a
    drifted shell copy would start ttyd on a port the proxy never dials.
    """
    if len(argv) < 2 or argv[1] not in ('port', 'ports'):
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        print("usage: lcars_terminal.py port --board <board.json> --lcars-port <N> "
              "[--terminal <name>]", file=sys.stderr)
        return 2

    args = argv[2:]
    opts = {}
    i = 0
    while i < len(args):
        if args[i].startswith('--') and i + 1 < len(args):
            opts[args[i][2:]] = args[i + 1]
            i += 2
        else:
            print(f"unrecognised argument: {args[i]}", file=sys.stderr)
            return 2

    board_path = opts.get('board')
    if not board_path:
        print("--board is required", file=sys.stderr)
        return 2
    try:
        lcars_port = int(opts.get('lcars-port', ''))
    except ValueError:
        print("--lcars-port must be an integer", file=sys.stderr)
        return 2

    try:
        with open(board_path, 'r', encoding='utf-8') as handle:
            board = json.load(handle)
    except (OSError, ValueError) as exc:
        print(f"could not read board {board_path}: {exc}", file=sys.stderr)
        return 1

    board_terminals = board.get('terminals', {}) if isinstance(board, dict) else {}
    wanted = opts.get('terminal')
    try:
        if wanted:
            print(resolve_ttyd_port(lcars_port, board_terminals, wanted))
        else:
            for name in terminal_names(board_terminals):
                print(f"{name} {resolve_ttyd_port(lcars_port, board_terminals, name)}")
    except TerminalConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(_cli(sys.argv))
