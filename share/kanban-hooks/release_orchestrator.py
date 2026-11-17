"""
release_orchestrator.py -- read-only release run-planner (XACA-1543, EPIC-0072 T2).

Stdlib only, py3.9-safe. The PLANNER layer is deterministic and READ-ONLY: it never writes a board, never calls a
mutating kb-* command and never touches tmux. The LEDGER layer (XACA-1546-001, the section delimited "LEDGER" below) is
the ONLY part of this module that writes, and it is the shell-out boundary for bash (CLI: ledger-append / ledger-hook):

  mint_run_id / run_release / run_id_valid  RUN-<REL-ID>-<UTC yyyymmddThhmmss>, same grammar as bash _kb_orch_run_valid
  ledger_append / ledger_read / ledger_path append-only <kanban>/orchestration/<RUN-ID>.jsonl; flock'd, fsync'd; reads FAIL
                                            CLOSED (LedgerCorrupt on any torn/garbage line; a final newline-less line is a warning)
  write_summary / start_run / record_state / close_run
                                            board .releases[].orchestration summary, written ONLY via
                                            kanban_utils.update_board_safely; double start refused
  assign_lane / lanes_view / STATE_STAGE    the LANE summary release.orchestration.lanes[] (XACA-1546-011, ticket-lamp
                                            XACA-1786): one entry per dispatch slot, see LANES below
  hook_append                               kb-ask / kb-answer / kb-dispatch hook: no-op unless the item carries
                                            orchestration.runId (a flat k=v `dispatch` event is nested for the caller)
  write_tokens                              release.orchestration.tokens (XACA-1808), under the board lock
  active_run / rehydrate / reattach_coordinator
                                            crash-safe resume (XACA-1547): find the open run, fold the ledger back into
                                            per-item history, re-point the run (summary + items) at a new coordinator

The planner functions below never call the ledger functions and the ledger functions never call plan().
The layers stay separate and individually callable:

  check_readiness(...)  -> per-item refusal reasons                           (XACA-1543-003)
  build_waves(...)      -> DAG + conflict-aware wave packing, cycle refusal   (XACA-1543-002)
  assign_terminals(...) -> terminal/persona/kind per scheduled item           (XACA-1543-004)
  plan(...)             -> the whole run plan (the ONLY function that reads files / imports the contention module)
  format_plan(plan)     -> human render

BOARD FIELDS (verified against kanban/academy-board.json, 1815 items):
  estimate  = `points`  (int or float, hours; 1291 items carry it; the epic's own estimate is "sum of child points").
              No item carries estimate / timeEstimate / estimatedHours / storyPoints. UNESTIMATED = missing, non-numeric,
              bool or <= 0.
  priority  = `priority` (present on every item): critical > high > medium > low, case-insensitive ("HIGH" occurs once);
              anything else sorts last.
  status    = `status`; an absent status means backlog. completed / cancelled are terminal.
  deps      = `blockedBy` (list of ids). `dependsOn` exists on 4 items and is deliberately NOT read: the spec names blockedBy.
  subitems  = `subitems` (list); cancelled subitems do not count toward NO_SUBITEMS.

REFUSAL CODES (stable): UNESTIMATED, NO_SUBITEMS, NO_PLAN_DOC, BLOCKED_OUTSIDE_RELEASE, ALREADY_TERMINAL, CYCLE,
BLOCKER_REFUSED. ALREADY_TERMINAL items are SKIPPED (reported separately, not "refused"): there is nothing to schedule.
Non-refusal warning codes: NO_TERMINAL, NO_PATHS, UNPARSED_PATHS, HOTSPOTS_CONFIG_INVALID.

CONTENTION FAIL-CLOSED (XACA-1543 QA round)
  An empty extracted file set means the file set is UNKNOWN, never "touches nothing". plan() therefore treats an in-release
  candidate with ZERO extracted paths (no Files section, paths only in prose, glob-only section, unparseable list) as
  conflicting with EVERY other candidate: it is serialised into a wave of its own, and a NO_PATHS warning says why. A
  candidate whose plan doc carried path-like tokens that could not be resolved (unparsed: unanchored absolute paths,
  globs, templates) also gets UNPARSED_PATHS listing them. WHY serialise (option b) rather than refuse with a NO_FILE_SET
  code (the reviewer's option a): both are fail-closed, but serialising keeps the item runnable without forcing a plan-doc
  edit, whereas a refusal would block it. Option (a), refuse, is the REJECTED alternative. The synthetic conflicts are
  listed in `contention` with "reason": "NO_PATHS". The rule itself is orchestrator_contention.predict_closed (shared with the
  contention CLI; plan() holds no copy). "Unknown" = the PLAN DOC yields no paths: description paths only add to a known
  set. plan docs are read with errors="replace" (one bad byte must not abort the plan); kanban_dir is made absolute once.
HOTSPOT CONFIG
  `releaseConfig.orchestration.hotspots` (board level) = list of extra hotspot paths / "dir/" prefixes added to the
  built-in set. A bare list at `releaseConfig.orchestration` is accepted for back-compat. Any other type raises a
  HOTSPOTS_CONFIG_INVALID warning (the config is then ignored, never silently).

DECISIONS
  * A blocker outside the release is fine only if it is `completed`. Open, blocked, cancelled (a cancelled blocker never
    completes, so the dependant would wait forever) and unknown ids all refuse with BLOCKED_OUTSIDE_RELEASE.
  * A blocker INSIDE the release that is already completed is satisfied (no edge, no wait); one that is cancelled makes the
    dependant BLOCKER_REFUSED. A refused blocker makes its dependants BLOCKER_REFUSED, transitively. Dependants of a cycle
    are BLOCKER_REFUSED; cycle members are CYCLE.
  * NO_TERMINAL is a WARNING, not a refusal: the item is still scheduled in its wave (the work is valid; the fleet just has
    no seat for its kind right now) and the coordinator decides. Wave width is capped by maxParallel, never terminal count.
  * Terminal eligibility is entirely orchestrator_routing.role_fit (non-empty matching role, not coordinatorOnly,
    state == present, sane lane_windows). Not duplicated here.
"""
from __future__ import annotations

import argparse
import datetime
import fcntl
import json
import os
import re
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import orchestrator_routing as routing  # noqa: E402
import orchestrator_state as ostate  # noqa: E402

DEFAULT_REPO_ROOT = os.path.dirname(_HERE)   # the checkout containing this script
DEFAULT_MAX_PARALLEL = 2
TERMINAL_STATUSES = ("completed", "cancelled")
_PRIORITY_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3}
_UNKNOWN_RANK = len(_PRIORITY_RANK)

UNESTIMATED = "UNESTIMATED"
NO_SUBITEMS = "NO_SUBITEMS"
NO_PLAN_DOC = "NO_PLAN_DOC"
BLOCKED_OUTSIDE_RELEASE = "BLOCKED_OUTSIDE_RELEASE"
ALREADY_TERMINAL = "ALREADY_TERMINAL"
CYCLE = "CYCLE"
BLOCKER_REFUSED = "BLOCKER_REFUSED"
NO_TERMINAL = "NO_TERMINAL"
NO_PATHS = "NO_PATHS"
UNPARSED_PATHS = "UNPARSED_PATHS"
HOTSPOTS_CONFIG_INVALID = "HOTSPOTS_CONFIG_INVALID"


class PlanError(Exception):
    """Unknown release, unreadable board, unusable terminals: the CLI maps this to exit 1."""


def _reason(code, text):
    return {"code": code, "text": text}


# ---------------------------------------------------------------- field accessors
def estimate_of(item):
    """Hours from `points`; None when missing/non-numeric/bool/<=0."""
    v = item.get("points") if isinstance(item, dict) else None
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v <= 0:
        return None
    return v


def priority_rank(item):
    p = item.get("priority") if isinstance(item, dict) else None
    return _PRIORITY_RANK.get(p.strip().lower(), _UNKNOWN_RANK) if isinstance(p, str) else _UNKNOWN_RANK


def _blockers(item):
    b = item.get("blockedBy")
    return [x for x in b if isinstance(x, str)] if isinstance(b, list) else []


def _order_key(item):
    est = estimate_of(item)
    return (priority_rank(item), est is None, est if est is not None else 0, item.get("id") or "")


