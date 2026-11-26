"""XACA-1546-003: the release orchestrator monitor (EPIC-0072). Logic behind `scripts/kb-release-orchestrate`.

Stdlib only, py3.9-safe. kanban-hooks/*.py is mirrored to the tap by sync-tap.sh's glob.

SYNOPSIS
  kb-release-orchestrate watch  <REL-ID> [--run RUN] [--once] [--interval S=30] [--timeout S=3600] [--repeat-after S=1800]
                                [--stall-seconds N] [--dispatch-seconds N] [--gate-stale-seconds N] [--board FILE]
                                [--kanban-dir DIR] [--repo owner/repo]
  kb-release-orchestrate status <REL-ID> [--json] [--run RUN] [--tokens] [same input flags]   (READ-ONLY, never writes)
  kb-release-orchestrate resume <REL-ID> [--coordinator team:terminal] [--json] [--dry-run] [same input flags]   (XACA-1547)
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
  11  QUESTION_PENDING  an item has an open pendingQuestion; detail carries threadId and question age. ALSO (XACA-1864,
                        channel=kb-msg) an UNREAD message in the coordinator's kb-msg inbox from a run worker (from_team = the
                        run's team, from_terminal = an in-flight item's latest DISPATCHED terminal, created_at >= that dispatch's
                        ts; kb-ask's own `[kb-ask ` rows and messages on an open pendingQuestion thread excluded): detail `<ITEM>: channel=kb-msg msg=<id8> thread=<id> age=<s>[ attribution=ambiguous]; <body[:120]>`.
                        The inbox is read READ-ONLY (plain JSONL read; never `kb-msg inbox`, never marks read); a missing file is
                        empty, an unreadable / malformed one is a warning. `kb-msg read <id>` / `kb-msg reply <id>` clears it.
  12  ITEM_STALLED      STALLED, or UNKNOWN persisted longer than dispatch_seconds (summary items[ID].since)
  13  ITEM_CRASHED      CRASHED (worker gone). The detail ends with the re-dispatch offer (XACA-1547-003):
                        `kb-dispatch <ID> --terminal <T> --run <RUN> --resume`, or ask the lead to cancel / re-plan
  14  ITEM_FAILED       FAILED (PR closed unmerged / terminal kb-pr-monitor verdict)
  15  DISPATCH_FAILED   the item's LATEST ledger `dispatch` event has outcome DISPATCH_FAILED and the item is still
                        QUEUED / DISPATCHING / UNKNOWN
  16  TOKEN_BUDGET      WARN-ONLY (XACA-1808): an item (perTicket) or the run (perRun) used MORE total tokens than its budget.
                        The detail tells the coordinator to PAUSE NEW dispatches and ask the lead. Nothing in code ever kills,
                        stops or nudges a worker because of it; the pause itself is the coordinator prompt's job (XACA-1548).
  17  MODEL_MISMATCH    WARN-ONLY (XACA-1808): a worker session observed a model that does not match the model its dispatch
                        recorded (the live proof that the model setting took effect). Detail names item, expected, observed.
                        XACA-1836: also the COORDINATOR session vs run meta models.coordinator.model, as item=coordinator.
  18  GATE_STALE        (XACA-1880-003, S7; a coordinator-side backstop to kb-pr-monitor's XACA-1876 STALE_APPROVAL) an
                        in-flight item's OPEN PR has a gate bot (EXACT login ds9-tester-bot[bot] / ai-security-review-bot[bot],
                        never user.type) whose latest APPROVED/CHANGES_REQUESTED review is on a commit other than the PR head,
                        NO such review of the head, and thresholds.gate_stale_seconds (default 3600 = kb-pr-monitor's 60 min;
                        KB_ORCH_GATE_STALE_SECONDS / gateStaleSeconds / --gate-stale-seconds) have passed since
                        max(head commit's committer date, that bot's stale review). A bot that never reviewed is "not launched
                        yet", not stale; COMMENTED reviews are ignored. Detail: `<ITEM>: pr=<N> head=<sha8>
                        stale_bots=<login>@<sha8>[,...] age=<s>; relaunch: kb-run-review <ITEM> --yes --delta <old sha>`
                        (kb-run-test for the tester; no --delta after CHANGES_REQUESTED, which re-runs in full). Reviews are
                        read ONLY for items with an OPEN PR (`gh api --paginate .../reviews --jq`, ctx.reviews), and the head
                        commit's date only when a bot is stale (ctx.commit_time). Either read failing is a warning and NO
                        verdict, never a crash and never a false GATE_STALE. watch only: status / resume never read reviews.
  31  TIMEOUT           watch: --timeout elapsed with nothing actionable
   0  WAVE0_DONE        (XACA-1873, a Wave 0 run only) every planning lane is terminal (DONE / INCOMPLETE / FAILED /
                        CANCELLED); the run is closed with close_run outcome=wave0. Shares 0 with ALL_DONE: read the NAME.

WAVE 0 (XACA-1873). A run whose summary has `phase: "wave0"` is a planning run: watch / status / resume derive each lane with
orchestrator_wave0.derive_lane (ledger plan_lane events + board stamp + window row + tmux; NO gh call) instead of
orchestrator_state, and reuse SLOT_FREE (the next QUEUED row takes a freed lane), QUESTION_PENDING, ITEM_STALLED,
ITEM_CRASHED (the offer is `kb-dispatch <ID> --plan ...`; a crashed lane keeps its lane) and DISPATCH_FAILED. ALL_DONE never
fires for it; WAVE0_DONE does. A lane that ends INCOMPLETE / FAILED raises no verdict of its own: it frees its lane, and the
re-plan after WAVE0_DONE refuses its ticket.

RESUME (XACA-1547; a coordinator that starts on a release with an active run calls this BEFORE anything else)
   0  RESUMED           rehydrated from the ledger, reconciled (the same derive-and-record step as a watch poll), optionally
                        re-attached (--coordinator: summary + every open item's orchestration.coordinator), and reported.
                        Per item: action live|closed|crashed|queued|failed|unknown, redispatch dispatch|resume|never (a Wave 0
                        run: plan|never, i.e. `kb-dispatch <ID> --plan`); every in-flight item is "never". Appends ONE
                        ledger `verdict` event, verdict RESUMED (not logged on --dry-run)
   4  NO_ACTIVE_RUN     no active open run on the release: start a new one
   2  USAGE             as for watch; a corrupt ledger is USAGE (fail closed), never a partial resume

PRIORITY when several hold (highest first): QUESTION_PENDING(11) > ITEM_CRASHED(13) > ITEM_FAILED(14) > DISPATCH_FAILED(15)
  > ITEM_STALLED(12) > GATE_STALE(18) > MODEL_MISMATCH(17) > TOKEN_BUDGET(16) > SLOT_FREE(10) > ALL_DONE(0). Ties within a
  verdict: lowest wave, then item id. (A question beats a crash because the answer is collected on resume; SLOT_FREE is lowest
  so a coordinator handles trouble before new work. GATE_STALE is trouble, but its worker may still be running, so it sits
  just below ITEM_STALLED. The two telemetry warnings sit just above SLOT_FREE: a coordinator must see "the model is
  wrong" / "budget blown" BEFORE it dispatches more work, but never ahead of a worker that is actually in trouble.)

UNKNOWN is never silently waited on forever, and one tmux hiccup must not fire a verdict: UNKNOWN only becomes ITEM_STALLED
once the summary says the item has BEEN UNKNOWN for longer than dispatch_seconds (record_state stamps `since` when it became
UNKNOWN, and the summary is re-read after this poll's writes, so a fresh UNKNOWN has age 0).

REPEAT SUPPRESSION (stops the coordinator busy-looping on a condition it already escalated). Every emitted verdict is appended
to the ledger as kind "verdict" {item, verdict, signature, detail}. signature = verdict | item | the evidence that would change
if the situation changed: QUESTION_PENDING threadId (channel=kb-msg: `msg=<message id>`); ITEM_CRASHED the derived detail; ITEM_FAILED PR number + state + detail;
DISPATCH_FAILED the dispatch event's ts + reason; ITEM_STALLED the lastActivity value (or the UNKNOWN `since`); GATE_STALE
`pr=<N>|head=<full sha>|stale=<login>@<full old sha>,...` (a new push or a fresh review changes it); SLOT_FREE the
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
WINDOW CLOSE (XACA-1875; write polls only, never status / resume --dry-run / read_only, never a Wave 0 run): after the lane
sync, a finished item's lane window <team>-<terminal>:<ITEM> is closed (`kill-window -t <pane id>`, ctx.tmux_kill) only when
ALL hold: (a) derived state DONE or CANCELLED; (b) board status completed or cancelled; (c) a window named EXACTLY <ITEM> (a
<ITEM>~crashed-* window is never touched); (d) that window has exactly one pane and its id equals the `pane` of the item's
latest DISPATCHED ledger event (no `pane` recorded = no identity proof = kept); (e) the pane is idle
(orchestrator_state.pane_idle: no busy marker, no dialog, and the same capture-pane tail hash on two consecutive polls; the
previous hash is read from the ledger, so `--once` polls and restarts behave the same); (f) no activeWindows row
<terminal>:<ITEM> is still working on an in_progress item. Ledger: lane action=window_closed {item, lane, pane, window} per
close; lane action=window_close_deferred {item, lane, pane, reason, tailHash} only when the item's reason or tail hash
changed, so a busy pane is ledgered once, not every poll. A kill-window / capture-pane failure is a warning, never a verdict;
the close step never changes which verdict is picked.
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
else the `<team>-board.json` file name. Env: KB_ORCH_TMUX (default tmux), KB_ORCH_GH (default gh), KB_ORCH_MAIL_DIR (default
~/.aiteamforge/mail: the kb-msg store whose <team>__<terminal>.jsonl is the coordinator inbox, XACA-1864), KB_KANBAN_DIR (default
<checkout>/kanban, or the MAIN checkout's kanban/ from a linked worktree with no board, when neither --board
nor --kanban-dir is given; on a TAP CONSUMER, where neither holds a board, resolve_kanban_dir() falls back to the current
tmux team's registry kanban dir, then the ONE registered board holding the release, else exit 2 naming --kanban-dir:
XACA-1878). Multiple panes in one window: a non-shell pane wins.
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
import orchestrator_wave0 as ow0  # noqa: E402
import release_orchestrator as ro  # noqa: E402

DEFAULT_REPO_ROOT = os.path.dirname(_HERE)
DEFAULT_INTERVAL = 30
DEFAULT_TIMEOUT = 3600
DEFAULT_REPEAT_AFTER = 1800
DEFAULT_TOKENS_INTERVAL = 120
TELEMETRY_VERDICTS = ("MODEL_MISMATCH", "TOKEN_BUDGET")   # warn-only; never block ALL_DONE

# verdict -> exit code
EXIT = {
    "ALL_DONE": 0, "HELP": 0, "STATUS": 0, "RESUMED": 0, "USAGE": 2, "PENDING": 3, "NO_ACTIVE_RUN": 4,
    "SLOT_FREE": 10, "QUESTION_PENDING": 11, "ITEM_STALLED": 12, "ITEM_CRASHED": 13, "ITEM_FAILED": 14,
    "DISPATCH_FAILED": 15, "TOKEN_BUDGET": 16, "MODEL_MISMATCH": 17, "GATE_STALE": 18, "TIMEOUT": 31, "WAVE0_DONE": 0,
}
PRIORITY = ("QUESTION_PENDING", "ITEM_CRASHED", "ITEM_FAILED", "DISPATCH_FAILED", "ITEM_STALLED", "GATE_STALE",
            "MODEL_MISMATCH", "TOKEN_BUDGET", "SLOT_FREE", "ALL_DONE", "WAVE0_DONE")
# XACA-1880-003: the two gate bots, by EXACT login (both are user.type "Bot": a type filter would let one gate's review
# satisfy the other). (role, login, relaunch command)
GATE_BOTS = (("tester", "ds9-tester-bot[bot]", "kb-run-test"), ("reviewer", "ai-security-review-bot[bot]", "kb-run-review"))
GATE_REVIEW_STATES = ("APPROVED", "CHANGES_REQUESTED")     # COMMENTED neither passes nor blocks a gate
_SHA_RE = re.compile(r"^[0-9a-fA-F]{7,64}$")
NOT_LOGGED = ("PENDING", "USAGE", "HELP", "STATUS", "NO_ACTIVE_RUN")
PRE_RUNNING = ("QUEUED", "DISPATCHING", "UNKNOWN")

TMUX_FORMAT = "#{session_name}\t#{window_name}\t#{pane_current_command}\t#{pane_id}"   # pane_id: XACA-1875
_PANE_ID_RE = re.compile(r"^%[0-9]+$")
CAPTURE_LINES = 15                 # XACA-1875: capture-pane -S -15, the tail pane_idle compares between polls


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


def real_tmux_kill(env=None):
    """XACA-1875 -> callable(pane_id) closing the window that holds that pane; raises RuntimeError on failure."""
    base = shlex.split((env or os.environ).get("KB_ORCH_TMUX") or "tmux")

    def fn(pane):
        rc, _out, err = _run(base + ["kill-window", "-t", pane], timeout=20)
        if rc != 0:
            raise RuntimeError("tmux kill-window -t %s rc=%d: %s" % (pane, rc, one_line(err)[:200]))
    return fn


def real_tmux_capture(env=None):
    """XACA-1875 -> callable(pane_id) returning the pane's last CAPTURE_LINES lines; raises RuntimeError on failure."""
    base = shlex.split((env or os.environ).get("KB_ORCH_TMUX") or "tmux")

    def fn(pane):
        rc, out, err = _run(base + ["capture-pane", "-p", "-t", pane, "-S", "-%d" % CAPTURE_LINES], timeout=20)
        if rc != 0:
            raise RuntimeError("tmux capture-pane -t %s rc=%d: %s" % (pane, rc, one_line(err)[:200]))
        return out
    return fn


