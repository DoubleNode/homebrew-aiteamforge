"""cr_exclusions.py -- the ONE reader of ``teamConfig.migration.excludeCrIds`` for the XACA-1662 status page.

Spec RELEASE-LIFECYCLE.md 15.1: a CR listed there "never has a cr-record backfilled" and "finishes on its
current path". scripts/migrate-cr-legacy-state.py (XACA-1348-006) is the original reader; it is a standalone
hyphen-named CLI that cannot be imported from kanban-hooks, so this module carries the SAME rule and
tests/test_xaca1662_exclude_cr_ids.py pins the two together on a shape matrix so they cannot drift.

Rule: board["teamConfig"]["migration"]["excludeCrIds"] is a list of CR id strings. Absent / null / [] means
"exclude nothing". Any other shape is a ConfigError (fail closed -- never guess which CRs are excluded).
"""
from __future__ import annotations

from typing import Any, Dict, List


class ConfigError(ValueError):
    pass


def configured_excludes(board: Any) -> List[str]:
    cfg = board.get("teamConfig") if isinstance(board, dict) else None
    if cfg is None:
        return []
    if not isinstance(cfg, dict):
        raise ConfigError("teamConfig is not an object")
    mig = cfg.get("migration")
    if mig is None:
        return []
    if not isinstance(mig, dict):
        raise ConfigError("teamConfig.migration is not an object")
    ids = mig.get("excludeCrIds")
    if ids is None:
        return []
    if not isinstance(ids, list) or not all(isinstance(x, str) for x in ids):
        raise ConfigError("teamConfig.migration.excludeCrIds must be a list of strings")
    return list(ids)


def excluded_set(board: Dict[str, Any]) -> frozenset:
    return frozenset(configured_excludes(board))


def is_excluded(board: Dict[str, Any], cr_id: Any) -> bool:
    return isinstance(cr_id, str) and cr_id in excluded_set(board)
