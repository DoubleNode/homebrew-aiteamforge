#!/usr/bin/env sh
# cc-credential-team-resolver.sh — resolves the FREELANCE instance slug used
# for AI-credential lookup (XACA-1313).
#
# THE BUG: cc / ccc / cc-whoami / the session-account recorder and
# freelance-banner.sh all resolve "which team am I" from
# SESSION_TYPE/LCARS_TEAM/KB_TEAM and use that value directly as the
# team-paths.json key for teams.<slug>.ai.credential. Every freelance
# startup script hardcodes SESSION_TYPE="freelance" (see e.g.
# freelance/scripts/freelance-engineering-startup.sh). LCARS Settings,
# however, saves a routed credential under the INSTANCE key
# freelance-<client>-<project> — teams.freelance itself is never populated
# (MEASURED on M4Mini 2026-09-22: teams.freelance-bandwear-android.ai.
# credential is set; teams.freelance is absent). Every lookup above
# therefore resolves "no credential for this team" and silently falls
# through to default OAuth, even when the operator correctly routed the
# instance's account in LCARS. Known since XACA-1184-002, which documented
# this as "deliberately unchanged" (see the note that used to sit at
# freelance/scripts/freelance-banner.sh:104-113) rather than treating it as
# the defect it is.
#
# THE FIX: _cc_credential_team() leaves every other team's identity alone,
# including an ALREADY-resolved freelance instance slug. Only for the
# literal value "freelance" does it try to recover the real instance slug,
# from the two sources a freelance shell actually has at credential-
# resolution time — the tmux session name, then the .kb-team sentinel
# (XACA-0454 layer 3). NEITHER source's raw value is the registered slug
# verbatim (see the two REAL SHAPES below); every candidate this file
# derives from them is accepted only when it is both freelance-*-shaped AND
# genuinely registered in team-paths — never guessed, never invented. If
# nothing qualifies, "freelance" passes through unchanged, which is today's
# existing (if broken) behaviour, not a new failure mode.
#
# REAL SHAPE 1 — tmux session name (#S) is ONE SEGMENT LONGER than the
# registered slug, not equal to it:
#   freelance-startup.sh:95   SESSION_PREFIX="freelance-${GROUP_LOWER}-${PROJECT_LOWER}"
#   freelance-startup.sh:127-147  session names are "${SESSION_PREFIX}-<terminal>"
#     (terminal in lcars/command/engineering/science/sickbay/tactical/comms/helm)
#   freelance/scripts/freelance-helm-startup.sh:23  (mirrored per-terminal)
#     SESSION_CODE="${SESSION_TYPE}-${GROUP_LOWER}-${PROJECT_LOWER}-${SESSION_NAME}"
# So a real #S looks like "freelance-bandwear-android-helm", while the
# registered slug is "freelance-bandwear-android" — an exact-match check
# against #S never hits. _cc_credential_team_tmux_candidates strips one
# trailing "-segment" at a time (longest candidate first) until a REGISTERED
# one is found.
#
# REAL SHAPE 2 — the .kb-team sentinel a freelance project actually gets is
# NOT the general XACA-0454 "<team>[:<terminal>]" form:
#   scripts/kb-freelance:10   content contract: "freelance:<client>:<project>"
#   scripts/kb-freelance:213-214  CLIENT/PROJECT lowercased via tr before write
#   scripts/kb-freelance:216  SLUG="freelance-${CLIENT}-${PROJECT}"
#   scripts/kb-freelance:220-226  _validate_slug_segment: each of CLIENT/
#     PROJECT must match ^[a-z0-9]+$ (alphanumeric only, no hyphens)
#   scripts/kb-freelance:822-825  _write_sentinel writes
#     "freelance:%s:%s\n" "$CLIENT" "$PROJECT"
# So a real sentinel line looks like "freelance:bandwear:android" — THREE
# colon-separated fields, the first one literally "freelance", the other two
# already-lowercased client/project segments — not "<team>:<terminal>".
# Taking everything before the first colon (the general form's own rule)
# yields the bare literal "freelance", which can never be eligible.
# _cc_credential_team_sentinel_candidates parses this shape into
# "freelance-<client>-<project>" (re-lowercasing defensively, since nothing
# enforces kb-freelance's own lowercasing on a sentinel some OTHER writer
# produced), and ALSO still emits the generic "<team>[:<terminal>]" team part
# as a fallback candidate for a sentinel written some other way (e.g. one
# that already stores the resolved instance slug).
#
# Sourced (never executed) from three independent call sites that each
# derive a team identity from SESSION_TYPE/LCARS_TEAM/KB_TEAM and then look
# up a credential for it:
#   - claude_code_cc_aliases.sh  (_cc_export_account_credentials, and ccc's
#     _ccc_team)
#   - scripts/cc-whoami.sh
#   - scripts/session-account-map-record.sh
# One implementation, three call sites — do not copy this logic inline at
# any of them.
#
# Deliberately POSIX sh, not zsh/bash-specific. All three sourcing sites
# above are zsh scripts, but this file is also reachable from non-
# interactive/CI shells (session-account-map-record.sh's callers include
# kb-run/kb-work). Known traps this sidesteps by construction:
#   - `for x in $(cmd)` / `set -- $(cmd)`: zsh, UNLIKE sh/bash, does not
#     word-split an unquoted substitution by default (no `SH_WORD_SPLIT`),
#     so either idiom silently collapses a multi-line candidate list into
#     ONE candidate under zsh. Every candidate list here is built with a
#     pure parameter-expansion split loop instead (see
#     _cc_credential_team_split_into_args), never a `for`/`set --` over a
#     raw substitution.
#   - bare zsh glob qualifiers misbehaving outside `setopt EXTENDED_GLOB`
#     contexts, `BASH_SOURCE` being empty under zsh, and `local` inside a
#     loop body behaving differently across shells.
# Plain global "_cctr_"-prefixed scratch variables, always unset immediately
# after use, sidestep all of the above.

