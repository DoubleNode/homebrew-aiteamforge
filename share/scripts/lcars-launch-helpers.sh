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
# _lcars_port_drift_guard <team> <port> <session_name> <atf_base>
#
# XACA-0626 startup-time port drift guard.
#
# Called from start_lcars_server() BEFORE the server binds, so every LCARS
# launch — on both the dev source machine and tap-installed consumers — runs
# this check automatically. No additional per-machine steps are required.
#
# Two checks:
#
# 1. .port file drift (SELF-HEAL):
#    Reads lcars-ports/<session_name>.port. If the value differs from <port>
#    (what the caller resolved via resolve_lcars_port / team-paths.json), the
#    file is REWRITTEN to <port> and a one-line notice is emitted. This closes
#    the "no automated sync" gap identified in XACA-0626-003 §6 (MISSING WRITER):
#    the .port file is written once at provisioning (kb-init-team) and was
#    never re-synced by any startup path. The 8427 stale cksum residue on M1Pro
#    is the canonical example — a single startup now self-heals it permanently.
#
# 2. team-paths.json vs DEFAULT_TEAMS canonical (WARN-ONLY):
#    Invokes aiteamforge_paths.py to compare the team-paths.json port (which
#    resolve_lcars_port already used as <port>) against DEFAULT_TEAMS canonical.
#    If they differ, a loud actionable warning is emitted pointing the operator
#    at "kb-port-reconcile --prefer canonical <team>". We do NOT auto-correct
#    team-paths.json here: that file is written by the installer's allocator, and
#    rewriting it mid-startup could fight a concurrent install or mask a real
#    collision that the operator needs to consciously resolve. The .port rewrite
#    (check 1) is the sufficient, safe self-heal for connectivity; team-paths
#    drift is a secondary issue that requires informed operator action.
#
# Defensive contract: any failure in this guard (missing files, Python errors,
# unresolvable canonical) emits a stderr warning and returns 0 — the guard
# NEVER aborts the startup. A broken guard is worse than no guard.
#
# Shell compatibility: #!/bin/zsh (macOS system zsh). No bashisms beyond what
# zsh supports; avoids "local" inside loops (feedback_zsh_local_in_loop_gotcha).
# ---------------------------------------------------------------------------
_lcars_port_drift_guard() {
    local _guard_team="${1:-}"
    local _guard_port="${2:-}"
    local _guard_session="${3:-}"
    local _guard_base="${4:-}"

    # Defensive: skip guard if arguments are missing (should never happen in
    # normal use, but we promised to never abort startup).
    if [[ -z "$_guard_team" || -z "$_guard_port" || -z "$_guard_session" || -z "$_guard_base" ]]; then
        echo "  [port-drift-guard] WARNING: missing arguments — skipping guard" >&2
        return 0
    fi

    local _guard_ports_dir="${_guard_base}/lcars-ports"
    local _guard_port_file="${_guard_ports_dir}/${_guard_session}.port"
    # Gate Check 2 on the module it actually imports (aiteamforge_paths.py), not a
    # co-shipped proxy — so the team-paths drift warning can't silently die if the
    # proxy is ever removed independently. (XACA-0626 review hardening.)
    local _guard_ports_py="${_guard_base}/kanban-hooks/aiteamforge_paths.py"

    # ------------------------------------------------------------------
    # Check 1: .port file vs resolved port (SELF-HEAL)
    # ------------------------------------------------------------------
    if [[ -f "$_guard_port_file" ]]; then
        local _guard_current_port
        _guard_current_port="$(cat "$_guard_port_file" 2>/dev/null | tr -d '[:space:]')"
        if [[ -n "$_guard_current_port" && "$_guard_current_port" != "$_guard_port" ]]; then
            # Rewrite .port to the resolved canonical value before server binds.
            if printf '%s\n' "$_guard_port" > "$_guard_port_file" 2>/dev/null; then
                echo "  [port-drift-guard] NOTICE: ${_guard_session}.port was ${_guard_current_port}, corrected to ${_guard_port} (stale value self-healed)." >&2
            else
                echo "  [port-drift-guard] WARNING: ${_guard_session}.port is stale (${_guard_current_port} vs ${_guard_port}) but could not be rewritten — check permissions on ${_guard_port_file}" >&2
            fi
        fi
    else
        # Port file does not exist — create it so future checks and connect
        # scripts have a value to read (mirrors kb-init-team P1 logic).
        if [[ -d "$_guard_ports_dir" ]]; then
            if printf '%s\n' "$_guard_port" > "$_guard_port_file" 2>/dev/null; then
                echo "  [port-drift-guard] NOTICE: ${_guard_session}.port did not exist — created with port ${_guard_port}." >&2
            fi
        fi
    fi

    # ------------------------------------------------------------------
    # Check 2: team-paths.json port vs DEFAULT_TEAMS canonical (WARN-ONLY)
    #
    # resolve_lcars_port (called by the template before start_lcars_server)
    # already prefers the team-paths.json overlay, so _guard_port == the
    # team-paths value. Here we fetch the DEFAULT_TEAMS canonical and compare.
    # A mismatch means the installer's allocator produced a +1 drift (self-
    # collision) — the operator must run kb-port-reconcile to correct it.
    # ------------------------------------------------------------------
    if [[ ! -f "$_guard_ports_py" ]]; then
        # No Python module available (edge case: stripped install). Skip silently.
        return 0
    fi

    local _guard_py_dir
    _guard_py_dir="$(dirname "$_guard_ports_py")"
    local _guard_default_port
    _guard_default_port="$(python3 -c "
import sys
sys.path.insert(0, '${_guard_py_dir}')
try:
    from aiteamforge_paths import DEFAULT_TEAMS
    entry = DEFAULT_TEAMS.get('${_guard_team}')
    if entry:
        p = entry.get('lcars_port')
        if p: print(int(p))
except Exception:
    pass
" 2>/dev/null)"

    if [[ -n "$_guard_default_port" && "$_guard_port" != "$_guard_default_port" ]]; then
        local _guard_drift=$(( _guard_port - _guard_default_port ))
        local _guard_drift_str
        if (( _guard_drift > 0 )); then
            _guard_drift_str="+${_guard_drift}"
        else
            _guard_drift_str="${_guard_drift}"
        fi
        echo "  [port-drift-guard] WARNING: team-paths.json port for '${_guard_team}' is ${_guard_port} but DEFAULT_TEAMS canonical is ${_guard_default_port} (drift: ${_guard_drift_str})." >&2
        echo "                     To correct: kb-port-reconcile --prefer canonical ${_guard_team}" >&2
    fi

    return 0
}

