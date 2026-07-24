#!/usr/bin/env zsh
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
# lcars_runtime_target_file
#
# XACA-0798: THE single canonical location of the RUNTIME router-redirect file.
#
# Prints the absolute path every runtime writer must use, and guarantees the
# parent directory exists so no call site has to remember its own `mkdir -p`.
#
# WHY THIS FILE MOVED OUT OF lcars-ui/
#   The `com.aiteamforge.lcars-watch` LaunchAgent sets WatchPaths on
#   $AITEAMFORGE_DIR/lcars-ui and fires `aiteamforge restart lcars` on ANY
#   content change under that directory. `start_lcars_server` used to write
#   lcars-target.js INTO that exact directory on every team startup — so every
#   startup tripped the watcher, which SIGTERM'd every server.py on the box,
#   including the one the startup script had launched ~5 seconds earlier
#   (observed `wait` status 143). The 300s lcars-health tick healed it later,
#   and the whole cycle repeated on the NEXT startup. A runtime-mutable file
#   must not live inside a directory that is watched for content changes.
#
#   XACA-0763-004 dodged the same trap on the health-check path with
#   LCARS_SKIP_TARGET_WRITE=1. That escape hatch is NOT the fix here: the
#   startup path legitimately needs to write the target. Moving the file is.
#
# PRECEDENCE (unchanged for the browser; see server.py::serve_lcars_target):
#   1. shipped static default   lcars-ui/lcars-target.js   (install-time only)
#   2. runtime auto file        THIS path                  (startup writes it)
#   3. manual per-machine       ~/.aiteamforge/lcars-target.local.js  (wins)
#   (2) shadows (1) at the /lcars-target.js route; (3) is a SEPARATE chained
#   script load and still wins last. Never auto-write (3) — it is a documented
#   deliberate developer override (XACA-0301) and clobbering it destroys work.
#
# PATH CHOICE: ~/.aiteamforge/ — the same directory that already holds the
# manual override, team-paths.json and run/. It is keyed to $HOME (NOT to
# $AITEAMFORGE_DIR) deliberately, so it matches server.py's `Path.home()`
# resolution of the sibling .local.js file exactly.
#
# LCARS_TARGET_RUNTIME_FILE overrides the path. It exists for TESTS (so a
# regression suite never mutates the operator's real cockpit target) and is
# read by BOTH this helper and server.py, so an override keeps writer and
# reader in agreement. Nothing in production sets it.
# ---------------------------------------------------------------------------
lcars_runtime_target_file() {
    local _f="${LCARS_TARGET_RUNTIME_FILE:-$HOME/.aiteamforge/lcars-target.js}"
    # Parent dir via POSIX suffix-strip, NOT zsh's `${_f:h}` modifier — this
    # helper is also sourced from bash contexts (feedback_zsh_colon_modifier_path).
    # Best-effort: never abort a startup because the dir could not be made;
    # the caller's redirect (`>`) will surface the real error if it matters.
    local _d="${_f%/*}"
    [[ "$_d" != "$_f" ]] && mkdir -p "$_d" 2>/dev/null
    printf '%s\n' "$_f"
    return 0
}

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
# Probe order (XACA-0486/0562/0563/0614, hardened XACA-0713):
#   0. $LCARS_PYTHON (env override)
#   1. KNOWN ABSOLUTE venv paths — probed DIRECTLY, no brew-on-PATH needed
#   2. brew --prefix aiteamforge / libexec/venv (brew located by absolute path
#      if not on PATH)
#   3. env.sh → $AITEAMFORGE_PYTHON
#   4. $(brew --prefix)/var/aiteamforge/venv
#   5. $AITEAMFORGE_DIR/share/venv
#   6. python3  (last-resort; dev source machine has deps globally)
#
# XACA-0713 ROOT CAUSE / FIX:
#   In launchd / non-login (health-daemon) contexts the inherited PATH lacks
#   /opt/homebrew/bin, so `brew --prefix` returned empty → the venv path built
#   from it ("/var/aiteamforge/venv/bin/python3", missing the brew prefix) was
#   not executable → the resolver fell all the way to bare `python3` (the macOS
#   system 3.9.6), which crashes server.py. Probing the FULL ABSOLUTE venv paths
#   FIRST (step 1) makes resolution independent of brew being on PATH, and step 2
#   now also locates the `brew` binary by absolute path so the brew-based probes
#   still work under launchd.
resolve_lcars_python() {
    if [[ -n "${LCARS_PYTHON:-}" && -x "${LCARS_PYTHON}" ]]; then
        echo "${LCARS_PYTHON}"; return 0
    fi

    # 1. Known ABSOLUTE venv interpreters — these do NOT require brew on PATH.
    #    Declared once, before the loop (zsh emits `local VAR` to stdout if it is
    #    re-declared inside a loop — see memory k501-zsh-local-in-loop-gotcha).
    local _cand
    for _cand in \
        /opt/homebrew/var/aiteamforge/venv/bin/python3 \
        /usr/local/var/aiteamforge/venv/bin/python3 \
        /opt/homebrew/opt/aiteamforge/libexec/venv/bin/python3 \
        /usr/local/opt/aiteamforge/libexec/venv/bin/python3 ; do
        if [[ -x "$_cand" ]]; then echo "$_cand"; return 0; fi
    done

    # 2. brew-based probes. Locate `brew` itself by absolute path when it is not
    #    on PATH (the launchd case), so `brew --prefix` works regardless.
    local _brew _p _brew_aitf_prefix
    _brew="$(command -v brew 2>/dev/null)"
    if [[ -z "$_brew" ]]; then
        if [[ -x /opt/homebrew/bin/brew ]]; then _brew=/opt/homebrew/bin/brew
        elif [[ -x /usr/local/bin/brew ]]; then _brew=/usr/local/bin/brew; fi
    fi
    if [[ -n "$_brew" ]]; then
        if _brew_aitf_prefix="$("$_brew" --prefix aiteamforge 2>/dev/null)" \
           && [[ -x "${_brew_aitf_prefix}/libexec/venv/bin/python3" ]]; then
            echo "${_brew_aitf_prefix}/libexec/venv/bin/python3"; return 0
        fi
    fi

    local _brew_prefix _atf_env_sh
    _brew_prefix=""
    if [[ -n "$_brew" ]]; then _brew_prefix="$("$_brew" --prefix 2>/dev/null)"; fi
    _atf_env_sh="${_brew_prefix}/var/aiteamforge/env.sh"
    if [[ -n "$_brew_prefix" && -f "$_atf_env_sh" ]]; then
        # shellcheck disable=SC1090
        source "$_atf_env_sh"
    fi
    if [[ -n "${AITEAMFORGE_PYTHON:-}" && -x "$AITEAMFORGE_PYTHON" ]]; then
        echo "$AITEAMFORGE_PYTHON"; return 0
    fi
    if [[ -n "$_brew_prefix" ]]; then
        _p="${_brew_prefix}/var/aiteamforge/venv/bin/python3"
        if [[ -x "$_p" ]]; then echo "$_p"; return 0; fi
    fi
    _p="${AITEAMFORGE_DIR:-$HOME/aiteamforge}/share/venv/bin/python3"
    if [[ -x "$_p" ]]; then echo "$_p"; return 0; fi
    echo "python3"   # last-resort (dev source machine has deps globally)
}

