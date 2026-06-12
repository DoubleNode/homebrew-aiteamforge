#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# AITeamForge Fresh Install Verification Script
# ═══════════════════════════════════════════════════════════════════════════
# Run this AFTER 'brew install aiteamforge && aiteamforge setup' to verify
# everything installed correctly. Safe to run multiple times.
#
# Usage:
#   bash test-fresh-install.sh                       # Test default ~/aiteamforge (static only)
#   bash test-fresh-install.sh /path/to/dir          # Test custom install location
#   bash test-fresh-install.sh --runtime             # ALSO start a real LCARS server and
#                                                     # verify team-start / reachability / durability
#   bash test-fresh-install.sh /path/to/dir --runtime
#
# By default this script is read-only (no services started). The opt-in
# --runtime flag (XACA-0654) actually launches a real LCARS server, confirms it
# is reachable on /api/status, checks it is detached (survives shell logout),
# then stops it again if it started from a clean slate.
#
# Exit codes:
#   0 = All checks passed
#   1 = Some checks failed

set -o pipefail

# ─────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────
# Parse args: --runtime is a flag; the first positional is the install dir.
# (No `set -u` here, so the empty-array default expansion below is safe on
# macOS bash 3.2.)
RUNTIME=0
POSITIONAL=()
for _arg in "$@"; do
    case "$_arg" in
        --runtime) RUNTIME=1 ;;
        *)         POSITIONAL+=("$_arg") ;;
    esac
done
INSTALL_DIR="${POSITIONAL[0]:-$HOME/aiteamforge}"
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

        # Check team_paths field
        if jq -e '.team_paths' "$INSTALL_DIR/.aiteamforge-config" &>/dev/null; then
            pass "team_paths field present in config"
        else
            warn "team_paths field missing from config (run: aiteamforge setup --upgrade)"
        fi

        # Check installed_features field
        FEATURE_COUNT=$(jq '.installed_features | length // 0' "$INSTALL_DIR/.aiteamforge-config" 2>/dev/null || echo "0")
        if [ "$FEATURE_COUNT" -gt 0 ] 2>/dev/null; then
            FEATURES=$(jq -r '.installed_features[]' "$INSTALL_DIR/.aiteamforge-config" 2>/dev/null | tr '\n' ' ')
            pass "installed_features field present (${FEATURE_COUNT} feature(s): ${FEATURES})"
        else
            warn "installed_features field missing or empty (run: aiteamforge setup --upgrade)"
        fi

        # Check fleet_registration_status field
        FLEET_REG=$(jq -r '.fleet_registration_status // "missing"' "$INSTALL_DIR/.aiteamforge-config" 2>/dev/null)
        if [ "$FLEET_REG" != "missing" ]; then
            pass "fleet_registration_status: ${FLEET_REG}"
        else
            warn "fleet_registration_status field missing from config (run: aiteamforge setup --upgrade)"
        fi
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
# 8. Python Virtual Environment (tap-owned)
# ─────────────────────────────────────────────────────────────────────────
section "Python Virtual Environment"

# XACA-0654: the venv is TAP-OWNED. It is no longer the deprecated per-install
# $INSTALL_DIR/.venv — it lives under the Homebrew prefix and is resolved via
# $HOMEBREW_PREFIX/var/aiteamforge/env.sh (which exports AITEAMFORGE_PYTHON,
# pointing at $HOMEBREW_PREFIX/var/aiteamforge/venv/bin/python3). The old check
# read $INSTALL_DIR/.venv, which on a current install does not exist, so the
# test was BLIND to a missing iterm2 package in the venv that actually runs the
# iTerm2 window manager. Resolve the real venv the same way the runtime does.
ATF_VENV_PYTHON=""
for _atf_prefix in "${HOMEBREW_PREFIX:-}" "$(brew --prefix 2>/dev/null)" "/opt/homebrew" "/usr/local"; do
    [ -z "$_atf_prefix" ] && continue
    if [ -f "$_atf_prefix/var/aiteamforge/env.sh" ]; then
        # shellcheck source=/dev/null
        . "$_atf_prefix/var/aiteamforge/env.sh" 2>/dev/null
        break
    fi
