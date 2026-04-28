"""ccusage heuristics — policy layer for the Claude Usage Monitor (XACA-0243).

This module is pure policy: it consumes the daemon-produced cache (see XACA-0243-001
which writes ``/tmp/lcars-ccusage-cache.json``) and emits a UI-ready status dict
consumed by the LCARS API endpoint (XACA-0243-003).

It performs no I/O, no subprocess calls, and never reaches out to ccusage itself.
The daemon owns freshness; this module owns interpretation.

==============================================================================
BAND THRESHOLDS — RATIONALE
==============================================================================
We classify usage into three bands based on percentage of the *historical*
window cap (``calibration.max_window_tokens``), NOT against Anthropic's
published cap. Anthropic's published limits are fuzzy (per-plan, per-model,
soft-throttled, change without notice). The largest window we have actually
been allowed to complete is a far more honest ceiling.

  GREEN:  used_pct_of_cap < 60   — comfortable, no concern
  AMBER:  60 <= used_pct < 85    — pay attention; consider pacing
  RED:    used_pct >= 85         — close to historical limits; throttle now

Why 60/85 instead of 70/90? Because we want the AMBER warning to fire while
there is still time to course-correct. By the time you are at 85% with a high
burn rate, the projected end-of-window is already over 100%, so RED at 85
gives roughly one window-quarter of useful warning.

Bands are applied symmetrically to:
  * ``current.band``         — based on tokens used right now
  * ``projection.projected_band`` — based on projected end-of-window tokens

Projected band is the early-warning signal: if we are 30 minutes into a
five-hour window and projected to land at 95% of cap, that is a RED projection
even when current.band is still GREEN.

==============================================================================
CALIBRATION CONFIDENCE
==============================================================================
``calibration.max_window_tokens`` is only meaningful once we have collected a
handful of completed windows. Confidence is reported as:

  HIGH   — samples >= 20  (multiple weeks of history)
  MEDIUM — samples >=  5  (enough to be directional)
  LOW    — samples <   5  (statistically uninformative)

When ``samples < 5`` we deliberately suppress band classification (returning
``"UNKNOWN"`` instead of GREEN/AMBER/RED) for both ``current.band`` and
``projected_band``. Showing GREEN against a noisy ceiling is worse than
showing UNKNOWN — it builds false confidence.

==============================================================================
PROJECTION MATH
==============================================================================
We prefer ccusage's own projection (``active_window.projection``) when present,
since ccusage already accounts for burn-rate smoothing. We only refuse to
project when ``elapsed_minutes < PROJECTION_MIN_ELAPSED_MINUTES``: too little
time has passed for the burn rate to stabilize.

For ``minutes_to_cap`` we solve linearly:
    minutes_to_cap = (max_window_tokens - tokens_used) / tokens_per_minute
and clamp the result to ``remaining_minutes``. If the solution exceeds
``remaining_minutes`` (or burn rate is zero), the window will not hit the
cap and ``minutes_to_cap`` is reported as ``None``.
"""

from __future__ import annotations

import datetime
import time
from typing import Any

SCHEMA_VERSION = 1

# Cache is considered stale once it is older than this many seconds.
#
# Why 300s (5 minutes)?
# The ccusage collector daemon runs every ~60s, but a full ccusage invocation
# (spawning the Node binary, waiting for API responses, writing JSON) can take
# up to ~90–120s under load. Back-to-back slow cycles mean the cache can
# legitimately be 120–250s old without any actual staleness problem. Setting
# the threshold at 120s (one full cycle) caused stale=True to fire on almost
# every poll in practice.
#
# 300s = 5 minutes = 2x the worst-case collector cycle time. This gives one
# complete collection cycle of headroom before we consider the data stale,
# eliminating near-constant stale badges during normal operation while still
# alerting promptly when the daemon truly stops writing.
STALE_THRESHOLD_SECONDS = 300

# Below this many minutes elapsed in a window, the burn rate is too noisy to
# project end-of-window numbers usefully. ccusage's own projection is also
# unstable in this range.
PROJECTION_MIN_ELAPSED_MINUTES = 5

# Weekly cache is considered stale once ``weekly.last_collected_at`` is older
# than this many seconds.
#
# Why 600s (10 minutes)?  The collector cycle is ~4 min end-to-end (180s sleep
# + ~65s scan) and the weekly ccusage call runs inside the same cycle.  600s
# gives one full collection cycle of headroom on top of the worst-case cycle
# time (~240s scan + 180s sleep = ~420s), preventing constant stale badges
# during normal operation while still alerting when the daemon truly stops.
WEEKLY_STALE_THRESHOLD_SECONDS = 600

