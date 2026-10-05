"""Pure release gate evaluator (XACA-1346-004, spec RELEASE-LIFECYCLE.md 3, 5.3, 6.4).

NO I/O, no server/board imports, deterministic. The promote endpoint (PR 3) and
any future caller feed it plain dicts and act on the returned verdict.

Record shape read (release-level state, XACA-1346-001):
  release.stage                     optional explicit current stage
  release.stages{S}                 {enteredAt, status, expected[], sha, waiver?}
  release.stageSha{S}               graded SHA per stage (wins over stages[S].sha)
  release.tests[]                   append-only; superseded records carry supersededBy
  release.branch                    release branch (spec 4.1)
  release.cr                        {state, approvedAt, deployWindowPlanned}  (documented, not yet written by anyone;
                                    state 'emergency-deployed' is accepted in place of 'cr-approved', spec 13.5)
  release.platforms{P}.version      PLANNED version check

Waiver shape (spec 6.1 plus one DELIBERATE addition): stages.<S>.waiver =
{by, reason, ts, tests[], sha}. `sha` is not in the 6.1 sketch; it is REQUIRED here
as the explicit binding for 6.4 "valid only for the SHA graded against". The PR 3
writer populates it. `tests` may name a current record id or a test name (a bare
string counts as one name); a waiver can never cover a test with no current record.
The gate re-validates by/reason/ts (non-blank) and treats a malformed waiver as void.

CR enablement (lead decision, XACA-1346 round 3): teamConfig.crSupport.enabled is the
SOLE source of truth for whether the CR stage exists (spec 3.1). It arrives as the
REQUIRED keyword-only `cr_support_enabled` (a real bool, else ValueError; omitted =
TypeError, never a silent CR skip). flowConfig.stages.CR is IGNORED because the
flow-config endpoint can toggle it. GAMMA (XACA-1375-013/017, user decisions 2026-10-01): when
crSupport is ON, GAMMA is ALWAYS enabled whatever flowConfig says (it is where the CR is completed:
CR -> GAMMA -> PROD, `cr-completed` on GAMMA exit); when crSupport is not true GAMMA FOLLOWS flowConfig
(missing entry = enabled, `enabled: false` skips it: a team with no CR and no GAMMA goes ... -> PROD). `intentionallyEmpty` counts only when it `is True`.

Data the release record does not carry (items, sibling releases, clock, branch
HEAD, lead deploy confirmation) arrives via the ``context`` dict. A condition
whose data is absent is UNMET ("cannot verify"), never assumed satisfied.
  context = {items: [{id, status, prMerged}], other_releases: [release,...],
             now: ISO-8601, branch_head: sha, deploy_confirmed: bool}
"""
from datetime import datetime, timezone

from release_schema import STAGES  # single source of truth (XACA-1346-003); re-exported here
from release_closeout import first_incomplete as _closeout_first_incomplete, binding_gap as _closeout_binding_gap  # pure stdlib (XACA-1353-004)

# GAMMA is deliberately NOT here: it follows flowConfig, EXCEPT that it is forced on when crSupport is on
# (enabled_stages, XACA-1375-017).
ALWAYS_ENABLED = ("PLANNED", "DEV", "PROD")
TEST_STAGES = ("DEV", "QA", "ALPHA", "BETA", "GAMMA")  # stages whose exit gate is a test set
PASSED, FAILED, WAIVED, PENDING, RUNNING = "passed", "failed", "waived", "pending", "running"

