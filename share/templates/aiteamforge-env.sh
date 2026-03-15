#!/bin/zsh
# AITeamForge Environment Loader
# Sources team-specific configurations, aliases, and secrets

# Dev-Team installation directory
# This will be substituted during installation
export AITEAMFORGE_DIR="{{AITEAMFORGE_DIR}}"

#──────────────────────────────────────────────────────────────────────────────
# Load Shell Aliases
#──────────────────────────────────────────────────────────────────────────────

# Agent switching aliases (claude-geordi, claude-sisko, etc.)
if [ -f "$AITEAMFORGE_DIR/share/aliases/agent-aliases.sh" ]; then
    source "$AITEAMFORGE_DIR/share/aliases/agent-aliases.sh"
fi

# Kanban helper functions (kb-add, kb-list, kb-update, etc.)
if [ -f "$AITEAMFORGE_DIR/share/aliases/kanban-aliases.sh" ]; then
    source "$AITEAMFORGE_DIR/share/aliases/kanban-aliases.sh"
fi

# Worktree helper functions (wt-create, wt-list, etc.)
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
