#!/usr/bin/env python3
"""
XACA-1376 — X-LCARS-Asset-Version fingerprint ("LCARS was updated - reload").

Covers server.compute_asset_version() and the response header on the board-data
and /api/status handlers:
  1. stable for identical content
  2. changes when a ?v= stamp changes
  3. picks up an index.html change with NO restart (mtime/size keyed cache)
  4. ignores non-stamp edits that keep the URL set identical (order-insensitive)
  4b. hashes the SERVED form: touching an unstamped file moves the value (XACA-1376-014)
  4c. served index.html carries a boot-time <meta> equal to the header (XACA-1376-013)
  5. fail-soft: missing file / no stamps -> None; handler omits header, still 200
  6. header present on /api/status and board data; exposed through CORS

Run with:
    python3 -m pytest lcars-ui/tests/test_xaca1376_asset_version.py -q
"""

import io
import json
import os
import re
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
    '<head>\n'
    '<link rel="stylesheet" href="css/lcars.css?v=1.0">\n'
    '<script src="js/lcars.js?v=2.0"></script>\n'
    '<script src="js/app.js"></script>\n'
    '<link rel="stylesheet" href="css/plain.css">\n'
    '<script src="https://cdn.example.com/x.js?v=9"></script>\n'
    '</head>\n'
)

UNSTAMPED = ("js/app.js", "css/plain.css")


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


def _touch(path, sec):
    """Set mtime to an exact whole second (the serve-time stamp is int seconds)."""
    os.utime(path, (sec, sec))


class ComputeAssetVersionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for rel in ("css/lcars.css", "js/lcars.js", *UNSTAMPED):
            f = self.root / rel
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text("/* x */", encoding="utf-8")
            _touch(f, 1_700_000_000)
        self.index = self.root / "index.html"
        _write(self.index, HTML_A, bump_mtime=False)

    def fp(self):
        return server.compute_asset_version(self.index)

    def test_stable_for_same_content(self):
        a, b = self.fp(), self.fp()
        self.assertRegex(a, r"^[0-9a-f]{12}$")
        self.assertEqual(a, b)

    def test_table_changes_vs_stable(self):
        """(label, mutate(index_text)->new_text, expect_change)"""
        cases = [
            ("stamped bump (js)", lambda t: t.replace("lcars.js?v=2.0", "lcars.js?v=2.1"), True),
            ("stamped bump (css)", lambda t: t.replace("lcars.css?v=1.0", "lcars.css?v=1.1"), True),
            ("new local ref added", lambda t: t.replace("</head>", '<script src="js/new.js"></script></head>'), True),
            ("non-stamp edit", lambda t: t + "<p>other edit</p>\n", False),
            ("reordered lines", lambda t: "\n".join(reversed(t.splitlines())) + "\n", False),
            ("external CDN bump ignored", lambda t: t.replace("x.js?v=9", "x.js?v=10"), False),
            ("external CDN added ignored", lambda t: t.replace("</head>", '<script src="https://a.example/y.js"></script></head>'), False),
            ("non-asset href edit ignored", lambda t: t.replace("<head>", '<head><a href="/somewhere">x</a>'), False),
        ]
        for label, mutate, changes in cases:
            with self.subTest(label):
                _write(self.index, HTML_A, bump_mtime=False)
                before = self.fp()
                _write(self.index, mutate(HTML_A))
                after = self.fp()
                (self.assertNotEqual if changes else self.assertEqual)(before, after)

    def test_picks_up_change_without_restart_even_same_size(self):
        a = self.fp()
        size = self.index.stat().st_size
        _write(self.index, HTML_A.replace("v=2.0", "v=2.1"))
        self.assertEqual(size, self.index.stat().st_size)
        self.assertNotEqual(a, self.fp())

    def test_touching_an_unstamped_file_changes_value_with_no_restart(self):
        # XACA-1376-014: 14 of the 30 real refs are unstamped; serve-time ?v=<mtime> covers them.
        for rel in UNSTAMPED:
            with self.subTest(rel):
                before = self.fp()
                _touch(self.root / rel, 1_700_000_000 + 100)
                self.assertNotEqual(before, self.fp())
                _touch(self.root / rel, 1_700_000_000)  # restore for the next row
                self.assertEqual(before, self.fp())

    def test_touching_a_stamped_files_mtime_does_not_change_value(self):
        before = self.fp()
        _touch(self.root / "js/lcars.js", 1_700_000_500)  # hand-stamped ref: the stamp rules, not mtime
        self.assertEqual(before, self.fp())

    def test_missing_unstamped_file_still_yields_a_value(self):
        (self.root / "js/app.js").unlink()
        self.assertRegex(self.fp(), r"^[0-9a-f]{12}$")

    def test_fingerprint_equals_hash_of_actual_served_output(self):
        """The two paths cannot drift: header value == hash of _version_html_refs output."""
        raw = self.index.read_bytes()
        with patch.object(server, "UI_DIR", self.root):
            h, _ = _make_handler()
            served = h._version_html_refs(raw)
        self.assertEqual(server.asset_fingerprint_from_served(served), self.fp())
        # and it really is the served form: unstamped refs carry their mtime
        self.assertIn(b"js/app.js?v=1700000000", served)
        self.assertIn(b"css/plain.css?v=1700000000", served)

    def test_missing_file_returns_none(self):
        self.assertIsNone(server.compute_asset_version(self.root / "nope.html"))

    def test_no_local_assets_returns_none(self):
        _write(self.index, "<html></html>")
        self.assertIsNone(self.fp())

    def test_real_index_html_yields_value(self):
        self.assertRegex(server.compute_asset_version(LCARS_UI_DIR / "index.html") or "",
                         r"^[0-9a-f]{12}$")


