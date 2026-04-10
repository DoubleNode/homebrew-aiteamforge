#!/usr/bin/env python3
"""
Kanban Stop Hook for Claude Code
Removes window from activeWindows when Claude Code exits.
"""

import json
import os
import sys
import subprocess
import time
from datetime import datetime, timezone

# Add kanban-hooks directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kanban_utils import get_board_file, update_board_safely, parse_session_name

KANBAN_DIR = os.path.expanduser("~/dev-team/kanban")
LOG_FILE = os.path.expanduser("~/dev-team/kanban/stop-hook-debug.log")

def log_debug(message):
    """Write debug message to log file."""
    try:
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(LOG_FILE, 'a') as f:
            f.write(f"[{timestamp}] {message}\n")
    except:
        pass

def get_tmux_context():
    """Get current tmux session name and window name."""
    try:
        session_result = subprocess.run(
            ["tmux", "display-message", "-p", "#S"],
            capture_output=True, text=True, timeout=2
        )
        window_name_result = subprocess.run(
            ["tmux", "display-message", "-p", "#W"],
            capture_output=True, text=True, timeout=2
        )
        if session_result.returncode == 0:
            return (
                session_result.stdout.strip(),
                window_name_result.stdout.strip() if window_name_result.returncode == 0 else "main"
            )
    except Exception:
        pass
    return None, None

# parse_session_name is now imported from kanban_utils

def is_claude_still_running(session_name, window_name):
    """
    Check if Claude is still running in the specified tmux pane.

    Gets the TTY of the target pane and checks if any 'claude' process
    is running on that TTY.
    - If 'claude' process exists → Claude is still running (turn-end Stop)
    - If no 'claude' process → Claude has exited (real exit)

    IMPORTANT: We must explicitly target the session:window because the hook
    may execute in a different tmux context than where Claude is running.
    """
    try:
        # Get the TTY of the target pane
        target = f"{session_name}:{window_name}.0"
        tty_result = subprocess.run(
            ["tmux", "display-message", "-t", target, "-p", "#{pane_tty}"],
            capture_output=True, text=True, timeout=2
        )

        if tty_result.returncode != 0:
            log_debug(f"Failed to get pane TTY: {tty_result.stderr}")
            return False

        pane_tty = tty_result.stdout.strip()
        if not pane_tty:
            log_debug("Empty pane TTY")
            return False

        log_debug(f"Target pane TTY: {pane_tty}")

        # Check if 'claude' process is running on this TTY
        # Remove /dev/ prefix for ps command
        tty_name = pane_tty.replace("/dev/", "")
        ps_result = subprocess.run(
            ["ps", "-t", tty_name, "-o", "comm="],
            capture_output=True, text=True, timeout=2
        )

        if ps_result.returncode == 0:
            processes = ps_result.stdout.strip().split('\n')
            log_debug(f"Processes on {tty_name}: {processes}")
            for proc in processes:
                if 'claude' in proc.lower():
                    log_debug(f"Found claude process: {proc}")
                    return True

        log_debug("No claude process found on pane TTY")
        return False
    except Exception as e:
        log_debug(f"Error checking claude process: {e}")
        return False

def remove_window(team, terminal, window_name):
    """Remove a window entry from activeWindows (only if active for >5 seconds) using atomic writes."""
    board_file = get_board_file(team)

    log_debug(f"remove_window called: team={team}, terminal={terminal}, window={window_name}")

    if not os.path.exists(board_file):
        log_debug(f"Board file not found: {board_file}")
        return False

    window_id = f"{terminal}:{window_name}"
    now = datetime.now(timezone.utc)
    timestamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")

    log_debug(f"Looking for window_id: {window_id}")

    def do_remove(board):
        # Find the window and check if it's been active long enough
        # This prevents removal during startup/reload
        window_to_check = None
        for win in board.get("activeWindows", []):
            if win.get("id") == window_id:
                window_to_check = win
                break

        if not window_to_check:
            log_debug("Window not found in activeWindows")
            return None  # Window not found, nothing to remove

        # Check if window was started more than 5 seconds ago
        # This prevents false Stop events during immediate startup from removing windows
        # 5 seconds is enough to filter startup noise but allows quick legitimate exits
        started_at = window_to_check.get("startedAt", "")
        log_debug(f"Window startedAt: {started_at}")

        if started_at:
            try:
                start_time = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
                age_seconds = (now - start_time).total_seconds()
                log_debug(f"Window age: {age_seconds:.1f} seconds")

                if age_seconds < 5:
                    # Window started very recently, don't remove (probably a false Stop event)
                    log_debug(f"BLOCKED: Window too young ({age_seconds:.1f}s < 5s), not removing")
                    return None
            except Exception as e:
                log_debug(f"Error parsing startedAt: {e}")

        # Check if window is paused - preserve paused windows across restarts
        window_status = window_to_check.get("status", "")
        if window_status == "paused":
            paused_reason = window_to_check.get("pausedReason", "unknown")
            log_debug(f"PRESERVING paused window (reason: {paused_reason}) - not removing on exit")
            return None  # Don't remove paused windows

        log_debug("Removing window from board")

        # Remove the window
        board["activeWindows"] = [
            win for win in board.get("activeWindows", [])
            if win.get("id") != window_id
        ]

        board["lastUpdated"] = timestamp
        log_debug("Window removed successfully")
        return board

    try:
        return update_board_safely(board_file, do_remove)
    except Exception as e:
        log_debug(f"Exception in remove_window: {e}")
        return False

