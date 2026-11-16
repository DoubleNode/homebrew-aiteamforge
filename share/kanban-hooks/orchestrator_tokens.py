"""XACA-1808-002..007: release orchestrator token telemetry (EPIC-0072 T11).

Per-ticket / per-lane / coordinator / run token usage, the observed model, model-mismatch proof and optional budgets for an
orchestrated run, built on kb-token-report's DEDUPLICATED transcript scan (scripts/token_scan.py, imported, never
re-implemented). Stdlib only, py3.9-safe. dev-team-only (kanban-hooks/*.py is not mirrored to the tap).

Pure functions (no I/O, no clock) are separated from the I/O ones at the bottom (`collect_run`, `collect_item`, `ScanCache`).
Every number is a COUNT of the transcript's own usage data; nothing is estimated.

ATTRIBUTION (002). A transcript file is `<projects>/<encoded-cwd>/<sessionId>.jsonl`, its subagent sidecars
`<projects>/<encoded-cwd>/<sessionId>/subagents/*.jsonl`. A subagent INHERITS its parent session's attribution.
  worker       the session's cwd is the worktree of a run-tracked item whose item.orchestration.runId == RUN, AND the session's
               FIRST timestamped record is >= item.orchestration.dispatchedAt (equal counts; one second earlier does not).
               dispatchedAt here is the EARLIEST of the board value and this run's DISPATCHED ledger `dispatch` events (a same-run
               re-dispatch overwrites the board value; XACA-1808-016).
  coordinator  the session's cwd is the release worktree AND its first record is >= the ledger run_start `ts`.
  unattributed it touches a run worktree but fails a rule above. ALWAYS reported with a reason, never dropped.
WORKTREE RULE (reported per item as `worktreeRules`): item.worktree from the board ("board": cwd == that path, or under it,
compared by realpath so a symlinked checkout still matches); when the board has none, the `worktrees/<id-lower>` CONVENTION
("convention": the cwd contains `/worktrees/<id-lower>`). The RELEASE worktree is `<project root>/worktrees/<release-id-lower>`
(kanban-helpers.sh `kb-run <REL-ID>`: `${project_root}/worktrees/<release id lowercased>`; release_resume.py only receives the
path as --worktree-dir and does not compute it). Python derives project root as the parent of the kanban dir (override:
`worktrees_root`), and ALSO accepts any cwd containing `/worktrees/<release-id-lower>`.
DIRECTORY PRUNING. Claude Code names a project dir by replacing every non-alphanumeric character of the cwd with `-` (verified
against ~/.claude/projects, read-only; the narrower "/ and ." variant is accepted too). Only dirs that can match are scanned: the
encoded board worktree paths (and their realpaths) plus any dir ending `-worktrees-<id-lower>`. Pruning is an optimisation
only: attribution is always decided by the session's cwd. A session in a pruned-in dir whose cwd matches no target is reported
unattributed, not ignored. A (path, size, mtime_ns) cache means an unchanged file is never rescanned by a long-running watch.

AGGREGATION (003). Per ticket, per lane (ledger `lane` events, else the lanes[] summary), coordinator and run total:
  models         observed model ids, `<synthetic>` and `<no-model>` excluded
  input / cacheCreate / cacheRead / output   the four token categories, summed over deduplicated messages
  turns          the count of DEDUPLICATED assistant messages = API round trips (one message.id = one turn, however many
                 content-block lines repeat it); `<synthetic>` records are locally generated errors, not API calls, so they
                 are not turns
  cacheReadShare cacheRead / total       tokensPerPoint total / item.points (null when points is missing or <= 0)
  total          input + cacheCreate + cacheRead + output
Dedup is token_scan's: keyed (file, message.id), LAST occurrence wins. FAIL CLOSED: an unreadable transcript, malformed usage,
usage without a message.id or a timestamp makes the report `complete: false` with the reasons. Never a silent zero.

MODEL CHECK (004). Expected model = the LATEST ledger `dispatch` event for the item (nested dispatch.model, else top-level
`model`). MATCH RULE: an observed id matches expected `E` iff it is exactly `E`, or `E-YYYYMMDD` (a dated snapshot: exactly 8 digits, then the end of
the string or a `[...]` suffix), or `E[...]` (a `[1m]` context suffix). Any other `-` suffix is a DIFFERENT model: the expected
`claude-opus-5` does NOT match the observed `claude-opus-5-5` (XACA-1808-015). `inherit` = no override: the observed model is reported and there is NO mismatch. No dispatch event (or
an empty model) = expected `unknown`: reported, no mismatch. MODEL_MISMATCH = a WORKER session observed a model that does not
match. Only the worker's MAIN session is checked: a subagent (Explore, `model:` agents) picks its own model, so it never
raises a mismatch (its tokens still count and its model is still listed). Aliases (`opus`) are not expanded: dispatch records resolved ids.

BUDGETS (005). `tokenBudget {perTicket, perRun}` (total tokens, positive ints), layered per key:
release.orchestration.tokenBudget > releaseConfig.orchestration.tokenBudget. Absent = report only. An invalid value (bool, 0,
negative, float, string, non-object block) is REFUSED with a warning: it does not fall through to a lower layer (that would
apply a budget nobody asked for) and it is never silently ignored. Over budget (strictly greater) = a TOKEN_BUDGET condition.

DATA CONTRACT (006), written to release.orchestration.tokens under the board lock (release_orchestrator.write_tokens):
  {"run": B, "perItem": {<ID>: B}, "coordinator": B, "updatedAt": ISO,
   "complete": bool, "unattributed": int, "modelMismatch": [{"item", "expected", "observed": [...]}]}
  B = {"model", "input", "cacheCreate", "cacheRead", "output", "turns"}   (model: "a,b" sorted observed ids, or null)
`complete`, `unattributed` (a count) and `modelMismatch` are the ONLY keys beyond the four spec'd ones. Pinned by
tests/fixtures/xaca-1808/orchestration-tokens.contract.json; XACA-1786 / XACA-1549 render it. Lane / cacheReadShare /
tokensPerPoint live in the full report (`kb-release-orchestrate tokens --json`), not in the board block.

BASELINE (007). `collect_item` produces the same per-ticket numbers for a NON-orchestrated ticket: sessions are attributed by
kb-token-report's classifier (`token_scan.classify`: title, kb-run task prompt, worktree cwd, gitBranch), class `ticket`. Gate
sessions (review/test/ux) of the ticket are reported separately under `gates`, not mixed into the worker numbers.
"""
from __future__ import annotations

