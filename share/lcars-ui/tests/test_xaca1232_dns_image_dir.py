#!/usr/bin/env python3

#
#  test_xaca1232_dns_image_dir.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Tests for XACA-1232 (subitem 001): LCARS serve_image() hardcodes a
'dns' -> 'dns-framework' on-disk directory rewrite for EVERY candidate root
returned by _image_candidate_roots() (lcars-ui/server.py ~16960-16962):

    team_dir = self._resolve_base_team(team)
    if team_dir == 'dns':
        team_dir = 'dns-framework'

That rewrite is correct ONLY for a developer's ~/dev-team checkout (root3,
the legacy fallback), where dns's working tree historically lives under a
sibling directory named 'dns-framework' rather than 'dns'. It is WRONG for
the installed layout (root1: UI_DIR.absolute().parent, and root2:
$AITEAMFORGE_DIR) used by a Homebrew-tap-provisioned box, because BOTH the
fresh-install copy loop and the post-install refresh step lay dns's assets
under a directory named after its tap TEAM_ID, which is 'dns' — never
'dns-framework':

  - homebrew-tap/share/teams/dns.conf:29           TEAM_ID="dns"
  - homebrew-tap/bin/aiteamforge-setup.sh:1737      mkdir -p
        "${INSTALL_DIR}/${team_id}/personas/avatars"        (team_id=dns)
  - homebrew-tap/bin/aiteamforge-setup.sh:1747      cp
        "${AITEAMFORGE_HOME}/share/personas/${team_id}/avatars/"*.png
        "${INSTALL_DIR}/${team_id}/personas/avatars/"
  - homebrew-tap/bin/aiteamforge-setup.sh:1758      mkdir -p
        "${INSTALL_DIR}/${team_id}/terminals/logos"
  - homebrew-tap/bin/aiteamforge-setup.sh:1759      cp
        "${AITEAMFORGE_HOME}/share/terminals/${team_id}/logos/"*.png
        "${INSTALL_DIR}/${team_id}/terminals/logos/"
  - homebrew-tap/libexec/commands/aiteamforge-upgrade.sh:4499-4521
        update_team_image_assets(): teams enumerated by
        `ls -d "$share"/personas/*/avatars "$share"/terminals/*/logos`
        (the team id is the on-disk dirname under share/personas or
        share/terminals — 'dns' per share/personas/dns/agents/*.md), then
        `dst="${WORKING_DIR}/$t/$kind"` — again 'dns', never
        'dns-framework'.

So an installed dns box has its logo/avatar PNGs sitting at
<root>/dns/terminals/logos/*.png and <root>/dns/personas/avatars/*.png, but
serve_image() only ever looks under <root>/dns-framework/... for roots 1
and 2 (it applies the SAME rewrite to every root in
_image_candidate_roots(), not just root3) — a 404 on every dns image
request on any tap-provisioned machine.

This file proves the installed-layout gap with DESIRED-behavior (assert
200) tests, following test_xaca1221_image_roots.py's harness pattern
exactly (root1 = UI_DIR.absolute().parent; server.Path.home() patched to an
isolated tmp dir so no real ~/dev-team is ever reachable; no real server is
started; no real team id/port is used). These tests are expected to FAIL
at HEAD (server.py unmodified) and are expected to PASS once
XACA-1232-002 fixes serve_image() to only apply the dns-framework rewrite
for the ~/dev-team fallback root (or otherwise stops assuming every root
uses the legacy on-disk name).

Run with:
    python3 -m unittest lcars-ui/tests/test_xaca1232_dns_image_dir.py
  or:
    python3 -m pytest lcars-ui/tests/test_xaca1232_dns_image_dir.py -q
"""

import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Bootstrap server.py imports (stub optional heavy dependencies) — mirrors
# the convention established in test_xaca1221_image_roots.py / test_server.py.
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
# Handler construction helper — identical to test_xaca1221_image_roots.py's
# _make_handler (kept local, not imported, so this file has no cross-test
# import dependency; both mirror test_xaca0992_appicons.py's original).
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


PNG_MAGIC = b'\x89PNG\r\n\x1a\n'


def _png(payload: bytes) -> bytes:
    """A minimal-but-valid PNG: real magic bytes + a payload distinct
    enough that served bytes prove WHICH root/file served them."""
    return PNG_MAGIC + payload


def _write_png(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(_png(payload))


# ---------------------------------------------------------------------------
# Fixture scaffold — same recipe as _ImageRootsTestBase in
# test_xaca1221_image_roots.py, scoped to TEAM = "dns" and to root1 only
# (the installed layout — UI_DIR.absolute().parent). root3 (~/dev-team) is
# never created here, and Path.home() is patched to an isolated tmp dir, so
# no real ~/dev-team checkout on this machine is ever reachable regardless
# of what's actually on disk. No real server is started and no real team
# id/port is used ('dns' here only ever resolves against the sandboxed
# tmp roots below, never a live LCARS instance).
# ---------------------------------------------------------------------------

class _DnsInstalledLayoutTestBase(unittest.TestCase):
    TEAM = "dns"

    def setUp(self):
        self._tmpdir_ctx = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir_ctx.cleanup)
        self.tmp = Path(self._tmpdir_ctx.name)

        self.ui_dir = self.tmp / "install" / "lcars-ui"
        (self.ui_dir / "images").mkdir(parents=True)
        self.root1 = self.ui_dir.parent  # installed layout root

        self.home = self.tmp / "home"
        self.home.mkdir()
        # self.home / "dev-team" (root3, the legacy fallback) is
        # deliberately NEVER created — proves these fixtures aren't
        # accidentally served from the legacy root.

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

    # Installed-layout paths, as actually produced by aiteamforge-setup.sh /
    # aiteamforge-upgrade.sh's update_team_image_assets(): <root>/dns/...,
    # NOT <root>/dns-framework/... (that rewrite is legacy-checkout-only).
    def _installed_logo_path(self, filename: str) -> Path:
        return self.root1 / self.TEAM / "terminals" / "logos" / filename

    def _installed_avatar_path(self, filename: str) -> Path:
        return self.root1 / self.TEAM / "personas" / "avatars" / filename

    # What serve_image() ACTUALLY looks under today (the bug): the
    # dns-framework rewrite applied even to the installed-layout root.
    def _rewritten_logo_path(self, filename: str) -> Path:
        return self.root1 / "dns-framework" / "terminals" / "logos" / filename

    def _rewritten_avatar_path(self, filename: str) -> Path:
        return self.root1 / "dns-framework" / "personas" / "avatars" / filename

    # XACA-1232-004: the legacy dev-tree layout (~/dev-team checkout,
    # root3) — this IS the 'dns-framework' on-disk name, and must keep
    # resolving after the fix (_team_dir_candidates() tries it as the
    # second name, after the installed-layout 'dns' name).
    def _devtree_logo_path(self, filename: str) -> Path:
        return self.home / "dev-team" / "dns-framework" / "terminals" / "logos" / filename

    def _devtree_avatar_path(self, filename: str) -> Path:
        return self.home / "dev-team" / "dns-framework" / "personas" / "avatars" / filename

    # Generic per-(root, team_dir) path builders for precedence tests below,
    # where fixtures must be placed under BOTH 'dns' and 'dns-framework'
    # names within/under specific roots.
    def _logo_path_under(self, root: Path, team_dir: str, filename: str) -> Path:
        return root / team_dir / "terminals" / "logos" / filename

    def _avatar_path_under(self, root: Path, team_dir: str, filename: str) -> Path:
        return root / team_dir / "personas" / "avatars" / filename


# ---------------------------------------------------------------------------
# Desired behavior: installed-layout dns assets under <root>/dns/... must
# resolve. All three currently FAIL against HEAD's server.py (404), because
# serve_image() rewrites team_dir to 'dns-framework' unconditionally.
# ---------------------------------------------------------------------------

class TestInstalledLayoutDnsAssetsResolve(_DnsInstalledLayoutTestBase):
    def test_installed_layout_dns_logo_200(self):
        """<root>/dns/terminals/logos/dns_lcars_logo.png must resolve to
        200 on an installed (tap-provisioned) layout. FAILS at HEAD: the
        file is written under 'dns', but serve_image() only looks under
        'dns-framework' for this root, so it 404s."""
        filename = "dns_lcars_logo.png"
        payload = b"DNS-INSTALLED-LOGO"
        _write_png(self._installed_logo_path(filename), payload)

        # Fixture sanity: nothing exists at the legacy-rewrite location, and
        # no legacy ~/dev-team checkout exists either — a pass here can only
        # come from resolving the installed-layout 'dns' dir directly.
        self.assertFalse(self._rewritten_logo_path(filename).exists())
        self.assertFalse((self.home / "dev-team").exists())

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(
            handler._response_code, 200,
            "installed-layout dns logo under <root>/dns/terminals/logos/ "
            "must serve; serve_image() must not assume every root uses "
            "the legacy 'dns-framework' on-disk name",
        )
        self.assertEqual(_headers_dict(handler).get("Content-Type"), "image/png")
        self.assertEqual(buf.getvalue(), _png(payload))

    def test_installed_layout_dns_avatar_200(self):
        """<root>/dns/personas/avatars/dns_tendi_avatar.png must resolve to
        200 on an installed layout. FAILS at HEAD for the same reason as
        the logo case above."""
        filename = "dns_tendi_avatar.png"
        payload = b"DNS-INSTALLED-AVATAR"
        _write_png(self._installed_avatar_path(filename), payload)

        self.assertFalse(self._rewritten_avatar_path(filename).exists())
        self.assertFalse((self.home / "dev-team").exists())

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(
            handler._response_code, 200,
            "installed-layout dns avatar under <root>/dns/personas/avatars/ "
            "must serve",
        )
        self.assertEqual(_headers_dict(handler).get("Content-Type"), "image/png")
        self.assertEqual(buf.getvalue(), _png(payload))

    def test_installed_layout_dns_avatar_thumb_200(self):
        """<root>/dns/personas/avatars/dns_tendi_avatar_thumb.png (the
        agent-panel.html fallback thumbnail, XACA-1221 Decision 2) must
        also resolve on an installed layout. FAILS at HEAD for the same
        reason as the two cases above."""
        filename = "dns_tendi_avatar_thumb.png"
        payload = b"DNS-INSTALLED-AVATAR-THUMB"
        _write_png(self._installed_avatar_path(filename), payload)

        self.assertFalse(self._rewritten_avatar_path(filename).exists())
        self.assertFalse((self.home / "dev-team").exists())

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(
            handler._response_code, 200,
            "installed-layout dns avatar_thumb under "
            "<root>/dns/personas/avatars/ must serve",
        )
        self.assertEqual(_headers_dict(handler).get("Content-Type"), "image/png")
        self.assertEqual(buf.getvalue(), _png(payload))


# ---------------------------------------------------------------------------
# Confirms WHY it fails today: the same bytes, written at the REWRITTEN
# ('dns-framework') location instead, DO resolve at HEAD — isolating the
# defect to the team_dir rewrite rather than to some other root-resolution
# problem. This test is expected to PASS both before and after the fix (a
# legacy ~/dev-team-style checkout terminology is not what XACA-1232-002 is
# removing — only the unconditional application of it to every root).
# ---------------------------------------------------------------------------

class TestRewrittenLocationStillResolvesAtHead(_DnsInstalledLayoutTestBase):
    def test_dns_framework_rewritten_logo_currently_resolves(self):
        filename = "dns_lcars_logo.png"
        payload = b"DNS-FRAMEWORK-REWRITE-LOGO"
        _write_png(self._rewritten_logo_path(filename), payload)

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(
            handler._response_code, 200,
            "sanity check: today's dns->dns-framework rewrite is exactly "
            "what makes THIS location resolve — if this fails too, the "
            "defect is not where this file assumes it is",
        )
        self.assertEqual(buf.getvalue(), _png(payload))


# ---------------------------------------------------------------------------
# XACA-1232-004: dev-tree layout (~/dev-team checkout, root3) still
# resolves under 'dns-framework' with the installed root (root1) empty of
# dns assets — proves the fix ADDS the installed-layout name rather than
# REPLACING the legacy dev-tree name.
# ---------------------------------------------------------------------------

class TestDevTreeLayoutDnsFrameworkAssetsStillResolve(_DnsInstalledLayoutTestBase):
    def test_devtree_dns_framework_logo_200(self):
        filename = "dns_lcars_logo.png"
        payload = b"DEVTREE-DNS-FRAMEWORK-LOGO"
        _write_png(self._devtree_logo_path(filename), payload)

        # Fixture sanity: nothing under root1 at all (neither on-disk name),
        # so a pass here can only come from resolving root3's legacy name.
        self.assertFalse((self.root1 / "dns").exists())
        self.assertFalse((self.root1 / "dns-framework").exists())

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(
            handler._response_code, 200,
            "dev-tree dns-framework logo under ~/dev-team must still "
            "resolve when the installed root has nothing",
        )
        self.assertEqual(_headers_dict(handler).get("Content-Type"), "image/png")
        self.assertEqual(buf.getvalue(), _png(payload))

    def test_devtree_dns_framework_avatar_200(self):
        filename = "dns_tendi_avatar.png"
        payload = b"DEVTREE-DNS-FRAMEWORK-AVATAR"
        _write_png(self._devtree_avatar_path(filename), payload)

        self.assertFalse((self.root1 / "dns").exists())
        self.assertFalse((self.root1 / "dns-framework").exists())

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(handler._response_code, 200)
        self.assertEqual(_headers_dict(handler).get("Content-Type"), "image/png")
        self.assertEqual(buf.getvalue(), _png(payload))


# ---------------------------------------------------------------------------
# XACA-1232-004: precedence between the two on-disk team_dir names, and
# between root order and team_dir order (team_dirs is the INNER loop, roots
# are the OUTER loop — see _team_dir_candidates()'s docstring and the
# per-(root, team_dir) comment in serve_image()).
# ---------------------------------------------------------------------------

class TestDnsDirNamePrecedence(_DnsInstalledLayoutTestBase):
    def test_dns_beats_dns_framework_within_the_same_root(self):
        """Within ONE root (root1) with BOTH 'dns/' and 'dns-framework/'
        copies present (different bytes), the installed-layout name 'dns'
        (tried first per _team_dir_candidates()) must win."""
        filename = "dns_lcars_logo.png"
        _write_png(self._logo_path_under(self.root1, "dns", filename), b"ROOT1-DNS")
        _write_png(self._logo_path_under(self.root1, "dns-framework", filename), b"ROOT1-DNS-FRAMEWORK")

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(handler._response_code, 200)
        self.assertEqual(
            buf.getvalue(), _png(b"ROOT1-DNS"),
            "'dns' (installed-layout name, tried first) must win over "
            "'dns-framework' within the same root",
        )

    def test_root_order_beats_dir_name_order(self):
        """Root priority beats dir-name priority: root1 has ONLY a
        'dns-framework/' copy (the second-tried name), and root3
        (~/dev-team, tried LAST) has a 'dns/' copy (the first-tried name)
        with DIFFERENT bytes. root1's dns-framework bytes must still win,
        because the outer loop is roots, not team_dir names — root1 is
        exhausted (both its team_dir names tried) before root3 is ever
        probed."""
        filename = "dns_lcars_logo.png"
        _write_png(
            self._logo_path_under(self.root1, "dns-framework", filename),
            b"ROOT1-DNS-FRAMEWORK-ONLY",
        )
        _write_png(
            self._logo_path_under(self.home / "dev-team", "dns", filename),
            b"ROOT3-DNS-SHOULD-LOSE",
        )

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(handler._response_code, 200)
        self.assertEqual(
            buf.getvalue(), _png(b"ROOT1-DNS-FRAMEWORK-ONLY"),
            "root1 (outer loop, tried first) must win even via its "
            "second-tried team_dir name, over root3's first-tried name",
        )


# ---------------------------------------------------------------------------
# XACA-1232-004: traversal / invalid paths must still 404 through the new
# per-(root, team_dir) loop, including a symlink escape planted under the
# 'dns' (installed-layout) team_dir specifically.
# ---------------------------------------------------------------------------

class TestDnsTraversalAndSymlinkEscape(_DnsInstalledLayoutTestBase):
    def test_traversal_variants_return_404(self):
        traversal_paths = [
            "/images/../server.py",
            "/images/../../../../../../../etc/passwd",
            "/images/..%2fserver.py",
            "/images/..%252fserver.py",
            "/images//etc/shadow",
            f"/images/{self.TEAM}_../../../etc/passwd_avatar.png",
        ]
        for path in traversal_paths:
            with self.subTest(path=path):
                handler, buf = self._handler(path)
                handler.serve_image(path)
                self.assertEqual(handler._response_code, 404, path)
                self.assertEqual(buf.getvalue(), b"", path)

    def test_symlink_inside_dns_logos_dir_escaping_root_returns_404_not_500(self):
        """A symlink planted under <root1>/dns/terminals/logos/ (the
        installed-layout, first-tried team_dir) pointing OUTSIDE root1 must
        404, not leak the outside file's bytes or 500 — same containment
        guarantee as XACA-1221's per-root check, now exercised through the
        new per-team_dir loop too."""
        filename = "dns_sneaky_logo.png"
        logos_dir = self.root1 / "dns" / "terminals" / "logos"
        logos_dir.mkdir(parents=True)

        outside = self.tmp / "outside-root1"
        outside.mkdir()
        outside_file = outside / "secret.png"
        _write_png(outside_file, b"SECRET-BYTES-OUTSIDE-ROOT")

        (logos_dir / filename).symlink_to(outside_file)

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(
            handler._response_code, 404,
            "symlink escape under the dns team_dir must 404, not 500/leak",
        )
        self.assertEqual(buf.getvalue(), b"")


# ---------------------------------------------------------------------------
# XACA-1232-004: alt_filename regression. The legal-coparenting ->
# 'legal_<name>_avatar.png' alt-filename remap path (a DIFFERENT base-brand
# collapse, unrelated to the dns on-disk-directory quirk this ticket fixes)
# is already covered by
# tests/test_xaca0992_appicons.py::TestServeImageRejectsTraversal::
# test_legit_team_logo_paths_still_resolve (asserts
# /images/legal-coparenting_chambers_logo.png resolves via the
# legal_chambers_logo.png alt filename) — not duplicated here.
#
# What IS new to this ticket: proving alt_filename is derived from
# base_team (the base-brand collapse), never from whichever on-disk
# team_dir happens to be tried. For 'dns', base_team == team (no
# collapsing), so alt_filename must be None — serve_image() must never
# probe a 'dns-framework_...'-prefixed filename, even though
# 'dns-framework' IS one of the on-disk directory names it tries.
# ---------------------------------------------------------------------------

class TestDnsAltFilenameNotDerivedFromTeamDir(_DnsInstalledLayoutTestBase):
    def test_dns_framework_prefixed_filename_is_never_probed(self):
        """Only 'dns-framework_lcars_logo.png' exists on disk (under the
        dns-framework team_dir); the request asks for 'dns_lcars_logo.png'.
        If alt_filename were (wrongly) derived from team_dir instead of
        base_team, this would resolve via the alt-filename probe. It must
        404 instead."""
        wrong_name = "dns-framework_lcars_logo.png"
        requested_name = "dns_lcars_logo.png"
        _write_png(
            self._logo_path_under(self.root1, "dns-framework", wrong_name),
            b"SHOULD-NEVER-SERVE-VIA-ALT-FILENAME",
        )
        # Fixture sanity: the requested filename genuinely doesn't exist
        # anywhere on disk under either team_dir name.
        self.assertFalse(self._logo_path_under(self.root1, "dns", requested_name).exists())
        self.assertFalse(self._logo_path_under(self.root1, "dns-framework", requested_name).exists())

        handler, buf = self._handler(f"/images/{requested_name}")
        handler.serve_image(f"/images/{requested_name}")

        self.assertEqual(
            handler._response_code, 404,
            "'dns-framework_...'-prefixed filename must never be probed "
            "for a dns request — alt_filename is derived from base_team, "
            "not from the on-disk team_dir name",
        )
        self.assertEqual(buf.getvalue(), b"")


# ---------------------------------------------------------------------------
# XACA-1232-004: negative control. Pinned to a fixed commit SHA that
# predates this ticket's (uncommitted) fix — NEVER HEAD, which would start
# containing the fix the moment it's committed, making this control
# vacuously pass. Resolved and verified immediately before writing this
# file:
#
#   $ git rev-parse dev-team/develop
#   5922bd6997de0486d31653d647c15864fd160ac0
#   $ git diff dev-team/develop -- lcars-ui/server.py   # non-empty: develop
#                                                        # does NOT have the
#                                                        # XACA-1232 fix yet
#   $ git show 5922bd6997de0486d31653d647c15864fd160ac0:lcars-ui/server.py \
#       | grep -c _team_dir_candidates    # 0: confirms pre-fix
#
# Override with XACA1232_PRECHANGE_REF for a future re-pin if this SHA is
# ever garbage-collected out of someone's shallow clone.
# ---------------------------------------------------------------------------

PRE_FIX_REF = os.environ.get("XACA1232_PRECHANGE_REF") or "5922bd6997de0486d31653d647c15864fd160ac0"


def _load_pre_fix_server_module():
    """Load `git show <PRE_FIX_REF>:lcars-ui/server.py` — the pinned
    pre-XACA-1232 baseline — into an isolated module for the negative
    control.

    Returns (module, None) on success, or (None, reason) if git is
    unavailable or the ref is not in this clone (a shallow CI checkout).
    Callers MUST skip on a (None, reason) result (with the reason in the
    skip message) rather than silently treating a load failure as a pass.
    """
    git = shutil.which("git")
    if git is None:
        return None, "git not found on PATH"
    spec_ref = f"{PRE_FIX_REF}:lcars-ui/server.py"
    try:
        proc = subprocess.run(
            [git, "show", spec_ref],
            cwd=str(REPO_ROOT), capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return None, f"git show failed to run: {exc}"
    if proc.returncode != 0:
        return None, (
            f"git show {spec_ref} exited {proc.returncode} (shallow clone? "
            f"set XACA1232_PRECHANGE_REF): {proc.stderr.strip()}"
        )
    source = proc.stdout
    if not source.strip():
        return None, f"git show {spec_ref} returned empty content"

    with tempfile.TemporaryDirectory() as srcdir:
        pre_fix_path = Path(srcdir) / "server_pre_fix_xaca1232.py"
        pre_fix_path.write_text(source)
        module_name = "lcars_server_pre_fix_xaca1232"
        spec = importlib.util.spec_from_file_location(module_name, pre_fix_path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        try:
            spec.loader.exec_module(module)
        except Exception as exc:  # pragma: no cover - defensive
            sys.modules.pop(module_name, None)
            return None, f"exec_module of pre-fix server.py failed: {exc}"
    return module, None


class TestNegativeControlPreFixServer(unittest.TestCase):
    """Proves the installed-layout dns fixtures above are load-bearing:
    against the pinned pre-fix server.py (serve_image() there applies the
    dns->dns-framework rewrite unconditionally to EVERY root), the
    installed-layout dns logo must 404. A VACUITY companion assertion in
    the same test proves the pre-fix module can still serve SOMETHING
    (a non-dns team under the installed layout) — otherwise the 404 above
    could just as easily mean a broken harness as a real defect."""

    TEAM = "dns"

    @classmethod
    def setUpClass(cls):
        cls._pre_fix_module, cls._pre_fix_module_error = _load_pre_fix_server_module()

    def setUp(self):
        if self._pre_fix_module is None:
            self.skipTest(
                "negative control skipped — could not load the pre-fix "
                f"server.py ({PRE_FIX_REF}): {self._pre_fix_module_error}"
            )
        # A baseline that already carries the fix makes this control
        # vacuous: FAIL loudly, never skip (an override pointing at a
        # post-fix ref lands here).
        self.assertFalse(
            hasattr(self._pre_fix_module.LCARSHandler, "_team_dir_candidates"),
            f"NEGATIVE CONTROL VACUOUS: {PRE_FIX_REF} already contains the "
            "XACA-1232 fix — point XACA1232_PRECHANGE_REF at a pre-fix commit",
        )
        self._tmpdir_ctx = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir_ctx.cleanup)
        self.tmp = Path(self._tmpdir_ctx.name)

        self.ui_dir = self.tmp / "install" / "lcars-ui"
        (self.ui_dir / "images").mkdir(parents=True)
        self.root1 = self.ui_dir.parent

        self.home = self.tmp / "home"
        self.home.mkdir()
        # root3 (self.home / "dev-team") is deliberately NEVER created.

        p1 = patch.object(self._pre_fix_module, "UI_DIR", self.ui_dir)
        p2 = patch.object(self._pre_fix_module.Path, "home", return_value=self.home)
        p3 = patch.dict(os.environ, {}, clear=False)
        for p in (p1, p2, p3):
            p.start()
            self.addCleanup(p.stop)
        os.environ.pop("AITEAMFORGE_DIR", None)

    def _handler(self, path, method="GET"):
        return _make_handler(self._pre_fix_module, path, method)

    def test_installed_layout_dns_logo_404s_on_pre_fix_server(self):
        filename = "dns_lcars_logo.png"
        target = self.root1 / self.TEAM / "terminals" / "logos" / filename
        _write_png(target, b"ROOT1-DNS-LOGO")
        self.assertFalse((self.home / "dev-team").exists())

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(
            handler._response_code, 404,
            "Pre-fix serve_image() served the installed-layout dns "
            "fixture — either the pinned baseline already contains the "
            "fix (stale negative control) or this control isn't "
            "exercising the real gap.",
        )

        # VACUITY ASSERTION: the pre-fix module is not simply broken
        # end-to-end — it CAN serve a non-dns team's installed-layout
        # logo just fine, proving the 404 above is specific to the dns
        # on-disk-directory defect, not a harness failure.
        other_filename = "academy_x_logo.png"
        other_target = self.root1 / "academy" / "terminals" / "logos" / other_filename
        _write_png(other_target, b"ROOT1-ACADEMY-LOGO")

        handler2, buf2 = self._handler(f"/images/{other_filename}")
        handler2.serve_image(f"/images/{other_filename}")

        self.assertEqual(
            handler2._response_code, 200,
            "VACUITY CHECK FAILED: the pre-fix module can't even serve a "
            "non-dns team's installed-layout logo — the dns 404 above "
            "would then prove nothing about the dns-specific defect.",
        )
        self.assertEqual(buf2.getvalue(), _png(b"ROOT1-ACADEMY-LOGO"))


if __name__ == "__main__":
    unittest.main()
