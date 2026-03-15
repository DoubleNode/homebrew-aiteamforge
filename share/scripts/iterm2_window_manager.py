#!/usr/bin/env python3
"""
iTerm2 Window Manager - Python API for managing iTerm2 windows and tabs.

This script uses the iTerm2 Python API to:
- Find or create windows with specific titles
- Create tabs with specific profiles
- Execute commands in tabs

Usage:
    python3 iterm2_window_manager.py --window-title "Team Name" --action create-window
    python3 iterm2_window_manager.py --window-title "Team Name" --action create-tab --profile "Default" --tab-name "terminal" --command "tmux attach"
    python3 iterm2_window_manager.py --window-title "Team Name" --action set-title

Note: Requires the 'iterm2' Python package. On Python 3.12+ (PEP 668), use a venv:
    python3 -m venv ~/aiteamforge/.venv && ~/aiteamforge/.venv/bin/pip install iterm2
"""

import argparse
import asyncio
import os
import subprocess
import sys

# If iterm2 is not available, try re-executing via the aiteamforge venv
try:
    import iterm2
except ImportError:
    venv_python = os.path.expanduser("~/aiteamforge/.venv/bin/python3")
    if os.path.isfile(venv_python) and sys.executable != venv_python:
        os.execv(venv_python, [venv_python] + sys.argv)
    print("Error: iterm2 module not installed.", file=sys.stderr)
    print("Fix with: python3 -m venv ~/aiteamforge/.venv && ~/aiteamforge/.venv/bin/pip install iterm2", file=sys.stderr)
    sys.exit(1)


