#!/usr/bin/env python3

#
#  test_xaca1245_helpers_root_resolver.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Regression tests for XACA-1245-003: lcars-ui/server.py must locate
kanban-helpers.sh + scripts/kb-cr.sh through ONE root resolver instead of
hardcoding ~/dev-team.

THE DEFECT: _build_cr_transition_shell_parts emitted
`source ~/dev-team/kanban-helpers.sh` / `~/dev-team/scripts/kb-cr.sh`. A tap
consumer has no ~/dev-team (it installs the same layout under
$AITEAMFORGE_DIR), so every POST /api/kanban/cr/<id>/transition answered 500.

THE FIX: LCARSHandler._resolve_lcars_helpers_root() walks
_lcars_helpers_candidate_roots() (~/dev-team -> $AITEAMFORGE_DIR ->
UI_DIR.absolute().parent) and returns the first root holding BOTH files.
Nothing resolvable -> LcarsHelpersNotFound -> HTTP 500 before zsh runs.

Isolation (this machine must never be polluted by a test):
  * Path.home() is patched to a tmp dir; $AITEAMFORGE_DIR is cleared or set to
    a tmp tree in every test; server.UI_DIR is patched to a tmp dir whenever
    the third candidate (UI_DIR.parent) could otherwise resolve to this very
    worktree and mask the case under test.
  * Every board is a tmp file; server.TEAM_KANBAN_DIRS is patched to tmp.
  * The zsh subprocess gets HOME/TMPDIR pointed at tmp and TMUX* stripped.
  * "Consumer" trees are built from SYMLINKS to this worktree's files, so the
    branch under test (not ~/dev-team) is what actually gets sourced.
"""

import importlib.util
import io
import json
import os
import shutil
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
LCARS_UI_DIR = REPO_ROOT / "lcars-ui"
SERVER_PY = LCARS_UI_DIR / "server.py"
HELPERS_SH = REPO_ROOT / "kanban-helpers.sh"
SCRIPTS_DIR = REPO_ROOT / "scripts"
KB_CR_SH = SCRIPTS_DIR / "kb-cr.sh"
VALIDATOR_PY = SCRIPTS_DIR / "cr-schema-validator.py"

pytestmark = pytest.mark.skipif(
    shutil.which("zsh") is None, reason="zsh not available"
)

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


def _load_server_module():
    """Import lcars-ui/server.py fresh under a private module name so this
    file's patches never leak into other test files."""
    for name, stub in _stub_modules.items():
        if name not in sys.modules:
            sys.modules[name] = stub
    was_set = "LCARS_TEAM" in os.environ
    os.environ.setdefault("LCARS_TEAM", "academy")
    spec = importlib.util.spec_from_file_location("lcars_server_x1245", SERVER_PY)
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except SystemExit:
        pass
    if not was_set:
        os.environ.pop("LCARS_TEAM", None)
    return mod


server = _load_server_module()
HANDLER_CLS = server.LCARSHandler

CR_ID = "CR-ACADEMY-20260801-1"


# ── tree builders ───────────────────────────────────────────────────────────

def _link_full_root(root: Path, *, validator=True):
    """Make `root` look like an installed/dev tree whose files ARE this
    worktree's: root/kanban-helpers.sh and root/scripts/* -> symlinks.
    kanban-helpers.sh and kb-cr.sh locate their siblings via ${(%):-%x}:A:h,
    which resolves the symlink back into REPO_ROOT, so the sibling scripts
    they need (cc-account-routing.sh etc.) are found."""
    root.mkdir(parents=True, exist_ok=True)
    (root / "kanban-helpers.sh").symlink_to(HELPERS_SH)
    scripts = root / "scripts"
    scripts.mkdir()
    (scripts / "kb-cr.sh").symlink_to(KB_CR_SH)
    if validator:
        (scripts / "cr-schema-validator.py").symlink_to(VALIDATOR_PY)
    return root


def _make_half_root(root: Path, *, have_helpers: bool, have_kb_cr: bool):
    root.mkdir(parents=True, exist_ok=True)
    if have_helpers:
        (root / "kanban-helpers.sh").symlink_to(HELPERS_SH)
    if have_kb_cr:
        (root / "scripts").mkdir(exist_ok=True)
        (root / "scripts" / "kb-cr.sh").symlink_to(KB_CR_SH)
    return root


class Env:
    """Resolved per-test sandbox handles."""
    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.home = tmp / "home"
        self.home.mkdir()
        self.ui_dir = tmp / "ui-sandbox" / "lcars-ui"   # parent has no helpers
        self.ui_dir.mkdir(parents=True)
        self.kanban_dir = tmp / "kanban"
        self.kanban_dir.mkdir()
        self.tmpdir = tmp / "tmpdir"
        self.tmpdir.mkdir()
        self.board = self.kanban_dir / "academy-board.json"


