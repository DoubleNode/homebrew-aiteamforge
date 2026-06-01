#!/usr/bin/env python3
"""
migrate-cr-schema.py — Idempotent CR schema migration (v1 → v2)

Transforms team board JSON files from the per-item cr_* field pattern to the
v2.0 CR-as-Container pattern: a top-level crs[] collection (mirroring epics[]/
releases[]) with crAssignment back-pointers on items.

Usage:
    # Batch mode (whole board):
    migrate-cr-schema.py <board.json>

    # Per-item mode (single item, dry-run by default):
    migrate-cr-schema.py --item <item-id> --board <board.json>
    migrate-cr-schema.py --item <item-id> --board <board.json> --apply

Exit codes:
    0 — success (including no-op when already migrated)
    1 — backup failed (disk full, permission denied, etc.)
    2 — input file not found / unreadable
    3 — input file is not valid JSON
    4 — migration produced invalid JSON (rollback attempted from backup)
    5 — item-id not found on board (--item mode only)
    6 — item has no CR data to migrate (--item mode only)

Safety:
    - ALWAYS writes a timestamped backup before ANY mutation.
      If the backup write fails the script aborts with exit 1 — the original
      board is never touched.
    - Writes atomically: stages in memory → <board>.tmp → rename to <board>.
      A mid-flight kill cannot leave a half-written board.
    - No third-party dependencies — stdlib only.
    - Running the script a second time on an already-migrated board is a NO-OP.
    - --item mode: defaults to dry-run; pass --apply to write changes.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

# Per-item field names that belong on the CR container record after migration.
# These are deleted from items once a CR record has been created.
DEPRECATED_ITEM_CR_FIELDS = [
    "cr_id",
    "cr_type",
    "crState",
    "cr_approved_by",
    "cr_approver_name",
    "cr_pushback_count",
    "cr_pushback_notes",
    "cr_summary",
    "cr_doc_link",
    "deploy_window_planned",
    "platform",
    "emergency_justification",
    # Lifecycle timestamps (per-item → move to container timestamps{})
    "cr_created_at",
    "cr_submitted_at",
    "cr_approved_at",
    "cr_rejected_at",
    "cr_held_at",
    "cr_dev_started_at",
    "cr_testing_started_at",
    "cr_deployed_dev_at",
    "cr_deployed_prod_at",
    "cr_emergency_deployed_at",
    "cr_completed_at",
]

# Timestamp fields that live under the CR record's timestamps{} object.
TIMESTAMP_FIELDS = {
    "cr_created_at",
    "cr_submitted_at",
    "cr_approved_at",
    "cr_rejected_at",
    "cr_held_at",
    "cr_dev_started_at",
    "cr_testing_started_at",
    "cr_deployed_dev_at",
    "cr_deployed_prod_at",
    "cr_emergency_deployed_at",
    "cr_completed_at",
}

# Top-level board keys that hold item arrays.
# The board currently uses a single "backlog" array; this list is kept broad
# so the script is resilient to future board shape changes.
ITEM_CONTAINER_KEYS = [
    "backlog",
    "items",
    "active",
    "inProgress",
    "inReview",
    "done",
    "completed",
    "cancelled",
    "paused",
    "blocked",
]


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _item_has_deprecated_cr_fields(item: dict) -> bool:
    """Return True if the item has any populated (non-empty) deprecated cr_* fields."""
    for field in DEPRECATED_ITEM_CR_FIELDS:
        val = item.get(field)
        if val is not None and val != "" and val != 0:
            return True
    return False


def _item_is_already_migrated(item: dict) -> bool:
    """
    Return True if the item looks fully migrated:
      - Has a crAssignment back-pointer
      - Has NO deprecated cr_* fields remaining
    """
    has_assignment = bool(item.get("crAssignment"))
    has_deprecated = _item_has_deprecated_cr_fields(item)
    return has_assignment and not has_deprecated


def _parse_cr_seq(cr_id: str) -> int:
    """
    Extract the numeric sequence from a CR-<TEAM>-<YYYYMMDD>-<seq> identifier.
    Returns -1 on parse failure (treated as non-numeric / unknown).
    """
    if not isinstance(cr_id, str):
        return -1
    parts = cr_id.rsplit("-", 1)
    if len(parts) == 2:
        try:
            return int(parts[1])
        except ValueError:
            pass
    return -1


def _collect_items(board: dict) -> list:
    """
    Return a flat list of (container_key, index, item) tuples for every item
    object found in the board's known item containers.
    Recursively descends into subitems[] arrays one level only
    (subitems don't carry cr_* fields in practice but we skip gracefully).
    """
    result = []
    for key in ITEM_CONTAINER_KEYS:
        container = board.get(key)
        if not isinstance(container, list):
            continue
        for idx, item in enumerate(container):
            if isinstance(item, dict):
                result.append((key, idx, item))
    return result


# ─────────────────────────────────────────────────────────────────────────────
# Core migration logic
# ─────────────────────────────────────────────────────────────────────────────

def migrate_board(board: dict, item_filter: str | None = None) -> tuple:
    """
    Migrate the board dict in-place.

    Args:
      board: parsed board JSON dict
      item_filter: when set, only the item with this id is migrated; all other
                   items are left untouched (used by migrate_item() to scope
                   per-item migration). Default None = process all v1 items.

    Returns (items_migrated: int, cr_records_created: int, warnings: list[str])

    Idempotency contract:
      - If an item already has crAssignment and no deprecated fields → skip.
      - If crs[] already has a record with matching cr_id → skip creating a
        duplicate; still write crAssignment back-pointer if missing on item.
      - nextCrSeq is only increased, never decreased.
    """
    warnings = []
    items_migrated = 0
    new_cr_count = 0

    # 1. Initialise top-level board fields if absent.
    if not isinstance(board.get("crs"), list):
        board["crs"] = []
    if not isinstance(board.get("nextCrSeq"), int):
        board["nextCrSeq"] = 1

    # 2. Build an index of cr_id → existing CR record from crs[] so we can
    #    detect duplicates and merge multi-item CRs.
    existing_cr_by_id: dict = {}
    for record in board["crs"]:
        if isinstance(record, dict) and isinstance(record.get("id"), str):
            existing_cr_by_id[record["id"]] = record

    # We build new/updated CR records in a working dict keyed by cr_id so we
    # can accumulate itemIds across multiple items that share a cr_id.
    # pending_cr_by_id:  cr_id → partially-built CR record dict
    pending_cr_by_id: dict = {}

    # 3. Walk all items and collect CR data from deprecated fields.
    for container_key, idx, item in _collect_items(board):
        item_id = item.get("id", f"{container_key}[{idx}]")

        # Per-item scope: skip every item except the named one.
        if item_filter is not None and item_id != item_filter:
            continue

        # Already fully migrated — skip.
        if _item_is_already_migrated(item):
            continue

        # Item has no deprecated cr_* data at all — skip (nothing to migrate).
        if not _item_has_deprecated_cr_fields(item):
            continue

        # Validate cr_id.
        raw_cr_id = item.get("cr_id")
        if raw_cr_id is None or raw_cr_id == "":
            # Item has some cr_* data but no cr_id.  We can't build a proper
            # CR record without an identifier, so we log a warning and skip.
            warnings.append(
                f"WARNING: item '{item_id}' has cr_* fields but cr_id is "
                f"empty/missing — skipping (manual cleanup required)."
            )
            continue

        if not isinstance(raw_cr_id, str):
            warnings.append(
                f"WARNING: item '{item_id}' has non-string cr_id "
                f"({type(raw_cr_id).__name__}: {raw_cr_id!r}) — skipping."
            )
            continue

        cr_id = raw_cr_id

        # Check if this cr_id already exists in the board's crs[] array.
        if cr_id in existing_cr_by_id:
            # CR record already exists — just update itemIds and write
            # crAssignment back-pointer on the item if missing.
            existing_record = existing_cr_by_id[cr_id]
            item_ids = existing_record.setdefault("itemIds", [])
            if item_id not in item_ids:
                item_ids.append(item_id)
            if not item.get("crAssignment"):
                item["crAssignment"] = {
                    "crId": cr_id,
                    "crTitle": existing_record.get("title", ""),
                    "assignedAt": _now_iso(),
                }
            # Remove deprecated fields from item.
            for field in DEPRECATED_ITEM_CR_FIELDS:
                item.pop(field, None)
            items_migrated += 1
            continue

        # Build or update a pending CR record for this cr_id.
        if cr_id not in pending_cr_by_id:
            # First time we encounter this cr_id — build the skeleton.
            record: dict = {
                "id": cr_id,
                "title": item.get("title", ""),
                "type": item.get("cr_type", "major"),
                "crState": item.get("crState", "cr-drafted"),
                "itemIds": [],
                "pushback_count": item.get("cr_pushback_count", 0) or 0,
                "timestamps": {},
                "createdAt": item.get("cr_created_at") or _now_iso(),
                "updatedAt": _now_iso(),
            }

            # Optional scalar fields — only set if present on item.
            for src_field, dst_field in [
                ("deploy_window_planned", "deploy_window_planned"),
                ("cr_doc_link", "cr_doc_link"),
                ("cr_pushback_notes", "pushback_notes"),
                ("cr_summary", "summary"),
                ("platform", "platform"),
                ("emergency_justification", "emergency_justification"),
            ]:
                val = item.get(src_field)
                if val is not None and val != "":
                    record[dst_field] = val

            # Build approver object.
            login = item.get("cr_approved_by") or ""
            name = item.get("cr_approver_name") or ""
            if login or name:
                record["approver"] = {
                    "login": login,
                    "name": name,
                }

            # Collect timestamps.
            for ts_field in TIMESTAMP_FIELDS:
                val = item.get(ts_field)
                if val:
                    record["timestamps"][ts_field] = val

            pending_cr_by_id[cr_id] = record
        else:
            # We've seen this cr_id before (multi-item CR).  Merge timestamps
            # and approver; don't clobber existing fields.
            record = pending_cr_by_id[cr_id]
            for ts_field in TIMESTAMP_FIELDS:
                if ts_field not in record["timestamps"]:
                    val = item.get(ts_field)
                    if val:
                        record["timestamps"][ts_field] = val
            # Merge approver if not yet set.
            if "approver" not in record:
                login = item.get("cr_approved_by") or ""
                name = item.get("cr_approver_name") or ""
                if login or name:
                    record["approver"] = {"login": login, "name": name}

        # Accumulate this item's id into the CR's itemIds.
        pending_cr_by_id[cr_id]["itemIds"].append(item_id)

    # 4. Commit all pending CR records to the board's crs[] array and write
    #    crAssignment back-pointers + delete deprecated fields from items.
    for cr_id, record in pending_cr_by_id.items():
        board["crs"].append(record)
        existing_cr_by_id[cr_id] = record  # keep index current
        new_cr_count += 1

    # 5. Second pass: write crAssignment back-pointers on items that were just
    #    processed (pending_cr_by_id keys) and remove deprecated fields.
    # When item_filter is set, only mutate the named item. Otherwise the second
    # pass would silently half-migrate siblings sharing the same cr_id —
    # writing crAssignment without adding them to itemIds, leaving the
    # bidirectional invariant broken.
    for container_key, idx, item in _collect_items(board):
        item_id = item.get("id", "")
        if item_filter is not None and item_id != item_filter:
            continue
        raw_cr_id = item.get("cr_id")
        if not isinstance(raw_cr_id, str) or not raw_cr_id:
            continue
        if raw_cr_id not in existing_cr_by_id:
            continue
        if _item_is_already_migrated(item):
            continue

        cr_record = existing_cr_by_id[raw_cr_id]

        # Write back-pointer if missing.
        if not item.get("crAssignment"):
            item["crAssignment"] = {
                "crId": raw_cr_id,
                "crTitle": cr_record.get("title", ""),
                "assignedAt": _now_iso(),
            }

        # Delete deprecated fields.
        for field in DEPRECATED_ITEM_CR_FIELDS:
            item.pop(field, None)

        items_migrated += 1

    # 6. Update nextCrSeq to be max(existing seq numbers) + 1.
    all_seqs = [_parse_cr_seq(r["id"]) for r in board["crs"] if isinstance(r.get("id"), str)]
    positive_seqs = [s for s in all_seqs if s > 0]
    if positive_seqs:
        new_seq = max(positive_seqs) + 1
        if new_seq > board["nextCrSeq"]:
            board["nextCrSeq"] = new_seq

    return items_migrated, new_cr_count, warnings


# ─────────────────────────────────────────────────────────────────────────────
# Per-item migration (single-item wrapper around migrate_board)
# ─────────────────────────────────────────────────────────────────────────────

def migrate_item(board_path: Path, item_id: str, apply: bool) -> int:
    """
    Migrate a single item (item_id) on board_path from v1 → v2 shape.

    Validation contract (exits before any backup or write):
      - Item not found on board           → exit 5
      - Item has no CR data at all        → exit 6
      - Item already fully v2 (crAssignment + no deprecated fields) → exit 0 (no-op)
      - Item has v1 cr_* fields           → dry-run print (no --apply) or migrate

    Returns an integer exit code.
    """
    # ── Read board ────────────────────────────────────────────────────────────
    if not board_path.exists():
        print(f"ERROR: file not found: {board_path}", file=sys.stderr)
        return 2

    try:
        raw = board_path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot read {board_path}: {exc}", file=sys.stderr)
        return 2

    try:
        board = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"ERROR: {board_path} is not valid JSON: {exc}", file=sys.stderr)
        return 3

    # ── Locate the item across all known containers ───────────────────────────
    target_item = None
    for container_key, _idx, item in _collect_items(board):
        if isinstance(item, dict) and item.get("id") == item_id:
            target_item = item
            break

    if target_item is None:
        print(
            f"ERROR: item '{item_id}' not found on board {board_path}",
            file=sys.stderr,
        )
        return 5

    # ── Classify the item ─────────────────────────────────────────────────────
    has_assignment = bool(target_item.get("crAssignment"))
    has_deprecated = _item_has_deprecated_cr_fields(target_item)

    if has_assignment and not has_deprecated:
        # Already fully v2 — idempotent no-op.
        print(f"no-op (already v2): item '{item_id}' has crAssignment and no deprecated cr_* fields.")
        return 0

    if not has_deprecated and not has_assignment:
        # Item exists but has zero CR data — nothing to migrate.
        print(
            f"ERROR: item '{item_id}' has no CR data (no cr_* fields, no crAssignment).",
            file=sys.stderr,
        )
        return 6

    # ── At this point the item has v1 cr_* fields → migrate ──────────────────
    if not apply:
        print(
            f"[DRY RUN] item '{item_id}' has v1 CR fields — would migrate to v2 container shape.\n"
            f"  Pass --apply to write changes."
        )
        return 0

    # ── Backup BEFORE any mutation ────────────────────────────────────────────
    ts_str = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup_path = board_path.with_suffix(f".backup.{ts_str}")

    try:
        backup_path.write_text(raw, encoding="utf-8")
    except OSError as exc:
        print(
            f"ERROR: backup write failed — aborting to protect original board.\n"
            f"  Backup path: {backup_path}\n"
            f"  Reason: {exc}",
            file=sys.stderr,
        )
        return 1

    # ── Run migration (reuse existing batch logic, scoped to one item) ────────
    # item_filter pins migrate_board() to the single named item; all other
    # items on the board are left untouched.
    items_migrated, new_cr_records, warnings = migrate_board(board, item_filter=item_id)

    for w in warnings:
        print(w, file=sys.stderr)

    # ── Validate output parses ────────────────────────────────────────────────
    try:
        output_json = json.dumps(board, indent=2, ensure_ascii=False)
        json.loads(output_json)  # round-trip check
    except (TypeError, ValueError) as exc:
        print(
            f"ERROR: migration produced invalid JSON: {exc}\n"
            f"  Original board preserved. Backup at: {backup_path}",
            file=sys.stderr,
        )
        try:
            board_path.write_text(raw, encoding="utf-8")
            print("  Rollback: restored original from in-memory copy.", file=sys.stderr)
        except OSError as rollback_exc:
            print(
                f"  CRITICAL: rollback also failed: {rollback_exc}\n"
                f"  Manually restore from: {backup_path}",
                file=sys.stderr,
            )
        return 4

    # ── Atomic write ──────────────────────────────────────────────────────────
    tmp_path = board_path.with_suffix(".tmp")
    try:
        tmp_path.write_text(output_json, encoding="utf-8")
        os.replace(str(tmp_path), str(board_path))
    except OSError as exc:
        print(
            f"ERROR: atomic write failed: {exc}\n"
            f"  Original board may be intact. Backup at: {backup_path}",
            file=sys.stderr,
        )
        tmp_path.unlink(missing_ok=True)
        return 1

    # ── Summary ───────────────────────────────────────────────────────────────
    print(
        f"Migrated item '{item_id}': {items_migrated} item(s) → {new_cr_records} new CR record(s). "
        f"Backup: {backup_path}"
    )
    return 0


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        prog="migrate-cr-schema.py",
        description="Migrate CR schema from v1 (per-item cr_* fields) to v2 (container).",
        add_help=True,
    )
    # Per-item mode flags
    parser.add_argument(
        "--item",
        metavar="ITEM_ID",
        default=None,
        help="Migrate a single item by ID (dry-run unless --apply is also given).",
    )
    parser.add_argument(
        "--board",
        metavar="BOARD_JSON",
        default=None,
        help="Path to the board JSON file (required with --item; also accepted in batch mode).",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        default=False,
        help="Write changes to disk (required for --item to mutate; batch mode always applies).",
    )
    # Positional: legacy batch-mode invocation (migrate-cr-schema.py <board.json>)
    parser.add_argument(
        "board_positional",
        nargs="?",
        metavar="board.json",
        default=None,
        help="Board JSON file (batch mode — positional, for backwards compatibility).",
    )

    args = parser.parse_args()

    # ── Resolve board path ────────────────────────────────────────────────────
    if args.board is not None:
        board_path = Path(args.board)
    elif args.board_positional is not None:
        board_path = Path(args.board_positional)
    else:
        parser.print_usage(sys.stderr)
        print("ERROR: provide a board JSON path (--board or positional argument).", file=sys.stderr)
        return 2

    # ── Per-item mode ─────────────────────────────────────────────────────────
    if args.item is not None:
        return migrate_item(board_path, args.item, apply=args.apply)

    # ── Batch mode (original behaviour, always applies) ───────────────────────

    # ── Exit 2: input not found / unreadable ─────────────────────────────────
    if not board_path.exists():
        print(f"ERROR: file not found: {board_path}", file=sys.stderr)
        return 2

    try:
        raw = board_path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot read {board_path}: {exc}", file=sys.stderr)
        return 2

    # ── Exit 3: not valid JSON ────────────────────────────────────────────────
    try:
        board = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"ERROR: {board_path} is not valid JSON: {exc}", file=sys.stderr)
        return 3

    # ── Detect no-op BEFORE writing backup ───────────────────────────────────
    # A board is already fully initialised if crs[] exists, nextCrSeq is present,
    # and no items contain deprecated cr_* fields that need migrating.  In that
    # case we skip the backup entirely (no mutation, no backup needed).
    _crs_initialised = isinstance(board.get("crs"), list) and isinstance(board.get("nextCrSeq"), int)
    _has_items_to_migrate = any(
        _item_has_deprecated_cr_fields(item)
        for key in ITEM_CONTAINER_KEYS
        for item in (board.get(key) or [])
        if isinstance(item, dict)
    )
    if _crs_initialised and not _has_items_to_migrate:
        print("No CR data to migrate. Skipping backup.")
        return 0

    # ── Backup BEFORE any mutation ────────────────────────────────────────────
    ts_str = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup_path = board_path.with_suffix(f".backup.{ts_str}")

    try:
        backup_path.write_text(raw, encoding="utf-8")
    except OSError as exc:
        print(
            f"ERROR: backup write failed — aborting to protect original board.\n"
            f"  Backup path: {backup_path}\n"
            f"  Reason: {exc}",
            file=sys.stderr,
        )
        return 1  # Exit 1: backup failed

    # ── Run migration ─────────────────────────────────────────────────────────
    items_migrated, new_cr_records, warnings = migrate_board(board)

    for w in warnings:
        print(w, file=sys.stderr)

    # ── Validate output parses ────────────────────────────────────────────────
    try:
        output_json = json.dumps(board, indent=2, ensure_ascii=False)
        json.loads(output_json)  # round-trip check
    except (TypeError, ValueError) as exc:
        print(
            f"ERROR: migration produced invalid JSON: {exc}\n"
            f"  Original board preserved. Backup at: {backup_path}",
            file=sys.stderr,
        )
        # Attempt rollback from backup.
        try:
            board_path.write_text(raw, encoding="utf-8")
            print(f"  Rollback: restored original from in-memory copy.", file=sys.stderr)
        except OSError as rollback_exc:
            print(
                f"  CRITICAL: rollback also failed: {rollback_exc}\n"
                f"  Manually restore from: {backup_path}",
                file=sys.stderr,
            )
        return 4  # Exit 4: migration produced invalid JSON

    # ── Atomic write: .tmp → rename ───────────────────────────────────────────
    tmp_path = board_path.with_suffix(".tmp")
    try:
        tmp_path.write_text(output_json, encoding="utf-8")
        os.replace(str(tmp_path), str(board_path))
    except OSError as exc:
        print(
            f"ERROR: atomic write failed: {exc}\n"
            f"  Original board may be intact. Backup at: {backup_path}",
            file=sys.stderr,
        )
        tmp_path.unlink(missing_ok=True)
        return 1

    # ── Summary ───────────────────────────────────────────────────────────────
    if items_migrated == 0 and new_cr_records == 0:
        print(f"No CR data to migrate. Board is up to date. Backup: {backup_path}")
    else:
        print(
            f"Migrated {items_migrated} item(s) into {new_cr_records} new CR record(s). "
            f"Backup: {backup_path}"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
