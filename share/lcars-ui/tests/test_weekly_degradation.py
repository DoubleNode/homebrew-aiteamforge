#
#  test_weekly_degradation.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""Degradation tests for weekly-limit display (XACA-0250-006).

Covers every failure path documented in the graceful-degradation spec:
  - evaluate_weekly() with cache containing weekly=null
  - evaluate_weekly() with weekly present but current_week missing
  - evaluate_weekly() with last_collected_at >10 min old (stale=True)
  - evaluate_weekly() with empty history (confidence=LOW)
  - API endpoint: cache file missing -> graceful 200, weekly sentinel included
  - API endpoint: schema v1 cache -> weekly sentinel with reason
  - API endpoint: malformed JSON cache -> weekly sentinel included
  - API endpoint: ccusage_ok=False cache -> weekly evaluated gracefully

Run with:
    cd /Users/darrenehlers/dev-team/worktrees/xaca-0250
    python3 -m pytest lcars-ui/tests/test_weekly_degradation.py -v
"""

from __future__ import annotations

import datetime
import json
import os
import sys
import tempfile
import time
import unittest

# Make lcars-ui importable regardless of cwd.
_HERE = os.path.dirname(os.path.abspath(__file__))
_LCARS_UI = os.path.dirname(_HERE)
if _LCARS_UI not in sys.path:
    sys.path.insert(0, _LCARS_UI)

import ccusage_heuristics as ch    # noqa: E402
import server as _server            # noqa: E402

_UTC = datetime.timezone.utc
_NOW = datetime.datetime(2026, 4, 28, 12, 0, 0, tzinfo=_UTC)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_v2_cache(
    *,
    weekly=None,
    weekly_error=None,
    schema_version=2,
    ccusage_ok=True,
) -> dict:
    """Minimal cache dict. weekly=None simulates failed collection."""
    return {
        "schema_version": schema_version,
        "collected_at_unix": int(_NOW.timestamp()),
        "ccusage_ok": ccusage_ok,
        "ccusage_error": None,
        "active_window": None,
        "history": [],
        "calibration": {
            "max_window_tokens": 0,
            "max_window_cost_usd": 0.0,
            "max_window_id": "",
            "p90_window_tokens": 0,
            "samples": 0,
        },
        "totals": {
            "today_tokens": 0,
            "today_cost_usd": 0.0,
            "last_7d_tokens": 0,
            "last_7d_cost_usd": 0.0,
        },
        "weekly": weekly,
        "weekly_error": weekly_error,
    }


def _fresh_ts() -> str:
    """Timestamp 30 seconds before _NOW — within the freshness window."""
    return (_NOW - datetime.timedelta(seconds=30)).strftime("%Y-%m-%dT%H:%M:%SZ")


def _stale_ts(seconds_old: int) -> str:
    """Timestamp ``seconds_old`` seconds before _NOW."""
    return (_NOW - datetime.timedelta(seconds=seconds_old)).strftime("%Y-%m-%dT%H:%M:%SZ")


def _weekly_block_with_history(n_history: int, current_tokens: int = 100_000) -> dict:
    """Weekly block with n_history prior-week entries and a current week."""
    history = [
        {
            "week": f"2026-{3 + (i // 4):02d}-{1 + (i % 4) * 7:02d}",
            "totalTokens": 500_000,
            "totalCost": 5.0,
        }
        for i in range(n_history)
    ]
    return {
        "last_collected_at": _fresh_ts(),
        "current_week": {
            "week": "2026-04-28",
            "totalTokens": current_tokens,
            "totalCost": 2.0,
            "modelsUsed": ["claude-opus-4"],
        },
        "history": history,
    }


# ---------------------------------------------------------------------------
# evaluate_weekly() degradation paths
# ---------------------------------------------------------------------------

class TestEvaluateWeeklyDegradation(unittest.TestCase):
    """evaluate_weekly returns {available: False, reason: ...} for all failure cases."""

    # Case A: cache is None
    def test_none_cache_is_unavailable(self):
        out = ch.evaluate_weekly(None, now_utc=_NOW)
        self.assertFalse(out["available"])
        self.assertIn("cache unavailable", out["reason"])

    # Case B: weekly key is None (collection failed, no previous weekly block)
    def test_weekly_null_in_cache_is_unavailable(self):
        cache = _make_v2_cache(weekly=None, weekly_error="ccusage weekly timed out after 240s")
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertFalse(out["available"])
        self.assertIn("timed out", out["reason"])

    # Case C: weekly key absent entirely (schema v2 cache written by older collector)
    def test_weekly_key_absent_is_unavailable(self):
        cache = {
            "schema_version": 2,
            "collected_at_unix": int(_NOW.timestamp()),
            "ccusage_ok": True,
        }
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertFalse(out["available"])

    # Case D: weekly present but current_week is None
    def test_current_week_none_is_unavailable(self):
        weekly = {
            "last_collected_at": _fresh_ts(),
            "current_week": None,
            "history": [{"week": "2026-04-21", "totalTokens": 500_000, "totalCost": 5.0}],
        }
        cache = _make_v2_cache(weekly=weekly)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertFalse(out["available"])
        self.assertIn("no current week", out["reason"])

    # Case E: weekly present but current_week key missing entirely
    def test_current_week_key_missing_is_unavailable(self):
        weekly = {
            "last_collected_at": _fresh_ts(),
            "history": [],
        }
        cache = _make_v2_cache(weekly=weekly)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertFalse(out["available"])

    # Case F: schema v1 (weekly key not supported)
    def test_schema_v1_is_unavailable(self):
        cache = _make_v2_cache(schema_version=1)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertFalse(out["available"])
        self.assertIn("schema_version", out["reason"])

    # Case G: last_collected_at is >10 min old -> stale=True (but still available)
    def test_stale_collection_returns_stale_true(self):
        weekly = _weekly_block_with_history(4)
        weekly["last_collected_at"] = _stale_ts(ch.WEEKLY_STALE_THRESHOLD_SECONDS + 1)
        cache = _make_v2_cache(weekly=weekly)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        # Still available — stale is just a freshness warning, not unavailability
        self.assertTrue(out["available"])
        self.assertTrue(out["stale"])

    # Case H: empty history -> confidence=LOW, available=True, band=UNKNOWN
    def test_empty_history_confidence_low_available_true(self):
        weekly = _weekly_block_with_history(0)
        cache = _make_v2_cache(weekly=weekly)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertTrue(out["available"])
        self.assertEqual(out["confidence"], "LOW")
        self.assertEqual(out["band"], "UNKNOWN")
        self.assertFalse(out["calibrated"])

    # Case I: 1-3 history weeks -> LOW confidence, band=UNKNOWN (hidden by UI)
    def test_one_to_three_history_weeks_is_low_confidence(self):
        for n in (1, 2, 3):
            with self.subTest(n=n):
                weekly = _weekly_block_with_history(n)
                cache = _make_v2_cache(weekly=weekly)
                out = ch.evaluate_weekly(cache, now_utc=_NOW)
                self.assertTrue(out["available"])
                self.assertEqual(out["confidence"], "LOW", f"n={n} should give LOW")
                self.assertEqual(out["band"], "UNKNOWN", f"n={n} should give UNKNOWN")

    # Case J: 4+ history weeks -> HIGH confidence, band is GREEN/AMBER/RED
    def test_four_history_weeks_is_high_confidence(self):
        weekly = _weekly_block_with_history(4, current_tokens=100_000)
        cache = _make_v2_cache(weekly=weekly)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertTrue(out["available"])
        self.assertEqual(out["confidence"], "HIGH")
        self.assertNotEqual(out["band"], "UNKNOWN")

    # Case K: last_collected_at exactly at threshold is NOT stale
    def test_at_stale_threshold_is_not_stale(self):
        weekly = _weekly_block_with_history(4)
        weekly["last_collected_at"] = _stale_ts(ch.WEEKLY_STALE_THRESHOLD_SECONDS)
        cache = _make_v2_cache(weekly=weekly)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertFalse(out["stale"])

    # Case L: missing last_collected_at timestamp -> default-stale
    def test_missing_timestamp_is_stale(self):
        weekly = _weekly_block_with_history(4)
        weekly["last_collected_at"] = ""
        cache = _make_v2_cache(weekly=weekly)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertTrue(out["stale"])

    # Case M: ccusage_ok=False but weekly block present -> weekly still evaluated
    def test_ccusage_ok_false_weekly_still_evaluated(self):
        """Weekly data is independent of the 5h blocks flow."""
        weekly = _weekly_block_with_history(4)
        cache = _make_v2_cache(weekly=weekly, ccusage_ok=False)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        # evaluate_weekly doesn't care about ccusage_ok — it only looks at the
        # weekly block and schema_version
        self.assertTrue(out["available"])

    # Case N: weekly_error present but weekly block is also present -> weekly wins
    def test_weekly_block_present_despite_weekly_error_field(self):
        """weekly_error is advisory; if weekly block exists use it."""
        weekly = _weekly_block_with_history(4)
        cache = _make_v2_cache(weekly=weekly, weekly_error="prior cycle failed")
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertTrue(out["available"])


# ---------------------------------------------------------------------------
# API endpoint: _build_usage_response degradation paths
# ---------------------------------------------------------------------------

class TestBuildUsageResponseWeeklySentinel(unittest.TestCase):
    """_build_usage_response always returns a 'weekly' key regardless of error path."""

    def _assert_weekly_sentinel(self, payload: dict, expected_reason_fragment: str | None = None) -> None:
        """Assert that payload has weekly={available:False, reason:...}."""
        self.assertIn("weekly", payload, "API response must always include 'weekly' key")
        w = payload["weekly"]
        self.assertIsNotNone(w, "'weekly' must not be None in API response")
        self.assertFalse(w.get("available", True), "'weekly.available' must be False on error paths")
        self.assertIn("reason", w, "'weekly' sentinel must include 'reason'")
        if expected_reason_fragment:
            self.assertIn(
                expected_reason_fragment, w["reason"],
                f"Expected '{expected_reason_fragment}' in reason '{w['reason']}'"
            )

    # Case 1: cache file missing -> no 500, always 200, weekly sentinel present
    def test_cache_file_missing_returns_200_with_weekly_sentinel(self):
        _server._ccusage_missing_warned = False
        status, payload = _server._build_usage_response(
            cache_path="/tmp/xaca-0250-006-does-not-exist.json"
        )
        self.assertEqual(status, 200, "Must not 500 when cache is missing")
        self.assertFalse(payload["ok"])
        self._assert_weekly_sentinel(payload, "collector not running")

    # Case 2: malformed JSON cache -> no 500, weekly sentinel present
    def test_malformed_json_cache_returns_200_with_weekly_sentinel(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            f.write("{not valid json ][")
            path = f.name
        try:
            status, payload = _server._build_usage_response(cache_path=path)
            self.assertEqual(status, 200)
            self.assertFalse(payload["ok"])
            self._assert_weekly_sentinel(payload)
        finally:
            os.unlink(path)

    # Case 3: schema v1 cache -> weekly sentinel (schema too old)
    def test_schema_v1_cache_returns_weekly_unavailable(self):
        cache = _make_v2_cache(schema_version=1)
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(cache, f)
            path = f.name
        try:
            status, payload = _server._build_usage_response(cache_path=path)
            self.assertEqual(status, 200)
            self.assertIn("weekly", payload)
            w = payload["weekly"]
            self.assertFalse(w.get("available", True))
        finally:
            os.unlink(path)

    # Case 4: v2 cache with weekly=null -> weekly sentinel with error reason
    def test_v2_cache_weekly_null_returns_sentinel_with_reason(self):
        cache = _make_v2_cache(weekly=None, weekly_error="ccusage weekly timed out")
        # Write a fresh collected_at_unix so the cache is not stale
        cache["collected_at_unix"] = int(time.time())
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(cache, f)
            path = f.name
        try:
            status, payload = _server._build_usage_response(cache_path=path)
            self.assertEqual(status, 200)
            self._assert_weekly_sentinel(payload, "timed out")
        finally:
            os.unlink(path)

    # Case 5: v2 cache with valid weekly block -> weekly.available=True
    def test_v2_cache_valid_weekly_returns_available_true(self):
        weekly = _weekly_block_with_history(4)
        cache = _make_v2_cache(weekly=weekly)
        cache["collected_at_unix"] = int(time.time())
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(cache, f)
            path = f.name
        try:
            status, payload = _server._build_usage_response(cache_path=path)
            self.assertEqual(status, 200)
            self.assertIn("weekly", payload)
            w = payload["weekly"]
            self.assertTrue(w.get("available"), "Valid weekly block should be available")
        finally:
            os.unlink(path)

    # Case 6: heuristics module unavailable path includes weekly sentinel
    def test_heuristics_unavailable_includes_weekly_sentinel(self):
        """When CCUSAGE_HEURISTICS_AVAILABLE=False, weekly sentinel is still emitted."""
        orig = _server.CCUSAGE_HEURISTICS_AVAILABLE
        try:
            _server.CCUSAA_HEURISTICS_AVAILABLE = False  # noqa — see below
            _server.CCUSAGE_HEURISTICS_AVAILABLE = False
            status, payload = _server._build_usage_response(
                cache_path="/tmp/irrelevant-for-this-test.json"
            )
            self.assertEqual(status, 200)
            self._assert_weekly_sentinel(payload)
        finally:
            _server.CCUSAGE_HEURISTICS_AVAILABLE = orig


# ---------------------------------------------------------------------------
# evaluate_weekly response shape for all unavailable paths
# ---------------------------------------------------------------------------

class TestUnavailableResponseShape(unittest.TestCase):
    """All {available: False} responses include the required keys."""

    _REQUIRED_KEYS = {"available", "reason"}

    def _check_shape(self, cache_or_none, **kwargs):
        out = ch.evaluate_weekly(cache_or_none, **kwargs)
        self.assertFalse(out["available"])
        missing = self._REQUIRED_KEYS - set(out.keys())
        self.assertEqual(missing, set(), f"Missing keys in unavailable sentinel: {missing}")

    def test_none_cache_shape(self):
        self._check_shape(None, now_utc=_NOW)

    def test_v1_schema_shape(self):
        self._check_shape(_make_v2_cache(schema_version=1), now_utc=_NOW)

    def test_weekly_null_shape(self):
        self._check_shape(_make_v2_cache(weekly=None, weekly_error="test"), now_utc=_NOW)

    def test_current_week_none_shape(self):
        weekly = {"last_collected_at": _fresh_ts(), "current_week": None, "history": []}
        self._check_shape(_make_v2_cache(weekly=weekly), now_utc=_NOW)


if __name__ == "__main__":
    unittest.main()
