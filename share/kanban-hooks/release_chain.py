"""
release_chain.py -- the auto-promote chain driver behind `kb-release chain` (XACA-1350-005, spec 3.3 / 5.3).

Stdlib only, py3.9-safe. The chain is deterministic: every decision is read from release_resume.resume_plan (so the
chain and the resume dispatcher can never disagree) and every promote is the SAME gated endpoint any caller uses,
POST /api/releases/<id>/promote. This module never writes stage state; it only asks.

Edges (release_resume.auto_edge, spec 3.3 rule 2): QA->ALPHA, ALPHA->BETA, BETA->CR, and those edges with intervening
stages disabled. Never DEV->QA, never into DEV or GAMMA, never from CR. A non-CR team's BETA stops "GAMMA-ready".

Loop (rule 4): plan -> run the stage's missing automated tests -> re-plan -> when the stage passed, dry-run the promote
(the server reports the gate's reasons; in report mode a refusal would still proceed, so ANY blocking reason stops
the chain here) -> promote -> the next iteration runs the new stage's providers. Stops, with a named reason:
  stage-failed (6) | manual-needs-lead (5) | gate-refused (3) | tests-refused (3) | stage-sha-missing (7) |
  no-progress (1) | transport/provider error (1) |
  gamma-ready, cr-entered, human-gate, not-auto-source, dry-run (0: nothing wrong, the lead's move).
"""
import argparse
import json
import sys
import urllib.error
import urllib.request

import release_resume
import release_stage_cli
import release_walkthrough
from release_gate import INFORMATIONAL_CODES

RC_OK, RC_ERROR, RC_USAGE, RC_REFUSED, RC_MANUAL, RC_FAILED, RC_NOSHA = 0, 1, 2, 3, 5, 6, 7


class ChainError(Exception):
    pass


def http_promote(base_url, release_id, target, actor, dry_run, timeout=60):
    """POST the gated promote -> (http_code, body dict). HTTP errors are RETURNED (a 409 is a verdict); only a
    transport failure raises ChainError."""
    payload = {"targetStage": target, "actor": actor, "dryRun": bool(dry_run)}
    req = urllib.request.Request("%s/api/releases/%s/promote" % (base_url.rstrip("/"), release_id),
                                 data=json.dumps(payload).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    key = release_walkthrough._bearer_key()
    if key:
        req.add_header("Authorization", "Bearer " + key)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.getcode(), json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode(errors="replace") or "{}")
        except ValueError:
            return e.code, {}
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise ChainError("transport failure: %s" % (e,))


def _blocking(body):
    codes = body.get("reasonCodes") or []
    return [r for i, r in enumerate(body.get("reasons") or [])
            if not (i < len(codes) and codes[i] in INFORMATIONAL_CODES)]


