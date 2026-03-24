# Claude Code Damage Control Hooks

Pre-tool security hooks that prevent dangerous commands from executing in Claude Code CLI.

## Overview

These hooks run **before** Claude Code executes Bash, Edit, or Write tool calls, allowing you to:

- **Block** dangerous commands completely (exit code 2)
- **Ask** for user confirmation before proceeding (JSON output with permissionDecision)
- **Allow** safe commands (exit code 0)

## Hook Files

| File | Purpose | Hook Type |
|------|---------|-----------|
| `bash-tool-damage-control.py` | Prevents dangerous bash commands | PreToolUse (Bash) |
| `edit-tool-damage-control.py` | Prevents dangerous file edits | PreToolUse (Edit) |
| `write-tool-damage-control.py` | Prevents dangerous file writes | PreToolUse (Write) |
| `patterns.yaml` | Pattern definitions for all hooks | Config |
| `test-damage-control.py` | Test suite for hooks | Testing |

## How It Works

### Flow

1. **Claude Code prepares to execute a tool** (e.g., Bash command)
2. **PreToolUse hook fires** before actual execution
3. **Hook script receives tool parameters** via stdin (JSON)
4. **Pattern matching** checks command against deny/ask/allow lists
5. **Hook exits** with decision:
   - **Exit 0** - Allow (command proceeds)
   - **Exit 2** - Block (stderr message shown to Claude)
   - **JSON output** - Ask user for permission

### Exit Codes

```python
# Allow command
sys.exit(0)

# Block command
print("Blocked: This command is dangerous", file=sys.stderr)
sys.exit(2)

# Ask for user permission
output = {
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": "Force push requires confirmation"
    }
}
print(json.dumps(output))
sys.exit(0)
```

## Pattern Configuration

Patterns are defined in `patterns.yaml`:

```yaml
# Completely block these patterns
deny:
  - pattern: "rm -rf /*"
    reason: "Prevents deleting entire filesystem"
    category: "destructive"

  - pattern: "sudo rm -rf"
    reason: "Prevents destructive root operations"
    category: "destructive"

# Ask user before allowing
ask:
  - pattern: "git push --force"
    reason: "Force push can overwrite remote history"
    category: "git-destructive"

  - pattern: "git reset --hard"
    reason: "Hard reset loses uncommitted changes"
    category: "git-destructive"

# Explicitly allow (bypasses other rules)
allow:
  - pattern: "git status"
    reason: "Safe read-only command"
    category: "git-safe"
```

### Pattern Syntax

Patterns support glob-style wildcards:

- `*` - Match any characters except whitespace/slash
- `?` - Match single character except whitespace/slash
- Literal text - Exact match

Examples:

```yaml
deny:
  # Matches any rm -rf with root paths
  - pattern: "rm -rf /*"

  # Matches files starting with /Users
  - pattern: "rm */Users/*"

  # Matches any mkfs command
  - pattern: "mkfs*"
```

### Categories

Organize patterns by category for easier management:

- `destructive` - File/system destruction
- `git-destructive` - Destructive git operations
- `security` - Security-sensitive operations
- `network` - Network operations
- `system-config` - System configuration changes

## Hook Details

### Bash Tool Damage Control

**File:** `bash-tool-damage-control.py`

**Blocks:**
- `rm -rf /*` - Filesystem destruction
- `rm -rf ~/*` - Home directory destruction
- `sudo rm -rf` - Root destructive operations
- `mkfs*` - Filesystem formatting
- `dd if=* of=/dev/*` - Direct disk writes

**Asks:**
- `git push --force` - Force push to remote
- `git reset --hard` - Destructive git reset
- `chmod -R 777` - Overly permissive permissions

### Edit Tool Damage Control

**File:** `edit-tool-damage-control.py`

**Blocks:**
- Editing system files (`/etc/*`, `/System/*`)
- Editing credential files (`.env`, `credentials.json`)
- Editing binary files

**Asks:**
- Editing production configuration
- Large file edits (>10,000 lines)

### Write Tool Damage Control

**File:** `write-tool-damage-control.py`

