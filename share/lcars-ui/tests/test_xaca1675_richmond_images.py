#!/usr/bin/env python3

#
#  test_xaca1675_richmond_images.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
XACA-1675-004: every Richmond crew avatar, avatar thumbnail and terminal logo
must resolve through LCARS serve_image() to the RICHMOND FILE ITSELF.

Why bytes and not status codes
  serve_image() has no cross-team fallback of its own, but a 200 only proves
  *something* was served. The failure modes this suite exists to catch are:
    * the files were never generated (-> 404, the state at authoring time);
    * a placeholder / copy of another team's art was dropped in (-> 200 with
      the wrong bytes);
    * a flat file under lcars-ui/images/ shadows the team lookup (serve_image
      checks that location FIRST).
  So each case asserts the served bytes equal the file at the canonical
  richmond path, that the bytes are a real PNG of the documented size, and
  that no other team ships byte-identical art.

Where the lists come from (no hard-coded roster)
  * Slugs and terminal names: `_series_terminals` AFC arm in
    scripts/kb-init-team (the XACA-1674 roster, "terminal:slug" lines),
    cross-checked against the persona masters in
    .claude/agents-master/richmond/ (slug = 2nd filename token). The two
    sources must agree or the suite fails.
  * The one hard-coded entry is the `lcars` terminal (team identity logo):
    it is not in the series roster because every team gets it implicitly
    (docs/richmond-asset-prompts.md section 1.2 lists 8 terminal logos).
  * Both lists are asserted non-empty and of the documented size, so a parse
    that silently returns nothing FAILS instead of passing vacuously.

Harness: serve_image() is called directly on a socket-less handler (same
recipe as test_xaca1231_finance_logos.py). UI_DIR is pinned to this
checkout, Path.home() to an empty tmp dir and AITEAMFORGE_DIR is unset, so
only files tracked in THIS tree can satisfy a lookup (no ~/dev-team
fallback). No server is started; no real team is impersonated.

Run with:
    python3 -m pytest lcars-ui/tests/test_xaca1675_richmond_images.py -q
"""

import hashlib
import io
import os
import re
import struct
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
for _mod_name, _stub in _stub_modules.items():
    if _mod_name not in sys.modules:
        sys.modules[_mod_name] = _stub

_lcars_team_env_was_set = 'LCARS_TEAM' in os.environ
os.environ.setdefault('LCARS_TEAM', 'academy')
import server  # noqa: E402
if not _lcars_team_env_was_set:
    os.environ.pop('LCARS_TEAM', None)


TEAM = "richmond"
EXPECTED_CREW = 7
EXPECTED_TERMINAL_LOGOS = 8  # 7 crew terminals + lcars

AVATAR_DIR = REPO_ROOT / TEAM / "personas" / "avatars"
LOGO_DIR = REPO_ROOT / TEAM / "terminals" / "logos"
KB_INIT_TEAM = REPO_ROOT / "scripts" / "kb-init-team"
PERSONA_MASTER_DIR = REPO_ROOT / ".claude" / "agents-master" / TEAM

AVATAR_SIZE = (400, 400)
THUMB_SIZE = (200, 200)
LOGO_SIZE = (256, 256)

# Mirrored into the tap under share/, where none of the richmond/ asset
# directories exist. Same detection as test_xaca1231_finance_logos.py.
IN_TAP_MIRROR_LAYOUT = LCARS_UI_DIR.parent.name == "share"


# ---------------------------------------------------------------------------
# Canonical roster derivation
# ---------------------------------------------------------------------------

def _afc_terminal_pairs():
    """Parse the AFC arm of _series_terminals() in scripts/kb-init-team into
    [(terminal, slug), ...]. Raises AssertionError (never returns []) if the
    arm cannot be found, so a refactor of that script fails this suite loudly."""
    text = KB_INIT_TEAM.read_text()
    m = re.search(r"^\s*AFC\)\s*cat\s*<<'EOF'\n(.*?)^EOF\n", text, re.S | re.M)
    assert m, f"AFC arm of _series_terminals not found in {KB_INIT_TEAM}"
    pairs = []
    for line in m.group(1).splitlines():
        line = line.strip()
        if not line:
            continue
        terminal, _, slug = line.partition(":")
        assert terminal and slug, f"malformed roster line: {line!r}"
        pairs.append((terminal, slug))
    return pairs


def _persona_master_slugs():
    return sorted(
        p.name.split("_")[1]
        for p in PERSONA_MASTER_DIR.glob(f"{TEAM}_*_persona.md")
    )


def _roster():
    pairs = _afc_terminal_pairs()
    slugs = sorted(slug for _, slug in pairs)
    assert len(slugs) == EXPECTED_CREW, (
        f"roster resolved {len(slugs)} crew slugs, expected {EXPECTED_CREW}: {slugs}"
    )
    assert slugs == _persona_master_slugs(), (
        "kb-init-team AFC roster and .claude/agents-master/richmond/ personas "
        f"disagree: {slugs} vs {_persona_master_slugs()}"
    )
    terminals = ["lcars"] + [t for t, _ in pairs]
    assert len(terminals) == EXPECTED_TERMINAL_LOGOS, terminals
    return slugs, terminals


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

def _make_handler(path="/", method="GET"):
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
    handler.send_response = lambda code, message=None: setattr(handler, "_response_code", code)
    handler.send_header = lambda name, value: handler._headers_sent.append((name, value))
    handler.end_headers = lambda: None
    handler.send_error = MagicMock(
        side_effect=lambda code, msg=None: setattr(handler, "_response_code", code)
    )
    handler.log_message = MagicMock()
    handler.log_error = MagicMock()
    return handler, response_buf


def _png_dims(data: bytes):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG (bad magic)")
    return struct.unpack(">II", data[16:24])


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _other_team_asset_hashes():
    """sha256 -> relative path for every other team's deployed avatar/logo
    PNG. Used to prove richmond art is not a copy of someone else's."""
    seen = {}
    for pattern in ("*/personas/avatars/*.png", "*/terminals/logos/*.png"):
        for p in REPO_ROOT.glob(pattern):
            rel = p.relative_to(REPO_ROOT)
            if rel.parts[0] == TEAM:
                continue
            seen.setdefault(_sha(p.read_bytes()), str(rel))
    return seen