def real_gh(env=None):
    """-> callable(repo, branch) returning the parsed JSON list; raises RuntimeError on any failure."""
    base = shlex.split((env or os.environ).get("KB_ORCH_GH") or "gh")

    def fn(repo, branch):
        rc, out, err = _run(base + ["pr", "list", "--repo", repo, "--head", branch, "--state", "all",
                                    "--json", "number,state,mergedAt,isDraft,headRefOid"], timeout=60)
        if rc != 0:
            raise RuntimeError("gh pr list rc=%d: %s" % (rc, one_line(err)[:200]))
        try:
            return json.loads(out)
        except ValueError as exc:
            raise RuntimeError("gh pr list returned non-JSON: %s" % exc)
    return fn


def real_reviews(env=None):
    """XACA-1880-003 -> callable(repo, pr_number) -> list of {login, state, commit_id, submitted_at}; raises RuntimeError on
    any failure. ALL pages (`gh api --paginate`), flattened by --jq to one compact object per line, parsed here: the gh JSON
    never passes through a shell variable."""
    base = shlex.split((env or os.environ).get("KB_ORCH_GH") or "gh")
    jq = ".[] | {login: .user.login, state: .state, commit_id: .commit_id, submitted_at: .submitted_at}"

    def fn(repo, pr):
        if not isinstance(pr, int) or isinstance(pr, bool):
            raise RuntimeError("PR number must be an int, got %r" % (pr,))
        rc, out, err = _run(base + ["api", "--paginate", "repos/%s/pulls/%d/reviews" % (repo, pr), "--jq", jq], timeout=60)
        if rc != 0:
            raise RuntimeError("gh api reviews rc=%d: %s" % (rc, one_line(err)[:200]))
        rows = []
        for line in out.splitlines():
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
            except ValueError as exc:
                raise RuntimeError("gh api reviews returned non-JSON: %s" % exc)
            if not isinstance(rec, dict):
                raise RuntimeError("gh api reviews returned a non-object row")
            rows.append(rec)
        return rows
    return fn


