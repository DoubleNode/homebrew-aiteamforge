#!/usr/bin/env python3

#
#  test_xaca0161_terminal_bridge.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""XACA-0161-003 — tests for the LCARS terminal discovery + WebSocket proxy.

WHAT THESE TESTS ARE FOR. The route under test hands out an interactive,
writable, root-equivalent shell. Per docs/xaca-0161-threat-model.md §1.2 it is
the highest-severity surface this repository will have shipped, and per
docs/xaca-0161-terminal-bridge-evaluation.md §5 it lands on `do_GET`, the one
dispatch path in server.py with no authentication at all. So these are not
"does the feature work" tests. The load-bearing ones are the REFUSALS:

  * an unauthenticated upgrade must be refused,
  * a ticket must work exactly once,
  * with no API key configured the route must 503 rather than serve
    (the deliberate divergence from _auth_gate()'s fail-open),
  * nothing under /terminal/ may ever reach the static file server.

The proxy is exercised end to end against a REAL socket: a real LCARS server
on a throwaway port, a fake ttyd on the derived port, and a raw client socket
speaking a real upgrade. No mock stands in for the hijack — evaluation §5.1
records that this codebase has no streaming or raw-socket precedent anywhere,
so a mocked pump would be testing an idea rather than the code.

Run with:
    python3 -m pytest lcars-ui/tests/test_xaca0161_terminal_bridge.py -q
"""

import base64
import http.client
import io
import json
import os
import socket
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Bootstrap: import server.py without launching a server or touching real dirs.
# Mirrors test_xaca0161_bind_control.py's bootstrap exactly.
# ---------------------------------------------------------------------------

LCARS_UI_DIR = Path(__file__).parent.parent
REPO_ROOT = LCARS_UI_DIR.parent
sys.path.insert(0, str(LCARS_UI_DIR))
sys.path.insert(0, str(REPO_ROOT))

_stub_modules = {
    "kanban_utils": MagicMock(
        log_activity=MagicMock(),
        read_activity_log=MagicMock(return_value={"entries": [], "itemId": ""}),
        get_lcars_tmp_dir=MagicMock(return_value="/tmp/"),
    ),
    "integrations": MagicMock(),
    "calendar": MagicMock(),
    "calendar.sync_service": MagicMock(),
    "calendar.apple_provider": MagicMock(),
    "calendar.provider": MagicMock(),
}
for _mod_name, _stub in _stub_modules.items():
    if _mod_name not in sys.modules:
        sys.modules[_mod_name] = _stub

import http.server  # noqa: E402

import lcars_terminal  # noqa: E402
import server  # noqa: E402

TEST_API_KEY = "xaca0161-test-key-not-a-real-credential"

BOARD_FIXTURE = {
    "terminals": {
        # Deliberately NOT in sorted order on disk — terminal_names() must sort,
        # or every derived ttyd port would depend on hand-edit order.
        "training": {"avatar": "thok", "role": "Cadet Master", "color": "science"},
        "chancellor": {"avatar": "nahla", "role": "Chancellor", "color": "command"},
        "medical": {"avatar": "emh", "role": "Training Officer", "color": "medical"},
        "engineering": {"avatar": "reno", "role": "Chief Technical Instructor",
                        "color": "operations"},
    }
}
# sorted() order: chancellor(0) engineering(1) medical(2) training(3)


# ===========================================================================
# Pure-unit tests — port derivation
# ===========================================================================

class TestPortDerivation(unittest.TestCase):

    def test_formula_is_documented_arithmetic(self):
        """Pins the SHARED contract with XACA-0161-002's launchd work:
        21000 + (lcars_port - 8000) * 16 + index, index = position in the
        board's terminals map sorted by name. Academy = 8203."""
        self.assertEqual(lcars_terminal.TTYD_PORT_BASE, 21000)
        self.assertEqual(lcars_terminal.MAX_TERMINALS_PER_TEAM, 16)
        self.assertEqual(lcars_terminal.ttyd_port_for(8203, 0), 21000 + 203 * 16)
        self.assertEqual(lcars_terminal.ttyd_port_for(8203, 1), 24249)

    def test_no_two_team_terminal_pairs_collide(self):
        """The only property that actually matters: a collision would attach
        one team's pane to another team's shell."""
        seen = {}
        for port in range(8000, 9000):
            for index in range(lcars_terminal.MAX_TERMINALS_PER_TEAM):
                derived = lcars_terminal.ttyd_port_for(port, index)
                self.assertNotIn(derived, seen,
                                 f"{(port, index)} collides with {seen.get(derived)}")
                seen[derived] = (port, index)

    def test_derived_ports_stay_below_the_ephemeral_floor(self):
        """macOS allocates ephemeral ports from 49152. A derived port at or
        above that could be stolen by an outbound connection."""
        highest = lcars_terminal.ttyd_port_for(8999, lcars_terminal.MAX_TERMINALS_PER_TEAM - 1)
        self.assertLess(highest, 49152)
        self.assertGreater(lcars_terminal.ttyd_port_for(8000, 0), 1024)

    def test_lcars_port_outside_band_raises_rather_than_folding(self):
        for bad in (7999, 9000, 0, 65535):
            with self.assertRaises(lcars_terminal.TerminalConfigError):
                lcars_terminal.ttyd_port_for(bad, 0)

    def test_index_outside_block_raises_rather_than_wrapping(self):
        with self.assertRaises(lcars_terminal.TerminalConfigError):
            lcars_terminal.ttyd_port_for(8203, lcars_terminal.MAX_TERMINALS_PER_TEAM)
        with self.assertRaises(lcars_terminal.TerminalConfigError):
            lcars_terminal.ttyd_port_for(8203, -1)

    def test_bool_is_not_an_acceptable_int(self):
        with self.assertRaises(lcars_terminal.TerminalConfigError):
            lcars_terminal.ttyd_port_for(True, 0)

    def test_terminal_names_are_sorted_not_insertion_ordered(self):
        self.assertEqual(
            lcars_terminal.terminal_names(BOARD_FIXTURE["terminals"]),
            ["chancellor", "engineering", "medical", "training"])

    def test_terminal_names_drops_unsafe_names(self):
        names = lcars_terminal.terminal_names({
            "ok": {}, "../etc": {}, "with space": {}, "semi;colon": {}, "": {},
        })
        self.assertEqual(names, ["ok"])

    def test_resolve_refuses_a_name_not_on_the_board(self):
        with self.assertRaises(lcars_terminal.TerminalConfigError):
            lcars_terminal.resolve_ttyd_port(8203, BOARD_FIXTURE["terminals"], "ops")

    def test_resolve_matches_index_order(self):
        self.assertEqual(
            lcars_terminal.resolve_ttyd_port(8203, BOARD_FIXTURE["terminals"], "engineering"),
            lcars_terminal.ttyd_port_for(8203, 1))


# ===========================================================================
# Pure-unit tests — ticket store
# ===========================================================================

class _Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class TestTicketStore(unittest.TestCase):

    def setUp(self):
        self.clock = _Clock()
        self.store = lcars_terminal.TicketStore(
            server._auth_safe_equal, ttl_provider=lambda: 30, clock=self.clock)

    def test_ticket_is_high_entropy_and_url_safe(self):
        ticket, ttl = self.store.mint("engineering")
        self.assertEqual(ttl, 30)
        self.assertRegex(ticket, r'^[A-Za-z0-9_-]+$')
        # token_urlsafe(32) -> 43 chars. Threat model §6.1 requires >= 32 bytes.
        self.assertGreaterEqual(len(ticket), 43)

    def test_two_mints_never_collide(self):
        tickets = {self.store.mint("engineering")[0] for _ in range(200)}
        self.assertEqual(len(tickets), 200)

    def test_valid_ticket_is_accepted_exactly_once(self):
        ticket, _ = self.store.mint("engineering")
        self.assertTrue(self.store.redeem(ticket, "engineering"))
        self.assertFalse(self.store.redeem(ticket, "engineering"),
                         "a redeemed ticket must never be accepted a second time")

    def test_expired_ticket_is_refused(self):
        ticket, _ = self.store.mint("engineering")
        self.clock.now += 31
        self.assertFalse(self.store.redeem(ticket, "engineering"))

    def test_ticket_is_bound_to_one_terminal(self):
        ticket, _ = self.store.mint("engineering")
        self.assertFalse(self.store.redeem(ticket, "medical"))

    def test_wrong_terminal_still_burns_the_ticket(self):
        """A confused or hostile client must not get a second attempt with the
        right name after learning the first was wrong."""
        ticket, _ = self.store.mint("engineering")
        self.assertFalse(self.store.redeem(ticket, "medical"))
        self.assertFalse(self.store.redeem(ticket, "engineering"))

    def test_unknown_and_malformed_tickets_are_refused(self):
        self.store.mint("engineering")
        for bad in ("", None, 42, "short", "x" * 500, "has spaces", "has/slash",
                    "../../etc/passwd"):
            self.assertFalse(self.store.redeem(bad, "engineering"), repr(bad))

    def test_mint_refuses_an_unsafe_terminal_name(self):
        for bad in ("../etc", "a b", "", None, 7):
            with self.assertRaises(lcars_terminal.TerminalConfigError):
                self.store.mint(bad)

    def test_store_is_bounded(self):
        store = lcars_terminal.TicketStore(
            server._auth_safe_equal, ttl_provider=lambda: 30,
            max_outstanding=8, clock=self.clock)
        for _ in range(100):
            store.mint("engineering")
        self.assertLessEqual(store.outstanding(), 8)

    def test_expired_tickets_are_purged(self):
        for _ in range(5):
            self.store.mint("engineering")
        self.assertEqual(self.store.outstanding(), 5)
        self.clock.now += 31
        self.assertEqual(self.store.outstanding(), 0)

    def test_redeem_uses_the_injected_constant_time_comparator(self):
        """The comparator is injected precisely so there is exactly ONE
        credential-comparison primitive in the codebase. Pin that it is used —
        a `==` slipped in later would pass every other test in this class."""
        calls = []

        def spy(a, b):
            calls.append((a, b))
            return server._auth_safe_equal(a, b)

        store = lcars_terminal.TicketStore(spy, ttl_provider=lambda: 30, clock=self.clock)
        ticket, _ = store.mint("engineering")
        self.assertTrue(store.redeem(ticket, "engineering"))
        self.assertTrue(calls, "redeem() bypassed the injected comparator")


class TestSessionLimiter(unittest.TestCase):

    def test_cap_is_enforced_and_slots_are_returned(self):
        limiter = lcars_terminal.SessionLimiter(cap_provider=lambda: 2)
        self.assertTrue(limiter.acquire())
        self.assertTrue(limiter.acquire())
        self.assertFalse(limiter.acquire())
        limiter.release()
        self.assertTrue(limiter.acquire())

    def test_release_never_goes_negative(self):
        limiter = lcars_terminal.SessionLimiter(cap_provider=lambda: 1)
        for _ in range(5):
            limiter.release()
        self.assertEqual(limiter.active, 0)
        self.assertTrue(limiter.acquire())

    def test_acquire_does_not_block_at_the_cap(self):
        """A semaphore would block here and pin the very thread the cap
        exists to protect."""
        limiter = lcars_terminal.SessionLimiter(cap_provider=lambda: 1)
        limiter.acquire()
        started = time.monotonic()
        self.assertFalse(limiter.acquire())
        self.assertLess(time.monotonic() - started, 0.5)


# ===========================================================================
# Pure-unit tests — upstream handshake construction
# ===========================================================================

class _Headers(dict):
    """Case-insensitive .get(), like email.message.Message."""

    def get(self, key, default=None):
        for k, v in self.items():
            if k.lower() == key.lower():
                return v
        return default


def _upgrade_headers(**extra):
    base = _Headers({
        'Host': '127.0.0.1:8203',
        'Upgrade': 'websocket',
        'Connection': 'Upgrade',
        'Sec-WebSocket-Key': base64.b64encode(b'0123456789abcdef').decode(),
        'Sec-WebSocket-Version': '13',
    })
    base.update(extra)
    return base


class TestUpgradeDetection(unittest.TestCase):

    def test_well_formed_upgrade_is_recognised(self):
        self.assertTrue(lcars_terminal.is_websocket_upgrade(_upgrade_headers()))

    def test_case_and_multi_token_connection_are_tolerated(self):
        self.assertTrue(lcars_terminal.is_websocket_upgrade(
            _upgrade_headers(Upgrade='WebSocket', Connection='keep-alive, Upgrade')))

    def test_plain_get_is_not_an_upgrade(self):
        self.assertFalse(lcars_terminal.is_websocket_upgrade(_Headers({'Host': 'x'})))

    def test_missing_pieces_are_refused(self):
        self.assertFalse(lcars_terminal.is_websocket_upgrade(
            _upgrade_headers(Connection='keep-alive')))
        h = _upgrade_headers()
        del h['Sec-WebSocket-Key']
        self.assertFalse(lcars_terminal.is_websocket_upgrade(h))
        self.assertFalse(lcars_terminal.is_websocket_upgrade(
            _upgrade_headers(Upgrade='h2c')))


class TestUpstreamHandshake(unittest.TestCase):

    def build(self, headers, path='/terminal/engineering/ws'):
        return lcars_terminal.build_upstream_handshake(
            path, headers, '127.0.0.1', 21625, 'lcars').decode('latin-1')

    def test_injects_the_webauth_header(self):
        self.assertIn('X-WEBAUTH-USER: lcars', self.build(_upgrade_headers()))

    def test_client_supplied_webauth_header_is_never_forwarded(self):
        """ttyd performs NO validation of X-WEBAUTH-USER (evaluation §3.1) —
        forwarding a client's copy would let the client authenticate itself."""
        out = self.build(_upgrade_headers(**{'X-WEBAUTH-USER': 'attacker'}))
        self.assertNotIn('attacker', out)
        self.assertEqual(out.count('X-WEBAUTH-USER'), 1)

    def test_lcars_credentials_are_never_relayed_upstream(self):
        out = self.build(_upgrade_headers(**{
            'Authorization': 'Bearer ' + TEST_API_KEY,
            'X-API-Key': TEST_API_KEY,
            'Cookie': 'session=secret',
        }))
        self.assertNotIn(TEST_API_KEY, out)
        self.assertNotIn('Cookie', out)
        self.assertNotIn('Authorization', out)

    def test_websocket_headers_are_forwarded(self):
        headers = _upgrade_headers(**{'Sec-WebSocket-Protocol': 'tty'})
        out = self.build(headers)
        self.assertIn('Upgrade: websocket', out)
        self.assertIn('Sec-WebSocket-Protocol: tty', out)
        self.assertIn(headers.get('Sec-WebSocket-Key'), out)

    def test_crlf_in_a_forwarded_value_is_refused_not_stripped(self):
        """Header injection: the request is built by concatenation, so a CRLF
        would let a client add its own X-WEBAUTH-USER."""
        with self.assertRaises(lcars_terminal.HandshakeError):
            self.build(_upgrade_headers(**{
                'Sec-WebSocket-Protocol': 'tty\r\nX-WEBAUTH-USER: attacker'}))

    def test_unsafe_path_is_refused(self):
        for bad in ('terminal/x/ws', '/terminal/x/ws\r\nX: y', '/a\nb'):
            with self.assertRaises(lcars_terminal.HandshakeError):
                self.build(_upgrade_headers(), path=bad)

    def test_host_header_names_the_upstream_not_the_client(self):
        out = self.build(_upgrade_headers(Host='evil.example.com'))
        self.assertIn('Host: 127.0.0.1:21625', out)
        self.assertNotIn('evil.example.com', out)


class TestPostureDefaults(unittest.TestCase):
    """The env knobs must default to the SAFE end, and a typo must never
    widen anything."""

    def setUp(self):
        self._saved = {k: os.environ.get(k) for k in (
            'LCARS_TERMINAL_ENABLED', 'LCARS_TERMINAL_MAX_SESSIONS',
            'LCARS_TERMINAL_TICKET_TTL', 'LCARS_TERMINAL_IDLE_TIMEOUT',
            'LCARS_TERMINAL_TTYD_HOST', 'LCARS_TERMINAL_WEBAUTH_USER')}
        for key in self._saved:
            os.environ.pop(key, None)

    def tearDown(self):
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_feature_is_off_unless_explicitly_enabled(self):
        self.assertFalse(lcars_terminal.terminal_enabled())
        for truthy_looking in ('true', 'yes', 'on', '0', 'TRUE', ' 1 '):
            os.environ['LCARS_TERMINAL_ENABLED'] = truthy_looking
            if truthy_looking.strip() == '1':
                continue
            self.assertFalse(lcars_terminal.terminal_enabled(), truthy_looking)
        os.environ['LCARS_TERMINAL_ENABLED'] = '1'
        self.assertTrue(lcars_terminal.terminal_enabled())

    def test_session_cap_default_and_bounds(self):
        self.assertEqual(lcars_terminal.max_sessions(), 4)
        for bad in ('0', '-5', '9999', 'lots', ''):
            os.environ['LCARS_TERMINAL_MAX_SESSIONS'] = bad
            self.assertEqual(lcars_terminal.max_sessions(), 4, bad)

    def test_ticket_ttl_default_is_the_evaluation_ceiling(self):
        self.assertEqual(lcars_terminal.ticket_ttl_seconds(), 30)
        os.environ['LCARS_TERMINAL_TICKET_TTL'] = '99999'
        self.assertEqual(lcars_terminal.ticket_ttl_seconds(), 30)

    def test_idle_timeout_is_far_above_the_inherited_socket_timeout(self):
        """Evaluation §6.5 item 1 — 30s would kill idle panes on day one."""
        self.assertGreater(lcars_terminal.idle_timeout_seconds(),
                           int(os.environ.get('LCARS_SOCKET_TIMEOUT', '30')) * 10)

    def test_ttyd_host_cannot_be_pointed_off_the_loopback(self):
        for attempt in ('10.0.0.5', 'evil.example.com', '0.0.0.0', '100.95.180.109'):
            os.environ['LCARS_TERMINAL_TTYD_HOST'] = attempt
            self.assertEqual(lcars_terminal.ttyd_host(), '127.0.0.1', attempt)

    def test_webauth_user_is_shape_validated(self):
        os.environ['LCARS_TERMINAL_WEBAUTH_USER'] = 'bad value\r\ninjected'
        self.assertEqual(lcars_terminal.webauth_user(), 'lcars')


# ===========================================================================
# The buffered-rfile drain (evaluation §6.5 item 2)
# ===========================================================================

class TestBufferedResidueDrain(unittest.TestCase):
    """PINS the platform behaviour drain_buffered_reader() depends on.

    StreamRequestHandler hands the handler a BufferedReader. Bytes a client
    pipelines after its handshake are pulled off the socket by the header
    readline() and parked in that buffer, where select() on the RAW socket
    cannot see them. This test stands up a real HTTP server and a real client
    that pipelines, then asserts the drain both (a) returns those bytes and
    (b) does NOT block when there are none — which is the half that silently
    wedges a thread if it is wrong.
    """

    def _run(self, pipelined: bytes):
        captured = {}
        done = threading.Event()

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            timeout = 5

            def do_GET(inner):
                started = time.monotonic()
                captured['residue'] = lcars_terminal.drain_buffered_reader(
                    inner.connection, inner.rfile)
                captured['elapsed'] = time.monotonic() - started
                inner.send_response(200)
                inner.send_header('Content-Length', '2')
                inner.end_headers()
                inner.wfile.write(b'ok')
                inner.close_connection = True
                done.set()

            def log_message(inner, *args):
                pass

        srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            sock = socket.create_connection(('127.0.0.1', srv.server_address[1]), timeout=5)
            sock.sendall(b'GET / HTTP/1.1\r\nHost: x\r\n\r\n' + pipelined)
            done.wait(timeout=5)
            sock.close()
        finally:
            srv.shutdown()
            srv.server_close()
        return captured

    def test_pipelined_bytes_are_recovered(self):
        captured = self._run(b'PIPELINED-PAYLOAD')
        self.assertEqual(captured.get('residue'), b'PIPELINED-PAYLOAD')

    def test_drain_returns_immediately_when_nothing_is_buffered(self):
        captured = self._run(b'')
        self.assertEqual(captured.get('residue'), b'')
        self.assertLess(captured.get('elapsed', 99), 1.0,
                        "drain blocked on an empty buffer — this is the wedge")

    def test_drain_restores_the_socket_to_blocking_mode(self):
        """The pump that follows assumes blocking sendall(). Leaving the socket
        non-blocking would turn every large write into a partial one."""
        modes = {}

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            timeout = 5

            def do_GET(inner):
                lcars_terminal.drain_buffered_reader(inner.connection, inner.rfile)
                modes['timeout'] = inner.connection.gettimeout()
                inner.send_response(200)
                inner.send_header('Content-Length', '2')
                inner.end_headers()
                inner.wfile.write(b'ok')
                inner.close_connection = True

            def log_message(inner, *args):
                pass

        srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        srv.RequestHandlerClass.timeout = 7
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            conn = http.client.HTTPConnection('127.0.0.1', srv.server_address[1], timeout=5)
            conn.request('GET', '/')
            conn.getresponse().read()
            conn.close()
        finally:
            srv.shutdown()
            srv.server_close()
        # Non-blocking is gettimeout() == 0.0; the drain must not leave it there.
        self.assertNotEqual(modes.get('timeout'), 0.0)


# ===========================================================================
# End-to-end: real LCARS server + fake ttyd + raw client socket
# ===========================================================================

class TestPumpClearsTheInheritedTimeout(unittest.TestCase):
    """EVALUATION §6.5 ITEM 1, and a correction to it.

    The evaluation predicts (tagged [I]) that a hijacked socket's inherited
    LCARS_SOCKET_TIMEOUT kills an IDLE pane after 30s. Measured, that is false
    for a select()-driven pump: a socket timeout does not fire while the thread
    is parked in select(); it bites only a blocking recv()/sendall(). The real
    casualty is BACKPRESSURE — a client that stops draining makes sendall()
    block, and the inherited timeout then tears the pane down mid-stream.

    These two tests exist because the end-to-end "idle pane survives" test
    CANNOT detect a regression here: it passes whether or not the timeout is
    cleared, precisely because idleness never trips it. A test that passes
    against the broken code proves nothing, so the mechanism is pinned
    directly instead.
    """

    def test_socket_timeouts_are_inherited_in_the_first_place(self):
        """NEGATIVE CONTROL for the pair below — if StreamRequestHandler did
        not actually apply LCARSHandler.timeout to the connection, clearing it
        would be a no-op and both tests would be theatre."""
        import socketserver
        self.assertIsNotNone(server.LCARSHandler.timeout)
        self.assertIn('settimeout',
                      socketserver.StreamRequestHandler.setup.__code__.co_names)

    def test_pump_clears_both_socket_timeouts(self):
        client, client_peer = socket.socketpair()
        upstream, upstream_peer = socket.socketpair()
        self.addCleanup(client.close)
        self.addCleanup(upstream.close)
        client.settimeout(2)
        upstream.settimeout(2)
        # Both peers gone -> pump sees EOF on both sides and returns at once.
        client_peer.close()
        upstream_peer.close()

        lcars_terminal.pump(client, upstream)

        self.assertIsNone(client.gettimeout(),
                          "client socket kept the inherited timeout")
        self.assertIsNone(upstream.gettimeout(),
                          "upstream socket kept the inherited timeout")

    def test_a_stalled_client_does_not_kill_the_pane(self):
        """The failure the inherited timeout actually causes.

        The client stops reading; the upstream keeps writing until the client's
        receive window fills and the pump's sendall() blocks. With the
        inherited 1s timeout still in force that raises and the relay tears
        down, losing data. With it cleared, sendall() simply waits and every
        byte arrives once the client drains.
        """
        client, client_peer = socket.socketpair()
        upstream, upstream_peer = socket.socketpair()
        for sock in (client, client_peer, upstream, upstream_peer):
            self.addCleanup(sock.close)
        client.settimeout(1)
        upstream.settimeout(1)

        payload = b'x' * (4 * 1024 * 1024)
        result = {}

        def blast():
            try:
                upstream_peer.sendall(payload)
                upstream_peer.shutdown(socket.SHUT_WR)
            except OSError:
                pass

        def relay():
            result['counts'] = lcars_terminal.pump(client, upstream, idle_timeout=30)

        threading.Thread(target=blast, daemon=True).start()
        relay_thread = threading.Thread(target=relay, daemon=True)
        relay_thread.start()

        # Stall well past the inherited timeout before draining a single byte.
        time.sleep(3)

        received = 0
        client_peer.settimeout(20)
        while received < len(payload):
            try:
                chunk = client_peer.recv(1 << 20)
            except (socket.timeout, TimeoutError, OSError):
                break
            if not chunk:
                break
            received += len(chunk)
        # Half-close from the client so the pump's loop can unwind; without
        # this it correctly keeps waiting on a still-open peer.
        try:
            client_peer.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        relay_thread.join(timeout=20)

        self.assertEqual(
            received, len(payload),
            f"only {received} of {len(payload)} bytes survived a 3s client "
            f"stall — the inherited socket timeout was not cleared")
        self.assertEqual(result.get('counts', (0, 0, ''))[2], 'closed')


class FakeTtyd:
    """Stands in for `ttyd -b /terminal/<name>/ws`.

    Records the exact handshake it received (so tests can assert what the proxy
    did and did NOT forward), answers 101, then echoes everything back with a
    marker so the pump can be observed in both directions.
    """

    INDEX_BODY = b'<!DOCTYPE html><html><head><title>ttyd</title></head><body></body></html>'
    TOKEN_BODY = b'{"token": ""}'

    def __init__(self, port, status=101, echo_prefix=b'>'):
        self.port = port
        self.status = status
        self.echo_prefix = echo_prefix
        self.received_heads = []
        self.connections = 0
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(('127.0.0.1', port))
        self._sock.listen(8)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def start(self):
        self._thread.start()
        return self

    def _serve(self):
        self._sock.settimeout(0.25)
        while not self._stop.is_set():
            try:
                conn, _addr = self._sock.accept()
            except (socket.timeout, TimeoutError):
                continue
            except OSError:
                break
            self.connections += 1
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        try:
            conn.settimeout(10)
            head = b''
            while b'\r\n\r\n' not in head and len(head) < 65536:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                head += chunk
            head_part, _, residue = head.partition(b'\r\n\r\n')
            text = head_part.decode('latin-1')
            self.received_heads.append(text)

            lowered = text.lower()
            if 'upgrade: websocket' not in lowered:
                # Buffered (non-upgrade) endpoint. Reproduce the measured
                # behaviour of real ttyd 1.7.7 under `-H X-WEBAUTH-USER`:
                # 407 when the header is absent OR present-but-empty, 200
                # otherwise. Verified live on 2026-08-26 before this fixture
                # was written — see the subitem's verification notes.
                user = ''
                for line in text.split('\r\n')[1:]:
                    name, _, value = line.partition(':')
                    if name.strip().lower() == 'x-webauth-user':
                        user = value.strip()
                if not user:
                    conn.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\n"
                                 b"Content-Length: 0\r\nConnection: close\r\n\r\n")
                    conn.close()
                    return
                body = self.TOKEN_BODY if '/token' in text.split(' ')[1] else self.INDEX_BODY
                ctype = 'application/json' if body is self.TOKEN_BODY else 'text/html'
                conn.sendall(
                    f"HTTP/1.1 200 OK\r\nContent-Type: {ctype}\r\n"
                    f"Server: ttyd-fixture-version-banner\r\n"
                    f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
                    + body)
                conn.close()
                return

            if self.status != 101:
                conn.sendall(
                    f"HTTP/1.1 {self.status} Forbidden\r\n"
                    "Content-Length: 22\r\n\r\nttyd-internal-detail!!".encode())
                conn.close()
                return
            conn.sendall(
                b"HTTP/1.1 101 Switching Protocols\r\n"
                b"Upgrade: websocket\r\n"
                b"Connection: Upgrade\r\n"
                b"Sec-WebSocket-Accept: fake-accept-value\r\n"
                b"Sec-WebSocket-Protocol: tty\r\n\r\n")
            if residue:
                conn.sendall(self.echo_prefix + residue)
            conn.settimeout(None)
            while True:
                data = conn.recv(65536)
                if not data:
                    break
                conn.sendall(self.echo_prefix + data)
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def stop(self):
        self._stop.set()
        try:
            self._sock.close()
        except OSError:
            pass


