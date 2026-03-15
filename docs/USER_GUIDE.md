# User Guide

**Day-to-day usage of the AITeamForge environment**

---

## Table of Contents

- [Overview](#overview)
- [Main Commands](#main-commands)
- [Working with Teams](#working-with-teams)
- [LCARS Kanban System](#lcars-kanban-system)
- [Claude Code Agents](#claude-code-agents)
- [Git Worktrees](#git-worktrees)
- [Shell Aliases and Shortcuts](#shell-aliases-and-shortcuts)
- [Managing Services](#managing-services)
- [Upgrading and Maintenance](#upgrading-and-maintenance)

---

## Overview

AITeamForge provides a comprehensive development environment with:
- **Multiple specialized teams** (iOS, Android, Firebase, etc.)
- **LCARS Kanban system** for visual task management
- **Claude Code integration** with team-specific AI agents
- **Git worktree automation** for parallel development
- **Terminal automation** with iTerm2 integration
- **Fleet Monitor** for multi-machine coordination

---

## Main Commands

### Core Commands

```bash
aiteamforge setup      # Run interactive setup wizard
aiteamforge doctor     # Health check and diagnostics
aiteamforge status     # Show current environment status
aiteamforge start      # Start aiteamforge services
aiteamforge stop       # Stop aiteamforge services
aiteamforge restart    # Restart aiteamforge services
aiteamforge upgrade    # Upgrade aiteamforge components
aiteamforge uninstall  # Remove aiteamforge environment
aiteamforge version    # Show version information
aiteamforge help       # Show help message
```

### Command Details

#### aiteamforge setup

Run the interactive setup wizard to configure aiteamforge.

```bash
# Interactive setup
aiteamforge setup

# Non-interactive (uses existing config or defaults)
aiteamforge setup --non-interactive

# Preview changes without applying
aiteamforge setup --dry-run

# Install to custom directory
aiteamforge setup --install-dir /opt/aiteamforge
```

**Use cases:**
- Initial installation
- Adding new teams
- Enabling new features
- Reconfiguring existing setup

#### aiteamforge doctor

Run comprehensive health checks and diagnostics.

```bash
# Standard health check
aiteamforge doctor

# Verbose diagnostics
aiteamforge doctor --verbose

# Check specific component
aiteamforge doctor --check dependencies
aiteamforge doctor --check services
aiteamforge doctor --check config

# Attempt automatic fixes (future feature)
aiteamforge doctor --fix
```

**What it checks:**
- External dependencies (Python, Node, jq, gh, etc.)
- Framework installation
- Configuration files
- Running services (LCARS, Fleet Monitor)
- File permissions

#### aiteamforge status

Show current environment status.

```bash
# Full status
aiteamforge status

# JSON output
aiteamforge status --json

# Brief status
aiteamforge status --brief
```

**Displays:**
- Installed teams
- Running services
- Active terminals
- Current kanban status
- Fleet Monitor status (if enabled)

#### aiteamforge start/stop/restart

Control aiteamforge services and environments.

```bash
# Start all teams
aiteamforge start

# Start specific team
aiteamforge start ios
aiteamforge start android
aiteamforge start firebase

# Stop all services
aiteamforge stop

# Stop specific team
aiteamforge stop ios

# Restart everything
aiteamforge restart

# Restart specific service
aiteamforge restart lcars
aiteamforge restart fleet-monitor
```

---

## Working with Teams

### Available Teams

| Team | Purpose | Category |
|------|---------|----------|
| **ios** | iOS app development with Swift | Platform |
| **android** | Android app development with Kotlin | Platform |
| **firebase** | Firebase backend and cloud functions | Platform |
| **academy** | Dev-team infrastructure and tooling | Infrastructure |
| **dns** | DNS framework development | Infrastructure |
| **freelance** | Full-stack freelance projects | Project-Based |
| **mainevent** | Cross-platform coordination | Coordination |
| **command** | Strategic planning | Strategic |
| **legal** | Legal research and documentation | Strategic |
| **medical** | Medical documentation | Strategic |

### Selecting Teams

Teams are selected during initial setup via `aiteamforge setup`. You can add or remove teams by re-running the wizard.

```bash
# Add new teams
aiteamforge setup  # Re-run wizard, select additional teams
```

### Starting a Team Environment

Each team has its own startup script that configures the environment.

```bash
# Start iOS team
aiteamforge start ios

# Start multiple teams
aiteamforge start ios firebase
```

**What happens on team start:**
- Opens iTerm2 windows/tabs (if iTerm2 integration enabled)
- Loads team-specific shell configurations
- Starts team-specific services
- Initializes kanban board state
- Configures terminal badges and themes

### Switching Between Teams

```bash
# Use team-specific aliases (see Shell Aliases section)
# Each team has its own set of commands
```

### Team Directory Structure

Each team has a directory in `~/aiteamforge/`:

```
~/aiteamforge/<team-id>/
├── personas/
│   ├── agents/          # Agent persona markdown files
│   ├── avatars/         # Agent avatar images
│   └── docs/            # Team-specific documentation
├── scripts/             # Team-specific scripts
└── terminals/           # Terminal configurations
```

---

## LCARS Kanban System

The LCARS (Library Computer Access/Retrieval System) Kanban provides a Star Trek-styled visual task management interface.

### Accessing LCARS

Open in your browser:
```
http://localhost:8082
```

**Default port:** 8082 (configurable via `~/aiteamforge/config.json`)

### Kanban Commands

#### Shell Functions

```bash
# List kanban items
kb-list                  # List all items
kb-list ios              # List items for iOS team
kb-list --status backlog # List items in backlog

# Add new item
kb-add "Task description"
kb-add "Task" --team ios

# Update item
kb-update XIOS-0001 --status in_progress
kb-update XIOS-0001 --assignee picard

# Move item between states
kb-move XIOS-0001 in_progress
kb-move XIOS-0001 done

# Show item details
kb-show XIOS-0001

# Delete item (sets status to cancelled)
kb-cancel XIOS-0001

# Kanban status summary
kb-status
kb-status ios            # Status for specific team
```

#### Kanban States

Items progress through these states:

1. **Backlog** - Not yet started
2. **In Progress** - Actively being worked on
3. **In Review** - Awaiting code review
4. **Testing** - In QA testing
5. **Done** - Completed
6. **Cancelled** - Cancelled or deprecated

#### Working with Subitems

```bash
# Add subitem to an item
kb-sub add XIOS-0001 "Subtask description"

# List subitems
kb-sub list XIOS-0001

# Update subitem
kb-sub update XIOS-0001-001 --status done

# Start working on subitem
kb-sub start XIOS-0001-001

# Mark subitem done
kb-sub done XIOS-0001-001
```

### Kanban Backup System

Kanban boards are automatically backed up hourly.

```bash
# View backups
ls ~/aiteamforge/kanban-backups/

# Restore from backup
cp ~/aiteamforge/kanban-backups/ios-board-20260217-1400.json \
   ~/aiteamforge/kanban/ios-board.json
```

**Backup schedule:** Every hour (via LaunchAgent)
**Retention:** 7 days of hourly backups

---

## Claude Code Agents

If you installed Claude Code integration, you have team-specific AI agents configured.

### Agent Personas

Each team has multiple agent personas with distinct specializations:

#### iOS Team Agents
```bash
ios-picard      # Captain Picard - Lead Feature Developer
ios-beverly     # Dr. Crusher - Bugfix Specialist
ios-data        # Data - Testing & Quality Assurance
ios-geordi      # Geordi La Forge - Performance Optimization
ios-worf        # Worf - Security Specialist
ios-deanna      # Deanna Troi - UX/UI Specialist
ios-barclay     # Reginald Barclay - Documentation
```

#### Android Team Agents
```bash
android-kirk    # Captain Kirk - Lead Feature Developer
android-mccoy   # Dr. McCoy - Bugfix Specialist
android-spock   # Spock - Testing & Logic
android-scotty  # Scotty - Performance Engineer
android-uhura   # Uhura - Localization & i18n
android-sulu    # Sulu - Navigation & UI
android-chekov  # Chekov - Documentation
```

#### Firebase Team Agents
```bash
firebase-sisko     # Commander Sisko - Backend Lead
firebase-bashir    # Dr. Bashir - API Health
firebase-kira      # Major Kira - Security
firebase-odo       # Odo - Authentication
firebase-jadzia    # Jadzia Dax - Database Optimization
firebase-obrien    # Chief O'Brien - Infrastructure
firebase-weyoun    # Weyoun - Documentation
firebase-garak     # Garak - Data Migration
```

### Using Agents

```bash
# Start agent session (opens Claude Code)
ios-picard

# The agent will:
# - Load team-specific persona
# - Have access to team repositories
# - Auto-track work in kanban system
# - Follow team-specific guidelines
```

### Agent Tracking

Agents automatically track their work in the kanban system:
- Session start/stop hooks record activity
- Tool usage is logged
- Kanban items are updated automatically
- Time tracking is recorded

### Agent Configuration

Agent configurations are stored in:
```
~/aiteamforge/claude/agents/<Team Name>/<agent-name>/
```

Each agent has:
- `persona.md` - Agent personality and role description
- `settings.json` - Claude Code configuration
- `avatar.png` - Agent avatar image

---

## Git Worktrees

AITeamForge includes automation for git worktrees, allowing parallel development.

### Worktree Commands

```bash
# List worktrees
wt-list

# Create new worktree
wt-create feature/my-feature
wt-create bugfix/fix-crash

# Remove worktree
wt-remove feature/my-feature

# Clean up stale worktrees
wt-clean

# Switch to worktree
wt-switch feature/my-feature
```

### Worktree Workflow

```bash
# 1. Create worktree for new feature
wt-create feature/xios-0042

# 2. CD into worktree
cd ~/aiteamforge/worktrees/feature/xios-0042

# 3. Work on feature (separate from main repo)
# Make changes, commit, push

# 4. When done, create PR
gh pr create --base develop

# 5. After merge, clean up worktree
wt-remove feature/xios-0042
```

### Worktree Integration with Kanban

Worktrees created via `kb-run` are automatically linked to kanban items:

```bash
# Create worktree from kanban item
kb-run XIOS-0042

# This:
# 1. Creates worktree: worktrees/xios-0042
# 2. Creates branch: feature/xios-0042
# 3. Links to kanban item
# 4. Updates kanban status to "in_progress"
```

---

## Shell Aliases and Shortcuts

AITeamForge installs numerous shell aliases for common operations.

### Core Aliases

```bash
# AITeamForge commands
dt-status        # Alias for: aiteamforge status
dt-doctor        # Alias for: aiteamforge doctor
dt-start         # Alias for: aiteamforge start
dt-stop          # Alias for: aiteamforge stop

# Claude Code shortcuts
cc               # Launch Claude Code in current directory
cc-auth          # Re-authenticate Claude Code
```

### Kanban Aliases

```bash
# See LCARS Kanban System section above
kb-list, kb-add, kb-update, kb-move, kb-show, kb-status, kb-sub, etc.
```

### Worktree Aliases

```bash
# See Git Worktrees section above
wt-list, wt-create, wt-remove, wt-clean, wt-switch
```

### Git Shortcuts

```bash
# Common git operations
gs               # git status
gd               # git diff
gl               # git log --oneline
gp               # git push
gpl              # git pull
gco              # git checkout
gcb              # git checkout -b
```

### Navigation Shortcuts

```bash
# Quick navigation
cddt             # cd ~/aiteamforge
cdk              # cd ~/aiteamforge/kanban
cdl              # cd ~/aiteamforge/lcars-ui
cdt              # cd ~/aiteamforge/teams
```

### Viewing Aliases

```bash
# List all aiteamforge aliases
alias | grep "^dt-"
alias | grep "^kb-"
alias | grep "^wt-"
```

---

## Managing Services

### LCARS Kanban Service

```bash
# Check LCARS status
curl http://localhost:8082/health

# Start LCARS
aiteamforge start lcars

# Stop LCARS
aiteamforge stop lcars

# Restart LCARS
aiteamforge restart lcars

# View LCARS logs
tail -f ~/aiteamforge/logs/lcars.log
```

### Fleet Monitor Service (Multi-Machine Only)

```bash
# Check Fleet Monitor status
curl http://localhost:3000/api/health

# Start Fleet Monitor
aiteamforge start fleet-monitor

# Stop Fleet Monitor
aiteamforge stop fleet-monitor

# Restart Fleet Monitor
aiteamforge restart fleet-monitor

# View Fleet Monitor logs
tail -f ~/aiteamforge/logs/fleet-monitor.log
```

### LaunchAgents (Background Services)

AITeamForge installs LaunchAgents for background tasks:

```bash
# List aiteamforge LaunchAgents
launchctl list | grep aiteamforge

# View LaunchAgent status
launchctl list com.devteam.kanban-backup
launchctl list com.devteam.lcars-health

# Restart LaunchAgent
launchctl kickstart -k gui/$(id -u)/com.devteam.kanban-backup
```

**Installed LaunchAgents:**
- `com.devteam.kanban-backup` - Hourly kanban backups
- `com.devteam.lcars-health` - LCARS health monitoring

---

## Upgrading and Maintenance

### Upgrading AITeamForge

```bash
# Upgrade framework
brew upgrade aiteamforge

# Upgrade working directory components
aiteamforge upgrade
```

**What gets upgraded:**
- Core scripts and executables
- Shell helper functions
- LCARS UI components
- Fleet Monitor server
- Team configurations (templates merged with existing)

**What's preserved:**
- Kanban board data
- Custom configurations
- Team directories
- Git worktrees

### Upgrade Process

1. **Check for updates:**
   ```bash
   brew update
   brew outdated aiteamforge
   ```

2. **Backup current state:**
   ```bash
   tar -czf ~/aiteamforge-backup-$(date +%Y%m%d).tar.gz ~/aiteamforge/
   ```

3. **Upgrade framework:**
   ```bash
   brew upgrade aiteamforge
   ```

4. **Upgrade working directory:**
   ```bash
   aiteamforge upgrade
   ```

5. **Verify upgrade:**
   ```bash
   aiteamforge doctor
   aiteamforge --version
   ```

6. **Restart services:**
   ```bash
   aiteamforge restart
   ```

### Maintenance Tasks

#### Clean Up Old Worktrees

```bash
wt-clean
```

#### Clean Up Old Backups

```bash
# Backups older than 7 days are auto-deleted
# Manual cleanup:
find ~/aiteamforge/kanban-backups -mtime +7 -delete
```

#### Update Dependencies

```bash
# Update Homebrew packages
brew upgrade python@3 node jq gh

# Update Claude Code
npm update -g @anthropic-ai/claude-code

# Update Tailscale
brew upgrade tailscale
```

#### Repair Broken Installation

```bash
# Run diagnostics
aiteamforge doctor --verbose

# Attempt automatic repair
aiteamforge doctor --fix

# Manual repair: re-run setup
aiteamforge setup
```

---

## Advanced Usage

### Environment Variables

```bash
# Framework location
echo $AITEAMFORGE_HOME
# Output: /opt/homebrew/opt/aiteamforge/libexec

# Working directory location
echo $AITEAMFORGE_DIR
# Output: /Users/username/aiteamforge
```

### Custom Configuration

Edit `~/aiteamforge/config.json` to customize:
- LCARS port number
- Fleet Monitor settings
- Team-specific settings
- Service startup behavior

### Adding Custom Teams

See [ADDING_A_TEAM.md](ADDING_A_TEAM.md) for detailed instructions on creating custom teams.

### Scripting with AITeamForge

```bash
# Non-interactive operations
aiteamforge status --json | jq .teams

# Programmatic kanban operations
kb-add "Automated task" --team ios --status backlog

# Batch operations
for team in ios android firebase; do
  kb-status $team
done
```

---

## Tips and Best Practices

### Daily Workflow

1. **Start your team environment:**
   ```bash
   aiteamforge start ios
   ```

2. **Check kanban status:**
   ```bash
   kb-list --status in_progress
   ```

3. **Start working on item:**
   ```bash
   kb-run XIOS-0042  # Creates worktree and starts agent
   ```

4. **Work in worktree with agent assistance:**
   ```bash
   ios-picard  # Agent auto-tracks work
   ```

5. **Create PR when done:**
   ```bash
   gh pr create --base develop
   ```

6. **Clean up:**
   ```bash
   kb-done XIOS-0042  # Updates kanban
   wt-remove xios-0042  # Removes worktree
   ```

### Parallel Development

Use worktrees to work on multiple features simultaneously:

```bash
# Terminal 1: Feature A
kb-run XIOS-0042
cd ~/aiteamforge/worktrees/xios-0042
ios-picard

# Terminal 2: Feature B
kb-run XIOS-0043
cd ~/aiteamforge/worktrees/xios-0043
ios-beverly

# Each worktree is isolated
```

### Multi-Team Development

Work across platforms simultaneously:

```bash
# Start all relevant teams
aiteamforge start ios android firebase

# Work in each team's context
# Agents track work to correct team's kanban board
```

---

## Getting Help

### Built-in Help

```bash
# Command help
aiteamforge help
aiteamforge setup --help
aiteamforge doctor --help

# Kanban help
kb-help

# Worktree help
wt-help
```

### Documentation

```bash
# View installed documentation
ls ~/aiteamforge/docs/

# Key documents
cat ~/aiteamforge/docs/QUICK_START.md
cat ~/aiteamforge/docs/INSTALLATION.md
cat ~/aiteamforge/docs/TROUBLESHOOTING.md
```

### Diagnostics

```bash
# Full diagnostic report
aiteamforge doctor --verbose > ~/aiteamforge-diagnostic-report.txt
```

---

**Next Steps:**
- Explore [Architecture](ARCHITECTURE.md) to understand the system design
- Set up [Multi-Machine](MULTI_MACHINE.md) coordination if using multiple machines
- Check [Troubleshooting](TROUBLESHOOTING.md) for common issues
- Review [Team Reference](TEAM_REFERENCE.md) for team-specific details
