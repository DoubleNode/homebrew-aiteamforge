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
# Ensure kanban-hooks/ is on the path regardless of invocation directory.
# ---------------------------------------------------------------------------
_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import aiteamforge_paths  # noqa: E402
from aiteamforge_paths import compute_instance_port  # noqa: E402

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
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    unittest.main(verbosity=2)