def _port_is_free(port):
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        probe.bind(('127.0.0.1', port))
        return True
    except OSError:
        return False
    finally:
        probe.close()


def _pick_lcars_port():
    """A throwaway LCARS port inside the derivation band whose whole derived
    ttyd block is also free.

    8600-8998 is deliberately above every port in this fleet's
    ~/.aiteamforge/team-paths.json (highest measured: 8405), so a test run can
    never bind over a live team dashboard.
    """
    for candidate in range(8600, 8999):
        if not _port_is_free(candidate):
            continue
        block = [lcars_terminal.ttyd_port_for(candidate, i)
                 for i in range(lcars_terminal.MAX_TERMINALS_PER_TEAM)]
        if all(_port_is_free(p) for p in block):
            return candidate
    # A hard error, NOT unittest.SkipTest. XACA-0952's lcars-ui gate reconciles
    # `passed + xfailed == collected`, so a skip here would fail that gate with
    # a misleading message; and "no free port in a 399-wide band" is a real
    # environment fault worth surfacing loudly rather than quietly skipping the
    # entire end-to-end half of this suite.
    raise RuntimeError("no free LCARS/ttyd port pair available in 8600-8998")


class TerminalBridgeServerCase(unittest.TestCase):
    """Stands up a REAL LCARSHandler server on a throwaway port in the
    derivation band, with a temp board and a controllable API-key posture."""

    api_key = TEST_API_KEY
    enabled = True

    @classmethod
    def setUpClass(cls):
        cls.lcars_port = _pick_lcars_port()

        cls._tmpdir = tempfile.TemporaryDirectory()
        board_path = Path(cls._tmpdir.name) / "academy-board.json"
        board_path.write_text(json.dumps(BOARD_FIXTURE), encoding='utf-8')
        cls.board_path = board_path

        cls._patches = [
            patch.object(server, 'get_board_file', lambda team: board_path),
            patch.object(server, 'LCARS_TEAM', 'academy'),
            # This dev machine HAS a real ~/.aiteamforge/api-key. Popping the
            # env var alone therefore does NOT produce the "no key configured"
            # posture — the loader falls through to the file and the
            # fail-closed test passes vacuously against a machine that happens
            # to be keyed (and, first time round, printed that key into the
            # assertion message). Point the loader at a path that cannot
            # exist, so the posture under test is the posture in force.
            patch.object(server, 'AITEAMFORGE_API_KEY_FILE',
                         Path(cls._tmpdir.name) / 'no-such-api-key'),
        ]
        for p in cls._patches:
            p.start()

        cls._saved_env = {k: os.environ.get(k) for k in (
            'LCARS_TERMINAL_ENABLED', 'AITEAMFORGE_API_KEY',
            'LCARS_TERMINAL_MAX_SESSIONS', 'LCARS_TERMINAL_IDLE_TIMEOUT')}
        os.environ['LCARS_TERMINAL_ENABLED'] = '1' if cls.enabled else '0'
        if cls.api_key:
            os.environ['AITEAMFORGE_API_KEY'] = cls.api_key
        else:
            os.environ.pop('AITEAMFORGE_API_KEY', None)
        server._reset_resolved_api_key_cache_for_tests()

        # The handler's own resolved key must also be re-read; the cache is
        # process-wide and other test files may have populated it.
        cls.httpd = http.server.ThreadingHTTPServer(
            ('127.0.0.1', cls.lcars_port), server.LCARSHandler)
        cls.httpd.daemon_threads = True
        cls._serve_thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls._serve_thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        for p in cls._patches:
            p.stop()
        for key, value in cls._saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        server._reset_resolved_api_key_cache_for_tests()
        cls._tmpdir.cleanup()

    # -- helpers ----------------------------------------------------------

    def http(self):
        return http.client.HTTPConnection('127.0.0.1', self.lcars_port, timeout=10)

    def get_json(self, path, headers=None):
        conn = self.http()
        try:
            conn.request('GET', path, headers=headers or {})
            resp = conn.getresponse()
            body = resp.read()
            return resp.status, body
        finally:
            conn.close()

    def mint(self, terminal, key=None, expect=200):
        conn = self.http()
        try:
            headers = {'Content-Type': 'application/json'}
            if key is not False:
                headers['X-API-Key'] = key or self.api_key
            conn.request('POST', '/api/terminal/ticket',
                         body=json.dumps({"terminal": terminal}), headers=headers)
            resp = conn.getresponse()
            body = resp.read()
            self.assertEqual(resp.status, expect, body)
            return json.loads(body) if resp.status == 200 else body
        finally:
            conn.close()

    def open_ws(self, terminal, ticket=None, pipelined=b'', extra_headers=(), timeout=10):
        """Raw client upgrade. Returns (socket, first_response_chunk)."""
        sock = socket.create_connection(('127.0.0.1', self.lcars_port), timeout=timeout)
        query = f"?ticket={ticket}" if ticket else ""
        lines = [
            f"GET /terminal/{terminal}/ws{query} HTTP/1.1",
            f"Host: 127.0.0.1:{self.lcars_port}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: " + base64.b64encode(b'0123456789abcdef').decode(),
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Protocol: tty",
        ]
        lines.extend(extra_headers)
        sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode() + pipelined)
        sock.settimeout(timeout)
        try:
            first = sock.recv(65536)
        except (socket.timeout, TimeoutError):
            first = b''
        return sock, first


