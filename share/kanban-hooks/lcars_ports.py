#!/usr/bin/env python3
"""Resolve LCARS lcars_port for one or more teams from the canonical source.

Single source of the port-derivation logic shared by lcars-health-check.sh and
lcars-ui/lcars-smoke-test.sh (XACA-0561-008). Both scripts previously embedded an
identical inline ``python3 -c`` heredoc; duplicating the very thing this ticket
exists to eliminate was asking for future drift. They now both shell out here.

Resolution precedence (matches kb-port-reconcile's authority model):
  1. live ~/.aiteamforge/team-paths.json overlay  (authoritative)
  2. aiteamforge_paths.DEFAULT_TEAMS               (registry fallback)

aiteamforge_paths lives in this same directory (kanban-hooks/), so the import
works in both the dev tree and the shipped tap layout (share/kanban-hooks/).

Usage:
    lcars_ports.py [--with-primary-host] <team> [<team> ...]

Output (stdout), default mode: one ``team:port`` line per resolvable team, in
argument order. This is UNCHANGED from the pre-XACA-1063 format — existing
callers (lcars-ui/lcars-smoke-test.sh) parse exactly two ``:``-delimited
fields and must never see a third one appear underneath them.

Output (stdout), ``--with-primary-host`` mode (XACA-1063-002): one
``team:port:primary_host_field`` line per resolvable team. ``primary_host_field``
is one of:
  - ``-``    the team's config entry has no ``primary_host`` key at all (ABSENT
             — the normal, expected state for most teams; XACA-0802 §
             "ABSENT means 'no declared host'").
  - ``""``   (nothing between the last two colons) the key IS present but its
             value is empty-string or JSON ``null`` — a malformed/corrupted
             write, distinct from ABSENT (see aiteamforge_paths.py's
             ``primary_host`` field contract).
  - <host>   the declared owning host, verbatim, for the caller to compare
             (case-insensitively, ``.local``-stripped) against its own
             identity. This module does NOT perform that comparison — see
             lcars-health-check.sh's ported `_kb_host_matches`-equivalent —
             doing it here would be a second, Python-side reimplementation of
             the same comparison mechanics that already live in
             kanban-helpers.sh, which is exactly the sibling-heuristic drift
             this codebase is trying to stop accumulating.

This flag is opt-in and purely additive: it must be passed explicitly as the
FIRST argument. Called without it (the historical calling convention), output
is byte-identical to before this change.

Reading `primary_host` from the SAME `load_config()`/`DEFAULT_TEAMS` snapshot
already used for port resolution (rather than a second registry read) is
deliberate — XACA-1063-001 § 4.2 note 3 rules that ownership and port
resolution must not be resolvable independently, since two reads of a
transiently-corrupt registry could disagree with each other mid-sweep.

Exit codes:
    0  normal (including the "some teams skipped" case)
    1  aiteamforge_paths could not be imported (callers should treat as fatal)
    2  no team arguments given
"""
import sys
from pathlib import Path

# Sentinel for "no primary_host key at all" (ABSENT) — see module docstring.
# Not a valid hostname shape, so it can't collide with a real declared host.
_ABSENT_SENTINEL = "-"


def _resolve_primary_host_field(entry: dict) -> str:
    """Return the primary_host stdout field for one resolved team entry.

    ABSENT (key missing) -> "-"; present-but-empty/null -> ""; else the value
    verbatim. See module docstring for why these three states must stay
    distinguishable on the wire.
    """
    if "primary_host" not in entry:
        return _ABSENT_SENTINEL
    host = entry.get("primary_host")
    if host is None or host == "":
        return ""
    return str(host)


def main(argv):
    args = argv[1:]

    with_primary_host = False
    if args and args[0] == "--with-primary-host":
        with_primary_host = True
        args = args[1:]

    teams = args
    if not teams:
        print("ERROR: no team names given", file=sys.stderr)
        return 2

    # aiteamforge_paths is a sibling module in this directory.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    try:
        from aiteamforge_paths import DEFAULT_TEAMS, load_config
    except ImportError as e:
        print(f"ERROR: cannot import aiteamforge_paths: {e}", file=sys.stderr)
        return 1

    try:
        live = load_config().get("teams", {})
    except Exception:
        live = {}

    for team in teams:
        entry = live.get(team) or DEFAULT_TEAMS.get(team)
        if entry is None:
            print(f"WARNING: team '{team}' not in aiteamforge_paths — skipping",
                  file=sys.stderr)
            continue
        port = entry.get("lcars_port")
        if port is None:
            print(f"WARNING: team '{team}' lcars_port is None — skipping",
                  file=sys.stderr)
            continue
        if with_primary_host:
            print(f"{team}:{port}:{_resolve_primary_host_field(entry)}")
        else:
            print(f"{team}:{port}")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
