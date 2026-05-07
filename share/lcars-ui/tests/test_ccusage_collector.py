#
#  test_ccusage_collector.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""Unit tests for ccusage_collector.py — schema v2 additions (XACA-0250-002).

Tests cover:
- build_weekly() — the new data builder
- run_ccusage_weekly() — subprocess invocation (mocked)
- collect() integration — weekly success, weekly failure, rolling failure paths
- Schema version bump to 2

Run with:
    cd /Users/darrenehlers/dev-team/worktrees/xaca-0250
    python3 -m pytest lcars-ui/tests/test_ccusage_collector.py -v
    # or the full suite:
    cd lcars-ui && python3 -m pytest tests/ -x
"""

from __future__ import annotations

import datetime
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

_HERE = os.path.dirname(os.path.abspath(__file__))
_LCARS_UI = os.path.dirname(_HERE)
if _LCARS_UI not in sys.path:
    sys.path.insert(0, _LCARS_UI)

import ccusage_collector as cc  # noqa: E402


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

def _make_raw_week(
    week: str = "2026-04-21",
    total_tokens: int = 500_000_000,
    total_cost: float = 300.0,
    models_used: list | None = None,
) -> dict:
    """Build a single raw ccusage weekly entry."""
    return {
        "week": week,
        "inputTokens": 100_000,
        "outputTokens": 200_000,
        "cacheCreationTokens": 10_000_000,
        "cacheReadTokens": 489_700_000,
        "totalTokens": total_tokens,
        "totalCost": total_cost,
        "modelsUsed": models_used if models_used is not None else ["claude-sonnet-4-6"],
        "modelBreakdowns": [],
    }


def _make_raw_weekly_data(num_prior_weeks: int = 5, current_week: str = "2026-04-28") -> dict:
    """Build a full ccusage weekly --json response with num_prior_weeks + current."""
    weeks = []
    base = datetime.date(2026, 4, 28) - datetime.timedelta(weeks=num_prior_weeks)
    for i in range(num_prior_weeks):
        w_date = (base + datetime.timedelta(weeks=i)).isoformat()
        weeks.append(_make_raw_week(week=w_date, total_tokens=100_000_000 * (i + 1)))
    # Current week as last entry
    weeks.append(_make_raw_week(week=current_week, total_tokens=50_000_000, total_cost=30.0))
    return {"weekly": weeks}


def _make_blocks_data(active: bool = False) -> dict:
    """Minimal ccusage blocks --json response."""
    block = {
        "id": "blk-001",
        "startTime": "2026-04-28T10:00:00Z",
        "endTime": "2026-04-28T15:00:00Z",
        "totalTokens": 10_000_000,
        "costUSD": 5.0,
        "isActive": active,
        "isGap": False,
        "models": ["claude-sonnet-4-6"],
    }
    if active:
        block["burnRate"] = {"tokensPerMinute": 50_000.0, "costPerHour": 6.0}
        block["projection"] = {"totalTokens": 90_000_000, "totalCost": 45.0, "remainingMinutes": 200}
    return {"blocks": [block]}


# ---------------------------------------------------------------------------
# build_weekly() tests
# ---------------------------------------------------------------------------

class BuildWeeklyEmptyTests(unittest.TestCase):
    """Empty input should produce a valid but empty structure."""

    def test_empty_list_returns_null_current_week(self):
        result = cc.build_weekly([])
        self.assertIsNone(result["current_week"])

    def test_empty_list_returns_empty_history(self):
        result = cc.build_weekly([])
        self.assertEqual(result["history"], [])

    def test_empty_list_has_last_collected_at(self):
        result = cc.build_weekly([])
        self.assertIn("last_collected_at", result)
        self.assertTrue(result["last_collected_at"].endswith("Z"))


class BuildWeeklyCurrentWeekTests(unittest.TestCase):
    """Last entry in the raw list becomes current_week."""

    def setUp(self):
        weeks = [
            _make_raw_week(week="2026-04-14", total_tokens=200_000_000, total_cost=120.0),
            _make_raw_week(week="2026-04-21", total_tokens=300_000_000, total_cost=180.0),
            _make_raw_week(
                week="2026-04-28",
                total_tokens=50_000_000,
                total_cost=30.0,
                models_used=["claude-opus-4-6", "claude-sonnet-4-6"],
            ),
        ]
        self.result = cc.build_weekly(weeks)

    def test_current_week_is_last_entry(self):
        cw = self.result["current_week"]
        self.assertIsNotNone(cw)
        self.assertEqual(cw["week"], "2026-04-28")

    def test_current_week_tokens_correct(self):
        self.assertEqual(self.result["current_week"]["totalTokens"], 50_000_000)

    def test_current_week_cost_rounded(self):
        self.assertAlmostEqual(self.result["current_week"]["totalCost"], 30.0, places=6)

    def test_current_week_models_included(self):
        models = self.result["current_week"]["modelsUsed"]
        self.assertIn("claude-opus-4-6", models)
        self.assertIn("claude-sonnet-4-6", models)

    def test_history_excludes_current_week(self):
        weeks_in_history = [h["week"] for h in self.result["history"]]
        self.assertNotIn("2026-04-28", weeks_in_history)

    def test_history_contains_prior_weeks(self):
        weeks_in_history = [h["week"] for h in self.result["history"]]
        self.assertIn("2026-04-14", weeks_in_history)
        self.assertIn("2026-04-21", weeks_in_history)

    def test_history_entries_have_required_fields(self):
        for entry in self.result["history"]:
            self.assertIn("week", entry)
            self.assertIn("totalTokens", entry)
            self.assertIn("totalCost", entry)

    def test_history_entries_do_not_have_models_used(self):
        # History is lightweight — modelsUsed is only on current_week.
        for entry in self.result["history"]:
            self.assertNotIn("modelsUsed", entry)


class BuildWeeklyHistoryCapTests(unittest.TestCase):
    """History should be capped at WEEKLY_HISTORY_MAX prior weeks."""

    def test_history_capped_at_max(self):
        # 15 prior weeks + 1 current = 16 total; history should cap at 12.
        raw_data = _make_raw_weekly_data(num_prior_weeks=15)
        result = cc.build_weekly(raw_data["weekly"])
        self.assertLessEqual(len(result["history"]), cc.WEEKLY_HISTORY_MAX)

    def test_history_cap_keeps_most_recent_weeks(self):
        # 15 prior weeks — oldest should be dropped, newest kept.
        raw_data = _make_raw_weekly_data(num_prior_weeks=15, current_week="2026-04-28")
        result = cc.build_weekly(raw_data["weekly"])
        # The most recent prior week should be present.
        prior_weeks_in_history = [h["week"] for h in result["history"]]
        # Current week date minus 1 week = most recent prior week
        self.assertIn("2026-04-21", prior_weeks_in_history)

    def test_under_cap_no_truncation(self):
        # 3 prior weeks — all should appear in history.
        raw_data = _make_raw_weekly_data(num_prior_weeks=3)
        result = cc.build_weekly(raw_data["weekly"])
        self.assertEqual(len(result["history"]), 3)


class BuildWeeklyOnlyOneWeekTests(unittest.TestCase):
    """Single entry = current week, empty history."""

    def test_single_entry_is_current_week(self):
        result = cc.build_weekly([_make_raw_week(week="2026-04-28")])
        self.assertIsNotNone(result["current_week"])
        self.assertEqual(result["current_week"]["week"], "2026-04-28")

    def test_single_entry_has_empty_history(self):
        result = cc.build_weekly([_make_raw_week(week="2026-04-28")])
        self.assertEqual(result["history"], [])


class BuildWeeklyCostRoundingTests(unittest.TestCase):
    """totalCost should be rounded to 6 decimal places."""

    def test_cost_rounded_to_6_places(self):
        raw = [_make_raw_week(week="2026-04-28", total_cost=123.456789012345)]
        result = cc.build_weekly(raw)
        # Current week cost rounded to 6dp
        cost = result["current_week"]["totalCost"]
        self.assertEqual(cost, round(123.456789012345, 6))

    def test_history_cost_rounded(self):
        raw = [
            _make_raw_week(week="2026-04-21", total_cost=99.9999991234567),
            _make_raw_week(week="2026-04-28", total_cost=10.0),
        ]
        result = cc.build_weekly(raw)
        self.assertEqual(result["history"][0]["totalCost"], round(99.9999991234567, 6))


# ---------------------------------------------------------------------------
# run_ccusage_weekly() tests (subprocess mocked)
# ---------------------------------------------------------------------------

class RunCcusageWeeklyTests(unittest.TestCase):
    """run_ccusage_weekly parses stdout and handles errors correctly."""

    def _make_weekly_json(self) -> str:
        return json.dumps(_make_raw_weekly_data(num_prior_weeks=3))

    def test_successful_run_returns_ok_true(self):
        mock_result = mock.MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = self._make_weekly_json()
        mock_result.stderr = ""
        with mock.patch("subprocess.run", return_value=mock_result):
            ok, data, err = cc.run_ccusage_weekly("/fake/ccusage")
        self.assertTrue(ok)
        self.assertIsNotNone(data)
        self.assertEqual(err, "")

    def test_successful_run_data_has_weekly_key(self):
        mock_result = mock.MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = self._make_weekly_json()
        mock_result.stderr = ""
        with mock.patch("subprocess.run", return_value=mock_result):
            ok, data, _ = cc.run_ccusage_weekly("/fake/ccusage")
        self.assertIn("weekly", data)
        self.assertIsInstance(data["weekly"], list)

    def test_nonzero_exit_code_returns_ok_false(self):
        mock_result = mock.MagicMock()
        mock_result.returncode = 1
        mock_result.stdout = ""
        mock_result.stderr = "some error from ccusage"
        with mock.patch("subprocess.run", return_value=mock_result):
            ok, data, err = cc.run_ccusage_weekly("/fake/ccusage")
        self.assertFalse(ok)
        self.assertIsNone(data)
        self.assertIn("exited 1", err)

    def test_timeout_returns_ok_false(self):
        import subprocess
        with mock.patch("subprocess.run", side_effect=subprocess.TimeoutExpired("ccusage", 240)):
            ok, data, err = cc.run_ccusage_weekly("/fake/ccusage")
        self.assertFalse(ok)
        self.assertIsNone(data)
        self.assertIn("timed out", err)

    def test_file_not_found_returns_ok_false(self):
        with mock.patch("subprocess.run", side_effect=FileNotFoundError("no such file")):
            ok, data, err = cc.run_ccusage_weekly("/fake/ccusage")
        self.assertFalse(ok)
        self.assertIsNone(data)
        self.assertIn("not found", err)

    def test_malformed_json_returns_ok_false(self):
        mock_result = mock.MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "{not valid json]["
        mock_result.stderr = ""
        with mock.patch("subprocess.run", return_value=mock_result):
            ok, data, err = cc.run_ccusage_weekly("/fake/ccusage")
        self.assertFalse(ok)
        self.assertIsNone(data)
        self.assertIn("parse error", err)

    def test_correct_subcommand_passed(self):
        """Verify the subprocess call includes 'weekly' (not 'blocks')."""
        mock_result = mock.MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = self._make_weekly_json()
        mock_result.stderr = ""
        with mock.patch("subprocess.run", return_value=mock_result) as mock_run:
            cc.run_ccusage_weekly("/fake/ccusage")
        cmd = mock_run.call_args[0][0]
        self.assertIn("weekly", cmd)
        self.assertNotIn("blocks", cmd)

    def test_since_flag_included(self):
        """Verify --since flag is passed to weekly subcommand."""
        mock_result = mock.MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = self._make_weekly_json()
        mock_result.stderr = ""
        with mock.patch("subprocess.run", return_value=mock_result) as mock_run:
            cc.run_ccusage_weekly("/fake/ccusage")
        cmd = mock_run.call_args[0][0]
        self.assertIn("--since", cmd)
        self.assertIn("--json", cmd)


# ---------------------------------------------------------------------------
# collect() integration tests — weekly paths
# ---------------------------------------------------------------------------

def _make_subprocess_result(returncode: int = 0, stdout: str = "") -> mock.MagicMock:
    r = mock.MagicMock()
    r.returncode = returncode
    r.stdout = stdout
    r.stderr = ""
    return r


class CollectWeeklySuccessTests(unittest.TestCase):
    """When weekly succeeds, cache should contain schema_version=2 + weekly block."""

    def setUp(self):
        self._tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        )
        self._tmp.close()
        self._orig_cache = cc.CACHE_PATH
        self._orig_tmp = cc.CACHE_TMP_PATH
        cc.CACHE_PATH = type(cc.CACHE_PATH)(self._tmp.name)
        cc.CACHE_TMP_PATH = type(cc.CACHE_TMP_PATH)(self._tmp.name + ".tmp")

    def tearDown(self):
        cc.CACHE_PATH = self._orig_cache
        cc.CACHE_TMP_PATH = self._orig_tmp
        try:
            os.unlink(self._tmp.name)
        except FileNotFoundError:
            pass
        try:
            os.unlink(self._tmp.name + ".tmp")
        except FileNotFoundError:
            pass

    def _run_collect_with_mocks(self, weekly_ok: bool = True) -> dict:
        blocks_data = _make_blocks_data(active=False)
        weekly_data = _make_raw_weekly_data(num_prior_weeks=3) if weekly_ok else None

        def fake_subprocess_run(cmd, **kwargs):
            if "weekly" in cmd:
                if weekly_ok:
                    return _make_subprocess_result(stdout=json.dumps(weekly_data))
                else:
                    return _make_subprocess_result(returncode=1, stdout="weekly error")
            else:
                return _make_subprocess_result(stdout=json.dumps(blocks_data))

        with mock.patch("subprocess.run", side_effect=fake_subprocess_run):
            cc.collect("/fake/ccusage")

        return json.loads(cc.CACHE_PATH.read_text())

    def test_schema_version_is_2(self):
        cache = self._run_collect_with_mocks(weekly_ok=True)
        self.assertEqual(cache["schema_version"], 2)

    def test_weekly_block_present_on_success(self):
        cache = self._run_collect_with_mocks(weekly_ok=True)
        self.assertIsNotNone(cache.get("weekly"))

    def test_weekly_current_week_populated(self):
        cache = self._run_collect_with_mocks(weekly_ok=True)
        self.assertIsNotNone(cache["weekly"]["current_week"])

    def test_weekly_history_present(self):
        cache = self._run_collect_with_mocks(weekly_ok=True)
        self.assertIsInstance(cache["weekly"]["history"], list)

    def test_weekly_last_collected_at_present(self):
        cache = self._run_collect_with_mocks(weekly_ok=True)
        self.assertIn("last_collected_at", cache["weekly"])

    def test_weekly_error_is_null_on_success(self):
        cache = self._run_collect_with_mocks(weekly_ok=True)
        self.assertIsNone(cache.get("weekly_error"))

    # V1 fields must remain intact (backward compat)
    def test_v1_ccusage_ok_still_present(self):
        cache = self._run_collect_with_mocks(weekly_ok=True)
        self.assertIn("ccusage_ok", cache)

    def test_v1_calibration_still_present(self):
        cache = self._run_collect_with_mocks(weekly_ok=True)
        self.assertIn("calibration", cache)

    def test_v1_totals_still_present(self):
        cache = self._run_collect_with_mocks(weekly_ok=True)
        self.assertIn("totals", cache)

    def test_v1_history_still_present(self):
        cache = self._run_collect_with_mocks(weekly_ok=True)
        self.assertIn("history", cache)

    def test_v1_active_window_still_present(self):
        cache = self._run_collect_with_mocks(weekly_ok=True)
        self.assertIn("active_window", cache)


class CollectWeeklyFailureTests(unittest.TestCase):
    """When weekly fails, cache still written with weekly=null + ccusage_ok unaffected."""

    def setUp(self):
        self._tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        )
        self._tmp.close()
        self._orig_cache = cc.CACHE_PATH
        self._orig_tmp = cc.CACHE_TMP_PATH
        cc.CACHE_PATH = type(cc.CACHE_PATH)(self._tmp.name)
        cc.CACHE_TMP_PATH = type(cc.CACHE_TMP_PATH)(self._tmp.name + ".tmp")

    def tearDown(self):
        cc.CACHE_PATH = self._orig_cache
        cc.CACHE_TMP_PATH = self._orig_tmp
        try:
            os.unlink(self._tmp.name)
        except FileNotFoundError:
            pass
        try:
            os.unlink(self._tmp.name + ".tmp")
        except FileNotFoundError:
            pass

    def _run_collect_weekly_fails(self) -> dict:
        blocks_data = _make_blocks_data(active=False)

        def fake_subprocess_run(cmd, **kwargs):
            if "weekly" in cmd:
                return _make_subprocess_result(returncode=1, stdout="weekly unavailable")
            else:
                return _make_subprocess_result(stdout=json.dumps(blocks_data))

        with mock.patch("subprocess.run", side_effect=fake_subprocess_run):
            cc.collect("/fake/ccusage")

        return json.loads(cc.CACHE_PATH.read_text())

    def test_schema_version_is_2_even_on_weekly_failure(self):
        cache = self._run_collect_weekly_fails()
        self.assertEqual(cache["schema_version"], 2)

    def test_ccusage_ok_true_when_only_weekly_fails(self):
        """Rolling blocks succeed -> ccusage_ok must remain True."""
        cache = self._run_collect_weekly_fails()
        self.assertTrue(cache["ccusage_ok"])

    def test_weekly_is_null_on_failure(self):
        cache = self._run_collect_weekly_fails()
        self.assertIsNone(cache.get("weekly"))

    def test_weekly_error_populated_on_failure(self):
        cache = self._run_collect_weekly_fails()
        self.assertIsNotNone(cache.get("weekly_error"))
        self.assertIn("exited 1", cache["weekly_error"])

    def test_v1_fields_intact_on_weekly_failure(self):
        cache = self._run_collect_weekly_fails()
        for field in ("ccusage_ok", "calibration", "totals", "history", "active_window"):
            self.assertIn(field, cache)


class CollectRollingFailureTests(unittest.TestCase):
    """When rolling blocks fail, weekly data from prev cache is preserved."""

    def setUp(self):
        self._tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        )
        # Write a previous cache with weekly data already present.
        prev_weekly = {
            "last_collected_at": "2026-04-28T10:00:00Z",
            "current_week": {"week": "2026-04-28", "totalTokens": 100, "totalCost": 0.1, "modelsUsed": []},
            "history": [],
        }
        prev_cache = {
            "schema_version": 2,
            "collected_at": "2026-04-28T10:00:00Z",
            "collected_at_unix": 1_745_834_400,
            "ccusage_ok": True,
            "ccusage_error": None,
            "active_window": None,
            "history": [],
            "calibration": {"max_window_tokens": 0, "max_window_cost_usd": 0.0,
                            "max_window_id": "", "p90_window_tokens": 0, "samples": 0},
            "totals": {"today_tokens": 0, "today_cost_usd": 0.0,
                       "last_7d_tokens": 0, "last_7d_cost_usd": 0.0},
            "weekly": prev_weekly,
            "weekly_error": None,
        }
        self._tmp.write(json.dumps(prev_cache))
        self._tmp.flush()
        self._tmp.close()
        self._orig_cache = cc.CACHE_PATH
        self._orig_tmp = cc.CACHE_TMP_PATH
        cc.CACHE_PATH = type(cc.CACHE_PATH)(self._tmp.name)
        cc.CACHE_TMP_PATH = type(cc.CACHE_TMP_PATH)(self._tmp.name + ".tmp")

    def tearDown(self):
        cc.CACHE_PATH = self._orig_cache
        cc.CACHE_TMP_PATH = self._orig_tmp
        try:
            os.unlink(self._tmp.name)
        except FileNotFoundError:
            pass
        try:
            os.unlink(self._tmp.name + ".tmp")
        except FileNotFoundError:
            pass

    def test_weekly_preserved_when_rolling_fails(self):
        def fake_subprocess_run(cmd, **kwargs):
            return _make_subprocess_result(returncode=1, stdout="blocks error")

        with mock.patch("subprocess.run", side_effect=fake_subprocess_run):
            cc.collect("/fake/ccusage")

        cache = json.loads(cc.CACHE_PATH.read_text())
        # ccusage_ok should be False (rolling failed)
        self.assertFalse(cache["ccusage_ok"])
        # But weekly should be preserved from prev cache
        self.assertIsNotNone(cache.get("weekly"))
        self.assertEqual(cache["weekly"]["current_week"]["week"], "2026-04-28")

    def test_schema_version_is_2_even_when_rolling_fails(self):
        def fake_subprocess_run(cmd, **kwargs):
            return _make_subprocess_result(returncode=1, stdout="blocks error")

        with mock.patch("subprocess.run", side_effect=fake_subprocess_run):
            cc.collect("/fake/ccusage")

        cache = json.loads(cc.CACHE_PATH.read_text())
        self.assertEqual(cache["schema_version"], 2)


# ---------------------------------------------------------------------------
# Constants sanity checks
# ---------------------------------------------------------------------------

class ConstantsTests(unittest.TestCase):
    """Guard against accidental constant regressions."""

    def test_schema_version_is_2(self):
        self.assertEqual(cc.SCHEMA_VERSION, 2)

    def test_weekly_days_is_positive(self):
        self.assertGreater(cc.WEEKLY_DAYS, 0)

    def test_weekly_history_max_reasonable(self):
        self.assertGreaterEqual(cc.WEEKLY_HISTORY_MAX, 1)
        self.assertLessEqual(cc.WEEKLY_HISTORY_MAX, 52)


if __name__ == "__main__":
    unittest.main()