# Minimum number of prior-week history entries required for HIGH confidence in
# the weekly band classification.  Below this threshold, band is suppressed to
# UNKNOWN regardless of token counts.  4 weeks = roughly one calendar month of
# history, achievable within a month of first install.
WEEKLY_HIGH_CONFIDENCE_MIN_SAMPLES = 4

# Band cutoffs as percentage of historical window cap.
_BAND_AMBER_CUTOFF = 60.0
_BAND_RED_CUTOFF = 85.0

# Calibration confidence thresholds (sample counts).
_CALIBRATION_HIGH_SAMPLES = 20
_CALIBRATION_MEDIUM_SAMPLES = 5

# How many recent non-gap windows to surface in the history slice.
_HISTORY_LIMIT = 7


def classify_band(used_pct: float) -> str:
    """Return ``'GREEN' | 'AMBER' | 'RED'`` for a given percentage of cap.

    This function does not know about calibration confidence — callers must
    suppress to ``'UNKNOWN'`` separately when ``samples`` is too small.
    """
    if used_pct < _BAND_AMBER_CUTOFF:
        return "GREEN"
    if used_pct < _BAND_RED_CUTOFF:
        return "AMBER"
    return "RED"


def _calibration_confidence(samples: int) -> str:
    """Map calibration sample count to a confidence label."""
    if samples >= _CALIBRATION_HIGH_SAMPLES:
        return "HIGH"
    if samples >= _CALIBRATION_MEDIUM_SAMPLES:
        return "MEDIUM"
    return "LOW"


def _safe_pct(numerator: float, denominator: float) -> float:
    """Compute ``numerator / denominator * 100`` with zero-denominator guard."""
    if denominator <= 0:
        return 0.0
    return (numerator / denominator) * 100.0


def compute_projection(
    active_window: dict[str, Any] | None,
    calibration: dict[str, Any] | None,
) -> dict[str, Any] | None:
    """Project end-of-window tokens, cost, and time-to-cap.

    Returns ``None`` when there is no active window or when too little time
    has elapsed for a meaningful projection. The returned dict shape matches
    the ``projection`` slot in :func:`evaluate`'s output, minus the
    ``trustworthy`` flag which is the caller's responsibility (it depends on
    staleness, which this function does not see).

    Math:
        * Prefer ``active_window['projection']`` if ccusage supplied one.
        * Fall back to ``tokens_used + burn_rate * remaining_minutes``.
        * ``minutes_to_cap`` is linear and clamped to ``remaining_minutes``.
    """
    if not active_window:
        return None

    elapsed = active_window.get("elapsed_minutes") or 0
    if elapsed < PROJECTION_MIN_ELAPSED_MINUTES:
        return None

    tokens_used = active_window.get("total_tokens") or 0
    cost_used = active_window.get("cost_usd") or 0.0
    remaining_minutes = active_window.get("remaining_minutes") or 0
    burn = active_window.get("burn_rate") or {}
    tokens_per_minute = burn.get("tokens_per_minute") or 0.0
    cost_per_hour = burn.get("cost_per_hour") or 0.0

    # Prefer ccusage's own projection if available.
    ccusage_projection = active_window.get("projection") or {}
    projected_tokens = ccusage_projection.get("total_tokens")
    projected_cost = ccusage_projection.get("total_cost_usd")

    if projected_tokens is None:
        projected_tokens = tokens_used + (tokens_per_minute * remaining_minutes)
    if projected_cost is None:
        projected_cost = cost_used + (cost_per_hour * remaining_minutes / 60.0)

    cal = calibration or {}
    max_tokens = cal.get("max_window_tokens") or 0

    projected_pct = _safe_pct(projected_tokens, max_tokens)
    will_hit_cap = max_tokens > 0 and projected_tokens >= max_tokens

    # minutes_to_cap: linear extrapolation from current burn rate.
    minutes_to_cap: float | None
    if tokens_per_minute <= 0 or max_tokens <= 0:
        minutes_to_cap = None
    else:
        tokens_to_cap = max_tokens - tokens_used
        if tokens_to_cap <= 0:
            # Already over the historical cap.
            minutes_to_cap = 0.0
        else:
            raw = tokens_to_cap / tokens_per_minute
            if raw >= remaining_minutes:
                # Won't hit cap before window naturally ends.
                minutes_to_cap = None
            else:
                minutes_to_cap = raw

    return {
        "projected_tokens": projected_tokens,
        "projected_cost_usd": projected_cost,
        "projected_pct_of_cap": projected_pct,
        "will_hit_cap": will_hit_cap,
        "minutes_to_cap": minutes_to_cap,
    }