class _ServeImageBase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if IN_TAP_MIRROR_LAYOUT:
            raise unittest.SkipTest(
                f"running from the tap mirror ({LCARS_UI_DIR}); this suite checks "
                f"dev-team's canonical {TEAM}/ asset directories"
            )

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        home = Path(self._tmp.name) / "home"
        home.mkdir()
        for p in (
            patch.object(server, "UI_DIR", LCARS_UI_DIR),
            patch.object(server.Path, "home", return_value=home),
            patch.dict(os.environ, {}, clear=False),
        ):
            p.start()
            self.addCleanup(p.stop)
        os.environ.pop("AITEAMFORGE_DIR", None)

    def _serve(self, filename):
        handler, buf = _make_handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")
        return handler._response_code, buf.getvalue(), dict(handler._headers_sent)

    def _assert_resolves_to_file(self, filename, expected_path, expected_size):
        self.assertTrue(
            expected_path.is_file(),
            f"MISSING FILE: {expected_path.relative_to(REPO_ROOT)}",
        )
        expected = expected_path.read_bytes()
        code, body, headers = self._serve(filename)
        self.assertEqual(code, 200, f"{filename}: expected 200, got {code}")
        self.assertEqual(headers.get("Content-Type"), "image/png", filename)
        self.assertEqual(
            _sha(body), _sha(expected),
            f"{filename}: served bytes are not the file at "
            f"{expected_path.relative_to(REPO_ROOT)} (fallback or shadowing file?)",
        )
        self.assertEqual(_png_dims(body), expected_size, f"{filename}: wrong dimensions")
        return body


# ---------------------------------------------------------------------------
# 0. Roster + harness sanity (these must pass even before the images land)
# ---------------------------------------------------------------------------

class TestRosterAndHarness(_ServeImageBase):
    def test_roster_is_derived_and_complete(self):
        slugs, terminals = _roster()
        self.assertEqual(slugs, ["beard", "higgins", "keeley", "roy", "sharon", "ted", "trent"])
        self.assertEqual(len(terminals), EXPECTED_TERMINAL_LOGOS)
        self.assertEqual(terminals[0], "lcars")

    def test_harness_control_resolves_a_known_good_team(self):
        """Positive control: the identical code path resolves an existing
        team (snw) to its own bytes. If this fails the harness is broken, so
        a richmond failure cannot be trusted to mean 'files missing'."""
        control = REPO_ROOT / "snw" / "personas" / "avatars" / "snw_pike_avatar.png"
        self.assertTrue(control.is_file(), "control asset snw_pike_avatar.png missing")
        code, body, _ = self._serve("snw_pike_avatar.png")
        self.assertEqual(code, 200)
        self.assertEqual(body, control.read_bytes())

    def test_unknown_richmond_name_404s(self):
        """Negative control: the lookup is real filesystem resolution, not
        a catch-all that 200s any richmond_* name."""
        code, _, _ = self._serve("richmond_nobody_avatar.png")
        self.assertEqual(code, 404)

    def test_no_flat_shadow_files_for_richmond(self):
        """serve_image checks lcars-ui/images/<filename> BEFORE the team
        directories, so a flat richmond_* file there would mask the real
        asset and make every case below pass for the wrong reason."""
        shadows = sorted(p.name for p in (LCARS_UI_DIR / "images").glob(f"{TEAM}_*"))
        self.assertEqual(shadows, [], f"flat files shadow the team lookup: {shadows}")


