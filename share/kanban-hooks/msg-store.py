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
import math
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
# --after accepts an ISO timestamp (this) or a message-id prefix (anything else).
_ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T")


def _ensure_mail_dir():
    os.makedirs(MAIL_DIR, mode=0o700, exist_ok=True)


def _safe_token(token):
    """Sanitize a team/terminal token for use in a filename."""
    return _SAFE_RE.sub("_", token or "")


def inbox_path(team, terminal):
    """Absolute path to the JSONL inbox for a given <team>:<terminal>."""
    return os.path.join(MAIL_DIR, f"{_safe_token(team)}__{_safe_token(terminal)}.jsonl")


def broadcast_ledger_path(team):
    """Team-wide broadcast ledger (XACA-1833). Deliberately NOT named
    "<team>__<terminal>.jsonl" so no per-recipient inbox can collide with it.
    Each record is a broadcast plus "delivered_to": [terminals]. A terminal
    that had no live session when the broadcast went out picks it up later via
    sync_broadcasts() (fan-out at send time reaches live sessions only)."""
    return os.path.join(MAIL_DIR, f"{_safe_token(team)}.broadcasts.jsonl")


# How long a missed broadcast stays claimable by a terminal that was not live
# when it was sent. Older ledger rows are pruned on the next sync.
BROADCAST_TTL_DAYS_DEFAULT = 7


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


def _broadcast_ttl_seconds():
    raw = os.environ.get("KB_MSG_BROADCAST_TTL_DAYS", "")
    try:
        days = float(raw) if raw else BROADCAST_TTL_DAYS_DEFAULT
    except ValueError:
        days = BROADCAST_TTL_DAYS_DEFAULT
    if not math.isfinite(days) or days <= 0:
        # nan/inf disable pruning; 0/negative wipe the ledger on every check.
        days = BROADCAST_TTL_DAYS_DEFAULT
    return days * 86400


# The comms-triage brief (XACA-1833). The surfacing hook names this command in
# its notice so ANY team's session can hand a generic subagent the brief; the
# Academy `nahla` persona carries the same rules. Single source for non-Academy
# teams: `python3 <msg-store.py> triage-brief`.
TRIAGE_BRIEF = """kb-msg comms triage (XACA-1833, XACA-1941). You share the parent session's terminal identity.
1. source ~/aiteamforge/kanban-helpers.sh && kb-msg inbox, then kb-msg read <id> for each message.
   kb-msg inbox also lists the team's Team Transfer _INBOX (iCloud files the user dropped, XACA-1941).
2. Classify each one: FYI, ACTION (for this terminal), DECISION (for the user) or ALL-CLEAR.
3. FYI and ALL-CLEAR need nothing more. For DECISION, draft a reply but NEVER send it.
   Send nothing without the parent's approval; never answer a cross-team request yourself.
4. NEVER start work on any item. A 'SCOPE (XACA-1296)' banner means outside intake: report it only.
   NEVER open, move or process _INBOX files: list them only. Never read iCloud paths with file
   tools (they hang); never run kb-msg transfer done (it needs the user's approval).
5. Return a digest of 5 lines or fewer: one line per ACTION/DECISION
   ('<id8> <from> <class>: <gist>'), one 'TRANSFER: N pending: <names>' line if _INBOX has files,
   then one line totalling FYI/ALL-CLEAR.
6. Last step: run the LCARS avatar cleanup command from your prompt, if it gave one."""


def cmd_triage_brief(args):
    print(TRIAGE_BRIEF)


# ---------------------------------------------------------------------------
# Team Transfer _INBOX (XACA-1941)
# ---------------------------------------------------------------------------
#
# The second inbound channel: files the user drops into the team's iCloud
# Team Transfer folder, AITeamForge/team-transfers/<folder>/_INBOX. Nothing
# read it before XACA-1941, so it was missed while kb-msg mail was surfaced
# (or the reverse). Every inbox check now reports both.
#
# iCloud File Provider can hang ANY process that touches a dataless or
# still-syncing tree (XACA-0772/0773 hung Claude's native file tools). So this
# process never touches the tree itself: every stat/list/copy/move runs in a
# child process in its own session, and on timeout the whole group is killed
# and NOT waited for (a child stuck in an uninterruptible wait cannot be
# reaped, and waiting for it would hang the hook that called us).

TRANSFER_TIMEOUT_DEFAULT = 3.0        # listing, on every hook check
TRANSFER_COPY_TIMEOUT_DEFAULT = 60.0  # stage/done may pull a file down first

