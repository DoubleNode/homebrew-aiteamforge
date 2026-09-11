#!/bin/bash
# AITeamForge Setup Wizard
# Interactive configuration and installation

set -eo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Get framework location. In production, Homebrew's dispatch shim exports
# AITEAMFORGE_HOME. In source/dev mode, derive it from this script's location —
# the tap root is always one level above bin/, so the same ${AITEAMFORGE_HOME}/libexec/*
# references work in both environments (brew layout: libexec/libexec/..., source
# layout: tap/libexec/...).
if [ -z "$AITEAMFORGE_HOME" ]; then
  _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _candidate="$(cd "$_self_dir/.." && pwd)"
  if [ -f "$_candidate/libexec/lib/common.sh" ]; then
    AITEAMFORGE_HOME="$_candidate"
  elif command -v brew &>/dev/null; then
    AITEAMFORGE_HOME="$(brew --prefix)/opt/aiteamforge/libexec"
  else
    echo -e "${RED}ERROR: AITEAMFORGE_HOME not set and framework not locatable${NC}" >&2
    exit 1
  fi
fi

# Resolve tap-owned Python venv interpreter ($AITEAMFORGE_PYTHON).
# AITEAMFORGE_HOME is set above; python-env.sh lives in its libexec/lib/ subdir.
# shellcheck source=/dev/null
[ -f "$AITEAMFORGE_HOME/libexec/lib/python-env.sh" ] && . "$AITEAMFORGE_HOME/libexec/lib/python-env.sh"

# XACA-0683: source common.sh early so _aitf_launchctl (and the shared output
# helpers) are defined for ALL code paths — notably the inline `uninstall` block
# below, which runs and `exit 0`s before the later common.sh source. common.sh
# has its own double-source guard, so the later sources become cheap no-ops.
# shellcheck source=/dev/null
[ -f "$AITEAMFORGE_HOME/libexec/lib/common.sh" ] && . "$AITEAMFORGE_HOME/libexec/lib/common.sh"

# XACA-1070-002: source the mandatory-teams lib so the team-selection step can
# suppress mandatory teams from the presented checklist and so they can be
# force-appended into SELECTED_TEAMS later. Sourced early (same spot as
# common.sh) so it's available to both the Step 2 selection block and the
# later kanban-install block without re-sourcing. Degrades silently when
# absent (dev checkout mid-merge, older tap layout) — every call site below
# guards with `command -v atf_...` first, so a missing lib just means "no
# mandatory-team enforcement this run," never a hard failure.
# shellcheck source=/dev/null
[ -f "$AITEAMFORGE_HOME/libexec/lib/mandatory-teams.sh" ] && . "$AITEAMFORGE_HOME/libexec/lib/mandatory-teams.sh"

# ═══════════════════════════════════════════════════════════════════════════
# XACA-1070-002 / PR #865 review, BLOCKING 1: force-append mandatory teams
# into SELECTED_TEAMS.
#
# Defined as a function (not an inline block) because it has to run from
# TWO call sites, not one — see each call site's own comment for exactly
# why. Originally this was a single inline block placed unconditionally
# right before the kanban-install block (~line 1657 pre-fix), AFTER every
# loop in this script that consumes SELECTED_TEAMS had already iterated it
# (the per-team working-dir prompt at ~874, the persona/avatar copy at
# ~1346, and — the one that actually matters — the install-team.sh loop at
# ~1381). On a fresh interactive wizard install that meant a mandatory team
# reached `.aiteamforge-config` and got a kanban board (install-kanban.sh
# force-appends it independently on its own internal team list — see that
# file's install_kanban_system()), but install-team.sh NEVER ran for it:
# no port allocation, no team-paths.json entry, no connect/disconnect
# scripts, no per-agent startup scripts, no personas. PR #865 review,
# BLOCKING 1.
#
# Call site 1 (inside the interactive "Step 2" else-branch, immediately
# after SELECTED_TEAMS is finalized from user/non-interactive input and
# BEFORE the per-team working-dir loop — the FIRST loop in the file that
# consumes SELECTED_TEAMS) is the fix for that bug: it guarantees a
# mandatory team is present before ANY downstream consumer, including the
# working-dir loop, the persona copy, and the install-team.sh loop.
#
# Call site 2 (immediately after the Step 2 if/elif/else closes) exists
# because call site 1 is textually INSIDE the interactive branch only.
# UPGRADE_HYDRATED and cockpit populate SELECTED_TEAMS through their own
# branches of that same if/elif/else and never reach call site 1 at all —
# call site 2 is their safety net, matching what the original single
# (too-late) call site used to guarantee for them. It is a no-op on the
# interactive path: the dedup check below skips an id already present, so
# calling this function twice is always safe and never double-announces.
#
# Team-agnostic by design (XACA-1070): no team id is hard-coded anywhere in
# this function. Zero teams carry "mandatory": true as of this writing, so
# the loop below is a correctly-behaving no-op today — see
# libexec/lib/mandatory-teams.sh's own header comment for why that empty
# case matters.
#
# `set -eo pipefail` guard: `_mand_out="$(atf_mandatory_teams)"` alone would
# propagate atf_mandatory_teams' exit code to the assignment and abort the
# whole wizard — under errexit, `var=$(cmd)` fails the script the instant
# cmd returns non-zero, and unlike an `if`/`&&` condition this assignment is
# NOT exempt. `|| _mand_rc=$?` sidesteps that the same way the neighbouring
# jq/python calls in mandatory-teams.sh do: the trailing assignment is
# itself always "successful", so the list's overall exit status is 0 and
# errexit never fires, while `_mand_rc` still captures the real code so the
# empty-vs-unreadable distinction from the return-code contract isn't lost.
# ═══════════════════════════════════════════════════════════════════════════
_atf_apply_mandatory_teams() {
  if command -v atf_mandatory_teams >/dev/null 2>&1; then
    _mand_out="" ; _mand_rc=0
    # XACA-1070 (PR #865 review, subitem -015): capture STDOUT ONLY. Merging
    # stderr in here contaminated the very list this parses: the lib writes a
    # non-fatal diagnostic to stderr when it skips a malformed entry, and with
    # 2>&1 that sentence was read back as a team id and force-appended to
    # SELECTED_TEAMS, then handed to install-team.sh and written into
    # .aiteamforge-config. The diagnostic still reaches the user: it goes to
    # the real stderr. This matches update_mandatory_teams() in
    # libexec/commands/aiteamforge-upgrade.sh, which never merged it.
    _mand_out="$(atf_mandatory_teams)" || _mand_rc=$?
    if [ "$_mand_rc" -eq 0 ]; then
      while IFS= read -r _mand_id; do
        [ -n "$_mand_id" ] || continue
        _mand_already=0
        for _mand_existing in "${SELECTED_TEAMS[@]}"; do
          if [ "$_mand_existing" = "$_mand_id" ]; then
            _mand_already=1
            break
          fi
        done
        if [ "$_mand_already" -eq 0 ]; then
          SELECTED_TEAMS+=("$_mand_id")
          echo -e "${GREEN}✓${NC} Mandatory team added: ${_mand_id} (XACA-1070)"
        fi
      done <<EOF
$_mand_out
EOF
    else
      # Fail-closed on the ENFORCEMENT question, not on the install itself: an
      # unreadable registry.json must be surfaced (per mandatory-teams.sh's
      # return-code contract — this is the exit-1 fault case, never "no
      # mandatory teams"), but aborting the whole setup wizard over it would
      # be a worse outcome than continuing without mandatory-team enforcement
      # for this one run.
      echo -e "${YELLOW}⚠ Could not determine mandatory teams (registry.json missing/unparseable; see the stderr diagnostic above) — continuing without mandatory-team enforcement (XACA-1070)${NC}" >&2
    fi
  else
    # XACA-1070-020: the outer `command -v atf_mandatory_teams` guard used to
    # skip this whole function with ZERO console output when
    # mandatory-teams.sh itself is missing entirely (as opposed to present-
    # but-registry-unreadable, which the branch above already surfaces).
    # aiteamforge-upgrade.sh's update_mandatory_teams() has always printed a
    # warning for this exact condition ("mandatory-teams.sh not available —
    # skipping mandatory-team backfill (XACA-1070)"); this wizard silently
    # disabling the same enforcement with no indication at all is the
    # precise "silently does nothing" failure mode this ticket exists to
    # close one level up from the runtime feature itself. Non-fatal —
    # informational only; the wizard must still complete the install.
    echo -e "${YELLOW}⚠ mandatory-teams.sh not available — skipping mandatory-team enforcement (XACA-1070)${NC}" >&2
  fi
}

# Version — read from VERSION file (single source of truth)
_find_version() { for p in "$AITEAMFORGE_HOME/../VERSION" "$AITEAMFORGE_HOME/VERSION"; do [ -f "$p" ] && cat "$p" | tr -d '[:space:]' && return; done; echo "unknown"; }
VERSION="$(_find_version)"

# Banner
show_banner() {
  cat <<EOF
╔══════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║     █████╗ ██╗████████╗███████╗ █████╗ ███╗   ███╗                   ║
║    ██╔══██╗██║╚══██╔══╝██╔════╝██╔══██╗████╗ ████║                   ║
║    ███████║██║   ██║   █████╗  ███████║██╔████╔██║                   ║
║    ██╔══██║██║   ██║   ██╔══╝  ██╔══██║██║╚██╔╝██║                   ║
║    ██║  ██║██║   ██║   ███████╗██║  ██║██║ ╚═╝ ██║                   ║
║    ╚═╝  ╚═╝╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝                   ║
║                                                                      ║
║    ███████╗ ██████╗ ██████╗  ██████╗ ███████╗                        ║
║    ██╔════╝██╔═══██╗██╔══██╗██╔════╝ ██╔════╝                        ║
║    █████╗  ██║   ██║██████╔╝██║  ███╗█████╗                          ║
║    ██╔══╝  ██║   ██║██╔══██╗██║   ██║██╔══╝                          ║
║    ██║     ╚██████╔╝██║  ██║╚██████╔╝███████╗                        ║
║    ╚═╝      ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝                        ║
║                                                                      ║
║          AI-Powered Team Development Infrastructure                  ║
║                        Version ${VERSION}                                 ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
  echo ""
}

# Usage
usage() {
  cat <<EOF
AITeamForge Setup Wizard v${VERSION}

Usage: aiteamforge setup [options]

Options:
  --install-dir DIR      Installation directory (default: ~/aiteamforge)
  --upgrade              Upgrade existing installation
  --uninstall            Remove aiteamforge configuration
  --non-interactive      Run in non-interactive mode
  --dry-run              Preview what would be installed without making changes
  --refresh-profiles     Refresh AITeamForge-managed keys in the iTerm2 dynamic
                         profile while preserving your custom colors, fonts, and
                         window layout. Use after upgrades that include profile
                         changes (e.g., Mouse Reporting or Parent Name fixes).
  --cockpit-only         Install only the components needed to connect to remote
  --connect-only         AITeamForge hosts over Tailscale (alias for --cockpit-only).
                         Installs all <team>-connect.sh scripts, the Python venv,
                         iTerm2 window manager, and dynamic profile. Skips team
                         working directories, kanban boards, LCARS server, personas,
                         shell aliases, and other local-only infrastructure. Ideal
                         for laptops or secondary machines that drive remote teams
                         without hosting any team state locally.
  -h, --help             Show this help

Install Profiles:
  full (default)   Full installation: teams, kanban, LCARS, aliases, personas
  cockpit          Connect-only: remote connect scripts + iTerm2 glue, nothing local

Interactive Mode:
  When run without options, launches interactive setup wizard
  to configure your aiteamforge environment.

Examples:
  aiteamforge setup                          # Interactive setup
  aiteamforge setup --install-dir ~/my-team  # Custom location
  aiteamforge setup --upgrade                # Upgrade existing
  aiteamforge setup --uninstall              # Clean removal
  aiteamforge setup --dry-run                # Preview without changes
  aiteamforge setup --refresh-profiles       # Re-apply profile fixes while keeping your customizations
  aiteamforge setup --cockpit-only           # Cockpit install (connect to remote teams only)
EOF
}

# Save original args for re-exec after dependency install
ORIGINAL_ARGS=("$@")

# Parse arguments
# Honor AITEAMFORGE_DIR env override (used by tests + alt-install workflows);
# --install-dir CLI flag wins if both are provided (handled in arg loop below).
INSTALL_DIR="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
MODE="interactive"
IS_UPGRADE="false"
DRY_RUN="false"
REFRESH_PROFILES="false"
INSTALL_PROFILE="full"

while [[ $# -gt 0 ]]; do
  case $1 in
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --upgrade)
      IS_UPGRADE="true"
      shift
      ;;
    --uninstall)
      MODE="uninstall"
      shift
      ;;
    --non-interactive)
      MODE="non-interactive"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --refresh-profiles)
      REFRESH_PROFILES="true"
      shift
      ;;
    --cockpit-only|--connect-only)
      INSTALL_PROFILE="cockpit"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}ERROR: Unknown option: $1${NC}" >&2
      usage >&2
      exit 1
      ;;
  esac
done

export DRY_RUN
export INSTALL_PROFILE
if [ "$DRY_RUN" = "true" ]; then
  echo -e "${YELLOW}DRY RUN MODE: No changes will be made${NC}"
  echo ""
fi
if [ "$INSTALL_PROFILE" = "cockpit" ]; then
  echo -e "${CYAN}COCKPIT MODE: Installing connect scripts + iTerm2 glue only${NC}"
  echo -e "${CYAN}  Skipping: teams, kanban, LCARS server, personas, shell aliases${NC}"
  echo ""
fi

# Check if already configured
is_configured() {
  [ -f "${INSTALL_DIR}/.aiteamforge-config" ]
}

