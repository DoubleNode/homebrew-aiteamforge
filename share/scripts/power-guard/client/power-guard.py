#!/usr/bin/env python3
"""power-guard: per-machine UPS shutdown DECISION (XACA-1394-003, EPIC-0067 D4).

This file DECIDES; it never acts. It reads the accessory state file written by
fleet-reporter.sh (XACA-1394-002) and this machine's power-guard policy, and
returns a verdict object. Executing a shutdown is XACA-1394-004's job (a root
LaunchDaemon that wraps `power-guard.py --once --json`). Nothing in this file
calls shutdown/halt/pmset/osascript, and nothing may be added here that does:
the seam is the verdict.

WHY IT FAILS CLOSED (D4)
  A missed shutdown is what the fleet has today (hard power-off when the UPS
  runs flat). A FALSE shutdown powers off a running fleet on bad data, which
  is the new harm this epic must not introduce. So every doubt resolves to
  NO_ACTION: missing/unparseable/invalid policy, missing/unparseable/stale
  state, future timestamps, any state other than the exact string
  "on_battery", unreadable numbers, an undebounced reading, and any exception.

VERDICTS
  NO_ACTION       do nothing.
  WOULD_SHUTDOWN  every condition held, but the policy is dry_run (the default).
  SHUTDOWN        every condition held, policy enabled and dry_run is false.

SHUTDOWN requires ALL of:
  1. policy valid and `enabled` is exactly true;
  2. state file present, parseable, `schema` exactly 1;
  3. `receivedAt` and the accessory's `observedAt` both within `freshness_s`
     of now (a timestamp more than FUTURE_SKEW_S in the future is invalid);
  4. accessory `state` == "on_battery" exactly (case-sensitive);
  5. percent < min_percent OR minutes_remaining < min_minutes (a null/absent
     threshold or value cannot trigger);
  6. 2-5 held for `consecutive` DISTINCT readings in a row. A reading is
     identified by (seq, observedAt): re-reading an unchanged file is ONE
     reading. Any non-qualifying reading resets the count. The count lives in
     a counter file next to the state file; missing/corrupt => 0.

PATHS (CLI flags win over env, env wins over defaults). The -004 daemon runs
as root, where $HOME is /var/root, so it MUST pass the console user's paths
explicitly; this file does not try to detect the console user.
  state    --state-file   | $AITEAMFORGE_ACCESSORY_STATE_FILE | ~/.aiteamforge/run/accessory-state.json
  policy   --policy-file  | $AITEAMFORGE_POWER_GUARD_POLICY   | ~/.aiteamforge/power-guard-policy.json
  counter  --counter-file | (none)                            | <state dir>/power-guard-counter.json
The counter default above is for NON-root use only. The root daemon passes
/var/db/aiteamforge/power-guard-counter.json (root-owned, 0700) and the runner
verifies that dir before calling decide(): root must never write into the
user-writable state dir (XACA-1394-013).

Must run under /usr/bin/python3 (3.9): no match/case, no `X | Y` types, and
datetime.fromisoformat() on 3.9 rejects a trailing "Z" and odd fractional
second widths, so timestamps go through parse_ts() below.
"""
import argparse
import datetime
import json
import math
import os
import re
import sys
import tempfile

NO_ACTION = "NO_ACTION"
WOULD_SHUTDOWN = "WOULD_SHUTDOWN"
SHUTDOWN = "SHUTDOWN"

STATE_SCHEMA = 1
COUNTER_SCHEMA = 1
VERDICT_SCHEMA = 1

# Clock skew tolerated before a timestamp counts as "from the future".
# observedAt comes from the data-link host's clock, receivedAt from ours.
FUTURE_SKEW_S = 30

# Upper bounds on policy values. Rejected (=> NO_ACTION), never clamped: a
# freshness window of hours would let a long-dead reading shut the machine down.
MAX_FRESHNESS_S = 3600
MAX_CONSECUTIVE = 100

COUNTER_BASENAME = "power-guard-counter.json"

_TS_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})$"
)


# --------------------------------------------------------------------------
# paths
# --------------------------------------------------------------------------
def _home(env):
    return env.get("HOME") or os.path.expanduser("~")


def default_state_path(env=None):
    env = os.environ if env is None else env
    v = env.get("AITEAMFORGE_ACCESSORY_STATE_FILE")
    if v:
        return v
    return os.path.join(_home(env), ".aiteamforge", "run", "accessory-state.json")


def default_policy_path(env=None):
    env = os.environ if env is None else env
    v = env.get("AITEAMFORGE_POWER_GUARD_POLICY")
    if v:
        return v
    return os.path.join(_home(env), ".aiteamforge", "power-guard-policy.json")


