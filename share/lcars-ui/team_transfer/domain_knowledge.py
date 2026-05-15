"""Domain 4: Knowledge base.

Scans agent-tier and subject-tier knowledge dirs for the team's personas.
Persona list is read from team_config['personas'] if present; falls back to
the legacy TEAM_PERSONAS constant for backward compatibility.

- Agent tier:   ~/knowledge/agents/<persona>/
- Subject tier: ~/knowledge/subjects/<topic>/  (referenced by persona files)
- Project tier: <repo_root>/kanban/knowledge/  (future-use; manifested if present)

Persona files for subject-reference scanning are resolved from
~/dev-team/<team>/personas/agents/ when team_config is provided.
"""
from __future__ import annotations

import re
from pathlib import Path

from .channels import USER_STATE, ChannelConfig, UNTAGGED
from .checksum import sha256_file, walk_files
from .manifest import EXACT, FileEntry, Manifest

DOMAIN = "knowledge"

# Legacy default — only used when team_config doesn't provide personas.
_LEGACY_FINANCE_PERSONAS = ("quark", "nog", "brunt", "rom", "zek")


def inventory(
    manifest: Manifest,
    channels: ChannelConfig,
    *,
    knowledge_root: Path | None = None,
    repo_root: Path | None = None,
    home: Path | None = None,
    team_config: dict | None = None,
) -> None:
    _home = home or Path.home()
    k_root = knowledge_root or (_home / "knowledge")
    project_kn = (repo_root or (_home / "finance" / "personal")) / "kanban" / "knowledge"

    # Determine team and persona list from config.
    team = (team_config or {}).get("team", "")
    if team_config is not None and "personas" in team_config:
        personas = tuple(team_config["personas"])
    else:
        # Backward compat: fall back to finance persona list.
        personas = _LEGACY_FINANCE_PERSONAS

    # Agent-tier dirs (one per persona; some may not yet exist).
    for persona in personas:
        agent_dir = k_root / "agents" / persona
        if agent_dir.exists():
            for p in walk_files(agent_dir):
                _emit(manifest, p, _home, channels)

    # Subject-tier dirs that this team's personas reference.
    # Heuristic: scan persona files in ~/dev-team/<team>/personas/agents/ for
    # `subjects/<topic>` references.
    referenced_subjects = _scan_referenced_subjects(_home, team=team)
    for topic in referenced_subjects:
        sub_dir = k_root / "subjects" / topic
        if sub_dir.exists():
            for p in walk_files(sub_dir):
                _emit(manifest, p, _home, channels)

    # Project-tier (in-repo).
    if project_kn.exists():
        for p in walk_files(project_kn):
            _emit(manifest, p, _home, channels)

    # Legacy in-repo TEAM/INDEX.md.
    legacy_team = (repo_root or (_home / "finance" / "personal")) / "knowledge" / "TEAM" / "INDEX.md"
    if legacy_team.exists():
        _emit(manifest, legacy_team, _home, channels)

    blk = manifest.domains.setdefault(DOMAIN, _empty_block())
    blk.stats = {
        "file_count": len(blk.files),
        "personas_inventoried": list(personas),
        "subjects_inventoried": sorted(referenced_subjects),
    }


def _scan_referenced_subjects(home: Path, *, team: str = "") -> set[str]:
    """Look in ~/dev-team/<team>/personas/agents/ persona files for subject references."""
    out: set[str] = set()
    if not team:
        return out
    persona_dir = home / "dev-team" / team / "personas" / "agents"
    if not persona_dir.exists():
        return out
    pat = re.compile(r"subjects/([a-z0-9_\-]+)/")
    for p in persona_dir.glob("*.md"):
        try:
            text = p.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for m in pat.finditer(text):
            out.add(m.group(1))
    return out


def _emit(manifest: Manifest, p: Path, home: Path, channels: ChannelConfig) -> None:
    abs_path = str(p)
    ch = channels.resolve(abs_path)
    if ch == UNTAGGED:
        ch = USER_STATE
    fe = FileEntry(
        path=abs_path,
        relpath=p.relative_to(home).as_posix() if _under(p, home) else p.as_posix(),
        sha256=_safe_sha(p),
        size=p.stat().st_size,
        mtime=p.stat().st_mtime,
        cls=EXACT,
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