# Uninstall mode
if [ "$MODE" = "uninstall" ]; then
  echo -e "${BOLD}AITeamForge Uninstall${NC}"
  echo ""

  if ! is_configured; then
    echo -e "${YELLOW}⚠ No aiteamforge installation found at: ${INSTALL_DIR}${NC}"
    exit 0
  fi

  echo "This will remove:"
  echo "  • Dev-team configuration from: ${INSTALL_DIR}"
  echo "  • LaunchAgents (kanban-backup, lcars-health)"
  echo "  • Shell integration from ~/.zshrc"
  echo ""
  echo -e "${RED}Warning: This will NOT remove the Homebrew formula${NC}"
  echo "To fully remove aiteamforge, also run: brew uninstall aiteamforge"
  echo ""

  # skipped in dry-run — every step below this point (LaunchAgent unload+rm,
  # ~/.zshrc rewrite, working-directory rm -rf) is a disk-visible side effect
  # that violates "preview without making changes". Also skip the
  # destructive-confirmation prompt itself: asking an operator to type "yes"
  # during a preview trains exactly the wrong reflex.
  if [ "$DRY_RUN" = "true" ]; then
    echo -e "${YELLOW}[DRY RUN]${NC} Would remove:"
    echo -e "${YELLOW}[DRY RUN]${NC}   • LaunchAgent: com.aiteamforge.kanban-backup.plist (if present)"
    echo -e "${YELLOW}[DRY RUN]${NC}   • LaunchAgent: com.aiteamforge.lcars-health.plist (if present)"
    echo -e "${YELLOW}[DRY RUN]${NC}   • aiteamforge block from ~/.zshrc (a backup would be created first)"
    echo -e "${YELLOW}[DRY RUN]${NC}   • Working directory ${INSTALL_DIR} (only if operator confirms interactively)"
    echo ""
    echo -e "${GREEN}AITeamForge uninstall preview complete — no changes made${NC}"
    exit 0
  fi

  read -rp "Continue with uninstall? (yes/no): " confirm

  if [ "$confirm" != "yes" ]; then
    echo "Uninstall cancelled"
    exit 0
  fi

  # Remove LaunchAgents
  if [ -f "$HOME/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist" ]; then
    _aitf_launchctl unload "$HOME/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist" 2>/dev/null || true
    rm "$HOME/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist"
    echo -e "${GREEN}✓${NC} Removed kanban-backup LaunchAgent"
  fi

  if [ -f "$HOME/Library/LaunchAgents/com.aiteamforge.lcars-health.plist" ]; then
    _aitf_launchctl unload "$HOME/Library/LaunchAgents/com.aiteamforge.lcars-health.plist" 2>/dev/null || true
    rm "$HOME/Library/LaunchAgents/com.aiteamforge.lcars-health.plist"
    echo -e "${GREEN}✓${NC} Removed lcars-health LaunchAgent"
  fi

  # Remove shell integration (backup first)
  if [ -f "$HOME/.zshrc" ]; then
    cp "$HOME/.zshrc" "$HOME/.zshrc.backup.$(date +%s)"
    # Remove the entire aiteamforge block between markers
    sed '/^# >>> aiteamforge initialize >>>/,/^# <<< aiteamforge initialize <<</d' "$HOME/.zshrc" > "$HOME/.zshrc.tmp" || true
    mv "$HOME/.zshrc.tmp" "$HOME/.zshrc"
    echo -e "${GREEN}✓${NC} Removed shell integration (backed up .zshrc)"
  fi

  # Ask about removing working directory
  echo ""
  read -rp "Remove working directory ${INSTALL_DIR}? (yes/no): " remove_dir

  if [ "$remove_dir" = "yes" ]; then
    # Safety bounds: refuse to rm -rf dangerous paths
    _safe=true
    _err=""

    # Reject empty path
    if [ -z "${INSTALL_DIR}" ]; then
      _safe=false; _err="INSTALL_DIR is empty"
    fi

    # Reject root or home directory
    if [ "${INSTALL_DIR}" = "/" ] || [ "${INSTALL_DIR}" = "$HOME" ]; then
      _safe=false; _err="INSTALL_DIR is a protected path (${INSTALL_DIR})"
    fi

    # Reject paths with fewer than 3 components (e.g. "/foo" or "/foo/bar")
    _components=$(echo "${INSTALL_DIR}" | tr -s '/' | tr '/' '\n' | grep -c '.')
    if [ "$_safe" = "true" ] && [ "${_components}" -lt 3 ]; then
      _safe=false; _err="INSTALL_DIR has too few path components (${INSTALL_DIR})"
    fi

    # Reject paths that don't contain "aiteamforge"
    if [ "$_safe" = "true" ] && [[ "${INSTALL_DIR}" != *"aiteamforge"* ]]; then
      _safe=false; _err="INSTALL_DIR does not contain 'aiteamforge' (${INSTALL_DIR})"
    fi

    if [ "$_safe" = "false" ]; then
      echo -e "${RED}✗ Refusing to delete: ${_err}${NC}"
      echo -e "${RED}  Aborting uninstall to prevent data loss.${NC}"
      exit 1
    fi

    rm -rf "${INSTALL_DIR}"
    echo -e "${GREEN}✓${NC} Removed ${INSTALL_DIR}"
  else
    # Just remove config marker
    rm -f "${INSTALL_DIR}/.aiteamforge-config"
    echo -e "${GREEN}✓${NC} Unmarked installation (files preserved)"
  fi

  echo ""
  echo -e "${GREEN}AITeamForge uninstalled successfully${NC}"
  echo "To reinstall: aiteamforge setup"
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# Helper: prompt with non-interactive support
# Usage: wizard_prompt "prompt text" default_value variable_name
# In non-interactive mode, always uses default_value
# ═══════════════════════════════════════════════════════════════════════════
wizard_prompt() {
  local prompt_text="$1"
  local default_val="$2"

  if [ "$MODE" = "non-interactive" ]; then
    echo "$default_val"
    return
  fi

  local answer
  read -rp "$prompt_text" answer
  echo "${answer:-$default_val}"
}

# Interactive setup
show_banner

echo -e "${CYAN}This wizard will configure your AITeamForge.${NC}"
if [ "$MODE" = "non-interactive" ]; then
  echo -e "${CYAN}Running in non-interactive mode — using defaults.${NC}"
fi
echo ""

# Check dependencies
echo -e "${BOLD}Checking dependencies...${NC}"
echo ""

MISSING_DEPS=()

check_dep() {
  local cmd=$1
  local name=$2
  local install=$3

  if command -v "$cmd" &>/dev/null; then
    echo -e "${GREEN}✓${NC} $name"
  else
    echo -e "${RED}✗${NC} $name ${YELLOW}(missing)${NC}"
    MISSING_DEPS+=("$name:$install")
  fi
}

check_dep "python3" "Python 3" "brew install python@3.13"
check_dep "node" "Node.js" "brew install node"
check_dep "jq" "jq" "brew install jq"
check_dep "gh" "GitHub CLI" "brew install gh"
check_dep "git" "Git" "xcode-select --install"
check_dep "tmux" "tmux" "brew install tmux"

# Check for iTerm2 (application, not command)
if [ -d "/Applications/iTerm.app" ]; then
  echo -e "${GREEN}✓${NC} iTerm2"
else
  echo -e "${RED}✗${NC} iTerm2 ${YELLOW}(missing)${NC}"
  MISSING_DEPS+=("iTerm2:brew install --cask iterm2")
fi

# Check for Fira Code Nerd Font (used by Default + Agent Panel iTerm2 profiles).
# macOS only sees fonts in ~/Library/Fonts/ or /Library/Fonts/. Homebrew cask
# installs to Caskroom but sometimes fails to link them into ~/Library/Fonts/.
_font_found=false
if [ -f "$HOME/Library/Fonts/FiraCodeNerdFontMono-Light.ttf" ] || [ -f "/Library/Fonts/FiraCodeNerdFontMono-Light.ttf" ]; then
  _font_found=true
fi

if [ "$_font_found" = "true" ]; then
  echo -e "${GREEN}✓${NC} Fira Code Nerd Font"
else
  # Check if brew already has it in Caskroom but didn't link.
  # Every subshell/find must be guarded with || true — set -eo pipefail
  # kills the script on any non-zero exit inside $() substitutions.
  _brew_prefix="$(brew --prefix 2>/dev/null || true)"
  _caskroom_fonts=""
  if [ -d "${_brew_prefix}/Caskroom/font-fira-code-nerd-font" ]; then
    _caskroom_fonts="$(find "${_brew_prefix}/Caskroom/font-fira-code-nerd-font" -name "FiraCodeNerdFontMono-*.ttf" 2>/dev/null | head -1 || true)"
  fi

  if [ -n "$_caskroom_fonts" ]; then
    echo -e "${YELLOW}⚠${NC} Fira Code Nerd Font in Caskroom but not registered — copying to ~/Library/Fonts/"
    _cask_dir="$(dirname "$_caskroom_fonts")"
    if [ "$DRY_RUN" = "true" ]; then
      # skipped in dry-run — mkdir+cp into ~/Library/Fonts is a disk-visible
      # side effect that violates "preview without making changes"
      echo -e "${YELLOW}[DRY RUN]${NC} Would copy Fira Code Nerd Font from Caskroom to ~/Library/Fonts/"
    else
      mkdir -p ~/Library/Fonts
      cp "$_cask_dir"/FiraCodeNerdFont*.ttf ~/Library/Fonts/ 2>/dev/null || true
      echo -e "${GREEN}✓${NC} Fira Code Nerd Font (copied to ~/Library/Fonts/)"
    fi
  else
    echo -e "${YELLOW}⚠${NC} Fira Code Nerd Font ${YELLOW}(not found — installing)${NC}"
    if [ "$DRY_RUN" = "true" ]; then
      # skipped in dry-run — brew install --cask and the verification
      # mkdir+cp below it are both disk-visible side effects that violate
      # "preview without making changes"
      echo -e "${YELLOW}[DRY RUN]${NC} Would run: brew install --cask font-fira-code-nerd-font"
    else
      brew install --cask font-fira-code-nerd-font 2>&1 | tail -3 || true
      # Verify the install linked to ~/Library/Fonts; copy from Caskroom if not
      if [ ! -f "$HOME/Library/Fonts/FiraCodeNerdFontMono-Light.ttf" ]; then
        _cask_dir=""
        if [ -d "${_brew_prefix}/Caskroom/font-fira-code-nerd-font" ]; then
          _cask_dir="$(find "${_brew_prefix}/Caskroom/font-fira-code-nerd-font" -name "FiraCodeNerdFontMono-*.ttf" -exec dirname {} \; 2>/dev/null | head -1 || true)"
        fi
        if [ -n "$_cask_dir" ]; then
          mkdir -p ~/Library/Fonts
          cp "$_cask_dir"/FiraCodeNerdFont*.ttf ~/Library/Fonts/ 2>/dev/null || true
          echo -e "${GREEN}✓${NC} Fira Code Nerd Font (installed + copied to ~/Library/Fonts/)"
        else
          echo -e "${YELLOW}⚠${NC} Could not install Fira Code Nerd Font"
          echo -e "   Manual: ${CYAN}brew install --cask font-fira-code-nerd-font${NC}"
        fi
      else
        echo -e "${GREEN}✓${NC} Fira Code Nerd Font (installed)"
      fi
    fi
  fi
fi

# Check for Claude Code
if command -v claude &>/dev/null; then
  echo -e "${GREEN}✓${NC} Claude Code"
else
  echo -e "${RED}✗${NC} Claude Code ${YELLOW}(missing)${NC}"
  MISSING_DEPS+=("Claude Code:npm install -g @anthropic-ai/claude-code")
fi

# Check iTerm2 Python API (required for tab management)
if [ -d "/Applications/iTerm.app" ]; then
  api_enabled=$(defaults read com.googlecode.iterm2 EnableAPIServer 2>/dev/null || true)
  if [ "$api_enabled" = "1" ]; then
    echo -e "${GREEN}✓${NC} iTerm2 Python API"
  else
    echo -e "${YELLOW}⚠${NC} iTerm2 Python API ${YELLOW}(disabled)${NC}"
    # skipped in dry-run — `defaults write` is a disk-visible system-
    # preference mutation regardless of which branch below would fire it;
    # short-circuit here so neither the non-interactive nor the interactive
    # path runs it.
    if [ "$DRY_RUN" = "true" ]; then
      echo -e "  ${YELLOW}[DRY RUN]${NC} Would enable iTerm2 Python API (defaults write com.googlecode.iterm2 EnableAPIServer -bool true)"
    elif [ "$MODE" = "non-interactive" ]; then
      echo -e "  Enabling iTerm2 Python API..."
      defaults write com.googlecode.iterm2 EnableAPIServer -bool true
      echo -e "${GREEN}✓${NC} iTerm2 Python API (enabled)"
    else
      echo ""
      echo -e "  The iTerm2 Python API is required for automatic tab creation."
      echo -e "  Enable it now, or manually via: iTerm2 → Settings → General → Magic → Enable Python API"
      read -rp "  Enable iTerm2 Python API? (yes/no) [yes]: " enable_api
      enable_api="${enable_api:-yes}"
      if [ "$enable_api" = "yes" ]; then
        defaults write com.googlecode.iterm2 EnableAPIServer -bool true
        echo -e "${GREEN}✓${NC} iTerm2 Python API (enabled)"
        echo -e "  ${YELLOW}Note: Restart iTerm2 for this to take effect.${NC}"
      else
        echo -e "${YELLOW}⚠${NC} Tab management will not work without Python API"
      fi
    fi
  fi
fi

echo ""

# Handle missing dependencies
if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
  echo -e "${YELLOW}⚠ Missing required dependencies${NC}"
  echo ""
  echo "Install missing dependencies:"
  echo ""
  for dep in "${MISSING_DEPS[@]}"; do
    name="${dep%%:*}"
    install="${dep#*:}"
    echo "  $install"
  done
  echo ""

  # skipped in dry-run — running the queued install commands, or re-exec'ing
  # the wizard afterward, are both disk-visible side effects that violate
  # "preview without making changes". Fall through to continue the preview
  # rather than exiting: in a dry run the deps legitimately aren't there yet,
  # and the operator still wants to see the rest of what setup would do.
  if [ "$DRY_RUN" = "true" ]; then
    for dep in "${MISSING_DEPS[@]}"; do
      install="${dep#*:}"
      echo -e "${YELLOW}[DRY RUN]${NC} Would install: $install"
    done
    echo ""
  elif [ "$MODE" = "non-interactive" ]; then
    echo -e "${YELLOW}⚠ Skipping missing dependencies in non-interactive mode${NC}"
  else
    read -rp "Install missing dependencies now? (yes/no): " install_deps

    if [ "$install_deps" = "yes" ]; then
      echo ""
      echo -e "${BLUE}Installing dependencies...${NC}"
      for dep in "${MISSING_DEPS[@]}"; do
        install="${dep#*:}"
        echo "Running: $install"
        # Execute directly without eval - install commands are hardcoded in script
        bash -c "$install" || echo -e "${RED}Failed: $install${NC}"
      done
      echo ""
      echo -e "${GREEN}Dependencies installed${NC}"
      echo ""
      echo "Restarting setup wizard..."
      echo ""
      sleep 1
      exec bash "$0" "${ORIGINAL_ARGS[@]}"
    else
      echo ""
      echo -e "${RED}Cannot continue without required dependencies${NC}"
      exit 1
    fi
  fi
fi

# Installation directory
echo -e "${BOLD}Installation Location${NC}"
echo ""
echo "Default installation directory: ${INSTALL_DIR}"

if [ "$MODE" != "non-interactive" ]; then
  echo ""
  read -rp "Use default location? (yes/no): " use_default

  if [ "$use_default" != "yes" ]; then
    read -rp "Enter installation directory: " custom_dir
    INSTALL_DIR="${custom_dir/#\~/$HOME}" # Expand ~
  fi
fi

echo ""
echo "Installing to: ${INSTALL_DIR}"

# Check if already exists.
#
# Three outcomes when a prior install is present:
#   Upgrade     — refresh components in place, keep teams/config (default)
#   Preserve    — exit, change nothing
#   Reconfigure — re-run the full wizard (re-prompt teams + features)
#
# --upgrade on the CLI already set IS_UPGRADE=true (arg parser); honor it
# without prompting. Non-interactive mode auto-upgrades (preserves prior
# behavior). Interactive mode shows the three-way menu.
if is_configured; then
  echo ""
  echo -e "${YELLOW}⚠ Existing installation found${NC}"

  if [ "$IS_UPGRADE" = "true" ]; then
    # --upgrade flag was passed explicitly; skip the menu.
    echo "Upgrading existing installation (--upgrade)"
  elif [ "$MODE" = "non-interactive" ]; then
    echo "Upgrading existing installation (non-interactive mode)"
    IS_UPGRADE="true"
  else
    echo ""
    echo "  [U] Upgrade     - refresh components, keep teams/config"
    echo "  [P] Preserve    - exit, change nothing"
    echo "  [R] Reconfigure - re-run the full wizard"
    echo ""
    # Loop until we get a recognized choice. Empty input defaults to Upgrade.
    while true; do
      read -rp "Choice [U]: " _setup_choice
      case "$(printf '%s' "${_setup_choice:-U}" | tr '[:upper:]' '[:lower:]')" in
        u|upgrade)
          IS_UPGRADE="true"
          echo -e "${GREEN}✓${NC} Upgrade — refreshing components, keeping teams/config"
          break
          ;;
        p|preserve)
          echo -e "${GREEN}✓${NC} Preserved — no changes made"
          exit 0
          ;;
        r|reconfigure)
          IS_UPGRADE="false"
          echo -e "${GREEN}✓${NC} Reconfigure — re-running the full wizard"
          break
          ;;
        *)
          echo -e "${YELLOW}⚠ Unrecognized choice: '${_setup_choice}'. Enter U, P, or R.${NC}"
          ;;
      esac
    done
  fi
fi

# Create installation directory (skipped in dry-run — creating it would be
# a disk-visible side effect that violates "preview without making changes").
if [ "$DRY_RUN" != "true" ]; then
  mkdir -p "${INSTALL_DIR}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# EXPORT VARIABLES FOR INSTALLER MODULES
# ═══════════════════════════════════════════════════════════════════════════

export AITEAMFORGE_DIR="${INSTALL_DIR}"
export INSTALL_ROOT="${AITEAMFORGE_HOME}"
INSTALLERS_DIR="${AITEAMFORGE_HOME}/libexec/installers"
TEAMS_DIR="${AITEAMFORGE_HOME}/share/teams"

