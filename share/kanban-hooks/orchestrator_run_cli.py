"""
orchestrator_run_cli.py -- the shell-out boundary for coordinator mode in `kb-run <REL-ID>` (XACA-1548, EPIC-0072 T7).

Stdlib only, py3.9-safe. kanban-hooks/*.py is mirrored to the tap by sync-tap.sh's glob. The bash side still checks that
this file exists before it offers coordinator mode, so an install without it degrades to today's single-session flow.

Thin on purpose. Every rule lives in release_orchestrator.py (planner, ledger, summary writer); this module only adds the
four things the shell cannot do with jq alone:

  start    mint a run (release_orchestrator.start_run: run_start event + summary under the board lock; a second start on a
           release that already has an open run is REFUSED there) and merge the resolved settings into the summary:
             release.orchestration.models = {coordinator: {model, source}, worker: {model, source}}
             release.orchestration.maxParallelSource, release.orchestration.excluded
           Prints the run id on stdout. XACA-1873: --phase wave0 starts a Wave 0 (planning) run from the plan's `wave0`
           rows instead (release_orchestrator.start_run phase="wave0"); refused when the plan has none.
  close    idempotent hand-off close. An open run whose tracked items are ALL DONE/CANCELLED is closed (run_end, closedAt);
           an already closed run is a no-op; an open run with unfinished items is REFUSED (rc 3). activeRunId stays on the
           release as the closed run's record (close_run's own contract); "closed" is what every reader (kb-dispatch, the
           monitor, kb-run's active-run check) treats as "no active run".
           XACA-1914 (user decision 1a): BEFORE that check, close reconciles from the BOARD: every tracked item whose board
           status (orchestrator_state.resolve_item_status) is completed / cancelled but whose summary state is not DONE /
           CANCELLED is recorded DONE / CANCELLED through release_orchestrator.record_state (ledger `state` event + summary
           + lane mirror, under the board lock). Board-only: no tmux, no gh, no verdicts, so close stays offline and
           deterministic. Items the board does not show as terminal keep the rc 3 refusal. (R02: a summary still saying
           CRASHED / QUEUED for two completed items refused the hand-off until a manual `watch --once`.)
  exclude  apply `--exclude <ID>` to a plan-run --json document. FAIL CLOSED: an id that is not scheduled in the plan is an
           error (a typo must not silently exclude nothing), and so is excluding an item that a non-excluded scheduled item
           is blockedBy (its dependant would wait on a ticket nobody will run).
  render   the human plan text (release_orchestrator.format_plan) plus the exclusion list.
  cancel   (XACA-1882) abandon a RELEASE run: close the open run with outcome "cancelled" even with unfinished or
           never-dispatched items. The release and its items are untouched. Idempotent; refuses a batch (batch-cancel).

XACA-1834 -- ad-hoc batches (`kb-run A,B,...`). A batch is an ephemeral release record (kind "batch", REL-BATCH-<UTC
yyyymmddThhmmss>, stage DEV, no branch, `batchItems` = the ids) so the whole planner / run / monitor / resume stack is
reused unchanged. Its items keep their real releaseAssignment (membership is release_orchestrator.is_member).

  batch-readiness  the SAME per-item readiness rules a release uses (release_orchestrator.check_readiness, the batch ids
                   standing in for the release's), plus NOT_FOUND. Read-only. rc 0 every item ready | 1 any refused (one
                   line per refused item, or --json). Decision Q2 (user, 2026-11-16): there is no --allow-unplanned.
  batch-mint       append the batch record under the board lock; prints its id. Refuses an item that an OPEN batch
                   (status in_progress) already holds, and an id collision.
  batch-close      set an open batch's status (completed | cancelled) and closedAt. Idempotent; refuses a non-batch
                   release, and `completed` while the batch has an open run.

XACA-1853 -- plan-hash approval (`kb-run <REL|A,B> --plan-only` / `--approve-plan <hash>`), so an agent can start a run
without a tty while a human still approves the exact plan:

  plan-hash   print the stable hash of a plan document plus the resolved settings (plan_hash below). Read-only.
  batch-plan  the plan-run --json document for a batch that is NOT minted yet: the batch record exists only in memory, and
              release_orchestrator.plan runs the same rules it runs after the mint. Read-only.

Exit: 0 ok | 1 refused or failed (message on stderr) | 2 usage | 3 close refused (items unfinished).
"""
from __future__ import annotations

