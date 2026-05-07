#
#  test_ccusage_heuristics.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""Unit tests for ``ccusage_heuristics``.

Run with:
    cd /Users/darrenehlers/dev-team/worktrees/xaca-0243
    python3 -m unittest lcars-ui.tests.test_ccusage_heuristics -v

These tests cover every documented edge case plus the band boundary values.
All inputs are constructed by hand — no fixtures from disk, no real ccusage
invocations.
"""

from __future__ import annotations

import os
import sys
import unittest

# Make the lcars-ui package importable regardless of cwd. The test runner
# imports this file as ``lcars-ui.tests.test_ccusage_heuristics`` from the
# worktree root, but a direct ``python3 path/to/this/file.py`` should also
# work, hence the explicit path injection.
_HERE = os.path.dirname(os.path.abspath(__file__))
_LCARS_UI = os.path.dirname(_HERE)
if _LCARS_UI not in sys.path:
    sys.path.insert(0, _LCARS_UI)

import ccusage_heuristics as ch  # noqa: E402


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
    """Helper: build a daemon-cache-shaped dict with sensible defaults."""
    return {
        "schema_version": 1,
        "collected_at_unix": collected_at_unix,
        "ccusage_ok": ccusage_ok,
        "ccusage_error": ccusage_error,
        "active_window": active_window,
        "history": history if history is not None else [],
        "calibration": calibration
        if calibration is not None
        else {
            "max_window_tokens": 300_000_000,
            "max_window_cost_usd": 200.0,
            "max_window_id": "abc",
            "p90_window_tokens": 130_000_000,
            "samples": 47,
        },
        "totals": totals
        if totals is not None
        else {
            "today_tokens": 5_000_000,
            "today_cost_usd": 4.20,
            "last_7d_tokens": 30_000_000,
            "last_7d_cost_usd": 25.0,
        },
    }


_DEFAULT_PROJECTION = object()  # sentinel: distinguishes "omitted" from "explicit None"


def _make_active_window(
    *,
    elapsed_minutes: int = 49,
    remaining_minutes: int = 250,
    total_tokens: int = 14_891_570,
    cost_usd: float = 12.84,
    tokens_per_minute: float = 318_374.86,
    cost_per_hour: float = 16.47,
    projection=_DEFAULT_PROJECTION,
) -> dict:
    if projection is _DEFAULT_PROJECTION:
        projection = {
            "total_tokens": 94_603_120,
            "total_cost_usd": 81.57,
            "remaining_minutes": remaining_minutes,
        }
    return {
        "id": "win-1",
        "start_time": "2026-04-26T10:00:00Z",
        "end_time": "2026-04-26T15:00:00Z",
        "elapsed_minutes": elapsed_minutes,
        "remaining_minutes": remaining_minutes,
        "total_tokens": total_tokens,
        "cost_usd": cost_usd,
        "models": ["claude-opus-4"],
        "burn_rate": {
            "tokens_per_minute": tokens_per_minute,
            "cost_per_hour": cost_per_hour,
        },
        "projection": projection,
    }


class ClassifyBandTests(unittest.TestCase):
    """Boundary tests for the band cutoffs."""

    def test_green_below_60(self):
        self.assertEqual(ch.classify_band(0.0), "GREEN")
        self.assertEqual(ch.classify_band(59.9), "GREEN")

    def test_amber_at_60_boundary(self):
        # 60.0 is the inclusive lower bound of AMBER.
        self.assertEqual(ch.classify_band(60.0), "AMBER")
        self.assertEqual(ch.classify_band(84.9), "AMBER")

    def test_red_at_85_boundary(self):
        # 85.0 is the inclusive lower bound of RED.
        self.assertEqual(ch.classify_band(85.0), "RED")
        self.assertEqual(ch.classify_band(150.0), "RED")


class EvaluateNoCacheTests(unittest.TestCase):
    """Cache missing entirely."""

    def test_none_cache_returns_unusable_response(self):
        out = ch.evaluate(None, now_unix=1_714_000_100)
        self.assertFalse(out["ok"])
        self.assertTrue(out["stale"])
        self.assertIsNone(out["current"])
        self.assertIsNone(out["projection"])
        self.assertEqual(out["history"], [])
        self.assertEqual(out["calibration"]["confidence"], "LOW")
        self.assertEqual(out["calibration"]["samples"], 0)


class EvaluateCcusageErrorTests(unittest.TestCase):
    """``ccusage_ok=False`` should surface error, retain calibration/history."""

    def test_ccusage_error_surfaces_but_keeps_calibration(self):
        cache = _make_cache(
            ccusage_ok=False,
            ccusage_error="ccusage exited 1: command not found",
            active_window=None,
        )
        out = ch.evaluate(cache, now_unix=1_714_000_030)
        self.assertFalse(out["ok"])
        self.assertEqual(out["ccusage_error"], "ccusage exited 1: command not found")
        # Calibration is still passed through so the UI is not blank.
        self.assertEqual(out["calibration"]["samples"], 47)
        self.assertEqual(out["calibration"]["confidence"], "HIGH")
        self.assertIsNone(out["projection"])

    def test_ccusage_error_with_last_known_active_window(self):
        cache = _make_cache(
            ccusage_ok=False,
            ccusage_error="transient",
            active_window=_make_active_window(),
        )
        out = ch.evaluate(cache, now_unix=1_714_000_030)
        # Even on error we keep last-known current data.
        self.assertIsNotNone(out["current"])
        self.assertTrue(out["current"]["in_window"])
        # But projection is suppressed when ccusage isn't OK.
        self.assertIsNone(out["projection"])


class EvaluateNoActiveWindowTests(unittest.TestCase):
    """Between windows: ``current.in_window=False``, no projection."""

    def test_active_window_none(self):
        cache = _make_cache(active_window=None)
        out = ch.evaluate(cache, now_unix=1_714_000_030)
        self.assertTrue(out["ok"])
        self.assertIsNone(out["current"])
        self.assertIsNone(out["projection"])


class EvaluateLowSamplesTests(unittest.TestCase):
    """``calibration.samples < 5`` should suppress band classification."""

    def test_zero_samples_yields_unknown_band(self):
        cache = _make_cache(
            active_window=_make_active_window(),
            calibration={
                "max_window_tokens": 0,
                "max_window_cost_usd": 0.0,
                "max_window_id": None,
                "p90_window_tokens": 0,
                "samples": 0,
            },
        )
        out = ch.evaluate(cache, now_unix=1_714_000_030)
        self.assertEqual(out["calibration"]["confidence"], "LOW")
        self.assertEqual(out["current"]["band"], "UNKNOWN")
        # Projection still computed but its band is also UNKNOWN.
        self.assertIsNotNone(out["projection"])
        self.assertEqual(out["projection"]["projected_band"], "UNKNOWN")

    def test_three_samples_still_unknown(self):
        cache = _make_cache(
            active_window=_make_active_window(),
            calibration={
                "max_window_tokens": 100_000_000,
                "max_window_cost_usd": 90.0,
                "max_window_id": "x",
                "p90_window_tokens": 80_000_000,
                "samples": 3,
            },
        )
        out = ch.evaluate(cache, now_unix=1_714_000_030)
        self.assertEqual(out["calibration"]["confidence"], "LOW")
        self.assertEqual(out["current"]["band"], "UNKNOWN")

    def test_five_samples_promotes_to_medium(self):
        cache = _make_cache(
            active_window=_make_active_window(),
            calibration={
                "max_window_tokens": 100_000_000,
                "max_window_cost_usd": 90.0,
                "max_window_id": "x",
                "p90_window_tokens": 80_000_000,
                "samples": 5,
            },
        )
        out = ch.evaluate(cache, now_unix=1_714_000_030)
        self.assertEqual(out["calibration"]["confidence"], "MEDIUM")
        # Now band classification is allowed (14.89M / 100M ~= 14.9% -> GREEN).
        self.assertEqual(out["current"]["band"], "GREEN")


class EvaluateStaleTests(unittest.TestCase):
    """Cache older than threshold should mark stale + projection untrusted.

    STALE_THRESHOLD_SECONDS is 300 (5 minutes). Boundary values: 299 (fresh),
    300 (stale), 301 (stale). This replaces the old 119/120/121 boundary tests
    from when the threshold was 120s (XACA-0243-006).
    """

    def test_cache_at_299s_is_fresh(self):
        cache = _make_cache(
            collected_at_unix=1_714_000_000,
            active_window=_make_active_window(),
        )
        # 299 seconds later — below the 300s threshold (condition is strictly >).
        out = ch.evaluate(cache, now_unix=1_714_000_299)
        self.assertFalse(out["stale"])
        self.assertTrue(out["ok"])
        self.assertEqual(out["stale_age_seconds"], 299)
        self.assertTrue(out["projection"]["trustworthy"])

    def test_cache_at_300s_is_fresh(self):
        cache = _make_cache(
            collected_at_unix=1_714_000_000,
            active_window=_make_active_window(),
        )
        # Exactly 300 seconds later — NOT stale yet; staleness requires strictly > 300.
        out = ch.evaluate(cache, now_unix=1_714_000_300)
        self.assertFalse(out["stale"])
        self.assertTrue(out["ok"])
        self.assertEqual(out["stale_age_seconds"], 300)
        self.assertTrue(out["projection"]["trustworthy"])

    def test_cache_at_301s_is_stale(self):
        cache = _make_cache(
            collected_at_unix=1_714_000_000,
            active_window=_make_active_window(),
        )
        # 301 seconds later — one second past the 300s threshold; now stale.
        out = ch.evaluate(cache, now_unix=1_714_000_301)
        self.assertTrue(out["stale"])
        self.assertFalse(out["ok"])
        self.assertEqual(out["stale_age_seconds"], 301)
        self.assertIsNotNone(out["projection"])
        self.assertFalse(out["projection"]["trustworthy"])

    def test_cache_older_than_threshold_is_stale(self):
        cache = _make_cache(
            collected_at_unix=1_714_000_000,
            active_window=_make_active_window(),
        )
        # 600 seconds later — well past the 300s threshold.
        out = ch.evaluate(cache, now_unix=1_714_000_600)
        self.assertTrue(out["stale"])
        self.assertFalse(out["ok"])
        self.assertEqual(out["stale_age_seconds"], 600)
        # Projection is emitted but flagged untrustworthy.
        self.assertIsNotNone(out["projection"])
        self.assertFalse(out["projection"]["trustworthy"])

    def test_fresh_cache_is_not_stale(self):
        cache = _make_cache(active_window=_make_active_window())
        out = ch.evaluate(cache, now_unix=1_714_000_030)
        self.assertFalse(out["stale"])
        self.assertTrue(out["ok"])
        self.assertEqual(out["stale_age_seconds"], 30)
        self.assertTrue(out["projection"]["trustworthy"])


class EvaluateLowElapsedTests(unittest.TestCase):
    """Less than ``PROJECTION_MIN_ELAPSED_MINUTES`` -> projection=None."""

    def test_elapsed_below_threshold_suppresses_projection(self):
        cache = _make_cache(active_window=_make_active_window(elapsed_minutes=4))
        out = ch.evaluate(cache, now_unix=1_714_000_030)
        self.assertIsNotNone(out["current"])
        self.assertIsNone(out["projection"])

    def test_elapsed_at_threshold_allows_projection(self):
        cache = _make_cache(active_window=_make_active_window(elapsed_minutes=5))
        out = ch.evaluate(cache, now_unix=1_714_000_030)
        self.assertIsNotNone(out["projection"])


class ProjectionMathTests(unittest.TestCase):
    """``compute_projection`` direct tests."""

    def test_zero_burn_rate_yields_no_minutes_to_cap(self):
        active = _make_active_window(tokens_per_minute=0.0, projection=None)
        cal = {"max_window_tokens": 100_000_000, "samples": 47}
        proj = ch.compute_projection(active, cal)
        self.assertIsNotNone(proj)
        self.assertIsNone(proj["minutes_to_cap"])
        self.assertFalse(proj["will_hit_cap"])

    def test_high_burn_predicts_cap_hit(self):
        # 5M used + 1M/min burn for 250 remaining = 255M projected vs 100M cap.
        active = _make_active_window(
            elapsed_minutes=10,
            remaining_minutes=250,
            total_tokens=5_000_000,
            tokens_per_minute=1_000_000.0,
            projection=None,  # force fallback math
        )
        cal = {"max_window_tokens": 100_000_000, "samples": 47}
        proj = ch.compute_projection(active, cal)
        self.assertIsNotNone(proj)
        self.assertTrue(proj["will_hit_cap"])
        # (100M - 5M) / 1M = 95 minutes
        self.assertAlmostEqual(proj["minutes_to_cap"], 95.0, places=2)

    def test_prefers_ccusage_projection_when_present(self):
        active = _make_active_window(
            projection={
                "total_tokens": 999_999,
                "total_cost_usd": 7.77,
                "remaining_minutes": 250,
            }
        )
        cal = {"max_window_tokens": 300_000_000, "samples": 47}
        proj = ch.compute_projection(active, cal)
        self.assertEqual(proj["projected_tokens"], 999_999)
        self.assertEqual(proj["projected_cost_usd"], 7.77)


class HistoryTests(unittest.TestCase):
    """History should drop gaps, cap at 7, attach bands."""

    def test_drops_gaps_and_caps_at_seven(self):
        history = []
        # 10 entries, every 3rd is a gap.
        for i in range(10):
            history.append(
                {
                    "id": f"w{i}",
                    "start_time": f"2026-04-2{i % 9}T00:00:00Z",
                    "end_time": f"2026-04-2{i % 9}T05:00:00Z",
                    "total_tokens": 50_000_000 + i * 1_000_000,
                    "cost_usd": 40.0 + i,
                    "is_gap": (i % 3 == 0),
                }
            )
        cache = _make_cache(history=history, active_window=None)
        out = ch.evaluate(cache, now_unix=1_714_000_030)
        # i in [0..9], gap when i % 3 == 0 -> gaps at 0,3,6,9 -> 6 non-gaps.
        # 6 < the 7-entry cap, so all 6 non-gaps survive.
        self.assertEqual(len(out["history"]), 6)
        self.assertTrue(all(not w["is_gap"] for w in out["history"]))
        for w in out["history"]:
            self.assertIn(w["band"], {"GREEN", "AMBER", "RED", "UNKNOWN"})

    def test_history_caps_at_seven_when_more_available(self):
        # 12 non-gap entries -> trimmed to last 7.
        history = [
            {
                "id": f"w{i}",
                "start_time": "2026-04-20T00:00:00Z",
                "end_time": "2026-04-20T05:00:00Z",
                "total_tokens": 50_000_000 + i * 1_000_000,
                "cost_usd": 40.0,
                "is_gap": False,
            }
            for i in range(12)
        ]
        cache = _make_cache(history=history, active_window=None)
        out = ch.evaluate(cache, now_unix=1_714_000_030)
        self.assertEqual(len(out["history"]), 7)
        self.assertEqual(out["history"][0]["id"], "w5")
        self.assertEqual(out["history"][-1]["id"], "w11")


class TotalsPassthroughTest(unittest.TestCase):
    """Totals dict should pass through unchanged."""

    def test_totals_passthrough(self):
        totals = {
            "today_tokens": 7_777_777,
            "today_cost_usd": 6.66,
            "last_7d_tokens": 88_888_888,
            "last_7d_cost_usd": 99.99,
        }
        cache = _make_cache(totals=totals, active_window=_make_active_window())
        out = ch.evaluate(cache, now_unix=1_714_000_030)
        self.assertEqual(out["totals"], totals)


class CurrentBandBoundaryTests(unittest.TestCase):
    """Verify ``current.band`` respects the same boundaries as classify_band."""

    def _eval_at_pct(self, pct: float, samples: int = 47) -> dict:
        max_tokens = 100_000_000
        tokens_used = int(max_tokens * pct / 100.0)
        cache = _make_cache(
            active_window=_make_active_window(
                total_tokens=tokens_used,
                projection={
                    "total_tokens": tokens_used,
                    "total_cost_usd": 1.0,
                    "remaining_minutes": 250,
                },
            ),
            calibration={
                "max_window_tokens": max_tokens,
                "max_window_cost_usd": 90.0,
                "max_window_id": "x",
                "p90_window_tokens": 80_000_000,
                "samples": samples,
            },
        )
        return ch.evaluate(cache, now_unix=1_714_000_030)

    def test_current_band_just_below_amber(self):
        out = self._eval_at_pct(59.9)
        self.assertEqual(out["current"]["band"], "GREEN")

    def test_current_band_at_amber_boundary(self):
        out = self._eval_at_pct(60.0)
        self.assertEqual(out["current"]["band"], "AMBER")

    def test_current_band_just_below_red(self):
        out = self._eval_at_pct(84.9)
        self.assertEqual(out["current"]["band"], "AMBER")

    def test_current_band_at_red_boundary(self):
        out = self._eval_at_pct(85.0)
        self.assertEqual(out["current"]["band"], "RED")


class ProjectedBandEarlyWarningTest(unittest.TestCase):
    """Verify projected_band drives early warning even when current is GREEN."""

    def test_low_current_high_projected_yields_red_projection(self):
        # Current 5% but projecting 95% — projected_band should be RED.
        active = _make_active_window(
            elapsed_minutes=15,
            remaining_minutes=285,
            total_tokens=5_000_000,
            projection={
                "total_tokens": 95_000_000,  # 95% of 100M cap
                "total_cost_usd": 80.0,
                "remaining_minutes": 285,
            },
        )
        cache = _make_cache(
            active_window=active,
            calibration={
                "max_window_tokens": 100_000_000,
                "max_window_cost_usd": 90.0,
                "max_window_id": "x",
                "p90_window_tokens": 80_000_000,
                "samples": 47,
            },
        )
        out = ch.evaluate(cache, now_unix=1_714_000_030)
        self.assertEqual(out["current"]["band"], "GREEN")
        self.assertEqual(out["projection"]["projected_band"], "RED")
        self.assertTrue(out["projection"]["trustworthy"])


if __name__ == "__main__":
    unittest.main()
