# Quick Guide: Adding a New Team

**Time Required:** ~5 minutes
**Difficulty:** Easy

---

## Step 1: Create Team Configuration File

Create `share/teams/<team-id>.conf`:

```bash
# Team metadata
TEAM_ID="myteam"                       # REQUIRED: lowercase, no spaces
TEAM_NAME="My Team Name"               # REQUIRED: display name
TEAM_DESCRIPTION="Brief description"   # REQUIRED
TEAM_CATEGORY="platform"               # REQUIRED: platform|infrastructure|project|strategic|coordination
TEAM_COLOR="#00FF00"                   # HEX color for LCARS
TEAM_LCARS_PORT="8400"                # Unique port number (8000-9000 range)
TEAM_TMUX_SOCKET="myteam"             # Unique socket name

# Repositories this team works on
TEAM_REPOS=(
    "MyRepo1"
    "MyRepo2"
)

# Homebrew packages to install
TEAM_BREW_DEPS=(
    "package1"
    "package2"
)

# Homebrew casks to install (apps)
TEAM_BREW_CASK_DEPS=(
    "my-app"
)

# Agent personas for this team
TEAM_AGENTS=(
    "agent1"     # Brief role description
    "agent2"
)

# Script names (will be generated from templates)
TEAM_STARTUP_SCRIPT="myteam-startup.sh"    # REQUIRED
TEAM_SHUTDOWN_SCRIPT="myteam-shutdown.sh"  # REQUIRED

# Star Trek theme (optional, for fun)
TEAM_THEME="My Star Trek Series"
TEAM_SHIP="My Starship Name"
```

**Port Assignment Guidelines:**
- iOS: 8260+
- Android: 8280+
- Firebase: 8240+
- Academy: 8200+
- DNS: 8220+
- Freelance: 8300+
- Command: 8180+
- Legal: 8320+
- Medical: 8340+
- MainEvent: 8360+
- **Your team: Pick an unused range (e.g., 8400+)**

---

## Step 2: Add to Team Registry

Edit `share/teams/registry.json` and add your team to the `teams` array:

```json
{
  "id": "myteam",
  "name": "My Team Name",
  "category": "platform",
  "description": "Brief description",
  "color": "#00FF00",
  "theme": "My Star Trek Series",
  "icon": "🚀",
  "order": 11,
  "recommended": false
}
```

**Order Guidelines:**
- Lower numbers appear first in setup wizard
- Current teams use 1-10
- Start your team at 11+

---

## Step 3: Test Configuration

```bash
cd homebrew-tap
./libexec/installers/test-install-team.sh
```

**Expected Output:**
```
Testing team: myteam
  ✓ Configuration loaded successfully
  ✓ Validation passed
```

If you see errors, fix them before proceeding.

---

## Step 4: Install Team

```bash
./libexec/installers/install-team.sh myteam
```

**What Happens:**
1. ✅ Installs Homebrew dependencies
2. ✅ Creates `~/aiteamforge/myteam/` directory structure
3. ✅ Generates startup/shutdown scripts
4. ✅ Creates kanban board
5. ✅ Sets up LCARS port assignments
6. ✅ Adds agent aliases

---

## Step 5: Verify Installation

```bash
# Check team directory was created
ls -la ~/aiteamforge/myteam/

# Check startup script exists
ls -la ~/aiteamforge/myteam-startup.sh

# Check kanban board created
cat ~/aiteamforge/kanban/myteam-board.json

# Source aliases and try launching an agent
source ~/aiteamforge/claude_agent_aliases.sh
myteam-agent1
```

---

## Example: Adding a "QA Team"

### qa.conf

```bash
TEAM_ID="qa"
TEAM_NAME="Quality Assurance"
TEAM_DESCRIPTION="End-to-end testing and quality assurance"
TEAM_CATEGORY="platform"
TEAM_COLOR="#FF00FF"
TEAM_LCARS_PORT="8400"
TEAM_TMUX_SOCKET="qa"

TEAM_REPOS=(
    "MainEventApp-iOS"
    "MainEventApp-Android"
)

TEAM_BREW_DEPS=(
    "appium"
    "selenium"
)

TEAM_BREW_CASK_DEPS=(
    "android-studio"
)

TEAM_AGENTS=(
    "tester-alpha"
    "tester-beta"
    "automation-lead"
)

TEAM_STARTUP_SCRIPT="qa-startup.sh"
TEAM_SHUTDOWN_SCRIPT="qa-shutdown.sh"

TEAM_THEME="Star Trek: Lower Decks"
TEAM_SHIP="USS Cerritos"
```

### registry.json entry

```json
{
  "id": "qa",
  "name": "Quality Assurance",
  "category": "platform",
  "description": "End-to-end testing and quality assurance",
  "color": "#FF00FF",
  "theme": "Star Trek: Lower Decks",
  "icon": "🧪",
  "order": 11,
  "recommended": false
}
```

---

## Checklist

- [ ] Created `share/teams/<team-id>.conf` with all required variables
- [ ] Chose unique LCARS port number (no conflicts)
- [ ] Added team to `share/teams/registry.json`
- [ ] Ran `test-install-team.sh` (all tests passed)
- [ ] Ran `install-team.sh <team-id>` (installed successfully)
- [ ] Verified team directory created
- [ ] Verified startup/shutdown scripts exist
- [ ] Verified kanban board created
- [ ] Sourced aliases and tested agent launch

---

## Troubleshooting

**Port conflict:**
Check existing ports: `grep TEAM_LCARS_PORT share/teams/*.conf`

**JSON validation error:**
Validate JSON: `jq empty share/teams/registry.json`

**Missing homebrew package:**
Install manually: `brew install <package>`

**Agent alias not working:**
Source the file: `source ~/aiteamforge/claude_agent_aliases.sh`

---

## That's It

You've added a new team. No code changes required - just data configuration.

**Welcome to the fleet! 🚀**