@pytest.fixture
def env(tmp_path):
    """Sandbox with Path.home, UI_DIR, TEAM_KANBAN_DIRS and the process
    environment redirected. AITEAMFORGE_DIR/TMUX leaks are stripped; tests
    that want AITEAMFORGE_DIR set it with patch.dict inside the test."""
    e = Env(tmp_path)
    clean = {"HOME": str(e.home), "TMPDIR": str(e.tmpdir),
             "KB_SKIP_DUAL_BOARD_CHECK": "1"}
    with patch.dict(os.environ, clean):
        for key in ("AITEAMFORGE_DIR", "TMUX", "TMUX_PANE", "_KB_CR_LOADED"):
            os.environ.pop(key, None)
        with patch.object(server.Path, "home", return_value=e.home), \
             patch.object(server, "UI_DIR", e.ui_dir), \
             patch.dict(server.TEAM_KANBAN_DIRS, {"academy": str(e.kanban_dir)}):
            yield e


# ── board + request plumbing ────────────────────────────────────────────────

def _write_board(path: Path, state, timestamps):
    path.write_text(json.dumps({
        "teamConfig": {"crSupport": {"enabled": True}},
        "crs": [{
            "id": CR_ID, "title": "fixture", "type": "major",
            "crState": state, "itemIds": [], "pushback_count": 0,
            "timestamps": timestamps,
            "createdAt": "2026-08-01T00:00:00Z",
            "updatedAt": "2026-08-01T00:00:00Z",
        }],
        "nextCrSeq": 2, "backlog": [],
        "lastUpdated": "2026-08-01T00:00:00Z",
    }), encoding="utf-8")


def _drafted_board(path):
    _write_board(path, "cr-drafted", {"cr_created_at": "2026-08-01T00:00:00Z"})


def _submitted_board(path):
    _write_board(path, "cr-submitted", {
        "cr_created_at": "2026-08-01T00:00:00Z",
        "cr_submitted_at": "2026-08-01T01:00:00Z",
    })


def _post_transition(body_obj):
    """Drive the real handle_cr_transition with a mocked socket; returns
    (status_code, parsed_json_body)."""
    body = json.dumps(body_obj).encode()
    buf = io.BytesIO()
    with patch.object(HANDLER_CLS, "__init__", lambda self, *a, **kw: None):
        h = HANDLER_CLS.__new__(HANDLER_CLS)
    path = f"/api/kanban/cr/{CR_ID}/transition"
    h.path = path
    h.command = "POST"
    h.rfile = io.BytesIO(body)
    h.wfile = buf
    h.server = MagicMock()
    h.headers = {"Content-Length": str(len(body))}
    h.requestline = f"POST {path} HTTP/1.1"
    h.client_address = ("127.0.0.1", 9999)
    h._response_code = None
    h.send_response = lambda code, message=None: setattr(h, "_response_code", code)
    h.send_header = lambda *a, **k: None
    h.end_headers = lambda: None
    h.send_error = MagicMock()
    h.log_message = MagicMock()
    h.log_error = MagicMock()
    h.handle_cr_transition(CR_ID)
    return h._response_code, json.loads(buf.getvalue().decode())


def _board_state(board: Path):
    return json.loads(board.read_text(encoding="utf-8"))["crs"][0]


# ── 1. consumer layout: end to end through the real route ───────────────────

def test_consumer_layout_plain_transition_succeeds_end_to_end(env):
    """Fake HOME has NO dev-team; the only helpers tree is $AITEAMFORGE_DIR.
    Pre-fix this 500'd because zsh sourced ~/dev-team/kanban-helpers.sh."""
    assert not (env.home / "dev-team").exists()
    consumer = _link_full_root(env.tmp / "aiteamforge")
    _drafted_board(env.board)

    with patch.dict(os.environ, {"AITEAMFORGE_DIR": str(consumer)}):
        status, payload = _post_transition({
            "targetState": "cr-published",
            "fields": {"cr_confluence_url": "https://example.invalid/wiki/1"},
            "actor": "pytest-consumer",
        })

    assert status == 200, f"expected 200, got {status}: {payload}"
    assert payload["ok"] is True
    cr = _board_state(env.board)
    assert cr["crState"] == "cr-published", "temp board's crState did not change"
    assert cr["timestamps"].get("cr_published_at"), "entry timestamp not stamped"