class TestTerminalBridgeRefusals(TerminalBridgeServerCase):
    """The load-bearing half: everything that must NOT get a shell."""

    def test_unauthenticated_upgrade_with_no_ticket_is_refused(self):
        sock, first = self.open_ws('engineering', ticket=None)
        sock.close()
        self.assertTrue(first.startswith(b'HTTP/1.0 401') or first.startswith(b'HTTP/1.1 401'),
                        f"expected 401, got: {first[:120]!r}")
        self.assertNotIn(b'101 Switching Protocols', first)

    def test_forged_ticket_is_refused(self):
        sock, first = self.open_ws('engineering', ticket='A' * 43)
        sock.close()
        self.assertIn(b' 401 ', first[:40])

    def test_ticket_from_another_terminal_is_refused(self):
        minted = self.mint('medical')
        sock, first = self.open_ws('engineering', ticket=minted['ticket'])
        sock.close()
        self.assertIn(b' 401 ', first[:40])

    def test_expired_ticket_is_refused(self):
        minted = self.mint('engineering')
        with patch.object(lcars_terminal, 'ticket_ttl_seconds', lambda: 30):
            # Advance the store's clock by redeeming after the TTL. Rather than
            # sleeping 30s, reach into the store and age the entry.
            with server._TERMINAL_TICKETS._lock:
                for ticket in list(server._TERMINAL_TICKETS._tickets):
                    term, _exp = server._TERMINAL_TICKETS._tickets[ticket]
                    server._TERMINAL_TICKETS._tickets[ticket] = (term, time.monotonic() - 1)
        sock, first = self.open_ws('engineering', ticket=minted['ticket'])
        sock.close()
        self.assertIn(b' 401 ', first[:40])

    def test_unknown_terminal_is_refused_without_dialling_anything(self):
        sock, first = self.open_ws('nosuchterminal', ticket='A' * 43)
        sock.close()
        self.assertIn(b' 404 ', first[:40])

    def test_plain_get_on_the_ws_route_is_refused(self):
        status, _body = self.get_json(f'/terminal/engineering/ws')
        self.assertEqual(status, 400)

    def test_mint_requires_the_api_key(self):
        body = self.mint('engineering', key=False, expect=401)
        self.assertNotIn(b'ticket', body)

    def test_mint_rejects_a_wrong_api_key(self):
        self.mint('engineering', key='wrong-key-entirely', expect=401)

    def test_mint_refuses_an_unknown_terminal(self):
        self.mint('nosuchterminal', expect=404)

    def test_mint_refuses_a_traversal_shaped_name(self):
        conn = self.http()
        try:
            conn.request('POST', '/api/terminal/ticket',
                         body=json.dumps({"terminal": "../../etc/passwd"}),
                         headers={'X-API-Key': self.api_key})
            resp = conn.getresponse()
            resp.read()
            self.assertEqual(resp.status, 400)
        finally:
            conn.close()

    def test_discovery_is_gated(self):
        status, body = self.get_json('/api/terminals')
        self.assertEqual(status, 401, body)
        self.assertNotIn(b'ttydPort', body)

    def test_discovery_rejects_a_wrong_key(self):
        status, _ = self.get_json('/api/terminals', headers={'X-API-Key': 'nope'})
        self.assertEqual(status, 401)

    def test_discovery_succeeds_with_the_key(self):
        status, body = self.get_json('/api/terminals', headers={'X-API-Key': self.api_key})
        self.assertEqual(status, 200, body)
        payload = json.loads(body)
        names = [t['name'] for t in payload['terminals']]
        self.assertEqual(names, ['chancellor', 'engineering', 'medical', 'training'])
        engineering = next(t for t in payload['terminals'] if t['name'] == 'engineering')
        self.assertEqual(engineering['ttydPort'],
                         lcars_terminal.ttyd_port_for(self.lcars_port, 1))
        self.assertEqual(engineering['wsPath'], '/terminal/engineering/ws')

    def test_cross_origin_upgrade_is_refused(self):
        """Threat model §6.3 — browsers DO send Origin on an upgrade, so this
        is the check that stops a foreign page opening a shell socket."""
        minted = self.mint('engineering')
        sock, first = self.open_ws(
            'engineering', ticket=minted['ticket'],
            extra_headers=['Origin: http://evil.example.com'])
        sock.close()
        self.assertIn(b' 403 ', first[:40])

    def test_upstream_absent_yields_502_not_a_hang(self):
        """No ttyd is listening in this test class."""
        minted = self.mint('engineering')
        started = time.monotonic()
        sock, first = self.open_ws('engineering', ticket=minted['ticket'])
        sock.close()
        self.assertIn(b' 502 ', first[:40])
        self.assertLess(time.monotonic() - started, 8)

    def test_502_does_not_leak_upstream_detail(self):
        minted = self.mint('engineering')
        sock, first = self.open_ws('engineering', ticket=minted['ticket'])
        sock.close()
        self.assertNotIn(b'Connection refused', first)
        self.assertNotIn(b'Errno', first)