# Kanban team id -> Team Transfer folder name, where they differ. The same
# instance-id aliases .githooks/prepare-commit-msg uses. Anything else uses the
# team id itself (tmux-derived ids like "finance-personal" already match).
_TRANSFER_FOLDER_ALIASES = {
    "finance": "finance-personal",
    "legal": "legal-coparenting",
    "medical": "medical-general",
}

# Shell body for the listing child. $1 = root, $2 = folder. Prints one status
# word on the first line, then (for OK) NUL-separated paths relative to
# _INBOX. _processed/ is where handled files go, and dotfiles are Finder/sync
# noise, so both are pruned; ".<name>.icloud" placeholders (in iCloud, not
# downloaded here) are kept, because they are still pending files.
_TRANSFER_LIST_SH = r'''
r=$1; t=$2
[ -d "$r" ] || { echo NO_ROOT; exit 0; }
[ -d "$r/$t" ] || { echo NO_TEAM_FOLDER; exit 0; }
[ -d "$r/$t/_INBOX" ] || { echo NO_INBOX; exit 0; }
cd "$r/$t/_INBOX" || { echo ERROR; exit 0; }
echo OK
find . -mindepth 1 \( -name _processed -o \( -name '.*' ! -name '.*.icloud' \) \) -prune \
    -o -type f -print0
'''

_TRANSFER_STATE_TEXT = {
    "ok": "reachable",
    "no_root": "iCloud Team Transfer root not found (iCloud Drive off or not synced here)",
    "no_team_folder": "no Team Transfer folder for this team (channel not in use)",
    "no_inbox": "team folder exists but has no _INBOX",
    "timeout": "listing timed out (iCloud File Provider busy or hung)",
    "error": "listing failed",
}


def _env_seconds(name, default, cap):
    raw = os.environ.get(name, "")
    try:
        val = float(raw) if raw else default
    except ValueError:
        val = default
    if not math.isfinite(val) or val <= 0:
        val = default
    return min(val, cap)


def transfer_root():
    """AITeamForge/team-transfers in iCloud Drive (KB_TRANSFER_ROOT overrides,
    for tests and non-default layouts)."""
    env = os.environ.get("KB_TRANSFER_ROOT", "")
    if env:
        return env
    return os.path.join(os.path.expanduser("~"), "Library", "Mobile Documents",
                        "com~apple~CloudDocs", "AITeamForge", "team-transfers")


def transfer_folder(team):
    team = (team or "").strip().lower()
    return _safe_token(_TRANSFER_FOLDER_ALIASES.get(team, team))


def transfer_inbox_path(team):
    return os.path.join(transfer_root(), transfer_folder(team), "_INBOX")


def _run_bounded(argv, timeout):
    """Run argv in its own session. Returns (rc, stdout_bytes), or (None, b"")
    on timeout. On timeout the process group is SIGKILLed and NOT reaped."""
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return (-1, b"")
    try:
        out, _ = proc.communicate(timeout=timeout)
        return (proc.returncode, out)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, 9)
        except OSError:
            pass
        if proc.stdout is not None:
            try:
                proc.stdout.close()
            except OSError:
                pass
        return (None, b"")


def _placeholder_name(rel):
    """'.x.pdf.icloud' -> 'x.pdf' (keeps the directory part), else None."""
    d, b = os.path.split(rel)
    if b.startswith(".") and b.endswith(".icloud") and len(b) > len(".icloud") + 1:
        return os.path.join(d, b[1:-len(".icloud")])
    return None


def transfer_scan(team):
    """State + pending files of the team's Team Transfer _INBOX. Never raises,
    never blocks longer than KB_TRANSFER_TIMEOUT (default 3s, cap 30s)."""
    folder = transfer_folder(team)
    res = {"team": team, "folder": folder, "path": transfer_inbox_path(team),
           "state": "error", "pending": 0, "placeholders": 0, "files": []}
    if not folder:
        return res
    rc, out = _run_bounded(["/bin/sh", "-c", _TRANSFER_LIST_SH, "sh", transfer_root(), folder],
                           _env_seconds("KB_TRANSFER_TIMEOUT", TRANSFER_TIMEOUT_DEFAULT, 30.0))
    if rc is None:
        res["state"] = "timeout"
        return res
    head, _, body = out.partition(b"\n")
    word = head.decode("utf-8", "replace").strip()
    if word != "OK":
        res["state"] = word.lower() if word.lower() in _TRANSFER_STATE_TEXT else "error"
        return res
    # find's own exit status is ignored on purpose: a single unreadable entry
    # must not hide the rest; whatever it printed is still pending.
    files = []
    for raw in body.split(b"\0"):
        if not raw:
            continue
        rel = raw.decode("utf-8", "replace")
        if rel.startswith("./"):
            rel = rel[2:]
        ph = _placeholder_name(rel)
        files.append({"name": ph or rel, "placeholder": bool(ph)})
    files.sort(key=lambda f: f["name"].lower())
    res.update(state="ok", files=files, pending=len(files),
               placeholders=sum(1 for f in files if f["placeholder"]))
    return res


