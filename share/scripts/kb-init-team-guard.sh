#!/usr/bin/env bash
# shellcheck shell=bash
# kb-init-team-guard.sh — Shared startup guard: detect missing/empty kanban board
#                         and prompt to provision via kb-init-team.
#
# XACA-0542 subitem 003: Single canonical source for the detect-and-prompt logic.
# Subitem 004 wires this into every top-level *-startup.sh.
#
# ---------------------------------------------------------------------------
# USAGE
#   source "/path/to/dev-team/scripts/kb-init-team-guard.sh"
#   kb_ensure_team_initialized <team-id> <kanban-dir>
#
# RETURN CODES
#   0  — Board is present and non-empty; caller should proceed normally.
#   1  — Guard detected a missing/empty board AND the user chose NOT to
#         provision (or the environment is non-interactive and auto-yes is not
#         set). Caller should decide whether to abort or continue headless.
#   2  — Provisioning was attempted but kb-init-team failed. Caller should
#         abort or warn loudly.
#
# ---------------------------------------------------------------------------
# INTERACTIVE vs NON-INTERACTIVE DETECTION
#
# The guard is non-interactive when EITHER of the following is true:
#
#   1. No TTY on stdin:   [ ! -t 0 ]
#      This fires in subshells, CI pipelines, SKIP_ATTACH=1 runs, and
#      background process forks (the normal case for startup-script children).
#
#   2. Env var override:  KB_CI=1  or  CI=1
#      Callers that want to force non-interactive mode (CI runners, automated
#      tests, headless provisioning scripts) set one of these. KB_CI takes
#      precedence. CI is honoured as a widely-recognised convention.
#
# When non-interactive:
#   - The guard logs a WARNING to stderr (never blocks).
#   - Returns 1 (missing board) WITHOUT prompting or provisioning.
#   - Exception: if KB_INIT_TEAM_AUTO_YES=1 is set, the guard provisions
#     automatically and returns 0 on success or 2 on failure. This is an
#     explicit opt-in — callers that want unattended provisioning MUST set it.
#
# ---------------------------------------------------------------------------
# kb-init-team INTEGRATION
#
# kb-init-team --check-only validates ALL 12 registration sites (Python
# imports, shell case statements, JSON files, etc.). That is valuable for
# post-registration verification but is too heavy and too strict for a
# startup-time guard:
#
#   • Heavy: imports Python + reads multiple files on every startup.
#   • Over-strict: many pre-existing teams have a working board.json but are
#     not registered at all 12 check-only sites (they pre-date kb-init-team).
#     Flagging those teams as "uninitialized" would spam every startup.
#
# This guard answers a narrower, cheaper question:
#   "Is there a board file I can actually use?"
#   = kanban dir exists  AND  board JSON exists  AND  board has at least one
#     entry in the "backlog" array (even if all are completed/cancelled).
#
# When initialization IS needed, kb-init-team is invoked without --team-id
# so it prompts interactively, giving the user full control over all options.
# ---------------------------------------------------------------------------

# Guard against double-sourcing
if [[ "${_KB_INIT_TEAM_GUARD_LOADED:-0}" == "1" ]]; then
    return 0
fi
_KB_INIT_TEAM_GUARD_LOADED=1

# ── Colour helpers (safe: no-op if terminal lacks colour support) ─────────────
_kbitg_red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
_kbitg_yellow() { printf '\033[0;33m%s\033[0m\n' "$*" >&2; }
_kbitg_green()  { printf '\033[0;32m%s\033[0m\n' "$*" >&2; }
_kbitg_cyan()   { printf '\033[0;36m%s\033[0m\n' "$*" >&2; }

