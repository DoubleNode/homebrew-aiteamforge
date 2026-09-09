#!/usr/bin/env zsh
# DNS Framework Connect Script (single-instance, DYNAMIC PORT — XACA-0605)
# Hand-authored (NOT rendered): DNS is a fleet-runtime team with no tap conf,
# maintained as a one-off in the repo root alongside dns-startup.sh.
#
# Opens an iTerm2 window pointed at a REMOTE machine's running DNS team via SSH.
# Pure viewer — no remote mutations, no startup, no cleanup, no port forwards.
#
# Unlike the projects-enabled parametric teams (finance/freelance/legal/medical/
# mainevent), DNS runs ONE LCARS server + ONE tmux session-set. Its umbrella
# sub-repos (DNSProtocols, DNSCore, …) are kanban-level routing (the `subRepo`
# field), NOT separate LCARS instances — so connect takes a HOST ONLY, no
# project argument (XACA-0605 design decision). The remote port is discovered
# at runtime (it may have been self-healed by the port-drift guard, XACA-0626),
# never hardcoded.

# ============================================================================
# Configuration
# ============================================================================
# shellcheck disable=SC1083,SC2039
TEAM_ID="dns"
# shellcheck disable=SC1083,SC2039
TEAM_NAME="DNS Framework"
# shellcheck disable=SC1083,SC2039
TEAM_THEME="Star Trek: Lower Decks"
# shellcheck disable=SC1083,SC2039
AITEAMFORGE_DIR="$HOME/dev-team"
# shellcheck disable=SC1083,SC2039
TMUX_SOCKET="dns"
# Agent sessions (non-LCARS). Mirror dns-startup.sh's session set:
# dns-lcars + dns-<agent> for each of these.
# shellcheck disable=SC1083,SC2039
AGENTS=(command bugbay testing build refactor apidesign docs)