import argparse
import hashlib
from types import SimpleNamespace
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import release_orchestrator as ro  # noqa: E402


# XACA-1873 (PR 3): after a Wave 0 run closes, the release summary still holds it (phase "wave0" + closedAt) until the
# execution run is minted (start_run then drops `phase` and records `wave0RunId`). That closed record is the signal that
# Wave 0 already ran for this plan: the re-plan does not run it again, and the approval covers what it generated.
def wave0_done(board, release_id):
    """{runId, items: [ids]} of the release's CLOSED Wave 0 run that no execution run has consumed yet, else None."""
    rel = ro._find_release_in(board, release_id) if isinstance(board, dict) else None
    orch = rel.get("orchestration") if isinstance(rel, dict) else None
    if not (isinstance(orch, dict) and orch.get("phase") == ro.PHASE_WAVE0 and orch.get("closedAt")
            and orch.get("activeRunId")):
        return None
    # XACA-1873-034: a Wave 0 run started while an earlier one was closed (tickets added to the release later) carries the
    # earlier run's items (wave0PriorItems), so the approval still covers every plan Wave 0 generated for this release.
    return {"runId": orch["activeRunId"], "items": sorted(ro.wave0_planned(orch))}


def plan_digests(board, ids, kanban_dir, repo_root=None):
    """{id: sha256(plan doc bytes + subitem titles + points)} for the tickets Wave 0 planned. It goes into the approval
    hash, so editing a generated plan after `--plan-only` makes `--approve-plan` refuse (rc 4). A missing doc hashes as
    empty: that is still a fact the human approved."""
    import orchestrator_contention as contention
    by_id = {i.get("id"): i for i in board.get("backlog") or [] if isinstance(i, dict)}
    out = {}
    for iid in ids:
        it = by_id.get(iid) or {"id": iid}
        doc = contention.find_plan_doc(it, kanban_dir, repo_root)
        h = hashlib.sha256()
        try:
            with open(doc, "rb") as fh:
                h.update(fh.read())
        except (OSError, TypeError):
            pass
        subs = [s.get("title") for s in it.get("subitems") or [] if isinstance(s, dict) and s.get("status") != "cancelled"]
        h.update(json.dumps({"subitems": subs, "points": it.get("points")}, sort_keys=True).encode("utf-8"))
        out[iid] = h.hexdigest()
    return out


def still_refused(plan_, done):
    """The re-plan's refused rows for tickets the Wave 0 run planned (their gaps outlived Wave 0)."""
    ids = set((done or {}).get("items") or [])
    return [r for r in plan_.get("refused") or [] if isinstance(r, dict) and r.get("id") in ids]