def transfer_summary_lines(scan, explain=False):
    """Human lines for kb-msg inbox / kb-msg transfer list. Empty and
    unreachable inboxes print nothing unless explain (EMPTY PRINTS NOTHING)."""
    if scan["state"] != "ok":
        if not explain:
            return []
        return [f"Team Transfer _INBOX ({scan['folder']}): {_TRANSFER_STATE_TEXT[scan['state']]}",
                f"  path: {scan['path']}"]
    if not scan["pending"]:
        return [f"Team Transfer _INBOX ({scan['folder']}): empty"] if explain else []
    lines = [f"\U0001F4E5 Team Transfer _INBOX ({scan['folder']}): {scan['pending']} pending"
             f" — {scan['path']}"]
    for f in scan["files"]:
        lines.append(f"    {f['name']}" + ("  (in iCloud, not downloaded)" if f["placeholder"] else ""))
    lines.append("    (kb-msg transfer stage <name> copies one out; never open it in place)")
    return lines


def cmd_transfer_count(args):
    scan = transfer_scan(args.team)
    scan.pop("files")
    print(json.dumps(scan))


def cmd_transfer_list(args):
    scan = transfer_scan(args.team)
    if args.json:
        print(json.dumps(scan))
        return
    for line in transfer_summary_lines(scan, explain=args.explain):
        print(line)


def _transfer_rel_ok(rel):
    """A name from transfer-list: relative, normalized, no '..', not under
    _processed. Anything else is refused before a child process sees it."""
    if not rel or "\0" in rel or rel.startswith("/"):
        return False
    parts = rel.split("/")
    if any(p in ("", ".", "..") for p in parts):
        return False
    return parts[0] != "_processed"


def _transfer_fail(msg, code=1):
    print(f"kb-msg transfer: {msg}", file=sys.stderr)
    sys.exit(code)


# _has_link BASE REL: true if any component of BASE/REL is a symlink. A link at
# ANY component (a linked folder inside _INBOX, not only the leaf) would lead
# outside _INBOX, so every prefix is checked (PR #1393).
_HAS_LINK_SH = r'''
_has_link() {
    cur=$1; old=$IFS; IFS=/; set -f
    for c in $2; do
        cur="$cur/$c"
        if [ -L "$cur" ]; then IFS=$old; set +f; return 0; fi
    done
    IFS=$old; set +f; return 1
}
'''

# $1 = inbox, $2 = rel, $3 = placeholder rel. Prints the real rel name used.
_TRANSFER_PICK_SH = _HAS_LINK_SH + r'''
for _p in "$2" "$3"; do _has_link "$1" "$_p" && { echo SYMLINK; exit 0; }; done
if [ -f "$1/$2" ]; then echo "F $2"; elif [ -f "$1/$3" ]; then echo "P $3"; else echo "MISSING"; fi
'''


def _transfer_pick(inbox, rel, timeout):
    d, b = os.path.split(rel)
    ph = os.path.join(d, "." + b + ".icloud")
    rc, out = _run_bounded(["/bin/sh", "-c", _TRANSFER_PICK_SH, "sh", inbox, rel, ph], timeout)
    if rc is None:
        _transfer_fail("timed out reaching the Team Transfer _INBOX (iCloud busy); try again")
    word = out.decode("utf-8", "replace").rstrip("\n")
    if word == "SYMLINK":
        # transfer-list never shows symlinks (find -type f), so a symlink name
        # cannot be a pending drop; following it could copy/move anything.
        _transfer_fail(f"'{rel}' is a symlink; refusing to follow it")
    if word == "MISSING" or word[:2] not in ("F ", "P "):
        _transfer_fail(f"'{rel}' is not in {inbox} (see: kb-msg transfer list)")
    return word[0], word[2:]


