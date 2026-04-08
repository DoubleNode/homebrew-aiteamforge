# Shell Environment Installer Module

## Overview

The shell environment installer sets up zsh integration, LCARS-inspired prompts, shell aliases, and secrets management for the aiteamforge infrastructure.

## Components

### 1. Installer Script
**Location:** `libexec/installers/install-shell.sh`

**Functions:**
- `install_shell_environment()` - Main installation function
- `uninstall_shell_environment()` - Clean removal function
- `add_zshrc_integration()` - Add sourcing block to ~/.zshrc
- `remove_zshrc_integration()` - Remove integration cleanly
- `install_env_loader()` - Install main environment loader
- `install_prompt()` - Install prompt customization
- `install_aliases()` - Install all shell alias files
- `install_secrets_template()` - Install secrets template

**Integration:**
- Sources `libexec/lib/common.sh` for utilities
- Exports functions for setup wizard
- Idempotent - can run multiple times safely

### 2. Environment Loader
**Location:** `share/templates/aiteamforge-env.sh`
**Installed to:** `$AITEAMFORGE_DIR/share/aiteamforge-env.sh`

**Purpose:**
- Sources all shell aliases (agent, kanban, worktree)
- Loads prompt customization
- Loads secrets.env if it exists
- Adds aiteamforge bin to PATH
- Sources team-specific startup scripts

**Variables Substituted:**
- `{{AITEAMFORGE_DIR}}` → Actual installation directory

### 3. Prompt Configuration
**Location:** `share/templates/aiteamforge-prompt.sh`
**Installed to:** `$AITEAMFORGE_DIR/share/aiteamforge-prompt.sh`

**Features:**
- Two-line LCARS-style prompt
- Shows team name, worktree, user@host, path, git branch
- Optional stardate display
- Customizable colors via environment variables
- Skips if already in team-specific terminal (SESSION_TYPE set)

**Customization Variables:**
```bash
export AITEAMFORGE_NAME="iOS"              # Team name display
export AITEAMFORGE_COLOR='%F{160}'         # Primary prompt color
export AITEAMFORGE_HIGHLIGHT='%F{196}'     # Highlight color
export AITEAMFORGE_STARDATE=true           # Enable stardate
```

### 4. Agent Aliases
**Location:** `share/templates/aliases/agent-aliases.sh`
**Installed to:** `$AITEAMFORGE_DIR/share/aliases/agent-aliases.sh`

**Provides:**
- `claude_agent()` - Main agent switcher function
- Team-specific aliases (claude-geordi, claude-sisko, etc.)
- `claude-status()` - Show current agent and worktree
- `claude-help()` - Display available agents

**Teams Covered:**
- iOS (TNG): 9 agents
- Firebase (DS9): 7 agents
- Android (TOS): 7 agents
- Freelance (ENT): 8 agents
- Academy (32nd): 4 agents
- Command (DSC): 5 agents
- MainEvent (VOY): 11 agents
- DNS (LD): 11 agents
- Generic: 6 standard agents

### 5. Kanban Aliases
**Location:** `share/templates/aliases/kanban-aliases.sh`
**Installed to:** `$AITEAMFORGE_DIR/share/aliases/kanban-aliases.sh`

**Provides:**
- `kb-list()` - List items
- `kb-backlog()` - List backlog
- `kb-add()` - Add item
- `kb-update()` - Update item
- `kb-move()` - Move item to status
- `kb-start()` - Start working on item
- `kb-done()` - Mark item done
- `kb-view()` - View item details
- `kb-search()` - Search items
- `kb-stats()` - Show statistics
- `kb-set-worktree()` - Set current item from worktree
- `kb-pr()` - Mark item in review
- `kb-merged()` - Mark item merged
- `kb-team()` - Switch team context
- `kb-help()` - Show help

**Backend:** Calls Python kanban-manager.py for all operations

### 6. Worktree Aliases
**Location:** `share/templates/aliases/worktree-aliases.sh`
**Installed to:** `$AITEAMFORGE_DIR/share/aliases/worktree-aliases.sh`

**Provides:**
- `wt-list()` - List worktrees
- `wt-create()` - Create new worktree
- `wt-remove()` - Remove worktree
- `wt-prune()` - Clean up deleted worktrees
- `wt-main()` - Jump to main repo
- `wt-go()` - Jump to specific worktree
- `wt-project()` - Set project context
- `wt-status()` - Show current status
- `wt-help()` - Show help

**Features:**
- Auto-detects git repositories
- Detects if currently in a worktree
- Manages project context for easier navigation

### 7. Secrets Template
**Location:** `share/templates/secrets.env.template`
**Installed to:** `$AITEAMFORGE_DIR/secrets.env.template`

