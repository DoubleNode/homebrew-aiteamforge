#!/usr/bin/env python3
"""
Kanban Hook for Claude Code
Automatically updates kanban board status based on tool usage.

Window-Based Tracking:
- Each tmux window gets its own entry in activeWindows
- Windows are identified by session:window_name
- Includes git worktree information

Tool to Status Mapping:
- SessionStart → ready (Claude Code started)
- Read, Glob, Grep, Task, EnterPlanMode → planning (researching/investigating)
- Edit, Write, NotebookEdit → coding (implementing)
- Bash (with test/pytest) → testing
- Bash (with git commit) → commit
- Bash (with gh pr create) → pr_review (awaiting review)
- Bash (with gh pr merge/close) → removed from activeWindows (task complete)
- Stop (Claude Code exit) → removed from activeWindows (session over)
"""

import json
import os
import sys
import subprocess
import re
from datetime import datetime, timezone

# Add kanban-hooks directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kanban_utils import get_board_file, read_board_safely, update_board_safely, parse_session_name

# Configuration
KANBAN_DIR = os.path.expanduser("~/aiteamforge/kanban")

def _resolve_amb_handle_from_tmux():
    """Resolve the AMB agent handle from the current tmux session name.

    Uses amb-session-map.json to map session names (e.g., 'android-helm')
    to AMB handles (e.g., 'sulu'). Returns None if not in tmux or unmapped.
    """
    try:
        pane_target = os.environ.get("TMUX_PANE", "")
        tmux_cmd = ["tmux", "display-message"]
        if pane_target:
            tmux_cmd.extend(["-t", pane_target])
        tmux_cmd.extend(["-p", "#S"])
        result = subprocess.run(tmux_cmd, capture_output=True, text=True, timeout=2)
        if result.returncode != 0:
            return None
        session_name = result.stdout.strip()
        if not session_name:
            return None

        session_map_file = os.path.expanduser("~/aiteamforge/amb-session-map.json")
        if not os.path.isfile(session_map_file):
            return None
        with open(session_map_file) as f:
            session_map = json.load(f)
        return session_map.get(session_name)
    except Exception:
        return None


def get_tmux_context():
    """Get current tmux session name, window index, and window name."""
    try:
        pane_target = os.environ.get("TMUX_PANE", "")
        tmux_cmd_base = ["tmux", "display-message"]
        if pane_target:
            tmux_cmd_base = ["tmux", "display-message", "-t", pane_target]
        # Get session name
        session_result = subprocess.run(
            tmux_cmd_base + ["-p", "#S"],
            capture_output=True,
            text=True,
            timeout=2
        )
        # Get window index
        window_idx_result = subprocess.run(
            tmux_cmd_base + ["-p", "#I"],
            capture_output=True,
            text=True,
            timeout=2
        )
        # Get window name
        window_name_result = subprocess.run(
            tmux_cmd_base + ["-p", "#W"],
            capture_output=True,
            text=True,
            timeout=2
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
            capture_output=True,
            text=True,
            timeout=2
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
            capture_output=True,
            text=True,
            timeout=2
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
            capture_output=True,
            text=True,
            timeout=2
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
            capture_output=True,
            text=True,
            timeout=2
        )
        if result.returncode == 0:
            added = 0
            deleted = 0
            for line in result.stdout.strip().split('\n'):
                if line:
                    parts = line.split('\t')
                    if len(parts) >= 2:
                        # Handle binary files (shows as -)
                        if parts[0] != '-':
                            added += int(parts[0])
                        if parts[1] != '-':
                            deleted += int(parts[1])
            return {"added": added, "deleted": deleted}
    except Exception:
        pass
    return {"added": 0, "deleted": 0}

# parse_session_name is now imported from kanban_utils

def read_board(team):
    """Read the kanban board for a team using safe locking."""
    board_file = get_board_file(team)
    return read_board_safely(board_file)

def get_window_entry(board, window_id):
    """Get existing window entry from activeWindows."""
    if not board:
        return None
    for win in board.get("activeWindows", []):
        if win.get("id") == window_id:
            return win
    return None

