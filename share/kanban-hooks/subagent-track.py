#!/usr/bin/env python3

#
#  subagent-track.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

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
  start            - PreToolUse: add subagent_type to tracking file (deduplicated)
  stop             - PostToolUse: remove subagent_type (skipped for background agents)
  remove           - CLI: remove agent_type passed as argv[2] (for subagent self-removal)
  cleanup_if_empty - Stop event: remove tracking file ONLY if it has no
                     active entries. Background agents launched in the turn
                     that is now ending will still be tracked and must stay
                     visible on the panel until they actually complete.
  cleanup          - SessionEnd event (and legacy Stop fallback): force-remove
                     the tracking file and its sidecars regardless of contents.
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


def cleanup_window_path(filepath):
    """Force-remove a tracking file and its lock/tmp sidecars.

    Used by SessionEnd (and the legacy ``cleanup`` action) when the Claude
    session is actually going away. Ignores active entries — nothing should
    still be reading the file after this point.
    """
    for f in [filepath, filepath + ".lock", filepath + ".tmp"]:
        try:
            os.remove(f)
        except OSError:
            pass


def cleanup_window_if_empty_path(filepath):
    """Remove the tracking file only if it holds no active subagent entries.

    Used by the Stop hook, which fires at the end of every assistant turn.
    A long-running background subagent launched during the turn that is now
    ending MUST stay tracked — deleting its entry here would hide it from the
    agent panel for the rest of its lifetime. So we only clean up when the
    file is empty (all tracked subagents already completed via the normal
    PostToolUse remove path) or when the file is unreadable garbage.
    """
    try:
        with open(filepath, "r") as f:
            data = json.load(f)
        if isinstance(data, list) and len(data) > 0:
            return  # Active entries — Stop hook must leave them alone.
    except (OSError, json.JSONDecodeError):
        # OSError covers FileNotFoundError, PermissionError, and other fs
        # failures — consistent with cleanup_window_path. Missing file is
        # fine; unreadable file is garbage we should sweep.
        pass
    cleanup_window_path(filepath)


def cleanup_window(session_name, window_index):
    """Force-remove the tracking file for this session/window."""
    cleanup_window_path(tracking_file_path(session_name, window_index))


def cleanup_window_if_empty(session_name, window_index):
    """Remove the tracking file only if no active subagent entries remain."""
    cleanup_window_if_empty_path(
        tracking_file_path(session_name, window_index)
    )


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

    elif action == "cleanup_if_empty":
        # Stop-hook path: only prune the file if no background agents are
        # still tracked. Preserves long-running test/review bots that will
        # outlive the parent's current turn.
        cleanup_window_if_empty(session_name, window_index)

    elif action == "cleanup":
        # SessionEnd-hook path (and legacy Stop fallback): force-remove.
        cleanup_window(session_name, window_index)

    print(json.dumps({}))
    sys.exit(0)


if __name__ == "__main__":
    main()
