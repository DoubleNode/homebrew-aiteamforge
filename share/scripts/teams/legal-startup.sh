#!/usr/bin/env zsh
# Legal Team All Terminals Master Startup
# Launches all 7 Legal-themed terminals in separate tabs
# Includes LCARS (Kanban Overview) as first tab
#
# Usage: ./legal-startup.sh <PROJECTID>
# Example: ./legal-startup.sh coparenting

source "$HOME/dev-team/scripts/lcars-launch-helpers.sh" || { echo "fatal: scripts/lcars-launch-helpers.sh missing or unreadable" >&2; exit 1; }
source "$HOME/dev-team/scripts/kb-init-team-guard.sh" || true

# ============================================================================
# Require project ID argument BEFORE any other output
# ============================================================================
if [ $# -lt 1 ]; then
    echo "ERROR: Project ID required"
    echo "Usage: $0 <PROJECTID>"
    echo "Example: $0 coparenting"
    exit 1
fi

PROJECTID="$1"
export PROJECTID

# Calculate derived variables that child scripts expect
PROJECT_DIR="$HOME/legal/$PROJECTID"

# Create project-specific session names
PROJECT_LOWER=$(echo "$PROJECTID" | tr '[:upper:]' '[:lower:]')
SESSION_PREFIX="legal-${PROJECT_LOWER}"

# Resolve LCARS port from the canonical registry (XACA-0590).
# resolve_lcars_port reads team-paths.json via kanban-hooks/lcars_ports.py —
# the same single source of truth used by kb-port-reconcile and lcars-health-check.sh.
# Fall back to the legacy deterministic cksum derivation ONLY for prefixes not yet
# registered, preserving backward-compat for new projects. XACA-0609: hash the
# per-project ${PROJECT_LOWER} (not the constant "legal") so distinct projects get
# distinct fallback ports — parity with finance/medical. Legal keeps its own port
# band (8220 + cksum % 20); only the hash INPUT is unified.
LCARS_PORT_TEMP="$(resolve_lcars_port "${SESSION_PREFIX}")" || \
    LCARS_PORT_TEMP=$((8220 + $(echo "${PROJECT_LOWER}" | cksum | cut -d' ' -f1) % 20))

# Export variables that child scripts check for
export LEGAL_PROJECTID="$PROJECTID"
export LEGAL_PROJECT_DIR="$PROJECT_DIR"
export LEGAL_LCARS_PORT="$LCARS_PORT_TEMP"

# ============================================================================
# Cleanup orphaned processes from previous crashed sessions
# ============================================================================
cleanup_orphans() {
    # Kill any orphaned zsh processes that have no controlling terminal
    # and were spawned by tmux (their parent is init/launchd, PID 1)
    local orphans=$(ps -eo pid,ppid,tty,comm | grep zsh | grep "??" | awk '$2 == 1 {print $1}')
    if [[ -n "$orphans" ]]; then
        echo "  Cleaning up orphaned processes..."
        echo "$orphans" | xargs kill 2>/dev/null
    fi
}

clear

# Window name for iTerm2 (tabs will be created in this named window)
ITERM_WINDOW_NAME="Legal Team"

# ============================================================================
# FIRST: Capture the current window IMMEDIATELY before user can switch
# This prevents race conditions if user switches windows during startup
# ============================================================================
ITERM_STARTUP_LOG="/tmp/legal-startup-iterm2-$(date +%Y%m%d-%H%M%S).log"
if has_iterm_gui; then
    echo "  Capturing current window..."
    python3 ~/dev-team/iterm2_window_manager.py \
        --action init-team-window \
        --window-title "$ITERM_WINDOW_NAME" \
        2>>"$ITERM_STARTUP_LOG"
    if [[ $? -ne 0 ]]; then
        echo "  ⚠️  Window capture failed (see $ITERM_STARTUP_LOG)"
    fi
fi

echo "  LEGAL TEAM TERMINAL INFRASTRUCTURE"
echo "   Custody Case Support System"
echo "   Legal Case Management & Strategy"
echo ""

# Cleanup any orphaned processes from previous crashed sessions
cleanup_orphans

# Use separate tmux server for this team (prevents cross-team crashes)
export TMUX_SOCKET="legal"
echo "   tmux socket: $TMUX_SOCKET"

# Use the already-calculated LCARS port (exported as LEGAL_LCARS_PORT)
LCARS_PORT="$LEGAL_LCARS_PORT"
echo "   LCARS Port: $LCARS_PORT"
echo ""

# Guard: verify kanban board is initialized before any kanban-dependent work.
# XACA-0576: pass the TEMPLATE id ("legal"), not the project-scoped form.
# board-check resolves template→instance via get_board_id() and the config
# lookup tolerates either form. The previous raw-PROJECTID session handoff
# worked by accident when PROJECTID="coparenting" matched the canonical
# instance id; it would fail for any other PROJECTID.
kb_ensure_team_initialized "legal" "$PROJECT_DIR/kanban" || true

# XACA-0666: deploy this project's personas into $PROJECT_DIR/.claude/agents.
# Shared helper in lcars-launch-helpers.sh (sourced above) — see
# deploy_team_personas for the rationale (nested-git-root project dirs).
deploy_team_personas legal "Legal" "$PROJECT_DIR"

# Base terminal names (actual script filenames)
# LCARS is first - provides the kanban overview
base_terminals=(
    "lcars"
    "chambers"
    "discovery"
    "research"
    "filings"
    "mediation"
    "timeline"
)

# Terminal definitions with labels
# Session names now include project ID: legal-{projectid}-{terminal}
declare -A terminals=(
    ["${SESSION_PREFIX}-lcars"]="LCARS"
    ["${SESSION_PREFIX}-chambers"]="chambers"
    ["${SESSION_PREFIX}-discovery"]="discovery"
    ["${SESSION_PREFIX}-research"]="research"
    ["${SESSION_PREFIX}-filings"]="filings"
    ["${SESSION_PREFIX}-mediation"]="mediation"
    ["${SESSION_PREFIX}-timeline"]="timeline"
)

# Order of terminals
# LCARS is first tab - Kanban overview
terminal_order=(
    "${SESSION_PREFIX}-lcars"
    "${SESSION_PREFIX}-chambers"
    "${SESSION_PREFIX}-discovery"
    "${SESSION_PREFIX}-research"
    "${SESSION_PREFIX}-filings"
    "${SESSION_PREFIX}-mediation"
    "${SESSION_PREFIX}-timeline"
)

# Create tmux sessions ASYNCHRONOUSLY for faster startup
# Use bash (not zsh) since scripts use bash shebang and rely on word splitting
# NOTE: Earlier versions piped output through `head -3` which could SIGPIPE the
# child mid-setup, silently killing session creation. Output now goes to a log.
STARTUP_LOG="/tmp/legal-startup-sessions-$(date +%Y%m%d-%H%M%S).log"
echo "  Creating tmux sessions (async for speed)..."
echo "  (Session log: $STARTUP_LOG)"
pids=()
for base_name in "${base_terminals[@]}"; do
    script="$HOME/dev-team/legal/scripts/legal-${base_name}-startup.sh"
    session_name="${SESSION_PREFIX}-${base_name}"
    if [ -f "$script" ]; then
        echo "  Initializing $session_name..."
        # Run in background with bash, passing PROJECTID via environment
        SKIP_ATTACH=1 SKIP_SERVER_START=1 PROJECTID="$PROJECTID" \
            bash "$script" >>"$STARTUP_LOG" 2>&1 &
        pids+=($!)
        # Small delay to stagger tmux commands slightly
        sleep 0.3
    else
        echo "    Warning: $script not found"
    fi
done

# Wait for all background processes to complete
echo "  Waiting for sessions to initialize..."
for pid in "${pids[@]}"; do
    wait $pid 2>/dev/null
done

echo ""
echo "  All sessions initialized"
sleep 1

echo ""
echo "  Creating terminal tabs..."

# ── LCARS server: ALWAYS start it (GUI and headless) ──
# Headless hosts (SSH/cockpit-host) have no GUI tab to open but MUST serve LCARS
# so <team>-connect.sh can reach http://<host>:<port>/api/status. (XACA-0614)
# Session-name prefix uses the lowercased SESSION_PREFIX (XACA-0609).
# start_lcars_server writes the team line to lcars-target.js; append the session line after.
echo "  Starting Legal LCARS server on port $LCARS_PORT..."
start_lcars_server "${SESSION_PREFIX}" "$LCARS_PORT" "${SESSION_PREFIX}-lcars" \
    || echo "    ⚠️  Continuing without a confirmed-ready LCARS server (see above)."
echo "window.LCARS_TARGET_SESSION = '${SESSION_PREFIX}-lcars';" >> ~/dev-team/lcars-ui/lcars-target.js

# ── Tabs: only when a GUI is present ──
if has_iterm_gui; then
    # iTerm2 automation using Python API for window management.
    # Window was already initialized at script start, all tabs are created fresh.

    for terminal in "${terminal_order[@]}"; do
        label="${terminals[$terminal]}"
        echo "  Opening tab: $terminal ($label)"

        # Create iTerm2 tab and attach to tmux session
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
    echo "  Connect from a cockpit machine: legal-connect.sh <this-host> ${PROJECTID}"
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
    echo "  Switching to LCARS tab..."
    python3 ~/dev-team/iterm2_window_manager.py \
        --action select-tab \
        --window-title "$ITERM_WINDOW_NAME" \
        --tab-name "LCARS" \
        2>>"$ITERM_STARTUP_LOG"
fi

echo ""
echo "  All Legal terminals launched in separate tabs!"
echo ""
echo "  Terminal Guide:"
echo "  * LCARS      - Kanban Overview (Port $LCARS_PORT)"
echo "  * Agent      - Active Agent Display"
echo "  * chambers   - Denny Crane (Lead Counsel & Strategy)"
echo "  * discovery  - Jerry Espenson (Evidence Review & Analysis)"
echo "  * research   - Carl Sack (Case Law & Precedent)"
echo "  * filings    - Brad Chase (Motions & Pleadings)"
echo "  * mediation  - Alan Shore (Negotiation & Settlement)"
echo "  * timeline   - Shirley Schmidt (Deadlines & Calendar)"
echo ""
echo "  Kanban Commands Available in All Terminals:"
echo "  kb-plan \"task\"   - Start planning a task"
echo "  kb-code          - Move to coding phase"
echo "  kb-test          - Move to testing phase"
echo "  kb-done          - Mark task complete"
echo "  kb-show          - Display kanban board"
echo ""
echo "  Tip: Use 'Ctrl+B' then window number to switch tmux windows"
echo ""
echo "  Remote Attach Commands:"
for terminal in "${terminal_order[@]}"; do
    echo "  tmux -L $TMUX_SOCKET attach -t $terminal"
done
echo ""

# Report any iTerm2 errors
if [[ -n "$ITERM_STARTUP_LOG" ]] && [[ -s "$ITERM_STARTUP_LOG" ]]; then
    echo "⚠️  iTerm2 errors logged to: $ITERM_STARTUP_LOG"
fi

echo "Legal Team ready for duty!"