def real_commit_time(env=None):
    """XACA-1880-003 -> callable(repo, sha) -> the commit's committer date (ISO string); raises RuntimeError on any failure."""
    base = shlex.split((env or os.environ).get("KB_ORCH_GH") or "gh")

    def fn(repo, sha):
        if not isinstance(sha, str) or not _SHA_RE.match(sha):
            raise RuntimeError("not a commit sha: %r" % (sha,))
        rc, out, err = _run(base + ["api", "repos/%s/commits/%s" % (repo, sha), "--jq", ".commit.committer.date"], timeout=60)
        if rc != 0:
            raise RuntimeError("gh api commit rc=%d: %s" % (rc, one_line(err)[:200]))
        return out.strip()
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


_MAIL_SAFE_RE = re.compile(r"[^A-Za-z0-9._-]")      # msg-store.py _SAFE_RE: the inbox file name of a team / terminal token


def inbox_file(address, environ):
    """XACA-1864: the JSONL inbox of a "team:terminal" address, in msg-store.py's inbox_path layout
    (<mail dir>/<team>__<terminal>.jsonl). KB_ORCH_MAIL_DIR replaces ~/.aiteamforge/mail, like KB_ORCH_TMUX / KB_ORCH_GH."""
    team, _sep, term = (address or "").partition(":")
    base = environ.get("KB_ORCH_MAIL_DIR") or os.path.join(os.path.expanduser("~"), ".aiteamforge", "mail")
    return os.path.join(base, "%s__%s.jsonl" % (_MAIL_SAFE_RE.sub("_", team), _MAIL_SAFE_RE.sub("_", term)))


def real_inbox(environ=None, warn=None):
    """XACA-1864 -> callable(address) -> list of message records (dicts) in that address's kb-msg inbox. STRICTLY READ-ONLY:
    a plain open() of the JSONL, never `kb-msg inbox` (its sync_broadcasts writes), no lock file, never marks anything read.
    A missing file is an empty inbox. Malformed / non-object lines are skipped with ONE warning (via warn). An unreadable
    file raises OSError; gather() turns that into a warning, never a verdict."""
    env = environ if environ is not None else os.environ

    def fn(address):
        path = inbox_file(address, env)
        if not os.path.exists(path):
            return []
        out, bad = [], 0
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if not line.strip():
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    rec = None
                if isinstance(rec, dict):
                    out.append(rec)
                else:
                    bad += 1
        if bad and warn:
            warn("coordinator inbox %s has malformed line(s); skipped them" % path)
        return out
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
                 tokens_interval=None, projects_dir=None, worktrees_root=None, msg=None, token_cache=None, inbox=None,
                 reviews=None, commit_time=None, tmux_kill=None, tmux_capture=None):
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
        # XACA-1875: callable(pane) -> kill that pane's window / its capture-pane tail. Only write polls call them.
        self.tmux_kill = tmux_kill or real_tmux_kill(self.env)
        self.tmux_capture = tmux_capture or real_tmux_capture(self.env)
        self.gh = gh or real_gh(self.env)
        self.msg = msg or real_msg(self.env)
        # XACA-1880-003: callable(repo, pr) -> review rows / callable(repo, sha) -> committer date (GATE_STALE); tests inject fakes.
        self.reviews = reviews or real_reviews(self.env)
        self.commit_time = commit_time or real_commit_time(self.env)
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
        # XACA-1864: callable(address) -> the coordinator's kb-msg records, read-only (real_inbox); tests inject a fake.
        self.inbox = inbox or real_inbox(self.env, self.warn)

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


def _has_board(kdir):
    import glob
    return bool(kdir) and bool(glob.glob(os.path.join(kdir, "*-board.json")))


def _board_holds(kdir, release_id=None, item_id=None):
    """True when a *-board.json under kdir carries the release (or, with item_id, the backlog item). Never raises."""
    import glob
    want = item_id or release_id
    for path in sorted(glob.glob(os.path.join(kdir, "*-board.json"))):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                board = json.load(fh)
        except (OSError, ValueError):
            continue
        if not isinstance(board, dict):
            continue
        rows = board.get("backlog") if item_id else board.get("releases")
        if any(isinstance(r, dict) and r.get("id") == want for r in rows or []):
            return True
    return False


def _tmux_team(ctx):
    """The team of the tmux session this process runs in (kanban_utils.parse_session_name), else None. Never raises."""
    if not ctx.env.get("TMUX"):
        return None
    base = shlex.split(ctx.env.get("KB_ORCH_TMUX") or "tmux")
    try:
        rc, out, _err = _run(base + ["display-message", "-p", "#S"], timeout=10)
    except RuntimeError:
        return None
    if rc != 0 or not out.strip():
        return None
    try:
        from kanban_utils import parse_session_name
    except Exception:  # noqa: BLE001 -- an unimportable helper only loses this step
        return None
    team, _term = parse_session_name(out.strip().splitlines()[0])
    return team


def _registry_kanban_dirs():
    """-> [(team, kanban_dir)] for every team in the per-machine registry (aiteamforge_registry, the reader LCARS uses).
    Board-less aliases and unreadable entries are skipped; an unreadable registry yields []. Never raises."""
    try:
        import aiteamforge_paths as apaths
        import aiteamforge_registry as reg
        view = apaths.read_config_view()   # ONE read-only peek, passed through (an unhealthy file pays the retry once)
        teams = reg.registered_teams(config=view)
    except Exception:  # noqa: BLE001
        return []
    out = []
    for team in teams:
        try:
            out.append((team, os.path.realpath(str(reg.kanban_dir(team, config=view)))))
        except Exception:  # noqa: BLE001 -- UnknownTeam / BoardLess / malformed: not a candidate
            continue
    return out


def resolve_kanban_dir(ctx, release_id=None, item_id=None):
    """The kanban dir used when no --board / --kanban-dir / KB_KANBAN_DIR is given (XACA-1878).

    1. the checkout default (default_kanban_dir, the XACA-1808 worktree rule) when it holds a *-board.json: on the dev
       checkout nothing changes;
    2. else (a TAP CONSUMER: the monitor runs from ~/aiteamforge/kanban-hooks or libexec/share/kanban-hooks, where no
       board lives) the registry kanban dir of the CURRENT tmux session's team, when its board holds the release/item;
    3. else the ONE registered team kanban dir whose board holds it;
    4. else UsageError (exit 2) naming --kanban-dir and every dir tried. Never silently a dir with no board."""
    own = default_kanban_dir(ctx.repo_root)
    if _has_board(own):
        return own
    tried = [own + " (no board)"]
    want = item_id or release_id
    reg = _registry_kanban_dirs()
    team = _tmux_team(ctx)
    if team:
        tdir = next((d for t, d in reg if t == team), None)
        if tdir and _board_holds(tdir, release_id, item_id):
            return tdir
        tried.append("tmux team %s: %s" % (team, "%s does not hold %s" % (tdir, want) if tdir else "not in the registry"))
    hits = sorted({d for _t, d in reg if _board_holds(d, release_id, item_id)})
    if len(hits) == 1:
        return hits[0]
    if hits:
        raise UsageError("%s is on more than one registered board (%s): pass --kanban-dir <dir>%s" % (
            want, ", ".join(hits), " (tried: %s)" % "; ".join(tried[1:]) if len(tried) > 1 else ""))
    tried.append("%d registered team kanban dir(s), none holding %s" % (len(reg), want))
    raise UsageError("cannot find the kanban dir for %s: pass --kanban-dir <team kanban dir> (tried: %s)" % (
        want, "; ".join(tried)))


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
        kdir = kdir or ctx.env.get("KB_KANBAN_DIR") or resolve_kanban_dir(ctx, ctx.release_id)
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


def is_dispatch_attempt(ev):
    """XACA-1829: a REFUSED dispatch created nothing (no window, no stamp), so it never SUPERSEDES the item's latest real
    attempt (DISPATCHED / DISPATCH_FAILED). Since kb-dispatch ledgers refusals too, a "latest dispatch event" reader that
    did not skip them would let e.g. a DUPLICATE_WINDOW retry clear a live DISPATCH_FAILED. REFUSED is EXCLUDED (rather
    than the attempt outcomes allow-listed) so an older event that carries no outcome still counts."""
    d = ev.get("dispatch") if isinstance(ev, dict) else None
    return not (isinstance(d, dict) and d.get("outcome") == "REFUSED")


