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
    lcars_ports.py <team> [<team> ...]

Output (stdout): one ``team:port`` line per resolvable team, in argument order.
A team that is absent from the registry, or whose lcars_port is null, is
reported as a WARNING on stderr and omitted from stdout — callers never get a
bogus/empty port.

Exit codes:
    0  normal (including the "some teams skipped" case)
    1  aiteamforge_paths could not be imported (callers should treat as fatal)
    2  no team arguments given
"""
import sys
from pathlib import Path


def main(argv):
    teams = argv[1:]
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
        print(f"{team}:{port}")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