# ---------------------------------------------------------------- 003: readiness
def check_readiness(item, release_item_ids, board, kanban_dir, repo_root=None, find_plan_doc=None):
    """Refusal reasons ([{code,text}], stable order) for one item; [] means ready.

    `release_item_ids` = ids assigned to the release. `board` supplies outside blockers' status. `find_plan_doc` is
    orchestrator_contention.find_plan_doc (injected so tests need no real module; plan() passes the real one).
    ALREADY_TERMINAL short-circuits: nothing else matters for an item that will not be scheduled."""
    status = item.get("status")
    if status in TERMINAL_STATUSES:
        return [_reason(ALREADY_TERMINAL, "status is %s; nothing to schedule" % status)]
    out = []
    if estimate_of(item) is None:
        out.append(_reason(UNESTIMATED, "no positive numeric `points` estimate"))
    subs = item.get("subitems")
    live = [s for s in subs if isinstance(s, dict) and s.get("status") != "cancelled"] if isinstance(subs, list) else []
    if not live:
        out.append(_reason(NO_SUBITEMS, "no non-cancelled subitems"))
    if find_plan_doc is not None and find_plan_doc(item, kanban_dir, repo_root) is None:
        out.append(_reason(NO_PLAN_DOC, "no plan document found"))
    by_id = {i.get("id"): i for i in (board or {}).get("backlog") or [] if isinstance(i, dict)}
    ids = set(release_item_ids)
    for b in sorted(set(_blockers(item))):
        if b in ids:
            continue
        st = (by_id.get(b) or {}).get("status")
        if b not in by_id:
            out.append(_reason(BLOCKED_OUTSIDE_RELEASE, "%s is outside the release and not on this board" % b))
        elif st != "completed":
            out.append(_reason(BLOCKED_OUTSIDE_RELEASE, "%s is outside the release and %s (not completed)" % (b, st or "backlog")))
    return out


# ---------------------------------------------------------------- 002: DAG + waves
def _reaches(start, edges, nodes):
    """Nodes reachable from `start` along dependant edges (blocker -> dependant), excluding start unless on a cycle."""
    seen, stack = set(), list(edges.get(start, ()))
    while stack:
        n = stack.pop()
        if n in seen or n not in nodes:
            continue
        seen.add(n)
        stack.extend(edges.get(n, ()))
    return seen


def build_waves(items, conflicts, max_parallel=DEFAULT_MAX_PARALLEL, refused=()):
    """Pack items into waves. `items` = list of item dicts (id, blockedBy, priority, points). `conflicts` = predict() output
    ([{"a","b",...}]); a pair is never placed in one wave. `refused` = ids already refused (readiness): they are excluded and
    their dependants get BLOCKER_REFUSED.

    Returns {"waves": [[id...]...], "refused": {id: [reason...]}, "cycles": [[id...]...], "maxParallel": N}.
    `refused` holds only the reasons decided HERE (CYCLE, BLOCKER_REFUSED). Edges are blockedBy entries whose target is in
    `items` only (outside blockers are readiness's concern). Packing: wave by wave, a candidate is an unplaced item whose
    blockers are all in strictly earlier waves; candidates are taken in order (priority, estimate ascending, id) and added
    if the wave has room and the item conflicts with nothing already in it. Same input, byte-identical output."""
    if isinstance(max_parallel, bool) or not isinstance(max_parallel, int) or max_parallel < 1:
        raise ValueError("max_parallel must be an integer >= 1 (got %r)" % (max_parallel,))
    by_id = {}
    for it in items:
        by_id.setdefault(it["id"], it)
    pre = set(refused)
    known = set(by_id) | pre   # a refused blocker need not be in `items`: it still poisons its dependants
    deps = {i: sorted(set(b for b in _blockers(it) if b in known)) for i, it in by_id.items()}
    dependants = {}
    for i, bs in deps.items():
        for b in bs:
            dependants.setdefault(b, []).append(i)
    out_refused = {}

    def propagate(bad):
        """Transitive dependants of `bad` (a set of refused ids) -> BLOCKER_REFUSED. Mutates out_refused; returns new bad."""
        changed = True
        while changed:
            changed = False
            for i in sorted(by_id):
                if i in bad:
                    continue
                hit = [b for b in deps[i] if b in bad]
                if hit:
                    out_refused[i] = [_reason(BLOCKER_REFUSED, "blocker %s is refused" % ", ".join(sorted(hit)))]
                    bad.add(i)
                    changed = True
        return bad

    bad = propagate(set(pre))
    # Kahn over the survivors; whatever is left is a cycle member or sits downstream of one.
    live = {i for i in by_id if i not in bad}   # a self-blocker keeps its own edge, so Kahn leaves it as a 1-cycle
    indeg = {i: sum(1 for b in deps[i] if b in live) for i in live}
    ready = sorted(i for i in live if indeg[i] == 0)
    done = set()
    while ready:
        n = ready.pop()
        done.add(n)
        for d in dependants.get(n, ()):
            if d in live and d not in done:
                indeg[d] -= 1
                if indeg[d] == 0:
                    ready.append(d)
    left = live - done
    edges = {i: [d for d in dependants.get(i, ()) if d in left] for i in left}
    cycles = []
    seen_members = set()
    for i in sorted(left):
        if i in seen_members:
            continue
        if i in _reaches(i, edges, left):          # on a cycle: reaches itself
            scc = sorted(n for n in left if n == i or (n in _reaches(i, edges, left) and i in _reaches(n, edges, left)))
            seen_members.update(scc)
            cycles.append(scc)
    for scc in cycles:
        for i in scc:
            out_refused[i] = [_reason(CYCLE, "dependency cycle: %s" % " -> ".join(scc + [scc[0]]))]
            bad.add(i)
    propagate(bad)

    live = sorted((by_id[i] for i in by_id if i not in out_refused and i not in pre), key=_order_key)
    pairs = set()
    for c in conflicts or ():
        if isinstance(c, dict) and c.get("a") != c.get("b"):
            pairs.add(frozenset((c.get("a"), c.get("b"))))
    placed, waves = set(), []
    remaining = list(live)
    while remaining:
        wave = []
        for it in remaining:
            i = it["id"]
            if len(wave) >= max_parallel:
                break
            if any(b not in placed for b in deps[i]):
                continue
            if any(frozenset((i, w)) in pairs for w in wave):
                continue
            wave.append(i)
        if not wave:   # unreachable after cycle removal; refuse to spin
            raise PlanError("internal: no schedulable item among %s" % [x["id"] for x in remaining])
        placed.update(wave)   # blockers must sit in strictly EARLIER waves, so commit only after the wave is closed
        remaining = [it for it in remaining if it["id"] not in placed]
        waves.append(wave)
    return {"waves": waves, "refused": {k: out_refused[k] for k in sorted(out_refused)},
            "cycles": cycles, "maxParallel": max_parallel}


# ---------------------------------------------------------------- 004: terminals
def assign_terminals(waves, items, terminals, paths_by_item=None):
    """-> {id: {"terminal", "persona", "kind"[, "reason"]}}.

    `items` = {id: item} or a list of items. `terminals` = `kb-terminals status --json` terminals[] (parsed). Eligibility is
    routing.role_fit. Within a wave: fewest terminals-already-assigned-in-this-wave first (spreads the wave), then the
    terminal's live lane_windows, then name. No eligible terminal -> terminal None + reason NO_TERMINAL (a warning)."""
    if isinstance(items, list):
        items = {i["id"]: i for i in items}
    paths_by_item = paths_by_item or {}
    out = {}
    for wave in waves:
        used = {}
        for iid in wave:
            kind = routing.classify(items[iid], paths_by_item.get(iid))
            fit = routing.role_fit(kind, terminals)
            if not fit:
                out[iid] = {"terminal": None, "persona": None, "kind": kind,
                            "reason": _reason(NO_TERMINAL, "no eligible terminal for kind %s" % kind)}
                continue
            best = min(fit, key=lambda t: (used.get(t["name"], 0), t["lane_windows"], t["name"]))
            used[best["name"]] = used.get(best["name"], 0) + 1
            out[iid] = {"terminal": best["name"], "persona": best.get("developer"), "kind": kind}
    return out