import glob
import json
import os
import re
import sys

_HERE = os.path.dirname(os.path.realpath(__file__))
_LIB = os.path.join(os.path.dirname(_HERE), "scripts")   # scripts/token_scan.py (flat: the tap sweep delivers only scripts/*.py)
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)

import token_scan as tscan  # noqa: E402

DEFAULT_PROJECTS_DIR = "~/.claude/projects"
PROJECTS_ENV = "KB_ORCH_PROJECTS_DIR"
BUDGET_KEYS = ("perTicket", "perRun")
BLOCK_KEYS = ("model", "input", "cacheCreate", "cacheRead", "output", "turns")
CONTRACT_TOP_KEYS = ("run", "perItem", "coordinator", "updatedAt", "complete", "unattributed", "modelMismatch")
NO_MODEL = "<no-model>"
IGNORED_MODELS = (tscan.SYNTHETIC_MODEL, NO_MODEL)


# ================================================================== pure: paths / discovery names
def encode_cwd(path, broad=True):
    """Claude Code's project-dir name for a cwd. broad: every non-alphanumeric -> '-' (what it really does);
    narrow: only '/' and '.'."""
    return re.sub(r"[^A-Za-z0-9]", "-", path) if broad else path.replace("/", "-").replace(".", "-")


def encoded_variants(path):
    """Every dir name `path` (or its realpath) could be stored under."""
    out = set()
    for p in {path, os.path.realpath(path)}:
        out.add(encode_cwd(p, True))
        out.add(encode_cwd(p, False))
    return out


def under(cwd, path):
    """cwd is `path` or inside it, by realpath on both sides (a symlinked checkout still matches)."""
    if not cwd or not path:
        return False
    a, b = os.path.realpath(cwd), os.path.realpath(path)
    return a == b or a.startswith(b.rstrip(os.sep) + os.sep)


def convention_match(cwd, name):
    """The `worktrees/<name>` convention: the cwd contains /worktrees/<name> as a whole path segment."""
    return bool(cwd) and re.search(r"/worktrees/%s(/|$)" % re.escape(name), cwd) is not None


def parse_ts(s):
    return tscan.parse_ts(s)


def _iso(dt):
    return None if dt is None else dt.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def _pos_number(p):
    return isinstance(p, (int, float)) and not isinstance(p, bool) and p > 0