def cmd_transfer_stage(args):
    """Copy one pending file to a LOCAL staging dir so tools can open it
    without touching iCloud. The _INBOX copy is left exactly where it was."""
    if not _transfer_rel_ok(args.name):
        _transfer_fail(f"refusing name '{args.name}' (use a name from kb-msg transfer list)", 2)
    inbox = transfer_inbox_path(args.team)
    timeout = _env_seconds("KB_TRANSFER_COPY_TIMEOUT", TRANSFER_COPY_TIMEOUT_DEFAULT, 600.0)
    kind, real = _transfer_pick(inbox, args.name, timeout)
    if kind == "P":
        _transfer_fail(f"'{args.name}' is still in iCloud, not downloaded to this Mac. "
                       f"Download it first: brctl download \"{os.path.join(inbox, args.name)}\"")
    dest_dir = args.dest or os.path.join(os.path.expanduser("~"), ".aiteamforge",
                                         "transfer-staging", transfer_folder(args.team))
    dest = os.path.join(dest_dir, args.name)
    os.makedirs(os.path.dirname(dest), mode=0o700, exist_ok=True)
    rc, _ = _run_bounded(["/bin/cp", "-p", os.path.join(inbox, real), dest], timeout)
    if rc is None:
        _transfer_fail("copy timed out (iCloud busy); the staged copy may be partial")
    if rc != 0:
        _transfer_fail(f"copy failed (cp exit {rc})")
    print(dest)


# $1 = inbox, $2 = real rel. Never overwrites anything in _processed/: the
# pre-check gives a clear message, and mv -n closes the check-then-move race
# mv -n's exit status differs (BSD: 0 when it skips; GNU coreutils 9.x: 1),
# so it is ignored and the outcome is read from the files themselves.
_TRANSFER_DONE_SH = _HAS_LINK_SH + r'''
# The DESTINATION is checked too (XACA-1941-022/023): a symlinked _processed
# or subfolder under it would move the file outside _INBOX. Checked before
# mkdir -p, which would otherwise create folders through the link.
_has_link "$1" "_processed/$2" && { echo SYMLINK; exit 0; }
dst="$1/_processed/$2"
[ -e "$dst" ] && { echo EXISTS; exit 0; }
mkdir -p "$(dirname "$dst")" || { echo FAILED; exit 0; }
mv -n "$1/$2" "$dst" 2>/dev/null
if [ ! -e "$1/$2" ] && [ ! -L "$1/$2" ]; then echo MOVED
elif [ -e "$dst" ]; then echo EXISTS
else echo FAILED; fi
'''


def cmd_transfer_done(args):
    """Move a handled file into _INBOX/_processed/. Only on the user's
    explicit approval: a file the user dropped is theirs to declare handled."""
    if not args.approved:
        _transfer_fail("moving a file to _processed needs the USER's explicit approval. "
                       "Ask first, then re-run with --approved.", 2)
    if not _transfer_rel_ok(args.name):
        _transfer_fail(f"refusing name '{args.name}' (use a name from kb-msg transfer list)", 2)
    inbox = transfer_inbox_path(args.team)
    timeout = _env_seconds("KB_TRANSFER_COPY_TIMEOUT", TRANSFER_COPY_TIMEOUT_DEFAULT, 600.0)
    _kind, real = _transfer_pick(inbox, args.name, timeout)
    rc, out = _run_bounded(["/bin/sh", "-c", _TRANSFER_DONE_SH, "sh", inbox, real], timeout)
    word = out.decode("utf-8", "replace").strip()
    if rc is None:
        _transfer_fail("move timed out (iCloud busy); check kb-msg transfer list before retrying")
    if word == "SYMLINK":
        _transfer_fail(f"_processed/{real} passes through a symlink; refusing to move outside _INBOX")
    if word == "EXISTS":
        _transfer_fail(f"_processed/{real} already exists; not overwriting it")
    if word != "MOVED":
        _transfer_fail("move failed")
    print(os.path.join(inbox, "_processed", real))


_ISO_FULL_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$")


def _iso_age_seconds(iso):
    """Seconds since an ISO-8601 timestamp; None if unparseable.

    Accepts the strict "...SSZ" form every writer here emits, plus fractional
    seconds (the relay's JS toISOString fallback) and +HH:MM offsets
    (`send --created-at`). A missing zone means UTC."""
    if not isinstance(iso, str):
        return None
    m = _ISO_FULL_RE.match(iso.strip())
    if not m:
        return None
    zone = m.group(2)
    offset = datetime.timedelta(0)
    if zone and zone != "Z":
        digits = zone[1:].replace(":", "")
        hours, minutes = int(digits[:2]), int(digits[2:])
        if hours > 23 or minutes > 59:
            return None  # e.g. +99:99 is not an offset
        offset = datetime.timedelta(hours=hours, minutes=minutes)
        if zone[0] == "-":
            offset = -offset
    # Never raise: callers include send/ingest (a raise there drops the rest
    # of a relay batch) and every inbox check. Boundary years overflow when
    # the offset is applied, so OverflowError is caught alongside ValueError.
    try:
        then = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")
        then = (then - offset).replace(tzinfo=datetime.timezone.utc)
        return (datetime.datetime.now(datetime.timezone.utc) - then).total_seconds()
    except (ValueError, OverflowError):
        return None