def _kdir(a):
    return os.path.abspath(getattr(a, "kanban_dir", None) or os.path.dirname(os.path.abspath(a.board)))

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
    wave0 = getattr(a, "phase", None) == ro.PHASE_WAVE0
    if not isinstance(plan_, dict) or not (plan_.get("wave0") if wave0 else _scheduled_ids(plan_)):
        raise ro.LedgerError("the plan has no %s: nothing to start" % ("wave0 rows" if wave0 else "scheduled items"))
    meta = json.loads(a.meta_json) if a.meta_json else {}
    if not isinstance(meta, dict):
        raise ro.LedgerError("--meta-json must be a JSON object")
    kdir = os.path.abspath(a.kanban_dir)
    done = wave0_done(_read_json(a.board), a.release)
    prior = done["items"] if (wave0 and done) else []
    done = None if wave0 else done
    run_id = ro.start_run(a.board, kdir, a.release, plan_, a.coordinator, a.max_parallel,
                          phase=ro.PHASE_WAVE0 if wave0 else None, wave0_run_id=done and done["runId"])
    meta = dict(meta)
    # XACA-1873: always written (start_run keeps old summary keys), like `excluded`: {} unless Wave 0 planned this run.
    meta["wave0"] = ({"runId": done["runId"], "stillRefused": [r["id"] for r in still_refused(plan_, done)]}
                     if done else {})
    # ALWAYS written: a re-run after a closed run must not inherit the previous run's exclusions (start_run keeps the old
    # summary keys), or the coordinator prompt would name items "excluded by the lead" that this run did not exclude.
    meta["excluded"] = list(plan_.get("excluded") or [])
    # XACA-1873-034: ALWAYS written for the same reason: the tickets a closed earlier Wave 0 run planned ([] otherwise).
    meta["wave0PriorItems"] = prior

    def _merge(orch):
        if orch.get("activeRunId") != run_id:
            raise ro.LedgerError("run %s is not the active run of %s" % (run_id, a.release))
        # XACA-1853: the approval record belongs to THIS run. A terminal-approved re-run must not inherit a previous
        # run's approvedVia/planHash (start_run keeps old summary keys), so drop them unless this meta sets them.
        for k in ("approvedVia", "planHash"):
            orch.pop(k, None)
        orch.update(meta)

    if meta:
        ro.write_summary(a.board, a.release, _merge)
    print(run_id)
    return 0


_BOARD_TERMINAL = {"completed": "DONE", "cancelled": "CANCELLED"}


def _reconcile_board_terminal(a, run_id, items):
    """XACA-1914: record DONE / CANCELLED for every tracked, not-yet-terminal item that the board shows completed /
    cancelled. -> the list of (item, from, to) recorded. An item missing from the backlog is left alone (fail closed)."""
    import orchestrator_state as ostate
    backlog = {i.get("id"): i for i in _read_json(a.board).get("backlog") or [] if isinstance(i, dict)}
    done = []
    for iid, row in sorted(items.items()):
        prev = row.get("state") if isinstance(row, dict) else None
        it = backlog.get(iid)
        to = _BOARD_TERMINAL.get(ostate.resolve_item_status(it)) if it is not None else None
        if to is None or prev in DONE_STATES:
            continue
        ro.record_state(a.board, os.path.abspath(a.kanban_dir), a.release, run_id, iid, to,
                        detail="hand-off reconcile: board status %s" % ("completed" if to == "DONE" else "cancelled"))
        print("reconciled %s: %s -> %s (board status)" % (iid, prev, to))
        done.append((iid, prev, to))
    return done


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
    if _reconcile_board_terminal(a, run_id, items):
        items = _release_orch(a.board, a.release).get("items") or {}
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
    done = wave0_done(_read_json(a.board), a.release) if a.board and a.release else None
    text = ro.format_plan(plan_, still_refused(plan_, done))
    if done:
        import orchestrator_wave0 as w0
        text += "\n\nGenerated by Wave 0 (%s): review these plans before approving" % done["runId"]
        for s in w0.plan_summaries(_read_json(a.board), done["items"], _kdir(a)):
            text += "\n  %s  %sh  %d subitem(s)  %s\n    plan doc: %s\n    files: %s" % (
                s["id"], s["points"] if s["points"] is not None else "-", s["subitems"], s["title"],
                s["planDoc"] or "MISSING", ", ".join(s["files"]) or "none parsed")
            if s["openDecisions"]:
                text += "\n    OPEN USER DECISIONS: %s" % "; ".join(s["openDecisions"])
    if plan_.get("excluded"):
        text += "\n\nExcluded by you (not dispatched): %s" % ", ".join(plan_["excluded"])
    print(text)
    return 0


