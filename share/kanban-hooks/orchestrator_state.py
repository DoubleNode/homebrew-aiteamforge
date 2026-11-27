"""XACA-1546-002: pure per-item state derivation for the release orchestrator monitor (EPIC-0072).

NO I/O. Everything is passed in, `now` included, so a call is deterministic and fixture-testable. The CLI
(`scripts/kb-release-orchestrate watch`) collects the raw inputs and calls these functions. Stdlib only, py3.9-safe.

STATE ENUM (stable strings, see STATES)
  QUEUED            not dispatched yet: board status todo (or blocked; signals.blocked is then True)
  DISPATCHING       orchestration stamp present, worker has not started the item yet / window row not up yet,
                    inside thresholds.dispatch_seconds
  RUNNING           in_progress, window row present, pane command is not a shell, activity fresh
  QUESTION_PENDING  item.pendingQuestion is non-empty (a human/coordinator owes an answer)
  IN_REVIEW         a PR for the item is OPEN
  MERGED_PENDING_DONE  PR merged but the board item is not completed yet (kb-done still owed)
  DONE              board status completed
  FAILED            PR closed unmerged, or a terminal kb-pr-monitor verdict (20/21/22/30/31)
  CRASHED           in_progress but the worker is gone (pane is a shell, pane/window missing)
  STALLED           would be RUNNING but activity is older than thresholds.stall_seconds, or an
                    orchestrated dispatch that never started inside dispatch_seconds
  CANCELLED         board status cancelled
  UNKNOWN           the inputs cannot support any other claim (see fail-closed list)

PRECEDENCE (first matching row wins)
   1  item missing / not a dict, or board status missing/unrecognised ........ UNKNOWN
   2  status cancelled ...................................................... CANCELLED
   3  status completed (the board is the record) ............................ DONE
   4  PR merged (state MERGED or mergedAt set) .............................. MERGED_PENDING_DONE
   5  PR closed unmerged, or terminal monitor verdict ....................... FAILED
   6  pendingQuestion non-empty ............................................. QUESTION_PENDING
   7  PR open ............................................................... IN_REVIEW
   8  status todo/blocked: orchestrated -> DISPATCHING (fresh) / STALLED (late) / UNKNOWN (bad stamp);
      not orchestrated -> QUEUED
   9  status in_progress: the liveness ladder (window row, pane, activity) ... CRASHED / DISPATCHING /
      STALLED / RUNNING / UNKNOWN

Collisions decided (each has a test):
  * merged beats a failed verdict: the merge is a fact, the verdict is an opinion about a moment.
  * pendingQuestion beats everything non-terminal, INCLUDING CRASHED and STALLED. A dead pane with an open
    question is still a question: kb-ask parks, and the per-asker tombstone is collected when the worker is
    resumed, so the answer is not futile. The detail says the pane is a shell. A stale lastActivity while
    parked is expected, not a stall.
  * PR open beats STALLED (kb-pr-monitor waits a long time on gates) but NOT CRASHED: the worker runs its own
    gates and kb-pr-monitor through merge, so an in_progress item with an open PR whose pane is a shell or gone
    (or whose orchestrated window row vanished past dispatch_seconds) is CRASHED; an unreadable pane is UNKNOWN.
  * pendingQuestion beats IN_REVIEW: a human decision is the more urgent signal.
  * `item.lastQuestion` (per-asker map of ANSWERED tombstones, or the older single object) is IGNORED. Only
    a non-empty `pendingQuestion` is an open question.

FAIL-CLOSED DECISIONS (nothing unknown reads as healthy RUNNING)
  * pane_command None (tmux unreadable) or "" on an in_progress item with a window row -> UNKNOWN.
    A pane we could not query is not evidence of life. PANE_GONE is the distinct "tmux answered, no such
    pane" and means CRASHED.
  * lastActivity missing, unparseable, naive (no zone) or in the future beyond clock_skew_seconds -> UNKNOWN,
    never RUNNING. UNKNOWN rather than STALLED because a bad timestamp is a data defect, not evidence the
    worker idled; STALLED triggers a nudge, UNKNOWN triggers a human look. Same for a bad dispatchedAt.
  * pr carrying "error" or an unrecognised state: downgrades an otherwise-healthy RUNNING to UNKNOWN (we
    could not see a PR that may exist). It never overrides a state the board or pane already decided.
  * Bad thresholds raise ValueError (a config bug must not silently disable stall detection).
  * in_progress, orchestrated, no window row: CRASHED once dispatch_seconds has passed (inside it, the
    row may simply not be written yet: DISPATCHING). Not orchestrated and no row: UNKNOWN (we do not own it).
  Crash detection deliberately does NOT use kb-recover's BOUND/ORPHANED classification (XACA-1125 is open).

INPUT SHAPES (what the caller must supply)
  item        board backlog item dict: status, subitems[].status, pendingQuestion {threadId, question, options,
              askedAt, askedBy, coordinator}, orchestration {runId, coordinator, dispatchedAt, model}.
  window_row  the board's activeWindows row for the item (id "<terminal>:<ITEM>"), or None when no row exists.
              Fields read: lastActivity, statusChangedAt, status.
  pane_command  tmux `#{pane_current_command}` of the worker's pane, from
              `tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}<TAB>#{pane_current_command}'`
              (strip, one value). None = tmux unreadable. PANE_GONE = tmux answered and the pane is absent.
  pr          None = no PR. Else a dict from `gh pr list --head <branch> --state all --json
              number,state,mergedAt,isDraft` (newest entry), optionally with "verdict": a kb-pr-monitor verdict
              name or exit code, and/or "error": "<why gh failed>".
  now         datetime (naive is taken as UTC).
"""
import re
from datetime import datetime, timedelta, timezone

