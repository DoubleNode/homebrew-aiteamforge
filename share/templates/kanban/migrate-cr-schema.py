#!/usr/bin/env python3
"""
migrate-cr-schema.py — Idempotent CR-lifecycle schema migration for AITeamForge kanban boards.

Consumed by: kb-cr.sh helpers (after migration), manual operator runs.
Schema source: cr-schema.json (same directory as this script).

Usage:
    python3 migrate-cr-schema.py --board /path/to/team-board.json [--dry-run]
    python3 migrate-cr-schema.py --all-mobile [--dry-run]

Exit codes:
    0 — success (or dry-run with no errors)
    1 — user error (bad args, missing backup, board not found)
    2 — internal error (malformed JSON, schema load failure)
"""

import argparse
import json
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path


# ─────────────────────────────────────────────────────────────────────────────
# Canonical board paths for --all-mobile (mirrors kanban-helpers.sh lines 60-90)
# ─────────────────────────────────────────────────────────────────────────────
_ALL_MOBILE_BOARDS = [
    "/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban/ios-board.json",
    "/Users/Shared/Development/Main Event/MainEventApp-Android/kanban/android-board.json",
    "/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban/firebase-board.json",
    "/Users/Shared/Development/Main Event/dev-team/kanban/command-board.json",
]


