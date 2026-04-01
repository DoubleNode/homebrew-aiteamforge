#!/usr/bin/env python3
"""
Kanban Session Start Hook for Claude Code
Automatically marks the window as "ready" when Claude Code starts.
"""

import json
import os
import sys
import subprocess
from datetime import datetime, timezone

# Add kanban-hooks directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kanban_utils import get_board_file, update_board_safely, parse_session_name

KANBAN_DIR = os.path.expanduser("~/aiteamforge/kanban")
LOG_FILE = os.path.expanduser("~/aiteamforge/kanban/start-hook-debug.log")

def log_debug(message):
    """Write debug message to log file."""
    try:
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(LOG_FILE, 'a') as f:
            f.write(f"[{timestamp}] {message}\n")
    except:
        pass

def get_tmux_context():
    """Get current tmux session name, window index, and window name."""
    try:
        pane_target = os.environ.get("TMUX_PANE", "")
        tmux_cmd_base = ["tmux", "display-message"]
        if pane_target:
            tmux_cmd_base = ["tmux", "display-message", "-t", pane_target]
        session_result = subprocess.run(
            tmux_cmd_base + ["-p", "#S"],
            capture_output=True, text=True, timeout=2
        )
        window_idx_result = subprocess.run(
            tmux_cmd_base + ["-p", "#I"],
            capture_output=True, text=True, timeout=2
        )
        window_name_result = subprocess.run(
            tmux_cmd_base + ["-p", "#W"],
            capture_output=True, text=True, timeout=2
        )

        if session_result.returncode == 0 and window_idx_result.returncode == 0:
            return (
                session_result.stdout.strip(),
                int(window_idx_result.stdout.strip()),
                window_name_result.stdout.strip() if window_name_result.returncode == 0 else "main"
            )
    except Exception:
        pass
    return None, None, None