# Stable machine-readable codes (XACA-1346-052/054). Reasons stay human strings; evaluate() and
# validate_waiver() return a PARALLEL `reasonCodes` list (and `reasonData`, per-reason params such
# as the stage/test a remedy names) so a UI never has to pattern-match prose. "other" = no remedy.
CODE_OTHER = "other"
CODE_GAMMA_CONFIRM_REQUIRED = "GAMMA_CONFIRM_REQUIRED"      # lead has not confirmed the prod deploy
CODE_GAMMA_ACTOR_NOT_LEAD = "GAMMA_ACTOR_NOT_LEAD"          # confirmation asserted by a non-lead
CODE_WAIVER_NEEDED = "WAIVER_NEEDED"                        # test FAIL / non-optional SKIP: a lead waiver can fix it
CODE_TEST_MISSING = "TEST_MISSING"                          # no current record: a waiver CANNOT cover it
CODE_WAIVER_VOID_SHA = "WAIVER_VOID_SHA"                    # waiver granted at another SHA
CODE_WAIVER_VOID_INVALID = "WAIVER_VOID_INVALID"            # stored waiver malformed
CODE_WAIVER_NOT_LEAD = "WAIVER_NOT_LEAD"                    # grantor is not the release lead
CODE_NOT_IN_LEADS = "NOT_IN_LEADS"                          # actor not in releaseConfig.leads
CODE_LEADS_NOT_CONFIGURED = "LEADS_NOT_CONFIGURED"          # releaseConfig.leads missing/empty: NO lead command can succeed
# XACA-1375: a release STRANDED at CR (crSupport turned off after it entered CR). INFORMATIONAL, never
# blocking: it replaces the CR exit conditions, and promote OUT of CR stays allowed. See is_blocking().
CODE_CR_SUPPORT_DISABLED = "CR_SUPPORT_DISABLED"
# XACA-1375: a forward promote that would skip an ENABLED CR or GAMMA stage. Always BLOCKING and a HARD refusal in
# BOTH gate modes (report mode included); other forward skips stay "refused in enforce, logged in report".
CODE_MANDATORY_STAGE_SKIPPED = "MANDATORY_STAGE_SKIPPED"
MANDATORY_STAGES = ("CR", "GAMMA")
# XACA-1349-004 (spec 13.3): entering the production-deploy stage with no determinable rollback target.
# Raised by the SERVER (it owns the git read); a HARD refusal in BOTH gate modes. The lead's remedy is
# `kb-release rollback-override` (release.rollbackShaOverride).
CODE_ROLLBACK_SHA_UNKNOWN = "ROLLBACK_SHA_UNKNOWN"
# PR #1036 round 1: a lead override that disagrees with the resolvable production tag. Also raised by the
# SERVER and HARD in both gate modes; the remedy is `kb-release rollback-override <id> --clear --by <lead>`.
CODE_ROLLBACK_OVERRIDE_CONFLICT = "ROLLBACK_OVERRIDE_CONFLICT"
# XACA-1353-004: GAMMA -> PROD before the PROD close-out finished. XACA-1353-013 (PR #1063 round 1): a HARD
# refusal in BOTH gate modes (report mode used to land the release at PROD, untagged and unmerged).
CODE_CLOSEOUT_INCOMPLETE = "CLOSEOUT_INCOMPLETE"
REASON_CODES = (CODE_OTHER, CODE_GAMMA_CONFIRM_REQUIRED, CODE_GAMMA_ACTOR_NOT_LEAD, CODE_WAIVER_NEEDED,
                CODE_TEST_MISSING, CODE_WAIVER_VOID_SHA, CODE_WAIVER_VOID_INVALID, CODE_WAIVER_NOT_LEAD,
                CODE_NOT_IN_LEADS, CODE_LEADS_NOT_CONFIGURED, CODE_CR_SUPPORT_DISABLED,
                CODE_MANDATORY_STAGE_SKIPPED, CODE_ROLLBACK_SHA_UNKNOWN, CODE_ROLLBACK_OVERRIDE_CONFLICT,
                CODE_CLOSEOUT_INCOMPLETE)
INFORMATIONAL_CODES = frozenset((CODE_CR_SUPPORT_DISABLED,))
CR_SUPPORT_DISABLED_MSG = "CR support disabled"

# The text fragments _grade builds and _row_code classifies on: ONE definition, used by both.
_VOID_MARK = "; waiver VOID: "
_VOID_SHA_MARK = _VOID_MARK + "waiver sha "