class TestStaticFallbackShadowing(TerminalBridgeServerCase):
    """Evaluation §6.5 item 5 — LCARSHandler extends SimpleHTTPRequestHandler,
    whose do_GET serves files from disk. Nothing under /terminal/ may reach it."""

    def test_terminal_prefix_never_reaches_the_static_file_server(self):
        for path in (
            '/terminal/',
            '/terminal/engineering',
            '/terminal/engineering/',
            '/terminal/engineering/index.html',
            '/terminal/engineering/ws/extra',
            '/terminal/../server.py',
            '/terminal/engineering/../../server.py',
            '/terminal/%2e%2e/server.py',
        ):
            status, body = self.get_json(path)
            self.assertNotEqual(status, 200, f"{path} served content: {body[:200]!r}")
            self.assertNotIn(b'lcars_terminal', body, path)
            self.assertNotIn(b'import http.server', body, path)

    def test_head_on_a_terminal_path_is_405_not_a_file_probe(self):
        conn = self.http()
        try:
            conn.request('HEAD', '/terminal/engineering/ws')
            resp = conn.getresponse()
            resp.read()
            self.assertEqual(resp.status, 405)
        finally:
            conn.close()


class TestFailClosedWithoutAnApiKey(TerminalBridgeServerCase):
    """Evaluation §5 conclusion 3 / §6.4 item 3 — the deliberate divergence
    from _auth_gate()'s open posture. An unauthenticated shell is not an
    acceptable degraded mode."""

    api_key = None

    def test_ws_route_returns_503_and_refuses_to_serve(self):
        sock, first = self.open_ws('engineering', ticket='A' * 43)
        sock.close()
        self.assertIn(b' 503 ', first[:40])
        self.assertNotIn(b'101 Switching Protocols', first)

    def test_mint_returns_503(self):
        body = self.mint('engineering', key=False, expect=503)
        self.assertIn(b'API key', body)

    def test_discovery_returns_503(self):
        status, body = self.get_json('/api/terminals')
        self.assertEqual(status, 503)
        self.assertNotIn(b'ttydPort', body)

    def test_the_baseline_auth_gate_really_is_open_in_this_posture(self):
        """NEGATIVE CONTROL for the test above. If the ambient posture were
        somehow still authenticated, the 503s would prove nothing — they could
        be the ordinary gate refusing. This pins that _auth_gate() genuinely
        returns True here, i.e. the rest of the server IS open and only the
        terminal routes are closed."""
        key, _rejected = server._get_resolved_api_key()
        # NOT assertFalse(key, ...) — unittest renders the offending value into
        # the failure message, which would print a real API key into CI logs
        # the first time this ever fails. Assert on the boolean instead.
        self.assertTrue(not key, "test setup failed: a key is still configured")


