#!/usr/bin/env python3
"""
release_profile_resolver.py -- XACA-1343-002.

Content-profile layering resolver for the release engine. Spec:
docs/release-workflow/RELEASE-LIFECYCLE.md § 11.1 (layering), § 2.2 (team
copies are never shared files), § 11.3 (release-profile/v1).

Tiers, highest precedence first:

  team     <team kanban>/config/profiles/<kind>/
  group    <team kanban>/config/profiles/_group/<kind>/
  default  scripts/release_profile_defaults/<kind>/   (Academy minimal default)

Kinds: cr, testing-log, cr-record, notice.

Resolution is PER FILE. profile.json, style.md and the template file are each
taken from the highest tier that has that file, independently: a team that
overrides only style.md still gets template.md from the group or default tier
in the same call. The template file is ``template.md``; for the ``notice``
kind (which holds many named templates such as ``cr-submitted.md``) it is
``<notice_name>.md``.

profile.json MERGE RULE: the profile.json of every tier that has one is
merged, team > group > default, as a recursive dict merge. Where a higher tier
and a lower tier both define a key: if both values are dicts they are merged
recursively; otherwise (scalar, list, or a dict-vs-non-dict mismatch) the
higher tier's value REPLACES the lower one wholesale. Lists are never
concatenated or unioned, so a team that lists its own requiredSections gets
exactly those and none from the default. A key present only in a lower tier
is inherited. There is no way to delete an inherited key (set it to null or an
empty list to neutralise it).

Group tier: the team's ``<kanban>/config/wiki.json`` may declare
``profileGroup: "<name>"``. On first resolution, when a group is declared and
``_group/<kind>/`` does not exist yet, the catalog
``scripts/release_profile_groups/<name>/<kind>/`` is COPIED into
``_group/<kind>/`` and resolution proceeds from the copy. The copy is never
refreshed or overwritten afterwards (§ 2.2): once ``_group/<kind>/`` exists it
is the team's own file set, and is used even if wiki.json later drops the
declaration. A declared group whose catalog directory does not exist AT ALL
(a typo'd name) raises ProfileResolutionError. A group that exists but does not
provide a given kind (no ``<name>/<kind>/`` subdirectory) falls through to the
default tier for that kind, exactly like a present-but-empty directory; nothing
is recorded in profileResolvedFrom for the absent group tier. A copy failure
(OSError) raises ProfileResolutionError and leaves no temp dir behind.
A leading underscore in a group name (e.g. ``_layering_test``) marks it
test-only; names are never used as team-tree path segments.

Result of resolve_profile() (a dict, JSON-serialisable):

  {
    "profile":  <merged profile.json dict, schema-valid>,
    "template": <template text, or None if no tier has it>,
    "style":    <style.md text, or None if no tier has it>,
    "profileResolvedFrom": {
        "kind": "cr",
        "profile.json": ["team", "default"],  # every contributing tier,
                                              # highest first ([] = none had one)
        "template.md":  "group",              # single tier, or null if absent
        "style.md":     "default",            # single tier, or null if absent
    },
  }

For notice, the template key is ``"<notice_name>.md"`` instead of
``"template.md"`` (absent when no notice_name is given). Records persist
profileResolvedFrom verbatim; kb-wiki doctor (XACA-1344) prints it.

The merged profile is validated with validate_profile_config(); an invalid
result raises ReleaseConfigValidationError, never a silent return.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import shutil
import sys
from pathlib import Path
from typing import Any, Optional

_THIS_DIR = Path(__file__).resolve().parent


def _load_rcv():
    """Import the sibling release_config_validate (dev tree and tap layout)."""
    mod = sys.modules.get("release_config_validate")
    if mod is not None:
        return mod
    spec = importlib.util.spec_from_file_location(
        "release_config_validate", _THIS_DIR / "release_config_validate.py"
    )
    mod = importlib.util.module_from_spec(spec)
    sys.modules["release_config_validate"] = mod
    spec.loader.exec_module(mod)
    return mod


_rcv = _load_rcv()
ReleaseConfigValidationError = _rcv.ReleaseConfigValidationError
validate_profile_config = _rcv.validate_profile_config

PROFILE_KINDS = ("cr", "testing-log", "cr-record", "notice")
TIERS = ("team", "group", "default")  # highest precedence first

# Resolved relative to this module so it works from the tap's share/scripts/.
_DEFAULTS_ROOT = _THIS_DIR / "release_profile_defaults"
_GROUPS_ROOT = _THIS_DIR / "release_profile_groups"

_SLUG_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}(?![\s\S])")


class ProfileResolutionError(Exception):
    """Raised when a profile cannot be resolved (bad kind/name, missing group
    catalog, unreadable or non-object profile.json, unknown team)."""


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise ProfileResolutionError(
            f"cannot read {path.name} ({type(exc).__name__}) at {path}"
        ) from None


def _read_json_object(path: Path) -> dict:
    try:
        data = json.loads(_read_text(path))
    except ValueError:
        raise ProfileResolutionError(f"invalid JSON in {path}") from None
    if not isinstance(data, dict):
        raise ProfileResolutionError(f"{path} must contain a JSON object")
    return data


def merge_profiles(low: dict, high: dict) -> dict:
    """Recursive dict merge; `high` wins. Lists/scalars replace, not combine."""
    out = dict(low)
    for key, hv in high.items():
        lv = out.get(key)
        if isinstance(lv, dict) and isinstance(hv, dict):
            out[key] = merge_profiles(lv, hv)
        else:
            out[key] = hv
    return out


def _team_kanban_dir(team: str) -> Path:
    try:
        paths = _rcv._load_aiteamforge_paths_module()
        return Path(paths.get_team_kanban_dir(team))
    except KeyError as exc:
        raise ProfileResolutionError(str(exc)) from None
    except Exception as exc:  # noqa: BLE001 - registry load failure: fail closed
        raise ProfileResolutionError(
            f"cannot resolve kanban dir for team '{team}' ({type(exc).__name__})"
        ) from None


def _declared_group(config_dir: Path) -> Optional[str]:
    wiki = config_dir / "wiki.json"
    if not wiki.is_file():
        return None
    group = _read_json_object(wiki).get("profileGroup")
    if group is None:
        return None
    if not isinstance(group, str) or not _SLUG_RE.match(group):
        raise ProfileResolutionError("wiki.json profileGroup must be a simple name")
    return group


def _ensure_group_cache(
    config_dir: Path, kind: str, group: str, groups_root: Path
) -> None:
    """Copy the catalog into _group/<kind>/ once; never overwrite an existing copy."""
    cache = config_dir / "profiles" / "_group" / kind
    if cache.exists():
        return
    group_dir = groups_root / group
    if not group_dir.is_dir():
        raise ProfileResolutionError(
            f"profileGroup '{group}' is declared but has no catalog at {group_dir}"
        )
    catalog = group_dir / kind
    if not catalog.is_dir():
        return  # group does not provide this kind: fall through to default
    tmp = cache.parent / f".{kind}.tmp-{os.getpid()}"
    try:
        cache.parent.mkdir(parents=True, exist_ok=True)
        if tmp.exists():
            shutil.rmtree(str(tmp))
        shutil.copytree(str(catalog), str(tmp))
        try:
            os.rename(str(tmp), str(cache))
        except OSError:
            shutil.rmtree(str(tmp), ignore_errors=True)
            if not cache.exists():
                raise
    except OSError as exc:
        shutil.rmtree(str(tmp), ignore_errors=True)
        raise ProfileResolutionError(
            f"cannot populate group cache for kind '{kind}' "
            f"({type(exc).__name__})"
        ) from exc


def resolve_profile(
    team: str,
    kind: str,
    *,
    kanban_dir: Any = None,
    notice_name: Optional[str] = None,
    defaults_root: Any = None,
    groups_root: Any = None,
) -> dict:
    """
    Resolve `kind` for `team` across team > group > default, per file.

    kanban_dir     team kanban dir (contains config/); default: the team
                   registry lookup used by release_config_validate.
    notice_name    for kind 'notice': the named template to resolve
                   (``<notice_name>.md``).
    defaults_root / groups_root   test injection points.

    See the module docstring for the result shape and merge rule.
    """
    if kind not in PROFILE_KINDS:
        raise ProfileResolutionError(
            f"unknown profile kind '{kind}' (expected one of {', '.join(PROFILE_KINDS)})"
        )
    if notice_name is not None:
        if kind != "notice":
            raise ProfileResolutionError("notice_name is only valid for kind 'notice'")
        if not isinstance(notice_name, str) or not _SLUG_RE.match(notice_name):
            raise ProfileResolutionError("notice_name must be a simple name")

    kdir = Path(kanban_dir) if kanban_dir is not None else _team_kanban_dir(team)
    config_dir = kdir / "config"
    d_root = Path(defaults_root) if defaults_root is not None else _DEFAULTS_ROOT
    g_root = Path(groups_root) if groups_root is not None else _GROUPS_ROOT

    group = _declared_group(config_dir)
    if group is not None:
        _ensure_group_cache(config_dir, kind, group, g_root)

    tier_dirs = {
        "team": config_dir / "profiles" / kind,
        "group": config_dir / "profiles" / "_group" / kind,
        "default": d_root / kind,
    }

    template_file = "template.md" if kind != "notice" else (
        "%s.md" % notice_name if notice_name else None
    )

    def first_tier(filename: str) -> Optional[str]:
        for tier in TIERS:
            if (tier_dirs[tier] / filename).is_file():
                return tier
        return None

    merged: dict = {}
    profile_tiers = []
    for tier in reversed(TIERS):  # default, group, team -> higher overwrites
        pj = tier_dirs[tier] / "profile.json"
        if pj.is_file():
            merged = merge_profiles(merged, _read_json_object(pj))
            profile_tiers.append(tier)
    profile_tiers.reverse()  # highest first

    resolved_from: dict = {"kind": kind, "profile.json": profile_tiers}
    texts = {}
    wanted = [("style", "style.md")]
    if template_file:
        wanted.insert(0, ("template", template_file))
    for label, fname in wanted:
        tier = first_tier(fname)
        resolved_from[fname] = tier
        texts[label] = _read_text(tier_dirs[tier] / fname) if tier else None

    merged_kind = merged.get("kind")
    if merged_kind is not None and merged_kind != kind:
        raise ProfileResolutionError(
            f"profile.json kind mismatch: requested '{kind}', "
            f"merged profile declares '{merged_kind}'"
            if isinstance(merged_kind, str) and len(merged_kind) <= 32
            else f"profile.json kind mismatch: requested '{kind}', "
            "merged profile declares a different kind"
        )
    errors = validate_profile_config(merged)
    if errors:
        raise ReleaseConfigValidationError(errors)

    return {
        "profile": merged,
        "template": texts.get("template"),
        "style": texts.get("style"),
        "profileResolvedFrom": resolved_from,
    }
