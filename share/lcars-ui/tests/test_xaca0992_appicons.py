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
import tempfile
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


class _NeverRemembers:
    """A dedupe-set stand-in that never records anything — every
    `in` check is False and `.add()` is a no-op. Used to mutate away the
    XACA-0992 subitem-020 throttle guard: with this swapped in for
    `_appicon_missing_master_warned`, the "already warned" branch can never
    be true, reproducing the pre-fix behaviour of printing on every single
    call regardless of prior warnings for the same base team."""

    def __contains__(self, item):
        return False

    def add(self, item):
        pass


class TestServeAppiconMissingMasterWarningThrottled(unittest.TestCase):
    """XACA-0992 review (protected subitem 020): serve_appicon()'s "no
    appicons master" fallback warning used to print unconditionally on
    every request, so one page load (which fetches all 7 appicon files)
    logged 7 identical WARNING lines for a single missing master. Throttled
    to once per base_team via a class-level dedupe set, matching the
    existing _planned_heal_warned convention elsewhere in this file — see
    the comment above _appicon_missing_master_warned."""

    def _missing_master_fixture(self, tmp):
        """Build an appicons_root with ONLY the fallback ('academy') master
        present — the requested base team has no directory at all, so
        every request for it hits the missing-master branch."""
        fake_ui_dir = Path(tmp)
        appicons_root = fake_ui_dir / "images" / "appicons"
        fallback_dir = appicons_root / "academy"
        fallback_dir.mkdir(parents=True)
        png_bytes = b'\x89PNG\r\n\x1a\nFALLBACK'
        for filename in server.LCARSHandler.APPICON_FILENAMES:
            (fallback_dir / filename).write_bytes(png_bytes)
        return fake_ui_dir

    def test_second_request_for_same_missing_team_does_not_rewarn(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake_ui_dir = self._missing_master_fixture(tmp)

            with patch.object(server, "UI_DIR", fake_ui_dir), \
                 patch.object(server, "LCARS_TEAM", "missingteam"), \
                 patch.object(server.LCARSHandler, "_appicon_missing_master_warned", set()), \
                 patch("builtins.print") as mock_print:
                handler1, buf1 = _make_handler("/appicons/icon-192.png")
                handler1.serve_appicon("/appicons/icon-192.png")
                handler2, buf2 = _make_handler("/appicons/icon-512.png")
                handler2.serve_appicon("/appicons/icon-512.png")

            # Both requests still succeed (served from the fallback) —
            # throttling the WARNING must never affect the actual response.
            self.assertEqual(handler1._response_code, 200)
            self.assertEqual(handler2._response_code, 200)

            warning_calls = [
                c for c in mock_print.call_args_list
                if c.args and "no appicons master" in str(c.args[0])
            ]
            self.assertEqual(
                len(warning_calls), 1,
                "Two requests for the SAME missing base team must produce "
                f"exactly one WARNING print, got {len(warning_calls)}: "
                f"{warning_calls}",
            )

    def test_different_missing_team_still_gets_its_own_warning(self):
        """Throttling is keyed per base_team, not a single global on/off —
        a distinct missing team must still warn even after another team's
        warning has already fired."""
        with tempfile.TemporaryDirectory() as tmp:
            fake_ui_dir = self._missing_master_fixture(tmp)

            with patch.object(server, "UI_DIR", fake_ui_dir), \
                 patch.object(server.LCARSHandler, "_appicon_missing_master_warned", set()), \
                 patch("builtins.print") as mock_print:
                # No hyphens — a hyphenated id (e.g. 'missingteam-one') would
                # collapse via _split_team_id() to the SAME base brand
                # ('missingteam'), which would defeat this test's own
                # premise of two genuinely distinct base teams.
                with patch.object(server, "LCARS_TEAM", "missingteamone"):
                    h1, _ = _make_handler("/appicons/icon-192.png")
                    h1.serve_appicon("/appicons/icon-192.png")
                with patch.object(server, "LCARS_TEAM", "missingteamtwo"):
                    h2, _ = _make_handler("/appicons/icon-192.png")
                    h2.serve_appicon("/appicons/icon-192.png")

            warning_calls = [
                c for c in mock_print.call_args_list
                if c.args and "no appicons master" in str(c.args[0])
            ]
            self.assertEqual(
                len(warning_calls), 2,
                "Two DIFFERENT missing base teams must each get their own "
                f"warning, got {len(warning_calls)}: {warning_calls}",
            )

    def test_throttle_can_actually_fail_against_an_unguarded_mutation(self):
        """Mutation proof: swap the real dedupe set for _NeverRemembers(),
        which can never report "already warned" — reproducing the pre-fix
        unconditional-print behaviour. Two requests for the SAME missing
        team must then produce TWO warnings, proving the throttle test
        above is exercising a real guard and not vacuously passing (e.g.
        because the fixture only happens to trigger one request)."""
        with tempfile.TemporaryDirectory() as tmp:
            fake_ui_dir = self._missing_master_fixture(tmp)

            with patch.object(server, "UI_DIR", fake_ui_dir), \
                 patch.object(server, "LCARS_TEAM", "missingteam"), \
                 patch.object(server.LCARSHandler, "_appicon_missing_master_warned", _NeverRemembers()), \
                 patch("builtins.print") as mock_print:
                h1, _ = _make_handler("/appicons/icon-192.png")
                h1.serve_appicon("/appicons/icon-192.png")
                h2, _ = _make_handler("/appicons/icon-512.png")
                h2.serve_appicon("/appicons/icon-512.png")

            warning_calls = [
                c for c in mock_print.call_args_list
                if c.args and "no appicons master" in str(c.args[0])
            ]
            self.assertEqual(
                len(warning_calls), 2,
                "With the dedupe guard defeated, two requests for the same "
                f"missing team must produce two warnings, got "
                f"{len(warning_calls)} — this mutation no longer proves the "
                "throttle test above is load-bearing.",
            )


class TestServeAppiconSymlinkEscapeReturns404(unittest.TestCase):
    """PR #780 review (non-blocking regression): `team_dir.relative_to(
    appicons_root)` used to be evaluated as a bare argument expression to
    `_resolve_contained_path(...)`, OUTSIDE that helper's own try/except.
    If the on-disk `appicons/<base_team>` entry is a symlink pointing
    outside `appicons_root`, `team_dir` (already `.resolve()`d earlier in
    serve_appicon) points at the escaped, real target — and `.is_dir()`
    still returns True for it (it's a real directory, just not the one
    under appicons_root), so the "no master for this team" fallback branch
    does NOT trigger either. `.relative_to(appicons_root)` then raises
    ValueError, uncaught, producing an unhandled-exception 500 instead of
    the clean 404 every other containment failure on this route produces.
    Fixed by moving that call inside its own try/except ValueError -> 404.
    """

    def test_symlinked_team_dir_escaping_root_returns_404_not_500(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake_ui_dir = Path(tmp)
            appicons_root = fake_ui_dir / "images" / "appicons"
            appicons_root.mkdir(parents=True)

            outside = fake_ui_dir / "outside-appicons-root"
            outside.mkdir()
            # A file here would be leaked bytes if the escape ever served
            # content instead of 404ing — not exercised directly (this test
            # only checks status/response emptiness), but documents what a
            # successful escape would actually expose.
            (outside / "icon-192.png").write_bytes(b'\x89PNG\r\n\x1a\nESCAPED-BYTES')

            # 'evilteam' has no hyphen, so _resolve_base_team/_split_team_id
            # returns it unchanged — base_team == 'evilteam', matching the
            # symlink name below with no extra remapping to account for.
            (appicons_root / "evilteam").symlink_to(outside, target_is_directory=True)

            # Real fallback dir too, so if the fix regresses to over-eagerly
            # falling back (rather than 404ing) this test still fails
            # loudly instead of accidentally passing on a 200 from academy's
            # real fallback icon.
            fallback_dir = appicons_root / "academy"
            fallback_dir.mkdir()
            (fallback_dir / "icon-192.png").write_bytes(b'\x89PNG\r\n\x1a\nFALLBACK')

            with patch.object(server, "UI_DIR", fake_ui_dir), \
                 patch.object(server, "LCARS_TEAM", "evilteam"):
                handler, buf = _make_handler("/appicons/icon-192.png")
                handler.serve_appicon("/appicons/icon-192.png")

            self.assertEqual(
                handler._response_code, 404,
                "Symlinked team dir escaping appicons_root must 404, not "
                "500/raise — got response code "
                f"{handler._response_code!r}",
            )
            self.assertEqual(buf.getvalue(), b"")

    def test_symlink_escape_can_actually_fail_against_the_pre_fix_call(self):
        """Mutation proof: reconstruct the PRE-FIX call shape — evaluating
        `team_dir.relative_to(appicons_root)` as a bare expression, not
        inside a try/except — against the exact same escaped-symlink
        fixture, and confirm it raises ValueError uncaught. This proves
        the 404 assertion above is not vacuously true against the current
        code (i.e. the escape fixture genuinely produces a containment
        failure, not e.g. a coincidental 404 from some unrelated check)."""
        with tempfile.TemporaryDirectory() as tmp:
            fake_ui_dir = Path(tmp)
            appicons_root = fake_ui_dir / "images" / "appicons"
            appicons_root.mkdir(parents=True)
            outside = fake_ui_dir / "outside-appicons-root"
            outside.mkdir()
            (appicons_root / "evilteam").symlink_to(outside, target_is_directory=True)

            team_dir = (appicons_root / "evilteam").resolve()
            appicons_root_resolved = appicons_root.resolve()

            # Sanity: the escape fixture actually escapes.
            with self.assertRaises(ValueError):
                team_dir.relative_to(appicons_root_resolved)

            # And is_dir() is True (proving the earlier fallback branch,
            # which checks `not team_dir.is_dir()`, would NOT have caught
            # this — the bug is specifically in the relative_to() call, not
            # a missing directory).
            self.assertTrue(team_dir.is_dir())

            # Pre-fix call shape: bare expression, no try/except -> raises,
            # uncaught, exactly reproducing the pre-fix 500.
            with self.assertRaises(ValueError):
                server.LCARSHandler._resolve_contained_path(
                    appicons_root_resolved,
                    team_dir.relative_to(appicons_root_resolved),
                    "icon-192.png",
                )


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
# 3b. Manifest name/short_name correctness (PR #780 UX gate, Finding 1)
# ---------------------------------------------------------------------------
#
# Before this fix: `short_name` was simply an alias of `name` — fine for
# teams whose registry.json `name` happens to be short (e.g. "Boston
# Legal"), but wrong for `ios` ("Star Trek: TNG - iOS", 20 chars — iOS
# truncates a home-screen label at roughly 11-12 characters) and for teams
# with NO registry.json entry (`dns`, `mainevent`), which fell through to a
# naive `base_team.title()`: 'dns' -> 'Dns' (should be 'DNS'), 'mainevent'
# -> 'Mainevent' (should be 'MainEvent'). Fixed via _BASE_BRAND_SHORT_NAMES
# + _base_brand_short_name() (server.py, next to MULTI_PROJECT_BASE_TEAMS).

class TestManifestShortNameAllRegisteredIds(unittest.TestCase):
    """Every one of the 15 registered runtime ids must produce a non-empty
    `name` and a non-empty, <=12-character, correctly-cased `short_name`."""

    _SHORT_NAME_MAX_LEN = 12

    def _manifest_for(self, team):
        with patch.object(server, "LCARS_TEAM", team):
            handler, buf = _make_handler("/appicons/team.webmanifest")
            handler.serve_appicon("/appicons/team.webmanifest")
            self.assertEqual(handler._response_code, 200, team)
            return json.loads(buf.getvalue())

    def test_all_15_registered_ids_have_nonempty_bounded_short_name(self):
        for team_id, _base in _REGISTERED_RUNTIME_TEAM_IDS:
            with self.subTest(team_id=team_id):
                manifest = self._manifest_for(team_id)
                name = manifest["name"]
                short_name = manifest["short_name"]
                self.assertTrue(name.strip(), f"{team_id}: empty name")
                self.assertTrue(short_name.strip(), f"{team_id}: empty short_name")
                self.assertLessEqual(
                    len(short_name), self._SHORT_NAME_MAX_LEN,
                    f"{team_id}: short_name {short_name!r} exceeds "
                    f"{self._SHORT_NAME_MAX_LEN} chars",
                )

    def test_short_name_casing_for_known_brands(self):
        """Pins the exact human-correct casing this fix produces — a naive
        base_team.title() would instead give 'Dns'/'Mainevent' (pre-fix
        bug, reproduced by the mutation test below)."""
        expected = {
            "dns": "DNS",
            "ios": "iOS",
            "mainevent": "MainEvent",
            "mainevent-dev-team": "MainEvent",
            "android": "Android",
            "finance-personal": "Finance",
            "legal-coparenting": "Legal",
            "medical-general": "Medical",
        }
        for team_id, expected_short in expected.items():
            with self.subTest(team_id=team_id):
                self.assertEqual(self._manifest_for(team_id)["short_name"], expected_short)

    def test_name_is_never_empty_even_with_no_registry_entry(self):
        """dns and mainevent have NO registry.json entry at all — `name`
        must still be non-empty (falls back to the short_name, itself
        guaranteed non-empty by _base_brand_short_name)."""
        for team_id in ("dns", "mainevent"):
            with self.subTest(team_id=team_id):
                self.assertTrue(self._manifest_for(team_id)["name"].strip())

    def test_short_name_can_actually_regress(self):
        """Mutation proof: with _BASE_BRAND_SHORT_NAMES emptied, dns's
        short_name reverts to the pre-fix naive title-case bug ('Dns') —
        proving the map (not something else) is what fixes casing, and
        that the tests above are not vacuously true."""
        with patch.object(server, "_BASE_BRAND_SHORT_NAMES", {}):
            mutated = self._manifest_for("dns")
        self.assertEqual(
            mutated["short_name"], "Dns",
            "Expected the pre-fix naive-title-case bug to reappear with "
            "the map emptied — got something else, so this mutation no "
            "longer demonstrates what the map fixes",
        )
        # And confirm it's restored once the patch context exits.
        restored = self._manifest_for("dns")
        self.assertEqual(restored["short_name"], "DNS")


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

    # XACA-0992 (PR #780 review): "/images/academy_lcars_logo.png" used to be
    # in this list. It depends on ~/dev-team/academy/terminals/logos/
    # academy_lcars_logo.png existing — true on THIS machine (this
    # worktree's checkout doubles as ~/dev-team) but not on a fresh clone or
    # CI runner, since serve_image()'s lookup is `Path.home() / "dev-team" /
    # ...` — hardcoded to the developer's home directory layout, not to
    # wherever a given checkout actually lives. Moved to its own test below
    # with a self-contained fixture (patches Path.home() to a tmp dir) so
    # /images/ HEAD/GET parity is still covered without that host coupling.
    PARITY_PATHS = [
        "/appicons/icon-192.png",
        "/appicons/team.webmanifest",
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

    def test_head_get_parity_for_team_logo_image(self):
        """/images/<team>_<name>_logo.png HEAD/GET parity — exercised
        against a SELF-CONTAINED fixture (Path.home() patched to a tmp dir)
        rather than the real ~/dev-team/academy/terminals/logos/
        academy_lcars_logo.png this case used to depend on directly (see
        the comment on PARITY_PATHS above for why that's not CI-safe). This
        still walks the exact same serve_image() code path — the
        team/name/type regex match, PNG-magic validity check, and
        Content-Type/Content-Length headers — just against a fixture file
        this test builds and owns instead of a host-machine asset.
        """
        # Only the PNG magic bytes matter to serve_image() (it checks
        # header[:4] == b'\x89PNG' and otherwise serves the file's raw
        # bytes verbatim — it never decodes the image) so this fixture
        # doesn't need to be a real, renderable PNG.
        png_bytes = b'\x89PNG\r\n\x1a\n' + b'FIXTURE-PNG-BYTES-NOT-A-REAL-IMAGE'
        path = "/images/academy_lcars_logo.png"

        with tempfile.TemporaryDirectory() as tmp:
            fake_home = Path(tmp)
            logos_dir = fake_home / "dev-team" / "academy" / "terminals" / "logos"
            logos_dir.mkdir(parents=True)
            (logos_dir / "academy_lcars_logo.png").write_bytes(png_bytes)

            with patch.object(server, "LCARS_TEAM", "academy"), \
                 patch.object(server.Path, "home", return_value=fake_home):
                get_handler, get_buf = _make_handler(path, method="GET")
                get_handler.do_GET()
                head_handler, head_buf = _make_handler(path, method="HEAD")
                head_handler.do_HEAD()

            # Assertions run while the tmp dir is still alive (do_GET/do_HEAD
            # already read the bytes into buffers by this point, but keeping
            # them inside the `with` avoids relying on that ordering).
            self.assertEqual(get_handler._response_code, 200)
            self.assertEqual(head_handler._response_code, 200)
            self.assertEqual(
                _headers_dict(head_handler).get("Content-Type"),
                _headers_dict(get_handler).get("Content-Type"),
            )
            self.assertEqual(_headers_dict(get_handler).get("Content-Type"), "image/png")
            self.assertEqual(
                _headers_dict(head_handler).get("Content-Length"),
                _headers_dict(get_handler).get("Content-Length"),
            )
            self.assertEqual(head_buf.getvalue(), b"")
            self.assertEqual(get_buf.getvalue(), png_bytes)

    def test_team_logo_fixture_can_actually_fail(self):
        """Mutation proof: the fixture test above is not vacuously true —
        confirm that WITHOUT patching Path.home(), the same request 404s on
        this repo layout (proving the patch is load-bearing) OR serves a
        DIFFERENT file than the fixture (proving the fixture, not some
        other lookup, is what the patched test actually reads)."""
        path = "/images/academy_lcars_logo.png"
        with patch.object(server, "LCARS_TEAM", "academy"):
            handler, buf = _make_handler(path, method="GET")
            handler.do_GET()
        # Whatever this machine's real ~/dev-team/academy/terminals/logos/
        # academy_lcars_logo.png contains (present here, absent on CI), it
        # is never the synthetic fixture bytes the patched test asserts —
        # proving that test is reading ITS OWN fixture, not incidentally
        # passing against the real file regardless of the patch.
        self.assertNotEqual(
            buf.getvalue(),
            b'\x89PNG\r\n\x1a\n' + b'FIXTURE-PNG-BYTES-NOT-A-REAL-IMAGE',
            "Unpatched request returned the exact fixture bytes — the "
            "Path.home() patch in the test above would not be proven "
            "load-bearing",
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


# ---------------------------------------------------------------------------
# 5. web-app-capable meta tag policy (PR #780 UX gate, Finding 2)
# ---------------------------------------------------------------------------
#
# apple-mobile-web-app-capable / mobile-web-app-capable must appear ONLY on
# real destination pages (index.html, agent-panel.html) — NOT on pages
# whose entire mechanism is an automatic window.location.href redirect
# (redirect.html, agent-panel-router.html) or a diagnostic page with no
# reason to solicit an install (audio-test.html). Standalone mode's only
# effect is stripping Safari's chrome; a failed redirect would strand the
# user full-screen with no address bar and no back button.

class TestWebAppCapableMetaTagPolicy(unittest.TestCase):
    MUST_NOT_HAVE = ["redirect.html", "agent-panel-router.html", "audio-test.html"]
    MUST_HAVE = ["index.html", "agent-panel.html"]

    def _read(self, name):
        return (LCARS_UI_DIR / name).read_text()

    def test_fragile_and_diagnostic_pages_omit_web_app_capable(self):
        for name in self.MUST_NOT_HAVE:
            with self.subTest(file=name):
                html = self._read(name)
                self.assertNotIn('<meta name="apple-mobile-web-app-capable"', html)
                self.assertNotIn('<meta name="mobile-web-app-capable"', html)
                # Must still get a proper icon + status bar styling — this
                # is a "remove ONE tag pair", not "strip all PWA metadata".
                self.assertEqual(html.count('rel="apple-touch-icon"'), 4, name)
                self.assertEqual(html.count('rel="manifest"'), 1, name)
                self.assertIn('apple-mobile-web-app-status-bar-style', html, name)

    def test_real_destination_pages_still_declare_web_app_capable(self):
        for name in self.MUST_HAVE:
            with self.subTest(file=name):
                html = self._read(name)
                self.assertIn('<meta name="apple-mobile-web-app-capable"', html)

    def test_policy_can_actually_regress(self):
        """Mutation proof: re-inserting the tag into a copy of redirect.html
        (never the real file) DOES trip the assertion above — proving the
        test is checking real tag presence/absence, not something vacuous
        like a comment that happens to mention the tag's name."""
        html = self._read("redirect.html")
        # Sanity: the explanatory HTML comment left in place DOES mention
        # the tag names in prose — if the test above searched for the bare
        # substring instead of the literal opening tag, it would false-fail
        # against the comment itself. Confirms the assertion is specific
        # enough to survive that.
        self.assertIn("apple-mobile-web-app-capable", html)  # in the comment
        self.assertNotIn('<meta name="apple-mobile-web-app-capable"', html)  # not a live tag

        broken = html.replace(
            '<meta name="apple-mobile-web-app-status-bar-style"',
            '<meta name="apple-mobile-web-app-capable" content="yes">\n'
            '    <meta name="apple-mobile-web-app-status-bar-style"',
            1,
        )
        self.assertIn('<meta name="apple-mobile-web-app-capable"', broken)


# ---------------------------------------------------------------------------
# 6. serve_image() path traversal (PR #780 security review)
# ---------------------------------------------------------------------------
#
# serve_image()'s "local images" fast path built its candidate file path
# with NO containment check at all: `UI_DIR / "images" / filename` where
# filename is everything after '/images/' in the request path, verbatim.
# A request like /images/../server.py (or a deep .../../../../../etc/passwd
# chain) resolved to a real file OUTSIDE the intended images/ directory and
# was served as-is — full server.py source, or arbitrary files off the box,
# regardless of the 127.0.0.1/tailnet bind. Closed via the shared
# _resolve_contained_path() helper (the same one serve_appicon() uses).

class TestServeImageRejectsTraversal(unittest.TestCase):
    TRAVERSAL_PATHS = [
        "/images/../server.py",
        "/images/../../../../../../../etc/passwd",
        "/images/..%2fserver.py",
        "/images/..%252fserver.py",
        "/images//etc/shadow",
    ]

    def test_traversal_variants_all_404_get(self):
        with patch.object(server, "LCARS_TEAM", "academy"):
            for path in self.TRAVERSAL_PATHS:
                with self.subTest(path=path):
                    handler, buf = _make_handler(path)
                    handler.serve_image(path)
                    self.assertEqual(handler._response_code, 404, path)
                    self.assertEqual(buf.getvalue(), b"")

    def test_traversal_variants_all_404_head(self):
        with patch.object(server, "LCARS_TEAM", "academy"):
            for path in self.TRAVERSAL_PATHS:
                with self.subTest(path=path):
                    handler, buf = _make_handler(path, method="HEAD")
                    handler.serve_image(path, head_only=True)
                    self.assertEqual(handler._response_code, 404, path)
                    self.assertEqual(buf.getvalue(), b"")

    def test_legit_team_logo_paths_still_resolve(self):
        """The real per-team logo/avatar paths named in the PR #780 review
        must still resolve exactly as before — a containment fix that
        breaks real logo serving is worse than the bug. Uses the same
        Path.home()-patched fixture technique as
        TestHeadGetParity.test_head_get_parity_for_team_logo_image (these
        are real, git-tracked assets on THIS machine but not guaranteed on
        a CI runner, since serve_image()'s lookup is Path.home()-relative,
        not checkout-relative)."""
        png_bytes = b'\x89PNG\r\n\x1a\n' + b'FIXTURE-PNG-BYTES-NOT-A-REAL-IMAGE'
        cases = [
            # (request path, on-disk base_team dir, on-disk filename)
            ("/images/dns_command_logo.png", "dns-framework", "dns_command_logo.png"),
            ("/images/legal_chambers_logo.png", "legal", "legal_chambers_logo.png"),
            ("/images/freelance_command_logo.png", "freelance", "freelance_command_logo.png"),
            # legal-coparenting -> legal alt_filename remap path.
            ("/images/legal-coparenting_chambers_logo.png", "legal", "legal_chambers_logo.png"),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            fake_home = Path(tmp)
            for _path, base_dir_name, filename in cases:
                logos_dir = fake_home / "dev-team" / base_dir_name / "terminals" / "logos"
                logos_dir.mkdir(parents=True, exist_ok=True)
                (logos_dir / filename).write_bytes(png_bytes)

            with patch.object(server, "LCARS_TEAM", "academy"), \
                 patch.object(server.Path, "home", return_value=fake_home):
                for path, _base_dir_name, _filename in cases:
                    with self.subTest(path=path):
                        handler, buf = _make_handler(path)
                        handler.serve_image(path)
                        self.assertEqual(handler._response_code, 200, path)
                        self.assertEqual(buf.getvalue(), png_bytes, path)

    def test_traversal_defense_can_actually_fail(self):
        """Mutation proof: reconstruct the PRE-FIX local-images lookup
        (bare `UI_DIR / "images" / filename`, no containment check) inline
        and confirm it DOES resolve to server.py's own source for
        '/images/../server.py' — proving the 404 tests above are not
        vacuously true against the current code."""
        filename = "../server.py"
        pre_fix_candidate = server.UI_DIR / "images" / filename
        self.assertTrue(
            pre_fix_candidate.exists(),
            "Fixture assumption broken: the pre-fix bare join no longer "
            "resolves to an existing file for this traversal path — this "
            "mutation no longer demonstrates the vulnerability the fix "
            "closes.",
        )
        # And it's genuinely OUTSIDE the images/ root, not some legitimate
        # same-directory file that happens to also be named via '../'.
        images_root = (server.UI_DIR / "images").resolve()
        with self.assertRaises(ValueError):
            pre_fix_candidate.resolve().relative_to(images_root)


# ---------------------------------------------------------------------------
# 6. PATH_PREFIXES membership + funnel-prefix behavior (XACA-0992 round three)
# ---------------------------------------------------------------------------
#
# A prior round of this ticket claimed medical-general had been added to
# PATH_PREFIXES and had NOT — it had instead added an unrelated
# 'medical': 'Medical' entry to _BASE_BRAND_SHORT_NAMES (a manifest
# short_name map, already covered by TestManifestShortNameAllRegisteredIds
# above), which does not touch funnel routing at all. medical-general sits
# at the identical architectural tier as legal-coparenting and
# finance-personal (see TEAM_KANBAN_DIRS / _PARAMETERIZED_TEMPLATES in
# server.py) — both of which WERE already present — so its absence from
# PATH_PREFIXES was the actual, unfixed gap. Live-verified against a
# throwaway `LCARS_TEAM=medical-general` server on a scratch port: bare
# '/medical-general' -> 301 to '/medical-general/', both GET and HEAD for
# '/medical-general/appicons/icon-192.png' -> 200 image/png with the SAME
# Content-Length as the unprefixed '/appicons/icon-192.png' route — exactly
# the behavior every other funnel-prefixed team gets.

class TestPathPrefixesMembership(unittest.TestCase):
    """Pins PATH_PREFIXES' membership so this specific regression — a team
    architecturally identical to two already-listed teams silently missing
    from the list — cannot recur unnoticed."""

    # The non-freelance prefixes are a fixed, hand-maintained list (freelance
    # entries are derived dynamically from the team registry — see the
    # class comment on PATH_PREFIXES itself — and are deliberately excluded
    # here so this test doesn't have to track per-machine overlay teams).
    EXPECTED_FIXED_PREFIXES = {
        '/academy', '/firebase', '/dns', '/command', '/ios', '/android',
        '/mainevent', '/legal-coparenting', '/medical-general', '/finance-personal',
    }

    def test_fixed_prefixes_match_exactly(self):
        actual_fixed = {
            p for p in server.LCARSHandler.PATH_PREFIXES
            if not p.startswith('/freelance-')
        }
        self.assertEqual(
            actual_fixed, self.EXPECTED_FIXED_PREFIXES,
            "PATH_PREFIXES' fixed (non-freelance) membership changed — if "
            "this was intentional (a new single-instance personal/funnel "
            "team), update EXPECTED_FIXED_PREFIXES here too; if not, a "
            "team was silently added or removed from funnel routing.",
        )

    def test_medical_general_is_present(self):
        """The specific regression this round fixed: medical-general sits
        at the same tier as legal-coparenting/finance-personal (both
        already present) but was missing."""
        self.assertIn('/medical-general', server.LCARSHandler.PATH_PREFIXES)

    def test_bare_medical_general_redirects_to_trailing_slash(self):
        with patch.object(server, "LCARS_TEAM", "medical-general"):
            handler, buf = _make_handler("/medical-general")
            handler.do_GET()
        self.assertEqual(handler._response_code, 301)
        self.assertIn(("Location", "/medical-general/"), handler._headers_sent)

    def test_medical_general_prefixed_appicon_matches_unprefixed(self):
        """'/medical-general/appicons/icon-192.png' must strip to
        '/appicons/icon-192.png' and serve identically — the same parity
        TestHeadGetParity pins for '/academy/appicons/icon-192.png'."""
        with patch.object(server, "LCARS_TEAM", "medical-general"):
            prefixed_handler, prefixed_buf = _make_handler(
                "/medical-general/appicons/icon-192.png")
            prefixed_handler.do_GET()
            bare_handler, bare_buf = _make_handler("/appicons/icon-192.png")
            bare_handler.do_GET()
        self.assertEqual(prefixed_handler._response_code, 200)
        self.assertEqual(bare_handler._response_code, 200)
        self.assertEqual(prefixed_buf.getvalue(), bare_buf.getvalue())

    def test_membership_pin_can_actually_fail(self):
        """Mutation proof: with medical-general removed from PATH_PREFIXES
        (reconstructing the exact pre-fix list), the bare-prefix redirect
        this file pins above must NOT fire — confirming the test is not
        vacuously true."""
        pre_fix_prefixes = tuple(
            p for p in server.LCARSHandler.PATH_PREFIXES if p != '/medical-general'
        )
        with patch.object(server, "LCARS_TEAM", "medical-general"), \
             patch.object(server.LCARSHandler, "PATH_PREFIXES", pre_fix_prefixes):
            handler, buf = _make_handler("/medical-general")
            handler.do_GET()
        self.assertNotEqual(
            handler._response_code, 301,
            "Pre-fix PATH_PREFIXES (without medical-general) was expected "
            "to NOT redirect the bare prefix — got a 301 anyway, so this "
            "mutation no longer demonstrates the regression the fix closes",
        )


if __name__ == "__main__":
    unittest.main()
