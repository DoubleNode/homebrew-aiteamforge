#!/usr/bin/env python3
"""aiteamforge_org_paths.py — Organization identity resolver (Python layer).

XACA-0139-001 — Foundation: org identity config loader.

This module is the Python counterpart to
``homebrew-tap/libexec/lib/aiteamforge-org-paths.sh``. Both must produce
identical results for the same ``organization.yaml`` input.

Design
------
# xaca-0139:allowed — module docstring explaining the historical context; "Main Event" and "DoubleNode" are origin examples only
Before XACA-0139 the AITeamForge framework had the client organization
("Main Event") baked into shipped code and documentation.  XACA-0139 # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
extracts that identity into a per-install YAML file so the same tap can be
installed for Main Event, DoubleNode, or any third-party org. # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)

Organization identity is the *fourth axis* of the Three-Axis Configuration
Model (XACA-0130):

    Axis 1: Machine       (which box)
    Axis 2: Team          (which board / group of humans)
    Axis 3: Role          (which persona an agent is currently wearing)
    Axis 4: Organization  (which client/company the install belongs to)

Resolution order (first hit wins):

    1. ``$AITEAMFORGE_ORG_CONFIG``  — env override, for tests / CI
    2. ``$AITEAMFORGE_DIR/organization.yaml``
    3. ``$HOME/.aiteamforge/organization.yaml``
    4. ``<share>/config/organization.yaml.example`` — shipped fallback

If none of the above exist, :func:`_load_org_config` raises
:class:`FileNotFoundError`.  In the normal install the shipped example
guarantees the fallback resolves, so callers rarely need to catch this.

Module-level side effects
-------------------------
NONE.  All I/O happens on first call to :func:`_load_org_config`.
The parsed config is cached; pass ``force_reload=True`` to invalidate.

Usage
-----
    from aiteamforge_org_paths import org_slug, org_plugin_enabled

    if org_plugin_enabled("main-event"):
        ...

    slug = org_slug()
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Optional

try:
    import yaml  # PyYAML — shipped in the tap's Python venv (share/requirements.txt)
except ImportError as _yaml_err:  # pragma: no cover — venv guarantees availability
    yaml = None  # type: ignore[assignment]
    _YAML_IMPORT_ERROR: Optional[ImportError] = _yaml_err
else:
    _YAML_IMPORT_ERROR = None


# ---------------------------------------------------------------------------
# Module-level cache
# ---------------------------------------------------------------------------

_ORG_CONFIG_CACHE: Optional[dict] = None
_ORG_CONFIG_CACHE_PATH: Optional[str] = None  # path we loaded from

#: Defaults applied when a field is missing from the resolved config.
_DEFAULTS: dict[str, Any] = {
    "organization": {
        "slug": "example-org",
        "name": "Example Organization",
        "display_short": "",   # falls back to organization.name
        "domain": "",
    },
    "paths": {
        "projects_root": "${HOME}/projects",
        "shared_dev_root": "",
    },
    "plugins": {
        "enabled": [],
    },
    "integrations": {},
}


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _share_dir() -> Optional[Path]:
    """Return the tap's ``share/`` directory, or None if unlocatable.

    Honours ``$AITEAMFORGE_SHARE_DIR`` first; otherwise infers from this
    file's location (kanban-hooks lives under share/).
    """
    env = os.environ.get("AITEAMFORGE_SHARE_DIR", "").strip()
    if env:
        return Path(env).expanduser()
    # This file lives at <share>/kanban-hooks/aiteamforge_org_paths.py
    here = Path(__file__).resolve().parent
    candidate = here.parent  # share/
    if (candidate / "config").exists() or (candidate / "kanban-hooks").exists():
        return candidate
    return None


def _expand_home(value: str) -> str:
    """Expand ``${HOME}`` and ``$HOME`` inside a path string."""
    if not value:
        return value
    home = str(Path.home())
    return value.replace("${HOME}", home).replace("$HOME", home)


def org_config_path() -> Path:
    """Return the :class:`Path` to the active ``organization.yaml``.

    Follows the resolution order documented at the top of the module.
    Raises :class:`FileNotFoundError` if *no* config (not even the shipped
    example) can be located — this indicates a broken install.
    """
    # 1. Env override
    env = os.environ.get("AITEAMFORGE_ORG_CONFIG", "").strip()
    if env:
        return Path(env).expanduser()

    # 2. Working-dir config
    atf_dir = os.environ.get("AITEAMFORGE_DIR", "").strip()
    if atf_dir:
        candidate = Path(atf_dir).expanduser() / "organization.yaml"
        if candidate.exists():
            return candidate

    # 3. Canonical per-user config
    canonical = Path.home() / ".aiteamforge" / "organization.yaml"
    if canonical.exists():
        return canonical

    # 4. Shipped example (framework fallback)
    share = _share_dir()
    if share is not None:
        example = share / "config" / "organization.yaml.example"
        if example.exists():
            return example

    raise FileNotFoundError(
        "Could not locate organization.yaml. Searched: "
        "$AITEAMFORGE_ORG_CONFIG, $AITEAMFORGE_DIR/organization.yaml, "
        "~/.aiteamforge/organization.yaml, and "
        "<share>/config/organization.yaml.example"
    )


def _merge_defaults(parsed: dict) -> dict:
    """Return *parsed* merged over :data:`_DEFAULTS` (two-level deep)."""
    merged: dict[str, Any] = {}
    for section, default_block in _DEFAULTS.items():
        incoming = parsed.get(section) if isinstance(parsed, dict) else None
        if isinstance(default_block, dict):
            block: dict[str, Any] = dict(default_block)
            if isinstance(incoming, dict):
                block.update(incoming)
            merged[section] = block
        else:
            merged[section] = incoming if incoming is not None else default_block
    # Preserve any unknown top-level sections verbatim (forward compat)
    if isinstance(parsed, dict):
        for key, value in parsed.items():
            if key not in merged:
                merged[key] = value
    return merged


def _load_org_config(force_reload: bool = False) -> dict:
    """Load, validate, and cache the organization config.

    Args:
        force_reload: If True, bypass the cache and re-read from disk.

    Returns:
        A dict shaped like ``_DEFAULTS``, with user values merged on top.

    Raises:
        FileNotFoundError: If no config file can be located.
        RuntimeError: If PyYAML is unavailable (install is broken).
    """
    global _ORG_CONFIG_CACHE, _ORG_CONFIG_CACHE_PATH

    if yaml is None:
        raise RuntimeError(
            "PyYAML is required to parse organization.yaml but could not be "
            f"imported: {_YAML_IMPORT_ERROR!r}"
        )

    config_path = org_config_path()
    path_str = str(config_path)

    if (
        not force_reload
        and _ORG_CONFIG_CACHE is not None
        and _ORG_CONFIG_CACHE_PATH == path_str
    ):
        return _ORG_CONFIG_CACHE

    try:
        raw = config_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise FileNotFoundError(
            f"Could not read organization.yaml at {config_path}: {exc}"
        ) from exc

    parsed = yaml.safe_load(raw) or {}
    if not isinstance(parsed, dict):
        parsed = {}

    merged = _merge_defaults(parsed)

    _ORG_CONFIG_CACHE = merged
    _ORG_CONFIG_CACHE_PATH = path_str
    return merged


# ---------------------------------------------------------------------------
# Public API — scalar accessors
# ---------------------------------------------------------------------------

def org_slug() -> str:
    """Return ``organization.slug`` or the default ``"example-org"``."""
    config = _load_org_config()
    value = (config.get("organization") or {}).get("slug")
    return str(value) if value else "example-org"


def org_name() -> str:
    """Return ``organization.name`` or the default ``"Example Organization"``."""
    config = _load_org_config()
    value = (config.get("organization") or {}).get("name")
    return str(value) if value else "Example Organization"


def org_display_short() -> str:
    """Return ``organization.display_short`` or fall back to :func:`org_name`."""
    config = _load_org_config()
    value = (config.get("organization") or {}).get("display_short")
    if value:
        return str(value)
    return org_name()


def org_domain() -> str:
    """Return ``organization.domain`` or empty string if unset."""
    config = _load_org_config()
    value = (config.get("organization") or {}).get("domain")
    return str(value) if value else ""


def org_projects_root() -> Path:
    """Return ``paths.projects_root`` as an expanded :class:`Path`.

    Defaults to ``$HOME/projects`` if unset.
    """
    config = _load_org_config()
    value = (config.get("paths") or {}).get("projects_root") or "${HOME}/projects"
    return Path(_expand_home(str(value))).expanduser()


def org_shared_dev_root() -> Optional[Path]:
    """Return ``paths.shared_dev_root`` as a :class:`Path`, or ``None`` if unset."""
    config = _load_org_config()
    value = (config.get("paths") or {}).get("shared_dev_root")
    if not value:
        return None
    return Path(_expand_home(str(value))).expanduser()


# ---------------------------------------------------------------------------
# Public API — plugins + integrations
# ---------------------------------------------------------------------------

def org_plugin_enabled(slug: str) -> bool:
    """Return True if *slug* appears in ``plugins.enabled``."""
    if not slug:
        return False
    config = _load_org_config()
    enabled = (config.get("plugins") or {}).get("enabled") or []
    if not isinstance(enabled, list):
        return False
    return slug in {str(item) for item in enabled}


def org_integration_get(integration: str, key: str) -> Optional[str]:
    """Return ``integrations.<integration>.<key>`` as a string, or None.

    List values are joined with newlines.  Dict values return None (callers
    that need nested blocks should load the raw config directly).
    """
    if not integration or not key:
        return None
    config = _load_org_config()
    block = (config.get("integrations") or {}).get(integration)
    if not isinstance(block, dict):
        return None
    value = block.get(key)
    if value is None:
        return None
    if isinstance(value, list):
        return "\n".join(str(item) for item in value)
    if isinstance(value, dict):
        return None
    return str(value)
