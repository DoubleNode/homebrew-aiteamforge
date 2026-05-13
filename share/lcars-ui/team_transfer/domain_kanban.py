"""Domain 2: Kanban tree at <repo_root>/kanban/ + worktrees.

Kanban is fully gitignored — it travels via the 'export' channel only.

The board filename and ticket prefix are read from team_config (populated by the team
YAML config file). If team_config is None, the SCHEMA-class board probe is skipped
and all board JSON files are treated as EXACT.
"""
from __future__ import annotations

import json
from pathlib import Path

from .channels import ChannelConfig, EXPORT, UNTAGGED
from .checksum import is_excluded, safe_relpath, sha256_file, walk_files
from .manifest import EXACT, FileEntry, Manifest, PRESENT, SCHEMA

DOMAIN = "kanban"


def inventory(
    repo_root: Path,
    manifest: Manifest,
    channels: ChannelConfig,
    home: Path | None = None,
    team_config: dict | None = None,
) -> None:
    home = home or Path.home()
    kanban_root = repo_root / "kanban"
    worktrees_root = repo_root / "worktrees"

    board_filename = (team_config or {}).get("board_filename") if team_config else None
    ticket_prefix = (team_config or {}).get("ticket_prefix") if team_config else None

    if kanban_root.exists():
        for p in walk_files(kanban_root):
            cls = _class_for(p, board_filename=board_filename)
            probe = _probe_for(p, ticket_prefix=ticket_prefix) if cls == SCHEMA else None
            _emit(manifest, p, home, channels, cls, probe)

    if worktrees_root.exists():
        # Capture only the directory listing (not files inside worktrees — those are
        # transient working state).
        try:
            entries = sorted([c.name for c in worktrees_root.iterdir()])
        except OSError:
            entries = []
        import hashlib
        listing_bytes = ("\n".join(entries)).encode("utf-8")
        sha = hashlib.sha256(listing_bytes).hexdigest()
        fe = FileEntry(
            path=str(worktrees_root),
            relpath=safe_relpath(worktrees_root, home),
            sha256=sha,
            size=len(listing_bytes),
            mtime=worktrees_root.stat().st_mtime,
            cls=PRESENT,
            channel=channels.resolve(str(worktrees_root)) or EXPORT,
            domain=DOMAIN,
            probe={"worktrees": entries},
        )
        if fe.channel == UNTAGGED:
            fe.channel = EXPORT  # safe fallback; worktrees ride the export channel
        manifest.add_file(DOMAIN, fe)

    blk = manifest.domains.setdefault(DOMAIN, _empty_block())
    blk.stats = {"file_count": len(blk.files), "kanban_root": str(kanban_root)}


def _class_for(p: Path, *, board_filename: str | None) -> str:
    name = p.name
    # The board JSON gets a structural probe when we know the filename (not exact match —
    # kb commands write to it constantly, so SHA256 will drift between source and destination
    # by the time of audit).
    if board_filename and name == board_filename:
        return SCHEMA
    if name.endswith(".lock"):
        return PRESENT  # transient, but if present, just verify existence
    return EXACT


def _probe_for(p: Path, *, ticket_prefix: str | None) -> dict | None:
    """For board.json, capture item count and ID list as a structural snapshot."""
    if not ticket_prefix:
        return None
    try:
        with open(p, "r", encoding="utf-8") as f:
            board = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        return {"error": str(e)}
    ids = sorted(_walk_ids(board, ticket_prefix=ticket_prefix))
    return {"item_count": len(ids), "item_ids": ids[:200]}


def _walk_ids(obj, *, ticket_prefix: str):
    if isinstance(obj, dict):
        i = obj.get("id")
        if isinstance(i, str) and i.startswith(ticket_prefix):
            yield i
        for v in obj.values():
            yield from _walk_ids(v, ticket_prefix=ticket_prefix)
    elif isinstance(obj, list):
        for v in obj:
            yield from _walk_ids(v, ticket_prefix=ticket_prefix)


def _emit(manifest: Manifest, p: Path, home: Path, channels: ChannelConfig, cls: str, probe: dict | None) -> None:
    abs_path = str(p)
    ch = channels.resolve(abs_path)
    sha = None if cls == PRESENT else _safe_sha(p)
    fe = FileEntry(
        path=abs_path,
        relpath=safe_relpath(p, home),
        sha256=sha,
        size=p.stat().st_size,
        mtime=p.stat().st_mtime,
        cls=cls,
        channel=ch,
        domain=DOMAIN,
        probe=probe,
    )
    manifest.add_file(DOMAIN, fe)


def _safe_sha(p: Path) -> str | None:
    try:
        return sha256_file(p)
    except (OSError, PermissionError):
        return None


def _empty_block():
    from .manifest import DomainBlock
    return DomainBlock()