def default_counter_path(state_path):
    return os.path.join(os.path.dirname(os.path.abspath(state_path)), COUNTER_BASENAME)


# --------------------------------------------------------------------------
# small validators
# --------------------------------------------------------------------------
def parse_ts(value):
    """Parse an RFC3339 UTC/offset timestamp. Returns aware datetime or None.

    Naive timestamps (no zone) are rejected: their meaning depends on the
    reader's TZ, which is exactly the kind of guess D4 forbids.
    """
    if not isinstance(value, str):
        return None
    m = _TS_RE.match(value.strip())
    if not m:
        return None
    date, clock, frac, zone = m.groups()
    frac = (frac or "")[:6].ljust(6, "0")
    if zone == "Z":
        zone = "+00:00"
    try:
        return datetime.datetime.fromisoformat("%sT%s.%s%s" % (date, clock, frac, zone))
    except ValueError:
        return None


def _is_number(v):
    # bool is an int subclass; True must never read as 1.
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return False
    return math.isfinite(v)


def _fmt_now(now):
    return now.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _freshness(ts_value, now, freshness_s, label):
    """Return None when fresh, else a reason string."""
    ts = parse_ts(ts_value)
    if ts is None:
        return "%s missing or unparseable (%r)" % (label, ts_value)
    age = (now - ts).total_seconds()
    if age < -FUTURE_SKEW_S:
        return "%s is %.0fs in the future (skew limit %ss)" % (label, -age, FUTURE_SKEW_S)
    if age > freshness_s:
        return "%s is stale (%.0fs old > freshness_s %s)" % (label, age, freshness_s)
    return None


# --------------------------------------------------------------------------
# policy
# --------------------------------------------------------------------------
def load_policy(path):
    """Return (policy, error). Exactly one is None.

    Invalid in ANY field => error. There are no aggressive defaults to fall
    back to; the only defaults are the safe ones (enabled false, dry_run true).
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except FileNotFoundError:
        return None, "policy file not found: %s" % path
    except OSError as exc:
        return None, "policy file unreadable: %s (%s)" % (path, exc)
    if not raw.strip():
        return None, "policy file is empty: %s" % path
    try:
        doc = json.loads(raw, parse_constant=_reject_constant)
    except ValueError as exc:
        return None, "policy file is not valid JSON: %s" % exc
    return validate_policy(doc)


def _reject_constant(name):
    raise ValueError("non-finite number %s not allowed" % name)


def validate_policy(doc):
    if not isinstance(doc, dict):
        return None, "policy must be a JSON object"
    errs = []
    pol = {}

    enabled = doc.get("enabled", False)
    if not isinstance(enabled, bool):
        errs.append("enabled must be true/false")
    pol["enabled"] = enabled is True

    dry_run = doc.get("dry_run", True)
    if not isinstance(dry_run, bool):
        errs.append("dry_run must be true/false")
    # Anything but an explicit false keeps dry run on.
    pol["dry_run"] = dry_run is not False

    for key, upper in (("min_percent", 100), ("min_minutes", None)):
        v = doc.get(key)
        if v is None:
            pol[key] = None
            continue
        if not _is_number(v) or v < 0 or (upper is not None and v > upper):
            errs.append("%s must be null or a number in [0, %s]" % (key, upper if upper is not None else "inf"))
            pol[key] = None
        else:
            pol[key] = v

    fr = doc.get("freshness_s")
    if not _is_number(fr) or fr <= 0 or fr > MAX_FRESHNESS_S:
        errs.append("freshness_s is required: a number in (0, %d]" % MAX_FRESHNESS_S)
    pol["freshness_s"] = fr

    cons = doc.get("consecutive")
    if isinstance(cons, bool) or not isinstance(cons, int) or cons < 1 or cons > MAX_CONSECUTIVE:
        errs.append("consecutive is required: an integer in [1, %d]" % MAX_CONSECUTIVE)
    pol["consecutive"] = cons

    ids = doc.get("accessory_ids")
    if ids is None:
        pol["accessory_ids"] = None
    elif (not isinstance(ids, list) or not ids
          or not all(isinstance(i, str) and i for i in ids)):
        errs.append("accessory_ids must be omitted/null or a non-empty list of non-empty strings")
        pol["accessory_ids"] = None
    else:
        pol["accessory_ids"] = list(dict.fromkeys(ids))

    if errs:
        return None, "invalid policy: " + "; ".join(errs)
    return pol, None


# --------------------------------------------------------------------------
# accessory state
# --------------------------------------------------------------------------
def load_state(path):
    """Return (doc, error). Validates only the envelope; freshness is checked
    by the decision because it needs `now` and the policy."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except FileNotFoundError:
        return None, "accessory state file not found: %s" % path
    except OSError as exc:
        return None, "accessory state file unreadable: %s (%s)" % (path, exc)
    if not raw.strip():
        return None, "accessory state file is empty"
    try:
        doc = json.loads(raw, parse_constant=_reject_constant)
    except ValueError as exc:
        return None, "accessory state file is not valid JSON: %s" % exc
    if not isinstance(doc, dict):
        return None, "accessory state must be a JSON object"
    schema = doc.get("schema")
    if type(schema) is not int or schema != STATE_SCHEMA:
        return None, "accessory state schema %r is not %d" % (schema, STATE_SCHEMA)
    if not isinstance(doc.get("accessories"), list):
        return None, "accessory state has no accessories list"
    return doc, None


