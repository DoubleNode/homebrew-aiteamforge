"""XACA-1390-001 — LCARS EDIT STATE vs kb-cr's v2 lifecycle guard.

A CR marked ``cr_lifecycle: "v2"`` is subject to scripts/kb-cr.sh's
``_kb_cr_v2_guard`` on every force-write, including the LCARS transition
endpoint (it reaches the guard through ``_kb_cr_stamp_state_entry``). Before
this ticket EDIT STATE offered every state for every CR, so a v2 CR was offered
targets kb-cr ALWAYS refuses (implementing, deployed-dev, cr-held, ...), and
the refusal came back as a generic 500.

Three copies of the STRUCTURAL refusal rules exist and must agree:

  * scripts/kb-cr.sh          ``_kb_cr_v2_guard``          (the authority)
  * lcars-ui/server.py        ``_cr_v2_structural_refusal`` (400 before shell-out)
  * lcars-ui/js/lcars-cr-tab.js ``_crV2StructurallyRefused`` (dropdown filter)

This file pins all three over EVERY (from, to) pair by EXECUTING the real
shell guard as the oracle — never a hand-typed expectation table, which would
just be a fourth copy. The fixture CR carries complete approval evidence, a
past approval time, no deploy window and no lead-draft-approval requirement,
so every evidence-conditional branch of the guard passes and whatever it still
refuses is, by construction, structural.

Isolation: zsh subprocesses run with a sandboxed HOME/TMPDIR and TMUX unset;
helpers are sourced from THIS worktree; the server module is imported under a
synthetic team id. No live board, no live LCARS server.
"""

import importlib.util
import json
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
LCARS_UI_DIR = REPO_ROOT / "lcars-ui"
SERVER_PY = LCARS_UI_DIR / "server.py"
CR_TAB_JS = LCARS_UI_DIR / "js" / "lcars-cr-tab.js"
KB_CR_SH = REPO_ROOT / "scripts" / "kb-cr.sh"
KANBAN_HELPERS_SH = REPO_ROOT / "kanban-helpers.sh"

pytestmark = pytest.mark.skipif(
    shutil.which("zsh") is None or shutil.which("jq") is None,
    reason="zsh and jq required",
)

SYNTH_TEAM = "zzxaca1390"

# ── server.py bootstrap (same stub convention as test_xaca1239_*) ────────────

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
    for name, stub in _stub_modules.items():
        if name not in sys.modules:
            sys.modules[name] = stub
    saved = {k: os.environ.get(k) for k in ("LCARS_TEAM", "LCARS_SKIP_TEAM_VALIDATION")}
    os.environ["LCARS_TEAM"] = SYNTH_TEAM
    os.environ["LCARS_SKIP_TEAM_VALIDATION"] = "1"
    try:
        spec = importlib.util.spec_from_file_location("lcars_server_x1390", SERVER_PY)
        mod = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(mod)
        except SystemExit:
            pass
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    return mod


server = _load_server_module()
H = server.LCARSHandler
STATES = sorted(H._CR_VALID_STATES)


# ── sandboxed shell runner ───────────────────────────────────────────────────

def _sandbox_env(tmp_path):
    home = tmp_path / "home"
    tmpd = tmp_path / "tmp"
    home.mkdir(exist_ok=True)
    tmpd.mkdir(exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith("TMUX")}
    env.update({
        "HOME": str(home), "TMPDIR": str(tmpd),
        "KB_CR_ACTOR": "pytest-x1390", "KB_SKIP_DUAL_BOARD_CHECK": "1",
        "KB_TEAM": SYNTH_TEAM, "KB_TERMINAL": "agent",
        # deployed-prod timing gate clock: well after the fixture approval.
        "KB_CR_TEST_NOW": "2026-09-01T00:00:00Z",
    })
    env.pop("_KB_CR_LOADED", None)
    return env


def _run_zsh(parts, env):
    return subprocess.run(["zsh", "-c", "\n".join(parts)], capture_output=True,
                          text=True, env=env, timeout=120)