def remove_window(team, terminal, window_name):
    """Remove a window entry from activeWindows (task complete)."""
    board_file = get_board_file(team)

    if not os.path.exists(board_file):
        return False

    window_id = f"{terminal}:{window_name}"
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def do_remove(board):
        # Find and remove the window entry
        original_len = len(board.get("activeWindows", []))
        board["activeWindows"] = [
            win for win in board.get("activeWindows", [])
            if win.get("id") != window_id
        ]

        # Only update if we actually removed something
        if len(board.get("activeWindows", [])) < original_len:
            board["lastUpdated"] = timestamp
            return board
        return None  # No changes needed

    return update_board_safely(board_file, do_remove)

def extract_item_id_from_branch(branch_name):
    """
    Extract a potential item ID from a git branch name.

    Examples:
        feature/xaca-0012 -> XACA-0012
        feature/xfsw-0007 -> XFSW-0007
        bugfix/xfre-0001-fix-crash -> XFRE-0001

    Returns the uppercase item ID or None if no match.
    """
    if not branch_name:
        return None

    # Match patterns like xaca-0012, xfsw-0007, xfre-0001, etc.
    match = re.search(r'([a-zA-Z]{4})-(\d{4})', branch_name)
    if match:
        prefix = match.group(1).upper()
        number = match.group(2)
        return f"{prefix}-{number}"
    return None

def auto_link_item_from_branch(board, branch_name, worktree, window_id, timestamp):
    """
    Auto-link a backlog item based on the current git branch name.
    Returns the item ID if linked, None otherwise.
    """
    item_id = extract_item_id_from_branch(branch_name)
    if not item_id:
        return None

    # Find the item in backlog
    for item in board.get("backlog", []):
        if item.get("id") == item_id:
            existing_window = item.get("worktreeWindowId")
            if existing_window and existing_window != window_id:
                return None  # Already linked to different window

            if not item.get("activelyWorking"):
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

    # Check subitems
    for item in board.get("backlog", []):
        for subitem in item.get("subitems", []):
            if subitem.get("id") == item_id:
                existing_window = subitem.get("worktreeWindowId")
                if existing_window and existing_window != window_id:
                    return None

                if not subitem.get("activelyWorking"):
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

    return None

def update_window(team, terminal, window_index, window_name, task_status, task=None, todo_progress=None):
    """Update or create a window entry in activeWindows using atomic writes."""
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
        nonlocal task  # Allow modification of task

        # Get developer info from terminals config
        developer = "Unknown"
        color = "operations"
        if terminal in board.get("terminals", {}):
            developer = board["terminals"][terminal].get("developer", "Unknown")
            color = board["terminals"][terminal].get("color", "operations")

        # Find existing window entry
        existing_entry = None
        existing_idx = None
        existing_working_on_id = None
        existing_work_mode = None
        for i, win in enumerate(board.get("activeWindows", [])):
            if win.get("id") == window_id:
                existing_entry = win
                existing_idx = i
                existing_working_on_id = win.get("workingOnId")
                existing_work_mode = win.get("workMode")
                break

        # Track status history and timing
        status_history = []
        status_changed_at = timestamp
        current_todo_progress = None

        if existing_entry:
            current_status = existing_entry.get("status", "")
            current_task = existing_entry.get("task", "")
            status_history = list(existing_entry.get("statusHistory", []))  # Copy list
            current_todo_progress = existing_entry.get("todoProgress")

            # Check if status changed
            if current_status != task_status:
                # Add to history if not already the last entry
                if not status_history or status_history[-1] != current_status:
                    status_history.append(current_status)
                status_changed_at = timestamp
            else:
                # Preserve existing statusChangedAt
                status_changed_at = existing_entry.get("statusChangedAt", timestamp)

            # Skip update if nothing changed (but still update git info)
            if current_status == task_status and (not task or current_task == task) and not todo_progress:
                # Still update git stats even if nothing else changed
                existing_entry["gitModified"] = git_modified
                existing_entry["gitLines"] = git_lines
                existing_entry["lastActivity"] = timestamp
                board["lastUpdated"] = timestamp
                return board

            # Preserve task if not provided
            if not task:
                task = current_task

        # Use provided todo_progress or preserve existing
        final_todo_progress = todo_progress if todo_progress else current_todo_progress

        # Ensure activeWindows array exists
        if "activeWindows" not in board:
            board["activeWindows"] = []

        # Create new/updated entry
        new_entry = {
            "id": window_id,
            "terminal": terminal,
            "window": window_index,
            "windowName": window_name,
            "status": task_status,
            "task": task or "",
            "worktree": worktree,
            "gitBranch": git_branch,
            "gitModified": git_modified,
            "gitLines": git_lines,
            "developer": developer,
            "color": color,
            "startedAt": existing_entry.get("startedAt", timestamp) if existing_entry else timestamp,
            "statusChangedAt": status_changed_at,
            "statusHistory": status_history,
            "todoProgress": final_todo_progress,
            "lastActivity": timestamp
        }

        # Preserve workingOnId unconditionally - only clear via kb-stop-working
        # XACA-0015: Removed worktree comparison that caused false clears on path variations
        if existing_working_on_id:
            new_entry["workingOnId"] = existing_working_on_id
        # Preserve workMode (DEV/TEST/REVIEW/DEBUG) - only set via _kb_set_working_on
        if existing_work_mode:
            new_entry["workMode"] = existing_work_mode

        # XACA-0023: Auto-link item from branch name if no workingOnId yet
        if not new_entry.get("workingOnId") and git_branch:
            auto_linked_id = auto_link_item_from_branch(board, git_branch, worktree, window_id, timestamp)
            if auto_linked_id:
                new_entry["workingOnId"] = auto_linked_id

        # Update or append
        if existing_idx is not None:
            board["activeWindows"][existing_idx] = new_entry
        else:
            board["activeWindows"].append(new_entry)

        board["lastUpdated"] = timestamp
        return board

    return update_board_safely(board_file, do_update)