# ---------------------------------------------------------------------------
# is_headless — returns 0 (true) when no macOS GUI session is available for
# iTerm2/Terminal.app automation; returns 1 (false) when a GUI is present.
#
# Rationale for each signal (most-decisive first):
#   * $SSH_CONNECTION / $SSH_TTY set  -> we are inside an SSH session => headless.
#   * No Aqua login session            -> `launchctl print gui/$(id -u)` fails or
#                                         the user is not bootstrapped into Aqua.
#                                         This is the authoritative "is there a
#                                         window server for me" check on macOS.
#   * No iTerm.app AND no Terminal.app -> nothing to automate.
# Any ONE of these => headless. We deliberately do NOT rely on $TERM_PROGRAM
# alone: a tmux pane unsets/rewrites it, producing false "headless" on a real GUI.
#
# Override hooks (testability + ops):
#   ATF_FORCE_HEADLESS=1  -> always returns 0 (headless), even on a GUI box.
#   ATF_FORCE_GUI=1       -> always returns 1 (GUI present). ATF_FORCE_HEADLESS wins.
# (XACA-0614)
is_headless() {
    # Override: force headless wins over force GUI.
    if [[ "${ATF_FORCE_HEADLESS:-}" == "1" ]]; then return 0; fi
    if [[ "${ATF_FORCE_GUI:-}" == "1" ]]; then return 1; fi

    # Strongest signal: an SSH session has no local window server.
    if [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" ]]; then
        return 0
    fi
    # Authoritative macOS GUI-session probe. In an Aqua (logged-in) session this
    # succeeds; over SSH / in a LaunchDaemon / on a headless boot it fails.
    if ! launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
        return 0
    fi
    # Belt-and-suspenders: neither GUI terminal app is running => nothing to drive.
    if ! pgrep -x iTerm2 >/dev/null 2>&1 \
       && ! pgrep -f "iTerm.app" >/dev/null 2>&1 \
       && ! pgrep -f "Terminal.app" >/dev/null 2>&1; then
        return 0
    fi
    return 1   # a GUI session is available
}

# ---------------------------------------------------------------------------
# has_iterm_gui — returns 0 (true) when iTerm2 is running and automatable.
# Replaces the repeated literal `[[ "$TERM_PROGRAM" == "iTerm.app" ]] || pgrep`
# across all startup scripts (XACA-0614 sibling-drift fix R1).
# (XACA-0614)
has_iterm_gui() {
    [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]] || pgrep -f "iTerm.app" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# resolve_lcars_python — echo the python interpreter that has the LCARS runtime
# deps (pyzipper, requests, …). Single source of truth for both
# start_lcars_server and lcars-health-check.sh::_hc_start_lcars_server.
#
# Probe order (mirrors start_lcars_server's previous inline chain, XACA-0486/0562/0563):
#   0. $LCARS_PYTHON (env override)
#   1. brew --prefix aiteamforge / libexec/venv
#   2. env.sh → $AITEAMFORGE_PYTHON
#   3. $(brew --prefix)/var/aiteamforge/venv
#   4. $AITEAMFORGE_DIR/share/venv
#   5. python3  (last-resort; dev source machine has deps globally)
# (XACA-0614)
resolve_lcars_python() {
    if [[ -n "${LCARS_PYTHON:-}" && -x "${LCARS_PYTHON}" ]]; then
        echo "${LCARS_PYTHON}"; return 0
    fi
    local _p
    local _brew_aitf_prefix
    if _brew_aitf_prefix="$(brew --prefix aiteamforge 2>/dev/null)" \
       && [[ -x "${_brew_aitf_prefix}/libexec/venv/bin/python3" ]]; then
        echo "${_brew_aitf_prefix}/libexec/venv/bin/python3"; return 0
    fi
    local _brew_prefix _atf_env_sh
    _brew_prefix="$(brew --prefix 2>/dev/null)"
    _atf_env_sh="${_brew_prefix}/var/aiteamforge/env.sh"
    if [[ -f "$_atf_env_sh" ]]; then
        # shellcheck disable=SC1090
        source "$_atf_env_sh"
    fi
    if [[ -n "${AITEAMFORGE_PYTHON:-}" && -x "$AITEAMFORGE_PYTHON" ]]; then
        echo "$AITEAMFORGE_PYTHON"; return 0
    fi
    _p="${_brew_prefix}/var/aiteamforge/venv/bin/python3"
    if [[ -x "$_p" ]]; then echo "$_p"; return 0; fi
    _p="${AITEAMFORGE_DIR:-$HOME/aiteamforge}/share/venv/bin/python3"
    if [[ -x "$_p" ]]; then echo "$_p"; return 0; fi
    echo "python3"   # last-resort (dev source machine has deps globally)
}

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

    # -------------------------------------------------------------------------
    # XACA-0661 (007): Per-port startup lock — serialize concurrent invocations.
    #
    # ROOT CAUSE: pkill -f "server.py.*<PORT>" runs UNCONDITIONALLY near the top
    # of every start_lcars_server call.  If two invocations race (two terminals,
    # tmux re-attach, upgrade re-running startup), the SECOND call's pkill sends
    # SIGTERM (status 143) to the FIRST call's freshly-launched, still-warming-up
    # server — killing it before or just after /api/status 200.
    #
    # FIX: a per-port advisory lock using `mkdir` (POSIX-atomic on macOS and
    # Linux under both bash 3.2 and zsh).  The lock is scoped to the PORT (not
    # the team name) because pkill targets a port; two different teams on
    # different ports must not block each other.
    #
    # LOCK PRIMITIVE — WHY mkdir, NOT noclobber redirect:
    #   `(set -C; echo $$ > file)` is also atomic, but `set -C` is a shell option
    #   that interacts with `set -u` and zsh's noclobber differently across
    #   versions; the interaction has caused silent failures before
    #   (feedback_removing_guard_unmasks_empty_array_set_u).  `mkdir` is a single
    #   syscall with no shell-option dependency and is universally supported.
    #
    # LOCK DIRECTORY: /tmp/lcars-start-lock-<PORT>
    #   Holds one file: "pid" containing the holder's PID.
    #
    # STALE-LOCK POLICY (the hard part):
    #   A crashed or killed prior holder must not deadlock all future starts.
    #   After mkdir fails, we read the PID from $lockdir/pid and apply two tests:
    #     1. Liveness:  kill -0 $holder_pid fails → holder is dead → reclaim now.
    #     2. Age:       lockdir mtime > 30s old → holder is stuck/zombie → reclaim.
    #        30s is generous: the poll window is 15s; a legitimate holder should
    #        always complete (success or failure) within that window.
    #   If the holder is alive AND recent, we wait up to 20s (40 × 0.5s), re-
    #   checking each half-second.  After 20s we reclaim anyway and proceed.
    #
    # SHORT-CIRCUIT — healthy server already up:
    #   After acquiring the lock (immediately or after waiting), we check whether
    #   a server is ALREADY answering /api/status on this port.  If so, a prior
    #   invocation completed successfully while we were waiting; we skip the
    #   pkill+relaunch entirely and return 0.  This is the most common outcome
    #   when two sessions start the same team concurrently — the second one
    #   arrives after the first has fully started.
    #
    # RELEASE PATHS — guaranteed via RETURN trap:
    #   A `trap ... RETURN` inside a shell function fires on every exit path
    #   (return 0, return 1, and implicit fall-through).  We set this trap
    #   immediately after acquiring the lock and clear it when we deliberately
    #   release (to avoid a double-remove on normal exit if the trap fires after
    #   our explicit rm already ran).  All five named return points below (①②③④⑤)
    #   are covered.
    # -------------------------------------------------------------------------
    local _lock_dir="/tmp/lcars-start-lock-${port}"

    # Lock-release helper: called before every return in this function.
    # Defined as a named function (not an inner function) because zsh does not
    # support `trap ... RETURN` inside a function — that pseudo-signal is a bash
    # extension (feedback confirmed by: zsh -c 'f(){trap ":" RETURN};f' emitting
    # "undefined signal: RETURN").  Explicit call on each of the five exit paths
    # below is the portable alternative.  rm -rf on a non-existent dir is a
    # silent no-op, so double-release is harmless.
    _lcars_start_lock_release() { rm -rf "${_lock_dir}" 2>/dev/null || true; }

    # Attempt atomic acquire (mkdir is a single atomic syscall on macOS and
    # Linux under both bash 3.2 and zsh — no shell option dependencies).
    if ! mkdir "${_lock_dir}" 2>/dev/null; then
        # Lock is held by another invocation.  Apply stale-lock tests, then wait.
        local _holder_pid=""
        _holder_pid="$(cat "${_lock_dir}/pid" 2>/dev/null || true)"

        local _waited=0
        local _reclaimed=0
        # Declare age-check variables before the loop (zsh emits "VAR=value" to
        # stdout on the 2nd+ iteration of `local VAR=...` inside a loop —
        # feedback_zsh-local-in-loop-gotcha).
        local _mtime _now _lock_age
        while true; do
            # Test 1: lock directory gone — holder released while we were polling.
            if [[ ! -d "${_lock_dir}" ]]; then
                break
            fi

            # Test 2: holder liveness — kill -0 fails → process is dead → stale lock.
            if [[ -n "${_holder_pid}" ]] && ! kill -0 "${_holder_pid}" 2>/dev/null; then
                echo "    ⚠️  start_lcars_server: stale lock on port ${port} (pid ${_holder_pid} dead) — reclaiming." >&2
                rm -rf "${_lock_dir}" 2>/dev/null || true
                _reclaimed=1
                break
            fi

            # Test 3: age guard — lockdir mtime > 30s → holder is stuck/zombie.
            # 30s is conservative: the poll window is 15s; a healthy holder completes
            # (success or failure) well within that window.
            # Portable mtime: GNU `stat -c %Y` first (Linux), then BSD `stat -f %m`
            # (macOS).  GNU-first matters because BSD `stat -f %m` does NOT error on
            # Linux — `-f` means "filesystem" there and exits 0 with junk, so the
            # `|| echo 0` fallback would never fire (XACA-0661-008).  macOS stat
            # rejects `-c` (exit 1) and falls through to the BSD form correctly.
            _mtime="$(stat -c %Y "${_lock_dir}" 2>/dev/null || stat -f %m "${_lock_dir}" 2>/dev/null || echo "0")"
            _now="$(date +%s)"
            _lock_age=$(( _now - _mtime ))
            if [[ "${_lock_age}" -gt 30 ]]; then
                echo "    ⚠️  start_lcars_server: lock on port ${port} is ${_lock_age}s old (pid ${_holder_pid:-?} may be stuck) — reclaiming." >&2
                rm -rf "${_lock_dir}" 2>/dev/null || true
                _reclaimed=1
                break
            fi

            # Live, recent holder — wait 0.5s and try again (up to 20s total).
            if [[ "${_waited}" -eq 0 ]]; then
                echo "    ⏳ start_lcars_server: port ${port} is being started by pid ${_holder_pid:-?} — waiting up to 20s..." >&2
            fi
            sleep 0.5
            _waited=$(( _waited + 1 ))
            if [[ "${_waited}" -ge 40 ]]; then
                echo "    ⚠️  start_lcars_server: waited 20s for lock on port ${port} — reclaiming to prevent deadlock." >&2
                rm -rf "${_lock_dir}" 2>/dev/null || true
                _reclaimed=1
                break
            fi
        done

        # After waiting/reclaiming, try to acquire the lock.
        if ! mkdir "${_lock_dir}" 2>/dev/null; then
            # Extremely rare: another process raced us after our reclaim.
            # Proceed without a lock — better to attempt a start than deadlock.
            echo "    ⚠️  start_lcars_server: could not re-acquire lock on port ${port} after reclaim — proceeding unlocked." >&2
        else
            echo "${$}" > "${_lock_dir}/pid" 2>/dev/null || true

            # SHORT-CIRCUIT: if another starter finished while we waited, a healthy
            # server may already be up.  Skip pkill+relaunch if so.
            if [[ "${_waited}" -gt 0 || "${_reclaimed}" -eq 1 ]]; then
                if curl -s --max-time 1 "http://localhost:${port}/api/status" >/dev/null 2>&1; then
                    echo "    ✅ LCARS server already up on port ${port} (started while we waited)" >&2
                    _lcars_start_lock_release
                    return 0  # ① short-circuit: concurrent starter finished cleanly
                fi
            fi
        fi
    else
        echo "${$}" > "${_lock_dir}/pid" 2>/dev/null || true
    fi

    # XACA-0626: startup-time port drift guard.
    # Must run BEFORE the server binds so the .port file is correct before any
    # connect script reads it. Soft-fail: guard never aborts startup.
    _lcars_port_drift_guard "$team" "$port" "$session_name" "$_atf_base" || true

    # Write the router redirect so the UI knows which team dashboard to show.
    # This must happen BEFORE the server starts; the file is read on first load.
    echo "window.LCARS_TARGET_TEAM = '${team}';" > "${lcars_ui_dir}/lcars-target.js"

    # Kill any stale server process on this port. Stale processes are normal
    # (previous session crash, leftover from a prior startup). Errors here are
    # expected when nothing is running; suppress them.
    #
    # XACA-0661 (005): anchor the port at a word boundary (space before, end-of-
    # cmdline or non-digit after) to prevent a broader-than-intended match.
    # The server is always launched as:  python3 server.py <PORT>
    # so the port is the last argument.  Using "[[:space:]]${port}([[:space:]]|$)"
    # avoids matching e.g. "server.py 83200" when port=8320.  No registered team
    # port is a numeric prefix of another, so this is defence-in-depth rather than
    # a fix to a live cross-team kill, but it closes the window should ports change.
    #
    # XACA-0661 (007): This pkill now runs UNDER the per-port lock above, so two
    # concurrent starts for the same port cannot interleave their pkill+launch
    # cycles and SIGTERM each other's freshly-started server.
    pkill -f "server\.py[[:space:]].*[[:space:]]${port}([[:space:]]|$)" 2>/dev/null || \
        pkill -f "server\.py[[:space:]]${port}([[:space:]]|$)" 2>/dev/null || true

    # XACA-0486 / XACA-0562 / XACA-0563 / XACA-0614: Resolve the python that has
    # the LCARS runtime imports (pyzipper, requests, etc. from share/requirements.txt).
    # Delegated to resolve_lcars_python() — the single canonical resolver shared with
    # lcars-health-check.sh::_hc_start_lcars_server (XACA-0614 §4).
    # Probe order, override hooks, and last-resort fallback are documented in
    # resolve_lcars_python() above.
    local lcars_python
    lcars_python="$(resolve_lcars_python)"

    # Resolve a log dir consistent with the rendered-template convention
    # (team-startup.sh.template logs to $AITEAMFORGE_DIR/logs/lcars-server-<team>.log).
    # On the dev machine $AITEAMFORGE_DIR is unset, so fall back to dev-team/logs.
    # Use _atf_base (not dirname of lcars_ui_dir) so an LCARS_UI_DIR override does
    # not relocate the logs away from the canonical tree.
    local _log_dir="${_atf_base}/logs"
    mkdir -p "${_log_dir}" 2>/dev/null
    local _server_log="${_log_dir}/lcars-server-${team}.log"

    # XACA-0661: Roll the per-team log at the START of every server-start invocation.
    #
    # WHY: server.py stderr is APPENDED (2>>) to the same log file across restarts.
    # A size-only cap (the prior behavior) left any small log — even one carrying an
    # old FATAL from a prior incident — intact across restarts.  The three failure-
    # path tail calls at the bottom of this function then resurfaced those stale
    # lines, making an unrelated historical FATAL masquerade as the current failure.
    #
    # FIX: unconditionally rotate the log before each launch.
    #   - If a log exists (even tiny), back it up to .old before truncating so a
    #     genuine just-crashed log from the immediately-preceding run is not lost.
    #   - After rotation, the log file starts fresh; every tail only shows current-
    #     start stderr.
    #   - The old size-based cap is preserved inside the rotation: if the outgoing
    #     log is already over 256 KB it is still moved to .old (same as before); a
    #     smaller log is also moved to .old so it is not silently discarded.
    #   - Only one .old backup is kept (mv -f overwrites any prior .old).
    if [[ -f "${_server_log}" ]]; then
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
                # XACA-0661 (005): status 143 = 128+15 = SIGTERM (not SIGHUP=129).
                # The most likely cause of SIGTERM here is a concurrent or re-entrant
                # startup invocation whose pkill targeted the same port, killing this
                # freshly-launched server before or just after it answered /api/status.
                # SIGHUP (129) would indicate the nohup/disown protection failed.
                local _reason="startup-script SIGHUP suspected"
                if [[ "${_rc}" -eq 143 ]]; then
                    _reason="SIGTERM received (likely: concurrent startup re-entrancy — another legal/team startup script ran pkill on this port while this server was starting)"
                elif [[ "${_rc}" -eq 129 ]]; then
                    _reason="SIGHUP received — nohup/disown protection may have failed (XACA-0652 regression)"
                fi
                echo "    ❌ LCARS server for team '${team}' on port ${port} responded once then exited (status ${_rc}) — ${_reason}." >&2
                echo "       Last lines of ${_server_log}:" >&2
                tail -n 15 "${_server_log}" 2>/dev/null | sed 's/^/         /' >&2
                _lcars_start_lock_release
                return 1  # ② momentary-truth / post-200 death
            fi
            echo "    ✅ LCARS server ready on port ${port} (pid ${_server_pid})"
            _lcars_start_lock_release
            return 0  # ③ success — server is up and healthy
        fi
        if ! kill -0 "${_server_pid}" 2>/dev/null; then
            wait "${_server_pid}" 2>/dev/null; local _rc=$?
            # XACA-0661 (005): decode the exit status for actionable diagnostics.
            local _reason2="server crashed or was killed"
            if [[ "${_rc}" -eq 143 ]]; then
                _reason2="SIGTERM received (likely: concurrent startup re-entrancy — another startup script ran pkill on port ${port})"
            elif [[ "${_rc}" -eq 129 ]]; then
                _reason2="SIGHUP received — nohup/disown protection may have failed (XACA-0652 regression)"
            fi
            echo "    ❌ LCARS server for team '${team}' on port ${port} exited (status ${_rc}) before becoming ready — ${_reason2}." >&2
            echo "       Last lines of ${_server_log}:" >&2
            tail -n 15 "${_server_log}" 2>/dev/null | sed 's/^/         /' >&2
            _lcars_start_lock_release
            return 1  # ④ crashed before answering /api/status
        fi
        sleep 0.5
    done

    # Window elapsed but the process is still alive (slow/hung boot). Surface
    # the log tail instead of a bare timeout. Do NOT abort — the tab may still
    # work once iTerm2 opens it; let the caller decide whether to proceed.
    echo "    ⚠️  LCARS server for team '${team}' on port ${port} did not become ready within 15s (process still running, pid ${_server_pid})." >&2
    echo "       Recent ${_server_log}:" >&2
    tail -n 15 "${_server_log}" 2>/dev/null | sed 's/^/         /' >&2
    _lcars_start_lock_release
    return 1  # ⑤ timeout — process alive but not answering
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

# ---------------------------------------------------------------------------
# deploy_team_personas <team-slug> <Display-Label> [<project-dir>]
#
# Deploy a multi-project personal team's personas into the project dir's
# .claude/agents at startup. These teams (legal/finance/medical) work inside
# ~/<team>/<PROJECTID> — a nested git repo the static persona manifest cannot
# enumerate — so plain `kb-sync-personas sync` (umbrella target) never reaches
# it and a session there loads zero personas. kb-sync-personas's XACA-0660
# nested-root deploy (`sync-worktrees`) resolves each inner git root and
# populates it (kept untracked via the repo's .git/info/exclude). Idempotent:
# re-runs hash-compare and refresh on master persona changes.
#
# Arguments:
#   1  team-slug   — e.g. "legal", "finance", "medical"
#   2  label       — display name for output (defaults to team-slug)
#   3  project-dir — REQUIRED on tap-consumer machines: absolute path to the
#                    project's git repo root (e.g. $PROJECT_DIR). Falls back
#                    to $PWD when omitted, but callers SHOULD pass it explicitly
#                    because startup scripts are typically invoked from a
#                    different directory than the project root. (XACA-0667 fix)
#
# Single shared implementation (XACA-0666-001, anti k501 sibling-drift): the
# legal/finance/medical startup scripts call THIS rather than each carrying a
# copy of the guard + invocation. kb-sync-personas is dev-team-only (not
# tap-mirrored); the `[ -x ]` guard makes this a safe no-op on a tap-installed /
# non-dev host, and the `|| echo` keeps a tool failure from ever aborting team
# startup (parity with the surrounding `kb_ensure_team_initialized ... || true`).
# Path resolves via the portable base, same as the rest of this helper.
# ---------------------------------------------------------------------------
deploy_team_personas() {
    local team="${1:?deploy_team_personas: team slug required}"
    local label="${2:-$team}"
    local project_dir="${3:-$PWD}"
    local _atf_base="${AITEAMFORGE_DIR:-$HOME/dev-team}"
    local _sync_tool="${_atf_base}/scripts/kb-sync-personas"
    if [ -x "$_sync_tool" ]; then
        # Dev machine path (kb-sync-personas present): unchanged behaviour.
        echo "   Syncing ${label} personas into project dir..."
        "$_sync_tool" sync-worktrees "$team" >/dev/null 2>&1 \
            || echo "   ⚠️  Persona sync skipped (non-fatal; run kb-sync-personas sync-worktrees ${team})"
    else
        # Tap-consumer path (XACA-0667): kb-sync-personas is NOT installed on
        # tap machines. Fall back to deploy-worktree-personas.sh's
        # --nested-main-root mode, which deploys from the tap persona source
        # (${AITEAMFORGE_DIR}/<team>/personas/agents/) into
        # <project_dir>/.claude/agents/ and writes .git/info/exclude so they
        # stay untracked. Non-fatal: a failure emits a warning but never aborts
        # startup.
        local _tap_deploy="${_atf_base}/scripts/deploy-worktree-personas.sh"
        if [ -x "$_tap_deploy" ]; then
            echo "   Deploying ${label} tap personas into project dir..."
            "$_tap_deploy" --nested-main-root "$project_dir" "$team" >/dev/null 2>&1 \
                || echo "   ⚠️  Tap persona deploy skipped (non-fatal; run deploy-worktree-personas.sh --nested-main-root \$project_dir ${team})"
        fi
    fi
}
