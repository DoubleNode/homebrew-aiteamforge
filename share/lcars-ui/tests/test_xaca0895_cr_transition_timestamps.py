"""XACA-0895-018 — LCARS EDIT STATE must stamp the state's entry timestamp.

THE DEFECT: server.py's handle_cr_transition wrote only crState / updatedAt /
lastUpdated plus allow-listed FLAT fields. It never wrote timestamps.*. Once
XACA-0895 exposed cr-published in _CR_VALID_STATES, an operator transitioning
through the UI produced a record with crState='cr-published' and no
timestamps.cr_published_at, which:

  1. hard-FAILs cr-schema-validator's check7 for the WHOLE board,
  2. leaves cr-lifecycle-monitor's Auto 1 with no age basis, so it silently
     never reminds, and
  3. drops the cr-published->cr-submitted stateDurations leg and the STAGE AGE
     anchor.

Only (1) is loud. (2) and (3) are silent, which is why this test asserts on the
resulting BOARD RECORD rather than on the filter string: a string-equality test
would pass against any filter that merely mentions the field, including one that
never actually writes it.

Approach: build the real jq filter via HANDLER._cr_build_state_jq() and execute
it with the real jq binary against a fixture board, exactly as the handler's
shell script does. Then feed the result to the real cr-schema-validator. No
HTTP server, no board I/O against a live board, no network.
"""

import importlib.util
import json
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SERVER_PY = REPO_ROOT / "lcars-ui" / "server.py"
VALIDATOR_PY = REPO_ROOT / "scripts" / "cr-schema-validator.py"

TS = "2026-08-07T12:00:00Z"

pytestmark = pytest.mark.skipif(
    shutil.which("jq") is None, reason="jq not available on PATH"
)


