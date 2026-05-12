#!/bin/zsh
# shellcheck shell=bash
# lcars-launch-helpers.sh — Shared helper functions for LCARS server startup
#
# Source this file in team-startup scripts; it provides two functions:
#
#   start_lcars_server <team> <port> [session_name]
#   open_lcars_tab <port> <window_title> <tab_name> <tmux_socket> <lcars_session> <startup_log>
#
# Usage example (in a team-startup script):
#
#   source "$HOME/dev-team/scripts/lcars-launch-helpers.sh"
#
#   if start_lcars_server "academy" "$LCARS_PORT" "academy-lcars"; then
#       echo "Server is up"
#   else
#       echo "Server timed out — continuing anyway"
#   fi
#
#   open_lcars_tab "$LCARS_PORT" "$ITERM_WINDOW_NAME" "LCARS" \
#       "$TMUX_SOCKET" "academy-lcars" "$ITERM_STARTUP_LOG" \
#       || { echo "Failed to open LCARS tab"; exit 1; }
#
# NOTE: Remote-host (SSH) LCARS setup is NOT handled here. Academy's SSH-remote
# branch in academy-startup.sh does bespoke port-forwarding setup; generalising
# that path would require passing remote_host, port-forward PID tracking arrays,
# and ssh keys — the complexity would outweigh the benefit. Teams with remote
# LCARS hosts should retain their own remote branch and call start_lcars_server()
# only for the local-mode branch.
#
# IMPORTANT — silent-fail removal:
# Previous versions of team-startup scripts suppressed all errors from
# set-lcars-profile-browser.py with "2>/dev/null". This meant a missing or
# mis-named Dynamic Profile would cause the LCARS tab to open on the WRONG URL
# with no diagnostic output — a confusing failure. open_lcars_tab() removes that
# suppression and logs errors loudly so they are actionable.

# ---------------------------------------------------------------------------
# start_lcars_server <team> <port> [session_name]
#
# Writes the router redirect file, kills any stale server on <port>, starts a
# fresh server.py in the background, then polls /api/status for up to 5 seconds.
#
# Returns:
#   0  — server responded within the polling window
#   1  — server did not respond in time (caller may proceed anyway)
# ---------------------------------------------------------------------------
start_lcars_server() {
    local team="${1:?start_lcars_server: team argument is required}"
    local port="${2:?start_lcars_server: port argument is required}"
    local session_name="${3:-${team}-lcars}"

    local lcars_ui_dir="$HOME/dev-team/lcars-ui"

    # Write the router redirect so the UI knows which team dashboard to show.
    # This must happen BEFORE the server starts; the file is read on first load.
    echo "window.LCARS_TARGET_TEAM = '${team}';" > "${lcars_ui_dir}/lcars-target.js"

    # Kill any stale server process on this port. Stale processes are normal
    # (previous session crash, leftover from a prior startup). Errors here are
    # expected when nothing is running; suppress them.
    pkill -f "server.py.*${port}" 2>/dev/null

    # XACA-0486: Resolve the brew venv python so runtime imports (pyzipper,
    # requests, etc. listed in share/requirements.txt) actually work. Bare
    # `python3` resolves to the system python which does NOT have these deps.
    #
    # The Formula creates a venv at $(brew --prefix)/var/aiteamforge/venv and
    # exports AITEAMFORGE_PYTHON via env.sh. Use that env var (canonical) when
    # available; otherwise probe known paths; bare python3 as last resort.
    local lcars_python="python3"  # last-resort fallback (dev-team source machine)
    local _atf_env_sh="$(brew --prefix 2>/dev/null)/var/aiteamforge/env.sh"
    if [[ -f "$_atf_env_sh" ]]; then
        # shellcheck disable=SC1090
        source "$_atf_env_sh"
    fi
    if [[ -n "${AITEAMFORGE_PYTHON:-}" ]] && [[ -x "$AITEAMFORGE_PYTHON" ]]; then
        lcars_python="$AITEAMFORGE_PYTHON"
    elif [[ -x "$(brew --prefix 2>/dev/null)/var/aiteamforge/venv/bin/python3" ]]; then
        lcars_python="$(brew --prefix)/var/aiteamforge/venv/bin/python3"
    elif [[ -x "${AITEAMFORGE_DIR:-$HOME/aiteamforge}/share/venv/bin/python3" ]]; then
        lcars_python="${AITEAMFORGE_DIR:-$HOME/aiteamforge}/share/venv/bin/python3"
    fi

    # Start the server in a background subshell. stdout/stderr are discarded
    # because server.py is chatty and we only care about the /api/status poll.
    (
        cd "${lcars_ui_dir}" || return 1
        LCARS_TEAM="${team}" LCARS_SESSION_NAME="${session_name}" \
            "${lcars_python}" server.py "${port}" > /dev/null 2>&1 &
    )

    # Poll /api/status for up to 5s (10 × 0.5s). A ready response means the
    # server is serving routes; a timeout is a soft warning — the browser tab
    # may still load once iTerm2 opens it (the server often wins the race).
    local _poll_i
    for _poll_i in {1..10}; do
        if curl -s "http://localhost:${port}/api/status" > /dev/null 2>&1; then
            echo "    ✅ LCARS server ready on port ${port}"
            return 0
        fi
        sleep 0.5
    done

    # Do NOT abort here. The tab may still work; log a warning and let the
    # caller decide whether to proceed.
    echo "    ⚠️  LCARS server on port ${port} did not respond within 5s — continuing" >&2
    return 1
}

