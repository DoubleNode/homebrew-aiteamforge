#!/usr/bin/env python3

#
#  test_xaca0401_cors_origin.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Regression tests for XACA-0401 (audit F-05-002, and the CORS half of the
F-04-002 cross-ref) — replacement of `Access-Control-Allow-Origin: *` with a
validated, echoed same-origin value.

Tests cover:
  1. _resolve_cors_origin() accepts a same-origin request.
  2. _resolve_cors_origin() accepts CROSS-PORT localhost (redirect.html and
     agent-panel-router.html depend on this — they fetch /api/status on the
     API port from a page served on a different port).
  3. _resolve_cors_origin() refuses a foreign origin.
  4. _resolve_cors_origin() refuses the DNS-rebinding shape (Origin and Host
     agree with each other but name neither this machine nor this server).
  5. _resolve_cors_origin() refuses header-injection payloads (CR/LF).
  6. _resolve_cors_origin() returns None (omit) when there is no Origin.
  7. It NEVER returns '*' for any input, including hostile ones.
  8. _send_cors_headers() emits ACAO + `Vary: Origin` together, or nothing.
  9. do_OPTIONS does not advertise mutating verbs to an unvalidated origin.
 10. SOURCE GUARD: no executable `send_header('Access-Control-Allow-Origin',
     '*')` survives anywhere in server.py. This is the test that fails if a
     future edit reintroduces the wildcard.
 11. SOURCE GUARD: serve_auth_key() still sends NO ACAO header at all — its
     absence is load-bearing (see the block comment on _origin_matches_host).

Run with:
    python3 -m pytest lcars-ui/tests/test_xaca0401_cors_origin.py -v
  or from the repo root:
    python3 -m unittest discover -s lcars-ui/tests -p 'test_*.py'