# ---------------------------------------------------------------------------
# _cc_credential_team_hooks_dir
#
# Locate kanban-hooks/ (home of the one sanctioned credential reader,
# aiteamforge_registry.py) across the layouts this file can be installed
# into. Same dual-absolute probe convention as team-account-display.sh's
# _atf_acct_hooks_dir — kept as its own small copy rather than sourcing that
# file, since that file's job is display decoration and this resolver has
# no other reason to depend on it; both ultimately read through the same
# aiteamforge_registry entry point.
# ---------------------------------------------------------------------------
_cc_credential_team_hooks_dir() {
    for _cctr_d in \
        ${AITEAMFORGE_DIR:+"${AITEAMFORGE_DIR}/kanban-hooks"} \
        "${HOME}/dev-team/kanban-hooks" \
        "${HOME}/aiteamforge/kanban-hooks"
    do
        if [ -f "${_cctr_d}/aiteamforge_registry.py" ]; then
            printf '%s\n' "${_cctr_d}"
            unset _cctr_d
            return 0
        fi
    done
    unset _cctr_d
    return 1
}

# ---------------------------------------------------------------------------
# _cc_credential_team_shape_ok <candidate>
#
# True iff <candidate> is non-empty and slug-shaped (the SAME predicate
# callers already apply to SESSION_TYPE/LCARS_TEAM/KB_TEAM — defense in
# depth, since a tmux session name or a .kb-team file's contents are exactly
# as operator-controlled as those env vars) AND shaped like a freelance
# instance (freelance-*). Shape only — does NOT check registration; see
# _cc_credential_team_first_registered for that.
#
# Uses _cctr_sok_* (not the generic _cctr_c) DELIBERATELY: callers invoke
# this from inside their OWN loops over a variable literally named _cctr_c
# (_cc_credential_team's split loop) — these are plain globals, not `local`
# (POSIX sh has no `local`), so a same-named scratch var here would `unset`
# the CALLER's loop variable out from under it the moment this returns.
# Measured directly: reusing _cctr_c here silently zeroed every real-shape
# candidate before `set --` ever saw it.
# ---------------------------------------------------------------------------
_cc_credential_team_shape_ok() {
    _cctr_sok_c="$1"
    if [ -z "$_cctr_sok_c" ]; then
        unset _cctr_sok_c
        return 1
    fi
    case "$_cctr_sok_c" in
        [A-Za-z0-9]*) : ;;
        *) unset _cctr_sok_c; return 1 ;;
    esac
    case "$_cctr_sok_c" in
        *[!A-Za-z0-9_-]*) unset _cctr_sok_c; return 1 ;;
    esac
    case "$_cctr_sok_c" in
        freelance-*) unset _cctr_sok_c; return 0 ;;
        *) unset _cctr_sok_c; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# _cc_credential_team_tmux_candidates <session_name>
