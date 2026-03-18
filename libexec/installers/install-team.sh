#!/bin/bash
# Team Installer Module
# Installs a specific team's environment, tools, and configuration
# Usage: install-team.sh <team-id> [--install-dir <path>]

set -e

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMEBREW_TAP_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEAMS_DIR="$HOMEBREW_TAP_ROOT/share/teams"

# Default installation location (can be overridden)
AITEAMFORGE_DIR="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

TEAM_ID=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --install-dir|--aiteamforge-dir)
            AITEAMFORGE_DIR="$2"
            shift 2
            ;;
        *)
            if [[ -z "$TEAM_ID" ]]; then
                TEAM_ID="$1"
            else
                echo "Error: Unknown argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$TEAM_ID" ]]; then
    echo "Usage: install-team.sh <team-id> [--install-dir <path>]"
    echo ""
    echo "Available teams:"
    for conf in "$TEAMS_DIR"/*.conf; do
        if [[ -f "$conf" ]]; then
            basename "$conf" .conf
        fi
    done
    exit 1
fi

# Validate TEAM_ID - alphanumeric, hyphens, and underscores only (BEFORE file check)
if [[ ! "$TEAM_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Invalid team ID: $TEAM_ID (alphanumeric, hyphens, and underscores only)"
    exit 1
fi

# ============================================================================
# LOAD TEAM DEFINITION
# ============================================================================

TEAM_CONF="$TEAMS_DIR/$TEAM_ID.conf"
if [[ ! -f "$TEAM_CONF" ]]; then
    echo "Error: Team configuration not found: $TEAM_CONF"
    exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Installing Team: $TEAM_ID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Source the team configuration
source "$TEAM_CONF"

# Save the base working dir from conf (before env override)
# For project-based teams, this is the parent dir (e.g., ~/medical)
# while TEAM_WORKING_DIR from env includes the project (e.g., ~/medical/ehlers.darren)
TEAM_BASE_WORKING_DIR="${TEAM_WORKING_DIR}"
TEAM_BASE_WORKING_DIR="${TEAM_BASE_WORKING_DIR/\$HOME/$HOME}"

echo "Team Name: $TEAM_NAME"
echo "Category: $TEAM_CATEGORY"
echo "Description: $TEAM_DESCRIPTION"
echo "Theme: $TEAM_THEME"
echo ""

# ============================================================================
# INSTALL HOMEBREW DEPENDENCIES
# ============================================================================

if [[ ${#TEAM_BREW_DEPS[@]} -gt 0 ]]; then
    echo "📦 Installing Homebrew dependencies..."
    for dep in "${TEAM_BREW_DEPS[@]}"; do
        if brew list "$dep" &>/dev/null; then
            echo "  ✓ $dep (already installed)"
        else
            echo "  → Installing $dep..."
            brew install "$dep" || {
                echo "  ⚠️  Warning: Failed to install $dep (continuing anyway)"
            }
        fi
    done
    echo ""
fi

if [[ ${#TEAM_BREW_CASK_DEPS[@]} -gt 0 ]]; then
    echo "📦 Installing Homebrew cask dependencies..."
    for dep in "${TEAM_BREW_CASK_DEPS[@]}"; do
        if brew list --cask "$dep" &>/dev/null; then
            echo "  ✓ $dep (already installed)"
        else
            echo "  → Installing $dep..."
            brew install --cask "$dep" || {
                echo "  ⚠️  Warning: Failed to install $dep (continuing anyway)"
            }
        fi
    done
    echo ""
fi

# ============================================================================
# CREATE TEAM DIRECTORY STRUCTURE
# ============================================================================

echo "📁 Creating team directory structure..."

TEAM_DIR="$AITEAMFORGE_DIR/$TEAM_ID"
mkdir -p "$TEAM_DIR"
mkdir -p "$TEAM_DIR/personas"
mkdir -p "$TEAM_DIR/personas/agents"
mkdir -p "$TEAM_DIR/personas/avatars"
mkdir -p "$TEAM_DIR/personas/docs"
mkdir -p "$TEAM_DIR/scripts"
mkdir -p "$TEAM_DIR/terminals"

echo "  ✓ $TEAM_DIR"
echo ""

# ============================================================================
# COPY TEAM PERSONA TEMPLATES (IF AVAILABLE)
# ============================================================================

# Check if persona templates exist in the homebrew-tap
PERSONAS_TEMPLATE_DIR="$HOMEBREW_TAP_ROOT/share/personas/$TEAM_ID"
if [[ -d "$PERSONAS_TEMPLATE_DIR" ]]; then
    echo "👤 Installing team personas..."
    cp -R "$PERSONAS_TEMPLATE_DIR"/* "$TEAM_DIR/personas/" || true
    echo "  ✓ Personas copied"
    echo ""
fi

# ============================================================================
# CREATE STARTUP/SHUTDOWN SCRIPTS FROM TEMPLATES
# ============================================================================

echo "🚀 Creating startup/shutdown scripts..."

STARTUP_SCRIPT="$AITEAMFORGE_DIR/$TEAM_STARTUP_SCRIPT"
SHUTDOWN_SCRIPT="$AITEAMFORGE_DIR/$TEAM_SHUTDOWN_SCRIPT"

# Build space-separated terminal list from agents (for template substitution)
TEAM_TERMINAL_LIST="${TEAM_AGENTS[*]}"

# Determine if this is a project-based team
IS_PROJECT_TEAM="false"
REQUIRES_CLIENT="false"
if [[ -f "$TEAM_CONF" ]]; then
    grep -q 'TEAM_HAS_PROJECTS="true"' "$TEAM_CONF" && IS_PROJECT_TEAM="true"
    grep -q 'TEAM_REQUIRES_CLIENT_ID="true"' "$TEAM_CONF" && REQUIRES_CLIENT="true"
fi

# Check for team-specific template first, then generic/project template
STARTUP_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/$TEAM_STARTUP_SCRIPT.template"
if [[ ! -f "$STARTUP_TEMPLATE" ]]; then
    if [[ "$IS_PROJECT_TEAM" == "true" ]]; then
        STARTUP_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/team-project-startup.sh.template"
    else
        STARTUP_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/team-startup.sh.template"
    fi
fi

SHUTDOWN_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/$TEAM_SHUTDOWN_SCRIPT.template"
if [[ ! -f "$SHUTDOWN_TEMPLATE" ]]; then
    SHUTDOWN_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/team-shutdown.sh.template"
fi

if [[ -f "$STARTUP_TEMPLATE" ]]; then
    sed -e "s|{{TEAM_ID}}|$TEAM_ID|g" \
        -e "s|{{TEAM_NAME}}|$TEAM_NAME|g" \
        -e "s|{{TEAM_THEME}}|$TEAM_THEME|g" \
        -e "s|{{TEAM_SHIP}}|$TEAM_SHIP|g" \
        -e "s|{{TEAM_LCARS_PORT}}|$TEAM_LCARS_PORT|g" \
        -e "s|{{TEAM_TMUX_SOCKET}}|$TEAM_TMUX_SOCKET|g" \
        -e "s|{{TEAM_TERMINAL_LIST}}|$TEAM_TERMINAL_LIST|g" \
        -e "s|{{TEAM_WORKING_DIR}}|$(if [[ "$IS_PROJECT_TEAM" == "true" ]]; then echo "$TEAM_BASE_WORKING_DIR"; else echo "${TEAM_WORKING_DIR:-$AITEAMFORGE_DIR/$TEAM_ID}"; fi)|g" \
        -e "s|{{TEAM_REQUIRES_CLIENT}}|${REQUIRES_CLIENT}|g" \
        -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
        "$STARTUP_TEMPLATE" > "$STARTUP_SCRIPT"
    chmod +x "$STARTUP_SCRIPT"
    echo "  ✓ $TEAM_STARTUP_SCRIPT"
else
    echo "  ⚠️  Template not found: $TEAM_STARTUP_SCRIPT.template (will create basic version)"
    cat > "$STARTUP_SCRIPT" <<EOF
#!/bin/zsh
# $TEAM_NAME Startup Script
# Auto-generated by aiteamforge installer

echo "🚀 $TEAM_NAME"
echo "   $TEAM_THEME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Team: $TEAM_ID"
echo "LCARS Port: $TEAM_LCARS_PORT"
echo ""
EOF
    chmod +x "$STARTUP_SCRIPT"
    echo "  ✓ $TEAM_STARTUP_SCRIPT (basic version)"
fi

if [[ -f "$SHUTDOWN_TEMPLATE" ]]; then
    sed -e "s|{{TEAM_ID}}|$TEAM_ID|g" \
        -e "s|{{TEAM_NAME}}|$TEAM_NAME|g" \
        -e "s|{{TEAM_TMUX_SOCKET}}|$TEAM_TMUX_SOCKET|g" \
        -e "s|{{TEAM_LCARS_PORT}}|$TEAM_LCARS_PORT|g" \
        -e "s|{{TEAM_WORKING_DIR}}|${TEAM_WORKING_DIR:-$AITEAMFORGE_DIR/$TEAM_ID}|g" \
        -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
        "$SHUTDOWN_TEMPLATE" > "$SHUTDOWN_SCRIPT"
    chmod +x "$SHUTDOWN_SCRIPT"
    echo "  ✓ $TEAM_SHUTDOWN_SCRIPT"
else
    cat > "$SHUTDOWN_SCRIPT" <<EOF
#!/bin/zsh
# $TEAM_NAME Shutdown Script
echo "Shutting down $TEAM_NAME..."
tmux -L $TEAM_TMUX_SOCKET kill-server 2>/dev/null || true
echo "✓ $TEAM_NAME shut down"
EOF
    chmod +x "$SHUTDOWN_SCRIPT"
    echo "  ✓ $TEAM_SHUTDOWN_SCRIPT (basic version)"
fi

echo ""

# ============================================================================
# CONFIGURE CLAUDE CODE AGENT ALIASES
# ============================================================================

echo "🤖 Configuring Claude Code agent aliases..."

ALIASES_FILE="$AITEAMFORGE_DIR/claude_agent_aliases.sh"
ALIASES_TEAM_SECTION="# $TEAM_NAME aliases"

# Create aliases file if it doesn't exist
if [[ ! -f "$ALIASES_FILE" ]]; then
    cat > "$ALIASES_FILE" <<EOF
#!/bin/bash
# Claude Code Agent Aliases
# Auto-generated by aiteamforge installer

EOF
fi

# Add team section if not already present
if ! grep -q "$ALIASES_TEAM_SECTION" "$ALIASES_FILE"; then
    cat >> "$ALIASES_FILE" <<EOF

$ALIASES_TEAM_SECTION
EOF

    for agent in "${TEAM_AGENTS[@]}"; do
        AGENT_NAME=$(echo "$agent" | tr '[:lower:]' '[:upper:]')
        cat >> "$ALIASES_FILE" <<EOF
alias ${TEAM_ID}-${agent}='claude --agent-path "$AITEAMFORGE_DIR/claude/agents/${TEAM_NAME}/${agent}"'
EOF
        echo "  ✓ Alias: ${TEAM_ID}-${agent}"
    done

    echo ""
fi

# ============================================================================
# SETUP TEAM KANBAN BOARD
# ============================================================================

echo "📋 Setting up team kanban board..."

# Use team working dir if set (project-based teams), otherwise central kanban dir
if [[ -n "${TEAM_WORKING_DIR:-}" && "$TEAM_WORKING_DIR" != "$AITEAMFORGE_DIR" && "$TEAM_WORKING_DIR" != "$AITEAMFORGE_DIR/$TEAM_ID" ]]; then
    KANBAN_DIR="${TEAM_WORKING_DIR}/kanban"
else
    KANBAN_DIR="$AITEAMFORGE_DIR/kanban"
fi
mkdir -p "$KANBAN_DIR"

TEAM_BOARD="$KANBAN_DIR/${TEAM_ID}-board.json"

if [[ ! -f "$TEAM_BOARD" ]]; then
    # Create initial empty board structure
    cat > "$TEAM_BOARD" <<EOF
{
  "team": "$TEAM_ID",
  "teamName": "$TEAM_NAME",
  "version": "1.3.0",
  "items": {},
  "metadata": {
    "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "lastModified": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  }
}
EOF
    echo "  ✓ Created kanban board: ${TEAM_ID}-board.json"
else
    echo "  ✓ Kanban board already exists"
fi

echo ""

# ============================================================================
# CREATE LCARS PORT CONFIGURATION
# ============================================================================

echo "🖥️  Configuring LCARS port assignments..."

LCARS_PORTS_DIR="$AITEAMFORGE_DIR/lcars-ports"
mkdir -p "$LCARS_PORTS_DIR"

# Create port files for each agent
for agent in "${TEAM_AGENTS[@]}"; do
    PORT_FILE="$LCARS_PORTS_DIR/${TEAM_ID}-${agent}.port"
    if [[ ! -f "$PORT_FILE" ]]; then
        # Assign a port (this is a simple incrementing scheme, can be improved)
        # Base port + offset based on agent index
        AGENT_INDEX=0
        for ((i=0; i<${#TEAM_AGENTS[@]}; i++)); do
            if [[ "${TEAM_AGENTS[$i]}" == "$agent" ]]; then
                AGENT_INDEX=$i
                break
            fi
        done

        AGENT_PORT=$((TEAM_LCARS_PORT + AGENT_INDEX))
        echo "$AGENT_PORT" > "$PORT_FILE"

        # Create theme file (default to team color)
        THEME_FILE="$LCARS_PORTS_DIR/${TEAM_ID}-${agent}.theme"
        echo "$TEAM_COLOR" > "$THEME_FILE"

        # Create order file
        ORDER_FILE="$LCARS_PORTS_DIR/${TEAM_ID}-${agent}.order"
        echo "$AGENT_INDEX" > "$ORDER_FILE"
    fi
done

echo "  ✓ Port assignments created"
echo ""

# ============================================================================
# INSTALLATION SUMMARY
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Team Installation Complete: $TEAM_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Team directory: $TEAM_DIR"
echo "Startup script: $AITEAMFORGE_DIR/$TEAM_STARTUP_SCRIPT"
echo "Shutdown script: $AITEAMFORGE_DIR/$TEAM_SHUTDOWN_SCRIPT"
echo "Kanban board: $TEAM_BOARD"
echo ""
echo "Agent aliases:"
for agent in "${TEAM_AGENTS[@]}"; do
    echo "  ${TEAM_ID}-${agent}"
done
echo ""
echo "Next steps:"
echo "  1. Source the aliases file: source $ALIASES_FILE"
echo "  2. Launch the team: $AITEAMFORGE_DIR/$TEAM_STARTUP_SCRIPT"
echo "  3. Start working with agents: ${TEAM_ID}-${TEAM_AGENTS[0]}"
echo ""
