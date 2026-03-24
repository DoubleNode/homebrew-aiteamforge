# Installation Guide

**Complete installation instructions for AITeamForge environment**

---

## Table of Contents

- [System Requirements](#system-requirements)
- [Prerequisites](#prerequisites)
- [Fresh Installation](#fresh-installation)
- [Migration from Manual Installation](#migration-from-manual-installation)
- [Verifying Installation](#verifying-installation)
- [Post-Installation Configuration](#post-installation-configuration)
- [Common Installation Issues](#common-installation-issues)
- [Uninstalling](#uninstalling)

---

## System Requirements

### Minimum Requirements

- **Operating System:** macOS Big Sur (11.0) or later
- **Architecture:** Intel (x86_64) or Apple Silicon (ARM64)
- **Disk Space:** 2 GB free space (5 GB+ recommended for full installation)
- **Memory:** 8 GB RAM minimum (16 GB+ recommended for running multiple teams)
- **Network:** Internet connection for downloading dependencies

### Recommended Setup

- **macOS:** Ventura (13.0) or later
- **Memory:** 16 GB+ RAM
- **Disk:** SSD with 10 GB+ free space
- **Terminal:** iTerm2 (for full features)
- **Network:** Fast internet connection (first-time setup downloads ~1 GB)

---

## Prerequisites

AITeamForge requires several tools to be installed. The setup wizard can install most of these automatically via Homebrew.

### Required Tools

| Tool | Purpose | Auto-Install | Version |
|------|---------|--------------|---------|
| **Homebrew** | Package manager | No (must install first) | Latest |
| **Python 3** | Scripting runtime | Yes | 3.8+ |
| **Node.js** | JavaScript runtime | Yes | 18.0+ |
| **jq** | JSON processor | Yes | Latest |
| **Git** | Version control | Yes | 2.0+ |
| **GitHub CLI (gh)** | GitHub operations | Yes | Latest |

### Optional Tools

| Tool | Purpose | Auto-Install | When Needed |
|------|---------|--------------|-------------|
| **iTerm2** | Terminal emulator | Yes | For full terminal automation |
| **Claude Code** | AI pair programmer | No (requires account) | For AI agent features |
| **Tailscale** | VPN networking | No (requires account) | For multi-machine setup |
| **ImageMagick** | Image processing | Yes | For avatar/image features |

### Installing Homebrew (Required First)

If you don't have Homebrew installed:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

After installation, follow the on-screen instructions to add Homebrew to your PATH.

**Verify Homebrew:**
```bash
brew --version
# Should output: Homebrew X.X.X
```

### Installing Claude Code (Optional but Recommended)

Claude Code requires an Anthropic account:

1. **Sign up** at [claude.ai](https://claude.ai)
2. **Install Claude Code:**
   ```bash
   npm install -g @anthropic-ai/claude-code
   ```
3. **Authenticate:**
   ```bash
   claude auth login
   ```

### Installing Tailscale (For Multi-Machine Only)

If you plan to use Fleet Monitor across multiple machines:

1. **Create account** at [tailscale.com](https://tailscale.com)
2. **Install Tailscale:**
   ```bash
   brew install --cask tailscale
   ```
3. **Sign in and enable Funnel** (in Tailscale admin console)

---

## Fresh Installation

### Step 1: Add Homebrew Tap

```bash
brew tap DoubleNode/aiteamforge
```

This adds the AITeamForge formula repository to Homebrew.

### Step 2: Install AITeamForge

```bash
brew install aiteamforge
```

**What this does:**
- Downloads the aiteamforge framework
- Installs required dependencies (Python, Node, jq, gh, Git)
- Places executables in `/opt/homebrew/bin/` (or `/usr/local/bin/` on Intel)
- Installs framework files to `/opt/homebrew/opt/aiteamforge/libexec/`

**Installation takes 2-5 minutes** depending on how many dependencies need installing.

### Step 3: Run Setup Wizard

```bash
aiteamforge setup
```

The interactive wizard will:

#### 3.1 Welcome & Prerequisites Check
- Displays LCARS-styled welcome banner
- Checks for required tools (Python, Node, jq, gh, Git)
- Checks for optional tools (iTerm2, Claude Code, Tailscale)
- Reports missing dependencies with install instructions
- Offers to install missing tools automatically

#### 3.2 Machine Identity
- Prompts for machine name (e.g., "macbook-pro-office", "mac-mini-home")
- Prompts for user display name (e.g., "John Doe")
- Used for Fleet Monitor identification and logging

#### 3.3 Team Selection
- Displays available teams grouped by category:
  - **Platform Development:** iOS, Android, Firebase
  - **Infrastructure:** Academy, DNS Framework
  - **Project-Based:** Freelance
  - **Coordination:** MainEvent
  - **Strategic:** Command, Legal, Medical
- Select teams using comma or space-separated list (e.g., "ios, firebase")
- Recommended teams are highlighted

**Tip:** Start with just the teams you need. You can add more later.

#### 3.4 Feature Selection
- **LCARS Kanban System** - Visual task management (recommended: yes)
- **Fleet Monitor** - Multi-machine coordination (recommended: no unless multi-machine)
- **Shell Environment** - Terminal shortcuts and helpers (recommended: yes)
- **Claude Code Configuration** - AI agent setup (recommended: yes if Claude installed)
- **iTerm2 Integration** - Terminal automation (recommended: no, optional)

#### 3.5 Configuration Generation
- Creates `~/.aiteamforge/config.json` with your selections
- Records machine identity, teams, features, paths, timestamp
- This config drives all subsequent installation steps

#### 3.6 Installation Orchestration
The wizard runs these installers in order:
1. **Team Setup** - Creates team directories, scripts, kanban boards
2. **Shell Environment** - Installs shell helpers and aliases
3. **Claude Code Config** - Sets up agent personas and configurations
4. **LCARS Kanban** - Installs kanban web UI and services
5. **Fleet Monitor** - Sets up multi-machine coordination (if selected)

**Each installer shows progress with LCARS-style status indicators.**

#### 3.7 Summary & Next Steps
- Shows what was installed successfully
- Reports any warnings or errors
- Displays manual steps (if any)
- Shows quick-start commands

### Step 4: Restart Terminal

```bash
# Close and reopen terminal, or:
source ~/.zshrc
```

This loads the new shell environment with aiteamforge aliases and helpers.

### Step 5: Verify Installation

```bash
aiteamforge doctor
```

Runs comprehensive health checks and reports issues.

---

## Migration from Manual Installation

If you have an existing manual aiteamforge installation in `~/aiteamforge/`:

### Option 1: Fresh Install (Recommended)

1. **Backup existing installation:**
   ```bash
   mv ~/aiteamforge ~/aiteamforge-backup-$(date +%Y%m%d)
   ```

2. **Install via Homebrew:**
   ```bash
   brew tap DoubleNode/aiteamforge
   brew install aiteamforge
   aiteamforge setup
   ```

3. **Migrate data:**
   ```bash
   # Copy kanban boards
   cp ~/aiteamforge-backup-*/kanban/*.json ~/aiteamforge/kanban/

   # Copy team-specific configs (if customized)
   # Review and merge manually
   ```

### Option 2: In-Place Upgrade (Advanced)

**Warning:** This approach is experimental and may require manual fixes.

1. **Install framework without setup:**
   ```bash
   brew tap DoubleNode/aiteamforge
   brew install aiteamforge
   ```

2. **Create compatibility marker:**
   ```bash
   echo '{"version":"1.0.0","migrated":true}' > ~/.aiteamforge/config.json
   ```

3. **Update scripts to use framework:**
   - Replace script paths with `$(brew --prefix)/opt/aiteamforge/libexec/`
   - Update sourced files in `.zshrc`

4. **Verify:**
   ```bash
   aiteamforge doctor
   ```

**Recommendation:** Use Option 1 (fresh install) unless you have extensive customizations.

---

## Verifying Installation

### Quick Verification

```bash
# Check version
aiteamforge --version

# Run health check
aiteamforge doctor
```

### Comprehensive Verification

```bash
# Verbose diagnostics
aiteamforge doctor --verbose
```

**Checks performed:**
- ✓ External dependencies (Python, Node, jq, gh, Git)
- ✓ Framework installation (core scripts, directories)
- ✓ Configuration files (working directory, config.json)
- ✓ Services (LCARS server, Fleet Monitor)
- ✓ File permissions (write access, execute permissions)

### Expected Output

```
AITeamForge Health Check v1.0.0
════════════════════════════════════════════════════════════════

DEPENDENCIES
────────────────────────────────────────────────────────────────
  ✓ python3         3.11.6
  ✓ node            20.10.0
  ✓ jq              1.7.1
  ✓ gh              2.40.1
  ✓ git             2.43.0
  ✓ brew            4.2.0
  ⚠ claude          not found (optional)
  ⚠ tailscale       not found (optional)

FRAMEWORK
────────────────────────────────────────────────────────────────
  ✓ Framework installed at /opt/homebrew/opt/aiteamforge/libexec
  ✓ Core scripts present (7/7)
  ✓ Core directories present (5/5)

CONFIGURATION
────────────────────────────────────────────────────────────────
  ✓ Working directory exists (~/aiteamforge)
  ✓ Configuration file exists
  ✓ Templates copied

SERVICES
────────────────────────────────────────────────────────────────
  ✓ LCARS server running (port 8082)
  - Fleet Monitor not configured

PERMISSIONS
────────────────────────────────────────────────────────────────
  ✓ Write access to ~/aiteamforge
  ✓ Execute permissions on core scripts

════════════════════════════════════════════════════════════════
RESULT: All critical checks passed
```

### Verifying Specific Components

```bash
# Check dependencies only
aiteamforge doctor --check dependencies

# Check services only
aiteamforge doctor --check services

# Check configuration only
aiteamforge doctor --check config
```

---

## Post-Installation Configuration

### Shell Integration

The setup wizard adds this to your `~/.zshrc`:

```bash
# AITeamForge Environment
if [ -f "$HOME/aiteamforge/shell-env.sh" ]; then
    source "$HOME/aiteamforge/shell-env.sh"
fi
```

**Manual verification:**
```bash
grep -A 2 "AITeamForge" ~/.zshrc
```

### LCARS Kanban Service

If you installed LCARS Kanban, verify it's running:

```bash
# Check LCARS server
curl -s http://localhost:8082/health | jq .

# Should return: {"status":"ok","version":"1.0.0"}
```

**Access in browser:**
```
http://localhost:8082
```

### Claude Code Configuration

If you installed Claude Code integration, verify agent configs:

```bash
# List configured agents
ls ~/aiteamforge/claude/agents/

# Check Claude Code settings
cat ~/aiteamforge/claude/settings.json
```

### Fleet Monitor (Multi-Machine Only)

If you installed Fleet Monitor:

```bash
# Check Fleet Monitor server
curl -s http://localhost:3000/api/health

# Access dashboard
open http://localhost:3000
```

---

## Common Installation Issues

### Issue: Homebrew Not Found

**Error:** `brew: command not found`

**Solution:**
```bash
# Install Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Add to PATH (follow Homebrew's instructions)
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
source ~/.zprofile
```

### Issue: Permission Denied

**Error:** `Permission denied` during installation

**Solution:**
```bash
# Fix Homebrew permissions
sudo chown -R $(whoami) $(brew --prefix)/*

# Or reinstall Homebrew as your user
```

### Issue: Python Version Too Old

**Error:** `Python 3.8+ required, found 3.7`

**Solution:**
```bash
# Update Python via Homebrew
brew upgrade python@3

# Verify version
python3 --version
```

### Issue: Port 8082 Already in Use

**Error:** `LCARS server failed to start - port 8082 in use`

**Solution:**
```bash
# Find what's using the port
lsof -i :8082

# Kill the process or use different port
# Edit ~/aiteamforge/config.json and change lcars_port
```

### Issue: Claude Code Authentication Failed

**Error:** `Claude Code authentication failed`

**Solution:**
```bash
# Re-authenticate
claude auth logout
claude auth login

# Verify
claude auth status
```

### Issue: Setup Wizard Won't Start

**Error:** Setup wizard fails immediately

**Solution:**
```bash
# Check if aiteamforge is properly installed
which aiteamforge
ls -la $(brew --prefix)/opt/aiteamforge/

# Reinstall if needed
brew reinstall aiteamforge
```

### Issue: Missing Dependencies

**Error:** `Required dependency not found: <tool>`

**Solution:**
```bash
# Install missing tools manually
brew install python@3 node jq gh git

# Re-run setup
aiteamforge setup
```

---

## Uninstalling

### Full Uninstall

To completely remove aiteamforge:

```bash
# 1. Remove configuration and services
aiteamforge uninstall

# 2. Remove framework
brew uninstall aiteamforge

# 3. Remove tap
brew untap DoubleNode/aiteamforge

# 4. (Optional) Delete working directory
rm -rf ~/aiteamforge

# 5. (Optional) Remove shell integration
# Edit ~/.zshrc and remove AITeamForge section
```

### Partial Uninstall

To remove only specific teams or features:

```bash
# Re-run setup and deselect features
aiteamforge setup

# Or manually remove team directories
rm -rf ~/aiteamforge/<team-name>
```

### Preserving Data

If you want to uninstall but keep your data:

```bash
# Backup first
tar -czf ~/aiteamforge-backup.tar.gz ~/aiteamforge/

# Uninstall framework only (keeps ~/aiteamforge/)
brew uninstall aiteamforge
```

---

## Advanced Installation Options

### Custom Installation Directory

```bash
# Install to custom location
aiteamforge setup --install-dir /opt/aiteamforge
```

### Non-Interactive Installation

```bash
# Create config file first
cat > ~/.aiteamforge/config.json <<EOF
{
  "machine": {"name": "server-01", "user": "Deploy Bot"},
  "teams": ["ios", "firebase"],
  "features": {
    "kanban": true,
    "fleet_monitor": false,
    "shell_env": true,
    "claude_config": false,
    "iterm_integration": false
  }
}
EOF

# Run non-interactive setup
aiteamforge setup --non-interactive
```

### Dry Run (Preview Changes)

```bash
# Preview what will be installed without making changes
aiteamforge setup --dry-run
```

---

## Next Steps

After successful installation:

1. **Read the [User Guide](USER_GUIDE.md)** - Learn day-to-day usage
2. **Explore [Quick Start](QUICK_START.md)** - Get up to speed quickly
3. **Check [Team Reference](TEAM_REFERENCE.md)** - Learn about available teams
4. **Set up [Multi-Machine](MULTI_MACHINE.md)** - If using multiple machines

---

**Installation Support:** Run `aiteamforge doctor --verbose` for detailed diagnostics, or check [Troubleshooting](TROUBLESHOOTING.md) for common issues.
