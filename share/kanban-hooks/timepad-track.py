#!/usr/bin/env python3
"""TimePad auto-tracking dispatcher — team-aware, config-driven.

EPIC-0039 Child B (XACA-0620). Relocated from ~/.config/timeapp/timeapp-track.py
and generalized from the hardcoded Bandwear block into a team-aware dispatcher.

Invoked by the SessionStart / SessionEnd hooks via timepad-track.sh. Always exits
0 — time tracking must NEVER block or slow a Claude Code session.

Flow
----
  1. Resolve the session's repo root (passed in TT_REPO_ROOT, or git fallback).
  2. Find the first ENABLED TimePad team whose working_dir contains that root
     (longest-prefix match). No enabled owner -> silent no-op.
  3. Load that team's connection config (XACA-0619: apiBaseUrl, tokenRef,
     clientId, projectId, tagId). Placeholder IDs -> "not configured" no-op.
  4. Resolve the API token via the vault(primary)+env-failover chain (XACA-0279).
  5. Resolve the current kanban item from the git branch -> board title.
  6. Classify a human-readable category label; apply the team's configured tagId.
  7. start: idempotent (won't double-start; caps an >8h orphan). stop: best-effort.

Cutover (XACA-0620)
-------------------
There is NO hardcoded API host constant. The base URL is read from the team's
config ``apiBaseUrl`` (default ``https://timepad.io/api``). Endpoint paths are
relative to that ``/api`` base (``/timer/status`` etc.). No reference to the
retired legacy host survives in this file — verified by the acceptance grep.

Security
--------
The resolved token is used in the request header only. It is never logged,
printed, written to disk, or exported.
"""
import os
import sys
import re
import json
import time
import ssl
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# Local category classifier (names only, no UUIDs).
from timepad_tags import classify_names

# Child A accessor API (XACA-0619).
from aiteamforge_paths import (
    list_teams,
    get_team_working_dir,
    get_team_kanban_dir,
    get_team_code,
    get_timepad_team_config,
    is_timepad_enabled,
    timepad_team_has_placeholders,
)
from timepad_config import resolve_timepad_token, TimePadTokenResolutionError

ACTION = sys.argv[1] if len(sys.argv) > 1 else ""
HDR = "X-API-Key"
TIMEOUT = 8
MAX_STALE_HOURS = 8  # an orphaned (never-stopped) timer older than this is capped
DEFAULT_BASE = "https://timepad.io/api"  # only a fail-soft default; real value comes from config
_CTX = ssl.create_default_context()


def log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {ACTION or '-'}: {msg}", flush=True)


# ---------------------------------------------------------------------------
# Team resolution
# ---------------------------------------------------------------------------

def resolve_repo_root():
    """Return the session's repo root: TT_REPO_ROOT, or a git fallback, or ''."""
    root = os.environ.get("TT_REPO_ROOT", "").strip()
    if root:
        return root
    try:
        import subprocess
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        return out.stdout.strip()
    except Exception:
        return ""


def resolve_team(repo_root):
    """First ENABLED team whose working_dir is a prefix of repo_root.

    Longest-prefix wins so a nested working_dir beats a shorter ancestor.
    Disabled teams are skipped entirely (the enable gate is the master switch).
    Returns the team slug, or None.
    """
    if not repo_root:
        return None
    try:
        rr = os.path.realpath(repo_root)
    except Exception:
        return None
    best = None  # (team_slug, matched_prefix_len)
    for team in list_teams():
        try:
            wd = os.path.realpath(str(get_team_working_dir(team)))
        except Exception:
            continue
        if rr == wd or rr.startswith(wd + os.sep):
            if not is_timepad_enabled(team):
                continue
            if best is None or len(wd) > best[1]:
                best = (team, len(wd))
    return best[0] if best else None


# ---------------------------------------------------------------------------
# Kanban item resolution
# ---------------------------------------------------------------------------

_TICKET_RE = re.compile(r"([A-Za-z]+)-0*(\d+)")


def _parse_ticket(s):
    """Return (PREFIX_UPPER, int_number) from a ticket-shaped string, or None."""
    m = _TICKET_RE.search(s or "")
    if not m:
        return None
    return m.group(1).upper(), int(m.group(2))


def _board_path(team):
    return os.path.join(str(get_team_kanban_dir(team)), f"{team}-board.json")