def test_consumer_layout_approval_waiver_transition_succeeds_end_to_end(env):
    assert not (env.home / "dev-team").exists()
    consumer = _link_full_root(env.tmp / "aiteamforge")
    _submitted_board(env.board)

    with patch.dict(os.environ, {"AITEAMFORGE_DIR": str(consumer)}):
        status, payload = _post_transition({
            "targetState": "implementing",
            "fields": {"approval_waiver": {
                "reason": "No approval notice received (XACA-1245 fixture)."}},
            "actor": "pytest-consumer",
        })

    assert status == 200, f"expected 200, got {status}: {payload}"
    cr = _board_state(env.board)
    assert cr["crState"] == "implementing"
    assert cr["timestamps"].get("cr_approval_waived_at")
    assert not cr["timestamps"].get("cr_approved_at"), "a waiver must never fabricate an approval"
    assert cr["approvalWaiver"]["actor"] == "pytest-consumer"


# ── 2. installed layout via UI_DIR.parent (AITEAMFORGE_DIR unset) ───────────

def test_installed_layout_resolves_via_ui_dir_parent(env):
    installed = _link_full_root(env.tmp / "installed")
    ui = installed / "lcars-ui"
    ui.mkdir()
    assert "AITEAMFORGE_DIR" not in os.environ
    assert not (env.home / "dev-team").exists()

    with patch.object(server, "UI_DIR", ui):
        resolved = HANDLER_CLS._resolve_lcars_helpers_root()
        parts = HANDLER_CLS._build_cr_transition_shell_parts(
            str(env.board), CR_ID, "implementing")

    assert resolved == installed
    assert parts[0] == f"source {installed}/kanban-helpers.sh"
    assert parts[1] == f"source {installed}/scripts/kb-cr.sh"


# ── 3. nothing resolves: 500, every root named, zsh never runs ──────────────

def test_no_resolvable_root_returns_500_naming_every_root_and_never_runs_zsh(env):
    empty_env_root = env.tmp / "empty-aiteamforge"
    empty_env_root.mkdir()
    _drafted_board(env.board)
    before = env.board.read_bytes()
    zsh_calls = MagicMock(name="subprocess.run")

    with patch.dict(os.environ, {"AITEAMFORGE_DIR": str(empty_env_root)}), \
         patch.object(server.subprocess, "run", zsh_calls):
        # The pre-rename alias exists before AND after the fix, so a pre-fix
        # run fails on behavior (zsh invoked / roots not named), not a name.
        roots = [str(r) for r in HANDLER_CLS._cr_schema_validator_candidate_roots()]
        status, payload = _post_transition({
            "targetState": "cr-published",
            "fields": {"cr_confluence_url": "https://example.invalid/wiki/1"},
        })

    assert len(roots) == 3, f"expected three distinct searched roots, got {roots}"
    assert status == 500, f"got {status}: {payload}"
    assert payload["ok"] is False
    for root in roots:
        assert root in payload["error"], f"{root!r} missing from error: {payload['error']!r}"
    zsh_calls.assert_not_called()
    assert env.board.read_bytes() == before, "board changed despite fail-closed refusal"


# ── 4. half roots are rejected ──────────────────────────────────────────────

@pytest.mark.parametrize("have_helpers,have_kb_cr", [(True, False), (False, True)])
def test_half_root_is_skipped_and_later_full_root_wins(env, have_helpers, have_kb_cr):
    half = _make_half_root(env.home / "dev-team", have_helpers=have_helpers,
                           have_kb_cr=have_kb_cr)
    full = _link_full_root(env.tmp / "aiteamforge")

    with patch.dict(os.environ, {"AITEAMFORGE_DIR": str(full)}):
        resolved = HANDLER_CLS._resolve_lcars_helpers_root()
        parts = HANDLER_CLS._build_cr_transition_shell_parts(
            str(env.board), CR_ID, "implementing")

    assert resolved == full
    assert resolved != half
    assert parts[0] == f"source {full}/kanban-helpers.sh"


@pytest.mark.parametrize("have_helpers,have_kb_cr", [(True, False), (False, True)])
def test_only_half_roots_raise_helpers_not_found(env, have_helpers, have_kb_cr):
    _make_half_root(env.home / "dev-team", have_helpers=have_helpers, have_kb_cr=have_kb_cr)
    other = _make_half_root(env.tmp / "aiteamforge", have_helpers=have_helpers,
                            have_kb_cr=have_kb_cr)

    with patch.dict(os.environ, {"AITEAMFORGE_DIR": str(other)}):
        assert HANDLER_CLS._resolve_lcars_helpers_root() is None
        with pytest.raises(server.LcarsHelpersNotFound) as exc:
            HANDLER_CLS._build_cr_transition_shell_parts(str(env.board), CR_ID, "implementing")

    searched = exc.value.searched_roots
    assert str(env.home / "dev-team") in searched
    assert str(other) in searched


