"""Superseding on a new SHA (XACA-1347-006, spec RELEASE-LIFECYCLE 6.5 / 13.1).

Pure helpers: stdlib only, Python 3.9-safe, no I/O, never mutate their input. The server
(lcars-ui/server.py handle_release_new_sha) owns locking, persistence and logging.

Every supersededBy write goes through release_schema.set_superseded(_many), which applies the ONE
legal-transition rule (supersede_transition_ok). Nothing here writes that field any other way.
"""
from __future__ import annotations

import copy
import re

import release_schema as _schema

DEFAULT_ON_NEW_SHA = "restart-from:QA"
_PREFIX = "restart-from:"
CURRENT_ONLY = "current-stage-only"     # spec 6.5 names it as the thing a CR team may NOT choose
_RESTART_STAGES = ("DEV", "QA", "ALPHA", "BETA")  # the pre-CR stages (index < CR)
_CR_IDX = _schema.STAGES.index("CR")
SETTING = "releaseConfig.onNewSha"


def _idx(stage):
    return _schema.STAGES.index(stage) if stage in _schema.STAGES else -1


def parse_on_new_sha(value, cr_enabled):
    """-> restart stage ("DEV"|"QA"|"ALPHA"|"BETA"), or None for "current-stage-only".

    Accepts "restart-from:<pre-CR stage>" (exact case). "current-stage-only" is accepted ONLY
    when CR is disabled (spec 6.5: never when the team has CRs enabled). Anything else raises
    ValueError naming the setting; there is no silent default (absent-key defaulting is the
    caller's job, an explicit bad value is a refusal).
    """
    if not isinstance(value, str):
        raise ValueError("%s must be a string such as %r, got %r" % (SETTING, DEFAULT_ON_NEW_SHA, value))
    if value == CURRENT_ONLY:
        if cr_enabled:
            raise ValueError("%s %r is not allowed when CRs are enabled (every pre-CR stage must pass as one "
                             "SHA); use %r" % (SETTING, value, "restart-from:<STAGE>"))
        return None
    if value.startswith(_PREFIX) and value[len(_PREFIX):] in _RESTART_STAGES:
        return value[len(_PREFIX):]
    raise ValueError("%s %r is invalid: expected 'restart-from:<STAGE>' with STAGE one of %s%s"
                     % (SETTING, value, list(_RESTART_STAGES),
                        "" if cr_enabled else " or 'current-stage-only'"))


def effective_restart_stage(cur, restart, stages_order):
    """The stage the release is sent back to. `restart` None = current-stage-only. Never LATER
    than `cur` (a release in DEV with restart-from:QA is not promoted by a new commit) and never
    a disabled stage: the first ENABLED stage in [restart, cur], else `cur`."""
    if restart is None:
        return cur
    lo, hi = _idx(restart), _idx(cur)
    for s in stages_order:
        if lo <= _idx(s) <= hi:
            return s
    return cur