# ================================================================ LEDGER (XACA-1546-001)
# The ONLY writing layer in this module. Everything above is the read-only planner (see the module docstring).
#
# Two layers, one truth (plan "Two-layer ledger"):
#   * the RUN LEDGER   <kanban_dir>/orchestration/<RUN-ID>.jsonl : append-only event history, the source of truth for
#                      "what happened" (dispatches, state changes, questions, stalls, verdicts).
#   * the SUMMARY      board .releases[].orchestration            : the small, current-state projection the bash side reads
#                      (activeRunId, startedAt, closedAt, coordinator, maxParallel, waves, items{}, lanes[]).
# The summary is only ever written through kanban_utils.update_board_safely (flock'd read-modify-write, atomic rename).
RUN_ID_RE = re.compile(r"RUN-REL-[A-Za-z0-9]+(-[A-Za-z0-9]+)*-[0-9]{8}T[0-9]{6}")   # == bash _kb_orch_run_valid
ORCH_DIRNAME = "orchestration"

# Stable event vocabulary. `ts`, `run` and `kind` belong to the ledger envelope and may not be passed as fields; a
# `dispatch` event therefore carries the kb-dispatch --json object NESTED under `dispatch` (that object has its own
# `run` and `ts`) and lifts `item` to the top level.
KIND_RUN_START, KIND_DISPATCH, KIND_STATE = "run_start", "dispatch", "state"
KIND_QUESTION, KIND_ANSWER, KIND_STALL = "question", "answer", "stall"
KIND_CRASH, KIND_FAILED, KIND_DONE = "crash", "failed", "done"
KIND_VERDICT, KIND_RUN_END = "verdict", "run_end"
KIND_LANE = "lane"          # a lane slot changed hands: {item, lane, action: "assign" | "free"} (XACA-1546-011)
# XACA-1808 token telemetry: model_mismatch {item, expected, observed, signature}, token_budget {scope, item?, used, limit,
# signature} (both appended ONCE per signature by the monitor), token_summary {run totals} (appended at ALL_DONE).
KIND_MODEL_MISMATCH, KIND_TOKEN_BUDGET, KIND_TOKEN_SUMMARY = "model_mismatch", "token_budget", "token_summary"
# kind -> fields that must be present (fail closed: an event the summariser cannot attribute is refused at write time).
LEDGER_KINDS = {
    KIND_RUN_START: (), KIND_DISPATCH: ("item", "dispatch"), KIND_STATE: ("item", "from", "to"),
    KIND_QUESTION: ("item",), KIND_ANSWER: ("item",), KIND_STALL: ("item",), KIND_CRASH: ("item",),
    KIND_FAILED: ("item",), KIND_DONE: ("item",), KIND_VERDICT: (), KIND_RUN_END: (),
    KIND_LANE: ("item", "lane", "action"),
    KIND_MODEL_MISMATCH: ("item",), KIND_TOKEN_BUDGET: (), KIND_TOKEN_SUMMARY: (),
}
_RESERVED_FIELDS = ("ts", "run", "kind")


class LedgerError(Exception):
    """Any refusal from the ledger layer (bad id, unknown kind, missing release, double start, ...)."""


class LedgerCorrupt(LedgerError):
    """ledger_read found a torn/garbage/foreign line. `.events` = the lines that were fine, `.errors` = one
    {"line": N, "error": text, "text": raw} per bad line, `.warnings` as for a clean read."""

    def __init__(self, path, events, errors, warnings):
        LedgerError.__init__(self, "ledger %s is corrupt: %d bad line(s), first: line %d: %s"
                             % (path, len(errors), errors[0]["line"], errors[0]["error"]))
        self.path, self.events, self.errors, self.warnings = path, events, errors, warnings


class LedgerEvents(list):
    """The events of a clean read, in file order. `.warnings` lists non-fatal notes (a final partial line)."""
    warnings = ()


def run_id_valid(run_id):
    return isinstance(run_id, str) and RUN_ID_RE.fullmatch(run_id) is not None   # fullmatch: no trailing-newline slip


def run_release(run_id):
    """RUN-REL-2026-Q4-049-20261113T193800 -> REL-2026-Q4-049 (inverse of mint_run_id)."""
    if not run_id_valid(run_id):
        raise LedgerError("not a valid run id: %r" % (run_id,))
    return run_id[len("RUN-"):].rsplit("-", 1)[0]


def _utc(now):
    if now is None:
        return datetime.datetime.now(datetime.timezone.utc)
    if isinstance(now, (int, float)) and not isinstance(now, bool):
        return datetime.datetime.fromtimestamp(now, datetime.timezone.utc)
    if isinstance(now, datetime.datetime):
        return now.astimezone(datetime.timezone.utc) if now.tzinfo else now.replace(tzinfo=datetime.timezone.utc)
    raise LedgerError("now must be None, epoch seconds or a datetime: %r" % (now,))


def _ts(now=None):
    return _utc(now).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def mint_run_id(release_id, now=None):
    """RUN-<REL-ID>-<UTC yyyymmddThhmmss>. Refuses a release id that would not round-trip through run_id_valid."""
    run_id = "RUN-%s-%s" % (release_id, _utc(now).strftime("%Y%m%dT%H%M%S"))
    if not isinstance(release_id, str) or not run_id_valid(run_id):
        raise LedgerError("cannot mint a run id for release %r (must be REL-<alnum>[-<alnum>...])" % (release_id,))
    return run_id


def ledger_path(kanban_dir, run_id):
    """<kanban_dir>/orchestration/<RUN-ID>.jsonl. The id is validated FIRST: no separator or dot can reach the path."""
    if not run_id_valid(run_id):
        raise LedgerError("not a valid run id: %r" % (run_id,))
    return os.path.join(kanban_dir, ORCH_DIRNAME, run_id + ".jsonl")