def latest_dispatch_attempts(events):
    """-> {item: latest ledger `dispatch` event that is a real attempt (see is_dispatch_attempt)}."""
    return latest_by_item([ev for ev in (events or []) if is_dispatch_attempt(ev)], ro.KIND_DISPATCH)


# ------------------------------------------------------------------ inputs
def parse_panes(text):
    """-> [(session, window, command, pane_id)]. A 3-column row (older format / fixtures) gets pane_id None."""
    rows = []
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3:
            pid = parts[3].strip() if len(parts) >= 4 else ""
            rows.append((parts[0], parts[1], parts[2].strip(), pid if _PANE_ID_RE.match(pid) else None))
    return rows


def pane_ids_for(rows, session, window):
    """XACA-1875: the pane ids of the window named EXACTLY `window` in `session` (rows None = tmux unreadable -> None)."""
    if rows is None:
        return None
    return [r[3] for r in rows if r[0] == session and r[1] == window and r[3]]


def pane_for(rows, session, window):
    """None-safe: rows None = tmux unreadable -> None; no match -> PANE_GONE; else a non-shell command wins."""
    if rows is None:
        return None
    cmds = [r[2] for r in rows if r[0] == session and r[1] == window]
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
    dispatches = latest_dispatch_attempts(events) if events else {}
    try:
        pane_rows = parse_panes(ctx.tmux())
    except Exception:  # noqa: BLE001 -- any tmux failure = unreadable, never "gone"
        pane_rows = None
    items, windows, panes, prs, terminals = {}, {}, {}, {}, {}
    repo, repo_err = ctx.repo, None
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
        if it is None or status in ("completed", "cancelled") or ow0.is_wave0(orch):   # XACA-1873: a plan lane has no PR
            prs[iid] = None
        else:
            if not repo and repo_err is None:
                # XACA-1829 (user decision 1a): no --repo and none derivable (e.g. a checkout with no git remote) DEGRADES
                # instead of aborting: warn once, and every PR lookup becomes an error row, so an item that needs PR evidence
                # derives UNKNOWN (fail closed) while crashes, questions and free slots are still seen.
                try:
                    repo = repo_from_git(ctx.repo_root)
                except UsageError as exc:
                    repo_err = str(exc)
                    ctx.warn("%s; PR evidence is unavailable, so items that need it derive UNKNOWN" % repo_err)
            if not repo:
                prs[iid] = {"error": repo_err or "no --repo"}
                continue
            try:
                prs[iid] = newest_pr(ctx.gh(repo, "feature/%s" % iid.lower()))
            except Exception as exc:  # noqa: BLE001 -- a gh failure is data, not a crash
                prs[iid] = {"error": one_line(exc)}
    # XACA-1864: the coordinator's kb-msg inbox, read-only. A failure is a warning and an empty inbox, never a verdict.
    inbox, coord = [], ro.coordinator_address(orch.get("coordinator"))
    if coord:
        try:
            inbox = list(ctx.inbox(coord) or [])
        except Exception as exc:  # noqa: BLE001 -- an unreadable inbox must never stop the monitor
            ctx.warn("cannot read the coordinator inbox of %s (%s); kb-msg escalations are not visible" % (
                coord, one_line(exc)[:200]))
    return {"now": now, "team": team, "thresholds": th, "sources": sources, "items": items, "windows": windows,
            "panes": panes, "prs": prs, "terminals": terminals, "dispatches": dispatches, "run": run, "inbox": inbox,
            "repo": repo, "pane_rows": pane_rows}


def gate_scan(reviews, head):
    """XACA-1880-003, pure (kb-pr-monitor _kbpm_stale_scan semantics) -> {role: {status, login, sha, state, submitted_at}}.
    status: current (an APPROVED/CHANGES_REQUESTED review on head), stale (none on head, but an earlier one exists: sha /
    state / submitted_at are the LATEST by submitted_at), never (that bot never reviewed: not launched yet, NOT stale).
    Matched by EXACT login only."""
    out = {}
    for role, login, _cmd in GATE_BOTS:
        rv = [r for r in reviews if isinstance(r, dict) and r.get("login") == login and r.get("state") in GATE_REVIEW_STATES]
        if not rv:
            out[role] = {"status": "never", "login": login}
        elif any(r.get("commit_id") == head for r in rv):
            out[role] = {"status": "current", "login": login}
        else:
            last = sorted(rv, key=lambda r: r.get("submitted_at") or "")[-1]
            out[role] = {"status": "stale", "login": login, "sha": last.get("commit_id") or "-", "state": last.get("state"),
                         "submitted_at": last.get("submitted_at")}
    return out


def gather_gates(ctx, g, states):
    """XACA-1880-003 -> g["gates"] = {item: {pr, head, scan, head_time}} for in-flight items with an OPEN PR. Only those
    items cost an API call (reviews); the head commit's date is read only when a bot is stale. A read failure is a warning
    and NO entry (no verdict), never a crash and never a false GATE_STALE. An OPEN PR row without a usable headRefOid
    (a gh that did not return it) is skipped: without the head there is no staleness to judge."""
    gates, repo = {}, g.get("repo")
    for iid, pr in sorted((g.get("prs") or {}).items()):
        if (states.get(iid) or {}).get("state") in NOT_IN_FLIGHT + (None,) or not repo:
            continue
        if not isinstance(pr, dict) or pr.get("error") or str(pr.get("state") or "").upper() != "OPEN":
            continue
        head, num = pr.get("headRefOid"), pr.get("number")
        if not isinstance(head, str) or not _SHA_RE.match(head) or not isinstance(num, int):
            continue
        try:
            scan = gate_scan(list(ctx.reviews(repo, num) or []), head)
        except Exception as exc:  # noqa: BLE001 -- an unreadable reviews list is not evidence anything is stuck
            ctx.warn("%s: cannot read the reviews of PR #%s (%s); GATE_STALE not evaluated" % (iid, num, one_line(exc)[:200]))
            continue
        row = {"pr": num, "head": head, "scan": scan, "head_time": None}
        if any(v["status"] == "stale" for v in scan.values()):
            try:
                row["head_time"] = ctx.commit_time(repo, head)
            except Exception as exc:  # noqa: BLE001
                ctx.warn("%s: cannot read the date of head %s of PR #%s (%s); GATE_STALE not evaluated" % (
                    iid, head[:8], num, one_line(exc)[:200]))
                continue
        gates[iid] = row
    g["gates"] = gates
    return gates


def gate_conditions(g, th, add):
    """XACA-1880-003, pure given g["gates"]: one GATE_STALE per item whose stale bot(s) passed gate_stale_seconds. A bot's
    window starts at max(head commit date, its stale review): the head's committer date approximates the push, and a review
    submitted after it on the old commit only became stale then. An unparseable date never fires."""
    now, limit = g["now"], th["gate_stale_seconds"]
    for iid, row in sorted((g.get("gates") or {}).items()):
        head_t = ostate.parse_ts(row.get("head_time")) if row.get("head_time") else None
        if head_t is None:
            continue
        fired = []
        for role, login, cmd in GATE_BOTS:
            b = row["scan"].get(role) or {}
            if b.get("status") != "stale":
                continue
            sub_t = ostate.parse_ts(b.get("submitted_at")) if b.get("submitted_at") else None
            anchor = max(head_t, sub_t) if sub_t is not None else head_t
            age = int((now - anchor).total_seconds())
            if age >= limit:
                old = b.get("sha") or "-"
                relaunch = "%s %s --yes" % (cmd, iid)
                if b.get("state") == "APPROVED" and _SHA_RE.match(old):
                    relaunch += " --delta %s" % old
                fired.append((login, old, age, relaunch))
        if fired:
            stale = ",".join("%s@%s" % (lg, old) for lg, old, _a, _r in fired)
            add("GATE_STALE", iid, "pr=%s|head=%s|stale=%s" % (row["pr"], row["head"], stale),
                "%s: pr=%s head=%s stale_bots=%s age=%ds; relaunch: %s" % (
                    iid, row["pr"], row["head"][:8], ",".join("%s@%s" % (lg, old[:8]) for lg, old, _a, _r in fired),
                    min(a for _l, _o, a, _r in fired), "; ".join(r for _l, _o, _a, r in fired)))


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


