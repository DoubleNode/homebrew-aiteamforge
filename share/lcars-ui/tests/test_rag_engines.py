#!/usr/bin/env python3

#
#  test_rag_engines.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Unit tests for lcars-ui/rag_engines module.

Tests cover:
- RAGEngineConfig.from_dict() / to_dict() round-trip
- RAGEngineStatus.to_dict() serialization
- InstallProgress.to_dict() serialization
- RAGEngineManager engine registration (all 3 types)
- RAGEngineManager.get_engine() returns None for unknown ID
- Each engine's get_status(), health_check(), install(), to_dict()

Run with:
    python3 -m unittest lcars-ui/tests/test_rag_engines.py
  or from the repo root:
    python3 -m unittest discover -s lcars-ui/tests -p 'test_*.py'
  or with pytest:
    cd lcars-ui && python3 -m pytest tests/test_rag_engines.py -v
"""

import sys
import unittest
from pathlib import Path
from unittest.mock import patch

# ---------------------------------------------------------------------------
# Ensure rag_engines can be imported from this test file's location
# ---------------------------------------------------------------------------
LCARS_UI_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(LCARS_UI_DIR))

from rag_engines.provider import (  # noqa: E402
    RAGEngineConfig,
    RAGEngineProvider,
    RAGEngineStatus,
    InstallProgress,
)
from rag_engines.manager import RAGEngineManager  # noqa: E402

# Importing rag_engines.engines triggers registration of all 3 engine types
import rag_engines.engines  # noqa: E402, F401
from rag_engines.engines import (  # noqa: E402
    LightRAGEngine,
    CodeGraphRAGEngine,
    RAGAnythingEngine,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_config(engine_id="test-engine", engine_type="lightrag", port=9621) -> RAGEngineConfig:
    """Return a minimal RAGEngineConfig for testing."""
    return RAGEngineConfig(
        id=engine_id,
        type=engine_type,
        name=f"Test {engine_type}",
        enabled=True,
        install_path="",
        data_dir="",
        port=port,
        status="not_installed",
        version="1.0.0",
        settings={"key": "value"},
        teams=["academy"],
    )


# ---------------------------------------------------------------------------
# Tests: RAGEngineConfig
# ---------------------------------------------------------------------------

class TestRAGEngineConfig(unittest.TestCase):
    """Tests for RAGEngineConfig data class."""

    def test_from_dict_basic(self):
        data = {
            "id": "my-engine",
            "type": "lightrag",
            "name": "My LightRAG",
            "enabled": True,
            "installPath": "/opt/lightrag",
            "dataDir": "/data/lightrag",
            "port": 9621,
            "status": "installed",
            "version": "0.9.1",
            "settings": {"graph_type": "nx"},
            "teams": ["ios", "android"],
        }
        config = RAGEngineConfig.from_dict(data)

        self.assertEqual(config.id, "my-engine")
        self.assertEqual(config.type, "lightrag")
        self.assertEqual(config.name, "My LightRAG")
        self.assertTrue(config.enabled)
        self.assertEqual(config.install_path, "/opt/lightrag")
        self.assertEqual(config.data_dir, "/data/lightrag")
        self.assertEqual(config.port, 9621)
        self.assertEqual(config.status, "installed")
        self.assertEqual(config.version, "0.9.1")
        self.assertEqual(config.settings, {"graph_type": "nx"})
        self.assertEqual(config.teams, ["ios", "android"])

    def test_from_dict_defaults(self):
        """from_dict() applies sensible defaults for missing keys."""
        config = RAGEngineConfig.from_dict({})

        self.assertEqual(config.id, "")
        self.assertEqual(config.type, "")
        self.assertEqual(config.name, "")
        self.assertTrue(config.enabled)
        self.assertEqual(config.install_path, "")
        self.assertEqual(config.data_dir, "")
        self.assertEqual(config.port, 0)
        self.assertEqual(config.status, "not_installed")
        self.assertIsNone(config.version)
        self.assertEqual(config.settings, {})
        self.assertEqual(config.teams, [])

    def test_to_dict_round_trip(self):
        """to_dict() produces a dict that from_dict() reconstructs identically."""
        original_data = {
            "id": "round-trip",
            "type": "rag-anything",
            "name": "RT Engine",
            "enabled": False,
            "installPath": "/tmp/engine",
            "dataDir": "/tmp/data",
            "port": 9623,
            "status": "running",
            "version": "2.0.0",
            "settings": {"modalities": ["text", "image"]},
            "teams": [],
        }
        config = RAGEngineConfig.from_dict(original_data)
        serialized = config.to_dict()

        self.assertEqual(serialized["id"], original_data["id"])
        self.assertEqual(serialized["type"], original_data["type"])
        self.assertEqual(serialized["name"], original_data["name"])
        self.assertEqual(serialized["enabled"], original_data["enabled"])
        self.assertEqual(serialized["installPath"], original_data["installPath"])
        self.assertEqual(serialized["dataDir"], original_data["dataDir"])
        self.assertEqual(serialized["port"], original_data["port"])
        self.assertEqual(serialized["status"], original_data["status"])
        self.assertEqual(serialized["version"], original_data["version"])
        self.assertEqual(serialized["settings"], original_data["settings"])
        # Empty teams list serializes as None
        self.assertIsNone(serialized["teams"])

    def test_to_dict_teams_populated(self):
        """teams list is preserved when non-empty."""
        config = RAGEngineConfig.from_dict({"teams": ["academy", "ios"]})
        serialized = config.to_dict()
        self.assertEqual(serialized["teams"], ["academy", "ios"])


# ---------------------------------------------------------------------------
# Tests: RAGEngineStatus
# ---------------------------------------------------------------------------

class TestRAGEngineStatus(unittest.TestCase):
    """Tests for RAGEngineStatus.to_dict() serialization."""

    def test_to_dict_full(self):
        status = RAGEngineStatus(
            engine_id="eng-1",
            status="running",
            health="healthy",
            message="All good",
            last_check="2025-01-01T00:00:00+00:00",
            version="1.2.3",
            port=9621,
            pid=12345,
        )
        d = status.to_dict()

        self.assertEqual(d["engineId"], "eng-1")
        self.assertEqual(d["status"], "running")
        self.assertEqual(d["health"], "healthy")
        self.assertEqual(d["message"], "All good")
        self.assertEqual(d["lastCheck"], "2025-01-01T00:00:00+00:00")
        self.assertEqual(d["version"], "1.2.3")
        self.assertEqual(d["port"], 9621)
        self.assertEqual(d["pid"], 12345)

    def test_to_dict_defaults(self):
        status = RAGEngineStatus(engine_id="eng-2", status="not_installed")
        d = status.to_dict()

        self.assertEqual(d["engineId"], "eng-2")
        self.assertEqual(d["status"], "not_installed")
        self.assertEqual(d["health"], "unknown")
        self.assertIsNone(d["message"])
        self.assertIsNone(d["lastCheck"])
        self.assertIsNone(d["version"])
        self.assertIsNone(d["port"])
        self.assertIsNone(d["pid"])

    def test_to_dict_keys_present(self):
        """All expected keys are always present in the serialized dict."""
        status = RAGEngineStatus(engine_id="x", status="error")
        d = status.to_dict()
        expected_keys = {
            "engineId", "status", "health", "message", "lastCheck",
            "version", "port", "pid", "latestVersion", "updateAvailable",
        }
        self.assertEqual(set(d.keys()), expected_keys)


# ---------------------------------------------------------------------------
# Tests: InstallProgress
# ---------------------------------------------------------------------------

class TestInstallProgress(unittest.TestCase):
    """Tests for InstallProgress.to_dict() serialization."""

    def test_to_dict_full(self):
        progress = InstallProgress(
            engine_id="eng-3",
            step=2,
            total_steps=5,
            message="Downloading...",
            percent=40.0,
            error=None,
        )
        d = progress.to_dict()

        self.assertEqual(d["engineId"], "eng-3")
        self.assertEqual(d["step"], 2)
        self.assertEqual(d["totalSteps"], 5)
        self.assertEqual(d["message"], "Downloading...")
        self.assertAlmostEqual(d["percent"], 40.0)
        self.assertIsNone(d["error"])

    def test_to_dict_with_error(self):
        progress = InstallProgress(
            engine_id="eng-4",
            step=1,
            total_steps=3,
            message="Failed",
            percent=0.0,
            error="pip install failed",
        )
        d = progress.to_dict()
        self.assertEqual(d["error"], "pip install failed")

    def test_to_dict_keys_present(self):
        progress = InstallProgress(engine_id="x", step=0, total_steps=1, message="")
        d = progress.to_dict()
        expected_keys = {"engineId", "step", "totalSteps", "message", "percent", "error"}
        self.assertEqual(set(d.keys()), expected_keys)


# ---------------------------------------------------------------------------
# Tests: RAGEngineManager registration
# ---------------------------------------------------------------------------

class TestRAGEngineManagerRegistration(unittest.TestCase):
    """Tests for engine type registration in RAGEngineManager."""

    def test_all_three_types_registered(self):
        registered = RAGEngineManager.get_registered_types()
        self.assertIn("lightrag", registered)
        self.assertIn("code-graph-rag", registered)
        self.assertIn("rag-anything", registered)

    def test_registered_count_at_least_three(self):
        """At least the 3 built-in engine types are registered."""
        self.assertGreaterEqual(len(RAGEngineManager.get_registered_types()), 3)

    def test_get_engine_unknown_id_returns_none(self):
        """get_engine() returns None for an ID that doesn't exist in config."""
        # Use a fresh manager with no config file to ensure _engines is empty
        manager = RAGEngineManager(config_path="/nonexistent/path/rag-engines.json")
        result = manager.get_engine("definitely-does-not-exist")
        self.assertIsNone(result)

    def test_list_engines_empty_when_no_config(self):
        """list_engines() returns empty list when no config file is present."""
        manager = RAGEngineManager(config_path="/nonexistent/path/rag-engines.json")
        # Patch _find_config_file to guarantee no fallback config is loaded from
        # real on-disk locations (e.g. ~/dev-team/kanban/config/rag-engines.json).
        # This isolates the test from the execution environment.
        with patch.object(manager, "_find_config_file", return_value=None):
            result = manager.list_engines()
        self.assertEqual(result, [])


