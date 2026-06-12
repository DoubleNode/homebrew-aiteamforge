#!/usr/bin/env python3

#
#  ccusage_collector.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
ccusage_collector.py — Claude Usage Cache Collector Daemon

Polls `ccusage blocks --json` every 30 seconds and writes a normalised JSON
cache to ~/.aiteamforge/run/lcars-ccusage-cache.json atomically. Multiple UI
clients (LCARS dashboard, agent panels) read the cache without repeatedly
re-scanning the underlying JSONL files.

Cache schema (v4):
{
  "schema_version": 4,
  "collected_at": "<ISO-8601 UTC>",
  "collected_at_unix": <int>,
  "ccusage_ok": <bool>,
  "ccusage_error": <str|null>,
  "active_window": {
    "id": str, "start_time": str, "end_time": str,
    "elapsed_minutes": int, "remaining_minutes": int,
    "total_tokens": int, "cost_usd": float, "models": [str],
    "burn_rate": {"tokens_per_minute": float, "cost_per_hour": float},
    "projection": {"total_tokens": int, "total_cost_usd": float,
                   "remaining_minutes": int}
  } | null,
  "history": [
    {"id": str, "start_time": str, "end_time": str,
     "total_tokens": int, "cost_usd": float, "is_gap": false},
    ...  // last 50 non-gap windows, oldest->newest
  ],
  "calibration": {
    "max_window_tokens": int, "max_window_cost_usd": float,
    "max_window_id": str, "p90_window_tokens": int, "samples": int
  },
  "totals": {
    "today_tokens": int, "today_cost_usd": float,
    "last_7d_tokens": int, "last_7d_cost_usd": float
  },
  "weekly": {
    "last_collected_at": "<ISO-8601 UTC>",
    "current_week": {
      "week": "<ISO date anchor e.g. 2026-04-28>",
      "totalTokens": int,
      "totalCost": float,
      "modelsUsed": [str, ...]
    } | null,
    "history": [
      {"week": "<ISO>", "totalTokens": int, "totalCost": float},
      ...  // up to 12 weeks, oldest->newest, excludes current week
    ]
  } | null,  // null when ccusage weekly call fails; weekly_error populated
  "weekly_error": str | null,  // set when weekly collection fails
  "accounts": {
    "<account_id>": {
      "nickname": str,         // from team-paths.json anthropic_account_nickname
      "today_tokens": int,
      "today_cost_usd": float,
      "last_7d_tokens": int,
      "last_7d_cost_usd": float,
      "all_time_tokens": int,
      "all_time_cost_usd": float,
    },
    ...
  },
  "untagged_bucket": {
    "nickname": "Untagged (pre-isolation)",
    "today_tokens": int,
    "today_cost_usd": float,
    "last_7d_tokens": int,
    "last_7d_cost_usd": float,
    "all_time_tokens": int,
    "all_time_cost_usd": float,
    "cwds": [str, ...]         // decoded cwd paths, for diagnostics
  },
  "by_model": {
    "tiers": {
      "Opus":   {"today_tokens":int,"today_cost_usd":float,"last_7d_tokens":int,"last_7d_cost_usd":float},
      "Sonnet": {"today_tokens":int,"today_cost_usd":float,"last_7d_tokens":int,"last_7d_cost_usd":float},
      "Haiku":  {"today_tokens":int,"today_cost_usd":float,"last_7d_tokens":int,"last_7d_cost_usd":float},
      "Fable":  {"today_tokens":int,"today_cost_usd":float,"last_7d_tokens":int,"last_7d_cost_usd":float},
      "Other":  {"today_tokens":int,"today_cost_usd":float,"last_7d_tokens":int,"last_7d_cost_usd":float}
    },
    "last_collected_at": "<ISO-8601 UTC>"
  }
}

NOTE on v4 rollup semantics:
- All v2 fields (active_window, history, calibration, totals, weekly) are
  PRESERVED UNCHANGED as the all-accounts rollup. Existing consumers are
  unaffected.
- "accounts" is the new per-account breakdown keyed by Anthropic account_id
  (e.g. "acct-xyz") or "default-oauth" for teams with no explicit account
  configured. Attribution uses cwd-based matching via team-paths.json
  working_dir fields. session --json sessionId encoding: all '/' replaced
  by '-', so we encode working_dir the same way and use prefix matching.
- "untagged_bucket" aggregates sessions whose cwd does not match any team.
  No heuristic backfill is attempted; only genuinely unmapped cwds land here.
- SessionAccountMapIndex (see class below) provides an auxiliary tiebreaker:
  if a cwd has no team-paths match but the JSONL map has a known account for
  it, that account is used instead of Untagged.

v1 -> v2 change notes:
- All v1 fields are preserved unchanged for backward compatibility.
- New top-level "weekly" key contains per-calendar-week aggregates.
- New top-level "weekly_error" key captures weekly-fetch failures without
  affecting ccusage_ok (the 5h blocks flow is independent).
- schema_version bumped from 1 to 2.

v2 -> v3 change notes:
- All v2 fields are preserved unchanged for backward compatibility.
- New top-level "accounts" key contains per-account usage breakdown.
- New top-level "untagged_bucket" key aggregates unmatched sessions.
- schema_version bumped from 2 to 3.
- v2->v3 migration (run once): legacy totals mirrored into untagged_bucket
  so historical numbers don't vanish from the new UI.

v3 -> v4 change notes (XACA-0679):
- All v3 fields are preserved unchanged for backward compatibility.
- New top-level "by_model" key contains per-model-tier token + cost breakdown.
- Model IDs are collapsed to 5 tiers: Opus, Sonnet, Haiku, Fable, Other.
  Any unrecognized model ID lands in Other (tokens/cost never dropped).
