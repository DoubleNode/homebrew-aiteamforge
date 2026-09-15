#!/usr/bin/env python3
"""Report this host's LCARS-supervision roster from team-paths.json, read-only.

Single source of "which teams does this host's registry currently list" for
lcars-health-check.sh (XACA-1223). Calls aiteamforge_paths.peek_config()
exactly once and prints its result — nothing more. This module performs NO
self-heal of its own and must never be able to: it exists precisely so a
300s-cadence LaunchAgent tick can learn the roster without risking the
reseed/quarantine side effects load_config() can trigger (XACA-1192 Decision
(d); see peek_config()'s own docstring for the full read-path-never-mutates
contract).

aiteamforge_paths lives in this same directory (kanban-hooks/), so the import
works in both the dev tree and the shipped tap layout (share/kanban-hooks/).

THIS MODULE MUST NEVER IMPORT load_config, read_config_view, OR ANY OTHER
aiteamforge_paths ACCESSOR — peek_config() ONLY. `lcars_ports.py` is the
designated self-heal owner (XACA-1193-001 Decision A) and must keep calling
load_config() on every tick; this helper answers a DIFFERENT question ("what
does the registry currently say, without touching it") and giving it
write-capable machinery would blur that split. A static guard
(tests/test_xaca1223_supervision_rows.py, in the XACA-1193-006 style) fails
the build if this file's source ever references load_config, read_config_view,
or passes config=.

Usage:
    lcars_host_roster.py

Output (stdout):
    status=<ok|invalid|unreadable|missing|quarantined>   (ConfigPeek.status, verbatim)
    path=<resolved config path>                           (ConfigPeek.path, verbatim)
    team=<id>                                              (one line per team, status=="ok" only)

`team=` lines are emitted only when status is "ok" and the parsed config's
"teams" value is itself a dict — mirroring config_is_structurally_valid()'s
own shape requirement (peek_config() only ever returns "ok" for a
structurally-valid config, so this can't actually fail in practice; the
isinstance checks are defense-in-depth, not a believed-reachable branch). A
non-string team key is skipped — a team id is always a string, so a
non-string key is not a team this host can supervise.

Output (stderr): whatever peek_config() itself emits — its own
once-per-process diagnostics (WARNING for "invalid", CRITICAL for
"unreadable"/"quarantined"). This module adds no diagnostics of its own.

Exit codes:
    0  a status was produced (including every non-"ok" status — the caller
       reads `status=` to decide what that means; a non-"ok" status is not
       a failure of THIS script)
    1  aiteamforge_paths could not be imported (callers should treat as
       fatal — the same convention lcars_ports.py uses)
"""
import sys
from pathlib import Path


def main(argv):
    # aiteamforge_paths is a sibling module in this directory.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    try:
        from aiteamforge_paths import peek_config
    except ImportError as e:
        print(f"ERROR: cannot import aiteamforge_paths: {e}", file=sys.stderr)
        return 1

    peek = peek_config()

    print(f"status={peek.status}")
    print(f"path={peek.path}")

    if peek.status == "ok" and isinstance(peek.config, dict):
        teams = peek.config.get("teams")
        if isinstance(teams, dict):
            for team_id in teams:
                if isinstance(team_id, str):
                    print(f"team={team_id}")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