STATES = (
    "QUEUED", "DISPATCHING", "RUNNING", "QUESTION_PENDING", "IN_REVIEW", "MERGED_PENDING_DONE",
    "DONE", "FAILED", "CRASHED", "STALLED", "CANCELLED", "UNKNOWN",
)

DEFAULT_THRESHOLDS = {
    "stall_seconds": 900,        # RUNNING with no activity this long -> STALLED
    "dispatch_seconds": 300,     # dispatched but not started / no window row yet this long -> STALLED / CRASHED
    "clock_skew_seconds": 120,   # a lastActivity this far in the future is untrustworthy -> UNKNOWN
    # XACA-1880-003: a lane PR gate whose latest review is on a non-HEAD commit, with no review of HEAD this long after the
    # head commit / that stale review -> the monitor's GATE_STALE (matches kb-pr-monitor KBPM_STALE_APPROVAL_MINUTES=60)
    "gate_stale_seconds": 3600,
}

PANE_GONE = "<pane-gone>"

SHELL_COMMANDS = frozenset(("zsh", "bash", "sh", "dash", "fish", "ksh", "tcsh"))

# XACA-1875 (shared with 1880-002's ITEM_AT_PROMPT): the Claude Code screen strings that say a pane is NOT idle. Extended
# regexes, matched case-insensitively on a capture-pane tail. These rows MUST equal the dialog/busy rows of kb-nudge's
# _KB_NUDGE_PANE_PATTERNS in kanban-helpers.sh (tests/test_xaca1875_window_close.py enforces it), so a Claude Code UI
# change is one edit in each table, caught by that test if only one moves.
PANE_PATTERNS = {
    "dialog": ("Enter to select", "Esc to cancel", r"Do you want to proceed\?", "Do you want to (make this edit|create|allow)",
               "About to (merge|cut)", "at (low|medium) effort"),
    "busy": ("esc to interrupt",),
}


def tail_hash(text):
    """A short stable hash of a capture-pane tail (trailing blank lines and trailing spaces ignored)."""
    import hashlib
    lines = [ln.rstrip() for ln in str(text).splitlines()]
    while lines and not lines[-1]:
        lines.pop()
    return hashlib.sha256("\n".join(lines).encode("utf-8", "replace")).hexdigest()[:16]


def pane_idle(tail_now, prev_hash):
    """XACA-1875 USER DECISION 1(a), pure -> (idle, reason). reason: unreadable (no tail), busy (a turn is running),
    dialog (an interactive prompt is open), unconfirmed (first sighting, or the tail changed since prev_hash), idle (the
    same quiet tail on two consecutive polls). Busy and dialog win over the hash comparison."""
    if tail_now is None:
        return False, "unreadable"
    for cls in ("busy", "dialog"):
        if any(re.search(p, tail_now, re.I) for p in PANE_PATTERNS[cls]):
            return False, cls
    if not prev_hash or tail_hash(tail_now) != prev_hash:
        return False, "unconfirmed"
    return True, "idle"

