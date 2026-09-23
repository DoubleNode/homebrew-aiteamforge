#!/bin/bash
# session-account-map-headless.sh — pin a session id for a HEADLESS Claude
# launch and record the account that launch will actually run on
# (XACA-1300-014).
#
# WHY THIS EXISTS
#   Interactive persona launches (_cc_launch / ccc) resolve a team credential,
#   pin --session-id, and write a row to ~/.claude/.session-account-map.jsonl.
#   Headless launches did not: the kb-run-* gate sessions (`printf … | cc`
#   with no persona context, i.e. cc()'s plain-claude fallback) and one-shot
#   `claude -p` calls wrote NO row, so XACA-1300-001 measured the `gate` and
#   `scheduled` token classes as 100% unattributed. This helper is the one
#   shared piece every headless launcher calls, so the "which account is this
#   launch billed to" rule exists exactly once.
#
# USAGE
#   sid=$(session-account-map-headless.sh [--claude-bin <path>] </dev/null)
#   claude ${sid:+--session-id "$sid"} …      # (use an array in real code)
#
#   stdout: the pinned session id (lowercase UUID), or NOTHING when the
#           installed claude does not advertise --session-id or no UUID
#           source exists. Callers pass --session-id only when non-empty.
#   stderr: every warning, including anything the recorder printed. Nothing
#           here is ever discarded (see XACA-1197: silent recorder failure
#           is the bug class this must not add to).
#   exit:   ALWAYS 0. A failed record must never abort the headless job.
#           Failure is signalled on stderr instead.
#
#   Redirect stdin from /dev/null at the call site when the caller's own
#   stdin carries the prompt (every `printf … | cc` gate launch): this
#   script runs `claude --help`, and nothing it runs may consume the prompt.
#
# WHICH ACCOUNT (the rule — keep it in sync with nothing else; it lives here)
#   A headless launch does NOT resolve a team credential itself; it inherits
#   whatever credential its environment carries. So:
#     1. No credential variable in the environment
#          (ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN,
#           and no Bedrock/Vertex switch)
#        → claude uses the machine's default OAuth login. Recorded as
#          account_id "" WITH account_resolved=true (the map's "resolved to
#          default OAuth" state).
#     2. A credential variable IS present and CLAUDE_BILLED_ACCOUNT_ID is
#        non-empty → the credential was injected by _cc_launch/ccc into an
#        ancestor claude process together with that gated billed id (they
#        are set in the same launch; the token itself only ever lives in the
#        claude child env). Recorded as that account, account_resolved=true.
#        This is the M3Pro case: a gate launched from inside an academy
#        session bills claude-max-me2, not the machine default claude-max-me.
#     3. A credential variable is present but no billed id accompanies it
#        (hand-exported key, Bedrock/Vertex, a parent that never ran gated
#        resolution) → we do NOT know the account. Recorded WITHOUT
#        --account-id, so account_resolved=false and the token report keeps
#        it in unattributed:map_unresolved rather than guessing.
#   CLAUDE_ACTIVE_ACCOUNT_ID is deliberately never used: it is UNGATED
#   metadata (exported before any token resolves — XACA-0977-013/015).
#   Known blind spot: an `apiKeyHelper` in Claude settings is not inspected;
#   such a launch is recorded under rule 1 by its (empty) environment alone.
#   XACA-1300-025: a settings.json / managed-settings `env` block is the
#   same blind spot by a different mechanism. Claude Code applies that
#   block to its OWN process, not to this calling shell, so a credential
#   injected purely via `env` in settings.json/managed-settings is
#   INVISIBLE to the presence tests below — and settings.json's `env` wins
#   over a shell export of the same name (measured XACA-1282), so even
#   when the calling shell DOES export a credential var, the value that
#   var carries is not necessarily the one claude will actually use. The
#   dangerous case is the shell exporting NOTHING: rule 1 then records
#   account_resolved=true/default-OAuth with full confidence, when the
#   launch may actually be running on a settings-injected, non-default
#   credential — the same "confidently wrong" shape as the apiKeyHelper
#   gap, not the safer "unresolved" shape of rule 3.
#
# Presence tests below use [ -n "${VAR:-}" ] only; no value is ever printed.
# Must stay bash 3.2 compatible (/bin/bash on macOS): no associative arrays,
# no ${var,,}, no empty-array expansion under set -u.

