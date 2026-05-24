#!/usr/bin/env python3
"""
aiteamforge-team-paths-wizard.py — Interactive wizard for ~/.aiteamforge/team-paths.json

XACA-0168-002 — Wave 2: Setup wizard for team working directory configuration

This wizard guides users through enabling/disabling teams and setting their
kanban/working directory paths.  It reads DEFAULT_TEAMS from the canonical
Python loader (aiteamforge_paths.py) and writes the result to
~/.aiteamforge/team-paths.json.

USAGE:
    python3 scripts/aiteamforge-team-paths-wizard.py [OPTIONS]

OPTIONS:
    --accept-defaults   Write DEFAULT_TEAMS as-is, no prompts
    --dry-run           Show what would be written without writing
    --config PATH       Override config path (also honoured via $AITEAMFORGE_CONFIG)
    --help / -h         Show this message

ENVIRONMENT:
    AITEAMFORGE_CONFIG  Override config file path (same as --config)

Design notes:
- Uses only input() — no curses, no external dependencies.
- Atomic write: writes to .tmp file then os.replace() to avoid partial writes.
- Creates a timestamped backup of any existing config before overwriting.
- JSON output: indent=2, keys sorted within each team block.
- Alias teams (mainevent, medical, freelance) are auto-included in accepted
  defaults but not shown as interactive choices (they mirror primary teams).
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Locate and import the canonical loader
# ---------------------------------------------------------------------------

def _load_aiteamforge_paths_module():
    """Import aiteamforge_paths from the sibling kanban-hooks/ directory."""
    script_dir = Path(__file__).resolve().parent
    # scripts/ is a sibling of kanban-hooks/
    candidates = [
        script_dir.parent / "kanban-hooks" / "aiteamforge_paths.py",
        script_dir / "aiteamforge_paths.py",  # fallback: same dir
    ]
    for candidate in candidates:
        if candidate.exists():
            spec = importlib.util.spec_from_file_location(
                "aiteamforge_paths", candidate
            )
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    print(
        "ERROR: Cannot find aiteamforge_paths.py.\n"
        "Expected it at: kanban-hooks/aiteamforge_paths.py (relative to dev-team root).",
        file=sys.stderr,
    )
    sys.exit(1)


# ---------------------------------------------------------------------------
# Alias teams — included in config output but skipped in interactive prompts
# ---------------------------------------------------------------------------

# These teams mirror primary teams and are auto-included unchanged.
ALIAS_TEAMS = {"mainevent", "medical", "freelance"}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _config_path(override: str = "") -> Path:
    """Return the config file path, honouring env var and CLI override."""
    if override:
        return Path(override).expanduser()
    env_override = os.environ.get("AITEAMFORGE_CONFIG", "")
    if env_override:
        return Path(env_override).expanduser()
    return Path.home() / ".aiteamforge" / "team-paths.json"


def _path_status(path_str: str) -> str:
    """Return a short status tag for a path."""
    p = Path(path_str).expanduser()
    return "found" if p.exists() else "NOT FOUND"


def _prompt(msg: str, default: str = "") -> str:
    """Prompt the user with a default, return the entered value or default."""
    if default:
        display = f"{msg} [{default}]: "
    else:
        display = f"{msg}: "
    try:
        answer = input(display).strip()
    except (EOFError, KeyboardInterrupt):
        print()
        return default
    return answer if answer else default


def _prompt_yes_no(msg: str, default_yes: bool = True) -> bool:
    """Prompt [Y/n] or [y/N].  Returns bool."""
    hint = "[Y/n]" if default_yes else "[y/N]"
    try:
        answer = input(f"{msg} {hint}: ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return default_yes
    if not answer:
        return default_yes
    return answer.startswith("y")


def _separator(char: str = "-", width: int = 70) -> None:
    print(char * width)


# ---------------------------------------------------------------------------
# Port-collision auto-fix (XACA-0557)
# ---------------------------------------------------------------------------

# kb-port-fix resolution + invocation live in the shared portfix_runner module
# (kanban-hooks/) so the brew/dev path layout is defined in exactly one place,
# shared with kb-team-import (XACA-0557, PR #472 review consolidation).
_PORTFIX_MOD = None


def _load_portfix_runner():
    """Import portfix_runner from the sibling kanban-hooks/ directory (cached)."""
    global _PORTFIX_MOD
    if _PORTFIX_MOD is not None:
        return _PORTFIX_MOD
    script_dir = Path(__file__).resolve().parent
    # scripts/ is a sibling of kanban-hooks/ (same in dev tree and tap share/).
    candidates = [
        script_dir.parent / "kanban-hooks" / "portfix_runner.py",
        script_dir / "portfix_runner.py",  # fallback: same dir
    ]
    for candidate in candidates:
        if candidate.exists():
            spec = importlib.util.spec_from_file_location("portfix_runner", candidate)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            _PORTFIX_MOD = mod
            return mod
    print(
        "ERROR: Cannot find portfix_runner.py.\n"
        "Expected it at: kanban-hooks/portfix_runner.py (relative to dev-team root).",
        file=sys.stderr,
    )
    sys.exit(1)


def _resolve_kb_port_fix() -> Path | None:
    """Locate kb-port-fix.py (delegates to the shared portfix_runner module)."""
    return _load_portfix_runner().resolve_kb_port_fix()


def _run_port_collision_fix(config_path: Path) -> None:
    """Detect and auto-fix lcars_port collisions in the written config.

    Thin wrapper around ``portfix_runner.run_port_collision_fix`` (the single
    shared implementation) with the wizard's section separators. Non-fatal: a
    leftover collision is caught again by the LCARS startup guard at boot.
    """
    _separator()
    _load_portfix_runner().run_port_collision_fix(config_path)
    _separator()


def _print_summary_table(teams_dict: dict) -> None:
    """Print a formatted summary table of teams that will be written."""
    _separator("=")
    print("  SUMMARY — teams to be written")
    _separator("=")
    primary = {k: v for k, v in teams_dict.items() if k not in ALIAS_TEAMS}
    alias = {k: v for k, v in teams_dict.items() if k in ALIAS_TEAMS}

    for team_id in sorted(primary.keys()):
        entry = primary[team_id]
        port = entry.get("lcars_port")
        port_str = f"  LCARS:{port}" if port else ""
        wd = entry["working_dir"]
        status = _path_status(wd)
        print(f"  {team_id}")
        print(f"    working_dir: {wd}  [{status}]{port_str}")
        print(f"    kanban_dir:  {entry['kanban_dir']}")

    if alias:
        print()
        print("  Alias teams (auto-included, not configurable):")
        for team_id in sorted(alias.keys()):
            print(f"    {team_id}")

    _separator("=")


# ---------------------------------------------------------------------------
# Atomic write helpers
# ---------------------------------------------------------------------------

def _backup_existing(config_path: Path) -> None:
    """Create a timestamped backup of the existing config if it exists."""
    if not config_path.exists():
        return
    ts = int(time.time())
    backup_path = config_path.parent / f"{config_path.name}.bak.{ts}"
    try:
        backup_path.write_bytes(config_path.read_bytes())
        print(f"Backup written: {backup_path}")
    except OSError as exc:
        print(f"WARNING: Could not create backup: {exc}", file=sys.stderr)


def _atomic_write(config_path: Path, data: dict) -> bool:
    """Write data as JSON to config_path atomically via a .tmp file."""
    tmp_path = config_path.parent / (config_path.name + ".tmp")
    try:
        config_path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path.write_text(
            json.dumps(data, indent=2, sort_keys=False) + "\n",
            encoding="utf-8",
        )
        os.replace(tmp_path, config_path)
        return True
    except OSError as exc:
        print(f"ERROR: Could not write config: {exc}", file=sys.stderr)
        # Clean up tmp if it exists
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass
        return False


# ---------------------------------------------------------------------------
# Non-interactive mode (--accept-defaults)
# ---------------------------------------------------------------------------

def run_accept_defaults(
    default_teams: dict,
    config_path: Path,
    dry_run: bool,
    schema_version: int,
) -> int:
    """Write DEFAULT_TEAMS as-is without any prompts.  Returns exit code."""
    config = {"schema_version": schema_version, "teams": default_teams}

    if dry_run:
        print(f"[DRY RUN] Would write to: {config_path}")
        _separator()
        # Show first 5 teams for brevity
        preview_teams = dict(list(default_teams.items())[:5])
        preview = {"schema_version": schema_version, "teams": preview_teams}
        print(json.dumps(preview, indent=2))
        remaining = len(default_teams) - 5
        if remaining > 0:
            print(f"  ... and {remaining} more teams")
        return 0

    if config_path.exists():
        _backup_existing(config_path)

    success = _atomic_write(config_path, config)
    if success:
        print(f"Written: {config_path}")
        print(f"Teams:   {len(default_teams)}")
        if not dry_run:
            _run_port_collision_fix(config_path)
    return 0 if success else 1


# ---------------------------------------------------------------------------
# Interactive wizard
# ---------------------------------------------------------------------------

def run_interactive(
    default_teams: dict,
    config_path: Path,
    dry_run: bool,
    schema_version: int,
) -> int:
    """Run the interactive team-paths wizard.  Returns exit code."""
    # ── Check for existing config ─────────────────────────────────────────
    if config_path.exists() and not dry_run:
        print(f"\nConfig already exists: {config_path}")
        reconfigure = _prompt_yes_no("Reconfigure?", default_yes=False)
        if not reconfigure:
            print("No changes made.")
            return 0

    print()
    _separator("=")
    print("  AITeamForge — Team Paths Setup Wizard")
    _separator("=")
    print()
    print("For each team you can:")
    print("  - Enable or skip the team")
    print("  - Accept the default paths or supply custom ones")
    print("  - Accept the default LCARS port or supply a custom one")
    print()
    print("Press Enter to accept the shown default.")
    _separator()
    print()

    # ── Separate primary teams from aliases ───────────────────────────────
    primary_teams = {k: v for k, v in default_teams.items() if k not in ALIAS_TEAMS}
    alias_teams   = {k: v for k, v in default_teams.items() if k in ALIAS_TEAMS}

    configured_teams: dict[str, dict[str, Any]] = {}

    for team_id in sorted(primary_teams.keys()):
        defaults = primary_teams[team_id]
        default_wd = defaults["working_dir"]
        default_kd = defaults["kanban_dir"]
        default_port = defaults.get("lcars_port")

        wd_status = _path_status(default_wd)
        wd_tag = "found" if wd_status == "found" else "NOT FOUND"

        print(f"Team: {team_id}")
        enabled = _prompt_yes_no(f"  Enable '{team_id}'?", default_yes=True)
        if not enabled:
            print(f"  Skipping {team_id}.")
            print()
            continue

        # ── Working directory ──────────────────────────────────────────────
        print(f"  Default working_dir: {default_wd}  [{wd_tag}]")
        working_dir = _prompt("  Working dir", default_wd)

        # Validate the entered path (warn but allow)
        working_dir_path = Path(working_dir).expanduser()
        if not working_dir_path.exists():
            print(f"  WARNING: '{working_dir}' does not exist on disk.")
            if not _prompt_yes_no("  Use this path anyway?", default_yes=True):
                working_dir = _prompt("  Working dir (try again)", default_wd)

        # kanban_dir is always working_dir/kanban — ask if they want to override
        inferred_kanban = str(Path(working_dir).expanduser() / "kanban")
        if inferred_kanban != default_kd:
            # Their custom working_dir changes the inferred kanban path
            print(f"  Inferred kanban_dir: {inferred_kanban}")
            kanban_dir = _prompt("  Kanban dir", inferred_kanban)
        else:
            print(f"  Kanban dir: {default_kd} (inferred from working_dir)")
            override_kanban = _prompt_yes_no(
                "  Override kanban_dir?", default_yes=False
            )
            if override_kanban:
                kanban_dir = _prompt("  Kanban dir", default_kd)
            else:
                kanban_dir = default_kd

        # ── LCARS port ─────────────────────────────────────────────────────
        if default_port is not None:
            print(f"  LCARS port: {default_port}")
            override_port = _prompt_yes_no("  Override LCARS port?", default_yes=False)
            if override_port:
                port_str = _prompt("  LCARS port", str(default_port))
                try:
                    lcars_port: int | None = int(port_str)
                except ValueError:
                    print(f"  Invalid port '{port_str}' — keeping default {default_port}")
                    lcars_port = default_port
            else:
                lcars_port = default_port
        else:
            lcars_port = None

        configured_teams[team_id] = {
            "kanban_dir": kanban_dir,
            "working_dir": working_dir,
            "lcars_port": lcars_port,
        }
        print()

    # ── Always include alias teams unchanged ──────────────────────────────
    for team_id, entry in alias_teams.items():
        configured_teams[team_id] = entry

    if not configured_teams:
        print("No teams configured.  Nothing to write.")
        return 0

    # ── Summary ────────────────────────────────────────────────────────────
    print()
    _print_summary_table(configured_teams)
    print()

    if dry_run:
        print("[DRY RUN] Would write the above config to:")
        print(f"  {config_path}")
        return 0

    # ── Confirm write ──────────────────────────────────────────────────────
    confirm = _prompt_yes_no(
        f"Write to {config_path}?", default_yes=True
    )
    if not confirm:
        print("Cancelled.  No changes made.")
        return 0

    if config_path.exists():
        _backup_existing(config_path)

    config = {"schema_version": schema_version, "teams": configured_teams}
    success = _atomic_write(config_path, config)
    if success:
        print(f"\nWritten: {config_path}")
        print(f"Teams configured: {len(configured_teams)}")
        _run_port_collision_fix(config_path)
    return 0 if success else 1


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]

    accept_defaults = False
    dry_run = False
    config_override = ""

    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("--accept-defaults",):
            accept_defaults = True
        elif arg in ("--dry-run",):
            dry_run = True
        elif arg in ("--config",):
            i += 1
            if i >= len(argv):
                print("ERROR: --config requires a path argument", file=sys.stderr)
                return 1
            config_override = argv[i]
        elif arg in ("--help", "-h"):
            # Print the module docstring as help
            doc = __doc__ or ""
            # Trim leading/trailing blank lines
            lines = doc.strip().splitlines()
            for line in lines:
                print(line)
            return 0
        else:
            print(f"Unknown option: {arg}", file=sys.stderr)
            print("Run with --help for usage.", file=sys.stderr)
            return 1
        i += 1

    mod = _load_aiteamforge_paths_module()
    default_teams: dict = mod.DEFAULT_TEAMS
    schema_version: int = mod.SUPPORTED_SCHEMA_VERSION
    config_path = _config_path(config_override)

    if accept_defaults:
        return run_accept_defaults(
            default_teams, config_path, dry_run, schema_version
        )
    else:
        return run_interactive(
            default_teams, config_path, dry_run, schema_version
        )


if __name__ == "__main__":
    sys.exit(main())