# kb-pr-monitor terminal-failure verdicts: name -> exit code
FAILED_VERDICTS = {"CONFLICT": 20, "UX_REOPEN": 21, "BLOCKED": 22, "CI_FLAKE_REPEAT": 24, "PR_CLOSED": 30, "TIMEOUT": 31}

_TS_RE = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})$")


def parse_ts(value):
    """ISO-8601 with an explicit zone -> aware UTC datetime, else None. Never guesses a zone."""
    if not isinstance(value, str):
        return None
    m = _TS_RE.match(value.strip())
    if not m:
        return None
    y, mo, d, h, mi, s, frac, tz = m.groups()
    try:
        micro = int((frac or ".0")[1:7].ljust(6, "0"))
        dt = datetime(int(y), int(mo), int(d), int(h), int(mi), int(s), micro, tzinfo=timezone.utc)
        if tz != "Z":
            sign = 1 if tz[0] == "+" else -1
            digits = tz[1:].replace(":", "")
            off = timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
            dt = dt - sign * off
        return dt
    except (ValueError, OverflowError):
        return None


def _now(now):
    if not isinstance(now, datetime):
        raise TypeError("now must be a datetime")
    return now.replace(tzinfo=timezone.utc) if now.tzinfo is None else now.astimezone(timezone.utc)


def _thresholds(thresholds):
    out = dict(DEFAULT_THRESHOLDS)
    if thresholds:
        out.update(thresholds)
    for k, v in out.items():
        if isinstance(v, bool) or not isinstance(v, (int, float)) or v < 0 or v != v:
            raise ValueError("threshold %s must be a non-negative number, got %r" % (k, v))
    return out


def _res(state, detail, since, signals):
    return {"state": state, "detail": detail, "since": since, "signals": signals}


def _norm_command(cmd):
    if not isinstance(cmd, str):
        return None
    c = cmd.strip()
    if not c:
        return None
    if c == PANE_GONE:
        return c
    return c.lstrip("-").rsplit("/", 1)[-1].lower()


def _question_open(item):
    pq = item.get("pendingQuestion")
    if isinstance(pq, dict):
        return any(bool(v) for v in pq.values())
    return bool(pq)


PLANNING_SUBITEM_PREFIX = "[USER DECISION]"
PLANNING_SUBITEM_WS = " \t\n\r\v\f"   # == the jq class in kb_is_planning_subitem: never bare lstrip() (it also eats \x1c-\x1f)


def is_planning_subitem(sub):
    """XACA-1863: True iff `sub` is a planning-phase subitem: its title, after leading whitespace, starts with
    "[USER DECISION]". Such a subitem is never R2 evidence of a start (planners resolve decisions before dispatch, so
    counting them made every fully planned ticket read in_progress). Mirrors kanban-helpers.sh kb_is_planning_subitem."""
    title = sub.get("title") if isinstance(sub, dict) else None
    return isinstance(title, str) and title.lstrip(PLANNING_SUBITEM_WS).startswith(PLANNING_SUBITEM_PREFIX)


def resolve_item_status(item):
    """The board's item status exactly as kanban-helpers.sh `kb_resolve_item_status` resolves it (what kb-dispatch uses).
    A RECORDED status (non-null, not blank after trimming) wins verbatim. An unrecorded one is derived: a live
    (non-cancelled) subitem in_progress / in_review / blocked / completed (a "[USER DECISION]" planning subitem does not
    count, XACA-1863), activelyWorking truthy, or startedAt set -> "in_progress"; otherwise "todo". Items created by kb-backlog carry NO status key, so reading raw `item.status` would
    turn every fresh todo item into UNKNOWN (XACA-1546-005)."""
    rec = item.get("status")
    if rec is not None and (not isinstance(rec, str) or rec.strip() != ""):
        return rec.strip() if isinstance(rec, str) else rec
    subs = item.get("subitems")
    if isinstance(subs, list):
        for s in subs:
            if not isinstance(s, dict) or is_planning_subitem(s):    # XACA-1863: a decision is not a start
                continue
            st = s.get("status")
            st = st.strip() if isinstance(st, str) else st
            if st in ("in_progress", "in_review", "blocked", "completed"):     # blank/None = todo, cancelled = not live
                return "in_progress"
    if item.get("activelyWorking") not in (None, False) or item.get("startedAt") is not None:
        return "in_progress"
    return "todo"


def _subitem_counts(item):
    subs = item.get("subitems")
    if not isinstance(subs, list):
        return 0, 0
    live = [s for s in subs if isinstance(s, dict) and s.get("status") != "cancelled"]
    return sum(1 for s in live if s.get("status") == "completed"), len(live)


