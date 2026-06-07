#!/usr/bin/env python3
"""Unit tests for kb-port-fix.py — XACA-0463 subitem 005."""

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

# ---------------------------------------------------------------------------
# Load kb-port-fix as a module (it lives alongside this test file).
# ---------------------------------------------------------------------------

_HERE = Path(__file__).resolve().parent
_SCRIPT = _HERE / "kb-port-fix.py"

spec = importlib.util.spec_from_file_location("kb_port_fix", _SCRIPT)
assert spec is not None
kpf = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(kpf)  # type: ignore[attr-defined]


# ---------------------------------------------------------------------------
# Helpers for building synthetic team-paths dicts
# ---------------------------------------------------------------------------

def _make_team_paths(**kwargs: dict) -> dict:
    """Build a minimal team-paths.json dict.

    Pass keyword args as instance_id -> {lcars_port, addedAt?, ...}.
    """
    return {"schema_version": 2, "teams": {k: v for k, v in kwargs.items()}}


def _entry(port, added_at=None):
    """Minimal team-paths entry."""
    e: dict = {"lcars_port": port}
    if added_at is not None:
        e["addedAt"] = added_at
    return e


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestDetectNoCollisions(unittest.TestCase):
    """Test 1: clean team-paths.json, no nulls → empty plan, needs_work=False."""

    def test_detect_no_collisions(self):
        data = _make_team_paths(
            academy=_entry(8200),
            ios=_entry(8260),
            android=_entry(8280),
        )
        plan = kpf._build_plan(data)
        self.assertFalse(plan["needs_work"])
        self.assertEqual(plan["collisions"], [])
        self.assertEqual(plan["null_ports"], [])


class TestDetectSingleCollision(unittest.TestCase):
    """Test 2: two instances on same port, both have addedAt → winner = earlier."""

    def test_detect_single_collision(self):
        data = _make_team_paths(
            **{
                "command": _entry(8234, added_at="2024-01-01T00:00:00Z"),
                "mainevent": _entry(8234, added_at="2025-06-01T00:00:00Z"),
            }
        )
        plan = kpf._build_plan(data)
        self.assertTrue(plan["needs_work"])
        self.assertEqual(len(plan["collisions"]), 1)
        group = plan["collisions"][0]
        self.assertEqual(group["port"], 8234)
        self.assertEqual(group["winner"], "command")   # earlier addedAt
        self.assertIn("mainevent", group["renumber"])


class TestDetectMultiCollisionFreelance(unittest.TestCase):
    """Test 3: 6 freelance instances on 8505 → 1 winner, 5 renumberers."""

    def _make_6_freelance(self):
        # Order in JSON dict is insertion order (Python 3.7+)
        return _make_team_paths(
            **{
                "freelance-doublenode-starwords":   _entry(8505, "2025-01-01T00:00:00Z"),
                "freelance-doublenode-appplanning": _entry(8505, "2025-02-01T00:00:00Z"),
                "freelance-doublenode-workstats":   _entry(8505, "2025-03-01T00:00:00Z"),
                "freelance-doublenode-lifeboard":   _entry(8505, "2025-04-01T00:00:00Z"),
                "freelance-doublenode-caravan":     _entry(8505, "2025-05-01T00:00:00Z"),
                "freelance-doublenode-awaysentry":  _entry(8505, "2025-06-01T00:00:00Z"),
            }
        )

    def test_detect_multi_collision_freelance(self):
        data = self._make_6_freelance()
        plan = kpf._build_plan(data)
        self.assertTrue(plan["needs_work"])
        self.assertEqual(len(plan["collisions"]), 1)
        group = plan["collisions"][0]
        self.assertEqual(group["port"], 8505)
        self.assertEqual(group["winner"], "freelance-doublenode-starwords")
        self.assertEqual(len(group["renumber"]), 5)

    def test_renumbers_have_distinct_ports_freelance(self):
        """With compute_instance_port, each renumbered entry gets a distinct port."""
        data = self._make_6_freelance()
        full_plan = kpf._compute_plan_with_new_ports(data)
        all_new_ports = [e["new_port"] for e in full_plan["collisions"][0]["renumber"]]
        self.assertEqual(len(all_new_ports), len(set(all_new_ports)),
                         "Renumbered entries must all have distinct ports")
        # All should be in freelance band [8500, 8600)
        for p in all_new_ports:
            self.assertGreaterEqual(p, 8500)
            self.assertLess(p, 8600)


