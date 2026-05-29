"""Tests for XACA-0586-010: source_team generator assignment and wrong-team gate logic.

Server-side HTTP wiring is not unit-testable in isolation (the handler class requires
a live socket and environment variables), so the wrong-team comparison logic — which
amounts to: base(source_team) != base(target_team) — is covered here directly via the
_split_team_id function logic replicated in a focused unit test.  The server.py usage
of that comparison is verified by the existing integration smoke tests when run E2E.
"""
from __future__ import annotations

import json

from team_transfer.manifest import Manifest, new_manifest


# ---------------------------------------------------------------------------
# Generator: source_team is set from args.team after new_manifest()
# ---------------------------------------------------------------------------

def test_generator_sets_source_team(tmp_path):
    """Running the generator with --team X produces a manifest with source_team=X."""
    import subprocess
    import sys
    from pathlib import Path

    lcars_ui = Path(__file__).resolve().parents[2]
    out = tmp_path / "manifest.json"

    import os
    env = os.environ.copy()
    pp = str(lcars_ui)
    if env.get("PYTHONPATH"):
        pp = pp + ":" + env["PYTHONPATH"]
    env["PYTHONPATH"] = pp

    result = subprocess.run(
        [sys.executable, "-m", "team_transfer.generator",
         "--team", "finance", "--output", str(out), "--allow-untagged"],
        env=env, capture_output=True, text=True, timeout=120,
    )
    # Generator may exit 0 (no gaps) or 1 (untagged gaps) — both are normal.
    assert result.returncode in (0, 1), (
        f"Generator failed unexpectedly (exit {result.returncode}):\n"
        f"{result.stdout}\n{result.stderr}"
    )
    assert out.exists(), "Manifest file was not written"

    raw = json.loads(out.read_text())
    assert raw.get("source_team") == "finance", (
        f"Expected source_team='finance' in manifest, got {raw.get('source_team')!r}"
    )


# ---------------------------------------------------------------------------
# Wrong-team gate: base-comparison logic (mirrors server.py XACA-0586-010)
# ---------------------------------------------------------------------------

def _split_team_id(team_id: str):
    """Mirror of server.py's _split_team_id — returns (base, suffixes)."""
    if '-' not in team_id:
        return team_id, []
    parts = team_id.split('-')
    return parts[0], parts[1:]


def _wrong_team_gate(source_team: str, target_team: str):
    """Replicate the wrong-team check from server.py handle_import_upload.

    Returns (base_match, verifier_state) for the gate-only logic:
      - base_match False + verifier_state 'FAIL' when source base != target base
      - base_match True (no-op — whatever verifier said) when source is empty (legacy)
        or bases match
    """
    source_base = _split_team_id(source_team)[0] if source_team else ''
    target_base = _split_team_id(target_team)[0]
    base_match = True
    verifier_state = 'PASS'  # stand-in; gate only cares about changing it
    if source_base and source_base != target_base:
        base_match = False
        verifier_state = 'FAIL'
    return base_match, verifier_state


def test_wrong_team_same_base_is_allowed():
    """finance exported to finance — same base, no block."""
    match, state = _wrong_team_gate("finance", "finance")
    assert match is True
    assert state == 'PASS'


def test_wrong_team_scope_suffix_variant_is_allowed():
    """finance exported to finance-personal — same base, allow (scope suffix differs)."""
    match, state = _wrong_team_gate("finance", "finance-personal")
    assert match is True
    assert state == 'PASS'


def test_wrong_team_reverse_scope_suffix_is_allowed():
    """finance-personal exported to finance — same base, allow."""
    match, state = _wrong_team_gate("finance-personal", "finance")
    assert match is True
    assert state == 'PASS'


def test_wrong_team_differing_base_is_blocked():
    """finance exported to academy — different base, hard block."""
    match, state = _wrong_team_gate("finance", "academy")
    assert match is False
    assert state == 'FAIL'


def test_wrong_team_differing_base_with_suffix_is_blocked():
    """finance-personal exported to legal-coparenting — different base, hard block."""
    match, state = _wrong_team_gate("finance-personal", "legal-coparenting")
    assert match is False
    assert state == 'FAIL'


def test_wrong_team_empty_source_is_legacy_passthrough():
    """Empty source_team (pre-XACA-0586 manifest) — cannot enforce, do not block."""
    match, state = _wrong_team_gate("", "finance")
    assert match is True
    assert state == 'PASS'
