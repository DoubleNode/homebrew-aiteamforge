# Claude Code Configuration Templates

This directory contains templates for setting up Claude Code CLI configuration as part of the aiteamforge environment.

## Directory Structure

```
claude/
├── README.md                           # This file
├── claude-md-global.template           # Global CLAUDE.md guidelines
├── claude-md-team.template             # Per-team CLAUDE.md template
├── settings.json.template              # Main Claude Code settings
├── mcp-settings.template               # MCP server configuration
├── statusline-command.sh               # Status line script template
├── agent-tracking.sh                   # Agent session tracking template
├── hooks/                              # Hook script templates
│   └── damage-control/                 # Pre-tool damage control hooks
│       ├── bash-tool-damage-control.py
│       ├── edit-tool-damage-control.py
│       ├── write-tool-damage-control.py
│       ├── patterns.yaml
│       └── test-damage-control.py
└── skills/                             # Skill templates (if any)
```

## Template Variables

All templates support the following variable substitutions:

- `{{AITEAMFORGE_DIR}}` - Path to aiteamforge installation (e.g., `~/aiteamforge`)
- `{{HOME}}` - User's home directory
- `{{CLAUDE_CONFIG_DIR}}` - Claude Code config directory (usually `~/.claude`)
- `{{USER}}` - Current username
- `{{TEAM_NAME}}` - Team name (for team-specific templates)

## What Gets Installed

### Core Configuration Files

1. **Global CLAUDE.md** (`~/.claude/CLAUDE.md`)
   - Git workflow rules (worktree safety, PR process)
   - Repository boundaries by team
   - Kanban team boundaries
   - Code quality standards
   - Commit message guidelines
   - PR review workflow

2. **settings.json** (`~/.claude/settings.json`)
   - Permission rules (deny dangerous commands)
   - Hook configurations (session start/stop, damage control)
   - Status line configuration
   - Enabled plugins
   - MCP server connections
   - Model preferences

3. **Status Line** (`~/.claude/statusline-command.sh`)
   - Displays current agent, team, kanban item
   - Git branch and status
   - Custom per-terminal information

4. **Agent Tracking** (`~/.claude/agent-tracking.sh`)
   - Tracks agent session starts/stops
   - Integrates with kanban system

### Hooks

Located in `~/.claude/hooks/`:

1. **Damage Control Hooks** (`hooks/damage-control/`)
   - **PreToolUse hooks** - Prevent dangerous commands before execution
   - Pattern-based blocking of:
     - Destructive file operations
     - Force git commands without confirmation
     - Dangerous system commands
   - Uses `patterns.yaml` for easy customization

2. **Kanban Hooks** (referenced from aiteamforge)
   - **SessionStart** - Initialize kanban session
   - **PostToolUse** - Track tool usage for kanban items
   - **Stop** - Clean up kanban session

### Skills

Skills are symlinked from `~/aiteamforge/skills/` to `~/.claude/skills/`:

- Kanban Manager
- LCARS Styling
- Project Planner
- Release Manager
- git-worktree
- Team-specific skills

Skills are symlinked so updates to the aiteamforge skills directory automatically reflect in Claude Code.

### Team-Specific Configuration

For each selected team, the installer creates:

1. **Agent Directory** (`~/.claude/agents/{Team Name}/`)
   - Team-specific CLAUDE.md (optional overrides)
   - Agent persona markdown files

2. **Agent Personas** (copied from `~/aiteamforge/{team}/personas/agents/`)
   - Persona markdown files with:
     - Agent name and description
     - Model preference (opus/sonnet)
     - Character background and expertise
     - Communication style

## Installation Process

The `install-claude-config.sh` installer:

1. **Checks prerequisites** - Verifies Claude Code CLI is installed
2. **Creates backups** - Saves existing config to `.backups/`
3. **Installs core files** - CLAUDE.md, settings.json, hooks, skills
4. **Installs team configs** - Per selected team personas and overrides
5. **Merges settings** - Combines new settings with existing user settings

## Usage

### Full Installation

```bash
# Install via setup wizard (recommended)
aiteamforge-setup

# Or directly for specific teams
./libexec/installers/install-claude-config.sh "Academy Team" "iOS Dev Team"
```

### Restore from Backup

```bash
# List available backups
ls ~/aiteamforge/.backups/

# Restore specific backup
./libexec/installers/install-claude-config.sh --restore 20260217-095800
```

## Customization

### Adding Custom Hooks

1. Create hook script in `~/.claude/hooks/`
2. Add hook configuration to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/your/hook.sh"
          }
        ]
      }
    ]
  }
}
```

### Adding MCP Servers

Edit `~/.claude/settings.json` to add MCP server configurations:

```json
{
  "mcpServers": {
    "your-server-name": {
      "command": "node",
      "args": ["/path/to/server.js"],
      "env": {
        "SERVER_CONFIG": "value"
      }
    }
  }
}
```

### Customizing Damage Control Patterns

Edit `~/.claude/hooks/damage-control/patterns.yaml`:

```yaml
deny:
  - pattern: "rm -rf /*"
    reason: "Prevents deleting entire filesystem"

ask:
  - pattern: "git push --force"
    reason: "Force push can overwrite remote history"
```

## File Locations

After installation:

```
~/.claude/
├── CLAUDE.md                           # Global guidelines
├── settings.json                       # Main configuration
├── statusline-command.sh               # Status line script
├── agent-tracking.sh                   # Session tracking
├── current-agent                       # Current active agent name
├── hooks/                              # Hook scripts
│   └── damage-control/
├── skills/                             # Symlinked to ~/aiteamforge/skills/
└── agents/                             # Team agent configurations
    ├── Academy Team/
    │   ├── academy_reno_engineer_persona.md
    │   ├── academy_nahla_chancellor_persona.md
    │   └── ...
    ├── iOS Dev Team/
    └── ...
```

## Troubleshooting

### Claude Code Not Found

```bash
# Install Claude Code CLI
npm install -g @anthropic-ai/claude-code

# Verify installation
claude --version
```

### Hooks Not Running

Check hook permissions:

```bash
chmod +x ~/.claude/hooks/damage-control/*.py
chmod +x ~/.claude/statusline-command.sh
```

Verify settings.json syntax:

```bash
jq . ~/.claude/settings.json
```

### Skills Not Loading

Skills should be symlinks to aiteamforge:

```bash
ls -la ~/.claude/skills/
# Should show symlinks like: Kanban Manager -> /Users/.../aiteamforge/skills/Kanban Manager
```

If not symlinked, reinstall:

```bash
aiteamforge-setup --reinstall-claude-config
```

### MCP Server Not Connecting

Check MCP server configuration:

```bash
# Test MCP server manually
node ~/aiteamforge/mcp-servers/kanban-integration/dist/index.js

# Check Claude Code logs
tail -f ~/.claude/debug/*.log
```

## See Also

- [AITeamForge Installation Guide](../../../docs/homebrew-tap/INSTALLATION_GUIDE.md)
- [Environment Inventory](../../../docs/homebrew-tap/ENVIRONMENT_INVENTORY.md)
- [Claude Code Documentation](https://claude.com/code)
- [Damage Control Hooks Documentation](hooks/damage-control/README.md)

---

**Last Updated:** 2026-02-17
**Maintainer:** Academy Team