PLAN_HASH_VERSION = 1
PLAN_HASH_LEN = 16       # hex chars shown to (and typed back by) a human; an approval check, not a security boundary
UNMINTED_BATCH_ID = "REL-BATCH-(unminted)"


def canonical_plan(plan_, target, coordinator_model, coordinator_effort, worker_model, digests=None):
    """The plan facts a human approves, as a canonical dict (XACA-1853). Only what changes WHAT runs is in it: the target
    (a release id, or a batch's sorted item ids: a batch's REL-BATCH-<UTC> id does not exist until the mint), max
    parallel, the waves (ids, sorted within a wave: order inside a wave is not a decision), every scheduled id, the
    refused ids, the exclusions and the three resolved model/effort settings. Terminal and persona picks are left out:
    they follow terminal availability minute to minute, and kb-dispatch re-checks them at dispatch time anyway."""
    if not isinstance(plan_, dict):
        raise ro.LedgerError("the plan document is not a JSON object")

    def _list(v, what):
        if v is None:
            return []
        if not isinstance(v, list):
            raise ro.LedgerError("malformed plan document: %s is not a list" % what)
        return v

    def _ids(entries, what):
        out = []
        for e in _list(entries, what):
            if not (isinstance(e, dict) and "id" in e):
                continue
            if not isinstance(e["id"], str):
                raise ro.LedgerError("malformed plan document: a %s id is not a string" % what)
            out.append(e["id"])
        return sorted(out)

    waves = []
    for w in _list(plan_.get("waves"), "waves"):
        if not isinstance(w, dict):
            raise ro.LedgerError("malformed plan document: a wave is not an object")
        waves.append(_ids(w.get("items"), "wave item"))
    refused = _ids(plan_.get("refused"), "refused")
    excluded = _list(plan_.get("excluded"), "excluded")
    if not all(isinstance(x, str) for x in excluded):
        raise ro.LedgerError("malformed plan document: an excluded id is not a string")
    out = {"v": PLAN_HASH_VERSION, "target": target, "maxParallel": plan_.get("maxParallel"),
           "waves": waves, "items": sorted(i for w in waves for i in w), "refused": refused,
           "excluded": sorted(excluded),
           "models": {"coordinator": coordinator_model, "coordinatorEffort": coordinator_effort, "worker": worker_model}}
    # XACA-1873: Wave 0 membership (review advisory -020: plans differing only in their Wave 0 tickets must not collide)
    # and, after Wave 0, a digest of every generated plan. Added only when non-empty: a plan without them hashes as before.
    for k in ("wave0", "waitingOnWave0"):
        ids = _ids(plan_.get(k), k)
        if ids:
            out[k] = ids
    if digests:
        out["planDigests"] = dict(sorted(digests.items()))
    return out