class TestFeatureDisabledByDefault(TerminalBridgeServerCase):
    enabled = False

    def test_a_refused_post_still_delivers_its_response_body(self):
        """REGRESSION, found as a ~1-in-6 flake in this very suite.

        A refusal that answers without first reading the request body leaves
        unread bytes in the socket; macOS then answers the connection close
        with an RST instead of a FIN, and the client raises
        ConnectionResetError while reading a response the server had already
        written correctly. The caller sees "connection reset" —
        indistinguishable from a crash — instead of the 404/503 that explains
        what happened.

        A large body makes the race deterministic: with the drain removed this
        resets every time; with it in place the status always arrives.
        """
        body = json.dumps({"terminal": "engineering", "pad": "x" * 200000})
        conn = self.http()
        try:
            conn.request('POST', '/api/terminal/ticket', body=body,
                         headers={'Content-Type': 'application/json',
                                  'X-API-Key': self.api_key})
            resp = conn.getresponse()
            resp.read()
            self.assertEqual(resp.status, 404)
        except ConnectionResetError as exc:
            self.fail(f"refusal was lost to a connection reset: {exc} — the "
                      f"request body was not drained before responding")
        finally:
            conn.close()

    def test_routes_are_404_when_not_enabled(self):
        sock, first = self.open_ws('engineering', ticket='A' * 43)
        sock.close()
        self.assertIn(b' 404 ', first[:40])
        status, _ = self.get_json('/api/terminals', headers={'X-API-Key': self.api_key})
        self.assertEqual(status, 404)
        self.mint('engineering', expect=404)