def _pr_view(pr):
    """-> (kind, number, state, verdict) with kind in none|open|merged|closed|bad."""
    if pr is None:
        return "none", None, None, None
    if not isinstance(pr, dict):
        return "bad", None, None, None
    num = pr.get("number")
    raw = pr.get("verdict")
    verdict = None
    if isinstance(raw, str) and raw in FAILED_VERDICTS:
        verdict = raw
    elif isinstance(raw, int) and not isinstance(raw, bool):
        for name, code in FAILED_VERDICTS.items():
            if code == raw:
                verdict = name
    st = pr.get("state")
    st = st.upper() if isinstance(st, str) else None
    if st == "MERGED" or (pr.get("mergedAt") and st in (None, "CLOSED", "MERGED")):
        return "merged", num, "MERGED", verdict
    if pr.get("error") or (st is None and verdict is None):
        return "bad", num, st, verdict
    if st == "OPEN":
        return "open", num, st, verdict
    if st == "CLOSED":
        return "closed", num, st, verdict
    if verdict:
        return "none", num, st, verdict
    return "bad", num, st, verdict


def derive_item_state(item, window_row, pane_command, pr, now, thresholds):
    """Pure. -> {state, detail, since, signals}. See the module docstring for precedence and fail-closed rules."""
    now = _now(now)
    th = _thresholds(thresholds)
    signals = {
        "subitems_done": 0, "subitems_total": 0, "pr_number": None, "pr_state": None,
        "question_age_seconds": None, "activity_age_seconds": None, "pane_command": None, "blocked": False,
    }
    if not isinstance(item, dict):
        return _res("UNKNOWN", "item missing or not an object", None, signals)

    signals["subitems_done"], signals["subitems_total"] = _subitem_counts(item)
    status = resolve_item_status(item)
    signals["blocked"] = status == "blocked"
    kind, pr_num, pr_state, verdict = _pr_view(pr)
    signals["pr_number"], signals["pr_state"] = pr_num, pr_state
    cmd = _norm_command(pane_command)
    signals["pane_command"] = cmd

    if status not in ("todo", "blocked", "in_progress", "completed", "cancelled"):
        return _res("UNKNOWN", "unrecognised board status %r" % (status,), None, signals)
    if status == "cancelled":
        return _res("CANCELLED", "board status cancelled", None, signals)
    if status == "completed":
        return _res("DONE", "board status completed", None, signals)

    if kind == "merged":
        return _res("MERGED_PENDING_DONE", "PR #%s merged, board item is %s" % (pr_num, status), None, signals)
    if kind == "closed":
        return _res("FAILED", "PR #%s closed without merging" % pr_num, None, signals)
    if verdict:
        return _res("FAILED", "kb-pr-monitor verdict %s (%d)" % (verdict, FAILED_VERDICTS[verdict]), None, signals)

    if _question_open(item):
        pq = item.get("pendingQuestion")
        asked = pq.get("askedAt") if isinstance(pq, dict) else None
        t = parse_ts(asked)
        since = asked if t else None
        if t:
            signals["question_age_seconds"] = max(0, int((now - t).total_seconds()))
        detail = "open question awaiting an answer"
        if status == "in_progress" and (cmd == PANE_GONE or cmd in SHELL_COMMANDS):
            detail += "; worker pane is %s, the answer will be collected on resume" % (
                "gone" if cmd == PANE_GONE else "a shell")
        return _res("QUESTION_PENDING", detail, since, signals)

    orch = item.get("orchestration")
    # XACA-1873: a Wave 0 planning stamp (phase "wave0") leaves the item todo; it is not an execution dispatch.
    orchestrated = isinstance(orch, dict) and bool(orch.get("runId")) and orch.get("phase") != "wave0"

    if kind == "open":
        # The worker drives its own gates and kb-pr-monitor through merge (EPIC-0072 2026-11-09 autonomy
        # amendment), so an open PR does NOT excuse a dead worker: nobody is left to merge or answer a verdict.
        if status == "in_progress" and isinstance(window_row, dict):
            if cmd == PANE_GONE or cmd in SHELL_COMMANDS:
                return _res("CRASHED", "PR #%s open but the worker pane is %s; nobody is driving kb-pr-monitor"
                            % (pr_num, "gone" if cmd == PANE_GONE else "a shell"), None, signals)
            if cmd is None:
                return _res("UNKNOWN", "PR #%s open but the pane command is unreadable" % pr_num, None, signals)
        elif status == "in_progress" and orchestrated and window_row is None:
            r = _dispatch_age(orch, now, th, signals, "no window row")
            if r["state"] == "STALLED":
                return _res("CRASHED", "PR #%s open but the orchestrated window is gone" % pr_num,
                            r["since"], signals)
        # No activity stall while in review: kb-pr-monitor legitimately waits a long time on gate sessions.
        return _res("IN_REVIEW", "PR #%s open" % pr_num, None, signals)

    if status in ("todo", "blocked"):
        if not orchestrated:
            return _res("QUEUED", "board status %s, not dispatched" % status, None, signals)
        return _dispatch_age(orch, now, th, signals, "dispatched, worker has not started the item")

    # in_progress
    if window_row is None or not isinstance(window_row, dict):
        if not orchestrated:
            return _res("UNKNOWN", "in_progress with no window row and no orchestration stamp", None, signals)
        r = _dispatch_age(orch, now, th, signals, "no window row yet")
        if r["state"] == "STALLED":
            return _res("CRASHED", "orchestrated run %s but the window is gone" % orch.get("runId"),
                        r["since"], signals)
        return r
    if cmd == PANE_GONE:
        return _res("CRASHED", "window row exists but its pane is gone", None, signals)
    if cmd is None:
        return _res("UNKNOWN", "pane command unreadable; a pane we could not query is not evidence of life",
                    None, signals)
    if cmd in SHELL_COMMANDS:
        return _res("CRASHED", "pane is back at a shell (%s); claude exited" % cmd, None, signals)

    raw = window_row.get("lastActivity")
    t = parse_ts(raw)
    if t is None:
        return _res("UNKNOWN", "lastActivity missing or unparseable (%r); not treated as fresh" % (raw,),
                    None, signals)
    age = (now - t).total_seconds()
    if age < -th["clock_skew_seconds"]:
        return _res("UNKNOWN", "lastActivity is %ds in the future; clock skew, not treated as fresh" % -age,
                    None, signals)
    age = max(0, int(age))
    signals["activity_age_seconds"] = age
    if age > th["stall_seconds"]:
        return _res("STALLED", "no activity for %ds (limit %ds)" % (age, th["stall_seconds"]), raw, signals)
    if kind == "bad":
        return _res("UNKNOWN", "PR state unreadable (%s)" % ((pr or {}).get("error") if isinstance(pr, dict) else "bad input"),
                    None, signals)
    since = window_row.get("statusChangedAt")
    return _res("RUNNING", "worker alive, last activity %ds ago" % age, since if parse_ts(since) else None, signals)


