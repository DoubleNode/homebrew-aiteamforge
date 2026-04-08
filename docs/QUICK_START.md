# Quick Start Guide

**Get up and running with AITeamForge in 5 minutes**

---

## Prerequisites

Before installing AITeamForge, you'll need:

- **macOS** Big Sur (11.0) or later
- **Homebrew** package manager ([install here](https://brew.sh))
- **Terminal** access (Terminal.app or iTerm2)

---

## Installation

### Step 1: Install AITeamForge

```bash
brew tap DoubleNode/aiteamforge
brew install aiteamforge
```

This installs the AITeamForge framework and its dependencies (Python 3, Node.js, jq, GitHub CLI, Git).

### Step 2: Run Setup Wizard

```bash
aiteamforge setup
```

The setup wizard will guide you through:
- Checking dependencies (installs missing tools if needed)
- Selecting teams (iOS, Android, Firebase, etc.)
- Configuring features (LCARS Kanban, Fleet Monitor, etc.)
- Setting up your environment

**Typical setup takes 5-10 minutes.**

### Step 3: Verify Installation

```bash
aiteamforge doctor
```

This runs a comprehensive health check and reports any issues.

---

## What to Expect

### During Setup

The setup wizard will ask you to:

1. **Provide machine identity** - A name for this machine (e.g., "macbook-pro-office")
2. **Select teams** - Which development teams to install (start with the ones you need)
3. **Choose features**:
   - **LCARS Kanban** - Visual task management system (recommended: yes)
   - **Fleet Monitor** - Multi-machine coordination (recommended: no, unless you have multiple machines)
   - **Shell Environment** - Terminal shortcuts and helpers (recommended: yes)
   - **Claude Code Config** - AI agent configuration (recommended: yes)
   - **iTerm2 Integration** - Terminal automation (recommended: no, optional)

**Tip:** You can always re-run `aiteamforge setup` later to add more teams or features.

### After Setup

You'll have:
- A `~/aiteamforge/` directory with all configurations
- Shell aliases for common commands
- Team-specific directories and scripts
- LCARS Kanban system running (if selected)
- Claude Code agents configured (if selected)

---

## First Steps After Installation

### 1. Restart Your Terminal

```bash
# Close and reopen your terminal, or:
source ~/.zshrc
```

This loads the new shell environment.

### 2. Check Status

```bash
aiteamforge status
```

Shows what's installed and running.

### 3. Start a Team

```bash
# Start a specific team
aiteamforge start ios

# Or start all teams
aiteamforge start
```

This launches team-specific tools, terminals, and services.

### 4. Access LCARS Kanban

If you installed LCARS Kanban, open in your browser:

```
http://localhost:8082
```

You'll see the Star Trek-styled task management interface.

### 5. Use Shell Helpers

Try these commands:

```bash
# Kanban helpers
kb-list              # List kanban items
kb-add "Task name"   # Add new task
kb-status            # Show kanban status

# Worktree helpers
wt-list              # List git worktrees
wt-create            # Create new worktree

# Claude Code
cc                   # Launch Claude Code in current directory
```

---

## Common Use Cases

### For iOS Development

```bash
# Install iOS team
aiteamforge setup  # Select "iOS Development"

# Start iOS environment
aiteamforge start ios

# Use iOS-specific agents
ios-picard     # Captain Picard - Lead Feature Developer
ios-beverly    # Dr. Crusher - Bugfix Specialist
```

### For Multi-Platform Development

```bash
# Install multiple teams
aiteamforge setup  # Select "iOS", "Android", "Firebase"

# Start all teams
aiteamforge start

# Each team gets its own terminals, tools, and kanban board
```

### For Multi-Machine Setup

```bash
# On main machine (server)
aiteamforge setup  # Enable "Fleet Monitor" as server

# On secondary machines (clients)
aiteamforge setup  # Enable "Fleet Monitor" as client

# View fleet status
open http://localhost:3000  # Fleet Monitor dashboard
```

---

## Need Help?

### Run Diagnostics

```bash
aiteamforge doctor --verbose
```

Shows detailed information about your installation.

### Check Documentation

```bash
# View available docs
ls ~/aiteamforge/docs/

# Key documents
~/aiteamforge/docs/INSTALLATION.md      # Complete installation guide
~/aiteamforge/docs/USER_GUIDE.md        # Day-to-day usage
~/aiteamforge/docs/TROUBLESHOOTING.md   # Problem solving
```

### Common Issues

**LCARS server not starting?**
```bash
# Check port 8082
lsof -i :8082

# Restart LCARS
aiteamforge stop
aiteamforge start
```

**Claude Code not working?**
```bash
# Check authentication
claude auth login

# Verify installation
claude --version
```

**Commands not found?**
```bash
# Reload shell
source ~/.zshrc

# Verify installation
which aiteamforge
```

---

## What's Next?

- **Read the [User Guide](USER_GUIDE.md)** - Learn all aiteamforge commands and workflows
- **Explore [Architecture](ARCHITECTURE.md)** - Understand how aiteamforge works
- **Set up [Multi-Machine](MULTI_MACHINE.md)** - Connect multiple development machines
- **Check [Team Reference](TEAM_REFERENCE.md)** - Learn about available teams

---

## Uninstalling

If you need to remove aiteamforge:

```bash
# Remove configuration
aiteamforge uninstall

# Remove framework
brew uninstall aiteamforge
brew untap DoubleNode/aiteamforge
```

Your `~/aiteamforge/` directory will be preserved. Delete it manually if desired.

---

**Next Steps:** Once installation is complete, continue to the [User Guide](USER_GUIDE.md) for detailed usage instructions.
