#!/usr/bin/env python3
"""Prepend or strip the Claude Code "C " prefix on the iTerm2 tab that hosts
the caller's current shell.

Design (XACA-0214 round-3 after discovering stale ITERM_SESSION_ID in tmux):

Round-1 used OSC 1337 SetUserVar + Custom Tab Title format — broken by
tab.titleOverride. Round-2 wrote tab.titleOverride directly via the iTerm2
Python API, keyed on ITERM_SESSION_ID from the environment. That fixed the
render channel but kept a latent pointing bug: inside the academy tmux fleet,
ITERM_SESSION_ID is STALE. The academy tmux server is spawned from the
Startup iTerm2 tab, so every pane the server hosts inherits Startup's
ITERM_SESSION_ID — no matter which iTerm2 tab the user ends up viewing that
pane in. Every SessionStart hook from every persona tab therefore prepended
"C " on the Startup tab's title and never touched medical/chancellor/etc.

Round-3 adds a tmux-aware target resolver:

  * If TMUX and TMUX_PANE are set, ask tmux for this pane's client_tty
    (the outer iTerm2 TTY that has focus on the pane). Find the iTerm2
    session whose `tty` variable matches, and mutate THAT session's tab.
  * Otherwise (pristine iTerm2, no tmux), fall back to ITERM_SESSION_ID
    — the classic direct mapping that Round-2 used.

Invocation:
    iterm2_tab_title_prefix.py --activate        # adds "C " if not already
    iterm2_tab_title_prefix.py --deactivate      # strips "C " if present

Behavior:
    * Resolves target via tmux client_tty (inside tmux) or ITERM_SESSION_ID.
    * If resolution fails, exits 0 silently — nothing to do outside iTerm2.
    * Idempotent: --activate twice does not produce "C C "; --deactivate on
      an already-unprefixed title is a no-op.
    * Tab-scoped: iterates every tab in every window, finds the one hosting
      the resolved session, mutates only that tab's title.

Failure modes (all non-fatal — script returns 0):
    * iTerm2 Python API disabled → connection timeout → log stderr + exit 0
    * Resolved session UUID/TTY does not match any live session → exit 0
    * Socket auth denied by iTerm2 → exit 0
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys

# XACA-0652: Bootstrap — re-exec under the tap-owned venv that has iterm2
# if running under system python3. Must come before any `import iterm2`.
# XACA-1144-002: this file IS now tap-mirrored (ships to
# $AITEAMFORGE_DIR/scripts/, same as on the dev-team canonical checkout) —
# the __file__-relative bootstrap path still resolves correctly post-ship
# because iterm2_venv_bootstrap.py is already mirrored into that exact same
# scripts/ directory (XACA-0652), so the two remain siblings on every layout.
_bootstrap_dir = os.path.dirname(os.path.abspath(__file__))
if _bootstrap_dir not in sys.path:
    sys.path.insert(0, _bootstrap_dir)
try:
    import iterm2_venv_bootstrap  # noqa: F401 — side-effect: re-exec if needed
except ImportError:
    pass  # dev machine: iterm2 installed globally, bootstrap not required

CLAUDE_PREFIX = "C "


def _tmux_client_tty() -> str | None:
    """Ask tmux for the client TTY hosting the current pane.

    Inside an academy-style setup, multiple iTerm2 tabs each run their own
    `tmux attach` against the same tmux server. Each attach has its own
    client TTY. `#{client_tty}` resolved at a specific pane returns the
    client whose focus is currently on that pane — which is the iTerm2
    TTY we want to target.

    Returns None if not in tmux, if tmux isn't on PATH, or if the command
    fails for any reason.
    """
    pane = os.environ.get("TMUX_PANE")
    if not (os.environ.get("TMUX") and pane):
        return None
    try:
        result = subprocess.run(
            ["tmux", "display-message", "-p", "-t", pane, "#{client_tty}"],
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    tty = result.stdout.strip()
    return tty or None


def _session_uuid_from_env() -> str | None:
    """ITERM_SESSION_ID looks like 'w0t0p0:UUID'. Extract the UUID."""
    raw = os.environ.get("ITERM_SESSION_ID", "")
    if not raw or ":" not in raw:
        return None
    uuid = raw.split(":", 1)[1].strip()
    return uuid or None


async def _find_session_by_tty(app, target_tty):
    for window in app.windows:
        for tab in window.tabs:
            for session in tab.sessions:
                session_tty = await session.async_get_variable("tty")
                if session_tty == target_tty:
                    return tab
    return None


async def _find_tab_by_session_uuid(app, target_uuid):
    for window in app.windows:
        for tab in window.tabs:
            for session in tab.sessions:
                if session.session_id == target_uuid:
                    return tab
    return None


async def _main(connection, target_kind: str, target_value: str, action: str) -> int:
    import iterm2  # noqa: F401 — imported for side effect of ensuring availability

    app = await iterm2.async_get_app(connection)

    if target_kind == "tty":
        tab = await _find_session_by_tty(app, target_value)
    else:  # "uuid"
        tab = await _find_tab_by_session_uuid(app, target_value)

    if tab is None:
        return 0

    current = await tab.async_get_variable("titleOverride") or ""
    if action == "activate":
        new = current if current.startswith(CLAUDE_PREFIX) else CLAUDE_PREFIX + current
    else:  # deactivate
        new = current[len(CLAUDE_PREFIX):] if current.startswith(CLAUDE_PREFIX) else current
    if new != current:
        await tab.async_set_title(new)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--activate", action="store_const", const="activate", dest="action")
    group.add_argument("--deactivate", action="store_const", const="deactivate", dest="action")
    args = ap.parse_args()

    # Tmux-aware target resolution: prefer client_tty inside tmux because
    # ITERM_SESSION_ID is stale there. Fall back to the env var otherwise.
    target_kind: str
    target_value: str | None
    tty = _tmux_client_tty()
    if tty:
        target_kind, target_value = "tty", tty
    else:
        uuid = _session_uuid_from_env()
        if not uuid:
            return 0
        target_kind, target_value = "uuid", uuid

    try:
        import iterm2
    except ImportError:
        print("[iterm2_tab_title_prefix] iterm2 module unavailable; skipping", file=sys.stderr)
        return 0

    try:
        iterm2.run_until_complete(lambda conn: _main(conn, target_kind, target_value, args.action))
    except Exception as exc:  # noqa: BLE001 — best-effort UI decoration
        print(f"[iterm2_tab_title_prefix] iTerm2 API call failed: {exc}", file=sys.stderr)
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