# ---------------------------------------------------------------------------
# Tests: LightRAGEngine
# ---------------------------------------------------------------------------

class TestLightRAGEngine(unittest.TestCase):
    """Tests for LightRAGEngine provider."""

    def setUp(self):
        self.config = _make_config("lr-1", "lightrag", port=9621)
        self.engine = LightRAGEngine(self.config)

    def test_get_status_no_process(self):
        with patch.object(self.engine, "_find_process_pid", return_value=None):
            status = self.engine.get_status()
        self.assertIsInstance(status, RAGEngineStatus)
        self.assertEqual(status.engine_id, "lr-1")
        self.assertIsNone(status.pid)

    def test_get_status_with_process(self):
        with patch.object(self.engine, "_find_process_pid", return_value=9999):
            status = self.engine.get_status()
        self.assertEqual(status.status, "running")
        self.assertEqual(status.health, "healthy")
        self.assertEqual(status.pid, 9999)

    def test_health_check_no_process(self):
        with patch.object(self.engine, "_find_process_pid", return_value=None):
            status = self.engine.health_check()
        self.assertIsInstance(status, RAGEngineStatus)
        self.assertEqual(status.engine_id, "lr-1")

    def test_health_check_with_process(self):
        with patch.object(self.engine, "_find_process_pid", return_value=1234):
            status = self.engine.health_check()
        self.assertEqual(status.status, "running")
        self.assertEqual(status.health, "healthy")
        self.assertEqual(status.pid, 1234)

    def test_install_returns_progress(self):
        with patch.object(RAGEngineProvider, "_venv_python", return_value=sys.executable):
            progress = self.engine.install()
        self.assertIsInstance(progress, InstallProgress)
        self.assertEqual(progress.engine_id, "lr-1")
        self.assertGreater(progress.total_steps, 0)

    def test_to_dict_shape(self):
        d = self.engine.to_dict()
        self.assertEqual(d["id"], "lr-1")
        self.assertEqual(d["type"], "lightrag")
        self.assertIn("description", d)
        self.assertIn("port", d)
        self.assertIn("dataDir", d)