def extract_task_from_file_path(file_path):
    """Extract a meaningful task name from a file path."""
    if not file_path:
        return None

    # Get just the filename
    filename = os.path.basename(file_path)

    # Remove common extensions
    name = re.sub(r'\.(swift|kt|ts|js|py|json|md|sh|yaml|yml|xml)$', '', filename, flags=re.I)

    # Convert to readable format
    # CamelCase to spaces
    name = re.sub(r'([a-z])([A-Z])', r'\1 \2', name)
    # snake_case to spaces
    name = name.replace('_', ' ').replace('-', ' ')

    # Capitalize first letter
    if name:
        name = name[0].upper() + name[1:]

    # Truncate if too long
    if len(name) > 40:
        name = name[:37] + "..."

    return name if name else None

def extract_task_from_todos(todos):
    """Extract task name from TodoWrite input."""
    if not todos:
        return None

    # Find in_progress todos
    in_progress = [t for t in todos if t.get("status") == "in_progress"]
    if in_progress:
        content = in_progress[0].get("content", "")
        if content:
            # Truncate if needed
            if len(content) > 50:
                return content[:47] + "..."
            return content

    return None

def extract_task_from_bash(command):
    """Extract a meaningful task from a bash command."""
    if not command:
        return None

    # Git commit - extract message
    # Handle HEREDOC format: git commit -m "$(cat <<'EOF'\nActual message\nEOF\n)"
    if "git commit" in command and "-m" in command:
        # Try HEREDOC format first (look for actual message after EOF marker line)
        heredoc_match = re.search(r"<<'?EOF'?\s*\n(.+?)(?:\n|$)", command, re.DOTALL)
        if heredoc_match:
            # Get first line of actual commit message
            first_line = heredoc_match.group(1).split('\n')[0].strip()
            if first_line and not first_line.startswith('EOF'):
                return f"Commit: {first_line[:120]}"

        # Fallback to simple quoted format
        simple_match = re.search(r'-m\s*["\']([^"\']+)["\']', command)
        if simple_match:
            msg = simple_match.group(1)
            if not msg.startswith("$(cat"):
                return f"Commit: {msg[:120]}"

        return "Committing changes"

    # Test commands
    if any(x in command for x in ["pytest", "npm test", "yarn test", "swift test"]):
        return "Running tests"

    # Build commands
    if any(x in command for x in ["xcodebuild", "gradle", "npm run build", "swift build"]):
        return "Building project"

    return None

