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

## Python Dependencies

Python library dependencies are installed into a tap-owned virtual environment
at `$HOMEBREW_PREFIX/var/aiteamforge/venv`. The venv is provisioned by the
Formula's `post_install` step from the pinned dep list in
`share/requirements.txt`. All bin stubs and libexec scripts that require
third-party Python libraries invoke Python via the `$AITEAMFORGE_PYTHON`
environment variable, which `post_install` resolves to the venv interpreter.

- How to add a new dependency: [`docs/adding-a-python-dep.md`](adding-a-python-dep.md)
- Design rationale and channel selection: [`docs/python-dep-channel-design.md`](python-dep-channel-design.md)

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
TEAM_REPOS=("AcmeCorpApp-iOS" "DNSFramework")  # repo names configured via organization.yaml
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

## Install Profiles

`aiteamforge setup` supports two mutually exclusive install profiles: `full` (the
default) and `cockpit`. The profile controls which installer steps run and which
components are written to the working layer.

### Profile Selection

```bash
aiteamforge setup               # full profile (default)
aiteamforge setup --cockpit-only  # cockpit profile
aiteamforge setup --connect-only  # alias for --cockpit-only
```

### Profile Marker File

At the end of setup, the installer writes a single-word marker to
`$AITEAMFORGE_DIR/.install-profile` containing either `full` or `cockpit`. This
file is the authoritative record of how the working directory was provisioned.

```
~/aiteamforge/
└── .install-profile    # contains "cockpit" or "full"
```

### Component Matrix

The table below shows which components are installed by each profile.

| Component | full | cockpit |
|-----------|------|---------|
| `<team>-connect.sh` scripts (all teams) | Yes | Yes |
| Python venv with `iterm2` package | Yes | Yes |
| `iterm2_window_manager.py` | Yes | Yes |
| `aiteamforge-lcars.json` dynamic profile | Yes | Yes |
| `set-lcars-profile-browser.py` (iTerm2 plugin) | Yes | Yes |
| Team working directories (`~/aiteamforge/<team>/`) | Yes | No |
| Kanban boards and `kb-*` helpers | Yes | No |
| LCARS UI server | Yes | No |
| Persona markdown files and agent avatars | Yes | No |
| Shell aliases, cc-aliases, worktree-aliases | Yes | No |
| Statusline scripts | Yes | No |
| Knowledge base directories | Yes | No |
| Team zshrc fragments | Yes | No |
| Fleet Monitor | Yes | No |

The connect scripts for every available team are always installed regardless of
profile. This depends on XACA-0160, which renders connect scripts universally rather
than only for selected teams.

### Doctor Integration

`aiteamforge doctor` reads `.install-profile` before running its component checks.
When the profile is `cockpit`, checks for kanban boards, LCARS servers, team
directories, and other cockpit-excluded components are skipped entirely — they are
absent by design, not by error.

```
aiteamforge doctor (cockpit install)
  ✓ Dependencies
  ✓ Framework installation
  ✓ Connect scripts
  ✓ Python venv (iterm2)
  ✓ Dynamic profile
  — Kanban boards        [skipped: cockpit profile]
  — LCARS server         [skipped: cockpit profile]
  — Team directories     [skipped: cockpit profile]
```

### Design Rationale

**Why cockpit exists:** Some machines — laptops, second workstations, thin clients —
only ever connect *into* teams running on a primary dev machine over Tailscale. A
full install on these machines creates ~300 MB of team infrastructure that is never
used locally. The cockpit profile ships only what is needed to open a remote
session.

**Why the profile is immutable per install:** Mixing partial and full components in
the same working directory risks inconsistent state. If a cockpit user later needs
full capabilities, they re-run `aiteamforge setup` without `--cockpit-only`. There is
no in-place migration path.

**XACA-0160 dependency:** The cockpit profile relies on XACA-0160 (always render all
connect scripts for every team) so that cockpit machines receive a complete set of
`<team>-connect.sh` scripts without requiring team selection during setup.

---

## Per-Team Persona Architecture (XACA-0285)

### Overview

Claude Code agent personas are deployed per-team-repository rather than user-level. This architecture reduces token usage ~85% by loading only the personas for the team you're currently working in, and allows teams to version-control and own their persona definitions.

### Three-Layer Model

**1. Master (canonical source):** `~/dev-team/.claude/agents-master/`
- All 68 persona files organized by team slug: `academy/`, `ios/`, `android/`, `firebase/`, `command/`, `dns/`, `finance/`, `legal/`, `medical/`, `mainevent/`, `freelance/`
- Maintained by Academy team
- Tracked in main git repo