# XACA-0804: this is the interactive setup wizard — opt in to registry
# bootstrap-write here so every install-team.sh invocation below (each its
# own child process) inherits setup intent, not just read-and-fallback.
export AITEAMFORGE_ALLOW_BOOTSTRAP_WRITE=1

# Source common utilities (used by installer modules)
source "${AITEAMFORGE_HOME}/libexec/lib/common.sh"

# launchagents.sh provides the load-verify + disabled-detection helpers used
# by the "Load LaunchAgents" block below (XACA-1097) — a bare `launchctl load`
# exit code is not proof the agent registered. Sourced defensively at TOP
# LEVEL (own include-guard, no top-level side effects) so it is available to
# that block, which itself must run at top level, not in a subshell. The
# block still guards each call with `type` so a missing lib degrades to a
# clear warning instead of "command not found".
# shellcheck source=../libexec/lib/launchagents.sh
[ -f "${AITEAMFORGE_HOME}/libexec/lib/launchagents.sh" ] && source "${AITEAMFORGE_HOME}/libexec/lib/launchagents.sh" 2>/dev/null || true

# XACA-0676: trust the Homebrew tap so the formula keeps loading after a Homebrew
# upgrade flips on the tap-trust gate ($HOMEBREW_REQUIRE_TAP_TRUST). Without this,
# `brew upgrade` / `brew postinstall aiteamforge` silently no-op and the box rots
# on an old version. Idempotent; only run when brew + the tap are actually present
# so non-brew installs aren't confused. Guarded — set -eo pipefail is active.
if command -v brew &>/dev/null && brew tap 2>/dev/null | grep -qi "$(_aitf_tap_name)"; then
  if ensure_tap_trusted; then
    echo -e "${GREEN}✓${NC} Homebrew tap trusted ($(_aitf_tap_name))"
  else
    echo -e "${YELLOW}⚠${NC} Could not trust the Homebrew tap (older Homebrew without trust gate?) — continuing"
  fi
fi

# Sanitize an id before it is interpolated into an `eval`'d variable NAME.
# Allow only alphanumerics, dot, hyphen, underscore. Defined here (before the
# upgrade-hydration block) so BOTH the hydration path and the later
# project-based-team loop can use it — the loop's own copy lived inside the
# team-selection block, which the hydrated-upgrade path skips (XACA-0559).
_sanitize_id() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9._-]//g'; }

# ═══════════════════════════════════════════════════════════════════════════
# UPGRADE HYDRATION (XACA-0559)
#
# On an upgrade (IS_UPGRADE=true) we refresh the EXISTING install in place:
# re-read the prior selection from .aiteamforge-config rather than re-prompting.
# This populates SELECTED_TEAMS, the per-team _WORKDIR_<team> vars, and the
# INSTALL_* feature flags so the team-install loops and the kanban refresh run
# against exactly the teams the user already has. INSTALL_KANBAN is FORCED to
# "yes" so the shared-component refresh (hooks/UI/helpers) always runs — that
# refresh is the whole point of an upgrade.
#
# Degrades gracefully: if jq or the config is missing/unparseable, we fall
# through to the interactive wizard (UPGRADE_HYDRATED stays "false"), so the
# user is never left with an empty selection on a broken config.
#
# Cockpit upgrades are intentionally excluded — cockpit installs have no teams
# and the dedicated cockpit passes handle their own refresh.
# ═══════════════════════════════════════════════════════════════════════════
UPGRADE_HYDRATED="false"

