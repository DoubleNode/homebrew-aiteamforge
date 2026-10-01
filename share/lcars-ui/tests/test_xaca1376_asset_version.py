#!/usr/bin/env python3
"""
XACA-1376 — X-LCARS-Asset-Version fingerprint ("LCARS was updated - reload").

Covers server.compute_asset_version() and the response header on the board-data
and /api/status handlers:
  1. stable for identical content
  2. changes when a ?v= stamp changes
  3. picks up an index.html change with NO restart (mtime/size keyed cache)
  4. ignores non-stamp edits that keep the stamp set identical (order-insensitive)
  5. fail-soft: missing file / no stamps -> None; handler omits header, still 200
  6. header present on /api/status and board data; exposed through CORS

Run with:
    python3 -m pytest lcars-ui/tests/test_xaca1376_asset_version.py -q
"""

import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

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
for _name, _stub in _stub_modules.items():
    if _name not in sys.modules:
        sys.modules[_name] = _stub

# Do NOT set LCARS_TEAM here: `server` is cached in sys.modules, so a value set
# at import leaks into every later test in the same process (it broke
# test_server.TestModuleLevelConfig when run together).
import server  # noqa: E402

HEADER = "X-LCARS-Asset-Version"

HTML_A = (
    '<link rel="stylesheet" href="css/lcars.css?v=1.0">\n'
    '<script src="js/lcars.js?v=2.0"></script>\n'
    '<script src="https://cdn.example.com/x.js?v=9"></script>\n'
)


def _write(path, text, bump_mtime=True):
    """Write text and force a distinct mtime so same-size edits are seen."""
    prev = path.stat().st_mtime_ns if path.exists() else 0
    path.write_text(text, encoding="utf-8")
    if bump_mtime:
        os.utime(path, ns=(prev + 5_000_000_000, prev + 5_000_000_000))


def _make_handler():
    buf = io.BytesIO()
    with patch.object(server.LCARSHandler, "__init__", lambda self, *a, **kw: None):
        h = server.LCARSHandler.__new__(server.LCARSHandler)
    h.path = "/"
    h.command = "GET"
    h.rfile = io.BytesIO(b"")
    h.wfile = buf
    h.server = MagicMock()
    h.headers = {}
    h.client_address = ("127.0.0.1", 9999)
    h._code = None
    h._sent = []
    h.send_response = lambda code, message=None: setattr(h, "_code", code)
    h.send_header = lambda n, v: h._sent.append((n, v))
    h.end_headers = lambda: None
    h.send_error = MagicMock(side_effect=lambda c, m=None: setattr(h, "_code", c))
    h.log_message = MagicMock()
    h.log_error = MagicMock()
    return h, buf


class ComputeAssetVersionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.index = Path(self.tmp.name) / "index.html"
        _write(self.index, HTML_A, bump_mtime=False)

    def test_stable_for_same_content(self):
        a = server.compute_asset_version(self.index)
        b = server.compute_asset_version(self.index)
        self.assertRegex(a, r"^[0-9a-f]{12}$")
        self.assertEqual(a, b)

    def test_changes_when_stamp_changes(self):
        a = server.compute_asset_version(self.index)
        _write(self.index, HTML_A.replace("js/lcars.js?v=2.0", "js/lcars.js?v=2.1"))
        self.assertNotEqual(a, server.compute_asset_version(self.index))

    def test_picks_up_change_without_restart_even_same_size(self):
        a = server.compute_asset_version(self.index)
        # same byte length: 2.0 -> 2.1, only mtime distinguishes the file
        size = self.index.stat().st_size
        _write(self.index, HTML_A.replace("v=2.0", "v=2.1"))
        self.assertEqual(size, self.index.stat().st_size)
        self.assertNotEqual(a, server.compute_asset_version(self.index))

    def test_same_stamps_reordered_or_other_edits_are_stable(self):
        a = server.compute_asset_version(self.index)
        lines = HTML_A.splitlines()
        _write(self.index, "\n".join(reversed(lines)) + "\n<p>other edit</p>\n")
        self.assertEqual(a, server.compute_asset_version(self.index))

    def test_external_urls_ignored(self):
        a = server.compute_asset_version(self.index)
        _write(self.index, HTML_A.replace("x.js?v=9", "x.js?v=10"))
        self.assertEqual(a, server.compute_asset_version(self.index))

    def test_missing_file_returns_none(self):
        self.assertIsNone(server.compute_asset_version(Path(self.tmp.name) / "nope.html"))

    def test_no_stamps_returns_none(self):
        _write(self.index, "<html></html>")
        self.assertIsNone(server.compute_asset_version(self.index))

    def test_real_index_html_yields_value(self):
        self.assertRegex(server.compute_asset_version(LCARS_UI_DIR / "index.html") or "",
                         r"^[0-9a-f]{12}$")


class HandlerHeaderTests(unittest.TestCase):
    def test_status_has_header(self):
        h, _ = _make_handler()
        with patch.object(server, "compute_asset_version", return_value="abc123def456"):
            h.serve_status()
        self.assertEqual(h._code, 200)
        self.assertIn((HEADER, "abc123def456"), h._sent)

    def test_status_omits_header_on_error_but_still_200(self):
        h, buf = _make_handler()
        with patch.object(server, "compute_asset_version", side_effect=RuntimeError("boom")):
            h.serve_status()
        self.assertEqual(h._code, 200)
        self.assertNotIn(HEADER, [n for n, _ in h._sent])
        self.assertEqual(json.loads(buf.getvalue())["status"], "online")

    def test_status_omits_header_when_none(self):
        h, _ = _make_handler()
        with patch.object(server, "compute_asset_version", return_value=None):
            h.serve_status()
        self.assertNotIn(HEADER, [n for n, _ in h._sent])

    def test_board_data_has_header(self):
        with tempfile.TemporaryDirectory() as d:
            board = Path(d) / "x-board.json"
            board.write_text(json.dumps({
                "organization": "O", "teamName": "T", "subtitle": "S", "backlog": [],
            }))
            h, _ = _make_handler()
            with patch.object(server, "get_board_file", return_value=board), \
                 patch.object(server, "get_reconciled_inprogress", return_value=[]), \
                 patch.object(server, "compute_asset_version", return_value="feedfacecafe"):
                h.serve_kanban_data("x")
        self.assertEqual(h._code, 200)
        self.assertIn((HEADER, "feedfacecafe"), h._sent)

    def test_cors_exposes_header_when_origin_allowed(self):
        h, _ = _make_handler()
        with patch.object(server, "_resolve_cors_origin", return_value="http://localhost:1"):
            h._send_cors_headers()
        self.assertIn(("Access-Control-Expose-Headers", HEADER), h._sent)

    def test_cors_refused_origin_exposes_nothing(self):
        h, _ = _make_handler()
        with patch.object(server, "_resolve_cors_origin", return_value=None):
            h._send_cors_headers()
        self.assertNotIn("Access-Control-Expose-Headers", [n for n, _ in h._sent])


if __name__ == "__main__":
    unittest.main()