# ================================================================== pure: targets + attribution
def first_dispatch_ts(events, run):
    """Pure. -> {item: earliest ts (datetime)} over the ledger `dispatch` events of THIS run whose outcome is DISPATCHED.
    A same-run re-dispatch overwrites item.orchestration.dispatchedAt, so the board alone forgets the earlier attempt
    (XACA-1808-016). An event stamped with another run id, a non-DISPATCHED outcome or an unreadable ts is ignored."""
    out = {}
    for ev in events or []:
        if not isinstance(ev, dict) or ev.get("kind") != "dispatch" or not isinstance(ev.get("item"), str):
            continue
        if ev.get("run") is not None and ev.get("run") != run:
            continue
        d = ev.get("dispatch") if isinstance(ev.get("dispatch"), dict) else {}
        if d.get("outcome") != "DISPATCHED":
            continue
        t = parse_ts(ev.get("ts"))
        if t is not None and (ev["item"] not in out or t < out[ev["item"]]):
            out[ev["item"]] = t
    return out


def build_targets(rel_id, orch, backlog, run, run_start, worktrees_root=None, kanban_dir=None, events=None):
    """-> {"items": {id: {worktree, rule, name, runId, dispatchedAt, points}}, "release": {...}, run, runStart}.
    Pure given its arguments. rule = "board" (item.worktree) or "convention" (worktrees/<id-lower>).
    dispatchedAt is the EARLIEST of item.orchestration.dispatchedAt and this run's DISPATCHED ledger events for the item
    (XACA-1808-016a); an unreadable board dispatchedAt stays unreadable (fail closed), events never rescue it."""
    firsts = first_dispatch_ts(events, run)
    by_id = {i.get("id"): i for i in backlog or [] if isinstance(i, dict)}
    items = {}
    for iid in sorted((orch or {}).get("items") or {}):
        it = by_id.get(iid) or {}
        wt = it.get("worktree")
        wt = wt if isinstance(wt, str) and wt.strip() else None
        o = it.get("orchestration") if isinstance(it.get("orchestration"), dict) else {}
        disp = o.get("dispatchedAt")
        board_t, ev_t = parse_ts(disp), firsts.get(iid)
        if board_t is not None and ev_t is not None and ev_t < board_t:
            disp = _iso(ev_t)
        items[iid] = {"worktree": wt, "rule": "board" if wt else "convention", "name": iid.lower(),
                      "runId": o.get("runId"), "dispatchedAt": disp, "points": it.get("points")}
    root = worktrees_root or (os.path.dirname(os.path.abspath(kanban_dir)) if kanban_dir else None)
    rname = rel_id.lower()
    rwt = os.path.join(root, "worktrees", rname) if root else None
    return {"items": items, "run": run, "runStart": run_start,
            "release": {"worktree": rwt, "name": rname, "rule": "release-root" if rwt else "convention"}}


def dir_names_for(targets):
    """-> (exact dir names, dir-name suffixes) that can hold a matching session. Pruning only."""
    exact, suffixes = set(), set()
    for t in list(targets["items"].values()) + [targets["release"]]:
        if t.get("worktree"):
            exact |= encoded_variants(t["worktree"])
        suffixes.add("-worktrees-" + t["name"])
    return exact, suffixes


def _match_target(cwd, t):
    if t["rule"] == "board":
        return under(cwd, t["worktree"])
    if t["rule"] == "release-root":
        return under(cwd, t["worktree"]) or convention_match(cwd, t["name"])
    return convention_match(cwd, t["name"])


def attribute_session(cwd, first_ts, targets):
    """Pure. -> (role, item_id|None, reason|None). role: "worker" | "coordinator" | "unattributed" | None (touches no
    run worktree: not ours, and not reportable). The two time rules live here."""
    if not cwd:
        return "unattributed", None, "session records no cwd, so it cannot be tied to a worktree"
    run, rstart = targets["run"], parse_ts(targets["runStart"])
    for iid, t in sorted(targets["items"].items()):
        if not _match_target(cwd, t):
            continue
        if t["runId"] != run:
            return "unattributed", iid, "cwd is %s's worktree but item.orchestration.runId is %r, not %s" % (iid, t["runId"], run)
        disp = parse_ts(t["dispatchedAt"])
        if disp is None:
            return "unattributed", iid, ("%s has no readable item.orchestration.dispatchedAt (%r): cannot tie the session "
                                         "to this dispatch" % (iid, t["dispatchedAt"]))
        if first_ts is None:
            return "unattributed", iid, "session has no timestamped record: cannot compare with dispatchedAt"
        if first_ts >= disp:                       # equal counts
            return "worker", iid, None
        return "unattributed", iid, "started %s, before %s dispatchedAt %s" % (_iso(first_ts), iid, _iso(disp))
    if _match_target(cwd, targets["release"]):
        if rstart is None:
            return "unattributed", None, "ledger has no readable run_start ts: cannot tell the coordinator from an older session"
        if first_ts is None:
            return "unattributed", None, "session has no timestamped record: cannot compare with the run start"
        if first_ts >= rstart:
            return "coordinator", None, None
        # The coordinator normally IS the session that calls start_run, so it always began before run_start. Accept it
        # with a per-message floor: only usage at or after run_start counts, and a session with NO in-run usage (an
        # older run's coordinator that did not carry on) is still unattributed by the caller (PR #1345 review).
        return COORD_FLOOR, None, "release-worktree session started %s, before the run start %s" % (_iso(first_ts), _iso(rstart))
    return None, None, None