def _board(tmp_path, state="cr-submitted", v2=True, timestamps=None, extra=None):
    cr = {
        "id": "CR-ZZXACA-20261002-1", "title": "fixture", "type": "major",
        "crState": state, "itemIds": [], "pushback_count": 0,
        "approver": {"login": "lead", "name": "Lead"},
        "approval_basis": "explicit",
        "held_from": "cr-submitted",
        "timestamps": timestamps if timestamps is not None else {
            "cr_created_at": "2026-08-01T00:00:00Z",
            "cr_submitted_at": "2026-08-01T01:00:00Z",
            "cr_approved_at": "2026-08-01T02:00:00Z",
        },
        "createdAt": "2026-08-01T00:00:00Z",
        "updatedAt": "2026-08-01T00:00:00Z",
    }
    if v2:
        cr["cr_lifecycle"] = "v2"
    if extra:
        cr.update(extra)
    board = tmp_path / "board.json"
    board.write_text(json.dumps({
        "teamConfig": {"crSupport": {"enabled": True, "requireLeadDraftApproval": False}},
        "crs": [cr], "nextCrSeq": 2, "backlog": [],
        "lastUpdated": "2026-08-01T00:00:00Z",
    }), encoding="utf-8")
    return board


def _oracle_refusals(tmp_path, v2=True):
    """Run the REAL _kb_cr_v2_guard for every (from, to) pair in ONE zsh
    process. The guard takes from/to as arguments, so one board serves all
    pairs. Returns {(from, to): refused_bool}."""
    board = _board(tmp_path, v2=v2)
    parts = [
        f"source {shlex.quote(str(KANBAN_HELPERS_SH))}",
        f"source {shlex.quote(str(KB_CR_SH))}",
        f"for f in {' '.join(STATES)}; do for t in {' '.join(STATES)}; do",
        f'  _kb_cr_v2_guard {shlex.quote(str(board))} 0 CR-ZZXACA-20261002-1 transition "$f" "$t" 2>/dev/null',
        '  echo "PAIR $f $t $?"',
        "done; done",
    ]
    proc = _run_zsh(parts, _sandbox_env(tmp_path))
    assert proc.returncode == 0, proc.stderr
    out = {}
    for line in proc.stdout.splitlines():
        if line.startswith("PAIR "):
            _, f, t, rc = line.split()
            out[(f, t)] = rc != "0"
    assert len(out) == len(STATES) ** 2, f"oracle produced {len(out)} pairs: {proc.stderr}"
    return out


@pytest.fixture(scope="module")
def oracle_v2(tmp_path_factory):
    return _oracle_refusals(tmp_path_factory.mktemp("oracle_v2"), v2=True)


# ── (1) server predicate == real kb-cr guard, every pair ─────────────────────

def test_server_predicate_matches_kb_cr_guard_for_every_pair(oracle_v2):
    diffs = []
    for (f, t), refused in sorted(oracle_v2.items()):
        mine = H._cr_v2_structural_refusal(f, t) is not None
        if mine != refused:
            diffs.append(f"{f} -> {t}: kb-cr refused={refused} server refused={mine}")
    assert not diffs, "server.py drifted from _kb_cr_v2_guard:\n" + "\n".join(diffs)


def test_oracle_is_not_vacuous(oracle_v2):
    """The guard must actually refuse SOMETHING and allow SOMETHING with this
    fixture — otherwise a broken source/invocation (every rc=1, or the guard
    never reached) would make the parity test above meaningless."""
    assert oracle_v2[("cr-submitted", "implementing")] is True
    assert oracle_v2[("cr-submitted", "cr-held")] is True
    assert oracle_v2[("deployed-prod", "cr-completed")] is False
    assert oracle_v2[("cr-approved", "deployed-prod")] is False
    assert oracle_v2[("cr-submitted", "cr-approved")] is False


def test_legacy_cr_is_never_refused_by_the_guard(tmp_path):
    refusals = _oracle_refusals(tmp_path, v2=False)
    assert not any(refusals.values()), "kb-cr guard refused a LEGACY CR transition"