def _record_broadcast(team, base_record, delivered_terminals):
    """Append one broadcast to the team ledger (XACA-1833), noting which
    terminals already received a fan-out copy at send time."""
    row = dict(base_record)
    row["to_terminal"] = None
    row["to"] = team
    row["read_at"] = None
    row["delivered_to"] = sorted(set(delivered_terminals))
    if _iso_age_seconds(row.get("created_at")) is None:
        # An unreadable timestamp would get the row pruned on its first sync,
        # so offline terminals would never see it: stamp it with "now".
        row["created_at"] = _now_iso()

    def updater(records):
        if any(r.get("id") == row["id"] for r in records):
            return records
        records.append(row)
        return records
    locked_update(broadcast_ledger_path(team), updater)


def sync_broadcasts(team, terminal):
    """Copy team broadcasts this terminal never received into its inbox.

    Fan-out at send/ingest time only reaches LIVE sessions, so a terminal that
    was closed missed them. Under the ledger lock: every row younger than the
    TTL whose delivered_to lacks this terminal is copied into the terminal's
    inbox (id "<ledger-id>:<terminal>", the shape ingest uses), and the
    terminal is recorded ONLY after that copy landed: a failed copy leaves the
    row unclaimed so the next check retries it, instead of marking a message
    delivered that never arrived. Rows older than the TTL are pruned. Returns
    the number of copies made.

    Lock order: ledger lock, then the inbox lock inside it. Nothing takes them
    in the opposite order (send/ingest release each inbox lock before taking
    the ledger lock), so this cannot deadlock."""
    path = broadcast_ledger_path(team)
    if not os.path.exists(path):
        return 0
    ttl = _broadcast_ttl_seconds()
    copied = [0]

    def updater(records):
        kept = []
        for r in records:
            age = _iso_age_seconds(r.get("created_at"))
            if age is None or age > ttl:
                continue  # expired, or no readable created_at (unbounded otherwise): prune
            delivered = r.get("delivered_to")
            if not isinstance(delivered, list):
                delivered = []
            if terminal not in delivered:
                copy = {k: v for k, v in r.items() if k != "delivered_to"}
                copy["id"] = f"{r.get('id') or uuid.uuid4().hex}:{terminal}"
                copy["read_at"] = None
                try:
                    _append_record(team, terminal, copy)
                except OSError as exc:
                    print(f"msg-store: broadcast {copy['id']} not copied, will retry: {exc}",
                          file=sys.stderr)
                else:
                    delivered = delivered + [terminal]
                    copied[0] += 1
            r["delivered_to"] = delivered
            kept.append(r)
        return kept
    locked_update(path, updater)
    return copied[0]


# ---------------------------------------------------------------------------
# tmux liveness — which <team>:<terminal> sessions exist on THIS machine
# ---------------------------------------------------------------------------