"""

import io
import re
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Bootstrap: import server.py with heavy optional deps stubbed out.
# Matches the pattern established in test_alert_endpoints.py /
# test_xaca0387_post_body_cap.py.
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

import server  # noqa: E402
from server import LCARSHandler, _resolve_cors_origin  # noqa: E402

SERVER_SOURCE = (LCARS_UI_DIR / "server.py").read_text()


def _make_handler(host=None, origin=None, path="/api/status", command="OPTIONS"):
    """Construct an LCARSHandler with header/socket I/O mocked."""
    with patch.object(LCARSHandler, "__init__", lambda self, *a, **kw: None):
        handler = LCARSHandler.__new__(LCARSHandler)

    headers = {}
    if host is not None:
        headers["Host"] = host
    if origin is not None:
        headers["Origin"] = origin

    handler.path = path
    handler.command = command
    handler.headers = headers
    handler.rfile = io.BytesIO(b"")
    handler.wfile = io.BytesIO()
    handler.server = MagicMock()
    handler._headers_buffer = []
    handler._response_code = None

    handler.send_response = lambda code, message=None: setattr(
        handler, "_response_code", code)
    handler.send_header = lambda name, value: handler._headers_buffer.append(
        (name, value))
    handler.end_headers = lambda: None
    handler.log_message = MagicMock()
    handler.log_error = MagicMock()
    return handler


def _header_names(handler):
    return [n for n, _ in handler._headers_buffer]


def _header_value(handler, name):
    for n, v in handler._headers_buffer:
        if n.lower() == name.lower():
            return v
    return None


class TestResolveCorsOrigin(unittest.TestCase):
    """Unit coverage for the resolver itself."""

    def test_same_origin_is_echoed(self):
        self.assertEqual(
            _resolve_cors_origin("localhost:8203", "http://localhost:8203"),
            "http://localhost:8203")

    def test_cross_port_localhost_is_allowed(self):
        """redirect.html:164 and agent-panel-router.html:97 fetch
        /api/status on the API port from a page on a DIFFERENT port. If this
        ever fails, both of those pages silently stop working."""
        self.assertEqual(
            _resolve_cors_origin("localhost:8203", "http://localhost:8210"),
            "http://localhost:8210")

    def test_ip_literal_is_allowed(self):
        self.assertEqual(
            _resolve_cors_origin("127.0.0.1:8203", "http://127.0.0.1:8203"),
            "http://127.0.0.1:8203")

    def test_foreign_origin_is_refused(self):
        self.assertIsNone(
            _resolve_cors_origin("localhost:8203", "http://evil.example"))

    def test_dns_rebinding_shape_is_refused(self):
        """Origin and Host agree with each other, but name neither this
        machine nor this server. _origin_matches_host() alone cannot catch
        this; the local-identity requirement is what does."""
        self.assertIsNone(
            _resolve_cors_origin("evil.example:8203", "http://evil.example:8203"))

    def test_missing_origin_omits_header(self):
        self.assertIsNone(_resolve_cors_origin("localhost:8203", None))
        self.assertIsNone(_resolve_cors_origin("localhost:8203", ""))

    def test_header_injection_is_refused(self):
        for payload in (
            "http://localhost:8203\r\nX-Injected: 1",
            "http://localhost:8203\nX-Injected: 1",
            'http://localhost:8203"',
            "http://localhost:8203 http://evil.example",
        ):
            with self.subTest(payload=payload):
                self.assertIsNone(
                    _resolve_cors_origin("localhost:8203", payload))

    def test_non_http_scheme_is_refused(self):
        for payload in ("file:///etc/passwd", "javascript:alert(1)",
                        "data:text/html,x", "null"):
            with self.subTest(payload=payload):
                self.assertIsNone(
                    _resolve_cors_origin("localhost:8203", payload))

    def test_never_returns_wildcard(self):
        """The whole point of the ticket: no input may produce '*'."""
        hostile = [
            ("localhost:8203", "*"),
            ("*", "*"),
            ("localhost:8203", "http://*"),
            ("evil.example", "*"),
            (None, "*"),
            ("localhost:8203", "http://localhost:8203"),
        ]
        for host, origin in hostile:
            with self.subTest(host=host, origin=origin):
                self.assertNotEqual(_resolve_cors_origin(host, origin), "*")


class TestSendCorsHeaders(unittest.TestCase):
    """The handler-side emitter."""

    def test_emits_acao_and_vary_together(self):
        h = _make_handler(host="localhost:8203", origin="http://localhost:8203")
        h._send_cors_headers()
        self.assertEqual(_header_value(h, "Access-Control-Allow-Origin"),
                         "http://localhost:8203")
        self.assertEqual(_header_value(h, "Vary"), "Origin")

    def test_emits_nothing_when_refused(self):
        h = _make_handler(host="localhost:8203", origin="http://evil.example")
        h._send_cors_headers()
        self.assertEqual(h._headers_buffer, [])

    def test_vary_never_without_acao_and_vice_versa(self):
        """A cached response keyed without Vary could be served to the wrong
        origin, so the two headers must travel together."""
        for host, origin in (("localhost:8203", "http://localhost:8203"),
                             ("localhost:8203", "http://evil.example"),
                             ("localhost:8203", None)):
            with self.subTest(host=host, origin=origin):
                h = _make_handler(host=host, origin=origin)
                h._send_cors_headers()
                names = [n.lower() for n in _header_names(h)]
                self.assertEqual(
                    "access-control-allow-origin" in names,
                    "vary" in names)


class TestPreflightHardening(unittest.TestCase):
    """do_OPTIONS must not advertise mutating verbs to a refused origin."""

    def test_allowed_origin_gets_full_preflight(self):
        h = _make_handler(host="localhost:8203", origin="http://localhost:8203")
        h.do_OPTIONS()
        self.assertEqual(_header_value(h, "Access-Control-Allow-Origin"),
                         "http://localhost:8203")
        methods = _header_value(h, "Access-Control-Allow-Methods")
        self.assertIsNotNone(methods)
        self.assertIn("POST", methods)

    def test_refused_origin_gets_no_methods(self):
        h = _make_handler(host="localhost:8203", origin="http://evil.example")
        h.do_OPTIONS()
        self.assertIsNone(_header_value(h, "Access-Control-Allow-Origin"))
        self.assertIsNone(_header_value(h, "Access-Control-Allow-Methods"))
        self.assertEqual(h._response_code, 200)

    def test_allow_headers_not_widened(self):
        """XACA-0395-007 reverted a widening to Authorization/X-API-Key for a
        documented reason. Keep it pinned to Content-Type."""
        h = _make_handler(host="localhost:8203", origin="http://localhost:8203")
        h.do_OPTIONS()
        self.assertEqual(_header_value(h, "Access-Control-Allow-Headers"),
                         "Content-Type")


class TestSourceGuards(unittest.TestCase):
    """Grep-style guards that fail if a future edit undoes this ticket."""

    WILDCARD_RE = re.compile(
        r"""send_header\(\s*(['"])Access-Control-Allow-Origin\1\s*,\s*(['"])\*\2\s*\)""")

    def test_no_executable_wildcard_acao_remains(self):
        offenders = []
        for lineno, line in enumerate(SERVER_SOURCE.split("\n"), 1):
            stripped = line.strip()
            if stripped.startswith("#") or "`" in line:
                continue  # comment or docstring prose
            if self.WILDCARD_RE.search(line):
                offenders.append(f"{lineno}: {stripped}")
        self.assertEqual(
            offenders, [],
            "Wildcard Access-Control-Allow-Origin reintroduced. Use "
            "self._send_cors_headers() instead:\n" + "\n".join(offenders))

    def test_serve_auth_key_sends_no_acao(self):
        """serve_auth_key()'s ABSENT ACAO is complementary to its Origin
        check, not redundant with it — removing either opens a real gap.
        See the block comment on _origin_matches_host()."""
        m = re.search(r"\n    def serve_auth_key\(self.*?(?=\n    def )",
                      SERVER_SOURCE, re.S)
        self.assertIsNotNone(m, "serve_auth_key() not found — update this test")
        body = m.group(0)
        # Assert on the header EMISSION, not on the word: this handler's
        # docstring discusses Access-Control-Allow-Origin at length precisely
        # to explain why it is absent, so a substring check would fail on the
        # documentation that protects the behaviour.
        for lineno, line in enumerate(body.split("\n"), 1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            self.assertNotRegex(
                stripped,
                r"""self\.send_header\(\s*['"]Access-Control-Allow-Origin['"]""",
                f"serve_auth_key() gained an ACAO header at relative line {lineno}: "
                f"{stripped}")
            self.assertNotIn(
                "self._send_cors_headers()", stripped,
                f"serve_auth_key() must not call the shared CORS emitter "
                f"(relative line {lineno})")

    def test_resolver_is_actually_wired(self):
        """A resolver nothing calls is the XACA-0297 failure mode."""
        self.assertGreater(SERVER_SOURCE.count("self._send_cors_headers()"), 40)


if __name__ == "__main__":
    unittest.main(verbosity=2)
