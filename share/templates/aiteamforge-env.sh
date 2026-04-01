#!/bin/zsh
# AITeamForge Environment Loader
# Sources team-specific configurations, aliases, and secrets

# Guard against double-sourcing (e.g. when iTerm2 startup sends "exec zsh"
# to replace the initial shell, causing .zshrc — and this file — to be
# sourced a second time inside the same logical session).
if [[ -n "${_AITEAMFORGE_ENV_LOADED:-}" ]]; then
    return 0
fi
export _AITEAMFORGE_ENV_LOADED=1

# AITeamForge installation directory
# This will be substituted during installation
export AITEAMFORGE_DIR="{{AITEAMFORGE_DIR}}"

#──────────────────────────────────────────────────────────────────────────────
# Kanban Helper Functions (kb-add, kb-list, kb-done, kb-backlog, etc.)
# Sourced from the full kanban-helpers.sh installed by install-kanban.sh
#──────────────────────────────────────────────────────────────────────────────

if [ -f "$AITEAMFORGE_DIR/kanban-helpers.sh" ]; then
    source "$AITEAMFORGE_DIR/kanban-helpers.sh"
fi

#──────────────────────────────────────────────────────────────────────────────
# Shell Aliases and Functions
#──────────────────────────────────────────────────────────────────────────────

# Agent switching functions (claude-geordi, claude-sisko, claude-reno, etc.)
if [ -f "$AITEAMFORGE_DIR/share/aliases/agent-aliases.sh" ]; then
    source "$AITEAMFORGE_DIR/share/aliases/agent-aliases.sh"
fi

# CC aliases — launch Claude with team-specific agent personas
# (cc-ios-bridge, cc-academy-engineering, cc-firebase-ops, etc.)
if [ -f "$AITEAMFORGE_DIR/share/aliases/cc-aliases.sh" ]; then
    source "$AITEAMFORGE_DIR/share/aliases/cc-aliases.sh"
fi

# Worktree helper functions (wt-create, wt-list, wt-go, etc.)
if [ -f "$AITEAMFORGE_DIR/share/aliases/worktree-aliases.sh" ]; then
    source "$AITEAMFORGE_DIR/share/aliases/worktree-aliases.sh"
fi

#──────────────────────────────────────────────────────────────────────────────
# Load Prompt Customization
#──────────────────────────────────────────────────────────────────────────────

if [ -f "$AITEAMFORGE_DIR/share/aiteamforge-prompt.sh" ]; then
    source "$AITEAMFORGE_DIR/share/aiteamforge-prompt.sh"
fi

#──────────────────────────────────────────────────────────────────────────────
# Load Secrets (if exists)
#──────────────────────────────────────────────────────────────────────────────

# Load secrets ONLY if file exists
# This file should NEVER be committed to git
SECRETS_FILE="$AITEAMFORGE_DIR/secrets.env"
if [ -f "$SECRETS_FILE" ]; then
    # Verify file is only readable by owner
    if [[ "$(stat -f '%Lp' "$SECRETS_FILE" 2>/dev/null)" != "600" ]]; then
        echo "⚠️  Warning: $SECRETS_FILE has loose permissions. Run: chmod 600 $SECRETS_FILE"
    fi
    source "$SECRETS_FILE"
fi

#──────────────────────────────────────────────────────────────────────────────
# Python Virtual Environment (for iterm2 module and other Python scripts)
#──────────────────────────────────────────────────────────────────────────────

# Activate the AITeamForge venv if it exists, making the iterm2 module and
# other installed packages available to scripts like iterm2_window_manager.py
# and iterm-browser.py without requiring system-wide pip installs.
AITEAMFORGE_VENV="${HOME}/.aiteamforge/venv"
if [ -f "${AITEAMFORGE_VENV}/bin/activate" ]; then
    source "${AITEAMFORGE_VENV}/bin/activate"
fi

#──────────────────────────────────────────────────────────────────────────────
# PATH Additions
#──────────────────────────────────────────────────────────────────────────────

# Add aiteamforge bin directory to PATH if it exists
if [ -d "$AITEAMFORGE_DIR/bin" ]; then
    export PATH="$AITEAMFORGE_DIR/bin:$PATH"
fi

#──────────────────────────────────────────────────────────────────────────────
# Team-Specific Startup Scripts
#──────────────────────────────────────────────────────────────────────────────

# If a team-specific startup script exists for this terminal, source it
# This is set by iTerm2 profiles or manual export
if [ -n "$AITEAMFORGE_STARTUP" ]; then
    # Reject path traversal attempts
    if [[ "$AITEAMFORGE_STARTUP" == *".."* ]]; then
        echo "⚠️  Warning: AITEAMFORGE_STARTUP contains path traversal — ignoring"
    elif [ -f "$AITEAMFORGE_DIR/$AITEAMFORGE_STARTUP" ]; then
        source "$AITEAMFORGE_DIR/$AITEAMFORGE_STARTUP"
    fi
fi

#──────────────────────────────────────────────────────────────────────────────
# Quiet Success
#──────────────────────────────────────────────────────────────────────────────

# Don't spam output on every shell load
# The aliases will print their own load messages
