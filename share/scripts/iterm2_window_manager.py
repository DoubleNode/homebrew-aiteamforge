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

Note: Requires the 'iterm2' Python package. The dep is provisioned in the
    tap-owned venv at $HOMEBREW_PREFIX/var/aiteamforge/venv by the Formula
    post_install. If it is missing, run: brew postinstall aiteamforge
"""

import argparse
import asyncio
import os
import subprocess
import sys

# If iterm2 is not available, try re-executing via the tap-owned venv.
# The venv is provisioned at $HOMEBREW_PREFIX/var/aiteamforge/venv by the
# Formula post_install.  If missing, run: brew postinstall aiteamforge
try:
    import iterm2
except ImportError:
    import subprocess as _sp
    _brew_prefix = ""
    try:
        _brew_prefix = _sp.check_output(
            ["brew", "--prefix"], text=True, timeout=5
        ).strip()
    except Exception:
        pass
    _tap_venv_candidates = [
        os.path.join(_brew_prefix, "var/aiteamforge/venv") if _brew_prefix else "",
        "/opt/homebrew/var/aiteamforge/venv",
        "/usr/local/var/aiteamforge/venv",
    ]
    for _venv_dir in _tap_venv_candidates:
        if not _venv_dir:
            continue
        venv_python = os.path.join(_venv_dir, "bin/python3")
        if os.path.isfile(venv_python) and sys.executable != venv_python:
            os.execv(venv_python, [venv_python] + sys.argv)
    print("Error: iterm2 module not installed.", file=sys.stderr)
    print(
        "The iterm2 package is provisioned in the tap-owned venv by the Formula.\n"
        "Fix: brew postinstall aiteamforge",
        file=sys.stderr,
    )
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


async def _create_tab_applescript(connection, window, profile, tab_name=None, command=None, window_title=None):
    """Fallback: create a tab via AppleScript when the Python API returns None.

    The Python API's async_create_tab can return None for browser-mode profiles
    and sometimes for regular profiles. AppleScript's `create tab with profile`
    works reliably in both cases.

    Targets a specific window by name to avoid creating tabs in the wrong window.
    """
    import subprocess as _sp

    # Build the profile clause
    if profile:
        safe_profile = profile.replace('\\', '\\\\').replace('"', '\\"')
        profile_clause = f'create tab with profile "{safe_profile}"'
    else:
        profile_clause = 'create tab with default profile'

    # Target window: by name if available, otherwise current window
    if window_title:
        safe_title = window_title.replace('\\', '\\\\').replace('"', '\\"')
        window_target = (
            f'    set targetWindow to missing value\n'
            f'    repeat with w in windows\n'
            f'        if name of w contains "{safe_title}" then\n'
            f'            set targetWindow to w\n'
            f'            exit repeat\n'
            f'        end if\n'
            f'    end repeat\n'
            f'    if targetWindow is missing value then\n'
            f'        set targetWindow to current window\n'
            f'    end if\n'
            f'    tell targetWindow'
        )
    else:
        window_target = '    tell current window'

    # Build AppleScript
    lines = [
        'tell application "iTerm2"',
        window_target,
        f'        {profile_clause}',
    ]
    if tab_name or command:
        lines.append('        tell current session')
        if tab_name:
            safe_tab = tab_name.replace('\\', '\\\\').replace('"', '\\"')
            lines.append(f'            set name to "{safe_tab}"')
        if command:
            safe_cmd = command.replace('\\', '\\\\').replace('"', '\\"')
            lines.append(f'            write text "{safe_cmd}"')
        lines.append('        end tell')
    lines += ['    end tell', 'end tell']

    script = "\n".join(lines)
    result = _sp.run(
        ["osascript", "-e", script],
        capture_output=True, text=True, timeout=10
    )

    if result.returncode != 0:
        print(f"AppleScript error: {result.stderr.strip()}", file=sys.stderr)
        return None

    # If we have a connection, set tab title via API for later lookup
    if connection:
        try:
            app = await iterm2.async_get_app(connection)
            if app.current_window and app.current_window.current_tab:
                new_tab = app.current_window.current_tab
                if tab_name:
                    await new_tab.async_set_title(tab_name)
                    try:
                        await new_tab.async_set_variable("user.tab_name", tab_name)
                    except Exception:
                        pass
                print(f"Created tab via AppleScript: {tab_name or profile}")
                return new_tab
        except Exception:
            pass

    # Pure AppleScript mode (no API connection) — tab was created, return sentinel
    print(f"Created tab via AppleScript (no API): {tab_name or profile}")
    return True  # Sentinel — caller just needs to know it succeeded


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
        # Python API can return None for browser-mode profiles and sometimes
        # after plist modifications. Fall back to AppleScript.
        print(f"Python API returned None, trying AppleScript fallback...")
        tab = await _create_tab_applescript(connection, window, profile, tab_name, command, window_title)
        if tab:
            return tab
        print(f"AppleScript fallback also failed for '{tab_name or profile}'", file=sys.stderr)
        return None

    if tab_name:
        await tab.async_set_title(tab_name)
        # Store tab name as a user variable so select_tab_by_name can find
        # browser-mode tabs (LCARS Web profile) even after the page title
        # overrides titleOverride.
        try:
            await tab.async_set_variable("user.tab_name", tab_name)
        except Exception:
            pass

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

    # Find the tab by name — three strategies in order of reliability:
    # 1. user.tab_name variable (set at creation time, immune to page-title overrides)
    # 2. titleOverride (set via async_set_title — browser tabs may lose this)
    # 3. session name (fallback for shell-mode tabs without a user variable)
    for tab in window.tabs:
        # Strategy 1: user variable set at creation — works for browser-mode tabs
        try:
            user_tab_name = await tab.async_get_variable("user.tab_name")
            if user_tab_name == tab_name:
                await tab.async_activate(order_window_front=True)
                print(f"Selected tab (by user.tab_name): {tab_name} in window: {window_title}")
                return True
        except Exception:
            pass

        # Strategy 2: titleOverride — may be overwritten by browser page title
        try:
            current_title = await tab.async_get_variable("titleOverride")
            if current_title == tab_name:
                await tab.async_activate(order_window_front=True)
                print(f"Selected tab: {tab_name} in window: {window_title}")
                return True
        except Exception:
            pass

        # Strategy 3: session name — shell-mode tabs without user variable
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

        # Run the display command in the agent panel pane.
        # Prefix with "stty -echo" so the command string is not echoed to the
        # terminal when async_send_text simulates typing it.  The display
        # script runs as a long-lived process that occupies the pane, so there
        # is no interactive shell prompt where echo state would matter.
        if command:
            await agent_session.async_send_text("stty -echo; " + command + "\n")

        print(f"Created agent panel pane in tab: {tab_name}")
        # Activate the original (left) session so the terminal is focused
        await session.async_activate()
    else:
        print(f"Failed to create agent panel pane", file=sys.stderr)

    return agent_session


async def ensure_agent_panel_profile(connection, font_spec="FiraCodeNFM-Light 8"):
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


async def resize_pane_by_env(connection, target_cols=30, min_rows=50):
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
                    current_width = session.grid_size.width
                    if current_width == target_cols:
                        return True  # already correct

                    # Only set the agent panel's preferred size.
                    # Do NOT compute or set the other pane's size —
                    # reading total_cols and subtracting creates a
                    # feedback loop where rounding/divider errors
                    # accumulate, shrinking the window each cycle.
                    #
                    # Height: only grow to min_rows if currently shorter.
                    # Round-tripping grid_size.height into preferred_size
                    # also feedback-loops (chrome padding inflates grid each
                    # cycle, causing monotonic window growth). Preserve the
                    # stable preferred height when current is already tall enough.
                    current_height = session.grid_size.height
                    if current_height < min_rows:
                        target_height = min_rows
                    else:
                        # `preferred_size.height or current_height`: on a freshly-created
                        # session iTerm2 reports preferred_size.height as 0 (falsy) until
                        # the layout has stabilized — fall back to current_height in that
                        # window to avoid pinning the pane to a 0-row preference.
                        target_height = session.preferred_size.height or current_height
                    session.preferred_size = iterm2.util.Size(target_cols, target_height)
                    # Capture window frame BEFORE update_layout, restore AFTER.
                    # async_update_layout uses preferred_sizes as the layout target;
                    # because main pane's preferred_size is frozen at split-time
                    # (170 cols) and never tracks user-driven window growth,
                    # the layout pass pulls the window down toward the preferred
                    # sum (~200 cols) — shrinking the window monotonically each
                    # tick where this branch fires. Restoring the pixel frame
                    # cancels that pull without disturbing pane ratios.
                    saved_frame = await window.async_get_frame()
                    await tab.async_update_layout()
                    await window.async_set_frame(saved_frame)
                    print(f"Resized pane {session.session_id}: "
                          f"{current_width} -> {target_cols} cols, "
                          f"height {current_height} (min {min_rows})")
                    return True
    print(f"Session not found: {env_session_id} (uuid: {session_uuid})", file=sys.stderr)
    return False



async def reset_all_agent_panels(connection, target_cols=30, min_rows=50):
    """Reset ALL agent panel panes across all windows to the target width.

    Iterates through every tab in every window. For tabs with exactly 2 panes,
    sets the narrower pane (the agent panel) to target_cols and the wider pane
    to the remainder. Processes one tab at a time to avoid cascading.
    """
    import asyncio
    app = await iterm2.async_get_app(connection)
    fixed = 0
    skipped = 0

    for window in app.windows:
        for tab in window.tabs:
            sessions = tab.sessions
            if len(sessions) != 2:
                continue  # skip tabs without a 2-pane split

            # Identify the agent panel (narrower pane) vs main terminal
            s0, s1 = sessions[0], sessions[1]
            w0, w1 = s0.grid_size.width, s1.grid_size.width
            if w0 <= w1:
                agent, main = s0, s1
                agent_w, main_w = w0, w1
            else:
                agent, main = s1, s0
                agent_w, main_w = w1, w0

            if agent_w == target_cols:
                skipped += 1
                continue

            # Height: only grow to min_rows if shorter; otherwise preserve the
            # stable preferred height. Using grid_size.height round-trips
            # chrome-padded values back into preferred and inflates the window.
            current_h = agent.grid_size.height
            if current_h < min_rows:
                target_h = min_rows
            else:
                # See `preferred_size.height or current_h` note in resize_pane_by_env:
                # a fresh session reports preferred_size.height = 0 until layout settles.
                target_h = agent.preferred_size.height or current_h
            agent.preferred_size = iterm2.util.Size(target_cols, target_h)
            # See window-frame capture/restore note in resize_pane_by_env:
            # the layout pass otherwise pulls the window toward the sum of
            # preferred_sizes (agent_target + main_frozen ≈ 200 cols),
            # shrinking the window each cycle.
            saved_frame = await window.async_get_frame()
            await tab.async_update_layout()
            await window.async_set_frame(saved_frame)
            fixed += 1

            # Small delay between tabs to let iTerm2 settle
            await asyncio.sleep(0.1)

    print(f"Reset {fixed} panels, {skipped} already correct")


async def set_default_profile_font(connection, font_spec):
    """Set the Normal Font on iTerm2's built-in 'Default' profile.

    Team agent tabs are created without an explicit --profile, so they inherit
    Default. Calling this once at install time ensures every future agent tab
    uses the intended font/size without per-tab overrides.
    """
    all_profiles = await iterm2.PartialProfile.async_query(connection)
    for p in all_profiles:
        if p.name == "Default":
            full = await p.async_get_full_profile()
            if full.normal_font != font_spec:
                await full.async_set_normal_font(font_spec)
                print(f"Set Default profile font to '{font_spec}'")
            else:
                print(f"Default profile font already '{font_spec}'")
            return True
    print("Default profile not found", file=sys.stderr)
    return False


async def set_session_font(connection, font_spec):
    """Set the font for the current session (identified by ITERM_SESSION_ID env var).

    font_spec: Font name and size, e.g. "FiraCodeNFM-Light 8"
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
    connection = None
    try:
        connection = await asyncio.wait_for(
            iterm2.Connection.async_create(),
            timeout=5.0
        )
    except asyncio.TimeoutError:
        print("Warning: Timed out connecting to iTerm2 API (5s).", file=sys.stderr)
    except Exception as e:
        print(f"Warning: iTerm2 API connection failed: {e}", file=sys.stderr)

    # If the API is unavailable, fall back to pure AppleScript for create-tab
    if not connection:
        if args.action == "create-tab":
            print("Using AppleScript-only fallback for tab creation...")
            tab = await _create_tab_applescript(None, None, args.profile, args.tab_name, args.command, args.window_title)
            if tab is None:
                sys.exit(1)

            # AppleScript succeeded.  Try to reconnect the Python API so we can
            # back-fill user.tab_name on the newly created tab — this lets later
            # select-tab and split-agent-panel calls find the tab by name.
            # Simple retry: up to 5 attempts, 1 s apart.  Give up silently if
            # the API is still unavailable (the tab still exists, lookups will
            # fall back to titleOverride / session-name strategies).
            if args.tab_name:
                reconnected = None
                for _retry in range(5):
                    await asyncio.sleep(1)
                    try:
                        reconnected = await asyncio.wait_for(
                            iterm2.Connection.async_create(),
                            timeout=3.0
                        )
                        break
                    except Exception:
                        pass

                if reconnected:
                    try:
                        app = await iterm2.async_get_app(reconnected)
                        # Walk all tabs in all windows to find the newly created one.
                        # We identify it by titleOverride or session name matching
                        # args.tab_name (AppleScript set the session name above).
                        # Skip tabs that already have user.tab_name set — they are
                        # pre-existing tabs with the same display name, not the new one.
                        # Collect all candidates first, then pick the last one (newest).
                        candidates_found = []
                        for window in app.windows:
                            for candidate in window.tabs:
                                matched = False
                                already_labelled = False
                                try:
                                    existing = await candidate.async_get_variable("user.tab_name")
                                    if existing == args.tab_name:
                                        already_labelled = True
                                except Exception:
                                    pass
                                if already_labelled:
                                    continue
                                try:
                                    ov = await candidate.async_get_variable("titleOverride")
                                    if ov == args.tab_name:
                                        matched = True
                                except Exception:
                                    pass
                                if not matched and candidate.current_session:
                                    try:
                                        sn = await candidate.current_session.async_get_variable("name")
                                        if sn == args.tab_name:
                                            matched = True
                                    except Exception:
                                        pass
                                if matched:
                                    candidates_found.append(candidate)
                        # Use the last match — iTerm2 appends new tabs at the end.
                        if candidates_found:
                            target = candidates_found[-1]
                            try:
                                await target.async_set_variable("user.tab_name", args.tab_name)
                                print(f"Back-filled user.tab_name='{args.tab_name}' after AppleScript tab creation")
                            except Exception as _e:
                                print(f"Warning: could not back-fill user.tab_name: {_e}", file=sys.stderr)
                    except Exception as _e:
                        print(f"Warning: API reconnect succeeded but backfill failed: {_e}", file=sys.stderr)
                else:
                    print(f"Warning: iTerm2 API unavailable after AppleScript tab creation — user.tab_name not set", file=sys.stderr)
            return
        else:
            print("Error: iTerm2 API unavailable and no fallback for this action.", file=sys.stderr)
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
        min_rows = int(args.min_rows) if args.min_rows else 50
        await resize_pane_by_env(connection, target, min_rows)

    elif args.action == "set-font":
        font_name = args.font or "FiraCodeNFM-Light 8"
        await set_session_font(connection, font_name)

    elif args.action == "set-default-font":
        font_name = args.font or "FiraCodeNFM-Reg 10"
        await set_default_profile_font(connection, font_name)

    elif args.action == "reset-panels":
        target = int(args.target_cols) if args.target_cols else 30
        min_rows = int(args.min_rows) if args.min_rows else 50
        await reset_all_agent_panels(connection, target, min_rows)

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
    parser.add_argument("--min-rows", help="Minimum row height; only grows pane if shorter (default: 50)")
    parser.add_argument("--font", "-f", help="Font spec for set-font action (e.g. 'FiraCodeNFM-Light 8')")
    parser.add_argument(
        "--action", "-a",
        choices=["create-window", "init-team-window", "create-tab", "set-title", "select-tab", "split-agent-panel", "resize-pane", "reset-panels", "set-font", "set-default-font", "list-windows"],
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