#
# See REAL SHAPE 1 in the file header. Prints, one per line, the full name
# and then each progressively shorter prefix formed by stripping one
# trailing "-segment" at a time, stopping BEFORE the bare "freelance" root
# (which can never be a freelance instance slug). Prints nothing for a
# session name that isn't freelance-*-shaped to begin with. Does not itself
# check registration — _cc_credential_team_first_registered judges the
# WHOLE combined candidate list (tmux + sentinel) in one python3 call.
# ---------------------------------------------------------------------------
_cc_credential_team_tmux_candidates() {
    _cctr_s="$1"
    case "$_cctr_s" in
        freelance-*) : ;;
        *) unset _cctr_s; return 0 ;;
    esac
    while :; do
        if _cc_credential_team_shape_ok "$_cctr_s"; then
            printf '%s\n' "$_cctr_s"
        fi
        case "$_cctr_s" in
            *-*) _cctr_s="${_cctr_s%-*}" ;;
            *) break ;;
        esac
        [ "$_cctr_s" = "freelance" ] && break
    done
    unset _cctr_s
}

# ---------------------------------------------------------------------------
# _cc_credential_team_sentinel_candidates
#
# See REAL SHAPE 2 in the file header. Walks up from $PWD (XACA-0454 layer
# 3) to the nearest .kb-team, reads its first line, and prints candidates in
# priority order:
#   1. If the line is exactly "freelance:<seg>:<seg>" (3 fields, the first
#      literally "freelance"): "freelance-<seg>-<seg>", lowercased.
#   2. The generic XACA-0454 form's own team part (everything before the
#      first colon) — a fallback for a sentinel written some other way.
# Prints nothing when no sentinel is found. Neither candidate is checked for
# registration here — see _cc_credential_team_first_registered.
# ---------------------------------------------------------------------------
_cc_credential_team_sentinel_candidates() {
    _cctr_dir="$PWD"
    _cctr_line=""
    while [ -n "$_cctr_dir" ]; do
        if [ -f "${_cctr_dir}/.kb-team" ]; then
            _cctr_line=$(head -n 1 "${_cctr_dir}/.kb-team" 2>/dev/null | tr -d '\r')
            break
        fi
        [ "$_cctr_dir" = "/" ] && break
        _cctr_dir=$(dirname "$_cctr_dir")
    done
    unset _cctr_dir

    # Normalize: CR already stripped above (a CRLF-saved sentinel); trim
    # trailing whitespace the same way (XACA-1313 test-gate advisory).
    _cctr_line="${_cctr_line%"${_cctr_line##*[![:space:]]}"}"

    if [ -z "$_cctr_line" ]; then
        unset _cctr_line
        return 0
    fi

    case "$_cctr_line" in
        freelance:*:*)
            # "freelance:<client>:<project>" (kb-freelance:822-825). A 4th+
            # field (e.g. ":<terminal>") is ignored, not fatal -- the result
            # still has to pass the registration gate like every candidate.
            _cctr_rest="${_cctr_line#freelance:}"
            _cctr_client="${_cctr_rest%%:*}"
            _cctr_project="${_cctr_rest#*:}"
            _cctr_project="${_cctr_project%%:*}"
            _cctr_client=$(printf '%s' "$_cctr_client" | tr '[:upper:]' '[:lower:]')
            _cctr_project=$(printf '%s' "$_cctr_project" | tr '[:upper:]' '[:lower:]')
            printf 'freelance-%s-%s\n' "$_cctr_client" "$_cctr_project"
            unset _cctr_rest _cctr_client _cctr_project
            ;;
    esac

    # Generic XACA-0454 fallback: the team part before the first colon.
    printf '%s\n' "${_cctr_line%%:*}"
    unset _cctr_line
}

