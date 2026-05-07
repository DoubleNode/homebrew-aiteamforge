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
cache to /tmp/lcars-ccusage-cache.json atomically. Multiple UI clients
(LCARS dashboard, agent panels) read the cache without repeatedly re-scanning
the underlying JSONL files.

Cache schema (v2):
{
  "schema_version": 2,
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
  "weekly_error": str | null  // set when weekly collection fails
}

v1 -> v2 change notes:
- All v1 fields are preserved unchanged for backward compatibility.
- New top-level "weekly" key contains per-calendar-week aggregates.
- New top-level "weekly_error" key captures weekly-fetch failures without
  affecting ccusage_ok (the 5h blocks flow is independent).
- schema_version bumped from 1 to 2.

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

# --- constants ---
CACHE_PATH = pathlib.Path("/tmp/lcars-ccusage-cache.json")
CACHE_TMP_PATH = pathlib.Path("/tmp/lcars-ccusage-cache.tmp.json")
PID_PATH = pathlib.Path("/tmp/lcars-ccusage-collector.pid")
# POLL_INTERVAL_S is the SLEEP between completed scans, not the wall-clock
# period of the loop. The main loop is sequential: do_collection() blocks for
# the scan (up to CCUSAGE_TIMEOUT_S), THEN we sleep POLL_INTERVAL_S. So polls
# can never stack regardless of which value is larger — total cycle is
# (scan_duration + POLL_INTERVAL_S). 180s sleep + ~65s typical scan ≈ 4 min
# between cache refreshes on a healthy system, headroom for 240s slow scans.
POLL_INTERVAL_S = 180
CCUSAGE_TIMEOUT_S = 240  # ccusage scans JSONL transcripts; ~65s typical, 200s+ under load
HISTORY_MAX = 50
SCHEMA_VERSION = 2
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


# --- cache I/O ---
def read_prev_cache() -> dict:
    try:
        return json.loads(CACHE_PATH.read_text())
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
        # Weekly data is preserved as-is from previous cache (independent flow).
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
    }
    write_cache(payload)

    active_label = "active" if active_window else "idle"
    log_info(
        f"Collected: {active_label}, "
        f"history={len(history)}, "
        f"cal_samples={calibration.get('samples', 0)}, "
        f"max_window_tokens={calibration.get('max_window_tokens', 0):,}, "
        f"weekly={'ok' if weekly_ok else 'failed'}"
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

def run_loop(binary: str) -> None:
    signal.signal(signal.SIGTERM, _handle_sigterm)
    acquire_pid_or_exit()
    log_info(f"Collector started (PID {os.getpid()}), polling every {POLL_INTERVAL_S}s")
    try:
        while not _shutdown_requested:
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

    if args.once:
        collect(binary)
    else:
        run_loop(binary)

if __name__ == "__main__":
    main()