def item_title(team, prefix, num):
    """Look up a kanban item's title in the team board (read-only).

    Padding-insensitive: matches on (PREFIX, integer) so feature/xaca-620 and
    XACA-0620 resolve to the same item. Returns (title, canonical_id) or
    (None, None).
    """
    path = _board_path(team)
    try:
        with open(path) as f:
            board = json.load(f)
    except Exception as e:
        log(f"{team}: board unreadable ({type(e).__name__}) — using branch label")
        return None, None
    for it in board.get("backlog", []):
        parsed = _parse_ticket(str(it.get("id", "")))
        if parsed and parsed[0] == prefix and parsed[1] == num:
            return it.get("title"), it.get("id")
    return None, None


def describe(team):
    """Build the timer description + whether this is a coordination session.

    Returns (description, is_coordination). A branch carrying a ticket id ->
    "[<ID>] <title>". A bare branch (e.g. develop) -> "<Team> — <branch>" and
    is_coordination=True so the classifier falls back to Admin.
    """
    branch = os.environ.get("TT_BRANCH", "").strip()
    parsed = _parse_ticket(branch)
    if parsed:
        prefix, num = parsed
        title, canon = item_title(team, prefix, num)
        ident = canon or f"{prefix}-{num:04d}"
        return (f"[{ident}] {title}" if title else f"[{ident}] {team}"), False
    return (f"{team} — {branch}" if branch else team), True


# ---------------------------------------------------------------------------
# TimePad API
# ---------------------------------------------------------------------------

def make_caller(base, token):
    base = (base or DEFAULT_BASE).rstrip("/")

    def call(method, path, body=None):
        headers = {HDR: token}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(base + path, data=data, method=method, headers=headers)
        try:
            resp = urllib.request.urlopen(req, timeout=TIMEOUT, context=_CTX)
            return resp.status, json.loads(resp.read().decode())
        except Exception as e:
            return None, f"{type(e).__name__}: {e}"

    return call


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    if ACTION not in ("start", "stop"):
        log(f"unknown action {ACTION!r} (expected start|stop)")
        return

    repo_root = resolve_repo_root()
    team = resolve_team(repo_root)
    if not team:
        # No enabled TimePad team owns this repo — the common case. Silent no-op.
        return

    cfg = get_timepad_team_config(team)
    if not cfg:
        log(f"{team}: no TimePad config block — skipping")
        return
    if timepad_team_has_placeholders(team):
        log(f"{team}: config still has <fetch-from-timepad.io> placeholders — "
            f"not configured; skipping (populate real IDs before enabling)")
        return

    try:
        token = resolve_timepad_token(
            team,
            team_code=get_team_code(team),
            token_ref=cfg.get("tokenRef"),
        )
    except TimePadTokenResolutionError:
        log(f"{team}: API token could not be resolved (vault/env/secrets) — skipping")
        return

    call = make_caller(cfg.get("apiBaseUrl"), token)
    project = cfg.get("projectId")
    tag = cfg.get("tagId")
    tag_ids = [tag] if tag and tag != "<fetch-from-timepad.io>" else []

    _, st = call("GET", "/timer/status")
    running = isinstance(st, dict) and st.get("isRunning")
    elapsed = st.get("elapsed") if isinstance(st, dict) else None

    if ACTION == "start":
        if running:
            if elapsed and elapsed > MAX_STALE_HOURS * 3600:
                log(f"{team}: WARNING stale timer running {elapsed}s (> {MAX_STALE_HOURS}h) — "
                    f"capping it and starting fresh; review that entry in the TimePad UI")
                call("POST", "/timer/stop")
            else:
                log(f"{team}: timer already running (elapsed={elapsed}s) — not starting a second one")
                return
        desc, coordination = describe(team)
        names = classify_names(desc, coordination=coordination)
        body = {"projectId": project, "description": desc, "tagIds": tag_ids}
        code, res = call("POST", "/timer/start", body)
        log(f"{team}: start -> {code} desc={desc!r} categories={names} tags={len(tag_ids)}"
            + ("" if code in (200, 201) else f" :: {res}"))

    elif ACTION == "stop":
        if not running:
            log(f"{team}: no timer running — nothing to stop")
            return
        code, res = call("POST", "/timer/stop")
        earn = res.get("earnings") if isinstance(res, dict) else None
        log(f"{team}: stop -> {code} earnings={earn}" + ("" if code == 200 else f" :: {res}"))


if __name__ == "__main__":
    # Run as a hook (python3 timepad-track.py start|stop). Guarded so the module
    # can be imported for testing without firing main() or exiting the process.
    try:
        main()
    except Exception as e:
        log(f"unexpected error: {type(e).__name__}: {e}")
    sys.exit(0)