# ---------------------------------------------------------------------------
# open_lcars_tab <port> <window_title> <tab_name> <tmux_socket> <lcars_session> <startup_log>
#
# Arguments:
#   port           — LCARS server port (e.g. 8203)
#   window_title   — iTerm2 window name (e.g. "Academy Team")
#   tab_name       — Tab label to display (typically "LCARS")
#   tmux_socket    — tmux -L socket name (e.g. "academy")
#   lcars_session  — tmux session name for the LCARS terminal (e.g. "academy-lcars")
#   startup_log    — path to the ITERM_STARTUP_LOG file for error capture
#
# 1. Calls set-lcars-profile-browser.py to update the "LCARS Web" Dynamic
#    Profile URL. Errors are printed loudly (no 2>/dev/null) so misconfigurations
#    are immediately visible. Returns non-zero on failure.
#
# 2. Creates an iTerm2 tab using the "LCARS Web" profile via iterm2_window_manager.py,
#    with up to 3 retries on failure.
#
# NOTE: The setter script (set-lcars-profile-browser.py) includes its own
# wait-for-reload logic (added in XACA-0225 subitem 003). This function does
# NOT add a secondary wait on top of that.
#
# Returns:
#   0  — tab created successfully
#   1  — profile setter failed (caller should treat as fatal)
#   2  — tab creation failed after 3 attempts
# ---------------------------------------------------------------------------
open_lcars_tab() {
    local port="${1:?open_lcars_tab: port argument is required}"
    local window_title="${2:?open_lcars_tab: window_title argument is required}"
    local tab_name="${3:?open_lcars_tab: tab_name argument is required}"
    local tmux_socket="${4:?open_lcars_tab: tmux_socket argument is required}"
    local lcars_session="${5:?open_lcars_tab: lcars_session argument is required}"
    local startup_log="${6:?open_lcars_tab: startup_log argument is required}"

    local lcars_url="http://localhost:${port}"
    local setter_script="$HOME/dev-team/scripts/set-lcars-profile-browser.py"
    local wm_script="$HOME/dev-team/iterm2_window_manager.py"

    # ---- Step 1: Update the Dynamic Profile URL ----
    #
    # NOT using 2>/dev/null here. Previous scripts silently swallowed failures,
    # which caused the LCARS tab to open on a stale URL with no indication of
    # why. If the setter fails — missing profile file, wrong GUID, etc. — we
    # need to know about it immediately.
    if ! python3 "${setter_script}" "${lcars_url}"; then
        echo "🚨 LCARS profile setter FAILED for ${lcars_url}" >&2
        echo "   Script: ${setter_script}" >&2
        echo "   Check that the 'LCARS Web' Dynamic Profile exists in iTerm2." >&2
        echo "   Without this, the LCARS tab will open on the wrong URL." >&2
        return 1
    fi

    # ---- Step 2: Create the LCARS Web tab in iTerm2 ----
    #
    # We attach to the team's LCARS tmux session. The "LCARS Web" iTerm2 profile
    # renders the tab as an inline browser, but a tmux session backing is still
    # required for consistent session management across team startup scripts.
    local attach_cmd="export ITERM_TAB_TITLE='${tab_name}' && tmux -L ${tmux_socket} attach -t ${lcars_session}"

    local attempt
    local tab_created=false
    for attempt in 1 2 3; do
        if python3 "${wm_script}" \
            --action create-tab \
            --window-title "${window_title}" \
            --profile "LCARS Web" \
            --tab-name "${tab_name}" \
            --command "${attach_cmd}" \
            2>>"${startup_log}"; then
            tab_created=true
            break
        fi
        echo "    ⚠️  LCARS tab creation attempt ${attempt}/3 failed, retrying..." >&2
        sleep 1
    done

    if [[ "${tab_created}" != "true" ]]; then
        echo "    ❌ Failed to create LCARS tab after 3 attempts (see ${startup_log})" >&2
        return 2
    fi

    return 0
}
