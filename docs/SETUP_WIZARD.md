# AITeamForge Setup Wizard

**Version:** 1.0.0
**Component:** Interactive environment installer
**Phase:** 3 (Homebrew Tap Infrastructure)

---

## Overview

The aiteamforge setup wizard (`aiteamforge-setup`) is an interactive CLI tool that guides new users through setting up the AITeamForge on their machine. It runs after `brew install aiteamforge` and handles all configuration and installation tasks.

## Features

### 1. **LCARS-Styled UI**
- Color-coded output using LCARS color scheme (amber/blue/red/lilac)
- Progress indicators and status displays
- Clear visual hierarchy and section headers
- Professional, polished user experience

### 2. **Interactive Workflow**
The wizard guides users through seven stages:

1. **Welcome & Prerequisites Check**
   - Displays welcome banner
   - Checks for required tools (git, node, python3, gh, jq)
   - Checks for optional tools (claude, brew)
   - Reports missing dependencies with install instructions
   - Allows continuing with warnings for optional deps

2. **Machine Identity**
   - Prompts for machine name/identifier (e.g., "macbook-pro-office")
   - Prompts for user display name
   - Used for Fleet Monitor identification

3. **Team Selection**
   - Presents available teams with descriptions
   - Allows multi-select (comma-separated or space-separated)
   - Teams: iOS, Android, Firebase, Academy, DNS, Freelance, Command, Legal, Medical, `mainevent`

4. **Feature Selection**
   - LCARS Kanban System (default: yes)
   - Fleet Monitor (default: no - only for multi-machine setups)
   - Shell Environment (default: yes)
   - Claude Code Configuration (default: yes)
   - iTerm2 Integration (default: no - optional)

