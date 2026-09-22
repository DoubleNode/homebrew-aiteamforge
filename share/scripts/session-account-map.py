#!/usr/bin/env python3
"""
session-account-map.py — Append-only JSONL writer for session-to-account tagging.

Writes one JSON record per line to ~/.claude/.session-account-map.jsonl.
Each record pairs a Claude session_id with Anthropic account metadata that the
CC session JSONLs do not carry (account_id, nickname, team, terminal).

Usage:
    session-account-map.py record --session-id <id> [--account-id X]
                                   [--account-nickname Y] [--team Z]
                                   [--terminal T] [--cwd PATH] [--pid N]
                                   [--account-resolved]
    session-account-map.py lookup --session-id <id>
    session-account-map.py last-for-terminal --terminal <id>
    session-account-map.py compact [--keep-last N] [--keep-days D]

Auto-rotation on record:
    After each record write, if the file exceeds SESSION_ACCOUNT_MAP_ROTATE_AT
    lines (default 10000), the file is automatically compacted in-place keeping
    SESSION_ACCOUNT_MAP_KEEP_AFTER_ROTATE records (default 5000).  Rotation
    failure never fails the record call — errors are logged to stderr only.

account_resolved (XACA-0977 round 6, BLOCKING B):
    A boolean, OUT-OF-BAND flag recording whether this record's account_id
    reflects an actual, gated credential-resolution decision -- as opposed to
    "account_id" itself, which stays "" for BOTH "no opinion" and "resolved,
    but no account" so every falsiness-based reader of account_id (the LCARS
    ccusage collector, cc-whoami, etc.) keeps working unmodified.

    Pass --account-resolved when the caller DID run gated resolution, even if
    the result was empty (billed to default OAuth) -- this is what lets a
    reader tell "explicitly resolved to no account" apart from "the writer
    never had an opinion" when account_id is "". Omit it when the caller has
    no opinion at all (e.g. a belt-and-suspenders call with no gated identity
    available).

    SAFE DEFAULT WHEN ABSENT: false. Every record written before this field
    existed (including every record on disk before this ticket) has no
    account_resolved key at all; a reader must treat a missing key exactly
    like False -- "this record's account_id is not authoritative; do not
    treat an empty value here as a deliberate 'no account' answer." That is
    the same default a caller gets by simply omitting the flag, so old and
    new readers/writers interoperate without a migration step.
"""

import argparse
import json
import os
import sys
from collections import deque
from datetime import datetime, timezone, timedelta

DEFAULT_MAP_PATH = os.path.join(
    os.path.expanduser("~"), ".claude", ".session-account-map.jsonl"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _map_path() -> str:
    """Return the JSONL path, honouring SESSION_ACCOUNT_MAP_PATH env override."""
    return os.environ.get("SESSION_ACCOUNT_MAP_PATH", DEFAULT_MAP_PATH)


def _ensure_dir(path: str) -> None:
    """Create parent directories if they do not exist."""
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)


def _iter_records_reversed(path: str):
    """
    Yield parsed records from *path* in reverse order (most-recent first).

    Corrupted / non-JSON lines are silently skipped.
    Returns an empty iterator if the file does not exist.
    """
    if not os.path.exists(path):
        return
    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            # Skip corrupted lines silently.
            continue


def _count_lines(path: str) -> int:
    """
    Count newlines in *path* cheaply by reading in binary chunks.

    Returns 0 if the file does not exist or cannot be read.
    """
    if not os.path.exists(path):
        return 0
    try:
        count = 0
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                count += chunk.count(b"\n")
        return count
    except OSError:
        return 0


