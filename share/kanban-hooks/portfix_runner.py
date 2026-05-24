#!/usr/bin/env python3
"""Single source of truth for locating and running kb-port-fix.py (XACA-0557).

Both the team-paths wizard (Python) and ``kb-team-import`` (shell) need to
auto-fix lcars_port collisions after writing config. Before this module each
carried its own copy of the "dev-tree path → brew-installed fallback" resolver
plus the ``--apply --yes`` invocation, so a change to the brew path layout had
to be made in two languages (XACA-0557 review nit, PR #472).

This module is the *one* place that knows where kb-port-fix.py lives and how to
invoke it non-interactively:

  * ``resolve_kb_port_fix()`` — dev-tree first, then ``brew --prefix`` fallback.
  * ``run_port_collision_fix(config_path)`` — run ``--apply --yes`` against the
    given config, surface the output, and return the underlying exit code.
    Never raises and never exits the host process; collisions left unresolved
    are caught again by the LCARS startup guard (XACA-0463).

It is also runnable as a CLI for shell callers::

    python3 <repo>/kanban-hooks/portfix_runner.py /path/to/team-paths.json

The CLI is intentionally non-fatal (exits 0 even when kb-port-fix reports an
issue) so it can be dropped into an import flow without aborting it; the printed
summary tells the operator what happened.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

# Resolution order is the same one used by the kb-port-fix() shell function in
# kanban-helpers.sh, so behaviour is identical in a dev worktree and on an
# end-user (brew-installed) machine.
_DEV_RELATIVE = ("dev-team", "homebrew-tap", "libexec", "commands", "kb-port-fix.py")
_BREW_RELATIVE = ("opt", "aiteamforge", "libexec", "libexec", "commands", "kb-port-fix.py")


def resolve_kb_port_fix() -> Path | None:
    """Locate kb-port-fix.py — dev-tree path first, then brew-installed fallback.

    Returns ``None`` when the script cannot be found (no AITeamForge install and
    no dev checkout). ``Path.home()`` is read at call time so tests can patch it.
    """
    dev_path = Path.home().joinpath(*_DEV_RELATIVE)
    if dev_path.exists():
        return dev_path

    # Brew-installed fallback.
    try:
        brew_prefix = subprocess.run(
            ["brew", "--prefix"],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
        if brew_prefix:
            brew_path = Path(brew_prefix).joinpath(*_BREW_RELATIVE)
            if brew_path.exists():
                return brew_path
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass  # brew not on PATH or timed out — skip fallback silently

    return None


def run_port_collision_fix(config_path: Path | str | None = None) -> int:
    """Detect and auto-fix lcars_port collisions in the written config.

    Invokes ``kb-port-fix.py --apply --yes`` (non-interactive), prints the
    tool's combined output so the operator sees exactly what changed, and
    returns the tool's exit code. When ``config_path`` is given it is passed via
    ``AITEAMFORGE_CONFIG``; when ``None`` the tool targets its default config
    (``~/.aiteamforge/team-paths.json`` or the inherited ``$AITEAMFORGE_CONFIG``).

    Never raises and never calls ``sys.exit``. If kb-port-fix.py cannot be
    located the function warns and returns ``0`` — the config has already been
    written and any collision is caught again at LCARS boot time.
    """
    print("Checking for LCARS port collisions …")

    kbfix = resolve_kb_port_fix()
    if kbfix is None:
        print(
            "WARNING: kb-port-fix.py not found — cannot auto-fix port collisions.\n"
            "Run `kb-port-fix --apply` manually after ensuring AITeamForge is installed.",
            file=sys.stderr,
        )
        return 0

    env = dict(os.environ)
    if config_path is not None:
        env["AITEAMFORGE_CONFIG"] = str(Path(config_path))
    try:
        result = subprocess.run(
            [sys.executable, str(kbfix), "--apply", "--yes"],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(
            f"WARNING: kb-port-fix invocation failed: {exc}\n"
            "Run `kb-port-fix --apply` manually to resolve any collisions.",
            file=sys.stderr,
        )
        return 0

    combined = (result.stdout + result.stderr).strip()
    if combined:
        print(combined)

    if result.returncode == 0:
        print("Port collision check: OK")
    else:
        print(
            f"WARNING: kb-port-fix exited {result.returncode} — review the output above.",
            file=sys.stderr,
        )
    return result.returncode


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint for shell callers. Always exits 0 (non-fatal contract).

    Usage: ``portfix_runner.py [team-paths.json]`` — with no argument the
    default config is targeted.
    """
    argv = list(sys.argv[1:] if argv is None else argv)
    run_port_collision_fix(argv[0] if argv else None)
    # Non-fatal: a leftover collision is surfaced in the output above and caught
    # again at LCARS boot; do not abort the host import/setup flow.
    return 0


if __name__ == "__main__":
    sys.exit(main())
