#!/usr/bin/env python3
"""kb-port-fix — XACA-0463 migration helper.

Detect port collisions and null ports in ~/.aiteamforge/team-paths.json,
print a remediation report, and on user consent renumber non-conflict-winners
using compute_instance_port from aiteamforge_paths.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Import bootstrap: find aiteamforge_paths.py in kanban-hooks/.
# The script lives in homebrew-tap/libexec/commands/ when shipped; at dev time
# it lives under the worktree at the same path, but the canonical Python source
# is in kanban-hooks/ (mirrored to homebrew-tap/share/kanban-hooks/ for the
# tap). Try both locations so dev-time invocations work without installation.
# ---------------------------------------------------------------------------

def _find_kanban_hooks_dir() -> Path | None:
    """Locate the kanban-hooks directory containing aiteamforge_paths.py."""
    # __file__ may be:
    #   .../worktrees/xaca-0463/homebrew-tap/libexec/commands/kb-port-fix.py
    #   .../homebrew-tap/libexec/commands/kb-port-fix.py  (tap install)
    here = Path(__file__).resolve()

    # Walk up looking for kanban-hooks/ sibling of homebrew-tap/
    for ancestor in here.parents:
        candidate = ancestor / "kanban-hooks"
        if (candidate / "aiteamforge_paths.py").exists():
            return candidate
        # Tap install: share/kanban-hooks/ is inside homebrew-tap/
        candidate2 = ancestor / "share" / "kanban-hooks"
        if (candidate2 / "aiteamforge_paths.py").exists():
            return candidate2

    # Absolute fallback: dev-team canonical location
    dev_team = Path.home() / "dev-team" / "kanban-hooks"
    if (dev_team / "aiteamforge_paths.py").exists():
        return dev_team

    return None


_hooks_dir = _find_kanban_hooks_dir()
if _hooks_dir is None:
    print(
        "ERROR: Cannot find aiteamforge_paths.py. "
        "Ensure you are running from an aiteamforge worktree or installed tap.",
        file=sys.stderr,
    )
    sys.exit(1)

sys.path.insert(0, str(_hooks_dir))

try:
    from aiteamforge_paths import compute_instance_port, _resolve_template_band  # type: ignore[import]
except ImportError as exc:
    print(f"ERROR: Failed to import aiteamforge_paths: {exc}", file=sys.stderr)
    sys.exit(1)

# Parameterized templates whose BARE key (template == instance) violates the
# team-id contract. Import if available; fall back to a literal so an older
# aiteamforge_paths (pre-XACA-0643) doesn't break the import. (XACA-0643)
try:
    from aiteamforge_paths import _PARAMETERIZED_TEMPLATES  # type: ignore[import]
except ImportError:
    _PARAMETERIZED_TEMPLATES = frozenset({"finance", "legal", "medical", "freelance"})


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_CONFIG_PATH = Path.home() / ".aiteamforge" / "team-paths.json"
BACKUP_SUFFIX_PREFIX = ".bak-xaca0463-"


# ---------------------------------------------------------------------------
# Core helpers
# ---------------------------------------------------------------------------


def _split_template(instance_id: str) -> str:
    """Return the template id from an instance id (first dash-component)."""
    return instance_id.split("-")[0]


def _is_contract_violating_key(instance_id: str) -> bool:
    """True if *instance_id* is a bare parameterized-template id (contract violation).

    e.g. "medical" or "freelance" — these must be instance ids ("medical-general").
    kb-port-fix must NOT allocate ports to such keys; aiteamforge_paths scrubs
    them from team-paths.json on its next load. (XACA-0643)
    """
    return (
        instance_id in _PARAMETERIZED_TEMPLATES
        and _split_template(instance_id) == instance_id
    )


def _load_team_paths(config_path: Path) -> dict:
    """Load and return the parsed team-paths.json dict.

    A root value that isn't a JSON object (null, [], scalar) is normalized
    to {"teams": {}} — the caller treats that as "nothing to migrate".
    Likewise a present-but-non-object "teams" value is tolerated. Both are
    deliberate (XACA-0463-013, subitem 008 QA finding): tolerate externally
    authored malformed JSON rather than crash. XACA-0762-004 hardens this by
    making the tolerance LOUD (a WARNING on stderr) instead of silent, so a
    malformed config doesn't quietly present as "no teams configured" — this
    is the single load site, so the warning fires exactly once per invocation
    regardless of how many times downstream helpers re-derive the teams dict.

    Exit codes:
      3 — config file not found (XACA-0762-005: distinct from "1 == issues
          found" so callers like aiteamforge-start.sh's check_port_health()
          can tell "nothing to check" from "found something wrong" and
          degrade gracefully instead of aborting startup).
    """
    if not config_path.exists():
        print(f"ERROR: Config file not found: {config_path}", file=sys.stderr)
        sys.exit(3)
    with config_path.open() as f:
        data = json.load(f)
    if not isinstance(data, dict):
        print(
            f"WARNING: {config_path} does not contain a JSON object at its "
            f"root (found {type(data).__name__}) — treating as empty "
            f"(no teams configured).",
            file=sys.stderr,
        )
        return {"teams": {}}
    teams = data.get("teams")
    if teams is not None and not isinstance(teams, dict):
        print(
            f"WARNING: {config_path} has a non-object \"teams\" value "
            f"(found {type(teams).__name__}) — treating as empty "
            f"(no teams configured).",
            file=sys.stderr,
        )
    return data


def _safe_teams(data: dict) -> dict:
    """Return data["teams"] as a dict, defending against non-dict values.

    XACA-0463-013: a file authored externally may contain `"teams": null`
    or `"teams": []`; treat those as empty rather than crashing.
    """
    if not isinstance(data, dict):
        return {}
    teams = data.get("teams", {})
    return teams if isinstance(teams, dict) else {}


def _build_port_map(data: dict) -> dict[int, list[str]]:
    """Build a port -> [instance_ids] map from team-paths.json data.

    Only includes entries where lcars_port is a non-null integer.
    Tolerates non-dict root or non-dict ``teams`` value (XACA-0463-013).
    """
    port_map: dict[int, list[str]] = {}
    for instance_id, entry in _safe_teams(data).items():
        if not isinstance(entry, dict):
            continue
        if _is_contract_violating_key(instance_id):
            continue  # XACA-0643: never plan ports for bare-template keys
        port = entry.get("lcars_port")
        if port is not None:
            port = int(port)
            port_map.setdefault(port, []).append(instance_id)
    return port_map


def _collect_null_ports(data: dict) -> list[str]:
    """Return a list of instance_ids with lcars_port == null.

    XACA-0643: bare parameterized-template keys ("medical", "freelance") are
    skipped — they are contract violations and must not be allocated ports.
    """
    return [
        instance_id
        for instance_id, entry in _safe_teams(data).items()
        if isinstance(entry, dict)
        and entry.get("lcars_port") is None
        and not _is_contract_violating_key(instance_id)
    ]


def _sort_key_winner(instance_id: str, entry: dict) -> tuple[int, str, str]:
    """Sort key for winner selection.

    Sorting rules (ascending → first = winner):
    1. Entries WITH addedAt sort before entries WITHOUT (0 < 1).
    2. Among entries that have addedAt, earlier timestamp wins.
    3. Alphabetical instance_id as final tiebreaker.
    """
    added_at = entry.get("addedAt")
    if added_at:
        return (0, added_at, instance_id)
    else:
        return (1, "", instance_id)


def _build_plan(data: dict) -> dict:
    """Compute the full remediation plan without mutating data.

    Returns a dict with:
        "collisions": list of dicts, one per collision group
            {
                "port": int,
                "winner": str (instance_id),
                "renumber": list of str (instance_ids to renumber)
            }
        "null_ports": list of str (instance_ids needing allocation)
        "needs_work": bool

    Note: The actual new port for each renumbered/null entry is NOT computed
    here — it is computed at apply time using running state so each allocation
    sees prior allocations. detect-mode uses placeholder "?" for display.
    """
    port_map = _build_port_map(data)
    null_instances = _collect_null_ports(data)
    teams = _safe_teams(data)

    collision_groups: list[dict] = []
    for port, instances in sorted(port_map.items()):
        if len(instances) <= 1:
            continue
        # Sort to determine winner
        sorted_instances = sorted(
            instances,
            key=lambda iid: _sort_key_winner(iid, teams.get(iid, {})),
        )
        winner = sorted_instances[0]
        renumber = sorted_instances[1:]
        collision_groups.append({
            "port": port,
            "winner": winner,
            "renumber": renumber,
        })

    return {
        "collisions": collision_groups,
        "null_ports": null_instances,
        "needs_work": bool(collision_groups or null_instances),
    }


def _compute_plan_with_new_ports(data: dict) -> dict:
    """Like _build_plan but also computes proposed new ports.

    Allocates running-state: each renumbered entry is treated as
    already allocated before the next entry is computed. This ensures
    no two newly-renumbered entries get the same port.

    Returns same shape as _build_plan but each renumber entry is a
    dict {"instance_id": str, "new_port": int} and each null entry is
    {"instance_id": str, "new_port": int}.
    """
    plan = _build_plan(data)

    # Build a working copy of team-paths.json we mutate as we allocate.
    working_data: dict = json.loads(json.dumps(data))  # deep copy
    working_teams: dict = working_data.setdefault("teams", {})

    collisions_with_ports = []
    for group in plan["collisions"]:
        renumber_with_ports = []
        for iid in group["renumber"]:
            template = _split_template(iid)
            new_port = compute_instance_port(template, working_data)
            # Mark allocated so next call sees it as used
            working_teams[iid]["lcars_port"] = new_port
            renumber_with_ports.append({"instance_id": iid, "new_port": new_port})
        collisions_with_ports.append({
            "port": group["port"],
            "winner": group["winner"],
            "renumber": renumber_with_ports,
        })

    null_with_ports = []
    for iid in plan["null_ports"]:
        template = _split_template(iid)
        new_port = compute_instance_port(template, working_data)
        working_teams[iid]["lcars_port"] = new_port
        null_with_ports.append({"instance_id": iid, "new_port": new_port})

    return {
        "collisions": collisions_with_ports,
        "null_ports": null_with_ports,
        "needs_work": plan["needs_work"],
    }


# ---------------------------------------------------------------------------
# Report formatting
# ---------------------------------------------------------------------------


def _print_report(config_path: Path, plan: dict, include_new_ports: bool = False) -> None:
    """Print the human-readable detection / apply-preview report."""
    collision_count = sum(
        len(g["renumber"]) for g in plan["collisions"]
    )
    null_count = len(plan["null_ports"])
    total_changes = collision_count + null_count

    print()
    print("XACA-0463 LCARS Port Migration Report")
    print("=" * 38)
    print(f"File: {config_path}")
    print()

    if not plan["needs_work"]:
        print("No changes needed. All instances have unique, non-null lcars_port values.")
        print()
        return

    if plan["collisions"]:
        n_groups = len(plan["collisions"])
        print(f"Collisions ({n_groups} group(s)):")
        for group in plan["collisions"]:
            port = group["port"]
            winner = group["winner"]
            renumber = group["renumber"]
            total_in_group = 1 + len(renumber)
            print(f"  Port {port} — held by {total_in_group} instance(s):")
            print(f"    [WINNER]    {winner:<44}  (keep port {port})")
            for entry in renumber:
                if include_new_ports and isinstance(entry, dict):
                    iid = entry["instance_id"]
                    new_port = entry["new_port"]
                    print(f"    [RENUMBER]  {iid:<44}  -> {new_port}")
                else:
                    iid = entry if isinstance(entry, str) else entry["instance_id"]
                    print(f"    [RENUMBER]  {iid:<44}  (will be allocated)")
        print()

    if plan["null_ports"]:
        n_null = len(plan["null_ports"])
        print(f"Null ports ({n_null}):")
        for entry in plan["null_ports"]:
            if include_new_ports and isinstance(entry, dict):
                iid = entry["instance_id"]
                new_port = entry["new_port"]
                print(f"    [ALLOCATE]  {iid:<44}  -> {new_port}")
            else:
                iid = entry if isinstance(entry, str) else entry["instance_id"]
                print(f"    [ALLOCATE]  {iid:<44}  (will be allocated)")
        print()

    verb = "would be" if not include_new_ports else "will be"
    print(f"Summary: {total_changes} entry/entries {verb} renumbered, "
          f"{sum(1 for _ in plan['collisions'])} collision group(s) resolved.")
    if not include_new_ports:
        print("Run `aiteamforge-port-fix --apply` to make these changes.")
        print("Run `aiteamforge-port-fix --check` to use as a script gate (exit 0=clean, 1=issues, 3=config not found).")
    print()


def _print_json_report(config_path: Path, plan: dict) -> None:
    """Print machine-readable JSON report (--json mode)."""
    out = {
        "file": str(config_path),
        "needs_work": plan["needs_work"],
        "collisions": [
            {
                "port": g["port"],
                "winner": g["winner"],
                "renumber": (
                    [e if isinstance(e, str) else e for e in g["renumber"]]
                ),
            }
            for g in plan["collisions"]
        ],
        "null_ports": plan["null_ports"],
    }
    print(json.dumps(out, indent=2))


# ---------------------------------------------------------------------------
# Atomic write
# ---------------------------------------------------------------------------


def _atomic_write(data: dict, target: Path) -> None:
    """Write data as JSON to target atomically (tmp + os.replace)."""
    target_dir = str(target.parent)
    tmp_fd, tmp_path = tempfile.mkstemp(prefix="team-paths-", dir=target_dir)
    try:
        with os.fdopen(tmp_fd, "w") as f:
            json.dump(data, f, indent=2, sort_keys=False)
            f.write("\n")
        os.replace(tmp_path, str(target))
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------------------
# Check mode (script-usable gate — exits 0=clean, 1=issues, 3=config not found)
# ---------------------------------------------------------------------------


def cmd_check(args: argparse.Namespace) -> int:
    """Check mode: exit 0 if clean, exit 1 if any collisions or null ports found.

    Designed for use as a startup gate or CI check — outputs a concise summary
    and returns a standard exit code (0 = OK, 1 = issues found) rather than
    the detect-mode 2 (which signals "work available" rather than "error").

    Exit 3 (config file not found) is raised from _load_team_paths() before
    this function's own body runs — see that docstring. XACA-0762-005:
    kept distinct from 1 so a genuinely unconfigured install (no
    team-paths.json yet) is distinguishable from "found real issues" by
    callers such as aiteamforge-start.sh's check_port_health(), which must
    degrade gracefully (warn + continue) rather than abort startup when
    there is nothing to check yet.
    """
    config_path = Path(
        os.environ.get("AITEAMFORGE_CONFIG", str(DEFAULT_CONFIG_PATH))
    )

    data = _load_team_paths(config_path)
    plan = _build_plan(data)

    if plan["needs_work"]:
        collision_count = sum(len(g["renumber"]) for g in plan["collisions"])
        null_count = len(plan["null_ports"])
        print(
            f"ERROR: LCARS port issues detected in {config_path}: "
            f"{collision_count} collision(s), {null_count} null port(s). "
            f"Run `aiteamforge-port-fix --apply` to fix.",
            file=sys.stderr,
        )
        return 1

    return 0


# ---------------------------------------------------------------------------
# Detect mode
# ---------------------------------------------------------------------------


def cmd_detect(args: argparse.Namespace) -> int:
    """Default mode: report collisions and null ports, exit non-zero if work needed."""
    config_path = Path(
        os.environ.get("AITEAMFORGE_CONFIG", str(DEFAULT_CONFIG_PATH))
    )

    data = _load_team_paths(config_path)

    if args.json:
        plan = _build_plan(data)
        _print_json_report(config_path, plan)
        return 2 if plan["needs_work"] else 0

    plan = _build_plan(data)
    _print_report(config_path, plan, include_new_ports=False)
    return 2 if plan["needs_work"] else 0


# ---------------------------------------------------------------------------
# Apply mode
# ---------------------------------------------------------------------------


def cmd_apply(args: argparse.Namespace) -> int:
    """Apply mode: compute plan, confirm, backup, write."""
    config_path = Path(
        os.environ.get("AITEAMFORGE_CONFIG", str(DEFAULT_CONFIG_PATH))
    )

    data = _load_team_paths(config_path)

    # Compute full plan with actual new ports
    try:
        plan = _compute_plan_with_new_ports(data)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    if not plan["needs_work"]:
        print("No changes needed. All instances have unique, non-null lcars_port values.")
        return 0

    _print_report(config_path, plan, include_new_ports=True)

    # Confirmation
    if not args.yes:
        if not sys.stdin.isatty():
            print(
                "Non-interactive stdin detected. "
                "Pass --yes to apply without confirmation.",
                file=sys.stderr,
            )
            return 1
        answer = input("Apply these changes? [y/N] ").strip().lower()
        if answer not in ("y", "yes"):
            print("Aborted. No changes made.")
            return 0

    # Backup — XACA-0762-003: a read-only config parent dir (or any other
    # OSError, e.g. disk full, permission denied) must produce a single
    # actionable ERROR line, not a raw Python traceback. A failed backup
    # must NOT be followed by a write attempt.
    ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    backup_path = config_path.parent / (config_path.name + BACKUP_SUFFIX_PREFIX + ts)
    import shutil
    try:
        shutil.copy2(str(config_path), str(backup_path))
    except OSError as exc:
        print(
            f"ERROR: Failed to write backup to {backup_path}: {exc}",
            file=sys.stderr,
        )
        return 1
    print(f"Backup written: {backup_path}")

    # Apply changes to data in memory
    teams = data.setdefault("teams", {})

    for group in plan["collisions"]:
        for entry in group["renumber"]:
            iid = entry["instance_id"]
            new_port = entry["new_port"]
            teams[iid]["lcars_port"] = new_port

    for entry in plan["null_ports"]:
        iid = entry["instance_id"]
        new_port = entry["new_port"]
        teams[iid]["lcars_port"] = new_port

    # Atomic write — same OSError-to-single-line-ERROR treatment as the backup
    # above. _atomic_write() already cleans up its own tmp file on failure
    # (see its internal try/except); we only need to convert the re-raised
    # exception into an actionable message here.
    try:
        _atomic_write(data, config_path)
    except OSError as exc:
        print(
            f"ERROR: Failed to write {config_path}: {exc}",
            file=sys.stderr,
        )
        return 1

    total = sum(len(g["renumber"]) for g in plan["collisions"]) + len(plan["null_ports"])
    print(f"Done. {total} entry/entries updated in {config_path}")
    return 0


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="kb-port-fix",
        description=(
            "XACA-0463 — Detect and fix lcars_port collisions and null ports\n"
            "in ~/.aiteamforge/team-paths.json.\n\n"
            "Default (no args): print a report. Exit 0 if nothing to fix,\n"
            "exit 2 if changes are needed.\n\n"
            "--check: script-usable gate. Exit 0 if clean, exit 1 if issues\n"
            "  found, exit 3 if the config file does not exist. Suitable for\n"
            "  use in startup scripts and CI.\n\n"
            "--apply: show plan, ask for confirmation, backup, write. Exit 0\n"
            "  on success or nothing-to-do, exit 1 on a failed backup/write\n"
            "  or a refused non-interactive confirmation, exit 3 if the\n"
            "  config file does not exist.\n\n"
            "--json: machine-readable JSON report (detect mode only)."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--check",
        action="store_true",
        default=False,
        help=(
            "Script-usable gate: exit 0 if all ports are unique and non-null, "
            "exit 1 if any collision or null port is found, exit 3 if the "
            "config file does not exist. Suitable for startup scripts and CI."
        ),
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        default=False,
        help="Apply the remediation plan (requires confirmation unless --yes).",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        default=False,
        help="Skip interactive confirmation in --apply mode.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        default=False,
        help="Emit machine-readable JSON (detect mode only).",
    )
    return parser


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> int:
    parser = _build_parser()
    args = parser.parse_args()

    if args.check:
        return cmd_check(args)
    elif args.apply:
        return cmd_apply(args)
    else:
        return cmd_detect(args)


if __name__ == "__main__":
    sys.exit(main())