# ---------------------------------------------------------------------------
# 1. Avatars and thumbnails
# ---------------------------------------------------------------------------

class TestRichmondAvatarsResolve(_ServeImageBase):
    def test_every_crew_avatar_and_thumb_resolves_to_its_own_file(self):
        slugs, _ = _roster()
        self.assertEqual(len(slugs), EXPECTED_CREW)  # fail closed on empty
        for slug in slugs:
            for suffix, size in (("avatar", AVATAR_SIZE), ("avatar_thumb", THUMB_SIZE)):
                name = f"{TEAM}_{slug}_{suffix}.png"
                with self.subTest(name=name):
                    self._assert_resolves_to_file(name, AVATAR_DIR / name, size)

    def test_thumb_is_distinct_from_full_avatar(self):
        slugs, _ = _roster()
        for slug in slugs:
            with self.subTest(slug=slug):
                full = AVATAR_DIR / f"{TEAM}_{slug}_avatar.png"
                thumb = AVATAR_DIR / f"{TEAM}_{slug}_avatar_thumb.png"
                self.assertTrue(full.is_file() and thumb.is_file(),
                                f"MISSING FILE for {slug}")
                self.assertNotEqual(_sha(full.read_bytes()), _sha(thumb.read_bytes()))

    def test_avatars_are_unique_and_not_copies_of_other_teams(self):
        slugs, _ = _roster()
        others = _other_team_asset_hashes()
        self.assertTrue(others, "no other-team assets found to compare against")
        seen = {}
        for slug in slugs:
            for suffix in ("avatar", "avatar_thumb"):
                name = f"{TEAM}_{slug}_{suffix}.png"
                with self.subTest(name=name):
                    path = AVATAR_DIR / name
                    self.assertTrue(path.is_file(), f"MISSING FILE: {path.relative_to(REPO_ROOT)}")
                    digest = _sha(path.read_bytes())
                    self.assertNotIn(digest, others,
                                     f"{name} is byte-identical to {others.get(digest)}")
                    self.assertNotIn(digest, seen,
                                     f"{name} duplicates {seen.get(digest)}")
                    seen[digest] = name


# ---------------------------------------------------------------------------
# 2. Terminal logos
# ---------------------------------------------------------------------------

class TestRichmondTerminalLogosResolve(_ServeImageBase):
    def test_every_terminal_logo_resolves_to_its_own_file(self):
        _, terminals = _roster()
        self.assertEqual(len(terminals), EXPECTED_TERMINAL_LOGOS)  # fail closed on empty
        for terminal in terminals:
            name = f"{TEAM}_{terminal}_logo.png"
            with self.subTest(name=name):
                self._assert_resolves_to_file(name, LOGO_DIR / name, LOGO_SIZE)

    def test_logos_are_unique_and_not_copies_of_other_teams(self):
        _, terminals = _roster()
        others = _other_team_asset_hashes()
        self.assertTrue(others, "no other-team assets found to compare against")
        seen = {}
        for terminal in terminals:
            name = f"{TEAM}_{terminal}_logo.png"
            with self.subTest(name=name):
                path = LOGO_DIR / name
                self.assertTrue(path.is_file(), f"MISSING FILE: {path.relative_to(REPO_ROOT)}")
                digest = _sha(path.read_bytes())
                self.assertNotIn(digest, others,
                                 f"{name} is byte-identical to {others.get(digest)}")
                self.assertNotIn(digest, seen, f"{name} duplicates {seen.get(digest)}")
                seen[digest] = name


# ---------------------------------------------------------------------------
# 3. Terminal logo transparency (XACA-1675-012, -013, -014)
# ---------------------------------------------------------------------------

FLEET_AVATAR_DIR = REPO_ROOT / "fleet-monitor" / "server" / "public" / "avatars"

# Every place a terminal logo ships. The badges are circles on a transparent
# field, so all four corners must be fully transparent. The image generator
# painted its grey/white "transparency" checkerboard INTO the pixels of 7 of
# the 8 originals, and they rendered as light squares on the black LCARS
# panel. Resolver checks cannot see that, because they never look inside the file.
LOGO_LOCATIONS = (
    ("originals", lambda t: LOGO_DIR / "originals" / f"{TEAM}_{t}_logo.png"),
    ("deployed", lambda t: LOGO_DIR / f"{TEAM}_{t}_logo.png"),
    ("fleet-monitor", lambda t: FLEET_AVATAR_DIR / f"{TEAM}_{t}_logo.png"),
    ("fleet-monitor panel", lambda t: FLEET_AVATAR_DIR / f"{TEAM}_{t}_logo_panel.png"),
)