def _dispatch_age(orch, now, th, signals, why):
    raw = orch.get("dispatchedAt")
    t = parse_ts(raw)
    if t is None:
        return _res("UNKNOWN", "orchestration.dispatchedAt missing or unparseable (%r)" % (raw,), None, signals)
    age = (now - t).total_seconds()
    if age < -th["clock_skew_seconds"]:
        return _res("UNKNOWN", "dispatchedAt is in the future; clock skew", None, signals)
    age = max(0, int(age))
    if age > th["dispatch_seconds"]:
        return _res("STALLED", "%s for %ds (limit %ds)" % (why, age, th["dispatch_seconds"]), raw, signals)
    return _res("DISPATCHING", "%s (%ds ago)" % (why, age), raw, signals)


def derive_states(items_by_id, windows, panes, prs, now, thresholds):
    """-> {item_id: result}. windows/panes/prs are {item_id: ...}; a missing key means None for that input
    (windows: no row; panes: unreadable; prs: no PR). `windows` and `prs` None are treated as empty."""
    windows = windows or {}
    prs = prs or {}
    panes = panes or {}
    return {iid: derive_item_state(it, windows.get(iid), panes.get(iid), prs.get(iid), now, thresholds)
            for iid, it in sorted(items_by_id.items())}


def transitions(prev_states, cur_states):
    """-> sorted [(id, from, to)] for every id whose state changed. Accepts result dicts or bare state strings.
    A new id is (id, None, state); a vanished id is (id, state, None)."""
    def st(v):
        return v.get("state") if isinstance(v, dict) else v
    prev = prev_states or {}
    cur = cur_states or {}
    out = []
    for iid in sorted(set(prev) | set(cur)):
        a = st(prev[iid]) if iid in prev else None
        b = st(cur[iid]) if iid in cur else None
        if a != b:
            out.append((iid, a, b))
    return out


