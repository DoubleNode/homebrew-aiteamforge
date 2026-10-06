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
      "stage": "<S>",                             # the bound stage: the last enabled stage before PROD (XACA-1446)
      "sha": "<stageSha[S] at init>",             # the build this record belongs to (XACA-1353-014, XACA-1446)
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

  * (XACA-1353-014, generalised by XACA-1446) The record is BOUND to the build it started on: `stage` = S, the
    last enabled stage before PROD (GAMMA when the team has it), and `sha` = stageSha[S], both taken from the
    board at init (never from the client; the server resolves S via release_gate.closeout_stage). set/target are
    refused when `sha` no longer equals stageSha[stage]. A backward move out of S/PROD (or a replaced
    stageSha[S]) archives the live record into the append-only `closeOutHistory[]` (`archivedAt`, `reason`) and
    clears it -- but is REFUSED once production already ships the build (mergeProduction or any later step
    `done`): that is fixed forward, never regressed.
  * close_out_binding() is the ONLY reader of the binding fields. Read-compat shim: a legacy record carrying
    only `gammaSha` (XACA-1353, pre-XACA-1446) reads as ("GAMMA", gammaSha). Writers emit only `stage`/`sha`
    (no dual-write); closeOutHistory[] entries keep whatever shape they had.

stdlib only, python 3.9 compatible.

CLI (all read-only; JSON on stdout, rc 0 ok / 1 refused / 2 usage):
    init             [--cr-team] [--targets a,b,c] [--stage S --sha X | --gamma-sha SHA (deprecated: GAMMA)]
                                                            -> fresh closeOut
    binding          --release FILE|-                       -> JSON {stage, sha, bound, gap}; rc 0 bound or no
                                                               record, 1 stale/malformed
    archived-for-sha --release FILE|- --sha X               -> the newest closeOutHistory entry bound to X
                                                               (JSON), rc 1 when none
    first-incomplete --release FILE|-                       -> step name, or "" when complete
    step-status      --release FILE|- --step NAME           -> pending|done|failed (or "n/a")
    can-delete       --release FILE|-                       -> exit 0 when deleteBranch may run
