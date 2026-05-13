"""Domain 1: Git repository.

Captures git-tracked files (exact + git channel), essential gitignored content
(database -> present + export, env files -> present + secrets_export), and sensitive
docs (icloud_excluded — manifested but verifier skips).

The databases to probe are taken from team_config['databases'] (opt-in per team).
If that key is absent or empty, no DB probing occurs — this layer is entirely optional.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

from .channels import ChannelConfig, EXPORT, GIT, ICLOUD_EXCLUDED, SECRETS_EXPORT, UNTAGGED, _substitute, _build_tokens
from .checksum import is_excluded, sha256_file, walk_files
from .manifest import EXACT, FileEntry, Manifest, PRESENT, SCHEMA

DOMAIN = "git_repo"


def inventory(
    repo_root: Path,
    manifest: Manifest,
    channels: ChannelConfig,
    *,
    db_probe_fn=None,
    skip_paths: set[Path] | None = None,
    team_config: dict | None = None,
    home: Path | None = None,
) -> None:
    """Walk the git repo and append entries to manifest under the git_repo domain.

    skip_paths: resolved Paths the caller has already accounted for (e.g. the
    manifest output file, which the generator adds as its own PRESENT-class entry).

    team_config: team YAML config dict. If provided, databases listed under
    team_config['databases'] are probed (opt-in). If absent, no DB probing occurs.
    """
    _home = home or Path.home()
    skip = {p.resolve() for p in (skip_paths or set())}
    if not repo_root.exists():
        manifest.domains.setdefault(DOMAIN, manifest.domains.get(DOMAIN) or _empty_block())
        return

    # 1. git-tracked files — these are the canonical "git" channel set.
    tracked = _git_tracked(repo_root)
    seen: set[Path] = set(skip)
    for rel in tracked:
        p = repo_root / rel
        if not p.exists():
            continue
        if is_excluded(p):
            continue
        rp = p.resolve()
        if rp in skip:
            continue
        seen.add(rp)
        _add_entry(manifest, p, _home, channels, repo_root, default_class=EXACT)

    # 2. Untracked / gitignored content that MUST travel.
    #    Walk the configured databases list (from team_config) plus any extras.
    extras: list[tuple[Path, str]] = []

    if team_config:
        tokens = _build_tokens(team_config, str(_home))
        for db_entry in team_config.get("databases", []):
            raw_path = db_entry.get("path", "")
            if raw_path:
                db_path = Path(_substitute(raw_path, tokens))
                extras.append((db_path, PRESENT))

    for p, cls in extras:
        if p.exists() and p.resolve() not in seen and not is_excluded(p):
            seen.add(p.resolve())
            _add_entry(manifest, p, _home, channels, repo_root, default_class=cls)

    # 3. Generic walk of remaining files in the repo root that aren't yet captured
    #    AND aren't in the kanban tree (kanban is its own domain).
    kanban_root = (repo_root / "kanban").resolve()
    for p in walk_files(repo_root):
        rp = p.resolve()
        if rp in seen:
            continue
        # Skip kanban tree (handled by domain_kanban).
        try:
            rp.relative_to(kanban_root)
            continue  # under kanban/
        except ValueError:
            pass
        seen.add(rp)
        _add_entry(manifest, p, _home, channels, repo_root, default_class=PRESENT)

    # 4. Probe databases declared in team_config and stash result on the manifest entry.
    if db_probe_fn is not None and team_config:
        tokens = _build_tokens(team_config, str(_home))
        for db_entry in team_config.get("databases", []):
            raw_path = db_entry.get("path", "")
            if not raw_path:
                continue
            db_path = Path(_substitute(raw_path, tokens))
            if not db_path.exists():
                continue
            probe = db_probe_fn(db_path)
            for fe in manifest.domains[DOMAIN].files:
                if fe.path == str(db_path):
                    fe.cls = SCHEMA
                    fe.probe = probe
                    break

    # Domain-level stats.
    blk = manifest.domains.setdefault(DOMAIN, _empty_block())
    blk.stats = {
        "file_count": len(blk.files),
        "tracked_files": len(tracked),
        "repo_root": str(repo_root),
    }


def _add_entry(manifest: Manifest, p: Path, home: Path, channels: ChannelConfig, repo_root: Path, default_class: str) -> None:
    abs_path = str(p)
    rel = p.relative_to(home).as_posix() if _is_under(p, home) else p.as_posix()
    ch = channels.resolve(abs_path)
    cls = default_class
    # If file is icloud_excluded, don't bother hashing.
    sha = None if ch == ICLOUD_EXCLUDED else _safe_sha(p)
    fe = FileEntry(
        path=abs_path,
        relpath=rel,
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


def _git_tracked(repo_root: Path) -> list[str]:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(repo_root), "ls-files"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    return [line for line in out.splitlines() if line]


def _is_under(p: Path, root: Path) -> bool:
    try:
        p.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def _empty_block():
    from .manifest import DomainBlock
    return DomainBlock()
