"""Tests for XACA-0586-011: wrong-team apply gate requires acknowledgeWrongTeam,
not the generic acknowledgePreflightDeltas.

server.py handle_import_apply is not unit-testable in isolation (requires a live
HTTP socket and environment). The gate decision logic is factored here as a pure
helper that mirrors the exact coercion + gate path in the handler, covering the
flag-coercion shapes and the critical invariant: acknowledgePreflightDeltas alone
does NOT bypass a wrongTeam job; only acknowledgeWrongTeam does.
"""
from __future__ import annotations

import pytest


# ---------------------------------------------------------------------------
# Helpers mirroring server.py handle_import_apply XACA-0586-011 logic
# ---------------------------------------------------------------------------

def _coerce_bool_flag(raw) -> bool:
    """Mirrors the type-aware coercion used for acknowledge* flags in server.py.

    Accepts: True (bool), 1 (int), "true"/"yes"/"1" (case-insensitive strings).
    Everything else — including string "false" — coerces to False.
    """
    if isinstance(raw, bool):
        return raw
    if isinstance(raw, int):
        return raw == 1
    if isinstance(raw, str):
        return raw.strip().lower() in ('true', 'yes', '1')
    return False


def _apply_gate_decision(job: dict, body_json: dict) -> tuple[bool, str]:
    """Mirror the wrong-team gate + baseMatch gate decision from handle_import_apply.

    Returns (allowed: bool, reason: str).
    'allowed' True means the import is permitted to proceed past these two gates.
    'reason' is a short description of why it was blocked or permitted.

    This does NOT include the secrets gate — that is separate and beyond scope here.
    """
    acknowledge_preflight_deltas = _coerce_bool_flag(
        body_json.get('acknowledgePreflightDeltas', False)
    )
    acknowledge_wrong_team = _coerce_bool_flag(
        body_json.get('acknowledgeWrongTeam', False)
    )

    # XACA-0586-011: wrong-team gate must be checked before the generic baseMatch gate.
    if job.get('wrongTeam'):
        if not acknowledge_wrong_team:
            return False, 'wrongTeam_blocked'
        # operator override — fall through
        return True, 'wrongTeam_override'

    # Generic baseMatch gate (verifier FAIL / staleness).
    if not job.get('baseMatch'):
        if not acknowledge_preflight_deltas:
            return False, 'baseMatch_blocked'
        # operator override — fall through
        return True, 'preflight_override'

    return True, 'clean'


# ---------------------------------------------------------------------------
# Coercion tests (shared helper used by both flags)
# ---------------------------------------------------------------------------

class TestCoerceBoolFlag:
    def test_true_bool(self):
        assert _coerce_bool_flag(True) is True

    def test_false_bool(self):
        assert _coerce_bool_flag(False) is False

    def test_int_one(self):
        assert _coerce_bool_flag(1) is True

    def test_int_zero(self):
        assert _coerce_bool_flag(0) is False

    def test_string_true(self):
        assert _coerce_bool_flag("true") is True

    def test_string_yes(self):
        assert _coerce_bool_flag("YES") is True

    def test_string_one(self):
        assert _coerce_bool_flag("1") is True

    def test_string_false_is_rejected(self):
        # Critical: bool("false") == True in Python — coercion must reject it.
        assert _coerce_bool_flag("false") is False

    def test_none_is_rejected(self):
        assert _coerce_bool_flag(None) is False

    def test_other_type_is_rejected(self):
        assert _coerce_bool_flag(["true"]) is False


# ---------------------------------------------------------------------------
# Gate decision tests — FIX 1 core invariants
# ---------------------------------------------------------------------------

def _wrong_team_job() -> dict:
    """A job dict that represents a cross-team import (wrongTeam=True, baseMatch=False)."""
    return {
        'baseMatch': False,
        'wrongTeam': True,
        'verifierState': 'FAIL',
        'targetBase': 'academy',
        'sourceIdentity': {'team': 'finance', 'hostname': 'test-host'},
    }


def _stale_job() -> dict:
    """A job dict with an ordinary preflight FAIL (staleness, not wrong-team)."""
    return {
        'baseMatch': False,
        'wrongTeam': False,
        'verifierState': 'FAIL',
        'targetBase': 'finance',
        'sourceIdentity': {'team': 'finance', 'hostname': 'test-host'},
    }