class Reasons(list):
    """list of reason strings carrying parallel `.codes` / `.data` lists (kept in lockstep)."""

    def __init__(self, items=(), codes=None, data=None):
        super().__init__(items)
        self.codes = list(codes) if codes is not None else [CODE_OTHER] * len(self)
        self.data = list(data) if data is not None else [None] * len(self)

    def append(self, msg, code=CODE_OTHER, data=None):
        super().append(msg)
        self.codes.append(code)
        self.data.append(data)

    def extend(self, other):
        if isinstance(other, Reasons):
            super().extend(other)
            self.codes.extend(other.codes)
            self.data.extend(other.data)
        else:
            for m in other:
                self.append(m)

    def blocking(self):
        """The reasons that actually block a move: everything except INFORMATIONAL_CODES."""
        return [m for m, c in zip(self, self.codes) if c not in INFORMATIONAL_CODES]

    def payload(self):
        """{"reasons", "reasonCodes", "reasonData"} as plain JSON-able lists."""
        return {"reasons": list(self), "reasonCodes": list(self.codes), "reasonData": list(self.data)}


def deploy_confirm_stage(order):
    """XACA-1375-013: the stage whose ENTRY needs the lead's production-deploy confirmation:
    GAMMA when the team has it (GAMMA is the live-prod soak stage), else PROD (the stage that
    actually enters production). `order` = enabled_stages(...)."""
    return "GAMMA" if "GAMMA" in order else "PROD"


def _cr_flag(v):
    if not isinstance(v, bool):
        raise ValueError("cr_support_enabled must be a bool (teamConfig.crSupport.enabled), got %r" % (v,))
    return v


def enabled_stages(flow_config, *, cr_support_enabled):
    """Ordered enabled stages. CR exists iff cr_support_enabled (spec 3.1);
    flowConfig's CR key is ignored. GAMMA is forced ON when cr_support_enabled, else follows flowConfig
    (XACA-1375-017). A missing QA/ALPHA/BETA entry counts as ENABLED: fail closed, never
    silently drop a test stage."""
    cfg = (flow_config or {}).get("stages") or {}
    _cr_flag(cr_support_enabled)
    out = []
    for s in STAGES:
        if s in ALWAYS_ENABLED:
            out.append(s)
        elif s == "CR":
            if _cr_flag(cr_support_enabled):
                out.append(s)
        elif s == "GAMMA" and _cr_flag(cr_support_enabled):
            out.append(s)   # XACA-1375-017: a CR team ALWAYS has GAMMA (CR is completed there)
        elif (cfg.get(s) or {}).get("enabled", True) is not False:
            out.append(s)
    return out


def later_enabled(order, cur, target):
    """Enabled stages strictly between `cur` and `target` (what a forward promote cur -> target skips).
    Disabled stages are not in `order`, so they are never "skipped"."""
    lo, hi = STAGES.index(cur), STAGES.index(target)
    return [x for x in order if lo < STAGES.index(x) < hi]


def stranded_in_cr(release, cr_support_enabled):
    """XACA-1375: True iff the release sits AT the CR stage while teamConfig.crSupport.enabled is
    not true (CR was turned off after the release entered it). Nothing may ENTER CR in that state;
    a release already there may only leave it."""
    return current_stage(release) == "CR" and not _cr_flag(cr_support_enabled)


def _platforms(release):
    p = release.get("platforms")
    return p if isinstance(p, dict) else {}


def current_stage(release):
    """Rule: explicit release.stage; else the furthest stage in stages{} with an
    enteredAt; else the EARLIEST legacy platforms.*.environment (conservative:
    a release is only as far along as its slowest platform); else PLANNED."""
    st = release.get("stage")
    if st in STAGES:
        return st
    entered = [s for s, r in (release.get("stages") or {}).items()
               if s in STAGES and isinstance(r, dict) and r.get("enteredAt")]
    if entered:
        return max(entered, key=STAGES.index)
    legacy = [p.get("environment") for p in _platforms(release).values()
              if isinstance(p, dict) and p.get("environment") in STAGES]
    return min(legacy, key=STAGES.index) if legacy else "PLANNED"


def _parse_ts(v):
    try:
        d = datetime.fromisoformat(str(v).replace("Z", "+00:00"))
        return d if d.tzinfo else d.replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None


