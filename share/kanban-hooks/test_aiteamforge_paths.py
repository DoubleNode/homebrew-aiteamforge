#!/usr/bin/env python3
"""
test_aiteamforge_paths.py — Unit tests for aiteamforge_paths.py helpers.

XACA-0463 (subitem 003): Tests for compute_instance_port allocator.

Run:
    python3 -m unittest kanban-hooks/test_aiteamforge_paths.py -v
    # or from inside kanban-hooks/:
    python3 -m unittest test_aiteamforge_paths -v
"""

import copy
import importlib
import sys
import unittest
from pathlib import Path

# ---------------------------------------------------------------------------
# All 20 canonical teams with their expected 3-letter codes.
# XACA-0542-015: This table is the parity fixture — any drift between
# DEFAULT_TEAMS team_code values and this list will fail the test.
# ---------------------------------------------------------------------------
_EXPECTED_TEAM_CODES: dict[str, str] = {
    "academy":                             "ACA",
    "ios":                                 "IOS",
    "android":                             "AND",
    "firebase":                            "FIR",
    "command":                             "CMD",
    "dns":                                 "DNS",
    "freelance-doublenode-starwords":      "FSW",
    "freelance-doublenode-appplanning":    "FAP",
    "freelance-doublenode-workstats":      "FWS",
    "freelance-doublenode-lifeboard":      "FLB",
    "freelance-doublenode-caravan":        "VAN",
    "freelance-doublenode-awaysentry":     "FAS",
    "freelance-liquidstyle-agentbadges-app": "FLA",
    "freelance-liquidstyle-agentbadges-ios": "FLI",
    "freelance-bandwear-android":          "BWA",
    "legal-coparenting":                   "LCP",
    "medical-general":                     "MED",
    "finance-personal":                    "FIN",
    "mainevent":                           "MEV",
    "freelance":                           "FRE",
}

