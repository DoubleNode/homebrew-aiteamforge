#!/bin/bash
# Team Installer Module
# Installs a specific team's environment, tools, and configuration
# Usage: install-team.sh <team-id> [--install-dir <path>]

set -euo pipefail

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

# Read conf values safely in a subshell so the conf file cannot modify the
# current shell's PATH, functions, or other sensitive state.  The subshell
# sources the file and then serializes only the known scalar and array
# variables back to stdout as eval-safe quoted assignments.  The parent shell
# evals that output to import the values.
_read_conf() {
    local conf_file="$1"
    (
        # Source in a clean subshell — side effects are contained here.
        # shellcheck disable=SC1090
        source "$conf_file"

        # Emit scalar variables as KEY='value' lines.
        printf 'TEAM_NAME=%q\n'         "${TEAM_NAME:-}"
        printf 'TEAM_DESCRIPTION=%q\n'  "${TEAM_DESCRIPTION:-}"
        printf 'TEAM_CATEGORY=%q\n'     "${TEAM_CATEGORY:-}"
        printf 'TEAM_COLOR=%q\n'        "${TEAM_COLOR:-#5585CC}"
        printf 'TEAM_LCARS_PORT=%q\n'   "${TEAM_LCARS_PORT:-8200}"
        printf 'TEAM_TMUX_SOCKET=%q\n'  "${TEAM_TMUX_SOCKET:-$TEAM_ID}"
        printf 'TEAM_WORKING_DIR=%q\n'  "${TEAM_WORKING_DIR:-}"
        printf 'TEAM_THEME=%q\n'        "${TEAM_THEME:-}"
        printf 'TEAM_SHIP=%q\n'         "${TEAM_SHIP:-}"
        printf 'TEAM_STARTUP_SCRIPT=%q\n'  "${TEAM_STARTUP_SCRIPT:-${TEAM_ID}-startup.sh}"
        printf 'TEAM_SHUTDOWN_SCRIPT=%q\n' "${TEAM_SHUTDOWN_SCRIPT:-${TEAM_ID}-shutdown.sh}"
        printf 'TEAM_HAS_PROJECTS=%q\n'    "${TEAM_HAS_PROJECTS:-false}"
        printf 'TEAM_REQUIRES_CLIENT_ID=%q\n' "${TEAM_REQUIRES_CLIENT_ID:-false}"
        printf 'TEAM_ORGANIZATION=%q\n' "${TEAM_ORGANIZATION:-}"

        # Emit arrays as bash array declarations so they survive the eval.
        printf 'TEAM_AGENTS=('
        printf '%q ' "${TEAM_AGENTS[@]+"${TEAM_AGENTS[@]}"}"
        printf ')\n'

        printf 'TEAM_BREW_DEPS=('
        printf '%q ' "${TEAM_BREW_DEPS[@]+"${TEAM_BREW_DEPS[@]}"}"
        printf ')\n'

        printf 'TEAM_BREW_CASK_DEPS=('
        printf '%q ' "${TEAM_BREW_CASK_DEPS[@]+"${TEAM_BREW_CASK_DEPS[@]}"}"
        printf ')\n'
    )
}

# Import conf values into the current shell via eval.
eval "$(_read_conf "$TEAM_CONF")"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Installing Team: $TEAM_ID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

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
mkdir -p "$TEAM_DIR/scripts/prompts"
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
    # Also copy avatar images into the flat avatars/ pool so agent-panel-display.sh
    # can find them without fleet-monitor installed.
    FLAT_AVATARS_DIR="$AITEAMFORGE_DIR/avatars"
    mkdir -p "$FLAT_AVATARS_DIR"
    if [[ -d "$PERSONAS_TEMPLATE_DIR/avatars" ]]; then
        cp "$PERSONAS_TEMPLATE_DIR/avatars/"*.png "$FLAT_AVATARS_DIR/" 2>/dev/null || true
        echo "  ✓ Avatars added to shared pool ($FLAT_AVATARS_DIR)"
    fi

    # Copy .txt system prompt files into scripts/prompts/ so cc-aliases can find them.
    # cc-aliases reads <AITEAMFORGE_DIR>/<team>/scripts/prompts/<team>-<terminal>-prompt.txt
    # to load the Claude system prompt when launching agents.
    if [[ -d "$PERSONAS_TEMPLATE_DIR/prompts" ]]; then
        mkdir -p "$TEAM_DIR/scripts/prompts"
        cp "$PERSONAS_TEMPLATE_DIR/prompts/"*.txt "$TEAM_DIR/scripts/prompts/" 2>/dev/null || true
        PROMPT_COUNT=$(ls "$TEAM_DIR/scripts/prompts/"*.txt 2>/dev/null | wc -l | tr -d ' ')
        echo "  ✓ Installed $PROMPT_COUNT system prompt file(s) to scripts/prompts/"
    fi
    echo ""
fi

