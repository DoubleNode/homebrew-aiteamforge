"""release_gamma_failure.py -- the resumable GAMMA failure / rollback protocol (XACA-1349-005; spec RELEASE-LIFECYCLE.md 13.3).

`kb-release gamma-fail <REL-ID> --by <lead> --summary "..."` runs spec 13.3 against the team board and stops at
the first thing it cannot do for the lead. Every step first asks "did this already happen?" and skips if so, so
a failure leaves the release in its last good state and a re-run resumes there (same style as release_cr_stage).

  step             what it does                                                          done when
  stop             refuse unless the release is at GAMMA; stages.GAMMA.status = failed;  release.gammaFailure
                   release.gammaFailure = {at, by, summary, gammaSha, testsStopped, ..}  exists for this GAMMA SHA
                   (`kb-release test` then refuses to run GAMMA tests)
  rollback-deploy  STOPS (rc 5) until the lead has redeployed production from            a PASS `rollback-deploy`
                   release.rollbackSha and re-runs with --rollback-result PASS|FAIL;    record names rollbackSha
                   the engine records the Automated test `rollback-deploy`
  rollback-smoke   same for the production smoke re-run against rollbackSha              a PASS `rollback-smoke`
                   (--smoke-result PASS|FAIL); records `rollback-smoke`                  record
  hold             stamp gammaFailure on the CR, then `kb-cr hold` (reason per 13.3)     CR is held by this failure
  regress          POST /api/releases/<id>/regress to DEV (the sanctioned path)          release no longer at GAMMA
  notify           kb-notify send --to release-channel --template gamma-rollback         a receipt exists since `at`
  record           re-publish the Testing Log (stored handle) and the CR's cr-record     both flags in .recorded

NO DEPLOY PROVIDER EXISTS (release_providers.py declares TEST providers only; the runner never deploys), so the
redeploy and the production smoke re-run are performed by the lead/session and REPORTED here. The engine never
invents a deploy: it records what the lead reports, against the rollback SHA the engine recorded at GAMMA entry.

How the rollback records fit the test schema (spec 6.2: `sha` MUST equal stageSha.<stage>): the records carry
sha = stageSha.GAMMA (the build that FAILED, which is what the /tests endpoint requires of every GAMMA record),
env = "PROD", and `notes` starting `rollbackSha=<40-hex>` -- the SHA production was rolled back to. They are
NOT in stages.GAMMA.expected, so they never change the (failed) gate verdict.

Scoping of a failure (XACA-1349-005 QA): release.gammaFailure governs a GAMMA entry only while it matches that build AND
has no `regressedAt` (stamped by the regress step, or by a re-run after a by-hand regress). So `kb-release test` /
`walkthrough` refuse, and the GAMMA exit gate blocks, for the failed build only until the release is regressed out of
GAMMA; a retry of the same SHA, or the fix on a new one, tests normally and a second failure starts a NEW marker
(the earlier one is kept in `history`). Rollback records only count for a failure if written at/after its `at`.
A failure declared before any GAMMA test ran has no expected set for the sha; the first rollback record binds the
(possibly empty) recorded set to it, because /tests refuses a records-only post otherwise.

Superseded-by (spec 13.3 step 4 / G9): the held CR carries `gammaFailure`; `kb-release cr-stage` closes it with
`kb-cr close <held> --reason "superseded by <new CR-ID>"` AFTER it has created and linked the new CR
(release_cr_stage.CrStage._close_superseded).

Exit codes (same table as cr-stage): 0 complete | 1 a tool failed or the rollback FAILED (re-run) | 2 usage /
config | 3 refused (not GAMMA, not a lead, no rollbackSha, regressed off GAMMA before the rollback records, ...) | 5 STOPPED for the lead (redeploy / smoke result).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import approval_providers as ap  # noqa: E402
import release_cr_stage as rcs  # noqa: E402
import release_gate  # noqa: E402
import release_rollback  # noqa: E402
import release_schema  # noqa: E402

RC_OK, RC_FAILED, RC_USAGE, RC_REFUSED, RC_NEEDS_LEAD = 0, 1, 2, 3, 5

STEPS = ("stop", "rollback-deploy", "rollback-smoke", "hold", "regress", "notify", "record")
NOTICE_ALIAS, NOTICE_TEMPLATE = "release-channel", "gamma-rollback"
T_DEPLOY, T_SMOKE = "rollback-deploy", "rollback-smoke"
PROD_ENV = "PROD"
REGRESS_TO = "DEV"
_SHA40 = re.compile(r"[0-9a-fA-F]{40}")
CrStageError, ToolError = rcs.CrStageError, rcs.ToolError


def _reason(summary: str, rollback_sha: str) -> str:
    """The hold/regress reason, verbatim from spec 13.3 step 3."""
    return "GAMMA failure: %s; rolled back to %s" % (summary, rollback_sha)


def marker_matches(marker: Any, gamma_sha: Optional[str]) -> bool:
    return (isinstance(marker, dict) and isinstance(marker.get("gammaSha"), str) and bool(gamma_sha)
            and marker["gammaSha"].lower() == str(gamma_sha).lower())


def marker_active(marker: Any, gamma_sha: Optional[str]) -> bool:
    """A failure that still governs THIS GAMMA entry: it matches the build and the release was not yet regressed
    out of GAMMA for it. Once the protocol's regress step lands it stamps `regressedAt`; a re-entry of GAMMA on the
    SAME SHA (a retry with no new commit) is then a new GAMMA entry, not the old failure still in force. The same
    predicate is what `kb-release test` / `walkthrough` refuse on and what the GAMMA exit gate blocks on."""
    return marker_matches(marker, gamma_sha) and not marker.get("regressedAt")


# ---------------------------------------------------------------------------------------- tools

class GammaTools(rcs.ShellTools):
    """ShellTools plus the two LCARS endpoints this flow needs (tests records, regress)."""

    def __init__(self, *a: Any, port: int = 8080, post: Optional[Callable[..., Any]] = None, **kw: Any):
        kw.setdefault("actor", "kb-release gamma-fail")
        rcs.ShellTools.__init__(self, *a, **kw)
        self.base_url = "http://localhost:%d" % port
        self._post = post or self._http_post

    def _http_post(self, path: str, payload: Dict[str, Any], timeout: int = 60) -> Dict[str, Any]:
        import release_walkthrough  # noqa: PLC0415 -- bearer key source shared with kb-release test
        req = urllib.request.Request(self.base_url + path, data=json.dumps(payload).encode(), method="POST",
                                     headers={"Content-Type": "application/json"})
        key = release_walkthrough._bearer_key()
        if key:
            req.add_header("Authorization", "Bearer " + key)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode() or "{}")
        except urllib.error.HTTPError as e:
            raw = e.read().decode(errors="replace")
            try:
                msg = json.loads(raw).get("error") or raw
            except ValueError:
                msg = raw
            raise ToolError("HTTP %d from %s: %s" % (e.code, path, str(msg)[:400]), 3 if e.code in (400, 404, 409) else 1)
        except (urllib.error.URLError, OSError, ValueError) as e:
            raise ToolError("transport failure calling %s: %s (is LCARS running?)" % (path, e), 1)

    def post_tests(self, release_id: str, stage: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        return self._post("/api/releases/%s/stages/%s/tests" % (release_id, stage), payload)

    def regress(self, release_id: str, to: str, reason: str, actor: str) -> Dict[str, Any]:
        return self._post("/api/releases/%s/regress" % release_id, {"to": to, "reason": reason, "actor": actor})


# ---------------------------------------------------------------------------------------- orchestrator

class GammaFailure:
    """One run of the GAMMA-failure protocol for one release. Reads the board fresh at every step."""

    def __init__(self, release_id: str, tools: Any, board_file: str, kanban_dir: str, team: str, *, by: str,
                 summary: Optional[str] = None, rollback_result: Optional[str] = None,
                 rollback_notes: Optional[str] = None, smoke_result: Optional[str] = None,
                 smoke_notes: Optional[str] = None, only_step: Optional[str] = None,
                 now: Optional[Callable[[], datetime]] = None, say: Callable[[str], None] = print,
                 resolve: Optional[Callable[..., Dict[str, Any]]] = None):
        if only_step is not None and only_step not in STEPS:
            raise CrStageError("unknown step %r (steps: %s)" % (only_step, ", ".join(STEPS)), rcs.RC_USAGE)
        if not (by or "").strip():
            raise CrStageError("--by <lead> is required (the lead confirms the rollback)", rcs.RC_USAGE)
        results = {}
        for label, val, notes in (("--rollback-result", rollback_result, rollback_notes),
                                  ("--smoke-result", smoke_result, smoke_notes)):
            if val is None:
                results[label] = None
                continue
            v = str(val).strip().upper()
            if v not in ("PASS", "FAIL"):
                raise CrStageError("%s must be PASS or FAIL, not %r" % (label, val), rcs.RC_USAGE)
            if v == "FAIL" and not (notes or "").strip():
                raise CrStageError("%s FAIL needs notes (spec 6.2: a FAIL record carries its evidence)" % label, rcs.RC_USAGE)
            results[label] = v
        self.rel_id, self.tools, self.board_file, self.kdir, self.team = release_id, tools, board_file, kanban_dir, team
        self.by, self.summary = by.strip(), (summary or "").strip() or None
        self.rb_result, self.rb_notes = results["--rollback-result"], (rollback_notes or "").strip()
        self.sm_result, self.sm_notes = results["--smoke-result"], (smoke_notes or "").strip()
        self.only, self.say = only_step, say
        self.now = now or (lambda: datetime.now(timezone.utc))
        self._resolve = resolve
        self._cs: Optional[rcs.CrStage] = None

    # -- loading ----------------------------------------------------------------------------------
    def _load(self) -> Tuple[Dict[str, Any], Dict[str, Any]]:
        board = rcs.read_board(self.board_file)
        rel = rcs._find(board, "releases", self.rel_id)
        if rel is None:
            raise CrStageError("release %s not found on %s" % (self.rel_id, self.board_file), rcs.RC_USAGE)
        return board, rel

    def _ts(self) -> str:
        return rcs._iso(self.now())

    @staticmethod
    def _stage(rel: Dict[str, Any]) -> str:
        return release_gate.current_stage(rel)

    @staticmethod
    def _gamma_sha(rel: Dict[str, Any]) -> Optional[str]:
        v = (rel.get("stageSha") or {}).get("GAMMA") if isinstance(rel.get("stageSha"), dict) else None
        return v if isinstance(v, str) and v.strip() else None

    def _platform_name(self) -> str:
        try:
            with open(os.path.join(self.kdir, "config", "wiki.json"), "r", encoding="utf-8") as fh:
                v = json.load(fh).get("platformName")
            return v.strip() if isinstance(v, str) else ""
        except (OSError, ValueError, AttributeError):
            return ""

    def _set_marker(self, **changes: Any) -> None:
        def mut(r: Dict[str, Any]) -> None:
            r["gammaFailure"].update(changes)
        rcs.update_records(self.board_file, [("releases", self.rel_id, mut)])

    def _crstage(self) -> rcs.CrStage:
        if self._cs is None:
            self._cs = rcs.CrStage(self.rel_id, self.tools, self.board_file, self.kdir, self.team, now=self.now,
                                   say=self.say, resolve=self._resolve)
        return self._cs

    # -- preflight --------------------------------------------------------------------------------
    def _preflight(self) -> Dict[str, Any]:
        """Lead check + stage check + resume detection. Writes nothing."""
        board, rel = self._load()
        ok, why = release_gate.actor_is_lead(self.by, board.get("releaseConfig"))
        if not ok:
            raise CrStageError("--by refused: %s. Add the lead to releaseConfig.leads on the board (the same list the "
                               "release lead commands use). Nothing was written." % why, rcs.RC_REFUSED)
        stage, marker, gsha = self._stage(rel), rel.get("gammaFailure"), self._gamma_sha(rel)
        if stage == "GAMMA":
            if marker_active(marker, gsha):
                return {"mode": "resume"}
            if not gsha:
                raise CrStageError("release %s is at GAMMA but has no stageSha.GAMMA; refusing to record a failure "
                                   "against an unknown build" % self.rel_id, rcs.RC_REFUSED)
            if not self.summary:
                raise CrStageError("--summary \"<what failed>\" is required to start the GAMMA failure protocol",
                                   rcs.RC_USAGE)
            return {"mode": "fresh"}
        order = list(release_schema.STAGES)
        if isinstance(marker, dict) and stage in order and order.index(stage) < order.index("GAMMA"):
            return {"mode": "resume"}   # regressed already (by this command or by hand): finish the remaining steps
        raise CrStageError("release %s is at stage %s; the GAMMA failure protocol applies only while it is in GAMMA "
                           "(or to finish a failure already started)" % (self.rel_id, stage), rcs.RC_REFUSED)

    # -- records ----------------------------------------------------------------------------------
    @staticmethod
    def _latest(rel: Dict[str, Any], test: str, gamma_sha: str) -> Optional[Dict[str, Any]]:
        best = None
        for t in rel.get("tests") or []:
            if (isinstance(t, dict) and t.get("stage") == "GAMMA" and t.get("test") == test
                    and str(t.get("sha", "")).lower() == str(gamma_sha).lower() and not t.get("supersededBy")):
                best = t   # tests[] is append-only, so the last one is the latest
        return best

    @staticmethod
    def _fresh_record(rec: Optional[Dict[str, Any]], m: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """A record only counts for THIS failure if it was written at/after the failure started: a retry of the same
        build that fails again must redo the rollback, not inherit the first failure's PASS records."""
        if rec is None:
            return None
        return rec if str(rec.get("ts", "")) >= str(m.get("at", "")) else None

    def _rollback_done(self, rel: Dict[str, Any], test: str) -> bool:
        m = rel.get("gammaFailure") or {}
        rsha = m.get("rollbackSha")
        rec = self._fresh_record(self._latest(rel, test, m.get("gammaSha", "")), m) if rsha else None
        return bool(rec) and rec.get("result") == "PASS" and ("rollbackSha=%s" % rsha) in str(rec.get("notes", ""))

    def _ensure_failed(self) -> None:
        board, rel = self._load()
        if self._stage(rel) != "GAMMA" or not isinstance(rel.get("gammaFailure"), dict):
            return
        st = (rel.get("stages") or {}).get("GAMMA") if isinstance(rel.get("stages"), dict) else None
        if isinstance(st, dict) and st.get("status") == "failed":
            return

        def mut(r: Dict[str, Any]) -> None:   # the /tests endpoint re-derives status from the expected set
            stages = r.get("stages")
            if not isinstance(stages, dict):
                stages = r["stages"] = {}
            g = stages.get("GAMMA")
            if not isinstance(g, dict):
                g = stages["GAMMA"] = {}
            g["status"] = "failed"
        rcs.update_records(self.board_file, [("releases", self.rel_id, mut)])

    # -- is-done (shared by run and status) -------------------------------------------------------
    def _is_done(self, step: str, board: Dict[str, Any], rel: Dict[str, Any]) -> bool:
        m = rel.get("gammaFailure")
        stage = self._stage(rel)
        if step == "stop":
            return isinstance(m, dict) and (marker_active(m, self._gamma_sha(rel)) if stage == "GAMMA" else True)
        if not isinstance(m, dict):
            return False
        if step == "rollback-deploy":
            return self._rollback_done(rel, T_DEPLOY)
        if step == "rollback-smoke":
            return self._rollback_done(rel, T_SMOKE)
        if step == "hold":
            cid = m.get("cr")
            if cid == "":
                return True
            cr = rcs._find(board, "crs", cid) if cid else None
            return bool(cr) and (rcs.is_gamma_held(cr) or cr.get("crState") == "cr-closed")
        if step == "regress":
            return stage != "GAMMA"
        if step == "notify":
            return any(isinstance(n, dict) and n.get("alias") == NOTICE_ALIAS and n.get("template") == NOTICE_TEMPLATE
                       and n.get("ok") is True and str(n.get("ts", "")) >= str(m.get("at", "~"))
                       for n in (rel.get("notices") or []))
        if step == "record":
            rec = m.get("recorded") if isinstance(m.get("recorded"), dict) else {}
            return "testing-log" in rec and (m.get("cr") in ("", None) or "cr-record" in rec) and m.get("cr") is not None
        return False

    # -- run --------------------------------------------------------------------------------------
    def run(self) -> Dict[str, Any]:
        result: Dict[str, Any] = {"release": self.rel_id, "steps": [], "ok": False, "stopped": None, "message": "",
                                  "cr": None, "rollbackSha": None}
        self._preflight()
        impl = {"stop": self._step_stop, "rollback-deploy": self._step_deploy, "rollback-smoke": self._step_smoke,
                "hold": self._step_hold, "regress": self._step_regress, "notify": self._step_notify,
                "record": self._step_record}
        stop_at = STEPS.index(self.only) if self.only else len(STEPS) - 1
        for i, name in enumerate(STEPS):
            if i > stop_at:
                break
            try:
                board, rel = self._load()
                if self._is_done(name, board, rel):
                    status, detail = "skipped", "already done"
                else:
                    status, detail = impl[name]()
            except CrStageError as exc:
                exc.step = exc.step or name
                result["steps"].append({"step": name, "status": "stopped" if exc.rc == RC_NEEDS_LEAD else "failed",
                                        "detail": str(exc)})
                result.update(stopped=name, message=str(exc), rc=exc.rc)
                self._finish(result)
                return result
            except ToolError as exc:
                result["steps"].append({"step": name, "status": "failed", "detail": str(exc)})
                result.update(stopped=name, message=str(exc), rc=RC_FAILED)
                self._finish(result)
                return result
            if name == "regress" and status == "skipped":
                self._stamp_regressed()   # the lead regressed by hand: the failure is no longer in force for GAMMA
            result["steps"].append({"step": name, "status": status, "detail": detail})
            self.say("[%s] %s%s" % (name, status, (": " + detail) if detail else ""))
        result["ok"], result["rc"] = True, RC_OK
        result["message"] = ("GAMMA failure protocol complete" if self.only is None
                             else "ran through step %s" % self.only)
        self._finish(result)
        return result

    def _stamp_regressed(self) -> None:
        _b, rel = self._load()
        m = rel.get("gammaFailure")
        if isinstance(m, dict) and not m.get("regressedAt") and self._stage(rel) != "GAMMA":
            self._set_marker(regressedAt=self._ts())

    def _finish(self, result: Dict[str, Any]) -> None:
        try:
            _b, rel = self._load()
            m = rel.get("gammaFailure") or {}
            result["cr"] = m.get("cr") or None
            result["rollbackSha"] = m.get("rollbackSha")
        except (OSError, ValueError, CrStageError):
            pass

    def status(self) -> List[Dict[str, Any]]:
        """Read-only: which steps are done. Needs no lead (it changes nothing)."""
        board, rel = self._load()
        return [{"step": s, "done": bool(self._is_done(s, board, rel))} for s in STEPS]

    # -- step 1: stop -----------------------------------------------------------------------------
    def _step_stop(self) -> Tuple[str, str]:
        board, rel = self._load()
        gsha, ts = self._gamma_sha(rel), self._ts()
        marker = {"at": ts, "by": self.by, "summary": self.summary, "gammaSha": gsha, "testsStopped": True,
                  "rollbackSha": None, "rollbackShaSource": None, "cr": None, "recorded": {}}

        def mut(r: Dict[str, Any]) -> None:
            prev = r.get("gammaFailure")
            if marker_active(prev, gsha):
                pass   # a concurrent run already stopped this build: never overwrite its progress
            else:
                new = dict(marker)
                if isinstance(prev, dict):   # an earlier failure (another build, or this one before a retry): keep it
                    old = {k: v for k, v in prev.items() if k != "history"}
                    new["history"] = list(prev.get("history") or []) + [old]
                r["gammaFailure"] = new
            stages = r.get("stages")
            if not isinstance(stages, dict):
                stages = r["stages"] = {}
            g = stages.get("GAMMA")
            if not isinstance(g, dict):
                g = stages["GAMMA"] = {}
            g["status"] = "failed"
        rcs.update_records(self.board_file, [("releases", self.rel_id, mut)])
        return "done", "GAMMA marked failed at %s; GAMMA test execution stopped (reported by %s)" % (gsha[:12], self.by)

    # -- steps 2-3: the rollback deploy and its smoke confirmation --------------------------------
    def _pin_rollback_sha(self, rel: Dict[str, Any]) -> str:
        m = rel["gammaFailure"]
        if isinstance(m.get("rollbackSha"), str) and _SHA40.fullmatch(m["rollbackSha"]):
            return m["rollbackSha"]   # pinned on first use: a later override must not retarget a flow in progress
        sha = rel.get("rollbackSha")
        if not isinstance(sha, str) or not _SHA40.fullmatch(sha):
            raise CrStageError(
                "release %s has no usable rollbackSha (%r). A rollback target MUST exist (spec 13.3): production "
                "cannot be redeployed to an unknown SHA. To %s" % (self.rel_id, sha, release_rollback.override_howto(self.rel_id)),
                rcs.RC_REFUSED)
        if sha.lower() == str(m.get("gammaSha", "")).lower():
            raise CrStageError(
                "release %s: rollbackSha %s IS the build that failed (stageSha.GAMMA); redeploying it is not a rollback. "
                "A rollback target MUST be the previous production SHA (spec 13.3). To %s"
                % (self.rel_id, sha[:12], release_rollback.override_howto(self.rel_id)), rcs.RC_REFUSED)
        self._set_marker(rollbackSha=sha, rollbackShaSource=rel.get("rollbackShaSource"))
        return sha

    def _record_rollback_test(self, test: str, result: str, rsha: str, user_notes: str, rel: Dict[str, Any]) -> None:
        gsha = self._gamma_sha(rel)
        notes = "rollbackSha=%s; confirmed by %s" % (rsha, self.by)
        if user_notes:
            notes += "; " + user_notes
        rec = {"stage": "GAMMA", "type": "Automated", "ts": self._ts(), "env": PROD_ENV, "sha": gsha, "test": test,
               "result": result, "runBy": "pipeline", "notes": notes}
        payload: Dict[str, Any] = {"sha": gsha, "records": [rec]}
        st = (rel.get("stages") or {}).get("GAMMA") if isinstance(rel.get("stages"), dict) else None
        st = st if isinstance(st, dict) else {}
        if str(st.get("expectedSha") or "").lower() != str(gsha).lower():
            # /tests refuses a records-only post until an expected set is recorded for THIS sha (XACA-1347-031). A
            # failure declared before any GAMMA test ran (the deploy itself is unhealthy) has none, which stranded the
            # protocol at this step for good. Bind whatever set is recorded (possibly empty) to this build; the
            # endpoint then only lets it be added to, and an empty set still fails the gate.
            exp = st.get("expected")
            payload["expected"] = list(exp) if isinstance(exp, list) else []
        try:
            self.tools.post_tests(self.rel_id, "GAMMA", payload)
        except ToolError as exc:
            raise CrStageError("the %s result was NOT recorded (%s). Re-run with the same flags." % (test, exc), rcs.RC_FAILED)
        self._ensure_failed()   # the endpoint re-derives the stage status; a failed GAMMA stays failed

    def _rollback_step(self, test: str, result: Optional[str], user_notes: str, flag: str, what: str) -> Tuple[str, str]:
        board, rel = self._load()
        step = "rollback-deploy" if test == T_DEPLOY else "rollback-smoke"
        stage = self._stage(rel)
        if stage != "GAMMA":
            # XACA-1432 (XACA-1349-024): the lead regressed the release by hand BEFORE this record existed. The GAMMA
            # /tests endpoint 409s off GAMMA, so recording would fail forever as "re-run". Refuse BEFORE pinning
            # anything: the refused attempt must leave the marker untouched. (A record made before the regress is
            # skipped by _is_done and never reaches here.)
            # The remedy below is the tested one (test_by_hand_regress_then_back_at_gamma_on_the_failed_build_completes):
            # a by-hand regress never stamps regressedAt, so back at GAMMA on the same build the marker governs again.
            raise CrStageError(
                "release %s is at stage %s, no longer at GAMMA, so the %s result cannot be recorded. The GAMMA tests "
                "endpoint only accepts records while the release is at GAMMA; re-running this command as-is cannot "
                "succeed, so nothing was posted and nothing on the failure marker was changed. The hold, notify and "
                "record steps did not run.\n"
                "The rollback records are bound to the failed build (stageSha.GAMMA %s). Either:\n"
                "  - return the release to GAMMA on that same build, then re-run this command; or\n"
                "  - if it cannot return to GAMMA on that build, settle the remaining steps (CR hold, notice, Testing "
                "Log) by hand; this engine has no off-GAMMA record path.\n"
                "Check where the failure stands with:\n"
                "    kb-release gamma-fail %s --status"
                % (self.rel_id, stage, test, str(rel["gammaFailure"].get("gammaSha", "?"))[:12], self.rel_id),
                rcs.RC_REFUSED, step)
        rsha = self._pin_rollback_sha(rel)
        board, rel = self._load()
        if test == T_SMOKE and not self._rollback_done(rel, T_DEPLOY):
            raise CrStageError("the rollback deploy has not been recorded as PASS; run that step first "
                               "(--rollback-result PASS)", rcs.RC_REFUSED)
        if result is None:
            raise CrStageError(
                "STOPPED for the lead: %s. Then re-run:\n    kb-release gamma-fail %s --by %s %s PASS|FAIL [--%s-notes \"...\"]\n"
                "The engine records the %r test; it does not deploy (no deploy provider exists)."
                % (what % rsha, self.rel_id, self.by, flag, "rollback" if test == T_DEPLOY else "smoke", test),
                RC_NEEDS_LEAD, step)
        latest = self._fresh_record(self._latest(rel, test, rel["gammaFailure"]["gammaSha"]), rel["gammaFailure"])
        same = (latest is not None and latest.get("result") == result
                and ("rollbackSha=%s" % rsha) in str(latest.get("notes", "")))
        if not same:
            self._record_rollback_test(test, result, rsha, user_notes, rel)
        if result == "FAIL":
            raise CrStageError("%s reported FAIL: production is NOT confirmed recovered. Fix it, then re-run with %s PASS "
                               "(the FAIL record stays; the new PASS record supersedes it for this protocol)." % (test, flag),
                               rcs.RC_FAILED)
        return "done", "%s PASS recorded against rollbackSha %s (record sha = stageSha.GAMMA, env %s)" % (test, rsha[:12], PROD_ENV)

    def _step_deploy(self) -> Tuple[str, str]:
        return self._rollback_step(T_DEPLOY, self.rb_result, self.rb_notes, "--rollback-result",
                                   "redeploy PRODUCTION from rollbackSha %s")

    def _step_smoke(self) -> Tuple[str, str]:
        return self._rollback_step(T_SMOKE, self.sm_result, self.sm_notes, "--smoke-result",
                                   "run the production smoke checks against the rolled-back build (rollbackSha %s)")

    # -- step 4: hold the CR ----------------------------------------------------------------------
    def _target_cr(self, board: Dict[str, Any], rel: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        try:
            crs, missing = ap._linked_crs(board, rel)
        except Exception as exc:  # noqa: BLE001
            raise CrStageError("cannot read the CRs linked to %s: %s" % (self.rel_id, exc), rcs.RC_REFUSED)
        if missing:
            raise CrStageError("release %s links CR(s) that are not on the board: %s"
                               % (self.rel_id, ", ".join(map(str, missing))), rcs.RC_REFUSED)
        pinned = (rel.get("gammaFailure") or {}).get("cr")
        if pinned:
            return next((c for c in crs if c.get("id") == pinned), None)
        # a CR an EARLIER failure already held is finished business (cr-stage closes it as superseded); counting it
        # here made a second failure refuse "2 open CRs" whenever that close had not happened yet
        live = [c for c in crs if c.get("crState") not in rcs.RETIRED_STATES and not rcs.is_gamma_held(c)]
        if len(live) > 1:
            raise CrStageError("release %s has %d open CRs (%s); close the extras so exactly one remains, then re-run"
                               % (self.rel_id, len(live), ", ".join(c["id"] for c in live)), rcs.RC_REFUSED)
        return live[0] if live else None

    def _step_hold(self) -> Tuple[str, str]:
        board, rel = self._load()
        m = rel["gammaFailure"]
        cr = self._target_cr(board, rel)
        if cr is None:
            self._set_marker(cr="")
            return "skipped", "no open CR is linked to %s (a team without CR support, or none was created)" % self.rel_id
        state = cr.get("crState")
        if rcs.is_gamma_held(cr):
            return "skipped", "%s is already held by a GAMMA failure" % cr["id"]
        if state == "cr-held":
            raise CrStageError("CR %s is on hold for another reason; it is not the GAMMA-failure hold. Resolve it "
                               "(kb-cr resume / close) and re-run" % cr["id"], rcs.RC_REFUSED)
        if state not in ("deployed-prod", "emergency-deployed", "cr-approved", "cr-submitted"):
            raise CrStageError("CR %s is in state %r; kb-cr hold applies from deployed-prod (the normal GAMMA case), "
                               "emergency-deployed (spec 13.5 step 4), cr-approved or cr-submitted" % (cr["id"], state),
                               rcs.RC_REFUSED)
        rsha = m["rollbackSha"]
        stamp = {"at": m["at"], "summary": m["summary"], "rollbackSha": rsha, "release": self.rel_id,
                 "gammaSha": m["gammaSha"]}
        # Marker FIRST, hold second: a crash between them leaves a marked, still-live CR (harmless: cr-stage only
        # skips CRs that are BOTH held and marked), whereas hold-then-marker would leave an unmarked held CR that
        # cr-stage would refuse as "on hold" forever.
        rcs.update_records(self.board_file, [("crs", cr["id"], lambda r, s=stamp: r.__setitem__("gammaFailure", s)),
                                             ("releases", self.rel_id, lambda r, c=cr["id"]: r["gammaFailure"].__setitem__("cr", c))])
        try:
            self.tools.cr_hold(cr["id"], _reason(m["summary"], rsha))
        except ToolError as exc:
            raise CrStageError("kb-cr hold %s failed (%s). The failure is recorded; re-run to retry the hold."
                               % (cr["id"], exc), rcs.RC_FAILED)
        return "done", "%s held (%s)" % (cr["id"], _reason(m["summary"], rsha))

    # -- step 5: regress --------------------------------------------------------------------------
    def _step_regress(self) -> Tuple[str, str]:
        board, rel = self._load()
        m = rel["gammaFailure"]
        try:
            self.tools.regress(self.rel_id, REGRESS_TO, _reason(m["summary"], m["rollbackSha"]), self.by)
        except ToolError as exc:
            raise CrStageError("regress to %s failed (%s). The rollback and hold are done; re-run to retry the regress."
                               % (REGRESS_TO, exc), rcs.RC_REFUSED if exc.rc == 3 else RC_FAILED)
        self._set_marker(regressedAt=self._ts())
        return "done", "regressed %s GAMMA -> %s (the fix ships under a new CR)" % (self.rel_id, REGRESS_TO)

    # -- step 6: notify ---------------------------------------------------------------------------
    def _step_notify(self) -> Tuple[str, str]:
        board, rel = self._load()
        m = rel["gammaFailure"]
        cr = rcs._find(board, "crs", m.get("cr")) if m.get("cr") else None
        try:
            relr = rcs.rcf.release_record_for_facts(rel, cr=cr, platform_name=self._platform_name())
        except ValueError as exc:
            raise CrStageError("cannot assemble the notice facts: %s" % exc, rcs.RC_REFUSED)
        data = {"release": {"id": self.rel_id, "version": relr.get("version", ""), "platform": relr.get("platform", "")},
                "rollback": {"sha": m["rollbackSha"], "summary": m["summary"]},
                "cr": {"id": (cr or {}).get("id", "")},
                "links": {"testingLog": (rcs.get_wiki_handle(rel, "testing-log") or {}).get("url", "")}}
        try:
            self.tools.notify_send(NOTICE_ALIAS, NOTICE_TEMPLATE, self.rel_id, data)
        except ToolError as exc:
            if exc.rc == 3:
                raise CrStageError("the %s notice may have been SENT but its receipt could not be written (%s). Check the "
                                   "channel before re-running (a re-run sends again)." % (NOTICE_ALIAS, exc), rcs.RC_FAILED)
            raise CrStageError("the %s notice was not delivered (%s). Everything before it is done; fix notify.json / the "
                               "secret and re-run." % (NOTICE_ALIAS, exc), rcs.RC_FAILED)
        return "done", "%s notified (%s)" % (NOTICE_ALIAS, NOTICE_TEMPLATE)

    # -- step 7: re-publish the evidence ----------------------------------------------------------
    def _step_record(self) -> Tuple[str, str]:
        board, rel = self._load()
        m = rel["gammaFailure"]
        rec = dict(m.get("recorded") or {})
        notes: List[str] = []
        cr = rcs._find(board, "crs", m.get("cr")) if m.get("cr") else None
        if "testing-log" not in rec:
            handle = rcs.get_wiki_handle(rel, "testing-log")
            if handle is None:
                # Never create a page here (spec: use the stored handle). CR teams published it at the CR stage.
                notes.append("no Testing Log page was ever published for this release; not creating one now")
                rec["testing-log"] = "none"
            else:
                cs = self._crstage()
                facts = cs._facts(board, rel, cr, content=(cr or {}).get("draftContent"))
                body, title = cs._compose_testing_log(facts, rel, cs._tz(board))
                h = cs._publish_page("testing-log", self.rel_id, title, body, handle)
                rcs.set_wiki_handle(self.board_file, "releases", self.rel_id, "testing-log", h, links={"testingLog": h["url"]})
                rec["testing-log"] = self._ts()
                self._set_marker(recorded=dict(rec))
                notes.append("Testing Log re-published (v%d)" % h["version"])
        if m.get("cr") and "cr-record" not in rec:
            try:
                self.tools.cr_publish_record(m["cr"])
            except ToolError as exc:
                raise CrStageError("the Testing Log is up to date but the cr-record for %s was not published (%s). Re-run "
                                   "to retry (kb-cr publish-record %s)." % (m["cr"], exc, m["cr"]), rcs.RC_FAILED)
            rec["cr-record"] = self._ts()
            notes.append("cr-record published for %s" % m["cr"])
        self._set_marker(recorded=rec)
        return "done", "; ".join(notes)


# ---------------------------------------------------------------------------------------- CLI

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="kb-release gamma-fail",
                                description="Resumable GAMMA failure protocol (spec 13.3): stop, record the rollback "
                                            "deploy + smoke, hold the CR, regress to DEV, notify, re-publish the record.")
    p.add_argument("release")
    p.add_argument("--team", required=True)
    p.add_argument("--kanban-dir", required=True)
    p.add_argument("--board-file", default=None)
    p.add_argument("--helpers", default=os.environ.get("KB_HELPERS_PATH", ""), help="path to kanban-helpers.sh")
    p.add_argument("--port", type=int, default=8080, help="LCARS port of the team (tests + regress endpoints)")
    p.add_argument("--by", default=None, help="the lead confirming the rollback (must be in releaseConfig.leads; not needed with --status)")
    p.add_argument("--summary", default=None, help="what failed (required to start; stored, so re-runs may omit it)")
    p.add_argument("--rollback-result", default=None, metavar="PASS|FAIL", help="outcome of redeploying production from rollbackSha")
    p.add_argument("--rollback-notes", default=None, help="evidence for the rollback deploy (required with FAIL)")
    p.add_argument("--smoke-result", default=None, metavar="PASS|FAIL", help="outcome of the production smoke re-run on rollbackSha")
    p.add_argument("--smoke-notes", default=None, help="evidence for the smoke re-run (required with FAIL)")
    p.add_argument("--step", choices=STEPS, default=None, help="run only through this step")
    p.add_argument("--status", action="store_true", help="show which steps are done; change nothing")
    p.add_argument("--json", action="store_true", help="print the result as one JSON line (the last stdout line)")
    return p