class TestDetectNullPort(unittest.TestCase):
    """Test 4: finance-personal with lcars_port=None → plan assigns it in finance band."""

    def test_detect_null_port(self):
        data = _make_team_paths(**{"finance-personal": {"lcars_port": None}})
        plan = kpf._build_plan(data)
        self.assertTrue(plan["needs_work"])
        self.assertIn("finance-personal", plan["null_ports"])
        self.assertEqual(plan["collisions"], [])

    def test_null_port_gets_finance_band_port(self):
        data = _make_team_paths(**{"finance-personal": {"lcars_port": None}})
        full_plan = kpf._compute_plan_with_new_ports(data)
        null_entries = full_plan["null_ports"]
        self.assertEqual(len(null_entries), 1)
        entry = null_entries[0]
        self.assertEqual(entry["instance_id"], "finance-personal")
        # Finance band: [8360, 8370)
        self.assertGreaterEqual(entry["new_port"], 8360)
        self.assertLess(entry["new_port"], 8370)


class TestWinnerSelectionAddedAt(unittest.TestCase):
    """Test 5: earliest addedAt wins regardless of insertion order in dict."""

    def test_winner_selection_addedat(self):
        # Insert later-timestamp first, earlier-timestamp second
        data = _make_team_paths(
            **{
                "command": _entry(8234, added_at="2025-12-01T00:00:00Z"),  # LATER
                "mainevent": _entry(8234, added_at="2024-01-01T00:00:00Z"),  # EARLIER
            }
        )
        plan = kpf._build_plan(data)
        group = plan["collisions"][0]
        # mainevent has earlier timestamp → should be winner
        self.assertEqual(group["winner"], "mainevent")
        self.assertIn("command", group["renumber"])


class TestWinnerSelectionMissingAddedAt(unittest.TestCase):
    """Test 6: no entries have addedAt → alphabetical instance_id wins."""

    def test_winner_selection_missing_addedat_falls_back(self):
        data = _make_team_paths(
            **{
                "freelance-zzz-project": _entry(8505),
                "freelance-aaa-project": _entry(8505),
                "freelance-mmm-project": _entry(8505),
            }
        )
        plan = kpf._build_plan(data)
        group = plan["collisions"][0]
        # Alphabetically first = winner
        self.assertEqual(group["winner"], "freelance-aaa-project")


class TestWinnerSelectionPartialAddedAt(unittest.TestCase):
    """Test 7: entries WITH addedAt outrank entries WITHOUT."""

    def test_winner_selection_partial_addedat(self):
        data = _make_team_paths(
            **{
                "command": _entry(8234),              # no addedAt
                "mainevent": _entry(8234, added_at="2025-01-01T00:00:00Z"),  # has addedAt
            }
        )
        plan = kpf._build_plan(data)
        group = plan["collisions"][0]
        # mainevent has addedAt → outranks command which doesn't
        self.assertEqual(group["winner"], "mainevent")
        self.assertIn("command", group["renumber"])