"""
import argparse
import json
import re
import sys
from datetime import datetime, timezone

STEPS = ("tag", "mergeProduction", "mergeIntegration", "mergeOtherReleases", "deleteBranch", "crClose")
STATUSES = ("pending", "done", "failed")
TARGET_STATUSES = ("pending", "done", "conflict", "failed")
TERMINAL_TARGETS = ("done", "conflict")
_DELETE_PREREQS = ("tag", "mergeProduction", "mergeIntegration")
# Once ANY of these is done, production already ships the build: a regress can no longer undo it.
_PRODUCTION_SHIPPED_STEPS = ("mergeProduction", "mergeIntegration", "mergeOtherReleases", "deleteBranch", "crClose")
_SHA_RE = re.compile(r"^[0-9a-f]{40,64}$")
# Stages a close-out may be bound to: every enabled stage that precedes PROD (PLANNED and CR never hold a build).
BINDABLE_STAGES = ("DEV", "QA", "ALPHA", "BETA", "GAMMA")


class CloseOutError(ValueError):
    """A refused operation; str(e) is the human reason (the server returns it as 409)."""


def _now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def applicable_steps(close_out):
    """Ordered step names that apply to this record (crClose only for CR teams)."""
    steps = (close_out or {}).get("steps") or {}
    return [s for s in STEPS if s in steps]


def _valid_sha(v):
    """`v` as a lower-case SHA string when valid, else None."""
    return v.lower() if isinstance(v, str) and _SHA_RE.match(v.lower()) else None


def init_close_out(cr_team=False, targets=None, now=None, stage=None, sha=None, gamma_sha=None):
    """Fresh record, every step pending. `targets` = the other open release branches at the time
    close-out starts (one sub-entry each, all pending). `stage`/`sha` = the bound stage S and stageSha[S]
    the record belongs to; `gamma_sha` is the deprecated spelling of stage="GAMMA", sha=gamma_sha.
    Writes only `stage` and `sha` (never the legacy `gammaSha`)."""
    if gamma_sha is not None:
        if stage not in (None, "GAMMA") or (sha is not None and sha != gamma_sha):
            raise CloseOutError("gamma_sha conflicts with stage/sha")
        stage, sha = "GAMMA", gamma_sha
    if (stage is None) != (sha is None):
        raise CloseOutError("stage and sha must be given together")
    if stage is not None and (stage not in BINDABLE_STAGES or _valid_sha(sha) is None):
        raise CloseOutError("cannot bind close-out to stage %r / sha %r" % (stage, sha))
    ts = now or _now()
    steps = {s: {"status": "pending", "ts": ts} for s in STEPS if s != "crClose" or cr_team}
    tg = {}
    for t in (targets or []):
        if not isinstance(t, str) or not t.strip():
            raise CloseOutError("mergeOtherReleases target must be a non-empty branch name")
        tg[t.strip()] = "pending"
    steps["mergeOtherReleases"]["targets"] = tg
    rec = {"startedAt": ts, "crTeam": bool(cr_team), "steps": steps}
    if stage is not None:
        rec["stage"] = stage
        rec["sha"] = _valid_sha(sha)
    return rec


def close_out_binding(close_out):
    """THE accessor for a record's binding: (stage, sha) with sha lower-cased, or None when the record is
    malformed. A record with a valid `stage` + `sha` returns them; otherwise a legacy record (XACA-1353,
    `gammaSha` only, no stage/sha keys) reads as ("GAMMA", gammaSha). Nothing else reads these fields."""
    if not isinstance(close_out, dict):
        return None
    st, sha = close_out.get("stage"), _valid_sha(close_out.get("sha"))
    if st in BINDABLE_STAGES and sha is not None:
        return st, sha
    legacy = _valid_sha(close_out.get("gammaSha"))
    if legacy is not None and "stage" not in close_out and "sha" not in close_out:
        return "GAMMA", legacy
    return None


def stage_sha(release, stage):
    """stageSha[stage] of a release as a valid lower-case SHA string, else None."""
    ss = (release or {}).get("stageSha")
    return _valid_sha(ss.get(stage)) if isinstance(ss, dict) else None


def binding_gap(release):
    """Why the live closeOut is not bound to the CURRENT build of its OWN stage, or None when it is. Record-
    intrinsic: compares close_out_binding(record) with stageSha[record.stage]; flow config plays no part (the
    gate checks the stage itself, XACA-1446-003). A malformed record is a gap; so is a release with no valid
    stageSha for the record's stage."""
    co = (release or {}).get("closeOut")
    if not isinstance(co, dict):
        return None
    bound = close_out_binding(co)
    if bound is None:
        return "close-out record is malformed (no stage/sha binding it to a build)"
    stage, rec = bound
    cur = stage_sha(release, stage)
    if cur is None:
        return "release has no valid stageSha.%s to bind the close-out to" % stage
    if rec != cur:
        return ("close-out belongs to a different %s build (record %s, stageSha.%s %s)"
                % (stage, rec[:12], stage, cur[:12]))
    return None


def archive_close_out(release, reason, now=None):
    """Move the live `closeOut` into the append-only `closeOutHistory[]` (flat copy + archivedAt + reason) and
    clear it. No record = no-op (returns None). Raises CloseOutError, changing nothing, when production already
    ships the build (mergeProduction or any later step is done): that is fixed forward with a hotfix release."""
    co = release.get("closeOut")
    if co is None:
        return None
    steps = co.get("steps") if isinstance(co, dict) else None
    shipped = [s for s in _PRODUCTION_SHIPPED_STEPS if isinstance(steps, dict) and step_status(co, s) == "done"]
    if shipped:
        raise CloseOutError(
            "refused: production already ships this build (close-out step '%s' is done) and cannot be un-shipped by "
            "a regress. Fix forward: cut a hotfix release (kb-release create --type hotfix) for the correction"
            % shipped[0])
    hist = release.get("closeOutHistory")
    hist = hist if isinstance(hist, list) else []
    entry = dict(co) if isinstance(co, dict) else {"malformed": co}
    entry["archivedAt"] = now or _now()
    entry["reason"] = str(reason or "unspecified")
    hist.append(entry)
    release["closeOutHistory"] = hist
    release.pop("closeOut", None)
    return entry