def _norm_expected(expected):
    """[str | {test, optional}] -> [(test, optional)]. A non-list container yields ONE
    malformed entry (name None) so _grade can name it; it is never iterated as a string."""
    if expected and not isinstance(expected, (list, tuple)):
        return [(None, False)]
    out = []
    for e in expected or []:
        if isinstance(e, dict):
            out.append((e.get("test"), bool(e.get("optional"))))
        else:
            out.append((e, False))
    return out


def _graded_sha(release, stage):
    return (release.get("stageSha") or {}).get(stage) or \
        ((release.get("stages") or {}).get(stage) or {}).get("sha")


graded_sha = _graded_sha  # public alias: the server stamps waivers with the same SHA the gate grades


def _current_record(tests, stage, name, sha):
    """Latest non-superseded record for `name` at the graded sha (spec 6.4)."""
    found = None
    for r in tests or []:
        if not isinstance(r, dict):
            continue  # a malformed record can never satisfy an expected test
        if (r.get("test") == name and (stage is None or r.get("stage") == stage)
                and sha and r.get("sha") == sha and not r.get("supersededBy")):
            found = r  # later in append-only list wins
    return found


def _current_index(tests, stage, sha):
    """{name: _current_record(tests, stage, name, sha)} for every name that has one, in ONE pass.
    _grade used to call _current_record once per expected name: O(names x records), 26 s of a 42 s
    /tests POST at 2,000 records (PR #1010 round 1). Same predicate, same last-wins rule; only string
    names are indexed because _grade refuses every non-string expected name before looking one up."""
    out = {}
    if not sha:
        return out
    for r in tests or []:
        if not isinstance(r, dict):
            continue
        name = r.get("test")
        if (isinstance(name, str) and (stage is None or r.get("stage") == stage)
                and r.get("sha") == sha and not r.get("supersededBy")):
            out[name] = r  # later in append-only list wins
    return out


def _waiver_problem(waiver):
    """Why a stored waiver is void regardless of SHA (defence in depth), or None."""
    if not isinstance(waiver, dict):
        return "waiver is not an object"
    for f in ("by", "reason", "ts"):
        v = waiver.get(f)
        if not isinstance(v, str) or not v.strip():
            return "waiver is malformed: '%s' is blank" % f
    return _tests_problem(waiver)


def _tests_problem(waiver):
    t = waiver.get("tests")
    if t is None or isinstance(t, str):
        return None
    if not isinstance(t, (list, tuple)) or not all(isinstance(x, str) for x in t):
        return "waiver is malformed: 'tests' must be a string or a list of strings"
    return None


def _waiver_tests(waiver):
    t = waiver.get("tests")
    if isinstance(t, str):
        return {t}
    if isinstance(t, (list, tuple)):
        return {x for x in t if isinstance(x, str)}
    return set()


def _grade(expected, tests, sha, waiver, stage=None):
    """-> [(test, outcome, detail)] outcome in passed|failed|waived|missing"""
    bad = _waiver_problem(waiver) if waiver else None
    w_ok = bool(waiver) and bad is None and bool(sha) and waiver.get("sha") == sha
    covered = _waiver_tests(waiver) if waiver and bad is None else set()
    rows = []
    current = _current_index(tests, stage, sha)
    for name, optional in _norm_expected(expected):
        if not isinstance(name, str) or not name.strip():
            # XACA-1346-033: an unhashable/blank expected `test` must be a NAMED refusal,
            # never a TypeError from the `in covered` set lookups below.
            rows.append(("<malformed>", FAILED, "expected test entry is malformed: 'test' must be a "
                         "non-empty string (got %r)" % (name,)))
            continue
        rec = current.get(name)
        if rec and rec.get("result") == "PASS":
            rows.append((name, PASSED, ""))
            continue
        if rec is None:
            outcome, why = "missing", "expected test '%s' has no current record at SHA %s (missing != passing)" % (name, sha or "<none recorded>")
            if name in covered:
                why += "; waiver cannot cover a missing test"
        elif rec.get("result") == "SKIP" and optional:
            rows.append((name, PASSED, ""))
            continue
        elif rec.get("result") == "SKIP":
            outcome, why = FAILED, "test '%s' was SKIPped and is not optional (needs a lead waiver)" % name
        else:
            outcome, why = FAILED, "test '%s' result is %s" % (name, rec.get("result"))
        rid = rec.get("id") if rec is not None else None
        rid = rid if isinstance(rid, str) else None  # XACA-1346-033: unhashable id can never be "covered"
        if rec is not None and waiver and (name in covered or (rid is not None and rid in covered)):
            if w_ok:
                rows.append((name, WAIVED, ""))
                continue
            why += _VOID_SHA_MARK + "%s != graded sha %s" % (waiver.get("sha"), sha)
        elif rec is not None and bad and waiver:
            why += _VOID_MARK + bad
        rows.append((name, outcome, why))
    return rows


