#!/usr/bin/env python3

#
#  test_xaca0387_post_body_cap.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Regression tests for XACA-0387 (audit F-04-008) — POST Content-Length cap and
socket timeout on the LCARS server's do_POST.

Tests cover:
  1. LCARSHandler.timeout class attribute defaults to 30.
  2. MAX_POST_BODY_BYTES module constant defaults to 50 MiB.
  3. POST with Content-Length > MAX_POST_BODY_BYTES → HTTP 413 (body-cap guard).
  4. POST with Content-Length == MAX_POST_BODY_BYTES → guard passes (accepted).
  5. POST with a malformed (non-numeric) Content-Length → HTTP 400.
  6. POST with a negative Content-Length → HTTP 400.
  7. POST with no Content-Length header → guard skips, proceeds to dispatch.

Run with:
    python3 -m pytest lcars-ui/tests/test_xaca0387_post_body_cap.py -v
  or from the repo root:
    python3 -m unittest discover -s lcars-ui/tests -p 'test_*.py'
"""

import io
import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Bootstrap: import server.py with heavy optional deps stubbed out.
# Matches the pattern established in test_alert_endpoints.py.
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
from server import LCARSHandler, MAX_POST_BODY_BYTES  # noqa: E402


# ---------------------------------------------------------------------------
# Helper: build a mock LCARSHandler (mirrors test_alert_endpoints.py pattern)
# ---------------------------------------------------------------------------

def _make_post_handler(path="/api/toggle-collapsed", body=b"", headers=None):
    """Construct an LCARSHandler with all socket I/O mocked for a POST."""
    rfile = io.BytesIO(body)
    response_buf = io.BytesIO()

    with patch.object(LCARSHandler, "__init__", lambda self, *a, **kw: None):
        handler = LCARSHandler.__new__(LCARSHandler)

    handler.path = path
    handler.command = "POST"
    handler.rfile = rfile
    handler.wfile = response_buf
    handler.server = MagicMock()
    # Default headers dict; callers may override Content-Length
    handler.headers = {"Content-Type": "application/json"}
    if headers is not None:
        handler.headers = headers
    handler.requestline = f"POST {path} HTTP/1.1"
    handler.client_address = ("127.0.0.1", 9999)
    handler._headers_buffer = []
    handler._response_code = None

    def _send_response(code, message=None):
        handler._response_code = code

    def _send_header(name, value):
        handler._headers_buffer.append((name, value))

    def _end_headers():
        pass

    handler.send_response = _send_response
    handler.send_header = _send_header
    handler.end_headers = _end_headers
    handler.send_error = MagicMock()
    handler.log_message = MagicMock()
    handler.log_error = MagicMock()

    # XACA-0952-002: _auth_gate() (XACA-0395) is the mandatory first
    # statement of do_POST — it 401s before this guard (or anything else in
    # do_POST) runs whenever the machine running the suite has a real
    # resolvable API key (e.g. ~/.aiteamforge/api-key) and this mock request
    # carries no credential. These tests exist to exercise the
    # Content-Length guard specifically, not auth, so bypass it here rather
    # than depend on the machine's auth posture being "open" for these
    # assertions to mean what they say.
    handler._auth_gate = lambda: True

    return handler, response_buf


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestXACA0387Constants(unittest.TestCase):
    """Verify module-level constant and class attribute are set to sane defaults."""

    def test_max_post_body_bytes_default(self):
        """MAX_POST_BODY_BYTES should default to 50 MiB when env var is absent."""
        # Ensure we're testing the default, not a polluted env
        env_copy = os.environ.copy()
        env_copy.pop('LCARS_MAX_POST_BODY_BYTES', None)
        expected = 50 * 1024 * 1024
        # The constant was evaluated at import time; just verify the value.
        self.assertEqual(MAX_POST_BODY_BYTES, expected,
                         f"Expected {expected} (50 MiB), got {MAX_POST_BODY_BYTES}")

    def test_lcars_handler_timeout_default(self):
        """LCARSHandler.timeout should default to 30 seconds."""
        # Evaluated at class-definition time from env var; verify the value.
        self.assertEqual(LCARSHandler.timeout, 30,
                         f"Expected timeout=30, got {LCARSHandler.timeout}")


class TestXACA0387ContentLengthCap(unittest.TestCase):
    """Integration tests: do_POST Content-Length guard fires before dispatch."""

    def _response_json(self, buf):
        buf.seek(0)
        raw = buf.read()
        return json.loads(raw) if raw else {}

    def test_oversized_content_length_returns_413(self):
        """A POST with Content-Length just over the cap must return HTTP 413."""
        oversized = MAX_POST_BODY_BYTES + 1
        handler, buf = _make_post_handler(
            headers={"Content-Length": str(oversized),
                     "Content-Type": "application/json"},
        )
        # The guard fires before any body read; no real payload needed.
        handler.do_POST()
        self.assertEqual(handler._response_code, 413,
                         "Expected HTTP 413 for oversized Content-Length")
        body = self._response_json(buf)
        self.assertIn("error", body)
        self.assertIn("too large", body["error"].lower())

    def test_exact_cap_content_length_passes_guard(self):
        """A POST with Content-Length == MAX_POST_BODY_BYTES must not return 413."""
        handler, buf = _make_post_handler(
            headers={"Content-Length": str(MAX_POST_BODY_BYTES),
                     "Content-Type": "application/json"},
        )
        handler.do_POST()
        # Guard passes; handler proceeds to dispatch and may return any non-413 code
        self.assertNotEqual(handler._response_code, 413,
                            "Exact-cap Content-Length should not be rejected")

    def test_malformed_content_length_returns_400(self):
        """A POST with a non-numeric Content-Length must return HTTP 400."""
        handler, buf = _make_post_handler(
            headers={"Content-Length": "abc",
                     "Content-Type": "application/json"},
        )
        handler.do_POST()
        self.assertEqual(handler._response_code, 400,
                         "Expected HTTP 400 for malformed Content-Length")
        body = self._response_json(buf)
        self.assertIn("error", body)

    def test_negative_content_length_returns_400(self):
        """A POST with a negative Content-Length must return HTTP 400."""
        handler, buf = _make_post_handler(
            headers={"Content-Length": "-1",
                     "Content-Type": "application/json"},
        )
        handler.do_POST()
        self.assertEqual(handler._response_code, 400,
                         "Expected HTTP 400 for negative Content-Length")
        body = self._response_json(buf)
        self.assertIn("error", body)

    def test_no_content_length_skips_guard(self):
        """A POST with no Content-Length header bypasses the guard without error."""
        handler, buf = _make_post_handler(
            headers={"Content-Type": "application/json"},
        )
        handler.do_POST()
        # Guard skips; 413 and 400 must NOT be returned
        self.assertNotIn(handler._response_code, (400, 413),
                         "No Content-Length should not trigger the guard (got "
                         f"{handler._response_code})")


if __name__ == "__main__":
    unittest.main()