class TestTerminalBridgeProxy(TerminalBridgeServerCase):
    """The happy path — with a real fake-ttyd on the derived port."""

    def setUp(self):
        self.ttyd_port = lcars_terminal.ttyd_port_for(self.lcars_port, 1)  # engineering
        self.ttyd = FakeTtyd(self.ttyd_port).start()
        self.addCleanup(self.ttyd.stop)

    def test_valid_ticket_upgrades_and_relays_bytes_both_ways(self):
        minted = self.mint('engineering')
        sock, first = self.open_ws('engineering', ticket=minted['ticket'])
        self.addCleanup(sock.close)
        self.assertIn(b'101 Switching Protocols', first)
        # The 101 is relayed VERBATIM from ttyd — no Server:/Date: line that
        # send_response() would have added (evaluation §6.5 item 6).
        self.assertIn(b'Sec-WebSocket-Accept: fake-accept-value', first)
        self.assertNotIn(b'Server: ', first)
        self.assertNotIn(b'Date: ', first)

        sock.sendall(b'hello-terminal')
        echoed = sock.recv(65536)
        self.assertEqual(echoed, b'>hello-terminal')

    def test_a_ticket_is_accepted_once_and_rejected_on_reuse(self):
        minted = self.mint('engineering')
        sock1, first1 = self.open_ws('engineering', ticket=minted['ticket'])
        self.addCleanup(sock1.close)
        self.assertIn(b'101 Switching Protocols', first1)

        sock2, first2 = self.open_ws('engineering', ticket=minted['ticket'])
        sock2.close()
        self.assertIn(b' 401 ', first2[:40])
        self.assertNotIn(b'101 Switching Protocols', first2)

    def test_pipelined_bytes_survive_the_hijack(self):
        """Evaluation §6.5 item 2 — the latent one. Bytes sent in the SAME
        segment as the handshake sit in rfile's buffer, invisible to select()."""
        minted = self.mint('engineering')
        sock, first = self.open_ws('engineering', ticket=minted['ticket'],
                                   pipelined=b'EARLY-BYTES')
        self.addCleanup(sock.close)
        self.assertIn(b'101 Switching Protocols', first)
        deadline = time.monotonic() + 5
        seen = first
        while b'>EARLY-BYTES' not in seen and time.monotonic() < deadline:
            try:
                chunk = sock.recv(65536)
            except (socket.timeout, TimeoutError):
                break
            if not chunk:
                break
            seen += chunk
        self.assertIn(b'>EARLY-BYTES', seen,
                      "pipelined bytes were dropped by the hijack")

    def test_the_proxied_handshake_carries_the_injected_auth_header(self):
        minted = self.mint('engineering')
        sock, _ = self.open_ws('engineering', ticket=minted['ticket'])
        self.addCleanup(sock.close)
        head = self.ttyd.received_heads[-1]
        self.assertIn('X-WEBAUTH-USER: lcars', head)
        self.assertIn('GET /terminal/engineering/ws HTTP/1.1', head)

    def test_the_ticket_is_never_forwarded_upstream(self):
        minted = self.mint('engineering')
        sock, _ = self.open_ws('engineering', ticket=minted['ticket'])
        self.addCleanup(sock.close)
        head = self.ttyd.received_heads[-1]
        self.assertNotIn(minted['ticket'], head)
        self.assertNotIn('?', head.split('\r\n')[0])

    def test_the_api_key_is_never_forwarded_upstream(self):
        minted = self.mint('engineering')
        sock, _ = self.open_ws(
            'engineering', ticket=minted['ticket'],
            extra_headers=[f'X-API-Key: {self.api_key}',
                           f'Authorization: Bearer {self.api_key}'])
        self.addCleanup(sock.close)
        head = self.ttyd.received_heads[-1]
        self.assertNotIn(self.api_key, head)

    def test_a_client_supplied_webauth_header_is_stripped(self):
        minted = self.mint('engineering')
        sock, _ = self.open_ws('engineering', ticket=minted['ticket'],
                               extra_headers=['X-WEBAUTH-USER: attacker'])
        self.addCleanup(sock.close)
        head = self.ttyd.received_heads[-1]
        self.assertNotIn('attacker', head)
        self.assertEqual(head.count('X-WEBAUTH-USER'), 1)

    def test_session_slot_is_released_when_a_pane_closes(self):
        for _ in range(6):  # more than the default cap of 4
            minted = self.mint('engineering')
            sock, first = self.open_ws('engineering', ticket=minted['ticket'])
            self.assertIn(b'101 Switching Protocols', first)
            sock.close()
            # Give the pump a moment to notice the half-close and unwind.
            deadline = time.monotonic() + 5
            while server._TERMINAL_SESSIONS.active > 0 and time.monotonic() < deadline:
                time.sleep(0.05)
        self.assertEqual(server._TERMINAL_SESSIONS.active, 0)

    def test_concurrent_session_cap_is_enforced(self):
        """Evaluation §6.5 item 3 — each pane pins a thread for its lifetime."""
        cap = lcars_terminal.max_sessions()
        held = []
        self.addCleanup(lambda: [s.close() for s in held])
        for _ in range(cap):
            minted = self.mint('engineering')
            sock, first = self.open_ws('engineering', ticket=minted['ticket'])
            held.append(sock)
            self.assertIn(b'101 Switching Protocols', first)

        minted = self.mint('engineering')
        sock, first = self.open_ws('engineering', ticket=minted['ticket'])
        sock.close()
        self.assertIn(b' 503 ', first[:40])
        self.assertNotIn(b'101 Switching Protocols', first)

    def test_upstream_refusal_is_not_relayed_to_the_client(self):
        self.ttyd.stop()
        refusing = FakeTtyd(self.ttyd_port, status=403).start()
        self.addCleanup(refusing.stop)
        minted = self.mint('engineering')
        sock, first = self.open_ws('engineering', ticket=minted['ticket'])
        sock.close()
        self.assertIn(b' 502 ', first[:40])
        self.assertNotIn(b'ttyd-internal-detail', first)


