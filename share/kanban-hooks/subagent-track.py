#!/usr/bin/env python3
"""
Subagent Tracker Hook for Claude Code

Tracks Task tool subagent lifecycle for LCARS agent panel display.
Writes active subagent list to <kanban/tmp>/lcars-subagents-{session}-w{window}.json
so agent-panel-display.sh can render crew avatars.

The tmp directory is team-specific, resolved via get_lcars_tmp_dir() from the
tmux session name. Falls back to /tmp/ for unknown sessions or teams.

Format: [{"type": "reno"}, {"type": "nahla"}, ...]
Shows actively running subagents. Removed on completion (foreground only).
Background agents persist until session cleanup since their completion
notification doesn't trigger a PostToolUse hook.

Actions:
  start   - PreToolUse: add subagent_type to tracking file (deduplicated)
  stop    - PostToolUse: remove subagent_type (skipped for background agents)
  remove  - CLI: remove agent_type passed as argv[2] (for subagent self-removal)
  cleanup - Stop event: remove tracking file for this window
"""

import json
import os
import sys
import subprocess
import fcntl
import glob

from kanban_utils import get_lcars_tmp_dir


def get_tmux_context():
    """Get tmux session name and window index."""
    try:
        pane_target = os.environ.get("TMUX_PANE", "")
        tmux_cmd_base = ["tmux", "display-message"]
        if pane_target:
            tmux_cmd_base = ["tmux", "display-message", "-t", pane_target]
        session = subprocess.run(
            tmux_cmd_base + ["-p", "#S"],
            capture_output=True, text=True, timeout=2
        )
        window_idx = subprocess.run(
            tmux_cmd_base + ["-p", "#I"],
            capture_output=True, text=True, timeout=2
        )
        if session.returncode == 0 and window_idx.returncode == 0:
            return session.stdout.strip(), window_idx.stdout.strip()
    except Exception:
        pass
    return None, None


def tracking_file_path(session_name, window_index):
    """Build tracking file path for this session/window.

    Resolves the tmp directory from the session name via get_lcars_tmp_dir(),
    placing files in the team's kanban/tmp/ directory rather than /tmp/.
    Lock files (.json.lock) and temp files (.json.tmp) are derived from the
    returned path and land in the same directory.
    """
    tmp_dir = get_lcars_tmp_dir(session_name)
    return f"{tmp_dir}lcars-subagents-{session_name}-w{window_index}.json"


def locked_update(filepath, update_fn):
    """Atomic read-modify-write with file locking."""
    lockfile = filepath + ".lock"
    with open(lockfile, "w") as lf:
        fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
        try:
            try:
                with open(filepath, "r") as f:
                    data = json.load(f)
                if not isinstance(data, list):
                    data = []
            except (FileNotFoundError, json.JSONDecodeError):
                data = []

            # Migrate legacy format: plain strings → objects
            data = [
                {"type": e} if isinstance(e, str)
                else e for e in data
                if isinstance(e, str) or (isinstance(e, dict) and "type" in e)
            ]

            data = update_fn(data)

            tmp = filepath + ".tmp"
            with open(tmp, "w") as f:
                json.dump(data, f)
            os.rename(tmp, filepath)
        finally:
            fcntl.flock(lf.fileno(), fcntl.LOCK_UN)


def add_agent(filepath, agent_type):
    """Add agent type to tracking list if not already present."""
    def updater(agents):
        if agent_type not in {a.get("type") for a in agents}:
            agents.append({"type": agent_type})
        return agents
    locked_update(filepath, updater)


def remove_agent(filepath, agent_type):
    """Remove first occurrence of agent type from tracking list."""
    def updater(agents):
        for i, entry in enumerate(agents):
            if entry.get("type") == agent_type:
                agents.pop(i)
                break
        return agents
    locked_update(filepath, updater)


def cleanup_window(session_name, window_index):
    """Remove tracking file for this specific session/window only."""
    filepath = tracking_file_path(session_name, window_index)
    for f in [filepath, filepath + ".lock", filepath + ".tmp"]:
        try:
            os.remove(f)
        except OSError:
            pass


def is_background_launch(tool_response):
    """Check if the PostToolUse response indicates a background agent launch.

    Background agents fire PostToolUse immediately on launch (not completion),
    so we must skip removal to keep the crew avatar visible while it runs.
    """
    if isinstance(tool_response, dict):
        return tool_response.get("isAsync") is True
    return False


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "unknown"

    try:
        input_data = json.load(sys.stdin)
    except Exception:
        input_data = {}

    session_name, window_index = get_tmux_context()
    if not session_name or not window_index:
        print(json.dumps({}))
        sys.exit(0)

    if action == "start":
        agent_type = input_data.get("tool_input", {}).get("subagent_type", "")
        if agent_type:
            add_agent(tracking_file_path(session_name, window_index), agent_type)

    elif action == "stop":
        agent_type = input_data.get("tool_input", {}).get("subagent_type", "")
        tool_response = input_data.get("tool_response", {})
        bg = is_background_launch(tool_response)
        if agent_type and not bg:
            remove_agent(tracking_file_path(session_name, window_index), agent_type)

    elif action == "remove":
        # CLI-driven removal: subagents call this directly before completing.
        # Usage: python3 subagent-track.py remove <agent_type>
        agent_type = sys.argv[2] if len(sys.argv) > 2 else ""
        if agent_type:
            remove_agent(tracking_file_path(session_name, window_index), agent_type)

    elif action == "cleanup":
        cleanup_window(session_name, window_index)

    print(json.dumps({}))
    sys.exit(0)


if __name__ == "__main__":
    main()