# ================================================================== pure: aggregation
COORD_FLOOR = "coordinator-floor"   # attribute_session role: a release-worktree session spanning run_start


def merge_block(dst, src):
    for k in ("input", "cacheCreate", "cacheRead", "output", "turns"):
        dst[k] += src[k]
    dst["models"] |= src["models"]


def new_block():
    return {"models": set(), "input": 0, "cacheCreate": 0, "cacheRead": 0, "output": 0, "turns": 0}


def add_scan(block, fs, since=None):
    """Fold ONE FileScan's deduplicated usage into `block`. -> count of usage entries that could not be placed in time
    (only counted when `since` is set: such an entry is excluded, and the caller marks the report incomplete)."""
    undated = 0
    for key in fs.order:
        ts, model, u = fs.usage[key]
        if since is not None:
            if ts is None:
                undated += 1
                continue
            if ts < since:
                continue
        block["input"] += u["input"]
        block["cacheCreate"] += u["cache_creation"]
        block["cacheRead"] += u["cache_read"]
        block["output"] += u["output"]
        if model != tscan.SYNTHETIC_MODEL:
            block["turns"] += 1
            if model != NO_MODEL:
                block["models"].add(model)
    return undated


def merge_blocks(dst, src):
    for k in ("input", "cacheCreate", "cacheRead", "output", "turns"):
        dst[k] += src[k]
    dst["models"] |= src["models"]


def total_of(b):
    return b["input"] + b["cacheCreate"] + b["cacheRead"] + b["output"]


def finish_block(b):
    """-> the contract block B (JSON-safe)."""
    return {"model": ",".join(sorted(b["models"])) or None, "input": b["input"], "cacheCreate": b["cacheCreate"],
            "cacheRead": b["cacheRead"], "output": b["output"], "turns": b["turns"]}


def derived(b, points=None):
    """-> {total, cacheReadShare, tokensPerPoint}. Never divides by zero: an empty block has share None, missing/<=0
    points has tokensPerPoint None."""
    tot = total_of(b)
    share = (b["cacheRead"] / float(tot)) if tot > 0 else None
    return {"total": tot, "cacheReadShare": None if share is None else round(share, 4),
            "tokensPerPoint": round(tot / float(points), 1) if _pos_number(points) else None}


_MODEL_SUFFIX = re.compile(r"(-[0-9]{8})?(\[[^\]]*\])?\Z")


def model_matches(expected, observed):
    """E matches O iff O == E, or O == E + '-YYYYMMDD' (8 digits) [+ '[...]'], or O == E + '[...]'. Any other '-' suffix is a
    DIFFERENT model (claude-opus-5 must not match its successor claude-opus-5-5): XACA-1808-015."""
    if not isinstance(expected, str) or not expected or not isinstance(observed, str):
        return False
    if not observed.startswith(expected):
        return False
    return _MODEL_SUFFIX.match(observed[len(expected):]) is not None


def expected_models(events):
    """-> {item: expected model}: from the LATEST dispatch event per item. Nested `dispatch.model` first (the kb-dispatch
    --json object), then a top-level `model`. Empty / missing -> absent from the map (reported as `unknown`)."""
    out = {}
    for ev in events or []:
        if ev.get("kind") != "dispatch" or not isinstance(ev.get("item"), str):
            continue
        d = ev.get("dispatch") if isinstance(ev.get("dispatch"), dict) else {}
        m = d.get("model") if d.get("model") else ev.get("model")
        if isinstance(m, str) and m.strip():
            out[ev["item"]] = m.strip()
        else:
            out.pop(ev["item"], None)
    return out


def check_models(observed, expected):
    """Pure. observed {item: set(models)}, expected {item: model} -> (per-item status dict, mismatches list).
    status: "match" | "mismatch" | "inherit" | "unknown" | "unobserved". `inherit` and `unknown` never mismatch."""
    status, bad = {}, []
    for iid in sorted(set(observed) | set(expected)):
        exp, obs = expected.get(iid), sorted(observed.get(iid) or ())
        if exp is None:
            status[iid] = {"expected": "unknown", "status": "unknown"}
        elif exp == "inherit":
            status[iid] = {"expected": "inherit", "status": "inherit"}
        elif not obs:
            status[iid] = {"expected": exp, "status": "unobserved"}
        else:
            wrong = [m for m in obs if not model_matches(exp, m)]
            status[iid] = {"expected": exp, "status": "mismatch" if wrong else "match"}
            if wrong:
                bad.append({"item": iid, "expected": exp, "observed": wrong})
    return status, bad


