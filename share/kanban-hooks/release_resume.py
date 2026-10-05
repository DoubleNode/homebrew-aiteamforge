"""
release_resume.py -- `kb-run <REL-ID>`: resume dispatcher + release worktree attach (XACA-1350-003/004,
spec RELEASE-LIFECYCLE 5.1 / 5.2 / 3.3).

Stdlib only, py3.9-safe. resume_plan() is PURE (no I/O, no clock unless `now` is omitted): the release record plus a
few pre-resolved facts in, a structured plan out. It never re-implements a rule: the gate's own grader
(release_gate._grade -- the "current record" rule of spec 6.4) decides passed/failed/missing, and the PLANNED / GAMMA
questions are asked of release_gate.evaluate. NEVER re-runs a record that is still current: a test with a current
PASS is not in any `run` list.

CLI (`kb-run` calls it; the session prompt embeds its text):
  plan      --release R --kanban-dir D [--repo-dir G] [--json]   print the resume plan
  worktree  --release R --kanban-dir D --repo-dir G --worktree-dir W   attach to / create the release worktree

Exit codes: 0 ok | 2 usage/config, no branch (PLANNED), branch not found | 4 release not found.
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

import release_branches
import release_gate as G
from release_runner import RunnerError, _git

AUTO_SOURCES = ("QA", "ALPHA", "BETA")      # spec 3.3 rule 2: QA->ALPHA, ALPHA->BETA, BETA->CR, and with disabled gaps
AUTO_TARGETS = ("ALPHA", "BETA", "CR")
_OFFSET = re.compile(r"T\+([0-9]+)([hm])")


def auto_edge(cur, flow_config, cr_support_enabled):
    """The stage an auto-promote from `cur` would enter, or None. Spec 3.3: only from QA/ALPHA/BETA, only into
    the NEXT enabled stage, and only if that is ALPHA/BETA/CR. Never DEV->QA, never into GAMMA/PROD, never from CR."""
    if cur not in AUTO_SOURCES:
        return None
    order = G.enabled_stages(flow_config, cr_support_enabled=cr_support_enabled)
    later = [s for s in order if G.STAGES.index(s) > G.STAGES.index(cur)]
    return later[0] if later and later[0] in AUTO_TARGETS else None


def _eq(a, b):
    return bool(a) and bool(b) and str(a).lower() == str(b).lower()


def _slots(scheduled, tests, sha, t0, now):
    """GAMMA soak slots: one per (scheduled provider, offset). A slot is DONE once every test of that provider has a
    current record stamped at or after dueAt (the record carries no 'which slot' field, so time is the only key)."""
    cur = G._current_index(tests, "GAMMA", sha)
    out = []
    for p in scheduled or ():
        for off in p.get("schedule") or ():
            m = _OFFSET.fullmatch(str(off))
            if not m or t0 is None:
                out.append({"provider": p["provider"], "offset": off, "dueAt": None, "status": "unknown"})
                continue
            due = t0 + (timedelta(hours=int(m.group(1))) if m.group(2) == "h" else timedelta(minutes=int(m.group(1))))
            names = p.get("tests") or []
            done = bool(names) and all(
                n in cur and (G._parse_ts(cur[n].get("ts")) or t0 - timedelta(days=1)) >= due for n in names)
            out.append({"provider": p["provider"], "offset": off, "dueAt": due.isoformat(),
                        "status": "done" if done else ("due" if now >= due else "waiting")})
    return out


def resume_plan(release, *, flow_config, cr_support_enabled, items=None, other_releases=None, manual_tests=(),
                scheduled=(), cr=None, branch_head=None, now=None):
    """-> plan dict {release, stage, stageSha, branch, row, action, headline, lines[], offer, run{}}.

    row = the spec 5.2 table row (planned | dev-items-open | dev-deploy-pending | tests-running | tests-failed |
    cr-draft-not-approved | cr-submitted | gamma-soak-pending) or one of the follow-on rows the table implies
    (stage-passed, gamma-ready, gamma-passed, cr-stage-incomplete, cr-held, gamma-failed, stage-sha-missing, terminal).
    action = what the session does next. `items` [{id,title,status,prMerged}], `scheduled` [{provider, schedule[],
    tests[]}], `cr` {id, crState, draftApproved, feed} (feed = approval_providers.release_cr_feed) are pre-resolved by
    the loader; None means "could not read" and fails closed."""
    now = now or datetime.now(timezone.utc)
    cur, rid = G.current_stage(release), release.get("id")
    sha = G.graded_sha(release, cur)
    tests = release.get("tests") or []
    plan = {"release": rid, "stage": cur, "stageSha": sha, "branch": release.get("branch"), "row": None, "action": None,
            "headline": "", "lines": [], "offer": None, "edge": None,
            "run": {"missingAutomated": [], "manualRemaining": [], "manualFirst": None, "soakDue": [], "all": False}}

    def done(row, action, headline, *lines, offer=None):
        plan.update(row=row, action=action, headline=headline, offer=offer)
        plan["lines"].extend(ln for ln in lines if ln)
        return plan

    def promote_offer(target, **kw):
        return dict({"promote": target, "confirmDeploy": target == G.deploy_confirm_stage(
            G.enabled_stages(flow_config, cr_support_enabled=cr_support_enabled))}, **kw)

    if cur == "PROD":
        return done("terminal", "none", "Release is at PROD (terminal): nothing to resume.")
    if cur == "PLANNED":
        v = G.evaluate(release, "DEV", flow_config, cr_support_enabled=cr_support_enabled,
                       context={"items": items, "other_releases": other_releases})
        if v["allowed"]:
            return done("planned", "offer-dev-promote", "PLANNED: assignment and version checks pass.",
                        "Offer the DEV promote; it cuts releases/<ver> and records branch/branchBaseSha.",
                        offer=promote_offer("DEV"))
        return done("planned", "fix-planning", "PLANNED: the DEV promote would be refused.",
                    *["unmet: " + r for r in v["reasons"]])
    if cur == "DEV":
        bad = [it for it in (items or []) if it.get("status") != "completed" or not it.get("prMerged")]
        if items is None or not items or bad:
            lines = ["cannot read the assigned items" if items is None else
                     ("no items are assigned" if not items else "open items (work them in their own item sessions):")]
            lines += ["  %s [%s] %s  PR merged into release branch: %s" % (
                it.get("id"), it.get("status"), it.get("title", ""), "yes" if it.get("prMerged") else "no") for it in bad]
            return done("dev-items-open", "report-items", "DEV: items are still open.", *lines)
        if not sha:
            return done("dev-deploy-pending", "offer-dev-deploy",
                        "DEV: every item is completed and merged, but no DEV deploy is recorded.",
                        "Offer the DEV deploy from the release branch (the lead confirms), then run the DEV tests.")
    if cur == "CR":
        return _cr_row(release, plan, done, promote_offer, cr, branch_head, flow_config, cr_support_enabled, now)
    if not sha:
        return done("stage-sha-missing", "record-stage-sha", "%s: stageSha.%s is not recorded." % (cur, cur),
                    "Nothing can run or be graded without it (release_stage_cli refuses). Branch HEAD: %s" % branch_head)

    gf = release.get("gammaFailure")
    if cur == "GAMMA" and gf is not None and (not isinstance(gf, dict) or (
            not gf.get("regressedAt") and _eq(gf.get("gammaSha"), sha))):
        return done("gamma-failed", "finish-gamma-fail", "GAMMA failed for this build and production was rolled back.",
                    "Run: kb-release gamma-fail %s --status (the protocol is resumable); no further GAMMA tests run." % rid)

    st = (release.get("stages") or {}).get(cur) or {}
    stale = bool(st.get("expectedSha")) and not _eq(st.get("expectedSha"), sha)
    expected = [] if stale else st.get("expected")
    rows = G._grade(expected, tests, sha, st.get("waiver"), cur) if G._norm_expected(expected) else []
    soak = _slots(scheduled, tests, sha, G._parse_ts(st.get("deployedAt") or st.get("enteredAt")), now) \
        if cur == "GAMMA" else []
    plan["run"]["soakDue"] = sorted({s["provider"] for s in soak if s["status"] == "due"})
    sched_names = {n for p in scheduled or () for n in p.get("tests") or ()}
    if not rows and st.get("intentionallyEmpty") is not True:
        plan["run"]["all"] = True
        return done("tests-running", "run-tests", "%s: the expected test set is not recorded for %s." % (cur, sha[:12]),
                    "Run the stage providers (kb-release test); they record the expected set first.")
    failed = [(n, why) for n, o, why in rows if o == "failed"]
    missing = [n for n, o, _ in rows if o == "missing"]
    if failed:
        return done("tests-failed", "await-fix-or-waiver", "%s: %d expected test(s) failed." % (cur, len(failed)),
                    *["FAIL %s: %s" % f for f in failed],
                    "Wait for a fix to land (new SHA via kb-release new-sha) or a lead waiver (kb-release waive). "
                    "Do not re-run records that are current.")
    manual = [n for n in missing if n in set(manual_tests)]
    auto = [n for n in missing if n not in set(manual_tests) and n not in sched_names]
    plan["run"].update(missingAutomated=auto, manualRemaining=manual, manualFirst=manual[0] if manual else None)
    if auto or manual:
        lines = ["run only the %d automated test(s) with no current record (kb-release test --only-missing)"
                 % len(auto)] if auto else []
        if manual:
            lines.append("manual walkthrough resumes at the first unanswered case: %s (%d remaining)" % (manual[0], len(manual)))
        return done("tests-running", "run-tests" if auto else "walkthrough",
                    "%s: %d expected test(s) have no current record." % (cur, len(auto) + len(manual)), *lines)
    if any(s["status"] != "done" for s in soak) or (cur == "GAMMA" and set(missing) & sched_names):
        lines = ["soak %s %s: %s%s" % (s["provider"], s["offset"], s["status"],
                                       " (due %s)" % s["dueAt"] if s["dueAt"] else "") for s in soak]
        return done("gamma-soak-pending", "soak", "GAMMA: soak checks are pending.", *lines,
                    *(["run the due checks: kb-release test --include-scheduled --provider <name>"]
                      if plan["run"]["soakDue"] else ["none is due yet; show the due times above and end the session"]))
    nxt = [s for s in G.enabled_stages(flow_config, cr_support_enabled=cr_support_enabled)
           if G.STAGES.index(s) > G.STAGES.index(cur)]
    edge = auto_edge(cur, flow_config, cr_support_enabled)
    status = "waived" if any(o == "waived" for _n, o, _w in rows) else "passed"
    plan["edge"] = edge
    if edge:
        return done("stage-passed", "chain", "%s %s: the auto-promote chain continues into %s." % (cur, status, edge))
    if cur == "GAMMA":
        return done("gamma-passed", "offer-promote", "GAMMA %s: offer the PROD promote (session promote)." % status,
                    # XACA-1353-004: a branch-per-release release enters PROD only through the close-out
                    ("Close-out is the PROD entry: run `kb-release close-out %s` (tag, merges, branch delete, CR close, "
                     "then the gated promote); the gate refuses a bare promote until it is done." % rid)
                    if release.get("branch") else "",
                    offer=promote_offer("PROD") if nxt else None)
    if cur in AUTO_SOURCES:   # no auto edge and not GAMMA: the next enabled stage is GAMMA/PROD (a CR team always has an edge)
        return done("gamma-ready", "offer-promote", "%s %s: GAMMA-ready (no CR stage for this team)." % (cur, status),
                    "GAMMA needs the lead to confirm a production deploy: wait for the session promote.",
                    offer=promote_offer(nxt[0]) if nxt else None)
    return done("stage-passed", "offer-promote", "%s %s: the next move is a deliberate session promote." % (cur, status),
                "DEV -> QA is never automatic: the lead declares the release feature-complete."
                if cur == "DEV" else "", offer=promote_offer(nxt[0]) if nxt else None)


def _cr_row(release, plan, done, promote_offer, cr, branch_head, flow_config, cr_on, now):
    rid, cr = release.get("id"), cr or {}
    state = cr.get("crState")
    if not cr.get("id"):
        return done("cr-draft-not-approved", "cr-stage", "CR: no open CR is linked yet.",
                    "Run: kb-release cr-stage %s (reuses or creates the CR, drafts it, stops for the lead's approval)." % rid)
    if state == "cr-held":
        return done("cr-held", "hold", "CR %s is held: the GAMMA gate stays closed." % cr["id"],
                    "Resume with kb-cr resume (returns to exactly held_from), or close it (spec 13.2).")
    if state == "cr-drafted" and not cr.get("draftApproved"):
        return done("cr-draft-not-approved", "present-draft", "CR %s: draft is not approved." % cr["id"],
                    "Re-present the draft for the lead's approval (kb-release cr-stage %s stops at the approval step); "
                    "the lead records it with kb-cr approve-draft." % rid)
    if state in (None, "cr-drafted", "cr-published"):
        return done("cr-stage-incomplete", "cr-stage", "CR %s: stage flow is not finished (state %s)." % (cr["id"], state),
                    "Run: kb-release cr-stage %s (every step detects that it already happened)." % rid)
    feed = cr.get("feed") or {}
    lines = ["CR %s state: %s" % (cr["id"], state),
             "cr_approval_expected_at: %s" % (feed.get("cr_approval_expected_at") or "none (manual approval)"),
             "approved at: %s" % (feed.get("approvedAt") or "not yet")]
    ctx = {"now": now.isoformat(), "deploy_confirmed": True, "items": [], "other_releases": []}
    if branch_head:
        ctx["branch_head"] = branch_head
    v = G.evaluate(dict(release, cr=feed), "GAMMA", flow_config, cr_support_enabled=cr_on, context=ctx)
    if v["allowed"]:
        return done("cr-submitted", "offer-promote", "CR submitted and the GAMMA gate can pass.", *lines,
                    offer=promote_offer("GAMMA"))
    return done("cr-submitted", "await-cr-approval", "CR submitted: the GAMMA gate cannot pass yet.", *lines,
                *["unmet: " + r for r in v["reasons"]])


def format_plan(plan):
    out = ["Release %s  stage %s  row=%s  action=%s" % (plan["release"], plan["stage"], plan["row"], plan["action"]),
           plan["headline"]] + [ln for ln in plan["lines"] if ln]
    if plan.get("offer"):
        o = plan["offer"]
        out.append("Offer: kb-release promote %s --to %s%s" % (plan["release"], o["promote"],
                                                               " --confirm-deploy (ask the lead first)" if o["confirmDeploy"] else ""))
    return "\n".join(out)


# ------------------------------------------------------------------ loading (the only I/O)
def find_release(kanban_dir, release_id):
    """-> (board_path, board, release). RunnerError when absent."""
    for path in sorted(glob.glob(os.path.join(kanban_dir, "*-board.json"))):
        with open(path, "r", encoding="utf-8") as fh:
            board = json.load(fh)
        for r in board.get("releases") or []:
            if r.get("id") == release_id:
                return path, board, r
    raise RunnerError("release %s not found under %s" % (release_id, kanban_dir))


def load_plan(kanban_dir, release_id, repo_dir=None, now=None):
    from release_providers import load_providers, providers_for_stage
    from release_runner import build_expected
    path, board, rel = find_release(kanban_dir, release_id)
    rc = board.get("releaseConfig") if isinstance(board.get("releaseConfig"), dict) else {}
    cs = (board.get("teamConfig") or {}).get("crSupport")
    cr_on = isinstance(cs, dict) and cs.get("enabled") is True
    now = now or datetime.now(timezone.utc)
    cur = G.current_stage(rel)
    items = [{"id": it.get("id"), "title": it.get("title"), "status": it.get("status"), "prMerged": it.get("prMerged")}
             for it in board.get("backlog") or []
             if isinstance(it.get("releaseAssignment"), dict) and it["releaseAssignment"].get("releaseId") == release_id]
    head = None
    if repo_dir and rel.get("branch"):
        head = release_branches.branch_tip(repo_dir, rel["branch"])   # remote tip; local refs lag/absent (XACA-1352-018)
    manual, sched = [], []
    try:
        provs = providers_for_stage(load_providers(os.path.join(kanban_dir, "config", "test-providers.json")), cur)
    except Exception:  # noqa: BLE001 -- no/invalid config: the plan still renders; kb-release test names the cause
        provs = []
    for p in provs:
        if p.get("kind") == "manual":
            manual += [e if isinstance(e, str) else e["test"] for e in build_expected([p], repo_dir=None, kanban_dir=kanban_dir)[0]]
        elif p.get("schedule") and repo_dir:
            names = build_expected([p], repo_dir=repo_dir, kanban_dir=kanban_dir)[0]
            sched.append({"provider": p["name"], "schedule": p["schedule"],
                          "tests": [e if isinstance(e, str) else e["test"] for e in names]})
    cr = None
    if cur == "CR" and cr_on:
        import approval_providers as ap
        from release_cr_stage import is_gamma_held, RETIRED_STATES
        crs, _missing = ap._linked_crs(board, rel)
        open_crs = [c for c in crs if c.get("crState") not in RETIRED_STATES and not is_gamma_held(c)]
        if open_crs:
            c = open_crs[0]
            cr = {"id": c["id"], "crState": c.get("crState"),
                  "draftApproved": bool((c.get("timestamps") or {}).get("cr_draft_approved_at")),
                  "feed": ap.release_cr_feed(board, rel, now.isoformat())}
    plan = resume_plan(rel, flow_config=rc.get("flowConfig") or {}, cr_support_enabled=cr_on, items=items,
                       other_releases=board.get("releases") or [], manual_tests=manual, scheduled=sched, cr=cr,
                       branch_head=head, now=now)
    plan["name"] = rel.get("name")
    return plan


def ensure_worktree(release, repo_dir, worktree_dir, *, run=subprocess.run):
    """Attach to the worktree already on release.branch, else create one at worktree_dir from that branch (local, or the
    remote-tracking ref). -> (path, "attached"|"created"). Never defaults to develop and never switches branches."""
    branch = release.get("branch")
    if not isinstance(branch, str) or not branch.strip() or branch.startswith("-"):
        raise RunnerError("release %s has no branch recorded: a PLANNED release has none (the DEV promote cuts "
                          "releases/<ver>). Refusing to fall back to develop; promote to DEV first." % release.get("id"))
    path = None
    for ln in _git(run, repo_dir, "worktree", "list", "--porcelain").splitlines():
        if ln.startswith("worktree "):
            path = ln[9:]
        elif ln == "branch refs/heads/" + branch and path:
            return path, "attached"
    if os.path.exists(worktree_dir):
        raise RunnerError("%s exists but is not a worktree on %s; move it aside or remove it (never auto-removed)"
                          % (worktree_dir, branch))
    def has(ref):
        try:
            _git(run, repo_dir, "rev-parse", "--verify", "--quiet", ref + "^{commit}")
            return True
        except RunnerError:
            return False
    if not has("refs/heads/" + branch):
        remotes = _git(run, repo_dir, "remote").split()
        for rm in remotes:   # best effort: a release cut on another machine is only on the remote
            try:
                _git(run, repo_dir, "fetch", "--quiet", rm, "+refs/heads/%s:refs/remotes/%s/%s" % (branch, rm, branch))
            except RunnerError:
                pass
        found = [rm for rm in remotes if has("refs/remotes/%s/%s" % (rm, branch))]
        if not found:
            raise RunnerError("branch %s (release.branch) exists neither locally nor on any remote; push or fetch it" % branch)
        _git(run, repo_dir, "worktree", "add", "-b", branch, worktree_dir, "%s/%s" % (found[0], branch))
        return worktree_dir, "created"
    _git(run, repo_dir, "worktree", "add", worktree_dir, branch)
    return worktree_dir, "created"


def main(argv=None):
    ap_ = argparse.ArgumentParser(description="kb-run <REL-ID> resume plan / worktree (XACA-1350)")
    sub = ap_.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--release", required=True)
    p.add_argument("--kanban-dir", required=True)
    p.add_argument("--repo-dir", default=None)
    p.add_argument("--json", action="store_true")
    w = sub.add_parser("worktree")
    w.add_argument("--release", required=True)
    w.add_argument("--kanban-dir", required=True)
    w.add_argument("--repo-dir", required=True)
    w.add_argument("--worktree-dir", required=True)
    a = ap_.parse_args(argv)
    try:
        if a.cmd == "plan":
            plan = load_plan(a.kanban_dir, a.release, a.repo_dir)
            print(json.dumps(plan) if a.json else format_plan(plan))
        else:
            _p, _b, rel = find_release(a.kanban_dir, a.release)
            path, how = ensure_worktree(rel, a.repo_dir, a.worktree_dir)
            print("%s\t%s" % (how, path))
    except RunnerError as e:
        print("release_resume: %s" % (e,), file=sys.stderr)
        return 4 if "not found under" in str(e) else 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