def _empty_response(
    *,
    stale: bool,
    stale_age_seconds: int,
    ccusage_error: str | None,
    calibration: dict[str, Any] | None = None,
    history: list[dict[str, Any]] | None = None,
    totals: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build a response for unusable / missing cache cases."""
    cal_payload: dict[str, Any]
    if calibration:
        samples = calibration.get("samples") or 0
        cal_payload = {
            "max_window_tokens": calibration.get("max_window_tokens") or 0,
            "max_window_cost_usd": calibration.get("max_window_cost_usd") or 0.0,
            "samples": samples,
            "confidence": _calibration_confidence(samples),
        }
    else:
        cal_payload = {
            "max_window_tokens": 0,
            "max_window_cost_usd": 0.0,
            "samples": 0,
            "confidence": "LOW",
        }

    return {
        "schema_version": SCHEMA_VERSION,
        "ok": False,
        "stale": stale,
        "stale_age_seconds": stale_age_seconds,
        "ccusage_error": ccusage_error,
        "current": None,
        "projection": None,
        "calibration": cal_payload,
        "history": history or [],
        "totals": totals or {},
    }


def _band_or_unknown(used_pct: float, samples: int) -> str:
    """Return a band label, suppressing to UNKNOWN when calibration is thin."""
    if samples < _CALIBRATION_MEDIUM_SAMPLES:
        return "UNKNOWN"
    return classify_band(used_pct)


def _build_history(
    raw_history: list[dict[str, Any]],
    max_window_tokens: int,
    samples: int,
) -> list[dict[str, Any]]:
    """Filter to last N non-gap windows and assign each a band."""
    non_gap = [w for w in raw_history if not w.get("is_gap")]
    recent = non_gap[-_HISTORY_LIMIT:]
    out: list[dict[str, Any]] = []
    for window in recent:
        tokens = window.get("total_tokens") or 0
        pct = _safe_pct(tokens, max_window_tokens)
        out.append({**window, "used_pct_of_cap": pct, "band": _band_or_unknown(pct, samples)})
    return out


def evaluate(
    cache: dict[str, Any] | None,
    now_unix: int | None = None,
) -> dict[str, Any]:
    """Translate the daemon cache into a UI-ready status dict.

    See the module docstring for output schema and band rationale. Pure
    function: ``now_unix`` is injectable for testability and defaults to
    ``time.time()`` when omitted.
    """
    now = int(now_unix if now_unix is not None else time.time())

    # Case 1: no cache at all (daemon hasn't written yet, file missing).
    if cache is None:
        return _empty_response(
            stale=True,
            stale_age_seconds=0,
            ccusage_error=None,
        )

    collected_at = int(cache.get("collected_at_unix") or 0)
    stale_age_seconds = max(0, now - collected_at) if collected_at else 0
    is_stale = collected_at == 0 or stale_age_seconds > STALE_THRESHOLD_SECONDS

    raw_calibration = cache.get("calibration") or {}
    raw_history = cache.get("history") or []
    raw_totals = cache.get("totals") or {}

    samples = int(raw_calibration.get("samples") or 0)
    max_window_tokens = int(raw_calibration.get("max_window_tokens") or 0)

    calibration_payload = {
        "max_window_tokens": max_window_tokens,
        "max_window_cost_usd": raw_calibration.get("max_window_cost_usd") or 0.0,
        "samples": samples,
        "confidence": _calibration_confidence(samples),
    }
    history_payload = _build_history(raw_history, max_window_tokens, samples)

    # Case 2: ccusage itself reported failure. Surface the error but keep
    # last-known calibration/history/totals so the UI is not blank.
    if not cache.get("ccusage_ok", False):
        active = cache.get("active_window")
        current_payload = _build_current(active, max_window_tokens, samples) if active else None
        return {
            "schema_version": SCHEMA_VERSION,
            "ok": False,
            "stale": is_stale,
            "stale_age_seconds": stale_age_seconds,
            "ccusage_error": cache.get("ccusage_error"),
            "current": current_payload,
            "projection": None,
            "calibration": calibration_payload,
            "history": history_payload,
            "totals": raw_totals,
        }

    active = cache.get("active_window")
    current_payload = _build_current(active, max_window_tokens, samples) if active else None

    # Projection: refuse if active window absent OR cache is stale.
    projection_payload: dict[str, Any] | None = None
    if active is not None and not is_stale:
        proj = compute_projection(active, raw_calibration)
        if proj is not None:
            proj["projected_band"] = _band_or_unknown(proj["projected_pct_of_cap"], samples)
            proj["trustworthy"] = True
            projection_payload = proj
    elif active is not None and is_stale:
        # Stale but window exists — emit a marker projection so the UI can
        # render an "untrusted" overlay rather than hiding the row entirely.
        proj = compute_projection(active, raw_calibration)
        if proj is not None:
            proj["projected_band"] = _band_or_unknown(proj["projected_pct_of_cap"], samples)
            proj["trustworthy"] = False
            projection_payload = proj

    return {
        "schema_version": SCHEMA_VERSION,
        "ok": not is_stale,
        "stale": is_stale,
        "stale_age_seconds": stale_age_seconds,
        "ccusage_error": cache.get("ccusage_error"),
        "current": current_payload,
        "projection": projection_payload,
        "calibration": calibration_payload,
        "history": history_payload,
        "totals": raw_totals,
    }


def _build_current(
    active: dict[str, Any] | None,
    max_window_tokens: int,
    samples: int,
) -> dict[str, Any]:
    """Build the ``current`` slot. Caller decides whether ``active`` is None."""
    if not active:
        return {
            "in_window": False,
            "window_start": None,
            "window_end": None,
            "elapsed_minutes": 0,
            "remaining_minutes": 0,
            "tokens_used": 0,
            "cost_usd": 0.0,
            "burn_tokens_per_minute": 0.0,
            "burn_cost_per_hour": 0.0,
            "used_pct_of_cap": 0.0,
            "band": _band_or_unknown(0.0, samples),
        }

    burn = active.get("burn_rate") or {}
    tokens_used = active.get("total_tokens") or 0
    pct = _safe_pct(tokens_used, max_window_tokens)
    return {
        "in_window": True,
        "window_start": active.get("start_time"),
        "window_end": active.get("end_time"),
        "elapsed_minutes": active.get("elapsed_minutes") or 0,
        "remaining_minutes": active.get("remaining_minutes") or 0,
        "tokens_used": tokens_used,
        "cost_usd": active.get("cost_usd") or 0.0,
        "burn_tokens_per_minute": burn.get("tokens_per_minute") or 0.0,
        "burn_cost_per_hour": burn.get("cost_per_hour") or 0.0,
        "used_pct_of_cap": pct,
        "band": _band_or_unknown(pct, samples),
    }


# ---------------------------------------------------------------------------
# Weekly heuristics (XACA-0250-003)
# ---------------------------------------------------------------------------

def _format_time_to_reset(seconds_remaining: int) -> str:
    """Return a human-friendly duration string for ``seconds_remaining``.

    Examples: 0 -> "0m", 45 -> "45s", 3661 -> "1h 1m", 90061 -> "1d 1h".
    Granularity: days + hours when >= 1 day; hours + minutes when >= 1 hour;
    minutes + seconds when < 1 hour.
    """
    if seconds_remaining <= 0:
        return "0m"
    days, rem = divmod(seconds_remaining, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, secs = divmod(rem, 60)

    if days >= 1:
        if hours:
            return f"{days}d {hours}h"
        return f"{days}d"
    if hours >= 1:
        if minutes:
            return f"{hours}h {minutes}m"
        return f"{hours}h"
    if minutes >= 1:
        if secs:
            return f"{minutes}m {secs}s"
        return f"{minutes}m"
    return f"{secs}s"


def _parse_week_anchor(week_str: str) -> datetime.datetime | None:
    """Parse an ISO date string like ``"2026-04-28"`` as a UTC midnight datetime.

    Returns ``None`` on parse failure so callers can degrade gracefully.
    """
    if not week_str:
        return None
    try:
        d = datetime.date.fromisoformat(week_str)
        return datetime.datetime(d.year, d.month, d.day, tzinfo=datetime.timezone.utc)
    except (ValueError, AttributeError):
        return None


def evaluate_weekly(
    cache: dict[str, Any] | None,
    now_utc: datetime.datetime | None = None,
) -> dict[str, Any]:
    """Translate the ``weekly`` block from the daemon cache into a UI-ready dict.

    Mirrors the design of :func:`evaluate` for the 5h-window path.  Pure
    function: ``now_utc`` is injectable for testability and defaults to
    ``datetime.datetime.now(UTC)`` when omitted.

    Return shape (success)::

        {
            "available": True,
            "used_pct": float,
            "band": "GREEN" | "AMBER" | "RED" | "UNKNOWN",
            "time_to_reset": "11h 18m",
            "seconds_remaining": int,
            "tokens_used": int,
            "tokens_cap": int,
            "calibrated": bool,   # False when history is empty
            "confidence": "HIGH" | "LOW",
            "stale": bool,
        }

    Return shape (unavailable)::

        {"available": False, "reason": "<str>"}

    Unavailable sentinel is returned when:
      - ``cache`` is ``None`` or ``schema_version < 2``
      - ``weekly`` key is absent or ``None`` in the cache
      - ``current_week`` is absent or ``None`` in the weekly block
    """
    # Unavailability guard 1: no cache, or pre-v2 schema.
    if cache is None:
        return {"available": False, "reason": "cache unavailable"}
    schema_version = cache.get("schema_version") or 0
    if schema_version < 2:
        return {"available": False, "reason": f"schema_version {schema_version} < 2"}

    # Unavailability guard 2: weekly block absent or null (weekly call failed).
    weekly = cache.get("weekly")
    if weekly is None:
        reason = cache.get("weekly_error") or "weekly data not collected"
        return {"available": False, "reason": reason}

    # Unavailability guard 3: no current_week (edge case: brand-new install, no data yet).
    current_week = weekly.get("current_week")
    if current_week is None:
        return {"available": False, "reason": "no current week data"}

    # --- Staleness ---
    now = now_utc if now_utc is not None else datetime.datetime.now(datetime.timezone.utc)
    last_collected_raw = weekly.get("last_collected_at") or ""
    is_stale = True  # default-stale when timestamp is missing or unparseable
    if last_collected_raw:
        try:
            last_collected = datetime.datetime.fromisoformat(
                last_collected_raw.replace("Z", "+00:00")
            )
            age_seconds = (now - last_collected).total_seconds()
            is_stale = age_seconds > WEEKLY_STALE_THRESHOLD_SECONDS
        except (ValueError, TypeError):
            pass

    # --- Calibration from history ---
    history: list[dict[str, Any]] = weekly.get("history") or []
    tokens_cap: int
    calibrated: bool
    if history:
        tokens_cap = max(int(w.get("totalTokens") or 0) for w in history)
        calibrated = True
    else:
        tokens_cap = 0
        calibrated = False

    # Confidence: mirrors session calibration — based on number of history weeks.
    # Weekly has fewer samples than 5h windows; we use a simplified two-tier model:
    # HIGH = WEEKLY_HIGH_CONFIDENCE_MIN_SAMPLES+ prior weeks (a month of data), LOW otherwise.
    confidence = "HIGH" if len(history) >= WEEKLY_HIGH_CONFIDENCE_MIN_SAMPLES else "LOW"

    # --- Token usage ---
    tokens_used = int(current_week.get("totalTokens") or 0)

    # --- Band classification ---
    if not calibrated or tokens_cap <= 0:
        band = "UNKNOWN"
        used_pct: float = 0.0
    else:
        used_pct = _safe_pct(tokens_used, tokens_cap)
        # Suppress band to UNKNOWN when confidence is LOW (thin history).
        if confidence == "LOW":
            band = "UNKNOWN"
        else:
            band = classify_band(used_pct)

    # --- Time to reset ---
    week_str = current_week.get("week") or ""
    week_start = _parse_week_anchor(week_str)
    if week_start is not None:
        week_end = week_start + datetime.timedelta(days=7)
        delta = (week_end - now).total_seconds()
        seconds_remaining = max(0, int(delta))
    else:
        seconds_remaining = 0

    time_to_reset = _format_time_to_reset(seconds_remaining)

    return {
        "available": True,
        "used_pct": used_pct,
        "band": band,
        "time_to_reset": time_to_reset,
        "seconds_remaining": seconds_remaining,
        "tokens_used": tokens_used,
        "tokens_cap": tokens_cap,
        "calibrated": calibrated,
        "confidence": confidence,
        "stale": is_stale,
    }
