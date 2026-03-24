# Architecture Overview

**Technical architecture and design principles of the AITeamForge system**

---

## Table of Contents

- [Design Philosophy](#design-philosophy)
- [Two-Layer Architecture](#two-layer-architecture)
- [Directory Structure](#directory-structure)
- [Component Relationships](#component-relationships)
- [Setup Wizard Orchestration](#setup-wizard-orchestration)
- [Lifecycle Commands](#lifecycle-commands)
- [Configuration System](#configuration-system)
- [Extension Points](#extension-points)

---

## Design Philosophy

### Core Principles

**1. Two-Layer Separation**
- **Framework layer** (Homebrew-managed) provides immutable product code
- **Working layer** (user-managed) contains mutable configuration and data
- Clean separation enables safe upgrades without data loss

**2. Data-Driven Configuration**
- Teams, agents, and features defined in data files (JSON, `.conf`)
- Adding teams doesn't require code changes
- Generic installers read configuration and act accordingly

**3. Idempotent Operations**
- All operations safe to run multiple times
- Setup wizard can be re-run to add features
- Installers check existing state before modifying

**4. Graceful Degradation**
- Missing optional dependencies don't block installation
- Service failures are logged but don't crash system
- Network issues don't prevent local work

**5. Progressive Enhancement**
- Minimal install works standalone
- Optional features add capabilities
- Multi-machine setup is entirely optional

---

## Two-Layer Architecture

### Framework Layer

**Location:** `$(brew --prefix)/opt/aiteamforge/libexec/`

**Content:**
- Core executables and scripts
- Installer modules
- Configuration templates
- Documentation
- LCARS UI files
- Skills and helpers

**Management:**
- Installed via `brew install aiteamforge`
- Upgraded via `brew upgrade aiteamforge`
- Read-only to users
- Rolled back via `brew switch aiteamforge <version>`

**Purpose:**
- Provides stable, versioned product code
- Shared across all users on the system
- Enables clean upgrades

### Working Layer

**Location:** `~/aiteamforge/` (or custom location via `--install-dir`)

**Content:**
- User-specific configuration
- Kanban board data
- Team directories
- Generated scripts
- Service logs
- Git worktrees

**Management:**
- Created by `aiteamforge setup`
- Modified by user and agents
- Persisted across framework upgrades
- Backed up by user

**Purpose:**
- Holds user's work and customizations
- Preserves data during upgrades
- Allows multiple working directories

### Interaction

```
┌───────────────────────────────────────┐
│  Framework Layer (Homebrew)           │
│  /opt/homebrew/opt/aiteamforge/libexec/  │
│                                       │
│  ├── bin/                             │
│  │   ├── aiteamforge-cli.sh              │
│  │   └── aiteamforge-setup.sh            │
│  ├── libexec/                         │
│  │   ├── commands/                    │
│  │   ├── installers/                  │
│  │   └── ui/lib/                      │
│  ├── share/                           │
│  │   ├── teams/                       │
│  │   └── templates/                   │
│  └── docs/                            │
└───────────────────────────────────────┘
              ↓ Reads templates
              ↓ Generates configs
              ↓
┌───────────────────────────────────────┐
│  Working Layer (User Data)            │
│  ~/aiteamforge/                          │
│                                       │
│  ├── .aiteamforge-config                 │
│  ├── config.json                      │
│  ├── teams/                           │
│  ├── kanban/                          │
│  ├── claude/                          │
│  ├── lcars-ui/                        │
│  ├── fleet-monitor/                   │
│  └── worktrees/                       │
└───────────────────────────────────────┘
              ↑ Users work here
              ↑ Agents modify data
              ↑ Services read/write
```

---

## Directory Structure

### Framework Directory

```
$(brew --prefix)/opt/aiteamforge/libexec/
├── bin/
│   ├── aiteamforge-cli.sh              # Main CLI dispatcher
│   └── aiteamforge-setup.sh            # Setup wizard entry point
├── libexec/
│   ├── commands/                    # Subcommand scripts
│   │   ├── aiteamforge-doctor.sh       # Health check
│   │   ├── aiteamforge-status.sh       # Status display
│   │   ├── aiteamforge-start.sh        # Start services
│   │   ├── aiteamforge-stop.sh         # Stop services
│   │   ├── aiteamforge-upgrade.sh      # Upgrade components
│   │   └── aiteamforge-uninstall.sh    # Uninstall
│   ├── installers/                  # Installer modules
│   │   ├── install-team.sh          # Team installer
│   │   ├── install-shell-env.sh     # Shell environment
│   │   ├── install-claude.sh        # Claude Code config
│   │   ├── install-kanban.sh        # LCARS Kanban
│   │   └── install-fleet.sh         # Fleet Monitor
│   └── ui/lib/
│       └── wizard-ui.sh             # UI library for setup wizard
├── share/
│   ├── teams/                       # Team definitions
│   │   ├── ios.conf
│   │   ├── android.conf
│   │   ├── firebase.conf
│   │   └── registry.json
│   └── templates/                   # Configuration templates
│       ├── claude-settings.json.template
│       ├── fleet-config.json.template
│       └── machine.json.template
├── lcars-ui/                        # LCARS Kanban web UI
│   ├── index.html
│   ├── server.py
│   ├── css/
│   ├── js/
│   └── images/
├── fleet-monitor/                   # Fleet Monitor server
│   ├── server/
│   │   ├── server.js
│   │   └── package.json
│   └── client/
├── scripts/                         # Helper scripts
│   ├── kanban-helpers.sh
│   ├── worktree-helpers.sh
│   └── claude_agent_aliases.sh
├── kanban-hooks/                    # Kanban automation
│   ├── kanban-session-start.py
│   ├── kanban-hook.py
│   └── kanban-stop.py
├── skills/                          # Claude Code skills
│   ├── Kanban Manager/
│   ├── Project Planner/
│   └── git-worktree/
└── docs/                            # Documentation
    ├── QUICK_START.md
    ├── INSTALLATION.md
    ├── USER_GUIDE.md
    └── ...
```

### Working Directory

```
~/aiteamforge/
├── .aiteamforge-config                 # Installation marker
├── config.json                      # User configuration
├── teams/                           # Team-specific files
│   ├── ios/
│   │   ├── personas/
│   │   ├── scripts/
│   │   └── terminals/
│   ├── android/
│   └── firebase/
├── kanban/                          # Kanban board data
│   ├── ios-board.json
│   ├── android-board.json
│   └── releases/
├── kanban-backups/                  # Automatic backups
│   └── ios-board-20260217-1400.json
├── claude/                          # Claude Code configs
│   ├── settings.json
│   ├── current-agent
│   └── agents/
│       ├── iOS Development/
│       ├── Android Development/
│       └── Firebase Development/
├── lcars-ui/                        # LCARS instance
│   └── config/
├── lcars-ports/                     # Port assignments
│   ├── ios-picard.port
│   ├── ios-picard.theme
│   └── ios-picard.order
├── fleet-monitor/                   # Fleet Monitor config
│   ├── config.json
│   └── data/
├── scripts/                         # Generated scripts
│   ├── ios-startup.sh
│   ├── ios-shutdown.sh
│   └── shell-env.sh
├── worktrees/                       # Git worktrees
│   ├── feature-xios-0042/
│   └── bugfix-crash/
├── logs/                            # Service logs
│   ├── lcars.log
│   └── fleet-monitor.log
└── docs/                            # Copied documentation
```

---

## Component Relationships

### Data Flow

```
User runs: aiteamforge setup
         ↓
    Setup Wizard (aiteamforge-setup.sh)
         ↓
    ┌────────────────────┐
    │ Stage 1: Check Deps│
    └────────────────────┘
         ↓
    ┌────────────────────┐
    │ Stage 2: Machine ID│
    └────────────────────┘
         ↓
    ┌────────────────────┐
    │ Stage 3: Select    │
    │         Teams      │
    └────────────────────┘
         ↓
    ┌────────────────────┐
    │ Stage 4: Select    │
    │         Features   │
    └────────────────────┘
         ↓
    Generates config.json
         ↓
    ┌─────────────────────────────────────┐
    │ Stage 5: Run Installers             │
    ├─────────────────────────────────────┤
    │  install-team.sh (for each team)    │
    │       ↓                              │
    │  install-shell-env.sh                │
    │       ↓                              │
    │  install-claude.sh                   │
    │       ↓                              │
    │  install-kanban.sh                   │
    │       ↓                              │
    │  install-fleet.sh                    │
    └─────────────────────────────────────┘
         ↓
    ┌────────────────────┐
    │ Stage 6: Summary   │
    └────────────────────┘
         ↓
    Installation Complete
```

### Component Dependencies

```
aiteamforge CLI
    ↓
    ├── Commands (doctor, status, start, stop, etc.)
    │   ├── Read config.json
    │   ├── Use wizard-ui.sh for output
    │   └── Call service scripts
    │
    └── Setup Wizard
        ├── Use wizard-ui.sh for UI
        ├── Read share/teams/registry.json
        └── Call Installer Modules
            ├── install-team.sh
            │   ├── Read share/teams/<team>.conf
            │   └── Generate team directories/scripts
            ├── install-shell-env.sh
            │   └── Copy scripts/ to working dir
            ├── install-claude.sh
            │   ├── Read templates/claude-settings.json.template
            │   └── Generate claude/settings.json
            ├── install-kanban.sh
            │   ├── Copy lcars-ui/ to working dir
            │   └── Install LaunchAgents
            └── install-fleet.sh
                ├── Copy fleet-monitor/ to working dir
                └── Install fleet server/client
```

---

## Setup Wizard Orchestration

### Wizard Stages

**Stage 1: Prerequisites Check**
- Checks for required tools (Python, Node, jq, gh, Git)
- Checks for optional tools (iTerm2, Claude Code, Tailscale)
- Offers to install missing tools via Homebrew
- Aborts if critical dependencies missing

**Stage 2: Machine Identity**
- Prompts for machine name
- Prompts for user display name
- Used for Fleet Monitor and logging

**Stage 3: Team Selection**
- Loads `share/teams/registry.json`
- Displays teams grouped by category
- User selects teams (comma or space-separated)

**Stage 4: Feature Selection**
- LCARS Kanban (yes/no)
- Fleet Monitor (yes/no, mode selection)
- Shell Environment (yes/no)
- Claude Code Config (yes/no)
- iTerm2 Integration (yes/no)

**Stage 5: Configuration Generation**
- Creates `~/.aiteamforge/config.json`
- Records machine identity, teams, features, paths, timestamp

**Stage 6: Installation**
- Runs installer modules in sequence
- Shows progress with LCARS-style UI
- Logs output to `~/aiteamforge/logs/install.log`
- Continues on installer failures (non-fatal)

**Stage 7: Summary**
- Shows what was installed successfully
- Reports warnings/errors
- Shows manual steps (if any)
- Displays quick-start commands

### Installer Module Interface

Each installer module:
- Is a bash script in `libexec/installers/`
- Is sourced (not executed as subprocess)
- Has access to `$CONFIG_FILE` variable
- Returns 0 on success, non-zero on failure
- Uses wizard-ui.sh functions for output
- Is idempotent (safe to run multiple times)

**Example module signature:**
```bash
#!/bin/bash
# install-example.sh

install_example() {
    local config_file="${1:-$HOME/.aiteamforge/config.json}"

    print_section "Installing Example Component"

    # Check if already installed
    if [ -f "$HOME/aiteamforge/example/.installed" ]; then
        print_warning "Already installed, skipping"
        return 0
    fi

    # Perform installation
    # ...

    # Mark as installed
    touch "$HOME/aiteamforge/example/.installed"

    print_success "Example component installed"
    return 0
}

# Allow running standalone
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_example "$@"
fi
```

---

## Lifecycle Commands

### aiteamforge start

**Purpose:** Start aiteamforge services and team environments

**What it does:**
1. Reads `config.json` to determine enabled features
2. Starts LCARS server (if enabled)
3. Starts Fleet Monitor (if enabled)
4. Starts team-specific environments (if team specified)

**Team startup:**
- Calls `~/aiteamforge/<team>-startup.sh`
- Opens iTerm2 windows/tabs (if iTerm2 integration enabled)
- Initializes kanban board state
- Starts team-specific services

### aiteamforge stop

**Purpose:** Stop aiteamforge services and close team environments

**What it does:**
1. Stops team-specific environments
2. Stops Fleet Monitor
3. Stops LCARS server
4. Saves kanban board state

### aiteamforge doctor

**Purpose:** Comprehensive health check and diagnostics

**Check categories:**
- **Dependencies** - External tools (Python, Node, etc.)
- **Framework** - Framework installation integrity
- **Config** - Working directory and configuration files
- **Services** - Running services (LCARS, Fleet Monitor)
- **Permissions** - File permissions and write access

**Output format:**
- ✓ Pass (green) - Check succeeded
- ⚠ Warn (yellow) - Non-critical issue
- ✗ Fail (red) - Critical issue

### aiteamforge status

**Purpose:** Show current environment status

**Displays:**
- Installed teams
- Running services with ports
- Active terminals and agents
- Kanban summary (items in progress)
- Fleet Monitor status

### aiteamforge upgrade

**Purpose:** Upgrade working directory components

**What it does:**
1. Checks for framework updates (via Homebrew)
2. Backs up current working directory
3. Updates scripts from framework templates
4. Merges new configurations with existing
5. Updates LCARS UI
6. Updates Fleet Monitor
7. Preserves user data and customizations

---

## Configuration System

### Configuration Files

**1. User Configuration (`~/.aiteamforge/config.json`)**
```json
{
  "version": "1.0.0",
  "machine": {
    "name": "macbook-pro-office",
    "hostname": "macbook-pro.local",
    "user": "John Doe"
  },
  "teams": ["ios", "firebase", "academy"],
  "features": {
    "kanban": true,
    "fleet_monitor": false,
    "shell_env": true,
    "claude_config": true,
    "iterm_integration": false
  },
  "paths": {
    "install_dir": "/Users/johndoe/aiteamforge",
    "config_dir": "/Users/johndoe/.aiteamforge"
  },
  "installed_at": "2026-02-17T10:30:00Z"
}
```

**2. Team Configuration (`share/teams/<team>.conf`)**
```bash
TEAM_ID="ios"
TEAM_NAME="iOS Development"
TEAM_CATEGORY="platform"
TEAM_COLOR="#FF9500"
TEAM_LCARS_PORT="8260"
TEAM_REPOS=("MainEventApp-iOS" "DNSFramework")
TEAM_BREW_DEPS=("swiftlint" "xcodegen")
TEAM_AGENTS=("picard" "beverly" "data")
```

**3. Fleet Monitor Configuration (`~/aiteamforge/fleet-monitor/config.json`)**
```json
{
  "mode": "server",
  "port": 3000,
  "hostname": "0.0.0.0",
  "sync": {
    "kanban": true,
    "interval": 300
  }
}
```

**4. Claude Code Settings (`~/aiteamforge/claude/settings.json`)**
```json
{
  "hooks": {
    "SessionStart": "~/aiteamforge/kanban-hooks/kanban-session-start.py",
    "PostToolUse": "~/aiteamforge/kanban-hooks/kanban-hook.py",
    "Stop": "~/aiteamforge/kanban-hooks/kanban-stop.py"
  },
  "mcpServers": {
    "kanban": {
      "command": "python3",
      "args": ["~/aiteamforge/kanban-hooks/kanban_mcp_server.py"]
    }
  }
}
```

### Template System

Templates in `share/templates/` are processed by installers:
- Variables like `${TEAM_NAME}` are substituted
- Conditional blocks are evaluated
- Result is written to working directory

**Example template processing:**
```bash
# Template: share/templates/team-startup.sh.template
# Becomes: ~/aiteamforge/ios-startup.sh

# Variables available:
# - ${TEAM_ID}
# - ${TEAM_NAME}
# - ${TEAM_LCARS_PORT}
# - ${INSTALL_DIR}
```

---

## Extension Points

### Adding New Teams

1. Create `share/teams/newteam.conf`
2. Add entry to `share/teams/registry.json`
3. Run `aiteamforge setup` and select new team

No code changes required - team installer reads configuration.

### Adding New Features

1. Create installer module: `libexec/installers/install-newfeature.sh`
2. Add feature prompt in `aiteamforge-setup.sh` Stage 4
3. Add installer call in `aiteamforge-setup.sh` Stage 6
4. Update `config.json` schema to include feature flag

### Custom Commands

Add new commands in `libexec/commands/`:
```bash
# libexec/commands/aiteamforge-mycommand.sh
#!/bin/bash
# Implementation
```

Update `bin/aiteamforge-cli.sh` dispatcher:
```bash
case "${1:-}" in
  mycommand)
    shift
    exec "${AITEAMFORGE_HOME}/libexec/commands/aiteamforge-mycommand.sh" "$@"
    ;;
esac
```

### Custom Installers

Create custom installer for special setup:
```bash
# ~/my-custom-installer.sh
source "$(brew --prefix)/opt/aiteamforge/libexec/ui/lib/wizard-ui.sh"

print_header "My Custom Setup"
# ... installation logic ...
```

---

## Performance Considerations

### Startup Time

- **Initial setup:** 5-10 minutes (includes dependency installation)
- **Team start:** 2-5 seconds per team
- **LCARS start:** < 1 second
- **Fleet Monitor start:** 1-2 seconds

### Memory Usage

- **LCARS server:** ~50 MB
- **Fleet Monitor:** ~100 MB
- **Claude Code agent:** ~500 MB per agent
- **Total baseline:** ~200 MB without agents

### Disk Usage

- **Framework:** ~100 MB
- **Working directory:** ~500 MB (excluding kanban data and worktrees)
- **Kanban backups:** ~10 MB (grows with board size)
- **Fleet Monitor data:** ~50 MB (grows with fleet size)

---

## Security Considerations

### Credentials and Secrets

- **Never stored in config files** - Use macOS Keychain or environment variables
- **GitHub CLI authentication** - Handled by `gh` with OAuth
- **Claude Code authentication** - Handled by Claude SDK
- **Tailscale authentication** - Handled by Tailscale app

### Network Security

- **Fleet Monitor** - HTTP by default, HTTPS via Tailscale Funnel
- **LCARS** - Localhost only by default
- **Tailscale** - End-to-end encrypted VPN

### File Permissions

- **Working directory:** User-owned, mode 755
- **Scripts:** Executable by user only
- **Configs:** Readable/writable by user only

---

## Future Architecture Enhancements

### Planned

- **Plugin system** - Load third-party extensions
- **API server** - REST API for external integrations
- **Event system** - Pub/sub for component communication
- **Remote execution** - Run commands on remote machines via Fleet Monitor

### Possible

- **Container support** - Run in Docker/Podman
- **Cloud sync** - Sync configuration to cloud storage
- **Web UI** - Full web-based management interface
- **Mobile app** - iOS/Android app for monitoring

---

**Next Steps:**
- Review [User Guide](USER_GUIDE.md) for day-to-day usage
- Check [Installation](INSTALLATION.md) for setup details
- Explore [Team Reference](TEAM_REFERENCE.md) for team-specific information
