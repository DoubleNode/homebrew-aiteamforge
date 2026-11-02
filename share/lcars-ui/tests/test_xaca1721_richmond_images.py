#!/usr/bin/env python3

#
#  test_xaca1721_richmond_images.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Tests for XACA-1721: the tap shipped NO richmond avatars or terminal logos
(`share/personas/richmond/avatars/` and `share/terminals/richmond/logos/` did
not exist in the homebrew-tap), so every consumer's richmond LCARS 404'd all
14 avatars and its logo regardless of install method. sync-tap.sh simply had
no sync_dir mapping for `richmond/personas/avatars` or
`richmond/terminals/logos` (XACA-1713 mirrored only `richmond/scripts/prompts`).

This is the XACA-1231 delivery proof for richmond, end to end, in a sandbox:

  (a) MIRROR: the CURRENT sync-tap.sh, run in write mode into a mktemp scratch
      tap (never the real homebrew-tap/ checkout), lands exactly the canonical
      avatars at share/personas/richmond/avatars and logos at
      share/terminals/richmond/logos, byte-identical, with NO originals/ path.
  (b) CONSUMER DELIVERY: the tap's two copy paths -- the fresh-install loop in
      bin/aiteamforge-setup.sh and `update_team_image_assets`
      (libexec/commands/aiteamforge-upgrade.sh, XACA-1221) -- both land those
      files under an install dir, run against the scratch tap with HOME and
      AITEAMFORGE_DIR pointed into a tmp dir (exported BEFORE anything runs).
  (c) SERVE: serve_image() returns 200 (real bytes) for the delivered files
      with NO ~/dev-team present, and 404 when the delivered dirs are absent.

Negative control: the script under test can be swapped with the env var
XACA1721_SYNC_TAP_SCRIPT (a path to an alternate sync-tap.sh, e.g. the
pre-fix `git show <rev>:sync-tap.sh`). Against a sync-tap.sh lacking the two
richmond sync_dir lines, (a) fails on the missing directories and (b)/(c)
fail because nothing was delivered -- proving the suite is not vacuous.

Safety: nothing here touches the real $HOME, ~/dev-team, or the worktree's
homebrew-tap/ (read only: the tap's setup/upgrade scripts are read and slices
of them executed in a subshell whose HOME/AITEAMFORGE_DIR/INSTALL_DIR are all
under a tmp dir). The only write-mode sync-tap.sh run targets a mktemp tree.

Requires the homebrew-tap submodule checkout for (b) (the tap's own scripts
are the system under test); when it is not initialized those tests skip with an
explicit reason (see conftest.py, XACA-1231-018). Part (a) needs no tap content.

Run with:
    python3 -m pytest lcars-ui/tests/test_xaca1721_richmond_images.py -q