def test_server_and_js_state_lists_agree():
    src = CR_TAB_JS.read_text(encoding="utf-8")
    start = src.index("const _CR_STATES = [")
    block = src[start:src.index("];", start)]
    js_states = set(__import__("re").findall(r"'([a-z-]+)'", block))
    assert js_states == set(H._CR_VALID_STATES)
    assert "cr-completed" in js_states


# ── (2) JS predicate == server predicate, every pair ─────────────────────────

def test_js_predicate_matches_server_predicate_for_every_pair():
    if shutil.which("node") is None:
        pytest.skip("node not available")
    src = CR_TAB_JS.read_text(encoding="utf-8")
    start = src.index("function _crV2StructurallyRefused(")
    end = src.index("function _crEditStateTargets(", start)
    fn_src = src[start:end]
    script = (
        fn_src
        + f"\nconst S = {json.dumps(STATES)};"
        + "\nconst out = {}; for (const f of S) for (const t of S) out[f + '>' + t] = _crV2StructurallyRefused(f, t);"
        + "\nprocess.stdout.write(JSON.stringify(out));"
    )
    proc = subprocess.run(["node", "-e", script], capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stderr
    js = json.loads(proc.stdout)
    diffs = [
        f"{k}: js={v} server={H._cr_v2_structural_refusal(*k.split('>')) is not None}"
        for k, v in sorted(js.items())
        if v != (H._cr_v2_structural_refusal(*k.split(">")) is not None)
    ]
    assert len(js) == len(STATES) ** 2
    assert not diffs, "lcars-cr-tab.js drifted from server.py:\n" + "\n".join(diffs)


# ── (3) cr-completed is a first-class endpoint target ────────────────────────

def test_cr_completed_is_a_valid_target_with_no_required_fields():
    assert "cr-completed" in H._CR_VALID_STATES
    assert H._CR_REQUIRED_FIELDS["cr-completed"] == []
    assert H._CR_STATE_ENTRY_TIMESTAMP["cr-completed"] == "cr_completed_at"


# ── (4) generated script: guard runs FIRST, exit 5, nothing written ──────────

def _run_generated(tmp_path, board, target, approval_waiver=None):
    parts = H._build_cr_transition_shell_parts(
        str(board.resolve()), "CR-ZZXACA-20261002-1", target,
        helpers_root=str(REPO_ROOT), approval_waiver=approval_waiver,
    )
    proc = _run_zsh(parts, _sandbox_env(tmp_path))
    return proc, json.loads(board.read_text(encoding="utf-8"))["crs"][0]


def test_generated_script_v2_refusal_exits_5_with_kb_cr_message_and_writes_nothing(tmp_path):
    board = _board(tmp_path, state="cr-submitted")
    proc, cr = _run_generated(tmp_path, board, "implementing")
    assert proc.returncode == 5, (proc.returncode, proc.stderr)
    assert "v2 lifecycle" in proc.stderr
    assert cr["crState"] == "cr-submitted"
    assert "cr_started_dev_at" not in cr["timestamps"]


def test_generated_script_refusal_precedes_waiver_write(tmp_path):
    """A v2 cr-submitted CR without approval: the waiver is applicable to
    deployed-prod, but the guard refuses deployed-prod from cr-submitted. The
    waiver must NOT be recorded for a move that never happens."""
    board = _board(tmp_path, state="cr-submitted", timestamps={
        "cr_created_at": "2026-08-01T00:00:00Z",
        "cr_submitted_at": "2026-08-01T01:00:00Z",
    }, extra={"approver": {}, "approval_basis": ""})
    proc, cr = _run_generated(tmp_path, board, "deployed-prod", approval_waiver="no notice")
    assert proc.returncode == 5, (proc.returncode, proc.stderr)
    assert "cr_approval_waived_at" not in cr["timestamps"]
    assert cr["crState"] == "cr-submitted"


def test_generated_script_legacy_cr_still_moves_to_implementing(tmp_path):
    board = _board(tmp_path, state="cr-approved", v2=False)
    proc, cr = _run_generated(tmp_path, board, "implementing")
    assert proc.returncode == 0, proc.stderr
    assert cr["crState"] == "implementing"


def test_generated_script_v2_deployed_prod_to_cr_completed_succeeds(tmp_path):
    board = _board(tmp_path, state="deployed-prod", timestamps={
        "cr_created_at": "2026-08-01T00:00:00Z",
        "cr_submitted_at": "2026-08-01T01:00:00Z",
        "cr_approved_at": "2026-08-01T02:00:00Z",
        "cr_deployed_prod_at": "2026-08-02T00:00:00Z",
    })
    proc, cr = _run_generated(tmp_path, board, "cr-completed")
    assert proc.returncode == 0, proc.stderr
    assert cr["crState"] == "cr-completed"
    assert cr["timestamps"].get("cr_completed_at")


# ── (5) handler: structural refusal answered 400 BEFORE any shell-out ────────

def _post_transition(tmp_path, cr_state, target, v2=True):
    kdir = tmp_path / "kanban"
    kdir.mkdir()
    cr = {"id": "CR-ZZXACA-20261002-1", "crState": cr_state,
          "updatedAt": "2026-08-01T00:00:00Z", "timestamps": {}}
    if v2:
        cr["cr_lifecycle"] = "v2"
    # CR-ID prefix "ZZXACA" lowercases to the (synthetic) team id "zzxaca".
    (kdir / "zzxaca-board.json").write_text(json.dumps({"crs": [cr]}))
    body = json.dumps({"targetState": target}).encode()

    with patch.object(H, "__init__", lambda self, *a, **kw: None):
        h = H.__new__(H)
    h.headers = {"Content-Length": str(len(body))}
    h.rfile = MagicMock(read=MagicMock(return_value=body))
    sent = {}
    h._send_json_response = lambda payload, status=200: sent.update(payload=payload, status=status)
    run = MagicMock(side_effect=RuntimeError("stub: shell-out reached"))
    with patch.dict(server.TEAM_KANBAN_DIRS, {"zzxaca": kdir}), \
         patch.object(server.subprocess, "run", run):
        h.handle_cr_transition("CR-ZZXACA-20261002-1")
    return sent, run


def test_handler_rejects_v2_structural_refusal_with_400_and_no_shell(tmp_path):
    sent, run = _post_transition(tmp_path, "cr-submitted", "implementing")
    assert sent["status"] == 400, sent
    assert "kb-cr refuses" in sent["payload"]["error"]
    assert "cr-submitted -> implementing" in sent["payload"]["error"]
    run.assert_not_called()


def test_handler_does_not_prefilter_legacy_cr(tmp_path):
    """Legacy CR: no structural pre-check, so the request reaches the shell
    (our stub raises, which the handler turns into a 500 — proving it got
    past the v2 pre-check rather than being answered 400)."""
    sent, run = _post_transition(tmp_path, "cr-submitted", "implementing", v2=False)
    run.assert_called_once()
    assert sent["status"] == 500


# ── (6) daily overview: a completed CR is done, never late/pending ───────────

def test_daily_overview_never_surfaces_cr_completed(tmp_path):
    board = tmp_path / "b.json"
    board.write_text(json.dumps({"crs": [
        {"id": "CR-ZZXACA-20261002-1", "crState": "cr-completed", "title": "done"},
        {"id": "CR-ZZXACA-20261002-2", "crState": "cr-submitted", "title": "pending"},
    ]}))
    with patch.object(H, "__init__", lambda self, *a, **kw: None):
        h = H.__new__(H)
    from datetime import datetime, timezone
    with patch.object(server, "get_board_file", lambda team: board):
        items = h._collect_change_requests(SYNTH_TEAM, datetime(2026, 10, 2, tzinfo=timezone.utc))
    ids = [i["id"] for i in items]
    assert "CR-ZZXACA-20261002-2" in ids, "fixture sanity: pending CR must surface"
    assert "CR-ZZXACA-20261002-1" not in ids