done
# env.sh exports AITEAMFORGE_PYTHON; if it fell back to bare "python3" (or was
# absent), probe the canonical venv path directly so we never silently grade a
# system python3 as the tap venv.
if [ -z "${AITEAMFORGE_PYTHON:-}" ] || [ "${AITEAMFORGE_PYTHON}" = "python3" ]; then
    for _atf_prefix in "${HOMEBREW_PREFIX:-}" "$(brew --prefix 2>/dev/null)" "/opt/homebrew" "/usr/local"; do
        [ -z "$_atf_prefix" ] && continue
        if [ -x "$_atf_prefix/var/aiteamforge/venv/bin/python3" ]; then
            ATF_VENV_PYTHON="$_atf_prefix/var/aiteamforge/venv/bin/python3"
            break
        fi
    done
else
    ATF_VENV_PYTHON="$AITEAMFORGE_PYTHON"
fi
unset _atf_prefix

if [ -n "$ATF_VENV_PYTHON" ] && [ "$ATF_VENV_PYTHON" != "python3" ] && [ -x "$ATF_VENV_PYTHON" ]; then
    pass "tap-owned venv present ($ATF_VENV_PYTHON)"
    if "$ATF_VENV_PYTHON" -c "import iterm2" 2>/dev/null; then
        iterm2_ver=$("$ATF_VENV_PYTHON" -c "import iterm2; print(iterm2.__version__)" 2>/dev/null)
        pass "iterm2 package importable in tap venv (v$iterm2_ver)"
    else
        fail "iterm2 package NOT importable in tap-owned venv (iTerm2 window manager will fail — run: brew reinstall aiteamforge)"
    fi
else
    fail "tap-owned venv missing (expected \$HOMEBREW_PREFIX/var/aiteamforge/venv — run: brew reinstall aiteamforge)"
fi

# Surface — but do not depend on — a lingering deprecated venv.
if [ -e "$INSTALL_DIR/.venv" ]; then
    warn "deprecated $INSTALL_DIR/.venv still present (no longer used; safe to remove)"
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

if [ -f "$INSTALL_DIR/share/aliases/agent-aliases.sh" ]; then
    fn_count=$(grep -c "^claude-" "$INSTALL_DIR/share/aliases/agent-aliases.sh" 2>/dev/null || echo "0")
    pass "Agent aliases (agent-aliases.sh, $fn_count claude-* functions)"
else
    warn "share/aliases/agent-aliases.sh missing"
fi

if [ -f "$INSTALL_DIR/share/aliases/cc-aliases.sh" ]; then
    cc_count=$(grep -c "^cc-" "$INSTALL_DIR/share/aliases/cc-aliases.sh" 2>/dev/null || echo "0")
    pass "CC aliases (cc-aliases.sh, $cc_count cc-* functions)"
else
    warn "share/aliases/cc-aliases.sh missing"
fi

if [ -f "$INSTALL_DIR/share/aliases/worktree-aliases.sh" ]; then
    pass "Worktree aliases (worktree-aliases.sh)"
else
    warn "share/aliases/worktree-aliases.sh missing"
fi

if [ -f "$INSTALL_DIR/update_claude_agent.sh" ]; then
    pass "Agent switcher script (update_claude_agent.sh)"
else
    warn "update_claude_agent.sh missing"
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
# 14. AITeamForge Doctor (cross-check)
# ─────────────────────────────────────────────────────────────────────────
section "AITeamForge Doctor"

if command -v aiteamforge &>/dev/null; then
    doctor_output=$(aiteamforge doctor 2>&1)
    doctor_pass=$(echo "$doctor_output" | grep -oE 'Passed:\s+[0-9]+' | grep -oE '[0-9]+')
    doctor_fail=$(echo "$doctor_output" | grep -oE 'Failed:\s+[0-9]+' | grep -oE '[0-9]+')
    doctor_warn=$(echo "$doctor_output" | grep -oE 'Warnings:\s+[0-9]+' | grep -oE '[0-9]+')
    pass "aiteamforge doctor: ${doctor_pass:-0} pass, ${doctor_warn:-0} warn, ${doctor_fail:-0} fail"
else
    warn "aiteamforge command not available for doctor check"
fi

