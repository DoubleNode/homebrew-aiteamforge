# Troubleshooting Guide

**Problem solving guide for common AITeamForge issues**

---

## Table of Contents

- [Using aiteamforge doctor](#using-aiteamforge-doctor)
- [Installation Issues](#installation-issues)
- [Service Issues](#service-issues)
- [Shell Integration Issues](#shell-integration-issues)
- [Claude Code Issues](#claude-code-issues)
- [Kanban Issues](#kanban-issues)
- [Fleet Monitor Issues](#fleet-monitor-issues)
- [Migration Issues](#migration-issues)
- [Reporting Bugs](#reporting-bugs)

---

## Using aiteamforge doctor

The `aiteamforge doctor` command is your first tool for diagnosing issues.

### Basic Usage

```bash
# Standard health check
aiteamforge doctor

# Verbose diagnostics
aiteamforge doctor --verbose

# Check specific component
aiteamforge doctor --check dependencies
aiteamforge doctor --check services
aiteamforge doctor --check config
aiteamforge doctor --check permissions
```

### Interpreting Results

- **✓ (Green)** - Check passed, no action needed
- **⚠ (Yellow)** - Warning, non-critical issue
- **✗ (Red)** - Failed, requires attention

### Example Output

```
DEPENDENCIES
────────────────────────────────────────────────────────────────
  ✓ python3         3.11.6
  ✓ node            20.10.0
  ✓ jq              1.7.1
  ✓ gh              2.40.1
  ✓ git             2.43.0
  ✗ claude          not found

SERVICES
────────────────────────────────────────────────────────────────
  ✓ LCARS server running (port 8082)
  ✗ Fleet Monitor not running
```

---

## Installation Issues

### Issue: Homebrew Not Found

**Symptoms:**
```
brew: command not found
```

**Solution:**

1. **Install Homebrew:**
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

2. **Add to PATH:**
   ```bash
   # For Apple Silicon
   echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
   source ~/.zprofile

   # For Intel
   echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zprofile
   source ~/.zprofile
   ```

3. **Verify:**
   ```bash
   brew --version
   ```

### Issue: Python Version Too Old

**Symptoms:**
```
Python 3.8+ required, found 3.7.x
```

**Solution:**

```bash
# Update Python via Homebrew
brew upgrade python@3

# Verify version
python3 --version

# If still old, unlink and relink
brew unlink python@3
brew link python@3
```

### Issue: Permission Denied During Installation

**Symptoms:**
```
Error: Permission denied @ apply2files
```

**Solution:**

```bash
# Fix Homebrew permissions
sudo chown -R $(whoami) $(brew --prefix)/*

# Or fix specific directory
sudo chown -R $(whoami) /opt/homebrew/
```

### Issue: Setup Wizard Crashes

**Symptoms:**
- Wizard exits immediately
- Error: "AITEAMFORGE_HOME not set"

**Solution:**

1. **Verify aiteamforge is installed:**
   ```bash
   which aiteamforge
   ls -la $(brew --prefix)/opt/aiteamforge/
   ```

2. **Reinstall if needed:**
   ```bash
   brew reinstall aiteamforge
   ```

3. **Run with explicit path:**
   ```bash
   $(brew --prefix)/opt/aiteamforge/libexec/bin/aiteamforge-setup.sh
   ```

### Issue: Dependency Installation Fails

**Symptoms:**
```
Error: Failed to install <package>
```

**Solution:**

1. **Update Homebrew:**
   ```bash
   brew update
   ```

2. **Install dependencies manually:**
   ```bash
   brew install python@3 node jq gh git
   ```

3. **Check for conflicts:**
   ```bash
   brew doctor
   ```

4. **Retry setup:**
   ```bash
   aiteamforge setup
   ```

---

## Service Issues

### LCARS Server Won't Start

**Symptoms:**
- `curl http://localhost:8082/health` returns connection refused
- Error: "Port 8082 already in use"

**Diagnosis:**

```bash
# Check if port is in use
lsof -i :8082

# Check for python processes
ps aux | grep "server.py"
```

**Solutions:**

**If port is in use by another process:**
```bash
# Kill the process
kill -9 <PID>

# Or use different port
# Edit ~/aiteamforge/config.json
# Change lcars_port to 8083
# Restart LCARS
aiteamforge restart lcars
```

**If no process using port:**
```bash
# Start manually to see errors
cd ~/aiteamforge/lcars-ui
python3 server.py

# Check for missing dependencies
pip3 install -r requirements.txt  # if requirements.txt exists
```

**If python version mismatch:**
```bash
# Use system python3
which python3
/opt/homebrew/bin/python3 ~/aiteamforge/lcars-ui/server.py
```

### LCARS Server Running But Not Accessible

**Symptoms:**
- `lsof -i :8082` shows server running
- Browser shows "Connection refused" or "Can't connect"

**Diagnosis:**

```bash
# Check server binding
netstat -an | grep 8082

# Check server logs
tail -f ~/aiteamforge/logs/lcars.log
```

**Solutions:**

```bash
# Verify server is bound to correct interface
# Edit ~/aiteamforge/lcars-ui/server.py
# Change to: server_address = ('0.0.0.0', 8082)

# Restart LCARS
aiteamforge restart lcars

# Try localhost explicitly
curl http://127.0.0.1:8082/health
```

### Fleet Monitor Won't Start

**Symptoms:**
- Fleet Monitor fails to start
- Error: "EADDRINUSE: address already in use"

**Diagnosis:**

```bash
# Check if port 3000 is in use
lsof -i :3000

# Check Fleet Monitor logs
tail -f ~/aiteamforge/logs/fleet-monitor.log
```

**Solutions:**

**If port in use:**
```bash
# Kill the process
kill -9 <PID>

# Or change port in config
# Edit ~/aiteamforge/fleet-monitor/config.json
# Change "port" to 3001
```

**If Node.js errors:**
```bash
# Reinstall dependencies
cd ~/aiteamforge/fleet-monitor/server
rm -rf node_modules package-lock.json
npm install

# Start manually to see errors
node server.js
```

### LaunchAgents Not Running

**Symptoms:**
- Kanban backups not happening
- LCARS health checks not running

**Diagnosis:**

```bash
# List aiteamforge LaunchAgents
launchctl list | grep aiteamforge

# Check specific agent
launchctl list com.devteam.kanban-backup
```

**Solutions:**

```bash
# Load LaunchAgent
launchctl load ~/Library/LaunchAgents/com.devteam.kanban-backup.plist

# Unload and reload
launchctl unload ~/Library/LaunchAgents/com.devteam.kanban-backup.plist
launchctl load ~/Library/LaunchAgents/com.devteam.kanban-backup.plist

# Check logs
cat ~/aiteamforge/logs/kanban-backup.log

# Verify plist syntax
plutil -lint ~/Library/LaunchAgents/com.devteam.kanban-backup.plist
```

---

## Shell Integration Issues

### Aliases Not Loading

**Symptoms:**
- `kb-list`, `wt-list`, etc. commands not found
- Shell helpers not available

**Diagnosis:**

```bash
# Check if shell-env.sh exists
ls -la ~/aiteamforge/shell-env.sh

# Check if sourced in .zshrc
grep "aiteamforge" ~/.zshrc
```

**Solutions:**

```bash
# Manually source shell environment
source ~/aiteamforge/shell-env.sh

# Add to .zshrc if missing
echo 'source ~/aiteamforge/shell-env.sh' >> ~/.zshrc

# Reload shell
source ~/.zshrc

# Verify aliases loaded
alias | grep "^kb-"
```

### Prompt Not Showing

**Symptoms:**
- Terminal prompt doesn't show aiteamforge info
- Custom prompt disappeared

**Diagnosis:**

```bash
# Check prompt configuration
echo $PS1
echo $PROMPT

# Check if prompt script exists
ls -la ~/aiteamforge/scripts/prompt.sh
```

**Solutions:**

```bash
# Reload shell environment
source ~/.zshrc

# If prompt script missing, regenerate
aiteamforge setup --upgrade

# Manually set prompt
export PROMPT="%F{blue}[aiteamforge]%f %~ %# "
```

### PATH Issues

**Symptoms:**
- `aiteamforge` command not found after installation
- Other installed tools not found

**Diagnosis:**

```bash
# Check PATH
echo $PATH

# Find where aiteamforge is installed
brew --prefix aiteamforge
```

**Solutions:**

```bash
# Add Homebrew bin to PATH
export PATH="$(brew --prefix)/bin:$PATH"

# Make permanent
echo 'export PATH="$(brew --prefix)/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# Verify
which aiteamforge
```

---

## Claude Code Issues

### Claude Code Not Found

**Symptoms:**
```
claude: command not found
```

**Solution:**

```bash
# Install Claude Code
npm install -g @anthropic-ai/claude-code

# Verify installation
claude --version

# If still not found, check PATH
echo $PATH | grep npm

# Add npm global bin to PATH
export PATH="$HOME/.npm-global/bin:$PATH"
```

### Authentication Failed

**Symptoms:**
- Claude Code prompts for login on every use
- Error: "Authentication required"

**Solution:**

```bash
# Re-authenticate
claude auth logout
claude auth login

# Verify authentication
claude auth status

# If issues persist, clear cache
rm -rf ~/.claude/
claude auth login
```

### Agents Not Loading Persona

**Symptoms:**
- Agent doesn't follow team-specific guidelines
- Agent asks about context repeatedly

**Diagnosis:**

```bash
# Check agent configuration
ls -la ~/aiteamforge/claude/agents/

# Verify settings.json
cat ~/aiteamforge/claude/settings.json | jq .
```

**Solutions:**

```bash
# Regenerate agent configs
aiteamforge setup --upgrade

# Manually verify agent path
ios-picard --debug

# Check persona files exist
ls ~/aiteamforge/claude/agents/iOS\ Development/picard/
```

### Kanban Hooks Not Firing

**Symptoms:**
- Agent work not tracked in kanban
- Session start/stop not recorded

**Diagnosis:**

```bash
# Check hook files exist
ls -la ~/aiteamforge/kanban-hooks/

# Check settings.json for hook paths
cat ~/aiteamforge/claude/settings.json | jq .hooks

# Test hook manually
python3 ~/aiteamforge/kanban-hooks/kanban-session-start.py
```

**Solutions:**

```bash
# Fix hook permissions
chmod +x ~/aiteamforge/kanban-hooks/*.py

# Verify Python can execute hooks
python3 ~/aiteamforge/kanban-hooks/kanban-session-start.py --test

# Check hook logs
cat ~/aiteamforge/logs/start-hook-debug.log

# Regenerate settings.json
aiteamforge setup --upgrade
```

---

## Kanban Issues

### Kanban Board Not Loading

**Symptoms:**
- LCARS shows "Loading..." forever
- Browser console shows errors

**Diagnosis:**

```bash
# Check LCARS server
curl http://localhost:8082/api/boards

# Check board file exists
ls -la ~/aiteamforge/kanban/ios-board.json

# Validate JSON syntax
jq . ~/aiteamforge/kanban/ios-board.json
```

**Solutions:**

**If JSON syntax error:**
```bash
# Restore from backup
cp ~/aiteamforge/kanban-backups/ios-board-*.json \
   ~/aiteamforge/kanban/ios-board.json

# Or create new board
cat > ~/aiteamforge/kanban/ios-board.json <<'EOF'
{
  "version": "1.0.0",
  "team": "ios",
  "items": [],
  "columns": ["backlog", "in_progress", "in_review", "testing", "done"]
}
EOF
```

**If LCARS server error:**
```bash
# Restart LCARS
aiteamforge restart lcars

# Check logs
tail -f ~/aiteamforge/logs/lcars.log
```

### kb- Commands Not Working

**Symptoms:**
- `kb-list`, `kb-add` return errors
- Error: "Kanban board not found"

**Diagnosis:**

```bash
# Check if kanban-helpers.sh is loaded
type kb-list

# Check if board files exist
ls ~/aiteamforge/kanban/

# Test command manually
bash -c "source ~/aiteamforge/scripts/kanban-helpers.sh && kb-list"
```

**Solutions:**

```bash
# Reload shell environment
source ~/aiteamforge/scripts/kanban-helpers.sh

# Create missing board file
kb-init ios

# Fix permissions
chmod 644 ~/aiteamforge/kanban/*.json

# Regenerate helpers
aiteamforge setup --upgrade
```

### Backup System Not Running

**Symptoms:**
- No files in `~/aiteamforge/kanban-backups/`
- Backups older than today

**Diagnosis:**

```bash
# Check LaunchAgent status
launchctl list com.devteam.kanban-backup

# Check backup script
ls -la ~/aiteamforge/scripts/kanban-backup.py

# Test backup manually
python3 ~/aiteamforge/scripts/kanban-backup.py
```

**Solutions:**

```bash
# Load LaunchAgent
launchctl load ~/Library/LaunchAgents/com.devteam.kanban-backup.plist

# Check LaunchAgent plist
cat ~/Library/LaunchAgents/com.devteam.kanban-backup.plist

# Verify schedule
launchctl list com.devteam.kanban-backup | grep StartCalendarInterval

# Check logs
cat ~/aiteamforge/logs/kanban-backup.log
```

### Board Conflicts After Sync

**Symptoms:**
- Kanban items duplicated
- Changes on one machine don't appear on others
- Sync errors in logs

**Diagnosis:**

```bash
# Check sync status
kb-sync status

# View sync log
tail -f ~/aiteamforge/logs/kanban-sync.log

# Check Fleet Monitor connection
curl http://server:3000/api/machines
```

**Solutions:**

```bash
# Pull latest from server (overwrites local)
kb-sync pull --force

# Or push local to server (overwrites server)
kb-sync push --force

# Resolve conflicts manually
kb-sync conflicts
# Follow prompts to choose versions
```

---

## Fleet Monitor Issues

### Can't Connect to Server

**Symptoms:**
- Client shows "Connection refused"
- Dashboard not accessible

**Diagnosis:**

```bash
# Test connection from client
ping macbook-pro-office

# Test Fleet Monitor port
nc -zv macbook-pro-office 3000

# Check Tailscale status
tailscale status
```

**Solutions:**

See [Multi-Machine Setup - Troubleshooting Network Issues](MULTI_MACHINE.md#troubleshooting-network-issues) for detailed network troubleshooting.

Quick fixes:
```bash
# Verify server is running
# On server:
curl http://localhost:3000/api/health

# Verify firewall allows connections
# System Settings → Network → Firewall

# Use IP address instead of hostname
# Edit client config.json, use: "http://100.64.0.1:3000"
```

### Dashboard Shows Stale Data

**Symptoms:**
- Machine status not updating
- Last seen timestamp old

**Diagnosis:**

```bash
# Check client heartbeat
# On client:
tail -f ~/aiteamforge/logs/fleet-monitor-client.log

# Check server receives heartbeats
# On server:
tail -f ~/aiteamforge/logs/fleet-monitor.log | grep heartbeat
```

**Solutions:**

```bash
# Restart client
# On client:
aiteamforge restart fleet-monitor

# Force heartbeat
# On client:
curl -X POST http://server:3000/api/heartbeat \
  -H "Content-Type: application/json" \
  -d '{"machine":"macbook-air-home"}'
```

---

## Migration Issues

### Migrating from Manual Installation

**Symptoms:**
- Have existing `~/aiteamforge/` with custom configs
- Want to switch to Homebrew version

**Solution:**

```bash
# 1. Backup existing installation
mv ~/aiteamforge ~/aiteamforge-backup-$(date +%Y%m%d)

# 2. Install via Homebrew
brew tap DoubleNode/aiteamforge
brew install aiteamforge
aiteamforge setup

# 3. Migrate kanban boards
cp ~/aiteamforge-backup-*/kanban/*.json ~/aiteamforge/kanban/

# 4. Migrate customizations (review files first)
# Don't blindly copy - review and merge as needed
```

### Upgrade Broke My Installation

**Symptoms:**
- After `brew upgrade aiteamforge`, things stopped working
- Commands return errors

**Solution:**

```bash
# 1. Check what broke
aiteamforge doctor --verbose

# 2. Try repair
aiteamforge setup --upgrade

# 3. If still broken, rollback
brew switch aiteamforge <previous-version>

# 4. Restore from backup (if you made one)
cp ~/aiteamforge-backup.tar.gz ~
tar -xzf ~/aiteamforge-backup.tar.gz

# 5. Report bug (see Reporting Bugs section)
```

---

## Reporting Bugs

### Before Reporting

1. **Run diagnostics:**
   ```bash
   aiteamforge doctor --verbose > ~/diagnostic-report.txt
   ```

2. **Check logs:**
   ```bash
   ls ~/aiteamforge/logs/
   cat ~/aiteamforge/logs/*.log
   ```

3. **Try upgrading:**
   ```bash
   brew upgrade aiteamforge
   aiteamforge setup --upgrade
   ```

### What to Include

- **System info:**
  ```bash
  sw_vers
  uname -a
  brew --version
  ```

- **AITeamForge version:**
  ```bash
  aiteamforge --version
  brew info aiteamforge
  ```

- **Diagnostic report:**
  ```bash
  aiteamforge doctor --verbose
  ```

- **Relevant logs:**
  ```bash
  cat ~/aiteamforge/logs/lcars.log
  cat ~/aiteamforge/logs/fleet-monitor.log
  ```

- **Steps to reproduce**

- **Expected vs actual behavior**

### Where to Report

- **GitHub Issues:** https://github.com/DoubleNode/aiteamforge/issues
- **Include:** Diagnostic report, logs, steps to reproduce

---

## Emergency Recovery

### Nuclear Option: Complete Reinstall

If nothing else works:

```bash
# 1. Backup critical data
tar -czf ~/aiteamforge-backup.tar.gz \
  ~/aiteamforge/kanban/ \
  ~/aiteamforge/config.json

# 2. Completely remove aiteamforge
aiteamforge uninstall
brew uninstall aiteamforge
brew untap DoubleNode/aiteamforge
rm -rf ~/aiteamforge
rm -rf ~/.aiteamforge

# 3. Clean reinstall
brew tap DoubleNode/aiteamforge
brew install aiteamforge
aiteamforge setup

# 4. Restore data
tar -xzf ~/aiteamforge-backup.tar.gz -C ~/
```

---

## Getting More Help

### Built-in Help

```bash
aiteamforge help
aiteamforge doctor --help
aiteamforge setup --help
```

### Documentation

- [Quick Start](QUICK_START.md)
- [Installation Guide](INSTALLATION.md)
- [User Guide](USER_GUIDE.md)
- [Architecture](ARCHITECTURE.md)

### Community Support

- GitHub Discussions
- GitHub Issues (for bugs)

---

**Remember:** Most issues can be diagnosed with `aiteamforge doctor --verbose`. Start there!
