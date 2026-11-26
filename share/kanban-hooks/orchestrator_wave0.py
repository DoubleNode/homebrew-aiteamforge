"""XACA-1873 Wave 0: planning-lane state for a Wave 0 run (summary `phase: "wave0"`). Stdlib only, py3.9-safe. No `gh`:
a planning lane has no PR. orchestrator_monitor branches here on the phase and reuses its own verdicts.

LANE STATES (derive_lane, first match wins):
  CANCELLED         the board item is completed / cancelled: nothing to plan
  DONE              the latest plan_lane event (after the latest DISPATCHED dispatch) is `done` AND the readiness re-check
                    finds no planning gap left
  INCOMPLETE        that `done`, but a gap is still open (a `done` is a claim; the board and plan doc are the evidence)
  FAILED            that event is `failed` (kb-orch-plan-done --failed "<reason>")
  QUEUED            not stamped for THIS run (item.orchestration.runId != run or phase != "wave0"): waits for a lane
  QUESTION_PENDING  an open kb-ask question
  DISPATCHING       stamped, no window row yet, within dispatch_seconds
  CRASHED           stamped, no event, and the worker is gone: no window row after dispatch_seconds, the pane is gone, or
                    it is back at a shell. It KEEPS its lane: the coordinator asks the user (re-dispatch or cancel)
  UNKNOWN           tmux unreadable or the window's lastActivity unreadable: never evidence of life
  STALLED           lastActivity older than stall_seconds
  RUNNING           otherwise
TERMINAL = DONE, INCOMPLETE, FAILED, CANCELLED: the lane is freed and the next QUEUED row (plan order) takes it
(SLOT_FREE). WAVE0_DONE fires when every lane is terminal. The summary stores ostate.STATES names, so INCOMPLETE is
recorded as FAILED with an "INCOMPLETE:" detail (summary_state); slots and verdicts see every terminal lane as DONE.

RE-DISPATCH (kb-dispatch --plan, via the `lane-info` CLI): allowed only when no live window exists (the shell checks tmux)
and the run's ledger holds no `done` plan_lane event for the item.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import orchestrator_state as ostate  # noqa: E402
import release_orchestrator as ro  # noqa: E402

TERMINAL = ("DONE", "INCOMPLETE", "FAILED", "CANCELLED")


def is_wave0(orch):
    return isinstance(orch, dict) and orch.get("phase") == ro.PHASE_WAVE0


def summary_state(state):
    return "FAILED" if state == "INCOMPLETE" else state


def base_state(state):
    """The vocabulary compute_slot_free / build_conditions understand: a terminal lane is DONE."""
    return "DONE" if state in TERMINAL else state


def _res(state, detail, since=None):
    return {"state": state, "detail": detail, "since": since, "signals": {}}


def lane_end(events, item):
    """The plan_lane event that ends the item's CURRENT attempt: the latest one, unless a DISPATCHED dispatch follows it
    (a re-dispatch after `failed` starts a new attempt). None while the attempt is open."""
    end = None
    for ev in events or []:
        if ev.get("item") != item:
            continue
        if ev.get("kind") == ro.KIND_PLAN_LANE:
            end = ev
        elif ev.get("kind") == ro.KIND_DISPATCH and (ev.get("dispatch") or {}).get("outcome") == "DISPATCHED":
            end = None
    return end


def lane_info(events, item):
    """-> {"done": the run holds a `done` event for item, "ended": [items whose current attempt has ended]}."""
    ids = sorted({ev.get("item") for ev in events or [] if isinstance(ev.get("item"), str)})
    return {"done": any(ev.get("kind") == ro.KIND_PLAN_LANE and ev.get("item") == item and ev.get("action") == "done"
                        for ev in events or []),
            "ended": [i for i in ids if lane_end(events, i) is not None]}


def derive_lane(item, run, end, window_row, pane, gaps_now, now, thresholds):
    """Pure. gaps_now() -> the planning gaps still open (called only for a `done`). See LANE STATES."""
    th = ostate._thresholds(thresholds)
    if not isinstance(item, dict):
        return _res("UNKNOWN", "item missing from the board")
    status = ostate.resolve_item_status(item)
    if status in ("completed", "cancelled"):
        return _res("CANCELLED", "board status %s: nothing to plan" % status)
    if end is not None:
        if end.get("action") == "done":
            gaps = list(gaps_now() or [])
            if gaps:
                return _res("INCOMPLETE", "INCOMPLETE: planner reported done but gaps remain: %s" % ", ".join(gaps), end.get("ts"))
            return _res("DONE", "planned: no planning gap left", end.get("ts"))
        return _res("FAILED", "planner failed: %s" % (end.get("reason") or "no reason given"), end.get("ts"))
    o = item.get("orchestration") if isinstance(item.get("orchestration"), dict) else {}
    if o.get("runId") != run or o.get("phase") != ro.PHASE_WAVE0:
        return _res("QUEUED", "not dispatched in this Wave 0 run")
    if ostate._question_open(item):
        return _res("QUESTION_PENDING", "open question awaiting an answer", (item.get("pendingQuestion") or {}).get("askedAt"))
    if not isinstance(window_row, dict):
        r = ostate._dispatch_age(o, now, th, {}, "planning lane dispatched, no window row")
        if r["state"] == "STALLED":
            return _res("CRASHED", "%s; no plan_lane event" % r["detail"], r["since"])
        return r
    if pane == ostate.PANE_GONE:
        return _res("CRASHED", "planner pane is gone with no kb-orch-plan-done")
    if pane is None:
        return _res("UNKNOWN", "pane command unreadable; not evidence of life")
    if ostate._norm_command(pane) in ostate.SHELL_COMMANDS:
        return _res("CRASHED", "planner pane is back at a shell with no kb-orch-plan-done")
    t = ostate.parse_ts(window_row.get("lastActivity"))
    if t is None:
        return _res("UNKNOWN", "lastActivity missing or unparseable; not treated as fresh")
    age = int((ostate._now(now) - t).total_seconds())
    if age > th["stall_seconds"]:
        return _res("STALLED", "no activity for %ds (limit %ds)" % (age, th["stall_seconds"]), window_row.get("lastActivity"))
    return _res("RUNNING", "planner alive, last activity %ds ago" % max(0, age))


def remaining_gaps(item, board, kanban_dir, repo_root=None, contention=None):
    """The planning gaps still open: check_readiness gap codes, else (a plan doc exists) NO_PATHS / UNPARSED_PATHS from its
    `## Files to Modify`. Hard codes are not gaps (re-planning refuses them)."""
    if contention is None:
        import orchestrator_contention as contention
    codes = [r["code"] for r in ro.check_readiness(item, [], board, kanban_dir, repo_root, contention.find_plan_doc)]
    gaps = [c for c in codes if c in ro.PLANNING_GAP_CODES]
    if gaps or ro.NO_PLAN_DOC in codes:
        return gaps
    rep = contention.extract_paths_report(_read(contention.find_plan_doc(item, kanban_dir, repo_root)),
                                          item.get("description"), repo_root=repo_root)
    return ([ro.NO_PATHS] if not rep.get("paths") else []) + ([ro.UNPARSED_PATHS] if rep.get("unparsed") else [])


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except (OSError, TypeError):
        return ""


def derive_states(orch, run, g, events, gaps_fn):
    """-> {id: lane result} for every tracked item. g = orchestrator_monitor.gather output; gaps_fn(id) -> open gaps."""
    by_id = g["items"]
    return {iid: derive_lane(by_id.get(iid), run, lane_end(events, iid), g["windows"].get(iid), g["panes"].get(iid),
                             lambda iid=iid: gaps_fn(iid), g["now"], g["thresholds"])
            for iid in sorted(orch.get("items") or {})}


def all_terminal(states):
    return bool(states) and all(r["state"] in TERMINAL for r in states.values())


def plan_summaries(board, ids, kanban_dir, repo_root=None, contention=None):
    """For the approval view: per item {id, title, points, subitems, planDoc, files, openDecisions}."""
    if contention is None:
        import orchestrator_contention as contention
    by_id = {i.get("id"): i for i in board.get("backlog") or [] if isinstance(i, dict)}
    out = []
    for iid in ids:
        it = by_id.get(iid) or {"id": iid}
        subs = [s for s in it.get("subitems") or [] if isinstance(s, dict) and s.get("status") != "cancelled"]
        doc = contention.find_plan_doc(it, kanban_dir, repo_root)
        rep = contention.extract_paths_report(_read(doc), it.get("description"), repo_root=repo_root) if doc else {}
        out.append({"id": iid, "title": it.get("title"), "points": it.get("points"), "subitems": len(subs), "planDoc": doc,
                    "files": list(rep.get("paths") or []),
                    "openDecisions": [s.get("title") for s in subs if "[USER DECISION]" in str(s.get("title"))
                                      and s.get("status") not in ("completed", "done")]})
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(prog="orchestrator_wave0.py")
    sub = ap.add_subparsers(dest="cmd")
    li = sub.add_parser("lane-info", help="kb-dispatch --plan: {done, ended} from the run ledger (JSON)")
    li.add_argument("--kanban-dir", required=True)
    li.add_argument("--run", required=True)
    li.add_argument("--item", required=True)
    args = ap.parse_args(argv)
    if args.cmd != "lane-info":
        ap.print_usage(sys.stderr)
        return 2
    try:
        events = ro.ledger_read(os.path.abspath(args.kanban_dir), args.run)
    except ro.LedgerError as exc:
        print("Error: %s" % exc, file=sys.stderr)
        return 1
    print(json.dumps(lane_info(events, args.item), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