def derive_stage_status(stage_record, tests, expected, stage=None):
    """Spec 3.4. `tests` are the stage's records; graded at stage_record['sha']."""
    sr = stage_record or {}
    rows = _grade(expected, tests, sr.get("sha"), sr.get("waiver"), stage)
    if not rows:
        if sr.get("intentionallyEmpty") is True:
            return PASSED
        return RUNNING if sr.get("status") == RUNNING else PENDING
    outs = [r[1] for r in rows]
    if FAILED in outs:
        return FAILED
    if "missing" in outs:
        return PENDING if all(o == "missing" for o in outs) and sr.get("status") != RUNNING else RUNNING
    return WAIVED if WAIVED in outs else PASSED


def actor_is_lead(actor, release_config):
    """(is_lead, reason). THE lead check (XACA-1349): the LCARS endpoints (server._actor_is_lead
    delegates here) and `kb-release cr-stage --skip-notify --by` share it. FAILS CLOSED:
    releaseConfig.leads missing/empty/malformed means nobody is a lead. The actor is self-asserted
    (localhost trust model) but always recorded."""
    leads = release_config.get("leads") if isinstance(release_config, dict) else None
    names = {x.strip() for x in leads if isinstance(x, str) and x.strip()} if isinstance(leads, list) else set()
    if not names:
        return False, ("releaseConfig.leads is missing or empty; nobody can be authorized as lead "
                       "(fails closed)")
    if not isinstance(actor, str) or not actor.strip():
        return False, "an actor name is required and must be listed in releaseConfig.leads"
    if actor.strip() not in names:
        return False, "actor '%s' is not in releaseConfig.leads" % actor.strip()
    return True, None


def validate_waiver(waiver, stage_record, actor_is_lead):
    """Reasons a waiver is not acceptable ([] = valid). Lead check is the caller's fact."""
    r = Reasons()
    w = waiver if isinstance(waiver, dict) else {}
    if not actor_is_lead:
        r.append("only the release lead may grant a waiver", CODE_WAIVER_NOT_LEAD)
    for f in ("by", "reason", "ts", "sha"):
        if not str(w.get(f) or "").strip():
            r.append("waiver is missing required field '%s'" % f)
    if _tests_problem(w):
        r.append(_tests_problem(w))
    elif not _waiver_tests(w):
        r.append("waiver must name the test record ids/tests it covers")
    graded = (stage_record or {}).get("sha")
    if not graded:
        r.append("stage has no graded sha; nothing to bind the waiver to")
    elif w.get("sha") and w.get("sha") != graded:
        r.append("waiver sha %s != stage graded sha %s (a new SHA voids waivers)" % (w.get("sha"), graded))
    return r


def _row_code(outcome, why):
    """Code for one _grade row that blocks the gate (outcome missing|failed)."""
    if outcome == "missing":
        return CODE_TEST_MISSING
    if _VOID_SHA_MARK in why:
        return CODE_WAIVER_VOID_SHA
    if _VOID_MARK in why:
        return CODE_WAIVER_VOID_INVALID
    if why.startswith("expected test entry is malformed"):
        return CODE_OTHER
    return CODE_WAIVER_NEEDED


_CLOSEOUT_BASE_STEPS = ("tag", "mergeProduction", "mergeIntegration", "mergeOtherReleases", "deleteBranch")


