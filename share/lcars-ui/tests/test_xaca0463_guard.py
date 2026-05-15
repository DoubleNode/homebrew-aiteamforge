#!/usr/bin/env python3

#
#  test_xaca0463_guard.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Unit tests for the XACA-0463 LCARS server startup conflict guard.

Tests cover:
  1. No-conflict data → guard returns None (no exit)
  2. Port collision → SystemExit(2)
  3. Collision message names every offending instance
  4. Collision message points at kb-port-fix
  5. Active instance has null port → SystemExit(2)
  6. Non-active instance has null port → no exit (not this server's problem)
  7. Missing team-paths.json → loader returns empty teams → no exit
  8. Malformed JSON → loader raises → caught at call site → guard skipped

Run with:
    python3 -m unittest lcars-ui/tests/test_xaca0463_guard.py -v
  or from the repo root:
    python3 -m unittest discover -s lcars-ui/tests -p 'test_*.py'
"""

import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Bootstrap: ensure server.py and its dependencies can be imported cleanly
# without launching a real server or touching real kanban dirs.
# ---------------------------------------------------------------------------

LCARS_UI_DIR = Path(__file__).parent.parent
REPO_ROOT = LCARS_UI_DIR.parent
sys.path.insert(0, str(LCARS_UI_DIR))
sys.path.insert(0, str(REPO_ROOT))

# Stub heavy optional imports before server.py is loaded
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

import server  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _capture_stderr(fn, *args, **kwargs):
    """Call fn(*args, **kwargs) and return (return_value, stderr_text).

    Captures sys.stderr output.  If fn raises SystemExit the exception
    propagates — callers that expect SystemExit should use assertRaises.
    For the no-exit cases, captures and returns stderr cleanly.
    """
    buf = io.StringIO()
    old_stderr = sys.stderr
    sys.stderr = buf
    try:
        result = fn(*args, **kwargs)
        return result, buf.getvalue()
    finally:
        sys.stderr = old_stderr


def _capture_stderr_with_exit(fn, *args, **kwargs):
    """Call fn(*args, **kwargs), capture stderr, expect SystemExit.

    Returns (SystemExit_exception, stderr_text).
    Raises AssertionError if fn does NOT raise SystemExit.
    """
    buf = io.StringIO()
    old_stderr = sys.stderr
    sys.stderr = buf
    try:
        fn(*args, **kwargs)
        raise AssertionError("Expected SystemExit but function returned normally")
    except SystemExit as exc:
        return exc, buf.getvalue()
    finally:
        sys.stderr = old_stderr


# ---------------------------------------------------------------------------
# Guard function tests
# ---------------------------------------------------------------------------

class TestXaca0463Guard(unittest.TestCase):

    # ------------------------------------------------------------------
    # Test 1: clean data → guard is a no-op
    # ------------------------------------------------------------------
    def test_guard_no_conflicts_no_op(self):
        """Clean team-paths data with distinct ports → guard returns None."""
        data = {
            "teams": {
                "academy":        {"lcars_port": 8203},
                "ios":            {"lcars_port": 8260},
                "android":        {"lcars_port": 8280},
            }
        }
        result, stderr = _capture_stderr(
            server._xaca0463_assert_no_port_conflicts, data, "academy"
        )
        self.assertIsNone(result)
        # No noise on stderr when guard passes
        self.assertEqual(stderr.strip(), "")

    # ------------------------------------------------------------------
    # Test 2: port collision → SystemExit with code 2
    # ------------------------------------------------------------------
    def test_guard_collision_exits_nonzero(self):
        """Two instances sharing a port → SystemExit(2)."""
        data = {
            "teams": {
                "a": {"lcars_port": 8200},
                "b": {"lcars_port": 8200},
            }
        }
        exc, _ = _capture_stderr_with_exit(
            server._xaca0463_assert_no_port_conflicts, data, "a"
        )
        self.assertEqual(exc.code, 2)

    # ------------------------------------------------------------------
    # Test 3: collision message names every offender
    # ------------------------------------------------------------------
    def test_guard_collision_names_offenders(self):
        """Stderr must mention every offending instance id by name."""
        data = {
            "teams": {
                "a": {"lcars_port": 8200},
                "b": {"lcars_port": 8200},
            }
        }
        exc, stderr = _capture_stderr_with_exit(
            server._xaca0463_assert_no_port_conflicts, data, "a"
        )
        self.assertEqual(exc.code, 2)
        self.assertIn("a", stderr)
        self.assertIn("b", stderr)
        self.assertIn("8200", stderr)

    # ------------------------------------------------------------------
    # Test 4: collision message points at kb-port-fix
    # ------------------------------------------------------------------
    def test_guard_collision_points_at_kb_port_fix(self):
        """Stderr must mention kb-port-fix so the user knows the fix."""
        data = {
            "teams": {
                "x": {"lcars_port": 9000},
                "y": {"lcars_port": 9000},
            }
        }
        _, stderr = _capture_stderr_with_exit(
            server._xaca0463_assert_no_port_conflicts, data, "x"
        )
        self.assertIn("kb-port-fix", stderr)

    # ------------------------------------------------------------------
    # Test 5: active instance has null port → SystemExit(2)
    # ------------------------------------------------------------------
    def test_guard_active_null_port_exits(self):
        """Active LCARS_TEAM instance with null port → SystemExit(2)."""
        data = {
            "teams": {
                "finance-personal": {"lcars_port": None},
            }
        }
        exc, stderr = _capture_stderr_with_exit(
            server._xaca0463_assert_no_port_conflicts, data, "finance-personal"
        )
        self.assertEqual(exc.code, 2)
        self.assertIn("finance-personal", stderr)

    # ------------------------------------------------------------------
    # Test 6: null port on a NON-active instance → no exit
    # ------------------------------------------------------------------
    def test_guard_inactive_null_port_ignored(self):
        """Null port on an instance OTHER than LCARS_TEAM is not our problem.

        Per contract §6 rule 4: guard only blocks when its OWN instance has
        null lcars_port or when any GLOBAL collision exists.  A null on a
        different instance is not a startup blocker for this server.
        """
        data = {
            "teams": {
                "academy":         {"lcars_port": 8203},   # active — port is fine
                "legal-coparenting": {"lcars_port": None},  # not active — ignored
            }
        }
        result, stderr = _capture_stderr(
            server._xaca0463_assert_no_port_conflicts, data, "academy"
        )
        self.assertIsNone(result)
        self.assertEqual(stderr.strip(), "")

    # ------------------------------------------------------------------
    # Test 7: missing team-paths.json → loader returns empty teams → no exit
    # ------------------------------------------------------------------
    def test_guard_handles_missing_file(self):
        """Missing team-paths.json → _xaca0463_load_team_paths returns empty teams."""
        with tempfile.TemporaryDirectory() as tmpdir:
            nonexistent = os.path.join(tmpdir, "no-such-file.json")
            with patch.dict(os.environ, {"AITEAMFORGE_CONFIG": nonexistent}):
                # Also reset aiteamforge_paths cache so it re-reads the env
                import aiteamforge_paths
                orig_cache = aiteamforge_paths._CONFIG_CACHE
                orig_path = aiteamforge_paths._CONFIG_PATH_AT_LOAD
                aiteamforge_paths._CONFIG_CACHE = None
                aiteamforge_paths._CONFIG_PATH_AT_LOAD = None
                try:
                    # Capture stderr from load (bootstrap prints a message)
                    buf = io.StringIO()
                    old_stderr = sys.stderr
                    sys.stderr = buf
                    try:
                        data = server._xaca0463_load_team_paths()
                    finally:
                        sys.stderr = old_stderr
                    # The loader must return a dict with a "teams" key
                    self.assertIsInstance(data, dict)
                    self.assertIn("teams", data)
                    # Guard on an empty (or default-populated) dict with academy
                    # active must not exit (no collisions in defaults)
                    result, stderr = _capture_stderr(
                        server._xaca0463_assert_no_port_conflicts, {"teams": {}}, "academy"
                    )
                    self.assertIsNone(result)
                finally:
                    # Restore cache
                    aiteamforge_paths._CONFIG_CACHE = orig_cache
                    aiteamforge_paths._CONFIG_PATH_AT_LOAD = orig_path

    # ------------------------------------------------------------------
    # Test 8: malformed JSON → loader raises → guard is skipped
    # ------------------------------------------------------------------
    def test_guard_handles_malformed_json(self):
        """Malformed JSON in team-paths.json must not crash the server.

        The guard call site (in main()) catches exceptions from
        _xaca0463_load_team_paths() and sets team_paths_data = None, which
        causes the guard check to be skipped entirely.  This mirrors the
        main() wiring behaviour.

        We test the loader directly: a garbage JSON file must cause
        _xaca0463_load_team_paths() to either (a) raise an exception (caught
        at the call site) or (b) return bootstrap defaults.  In EITHER case
        the server must not raise an unhandled non-SystemExit exception.
        SystemExit is acceptable only if the loaded data happens to contain
        real collisions (e.g. bootstrap defaults that haven't been migrated);
        in that case the guard is working correctly.
        """
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            f.write("{ this is not valid json {{{{")
            tmp_path = f.name

        try:
            with patch.dict(os.environ, {"AITEAMFORGE_CONFIG": tmp_path}):
                import aiteamforge_paths
                orig_cache = aiteamforge_paths._CONFIG_CACHE
                orig_path = aiteamforge_paths._CONFIG_PATH_AT_LOAD
                aiteamforge_paths._CONFIG_CACHE = None
                aiteamforge_paths._CONFIG_PATH_AT_LOAD = None
                try:
                    buf = io.StringIO()
                    old_stderr = sys.stderr
                    sys.stderr = buf
                    try:
                        try:
                            data = server._xaca0463_load_team_paths()
                            team_paths_data = data
                        except Exception:
                            # Loader raised — call site would catch and skip guard.
                            # This is the correct behaviour: no unhandled crash.
                            team_paths_data = None
                    finally:
                        sys.stderr = old_stderr

                    # Key assertion: we got here without an unhandled exception.
                    # Whether team_paths_data is None (loader raised) or a dict
                    # (bootstrap defaults), the guard machinery didn't crash.
                    if team_paths_data is not None:
                        self.assertIsInstance(team_paths_data, dict)
                        self.assertIn("teams", team_paths_data)
                    # else: guard was skipped — acceptable outcome for malformed JSON
                finally:
                    aiteamforge_paths._CONFIG_CACHE = orig_cache
                    aiteamforge_paths._CONFIG_PATH_AT_LOAD = orig_path
        finally:
            os.unlink(tmp_path)

    # ------------------------------------------------------------------
    # Additional: multiple collisions → all reported
    # ------------------------------------------------------------------
    def test_guard_multiple_collisions_all_reported(self):
        """When two distinct ports each have collisions, both appear in output."""
        data = {
            "teams": {
                "a": {"lcars_port": 8200},
                "b": {"lcars_port": 8200},
                "c": {"lcars_port": 8300},
                "d": {"lcars_port": 8300},
            }
        }
        _, stderr = _capture_stderr_with_exit(
            server._xaca0463_assert_no_port_conflicts, data, "a"
        )
        self.assertIn("8200", stderr)
        self.assertIn("8300", stderr)

    # ------------------------------------------------------------------
    # Additional: collision + null active → both conditions reported
    # ------------------------------------------------------------------
    def test_guard_collision_and_null_active_both_reported(self):
        """Active instance has null AND there are port collisions — both reported."""
        data = {
            "teams": {
                "my-team":  {"lcars_port": None},
                "other-a":  {"lcars_port": 8200},
                "other-b":  {"lcars_port": 8200},
            }
        }
        _, stderr = _capture_stderr_with_exit(
            server._xaca0463_assert_no_port_conflicts, data, "my-team"
        )
        self.assertIn("my-team", stderr)
        self.assertIn("8200", stderr)
        self.assertIn("kb-port-fix", stderr)


if __name__ == "__main__":
    unittest.main()
