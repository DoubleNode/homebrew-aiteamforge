#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# Dev-Team Fresh Install Verification Script
# ═══════════════════════════════════════════════════════════════════════════
# Run this AFTER 'brew install aiteamforge && aiteamforge setup' to verify
# everything installed correctly. Safe to run multiple times.
#
# Usage:
#   bash test-fresh-install.sh              # Test default ~/aiteamforge
#   bash test-fresh-install.sh /path/to/dir # Test custom install location
#
# Exit codes:
#   0 = All checks passed
#   1 = Some checks failed

set -o pipefail

# ─────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────
INSTALL_DIR="${1:-$HOME/aiteamforge}"
PASS=0
FAIL=0
WARN=0
SECTION=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED}✗${NC} $1"; }
warn() { WARN=$((WARN + 1)); echo -e "  ${YELLOW}⚠${NC} $1"; }
section() { SECTION="$1"; echo ""; echo -e "${BLUE}${BOLD}── $1 ──${NC}"; }

# ─────────────────────────────────────────────────────────────────────────
# 1. Prerequisites
# ─────────────────────────────────────────────────────────────────────────
section "Prerequisites"

if command -v brew &>/dev/null; then
    pass "Homebrew $(brew --version 2>/dev/null | head -1 | cut -d' ' -f2)"
else
    fail "Homebrew not installed"
    echo -e "  ${RED}Cannot continue without Homebrew. Install from https://brew.sh${NC}"
    exit 1
fi

for dep in python3 node jq gh git; do
    if command -v "$dep" &>/dev/null; then
        ver=$("$dep" --version 2>/dev/null | head -1 | sed 's/.*version //' | sed 's/Python //')
        pass "$dep ($ver)"
    else
        fail "$dep not found"
    fi
done

if [ -d "/Applications/iTerm.app" ]; then
    pass "iTerm2 installed"
else
    warn "iTerm2 not installed (tab management won't work)"
fi

if command -v claude &>/dev/null; then
    pass "Claude Code $(claude --version 2>/dev/null | head -1)"
else
    warn "Claude Code not installed (agents won't work)"
fi

# ─────────────────────────────────────────────────────────────────────────
# 2. Homebrew Formula
# ─────────────────────────────────────────────────────────────────────────
section "Homebrew Formula"

if brew list aiteamforge &>/dev/null; then
    pass "aiteamforge formula installed"
else
    fail "aiteamforge formula not installed (run: brew install aiteamforge)"
fi

FRAMEWORK_DIR="$(brew --prefix 2>/dev/null)/opt/aiteamforge/libexec"
if [ -d "$FRAMEWORK_DIR" ]; then
    pass "Framework directory exists: $FRAMEWORK_DIR"
else
    fail "Framework directory missing: $FRAMEWORK_DIR"
fi

for cmd in aiteamforge aiteamforge-setup aiteamforge-doctor; do
    if command -v "$cmd" &>/dev/null; then
        pass "$cmd command in PATH"
    else
        fail "$cmd not in PATH"
    fi
done