# ─────────────────────────────────────────────────────────────────────────
# 15. Runtime Smoke Test (opt-in: --runtime)  — XACA-0654
# ─────────────────────────────────────────────────────────────────────────
# The static checks above can all pass while the runtime is dead (e.g. a venv
# missing iterm2, or a server that starts but immediately dies / is not durable).
# When --runtime is passed, actually start a real LCARS server and assert:
#   (1) team-start        — `aiteamforge start lcars` exits 0
#   (2) reachability      — /api/status answers with a configured team
#   (3) durability        — the server.py process is detached (PPID 1) so it
#                           survives shell logout (nohup+disown launch contract)
# We only stop the server afterward if NOTHING was running before we started
# (least surprise: never kill a server the user already had up).
section "Runtime Smoke Test (--runtime)"

if [ "$RUNTIME" != "1" ]; then
    warn "Runtime checks skipped — pass --runtime to start a real server and verify start/reachability/durability"
elif ! command -v aiteamforge &>/dev/null; then
    fail "Runtime checks requested (--runtime) but 'aiteamforge' is not in PATH"
elif [ -z "$TEAMS" ]; then
    fail "Runtime checks requested (--runtime) but no teams are configured"
else
    rt_team=$(echo "$TEAMS" | head -1 | tr -d '[:space:]')

    # Snapshot LCARS ports already serving a team, so we (a) don't take credit for
    # a pre-existing server and (b) don't stop one the user already had running.
    rt_before_ports=""
    for p in $(seq 8080 8400); do
        if curl -s --max-time 1 "http://localhost:$p/api/status" 2>/dev/null | jq -e '.team' &>/dev/null; then
            rt_before_ports="$rt_before_ports $p"
        fi
    done

    # (1) Team-start
    if aiteamforge start lcars >/tmp/atf-runtime-start.log 2>&1; then
        pass "aiteamforge start lcars exited 0 (team: $rt_team)"
    else
        fail "aiteamforge start lcars failed (see /tmp/atf-runtime-start.log)"
    fi

    # (2) Reachability — poll up to ~20s for any LCARS server answering /api/status
    rt_port=""
    rt_seen_team=""
    for _try in $(seq 1 20); do
        for p in $(seq 8080 8400); do
            t=$(curl -s --max-time 1 "http://localhost:$p/api/status" 2>/dev/null | jq -r '.team // empty' 2>/dev/null)
            if [ -n "$t" ]; then rt_port="$p"; rt_seen_team="$t"; break; fi
        done
        [ -n "$rt_port" ] && break
        sleep 1
    done
    if [ -n "$rt_port" ]; then
        pass "LCARS server reachable on port $rt_port (/api/status team=$rt_seen_team)"
    else
        fail "No LCARS server reachable on /api/status within 20s of start"
    fi

    # (3) Durability — the launch contract (lcars-launch-helpers.sh) is nohup+disown,
    # so once the `aiteamforge start` child exits, server.py is reparented to init
    # (PPID 1) and survives shell logout. PPID != 1 means it would die on logout.
    if [ -n "$rt_port" ]; then
        rt_pid=$(pgrep -f "server.py $rt_port" | head -1)
        if [ -n "$rt_pid" ]; then
            rt_ppid=$(ps -o ppid= -p "$rt_pid" 2>/dev/null | tr -d ' ')
            if [ "$rt_ppid" = "1" ]; then
                pass "LCARS server (pid $rt_pid) detached from shell (PPID 1 — survives logout)"
            else
                fail "LCARS server (pid $rt_pid) NOT detached (PPID $rt_ppid — would die on shell logout / not durable)"
            fi
        else
            warn "Could not locate server.py PID for port $rt_port — skipping durability check"
        fi
    fi

    # Cleanup — only if we started from a clean slate (nothing was serving before).
    if [ -z "${rt_before_ports// /}" ] && [ -n "$rt_port" ]; then
        if aiteamforge stop lcars >/dev/null 2>&1; then
            warn "Stopped the LCARS server this test started (clean-slate cleanup)"
        fi
    elif [ -n "$rt_port" ]; then
        warn "Left LCARS running — a server was already up before this test (no cleanup)"
    fi
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