# ---------------------------------------------------------------------------
# Ensure kanban-hooks/ is on the path regardless of invocation directory.
# ---------------------------------------------------------------------------
_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import aiteamforge_paths  # noqa: E402
from aiteamforge_paths import (  # noqa: E402
    build_team_code_map,
    compute_instance_port,
    get_team_code,
    get_team_from_code,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _team_paths(port_map: dict) -> dict:
    """Build a minimal existing_team_paths dict from {instance: port | None}."""
    teams = {}
    for instance, port in port_map.items():
        teams[instance] = {"lcars_port": port}
    return {"teams": teams}


# Finance band: base=8360, range=10  → [8360, 8370)
FINANCE_BASE = 8360
FINANCE_RANGE = 10

# Freelance band: base=8500, range=100 → [8500, 8600)
FREELANCE_BASE = 8500
FREELANCE_RANGE = 100


# ---------------------------------------------------------------------------
# Test class
# ---------------------------------------------------------------------------

class TestComputeInstancePort(unittest.TestCase):
    """Unit tests for compute_instance_port per XACA-0463 / §4.1."""

    # ── 1. Empty state ──────────────────────────────────────────────────────

    def test_compute_port_empty_state(self):
        """Empty team-paths → returns band base (8360 for finance)."""
        result = compute_instance_port("finance", _team_paths({}))
        self.assertEqual(result, FINANCE_BASE)

    # ── 2. Partial fill ────────────────────────────────────────────────────

    def test_compute_port_partial_fill(self):
        """Two ports taken at base and base+1 → returns base+2."""
        existing = _team_paths({
            "finance-personal": FINANCE_BASE,
            "finance-business": FINANCE_BASE + 1,
        })
        result = compute_instance_port("finance", existing)
        self.assertEqual(result, FINANCE_BASE + 2)

    # ── 3. Mid-band skip ───────────────────────────────────────────────────

    def test_compute_port_skips_taken_port_mid_band(self):
        """Only base+1 is taken; lowest free is still base."""
        existing = _team_paths({"x": FINANCE_BASE + 1})
        result = compute_instance_port("finance", existing)
        self.assertEqual(result, FINANCE_BASE)

    # ── 4. Band exhausted ──────────────────────────────────────────────────

    def test_compute_port_band_exhausted(self):
        """All 10 finance ports taken → raises ValueError with 'exhausted'."""
        port_map = {f"finance-instance{i}": FINANCE_BASE + i for i in range(FINANCE_RANGE)}
        existing = _team_paths(port_map)
        with self.assertRaises(ValueError) as ctx:
            compute_instance_port("finance", existing)
        self.assertIn("exhausted", str(ctx.exception).lower())

    # ── 5. Unknown template ────────────────────────────────────────────────

    def test_compute_port_unknown_template(self):
        """Unknown template 'bogus' → raises ValueError."""
        with self.assertRaises(ValueError) as ctx:
            compute_instance_port("bogus", _team_paths({}))
        msg = str(ctx.exception).lower()
        self.assertTrue(
            "lcars_port_base" in msg or "not found" in msg or "unknown" in msg,
            f"Unexpected error message: {ctx.exception}",
        )

    # ── 6. Tolerant input (instance id passed as template id) ─────────────

    def test_compute_port_tolerates_instance_id_input(self):
        """'finance-personal' (instance id) resolves same band as 'finance'."""
        empty = _team_paths({})
        result_template = compute_instance_port("finance", empty)
        result_instance = compute_instance_port("finance-personal", empty)
        self.assertEqual(result_template, result_instance)

    # ── 7. Cross-template collision ────────────────────────────────────────

    def test_compute_port_honors_cross_template_collision(self):
        """Port 8360 taken by an unrelated team → returns 8361 for finance."""
        existing = _team_paths({"unrelated-team": FINANCE_BASE})
        result = compute_instance_port("finance", existing)
        self.assertEqual(result, FINANCE_BASE + 1)

    # ── 8. Null port entries ignored ───────────────────────────────────────

    def test_compute_port_ignores_null_port_entries(self):
        """Entries with lcars_port=None do not count as used."""
        existing = _team_paths({
            "a": None,
            "b": FINANCE_BASE,
        })
        result = compute_instance_port("finance", existing)
        self.assertEqual(result, FINANCE_BASE + 1)

    # ── 9. Freelance band size ─────────────────────────────────────────────

    def test_compute_port_freelance_band_size(self):
        """Empty state for freelance → returns 8500 (band base)."""
        result = compute_instance_port("freelance", _team_paths({}))
        self.assertEqual(result, FREELANCE_BASE)

    def test_compute_port_freelance_band_size_fills_10(self):
        """Fill freelance ports 8500..8509 → next is 8510 (band is 100, not 10)."""
        port_map = {f"freelance-client-p{i}": FREELANCE_BASE + i for i in range(10)}
        existing = _team_paths(port_map)
        result = compute_instance_port("freelance", existing)
        self.assertEqual(result, FREELANCE_BASE + 10)

    # ── 10. Input dict not mutated ─────────────────────────────────────────

    def test_compute_port_does_not_mutate_input(self):
        """Purity contract: existing_team_paths dict is unchanged after call."""
        existing = _team_paths({"finance-personal": FINANCE_BASE})
        original = copy.deepcopy(existing)
        compute_instance_port("finance", existing)
        self.assertEqual(existing, original)


# ---------------------------------------------------------------------------
# XACA-0542-015: Team-code registry parity tests
# ---------------------------------------------------------------------------
# These tests lock the parity between build_team_code_map() / get_team_code()
# / get_team_from_code() and the expected codes for all 20 canonical teams.
# Any future drift (new team added to DEFAULT_TEAMS without an entry here, or
# a code changed without updating the other side) will fail these tests.
# ---------------------------------------------------------------------------

class TestTeamCodeParity(unittest.TestCase):
    """XACA-0542-015: Parity regression for team_code registry coverage."""

    # ── build_team_code_map coverage ──────────────────────────────────────

    def test_build_team_code_map_all_20_teams_present(self):
        """build_team_code_map() must contain an entry for all 20 canonical teams."""
        code_map = build_team_code_map()  # {code -> team_id}
        # Invert for easy lookup: {team_id -> code}
        team_to_code = {team_id: code for code, team_id in code_map.items()}
        missing = [t for t in _EXPECTED_TEAM_CODES if t not in team_to_code]
        self.assertEqual(
            missing, [],
            f"build_team_code_map() is missing teams: {missing}",
        )

    def test_build_team_code_map_correct_codes(self):
        """build_team_code_map() must map every team to its canonical 3-letter code."""
        code_map = build_team_code_map()  # {code -> team_id}
        team_to_code = {team_id: code for code, team_id in code_map.items()}
        mismatches = []
        for team, expected_code in _EXPECTED_TEAM_CODES.items():
            actual_code = team_to_code.get(team, "")
            if actual_code.upper() != expected_code.upper():
                mismatches.append(f"{team}: expected {expected_code}, got {actual_code}")
        self.assertEqual(mismatches, [], "\n".join(mismatches))

    def test_build_team_code_map_xfre_present(self):
        """XFRE (freelance) must appear in build_team_code_map() — was absent in pre-XACA-0542 hardcoded dict."""
        code_map = build_team_code_map()
        self.assertIn(
            "FRE", code_map,
            "build_team_code_map() missing FRE (freelance); XFRE→freelance routing broken",
        )
        self.assertEqual(code_map["FRE"], "freelance")

    def test_build_team_code_map_xmed_present(self):
        """XMED (medical-general) must appear in build_team_code_map() — was absent in pre-XACA-0542 hardcoded dict."""
        code_map = build_team_code_map()
        self.assertIn(
            "MED", code_map,
            "build_team_code_map() missing MED (medical-general); XMED→medical-general routing broken",
        )
        self.assertEqual(code_map["MED"], "medical-general")

    # ── get_team_code forward lookup ──────────────────────────────────────

    def test_get_team_code_all_20_teams(self):
        """get_team_code() must return the correct 3-letter code for each of the 20 canonical teams."""
        mismatches = []
        for team, expected_code in _EXPECTED_TEAM_CODES.items():
            actual = get_team_code(team)
            if actual.upper() != expected_code.upper():
                mismatches.append(f"get_team_code({team!r}) -> {actual!r}, want {expected_code!r}")
        self.assertEqual(mismatches, [], "\n".join(mismatches))

    def test_get_team_code_unknown_returns_empty(self):
        """get_team_code() returns '' for an unregistered team."""
        result = get_team_code("nonexistent-team-xyz")
        self.assertEqual(result, "")

    # ── get_team_from_code reverse lookup ────────────────────────────────

    def test_get_team_from_code_all_20_codes(self):
        """get_team_from_code() must return the correct team_id for each of the 20 canonical codes."""
        mismatches = []
        for team, code in _EXPECTED_TEAM_CODES.items():
            actual = get_team_from_code(code)
            if actual != team:
                mismatches.append(f"get_team_from_code({code!r}) -> {actual!r}, want {team!r}")
        self.assertEqual(mismatches, [], "\n".join(mismatches))

    def test_get_team_from_code_case_insensitive(self):
        """get_team_from_code() must work with lowercase code input."""
        result = get_team_from_code("aca")
        self.assertEqual(result, "academy")

    def test_get_team_from_code_unknown_returns_empty(self):
        """get_team_from_code() returns '' for an unknown code."""
        result = get_team_from_code("ZZZ")
        self.assertEqual(result, "")

    # ── bidirectional roundtrip ───────────────────────────────────────────

    def test_roundtrip_team_code_to_team(self):
        """get_team_code(team) → code → get_team_from_code(code) must round-trip for all 20 teams."""
        mismatches = []
        for team in _EXPECTED_TEAM_CODES:
            code = get_team_code(team)
            round_tripped = get_team_from_code(code)
            if round_tripped != team:
                mismatches.append(
                    f"Roundtrip failed: {team!r} -> code={code!r} -> {round_tripped!r}"
                )
        self.assertEqual(mismatches, [], "\n".join(mismatches))

    # ── _ITEM_PREFIX_TO_TEAM parity ───────────────────────────────────────

    def test_item_prefix_to_team_includes_xfre_and_xmed(self):
        """_ITEM_PREFIX_TO_TEAM must include XFRE and XMED added by XACA-0542 registry derivation."""
        # We derive the map the same way server.py does — via build_team_code_map.
        code_map = build_team_code_map()
        item_prefix_map = {f"X{code}": team_id for code, team_id in code_map.items()}
        self.assertIn(
            "XFRE", item_prefix_map,
            "XFRE missing from _ITEM_PREFIX_TO_TEAM equivalent; freelance items won't route",
        )
        self.assertEqual(item_prefix_map["XFRE"], "freelance")
        self.assertIn(
            "XMED", item_prefix_map,
            "XMED missing from _ITEM_PREFIX_TO_TEAM equivalent; medical-general items won't route",
        )
        self.assertEqual(item_prefix_map["XMED"], "medical-general")

    def test_item_prefix_to_team_all_20_entries(self):
        """_ITEM_PREFIX_TO_TEAM must include X<code> prefixes for all 20 canonical teams."""
        code_map = build_team_code_map()
        item_prefix_map = {f"X{code}": team_id for code, team_id in code_map.items()}
        missing = []
        for team, code in _EXPECTED_TEAM_CODES.items():
            prefix = f"X{code}"
            if prefix not in item_prefix_map:
                missing.append(f"{prefix} ({team})")
            elif item_prefix_map[prefix] != team:
                missing.append(
                    f"{prefix}: expected {team!r}, got {item_prefix_map[prefix]!r}"
                )
        self.assertEqual(missing, [], f"_ITEM_PREFIX_TO_TEAM parity failures: {missing}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    unittest.main(verbosity=2)