def apply_new_sha(release, new_sha, *, on_new_sha=None, cr_enabled, stages_order, now=None):
    """-> (new_release, summary). `release` is NOT mutated.

    Pre-CR (current stage index < CR): stageSha is overwritten with new_sha for every stage in
    [restart, current] (and any later stage that already has an entry, so no stale SHA survives);
    EVERY not-yet-superseded record of the restart stage and later stages whose sha != new_sha gets
    supersededBy = "sha:<new_sha>" (placeholder; server.handle_release_stage_tests repoints it to
    the first new record for the same test); the release goes back to the restart stage, status
    running, and later stages are reset to pending. A waiver on every superseded stage is MOVED into the
    append-only stages.<S>.waiverHistory ({...waiver, voidedAt, voidedBySha}) and stages.<S>.waiver is
    deleted (spec 6.4: "a new SHA voids it"). Leaving it in place was not enough: it bound to the old
    SHA, so an A -> B -> A round trip made it match the graded SHA again and revived it.

    CR or later: nothing is re-run, stageSha / tests / stages are untouched. The new SHA is only
    recorded as release["pendingSha"]; the server feeds it to the gate as the branch HEAD, so
    CR -> GAMMA is refused until the lead regresses (spec 13.2).

    `on_new_sha` None = default "restart-from:QA". Raises ValueError on an invalid setting, a
    malformed SHA, or a PLANNED/PROD release (the caller maps those to 400/409).
    """
    if not isinstance(new_sha, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", new_sha):
        raise ValueError("sha must be a 40-character hex string")
    sha = new_sha.lower()
    restart = parse_on_new_sha(DEFAULT_ON_NEW_SHA if on_new_sha is None else on_new_sha, cr_enabled)
    rel = copy.deepcopy(release)
    cur = _current_stage(rel)
    if cur in ("PLANNED", "PROD"):
        raise ValueError("release is at %s: a new SHA is not applicable" % cur)
    stage_sha = rel.get("stageSha") if isinstance(rel.get("stageSha"), dict) else {}
    prev = stage_sha.get(cur)
    summary = {"from": cur, "to": cur, "sha": sha, "previousSha": prev, "superseded": [],
               "onNewSha": DEFAULT_ON_NEW_SHA if on_new_sha is None else on_new_sha}

    if _idx(cur) >= _CR_IDX:
        rel["pendingSha"] = {"sha": sha, "atStage": cur}
        if now:
            rel["pendingSha"]["ts"] = now
        summary["action"] = "blocked-pending-regress"
        return rel, summary

    eff = effective_restart_stage(cur, restart, stages_order)
    lo = _idx(eff)
    tests = rel.get("tests") if isinstance(rel.get("tests"), list) else []
    updates = []
    for rec in tests:
        if not isinstance(rec, dict) or not isinstance(rec.get("id"), str) or rec.get("supersededBy") is not None:
            continue
        if _idx(rec.get("stage")) < lo or str(rec.get("sha")).lower() == sha:
            continue
        updates.append((rec["id"], "sha:" + sha))
    # one batch: per-record set_superseded rebuilt the id index each time (O(N^2) under the board lock)
    tests, done = _schema.set_superseded_many(tests, updates)
    rel["tests"] = tests

    stage_sha = dict(stage_sha)
    for s in _schema.STAGES:
        if s in ("PLANNED", "PROD"):
            continue
        if lo <= _idx(s) <= _idx(cur) or (_idx(s) > _idx(cur) and s in stage_sha):
            stage_sha[s] = sha
    rel["stageSha"] = stage_sha
    rel.pop("pendingSha", None)

    stages = rel.get("stages") if isinstance(rel.get("stages"), dict) else {}
    rel["stages"] = stages
    for s in _schema.STAGES:
        if not (lo <= _idx(s) <= _idx(cur)) and not (_idx(s) > _idx(cur) and isinstance(stages.get(s), dict)):
            continue
        srec = stages.get(s)
        if not isinstance(srec, dict):
            if s != eff and stages_order and s not in stages_order:
                continue                  # PR #1010 round 1: never mint an entry for a DISABLED stage
            srec = {"enteredAt": now, "expected": []} if s == eff else {"expected": []}
            stages[s] = srec
        if isinstance(srec.get("waiver"), dict):
            void = dict(srec.pop("waiver"), voidedAt=now, voidedBySha=sha)
            srec["waiverHistory"] = list(srec.get("waiverHistory") or []) + [void]
        elif "waiver" in srec:            # malformed (not an object): still must not survive the new SHA
            srec["waiverHistory"] = list(srec.get("waiverHistory") or []) + [
                {"malformed": srec.pop("waiver"), "voidedAt": now, "voidedBySha": sha}]
        srec["status"] = "running" if s == eff else "pending"
        srec["completedAt"] = None
        if s == eff and now:
            srec["enteredAt"] = now
    rel["stage"] = eff
    summary.update(action="restart" if eff != cur else "rerun-current", to=eff, superseded=done)
    return rel, summary


def _current_stage(rel):
    st = rel.get("stage")
    if st in _schema.STAGES:
        return st
    import release_gate  # late: only needed for legacy releases with no explicit stage
    return release_gate.current_stage(rel)
