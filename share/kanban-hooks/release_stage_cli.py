"""
release_stage_cli.py -- glue behind `kb-release test` / `kb-release walkthrough` (XACA-1347-007).

Stdlib only, py3.9-safe. kanban-helpers.sh does the bash-side work (team context, port, kanban
dir, argument validation) and calls this module; ALL the release logic lives in the sibling
libraries (release_runner / release_providers / release_walkthrough). This file only wires them.

Subcommands
  test         run the CURRENT stage's AUTOMATED providers, POST the result to
               /api/releases/<id>/stages/<STAGE>/tests
  walkthrough  resolve the current stage + manual provider, then hand off to
               release_walkthrough.main (the interactive flow lives there)

SHA handling is VERIFY ONLY. Spec 7.2 says the engine checks out stageSha[STAGE]; that belongs
to the release worktree that XACA-1352 / XACA-1350 create. This CLI never runs `git checkout`:
it refuses (rc 3) when HEAD != stageSha[STAGE] or the tree is dirty, and says which SHA to check
out and where. Running tests against "whatever happens to be checked out" is the failure mode
this refusal exists to prevent.

--dry-run: posts nothing and never runs a test command. It DOES run each provider's listCommand
(enumeration only, the same call the real run makes) because the expected set cannot be shown
otherwise; when the SHA check would refuse, even that is skipped and the plan is printed from
the config alone.

Exit codes: 0 ok | 1 server/transport error | 2 usage, config or rejected request (400) |
3 refused (SHA/tree check, or 409 stale/not-current stage) | 4 not found (404) |
6 results were recorded but at least one top-level record is FAIL.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

import release_walkthrough
from release_gate import TEST_STAGES, current_stage
from release_providers import ProvidersError, load_providers, providers_for_stage
from release_runner import RunnerError, build_expected, check_gamma, run_stage, verify_stage_sha

RC_OK, RC_TRANSPORT, RC_USAGE, RC_REFUSED, RC_NOTFOUND, RC_FAILING = 0, 1, 2, 3, 4, 6


class StagePostError(Exception):
    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code = code


def verify_only(repo_dir, sha):
    """verify_stage_sha with checkout=False; the refusal names the SHA and the directory."""
    try:
        return verify_stage_sha(repo_dir, sha, checkout=False)
    except RunnerError as e:
        raise RunnerError("%s\n  stage SHA is %s; check it out in %s with a clean tree, then re-run "
                          "(kb-release test never runs git checkout)" % (e, sha, repo_dir))


def post_tests(base_url, release_id, stage, payload, timeout=60):
    """POST the run to the /tests endpoint -> decoded JSON. Raises StagePostError(code, msg)."""
    url = "%s/api/releases/%s/stages/%s/tests" % (base_url.rstrip("/"), release_id, stage)
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST",
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
        raise StagePostError(e.code, str(msg)[:400])
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise StagePostError(0, "transport failure: %s" % (e,))


def _rc_for_http(code):
    return {409: RC_REFUSED, 404: RC_NOTFOUND, 400: RC_USAGE}.get(code, RC_TRANSPORT)


def _context(a):
    """-> (release, stage, sha, providers) or raises RunnerError/ProvidersError."""
    release = release_walkthrough._load_release(a.kanban_dir, a.release)
    stage = current_stage(release)
    if stage not in TEST_STAGES:
        raise RunnerError("release %s is at stage %s, which has no test set (test stages: %s)"
                          % (a.release, stage, ", ".join(TEST_STAGES)))
    doc = load_providers(os.path.join(a.kanban_dir, "config", "test-providers.json"))
    providers = providers_for_stage(doc, stage)
    if not providers:
        raise RunnerError("test-providers.json declares no providers for %s; refusing to treat "
                          "that as 'nothing to test'" % stage)
    return release, stage, (release.get("stageSha") or {}).get(stage), providers


def _plan_lines(providers, include_scheduled):
    lines = []
    for p in providers:
        if p.get("kind") == "manual":
            lines.append("  [manual]    %s  cases=%s  -> `kb-release walkthrough` (not run here)"
                         % (p["name"], p.get("cases")))
            continue
        if p.get("schedule") and not include_scheduled:
            verdict = "SKIP (scheduled %s; --include-scheduled to run)" % p["schedule"]
        else:
            verdict = "WOULD RUN"
        lines.append("  [automated] %s  parser=%s perFile=%s  -> %s\n              command: %s"
                     % (p["name"], p.get("parser"), bool(p.get("perFile")), verdict, p.get("command")))
    return lines


def _gamma_failed_refusal(release, stage, sha, verb, rel_id):
    """XACA-1349-005 (spec 13.3 step 1): after `kb-release gamma-fail` the session halts further GAMMA tests of
    EVERY kind (automated `test` and manual `walkthrough`) for the build that failed. Scoped to that SHA and to the
    failure still being in force: once the release was regressed out of GAMMA for it (marker.regressedAt) a re-entry
    of GAMMA, on a new SHA or the same one, is free to test again. Returns the refusal text, or None."""
    gf = release.get("gammaFailure")
    if stage != "GAMMA" or gf is None:
        return None
    if not isinstance(gf, dict):
        return "kb-release %s: refused: release.gammaFailure is malformed; fix it before testing GAMMA" % verb
    if not sha or str(gf.get("gammaSha", "")).lower() != str(sha).lower() or gf.get("regressedAt"):
        return None
    return ("kb-release %s: refused: GAMMA failed at %s (gamma-fail at %s: %s); no further GAMMA tests run for this "
            "build. Finish the protocol (kb-release gamma-fail %s --status); the fix re-enters GAMMA on a new SHA."
            % (verb, str(sha)[:12], gf.get("at", "?"), gf.get("summary", "?"), rel_id))


def missing_tests(release, stage, sha):
    """Names of the stage's expected tests with NO current record at `sha` (spec 6.4 grading, release_gate._grade), or
    None when no expected set is stored for this SHA (nothing is known to be current: run everything)."""
    import release_gate
    st = (release.get("stages") or {}).get(stage) or {}
    exp = st.get("expected")
    if not release_gate._norm_expected(exp) or str(st.get("expectedSha") or "").lower() != str(sha or "").lower():
        return None
    return {n for n, o, _w in release_gate._grade(exp, release.get("tests"), sha, st.get("waiver"), stage)
            if o == "missing"}


def cmd_test(a, *, run=None, post=None, out=None):
    import subprocess
    run = run or subprocess.run
    post = post or post_tests
    out = out or sys.stdout

    def say(s=""):
        print(s, file=out)

    try:
        release, stage, sha, providers = _context(a)
        check_gamma(stage, providers)
    except (RunnerError, ProvidersError) as e:
        print("kb-release test: %s" % (e,), file=sys.stderr)
        return RC_USAGE
    refusal = _gamma_failed_refusal(release, stage, sha, "test", a.release)
    if refusal:
        print(refusal, file=sys.stderr)
        return RC_REFUSED
    only = None
    if getattr(a, "provider", None):   # XACA-1350-004: an explicit provider (a due soak slot) re-runs by design
        providers = [p for p in providers if p["name"] in a.provider]
        if not providers:
            print("kb-release test: no %s provider named %s" % (stage, ", ".join(a.provider)), file=sys.stderr)
            return RC_USAGE
    elif getattr(a, "only_missing", False):
        only = missing_tests(release, stage, sha)
        if only is not None and not only:
            say("Nothing to run: every expected test of %s stage %s has a current record at %s"
                % (a.release, stage, str(sha)[:12]))
            return RC_OK
    if a.dry_run:
        return _dry_run(a, release, stage, sha, providers, run, say)
    try:
        result = run_stage(release, stage, providers, repo_dir=a.repo_dir, kanban_dir=a.kanban_dir,
                           verify=verify_only, include_scheduled=a.include_scheduled or bool(getattr(a, "provider", None)),
                           run=run, only=only)
    except RunnerError as e:  # SHA/tree refusal or missing stageSha: nothing ran, nothing posted
        print("kb-release test: refused: %s" % (e,), file=sys.stderr)
        return RC_REFUSED

    for pr in result["problems"]:
        print("  problem: %s" % pr, file=sys.stderr)
    payload = {"sha": sha, "expected": result["expected"], "records": result["records"]}
    try:
        resp = post("http://localhost:%d" % a.port, a.release, stage, payload)
    except StagePostError as e:
        print("kb-release test: results NOT recorded (HTTP %s): %s" % (e.code or "-", e), file=sys.stderr)
        return _rc_for_http(e.code)
    tops = [r for r in result["records"] if not r.get("parentRef")]
    failing = [r for r in tops if r.get("result") == "FAIL"]
    say("Recorded %d record(s) for %s stage %s at %s (%d expected test(s))"
        % (len(result["records"]), a.release, stage, sha[:12], len(result["expected"])))
    say("  top-level: %d PASS, %d FAIL, %d SKIP" % tuple(
        sum(1 for r in tops if r.get("result") == k) for k in ("PASS", "FAIL", "SKIP")))
    for r in failing:
        say("  FAIL %s: %s" % (r.get("test"), (r.get("notes") or "")[:200]))
    say("  ids: %s" % ", ".join((resp.get("ids") or [])[:5] + (["..."] if len(resp.get("ids") or []) > 5 else [])))
    return RC_FAILING if failing or result["problems"] else RC_OK


def _dry_run(a, release, stage, sha, providers, run, say):
    say("DRY RUN: %s stage %s  stageSha=%s" % (a.release, stage, sha or "<none>"))
    say("Providers:")
    for line in _plan_lines(providers, a.include_scheduled):
        say(line)
    if not sha:
        say("WOULD REFUSE: release has no stageSha.%s" % stage)
        return RC_REFUSED
    try:
        verify_only(a.repo_dir, sha)
    except RunnerError as e:
        say("WOULD REFUSE: %s" % e)
        say("(expected set not enumerated: listing the wrong tree would be misleading)")
        return RC_REFUSED
    say("SHA check: HEAD == stageSha, tree clean")
    expected, problems = build_expected(providers, repo_dir=a.repo_dir, kanban_dir=a.kanban_dir, run=run)
    say("Expected set (%d):" % len(expected))
    for e in expected:
        say("  - %s" % (e["test"] + " (optional)" if isinstance(e, dict) else e))
    for pr in problems:
        say("  problem: %s" % pr)
    say("Nothing was run and nothing was posted.")
    return RC_OK if not problems else RC_FAILING


def cmd_walkthrough(a):
    try:
        release = release_walkthrough._load_release(a.kanban_dir, a.release)
        stage = current_stage(release)
        if stage not in TEST_STAGES:
            raise RunnerError("release %s is at stage %s, which has no test set" % (a.release, stage))
        doc = load_providers(os.path.join(a.kanban_dir, "config", "test-providers.json"))
        manual = [p["name"] for p in providers_for_stage(doc, stage) if p.get("kind") == "manual"]
        refusal = _gamma_failed_refusal(release, stage, (release.get("stageSha") or {}).get(stage), "walkthrough",
                                        a.release)
        if refusal:
            print(refusal, file=sys.stderr)
            return RC_REFUSED
        name = a.provider
        if not name:
            if len(manual) != 1:
                raise RunnerError("%d manual providers for %s (%s); pick one with --provider"
                                  % (len(manual), stage, ", ".join(manual) or "none"))
            name = manual[0]
    except (RunnerError, ProvidersError) as e:
        print("kb-release walkthrough: %s" % (e,), file=sys.stderr)
        return RC_USAGE
    return release_walkthrough.main(["--release", a.release, "--stage", stage, "--provider", name,
                                     "--kanban-dir", a.kanban_dir, "--lead", a.lead,
                                     "--port", str(a.port)] + (["--json"] if getattr(a, "json", False) else []))


def build_parser():
    ap = argparse.ArgumentParser(description="kb-release test/walkthrough glue (XACA-1347-007)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("test")
    t.add_argument("--release", required=True)
    t.add_argument("--kanban-dir", required=True)
    t.add_argument("--repo-dir", required=True)
    t.add_argument("--port", type=int, required=True)
    t.add_argument("--include-scheduled", action="store_true")
    t.add_argument("--dry-run", action="store_true")
    t.add_argument("--only-missing", action="store_true",
                   help="run only the expected tests with no current record (XACA-1350-004, spec 5.2)")
    t.add_argument("--provider", action="append", default=None,
                   help="run only this provider (repeatable; includes scheduled ones). XACA-1350-004")
    w = sub.add_parser("walkthrough")
    w.add_argument("--release", required=True)
    w.add_argument("--kanban-dir", required=True)
    w.add_argument("--port", type=int, required=True)
    w.add_argument("--lead", required=True)
    w.add_argument("--provider", default=None)
    w.add_argument("--json", action="store_true", help="end summary as one JSON line (XACA-1347-045)")
    return ap


def main(argv=None):
    a = build_parser().parse_args(argv)
    return cmd_test(a) if a.cmd == "test" else cmd_walkthrough(a)


if __name__ == "__main__":
    sys.exit(main())
