#!/usr/bin/env python3

#
#  test_xaca0679_by_model.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Unit tests for XACA-0679 Python helpers: _model_tier() and build_models_breakdown().

Coverage:
  _model_tier()         — tier classification by model ID, unknown/empty/case variants
  build_models_breakdown() — empty input, today/7d windowing, multi-tier accumulation,
                             malformed date handling
"""

import datetime
import sys
from pathlib import Path
from unittest.mock import patch

# Add parent directory so ccusage_collector imports cleanly
sys.path.insert(0, str(Path(__file__).parent))

import ccusage_collector as cc


# ---------------------------------------------------------------------------
# _model_tier() tests
# ---------------------------------------------------------------------------

def test_model_tier_opus():
    assert cc._model_tier("claude-opus-4-8") == "Opus"


def test_model_tier_sonnet():
    assert cc._model_tier("claude-sonnet-4-6") == "Sonnet"


def test_model_tier_haiku():
    assert cc._model_tier("claude-haiku-4-5-20251001") == "Haiku"


def test_model_tier_fable():
    assert cc._model_tier("claude-fable-5") == "Fable"


def test_model_tier_unknown_returns_other():
    assert cc._model_tier("claude-unknown-model") == "Other"


def test_model_tier_empty_string_returns_other():
    assert cc._model_tier("") == "Other"


def test_model_tier_case_insensitive():
    """Uppercase model ID should still map to the correct tier."""
    assert cc._model_tier("CLAUDE-OPUS-4-8") == "Opus"
    assert cc._model_tier("Claude-Sonnet-4-6") == "Sonnet"
    assert cc._model_tier("CLAUDE-HAIKU-3") == "Haiku"
    assert cc._model_tier("CLAUDE-FABLE-1") == "Fable"


def test_model_tier_future_point_version():
    """Substring match means future point versions keep working automatically."""
    assert cc._model_tier("claude-opus-5-0") == "Opus"
    assert cc._model_tier("claude-sonnet-99-0") == "Sonnet"


# ---------------------------------------------------------------------------
# build_models_breakdown() tests
# ---------------------------------------------------------------------------

# Fixed "now" for deterministic windowing: 2026-06-11 noon UTC (local = same)
_FIXED_NOW = datetime.datetime(2026, 6, 11, 12, 0, 0)
_TODAY_STR = "2026-06-11"
_YESTERDAY_STR = "2026-06-10"
_SEVEN_DAYS_AGO_STR = "2026-06-04"   # exactly 7 days ago (within window)
_EIGHT_DAYS_AGO_STR = "2026-06-03"   # 8 days ago — outside the 7d window


def _call_with_fixed_now(daily_rows):
    """Call build_models_breakdown() with a fixed datetime.now() so tests are stable."""
    with patch.object(cc.datetime, "datetime", wraps=cc.datetime.datetime) as mock_dt:
        mock_dt.now.return_value = _FIXED_NOW
        return cc.build_models_breakdown(daily_rows)


def test_empty_input_returns_all_five_tiers_zero_filled():
    result = _call_with_fixed_now([])

    assert "tiers" in result
    assert "last_collected_at" in result

    tiers = result["tiers"]
    for tier_name in ("Opus", "Sonnet", "Haiku", "Fable", "Other"):
        assert tier_name in tiers, f"Missing tier: {tier_name}"
        t = tiers[tier_name]
        assert t["today_tokens"] == 0
        assert t["today_cost_usd"] == 0.0
        assert t["last_7d_tokens"] == 0
        assert t["last_7d_cost_usd"] == 0.0


def test_today_entry_appears_in_both_today_and_7d():
    rows = [
        {
            "date": _TODAY_STR,
            "modelBreakdowns": [
                {
                    "modelName": "claude-opus-4-8",
                    "inputTokens": 100,
                    "outputTokens": 50,
                    "cacheCreationTokens": 0,
                    "cacheReadTokens": 0,
                    "cost": 0.01,
                }
            ],
        }
    ]
    result = _call_with_fixed_now(rows)
    opus = result["tiers"]["Opus"]
    assert opus["today_tokens"] == 150
    assert opus["today_cost_usd"] == 0.01
    assert opus["last_7d_tokens"] == 150
    assert opus["last_7d_cost_usd"] == 0.01


def test_yesterday_entry_in_7d_but_not_today():
    rows = [
        {
            "date": _YESTERDAY_STR,
            "modelBreakdowns": [
                {
                    "modelName": "claude-sonnet-4-6",
                    "inputTokens": 200,
                    "outputTokens": 100,
                    "cacheCreationTokens": 0,
                    "cacheReadTokens": 0,
                    "cost": 0.02,
                }
            ],
        }
    ]
    result = _call_with_fixed_now(rows)
    sonnet = result["tiers"]["Sonnet"]
    assert sonnet["today_tokens"] == 0,    "yesterday must NOT count as today"
    assert sonnet["today_cost_usd"] == 0.0
    assert sonnet["last_7d_tokens"] == 300
    assert sonnet["last_7d_cost_usd"] == 0.02


def test_8_days_ago_excluded_from_both_windows():
    """Entry older than 7 days must not appear in either today or last_7d."""
    rows = [
        {
            "date": _EIGHT_DAYS_AGO_STR,
            "modelBreakdowns": [
                {
                    "modelName": "claude-haiku-4-5-20251001",
                    "inputTokens": 500,
                    "outputTokens": 500,
                    "cacheCreationTokens": 0,
                    "cacheReadTokens": 0,
                    "cost": 0.05,
                }
            ],
        }
    ]
    result = _call_with_fixed_now(rows)
    haiku = result["tiers"]["Haiku"]
    assert haiku["today_tokens"] == 0
    assert haiku["last_7d_tokens"] == 0


def test_7_days_ago_included_in_7d_window():
    """Exactly 7 days ago (date >= seven_days_ago) must be included in the 7d window."""
    rows = [
        {
            "date": _SEVEN_DAYS_AGO_STR,
            "modelBreakdowns": [
                {
                    "modelName": "claude-fable-5",
                    "inputTokens": 10,
                    "outputTokens": 10,
                    "cacheCreationTokens": 0,
                    "cacheReadTokens": 0,
                    "cost": 0.001,
                }
            ],
        }
    ]
    result = _call_with_fixed_now(rows)
    fable = result["tiers"]["Fable"]
    assert fable["last_7d_tokens"] == 20
    assert fable["today_tokens"] == 0


def test_multi_tier_accumulation():
    """Entries for multiple tiers on the same date accumulate into separate buckets."""
    rows = [
        {
            "date": _TODAY_STR,
            "modelBreakdowns": [
                {
                    "modelName": "claude-opus-4-8",
                    "inputTokens": 10,
                    "outputTokens": 5,
                    "cacheCreationTokens": 0,
                    "cacheReadTokens": 0,
                    "cost": 0.001,
                },
                {
                    "modelName": "claude-sonnet-4-6",
                    "inputTokens": 20,
                    "outputTokens": 10,
                    "cacheCreationTokens": 5,
                    "cacheReadTokens": 3,
                    "cost": 0.002,
                },
                {
                    "modelName": "claude-unknown-xyz",
                    "inputTokens": 7,
                    "outputTokens": 3,
                    "cacheCreationTokens": 0,
                    "cacheReadTokens": 0,
                    "cost": 0.0005,
                },
            ],
        }
    ]
    result = _call_with_fixed_now(rows)
    assert result["tiers"]["Opus"]["today_tokens"] == 15
    assert result["tiers"]["Sonnet"]["today_tokens"] == 38   # 20+10+5+3
    assert result["tiers"]["Other"]["today_tokens"] == 10    # unknown model → Other
    assert result["tiers"]["Haiku"]["today_tokens"] == 0
    assert result["tiers"]["Fable"]["today_tokens"] == 0


def test_malformed_date_string_skipped_without_raising():
    """Rows with bad or empty date strings must be silently skipped."""
    rows = [
        {"date": "", "modelBreakdowns": [
            {"modelName": "claude-opus-4-8", "inputTokens": 99, "outputTokens": 1,
             "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 0.1}
        ]},
        {"date": "not-a-date", "modelBreakdowns": [
            {"modelName": "claude-sonnet-4-6", "inputTokens": 50, "outputTokens": 50,
             "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 0.05}
        ]},
        # A valid today row to confirm the function still works after bad rows
        {"date": _TODAY_STR, "modelBreakdowns": [
            {"modelName": "claude-haiku-4-5-20251001", "inputTokens": 3, "outputTokens": 2,
             "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 0.0003}
        ]},
    ]
    result = _call_with_fixed_now(rows)
    # Bad-date rows silently skipped; only the valid Haiku row counts
    assert result["tiers"]["Opus"]["today_tokens"] == 0
    assert result["tiers"]["Sonnet"]["today_tokens"] == 0
    assert result["tiers"]["Haiku"]["today_tokens"] == 5


def test_result_has_last_collected_at_field():
    result = _call_with_fixed_now([])
    assert isinstance(result.get("last_collected_at"), str)
    assert len(result["last_collected_at"]) > 0


# ---------------------------------------------------------------------------
# main() runner — also lets pytest discover the test_ functions above
# ---------------------------------------------------------------------------

def main():
    """Run all tests with a simple print-based harness (mirrors test_create_item_endpoint.py)."""
    print("=" * 60)
    print("XACA-0679 — _model_tier() / build_models_breakdown() tests")
    print("=" * 60)
    print()

    tests = [
        test_model_tier_opus,
        test_model_tier_sonnet,
        test_model_tier_haiku,
        test_model_tier_fable,
        test_model_tier_unknown_returns_other,
        test_model_tier_empty_string_returns_other,
        test_model_tier_case_insensitive,
        test_model_tier_future_point_version,
        test_empty_input_returns_all_five_tiers_zero_filled,
        test_today_entry_appears_in_both_today_and_7d,
        test_yesterday_entry_in_7d_but_not_today,
        test_8_days_ago_excluded_from_both_windows,
        test_7_days_ago_included_in_7d_window,
        test_multi_tier_accumulation,
        test_malformed_date_string_skipped_without_raising,
        test_result_has_last_collected_at_field,
    ]

    passed = 0
    failed = 0
    for t in tests:
        try:
            t()
            print(f"  ok  {t.__name__}")
            passed += 1
        except Exception as exc:
            print(f"  FAIL {t.__name__}: {exc}")
            failed += 1

    print()
    print("=" * 60)
    if failed == 0:
        print(f"All {passed} tests passed.")
    else:
        print(f"{passed} passed, {failed} FAILED.")
    print("=" * 60)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