def clear_orphaned_item_fields(team, terminal, window_name):
    """
    Clear activelyWorking and worktree fields on backlog items/subitems
    that reference the exiting window.

    This prevents items from being stuck in 'active' state when a
    terminal/Claude session exits without properly completing the work.

    Fields cleared:
    - activelyWorking
    - worktree
    - worktreeBranch
    - worktreeWindowId
    """
    board_file = get_board_file(team)
    window_id = f"{terminal}:{window_name}"

    log_debug(f"clear_orphaned_item_fields called: window_id={window_id}")

    if not os.path.exists(board_file):
        log_debug(f"Board file not found: {board_file}")
        return False

    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def do_clear(board):
        items_cleared = 0
        subitems_cleared = 0

        for item in board.get("backlog", []):
            # Check if this item references the exiting window
            if item.get("worktreeWindowId") == window_id:
                log_debug(f"Clearing orphaned fields on item: {item.get('id')}")
                item.pop("activelyWorking", None)
                item.pop("worktree", None)
                item.pop("worktreeBranch", None)
                item.pop("worktreeWindowId", None)
                item["updatedAt"] = timestamp
                items_cleared += 1

            # Also check subitems
            for subitem in item.get("subitems", []):
                if subitem.get("worktreeWindowId") == window_id:
                    log_debug(f"Clearing orphaned fields on subitem: {subitem.get('id')}")
                    subitem.pop("activelyWorking", None)
                    subitem.pop("worktree", None)
                    subitem.pop("worktreeBranch", None)
                    subitem.pop("worktreeWindowId", None)
                    subitem["updatedAt"] = timestamp
                    subitems_cleared += 1

        if items_cleared > 0 or subitems_cleared > 0:
            board["lastUpdated"] = timestamp
            log_debug(f"Cleared orphaned fields: {items_cleared} items, {subitems_cleared} subitems")
            return board

        log_debug("No orphaned items found")
        return None  # No changes needed

    try:
        return update_board_safely(board_file, do_clear)
    except Exception as e:
        log_debug(f"Exception in clear_orphaned_item_fields: {e}")
        return False


def delayed_check_and_remove(session_name, window_name, team, terminal):
    """
    Background task: wait for Claude to exit, then remove the window if it did.

    This runs in a forked process so the main hook can return immediately,
    allowing Claude to actually terminate.

    Uses multiple checks with increasing delays to catch both quick exits
    and slower shutdowns.
    """
    try:
        # Check multiple times with increasing delays
        # This handles both quick exits and slower Claude shutdowns
        check_delays = [1.5, 2.0, 3.0]  # Total: 6.5 seconds of checking

        for i, delay in enumerate(check_delays):
            time.sleep(delay)

            log_debug(f"[Background] Check {i+1}/{len(check_delays)}: Checking if Claude exited from {session_name}:{window_name}")

            if not is_claude_still_running(session_name, window_name):
                log_debug("[Background] Claude has exited - proceeding with window removal")
                result = remove_window(team, terminal, window_name)
                log_debug(f"[Background] remove_window result: {result}")

                # NOTE: We intentionally do NOT auto-clear orphaned item fields here.
                # This allows the session to resume and restore the workingOnId
                # relationship via the session-start hook.
                # Truly orphaned items should be cleaned up manually via kb-backlog
                # or the clear_orphaned_item_fields() function.
                return  # Successfully removed window, done

            log_debug(f"[Background] Claude still running after {delay}s delay")

        # All checks found Claude still running - this was a turn-end Stop
        log_debug("[Background] BLOCKED: Claude still running after all checks - this was a turn-end Stop")

    except Exception as e:
        log_debug(f"[Background] Exception: {str(e)}")

def main():
    """Main hook entry point."""
    output = {}

    log_debug("=" * 50)
    log_debug("Stop hook triggered")

    try:
        # Read hook input (may be empty for Stop event)
        try:
            input_data = json.load(sys.stdin)
            log_debug(f"Input data: {json.dumps(input_data)[:200]}")
        except:
            input_data = {}
            log_debug("No input data (empty stdin)")

        session_name, window_name = get_tmux_context()
        team, terminal = parse_session_name(session_name)

        log_debug(f"Context: session={session_name}, window={window_name}, team={team}, terminal={terminal}")

        if team and terminal and window_name:
            # The Stop hook fires BOTH when:
            # 1. Claude finishes a conversation turn (returns to prompt)
            # 2. Claude actually exits (user typed /exit or Ctrl+D)
            #
            # CRITICAL: The hook runs synchronously as part of Claude's shutdown.
            # Claude can't fully exit until this hook returns. So if we check
            # for Claude's process here, it will always be running (waiting for us).
            #
            # Solution: Fork to background, return immediately, let Claude exit,
            # then check if Claude is gone after a delay.

            # Double-fork to fully daemonize the background check
            # This ensures the child survives even when Claude/parent exits
            pid = os.fork()
            if pid == 0:
                # First child - detach from parent session
                os.setsid()

                # Second fork - grandchild becomes the daemon
                pid2 = os.fork()
                if pid2 == 0:
                    # Grandchild - the actual daemon that does the work
                    # Close inherited file descriptors
                    try:
                        os.close(0)  # stdin
                        os.close(1)  # stdout
                        os.close(2)  # stderr
                    except:
                        pass

                    delayed_check_and_remove(session_name, window_name, team, terminal)
                    os._exit(0)
                else:
                    # First child exits immediately, orphaning grandchild to init
                    os._exit(0)
            else:
                # Parent process - wait for first child to exit, then return
                os.waitpid(pid, 0)
                log_debug(f"Daemonized background check, returning immediately")
        else:
            log_debug("Skipping - missing context")

    except Exception as e:
        log_debug(f"Exception: {str(e)}")

    print(json.dumps(output))
    sys.exit(0)

if __name__ == "__main__":
    main()
