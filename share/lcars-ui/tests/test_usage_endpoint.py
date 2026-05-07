#
#  test_usage_endpoint.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""Unit tests for the /api/usage/current endpoint logic (XACA-0243-003).

We test ``_build_usage_response`` — the pure function that contains all
response-building logic — rather than the HTTP handler directly.  This avoids
the need for a running server, fake sockets, or complex mocking of
``BaseHTTPRequestHandler``.

Run with:
    cd /Users/darrenehlers/dev-team/worktrees/xaca-0243
    python3 -m unittest lcars-ui.tests.test_usage_endpoint -v
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import unittest
from unittest import mock

# Make the lcars-ui package importable regardless of cwd.
_HERE = os.path.dirname(os.path.abspath(__file__))
_LCARS_UI = os.path.dirname(_HERE)
if _LCARS_UI not in sys.path:
    sys.path.insert(0, _LCARS_UI)

import server as _server  # noqa: E402


# ---------------------------------------------------------------------------
# Cache fixture helpers
# ---------------------------------------------------------------------------

def _make_cache(
    *,
    collected_at_unix: int = 1_714_000_000,
    ccusage_ok: bool = True,
    ccusage_error: str | None = None,
    active_window: dict | None = None,
    history: list | None = None,
    calibration: dict | None = None,
    totals: dict | None = None,
) -> dict:
    """Build a daemon-cache-shaped dict with sensible defaults."""
    return {
        "schema_version": 1,
        "collected_at_unix": collected_at_unix,
        "ccusage_ok": ccusage_ok,
        "ccusage_error": ccusage_error,
        "active_window": active_window,
        "history": history if history is not None else [],
        "calibration": calibration if calibration is not None else {
            "max_window_tokens": 300_000_000,
            "max_window_cost_usd": 200.0,
            "max_window_id": "test-abc",
            "p90_window_tokens": 130_000_000,
            "samples": 47,
        },
        "totals": totals if totals is not None else {
            "today_tokens": 5_000_000,
            "today_cost_usd": 4.20,
            "last_7d_tokens": 30_000_000,
            "last_7d_cost_usd": 25.0,
        },
    }


def _make_history_entries(n: int) -> list:
    """Return n dummy history window entries."""
    return [
        {
            "window_id": f"w-{i}",
            "total_tokens": 10_000_000 * (i + 1),
            "cost_usd": 5.0 * (i + 1),
            "is_gap": False,
        }
        for i in range(n)
    ]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestBuildUsageResponseCacheMissing(unittest.TestCase):
    """Case 1: cache file missing -> ok:false, error='collector not running'."""

    def test_missing_cache_returns_ok_false(self):
        _server._ccusage_missing_warned = False  # reset per-process flag
        status, payload = _server._build_usage_response(
            cache_path="/tmp/this-file-does-not-exist-xaca-0243.json"
        )
        self.assertEqual(status, 200)
        self.assertFalse(payload["ok"])
        self.assertTrue(payload["stale"])
        self.assertIsNone(payload["current"])
        self.assertIsNone(payload["projection"])
        self.assertEqual(payload["error"], "collector not running")

    def test_missing_cache_history_is_empty_list(self):
        _server._ccusage_missing_warned = False
        _, payload = _server._build_usage_response(
            cache_path="/tmp/this-file-does-not-exist-xaca-0243.json"
        )
        self.assertIsInstance(payload["history"], list)
        self.assertEqual(len(payload["history"]), 0)


class TestBuildUsageResponseCachePresent(unittest.TestCase):
    """Case 2: cache file present + valid -> ok based on freshness, current.tokens_used populated."""

    def setUp(self):
        self._tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        )
        # Use a fresh timestamp so the cache is not stale.
        import time
        cache = _make_cache(collected_at_unix=int(time.time()))
        cache["active_window"] = {
            "start_time": "2026-04-26T10:00:00Z",
            "end_time": "2026-04-26T15:00:00Z",
            "elapsed_minutes": 30,
            "remaining_minutes": 270,
            "total_tokens": 50_000_000,
            "cost_usd": 8.50,
            "burn_rate": {
                "tokens_per_minute": 250_000.0,
                "cost_per_hour": 17.0,
            },
        }
        json.dump(cache, self._tmp)
        self._tmp.flush()
        self._cache_path = self._tmp.name

    def tearDown(self):
        self._tmp.close()
        os.unlink(self._cache_path)

    def test_valid_cache_tokens_used_matches(self):
        status, payload = _server._build_usage_response(cache_path=self._cache_path)
        self.assertEqual(status, 200)
        self.assertIsNotNone(payload.get("current"))
        self.assertEqual(payload["current"]["tokens_used"], 50_000_000)

    def test_valid_cache_has_calibration(self):
        _, payload = _server._build_usage_response(cache_path=self._cache_path)
        self.assertIsNotNone(payload.get("calibration"))
        self.assertIn("max_window_tokens", payload["calibration"])


class TestBuildUsageResponseCcusageError(unittest.TestCase):
    """Case 3: ccusage_ok:false -> ok:false with error, but calibration still populated."""

    def setUp(self):
        self._tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        )
        import time
        cache = _make_cache(
            collected_at_unix=int(time.time()),
            ccusage_ok=False,
            ccusage_error="ccusage binary not found",
        )
        json.dump(cache, self._tmp)
        self._tmp.flush()
        self._cache_path = self._tmp.name

    def tearDown(self):
        self._tmp.close()
        os.unlink(self._cache_path)

    def test_ccusage_error_returns_ok_false(self):
        status, payload = _server._build_usage_response(cache_path=self._cache_path)
        self.assertEqual(status, 200)
        self.assertFalse(payload["ok"])

    def test_ccusage_error_calibration_still_populated(self):
        _, payload = _server._build_usage_response(cache_path=self._cache_path)
        cal = payload.get("calibration")
        self.assertIsNotNone(cal)
        # Calibration should have the samples count from the cache fixture (47).
        self.assertEqual(cal["samples"], 47)

    def test_ccusage_error_passthrough(self):
        _, payload = _server._build_usage_response(cache_path=self._cache_path)
        # ccusage_error should be surfaced in the response.
        self.assertEqual(payload.get("ccusage_error"), "ccusage binary not found")