def resolve_budgets(release_orch=None, team_orch=None):
    """Pure. -> (budgets {perTicket?, perRun?}, sources {key: "release"|"team"}, warnings). Per key, the first layer that
    SETS it wins (release > team). An invalid value is refused with a warning and BLOCKS that key (no fall-through)."""
    budgets, sources, warns = {}, {}, []
    blocked = set()
    for name, orch in (("release", release_orch), ("team", team_orch)):
        if not isinstance(orch, dict) or "tokenBudget" not in orch:
            continue
        tb = orch["tokenBudget"]
        label = "%s config tokenBudget" % name
        if not isinstance(tb, dict):
            warns.append("%s: must be an object {perTicket, perRun}, got %r: budget refused, not applied" % (label, tb))
            blocked |= set(BUDGET_KEYS)
            continue
        for k in sorted(tb, key=str):
            if k not in BUDGET_KEYS:
                warns.append("%s: unknown key %r ignored" % (label, k))
        for k in BUDGET_KEYS:
            if k not in tb or k in budgets or k in blocked:
                continue
            v = tb[k]
            if isinstance(v, bool) or not isinstance(v, int) or v <= 0:
                warns.append("%s.%s: must be a positive integer (total tokens), got %r: budget refused, not applied"
                             % (label, k, v))
                blocked.add(k)
                continue
            budgets[k] = v
            sources[k] = name
    return budgets, sources, warns


def check_budgets(tokens, budgets):
    """Pure. tokens = the contract block, budgets from resolve_budgets -> list of {scope, item, used, limit}.
    Strictly greater than the limit is over. perTicket applies to each perItem block; perRun to the run total."""
    out = []
    pt, pr = budgets.get("perTicket"), budgets.get("perRun")
    if pt is not None:
        for iid, b in sorted((tokens.get("perItem") or {}).items()):
            used = total_of(b)
            if used > pt:
                out.append({"scope": "item", "item": iid, "used": used, "limit": pt})
    if pr is not None:
        used = total_of(tokens["run"])
        if used > pr:
            out.append({"scope": "run", "item": None, "used": used, "limit": pr})
    return out


def lane_map(events, orch):
    """item -> lane number: the latest ledger `lane` assign event, else the lanes[] summary (current occupant)."""
    out = {}
    for ln in (orch or {}).get("lanes") or []:
        cur = ln.get("current") if isinstance(ln, dict) else None
        cid = cur.get("id") if isinstance(cur, dict) else cur
        if isinstance(cid, str) and cid and isinstance(ln.get("lane"), int):
            out[cid] = ln["lane"]
    for ev in events or []:
        if ev.get("kind") == "lane" and ev.get("action") == "assign" and isinstance(ev.get("item"), str) \
                and isinstance(ev.get("lane"), int):
            out[ev["item"]] = ev["lane"]
    return out


def run_start_ts(events):
    for ev in events or []:
        if ev.get("kind") == "run_start":
            return ev.get("ts")
    return None


def assemble(per_item_blocks, coord_block, observed_models, expected, points, lanes, unattributed, problems, now,
             undated=0):
    """Pure. Build the full report from folded blocks. per_item_blocks {id: block (mutable form)}."""
    run = new_block()
    for b in per_item_blocks.values():
        merge_blocks(run, b)
    merge_blocks(run, coord_block)
    model_status, mismatches = check_models(observed_models, expected)
    items = {}
    lane_tot, lane_pts, lane_missing = {}, {}, {}
    for iid, b in sorted(per_item_blocks.items()):
        lane = lanes.get(iid)
        ms = model_status.get(iid, {"expected": "unknown", "status": "unknown"})
        items[iid] = dict(finish_block(b), models=sorted(b["models"]), lane=lane, points=points.get(iid),
                          expectedModel=ms["expected"], modelStatus=ms["status"], **derived(b, points.get(iid)))
        key = str(lane) if lane is not None else "unlaned"
        lane_tot.setdefault(key, new_block())
        merge_blocks(lane_tot[key], b)
        if _pos_number(points.get(iid)):
            lane_pts[key] = lane_pts.get(key, 0) + points[iid]
        else:
            lane_missing[key] = True
    per_lane = {}
    for key, b in sorted(lane_tot.items()):
        per_lane[key] = dict(finish_block(b), **derived(b, None if lane_missing.get(key) else lane_pts.get(key)))
    all_pts = [points.get(i) for i in per_item_blocks]
    run_pts = sum(all_pts) if all_pts and all(_pos_number(p) for p in all_pts) else None
    problems = list(problems)
    if undated:
        problems.append("%d usage message(s) without a timestamp cannot be placed against --since and were excluded" % undated)
    complete = not problems
    block = {"run": finish_block(run), "perItem": {i: finish_block(b) for i, b in sorted(per_item_blocks.items())},
             "coordinator": finish_block(coord_block), "updatedAt": now, "complete": complete,
             "unattributed": len(unattributed), "modelMismatch": mismatches}
    return {"tokens": block, "items": items, "lanes": per_lane,
            "coordinator": dict(finish_block(coord_block), **derived(coord_block)),
            "run": dict(finish_block(run), **derived(run, run_pts)),
            "unattributed": unattributed, "complete": complete, "problems": problems}