# ---------------------------------------------------------------------------
# Tests: CodeGraphRAGEngine
# ---------------------------------------------------------------------------

class TestCodeGraphRAGEngine(unittest.TestCase):
    """Tests for CodeGraphRAGEngine provider."""

    def setUp(self):
        self.config = _make_config("cg-1", "code-graph-rag", port=9622)
        self.engine = CodeGraphRAGEngine(self.config)

    def test_get_status_no_process(self):
        with patch.object(self.engine, "_find_process_pid", return_value=None):
            status = self.engine.get_status()
        self.assertIsInstance(status, RAGEngineStatus)
        self.assertEqual(status.engine_id, "cg-1")

    def test_get_status_with_process(self):
        with patch.object(self.engine, "_find_process_pid", return_value=5678):
            status = self.engine.get_status()
        self.assertEqual(status.status, "running")
        self.assertEqual(status.pid, 5678)

    def test_health_check_no_process(self):
        with patch.object(self.engine, "_find_process_pid", return_value=None):
            status = self.engine.health_check()
        self.assertIsInstance(status, RAGEngineStatus)

    def test_health_check_with_process(self):
        with patch.object(self.engine, "_find_process_pid", return_value=5678):
            status = self.engine.health_check()
        self.assertEqual(status.health, "healthy")

    def test_install_returns_progress(self):
        with patch.object(RAGEngineProvider, "_venv_python", return_value=sys.executable):
            progress = self.engine.install()
        self.assertIsInstance(progress, InstallProgress)
        self.assertEqual(progress.engine_id, "cg-1")

    def test_start_failed_spawn_does_not_corrupt_status(self):
        """If _spawn_server returns None, config.status must NOT be set to 'running'."""
        self.engine.config.status = "installed"
        with patch.object(self.engine, "_find_process_pid", return_value=None), \
             patch.object(self.engine, "_spawn_server", return_value=None):
            result = self.engine.start()
        self.assertEqual(result.status, "error")
        self.assertEqual(self.engine.config.status, "installed")

    def test_start_successful_spawn_sets_running(self):
        """If _spawn_server returns a PID, config.status should be 'running'."""
        self.engine.config.status = "installed"
        with patch.object(self.engine, "_find_process_pid", return_value=None), \
             patch.object(self.engine, "_spawn_server", return_value=42):
            result = self.engine.start()
        self.assertEqual(result.status, "running")
        self.assertEqual(self.engine.config.status, "running")

    def test_to_dict_shape(self):
        d = self.engine.to_dict()
        self.assertEqual(d["id"], "cg-1")
        self.assertEqual(d["type"], "code-graph-rag")
        self.assertIn("description", d)


