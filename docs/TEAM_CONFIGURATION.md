# Team Configuration System

**Version:** 1.0.0
**Status:** Implemented
**Last Updated:** 2026-02-17

---

## Overview

The aiteamforge environment supports multiple teams with different specializations, tools, and workflows. The team configuration system provides a data-driven approach to defining and installing teams.

## Architecture

### Components

1. **Team Definitions** (`share/teams/*.conf`)
   - Shell configuration files defining each team's properties
   - Simple key-value format that can be sourced by shell scripts
   - One `.conf` file per team

2. **Team Registry** (`share/teams/registry.json`)
   - JSON metadata for team selection UI
   - Includes display order, categories, icons, recommendations
   - Used by setup wizard for interactive team selection

3. **Team Installer** (`libexec/installers/install-team.sh`)
   - Generic installer that reads team definitions
   - Installs tools, creates directories, generates scripts
   - Can be called by setup wizard or run standalone

### Data Flow

```
User selects team
    ↓
Setup wizard reads registry.json
    ↓
Calls install-team.sh <team-id>
    ↓
Loads share/teams/<team-id>.conf
    ↓
Installs brew dependencies
    ↓
Creates team directories
    ↓
Generates startup/shutdown scripts
    ↓
Configures agent aliases
    ↓
Sets up kanban board
    ↓
Creates LCARS port assignments
```

---

## Team Definition Format

### Structure

Each team configuration file follows this format:

```bash
# Team metadata
TEAM_ID="ios"                          # Unique identifier (lowercase, no spaces)
TEAM_NAME="iOS Development"            # Display name
TEAM_DESCRIPTION="iOS app development" # Short description
TEAM_CATEGORY="platform"               # Category (platform|infrastructure|project|strategic|coordination)
TEAM_COLOR="#FF9500"                   # LCARS display color (hex)
TEAM_LCARS_PORT="8260"                # Default LCARS port
TEAM_TMUX_SOCKET="ios"                # Dedicated tmux socket name

# Repository associations
TEAM_REPOS=(
    "MainEventApp-iOS"
    "DNSFramework"
)

# Homebrew dependencies
TEAM_BREW_DEPS=(
    "swiftlint"
    "xcodegen"
)

TEAM_BREW_CASK_DEPS=(
    "xcode"
)

# Agent personas
TEAM_AGENTS=(
    "picard"      # Lead Feature Developer
    "beverly"     # Bugfix Specialist
    # ...
)

# Startup/shutdown scripts
TEAM_STARTUP_SCRIPT="ios-startup.sh"
TEAM_SHUTDOWN_SCRIPT="ios-shutdown.sh"

# Star Trek theme (optional)
TEAM_THEME="Star Trek: The Next Generation"
TEAM_SHIP="USS Enterprise-D"
```

### Required Variables

- `TEAM_ID` - Unique team identifier
- `TEAM_NAME` - Human-readable team name
- `TEAM_CATEGORY` - Team category
- `TEAM_STARTUP_SCRIPT` - Startup script filename
- `TEAM_SHUTDOWN_SCRIPT` - Shutdown script filename

### Optional Variables

- `TEAM_DESCRIPTION` - Team description
- `TEAM_COLOR` - LCARS display color
- `TEAM_LCARS_PORT` - LCARS port number
- `TEAM_TMUX_SOCKET` - tmux socket name
- `TEAM_REPOS` - Associated repositories
- `TEAM_BREW_DEPS` - Homebrew packages to install
- `TEAM_BREW_CASK_DEPS` - Homebrew cask packages to install
- `TEAM_AGENTS` - Claude Code agent personas
- `TEAM_THEME` - Star Trek theme
- `TEAM_SHIP` - Star Trek ship/station name

---

## Team Categories

| Category | Purpose | Examples |
|----------|---------|----------|
| `platform` | Platform-specific development teams | iOS, Android, Firebase |
| `infrastructure` | Dev-team infrastructure and frameworks | Academy, DNS Framework |
| `project` | Project-based full-stack teams | Freelance |
| `coordination` | Cross-platform coordination | MainEvent |
| `strategic` | Planning, legal, research | Command, Legal, Medical |

---

## Team Installer Usage

### Install a Single Team

```bash
./libexec/installers/install-team.sh <team-id> [--aiteamforge-dir <path>]
```

**Examples:**

```bash
# Install iOS team to default location (~/aiteamforge)
./libexec/installers/install-team.sh ios

# Install Android team to custom location
./libexec/installers/install-team.sh android --aiteamforge-dir /opt/aiteamforge

# Install Academy team
./libexec/installers/install-team.sh academy
```

### List Available Teams

```bash
./libexec/installers/install-team.sh
```

### Test Team Definitions

```bash
./libexec/installers/test-install-team.sh
```

---

## What Gets Installed

For each team, the installer creates:

### 1. Directory Structure

```
~/aiteamforge/
├── <team-id>/
│   ├── personas/
│   │   ├── agents/          # Agent persona markdown files
│   │   ├── avatars/         # Agent avatar images
│   │   └── docs/            # Team-specific docs
│   ├── scripts/             # Team-specific scripts
│   └── terminals/           # Terminal configurations
```

### 2. Startup/Shutdown Scripts

- `~/aiteamforge/<team-id>-startup.sh` - Team startup script
- `~/aiteamforge/<team-id>-shutdown.sh` - Team shutdown script

Generated from templates with variable substitution.

### 3. Kanban Board

- `~/aiteamforge/kanban/<team-id>-board.json` - Empty kanban board structure

### 4. LCARS Port Assignments

For each agent in the team:
- `~/aiteamforge/lcars-ports/<team-id>-<agent>.port` - Port number
- `~/aiteamforge/lcars-ports/<team-id>-<agent>.theme` - Color theme
- `~/aiteamforge/lcars-ports/<team-id>-<agent>.order` - Display order

