# /// script
# requires-python = ">=3.8"
# dependencies = ["pyyaml"]
# ///
"""
Claude Code Edit Tool Damage Control
=====================================

Blocks edits to protected files via PreToolUse hook on Edit tool.
Loads zeroAccessPaths, readOnlyPaths, and kanbanProtectedPaths from patterns.yaml.

Features:
  - Path-based protection (zero-access, read-only)
  - Kanban board item deletion prevention (content-aware)

Exit codes:
  0 = Allow edit
  2 = Block edit (stderr fed back to Claude)
"""

import json
import sys
import os
import re
import fnmatch
from pathlib import Path
from typing import Dict, Any, List, Tuple, Optional, Set

import yaml


def is_glob_pattern(pattern: str) -> bool:
    """Check if pattern contains glob wildcards."""
    return '*' in pattern or '?' in pattern or '[' in pattern


def match_path(file_path: str, pattern: str) -> bool:
    """Match file path against pattern, supporting both prefix and glob matching."""
    expanded_pattern = os.path.expanduser(pattern)
    normalized = os.path.normpath(file_path)
    expanded_normalized = os.path.expanduser(normalized)

    if is_glob_pattern(pattern):
        # Glob pattern matching (case-insensitive for security)
        basename = os.path.basename(expanded_normalized)
        basename_lower = basename.lower()
        pattern_lower = pattern.lower()
        expanded_pattern_lower = expanded_pattern.lower()

        # Match against basename for patterns like *.pem, .env*
        if fnmatch.fnmatch(basename_lower, expanded_pattern_lower):
            return True
        if fnmatch.fnmatch(basename_lower, pattern_lower):
            return True
        # Also try full path match for patterns like /path/*.pem
        if fnmatch.fnmatch(expanded_normalized.lower(), expanded_pattern_lower):
            return True
        return False
    else:
        # Prefix matching (original behavior for directories)
        if expanded_normalized.startswith(expanded_pattern) or expanded_normalized == expanded_pattern.rstrip('/'):
            return True
        return False


def get_config_path() -> Path:
    """Get path to patterns.yaml, checking multiple locations."""
    # 1. Check project hooks directory (installed location)
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR")
    if project_dir:
        project_config = Path(project_dir) / ".claude" / "hooks" / "damage-control" / "patterns.yaml"
        if project_config.exists():
            return project_config

    # 2. Check script's own directory (installed location)
    script_dir = Path(__file__).parent
    local_config = script_dir / "patterns.yaml"
    if local_config.exists():
        return local_config

    # 3. Check skill root directory (development location)
    skill_root = script_dir.parent.parent / "patterns.yaml"
    if skill_root.exists():
        return skill_root

    return local_config  # Default, even if it doesn't exist


def load_config() -> Dict[str, Any]:
    """Load config from YAML."""
    config_path = get_config_path()

    if not config_path.exists():
        return {"zeroAccessPaths": [], "readOnlyPaths": []}

    with open(config_path, "r") as f:
        config = yaml.safe_load(f) or {}

    return config


def check_path(file_path: str, config: Dict[str, Any]) -> Tuple[bool, str]:
    """Check if file_path is blocked. Returns (blocked, reason)."""
    # Check zero-access paths first (no access at all)
    for zero_path in config.get("zeroAccessPaths", []):
        if match_path(file_path, zero_path):
            return True, f"zero-access path {zero_path} (no operations allowed)"

    # Check read-only paths (edits not allowed)
    for readonly in config.get("readOnlyPaths", []):
        if match_path(file_path, readonly):
            return True, f"read-only path {readonly}"

    return False, ""


# ---------------------------------------------------------------------------
# Kanban Board Item Deletion Protection
# ---------------------------------------------------------------------------

def is_kanban_board(file_path: str, config: Dict[str, Any]) -> bool:
    """Check if file is a kanban board file."""
    for pattern in config.get("kanbanProtectedPaths", []):
        if match_path(file_path, pattern):
            return True
    return False


def extract_ids(content: str) -> Set[str]:
    """Extract all 'id' field values from JSON content using regex.

    Matches the literal key "id" (not workingOnId, nextId, etc.)
    and extracts the string value. Fast regex approach avoids
    full JSON parsing for large board files.
    """
    return set(re.findall(r'"id"\s*:\s*"([^"]+)"', content))


def check_kanban_edit_deletion(
    file_path: str, old_string: str, new_string: str, replace_all: bool
) -> Tuple[bool, str]:
    """Check if an edit would delete kanban items by simulating the replacement.

    Returns (blocked, reason). If blocked, reason contains the
    error message with instructions for authorization.
    """
    if not os.path.exists(file_path):
        return False, ""  # New file, nothing to protect

    try:
        with open(file_path, "r") as f:
            existing_content = f.read()
    except (IOError, OSError):
        return False, ""  # Can't read existing file, allow

    # Simulate the edit
    if replace_all:
        new_content = existing_content.replace(old_string, new_string)
    else:
        new_content = existing_content.replace(old_string, new_string, 1)

    existing_ids = extract_ids(existing_content)
    new_ids = extract_ids(new_content)
    missing_ids = existing_ids - new_ids

    if not missing_ids:
        return False, ""  # No items removed

    # Check for authorization files
    unauthorized: Set[str] = set()
    authorized: Set[str] = set()
    for item_id in missing_ids:
        auth_file = f"/tmp/kanban-allow-removal-{item_id}"
        if os.path.exists(auth_file):
            authorized.add(item_id)
        else:
            unauthorized.add(item_id)

    if not unauthorized:
        # All removals authorized — consume the tokens
        for item_id in authorized:
            try:
                os.remove(f"/tmp/kanban-allow-removal-{item_id}")
            except OSError:
                pass
        return False, ""

    # Build block message
    lines = [
        f"KANBAN PROTECTION: Edit to {os.path.basename(file_path)} would "
        f"remove {len(missing_ids)} item/subitem ID(s).",
        "",
    ]
    for item_id in sorted(unauthorized):
        lines.append(f"  - {item_id}")
    lines.append("")
    lines.append("Items must NEVER be deleted from kanban boards.")
    lines.append("To mark items as done, set their 'status' to 'completed'.")
    lines.append("")
    lines.append("If removal is truly intentional, authorize each ID first:")
    for item_id in sorted(unauthorized):
        lines.append(f"  touch /tmp/kanban-allow-removal-{item_id}")
    lines.append("")
    lines.append("Auth files are single-use and consumed after the write.")

    return True, "\n".join(lines)


def main() -> None:
    config = load_config()

    # Read hook input from stdin
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON input: {e}", file=sys.stderr)
        sys.exit(1)

    tool_name = input_data.get("tool_name", "")
    tool_input = input_data.get("tool_input", {})

    # Only check Edit tool
    if tool_name != "Edit":
        sys.exit(0)

    file_path = tool_input.get("file_path", "")
    if not file_path:
        sys.exit(0)

    # Path-based protection (zero-access, read-only)
    blocked, reason = check_path(file_path, config)
    if blocked:
        print(f"SECURITY: Blocked edit to {reason}: {file_path}", file=sys.stderr)
        sys.exit(2)

    # Kanban board item deletion protection (content-aware)
    if is_kanban_board(file_path, config):
        old_string = tool_input.get("old_string", "")
        new_string = tool_input.get("new_string", "")
        replace_all = tool_input.get("replace_all", False)
        blocked, reason = check_kanban_edit_deletion(
            file_path, old_string, new_string, replace_all
        )
        if blocked:
            print(reason, file=sys.stderr)
            sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    main()