def reconcile_close_out(release, now=None):
    """Archive the live closeOut when it no longer matches stageSha[its bound stage] (a replaced build). Returns the
    archived entry or None. Raises CloseOutError (nothing changed) when production already ships the record's
    build."""
    if not isinstance(release.get("closeOut"), dict) or binding_gap(release) is None:
        return None
    bound = close_out_binding(release["closeOut"])
    return archive_close_out(release, "stageSha.%s changed: close-out belonged to another build"
                             % (bound[0] if bound else "<unbound>"), now)


def archived_for_sha(release, sha):
    """The NEWEST closeOutHistory[] entry whose binding sha equals `sha` (legacy gammaSha entries included), or
    None. Reads history entries through close_out_binding only."""
    want = _valid_sha(sha)
    hist = (release or {}).get("closeOutHistory")
    if want is None or not isinstance(hist, list):
        return None
    for entry in reversed(hist):
        b = close_out_binding(entry)
        if b is not None and b[1] == want:
            return entry
    return None


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


def apply_op(release, op, now=None, stage=None, sha=None):
    """The server's single entry point. `op` is the POST body:
         {"op": "init", "crTeam": bool, "targets": [..]}      (idempotent: refused if a record exists)
       `stage` is the bound stage S the SERVER resolved (release_gate.closeout_stage); init binds to it and to
       stageSha[S] read from the board here. Both come from keyword arguments, never from the body (a client
       `stage`/`sha`/`gammaSha` in the body is ignored). `sha`, when given, must equal stageSha[S].
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
        if stage not in BINDABLE_STAGES:
            raise CloseOutError("close-out cannot start: no valid stage to bind it to (%r)" % (stage,))
        bsha = stage_sha(release, stage)
        if bsha is None:
            raise CloseOutError("close-out cannot start: the release has no valid stageSha.%s to bind it to" % stage)
        if sha is not None and _valid_sha(sha) != bsha:
            raise CloseOutError("close-out cannot start: stageSha.%s is not the expected build" % stage)
        release["closeOut"] = init_close_out(cr, tg, now, stage=stage, sha=bsha)
        return release["closeOut"]
    co = release.get("closeOut")
    if kind in ("set", "target") and not isinstance(co, dict):
        raise CloseOutError("close-out not started for this release (op=init first)")
    if kind in ("set", "target"):
        gap = binding_gap(release)
        if gap:
            raise CloseOutError("%s; archive it (regress out of its stage) and start a new close-out" % gap)
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
    return doc if "steps" not in doc else {"closeOut": doc, "_bare": True}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("init")
    p.add_argument("--cr-team", action="store_true")
    p.add_argument("--targets", default="")
    p.add_argument("--gamma-sha", default=None)   # deprecated alias for --stage GAMMA --sha
    p.add_argument("--stage", default=None)
    p.add_argument("--sha", default=None)
    p = sub.add_parser("archived-for-sha")
    p.add_argument("--release", required=True)
    p.add_argument("--sha", required=True)
    for name in ("binding", "first-incomplete", "step-status", "can-delete"):
        p = sub.add_parser(name)
        p.add_argument("--release", required=True)
        if name == "step-status":
            p.add_argument("--step", required=True)
    a = ap.parse_args(argv)
    try:
        if a.cmd == "init":
            tg = [t for t in a.targets.split(",") if t.strip()]
            print(json.dumps(init_close_out(a.cr_team, tg, stage=a.stage, sha=a.sha, gamma_sha=a.gamma_sha)))
            return 0
        rel = _load_release(a.release)
        if a.cmd == "archived-for-sha":
            hit = archived_for_sha(rel, a.sha)
            if hit is None:
                print("no archived close-out for that sha", file=sys.stderr)
                return 1
            print(json.dumps(hit))
            return 0
        co = rel.get("closeOut")
        if a.cmd == "binding":
            if not isinstance(co, dict):
                print(json.dumps({"stage": None, "sha": None, "bound": None, "gap": None}))
                return 0
            b = close_out_binding(co)
            gap = None if (b and rel.get("_bare")) else binding_gap(rel)   # a bare closeOut has no stageSha to compare
            print(json.dumps({"stage": b[0] if b else None, "sha": b[1] if b else None,
                              "bound": b is not None and gap is None, "gap": gap}))
            return 0 if (b is not None and gap is None) else 1
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