class TestApplyDoesNotReuseRenumberedPorts(unittest.TestCase):
    """Test 8: 3-way collision — running-state allocation prevents port reuse."""

    def test_apply_does_not_reuse_renumbered_ports(self):
        # Three command instances on 8234 (command band: 8230–8239, range 10)
        # The winner keeps 8234; the other two must get distinct ports.
        # We place them all at 8234 so both renumber. The band starts at 8230,
        # so port 8230 is free → first renumberer gets 8230, second gets 8231.
        data = _make_team_paths(
            **{
                "command": _entry(8234, added_at="2024-01-01T00:00:00Z"),   # winner
                "command-backup1": _entry(8234, added_at="2024-06-01T00:00:00Z"),
                "command-backup2": _entry(8234, added_at="2025-01-01T00:00:00Z"),
            }
        )
        full_plan = kpf._compute_plan_with_new_ports(data)
        self.assertEqual(len(full_plan["collisions"]), 1)
        group = full_plan["collisions"][0]
        self.assertEqual(group["winner"], "command")
        renumber_ports = [e["new_port"] for e in group["renumber"]]
        # All distinct
        self.assertEqual(len(renumber_ports), len(set(renumber_ports)),
                         "Each renumbered entry must get a distinct port")
        # None is 8234 (winner's port)
        self.assertNotIn(8234, renumber_ports)