# ============================================================================
# CREATE STARTUP/SHUTDOWN SCRIPTS FROM TEMPLATES
# ============================================================================

echo "🚀 Creating startup/shutdown scripts..."

STARTUP_SCRIPT="$AITEAMFORGE_DIR/$TEAM_STARTUP_SCRIPT"
SHUTDOWN_SCRIPT="$AITEAMFORGE_DIR/$TEAM_SHUTDOWN_SCRIPT"

# Build space-separated terminal list from agents (for template substitution)
TEAM_TERMINAL_LIST="${TEAM_AGENTS[*]+"${TEAM_AGENTS[*]}"}"

# Build per-agent window name declarations for template substitution.
# Each agent in TEAM_AGENTS may have a corresponding AGENT_WINDOWS_<agent> variable
# defined in the .conf file (hyphens in agent names are stored with underscores).
# This emits shell variable assignment lines that get embedded verbatim into the
# generated startup script so the tmux loop can resolve window names at runtime.
TEAM_AGENT_WINDOWS_CONFIG=""
for _agent in "${TEAM_AGENTS[@]}"; do
    # Sanitize: replace hyphens with underscores for valid shell variable name
    _agent_key="${_agent//-/_}"
    _var="AGENT_WINDOWS_${_agent_key}"
    _val="${!_var}"
    if [[ -n "$_val" ]]; then
        TEAM_AGENT_WINDOWS_CONFIG+="AGENT_WINDOWS_${_agent_key}=\"${_val}\""$'\n'
    fi
done

# Determine if this is a project-based team (values already imported from conf)
IS_PROJECT_TEAM="$TEAM_HAS_PROJECTS"
REQUIRES_CLIENT="$TEAM_REQUIRES_CLIENT_ID"

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
    # Step 1: single-line substitutions via sed
    _TEAM_WORKING_DIR_RESOLVED="$(if [[ "$IS_PROJECT_TEAM" == "true" ]]; then echo "$TEAM_BASE_WORKING_DIR"; else echo "${TEAM_WORKING_DIR:-$AITEAMFORGE_DIR/$TEAM_ID}"; fi)"
    sed -e "s|{{TEAM_ID}}|$TEAM_ID|g" \
        -e "s|{{TEAM_NAME}}|$TEAM_NAME|g" \
        -e "s|{{TEAM_THEME}}|$TEAM_THEME|g" \
        -e "s|{{TEAM_SHIP}}|$TEAM_SHIP|g" \
        -e "s|{{TEAM_LCARS_PORT}}|$TEAM_LCARS_PORT|g" \
        -e "s|{{TEAM_TMUX_SOCKET}}|$TEAM_TMUX_SOCKET|g" \
        -e "s|{{TEAM_TERMINAL_LIST}}|$TEAM_TERMINAL_LIST|g" \
        -e "s|{{TEAM_WORKING_DIR}}|${_TEAM_WORKING_DIR_RESOLVED}|g" \
        -e "s|{{TEAM_REQUIRES_CLIENT}}|${REQUIRES_CLIENT}|g" \
        -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
        "$STARTUP_TEMPLATE" > "${STARTUP_SCRIPT}.tmp"

    # Step 2: multi-line substitution for per-agent window names via Python
    # {{TEAM_AGENT_WINDOWS_CONFIG}} may contain newlines which sed cannot handle
    python3 - "${STARTUP_SCRIPT}.tmp" "$STARTUP_SCRIPT" <<PYEOF
import sys
src, dst = sys.argv[1], sys.argv[2]
# Strip trailing newline then re-add one so the placeholder line is cleanly replaced
windows_config = """${TEAM_AGENT_WINDOWS_CONFIG}""".rstrip('\n')
if windows_config:
    windows_config += '\n'
with open(src) as f:
    content = f.read()
content = content.replace('{{TEAM_AGENT_WINDOWS_CONFIG}}\n', windows_config)
# Fallback: replace without trailing newline in case template line ending differs
if '{{TEAM_AGENT_WINDOWS_CONFIG}}' in content:
    content = content.replace('{{TEAM_AGENT_WINDOWS_CONFIG}}', windows_config.rstrip('\n'))
with open(dst, 'w') as f:
    f.write(content)
PYEOF
    rm -f "${STARTUP_SCRIPT}.tmp"
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
# GENERATE TEAM BANNER SCRIPT
# ============================================================================

echo "🎨 Generating team banner script..."

BANNER_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/team-banner.sh.template"
BANNER_SCRIPT="$TEAM_DIR/scripts/${TEAM_ID}-banner.sh"

