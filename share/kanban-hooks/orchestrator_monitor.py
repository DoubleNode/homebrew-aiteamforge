"""XACA-1546-003: the release orchestrator monitor (EPIC-0072). Logic behind `scripts/kb-release-orchestrate`.

Stdlib only, py3.9-safe. dev-team-only: kanban-hooks/*.py is not mirrored to the tap (like `kb-release plan-run`).

SYNOPSIS
  kb-release-orchestrate watch  <REL-ID> [--run RUN] [--once] [--interval S=30] [--timeout S=3600] [--repeat-after S=1800]
                                [--stall-seconds N] [--dispatch-seconds N] [--board FILE] [--kanban-dir DIR] [--repo owner/repo]
  kb-release-orchestrate status <REL-ID> [--json] [--run RUN] [--tokens] [same input flags]   (READ-ONLY, never writes)
  kb-release-orchestrate tokens <RUN-ID> [--json] [--since ISO] [--board FILE] [--kanban-dir DIR] [--projects-dir DIR]
  kb-release-orchestrate tokens --item <ID> [--json] [--since ISO] [--projects-dir DIR]        (XACA-1808, see TOKENS)
  watch also takes [--tokens-interval S=120] [--projects-dir DIR] [--worktrees-root DIR].

LEVEL-TRIGGERED. Every poll recomputes everything from inputs (board, tmux, gh, ledger) and trusts no in-memory state, so a
restarted `watch` behaves identically to one that never stopped. Per poll:
  1 read the board + release + release.orchestration (no activeRunId / closedAt set -> USAGE exit 2; --run must equal
    activeRunId). Tracked items = release.orchestration.items (the run's set).
  2 gather per item: activeWindows row `<terminal>:<ITEM>`; ONE `tmux list-panes -a` (session `<team>-<terminal>`, window
    name == ITEM; tmux failing = every pane None = UNKNOWN, tmux answering with no match = PANE_GONE); the newest PR of
    `feature/<item-id lowercase>` via `gh pr list` (a gh failure is {"error": ...}); thresholds via resolve_thresholds
    (flags > env > release > team > defaults; its warnings go to stderr).
  3 orchestrator_state.derive_states, then record_state (ledger + summary + lane sync) for every item whose derived state
    differs from summary items[ID].state. That is the change detection: a second poll with the same inputs writes nothing.
    `status` never writes. `watch` (both modes) writes only these state events, the verdict events below and run_end.
  4 refresh the token telemetry (TOKENS below), then pick ONE verdict by fixed priority (below), print it, append it to the
    ledger.

EXIT CODES / VERDICTS (stdout's LAST line is ALWAYS `VERDICT: <NAME> run=<RUN|-> item=<ID|-> detail=<one line>`)
   0  ALL_DONE          every tracked item is DONE or CANCELLED; the run is closed (close_run outcome=complete)
   0  HELP / STATUS     --help, and `status` success (same sharing-of-0 caveat as kb-pr-monitor: read the NAME)
   2  USAGE             usage / env error: bad flags, release or run missing / closed, bad thresholds, unreadable board,
                        corrupt or missing ledger, repo not derivable, bad maxParallel, no tracked items
   3  PENDING           --once only: nothing actionable (NOT in the plan table; added here)
  10  SLOT_FREE         a lane is free AND an item is eligible (compute_slot_free); detail names lane(s) + first eligible
  11  QUESTION_PENDING  an item has an open pendingQuestion; detail carries threadId and question age
  12  ITEM_STALLED      STALLED, or UNKNOWN persisted longer than dispatch_seconds (summary items[ID].since)
  13  ITEM_CRASHED      CRASHED (worker gone)
  14  ITEM_FAILED       FAILED (PR closed unmerged / terminal kb-pr-monitor verdict)
  15  DISPATCH_FAILED   the item's LATEST ledger `dispatch` event has outcome DISPATCH_FAILED and the item is still
                        QUEUED / DISPATCHING / UNKNOWN
  16  TOKEN_BUDGET      WARN-ONLY (XACA-1808): an item (perTicket) or the run (perRun) used MORE total tokens than its budget.
                        The detail tells the coordinator to PAUSE NEW dispatches and ask the lead. Nothing in code ever kills,
                        stops or nudges a worker because of it; the pause itself is the coordinator prompt's job (XACA-1548).
  17  MODEL_MISMATCH    WARN-ONLY (XACA-1808): a worker session observed a model that does not match the model its dispatch
                        recorded (the live proof that the model setting took effect). Detail names item, expected, observed.
  31  TIMEOUT           watch: --timeout elapsed with nothing actionable

PRIORITY when several hold (highest first): QUESTION_PENDING(11) > ITEM_CRASHED(13) > ITEM_FAILED(14) > DISPATCH_FAILED(15)
  > ITEM_STALLED(12) > MODEL_MISMATCH(17) > TOKEN_BUDGET(16) > SLOT_FREE(10) > ALL_DONE(0). Ties within a verdict: lowest wave,
  then item id. (A question beats a crash because the answer is collected on resume; SLOT_FREE is lowest so a coordinator
  handles trouble before new work. The two telemetry warnings sit just above SLOT_FREE: a coordinator must see "the model is
  wrong" / "budget blown" BEFORE it dispatches more work, but never ahead of a worker that is actually in trouble.)

UNKNOWN is never silently waited on forever, and one tmux hiccup must not fire a verdict: UNKNOWN only becomes ITEM_STALLED
once the summary says the item has BEEN UNKNOWN for longer than dispatch_seconds (record_state stamps `since` when it became
UNKNOWN, and the summary is re-read after this poll's writes, so a fresh UNKNOWN has age 0).

REPEAT SUPPRESSION (stops the coordinator busy-looping on a condition it already escalated). Every emitted verdict is appended
to the ledger as kind "verdict" {item, verdict, signature, detail}. signature = verdict | item | the evidence that would change
if the situation changed: QUESTION_PENDING threadId; ITEM_CRASHED the derived detail; ITEM_FAILED PR number + state + detail;
DISPATCH_FAILED the dispatch event's ts + reason; ITEM_STALLED the lastActivity value (or the UNKNOWN `since`); SLOT_FREE the
free-lane set + eligible ids; MODEL_MISMATCH `expected=<id>|observed=<bad ids>` (stable per item and cause: new token counts never
change it); TOKEN_BUDGET `item|limit=<N>` or `run|limit=<N>` (stable per scope and limit: raising the budget and blowing the new
one is a NEW condition, merely growing past the same limit is not). In `watch` WITHOUT --once, a condition is suppressed while the latest verdict event WITH THE SAME
SIGNATURE is younger than --repeat-after seconds (default 1800); then it fires again (debounced, never lost). Keyed on the
signature, not the item's latest verdict: one item can hold two live conditions at once (DISPATCH_FAILED + the SLOT_FREE it is
first-eligible for), and per-item keying made the pair alternate forever (PR #1343 QA). A changed signature fires at once; an
event stamped more than clock_skew_seconds in the future never suppresses.
LANE SYNC: after recording transitions, every in-flight item (neither QUEUED nor DONE/CANCELLED) holding no lane is given the
lowest free lane (assign_lane), so lanes[] is right even when nothing assigned one at dispatch. SLOT_FREE capacity separately
counts in-flight items (orchestrator_state.compute_slot_free), mirroring kb-dispatch's max(open lanes, stamped open items).
ALL_DONE and TIMEOUT are never suppressed. `--once` never suppresses (it reports the top condition) EXCEPT the two WARN-ONLY
verdicts (MODEL_MISMATCH, TOKEN_BUDGET, XACA-1808-014): those honour the signature-keyed suppression above (ledger verdict
events + --repeat-after) even under --once, so each is delivered ONCE per signature per repeat window and the next condition
(e.g. SLOT_FREE) surfaces on the following `--once`; a permanent mismatch can no longer starve dispatch. Because TOKEN_BUDGET
is delivered once, the coordinator's pause on it must be STICKY on ITS side (XACA-1548): it must keep pausing new dispatches
until the lead answers, not until the next verdict. Warn-only verdicts still never mask ALL_DONE. Suppression is read from
the ledger, not memory. Appended verdict events: every emitted verdict except PENDING / USAGE / HELP (run-level ones use item
"-"; SLOT_FREE uses the first eligible item).

CONTENTION: compute_slot_free needs the plan's `contention` pairs; start_run stores them in release.orchestration.contention.
A summary WITHOUT that key (or a non-list) FAILS CLOSED: every pair of tracked items is treated as conflicting, and SLOT_FREE
detail says so.

TOKENS (XACA-1808; telemetry in kanban-hooks/orchestrator_tokens.py, the contract is documented there). Each `watch` poll
refreshes release.orchestration.tokens, at most every --tokens-interval seconds (default 120; 0 = every poll), and at once when
an item newly reaches DONE. The throttle reads the stored tokens.updatedAt, never memory, so a restarted watch behaves
identically. Between refreshes the stored block feeds the conditions. `status` is READ-ONLY and (with --tokens) only COMPUTES;
`poll(read_only=True)` never writes tokens either. Budgets: release.orchestration.tokenBudget > releaseConfig.orchestration
.tokenBudget, {perTicket, perRun}; absent = report only; an invalid value is refused with a warning. Every MODEL_MISMATCH /
TOKEN_BUDGET condition is also appended ONCE per signature as ledger kind `model_mismatch` / `token_budget`. On ALL_DONE
(just before close_run) a final refresh is written, a `token_summary` event (run totals) is appended, and the summary is sent to
the lead (`release.orchestration.lead`, else the coordinator) through `kb-msg send` (the KB_ORCH_MSG variable overrides the
command, like KB_ORCH_TMUX / KB_ORCH_GH). A send failure is warned about, never changes the verdict. KB_ORCH_PROJECTS_DIR overrides
~/.claude/projects. `Ctx(tokens_interval=None)` (the default for programmatic callers) disables all of it; the CLI enables it.
`tokens` exits 0 (report produced), 2 (usage / board / run problem) or 3 (the data is unreadable or partial: complete is false;
the report is STILL printed). Unlike watch/status its stdout is the report, not a VERDICT line.

TERMINAL used to find the window row / tmux window: the terminal of the item's latest DISPATCHED ledger `dispatch` event
(the dispatcher may pick a terminal other than the plan's), else summary items[ID].terminal. Team = release.team, else board.team,
else the `<team>-board.json` file name. Env: KB_ORCH_TMUX (default tmux), KB_ORCH_GH (default gh), KB_KANBAN_DIR (default
<checkout>/kanban, or the MAIN checkout's kanban/ from a linked worktree with no board, when neither --board
nor --kanban-dir is given). Multiple panes in one window: a non-shell pane wins.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shlex
import subprocess
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import orchestrator_state as ostate  # noqa: E402
import orchestrator_tokens as otok  # noqa: E402
import release_orchestrator as ro  # noqa: E402

DEFAULT_REPO_ROOT = os.path.dirname(_HERE)
DEFAULT_INTERVAL = 30
DEFAULT_TIMEOUT = 3600
DEFAULT_REPEAT_AFTER = 1800
DEFAULT_TOKENS_INTERVAL = 120
TELEMETRY_VERDICTS = ("MODEL_MISMATCH", "TOKEN_BUDGET")   # warn-only; never block ALL_DONE

# verdict -> exit code
EXIT = {
    "ALL_DONE": 0, "HELP": 0, "STATUS": 0, "USAGE": 2, "PENDING": 3,
    "SLOT_FREE": 10, "QUESTION_PENDING": 11, "ITEM_STALLED": 12, "ITEM_CRASHED": 13, "ITEM_FAILED": 14,
    "DISPATCH_FAILED": 15, "TOKEN_BUDGET": 16, "MODEL_MISMATCH": 17, "TIMEOUT": 31,
}
PRIORITY = ("QUESTION_PENDING", "ITEM_CRASHED", "ITEM_FAILED", "DISPATCH_FAILED", "ITEM_STALLED", "MODEL_MISMATCH",
            "TOKEN_BUDGET", "SLOT_FREE", "ALL_DONE")
NOT_LOGGED = ("PENDING", "USAGE", "HELP", "STATUS")
PRE_RUNNING = ("QUEUED", "DISPATCHING", "UNKNOWN")

TMUX_FORMAT = "#{session_name}\t#{window_name}\t#{pane_current_command}"


class UsageError(Exception):
    """Usage / environment error -> exit 2."""


def one_line(text):
    return re.sub(r"\s+", " ", str(text)).strip()


def verdict_line(name, run, item, detail):
    return "VERDICT: %s run=%s item=%s detail=%s" % (name, run or "-", item or "-", one_line(detail))


# ------------------------------------------------------------------ real runners (injectable)
def _run(argv, timeout=60):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeError("%s: %s" % (argv[0], exc))
    return p.returncode, p.stdout, p.stderr


def real_tmux(env=None):
    """-> callable() returning the list-panes text; raises RuntimeError when tmux fails."""
    base = shlex.split((env or os.environ).get("KB_ORCH_TMUX") or "tmux")

    def fn():
        rc, out, err = _run(base + ["list-panes", "-a", "-F", TMUX_FORMAT], timeout=20)
        if rc != 0:
            raise RuntimeError("tmux list-panes rc=%d: %s" % (rc, one_line(err)[:200]))
        return out
    return fn


def real_gh(env=None):
    """-> callable(repo, branch) returning the parsed JSON list; raises RuntimeError on any failure."""
    base = shlex.split((env or os.environ).get("KB_ORCH_GH") or "gh")

    def fn(repo, branch):
        rc, out, err = _run(base + ["pr", "list", "--repo", repo, "--head", branch, "--state", "all",
                                    "--json", "number,state,mergedAt,isDraft"], timeout=60)
        if rc != 0:
            raise RuntimeError("gh pr list rc=%d: %s" % (rc, one_line(err)[:200]))
        try:
            return json.loads(out)
        except ValueError as exc:
            raise RuntimeError("gh pr list returned non-JSON: %s" % exc)
    return fn


def real_msg(environ=None):
    """-> callable(address, text) that runs `kb-msg send <address> <text>`; raises RuntimeError on any failure.
    KB_ORCH_MSG (shlex-split) replaces the command; the default sources kanban-helpers.sh into zsh because kb-msg is a
    shell function, not an executable."""
    raw = (environ if environ is not None else os.environ).get("KB_ORCH_MSG")
    if raw:
        base = shlex.split(raw)
    else:
        base = ["zsh", "-c", 'source "$1" >/dev/null 2>&1 || exit 97; shift; kb-msg "$@"', "kb-msg", ro._helpers_path()]

    def fn(address, text):
        rc, _out, err = _run(base + ["send", address, text], timeout=60)
        if rc != 0:
            raise RuntimeError("kb-msg send rc=%d: %s" % (rc, one_line(err)[:200]))
    return fn


def repo_from_git(repo_root):
    """owner/repo from `git remote get-url` of the FIRST remote (never assumes `origin`)."""
    try:
        rc, out, _e = _run(["git", "-C", repo_root, "remote"], timeout=20)
        names = out.split()
        if rc != 0 or not names:
            raise RuntimeError("no git remote in %s" % repo_root)
        rc, url, _e = _run(["git", "-C", repo_root, "remote", "get-url", names[0]], timeout=20)
        if rc != 0:
            raise RuntimeError("git remote get-url %s failed" % names[0])
    except RuntimeError as exc:
        raise UsageError("cannot derive --repo: %s (pass --repo owner/repo)" % exc)
    m = re.search(r"[:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$", url.strip())
    if not m:
        raise UsageError("cannot derive --repo from remote url %r (pass --repo owner/repo)" % url.strip().split("@")[-1])
    return "%s/%s" % (m.group(1), m.group(2))


# ------------------------------------------------------------------ context
class Ctx(object):
    def __init__(self, release_id, run=None, board=None, kanban_dir=None, repo=None, cli_thresholds=None,
                 repeat_after=DEFAULT_REPEAT_AFTER, interval=DEFAULT_INTERVAL, timeout=DEFAULT_TIMEOUT,
                 tmux=None, gh=None, clock=None, sleep=None, env=None, repo_root=None, stderr=None, out=None,
                 tokens_interval=None, projects_dir=None, worktrees_root=None, msg=None, token_cache=None):
        self.release_id = release_id
        self.run = run
        self.board = board
        self.kanban_dir = kanban_dir
        self.repo = repo
        self.cli_thresholds = cli_thresholds or {}
        self.repeat_after = repeat_after
        self.interval = interval
        self.timeout = timeout
        self.env = dict(os.environ) if env is None else env
        self.tmux = tmux or real_tmux(self.env)
        self.gh = gh or real_gh(self.env)
        self.msg = msg or real_msg(self.env)
        # XACA-1808: None disables token telemetry (programmatic callers / pre-1808 tests); the CLI passes the interval.
        self.tokens_interval = tokens_interval
        self.projects_dir = otok.projects_dir_from(projects_dir, self.env)
        self.worktrees_root = worktrees_root
        self.token_cache = token_cache
        self.clock = clock or (lambda: datetime.datetime.now(datetime.timezone.utc))
        self.sleep = sleep or time.sleep
        self.repo_root = repo_root or DEFAULT_REPO_ROOT
        self.stderr = stderr if stderr is not None else sys.stderr
        self.out = out if out is not None else sys.stdout
        self._warned = set()
        self._kdir = None

    def warn(self, text):
        if text not in self._warned:
            self._warned.add(text)
            print("warning: %s" % text, file=self.stderr)


def _load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        raise UsageError("cannot read board %s: %s" % (path, exc))


def default_kanban_dir(repo_root):
    """<checkout>/kanban, unless that holds no *-board.json and the checkout is a LINKED git worktree: then the main
    checkout's kanban/. The board is untracked and lives only in the main checkout, so a coordinator running in the
    release worktree (or a lane in its ticket worktree) must still find it without --board (XACA-1808)."""
    import glob
    own = os.path.join(repo_root, "kanban")
    if glob.glob(os.path.join(own, "*-board.json")):
        return own
    try:
        with open(os.path.join(repo_root, ".git"), "r", encoding="utf-8") as fh:
            line = fh.readline().strip()
    except OSError:          # .git is a directory (main checkout) or absent: nothing better to offer
        return own
    if not line.startswith("gitdir:"):
        return own
    gitdir = os.path.realpath(os.path.join(repo_root, line[len("gitdir:"):].strip()))
    parts = gitdir.split(os.sep)
    if len(parts) >= 3 and parts[-2] == "worktrees" and parts[-3] == ".git":   # <main>/.git/worktrees/<name>
        main_kanban = os.path.join(os.sep.join(parts[:-3]) or os.sep, "kanban")
        if os.path.isdir(main_kanban):
            return main_kanban
    return own


def locate_release(ctx):
    """-> (board_file, kanban_dir, board, release). Re-reads the board file every call (level-triggered)."""
    board_file, kdir = ctx.board, ctx.kanban_dir
    if board_file:
        kdir = kdir or os.path.dirname(os.path.abspath(board_file))
        board = _load_json(board_file)
        rel = next((r for r in board.get("releases") or [] if isinstance(r, dict) and r.get("id") == ctx.release_id), None)
        if rel is None:
            raise UsageError("release %s not found in %s" % (ctx.release_id, board_file))
    else:
        kdir = kdir or ctx.env.get("KB_KANBAN_DIR") or default_kanban_dir(ctx.repo_root)
        import release_resume
        try:
            board_file, board, rel = release_resume.find_release(kdir, ctx.release_id)
        except Exception as exc:  # noqa: BLE001 -- RunnerError / bad JSON: one error type
            raise UsageError(str(exc))
    if not isinstance(board, dict):
        raise UsageError("board %s is not a JSON object" % board_file)
    return board_file, os.path.abspath(kdir), board, rel


def team_of(board, rel, board_file):
    for v in (rel.get("team"), board.get("team")):
        if isinstance(v, str) and v:
            return v
    m = re.match(r"^(.+)-board\.json$", os.path.basename(board_file))
    return m.group(1) if m else None


def active_orch(ctx, rel):
    orch = rel.get("orchestration")
    rid = orch.get("activeRunId") if isinstance(orch, dict) else None
    if not rid or orch.get("closedAt"):
        raise UsageError("no active run for %s" % ctx.release_id)
    if ctx.run and ctx.run != rid:
        raise UsageError("--run %s is not the active run of %s (active: %s)" % (ctx.run, ctx.release_id, rid))
    if not isinstance(orch.get("items"), dict) or not orch["items"]:
        raise UsageError("run %s tracks no items" % rid)
    return rid, orch


def read_ledger(ctx, kdir, run):
    try:
        return list(ro.ledger_read(kdir, run))
    except ro.LedgerError as exc:
        raise UsageError("ledger unreadable (fail closed): %s" % exc)


def latest_by_item(events, kind):
    out = {}
    for ev in events:
        if ev.get("kind") == kind and isinstance(ev.get("item"), str):
            out[ev["item"]] = ev
    return out


# ------------------------------------------------------------------ inputs
def parse_panes(text):
    rows = []
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3:
            rows.append((parts[0], parts[1], parts[2].strip()))
    return rows


def pane_for(rows, session, window):
    """None-safe: rows None = tmux unreadable -> None; no match -> PANE_GONE; else a non-shell command wins."""
    if rows is None:
        return None
    cmds = [c for s, w, c in rows if s == session and w == window]
    if not cmds:
        return ostate.PANE_GONE
    for c in cmds:
        if c and ostate._norm_command(c) not in ostate.SHELL_COMMANDS:
            return c
    return cmds[0]


def newest_pr(entries):
    if not isinstance(entries, list):
        return {"error": "gh returned %s, expected a list" % type(entries).__name__}
    # The branch's LIVE attempt wins, not simply the highest number: OPEN, then MERGED, then the newest of the rest.
    # A retry after a closed-unmerged PR reuses feature/<id>; picking the closed one would pin the item at FAILED.
    rank = {"OPEN": 0, "MERGED": 1}
    best = None
    for e in entries:
        if not isinstance(e, dict) or not isinstance(e.get("number"), int):
            return {"error": "gh returned an entry that is not a PR object: %r" % (e,)}
        raw_state = e.get("state")
        st = raw_state.upper() if isinstance(raw_state, str) else ""
        if e.get("mergedAt") and st != "OPEN":
            st = "MERGED"
        key = (rank.get(st, 2), -e["number"])
        if best is None or key < best[0]:
            best = (key, e)
    return best[1] if best else None


def gather(ctx, rel, board, board_file, run, orch, events):
    """-> dict of everything the derivation needs. Raises UsageError for env problems."""
    now = ctx.clock()
    team = team_of(board, rel, board_file)
    th, sources, warns = ostate.resolve_thresholds(
        cli=ctx.cli_thresholds, env=ctx.env, release_orch=orch,
        team_orch=(board.get("releaseConfig") or {}).get("orchestration") if isinstance(board.get("releaseConfig"), dict) else None)
    for w in warns:
        ctx.warn(w)
    backlog = {i.get("id"): i for i in board.get("backlog") or [] if isinstance(i, dict)}
    wins = {w.get("id"): w for w in board.get("activeWindows") or [] if isinstance(w, dict)}
    dispatches = latest_by_item(events, ro.KIND_DISPATCH) if events else {}
    try:
        pane_rows = parse_panes(ctx.tmux())
    except Exception:  # noqa: BLE001 -- any tmux failure = unreadable, never "gone"
        pane_rows = None
    items, windows, panes, prs, terminals = {}, {}, {}, {}, {}
    repo = ctx.repo
    for iid, srow in sorted(orch["items"].items()):
        it = backlog.get(iid)
        if it is not None:
            items[iid] = it
        term = srow.get("terminal") if isinstance(srow, dict) else None
        disp = None
        for ev in (events or []):
            if ev.get("kind") == ro.KIND_DISPATCH and ev.get("item") == iid:
                d = ev.get("dispatch")
                if isinstance(d, dict) and d.get("outcome") == "DISPATCHED" and isinstance(d.get("terminal"), str):
                    disp = d["terminal"]
        term = disp or term
        terminals[iid] = term
        windows[iid] = wins.get("%s:%s" % (term, iid)) if term else None
        session = "%s-%s" % (team, term) if (team and term) else None
        panes[iid] = pane_for(pane_rows, session, iid) if session else (None if pane_rows is None else ostate.PANE_GONE)
        status = ostate.resolve_item_status(it) if it else None
        if it is None or status in ("completed", "cancelled"):
            prs[iid] = None
        else:
            if not repo:
                repo = repo_from_git(ctx.repo_root)
            try:
                prs[iid] = newest_pr(ctx.gh(repo, "feature/%s" % iid.lower()))
            except Exception as exc:  # noqa: BLE001 -- a gh failure is data, not a crash
                prs[iid] = {"error": one_line(exc)}
    return {"now": now, "team": team, "thresholds": th, "sources": sources, "items": items, "windows": windows,
            "panes": panes, "prs": prs, "terminals": terminals, "dispatches": dispatches}


# ------------------------------------------------------------------ conditions
def wave_of(orch):
    out = {}
    for n, ids in enumerate(orch.get("waves") or [], 1):
        for i in ids or []:
            out.setdefault(i, n)
    return out


def plan_from_summary(orch):
    """-> (plan dict for compute_slot_free, contention_note|None). Missing/garbled contention FAILS CLOSED."""
    waves = [{"wave": n, "items": [{"id": i} for i in ids]} for n, ids in enumerate(orch.get("waves") or [], 1)]
    cont = orch.get("contention")
    note = None
    if isinstance(cont, list):
        pairs = cont
    else:
        ids = [i for w in orch.get("waves") or [] for i in w]
        pairs = [{"a": a, "b": b} for n, a in enumerate(ids) for b in ids[n + 1:]]
        note = "contention missing from the run summary: fail closed, every pair of items treated as conflicting"
    return {"waves": waves, "contention": pairs}, note


def _age(now, ts):
    t = ostate.parse_ts(ts)
    return None if t is None else max(0, int((now - t).total_seconds()))


def build_conditions(orch, states, g, events, th):
    """-> list of condition dicts {verdict, item, wave, signature, detail}, UNSORTED. Pure given its inputs."""
    now = g["now"]
    waves = wave_of(orch)
    conds = []
    dispatch_latest = latest_by_item(events, ro.KIND_DISPATCH)

    def add(verdict, item, evidence, detail):
        conds.append({"verdict": verdict, "item": item, "wave": waves.get(item, 10 ** 6),
                      "signature": "%s|%s|%s" % (verdict, item, evidence), "detail": one_line(detail)})

    for iid, res in sorted(states.items()):
        st, sig = res["state"], res["signals"]
        srow = orch["items"].get(iid) or {}
        if st == "QUESTION_PENDING":
            pq = (g["items"].get(iid) or {}).get("pendingQuestion")
            tid = pq.get("threadId") if isinstance(pq, dict) else None
            age = sig.get("question_age_seconds")
            add("QUESTION_PENDING", iid, "thread=%s" % tid,
                "%s: threadId=%s age=%s; %s" % (iid, tid, "%ds" % age if age is not None else "unknown", res["detail"]))
        elif st == "CRASHED":
            add("ITEM_CRASHED", iid, res["detail"], "%s: %s" % (iid, res["detail"]))
        elif st == "FAILED":
            add("ITEM_FAILED", iid, "pr=%s:%s:%s" % (sig.get("pr_number"), sig.get("pr_state"), res["detail"]),
                "%s: %s" % (iid, res["detail"]))
        elif st == "STALLED":
            add("ITEM_STALLED", iid, "since=%s" % res["since"], "%s: %s" % (iid, res["detail"]))
        elif st == "UNKNOWN":
            # the summary was re-read after this poll's writes: a fresh UNKNOWN has age 0 and does not fire.
            since = srow.get("since") if srow.get("state") == "UNKNOWN" else None
            age = _age(now, since)
            if srow.get("state") == "UNKNOWN" and (age is None or age > th["dispatch_seconds"]):
                add("ITEM_STALLED", iid, "unknown-since=%s" % since,
                    "%s: UNKNOWN for %s (limit %ss): %s" % (
                        iid, "an unreadable duration" if age is None else "%ds" % age, th["dispatch_seconds"], res["detail"]))
        if st in PRE_RUNNING:
            ev = dispatch_latest.get(iid)
            d = ev.get("dispatch") if isinstance(ev, dict) else None
            if isinstance(d, dict) and d.get("outcome") == "DISPATCH_FAILED":
                add("DISPATCH_FAILED", iid, "ts=%s|%s" % (ev.get("ts"), d.get("reason")),
                    "%s: dispatch failed (%s) at %s" % (iid, d.get("reason") or "no reason given", ev.get("ts")))
    return conds


def slot_condition(orch, states, max_parallel):
    plan, note = plan_from_summary(orch)
    try:
        res = ostate.compute_slot_free(plan, states, orch.get("lanes") or [], max_parallel)
    except ValueError as exc:
        raise UsageError("cannot compute slots: %s" % exc)
    if not res["slot_free"]:
        return None, res
    first = res["eligible"][0]
    detail = "free lane(s) %s; first eligible %s (eligible: %s; wave %s)" % (
        ",".join(str(n) for n in res["free_lanes"]), first, ",".join(res["eligible"]), res["current_wave"])
    if note:
        detail += "; " + note
    return {"verdict": "SLOT_FREE", "item": first, "wave": res["current_wave"] or 0,
            "signature": "SLOT_FREE|%s|lanes=%s|eligible=%s" % (
                first, ",".join(str(n) for n in res["free_lanes"]), ",".join(res["eligible"])),
            "detail": detail}, res


def pick(conds):
    """Highest priority verdict, then lowest wave, then item id."""
    best = None
    for c in conds:
        key = (PRIORITY.index(c["verdict"]), c["wave"], c["item"])
        if best is None or key < best[0]:
            best = (key, c)
    return best[1] if best else None


def latest_by_signature(events):
    out = {}
    for ev in events:
        if ev.get("kind") == ro.KIND_VERDICT and isinstance(ev.get("signature"), str):
            out[ev["signature"]] = ev
    return out


def suppressed(cond, events, now, repeat_after):
    # Keyed on the SIGNATURE (verdict + item + evidence), not the item's latest verdict: one item can hold two live
    # conditions at once (DISPATCH_FAILED + the SLOT_FREE it is first-eligible for; DISPATCH_FAILED + ITEM_STALLED).
    # Comparing against the item's latest event let the pair alternate forever (PR #1343 QA), the very busy-loop
    # suppression exists to stop. Each condition is now judged against ITS OWN last emission.
    last = latest_by_signature(events).get(cond["signature"])
    if not last:
        return False
    t = ostate.parse_ts(last.get("ts"))
    if t is None:
        return False
    delta = (now - t).total_seconds()
    if delta < -ostate.DEFAULT_THRESHOLDS["clock_skew_seconds"]:
        return False      # stamped in the future (clock skew / a jumped clock): its age is unknowable, never silence a live condition
    return max(0, delta) < repeat_after


# ------------------------------------------------------------------ token telemetry (XACA-1808)
def team_orch_of(board):
    rc = board.get("releaseConfig")
    return rc.get("orchestration") if isinstance(rc, dict) else None


def tokens_due(stored, now, interval, newly_done):
    """Pure. Refresh when there is no usable stored block, an item newly reached DONE, the block is older than interval, or its
    updatedAt is ahead of now by more than the clock-skew allowance (a skewed / jumped clock must not freeze the throttle)."""
    if newly_done or not isinstance(stored, dict):
        return True
    t = ostate.parse_ts(stored.get("updatedAt"))
    if t is None:
        return True
    age = (now - t).total_seconds()
    if age < -ostate.DEFAULT_THRESHOLDS["clock_skew_seconds"]:
        return True
    return age >= interval


def token_conditions(tokens, budgets, orch):
    """Pure. -> condition dicts for MODEL_MISMATCH and TOKEN_BUDGET from a contract block. Signatures are stable per
    (item|run, cause): no token count appears in them, so a growing total never re-fires a suppressed condition."""
    waves = wave_of(orch)
    conds = []
    if not isinstance(tokens, dict):
        return conds
    for m in tokens.get("modelMismatch") or []:
        obs = ",".join(m.get("observed") or [])
        conds.append({"verdict": "MODEL_MISMATCH", "item": m["item"], "wave": waves.get(m["item"], 10 ** 6),
                      "signature": "MODEL_MISMATCH|%s|expected=%s|observed=%s" % (m["item"], m.get("expected"), obs),
                      "detail": one_line("%s: dispatched with model %s but a worker session used %s: the configured model did "
                                         "not take effect (warn-only; no worker was touched)" % (m["item"], m.get("expected"), obs)),
                      "event": {"kind": ro.KIND_MODEL_MISMATCH, "fields": {"item": m["item"], "expected": m.get("expected"),
                                                                           "observed": m.get("observed")}}})
    if isinstance(tokens.get("run"), dict):
        for c in otok.check_budgets(tokens, budgets):
            if c["scope"] == "item":
                who, sig_scope = c["item"], "item|limit=%d" % c["limit"]
                label = "%s used %d tokens, over its perTicket budget of %d" % (c["item"], c["used"], c["limit"])
            else:
                who, sig_scope = "-", "run|limit=%d" % c["limit"]
                label = "the run used %d tokens, over its perRun budget of %d" % (c["used"], c["limit"])
            conds.append({"verdict": "TOKEN_BUDGET", "item": who, "wave": waves.get(who, 10 ** 6),
                          "signature": "TOKEN_BUDGET|%s|%s" % (who, sig_scope),
                          "detail": one_line("%s: PAUSE NEW dispatches and ask the lead (kb-msg) whether to continue; do NOT "
                                             "stop or kill any worker (warn-only; delivered ONCE: keep the pause sticky until the lead answers)" % label),
                          "event": {"kind": ro.KIND_TOKEN_BUDGET, "fields": {
                              "scope": c["scope"], "item": c["item"], "used": c["used"], "limit": c["limit"]}}})
    return conds


def refresh_tokens(ctx, board, orch, events, run, kdir, now, write, board_file):
    """Compute the report (a ledger/board problem becomes `complete: false`, never an exception) and, when `write`, store the
    contract block under the board lock. -> the full report."""
    rep = otok.collect_run(ctx.release_id, orch, board.get("backlog") or [], events, run, ctx.projects_dir, kanban_dir=kdir,
                           now=ro._ts(now), cache=ctx.token_cache, worktrees_root=ctx.worktrees_root)
    if write:
        ro.write_tokens(board_file, ctx.release_id, run, rep["tokens"])
    return rep


def token_step(ctx, board_file, kdir, board, run, orch, events, g, changes, read_only):
    """One poll's telemetry. -> (tokens block | None, budgets). Telemetry must never break the monitor: anything unexpected
    is warned about once and the poll goes on without token conditions."""
    budgets, _src, warns = otok.resolve_budgets(orch, team_orch_of(board))
    for w in warns:
        ctx.warn(w)
    stored = orch.get("tokens") if isinstance(orch.get("tokens"), dict) else None
    newly_done = any(new == "DONE" for _i, _o, new in changes)
    try:
        if tokens_due(stored, g["now"], ctx.tokens_interval, newly_done):
            rep = refresh_tokens(ctx, board, orch, events, run, kdir, g["now"], not read_only, board_file)
            return rep["tokens"], budgets
    except (ro.LedgerError, OSError, ValueError, KeyError, TypeError) as exc:
        ctx.warn("token telemetry refresh failed: %s" % one_line(exc))
    return stored, budgets


def send_token_summary(ctx, kdir, orch, run, rep, lines):
    """Append the ledger `token_summary` and tell the lead. A kb-msg failure is warned about and changes nothing else."""
    t = rep["tokens"]
    ro.ledger_append(kdir, run, ro.KIND_TOKEN_SUMMARY, now=ctx.clock(), totals=t["run"], total=otok.total_of(t["run"]),
                     coordinator=t["coordinator"], complete=t["complete"], unattributed=t["unattributed"],
                     modelMismatch=len(t["modelMismatch"]), items=len(t["perItem"]))
    lead = orch.get("lead") or orch.get("coordinator")
    if isinstance(lead, dict):          # kanban-helpers.sh accepts the coordinator as "team:terminal" or {address}
        lead = lead.get("address")
    text = ("%s complete: %d tokens over %d turns (input %d, cacheCreate %d, cacheRead %d, output %d), model %s, %d ticket(s), "
            "telemetry %s, %d unattributed session(s), %d model mismatch(es)" % (
                run, otok.total_of(t["run"]), t["run"]["turns"], t["run"]["input"], t["run"]["cacheCreate"],
                t["run"]["cacheRead"], t["run"]["output"], t["run"]["model"] or "unobserved", len(t["perItem"]),
                "complete" if t["complete"] else "INCOMPLETE", t["unattributed"], len(t["modelMismatch"])))
    if not isinstance(lead, str) or not lead:
        ctx.warn("token summary not sent: the run has neither release.orchestration.lead nor a coordinator address")
        return
    try:
        ctx.msg(lead, text)
        lines.append("token summary sent to %s" % lead)
    except Exception as exc:  # noqa: BLE001 -- a kb-msg failure must never change the verdict
        ctx.warn("token summary to %s failed: %s" % (lead, one_line(exc)))


# ------------------------------------------------------------------ poll
class Result(object):
    def __init__(self, verdict, run, item, detail, lines=None, extra=None):
        self.verdict, self.run, self.item, self.detail = verdict, run, item, detail
        self.lines = lines or []
        self.extra = extra or {}

    @property
    def code(self):
        return EXIT[self.verdict]

    def render(self):
        return "\n".join(self.lines + [verdict_line(self.verdict, self.run, self.item, self.detail)])


def lane_lines(orch):
    out = []
    for ln in ro.lanes_view(orch):
        cur = ln.get("current")
        if isinstance(cur, dict):
            occ = "%s [%s/%s]%s" % (cur.get("id"), cur.get("status"), cur.get("stage"),
                                    " PR #%s" % cur["prNumber"] if cur.get("prNumber") else "")
        else:
            occ = "free"
        out.append("lane %s: %s; queue: %s" % (ln["lane"], occ, ", ".join(ln["queue"]) or "-"))
    return out


def _summary_after(ctx, rel_unused=None):
    board_file, kdir, board, rel = locate_release(ctx)
    rid, orch = active_orch(ctx, rel)
    return board_file, kdir, board, rel, rid, orch


def _max_parallel(orch):
    mp = orch.get("maxParallel")
    if isinstance(mp, bool) or not isinstance(mp, int) or mp < 1:
        raise UsageError("summary maxParallel is invalid: %r" % (mp,))
    return mp


def poll(ctx, once=False, read_only=False):
    """One level-triggered poll. Never raises UsageError (it becomes a USAGE Result)."""
    try:
        return _poll(ctx, once, read_only)
    except UsageError as exc:
        return Result("USAGE", ctx.run, None, str(exc))
    except ValueError as exc:       # resolve_thresholds
        return Result("USAGE", ctx.run, None, "bad configuration: %s" % exc)
    except ro.LedgerError as exc:
        return Result("USAGE", ctx.run, None, "ledger/summary write refused: %s" % exc)


def _sync_lanes(ctx, board_file, kdir, run, orch, states, now, lines):
    """LEVEL-TRIGGERED lane sync (PR #1343 review): every in-flight item (state neither QUEUED nor DONE/CANCELLED) that
    holds no lane gets the lowest free one via assign_lane, so lanes[] - which ticket-lamp shows and kb-dispatch's
    LANES_FULL counts - reflects reality even when nothing called assign_lane at dispatch time. Items are taken in plan
    order (wave, then position). No free lane: skipped (capacity is still enforced by compute_slot_free's in-flight
    count). Returns True iff a lane was assigned."""
    laned = set()
    for ln in orch.get("lanes") or []:
        cur = ln.get("current") if isinstance(ln, dict) else None
        cid = cur.get("id") if isinstance(cur, dict) else cur
        if isinstance(cid, str) and cid:
            laned.add(cid)
    order = [i for w in orch.get("waves") or [] for i in (w if isinstance(w, list) else [])]
    order += sorted(i for i in states if i not in order)
    changed = False
    for iid in order:
        st = (states.get(iid) or {}).get("state")
        if iid in laned or st in ostate.TERMINAL_STATES or st in (None, "QUEUED"):
            continue
        try:
            n = ro.assign_lane(board_file, kdir, ctx.release_id, run, iid, now=now)
        except ro.LedgerError as exc:
            lines.append("lane sync: %s holds no lane (%s)" % (iid, exc))
            continue
        lines.append("lane sync: %s -> lane %s" % (iid, n))
        changed = True
    return changed


def _poll(ctx, once, read_only):
    board_file, kdir, board, rel, run, orch = _summary_after(ctx)
    events = read_ledger(ctx, kdir, run)
    g = gather(ctx, rel, board, board_file, run, orch, events)
    states = ostate.derive_states(g["items"], g["windows"], g["panes"], g["prs"], g["now"], g["thresholds"])
    for iid in orch["items"]:                 # a tracked item missing from the backlog is UNKNOWN, never silently absent
        if iid not in states:
            states[iid] = ostate.derive_item_state(None, None, None, None, g["now"], g["thresholds"])
    lines, changes = [], []
    for iid, srow in sorted(orch["items"].items()):
        cur = states[iid]["state"]
        if (srow or {}).get("state") != cur:
            changes.append((iid, (srow or {}).get("state"), cur))
    if changes and not read_only:
        for iid, old, new in changes:
            extra = {}
            if states[iid]["signals"].get("pr_number") is not None:
                extra["prNumber"] = states[iid]["signals"]["pr_number"]
            ro.record_state(board_file, kdir, ctx.release_id, run, iid, new, detail=states[iid]["detail"],
                            now=g["now"], **extra)
            lines.append("transition %s: %s -> %s (%s)" % (iid, old, new, states[iid]["detail"]))
        board_file, kdir, board, rel, run, orch = _summary_after(ctx)     # re-read: since/lanes are now current
    if not read_only and _sync_lanes(ctx, board_file, kdir, run, orch, states, g["now"], lines):
        board_file, kdir, board, rel, run, orch = _summary_after(ctx)
    lines.extend(lane_lines(orch))
    th = g["thresholds"]
    conds = build_conditions(orch, states, g, events, th)
    if ctx.tokens_interval is not None:
        tokens, budgets = token_step(ctx, board_file, kdir, board, run, orch, events, g, changes, read_only)
        tok_conds = token_conditions(tokens, budgets, orch)
        conds.extend(tok_conds)
        if not read_only:
            seen = {(e.get("kind"), e.get("signature")) for e in events}
            for c in tok_conds:
                k = c["event"]["kind"]
                if (k, c["signature"]) not in seen:
                    ro.ledger_append(kdir, run, k, now=g["now"], signature=c["signature"], **c["event"]["fields"])
    slot, slot_res = slot_condition(orch, states, _max_parallel(orch))
    if slot:
        conds.append(slot)
    done = all(r["state"] in ostate.TERMINAL_STATES for r in states.values())
    if done:
        # XACA-1808-008: every item is terminal, so a warn-only telemetry condition has nothing left to pause or re-dispatch. It
        # was already ledgered above (and is counted in the token_summary); it must not outrank ALL_DONE, which `--once` (never
        # suppressed) would otherwise mask forever, so the run would never close and the lead would never get the summary.
        conds = [c for c in conds if c["verdict"] not in TELEMETRY_VERDICTS]
        conds.append({"verdict": "ALL_DONE", "item": "-", "wave": 0, "signature": "ALL_DONE|-|-",
                      "detail": "all %d tracked item(s) are DONE or CANCELLED" % len(states)})
    extra = {"states": states, "slot": slot_res, "changes": changes}
    # XACA-1808-014: --once never suppresses EXCEPT the two warn-only verdicts, which are delivered once per signature per
    # repeat window even under --once (a permanent MODEL_MISMATCH would otherwise outrank SLOT_FREE forever).
    live = [c for c in conds if c["verdict"] == "ALL_DONE"
            or (once and c["verdict"] not in TELEMETRY_VERDICTS)
            or not suppressed(c, events, g["now"], ctx.repeat_after)]
    top = pick(live)
    if top is None:
        counts = {}
        for r in states.values():
            counts[r["state"]] = counts.get(r["state"], 0) + 1
        why = "nothing actionable: " + " ".join("%s=%d" % kv for kv in sorted(counts.items()))
        n_sup = len(conds) - len(live)
        if n_sup:
            why += "; %d condition(s) suppressed (already escalated, repeat-after %ss)" % (n_sup, ctx.repeat_after)
        return Result("PENDING", run, None, why, lines, extra)
    if not read_only:
        ro.ledger_append(kdir, run, ro.KIND_VERDICT, now=g["now"], item=top["item"], verdict=top["verdict"],
                         signature=top["signature"], detail=top["detail"])
        if top["verdict"] == "ALL_DONE":
            if ctx.tokens_interval is not None:
                try:
                    final = refresh_tokens(ctx, board, orch, events, run, kdir, g["now"], True, board_file)
                    send_token_summary(ctx, kdir, orch, run, final, lines)
                except (ro.LedgerError, OSError, ValueError, KeyError, TypeError) as exc:
                    ctx.warn("final token summary failed: %s" % one_line(exc))
            ro.close_run(board_file, kdir, ctx.release_id, run, outcome="complete", detail=top["detail"], now=g["now"])
            lines.append("run %s closed (complete)" % run)
    return Result(top["verdict"], run, top["item"], top["detail"], lines, extra)


# ------------------------------------------------------------------ watch / status
def watch(ctx, once=False):
    """-> Result. `once`: exactly one poll, PENDING when nothing is actionable. Otherwise loop until a verdict or TIMEOUT."""
    start = ctx.clock()
    while True:
        res = poll(ctx, once=once)
        if once or res.verdict not in ("PENDING",):
            return res
        elapsed = (ctx.clock() - start).total_seconds()
        if elapsed >= ctx.timeout:
            res = Result("TIMEOUT", res.run, None, "no actionable condition within %ss; last poll: %s" % (ctx.timeout, res.detail),
                         res.lines, res.extra)
            try:
                _b, kdir, _bd, _r, run, _o = _summary_after(ctx)
                ro.ledger_append(kdir, run, ro.KIND_VERDICT, now=ctx.clock(), item="-", verdict="TIMEOUT",
                                 signature="TIMEOUT|-|-", detail=res.detail)
            except (UsageError, ro.LedgerError):
                pass
            return res
        # a poll's human lines are only worth printing when something happened; keep the loop quiet otherwise
        if res.lines:
            print("\n".join(res.lines), file=ctx.out)
        ctx.sleep(max(0, min(ctx.interval, ctx.timeout - elapsed)))


def status(ctx, with_tokens=False):
    """-> (Result, view|None). READ-ONLY: never writes the board or the ledger. with_tokens only COMPUTES the telemetry
    (view["tokens"] = the full report, or {"error": ...}); it is never stored."""
    try:
        board_file, kdir, board, rel, run, orch = _summary_after(ctx)
        try:
            events = list(ro.ledger_read(kdir, run))
            ledger_error = None
        except ro.LedgerError as exc:
            events, ledger_error = [], str(exc)
        g = gather(ctx, rel, board, board_file, run, orch, events)
        states = ostate.derive_states(g["items"], g["windows"], g["panes"], g["prs"], g["now"], g["thresholds"])
        for iid in orch["items"]:
            if iid not in states:
                states[iid] = ostate.derive_item_state(None, None, None, None, g["now"], g["thresholds"])
    except UsageError as exc:
        return Result("USAGE", ctx.run, None, str(exc)), None
    except ValueError as exc:
        return Result("USAGE", ctx.run, None, "bad configuration: %s" % exc), None
    waves = wave_of(orch)
    items = {}
    for iid, srow in sorted(orch["items"].items()):
        srow = srow or {}
        pr = g["prs"].get(iid)
        items[iid] = {"wave": waves.get(iid), "terminal": g["terminals"].get(iid), "summaryState": srow.get("state"),
                      "derivedState": states[iid]["state"], "detail": states[iid]["detail"], "since": srow.get("since"),
                      "pr": pr, "pane": g["panes"].get(iid)}
    view = {"run": run, "release": ctx.release_id, "startedAt": orch.get("startedAt"), "closedAt": orch.get("closedAt"),
            "coordinator": orch.get("coordinator"), "maxParallel": orch.get("maxParallel"), "waves": orch.get("waves"),
            "items": items, "lanes": ro.lanes_view(orch), "contentionStored": isinstance(orch.get("contention"), list),
            "thresholds": {"values": g["thresholds"], "sources": g["sources"]}, "now": ro._ts(g["now"]),
            "ledgerError": ledger_error}
    if with_tokens:
        try:
            view["tokens"] = otok.collect_run(ctx.release_id, orch, board.get("backlog") or [], events, run, ctx.projects_dir,
                                              kanban_dir=kdir, now=ro._ts(g["now"]), cache=ctx.token_cache,
                                              worktrees_root=ctx.worktrees_root)
        except (OSError, ValueError, KeyError, TypeError) as exc:
            view["tokens"] = {"error": one_line(exc)}
    n = sum(1 for v in items.values() if v["summaryState"] != v["derivedState"])
    return Result("STATUS", run, None, "%d item(s), %d differ from the summary" % (len(items), n)), view


def format_status(view):
    L = ["Run %s  release %s" % (view["run"], view["release"]),
         "started %s  coordinator %s  maxParallel %s%s" % (
             view["startedAt"], view["coordinator"], view["maxParallel"],
             "  CLOSED %s" % view["closedAt"] if view["closedAt"] else "")]
    for n, ids in enumerate(view["waves"] or [], 1):
        L.append("wave %d: %s" % (n, ", ".join(ids)))
    for iid, v in view["items"].items():
        pr = v["pr"]
        prs = "-" if not pr else ("error: %s" % pr["error"] if "error" in pr else "#%s %s" % (pr.get("number"), pr.get("state")))
        L.append("  %s  terminal=%s  summary=%s  derived=%s  since=%s  pr=%s" % (
            iid, v["terminal"], v["summaryState"], v["derivedState"], v["since"], prs))
    for ln in view["lanes"]:
        cur = ln["current"]
        L.append("lane %s: %s; queue: %s" % (ln["lane"], (cur or {}).get("id") if isinstance(cur, dict) else "free",
                                              ", ".join(ln["queue"]) or "-"))
    t = view["thresholds"]
    L.append("thresholds: " + ", ".join("%s=%s (%s)" % (k, t["values"][k], t["sources"][k]) for k in sorted(t["values"])))
    if view["ledgerError"]:
        L.append("ledger: UNREADABLE: %s" % view["ledgerError"])
    tk = view.get("tokens")
    if isinstance(tk, dict) and "error" in tk:
        L.append("tokens: ERROR: %s" % tk["error"])
    elif isinstance(tk, dict):
        L.extend(otok.format_table(tk))
    return L


# ------------------------------------------------------------------ tokens subcommand (XACA-1808-B/007)
def _find_item(kdir, item_id):
    """-> (item dict | None, note | None). Scans every *-board.json under kdir; never fatal (points just stay null)."""
    import glob
    seen = []
    for path in sorted(glob.glob(os.path.join(kdir, "*-board.json"))):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                board = json.load(fh)
        except (OSError, ValueError) as exc:
            seen.append("%s unreadable (%s)" % (path, type(exc).__name__))
            continue
        for it in board.get("backlog") or [] if isinstance(board, dict) else []:
            if isinstance(it, dict) and it.get("id") == item_id:
                return it, None
    return None, "item %s not found on any board under %s%s: tokensPerPoint is null" % (
        item_id, kdir, " (" + "; ".join(seen) + ")" if seen else "")


def tokens_cmd(args, out, overrides):
    """-> exit code. 0 report produced, 2 usage / board / run problem, 3 data unreadable or partial (report still printed)."""
    def fail(msg):
        print("Error: %s" % msg, file=sys.stderr)
        return 2
    if bool(args.run) == bool(args.item):
        return fail("tokens needs exactly one of <RUN-ID> or --item <ID>")
    since = None
    if args.since:
        since = otok.parse_ts(args.since)
        if since is None:
            return fail("--since %r is not an ISO timestamp" % args.since)
    ctx = Ctx(args.release or "-", board=args.board, kanban_dir=args.kanban_dir, projects_dir=args.projects_dir,
              worktrees_root=args.worktrees_root, **{k: v for k, v in overrides.items() if k != "out"})
    now = ro._ts(ctx.clock())
    extra_problems, budget_info = [], None
    if args.item:
        kdir = os.path.abspath(args.kanban_dir or (os.path.dirname(os.path.abspath(args.board)) if args.board else None)
                               or ctx.env.get("KB_KANBAN_DIR") or default_kanban_dir(ctx.repo_root))
        item, note = _find_item(kdir, args.item)
        rep = otok.collect_item(args.item, item, ctx.projects_dir, now=now, since=since, cache=ctx.token_cache)
        if note:
            rep.setdefault("notes", []).append(note)
    else:
        if not ro.run_id_valid(args.run):
            return fail("%r is not a run id (expected RUN-<REL-ID>-<yyyymmddThhmmss>)" % args.run)
        ctx.release_id = ro.run_release(args.run)
        try:
            board_file, kdir, board, rel = locate_release(ctx)
        except UsageError as exc:
            return fail(str(exc))
        orch = rel.get("orchestration")
        if not isinstance(orch, dict) or orch.get("activeRunId") != args.run:
            return fail("%s is not the current run of %s (the board's summary holds %s)" % (
                args.run, ctx.release_id, orch.get("activeRunId") if isinstance(orch, dict) else "none"))
        try:
            events = list(ro.ledger_read(kdir, args.run))
        except ro.LedgerCorrupt as exc:
            events = exc.events
            extra_problems.append("ledger corrupt (fail closed, readable lines used): %s" % exc)
        except ro.LedgerError as exc:
            events = []
            extra_problems.append("ledger unreadable: %s" % exc)
        rep = otok.collect_run(ctx.release_id, orch, board.get("backlog") or [], events, args.run, ctx.projects_dir,
                               kanban_dir=kdir, now=now, since=since, cache=ctx.token_cache, worktrees_root=ctx.worktrees_root)
        limits, sources, warns = otok.resolve_budgets(orch, team_orch_of(board))
        for w in warns:
            ctx.warn(w)
        rep["budget"] = {"limits": limits, "sources": sources, "warnings": warns,
                         "over": otok.check_budgets(rep["tokens"], limits)}
    if extra_problems:
        rep["problems"] = list(rep["problems"]) + extra_problems
        rep["complete"] = rep["tokens"]["complete"] = False
    if args.json:
        print(json.dumps(rep, sort_keys=True, indent=2), file=out)
    else:
        for ln in otok.format_table(rep):
            print(ln, file=out)
        for o in (rep.get("budget") or {}).get("over", []):
            print("over budget: %s %s used %d > limit %d" % (o["scope"], o["item"] or "run", o["used"], o["limit"]), file=out)
        for m in rep["tokens"]["modelMismatch"]:
            print("MODEL MISMATCH %s: expected %s, observed %s" % (m["item"], m["expected"], ",".join(m["observed"])), file=out)
    return 0 if rep["complete"] else 3


# ------------------------------------------------------------------ CLI
class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)

    def exit(self, status=0, message=None):
        raise UsageError(message or "exit")


def build_parser():
    ap = _Parser(prog="kb-release-orchestrate", add_help=False, description="Release orchestrator monitor (XACA-1546-003).")
    ap.add_argument("-h", "--help", action="store_true")
    sub = ap.add_subparsers(dest="cmd", parser_class=_Parser)

    def common(p):
        p.add_argument("release")
        p.add_argument("--run")
        p.add_argument("--stall-seconds")
        p.add_argument("--dispatch-seconds")
        p.add_argument("--board")
        p.add_argument("--kanban-dir")
        p.add_argument("--repo")
        p.add_argument("--projects-dir")
        p.add_argument("--worktrees-root")
    w = sub.add_parser("watch", add_help=False)
    common(w)
    w.add_argument("--tokens-interval", default=str(DEFAULT_TOKENS_INTERVAL))
    w.add_argument("--once", action="store_true")
    w.add_argument("--interval", default=str(DEFAULT_INTERVAL))
    w.add_argument("--timeout", default=str(DEFAULT_TIMEOUT))
    w.add_argument("--repeat-after", default=str(DEFAULT_REPEAT_AFTER))
    s = sub.add_parser("status", add_help=False)
    common(s)
    s.add_argument("--json", action="store_true")
    s.add_argument("--tokens", action="store_true")
    t = sub.add_parser("tokens", add_help=False)
    t.add_argument("run", nargs="?")
    t.add_argument("--item")
    t.add_argument("--json", action="store_true")
    t.add_argument("--since")
    t.add_argument("--board")
    t.add_argument("--kanban-dir")
    t.add_argument("--projects-dir")
    t.add_argument("--worktrees-root")
    return ap


USAGE_TEXT = ("usage: kb-release-orchestrate watch <REL-ID> [--run RUN] [--once] [--interval S] [--timeout S] [--repeat-after S] "
              "[--stall-seconds N] [--dispatch-seconds N] [--board FILE] [--kanban-dir DIR] [--repo owner/repo]\n"
              "       kb-release-orchestrate status <REL-ID> [--json] [--tokens] [--run RUN] [same input flags]\n"
              "       kb-release-orchestrate tokens <RUN-ID> [--json] [--since ISO] [--board FILE] [--kanban-dir DIR] [--projects-dir DIR]\n"
              "       kb-release-orchestrate tokens --item <ID> [--json] [--since ISO] [--kanban-dir DIR] [--projects-dir DIR]\n"
              "       (watch also: [--tokens-interval S] [--projects-dir DIR] [--worktrees-root DIR]; tokens exit: 0 ok, 2 usage, 3 incomplete data)")


def _num(name, raw, minimum=0):
    try:
        v = float(raw)
    except (TypeError, ValueError):
        raise UsageError("%s must be a number, got %r" % (name, raw))
    if v != v or v in (float("inf"), float("-inf")) or v < minimum:
        raise UsageError("%s must be a finite number >= %s, got %r" % (name, minimum, raw))
    return v


def main(argv=None, **overrides):
    argv = list(sys.argv[1:] if argv is None else argv)
    out = overrides.get("out") or sys.stdout
    try:
        args = build_parser().parse_args(argv)
        if args.help:
            print(USAGE_TEXT, file=out)
            print(verdict_line("HELP", None, None, "usage printed, no run was monitored"), file=out)
            return 0
        if not args.cmd:
            raise UsageError("a subcommand (watch | status | tokens) is required")
        if args.cmd == "tokens":
            args.release = None
            return tokens_cmd(args, out, overrides)
        cli = {}
        if args.stall_seconds is not None:
            cli["stall_seconds"] = args.stall_seconds
        if args.dispatch_seconds is not None:
            cli["dispatch_seconds"] = args.dispatch_seconds
        kw = dict(run=args.run, board=args.board, kanban_dir=args.kanban_dir, repo=args.repo, cli_thresholds=cli)
        if args.cmd == "watch":
            kw.update(interval=_num("--interval", args.interval), timeout=_num("--timeout", args.timeout),
                      repeat_after=_num("--repeat-after", args.repeat_after),
                      tokens_interval=_num("--tokens-interval", args.tokens_interval))
        kw.update(projects_dir=args.projects_dir, worktrees_root=args.worktrees_root)
        kw.update({k: v for k, v in overrides.items() if k != "out"})
        ctx = Ctx(args.release, out=out, **kw)
    except UsageError as exc:
        print("Error: %s" % exc, file=sys.stderr)
        print(USAGE_TEXT, file=sys.stderr)
        print(verdict_line("USAGE", None, None, str(exc)), file=out)
        return 2
    if args.cmd == "watch":
        res = watch(ctx, once=args.once)
        print(res.render(), file=out)
        if res.verdict == "USAGE":
            print("Error: %s" % res.detail, file=sys.stderr)
        return res.code
    res, view = status(ctx, with_tokens=args.tokens)
    if view is None:
        print("Error: %s" % res.detail, file=sys.stderr)
        print(verdict_line("USAGE", res.run, None, res.detail), file=out)
        return 2
    if args.json:
        print(json.dumps(view, sort_keys=True, indent=2), file=out)
    else:
        res.lines = format_status(view)
        print(res.render(), file=out)
    return 0
