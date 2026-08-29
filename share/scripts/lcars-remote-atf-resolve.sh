#!/usr/bin/env zsh
# shellcheck shell=bash
# lcars-remote-atf-resolve.sh — Shared helper: resolve the AITeamForge
# install directory on a REMOTE host (XACA-1006-001).
#
# THE BUG THIS FIXES: *-connect.sh scripts open an agent panel by ssh-ing to
# a remote host and running "${REMOTE_ATF_DIR}/scripts/agent-panel-display.sh"
# there. 6 of 11 scripts never probed the remote at all (they just reused the
# LOCAL AITEAMFORGE_DIR, e.g. the dev-team checkout under $HOME on the machine running the
# connect script — wrong host entirely). The other 5 probed with
# `[ -d "$candidate" ]` across two hardcoded directories, which is fooled by
# a same-named DECOY directory that exists but is not an AITeamForge install
# (e.g. a kanban-data-only dev-team checkout under $HOME with no scripts/ subtree).
#
# THE FIX: probe for the FILE this caller is about to invoke
# (scripts/agent-panel-display.sh), not merely a directory, across three
# candidates in priority order:
#   1. $(brew --prefix)/opt/aiteamforge/libexec/share   (tap install)
#   2. $HOME/aiteamforge
#   3. the dev-team checkout under $HOME
# The first candidate whose scripts/agent-panel-display.sh exists wins. If
# NONE match, fail loudly — never silently fall back to a guess, which is
# the exact shape of the original bug.
#
# ONE ssh ROUND TRIP: all three candidates are tested inside a single
# remote invocation (the probe body below is piped over stdin to
# `ssh ... /bin/zsh -s`), matching the "already ssh several times, don't add
# more" constraint these connect scripts operate under.
#
# USAGE — MANDATORY HARD DEPENDENCY. Do NOT soft-source this with `|| true`
# the way scripts/lcars-launch-helpers.sh is soft-sourced for the OPTIONAL
# iTerm2-detection nicety. An undefined function here (because the file was
# silently missing) reproduces the exact "assumed the path exists on the
# other machine" failure shape this whole ticket exists to eliminate:
#
#   if ! source "${AITEAMFORGE_DIR}/scripts/lcars-remote-atf-resolve.sh"; then
#       echo "  ✗ FATAL: required helper scripts/lcars-remote-atf-resolve.sh" >&2
#       echo "    not found under \$AITEAMFORGE_DIR. Run 'aiteamforge upgrade'." >&2
#       exit 1
#   fi
#   if ! REMOTE_ATF_DIR="$(lcars_resolve_remote_atf_dir "$HOST")"; then
#       exit 1   # lcars_resolve_remote_atf_dir already wrote a loud,
#                # host-named, candidate-itemized error to stderr
#   fi
#
# lcars_resolve_remote_atf_dir prints ONLY the resolved absolute remote path
# to stdout on success (exit 0), with no trailing content. On failure it
# prints NOTHING to stdout and writes a detailed error to stderr (exit 1).
#
# CANONICAL SOURCE: this file (dev-team/scripts/). homebrew-tap/share/ carries
# only a COPY, mirrored by sync-tap.sh — patch here first (see CLAUDE.md
# "canonical-source rule", XACA-0340).

# XACA-0614-013-style injection guard (same character blacklist medical-
# connect.sh already applies to REMOTE_ATF_DIR): the resolved path gets
# interpolated by CALLERS into a single-quoted remote zsh command string, so
# reject characters that would break that quoting or inject extra commands.
# '$' and '/' are intentionally allowed — a literal "$HOME/aiteamforge"
# return value is expected and expands correctly on the remote side.
_lcars_atf_path_is_safe() {
    case "$1" in
        *\'*|*\`*|*\;*|*'&'*|*'|'*|*$'\n'*) return 1 ;;
        *) return 0 ;;
    esac
}

