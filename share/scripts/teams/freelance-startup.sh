#!/usr/bin/env zsh
# Freelance All Terminals Master Startup
# Launches all 8 ENT-themed Freelance terminals in separate tabs
# Includes LCARS (Kanban Overview) as first tab
# Usage: ./freelance-startup.sh <GROUPID> <PROJECTID>
# Example: ./freelance-startup.sh AcmeCorp WidgetTracker

source "$HOME/dev-team/scripts/lcars-launch-helpers.sh" || { echo "fatal: scripts/lcars-launch-helpers.sh missing or unreadable" >&2; exit 1; }
source "$HOME/dev-team/scripts/kb-init-team-guard.sh" || true

# ============================================================================
# Cleanup orphaned processes from previous crashed sessions
# ============================================================================
cleanup_orphans() {
    local orphans=$(ps -eo pid,ppid,tty,comm | grep zsh | grep "??" | awk '$2 == 1 {print $1}')
    if [[ -n "$orphans" ]]; then
        echo "  Cleaning up orphaned processes..."
        echo "$orphans" | xargs kill 2>/dev/null
    fi
}

# Check for required parameters
clear

if [ $# -lt 2 ]; then
    echo "❌ Error: Missing required parameters"
    echo ""
    echo "Usage: $0 <GROUPID> <PROJECTID>"
    echo ""
    echo "Examples:"
    echo "  $0 AcmeCorp WidgetTracker"
    echo "  $0 ClientCorp ProjectName"
    echo ""
    echo "This will set the project directory to:"
    echo "  /Users/Shared/Development/<GROUPID>/<PROJECTID>/develop/"
    echo ""
    exit 1
fi

GROUPID="$1"
PROJECTID="$2"
PROJECT_DIR="/Users/Shared/Development/${GROUPID}/${PROJECTID}/develop"

# Validate directory exists
if [ ! -d "$PROJECT_DIR" ]; then
    echo "❌ Error: Project directory does not exist:"
    echo "   $PROJECT_DIR"
    echo ""
    echo "Please verify the GROUPID and PROJECTID are correct."
    exit 1
fi

echo "🚀 FREELANCE TERMINAL INFRASTRUCTURE"
echo "   Star Trek: Enterprise Theme"
echo "   Enterprise NX-01"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   Group:   $GROUPID"
echo "   Project: $PROJECTID"
echo "   Path:    $PROJECT_DIR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Cleanup orphaned processes from previous crashed sessions
cleanup_orphans

# Use separate tmux server for this team (prevents cross-team crashes)
export TMUX_SOCKET="freelance"
echo "   tmux socket: $TMUX_SOCKET"

# Window name for iTerm2 (tabs will be created in this named window)
# Includes project name to support multiple freelance projects simultaneously
ITERM_WINDOW_NAME="${PROJECTID} / ${GROUPID} : Freelance"

# ============================================================================
# CAPTURE: Lock the current window IMMEDIATELY to prevent race conditions
# ============================================================================
ITERM_STARTUP_LOG="/tmp/freelance-startup-iterm2-$(date +%Y%m%d-%H%M%S).log"
if has_iterm_gui; then
    echo "🔒 Capturing current window..."
    python3 ~/dev-team/iterm2_window_manager.py \
        --action init-team-window \
        --window-title "$ITERM_WINDOW_NAME" \
        2>>"$ITERM_STARTUP_LOG"
    if [[ $? -ne 0 ]]; then
        echo "  ⚠️  Window capture failed (see $ITERM_STARTUP_LOG)"
    fi
fi

# Create project-specific session names
GROUP_LOWER=$(echo "$GROUPID" | tr '[:upper:]' '[:lower:]')
PROJECT_LOWER=$(echo "$PROJECTID" | tr '[:upper:]' '[:lower:]')
SESSION_PREFIX="freelance-${GROUP_LOWER}-${PROJECT_LOWER}"

# Guard: verify kanban board is initialized before any kanban-dependent work.
# Kanban dir is at the project root (parent of the 'develop' worktree), not inside it.
kb_ensure_team_initialized "$SESSION_PREFIX" "$(dirname "$PROJECT_DIR")/kanban" || true

# Resolve LCARS port from the canonical registry (XACA-0590).
# resolve_lcars_port reads team-paths.json via kanban-hooks/lcars_ports.py —
# the same single source of truth used by kb-port-reconcile and lcars-health-check.sh.
# This supersedes the prior XACA-0549 .port-file-read approach with the authoritative
# registry query (team-paths.json wins, DEFAULT_TEAMS fallback).
# Fall back to the legacy deterministic cksum derivation ONLY for prefixes not yet
# registered, preserving backward-compat for ad-hoc projects.
LCARS_PORT="$(resolve_lcars_port "${SESSION_PREFIX}")" || \
    LCARS_PORT=$((8080 + $(echo "${GROUP_LOWER}-${PROJECT_LOWER}" | cksum | cut -d' ' -f1) % 900))
echo "   LCARS Port: $LCARS_PORT"

# Base terminal names (actual script filenames)
# LCARS is first - provides the kanban overview
base_terminals=(
    "lcars"
    "command"
    "engineering"
    "science"
    "sickbay"
    "tactical"
    "comms"
    "helm"
)

# Terminal definitions with project-specific session names and labels
declare -A terminals=(
    ["${SESSION_PREFIX}-lcars"]="LCARS"
    ["${SESSION_PREFIX}-command"]="command"
    ["${SESSION_PREFIX}-engineering"]="engineering"
    ["${SESSION_PREFIX}-science"]="science"
    ["${SESSION_PREFIX}-sickbay"]="sickbay"
    ["${SESSION_PREFIX}-tactical"]="tactical"
    ["${SESSION_PREFIX}-comms"]="comms"
    ["${SESSION_PREFIX}-helm"]="helm"
)

# Order of terminals (project-specific session names)
# LCARS is first tab - Kanban overview
terminal_order=(
    "${SESSION_PREFIX}-lcars"
    "${SESSION_PREFIX}-command"
    "${SESSION_PREFIX}-engineering"
    "${SESSION_PREFIX}-science"
    "${SESSION_PREFIX}-sickbay"
    "${SESSION_PREFIX}-tactical"
    "${SESSION_PREFIX}-comms"
    "${SESSION_PREFIX}-helm"
)

# Developer data for agent panel pre-seeding (terminal_label → developer|role|theme|location|description)
declare -A terminal_devdata=(
    ["command"]="Captain Jonathan Archer|Lead Feature Developer|COMMAND|ENT: Enterprise NX-01 Bridge|FREELANCE COMMAND - STRATEGIC DEVELOPMENT"
    ["engineering"]="Commander Charles 'Trip' Tucker III|Release Engineer & CI/CD|OPERATIONS|ENT: Main Engineering|FREELANCE ENGINEERING - RELEASE MANAGEMENT"
    ["science"]="Sub-Commander T'Pol|Lead Refactoring Developer|SCIENCE|ENT: Science Lab|FREELANCE SCIENCE - CODE REFACTORING"
    ["sickbay"]="Dr. Phlox|Bug Fix Developer|SCIENCE|ENT: Sickbay|FREELANCE SICKBAY - BUG DIAGNOSIS"
    ["tactical"]="Lieutenant Malcolm Reed|Security & Test Lead|OPERATIONS|ENT: Tactical Station|FREELANCE TACTICAL - SECURITY & TESTING"
    ["comms"]="Ensign Hoshi Sato|Documentation Lead|SCIENCE|ENT: Communications Station|FREELANCE COMMS - DOCUMENTATION"
    ["helm"]="Ensign Travis Mayweather|UX/UI Developer|OPERATIONS|ENT: Helm Station|FREELANCE HELM - UX DESIGN"
)

# Create tmux sessions ASYNCHRONOUSLY for faster startup
# Use bash (not zsh) since scripts use bash shebang and rely on word splitting
# NOTE: Earlier versions piped output through `head -3` which could SIGPIPE the
# child mid-setup, silently killing session creation. Output now goes to a log.
STARTUP_LOG="/tmp/freelance-startup-sessions-$(date +%Y%m%d-%H%M%S).log"
echo "📡 Creating tmux sessions (async for speed)..."
echo "  (Session log: $STARTUP_LOG)"
pids=()
for base_name in "${base_terminals[@]}"; do
    script="$HOME/dev-team/freelance/scripts/freelance-${base_name}-startup.sh"
    session_name="${SESSION_PREFIX}-${base_name}"
    if [ -f "$script" ]; then
        echo "  Initializing $session_name..."
        # Run in background with bash
        # Pass LCARS_PORT so the LCARS script can use the project-specific port
        SKIP_ATTACH=1 SKIP_SERVER_START=1 FREELANCE_GROUPID="$GROUPID" FREELANCE_PROJECTID="$PROJECTID" FREELANCE_PROJECT_DIR="$PROJECT_DIR" FREELANCE_LCARS_PORT="$LCARS_PORT" \
            bash "$script" >>"$STARTUP_LOG" 2>&1 &
        pids+=($!)
        # Small delay to stagger tmux commands slightly
        sleep 0.3
    else
        echo "  ⚠️  Warning: $script not found"
    fi
done

# Wait for all background processes to complete
echo "  Waiting for sessions to initialize..."
for pid in "${pids[@]}"; do
    wait $pid 2>/dev/null
done

echo ""
echo "✅ All sessions initialized"
sleep 1

echo ""
echo "🚀 Creating terminal tabs..."

# ── LCARS server: ALWAYS start it (GUI and headless) ──
# Headless hosts (SSH/cockpit-host) have no GUI tab to open but MUST serve LCARS
# so <team>-connect.sh can reach http://<host>:<port>/api/status. (XACA-0614)
# start_lcars_server writes the team line to the RUNTIME target file; append
# the session line to the SAME file. XACA-0798: that file is
# ~/.aiteamforge/lcars-target.js (via lcars_runtime_target_file), NOT
# lcars-ui/lcars-target.js — lcars-ui/ is the lcars-watch WatchPaths dir and
# writing there made every startup restart (and SIGTERM) every LCARS server.
echo "  Starting Freelance LCARS server on port $LCARS_PORT..."
start_lcars_server "${SESSION_PREFIX}" "$LCARS_PORT" "${SESSION_PREFIX}-lcars" \
    || echo "    ⚠️  Continuing without a confirmed-ready LCARS server (see above)."
echo "window.LCARS_TARGET_SESSION = '${SESSION_PREFIX}-lcars';" >> "$(lcars_runtime_target_file)"

# ── Tabs: only when a GUI is present ──
if has_iterm_gui; then
    # iTerm2 automation using Python API for window management.

    # ── All tabs ──
    for terminal in "${terminal_order[@]}"; do
        label="${terminals[$terminal]}"
        echo "  Opening tab: $terminal ($label)"

        # LCARS uses inline browser profile; agents use Default terminal
        if [[ "$label" == "LCARS" ]]; then
            open_lcars_tab "$LCARS_PORT" "$ITERM_WINDOW_NAME" "LCARS" "$TMUX_SOCKET" "${SESSION_PREFIX}-lcars" "$ITERM_STARTUP_LOG" \
                || echo "    ❌ Failed to open LCARS tab (see $ITERM_STARTUP_LOG)"
            sleep 0.3
            continue
        fi

        # Create tab with retry on failure
        tab_created=false
        for attempt in 1 2 3; do
            python3 ~/dev-team/iterm2_window_manager.py \
                --action create-tab \
                --window-title "$ITERM_WINDOW_NAME" \
                --profile "Default" \
                --tab-name "$label" \
                --command "export ITERM_TAB_TITLE='$label' && tmux -L $TMUX_SOCKET attach -t $terminal" \
                2>>"$ITERM_STARTUP_LOG"
            if [[ $? -eq 0 ]]; then
                tab_created=true
                break
            fi
            echo "    ⚠️  Tab creation attempt $attempt failed, retrying..." >&2
            sleep 1
        done
        if [[ "$tab_created" != "true" ]]; then
            echo "    ❌ Failed to create tab: $label (see $ITERM_STARTUP_LOG)"
        fi

        sleep 0.3
    done
elif ! is_headless; then
    # Terminal.app automation
    for terminal in "${terminal_order[@]}"; do
        label="${terminals[$terminal]}"
        echo "  Opening tab: $terminal ($label)"

        osascript <<EOF
tell application "Terminal"
    activate
    tell application "System Events"
        tell process "Terminal"
            keystroke "t" using command down
        end tell
    end tell
    delay 0.5
    do script "printf '\\\\033]0;$label\\\\007' && tmux -L $TMUX_SOCKET attach -t $terminal" in front window
end tell
EOF
        sleep 0.5
    done
else
    echo "  Headless host: tmux sessions + LCARS server are up; no GUI tabs created."
    echo "  Connect from a cockpit machine: freelance-connect.sh <this-host> ${GROUPID} ${PROJECTID}"
fi

echo ""

# Pre-seed agent panel JSON files so panels show data immediately (not "Awaiting agent...")
# This writes initial data BEFORE creating agent panel split panes.
# When the full banner runs inside tmux later, it overwrites with complete data.
echo "📋 Pre-seeding agent panel data..."
source ~/dev-team/scripts/display-agent-avatar.sh
for terminal in "${terminal_order[@]}"; do
    label="${terminals[$terminal]}"
    [[ "$label" == "LCARS" ]] && continue

    devdata="${terminal_devdata[$label]}"
    [[ -z "$devdata" ]] && continue

    IFS='|' read -r dev_name dev_role dev_theme dev_location dev_desc <<< "$devdata"

    # Set environment variables expected by display_agent_avatar
    SESSION_CODE="$terminal"
    SESSION_ROLE="$dev_role"
    SESSION_LOCATION="$dev_location"
    SESSION_DESCRIPTION="$dev_desc"
    SESSION_THEME="$dev_theme"
    TERMINAL_NAME="general"
    TERMINAL_DESCRIPTION="Starting up..."
    TERMINAL_NUMBER=""

    display_agent_avatar "freelance" "$dev_name"
done
echo ""

# Add Agent Panel WebView pane to each terminal tab
if has_iterm_gui; then
    echo "🎨 Adding agent panels to terminal tabs..."

    # Wait for iTerm2 Python API to become ready (may lag after launch)
    api_ready=false
    for wait_attempt in 1 2 3 4 5; do
        if python3 ~/dev-team/iterm2_window_manager.py \
            --action select-tab \
            --window-title "$ITERM_WINDOW_NAME" \
            --tab-name "LCARS" \
            2>/dev/null; then
            api_ready=true
            break
        fi
        echo "    ⏳ Waiting for iTerm2 API (attempt $wait_attempt/5)..."
        sleep 2
    done

    if [[ "$api_ready" != "true" ]]; then
        echo "    ⚠️  iTerm2 API not ready after 10s — agent panels may not open"
    fi

    for terminal in "${terminal_order[@]}"; do
        label="${terminals[$terminal]}"
        [[ "$label" == "LCARS" ]] && continue

        panel_created=false
        for attempt in 1 2 3; do
            python3 ~/dev-team/iterm2_window_manager.py \
                --action split-agent-panel \
                --window-title "$ITERM_WINDOW_NAME" \
                --tab-name "$label" \
                --command "~/dev-team/scripts/agent-panel-display.sh $terminal" \
                2>>"$ITERM_STARTUP_LOG"
            if [[ $? -eq 0 ]]; then
                panel_created=true
                break
            fi
            echo "    ⚠️  Panel split attempt $attempt failed for $label, retrying..." >&2
            sleep 1
        done
        if [[ "$panel_created" != "true" ]]; then
            echo "    ❌ Failed to create agent panel: $label (see $ITERM_STARTUP_LOG)"
        fi

        sleep 0.3
    done
fi

echo ""

# Switch to the LCARS tab after all tabs are created
if has_iterm_gui; then
    echo "🎯 Switching to LCARS tab..."
    python3 ~/dev-team/iterm2_window_manager.py \
        --action select-tab \
        --window-title "$ITERM_WINDOW_NAME" \
        --tab-name "LCARS" \
        2>>"$ITERM_STARTUP_LOG"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "All Freelance terminals launched in separate tabs!"
echo ""
echo "Available Sessions (61 total windows across 8 terminals):"
tmux -L $TMUX_SOCKET list-sessions 2>/dev/null | grep "^${SESSION_PREFIX}-"
echo ""
echo "Freelance Team Roster:"
echo "  * LCARS - Kanban Overview (Port $LCARS_PORT)"
echo "  * Agent     - Active Agent Display"
echo "  * Captain Jonathan Archer - Command (Strategic Development)"
echo "  * Commander Trip Tucker - Engineering (Release Management)"
echo "  * Sub-Commander T'Pol - Science (Code Refactoring)"
echo "  * Dr. Phlox - Sickbay (Bug Diagnosis)"
echo "  * Lt. Malcolm Reed - Tactical (Security & Testing)"
echo "  * Ensign Hoshi Sato - Communications (Documentation)"
echo "  * Ensign Travis Mayweather - Helm (UX Design)"
echo ""
echo "Kanban Commands Available in All Terminals:"
echo "  kb-plan \"task\"   - Start planning a task"
echo "  kb-code          - Move to coding phase"
echo "  kb-test          - Move to testing phase"
echo "  kb-done          - Mark task complete"
echo "  kb-show          - Display kanban board"
echo ""
echo "🔌 Remote Attach Commands:"
for terminal in "${terminal_order[@]}"; do
    echo "  tmux -L $TMUX_SOCKET attach -t $terminal"
done
echo ""

# Report any iTerm2 errors
if [[ -n "$ITERM_STARTUP_LOG" ]] && [[ -s "$ITERM_STARTUP_LOG" ]]; then
    echo "⚠️  iTerm2 errors logged to: $ITERM_STARTUP_LOG"
fi

echo "Enterprise NX-01 ready for exploration!"