### 5. Agent Aliases

Adds to `~/aiteamforge/claude_agent_aliases.sh`:

```bash
alias ios-picard='claude --agent-path "$AITEAMFORGE_DIR/claude/agents/iOS Development/picard"'
alias ios-beverly='claude --agent-path "$AITEAMFORGE_DIR/claude/agents/iOS Development/beverly"'
# ...
```

### 6. Homebrew Dependencies

Installs specified packages and casks (checks for existing installations first).

---

## Adding a New Team

To add a new team to the system:

### 1. Create Team Definition

Create `share/teams/<team-id>.conf`:

```bash
TEAM_ID="myteam"
TEAM_NAME="My Team"
TEAM_DESCRIPTION="My team description"
TEAM_CATEGORY="platform"
TEAM_COLOR="#00FF00"
TEAM_LCARS_PORT="8400"
TEAM_TMUX_SOCKET="myteam"

TEAM_REPOS=(
    "MyRepo"
)

TEAM_BREW_DEPS=(
    "tool1"
    "tool2"
)

TEAM_BREW_CASK_DEPS=()

TEAM_AGENTS=(
    "agent1"
    "agent2"
)

TEAM_STARTUP_SCRIPT="myteam-startup.sh"
TEAM_SHUTDOWN_SCRIPT="myteam-shutdown.sh"

TEAM_THEME="My Theme"
TEAM_SHIP="My Ship"
```

### 2. Update Team Registry

Add entry to `share/teams/registry.json`:

```json
{
  "id": "myteam",
  "name": "My Team",
  "category": "platform",
  "description": "My team description",
  "color": "#00FF00",
  "theme": "My Theme",
  "icon": "🚀",
  "order": 11,
  "recommended": false
}
```

### 3. Test the Configuration

```bash
./libexec/installers/test-install-team.sh
```

### 4. Install the Team

```bash
./libexec/installers/install-team.sh myteam
```

That's it. No code changes required - the installer reads your configuration and sets everything up.

---

## Team Configuration Reference

### Current Teams

| Team ID | Name | Category | Agents | Brew Deps |
|---------|------|----------|--------|-----------|
| `ios` | iOS Development | platform | 7 | 2 |
| `android` | Android Development | platform | 7 | 2 |
| `firebase` | Firebase Development | platform | 8 | 2 |
| `academy` | Starfleet Academy | infrastructure | 4 | 4 |
| `dns` | DNS Framework | infrastructure | 6 | 1 |
| `freelance` | Freelance Projects | project | 6 | 6 |
| `command` | Starfleet Command | strategic | 2 | 1 |
| `legal` | JAG Legal | strategic | 1 | 0 |
| `medical` | Starfleet Medical | strategic | 1 | 0 |
| `mainevent` | MainEvent Coordination | coordination | 1 | 2 |

---

## Integration with Setup Wizard

The setup wizard (`bin/aiteamforge-setup`) will:

1. Load `share/teams/registry.json`
2. Display teams grouped by category
3. Allow user to select which teams to install
4. Call `install-team.sh` for each selected team
5. Handle dependencies (shared brew packages installed once)
6. Generate master startup script that calls all team startups

---

## Design Principles

### Data-Driven

Team definitions are data, not code. Adding a team requires creating a configuration file, not modifying installer logic.

### Simple Format

Shell-sourceable `.conf` files are easy to read, write, and maintain. No complex parsing required.

### Generic Installer

The installer reads team definitions generically. All teams use the same installation logic.

### No Duplication

Shared dependencies (like `jq`, `node`, etc.) are only installed once, even if multiple teams require them.

### Graceful Degradation

If a template doesn't exist, the installer creates a minimal version. Missing optional dependencies don't block installation.

### Testable

`test-install-team.sh` validates all team definitions without actually installing anything.

---

## Future Enhancements

### Planned

- [ ] Template system for startup/shutdown scripts
- [ ] Persona template library for common agent types
- [ ] Team dependency graph (team A requires team B)
- [ ] Uninstall functionality
- [ ] Update/upgrade team configurations
- [ ] Export team configuration for sharing

### Possible

- [ ] Team configuration wizard (interactive .conf creation)
- [ ] Validate LCARS port conflicts across teams
- [ ] Auto-generate team summary documentation
- [ ] Team configuration schema validation
- [ ] Support for team-specific environment variables

---

## Troubleshooting

### Team Not Found

```
Error: Team configuration not found: share/teams/xyz.conf
```

**Solution:** Check that `xyz.conf` exists and the team ID is correct.

### Missing Dependencies

```
Warning: Failed to install <package>
```

**Solution:** Install manually with `brew install <package>`. The installer continues even if some dependencies fail.

### Port Conflicts

If two teams have the same `TEAM_LCARS_PORT`, they'll conflict when both run simultaneously.

**Solution:** Assign unique port ranges per team. Check `share/teams/*.conf` for conflicts.

### Registry Validation Fails

```
Registry contains team 'xyz' but no .conf file exists
```

**Solution:** Either create `xyz.conf` or remove the entry from `registry.json`.

---

## Development Notes

### Testing Changes

After modifying team configurations:

```bash
# Validate syntax and structure
./libexec/installers/test-install-team.sh

# Test installation to temp directory
./libexec/installers/install-team.sh <team-id> --aiteamforge-dir /tmp/test-aiteamforge

# Verify results
ls -la /tmp/test-aiteamforge/

# Cleanup
rm -rf /tmp/test-aiteamforge
```

### Debugging

Set `set -x` at the top of `install-team.sh` to see detailed execution:

```bash
#!/bin/bash
set -ex  # Added 'x' for debugging
```

---

**End of Documentation**
