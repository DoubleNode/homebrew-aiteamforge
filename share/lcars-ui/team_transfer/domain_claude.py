"""Domain 5: Claude state.

- ~/.claude/projects/<project_dir>/memory/  (exact)
- ~/.claude/projects/<project_dir>/*.jsonl  (present — drifts)
- ~/<team_root>/.claude/agents/             (exact)

UUID-named subdirs under <project_dir>/ are intentionally NOT inventoried —
directory-typed manifest entries cannot round-trip through the file-based zip
pipeline (see XACA-0579 and the inline comment in `inventory()` for the full
explanation). The primary `<UUID>.jsonl` session transcripts at the glob line
above carry the conversation history that matters for migration; subagent
transcripts inside `<UUID>/subagents/` are ephemeral debug content.

The project directory name is read from team_config['claude_project_dir_name'].
If team_config is None, falls back to the explicit `claude_root` argument.

The finance/.claude/agents root is derived from team_config['home_relative_root']
(strip the last path segment to get the team home dir, e.g. 'finance/personal' -> 'finance').
"""
from __future__ import annotations

from pathlib import Path

from .channels import USER_STATE, ChannelConfig, UNTAGGED
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
        # UUID-named subdirs (subagent transcript containers) are intentionally
        # NOT emitted as directory-typed entries.  Directories cannot round-trip
        # through the file-based zip pipeline: zipfile.write(dir, relpath) stores
        # relpath/ (trailing slash) but the import loop checks for relpath (no
        # slash), so the entry is skipped and the directory is never created on
        # the destination.  The primary session transcript (<UUID>.jsonl) is
        # the artifact that matters for resume; subagent transcripts inside
        # <UUID>/subagents/ are ephemeral debug content acceptable to omit.
        # (XACA-0579 — sibling-drift fix; see XACA-0579-001_AUDIT.md)

    if froot.exists():
        for p in walk_files(froot):
            # finance/.claude/agents/ is installer-carried (aiteamforge_product channel).
            # ADR §3.2: aiteamforge_product files must use PRESENT — installer mutates
            # these files on the destination after update, so EXACT would false-FAIL.
            _emit(manifest, p, _home, channels, PRESENT)

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
        ch = USER_STATE
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