def run_chain(release_id, *, get_plan, run_tests, promote, dry_run=False, max_steps=12):
    """-> {"stop", "rc", "steps"[], "plan", "message"}. get_plan() -> plan; run_tests() -> rc of `kb-release test
    --only-missing`; promote(target, dry_run) -> (code, body). All three are injected (tests drive fakes)."""
    steps, last = [], None

    def end(stop, rc, plan, message=""):
        return {"stop": stop, "rc": rc, "steps": steps, "plan": plan, "message": message or plan["headline"]}

    for _ in range(max_steps):
        plan = get_plan()
        row, cur, run = plan["row"], plan["stage"], plan["run"]
        if cur not in release_resume.AUTO_SOURCES and not (cur == "CR" and steps):
            return end("not-auto-source" if cur != "CR" else "human-gate", RC_OK, plan,
                       "stage %s is not an auto-promote source; the chain only runs QA/ALPHA/BETA (spec 3.3)" % cur)
        if cur == "CR":
            return end("cr-entered", RC_OK, plan, "entered CR: run `kb-release cr-stage %s` (the lead approves the draft)" % release_id)
        if row == "stage-sha-missing":
            return end("stage-sha-missing", RC_NOSHA, plan,
                       "stageSha.%s is not recorded, so nothing can run or be graded (the promote endpoint records it "
                       "on entry to QA/ALPHA/BETA; a release promoted before that needs `kb-release new-sha`)" % cur)
        if row == "tests-failed":
            return end("stage-failed", RC_FAILED, plan)
        if row == "tests-running" and plan["action"] == "walkthrough":
            return end("manual-needs-lead", RC_MANUAL, plan,
                       "%s needs the lead: kb-release walkthrough %s (next case: %s)" % (cur, release_id, run["manualFirst"]))
        if row == "tests-running":
            key = (cur, plan["stageSha"], tuple(run["missingAutomated"]), run["all"])
            if key == last:
                return end("no-progress", RC_ERROR, plan, "the test run recorded nothing new for %s; stopping" % cur)
            last = key
            if dry_run:
                steps.append({"step": "would-run-tests", "stage": cur})
                return end("dry-run", RC_OK, plan)
            rc = run_tests()
            steps.append({"step": "tests", "stage": cur, "rc": rc})
            if rc == RC_REFUSED:
                return end("tests-refused", RC_REFUSED, plan, "the test run was refused (SHA/tree check or stale stage)")
            if rc not in (RC_OK, RC_FAILED):
                return end("tests-error", RC_ERROR, plan, "kb-release test failed (rc %s)" % rc)
            continue
        if row == "stage-passed" and plan["action"] == "chain":
            target = plan["edge"]
            code, body = promote(target, True)
            if code != 200 or body.get("to") != target or _blocking(body):
                return end("gate-refused", RC_REFUSED, plan, "promote %s -> %s would not pass the gate: %s" % (
                    cur, target, "; ".join(_blocking(body)) or body.get("error") or "HTTP %s" % code))
            if dry_run:
                steps.append({"step": "would-promote", "from": cur, "to": target})
                return end("dry-run", RC_OK, plan)
            code, body = promote(target, False)
            if code != 200 or body.get("to") != target:
                return end("gate-refused", RC_REFUSED, plan, "promote %s -> %s refused: %s" % (
                    cur, target, "; ".join(body.get("reasons") or []) or body.get("error") or "HTTP %s" % code))
            steps.append({"step": "promote", "from": cur, "to": target})
            continue
        if row == "gamma-ready":
            return end("gamma-ready", RC_OK, plan)
        return end("human-gate", RC_OK, plan)
    return end("no-progress", RC_ERROR, get_plan(), "chain did not settle in %d steps" % max_steps)


def main(argv=None):
    ap = argparse.ArgumentParser(description="kb-release chain (XACA-1350-005)")
    ap.add_argument("--release", required=True)
    ap.add_argument("--kanban-dir", required=True)
    ap.add_argument("--repo-dir", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--actor", required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    base = "http://localhost:%d" % a.port
    ns = argparse.Namespace(release=a.release, kanban_dir=a.kanban_dir, repo_dir=a.repo_dir, port=a.port,
                            include_scheduled=False, dry_run=False, only_missing=True, provider=None)
    try:
        res = run_chain(a.release,
                        get_plan=lambda: release_resume.load_plan(a.kanban_dir, a.release, a.repo_dir),
                        run_tests=lambda: release_stage_cli.cmd_test(ns),
                        promote=lambda t, d: http_promote(base, a.release, t, a.actor, d),
                        dry_run=a.dry_run)
    except (ChainError, release_resume.RunnerError) as e:
        print("release_chain: %s" % (e,), file=sys.stderr)
        return RC_ERROR
    if a.json:
        print(json.dumps({k: res[k] for k in ("stop", "rc", "steps", "message")}))
    else:
        for s in res["steps"]:
            print("  step: %s" % json.dumps(s))
        print("chain stopped: %s -- %s" % (res["stop"], res["message"]))
    return res["rc"]


if __name__ == "__main__":
    sys.exit(main())
