# AITeamForge Homebrew Tap

![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)
![License](https://img.shields.io/badge/license-MIT-blue)
![Version](https://img.shields.io/badge/version-1.0.0-green)
![macOS](https://img.shields.io/badge/macOS-Big_Sur+-blue)

**AITeamForge** - AI-powered multi-team development infrastructure

> This Homebrew tap provides the `aiteamforge` formula for installing and managing the AITeamForge environment on macOS - a comprehensive AI-assisted development platform with specialized teams, visual kanban management, and multi-machine coordination.

## What is AITeamForge?

AITeamForge is a comprehensive development environment designed for AI-assisted development with multiple specialized teams.

### Key Features

#### 🎯 Multi-Team Architecture
Separate teams (iOS, Android, Firebase, etc.) with distinct AI agents, kanban boards, and workflows.

```bash
aiteamforge start ios      # Start iOS team
ios-picard              # Launch Captain Picard agent
kb-list                 # View iOS kanban board
```

#### 🖥️ LCARS Kanban System
Star Trek-inspired visual kanban board with real-time updates and automatic agent tracking.

```bash
kb-add "New feature"            # Add kanban item
kb-move XIOS-0042 in_progress   # Move to in progress
kb-run XIOS-0042                # Create worktree and start work
```

**Access in browser:** http://localhost:8082

#### 🤖 Claude Code Integration
AI pair programming with team-specific personas that auto-track work in kanban.

```bash
ios-picard      # Lead Feature Developer
ios-beverly     # Bugfix Specialist
ios-data        # Testing & QA
```

Each agent has a unique personality and specialization based on Star Trek characters.

#### 🔄 Git Worktree Management
Advanced git workflow automation for parallel development.

```bash
wt-create feature/new-ui    # Create worktree
wt-list                     # List worktrees
wt-remove feature/new-ui    # Clean up after merge
```

#### 🌐 Fleet Monitor
Multi-machine coordination for distributed development across multiple Macs.

```bash
# View all machines, agents, and kanban state
open http://localhost:3000
```

#### 💻 Terminal Automation
iTerm2 integration with automated window/tab management (optional).

```bash
aiteamforge start ios
# Automatically opens terminals, configures environments
```

## Quick Start

Get up and running in under 5 minutes:

```bash
# 1. Add tap and install
brew tap DoubleNode/aiteamforge
brew install aiteamforge

# 2. Run interactive setup wizard
aiteamforge setup

# 3. Verify installation
aiteamforge doctor

# 4. Start your environment
aiteamforge start ios
```

**That's it!** Your AI-powered development environment is ready.

## Installation

### Prerequisites

- **macOS Big Sur (11.0) or later**
- **Homebrew** - [Install here](https://brew.sh) if you don't have it

### Step-by-Step Installation

**Step 1: Add the AITeamForge tap**
```bash
brew tap DoubleNode/aiteamforge
```

**Step 2: Install AITeamForge**
```bash
brew install aiteamforge
```

This installs the framework and required dependencies (Python 3, Node.js, jq, GitHub CLI, Git).

**Step 3: Run the Setup Wizard**
```bash
aiteamforge setup
```

The interactive wizard guides you through:
1. ✓ Checking dependencies
2. ✓ Installing missing tools (if needed)
3. ✓ Selecting teams (iOS, Android, Firebase, etc.)
4. ✓ Configuring features (LCARS Kanban, Fleet Monitor, etc.)
5. ✓ Setting up shell environment
6. ✓ Installing system services

**Typical setup time: 5-10 minutes** (depending on how many dependencies need installation).

**Step 4: Restart Your Terminal**
```bash
source ~/.zshrc
```

**Step 5: Verify Everything Works**
```bash
aiteamforge doctor
```

### Kanban Board Organization

When setting up teams with profiles (e.g., Finance with personal/work profiles), the installer detects existing profile-scoped canonical boards and skips creating a stub board in the parent directory. This prevents dual-board warnings from recurring on subsequent installer runs.

**Example:** If `~/finance/personal/kanban/finance-personal-board.json` already exists, the installer will not create `~/finance/finance-board.json`. If you have an older installation with dual boards, resolve the warning with:

```bash
kb-quarantine-stub finance  # Disables the stub board warning
```

## Usage

### Main Commands

```bash
aiteamforge setup      # Run interactive setup wizard
aiteamforge doctor     # Health check and diagnostics
aiteamforge status     # Show current environment status
aiteamforge start      # Start aiteamforge environment
aiteamforge stop       # Stop aiteamforge environment
aiteamforge upgrade    # Upgrade components
aiteamforge help       # Show help information
```

### Example Usage

**For iOS Development:**
```bash
# Install and select iOS team
aiteamforge setup  # Choose "iOS Development"

# Start iOS environment
aiteamforge start ios

# Use iOS agents
ios-picard      # Captain Picard - Lead Feature Developer
ios-beverly     # Dr. Crusher - Bugfix Specialist

# Manage tasks
kb-list         # List kanban items
kb-add "New feature"
```

**For Multi-Platform Development:**
```bash
# Install iOS, Android, and Firebase teams
aiteamforge setup  # Choose multiple teams

# Start all teams
aiteamforge start

# Each team has its own kanban board and agents
```

**For Multi-Machine Setup:**
```bash
# On main machine (server)
aiteamforge setup  # Enable "Fleet Monitor" as server

# On secondary machines (clients)
aiteamforge setup  # Enable "Fleet Monitor" as client

# Monitor entire fleet
open http://localhost:3000
```

## Requirements

### Required Dependencies
- **macOS** Big Sur or later
- **Homebrew** package manager
- **Python 3** (3.8 or later)
- **Node.js** (18.0 or later)
- **jq** JSON processor
- **Git** version control
- **GitHub CLI** (`gh`)
- **iTerm2** terminal emulator
- **Claude Code** AI pair programmer

The setup wizard will check for and offer to install missing dependencies.

### Optional Dependencies
- **Tailscale** - For multi-machine coordination
- **ImageMagick** - For avatar/image processing
- **tmux** - For Fleet Monitor

## Architecture

### Installation Locations

**Framework** (Homebrew-managed):
```
$(brew --prefix)/opt/aiteamforge/libexec/
├── bin/                    # Core executables
├── scripts/                # Automation scripts
├── config/templates/       # Configuration templates
├── docs/                   # Documentation
├── skills/                 # Claude Code skills
├── lcars-ui/              # LCARS Kanban UI
├── kanban-hooks/          # Kanban automation
└── ...
```

**Working Directory** (user-managed):
```
~/aiteamforge/                 # Default location
├── templates/              # Copied from framework
├── docs/                   # Copied from framework
├── skills/                 # Copied from framework
├── kanban/                 # Kanban board data
├── teams/                  # Team configurations
├── scripts/                # Generated scripts
└── .aiteamforge-config        # Installation metadata
```

### Two-Layer Design

1. **Framework Layer** (`$(brew --prefix)/opt/aiteamforge/libexec/`)
   - Installed via Homebrew
   - Read-only template files
   - Upgraded via `brew upgrade aiteamforge`

2. **Working Layer** (`~/aiteamforge` or custom location)
   - Created by `aiteamforge setup`
   - User-specific configuration
   - Kanban data, team configs, generated scripts
   - Preserved across framework upgrades

## Components

### LCARS Kanban System
Web-based kanban board with Star Trek LCARS interface:
- Real-time board updates
- Multi-team support
- Agent status tracking
- Calendar integration
- Health monitoring

### Team Directories
Pre-configured teams with personas:
- **Academy** - Infrastructure and tooling
- **iOS** - iOS app development
- **Android** - Android app development
- **Firebase** - Backend/cloud functions
- **Command** - Strategic planning
- **DNS** - DNS framework
- **Freelance** - Client projects
- **Legal** - Legal/compliance
- **MainEvent** - Cross-platform coordination
- **Medical** - Health/diagnostics

### Claude Code Integration
AI agents with team-specific personas:
- Automated kanban tracking
- Session management
- Tool use hooks
- Custom skills and workflows

### Fleet Monitor
Multi-machine coordination (optional):
- Monitor multiple aiteamforge installations
- Centralized kanban aggregation
- Cross-machine agent status
- Tailscale integration

## Configuration

### Customize Installation Location

```bash
aiteamforge setup --install-dir ~/my-custom-location
```

### Upgrade Existing Installation

```bash
# Upgrade framework
brew upgrade aiteamforge

# Upgrade working directory
aiteamforge setup --upgrade
```

### Refreshing Dynamic Profiles After Upgrade

**Why this exists:** When AITeamForge installs its iTerm2 dynamic profiles for the
first time, the installer skips the file on subsequent runs to protect your
customizations. This means bug fixes shipped in the profile (such as the v0.8.27
Mouse Reporting and Dynamic Profile Parent Name corrections) do not propagate
automatically when you run `brew upgrade aiteamforge`.

**When to use it:** After `brew upgrade aiteamforge` when the release notes mention
dynamic profile changes — for example, a fix to click-to-navigate in the LCARS Web
browser tab, or a correction to profile inheritance.

**How to run it:**

```bash
aiteamforge setup --refresh-profiles
```

**What gets refreshed (AITeamForge-owned keys):**
- `Name` — profile identity used by iTerm2 for lookups
- `Guid` — immutable profile anchor
- `Tags` — AITeamForge visibility tag (`["aiteamforge"]`)
- `Custom Command` — must be `"Browser"` for LCARS Web inline browser mode
- `Mouse Reporting` — required for click-to-navigate in the browser tab
- `Dynamic Profile Parent Name` — links the profile to its parent for font/color inheritance
- `Background Color` — functional pure-black background behind the browser view
- `Initial URL` — source placeholder URL (overwritten at team start with the correct port)

**What is preserved (your settings):**
- Fonts (`Normal Font`, `Non Ascii Font`, and related rendering flags)
- Colors (`Foreground Color` and any other color customizations)
- Window geometry (`Columns`, `Rows`, `Window Type`)
- Transparency and blur settings
- Scrollback buffer size
- Key mappings and triggers
- All other personal preferences

**Rollback:** Before writing changes the merge tool creates a timestamped backup of
your existing profiles file at the same location:

```
~/Library/Application Support/iTerm2/DynamicProfiles/aiteamforge-lcars.json.bak-<timestamp>
```

Restore it by copying it back over the live file and letting iTerm2 hot-reload.

For maintainers who want to know which keys are in which bucket and why, see
[docs/refresh-profiles-design.md](docs/refresh-profiles-design.md).

### Cockpit Install (Remote Connect Only)

The **cockpit profile** is a minimal install for machines that connect *into* teams
running on a primary dev machine over Tailscale — without running any team
infrastructure locally.

**Who it is for:** Laptop users, second workstations, or thin clients that need to
drive a remote AITeamForge session without maintaining local kanban boards, LCARS
servers, or team directories.

**How to install:**

```bash
aiteamforge setup --cockpit-only
# --connect-only is an accepted alias
```

The setup wizard skips team selection entirely — all connect scripts are installed
unconditionally.

**What a cockpit install includes:**

| Component | Included |
|-----------|----------|
| `<team>-connect.sh` scripts (all teams) | Yes |
| Python venv with `iterm2` package | Yes |
| `iterm2_window_manager.py` | Yes |
| LCARS dynamic profile JSON | Yes |
| `set-lcars-profile-browser.py` (iTerm2 plugin) | Yes |

**What a cockpit install excludes:**

| Component | Excluded |
|-----------|----------|
| Team working directories (`~/aiteamforge/<team>/`) | Omitted |
| Kanban boards and `kb-*` helpers | Omitted |
| LCARS UI server | Omitted |
| Persona markdown files and agent avatars | Omitted |
| Shell aliases, cc-aliases, statusline scripts | Omitted |
| Team zshrc fragments | Omitted |

**Typical workflow:**

```bash
# On cockpit machine: connect into a remote team running on another host
academy-connect.sh darren-m4-mini

# The remote team's full environment opens in iTerm2 over Tailscale
# Your local machine stays clean — no team state is created or maintained here
```

**Switching to a full install:** There is no in-place migration from cockpit to full.
Re-run `aiteamforge setup` (without `--cockpit-only`) on the machine to perform a
complete installation.

**Health checks:** `aiteamforge doctor` recognizes the cockpit profile via a
`.install-profile` marker file and does not report missing kanban boards, LCARS
servers, or team directories as errors.

### Uninstall

```bash
# Remove configuration (keeps framework)
aiteamforge setup --uninstall

# Remove framework
brew uninstall aiteamforge
```

## Troubleshooting

### Health Check

```bash
aiteamforge doctor
```

Checks:
- External dependencies
- Framework installation
- Configuration files
- Running services
- File permissions

### Verbose Diagnostics

```bash
aiteamforge doctor --verbose
```

### Check Specific Component

```bash
aiteamforge doctor --check dependencies
aiteamforge doctor --check services
aiteamforge doctor --check config
```

### Common Issues

**LCARS server not starting**
```bash
# Check port 8082 availability
lsof -i :8082

# Start manually
cd ~/aiteamforge/lcars-ui
python3 server.py
```

**Claude Code not authenticated**
```bash
claude auth login
```

**GitHub CLI not authenticated**
```bash
gh auth login
```

**Missing dependencies**
```bash
aiteamforge doctor
# Follow install instructions for missing deps
```

## Documentation

Comprehensive documentation is available in the `docs/` directory:

### Getting Started
- **[Quick Start](docs/QUICK_START.md)** - Get up and running in 5 minutes
- **[Installation Guide](docs/INSTALLATION.md)** - Complete installation instructions
- **[User Guide](docs/USER_GUIDE.md)** - Day-to-day usage and commands

### Advanced Topics
- **[Multi-Machine Setup](docs/MULTI_MACHINE.md)** - Fleet Monitor and multi-machine coordination
- **[Architecture](docs/ARCHITECTURE.md)** - Technical architecture and design
- **[Team Reference](docs/TEAM_REFERENCE.md)** - Complete team and agent reference

### Support
- **[Troubleshooting](docs/TROUBLESHOOTING.md)** - Problem solving guide
- **[Contributing](CONTRIBUTING.md)** - How to contribute to aiteamforge

### Quick Reference

**After installation, docs are also available locally:**
```bash
ls ~/aiteamforge/docs/
cat ~/aiteamforge/docs/QUICK_START.md
```

## FAQ

### What is AITeamForge?

AITeamForge is a comprehensive macOS development environment that combines:
- **AI pair programming** with Claude Code agents
- **Visual task management** with LCARS Kanban
- **Multi-machine coordination** with Fleet Monitor
- **Terminal automation** with iTerm2 integration

### Do I need Claude Code?

No, it's optional. AITeamForge works standalone, but Claude Code integration provides AI-assisted development with automatic kanban tracking.

### Can I use this for team development?

Yes! AITeamForge supports both solo and team development. Fleet Monitor enables multi-machine coordination perfect for distributed teams.

### What teams are available?

AITeamForge includes 10 pre-configured teams:
- **Platform:** iOS, Android, Firebase
- **Infrastructure:** Academy, DNS Framework
- **Project-Based:** Freelance
- **Coordination:** MainEvent
- **Strategic:** Command, Legal, Medical

See [Team Reference](docs/TEAM_REFERENCE.md) for details.

### Can I add custom teams?

Yes! Teams are defined in data files, so you can add custom teams without modifying code. See [ADDING_A_TEAM](docs/ADDING_A_TEAM.md).

### How much disk space does it need?

- **Framework:** ~100 MB
- **Working directory:** ~500 MB (excluding your kanban data and worktrees)
- **Full installation:** 2-5 GB depending on how many teams you install

### Is my data safe during upgrades?

Yes! The two-layer architecture separates the framework (Homebrew-managed) from your working directory (user-managed). Upgrades never touch your kanban data or configurations.

### How do I uninstall?

```bash
aiteamforge uninstall     # Remove configuration
brew uninstall aiteamforge
brew untap DoubleNode/aiteamforge
```

Your `~/aiteamforge/` directory is preserved. Delete it manually if desired.

### What if something breaks?

Run `aiteamforge doctor` for diagnostics. See [Troubleshooting](docs/TROUBLESHOOTING.md) for common issues and solutions.

## Development

### Formula Development

```bash
# Clone this tap
brew tap DoubleNode/aiteamforge
cd $(brew --repository DoubleNode/aiteamforge)

# Edit formula
vim Formula/aiteamforge.rb

# Test formula
brew install --build-from-source aiteamforge
brew test aiteamforge
```

### Testing

```bash
# Run formula tests
brew test aiteamforge

# Manual testing
aiteamforge doctor --verbose
```

## License

MIT License - See formula for details

## Support

- **Issues**: https://github.com/DoubleNode/aiteamforge/issues
- **Documentation**: `~/aiteamforge/docs/`
- **Health Check**: `aiteamforge doctor`

## Version

Current version: **1.0.0**

**Development Status:** Phase 3 Complete (Interactive Setup Wizard)
- ✅ Setup wizard implemented
- ✅ LCARS-styled UI library
- 🚧 Installer modules (Phases 4-8 in progress)

```bash
aiteamforge --version
```
