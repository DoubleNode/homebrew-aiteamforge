#!/usr/bin/env zsh
# DNS Framework All Terminals Master Startup
# Launches all 8 Lower Decks-themed DNS Framework terminals in separate tabs
# Includes LCARS (Kanban Overview) as first tab

source "$HOME/dev-team/scripts/lcars-launch-helpers.sh" || { echo "fatal: scripts/lcars-launch-helpers.sh missing or unreadable" >&2; exit 1; }
source "$HOME/dev-team/scripts/kb-init-team-guard.sh" || true
# XACA-0804: startup IS setup intent — opt in unconditionally so
# kb_ensure_team_initialized below can bootstrap-write a missing registry.
export AITEAMFORGE_ALLOW_BOOTSTRAP_WRITE=1

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

clear

# Window name for iTerm2 (tabs will be created in this named window)
ITERM_WINDOW_NAME="DNS Team"

# ============================================================================
# FIRST: Capture the current window IMMEDIATELY before user can switch
# This prevents race conditions if user switches windows during startup
# ============================================================================
ITERM_STARTUP_LOG="/tmp/dns-startup-iterm2-$(date +%Y%m%d-%H%M%S).log"
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

echo "🚀 DNS FRAMEWORK TERMINAL INFRASTRUCTURE"
echo "   Star Trek: Lower Decks Theme"
echo "   USS Cerritos NCC-75567"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Cleanup orphaned processes from previous crashed sessions
cleanup_orphans

# Use separate tmux server for this team (prevents cross-team crashes)
export TMUX_SOCKET="dns"
echo "   tmux socket: $TMUX_SOCKET"

# Resolve LCARS port from the canonical registry (XACA-0590).
# resolve_lcars_port reads team-paths.json via kanban-hooks/lcars_ports.py —
# the same single source of truth used by kb-port-reconcile and lcars-health-check.sh.
# The legacy constant-input cksum produced 8180 which happens to match the canonical
# value; the resolver now makes the authority explicit and stable. The cksum band
# fallback is shared via resolve_lcars_port_fallback (XACA-0672) so dns-startup /
# dns-connect / dns-disconnect can never drift. (lcars-launch-helpers.sh is sourced
# above with a hard exit-1 guard, so the fallback function is always in scope here.)
LCARS_PORT="$(resolve_lcars_port "dns")" || \
    LCARS_PORT="$(resolve_lcars_port_fallback "dns-framework" 8180 20)"
echo "   LCARS Port: $LCARS_PORT"
echo ""

# Base terminal names (actual script filenames)
# LCARS is first - provides the kanban overview
base_terminals=(
    "lcars"
    "command"
    "bugbay"
    "testing"
    "build"
    "refactor"
    "apidesign"
    "docs"
)

# Terminal definitions with labels
declare -A terminals=(
    ["dns-lcars"]="LCARS"
    ["dns-command"]="command"
    ["dns-bugbay"]="bugbay"
    ["dns-testing"]="testing"
    ["dns-build"]="build"
    ["dns-refactor"]="refactor"
    ["dns-apidesign"]="apidesign"
    ["dns-docs"]="docs"
)

# Order of terminals
# LCARS is first tab - Kanban overview
terminal_order=(
    "dns-lcars"
    "dns-command"
    "dns-bugbay"
    "dns-testing"
    "dns-build"
    "dns-refactor"
    "dns-apidesign"
    "dns-docs"
)

# Guard: verify kanban board is initialized before any kanban-dependent work.
kb_ensure_team_initialized "dns" "/Users/Shared/Development/DNSFramework/kanban" || true

# Create tmux sessions ASYNCHRONOUSLY for faster startup
# Use bash (not zsh) since scripts use bash shebang and rely on word splitting
echo "📡 Creating tmux sessions (async for speed)..."
pids=()
for base_name in "${base_terminals[@]}"; do
    script="$HOME/dev-team/dns-framework/scripts/dns-${base_name}-startup.sh"
    session_name="dns-${base_name}"
    if [ -f "$script" ]; then
        echo "  Initializing $session_name..."
        # Run in background with bash
        SKIP_ATTACH=1 SKIP_SERVER_START=1 bash "$script" 2>&1 | grep -v "^$" | head -3 &
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
echo "🔥 Creating terminal tabs..."

# ── LCARS server: ALWAYS start it (GUI and headless) ──
# Headless hosts (SSH/cockpit-host) have no GUI tab to open but MUST serve LCARS
# so <team>-connect.sh can reach http://<host>:<port>/api/status. (XACA-0614)
echo "  Starting DNS LCARS server on port $LCARS_PORT..."
start_lcars_server "dns" "$LCARS_PORT" "dns-lcars" \
    || echo "    ⚠️  Continuing without a confirmed-ready LCARS server (see above)."

# ── Tabs: only when a GUI is present ──
if has_iterm_gui; then
    # iTerm2 automation using Python API for window management.
    for terminal in "${terminal_order[@]}"; do
        label="${terminals[$terminal]}"
        echo "  Opening tab: $terminal ($label)"

        # Create iTerm2 tab and attach to tmux session using Python API
        if [[ "$label" == "LCARS" ]]; then
            open_lcars_tab "$LCARS_PORT" "$ITERM_WINDOW_NAME" "LCARS" "$TMUX_SOCKET" "dns-lcars" "$ITERM_STARTUP_LOG" \
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
    echo "  Connect from a cockpit machine: dns-connect.sh <this-host>"
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
echo "✅ All DNS Framework terminals launched in separate tabs!"
echo ""
echo "📚 Terminal Guide:"
echo "  * LCARS      - Kanban Overview (Port $LCARS_PORT)"
echo "  * Agent      - Active Agent Display"
echo "  • command    - Mariner (Lead Feature Dev)"
echo "  • bugbay     - T'Ana (Bug Fix)"
echo "  • testing    - Shaxs (Lead Tester)"
echo "  • build      - Rutherford (Release Engineer)"
echo "  • refactor   - Tendi (Lead Refactoring)"
echo "  • apidesign  - Boimler (API Design)"
echo "  • docs       - Ransom (Documentation)"
echo ""
echo "📁 Working Directories:"
echo "  • iOS:      /Users/Shared/Development/DNSFramework/DNSFramework-iOS/ (28 repos)"
echo "  • Android:  /Users/Shared/Development/DNSFramework/DNSFramework-Android/ (1 repo)"
echo ""
echo "🎯 Kanban Commands Available in All Terminals:"
echo "  kb-plan \"task\"   - Start planning a task"
echo "  kb-code          - Move to coding phase"
echo "  kb-test          - Move to testing phase"
echo "  kb-done          - Mark task complete"
echo "  kb-show          - Display kanban board"
echo ""
echo "💡 Tip: Use 'Ctrl+B' then window number to switch tmux windows"
echo ""
echo "🔌 Remote Attach Commands:"
for terminal in "${terminal_order[@]}"; do
    echo "  tmux -L $TMUX_SOCKET attach -t $terminal"
done
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Report any iTerm2 errors
if [[ -n "$ITERM_STARTUP_LOG" ]] && [[ -s "$ITERM_STARTUP_LOG" ]]; then
    echo "⚠️  iTerm2 errors logged to: $ITERM_STARTUP_LOG"
fi

echo "USS Cerritos NCC-75567 ready for operations!"