_hl_warn() {
    printf 'session-account-map-headless: %s\n' "$*" >&2
}

CLAUDE_BIN="claude"
while [ $# -gt 0 ]; do
    case "$1" in
        --claude-bin)
            shift
            [ $# -gt 0 ] && CLAUDE_BIN="$1" && shift
            ;;
        *)
            _hl_warn "ignoring unknown argument: $1"
            shift
            ;;
    esac
done

# --- 1. Feature-detect --session-id (same probe as _cc_launch, XACA-0541) ---
# stdin is /dev/null so the probe can never read a piped prompt; stderr is
# folded into the pipe rather than discarded.
if ! "$CLAUDE_BIN" --help </dev/null 2>&1 | grep -q -- "--session-id"; then
    # Not an error: older claude, or no claude at all. Without a pinned id
    # there is nothing to key a row on, so the launch goes ahead unrecorded.
    exit 0
fi

SID=""
if command -v uuidgen >/dev/null 2>&1; then
    SID=$(uuidgen | tr 'A-Z' 'a-z')
elif command -v python3 >/dev/null 2>&1; then
    SID=$(python3 -c 'import uuid; print(uuid.uuid4())')
fi
if [ -z "$SID" ]; then
    _hl_warn "no UUID source (uuidgen/python3) — headless launch NOT recorded"
    exit 0
fi

# --- 2. Which account will this launch run on? (rule above) ---------------
_hl_cred_present=0
[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] && _hl_cred_present=1
[ -n "${ANTHROPIC_API_KEY:-}" ] && _hl_cred_present=1
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && _hl_cred_present=1
[ -n "${CLAUDE_CODE_USE_BEDROCK:-}" ] && _hl_cred_present=1
[ -n "${CLAUDE_CODE_USE_VERTEX:-}" ] && _hl_cred_present=1

_hl_mode=""          # resolved | unresolved
_hl_acct_id=""
_hl_acct_nick=""
if [ "$_hl_cred_present" -eq 0 ]; then
    _hl_mode="resolved"                       # rule 1: default OAuth
elif [ -n "${CLAUDE_BILLED_ACCOUNT_ID:-}" ]; then
    _hl_mode="resolved"                       # rule 2: inherited gated pair
    _hl_acct_id="$CLAUDE_BILLED_ACCOUNT_ID"
    _hl_acct_nick="${CLAUDE_BILLED_ACCOUNT_NICKNAME:-}"
else
    _hl_mode="unresolved"                     # rule 3: unknown credential
fi

# --- 3. Record (fire-and-forget, but never silent) ------------------------
_hl_dir=$(cd "$(dirname "$0")" && pwd)
_hl_rec="$_hl_dir/session-account-map-record.sh"

if [ ! -x "$_hl_rec" ]; then
    _hl_warn "recorder not executable at $_hl_rec — session $SID NOT recorded"
else
    # The shim prints nothing on success (measured, XACA-0977-031) and its
    # own `|| true` hides python's exit status, so anything it writes to
    # stderr is surfaced here with context instead of being dropped.
    if [ "$_hl_mode" = "resolved" ]; then
        _hl_out=$("$_hl_rec" "$SID" \
            --account-id "$_hl_acct_id" \
            --account-nickname "$_hl_acct_nick" 2>&1)
    else
        # No --account-id → account_resolved=false. Scrub the ungated
        # metadata pair too: without --account-id the shim falls back to
        # reading CLAUDE_ACTIVE_ACCOUNT_ID itself, which would stamp an
        # un-vouched-for account onto a row we are explicitly saying we
        # could not attribute (caught by test H3).
        _hl_out=$(env -u CLAUDE_ACTIVE_ACCOUNT_ID -u CLAUDE_ACTIVE_ACCOUNT_NICKNAME \
            "$_hl_rec" "$SID" 2>&1)
    fi
    _hl_rc=$?
    if [ "$_hl_rc" -ne 0 ] || [ -n "$_hl_out" ]; then
        _hl_warn "recorder rc=$_hl_rc for session $SID: ${_hl_out:-(no output)}"
    fi
fi

printf '%s\n' "$SID"
exit 0