def _clean_job() -> dict:
    """A job dict with no issues — passes both gates."""
    return {
        'baseMatch': True,
        'wrongTeam': False,
        'verifierState': 'PASS',
        'targetBase': 'finance',
        'sourceIdentity': {'team': 'finance', 'hostname': 'test-host'},
    }


class TestWrongTeamApplyGate:
    def test_wrong_team_blocked_with_no_flags(self):
        """Cross-team job with no override flags must be blocked."""
        allowed, reason = _apply_gate_decision(_wrong_team_job(), {})
        assert allowed is False
        assert reason == 'wrongTeam_blocked'

    def test_wrong_team_blocked_when_only_acknowledge_preflight_deltas(self):
        """CRITICAL: acknowledgePreflightDeltas alone must NOT bypass the wrong-team gate."""
        body = {'acknowledgePreflightDeltas': True}
        allowed, reason = _apply_gate_decision(_wrong_team_job(), body)
        assert allowed is False, (
            "acknowledgePreflightDeltas must not bypass a wrongTeam job — "
            "only acknowledgeWrongTeam may do so (XACA-0586-011)."
        )
        assert reason == 'wrongTeam_blocked'

    def test_wrong_team_allowed_when_acknowledge_wrong_team(self):
        """acknowledgeWrongTeam=true must allow a cross-team import to proceed."""
        body = {'acknowledgeWrongTeam': True}
        allowed, reason = _apply_gate_decision(_wrong_team_job(), body)
        assert allowed is True
        assert reason == 'wrongTeam_override'

    def test_wrong_team_allowed_when_both_flags_set(self):
        """Both flags set — still allowed (acknowledgeWrongTeam present)."""
        body = {'acknowledgeWrongTeam': True, 'acknowledgePreflightDeltas': True}
        allowed, reason = _apply_gate_decision(_wrong_team_job(), body)
        assert allowed is True
        assert reason == 'wrongTeam_override'

    def test_wrong_team_string_coercion_true(self):
        """acknowledgeWrongTeam accepts string 'true'."""
        body = {'acknowledgeWrongTeam': 'true'}
        allowed, _ = _apply_gate_decision(_wrong_team_job(), body)
        assert allowed is True

    def test_wrong_team_string_coercion_false_rejected(self):
        """acknowledgeWrongTeam string 'false' must be rejected (Python bool() trap)."""
        body = {'acknowledgeWrongTeam': 'false'}
        allowed, reason = _apply_gate_decision(_wrong_team_job(), body)
        assert allowed is False
        assert reason == 'wrongTeam_blocked'

    def test_clean_job_passes_without_flags(self):
        """A clean job (baseMatch=True, wrongTeam=False) passes both gates unconditionally."""
        allowed, reason = _apply_gate_decision(_clean_job(), {})
        assert allowed is True
        assert reason == 'clean'

    def test_stale_job_blocked_without_acknowledge_preflight(self):
        """Ordinary staleness job blocked without acknowledgePreflightDeltas."""
        allowed, reason = _apply_gate_decision(_stale_job(), {})
        assert allowed is False
        assert reason == 'baseMatch_blocked'

    def test_stale_job_allowed_with_acknowledge_preflight_deltas(self):
        """acknowledgePreflightDeltas bypasses the staleness gate for non-wrong-team jobs."""
        body = {'acknowledgePreflightDeltas': True}
        allowed, reason = _apply_gate_decision(_stale_job(), body)
        assert allowed is True
        assert reason == 'preflight_override'

    def test_stale_job_still_blocked_with_only_acknowledge_wrong_team(self):
        """acknowledgeWrongTeam alone does not bypass the baseMatch/staleness gate."""
        body = {'acknowledgeWrongTeam': True}
        allowed, reason = _apply_gate_decision(_stale_job(), body)
        assert allowed is False
        assert reason == 'baseMatch_blocked'

    def test_wrong_team_gate_checked_before_base_match_gate(self):
        """Wrong-team gate fires first; a wrong-team job blocked before baseMatch gate."""
        # If wrongTeam gate were skipped, the baseMatch gate would fire and give
        # 'baseMatch_blocked' — but since wrongTeam runs first we get 'wrongTeam_blocked'.
        body = {}
        allowed, reason = _apply_gate_decision(_wrong_team_job(), body)
        assert reason == 'wrongTeam_blocked'  # not 'baseMatch_blocked'