# ================================================================== I/O: scan cache + discovery
def _sig(path):
    st = os.stat(path)
    return (st.st_size, st.st_mtime_ns)


def first_record_ts(path, limit=400):
    """The first record that carries a parseable `timestamp`, or None. Reads at most `limit` lines."""
    try:
        with open(path, "rb") as fh:
            for n, line in enumerate(fh):
                if n >= limit:
                    break
                try:
                    o = json.loads(line.decode("utf-8"))
                except (UnicodeDecodeError, ValueError):
                    continue
                if isinstance(o, dict):
                    t = parse_ts(o.get("timestamp"))
                    if t is not None:
                        return t
    except OSError:
        return None
    return None


class ScanCache(object):
    """(path, want_classifier) -> (size, mtime_ns) signature + FileScan + first timestamp. An unchanged file is a hit."""

    def __init__(self):
        self.entries = {}
        self.hits = 0
        self.misses = 0

    def scan(self, path, want_classifier=False):
        try:
            sig = _sig(path)
        except OSError:
            sig = None
        k = (path, bool(want_classifier))
        e = self.entries.get(k)
        if e is not None and sig is not None and e[0] == sig:
            self.hits += 1
            return e[1], e[2]
        self.misses += 1
        fs = tscan.scan_file(path, bool(want_classifier))
        first = first_record_ts(path)
        if sig is not None and not fs.unreadable:
            self.entries[k] = (sig, fs, first)
        return fs, first


_DEFAULT_CACHE = ScanCache()


def projects_dir_from(arg=None, env=None):
    env = os.environ if env is None else env
    return os.path.expanduser(arg or env.get(PROJECTS_ENV) or DEFAULT_PROJECTS_DIR)


def _select_dirs(projects, exact, suffixes):
    try:
        names = sorted(os.listdir(projects))
    except OSError:
        return []
    def can_match(n):
        # A session launched from a SUBDIRECTORY of a worktree lives in `<encoded worktree>-<sub...>` (under() accepts such a
        # cwd), so a name that merely EXTENDS a target is scanned too. Over-selection is harmless: the cwd decides.
        return (n in exact or any(n.startswith(e + "-") for e in exact)
                or any(n.endswith(s) or (s + "-") in n for s in suffixes))
    return [os.path.join(projects, n) for n in names if os.path.isdir(os.path.join(projects, n)) and can_match(n)]


def _files_of(d):
    mains = sorted(glob.glob(os.path.join(d, "*.jsonl")))
    subs = {}
    for f in sorted(glob.glob(os.path.join(d, "*", "subagents", "*.jsonl"))):
        subs.setdefault(os.path.basename(os.path.dirname(os.path.dirname(f))), []).append(f)
    return mains, subs


def _file_problems(fs, path, problems):
    """Record fail-closed problems for one scanned file; -> True when the file is unusable (unreadable)."""
    if fs.unreadable:
        problems.append("transcript unreadable: %s (%s)" % (path, fs.unreadable))
        return True
    if fs.malformed:
        problems.append("%s: %d assistant usage dict(s) missing a core field or non-integer" % (path, fs.malformed))
    if fs.no_id:
        problems.append("%s: %d assistant usage line(s) without message.id (counted undeduped)" % (path, fs.no_id))
    if fs.no_ts:
        problems.append("%s: %d assistant usage line(s) without a parseable timestamp" % (path, fs.no_ts))
    return False


def _models_of(fs):
    return {fs.usage[k][1] for k in fs.order} - set(IGNORED_MODELS)


