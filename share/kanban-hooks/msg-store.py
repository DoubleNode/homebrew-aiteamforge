#!/usr/bin/env python3

#
#  msg-store.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Local message store for the kb-msg inter-session / inter-team comms channel
(XACA-0777).

This is the SINGLE local inbox that BOTH transport tiers write to:

  * Tier 1 (same-machine): kb-msg send calls `send` directly.
  * Tier 2 (cross-machine): the recipient machine's reporter pulls a SEALED
    envelope off the relay, `sealOpen`s it, and calls `ingest` with the
    decrypted record. The record lands in the exact same inbox files a Tier-1
    message would — so kb-msg inbox/read/reply and the surfacing hook are
    identical regardless of a message's origin.

Design (see kanban/XACA-0777_intersession_interteam_comms.md):
  * One JSONL file PER RECIPIENT identity under ~/.aiteamforge/mail/, named
    "<team>__<terminal>.jsonl". Per-recipient files mean read-state is trivially
    correct even for broadcasts (each live session gets its own copy/id-row).
  * Atomic writes via the lock-file + temp-file + os.rename pattern lifted from
    subagent-track.py's locked_update(). Two concurrent writers to one inbox can
    never corrupt the JSONL.
  * stdlib only. No third-party imports. tmux is shelled out to for liveness.

Addressing grammar (mirrors _kb_detect_context): "<team>:<terminal>".
  * "academy:chancellor" — one specific session on this machine.
  * "academy" or "academy:*" — team broadcast: fan out to every live session of
    that team on this machine.

Record schema (one JSON object per line):
  {
    "id":            "<uuid>",
    "from_team":     "academy",
    "from_terminal": "chancellor",
    "to_team":       "academy",
    "to_terminal":   "engineering",   # null == broadcast (stored per live session)
    "to":            "academy:engineering",
    "body":          "...",
    "thread_id":     "<uuid>",
    "origin":        "local" | "relay",
    "created_at":    "2026-07-10T12:00:00Z",
    "read_at":       null,
    "acked":         false
  }
