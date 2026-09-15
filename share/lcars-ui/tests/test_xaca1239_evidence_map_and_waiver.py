#!/usr/bin/env python3

#
#  test_xaca1239_evidence_map_and_waiver.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Tests for XACA-1239-004: GET /api/kanban/cr/evidence-map and the transition
endpoint's approval-waiver support (lcars-ui/server.py).

XACA-1239 adds an approval WAIVER — real evidence saying "approval was not
received, and we proceeded anyway" — as an alternative to the (missing)
IT Connect approval signal (XACA-0899). Two server-side pieces are covered
here:

  (a) GET /api/kanban/cr/evidence-map, DERIVED at request time from
      scripts/cr-schema-validator.py's STATE_ENTRY_TS + EVIDENCE_PREREQS
      (D4) — never a hand-copied fifth map. The derivation must produce
      exactly what scripts/kb-cr.sh's _kb_cr_state_required_evidence()
      prints, for every crState.
  (b) The transition endpoint's fields.approval_waiver support (D5): the
      generated shell script calls _kb_cr_waive_approval BEFORE the state
      write, as ONE script — a failed waiver write must be fatal (exit 4)
      and must leave the board with NO state change.

XACA-1019 (memory: feedback_source_worktree_helpers_not_since_develop...):
kanban-helpers.sh sources the MAIN-repo kb-cr.sh, so a test that lets that
happen can pass vacuously against code this branch never shipped. Every
shell invocation and every _derive_cr_evidence_map() call in this file
explicitly points at THIS WORKTREE (REPO_ROOT / a home symlink to it),
never the default ~/dev-team resolution, except the one route test that
exists specifically to prove the ROUTING works and deliberately exercises
the real do_GET() dispatch path (still pinned to the worktree via a home
symlink — see fake_home_root).
"""

import importlib.util
import io
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
LCARS_UI_DIR = REPO_ROOT / "lcars-ui"
SERVER_PY = LCARS_UI_DIR / "server.py"
VALIDATOR_PY = REPO_ROOT / "scripts" / "cr-schema-validator.py"
KB_CR_SH = REPO_ROOT / "scripts" / "kb-cr.sh"
KANBAN_HELPERS_SH = REPO_ROOT / "kanban-helpers.sh"

pytestmark = pytest.mark.skipif(
    shutil.which("zsh") is None, reason="zsh not available"
)


# ── server.py bootstrap (mirrors test_xaca0992_appicons.py's convention) ────

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
    """Import lcars-ui/server.py fresh, under its own sys.modules name, so
    this file's monkeypatches of `server.Path.home` never leak into other
    test files that also import server.py by path."""
    for name, stub in _stub_modules.items():
        if name not in sys.modules:
            sys.modules[name] = stub
    was_set = "LCARS_TEAM" in os.environ
    os.environ.setdefault("LCARS_TEAM", "academy")
    spec = importlib.util.spec_from_file_location("lcars_server_x1239", SERVER_PY)
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


def _load_validator_module():
    """Import scripts/cr-schema-validator.py by path (hyphenated filename is
    not importable) — same technique tests/test_xaca0924_evidence_maps.py
    uses to pin this file's own maps."""
    spec = importlib.util.spec_from_file_location(
        "cr_schema_validator_x1239", VALIDATOR_PY
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


VALIDATOR = _load_validator_module()


def _new_handler_instance():
    """A bare LCARSHandler instance with __init__ skipped, for calling
    instance methods that need no live socket (_cr_validate_approval_waiver,
    _cr_target_accepts_approval_waiver). Mirrors test_xaca0992_appicons.py's
    _make_handler technique."""
    with patch.object(HANDLER_CLS, "__init__", lambda self, *a, **kw: None):
        return HANDLER_CLS.__new__(HANDLER_CLS)


def _make_request_handler(path, method="GET"):
    """Construct an LCARSHandler with all socket I/O mocked, for exercising
    the real do_GET() dispatch (the route test). Copied from the
    established _make_handler pattern in test_xaca0992_appicons.py /
    test_server.py — kept local rather than imported so this file has no
    cross-file test coupling."""
    response_buf = io.BytesIO()
    with patch.object(HANDLER_CLS, "__init__", lambda self, *a, **kw: None):
        handler = HANDLER_CLS.__new__(HANDLER_CLS)
    handler.path = path
    handler.command = method
    handler.rfile = io.BytesIO(b"")
    handler.wfile = response_buf
    handler.server = MagicMock()
    handler.headers = {}
    handler.directory = str(getattr(server, "UI_DIR", LCARS_UI_DIR))
    handler.requestline = f"{method} {path} HTTP/1.1"
    handler.client_address = ("127.0.0.1", 9999)
    handler._response_code = None
    handler._headers_sent = []

    def _send_response(code, message=None):
        handler._response_code = code

    def _send_header(name, value):
        handler._headers_sent.append((name, value))

    handler.send_response = _send_response
    handler.send_header = _send_header
    handler.end_headers = lambda: None
    handler.send_error = MagicMock(
        side_effect=lambda code, msg=None: setattr(handler, "_response_code", code)
    )
    handler.log_message = MagicMock()
    handler.log_error = MagicMock()
    return handler, response_buf


@pytest.fixture
def fake_home_root(tmp_path):
    """A directory whose dev-team/ is a symlink to REPO_ROOT (this
    worktree), so patching Path.home() to return it makes the production
    (helpers_root=None) code path resolve scripts/cr-schema-validator.py
    from the BRANCH UNDER TEST rather than from whatever ~/dev-team (main
    checkout) happens to contain — same reasoning test_xaca0297's
    helpers_root=str(REPO_ROOT) uses for the shell side (XACA-1019)."""
    home = tmp_path / "home"
    home.mkdir()
    (home / "dev-team").symlink_to(REPO_ROOT, target_is_directory=True)
    return home


def _patched_home(fake_home_root):
    return patch.object(server.Path, "home", return_value=fake_home_root)


# ── fixture boards ────────────────────────────────────────────────────────

def _fixture_board(tmp: Path, state="cr-submitted", timestamps=None, cr_id="CR-GEN-1"):
    board = tmp / "board.json"
    board.write_text(json.dumps({
        "teamConfig": {"crSupport": {"enabled": True}},
        "crs": [{
            "id": cr_id, "title": "fixture", "type": "major",
            "crState": state, "itemIds": [], "pushback_count": 0,
            "timestamps": timestamps if timestamps is not None else {
                "cr_created_at": "2026-08-01T00:00:00Z",
                "cr_submitted_at": "2026-08-01T01:00:00Z",
            },
            "createdAt": "2026-08-01T00:00:00Z",
            "updatedAt": "2026-08-01T00:00:00Z",
        }],
        "nextCrSeq": 2, "backlog": [],
        "lastUpdated": "2026-08-01T00:00:00Z",
    }), encoding="utf-8")
    return board


def _run_shell_parts(parts, extra_env=None):
    env = {**os.environ, "KB_CR_ACTOR": "pytest-fixture",
           "KB_SKIP_DUAL_BOARD_CHECK": "1"}
    env.pop("_KB_CR_LOADED", None)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(["zsh", "-c", "\n".join(parts)],
                          capture_output=True, text=True, env=env, timeout=60)


def _build_and_run(board, target_state, approval_waiver=None, actor=None,
                    cr_id="CR-GEN-1"):
    """CALLS the production assembly against THIS WORKTREE's kb-cr.sh
    (helpers_root=str(REPO_ROOT)) — never the default ~/dev-team resolution
    (XACA-1019)."""
    parts = HANDLER_CLS._build_cr_transition_shell_parts(
        str(board.resolve()), cr_id, target_state,
        helpers_root=str(REPO_ROOT),
        approval_waiver=approval_waiver, actor=actor,
    )
    proc = _run_shell_parts(parts)
    data = json.loads(board.read_text(encoding="utf-8"))
    return proc, data


# ── (a) derived evidence map == _kb_cr_state_required_evidence, every state ─

def _shell_required_evidence(state):
    """Run _kb_cr_state_required_evidence <state> against THIS WORKTREE's
    kb-cr.sh and return its output as a list of tokens (possibly "a|b"
    OR-group tokens, unsplit — same shape _derive_cr_evidence_map returns)."""
    parts = [
        f"source {shlex.quote(str(KANBAN_HELPERS_SH))}",
        f"source {shlex.quote(str(KB_CR_SH))}",
        f"_kb_cr_state_required_evidence {shlex.quote(state)}",
    ]
    proc = _run_shell_parts(parts)
    assert proc.returncode == 0, (
        f"_kb_cr_state_required_evidence {state!r} exited {proc.returncode}: "
        f"{proc.stderr}"
    )
    return [line for line in proc.stdout.splitlines() if line.strip()]


# The 11 canonical states, enumerated from the VALIDATOR's own map rather
# than a hand list — a state added to STATE_ENTRY_TS is automatically
# covered here.
_ALL_STATES = list(VALIDATOR.STATE_ENTRY_TS.keys())


def test_all_states_enumerated_is_nonempty_and_matches_known_count():
    """Sanity floor: if this ever comes back empty or tiny, every assertion
    below would vacuously pass over nothing."""
    assert len(_ALL_STATES) == 11, (
        f"expected 11 canonical crStates, got {len(_ALL_STATES)}: {_ALL_STATES} "
        "— either the schema grew a state (update this comment, the pin test "
        "still applies) or STATE_ENTRY_TS failed to load correctly."
    )


@pytest.mark.parametrize("state", _ALL_STATES)
def test_derived_evidence_map_matches_shell_for_every_state(state):
    """
    THE core D4 pin: the endpoint-derived map must equal
    _kb_cr_state_required_evidence's own output for EVERY state, token for
    token, in order — including OR-group tokens passed through unsplit.
    """
    derived = HANDLER_CLS._derive_cr_evidence_map(helpers_root=str(REPO_ROOT))
    assert state in derived, f"derived map is missing state {state!r} entirely"
    shell_tokens = _shell_required_evidence(state)
    assert derived[state] == shell_tokens, (
        f"state {state!r}: derived={derived[state]!r} != shell={shell_tokens!r}"
    )


def test_derivation_goes_red_when_the_validator_map_is_mutated():
    """
    Proof the pin above is not vacuous: point _derive_cr_evidence_map at a
    MUTATED copy of the validator (the 'implementing' row's OR-group
    collapsed to a single field) and confirm the derived output changes —
    i.e. the function actually reads EVIDENCE_PREREQS rather than returning
    a cached/hardcoded answer. If this ever stopped detecting the mutation,
    the parity test above would also stop being able to catch real drift.
    """
    real_src = VALIDATOR_PY.read_text(encoding="utf-8")
    mutated_src = real_src.replace(
        '("cr_started_dev_at",   ("cr_submitted_at", "cr_approved_at|cr_approval_waived_at")),',
        '("cr_started_dev_at",   ("cr_submitted_at", "cr_approved_at")),',
    )
    assert mutated_src != real_src, (
        "the literal EVIDENCE_PREREQS row for cr_started_dev_at was not found — "
        "this fixture no longer matches the source it mutates, update the string"
    )

    with tempfile.TemporaryDirectory() as td:
        mutated_root = Path(td)
        (mutated_root / "scripts").mkdir()
        (mutated_root / "scripts" / "cr-schema-validator.py").write_text(
            mutated_src, encoding="utf-8"
        )
        real_map = HANDLER_CLS._derive_cr_evidence_map(helpers_root=str(REPO_ROOT))
        mutated_map = HANDLER_CLS._derive_cr_evidence_map(helpers_root=str(mutated_root))

    assert real_map["implementing"] == ["cr_submitted_at", "cr_approved_at|cr_approval_waived_at"]
    assert mutated_map["implementing"] == ["cr_submitted_at", "cr_approved_at"], (
        "mutating the validator's source did not change the derived output — "
        "the derivation is not actually reading EVIDENCE_PREREQS from disk"
    )
    assert real_map["implementing"] != mutated_map["implementing"]


# ── (b) route test: exact path resolves to the evidence-map handler ─────────

def test_evidence_map_path_does_not_match_the_cr_id_regex():
    """
    Cheap, direct proof of the routing hazard the plan calls out: if
    'evidence-map' fell through to a generic '/api/kanban/cr/<id>/...'
    prefix branch, it would be parsed as a CR-ID and 400. The CR-ID regex
    itself (copied from serve_cr_activity / handle_cr_transition) must
    reject it.
    """
    assert not re.match(r"^CR-[A-Z]+-\d{8}-\d+$", "evidence-map")


def test_evidence_map_route_is_dispatched_not_parsed_as_cr_id(fake_home_root):
    """
    Exercises the REAL do_GET() dispatch. A 400 "Invalid CR-ID format" means
    the route is wired wrong (fell through to the /activity prefix branch's
    sibling CR-ID parsing instead of the exact-path match).
    """
    with _patched_home(fake_home_root):
        handler, buf = _make_request_handler("/api/kanban/cr/evidence-map")
        handler.do_GET()

    assert handler._response_code == 200, (
        f"expected 200, got {handler._response_code}: {buf.getvalue()!r}"
    )
    payload = json.loads(buf.getvalue())
    assert "error" not in payload, payload
    assert payload.get("orSeparator") == "|"
    assert payload.get("source") == "cr-schema-validator.py"
    states = payload.get("states")
    assert isinstance(states, dict) and "implementing" in states
    assert "cr_approved_at|cr_approval_waived_at" in states["implementing"]
    assert states.get("cr-drafted") == []


def test_evidence_map_endpoint_fails_closed_on_unreadable_validator(tmp_path):
    """
    XACA-1239: an unreadable validator must 500 with a JSON error, never an
    empty {"states": {}} — an empty map would read to a client as "nothing
    is required anywhere", the opposite of fail-closed.

    XACA-1239-020: _resolve_cr_schema_validator_path now tries THREE
    candidate roots in production (Path.home()/"dev-team", $AITEAMFORGE_DIR,
    UI_DIR.absolute().parent — see _cr_schema_validator_candidate_roots),
    not just Path.home()/"dev-team". Patching only Path.home() is no longer
    enough to prove fail-closed: on this worktree, UI_DIR.absolute().parent
    IS a real checkout with a real scripts/cr-schema-validator.py, so root 3
    would find it and this test would pass for the WRONG reason (silently
    stop testing the failure path at all). All three candidate roots must
    be repointed at directories with no validator (mirrors the established
    idiom in test_xaca0992_appicons.py for the sibling _image_candidate_roots
    fail-closed cases).
    """
    missing_root = tmp_path / "missing-home"
    (missing_root / "dev-team" / "scripts").mkdir(parents=True, exist_ok=True)
    # Deliberately do NOT create cr-schema-validator.py under it.

    fake_ui_dir = tmp_path / "install" / "lcars-ui"
    (fake_ui_dir / "install-scripts-parent-has-no-validator").mkdir(parents=True)

    with patch.object(server, "UI_DIR", fake_ui_dir), \
         patch.object(server.Path, "home", return_value=missing_root), \
         patch.dict(os.environ, {}, clear=False):
        os.environ.pop("AITEAMFORGE_DIR", None)
        handler, buf = _make_request_handler("/api/kanban/cr/evidence-map")
        handler.do_GET()

    assert handler._response_code == 500, (
        f"expected 500 for an unreadable validator, got {handler._response_code}: "
        f"{buf.getvalue()!r}"
    )
    payload = json.loads(buf.getvalue())
    assert "error" in payload
    assert "states" not in payload, "must never serve an empty map as if it were real"


def test_evidence_map_endpoint_resolves_from_installed_layout_when_dev_team_absent(tmp_path):
    """
    XACA-1239-020: the actual defect this fixes. A consumer (tap) install
    has no ~/dev-team at all — cr-schema-validator.py lives at
    $AITEAMFORGE_DIR/scripts/cr-schema-validator.py instead (per
    homebrew-tap/libexec/installers/install-kanban.sh's layout, once the
    companion sync-tap.sh mapping ships it there). Before this fix, every
    consumer request to GET /api/kanban/cr/evidence-map (and every
    approval_waiver POST) 500'd, because production resolved ONLY
    Path.home()/"dev-team", which never exists on such a machine.
    """
    missing_dev_team = tmp_path / "missing-home"
    # Deliberately do NOT create a dev-team dir under it at all.

    installed_root = tmp_path / "aiteamforge"
    (installed_root / "scripts").mkdir(parents=True)
    shutil.copy(str(VALIDATOR_PY), str(installed_root / "scripts" / "cr-schema-validator.py"))

    fake_ui_dir = installed_root / "lcars-ui"
    fake_ui_dir.mkdir(parents=True)

    with patch.object(server, "UI_DIR", fake_ui_dir), \
         patch.object(server.Path, "home", return_value=missing_dev_team), \
         patch.dict(os.environ, {"AITEAMFORGE_DIR": str(installed_root)}):
        handler, buf = _make_request_handler("/api/kanban/cr/evidence-map")
        handler.do_GET()

    assert handler._response_code == 200, (
        f"expected 200 resolving via $AITEAMFORGE_DIR, got "
        f"{handler._response_code}: {buf.getvalue()!r}"
    )
    payload = json.loads(buf.getvalue())
    assert "states" in payload
    assert payload["states"].get("implementing") == ["cr_submitted_at", "cr_approved_at|cr_approval_waived_at"]


# ── (c) waiver + state change run as ONE script ──────────────────────────────

def test_waiver_and_transition_run_as_one_script_cr_submitted_to_implementing():
    with tempfile.TemporaryDirectory() as td:
        board = _fixture_board(Path(td))  # cr-submitted, no cr_approved_at
        proc, data = _build_and_run(
            board, "implementing",
            approval_waiver="No approval notice received — IT Connect approval "
                             "signal not integrated (XACA-0899).",
            actor="pytest-operator",
        )
        assert proc.returncode == 0, proc.stderr
        cr = data["crs"][0]
        assert cr["crState"] == "implementing"
        ts = cr["timestamps"]
        assert ts.get("cr_started_dev_at"), "state entry timestamp not stamped"
        assert ts.get("cr_approval_waived_at"), "waiver timestamp not stamped"
        assert not ts.get("cr_approved_at"), (
            "a waiver must NEVER write cr_approved_at — that is exactly the "
            "fabrication XACA-0924 exists to prevent"
        )
        assert not cr.get("approver"), "a waiver must never write approver"
        waiver = cr.get("approvalWaiver")
        assert waiver, "approvalWaiver object not written"
        assert waiver["actor"] == "pytest-operator"
        assert "IT Connect" in waiver["reason"]


# ── (d) forced waiver-write failure is fatal (exit 4), board unchanged ──────

def test_waiver_write_failure_is_fatal_and_board_is_unchanged():
    """
    _kb_cr_waive_approval refuses (non-zero, unwritten) when the CR already
    has a real approval on record. Force exactly that refusal and confirm
    the generated script exits 4 and the board shows NO state change — the
    D5 guarantee that a half-done move (state advanced with neither a real
    approval nor a recorded waiver) is impossible.
    """
    with tempfile.TemporaryDirectory() as td:
        board = _fixture_board(Path(td), state="cr-submitted", timestamps={
            "cr_created_at": "2026-08-01T00:00:00Z",
            "cr_submitted_at": "2026-08-01T01:00:00Z",
            "cr_approved_at": "2026-08-01T02:00:00Z",
        })
        before = json.loads(board.read_text(encoding="utf-8"))
        proc, data = _build_and_run(
            board, "implementing",
            approval_waiver="operator requested a waiver anyway",
            actor="pytest-operator",
        )
        assert proc.returncode == 4, (
            f"expected exit 4 for a refused waiver write, got {proc.returncode}: "
            f"{proc.stderr}"
        )
        assert "approval waiver write failed" in proc.stderr
        # Guard against a false pass: our own `|| { ...; exit 4; }` fires on
        # ANY failure of _kb_cr_waive_approval, including the function being
        # UNDEFINED (a sourcing problem, "command not found" — which zsh
        # also surfaces as a non-zero exit and would land on the same
        # message above). Assert the refusal actually came from the real
        # helper's own guard, not from a missing definition.
        assert "command not found" not in proc.stderr, (
            "the failure looks like _kb_cr_waive_approval was never sourced, "
            "not a genuine refusal — this assertion would otherwise pass for "
            "the wrong reason: " + proc.stderr
        )
        assert "already has a recorded approval" in proc.stderr
        cr = data["crs"][0]
        assert cr["crState"] == "cr-submitted", "state MUST NOT have advanced"
        assert not cr["timestamps"].get("cr_started_dev_at"), (
            "state entry timestamp must not exist — the state write must never "
            "have run after the waiver write failed"
        )
        assert cr["timestamps"].get("cr_approval_waived_at") is None, (
            "no NEW waiver may have been written either"
        )
        assert cr == before["crs"][0], "board must be byte-for-byte unchanged"


# ── (e) shell-injection in reason is inert ──────────────────────────────────

def test_hostile_reason_is_quoted_not_executed():
    hostile = "$(touch /tmp/xaca1239_pwned) `whoami` $HOME; rm -rf /tmp/nope"
    marker = Path("/tmp/xaca1239_pwned")
    if marker.exists():
        marker.unlink()
    try:
        with tempfile.TemporaryDirectory() as td:
            board = _fixture_board(Path(td))
            proc, data = _build_and_run(
                board, "implementing", approval_waiver=hostile, actor="pytest",
            )
            assert proc.returncode == 0, proc.stderr
            assert not marker.exists(), "COMMAND SUBSTITUTION FIRED in the reason"
            waiver = data["crs"][0].get("approvalWaiver") or {}
            assert waiver.get("reason") == hostile, "value was mangled"
    finally:
        if marker.exists():
            marker.unlink()


def test_hostile_actor_is_quoted_not_executed():
    hostile_actor = "$(touch /tmp/xaca1239_pwned_actor)`id`"
    marker = Path("/tmp/xaca1239_pwned_actor")
    if marker.exists():
        marker.unlink()
    try:
        with tempfile.TemporaryDirectory() as td:
            board = _fixture_board(Path(td))
            proc, data = _build_and_run(
                board, "implementing", approval_waiver="fine", actor=hostile_actor,
            )
            assert proc.returncode == 0, proc.stderr
            assert not marker.exists(), "COMMAND SUBSTITUTION FIRED in the actor"
            waiver = data["crs"][0].get("approvalWaiver") or {}
            assert waiver.get("actor") == hostile_actor
    finally:
        if marker.exists():
            marker.unlink()


# ── (f) request-shape validation ─────────────────────────────────────────────

class TestApprovalWaiverFieldValidation(unittest.TestCase):
    def test_absent_waiver_is_a_no_op_ok(self):
        inst = _new_handler_instance()
        ok, err, reason, status = inst._cr_validate_approval_waiver("implementing", {})
        self.assertTrue(ok)
        self.assertIsNone(err)
        self.assertIsNone(reason)
        self.assertIsNone(status)

    def test_blank_reason_rejected(self):
        inst = _new_handler_instance()
        for bad in ["", "   ", "\t\n"]:
            with self.subTest(bad=bad):
                ok, err, reason, status = inst._cr_validate_approval_waiver(
                    "implementing", {"approval_waiver": {"reason": bad}}
                )
                self.assertFalse(ok)
                self.assertEqual(status, 400)
                self.assertIn("reason", err)

    def test_missing_reason_key_rejected(self):
        inst = _new_handler_instance()
        ok, err, reason, status = inst._cr_validate_approval_waiver(
            "implementing", {"approval_waiver": {}}
        )
        self.assertFalse(ok)
        self.assertEqual(status, 400)

    def test_non_object_waiver_rejected(self):
        inst = _new_handler_instance()
        for bad in ["a string", 42, ["reason", "x"], True]:
            with self.subTest(bad=bad):
                ok, err, reason, status = inst._cr_validate_approval_waiver(
                    "implementing", {"approval_waiver": bad}
                )
                self.assertFalse(ok)
                self.assertEqual(status, 400)
                self.assertIn("object", err)

    def test_unknown_keys_rejected(self):
        inst = _new_handler_instance()
        ok, err, reason, status = inst._cr_validate_approval_waiver(
            "implementing",
            {"approval_waiver": {"reason": "fine", "approver_login": "sneaky"}},
        )
        self.assertFalse(ok)
        self.assertEqual(status, 400)
        self.assertIn("approver_login", err)

    def test_reason_too_long_rejected(self):
        inst = _new_handler_instance()
        ok, err, reason, status = inst._cr_validate_approval_waiver(
            "implementing",
            {"approval_waiver": {"reason": "x" * 2001}},
        )
        self.assertFalse(ok)
        self.assertEqual(status, 400)

    def test_waiver_plus_approver_rejected_as_contradictory(self):
        inst = _new_handler_instance()
        ok, err, reason, status = inst._cr_validate_approval_waiver(
            "implementing",
            {
                "approval_waiver": {"reason": "fine"},
                "approver": {"login": "someone", "name": "Some One"},
            },
        )
        self.assertFalse(ok)
        self.assertEqual(status, 400)
        self.assertIn("approver", err)

    def test_waiver_on_target_not_requiring_approval_rejected(self):
        inst = self._inst_with_worktree_home()
        ok, err, reason, status = inst._cr_validate_approval_waiver(
            "cr-rejected", {"approval_waiver": {"reason": "fine"}}
        )
        self.assertFalse(ok)
        self.assertEqual(status, 400)
        self.assertIn("not applicable", err)

    def test_waiver_on_target_requiring_approval_accepted(self):
        inst = self._inst_with_worktree_home()
        for target in ("implementing", "deployed-dev", "deployed-prod"):
            with self.subTest(target=target):
                ok, err, reason, status = inst._cr_validate_approval_waiver(
                    target, {"approval_waiver": {"reason": "  fine, trimmed  "}}
                )
                self.assertTrue(ok, err)
                self.assertIsNone(err)
                self.assertEqual(reason, "fine, trimmed")
                self.assertIsNone(status)

    def _inst_with_worktree_home(self):
        """Patches Path.home() to a fresh symlink-to-worktree dir for the
        life of the TEST METHOD (not just one call), since
        _cr_target_accepts_approval_waiver uses the default (helpers_root=
        None) resolution and must read THIS WORKTREE's validator."""
        tmp = tempfile.mkdtemp()
        home = Path(tmp) / "home"
        home.mkdir()
        (home / "dev-team").symlink_to(REPO_ROOT, target_is_directory=True)
        home_patch = patch.object(server.Path, "home", return_value=home)
        home_patch.start()
        self.addCleanup(home_patch.stop)
        self.addCleanup(lambda: shutil.rmtree(tmp, ignore_errors=True))
        return _new_handler_instance()


# ── (f) per-CR precheck (XACA-1239-019): crState + already-satisfied ────────
#
# _cr_precheck_approval_waiver_against_cr is the server-side mirror of
# _kb_cr_waive_approval's own D3 guards in scripts/kb-cr.sh. Without the
# crState check, a waiver offered against any CR not sitting in
# cr-submitted/cr-held (e.g. a --force'd implementing CR moving on to
# deployed-dev, or cr-rejected moving to implementing) reaches the generated
# shell script, whose waiver-write step is fatal (D5's `|| { …; exit 4; }`)
# — the endpoint's generic script-failure path then answers 500 for what is
# actually a 409-shaped client precondition failure. These tests call the
# real method directly (no request/socket mocking needed — it takes plain
# dict args), following this file's own established rule (XACA-0297 review
# round 3): call the production function, never hand-mirror its logic.
class TestApprovalWaiverPerCrPrecheck(unittest.TestCase):
    def test_none_reason_is_a_no_op_ok(self):
        inst = _new_handler_instance()
        ok, err = inst._cr_precheck_approval_waiver_against_cr(
            "CR-GEN-1", {"crState": "implementing"}, None)
        self.assertTrue(ok)
        self.assertIsNone(err)

    def test_wrong_crstate_rejected_409(self):
        inst = _new_handler_instance()
        for bad_state in ("implementing", "deployed-dev", "deployed-prod",
                           "cr-rejected", "cr-approved", "cr-published",
                           "cr-drafted", "emergency-deployed", None):
            with self.subTest(bad_state=bad_state):
                cr = {"crState": bad_state, "timestamps": {}}
                ok, err = inst._cr_precheck_approval_waiver_against_cr(
                    "CR-GEN-1", cr, "operator requested a waiver anyway")
                self.assertFalse(ok)
                self.assertIn("cr-submitted or cr-held", err)
                self.assertIn("CR-GEN-1", err)

    def test_cr_submitted_and_cr_held_are_accepted_states(self):
        inst = _new_handler_instance()
        for good_state in ("cr-submitted", "cr-held"):
            with self.subTest(good_state=good_state):
                cr = {"crState": good_state, "timestamps": {}}
                ok, err = inst._cr_precheck_approval_waiver_against_cr(
                    "CR-GEN-1", cr, "a reason")
                self.assertTrue(ok, err)
                self.assertIsNone(err)

    def test_already_approved_rejected_409_even_from_allowed_state(self):
        inst = _new_handler_instance()
        cr = {"crState": "cr-submitted",
              "timestamps": {"cr_approved_at": "2026-08-01T02:00:00Z"}}
        ok, err = inst._cr_precheck_approval_waiver_against_cr(
            "CR-GEN-1", cr, "a reason")
        self.assertFalse(ok)
        self.assertIn("already has a recorded approval", err)

    def test_already_waived_rejected_409_even_from_allowed_state(self):
        inst = _new_handler_instance()
        cr = {"crState": "cr-held",
              "timestamps": {"cr_approval_waived_at": "2026-08-01T02:00:00Z"}}
        ok, err = inst._cr_precheck_approval_waiver_against_cr(
            "CR-GEN-1", cr, "a reason")
        self.assertFalse(ok)
        self.assertIn("already has a recorded approval", err)
        self.assertIn("waiver", err)

    def test_crstate_checked_before_already_satisfied(self):
        """A CR in a disallowed state that ALSO happens to carry
        cr_approved_at must still be refused for the state reason — the
        D3 gate (kb-cr.sh's own check order) runs first."""
        inst = _new_handler_instance()
        cr = {"crState": "implementing",
              "timestamps": {"cr_approved_at": "2026-08-01T02:00:00Z"}}
        ok, err = inst._cr_precheck_approval_waiver_against_cr(
            "CR-GEN-1", cr, "a reason")
        self.assertFalse(ok)
        self.assertIn("cr-submitted or cr-held", err)


if __name__ == "__main__":
    unittest.main()