def collect_run(release_id, orch, backlog, events, run, projects_dir, kanban_dir=None, now=None, since=None,
                cache=None, worktrees_root=None):
    """I/O wrapper for an orchestrated run -> the full report (see assemble). Never raises for data problems: they become
    `complete: false` + `problems`. `now` is an ISO string (the caller's clock)."""
    cache = cache or _DEFAULT_CACHE
    targets = build_targets(release_id, orch, backlog, run, run_start_ts(events), worktrees_root, kanban_dir, events=events)
    problems, unattributed = [], []
    blocks = {iid: new_block() for iid in targets["items"]}
    coord, observed = new_block(), {iid: set() for iid in targets["items"]}
    undated = 0
    if not os.path.isdir(projects_dir):
        problems.append("projects dir missing or unreadable: %s" % projects_dir)
    else:
        if targets["runStart"] is None:
            problems.append("ledger has no run_start event: the coordinator cannot be told from an older session")
        exact, suffixes = dir_names_for(targets)
        for d in _select_dirs(projects_dir, exact, suffixes):
            mains, subs = _files_of(d)
            exact_dir = os.path.basename(d) in exact
            seen_parents = set()
            for f in mains:
                sid = os.path.basename(f)[:-len(".jsonl")]
                seen_parents.add(sid)
                fs, first = cache.scan(f, False)
                if _file_problems(fs, f, problems):
                    continue
                role, iid, why = attribute_session(fs.cwd, first, targets)
                if role is None:
                    if exact_dir:
                        unattributed.append({"path": f, "cwd": fs.cwd, "item": None, "firstRecord": _iso(first),
                                             "reason": "in the project dir of a run worktree but its cwd %r matches no target" % fs.cwd})
                    continue
                files = [fs]
                for sf in subs.get(sid, []):
                    sfs, _first = cache.scan(sf, False)
                    if not _file_problems(sfs, sf, problems):
                        files.append(sfs)
                if role == "unattributed":
                    unattributed.append({"path": f, "cwd": fs.cwd, "item": iid, "firstRecord": _iso(first),
                                         "subagents": len(files) - 1, "reason": why})
                    continue
                if role == COORD_FLOOR:
                    # Count only the in-run part of a coordinator session that began before run_start (subagent
                    # sidecars get the same floor). Nothing in-run -> it is an older session: unattributed.
                    rstart = parse_ts(targets["runStart"])
                    floor = max(since, rstart) if since is not None else rstart
                    part, part_undated = new_block(), 0
                    for x in files:
                        part_undated += add_scan(part, x, floor)
                    if not any(part[k] for k in ("input", "cacheCreate", "cacheRead", "output", "turns")):
                        unattributed.append({"path": f, "cwd": fs.cwd, "item": None, "firstRecord": _iso(first),
                                             "subagents": len(files) - 1, "reason": why + ", with no usage after it"})
                        continue
                    merge_block(coord, part)
                    undated += part_undated
                    continue
                blk = blocks[iid] if role == "worker" else coord
                for n, x in enumerate(files):
                    undated += add_scan(blk, x, since)
                    if role == "worker" and n == 0:     # files[0] is the main session: a subagent picks its own model
                        observed[iid] |= _models_of(x)
            for sid, sfiles in sorted(subs.items()):
                if sid not in seen_parents and exact_dir:
                    for sf in sfiles:
                        unattributed.append({"path": sf, "cwd": None, "item": None, "firstRecord": None,
                                             "reason": "subagent whose parent session transcript is absent: attribution unknown"})
    points = {iid: t["points"] for iid, t in targets["items"].items()}
    rep = assemble(blocks, coord, observed, expected_models(events), points, lane_map(events, orch), unattributed,
                   problems, now, undated)
    rep["worktreeRules"] = {iid: {"rule": t["rule"], "worktree": t["worktree"] or "worktrees/%s" % t["name"]}
                            for iid, t in targets["items"].items()}
    rep["releaseWorktree"] = targets["release"]["worktree"]
    rep["run_id"], rep["release"] = run, release_id
    return rep


PREFILTER_CHUNK = 1 << 20      # bytes read per step of the collect_item needle pre-filter (XACA-1808-018)


def _has_needle(path, needles, chunk=PREFILTER_CHUNK):
    """True iff any of `needles` (bytes) occurs in the file. Streams in bounded `chunk`-byte reads, carrying the last
    len(longest needle)-1 bytes into the next window so a needle across a chunk boundary is still found; memory stays at
    about chunk + len(needle) instead of the whole transcript. OSError propagates (the caller reports it)."""
    chunk = max(1, int(chunk))
    keep = max(len(n) for n in needles) - 1
    tail = b""
    with open(path, "rb") as fh:
        while True:
            buf = fh.read(chunk)
            if not buf:
                return False
            data = tail + buf
            if any(n in data for n in needles):
                return True
            tail = data[-keep:] if keep > 0 else b""