def closeout_gap(release):
    """Why the PROD close-out (spec 3.2 PROD / 13.4) is not finished, or None when it is. Only a release that
    HAS a branch is subject (a pre-branch-model release has nothing to close out). Fails closed: a missing or
    malformed record is a gap, never 'complete' (first_incomplete({}) alone would read as complete)."""
    if not (isinstance(release.get("branch"), str) and release["branch"]):
        return None
    co = release.get("closeOut")
    if not isinstance(co, dict) or not isinstance(co.get("steps"), dict):
        return "close-out has not started"
    bound = _closeout_binding_gap(release)   # XACA-1353-014: a record from another build / with no gammaSha is no record
    if bound:
        return bound
    need = _CLOSEOUT_BASE_STEPS + (("crClose",) if co.get("crTeam") is True else ())
    miss = [s for s in need if s not in co["steps"]]
    if miss:
        return "close-out record is malformed (missing step %s)" % miss[0]
    nxt = _closeout_first_incomplete(co)
    return "close-out is incomplete (next step: %s)" % nxt if nxt else None


def _cr_closed_by_close_out(release, cr):
    """XACA-1353-016: the GAMMA-exit CR condition for a release whose CRs were closed BY ITS OWN close-out. crClose
    (spec 13.4, before the PROD promote) moves every linked CR to cr-closed, which release_cr_feed reads as "no open CR",
    so `state == cr-completed` can never hold again at the terminal promote. Satisfied ONLY when ALL of: the feed says
    every linked CR is cr-closed (a real linkage read, so a missing/unrelated CR cannot satisfy it), the closeOut is
    bound to the CURRENT build (gammaSha == stageSha.GAMMA), and its crClose step is done. Anything less still refuses."""
    co = release.get("closeOut")
    if not (isinstance(cr, dict) and cr.get("allClosed") is True and isinstance(co, dict)):
        return False
    if _closeout_binding_gap(release) is not None:
        return False
    rec = (co.get("steps") or {}).get("crClose")
    return isinstance(rec, dict) and rec.get("status") == "done"


