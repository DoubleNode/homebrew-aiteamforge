"""Domain 3: Dev-team team infrastructure at ~/dev-team/<team>/.

Personas, scripts, prompts, avatars, terminals, logos. Travels via the AITeamForge
setup channel.

The team subdirectory under ~/dev-team/ is derived from team_config['team'].
If team_config is None, falls back to the explicit `root` argument.
"""
from __future__ import annotations

from pathlib import Path

from .channels import AITEAMFORGE, ChannelConfig, UNTAGGED
from .checksum import is_excluded, safe_relpath, sha256_file, walk_files
from .manifest import EXACT, FileEntry, Manifest

DOMAIN = "devteam"


def inventory(
    manifest: Manifest,
    channels: ChannelConfig,
    root: Path | None = None,
    home: Path | None = None,
    team_config: dict | None = None,
) -> None:
    home = home or Path.home()

    if team_config is not None:
        team = team_config.get("team", "")
        devteam_root = root or (home / "dev-team" / team)
    else:
        devteam_root = root or (home / "dev-team")

    if not devteam_root.exists():
        manifest.domains.setdefault(DOMAIN, _empty_block())
        return

    for p in walk_files(devteam_root):
        abs_path = str(p)
        ch = channels.resolve(abs_path)
        if ch == UNTAGGED:
            ch = AITEAMFORGE  # safety net for new files in this tree
        fe = FileEntry(
            path=abs_path,
            relpath=safe_relpath(p, home),
            sha256=_safe_sha(p),
            size=p.stat().st_size,
            mtime=p.stat().st_mtime,
            cls=EXACT,
            channel=ch,
            domain=DOMAIN,
        )
        manifest.add_file(DOMAIN, fe)

    blk = manifest.domains.setdefault(DOMAIN, _empty_block())
    blk.stats = {"file_count": len(blk.files), "root": str(devteam_root)}


def _safe_sha(p: Path) -> str | None:
    try:
        return sha256_file(p)
    except (OSError, PermissionError):
        return None


def _empty_block():
    from .manifest import DomainBlock
    return DomainBlock()
