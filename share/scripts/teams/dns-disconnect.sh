#!/usr/bin/env zsh
# DNS Framework Disconnect Script (XACA-0605)
# Hand-authored counterpart to dns-connect.sh (DNS has no tap conf).
#
# Symmetric counterpart to dns-connect.sh. Purely local cleanup:
# closes the iTerm2 window opened by connect and resets the local LCARS
# Web profile URL back to localhost. Does NOT touch the remote host —
# the remote team keeps running, remote tmux sessions persist.
#
# Usage:
#   dns-disconnect.sh              # close ALL DNS Framework @ * windows
#   dns-disconnect.sh <host>       # close only the window for <host>

# shellcheck disable=SC1083,SC2039
TEAM_ID="dns"
# shellcheck disable=SC1083,SC2039
TEAM_NAME="DNS Framework"
# shellcheck disable=SC1083,SC2039
AITEAMFORGE_DIR="$HOME/dev-team"

# DNS resolves its port dynamically (no hardcoded constant): canonical registry
# first (resolve_lcars_port "dns"), then the same cksum band fallback as
# dns-startup.sh / dns-connect.sh. The disconnect only needs a LOCAL port for the
# localhost profile reset, so no remote lookup is required here.
LCARS_PORT=""
# shellcheck source=/dev/null
if [[ -f "$AITEAMFORGE_DIR/scripts/lcars-launch-helpers.sh" ]]; then
    source "$AITEAMFORGE_DIR/scripts/lcars-launch-helpers.sh" 2>/dev/null || true
    if typeset -f resolve_lcars_port >/dev/null 2>&1; then
        LCARS_PORT="$(resolve_lcars_port "$TEAM_ID" 2>/dev/null | tr -dc '0-9')"
    fi
fi
# cksum band fallback — shared resolve_lcars_port_fallback (XACA-0672) keeps this byte-
# identical to dns-startup.sh / dns-connect.sh. In scope when the helper sourced above.
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

HOST_FILTER="${1:-}"

echo ""
if [[ -n "$HOST_FILTER" ]]; then
    echo "  Disconnecting ${TEAM_NAME} @ ${HOST_FILTER}"
else
    echo "  Disconnecting all ${TEAM_NAME} remote connections"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ============================================================================
# Reset local LCARS Web profile URL back to localhost
# ============================================================================
LCARS_BROWSER_SCRIPT="$AITEAMFORGE_DIR/scripts/set-lcars-profile-browser.py"
if [[ -f "$LCARS_BROWSER_SCRIPT" ]]; then
    echo "  Resetting LCARS profile URL → http://localhost:${LCARS_PORT}"
    python3 "$LCARS_BROWSER_SCRIPT" "http://localhost:${LCARS_PORT}" 2>/dev/null || true
fi

# ============================================================================
# Close matching iTerm2 windows
# ============================================================================
# dns-connect.sh names the window "${TEAM_NAME} @ ${HOST}". Match by prefix
# "${TEAM_NAME} @ " to close all connect windows for this team, or the exact
# title when a host argument is supplied.
if [[ -d "/Applications/iTerm.app" ]] && pgrep -f "iTerm.app" > /dev/null; then
    if [[ -n "$HOST_FILTER" ]]; then
        _match_title="${TEAM_NAME} @ ${HOST_FILTER}"
        _match_mode="exact"
    else
        _match_title="${TEAM_NAME} @ "
        _match_mode="prefix"
    fi

    # shellcheck disable=SC2086
    _closed=$(osascript <<APPLESCRIPT 2>/dev/null
tell application "iTerm"
    set closed_count to 0
    set target_title to "${_match_title}"
    set match_mode to "${_match_mode}"
    set windows_to_close to {}
    repeat with w in windows
        try
            set wname to name of w
            if match_mode is "exact" then
                if wname is target_title then
                    set end of windows_to_close to w
                end if
            else
                if wname starts with target_title then
                    set end of windows_to_close to w
                end if
            end if
        end try
    end repeat
    repeat with w in windows_to_close
        try
            close w
            set closed_count to closed_count + 1
        end try
    end repeat
    return closed_count
end tell
APPLESCRIPT
)
    _closed="${_closed:-0}"
    if [[ "$_closed" -gt 0 ]]; then
        echo "  Closed ${_closed} iTerm2 window(s)"
    else
        echo "  No matching iTerm2 window found"
        echo "    (looking for: \"${_match_title}\"${_match_mode:+ [${_match_mode}]})"
    fi
else
    echo "  iTerm2 not running — nothing to close"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ${TEAM_NAME} disconnected"
echo ""
echo "  Remote team is still running. To reconnect:"
echo "    ${TEAM_ID}-connect.sh <host>"
echo ""
echo "  To shut down the remote team, SSH to the host and run:"
echo "    ${TEAM_ID}-shutdown.sh"
echo ""