**Expected Secrets:**
- `ANTHROPIC_API_KEY` - Claude Code API key
- `GITHUB_TOKEN` - GitHub personal access token
- `GOOGLE_APPLICATION_CREDENTIALS` - Firebase service account
- `TAILSCALE_AUTH_KEY` - Tailscale auth (optional)
- Custom environment variables as needed

**Security Notes:**
- Template is committed, actual secrets.env is NOT
- User must copy template and populate
- Recommended: chmod 600 secrets.env
- Never share or commit actual secrets

## Installation Flow

1. **Check Integration**
   - Look for markers in ~/.zshrc
   - Warn if already exists

2. **Backup**
   - Backup ~/.zshrc to ~/.zshrc.aiteamforge-backup
   - Only if backup doesn't already exist

3. **Install Components**
   - Create share/ directory
   - Install environment loader (with variable substitution)
   - Install prompt configuration
   - Install alias files (with variable substitution)
   - Install secrets template

4. **Add Integration**
   - Append sourcing block to ~/.zshrc
   - Block wrapped in markers for clean removal

5. **Report Next Steps**
   - Review secrets template
   - Create and populate secrets.env
   - Reload shell

## Uninstallation Flow

1. **Remove Integration**
   - Delete block between markers in ~/.zshrc
   - Uses sed to remove cleanly

2. **Remove Files**
   - Delete aiteamforge-env.sh
   - Delete aiteamforge-prompt.sh
   - Delete aliases directory
   - Delete secrets.env.template

3. **Offer Backup Restore**
   - If ~/.zshrc.aiteamforge-backup exists
   - Prompt user to restore

## .zshrc Integration Block

```zsh
# >>> aiteamforge initialize >>>
# AITeamForge Environment Loader
# Auto-generated by aiteamforge installer
if [ -f "$AITEAMFORGE_DIR/share/aiteamforge-env.sh" ]; then
    source "$AITEAMFORGE_DIR/share/aiteamforge-env.sh"
fi
# <<< aiteamforge initialize <<<
```

**Markers:** `# >>> aiteamforge initialize >>>` and `# <<< aiteamforge initialize <<<`

**Purpose:**
- Easy detection for idempotency
- Clean removal without affecting other config
- Similar to conda/pyenv integration patterns

## Dependencies

**Required:**
- `libexec/lib/common.sh` - Utility functions (header, info, success, warning, error, prompt_yes_no)
- Python 3 - For kanban backend
- jq - For kanban operations (via backend)
- Git - For worktree operations

**Optional:**
- tmux - For claude-status worktree display
- Claude Code - For agent switching to work

## Testing

**Smoke Test:**
```bash
# Source the installer
source libexec/installers/install-shell.sh

# Check functions are defined
type install_shell_environment
type uninstall_shell_environment

# Test idempotency check
has_zshrc_integration && echo "Integration exists" || echo "No integration"
```

**Full Test:**
```bash
# Set test env
export AITEAMFORGE_DIR="$HOME/test-aiteamforge"
export INSTALL_ROOT="$(pwd)"

# Run install
install_shell_environment

# Verify files
ls -la ~/test-aiteamforge/share/
cat ~/.zshrc | grep "aiteamforge initialize"

# Test uninstall
uninstall_shell_environment

# Clean up
rm -rf ~/test-aiteamforge
```

## File Metrics

| File | Lines | Purpose |
|------|-------|---------|
| install-shell.sh | 259 | Installer logic |
| aiteamforge-env.sh | 70 | Environment loader |
| aiteamforge-prompt.sh | 116 | Prompt config |
| agent-aliases.sh | 211 | Agent switching |
| kanban-aliases.sh | 244 | Kanban helpers |
| worktree-aliases.sh | 293 | Worktree helpers |
| secrets.env.template | 65 | Secrets template |
| **Total** | **1,258** | |

## Known Limitations

1. **zsh Only** - Does not support bash or fish
2. **macOS Assumed** - Paths assume macOS directory structure
3. **Single Machine** - Secrets are local, not synced
4. **Manual Secrets** - User must populate secrets.env manually
5. **Prompt Override** - Team terminals override generic prompt (by design)

## Future Enhancements

- [ ] Bash support (if needed)
- [ ] Fish shell support (if needed)
- [ ] Secrets sync across machines (via Tailscale?)
- [ ] Auto-detect more team contexts
- [ ] Theme switcher for different Starfleet eras
- [ ] Integration with iTerm2 badges
- [ ] Status bar integration for terminal title

## Related Modules

- **Dependencies:** `libexec/lib/common.sh`
- **Called By:** Main setup wizard
- **Integrates With:**
  - Claude Code installer (agent switching)
  - Kanban installer (kb-* commands)
  - Team installer (team-specific prompts)

---

**Module Status:** ✅ Complete

**Created:** 2026-02-17
**Author:** Commander Jett Reno (Academy Engineering)