# ---------------------------------------------------------------------------
# _cc_credential_team_first_registered <hooks_dir> <candidate>...
#
# Prints the FIRST candidate that is actually registered per
# aiteamforge_registry.is_registered — one python3 call for the WHOLE list,
# never one call per candidate. Callers pass only already shape-filtered
# candidates (see _cc_credential_team's split loop). Candidates are passed
# via argv, never interpolated into program text (XACA-0539-011 convention).
# Prints nothing when none qualify or on any local failure (missing
# python3/hooks dir/module) — this is a resolution helper, never a hard
# failure point.
# ---------------------------------------------------------------------------
_cc_credential_team_first_registered() {
    _cctr_h="$1"
    shift
    if [ -z "$_cctr_h" ] || [ "$#" -eq 0 ]; then
        unset _cctr_h
        return 0
    fi
    command -v python3 >/dev/null 2>&1 || { unset _cctr_h; return 0; }

    python3 - "$_cctr_h" "$@" <<'CCTR_PY' 2>/dev/null
import sys
hooks_dir = sys.argv[1]
candidates = sys.argv[2:]
sys.path.insert(0, hooks_dir)
try:
    import aiteamforge_registry as reg
except Exception:
    sys.exit(0)
for c in candidates:
    try:
        if reg.is_registered(c):
            print(c)
            sys.exit(0)
    except Exception:
        continue
sys.exit(0)
CCTR_PY
    unset _cctr_h
}

# ---------------------------------------------------------------------------
# _cc_credential_team <team>
#
# Prints the team slug credential lookups should actually use for <team> —
# the value the caller already computed from
# SESSION_TYPE/LCARS_TEAM/KB_TEAM. See the file header for the full
# contract. Always prints exactly one line and always returns 0: this is a
# resolution helper, not a validator — callers keep applying their own
# existing slug-safety gate to whatever this prints, unchanged.
# ---------------------------------------------------------------------------
_cc_credential_team() {
    _cctr_in="${1:-}"

    if [ "$_cctr_in" != "freelance" ]; then
        printf '%s\n' "$_cctr_in"
        unset _cctr_in
        return 0
    fi

    # || fallback: under zsh ERR_EXIT a failing $(...) assignment would abort
    # the whole resolver and break its "always prints one line" contract
    # (XACA-1313-018).
    _cctr_hooks=$(_cc_credential_team_hooks_dir) || _cctr_hooks=""
    if [ -z "$_cctr_hooks" ]; then
        printf 'freelance\n'
        unset _cctr_in _cctr_hooks
        return 0
    fi

    # Gather every candidate from both sources into ONE newline-separated
    # string, tmux first (more specific — it names the exact terminal),
    # then the sentinel's parsed-then-fallback forms, before the single
    # python3 registration check below judges the combined list in order.
    _cctr_tmux_s=""
    if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
        # Target this pane when known (house idiom, kanban-helpers.sh
        # _kb_detect_context): untargeted, tmux answers for its default
        # session, which may be a DIFFERENT freelance instance (XACA-1313-020).
        if [ -n "${TMUX_PANE:-}" ]; then
            _cctr_tmux_s=$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null)
        else
            _cctr_tmux_s=$(tmux display-message -p '#S' 2>/dev/null)
        fi
    fi
    _cctr_all="$(_cc_credential_team_tmux_candidates "$_cctr_tmux_s")
$(_cc_credential_team_sentinel_candidates)"
    unset _cctr_tmux_s

    # Split _cctr_all on newlines via pure parameter expansion — never
    # `for x in $(...)`/`set -- $(...)` (see the file header's zsh
    # word-splitting note). Shape-filter as we go; only a candidate that
    # passes _cc_credential_team_shape_ok ever reaches `set --`.
    set --
    _cctr_nl='
'
    _cctr_remaining="$_cctr_all"
    while [ -n "$_cctr_remaining" ]; do
        case "$_cctr_remaining" in
            *"$_cctr_nl"*)
                _cctr_c="${_cctr_remaining%%"$_cctr_nl"*}"
                _cctr_remaining="${_cctr_remaining#*"$_cctr_nl"}"
                ;;
            *)
                _cctr_c="$_cctr_remaining"
                _cctr_remaining=""
                ;;
        esac
        if [ -n "$_cctr_c" ] && _cc_credential_team_shape_ok "$_cctr_c"; then
            set -- "$@" "$_cctr_c"
        fi
    done
    unset _cctr_all _cctr_nl _cctr_remaining _cctr_c

    if [ "$#" -gt 0 ]; then
        _cctr_hit=$(_cc_credential_team_first_registered "$_cctr_hooks" "$@")
        if [ -n "$_cctr_hit" ]; then
            printf '%s\n' "$_cctr_hit"
            unset _cctr_in _cctr_hooks _cctr_hit
            return 0
        fi
        unset _cctr_hit
    fi

    # Nothing qualified — today's behaviour: pass "freelance" through
    # unchanged rather than guessing.
    printf 'freelance\n'
    unset _cctr_in _cctr_hooks
}