def determine_status_and_task(input_data, current_board, terminal, window_name):
    """
    Determine kanban status and task based on tool being used.
    Returns (status, task, todo_progress) or (None, None, None) if no update needed.
    """
    tool_name = input_data.get("tool_name", "")
    tool_input = input_data.get("tool_input", {})

    # Get current task (we might want to preserve it)
    window_id = f"{terminal}:{window_name}"
    current_task = ""
    current_status = ""

    if current_board:
        for win in current_board.get("activeWindows", []):
            if win.get("id") == window_id:
                current_task = win.get("task", "")
                current_status = win.get("status", "")
                break

    # === PAUSED STATUS PROTECTION ===
    # If status is "paused", preserve it - only manual intervention (kb-resume) can unpause
    # This prevents automatic status changes from accidentally resuming items
    if current_status == "paused":
        return "paused", current_task, None

    # === PLANNING PHASE ===
    # EnterPlanMode → planning (formal plan mode)
    if tool_name == "EnterPlanMode":
        return "planning", current_task or "Planning approach", None

    # Read, Glob, Grep → planning (researching/investigating)
    # Only transition to planning if currently at "ready" status
    if tool_name in ["Read", "Glob", "Grep"]:
        if current_status == "ready" or not current_status:
            file_path = tool_input.get("file_path", "") or tool_input.get("pattern", "")
            task = extract_task_from_file_path(file_path) if file_path else None
            return "planning", task or current_task or "Investigating", None
        # If already past planning (coding, testing, etc.), don't regress
        return None, None, None

    # Task tool (spawning agents for research) → planning
    if tool_name == "Task":
        if current_status in ["ready", "planning", ""] or not current_status:
            prompt = tool_input.get("prompt", "")
            # Extract first few words as task description
            task = prompt[:50] + "..." if len(prompt) > 50 else prompt
            return "planning", task or current_task or "Researching", None
        return None, None, None

    # === CODING PHASE ===
    # ExitPlanMode → coding (plan approved, ready to implement)
    if tool_name == "ExitPlanMode":
        return "coding", current_task or "Implementing plan", None

    # Edit, Write, NotebookEdit → coding
    if tool_name in ["Edit", "Write", "NotebookEdit", "MultiEdit"]:
        file_path = tool_input.get("file_path", "")
        task = extract_task_from_file_path(file_path)

        # If we already have a task, prefer keeping it unless file gives good context
        if current_task and (not task or len(task) < 5):
            task = current_task

        return "coding", task or "Editing files", None

    # TodoWrite - extract task from in_progress item and calculate progress
    if tool_name == "TodoWrite":
        todos = tool_input.get("todos", [])
        task = extract_task_from_todos(todos)

        # Calculate todo progress
        todo_progress = None
        if todos:
            completed = sum(1 for t in todos if t.get("status") == "completed")
            total = len(todos)
            todo_progress = {"completed": completed, "total": total}

        if task:
            # Check if any todos are in_progress
            has_in_progress = any(t.get("status") == "in_progress" for t in todos)
            if has_in_progress:
                # Only move to coding if we have actual work happening
                if current_status in ["ready", "planning", ""]:
                    return "planning", task, todo_progress  # Still planning if just writing todos
                return None, None, todo_progress  # Keep current status but update progress

        # When all todos are completed, just update progress but don't change status
        # The task isn't truly "done" until user explicitly marks it (kb-done or PR merge)
        # This prevents cards from vanishing from the Workflow view
        return None, None, todo_progress

    # === TESTING/COMMIT/PR PHASES ===
    # Bash commands need inspection
    if tool_name == "Bash":
        command = tool_input.get("command", "")

        # PR merge/close → remove from activeWindows (task complete)
        if "gh pr merge" in command or "gh pr close" in command:
            return "remove", current_task or "PR closed", None

        # PR create → awaiting review
        if "gh pr create" in command:
            return "pr_review", current_task or "Awaiting PR review", None

        # Git commit → commit phase
        if "git commit" in command:
            task = extract_task_from_bash(command)
            return "commit", task or "Committing changes", None

        # Git push → pr_review (typically followed by PR)
        if "git push" in command:
            return "commit", current_task or "Pushed changes", None

        # Test commands → testing
        test_indicators = [
            "pytest", "python -m pytest",
            "npm test", "yarn test", "npm run test",
            "xcodebuild test", "xctest",
            "gradle test", "./gradlew test",
            "swift test",
            "go test",
            "cargo test",
            "jest", "mocha", "vitest"
        ]
        for indicator in test_indicators:
            if indicator in command:
                return "testing", current_task or "Running tests", None

        # Build commands → coding (building is part of coding)
        build_indicators = [
            "xcodebuild", "gradle", "npm run build",
            "swift build", "cargo build", "go build"
        ]
        for indicator in build_indicators:
            if indicator in command:
                return "coding", current_task or "Building project", None

        # Git status, diff, log → planning (if still early)
        if current_status in ["ready", "planning", ""] and any(x in command for x in ["git status", "git diff", "git log"]):
            return "planning", current_task or "Reviewing changes", None

    return None, None, None