# ---------------------------------------------------------------------------
# _lcars_spawn_detached <lcars_ui_dir> <team> <session_name> <lcars_python> <port> <log_file> <atf_base>
#
# XACA-0763 (003): genuine session/process-group detach for the LCARS server
# launch, shared by start_lcars_server AND (via delegation, XACA-0763-004)
# lcars-health-check.sh::_hc_start_lcars_server — so BOTH launch sites get the
# same durability guarantee from one implementation instead of two hand-copied
# ones drifting apart.
#
# ROOT CAUSE this closes: launchd SIGKILLs every process remaining in a job's
# process group the instant that job exits, unless the job's plist sets
# AbandonProcessGroup=true (the sibling half of this fix, in the plists under
# homebrew-tap/). `nohup ... & ; disown` (XACA-0652) is necessary but NOT
# sufficient against that: nohup only makes the child ignore SIGHUP, and
# disown only removes the PID from the launching shell's job table — NEITHER
# changes the process group, and nothing can ignore SIGKILL. A server spawned
# from any launchd job (a LaunchAgent-triggered `aiteamforge restart lcars`,
# the health-check LaunchAgent's own restart) would answer one real
# /api/status 200, get logged as "started successfully", then be SIGKILLed
# milliseconds later when the launching job exited.
#
# FIX: route the launch through _LCARS_SETSID_SRC (below) — a four-line python
# shim, executed via `python -c`, that calls os.setsid() (the only syscall that
# atomically creates a NEW session AND a NEW process group) and then
# os.execvp()'s the real interpreter in place. A double-fork is explicitly NOT
# sufficient here: it reparents the child to init but leaves its process group
# unchanged, so launchd's SIGKILL-to-pgid still lands. Only setsid(2) breaks
# that link. macOS ships no setsid(1) binary, hence the python shim.
#
# WHY INLINE (`python -c`) AND NOT A SHIPPED scripts/lcars-setsid-exec.py FILE:
# a standalone file would be a brand-new MANDATORY runtime dependency, and the
# tap's `update_runtime_helpers` only "refreshes what this machine already
# installed under scripts/" — it never lays down a file that was not previously
# present. A new file therefore reaches FRESH installs but is silently SKIPPED
# on every UPGRADE — i.e. on exactly the already-deployed machines (M4Mini,
# M1Pro) whose reaped servers are the reason XACA-0763 exists. The launch would
# degrade to the unprotected form on the whole existing fleet while looking
# fixed in the repo. (Same class of bug as XACA-0751; see memory
# feedback_upgrade_skips_new_mandatory_shared_module.md.) This file,
# lcars-launch-helpers.sh, is ALREADY installed and refreshed on every machine,
# so carrying the shim source inside it adds ZERO new shipping surface: no
# sync-tap.sh entry, no install lay-down, no upgrade wiring, nothing to drift.
#
# PID TRACKABILITY: os.execvp() REPLACES the process image rather than
# forking, so the PID captured via `$!` right after backgrounding this call is
# the SAME pid that ultimately runs server.py — existing `kill -0 "$pid"`
# liveness checks keep working unmodified. Verified empirically (XACA-0763):
# spawned pid == final `ps -o pid,pgid,sess` pid, with a freshly-created pgid
# that differs from the caller's, and getsid(0) inside the final process
# equal to its own pid (proof a new session was created).
#
# EPERM: os.setsid() raises OSError (EPERM) when the CALLING process is
# ALREADY a process-group leader (can happen depending on how the launching
# shell backgrounds a pipeline). That is a benign, already-correct state — the
# process is already in its own group — so the shim catches it and proceeds
# to exec rather than aborting the launch. Verified empirically: a process
# that setsid()'d itself, then exec'd into the shim, reached the shim's final
# exec successfully instead of crashing on the second (redundant) setsid().
#
# ps eww PARSE INVARIANT: lcars-health-check.sh::detect_lcars_bound_ports
# (XACA-0706) parses each live server's team/port straight out of
# `ps eww -o args=`, anchored on the literal `server.py <PORT>` argv prefix
# and a whitespace-prefixed ` LCARS_TEAM=` env token. Because execvp replaces
# argv wholesale, the shim's own path never appears in the final process's
# argv — verified empirically with a real `ps eww -o args=` on a spawned
# process: the output began with `<python> server.py <PORT>` exactly as
# before, immediately followed by the env blob, with no shim-path leakage.
#
# GRACEFUL DEGRADATION: if the resolved python cannot run the shim at all, the
# `sh -c` exec fails and the server never starts — the same outcome as a broken
# interpreter, surfaced by the existing poll-loop diagnostics below. There is no
# "shim missing" state to degrade around any more, which is the point of
# inlining it.
#
# RETURN CHANNEL — a GLOBAL, deliberately NOT command substitution:
#   Callers MUST invoke this as a plain command and then read the global
#   `_LCARS_SPAWNED_PID`:
#       _lcars_spawn_detached ... ; local _server_pid="${_LCARS_SPAWNED_PID}"
#   NOT as `_server_pid="$(_lcars_spawn_detached ...)"`.
#
#   Why (XACA-0763, caught in review): `$(...)` runs the function in a SUBSHELL.
#   The server would then be backgrounded as a child of that transient subshell,
#   not of the caller. `kill -0 "$pid"` still works (it only needs the pid to
#   exist), so the poll loop LOOKS fine — but `wait "$pid"` in the caller fails
#   with 127 ("not a child of this shell") instead of returning the server's
#   real exit status. start_lcars_server's two crash-diagnostic branches below
#   do exactly `wait "${_server_pid}"; local _rc=$?` and then decode _rc: 143 =>
#   SIGTERM (concurrent-startup pkill re-entrancy, XACA-0661), 129 => SIGHUP
#   (nohup/disown protection regressed, XACA-0652). Under command substitution
#   _rc is ALWAYS 127, so both of those signals would be silently misreported as
#   a generic crash forever — blinding precisely the diagnostics that tell us
#   whether THIS fix regressed. Verified empirically: caller-shell spawn => wait
#   rc=143; `$(...)` spawn => wait rc=127.
#
#   All diagnostics go to stderr; nothing is written to stdout, so a caller that
#   ignores the contract at least does not capture garbage.
# ---------------------------------------------------------------------------
# The shim, as python source. Passed to the interpreter via `python -c "$src"`.
#
# ARGV CONTRACT: for `python -c <src> A B C`, CPython sets sys.argv to
# ['-c', 'A', 'B', 'C'] — so sys.argv[1] is the executable to exec and
# sys.argv[1:] is its full argv (argv[0] included). We invoke it as
#   "$PY" -c "$_LCARS_SETSID_SRC" "$PY" server.py "$PORT"
# which execvp's `"$PY" server.py "$PORT"`. Because execvp REPLACES the process
# image (no fork), the pid is preserved end-to-end: the `$!` captured by the
# caller is the same pid that ultimately runs server.py, so `kill -0 "$pid"` and
# `wait "$pid"` keep working. And because argv is replaced wholesale, neither
# `-c` nor the shim source appears in the final process's `ps eww -o args=` —
# which matters because lcars-health-check.sh::detect_lcars_bound_ports
# (XACA-0706) parses each live server's port from the literal `server.py <PORT>`
# argv prefix and its team from a whitespace-prefixed ` LCARS_TEAM=` env token.
# Any shim leakage into argv would blind that parser.
#
# os.setsid() raises OSError (EPERM) when the calling process is ALREADY a
# process-group leader — a benign, already-correct state (it is already in its
# own group). Swallow it and proceed to exec rather than aborting the launch.
_LCARS_SETSID_SRC='import os, sys
try:
    os.setsid()
