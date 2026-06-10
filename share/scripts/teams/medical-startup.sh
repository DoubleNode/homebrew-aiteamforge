#!/bin/zsh
# Medical Team All Terminals Master Startup
# Launches all Medical terminals in separate tabs
# Includes LCARS (Kanban Overview) as first tab
# Usage: ./medical-startup.sh <PROJECTID>
# Example: ./medical-startup.sh clinic1

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

if [ $# -lt 1 ]; then
    echo "ERROR: Project ID required"
    echo "Usage: $0 <PROJECTID>"
    echo "Example: $0 clinic1"
    exit 1
fi

PROJECTID="$1"
PROJECT_DIR="$HOME/medical/${PROJECTID}"

# Validate directory exists
if [ ! -d "$PROJECT_DIR" ]; then
    echo "❌ Error: Project directory does not exist:"
    echo "   $PROJECT_DIR"
    echo ""
    echo "Please verify the PROJECTID is correct."
    exit 1
fi

echo "🏥 MEDICAL TEAM INFRASTRUCTURE"
echo "   Princeton-Plainsboro Teaching Hospital"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   Project: $PROJECTID"
echo "   Path:    $PROJECT_DIR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Cleanup orphaned processes from previous crashed sessions
cleanup_orphans

# Use separate tmux server for this team (prevents cross-team crashes)
export TMUX_SOCKET="medical"
echo "   tmux socket: $TMUX_SOCKET"

# Window name for iTerm2 (tabs will be created in this named window)
# Includes project name to support multiple medical projects simultaneously
ITERM_WINDOW_NAME="${PROJECTID}: Medical"

# ============================================================================
# CAPTURE: Lock the current window IMMEDIATELY to prevent race conditions
# ============================================================================
ITERM_STARTUP_LOG="/tmp/medical-startup-iterm2-$(date +%Y%m%d-%H%M%S).log"
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
PROJECT_LOWER=$(echo "$PROJECTID" | tr '[:upper:]' '[:lower:]')
SESSION_PREFIX="medical-${PROJECT_LOWER}"

# Guard: verify kanban board is initialized before any kanban-dependent work.
# XACA-0576: pass the TEMPLATE id ("medical"), not the project-scoped session
# prefix. board-check resolves template→instance via get_board_id() and the
# config lookup tolerates either form. Passing SESSION_PREFIX was masking
# real config issues with a misleading "unknown team" warning.
kb_ensure_team_initialized "medical" "$PROJECT_DIR/kanban" || true

# XACA-0666: Ensure this project's personas are deployed into
# $PROJECT_DIR/.claude/agents. Multi-project personal teams cd into
# ~/medical/<PROJECTID> — a nested git repo the static persona manifest cannot
# enumerate — so plain `kb-sync-personas sync` (umbrella target) never reaches
# it and a session here loads zero personas. The XACA-0660 nested-root deploy in
# `sync-worktrees` resolves and populates each inner git root. Idempotent:
# re-runs refresh on master persona changes. Guarded + non-fatal so a missing
# tool or non-dev host never blocks team startup.
if [ -x "$HOME/dev-team/scripts/kb-sync-personas" ]; then
    echo "   Syncing Medical personas into project dir..."
    "$HOME/dev-team/scripts/kb-sync-personas" sync-worktrees medical >/dev/null 2>&1 \
        || echo "   ⚠️  Persona sync skipped (non-fatal; run kb-sync-personas sync-worktrees medical)"
fi

# Resolve LCARS port from the canonical registry (XACA-0590).
# resolve_lcars_port reads team-paths.json via kanban-hooks/lcars_ports.py —
# the same single source of truth used by kb-port-reconcile and lcars-health-check.sh.
# Fall back to the legacy deterministic cksum derivation ONLY for prefixes not yet
# registered, preserving backward-compat for new/unregistered projects.
LCARS_PORT="$(resolve_lcars_port "${SESSION_PREFIX}")" || \
    LCARS_PORT=$((8300 + $(echo "${PROJECT_LOWER}" | cksum | cut -d' ' -f1) % 80))
echo "   LCARS Port: $LCARS_PORT"

# Base terminal names (actual script filenames)
# LCARS is first - provides the kanban overview
base_terminals=(
    "lcars"
    "diagnostics"
    "oncology"
    "immunology"
    "surgery"
    "neurology"
    "emergency"
)

# Terminal definitions with project-specific session names and labels
declare -A terminals=(
    ["${SESSION_PREFIX}-lcars"]="LCARS"
    ["${SESSION_PREFIX}-diagnostics"]="diagnostics"
    ["${SESSION_PREFIX}-oncology"]="oncology"
    ["${SESSION_PREFIX}-immunology"]="immunology"
    ["${SESSION_PREFIX}-surgery"]="surgery"
    ["${SESSION_PREFIX}-neurology"]="neurology"
    ["${SESSION_PREFIX}-emergency"]="emergency"
)

# Order of terminals (project-specific session names)
# LCARS is first tab - Kanban overview
terminal_order=(
    "${SESSION_PREFIX}-lcars"
    "${SESSION_PREFIX}-diagnostics"
    "${SESSION_PREFIX}-oncology"
    "${SESSION_PREFIX}-immunology"
    "${SESSION_PREFIX}-surgery"
    "${SESSION_PREFIX}-neurology"
    "${SESSION_PREFIX}-emergency"
)

# Create tmux sessions ASYNCHRONOUSLY for faster startup
# Use bash (not zsh) since scripts use bash shebang and rely on word splitting
# NOTE: Earlier versions piped output through `head -3` which could SIGPIPE the
# child mid-setup, silently killing session creation. Output now goes to a log.
STARTUP_LOG="/tmp/medical-startup-sessions-$(date +%Y%m%d-%H%M%S).log"
echo "📡 Creating tmux sessions (async for speed)..."
echo "  (Session log: $STARTUP_LOG)"
pids=()
for base_name in "${base_terminals[@]}"; do
    script="$HOME/dev-team/medical/scripts/medical-${base_name}-startup.sh"
    session_name="${SESSION_PREFIX}-${base_name}"
    if [ -f "$script" ]; then
        echo "  Initializing $session_name..."
        # Run in background with bash
        # Pass LCARS_PORT so the LCARS script can use the project-specific port
        SKIP_ATTACH=1 MEDICAL_PROJECTID="$PROJECTID" MEDICAL_PROJECT_DIR="$PROJECT_DIR" MEDICAL_LCARS_PORT="$LCARS_PORT" \
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
# start_lcars_server writes the team line to lcars-target.js; append the session line after.
echo "  Starting Medical LCARS server on port $LCARS_PORT..."
start_lcars_server "${SESSION_PREFIX}" "$LCARS_PORT" "${SESSION_PREFIX}-lcars" \
    || echo "    ⚠️  Continuing without a confirmed-ready LCARS server (see above)."
echo "window.LCARS_TARGET_SESSION = '${SESSION_PREFIX}-lcars';" >> ~/dev-team/lcars-ui/lcars-target.js

# ── Tabs: only when a GUI is present ──
if has_iterm_gui; then
    # iTerm2 automation using Python API for window management.
    for terminal in "${terminal_order[@]}"; do
        label="${terminals[$terminal]}"
        echo "  Opening tab: $terminal ($label)"

        # Create iTerm2 tab and attach to tmux session using Python API
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
    echo "  Connect from a cockpit machine: medical-connect.sh <this-host> ${PROJECTID}"
fi

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
echo "All Medical terminals launched in separate tabs!"
echo ""
echo "Available Sessions:"
tmux -L $TMUX_SOCKET list-sessions 2>/dev/null | grep "^${SESSION_PREFIX}-"
echo ""
echo "Medical Team Roster:"
echo "  * LCARS - Kanban Overview (Port $LCARS_PORT)"
echo "  * Agent - Active Agent Display"
echo "  * Dr. Gregory House - Diagnostics (Lead Feature Developer)"
echo "  * Dr. James Wilson - Oncology (Documentation Lead)"
echo "  * Dr. Allison Cameron - Immunology (Lead Tester)"
echo "  * Dr. Robert Chase - Surgery (Bug Fix Developer)"
echo "  * Dr. Eric Foreman - Neurology (Lead Refactoring Developer)"
echo "  * Dr. Lisa Cuddy - Emergency (Release Engineer)"
echo ""
echo "Kanban Commands Available in All Terminals:"
echo "  kb-plan \"task\"   - Start planning a task"
echo "  kb-code          - Move to coding phase"
echo "  kb-test          - Move to testing phase"
echo "  kb-done          - Mark task complete"
echo "  kb-show          - Display kanban board"
echo ""

# Report any iTerm2 errors
if [[ -n "$ITERM_STARTUP_LOG" ]] && [[ -s "$ITERM_STARTUP_LOG" ]]; then
    echo "⚠️  iTerm2 errors logged to: $ITERM_STARTUP_LOG"
fi

echo "Medical Team ready for diagnosis!"