def plan_hash(canonical):
    """sha256 of the canonical dict as sorted, separator-free JSON, cut to PLAN_HASH_LEN hex chars."""
    blob = json.dumps(canonical, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()[:PLAN_HASH_LEN]


def _hash_target(a):
    if a.batch_items:
        return {"kind": "batch", "items": sorted(_batch_ids(a.batch_items))}
    if not (a.board and a.release):
        raise ro.LedgerError("plan-hash needs --batch-items, or --board and --release")
    rel = ro._find_release_in(_read_json(a.board), a.release)
    if ro.is_batch(rel):
        return {"kind": "batch", "items": sorted(b for b in rel.get("batchItems") or [] if isinstance(b, str))}
    return {"kind": "release", "id": a.release}


def cmd_plan_hash(a):
    digests = None
    if a.board and a.release and not a.batch_items:
        board = _read_json(a.board)
        done = wave0_done(board, a.release)
        digests = plan_digests(board, done["items"], _kdir(a)) if done else None
    canon = canonical_plan(_read_json(a.plan_file), _hash_target(a), a.coordinator_model, a.coordinator_effort,
                           a.worker_model, digests)
    print(json.dumps(canon, sort_keys=True) if a.canonical else plan_hash(canon))
    return 0


def cmd_batch_plan(a):
    ids = _batch_ids(a.items)
    board = _read_json(a.board)
    rel = {"id": UNMINTED_BATCH_ID, "kind": ro.BATCH_KIND, "team": a.team, "stage": "DEV", "status": BATCH_OPEN,
           "batchItems": ids}
    kdir = os.path.abspath(a.kanban_dir)
    if a.terminals_json:
        terms = _read_json(a.terminals_json)
        terms = terms.get("terminals") if isinstance(terms, dict) else terms
        if not isinstance(terms, list):
            raise ro.LedgerError("--terminals-json %s has no terminals[] list" % a.terminals_json)
    else:
        terms = ro._terminals_from_helpers(kdir, a.team)
    result = ro.plan(UNMINTED_BATCH_ID, kdir, a.repo_root or ro.DEFAULT_REPO_ROOT, terms, a.max_parallel,
                     loaded=(board, rel))
    print(json.dumps(result, sort_keys=True, indent=2))
    return 0


NOT_FOUND = "NOT_FOUND"
NOT_TODO = "NOT_TODO"          # kb-dispatch dispatches only a todo item (ITEM_NOT_TODO): refuse before the mint instead
HELD_BY_RUN = "HELD_BY_RUN"    # tracked by another release's (or batch's) OPEN run: two coordinators must never share it
BATCH_OPEN = "in_progress"
BATCH_CLOSED = ("completed", "cancelled")


def _batch_ids(text):
    ids = [i.strip() for i in (text or "").split(",")]
    if not ids or any(not i for i in ids):
        raise ro.LedgerError("--items must be a comma-separated list of item ids with no empty element")
    return list(dict.fromkeys(ids))


def _open_run_holders(board):
    """{item id: "<release> run <RUN>"} for every item tracked by an OPEN run (activeRunId set, no closedAt) of any
    release or batch on the board."""
    held = {}
    for r in board.get("releases") or []:
        if not isinstance(r, dict):
            continue
        o = r.get("orchestration")
        if not isinstance(o, dict) or not o.get("activeRunId") or o.get("closedAt"):
            continue
        items = o.get("items")
        for iid in (items.keys() if isinstance(items, dict) else []):
            held.setdefault(iid, "%s run %s" % (r.get("id"), o["activeRunId"]))
    return held


def batch_readiness(board, ids, kanban_dir, repo_root=None, find_plan_doc=None):
    """-> [{id, title, reasons:[{code,text}]}] for every refused id ([] = all ready). ALREADY_TERMINAL is a refusal here:
    a batch names its tickets explicitly, so one with nothing to run is a typo or a stale list, not something to skip.
    NOT_TODO (resolved status is not todo: kb-dispatch would refuse it with ITEM_NOT_TODO) and HELD_BY_RUN (another
    open run tracks it) are refused here too, so a batch never mints and then fails at dispatch (XACA-1834-010).
    XACA-1863: an in_progress item nothing is working (check_readiness STALE_IN_PROGRESS) gets that code, with its demote
    remedy, INSTEAD of NOT_TODO; an in_progress item that is really being worked keeps NOT_TODO."""
    if find_plan_doc is None:
        import orchestrator_contention as contention
        find_plan_doc = contention.find_plan_doc
    import orchestrator_state
    by_id = {i.get("id"): i for i in board.get("backlog") or [] if isinstance(i, dict)}
    holders = _open_run_holders(board)
    out = []
    for iid in ids:
        it = by_id.get(iid)
        if it is None:
            out.append({"id": iid, "title": None, "reasons": [{"code": NOT_FOUND, "text": "not on this board (a batch runs on the caller's board only)"}]})
            continue
        why = ro.check_readiness(it, ids, board, kanban_dir, repo_root, find_plan_doc)
        for w in why:   # XACA-1863: a batch has no format_plan, so the stale refusal carries its own remedy
            if w.get("code") == ro.STALE_IN_PROGRESS:
                w["text"] = "%s; remedy: %s" % (w["text"], w.get("remedy") or ro.demote_remedy(iid))
        stale = any(w.get("code") == ro.STALE_IN_PROGRESS for w in why)
        if not any(w.get("code") == ro.ALREADY_TERMINAL for w in why):
            st = orchestrator_state.resolve_item_status(it)
            if st != "todo" and not stale:    # STALE_IN_PROGRESS is the specific (fixable) form of NOT_TODO
                why.append({"code": NOT_TODO, "text": "status is %s; only a todo item is dispatched" % st})
            if iid in holders:
                why.append({"code": HELD_BY_RUN, "text": "tracked by the open %s" % holders[iid]})
        if why:
            out.append({"id": iid, "title": it.get("title"), "reasons": why})
    return out


def cmd_batch_readiness(a):
    board = _read_json(a.board)
    ids = _batch_ids(a.items)
    refused = batch_readiness(board, ids, os.path.abspath(a.kanban_dir), a.repo_root or ro.DEFAULT_REPO_ROOT)
    if a.json:
        print(json.dumps({"items": ids, "refused": refused}, sort_keys=True))
    else:
        for r in refused:
            print("%s: %s" % (r["id"], "; ".join("%s (%s)" % (x["code"], x["text"]) for x in r["reasons"])))
    return 1 if refused else 0


def mint_batch_id(now=None):
    return "REL-BATCH-%s" % ro._utc(now).strftime("%Y%m%dT%H%M%S")


def _locked_update(board_file, fn, what):
    """Run fn(board) under kanban_utils.update_board_safely. fn returns the board to write, or None to skip the write;
    anything it raises is re-raised here (update_board_safely itself only returns False)."""
    import kanban_utils
    box = {}

    def _upd(board):
        try:
            return fn(board)
        except Exception as exc:  # noqa: BLE001 -- re-raised below; must not be swallowed by update_board_safely
            box["exc"] = exc
            return None

    ok = kanban_utils.update_board_safely(board_file, _upd)
    if "exc" in box:
        raise box["exc"]
    return ok


def cmd_batch_mint(a, now=None):
    ids = _batch_ids(a.items)
    if len(ids) < 2:
        raise ro.LedgerError("a batch needs at least two distinct items (got %s)" % ", ".join(ids))
    rel_id = mint_batch_id(now)
    if not ro.run_id_valid(ro.mint_run_id(rel_id, now)):
        raise ro.LedgerError("minted batch id %s would not round-trip through the run-id grammar" % rel_id)
    wrote = {}

    def _mint(board):
        rels = board.setdefault("releases", [])
        held = {}
        for r in rels:
            if ro.is_batch(r) and r.get("status") == BATCH_OPEN:
                for i in r.get("batchItems") or []:
                    if i in ids:
                        held.setdefault(i, r.get("id"))
        if held:
            raise ro.LedgerError("already in an open batch: %s (finish it with `kb-release handoff <id>`, or abandon it "
                                 "with `kb-release handoff <id> --cancel`)"
                                 % ", ".join("%s (%s)" % (k, v) for k, v in sorted(held.items())))
        if any(isinstance(r, dict) and r.get("id") == rel_id for r in rels):
            raise ro.LedgerError("batch id %s already exists (two batches within one second); retry" % rel_id)
        rels.append({"id": rel_id, "kind": ro.BATCH_KIND, "name": "Batch: %s" % ", ".join(ids),
                     "shortTitle": "Batch (%d)" % len(ids), "team": a.team, "type": "maintenance",
                     "stage": "DEV", "status": BATCH_OPEN, "batchItems": ids, "createdAt": ro._ts(now),
                     "platforms": {}, "stageSha": {}, "stages": {}, "tests": []})
        wrote["ok"] = True
        return board

    if not _locked_update(a.board, _mint, "mint") or not wrote:
        raise ro.LedgerError("could not write the batch record to %s" % a.board)
    print(rel_id)
    return 0


def cmd_batch_close(a, now=None):
    res = {}

    def _close(board):
        rel = ro._find_release_in(board, a.release)
        if not ro.is_batch(rel):
            raise ro.LedgerError("%s is not a batch release (kind %r); refusing to close it here" % (a.release, rel.get("kind")))
        if rel.get("status") in BATCH_CLOSED:
            res["msg"] = "batch %s already %s" % (a.release, rel["status"])
            return None
        orch = rel.get("orchestration") if isinstance(rel.get("orchestration"), dict) else {}
        if a.status == "completed" and orch.get("activeRunId") and not orch.get("closedAt"):
            raise ro.LedgerError("batch %s still has an open run %s; close the run first (kb-release handoff %s), or "
                                 "abandon the batch (kb-release handoff %s --cancel)"
                                 % (a.release, orch["activeRunId"], a.release, a.release))
        rel["status"] = a.status
        rel["closedAt"] = ro._ts(now)
        if a.reason:
            rel["closeReason"] = a.reason
        res["msg"] = "batch %s %s" % (a.release, a.status)
        res["wrote"] = True
        return board

    ok = _locked_update(a.board, _close, "close")
    if "msg" not in res or (res.get("wrote") and not ok):
        raise ro.LedgerError("could not close batch %s in %s" % (a.release, a.board))
    print(res["msg"])
    return 0


def cmd_batch_cancel(a, now=None):
    """Abandon a batch (XACA-1834-009): close its open run, if any, with outcome "cancelled" (unfinished items allowed:
    that is the point), then mark the batch cancelled. Idempotent. Refuses a non-batch release. Workers already
    dispatched keep running in their own windows; the closed run only stops new dispatches and the monitor."""
    board = _read_json(a.board)
    rel = ro._find_release_in(board, a.release)
    if not ro.is_batch(rel):
        raise ro.LedgerError("%s is not a batch release (kind %r); --cancel applies to batches only" % (a.release, rel.get("kind")))
    reason = a.reason or "abandoned by the lead"
    orch = rel.get("orchestration") if isinstance(rel.get("orchestration"), dict) else {}
    run_id = orch.get("activeRunId")
    if run_id and not orch.get("closedAt"):
        ro.close_run(a.board, os.path.abspath(a.kanban_dir), a.release, run_id, outcome="cancelled", detail=reason, now=now)
        print("run %s closed (cancelled)" % run_id)
    return cmd_batch_close(SimpleNamespace(board=a.board, release=a.release, status="cancelled", reason=reason), now=now)


def cmd_cancel(a, now=None):
    """Abandon a RELEASE run (XACA-1882): close its open run with outcome "cancelled" even with unfinished or
    never-dispatched items. The release (status, stage, every other field), its orchestration items rows and lanes, and
    every backlog item are left as they are: the run summary keeps the last known per-item state as history. Workers
    already dispatched keep running in their own windows; the closed run only stops new dispatches and the monitor.
    Idempotent: no run, or a run already closed with ANY outcome, is rc 0 and writes nothing (a closed run's outcome is
    never rewritten). Refuses a batch: abandoning a batch also closes the batch record, which is batch-cancel's job."""
    board = _read_json(a.board)
    rel = ro._find_release_in(board, a.release)
    if ro.is_batch(rel):
        raise ro.LedgerError("%s is a batch release; abandon it with batch-cancel (kb-release handoff %s --cancel)"
                             % (a.release, a.release))
    orch = rel.get("orchestration") if isinstance(rel.get("orchestration"), dict) else {}
    run_id = orch.get("activeRunId")
    if not run_id:
        print("no orchestrated run recorded for %s: nothing to cancel" % a.release)
        return 0
    if orch.get("closedAt"):
        print("run %s already closed at %s; nothing to cancel" % (run_id, orch["closedAt"]))
        return 0
    ro.close_run(a.board, os.path.abspath(a.kanban_dir), a.release, run_id, outcome="cancelled",
                 detail=a.reason or "abandoned by the lead", now=now)
    print("run %s closed (cancelled); %s and its items are unchanged" % (run_id, a.release))
    print("start a new run with: kb-run %s" % a.release)
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
    s.add_argument("--phase", choices=(ro.PHASE_WAVE0,), help="XACA-1873: start a Wave 0 (planning) run")
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
    r.add_argument("--board", help="XACA-1873: with --release, add the Wave 0 sections when Wave 0 ran")
    r.add_argument("--release")
    r.add_argument("--kanban-dir")
    br = sub.add_parser("batch-readiness")
    br.add_argument("--board", required=True)
    br.add_argument("--kanban-dir", required=True)
    br.add_argument("--items", required=True)
    br.add_argument("--repo-root")
    br.add_argument("--json", action="store_true")
    bm = sub.add_parser("batch-mint")
    bm.add_argument("--board", required=True)
    bm.add_argument("--items", required=True)
    bm.add_argument("--team", required=True)
    bc = sub.add_parser("batch-close")
    bc.add_argument("--board", required=True)
    bc.add_argument("--release", required=True)
    bc.add_argument("--status", required=True, choices=BATCH_CLOSED)
    bc.add_argument("--reason")
    bx = sub.add_parser("batch-cancel")
    bx.add_argument("--board", required=True)
    bx.add_argument("--kanban-dir", required=True)
    bx.add_argument("--release", required=True)
    bx.add_argument("--reason")
    cx = sub.add_parser("cancel")
    cx.add_argument("--board", required=True)
    cx.add_argument("--kanban-dir", required=True)
    cx.add_argument("--release", required=True)
    cx.add_argument("--reason")
    ph = sub.add_parser("plan-hash")
    ph.add_argument("--plan-file", required=True)
    ph.add_argument("--board")
    ph.add_argument("--release")
    ph.add_argument("--batch-items")
    ph.add_argument("--kanban-dir", help="XACA-1873: where the Wave 0 plan docs live (default: the board's directory)")
    ph.add_argument("--coordinator-model", required=True)
    ph.add_argument("--coordinator-effort", required=True)
    ph.add_argument("--worker-model", required=True)
    ph.add_argument("--canonical", action="store_true", help="print the canonical JSON instead of its hash")
    bp = sub.add_parser("batch-plan")
    bp.add_argument("--board", required=True)
    bp.add_argument("--kanban-dir", required=True)
    bp.add_argument("--items", required=True)
    bp.add_argument("--team", required=True)
    bp.add_argument("--repo-root")
    bp.add_argument("--max-parallel", type=int)
    bp.add_argument("--terminals-json")
    try:
        args = ap.parse_args(argv)
    except SystemExit as exc:
        return 0 if exc.code in (0, None) else 2
    fn = {"start": cmd_start, "close": cmd_close, "exclude": cmd_exclude, "render": cmd_render,
          "batch-readiness": cmd_batch_readiness, "batch-mint": cmd_batch_mint,
          "batch-close": cmd_batch_close, "batch-cancel": cmd_batch_cancel, "cancel": cmd_cancel,
          "plan-hash": cmd_plan_hash, "batch-plan": cmd_batch_plan}.get(args.cmd)
    if fn is None:
        ap.print_usage(sys.stderr)
        return 2
    try:
        return fn(args)
    except (ro.LedgerError, ro.PlanError, OSError, ValueError, KeyError, ImportError) as exc:
        print("Error: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