# Verify CLI responds
if aiteamforge help &>/dev/null; then
    ver=$(aiteamforge version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    pass "CLI responds (v$ver)"
else
    fail "CLI not responding"
fi

# ─────────────────────────────────────────────────────────────────────────
# 3. Working Directory
# ─────────────────────────────────────────────────────────────────────────
section "Working Directory ($INSTALL_DIR)"

if [ -d "$INSTALL_DIR" ]; then
    pass "Install directory exists"
else
    fail "Install directory missing: $INSTALL_DIR"
    echo -e "  ${RED}Run 'aiteamforge setup' first, or specify path: $0 /your/path${NC}"
fi

if [ -f "$INSTALL_DIR/.aiteamforge-config" ]; then
    pass ".aiteamforge-config exists"
    if jq -e '.' "$INSTALL_DIR/.aiteamforge-config" &>/dev/null; then
        pass ".aiteamforge-config is valid JSON"
        TEAMS=$(jq -r '.teams[]' "$INSTALL_DIR/.aiteamforge-config" 2>/dev/null)
        TEAM_COUNT=$(echo "$TEAMS" | wc -l | tr -d ' ')
        pass "$TEAM_COUNT team(s) configured: $(echo $TEAMS | tr '\n' ' ')"
    else
        fail ".aiteamforge-config is invalid JSON"
    fi
else
    fail ".aiteamforge-config missing (run: aiteamforge setup)"
    TEAMS=""
fi

# ─────────────────────────────────────────────────────────────────────────
# 4. Team Directories
# ─────────────────────────────────────────────────────────────────────────
section "Team Directories"

if [ -n "$TEAMS" ]; then
    while IFS= read -r team; do
        [ -z "$team" ] && continue
        if [ -d "$INSTALL_DIR/$team" ]; then
            pass "$team/ directory"
        else
            fail "$team/ directory missing"
        fi
    done <<< "$TEAMS"
else
    warn "No teams configured — skipping directory checks"
fi

# ─────────────────────────────────────────────────────────────────────────
# 5. Startup & Shutdown Scripts
# ─────────────────────────────────────────────────────────────────────────
section "Startup & Shutdown Scripts"

if [ -n "$TEAMS" ]; then
    while IFS= read -r team; do
        [ -z "$team" ] && continue
        startup="$INSTALL_DIR/${team}-startup.sh"
        shutdown="$INSTALL_DIR/${team}-shutdown.sh"

        if [ -f "$startup" ] && [ -x "$startup" ]; then
            # Check if it's a real script (has TERMINALS=) or a stub
            if grep -q "TERMINALS=" "$startup" 2>/dev/null; then
                terms=$(grep "^TERMINALS=" "$startup" | sed 's/TERMINALS=(lcars //' | sed 's/)//' | wc -w | tr -d ' ')
                pass "$team-startup.sh (functional, $terms agents)"
            else
                warn "$team-startup.sh (stub — missing template during install)"
            fi
            # Syntax check
            bash -n "$startup" 2>/dev/null || fail "$team-startup.sh has syntax errors"
        else
            fail "$team-startup.sh missing or not executable"
        fi

        if [ -f "$shutdown" ] && [ -x "$shutdown" ]; then
            bash -n "$shutdown" 2>/dev/null && pass "$team-shutdown.sh" || fail "$team-shutdown.sh syntax error"
        else
            fail "$team-shutdown.sh missing or not executable"
        fi
    done <<< "$TEAMS"
else
    warn "No teams — skipping script checks"
fi

# ─────────────────────────────────────────────────────────────────────────
# 6. Kanban System
# ─────────────────────────────────────────────────────────────────────────
section "Kanban System"

if [ -f "$INSTALL_DIR/kanban-helpers.sh" ]; then
    pass "kanban-helpers.sh exists"
    bash -n "$INSTALL_DIR/kanban-helpers.sh" 2>/dev/null && pass "kanban-helpers.sh syntax valid" || fail "kanban-helpers.sh syntax error"
else
    warn "kanban-helpers.sh missing"
fi

if [ -d "$INSTALL_DIR/kanban" ]; then
    board_count=$(find "$INSTALL_DIR/kanban" -name "*-board.json" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$board_count" -gt 0 ]; then
        pass "$board_count kanban board(s) found"
        # Validate each board is valid JSON
        invalid=0
        find "$INSTALL_DIR/kanban" -name "*-board.json" -type f 2>/dev/null | while read -r board; do
            if ! jq -e '.' "$board" &>/dev/null; then
                fail "Invalid JSON: $(basename "$board")"
                invalid=$((invalid + 1))
            fi
        done
        [ "$invalid" -eq 0 ] && pass "All boards are valid JSON"
    else
        warn "No kanban boards found"
    fi
else
    warn "kanban/ directory missing"
fi

if [ -d "$INSTALL_DIR/kanban-hooks" ]; then
    hook_count=$(find "$INSTALL_DIR/kanban-hooks" -name "*.py" -type f 2>/dev/null | wc -l | tr -d ' ')
    pass "Kanban hooks installed ($hook_count files)"
else
    warn "kanban-hooks/ missing"
fi

# ─────────────────────────────────────────────────────────────────────────
# 7. LCARS UI
# ─────────────────────────────────────────────────────────────────────────
section "LCARS UI"

if [ -d "$INSTALL_DIR/lcars-ui" ]; then
    pass "lcars-ui/ directory"
    for f in server.py index.html redirect.html; do
        [ -f "$INSTALL_DIR/lcars-ui/$f" ] && pass "$f" || fail "$f missing"
    done

    # Test server can import without crashing (Python 3.14 calendar fix)
    cd "$INSTALL_DIR/lcars-ui" 2>/dev/null
    if python3 -c "
import sys, os
sys.path.insert(0, '.')
# Test the calendar module fix
from calendar import sync_service
" 2>/dev/null; then
        pass "LCARS server imports clean (Python $(python3 --version 2>&1 | cut -d' ' -f2))"
    else
        fail "LCARS server import error (Python compatibility issue)"
    fi
    cd - &>/dev/null
else
    fail "lcars-ui/ directory missing"
fi

# ─────────────────────────────────────────────────────────────────────────
# 8. Python Virtual Environment
# ─────────────────────────────────────────────────────────────────────────
section "Python Virtual Environment"

if [ -f "$INSTALL_DIR/.venv/bin/python3" ]; then
    pass ".venv exists"
    venv_python="$INSTALL_DIR/.venv/bin/python3"
    if "$venv_python" -c "import iterm2" 2>/dev/null; then
        iterm2_ver=$("$venv_python" -c "import iterm2; print(iterm2.__version__)" 2>/dev/null)
        pass "iterm2 package installed (v$iterm2_ver)"
    else
        fail "iterm2 package not importable in venv"
    fi
else
    fail ".venv missing (iTerm2 tab management won't work)"
fi

# ─────────────────────────────────────────────────────────────────────────
# 9. iTerm2 Window Manager
# ─────────────────────────────────────────────────────────────────────────
section "iTerm2 Window Manager"

if [ -f "$INSTALL_DIR/iterm2_window_manager.py" ]; then
    pass "iterm2_window_manager.py exists"
    if python3 "$INSTALL_DIR/iterm2_window_manager.py" --help &>/dev/null; then
        pass "Window manager runs (venv fallback works)"
    else
        fail "Window manager failed to run"
    fi
else
    warn "iterm2_window_manager.py missing"
fi

# Check iTerm2 Python API enabled
if [ -d "/Applications/iTerm.app" ]; then
    api_enabled=$(defaults read com.googlecode.iterm2 EnableAPIServer 2>/dev/null)
    if [ "$api_enabled" = "1" ]; then
        pass "iTerm2 Python API enabled"
    else
        fail "iTerm2 Python API not enabled"
        echo -e "    Fix: ${YELLOW}defaults write com.googlecode.iterm2 EnableAPIServer -bool true${NC}"
        echo -e "    Then restart iTerm2"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────
# 10. Shell Environment
# ─────────────────────────────────────────────────────────────────────────
section "Shell Environment"

if [ -f "$INSTALL_DIR/claude_agent_aliases.sh" ]; then
    alias_count=$(grep -c "^alias " "$INSTALL_DIR/claude_agent_aliases.sh" 2>/dev/null || echo "0")
    pass "Agent aliases file ($alias_count aliases)"
else
    warn "claude_agent_aliases.sh missing"
fi

# Check if zshrc has aiteamforge integration (only for default install location)
if [ "$INSTALL_DIR" = "$HOME/aiteamforge" ]; then
    if grep -q "aiteamforge initialize" "$HOME/.zshrc" 2>/dev/null; then
        pass ".zshrc has aiteamforge integration"
    else
        warn ".zshrc missing aiteamforge integration"
        echo -e "    You may need to add: ${YELLOW}source $INSTALL_DIR/share/aiteamforge-env.sh${NC}"
    fi
fi

if [ -f "$INSTALL_DIR/share/aiteamforge-env.sh" ]; then
    pass "Environment loader script"
else
    warn "share/aiteamforge-env.sh missing"
fi

# ─────────────────────────────────────────────────────────────────────────
# 11. Claude Code Configuration
# ─────────────────────────────────────────────────────────────────────────
section "Claude Code Configuration"

CLAUDE_DIR="$HOME/.claude"
if [ "$INSTALL_DIR" != "$HOME/aiteamforge" ]; then
    # Non-default install — check staging dir
    CLAUDE_DIR="$INSTALL_DIR/.claude-staging"
    echo -e "  ${BLUE}ℹ${NC} Non-default install — checking staging dir"
fi

if [ -d "$CLAUDE_DIR" ]; then
    pass "Claude config directory: $CLAUDE_DIR"
    [ -f "$CLAUDE_DIR/CLAUDE.md" ] && pass "CLAUDE.md" || warn "CLAUDE.md missing"
    [ -f "$CLAUDE_DIR/settings.json" ] && pass "settings.json" || warn "settings.json missing"
    [ -f "$CLAUDE_DIR/statusline-command.sh" ] && pass "statusline-command.sh" || warn "statusline-command.sh missing"
else
    warn "Claude config directory missing: $CLAUDE_DIR"
fi

# ─────────────────────────────────────────────────────────────────────────
# 12. Documentation
# ─────────────────────────────────────────────────────────────────────────
section "Documentation"

if [ -d "$INSTALL_DIR/docs" ]; then
    doc_count=$(find "$INSTALL_DIR/docs" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    pass "$doc_count documentation files"
else
    warn "docs/ directory missing"
fi

# ─────────────────────────────────────────────────────────────────────────
# 13. Running Services (informational)
# ─────────────────────────────────────────────────────────────────────────
section "Running Services (informational)"

lcars_running=0
for port in $(seq 8080 8400); do
    if curl -s "http://localhost:$port/api/status" 2>/dev/null | jq -e '.team' &>/dev/null; then
        team=$(curl -s "http://localhost:$port/api/status" 2>/dev/null | jq -r '.team')
        pass "LCARS server: $team on port $port"
        lcars_running=$((lcars_running + 1))
    fi
done
[ "$lcars_running" -eq 0 ] && warn "No LCARS servers running (start a team to launch one)"

# ─────────────────────────────────────────────────────────────────────────
# 14. Dev-Team Doctor (cross-check)
# ─────────────────────────────────────────────────────────────────────────
section "Dev-Team Doctor"

if command -v aiteamforge &>/dev/null; then
    doctor_output=$(aiteamforge doctor 2>&1)
    doctor_pass=$(echo "$doctor_output" | grep -oE 'Passed:\s+[0-9]+' | grep -oE '[0-9]+')
    doctor_fail=$(echo "$doctor_output" | grep -oE 'Failed:\s+[0-9]+' | grep -oE '[0-9]+')
    doctor_warn=$(echo "$doctor_output" | grep -oE 'Warnings:\s+[0-9]+' | grep -oE '[0-9]+')
    pass "aiteamforge doctor: ${doctor_pass:-0} pass, ${doctor_warn:-0} warn, ${doctor_fail:-0} fail"
else
    warn "aiteamforge command not available for doctor check"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Installation Verification Summary${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Install Dir:  $INSTALL_DIR"
echo -e "  ${GREEN}Passed:  $PASS${NC}"
echo -e "  ${YELLOW}Warnings: $WARN${NC}"
if [ "$FAIL" -gt 0 ]; then
    echo -e "  ${RED}Failed:  $FAIL${NC}"
else
    echo -e "  Failed:  0"
fi
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}  ✅ Installation looks good!${NC}"
    echo ""
    echo "  Next steps:"
    echo "    1. Start a team:  ./$INSTALL_DIR/<team>-startup.sh"
    echo "    2. Health check:  aiteamforge doctor"
    echo "    3. Show status:   aiteamforge status"
    echo ""
    exit 0
else
    echo -e "${RED}${BOLD}  ❌ $FAIL issue(s) need attention${NC}"
    echo ""
    echo "  Try running: aiteamforge doctor --fix"
    echo ""
    exit 1
fi