**Blocks:**
- Writing to system directories
- Overwriting important config files
- Writing outside project directories

**Asks:**
- Overwriting existing files >1000 lines
- Writing to production paths

## Installation

Installed automatically by `install-claude-config.sh`:

```bash
# Via setup wizard
aiteamforge-setup

# Or directly
./libexec/installers/install-claude-config.sh
```

Hooks are copied to:
```
~/.claude/hooks/damage-control/
```

And referenced in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "uv run ~/.claude/hooks/damage-control/bash-tool-damage-control.py",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

## Customization

### Adding New Patterns

Edit `~/.claude/hooks/damage-control/patterns.yaml`:

```yaml
deny:
  - pattern: "your-dangerous-command"
    reason: "Why this is blocked"
    category: "custom"
```

### Testing Patterns

Run the test suite:

```bash
cd ~/.claude/hooks/damage-control/
python3 test-damage-control.py
```

Or test specific command:

```bash
# Simulate a bash command
echo '{"command": "rm -rf /"}' | python3 bash-tool-damage-control.py
```

### Bypassing Hooks (Emergency)

If hooks are blocking legitimate work:

1. **Temporary disable** - Edit `~/.claude/settings.json` and comment out hook
2. **Add allow pattern** - Add pattern to `patterns.yaml` allow list
3. **Use different tool** - Sometimes Edit instead of Write works

**DO NOT** disable damage control permanently unless you understand the risks.

## Dependencies

Hooks use Python 3.8+ with these packages:

- `pyyaml` - Pattern file parsing

Install via uv (recommended):

```bash
# uv handles dependencies via PEP 723 inline metadata
uv run bash-tool-damage-control.py
```

Or via pip:

```bash
pip3 install pyyaml
```

## Troubleshooting

### Hook Not Running

Check hook is executable:

```bash
chmod +x ~/.claude/hooks/damage-control/*.py
```

Check settings.json references correct path:

```bash
jq '.hooks.PreToolUse' ~/.claude/settings.json
```

### Pattern Not Matching

Test pattern directly:

```bash
cd ~/.claude/hooks/damage-control/
python3 test-damage-control.py
```

Enable debug output in hook script:

```python
import sys
print(f"DEBUG: Received input: {input_data}", file=sys.stderr)
```

### Hook Timing Out

Increase timeout in `settings.json`:

```json
{
  "timeout": 10  // seconds
}
```

Simplify `patterns.yaml` (too many patterns can slow matching).

## Security Considerations

**Damage control hooks are NOT a complete security solution.**

They provide:
- ✅ Protection against accidental dangerous commands
- ✅ Confirmation prompts for risky operations
- ✅ Pattern-based filtering of known bad commands

They do NOT provide:
- ❌ Protection against intentional malicious commands
- ❌ Sandboxing or isolation
- ❌ Complete command validation

**Best practices:**
- Review hook patterns regularly
- Test hooks with known dangerous commands
- Keep patterns.yaml under version control
- Add new patterns when issues are discovered
- Never disable hooks permanently

## Examples

### Example 1: Blocking Dangerous Command

```bash
# Claude attempts:
$ rm -rf /

# Hook blocks:
[ERROR] Blocked by damage control: Prevents deleting entire filesystem
Exit code: 2
```

### Example 2: Asking for Confirmation

```bash
# Claude attempts:
$ git push --force origin main

# Hook asks user:
⚠️  Confirmation Required
Command: git push --force origin main
Reason: Force push can overwrite remote history

Allow this command? [y/N]:
```

### Example 3: Allowing Safe Command

```bash
# Claude attempts:
$ git status

# Hook allows:
Exit code: 0
(Command proceeds normally)
```

## See Also

- [Claude Code Settings Documentation](../README.md)
- [Pattern Configuration Guide](patterns.yaml)
- [Test Suite](test-damage-control.py)
- [AITeamForge Security Guide](../../../../../docs/SECURITY-CREDENTIAL-STORAGE.md)

---

**Last Updated:** 2026-02-17
**Maintainer:** Academy Team