4.5. **Change Request (CR) Workflow** *(new in XACA-0470)*
   - Prompted per selected team: "Enable Change Request workflow for team '<X>'?" (default No)
   - If any team opts in, captures shared Atlassian credentials once (see [CR Workflow Setup](#change-request-cr-workflow-setup) below)
   - Skipped in non-interactive, auto-upgrade, and cockpit modes (migration handles those cases)

5. **Configuration Generation**
   - Creates `~/.aiteamforge/config.json` with all selections
   - Records machine identity, teams, features, paths, timestamp
   - This config drives all subsequent installers

6. **Installation Orchestration**
   - Calls each selected installer module in order:
     1. Shell environment (Phase 5 - TODO)
     2. Claude Code config (Phase 6 - TODO)
     3. LCARS Kanban (Phase 7 - TODO)
     4. Fleet Monitor (Phase 8 - TODO)
     5. Team-specific setup (Phase 4 - TODO)
   - Shows progress with LCARS-style progress bars
   - Handles errors gracefully (continue with warnings, don't abort)

7. **Summary & Next Steps**
   - Shows what was installed
   - Displays any warnings or manual steps needed
   - Shows quick-start commands

### 3. **Non-Interactive Mode**
For scripted/automated installations:
```bash
aiteamforge-setup --non-interactive
```
- Reads from existing config file or uses defaults
- No prompts
- Suitable for CI/CD or remote provisioning

### 4. **Dry Run Mode**
Preview changes without applying them:
```bash
aiteamforge-setup --dry-run
```
- Shows what would be installed
- Prints config that would be generated
- No files created or modified
- Useful for testing or pre-approval review

### 5. **Idempotent & Safe**
- Safe to run multiple times
- Won't overwrite existing configurations without confirmation
- Each installer module is idempotent
- Can be re-run to add new teams or features

---

## Change Request (CR) Workflow Setup

The CR workflow connects AITeamForge to your Atlassian Confluence instance so that
change requests can be created and polled automatically per team. It is entirely
optional and opt-in per team.

### Wizard Prompts (STEP 3.5)

After team selection the wizard asks once per selected team:

```
Enable Change Request workflow for team 'ios'? [y/N]
```

The default is **No**. Teams you decline are recorded as disabled and will not get a
CR poller LaunchAgent.

If at least one team answers Yes, the wizard prompts once for **shared Atlassian credentials**:

```
Atlassian API credentials (shared across CR-enabled teams)
  Create an API token: https://id.atlassian.com/manage-profile/security/api-tokens
  Atlassian account email: you@example.com
  Atlassian API token (hidden): ••••••••••••••••
  Confluence site [mainevent.atlassian.net]: <Enter to accept default>
  Confluence space key [DPD2]: <Enter to accept default>
```

Defaults for site (`mainevent.atlassian.net`) and space key (`DPD2`) can be accepted
with Enter or overridden by typing the desired value. If email or token are left
blank the credential write is skipped and the wizard prints a reminder to re-run
`aiteamforge upgrade` interactively to finish CR setup.

### Configuration Files

Two files in `~/.config/aiteamforge/` drive the per-team CR workflow:

#### `cr-config.json` — per-team opt-in record (mode 644, non-secret)

Records which teams have CR enabled. Lives in `~/.config/` so `aiteamforge upgrade`
never touches it.

```json
{
  "version": 1,
  "prompted": true,
  "teams": {
    "ios":     true,
    "android": false
  }
}
```

The `prompted` flag is set to `true` after the first time the wizard runs the CR
prompts. It suppresses re-nagging on subsequent `aiteamforge setup` runs. This file
is the **authority** for which teams get a CR poller LaunchAgent.

#### `confluence-credentials.json` — shared Atlassian credentials (mode 600, secret)

Written under `umask 077` so the file is never group- or world-readable, even
briefly. Contains one entry per opted-in team. Teams that are not CR-enabled are
never written here.

```json
{
  "teams": {
    "ios": {
      "site":      "mainevent.atlassian.net",
      "email":     "you@example.com",
      "api_token": "your-atlassian-api-token",
      "space_key": "DPD2"
    }
  },
  "default": "ios"
}
```

Both files are **merge-safe**: a partial re-run (e.g. adding a new team) never
drops flags or credentials for teams that were set up previously.

### LaunchAgent Behavior

After the wizard runs the installer reconciles LaunchAgents:

- **Opted-in teams with credentials** receive a per-team plist at
  `~/Library/LaunchAgents/com.aiteamforge.cr-confluence-poller.<team>.plist`.
- **Non-enabled teams** have their plists unloaded and removed automatically on
  every install or upgrade.

Each plist runs independently; a broken credential for one team does not affect
others.

### MIGRATION: Existing Installs

For installations predating this feature the installer performs a one-time migration
(`maybe_migrate_cr_config`) the next time `aiteamforge upgrade` runs:

| Situation | What happens |
|---|---|
| `confluence-credentials.json` already has teams | Those teams are inferred as CR-enabled; `cr-config.json` is written silently — no prompts |
| No credentials file, interactive TTY | Prompted per team; credentials captured if any team opts in |
| No credentials file, `--non-interactive` / CI / auto-upgrade | No-op — `cr-config.json` is left absent so a future interactive run can prompt. Never blocks an unattended upgrade |

To enable or change the CR workflow after initial setup, run `aiteamforge upgrade`
interactively. (Dedicated `aiteamforge cr-enable` / `cr-disable` CLI subcommands are
planned as future work.)

---

## Usage

### Basic Interactive Setup
```bash
# After installing via Homebrew
brew install aiteamforge

# Run the setup wizard
aiteamforge-setup
```

### Preview Without Changes
```bash
aiteamforge-setup --dry-run
```

### Automated Setup
```bash
# Create config file first
cat > ~/.aiteamforge/config.json <<EOF
{
  "machine": {
    "name": "macbook-pro-office",
    "user": "John Doe"
  },
  "teams": ["iOS", "Firebase"],
  "features": {
    "kanban": true,
    "fleet_monitor": false,
    "shell_env": true,
    "claude_config": true,
    "iterm_integration": false
  }
}
EOF

# Run in non-interactive mode
aiteamforge-setup --non-interactive
```

### Get Help
```bash
aiteamforge-setup --help
```

---

## Configuration File Format

The wizard generates `~/.aiteamforge/config.json`:

```json
{
  "version": "1.0.0",
  "machine": {
    "name": "macbook-pro-office",
    "hostname": "macbook-pro.local",
    "user": "John Doe"
  },
  "teams": ["iOS", "Firebase", "Academy"],
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

This config is used by:
- Installer modules (to know what to install)
- Fleet Monitor (for machine identification)
- Team startup scripts (to know which teams to activate)
- Non-interactive mode (to skip prompts)

---

## Architecture

### File Structure
```
homebrew-tap/
├── bin/
│   └── aiteamforge-setup           # Wrapper script (Homebrew adds to PATH)
├── libexec/
│   ├── aiteamforge-setup.sh        # Main wizard logic
│   ├── lib/
│   │   └── wizard-ui.sh         # UI helpers (colors, prompts, banners)
│   └── installers/              # Module installers (built by other phases)
│       ├── install-shell-env.sh
│       ├── install-claude.sh
│       ├── install-kanban.sh
│       ├── install-fleet.sh
│       └── install-teams.sh
└── docs/
    └── SETUP_WIZARD.md          # This file
```

### Installer Modules (To Be Built)

The wizard calls these installer modules (currently placeholders):

1. **`install-shell-env.sh`** (Phase 5)
   - Installs shell environment (prompts, aliases)
   - Configures zsh integration
   - Sets up kanban-helpers.sh, worktree-helpers.sh, etc.

2. **`install-claude.sh`** (Phase 6)
   - Installs Claude Code configuration
   - Sets up agent personas
   - Configures settings.json with hooks and MCP servers

3. **`install-kanban.sh`** (Phase 7)
   - Installs LCARS Kanban system
   - Sets up lcars-ui web server
   - Configures port assignments
   - Installs LaunchAgents (backup, health check)

4. **`install-fleet.sh`** (Phase 8)
   - Installs Fleet Monitor server/client
   - Configures multi-machine setup
   - Sets up Tailscale integration (if needed)

5. **`install-teams.sh`** (Phase 4)
   - Generates team-specific configs from templates
   - Creates team directories
   - Sets up startup/shutdown scripts
   - Configures team-specific zshrc files

Each module:
- Is sourced by the main wizard (not executed as subprocess)
- Has access to `$CONFIG_FILE` for reading selections
- Uses wizard-ui.sh functions for output
- Is idempotent (safe to run multiple times)
- Returns 0 on success, non-zero on failure
- Does NOT abort the wizard on failure (logs warning, continues)

---

## UI Library (wizard-ui.sh)

The wizard uses a shared UI library for consistent styling.

### Color Functions
```bash
print_color <color> <text>       # Print colored text
print_success <message>          # Green checkmark + message
print_error <message>            # Red X + message
print_warning <message>          # Amber warning + message
print_info <message>             # Blue info + message
```

### Headers
```bash
print_header <text>              # Major section header (amber, double border)
print_section <text>             # Minor section header (blue, single border)
```

### Progress
```bash
print_progress <current> <total> <label>    # Progress bar
run_with_spinner <command> <label>          # Spinner animation
```

### Interactive Prompts
```bash
prompt_yes_no <question> [default]          # Returns 0=yes, 1=no
prompt_text <question> [default]            # Returns user input
prompt_select <question> <opt1> <opt2>...   # Returns selected index
prompt_multi_select <question> <opt1>...    # Returns space-separated indices
```

### Status Display
```bash
print_status <label> <status>    # Status can be: ok, missing, installed, skipped, failed
```

### Utility
```bash
press_any_key [prompt]           # Wait for key press
clear_screen                     # Clear and show header
die <message> [exit_code]        # Print error and exit
```

---

## Error Handling

The wizard handles errors gracefully:

### Missing Required Dependencies
- Wizard aborts if missing: git, python3, node, jq, gh
- Shows install instructions for each missing tool
- User must install deps and re-run wizard

### Missing Optional Dependencies
- Warns if missing: claude, brew
- Shows install instructions
- Prompts to continue or abort
- Continues with warnings if user approves

### Installer Module Failures
- Logs warning if installer fails
- Continues to next installer (doesn't abort wizard)
- Shows failed status in summary
- User can re-run wizard to retry failed installers

### User Cancellation
- User can Ctrl-C at any time
- Wizard cleans up partial state
- Config file only written after all prompts complete

---

## Testing

### Manual Testing
```bash
# Test help
aiteamforge-setup --help

# Test dry run
aiteamforge-setup --dry-run

# Test non-interactive with defaults
aiteamforge-setup --non-interactive

# Test interactive (full wizard)
aiteamforge-setup
```

### Automated Testing
```bash
# TODO: Phase 11 (Testing & Documentation)
# - Create automated test suite
# - Test all prompts and selections
# - Test error handling
# - Test idempotency
```

---

## Integration with Homebrew

The wizard is designed to work with Homebrew Tap installation:

### Homebrew Formula (Phase 2)
```ruby
class Aiteamforge < Formula
  desc "AITeamForge"
  homepage "https://github.com/YOUR_ORG/aiteamforge"
  url "https://github.com/YOUR_ORG/aiteamforge/archive/v1.0.0.tar.gz"

  depends_on "python@3"
  depends_on "node"
  depends_on "jq"
  depends_on "gh"
  depends_on "git"

  def install
    libexec.install Dir["homebrew-tap/libexec/*"]
    bin.install "homebrew-tap/bin/aiteamforge-setup"
  end

  def caveats
    <<~EOS
      AITeamForge has been installed. Run the setup wizard:
        aiteamforge-setup
    EOS
  end
end
```

### Post-Install Flow
1. User runs: `brew install aiteamforge`
2. Homebrew installs dependencies (python, node, jq, gh)
3. Homebrew shows caveats message
4. User runs: `aiteamforge-setup`
5. Wizard completes setup
6. User restarts terminal
7. Dev-team environment is ready

---

## Future Enhancements

### Phase 3 (Current)
- [x] Basic wizard structure
- [x] LCARS-styled UI
- [x] All 7 stages implemented
- [x] Dry-run mode
- [x] Non-interactive mode
- [x] Config file generation
- [x] Placeholder installer modules

### Phase 4-8 (Upcoming)
- [ ] Implement installer modules:
  - [ ] Team configuration (Phase 4)
  - [ ] Shell environment (Phase 5)
  - [ ] Claude Code config (Phase 6)
  - [ ] LCARS Kanban (Phase 7)
  - [ ] Fleet Monitor (Phase 8)

### Phase 11 (Testing)
- [ ] Automated test suite
- [ ] Integration tests with Homebrew
- [ ] Error scenario testing

### Future Ideas
- [ ] Update mode: `aiteamforge-setup --update` (add new teams/features)
- [ ] Uninstall mode: `aiteamforge-setup --uninstall`
- [ ] Repair mode: `aiteamforge-setup --repair` (fix broken installations)
- [ ] Config validation: `aiteamforge-setup --validate`
- [ ] Migration tool for upgrading from old versions

---

## Troubleshooting

### Wizard Won't Start
```bash
# Check if wrapper is executable
ls -la $(which aiteamforge-setup)

# Check if libexec path is correct
aiteamforge-setup --help
```

### Missing Dependencies Error
```bash
# Check what's missing
which git python3 node jq gh

# Install missing deps
brew install python@3 node jq gh
```

### Config File Issues
```bash
# View current config
cat ~/.aiteamforge/config.json

# Validate JSON
jq . ~/.aiteamforge/config.json

# Reset config (deletes existing)
rm ~/.aiteamforge/config.json
aiteamforge-setup
```

### Installer Module Failures
```bash
# Re-run wizard to retry failed installers
aiteamforge-setup

# Check logs (when implemented)
cat ~/.aiteamforge/logs/install.log
```

---

## Developer Notes

### Adding New Teams
Edit `AVAILABLE_TEAMS` array in `aiteamforge-setup.sh`:
```bash
AVAILABLE_TEAMS=(
  "NewTeam|Description of new team"
)
```

### Adding New Features
1. Add boolean flag to globals section
2. Add prompt in `stage_feature_selection()`
3. Add to config JSON in `stage_generate_config()`
4. Add installer function and call in `stage_installation()`

### Customizing UI Colors
Edit color definitions in `wizard-ui.sh`:
```bash
readonly COLOR_AMBER='\033[38;5;214m'
```

### Testing Installer Modules
```bash
# Source the wizard environment
source homebrew-tap/libexec/lib/wizard-ui.sh

# Test individual installer
source homebrew-tap/libexec/installers/install-kanban.sh
install_lcars_kanban
```

---

**Last Updated:** 2026-02-17
**Maintained By:** Academy Team (Commander Jett Reno)
**Related:** XACA-0073 (Homebrew Tap Infrastructure)
