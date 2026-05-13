"""Domain 5: Claude state.

- ~/.claude/projects/<project_dir>/memory/  (exact)
- ~/.claude/projects/<project_dir>/*.jsonl  (present — drifts)
- ~/.claude/projects/<project_dir>/<UUID>/  (present)
- ~/<team_root>/.claude/agents/             (exact)

The project directory name is read from team_config['claude_project_dir_name'].
If team_config is None, falls back to the explicit `claude_root` argument.

The finance/.claude/agents root is derived from team_config['home_relative_root']
(strip the last path segment to get the team home dir, e.g. 'finance/personal' -> 'finance').
"""
from __future__ import annotations

from pathlib import Path

from .channels import AITEAMFORGE, ChannelConfig, UNTAGGED
from .checksum import is_excluded, sha256_file, walk_files
from .manifest import EXACT, FileEntry, Manifest, PRESENT

DOMAIN = "claude"


def inventory(
    manifest: Manifest,
    channels: ChannelConfig,
    *,
    claude_root: Path | None = None,
    finance_root: Path | None = None,
    home: Path | None = None,
    team_config: dict | None = None,
) -> None:
    _home = home or Path.home()

    if team_config is not None:
        project_dir_name = team_config.get("claude_project_dir_name", "")
        croot = claude_root or (_home / ".claude" / "projects" / project_dir_name)
        # Derive the .claude/agents root from home_relative_root.
        # e.g. "finance/personal" -> top-level team dir is "finance"
        rel_root = team_config.get("home_relative_root", "")
        team_top = rel_root.split("/")[0] if rel_root else ""
        froot = finance_root or (_home / team_top / ".claude" / "agents" if team_top else _home / ".claude" / "agents")
    else:
        croot = claude_root or Path("/nonexistent")
        froot = finance_root or Path("/nonexistent")

    if croot.exists():
        # Memory dir -> exact
        mem = croot / "memory"
        if mem.exists():
            for p in walk_files(mem):
                _emit(manifest, p, _home, channels, EXACT)
        # *.jsonl session histories -> present (will drift)
        for p in croot.glob("*.jsonl"):
            if p.is_file() and not is_excluded(p):
                _emit(manifest, p, _home, channels, PRESENT)
        # UUID-named subdirs -> present (per-session state)
        for d in croot.iterdir():
            if d.is_dir() and d.name != "memory":
                files_in = sum(1 for _ in walk_files(d))
                fe = FileEntry(
                    path=str(d),
                    relpath=d.relative_to(_home).as_posix(),
                    sha256=None,
                    size=0,
                    mtime=d.stat().st_mtime,
                    cls=PRESENT,
                    channel=channels.resolve(str(d)) if channels.resolve(str(d)) != UNTAGGED else AITEAMFORGE,
                    domain=DOMAIN,
                    probe={"file_count": files_in, "kind": "session_subdir"},
                )
                manifest.add_file(DOMAIN, fe)

    if froot.exists():
        for p in walk_files(froot):
            _emit(manifest, p, _home, channels, EXACT)

    blk = manifest.domains.setdefault(DOMAIN, _empty_block())
    blk.stats = {
        "file_count": len(blk.files),
        "claude_root": str(croot),
        "finance_agents_root": str(froot),
    }


def _emit(manifest: Manifest, p: Path, home: Path, channels: ChannelConfig, cls: str) -> None:
    abs_path = str(p)
    ch = channels.resolve(abs_path)
    if ch == UNTAGGED:
        ch = AITEAMFORGE
    sha = None if cls == PRESENT else _safe_sha(p)
    fe = FileEntry(
        path=abs_path,
        relpath=p.relative_to(home).as_posix() if _under(p, home) else p.as_posix(),
        sha256=sha,
        size=p.stat().st_size,
        mtime=p.stat().st_mtime,
        cls=cls,
        channel=ch,
        domain=DOMAIN,
    )
    manifest.add_file(DOMAIN, fe)


def _safe_sha(p: Path) -> str | None:
    try:
        return sha256_file(p)
    except (OSError, PermissionError):
        return None


def _under(p: Path, root: Path) -> bool:
    try:
        p.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def _empty_block():
    from .manifest import DomainBlock
    return DomainBlock()
