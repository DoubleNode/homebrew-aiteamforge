#!/usr/bin/env python3
"""PROD close-out step-state (XACA-1353-001; spec RELEASE-LIFECYCLE.md 3.2 PROD, 4.2, 13.4).

Pure state logic for `release.closeOut`, the ordered + resumable record of a release's PROD
close-out. Never reads or writes a board: the ONE writer of the record is the LCARS server
(POST /api/releases/<id>/close-out), which calls apply_op() under the board write lock. The shell
helpers in kanban-helpers.sh use the CLI below only to READ / DERIVE (first-incomplete, can-delete).

Shape (fixed order = spec 13.4: tag -> mergeProduction -> mergeIntegration -> mergeOtherReleases
-> deleteBranch -> crClose):

    release.closeOut = {
      "startedAt": "<iso>",
      "crTeam": true|false,                       # crClose is a step ONLY when true
      "steps": {
        "tag":                {"status": "pending|done|failed", "ts": "<iso>", "error": "<msg>"?},
        "mergeProduction":    {...}, "mergeIntegration": {...},
        "mergeOtherReleases": {..., "targets": {"releases/1.3.0": "done|conflict|failed|pending"}},
        "deleteBranch":       {...},
        "crClose":            {...}                # present only when crTeam
      }
    }

Contract (enforced here, not by callers):
  * A step may only be set to `done` or `failed` when EVERY earlier applicable step is `done`
    (so first_incomplete() is always the one runnable step, and resume never skips ahead).
  * deleteBranch therefore cannot run until tag, mergeProduction and mergeIntegration are done
    (spec 13.4: "nothing is deleted until the tag and both merges have succeeded").
  * `done` is sticky: re-marking it `done` is an idempotent no-op; any other change is refused,
    so a resumed run can never re-execute (duplicate tag / merge) a finished step.
  * mergeOtherReleases is per-target. `done` and `conflict` are TERMINAL targets (a conflict is
    resolved by a PR into THAT release's own branch and never blocks the closing release);
    `pending` and `failed` (e.g. push rejected) are retryable and block the step's `done`.

stdlib only, python 3.9 compatible.

CLI (all read-only; JSON on stdout, rc 0 ok / 1 refused / 2 usage):
    init             [--cr-team] [--targets a,b,c]          -> fresh closeOut
    first-incomplete --release FILE|-                       -> step name, or "" when complete
    step-status      --release FILE|- --step NAME           -> pending|done|failed (or "n/a")
    can-delete       --release FILE|-                       -> exit 0 when deleteBranch may run
"""
import argparse
import json
import sys
from datetime import datetime, timezone

STEPS = ("tag", "mergeProduction", "mergeIntegration", "mergeOtherReleases", "deleteBranch", "crClose")
STATUSES = ("pending", "done", "failed")
TARGET_STATUSES = ("pending", "done", "conflict", "failed")
TERMINAL_TARGETS = ("done", "conflict")
_DELETE_PREREQS = ("tag", "mergeProduction", "mergeIntegration")


class CloseOutError(ValueError):
    """A refused operation; str(e) is the human reason (the server returns it as 409)."""


def _now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def applicable_steps(close_out):
    """Ordered step names that apply to this record (crClose only for CR teams)."""
    steps = (close_out or {}).get("steps") or {}
    return [s for s in STEPS if s in steps]


def init_close_out(cr_team=False, targets=None, now=None):
    """Fresh record, every step pending. `targets` = the other open release branches at the time
    close-out starts (one sub-entry each, all pending)."""
    ts = now or _now()
    steps = {s: {"status": "pending", "ts": ts} for s in STEPS if s != "crClose" or cr_team}
    tg = {}
    for t in (targets or []):
        if not isinstance(t, str) or not t.strip():
            raise CloseOutError("mergeOtherReleases target must be a non-empty branch name")
        tg[t.strip()] = "pending"
    steps["mergeOtherReleases"]["targets"] = tg
    return {"startedAt": ts, "crTeam": bool(cr_team), "steps": steps}


def step_status(close_out, step):
    rec = ((close_out or {}).get("steps") or {}).get(step)
    return rec.get("status", "pending") if isinstance(rec, dict) else "n/a"


def first_incomplete(close_out):
    """First applicable step whose status is not `done`, or None when close-out is complete."""
    for s in applicable_steps(close_out):
        if step_status(close_out, s) != "done":
            return s
    return None


def _earlier_not_done(close_out, step):
    order = applicable_steps(close_out)
    return [s for s in order[:order.index(step)] if step_status(close_out, s) != "done"]


def can_run(close_out, step):
    """True when `step` is applicable, not yet done, and every earlier applicable step is done."""
    if step not in applicable_steps(close_out) or step_status(close_out, step) == "done":
        return False
    return not _earlier_not_done(close_out, step)


def can_delete(close_out):
    """True when deleteBranch is runnable: tag + both merges done (and the step itself not done)."""
    if not close_out or not all(step_status(close_out, s) == "done" for s in _DELETE_PREREQS):
        return False
    return can_run(close_out, "deleteBranch")


def targets_terminal(close_out):
    """True when every mergeOtherReleases target is done|conflict (no targets = vacuously true)."""
    tg = (((close_out or {}).get("steps") or {}).get("mergeOtherReleases") or {}).get("targets") or {}
    return all(v in TERMINAL_TARGETS for v in tg.values())