class TestIdleTimeoutIsNotInherited(TerminalBridgeServerCase):
    """End-to-end: an idle pane outlives the inherited LCARS_SOCKET_TIMEOUT.

    This is the property the subitem asks to be demonstrated, and it is a real
    end-to-end assertion — but READ THIS BEFORE TRUSTING IT AS A REGRESSION
    GUARD: it does NOT discriminate a pump that forgot `settimeout(None)`.
    Measured, a socket timeout does not fire while the thread is parked in
    `select()`, so an idle select()-gated pane survives either way. Deleting
    the `settimeout(None)` lines leaves this class green.

    The mechanism is pinned by TestPumpClearsTheInheritedTimeout above, which
    does go red under that mutation. Keep both: this one proves the observable
    behaviour the feature promises, that one proves the code that will still be
    needed when a client stalls.

    The handler timeout is patched DOWN to 2s so the class costs ~6s rather
    than 30+ in CI; set LCARS_TERMINAL_SOAK_SECONDS to idle for longer.
    """

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls._saved_timeout = server.LCARSHandler.timeout
        server.LCARSHandler.timeout = 2

    @classmethod
    def tearDownClass(cls):
        server.LCARSHandler.timeout = cls._saved_timeout
        super().tearDownClass()

    def test_the_inherited_timeout_is_genuinely_short_in_this_class(self):
        """NEGATIVE CONTROL for the survival test below: if the patched-down
        timeout were not actually in force, 'survives 6 seconds' would be a
        vacuous pass. This asserts the setup itself took effect."""
        self.assertEqual(server.LCARSHandler.timeout, 2)

    def test_an_idle_pane_outlives_the_inherited_socket_timeout(self):
        ttyd_port = lcars_terminal.ttyd_port_for(self.lcars_port, 1)
        ttyd = FakeTtyd(ttyd_port).start()
        self.addCleanup(ttyd.stop)

        minted = self.mint('engineering')
        sock, first = self.open_ws('engineering', ticket=minted['ticket'], timeout=60)
        self.addCleanup(sock.close)
        self.assertIn(b'101 Switching Protocols', first)

        idle_for = float(os.environ.get('LCARS_TERMINAL_SOAK_SECONDS',
                                        server.LCARSHandler.timeout * 3))
        time.sleep(idle_for)

        # Still alive: a round trip after the idle period must still work.
        sock.settimeout(10)
        sock.sendall(b'still-here')
        echoed = sock.recv(65536)
        self.assertEqual(
            echoed, b'>still-here',
            f"pane died during {idle_for}s of idling — the inherited "
            f"{server.LCARSHandler.timeout}s LCARS_SOCKET_TIMEOUT was not cleared")