def _exit_conditions(release, cur, cr_on, ctx):
    """Stage-specific unmet conditions for leaving `cur` (spec 3.2), all collected."""
    r = Reasons()
    sha = _graded_sha(release, cur)
    if cur == "PLANNED":
        items = ctx.get("items")
        if items is None:
            r.append("PLANNED: cannot verify assigned items (context.items absent)")
        elif not items:
            r.append("PLANNED: at least one item must be assigned")
        vers = [p.get("version") for p in _platforms(release).values() if isinstance(p, dict)]
        if not any(str(v or "").strip() for v in vers):
            r.append("PLANNED: a version must be set (platforms.<plat>.version)")
        others = ctx.get("other_releases")
        if others is None:
            r.append("PLANNED: cannot verify version uniqueness (context.other_releases absent)")
        mine = [(pn, p["version"]) for pn, p in _platforms(release).items()
                if isinstance(p, dict) and p.get("version")]
        for o in others or []:
            if not isinstance(o, dict):
                r.append("PLANNED: malformed entry in context.other_releases")
                continue
            same_id = bool(release.get("id")) and o.get("id") == release.get("id")
            if o is release or same_id or o.get("status") == "completed":
                continue
            op = o.get("platforms") if isinstance(o.get("platforms"), dict) else {}
            for pn, ver in mine:
                theirs = op.get(pn)
                if isinstance(theirs, dict) and theirs.get("version") == ver:
                    r.append("PLANNED: version %s on %s already used by open release %s" % (ver, pn, o.get("id")))
    if cur == "DEV":
        if not release.get("branch"):
            r.append("DEV: release has no branch recorded (spec 4.1)")
        items = ctx.get("items")
        if items is None:
            r.append("DEV: cannot verify item completion (context.items absent)")
        else:
            if not items:
                r.append("DEV: no items assigned")
            for it in items:
                if it.get("status") != "completed" or not it.get("prMerged"):
                    r.append("DEV: item %s is not completed with its PR merged into the release branch" % it.get("id"))
        head = ctx.get("branch_head")
        if not head:
            r.append("DEV: cannot verify DEV deploy SHA == branch HEAD (context.branch_head absent)")
        elif sha != head:
            r.append("DEV: stageSha.DEV %s != release branch HEAD %s" % (sha, head))
    if cur == "CR" and not cr_on:
        # XACA-1375: CR support was turned off while the release sat at CR. The CR exit conditions
        # (cr-approved, deploy window, stageSha.CR) describe a stage that no longer exists for this
        # team, so they are REPLACED by one informational reason. Promote OUT stays allowed.
        r.append(CR_SUPPORT_DISABLED_MSG, CODE_CR_SUPPORT_DISABLED, {"stage": "CR"})
    elif cur == "CR":
        cr = release.get("cr") or {}
        state = cr.get("state")
        if state == "emergency-deployed":
            # Spec 13.5: the GAMMA gate accepts emergency-deployed IN PLACE OF cr-approved.
            # Approval is retroactive on this path, so there is no approval time / deploy
            # window to wait for; the branch-HEAD == stageSha.CR check below still applies.
            pass
        else:
            if state != "cr-approved":
                r.append("CR: CR state is '%s', must be cr-approved (or emergency-deployed, spec 13.5)" % state)
            if isinstance(cr.get("staleApproval"), str) and cr["staleApproval"]:   # XACA-1349 F1
                r.append("CR: " + cr["staleApproval"])
            now, ap, win = _parse_ts(ctx.get("now")), _parse_ts(cr.get("approvedAt")), _parse_ts(cr.get("deployWindowPlanned"))
            if not (now and ap and win):
                r.append("CR: cannot verify approval time / deploy window (need context.now, cr.approvedAt, cr.deployWindowPlanned)")
            elif now < max(ap, win):
                r.append("CR: now is before max(cr_approved_at, deploy_window_planned)")
        head = ctx.get("branch_head")
        if not head or head != sha:
            r.append("CR: release branch HEAD %s != stageSha.CR %s (branch moved or unknown)" % (head, sha))
    if cur == "GAMMA" and cr_on:
        _cr = release.get("cr") or {}
        if _cr.get("state") != "cr-completed" and not _cr_closed_by_close_out(release, _cr):
            r.append("GAMMA: CR must be cr-completed")
    if cur == "GAMMA":
        # XACA-1353-004 (spec 13.4): PROD entry is the LAST act of close-out. The release stays in GAMMA until the
        # tag, both merges, the other-release merges, the branch delete (and kb-cr close) are done, so a failed
        # close-out can never leave a release at PROD with an undeleted branch / untagged production. That is only
        # true because the server treats CLOSEOUT_INCOMPLETE as a HARD refusal in BOTH gate modes (XACA-1353-013).
        _gap = closeout_gap(release)
        if _gap:
            r.append("PROD: %s; run `kb-release close-out %s` (kb-run resumes it)" % (_gap, release.get("id") or "<REL-ID>"),
                     CODE_CLOSEOUT_INCOMPLETE, {"releaseId": release.get("id")})
    if cur == "GAMMA" and release.get("gammaFailure") is not None:
        # XACA-1349-005 QA (spec 13.3): a build that failed in GAMMA and was rolled back is never promoted to PROD, even
        # when every expected test reads PASS (the lead may have declared the failure with no FAIL record, or waived
        # the failing test afterwards) and even for a team with no CR to hold. Scoped like `kb-release test`: this
        # build, and only until the protocol regressed the release out of GAMMA (marker.regressedAt).
        gfm = release.get("gammaFailure")
        if not isinstance(gfm, dict):
            r.append("GAMMA: release.gammaFailure is malformed; refusing (fails closed)")
        elif not gfm.get("regressedAt") and str(gfm.get("gammaSha", "")).lower() == str(sha or "").lower():
            r.append("GAMMA: a GAMMA failure is recorded for this build (%s); production was rolled back. A failed build "
                     "is not promoted: finish `kb-release gamma-fail` (regress to DEV) and ship the fix under a new CR"
                     % (gfm.get("summary") or "no summary"))
    if cur in TEST_STAGES:
        rec = (release.get("stages") or {}).get(cur) or {}
        expected = rec.get("expected")
        if not _norm_expected(expected):
            if rec.get("intentionallyEmpty") is not True:
                r.append("%s: empty expected test set fails the gate unless declared intentionally empty" % cur)
        else:
            wv = rec.get("waiver")
            for _n, outcome, why in _grade(expected, release.get("tests"), sha, wv, cur):
                if outcome in ("missing", FAILED):
                    r.append("%s: %s" % (cur, why), _row_code(outcome, why),
                             {"stage": cur, "test": _n, "sha": sha})
    return r


