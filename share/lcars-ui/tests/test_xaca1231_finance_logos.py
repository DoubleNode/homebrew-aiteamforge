#!/usr/bin/env python3

#
#  test_xaca1231_finance_logos.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Tests for XACA-1231: finance shipped NO tap-side terminal logos at all
(share/terminals/finance/logos/ did not exist in the homebrew-tap prior to
this ticket), so every consumer's LCARS 404'd on
`/images/finance_{bar,fca,lcars,nagus,vault,workshop}_logo.png` regardless
of install method. A second, related defect: dev-team's own canonical
`finance/terminals/logos/*.png` (the source these were mirrored from) were
1024x1024 byte-identical copies of their `originals/` masters -- unlike
every other team's 256x256 deployed convention -- so even a correct mirror
would have shipped 4x-oversized logos. Both are fixed as of this ticket:
the 6 files now exist under `finance/terminals/logos/` at 256x256 (via
`sips -Z 256` from each file's own `originals/` master, which is left
untouched at 1024x1024), and the tap ships a byte-identical mirror under
`share/terminals/finance/logos/` (see the sibling suite in the tap clone,
test-xaca-1231-finance-logos.sh, for tap-side shipping/setup/upgrade
delivery coverage).

This file covers the LCARS `serve_image()` half: proving a CONSUMER
(an installed AITeamForge, no ~/dev-team checkout) can actually resolve
these 6 files, using test_xaca1221_image_roots.py's exact
loading/handler-construction/installed-layout harness (XACA-1221 built
serve_image()'s root-resolution fallback chain this ticket's fix depends
on; this suite exercises that machinery with the REAL finance logo bytes
that ticket's own generic fixtures never touched).

Coverage:
  1. All 6 finance_*_logo.png resolve 200 from an installed layout (no
     ~/dev-team present at all), with response bytes equal to the
     installed file -- using the REAL deployed bytes from this repo's own
     finance/terminals/logos/.
  2. A 404 control: a filename in the same family that was never shipped
     (`finance_ghost_logo.png`) still 404s -- proving the installed-layout
     lookup is real filesystem resolution, not something that 200s on any
     finance_*_logo.png shape.
  3. Regression guard on the "deployed copy is just the master" defect:
     the 6 canonical DEPLOYED finance logos (finance/terminals/logos/*.png,
     the source serve_image ultimately mirrors from) are each exactly
     256x256, and each corresponding originals/ master is 1024x1024 --
     proving the deployed copies are actually downscaled, not identical
     copies of the originals (the second half of this ticket's defect).
  4. Canonical-vs-tap parity (PR #907 review, XACA-1231-014: an earlier
     revision of this docstring CLAIMED this was checked in case 1 above
     when no such code existed anywhere in this file): each of the 6
     canonical `finance/terminals/logos/*.png` files is byte-identical to
     its `homebrew-tap/share/terminals/finance/logos/*.png` counterpart --
     the tap-side suite (test-xaca-1231-finance-logos.sh in the tap clone)
     proves shipping/setup/upgrade delivery FROM the tap mirror, and this
     file's case 1 proves serve_image() delivery of the canonical bytes;
     this case is what proves those two are actually the SAME bytes, i.e.
     that no drift has opened up between the canonical source and the
     tap mirror it's supposed to equal. Runs only when the homebrew-tap
     submodule is initialized (true in CI, which checks out submodules);
     skipTest with an explicit reason otherwise (true in an uninitialized
     worktree checkout, where there is nothing to compare against).

Run with:
    python3 -m pytest lcars-ui/tests/test_xaca1231_finance_logos.py -q
  or alongside the XACA-1221 suite it reuses harness from:
    python3 -m pytest lcars-ui/tests/test_xaca1221_image_roots.py \
        lcars-ui/tests/test_xaca1231_finance_logos.py -q
"""

import importlib.util
import io
import os
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Bootstrap server.py imports (stub optional heavy dependencies) -- mirrors
# test_xaca1221_image_roots.py's own bootstrap so both suites share one
# import of `server` when run together (module caching means this block is a
# no-op on the second import).
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

_lcars_team_env_was_set = 'LCARS_TEAM' in os.environ
os.environ.setdefault('LCARS_TEAM', 'academy')
import server  # noqa: E402
if not _lcars_team_env_was_set:
    os.environ.pop('LCARS_TEAM', None)


# ---------------------------------------------------------------------------
# Handler construction helper -- identical to test_xaca1221_image_roots.py's
# _make_handler (duplicated rather than imported: tests/ files are not a
# package here, and this suite must also stand alone under a single-file
# `python3 -m pytest <this file>` invocation).
# ---------------------------------------------------------------------------

def _make_handler(module, path="/", method="GET"):
    """Construct a LCARSHandler instance (from the given server module) with
    all socket I/O mocked out. Returns (handler, response_buf)."""
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


def _png_dims(path: Path):
    """Portable PNG IHDR dimension read (same technique as the tap-side
    suite's `_png_dims` bash function): the PNG signature is 8 bytes, and
    the first chunk is always IHDR -- length(4) type(4) width(4) height(4)
    starting at byte 8, so width/height are the big-endian uint32s at
    offset 16 and 20. Returns (width, height) or raises on a bad file."""
    data = path.read_bytes()[:24]
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f"{path}: not a PNG (bad magic)")
    width, height = struct.unpack('>II', data[16:24])
    return width, height


TEAM = "finance"
LOGO_NAMES = [
    f"{TEAM}_bar_logo.png",
    f"{TEAM}_fca_logo.png",
    f"{TEAM}_lcars_logo.png",
    f"{TEAM}_nagus_logo.png",
    f"{TEAM}_vault_logo.png",
    f"{TEAM}_workshop_logo.png",
]

DEPLOYED_LOGOS_DIR = REPO_ROOT / "finance" / "terminals" / "logos"
ORIGINALS_DIR = DEPLOYED_LOGOS_DIR / "originals"

# This file is also mirrored into the tap at share/lcars-ui/tests/ (sync-tap.sh
# maps lcars-ui/), where REPO_ROOT is share/ and finance/terminals/logos does
# not exist. Skip ONLY in that mirrored layout, detected by lcars-ui/ sitting
# directly under a directory named "share" -- in the dev-team checkout a
# missing finance/terminals/logos must still FAIL, never skip (XACA-1231
# round-3 review; same outcome as test_xaca1221_image_roots.py in the tap).
IN_TAP_MIRROR_LAYOUT = LCARS_UI_DIR.parent.name == "share"


def _skip_in_tap_mirror_layout():
    if IN_TAP_MIRROR_LAYOUT:
        raise unittest.SkipTest(
            f"running from the tap mirror ({LCARS_UI_DIR}); this suite checks "
            f"dev-team's canonical finance/terminals/logos, which the tap layout "
            f"does not carry"
        )


# ---------------------------------------------------------------------------
# Fixture scaffold -- reuses test_xaca1221_image_roots.py's recipe: a
# TemporaryDirectory with an "install/lcars-ui" UI_DIR (root1, the installed
# layout) and Path.home() pointed at a tempdir with NO "dev-team" (root3),
# so a lookup can only succeed via root1. AITEAMFORGE_DIR (root2) is popped
# by default, exactly as XACA-1221's own base class does.
# ---------------------------------------------------------------------------

class _FinanceLogoDeliveryTestBase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _skip_in_tap_mirror_layout()

    def setUp(self):
        self._tmpdir_ctx = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir_ctx.cleanup)
        self.tmp = Path(self._tmpdir_ctx.name)

        self.ui_dir = self.tmp / "install" / "lcars-ui"
        (self.ui_dir / "images").mkdir(parents=True)
        self.root1 = self.ui_dir.parent  # installed layout: root1/finance/terminals/logos/...

        self.home = self.tmp / "home"
        self.home.mkdir()
        self.dev_team_dir = self.home / "dev-team"  # deliberately NEVER created

        self._start_patch(patch.object(server, "UI_DIR", self.ui_dir))
        self._start_patch(patch.object(server.Path, "home", return_value=self.home))
        self._start_patch(patch.dict(os.environ, {}, clear=False))
        os.environ.pop("AITEAMFORGE_DIR", None)

    def _start_patch(self, p):
        p.start()
        self.addCleanup(p.stop)
        return p

    def _handler(self, path, method="GET"):
        return _make_handler(server, path, method)

    def _install_finance_logos(self):
        """Copy the REAL deployed finance logo bytes from this repo's own
        finance/terminals/logos/ into the installed-layout root1, at the
        exact path serve_image() resolves for a 'logo' image type
        (team/terminals/logos/filename). Returns {filename: bytes}."""
        dst_dir = self.root1 / TEAM / "terminals" / "logos"
        dst_dir.mkdir(parents=True, exist_ok=True)
        installed = {}
        for name in LOGO_NAMES:
            src = DEPLOYED_LOGOS_DIR / name
            data = src.read_bytes()
            (dst_dir / name).write_bytes(data)
            installed[name] = data
        return installed


# ---------------------------------------------------------------------------
# 1. Installed-layout delivery, real bytes, no ~/dev-team present
# ---------------------------------------------------------------------------

class TestFinanceLogosServedFromInstalledLayout(_FinanceLogoDeliveryTestBase):
    """The core consumer-delivery proof: an installed AITeamForge (no
    ~/dev-team checkout on the box) must resolve every one of the 6 finance
    terminal logos, byte-identical to what was installed."""

    def test_all_six_finance_logos_return_200_with_matching_bytes(self):
        self.assertFalse(self.dev_team_dir.exists(), "fixture sanity: no ~/dev-team")
        installed = self._install_finance_logos()

        for name, expected_bytes in installed.items():
            with self.subTest(name=name):
                handler, buf = self._handler(f"/images/{name}")
                handler.serve_image(f"/images/{name}")

                self.assertEqual(handler._response_code, 200, f"{name} did not resolve")
                self.assertEqual(_headers_dict(handler).get("Content-Type"), "image/png")
                self.assertEqual(
                    buf.getvalue(), expected_bytes,
                    f"{name}: served bytes did not match the installed file",
                )

    def test_head_request_parity_for_a_finance_logo(self):
        installed = self._install_finance_logos()
        name = f"{TEAM}_lcars_logo.png"
        expected_bytes = installed[name]

        get_handler, get_buf = self._handler(f"/images/{name}", method="GET")
        get_handler.serve_image(f"/images/{name}")

        head_handler, head_buf = self._handler(f"/images/{name}", method="HEAD")
        head_handler.serve_image(f"/images/{name}", head_only=True)

        self.assertEqual(head_handler._response_code, 200)
        self.assertEqual(head_handler._response_code, get_handler._response_code)
        self.assertEqual(
            _headers_dict(head_handler).get("Content-Length"),
            _headers_dict(get_handler).get("Content-Length"),
        )
        self.assertEqual(
            int(_headers_dict(head_handler).get("Content-Length")), len(expected_bytes)
        )
        self.assertEqual(head_buf.getvalue(), b"", "HEAD must carry no body")
        self.assertEqual(get_buf.getvalue(), expected_bytes)


# ---------------------------------------------------------------------------
# 2. 404 control: a name in the same family that was never shipped
# ---------------------------------------------------------------------------

class TestUnshippedFinanceLogo404s(_FinanceLogoDeliveryTestBase):
    def test_unshipped_finance_logo_name_404s(self):
        """Proves case 1 above isn't vacuously true for ANY finance_*_logo.png
        shape -- only names actually installed resolve."""
        self._install_finance_logos()  # the 6 real ones exist...
        filename = f"{TEAM}_ghost_logo.png"  # ...this one was never shipped

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(handler._response_code, 404)
        self.assertEqual(buf.getvalue(), b"")


# ---------------------------------------------------------------------------
# 3. Regression guard: deployed copies are downscaled, not master copies
# ---------------------------------------------------------------------------

class TestDeployedFinanceLogoDimensions(unittest.TestCase):
    """XACA-1231's second defect: finance/terminals/logos/*.png were
    1024x1024 byte-identical copies of their originals/ masters (every
    other team ships 256x256 deployed logos with the 1024px master kept
    separately in originals/). Guards against a future regression re-copying
    a master over its deployed 256px file."""

    @classmethod
    def setUpClass(cls):
        _skip_in_tap_mirror_layout()

    def test_deployed_finance_logos_are_256x256(self):
        for name in LOGO_NAMES:
            with self.subTest(name=name):
                path = DEPLOYED_LOGOS_DIR / name
                self.assertTrue(path.is_file(), f"missing deployed file: {path}")
                dims = _png_dims(path)
                self.assertEqual(dims, (256, 256), f"{name}: deployed at {dims}, expected 256x256")

    def test_originals_masters_are_1024x1024_and_untouched(self):
        for name in LOGO_NAMES:
            with self.subTest(name=name):
                path = ORIGINALS_DIR / name
                self.assertTrue(path.is_file(), f"missing originals master: {path}")
                dims = _png_dims(path)
                self.assertEqual(dims, (1024, 1024), f"{name}: originals master at {dims}, expected 1024x1024")

    def test_deployed_is_not_byte_identical_to_originals_master(self):
        """The pre-fix defect specifically: deployed == originals (same
        bytes, same 1024x1024 dims). Confirms the deployed file is a real
        downscale, not a copy that merely happens to report 256x256 via a
        different code path."""
        for name in LOGO_NAMES:
            with self.subTest(name=name):
                deployed = (DEPLOYED_LOGOS_DIR / name).read_bytes()
                master = (ORIGINALS_DIR / name).read_bytes()
                self.assertNotEqual(
                    deployed, master,
                    f"{name}: deployed file is byte-identical to its originals/ master "
                    "(the pre-fix defect -- deployed copy was never downscaled)",
                )


# ---------------------------------------------------------------------------
# 4. Canonical-vs-tap parity (PR #907 review, XACA-1231-014)
# ---------------------------------------------------------------------------

TAP_LOGOS_DIR = REPO_ROOT / "homebrew-tap" / "share" / "terminals" / "finance" / "logos"


class TestCanonicalMatchesTapMirror(unittest.TestCase):
    """The docstring above used to CLAIM this comparison happened as part of
    case 1's fixture loading; it never did -- case 1 only ever reads
    finance/terminals/logos/ (the canonical source), never touches
    homebrew-tap/ at all. This class is the actual check: every one of the
    6 canonical deployed finance logos must be byte-identical to its
    homebrew-tap/share/terminals/finance/logos/ counterpart, proving no
    drift has opened up between the canonical source and the hand-mirrored
    tap copy (XACA-0340: canonical-source rule -- the tap copy is derived,
    never independently edited, so any divergence here is itself a bug).

    Requires the homebrew-tap submodule to be checked out (true in CI,
    which clones with --recurse-submodules / runs `git submodule update`).
    In an uninitialized worktree -- verified here: homebrew-tap/ exists as
    an empty directory, share/terminals/finance/logos/ absent under it --
    there is nothing to compare against, so every test in this class
    skips with an explicit reason rather than silently passing or
    fabricating a comparison target.
    """

    @classmethod
    def setUpClass(cls):
        _skip_in_tap_mirror_layout()
        if not TAP_LOGOS_DIR.is_dir():
            raise unittest.SkipTest(
                f"homebrew-tap submodule not initialized (or share/terminals/finance/"
                f"logos not present) at {TAP_LOGOS_DIR} -- run `git submodule update "
                f"--init` (or clone with --recurse-submodules) to enable this check"
            )

    def test_each_canonical_finance_logo_matches_tap_mirror_bytes(self):
        for name in LOGO_NAMES:
            with self.subTest(name=name):
                canonical_path = DEPLOYED_LOGOS_DIR / name
                tap_path = TAP_LOGOS_DIR / name
                self.assertTrue(canonical_path.is_file(), f"missing canonical file: {canonical_path}")
                self.assertTrue(tap_path.is_file(), f"missing tap mirror file: {tap_path}")
                canonical_bytes = canonical_path.read_bytes()
                tap_bytes = tap_path.read_bytes()
                self.assertEqual(
                    canonical_bytes, tap_bytes,
                    f"{name}: canonical finance/terminals/logos/ differs from the "
                    f"homebrew-tap/share/terminals/finance/logos/ mirror -- the tap "
                    f"copy has drifted from its canonical source (XACA-0340)",
                )


if __name__ == "__main__":
    unittest.main()
