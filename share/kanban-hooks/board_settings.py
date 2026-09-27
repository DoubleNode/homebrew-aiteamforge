#!/usr/bin/env python3
"""
board_settings.py — per-team board start-gate settings: CLI + accessor re-exports.

XACA-1083-001 — Config schema + loader, fail-closed.

Design
------
Mirrors the XACA-0619 TimePad sibling split: config loading/validation/caching/
the fail-closed accessors/the atomic setter all live in aiteamforge_paths.py
(sibling loader, shared by every consumer that already imports that module).
This module is the thin, dependency-light entry point a SHELL caller can
invoke cheaply without importing the (large) aiteamforge_paths module tree
directly, and it re-exports the accessor API for Python callers that want one
import point (kanban-helpers.sh's future resolvers, lcars-ui/server.py's
toggle endpoint — XACA-1083-002/003/004).

Config file: kanban-hooks/board_settings.json  (committed schema; runtime
             copy at ~/.aiteamforge/board_settings.json — not committed to git)
Schema doc:  docs/BOARD_SETTINGS.md
Plan doc:    kanban/XACA-1083_require_epic_release_settings.md

CLI contract
------------
    python3 board_settings.py get <team>
        Resolves both gate booleans, the grandfather cutoff, and the
        creation-timestamp field name for <team>, and prints them as stable
        `key=value` lines (one per line, booleans as the literal strings
        "true"/"false", stdout only — nothing else is written to stdout).
        Always resolves (fail-closed never raises); exit 0 on success.
        A missing <team> argument is an argparse usage error (exit 2).

        Example:
            $ python3 board_settings.py get academy
            team=academy
            requireEpicOnStart=true
            requireReleaseOnStart=true
            grandfatherCutoff=2026-09-25T00:00:00Z
            creationTimestampField=addedAt

    python3 board_settings.py set <team> [--require-epic true|false]
                                          [--require-release true|false]
        Writes one or both booleans for <team> to the RUNTIME copy
        (~/.aiteamforge/board_settings.json, or $AITEAMFORGE_BOARD_SETTINGS_CONFIG
        when set) via an atomic temp-file + os.replace write. Never touches the
        committed kanban-hooks/board_settings.json source.

        Exit 0 and prints "OK team=<team>" on success.
        Exit 1 on any write failure (I/O error, plausibility-floor refusal) —
        a failed write is NEVER reported as success.
        Exit 2 on a usage error (neither flag given, or a flag value that
        isn't recognizably true/false) — nothing is written in this case.

Both subcommands are safe to call from a shell hot path: neither subcommand
ever raises an uncaught exception (every failure is caught and turned into a
non-zero exit code with a message on stderr), and `get` never touches disk
for writing.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Allow `python3 board_settings.py ...` direct invocation (not just `import`)
# without requiring the caller to have kanban-hooks/ on PYTHONPATH already.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from aiteamforge_paths import (  # noqa: E402
    bust_board_settings_cache,
    get_board_settings_creation_timestamp_field,
    get_board_settings_grandfather_cutoff,
    is_epic_required_for_team,
    is_item_grandfathered,
    is_release_required_for_team,
    load_board_settings,
    set_board_settings_for_team,
)

__all__ = [
    "bust_board_settings_cache",
    "get_board_settings_creation_timestamp_field",
    "get_board_settings_grandfather_cutoff",
    "is_epic_required_for_team",
    "is_item_grandfathered",
    "is_release_required_for_team",
    "load_board_settings",
    "set_board_settings_for_team",
]


def _bool_str(value: bool) -> str:
    return "true" if value else "false"


def _parse_bool_flag(raw: str) -> bool | None:
    """Parse a CLI --require-* value. Returns None (never raises) if *raw*
    is not a recognized true/false spelling — the caller reports the usage
    error."""
    v = raw.strip().lower()
    if v in ("true", "1", "yes", "on"):
        return True
    if v in ("false", "0", "no", "off"):
        return False
    return None


def _cmd_get(args: argparse.Namespace) -> int:
    team = args.team
    require_epic = is_epic_required_for_team(team)
    require_release = is_release_required_for_team(team)
    cutoff = get_board_settings_grandfather_cutoff() or ""
    field = get_board_settings_creation_timestamp_field()

    print(f"team={team}")
    print(f"requireEpicOnStart={_bool_str(require_epic)}")
    print(f"requireReleaseOnStart={_bool_str(require_release)}")
    print(f"grandfatherCutoff={cutoff}")
    print(f"creationTimestampField={field}")
    return 0


def _cmd_set(args: argparse.Namespace) -> int:
    require_epic: bool | None = None
    require_release: bool | None = None

    if args.require_epic is not None:
        require_epic = _parse_bool_flag(args.require_epic)
        if require_epic is None:
            print(
                f"error: --require-epic must be true/false, got {args.require_epic!r}",
                file=sys.stderr,
            )
            return 2

    if args.require_release is not None:
        require_release = _parse_bool_flag(args.require_release)
        if require_release is None:
            print(
                f"error: --require-release must be true/false, got "
                f"{args.require_release!r}",
                file=sys.stderr,
            )
            return 2

    if require_epic is None and require_release is None:
        print(
            "error: 'set' requires at least one of --require-epic / --require-release",
            file=sys.stderr,
        )
        return 2

    ok = set_board_settings_for_team(
        args.team,
        require_epic_on_start=require_epic,
        require_release_on_start=require_release,
    )
    if not ok:
        print(
            f"error: failed to write board settings for team {args.team!r} "
            "(see prior stderr line for the reason) — nothing was changed on disk",
            file=sys.stderr,
        )
        return 1

    print(f"OK team={args.team}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="board_settings.py",
        description=(
            "Per-team board start-gate settings (requireEpicOnStart / "
            "requireReleaseOnStart) — XACA-1083"
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_get = sub.add_parser(
        "get", help="Resolve a team's gate settings (fail-closed; never fails)"
    )
    p_get.add_argument("team", help="Team slug, e.g. academy")
    p_get.set_defaults(func=_cmd_get)

    p_set = sub.add_parser(
        "set",
        help="Set one or both booleans for a team (runtime copy, atomic write)",
    )
    p_set.add_argument("team", help="Team slug, e.g. academy")
    p_set.add_argument("--require-epic", help="true|false")
    p_set.add_argument("--require-release", help="true|false")
    p_set.set_defaults(func=_cmd_set)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
