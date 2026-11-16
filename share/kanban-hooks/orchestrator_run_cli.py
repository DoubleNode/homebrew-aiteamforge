"""
orchestrator_run_cli.py -- the shell-out boundary for coordinator mode in `kb-run <REL-ID>` (XACA-1548, EPIC-0072 T7).

Stdlib only, py3.9-safe. dev-team-only (kanban-hooks/*.py is not mirrored to the tap): the bash side checks that this file
exists before it offers coordinator mode, so a tap install degrades to today's single-session flow.

Thin on purpose. Every rule lives in release_orchestrator.py (planner, ledger, summary writer); this module only adds the
four things the shell cannot do with jq alone:

  start    mint a run (release_orchestrator.start_run: run_start event + summary under the board lock; a second start on a
           release that already has an open run is REFUSED there) and merge the resolved settings into the summary:
             release.orchestration.models = {coordinator: {model, source}, worker: {model, source}}
             release.orchestration.maxParallelSource, release.orchestration.excluded
           Prints the run id on stdout.
  close    idempotent hand-off close. An open run whose tracked items are ALL DONE/CANCELLED is closed (run_end, closedAt);
           an already closed run is a no-op; an open run with unfinished items is REFUSED (rc 3). activeRunId stays on the
           release as the closed run's record (close_run's own contract); "closed" is what every reader (kb-dispatch, the
           monitor, kb-run's active-run check) treats as "no active run".
  exclude  apply `--exclude <ID>` to a plan-run --json document. FAIL CLOSED: an id that is not scheduled in the plan is an
           error (a typo must not silently exclude nothing), and so is excluding an item that a non-excluded scheduled item
           is blockedBy (its dependant would wait on a ticket nobody will run).
  render   the human plan text (release_orchestrator.format_plan) plus the exclusion list.

Exit: 0 ok | 1 refused or failed (message on stderr) | 2 usage | 3 close refused (items unfinished).
"""
from __future__ import annotations

import argparse
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import release_orchestrator as ro  # noqa: E402

DONE_STATES = ("DONE", "CANCELLED")


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        raise ro.LedgerError("cannot read %s: %s" % (path, exc))


def _release_orch(board_file, release_id):
    """-> the release's orchestration dict ({} when none). Read-only."""
    board = _read_json(board_file)
    for rel in board.get("releases") or []:
        if isinstance(rel, dict) and rel.get("id") == release_id:
            orch = rel.get("orchestration")
            return orch if isinstance(orch, dict) else {}
    raise ro.LedgerError("release %s not found in %s" % (release_id, board_file))


def _scheduled_ids(plan_):
    return [it["id"] for w in plan_.get("waves") or [] for it in w.get("items") or [] if isinstance(it, dict) and "id" in it]


def apply_exclusions(plan_, excluded, board):
    """plan-run document minus `excluded`. Raises ro.LedgerError (fail closed) on an unscheduled id or an excluded blocker."""
    excluded = list(dict.fromkeys(excluded))
    scheduled = _scheduled_ids(plan_)
    unknown = [e for e in excluded if e not in scheduled]
    if unknown:
        raise ro.LedgerError("--exclude %s: not scheduled in this plan (refused, skipped or not in the release); "
                             "scheduled: %s" % (", ".join(unknown), ", ".join(scheduled) or "none"))
    blocked = {}
    for it in board.get("backlog") or []:
        if isinstance(it, dict) and it.get("id") in scheduled and it["id"] not in excluded:
            for b in it.get("blockedBy") or []:
                if b in excluded:
                    blocked.setdefault(b, []).append(it["id"])
    if blocked:
        raise ro.LedgerError("; ".join("cannot exclude %s: %s is blockedBy it (exclude those too, or leave it in)"
                                       % (b, ", ".join(sorted(v))) for b, v in sorted(blocked.items())))
    out = dict(plan_)
    waves = []
    for w in plan_.get("waves") or []:
        items = [it for it in w.get("items") or [] if it.get("id") not in excluded]
        if items:
            waves.append({"wave": len(waves) + 1, "items": items})
    out["waves"] = waves
    if isinstance(plan_.get("contention"), list):
        out["contention"] = [c for c in plan_["contention"]
                             if not (isinstance(c, dict) and (c.get("a") in excluded or c.get("b") in excluded))]
    out["warnings"] = [x for x in plan_.get("warnings") or [] if x.get("id") not in excluded]
    out["excluded"] = excluded
    return out