# ── _kb_board_is_present <team-id> <kanban-dir> ───────────────────────────────
# Returns 0 if a usable board exists; 1 if it is missing or empty.
# Usable = kanban dir exists AND board JSON exists AND backlog array is
# non-empty (at least one item, regardless of status).
_kb_board_is_present() {
    local team_id="$1"
    local kanban_dir="$2"

    # 1. Kanban directory must exist.
    if [[ ! -d "$kanban_dir" ]]; then
        return 1
    fi

    # 2. Board JSON file must exist.
    local board_file="${kanban_dir}/${team_id}-board.json"
    if [[ ! -f "$board_file" ]]; then
        return 1
    fi

    # 3. Board JSON must be non-empty (file size > 10 bytes as a fast pre-check
    #    before parsing).
    if [[ ! -s "$board_file" ]]; then
        return 1
    fi

    # 4. Board must have at least one item in "backlog" (parsed check).
    #    Use python3 for reliable JSON parsing; fall back to grep if unavailable.
    if command -v python3 &>/dev/null; then
        # XACA-0542-019: pass board_file as argv (quoted heredoc) rather than
        # interpolating it into the Python source — robust to paths containing
        # single quotes or other Python-string-breaking characters.
        python3 - "$board_file" << 'PYEOF' 2>/dev/null
import json, sys
try:
    b = json.load(open(sys.argv[1]))
    backlog = b.get('backlog', [])
    sys.exit(0 if isinstance(backlog, list) and len(backlog) > 0 else 1)
except Exception:
    sys.exit(1)
PYEOF
        return $?
    else
        # Fallback: grep for at least one item id pattern (e.g. "XACA-0001")
        if grep -qE '"id"[[:space:]]*:[[:space:]]*"[A-Z]' "$board_file" 2>/dev/null; then
            return 0
        fi
        return 1
    fi
}

# ── _kb_is_noninteractive ─────────────────────────────────────────────────────
# Returns 0 (true = non-interactive) when:
#   - KB_CI=1, or
#   - CI=1 (common CI convention), or
#   - stdin is not a TTY.
_kb_is_noninteractive() {
    if [[ "${KB_CI:-0}" == "1" ]]; then return 0; fi
    if [[ "${CI:-}"   == "1" ]]; then return 0; fi
    if [[ ! -t 0 ]]; then return 0; fi
    return 1
}