if [[ -f "$BANNER_TEMPLATE" ]]; then
    # Convert TEAM_COLOR hex (#RRGGBB) to a best-effort xterm-256 color code.
    # We use Python for the conversion since it handles the math cleanly.
    # The 256-color cube starts at index 16; gray ramp starts at 232.
    _hex_to_256() {
        local hex="${1#\#}"  # Strip leading #
        python3 -c "
import sys

def nearest_256(r, g, b):
    def cube_val(n):
        return 0 if n == 0 else 55 + n * 40

    # Brute-force search the full 6x6x6 color cube (indices 16-231)
    best_cube_dist = float('inf')
    best_cube_idx = 16
    for ri in range(6):
        for gi in range(6):
            for bi in range(6):
                cr, cg, cb = cube_val(ri), cube_val(gi), cube_val(bi)
                d = (r-cr)**2 + (g-cg)**2 + (b-cb)**2
                if d < best_cube_dist:
                    best_cube_dist = d
                    best_cube_idx = 16 + 36*ri + 6*gi + bi

    # Search the gray ramp (indices 232-255, values 8, 18, 28 ... 238)
    best_gray_dist = float('inf')
    best_gray_idx = 232
    for i in range(24):
        gv = 8 + i * 10
        d = (r-gv)**2 + (g-gv)**2 + (b-gv)**2
        if d < best_gray_dist:
            best_gray_dist = d
            best_gray_idx = 232 + i

    return best_cube_idx if best_cube_dist <= best_gray_dist else best_gray_idx

h = sys.argv[1].lstrip('#')
r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
print(nearest_256(r, g, b))
" "$hex" 2>/dev/null || echo "178"
    }

    # Derive primary and secondary (slightly darker/lighter) color codes
    TEAM_COLOR_HEX="${TEAM_COLOR:-#5585CC}"
    PRIMARY_CODE=$(_hex_to_256 "$TEAM_COLOR_HEX")

    # Secondary: shift toward darker by biasing toward a lower cube index.
    # Simple approach: clamp primary - 36 (one cube "row" darker) or clamp to 16.
    if [[ "$PRIMARY_CODE" -ge 52 ]]; then
        SECONDARY_CODE=$((PRIMARY_CODE - 36))
    else
        SECONDARY_CODE=$((PRIMARY_CODE + 36))
        # Keep within valid range
        [[ "$SECONDARY_CODE" -gt 231 ]] && SECONDARY_CODE=231
    fi

    # Generate banner script by substituting template placeholders
    TEAM_BANNER_SCRIPT_NAME="${TEAM_ID}-banner.sh"
    sed -e "s|{{TEAM_ID}}|${TEAM_ID}|g" \
        -e "s|{{TEAM_NAME}}|${TEAM_NAME}|g" \
        -e "s|{{TEAM_SHIP}}|${TEAM_SHIP:-${TEAM_THEME}}|g" \
        -e "s|{{TEAM_BANNER_SCRIPT}}|${TEAM_BANNER_SCRIPT_NAME}|g" \
        -e "s|{{TEAM_COLOR_PRIMARY}}|${PRIMARY_CODE}|g" \
        -e "s|{{TEAM_COLOR_SECONDARY}}|${SECONDARY_CODE}|g" \
        "$BANNER_TEMPLATE" > "$BANNER_SCRIPT"
    chmod +x "$BANNER_SCRIPT"
    echo "  ✓ ${TEAM_ID}-banner.sh (primary color: ${PRIMARY_CODE}, secondary: ${SECONDARY_CODE})"
    echo "    Path: $BANNER_SCRIPT"
    echo "    Note: Edit color codes in the script to customize team themes"
else
    echo "  ⚠️  Banner template not found: $BANNER_TEMPLATE (skipping)"
fi

echo ""

# ============================================================================
# AGENT FUNCTION NAME LOOKUP
# Resolves the claude-* shell function name for a given team/agent pair.
# Most agents map directly to claude-<agent> (matching agent-aliases.sh).
# Exceptions (where character names differ from function names) are listed here.
# ============================================================================

_agent_function_name() {
    local team="$1" agent="$2"
    case "${team}/${agent}" in
        # Academy exceptions: character names differ from function names
        academy/chancellor) echo "claude-ake" ;;
        # Command exceptions
        command/admiral)    echo "claude-vance" ;;
        command/commodore)  echo "claude-ross" ;;
        # Default: claude-<agent> matches the function in agent-aliases.sh
        *)                  echo "claude-${agent}" ;;
    esac
}

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
        echo "  ✓ Alias: $(_agent_function_name "$TEAM_ID" "$agent")"
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
_first_agent_func=""
for agent in "${TEAM_AGENTS[@]}"; do
    _func="$(_agent_function_name "$TEAM_ID" "$agent")"
    echo "  ${_func}"
    [[ -z "$_first_agent_func" ]] && _first_agent_func="$_func"
done
echo ""
echo "Next steps:"
echo "  1. Source the aliases file: source $ALIASES_FILE"
echo "  2. Launch the team: $AITEAMFORGE_DIR/$TEAM_STARTUP_SCRIPT"
echo "  3. Start working with agents: ${_first_agent_func}"
echo ""