def cmd_start(a):
    plan_ = _read_json(a.plan_file)
    if not isinstance(plan_, dict) or not _scheduled_ids(plan_):
        raise ro.LedgerError("the plan has no scheduled items: nothing to start")
    meta = json.loads(a.meta_json) if a.meta_json else {}
    if not isinstance(meta, dict):
        raise ro.LedgerError("--meta-json must be a JSON object")
    kdir = os.path.abspath(a.kanban_dir)
    run_id = ro.start_run(a.board, kdir, a.release, plan_, a.coordinator, a.max_parallel)
    meta = dict(meta)
    # ALWAYS written: a re-run after a closed run must not inherit the previous run's exclusions (start_run keeps the old
    # summary keys), or the coordinator prompt would name items "excluded by the lead" that this run did not exclude.
    meta["excluded"] = list(plan_.get("excluded") or [])

    def _merge(orch):
        if orch.get("activeRunId") != run_id:
            raise ro.LedgerError("run %s is not the active run of %s" % (run_id, a.release))
        orch.update(meta)

    if meta:
        ro.write_summary(a.board, a.release, _merge)
    print(run_id)
    return 0


def cmd_close(a):
    orch = _release_orch(a.board, a.release)
    run_id = orch.get("activeRunId")
    if not run_id:
        print("no orchestrated run recorded for %s: nothing to close" % a.release)
        return 0
    if orch.get("closedAt"):
        print("run %s already closed at %s" % (run_id, orch["closedAt"]))
        return 0
    items = orch.get("items")
    if not isinstance(items, dict) or not items:
        # fail closed: a missing or malformed items record is NOT evidence that every item is done
        print("run %s has no readable items record; not closing it as complete" % run_id, file=sys.stderr)
        return 3
    open_ = sorted(i for i, v in items.items() if not (isinstance(v, dict) and v.get("state") in DONE_STATES))
    if open_:
        print("run %s still has unfinished item(s): %s; not closing it" % (run_id, ", ".join(open_)), file=sys.stderr)
        return 3
    ro.close_run(a.board, os.path.abspath(a.kanban_dir), a.release, run_id, outcome="complete",
                 detail="coordinator hand-off: every tracked item is done")
    print("run %s closed" % run_id)
    return 0


def cmd_exclude(a):
    plan_ = _read_json(a.plan_file)
    board = _read_json(a.board)
    print(json.dumps(apply_exclusions(plan_, a.exclude, board), sort_keys=True))
    return 0


def cmd_render(a):
    plan_ = _read_json(a.plan_file)
    text = ro.format_plan(plan_)
    if plan_.get("excluded"):
        text += "\n\nExcluded by you (not dispatched): %s" % ", ".join(plan_["excluded"])
    print(text)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="orchestrator_run_cli.py")
    sub = ap.add_subparsers(dest="cmd")
    s = sub.add_parser("start")
    s.add_argument("--board", required=True)
    s.add_argument("--kanban-dir", required=True)
    s.add_argument("--release", required=True)
    s.add_argument("--plan-file", required=True)
    s.add_argument("--coordinator", required=True)
    s.add_argument("--max-parallel", required=True, type=int)
    s.add_argument("--meta-json")
    c = sub.add_parser("close")
    c.add_argument("--board", required=True)
    c.add_argument("--kanban-dir", required=True)
    c.add_argument("--release", required=True)
    e = sub.add_parser("exclude")
    e.add_argument("--plan-file", required=True)
    e.add_argument("--board", required=True)
    e.add_argument("--exclude", action="append", default=[], required=True)
    r = sub.add_parser("render")
    r.add_argument("--plan-file", required=True)
    try:
        args = ap.parse_args(argv)
    except SystemExit as exc:
        return 0 if exc.code in (0, None) else 2
    fn = {"start": cmd_start, "close": cmd_close, "exclude": cmd_exclude, "render": cmd_render}.get(args.cmd)
    if fn is None:
        ap.print_usage(sys.stderr)
        return 2
    try:
        return fn(args)
    except (ro.LedgerError, OSError, ValueError, KeyError) as exc:
        print("Error: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