# ------------------------------------------------------------------ XACA-1546-004: thresholds + SLOT_FREE

THRESHOLD_ENV = {
    "stall_seconds": "KB_ORCH_STALL_SECONDS",
    "dispatch_seconds": "KB_ORCH_DISPATCH_SECONDS",
    "clock_skew_seconds": "KB_ORCH_CLOCK_SKEW_SECONDS",
    "gate_stale_seconds": "KB_ORCH_GATE_STALE_SECONDS",
}
# config-file (board JSON) spelling -> internal key
THRESHOLD_CONFIG_KEYS = {
    "stallSeconds": "stall_seconds",
    "dispatchSeconds": "dispatch_seconds",
    "clockSkewSeconds": "clock_skew_seconds",
    "gateStaleSeconds": "gate_stale_seconds",
}
_NUM_RE = re.compile(r"^[+]?(\d+(\.\d*)?|\.\d+)$")


def _layer_number(layer, key, value):
    """One threshold value -> int/float, or ValueError naming the layer and key. Never coerces garbage to a default."""
    if isinstance(value, bool):
        raise ValueError("%s: %s must be a non-negative number, got %r" % (layer, key, value))
    if isinstance(value, str):
        s = value.strip()
        if not _NUM_RE.match(s):
            raise ValueError("%s: %s is not a non-negative number: %r" % (layer, key, value))
        value = float(s)
        if value == int(value):
            value = int(value)
    if (not isinstance(value, (int, float)) or value != value
            or value in (float("inf"), float("-inf")) or value < 0):
        raise ValueError("%s: %s must be a finite non-negative number, got %r" % (layer, key, value))
    return value


def _orch_thresholds(layer, orch):
    """The `thresholds` dict of an orchestration config block -> ({internal_key: raw}, [unknown keys]).
    None / a bare list (the back-compat hotspots shape) carry no thresholds. Any other non-dict raises."""
    if orch is None or isinstance(orch, list):
        return {}, []
    if not isinstance(orch, dict):
        raise ValueError("%s: orchestration must be an object, got %s" % (layer, type(orch).__name__))
    th = orch.get("thresholds")
    if th is None:
        return {}, []
    if not isinstance(th, dict):
        raise ValueError("%s: thresholds must be an object, got %s" % (layer, type(th).__name__))
    out, unknown = {}, []
    for k, v in th.items():
        if k in THRESHOLD_CONFIG_KEYS:
            out[THRESHOLD_CONFIG_KEYS[k]] = v
        else:
            unknown.append(k)
    return out, unknown


def resolve_thresholds(cli=None, env=None, release_orch=None, team_orch=None):
    """Pure. -> (thresholds, sources, warnings).

    LAYERS, highest priority first (each key is taken from the first layer that SETS it):
      cli          dict with the internal keys stall_seconds / dispatch_seconds / clock_skew_seconds / gate_stale_seconds
      env          dict (the caller passes a copy of the process environment; this function never reads it itself):
                   KB_ORCH_STALL_SECONDS / KB_ORCH_DISPATCH_SECONDS / KB_ORCH_CLOCK_SKEW_SECONDS / KB_ORCH_GATE_STALE_SECONDS
      release      `release.orchestration` block, thresholds {stallSeconds, dispatchSeconds, clockSkewSeconds,
                   gateStaleSeconds (XACA-1880-003)}
      team         team `releaseConfig.orchestration` block, same shape
      defaults     DEFAULT_THRESHOLDS
    `sources` maps every key to "cli" | "env" | "release" | "team" | "default".

    FAIL CLOSED: a layer that sets a key to anything that is not a finite non-negative number (bool, None, "", "abc",
    "-5", nan, inf, a non-object layer) raises ValueError naming the layer and key. It is never skipped, because falling
    through to a lower layer or the default would silently disable stall detection the user tried to configure. An env
    var that is set but empty raises too (set-but-blank is a typo, not "unset"; unset the variable instead).

    UNKNOWN KEYS: not an error (forward compatibility) but never silent: each is returned in `warnings`
    ("<layer>: unknown threshold key 'x'"). The caller must print them."""
    th = dict(DEFAULT_THRESHOLDS)
    sources = {k: "default" for k in th}
    warnings = []
    layers = []  # lowest priority first, so later writes win

    for name, orch in (("team", team_orch), ("release", release_orch)):
        vals, unknown = _orch_thresholds(name + " config", orch)
        warnings.extend("%s config: unknown threshold key %r" % (name, k) for k in sorted(unknown, key=str))
        layers.append((name, name + " config", vals))

    if env is not None and not isinstance(env, dict):
        raise ValueError("env: must be a dict")
    ev = {}
    for key, var in THRESHOLD_ENV.items():
        if env is not None and var in env:
            ev[key] = env[var]
    layers.append(("env", "env", ev))

    if cli is not None and not isinstance(cli, dict):
        raise ValueError("cli: must be a dict")
    cv = {}
    for k, v in (cli or {}).items():
        if k in DEFAULT_THRESHOLDS:
            cv[k] = v
        else:
            warnings.append("cli: unknown threshold key %r" % (k,))
    layers.append(("cli", "cli", cv))

    for name, label, vals in layers:
        for key in DEFAULT_THRESHOLDS:
            if key in vals:
                shown = THRESHOLD_ENV[key] if name == "env" else key
                th[key] = _layer_number(label, shown, vals[key])
                sources[key] = name
    return _thresholds(th), sources, warnings


