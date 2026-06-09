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
#   source "${AITEAMFORGE_DIR:-$HOME/dev-team}/scripts/lcars-launch-helpers.sh"
#
#   if start_lcars_server "academy" "$LCARS_PORT" "academy-lcars"; then
#       echo "Server is up"
#   else
#       echo "Server timed out — continuing anyway"
#   fi
#
# PORTABILITY (XACA-0562): this is the single canonical helper shared by BOTH the
# dev machine (per-team *-startup.sh scripts) AND tap-installed machines
# (`aiteamforge start`). All dev-team paths are resolved from a portable base:
#   _atf_base="${AITEAMFORGE_DIR:-$HOME/dev-team}"
# On the dev source machine AITEAMFORGE_DIR is unset → $HOME/dev-team (the
# historical hardcoded location). On a tap-installed machine AITEAMFORGE_DIR is
# set (e.g. $HOME/aiteamforge) and this helper lives at
# $AITEAMFORGE_DIR/scripts/lcars-launch-helpers.sh, so the base resolves to the
# installed tree. We deliberately do NOT self-locate via ${BASH_SOURCE[0]}: the
# 11 callers are #!/bin/zsh scripts and BASH_SOURCE is empty under zsh
# (feedback_bash_source_empty_under_zsh).
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
# fresh server.py in the background (capturing its stderr to a per-team log),
# then polls /api/status for up to 15 seconds (30 × 0.5s) for first boot.
#
# Unlike the previous version (which discarded all output and polled a fixed
# 5s), this:
#   - captures server.py's stderr to ${AITEAMFORGE_DIR:-<dev-team>}/logs/
#     lcars-server-<team>.log so a FATAL boot error is recoverable;
#   - tracks the server PID and short-circuits the poll the instant the process
#     dies, surfacing the REAL exit status + the log tail (a crashed server is
#     never going to answer /api/status — don't burn the whole window);
#   - on a slow/hung-but-alive boot, surfaces the log tail instead of a bare
#     "did not respond" message.
#
# Soft-fail contract is preserved: callers continue regardless of the return.
#
# Returns:
#   0  — server responded within the polling window
#   1  — server crashed on boot, or did not respond in time (caller may proceed)
# ---------------------------------------------------------------------------
start_lcars_server() {
    local team="${1:?start_lcars_server: team argument is required}"
    local port="${2:?start_lcars_server: port argument is required}"
    local session_name="${3:-${team}-lcars}"

    # XACA-0562: portable base. Dev machine (AITEAMFORGE_DIR unset) → $HOME/dev-team
    # (== the historical /Users/darrenehlers/dev-team hardcode). Tap machine →
    # $AITEAMFORGE_DIR (e.g. $HOME/aiteamforge). LCARS_UI_DIR allows an explicit
    # override if ever needed.
    local _atf_base="${AITEAMFORGE_DIR:-$HOME/dev-team}"
    local lcars_ui_dir="${LCARS_UI_DIR:-${_atf_base}/lcars-ui}"

    # Write the router redirect so the UI knows which team dashboard to show.
    # This must happen BEFORE the server starts; the file is read on first load.
    echo "window.LCARS_TARGET_TEAM = '${team}';" > "${lcars_ui_dir}/lcars-target.js"

    # Kill any stale server process on this port. Stale processes are normal
    # (previous session crash, leftover from a prior startup). Errors here are
    # expected when nothing is running; suppress them.
    pkill -f "server.py.*${port}" 2>/dev/null

    # XACA-0486 / XACA-0562 / XACA-0563: Resolve the python that has the LCARS
    # runtime imports (pyzipper, requests, etc. from share/requirements.txt). Bare
    # `python3` is the system interpreter and does NOT have these deps — it is only
    # the last-resort fallback (the dev-team source machine has the deps globally;
    # tap machines do not, so the venv MUST win there).
    #
    # Probe order:
    #   0. $LCARS_PYTHON (env override)              — XACA-0563: an explicit, caller-
    #                                                  resolved interpreter wins. The rendered
    #                                                  tap startup templates export their own
    #                                                  $VENV_PYTHON (resolved from
    #                                                  $HOME/.aiteamforge/venv or
    #                                                  $AITEAMFORGE_DIR/.venv — paths the chain
    #                                                  below does NOT cover). Unset on the dev
    #                                                  machine + per-team scripts → chain runs
    #                                                  unchanged there.
    #   1. `brew --prefix aiteamforge`/libexec/venv  — current formula convention
    #                                                  (XACA-0486; installed by the Formula)
    #   2. env.sh → $AITEAMFORGE_PYTHON               — older convention; env.sh exports
    #                                                  the canonical interpreter path
    #   3. $(brew --prefix)/var/aiteamforge/venv      — older var-located venv
    #   4. $AITEAMFORGE_DIR/share/venv                — bundled-share venv layout
    #   5. python3                                    — last resort (dev source machine)
    # On the dev machine the override is unset and probes 1-4 all miss (no brew
    # aiteamforge / no env.sh), so we fall straight through to bare python3 —
    # identical to prior behavior.
    local lcars_python
    if [[ -n "${LCARS_PYTHON:-}" ]] && [[ -x "${LCARS_PYTHON}" ]]; then
        lcars_python="${LCARS_PYTHON}"
    else
        lcars_python="python3"  # last-resort fallback (dev-team source machine)
        local _brew_aitf_prefix
        if _brew_aitf_prefix="$(brew --prefix aiteamforge 2>/dev/null)" && [[ -x "${_brew_aitf_prefix}/libexec/venv/bin/python3" ]]; then
            lcars_python="${_brew_aitf_prefix}/libexec/venv/bin/python3"
        else
            # Older convention: env.sh exports AITEAMFORGE_PYTHON (canonical interpreter).
            local _brew_prefix _atf_env_sh
            _brew_prefix="$(brew --prefix 2>/dev/null)"
            _atf_env_sh="${_brew_prefix}/var/aiteamforge/env.sh"
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
        fi
    fi

    # Resolve a log dir consistent with the rendered-template convention
    # (team-startup.sh.template logs to $AITEAMFORGE_DIR/logs/lcars-server-<team>.log).
    # On the dev machine $AITEAMFORGE_DIR is unset, so fall back to dev-team/logs.
    # Use _atf_base (not dirname of lcars_ui_dir) so an LCARS_UI_DIR override does
    # not relocate the logs away from the canonical tree.
    local _log_dir="${_atf_base}/logs"
    mkdir -p "${_log_dir}" 2>/dev/null
    local _server_log="${_log_dir}/lcars-server-${team}.log"

    # Cap unbounded log growth: roll to a single .old backup past ~256KB.
    if [[ -f "${_server_log}" ]] && (( $(wc -c < "${_server_log}" 2>/dev/null || echo 0) > 262144 )); then
        mv -f "${_server_log}" "${_server_log}.old" 2>/dev/null || true
    fi

    # XACA-0652: Durable server launch.
    #
    # WHY THE OLD FORM WORKED ON DEV BUT NOT ON A TAP-INSTALLED CONSUMER:
    #   Dev machine: startup scripts are SOURCED inside a persistent tmux pane.
    #   The shell hosting the pane does not exit, so SIGHUP is never sent to the
    #   background server child.  The server lives indefinitely.
    #
    #   Consumer (tap-installed, e.g. M4Mini): each team's startup script is
    #   invoked as the "Initial Command" of an iTerm2 profile tab OR called from
    #   a transient shell.  When the startup script finishes and the shell exits,
    #   the OS sends SIGHUP to the entire process group — including the server.py
    #   child.  The server received the first /api/status 200 (a momentary truth),
    #   reported "ready", then was killed milliseconds later when the parent exited.
    #
    # FIX: two layers of protection:
    #   1. `nohup` makes server.py IGNORE SIGHUP even if it receives one.
    #   2. `disown` removes the PID from the shell's job table, preventing the
    #      shell from SIGHUP'ing the child on exit in interactive/hup-sending
    #      contexts.  `|| true` absorbs the expected "job not found" error that
    #      zsh emits when disown is called from a non-interactive subshell.
    #   Together these ensure the server outlives the startup script on all paths.
    #
    # PID TRACKABILITY: `nohup sh -c "... exec env ... python3 server.py ..."` works
    # because `exec` inside sh -c replaces the `sh` subprocess with the python
    # process.  `$!` therefore resolves to the python PID — NOT a shell wrapper —
    # so kill -0 liveness checks remain accurate.  (Verified: ps -p $! shows
    # "python3" on macOS after the exec.)
    #
    # STDERR: nohup normally redirects stderr to nohup.out; we override that with
    # an explicit `2>>log` redirect, which takes precedence.  stdout is discarded.
    #
    # Note: we use env vars rather than shell variable expansion inside the
    # sh -c string to avoid quoting hazards with paths that may contain spaces.
    nohup env \
        _ATF_LCARS_DIR="${lcars_ui_dir}" \
        _ATF_TEAM="${team}" \
        _ATF_SESSION="${session_name}" \
        _ATF_PYTHON="${lcars_python}" \
        _ATF_PORT="${port}" \
        sh -c 'cd "$_ATF_LCARS_DIR" && exec env \
            LCARS_TEAM="$_ATF_TEAM" LCARS_SESSION_NAME="$_ATF_SESSION" \
            "$_ATF_PYTHON" server.py "$_ATF_PORT"' \
        >/dev/null 2>>"${_server_log}" &
    local _server_pid=$!
    disown "${_server_pid}" 2>/dev/null || true

    # Poll /api/status for up to 15s (30 × 0.5s). A ready response means the
    # server is serving routes. If the process dies before answering, a crashed
    # server is never going to respond — short-circuit and surface the real
    # exit status + log tail instead of waiting out the full window.
    local _poll_i
    for _poll_i in {1..30}; do
        if curl -s "http://localhost:${port}/api/status" >/dev/null 2>&1; then
            # XACA-0652: Hardened readiness check — confirm the process is still
            # alive after the first 200.  The old code returned immediately on the
            # first successful curl, which passed even when the server was about to
            # be killed by SIGHUP (it answered the request, THEN died).  A 0.3s
            # pause + re-check catches this "momentary truth" failure mode.
            sleep 0.3
            if ! kill -0 "${_server_pid}" 2>/dev/null; then
                wait "${_server_pid}" 2>/dev/null; local _rc=$?
                echo "    ❌ LCARS server for team '${team}' on port ${port} responded once then exited (status ${_rc}) — startup-script SIGHUP suspected." >&2
                echo "       Last lines of ${_server_log}:" >&2
                tail -n 15 "${_server_log}" 2>/dev/null | sed 's/^/         /' >&2
                return 1
            fi
            echo "    ✅ LCARS server ready on port ${port} (pid ${_server_pid})"
            return 0
        fi
        if ! kill -0 "${_server_pid}" 2>/dev/null; then
            wait "${_server_pid}" 2>/dev/null; local _rc=$?
            echo "    ❌ LCARS server for team '${team}' on port ${port} exited (status ${_rc}) before becoming ready." >&2
            echo "       Last lines of ${_server_log}:" >&2
            tail -n 15 "${_server_log}" 2>/dev/null | sed 's/^/         /' >&2
            return 1
        fi
        sleep 0.5
    done

    # Window elapsed but the process is still alive (slow/hung boot). Surface
    # the log tail instead of a bare timeout. Do NOT abort — the tab may still
    # work once iTerm2 opens it; let the caller decide whether to proceed.
    echo "    ⚠️  LCARS server for team '${team}' on port ${port} did not become ready within 15s (process still running, pid ${_server_pid})." >&2
    echo "       Recent ${_server_log}:" >&2
    tail -n 15 "${_server_log}" 2>/dev/null | sed 's/^/         /' >&2
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
    # XACA-0562: portable base — identical to start_lcars_server. Dev machine
    # (AITEAMFORGE_DIR unset) → $HOME/dev-team; tap machine → $AITEAMFORGE_DIR.
    local _atf_base="${AITEAMFORGE_DIR:-$HOME/dev-team}"
    local setter_script="${_atf_base}/scripts/set-lcars-profile-browser.py"
    local wm_script="${_atf_base}/iterm2_window_manager.py"

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

# ---------------------------------------------------------------------------
# resolve_lcars_port <session_prefix>
#
# Returns the canonical LCARS port for <session_prefix> on stdout.
#
# Resolution order (XACA-0590):
#   1. kanban-hooks/lcars_ports.py via aiteamforge_paths (team-paths.json overlay
#      wins; DEFAULT_TEAMS is the fallback).  This is the single canonical source.
#   2. Legacy cksum-based derivation is NOT done here — callers that need a cksum
#      fallback for unregistered prefixes should supply it after a failed call:
#
#       LCARS_PORT="$(resolve_lcars_port "$SESSION_PREFIX")" || \
#         LCARS_PORT=$((BASE + $(echo "$INPUT" | cksum | cut -d' ' -f1) % RANGE))
#
# Returns:
#   0  — resolved; port is printed on stdout.
#   1  — prefix is unknown / lcars_port is null; nothing printed on stdout
#         (warnings go to stderr so the caller's || branch runs cleanly).
#
# Portability (mirrors start_lcars_server): uses ${AITEAMFORGE_DIR:-$HOME/dev-team}
# as the base so it works on dev machines (unset AITEAMFORGE_DIR → ~/dev-team)
# and tap-installed machines (AITEAMFORGE_DIR exported by the Formula).
# BASH_SOURCE is empty under zsh — do NOT use it to self-locate (see
# feedback_bash_source_empty_under_zsh). We rely on the portable base instead.
# ---------------------------------------------------------------------------
resolve_lcars_port() {
    local prefix="${1:?resolve_lcars_port: session_prefix argument is required}"
    local _atf_base="${AITEAMFORGE_DIR:-$HOME/dev-team}"
    local _ports_py="${_atf_base}/kanban-hooks/lcars_ports.py"

    if [[ ! -f "$_ports_py" ]]; then
        echo "resolve_lcars_port: kanban-hooks/lcars_ports.py not found at ${_ports_py}" >&2
        return 1
    fi

    # lcars_ports.py prints "prefix:port" on stdout for known prefixes;
    # unknown/null prefixes emit a WARNING on stderr and produce no stdout output.
    local _result
    _result="$(python3 "$_ports_py" "$prefix" 2>/dev/null)"

    if [[ -z "$_result" ]]; then
        # Emit warning so callers logging stderr understand why the fallback ran.
        echo "resolve_lcars_port: '${prefix}' not found in canonical registry — caller should use cksum fallback" >&2
        return 1
    fi

    # Strip the "prefix:" part; output only the port number.
    echo "${_result#*:}"
    return 0
}