class TestApplyAtomicWrite(unittest.TestCase):
    """Test 9: patch os.replace to raise; assert original unchanged and tmp cleaned up."""

    def test_apply_atomic_write(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            target = Path(tmpdir) / "team-paths.json"
            original_data = {"schema_version": 2, "teams": {"academy": {"lcars_port": 8200}}}
            with target.open("w") as f:
                json.dump(original_data, f)

            original_mtime = target.stat().st_mtime

            # Find any tmp file that would be created
            created_tmp: list[str] = []
            original_mkstemp = tempfile.mkstemp

            def tracking_mkstemp(*args, **kwargs):
                fd, path = original_mkstemp(*args, **kwargs)
                created_tmp.append(path)
                return fd, path

            # Patch os.replace to raise after mkstemp
            with patch("tempfile.mkstemp", side_effect=tracking_mkstemp):
                with patch("os.replace", side_effect=OSError("simulated failure")):
                    with self.assertRaises(OSError):
                        kpf._atomic_write({"schema_version": 2, "teams": {}}, target)

            # Original file must be unchanged
            current_mtime = target.stat().st_mtime
            self.assertEqual(original_mtime, current_mtime,
                              "Original file must not be modified on atomic write failure")

            # Tmp file(s) must have been cleaned up
            for tmp in created_tmp:
                self.assertFalse(os.path.exists(tmp),
                                 f"Tmp file {tmp} should have been removed on failure")


class TestApplyCreatesBackup(unittest.TestCase):
    """Test 10: happy-path apply creates a .bak-xaca0463-* file."""

    def test_apply_creates_backup(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "team-paths.json"
            # Put a collision in so apply has work to do
            data = _make_team_paths(
                **{
                    "command": _entry(8234, added_at="2024-01-01T00:00:00Z"),
                    "mainevent": _entry(8234, added_at="2025-01-01T00:00:00Z"),
                }
            )
            with config_path.open("w") as f:
                json.dump(data, f)

            # Patch AITEAMFORGE_CONFIG to point at our tmp file
            with patch.dict(os.environ, {"AITEAMFORGE_CONFIG": str(config_path)}):
                import argparse
                args = argparse.Namespace(apply=True, yes=True, json=False)
                ret = kpf.cmd_apply(args)

            self.assertEqual(ret, 0, "cmd_apply should return 0 on success")

            # Find backup files
            bak_files = list(config_path.parent.glob(
                config_path.name + kpf.BACKUP_SUFFIX_PREFIX + "*"
            ))
            self.assertTrue(len(bak_files) >= 1, "A backup file must be created")


class TestExitCodes(unittest.TestCase):
    """Test 11: detect with no work → exit 0; detect with work → exit 2; apply success → exit 0."""

    def test_detect_no_work_exit_0(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "team-paths.json"
            data = _make_team_paths(academy=_entry(8200))
            with config_path.open("w") as f:
                json.dump(data, f)
            with patch.dict(os.environ, {"AITEAMFORGE_CONFIG": str(config_path)}):
                import argparse
                args = argparse.Namespace(apply=False, yes=False, json=False)
                ret = kpf.cmd_detect(args)
            self.assertEqual(ret, 0)

    def test_detect_with_work_exit_2(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "team-paths.json"
            data = _make_team_paths(
                **{
                    "command": _entry(8234, added_at="2024-01-01T00:00:00Z"),
                    "mainevent": _entry(8234, added_at="2025-01-01T00:00:00Z"),
                }
            )
            with config_path.open("w") as f:
                json.dump(data, f)
            with patch.dict(os.environ, {"AITEAMFORGE_CONFIG": str(config_path)}):
                import argparse
                args = argparse.Namespace(apply=False, yes=False, json=False)
                ret = kpf.cmd_detect(args)
            self.assertEqual(ret, 2)

    def test_apply_success_exit_0(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "team-paths.json"
            data = _make_team_paths(
                **{
                    "command": _entry(8234, added_at="2024-01-01T00:00:00Z"),
                    "mainevent": _entry(8234, added_at="2025-01-01T00:00:00Z"),
                }
            )
            with config_path.open("w") as f:
                json.dump(data, f)
            with patch.dict(os.environ, {"AITEAMFORGE_CONFIG": str(config_path)}):
                import argparse
                args = argparse.Namespace(apply=True, yes=True, json=False)
                ret = kpf.cmd_apply(args)
            self.assertEqual(ret, 0)


class TestCheckMode(unittest.TestCase):
    """Test 12: --check flag exits 0 when clean, 1 when collisions or null ports found."""

    def test_check_clean_exits_0(self):
        """check mode returns 0 when all ports are unique and non-null."""
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "team-paths.json"
            data = _make_team_paths(
                academy=_entry(8200),
                ios=_entry(8260),
                android=_entry(8280),
            )
            with config_path.open("w") as f:
                json.dump(data, f)
            with patch.dict(os.environ, {"AITEAMFORGE_CONFIG": str(config_path)}):
                import argparse
                args = argparse.Namespace(check=True, apply=False, yes=False, json=False)
                ret = kpf.cmd_check(args)
            self.assertEqual(ret, 0, "cmd_check should return 0 when no issues found")

    def test_check_collision_exits_1(self):
        """check mode returns 1 when a port collision is present."""
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "team-paths.json"
            data = _make_team_paths(
                **{
                    "command": _entry(8234, added_at="2024-01-01T00:00:00Z"),
                    "mainevent": _entry(8234, added_at="2025-06-01T00:00:00Z"),
                }
            )
            with config_path.open("w") as f:
                json.dump(data, f)
            with patch.dict(os.environ, {"AITEAMFORGE_CONFIG": str(config_path)}):
                import argparse
                args = argparse.Namespace(check=True, apply=False, yes=False, json=False)
                ret = kpf.cmd_check(args)
            self.assertEqual(ret, 1, "cmd_check should return 1 when a collision is present")

    def test_check_null_port_exits_1(self):
        """check mode returns 1 when a null port is present."""
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "team-paths.json"
            data = _make_team_paths(**{"finance-personal": {"lcars_port": None}})
            with config_path.open("w") as f:
                json.dump(data, f)
            with patch.dict(os.environ, {"AITEAMFORGE_CONFIG": str(config_path)}):
                import argparse
                args = argparse.Namespace(check=True, apply=False, yes=False, json=False)
                ret = kpf.cmd_check(args)
            self.assertEqual(ret, 1, "cmd_check should return 1 when a null port is present")

    def test_check_mode_dispatched_from_main(self):
        """main() dispatches to cmd_check when --check is parsed."""
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "team-paths.json"
            data = _make_team_paths(academy=_entry(8200))
            with config_path.open("w") as f:
                json.dump(data, f)
            with patch.dict(os.environ, {"AITEAMFORGE_CONFIG": str(config_path)}):
                import sys as _sys
                old_argv = _sys.argv
                _sys.argv = ["kb-port-fix", "--check"]
                try:
                    ret = kpf.main()
                finally:
                    _sys.argv = old_argv
            self.assertEqual(ret, 0, "main() with --check on clean config should return 0")


class TestMalformedRootGuard(unittest.TestCase):
    """XACA-0463-013: defend against non-dict root or non-dict ``teams`` value."""

    def test_build_port_map_handles_null_root(self):
        self.assertEqual(kpf._build_port_map(None), {})

    def test_build_port_map_handles_array_root(self):
        self.assertEqual(kpf._build_port_map([]), {})

    def test_build_port_map_handles_null_teams(self):
        self.assertEqual(kpf._build_port_map({"teams": None}), {})

    def test_build_port_map_handles_array_teams(self):
        self.assertEqual(kpf._build_port_map({"teams": []}), {})

    def test_build_port_map_skips_non_dict_entry(self):
        # "teams.foo": "not-a-dict" must not crash on entry.get(...)
        data = {"teams": {"foo": "not-a-dict", "bar": _entry(8200)}}
        self.assertEqual(kpf._build_port_map(data), {8200: ["bar"]})

    def test_collect_null_ports_handles_null_root(self):
        self.assertEqual(kpf._collect_null_ports(None), [])

    def test_collect_null_ports_handles_non_dict_entry(self):
        data = {"teams": {"foo": "not-a-dict", "bar": {"lcars_port": None}}}
        self.assertEqual(kpf._collect_null_ports(data), ["bar"])

    def test_build_plan_handles_null_root(self):
        plan = kpf._build_plan(None)
        self.assertFalse(plan["needs_work"])
        self.assertEqual(plan["collisions"], [])
        self.assertEqual(plan["null_ports"], [])

    def test_load_team_paths_normalises_null_root(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "team-paths.json"
            config_path.write_text("null\n")
            result = kpf._load_team_paths(config_path)
            self.assertEqual(result, {"teams": {}})

    def test_load_team_paths_normalises_array_root(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "team-paths.json"
            config_path.write_text("[]\n")
            result = kpf._load_team_paths(config_path)
            self.assertEqual(result, {"teams": {}})


class TestContractViolatingKeysSkipped(unittest.TestCase):
    """XACA-0643: bare parameterized-template keys must never get a port."""

    def test_predicate(self):
        self.assertTrue(kpf._is_contract_violating_key("medical"))
        self.assertTrue(kpf._is_contract_violating_key("freelance"))
        self.assertFalse(kpf._is_contract_violating_key("medical-general"))
        self.assertFalse(kpf._is_contract_violating_key("freelance-acme-app"))
        self.assertFalse(kpf._is_contract_violating_key("academy"))
        self.assertFalse(kpf._is_contract_violating_key("mainevent"))

    def test_null_port_collection_skips_bare_keys(self):
        data = _make_team_paths(
            **{
                "academy": _entry(8230),
                "medical": _entry(None),          # contract violation — skip
                "freelance": _entry(None),        # contract violation — skip
                "medical-general": _entry(None),  # real instance — collect
            }
        )
        nulls = kpf._collect_null_ports(data)
        self.assertEqual(nulls, ["medical-general"])

    def test_port_map_skips_bare_keys(self):
        data = _make_team_paths(
            **{
                "medical": _entry(8340),
                "medical-general": _entry(8340),
            }
        )
        port_map = kpf._build_port_map(data)
        # Only the real instance should appear; bare "medical" is skipped, so no
        # phantom collision is reported on 8340.
        self.assertEqual(port_map.get(8340), ["medical-general"])

    def test_plan_does_not_allocate_for_bare_keys(self):
        data = _make_team_paths(
            **{
                "academy": _entry(8230),
                "medical": _entry(None),
            }
        )
        plan = kpf._build_plan(data)
        self.assertEqual(plan["null_ports"], [])
        self.assertFalse(plan["needs_work"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