"""

import importlib.util  # noqa: F401  (kept for parity with sibling suites)
import io
import os
import re
import shutil
import subprocess
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


# ---------------------------------------------------------------------------
# Constants / layout
# ---------------------------------------------------------------------------

TEAM = "richmond"
CANON_AVATARS = REPO_ROOT / TEAM / "personas" / "avatars"
CANON_LOGOS = REPO_ROOT / TEAM / "terminals" / "logos"

SYNC_TAP_DEFAULT = REPO_ROOT / "sync-tap.sh"
SYNC_TAP = Path(os.environ.get("XACA1721_SYNC_TAP_SCRIPT") or SYNC_TAP_DEFAULT)

TAP_SRC = REPO_ROOT / "homebrew-tap"
SETUP_SH = TAP_SRC / "bin" / "aiteamforge-setup.sh"
UPGRADE_SH = TAP_SRC / "libexec" / "commands" / "aiteamforge-upgrade.sh"

# The test is also mirrored into the tap (share/lcars-ui/tests/), where
# REPO_ROOT is share/ and none of richmond/, sync-tap.sh or homebrew-tap exist.
IN_TAP_MIRROR_LAYOUT = LCARS_UI_DIR.parent.name == "share"

SAMPLE_AVATAR_THUMB = "richmond_ted_avatar_thumb.png"
SAMPLE_LOGO = "richmond_lcars_logo.png"


def _canonical_pngs(d: Path):
    """Top-level *.png files only (originals/ is a subdir and never ships)."""
    return sorted(p.name for p in d.iterdir() if p.is_file() and p.suffix == ".png")


def _skip_in_tap_mirror_layout():
    if IN_TAP_MIRROR_LAYOUT:
        raise unittest.SkipTest(
            f"running from the tap mirror ({LCARS_UI_DIR}); this suite checks "
            f"dev-team's canonical richmond assets and sync-tap.sh, which the "
            f"tap layout does not carry"
        )


def _tap_scripts_missing_reason():
    """None when the tap submodule content this suite executes is present."""
    missing = [p for p in (SETUP_SH, UPGRADE_SH) if not p.is_file()]
    if not missing:
        return None
    return (
        f"homebrew-tap submodule not initialized (missing {missing[0]}) -- run "
        f"`git submodule update --init homebrew-tap` (or clone with "
        f"--recurse-submodules) to enable the consumer-delivery checks"
    )


# ---------------------------------------------------------------------------
# Scratch tap: built ONCE per module from the CURRENT (or overridden)
# sync-tap.sh, in write mode, into a mktemp tree. Never the real tap.
# ---------------------------------------------------------------------------

_SCRATCH = {"root": None, "ref": None, "tap": None, "run": None}


def _clean_env(home: Path, extra=None):
    """Minimal env: no inherited git env, HOME/AITEAMFORGE_DIR in the sandbox."""
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(home),
        "TMPDIR": str(home.parent),
        "LANG": "C",
    }
    if extra:
        env.update(extra)
    return env


def setUpModule():
    if IN_TAP_MIRROR_LAYOUT:
        return
    root = Path(tempfile.mkdtemp(prefix="xaca1721-")).resolve()
    _SCRATCH["root"] = root
    home = root / "home"
    home.mkdir()
    ref = root / "ref"
    (ref / "homebrew-tap" / "share").mkdir(parents=True)
    _SCRATCH["ref"] = ref
    _SCRATCH["tap"] = ref / "homebrew-tap"

    # Sandbox sanity: the scratch tree must not alias the real tap or real HOME.
    real_home = Path(os.path.expanduser("~")).resolve()
    assert real_home not in root.parents or root.parent == Path(tempfile.gettempdir()).resolve()
    assert ref.resolve() != (REPO_ROOT / "homebrew-tap").resolve()

    if not SYNC_TAP.is_file():
        _SCRATCH["run"] = subprocess.CompletedProcess([], 127, "", f"missing {SYNC_TAP}")
        return
    _SCRATCH["run"] = subprocess.run(
        [
            str(SYNC_TAP), "--allow-local-write",
            "XACA-1721 sandbox delivery test (scratch tap under mktemp)",
            "--source-dir", str(REPO_ROOT),
            "--reference-dir", str(ref),
        ],
        env=_clean_env(home, {"AITEAMFORGE_DIR": str(root / "aiteamforge")}),
        capture_output=True, text=True, timeout=600, cwd=str(root),
    )


def tearDownModule():
    root = _SCRATCH.get("root")
    if root is not None and root.name.startswith("xaca1721-"):
        shutil.rmtree(root, ignore_errors=True)


def _tap_avatars() -> Path:
    return _SCRATCH["tap"] / "share" / "personas" / TEAM / "avatars"


def _tap_logos() -> Path:
    return _SCRATCH["tap"] / "share" / "terminals" / TEAM / "logos"


# ---------------------------------------------------------------------------
# (a) sync-tap.sh mapping
# ---------------------------------------------------------------------------

class TestSyncTapMirrorsRichmondImages(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _skip_in_tap_mirror_layout()

    def test_scratch_sync_ran_clean(self):
        run = _SCRATCH["run"]
        self.assertEqual(
            run.returncode, 0,
            f"sync-tap.sh ({SYNC_TAP}) failed in the scratch tap:\n{run.stderr[-2000:]}",
        )

    def test_canonical_sources_have_expected_inventory(self):
        """Anti-vacuity: the canonical dirs hold the 14 avatars (7 + 7 _thumb)
        and 8 logos (7 terminal + lcars) this ticket is about, plus an
        originals/ subdir that must NOT ship."""
        avatars = _canonical_pngs(CANON_AVATARS)
        logos = _canonical_pngs(CANON_LOGOS)
        self.assertEqual(len(avatars), 14, avatars)
        self.assertEqual(len([a for a in avatars if a.endswith("_avatar_thumb.png")]), 7)
        self.assertEqual(len(logos), 8, logos)
        self.assertIn(SAMPLE_AVATAR_THUMB, avatars)
        self.assertIn(SAMPLE_LOGO, logos)
        self.assertTrue((CANON_AVATARS / "originals").is_dir(), "fixture sanity: originals/ exists")
        self.assertTrue((CANON_LOGOS / "originals").is_dir(), "fixture sanity: originals/ exists")

    def test_avatars_land_exactly_and_byte_identical(self):
        self.assertTrue(_tap_avatars().is_dir(), f"not mirrored: {_tap_avatars()}")
        self.assertEqual(
            sorted(p.name for p in _tap_avatars().iterdir()),
            _canonical_pngs(CANON_AVATARS),
        )
        for name in _canonical_pngs(CANON_AVATARS):
            with self.subTest(name=name):
                self.assertEqual(
                    (_tap_avatars() / name).read_bytes(), (CANON_AVATARS / name).read_bytes()
                )

    def test_logos_land_exactly_and_byte_identical(self):
        self.assertTrue(_tap_logos().is_dir(), f"not mirrored: {_tap_logos()}")
        self.assertEqual(
            sorted(p.name for p in _tap_logos().iterdir()),
            _canonical_pngs(CANON_LOGOS),
        )
        for name in _canonical_pngs(CANON_LOGOS):
            with self.subTest(name=name):
                self.assertEqual(
                    (_tap_logos() / name).read_bytes(), (CANON_LOGOS / name).read_bytes()
                )

    def test_no_originals_path_anywhere_under_richmond_in_tap(self):
        leaked = []
        for base in (_SCRATCH["tap"] / "share" / "personas" / TEAM,
                     _SCRATCH["tap"] / "share" / "terminals" / TEAM):
            if base.is_dir():
                leaked += [str(p) for p in base.rglob("*") if "originals" in p.parts]
        self.assertEqual(leaked, [], "originals/ is source art and must never ship")
        # ...and the avatar/logo dirs must exist for that to mean anything.
        self.assertTrue(_tap_avatars().is_dir() and _tap_logos().is_dir())


# ---------------------------------------------------------------------------
# (b) consumer delivery: fresh install loop + upgrade refresh
# ---------------------------------------------------------------------------

def _slice_lines(text: str, start_re: str, end_re: str) -> str:
    lines = text.splitlines()
    out, on = [], False
    for ln in lines:
        if not on and re.search(start_re, ln):
            on = True
        if on:
            out.append(ln)
            if re.search(end_re, ln):
                return "\n".join(out) + "\n"
    return ""


def _extract_fn(text: str, name: str) -> str:
    """A top-level `name() {` ... `}` shell function (same slice as the
    XACA-1221 shell suite's awk _extract_fn)."""
    lines = text.splitlines()
    out, on = [], False
    for ln in lines:
        if not on and re.match(rf"^{re.escape(name)}\(\) \{{", ln):
            on = True
        if on:
            out.append(ln)
            if ln == "}":
                return "\n".join(out) + "\n"
    return ""


class _ConsumerBase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _skip_in_tap_mirror_layout()
        reason = _tap_scripts_missing_reason()
        if reason:
            raise unittest.SkipTest(reason)

    def setUp(self):
        self._ctx = tempfile.TemporaryDirectory(prefix="xaca1721-consumer-")
        self.addCleanup(self._ctx.cleanup)
        self.tmp = Path(self._ctx.name).resolve()
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.install = self.tmp / "aiteamforge"  # AITEAMFORGE_DIR / INSTALL_DIR / WORKING_DIR
        self.install.mkdir()
        # The sandbox must be nowhere near the real HOME.
        real_home = Path(os.path.expanduser("~")).resolve()
        self.assertNotEqual(self.home, real_home)

    def _run_bash(self, script_body: str):
        env = _clean_env(self.home, {
            # exported into the sandbox BEFORE bash starts / sources anything
            "AITEAMFORGE_DIR": str(self.install),
        })
        return subprocess.run(
            ["bash", "-c", script_body], env=env, capture_output=True, text=True,
            timeout=120, cwd=str(self.tmp),
        )

    def _assert_delivered(self, root: Path):
        av = root / TEAM / "personas" / "avatars"
        lg = root / TEAM / "terminals" / "logos"
        self.assertEqual(sorted(p.name for p in av.iterdir()), _canonical_pngs(CANON_AVATARS))
        self.assertEqual(sorted(p.name for p in lg.iterdir()), _canonical_pngs(CANON_LOGOS))
        for name in _canonical_pngs(CANON_AVATARS):
            self.assertEqual((av / name).read_bytes(), (CANON_AVATARS / name).read_bytes(), name)
        for name in _canonical_pngs(CANON_LOGOS):
            self.assertEqual((lg / name).read_bytes(), (CANON_LOGOS / name).read_bytes(), name)
        # flat pool read by agent-panel-display.sh carries both kinds
        pool = sorted(p.name for p in (root / "avatars").iterdir())
        self.assertEqual(pool, sorted(_canonical_pngs(CANON_AVATARS) + _canonical_pngs(CANON_LOGOS)))


class TestFreshInstallDeliversRichmondImages(_ConsumerBase):
    """bin/aiteamforge-setup.sh's persona/avatar/logo copy loop."""

    def test_setup_copy_loop_lands_richmond_assets(self):
        block = _slice_lines(
            SETUP_SH.read_text(),
            r"^_personas_copied=0$",
            r"^\[ \$_logos_copied -gt 0 \] && echo",
        )
        self.assertIn("_logos_copied", block, "could not extract the setup copy loop")
        body = (
            "set -eo pipefail\n"
            'GREEN=""; NC=""\n'
            f'AITEAMFORGE_HOME="{_SCRATCH["tap"]}"\n'
            f'INSTALL_DIR="{self.install}"\n'
            'INSTALL_PROFILE="full"\n'
            f"SELECTED_TEAMS=({TEAM})\n"
            f"{block}"
            "echo SETUP_LOOP_DONE\n"
        )
        run = self._run_bash(body)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("SETUP_LOOP_DONE", run.stdout)
        self.assertIn("Agent personas and avatars (1 teams)", run.stdout)
        self.assertIn("Terminal logos (1 teams)", run.stdout)
        self._assert_delivered(self.install)


class TestUpgradeDeliversRichmondImages(_ConsumerBase):
    """libexec/commands/aiteamforge-upgrade.sh update_team_image_assets (XACA-1221)."""

    def test_update_team_image_assets_lands_richmond_assets(self):
        text = UPGRADE_SH.read_text()
        fns = _extract_fn(text, "update_team_image_assets") + _extract_fn(text, "_xaca0925_valid_team_id")
        self.assertIn("update_team_image_assets()", fns)
        self.assertIn("_xaca0925_valid_team_id()", fns)
        (self.install / TEAM).mkdir()  # refresh-only: team must already be provisioned
        body = (
            "set -eo pipefail\n"
            'for _p in print_section print_info print_success print_warning print_error; do\n'
            '  eval "${_p}() { printf \'%s: %s\\n\' ${_p} \\"\\$*\\"; }"\n'
            "done\n"
            f"{fns}\n"
            f'FRAMEWORK_DIR="{_SCRATCH["tap"]}"\n'
            f'WORKING_DIR="{self.install}"\n'
            "DRY_RUN=false\n"
            "update_team_image_assets\n"
            "echo UPGRADE_FN_DONE\n"
        )
        run = self._run_bash(body)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("UPGRADE_FN_DONE", run.stdout)
        self.assertIn("1 team(s): 44 written, 0 current, 0 failed", run.stdout)
        self._assert_delivered(self.install)


# ---------------------------------------------------------------------------
# (c) serve_image on a delivered install, no ~/dev-team
# ---------------------------------------------------------------------------

def _make_handler(module, path="/", method="GET"):
    response_buf = io.BytesIO()
    with patch.object(module.LCARSHandler, "__init__", lambda self, *a, **kw: None):
        handler = module.LCARSHandler.__new__(module.LCARSHandler)
    handler.path = path
    handler.command = method
    handler.rfile = io.BytesIO(b"")
    handler.wfile = response_buf
    handler.server = MagicMock()
    handler.headers = {}
    handler.directory = str(module.UI_DIR)
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


class TestServeImageOnDeliveredInstall(_ConsumerBase):
    """Run the real delivery (setup copy loop) into an install dir, then point
    serve_image's installed-layout root at it with no ~/dev-team present."""

    def setUp(self):
        super().setUp()
        self.ui_dir = self.install / "lcars-ui"
        (self.ui_dir / "images").mkdir(parents=True)
        self.dev_team_dir = self.home / "dev-team"  # deliberately NEVER created
        for p in (
            patch.object(server, "UI_DIR", self.ui_dir),
            patch.object(server.Path, "home", return_value=self.home),
            patch.dict(os.environ, {}, clear=False),
        ):
            p.start()
            self.addCleanup(p.stop)
        os.environ.pop("AITEAMFORGE_DIR", None)

    def _deliver_via_setup_loop(self):
        block = _slice_lines(
            SETUP_SH.read_text(),
            r"^_personas_copied=0$",
            r"^\[ \$_logos_copied -gt 0 \] && echo",
        )
        run = self._run_bash(
            "set -eo pipefail\nGREEN=''; NC=''\n"
            f'AITEAMFORGE_HOME="{_SCRATCH["tap"]}"\nINSTALL_DIR="{self.install}"\n'
            f'INSTALL_PROFILE="full"\nSELECTED_TEAMS=({TEAM})\n{block}'
            # the block's last line is `[ n -gt 0 ] && echo`, rc 1 when nothing copied
            "true\n"
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def _get(self, name):
        handler, buf = _make_handler(server, f"/images/{name}")
        handler.serve_image(f"/images/{name}")
        return handler, buf

    def test_delivered_richmond_images_return_200_without_dev_team(self):
        self.assertFalse(self.dev_team_dir.exists(), "fixture sanity: no ~/dev-team")
        self._deliver_via_setup_loop()

        for name, canon in (
            [(n, CANON_AVATARS) for n in _canonical_pngs(CANON_AVATARS)]
            + [(n, CANON_LOGOS) for n in _canonical_pngs(CANON_LOGOS)]
        ):
            with self.subTest(name=name):
                handler, buf = self._get(name)
                self.assertEqual(handler._response_code, 200, f"{name} did not resolve")
                self.assertEqual(buf.getvalue(), (canon / name).read_bytes())

        # The two named in the ticket, explicitly.
        for name in (SAMPLE_AVATAR_THUMB, SAMPLE_LOGO):
            handler, _ = self._get(name)
            self.assertEqual(handler._response_code, 200, name)
            self.assertEqual(dict(handler._headers_sent).get("Content-Type"), "image/png")

    def test_missing_delivered_dirs_return_404(self):
        """404 control: no delivery -> no image (and an unshipped name 404s even
        after delivery, so the 200s above are real filesystem resolution)."""
        for name in (SAMPLE_AVATAR_THUMB, SAMPLE_LOGO):
            with self.subTest(name=name, delivered=False):
                handler, buf = self._get(name)
                self.assertEqual(handler._response_code, 404)
                self.assertEqual(buf.getvalue(), b"")

        self._deliver_via_setup_loop()
        handler, _ = self._get("richmond_ghost_logo.png")
        self.assertEqual(handler._response_code, 404)


if __name__ == "__main__":
    unittest.main()