if [ "$IS_UPGRADE" = "true" ] && [ "$INSTALL_PROFILE" != "cockpit" ]; then
  _cfg="${INSTALL_DIR}/.aiteamforge-config"
  if command -v jq &>/dev/null && [ -f "$_cfg" ] && jq -e . "$_cfg" >/dev/null 2>&1; then
    echo ""
    echo -e "${BOLD}Upgrade: reading existing configuration${NC}"

    # Teams (JSON array of team id strings) → SELECTED_TEAMS
    SELECTED_TEAMS=()
    while IFS= read -r _t; do
      # Sanitize the config-derived id before it flows into the eval var-NAMEs
      # below (and into every downstream _WORKDIR_<team> read) — defense-in-depth
      # so a tampered .aiteamforge-config can't inject via the eval name. Done
      # once here so the array value and the eval name stay consistent (XACA-0559).
      _t="$(_sanitize_id "$_t")"
      [ -n "$_t" ] && SELECTED_TEAMS+=("$_t")
    done < <(jq -r '.teams[]? // empty' "$_cfg" 2>/dev/null)

    if [ ${#SELECTED_TEAMS[@]} -gt 0 ]; then
      # Per-team working dirs from team_paths.<team>.working_dir → _WORKDIR_<team>
      # (also restore client_id/project_id so the config rewrite preserves them).
      for _ht in "${SELECTED_TEAMS[@]}"; do
        _hwdir="$(jq -r --arg t "$_ht" '.team_paths[$t].working_dir // empty' "$_cfg" 2>/dev/null)"
        _hproj="$(jq -r --arg t "$_ht" '.team_paths[$t].project_id // empty' "$_cfg" 2>/dev/null)"
        _hclient="$(jq -r --arg t "$_ht" '.team_paths[$t].client_id // empty' "$_cfg" 2>/dev/null)"
        [ -n "$_hwdir" ] && eval "_WORKDIR_${_ht}=\"${_hwdir}\""
        [ -n "$_hproj" ] && eval "_PROJECT_${_ht}=\"${_hproj}\""
        [ -n "$_hclient" ] && eval "_CLIENT_${_ht}=\"${_hclient}\""
      done

      # Feature flags from features.* (JSON booleans) → INSTALL_* (yes/no).
      _bool_to_yn() { [ "$1" = "true" ] && echo "yes" || echo "no"; }
      INSTALL_SHELL="$(_bool_to_yn "$(jq -r '.features.shell_environment // false' "$_cfg" 2>/dev/null)")"
      INSTALL_CLAUDE="$(_bool_to_yn "$(jq -r '.features.claude_code_config // false' "$_cfg" 2>/dev/null)")"
      INSTALL_FLEET="$(_bool_to_yn "$(jq -r '.features.fleet_monitor // false' "$_cfg" 2>/dev/null)")"
      FLEET_MODE="$(jq -r '.features.fleet_mode // "standalone"' "$_cfg" 2>/dev/null)"
      FLEET_SERVER_URL="$(jq -r '.features.fleet_server_url // ""' "$_cfg" 2>/dev/null)"

      # Force kanban refresh: the shared-component refresh is the point of an
      # upgrade, so kanban always runs regardless of the prior feature flag.
      INSTALL_KANBAN="yes"

      # Restore the machine name so the config rewrite + summary keep it.
      _hmachine="$(jq -r '.machine_name // empty' "$_cfg" 2>/dev/null)"
      [ -n "$_hmachine" ] && MACHINE_NAME="$_hmachine"

      UPGRADE_HYDRATED="true"
      echo -e "${GREEN}✓${NC} Upgrading installed teams: ${SELECTED_TEAMS[*]}"
      echo -e "${GREEN}✓${NC} Refreshing components (kanban refresh forced on)"
    else
      echo -e "${YELLOW}⚠ Config has no teams — falling back to interactive selection${NC}"
    fi
  else
    echo -e "${YELLOW}⚠ Could not read ${INSTALL_DIR}/.aiteamforge-config (jq/config missing) — falling back to interactive selection${NC}"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1: MACHINE IDENTITY
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}Step 1: Machine Identity${NC}"
echo ""
echo "Give this machine a name (used for Fleet Monitor and multi-machine setups)."
echo ""

DEFAULT_MACHINE_NAME="$(hostname -s 2>/dev/null || echo "my-mac")"

if [ "$UPGRADE_HYDRATED" = "true" ]; then
  # Machine name already restored from config; don't re-prompt on upgrade.
  MACHINE_NAME="${MACHINE_NAME:-$DEFAULT_MACHINE_NAME}"
  echo "Keeping existing machine name (upgrade)."
elif [ "$MODE" = "non-interactive" ]; then
  MACHINE_NAME="$DEFAULT_MACHINE_NAME"
else
  read -rp "Machine name [${DEFAULT_MACHINE_NAME}]: " MACHINE_NAME
  MACHINE_NAME="${MACHINE_NAME:-$DEFAULT_MACHINE_NAME}"
fi

echo ""
echo -e "${GREEN}✓${NC} Machine name: ${MACHINE_NAME}"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2: TEAM SELECTION
# Skipped in cockpit mode — all connect scripts render for ALL teams
# unconditionally; no team working dirs are installed.
# Skipped on a hydrated upgrade — SELECTED_TEAMS is already populated from the
# existing config (XACA-0559); re-prompting would defeat "refresh in place".
# ═══════════════════════════════════════════════════════════════════════════

if [ "$UPGRADE_HYDRATED" = "true" ]; then
  echo ""
  echo -e "${BOLD}Step 2: Team Selection${NC}"
  echo -e "  ${CYAN}[UPGRADE] Keeping existing teams: ${SELECTED_TEAMS[*]}${NC}"
  echo ""
elif [ "$INSTALL_PROFILE" = "cockpit" ]; then
  SELECTED_TEAMS=()
  echo ""
  echo -e "${BOLD}Step 2: Team Selection${NC}"
  echo -e "  ${CYAN}[COCKPIT MODE] Skipping team selection — all connect scripts will be rendered${NC}"
  echo ""
else

SELECTED_TEAMS=()

echo ""
echo -e "${BOLD}Step 2: Select Teams${NC}"
echo ""
echo "Choose which development teams to install."
echo "Each team includes agent personas, kanban board, and startup scripts."
echo ""

# Build list of available teams from .conf files
AVAILABLE_TEAMS=()
TEAM_LABELS=()

for conf_file in "${TEAMS_DIR}"/*.conf; do
  [ -f "$conf_file" ] || continue
  tid="$(basename "$conf_file" .conf)"

  # XACA-1070-002: mandatory teams are never shown as a checkbox — they are
  # force-appended into SELECTED_TEAMS by _atf_apply_mandatory_teams (PR #865
  # review, BLOCKING 1 fix: called right after selection is finalized below,
  # BEFORE the working-dir loop — see that function's header comment near
  # the top of this file). Skip adding this one to AVAILABLE_TEAMS/TEAM_LABELS
  # so it can't be selected twice and never occupies a numbered slot in the
  # printed menu.
  #
  # `atf_is_mandatory_team` is safe here even though this script runs under
  # `set -eo pipefail`: it's the condition of an `if`, and bash exempts
  # if/while/until conditions from errexit entirely — including whatever
  # non-zero exit happens inside the function it calls (an unreadable
  # registry.json fails the function closed, per mandatory-teams.sh's
  # contract, which here just means "don't suppress," not "abort the
  # wizard"). The `command -v` guard makes the same true when the lib
  # itself failed to source.
  if command -v atf_is_mandatory_team >/dev/null 2>&1 && atf_is_mandatory_team "$tid"; then
    continue
  fi

  # Read team name and description from conf
  tname="$(grep '^TEAM_NAME=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
  tdesc="$(grep '^TEAM_DESCRIPTION=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
  tcat="$(grep '^TEAM_CATEGORY=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"

  AVAILABLE_TEAMS+=("$tid")
  TEAM_LABELS+=("${tid} - ${tname} (${tdesc})")
done

# Display teams with numbers
for i in "${!TEAM_LABELS[@]}"; do
  echo "  $((i + 1))) ${TEAM_LABELS[$i]}"
done
echo ""
echo "Enter team numbers separated by spaces (e.g., '1 3 5'), or 'all' for everything."
echo ""

if [ "$MODE" = "non-interactive" ]; then
  team_choices="${AITEAMFORGE_TEAMS:-all}"
  echo "Teams to install: $team_choices (non-interactive)"
else
  read -rp "Teams to install: " team_choices
fi

if [ "$team_choices" = "all" ]; then
  SELECTED_TEAMS=("${AVAILABLE_TEAMS[@]}")
else
  for choice in $team_choices; do
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#AVAILABLE_TEAMS[@]} ]; then
      SELECTED_TEAMS+=("${AVAILABLE_TEAMS[$((choice - 1))]}")
    else
      echo -e "${YELLOW}⚠ Skipping invalid choice: $choice${NC}"
    fi
  done
fi

if [ ${#SELECTED_TEAMS[@]} -eq 0 ]; then
  echo -e "${RED}No teams selected. At least one team is required.${NC}"
  exit 1
fi

echo ""
echo -e "${GREEN}✓${NC} Selected teams: ${SELECTED_TEAMS[*]}"

# XACA-1070-002 / PR #865 review, BLOCKING 1 — CALL SITE 1: apply mandatory
# teams here, BEFORE the per-team working-dir loop immediately below (the
# first loop anywhere in this file that consumes SELECTED_TEAMS). This is
# the fix: everything downstream of this point — the working-dir loop, the
# persona/avatar copy, and the install-team.sh loop — now sees the
# mandatory team as if the user had picked it. See the function's own
# header comment (near the top of this file) for the full rationale and
# why a second call site also exists further down.
_atf_apply_mandatory_teams

# -----------------------------------------------------------------------
# For project-based teams, ask for ClientID and/or ProjectID
# Uses eval instead of declare -A (bash 3.2 compatible)
# Variables: _PROJECT_<team_id>, _WORKDIR_<team_id>, _CLIENT_<team_id>
# -----------------------------------------------------------------------
# _sanitize_id is defined earlier (before the upgrade-hydration block) so it is
# available on both the hydrated-upgrade and interactive paths (XACA-0559).

for team_id in "${SELECTED_TEAMS[@]}"; do
  conf_file="${TEAMS_DIR}/${team_id}.conf"
  [ -f "$conf_file" ] || continue

  has_projects="$(grep '^TEAM_HAS_PROJECTS=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
  requires_client="$(grep '^TEAM_REQUIRES_CLIENT_ID=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
  working_dir="$(grep '^TEAM_WORKING_DIR=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
  working_dir="${working_dir/\$HOME/$HOME}" # Expand $HOME

  # If the conf's working_dir is the default ($HOME/aiteamforge), remap to the
  # user-chosen INSTALL_DIR so non-default installs stay self-contained.
  if [ "$working_dir" = "$HOME/aiteamforge" ] && [ "$INSTALL_DIR" != "$HOME/aiteamforge" ]; then
    working_dir="$INSTALL_DIR"
  fi

  if [ "$requires_client" = "true" ]; then
    # Team requires ClientID + ProjectID (e.g., freelance)
    default_project="$(grep '^TEAM_DEFAULT_PROJECT=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
    team_name="$(grep '^TEAM_NAME=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
    echo ""
    echo -e "${CYAN}${team_name}${NC} requires client and project identifiers"
    echo -e "  (e.g., client=acme, project=mobile-app → ${working_dir}/acme/mobile-app/)"

    if [ "$MODE" = "non-interactive" ]; then
      client_id="default-client"
    else
      read -rp "  Client ID: " client_id
      client_id="$(_sanitize_id "$client_id")"
    fi
    if [ -z "$client_id" ]; then
      # ═════════════════════════════════════════════════════════════════
      # XACA-1070-021 (PR #865 round 3): a MANDATORY team cannot be
      # dropped here by leaving Client ID blank.
      #
      # Why this branch has to exist at all: the "drop" path below does
      # `SELECTED_TEAMS=("${SELECTED_TEAMS[@]/$team_id}")`, which is a
      # bash pattern-substitution on every array element, not a filter —
      # it turns the matching element into the EMPTY STRING, it does not
      # remove the slot. For an ordinary team that is harmless: every
      # downstream consumer of SELECTED_TEAMS already guards with
      # `[ -z "$team_id" ] && continue` (see the loops at the team-install,
      # persona-copy, and config-serialization sites below).
      #
      # For a MANDATORY team it is not harmless, because of what happens
      # one function-call away from here. This same loop only runs on the
      # interactive path, textually inside _atf_apply_mandatory_teams'
      # CALL SITE 1 (top of this file) ... call site 2 (the
      # UPGRADE_HYDRATED/cockpit safety net, right after this whole Step 2
      # block closes). Call site 2's dedup scan compares the mandatory id
      # against every CURRENT element of SELECTED_TEAMS looking for an
      # exact string match. A blanked slot is "", not the mandatory id, so
      # the scan finds no match and re-appends the id — but by then this
      # working-dir loop has already finished, so _WORKDIR_<team>/
      # _CLIENT_<team>/_PROJECT_<team> are never set for that second,
      # metadata-less append. The team then reaches install-team.sh (and
      # .aiteamforge-config's team_paths serialization) with no working
      # directory the user chose and, for a client/project team, no
      # client or project id — a broken install for a team the wizard
      # was never supposed to let the user opt out of in the first place.
      #
      # Chosen semantic: refuse the drop, not "restore metadata after the
      # fact". A mandatory team is mandatory — the prompt should not
      # produce a state where it silently vanishes AND silently
      # reappears half-configured a few lines later. Falling back to the
      # same "default-client" the non-interactive path already uses (a
      # few lines up in this same branch) keeps this a ONE-PLACE fix:
      # client_id becomes non-empty here, so this iteration's own
      # eval-assignments a few lines below run exactly as they would for
      # any other team, SELECTED_TEAMS is never blanked, and call site 2
      # stays the no-op safety net its own header comment says it is.
      # ═════════════════════════════════════════════════════════════════
      if command -v atf_is_mandatory_team >/dev/null 2>&1 && atf_is_mandatory_team "$team_id"; then
        echo -e "  ${YELLOW}⚠${NC} ${team_id} is a mandatory team and cannot be skipped by leaving Client ID blank — using default Client ID 'default-client' (XACA-1070-021)."
        client_id="default-client"
      else
        echo -e "  ${RED}Client ID is required. Skipping ${team_id}.${NC}"
        # Remove from selected teams
        SELECTED_TEAMS=("${SELECTED_TEAMS[@]/$team_id}")
        continue
      fi
    fi
    if [ "$MODE" = "non-interactive" ]; then
      project_id="${default_project}"
    else
      read -rp "  Project ID [${default_project}]: " project_id
      project_id="$(_sanitize_id "${project_id:-$default_project}")"
    fi
    project_id="${project_id:-$default_project}"
    eval "_PROJECT_${team_id}=\"${project_id}\""
    eval "_CLIENT_${team_id}=\"${client_id}\""
    eval "_WORKDIR_${team_id}=\"${working_dir}/${client_id}/${project_id}\""
    echo -e "  ${GREEN}✓${NC} ${team_id}: ${working_dir}/${client_id}/${project_id}"

  elif [ "$has_projects" = "true" ]; then
    # Team requires ProjectID only (e.g., legal, medical)
    default_project="$(grep '^TEAM_DEFAULT_PROJECT=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
    team_name="$(grep '^TEAM_NAME=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
    echo ""
    echo -e "${CYAN}${team_name}${NC} uses project-based organization"
    if [ "$MODE" = "non-interactive" ]; then
      project_id="${default_project}"
    else
      read -rp "  Project ID [${default_project}]: " project_id
      project_id="$(_sanitize_id "${project_id:-$default_project}")"
    fi
    project_id="${project_id:-$default_project}"
    eval "_PROJECT_${team_id}=\"${project_id}\""
    eval "_WORKDIR_${team_id}=\"${working_dir}/${project_id}\""
    echo -e "  ${GREEN}✓${NC} ${team_id}: ${working_dir}/${project_id}"

  else
    eval "_WORKDIR_${team_id}=\"${working_dir}\""
  fi
done

fi  # end: if INSTALL_PROFILE != cockpit (team selection block)

# XACA-1070-002 / PR #865 review, BLOCKING 1 — CALL SITE 2: safety net for
# the UPGRADE_HYDRATED and cockpit branches above. Both populate
# SELECTED_TEAMS through their own arm of the if/elif/else that just
# closed and never reach call site 1 (which lives textually inside the
# interactive else-branch only). This call is a no-op on the interactive
# path — the dedup check inside _atf_apply_mandatory_teams skips an id
# that is already present, so it never double-adds or double-announces.
_atf_apply_mandatory_teams

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3: FEATURE SELECTION
# Skipped in cockpit mode — all heavy features are off; only cockpit-required
# components (venv, iterm2 scripts, dynamic profile) are installed via the
# pre-installer block that runs unconditionally before this section.
# Skipped on a hydrated upgrade — INSTALL_* flags are already populated from the
# existing config (with INSTALL_KANBAN forced "yes") by the upgrade-hydration
# block above (XACA-0559). Do NOT reset them here, or the refresh selection is
# lost and the kanban refresh never runs.
#
# XACA-1070 / PR #865 round 2: INSTALL_KANBAN stays "no" for cockpit below
# EVEN THOUGH a mandatory team now gets a full local install on cockpit
# (see the "Install selected teams" header comment further down). This was
# investigated, not overlooked: install-team.sh writes a mandatory team's
# *-board.json itself, with zero reference to INSTALL_KANBAN anywhere in
# that installer, and EPIC-0057 places the intended first mandatory team's
# (spacedock) board at ~/.aiteamforge/spacedock/kanban/ — deliberately
# OUTSIDE $AITEAMFORGE_DIR — precisely so it never depends on the kanban
# system being installed. Flipping INSTALL_KANBAN="yes" here would turn on
# the LCARS backup system, port-management templates, and every mandatory
# LaunchAgent for the WHOLE BOX, which the user decision behind this ticket
# never asked for. The one real gap this leaves (the mandatory team's LCARS
# web server has nowhere to run from, since install_lcars_ui is normally
# reached only through the INSTALL_KANBAN="yes" path) is closed narrowly,
# without flipping this flag, by the "Cockpit mandatory-team LCARS
# instance" block after the team-install loop below.
# ═══════════════════════════════════════════════════════════════════════════

if [ "$UPGRADE_HYDRATED" = "true" ]; then
  echo ""
  echo -e "${BOLD}Step 3: Feature Selection${NC}"
  echo -e "  ${CYAN}[UPGRADE] Refreshing existing features: shell=${INSTALL_SHELL}, claude=${INSTALL_CLAUDE}, kanban=${INSTALL_KANBAN}, fleet=${INSTALL_FLEET}${NC}"
  echo ""
else

INSTALL_SHELL="no"
INSTALL_CLAUDE="no"
INSTALL_KANBAN="no"
INSTALL_FLEET="no"
FLEET_MODE="standalone"
FLEET_SERVER_URL=""

if [ "$INSTALL_PROFILE" = "cockpit" ]; then
  echo ""
  echo -e "${BOLD}Step 3: Feature Selection${NC}"
  echo -e "  ${CYAN}[COCKPIT MODE] Skipping feature selection — no local team features needed${NC}"
  echo ""
elif [ "$MODE" = "non-interactive" ]; then
  echo ""
  echo -e "${BOLD}Step 3: Choose Features${NC}"
  echo ""
  INSTALL_SHELL="yes"
  INSTALL_CLAUDE="yes"
  INSTALL_KANBAN="yes"
  INSTALL_FLEET="no"
  FLEET_MODE="standalone"
  FLEET_SERVER_URL=""
  echo -e "${GREEN}✓${NC} Features: shell=yes, claude=yes, kanban=yes, fleet=skip (defaults)"
else
  echo ""
  echo -e "${BOLD}Step 3: Choose Features${NC}"
  echo ""

  # Shell Environment
  echo -e "${CYAN}Shell Environment${NC} — Terminal aliases, prompts, and helpers"
  read -rp "  Install shell environment? (yes/no) [yes]: " ans
  INSTALL_SHELL="${ans:-yes}"
  echo ""

  # Claude Code Configuration
  echo -e "${CYAN}Claude Code Config${NC} — AI agent settings, hooks, and personas"
  read -rp "  Install Claude Code config? (yes/no) [yes]: " ans
  INSTALL_CLAUDE="${ans:-yes}"
  echo ""

  # LCARS Kanban System
  echo -e "${CYAN}LCARS Kanban System${NC} — Visual task management with web UI"
  read -rp "  Install LCARS Kanban? (yes/no) [yes]: " ans
  INSTALL_KANBAN="${ans:-yes}"
  echo ""

  # Fleet Monitor
  echo -e "${CYAN}Fleet Monitor${NC} — Cross-machine monitoring and agent status tracking"
  echo -e "  Fleet Monitor provides a web dashboard to see agent sessions across"
  echo -e "  all your development machines. Requires Tailscale for remote access."
  echo ""
  echo "  Options:"
  echo "    1) Skip       — Don't install Fleet Monitor"
  echo "    2) New Server — Set up a NEW Fleet Monitor server on this machine"
  echo "    3) Connect    — Connect this machine to an EXISTING Fleet Monitor"
  echo ""
  read -rp "  Choose (1/2/3) [1]: " fleet_choice
  fleet_choice="${fleet_choice:-1}"

  FLEET_MODE="standalone"
  FLEET_SERVER_URL=""

  case "$fleet_choice" in
    2)
      INSTALL_FLEET="yes"
      FLEET_MODE="server"
      echo -e "  ${GREEN}✓${NC} Will set up a new Fleet Monitor server"
      ;;
    3)
      INSTALL_FLEET="yes"
      FLEET_MODE="client"
      echo ""
      echo "  Enter the URL of the existing Fleet Monitor server."
      echo "  (e.g., http://192.168.1.100:3000 or https://my-mac.tail12345.ts.net)"
      read -rp "  Server URL: " FLEET_SERVER_URL
      if [ -z "$FLEET_SERVER_URL" ]; then
        echo -e "  ${RED}✗ No URL provided — skipping Fleet Monitor${NC}"
        INSTALL_FLEET="no"
      else
        echo -e "  ${GREEN}✓${NC} Will connect to: ${FLEET_SERVER_URL}"
      fi
      ;;
    *)
      echo -e "  Skipping Fleet Monitor"
      ;;
  esac
  echo ""
fi

fi  # end: if UPGRADE_HYDRATED (Step 3 feature selection wrapper, XACA-0559)

echo -e "${GREEN}✓${NC} Features selected"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3.5: CHANGE REQUEST (CR) WORKFLOW — per-team opt-in (XACA-0470)
# Ask, per selected team, whether to enable the Confluence + IT Connect CR
# workflow. If any team opts in, capture shared Atlassian credentials once.
# Skipped in cockpit / non-interactive / hydrated-upgrade contexts — the
# installer's migration path (install-kanban.sh::maybe_migrate_cr_config) covers
# upgrades and pre-existing installs.
# ═══════════════════════════════════════════════════════════════════════════
CR_ENABLED_TEAMS=()
CR_ATLASSIAN_EMAIL=""
CR_ATLASSIAN_TOKEN=""
CR_CONFLUENCE_SITE=""
CR_SPACE_KEY=""
# Sentinel: "1" only when the prompt below actually ran. Without it the installer
# cannot tell "wizard asked, user declined all" (record it) from "wizard skipped
# this on a hydrated upgrade/cockpit" (leave existing CR config untouched —
# otherwise an upgrade would silently disable CR for teams that had it on).
CR_WIZARD_RAN=""

if [ "$MODE" != "non-interactive" ] && [ "$UPGRADE_HYDRATED" != "true" ] \
   && [ "$INSTALL_PROFILE" != "cockpit" ] && [ "$INSTALL_KANBAN" = "yes" ] \
   && [ ${#SELECTED_TEAMS[@]} -gt 0 ]; then
  CR_WIZARD_RAN="1"
  echo ""
  echo -e "${CYAN}Change Request Workflow${NC} — optional Confluence + IT Connect CR tracking, per team"
  for _cr_team in "${SELECTED_TEAMS[@]}"; do
    [ -z "$_cr_team" ] && continue
    if prompt_yes_no "  Enable Change Request workflow for team '${_cr_team}'?" "n"; then
      CR_ENABLED_TEAMS+=("$_cr_team")
    fi
  done

  if [ ${#CR_ENABLED_TEAMS[@]} -gt 0 ]; then
    echo ""
    echo -e "${CYAN}Atlassian API credentials${NC} (shared across CR-enabled teams)"
    echo -e "  Create an API token: ${BLUE}https://id.atlassian.com/manage-profile/security/api-tokens${NC}"
    read -rp "  Atlassian account email: " CR_ATLASSIAN_EMAIL
    read -rsp "  Atlassian API token (hidden): " CR_ATLASSIAN_TOKEN; echo ""
    read -rp "  Confluence site [mainevent.atlassian.net]: " CR_CONFLUENCE_SITE
    CR_CONFLUENCE_SITE="${CR_CONFLUENCE_SITE:-mainevent.atlassian.net}"
    read -rp "  Confluence space key [DPD2]: " CR_SPACE_KEY
    CR_SPACE_KEY="${CR_SPACE_KEY:-DPD2}"
    if [ -z "$CR_ATLASSIAN_EMAIL" ] || [ -z "$CR_ATLASSIAN_TOKEN" ]; then
      echo -e "  ${YELLOW}⚠ Email and token are both required — CR credentials will be skipped.${NC}"
      echo -e "  ${YELLOW}  Re-run 'aiteamforge upgrade' interactively to finish CR setup.${NC}"
      CR_ATLASSIAN_TOKEN=""
    fi
    echo -e "  ${GREEN}✓${NC} CR enabled for: ${CR_ENABLED_TEAMS[*]}"
  else
    echo -e "  ${GREEN}✓${NC} Change Request workflow left disabled for all teams"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4: CONFIRM & INSTALL
# ═══════════════════════════════════════════════════════════════════════════

# XACA-1070 / PR #865 round 2, carve-out 4 of 4: SELECTED_TEAMS is no longer
# guaranteed empty on cockpit — _atf_apply_mandatory_teams (Step 2 call site
# 2) force-appends any mandatory team id into it before any of the three
# cockpit summary/dry-run/completion messages below print. Telling a cockpit
# user "Teams: (none...)" unconditionally would be actively wrong once a
# mandatory team is force-appended: that team gets a full local install (see
# the "Install selected teams" and "Cockpit mandatory-team LCARS instance"
# blocks above), not just a connect script like every other cockpit team.
# One shared helper, used at all three display sites, so they cannot drift
# out of sync with each other the way three independent inline checks could.
_cockpit_mandatory_teams_str() {
  local _t _out=""
  for _t in "${SELECTED_TEAMS[@]}"; do
    [ -n "$_t" ] || continue
    _out="${_out:+$_out }$_t"
  done
  printf '%s' "$_out"
}

echo ""
echo -e "${BOLD}Installation Summary${NC}"
echo ""
echo "  Machine:    ${MACHINE_NAME}"
echo "  Directory:  ${INSTALL_DIR}"
echo "  Profile:    ${INSTALL_PROFILE}"
if [ "$INSTALL_PROFILE" = "cockpit" ]; then
  _cockpit_mand_str="$(_cockpit_mandatory_teams_str)"
  if [ -n "$_cockpit_mand_str" ]; then
    echo "  Teams:      ${_cockpit_mand_str} (mandatory — full local install; every other team gets connect scripts only)"
  else
    echo "  Teams:      (none — cockpit mode renders connect scripts for all teams)"
  fi
  echo "  Features:   iTerm2 scripts + dynamic profile + connect scripts"
else
  echo "  Teams:      ${SELECTED_TEAMS[*]}"
  echo "  Features:"
  echo "    Shell Environment:   ${INSTALL_SHELL}"
  echo "    Claude Code Config:  ${INSTALL_CLAUDE}"
  echo "    LCARS Kanban:        ${INSTALL_KANBAN}"
  if [ "$INSTALL_FLEET" = "yes" ]; then
    if [ "$FLEET_MODE" = "client" ]; then
      echo "    Fleet Monitor:       Connect to ${FLEET_SERVER_URL}"
    else
      echo "    Fleet Monitor:       New server (${FLEET_MODE} mode)"
    fi
  else
    echo "    Fleet Monitor:       skip"
  fi
fi
echo ""

if [ "$MODE" = "non-interactive" ]; then
  echo "Proceeding with installation (Non-interactive mode)..."
elif [ "$UPGRADE_HYDRATED" = "true" ]; then
  # User already chose Upgrade at the three-way prompt — don't re-confirm.
  echo "Proceeding with upgrade (refreshing existing installation)..."
elif [ "$INSTALL_PROFILE" = "cockpit" ]; then
  echo "Proceeding with cockpit installation..."
else
  read -rp "Proceed with installation? (yes/no): " confirm

  if [ "$confirm" != "yes" ]; then
    echo "Setup cancelled."
    exit 0
  fi
fi

# In dry-run mode, stop here: user has seen the configuration summary and
# any interactive prompts. Skipping installer invocations keeps the filesystem
# untouched (no venv, no team dirs, no kanban boards, no zshrc edits).
if [ "$DRY_RUN" = "true" ]; then
  echo ""
  echo -e "${BOLD}Dry-run preview — what Would be installed:${NC}"
  echo "  Framework version: ${VERSION}"
  echo "  Would install framework to: ${INSTALL_DIR}"
  if [ "$INSTALL_PROFILE" = "cockpit" ]; then
    _cockpit_mand_str="$(_cockpit_mandatory_teams_str)"
    if [ -n "$_cockpit_mand_str" ]; then
      echo "  Would install cockpit profile (connect scripts for all teams; full local install for mandatory team(s): ${_cockpit_mand_str})"
    else
      echo "  Would install cockpit profile (connect scripts for all teams)"
    fi
  else
    for _dry_team in "${SELECTED_TEAMS[@]}"; do
      echo "  Would install team: ${_dry_team}"
    done
    [ "$INSTALL_SHELL"  = "yes" ] && echo "  Would install shell environment (zshrc integration)"
    [ "$INSTALL_CLAUDE" = "yes" ] && echo "  Would install Claude Code config (agents, skills, personas)"
    [ "$INSTALL_KANBAN" = "yes" ] && echo "  Would install LCARS kanban boards and UI"
    if [ "$INSTALL_FLEET" = "yes" ]; then
      if [ "$FLEET_MODE" = "client" ]; then
        echo "  Would install Fleet Monitor (client → ${FLEET_SERVER_URL})"
      else
        echo "  Would install Fleet Monitor (${FLEET_MODE} mode)"
      fi
    fi
  fi
  echo ""
  echo -e "${YELLOW}DRY RUN COMPLETE — no installation performed.${NC}"
  echo -e "${YELLOW}Re-run without --dry-run to install the above configuration.${NC}"
  exit 0
fi

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Beginning Installation...${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
echo ""

INSTALL_ERRORS=0

# -----------------------------------------------------------------------
# Copy base framework files
# -----------------------------------------------------------------------
echo -e "${BOLD}Copying framework files...${NC}"
mkdir -p "${INSTALL_DIR}/share"
mkdir -p "${INSTALL_DIR}/docs"
mkdir -p "${INSTALL_DIR}/teams"

[ -d "${AITEAMFORGE_HOME}/share/templates" ] && cp -r "${AITEAMFORGE_HOME}/share/templates" "${INSTALL_DIR}/templates" 2>/dev/null && echo -e "${GREEN}✓${NC} Templates"
[ -d "${AITEAMFORGE_HOME}/docs" ] && cp -r "${AITEAMFORGE_HOME}/docs"/* "${INSTALL_DIR}/docs/" 2>/dev/null && echo -e "${GREEN}✓${NC} Documentation"
[ -d "${AITEAMFORGE_HOME}/share/teams" ] && cp -r "${AITEAMFORGE_HOME}/share/teams"/* "${INSTALL_DIR}/teams/" 2>/dev/null && echo -e "${GREEN}✓${NC} Team configurations"

# Copy scripts (window manager, agent panel display, helpers)
if [ -d "${AITEAMFORGE_HOME}/share/scripts" ]; then
  mkdir -p "${INSTALL_DIR}/scripts"
  find "${AITEAMFORGE_HOME}/share/scripts" -maxdepth 1 -type f -exec cp {} "${INSTALL_DIR}/scripts/" \; 2>/dev/null
  chmod +x "${INSTALL_DIR}/scripts/"*.sh "${INSTALL_DIR}/scripts/"*.py 2>/dev/null
  # Also copy window manager to root for backward compat with startup templates
  cp "${INSTALL_DIR}/scripts/iterm2_window_manager.py" "${INSTALL_DIR}/iterm2_window_manager.py" 2>/dev/null
  echo -e "${GREEN}✓${NC} Scripts (window manager, agent panel, helpers)"
fi

# Python deps (iterm2, pyzipper, etc.) now live in the tap-owned venv managed by
# the Formula post_install. The per-user ~/aiteamforge/.venv is no longer created here.
# Run: brew reinstall aiteamforge  — to provision or refresh the tap-owned venv.

# Create LCARS Web profile in iTerm2 (before iTerm2 is started with team scripts)
# This profile uses iTerm2's built-in browser mode for inline kanban display.
# Must be created before the user launches team startup scripts.
#
# IMPORTANT: Source the script directly from the tap (AITEAMFORGE_HOME) rather
# than INSTALL_DIR/scripts/. The installers that populate INSTALL_DIR/scripts/
# run later in this file (install-kanban.sh, install-fleet-monitor.sh), and
# Fleet Monitor is optional — so relying on INSTALL_DIR caused the profile to
# be silently skipped on fresh installs. The tap copy is always present.
if [ -d "/Applications/iTerm.app" ]; then
  # --------------------------------------------------------------------
  # iTerm2 Browser Plugin — prerequisite for the LCARS inline tab
  # --------------------------------------------------------------------
  # iTerm2 3.5+ ships browser mode as a separately-downloaded bundle
  # (iTermBrowserPlugin.app, bundle id com.googlecode.iterm2.iTermBrowserPlugin).
  # Without it, the LCARS Web profile appears in the Profiles menu but
  # browser-type tabs silently fail to render pages, and the Dynamic
  # Profile loader drops browser-type profiles tagged internally as
  # 'Profile Type (Phony)'. Detect-and-install here so fresh installs
  # get a fully working LCARS tab without the user having to chase
  # down a popup the first time iTerm2 tries to open a browser tab.
  _plugin_bundle_id="com.googlecode.iterm2.iTermBrowserPlugin"
  _plugin_app=""
  if command -v mdfind >/dev/null 2>&1; then
    _plugin_app=$(mdfind "kMDItemCFBundleIdentifier == '${_plugin_bundle_id}'" 2>/dev/null | head -1)
  fi
  if [ -z "$_plugin_app" ]; then
    for _candidate in "/Applications/iTermBrowserPlugin.app" "$HOME/Applications/iTermBrowserPlugin.app"; do
      [ -d "$_candidate" ] && _plugin_app="$_candidate" && break
    done
  fi

  if [ -n "$_plugin_app" ]; then
    echo -e "${GREEN}✓${NC} iTerm2 Browser Plugin (already installed: $_plugin_app)"
  else
    echo -e "${BOLD}Downloading iTerm2 Browser Plugin...${NC}"
    _plugin_url="https://iterm2.com/downloads/browser-plugin/iTermBrowserPlugin-1.0.zip"
    _plugin_tmpdir=$(mktemp -d -t iterm2-browser-plugin.XXXXXX)
    _plugin_zip="$_plugin_tmpdir/iTermBrowserPlugin.zip"
    _plugin_installed=no

    if curl -fsSL --connect-timeout 15 -o "$_plugin_zip" "$_plugin_url"; then
      # ditto is macOS-native and handles resource forks / xattrs
      # correctly, unlike unzip, when extracting .app bundles.
      if ditto -x -k "$_plugin_zip" "$_plugin_tmpdir" 2>/dev/null && \
         [ -d "$_plugin_tmpdir/iTermBrowserPlugin.app" ]; then
        # Prefer /Applications if writable, otherwise ~/Applications.
        # iTerm2 locates the plugin via LaunchServices (mdfind), so any
        # indexed Applications directory works.
        _target_dir=""
        if [ -w "/Applications" ]; then
          _target_dir="/Applications"
        else
          mkdir -p "$HOME/Applications"
          _target_dir="$HOME/Applications"
        fi
        _target="$_target_dir/iTermBrowserPlugin.app"
        # Remove any stale prior install before copying
        rm -rf "$_target" 2>/dev/null || true
        if cp -R "$_plugin_tmpdir/iTermBrowserPlugin.app" "$_target" 2>/dev/null; then
          # Strip the Gatekeeper quarantine bit or macOS will block
          # launch with "can't be opened because Apple cannot check".
          xattr -dr com.apple.quarantine "$_target" 2>/dev/null || true
          _plugin_installed=yes
          echo -e "${GREEN}✓${NC} iTerm2 Browser Plugin installed at $_target"
        else
          echo -e "${YELLOW}⚠${NC} Could not copy plugin to $_target_dir (permissions?)"
        fi
      else
        echo -e "${YELLOW}⚠${NC} Downloaded plugin zip was malformed or missing .app"
      fi
    else
      echo -e "${YELLOW}⚠${NC} Could not download iTerm2 Browser Plugin from $_plugin_url"
    fi

    rm -rf "$_plugin_tmpdir" 2>/dev/null || true

    if [ "$_plugin_installed" != "yes" ]; then
      echo -e "   ${YELLOW}Manual fallback:${NC} download from https://iterm2.com/browser-plugin.html"
      echo -e "   and drag iTermBrowserPlugin.app into /Applications."
    fi
  fi

  # --------------------------------------------------------------------
  # LCARS Web Dynamic Profile (depends on Browser Plugin being present)
  # --------------------------------------------------------------------
  LCARS_PROFILE_SCRIPT="${AITEAMFORGE_HOME}/share/scripts/create-lcars-profile.py"
  if [ -f "$LCARS_PROFILE_SCRIPT" ]; then
    if "${AITEAMFORGE_PYTHON:-python3}" "$LCARS_PROFILE_SCRIPT" "http://localhost:8080" >/dev/null 2>&1; then
      echo -e "${GREEN}✓${NC} LCARS Web profile (iTerm2 inline browser)"
    else
      echo -e "${YELLOW}⚠${NC} Could not create LCARS Web profile"
    fi
  else
    echo -e "${YELLOW}⚠${NC} LCARS profile script missing from tap (skipping)"
  fi

  # Set iTerm2 Default profile font to FiraCodeNFM-Reg 10.
  # Team agent tabs are created without an explicit --profile, so they inherit
  # the Default profile. This call requires iTerm2 running with Python API;
  # it is non-fatal if unavailable (user can re-run setup later).
  WINDOW_MGR="${AITEAMFORGE_HOME}/share/scripts/iterm2_window_manager.py"
  if [ -f "$WINDOW_MGR" ] && [ -d "/Applications/iTerm.app" ]; then
    if "${AITEAMFORGE_PYTHON:-python3}" "$WINDOW_MGR" -a set-default-font -f "FiraCodeNFM-Reg 10" >/dev/null 2>&1; then
      echo -e "${GREEN}✓${NC} iTerm2 Default profile font (FiraCodeNFM-Reg 10)"
    else
      echo -e "${YELLOW}⚠${NC} Could not set iTerm2 Default profile font (iTerm2 not running or Python API unavailable)"
      echo -e "   Re-run: ${CYAN}\"${AITEAMFORGE_PYTHON:-python3}\" $WINDOW_MGR -a set-default-font${NC}"
    fi
  fi
fi

# Copy skills (Claude Code slash commands)
if [ -d "${AITEAMFORGE_HOME}/share/skills" ]; then
  mkdir -p "${INSTALL_DIR}/skills"
  cp -r "${AITEAMFORGE_HOME}/share/skills"/* "${INSTALL_DIR}/skills/" 2>/dev/null && echo -e "${GREEN}✓${NC} Skills (Kanban Manager, git-worktree, Project Planner)"
fi

# Copy agent personas, avatars, and terminal logos for selected teams
# Also populate the flat avatars/ pool so agent-panel-display.sh can find them
# without needing fleet-monitor installed.
#
# XACA-1070 / PR #865 round 2, carve-out 1 of 4: this loop's comment used to
# read "Skipped in cockpit mode — no team working dirs, no personas needed
# locally", and that was true BEFORE this ticket: SELECTED_TEAMS was
# unconditionally emptied for cockpit (Step 2 above) and nothing ever
# refilled it, so this loop always iterated zero teams on a cockpit box.
# That is no longer the whole story — _atf_apply_mandatory_teams (call site
# 2, above) now force-appends any mandatory team id into SELECTED_TEAMS on
# EVERY cockpit install, so by the time control reaches here SELECTED_TEAMS
# already contains that team, and this loop — UNCHANGED — correctly copies
# its personas as a side effect of that invariant alone. The EPIC-0057
# decision behind this ticket (full setup for a mandatory team, cockpit
# included) requires exactly this: a mandatory team's crew needs real
# persona files on disk to populate its agent-panel avatars and terminal
# banners, the same as any full-mode team.
#
# The per-iteration guard just inside the loop is the SAME belt-and-
# suspenders check the team-install loop further down already applies (see
# that loop's own header comment for the full rationale) — not because
# SELECTED_TEAMS is expected to ever carry a non-mandatory id on cockpit
# today, but so a future regression upstream can never leak a
# non-mandatory team's personas onto a cockpit box through this loop
# specifically. `atf_is_mandatory_team` fails closed (returns 1) on an
# unreadable registry or a missing lib, matching every other mandatory-
# team call site in this file.
_personas_copied=0
_logos_copied=0
mkdir -p "${INSTALL_DIR}/avatars"
for team_id in "${SELECTED_TEAMS[@]}"; do
  [ -z "$team_id" ] && continue
  if [ "$INSTALL_PROFILE" = "cockpit" ] && ! { command -v atf_is_mandatory_team >/dev/null 2>&1 && atf_is_mandatory_team "$team_id"; }; then
    continue
  fi
  # Agent personas and avatar thumbnails
  if [ -d "${AITEAMFORGE_HOME}/share/personas/${team_id}" ]; then
    mkdir -p "${INSTALL_DIR}/${team_id}/personas/agents"
    mkdir -p "${INSTALL_DIR}/${team_id}/personas/avatars"
    cp "${AITEAMFORGE_HOME}/share/personas/${team_id}/agents/"*.md "${INSTALL_DIR}/${team_id}/personas/agents/" 2>/dev/null
    cp "${AITEAMFORGE_HOME}/share/personas/${team_id}/avatars/"*.png "${INSTALL_DIR}/${team_id}/personas/avatars/" 2>/dev/null
    # Also copy into flat avatars/ pool for agent-panel-display.sh path resolution
    cp "${AITEAMFORGE_HOME}/share/personas/${team_id}/avatars/"*.png "${INSTALL_DIR}/avatars/" 2>/dev/null
    _personas_copied=$((_personas_copied + 1))
  fi
  # Terminal logos (for iTerm2 profiles)
  if [ -d "${AITEAMFORGE_HOME}/share/terminals/${team_id}/logos" ]; then
    mkdir -p "${INSTALL_DIR}/${team_id}/terminals/logos"
    cp "${AITEAMFORGE_HOME}/share/terminals/${team_id}/logos/"*.png "${INSTALL_DIR}/${team_id}/terminals/logos/" 2>/dev/null
    # Also copy logos into flat avatars/ pool
    cp "${AITEAMFORGE_HOME}/share/terminals/${team_id}/logos/"*.png "${INSTALL_DIR}/avatars/" 2>/dev/null
    _logos_copied=$((_logos_copied + 1))
  fi
done
[ $_personas_copied -gt 0 ] && echo -e "${GREEN}✓${NC} Agent personas and avatars (${_personas_copied} teams)"
[ $_logos_copied -gt 0 ] && echo -e "${GREEN}✓${NC} Terminal logos (${_logos_copied} teams)"
echo ""

# -----------------------------------------------------------------------
# Install selected teams.
#
# XACA-1070 (PR #865 round 2, BLOCKING): this block used to be wrapped
# whole in `if [ "$INSTALL_PROFILE" != "cockpit" ]`, so install-team.sh
# NEVER ran on a cockpit install -- for anyone, including a mandatory team
# that call site 2 of _atf_apply_mandatory_teams (above, ~line 1069) had
# already force-appended into SELECTED_TEAMS. The config write further
# down (WRITE CONFIGURATION FILE) does NOT gate on profile, so
# .aiteamforge-config ended up listing a mandatory team that had no board
# on disk at all. atf_team_provisioned() requires BOTH config-membership
# AND a real on-disk board (mandatory-teams.sh's atf_team_has_board()), so
# it returned false and `aiteamforge doctor` reported a permanent FAULT on
# every cockpit box, forever -- no upgrade run could ever heal it, because
# the wizard is what runs once at install time.
#
# WHY a mandatory team gets provisioned here even though cockpit
# deliberately skips "teams, kanban, LCARS server, personas, shell
# aliases" everywhere else (see the Step 2/Step 3 cockpit branches above,
# and the LaunchAgents/shell-integration guards further down -- none of
# those change): EPIC-0057 requires a mandatory team on every machine
# AITeamForge is installed on, full stop, and a mandatory team's purpose
# is LOCAL HOST RECOVERY (XACA-1070/1071's kb-spacedock) -- it needs a
# real board + CLI on THIS machine, not a web UI. Cockpit's whole premise
# ("connect to teams hosted elsewhere, install nothing locally") does not
# apply to the one team whose job is recovering THIS host when nothing
# elsewhere is reachable. This does NOT flip INSTALL_KANBAN back on, does
# NOT load any LCARS LaunchAgent, and does NOT resurrect interactive team
# selection for cockpit -- every other cockpit skip in this file is
# unchanged; only this one team, on this one path, is exempted.
#
# THE FIX: the block no longer skips cockpit outright. Because
# SELECTED_TEAMS is emptied for cockpit (Step 2, ~line 884-885) and from
# then on is repopulated ONLY by _atf_apply_mandatory_teams, SELECTED_TEAMS
# already contains ONLY mandatory team ids on a cockpit box by construction
# -- but the per-iteration guard just inside the loop below is a second,
# independent check rather than leaning on that alone. Even if some future
# change ever put a non-mandatory id into SELECTED_TEAMS on a cockpit
# install, this loop would still refuse to install-team.sh it. The loop
# BODY itself (work-dir resolution, --project/--client flags,
# install-team.sh invocation, error handling) is untouched and unduplicated
# -- the same code now simply also runs, per-team-conditionally, for
# cockpit. Two independent components silently disagreeing about what
# "provisioned" means is this ticket's own worst defect (see
# mandatory-teams.sh's atf_team_has_board() header comment,
# XACA-1070-017) -- sharing this loop body rather than cloning a
# mandatory-only copy of it is what keeps that from happening again here.
# -----------------------------------------------------------------------

echo -e "${BOLD}Installing teams...${NC}"
echo ""

for team_id in "${SELECTED_TEAMS[@]}"; do
  [ -z "$team_id" ] && continue  # skip empty entries from removed teams

  # XACA-1070 / PR #865 round 2: on a cockpit install, SELECTED_TEAMS
  # should only ever contain mandatory teams (see the block header comment
  # above) -- this is the belt-and-suspenders per-iteration enforcement of
  # that, so a future regression upstream can never install a non-mandatory
  # team locally on a cockpit box through this loop. `atf_is_mandatory_team`
  # fails closed (returns 1) on an unreadable registry or a missing lib, so
  # an unreadable registry on a cockpit box means "install nothing here"
  # rather than "install everything" -- consistent with this file's other
  # mandatory-team call sites, which all fail closed on the enforcement
  # question rather than aborting the wizard over it.
  if [ "$INSTALL_PROFILE" = "cockpit" ] && ! { command -v atf_is_mandatory_team >/dev/null 2>&1 && atf_is_mandatory_team "$team_id"; }; then
    continue
  fi

  _wdir_var="_WORKDIR_${team_id}"
  _proj_var="_PROJECT_${team_id}"
  _client_var="_CLIENT_${team_id}"
  team_work_dir="${!_wdir_var:-${INSTALL_DIR}/${team_id}}"
  team_project="${!_proj_var:-}"
  team_client="${!_client_var:-}"
  # XACA-0643: forward the project/client captured during team selection to
  # install-team.sh. Without --project, parameterized templates (finance,
  # legal, medical, freelance) silently fall back to TEAM_DEFAULT_PROJECT and
  # build the WRONG instance board (e.g. legal-default instead of the requested
  # legal-coparenting). The startup guard then sees no usable board, tries to
  # provision via kb-init-team, and collides on the already-registered team
  # code. Append the flags ONLY when set — install-team.sh REJECTS
  # --project/--client for non-parameterized templates (TEAM_HAS_PROJECTS=false).
  _team_param_flags=()
  [ -n "$team_project" ] && _team_param_flags+=(--project "$team_project")
  [ -n "$team_client" ]  && _team_param_flags+=(--client "$team_client")
  echo -e "${BLUE}  Installing team: ${team_id} → ${team_work_dir}${NC}"
  if [ -x "${INSTALLERS_DIR}/install-team.sh" ]; then
    AITEAMFORGE_DIR="${INSTALL_DIR}" TEAM_WORKING_DIR="${team_work_dir}" bash "${INSTALLERS_DIR}/install-team.sh" "$team_id" --install-dir "${INSTALL_DIR}" ${_team_param_flags[@]+"${_team_param_flags[@]}"} 2>&1 | sed 's/^/    /' || {
      echo -e "    ${RED}✗ Team ${team_id} had errors (continuing)${NC}"
      INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    }
  else
    # Fallback: create basic team directory structure
    mkdir -p "${team_work_dir}"
    echo -e "    ${GREEN}✓${NC} Created ${team_work_dir}/ directory"
  fi
  echo ""
done

# -----------------------------------------------------------------------
# Detect and regenerate stale per-agent startup scripts
# -----------------------------------------------------------------------
# Per-agent startup scripts are generated from templates at install time.
# If the tap was upgraded (new template features like tmux hostname), the
# existing scripts become stale. This block scans ALL installed teams
# (not just SELECTED_TEAMS) and regenerates scripts whose embedded
# AITEAMFORGE_GENERATED_VERSION doesn't match the current tap version.
_CURRENT_TAP_VERSION="$(cat "${AITEAMFORGE_HOME}/VERSION" 2>/dev/null || cat "${INSTALL_DIR}/../homebrew-tap/VERSION" 2>/dev/null || echo "unknown")"

_stale_teams=()
for _team_dir in "${INSTALL_DIR}"/*/scripts; do
  [ -d "$_team_dir" ] || continue
  _team_name="$(basename "$(dirname "$_team_dir")")"
  # Check any per-agent startup script for the version marker
  _any_script="$(find "$_team_dir" -name "${_team_name}-*-startup.sh" -maxdepth 1 2>/dev/null | head -1)"
  if [ -n "$_any_script" ]; then
    _script_version="$(grep '^# AITEAMFORGE_GENERATED_VERSION=' "$_any_script" 2>/dev/null | head -1 | cut -d= -f2)"
    if [ "$_script_version" != "$_CURRENT_TAP_VERSION" ]; then
      _stale_teams+=("$_team_name")
    fi
  fi
done

if [ ${#_stale_teams[@]} -gt 0 ]; then
  echo -e "${YELLOW}⚠${NC} Stale startup scripts detected for: ${_stale_teams[*]}"
  echo -e "  Regenerating from current templates (v${_CURRENT_TAP_VERSION})..."
  for _stale_team in "${_stale_teams[@]}"; do
    _wdir_var="_WORKDIR_${_stale_team}"
    _stale_wdir="${!_wdir_var:-${INSTALL_DIR}/${_stale_team}}"
    # XACA-0845: forward project/client here too. XACA-0643 fixed only the
    # SELECTED_TEAMS install loop above; this regeneration pass still called
    # install-team.sh bare, so a parameterised team silently fell back to
    # TEAM_DEFAULT_PROJECT and regenerated the WRONG instance (legal-default
    # rather than the live legal-coparenting) — one of the ways stray
    # "-default" instances got manufactured. Flags are appended ONLY when set,
    # because install-team.sh REJECTS them for TEAM_HAS_PROJECTS=false teams.
    _proj_var="_PROJECT_${_stale_team}"
    _client_var="_CLIENT_${_stale_team}"
    _stale_param_flags=()
    [ -n "${!_proj_var:-}" ]   && _stale_param_flags+=(--project "${!_proj_var}")
    [ -n "${!_client_var:-}" ] && _stale_param_flags+=(--client "${!_client_var}")
    if [ -x "${INSTALLERS_DIR}/install-team.sh" ]; then
      echo -e "  ${CYAN}Regenerating: ${_stale_team}${NC}"
      AITEAMFORGE_DIR="${INSTALL_DIR}" TEAM_WORKING_DIR="${_stale_wdir}" \
        bash "${INSTALLERS_DIR}/install-team.sh" "$_stale_team" --install-dir "${INSTALL_DIR}" ${_stale_param_flags[@]+"${_stale_param_flags[@]}"} 2>&1 | sed 's/^/    /' || true
    fi
  done
  echo ""
fi

# XACA-1070 / PR #865 round 2: this block used to close an
# `if [ "$INSTALL_PROFILE" != "cockpit" ]` here (removed — see the "Install
# selected teams" header comment above). No cockpit guard is needed for the
# stale-script regen pass either: it scans directories that already exist
# under ${INSTALL_DIR}, and on a cockpit box the only team directory that
# can exist is the mandatory team's own (created by the loop just above) —
# there is nothing else on disk for it to find.

# -----------------------------------------------------------------------
# Cockpit mandatory-team LCARS instance (XACA-1070 / PR #865 round 2,
# carve-out 3 of 4).
#
# THE USER DECISION THIS SERVES: EPIC-0057 requires a mandatory team's
# FULL setup on every AITeamForge install, cockpit included — "the
# mandatory team's LCARS instance and its tabs must come up on a cockpit
# box" is a settled requirement of this ticket's round-2 fix, not a
# reinterpretation of cockpit mode generally. Cockpit's whole premise
# ("connect to teams hosted elsewhere, install nothing locally") does not
# apply to the one team whose purpose is recovering THIS host when nothing
# elsewhere is reachable (XACA-1070/1071's kb-spacedock).
#
# WHAT WAS INVESTIGATED, so this reads as a deliberate narrow carve-out
# and not a partial fix someone forgot to finish:
#
#   * The mandatory team's BOARD needs none of this — see the INSTALL_KANBAN
#     comment in Step 3 above. install-team.sh (already invoked above,
#     unconditionally for a mandatory team on cockpit) writes the
#     *-board.json itself with zero reference to INSTALL_KANBAN anywhere in
#     that installer. INSTALL_KANBAN stays "no" on cockpit, unchanged.
#
#   * The mandatory team's per-agent startup scripts (generated by
#     install-team.sh's generate_per_agent_startup_scripts, also already
#     unconditional) and its top-level <team>-startup.sh DO need one real
#     thing that only install_kanban_system's install_lcars_ui provides:
#     $AITEAMFORGE_DIR/lcars-ui/server.py. share/scripts/lcars-launch-
#     helpers.sh — which defines start_lcars_server, called from every
#     <team>-startup.sh template (e.g. share/scripts/teams/finance-startup.sh)
#     — is already copied to $AITEAMFORGE_DIR/scripts/ on EVERY profile,
#     cockpit included, by the unconditional "Copy scripts" block earlier
#     in this file. But the server it launches lives under lcars-ui/,
#     which is written ONLY by install_lcars_ui(), normally reached
#     exclusively through install_kanban_system() (gated on
#     INSTALL_KANBAN="yes"). On cockpit that function never runs, so
#     $AITEAMFORGE_DIR/lcars-ui never exists and start_lcars_server has
#     nothing to launch — the "instance" half of "LCARS instance and its
#     tabs" would otherwise be permanently missing for a mandatory team on
#     a cockpit box.
#
#   * The "tabs" half needs NO code here: the iTerm2 "LCARS Web" dynamic
#     profile is created unconditionally for every profile (see the
#     "Create LCARS Web profile in iTerm2" block earlier in this file,
#     which carries no INSTALL_PROFILE guard at all), and the per-agent
#     tmux tabs are generated by install-team.sh itself. Both already
#     exist on cockpit before this block runs; only the server they point
#     at was the gap.
#
# THE FIX — call ONLY install_lcars_ui + configure_lcars_port directly,
# bypassing install_kanban_system() entirely, so nothing else that
# function does (backup system, port-management template copy, and —
# decisively — every install_*_launchagent call) runs on cockpit:
#
#   * Both functions are pure static-file writers under $AITEAMFORGE_DIR
#     (copy lcars-ui/, write lcars-target.js + .lcars-port). No process is
#     started, no LaunchAgent is touched, and no other team's data is read
#     or written. install_lcars_ui's own "LCARS UI not found (skipping)"
#     guard makes this a clean no-op on a tap checkout that lacks
#     share/lcars-ui, matching every other non-fatal installer call in
#     this file.
#
#   * LaunchAgents are DELIBERATELY excluded, including
#     install_lcars_health_launchagent (auto-restart on crash). The "Load
#     LaunchAgents" block further below still reads "Skipped in cockpit
#     mode — no LaunchAgents are installed (no LCARS server, no kanban
#     backup, no fleet reporter)", and that remains TRUE for cockpit as a
#     whole after this change — this block does not create any plist for
#     launchctl to (not) load. This also keeps
#     libexec/lib/launchagents.sh's _xaca0734_launchagents_applicable()
#     (consulted by aiteamforge-upgrade.sh's update_launchagents())
#     correct as-is: that gate decides "mandatory LaunchAgents on this
#     install should stay absent" from .install-profile / .aiteamforge-
#     config's lcars_kanban flag — both untouched by this block — never
#     from whether lcars-ui/ happens to exist on disk. Writing static
#     LCARS UI files here therefore cannot flip that gate and cannot risk
#     materializing a LaunchAgent pointed at a working_dir that does not
#     otherwise exist on this box (the exact "vandalism" scenario that
#     gate's own header comment in aiteamforge-upgrade.sh warns about). A
#     crashed LCARS server on a cockpit box is therefore not auto-
#     restarted — same as every other LaunchAgent-backed service on
#     cockpit today. That is a deliberately narrower guarantee than "must
#     come up" might suggest, but it matches the standard a full install
#     is already held to by this same wizard, which never starts any
#     process itself either (see the team-install loop above) — it only
#     ever makes starting one possible.
#
#   * Narrowed to cockpit + at least one team actually selected, i.e. at
#     least one mandatory team was force-appended (see the "Install
#     selected teams" header comment for why SELECTED_TEAMS holds ONLY
#     mandatory ids on cockpit by construction). On a cockpit box with
#     zero mandatory teams declared (today's real state — spacedock has
#     not shipped, XACA-1070-001), SELECTED_TEAMS is empty and this block
#     is a complete no-op: no lcars-ui/ directory is created at all,
#     matching cockpit's existing behavior for every box with no
#     mandatory team.
# -----------------------------------------------------------------------
_cockpit_has_mandatory_team="false"
for _clt in "${SELECTED_TEAMS[@]}"; do
  [ -n "$_clt" ] && _cockpit_has_mandatory_team="true" && break
done
if [ "$INSTALL_PROFILE" = "cockpit" ] && [ "$_cockpit_has_mandatory_team" = "true" ]; then
  echo -e "${BOLD}Installing LCARS instance for mandatory team(s) (cockpit mode)...${NC}"
  if [ -f "${INSTALLERS_DIR}/install-kanban.sh" ]; then
    (
      export AITEAMFORGE_DIR="${INSTALL_DIR}"
      export INSTALL_ROOT="${AITEAMFORGE_HOME}"
      source "${AITEAMFORGE_HOME}/libexec/lib/common.sh"
      source "${INSTALLERS_DIR}/install-kanban.sh"
      install_lcars_ui
      configure_lcars_port "$DEFAULT_LCARS_PORT"
    ) 2>&1 | sed 's/^/  /' || {
      echo -e "  ${YELLOW}⚠ LCARS instance setup had errors (continuing)${NC}"
      INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    }
  else
    echo -e "  ${YELLOW}⚠ Kanban installer not found — LCARS instance skipped${NC}"
  fi
  echo ""
fi  # end: cockpit mandatory-team LCARS instance (XACA-1070, PR #865 round 2)

# -----------------------------------------------------------------------
# Full-mode post-selected-teams pass (XACA-0160, ported from libexec
# stage_installation during XACA-0173 consolidation).
# After selected teams are fully installed, render connect scripts for
# every UNSELECTED team so users can still reach those teams remotely.
# Cockpit mode handles all teams via the dedicated pass below, so this
# block only runs when INSTALL_PROFILE = full.
# -----------------------------------------------------------------------
if [ "$INSTALL_PROFILE" = "full" ]; then
  _post_teams_dir="${AITEAMFORGE_HOME}/share/teams"
  if [ -d "$_post_teams_dir" ] && [ -x "${INSTALLERS_DIR}/install-team.sh" ]; then
    _post_rendered=0
    _post_failed=0
    for _conf in "$_post_teams_dir"/*.conf; do
      [ -f "$_conf" ] || continue
      _pt="$(basename "$_conf" .conf)"
      # Skip teams already fully installed in the SELECTED_TEAMS loop above.
      _already_selected="false"
      for _sel in "${SELECTED_TEAMS[@]}"; do
        if [ "$_sel" = "$_pt" ]; then
          _already_selected="true"
          break
        fi
      done
      [ "$_already_selected" = "true" ] && continue

      if [ "$_post_rendered" -eq 0 ] && [ "$_post_failed" -eq 0 ]; then
        echo -e "${BOLD}Rendering connect scripts for unselected teams...${NC}"
        echo ""
      fi
      # XACA-0845: forward project/client when the wizard captured them. This
      # pass renders connect scripts for UNSELECTED teams, so usually nothing is
      # set and the conf default is genuinely the best available guess — but
      # when a project IS known, defaulting anyway writes a connect script for
      # an instance that does not exist ("legal-default") while the real one
      # goes without. Append only when set: install-team.sh rejects these flags
      # for TEAM_HAS_PROJECTS=false teams.
      _post_proj_var="_PROJECT_${_pt}"
      _post_client_var="_CLIENT_${_pt}"
      _post_param_flags=()
      [ -n "${!_post_proj_var:-}" ]   && _post_param_flags+=(--project "${!_post_proj_var}")
      [ -n "${!_post_client_var:-}" ] && _post_param_flags+=(--client "${!_post_client_var}")
      if AITEAMFORGE_DIR="${INSTALL_DIR}" bash "${INSTALLERS_DIR}/install-team.sh" \
          "$_pt" --connect-only --install-dir "${INSTALL_DIR}" ${_post_param_flags[@]+"${_post_param_flags[@]}"} 2>&1 | sed 's/^/  /'; then
        _post_rendered=$((_post_rendered + 1))
      else
        _post_failed=$((_post_failed + 1))
        echo -e "  ${YELLOW}⚠ ${_pt}: connect script render had errors (continuing)${NC}"
      fi
    done
    if [ "$_post_rendered" -gt 0 ] || [ "$_post_failed" -gt 0 ]; then
      echo ""
      if [ "$_post_failed" -gt 0 ]; then
        echo -e "${GREEN}✓${NC} Connect scripts rendered for ${_post_rendered} unselected team(s); ${YELLOW}${_post_failed} failed${NC}"
      else
        echo -e "${GREEN}✓${NC} Connect scripts rendered for ${_post_rendered} unselected team(s)"
      fi
      echo ""
    fi
  fi
fi

# -----------------------------------------------------------------------
# Cockpit connect-scripts pass
# Render connect + disconnect scripts for EVERY team when in cockpit mode.
# In full mode, install-team.sh handles connect scripts for selected teams
# and the post-selected-teams pass above handles the rest.
#
# XACA-1070 / PR #865 round 2: verified this pass needs NO mandatory-team
# carve-out. It iterates every "$_cockpit_teams_dir"/*.conf, which includes
# a mandatory team's own <team>.conf — the resulting <team>-connect.sh /
# <team>-disconnect.sh filenames are distinct from the <team>-startup.sh /
# ${INSTANCE_ID}-startup.sh files the mandatory-team install loop above
# already wrote, so this pass cannot clobber that team's real local
# install. Change nothing here.
# -----------------------------------------------------------------------
if [ "$INSTALL_PROFILE" = "cockpit" ]; then
  echo -e "${BOLD}Rendering connect scripts for all teams (cockpit mode)...${NC}"
  echo ""
  _cockpit_teams_dir="${AITEAMFORGE_HOME}/share/teams"
  _cockpit_rendered=0
  _cockpit_failed=0
  if [ -d "$_cockpit_teams_dir" ] && [ -x "${INSTALLERS_DIR}/install-team.sh" ]; then
    for _conf in "$_cockpit_teams_dir"/*.conf; do
      [ -f "$_conf" ] || continue
      _ct="$(basename "$_conf" .conf)"
      # XACA-0845: forward project/client when known (same rationale as the
      # post-selected pass above). Cockpit mode installs no teams, so these are
      # normally unset and the conf default stands — but if the wizard did
      # capture a project, honour it instead of rendering a phantom instance.
      _cockpit_proj_var="_PROJECT_${_ct}"
      _cockpit_client_var="_CLIENT_${_ct}"
      _cockpit_param_flags=()
      [ -n "${!_cockpit_proj_var:-}" ]   && _cockpit_param_flags+=(--project "${!_cockpit_proj_var}")
      [ -n "${!_cockpit_client_var:-}" ] && _cockpit_param_flags+=(--client "${!_cockpit_client_var}")
      if AITEAMFORGE_DIR="${INSTALL_DIR}" bash "${INSTALLERS_DIR}/install-team.sh" \
          "$_ct" --connect-only --install-dir "${INSTALL_DIR}" ${_cockpit_param_flags[@]+"${_cockpit_param_flags[@]}"} 2>&1 | sed 's/^/  /'; then
        _cockpit_rendered=$((_cockpit_rendered + 1))
      else
        _cockpit_failed=$((_cockpit_failed + 1))
        echo -e "  ${YELLOW}⚠ ${_ct}: connect script render had errors (continuing)${NC}"
      fi
    done
    echo ""
    if [ "$_cockpit_failed" -gt 0 ]; then
      echo -e "${GREEN}✓${NC} Connect scripts rendered for ${_cockpit_rendered} team(s); ${YELLOW}${_cockpit_failed} failed${NC}"
    else
      echo -e "${GREEN}✓${NC} Connect scripts rendered for ${_cockpit_rendered} team(s)"
    fi
  else
    echo -e "${YELLOW}⚠ No team configs found or install-team.sh missing — skipping connect scripts${NC}"
  fi
  echo ""
fi

# -----------------------------------------------------------------------
# Install Shell Environment
# -----------------------------------------------------------------------
if [ "$INSTALL_SHELL" = "yes" ]; then
  echo -e "${BOLD}Installing Shell Environment...${NC}"
  if [ -x "${INSTALLERS_DIR}/install-shell.sh" ]; then
    # Source installer so its functions are available, then call main function
    (
      export AITEAMFORGE_DIR="${INSTALL_DIR}"
      export INSTALL_ROOT="${AITEAMFORGE_HOME}"
      # When installing to a non-default location, sandbox the zshrc modification
      if [ "${INSTALL_DIR}" != "${HOME}/aiteamforge" ]; then
        export ZSHRC_TARGET="${INSTALL_DIR}/.zshrc-integration"
      fi
      source "${AITEAMFORGE_HOME}/libexec/lib/common.sh"
      source "${INSTALLERS_DIR}/install-shell.sh"
      install_shell_environment
    ) 2>&1 | sed 's/^/  /' || {
      echo -e "  ${RED}✗ Shell environment had errors${NC}"
      INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    }
  else
    echo -e "  ${YELLOW}⚠ Shell installer not found (skipping)${NC}"
  fi
  echo ""
fi

# -----------------------------------------------------------------------
# Install Claude Code Configuration
# -----------------------------------------------------------------------
if [ "$INSTALL_CLAUDE" = "yes" ]; then
  echo -e "${BOLD}Installing Claude Code Configuration...${NC}"
  if [ -x "${INSTALLERS_DIR}/install-claude-config.sh" ]; then
    (
      export AITEAMFORGE_DIR="${INSTALL_DIR}"
      export INSTALL_ROOT="${AITEAMFORGE_HOME}"
      export TEMPLATE_DIR="${AITEAMFORGE_HOME}/share/templates"
      # Sandbox mode: stage configs under INSTALL_DIR instead of modifying real ~/.claude
      # Users can apply staged configs later with: aiteamforge apply-claude-config
      if [ "${INSTALL_DIR}" != "${HOME}/aiteamforge" ]; then
        export CLAUDE_SANDBOX=1
      fi
      bash "${INSTALLERS_DIR}/install-claude-config.sh"
    ) 2>&1 | sed 's/^/  /' || {
      echo -e "  ${RED}✗ Claude config had errors${NC}"
      INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    }
  else
    echo -e "  ${YELLOW}⚠ Claude config installer not found (skipping)${NC}"
  fi
  echo ""
fi

# -----------------------------------------------------------------------
# XACA-1070-002 / PR #865 review, BLOCKING 1: the force-append USED to live
# here, unconditionally, right before the kanban-install block — which was
# itself the bug (see _atf_apply_mandatory_teams' header comment near the
# top of this file). It ran AFTER the working-dir loop, the persona/avatar
# copy, and — the one that mattered — the install-team.sh loop had already
# iterated SELECTED_TEAMS without the mandatory team present. It has been
# moved to two earlier call sites (Step 2, both branches of the
# selection if/elif/else) so every one of those loops sees the mandatory
# team. SELECTED_TEAMS is already correct by the time control reaches here;
# nothing further to do at this point.
# -----------------------------------------------------------------------

# -----------------------------------------------------------------------
# Install LCARS Kanban System
# -----------------------------------------------------------------------
if [ "$INSTALL_KANBAN" = "yes" ]; then
  echo -e "${BOLD}Installing LCARS Kanban System...${NC}"
  if [ -f "${INSTALLERS_DIR}/install-kanban.sh" ]; then
    # Serialize team working dirs as "team:path team:path ..."
    _team_dirs=""
    for _tid in "${SELECTED_TEAMS[@]}"; do
      [ -z "$_tid" ] && continue
      _twvar="_WORKDIR_${_tid}"; _tw="${!_twvar:-${INSTALL_DIR}/${_tid}}"
      _team_dirs="${_team_dirs}${_tid}:${_tw} "
    done
    (
      export AITEAMFORGE_DIR="${INSTALL_DIR}"
      export INSTALL_ROOT="${AITEAMFORGE_HOME}"
      export SELECTED_TEAMS_STR="${SELECTED_TEAMS[*]}"
      export TEAM_WORKING_DIRS_STR="${_team_dirs}"
      # XACA-0470: hand the per-team CR opt-in + shared Atlassian credentials to
      # install-kanban.sh. CR_ENABLED_TEAMS_STR is exported even when empty so the
      # installer records "asked, declined" (prompted=true) and migration won't nag.
      export CR_WIZARD_RAN="${CR_WIZARD_RAN}"
      export CR_ENABLED_TEAMS_STR="${CR_ENABLED_TEAMS[*]}"
      export CR_ALL_SELECTED_TEAMS_STR="${SELECTED_TEAMS[*]}"
      export CR_ATLASSIAN_EMAIL CR_ATLASSIAN_TOKEN CR_CONFLUENCE_SITE CR_SPACE_KEY
      [ "$REFRESH_PROFILES" = "true" ] && export AITEAMFORGE_REFRESH_PROFILES=1
      source "${AITEAMFORGE_HOME}/libexec/lib/common.sh"
      source "${INSTALLERS_DIR}/install-kanban.sh"
      install_kanban_system
    ) 2>&1 | sed 's/^/  /' || {
      echo -e "  ${RED}✗ Kanban system had errors${NC}"
      INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    }
  else
    echo -e "  ${YELLOW}⚠ Kanban installer not found (skipping)${NC}"
  fi
  echo ""
fi

# -----------------------------------------------------------------------
# Install Fleet Monitor
# -----------------------------------------------------------------------
if [ "$INSTALL_FLEET" = "yes" ]; then
  echo -e "${BOLD}Installing Fleet Monitor...${NC}"
  if [ -f "${INSTALLERS_DIR}/install-fleet-monitor.sh" ]; then
    (
      export AITEAMFORGE_DIR="${INSTALL_DIR}"
      export INSTALL_ROOT="${AITEAMFORGE_HOME}"
      export MACHINE_NAME="${MACHINE_NAME}"
      export FLEET_MODE="${FLEET_MODE}"
      export FLEET_SERVER_URL="${FLEET_SERVER_URL}"
      export NON_INTERACTIVE="true"
      export INSTALL_FLEET_MONITOR="true"
      [ "$REFRESH_PROFILES" = "true" ] && export AITEAMFORGE_REFRESH_PROFILES=1
      source "${AITEAMFORGE_HOME}/libexec/lib/common.sh"
      source "${INSTALLERS_DIR}/install-fleet-monitor.sh"
      install_fleet_monitor
    ) 2>&1 | sed 's/^/  /' || {
      echo -e "  ${RED}✗ Fleet Monitor had errors${NC}"
      INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    }
  else
    echo -e "  ${YELLOW}⚠ Fleet Monitor installer not found (skipping)${NC}"
  fi
  echo ""
fi

# -----------------------------------------------------------------------
# Load LaunchAgents (must run at TOP LEVEL, not in subshells)
# launchctl fails silently when run inside pipes or subshells
# Skipped in cockpit mode — no LaunchAgents are installed (no LCARS server,
# no kanban backup, no fleet reporter).
# -----------------------------------------------------------------------
if [ "$INSTALL_PROFILE" != "cockpit" ]; then
echo -e "${BOLD}Loading LaunchAgents...${NC}"
_loaded_agents=0
# XACA-1097: `launchctl load` exits 0 even when launchd REJECTS the job (a
# disabled agent's `load` prints "Load failed: 5: Input/output error" to
# stderr and still returns 0), so the exit code alone is never proof the
# agent registered — the unconditional `unload; load` below used to count
# every attempt as a success on that exit code alone. Verify the actual
# post-condition via the canonical _xaca0734_launchctl_is_loaded, and detect
# DISABLED up front via _xaca1097_launchctl_is_disabled so a doomed
# unload/load cycle is never attempted for a service that can never come up.
_launchagents_helpers_ok=false
type _xaca0734_launchctl_is_loaded >/dev/null 2>&1 && _launchagents_helpers_ok=true
for _plist in \
    "$HOME/Library/LaunchAgents/com.aiteamforge.fleet-reporter.plist" \
    "$HOME/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist" \
    "$HOME/Library/LaunchAgents/com.aiteamforge.lcars-health.plist" \
    "$HOME/Library/LaunchAgents/com.aiteamforge.tailscale-funnel.plist" \
    "$HOME/Library/LaunchAgents/com.aiteamforge.fleet-monitor.plist"; do
    if [ -f "$_plist" ]; then
        _name=$(basename "$_plist" .plist)
        if [ "$_launchagents_helpers_ok" != true ]; then
            # launchagents.sh unavailable — degrade to the pre-XACA-1097
            # trust-the-exit-code behavior rather than "command not found".
            _aitf_launchctl unload "$_plist" 2>/dev/null || true
            if _aitf_launchctl load "$_plist" 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} ${_name}"
                _loaded_agents=$((_loaded_agents + 1))
            else
                echo -e "  ${YELLOW}⚠${NC} ${_name} (failed to load)"
            fi
            continue
        fi
        if type _xaca1097_launchctl_is_disabled >/dev/null 2>&1 && _xaca1097_launchctl_is_disabled "$_name"; then
            echo -e "  ${YELLOW}⚠${NC} ${_name} is disabled — cannot be auto-fixed (a disabled service can never be loaded)"
            echo -e "     Run: launchctl enable gui/$(id -u)/${_name}"
            continue
        fi
        # Reset then reload so config/template changes take effect, but
        # NEVER trust unload/load's exit code — verify the post-condition
        # with the same exact-match helper used above.
        _aitf_launchctl unload "$_plist" 2>/dev/null || true
        # `|| true` is REQUIRED under this script's `set -eo pipefail`
        # (line 5) — a failing command-substitution assignment aborts the
        # whole script the instant `load` returns non-zero, before the `if`
        # below ever runs.
        _agent_stderr="$(_aitf_launchctl load "$_plist" 2>&1 >/dev/null)" || true
        if _xaca0734_launchctl_is_loaded "$_name"; then
            echo -e "  ${GREEN}✓${NC} ${_name}"
            _loaded_agents=$((_loaded_agents + 1))
        elif [ -n "$_agent_stderr" ]; then
            echo -e "  ${YELLOW}⚠${NC} ${_name} (failed to load: ${_agent_stderr})"
        else
            echo -e "  ${YELLOW}⚠${NC} ${_name} (failed to load)"
        fi
    fi
done
if [ "$_loaded_agents" -eq 0 ]; then
    echo -e "  ${YELLOW}⚠${NC} No LaunchAgents found to load"
fi
echo ""
fi  # end: if INSTALL_PROFILE != cockpit (LaunchAgents block)

# ═══════════════════════════════════════════════════════════════════════════
# WRITE CONFIGURATION FILE
# ═══════════════════════════════════════════════════════════════════════════

# Convert yes/no to JSON true/false
to_json_bool() { [ "$1" = "yes" ] && echo "true" || echo "false"; }

# Build installed_features array (list of enabled feature names)
_build_installed_features() {
  local features=()
  [ "$INSTALL_SHELL" = "yes" ]  && features+=("shell_environment")
  [ "$INSTALL_CLAUDE" = "yes" ] && features+=("claude_code_config")
  [ "$INSTALL_KANBAN" = "yes" ] && features+=("lcars_kanban")
  [ "$INSTALL_FLEET" = "yes" ]  && features+=("fleet_monitor")
  printf '"%s",' "${features[@]}" 2>/dev/null | sed 's/,$//'
}

cat > "${INSTALL_DIR}/.aiteamforge-config" <<EOF
{
  "version": "${VERSION}",
  "install_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "install_dir": "${INSTALL_DIR}",
  "framework_home": "${AITEAMFORGE_HOME}",
  "machine_name": "${MACHINE_NAME}",
  "teams": [$(printf '"%s",' "${SELECTED_TEAMS[@]}" | sed 's/,""//' | sed 's/,$//')],
  "team_paths": {$(
    for _tid in "${SELECTED_TEAMS[@]}"; do
      [ -z "$_tid" ] && continue
      _pvar="_PROJECT_${_tid}"; _proj="${!_pvar:-}"
      # PR #865 review, BLOCKING 1 (second symptom): fall back to
      # ${INSTALL_DIR}/${_tid} exactly like the sibling _team_dirs
      # serializer a few dozen lines up in the kanban-install block (and
      # the install-team.sh loop's own team_work_dir fallback) — a team
      # force-appended via _atf_apply_mandatory_teams' call site 2 (the
      # UPGRADE_HYDRATED/cockpit safety net) never runs through the Step 2
      # working-dir loop, so _WORKDIR_<team> is never set for it and this
      # would otherwise serialize as "working_dir": "". Call site 1 (the
      # interactive path) DOES run the working-dir loop for a
      # newly-appended mandatory team, so this fallback is a no-op there.
      _wvar="_WORKDIR_${_tid}"; _wdir="${!_wvar:-${INSTALL_DIR}/${_tid}}"
      _cvar="_CLIENT_${_tid}"; _client="${!_cvar:-}"
      if [ -n "$_client" ] && [ -n "$_proj" ]; then
        printf '"%s": {"working_dir": "%s", "client_id": "%s", "project_id": "%s"},' "$_tid" "$_wdir" "$_client" "$_proj"
      elif [ -n "$_proj" ]; then
        printf '"%s": {"working_dir": "%s", "project_id": "%s"},' "$_tid" "$_wdir" "$_proj"
      else
        printf '"%s": {"working_dir": "%s"},' "$_tid" "$_wdir"
      fi
    done | sed 's/,$//'
  )},
  "installed_features": [$(_build_installed_features)],
  "fleet_registration_status": "$([ "$INSTALL_FLEET" = "yes" ] && echo "pending" || echo "not_configured")",
  "install_profile": "${INSTALL_PROFILE}",
  "features": {
    "shell_environment": $(to_json_bool "$INSTALL_SHELL"),
    "claude_code_config": $(to_json_bool "$INSTALL_CLAUDE"),
    "lcars_kanban": $(to_json_bool "$INSTALL_KANBAN"),
    "fleet_monitor": $(to_json_bool "$INSTALL_FLEET"),
    "fleet_mode": "${FLEET_MODE}",
    "fleet_server_url": "${FLEET_SERVER_URL}"
  }
}
EOF

# Write install profile marker — used by aiteamforge doctor to skip checks
# for components that are deliberately absent in cockpit mode.
printf '%s\n' "${INSTALL_PROFILE}" > "${INSTALL_DIR}/.install-profile"
echo -e "${GREEN}✓${NC} Install profile marker written (${INSTALL_PROFILE})"

# ═══════════════════════════════════════════════════════════════════════════
# COMPLETION
# ═══════════════════════════════════════════════════════════════════════════

echo ""
if [ "$INSTALL_ERRORS" -gt 0 ]; then
  echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║           Setup Complete (with ${INSTALL_ERRORS} warnings)                      ║${NC}"
  echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${YELLOW}Some installers reported errors. Run 'aiteamforge doctor' for details.${NC}"
else
  echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║                    Setup Complete!                                ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
fi
echo ""
echo "  Machine:    ${MACHINE_NAME}"
echo "  Directory:  ${INSTALL_DIR}"
echo "  Profile:    ${INSTALL_PROFILE}"
if [ "$INSTALL_PROFILE" = "cockpit" ]; then
  _cockpit_mand_str="$(_cockpit_mandatory_teams_str)"
  if [ -n "$_cockpit_mand_str" ]; then
    echo "  Teams:      ${_cockpit_mand_str} (mandatory, full local install) — connect scripts for all teams installed"
  else
    echo "  Teams:      (cockpit — connect scripts for all teams installed)"
  fi
else
  echo "  Teams:      ${SELECTED_TEAMS[*]}"
fi
echo ""

# -----------------------------------------------------------------------
# Post-install checklist: detect what still needs attention
# -----------------------------------------------------------------------
echo -e "${BOLD}Post-Install Checklist${NC}"
echo ""

CHECKLIST_ITEMS=0

# GitHub CLI authentication
if command -v gh &>/dev/null; then
  if gh auth status &>/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} GitHub CLI authenticated"
  else
    echo -e "  ${YELLOW}○${NC} GitHub CLI not authenticated"
    echo -e "    Run: ${CYAN}gh auth login${NC}"
    CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
  fi
fi

# Tailscale setup (for Fleet Monitor remote access)
# Resolve tailscale CLI path (cask puts it inside the app bundle)
TAILSCALE_CLI=""
if command -v tailscale &>/dev/null; then
  TAILSCALE_CLI="tailscale"
elif [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  TAILSCALE_CLI="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  # Create symlink so 'tailscale' works everywhere
  if [ ! -e "/usr/local/bin/tailscale" ]; then
    echo -e "  ${CYAN}Creating tailscale CLI symlink...${NC}"
    sudo mkdir -p /usr/local/bin 2>/dev/null || true
    sudo ln -sf "$TAILSCALE_CLI" /usr/local/bin/tailscale 2>/dev/null && TAILSCALE_CLI="tailscale" || true
  fi
fi

if [ -n "$TAILSCALE_CLI" ]; then
  # Tailscale installed — check if running and authenticated
  ts_status=$($TAILSCALE_CLI status 2>&1 || true)
  if echo "$ts_status" | grep -q "failed to connect\|stopped"; then
    echo -e "  ${YELLOW}○${NC} Tailscale installed but not running"
    if [ "$MODE" != "non-interactive" ]; then
      echo ""
      echo -e "    Tailscale enables remote access to your Fleet Monitor and LCARS dashboards."
      read -rp "    Start Tailscale now? (yes/no) [yes]: " start_ts
      start_ts="${start_ts:-yes}"
      if [ "$start_ts" = "yes" ]; then
        echo -e "    Starting Tailscale..."
        if [ -d "/Applications/Tailscale.app" ]; then
          open /Applications/Tailscale.app
          echo -e "    Opened Tailscale app. Sign in via the menu bar icon."
          sleep 5
        else
          echo -e "    ${YELLOW}Tailscale GUI app not found.${NC}"
          echo -e "    The CLI-only package cannot run the daemon on macOS."
          echo -e "    Installing the full app..."
          brew uninstall tailscale 2>/dev/null || true
          brew install --cask tailscale 2>&1 | tail -3
          open /Applications/Tailscale.app 2>/dev/null
          echo -e "    Opened Tailscale app. Sign in via the menu bar icon."
          sleep 5
        fi
        # Check if connected after app launch
        ts_status2=$($TAILSCALE_CLI status 2>&1 || true)
        if echo "$ts_status2" | grep -q "NeedsLogin\|not logged in\|failed to connect"; then
          echo ""
          echo -e "    ${CYAN}Sign in to Tailscale via the menu bar icon, then press Enter.${NC}"
          read -rp "    Press Enter when signed in... "
        fi
        # Verify
        ts_ip=$($TAILSCALE_CLI ip -4 2>/dev/null | head -n1 || true)
        if [ -n "$ts_ip" ]; then
          ts_hostname=$($TAILSCALE_CLI status 2>/dev/null | head -1 | awk '{print $2}' || true)
          echo -e "  ${GREEN}✓${NC} Tailscale connected: ${ts_hostname:-$ts_ip}"
        else
          echo -e "  ${YELLOW}⚠${NC} Tailscale started but not yet connected"
          CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
        fi
      else
        echo -e "    Run later: ${CYAN}open /Applications/Tailscale.app${NC}"
        CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
      fi
    else
      echo -e "    Start with: ${CYAN}open /Applications/Tailscale.app${NC}"
      CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
    fi
  elif echo "$ts_status" | grep -q "NeedsLogin\|not logged in"; then
    echo -e "  ${YELLOW}○${NC} Tailscale running but not authenticated"
    if [ "$MODE" != "non-interactive" ]; then
      echo ""
      echo -e "    Running ${CYAN}tailscale up${NC} — this will open a browser for login."
      echo ""
      $TAILSCALE_CLI up 2>&1 || true
      sleep 2
      ts_ip=$($TAILSCALE_CLI ip -4 2>/dev/null | head -n1 || true)
      if [ -n "$ts_ip" ]; then
        echo -e "  ${GREEN}✓${NC} Tailscale authenticated"
      else
        echo -e "  ${YELLOW}⚠${NC} Tailscale authentication incomplete"
        CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
      fi
    else
      echo -e "    Authenticate: ${CYAN}tailscale up${NC}"
      CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
    fi
  else
    ts_ip=$($TAILSCALE_CLI ip -4 2>/dev/null | head -n1 || true)
    ts_hostname=$($TAILSCALE_CLI status 2>/dev/null | head -1 | awk '{print $2}' || true)
    echo -e "  ${GREEN}✓${NC} Tailscale connected: ${ts_hostname:-$ts_ip}"
  fi
else
  echo -e "  ${YELLOW}○${NC} Tailscale not installed (optional — needed for remote access)"
  if [ "$MODE" != "non-interactive" ]; then
    read -rp "    Install Tailscale now? (yes/no) [no]: " install_ts
    install_ts="${install_ts:-no}"
    if [ "$install_ts" = "yes" ]; then
      echo -e "    Installing Tailscale (GUI app)..."
      brew install --cask tailscale 2>&1 | tail -3
      echo -e "    Opening Tailscale app..."
      open /Applications/Tailscale.app 2>/dev/null
      sleep 5
      echo -e "    ${CYAN}Sign in to Tailscale via the menu bar icon, then press Enter.${NC}"
      read -rp "    Press Enter when signed in... "
      ts_ip=$($TAILSCALE_CLI ip -4 2>/dev/null | head -n1 || true)
      if [ -n "$ts_ip" ]; then
        echo -e "  ${GREEN}✓${NC} Tailscale installed and connected"
      else
        echo -e "  ${YELLOW}⚠${NC} Tailscale installed — sign in via the menu bar icon"
        CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
      fi
    else
      echo -e "    Install later: ${CYAN}brew install --cask tailscale${NC}"
      CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
    fi
  else
    echo -e "    Install: ${CYAN}brew install --cask tailscale${NC}"
    CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
  fi
fi

# iTerm2 Python API
if [ -d "/Applications/iTerm.app" ]; then
  api_enabled=$(defaults read com.googlecode.iterm2 EnableAPIServer 2>/dev/null || true)
  if [ "$api_enabled" = "1" ]; then
    echo -e "  ${GREEN}✓${NC} iTerm2 Python API enabled"
  else
    echo -e "  ${YELLOW}○${NC} iTerm2 Python API not enabled (needed for automatic tab creation)"
    echo -e "    Fix: ${CYAN}defaults write com.googlecode.iterm2 EnableAPIServer -bool true${NC}"
    echo -e "    Then restart iTerm2"
    CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
  fi
fi

# Shell integration (not applicable in cockpit mode)
if [ "$INSTALL_PROFILE" != "cockpit" ]; then
  if [ -f "$HOME/.zshrc" ] && grep -q "aiteamforge" "$HOME/.zshrc" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Shell integration in .zshrc"
  else
    echo -e "  ${YELLOW}○${NC} Shell not yet reloaded"
    echo -e "    Run: ${CYAN}source ~/.zshrc${NC}"
    CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
  fi
fi

echo ""

if [ "$CHECKLIST_ITEMS" -eq 0 ]; then
  echo -e "  ${GREEN}All set! No additional steps needed.${NC}"
else
  echo -e "  ${YELLOW}${CHECKLIST_ITEMS} item(s) above will enhance your setup (all optional).${NC}"
fi

echo ""
echo -e "${BOLD}Getting Started${NC}"
echo ""
if [ "$INSTALL_PROFILE" = "cockpit" ]; then
  echo "  Connect to a remote team:"
  # Show first available connect script as example
  _first_connect=""
  for _cs in "${INSTALL_DIR}"/*-connect.sh; do
    [ -f "$_cs" ] && _first_connect="$_cs" && break
  done
  if [ -n "$_first_connect" ]; then
    echo -e "    ${CYAN}${_first_connect} <remote-hostname>${NC}"
    echo ""
    echo "  All connect scripts:"
    for _cs in "${INSTALL_DIR}"/*-connect.sh; do
      [ -f "$_cs" ] && echo -e "    ${CYAN}$(basename "$_cs")${NC}"
    done
  else
    echo -e "    ${CYAN}${INSTALL_DIR}/<team>-connect.sh <remote-hostname>${NC}"
  fi
else
  echo "  Launch a team:"
  for team_id in "${SELECTED_TEAMS[@]}"; do
    [ -z "$team_id" ] && continue
    echo -e "    ${CYAN}${INSTALL_DIR}/${team_id}-startup.sh${NC}"
    break  # Just show the first one as example
  done
  if [ ${#SELECTED_TEAMS[@]} -gt 1 ]; then
    echo "    (${#SELECTED_TEAMS[@]} teams available)"
  fi
fi
echo ""
echo "  Other commands:"
echo -e "    ${CYAN}aiteamforge doctor${NC}    Health check & diagnostics"
echo -e "    ${CYAN}aiteamforge status${NC}    Show environment status"
echo -e "    ${CYAN}aiteamforge help${NC}      All available commands"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# FINAL STEP: POST-INSTALL VALIDATION
# Verify everything landed correctly before handing control back to the user.
# ═══════════════════════════════════════════════════════════════════════════

echo -e "${BOLD}Running post-install validation...${NC}"
echo ""

# Locate the validate-install library (relative to this script or via AITEAMFORGE_HOME)
_VAL_LIB=""
for _candidate in \
    "${AITEAMFORGE_HOME}/libexec/lib/validate-install.sh" \
    "$(dirname "$(realpath "$0" 2>/dev/null || echo "$0")")/../libexec/lib/validate-install.sh"; do
  if [ -f "$_candidate" ]; then
    _VAL_LIB="$_candidate"
    break
  fi
done

if [ -n "$_VAL_LIB" ]; then
  # Source and run — returns 0 on pass/warn, 1 on failures
  source "$_VAL_LIB"
  validate_installation "${INSTALL_DIR}" || true
else
  echo -e "${YELLOW}⚠ Validation library not found — skipping post-install check${NC}"
  echo -e "  Run ${CYAN}aiteamforge doctor${NC} manually to verify your installation."
  echo ""
fi
