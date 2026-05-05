#!/usr/bin/env python3
"""
secrets_export_lib.py — Contract layer for LCARS per-team secrets export/import.

XACA-0172-001: source mapping + manifest schema constants.

This module is import-only — no route handlers, no I/O beyond path resolution.
Subitems 002 (export) and 003 (import) import from here.

─── Threat Model ──────────────────────────────────────────────────────────────
Channel separation:
    Secrets zip is distributed separately from the main kanban export so that
    a compromised export channel does not expose secrets.

Encryption:
    AES-256 (WZ_AES via pyzipper) protects file *contents*.

Metadata visibility:
    ZIP central directory is NOT encrypted by pyzipper's WZ_AES mode.
    File names and sizes within the zip ARE visible to anyone who opens the
    file without a password (e.g. `unzip -l secrets.zip`).  The manifest
    filename "secrets-manifest.json" and per-file arc paths are therefore
    considered semi-public.  Callers must ensure no secret values appear in
    file *names* — only in file *contents*.

Password handling:
    Password is accepted in the HTTP request body, passed as a thread
    argument to the worker, and explicitly nulled after use.  It is:
      * NEVER stored in the job dict (SECRETS_EXPORT_JOBS / SECRETS_IMPORT_JOBS)
      * NEVER written to any log statement
      * NEVER echoed in any status or error response
    DOM-side: the JS layer zeros the input immediately after the POST fires.

Retry budget:
    Wrong-password preflight attempts are capped at 5 (_SECRETS_IMPORT_MAX_PASSWORD_ATTEMPTS).
    After exhaustion the staged zip is deleted and the user must re-upload.
──────────────────────────────────────────────────────────────────────────────
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Dependency availability probe
# ---------------------------------------------------------------------------

def pyzipper_available() -> bool:
    """Return True if pyzipper is importable (AES-256 zip support)."""
    try:
        import pyzipper  # noqa: F401
        return True
    except ImportError:
        return False


# ---------------------------------------------------------------------------
# Export manifest schema constants
#
# Shape written into the encrypted zip as manifest.json:
# {
#   "version":    "1.0",
#   "kind":       "lcars-team-secrets",
#   "team":       "<team_id>",
#   "baseTeam":   "<base team string, e.g. 'academy'>",
#   "sourceHost": "<hostname of exporting machine>",
#   "exportId":   "<same job id as the paired main export zip>",
#   "createdAt":  "<ISO-8601 UTC>",
#   "fileCount":  <int>,
#   "targetRoot": "<rel path under which all targets are placed, e.g. 'secrets/'>",
#   "sources": [
#     {"target": "<rel path>", "kind": "file"|"dir", "fileCount": <int>},
#     ...
#   ]
# }
# ---------------------------------------------------------------------------

SECRETS_EXPORT_MANIFEST_KIND = "lcars-team-secrets"
SECRETS_EXPORT_MANIFEST_VERSION = "1.0"


# ---------------------------------------------------------------------------
# Secrets-manifest schema (kanban/<team>/secrets-manifest.json)
#
# {
#   "version":    "1.0",
#   "kind":       "lcars-team-secrets-source",
#   "targetRoot": "secrets/",
#   "sources": [
#     {"src": "<abs or ~-prefixed path>", "target": "<rel path under targetRoot>"},
#     ...
#   ]
# }
# ---------------------------------------------------------------------------

_MANIFEST_REQUIRED_KEYS = {"version", "kind", "sources", "targetRoot"}
_MANIFEST_KIND = "lcars-team-secrets-source"
_MANIFEST_VERSION = "1.0"


def validate_secrets_manifest(manifest_path: Path) -> dict:
    """Load and validate a team secrets-manifest.json.

    Returns the parsed dict on success.
    Raises ValueError with a descriptive message on any schema violation.
    Raises FileNotFoundError if the file does not exist.
    """
    with open(manifest_path, "r", encoding="utf-8") as fh:
        try:
            data = json.load(fh)
        except json.JSONDecodeError as exc:
            raise ValueError(f"secrets-manifest.json is not valid JSON: {exc}") from exc

    missing = _MANIFEST_REQUIRED_KEYS - set(data.keys())
    if missing:
        raise ValueError(
            f"secrets-manifest.json missing required keys: {sorted(missing)}"
        )

    if data.get("kind") != _MANIFEST_KIND:
        raise ValueError(
            f"secrets-manifest.json has wrong 'kind': expected '{_MANIFEST_KIND}', "
            f"got '{data.get('kind')}'"
        )

    if data.get("version") != _MANIFEST_VERSION:
        raise ValueError(
            f"secrets-manifest.json has wrong 'version': expected '{_MANIFEST_VERSION}', "
            f"got '{data.get('version')}'"
        )

    if not isinstance(data.get("sources"), list):
        raise ValueError("secrets-manifest.json 'sources' must be a list")

    for i, src_entry in enumerate(data["sources"]):
        if not isinstance(src_entry, dict):
            raise ValueError(f"secrets-manifest.json sources[{i}] must be an object")
        for key in ("src", "target"):
            if key not in src_entry:
                raise ValueError(
                    f"secrets-manifest.json sources[{i}] missing required key '{key}'"
                )

    return data


# ---------------------------------------------------------------------------
# Path resolution helpers
# ---------------------------------------------------------------------------

def _get_team_project_root(team_id: str) -> Path | None:
    """Return the project root (working_dir) for team_id via aiteamforge_paths.

    Returns None if the module is unavailable or the team is unknown — callers
    fall back to hardcoded logic.
    """
    # aiteamforge_paths lives in kanban-hooks/, which server.py prepends to sys.path.
    # We rely on the same setup rather than duplicating path wiring.
    try:
        from aiteamforge_paths import get_team_working_dir
        return get_team_working_dir(team_id)
    except Exception:
        return None


def _hardcoded_project_root(team_id: str) -> Path | None:
    """Fallback project-root map — mirrors aiteamforge_paths.DEFAULT_TEAMS working_dir."""
    home = Path.home()
    _MAP: dict[str, Path] = {
        "academy": home / "dev-team",
        "ios": Path("/Users/Shared/Development/Main Event/MainEventApp-iOS"),
        "android": Path("/Users/Shared/Development/Main Event/MainEventApp-Android"),
        "firebase": Path("/Users/Shared/Development/Main Event/MainEventApp-Functions"),
        "command": Path("/Users/Shared/Development/Main Event/dev-team"),
        "dns": Path("/Users/Shared/Development/DNSFramework"),
        "legal-coparenting": home / "legal" / "coparenting",
        "medical-general": home / "medical" / "general",
        "finance-personal": home / "finance" / "personal",
    }
    return _MAP.get(team_id)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def discover_secrets_sources(team_id: str) -> dict:
    """Discover secrets sources for a team.

    Resolution order:
    1. kanban/<team>/secrets-manifest.json relative to the team's project root
       — if present and valid, its sources/targetRoot are used verbatim.
    2. Auto-detect: <project_root>/secrets/ — if the directory exists, treat
       the whole dir as a single 'dir' source.
    3. Neither found — return empty sources list (caller skips secrets export).

    Returns:
        {
            "sources": [
                {"src": "<abs path str>", "target": "<rel path str>", "kind": "file"|"dir"},
                ...
            ],
            "target_root": "<rel path str, typically 'secrets/'>",
            "manifest_used": "auto" | "override:<abs manifest path>"
        }
    """
    project_root = _get_team_project_root(team_id) or _hardcoded_project_root(team_id)

    empty_result: dict[str, Any] = {
        "sources": [],
        "target_root": "secrets/",
        "manifest_used": "auto",
    }

    if project_root is None:
        return empty_result

    # Priority 1: explicit manifest override
    # The manifest lives at kanban/<team>/secrets-manifest.json inside the project root.
    # For academy the kanban dir IS project_root/kanban/, so the path is
    # ~/dev-team/kanban/academy/secrets-manifest.json.
    # For teams whose kanban_dir is already named by team (e.g. ios, android) it is
    # project_root/kanban/secrets-manifest.json — callers may also place a top-level one.
    manifest_candidates = [
        project_root / "kanban" / team_id / "secrets-manifest.json",
        project_root / "kanban" / "secrets-manifest.json",
    ]
    for manifest_path in manifest_candidates:
        if manifest_path.exists():
            try:
                data = validate_secrets_manifest(manifest_path)
            except (ValueError, OSError) as exc:
                # Malformed manifest is a hard error — don't silently fall through
                # to auto-detect and export unexpected files.
                raise ValueError(
                    f"Invalid secrets-manifest.json at {manifest_path}: {exc}"
                ) from exc

            target_root = data.get("targetRoot", "secrets/")
            sources = [
                {
                    "src": str(Path(entry["src"]).expanduser()),
                    "target": entry["target"],
                    "kind": "dir" if Path(entry["src"]).expanduser().is_dir() else "file",
                }
                for entry in data["sources"]
            ]
            return {
                "sources": sources,
                "target_root": target_root,
                "manifest_used": f"override:{manifest_path}",
            }

    # Priority 2: auto-detect <project_root>/secrets/
    auto_secrets_dir = project_root / "secrets"
    if auto_secrets_dir.exists() and auto_secrets_dir.is_dir():
        return {
            "sources": [
                {
                    "src": str(auto_secrets_dir),
                    "target": "secrets",
                    "kind": "dir",
                }
            ],
            "target_root": "secrets/",
            "manifest_used": "auto",
        }

    return empty_result