def _reading_key(acc):
    """Identity of a reading: (seq, observedAt). Same key == same reading."""
    return "%s|%s" % (json.dumps(acc.get("seq")), acc.get("observedAt"))


def evaluate_accessory(acc, now, pol):
    """Return (qualifies, reason) for conditions 3(observedAt)-5."""
    stale = _freshness(acc.get("observedAt"), now, pol["freshness_s"], "observedAt")
    if stale:
        return False, stale
    state = acc.get("state")
    if state != "on_battery":
        return False, "state is %r, not 'on_battery'" % (state,)
    hits = []
    pct, mp = acc.get("percent"), pol["min_percent"]
    if mp is not None and _is_number(pct) and 0 <= pct <= 100 and pct < mp:
        hits.append("percent %s < min_percent %s" % (pct, mp))
    mins, mm = acc.get("minutes_remaining"), pol["min_minutes"]
    # Negative minutes is pmset's "still calculating"; it cannot trigger.
    if mm is not None and _is_number(mins) and mins >= 0 and mins < mm:
        hits.append("minutes_remaining %s < min_minutes %s" % (mins, mm))
    if not hits:
        return False, "on battery but above thresholds (percent=%r, minutes_remaining=%r)" % (pct, mins)
    return True, "on battery, " + " and ".join(hits)