- Data source: ccusage daily --json --breakdown, aggregated for today and
  last 7 days using the same local-midnight windowing as build_totals().
- All five tiers are always present (zero-filled when no data for a tier),
  consistent with how build_accounts() always initialises its accumulator
  buckets before iterating.
- schema_version bumped from 3 to 4.
- v3->v4 migration (run once): adds by_model with zero-filled tiers so
  consumers that load a stale cache before the first v4 collect() don't
  encounter a missing key.

Notes for subitem 003 (API endpoint consumer):
- active_window is null between usage sessions.
- calibration uses a 30-day look-back (separate ccusage call) so it doesn't
  shrink as the rolling 7-day history cache rotates.
- elapsed_minutes is computed from startTime to now (UTC) when the block is
  active. remaining_minutes comes from projection.remainingMinutes.
- On ccusage failure, ccusage_ok=false and last known good values are
  preserved from the previous cache so the UI can show stale-data warnings
  rather than blanking out entirely.
- weekly is null when the weekly fetch fails; weekly_error describes why.
  Consumers must treat weekly=null gracefully (subitem 006 handles the UX).
"""

import argparse
import datetime
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time
from typing import Any, Optional

TEAM_PATHS_JSON = pathlib.Path("~/.aiteamforge/team-paths.json").expanduser()
SESSION_ACCOUNT_MAP_JSONL = pathlib.Path("~/.claude/.session-account-map.jsonl").expanduser()

# Import shared runtime paths (XACA-0385: moved out of world-writable /tmp)
try:
    from ccusage_paths import (  # noqa: PLC0415
        CACHE_PATH, CACHE_TMP_PATH, PID_PATH, ensure_runtime_dir,
    )
except ImportError as e:
    # Fallback: should not happen in a normal install, but log and abort rather
    # than silently reverting to /tmp paths.
    import sys as _sys
    print(f"[ccusage_collector] FATAL: ccusage_paths not available: {e}", file=_sys.stderr)
    _sys.exit(1)

# --- constants ---
# POLL_INTERVAL_S is the SLEEP between completed scans, not the wall-clock
# period of the loop. The main loop is sequential: do_collection() blocks for
# the scan (up to CCUSAGE_TIMEOUT_S), THEN we sleep POLL_INTERVAL_S. So polls
# can never stack regardless of which value is larger — total cycle is
# (scan_duration + POLL_INTERVAL_S). 180s sleep + ~65s typical scan ≈ 4 min
# between cache refreshes on a healthy system, headroom for 240s slow scans.
POLL_INTERVAL_S = 180
CCUSAGE_TIMEOUT_S = 240  # ccusage scans JSONL transcripts; ~65s typical, 200s+ under load
HISTORY_MAX = 50
SCHEMA_VERSION = 4
ROLLING_DAYS = 7       # rolling history window for display
CALIBRATION_DAYS = 30  # wider window keeps calibration stable as rolling rotates
WEEKLY_DAYS = 90       # ~13 calendar weeks for weekly history
WEEKLY_HISTORY_MAX = 12  # cap on historical weeks stored (excludes current week)
# Fallback binary paths for fnm-managed ccusage installs
FNM_FALLBACK_GLOBS = [
    "~/.local/state/fnm_multishells/*/bin/ccusage",
    "~/.fnm/aliases/default/bin/ccusage",
    "~/.fnm/node-versions/*/installation/bin/ccusage",
]


# --- logging ---
def _log(level: str, msg: str) -> None:
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"{ts} [{level}] {msg}", file=sys.stderr, flush=True)

def log_info(msg: str) -> None: _log("INFO", msg)
def log_warn(msg: str) -> None: _log("WARN", msg)
def log_error(msg: str) -> None: _log("ERROR", msg)


# --- binary discovery ---
def find_ccusage() -> Optional[str]:
    """Return path to ccusage binary or None if not found."""
    found = shutil.which("ccusage")
    if found:
        return found
    import glob
    for pattern in FNM_FALLBACK_GLOBS:
        matches = sorted(glob.glob(os.path.expanduser(pattern)))
        if matches:
            return matches[-1]
    return None


# --- ccusage invocation ---
def _since_flag(days_back: int) -> str:
    d = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days_back)
    return d.strftime("%Y%m%d")


def run_ccusage(binary: str, days_back: int) -> tuple[bool, Any, str]:
    """Run ccusage blocks --json --since YYYYMMDD. Returns (ok, data, error_msg)."""
    # ccusage scans JSONL files; can take 50-200s on large histories
    cmd = [binary, "blocks", "--json", "--since", _since_flag(days_back)]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=CCUSAGE_TIMEOUT_S)
    except FileNotFoundError as e:
        return False, None, f"ccusage binary not found: {e}"
    except subprocess.TimeoutExpired:
        return False, None, f"ccusage timed out after {CCUSAGE_TIMEOUT_S}s"
    except Exception as e:
        return False, None, f"ccusage subprocess error: {e}"

    if result.returncode != 0:
        err = (result.stderr or result.stdout or "unknown error").strip()
        return False, None, f"ccusage exited {result.returncode}: {err[:200]}"
    try:
        return True, json.loads(result.stdout), ""
    except json.JSONDecodeError as e:
        return False, None, f"JSON parse error: {e} — output: {result.stdout[:100]}"


def run_ccusage_weekly(binary: str) -> tuple[bool, Any, str]:
    """Run ccusage weekly --json --since YYYYMMDD. Returns (ok, data, error_msg).

    Uses the same timeout as the blocks call — weekly scans the same JSONL
    transcripts and has comparable runtime characteristics.
    """
    cmd = [binary, "weekly", "--json", "--since", _since_flag(WEEKLY_DAYS)]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=CCUSAGE_TIMEOUT_S)
    except FileNotFoundError as e:
        return False, None, f"ccusage binary not found: {e}"
    except subprocess.TimeoutExpired:
        return False, None, f"ccusage weekly timed out after {CCUSAGE_TIMEOUT_S}s"
    except Exception as e:
        return False, None, f"ccusage weekly subprocess error: {e}"

    if result.returncode != 0:
        err = (result.stderr or result.stdout or "unknown error").strip()
        return False, None, f"ccusage weekly exited {result.returncode}: {err[:200]}"
    try:
        return True, json.loads(result.stdout), ""
    except json.JSONDecodeError as e:
        return False, None, f"weekly JSON parse error: {e} — output: {result.stdout[:100]}"


def run_ccusage_session(binary: str, days_back: int) -> tuple[bool, Any, str]:
    """Run ccusage session --json --since YYYYMMDD. Returns (ok, data, error_msg).

    Used for per-account attribution: each session row carries a sessionId that
    encodes the project working directory.  Uses the same timeout as blocks/weekly
    since it scans the same JSONL transcripts.
    """
    cmd = [binary, "session", "--json", "--since", _since_flag(days_back)]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=CCUSAGE_TIMEOUT_S)
    except FileNotFoundError as e:
        return False, None, f"ccusage binary not found: {e}"
    except subprocess.TimeoutExpired:
        return False, None, f"ccusage session timed out after {CCUSAGE_TIMEOUT_S}s"
    except Exception as e:
        return False, None, f"ccusage session subprocess error: {e}"

    if result.returncode != 0:
        err = (result.stderr or result.stdout or "unknown error").strip()
        return False, None, f"ccusage session exited {result.returncode}: {err[:200]}"
    try:
        return True, json.loads(result.stdout), ""
    except json.JSONDecodeError as e:
        return False, None, f"session JSON parse error: {e} — output: {result.stdout[:100]}"


def run_ccusage_daily_breakdown(binary: str, days_back: int) -> tuple[bool, Any, str]:
    """Run ccusage daily --json --breakdown --since YYYYMMDD. Returns (ok, data, error_msg).

    The daily command with --breakdown returns per-model token + cost splits in
    each day's ``modelBreakdowns`` list.  This is the only ccusage command that
    gives a reliable per-model token/cost split (blocks carries only a ``models``
    list with no per-model token counts; session carries no model info at all).

    Uses the same timeout as the other calls since it scans the same JSONL
    transcripts.
    """
    cmd = [binary, "daily", "--json", "--breakdown", "--since", _since_flag(days_back)]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=CCUSAGE_TIMEOUT_S)
    except FileNotFoundError as e:
        return False, None, f"ccusage binary not found: {e}"
    except subprocess.TimeoutExpired:
        return False, None, f"ccusage daily timed out after {CCUSAGE_TIMEOUT_S}s"
    except Exception as e:
        return False, None, f"ccusage daily subprocess error: {e}"

    if result.returncode != 0:
        err = (result.stderr or result.stdout or "unknown error").strip()
        return False, None, f"ccusage daily exited {result.returncode}: {err[:200]}"
    try:
        return True, json.loads(result.stdout), ""
    except json.JSONDecodeError as e:
        return False, None, f"daily JSON parse error: {e} — output: {result.stdout[:100]}"


# --- data helpers ---
def _utc_now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")

def _utc_now_unix() -> int:
    return int(datetime.datetime.now(datetime.timezone.utc).timestamp())

def _parse_iso(ts: str) -> Optional[datetime.datetime]:
    if not ts:
        return None
    try:
        return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None

def _elapsed_minutes(start_iso: str) -> int:
    start = _parse_iso(start_iso)
    if not start:
        return 0
    return max(0, int((datetime.datetime.now(datetime.timezone.utc) - start).total_seconds() / 60))


def build_active_window(block: dict) -> Optional[dict]:
    """Extract normalised active-window fields from a raw ccusage block."""
    if not block.get("isActive"):
        return None
    burn = block.get("burnRate") or {}
    proj = block.get("projection") or {}
    remaining = int(proj.get("remainingMinutes") or 0)
    return {
        "id": block.get("id", ""),
        "start_time": block.get("startTime", ""),
        "end_time": block.get("endTime", ""),
        "elapsed_minutes": _elapsed_minutes(block.get("startTime", "")),
        "remaining_minutes": remaining,
        "total_tokens": block.get("totalTokens", 0),
        "cost_usd": round(block.get("costUSD", 0.0), 6),
        "models": block.get("models", []),
        "burn_rate": {
            "tokens_per_minute": burn.get("tokensPerMinute", 0.0),
            "cost_per_hour": burn.get("costPerHour", 0.0),
        },
        "projection": {
            "total_tokens": proj.get("totalTokens", 0),
            "total_cost_usd": round(proj.get("totalCost", 0.0), 6),
            "remaining_minutes": remaining,
        },
    }


def build_history(blocks: list[dict]) -> list[dict]:
    """Return last HISTORY_MAX non-gap, non-active blocks oldest-first."""
    return [
        {
            "id": b.get("id", ""), "start_time": b.get("startTime", ""),
            "end_time": b.get("endTime", ""), "total_tokens": b.get("totalTokens", 0),
            "cost_usd": round(b.get("costUSD", 0.0), 6), "is_gap": False,
        }
        for b in blocks if not b.get("isGap") and not b.get("isActive")
    ][-HISTORY_MAX:]


_EMPTY_CALIBRATION: dict = {
    "max_window_tokens": 0, "max_window_cost_usd": 0.0,
    "max_window_id": "", "p90_window_tokens": 0, "samples": 0,
}


def build_calibration(blocks: list[dict]) -> dict:
    """Compute max + p90 stats for UI progress-bar scaling (100% baseline)."""
    samples = [b for b in blocks if not b.get("isGap") and not b.get("isActive")]
    if not samples:
        return dict(_EMPTY_CALIBRATION)
    token_counts = sorted(b.get("totalTokens", 0) for b in samples)
    max_block = max(samples, key=lambda b: b.get("totalTokens", 0))
    n = len(token_counts)
    p90 = token_counts[max(0, int(n * 0.90) - 1)]
    return {
        "max_window_tokens": max_block.get("totalTokens", 0),
        "max_window_cost_usd": round(max_block.get("costUSD", 0.0), 6),
        "max_window_id": max_block.get("id", ""),
        "p90_window_tokens": p90,
        "samples": n,
    }


def build_totals(blocks: list[dict]) -> dict:
    """Aggregate today + last-7d (system timezone, includes active block)."""
    local_now = datetime.datetime.now()
    today_start = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
    seven_days_ago = today_start - datetime.timedelta(days=7)
    today_tok = today_cost = last7_tok = last7_cost = 0
    for b in blocks:
        if b.get("isGap"):
            continue
        tok = b.get("totalTokens", 0)
        cost = b.get("costUSD", 0.0)
        start_utc = _parse_iso(b.get("startTime", ""))
        if not start_utc:
            continue
        sl = start_utc.astimezone(tz=None).replace(tzinfo=None)
        if sl >= today_start:
            today_tok += tok; today_cost += cost
        if sl >= seven_days_ago:
            last7_tok += tok; last7_cost += cost
    return {
        "today_tokens": today_tok, "today_cost_usd": round(today_cost, 6),
        "last_7d_tokens": last7_tok, "last_7d_cost_usd": round(last7_cost, 6),
    }


_MODEL_TIERS = ("Opus", "Sonnet", "Haiku", "Fable", "Other")


def _model_tier(model_id: str) -> str:
    """Collapse a raw model ID to one of five canonical tiers.

    Matching is case-insensitive substring search on the tier name so future
    point-version model IDs (e.g. claude-opus-5-0) keep working automatically.
    The check order (Opus → Sonnet → Haiku → Fable → Other) is intentional:
    if Anthropic ever releases a model whose ID embeds two tier names the
    first match wins (currently hypothetical; order is stable and documented).

    Examples:
      "claude-opus-4-8"            → "Opus"
      "claude-sonnet-4-6"          → "Sonnet"
      "claude-haiku-4-5-20251001"  → "Haiku"
      "claude-fable-1-0"           → "Fable"
      "claude-unknown-model"       → "Other"
    """
    lower = model_id.lower()
    for tier in ("opus", "sonnet", "haiku", "fable"):
        if tier in lower:
            return tier.capitalize()
    return "Other"


def _empty_by_model_tiers() -> dict:
    """Return a zero-filled tiers dict covering all five model tiers.

    All five tiers are always present so consumers can read any tier key
    without a missing-key guard (mirrors how build_accounts initialises
    accumulator buckets before iterating session rows).
    """
    return {
        tier: {
            "today_tokens": 0,
            "today_cost_usd": 0.0,
            "last_7d_tokens": 0,
            "last_7d_cost_usd": 0.0,
        }
        for tier in _MODEL_TIERS
    }


def build_models_breakdown(daily_rows: list[dict]) -> dict:
    """Aggregate per-model-tier token + cost totals for today and last 7 days.

    Input is the ``daily`` list from ``ccusage daily --json --breakdown``.
    Each row carries a ``modelBreakdowns`` list where each entry has:
      modelName, inputTokens, outputTokens, cacheCreationTokens,
      cacheReadTokens, cost.

    Windowing uses system local midnight (same convention as build_totals):
      today   = rows whose ``date`` string >= today's local date
      last_7d = rows whose ``date`` string >= local date 7 days ago

    Returns a dict ready to write as the top-level ``by_model`` cache key:
      {
        "tiers": {
          "Opus":   {"today_tokens":N,"today_cost_usd":N,
                     "last_7d_tokens":N,"last_7d_cost_usd":N},
          "Sonnet": {...}, "Haiku": {...}, "Fable": {...}, "Other": {...}
        },
        "last_collected_at": "<ISO-8601 UTC>"
      }

    All five tiers are always present (zero-filled when no data), so
    downstream consumers need no missing-key guards.
    """
    local_now = datetime.datetime.now()
    today_date = local_now.date()
    seven_days_ago_date = (local_now - datetime.timedelta(days=7)).date()

    tiers = _empty_by_model_tiers()

    for row in daily_rows:
        row_date_str = row.get("date", "")
        try:
            row_date = datetime.date.fromisoformat(row_date_str)
        except (ValueError, AttributeError):
            continue

        is_today = row_date >= today_date
        is_7d = row_date >= seven_days_ago_date

        if not is_7d:
            continue  # outside both windows; skip to avoid wasted work

        for mb in row.get("modelBreakdowns", []):
            model_id = mb.get("modelName", "")
            tier = _model_tier(model_id)
            tokens = (
                mb.get("inputTokens", 0)
                + mb.get("outputTokens", 0)
                + mb.get("cacheCreationTokens", 0)
                + mb.get("cacheReadTokens", 0)
            )
            cost = mb.get("cost", 0.0)

            tiers[tier]["last_7d_tokens"] += tokens
            tiers[tier]["last_7d_cost_usd"] += cost
            if is_today:
                tiers[tier]["today_tokens"] += tokens
                tiers[tier]["today_cost_usd"] += cost

    # Round costs to 6 decimal places (matches build_totals/build_accounts convention).
    for entry in tiers.values():
        entry["today_cost_usd"] = round(entry["today_cost_usd"], 6)
        entry["last_7d_cost_usd"] = round(entry["last_7d_cost_usd"], 6)

    return {
        "tiers": tiers,
        "last_collected_at": _utc_now_iso(),
    }


def build_weekly(raw_weeks: list[dict]) -> dict:
    """Build the normalised weekly payload from raw ccusage weekly output.

    The ccusage weekly command returns a list of calendar-week aggregates,
    oldest first, where the last entry is always the current (in-progress)
    week.  We split that into:
      - current_week: the last entry (may be partial if week is still running)
      - history: up to WEEKLY_HISTORY_MAX prior complete weeks, oldest-first

    Each history entry is trimmed to week/totalTokens/totalCost only — keeping
    it lightweight since modelsUsed is only relevant for the current week.
    """
    if not raw_weeks:
        return {
            "last_collected_at": _utc_now_iso(),
            "current_week": None,
            "history": [],
        }

    # Last entry = current (possibly in-progress) week
    current_raw = raw_weeks[-1]
    current_week = {
        "week": current_raw.get("week", ""),
        "totalTokens": current_raw.get("totalTokens", 0),
        "totalCost": round(current_raw.get("totalCost", 0.0), 6),
        "modelsUsed": current_raw.get("modelsUsed", []),
    }

    # Prior weeks → lightweight history entries, capped at WEEKLY_HISTORY_MAX
    prior_weeks = raw_weeks[:-1]
    history = [
        {
            "week": w.get("week", ""),
            "totalTokens": w.get("totalTokens", 0),
            "totalCost": round(w.get("totalCost", 0.0), 6),
        }
        for w in prior_weeks
    ][-WEEKLY_HISTORY_MAX:]

    return {
        "last_collected_at": _utc_now_iso(),
        "current_week": current_week,
        "history": history,
    }


def _load_team_paths() -> dict:
    """Load ~/.aiteamforge/team-paths.json. Returns {} on any error."""
    try:
        return json.loads(TEAM_PATHS_JSON.read_text())
    except Exception:
        return {}


def _encode_path_as_session_id(path: str) -> str:
    """Encode a filesystem path the same way ccusage encodes sessionId.

    ccusage replaces all '/' characters with '-', so /Users/foo/bar becomes
    -Users-foo-bar.  Spaces in directory names also become '-' since ccusage
    uses the raw path separator replacement.
    """
    return path.replace("/", "-").replace(" ", "-")


def build_accounts(
    session_rows: list[dict],
    team_paths: dict,
    session_map_index: Optional["SessionAccountMapIndex"] = None,
) -> tuple[dict, dict]:
    """Build per-account usage breakdown from ccusage session rows.

    Returns (accounts, untagged_bucket) where:
    - accounts: {account_id: {nickname, today_tokens, today_cost_usd,
                              last_7d_tokens, last_7d_cost_usd,
                              all_time_tokens, all_time_cost_usd}}
    - untagged_bucket: same shape + cwds: [list of decoded cwd strings]

    Attribution priority:
    1. Exact encoded-path match or prefix match against team working_dir.
    2. SessionAccountMapIndex tiebreaker for cwds with no team match.
    3. Untagged (pre-isolation) bucket.

    The "today" cutoff uses system local time (midnight today).
    The "last_7d" cutoff uses system local time (midnight 7 days ago).
    All-time uses the full session history (no date filter).
    """
    teams = team_paths.get("teams", {})

    # Pre-encode all team working_dirs for fast comparison.
    # Each entry: (encoded_prefix, account_id, nickname)
    team_encodings: list[tuple[str, str, str]] = []
    for _slug, tdata in teams.items():
        wdir = tdata.get("working_dir", "")
        if not wdir:
            continue
        encoded = _encode_path_as_session_id(wdir)
        account_id = tdata.get("anthropic_account_id") or "default-oauth"
        nickname = tdata.get("anthropic_account_nickname") or account_id
        team_encodings.append((encoded, account_id, nickname))

    # Sort longest-prefix-first so most-specific match wins.
    team_encodings.sort(key=lambda t: len(t[0]), reverse=True)

    local_now = datetime.datetime.now()
    today_start = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
    seven_days_ago = today_start - datetime.timedelta(days=7)

    # Accumulators: {account_id: {nickname, today_tokens, ...}}
    acc: dict[str, dict] = {}
    untagged_tokens_today = untagged_cost_today = 0.0
    untagged_tokens_7d = untagged_cost_7d = 0.0
    untagged_tokens_all = untagged_cost_all = 0.0
    untagged_cwds: list[str] = []
    untagged_cwds_seen: set[str] = set()

    for row in session_rows:
        session_id = row.get("sessionId", "")
        total_tokens = row.get("totalTokens", 0)
        total_cost = row.get("totalCost", 0.0)
        last_activity = row.get("lastActivity", "")  # YYYY-MM-DD local date string

        # Determine "today" and "7d" fractions using lastActivity.
        # lastActivity is a date string; we treat it as a start-of-day marker
        # in system local time.  This is an approximation — the session may
        # span multiple days — but it matches the intent for the UI display.
        try:
            la_date = datetime.datetime.strptime(last_activity, "%Y-%m-%d") if last_activity else None
        except ValueError:
            la_date = None

        is_today = la_date is not None and la_date >= today_start
        is_7d = la_date is not None and la_date >= seven_days_ago

        # Match sessionId against team encodings (exact or prefix).
        matched_account_id: Optional[str] = None
        matched_nickname: Optional[str] = None
        for encoded_prefix, a_id, a_nick in team_encodings:
            if session_id == encoded_prefix or session_id.startswith(encoded_prefix + "-"):
                matched_account_id = a_id
                matched_nickname = a_nick
                break

        # Tiebreaker: SessionAccountMapIndex by decoded cwd.
        if matched_account_id is None and session_map_index is not None:
            # Decode sessionId back to a cwd approximation for map lookup.
            decoded_cwd = session_id.replace("-", "/", 1).replace("-", "/") if session_id.startswith("-") else session_id
            result = session_map_index.most_recent_account_for_cwd(decoded_cwd)
            if result:
                matched_account_id, matched_nickname = result

        if matched_account_id is not None and matched_nickname is not None:
            if matched_account_id not in acc:
                acc[matched_account_id] = {
                    "nickname": matched_nickname,
                    "today_tokens": 0, "today_cost_usd": 0.0,
                    "last_7d_tokens": 0, "last_7d_cost_usd": 0.0,
                    "all_time_tokens": 0, "all_time_cost_usd": 0.0,
                }
            entry = acc[matched_account_id]
            entry["all_time_tokens"] += total_tokens
            entry["all_time_cost_usd"] += total_cost
            if is_7d:
                entry["last_7d_tokens"] += total_tokens
                entry["last_7d_cost_usd"] += total_cost
            if is_today:
                entry["today_tokens"] += total_tokens
                entry["today_cost_usd"] += total_cost
        else:
            # Untagged
            untagged_tokens_all += total_tokens
            untagged_cost_all += total_cost
            if is_7d:
                untagged_tokens_7d += total_tokens
                untagged_cost_7d += total_cost
            if is_today:
                untagged_tokens_today += total_tokens
                untagged_cost_today += total_cost
            # Decode for diagnostics (best-effort; hyphens in dir names are ambiguous)
            decoded_cwd = session_id.replace("-", "/", 1) if session_id.startswith("-") else session_id
            if decoded_cwd not in untagged_cwds_seen:
                untagged_cwds_seen.add(decoded_cwd)
                untagged_cwds.append(decoded_cwd)

    # Round all costs.
    for entry in acc.values():
        entry["today_cost_usd"] = round(entry["today_cost_usd"], 6)
        entry["last_7d_cost_usd"] = round(entry["last_7d_cost_usd"], 6)
        entry["all_time_cost_usd"] = round(entry["all_time_cost_usd"], 6)

    untagged_bucket = {
        "nickname": "Untagged (pre-isolation)",
        "today_tokens": int(untagged_tokens_today),
        "today_cost_usd": round(untagged_cost_today, 6),
        "last_7d_tokens": int(untagged_tokens_7d),
        "last_7d_cost_usd": round(untagged_cost_7d, 6),
        "all_time_tokens": int(untagged_tokens_all),
        "all_time_cost_usd": round(untagged_cost_all, 6),
        "cwds": untagged_cwds,
    }

    return acc, untagged_bucket


# --- SessionAccountMapIndex (auxiliary attribution helper) ---

class SessionAccountMapIndex:
    """Lazy-loaded index of ~/.claude/.session-account-map.jsonl.

    Primary attribution uses team-paths.json working_dir prefix matching.
    This index is an auxiliary tiebreaker: when a cwd doesn't match any
    team's working_dir, the map may still know the account for that cwd
    from past cc-whoami attribution.

    The index auto-rebuilds when the file's mtime changes.
    """

    def __init__(self, path: pathlib.Path = SESSION_ACCOUNT_MAP_JSONL) -> None:
        self._path = path
        self._mtime: Optional[float] = None
        self._stat_error_logged: bool = False
        # {session_uuid: entry_dict}
        self._by_session: dict[str, dict] = {}
        # {cwd: [entry_dict, ...] sorted newest-first}
        self._by_cwd: dict[str, list[dict]] = {}

    def _rebuild(self) -> None:
        self._by_session = {}
        self._by_cwd = {}
        try:
            text = self._path.read_text()
        except Exception:
            return
        entries = []
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            entries.append(entry)
            sid = entry.get("session_id", "")
            if sid:
                self._by_session[sid] = entry
        # Build cwd index sorted newest-first.
        from collections import defaultdict
        cwd_map: dict[str, list[dict]] = defaultdict(list)
        for entry in entries:
            cwd = entry.get("cwd", "")
            if cwd:
                cwd_map[cwd].append(entry)
        for cwd, elist in cwd_map.items():
            self._by_cwd[cwd] = sorted(
                elist,
                key=lambda e: e.get("started_at", ""),
                reverse=True,
            )

    def _refresh_if_stale(self) -> None:
        try:
            mtime = self._path.stat().st_mtime
        except OSError as e:
            if not self._stat_error_logged:
                log_warn(f"SessionAccountMapIndex: stat() failed on {self._path}: {e}; serving stale index")
                self._stat_error_logged = True
            return
        if mtime != self._mtime:
            self._mtime = mtime
            self._rebuild()

    def by_session_id(self, session_uuid: str) -> Optional[dict]:
        """Exact lookup by JSONL filename UUID."""
        self._refresh_if_stale()
        return self._by_session.get(session_uuid)

    def by_cwd(self, cwd: str) -> list[dict]:
        """Return all entries for a given cwd, sorted newest-first."""
        self._refresh_if_stale()
        return self._by_cwd.get(cwd, [])

    def most_recent_account_for_cwd(self, cwd: str) -> Optional[tuple[str, str]]:
        """Return (account_id, nickname) from most recent entry for cwd, or None."""
        self._refresh_if_stale()
        entries = self._by_cwd.get(cwd, [])
        for entry in entries:
            account_id = entry.get("account_id", "")
            if account_id:
                nickname = entry.get("account_nickname", account_id)
                return account_id, nickname
        return None


# --- cache I/O ---

def _empty_untagged_bucket() -> dict:
    """Factory for a zero-filled untagged_bucket dict.

    Use a factory (not a module-level dict literal) so each caller gets its
    own instance and cannot accidentally mutate a shared object.
    """
    return {
        "nickname": "Untagged (pre-isolation)",
        "today_tokens": 0,
        "today_cost_usd": 0.0,
        "last_7d_tokens": 0,
        "last_7d_cost_usd": 0.0,
        "all_time_tokens": 0,
        "all_time_cost_usd": 0.0,
        "cwds": [],
    }


def _migrate_cache_if_needed(cache: dict) -> dict:
    """Upgrade cache in-memory from v1/v2/v3 to v4 shape.

    Migration runs once: the next write_cache() will persist the v4 schema
    so subsequent loads skip this path.

    v2->v3: synthesise empty accounts={} and untagged_bucket that mirrors
    the legacy totals so historical numbers don't vanish from the new UI.

    v3->v4: synthesise zero-filled by_model so consumers that load a stale
    cache before the first v4 collect() don't encounter a missing key.
    """
    if not isinstance(cache, dict):
        return {}
    version = cache.get("schema_version", 1)
    if version >= 4:
        return cache
    prev_totals = cache.get("totals", {})
    # v2->v3: add accounts + untagged_bucket (only needed when upgrading from v1/v2)
    if version < 3:
        cache.setdefault("accounts", {})
        cache.setdefault("untagged_bucket", {
            "nickname": "Untagged (pre-isolation)",
            "today_tokens": prev_totals.get("today_tokens", 0),
            "today_cost_usd": prev_totals.get("today_cost_usd", 0.0),
            "last_7d_tokens": prev_totals.get("last_7d_tokens", 0),
            "last_7d_cost_usd": prev_totals.get("last_7d_cost_usd", 0.0),
            "all_time_tokens": 0,
            "all_time_cost_usd": 0.0,
            "cwds": [],
        })

    # v3->v4: add by_model with zero-filled tiers
    cache.setdefault("by_model", {
        "tiers": _empty_by_model_tiers(),
        "last_collected_at": "",
    })

    cache["schema_version"] = 4
    return cache


def read_prev_cache() -> dict:
    try:
        raw = json.loads(CACHE_PATH.read_text())
        return _migrate_cache_if_needed(raw)
    except Exception:
        return {}

def write_cache(payload: dict) -> None:
    """Atomic write: tmp then os.replace to avoid partial reads."""
    CACHE_TMP_PATH.write_text(json.dumps(payload, indent=2))
    os.replace(CACHE_TMP_PATH, CACHE_PATH)


# --- collection logic ---

def collect(binary: str) -> None:
    """Run one full collection cycle and update the cache file."""
    prev = read_prev_cache()
    now_iso = _utc_now_iso()
    now_unix = _utc_now_unix()

    # Fetch rolling 7-day window
    ok, rolling_data, err = run_ccusage(binary, ROLLING_DAYS)

    if not ok:
        log_error(f"ccusage rolling fetch failed: {err}")
        # Preserve last known good values so UI can show stale-data warning.
        # Weekly, per-account, and per-model data are preserved from previous
        # cache (independent flows) so the UI never blanks out on a transient failure.
        write_cache({
            "schema_version": SCHEMA_VERSION,
            "collected_at": now_iso, "collected_at_unix": now_unix,
            "ccusage_ok": False, "ccusage_error": err,
            "active_window": prev.get("active_window"),
            "history": prev.get("history", []),
            "calibration": prev.get("calibration", dict(_EMPTY_CALIBRATION)),
            "totals": prev.get("totals", {
                "today_tokens": 0, "today_cost_usd": 0.0,
                "last_7d_tokens": 0, "last_7d_cost_usd": 0.0,
            }),
            "weekly": prev.get("weekly"),
            "weekly_error": prev.get("weekly_error"),
            "accounts": prev.get("accounts", {}),
            "untagged_bucket": prev.get("untagged_bucket", _empty_untagged_bucket()),
            "by_model": prev.get("by_model", {
                "tiers": _empty_by_model_tiers(),
                "last_collected_at": "",
            }),
        })
        return

    rolling_blocks = rolling_data.get("blocks", [])

    # Separate 30-day call for stable calibration baseline
    cal_ok, cal_data, cal_err = run_ccusage(binary, CALIBRATION_DAYS)
    if cal_ok:
        calibration = build_calibration(cal_data.get("blocks", []))
    else:
        log_warn(f"calibration fetch failed ({cal_err}); using prev calibration")
        calibration = prev.get("calibration", dict(_EMPTY_CALIBRATION))

    # Find active block
    active_block = next((b for b in rolling_blocks if b.get("isActive")), None)
    active_window = build_active_window(active_block) if active_block else None

    history = build_history(rolling_blocks)
    totals = build_totals(rolling_blocks)

    # Weekly collection — independent of the blocks flow; failures are tolerated.
    # On failure: weekly=null + weekly_error set so consumers can degrade gracefully.
    weekly_ok, weekly_data, weekly_err = run_ccusage_weekly(binary)
    if weekly_ok:
        weekly = build_weekly(weekly_data.get("weekly", []))
        weekly_error = None
        log_info(
            f"Weekly: current_week={weekly['current_week']['week'] if weekly['current_week'] else 'none'}, "
            f"history_weeks={len(weekly['history'])}"
        )
    else:
        log_warn(f"ccusage weekly fetch failed ({weekly_err}); writing weekly=null")
        weekly = None
        weekly_error = weekly_err

    # Per-account attribution — independent of blocks flow; failures are tolerated.
    # On failure: preserve previous accounts/untagged_bucket so UI doesn't blank out.
    session_ok, session_data, session_err = run_ccusage_session(binary, ROLLING_DAYS)
    if session_ok:
        team_paths = _load_team_paths()
        session_rows = session_data.get("sessions", [])
        session_map = SessionAccountMapIndex()
        accounts, untagged_bucket = build_accounts(
            session_rows, team_paths, session_map
        )
        log_info(
            f"Accounts: {len(accounts)} account(s) attributed, "
            f"untagged_cwds={len(untagged_bucket.get('cwds', []))}"
        )
    else:
        log_warn(f"ccusage session fetch failed ({session_err}); preserving prev account data")
        accounts = prev.get("accounts", {})
        untagged_bucket = prev.get("untagged_bucket", _empty_untagged_bucket())

    # Per-model breakdown — independent of blocks/session flows; failures are tolerated.
    # On failure: preserve previous by_model so the UI panel doesn't blank out.
    models_ok, models_data, models_err = run_ccusage_daily_breakdown(binary, ROLLING_DAYS)
    if models_ok:
        by_model = build_models_breakdown(models_data.get("daily", []))
        log_info(
            f"Models: tiers={list(by_model['tiers'].keys())}, "
            f"today_total_tokens="
            f"{sum(t['today_tokens'] for t in by_model['tiers'].values())}"
        )
    else:
        log_warn(f"ccusage daily breakdown fetch failed ({models_err}); preserving prev by_model")
        by_model = prev.get("by_model", {
            "tiers": _empty_by_model_tiers(),
            "last_collected_at": "",
        })

    payload = {
        "schema_version": SCHEMA_VERSION,
        "collected_at": now_iso,
        "collected_at_unix": now_unix,
        "ccusage_ok": True,
        "ccusage_error": None,
        "active_window": active_window,
        "history": history,
        "calibration": calibration,
        "totals": totals,
        "weekly": weekly,
        "weekly_error": weekly_error,
        "accounts": accounts,
        "untagged_bucket": untagged_bucket,
        "by_model": by_model,
    }
    write_cache(payload)

    active_label = "active" if active_window else "idle"
    log_info(
        f"Collected: {active_label}, "
        f"history={len(history)}, "
        f"cal_samples={calibration.get('samples', 0)}, "
        f"max_window_tokens={calibration.get('max_window_tokens', 0):,}, "
        f"weekly={'ok' if weekly_ok else 'failed'}, "
        f"accounts={'ok' if session_ok else 'failed'}, "
        f"models={'ok' if models_ok else 'failed'}"
    )


# --- PID management ---
def _is_pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0); return True
    except (ProcessLookupError, PermissionError):
        return False

def acquire_pid_or_exit() -> None:
    if PID_PATH.exists():
        try:
            existing = int(PID_PATH.read_text().strip())
        except (ValueError, OSError):
            existing = None
        if existing and _is_pid_alive(existing):
            log_info(f"Collector already running (PID {existing}). Exiting.")
            sys.exit(0)
        else:
            log_info("Stale PID file found; taking over.")
    PID_PATH.write_text(str(os.getpid()))

def release_pid() -> None:
    try:
        PID_PATH.unlink(missing_ok=True)
    except Exception:
        pass


# --- signal handling + main loop ---
_shutdown_requested = False

def _handle_sigterm(signum: int, frame: Any) -> None:
    global _shutdown_requested
    log_info("SIGTERM received — shutting down gracefully.")
    _shutdown_requested = True


def _source_changed(baseline: Optional[float]) -> bool:
    """Return True if __file__'s current mtime is newer than *baseline*.

    Used by run_loop() to detect that the source has been refreshed on disk
    (dev sync-develop or aiteamforge upgrade) while the daemon is running.
    Returns False when baseline is None (stat failed at startup) so the daemon
    never crashes over a missing baseline.  Testable seam: pass any float as
    baseline; the function does its own stat of __file__.  (XACA-0680)
    """
    if baseline is None:
        return False
    try:
        return os.path.getmtime(__file__) > baseline
    except OSError:
        return False


def run_loop(binary: str) -> None:
    signal.signal(signal.SIGTERM, _handle_sigterm)
    acquire_pid_or_exit()
    log_info(f"Collector started (PID {os.getpid()}), polling every {POLL_INTERVAL_S}s")
    try:
        source_mtime_baseline: Optional[float] = os.path.getmtime(__file__)
    except OSError:
        source_mtime_baseline = None
    try:
        while not _shutdown_requested:
            if _source_changed(source_mtime_baseline):
                log_info(
                    "Source file changed on disk (mtime advanced) — exiting cleanly"
                    " so supervisor respawns updated code (XACA-0680)."
                )
                break
            try:
                collect(binary)
            except Exception as e:
                log_error(f"Unhandled exception in collect(): {e}")
            for _ in range(POLL_INTERVAL_S):
                if _shutdown_requested:
                    break
                time.sleep(1)
    except KeyboardInterrupt:
        log_info("KeyboardInterrupt — shutting down.")
    finally:
        release_pid()
        log_info("Collector stopped.")


# --- entrypoint ---
def main() -> None:
    parser = argparse.ArgumentParser(description="Claude usage cache collector daemon for LCARS.")
    parser.add_argument("--once", action="store_true",
                        help="Run one collection cycle and exit (for tests/fallback).")
    parser.add_argument("--foreground", action="store_true",
                        help="Explicit foreground loop flag (default behaviour; no daemonization).")
    args = parser.parse_args()

    binary = find_ccusage()
    if not binary:
        log_error("ccusage binary not found. Install via npm/npx or ensure it is in PATH or a known fnm location.")
        sys.exit(1)
    log_info(f"Using ccusage at: {binary}")

    # Ensure secure runtime dir exists before any I/O (covers both --once and loop modes).
    ensure_runtime_dir()

    if args.once:
        collect(binary)
    else:
        run_loop(binary)

if __name__ == "__main__":
    main()