NOT_IN_FLIGHT = ("DONE", "CANCELLED", "QUEUED")


def _mentions(body, iid):
    return re.search(r"(?<![A-Za-z0-9])%s(?![A-Za-z0-9])" % re.escape(iid), body) is not None


KB_ASK_PREFIX = "[kb-ask "     # kanban-helpers.sh kb-ask: its question AND its SUPERSEDED note both start "[kb-ask <ITEM> thread=.."


def _is_kb_ask_traffic(rec, open_threads):
    """XACA-1864 (PR #1395 QA): kb-ask delivers its question as a real kb-msg into the coordinator's inbox, and nothing on
    the kb-ask path (kb-ask list / kb-answer / --clear) marks that row read. It belongs to the kb-ask channel (pendingQuestion
    raises its own QUESTION_PENDING; kb-answer resolves it), so counting it here re-raised the same question as channel=kb-msg
    and told the coordinator to answer it a second time. Excluded: any body starting with KB_ASK_PREFIX (question, SUPERSEDED
    note), and any message on a thread that is an item's OPEN pendingQuestion. Answered (lastQuestion) threads are NOT
    excluded: a worker writing back on a thread after its answer is a new escalation the coordinator has not seen."""
    body = rec.get("body")
    if isinstance(body, str) and body.lstrip().startswith(KB_ASK_PREFIX):
        return True
    return rec.get("thread_id") in open_threads


def worker_messages(states, g, events):
    """XACA-1864 -> [{"item", "msg", "ambiguous"}] for every UNREAD message in the coordinator's inbox (g["inbox"]) that a
    run worker sent. Pure. A message counts only when it is unread (read_at empty), from_team is the run's team, from_terminal
    is the terminal of an in-flight item's latest DISPATCHED ledger event, and created_at is at or after that event's ts (an
    unparseable created_at never counts: it cannot be shown to postdate the dispatch). In flight = derived state not in
    NOT_IN_FLIGHT. Several candidate items on one terminal (S11): the item the body STARTS with (`<ITEM>:`, the milestone-ping
    convention), else the one item the body mentions, else the oldest dispatch, flagged ambiguous."""
    dispatched = {}
    for ev in events or []:
        d = ev.get("dispatch") if ev.get("kind") == ro.KIND_DISPATCH else None
        if isinstance(d, dict) and d.get("outcome") == "DISPATCHED" and isinstance(d.get("terminal"), str):
            t = ostate.parse_ts(ev.get("ts"))
            if t is not None and isinstance(ev.get("item"), str):
                dispatched[ev["item"]] = (d["terminal"], t)          # last one wins = the latest DISPATCHED event
    team = g.get("team")
    open_threads = set()
    for it in (g.get("items") or {}).values():
        pq = it.get("pendingQuestion") if isinstance(it, dict) else None
        if isinstance(pq, dict) and isinstance(pq.get("threadId"), str) and pq["threadId"]:
            open_threads.add(pq["threadId"])
    out = []
    for rec in g.get("inbox") or []:
        if not isinstance(rec, dict) or rec.get("read_at") or not isinstance(rec.get("id"), str) or not rec["id"]:
            continue
        if not team or rec.get("from_team") != team:
            continue
        if _is_kb_ask_traffic(rec, open_threads):
            continue
        created = ostate.parse_ts(rec.get("created_at"))
        if created is None:
            continue
        cands = sorted((t, iid) for iid, (term, t) in dispatched.items()
                       if term == rec.get("from_terminal") and created >= t
                       and (states.get(iid) or {}).get("state") not in NOT_IN_FLIGHT + (None,))
        if not cands:
            continue
        body = rec.get("body")
        body = body if isinstance(body, str) else ""
        ids = [iid for _t, iid in cands]
        ambiguous = False
        if len(ids) == 1:
            item = ids[0]
        else:
            lead = [i for i in ids if body.lstrip().startswith(i + ":")]
            named = [i for i in ids if _mentions(body, i)]
            if len(lead) == 1:
                item = lead[0]
            elif len(named) == 1:
                item = named[0]
            else:
                pool = named or ids                                   # cands are sorted by dispatch ts: [0] is the oldest
                item, ambiguous = next(i for i in ids if i in pool), True
        out.append({"item": item, "msg": rec, "ambiguous": ambiguous})
    return out