def _encode(event):
    try:
        return (json.dumps(event, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise LedgerError("event is not JSON-serialisable: %s" % exc)


def _check_event(kind, fields):
    if kind not in LEDGER_KINDS:
        raise LedgerError("unknown ledger kind %r (known: %s)" % (kind, ", ".join(sorted(LEDGER_KINDS))))
    for k in _RESERVED_FIELDS:
        if k in fields:
            raise LedgerError("field %r is reserved by the ledger envelope" % k)
    missing = [k for k in LEDGER_KINDS[kind] if k not in fields]
    if missing:
        raise LedgerError("%s event is missing required field(s): %s" % (kind, ", ".join(missing)))
    if kind == KIND_DISPATCH and not isinstance(fields["dispatch"], dict):
        raise LedgerError("dispatch event: `dispatch` must be the kb-dispatch --json object")


def ledger_append(kanban_dir, run_id, kind, now=None, **fields):
    """Append ONE event {ts, run, kind, ...fields} as one sorted-key JSON line. Returns the event dict.

    Concurrency: an flock on the sidecar <ledger>.lock serialises appenders, the line goes out in a single write on an
    O_APPEND fd, then fsync. If the file ends without a newline (a crashed writer), a newline is written first so the torn
    fragment stays its OWN line (ledger_read will report it) instead of swallowing this record."""
    _check_event(kind, fields)
    path = ledger_path(kanban_dir, run_id)
    event = dict(fields)
    event.update({"ts": _ts(now), "run": run_id, "kind": kind})
    data = _encode(event)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lock_fd = os.open(path + ".lock", os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        fd = os.open(path, os.O_RDWR | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            size = os.fstat(fd).st_size
            if size > 0 and os.pread(fd, 1, size - 1) != b"\n":
                data = b"\n" + data
            view = memoryview(data)
            while view:
                view = view[os.write(fd, view):]
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        os.close(lock_fd)   # closing releases the flock
    return event


def ledger_read_report(kanban_dir, run_id):
    """Parse the ledger WITHOUT raising on bad lines -> (events, errors, warnings). Diagnostics use this; consumers use
    ledger_read. A missing ledger is a LedgerError (never an empty run). A line is bad if it is blank, not valid UTF-8,
    not a JSON object, lacks a string `ts`, names a different `run`, or has an unknown `kind`. The ONLY tolerated oddity is
    a final segment without a trailing newline (a write in progress): reported in warnings, never in events."""
    path = ledger_path(kanban_dir, run_id)
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        raise LedgerError("cannot read ledger %s: %s" % (path, exc))
    parts = raw.split(b"\n")
    tail = parts.pop()          # b"" when the file ends with a newline (or is empty)
    events, errors, warnings = [], [], []
    for n, line in enumerate(parts, 1):
        try:
            obj = json.loads(line.decode("utf-8"))
            if not isinstance(obj, dict):
                raise ValueError("not a JSON object")
            if not isinstance(obj.get("ts"), str):
                raise ValueError("missing ts")
            if obj.get("run") != run_id:
                raise ValueError("run is %r, expected %r" % (obj.get("run"), run_id))
            if obj.get("kind") not in LEDGER_KINDS:
                raise ValueError("unknown kind %r" % (obj.get("kind"),))
        except ValueError as exc:     # JSONDecodeError and UnicodeDecodeError are both ValueErrors
            errors.append({"line": n, "error": str(exc), "text": line.decode("utf-8", "replace")[:200]})
            continue
        events.append(obj)
    if tail:
        warnings.append("line %d: partial final line without a newline (write in progress?), ignored: %r"
                        % (len(parts) + 1, tail.decode("utf-8", "replace")[:80]))
    return events, errors, warnings


def ledger_read(kanban_dir, run_id):
    """The events in order (a list with `.warnings`). FAILS CLOSED: any bad line raises LedgerCorrupt (carrying `.events`,
    `.errors`, `.warnings`); nothing is silently skipped. A missing ledger raises LedgerError."""
    events, errors, warnings = ledger_read_report(kanban_dir, run_id)
    if errors:
        raise LedgerCorrupt(ledger_path(kanban_dir, run_id), events, errors, warnings)
    out = LedgerEvents(events)
    out.warnings = tuple(warnings)
    return out


# ---------------------------------------------------------------- summary (board .releases[].orchestration)
def _find_release_in(board, release_id):
    for rel in board.get("releases") or []:
        if isinstance(rel, dict) and rel.get("id") == release_id:
            return rel
    raise LedgerError("release %s not found in the board" % release_id)


def write_summary(board_file, release_id, mutate_fn):
    """Apply mutate_fn(orchestration_dict) to board .releases[id].orchestration under update_board_safely's lock; returns
    the resulting dict. mutate_fn mutates in place (or returns a replacement dict). A missing release, a board that cannot
    be read/written, or anything mutate_fn raises RAISES here (update_board_safely itself only returns False, which would
    otherwise read as success). Keys mutate_fn does not touch, `lanes` included, are preserved."""
    import kanban_utils
    box = {}

    def _upd(board):
        try:
            rel = _find_release_in(board, release_id)
            orch = rel.get("orchestration")
            if not isinstance(orch, dict):
                orch = {}
            res = mutate_fn(orch)
            if res is not None:
                orch = res
            rel["orchestration"] = orch
            box["orch"] = json.loads(json.dumps(orch))
            return board
        except Exception as exc:  # noqa: BLE001 -- re-raised below; must not be swallowed by update_board_safely
            box["exc"] = exc
            return None           # None = skip the write

    ok = kanban_utils.update_board_safely(board_file, _upd)
    if "exc" in box:
        raise box["exc"]
    if not ok or "orch" not in box:
        raise LedgerError("could not update the board summary for %s (%s)" % (release_id, board_file))
    return box["orch"]


def _plan_waves(plan_):
    """plan() output -> (waves as list of lists of ids, {id: terminal})."""
    waves, terminals = [], {}
    for w in plan_.get("waves") or []:
        row = w.get("items") if isinstance(w, dict) else w
        ids = []
        for it in row or []:
            iid = it.get("id") if isinstance(it, dict) else it
            ids.append(iid)
            if isinstance(it, dict):
                terminals[iid] = it.get("terminal")
        waves.append(ids)
    return waves, terminals


def start_run(board_file, kanban_dir, release_id, plan_, coordinator, max_parallel, now=None):
    """Mint a run id, append run_start, write the summary; returns the run id. REFUSES (LedgerError) when the release
    already has an activeRunId that is not closed: no silent double run. The check, the run_start append and the summary
    write all happen under the board lock, so two racing starts cannot both win. Failure modes: if the ledger append fails
    nothing is written to the board; if the board write fails AFTER the append, an orphan ledger holding only run_start is
    left behind (harmless: no summary references it)."""
    waves, terminals = _plan_waves(plan_)
    run_id = mint_run_id(release_id, now)
    started = _ts(now)

    def _mut(orch):
        if orch.get("activeRunId") and not orch.get("closedAt"):
            raise LedgerError("release %s already has an active run %s (close it first)" % (release_id, orch["activeRunId"]))
        if os.path.exists(ledger_path(kanban_dir, run_id)):
            raise LedgerError("ledger for %s already exists (id collision within one second)" % run_id)
        ledger_append(kanban_dir, run_id, KIND_RUN_START, now=now, release=release_id, coordinator=coordinator,
                      maxParallel=max_parallel, waves=waves)
        orch.pop("closedAt", None)
        orch.pop("tokens", None)       # XACA-1808: a re-run starts with no telemetry; the previous run's numbers are not this run's
        if isinstance(plan_.get("contention"), list):
            # XACA-1546-003: the monitor's compute_slot_free needs the plan's contention pairs. A plan without the key
            # stores nothing, so "missing" stays distinguishable (the monitor then fails closed: every pair conflicts).
            orch["contention"] = [dict(c) if isinstance(c, dict) else c for c in plan_["contention"]]
        else:
            orch.pop("contention", None)
        orch.update({"activeRunId": run_id, "startedAt": started, "coordinator": coordinator,
                     "maxParallel": max_parallel, "waves": waves,
                     "lanes": _init_lanes(orch.get("lanes"), waves, max_parallel, started),
                     "items": {iid: {"terminal": terminals.get(iid), "state": "QUEUED", "since": started}
                               for w in waves for iid in w}})

    write_summary(board_file, release_id, _mut)
    return run_id


# ---------------------------------------------------------------- lanes (XACA-1546-011)
# LANES. release.orchestration.lanes[] is one entry per dispatch slot, lane numbers 1..maxParallel:
#     {"lane": int, "current": {"id", "status", "stage", "prNumber"} | null, "queue": [item ids], "since": ISO ts}
# RULES (the lamp lines stay stable because a lane number never moves):
#   * start_run builds lanes 1..maxParallel, current null. `queue` = the plan's wave items flattened in plan order
#     (wave 1 first, in-wave order) and dealt ROUND-ROBIN: the i-th item goes to lane (i % N) + 1. Deterministic, no
#     capacity guessing. A RE-RUN keeps the existing lanes (their `current` and number) and rebuilds only the queues from the
#     new plan; items already sitting in a lane are not queued again. maxParallel may GROW (extra empty lanes) and never
#     shrinks below an occupied lane: an empty lane above the new max is dropped, an occupied one is kept.
#   * assign_lane (dispatch) puts the item in the requested free lane or the LOWEST-numbered free lane, removes it from every
#     queue, appends a `lane` ledger event. Refuses an occupied lane, no free lane, an untracked item, an item already in a
#     lane, a lane outside 1..maxParallel.
#   * record_state keeps `current` in sync (status = the orchestrator_state STATES name, stage = STATE_STAGE[status],
#     prNumber), and bumps `since` on every change of `current`.
#   * HARD CONTRACT with the bash dispatcher (kb-dispatch in kanban-helpers.sh): it counts
#         .orchestration.lanes[] | objects | select(.current != null)
#     as OPEN lanes and refuses LANES_FULL at >= maxParallel. So `current` MUST become null when the lane's item reaches a
#     terminal board state: DONE (completed) or CANCELLED. Otherwise dispatch deadlocks. The lane NUMBER stays, so the next
#     dispatch ("SLOT_FREE") reuses it. FAILED, CRASHED, STALLED and every other state KEEP the lane: a human decides, and a
#     dead item must keep counting against the cap rather than silently free capacity.
STATE_STAGE = {
    "QUEUED": "queued", "DISPATCHING": "dispatching", "RUNNING": "coding", "QUESTION_PENDING": "question",
    "IN_REVIEW": "review", "MERGED_PENDING_DONE": "merged", "DONE": "done", "FAILED": "failed",
    "CRASHED": "crashed", "STALLED": "stalled", "CANCELLED": "cancelled", "UNKNOWN": "unknown",
}
LANE_FREEING_STATES = ("DONE", "CANCELLED")   # the ONLY states that null `current` (see the contract above)


def _stage_of(status):
    return STATE_STAGE.get(status, "unknown")


def _lane_no(entry, index):
    n = entry.get("lane") if isinstance(entry, dict) else None
    return n if isinstance(n, int) and not isinstance(n, bool) and n >= 1 else index + 1


def _lane_is_open(entry):
    return isinstance(entry, dict) and entry.get("current") is not None


def _init_lanes(existing, waves, max_parallel, ts):
    """Build the lanes list for start_run (see LANES). Pure."""
    by_no = {}
    if isinstance(existing, list):
        for i, e in enumerate(existing):
            if isinstance(e, dict):
                by_no.setdefault(_lane_no(e, i), e)
    n = max_parallel if isinstance(max_parallel, int) and not isinstance(max_parallel, bool) and max_parallel >= 1 else 1
    occupied = {e["current"].get("id") for e in by_no.values() if isinstance(e.get("current"), dict)}
    lanes = []
    for no in sorted(set(range(1, n + 1)) | {k for k, e in by_no.items() if _lane_is_open(e)}):
        e = dict(by_no.get(no) or {})
        e["lane"] = no
        e.setdefault("current", None)
        e.setdefault("since", ts)
        e["queue"] = []
        lanes.append(e)
    pending = list(dict.fromkeys(iid for w in waves for iid in w if iid not in occupied))   # an id listed twice queues once
    for i, iid in enumerate(pending):
        lanes[i % n]["queue"].append(iid)     # lanes[:n] are exactly lanes 1..n (sorted; occupied extras sort after)
    return lanes


def lanes_view(summary):
    """Pure. orchestration summary -> lanes sorted by number, fixed width 1..maxParallel (missing lanes shown empty:
    {"lane": N, "current": None, "queue": [], "since": None}); an occupied lane above maxParallel is still shown."""
    summary = summary if isinstance(summary, dict) else {}
    mp = summary.get("maxParallel")
    n = mp if isinstance(mp, int) and not isinstance(mp, bool) and mp >= 1 else 0
    raw = summary.get("lanes")
    by_no = {}
    if isinstance(raw, list):
        for i, e in enumerate(raw):
            if isinstance(e, dict):
                by_no.setdefault(_lane_no(e, i), e)
    nos = sorted(set(range(1, n + 1)) | set(by_no))
    out = []
    for no in nos:
        e = by_no.get(no) or {}
        out.append({"lane": no, "current": e.get("current"), "queue": list(e.get("queue") or []),
                    "since": e.get("since")})
    return out


def _find_lane(lanes, item):
    for e in lanes:
        cur = e.get("current") if isinstance(e, dict) else None
        if isinstance(cur, dict) and cur.get("id") == item:
            return e
    return None


def assign_lane(board_file, kanban_dir, release_id, run_id, item_id, lane=None, now=None):
    """Dispatch: put item_id into `lane` (must be free) or the lowest-numbered free lane; remove it from every queue; append
    a `lane` ledger event; returns the lane number. Refuses (LedgerError): not the active open run, an item the run does not
    track, an item already in a lane, a lane outside 1..maxParallel, an occupied lane, and no free lane. All under the
    board lock."""
    ts = _ts(now)
    box = {}

    def _mut(orch):
        _active_run_check(orch, release_id, run_id)
        items = orch.get("items")
        if not isinstance(items, dict) or not isinstance(items.get(item_id), dict):
            raise LedgerError("item %s is not tracked by run %s" % (item_id, run_id))
        mp = orch.get("maxParallel")
        lanes = orch.get("lanes")
        if not isinstance(lanes, list):
            lanes = []
        if not lanes:    # a summary from before lanes existed: materialise empty lanes 1..maxParallel
            lanes = _init_lanes([], [], mp if isinstance(mp, int) else 1, orch.get("startedAt") or ts)
        if _find_lane(lanes, item_id) is not None:
            raise LedgerError("item %s is already in lane %s" % (item_id, _find_lane(lanes, item_id)["lane"]))
        by_no = {_lane_no(e, i): e for i, e in enumerate(lanes) if isinstance(e, dict)}
        if lane is not None:
            if isinstance(lane, bool) or not isinstance(lane, int) or lane < 1 or lane > max(mp or 0, 0):
                raise LedgerError("lane %r is outside 1..%s" % (lane, mp))
            target = by_no.get(lane)
            if target is None:
                target = {"lane": lane, "current": None, "queue": [], "since": ts}
                lanes.append(target)
            elif _lane_is_open(target):
                raise LedgerError("lane %d is occupied by %s" % (lane, (target["current"] or {}).get("id")))
        else:
            free = [no for no in sorted(by_no) if not _lane_is_open(by_no[no]) and no <= (mp or 0)]
            if not free:
                raise LedgerError("no free lane (maxParallel %s, all occupied)" % (mp,))
            target = by_no[free[0]]
        status = items[item_id].get("state") or "QUEUED"
        target["current"] = {"id": item_id, "status": status, "stage": _stage_of(status),
                             "prNumber": items[item_id].get("prNumber")}
        target["since"] = ts
        for e in lanes:
            if isinstance(e, dict) and isinstance(e.get("queue"), list):
                e["queue"] = [q for q in e["queue"] if q != item_id]
        lanes.sort(key=lambda e: e.get("lane", 0) if isinstance(e, dict) else 0)
        orch["lanes"] = lanes
        ledger_append(kanban_dir, run_id, KIND_LANE, now=now, item=item_id, lane=target["lane"], action="assign")
        box["lane"] = target["lane"]

    write_summary(board_file, release_id, _mut)
    return box["lane"]


def _sync_lane(orch, kanban_dir, run_id, item, to, pr_number, has_pr, ts, now):
    """record_state helper: mirror a state change onto the item's lane (no-op when the item holds no lane)."""
    lanes = orch.get("lanes")
    entry = _find_lane(lanes, item) if isinstance(lanes, list) else None
    if entry is None:
        return
    if to in LANE_FREEING_STATES:
        entry["current"] = None
        ledger_append(kanban_dir, run_id, KIND_LANE, now=now, item=item, lane=entry.get("lane"), action="free")
    else:
        cur = entry["current"]
        cur["status"], cur["stage"] = to, _stage_of(to)
        if has_pr:
            cur["prNumber"] = pr_number
    entry["since"] = ts


def _active_run_check(orch, release_id, run_id):
    if orch.get("activeRunId") != run_id:
        raise LedgerError("%s is not the active run of %s (active: %s)" % (run_id, release_id, orch.get("activeRunId")))
    if orch.get("closedAt"):
        raise LedgerError("run %s of %s is already closed" % (run_id, release_id))


def record_state(board_file, kanban_dir, release_id, run_id, item, to, detail=None, now=None, **extra):
    """Append a `state` event AND update summary items[item] in ONE locked call. `from` is read from the summary.
    extra may carry terminal=... / prNumber=...: they ride on the event and are stored on items[item]. Refuses a run that
    is not the active, open run, and an item the run does not track. Also mirrors the change onto the item's lane (see LANES:
    DONE / CANCELLED null the lane's `current` and keep the lane number; every other state keeps the lane)."""
    ts = _ts(now)
    # ONE vocabulary: the summary, the lanes and the ledger all carry orchestrator_state.STATES names, so a reader
    # (status, LCARS, ticket-lamp) never has to guess a spelling.
    if to not in ostate.STATES:
        raise LedgerError("state %r is not one of %s" % (to, ", ".join(ostate.STATES)))

    def _mut(orch):
        _active_run_check(orch, release_id, run_id)
        items = orch.get("items")
        if not isinstance(items, dict) or item not in items or not isinstance(items[item], dict):
            raise LedgerError("item %s is not tracked by run %s" % (item, run_id))
        prev = items[item].get("state")
        if prev == to and all(items[item].get(k) == v for k, v in extra.items() if k in ("terminal", "prNumber")):
            return    # already recorded (a second watcher lost the race): no RUNNING->RUNNING event, `since` untouched
        fields = {"item": item, "from": prev, "to": to}
        if detail is not None:
            fields["detail"] = detail
        fields.update(extra)
        ledger_append(kanban_dir, run_id, KIND_STATE, now=now, **fields)
        items[item].update({"state": to, "since": ts})
        for k in ("terminal", "prNumber"):
            if k in extra:
                items[item][k] = extra[k]
        _sync_lane(orch, kanban_dir, run_id, item, to, extra.get("prNumber"), "prNumber" in extra, ts, now)

    write_summary(board_file, release_id, _mut)


def close_run(board_file, kanban_dir, release_id, run_id, outcome="complete", detail=None, now=None):
    """Append run_end and stamp closedAt (activeRunId stays, as the closed run's record). Refuses a run that is not the
    active open one."""
    ts = _ts(now)

    def _mut(orch):
        _active_run_check(orch, release_id, run_id)
        fields = {"outcome": outcome}
        if detail is not None:
            fields["detail"] = detail
        ledger_append(kanban_dir, run_id, KIND_RUN_END, now=now, **fields)
        orch["closedAt"] = ts

    write_summary(board_file, release_id, _mut)


def write_tokens(board_file, release_id, run_id, tokens):
    """XACA-1808-006: store the token telemetry block at release.orchestration.tokens, under the board lock (the same
    write_summary path as every other summary write). Refuses a run that is not the release's active run. A CLOSED run is
    accepted on purpose (the final refresh at ALL_DONE is written just before close_run, but a late correction after close is
    still the same run's own data). `tokens` must be a JSON object. Keys of the summary this does not touch are preserved."""
    if not isinstance(tokens, dict):
        raise LedgerError("tokens must be a JSON object, got %s" % type(tokens).__name__)

    def _mut(orch):
        if orch.get("activeRunId") != run_id:
            raise LedgerError("%s is not the active run of %s (active: %s)" % (run_id, release_id, orch.get("activeRunId")))
        orch["tokens"] = tokens

    write_summary(board_file, release_id, _mut)


def item_run_id(board_file, item_id):
    """item.orchestration.runId from the board, or None when the item has none (or does not exist). Read-only."""
    try:
        with open(board_file, "r", encoding="utf-8") as fh:
            board = json.load(fh)
    except (OSError, ValueError):
        return None
    for it in board.get("backlog") or []:
        if isinstance(it, dict) and it.get("id") == item_id:
            orch = it.get("orchestration")
            rid = orch.get("runId") if isinstance(orch, dict) else None
            return rid if isinstance(rid, str) and rid else None
    return None


def _parse_fields(pairs, json_pairs):
    fields = {}
    for p in pairs or []:
        k, sep, v = p.partition("=")
        if not sep or not k:
            raise LedgerError("--field expects k=v, got %r" % p)
        fields[k] = v
    for p in json_pairs or []:
        k, sep, v = p.partition("=")
        if not sep or not k:
            raise LedgerError("--json-field expects k=JSON, got %r" % p)
        try:
            fields[k] = json.loads(v)
        except ValueError as exc:
            raise LedgerError("--json-field %s is not valid JSON: %s" % (k, exc))
    return fields


def hook_append(board_file, item_id, kind, kanban_dir=None, **fields):
    """The bash hook entry point. NO-OP (returns None) when the item carries no orchestration.runId. Otherwise appends
    `kind` for that run, with item=<item_id> added; returns the event. Refuses (LedgerError) a malformed runId or a run
    with no ledger yet (start_run creates it; a hook must never conjure a ledger for a made-up run)."""
    run_id = item_run_id(board_file, item_id)
    if run_id is None:
        return None
    kdir = kanban_dir or os.path.dirname(os.path.abspath(board_file))
    if not run_id_valid(run_id):
        raise LedgerError("item %s carries an invalid orchestration.runId %r" % (item_id, run_id))
    if not os.path.isfile(ledger_path(kdir, run_id)):
        raise LedgerError("no ledger for run %s (item %s); not creating one from a hook" % (run_id, item_id))
    fields.setdefault("item", item_id)
    if kind == KIND_DISPATCH and "dispatch" not in fields:
        # XACA-1808-D: kb-dispatch reports a DISPATCHED outcome through the shell hook, whose k=v pairs are flat strings, but a
        # `dispatch` event carries the kb-dispatch --json object NESTED under `dispatch` (see KIND_* above). Nest everything but
        # `item`, and lift `model` to the top level too, so a reader can use either spelling (orchestrator_tokens reads both).
        nested = {k: v for k, v in fields.items() if k != "item"}
        fields = {"item": fields["item"], "dispatch": nested}
        if "model" in nested:
            fields["model"] = nested["model"]
    return ledger_append(kdir, run_id, kind, **fields)

# ---------------------------------------------------------------- resume (XACA-1547)
# A coordinator that restarts mid-run (its pane died, the machine rebooted, the user re-ran `kb-run <REL-ID>`) must pick the
# run back up WITHOUT re-dispatching work that is still running. The ledger is the resume source (plan "Two-layer ledger"):
#   active_run           the release's active, open run from the board summary (None = nothing to resume, start fresh)
#   rehydrate            folds the ledger into per-item history: last recorded state, DISPATCHED count + last dispatch
#                        (terminal, resume flag), the open question (a `question` with no later `answer` on its thread), the
#                        last verdict, and run-level facts (startedAt, coordinator, lastVerdictAt = when a coordinator last
#                        looked). PURE: no I/O, never raises on an odd event (an unknown shape is ignored, not fatal; ledger_read
#                        already refused anything torn).
#   reattach_coordinator re-points the run at a NEW coordinator address in ONE board write: release.orchestration.coordinator
#                        AND item.orchestration.coordinator of every non-terminal item of this run. kb-ask reads the ITEM's
#                        coordinator (XACA-1545), so rewriting only the summary would send every later question to the dead
#                        pane's mailbox. Questions already pending keep their own `pendingQuestion.coordinator`: they were
#                        sent to the old address, and the resume report lists them so the new coordinator can kb-answer them.
# The decisions about what to DO with each item live in orchestrator_monitor.resume (the `resume` subcommand).
VERDICT_RESUMED = "RESUMED"
ADDR_RE = re.compile(r"[a-z0-9][a-z0-9-]*:[a-z0-9][a-z0-9_-]*")   # == bash _kb_orch_addr_valid


def addr_valid(addr):
    return isinstance(addr, str) and ADDR_RE.fullmatch(addr) is not None


def coordinator_address(value):
    """release.orchestration.coordinator is "team:terminal" or {"address": "team:terminal", ...}; -> the string or None."""
    if isinstance(value, dict):
        value = value.get("address")
    return value if isinstance(value, str) and value else None


def active_run(board, release_id):
    """-> (run_id, orchestration dict) for the release's active, OPEN run, or None (no release, no run, or closed)."""
    for rel in (board or {}).get("releases") or []:
        if isinstance(rel, dict) and rel.get("id") == release_id:
            orch = rel.get("orchestration")
            if isinstance(orch, dict) and orch.get("activeRunId") and not orch.get("closedAt"):
                return orch["activeRunId"], orch
            return None
    return None


def rehydrate(events):
    """Fold a run's ledger events (ledger_read order) into {"run": {...}, "items": {ID: {...}}}. See the block above."""
    run = {"startedAt": None, "coordinator": None, "lastEventAt": None, "lastVerdictAt": None, "lastVerdict": None,
           "resumes": 0, "closed": False, "events": 0}
    items = {}

    def it(iid):
        return items.setdefault(iid, {"ledgerState": None, "stateAt": None, "dispatches": 0, "resumeDispatches": 0,
                                      "lastDispatch": None, "openQuestion": None, "lastVerdict": None})

    for ev in events or []:
        if not isinstance(ev, dict):
            continue
        run["events"] += 1
        kind, ts, iid = ev.get("kind"), ev.get("ts"), ev.get("item")
        iid = iid if isinstance(iid, str) and iid and iid != "-" else None
        run["lastEventAt"] = ts
        if kind == KIND_RUN_START:
            run["startedAt"] = ts
            run["coordinator"] = coordinator_address(ev.get("coordinator"))
        elif kind == KIND_RUN_END:
            run["closed"] = True
        elif kind == KIND_VERDICT:
            run["lastVerdictAt"], run["lastVerdict"] = ts, ev.get("verdict")
            if ev.get("verdict") == VERDICT_RESUMED:
                run["resumes"] += 1
                if coordinator_address(ev.get("coordinator")):
                    run["coordinator"] = coordinator_address(ev.get("coordinator"))
            elif iid:
                it(iid)["lastVerdict"] = {"verdict": ev.get("verdict"), "ts": ts}
        elif kind == KIND_STATE and iid:
            it(iid).update({"ledgerState": ev.get("to"), "stateAt": ts})
        elif kind == KIND_DISPATCH and iid:
            d = ev.get("dispatch") if isinstance(ev.get("dispatch"), dict) else {}
            row = it(iid)
            row["lastDispatch"] = {"ts": ts, "outcome": d.get("outcome"), "terminal": d.get("terminal"),
                                   "reason": d.get("reason"), "resume": str(d.get("resume")).lower() in ("1", "true")}
            if d.get("outcome") == "DISPATCHED":
                row["dispatches"] += 1
                if row["lastDispatch"]["resume"]:
                    row["resumeDispatches"] += 1
        elif kind == KIND_QUESTION and iid:
            it(iid)["openQuestion"] = {"thread": ev.get("thread"), "ts": ts, "to": ev.get("to")}
        elif kind == KIND_ANSWER and iid:
            q = it(iid)["openQuestion"]
            if q is not None and (q.get("thread") is None or ev.get("thread") in (None, q.get("thread"))):
                it(iid)["openQuestion"] = None
    return {"run": run, "items": items}


def reattach_coordinator(board_file, release_id, run_id, coordinator, now=None):
    """Re-point an active run at `coordinator` (see the block above). ONE locked board write. Returns
    {"previous": old address|None, "items": [ids whose item.orchestration.coordinator was rewritten]}. Refuses (LedgerError)
    a bad address, a missing release, or a run that is not the release's active open run. Same address = no write."""
    if not addr_valid(coordinator):
        raise LedgerError("coordinator %r is not a team:terminal address" % (coordinator,))
    import kanban_utils
    ts = _ts(now)
    box = {}

    def _upd(board):
        try:
            rel = _find_release_in(board, release_id)
            orch = rel.get("orchestration")
            if not isinstance(orch, dict):
                raise LedgerError("release %s has no orchestration summary" % release_id)
            _active_run_check(orch, release_id, run_id)
            prev = coordinator_address(orch.get("coordinator"))
            box["previous"], box["items"] = prev, []
            changed = prev != coordinator
            if isinstance(orch.get("coordinator"), dict):
                orch["coordinator"] = dict(orch["coordinator"], address=coordinator)
            else:
                orch["coordinator"] = coordinator
            for item in board.get("backlog") or []:
                io = item.get("orchestration") if isinstance(item, dict) else None
                if not isinstance(io, dict) or io.get("runId") != run_id:
                    continue
                if ostate.resolve_item_status(item) in ("completed", "cancelled"):
                    continue
                if io.get("coordinator") != coordinator:
                    io["coordinator"] = coordinator
                    item["updatedAt"] = ts
                    box["items"].append(item.get("id"))
                    changed = True
            if not changed:
                return None               # nothing to write
            board["lastUpdated"] = ts
            return board
        except Exception as exc:  # noqa: BLE001 -- re-raised below; must not be swallowed by update_board_safely
            box["exc"] = exc
            return None

    ok = kanban_utils.update_board_safely(board_file, _upd)
    if "exc" in box:
        if isinstance(box["exc"], LedgerError):
            raise box["exc"]
        # PR #1348 review: an odd board shape (TypeError, ...) must stay a LedgerError, so `resume` still ends on a VERDICT line.
        raise LedgerError("could not re-attach %s: %s: %s" % (run_id, type(box["exc"]).__name__, box["exc"]))
    if not ok or "previous" not in box:      # update_board_safely: False = unreadable/unwritable (None from _upd is True)
        raise LedgerError("could not re-attach %s to %s (%s)" % (run_id, coordinator, board_file))
    return {"previous": box["previous"], "items": sorted(box["items"])}
# ================================================================ end LEDGER (XACA-1546-001)


# ---------------------------------------------------------------- entry point (the only I/O)
BATCH_KIND = "batch"   # XACA-1834: an ephemeral REL-BATCH-* record minted by `kb-run A,B,...`


def is_batch(rel):
    return isinstance(rel, dict) and rel.get("kind") == BATCH_KIND


def is_member(item, rel, release_id):
    """XACA-1834: does `item` belong to the release? A batch release owns exactly the ids in its `batchItems` (its items
    keep their real releaseAssignment, so a worker still branches from its own release); any other release owns the items
    whose releaseAssignment.releaseId is its id. Same rule as bash _KB_ORCH_MEMBER_JQ (kb-dispatch, _kb_orch_check)."""
    if not isinstance(item, dict):
        return False
    if is_batch(rel):
        return item.get("id") in [b for b in rel.get("batchItems") or [] if isinstance(b, str)]
    ra = item.get("releaseAssignment")
    return isinstance(ra, dict) and ra.get("releaseId") == release_id


def _load_board(kanban_dir, release_id):
    import release_resume
    try:
        _path, board, rel = release_resume.find_release(kanban_dir, release_id)
    except Exception as exc:  # noqa: BLE001 -- RunnerError / bad JSON: one error type for the CLI
        raise PlanError(str(exc))
    return board, rel


def _hotspot_config(board):
    """-> (entries|None, invalid_text|None) from board.releaseConfig.orchestration (dict key `hotspots`, or a bare list)."""
    rc = board.get("releaseConfig")
    if not isinstance(rc, dict) or "orchestration" not in rc or rc["orchestration"] is None:
        return None, None
    o = rc["orchestration"]
    if isinstance(o, list):
        return o, None
    if isinstance(o, dict):
        if "hotspots" not in o or o["hotspots"] is None:
            return None, None
        if isinstance(o["hotspots"], list):
            return o["hotspots"], None
        return None, "releaseConfig.orchestration.hotspots must be a list, got %s (ignored)" % type(o["hotspots"]).__name__
    return None, "releaseConfig.orchestration must be an object with a `hotspots` list, got %s (ignored)" % type(o).__name__


def plan(release_id, kanban_dir, repo_root=None, terminals=None, max_parallel=None, contention=None):
    """The whole read-only run plan for a release. `terminals` = parsed terminals[] (None -> no terminals: every item gets
    NO_TERMINAL). `contention` = module-like with extract_paths/find_plan_doc/load_hotspots/predict (default: the real
    orchestrator_contention, imported here so the pure layers above never need it)."""
    if contention is None:
        import orchestrator_contention as contention
    kanban_dir = os.path.abspath(kanban_dir)   # a relative dir must not depend on cwd vs repo_root (NO_PLAN_DOC for all)
    board, rel = _load_board(kanban_dir, release_id)
    orch = rel.get("orchestration") if isinstance(rel.get("orchestration"), dict) else {}
    if max_parallel is None:
        max_parallel = orch.get("maxParallel", DEFAULT_MAX_PARALLEL)
    members = sorted((i for i in board.get("backlog") or [] if is_member(i, rel, release_id)),
                     key=lambda i: i.get("id") or "")
    ids = [i["id"] for i in members]
    skipped, refused_reasons, candidates = [], {}, []
    for it in members:
        why = check_readiness(it, ids, board, kanban_dir, repo_root, contention.find_plan_doc)
        if why and why[0]["code"] == ALREADY_TERMINAL:
            skipped.append({"id": it["id"], "status": it.get("status")})
        elif why:
            refused_reasons[it["id"]] = why
        else:
            candidates.append(it)
    by_id = {i["id"]: i for i in members}
    # A terminal in-release blocker is not a scheduling edge: completed = satisfied, cancelled = refused for its dependants.
    cancelled = {s["id"] for s in skipped if s["status"] == "cancelled"}
    completed = {s["id"] for s in skipped if s["status"] == "completed"}
    sched_items = []
    for it in candidates:
        it2 = dict(it)
        it2["blockedBy"] = [b for b in _blockers(it) if b not in completed]
        sched_items.append(it2)

    paths_by_item, reports = {}, {}
    report_fn = getattr(contention, "extract_paths_report", None)
    for it in candidates:
        doc = contention.find_plan_doc(it, kanban_dir, repo_root)
        text = ""
        if doc:
            try:
                with open(doc, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                pass
        if report_fn is not None:
            rep_ = report_fn(text, it.get("description"), repo_root=repo_root)
        else:
            rep_ = {"paths": contention.extract_paths(text, it.get("description")), "unparsed": []}
        reports[it["id"]] = rep_
        paths_by_item[it["id"]] = list(rep_.get("paths") or [])
    cfg, cfg_invalid = _hotspot_config(board)
    hotspots = contention.load_hotspots(repo_root or DEFAULT_REPO_ROOT, cfg)
    # FAIL CLOSED: the rule lives in ONE place, contention.predict_closed, shared with the CLI (see module docstring).
    closed = contention.predict_closed(reports, hotspots)
    conflicts, no_paths, unparsed_by_item = closed["conflicts"], set(closed["no_paths"]), closed["unparsed"]

    pre = set(refused_reasons) | cancelled
    res = build_waves(sched_items, conflicts, max_parallel, refused=pre)
    refused_reasons.update(res["refused"])
    assign = assign_terminals(res["waves"], by_id, terminals or [], paths_by_item)
    waves, warnings = [], []
    for n, wave in enumerate(res["waves"], 1):
        row = []
        for iid in wave:
            it, a = by_id[iid], assign[iid]
            row.append({"id": iid, "title": it.get("title"), "kind": a["kind"], "points": estimate_of(it),
                        "priority": it.get("priority"), "terminal": a["terminal"], "persona": a["persona"]})
            if a.get("reason"):
                warnings.append({"id": iid, "code": a["reason"]["code"], "text": a["reason"]["text"]})
        waves.append({"wave": n, "items": row})
    for iid in sorted(i["id"] for w in waves for i in w["items"]):
        if iid in no_paths:
            warnings.append({"id": iid, "code": NO_PATHS, "text": "no file paths extracted from the plan doc; file set unknown, "
                             "serialised against every other item"})
        if unparsed_by_item.get(iid):
            warnings.append({"id": iid, "code": UNPARSED_PATHS,
                             "text": "unresolved path-like tokens: %s" % ", ".join(unparsed_by_item[iid])})
    if cfg_invalid:
        warnings.append({"id": release_id, "code": HOTSPOTS_CONFIG_INVALID, "text": cfg_invalid})
    refused = [{"id": i, "title": by_id[i].get("title"), "reasons": refused_reasons[i]} for i in sorted(refused_reasons)]
    return {"release": release_id, "maxParallel": max_parallel, "waves": waves, "refused": refused,
            "skipped": sorted(skipped, key=lambda s: s["id"]), "warnings": warnings,
            "cycles": res["cycles"], "contention": conflicts}


def format_plan(plan_):
    out = ["Release %s  maxParallel %s" % (plan_["release"], plan_["maxParallel"])]
    for w in plan_["waves"]:
        out.append("")
        out.append("Wave %d" % w["wave"])
        for r in w["items"]:
            tgt = ("%s (%s)" % (r["terminal"], r["persona"] or "-")) if r["terminal"] else "NO TERMINAL"
            est = ("%gh" % r["points"]) if r["points"] is not None else "-"
            out.append("  %s  %s  -> %s  %s  %s" % (r["id"], r["kind"], tgt, est, r["title"]))
    if not plan_["waves"]:
        out.extend(["", "No schedulable items."])
    if plan_["refused"]:
        out.extend(["", "Refused"])
        for r in plan_["refused"]:
            out.append("  %s  %s" % (r["id"], r["title"]))
            out.extend("    %s: %s" % (x["code"], x["text"]) for x in r["reasons"])
    if plan_["skipped"]:
        out.extend(["", "Skipped (already completed/cancelled)"])
        out.extend("  %s  %s" % (s["id"], s["status"]) for s in plan_["skipped"])
    if plan_["warnings"]:
        out.extend(["", "Warnings"])
        out.extend("  %s  %s: %s" % (x["id"], x["code"], x["text"]) for x in plan_["warnings"])
    if plan_["contention"]:
        out.extend(["", "Contention (serialized into different waves)"])
        for c in plan_["contention"]:
            out.append("  %s <> %s  %s%s" % (c["a"], c["b"], ", ".join(c.get("paths") or []) or "[%s]" % c.get("reason", "?"),
                                             ("  [hotspot: %s]" % ", ".join(c["hotspots"])) if c.get("hotspots") else ""))
    return "\n".join(out)


# ---------------------------------------------------------------- CLI
def _helpers_path():
    """KB_HELPERS, else the kanban-helpers.sh shipped beside this file (so a worktree/tap copy uses its OWN helpers,
    not a stale installed one that may predate kb-terminals), else ~/aiteamforge/kanban-helpers.sh."""
    env = os.environ.get("KB_HELPERS")
    if env:
        return env
    sibling = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "kanban-helpers.sh")
    return sibling if os.path.isfile(sibling) else os.path.expanduser("~/aiteamforge/kanban-helpers.sh")


def _terminals_from_helpers(kanban_dir, team):
    helpers = _helpers_path()
    cmd = 'source "$1" >/dev/null 2>&1; kb-terminals status --json%s' % (' --team "$2"' if team else "")
    try:
        p = subprocess.run(["zsh", "-c", cmd, "_", helpers] + ([team] if team else []),
                           capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise PlanError("kb-terminals status --json failed (helpers=%s): %s" % (helpers, exc))
    try:
        data = json.loads(p.stdout)
    except ValueError:
        raise PlanError("kb-terminals status --json rc=%s produced no JSON (helpers=%s; does it define kb-terminals? "
                        "set KB_HELPERS or pass --terminals-json): %s"
                        % (p.returncode, helpers, (p.stderr or "").strip()[-200:]))
    if p.returncode != 0 or not isinstance(data, dict) or not isinstance(data.get("terminals"), list):
        raise PlanError("kb-terminals status --json rc=%s, unusable output (helpers=%s)" % (p.returncode, helpers))
    return data["terminals"]


def main(argv=None):
    ap = argparse.ArgumentParser(prog="release_orchestrator.py", add_help=True)
    sub = ap.add_subparsers(dest="cmd")
    pp = sub.add_parser("plan", formatter_class=argparse.RawDescriptionHelpFormatter, epilog=(
        "Board config: releaseConfig.orchestration.hotspots = [list of extra hotspot paths or dir/ prefixes] "
        "(a bare list at releaseConfig.orchestration is also accepted); a wrong type warns HOTSPOTS_CONFIG_INVALID.\n"
        "Items whose plan doc yields no file paths are serialised and warn NO_PATHS (rule: orchestrator_contention.predict_closed)."))
    pp.add_argument("--release", required=True)
    pp.add_argument("--kanban-dir", required=True)
    pp.add_argument("--repo-root", help="repo root for sync-tap.sh hotspots and path anchoring "
                    "(default: the checkout containing this script)")
    pp.add_argument("--terminals-json")
    pp.add_argument("--max-parallel", type=int)
    pp.add_argument("--json", action="store_true")
    la = sub.add_parser("ledger-append", help="append one event to a run ledger (XACA-1546-001)")
    la.add_argument("--kanban-dir", required=True)
    la.add_argument("--run", required=True)
    la.add_argument("--kind", required=True)
    la.add_argument("--field", action="append", default=[], metavar="k=v")
    la.add_argument("--json-field", action="append", default=[], metavar="k=JSON")
    lh = sub.add_parser("ledger-hook", help="like ledger-append but keyed by an item: silent no-op unless the item "
                        "carries orchestration.runId (the kb-ask / kb-answer hook, XACA-1546-001)")
    lh.add_argument("--board", required=True)
    lh.add_argument("--item", required=True)
    lh.add_argument("--kind", required=True)
    lh.add_argument("--kanban-dir", help="default: the directory holding --board")
    lh.add_argument("--field", action="append", default=[], metavar="k=v")
    lh.add_argument("--json-field", action="append", default=[], metavar="k=JSON")
    try:
        args = ap.parse_args(argv)
    except SystemExit as exc:
        return 0 if exc.code in (0, None) else 2
    if args.cmd in ("ledger-append", "ledger-hook"):
        try:
            fields = _parse_fields(args.field, args.json_field)
            if args.cmd == "ledger-append":
                ledger_append(os.path.abspath(args.kanban_dir), args.run, args.kind, **fields)
            else:
                hook_append(args.board, args.item, args.kind, kanban_dir=args.kanban_dir, **fields)
        except (LedgerError, OSError) as exc:
            print("Error: %s" % exc, file=sys.stderr)
            return 1
        return 0
    if args.cmd != "plan":
        ap.print_usage(sys.stderr)
        return 2
    kdir = os.path.abspath(args.kanban_dir)
    try:
        if args.terminals_json:
            with open(args.terminals_json, encoding="utf-8") as fh:
                try:
                    terms = json.load(fh)
                except ValueError as exc:
                    raise PlanError("--terminals-json %s is not valid JSON: %s" % (args.terminals_json, exc))
            terms = terms.get("terminals") if isinstance(terms, dict) else terms
            if not isinstance(terms, list):
                raise PlanError("--terminals-json %s has no terminals[] list" % args.terminals_json)
        else:
            _b, rel = _load_board(kdir, args.release)
            terms = _terminals_from_helpers(kdir, rel.get("team"))
        result = plan(args.release, kdir, args.repo_root or DEFAULT_REPO_ROOT, terms, args.max_parallel)
    except (PlanError, OSError, ValueError, ImportError) as exc:
        # One voice with the kb-release shell wrapper: "Error: ..." plus a next step where there is one (XACA-1543-031).
        msg = str(exc)
        if "not found under" in msg:
            msg += " (see: kb-release list)"
        print("Error: %s" % msg, file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, indent=2) if args.json else format_plan(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