def _compact_file(path: str, keep_last: int = 1000, keep_days: int = 0) -> tuple[int, int]:
    """
    Compact *path* in-place using an atomic write.

    Keeps records meeting EITHER criterion when both are specified:
      - keep_last: keep the N most-recent records (by file order)
      - keep_days: keep records whose started_at is within D days of now

    Returns (before, after) line counts.
    Raises OSError on write failure.
    """
    if not os.path.exists(path):
        return 0, 0

    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.readlines()

    before = len([l for l in lines if l.strip()])

    # Parse records, keeping their raw line for round-trip fidelity.
    parsed: list[tuple[str, dict]] = []
    for raw in lines:
        stripped = raw.strip()
        if not stripped:
            continue
        try:
            rec = json.loads(stripped)
        except json.JSONDecodeError:
            rec = {}
        parsed.append((raw, rec))

    cutoff_dt = None
    if keep_days > 0:
        cutoff_dt = datetime.now(timezone.utc) - timedelta(days=keep_days)

    keep_set: set[int] = set()

    # keep_last: indices from the end
    if keep_last > 0:
        start = max(0, len(parsed) - keep_last)
        for i in range(start, len(parsed)):
            keep_set.add(i)

    # keep_days: records whose started_at >= cutoff
    if cutoff_dt is not None:
        for i, (raw, rec) in enumerate(parsed):
            started_at = rec.get("started_at", "")
            if started_at:
                try:
                    rec_dt = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
                    if rec_dt >= cutoff_dt:
                        keep_set.add(i)
                except ValueError:
                    pass

    # Default: if neither criterion was specified, keep everything
    if keep_last <= 0 and keep_days <= 0:
        keep_set = set(range(len(parsed)))

    kept_lines = [parsed[i][0] for i in sorted(keep_set)]
    after = len(kept_lines)

    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.writelines(kept_lines)
    os.replace(tmp, path)

    return before, after