"""

import argparse
import datetime
import fcntl
import glob
import json
import os
import re
import stat
import subprocess
import sys
import uuid

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

MAIL_DIR = os.path.join(os.path.expanduser("~"), ".aiteamforge", "mail")

# Terminal/team tokens are used to build filenames; keep them filesystem-safe.
_SAFE_RE = re.compile(r"[^A-Za-z0-9._-]")


def _ensure_mail_dir():
    os.makedirs(MAIL_DIR, mode=0o700, exist_ok=True)


def _safe_token(token):
    """Sanitize a team/terminal token for use in a filename."""
    return _SAFE_RE.sub("_", token or "")


def inbox_path(team, terminal):
    """Absolute path to the JSONL inbox for a given <team>:<terminal>."""
    return os.path.join(MAIL_DIR, f"{_safe_token(team)}__{_safe_token(terminal)}.jsonl")


def _now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# Atomic JSONL read-modify-write (pattern from subagent-track.py::locked_update)
# ---------------------------------------------------------------------------

def locked_update(filepath, update_fn):
    """Atomic read-modify-write of a JSONL file under an exclusive lock.

    Reads the JSONL into a list of records, applies update_fn(list) -> list,
    then writes to a temp file and os.rename()s it into place. The lock file is
    a sibling ".lock" so concurrent writers serialize.
    """
    _ensure_mail_dir()
    lockfile = filepath + ".lock"
    with open(lockfile, "w") as lf:
        fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
        try:
            records = _read_jsonl(filepath)
            records = update_fn(records)
            tmp = filepath + ".tmp"
            with open(tmp, "w") as f:
                for rec in records:
                    f.write(json.dumps(rec) + "\n")
            os.rename(tmp, filepath)
        finally:
            fcntl.flock(lf.fileno(), fcntl.LOCK_UN)


def _read_jsonl(filepath):
    """Read a JSONL file into a list of dicts. Missing file -> []. Skips
    unparseable lines rather than aborting (a torn line never nukes the box)."""
    records = []
    try:
        with open(filepath, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                    if isinstance(obj, dict):
                        records.append(obj)
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        pass
    return records


def _append_record(team, terminal, record):
    """Append a record to a recipient inbox, de-duplicating on id."""
    def updater(records):
        if any(r.get("id") == record.get("id") for r in records):
            return records  # already present (idempotent ingest / re-pull)
        records.append(record)
        return records
    locked_update(inbox_path(team, terminal), updater)


# ---------------------------------------------------------------------------
# tmux liveness — which <team>:<terminal> sessions exist on THIS machine
# ---------------------------------------------------------------------------

def _tmux_sockets():
    """Discover candidate tmux socket paths: the standard per-uid dir plus any
    team-named socket files directly in /tmp (the fleet's per-team sockets)."""
    sockets = set()
    uid = os.getuid()
    std_dir = f"/tmp/tmux-{uid}"
    if os.path.isdir(std_dir):
        for p in glob.glob(os.path.join(std_dir, "*")):
            try:
                if stat.S_ISSOCK(os.stat(p).st_mode):
                    sockets.add(p)
            except OSError:
                continue
    # Team-named sockets live directly under /tmp (e.g. /tmp/academy).
    for p in glob.glob("/tmp/*"):
        try:
            st = os.stat(p)
            if stat.S_ISSOCK(st.st_mode) and st.st_uid == uid:
                sockets.add(p)
        except OSError:
            continue
    return sockets


def live_sessions():
    """Return a set of (team, terminal) tuples for every live tmux session on
    this machine. Session names split on the LAST hyphen exactly like
    _kb_detect_context: 'academy-engineering' -> ('academy', 'engineering'),
    'freelance-doublenode-starwords-command' -> (...'-starwords', 'command')."""
    found = set()
    for sock in _tmux_sockets():
        try:
            out = subprocess.run(
                ["tmux", "-S", sock, "list-sessions", "-F", "#S"],
                capture_output=True, text=True, timeout=3,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        if out.returncode != 0:
            continue
        for name in out.stdout.splitlines():
            name = name.strip()
            if not name or "-" not in name:
                continue
            team, _, terminal = name.rpartition("-")
            if team and terminal:
                found.add((team, terminal))
    return found


def live_terminals_for_team(team):
    """Terminals of a team that currently have a live session on this machine."""
    return sorted(t for (tm, t) in live_sessions() if tm == team)


# ---------------------------------------------------------------------------
# Addressing
# ---------------------------------------------------------------------------

def parse_address(addr):
    """Parse '<team>:<terminal>' | '<team>' | '<team>:*' into (team, terminal).

    terminal is None for a team broadcast."""
    if not addr:
        raise ValueError("empty address")
    if ":" in addr:
        team, terminal = addr.split(":", 1)
        if terminal in ("", "*"):
            terminal = None
    else:
        team, terminal = addr, None
    if not team:
        raise ValueError(f"invalid address: {addr!r}")
    return team, terminal


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

def _build_record(args, to_team, to_terminal):
    return {
        "id": args.id or uuid.uuid4().hex,
        "from_team": args.from_team,
        "from_terminal": args.from_terminal,
        "to_team": to_team,
        "to_terminal": to_terminal,
        "to": f"{to_team}:{to_terminal}" if to_terminal else to_team,
        "body": args.body,
        "thread_id": args.thread or uuid.uuid4().hex,
        "origin": args.origin,
        "created_at": args.created_at or _now_iso(),
        "read_at": None,
        "acked": False,
    }


def cmd_send(args):
    """Deliver a message into local recipient inbox(es).

    Directed (team:terminal): always written (queues even if the target session
    is not live) — graceful, never a crash on a dead session.
    Broadcast (team / team:*): fanned out to every live session of the team on
    this machine; if none are live, delivered is empty (still no crash)."""
    to_team, to_terminal = parse_address(args.to)

    delivered = []
    if to_terminal is not None:
        # Directed to one identity.
        rec = _build_record(args, to_team, to_terminal)
        _append_record(to_team, to_terminal, rec)
        live = (to_team, to_terminal) in live_sessions()
        delivered.append({"to": f"{to_team}:{to_terminal}", "live": live, "id": rec["id"]})
        thread_id = rec["thread_id"]
    else:
        # Broadcast: fan out to live sessions only.
        thread_id = args.thread or uuid.uuid4().hex
        for term in live_terminals_for_team(to_team):
            rec = _build_record(args, to_team, term)
            rec["to_terminal"] = None      # preserve broadcast intent in the record
            rec["to"] = to_team
            rec["thread_id"] = thread_id
            _append_record(to_team, term, rec)
            delivered.append({"to": f"{to_team}:{term}", "live": True, "id": rec["id"]})

    print(json.dumps({
        "ok": True,
        "to": args.to,
        "thread_id": thread_id,
        "delivered": delivered,
        "count": len(delivered),
    }))


def cmd_ingest(args):
    """Ingest a decrypted (Tier-2) message record into the local inbox — the
    same destination a Tier-1 send would reach. Input is a full record JSON on
    stdin or via --file. Broadcast records (to_terminal null) fan out to live
    sessions on THIS machine; directed records land in their one inbox."""
    if args.file:
        with open(args.file, "r") as f:
            raw = f.read()
    else:
        raw = sys.stdin.read()

    delivered = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            print("msg-store: skipping unparseable envelope line", file=sys.stderr)
            continue
        rec.setdefault("id", uuid.uuid4().hex)
        rec["origin"] = "relay"
        rec.setdefault("read_at", None)
        rec.setdefault("acked", False)
        to_team = rec.get("to_team")
        to_terminal = rec.get("to_terminal")
        if not to_team:
            continue
        if to_terminal:
            _append_record(to_team, to_terminal, rec)
            delivered.append(f"{to_team}:{to_terminal}")
        else:
            for term in live_terminals_for_team(to_team):
                copy = dict(rec)
                copy["id"] = rec["id"] + ":" + term  # unique per-recipient id
                _append_record(to_team, term, copy)
                delivered.append(f"{to_team}:{term}")

    print(json.dumps({"ok": True, "delivered": delivered, "count": len(delivered)}))


def cmd_inbox(args):
    """List messages for a recipient. Unread only unless --all."""
    records = _read_jsonl(inbox_path(args.team, args.terminal))
    if not args.all:
        records = [r for r in records if not r.get("read_at")]
    if args.json:
        print(json.dumps(records))
        return
    if not records:
        return  # print nothing on an empty inbox (no noise)
    for r in records:
        flag = " " if r.get("read_at") else "*"
        frm = f"{r.get('from_team','?')}:{r.get('from_terminal','?')}"
        body = (r.get("body") or "").replace("\n", " ")
        if len(body) > 100:
            body = body[:97] + "..."
        print(f"{flag} [{r.get('id','')[:8]}] {r.get('created_at','')}  {frm}\n    {body}")


def cmd_unread_count(args):
    """Print the number of unread messages for a recipient (0 if none)."""
    records = _read_jsonl(inbox_path(args.team, args.terminal))
    print(sum(1 for r in records if not r.get("read_at")))


def cmd_read(args):
    """Mark a message read by id (prefix match ok). Prints the full body."""
    path = inbox_path(args.team, args.terminal)
    matched = {"rec": None}

    def updater(records):
        for r in records:
            rid = r.get("id", "")
            if rid == args.id or rid.startswith(args.id):
                if not r.get("read_at"):
                    r["read_at"] = _now_iso()
                matched["rec"] = dict(r)
                break
        return records

    locked_update(path, updater)
    if matched["rec"] is None:
        print(json.dumps({"ok": False, "error": "not found"}))
        sys.exit(1)
    r = matched["rec"]
    if args.json:
        print(json.dumps(r))
    else:
        frm = f"{r.get('from_team','?')}:{r.get('from_terminal','?')}"
        print(f"From: {frm}")
        print(f"To:   {r.get('to','')}")
        print(f"Date: {r.get('created_at','')}")
        print(f"Thread: {r.get('thread_id','')[:8]}")
        print("")
        print(r.get("body", ""))


def cmd_who(args):
    """List live <team>:<terminal> sessions on this machine."""
    sessions = sorted(live_sessions())
    if args.json:
        print(json.dumps([f"{t}:{term}" for (t, term) in sessions]))
        return
    for (t, term) in sessions:
        print(f"{t}:{term}")


def cmd_is_local(args):
    """Print 'yes' if the target team has at least one live session on THIS
    machine (i.e. a same-machine Tier-1 delivery is possible), else 'no'.
    Used by the shell send path to choose Tier 1 vs Tier 2."""
    team, _ = parse_address(args.to)
    print("yes" if live_terminals_for_team(team) else "no")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(prog="msg-store.py", description="kb-msg local message store")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("send", help="deliver a message into local inbox(es)")
    s.add_argument("--to", required=True, help="<team>:<terminal> | <team> | <team>:*")
    s.add_argument("--from-team", dest="from_team", required=True)
    s.add_argument("--from-terminal", dest="from_terminal", required=True)
    s.add_argument("--body", required=True)
    s.add_argument("--thread", default=None)
    s.add_argument("--origin", default="local", choices=["local", "relay"])
    s.add_argument("--id", default=None)
    s.add_argument("--created-at", dest="created_at", default=None)
    s.set_defaults(func=cmd_send)

    s = sub.add_parser("ingest", help="ingest decrypted Tier-2 record(s) into local inbox")
    s.add_argument("--file", default=None, help="read record JSON from file (default: stdin)")
    s.set_defaults(func=cmd_ingest)

    s = sub.add_parser("inbox", help="list messages for a recipient")
    s.add_argument("--team", required=True)
    s.add_argument("--terminal", required=True)
    s.add_argument("--all", action="store_true", help="include read messages")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_inbox)

    s = sub.add_parser("unread-count", help="print unread count for a recipient")
    s.add_argument("--team", required=True)
    s.add_argument("--terminal", required=True)
    s.set_defaults(func=cmd_unread_count)

    s = sub.add_parser("read", help="mark a message read by id")
    s.add_argument("--team", required=True)
    s.add_argument("--terminal", required=True)
    s.add_argument("--id", required=True)
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_read)

    s = sub.add_parser("who", help="list live team:terminal sessions on this machine")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_who)

    s = sub.add_parser("is-local", help="is the target team live on this machine? yes/no")
    s.add_argument("--to", required=True)
    s.set_defaults(func=cmd_is_local)

    return p


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
