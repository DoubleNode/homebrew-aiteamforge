"""SHA256 helpers + exclusion-rule walker.

Stdlib-only.
"""
from __future__ import annotations

import fnmatch
import hashlib
from pathlib import Path
from typing import Iterator

# Paths that NEVER appear in the manifest. Regenerable noise or transient state.
ALWAYS_EXCLUDE_GLOBS = (
    # XACA-0487: exclude git internals to prevent false positives on fresh clones
    # with different pack files (object store is repackaged on every gc/push).
    "**/.git/**",
    "**/.git",
    "**/.venv/**",
    "**/.venv",
    "**/__pycache__/**",
    "**/__pycache__",
    "**/*.pyc",
    "**/*.pyo",
    "**/.pytest_cache/**",
    "**/.pytest_cache",
    "**/*.egg-info/**",
    "**/*.egg-info",
    "**/.DS_Store",
    "**/*.json.lock",
    # SQLite write-ahead-log / shared-memory sidecars — transient state
    # regenerated on the destination when the db is reopened. XACA-0496:
    # surfaced via XACA-0488's new export_database channel-class invariant
    # which requires cls=schema; sidecars naturally fall into cls=present
    # and tripped the invariant on every E2E round-trip.
    "**/*.db-shm",
    "**/*.db-wal",
    "**/node_modules/**",
    "**/node_modules",
    "**/firebase-debug.log",
    "**/kanban/tmp/**",  # explicitly per its own .gitignore
    # XACA-0490: the generator writes PRE_EXPORT_CHECKLIST.md alongside the manifest
    # on every run. It is generator-owned derived output — not user content — and
    # must never be cataloged as a manifest entry. Without this glob, a prior run's
    # checklist would be swept up by domain_git on the next run.
    "**/docs/migration/PRE_EXPORT_CHECKLIST.md",
)


def is_excluded(path: Path) -> bool:
    s = str(path)
    return any(fnmatch.fnmatchcase(s, pat) or _name_match(path, pat) for pat in ALWAYS_EXCLUDE_GLOBS)


def _name_match(path: Path, pat: str) -> bool:
    # fnmatchcase doesn't honor `**` segment matching; use Path.match for that semantic.
    try:
        return path.match(pat)
    except ValueError:
        return False


def walk_files(root: Path) -> Iterator[Path]:
    """Yield every file under `root` that is not excluded. Symlinks yielded as-is."""
    if not root.exists():
        return
    if root.is_file():
        if not is_excluded(root):
            yield root
        return
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        if is_excluded(p):
            continue
        yield p


def sha256_file(path: Path, chunk: int = 8 * 1024 * 1024) -> str:
    """Streaming SHA256."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def safe_relpath(p: Path, home: Path) -> str:
    """Return path relative to `home` if possible, else absolute POSIX."""
    try:
        return p.relative_to(home).as_posix()
    except ValueError:
        return p.as_posix()