TERMINAL_STATES = frozenset(("DONE", "CANCELLED"))


def _state_name(states, iid):
    v = (states or {}).get(iid)
    v = v.get("state") if isinstance(v, dict) else v
    return v if isinstance(v, str) and v in STATES else "UNKNOWN"


def _occupant_id(current):
    if isinstance(current, str):
        return current.strip() or None
    if isinstance(current, dict):
        i = current.get("id")
        return i.strip() if isinstance(i, str) and i.strip() else None
    return None


def compute_slot_free(plan, states, lanes, max_parallel):
    """Pure. -> {slot_free, free_lanes, eligible, pairs, current_wave, reason, excluded}.

    `plan` is release_orchestrator.plan() output (waves[].items[].id in dispatch order, contention[] pairs {a,b}).
    `states` is {item_id: derive_item_state result dict | bare state string}. `lanes` is the board's list of
    {lane, current, queue, since} (a lane number absent from the list is free).

    RULES
      1 LANE OCCUPIED iff `current` is non-null (string id, or an object; even an empty string counts as occupied).
        This is the exact rule kb-dispatch uses (`lanes[].current != null` is open; LANES_FULL at maxParallel).
        free_lanes = lane numbers 1..max_parallel not occupied, ascending. Lanes numbered above max_parallel are
        ignored as slots, but an occupied one still consumes capacity (as in kb-dispatch, which counts ALL open
        lanes): free_lanes is truncated to max_parallel - total_occupied so we never claim more than kb-dispatch
        would accept. Duplicate entries for one lane: occupied if any says so.
        CAPACITY ALSO COUNTS IN-FLIGHT ITEMS: used = max(occupied lanes, tracked items whose state is neither QUEUED
        nor DONE/CANCELLED; UNKNOWN included), mirroring kb-dispatch's max(open lanes, run-stamped open items), so a
        lane that was never assigned cannot over-report a free slot. In-flight items are occupants for rule 3a too.
      2 current_wave = the lowest plan wave holding any item whose state is not terminal. Terminal = DONE or
        CANCELLED only. WAVES ARE GATES: a wave-N+1 item is never eligible while any wave-N item is non-terminal;
        that is how plan() guarantees contention/dependency ordering. FAILED is NOT terminal for gating (a human
        decides to retry or cancel), so a FAILED item holds its wave. So do CRASHED, STALLED, IN_REVIEW,
        MERGED_PENDING_DONE and QUESTION_PENDING. None when every plan item is terminal (or the plan is empty).
      3 eligible = items of current_wave whose state is QUEUED, in the plan's within-wave order, minus (a) any item
        that conflicts (plan.contention pair, either direction) with an item currently occupying a lane, and
        (b) an item that itself occupies a lane (dispatched, board not updated yet). Excluded ids and why are in
        `excluded`. A wave-mate that is merely running does NOT block: plan() already put conflicting items in
        different waves, and rule 3a covers cross-wave leftovers.
      4 slot_free is True iff free_lanes AND eligible are both non-empty. pairs = min(len(free_lanes), len(eligible)).
      5 UNKNOWN INPUTS FAIL CLOSED: a plan item with no entry in `states`, an UNKNOWN state, or an unrecognised
        state string counts as non-terminal (it holds the wave) and is never eligible. An occupied lane whose
        occupant id cannot be read makes the whole eligible set empty (we cannot rule out a conflict). Each case is
        named in `reason`.
    Malformed plan / bad max_parallel raise ValueError."""
    if isinstance(max_parallel, bool) or not isinstance(max_parallel, int) or max_parallel < 1:
        raise ValueError("max_parallel must be an integer >= 1 (got %r)" % (max_parallel,))
    if not isinstance(plan, dict) or not isinstance(plan.get("waves"), list):
        raise ValueError("plan must be a dict with a waves list")
    waves = []
    for w in plan["waves"]:
        if not isinstance(w, dict) or not isinstance(w.get("items"), list):
            raise ValueError("plan wave malformed: %r" % (w,))
        waves.append((w.get("wave"), [i["id"] for i in w["items"] if isinstance(i, dict) and "id" in i]))
    waves.sort(key=lambda t: (t[0] is None, t[0] or 0))

    occupied, occupants, unreadable = set(), set(), False
    for pos, ln in enumerate(lanes or []):
        if not isinstance(ln, dict) or ln.get("current") is None:
            continue
        n = ln.get("lane")
        occupied.add(n if isinstance(n, int) and not isinstance(n, bool) else ("?", pos))
        oid = _occupant_id(ln.get("current"))
        if oid:
            occupants.add(oid)
        else:
            unreadable = True
    # IN-FLIGHT items count against the cap whether or not a lane records them (PR #1343 review): kb-dispatch caps at
    # max(open lanes, run-stamped non-completed items), and a lane is only as current as the last assign. In flight =
    # every tracked item whose state is neither QUEUED nor terminal; UNKNOWN counts (fail closed: under-dispatch
    # beats a LANES_FULL refusal that feeds DISPATCH_FAILED).
    inflight = sorted(i for i in (states or {}) if _state_name(states, i) not in TERMINAL_STATES | {"QUEUED"})
    used = max(len(occupied), len(inflight))
    free = [n for n in range(1, max_parallel + 1) if n not in occupied]
    free = free[:max(0, max_parallel - used)]
    occupants |= set(inflight)              # an in-flight item without a lane still conflicts (rule 3a)

    current_wave, wave_ids, held = None, [], []
    for n, ids in waves:
        nonterm = [i for i in ids if _state_name(states, i) not in TERMINAL_STATES]
        if nonterm:
            current_wave, wave_ids, held = n, ids, nonterm
            break

    out = {"slot_free": False, "free_lanes": free, "eligible": [], "pairs": 0,
           "current_wave": current_wave, "reason": "", "excluded": {}}
    if current_wave is None:
        out["reason"] = "no non-terminal plan item: the plan is complete (or empty)"
        return out

    conflicts = {}
    for c in plan.get("contention") or []:
        if isinstance(c, dict) and c.get("a") and c.get("b"):
            conflicts.setdefault(c["a"], set()).add(c["b"])
            conflicts.setdefault(c["b"], set()).add(c["a"])
    eligible = []
    for i in wave_ids:
        if _state_name(states, i) != "QUEUED":
            continue
        if i in occupants:
            out["excluded"][i] = "already occupies a lane"
        elif unreadable:
            out["excluded"][i] = "a lane is occupied by an unreadable item id; conflict cannot be ruled out"
        elif conflicts.get(i, set()) & occupants:
            out["excluded"][i] = "conflicts with running %s" % ", ".join(sorted(conflicts[i] & occupants))
        else:
            eligible.append(i)
    out["eligible"] = eligible
    out["pairs"] = min(len(free), len(eligible))
    out["slot_free"] = bool(free and eligible)

    if out["slot_free"]:
        out["reason"] = "wave %s: %d free lane(s), %d eligible item(s)" % (current_wave, len(free), len(eligible))
    elif not free:
        out["reason"] = "no free lane (max_parallel %d, %d lane(s) occupied, %d item(s) in flight)" % (
            max_parallel, len(occupied), len(inflight))
    else:
        out["reason"] = "wave %s holds with nothing eligible; non-terminal: %s" % (
            current_wave, ", ".join("%s=%s" % (i, _state_name(states, i)) for i in held))
        if out["excluded"]:
            out["reason"] += "; excluded: " + "; ".join("%s (%s)" % kv for kv in sorted(out["excluded"].items()))
    unk = [i for i in held if _state_name(states, i) == "UNKNOWN"]
    if unk:
        out["reason"] += "%s unknown state (fail closed, holds the wave): %s" % (
            ";" if out["reason"] else "", ", ".join(unk))
    return out
