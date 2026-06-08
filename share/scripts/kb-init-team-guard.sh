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
#   0  — Board is present and structurally valid; caller should proceed normally.
#         An empty backlog (freshly-provisioned team) is accepted as valid
#         (XACA-0646 — previously required at least one backlog item).
#   1  — Guard detected a missing or structurally invalid board AND the user
#         chose NOT to provision (or the environment is non-interactive and
#         auto-yes is not set). Caller should decide whether to abort or
#         continue headless.
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
#   = kanban dir exists  AND  board JSON exists  AND  the file is a structurally
#     valid rendered board (JSON object with a list "backlog" — empty is fine —
#     a non-empty "team" string, and a "nextId" key). XACA-0646: the previous
#     definition required backlog to be non-empty (at least one item), which
#     wrongly flagged freshly-provisioned teams as uninitialized.
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

# ── _kb_resolve_instance_id <team-id> <kanban-dir> ───────────────────────────
# Resolve a possibly-TEMPLATE team id (e.g. "legal") to its concrete INSTANCE id
# (e.g. "legal-coparenting") for board-file naming and provisioning.
#
# Strategy (first match wins):
#   1. team-paths.json — return the key whose kanban_dir matches <kanban-dir>.
#      Generic and table-free: works for ANY project (legal-divorce,
#      finance-business, …) because the *-startup.sh caller passes the
#      instance's OWN kanban dir. (XACA-0643 — replaces a brittle 3-entry case
#      map that only knew the FIRST project of each parameterized template; see
#      k501 sibling-drift pattern.)
#   2. Built-in fallback for the canonical first-project of each parameterized
#      template — covers the pre-registration window before team-paths.json has
#      the entry on disk.
#   3. The input team-id unchanged (already an instance, or a single-instance team).
_kb_resolve_instance_id() {
    local team_id="$1"
    local kanban_dir="$2"
    local resolved=""

    # 1. team-paths.json lookup by kanban_dir (generic, table-free).
    local cfg="${AITEAMFORGE_CONFIG:-$HOME/.aiteamforge/team-paths.json}"
    if [[ -f "$cfg" ]] && command -v python3 &>/dev/null; then
        resolved="$(python3 - "$cfg" "$kanban_dir" "$team_id" << 'PYEOF' 2>/dev/null
import json, os, sys
cfg, want_dir, team_id = sys.argv[1], sys.argv[2], sys.argv[3]
def norm(p): return os.path.normpath(os.path.expanduser(p))
want = norm(want_dir)
try:
    teams = json.load(open(cfg)).get("teams", {})
except Exception:
    sys.exit(0)
# Match kanban_dir AND require the key to be the template itself or a
# template-prefixed instance, so an unrelated team sharing a dir can't win.
for key, entry in teams.items():
    kd = entry.get("kanban_dir")
    if kd and norm(kd) == want and (key == team_id or key.startswith(team_id + "-")):
        print(key); sys.exit(0)
PYEOF
)"
    fi

    # 2. Built-in fallback for the canonical first-project instances.
    if [[ -z "$resolved" ]]; then
        case "$team_id" in
            finance)  resolved="finance-personal"  ;;
            legal)    resolved="legal-coparenting" ;;
            medical)  resolved="medical-general"   ;;
            *)        resolved="$team_id"          ;;
        esac
    fi

    printf '%s' "$resolved"
}