def _load_handler_class():
    """Import server.py and return the request-handler class that owns the CR maps.

    server.py is not an importable package module (hyphenated siblings, executes
    on import), so we load it by path and locate the class by capability rather
    than by name — the class name is not the thing under test.
    """
    spec = importlib.util.spec_from_file_location("lcars_server", SERVER_PY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    for obj in vars(mod).values():
        if isinstance(obj, type) and hasattr(obj, "_cr_build_state_jq"):
            return obj
    raise AssertionError(
        "No class exposing _cr_build_state_jq found in server.py — the helper "
        "handle_cr_transition builds its crState jq filter with is missing."
    )


@pytest.fixture(scope="module")
def handler():
    return _load_handler_class()


def _cr(state="cr-drafted", timestamps=None, cr_id="CR-XACA-20260807-1"):
    return {
        "id": cr_id,
        "crState": state,
        "type": "major",
        "platform": "academy",
        "itemIds": [],
        "createdAt": "2026-08-01T00:00:00Z",
        "updatedAt": "2026-08-01T00:00:00Z",
        "cr_confluence_url": "https://example.atlassian.net/wiki/x",
        "timestamps": timestamps if timestamps is not None else {},
    }


def _apply(handler, target_state, cr, tmp_path):
    """Run the handler's real jq filter over a one-CR board; return the new CR."""
    board = {"crs": [cr], "lastUpdated": "2026-08-01T00:00:00Z", "nextCrSeq": 2}
    board_file = tmp_path / "academy-board.json"
    board_file.write_text(json.dumps(board), encoding="utf-8")

    jq_filter = handler._cr_build_state_jq(target_state)
    proc = subprocess.run(
        [
            "jq", jq_filter,
            "--argjson", "cidx", "0",
            "--arg", "state", target_state,
            "--arg", "ts", TS,
            str(board_file),
        ],
        capture_output=True, text=True, timeout=30,
    )
    assert proc.returncode == 0, (
        f"jq rejected the handler's filter for {target_state!r}.\n"
        f"filter: {jq_filter}\nstderr: {proc.stderr}"
    )
    return json.loads(proc.stdout)["crs"][0]


# ── The core defect ──────────────────────────────────────────────────────────

def test_transition_to_cr_published_stamps_cr_published_at(handler, tmp_path):
    """The exact operator flow from the subitem: EDIT STATE -> cr-published."""
    result = _apply(handler, "cr-published", _cr(state="cr-drafted"), tmp_path)

    assert result["crState"] == "cr-published"
    assert result["timestamps"].get("cr_published_at") == TS, (
        "handle_cr_transition must stamp timestamps.cr_published_at. Without it "
        "the record hard-FAILs cr-schema-validator check7 and Auto 1 silently "
        f"never reminds. Got timestamps={result['timestamps']!r}"
    )


def _check7_errors(board_dict):
    """Run the REAL cr-schema-validator over a board; return only check7 errors."""
    spec = importlib.util.spec_from_file_location("cr_schema_validator", VALIDATOR_PY)
    validator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(validator)

    schema_path = REPO_ROOT / "homebrew-tap" / "share" / "templates" / "kanban" / "cr-schema.json"
    if not schema_path.exists():
        pytest.skip(f"cr-schema.json not available at {schema_path}")
    schema = json.loads(schema_path.read_text(encoding="utf-8"))

    errors = validator.validate_board(board_dict, schema, "<test-board>", verbose=False)
    return [e for e in errors if "check7" in e]


def test_published_record_from_ui_passes_real_check7(handler, tmp_path):
    """End-to-end: the produced record must satisfy the REAL validator.

    This is the assertion that pins the reported consequence. It calls
    cr-schema-validator's own entry point rather than re-implementing check7.
    """
    result = _apply(handler, "cr-published", _cr(state="cr-drafted"), tmp_path)
    board = {"crs": [result], "nextCrSeq": 2}

    assert _check7_errors(board) == [], (
        "check7 must not fire for a UI-produced cr-published record: "
        f"{_check7_errors(board)}"
    )


def test_check7_negative_control_still_catches_a_missing_anchor(handler):
    """Negative control: prove check7 is actually capable of failing here.

    Without this, the assertion above could be green simply because check7 never
    fires on this fixture shape — a vacuous pass. This feeds check7 the exact
    record the UNFIXED handler produced (crState set, no anchor) and requires a
    failure.
    """
    broken = _cr(state="cr-published", timestamps={})  # pre-fix output shape
    errs = _check7_errors({"crs": [broken], "nextCrSeq": 2})
    assert errs, (
        "check7 did not fire on a cr-published CR with no cr_published_at. The "
        "positive test above is therefore vacuous — investigate the validator."
    )


# ── Write-once semantics (no retroactive backfill, no silent overwrite) ──────

def test_existing_timestamp_is_not_overwritten_on_a_backward_move(handler, tmp_path):
    """This endpoint has no rank guard, so backward moves are reachable.

    Overwriting would destroy the original submit time and corrupt every
    duration metric anchored on it.
    """
    original = "2026-08-02T09:30:00Z"
    cr = _cr(state="cr-approved", timestamps={
        "cr_submitted_at": original,
        "cr_approved_at": "2026-08-03T09:30:00Z",
    })
    result = _apply(handler, "cr-submitted", cr, tmp_path)

    assert result["timestamps"]["cr_submitted_at"] == original, (
        "A backward transition must preserve the original entry timestamp."
    )
    assert result["crState"] == "cr-submitted"


def test_empty_string_timestamp_is_treated_as_absent_and_filled(handler, tmp_path):
    """jq's `//` falls through on null/false but NOT on "" — hence the explicit test."""
    cr = _cr(state="cr-drafted", timestamps={"cr_published_at": ""})
    result = _apply(handler, "cr-published", cr, tmp_path)
    assert result["timestamps"]["cr_published_at"] == TS


def test_missing_timestamps_object_is_created(handler, tmp_path):
    cr = _cr(state="cr-drafted")
    del cr["timestamps"]
    result = _apply(handler, "cr-published", cr, tmp_path)
    assert result["timestamps"]["cr_published_at"] == TS


def test_revert_then_republish_restamps(handler, tmp_path):
    """kb-cr revert strips the field first, so re-entry must re-stamp."""
    cr = _cr(state="cr-drafted", timestamps={})  # post-revert shape
    result = _apply(handler, "cr-published", cr, tmp_path)
    assert result["timestamps"]["cr_published_at"] == TS


# ── The general mechanism, not a cr-published special case ───────────────────

@pytest.mark.parametrize("state,field", [
    ("cr-published",       "cr_published_at"),
    ("cr-submitted",       "cr_submitted_at"),
    ("cr-rejected",        "cr_rejected_at"),
    ("cr-held",            "cr_held_at"),
    ("cr-approved",        "cr_approved_at"),
    ("implementing",       "cr_started_dev_at"),
    ("deployed-dev",       "cr_deployed_dev_at"),
    ("deployed-prod",      "cr_deployed_prod_at"),
    ("emergency-deployed", "cr_emergency_deployed_at"),
])
def test_every_mapped_state_stamps_its_anchor(handler, state, field, tmp_path):
    result = _apply(handler, state, _cr(state="cr-drafted"), tmp_path)
    assert result["timestamps"].get(field) == TS, (
        f"{state} must stamp timestamps.{field}; the fix is a map, not a "
        f"cr-published special case. Got {result['timestamps']!r}"
    )


def test_states_without_a_canonical_anchor_stamp_nothing(handler, tmp_path):
    """cr-drafted is anchored by cr_created_at at creation; cr-closed has no field."""
    for state in ("cr-drafted", "cr-closed"):
        result = _apply(handler, state, _cr(state="cr-submitted"), tmp_path)
        assert result["timestamps"] == {}, (
            f"{state} owns no entry timestamp and must not invent one. "
            f"Got {result['timestamps']!r}"
        )
        assert result["crState"] == state


def test_map_covers_every_valid_state_except_the_two_documented_omissions(handler):
    """Guards against a new state being added to _CR_VALID_STATES un-mapped.

    That is exactly how cr-published acquired this defect.
    """
    expected_unmapped = {"cr-drafted", "cr-closed"}
    unmapped = set(handler._CR_VALID_STATES) - set(handler._CR_STATE_ENTRY_TIMESTAMP)
    assert unmapped == expected_unmapped, (
        f"States in _CR_VALID_STATES with no entry timestamp: {sorted(unmapped)}. "
        f"Only {sorted(expected_unmapped)} may be unmapped. A new lifecycle state "
        f"must be added to _CR_STATE_ENTRY_TIMESTAMP or explicitly excused here."
    )


def test_state_and_updated_fields_still_written(handler, tmp_path):
    """Regression: the original three writes must survive the refactor."""
    board = {"crs": [_cr()], "lastUpdated": "old"}
    board_file = tmp_path / "b.json"
    board_file.write_text(json.dumps(board), encoding="utf-8")
    proc = subprocess.run(
        ["jq", handler._cr_build_state_jq("cr-published"),
         "--argjson", "cidx", "0", "--arg", "state", "cr-published",
         "--arg", "ts", TS, str(board_file)],
        capture_output=True, text=True, timeout=30,
    )
    assert proc.returncode == 0, proc.stderr
    out = json.loads(proc.stdout)
    assert out["crs"][0]["crState"] == "cr-published"
    assert out["crs"][0]["updatedAt"] == TS
    assert out["lastUpdated"] == TS
