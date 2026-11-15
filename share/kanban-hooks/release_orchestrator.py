"""
release_orchestrator.py -- read-only release run-planner (XACA-1543, EPIC-0072 T2).

Stdlib only, py3.9-safe, deterministic, READ-ONLY: it never writes a board, never calls a mutating kb-* command and
never touches tmux. XACA-1546 adds the ledger to this same file, so the layers stay separate and individually callable:

  check_readiness(...)  -> per-item refusal reasons                           (XACA-1543-003)
  build_waves(...)      -> DAG + conflict-aware wave packing, cycle refusal   (XACA-1543-002)
  assign_terminals(...) -> terminal/persona/kind per scheduled item           (XACA-1543-004)
  plan(...)             -> the whole run plan (the ONLY function that reads files / imports the contention module)
  format_plan(plan)     -> human render

BOARD FIELDS (verified against kanban/academy-board.json, 1815 items):
  estimate  = `points`  (int or float, hours; 1291 items carry it; the epic's own estimate is "sum of child points").
              No item carries estimate / timeEstimate / estimatedHours / storyPoints. UNESTIMATED = missing, non-numeric,
              bool or <= 0.
  priority  = `priority` (present on every item): critical > high > medium > low, case-insensitive ("HIGH" occurs once);
              anything else sorts last.
  status    = `status`; an absent status means backlog. completed / cancelled are terminal.
  deps      = `blockedBy` (list of ids). `dependsOn` exists on 4 items and is deliberately NOT read: the spec names blockedBy.
  subitems  = `subitems` (list); cancelled subitems do not count toward NO_SUBITEMS.

REFUSAL CODES (stable): UNESTIMATED, NO_SUBITEMS, NO_PLAN_DOC, BLOCKED_OUTSIDE_RELEASE, ALREADY_TERMINAL, CYCLE,
BLOCKER_REFUSED. ALREADY_TERMINAL items are SKIPPED (reported separately, not "refused"): there is nothing to schedule.
Non-refusal warning codes: NO_TERMINAL, NO_PATHS, UNPARSED_PATHS, HOTSPOTS_CONFIG_INVALID.

CONTENTION FAIL-CLOSED (XACA-1543 QA round)
  An empty extracted file set means the file set is UNKNOWN, never "touches nothing". plan() therefore treats an in-release
  candidate with ZERO extracted paths (no Files section, paths only in prose, glob-only section, unparseable list) as
  conflicting with EVERY other candidate: it is serialised into a wave of its own, and a NO_PATHS warning says why. A
  candidate whose plan doc carried path-like tokens that could not be resolved (unparsed: unanchored absolute paths,
  globs, templates) also gets UNPARSED_PATHS listing them. WHY serialise (option b) rather than refuse with a NO_FILE_SET
  code (the reviewer's option a): both are fail-closed, but serialising keeps the item runnable without forcing a plan-doc
  edit, whereas a refusal would block it. Option (a), refuse, is the REJECTED alternative. The synthetic conflicts are
  listed in `contention` with "reason": "NO_PATHS". The rule itself is orchestrator_contention.predict_closed (shared with the
  contention CLI; plan() holds no copy). "Unknown" = the PLAN DOC yields no paths: description paths only add to a known
  set. plan docs are read with errors="replace" (one bad byte must not abort the plan); kanban_dir is made absolute once.
HOTSPOT CONFIG
  `releaseConfig.orchestration.hotspots` (board level) = list of extra hotspot paths / "dir/" prefixes added to the
  built-in set. A bare list at `releaseConfig.orchestration` is accepted for back-compat. Any other type raises a
  HOTSPOTS_CONFIG_INVALID warning (the config is then ignored, never silently).

DECISIONS
  * A blocker outside the release is fine only if it is `completed`. Open, blocked, cancelled (a cancelled blocker never
    completes, so the dependant would wait forever) and unknown ids all refuse with BLOCKED_OUTSIDE_RELEASE.
  * A blocker INSIDE the release that is already completed is satisfied (no edge, no wait); one that is cancelled makes the
    dependant BLOCKER_REFUSED. A refused blocker makes its dependants BLOCKER_REFUSED, transitively. Dependants of a cycle
    are BLOCKER_REFUSED; cycle members are CYCLE.
  * NO_TERMINAL is a WARNING, not a refusal: the item is still scheduled in its wave (the work is valid; the fleet just has
    no seat for its kind right now) and the coordinator decides. Wave width is capped by maxParallel, never terminal count.
  * Terminal eligibility is entirely orchestrator_routing.role_fit (non-empty matching role, not coordinatorOnly,
    state == present, sane lane_windows). Not duplicated here.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import orchestrator_routing as routing  # noqa: E402

DEFAULT_REPO_ROOT = os.path.dirname(_HERE)   # the checkout containing this script
DEFAULT_MAX_PARALLEL = 2
TERMINAL_STATUSES = ("completed", "cancelled")
_PRIORITY_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3}
_UNKNOWN_RANK = len(_PRIORITY_RANK)

UNESTIMATED = "UNESTIMATED"
NO_SUBITEMS = "NO_SUBITEMS"
NO_PLAN_DOC = "NO_PLAN_DOC"
BLOCKED_OUTSIDE_RELEASE = "BLOCKED_OUTSIDE_RELEASE"
ALREADY_TERMINAL = "ALREADY_TERMINAL"
CYCLE = "CYCLE"
BLOCKER_REFUSED = "BLOCKER_REFUSED"
NO_TERMINAL = "NO_TERMINAL"
NO_PATHS = "NO_PATHS"
UNPARSED_PATHS = "UNPARSED_PATHS"
HOTSPOTS_CONFIG_INVALID = "HOTSPOTS_CONFIG_INVALID"


class PlanError(Exception):
    """Unknown release, unreadable board, unusable terminals: the CLI maps this to exit 1."""


def _reason(code, text):
    return {"code": code, "text": text}


# ---------------------------------------------------------------- field accessors
def estimate_of(item):
    """Hours from `points`; None when missing/non-numeric/bool/<=0."""
    v = item.get("points") if isinstance(item, dict) else None
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v <= 0:
        return None
    return v


def priority_rank(item):
    p = item.get("priority") if isinstance(item, dict) else None
    return _PRIORITY_RANK.get(p.strip().lower(), _UNKNOWN_RANK) if isinstance(p, str) else _UNKNOWN_RANK


def _blockers(item):
    b = item.get("blockedBy")
    return [x for x in b if isinstance(x, str)] if isinstance(b, list) else []


def _order_key(item):
    est = estimate_of(item)
    return (priority_rank(item), est is None, est if est is not None else 0, item.get("id") or "")


# ---------------------------------------------------------------- 003: readiness
def check_readiness(item, release_item_ids, board, kanban_dir, repo_root=None, find_plan_doc=None):
    """Refusal reasons ([{code,text}], stable order) for one item; [] means ready.

    `release_item_ids` = ids assigned to the release. `board` supplies outside blockers' status. `find_plan_doc` is
    orchestrator_contention.find_plan_doc (injected so tests need no real module; plan() passes the real one).
    ALREADY_TERMINAL short-circuits: nothing else matters for an item that will not be scheduled."""
    status = item.get("status")
    if status in TERMINAL_STATUSES:
        return [_reason(ALREADY_TERMINAL, "status is %s; nothing to schedule" % status)]
    out = []
    if estimate_of(item) is None:
        out.append(_reason(UNESTIMATED, "no positive numeric `points` estimate"))
    subs = item.get("subitems")
    live = [s for s in subs if isinstance(s, dict) and s.get("status") != "cancelled"] if isinstance(subs, list) else []
    if not live:
        out.append(_reason(NO_SUBITEMS, "no non-cancelled subitems"))
    if find_plan_doc is not None and find_plan_doc(item, kanban_dir, repo_root) is None:
        out.append(_reason(NO_PLAN_DOC, "no plan document found"))
    by_id = {i.get("id"): i for i in (board or {}).get("backlog") or [] if isinstance(i, dict)}
    ids = set(release_item_ids)
    for b in sorted(set(_blockers(item))):
        if b in ids:
            continue
        st = (by_id.get(b) or {}).get("status")
        if b not in by_id:
            out.append(_reason(BLOCKED_OUTSIDE_RELEASE, "%s is outside the release and not on this board" % b))
        elif st != "completed":
            out.append(_reason(BLOCKED_OUTSIDE_RELEASE, "%s is outside the release and %s (not completed)" % (b, st or "backlog")))
    return out


# ---------------------------------------------------------------- 002: DAG + waves
def _reaches(start, edges, nodes):
    """Nodes reachable from `start` along dependant edges (blocker -> dependant), excluding start unless on a cycle."""
    seen, stack = set(), list(edges.get(start, ()))
    while stack:
        n = stack.pop()
        if n in seen or n not in nodes:
            continue
        seen.add(n)
        stack.extend(edges.get(n, ()))
    return seen


def build_waves(items, conflicts, max_parallel=DEFAULT_MAX_PARALLEL, refused=()):
    """Pack items into waves. `items` = list of item dicts (id, blockedBy, priority, points). `conflicts` = predict() output
    ([{"a","b",...}]); a pair is never placed in one wave. `refused` = ids already refused (readiness): they are excluded and
    their dependants get BLOCKER_REFUSED.

    Returns {"waves": [[id...]...], "refused": {id: [reason...]}, "cycles": [[id...]...], "maxParallel": N}.
    `refused` holds only the reasons decided HERE (CYCLE, BLOCKER_REFUSED). Edges are blockedBy entries whose target is in
    `items` only (outside blockers are readiness's concern). Packing: wave by wave, a candidate is an unplaced item whose
    blockers are all in strictly earlier waves; candidates are taken in order (priority, estimate ascending, id) and added
    if the wave has room and the item conflicts with nothing already in it. Same input, byte-identical output."""
    if isinstance(max_parallel, bool) or not isinstance(max_parallel, int) or max_parallel < 1:
        raise ValueError("max_parallel must be an integer >= 1 (got %r)" % (max_parallel,))
    by_id = {}
    for it in items:
        by_id.setdefault(it["id"], it)
    pre = set(refused)
    known = set(by_id) | pre   # a refused blocker need not be in `items`: it still poisons its dependants
    deps = {i: sorted(set(b for b in _blockers(it) if b in known)) for i, it in by_id.items()}
    dependants = {}
    for i, bs in deps.items():
        for b in bs:
            dependants.setdefault(b, []).append(i)
    out_refused = {}

    def propagate(bad):
        """Transitive dependants of `bad` (a set of refused ids) -> BLOCKER_REFUSED. Mutates out_refused; returns new bad."""
        changed = True
        while changed:
            changed = False
            for i in sorted(by_id):
                if i in bad:
                    continue
                hit = [b for b in deps[i] if b in bad]
                if hit:
                    out_refused[i] = [_reason(BLOCKER_REFUSED, "blocker %s is refused" % ", ".join(sorted(hit)))]
                    bad.add(i)
                    changed = True
        return bad

    bad = propagate(set(pre))
    # Kahn over the survivors; whatever is left is a cycle member or sits downstream of one.
    live = {i for i in by_id if i not in bad}   # a self-blocker keeps its own edge, so Kahn leaves it as a 1-cycle
    indeg = {i: sum(1 for b in deps[i] if b in live) for i in live}
    ready = sorted(i for i in live if indeg[i] == 0)
    done = set()
    while ready:
        n = ready.pop()
        done.add(n)
        for d in dependants.get(n, ()):
            if d in live and d not in done:
                indeg[d] -= 1
                if indeg[d] == 0:
                    ready.append(d)
    left = live - done
    edges = {i: [d for d in dependants.get(i, ()) if d in left] for i in left}
    cycles = []
    seen_members = set()
    for i in sorted(left):
        if i in seen_members:
            continue
        if i in _reaches(i, edges, left):          # on a cycle: reaches itself
            scc = sorted(n for n in left if n == i or (n in _reaches(i, edges, left) and i in _reaches(n, edges, left)))
            seen_members.update(scc)
            cycles.append(scc)
    for scc in cycles:
        for i in scc:
            out_refused[i] = [_reason(CYCLE, "dependency cycle: %s" % " -> ".join(scc + [scc[0]]))]
            bad.add(i)
    propagate(bad)

    live = sorted((by_id[i] for i in by_id if i not in out_refused and i not in pre), key=_order_key)
    pairs = set()
    for c in conflicts or ():
        if isinstance(c, dict) and c.get("a") != c.get("b"):
            pairs.add(frozenset((c.get("a"), c.get("b"))))
    placed, waves = set(), []
    remaining = list(live)
    while remaining:
        wave = []
        for it in remaining:
            i = it["id"]
            if len(wave) >= max_parallel:
                break
            if any(b not in placed for b in deps[i]):
                continue
            if any(frozenset((i, w)) in pairs for w in wave):
                continue
            wave.append(i)
        if not wave:   # unreachable after cycle removal; refuse to spin
            raise PlanError("internal: no schedulable item among %s" % [x["id"] for x in remaining])
        placed.update(wave)   # blockers must sit in strictly EARLIER waves, so commit only after the wave is closed
        remaining = [it for it in remaining if it["id"] not in placed]
        waves.append(wave)
    return {"waves": waves, "refused": {k: out_refused[k] for k in sorted(out_refused)},
            "cycles": cycles, "maxParallel": max_parallel}


# ---------------------------------------------------------------- 004: terminals
def assign_terminals(waves, items, terminals, paths_by_item=None):
    """-> {id: {"terminal", "persona", "kind"[, "reason"]}}.

    `items` = {id: item} or a list of items. `terminals` = `kb-terminals status --json` terminals[] (parsed). Eligibility is
    routing.role_fit. Within a wave: fewest terminals-already-assigned-in-this-wave first (spreads the wave), then the
    terminal's live lane_windows, then name. No eligible terminal -> terminal None + reason NO_TERMINAL (a warning)."""
    if isinstance(items, list):
        items = {i["id"]: i for i in items}
    paths_by_item = paths_by_item or {}
    out = {}
    for wave in waves:
        used = {}
        for iid in wave:
            kind = routing.classify(items[iid], paths_by_item.get(iid))
            fit = routing.role_fit(kind, terminals)
            if not fit:
                out[iid] = {"terminal": None, "persona": None, "kind": kind,
                            "reason": _reason(NO_TERMINAL, "no eligible terminal for kind %s" % kind)}
                continue
            best = min(fit, key=lambda t: (used.get(t["name"], 0), t["lane_windows"], t["name"]))
            used[best["name"]] = used.get(best["name"], 0) + 1
            out[iid] = {"terminal": best["name"], "persona": best.get("developer"), "kind": kind}
    return out


# ---------------------------------------------------------------- entry point (the only I/O)
def _load_board(kanban_dir, release_id):
    import release_resume
    try:
        _path, board, rel = release_resume.find_release(kanban_dir, release_id)
    except Exception as exc:  # noqa: BLE001 -- RunnerError / bad JSON: one error type for the CLI
        raise PlanError(str(exc))
    return board, rel


def _hotspot_config(board):
    """-> (entries|None, invalid_text|None) from board.releaseConfig.orchestration (dict key `hotspots`, or a bare list)."""
    rc = board.get("releaseConfig")
    if not isinstance(rc, dict) or "orchestration" not in rc or rc["orchestration"] is None:
        return None, None
    o = rc["orchestration"]
    if isinstance(o, list):
        return o, None
    if isinstance(o, dict):
        if "hotspots" not in o or o["hotspots"] is None:
            return None, None
        if isinstance(o["hotspots"], list):
            return o["hotspots"], None
        return None, "releaseConfig.orchestration.hotspots must be a list, got %s (ignored)" % type(o["hotspots"]).__name__
    return None, "releaseConfig.orchestration must be an object with a `hotspots` list, got %s (ignored)" % type(o).__name__


def plan(release_id, kanban_dir, repo_root=None, terminals=None, max_parallel=None, contention=None):
    """The whole read-only run plan for a release. `terminals` = parsed terminals[] (None -> no terminals: every item gets
    NO_TERMINAL). `contention` = module-like with extract_paths/find_plan_doc/load_hotspots/predict (default: the real
    orchestrator_contention, imported here so the pure layers above never need it)."""
    if contention is None:
        import orchestrator_contention as contention
    kanban_dir = os.path.abspath(kanban_dir)   # a relative dir must not depend on cwd vs repo_root (NO_PLAN_DOC for all)
    board, rel = _load_board(kanban_dir, release_id)
    orch = rel.get("orchestration") if isinstance(rel.get("orchestration"), dict) else {}
    if max_parallel is None:
        max_parallel = orch.get("maxParallel", DEFAULT_MAX_PARALLEL)
    members = sorted((i for i in board.get("backlog") or []
                      if isinstance(i.get("releaseAssignment"), dict) and i["releaseAssignment"].get("releaseId") == release_id),
                     key=lambda i: i.get("id") or "")
    ids = [i["id"] for i in members]
    skipped, refused_reasons, candidates = [], {}, []
    for it in members:
        why = check_readiness(it, ids, board, kanban_dir, repo_root, contention.find_plan_doc)
        if why and why[0]["code"] == ALREADY_TERMINAL:
            skipped.append({"id": it["id"], "status": it.get("status")})
        elif why:
            refused_reasons[it["id"]] = why
        else:
            candidates.append(it)
    by_id = {i["id"]: i for i in members}
    # A terminal in-release blocker is not a scheduling edge: completed = satisfied, cancelled = refused for its dependants.
    cancelled = {s["id"] for s in skipped if s["status"] == "cancelled"}
    completed = {s["id"] for s in skipped if s["status"] == "completed"}
    sched_items = []
    for it in candidates:
        it2 = dict(it)
        it2["blockedBy"] = [b for b in _blockers(it) if b not in completed]
        sched_items.append(it2)

    paths_by_item, reports = {}, {}
    report_fn = getattr(contention, "extract_paths_report", None)
    for it in candidates:
        doc = contention.find_plan_doc(it, kanban_dir, repo_root)
        text = ""
        if doc:
            try:
                with open(doc, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                pass
        if report_fn is not None:
            rep_ = report_fn(text, it.get("description"), repo_root=repo_root)
        else:
            rep_ = {"paths": contention.extract_paths(text, it.get("description")), "unparsed": []}
        reports[it["id"]] = rep_
        paths_by_item[it["id"]] = list(rep_.get("paths") or [])
    cfg, cfg_invalid = _hotspot_config(board)
    hotspots = contention.load_hotspots(repo_root or DEFAULT_REPO_ROOT, cfg)
    # FAIL CLOSED: the rule lives in ONE place, contention.predict_closed, shared with the CLI (see module docstring).
    closed = contention.predict_closed(reports, hotspots)
    conflicts, no_paths, unparsed_by_item = closed["conflicts"], set(closed["no_paths"]), closed["unparsed"]

    pre = set(refused_reasons) | cancelled
    res = build_waves(sched_items, conflicts, max_parallel, refused=pre)
    refused_reasons.update(res["refused"])
    assign = assign_terminals(res["waves"], by_id, terminals or [], paths_by_item)
    waves, warnings = [], []
    for n, wave in enumerate(res["waves"], 1):
        row = []
        for iid in wave:
            it, a = by_id[iid], assign[iid]
            row.append({"id": iid, "title": it.get("title"), "kind": a["kind"], "points": estimate_of(it),
                        "priority": it.get("priority"), "terminal": a["terminal"], "persona": a["persona"]})
            if a.get("reason"):
                warnings.append({"id": iid, "code": a["reason"]["code"], "text": a["reason"]["text"]})
        waves.append({"wave": n, "items": row})
    for iid in sorted(i["id"] for w in waves for i in w["items"]):
        if iid in no_paths:
            warnings.append({"id": iid, "code": NO_PATHS, "text": "no file paths extracted from the plan doc; file set unknown, "
                             "serialised against every other item"})
        if unparsed_by_item.get(iid):
            warnings.append({"id": iid, "code": UNPARSED_PATHS,
                             "text": "unresolved path-like tokens: %s" % ", ".join(unparsed_by_item[iid])})
    if cfg_invalid:
        warnings.append({"id": release_id, "code": HOTSPOTS_CONFIG_INVALID, "text": cfg_invalid})
    refused = [{"id": i, "title": by_id[i].get("title"), "reasons": refused_reasons[i]} for i in sorted(refused_reasons)]
    return {"release": release_id, "maxParallel": max_parallel, "waves": waves, "refused": refused,
            "skipped": sorted(skipped, key=lambda s: s["id"]), "warnings": warnings,
            "cycles": res["cycles"], "contention": conflicts}


def format_plan(plan_):
    out = ["Release %s  maxParallel %s" % (plan_["release"], plan_["maxParallel"])]
    for w in plan_["waves"]:
        out.append("")
        out.append("Wave %d" % w["wave"])
        for r in w["items"]:
            tgt = ("%s (%s)" % (r["terminal"], r["persona"] or "-")) if r["terminal"] else "NO TERMINAL"
            est = ("%gh" % r["points"]) if r["points"] is not None else "-"
            out.append("  %s  %s  -> %s  %s  %s" % (r["id"], r["kind"], tgt, est, r["title"]))
    if not plan_["waves"]:
        out.extend(["", "No schedulable items."])
    if plan_["refused"]:
        out.extend(["", "Refused"])
        for r in plan_["refused"]:
            out.append("  %s  %s" % (r["id"], r["title"]))
            out.extend("    %s: %s" % (x["code"], x["text"]) for x in r["reasons"])
    if plan_["skipped"]:
        out.extend(["", "Skipped (already completed/cancelled)"])
        out.extend("  %s  %s" % (s["id"], s["status"]) for s in plan_["skipped"])
    if plan_["warnings"]:
        out.extend(["", "Warnings"])
        out.extend("  %s  %s: %s" % (x["id"], x["code"], x["text"]) for x in plan_["warnings"])
    if plan_["contention"]:
        out.extend(["", "Contention (serialized into different waves)"])
        for c in plan_["contention"]:
            out.append("  %s <> %s  %s%s" % (c["a"], c["b"], ", ".join(c.get("paths") or []) or "[%s]" % c.get("reason", "?"),
                                             ("  [hotspot: %s]" % ", ".join(c["hotspots"])) if c.get("hotspots") else ""))
    return "\n".join(out)


# ---------------------------------------------------------------- CLI
def _helpers_path():
    """KB_HELPERS, else the kanban-helpers.sh shipped beside this file (so a worktree/tap copy uses its OWN helpers,
    not a stale installed one that may predate kb-terminals), else ~/aiteamforge/kanban-helpers.sh."""
    env = os.environ.get("KB_HELPERS")
    if env:
        return env
    sibling = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "kanban-helpers.sh")
    return sibling if os.path.isfile(sibling) else os.path.expanduser("~/aiteamforge/kanban-helpers.sh")


def _terminals_from_helpers(kanban_dir, team):
    helpers = _helpers_path()
    cmd = 'source "$1" >/dev/null 2>&1; kb-terminals status --json%s' % (' --team "$2"' if team else "")
    try:
        p = subprocess.run(["zsh", "-c", cmd, "_", helpers] + ([team] if team else []),
                           capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise PlanError("kb-terminals status --json failed (helpers=%s): %s" % (helpers, exc))
    try:
        data = json.loads(p.stdout)
    except ValueError:
        raise PlanError("kb-terminals status --json rc=%s produced no JSON (helpers=%s; does it define kb-terminals? "
                        "set KB_HELPERS or pass --terminals-json): %s"
                        % (p.returncode, helpers, (p.stderr or "").strip()[-200:]))
    if p.returncode != 0 or not isinstance(data, dict) or not isinstance(data.get("terminals"), list):
        raise PlanError("kb-terminals status --json rc=%s, unusable output (helpers=%s)" % (p.returncode, helpers))
    return data["terminals"]


def main(argv=None):
    ap = argparse.ArgumentParser(prog="release_orchestrator.py", add_help=True)
    sub = ap.add_subparsers(dest="cmd")
    pp = sub.add_parser("plan", formatter_class=argparse.RawDescriptionHelpFormatter, epilog=(
        "Board config: releaseConfig.orchestration.hotspots = [list of extra hotspot paths or dir/ prefixes] "
        "(a bare list at releaseConfig.orchestration is also accepted); a wrong type warns HOTSPOTS_CONFIG_INVALID.\n"
        "Items whose plan doc yields no file paths are serialised and warn NO_PATHS (rule: orchestrator_contention.predict_closed)."))
    pp.add_argument("--release", required=True)
    pp.add_argument("--kanban-dir", required=True)
    pp.add_argument("--repo-root", help="repo root for sync-tap.sh hotspots and path anchoring "
                    "(default: the checkout containing this script)")
    pp.add_argument("--terminals-json")
    pp.add_argument("--max-parallel", type=int)
    pp.add_argument("--json", action="store_true")
    try:
        args = ap.parse_args(argv)
    except SystemExit as exc:
        return 0 if exc.code in (0, None) else 2
    if args.cmd != "plan":
        ap.print_usage(sys.stderr)
        return 2
    kdir = os.path.abspath(args.kanban_dir)
    try:
        if args.terminals_json:
            with open(args.terminals_json, encoding="utf-8") as fh:
                try:
                    terms = json.load(fh)
                except ValueError as exc:
                    raise PlanError("--terminals-json %s is not valid JSON: %s" % (args.terminals_json, exc))
            terms = terms.get("terminals") if isinstance(terms, dict) else terms
            if not isinstance(terms, list):
                raise PlanError("--terminals-json %s has no terminals[] list" % args.terminals_json)
        else:
            _b, rel = _load_board(kdir, args.release)
            terms = _terminals_from_helpers(kdir, rel.get("team"))
        result = plan(args.release, kdir, args.repo_root or DEFAULT_REPO_ROOT, terms, args.max_parallel)
    except (PlanError, OSError, ValueError, ImportError) as exc:
        # One voice with the kb-release shell wrapper: "Error: ..." plus a next step where there is one (XACA-1543-031).
        msg = str(exc)
        if "not found under" in msg:
            msg += " (see: kb-release list)"
        print("Error: %s" % msg, file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, indent=2) if args.json else format_plan(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