# ── _kb_board_is_present <team-id> <kanban-dir> ───────────────────────────────
# Returns 0 if a usable board exists; 1 if it is missing or structurally invalid.
# Usable = kanban dir exists AND board JSON exists AND the file is a structurally
# valid rendered board:
#   • Parses as a JSON object
#   • "backlog" key is present and is a list (length 0 is acceptable — a freshly-
#     provisioned empty board is valid, XACA-0646)
#   • "team" is a non-empty string (proves substitution ran — not a bare template)
#   • "nextId" key is present
# A corrupt file (e.g. {} or random JSON) remains NOT usable.
_kb_board_is_present() {
    local team_id="$1"
    local kanban_dir="$2"

    # 1. Kanban directory must exist.
    if [[ ! -d "$kanban_dir" ]]; then
        return 1
    fi

    # 2. Board JSON file must exist. XACA-0576: profile-scoped teams have split
    #    ids (TEMPLATE "finance" vs INSTANCE "finance-personal"). The startup
    #    scripts pass the TEMPLATE form (XACA-0576-005), but board files on disk
    #    use the INSTANCE form. Resolve the instance generically from
    #    team-paths.json so the fast-path doesn't false-alarm "missing board" and
    #    prompt the operator on every startup. (XACA-0643: was a brittle 3-entry
    #    case map that only knew each template's FIRST project.)
    local _board_instance
    _board_instance="$(_kb_resolve_instance_id "$team_id" "$kanban_dir")"
    local board_file="${kanban_dir}/${team_id}-board.json"
    if [[ ! -f "$board_file" ]] && [[ "$_board_instance" != "$team_id" ]]; then
        board_file="${kanban_dir}/${_board_instance}-board.json"
    fi
    if [[ ! -f "$board_file" ]]; then
        return 1
    fi

    # 3. Board file must have content (file size > 10 bytes as a fast pre-check
    #    before parsing — guards against a truncated/zero-byte file).
    if [[ ! -s "$board_file" ]]; then
        return 1
    fi

    # 4. Board must be structurally valid (parsed check). XACA-0646: "usable"
    #    was previously defined as "backlog non-empty (len > 0)", which wrongly
    #    rejected freshly-provisioned empty boards (board-template.json ships
    #    backlog:[]) and caused kb_ensure_team_initialized to prompt re-init on
    #    every first launch of a new team. The correct definition is structural
    #    validity: the file is a JSON object, backlog is a list (empty is fine),
    #    team is a non-empty string, and nextId is present.
    #    Use python3 for reliable JSON parsing; fall back to grep if unavailable.
    if command -v python3 &>/dev/null; then
        # XACA-0542-019: pass board_file as argv (quoted heredoc) rather than
        # interpolating it into the Python source — robust to paths containing
        # single quotes or other Python-string-breaking characters.
        python3 - "$board_file" << 'PYEOF' 2>/dev/null
import json, sys
try:
    b = json.load(open(sys.argv[1]))
    # Structural validity (XACA-0646): must be a dict, backlog must be a list
    # (empty OK), team must be a non-empty string, nextId must be present.
    ok = (
        isinstance(b, dict)
        and isinstance(b.get('backlog'), list)
        and isinstance(b.get('team'), str) and b.get('team', '') != ''
        and 'nextId' in b
    )
    sys.exit(0 if ok else 1)
except Exception:
    sys.exit(1)
PYEOF
        return $?
    else
        # Fallback: grep for the structural markers that every rendered board
        # carries. XACA-0646: the old grep for item-id patterns failed for
        # freshly-provisioned empty boards. Check instead for:
        #   "backlog" key present, "nextId" key present, and a non-empty "team"
        #   value (a rendered non-template board always has a real team string).
        # All three must match. Best-effort only — runs only when python3 is absent.
        if grep -q '"backlog"' "$board_file" 2>/dev/null \
        && grep -q '"nextId"' "$board_file" 2>/dev/null \
        && grep -qE '"team"[[:space:]]*:[[:space:]]*"[^"]' "$board_file" 2>/dev/null; then
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
#   0  — board present and structurally valid, or provisioning succeeded
#   1  — board missing/invalid and not provisioned (caller decides what to do)
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

    # Resolve the concrete INSTANCE id (e.g. legal → legal-coparenting) so any
    # provisioning targets the right board instead of the bare TEMPLATE id —
    # passing the template id makes kb-init-team try to re-allocate the team
    # code and collide with the already-registered instance. (XACA-0643)
    local instance_id
    instance_id="$(_kb_resolve_instance_id "$team_id" "$kanban_dir")"

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
        _kbitg_yellow "           ${kbit_bin} --team-id ${instance_id} --kanban-dir ${kanban_dir}"
        return 1
    fi

    # ── Non-interactive branch ────────────────────────────────────────────────
    if _kb_is_noninteractive; then
        if [[ "${KB_INIT_TEAM_AUTO_YES:-0}" == "1" ]]; then
            # Explicit opt-in: auto-provision without prompting.
            _kbitg_yellow "[kb-guard] Non-interactive auto-provision for team '${team_id}' (KB_INIT_TEAM_AUTO_YES=1)"
            "$kbit_bin" \
                --team-id   "$instance_id" \
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
            _kbitg_yellow "[kb-guard] WARNING: kanban board missing or structurally invalid for team '${team_id}'."
            _kbitg_yellow "  Kanban dir : ${kanban_dir}"
            _kbitg_yellow "  Board file : ${kanban_dir}/${instance_id}-board.json"
            _kbitg_yellow ""
            _kbitg_yellow "  Non-interactive mode — will NOT provision automatically."
            _kbitg_yellow "  To provision: run kb-init-team --team-id ${instance_id} --kanban-dir ${kanban_dir}"
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
    _kbitg_yellow "│  The board JSON is missing or structurally invalid. Without it,"
    _kbitg_yellow "│  kanban commands (kb-show, kb-backlog, etc.) will fail."
    _kbitg_yellow "└─────────────────────────────────────────────────────────────────┘"
    printf '\n' >&2

    local response
    while true; do
        printf '[kb-guard] Initialize this team now? [y/N]: ' >&2
        read -r response </dev/tty 2>/dev/null || { response="n"; break; }
        # Case-insensitive match via bracket globs + in-loop normalization to a
        # canonical y/n. Portable across zsh and bash 3.2 — bash-4's lowercase
        # parameter expansion is a "bad substitution" in both, and this guard is
        # SOURCED by <team>-startup.sh (#!/bin/zsh), so it runs under zsh. (XACA-0615)
        case "$response" in
            [Yy]|[Yy][Ee][Ss]) response="y"; break ;;
            [Nn]|[Nn][Oo]|"")  response="n"; break ;;
            *) _kbitg_yellow "  Please enter y or n." ;;
        esac
    done

    if [[ "$response" != "y" ]]; then
        _kbitg_yellow "[kb-guard] Skipped. Kanban commands may fail until the team is initialized."
        _kbitg_yellow "           Run: ${kbit_bin} --team-id ${instance_id} --kanban-dir ${kanban_dir}"
        return 1
    fi

    # User confirmed — invoke kb-init-team interactively.
    # Pre-fill team-id and kanban-dir; let kb-init-team prompt for the rest.
    printf '\n' >&2
    _kbitg_cyan "[kb-guard] Launching kb-init-team for team '${team_id}'..."
    printf '\n' >&2

    "$kbit_bin" \
        --team-id    "$instance_id" \
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