def check_iterm2_python_api():
    """Check if iTerm2's Python API is enabled.

    Returns True if enabled, False if disabled or unset.
    When disabled, iterm2.Connection will fail with a connection error.
    """
    try:
        result = subprocess.run(
            ["defaults", "read", "com.googlecode.iterm2", "EnableAPIServer"],
            capture_output=True, text=True, timeout=3
        )
        return result.stdout.strip() == "1"
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def is_iterm2_running():
    """Check if iTerm2 is currently running via pgrep.

    Returns True if iTerm2 process is found, False otherwise.
    This check prevents hanging on iterm2.Connection.async_create() when
    iTerm2 is not running or is in a restart loop.

    Uses -f (full command match) instead of -x (exact name match) because
    pgrep -x "iTerm2" fails in some macOS terminal contexts even when
    iTerm2 is running. Matching against the app bundle path is reliable.
    """
    try:
        result = subprocess.run(
            ["pgrep", "-f", "iTerm.app"],
            capture_output=True,
            timeout=3
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


async def find_window_by_title(app, title):
    """Find a window by its title."""
    for window in app.windows:
        # Get the window's current title
        try:
            # Try to match by checking tabs/sessions
            if window.current_tab and window.current_tab.current_session:
                # Check if window has our title set
                pass
        except Exception:
            pass

    # iTerm2 doesn't expose window title directly in a searchable way
    # We'll use a user variable to track our windows
    for window in app.windows:
        try:
            var_title = await window.async_get_variable("user.window_title")
            if var_title == title:
                return window
        except Exception:
            continue

    return None


async def create_window_with_title(connection, title, profile=None):
    """Create a new window and set its title."""
    app = await iterm2.async_get_app(connection)

    # Create window with specified profile or default
    if profile:
        window = await iterm2.Window.async_create(connection, profile=profile)
    else:
        window = await iterm2.Window.async_create(connection)

    if window:
        # Set the window title
        await window.async_set_title(title)
        # Store title in user variable for later lookup
        await window.async_set_variable("user.window_title", title)
        print(f"Created window with title: {title}")
        print(f"Window ID: {window.window_id}")
        return window
    else:
        print("Failed to create window", file=sys.stderr)
        return None


async def find_or_create_window(connection, title, profile=None):
    """Find an existing window by title or create a new one."""
    app = await iterm2.async_get_app(connection)

    # Try to find existing window
    window = await find_window_by_title(app, title)
    if window:
        print(f"Found existing window: {title}")
        print(f"Window ID: {window.window_id}")
        return window

    # Create new window
    return await create_window_with_title(connection, title, profile)


async def create_tab_in_window(connection, window_title, profile=None, tab_name=None, command=None):
    """Create a new tab in the specified window.

    Logic:
    1. First, look for an existing window with the title
    2. If not found, rename the CURRENT window to that title (instead of creating new)
    3. ALWAYS create a new tab (never reuse the startup tab)
    """
    app = await iterm2.async_get_app(connection)

    # Find the window by title
    window = await find_window_by_title(app, window_title)

    if not window:
        # No window with this title exists - rename the CURRENT window
        window = app.current_window
        if window:
            print(f"Renaming current window to: {window_title}")
            await window.async_set_title(window_title)
            await window.async_set_variable("user.window_title", window_title)
            # Rename the startup tab so it's clear what it is
            if window.current_tab:
                await window.current_tab.async_set_title("Startup")
                if window.current_tab.current_session:
                    await window.current_tab.current_session.async_set_name("Startup")
        else:
            # No current window, create a new one
            print(f"No current window, creating new: {window_title}")
            window = await create_window_with_title(connection, window_title, profile)
            if not window:
                return None

    # ALWAYS create a new tab (never reuse the startup tab)
    try:
        if profile:
            tab = await window.async_create_tab(profile=profile)
        else:
            tab = await window.async_create_tab()
    except Exception as e:
        print(f"Failed to create tab in window '{window_title}': {e}", file=sys.stderr)
        return None

    if not tab:
        print(f"Failed to create tab in window '{window_title}': async_create_tab returned None", file=sys.stderr)
        return None

    if tab_name:
        await tab.async_set_title(tab_name)

    if command and tab.current_session:
        session = tab.current_session
        if tab_name:
            await session.async_set_name(tab_name)
        await session.async_send_text(command + "\n")

    print(f"Created tab in window: {window_title}")
    if tab_name:
        print(f"Tab name: {tab_name}")

    return tab


async def get_window_by_id(app, window_id):
    """Find a window by its ID."""
    for window in app.windows:
        if window.window_id == window_id:
            return window
    return None


async def init_team_window(connection, window_title):
    """Initialize the team window by capturing current window and renaming it.

    This should be called FIRST in startup scripts to capture the window
    before the user can switch to a different window.

    Returns the window ID that should be used for all subsequent operations.
    """
    app = await iterm2.async_get_app(connection)

    # Check if window with this title already exists
    existing = await find_window_by_title(app, window_title)
    if existing:
        print(f"WINDOW_ID={existing.window_id}")
        return existing.window_id

    # Capture the current window RIGHT NOW
    window = app.current_window
    if not window:
        print("ERROR: No current window", file=sys.stderr)
        return None

    # Rename the window immediately
    await window.async_set_title(window_title)
    await window.async_set_variable("user.window_title", window_title)

    # Rename the current tab to "Startup" so it's preserved
    if window.current_tab:
        await window.current_tab.async_set_title("Startup")
        if window.current_tab.current_session:
            await window.current_tab.current_session.async_set_name("Startup")

    print(f"WINDOW_ID={window.window_id}")
    return window.window_id


async def set_window_title(connection, window_id, title):
    """Set the title of an existing window by ID."""
    app = await iterm2.async_get_app(connection)

    for window in app.windows:
        if window.window_id == window_id:
            await window.async_set_title(title)
            await window.async_set_variable("user.window_title", title)
            print(f"Set window title to: {title}")
            return True

    print(f"Window not found: {window_id}", file=sys.stderr)
    return False


async def set_current_window_title(connection, title):
    """Set the title of the current/frontmost window."""
    app = await iterm2.async_get_app(connection)

    window = app.current_window
    if window:
        await window.async_set_title(title)
        await window.async_set_variable("user.window_title", title)
        print(f"Set current window title to: {title}")
        return True
    else:
        print("No current window found", file=sys.stderr)
        return False


async def select_tab_by_name(connection, window_title, tab_name):
    """Select/activate a tab by name within the specified window.

    This brings the tab to focus and optionally brings the window to front.
    """
    app = await iterm2.async_get_app(connection)

    # Find the window by title
    window = await find_window_by_title(app, window_title)
    if not window:
        print(f"Window not found: {window_title}", file=sys.stderr)
        return False

    # Find the tab by name
    for tab in window.tabs:
        try:
            # Get the tab title (set via async_set_title)
            current_title = await tab.async_get_variable("titleOverride")
            if current_title == tab_name:
                await tab.async_activate(order_window_front=True)
                print(f"Selected tab: {tab_name} in window: {window_title}")
                return True
        except Exception:
            pass

        # Also check session name as fallback
        if tab.current_session:
            try:
                session_name = await tab.current_session.async_get_variable("name")
                if session_name == tab_name:
                    await tab.async_activate(order_window_front=True)
                    print(f"Selected tab (by session name): {tab_name} in window: {window_title}")
                    return True
            except Exception:
                pass

    print(f"Tab not found: {tab_name} in window: {window_title}", file=sys.stderr)
    return False


async def split_agent_panel(connection, window_title, tab_name, command):
    """Split a tab's session to add an Agent Panel pane on the right side.

    Creates a narrow terminal pane that runs a display script showing the
    agent's avatar (via imgcat) and info. No browser chrome.
    """
    app = await iterm2.async_get_app(connection)

    # Find the window
    window = await find_window_by_title(app, window_title)
    if not window:
        print(f"Window not found: {window_title}", file=sys.stderr)
        return None

    # Find the tab by name
    target_tab = None
    for tab in window.tabs:
        try:
            current_title = await tab.async_get_variable("titleOverride")
            if current_title == tab_name:
                target_tab = tab
                break
        except Exception:
            pass
        # Fallback: check session name
        if tab.current_session:
            try:
                session_name = await tab.current_session.async_get_variable("name")
                if session_name == tab_name:
                    target_tab = tab
                    break
            except Exception:
                pass

    if not target_tab or not target_tab.current_session:
        print(f"Tab not found: {tab_name}", file=sys.stderr)
        return None

    # Use Agent Panel profile (Antonio font) with fallback to Default
    panel_profile = await ensure_agent_panel_profile(connection)

    # Split the session vertically (agent panel on the right)
    session = target_tab.current_session
    agent_session = await session.async_split_pane(
        vertical=True,
        profile=panel_profile
    )

    if agent_session:
        # Resize: make the agent panel narrow (30 cols) and terminal wide
        agent_session.preferred_size = iterm2.util.Size(30, 50)
        session.preferred_size = iterm2.util.Size(170, 50)
        await target_tab.async_update_layout()

        # Run the display command in the agent panel pane
        if command:
            await agent_session.async_send_text(command + "\n")

        print(f"Created agent panel pane in tab: {tab_name}")
        # Activate the original (left) session so the terminal is focused
        await session.async_activate()
    else:
        print(f"Failed to create agent panel pane", file=sys.stderr)

    return agent_session


async def ensure_agent_panel_profile(connection, font_spec="JetBrainsMonoNF-Light 9"):
    """Ensure the 'Agent Panel' iTerm2 profile exists and has the correct font.

    If the profile doesn't exist, falls back to 'Default'.
    Returns the profile name to use for splits.
    """
    all_profiles = await iterm2.PartialProfile.async_query(connection)
    for p in all_profiles:
        if p.name == "Agent Panel":
            # Ensure font is set correctly
            full = await p.async_get_full_profile()
            if full.normal_font != font_spec:
                await full.async_set_normal_font(font_spec)
            return "Agent Panel"
    return "Default"  # Fallback if profile doesn't exist


def extract_session_uuid(env_id):
    """Extract UUID from ITERM_SESSION_ID (format: 'w0t0p0:UUID' or just 'UUID')."""
    if ":" in env_id:
        return env_id.split(":", 1)[1]
    return env_id


async def resize_pane_by_env(connection, target_cols=30):
    """Resize the current pane (identified by ITERM_SESSION_ID env var) to a fixed column width.

    Called by agent-panel-display.sh when pane width drifts from target.
    """
    import os
    app = await iterm2.async_get_app(connection)
    env_session_id = os.environ.get("ITERM_SESSION_ID", "")
    if not env_session_id:
        print("No ITERM_SESSION_ID set", file=sys.stderr)
        return False

    session_uuid = extract_session_uuid(env_session_id)

    for window in app.windows:
        for tab in window.tabs:
            for session in tab.sessions:
                if session.session_id == session_uuid:
                    session.preferred_size = iterm2.util.Size(target_cols, 50)
                    # Also set the other pane to fill remaining space
                    for other in tab.sessions:
                        if other.session_id != session.session_id:
                            other.preferred_size = iterm2.util.Size(170, 50)
                    await tab.async_update_layout()
                    print(f"Resized pane {session.session_id} to {target_cols} cols")
                    return True
    print(f"Session not found: {env_session_id} (uuid: {session_uuid})", file=sys.stderr)
    return False



async def set_session_font(connection, font_spec):
    """Set the font for the current session (identified by ITERM_SESSION_ID env var).

    font_spec: Font name and size, e.g. "JetBrainsMonoNF-Light 9"
    """
    import os
    app = await iterm2.async_get_app(connection)
    env_session_id = os.environ.get("ITERM_SESSION_ID", "")
    if not env_session_id:
        print("No ITERM_SESSION_ID set", file=sys.stderr)
        return False

    session_uuid = extract_session_uuid(env_session_id)

    for window in app.windows:
        for tab in window.tabs:
            for session in tab.sessions:
                if session.session_id == session_uuid:
                    profile = await session.async_get_profile()
                    await profile.async_set_normal_font(font_spec)
                    print(f"Set font to '{font_spec}' for session {session.session_id}")
                    return True
    print(f"Session not found: {env_session_id} (uuid: {session_uuid})", file=sys.stderr)
    return False


async def main_async(args):
    """Main async function."""
    # Pre-flight check: verify iTerm2 is actually running before attempting
    # API connection. Without this, async_create() hangs indefinitely when
    # iTerm2 is not running, which can cascade into a runaway process loop.
    if not is_iterm2_running():
        print("Error: iTerm2 is not running. Start iTerm2 and try again.", file=sys.stderr)
        sys.exit(1)

    if not check_iterm2_python_api():
        print("Error: iTerm2 Python API is not enabled.", file=sys.stderr)
        print("Enable via: iTerm2 → Settings → General → Magic → Enable Python API", file=sys.stderr)
        print("Or run: defaults write com.googlecode.iterm2 EnableAPIServer -bool true", file=sys.stderr)
        print("Then restart iTerm2.", file=sys.stderr)
        sys.exit(1)

    # Establish connection with a 5-second timeout. If iTerm2 is running but
    # its API socket is not ready (e.g. mid-restart), we exit cleanly rather
    # than hanging indefinitely.
    try:
        connection = await asyncio.wait_for(
            iterm2.Connection.async_create(),
            timeout=5.0
        )
    except asyncio.TimeoutError:
        print("Error: Timed out connecting to iTerm2 API (5s). iTerm2 may be starting up or unresponsive.", file=sys.stderr)
        sys.exit(1)

    if args.action == "create-window":
        await find_or_create_window(connection, args.window_title, args.profile)

    elif args.action == "init-team-window":
        # Initialize team window - call this FIRST in startup scripts
        await init_team_window(connection, args.window_title)

    elif args.action == "create-tab":
        await create_tab_in_window(
            connection,
            args.window_title,
            args.profile,
            args.tab_name,
            args.command
        )

    elif args.action == "set-title":
        if args.window_id:
            await set_window_title(connection, args.window_id, args.window_title)
        else:
            await set_current_window_title(connection, args.window_title)

    elif args.action == "select-tab":
        await select_tab_by_name(connection, args.window_title, args.tab_name)

    elif args.action == "split-agent-panel":
        await split_agent_panel(connection, args.window_title, args.tab_name, args.command)

    elif args.action == "resize-pane":
        target = int(args.target_cols) if args.target_cols else 30
        await resize_pane_by_env(connection, target)

    elif args.action == "set-font":
        font_name = args.font or "JetBrainsMonoNF-Light 9"
        await set_session_font(connection, font_name)

    elif args.action == "list-windows":
        app = await iterm2.async_get_app(connection)
        print("Windows:")
        for window in app.windows:
            user_title = None
            try:
                user_title = await window.async_get_variable("user.window_title")
            except Exception:
                pass
            tabs = len(window.tabs) if window.tabs else 0
            print(f"  ID: {window.window_id}, User Title: {user_title}, Tabs: {tabs}")


def main():
    parser = argparse.ArgumentParser(description="iTerm2 Window Manager")
    parser.add_argument("--window-title", "-t", help="Window title to find or set")
    parser.add_argument("--window-id", "-i", help="Window ID (for set-title action)")
    parser.add_argument("--profile", "-p", help="iTerm2 profile to use")
    parser.add_argument("--tab-name", "-n", help="Name for the new tab")
    parser.add_argument("--command", "-c", help="Command to execute in the tab")
    parser.add_argument("--url", "-u", help="(deprecated) URL for agent panel")
    parser.add_argument("--target-cols", help="Target column width for resize-pane action (default: 30)")
    parser.add_argument("--font", "-f", help="Font spec for set-font action (e.g. 'JetBrainsMonoNF-Light 9')")
    parser.add_argument(
        "--action", "-a",
        choices=["create-window", "init-team-window", "create-tab", "set-title", "select-tab", "split-agent-panel", "resize-pane", "set-font", "list-windows"],
        default="create-window",
        help="Action to perform (init-team-window should be called FIRST in startup scripts, select-tab after all tabs created)"
    )

    args = parser.parse_args()

    if args.action in ["create-window", "init-team-window", "create-tab", "set-title", "select-tab", "split-agent-panel"] and not args.window_title:
        parser.error("--window-title is required for this action")

    if args.action in ["select-tab", "split-agent-panel"] and not args.tab_name:
        parser.error("--tab-name is required for this action")

    if args.action == "split-agent-panel" and not args.command:
        parser.error("--command is required for split-agent-panel action")

    try:
        asyncio.run(main_async(args))
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