# ============================================================================
# Usage / host argument
# ============================================================================
if [[ $# -lt 1 ]]; then
    echo ""
    echo "  Usage: $(basename "$0") <host>"
    echo ""
    echo "  <host>   Tailscale MagicDNS name or SSH-reachable hostname"
    echo "           Example: $(basename "$0") darren-m1pro"
    echo ""
    echo "  Opens an iTerm2 window connected to ${TEAM_NAME} running on <host>."
    echo "  The team must already be running on the remote machine."
    echo "  To start it: ssh <host> && ${TEAM_ID}-startup.sh"
    echo ""
    echo "  DNS is single-instance — there is NO project argument. Its sub-repos"
    echo "  (DNSProtocols, DNSCore, …) are kanban routing, not separate cockpits."
    echo ""
    exit 2
fi

HOST="$1"
ITERM_WINDOW_NAME="${TEAM_NAME} @ ${HOST}"
ITERM_CONNECT_LOG="/tmp/${TEAM_ID}-connect-iterm2-$(date +%Y%m%d-%H%M%S).log"

# ============================================================================
# Local pre-flight checks
# ============================================================================
PREFLIGHT_ERRORS=0

preflight_check() {
    local name="$1" cmd="$2" fix="$3"
    if ! command -v "$cmd" &>/dev/null; then
        echo "  ✗ $name not found"
        echo "    Fix: $fix"
        PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
    fi
}

preflight_check "python3" "python3" "brew install python@3"

if [[ ! -d "/Applications/iTerm.app" ]]; then
    echo "  ✗ iTerm2 not found"
    echo "    Fix: brew install --cask iterm2"
    PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
fi

if [[ -d "/Applications/iTerm.app" ]]; then
    _api=$(defaults read com.googlecode.iterm2 EnableAPIServer 2>/dev/null || true)
    if [[ "$_api" != "1" ]]; then
        echo "  Enabling iTerm2 Python API..."
        defaults write com.googlecode.iterm2 EnableAPIServer -bool true
        echo "  ⚠ iTerm2 must be restarted for Python API to activate."
        echo "    Please quit and restart iTerm2, then run this script again."
        exit 1
    fi
fi

if [[ ! -f "$AITEAMFORGE_DIR/iterm2_window_manager.py" && ! -f "$AITEAMFORGE_DIR/scripts/iterm2_window_manager.py" ]]; then
    echo "  ✗ Window manager not found"
    echo "    Fix: aiteamforge setup"
    PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
fi

if [[ $PREFLIGHT_ERRORS -gt 0 ]]; then
    echo ""
    echo "  $PREFLIGHT_ERRORS pre-flight check(s) failed. Aborting."
    exit 1
fi

# Resolve window manager path
WM="$AITEAMFORGE_DIR/iterm2_window_manager.py"
[[ ! -f "$WM" ]] && WM="$AITEAMFORGE_DIR/scripts/iterm2_window_manager.py"

# Use venv Python for iterm2 module (system Python may not have it)
VENV_PYTHON="$HOME/.aiteamforge/venv/bin/python3"
[[ ! -x "$VENV_PYTHON" ]] && VENV_PYTHON="$AITEAMFORGE_DIR/.venv/bin/python3"
[[ ! -x "$VENV_PYTHON" ]] && VENV_PYTHON="python3"

# ============================================================================
# Dynamic LCARS port resolution (XACA-0605)
# DNS resolves its port at runtime, not from a hardcoded constant:
#   1. serving_port — the REMOTE host's actual running port (its .port file).
#   2. canonical_port — this cockpit's registry (resolve_lcars_port "dns").
#   3. cksum band fallback — mirrors dns-startup.sh's 8180 + hash%20.
# If serving and canonical both resolve and differ, warn (non-fatal, XACA-0608).
# ============================================================================
SERVING_PORT="$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" \
    "/bin/zsh -lc 'cat ~/aiteamforge/lcars-ports/${TEAM_ID}-lcars.port 2>/dev/null || cat ~/dev-team/lcars-ports/${TEAM_ID}-lcars.port 2>/dev/null'" \
    2>/dev/null | head -1 | tr -dc '0-9')"

CANONICAL_PORT=""
# shellcheck source=/dev/null
if [[ -f "$AITEAMFORGE_DIR/scripts/lcars-launch-helpers.sh" ]]; then
    source "$AITEAMFORGE_DIR/scripts/lcars-launch-helpers.sh" 2>/dev/null || true
    if typeset -f resolve_lcars_port >/dev/null 2>&1; then
        CANONICAL_PORT="$(resolve_lcars_port "$TEAM_ID" 2>/dev/null | tr -dc '0-9')"
    fi
fi
# Fallback stub (XACA-0674-008): if the helper was missing, define a no-op gate
# so the iTerm checks below degrade silently to "not an iTerm GUI" instead of
# emitting 'command not found: has_iterm_gui' to stderr.
if ! command -v has_iterm_gui >/dev/null 2>&1; then
    has_iterm_gui() { false; }
fi

if [[ -n "$SERVING_PORT" && -n "$CANONICAL_PORT" && "$SERVING_PORT" != "$CANONICAL_PORT" ]]; then
    echo "  ⚠ port drift: ${HOST} serving ${SERVING_PORT} but canonical is ${CANONICAL_PORT} (see XACA-0608)"
fi

LCARS_PORT="$SERVING_PORT"
[[ -z "$LCARS_PORT" ]] && LCARS_PORT="$CANONICAL_PORT"
# cksum band fallback — shared resolve_lcars_port_fallback (XACA-0672) is the single
# source of the band, so this value always matches dns-startup.sh / dns-disconnect.sh.
# Sourced in the CANONICAL_PORT block above, so the function is in scope when present.
if [[ -z "$LCARS_PORT" ]] && typeset -f resolve_lcars_port_fallback >/dev/null 2>&1; then
    # XACA-0853: the literal "dns-framework" and range 20 below are LOAD-BEARING and
    # must NOT be "harmonized" with dns.conf's TEAM_LCARS_PORT_BASE=8180 / RANGE=10.
    # resolve_lcars_port_fallback computes base + cksum(input) % range, so the input
    # STRING and the range determine the port, not just the base. Measured:
    #     "dns-framework" 8180 20  -> 8180   <-- canonical, matches aiteamforge_paths.py
    #     "dns"           8180 10  -> 8187   <-- what "consistency" would produce
    # The mismatch with TEAM_ID and with the conf's range looks like a bug and is not.
    # PRECISELY: the INPUT STRING is what is load-bearing. cksum("dns-framework")
    # = 2744192700, which is divisible by 20, 10 and 5 alike, so the range is
    # currently INERT — swapping 20 for 10 still yields 8180. Do not read that as
    # permission to "tidy" the range: it is inert only for this particular cksum,
    # and changing the string is what actually moves the port (to 8187).
    LCARS_PORT="$(resolve_lcars_port_fallback "dns-framework" 8180 20)"
fi

# ============================================================================
# Resolve remote AITeamForge dir (XACA-1006-004)
# AITEAMFORGE_DIR above is the LOCAL install dir (this machine, running the
# connect script) — it is NOT valid on ${HOST}. The agent-panel command below
# runs on the REMOTE host via ssh, so it needs its own, separately-resolved
# remote path. Shared helper does a FILE probe (scripts/agent-panel-display.sh),
# not a directory-existence probe, across the tap-install / ~/aiteamforge /
# ~/dev-team candidates, and fails loudly rather than guessing. Hard
# dependency — do NOT soft-source with `|| true` (see the helper's header).
# ============================================================================
# shellcheck source=/dev/null
if ! source "${AITEAMFORGE_DIR}/scripts/lcars-remote-atf-resolve.sh"; then
    echo "  ✗ FATAL: required helper scripts/lcars-remote-atf-resolve.sh" >&2
    echo "    not found under \$AITEAMFORGE_DIR. Run 'aiteamforge upgrade'." >&2
    exit 1
fi
if ! REMOTE_ATF_DIR="$(lcars_resolve_remote_atf_dir "$HOST")"; then
    exit 1
fi

# ============================================================================
# Fail-fast remote preflight
# No retries. No auto-start. No remote mutations.
# ============================================================================
[[ -t 1 ]] && clear

echo ""
echo "  ${TEAM_NAME} @ ${HOST}"
echo "   ${TEAM_THEME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Checking remote host: ${HOST}"

_lcars_ok=false
_tmux_ok=false

# Probe 1: LCARS reachability
echo "  Checking LCARS:  http://${HOST}:${LCARS_PORT}/api/status ..."
if curl -sf --max-time 3 "http://${HOST}:${LCARS_PORT}/api/status" > /dev/null 2>&1; then
    _lcars_ok=true
    echo "    ✓ LCARS responding"
else
    echo "    ✗ LCARS not responding"
fi

# Probe 2: tmux session existence (uses the first agent as the sentinel)
# shellcheck disable=SC2086
_first_agent="${AGENTS[1]}"
echo "  Checking tmux:   ${TEAM_ID}-${_first_agent} on socket ${TMUX_SOCKET} ..."
# shellcheck disable=SC2029
if ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" \
    "/bin/zsh -lc 'tmux -L ${TMUX_SOCKET} has-session -t ${TEAM_ID}-${_first_agent}'" 2>/dev/null; then
    _tmux_ok=true
    echo "    ✓ tmux session found"
else
    echo "    ✗ tmux session not found"
fi

# Fail fast if either probe failed
if [[ "$_lcars_ok" != "true" || "$_tmux_ok" != "true" ]]; then
    echo ""
    echo "  ✗ ${TEAM_NAME} is not running on ${HOST}"

    if [[ "$_lcars_ok" != "true" ]]; then
        echo "    LCARS:  http://${HOST}:${LCARS_PORT} — not responding"
    fi
    if [[ "$_tmux_ok" != "true" ]]; then
        echo "    tmux:   socket '${TMUX_SOCKET}' on ${HOST} — no sessions"
    fi

    echo ""
    echo "    SSH to ${HOST} and run: ${TEAM_ID}-startup.sh"
    echo ""
    exit 1
fi

echo ""
echo "  Remote checks passed. Opening iTerm2 window..."
echo ""

# ============================================================================
# Capture the current iTerm2 window BEFORE user can switch
# ============================================================================
if has_iterm_gui; then
    echo "  Capturing current window..."
    "$VENV_PYTHON" "$WM" \
        --action init-team-window \
        --window-title "$ITERM_WINDOW_NAME" \
        2>>"$ITERM_CONNECT_LOG"
    # shellcheck disable=SC2181
    if [[ $? -ne 0 ]]; then
        echo "  Warning: Window capture failed (see $ITERM_CONNECT_LOG)"
    fi
fi

# ============================================================================
# Create iTerm2 tabs
# ============================================================================
echo "  Creating terminal tabs..."

if has_iterm_gui; then

    # ------------------------------------------------------------------
    # LCARS tab — update the LCARS Web profile URL to the REMOTE host
    # BEFORE creating the tab so the inline browser loads the remote dash.
    # ------------------------------------------------------------------
    LCARS_BROWSER_SCRIPT="$AITEAMFORGE_DIR/scripts/set-lcars-profile-browser.py"
    if [[ -f "$LCARS_BROWSER_SCRIPT" ]]; then
        echo "  Updating LCARS profile URL to http://${HOST}:${LCARS_PORT} ..."
        "$VENV_PYTHON" "$LCARS_BROWSER_SCRIPT" "http://${HOST}:${LCARS_PORT}" 2>/dev/null
    fi

    LCARS_OPENED=false
    if [[ -f "$LCARS_BROWSER_SCRIPT" ]]; then
        echo "  Opening LCARS tab..."
        _lcars_tab_err=$( "$VENV_PYTHON" "$WM" \
            --action create-tab \
            --window-title "$ITERM_WINDOW_NAME" \
            --profile "LCARS Web" \
            --tab-name "LCARS" \
            --command "export ITERM_TAB_TITLE='LCARS' && ${AITEAMFORGE_DIR}/scripts/remote-tmux-attach.sh ${HOST} ${TMUX_SOCKET} ${TEAM_ID}-lcars" \
            2>&1 )
        _lcars_tab_exit=$?
        if [[ $_lcars_tab_exit -eq 0 ]]; then
            LCARS_OPENED=true
        else
            echo "  Warning: iTerm2 LCARS tab failed (exit $_lcars_tab_exit)" >&2
            if [[ -n "$_lcars_tab_err" ]]; then
                echo "  Reason: $_lcars_tab_err" >&2
            fi
            echo "  Possible causes: 'LCARS Web' profile not in iTerm2, or Python API unavailable." >&2
            echo "  See full log: $ITERM_CONNECT_LOG" >&2
            echo "$_lcars_tab_err" >> "$ITERM_CONNECT_LOG"
        fi
    else
        echo "  Note: LCARS browser script not found — skipping iTerm2 inline browser." >&2
        echo "  (Expected: $LCARS_BROWSER_SCRIPT)" >&2
    fi

    if [[ "$LCARS_OPENED" != "true" ]]; then
        echo "  Opening LCARS tab without inline browser profile..."
        "$VENV_PYTHON" "$WM" \
            --action create-tab \
            --window-title "$ITERM_WINDOW_NAME" \
            --tab-name "LCARS" \
            --command "export ITERM_TAB_TITLE='LCARS' && ${AITEAMFORGE_DIR}/scripts/remote-tmux-attach.sh ${HOST} ${TMUX_SOCKET} ${TEAM_ID}-lcars" \
            2>>"$ITERM_CONNECT_LOG" || true
    fi
    sleep 0.3

    # ------------------------------------------------------------------
    # Agent tabs — one per entry in AGENTS
    # ------------------------------------------------------------------
    for agent in "${AGENTS[@]}"; do
        echo "  Opening tab: $agent"
        "$VENV_PYTHON" "$WM" \
            --action create-tab \
            --window-title "$ITERM_WINDOW_NAME" \
            --tab-name "$agent" \
            --command "export ITERM_TAB_TITLE='${agent}' && ${AITEAMFORGE_DIR}/scripts/remote-tmux-attach.sh ${HOST} ${TMUX_SOCKET} ${TEAM_ID}-${agent}" \
            2>>"$ITERM_CONNECT_LOG"
        # shellcheck disable=SC2181
        if [[ $? -ne 0 ]]; then
            echo "    Warning: Tab creation failed for $agent (see $ITERM_CONNECT_LOG)" >&2
        fi
        sleep 0.3
    done

    # ------------------------------------------------------------------
    # Agent panels (SSH-delegated to remote host)
    # Wait for iTerm2 Python API to become ready before splitting panels.
    #
    # XACA-0774: intentionally NOT wrapped with remote-tmux-attach.sh — this
    # is a remote display-refresh loop (agent-panel-display.sh polling
    # kanban/tmp state), not a tmux session attach. The reconnect helper only
    # applies to `tmux ... attach` surfaces.
    # ------------------------------------------------------------------
    _api_ready=false
    for _wait in 1 2 3 4 5; do
        if "$VENV_PYTHON" "$WM" \
            --action select-tab \
            --window-title "$ITERM_WINDOW_NAME" \
            --tab-name "${AGENTS[1]}" \
            2>/dev/null; then
            _api_ready=true
            break
        fi
        echo "    ⏳ Waiting for iTerm2 API (attempt $_wait/5)..."
        sleep 2
    done
    if [[ "$_api_ready" != "true" ]]; then
        echo "    ⚠️  iTerm2 API not ready after 10s — agent panels may not open"
    fi

    echo ""
    echo "  Adding agent panels..."
    for agent in "${AGENTS[@]}"; do
        _panel_ok=false
        for _attempt in 1 2 3; do
            "$VENV_PYTHON" "$WM" \
                --action split-agent-panel \
                --window-title "$ITERM_WINDOW_NAME" \
                --tab-name "$agent" \
                --command "ssh -t ${HOST} \"/bin/zsh -lc 'AITEAMFORGE_DIR=${REMOTE_ATF_DIR} ${REMOTE_ATF_DIR}/scripts/agent-panel-display.sh ${TEAM_ID}-${agent}'\"" \
                2>>"$ITERM_CONNECT_LOG"
            # shellcheck disable=SC2181
            if [[ $? -eq 0 ]]; then
                _panel_ok=true
                break
            fi
            echo "    ⚠️  Panel split attempt $_attempt failed for $agent, retrying..." >> "$ITERM_CONNECT_LOG"
            sleep 1
        done
        if [[ "$_panel_ok" != "true" ]]; then
            echo "    ⚠️  Failed to create agent panel: $agent (see $ITERM_CONNECT_LOG)" >&2
        fi
        sleep 0.3
    done

    # ------------------------------------------------------------------
    # Final focus: switch to LCARS tab
    # ------------------------------------------------------------------
    echo ""
    echo "  Switching to LCARS tab..."
    "$VENV_PYTHON" "$WM" \
        --action select-tab \
        --window-title "$ITERM_WINDOW_NAME" \
        --tab-name "LCARS" \
        2>>"$ITERM_CONNECT_LOG" || true

else
    # Terminal.app fallback: open SSH sessions in new tabs
    echo "  iTerm2 not running — using Terminal.app fallback"
    echo "  Note: LCARS inline browser not available in Terminal.app"
    osascript <<APPLESCRIPT
tell application "Terminal"
    activate
    tell application "System Events"
        tell process "Terminal"
            keystroke "t" using command down
        end tell
    end tell
    delay 0.5
    do script "printf '\\\\033]0;LCARS\\\\007' && ${AITEAMFORGE_DIR}/scripts/remote-tmux-attach.sh ${HOST} ${TMUX_SOCKET} ${TEAM_ID}-lcars" in front window
end tell
APPLESCRIPT
    sleep 0.5
    for agent in "${AGENTS[@]}"; do
        # shellcheck disable=SC2027,SC2086
        osascript <<APPLESCRIPT
tell application "Terminal"
    activate
    tell application "System Events"
        tell process "Terminal"
            keystroke "t" using command down
        end tell
    end tell
    delay 0.5
    do script "printf '\\\\033]0;${agent}\\\\007' && ${AITEAMFORGE_DIR}/scripts/remote-tmux-attach.sh ${HOST} ${TMUX_SOCKET} ${TEAM_ID}-${agent}" in front window
end tell
APPLESCRIPT
        sleep 0.5
    done
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ${TEAM_NAME} connected @ ${HOST}"
echo ""
echo "  LCARS:  http://${HOST}:${LCARS_PORT}"
echo "  tmux:   ${TMUX_SOCKET} on ${HOST}"
echo ""
echo "  Sessions:"
echo "    LCARS  tmux -L ${TMUX_SOCKET} attach -t ${TEAM_ID}-lcars"
for agent in "${AGENTS[@]}"; do
    echo "    ${agent}   tmux -L ${TMUX_SOCKET} attach -t ${TEAM_ID}-${agent}"
done
echo ""
echo "  This window is a viewer only — no remote mutations."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ -s "$ITERM_CONNECT_LOG" ]]; then
    echo "  iTerm2 errors logged to: $ITERM_CONNECT_LOG"
fi

echo "${TEAM_NAME} @ ${HOST} connected!"