def get_git_worktree():
    """Get current git worktree full path."""
    try:
        result = subprocess.run(
            ["git", "--no-optional-locks", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=2
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return ""

def get_git_branch():
    """Get current git branch name."""
    try:
        result = subprocess.run(
            ["git", "--no-optional-locks", "branch", "--show-current"],
            capture_output=True, text=True, timeout=2
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return ""

def get_git_modified_count():
    """Get count of modified/untracked files."""
    try:
        result = subprocess.run(
            ["git", "--no-optional-locks", "status", "--porcelain"],
            capture_output=True, text=True, timeout=2
        )
        if result.returncode == 0:
            lines = [l for l in result.stdout.strip().split('\n') if l]
            return len(lines)
    except Exception:
        pass
    return 0

def get_git_lines_changed():
    """Get lines added and deleted in working directory."""
    try:
        result = subprocess.run(
            ["git", "--no-optional-locks", "diff", "--numstat"],
            capture_output=True, text=True, timeout=2
        )
        if result.returncode == 0:
            added = 0
            deleted = 0
            for line in result.stdout.strip().split('\n'):
                if line:
                    parts = line.split('\t')
                    if len(parts) >= 2:
                        if parts[0] != '-':
                            added += int(parts[0])
                        if parts[1] != '-':
                            deleted += int(parts[1])
            return {"added": added, "deleted": deleted}
    except Exception:
        pass
    return {"added": 0, "deleted": 0}

# parse_session_name is now imported from kanban_utils

def trigger_health_check():
    """Trigger LCARS health check in background to ensure server is running.

    This runs the health check script asynchronously so it doesn't block
    the session start. The health check will auto-start any dead LCARS
    servers for active teams.
    """
    health_script = os.path.expanduser("~/aiteamforge/lcars-health-check.sh")
    try:
        if os.path.isfile(health_script) and os.access(health_script, os.X_OK):
            # Run in background, don't wait for result
            subprocess.Popen(
                [health_script],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True  # Detach from parent process
            )
            log_debug("Triggered LCARS health check in background")
        else:
            log_debug(f"Health check script not found or not executable: {health_script}")
    except Exception as e:
        log_debug(f"Failed to trigger health check: {e}")

def extract_item_id_from_branch(branch_name):
    """
    Extract a potential item ID from a git branch name.

    Examples:
        feature/xaca-0012 -> XACA-0012
        feature/xfsw-0007 -> XFSW-0007
        bugfix/xfre-0001-fix-crash -> XFRE-0001
        hotfix/ios-123 -> None (no match)

    Returns the uppercase item ID or None if no match.
    """
    import re
    if not branch_name:
        return None

    # Match patterns like xaca-0012, xfsw-0007, xfre-0001, etc.
    # These are typically 4 letters followed by 4 digits
    match = re.search(r'([a-zA-Z]{4})-(\d{4})', branch_name)
    if match:
        prefix = match.group(1).upper()
        number = match.group(2)
        return f"{prefix}-{number}"
    return None

def auto_link_item_from_branch(board, branch_name, worktree, window_id, timestamp):
    """
    Auto-link a backlog item based on the current git branch name.

    If the branch contains an item ID pattern (e.g., feature/xaca-0012),
    find the matching backlog item and establish the linkage.

    Returns the item ID if linked, None otherwise.
    """
    item_id = extract_item_id_from_branch(branch_name)
    if not item_id:
        log_debug(f"No item ID found in branch: {branch_name}")
        return None

    # Find the item in backlog
    for idx, item in enumerate(board.get("backlog", [])):
        if item.get("id") == item_id:
            # Check if item is already linked to a different window
            existing_window = item.get("worktreeWindowId")
            if existing_window and existing_window != window_id:
                log_debug(f"Item {item_id} already linked to different window: {existing_window}")
                return None

            # Link the item if not already linked or if linked to this window
            if not item.get("activelyWorking"):
                log_debug(f"Auto-linking item {item_id} to window {window_id}")
                item["activelyWorking"] = True
                item["worktree"] = worktree
                item["worktreeBranch"] = branch_name
                item["worktreeWindowId"] = window_id
                item["updatedAt"] = timestamp
                if not item.get("workStartedAt"):
                    item["workStartedAt"] = timestamp
                if not item.get("startedAt"):
                    item["startedAt"] = timestamp
                if item.get("status") == "pending":
                    item["status"] = "in_progress"
                board["lastUpdated"] = timestamp
                return item_id
            else:
                # Already actively working, just ensure window linkage
                if item.get("worktreeWindowId") != window_id:
                    item["worktreeWindowId"] = window_id
                    board["lastUpdated"] = timestamp
                return item_id

    # Check subitems
    for item in board.get("backlog", []):
        for sub_idx, subitem in enumerate(item.get("subitems", [])):
            if subitem.get("id") == item_id:
                existing_window = subitem.get("worktreeWindowId")
                if existing_window and existing_window != window_id:
                    log_debug(f"Subitem {item_id} already linked to different window: {existing_window}")
                    return None

                if not subitem.get("activelyWorking"):
                    log_debug(f"Auto-linking subitem {item_id} to window {window_id}")
                    subitem["activelyWorking"] = True
                    subitem["worktree"] = worktree
                    subitem["worktreeBranch"] = branch_name
                    subitem["worktreeWindowId"] = window_id
                    subitem["updatedAt"] = timestamp
                    if not subitem.get("workStartedAt"):
                        subitem["workStartedAt"] = timestamp
                    if not subitem.get("startedAt"):
                        subitem["startedAt"] = timestamp
                    if subitem.get("status") == "pending":
                        subitem["status"] = "in_progress"
                    board["lastUpdated"] = timestamp
                    return item_id
                else:
                    if subitem.get("worktreeWindowId") != window_id:
                        subitem["worktreeWindowId"] = window_id
                        board["lastUpdated"] = timestamp
                    return item_id

    log_debug(f"Item {item_id} not found in backlog")
    return None

def update_window_ready(team, terminal, window_index, window_name):
    """Add or update window entry as 'ready' status using atomic writes."""
    board_file = get_board_file(team)

    if not os.path.exists(board_file):
        return False

    # Gather git info BEFORE acquiring lock (these are slow operations)
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    window_id = f"{terminal}:{window_name}"
    worktree = get_git_worktree()
    git_branch = get_git_branch()
    git_modified = get_git_modified_count()
    git_lines = get_git_lines_changed()

    def do_update(board):
        # Get developer info from terminals config
        developer = "Unknown"
        color = "operations"
        if terminal in board.get("terminals", {}):
            developer = board["terminals"][terminal].get("developer", "Unknown")
            color = board["terminals"][terminal].get("color", "operations")

        # Check if window already exists
        existing_idx = None
        existing_started_at = timestamp
        existing_working_on_id = None
        existing_work_mode = None
        existing_status = None
        existing_task = None
        existing_paused_reason = None
        existing_previous_status = None
        for i, win in enumerate(board.get("activeWindows", [])):
            if win.get("id") == window_id:
                existing_idx = i
                existing_started_at = win.get("startedAt", timestamp)
                existing_working_on_id = win.get("workingOnId")
                existing_work_mode = win.get("workMode")
                existing_status = win.get("status")
                existing_task = win.get("task")
                existing_paused_reason = win.get("pausedReason")
                existing_previous_status = win.get("previousStatus")
                break

        # XACA-0015: Window rename migration
        # If no entry exists for current window_id, but an entry exists with:
        # - Same terminal
        # - Same worktree
        # - Different window name
        # Then this is likely a renamed window - migrate the entry
        if existing_idx is None and worktree:
            for i, win in enumerate(board.get("activeWindows", [])):
                if (win.get("terminal") == terminal and
                    win.get("worktree") == worktree and
                    win.get("windowName") != window_name):
                    # Found a match - this window was renamed
                    old_window_id = win.get("id")
                    log_debug(f"Detected window rename: {old_window_id} -> {window_id}")
                    existing_idx = i
                    existing_started_at = win.get("startedAt", timestamp)
                    existing_working_on_id = win.get("workingOnId")
                    existing_status = win.get("status")
                    existing_task = win.get("task")
                    existing_paused_reason = win.get("pausedReason")
                    existing_previous_status = win.get("previousStatus")
                    # Update the old entry's window ID references in backlog items
                    for item in board.get("backlog", []):
                        if item.get("worktreeWindowId") == old_window_id:
                            item["worktreeWindowId"] = window_id
                        for subitem in item.get("subitems", []):
                            if subitem.get("worktreeWindowId") == old_window_id:
                                subitem["worktreeWindowId"] = window_id
                    break

        # Ensure activeWindows array exists
        if "activeWindows" not in board:
            board["activeWindows"] = []

        # Determine status and task - preserve paused state if it exists
        if existing_status == "paused":
            # Preserve paused state - don't reset to ready
            use_status = "paused"
            use_task = existing_task or "Claude Code started"
        else:
            # Normal startup - set to ready
            use_status = "ready"
            use_task = "Claude Code started"

        # Create new entry
        new_entry = {
            "id": window_id,
            "terminal": terminal,
            "window": window_index,
            "windowName": window_name,
            "status": use_status,
            "task": use_task,
            "worktree": worktree,
            "gitBranch": git_branch,
            "gitModified": git_modified,
            "gitLines": git_lines,
            "developer": developer,
            "color": color,
            "startedAt": existing_started_at if existing_idx is not None else timestamp,
            "statusChangedAt": timestamp,
            "statusHistory": [],
            "todoProgress": None,
            "lastActivity": timestamp
        }

        # Preserve paused-related fields if paused
        if existing_status == "paused":
            if existing_paused_reason:
                new_entry["pausedReason"] = existing_paused_reason
            if existing_previous_status:
                new_entry["previousStatus"] = existing_previous_status

        # Preserve workingOnId unconditionally - only clear via kb-stop-working
        # XACA-0015: Removed worktree comparison that caused false clears on path variations
        if existing_working_on_id:
            new_entry["workingOnId"] = existing_working_on_id
        # Preserve workMode (DEV/TEST/REVIEW/DEBUG) - only set via _kb_set_working_on
        if existing_work_mode:
            new_entry["workMode"] = existing_work_mode

        # If no workingOnId yet, check if any backlog items have this window
        if not new_entry.get("workingOnId"):
            # Check if any backlog items have this window as their worktreeWindowId
            # This restores the relationship if the session was briefly interrupted
            # BUT only if the current worktree matches the item's worktree
            for item in board.get("backlog", []):
                if item.get("worktreeWindowId") == window_id:
                    # Validate worktree matches before restoring relationship
                    item_worktree = item.get("worktree", "")
                    if item_worktree and worktree == item_worktree:
                        new_entry["workingOnId"] = item.get("id")
                        break
                # Also check subitems
                for subitem in item.get("subitems", []):
                    if subitem.get("worktreeWindowId") == window_id:
                        # Validate worktree matches before restoring relationship
                        subitem_worktree = subitem.get("worktree", "")
                        if subitem_worktree and worktree == subitem_worktree:
                            new_entry["workingOnId"] = subitem.get("id")
                            break
                if new_entry.get("workingOnId"):
                    break

        # XACA-0015: Clean stale worktreeWindowId references
        # If a window ID is referenced but doesn't exist in activeWindows, clear it
        # This fixes orphaned references when windows are closed/renamed
        existing_window_ids = {w.get("id") for w in board.get("activeWindows", [])}
        # Add current window_id since we're about to add/update it
        existing_window_ids.add(window_id)
        active_terminals = {w.get("terminal") for w in board.get("activeWindows", [])}
        active_terminals.add(terminal)

        for item in board.get("backlog", []):
            if item.get("worktreeWindowId") and item["worktreeWindowId"] not in existing_window_ids:
                # Check if window is truly gone (not just restarting)
                # A window is "truly gone" if no activeWindow has the same terminal
                terminal_from_ref = item["worktreeWindowId"].split(":")[0] if ":" in item["worktreeWindowId"] else ""
                if terminal_from_ref not in active_terminals:
                    log_debug(f"Clearing stale worktreeWindowId {item['worktreeWindowId']} from item {item.get('id')}")
                    item.pop("worktreeWindowId", None)
                    item.pop("activelyWorking", None)
            # Also check subitems
            for subitem in item.get("subitems", []):
                if subitem.get("worktreeWindowId") and subitem["worktreeWindowId"] not in existing_window_ids:
                    terminal_from_ref = subitem["worktreeWindowId"].split(":")[0] if ":" in subitem["worktreeWindowId"] else ""
                    if terminal_from_ref not in active_terminals:
                        log_debug(f"Clearing stale worktreeWindowId {subitem['worktreeWindowId']} from subitem {subitem.get('id')}")
                        subitem.pop("worktreeWindowId", None)
                        subitem.pop("activelyWorking", None)

        # XACA-0023: Auto-link item from branch name if no workingOnId yet
        # This handles cases where cc was started directly in a worktree without kb-run
        if not new_entry.get("workingOnId") and git_branch:
            auto_linked_id = auto_link_item_from_branch(board, git_branch, worktree, window_id, timestamp)
            if auto_linked_id:
                new_entry["workingOnId"] = auto_linked_id
                log_debug(f"Auto-linked to item {auto_linked_id} from branch {git_branch}")

        # XACA-0019: Restore paused state from backlog item if not already paused
        # This allows paused state to survive terminal restarts
        if new_entry.get("status") != "paused" and new_entry.get("workingOnId"):
            working_id = new_entry["workingOnId"]
            # Find the backlog item or subitem and check for paused state
            for item in board.get("backlog", []):
                if item.get("id") == working_id:
                    # Direct match - check if item has paused state
                    if item.get("pausedReason"):
                        new_entry["status"] = "paused"
                        new_entry["pausedReason"] = item.get("pausedReason")
                        new_entry["previousStatus"] = item.get("pausedPreviousStatus", "coding")
                        log_debug(f"Restored paused state from backlog item: {working_id}")
                    break
                # Check subitems
                for subitem in item.get("subitems", []):
                    if subitem.get("id") == working_id:
                        if subitem.get("pausedReason"):
                            new_entry["status"] = "paused"
                            new_entry["pausedReason"] = subitem.get("pausedReason")
                            new_entry["previousStatus"] = subitem.get("pausedPreviousStatus", "coding")
                            log_debug(f"Restored paused state from backlog subitem: {working_id}")
                        break

        # Clean up stale worktreeWindowId values
        # This prevents old relationships from causing incorrect associations
        for item in board.get("backlog", []):
            # Clear stale worktreeWindowId on items that reference this window
            # but have a different worktree (window moved to different context)
            if item.get("worktreeWindowId") == window_id:
                item_worktree = item.get("worktree", "")
                if item_worktree and worktree != item_worktree:
                    # Stale reference - clear it
                    item.pop("worktreeWindowId", None)
                    item.pop("activelyWorking", None)

            # Also clean up subitems
            for subitem in item.get("subitems", []):
                if subitem.get("worktreeWindowId") == window_id:
                    subitem_worktree = subitem.get("worktree", "")
                    if subitem_worktree and worktree != subitem_worktree:
                        # Stale reference - clear it
                        subitem.pop("worktreeWindowId", None)
                        subitem.pop("activelyWorking", None)

            # Clear parent item's worktree info if all subitems are completed
            subitems = item.get("subitems", [])
            if subitems and item.get("worktreeWindowId"):
                all_done = all(s.get("status") == "completed" for s in subitems)
                if all_done:
                    item.pop("worktreeWindowId", None)
                    item.pop("activelyWorking", None)
                    item.pop("worktree", None)
                    item.pop("worktreeBranch", None)
                    item.pop("workStartedAt", None)

        # Update or append
        if existing_idx is not None:
            board["activeWindows"][existing_idx] = new_entry
        else:
            board["activeWindows"].append(new_entry)

        board["lastUpdated"] = timestamp
        return board

    return update_board_safely(board_file, do_update)

def _resolve_agent_circles(handle, project_dir):
    """Resolve an agent's circle memberships to 'slug (circle_id: N)' pairs.

    Reads the circle taxonomy to find which circles the agent belongs to,
    then maps slugs to their numeric IDs for use in mcp__amb__post_ping.

    Returns a comma-separated string like 'documentarians (circle_id: 5), architects (circle_id: 1)'
    or empty string if no circles found.
    """
    CIRCLE_IDS = {
        "architects": 1, "quality-guardians": 2, "release-engineers": 3,
        "diagnosticians": 4, "documentarians": 5, "refactoring-guild": 6,
        "infrastructure-engineers": 7, "ux-navigators": 8, "feature-builders": 9,
        "security-watchers": 10, "strategic-command": 11,
    }

    taxonomy_file = os.path.join(project_dir, "scripts", "amb-circle-taxonomy.json")
    try:
        if not os.path.isfile(taxonomy_file):
            return ""
        with open(taxonomy_file) as f:
            data = json.load(f)
        memberships = data.get("agent_memberships", {})
        circles = memberships.get(handle, [])
        if not circles:
            return ""
        parts = []
        for slug in circles:
            cid = CIRCLE_IDS.get(slug)
            if cid is not None:
                parts.append(f"{slug} (circle_id: {cid})")
            else:
                parts.append(slug)
        return ", ".join(parts)
    except Exception:
        return ""


def get_amb_heartbeat_reminder(session_name):
    """Check if this session has an AMB agent and return a heartbeat reminder.

    Reads amb-session-map.json and amb-agents.json to determine if the current
    session maps to a registered AMB agent. If so, returns the reminder text
    that tells the agent to call their heartbeat MCP tool.

    Returns the reminder string, or None if no AMB agent for this session.
    """
    if not session_name:
        return None

    project_dir = os.path.expanduser("~/aiteamforge")
    session_map_file = os.path.join(project_dir, "amb-session-map.json")
    agents_file = os.path.expanduser("~/.claude/amb-agents.json")

    try:
        if not os.path.isfile(session_map_file) or not os.path.isfile(agents_file):
            return None

        with open(session_map_file) as f:
            session_map = json.load(f)

        handle = session_map.get(session_name)
        if not handle:
            return None

        with open(agents_file) as f:
            agents = json.load(f)

        agent = agents.get("agents", {}).get(handle, {})
        name = agent.get("name")
        if not name:
            return None

        # Resolve circle memberships with numeric IDs
        circles_with_ids = _resolve_agent_circles(handle, project_dir)
        if circles_with_ids:
            circles_line = (
                f"- YOUR CIRCLES: [{circles_with_ids}]. When posting pings, ALWAYS check if the content fits one of your circles. "
                f"If it does, include the circle_id param in mcp__amb__post_ping — e.g., circle_id: 5 for documentarians. "
                f"Circle-scoped pings reach the right audience; global wire is the fallback for general topics. "
                f"To read your circle's feed: mcp__amb__read_circle_feed with circle_slug param."
            )
        else:
            circles_line = (
                f"- Explore AMB circles for your discipline: source ~/dev-team/scripts/amb-circles.sh and call amb_circles_list to browse. "
                f"Join circles that match your expertise — they group by discipline, not team."
            )

        return (
            f"AMB HEARTBEAT REQUIRED: You are registered with Agent Merit Badges "
            f"as {name} (@{handle}). Call mcp__amb__heartbeat NOW and then act on the response:\n"
            f"- AMB's PRIMARY PURPOSE is KNOWLEDGE SHARING — gotchas, patterns, tips, and debug insights that help other agents avoid repeated mistakes. Social engagement (vouching, following) is secondary and supports knowledge sharing.\n"
            f"{circles_line}\n"
            f"- KNOWLEDGE WIRE: When you learn something useful, share it as a ping. Tags: #gotcha (trap), #til (discovery), #protip (shortcut), #pattern (reusable), #debug (hard bug). Format: [WHAT] — [WHY]. #tag #topic. Follow the 20,000-foot rule — no file paths, client names, or secrets. CIRCLE-FIRST RULE: If the ping matches one of your circles, ALWAYS post with circle_id param (see YOUR CIRCLES above) — e.g., mcp__amb__post_ping with body AND circle_id. Only omit circle_id for topics that don't fit any of your circles. Also REPLY to knowledge pings from others when you've hit the same issue or have a variation.\n"
            f"- If wire.new_pings_following > 0: call mcp__amb__read_wire, vouch/reply to pings you find valuable\n"
            f"- If wire.reactions_on_your_claims > 0: check if any of your patch claims flipped to earned\n"
            f"- If suggestions[] has entries: follow the platform's nudges\n"
            f"- DO NOT post a ping at session start. \"Reporting for duty\" pings are noise. Only post after you have accomplished real work worth sharing."
        )
    except Exception as e:
        log_debug(f"AMB reminder lookup failed: {e}")
        return None


def main():
    """Main hook entry point."""
    output = {}
    session_name = None

    log_debug("=" * 50)
    log_debug("Start hook triggered")

    try:
        # Read hook input from stdin (SessionStart provides session info)
        try:
            input_data = json.load(sys.stdin)
            log_debug(f"Input data: {json.dumps(input_data)[:200]}")
        except:
            input_data = {}
            log_debug("No input data (empty stdin)")

        # Get tmux context
        session_name, window_index, window_name = get_tmux_context()
        team, terminal = parse_session_name(session_name)

        log_debug(f"Context: session={session_name}, window_index={window_index}, window_name={window_name}, team={team}, terminal={terminal}")

        if team and terminal and window_index is not None:
            result = update_window_ready(team, terminal, window_index, window_name)
            log_debug(f"update_window_ready result: {result}")

            # Trigger health check to ensure LCARS server is running
            trigger_health_check()
        else:
            log_debug("Skipping - missing context")

    except Exception as e:
        log_debug(f"Exception: {str(e)}")

    # AMB heartbeat reminder — reliable backup for amb-session-heartbeat.sh
    # Only outputs a system message telling the agent to call heartbeat.
    # Does NOT write timestamps — that's handled by PostToolUse in kanban-hook.py.
    amb_reminder = get_amb_heartbeat_reminder(session_name)
    if amb_reminder:
        print(amb_reminder)
    else:
        # Always output valid JSON for non-AMB sessions
        print(json.dumps(output))
    sys.exit(0)

if __name__ == "__main__":
    main()