# Fraction of alpha-boundary pixels allowed to be neutral light grey. A clean
# badge edge is saturated rim colour: SNW's 8 logos and Richmond's lcars logo
# all measure 0%. A circle mask applied over a baked checkerboard left a 1px
# arc of it along the rim, which measured 50-74%.
MAX_EDGE_FRINGE = 0.02


def _edge_fringe_fraction(im):
    """Share of the opaque pixels on the alpha boundary that are neutral light
    grey (min channel >= 150, spread <= 24): leftover checkerboard."""
    from PIL import ImageChops, ImageFilter

    opaque = im.getchannel("A").point(lambda v: 255 if v >= 128 else 0)
    edge = ImageChops.subtract(opaque, opaque.filter(ImageFilter.MinFilter(3)))
    r, g, b = im.convert("RGB").split()
    lo = ImageChops.darker(ImageChops.darker(r, g), b)
    hi = ImageChops.lighter(ImageChops.lighter(r, g), b)
    neutral = ImageChops.multiply(
        lo.point(lambda v: 255 if v >= 150 else 0),
        ImageChops.subtract(hi, lo).point(lambda v: 255 if v <= 24 else 0),
    )
    n_edge = edge.histogram()[255]
    n_grey = ImageChops.multiply(edge, neutral).histogram()[255]
    return n_grey / n_edge if n_edge else 0.0


def _logo_background_problem(path):
    """None if the PNG at `path` is RGBA with all four corners at alpha 0 and
    no checkerboard fringe along the badge edge, else why not."""
    from PIL import Image  # gen-appicons.py dependency; absent => fail, not skip

    with Image.open(path) as im:
        if im.mode != "RGBA":
            return f"{path.name} is {im.mode}, has no alpha channel"
        w, h = im.size
        corners = [im.getpixel(xy) for xy in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1))]
        fringe = _edge_fringe_fraction(im)
    if [c[3] for c in corners] != [0, 0, 0, 0]:
        return f"{path.name}: opaque corners {corners} (baked-in checkerboard or solid background?)"
    if fringe > MAX_EDGE_FRINGE:
        return (f"{path.name}: {fringe:.1%} of the badge edge is light grey "
                f"(> {MAX_EDGE_FRINGE:.0%}): checkerboard fringe left by the mask")
    return None


class TestRichmondTerminalLogoTransparency(_ServeImageBase):
    def test_every_logo_in_every_location_has_a_clean_transparent_background(self):
        _, terminals = _roster()
        self.assertEqual(len(terminals), EXPECTED_TERMINAL_LOGOS)  # fail closed on empty
        checked = 0
        for terminal in terminals:
            for location, path_for in LOGO_LOCATIONS:
                path = path_for(terminal)
                with self.subTest(terminal=terminal, location=location):
                    self.assertTrue(path.is_file(), f"MISSING FILE: {path.relative_to(REPO_ROOT)}")
                    problem = _logo_background_problem(path)
                    self.assertIsNone(problem, f"{path.relative_to(REPO_ROOT)}: {problem}")
                    checked += 1
        self.assertEqual(checked, EXPECTED_TERMINAL_LOGOS * len(LOGO_LOCATIONS))

    def test_checker_rejects_baked_checkerboards(self):
        """Negative controls: the defect shapes actually shipped (an RGB
        checkerboard original, an RGBA panel whose checkerboard is opaque,
        and a masked badge with a checkerboard arc left on its rim) must be
        rejected, and a cleanly masked badge accepted."""
        from PIL import Image, ImageDraw

        def checkerboard(mode):
            im = Image.new(mode, (64, 64))
            light = (255, 255, 255) + ((255,) if mode == "RGBA" else ())
            dark = (185, 185, 185) + ((255,) if mode == "RGBA" else ())
            for y in range(64):
                for x in range(64):
                    im.putpixel((x, y), light if (x // 8 + y // 8) % 2 == 0 else dark)
            return im

        masked = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
        ImageDraw.Draw(masked).ellipse((0, 0, 63, 63), fill=(0, 40, 230, 255))

        fringed = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
        ImageDraw.Draw(fringed).ellipse((0, 0, 63, 63), fill=(0, 40, 230, 255),
                                        outline=(200, 200, 200, 255), width=1)

        tmp = Path(self._tmp.name)
        for name, im, should_pass in (
            ("rgb_checker.png", checkerboard("RGB"), False),
            ("rgba_opaque_checker.png", checkerboard("RGBA"), False),
            ("fringed_badge.png", fringed, False),
            ("masked_badge.png", masked, True),
        ):
            with self.subTest(case=name):
                path = tmp / name
                im.save(path)
                problem = _logo_background_problem(path)
                if should_pass:
                    self.assertIsNone(problem)
                else:
                    self.assertIsNotNone(problem, f"{name} was accepted")

if __name__ == "__main__":
    unittest.main()