def evaluate(release, target_stage, flow_config, *, cr_support_enabled, actor=None, context=None):
    """Promote gate. Returns {allowed, reasons[], current, target, next, actor, status}."""
    ctx = context or {}
    reasons = Reasons()
    order = enabled_stages(flow_config, cr_support_enabled=cr_support_enabled)
    cur = current_stage(release)
    nxt = None
    if cur == "PROD":
        reasons.append("release is at PROD (terminal); nothing to promote to")
    else:
        later = [s for s in order if STAGES.index(s) > STAGES.index(cur)]
        nxt = later[0] if later else None
        if target_stage not in STAGES:
            reasons.append("unknown target stage '%s'" % target_stage)
        elif target_stage == cur:
            reasons.append("release is already at %s" % cur)
        elif STAGES.index(target_stage) < STAGES.index(cur):
            reasons.append("backward move %s -> %s refused; use regress (with a reason)" % (cur, target_stage))
        elif target_stage == "CR" and not _cr_flag(cr_support_enabled):
            reasons.append("target CR refused: CR support disabled for this team "
                           "(teamConfig.crSupport.enabled is not true); next enabled stage is %s" % nxt)
        elif target_stage not in order:
            reasons.append("target %s is disabled for this team; next enabled stage is %s" % (target_stage, nxt))
        elif target_stage != nxt:
            _skipped = [x for x in later_enabled(order, cur, target_stage) if x in MANDATORY_STAGES]
            if _skipped:
                reasons.append("mandatory stage %s skipped: next enabled stage after %s is %s, not %s"
                               % (_skipped[0], cur, nxt, target_stage),
                               CODE_MANDATORY_STAGE_SKIPPED, {"stage": _skipped[0], "skipped": _skipped})
            else:
                reasons.append("skipping refused: next enabled stage after %s is %s, not %s" % (cur, nxt, target_stage))
        _cs = deploy_confirm_stage(order)
        if target_stage == _cs and not ctx.get("deploy_confirmed"):
            reasons.append("%s: lead must explicitly confirm the production deploy" % _cs,
                           CODE_GAMMA_CONFIRM_REQUIRED, {"stage": _cs})
        reasons.extend(_exit_conditions(release, cur, cr_support_enabled, ctx))
    rec = (release.get("stages") or {}).get(cur) or {}
    status = derive_stage_status(dict(rec, sha=_graded_sha(release, cur)), release.get("tests"), rec.get("expected"), cur) \
        if cur in TEST_STAGES else None
    return {"allowed": not reasons.blocking(), "reasons": list(reasons), "reasonCodes": list(reasons.codes),
            "reasonData": list(reasons.data), "current": cur, "target": target_stage,
            "next": nxt, "actor": actor, "status": status,
            "strandedInCR": stranded_in_cr(release, cr_support_enabled)}


def evaluate_regress(release, target_stage, flow_config, reason, *, cr_support_enabled):
    """The only sanctioned backward move: strictly earlier enabled stage + non-blank reason."""
    reasons = []
    order = enabled_stages(flow_config, cr_support_enabled=cr_support_enabled)
    cur = current_stage(release)
    if not str(reason or "").strip():
        reasons.append("regress requires a non-empty reason")
    if target_stage not in STAGES:
        reasons.append("unknown target stage '%s'" % target_stage)
    elif STAGES.index(target_stage) >= STAGES.index(cur):
        reasons.append("regress target %s is not strictly earlier than current stage %s" % (target_stage, cur))
    elif target_stage == "CR" and not _cr_flag(cr_support_enabled):
        # XACA-1375: nothing may ENTER CR while CR support is off, regress included.
        reasons.append("regress target CR refused: CR support disabled for this team "
                       "(teamConfig.crSupport.enabled is not true)")
    elif target_stage not in order:
        reasons.append("regress target %s is disabled for this team" % target_stage)
    return {"allowed": not reasons, "reasons": reasons, "current": cur, "target": target_stage}