class ServedIndexMetaTests(unittest.TestCase):
    """XACA-1376-013: served index.html carries the same fingerprint as the header."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for rel in ("css/lcars.css", "js/lcars.js", *UNSTAMPED):
            f = self.root / rel
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text("/* x */", encoding="utf-8")
            _touch(f, 1_700_000_000)
        (self.root / "index.html").write_text(HTML_A, encoding="utf-8")
        (self.root / "other.html").write_text(HTML_A, encoding="utf-8")

    def _serve(self, path, head_only=False):
        with patch.object(server, "UI_DIR", self.root):
            h, buf = _make_handler()
            h.serve_no_cache_static(path, head_only=head_only)
            h._send_asset_version_header()
        return h, buf.getvalue()

    def _meta(self, body):
        found = re.findall(rb'<meta name="lcars-asset-version" content="([0-9a-f]{12})">', body)
        return found

    def test_meta_equals_header_value(self):
        for path in ("/", "/index.html"):
            with self.subTest(path):
                h, body = self._serve(path)
                self.assertEqual(h._code, 200)
                header = dict(h._sent)[HEADER]
                self.assertEqual(self._meta(body), [header.encode()])

    def test_meta_lives_inside_head_and_content_length_matches(self):
        h, body = self._serve("/index.html")
        self.assertLess(body.index(b"<head>"), body.index(b"lcars-asset-version"))
        self.assertLess(body.index(b"lcars-asset-version"), body.index(b"</head>"))
        self.assertEqual(int(dict(h._sent)["Content-Length"]), len(body))

    def test_head_request_content_length_matches_get(self):
        g, gbody = self._serve("/index.html")
        hh, hbody = self._serve("/index.html", head_only=True)
        self.assertEqual(hbody, b"")
        self.assertEqual(dict(hh._sent)["Content-Length"], dict(g._sent)["Content-Length"])

    def test_no_etag_or_other_validator_header_to_keep_in_sync(self):
        h, _ = self._serve("/index.html")
        self.assertNotIn("etag", [n.lower() for n, _ in h._sent])

    def test_meta_follows_unstamped_file_touch(self):
        _, body1 = self._serve("/index.html")
        _touch(self.root / "js/app.js", 1_700_000_000 + 60)
        _, body2 = self._serve("/index.html")
        self.assertNotEqual(self._meta(body1), self._meta(body2))

    def test_other_html_pages_get_no_meta(self):
        _, body = self._serve("/other.html")
        self.assertEqual(self._meta(body), [])

    def test_page_without_head_or_assets_is_served_unchanged(self):
        (self.root / "index.html").write_text("<html>hi</html>", encoding="utf-8")
        h, body = self._serve("/index.html")
        self.assertEqual(h._code, 200)
        self.assertEqual(body, b"<html>hi</html>")


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