def load_schema(schema_path: Path) -> dict:
    """Load cr-schema.json from the given path. Exits 2 on failure."""
    try:
        with open(schema_path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        print(f"ERROR: schema file not found: {schema_path}", file=sys.stderr)
        sys.exit(2)
    except json.JSONDecodeError as exc:
        print(f"ERROR: cr-schema.json is malformed: {exc}", file=sys.stderr)
        sys.exit(2)


def load_board(board_path: Path) -> dict:
    """Load and parse a board JSON file. Exits 1/2 on failure."""
    if not board_path.exists():
        print(f"ERROR: board file not found: {board_path}", file=sys.stderr)
        sys.exit(1)
    try:
        with open(board_path, encoding="utf-8") as fh:
            return json.load(fh)
    except json.JSONDecodeError as exc:
        print(f"ERROR: board JSON is malformed ({board_path}): {exc}", file=sys.stderr)
        sys.exit(2)


def check_recent_backup(board_path: Path) -> bool:
    """
    Return True if a recent backup file exists for the board.

    Looks for any file matching <board-basename>.bak-* in the same directory,
    where the file was modified within the last 60 minutes.
    """
    board_dir = board_path.parent
    name = board_path.name
    cutoff = datetime.now(tz=timezone.utc) - timedelta(minutes=60)

    for candidate in board_dir.glob(f"{name}.bak-*"):
        if candidate.is_file():
            mtime = datetime.fromtimestamp(candidate.stat().st_mtime, tz=timezone.utc)
            if mtime >= cutoff:
                return True
    return False


def print_backup_error(board_path: Path) -> None:
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    print(
        f"ERROR: refusing to migrate {board_path} without a backup.\n"
        f"Run: cp {board_path} {board_path}.bak-cr-schema-{ts} first.",
        file=sys.stderr,
    )


def migrate_board(
    board_path: Path,
    schema: dict,
    dry_run: bool = False,
) -> bool:
    """
    Apply CR-lifecycle schema additions to a single board file.

    Returns True if the board was (or would be) modified, False if already up-to-date.
    Exits 1 if no recent backup is found.
    """
    print(f"\n{'[DRY RUN] ' if dry_run else ''}Migrating: {board_path}")

    # ── Backup check ──────────────────────────────────────────────────────────
    if not check_recent_backup(board_path):
        print_backup_error(board_path)
        sys.exit(1)

    board = load_board(board_path)
    cr_states: list = schema.get("crStates", [])
    team_config_schema: dict = schema.get("teamConfig", {})
    cr_support_defaults: dict = team_config_schema.get("crSupport", {})

    added: list[str] = []
    already_present: list[str] = []

    # ── 1. Add missing crStates to board's statuses/columns ──────────────────
    # Boards use the key "statuses" OR "columns" (or neither yet).
    # We prefer "statuses"; fall back to "columns"; create "statuses" if absent.
    statuses_key = "statuses" if "statuses" in board else ("columns" if "columns" in board else "statuses")
    existing_statuses: list = board.get(statuses_key, [])
    existing_set = set(existing_statuses)

    new_states = [s for s in cr_states if s not in existing_set]
    already_states = [s for s in cr_states if s in existing_set]

    if new_states:
        added.append(f"{statuses_key}: added {new_states}")
        if not dry_run:
            board.setdefault(statuses_key, [])
            board[statuses_key].extend(new_states)
    else:
        already_present.append(f"{statuses_key}: all crStates already present")

    if already_states:
        already_present.append(f"  (already present: {already_states})")

    # ── 2. Add teamConfig.crSupport if missing ────────────────────────────────
    # Never touch the field if it already exists — preserves user-set enabled=true.
    tc = board.get("teamConfig", {})
    if "crSupport" in tc:
        already_present.append("teamConfig.crSupport: already present (not modified)")
    else:
        added.append("teamConfig.crSupport: added {enabled: false, description: ...}")
        if not dry_run:
            board.setdefault("teamConfig", {})
            board["teamConfig"]["crSupport"] = {
                "enabled": cr_support_defaults.get("enabled", False),
                "description": cr_support_defaults.get(
                    "description",
                    "Enable CR (CAB) support for this team. Configure via SETTINGS → TEAM CONFIG.",
                ),
            }

    # ── Summary ───────────────────────────────────────────────────────────────
    for msg in added:
        print(f"  + {msg}")
    for msg in already_present:
        print(f"  = {msg}")

    modified = bool(added)

    if not modified:
        print("  Board already up-to-date. No changes needed.")
        return False

    if dry_run:
        print("  [DRY RUN] No writes performed.")
        return True

    # ── Atomic write (temp-file + rename) ─────────────────────────────────────
    import tempfile, os

    board_dir = board_path.parent
    fd, tmp_path_str = tempfile.mkstemp(
        prefix=".migrate-cr-schema-", suffix=".tmp", dir=board_dir
    )
    tmp_path = Path(tmp_path_str)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(board, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        tmp_path.rename(board_path)
        print(f"  Written: {board_path}")
    except Exception as exc:
        tmp_path.unlink(missing_ok=True)
        print(f"ERROR: write failed for {board_path}: {exc}", file=sys.stderr)
        sys.exit(2)

    return True


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Idempotent CR-lifecycle schema migration for AITeamForge kanban boards.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )

    target_group = parser.add_mutually_exclusive_group(required=True)
    target_group.add_argument(
        "--board",
        metavar="PATH",
        help="Path to a single team board JSON file.",
    )
    target_group.add_argument(
        "--all-mobile",
        action="store_true",
        help="Target iOS, Android, Firebase, and MainEvent boards at their canonical paths.",
    )

    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what WOULD change without writing anything.",
    )

    args = parser.parse_args()

    # ── Load schema ───────────────────────────────────────────────────────────
    schema_path = Path(__file__).parent / "cr-schema.json"
    schema = load_schema(schema_path)

    # ── Resolve target board(s) ───────────────────────────────────────────────
    if args.all_mobile:
        # Prefer aiteamforge_team_kanban_dir env if available (set by aiteamforge installer).
        import os
        aiteamforge_dir = os.environ.get("AITEAMFORGE_DIR", "")
        if aiteamforge_dir:
            # Try to read team-paths.json from AITEAMFORGE_DIR
            team_paths_file = Path(aiteamforge_dir) / "team-paths.json"
            if team_paths_file.exists():
                try:
                    with open(team_paths_file, encoding="utf-8") as fh:
                        team_paths = json.load(fh)
                    teams_map = team_paths.get("teams", {})
                    if teams_map:
                        board_paths = []
                        for team_slug, team_info in teams_map.items():
                            if team_slug in ("ios", "android", "firebase", "mainevent"):
                                kanban_dir = team_info.get("kanbanDir", "")
                                if kanban_dir:
                                    board_paths.append(
                                        Path(kanban_dir) / f"{team_slug}-board.json"
                                    )
                        if board_paths:
                            print(
                                f"Using AITEAMFORGE_DIR team paths ({len(board_paths)} boards)"
                            )
                        else:
                            print(
                                "AITEAMFORGE_DIR set but no mobile teams found; "
                                "falling back to hardcoded paths."
                            )
                            board_paths = [Path(p) for p in _ALL_MOBILE_BOARDS]
                    else:
                        print("team-paths.json has empty teams map; falling back to hardcoded paths.")
                        board_paths = [Path(p) for p in _ALL_MOBILE_BOARDS]
                except (json.JSONDecodeError, KeyError):
                    print("Could not parse team-paths.json; falling back to hardcoded paths.")
                    board_paths = [Path(p) for p in _ALL_MOBILE_BOARDS]
            else:
                board_paths = [Path(p) for p in _ALL_MOBILE_BOARDS]
        else:
            board_paths = [Path(p) for p in _ALL_MOBILE_BOARDS]
    else:
        board_paths = [Path(args.board)]

    # ── Run migrations ────────────────────────────────────────────────────────
    total = 0
    modified = 0
    skipped = 0

    for bp in board_paths:
        total += 1
        if not bp.exists():
            print(f"\nSKIPPED (not found): {bp}")
            skipped += 1
            continue
        changed = migrate_board(bp, schema, dry_run=args.dry_run)
        if changed:
            modified += 1

    # ── Final summary ─────────────────────────────────────────────────────────
    print(
        f"\n{'[DRY RUN] ' if args.dry_run else ''}"
        f"Done. {total} board(s) checked, "
        f"{modified} modified, "
        f"{skipped} skipped (not found)."
    )


if __name__ == "__main__":
    main()