def _tmux_sockets():
    """Discover candidate tmux socket paths: the standard per-uid dir plus any
    team-named socket files directly in /tmp (the fleet's per-team sockets)."""
    sockets = set()
    uid = os.getuid()
    # Honour TMUX_TMPDIR exactly as tmux itself does (and as kanban-helpers.sh does
    # for its own socket dir). Unset in production, so the scan base stays /tmp. A
    # sandboxed caller (tests) then never probes the host's real sockets: every
    # unresponsive one costs `tmux list-sessions` its full 3 s timeout, per send
    # (XACA-1545: send-heavy suites blew the 120 s CI budget on shared runners).
    base = os.environ.get("TMUX_TMPDIR") or "/tmp"
    std_dir = os.path.join(base, f"tmux-{uid}")
    # Team-named sockets are opened with an explicit `tmux -S /tmp/<team>` (e.g.
    # fleet-reporter.sh), which tmux does NOT relocate under TMUX_TMPDIR, so their
    # base stays /tmp. A sandbox overrides it separately (XACA-1545-015).
    team_dir = os.environ.get("KB_MSG_TEAM_SOCKET_DIR") or "/tmp"
    if os.path.isdir(std_dir):
        for p in glob.glob(os.path.join(std_dir, "*")):
            try:
                if stat.S_ISSOCK(os.stat(p).st_mode):
                    sockets.add(p)
            except OSError:
                continue
    # Team-named sockets live directly under team_dir (e.g. /tmp/academy).
    for p in glob.glob(os.path.join(team_dir, "*")):
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
    'freelance-acme-starwords-command' -> (...'-starwords', 'command')."""
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
# XACA-1296-017: Space Dock scope banner
# ---------------------------------------------------------------------------
#
# docs/spacedock-board-hygiene.md "Intake from outside this machine" (decided
# for XACA-1296-017, option A): work arriving at Space Dock from outside this
# machine is DELIVERED, never refused, but carries a scope banner reminding
# the crew that Space Dock handles only this machine's local state and
# anything wider escalates to Academy. Delivery itself is never touched by
# this — the banner is display-only, computed fresh at read time from the
# stored record; _append_record/ingest/_build_record above are untouched.

_SPACEDOCK_TEAM = "spacedock"

_SCOPE_BANNER_TEMPLATE = (
    "⚠ SCOPE (XACA-1296): this request came from {source}. Space Dock "
    "handles only THIS machine's local state — if it needs a code "
    "change, involves another team, or applies to more than one machine, "
    "sisko-sd escalates it to Academy (docs/spacedock-board-hygiene.md rule 4)."
)


def _spacedock_scope_banner(rec, recipient_team):
    """Return the scope-banner text for this record, or None if none applies.

    Applies only when the RECIPIENT is spacedock. Within that, a banner is
    shown when the message provably came from outside this machine's
    spacedock team (origin == "relay", i.e. another machine, OR from_team !=
    "spacedock", i.e. another team on this same machine) -- and ALSO when the
    provenance fields are missing or not a recognized shape. Failing toward
    the banner on unparseable provenance is deliberate: an unparseable
    origin/sender is exactly the case where the crew most needs the caution,
    not a case to silently wave through as if it were confirmed local.

    Never raises: this is called from display paths (inbox/read) and must
    never turn a corrupt or partial record into a crashed inbox listing.
    """
    # Case-insensitive: team ids are lowercase by convention, but a mixed-case
    # KB_TEAM still resolves the same inbox on a case-insensitive filesystem,
    # and must not silently hide every banner (XACA-1296 [Test] finding).
    if not isinstance(recipient_team, str) or recipient_team.lower() != _SPACEDOCK_TEAM:
        return None
    if not isinstance(rec, dict):
        return _SCOPE_BANNER_TEMPLATE.format(source="an unverified origin")

    origin = rec.get("origin")
    from_team = rec.get("from_team")

    if origin == "relay":
        return _SCOPE_BANNER_TEMPLATE.format(source="another machine")

    if origin == "local":
        if isinstance(from_team, str) and from_team.lower() == _SPACEDOCK_TEAM:
            return None  # same-machine spacedock -> spacedock: no banner
        if isinstance(from_team, str) and from_team:
            return _SCOPE_BANNER_TEMPLATE.format(source=f"team {from_team}")
        # local origin but sender team missing/malformed -- fail toward caution
        return _SCOPE_BANNER_TEMPLATE.format(source="an unverified sender")

    # origin missing, None, or any value other than "local"/"relay" -- fail
    # toward caution rather than assuming it is safely local.
    return _SCOPE_BANNER_TEMPLATE.format(source="an unverified origin")


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
        live_terms = live_terminals_for_team(to_team)
        for term in live_terms:
            rec = _build_record(args, to_team, term)
            rec["to_terminal"] = None      # preserve broadcast intent in the record
            rec["to"] = to_team
            rec["thread_id"] = thread_id
            _append_record(to_team, term, rec)
            delivered.append({"to": f"{to_team}:{term}", "live": True, "id": rec["id"]})
        # XACA-1833: also keep it in the team ledger so terminals that were
        # not live pick it up on their next inbox check (sync_broadcasts).
        ledger = _build_record(args, to_team, None)
        ledger["thread_id"] = thread_id
        _record_broadcast(to_team, ledger, live_terms)

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
            live_terms = live_terminals_for_team(to_team)
            for term in live_terms:
                copy = dict(rec)
                copy["id"] = rec["id"] + ":" + term  # unique per-recipient id
                _append_record(to_team, term, copy)
                delivered.append(f"{to_team}:{term}")
            _record_broadcast(to_team, rec, live_terms)  # XACA-1833

    print(json.dumps({"ok": True, "delivered": delivered, "count": len(delivered)}))


def cmd_inbox(args):
    """List messages for a recipient. Unread only unless --all. Claims any
    team broadcasts this terminal missed first (XACA-1833)."""
    try:
        sync_broadcasts(args.team, args.terminal)
    except OSError:
        pass
    records = _read_jsonl(inbox_path(args.team, args.terminal))
    if not args.all:
        records = [r for r in records if not r.get("read_at")]
    if args.json:
        # scope_banner is computed fresh for display only -- it is never
        # written back to the stored JSONL (this list came from _read_jsonl
        # above and locked_update/_append_record are not invoked here).
        out = []
        for r in records:
            copy = dict(r)
            copy["scope_banner"] = _spacedock_scope_banner(r, args.team)
            out.append(copy)
        print(json.dumps(out))
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
        banner = _spacedock_scope_banner(r, args.team)
        if banner:
            print(f"    {banner}")


def cmd_unread_count(args):
    """Print the number of unread messages for a recipient (0 if none).

    --sync-broadcasts first claims team broadcasts this terminal missed
    (XACA-1833). --breakdown prints JSON instead of a bare number, for the
    one-line surfacing hook: {"total", "team" (broadcasts), "terminal"
    (directed), "scope" (unread carrying a XACA-1296 scope banner),
    "scope_sources"}."""
    if args.sync_broadcasts:
        try:
            sync_broadcasts(args.team, args.terminal)
        except OSError:
            pass  # a ledger problem must never hide the directed count
    records = [r for r in _read_jsonl(inbox_path(args.team, args.terminal))
               if not r.get("read_at")]
    if not args.breakdown:
        print(len(records))
        return
    team_wide = sum(1 for r in records if r.get("to_terminal") is None)
    sources = []
    scope = 0
    for r in records:
        banner = _spacedock_scope_banner(r, args.team)
        if banner:
            scope += 1
            m = re.search(r"came from (.+?)\. Space Dock", banner)
            src = m.group(1) if m else "outside"
            if src not in sources:
                sources.append(src)
    out = {
        "total": len(records),
        "team": team_wide,
        "terminal": len(records) - team_wide,
        "scope": scope,
        "scope_sources": sources,
    }
    if args.transfer:
        # XACA-1941: the Team Transfer _INBOX rides in the same JSON so the
        # hook makes ONE call and prints ONE notice for both channels.
        scan = transfer_scan(args.team)
        out["transfer_state"] = scan["state"]
        out["transfer_pending"] = scan["pending"]
        out["transfer_folder"] = scan["folder"]
    print(json.dumps(out))


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
    # Computed fresh for display only, same as cmd_inbox -- never written
    # back into the stored record (r is the dict handed back from the
    # locked_update closure above, already persisted before this point).
    banner = _spacedock_scope_banner(r, args.team)
    if args.json:
        out = dict(r)
        out["scope_banner"] = banner
        print(json.dumps(out))
    else:
        frm = f"{r.get('from_team','?')}:{r.get('from_terminal','?')}"
        print(f"From: {frm}")
        print(f"To:   {r.get('to','')}")
        print(f"Date: {r.get('created_at','')}")
        print(f"Thread: {r.get('thread_id','')[:8]}")
        print("")
        print(r.get("body", ""))
        if banner:
            print("")
            print(banner)


def cmd_thread_reply(args):
    """Return the first reply on a thread addressed to the caller (XACA-1545).

    The synchronous half of kb-ask: the worker polls this with the thread id it
    generated. Only records whose thread_id matches are candidates, so unrelated
    mail is never matched, never returned and never marked read. The match is
    marked read under the same lock that finds it (atomic find+mark), and nothing
    else in the inbox is touched.

    Filters (all optional):
      --exclude-from <team:terminal>  skip records sent by that identity, so the
                                      asker never "answers" its own question.
      --after <ISO|msg-id>            only records strictly newer than an ISO
                                      timestamp, or positioned after the record
                                      whose id starts with the given prefix.

    --consume                       exactly-once: skip replies already consumed and
                                      mark the match consumed_at in the same locked
                                      write (kb-ask always passes it).

    Read records are still candidates: the Stop-hook inbox surfacing may have
    marked the reply read before the poll saw it, and a read reply is still THE
    reply. Thread ids are unique per ask, so re-matching is harmless.

    Exit 0 + reply printed (body, or the full record with --json) on a match.
    Exit 1 + {"ok": false, "error": "no reply"} when there is none yet.
    """
    path = inbox_path(args.team, args.terminal)
    matched = {"rec": None}
    after_iso = None
    after_id = None
    if args.after:
        if _ISO_RE.match(args.after):
            after_iso = args.after
        else:
            after_id = args.after

    def find(records):
        seen_after = after_id is None
        for r in records:
            if not seen_after:
                if (r.get("id") or "").startswith(after_id):
                    seen_after = True
                continue
            if r.get("thread_id") != args.thread:
                continue
            frm = f"{r.get('from_team','')}:{r.get('from_terminal','')}"
            if args.exclude_from and frm == args.exclude_from:
                continue
            if after_iso and not (r.get("created_at") or "") > after_iso:
                continue
            if args.consume and r.get("consumed_at"):
                continue
            return r
        return None

    def updater(records):
        r = find(records)
        if r is not None:
            if not r.get("read_at"):
                r["read_at"] = _now_iso()
            if args.consume:
                # Exactly-once: kb-ask can never be handed the same answer twice, even
                # if its own board write afterwards fails (XACA-1545-020).
                r["consumed_at"] = _now_iso()
            matched["rec"] = dict(r)
        return records

    # Polling must not create inbox/lock files for an identity with no mail, nor
    # rewrite the inbox on every idle poll (a rewrite also drops unparseable lines):
    # a read-only scan first, and the lock + atomic find-and-mark only on a hit.
    if not os.path.exists(path) or find(_read_jsonl(path)) is None:
        print(json.dumps({"ok": False, "error": "no reply"}))
        sys.exit(1)
    locked_update(path, updater)
    if matched["rec"] is None:
        print(json.dumps({"ok": False, "error": "no reply"}))
        sys.exit(1)
    if args.json:
        print(json.dumps(matched["rec"]))
    else:
        print(matched["rec"].get("body", ""))


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
    s.add_argument("--breakdown", action="store_true",
                   help="print JSON {total, team, terminal, scope, scope_sources}")
    s.add_argument("--sync-broadcasts", dest="sync_broadcasts", action="store_true",
                   help="first claim team broadcasts this terminal missed (XACA-1833)")
    s.add_argument("--transfer", action="store_true",
                   help="with --breakdown, add the Team Transfer _INBOX state/pending count (XACA-1941)")
    s.set_defaults(func=cmd_unread_count)

    s = sub.add_parser("transfer-count", help="Team Transfer _INBOX state + pending count, as JSON (XACA-1941)")
    s.add_argument("--team", required=True)
    s.set_defaults(func=cmd_transfer_count)

    s = sub.add_parser("transfer-list", help="list pending Team Transfer _INBOX files (XACA-1941)")
    s.add_argument("--team", required=True)
    s.add_argument("--json", action="store_true")
    s.add_argument("--explain", action="store_true",
                   help="also say so when the inbox is empty or unreachable")
    s.set_defaults(func=cmd_transfer_list)

    s = sub.add_parser("transfer-stage", help="copy one _INBOX file to a local staging dir (XACA-1941)")
    s.add_argument("--team", required=True)
    s.add_argument("--name", required=True, help="a name exactly as transfer-list prints it")
    s.add_argument("--dest", default=None, help="staging dir (default ~/.aiteamforge/transfer-staging/<folder>)")
    s.set_defaults(func=cmd_transfer_stage)

    s = sub.add_parser("transfer-done", help="move a handled file to _INBOX/_processed (user-approved only)")
    s.add_argument("--team", required=True)
    s.add_argument("--name", required=True, help="a name exactly as transfer-list prints it")
    s.add_argument("--approved", action="store_true", help="the user explicitly approved this move")
    s.set_defaults(func=cmd_transfer_done)

    s = sub.add_parser("triage-brief", help="print the comms-triage brief for a subagent")
    s.set_defaults(func=cmd_triage_brief)

    s = sub.add_parser("read", help="mark a message read by id")
    s.add_argument("--team", required=True)
    s.add_argument("--terminal", required=True)
    s.add_argument("--id", required=True)
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_read)

    s = sub.add_parser("thread-reply", help="first reply on a thread (marks only that reply read)")
    s.add_argument("--team", required=True)
    s.add_argument("--terminal", required=True)
    s.add_argument("--thread", required=True)
    s.add_argument("--exclude-from", dest="exclude_from", default=None, help="<team>:<terminal> to skip")
    s.add_argument("--after", default=None, help="ISO timestamp or message-id prefix")
    s.add_argument("--consume", action="store_true",
                   help="skip replies already consumed; mark the match consumed (exactly-once delivery)")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_thread_reply)

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
