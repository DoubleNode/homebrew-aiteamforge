#!/usr/bin/env python3

#
#  test_xaca1221_image_roots.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Tests for XACA-1221: LCARS serve_image() resolves team logos/avatars from
several candidate roots, not ONLY from a developer's ~/dev-team checkout.

Before this ticket, serve_image() built its team-logo/avatar lookup as
`Path.home() / "dev-team" / <team> / ...` unconditionally — so an installed
AITeamForge (no ~/dev-team checkout on the box at all) could never resolve
`/images/<team>_<name>_logo.png` or `..._avatar.png`, regardless of what
the release actually shipped under the install tree. This file covers the
server.py half of Decision 1 (root order) and Decision 2 (avatar_thumb) in
kanban/plans/XACA-1221/design-xaca-1221.md.

Coverage (design doc Decision 4, "server.py" half):
  1. Installed-layout logo/avatar/avatar_thumb all resolve with NO
     ~/dev-team present at all.
  2. Root order: UI_DIR.absolute().parent > $AITEAMFORGE_DIR >
     Path.home()/"dev-team", proven with distinct bytes per root and
     fall-through as earlier roots go missing.
  3. Within-root precedence: an invalid-magic PNG falls through to the
     next root; an SVG in an earlier root beats a valid PNG in a later
     one (the "first root that produces EITHER a valid PNG or an
     existing SVG wins outright" rule).
  4. De-duplication: $AITEAMFORGE_DIR == UI_DIR.absolute().parent yields
     one candidate root, not two.
  5. Security: a 'logo_thumb' suffix (not admitted by the regex
     alternation), a dotted '.thumb.png' form, several '../' traversal
     encodings, and a symlink inside an avatars dir that escapes its root
     all 404 — the last one specifically must 404, not 500. The 404 body
     never echoes a resolved filesystem path.
  6. HEAD/GET parity for an installed-layout avatar (head_only=True:
     headers only, no body).
  7. Negative control: the SAME installed-layout fixtures loaded against
     `git show <PRECHANGE_REF>:lcars-ui/server.py` (pinned pre-fix
     baseline, never HEAD) must 404 — proving cases 1/2 above are not vacuously true
     (i.e. that something in server.py actually changed to make them
     pass, not that the fixtures would have passed on any prior code).

Run with:
    python3 -m unittest lcars-ui/tests/test_xaca1221_image_roots.py
  or:
    python3 -m pytest lcars-ui/tests/test_xaca1221_image_roots.py -q
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
# the convention established in test_server.py / test_xaca0992_appicons.py.
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
# Handler construction helper — mirrors test_xaca0992_appicons.py's
# _make_handler, parameterized by MODULE so the same helper serves both the
# live `server` module and the git-HEAD-loaded negative-control module.
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


def _write_bad_png(path: Path, payload: bytes = b"NOT-A-REAL-PNG") -> None:
    """A file at a '.png' path with INVALID magic bytes — exists, but must
    be rejected and fallen through past (to SVG in the same root, or to
    the next root)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"GIF89a" + payload)


def _write_svg(path: Path, payload: bytes = b"<svg>PLACEHOLDER</svg>") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


# Pinned PRE-FIX baseline: the last develop commit to touch lcars-ui/server.py
# before XACA-1221. NEVER `HEAD` — once the fix is committed HEAD contains it,
# and a HEAD-based control returns 200 and fails (PR #900 review round 1).
# Override with XACA1221_PRECHANGE_REF.
PRECHANGE_REF = os.environ.get("XACA1221_PRECHANGE_REF") or "23339bed"


def _load_head_server_module():
    """Load `git show <PRECHANGE_REF>:lcars-ui/server.py` — the pre-fix
    baseline — into an isolated module for the negative control.

    Returns (module, None) on success, or (None, reason) if git is
    unavailable or the ref is not in this clone (a shallow CI checkout).
    Callers MUST skip on a (None, reason) result (with the reason in the
    skip message) rather than silently treating a load failure as a pass —
    a negative control that cannot run proves nothing, and must never be
    indistinguishable from one that ran and found the expected 404.
    """
    git = shutil.which("git")
    if git is None:
        return None, "git not found on PATH"
    spec_ref = f"{PRECHANGE_REF}:lcars-ui/server.py"
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
            f"set XACA1221_PRECHANGE_REF): {proc.stderr.strip()}"
        )
    source = proc.stdout
    if not source.strip():
        return None, f"git show {spec_ref} returned empty content"

    with tempfile.TemporaryDirectory() as srcdir:
        head_path = Path(srcdir) / "server_head_xaca1221.py"
        head_path.write_text(source)
        module_name = "lcars_server_head_xaca1221"
        spec = importlib.util.spec_from_file_location(module_name, head_path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        try:
            spec.loader.exec_module(module)
        except Exception as exc:  # pragma: no cover - defensive
            sys.modules.pop(module_name, None)
            return None, f"exec_module of HEAD server.py failed: {exc}"
    return module, None


# ---------------------------------------------------------------------------
# Common fixture scaffold
# ---------------------------------------------------------------------------

class _ImageRootsTestBase(unittest.TestCase):
    """Builds three candidate-root directories and patches `server.UI_DIR`
    / `Path.home()` to point at them, per the design doc's test recipe:
    TemporaryDirectory; patch.object(server, "UI_DIR", .../"install"/
    "lcars-ui") with an empty images/ dir; patch Path.home -> tmp/"home";
    AITEAMFORGE_DIR popped by default (a tester shell may export it — see
    design doc "New facts" §1) and set explicitly only by tests that need
    root 2.

    root1 = UI_DIR.absolute().parent (installed layout)
    root2 = $AITEAMFORGE_DIR, only in play once _set_env_root() is called
    root3 = Path.home() / "dev-team" (legacy fallback)

    No real ~/dev-team or real UI_DIR is ever read.
    """

    TEAM = "spacedock"

    def setUp(self):
        self._tmpdir_ctx = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir_ctx.cleanup)
        self.tmp = Path(self._tmpdir_ctx.name)

        self.ui_dir = self.tmp / "install" / "lcars-ui"
        (self.ui_dir / "images").mkdir(parents=True)
        self.root1 = self.ui_dir.parent

        self.env_root = self.tmp / "env-root"
        self.env_root.mkdir()

        self.home = self.tmp / "home"
        self.home.mkdir()
        self.root3 = self.home / "dev-team"  # NOT created by default

        self._start_patch(patch.object(server, "UI_DIR", self.ui_dir))
        self._start_patch(patch.object(server.Path, "home", return_value=self.home))
        self._start_patch(patch.dict(os.environ, {}, clear=False))
        os.environ.pop("AITEAMFORGE_DIR", None)

    def _start_patch(self, p):
        p.start()
        self.addCleanup(p.stop)
        return p

    def _set_env_root(self, root: Path = None) -> Path:
        root = root if root is not None else self.env_root
        os.environ["AITEAMFORGE_DIR"] = str(root)
        return root

    def _handler(self, path, method="GET"):
        return _make_handler(server, path, method)

    def _logo_path(self, root: Path, filename: str = None) -> Path:
        filename = filename or f"{self.TEAM}_lcars_logo.png"
        return root / self.TEAM / "terminals" / "logos" / filename

    def _avatar_path(self, root: Path, filename: str = None) -> Path:
        filename = filename or f"{self.TEAM}_sisko_avatar.png"
        return root / self.TEAM / "personas" / "avatars" / filename


# ---------------------------------------------------------------------------
# 1. Installed layout, no ~/dev-team present at all
# ---------------------------------------------------------------------------

class TestInstalledLayoutNoDevTeam(_ImageRootsTestBase):
    """The core bug this ticket fixes: an installed AITeamForge with no
    ~/dev-team checkout on the box must still resolve its own logos and
    avatars from the install tree."""

    def test_logo_200_with_no_dev_team_present(self):
        self.assertFalse(self.root3.exists(), "fixture sanity: no ~/dev-team")
        payload = b"ROOT1-LOGO"
        _write_png(self._logo_path(self.root1), payload)

        filename = f"{self.TEAM}_lcars_logo.png"
        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(handler._response_code, 200)
        self.assertEqual(_headers_dict(handler).get("Content-Type"), "image/png")
        self.assertEqual(buf.getvalue(), _png(payload))

    def test_avatar_200_with_no_dev_team_present(self):
        self.assertFalse(self.root3.exists())
        payload = b"ROOT1-AVATAR"
        _write_png(self._avatar_path(self.root1), payload)

        filename = f"{self.TEAM}_sisko_avatar.png"
        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(handler._response_code, 200)
        self.assertEqual(_headers_dict(handler).get("Content-Type"), "image/png")
        self.assertEqual(buf.getvalue(), _png(payload))

    def test_avatar_thumb_200_with_no_dev_team_present(self):
        """Decision 2: '..._avatar_thumb.png' (agent-panel.html's fallback
        thumbnail) resolves through the SAME avatars dir as 'avatar'."""
        self.assertFalse(self.root3.exists())
        payload = b"ROOT1-AVATAR-THUMB"
        filename = f"{self.TEAM}_sisko_avatar_thumb.png"
        _write_png(self._avatar_path(self.root1, filename), payload)

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(handler._response_code, 200)
        self.assertEqual(_headers_dict(handler).get("Content-Type"), "image/png")
        self.assertEqual(buf.getvalue(), _png(payload))


# ---------------------------------------------------------------------------
# 2. Root order + fall-through
# ---------------------------------------------------------------------------

class TestRootOrder(_ImageRootsTestBase):
    def test_root1_wins_then_falls_through_to_env_then_home(self):
        filename = f"{self.TEAM}_lcars_logo.png"
        p1 = self._logo_path(self.root1, filename)
        self._set_env_root()
        p2 = self._logo_path(self.env_root, filename)
        p3 = self._logo_path(self.root3, filename)
        _write_png(p1, b"ROOT1")
        _write_png(p2, b"ROOT2")
        _write_png(p3, b"ROOT3")

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")
        self.assertEqual(handler._response_code, 200)
        self.assertEqual(buf.getvalue(), _png(b"ROOT1"),
                          "root 1 (UI_DIR.absolute().parent) must win when all three exist")

        p1.unlink()
        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")
        self.assertEqual(handler._response_code, 200)
        self.assertEqual(buf.getvalue(), _png(b"ROOT2"),
                          "removing root 1 must fall through to root 2 ($AITEAMFORGE_DIR)")

        p2.unlink()
        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")
        self.assertEqual(handler._response_code, 200)
        self.assertEqual(buf.getvalue(), _png(b"ROOT3"),
                          "removing roots 1 and 2 must fall through to root 3 (~/dev-team)")


# ---------------------------------------------------------------------------
# 3. Within-root precedence: invalid-magic PNG and SVG-beats-PNG
# ---------------------------------------------------------------------------

class TestInvalidMagicAndSvgPrecedence(_ImageRootsTestBase):
    def test_invalid_magic_png_in_root1_falls_through_to_valid_png_in_root2(self):
        filename = f"{self.TEAM}_lcars_logo.png"
        _write_bad_png(self._logo_path(self.root1, filename))
        self._set_env_root()
        _write_png(self._logo_path(self.env_root, filename), b"ROOT2-VALID")

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(handler._response_code, 200)
        self.assertEqual(_headers_dict(handler).get("Content-Type"), "image/png")
        self.assertEqual(buf.getvalue(), _png(b"ROOT2-VALID"))

    def test_svg_in_root1_beats_valid_png_in_root2(self):
        """'the first root that produces EITHER a valid PNG or an existing
        SVG wins outright' — root1 has only an SVG (no PNG at all), root2
        has a perfectly valid PNG. root1 must still win."""
        filename = f"{self.TEAM}_lcars_logo.png"
        svg_bytes = b"<svg>ROOT1-SVG</svg>"
        _write_svg(self._logo_path(self.root1, filename).with_suffix(".svg"), svg_bytes)
        self._set_env_root()
        _write_png(self._logo_path(self.env_root, filename), b"ROOT2-VALID")

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(handler._response_code, 200)
        self.assertEqual(_headers_dict(handler).get("Content-Type"), "image/svg+xml")
        self.assertEqual(buf.getvalue(), svg_bytes)


# ---------------------------------------------------------------------------
# 4. De-duplication
# ---------------------------------------------------------------------------

class TestCandidateRootDedup(_ImageRootsTestBase):
    def test_env_equal_to_ui_dir_parent_yields_one_entry(self):
        os.environ["AITEAMFORGE_DIR"] = str(self.root1)  # == UI_DIR.absolute().parent

        roots = server.LCARSHandler._image_candidate_roots()
        resolved = [str(r.resolve()) for r in roots]

        self.assertEqual(
            len(resolved), len(set(resolved)),
            f"duplicate resolved root(s) in {resolved!r}",
        )
        # root1 == env dedupes to one entry; root3 (~/dev-team) is distinct.
        self.assertEqual(len(roots), 2, f"expected 2 de-duplicated roots, got {roots!r}")

    def test_distinct_roots_all_present_when_env_differs(self):
        self._set_env_root()  # env_root != root1
        roots = server.LCARSHandler._image_candidate_roots()
        resolved = [str(r.resolve()) for r in roots]
        self.assertEqual(len(roots), 3)
        self.assertEqual(len(resolved), len(set(resolved)))


# ---------------------------------------------------------------------------
# 5. Security
# ---------------------------------------------------------------------------

class TestSecurity(_ImageRootsTestBase):
    def test_logo_thumb_suffix_not_admitted_returns_404(self):
        """'avatar_thumb' is admitted; 'logo_thumb' deliberately is not
        (Decision 2: alternation, not a free `(_thumb)?` group)."""
        filename = f"{self.TEAM}_x_logo_thumb.png"
        # Even if a file happened to exist there, the regex must reject
        # the filename before any filesystem lookup — no fixture needed,
        # but create one anyway so a false-positive match would be caught.
        _write_png(self._logo_path(self.root1, filename), b"SHOULD-NEVER-SERVE")

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(handler._response_code, 404)
        self.assertEqual(buf.getvalue(), b"")

    def test_dotted_thumb_form_returns_404(self):
        filename = "a_b_avatar.thumb.png"
        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")
        self.assertEqual(handler._response_code, 404)
        self.assertEqual(buf.getvalue(), b"")

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

    def test_symlink_inside_avatars_dir_escaping_root_returns_404_not_500(self):
        filename = f"{self.TEAM}_sisko_avatar.png"
        avatars_dir = self.root1 / self.TEAM / "personas" / "avatars"
        avatars_dir.mkdir(parents=True)

        outside = self.tmp / "outside-root1"
        outside.mkdir()
        outside_file = outside / "secret.png"
        _write_png(outside_file, b"SECRET-BYTES-OUTSIDE-ROOT")

        (avatars_dir / filename).symlink_to(outside_file)

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(
            handler._response_code, 404,
            "symlink escape must 404, not 500/raise/leak the outside file",
        )
        self.assertEqual(buf.getvalue(), b"")

    def test_directory_named_like_image_falls_through_not_500(self):
        """A directory at the candidate path used to reach open() and raise
        IsADirectoryError (pre-existing at HEAD). It must be skipped like a
        missing file, so the next root still serves."""
        filename = f"{self.TEAM}_lcars_logo.png"
        self._logo_path(self.root1, filename).mkdir(parents=True)
        self._set_env_root()
        _write_png(self._logo_path(self.env_root, filename), b"ROOT2-AFTER-DIR")

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(handler._response_code, 200)
        self.assertEqual(buf.getvalue(), _png(b"ROOT2-AFTER-DIR"))

    def test_local_images_directory_is_not_a_500_and_leaks_no_path(self):
        """PR #900 review: GET /images/appicons (a DIRECTORY under
        lcars-ui/images) used to reach open() and 500 with the absolute path
        in the body. It must now be treated as not-a-file."""
        (self.ui_dir / "images" / "appicons").mkdir()
        handler, buf = self._handler("/images/appicons")
        handler.serve_image("/images/appicons")

        self.assertEqual(handler._response_code, 404)
        for c in handler.send_error.call_args_list:
            self.assertNotIn(str(self.tmp), " ".join(str(a) for a in c.args))

    def test_unreadable_root_falls_through_to_next_root(self):
        """PR #900 review: a PermissionError while probing one root (is_file()
        only swallows ENOENT-class errors before Python 3.13) must skip that
        root, not abort the request."""
        filename = f"{self.TEAM}_lcars_logo.png"
        _write_png(self._logo_path(self.root1, filename), b"ROOT1-UNREADABLE")
        self._set_env_root()
        _write_png(self._logo_path(self.env_root, filename), b"ROOT2-READABLE")

        real_is_file = Path.is_file
        root1_str = str(self.root1.resolve())

        def _is_file(p):
            if str(p).startswith(root1_str) and "terminals" in str(p):
                raise PermissionError(13, "Permission denied", str(p))
            return real_is_file(p)

        with patch.object(server.Path, "is_file", _is_file):
            handler, buf = self._handler(f"/images/{filename}")
            handler.serve_image(f"/images/{filename}")

        self.assertEqual(handler._response_code, 200)
        self.assertEqual(buf.getvalue(), _png(b"ROOT2-READABLE"))

    def test_read_error_500_body_leaks_no_path(self):
        filename = f"{self.TEAM}_lcars_logo.png"
        _write_png(self._logo_path(self.root1, filename), b"X")
        real_open = open

        def _open(path, mode="r", *a, **kw):
            # Let the magic-byte probe succeed, fail the final full read.
            if str(path).endswith(filename) and mode == "rb" and _open.calls:
                raise PermissionError(13, "Permission denied", str(path))
            if str(path).endswith(filename):
                _open.calls += 1
            return real_open(path, mode, *a, **kw)
        _open.calls = 0

        with patch("builtins.open", _open):
            handler, buf = self._handler(f"/images/{filename}")
            handler.serve_image(f"/images/{filename}")

        self.assertEqual(handler._response_code, 500)
        message = handler.send_error.call_args.args[1]
        self.assertEqual(message, f"Error reading image: {filename}")
        self.assertNotIn(str(self.tmp), message)

    def test_404_body_contains_only_the_filename_no_resolved_path(self):
        """The 404 body must never echo a resolved filesystem path (that
        would leak the tmp/home directory layout); it echoes only the
        already-regex-validated `filename`."""
        filename = f"{self.TEAM}_ghost_logo.png"  # nowhere on disk
        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(handler._response_code, 404)
        handler.send_error.assert_called_once()
        message = handler.send_error.call_args.args[1]
        self.assertEqual(message, f"Image not found: {filename}")
        self.assertNotIn(str(self.tmp), message)
        self.assertNotIn(str(self.home), message)


# ---------------------------------------------------------------------------
# 6. HEAD/GET parity for an installed-layout avatar
# ---------------------------------------------------------------------------

class TestHeadRequest(_ImageRootsTestBase):
    def test_head_installed_layout_avatar_headers_only_no_body(self):
        payload = b"HEAD-AVATAR-BYTES"
        filename = f"{self.TEAM}_sisko_avatar.png"
        _write_png(self._avatar_path(self.root1, filename), payload)

        get_handler, get_buf = self._handler(f"/images/{filename}", method="GET")
        get_handler.serve_image(f"/images/{filename}")

        head_handler, head_buf = self._handler(f"/images/{filename}", method="HEAD")
        head_handler.serve_image(f"/images/{filename}", head_only=True)

        self.assertEqual(head_handler._response_code, 200)
        self.assertEqual(head_handler._response_code, get_handler._response_code)
        self.assertEqual(
            _headers_dict(head_handler).get("Content-Type"),
            _headers_dict(get_handler).get("Content-Type"),
        )
        self.assertEqual(_headers_dict(head_handler).get("Content-Type"), "image/png")
        self.assertEqual(
            _headers_dict(head_handler).get("Content-Length"),
            _headers_dict(get_handler).get("Content-Length"),
        )
        self.assertEqual(
            int(_headers_dict(head_handler).get("Content-Length")), len(_png(payload))
        )
        self.assertEqual(head_buf.getvalue(), b"", "HEAD must carry no body")
        self.assertEqual(get_buf.getvalue(), _png(payload))


# ---------------------------------------------------------------------------
# 7. Negative control: pinned pre-fix baseline must 404 on these fixtures
# ---------------------------------------------------------------------------

class TestNegativeControlPreFixServer(unittest.TestCase):
    """Proves the installed-layout fixtures above are load-bearing: run
    against `git show <PRECHANGE_REF>:lcars-ui/server.py` (the pinned pre-fix
    baseline — serve_image() there only ever looked under
    Path.home()/"dev-team"), the SAME installed-layout (root1-only, no
    ~/dev-team) fixtures that return 200 against the current code must
    404. If they didn't, cases 1/2 above would be vacuously true."""

    TEAM = "spacedock"

    @classmethod
    def setUpClass(cls):
        cls._head_module, cls._head_module_error = _load_head_server_module()

    def setUp(self):
        if self._head_module is None:
            self.skipTest(
                "negative control skipped — could not load the pre-fix "
                f"server.py ({PRECHANGE_REF}): {self._head_module_error}"
            )
        # A baseline that already carries the fix makes this control vacuous:
        # FAIL loudly, never skip (an override pointing at HEAD lands here).
        self.assertFalse(
            hasattr(self._head_module.LCARSHandler, "_image_candidate_roots"),
            f"NEGATIVE CONTROL VACUOUS: {PRECHANGE_REF} already contains the "
            "XACA-1221 fix — point XACA1221_PRECHANGE_REF at a pre-fix commit",
        )
        self._tmpdir_ctx = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir_ctx.cleanup)
        self.tmp = Path(self._tmpdir_ctx.name)

        self.ui_dir = self.tmp / "install" / "lcars-ui"
        (self.ui_dir / "images").mkdir(parents=True)
        self.root1 = self.ui_dir.parent

        self.home = self.tmp / "home"
        self.home.mkdir()
        # root3 (self.home / "dev-team") is deliberately NEVER created —
        # this is exactly what proves the pre-fix code has nowhere to look.

        p1 = patch.object(self._head_module, "UI_DIR", self.ui_dir)
        p2 = patch.object(self._head_module.Path, "home", return_value=self.home)
        p3 = patch.dict(os.environ, {}, clear=False)
        for p in (p1, p2, p3):
            p.start()
            self.addCleanup(p.stop)
        os.environ.pop("AITEAMFORGE_DIR", None)

    def _handler(self, path, method="GET"):
        return _make_handler(self._head_module, path, method)

    def test_installed_layout_logo_404s_on_pre_fix_server(self):
        filename = f"{self.TEAM}_lcars_logo.png"
        target = self.root1 / self.TEAM / "terminals" / "logos" / filename
        _write_png(target, b"ROOT1-LOGO")
        self.assertFalse((self.home / "dev-team").exists())

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(
            handler._response_code, 404,
            "Pre-fix serve_image() served the installed-layout fixture — "
            "either the HEAD baseline already contains the fix (stale "
            "negative control) or this control isn't exercising the real gap.",
        )

    def test_installed_layout_avatar_thumb_404s_on_pre_fix_server(self):
        """Doubles as a Decision-2 negative control: pre-fix code's regex
        admitted only 'logo'/'avatar', so 'avatar_thumb' should 404 even
        independent of the root-resolution gap."""
        filename = f"{self.TEAM}_sisko_avatar_thumb.png"
        target = self.root1 / self.TEAM / "personas" / "avatars" / filename
        _write_png(target, b"ROOT1-AVATAR-THUMB")
        self.assertFalse((self.home / "dev-team").exists())

        handler, buf = self._handler(f"/images/{filename}")
        handler.serve_image(f"/images/{filename}")

        self.assertEqual(
            handler._response_code, 404,
            "Pre-fix serve_image() served an '_avatar_thumb.png' fixture — "
            "either the HEAD baseline already contains Decision 2, or this "
            "control isn't exercising the real gap.",
        )


if __name__ == "__main__":
    unittest.main()