# ---------------------------------------------------------------------------
# Tests: RAGAnythingEngine
# ---------------------------------------------------------------------------

class TestRAGAnythingEngine(unittest.TestCase):
    """Tests for RAGAnythingEngine provider."""

    def setUp(self):
        self.config = _make_config("ra-1", "rag-anything", port=9623)
        self.engine = RAGAnythingEngine(self.config)

    def test_get_status_no_process(self):
        with patch.object(self.engine, "_find_process_pid", return_value=None):
            status = self.engine.get_status()
        self.assertIsInstance(status, RAGEngineStatus)
        self.assertEqual(status.engine_id, "ra-1")

    def test_get_status_with_process(self):
        with patch.object(self.engine, "_find_process_pid", return_value=7777):
            status = self.engine.get_status()
        self.assertEqual(status.status, "running")
        self.assertEqual(status.pid, 7777)

    def test_health_check_no_process(self):
        with patch.object(self.engine, "_find_process_pid", return_value=None):
            status = self.engine.health_check()
        self.assertIsInstance(status, RAGEngineStatus)

    def test_health_check_with_process(self):
        with patch.object(self.engine, "_find_process_pid", return_value=7777):
            status = self.engine.health_check()
        self.assertEqual(status.health, "healthy")

    def test_install_returns_progress(self):
        with patch.object(RAGEngineProvider, "_venv_python", return_value=sys.executable):
            progress = self.engine.install()
        self.assertIsInstance(progress, InstallProgress)
        self.assertEqual(progress.engine_id, "ra-1")

    def test_to_dict_shape(self):
        d = self.engine.to_dict()
        self.assertEqual(d["id"], "ra-1")
        self.assertEqual(d["type"], "rag-anything")
        self.assertIn("description", d)


# ---------------------------------------------------------------------------
# Tests: Base class helper methods
# ---------------------------------------------------------------------------

class TestBaseClassHelpers(unittest.TestCase):
    """Tests for _now_iso() and _find_process_pid() on the base class."""

    def setUp(self):
        config = _make_config("base-test", "lightrag", port=19999)
        self.engine = LightRAGEngine(config)

    def test_now_iso_format(self):
        iso = self.engine._now_iso()
        # Should be a non-empty string containing 'T' (ISO 8601 separator)
        self.assertIsInstance(iso, str)
        self.assertIn("T", iso)
        self.assertGreater(len(iso), 10)

    def test_find_process_pid_no_process(self):
        """Returns None when lsof finds nothing on the port."""
        import subprocess as _sp
        mock_result = _sp.CompletedProcess(args=[], returncode=1, stdout="", stderr="")
        with patch("rag_engines.provider.subprocess.run", return_value=mock_result):
            pid = self.engine._find_process_pid()
        self.assertIsNone(pid)

    def test_find_process_pid_with_process(self):
        """Returns integer PID when lsof finds a process."""
        import subprocess as _sp
        mock_result = _sp.CompletedProcess(args=[], returncode=0, stdout="42\n", stderr="")
        with patch("rag_engines.provider.subprocess.run", return_value=mock_result):
            pid = self.engine._find_process_pid()
        self.assertEqual(pid, 42)

    def test_find_process_pid_timeout_returns_none(self):
        """Returns None on subprocess timeout without raising."""
        import subprocess as _sp
        with patch("rag_engines.provider.subprocess.run", side_effect=_sp.TimeoutExpired(cmd="lsof", timeout=5)):
            pid = self.engine._find_process_pid()
        self.assertIsNone(pid)


if __name__ == "__main__":
    unittest.main()