def build_conditions(orch, states, g, events, th):
    """-> list of condition dicts {verdict, item, wave, signature, detail}, UNSORTED. Pure given its inputs."""
    now = g["now"]
    waves = wave_of(orch)
    conds = []
    dispatch_latest = latest_dispatch_attempts(events)

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
            # XACA-1547-003: the detail carries the re-dispatch offer; the signature keeps keying on the derived detail only.
            add("ITEM_CRASHED", iid, res["detail"], "%s: %s; %s" % (
                iid, res["detail"], crash_offer(iid, (g.get("terminals") or {}).get(iid), g.get("run"), ow0.is_wave0(orch))))
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
    # XACA-1864: a worker that escalated by `kb-msg send` instead of kb-ask. Same verdict and priority slot as a kb-ask
    # question; keyed on the message id, so each message fires once per repeat window and clears once it is read. The
    # derived item state is untouched (no record_state). Listed AFTER the kb-ask conditions: on a tie pick() keeps the first.
    for wm in worker_messages(states, g, events):
        rec, iid = wm["msg"], wm["item"]
        age = _age(now, rec.get("created_at"))
        add("QUESTION_PENDING", iid, "msg=%s" % rec["id"],
            "%s: channel=kb-msg msg=%s thread=%s age=%s%s; %s" % (
                iid, rec["id"][:8], rec.get("thread_id"), "%ds" % age if age is not None else "unknown",
                " attribution=ambiguous" if wm["ambiguous"] else "", one_line(rec.get("body") or "")[:120]))
    gate_conditions(g, th, add)          # XACA-1880-003: needs g["gates"] (gather_gates); absent = nothing to judge
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
        if m["item"] == otok.COORDINATOR_ITEM:     # XACA-1836-007: the role is the item, so it is in the signature
            detail = ("coordinator: launched with model %s but the coordinator session used %s: the configured coordinator "
                      "model did not take effect (warn-only; nothing was touched)" % (m.get("expected"), obs))
        else:
            detail = ("%s: dispatched with model %s but a worker session used %s: the configured model did "
                      "not take effect (warn-only; no worker was touched)" % (m["item"], m.get("expected"), obs))
        conds.append({"verdict": "MODEL_MISMATCH", "item": m["item"], "wave": waves.get(m["item"], 10 ** 6),
                      "signature": "MODEL_MISMATCH|%s|expected=%s|observed=%s" % (m["item"], m.get("expected"), obs),
                      "detail": one_line(detail),
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
    phase = {"phase": orch["phase"]} if orch.get("phase") else {}     # XACA-1873: a Wave 0 run's summary is tagged
    ro.ledger_append(kdir, run, ro.KIND_TOKEN_SUMMARY, now=ctx.clock(), totals=t["run"], total=otok.total_of(t["run"]),
                     coordinator=t["coordinator"], complete=t["complete"], unattributed=t["unattributed"],
                     modelMismatch=len(t["modelMismatch"]), items=len(t["perItem"]), **phase)
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


def _sync_lanes(ctx, board_file, kdir, run, orch, states, now, lines, wave0=False):
    """LEVEL-TRIGGERED lane sync (PR #1343 review): every in-flight item (state neither QUEUED nor DONE/CANCELLED) that
    holds no lane gets the lowest free one via assign_lane, so lanes[] - which ticket-lamp shows and kb-dispatch's
    LANES_FULL counts - reflects reality even when nothing called assign_lane at dispatch time. Items are taken in plan
    order (wave, then position). No free lane: skipped (capacity is still enforced by compute_slot_free's in-flight
    count). FREES FIRST (XACA-1862): an occupant whose derived state is QUEUED (demoted back to todo, no run stamp, so no
    worker) has its lane nulled via free_lane. record_state frees on the QUEUED edge, but a summary that already says QUEUED
    sees no transition again, and a held lane both fills kb-dispatch's cap and hides the item from SLOT_FREE (rule 3b).
    This sync is the only assigner and assigns only non-QUEUED items, so a QUEUED occupant is always stale.
    wave0 (XACA-1873): a terminal planning lane (orchestrator_wave0.TERMINAL) is freed too, and never assigned.
    Returns True iff a lane was assigned or freed."""
    laned = set()
    changed = False
    for ln in orch.get("lanes") or []:
        cur = ln.get("current") if isinstance(ln, dict) else None
        cid = cur.get("id") if isinstance(cur, dict) else cur
        if not (isinstance(cid, str) and cid):
            continue
        st = (states.get(cid) or {}).get("state")
        free = wave0 and st in ow0.TERMINAL    # a finished planning lane
        if (states.get(cid) or {}).get("state") == "QUEUED":
            free = True
        if free:
            try:
                n = ro.free_lane(board_file, kdir, ctx.release_id, run, cid, now=now, require_unclaimed=st == "QUEUED")
            except ro.LedgerError as exc:
                lines.append("lane sync: cannot free %s (%s)" % (cid, exc))
                laned.add(cid)
                continue
            if n is None:                   # claimed under the lock since the snapshot (XACA-1862-014): keep it
                laned.add(cid)
                continue
            lines.append("lane sync: %s is %s, lane %s freed" % (cid, st, n))
            changed = True
            continue
        laned.add(cid)
    order = [i for w in orch.get("waves") or [] for i in (w if isinstance(w, list) else [])]
    order += sorted(i for i in states if i not in order)
    for iid in order:
        st = (states.get(iid) or {}).get("state")
        if iid in laned or st in ostate.TERMINAL_STATES or st in (None, "QUEUED") or (wave0 and st in ow0.TERMINAL):
            continue
        try:
            n = ro.assign_lane(board_file, kdir, ctx.release_id, run, iid, now=now)
        except ro.LedgerError as exc:
            lines.append("lane sync: %s holds no lane (%s)" % (iid, exc))
            continue
        lines.append("lane sync: %s -> lane %s" % (iid, n))
        changed = True
    return changed


CLOSE_STATES = frozenset(("DONE", "CANCELLED"))
CLOSE_STATUSES = frozenset(("completed", "cancelled"))


def _dispatched_pane(events, iid):
    """The `pane` of the item's LATEST DISPATCHED ledger event, or None (none recorded: a pre-XACA-1875 dispatch)."""
    pane = None
    for ev in events or []:
        d = ev.get("dispatch") if ev.get("kind") == ro.KIND_DISPATCH and ev.get("item") == iid else None
        if isinstance(d, dict) and d.get("outcome") == "DISPATCHED":
            p = d.get("pane")
            pane = p if isinstance(p, str) and _PANE_ID_RE.match(p) else None
    return pane


def _last_lane_event(events, iid, action):
    last = None
    for ev in events or []:
        if ev.get("kind") == ro.KIND_LANE and ev.get("item") == iid and ev.get("action") == action:
            last = ev
    return last


def _close_finished_windows(ctx, kdir, run, orch, states, g, events, board, lines):
    """XACA-1875 (see WINDOW CLOSE in the module docstring). Closes each finished item's own, idle lane window; every
    guard that fails keeps the window. Never raises for a tmux or ledger problem and never touches the verdict."""
    rows = g.get("pane_rows")
    team = g.get("team")
    if rows is None or not team:
        return
    backlog = {i.get("id"): i for i in (board or {}).get("backlog") or [] if isinstance(i, dict)}
    wins = {w.get("id"): w for w in (board or {}).get("activeWindows") or [] if isinstance(w, dict)}
    for iid in sorted(states):
        if (states.get(iid) or {}).get("state") not in CLOSE_STATES:                       # (a)
            continue
        term = (g.get("terminals") or {}).get(iid)
        if not term:
            continue
        session = "%s-%s" % (team, term)
        target = "%s:%s" % (session, iid)
        panes = pane_ids_for(rows, session, iid)                                            # (c) exact name only
        if not panes:
            continue                                   # no such window (already closed, or never opened): nothing to say
        it = backlog.get(iid)
        if not it or ostate.resolve_item_status(it) not in CLOSE_STATUSES:                 # (b)
            lines.append("window close: %s kept (board status is not completed/cancelled)" % target)
            continue
        want = _dispatched_pane(events, iid)
        if want is None:                                                                     # (d) USER DECISION 3
            lines.append("window close: %s kept (no dispatched pane id recorded for this run)" % target)
            continue
        if panes != [want]:
            lines.append("window close: %s kept (panes %s are not this run's dispatched pane %s)" % (
                target, ",".join(panes), want))
            continue
        row = wins.get("%s:%s" % (term, iid))                                               # (f)
        other = row.get("workingOnId") if isinstance(row, dict) else None
        if isinstance(other, str) and other and other != iid:
            o_it = backlog.get(other)
            if o_it is None or ostate.resolve_item_status(o_it) not in CLOSE_STATUSES:
                lines.append("window close: %s kept (its window row is working on %s)" % (target, other))
                continue
        try:                                                                                 # (e) USER DECISION 1
            tail = ctx.tmux_capture(want)
        except Exception as exc:  # noqa: BLE001 -- an unreadable pane is "not idle", never a crash
            ctx.warn("window close: cannot capture %s (%s); kept" % (want, one_line(exc)[:200]))
            tail = None
        prev = _last_lane_event(events, iid, "window_close_deferred")
        prev_hash = prev.get("tailHash") if prev and prev.get("pane") == want else None
        idle, why = ostate.pane_idle(tail, prev_hash)
        lane = (_last_lane_event(events, iid, "assign") or {}).get("lane")
        if not idle:
            h = ostate.tail_hash(tail) if tail is not None else None
            if not (prev and prev.get("pane") == want and prev.get("reason") == why and prev.get("tailHash") == h):
                try:
                    ro.ledger_append(kdir, run, ro.KIND_LANE, now=g.get("now"), item=iid, lane=lane, pane=want,
                                     action="window_close_deferred", reason=why, tailHash=h, window=target)
                except ro.LedgerError as exc:
                    ctx.warn("window close: cannot ledger the deferral of %s (%s)" % (target, exc))
            lines.append("window close: %s deferred (%s)" % (target, why))
            continue
        try:
            ctx.tmux_kill(want)
        except Exception as exc:  # noqa: BLE001 -- a failed kill is a warning, never a verdict
            ctx.warn("window close: kill-window %s (%s) failed: %s" % (target, want, one_line(exc)[:200]))
            continue
        try:
            ro.ledger_append(kdir, run, ro.KIND_LANE, now=g.get("now"), item=iid, lane=lane, pane=want,
                             action="window_closed", window=target)
        except ro.LedgerError as exc:
            ctx.warn("window close: %s closed but the ledger append failed (%s)" % (target, exc))
        lines.append("window close: %s closed (pane %s, item %s)" % (target, want, states[iid]["state"]))


def derive(ctx, orch, run, g, events, board, kdir):
    """Every tracked item's derived state: orchestrator_wave0 lanes for a Wave 0 run, else orchestrator_state."""
    if ow0.is_wave0(orch):
        return ow0.derive_states(orch, run, g, events, lambda iid: ow0.remaining_gaps(
            g["items"].get(iid) or {"id": iid}, board, kdir, ctx.repo_root))
    states = ostate.derive_states(g["items"], g["windows"], g["panes"], g["prs"], g["now"], g["thresholds"])
    for iid in orch["items"]:                 # a tracked item missing from the backlog is UNKNOWN, never silently absent
        if iid not in states:
            states[iid] = ostate.derive_item_state(None, None, None, None, g["now"], g["thresholds"])
    return states


def reconcile(ctx, read_only):
    """The level-triggered half every poll AND `resume` share (XACA-1547-002): read summary + ledger (fail closed), gather
    the live inputs, derive every tracked item's state, record each one that differs from the summary (ledger `state` event +
    summary + lane mirror, via record_state), then the lane sync. read_only computes the same but writes nothing.
    -> dict(board_file, kdir, board, rel, run, orch [re-read after writes], events, g, states, lines, changes)."""
    board_file, kdir, board, rel, run, orch = _summary_after(ctx)
    events = read_ledger(ctx, kdir, run)
    g = gather(ctx, rel, board, board_file, run, orch, events)
    wave0 = ow0.is_wave0(orch)
    states = derive(ctx, orch, run, g, events, board, kdir)
    lines, changes = [], []
    for iid, srow in sorted(orch["items"].items()):
        cur = ow0.summary_state(states[iid]["state"])
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
    if not read_only and _sync_lanes(ctx, board_file, kdir, run, orch, states, g["now"], lines, wave0):
        board_file, kdir, board, rel, run, orch = _summary_after(ctx)
    if not read_only and not wave0:        # XACA-1875: a planning lane never finishes its item, so it is never closed here
        _close_finished_windows(ctx, kdir, run, orch, states, g, events, board, lines)
    return {"board_file": board_file, "kdir": kdir, "board": board, "rel": rel, "run": run, "orch": orch, "events": events,
            "g": g, "states": states, "lines": lines, "changes": changes}


def _poll(ctx, once, read_only):
    r = reconcile(ctx, read_only)
    board_file, kdir, board, run, orch, events = r["board_file"], r["kdir"], r["board"], r["run"], r["orch"], r["events"]
    g, states, lines, changes = r["g"], r["states"], r["lines"], r["changes"]
    lines.extend(lane_lines(orch))
    th = g["thresholds"]
    wave0 = ow0.is_wave0(orch)
    lane_states = states
    if wave0:   # XACA-1873: verdicts and slots see a terminal planning lane as DONE; no PR, so no gate scan
        states = {i: dict(r, state=ow0.base_state(r["state"])) for i, r in lane_states.items()}
    else:
        gather_gates(ctx, g, states)     # XACA-1880-003: watch polls only (status / resume never pay the reviews calls)
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
    if done and wave0:
        conds = [c for c in conds if c["verdict"] not in TELEMETRY_VERDICTS]
        counts = {}
        for r in lane_states.values():
            counts[r["state"]] = counts.get(r["state"], 0) + 1
        conds.append({"verdict": "WAVE0_DONE", "item": "-", "wave": 0, "signature": "WAVE0_DONE|-|-",
                      "detail": "all %d planning lane(s) ended: %s; re-plan the release" % (
                          len(lane_states), " ".join("%s=%d" % kv for kv in sorted(counts.items())))})
    elif done:
        # XACA-1808-008: every item is terminal, so a warn-only telemetry condition has nothing left to pause or re-dispatch. It
        # was already ledgered above (and is counted in the token_summary); it must not outrank ALL_DONE, which `--once` (never
        # suppressed) would otherwise mask forever, so the run would never close and the lead would never get the summary.
        conds = [c for c in conds if c["verdict"] not in TELEMETRY_VERDICTS]
        conds.append({"verdict": "ALL_DONE", "item": "-", "wave": 0, "signature": "ALL_DONE|-|-",
                      "detail": "all %d tracked item(s) are DONE or CANCELLED" % len(states)})
    extra = {"states": lane_states, "slot": slot_res, "changes": changes}
    # XACA-1808-014: --once never suppresses EXCEPT the two warn-only verdicts, which are delivered once per signature per
    # repeat window even under --once (a permanent MODEL_MISMATCH would otherwise outrank SLOT_FREE forever).
    live = [c for c in conds if c["verdict"] in ("ALL_DONE", "WAVE0_DONE")
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
        if top["verdict"] in ("ALL_DONE", "WAVE0_DONE"):
            if ctx.tokens_interval is not None:
                try:
                    final = refresh_tokens(ctx, board, orch, events, run, kdir, g["now"], True, board_file)
                    send_token_summary(ctx, kdir, orch, run, final, lines)
                except (ro.LedgerError, OSError, ValueError, KeyError, TypeError) as exc:
                    ctx.warn("final token summary failed: %s" % one_line(exc))
            outcome = "wave0" if wave0 else "complete"
            ro.close_run(board_file, kdir, ctx.release_id, run, outcome=outcome, detail=top["detail"], now=g["now"])
            lines.append("run %s closed (%s)" % (run, outcome))
    return Result(top["verdict"], run, top["item"], top["detail"], lines, extra)


# ------------------------------------------------------------------ resume (XACA-1547)
def crash_offer(item, terminal, run, plan=False):
    """The ITEM_CRASHED / resume offer: relaunch the worker in place. `kb-dispatch --resume` keeps the item's worktree, branch
    and dispatch stamp (it never re-stamps a todo item), refuses while a live worker still holds the window, and keeps the
    crashed window (renamed) for inspection. The alternative is the lead's call (cancel / re-plan). plan (XACA-1873): a
    Wave 0 lane is re-dispatched with --plan, which refuses a live window and a lane that already reported done."""
    if plan:
        return ("offer: ask the user, then re-dispatch the planning lane with `kb-dispatch %s --plan --terminal %s --run %s`, "
                "or leave it refused" % (item, terminal or "<terminal>", run or "<RUN-ID>"))
    return ("offer: re-dispatch in place with `kb-dispatch %s --terminal %s --run %s --resume` "
            "(keeps worktree + stamp), or ask the lead to cancel/re-plan" % (item, terminal or "<terminal>", run or "<RUN-ID>"))


# What `resume` does with each derived state. Only QUEUED is ever (re)dispatched as new work, and only through SLOT_FREE;
# CRASHED is offered a RESUME of the same worker. Every in-flight state is left alone: the worker is still on it.
RESUME_ACTION = {
    "DONE": "closed", "CANCELLED": "closed", "QUEUED": "queued", "CRASHED": "crashed", "FAILED": "failed",
    "UNKNOWN": "unknown", "DISPATCHING": "live", "RUNNING": "live", "IN_REVIEW": "live", "QUESTION_PENDING": "live",
    "STALLED": "live", "MERGED_PENDING_DONE": "live",     # merged, kb-done still owed: the worker closes it, never re-run
    "INCOMPLETE": "failed",                                # XACA-1873: a Wave 0 lane that ended with gaps open
}
RESUME_REDISPATCH = {"queued": "dispatch", "crashed": "resume"}     # every other action: "never"
# XACA-1873: a Wave 0 (planning) lane is never handed to the execution-worker commands. Both a queued row and a crashed
# lane are re-dispatched with `kb-dispatch <ID> --plan` (which sets a dead window aside the way --resume does).
RESUME_REDISPATCH_WAVE0 = {"queued": "plan", "crashed": "plan"}


def resume(ctx, coordinator=None, dry_run=False):
    """`kb-release-orchestrate resume <REL-ID>` (XACA-1547-001/002). A coordinator that (re)starts calls this FIRST.
    NO_ACTIVE_RUN (exit 4) when the release has no active open run: start a new run instead. Otherwise:
      1 rehydrate: fold the ledger (fail closed: a corrupt ledger is USAGE, never a guess) into per-item history;
      2 reconcile: the SAME derive-and-record step as every watch poll, so anything that changed while no coordinator was
        looking is recorded now (an item merged meanwhile becomes DONE and frees its lane; a dead worker becomes CRASHED);
      3 re-attach: with --coordinator, re-point the run at the new address (summary + every open item's stamp);
      4 report per item: state, action (live / closed / crashed / queued / failed / unknown) and redispatch (dispatch / resume
        / never; a Wave 0 run reports plan / never). An in-flight item is ALWAYS "never": resume never re-dispatches
        running work (plan requirement 9);
      5 append ONE `verdict` event, verdict RESUMED (no new ledger kind: LCARS and ticket-lamp already render verdicts).
    --dry-run computes everything and writes nothing. Returns a Result (RESUMED / NO_ACTIVE_RUN / USAGE)."""
    try:
        if coordinator is not None and not ro.addr_valid(coordinator):
            raise UsageError("--coordinator %r is not a team:terminal address" % (coordinator,))
        _bf, _kd, _board, rel = locate_release(ctx)
        orch0 = rel.get("orchestration")
        if not (isinstance(orch0, dict) and orch0.get("activeRunId") and not orch0.get("closedAt")):
            last = orch0.get("activeRunId") if isinstance(orch0, dict) else None
            return Result("NO_ACTIVE_RUN", last, None, "%s has no active open run%s; start a new run" % (
                ctx.release_id, " (last run %s is closed)" % last if last else ""))
        before = {iid: (row or {}).get("state") for iid, row in (orch0.get("items") or {}).items()}
        r = reconcile(ctx, dry_run)
        run, orch, states, g, lines = r["run"], r["orch"], r["states"], r["g"], r["lines"]
        hist = ro.rehydrate(r["events"])
        prev = ro.coordinator_address(orch.get("coordinator"))
        reattached = None
        if coordinator is not None and not dry_run:
            reattached = ro.reattach_coordinator(r["board_file"], ctx.release_id, run, coordinator, now=g["now"])
            if reattached["previous"] != coordinator or reattached["items"]:
                lines.append("re-attached: coordinator %s -> %s%s" % (
                    reattached["previous"], coordinator,
                    "; item stamps rewritten: %s" % ", ".join(reattached["items"]) if reattached["items"] else ""))
        slot, slot_res = slot_condition(orch, {i: dict(r, state=ow0.base_state(r["state"])) if ow0.is_wave0(orch) else r
                                               for i, r in states.items()}, _max_parallel(orch))
    except UsageError as exc:
        return Result("USAGE", ctx.run, None, str(exc))
    except ValueError as exc:
        return Result("USAGE", ctx.run, None, "bad configuration: %s" % exc)
    except ro.LedgerError as exc:
        return Result("USAGE", ctx.run, None, "ledger/summary write refused: %s" % exc)
    items, counts = {}, {}
    redispatch = RESUME_REDISPATCH_WAVE0 if ow0.is_wave0(orch) else RESUME_REDISPATCH
    for iid in sorted(states):
        st = states[iid]["state"]
        action = RESUME_ACTION.get(st, "unknown")
        h = hist["items"].get(iid) or {}
        pq = (g["items"].get(iid) or {}).get("pendingQuestion")
        row = {"state": st, "before": before.get(iid), "ledgerState": h.get("ledgerState"), "action": action,
               "redispatch": redispatch.get(action, "never"), "terminal": g["terminals"].get(iid),
               "detail": states[iid]["detail"], "dispatches": h.get("dispatches", 0),
               "pendingQuestion": ({"threadId": pq.get("threadId"), "coordinator": pq.get("coordinator")}
                                   if isinstance(pq, dict) and pq else None)}
        if action == "crashed":
            row["offer"] = crash_offer(iid, row["terminal"], run, ow0.is_wave0(orch))
        items[iid] = row
        counts[action] = counts.get(action, 0) + 1
    # Defence in depth for requirement 9: only a QUEUED item may ever be offered as new work.
    eligible = [i for i in (slot_res or {}).get("eligible") or [] if items.get(i, {}).get("action") == "queued"]
    gap = _age(g["now"], hist["run"]["lastVerdictAt"] or hist["run"]["startedAt"])
    report = {"run": run, "release": ctx.release_id, "coordinator": coordinator or prev, "previousCoordinator": prev,
              "reattached": reattached, "dryRun": bool(dry_run), "now": ro._ts(g["now"]),
              "startedAt": hist["run"]["startedAt"], "lastVerdictAt": hist["run"]["lastVerdictAt"],
              "coordinatorGapSeconds": gap, "resumes": hist["run"]["resumes"], "items": items,
              "changes": [{"item": i, "from": a, "to": b} for i, a, b in r["changes"]],
              "slotFree": bool(slot) and bool(eligible), "eligible": eligible}
    detail = "%d item(s): %s; %s recorded while no coordinator watched" % (
        len(items), " ".join("%s=%d" % kv for kv in sorted(counts.items())),
        "%d change(s)" % len(r["changes"]) if r["changes"] else "no changes")
    out = ["Resuming run %s (release %s), started %s; last coordinator verdict %s%s" % (
        run, ctx.release_id, hist["run"]["startedAt"], hist["run"]["lastVerdictAt"] or "never",
        " (%ss ago)" % gap if gap is not None else "")]
    out.extend(lines)
    for iid, row in items.items():
        out.append("  %s  %-16s %-7s redispatch=%-8s terminal=%s  %s%s" % (
            iid, row["state"], row["action"], row["redispatch"], row["terminal"], row["detail"],
            "  [question %s pending]" % row["pendingQuestion"]["threadId"] if row["pendingQuestion"] else ""))
        if row.get("offer"):
            out.append("      %s" % row["offer"])
    out.extend(lane_lines(orch))
    out.append("next: %s; then loop on `kb-release-orchestrate watch %s --run %s`" % (
        "dispatch %s (SLOT_FREE)" % ", ".join(eligible) if eligible else "no new dispatch is due", ctx.release_id, run))
    if not dry_run:
        try:
            ro.ledger_append(r["kdir"], run, ro.KIND_VERDICT, now=g["now"], item="-", verdict=ro.VERDICT_RESUMED,
                             signature="%s|-|%s" % (ro.VERDICT_RESUMED, ro._ts(g["now"])), detail=one_line(detail),
                             coordinator=coordinator or prev, previousCoordinator=prev,
                             actions={i: v["action"] for i, v in items.items()})
        except ro.LedgerError as exc:
            return Result("USAGE", run, None, "ledger/summary write refused: %s" % exc, out)
    return Result("RESUMED", run, "-", detail, out, {"report": report})


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
        states = derive(ctx, orch, run, g, events, board, kdir)
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
    view = {"run": run, "release": ctx.release_id, "phase": orch.get("phase"), "startedAt": orch.get("startedAt"),
            "closedAt": orch.get("closedAt"),
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
    n = sum(1 for v in items.values() if v["summaryState"] != ow0.summary_state(v["derivedState"]))
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
        try:
            kdir = os.path.abspath(args.kanban_dir or (os.path.dirname(os.path.abspath(args.board)) if args.board else None)
                                   or ctx.env.get("KB_KANBAN_DIR") or resolve_kanban_dir(ctx, item_id=args.item))
        except UsageError as exc:
            return fail(str(exc))
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
        p.add_argument("--gate-stale-seconds")
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
    rs = sub.add_parser("resume", add_help=False)
    common(rs)
    rs.add_argument("--coordinator")
    rs.add_argument("--json", action="store_true")
    rs.add_argument("--dry-run", action="store_true")
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
              "[--stall-seconds N] [--dispatch-seconds N] [--gate-stale-seconds N] [--board FILE] [--kanban-dir DIR] [--repo owner/repo]\n"
              "       kb-release-orchestrate status <REL-ID> [--json] [--tokens] [--run RUN] [same input flags]\n"
              "       kb-release-orchestrate resume <REL-ID> [--coordinator team:terminal] [--json] [--dry-run] [same input flags]\n"
              "         (resume exit: 0 RESUMED, 4 NO_ACTIVE_RUN, 2 usage / corrupt ledger)\n"
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
            raise UsageError("a subcommand (watch | status | resume | tokens) is required")
        if args.cmd == "tokens":
            args.release = None
            return tokens_cmd(args, out, overrides)
        cli = {}
        if args.stall_seconds is not None:
            cli["stall_seconds"] = args.stall_seconds
        if args.dispatch_seconds is not None:
            cli["dispatch_seconds"] = args.dispatch_seconds
        if args.gate_stale_seconds is not None:
            cli["gate_stale_seconds"] = args.gate_stale_seconds
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
    if args.cmd == "resume":
        res = resume(ctx, coordinator=args.coordinator, dry_run=args.dry_run)
        if args.json and res.verdict == "RESUMED":
            print(json.dumps(res.extra["report"], sort_keys=True, indent=2), file=out)
            print(verdict_line(res.verdict, res.run, res.item, res.detail), file=out)
        else:
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


if __name__ == "__main__":
    sys.exit(main())
