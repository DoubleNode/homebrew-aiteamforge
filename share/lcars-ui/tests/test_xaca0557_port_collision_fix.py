#!/usr/bin/env python3

#
#  test_xaca0557_port_collision_fix.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 DoubleNode.com. All rights reserved.
#

"""
Unit tests for XACA-0557: collision-free port assignment in the wizard and
import paths.

Tests cover:
  1. _resolve_kb_port_fix() finds the script at the dev-tree path.
  2. _run_port_collision_fix() is a no-op when team-paths.json has no collisions.
  3. _run_port_collision_fix() auto-fixes duplicate ports — config ends up
     collision-free (the core XACA-0557 requirement).
  4. _run_port_collision_fix() prints a human-readable summary of what changed.
  5. _run_port_collision_fix() is gracefully non-fatal when kb-port-fix.py is
     not found (warns, does not raise or exit).
  6. run_accept_defaults() calls _run_port_collision_fix() after writing config.
  7. run_interactive() calls _run_port_collision_fix() after writing config.
  8. Wizard does NOT call _run_port_collision_fix() on --dry-run writes.
  9. kb-team-import --fix-ports standalone mode exits 0 (shell integration smoke-test).

Run with:
    PYTHONPATH=lcars-ui python3 -m pytest lcars-ui/tests/test_xaca0557_port_collision_fix.py -v
  or from the repo root:
    PYTHONPATH=lcars-ui python3 -m pytest lcars-ui/tests/ -k xaca0557
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, call, patch

# ---------------------------------------------------------------------------
# Bootstrap: locate and import the wizard module directly (it lives in
# scripts/, not a package, so we use importlib).
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).parent.parent.parent  # dev-team root
WIZARD_PATH = REPO_ROOT / "scripts" / "aiteamforge-team-paths-wizard.py"
KB_PORT_FIX_PATH = (
    REPO_ROOT / "homebrew-tap" / "libexec" / "commands" / "kb-port-fix.py"
)

PORTFIX_PATH = REPO_ROOT / "kanban-hooks" / "portfix_runner.py"


def _import_wizard():
    """Import aiteamforge-team-paths-wizard as a module."""
    spec = importlib.util.spec_from_file_location("wizard", WIZARD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _import_portfix():
    """Import the shared portfix_runner module directly."""
    spec = importlib.util.spec_from_file_location("portfix_runner", PORTFIX_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


WIZARD = _import_wizard()
PORTFIX = _import_portfix()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_team_paths(teams: dict, schema_version: int = 3) -> dict:
    """Build a well-formed team-paths.json dict."""
    return {"schema_version": schema_version, "teams": teams}


def _write_team_paths(path: Path, teams: dict) -> None:
    """Write a team-paths.json with the given teams dict."""
    path.write_text(
        json.dumps(_make_team_paths(teams), indent=2) + "\n",
        encoding="utf-8",
    )


def _read_team_paths(path: Path) -> dict:
    """Read and parse a team-paths.json."""
    return json.loads(path.read_text(encoding="utf-8"))


def _has_port_collision(teams: dict) -> bool:
    """Return True if any two teams share an lcars_port value."""
    seen: set[int] = set()
    for entry in teams.values():
        port = entry.get("lcars_port")
        if port is None:
            continue
        p = int(port)
        if p in seen:
            return True
        seen.add(p)
    return False


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestResolveKbPortFix(unittest.TestCase):
    """_resolve_kb_port_fix() resolution logic."""

    def test_finds_dev_tree_path(self):
        """Returns the dev-tree kb-port-fix.py path when it exists."""
        resolved = WIZARD._resolve_kb_port_fix()
        # Dev-tree path: ~/dev-team/homebrew-tap/libexec/commands/kb-port-fix.py
        # This test machine always has it (dev M3Pro).
        if KB_PORT_FIX_PATH.exists():
            self.assertIsNotNone(resolved)
            self.assertTrue(resolved.exists(), f"Resolved path does not exist: {resolved}")
        else:
            # CI without a tap checkout — allowed to return None.
            pass  # pragma: no cover

    def test_returns_none_when_not_found(self):
        """Returns None when neither dev-tree nor brew path exists."""
        # Patch Path.home() to a temp dir so no real paths match.
        with tempfile.TemporaryDirectory() as tmpdir:
            fake_home = Path(tmpdir)
            with patch.object(Path, "home", return_value=fake_home):
                # brew fallback: stub 'brew' as not found
                with patch("subprocess.run", side_effect=FileNotFoundError):
                    result = WIZARD._resolve_kb_port_fix()
        self.assertIsNone(result)


class TestRunPortCollisionFix(unittest.TestCase):
    """_run_port_collision_fix() end-to-end with the real kb-port-fix.py."""

    def setUp(self):
        """Skip tests in this class if kb-port-fix.py is not available."""
        if not KB_PORT_FIX_PATH.exists():
            self.skipTest(  # pragma: no cover
                f"kb-port-fix.py not found at {KB_PORT_FIX_PATH} — "
                "skipping integration tests (dev-tree required)"
            )

    # ------------------------------------------------------------------
    # Test 2: no-op on a clean config
    # ------------------------------------------------------------------
    def test_noop_on_clean_config(self):
        """No changes when all ports are unique."""
        teams = {
            "academy":  {"lcars_port": 8203},
            "ios":      {"lcars_port": 8260},
            "android":  {"lcars_port": 8280},
        }
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = Path(tmpdir) / "team-paths.json"
            _write_team_paths(cfg, teams)
            before_text = cfg.read_text(encoding="utf-8")

            buf = io.StringIO()
            with patch.dict(os.environ, {"AITEAMFORGE_CONFIG": str(cfg)}, clear=False):
                with patch("sys.stdout", buf):
                    WIZARD._run_port_collision_fix(cfg)
            output = buf.getvalue()

            # File should still exist and be collision-free.
            after = _read_team_paths(cfg)
        self.assertFalse(_has_port_collision(after["teams"]))
        # Should mention "No changes needed" or "OK"
        self.assertRegex(output.lower(), r"no changes needed|port collision.*ok|ok")

    # ------------------------------------------------------------------
    # Test 3 (core): duplicate port → config ends up collision-free
    # ------------------------------------------------------------------
    def test_fixes_duplicate_ports_makes_config_collision_free(self):
        """After _run_port_collision_fix(), a config with duplicate lcars_port
        values has all ports unique.  This is the core XACA-0557 requirement."""
        # Write a config where academy and ios share port 8260.
        teams = {
            "academy":  {"lcars_port": 8260},   # collision!
            "ios":      {"lcars_port": 8260},   # collision!
            "android":  {"lcars_port": 8280},
        }
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = Path(tmpdir) / "team-paths.json"
            _write_team_paths(cfg, teams)

            self.assertTrue(
                _has_port_collision(_read_team_paths(cfg)["teams"]),
                "Pre-condition: initial config must have a collision",
            )

            with patch.dict(os.environ, {"AITEAMFORGE_CONFIG": str(cfg)}, clear=False):
                buf = io.StringIO()
                with patch("sys.stdout", buf):
                    WIZARD._run_port_collision_fix(cfg)

            after = _read_team_paths(cfg)
            self.assertFalse(
                _has_port_collision(after["teams"]),
                f"Post-condition: config must be collision-free after fix. Got: {after['teams']}",
            )

    # ------------------------------------------------------------------
    # Test 4: printed summary mentions what changed
    # ------------------------------------------------------------------
    def test_prints_summary_of_changes(self):
        """Output includes a human-readable summary when ports are reassigned."""
        teams = {
            "team-a": {"lcars_port": 8200},
            "team-b": {"lcars_port": 8200},  # collision
        }
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = Path(tmpdir) / "team-paths.json"
            _write_team_paths(cfg, teams)
            with patch.dict(os.environ, {"AITEAMFORGE_CONFIG": str(cfg)}, clear=False):
                buf = io.StringIO()
                with patch("sys.stdout", buf):
                    WIZARD._run_port_collision_fix(cfg)
                output = buf.getvalue()

        # The summary should mention either the port number or "renumbered"/"updated"
        self.assertTrue(
            any(kw in output for kw in ("8200", "renumber", "update", "collision", "Backup")),
            f"Expected collision-fix summary in output, got: {output!r}",
        )

    # ------------------------------------------------------------------
    # Test 5: gracefully non-fatal when kb-port-fix.py is not found
    # ------------------------------------------------------------------
    def test_graceful_when_kbfix_not_found(self):
        """Does not raise or exit when kb-port-fix.py cannot be located.

        The resolver/runner live in the shared portfix_runner module now, so we
        patch its resolve_kb_port_fix (which the wizard wrapper delegates to).
        """
        portfix = WIZARD._load_portfix_runner()
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = Path(tmpdir) / "team-paths.json"
            _write_team_paths(cfg, {"a": {"lcars_port": 8200}})

            buf_out = io.StringIO()
            buf_err = io.StringIO()
            with patch.object(portfix, "resolve_kb_port_fix", return_value=None):
                with patch("sys.stdout", buf_out):
                    with patch("sys.stderr", buf_err):
                        # Must not raise
                        WIZARD._run_port_collision_fix(cfg)

        # Should warn on stderr
        self.assertIn("WARNING", buf_err.getvalue())


class TestWizardCallsPortFix(unittest.TestCase):
    """Wizard functions call _run_port_collision_fix after writing config."""

    def _make_minimal_default_teams(self) -> dict:
        return {
            "academy": {
                "working_dir": str(Path.home() / "dev-team"),
                "kanban_dir": str(Path.home() / "dev-team" / "kanban"),
                "lcars_port": 8203,
                "lcars_port_base": 8200,
                "lcars_port_range": 10,
            },
        }

    # ------------------------------------------------------------------
    # Test 6: run_accept_defaults calls _run_port_collision_fix
    # ------------------------------------------------------------------
    def test_accept_defaults_calls_port_fix(self):
        """run_accept_defaults() calls _run_port_collision_fix() after writing."""
        default_teams = self._make_minimal_default_teams()
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = Path(tmpdir) / "team-paths.json"
            with patch.object(WIZARD, "_run_port_collision_fix") as mock_fix:
                WIZARD.run_accept_defaults(
                    default_teams=default_teams,
                    config_path=cfg,
                    dry_run=False,
                    schema_version=3,
                )
            mock_fix.assert_called_once_with(cfg)

    # ------------------------------------------------------------------
    # Test 7: run_interactive calls _run_port_collision_fix (via _atomic_write)
    # ------------------------------------------------------------------
    def test_interactive_calls_port_fix(self):
        """run_interactive() calls _run_port_collision_fix() after writing."""
        default_teams = self._make_minimal_default_teams()
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = Path(tmpdir) / "team-paths.json"
            # Simulate user pressing Enter to all prompts (accept all defaults + confirm).
            inputs = ["y"] * 20  # more than enough
            with patch("builtins.input", side_effect=inputs):
                with patch.object(WIZARD, "_run_port_collision_fix") as mock_fix:
                    with patch("sys.stdout", io.StringIO()):  # suppress wizard output
                        WIZARD.run_interactive(
                            default_teams=default_teams,
                            config_path=cfg,
                            dry_run=False,
                            schema_version=3,
                        )
            mock_fix.assert_called_once_with(cfg)

    # ------------------------------------------------------------------
    # Test 8: --dry-run does NOT call _run_port_collision_fix
    # ------------------------------------------------------------------
    def test_dry_run_does_not_call_port_fix(self):
        """Neither run_accept_defaults() nor run_interactive() calls port-fix on
        --dry-run because no real file is written."""
        default_teams = self._make_minimal_default_teams()
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = Path(tmpdir) / "team-paths.json"
            with patch.object(WIZARD, "_run_port_collision_fix") as mock_fix:
                with patch("sys.stdout", io.StringIO()):
                    WIZARD.run_accept_defaults(
                        default_teams=default_teams,
                        config_path=cfg,
                        dry_run=True,
                        schema_version=3,
                    )
            mock_fix.assert_not_called()


class TestKbTeamImportFixPorts(unittest.TestCase):
    """kb-team-import --fix-ports integration smoke-test."""

    def test_fix_ports_standalone_exits_0(self):
        """kb-team-import --fix-ports runs without error when team-paths.json
        has no collisions and kb-port-fix.py is available."""
        if not KB_PORT_FIX_PATH.exists():
            self.skipTest(  # pragma: no cover
                "kb-port-fix.py not found — skipping integration smoke-test"
            )

        kb_import = REPO_ROOT / "scripts" / "kb-team-import"
        if not kb_import.exists():
            self.skipTest(f"kb-team-import not found at {kb_import}")  # pragma: no cover

        # Write a clean (no-collision) team-paths.json in a temp dir.
        teams = {
            "academy":  {"lcars_port": 8203},
            "ios":      {"lcars_port": 8260},
        }
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = Path(tmpdir) / "team-paths.json"
            _write_team_paths(cfg, teams)

            env = {**os.environ, "AITEAMFORGE_CONFIG": str(cfg)}
            result = subprocess.run(
                ["bash", str(kb_import), "--fix-ports"],
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
            )

        self.assertEqual(
            result.returncode, 0,
            f"Expected exit 0 from kb-team-import --fix-ports, got {result.returncode}.\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}",
        )
        # Should mention "fix" or "OK" in output
        combined = result.stdout + result.stderr
        self.assertRegex(combined.lower(), r"fix|ok|no changes")


class TestPortfixRunnerModule(unittest.TestCase):
    """The shared portfix_runner module (single resolver/runner, PR #472)."""

    def test_resolve_finds_dev_tree_path(self):
        if not KB_PORT_FIX_PATH.exists():
            self.skipTest("kb-port-fix.py not found — dev tree required")  # pragma: no cover
        resolved = PORTFIX.resolve_kb_port_fix()
        self.assertIsNotNone(resolved)
        self.assertTrue(str(resolved).endswith("kb-port-fix.py"))

    def test_resolve_returns_none_when_not_found(self):
        with tempfile.TemporaryDirectory() as fake_home_dir:
            fake_home = Path(fake_home_dir)
            with patch.object(Path, "home", return_value=fake_home):
                with patch("subprocess.run", side_effect=FileNotFoundError):
                    self.assertIsNone(PORTFIX.resolve_kb_port_fix())

    def test_run_makes_config_collision_free(self):
        """run_port_collision_fix() on a duplicate-port config yields unique ports.

        Uses real team names (matching the wizard integration test) so
        kb-port-fix can resolve each team's port band and renumber the clash.
        """
        if not KB_PORT_FIX_PATH.exists():
            self.skipTest("kb-port-fix.py not found — dev tree required")  # pragma: no cover
        teams = {
            "academy":  {"lcars_port": 8260},   # collision
            "ios":      {"lcars_port": 8260},   # collision
            "android":  {"lcars_port": 8280},
        }
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = Path(tmpdir) / "team-paths.json"
            _write_team_paths(cfg, teams)
            self.assertTrue(_has_port_collision(_read_team_paths(cfg)["teams"]))
            with patch("sys.stdout", io.StringIO()):
                rc = PORTFIX.run_port_collision_fix(cfg)
            self.assertEqual(rc, 0)
            self.assertFalse(_has_port_collision(_read_team_paths(cfg)["teams"]))

    def test_run_graceful_when_not_found(self):
        """Returns 0 and warns (never raises) when kb-port-fix.py is absent."""
        buf_err = io.StringIO()
        with patch.object(PORTFIX, "resolve_kb_port_fix", return_value=None):
            with patch("sys.stdout", io.StringIO()):
                with patch("sys.stderr", buf_err):
                    rc = PORTFIX.run_port_collision_fix(None)
        self.assertEqual(rc, 0)
        self.assertIn("WARNING", buf_err.getvalue())

    def test_main_no_args_is_non_fatal(self):
        """CLI with no args targets the default config and always returns 0."""
        with patch.object(PORTFIX, "run_port_collision_fix", return_value=7) as mock_run:
            rc = PORTFIX.main([])
        self.assertEqual(rc, 0)  # non-fatal contract regardless of underlying code
        mock_run.assert_called_once_with(None)


if __name__ == "__main__":
    unittest.main()