# lcars_resolve_remote_atf_dir <host>
# Prints the resolved remote AITeamForge dir to stdout and returns 0, or
# prints nothing to stdout, writes a loud diagnostic to stderr, and returns
# 1. Never guesses.
lcars_resolve_remote_atf_dir() {
    local host="$1"
    if [ -z "$host" ]; then
        echo "  ✗ lcars_resolve_remote_atf_dir: no host given" >&2
        return 1
    fi

    # Probe body runs on the REMOTE host via a single `ssh ... /bin/zsh -s`
    # call (script fed over stdin, delimiter quoted so nothing local-expands
    # before it's sent). Written in a POSIX/bash-3.2-safe subset so it
    # behaves identically whether the remote's default shell interpreter is
    # zsh (the family convention for these connect scripts) or bash.
    local remote_out
    remote_out="$(ssh -o ConnectTimeout=5 -o BatchMode=yes -- "$host" /bin/zsh -s 2>&1 <<'REMOTE_PROBE'
# `ssh ... /bin/zsh -s` is a non-login, non-interactive shell: it does NOT
# source .zprofile/.zshrc, so the Homebrew PATH shellenv line never runs and
# `command -v brew` silently fails even when Homebrew is installed and
# healthy (observed live on darren-m4-mini: candidate 1 resolved empty and
# the probe fell through to $HOME/aiteamforge instead of the tap install).
# Locate the brew binary directly first (Apple Silicon then Intel default
# prefixes), falling back to PATH lookup only if neither exists — then ask
# THAT binary for --prefix so a customized HOMEBREW_PREFIX is still honored
# rather than hardcoding one of the two default prefixes as the answer.
brew_bin=""
for _cand_brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$_cand_brew" ]; then
        brew_bin="$_cand_brew"
        break
    fi
done
if [ -z "$brew_bin" ] && command -v brew >/dev/null 2>&1; then
    brew_bin="brew"
fi
d1=""
if [ -n "$brew_bin" ]; then
    bp=$("$brew_bin" --prefix 2>/dev/null)
    if [ -n "$bp" ]; then
        d1="$bp/opt/aiteamforge/libexec/share"
    fi
fi
d2="$HOME/aiteamforge"
# XACA-1006-010: do NOT write that literal path form here. This value is a
# path on the REMOTE host, but the upgrade renderer in aiteamforge-upgrade.sh,
# _xaca0608_render_team_script() rewrites that exact literal (and the braced
# and tilde forms) to the CONSUMING machine local WORKING_DIR whenever it
# materializes a file from the mandatory set -- which this helper joined in
# XACA-1006-004a. That rewrite is correct for files where the literal means "my
# own base dir"; it is wrong here, and would silently bake a local path into a
# remote probe candidate on every `aiteamforge upgrade`. Assembling the string
# keeps it out of the sed chain reach. Compare remote-tmux-attach.sh, the other
# remote-delegated file in that set, which sidesteps this by never embedding the
# literal at all (it takes the path as an argument).
_dt="dev-team"
d3="$HOME/$_dt"
for d in "$d1" "$d2" "$d3"; do
    if [ -n "$d" ] && [ -f "$d/scripts/agent-panel-display.sh" ]; then
        echo "LCARS_ATF_FOUND:$d"
        exit 0
    fi
done
echo "LCARS_ATF_NOTFOUND:$d1|$d2|$d3"
exit 1
REMOTE_PROBE
)"
    local ssh_status=$?

    local found_line
    found_line="$(printf '%s\n' "$remote_out" | grep '^LCARS_ATF_FOUND:' | tail -1)"
    if [ -n "$found_line" ]; then
        local resolved="${found_line#LCARS_ATF_FOUND:}"
        if ! _lcars_atf_path_is_safe "$resolved"; then
            echo "  ✗ Remote AITeamForge dir on '${host}' contains unsafe characters: ${resolved}" >&2
            echo "    Refusing to use it. Investigate the remote install before retrying." >&2
            return 1
        fi
        printf '%s\n' "$resolved"
        return 0
    fi

    # No candidate matched, or ssh itself failed before the probe could run
    # (host unreachable, auth failure, ConnectTimeout, etc). Either way: fail
    # loudly and name exactly what was tried — never fall back to a guess.
    echo "  ✗ Could not resolve the AITeamForge install dir on remote host '${host}'." >&2
    local notfound_line
    notfound_line="$(printf '%s\n' "$remote_out" | grep '^LCARS_ATF_NOTFOUND:' | tail -1)"
    if [ -n "$notfound_line" ]; then
        echo "    Probed the following candidates on ${host} (none contained scripts/agent-panel-display.sh):" >&2
        local probed remaining seg
        probed="${notfound_line#LCARS_ATF_NOTFOUND:}"
        remaining="$probed"
        while [ -n "$remaining" ]; do
            case "$remaining" in
                *"|"*)
                    seg="${remaining%%|*}"
                    remaining="${remaining#*|}"
                    ;;
                *)
                    seg="$remaining"
                    remaining=""
                    ;;
            esac
            if [ -n "$seg" ]; then
                echo "      - ${seg}" >&2
            fi
        done
    else
        echo "    ssh to '${host}' failed (exit ${ssh_status}) before any candidate could be probed." >&2
        if [ -n "$remote_out" ]; then
            echo "    ssh output: ${remote_out}" >&2
        fi
    fi
    echo "    Refusing to silently fall back to a guess — run 'aiteamforge upgrade' on ${host}, or verify SSH connectivity/auth." >&2
    return 1
}
