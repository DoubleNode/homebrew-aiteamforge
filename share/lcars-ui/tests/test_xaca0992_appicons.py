#!/usr/bin/env python3

#
#  test_xaca0992_appicons.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Tests for XACA-0992: per-team Add-to-Home-Screen app icons (LCARS server.py).

Before this ticket's remediation, `find tests lcars-ui/tests -iname
"*appicon*"` returned NOTHING — neither serve_appicon, _resolve_base_team,
the webmanifest handler, nor gen-appicons.py had a single test, despite both
suites reporting green. This file closes the server.py half of that gap
(scripts/gen-appicons.py is covered separately in
tests/test_xaca0992_gen_appicons.py).

Coverage:
  1. _resolve_base_team() for every one of the 15 registered runtime team
     ids (verified live via aiteamforge_paths.list_teams() while authoring
     this file — see the comment on _REGISTERED_RUNTIME_TEAM_IDS below),
     including the mainevent-maineventwrapper-ios gap this ticket closed
     and the dns special case (base brand stays 'dns', NOT 'dns-framework'
     — that remap is a serve_image-only on-disk quirk).
  2. serve_appicon(): all 7 valid filenames -> 200 + image/png; different
     teams return DIFFERENT bytes (the test that actually proves per-team
     resolution — a route serving one identical icon behind four 200s would
     pass a naive status-only check and defeat the entire ticket); unlisted
     filename -> 404; path traversal -> 404, including URL-encoded/
     mixed-encoding variants.
  3. The webmanifest route: 200, application/manifest+json, valid JSON,
     per-team name.
  4. HEAD/GET parity for /appicons/* and /images/* — a regression test for
     the HEAD/GET mismatch this ticket's remediation fixed (do_HEAD had no
     branch for either route and fell through to
     SimpleHTTPRequestHandler.do_HEAD(), which 404s on these server-side-
     resolved virtual routes). Guards against it silently coming back.

Run with:
    python3 -m unittest lcars-ui/tests/test_xaca0992_appicons.py
  or:
    python3 -m pytest lcars-ui/tests/test_xaca0992_appicons.py -q
  or as part of the full suite:
    python3 -m pytest lcars-ui/tests -q
"""

import io
import json
import re
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Bootstrap server.py imports (stub optional heavy dependencies) — mirrors
# the convention already established in test_server.py / test_xaca0630_parity.py.
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

import os as _os
_lcars_team_env_was_set = 'LCARS_TEAM' in _os.environ
_os.environ.setdefault('LCARS_TEAM', 'academy')
import server  # noqa: E402
if not _lcars_team_env_was_set:
    _os.environ.pop('LCARS_TEAM', None)


# ---------------------------------------------------------------------------
# Handler construction helper — mirrors test_server.py's _make_handler.
# ---------------------------------------------------------------------------

def _make_handler(path="/", method="GET"):
    """Construct an LCARSHandler instance with all socket I/O mocked out.

    Returns (handler, response_buf) where response_buf is a BytesIO that
    captures everything written via wfile.write. send_response/send_header
    calls are captured on handler._response_code / handler._headers_sent
    instead of being sent over a real socket.
    """
    response_buf = io.BytesIO()

    with patch.object(server.LCARSHandler, "__init__", lambda self, *a, **kw: None):
        handler = server.LCARSHandler.__new__(server.LCARSHandler)

    handler.path = path
    handler.command = method
    handler.rfile = io.BytesIO(b"")
    handler.wfile = response_buf
    handler.server = MagicMock()
    handler.headers = {}
    handler.directory = str(server.UI_DIR)
    handler.requestline = f"{method} {path} HTTP/1.1"
    handler.client_address = ("127.0.0.1", 9999)
    handler._response_code = None
    handler._headers_sent = []

    def _send_response(code, message=None):
        handler._response_code = code

    def _send_header(name, value):
        handler._headers_sent.append((name, value))

    def _end_headers():
        pass

    handler.send_response = _send_response
    handler.send_header = _send_header
    handler.end_headers = _end_headers
    handler.send_error = MagicMock(
        side_effect=lambda code, msg=None: setattr(handler, '_response_code', code)
    )
    handler.log_message = MagicMock()
    handler.log_error = MagicMock()
    return handler, response_buf


def _headers_dict(handler):
    return dict(handler._headers_sent)


# ---------------------------------------------------------------------------
# 1. _resolve_base_team() for every registered runtime team id
# ---------------------------------------------------------------------------

# XACA-0992: the 15 runtime team ids actually registered on this fleet,
# verified live while authoring this file via:
#     python3 -c "from aiteamforge_paths import list_teams; \
#                 print(len(list_teams())); print(sorted(list_teams()))"
# (kanban-hooks/aiteamforge_paths.py, merging DEFAULT_TEAMS with the
# per-machine ~/.aiteamforge/team-paths.json overlay) — count confirmed 15.
#
# This is deliberately a hand-pinned list, NOT a live call to
# aiteamforge_paths.list_teams() at test time: _resolve_base_team() is pure
# string-splitting (it delegates to the module-level _split_team_id(), which
# does no I/O at all), so testing it needs no config subsystem — and pinning
# the list keeps this test deterministic across machines/CI runners that may
# not carry the same ~/.aiteamforge/team-paths.json overlay this dev machine
# has (e.g. no freelance/legal/medical/finance projects configured there).
# Each entry is (runtime_team_id, expected_base_brand).
_REGISTERED_RUNTIME_TEAM_IDS = [
    ("academy", "academy"),
    ("android", "android"),
    ("command", "command"),
    ("dns", "dns"),  # pinned special case — see class docstring below
    ("finance-personal", "finance"),
    ("firebase", "firebase"),
    ("ios", "ios"),
    ("legal-coparenting", "legal"),
    ("mainevent", "mainevent"),
    ("mainevent-dev-team", "mainevent"),
    ("mainevent-maineventapp-android", "mainevent"),
    ("mainevent-maineventapp-functions", "mainevent"),
    ("mainevent-maineventapp-ios", "mainevent"),
    ("mainevent-maineventwrapper-ios", "mainevent"),  # the gap XACA-0992 closed
    ("medical-general", "medical"),
]


class TestResolveBaseTeam(unittest.TestCase):
    """_resolve_base_team() collapses a runtime team id to its base brand."""

    def test_all_15_registered_runtime_ids_resolve_correctly(self):
        self.assertEqual(
            len(_REGISTERED_RUNTIME_TEAM_IDS), 15,
            "This list itself is the fixture — if it's not 15, the comment "
            "documenting how it was derived is now stale, not just the count.",
        )
        for team_id, expected_base in _REGISTERED_RUNTIME_TEAM_IDS:
            with self.subTest(team_id=team_id):
                self.assertEqual(
                    server.LCARSHandler._resolve_base_team(team_id),
                    expected_base,
                )

    def test_mainevent_maineventwrapper_ios_resolves_to_mainevent(self):
        """The specific gap this ticket closed (previously fell through to
        no base brand / an unhandled parametric id)."""
        self.assertEqual(
            server.LCARSHandler._resolve_base_team("mainevent-maineventwrapper-ios"),
            "mainevent",
        )

    def test_dns_stays_dns_not_dns_framework(self):
        """Pinned special case: unlike serve_image (which further remaps
        'dns' -> 'dns-framework' for its own on-disk quirk), _resolve_base_team
        itself must return the bare 'dns' brand — that's what the appicons
        master directory is actually named (lcars-ui/images/appicons/dns/)."""
        self.assertEqual(server.LCARSHandler._resolve_base_team("dns"), "dns")
        appicons_dns_dir = server.UI_DIR / "images" / "appicons" / "dns"
        self.assertTrue(
            appicons_dns_dir.is_dir(),
            "Fixture assumption broken: lcars-ui/images/appicons/dns/ must exist "
            "on disk for this pinned case to mean anything.",
        )


# ---------------------------------------------------------------------------
# 2. serve_appicon()
# ---------------------------------------------------------------------------

class TestServeAppiconValidFilenames(unittest.TestCase):
    """Each of the 7 real, on-disk filenames returns 200 + image/png for the
    currently-running team (LCARS_TEAM)."""

    def test_all_7_appicon_filenames_return_200_png(self):
        self.assertEqual(len(server.LCARSHandler.APPICON_FILENAMES), 7)
        with patch.object(server, "LCARS_TEAM", "academy"):
            for filename in sorted(server.LCARSHandler.APPICON_FILENAMES):
                with self.subTest(filename=filename):
                    handler, buf = _make_handler(f"/appicons/{filename}")
                    handler.serve_appicon(f"/appicons/{filename}")
                    self.assertEqual(handler._response_code, 200)
                    self.assertEqual(_headers_dict(handler).get("Content-Type"), "image/png")
                    body = buf.getvalue()
                    self.assertTrue(len(body) > 0)
                    self.assertEqual(
                        int(_headers_dict(handler).get("Content-Length")), len(body)
                    )
                    handler.send_error.assert_not_called()


class TestServeAppiconPerTeamResolution(unittest.TestCase):
    """The test that actually proves per-team resolution: two different
    running teams must get DIFFERENT icon bytes back for the identical
    fixed path — a route that always serves one shared default would pass
    every status-code-only check above and defeat the entire ticket."""

    def _fetch(self, team, filename):
        with patch.object(server, "LCARS_TEAM", team):
            handler, buf = _make_handler(f"/appicons/{filename}")
            handler.serve_appicon(f"/appicons/{filename}")
            self.assertEqual(handler._response_code, 200, f"team={team} filename={filename}")
            return buf.getvalue()

    def test_academy_and_ios_return_different_icon_bytes(self):
        academy_bytes = self._fetch("academy", "icon-192.png")
        ios_bytes = self._fetch("ios", "icon-192.png")
        self.assertNotEqual(
            academy_bytes, ios_bytes,
            "academy and ios served byte-identical icons for a team-resolved "
            "route — per-team resolution is not actually happening",
        )

    def test_parametric_team_resolves_to_base_brand_icon_not_fallback(self):
        """A parametric team (mainevent-maineventwrapper-ios) must resolve to
        the SAME bytes as its base brand (mainevent), not to the generic
        fallback (academy) and not 404."""
        mainevent_bytes = self._fetch("mainevent", "icon-192.png")
        wrapper_bytes = self._fetch("mainevent-maineventwrapper-ios", "icon-192.png")
        academy_bytes = self._fetch("academy", "icon-192.png")
        self.assertEqual(mainevent_bytes, wrapper_bytes)
        self.assertNotEqual(wrapper_bytes, academy_bytes)

    def test_four_teams_all_pairwise_differ(self):
        """Stronger than the 2-team check above: guards against a subtler bug
        where e.g. two teams happen to share a fallback while others differ."""
        teams = ["academy", "ios", "android", "firebase"]
        bytes_by_team = {t: self._fetch(t, "icon-192.png") for t in teams}
        for i, t1 in enumerate(teams):
            for t2 in teams[i + 1:]:
                with self.subTest(t1=t1, t2=t2):
                    self.assertNotEqual(bytes_by_team[t1], bytes_by_team[t2])


class TestServeAppiconRejectsInvalidAndTraversal(unittest.TestCase):
    def test_unlisted_filename_returns_404(self):
        with patch.object(server, "LCARS_TEAM", "academy"):
            handler, buf = _make_handler("/appicons/not-a-real-icon.png")
            handler.serve_appicon("/appicons/not-a-real-icon.png")
            handler.send_error.assert_called()
            self.assertEqual(handler.send_error.call_args.args[0], 404)
            self.assertEqual(buf.getvalue(), b"")

    def test_path_traversal_variants_all_return_404(self):
        """Whitelist membership against the fixed 7-name set IS the
        path-traversal defense (see serve_appicon's own comment) — no
        traversal sequence, encoded or not, can ever equal one of those 7
        literal strings. Exercised across several encodings/forms."""
        traversal_names = [
            "../etc/passwd",
            "../../etc/passwd",
            "..%2Fetc%2Fpasswd",
            "%2e%2e%2Ficon-192.png",
            "%2E%2E%2Ficon-192.png",
            "icon-192.png/../../../../etc/passwd",
            "....//....//etc/passwd",
            "icon-192.png%00.jpg",
            "/etc/passwd",
            "academy/icon-192.png",
        ]
        with patch.object(server, "LCARS_TEAM", "academy"):
            for name in traversal_names:
                with self.subTest(name=name):
                    path = "/appicons/" + name
                    handler, buf = _make_handler(path)
                    handler.serve_appicon(path)
                    self.assertEqual(
                        handler._response_code, 404,
                        f"traversal variant {name!r} did not 404",
                    )
                    self.assertEqual(buf.getvalue(), b"")

    def test_traversal_defense_can_actually_fail(self):
        """Mutation proof: bypass the whitelist membership check (patched to
        accept anything) and request '../ios/icon-192.png' while running as
        'academy'. The containment check (path.relative_to(appicons_root))
        does NOT catch this one, because '../ios/icon-192.png' resolves to
        a path that is still inside appicons_root (just a different team's
        subdirectory) — it only rejects escapes from appicons_root entirely.
        So this specific traversal name is a case the whitelist alone
        blocks and the containment check alone would not. With the real
        whitelist this 404s (name isn't one of the 7 exact strings); with
        the whitelist bypassed it must instead succeed and serve iOS's icon
        bytes while LCARS_TEAM is academy — a clean, unambiguous behavior
        change proving the whitelist test above is not vacuous."""
        with patch.object(server, "LCARS_TEAM", "academy"):
            # Sanity: the real whitelist blocks this today.
            handler, buf = _make_handler("/appicons/../ios/icon-192.png")
            handler.serve_appicon("/appicons/../ios/icon-192.png")
            self.assertEqual(handler._response_code, 404)

            # Mutation: bypass the whitelist gate only.
            with patch.object(
                server.LCARSHandler, "APPICON_FILENAMES", _PermissiveContainsEverything()
            ):
                mut_handler, mut_buf = _make_handler("/appicons/../ios/icon-192.png")
                mut_handler.serve_appicon("/appicons/../ios/icon-192.png")

        self.assertEqual(
            mut_handler._response_code, 200,
            "Bypassing the whitelist was expected to let this traversal name "
            "through (proving the whitelist, not the containment check, is "
            "what blocks it normally) — got non-200, so this mutation no "
            "longer demonstrates what the whitelist test guards against",
        )
        # And it serves iOS's icon while LCARS_TEAM is academy — the actual
        # traversal payoff the whitelist exists to prevent.
        ios_handler, ios_buf = _make_handler("/appicons/icon-192.png")
        with patch.object(server, "LCARS_TEAM", "ios"):
            ios_handler.serve_appicon("/appicons/icon-192.png")
        self.assertEqual(mut_buf.getvalue(), ios_buf.getvalue())


class _PermissiveContainsEverything:
    """A whitelist stand-in whose `in` always returns True — the mutation
    used above to prove the real whitelist is load-bearing."""

    def __contains__(self, item):
        return True

    def __iter__(self):
        return iter(server.LCARSHandler.APPICON_FILENAMES)

    def __len__(self):
        return len(server.LCARSHandler.APPICON_FILENAMES)


# ---------------------------------------------------------------------------
# 3. Webmanifest route
# ---------------------------------------------------------------------------

class TestServeAppiconManifest(unittest.TestCase):
    def test_manifest_200_content_type_and_valid_json(self):
        with patch.object(server, "LCARS_TEAM", "academy"):
            handler, buf = _make_handler("/appicons/team.webmanifest")
            handler.serve_appicon("/appicons/team.webmanifest")
            self.assertEqual(handler._response_code, 200)
            self.assertEqual(
                _headers_dict(handler).get("Content-Type"), "application/manifest+json"
            )
            manifest = json.loads(buf.getvalue())
            self.assertIn("name", manifest)
            self.assertIn("icons", manifest)
            self.assertEqual(len(manifest["icons"]), 3)

    def test_manifest_name_differs_per_team(self):
        def _name_for(team):
            with patch.object(server, "LCARS_TEAM", team):
                handler, buf = _make_handler("/appicons/team.webmanifest")
                handler.serve_appicon("/appicons/team.webmanifest")
                return json.loads(buf.getvalue())["name"]

        academy_name = _name_for("academy")
        ios_name = _name_for("ios")
        self.assertTrue(academy_name)
        self.assertTrue(ios_name)
        self.assertNotEqual(academy_name, ios_name)


# ---------------------------------------------------------------------------
# 4. HEAD/GET parity regression guard (XACA-0992 Defect 1)
# ---------------------------------------------------------------------------

class TestHeadGetParity(unittest.TestCase):
    """Regression guard for the HEAD/GET mismatch fixed in do_HEAD: a HEAD
    request for /appicons/* or /images/* must return the SAME status code,
    Content-Type, and Content-Length as the equivalent GET, with no body.
    Before the fix, both fell through to SimpleHTTPRequestHandler.do_HEAD()
    and 404'd. Also covers the funnel-prefixed form (PATH_PREFIXES stripping
    was previously missing from do_HEAD entirely)."""

    PARITY_PATHS = [
        "/appicons/icon-192.png",
        "/appicons/team.webmanifest",
        "/images/academy_lcars_logo.png",
        "/academy/appicons/icon-192.png",
    ]

    def _get_and_head(self, path):
        with patch.object(server, "LCARS_TEAM", "academy"):
            get_handler, get_buf = _make_handler(path, method="GET")
            get_handler.do_GET()
            head_handler, head_buf = _make_handler(path, method="HEAD")
            head_handler.do_HEAD()
        return get_handler, get_buf, head_handler, head_buf

    def test_head_get_parity_for_appicons_and_images(self):
        for path in self.PARITY_PATHS:
            with self.subTest(path=path):
                get_handler, get_buf, head_handler, head_buf = self._get_and_head(path)

                self.assertEqual(get_handler._response_code, 200, path)
                self.assertEqual(
                    head_handler._response_code, get_handler._response_code, path
                )
                self.assertEqual(
                    _headers_dict(head_handler).get("Content-Type"),
                    _headers_dict(get_handler).get("Content-Type"),
                    path,
                )
                self.assertEqual(
                    _headers_dict(head_handler).get("Content-Length"),
                    _headers_dict(get_handler).get("Content-Length"),
                    path,
                )
                # HEAD must carry no body, and GET's body length must match
                # the Content-Length header it sent (sanity on the GET side).
                self.assertEqual(head_buf.getvalue(), b"")
                self.assertEqual(
                    len(get_buf.getvalue()),
                    int(_headers_dict(get_handler).get("Content-Length")),
                    path,
                )

    def test_head_parity_can_actually_fail_against_the_pre_fix_dispatcher(self):
        """Mutation proof: do_HEAD's pre-fix form (no /appicons or /images
        branch, no PATH_PREFIXES stripping) reproduces the exact 404 QA
        found. Reconstructed inline (not imported) since do_HEAD is a
        method on the class actually under test in every other test in
        this file — this proves the parity test above is not vacuously
        true against the current code."""

        def _pre_fix_do_head(self):
            from urllib.parse import urlparse
            path = urlparse(self.path).path
            if path == '/lcars-target.js':
                self.serve_lcars_target(head_only=True)
                return
            if path == '/lcars-target.local.js':
                self.serve_lcars_target_local(head_only=True)
                return
            if path.endswith('.js') or path.endswith('.html') or path.endswith('.css') or path == '/':
                self.serve_no_cache_static(path, head_only=True)
                return
            super(server.LCARSHandler, self).do_HEAD()

        with patch.object(server, "LCARS_TEAM", "academy"):
            with patch.object(server.LCARSHandler, "do_HEAD", _pre_fix_do_head):
                handler, buf = _make_handler("/appicons/icon-192.png", method="HEAD")
                handler.do_HEAD()
        # Pre-fix: falls through to SimpleHTTPRequestHandler.do_HEAD(), which
        # send_error's 404 in this mocked environment (no `directory`-backed
        # static file at that path) rather than the real 200 the fixed
        # dispatcher returns — proving the regression guard above is real.
        self.assertNotEqual(
            handler._response_code, 200,
            "Pre-fix do_HEAD was expected to NOT return 200 for /appicons/* "
            "(that's the bug) — got 200, so this mutation no longer "
            "demonstrates the regression the parity test guards against",
        )


if __name__ == "__main__":
    unittest.main()