# --------------------------------------------------------------------------
# debounce counter
# --------------------------------------------------------------------------
def load_counter(path):
    """Return {id: {"count": int, "last_key": str|None}}. Anything odd => {}."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return {}
    if not isinstance(doc, dict) or doc.get("schema") != COUNTER_SCHEMA:
        return {}
    accs = doc.get("accessories")
    if not isinstance(accs, dict):
        return {}
    out = {}
    for k, v in accs.items():
        if not isinstance(v, dict):
            continue
        c = v.get("count")
        lk = v.get("last_key")
        if isinstance(c, bool) or not isinstance(c, int) or c < 0:
            c = 0
        if not isinstance(lk, str):
            lk = None
        out[k] = {"count": c, "last_key": lk}
    return out


def save_counter(path, counters, now):
    """Atomic write (temp file in the same dir + os.replace)."""
    # No makedirs: the counter lives in the reporter's run dir; if that dir
    # does not exist there is no state to debounce and we must not create it.
    d = os.path.dirname(os.path.abspath(path))
    body = json.dumps({"schema": COUNTER_SCHEMA, "updatedAt": _fmt_now(now),
                       "accessories": counters}, indent=2, sort_keys=True)
    fd, tmp = tempfile.mkstemp(prefix=".power-guard-counter.", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(body + "\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# --------------------------------------------------------------------------
# decision
# --------------------------------------------------------------------------
def _verdict(verdict, reason, accessory_id=None, pol=None, details=None,
             now=None, paths=None):
    return {
        "schema": VERDICT_SCHEMA,
        "verdict": verdict,
        "reason": reason,
        "accessory_id": accessory_id,
        "enabled": bool(pol and pol.get("enabled") is True),
        "dry_run": not (pol and pol.get("dry_run") is False),
        "evaluatedAt": _fmt_now(now) if now else None,
        "paths": paths or {},
        "accessories": details or [],
    }


def decide(policy_path, state_path, counter_path=None, now=None):
    """Pure-ish decision: reads the two inputs, updates only the counter file.

    Never raises. Any exception => NO_ACTION.
    """
    try:
        if now is None:
            now = datetime.datetime.now(datetime.timezone.utc)
        if now.tzinfo is None:
            raise ValueError("now must be timezone-aware")
        return _decide(policy_path, state_path, counter_path, now)
    except Exception as exc:  # fail closed, by design
        return _verdict(NO_ACTION, "internal error, failing closed: %s: %s"
                        % (type(exc).__name__, exc), now=now if isinstance(now, datetime.datetime) else None)


def _decide(policy_path, state_path, counter_path, now):
    if counter_path is None:
        counter_path = default_counter_path(state_path)
    paths = {"policy": policy_path, "state": state_path, "counter": counter_path}

    def reset_all(reason, pol=None):
        # Fail closed: any non-qualifying condition clears every count. If the
        # reset cannot be written, remove the counter instead so an old count
        # can never be resumed; the verdict is NO_ACTION either way, and the
        # original reason is kept (it is the useful one).
        try:
            save_counter(counter_path, {}, now)
        except OSError:
            try:
                os.unlink(counter_path)
            except OSError:
                pass
        return _verdict(NO_ACTION, reason, pol=pol, now=now, paths=paths)

    pol, err = load_policy(policy_path)
    if err:
        return reset_all(err)
    if pol["enabled"] is not True:
        return reset_all("policy disabled (enabled is not true)", pol)

    doc, err = load_state(state_path)
    if err:
        return reset_all(err, pol)
    stale = _freshness(doc.get("receivedAt"), now, pol["freshness_s"], "receivedAt")
    if stale:
        return reset_all(stale, pol)

    by_id = {}
    dupes = set()
    for acc in doc["accessories"]:
        if not isinstance(acc, dict) or not isinstance(acc.get("id"), str) or not acc.get("id"):
            continue
        if acc["id"] in by_id:
            dupes.add(acc["id"])
        by_id[acc["id"]] = acc

    watched = pol["accessory_ids"] if pol["accessory_ids"] is not None else list(by_id.keys())
    if not watched:
        return reset_all("no accessories in state file", pol)

    old = load_counter(counter_path)
    new = {}
    details = []
    for aid in watched:
        prev = old.get(aid, {"count": 0, "last_key": None})
        acc = by_id.get(aid)
        if acc is None:
            qual, why, key = False, "watched accessory not present in state file", None
        elif aid in dupes:
            qual, why, key = False, "accessory id appears more than once in state file", None
        else:
            key = _reading_key(acc)
            qual, why = evaluate_accessory(acc, now, pol)
        if not qual:
            count = 0
        elif key == prev["last_key"]:
            count = prev["count"]  # same reading re-read: does not advance
            why += " (no new reading since last run)"
        else:
            count = prev["count"] + 1
        new[aid] = {"count": count, "last_key": key}
        details.append({"id": aid, "qualifies": qual, "count": count,
                        "consecutive": pol["consecutive"], "reason": why})

    save_counter(counter_path, new, now)

    for d in details:
        if d["qualifies"] and d["count"] >= pol["consecutive"]:
            reason = "%s; held for %d/%d consecutive readings" % (
                d["reason"], d["count"], pol["consecutive"])
            # Belt and braces: SHUTDOWN only on exact enabled=true, dry_run=false.
            if pol["enabled"] is True and pol["dry_run"] is False:
                return _verdict(SHUTDOWN, reason, d["id"], pol, details, now, paths)
            return _verdict(WOULD_SHUTDOWN, "dry run: " + reason, d["id"], pol, details, now, paths)

    pending = [d for d in details if d["qualifies"]]
    if pending:
        d = pending[0]
        return _verdict(NO_ACTION, "debouncing: %s; %d/%d consecutive readings" % (
            d["reason"], d["count"], pol["consecutive"]), d["id"], pol, details, now, paths)
    first = details[0]
    return _verdict(NO_ACTION, first["reason"] if len(details) == 1 else
                    "no watched accessory qualifies", first["id"] if len(details) == 1 else None,
                    pol, details, now, paths)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def main(argv=None):
    p = argparse.ArgumentParser(
        description="power-guard decision (never acts; prints a verdict)")
    p.add_argument("--once", action="store_true", help="evaluate once and exit (required)")
    p.add_argument("--json", action="store_true", help="print the verdict as JSON")
    p.add_argument("--state-file", help="accessory state file (overrides env/default)")
    p.add_argument("--policy-file", help="power-guard policy file (overrides env/default)")
    p.add_argument("--counter-file", help="debounce counter file (default: next to state file)")
    p.add_argument("--now", help="override current time (RFC3339, for tests/drills)")
    args = p.parse_args(argv)
    if not args.once:
        p.error("--once is required (the run loop belongs to the LaunchDaemon)")

    now = None
    if args.now is not None:
        now = parse_ts(args.now)
        if now is None:
            p.error("--now is not a valid RFC3339 timestamp with a zone")

    state = args.state_file or default_state_path()
    policy = args.policy_file or default_policy_path()
    v = decide(policy, state, args.counter_file, now)
    if args.json:
        print(json.dumps(v, sort_keys=True))
    else:
        print("%s [%s] %s" % (v["verdict"], v["accessory_id"] or "-", v["reason"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