**2. Manifest:** `~/dev-team/.claude/personas-manifest.json`
- JSON file listing which teams deploy to which repositories
- 13 deployment entries (e.g., iOS repo gets iOS + MainEvent personas)
- Single source of truth for "which personas go where"
- Editable for hot-swaps and dynamic persona variants

**3. Team repo deployments:** `<team-repo>/.claude/agents/`
- Synced copies of the appropriate master personas
- Per-repo git-tracked (not symlinks)
- Token-loaded per-session: opening iOS terminal loads only iOS + MainEvent personas (~14), not all 68

### Install Flow

During `aiteamforge setup --install-path <dir>`:

1. Framework copies `.claude/agents-master/` and `.claude/personas-manifest.json` from tap share (if not present)
2. `install-claude-config.sh` calls `kb-sync-personas sync --all`
3. Each team repo's `.claude/agents/` is populated from master based on manifest
4. User-level `~/.claude/agents/` remains empty post-migration

### Sync Mechanism

The `kb-sync-personas` command (from Academy's `~/dev-team/scripts/`) reads master and manifest, then:
- `sync <team|--all>` — Copy master files to target repos
- `check [team]` — Detect drift; exit 1 on mismatch
- `diff <team>` — Show per-file diffs vs. master
- `list` — Show all deployments and their status

**Safety guardrails:**
- Refuses to write into `/worktrees/` (preserves parallel development)
- Skips missing target repos with WARN
- Writes `.synced-from-master` marker (timestamp, commit SHA, schema version)

### Token Savings

| Context | Pre-XACA-0285 | Post-XACA-0285 | Reduction |
|---------|---------------|----------------|-----------|
| iOS dev session | 68 personas | 14 (iOS + MainEvent) | ~79% |
| Android dev session | 68 personas | 14 (Android + MainEvent) | ~79% |
| Firebase dev session | 68 personas | 14 (Firebase + MainEvent) | ~79% |
| Academy session | 68 personas | 4 (Academy only) | ~94% |
| Average across fleet | 68 personas | 11 (median) | ~85% |

### Naming Disambiguation

Two collisions were resolved by suffix:
- `janeway` (Command team, Strategic) remains
- `janeway-me` (MainEvent team, Lead Feature) — renamed to avoid collision
- `paris` (Command team, Communications) remains
- `paris-me` (MainEvent team, UX) — renamed to avoid collision

The rename applies to both frontmatter `name:` field and Task subagent_type references.

### Multi-Machine Sync

On a fresh machine or after pulling from main:
```bash
~/dev-team/scripts/kb-sync-personas sync --all
```

Master is canonical; per-repo edits are valid but sync overwrites them. Use the manifest to describe variants; edit master for shared updates.

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

### CR (Change Request) Lifecycle Axis

The kanban schema supports an optional CR-lifecycle axis layered orthogonally to the existing `status` and `releaseAssignment` axes. CR support is **per-board opt-in** via `teamConfig.crSupport.enabled` (boolean, default `false`).

**Three orthogonal axes per item:**
1. **`status`** — kanban workflow state (`backlog`, `in_progress`, `pr_review`, `completed`, …). Pre-existing.
2. **`releaseAssignment`** — environment promotion track (`DEV`, `QA`, `BETA`, `PROD`, …). Pre-existing.
3. **`crState`** — CR lifecycle state (`cr-drafted`, `cr-submitted`, `cr-approved`, `implementing`, `deployed-dev`, `deployed-prod`, `emergency-deployed`, …). Added by XACA-0291.

The three axes do not gate each other. An item can be `status=in_progress`, `releaseAssignment=PROD`, `crState=cr-approved` simultaneously. State transitions on one axis do not constrain the others.

**Cycle-time fields are derived, not stored.** All `cr_cycle_*_days` values and `deploy_estimate_delta_days` are computed at read time from the persisted `cr_*_at` timestamps. The schema document marks them with `derived: true` and a `formula` string. No code path persists derived values — preserves the single source of truth and avoids drift.

**Disabled-state invariant.** When `crSupport.enabled=false` (or absent), every `kb-cr` subcommand exits 0 with a single informational message and performs zero side effects. UI components that consume CR fields short-circuit symmetrically. The migration script adds `crStates` + `teamConfig.crSupport={enabled:false}` to a board without touching item-level data — the board behaves byte-for-byte like its pre-migration state until the flag is flipped. This is what makes the system safely reversible per board.

See `homebrew-tap/share/templates/kanban/cr-schema.json` for the canonical schema and the [CR Schema Opt-In Workflow](USER_GUIDE.md#cr-change-request-schema--opt-in-workflow) section of the User Guide for operator instructions.

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