def collect_item(item_id, item, projects_dir, now=None, since=None, cache=None, prefilter_chunk=None):
    """BASELINE (007): the per-ticket report for any ticket, run or no run. Class `ticket` sessions whose classifier ticket
    id is `item_id` are the worker numbers; class `gate` sessions go under `gates`."""
    cache = cache or _DEFAULT_CACHE
    problems, block, gates = [], new_block(), new_block()
    observed, unattributed, undated, n_sessions = set(), [], 0, 0
    needles = (item_id.encode("utf-8"), item_id.lower().encode("utf-8"))
    if not os.path.isdir(projects_dir):
        problems.append("projects dir missing or unreadable: %s" % projects_dir)
    else:
        for d in sorted(glob.glob(os.path.join(projects_dir, "*"))):
            if not os.path.isdir(d):
                continue
            mains, subs = _files_of(d)
            for f in mains:
                try:
                    found = _has_needle(f, needles, prefilter_chunk or PREFILTER_CHUNK)
                except OSError as exc:
                    problems.append("transcript unreadable: %s (%s)" % (f, type(exc).__name__))
                    continue
                if not found:                              # cheap streamed pre-filter: the id must appear somewhere
                    continue
                fs, first = cache.scan(f, True)
                if _file_problems(fs, f, problems):
                    continue
                cls, _signal, tid = tscan.classify(fs)
                if tid != item_id:
                    continue
                sid = os.path.basename(f)[:-len(".jsonl")]
                target = block if cls == "ticket" else gates if cls == "gate" else None
                if target is None:
                    unattributed.append({"path": f, "cwd": fs.cwd, "item": item_id, "firstRecord": _iso(first),
                                         "reason": "classified %r for %s: not a worker or gate session" % (cls, item_id)})
                    continue
                files = [fs]
                for sf in subs.get(sid, []):
                    sfs, _first = cache.scan(sf, False)
                    if not _file_problems(sfs, sf, problems):
                        files.append(sfs)
                if cls == "ticket":
                    n_sessions += 1
                for x in files:
                    undated += add_scan(target, x, since)
                    if cls == "ticket":
                        observed |= _models_of(x)
    points = {item_id: (item or {}).get("points")}
    rep = assemble({item_id: block}, new_block(), {item_id: observed}, {}, points, {}, unattributed, problems, now, undated)
    rep["gates"] = dict(finish_block(gates), **derived(gates))
    rep["item"], rep["sessions"] = item_id, n_sessions
    return rep


# ================================================================== presentation
def _fmt(n):
    if n is None:
        return "-"
    return "{:,}".format(n) if isinstance(n, int) else str(n)


def format_table(rep):
    """Human table for a report from collect_run / collect_item."""
    head = ("ITEM", "LANE", "MODEL", "INPUT", "CACHE_C", "CACHE_R", "OUTPUT", "TURNS", "CR%", "TOK/PT")
    rows = []

    def row(label, lane, d):
        share = d.get("cacheReadShare")
        rows.append((label, "-" if lane is None else str(lane), d.get("model") or "-", _fmt(d["input"]),
                     _fmt(d["cacheCreate"]), _fmt(d["cacheRead"]), _fmt(d["output"]), _fmt(d["turns"]),
                     "-" if share is None else "%.1f" % (share * 100), _fmt(d.get("tokensPerPoint"))))
    for iid, d in rep["items"].items():
        row(iid, d.get("lane"), d)
    if rep.get("run_id"):
        row("coordinator", None, rep["coordinator"])
        row("RUN TOTAL", None, rep["run"])
    w = [max([len(head[i])] + [len(r[i]) for r in rows]) for i in range(len(head))]

    def line(cells):
        return "  ".join(c.ljust(w[i]) if i < 3 else c.rjust(w[i]) for i, c in enumerate(cells))
    out = [line(head)] + [line(r) for r in rows]
    for iid, d in rep["items"].items():
        if d["modelStatus"] != "match":
            out.append("model %s: expected %s, status %s, observed %s" % (
                iid, d["expectedModel"], d["modelStatus"], ",".join(d["models"]) or "-"))
    g = rep.get("gates")
    if g and g["turns"]:
        out.append("gates (review/test/ux sessions, not in the numbers above): %s tokens over %d turn(s)" % (_fmt(g["total"]), g["turns"]))
    for u in rep["unattributed"]:
        out.append("unattributed: %s: %s" % (u["path"], u["reason"]))
    out.append("complete: %s" % ("yes" if rep["complete"] else "NO"))
    out += ["  problem: %s" % p for p in rep["problems"]]
    return out
