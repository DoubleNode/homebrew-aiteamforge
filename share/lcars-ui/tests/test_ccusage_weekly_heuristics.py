#
#  test_ccusage_weekly_heuristics.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""Unit tests for ``ccusage_heuristics.evaluate_weekly`` (XACA-0250-003).

Run with:
    cd /Users/darrenehlers/dev-team/worktrees/xaca-0250
    python3 -m pytest lcars-ui/tests/test_ccusage_weekly_heuristics.py -v

These tests cover every documented edge case from the XACA-0250-003 spec.
All inputs are hand-constructed — no fixtures from disk, no ccusage invocations.
"""

from __future__ import annotations

import datetime
import os
import sys
import unittest

# Make lcars-ui importable regardless of cwd.
_HERE = os.path.dirname(os.path.abspath(__file__))
_LCARS_UI = os.path.dirname(_HERE)
if _LCARS_UI not in sys.path:
    sys.path.insert(0, _LCARS_UI)

import ccusage_heuristics as ch  # noqa: E402


# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------

_UTC = datetime.timezone.utc

# A Monday that is unambiguous as a week anchor.
_WEEK_ANCHOR = "2026-04-27"  # Monday 2026-04-27
_WEEK_START_DT = datetime.datetime(2026, 4, 27, 0, 0, 0, tzinfo=_UTC)
_WEEK_END_DT = _WEEK_START_DT + datetime.timedelta(days=7)

# "now" is Tuesday mid-week: 1d 6h into the week.
_NOW = datetime.datetime(2026, 4, 28, 6, 0, 0, tzinfo=_UTC)
# seconds remaining from _NOW until end-of-week = 5d 18h = 5*86400 + 18*3600
_SECONDS_REMAINING = int((_WEEK_END_DT - _NOW).total_seconds())  # 504000


def _make_current_week(
    week: str = _WEEK_ANCHOR,
    total_tokens: int = 200_000,
    total_cost: float = 4.20,
    models_used: list | None = None,
) -> dict:
    return {
        "week": week,
        "totalTokens": total_tokens,
        "totalCost": total_cost,
        "modelsUsed": models_used or ["claude-opus-4"],
    }


def _make_history(weeks: list[tuple[str, int, float]]) -> list[dict]:
    """Build history from (week, totalTokens, totalCost) tuples."""
    return [
        {"week": w, "totalTokens": t, "totalCost": c}
        for w, t, c in weeks
    ]


_SENTINEL = object()  # distinguishes "omitted" from explicit None


def _make_weekly_block(
    current_week=_SENTINEL,
    history: list | None = None,
    last_collected_at: str | None = None,
) -> dict:
    if last_collected_at is None:
        # Fresh by default: one second before _NOW.
        ts = (_NOW - datetime.timedelta(seconds=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        last_collected_at = ts
    resolved_week = _make_current_week() if current_week is _SENTINEL else current_week
    return {
        "last_collected_at": last_collected_at,
        "current_week": resolved_week,
        "history": history if history is not None else [],
    }


def _make_cache(
    *,
    schema_version: int = 2,
    weekly: dict | None | str = "default",  # "default" = auto-build; None = explicit null
    weekly_error: str | None = None,
    collected_at_unix: int | None = None,
) -> dict:
    """Build a full cache dict.

    Pass ``weekly=None`` to simulate a weekly=null cache (collection failed).
    Pass ``weekly="default"`` (or omit) to get a sane weekly block.
    Pass an explicit dict to use that block verbatim.
    """
    if weekly == "default":
        weekly_val: dict | None = _make_weekly_block()
    else:
        weekly_val = weekly  # type: ignore[assignment]

    return {
        "schema_version": schema_version,
        "collected_at_unix": collected_at_unix or int(_NOW.timestamp()),
        "ccusage_ok": True,
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
        "weekly": weekly_val,
        "weekly_error": weekly_error,
    }


# ---------------------------------------------------------------------------
# Tests: Unavailability sentinels
# ---------------------------------------------------------------------------

class TestUnavailableSentinels(unittest.TestCase):
    """evaluate_weekly returns {available: False} for various missing-data cases."""

    def test_none_cache_returns_unavailable(self):
        out = ch.evaluate_weekly(None, now_utc=_NOW)
        self.assertFalse(out["available"])
        self.assertIn("cache unavailable", out["reason"])

    def test_schema_v1_returns_unavailable(self):
        cache = _make_cache(schema_version=1)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertFalse(out["available"])
        self.assertIn("schema_version", out["reason"])
        self.assertIn("1", out["reason"])

    def test_schema_v0_returns_unavailable(self):
        cache = _make_cache(schema_version=0)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertFalse(out["available"])

    def test_weekly_null_returns_unavailable(self):
        cache = _make_cache(weekly=None, weekly_error="ccusage weekly timed out")
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertFalse(out["available"])
        self.assertIn("timed out", out["reason"])

    def test_weekly_null_no_error_field(self):
        cache = _make_cache(weekly=None, weekly_error=None)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertFalse(out["available"])
        self.assertIsNotNone(out["reason"])

    def test_weekly_missing_key_returns_unavailable(self):
        # Cache with schema v2 but no "weekly" key at all.
        cache = {
            "schema_version": 2,
            "collected_at_unix": int(_NOW.timestamp()),
            "ccusage_ok": True,
        }
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertFalse(out["available"])

    def test_current_week_none_returns_unavailable(self):
        weekly_block = _make_weekly_block(current_week=None)
        cache = _make_cache(weekly=weekly_block)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertFalse(out["available"])
        self.assertIn("no current week", out["reason"])


# ---------------------------------------------------------------------------
# Tests: Empty history (LOW confidence, no band classification, no pct)
# ---------------------------------------------------------------------------

class TestEmptyHistory(unittest.TestCase):
    """With no history weeks, calibration is off and band must be UNKNOWN."""

    def test_empty_history_calibrated_false(self):
        weekly = _make_weekly_block(history=[])
        cache = _make_cache(weekly=weekly)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertTrue(out["available"])
        self.assertFalse(out["calibrated"])

    def test_empty_history_confidence_low(self):
        weekly = _make_weekly_block(history=[])
        cache = _make_cache(weekly=weekly)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertEqual(out["confidence"], "LOW")

    def test_empty_history_band_unknown(self):
        weekly = _make_weekly_block(history=[])
        cache = _make_cache(weekly=weekly)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertEqual(out["band"], "UNKNOWN")

    def test_empty_history_tokens_cap_zero(self):
        weekly = _make_weekly_block(history=[])
        cache = _make_cache(weekly=weekly)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertEqual(out["tokens_cap"], 0)

    def test_empty_history_used_pct_zero(self):
        weekly = _make_weekly_block(history=[])
        cache = _make_cache(weekly=weekly)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertEqual(out["used_pct"], 0.0)

    def test_available_true_despite_no_history(self):
        """available=True even with empty history; band=UNKNOWN communicates uncertainty."""
        weekly = _make_weekly_block(history=[])
        cache = _make_cache(weekly=weekly)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertTrue(out["available"])


# ---------------------------------------------------------------------------
# Tests: Single history entry (cap = that entry's totalTokens)
# ---------------------------------------------------------------------------

class TestSingleHistoryEntry(unittest.TestCase):
    """Single prior week sets the cap; confidence is LOW (< 4 samples)."""

    def setUp(self):
        history = _make_history([("2026-04-20", 500_000, 10.0)])
        current = _make_current_week(total_tokens=250_000)
        self.weekly = _make_weekly_block(current_week=current, history=history)
        self.cache = _make_cache(weekly=self.weekly)

    def test_cap_equals_single_history_entry(self):
        out = ch.evaluate_weekly(self.cache, now_utc=_NOW)
        self.assertTrue(out["available"])
        self.assertEqual(out["tokens_cap"], 500_000)

    def test_calibrated_true_with_one_entry(self):
        out = ch.evaluate_weekly(self.cache, now_utc=_NOW)
        self.assertTrue(out["calibrated"])

    def test_confidence_low_with_one_entry(self):
        # 1 < 4-week HIGH threshold -> LOW
        out = ch.evaluate_weekly(self.cache, now_utc=_NOW)
        self.assertEqual(out["confidence"], "LOW")

    def test_band_unknown_with_low_confidence(self):
        # Even though 250k/500k = 50% (would be GREEN), LOW confidence -> UNKNOWN
        out = ch.evaluate_weekly(self.cache, now_utc=_NOW)
        self.assertEqual(out["band"], "UNKNOWN")

    def test_tokens_used_matches_current_week(self):
        out = ch.evaluate_weekly(self.cache, now_utc=_NOW)
        self.assertEqual(out["tokens_used"], 250_000)


# ---------------------------------------------------------------------------
# Tests: Multi-week history (cap = max)
# ---------------------------------------------------------------------------

class TestMultiWeekHistory(unittest.TestCase):
    """Multi-week history: cap = max of all history totalTokens."""

    def _make_multi(self, history_counts: list[int], current_tokens: int) -> dict:
        history = _make_history([
            (f"2026-04-{7 + i * 7:02d}", c, float(c) / 100_000)
            for i, c in enumerate(history_counts)
        ])
        current = _make_current_week(total_tokens=current_tokens)
        weekly = _make_weekly_block(current_week=current, history=history)
        return _make_cache(weekly=weekly)

    def test_cap_is_max_of_all_history(self):
        # History: [100k, 800k, 300k] -> cap = 800k
        cache = self._make_multi([100_000, 800_000, 300_000], current_tokens=400_000)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertEqual(out["tokens_cap"], 800_000)

    def test_used_pct_computed_from_max_cap(self):
        # 400k / 800k = 50%
        cache = self._make_multi([100_000, 800_000, 300_000], current_tokens=400_000)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertAlmostEqual(out["used_pct"], 50.0, places=2)

    def test_confidence_high_with_four_or_more_weeks(self):
        cache = self._make_multi([100_000, 200_000, 300_000, 400_000], current_tokens=100_000)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertEqual(out["confidence"], "HIGH")

    def test_confidence_low_with_three_weeks(self):
        cache = self._make_multi([100_000, 200_000, 300_000], current_tokens=100_000)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertEqual(out["confidence"], "LOW")


# ---------------------------------------------------------------------------
# Tests: Band thresholds (GREEN/AMBER/RED boundary cases)
# ---------------------------------------------------------------------------

class TestBandThresholds(unittest.TestCase):
    """Band classification with HIGH confidence (>= 4 history weeks)."""

    def _eval_at_pct(self, pct: float) -> dict:
        cap = 1_000_000
        tokens_used = int(cap * pct / 100.0)
        # 4 history weeks -> HIGH confidence -> band classification active
        history = _make_history([
            ("2026-03-30", cap, 10.0),
            ("2026-04-06", cap, 10.0),
            ("2026-04-13", cap, 10.0),
            ("2026-04-20", cap, 10.0),
        ])
        current = _make_current_week(total_tokens=tokens_used)
        weekly = _make_weekly_block(current_week=current, history=history)
        cache = _make_cache(weekly=weekly)
        return ch.evaluate_weekly(cache, now_utc=_NOW)

    def test_just_below_amber_is_green(self):
        out = self._eval_at_pct(59.9)
        self.assertEqual(out["band"], "GREEN")

    def test_at_amber_boundary_is_amber(self):
        out = self._eval_at_pct(60.0)
        self.assertEqual(out["band"], "AMBER")

    def test_just_below_red_is_amber(self):
        out = self._eval_at_pct(84.9)
        self.assertEqual(out["band"], "AMBER")

    def test_at_red_boundary_is_red(self):
        out = self._eval_at_pct(85.0)
        self.assertEqual(out["band"], "RED")

    def test_over_100_pct_is_red(self):
        out = self._eval_at_pct(120.0)
        self.assertEqual(out["band"], "RED")

    def test_zero_pct_is_green(self):
        out = self._eval_at_pct(0.0)
        self.assertEqual(out["band"], "GREEN")

    def test_low_confidence_suppresses_to_unknown_even_near_red(self):
        # Only 2 history weeks -> LOW confidence -> UNKNOWN regardless of pct.
        cap = 1_000_000
        history = _make_history([
            ("2026-04-13", cap, 10.0),
            ("2026-04-20", cap, 10.0),
        ])
        current = _make_current_week(total_tokens=int(cap * 0.90))  # 90% -> would be RED
        weekly = _make_weekly_block(current_week=current, history=history)
        cache = _make_cache(weekly=weekly)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertEqual(out["band"], "UNKNOWN")


# ---------------------------------------------------------------------------
# Tests: Time-to-reset
# ---------------------------------------------------------------------------

class TestTimeToReset(unittest.TestCase):
    """seconds_remaining and time_to_reset are computed from week anchor + now_utc."""

    def _eval_at_now(self, now_utc: datetime.datetime) -> dict:
        current = _make_current_week(week=_WEEK_ANCHOR)
        weekly = _make_weekly_block(current_week=current)
        cache = _make_cache(weekly=weekly)
        return ch.evaluate_weekly(cache, now_utc=now_utc)

    def test_seconds_remaining_mid_week(self):
        out = self._eval_at_now(_NOW)
        self.assertEqual(out["seconds_remaining"], _SECONDS_REMAINING)

    def test_time_to_reset_multi_day(self):
        # _NOW is Tuesday, 1d 6h into the week -> 5d 18h remaining.
        out = self._eval_at_now(_NOW)
        self.assertEqual(out["time_to_reset"], "5d 18h")

    def test_time_to_reset_sub_hour(self):
        # 50 minutes before week end.
        near_end = _WEEK_END_DT - datetime.timedelta(minutes=50)
        out = self._eval_at_now(near_end)
        self.assertEqual(out["seconds_remaining"], 50 * 60)
        self.assertEqual(out["time_to_reset"], "50m")

    def test_time_to_reset_exactly_zero_at_week_end(self):
        out = self._eval_at_now(_WEEK_END_DT)
        self.assertEqual(out["seconds_remaining"], 0)
        self.assertEqual(out["time_to_reset"], "0m")

    def test_time_to_reset_past_week_end_clamps_to_zero(self):
        # 2 days after week end — seconds_remaining must not go negative.
        past = _WEEK_END_DT + datetime.timedelta(days=2)
        out = self._eval_at_now(past)
        self.assertEqual(out["seconds_remaining"], 0)
        self.assertEqual(out["time_to_reset"], "0m")

    def test_time_to_reset_just_over_one_day(self):
        # 1d 2h remaining
        t = _WEEK_END_DT - datetime.timedelta(days=1, hours=2)
        out = self._eval_at_now(t)
        self.assertEqual(out["seconds_remaining"], 1 * 86400 + 2 * 3600)
        self.assertEqual(out["time_to_reset"], "1d 2h")

    def test_time_to_reset_exactly_one_hour(self):
        t = _WEEK_END_DT - datetime.timedelta(hours=1)
        out = self._eval_at_now(t)
        self.assertEqual(out["time_to_reset"], "1h")

    def test_time_to_reset_less_than_one_minute(self):
        t = _WEEK_END_DT - datetime.timedelta(seconds=45)
        out = self._eval_at_now(t)
        self.assertEqual(out["time_to_reset"], "45s")


# ---------------------------------------------------------------------------
# Tests: Stale detection
# ---------------------------------------------------------------------------

class TestStaleDetection(unittest.TestCase):
    """weekly.last_collected_at older than WEEKLY_STALE_THRESHOLD_SECONDS -> stale=True."""

    def _eval_with_age(self, age_seconds: int) -> dict:
        collected_at_dt = _NOW - datetime.timedelta(seconds=age_seconds)
        last_collected_at = collected_at_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
        weekly = _make_weekly_block(last_collected_at=last_collected_at)
        cache = _make_cache(weekly=weekly)
        return ch.evaluate_weekly(cache, now_utc=_NOW)

    def test_fresh_cache_not_stale(self):
        out = self._eval_with_age(60)  # 1 minute old
        self.assertFalse(out["stale"])

    def test_at_threshold_boundary_is_fresh(self):
        # Exactly at WEEKLY_STALE_THRESHOLD_SECONDS (600) is NOT stale (strictly >).
        out = self._eval_with_age(ch.WEEKLY_STALE_THRESHOLD_SECONDS)
        self.assertFalse(out["stale"])

    def test_one_second_past_threshold_is_stale(self):
        out = self._eval_with_age(ch.WEEKLY_STALE_THRESHOLD_SECONDS + 1)
        self.assertTrue(out["stale"])

    def test_very_old_cache_is_stale(self):
        out = self._eval_with_age(3600)  # 1 hour
        self.assertTrue(out["stale"])

    def test_missing_last_collected_at_is_stale(self):
        weekly = _make_weekly_block(last_collected_at="")
        cache = _make_cache(weekly=weekly)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertTrue(out["stale"])

    def test_unparseable_last_collected_at_is_stale(self):
        weekly = _make_weekly_block(last_collected_at="not-a-timestamp")
        cache = _make_cache(weekly=weekly)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertTrue(out["stale"])


# ---------------------------------------------------------------------------
# Tests: Format time-to-reset helper (direct)
# ---------------------------------------------------------------------------

class TestFormatTimeToReset(unittest.TestCase):
    """Unit tests for the _format_time_to_reset helper."""

    def test_zero_seconds(self):
        self.assertEqual(ch._format_time_to_reset(0), "0m")

    def test_negative_seconds(self):
        self.assertEqual(ch._format_time_to_reset(-100), "0m")

    def test_45_seconds(self):
        self.assertEqual(ch._format_time_to_reset(45), "45s")

    def test_60_seconds(self):
        self.assertEqual(ch._format_time_to_reset(60), "1m")

    def test_90_seconds(self):
        self.assertEqual(ch._format_time_to_reset(90), "1m 30s")

    def test_1_hour(self):
        self.assertEqual(ch._format_time_to_reset(3600), "1h")

    def test_1_hour_1_minute(self):
        self.assertEqual(ch._format_time_to_reset(3660), "1h 1m")

    def test_1_day(self):
        self.assertEqual(ch._format_time_to_reset(86400), "1d")

    def test_1_day_1_hour(self):
        self.assertEqual(ch._format_time_to_reset(86400 + 3600), "1d 1h")

    def test_multi_day_no_hour(self):
        self.assertEqual(ch._format_time_to_reset(2 * 86400), "2d")

    def test_exact_minutes_no_seconds(self):
        self.assertEqual(ch._format_time_to_reset(5 * 60), "5m")


# ---------------------------------------------------------------------------
# Tests: Response shape completeness
# ---------------------------------------------------------------------------

class TestResponseShape(unittest.TestCase):
    """Available response must contain all required keys."""

    _REQUIRED_KEYS = {
        "available", "used_pct", "band", "time_to_reset",
        "seconds_remaining", "tokens_used", "tokens_cap",
        "calibrated", "confidence", "stale",
    }

    def test_full_response_has_all_required_keys(self):
        history = _make_history([
            ("2026-04-06", 400_000, 8.0),
            ("2026-04-13", 500_000, 10.0),
            ("2026-04-20", 600_000, 12.0),
            ("2026-04-27", 450_000, 9.0),
        ])
        current = _make_current_week(total_tokens=300_000)
        weekly = _make_weekly_block(current_week=current, history=history)
        cache = _make_cache(weekly=weekly)
        out = ch.evaluate_weekly(cache, now_utc=_NOW)
        self.assertTrue(out["available"])
        missing = self._REQUIRED_KEYS - set(out.keys())
        self.assertEqual(missing, set(), f"Missing keys: {missing}")

    def test_unavailable_response_has_available_and_reason(self):
        out = ch.evaluate_weekly(None, now_utc=_NOW)
        self.assertIn("available", out)
        self.assertIn("reason", out)
        self.assertFalse(out["available"])


if __name__ == "__main__":
    unittest.main()


# ---------------------------------------------------------------------------
# Tests: Weekly anchor I/O helpers (XACA-0253-001) — pytest-style
# ---------------------------------------------------------------------------

import pytest  # noqa: E402 (pytest import for tmp_path / monkeypatch fixtures)


class TestReadWeeklyAnchor:
    """read_weekly_anchor() returns dict on success, None on missing/malformed."""

    def test_read_anchor_missing_returns_none(self, tmp_path):
        path = tmp_path / "weekly-anchor.json"
        # File does not exist — should return None without raising.
        result = ch.read_weekly_anchor(_path=path)
        assert result is None

    def test_read_anchor_malformed_json_returns_none(self, tmp_path):
        path = tmp_path / "weekly-anchor.json"
        path.write_text("not valid json", encoding="utf-8")
        result = ch.read_weekly_anchor(_path=path)
        assert result is None

    def test_read_anchor_wrong_schema_version_returns_none(self, tmp_path):
        import json as _json
        path = tmp_path / "weekly-anchor.json"
        path.write_text(
            _json.dumps({
                "version": 99,
                "set_at": "2026-04-28T23:00:00.000Z",
                "reset_at": "2026-04-29T05:00:00.000Z",
                "set_hours": 6,
                "set_minutes": 0,
                "source": "manual",
            }),
            encoding="utf-8",
        )
        result = ch.read_weekly_anchor(_path=path)
        assert result is None

    def test_read_anchor_missing_timestamps_returns_none(self, tmp_path):
        import json as _json
        path = tmp_path / "weekly-anchor.json"
        path.write_text(_json.dumps({"version": 1}), encoding="utf-8")
        result = ch.read_weekly_anchor(_path=path)
        assert result is None


class TestWriteWeeklyAnchor:
    """write_weekly_anchor() atomic round-trip and validation."""

    def test_write_anchor_atomic_roundtrip(self, tmp_path):
        path = tmp_path / "weekly-anchor.json"
        now = datetime.datetime(2026, 4, 28, 20, 0, 0, tzinfo=datetime.timezone.utc)
        record = ch.write_weekly_anchor(5, 50, now_utc=now, _path=path)

        # Returns a valid record.
        assert record["set_hours"] == 5
        assert record["set_minutes"] == 50
        assert record["source"] == "manual"

        # reset_at = now + 5h50m
        expected_reset = now + datetime.timedelta(hours=5, minutes=50)
        assert record["reset_at"] == expected_reset

        # File was written.
        assert path.exists()

        # Round-trip: re-read matches what was written.
        read_back = ch.read_weekly_anchor(_path=path)
        assert read_back is not None
        assert read_back["set_hours"] == 5
        assert read_back["set_minutes"] == 50
        assert read_back["reset_at"] == expected_reset

    def test_write_anchor_creates_parent_dir(self, tmp_path):
        nested = tmp_path / "a" / "b" / "weekly-anchor.json"
        now = datetime.datetime(2026, 4, 28, 20, 0, 0, tzinfo=datetime.timezone.utc)
        ch.write_weekly_anchor(1, 0, now_utc=now, _path=nested)
        assert nested.exists()

    def test_write_anchor_validates_hours_too_large(self, tmp_path):
        path = tmp_path / "weekly-anchor.json"
        with pytest.raises(ValueError, match="hours"):
            ch.write_weekly_anchor(169, 0, _path=path)

    def test_write_anchor_validates_hours_negative(self, tmp_path):
        path = tmp_path / "weekly-anchor.json"
        with pytest.raises(ValueError, match="hours"):
            ch.write_weekly_anchor(-1, 0, _path=path)

    def test_write_anchor_validates_minutes_too_large(self, tmp_path):
        path = tmp_path / "weekly-anchor.json"
        with pytest.raises(ValueError, match="minutes"):
            ch.write_weekly_anchor(0, 60, _path=path)

    def test_write_anchor_validates_zero_total(self, tmp_path):
        path = tmp_path / "weekly-anchor.json"
        with pytest.raises(ValueError, match="total duration"):
            ch.write_weekly_anchor(0, 0, _path=path)

    def test_write_anchor_168_hours_is_valid(self, tmp_path):
        path = tmp_path / "weekly-anchor.json"
        now = datetime.datetime(2026, 4, 28, 0, 0, 0, tzinfo=datetime.timezone.utc)
        record = ch.write_weekly_anchor(168, 0, now_utc=now, _path=path)
        assert record["set_hours"] == 168

    def test_write_anchor_rejects_bool_hours(self, tmp_path):
        # bool is a subclass of int in Python — must be rejected explicitly.
        path = tmp_path / "weekly-anchor.json"
        with pytest.raises(ValueError, match="must be integers, not bool"):
            ch.write_weekly_anchor(True, 30, _path=path)

    def test_write_anchor_rejects_bool_minutes(self, tmp_path):
        path = tmp_path / "weekly-anchor.json"
        with pytest.raises(ValueError, match="must be integers, not bool"):
            ch.write_weekly_anchor(5, False, _path=path)

    def test_write_anchor_no_temp_file_left_on_success(self, tmp_path):
        # tempfile.mkstemp creates a unique temp file; verify it's cleaned up
        # by os.replace() and no stray *.tmp file is left in the directory.
        path = tmp_path / "weekly-anchor.json"
        ch.write_weekly_anchor(5, 30, _path=path)
        leftover = list(tmp_path.glob("*.tmp"))
        assert leftover == [], f"Stray temp files found: {leftover}"


class TestDeleteWeeklyAnchor:
    """delete_weekly_anchor() removes file and returns correct bool."""

    def test_delete_anchor_removes_file(self, tmp_path):
        path = tmp_path / "weekly-anchor.json"
        now = datetime.datetime(2026, 4, 28, 20, 0, 0, tzinfo=datetime.timezone.utc)
        ch.write_weekly_anchor(1, 0, now_utc=now, _path=path)
        assert path.exists()

        result = ch.delete_weekly_anchor(_path=path)
        assert result is True
        assert not path.exists()

    def test_delete_anchor_missing_returns_false(self, tmp_path):
        path = tmp_path / "does-not-exist.json"
        result = ch.delete_weekly_anchor(_path=path)
        assert result is False


# ---------------------------------------------------------------------------
# Tests: evaluate_weekly anchor state machine (XACA-0253-002) — pytest-style
# ---------------------------------------------------------------------------

def _make_standard_cache(now: datetime.datetime) -> dict:
    """Build a v2 cache with 4-week history (HIGH confidence) for anchor tests."""
    ts = (now - datetime.timedelta(seconds=60)).strftime("%Y-%m-%dT%H:%M:%SZ")
    cap = 1_000_000
    history = [
        {"week": "2026-03-30", "totalTokens": cap, "totalCost": 10.0},
        {"week": "2026-04-06", "totalTokens": cap, "totalCost": 10.0},
        {"week": "2026-04-13", "totalTokens": cap, "totalCost": 10.0},
        {"week": "2026-04-20", "totalTokens": cap, "totalCost": 10.0},
    ]
    current_week = {
        "week": "2026-04-27",
        "totalTokens": 400_000,
        "totalCost": 4.0,
        "modelsUsed": ["claude-opus-4"],
    }
    return {
        "schema_version": 2,
        "collected_at_unix": int(now.timestamp()),
        "ccusage_ok": True,
        "ccusage_error": None,
        "active_window": None,
        "history": [],
        "calibration": {"max_window_tokens": 0, "max_window_cost_usd": 0.0,
                        "max_window_id": "", "p90_window_tokens": 0, "samples": 0},
        "totals": {},
        "weekly": {
            "last_collected_at": ts,
            "current_week": current_week,
            "history": history,
        },
        "weekly_error": None,
    }


class TestEvaluateWeeklyAnchorStateMachine:
    """evaluate_weekly consults anchor first, ISO-week only as fallback."""

    def test_evaluate_weekly_uses_manual_anchor_when_present(self, tmp_path, monkeypatch):
        now = datetime.datetime(2026, 4, 28, 20, 0, 0, tzinfo=datetime.timezone.utc)
        anchor_path = tmp_path / "weekly-anchor.json"

        # Write anchor with 3h remaining.
        ch.write_weekly_anchor(3, 0, now_utc=now, _path=anchor_path)

        # Redirect module-level path to tmp file.
        monkeypatch.setattr(ch, "WEEKLY_ANCHOR_PATH", anchor_path)

        cache = _make_standard_cache(now)
        out = ch.evaluate_weekly(cache, now_utc=now)

        assert out["available"] is True
        assert out["anchor_state"] == "manual"
        assert out["seconds_remaining"] == 3 * 3600
        assert out["time_to_reset"] == "3h"
        assert out["anchor_set_at"] is not None
        assert out["anchor_reset_at"] is not None

    def test_evaluate_weekly_returns_expired_when_anchor_past(self, tmp_path, monkeypatch):
        now = datetime.datetime(2026, 4, 28, 20, 0, 0, tzinfo=datetime.timezone.utc)
        anchor_path = tmp_path / "weekly-anchor.json"

        # Write anchor that already expired (set 2h ago with 1h duration).
        set_at = now - datetime.timedelta(hours=2)
        ch.write_weekly_anchor(1, 0, now_utc=set_at, _path=anchor_path)
        monkeypatch.setattr(ch, "WEEKLY_ANCHOR_PATH", anchor_path)

        cache = _make_standard_cache(now)
        out = ch.evaluate_weekly(cache, now_utc=now)

        assert out["available"] is True
        assert out["anchor_state"] == "expired"
        assert out["seconds_remaining"] == 0
        assert out["anchor_set_at"] is not None
        assert out["anchor_reset_at"] is not None

    def test_evaluate_weekly_falls_back_to_iso_when_no_anchor(self, tmp_path, monkeypatch):
        now = datetime.datetime(2026, 4, 28, 20, 0, 0, tzinfo=datetime.timezone.utc)
        anchor_path = tmp_path / "weekly-anchor.json"
        # File does not exist — ISO fallback.
        monkeypatch.setattr(ch, "WEEKLY_ANCHOR_PATH", anchor_path)

        cache = _make_standard_cache(now)
        out = ch.evaluate_weekly(cache, now_utc=now)

        assert out["available"] is True
        assert out["anchor_state"] == "iso-fallback"
        # ISO week 2026-04-27 ends 2026-05-04T00:00:00Z; now is 2026-04-28T20:00:00Z.
        # remaining = (2026-05-04 - 2026-04-28T20:00) = 5d4h = 5*86400 + 4*3600
        expected = 5 * 86400 + 4 * 3600
        assert out["seconds_remaining"] == expected
        assert out["anchor_set_at"] is None
        assert out["anchor_reset_at"] is None

    def test_evaluate_weekly_anchor_state_keys_always_present(self, tmp_path, monkeypatch):
        """All three anchor keys are present in every available response."""
        now = datetime.datetime(2026, 4, 28, 20, 0, 0, tzinfo=datetime.timezone.utc)
        anchor_path = tmp_path / "weekly-anchor-missing.json"
        monkeypatch.setattr(ch, "WEEKLY_ANCHOR_PATH", anchor_path)

        cache = _make_standard_cache(now)
        out = ch.evaluate_weekly(cache, now_utc=now)

        assert "anchor_state" in out
        assert "anchor_set_at" in out
        assert "anchor_reset_at" in out