def main(argv: Optional[List[str]] = None, *, tools: Any = None, resolve: Optional[Callable[..., Any]] = None,
         now: Optional[Callable[[], datetime]] = None) -> int:
    a = build_parser().parse_args(argv)
    try:
        board_file = rcs._locate_board(a.kanban_dir, a.team, a.release, a.board_file)
        tools = tools or GammaTools(a.team, a.kanban_dir, os.getcwd(), a.helpers, port=a.port)
        say = (lambda s: print(s, file=sys.stderr)) if a.json else print
        if not a.by and not a.status:
            print("kb-release gamma-fail: --by <lead> is required (the lead confirms the rollback)", file=sys.stderr)
            return RC_USAGE
        gf = GammaFailure(a.release, tools, board_file, a.kanban_dir, a.team, by=a.by or "-", summary=a.summary,
                          rollback_result=a.rollback_result, rollback_notes=a.rollback_notes,
                          smoke_result=a.smoke_result, smoke_notes=a.smoke_notes, only_step=a.step, now=now,
                          say=say, resolve=resolve)
        if a.status:
            rows = gf.status()
            if a.json:
                print(json.dumps({"release": a.release, "steps": rows}))
            else:
                for r in rows:
                    print("%-16s %s" % (r["step"], "done" if r["done"] else "pending"))
            return RC_OK
        result = gf.run()
    except (OSError, ValueError) as exc:
        print("kb-release gamma-fail: %s" % exc, file=sys.stderr)
        return RC_USAGE
    except CrStageError as exc:
        print("kb-release gamma-fail: %s" % exc, file=sys.stderr)
        return exc.rc
    if a.json:
        print(json.dumps(result))
    if not result["ok"]:
        print("kb-release gamma-fail: step '%s' stopped:\n%s" % (result["stopped"], result["message"]), file=sys.stderr)
    return result.get("rc", RC_FAILED)


if __name__ == "__main__":
    sys.exit(main())