def set_step(close_out, step, status, error=None, now=None):
    """Mutate `close_out` in place: record `step` as `status`. Raises CloseOutError when refused."""
    if step not in STEPS:
        raise CloseOutError("unknown close-out step '%s' (one of %s)" % (step, list(STEPS)))
    if step not in applicable_steps(close_out):
        raise CloseOutError("step '%s' does not apply to this release (not a CR team)" % step)
    if status not in STATUSES:
        raise CloseOutError("status must be one of %s, got '%s'" % (list(STATUSES), status))
    cur = step_status(close_out, step)
    if cur == "done":
        if status == "done":
            return close_out   # idempotent: a resumed run re-reporting success
        raise CloseOutError("step '%s' is already done; a finished step is never re-run or reopened" % step)
    if status != "pending":
        blockers = _earlier_not_done(close_out, step)
        if blockers:
            if step == "deleteBranch":
                missing = [s for s in _DELETE_PREREQS if step_status(close_out, s) != "done"] or blockers
                raise CloseOutError("deleteBranch refused: %s not done (nothing is deleted until the tag and "
                                    "both merges have succeeded)" % ", ".join(missing))
            raise CloseOutError("step '%s' refused: earlier step(s) not done: %s" % (step, ", ".join(blockers)))
    if step == "mergeOtherReleases" and status == "done" and not targets_terminal(close_out):
        bad = sorted(t for t, v in close_out["steps"][step].get("targets", {}).items()
                     if v not in TERMINAL_TARGETS)
        raise CloseOutError("mergeOtherReleases cannot be done: target(s) not terminal: %s" % ", ".join(bad))
    rec = close_out["steps"][step]
    rec["status"] = status
    rec["ts"] = now or _now()
    if status == "failed":
        rec["error"] = str(error or "unspecified failure")
    else:
        rec.pop("error", None)
    return close_out


def set_target(close_out, target, status, now=None):
    """Record one mergeOtherReleases target. The step must be runnable (or already failed/pending
    with all earlier steps done) so targets are only touched at the right point in the order."""
    if status not in TARGET_STATUSES:
        raise CloseOutError("target status must be one of %s, got '%s'" % (list(TARGET_STATUSES), status))
    rec = close_out["steps"]["mergeOtherReleases"]
    if target not in rec.get("targets", {}):
        raise CloseOutError("unknown mergeOtherReleases target '%s' (recorded when close-out started)" % target)
    if step_status(close_out, "mergeOtherReleases") == "done":
        raise CloseOutError("mergeOtherReleases is already done; targets are frozen")
    blockers = _earlier_not_done(close_out, "mergeOtherReleases")
    if blockers:
        raise CloseOutError("target update refused: earlier step(s) not done: %s" % ", ".join(blockers))
    rec["targets"][target] = status
    rec["ts"] = now or _now()
    return close_out


def apply_op(release, op, now=None):
    """The server's single entry point. `op` is the POST body:
         {"op": "init", "crTeam": bool, "targets": [..]}      (idempotent: refused if a record exists)
         {"op": "set", "step": S, "status": X, "error": str?}
         {"op": "target", "target": branch, "status": X}
       Mutates release["closeOut"]; returns it. Raises CloseOutError when refused."""
    kind = op.get("op") if isinstance(op, dict) else None
    if kind == "init":
        if isinstance(release.get("closeOut"), dict):
            raise CloseOutError("close-out already started for this release; resume it, do not re-init")
        cr = op.get("crTeam", False)
        if not isinstance(cr, bool):
            raise CloseOutError("'crTeam' must be true or false")
        tg = op.get("targets", [])
        if not isinstance(tg, list):
            raise CloseOutError("'targets' must be a list of branch names")
        release["closeOut"] = init_close_out(cr, tg, now)
        return release["closeOut"]
    co = release.get("closeOut")
    if kind in ("set", "target") and not isinstance(co, dict):
        raise CloseOutError("close-out not started for this release (op=init first)")
    if kind == "set":
        set_step(co, op.get("step"), op.get("status"), op.get("error"), now)
    elif kind == "target":
        set_target(co, op.get("target"), op.get("status"), now)
    else:
        raise CloseOutError("op must be one of init|set|target")
    return co


def _load_release(path):
    raw = sys.stdin.read() if path == "-" else open(path, encoding="utf-8").read()
    doc = json.loads(raw)
    # Accept a bare release OR a bare closeOut (anything with `steps`).
    return doc if "steps" not in doc else {"closeOut": doc}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("init")
    p.add_argument("--cr-team", action="store_true")
    p.add_argument("--targets", default="")
    for name in ("first-incomplete", "step-status", "can-delete"):
        p = sub.add_parser(name)
        p.add_argument("--release", required=True)
        if name == "step-status":
            p.add_argument("--step", required=True)
    a = ap.parse_args(argv)
    try:
        if a.cmd == "init":
            tg = [t for t in a.targets.split(",") if t.strip()]
            print(json.dumps(init_close_out(a.cr_team, tg)))
            return 0
        co = _load_release(a.release).get("closeOut")
        if not isinstance(co, dict):
            print("no closeOut record on this release", file=sys.stderr)
            return 1
        if a.cmd == "first-incomplete":
            print(first_incomplete(co) or "")
            return 0
        if a.cmd == "step-status":
            print(step_status(co, a.step))
            return 0
        return 0 if can_delete(co) else 1
    except (CloseOutError, ValueError, OSError) as e:
        print("Error: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
