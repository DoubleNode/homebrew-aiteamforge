#!/usr/bin/env zsh
# session-account-map-record.sh — Thin shim for session-account-map.py record.
#
# Reads Anthropic account + team identity from environment variables and
# calls session-account-map.py record.  Used by cc / ccc / kb-run / kb-work
# entry points (wired in XACA-0279-006).
#
# Usage:
#   session-account-map-record.sh [SESSION_ID] [--account-id <id>] [--account-nickname <nick>]
#
# If SESSION_ID is not supplied as $1, falls back to $CLAUDE_SESSION_ID.
# Exits silently (exit 0) if no session ID is available — not all callers
# will have one at invocation time.
#
# --account-id / --account-nickname (XACA-0977 BLOCKING B, regression round):
# optional explicit overrides. When a caller passes them, they win over the
# CLAUDE_ACTIVE_ACCOUNT_ID/_NICKNAME environment variables below. This
# exists because those globals are metadata -- exported by
# _cc_export_account_credentials as soon as a team's config is read, BEFORE
# it is known whether any credential tier (engine guard / vault / cache /
# env-var) will actually produce a usable token (XACA-0977-013/015). A team
# can have real account metadata exported while no token ever reaches
# claude (engine mismatch, vault down + no fallback resolved, etc). ccc()
# already computes the GATED value locally (empty whenever no token
# resolved) for its own cross-account guard and "billed to" messages; before
# this fix this shim re-read the raw, UNGATED globals independently, so the
# guard's comparand and the map record it writes could disagree forever for
# any team with metadata but no resolving token -- verified directly.
# Callers that know the gated value (ccc, _cc_launch) MUST pass it
# explicitly via these flags so there is exactly ONE computation of "the
# account this session is actually billed to", never two that can drift.
#
# XACA-0977-025 (round 4): kb-run / kb-work are NOT exempt from this -- an
# earlier revision of this comment claimed they were "unaffected" and kept
# "the plain environment-variable behavior", which was wrong the moment it
# was written: those entry points call `cc` (which runs the exact same
# gated resolution as ccc/_cc_launch) and then make their OWN unconditional
# record call as a belt-and-suspenders step for the case where `cc` fell
# through to plain claude without ever reaching _cc_launch. Because lookup
# is most-recent-wins, an ungated write from that second call could
# silently overwrite a correct gated record _cc_launch had just written
# moments earlier. kb-run/kb-work now pass CLAUDE_BILLED_ACCOUNT_ID/
# _NICKNAME (the exported gated pair -- see claude_code_cc_aliases.sh)
# explicitly, the same as ccc/_cc_launch, whenever that pair was actually
# exported in the calling shell; only when it was never exported at all
# (no cc/ccc call has run yet) do they fall through to this shim's plain
# environment-variable behavior, unchanged.
#
# XACA-0977-028 (round 6): a value beginning with "-" (e.g. an account id
# that legitimately starts with a dash) makes zsh's own arg handling here
# fine, but if a caller ever pipes a raw value straight into a getopts-style
# parser elsewhere it can be misread as a flag. This script's own case-based
# loop below does not have that problem (it always shifts the flag token
# before reading its value). The `|| true` on the python3 call still swallows
# the EXIT STATUS of a python3-side argparse rejection (deliberately -- see the
# note above that call), but its stderr is no longer discarded by this script
# (XACA-0977-031). Note that every in-repo CALL SITE still redirects stderr
# itself, so the rejection remains invisible to them until those are changed.
SESSION_ID="${1:-${CLAUDE_SESSION_ID:-}}"
(( $# > 0 )) && shift

ACCOUNT_ID="${CLAUDE_ACTIVE_ACCOUNT_ID:-}"
ACCOUNT_NICKNAME="${CLAUDE_ACTIVE_ACCOUNT_NICKNAME:-}"

# XACA-0977 round 6 (finding E): explicitly initialise the "did the caller
# express an opinion at all" flag BEFORE the arg loop. An earlier revision
# left this to zsh's implicit unset-var-is-falsy behavior, which means an
# INHERITED environment variable of the same name silently took over:
# `env ACCOUNT_ID_EXPLICIT=1 ./session-account-map-record.sh sess-C` (with
# --account-id omitted) wrote this record as "resolved, no account" for a
# caller that had no opinion at all. Always start from a known value.
ACCOUNT_ID_EXPLICIT=0

# XACA-0977-022/026 (round 4): a TRAILING --account-id/--account-nickname
# with no value following it used to hang this script FOREVER. "shift 2"
# with only 1 arg left ($#=1) is a hard zsh error ("shift count must be <=
# $#") that does NOT shift at all -- $1 stays "--account-id", the case
# re-matches next iteration, and the loop spins, printing that error to
# stderr on every pass (measured: exit=124 under a timeout, >64MB of
# stderr in seconds). Shift ONE token at a time instead: consume the flag,
# then consume the value ONLY if one is actually left. A trailing flag with
# no value is treated as an empty override (consistent with this script's
# existing permissive style toward unrecognized input) rather than an
# error -- there is no in-repo caller that hits this today, but this is
# public CLI surface and must not be able to hang a caller's shell.
while (( $# > 0 )); do
  case "$1" in
    --account-id)
      shift
      ACCOUNT_ID="${1:-}"
      ACCOUNT_ID_EXPLICIT=1
      (( $# > 0 )) && shift
      ;;
    --account-nickname)
      shift
      ACCOUNT_NICKNAME="${1:-}"
      (( $# > 0 )) && shift
      ;;
    *)
      shift
      ;;
  esac
done

[[ -z "$SESSION_ID" ]] && exit 0  # no session id = nothing to record

# XACA-0977 round 6 (BLOCKING B): the "resolved, but no account" state moves
# OUT-OF-BAND into session-account-map.py's own `account_resolved` field,
# never back into an in-band magic string inside account_id. Rounds 4-5's
# $_CC_MAP_NO_ACCOUNT_MARKER approach put a sentinel INSIDE account_id, which
# meant every OTHER reader of account_id (the LCARS ccusage collector's
# most_recent_account_for_cwd, the running-sessions/resume-ids endpoints in
# lcars-ui/server.py, cc-whoami's display line) had to be re-audited for
# whether it treated the marker as falsy -- and the collector did not: a
# marker is a non-empty string, so `if account_id:` in
# most_recent_account_for_cwd rendered a phantom account row and zeroed out
# untagged tokens (measured: 23/1776 entries affected). Also removes the
# CROSS-FILE dependency that caused rounds 4/5's own regression:
# _CC_MAP_NO_ACCOUNT_MARKER was a plain (un-exported) assignment in
# claude_code_cc_aliases.sh, while CLAUDE_BILLED_ACCOUNT_ID IS exported, so a
# child shell that sources only kanban-helpers.sh (the documented subagent
# pattern) inherited the account pair but not the marker.
#
# account_id therefore stays "" for BOTH "no opinion" and "resolved, no
# account" -- every falsiness-based reader keeps working with NO changes.
# What ACCOUNT_ID_EXPLICIT tracked above (did the caller pass --account-id
# at all, even with an empty value?) is exactly "did gated resolution run",
# so it maps directly onto --account-resolved: a caller with no opinion
# omits --account-id entirely (ACCOUNT_ID_EXPLICIT stays 0, the flag below
# is omitted, and session-account-map.py's own default -- False -- applies);
# a caller that resolved (to a real account OR to nothing) passes
# --account-id explicitly (ACCOUNT_ID_EXPLICIT=1) and we pass
# --account-resolved alongside it. No magic string survives anywhere.
_cc_map_resolved_flag=()
if (( ACCOUNT_ID_EXPLICIT )); then
  _cc_map_resolved_flag=(--account-resolved)
fi

# XACA-0977-031: `2>/dev/null` was REMOVED here; only `|| true` remains. The
# two were doing separable jobs and only one of them was wanted. `|| true`
# preserves the fire-and-forget contract this shim documents -- a failed
# record must never fail the caller's own command. `2>/dev/null` bought
# nothing but blindness: it is what hid BLOCKING A for two full review
# rounds, where both kanban-helpers.sh call sites passed a flag as the
# positional session id, argparse rejected it, and NOTHING was recorded --
# silently, at rc=0. The no-session-id case exits before python runs, so
# dropping the redirect adds no routine noise (MEASURED: 0 bytes of stderr on
# all five ordinary paths).
#
# HONEST SCOPE, do not over-read this change: it is a NO-OP for every in-repo
# caller as shipped. All six call sites still carry their OWN `2>/dev/null` --
# claude_code_cc_aliases.sh:1312,1395,1899,1935 and kanban-helpers.sh:12098,
# 12099,12441,12442 -- INCLUDING the two kanban-helpers.sh sites this comment
# cites above as the ones that hid BLOCKING A. That failure would still be
# silent at rc=0 today. What this change buys is that the shim no longer
# ADDS blindness of its own, so a caller that drops its redirect immediately
# gets the visibility; it does not itself restore visibility anywhere.
# Removing the four call-site redirects is a behaviour change across `cc` and
# `ccc` launch paths and belongs in its own ticket, not here.
#
# (An earlier revision of these lines claimed "the only stderr a caller can now
# see is a real failure they would want to see." That was false as shipped, for
# the reason above, and is exactly the comment-contradicts-code shape this
# ticket kept tripping over.)
#
# The `|| true` below is deliberate and pre-existing (not
# introduced by this fix): this shim's own doc comment says it "exits
# silently... not all callers will have one [a session id] at invocation
# time", and every call site treats this as fire-and-forget housekeeping
# that must never fail the caller's own command. A malformed --account-id
# (e.g. one that argparse rejects) is therefore a silently-dropped record,
# not a caller-visible error -- kept for consistency with that existing
# contract, not because the failure mode is desirable. See BLOCKING A's
# note on the two kanban-helpers.sh call sites for the concrete case this
# swallowed.

# XACA-1313: resolve a bare "freelance" identity to its registered instance
# slug (freelance-<client>-<project>) before it is recorded as the
# attribution "team" below — otherwise every freelance record is written
# against the un-routable literal "freelance", disagreeing with what
# `cc`/`ccc` actually billed. Lazily sourced: this shim is called from
# non-interactive contexts (kb-run/kb-work) that may not have sourced
# claude_code_cc_aliases.sh in this shell.
_SACM_TEAM="${SESSION_TYPE:-${LCARS_TEAM:-${KB_TEAM:-}}}"
if ! command -v _cc_credential_team >/dev/null 2>&1; then
  _sacm_own_dir="$(dirname "$0")"
  for _sacm_r in "${_sacm_own_dir}/cc-credential-team-resolver.sh" \
                 ${AITEAMFORGE_DIR:+"${AITEAMFORGE_DIR}/scripts/cc-credential-team-resolver.sh"} \
                 "${HOME}/dev-team/scripts/cc-credential-team-resolver.sh" \
                 "${HOME}/aiteamforge/scripts/cc-credential-team-resolver.sh"; do
    if [[ -n "$_sacm_r" && -f "$_sacm_r" ]]; then
      source "$_sacm_r"
      break
    fi
  done
  unset _sacm_r _sacm_own_dir
fi
if [[ -n "$_SACM_TEAM" ]] && command -v _cc_credential_team >/dev/null 2>&1; then
  _SACM_TEAM="$(_cc_credential_team "$_SACM_TEAM")"
fi

python3 "$(dirname "$0")/session-account-map.py" record \
  --session-id "$SESSION_ID" \
  --account-id "$ACCOUNT_ID" \
  --account-nickname "$ACCOUNT_NICKNAME" \
  --team "$_SACM_TEAM" \
  --terminal "${TMUX_PANE:-${KB_TERMINAL:-}}" \
  --cwd "$PWD" \
  --pid "$$" \
  "${_cc_map_resolved_flag[@]}" || true
