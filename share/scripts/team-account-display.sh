#!/usr/bin/env sh
# team-account-display.sh — shared resolver for a team's routed AI credential.
#
# XACA-1184-002. Single source of the "which Anthropic account is this team
# using?" lookup that the terminal banners, the agent-panel avatar payload and
# cc-whoami all need. Before this file there were eleven hand-rolled copies of
# the same inline `python3 -c` heredoc — nine of them byte-identical modulo the
# team slug — each opening ~/.aiteamforge/team-paths.json directly and reading
# the retired anthropic_* trio. That is the k501 sibling-heuristic-drift shape:
# one heuristic, eleven places to forget.
#
# The credential now lives at teams.<slug>.ai.credential and the ONLY sanctioned
# reader is kanban-hooks/aiteamforge_registry.ai_credential(). This file shells
# to it rather than re-implementing the parse, so the three-state contract
# (undeclared / declared-none / routed) is honoured in exactly one place.
#
# NO LEGACY FALLBACK, DELIBERATELY. Promoting the retired trio into
# ai.credential is a one-time on-disk migration (XACA-1184-004). Reading the
# trio here as well would make that migration unobservable — every team would
# answer correctly whether or not it ever ran — and the retirement would
# silently never complete. See ai_credential()'s docstring.
#
# Usage (source, then call):
#   . "$HOME/dev-team/scripts/team-account-display.sh"
#   atf_team_account_fields academy      # -> set|claude-max-me2|Darren Max (me2)|CLAUDE_ACCT_ME2_TOKEN
#   atf_team_account_nickname academy    # -> Darren Max (me2)
#
# Failure contract: SILENT, and never a traceback. Account display is UI
# decoration; it must never break a banner, a shell or a diagnostic. Every
# failure path resolves to the "unavailable" state with empty value fields,
# which every caller renders exactly as it renders "no credential".
#
# Designed to work in both sh and zsh (banners are zsh, cc-whoami is zsh).

# ---------------------------------------------------------------------------
# Locate kanban-hooks/ across the layouts this file can be installed into.
#
# Deliberately probes explicit roots rather than self-locating: the portable
# "directory of the file currently being sourced" idiom differs between zsh
# (${(%):-%x}) and bash (BASH_SOURCE) and does not exist in POSIX sh, and the
# zsh form is a PARSE error under sh even inside an untaken branch. The same
# dual-absolute probe is the established convention here — see the
# onscreen-heal.sh block in every *-banner.sh.
# ---------------------------------------------------------------------------
_atf_acct_hooks_dir() {
    _d=""
    for _d in \
        ${AITEAMFORGE_DIR:+"${AITEAMFORGE_DIR}/kanban-hooks"} \
        "${HOME}/dev-team/kanban-hooks" \
        "${HOME}/aiteamforge/kanban-hooks"
    do
        if [ -f "${_d}/aiteamforge_registry.py" ]; then
            printf '%s\n' "${_d}"
            unset _d
            return 0
        fi
    done
    unset _d
    return 1
}

# ---------------------------------------------------------------------------
# atf_team_account_fields <team>
#
# Prints exactly one line: "<state>|<account_id>|<nickname>|<env_var_name>"
#
#   set          — an account is routed; the three value fields are populated.
#   none         — ai.credential is explicitly null. A RECORDED decision that
#                  this team uses no team credential, not an absence.
#   absent       — undeclared. Nothing has been decided for this team.
#   unknown-team — the slug is registered in no tier (ai_credential raises).
#   unavailable  — python3 missing, kanban-hooks not found, or the module
#                  blew up. We do not know, and we do not pretend to.
#
# The state field exists so the accessor's three-state contract survives the
# shell boundary instead of being flattened into "empty string". Today every
# caller renders set -> the nickname and everything else -> "(default OAuth)",
# but a caller that needs to distinguish "nobody decided" from "decided: none"
# can, without another team-paths parser being invented.
#
# Values are pipe-joined because that is this codebase's existing convention
# for these two call sites; a nickname containing "|" would split wrongly, an
# exposure the hand-rolled readers this replaces already had.
# ---------------------------------------------------------------------------
atf_team_account_fields() {
    _atf_team="${1:-}"
    if [ -z "${_atf_team}" ]; then
        printf 'unavailable|||\n'
        unset _atf_team
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        printf 'unavailable|||\n'
        unset _atf_team
        return 0
    fi

    _atf_hooks=$(_atf_acct_hooks_dir) || {
        printf 'unavailable|||\n'
        unset _atf_team
        return 0
    }

    # Slug and hooks dir are passed as ARGV, never interpolated into the
    # program text: the readers this replaces spliced the slug straight into
    # a python string literal, which a quote in a team name would have broken.
    _atf_out=$(python3 - "${_atf_team}" "${_atf_hooks}" <<'ATF_PY' 2>/dev/null
import sys

team, hooks_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, hooks_dir)

def emit(state, account_id="", nickname="", env_var_name=""):
    # Strip the delimiter and any newline out of values rather than emitting a
    # line the shell would mis-split.
    clean = [str(v).replace("|", " ").replace("\n", " ").replace("\r", " ")
             for v in (account_id, nickname, env_var_name)]
    print("%s|%s" % (state, "|".join(clean)))

try:
    import aiteamforge_registry as reg
except Exception:
    emit("unavailable")
    sys.exit(0)

try:
    cred = reg.ai_credential(team)
except reg.UnknownTeamError:
    emit("unknown-team")
    sys.exit(0)
except Exception:
    emit("unavailable")
    sys.exit(0)

# Order matters: is_absent() is an identity check and MUST precede any
# truthiness test — bool(ABSENT) raises on purpose (knowledge S002).
if reg.is_absent(cred):
    emit("absent")
elif cred is None:
    emit("none")
elif isinstance(cred, dict):
    emit("set",
         cred.get("account_id") or "",
         cred.get("nickname") or "",
         cred.get("env_var_name") or "")
else:
    emit("unavailable")
ATF_PY
    )

    case "${_atf_out}" in
        set\|*|none\|*|absent\|*|unknown-team\|*|unavailable\|*)
            printf '%s\n' "${_atf_out}" ;;
        *)
            # Empty or unrecognised — a python3 that died before emitting.
            printf 'unavailable|||\n' ;;
    esac
    unset _atf_team _atf_hooks _atf_out
}

# ---------------------------------------------------------------------------
# atf_team_account_nickname <team>
#
# Prints the human label for the routed account, or NOTHING when no account is
# routed (any of none / absent / unknown-team / unavailable). Callers test for
# empty and render their own "(default OAuth)" affordance, which is exactly the
# behaviour the nine banner copies had.
# ---------------------------------------------------------------------------
atf_team_account_nickname() {
    _atf_line=$(atf_team_account_fields "${1:-}")
    case "${_atf_line}" in
        set\|*)
            _atf_rest="${_atf_line#*|}"      # account_id|nickname|env
            _atf_rest="${_atf_rest#*|}"      # nickname|env
            printf '%s\n' "${_atf_rest%%|*}"
            unset _atf_rest ;;
    esac
    unset _atf_line
}