if __name__ == '__main__':
    unittest.main(verbosity=2)


class TestTerminalAssetRoutes(TerminalBridgeServerCase):
    """The two buffered ttyd endpoints.

    These exist because ttyd serves them under `-b /terminal/<name>` and
    because XACA-0161-002 measured — reproduced independently here against
    live ttyd 1.7.7 on 2026-08-26 — that ttyd started with `-H X-WEBAUTH-USER`
    answers **407** on BOTH the index and /token when the header is missing or
    empty. Injecting the header only at the WebSocket upgrade would leave the
    index 407ing, and the page would never load far enough to attempt a socket.

    The FakeTtyd fixture reproduces that 407 behaviour, which is what makes
    `test_index_is_served_with_a_valid_ticket` a real assertion rather than a
    formality: a 200 is only reachable if the proxy actually injected a
    non-empty header.
    """

    def setUp(self):
        self.ttyd_port = lcars_terminal.ttyd_port_for(self.lcars_port, 1)  # engineering
        self.ttyd = FakeTtyd(self.ttyd_port).start()
        self.addCleanup(self.ttyd.stop)

    def get(self, path, ticket=None):
        query = f"?ticket={ticket}" if ticket else ""
        return self.get_json(path + query)

    def test_index_without_a_ticket_is_refused(self):
        status, body = self.get('/terminal/engineering/')
        self.assertEqual(status, 401)
        self.assertNotIn(b'<!DOCTYPE', body)
        self.assertEqual(self.ttyd.connections, 0,
                         "an unticketed request reached ttyd")

    def test_token_without_a_ticket_is_refused(self):
        status, body = self.get('/terminal/engineering/token')
        self.assertEqual(status, 401)
        self.assertNotIn(b'token', body)
        self.assertEqual(self.ttyd.connections, 0)

    def test_index_is_served_with_a_valid_ticket(self):
        minted = self.mint('engineering')
        status, body = self.get('/terminal/engineering/', minted['ticket'])
        self.assertEqual(status, 200, body)
        self.assertIn(b'<!DOCTYPE', body)
        self.assertIn('X-WEBAUTH-USER: lcars', self.ttyd.received_heads[-1])

    def test_token_is_served_with_a_valid_ticket(self):
        minted = self.mint('engineering')
        status, body = self.get('/terminal/engineering/token', minted['ticket'])
        self.assertEqual(status, 200, body)
        self.assertEqual(json.loads(body), {"token": ""})

    def test_asset_tickets_are_single_use_too(self):
        minted = self.mint('engineering')
        status, _ = self.get('/terminal/engineering/', minted['ticket'])
        self.assertEqual(status, 200)
        status, _ = self.get('/terminal/engineering/', minted['ticket'])
        self.assertEqual(status, 401, "an asset ticket survived its first use")

    def test_an_asset_ticket_is_bound_to_its_terminal(self):
        minted = self.mint('medical')
        status, _ = self.get('/terminal/engineering/', minted['ticket'])
        self.assertEqual(status, 401)

    def test_upstream_version_banner_is_not_relayed(self):
        minted = self.mint('engineering')
        conn = self.http()
        try:
            conn.request('GET', f"/terminal/engineering/?ticket={minted['ticket']}")
            resp = conn.getresponse()
            resp.read()
            self.assertEqual(resp.status, 200)
            self.assertNotIn('ttyd-fixture-version-banner', resp.getheader('Server') or '')
            self.assertEqual(resp.getheader('Cache-Control'), 'no-store')
        finally:
            conn.close()

    def test_a_407_from_ttyd_becomes_a_502_and_does_not_leak(self):
        """If the injected header were ever empty, ttyd 407s. That is a server
        misconfiguration, not something to hand the client."""
        minted = self.mint('engineering')
        with patch.object(lcars_terminal, 'webauth_user', lambda: ''):
            status, body = self.get('/terminal/engineering/', minted['ticket'])
        self.assertEqual(status, 502)
        self.assertNotIn(b'407', body)

    def test_the_fixture_really_does_407_without_the_header(self):
        """NEGATIVE CONTROL for this whole class. If FakeTtyd answered 200
        regardless of the header, every 200 above would prove nothing about
        injection. Talk to the fixture directly, header-less, and require the
        407 the real ttyd gives."""
        conn = http.client.HTTPConnection('127.0.0.1', self.ttyd_port, timeout=5)
        try:
            conn.request('GET', '/terminal/engineering/')
            self.assertEqual(conn.getresponse().status, 407)
        finally:
            conn.close()
        conn = http.client.HTTPConnection('127.0.0.1', self.ttyd_port, timeout=5)
        try:
            conn.request('GET', '/terminal/engineering/',
                         headers={'X-WEBAUTH-USER': ''})
            self.assertEqual(conn.getresponse().status, 407,
                             "an EMPTY header must 407 too — measured on real ttyd")
        finally:
            conn.close()

    def test_client_credentials_are_not_relayed_on_the_asset_routes(self):
        minted = self.mint('engineering')
        conn = self.http()
        try:
            conn.request('GET', f"/terminal/engineering/?ticket={minted['ticket']}",
                         headers={'X-API-Key': self.api_key,
                                  'Cookie': 'session=secret',
                                  'X-WEBAUTH-USER': 'attacker'})
            resp = conn.getresponse()
            resp.read()
        finally:
            conn.close()
        head = self.ttyd.received_heads[-1]
        self.assertNotIn(self.api_key, head)
        self.assertNotIn('session=secret', head)
        self.assertNotIn('attacker', head)
        self.assertEqual(head.count('X-WEBAUTH-USER'), 1)

    def test_the_ticket_is_not_forwarded_upstream(self):
        minted = self.mint('engineering')
        self.get('/terminal/engineering/', minted['ticket'])
        head = self.ttyd.received_heads[-1]
        self.assertNotIn(minted['ticket'], head)
        self.assertNotIn('?', head.split('\r\n')[0])