# ── kb_ensure_team_initialized <team-id> <kanban-dir> ────────────────────────
#
# Main entry point. Call this early in a *-startup.sh before any kanban work.
#
# ARGUMENTS
#   team-id      The team identifier, e.g. "academy" or "freelance-bandwear-android"
#   kanban-dir   Absolute path to the team's kanban directory
#
# RETURN CODES (see file header for full contract)
#   0  — board present and usable, or provisioning succeeded
#   1  — board missing/empty and not provisioned (caller decides what to do)
#   2  — provisioning was attempted but kb-init-team exited non-zero
#
# ENVIRONMENT
#   KB_INIT_TEAM_AUTO_YES=1  — Non-interactive auto-provision opt-in (CI use)
#   KB_CI=1 / CI=1           — Force non-interactive mode
#   KB_INIT_TEAM_BIN         — Override path to kb-init-team (default: auto-locate)
#
kb_ensure_team_initialized() {
    local team_id="${1:?kb_ensure_team_initialized: team-id argument is required}"
    local kanban_dir="${2:?kb_ensure_team_initialized: kanban-dir argument is required}"

    # ── Fast path: board is present and usable ────────────────────────────────
    if _kb_board_is_present "$team_id" "$kanban_dir"; then
        return 0
    fi

    # ── Locate kb-init-team ───────────────────────────────────────────────────
    local kbit_bin
    if [[ -n "${KB_INIT_TEAM_BIN:-}" ]]; then
        kbit_bin="$KB_INIT_TEAM_BIN"
    else
        # Derive from this file's own location: scripts/kb-init-team-guard.sh
        # → sibling: scripts/kb-init-team
        # Shell-agnostic self-location: BASH_SOURCE is EMPTY under zsh (every
        # *-startup.sh caller is #!/bin/zsh), so fall back to zsh's prompt-
        # expansion %x (file of the source currently executing) then $0. (XACA-0548)
        local _self _guard_dir
        if [ -n "${BASH_SOURCE:-}" ]; then
            _self="${BASH_SOURCE[0]}"
        elif [ -n "${ZSH_VERSION:-}" ]; then
            _self="${(%):-%x}"
        else
            _self="$0"
        fi
        _guard_dir="$(cd "$(dirname "$_self")" && pwd)"
        kbit_bin="${_guard_dir}/kb-init-team"
    fi

    if [[ ! -x "$kbit_bin" ]]; then
        _kbitg_red "[kb-guard] kb-init-team not found or not executable: ${kbit_bin}"
        _kbitg_yellow "[kb-guard] Team '${team_id}' board is missing. Provision manually:"
        _kbitg_yellow "           ${kbit_bin} --team-id ${team_id} --kanban-dir ${kanban_dir}"
        return 1
    fi

    # ── Non-interactive branch ────────────────────────────────────────────────
    if _kb_is_noninteractive; then
        if [[ "${KB_INIT_TEAM_AUTO_YES:-0}" == "1" ]]; then
            # Explicit opt-in: auto-provision without prompting.
            _kbitg_yellow "[kb-guard] Non-interactive auto-provision for team '${team_id}' (KB_INIT_TEAM_AUTO_YES=1)"
            "$kbit_bin" \
                --team-id   "$team_id" \
                --kanban-dir "$kanban_dir" \
                --non-interactive
            local rc=$?
            if [[ $rc -eq 0 ]]; then
                _kbitg_green "[kb-guard] Team '${team_id}' provisioned successfully."
                return 0
            else
                _kbitg_red "[kb-guard] kb-init-team failed (exit ${rc}) for team '${team_id}'."
                return 2
            fi
        else
            # Default safe behavior: warn and continue WITHOUT provisioning.
            _kbitg_yellow ""
            _kbitg_yellow "[kb-guard] WARNING: kanban board missing or empty for team '${team_id}'."
            _kbitg_yellow "  Kanban dir : ${kanban_dir}"
            _kbitg_yellow "  Board file : ${kanban_dir}/${team_id}-board.json"
            _kbitg_yellow ""
            _kbitg_yellow "  Non-interactive mode — will NOT provision automatically."
            _kbitg_yellow "  To provision: run kb-init-team --team-id ${team_id} --kanban-dir ${kanban_dir}"
            _kbitg_yellow "  To auto-provision in CI: set KB_INIT_TEAM_AUTO_YES=1"
            _kbitg_yellow ""
            return 1
        fi
    fi

    # ── Interactive branch ────────────────────────────────────────────────────
    printf '\n' >&2
    _kbitg_yellow "┌─────────────────────────────────────────────────────────────────┐"
    _kbitg_yellow "│  KANBAN BOARD NOT FOUND                                         │"
    _kbitg_yellow "├─────────────────────────────────────────────────────────────────┤"
    _kbitg_yellow "│  Team      : ${team_id}"
    _kbitg_yellow "│  Kanban dir: ${kanban_dir}"
    _kbitg_yellow "│"
    _kbitg_yellow "│  The board JSON is missing or empty. Without it, kanban commands"
    _kbitg_yellow "│  (kb-show, kb-backlog, etc.) will fail."
    _kbitg_yellow "└─────────────────────────────────────────────────────────────────┘"
    printf '\n' >&2

    local response
    while true; do
        printf '[kb-guard] Initialize this team now? [y/N]: ' >&2
        read -r response </dev/tty 2>/dev/null || { response="n"; break; }
        case "${response,,}" in
            y|yes) break ;;
            n|no|"") response="n"; break ;;
            *) _kbitg_yellow "  Please enter y or n." ;;
        esac
    done

    if [[ "${response,,}" != "y" && "${response,,}" != "yes" ]]; then
        _kbitg_yellow "[kb-guard] Skipped. Kanban commands may fail until the team is initialized."
        _kbitg_yellow "           Run: ${kbit_bin} --team-id ${team_id} --kanban-dir ${kanban_dir}"
        return 1
    fi

    # User confirmed — invoke kb-init-team interactively.
    # Pre-fill team-id and kanban-dir; let kb-init-team prompt for the rest.
    printf '\n' >&2
    _kbitg_cyan "[kb-guard] Launching kb-init-team for team '${team_id}'..."
    printf '\n' >&2

    "$kbit_bin" \
        --team-id    "$team_id" \
        --kanban-dir "$kanban_dir"
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        _kbitg_green "[kb-guard] Team '${team_id}' initialized successfully."
        return 0
    else
        _kbitg_red "[kb-guard] kb-init-team failed (exit ${rc}) for team '${team_id}'."
        return 2
    fi
}