class TestBuildUsageResponseMalformedJson(unittest.TestCase):
    """Case 4: malformed JSON in cache -> ok:false, no exception raised."""

    def setUp(self):
        self._tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        )
        self._tmp.write("{this is not valid json ][")
        self._tmp.flush()
        self._cache_path = self._tmp.name

    def tearDown(self):
        self._tmp.close()
        os.unlink(self._cache_path)

    def test_malformed_json_does_not_raise(self):
        try:
            status, payload = _server._build_usage_response(cache_path=self._cache_path)
        except Exception as exc:
            self.fail(f"_build_usage_response raised unexpectedly: {exc}")
        self.assertEqual(status, 200)
        self.assertFalse(payload["ok"])

    def test_malformed_json_error_key_present(self):
        _, payload = _server._build_usage_response(cache_path=self._cache_path)
        self.assertIn("error", payload)
        self.assertIsNotNone(payload["error"])


class TestHistoryLimit(unittest.TestCase):
    """Cases 5 & 6: history_limit query param trims and clamps correctly."""

    def setUp(self):
        self._tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        )
        import time
        cache = _make_cache(
            collected_at_unix=int(time.time()),
            history=_make_history_entries(20),
        )
        json.dump(cache, self._tmp)
        self._tmp.flush()
        self._cache_path = self._tmp.name

    def tearDown(self):
        self._tmp.close()
        os.unlink(self._cache_path)

    def test_history_limit_3_trims_to_3(self):
        _, payload = _server._build_usage_response(
            cache_path=self._cache_path, history_limit=3
        )
        history = payload.get("history", [])
        self.assertLessEqual(len(history), 3)

    def test_history_limit_999_clamped_to_50(self):
        # Build a cache with 60 entries to verify the clamp.
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as big_tmp:
            import time
            big_cache = _make_cache(
                collected_at_unix=int(time.time()),
                history=_make_history_entries(60),
            )
            json.dump(big_cache, big_tmp)
            big_path = big_tmp.name

        try:
            _, payload = _server._build_usage_response(
                cache_path=big_path, history_limit=999
            )
            history = payload.get("history", [])
            self.assertLessEqual(len(history), 50)
        finally:
            os.unlink(big_path)


class TestCollectorWatchdog(unittest.TestCase):
    """_collector_pid_alive + _ensure_collector_running watchdog logic."""

    def setUp(self):
        # Each test gets its own PID file so they can run in parallel.
        self._pid_tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".pid", delete=False
        )
        self._pid_tmp.close()
        self._original_pid_path = _server.CCUSAGE_PID_PATH
        _server.CCUSAGE_PID_PATH = self._pid_tmp.name
        # Reset throttle so tests don't influence each other.
        _server._ccusage_last_respawn_at = 0.0

    def tearDown(self):
        _server.CCUSAGE_PID_PATH = self._original_pid_path
        try:
            os.unlink(self._pid_tmp.name)
        except FileNotFoundError:
            pass

    def test_pid_alive_returns_false_when_pid_file_missing(self):
        os.unlink(self._pid_tmp.name)
        self.assertFalse(_server._collector_pid_alive())

    def test_pid_alive_returns_false_when_pid_file_malformed(self):
        with open(self._pid_tmp.name, "w") as fh:
            fh.write("not-a-number\n")
        self.assertFalse(_server._collector_pid_alive())

    def test_pid_alive_returns_false_when_process_dead(self):
        # PID 1 is always alive; instead use a PID that won't exist.
        # 0x7FFFFFFF is well above any real PID on macOS/Linux.
        with open(self._pid_tmp.name, "w") as fh:
            fh.write("2147483646\n")
        self.assertFalse(_server._collector_pid_alive())

    def test_pid_alive_returns_true_for_self_pid(self):
        with open(self._pid_tmp.name, "w") as fh:
            fh.write(f"{os.getpid()}\n")
        self.assertTrue(_server._collector_pid_alive())

    def test_pid_alive_returns_false_on_permission_error(self):
        # Cross-user PID scenario: the PID is alive but kill(pid, 0) raises
        # PermissionError because the caller doesn't own the process. This
        # function treats that as "not our daemon" and returns False so the
        # watchdog will spawn a fresh one we can manage.
        with open(self._pid_tmp.name, "w") as fh:
            fh.write(f"{os.getpid()}\n")
        with mock.patch("os.kill", side_effect=PermissionError("EPERM")):
            self.assertFalse(_server._collector_pid_alive())

    def test_ensure_running_throttled_within_cooldown(self):
        # Force the throttle to a recent timestamp so the second call is a no-op.
        _server._ccusage_last_respawn_at = time.time()
        # PID file points at a dead process so the function would otherwise spawn.
        with open(self._pid_tmp.name, "w") as fh:
            fh.write("2147483646\n")
        # Should return False (throttled) without invoking subprocess.
        self.assertFalse(_server._ensure_collector_running())

    def test_ensure_running_returns_true_when_already_alive(self):
        with open(self._pid_tmp.name, "w") as fh:
            fh.write(f"{os.getpid()}\n")
        # Should short-circuit on the kill -0 fast path, no subprocess.
        self.assertTrue(_server._ensure_collector_running())


if __name__ == "__main__":
    unittest.main()