# ── 5. precedence unchanged: ~/dev-team beats $AITEAMFORGE_DIR ──────────────

def test_dev_team_wins_over_aiteamforge_dir_when_both_qualify(env):
    dev = _link_full_root(env.home / "dev-team")
    consumer = _link_full_root(env.tmp / "aiteamforge")

    with patch.dict(os.environ, {"AITEAMFORGE_DIR": str(consumer)}):
        resolved = HANDLER_CLS._resolve_lcars_helpers_root()
        parts = HANDLER_CLS._build_cr_transition_shell_parts(
            str(env.board), CR_ID, "implementing")

    assert resolved == dev
    assert parts[0] == f"source {dev}/kanban-helpers.sh"
    assert parts[1] == f"source {dev}/scripts/kb-cr.sh"
    assert str(consumer) not in "\n".join(parts)


# ── 6. validator and shell helpers share ONE tree ───────────────────────────

def test_validator_path_shares_root_with_builder_source_lines(env):
    full = _link_full_root(env.tmp / "aiteamforge")
    with patch.dict(os.environ, {"AITEAMFORGE_DIR": str(full)}):
        validator = HANDLER_CLS._resolve_cr_schema_validator_path()
        parts = HANDLER_CLS._build_cr_transition_shell_parts(
            str(env.board), CR_ID, "implementing")

    root_from_validator = validator.parent.parent
    assert root_from_validator == full
    assert parts[0] == f"source {root_from_validator}/kanban-helpers.sh"
    assert parts[1] == f"source {root_from_validator}/scripts/kb-cr.sh"


def test_decoy_validator_only_tree_earlier_in_chain_does_not_win(env):
    """~/dev-team holds ONLY cr-schema-validator.py (no helpers). The old
    validator chain would return it; the helpers-qualified $AITEAMFORGE_DIR
    tree must win so evidence map and enforcement cannot split across trees."""
    decoy = env.home / "dev-team"
    (decoy / "scripts").mkdir(parents=True)
    (decoy / "scripts" / "cr-schema-validator.py").symlink_to(VALIDATOR_PY)
    full = _link_full_root(env.tmp / "aiteamforge")

    with patch.dict(os.environ, {"AITEAMFORGE_DIR": str(full)}):
        validator = HANDLER_CLS._resolve_cr_schema_validator_path()
        parts = HANDLER_CLS._build_cr_transition_shell_parts(
            str(env.board), CR_ID, "implementing")

    assert validator == full / "scripts" / "cr-schema-validator.py"
    assert validator.parent.parent != decoy
    assert parts[0] == f"source {validator.parent.parent}/kanban-helpers.sh"


def test_helpers_root_without_validator_does_not_fall_through_to_later_tree(env):
    """XACA-1245-013: ~/dev-team holds BOTH helpers but NO validator; a later
    $AITEAMFORGE_DIR tree holds the validator. The validator path must be
    ~/dev-team's (missing) one, so the loader fails closed, rather than the
    later tree's: falling through would read the evidence map from a
    different tree than the one the transition sources."""
    helpers_only = _link_full_root(env.home / "dev-team", validator=False)
    later = _link_full_root(env.tmp / "aiteamforge")

    with patch.dict(os.environ, {"AITEAMFORGE_DIR": str(later)}):
        validator = HANDLER_CLS._resolve_cr_schema_validator_path()
        parts = HANDLER_CLS._build_cr_transition_shell_parts(
            str(env.board), CR_ID, "implementing")

    assert validator == helpers_only / "scripts" / "cr-schema-validator.py"
    assert not validator.exists()
    assert parts[0] == f"source {helpers_only}/kanban-helpers.sh"


# ── 7. helpers_root override is the SOLE candidate ──────────────────────────

def test_helpers_root_override_is_sole_candidate_even_when_incomplete(env):
    _link_full_root(env.home / "dev-team")           # a perfectly good fallback
    incomplete = _make_half_root(env.tmp / "override", have_helpers=True,
                                 have_kb_cr=False)

    parts = HANDLER_CLS._build_cr_transition_shell_parts(
        str(env.board), CR_ID, "implementing", helpers_root=str(incomplete))

    assert parts[0] == f"source {incomplete}/kanban-helpers.sh"
    assert parts[1] == f"source {incomplete}/scripts/kb-cr.sh"
    assert str(env.home / "dev-team") not in "\n".join(parts[:2])