def main():
    """Main hook entry point."""
    output = {}

    try:
        # Read hook input from stdin
        input_data = json.load(sys.stdin)

        # AMB heartbeat detection — write local timestamp when MCP heartbeat is called
        # File read by agent-panel-display.sh to show "heartbeat Xm ago" on the panel
        # Uses .last_heartbeat_time_ (NOT .last_ping_time_ which is owned by amb scripts)
        # Note: amb-proxy.py also writes this timestamp on successful heartbeat calls,
        # so this hook serves as a redundant write for per-handle MCP servers.
        tool_name = input_data.get("tool_name", "")
        if "heartbeat" in tool_name and tool_name.startswith("mcp__amb"):
            try:
                handle = None
                parts = tool_name.split("__")
                if len(parts) >= 3 and parts[1].startswith("amb-"):
                    # Per-handle server: mcp__amb-jett-reno__heartbeat -> jett-reno
                    handle = parts[1].replace("amb-", "", 1)
                elif parts[1] == "amb":
                    # Global "amb" server: resolve handle from tmux session
                    handle = _resolve_amb_handle_from_tmux()
                if handle:
                    ts_file = os.path.expanduser(f"~/.claude/.last_heartbeat_time_{handle}")
                    with open(ts_file, "w") as f:
                        f.write(str(int(datetime.now(timezone.utc).timestamp())))
            except Exception:
                pass

        # Get tmux context (session, window index, window name)
        session_name, window_index, window_name = get_tmux_context()
        team, terminal = parse_session_name(session_name)

        if not team or not terminal or window_index is None:
            # Not in a recognized terminal session
            print(json.dumps(output))
            sys.exit(0)

        # Note: Stop events are handled by kanban-stop.py, not this PostToolUse hook
        # The Stop hook has proper age checking to prevent false removals

        # Read current board state
        current_board = read_board(team)

        # Determine if we need to update status
        new_status, task, todo_progress = determine_status_and_task(
            input_data, current_board, terminal, window_name
        )

        if new_status or todo_progress:
            if new_status == "remove":
                # PR merged/closed - remove from activeWindows
                success = remove_window(team, terminal, window_name)
            else:
                # Determine fallback status: preserve current status if available, else "ready"
                # This prevents accidentally overwriting paused or other statuses
                fallback_status = "ready"
                if current_board:
                    window_id = f"{terminal}:{window_name}"
                    for win in current_board.get("activeWindows", []):
                        if win.get("id") == window_id:
                            fallback_status = win.get("status", "ready")
                            break

                success = update_window(
                    team, terminal, window_index, window_name,
                    new_status or fallback_status, task, todo_progress
                )
            # Optionally log success (commented to avoid noise)
            # if success:
            #     output["systemMessage"] = f"Kanban: {terminal}:{window_name} → {new_status}"

    except Exception as e:
        # Silent failure - don't interrupt Claude's work
        # Uncomment for debugging:
        # output["systemMessage"] = f"Kanban hook error: {str(e)}"
        pass

    # Always output valid JSON
    print(json.dumps(output))
    sys.exit(0)

if __name__ == "__main__":
    main()