def _maybe_rotate(path: str) -> None:
    """
    Check if *path* exceeds the auto-rotation threshold and compact if so.

    Thresholds are env-configurable:
      SESSION_ACCOUNT_MAP_ROTATE_AT         (default 10000)
      SESSION_ACCOUNT_MAP_KEEP_AFTER_ROTATE (default 5000)

    Never raises — rotation failure is logged to stderr but never propagated.
    """
    try:
        rotate_at = int(os.environ.get("SESSION_ACCOUNT_MAP_ROTATE_AT", "10000"))
        keep_after = int(os.environ.get("SESSION_ACCOUNT_MAP_KEEP_AFTER_ROTATE", "5000"))
    except ValueError:
        return

    try:
        current = _count_lines(path)
        if current <= rotate_at:
            return
        before, after = _compact_file(path, keep_last=keep_after)
        print(
            f"session-account-map.jsonl rotated: {before} → {after} records",
            file=sys.stderr,
        )
    except Exception as exc:  # noqa: BLE001
        print(f"session-account-map: auto-rotation failed (ignored): {exc}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------


def cmd_compact(args) -> int:
    """Compact the JSONL map file, keeping recent records."""
    path = _map_path()
    if not os.path.exists(path):
        print("session-account-map: nothing to compact — file does not exist.")
        return 0

    keep_last = args.keep_last if args.keep_last is not None else 1000
    keep_days = args.keep_days if args.keep_days is not None else 0

    try:
        before, after = _compact_file(path, keep_last=keep_last, keep_days=keep_days)
    except OSError as exc:
        print(f"session-account-map: compact failed: {exc}", file=sys.stderr)
        return 1

    print(f"Compacted: {before} → {after} records")
    return 0


def cmd_record(args) -> int:
    """Append a new record to the JSONL map."""
    record = {
        "session_id": args.session_id,
        "account_id": args.account_id if args.account_id is not None else "",
        # XACA-0977 round 6 (BLOCKING B): out-of-band companion to account_id
        # -- see the module docstring's "account_resolved" section for the
        # full contract. Always written explicitly (True or False) by this
        # (fixed) writer; only records from BEFORE this field existed lack
        # it, and every reader must default a missing key to False.
        "account_resolved": bool(args.account_resolved),
        "account_nickname": args.account_nickname if args.account_nickname is not None else "",
        "team": args.team if args.team is not None else "",
        "terminal": args.terminal if args.terminal is not None else "",
        "started_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "cwd": args.cwd if args.cwd is not None else os.getcwd(),
        "pid": args.pid if args.pid is not None else os.getppid(),
    }

    path = _map_path()
    _ensure_dir(path)

    line = json.dumps(record, separators=(",", ":")) + "\n"
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError as exc:
        print(f"session-account-map: write failed: {exc}", file=sys.stderr)
        return 1

    _maybe_rotate(path)
    return 0


def cmd_lookup(args) -> int:
    """
    Find and print the most-recent record matching --session-id.

    Exits 1 if no match found.
    """
    path = _map_path()
    # Use a deque of size 1 — we only need the first (most-recent) hit.
    result = deque(maxlen=1)
    for rec in _iter_records_reversed(path):
        if rec.get("session_id") == args.session_id:
            result.append(rec)
            break  # Stop on first match (most-recent).

    if not result:
        print(
            f"session-account-map: session_id '{args.session_id}' not found",
            file=sys.stderr,
        )
        return 1

    print(json.dumps(result[0], indent=2))
    return 0


def cmd_last_for_terminal(args) -> int:
    """
    Find and print the most-recent record matching --terminal.

    Exits 1 if no match found.
    """
    path = _map_path()
    result = deque(maxlen=1)
    for rec in _iter_records_reversed(path):
        if rec.get("terminal") == args.terminal:
            result.append(rec)
            break

    if not result:
        print(
            f"session-account-map: terminal '{args.terminal}' not found",
            file=sys.stderr,
        )
        return 1

    print(json.dumps(result[0], indent=2))
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Append-only JSONL session-to-account map for Claude Code sessions.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # --- record ---
    rec = sub.add_parser("record", help="Append a new session record.")
    rec.add_argument("--session-id", required=True, help="Claude session UUID.")
    rec.add_argument("--account-id", default=None, help="Anthropic account ID.")
    rec.add_argument(
        "--account-resolved",
        action="store_true",
        default=False,
        help=(
            "Set when the caller ran gated credential resolution, even if it "
            "produced no account (default OAuth). Omit when the caller has "
            "no opinion. See the module docstring for the full contract."
        ),
    )
    rec.add_argument("--account-nickname", default=None, help="Human-friendly account label.")
    rec.add_argument("--team", default=None, help="Team slug (e.g. academy, ios).")
    rec.add_argument("--terminal", default=None, help="TMUX_PANE or KB_TERMINAL value.")
    rec.add_argument("--cwd", default=None, help="Working dir at session start (default: cwd).")
    rec.add_argument("--pid", type=int, default=None, help="Invoking shell PID (default: getppid()).")

    # --- lookup ---
    lkp = sub.add_parser("lookup", help="Find most-recent record for a session_id.")
    lkp.add_argument("--session-id", required=True, help="Claude session UUID to look up.")

    # --- last-for-terminal ---
    lft = sub.add_parser("last-for-terminal", help="Find most-recent record for a terminal id.")
    lft.add_argument("--terminal", required=True, help="Terminal identifier (TMUX_PANE or KB_TERMINAL).")

    # --- compact ---
    cmp = sub.add_parser(
        "compact",
        help="Compact the JSONL map, keeping only recent records.",
    )
    cmp.add_argument(
        "--keep-last",
        type=int,
        default=None,
        metavar="N",
        help="Keep the N most-recent records (default 1000).",
    )
    cmp.add_argument(
        "--keep-days",
        type=int,
        default=None,
        metavar="D",
        help="Keep records newer than D days.  When combined with --keep-last, "
             "records meeting EITHER criterion are kept.",
    )

    return parser


def main() -> int:
    parser = _build_parser()
    args = parser.parse_args()

    if args.command == "record":
        return cmd_record(args)
    elif args.command == "lookup":
        return cmd_lookup(args)
    elif args.command == "last-for-terminal":
        return cmd_last_for_terminal(args)
    elif args.command == "compact":
        return cmd_compact(args)
    else:
        parser.print_help()
        return 1


if __name__ == "__main__":
    sys.exit(main())