except OSError:
    pass
os.execvp(sys.argv[1], sys.argv[1:])'

_lcars_spawn_detached() {
    local _sd_lcars_dir="${1:?_lcars_spawn_detached: lcars_ui_dir required}"
    local _sd_team="${2:?_lcars_spawn_detached: team required}"
    local _sd_session="${3:?_lcars_spawn_detached: session_name required}"
    local _sd_python="${4:?_lcars_spawn_detached: lcars_python required}"
    local _sd_port="${5:?_lcars_spawn_detached: port required}"
    local _sd_log="${6:?_lcars_spawn_detached: log_file required}"
    # $7 (atf_base) accepted for call-site compatibility; no longer needed now
    # that the shim is inline rather than a file resolved under $atf_base/scripts.

    # Values reach `sh` as POSITIONAL PARAMETERS, not as exported _ATF_* env
    # vars (which is what this used to do). Positionals are equally immune to
    # the space-in-path quoting hazard the old comment worried about, and they
    # have two advantages that matter here:
    #   1. The multi-line shim source never enters anyone's ENVIRONMENT. Passed
    #      via `env`, it would be inherited by server.py and would then appear,
    #      newlines and all, in every `ps eww` dump of the running server —
    #      directly in the blob that detect_lcars_bound_ports (XACA-0706) has to
    #      parse, and in every future debugging session's output.
    #   2. `sh`'s positional parameters vanish at `exec`, so nothing survives
    #      into the final process image except the env we explicitly set.
    # Only LCARS_TEAM / LCARS_SESSION_NAME are exported — LCARS_TEAM because
    # server.py needs it AND because detect_lcars_bound_ports keys on it.
    #   $0=sh  $1=ui_dir  $2=team  $3=session  $4=python  $5=shim_src  $6=port
    nohup sh -c 'cd "$1" && exec env \
        LCARS_TEAM="$2" LCARS_SESSION_NAME="$3" \
        "$4" -c "$5" "$4" server.py "$6"' \
        sh \
        "${_sd_lcars_dir}" \
        "${_sd_team}" \
        "${_sd_session}" \
        "${_sd_python}" \
        "${_LCARS_SETSID_SRC}" \
        "${_sd_port}" \
        >/dev/null 2>>"${_sd_log}" &

    # Assign WITHOUT `local` so the caller sees it (global in both bash and zsh).
    # See the RETURN CHANNEL note in this function's header: the pid must be
    # published via a global, never echoed through command substitution, or the
    # background job becomes a child of a subshell and `wait` breaks.
    _LCARS_SPAWNED_PID=$!
    disown "${_LCARS_SPAWNED_PID}" 2>/dev/null || true
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
    #
    # XACA-0798: the destination is lcars_runtime_target_file() —
    # ~/.aiteamforge/lcars-target.js — NOT ${lcars_ui_dir}/lcars-target.js.
    # lcars-ui/ is the com.aiteamforge.lcars-watch WatchPaths directory, so
    # writing there made every team startup fire `aiteamforge restart lcars`,
    # which SIGTERM'd the server this very function had just launched. See the
    # helper's header for the full rationale. lcars-ui/lcars-target.js is now
    # an install-time-only shipped default and is NEVER written at runtime.
    #
    # XACA-0763 (004): suppressible via LCARS_SKIP_TARGET_WRITE=1. The direct
    # callers of start_lcars_server (team-startup.sh, restart_team_lcars) are
    # the user opening/refreshing exactly THAT team's LCARS tab, so the write
    # is correct and intentional there — default behavior (unset) still writes.
    # lcars-health-check.sh::_hc_start_lcars_server, however, now delegates
    # here for EVERY configured team in one health-check sweep; if each
    # delegated call also rewrote lcars-target.js, the LAST team restarted in
    # that sweep would silently retarget the user's LCARS cockpit router
    # regardless of which tab the user was actually viewing. The health-check
    # wrapper sets this (via a `local` — dynamically scoped, visible here for
    # the duration of its call only) to suppress that side effect.
    if [[ "${LCARS_SKIP_TARGET_WRITE:-0}" != "1" ]]; then
        echo "window.LCARS_TARGET_TEAM = '${team}';" > "$(lcars_runtime_target_file)"
    fi

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

    # XACA-0713 (moved here from lcars-health-check.sh::_hc_start_lcars_server
    # as part of XACA-0763-004's delegation): server.py requires Python >= 3.10
    # at RUNTIME (PEP-604 unions are deferred by `from __future__ import
    # annotations`, but other runtime paths may still assume 3.10+). If
    # resolve_lcars_python had to fall back to the macOS system python3 (3.9.6)
    # — e.g. no venv installed, brew unreachable under launchd — the server
    # will crash on boot. Emit a LOUD, unmistakable warning so the failure is
    # diagnosable. This is a WARNING, not a hard abort: the dev source machine
    # intentionally runs a globally-installed 3.x. Now runs for every launch
    # site (team-startup.sh direct calls AND the health-check delegation),
    # instead of only the health-check path as before.
    local _lcars_pyver
    _lcars_pyver="$("$lcars_python" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
    if [[ -n "$_lcars_pyver" ]]; then
        local _lcars_pymaj="${_lcars_pyver%%.*}"
        local _lcars_pymin="${_lcars_pyver#*.}"
        if [[ "$_lcars_pymaj" -lt 3 ]] \
           || { [[ "$_lcars_pymaj" -eq 3 ]] && [[ "$_lcars_pymin" -lt 10 ]]; }; then
            echo "    ############################################################" >&2
            echo "    ## XACA-0713 WARNING: resolved python is ${_lcars_pyver} (< 3.10)" >&2
            echo "    ## interpreter: ${lcars_python}" >&2
            echo "    ## server.py REQUIRES >= 3.10 and will likely CRASH on boot." >&2
            echo "    ## Cause: LCARS venv not found / brew unreachable under this" >&2
            echo "    ## environment (launchd PATH?) — falling back to system python3." >&2
            echo "    ## Fix: ensure the aiteamforge venv exists, or set \$LCARS_PYTHON." >&2
            echo "    ############################################################" >&2
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

    # XACA-0652 / XACA-0763: Durable server launch.
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
    # XACA-0763: a THIRD durability gap exists beyond SIGHUP: when the launching
    # process is itself part of a launchd job's process group (e.g. an
    # `aiteamforge restart lcars` triggered by a LaunchAgent, or the health-check
    # LaunchAgent's own restart), launchd SIGKILLs every process left in that
    # group the instant the job exits — unrelated to SIGHUP, and unignorable.
    # nohup/disown alone do not protect against this because neither changes the
    # process group. _lcars_spawn_detached (above) closes this gap via a real
    # setsid(2), on top of (not instead of) the nohup+disown protection below.
    #
    # FIX: three layers of protection, all still in force:
    #   1. `nohup` makes server.py IGNORE SIGHUP even if it receives one.
    #   2. `disown` removes the PID from the shell's job table, preventing the
    #      shell from SIGHUP'ing the child on exit in interactive/hup-sending
    #      contexts.  `|| true` absorbs the expected "job not found" error that
    #      zsh emits when disown is called from a non-interactive subshell.
    #   3. (XACA-0763) setsid(2) via the shim gives the process its own session
    #      AND process group, so a launchd SIGKILL-to-pgid on the LAUNCHING
    #      job's group no longer reaches it at all.
    #   Together these ensure the server outlives the startup script/job on all
    #   paths: SIGHUP-on-shell-exit, AND SIGKILL-on-launchd-job-exit.
    #
    # PID TRACKABILITY: preserved through the whole chain — see
    # _lcars_spawn_detached's header comment for the empirical verification
    # (spawned PID via `$!` == final `ps -o pid` of the running server.py).
    #
    # STDERR: nohup normally redirects stderr to nohup.out; we override that with
    # an explicit `2>>log` redirect, which takes precedence.  stdout is discarded.
    # Plain call + read the global. NOT `$(...)` — see _lcars_spawn_detached's
    # RETURN CHANNEL header note: a subshell spawn breaks `wait` below (rc 127),
    # silently disabling the 143/129 signal decoding in the two branches after
    # this point.
    local _server_pid
    _lcars_spawn_detached "${lcars_ui_dir}" "${team}" "${session_name}" "${lcars_python}" "${port}" "${_server_log}" "${_atf_base}"
    _server_pid="${_LCARS_SPAWNED_PID}"

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
# resolve_lcars_port_fallback <cksum_input> <base> <range>
#
# Deterministic legacy port derivation for the case where resolve_lcars_port
# fails (prefix absent from the canonical registry). Echoes
# `base + (cksum(input) % range)` on stdout.
#
# Extracted (XACA-0672) from THREE hand-duplicated copies in dns-startup.sh /
# dns-connect.sh / dns-disconnect.sh, each of which inlined
#   8180 + $(echo "dns-framework" | cksum | cut -d' ' -f1) % 20
# with a comment begging callers to keep them byte-identical — a textbook
# k501 sibling-drift hazard (one edit and the bands silently diverge). One
# source of truth now guarantees the three callers always agree.
#
# IMPORTANT — newline sensitivity: cksum is the POSIX CRC checksum of its
# INPUT BYTES. The legacy form piped `echo "$input"` (which appends a trailing
# newline) into cksum; dropping that newline (e.g. printf '%s') changes the CRC
# and shifts the port (dns-framework: 8180 → 8192). We deliberately keep the
# `echo "$input"` form so the value is byte-for-byte identical to the historical
# behaviour and existing deployments are unchanged. The resolver test asserts
# resolve_lcars_port_fallback "dns-framework" 8180 20 == 8180.
#
# Usage (DNS callers):
#   LCARS_PORT="$(resolve_lcars_port "dns")" || \
#     LCARS_PORT="$(resolve_lcars_port_fallback "dns-framework" 8180 20)"
# ---------------------------------------------------------------------------
resolve_lcars_port_fallback() {
    local input="${1:?resolve_lcars_port_fallback: cksum input is required}"
    local base="${2:?resolve_lcars_port_fallback: base port is required}"
    local range="${3:?resolve_lcars_port_fallback: range is required}"
    local _hash
    # Preserve the legacy `echo` (trailing-newline) semantics — see header note.
    _hash="$(echo "$input" | cksum | cut -d' ' -f1)"
    echo "$(( base + _hash % range ))"
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
