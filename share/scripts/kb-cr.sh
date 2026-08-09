#!/usr/bin/env zsh
# kb-cr.sh — CR (Change Request) lifecycle helpers for AITeamForge kanban.
#
# Sourced by kanban-helpers.sh. Provides the kb-cr dispatcher.
#
# ══════════════════════════════════════════════════════════════════════════════
# UNIFIED v2.0 LIFECYCLE (XACA-0327)
# ══════════════════════════════════════════════════════════════════════════════
#
# v2.0 routing (established by XACA-0309; unified lifecycle by XACA-0327):
#
#  • v2 CONTAINERS: CRs stored in .crs[] array. Each container record has:
#    - id (e.g., CR-TEAM-YYYYMMDD-NNNN)
#    - crState, timestamps, itemIds[], metadata (title, type, platform, etc.)
#    - All lifecycle verbs (submit, approve, reject, etc.) operate atomically
#      on ALL siblings in itemIds[].
#
#  • v1 BACK-POINTERS: Backlog items with crAssignment contain:
#    - crAssignment.crId  — the container this item belongs to
#    - crAssignment.crTitle, assignedAt — audit trail
#    - Legacy flat fields (cr_id, cr_type, cr_created_at, crState) — DEPRECATED,
#      kept for backward compat with LCARS v1 UI readers (see XACA-0327 retro)
#
#  • DISPATCHER ROUTING (lines 768–837, 865–927, 940–952):
#    - Lifecycle verbs (submit, approve, reject, hold, start-dev, deploy-dev,
#      deploy-prod, start-test): dispatcher checks argument prefix.
#    - CR-ID prefix (e.g., "CR-XACA-…") → container variant (v2 → all siblings)
#    - Item-ID prefix (e.g., "XACA-…") → dispatch via _kb_cr_dispatch_item_lifecycle:
#      1. Read item's crAssignment.crId (if present)
#      2. Route to container variant with that CR-ID (propagates to all siblings)
#      3. If no crAssignment, fall through to v1 per-item helper (true legacy)
#    - Diagnostic line to stderr: "kb-cr: routing to <CR-ID> — <gerund> N items"
#
#  • LIFECYCLE PROPAGATION: When the user runs "kb-cr approve XIOS-0564" and
#    XIOS-0564 has crAssignment.crId=CR-IOS-20260505-0618, the call transparently
#    becomes "kb-cr approve CR-IOS-20260505-0618", advancing ALL 14 siblings.
#    Items without crAssignment still use v1 per-item path (true single-item CRs).
#
#  • NON-PROPAGATING VERBS:
#    - complete: has no container variant; routes to v1 only. Known limitation
#      (see XACA-0327 plan). Propagation for completion left for future work.
#    - emergency (v1), emergency-deploy (container): separate verbs.
#    - backfill (v1 utility): no container equivalent.
#
# ── PHASE 3 — CR DOC AS SOURCE OF TRUTH (XACA-0308) ─────────────────────────
#
#  • LOCAL MARKDOWN IS CANONICAL: Each CR has a file at
#      <team-kanban>/cr-docs/<ITEM-ID>-CR.md
#    This file is the authoritative CR document. The Confluence page is
#    published FROM it — not the other way around.
#
#  • cr_confluence_url: NEW field on crs[] records (set by kb-cr publish, 002).
#    Holds the Confluence page URL after a successful publish. Null/missing
#    means "not yet published." The URL is stable — re-publish updates the
#    same Confluence page; the URL does not change.
#
#  • cr_doc_link: DEPRECATED. Previously held either a Confluence URL or a
#    local file path. Removed by migrate-cr-schema-phase3.py (XACA-0308-001).
#    If you see cr_doc_link on a board, run the migration script.
#
#  • kb-cr draft <ITEM-ID> --type <major|emergency|fyi>  [implemented in 002]
#    Creates <team-kanban>/cr-docs/<ITEM-ID>-CR.md from cr-doc-template.md.
#    Sets cr_id, cr_type, crState=cr-drafted on the board.
#
#  • kb-cr publish <ITEM-ID>  [implemented in 002]
#    Reads local md, drives the Main Event CR skill to create/update the
#    Confluence page (DPD2 space), writes the resulting URL to cr_confluence_url.
#
#  • Server endpoints (refactored in 003): /api/kanban/<id>/cr-content and
#    /api/kanban/<id>/cr-exists glob from cr-docs/<id>-CR.md directly.
#    They no longer read cr_doc_link.
#
# LOAD-BEARING INVARIANT:
#   If teamConfig.crSupport.enabled is false (or absent) on the team board,
#   ALL subcommands exit 0 with a single informational line and no writes or
#   state transitions. Note: the gate check itself performs a single read
#   (_kb_cr_is_enabled → _kb_jq_read) to evaluate the flag, but never writes.
#   This is the isolation gate for non-CR teams.
#
# Usage:
#   Container commands (v2.0):
#   kb-cr create  <title> [--type major|emergency|fyi] [--platform …] [--summary "…"]
#   kb-cr add-item     <CR-ID> <item-id>
#   kb-cr remove-item  <CR-ID> <item-id>
#   kb-cr list         [--state <state>] [--platform <name>]
#   kb-cr transition   <CR-ID> <new-state>
#   kb-cr show         <CR-ID>           [shows local md path + cr_confluence_url]
#   kb-cr attach <item-id> --to <CR-ID>  [item-perspective alias for add-item]
#   kb-cr detach <item-id>               [item-perspective alias for remove-item]
#   kb-cr publish <ITEM-ID>              [Phase 3 — 002: drives Confluence publish]
#
#   Container lifecycle (v2.0 — state + timestamp, atomic — argument starts with CR-):
#   kb-cr submit  <CR-ID>
#   kb-cr approve <CR-ID> [--approver <login>] [--approver-name "<name>"]
#   kb-cr reject  <CR-ID> [--reason "<text>"]
#   kb-cr hold    <CR-ID> [--reason "<text>"]
#   kb-cr start-dev  <CR-ID>
#   kb-cr start-test <CR-ID>
#   kb-cr deploy-dev  <CR-ID>
#   kb-cr deploy-prod <CR-ID>
#   kb-cr emergency-deploy <CR-ID> --justification "<text>"
#
#   Backwards lifecycle (v2.0 — administrative correction — XACA-0329):
#   kb-cr revert         <CR-ID|item-id> [--to <state>] [--reason "<text>"]
#                        Walk back through earlier canonical states. Strips
#                        later-state timestamps + approver attribution; preserves
#                        the snapshot in .crs[i].revert_history[].
#                        Distinct from 'reject' (CAB pushback). Multi-item CRs
#                        propagate atomically. pushback_count is preserved.
#                        --reason REQUIRED when reverting from emergency-deployed.
#   kb-cr undo           <CR-ID|item-id> [--reason "<text>"]
#                        One-step convenience: revert without --to.
#   kb-cr revert-history <CR-ID|item-id>
#                        Read-only display of revert_history[] entries.
#
#   Per-item lifecycle (v1 / legacy — argument is an item-id):
#   kb-cr draft   <item-id> --type <major|emergency|fyi>
#                 [Phase 3 — 002: creates <team-kanban>/cr-docs/<ITEM-ID>-CR.md]
#   kb-cr submit  <item-id>     [propagates via crAssignment if present; v1 fallback otherwise]
#   kb-cr approve <item-id> --by <login> --name <display-name>  [propagates; v1 fallback]
#   kb-cr reject  <item-id>     [propagates; v1 fallback]
#   kb-cr hold    <item-id>     [propagates; v1 fallback]
#   kb-cr start-dev   <item-id> [propagates; v1 fallback]
#   kb-cr start-test  <item-id> [propagates; v1 fallback]
#   kb-cr deploy-dev  <item-id> [propagates; v1 fallback]
#   kb-cr deploy-prod <item-id> [propagates; v1 fallback]
#   kb-cr emergency   <item-id> --justification "text"      [v1 only; no propagation]
#   kb-cr complete    <item-id>                              [v1 only; no container variant]
#   kb-cr backfill    [--apply]
#   kb-cr backfill    --deploy-timestamps [<CR-ID>] [--apply]
#   kb-cr show        <item-id> [displays sibling list when crAssignment present;
#                                also shows local md path + cr_confluence_url]
#   kb-cr audit       --team <slug> [--from <ISO8601>] [--to <ISO8601>]
#                     [--format md|json|both] [--out-dir <path>]
#                     [--publish-confluence] [--apply] [--parent-page-id <id>]
#   kb-cr help

# ─────────────────────────────────────────────────────────────────────────────
# Script-directory capture (must happen at source time, not inside a function)
# BASH_SOURCE[0] works at top-level in both bash and zsh when sourced.
# Captured once here so _kb_cr_audit can locate sibling Python scripts.
# ─────────────────────────────────────────────────────────────────────────────
_KB_CR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# Internal helpers
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_timestamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# Normalize a user-supplied date string to ISO 8601 UTC for deploy_window_planned.
# BSD-date-safe: uses pure-shell regex only — no `date -d` (GNU-only).
# Accepts:
#   YYYY-MM-DD                 → YYYY-MM-DDT00:00:00Z  (UTC midnight)
#   YYYY-MM-DDTHH:MMZ          → YYYY-MM-DDTHH:MM:00Z  (pad seconds)
#   YYYY-MM-DDTHH:MM:SSZ       → pass through as-is
# The regex enforces calendar/time LEGAL RANGES, not just digit count:
#   month 01-12, day 01-31, hour 00-23, minute/second 00-59
#   (so 2026-99-99 / 2026-13-01 / ...T25:99:99Z are rejected). It does NOT
#   do per-month day limits or leap-year checks (no Feb-29 guard) — a pragmatic
#   stop; full date validity would need date arithmetic we deliberately avoid.
# Rejects offset forms (±HH:MM) and anything else — callers must supply UTC.
# Echoes normalized value on success; prints to stderr and returns 1 on failure.
_kb_cr_normalize_iso_date() {
    local input="$1"
    local normalized=""

    # Legal-range building blocks (inline-literal to avoid zsh/bash regex
    # interpolation differences): date = YYYY-MM-DD, time = HH:MM[:SS].
    if [[ "$input" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$ ]]; then
        # Full ISO-8601 UTC timestamp — pass through
        normalized="${input}"
    elif [[ "$input" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]Z$ ]]; then
        # HH:MM form — pad missing seconds
        normalized="${input%Z}:00Z"
    elif [[ "$input" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]]; then
        # Date-only — normalize to UTC midnight
        normalized="${input}T00:00:00Z"
    else
        echo "kb-cr: invalid deploy window '${input}'. Use YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ (UTC)." >&2
        return 1
    fi

    echo "$normalized"
}

# Print the disabled-state message and exit 0 (the isolation gate).
_kb_cr_disabled_exit() {
    local team="${1:-unknown}"
    echo "kb-cr: CR support disabled for team ${team}. Enable via SETTINGS → TEAM CONFIG → \"Enable CR (CAB) support\"."
    return 0
}

# Read teamConfig.crSupport.enabled from the board.
# Echoes "true" or "false".  Falls back to "false" on any read error.
_kb_cr_is_enabled() {
    local board_file="$1"
    local enabled
    enabled=$(_kb_jq_read "$board_file" '.teamConfig.crSupport.enabled // false' -r 2>/dev/null)
    echo "${enabled:-false}"
}

# Resolve an item-id to its array index in .backlog[].
# Echoes index or "-1" if not found.
_kb_cr_find_item() {
    local board_file="$1"
    local item_id="$2"
    _kb_jq_read "$board_file" \
        '(.backlog | to_entries[] | select(.value.id == $id) | .key) // -1' \
        --arg id "$item_id" -r 2>/dev/null || echo "-1"
}

# Common preamble: detect context, resolve board, check crSupport flag.
# Sets caller-scoped: _cr_team, _cr_board, _cr_enabled, _cr_item_id, _cr_idx
# Usage: _kb_cr_preamble <item-id-or-empty>
# Returns 1 if the preamble fails (caller should return 1).
# Returns 0 with _cr_enabled="false" if CR is disabled (caller should call _kb_cr_disabled_exit).
_kb_cr_preamble() {
    local item_id="${1:-}"

    local context
    context=$(_kb_detect_context 2>/dev/null)
    if [[ -z "$context" ]]; then
        echo "kb-cr: ERROR: cannot detect kanban context. Is tmux running?" >&2
        return 1
    fi

    _cr_team="${context%%:*}"
    _cr_board=$(_kb_get_board_file "$_cr_team")

    if [[ ! -f "$_cr_board" ]]; then
        echo "kb-cr: ERROR: no board found for team '$_cr_team'" >&2
        return 1
    fi

    _cr_enabled=$(_kb_cr_is_enabled "$_cr_board")
    _cr_item_id="$item_id"
    _cr_idx="-1"

    if [[ "$_cr_enabled" != "true" ]]; then
        return 0
    fi

    if [[ -n "$item_id" ]]; then
        _cr_idx=$(_kb_cr_find_item "$_cr_board" "$item_id")
        if [[ "$_cr_idx" == "-1" ]]; then
            echo "kb-cr: ERROR: item '$item_id' not found in team '$_cr_team' backlog." >&2
            return 1
        fi
    fi

    return 0
}

# Write a crState and optional timestamp field to an item atomically.
# Usage: _kb_cr_transition <board> <idx> <new_state> [<ts_field> <ts_value>] [extra jq args...]
_kb_cr_write_state() {
    local board_file="$1"
    local idx="$2"
    local new_state="$3"
    local ts_field="${4:-}"
    local ts_value="${5:-}"

    local filter
    filter='.backlog[$idx].crState = $state'

    local -a jq_args=(--argjson idx "$idx" --arg state "$new_state")

    if [[ -n "$ts_field" ]] && [[ -n "$ts_value" ]]; then
        filter+=" | .backlog[\$idx].${ts_field} = \$tsval"
        jq_args+=(--arg tsval "$ts_value")
    fi

    local timestamp
    timestamp=$(_kb_cr_timestamp)
    filter+=' | .lastUpdated = $lu'
    jq_args+=(--arg lu "$timestamp")

    _kb_jq_update "$board_file" "$filter" "${jq_args[@]}"
}

# Write a single timestamp field without changing crState.
_kb_cr_write_ts_only() {
    local board_file="$1"
    local idx="$2"
    local ts_field="$3"
    local ts_value="$4"

    local timestamp
    timestamp=$(_kb_cr_timestamp)

    _kb_jq_update "$board_file" \
        ".backlog[\$idx].${ts_field} = \$tsval | .lastUpdated = \$lu" \
        --argjson idx "$idx" \
        --arg tsval "$ts_value" \
        --arg lu "$timestamp"
}

# ─────────────────────────────────────────────────────────────────────────────
# _kb_cr_lifecycle_advance — core container lifecycle helper (v2.0)
#
# Atomically writes a new crState + a timestamp key to the CR container record.
# Called by all container lifecycle subcommands (submit, approve, reject, etc.)
#
# Usage:
#   _kb_cr_lifecycle_advance \
#     <board_file> <cr_idx> <cr_id> <new_state> <ts_key> [<ts_value>]
#
# Notes:
#   - ts_key is written inside .crs[cr_idx].timestamps.<ts_key>
#   - ts_value defaults to _kb_cr_timestamp if omitted
#   - updatedAt on the container and .lastUpdated on the board are both bumped
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_lifecycle_advance() {
    local board_file="$1"
    local cr_idx="$2"
    local cr_id="$3"
    local new_state="$4"
    local ts_key="$5"
    local ts_value="${6:-}"

    if [[ -z "$ts_value" ]]; then
        ts_value=$(_kb_cr_timestamp)
    fi

    local now
    now=$(_kb_cr_timestamp)

    # Capture old state before write (for activity log)
    local old_state
    old_state=$(_kb_cr_container_get_state "$board_file" "$cr_idx" 2>/dev/null || echo "")

    _kb_jq_update "$board_file" '
        .crs[$cidx].crState      = $state |
        .crs[$cidx].timestamps[$tskey] = $tsval |
        .crs[$cidx].updatedAt    = $now |
        .lastUpdated             = $now
    ' \
    --argjson cidx   "$cr_idx" \
    --arg     state  "$new_state" \
    --arg     tskey  "$ts_key" \
    --arg     tsval  "$ts_value" \
    --arg     now    "$now"

    # Append activity log entry (best-effort — never block the state transition)
    local event
    event=$(_kb_cr_activity_event "cr_state_changed" \
        "from_state=$old_state" "to_state=$new_state" 2>/dev/null || echo "")
    if [[ -n "$event" ]]; then
        _kb_cr_activity_append "$board_file" "$cr_id" "$event" 2>/dev/null || true
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# _kb_cr_container_get_state — read current crState from a container record
# Echoes the state string.
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_container_get_state() {
    local board_file="$1"
    local cr_idx="$2"
    _kb_jq_read "$board_file" ".crs[$cr_idx].crState // \"\"" -r 2>/dev/null
}

# ═════════════════════════════════════════════════════════════════════════════
# REVERT / UNDO INFRASTRUCTURE (XACA-0329)
# ═════════════════════════════════════════════════════════════════════════════
#
# Revert is an ADMINISTRATIVE CORRECTION that walks a CR backwards through
# its lifecycle. It is DISTINCT from `cr-rejected` (a CAB-process pushback)
# and from `transition` (a force-write with no field stripping).
#
# When reverting from <current> to <target>:
#   1. Strip the timestamp + auxiliary fields owned by every state with rank
#      strictly greater than <target>'s rank, IF their evidence is present
#      on the container (timestamp non-null). Evidence-based stripping is
#      robust against branches and re-submits.
#   2. Set crState = <target>.
#   3. Append a new entry to .crs[i].revert_history[] capturing the snapshot
#      of stripped values for forensic audit. The stripped data is never lost
#      — it is preserved inside revert_history.
#   4. Append an activity-log event of type "cr_state_reverted".
#
# Multi-item CR support is FREE: revert operates on .crs[i], and all itemIds[]
# siblings read state from that container. No per-item v1 fallback exists for
# revert — the dispatcher routes item-id calls to the container variant via
# the same _kb_cr_dispatch_item_lifecycle pattern.
#
# revert_history[] entry schema:
#   {
#     "ts":              "<ISO 8601 UTC>",
#     "actor":           "<KB_CR_ACTOR or 'kb-cr'>",
#     "operation":       "revert" | "undo",
#     "from_state":      "<crState before this revert>",
#     "to_state":        "<crState after this revert>",
#     "reason":          "<--reason flag value, or null>",
#     "stripped_states": ["<state>", ...],
#     "stripped_fields": {
#       "<state>": { "<dotted-path-under-.crs[i]>": <old_value>, ... },
#       ...
#     }
#   }
#
# Canonical state ranking (used to determine "earlier than"):
#     cr-drafted=0, cr-submitted=10, cr-rejected=11, cr-held=12,
#     cr-approved=20, implementing=30, deployed-dev=40, deployed-prod=50,
#     emergency-deployed=60.
# cr-rejected and cr-held are positioned between cr-submitted and cr-approved
# because both are ENTERED from cr-submitted (cr-held may also be entered from
# cr-approved, which is handled by the evidence-based strip — cr-approved's
# fields are stripped only if their timestamps are present).
# ═════════════════════════════════════════════════════════════════════════════

# Echo the canonical rank of a crState. -1 if unknown.
_kb_cr_state_rank() {
    case "$1" in
        cr-drafted)         echo 0  ;;
        cr-submitted)       echo 10 ;;
        cr-rejected)        echo 11 ;;
        cr-held)            echo 12 ;;
        cr-approved)        echo 20 ;;
        implementing)       echo 30 ;;
        deployed-dev)       echo 40 ;;
        deployed-prod)      echo 50 ;;
        emergency-deployed) echo 60 ;;
        *)                  echo -1 ;;
    esac
}

# Echo the timestamp + auxiliary fields owned by <state>, one per line, format:
#     <kind>\t<dotted-path-under-.crs[i]>
# kind ∈ { ts, obj, scalar } — informational only; del() handles all kinds.
# Empty output means "<state> owns no strippable fields" (cr-drafted).
# Non-zero exit means "<state> is unknown".
#
# pushback_count and pushback_notes are deliberately PRESERVED on revert from
# cr-rejected / cr-held: those CAB events did happen and the audit trail of
# them stays. Revert is an administrative correction of the state-write itself,
# not erasure of CAB process history. (See revert_history[].reason for the
# operator's note explaining the correction.)
_kb_cr_state_strip_spec() {
    case "$1" in
        cr-drafted)         ;;
        cr-submitted)       printf 'ts\ttimestamps.cr_submitted_at\n' ;;
        cr-rejected)        printf 'ts\ttimestamps.cr_rejected_at\n' ;;
        cr-held)            printf 'ts\ttimestamps.cr_held_at\n' ;;
        cr-approved)        printf 'ts\ttimestamps.cr_approved_at\nobj\tapprover\n' ;;
        implementing)       printf 'ts\ttimestamps.cr_started_dev_at\nts\ttimestamps.cr_started_test_at\n' ;;
        deployed-dev)       printf 'ts\ttimestamps.cr_deployed_dev_at\n' ;;
        deployed-prod)      printf 'ts\ttimestamps.cr_deployed_prod_at\n' ;;
        emergency-deployed) printf 'ts\ttimestamps.cr_emergency_deployed_at\nscalar\temergency_justification\n' ;;
        *)                  return 1 ;;
    esac
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# _kb_cr_state_entry_ts_field — canonical state -> entry-timestamp field map
#
# Echoes the single timestamps.<field> key a CR stamps when it ENTERS <state>.
# Empty output means the state stamps nothing on entry (cr-drafted — its moment
# is recorded as cr_created_at by `kb-cr create`).
# Non-zero exit means <state> is not a valid crState.
#
# This mirrors the ts_key argument each dedicated lifecycle subcommand already
# passes to _kb_cr_lifecycle_advance, and is the single source of truth for
# `kb-cr transition`.
#
# It is deliberately NOT _kb_cr_state_strip_spec. That map answers a different
# question — what REVERT removes — and differs in two ways that matter here:
#   * it omits terminal cr-closed (never reverted past), which transition needs;
#   * it lists BOTH cr_started_dev_at and cr_started_test_at for `implementing`,
#     only the first of which is stamped on entry (see _kb_cr_implement).
# Reusing it would stamp the wrong field set. Keep the two in sync by hand when
# a new crState is added — both cases must be extended together. (XACA-0297-005)
# ─────────────────────────────────────────────────────────────────────────────
_kb_cr_state_entry_ts_field() {
    case "$1" in
        cr-drafted)         ;;                              # stamped by `kb-cr create`
        cr-submitted)       echo "cr_submitted_at"          ;;
        cr-rejected)        echo "cr_rejected_at"           ;;
        cr-held)            echo "cr_held_at"               ;;
        cr-approved)        echo "cr_approved_at"           ;;
        implementing)       echo "cr_started_dev_at"        ;;
        deployed-dev)       echo "cr_deployed_dev_at"       ;;
        deployed-prod)      echo "cr_deployed_prod_at"      ;;
        emergency-deployed) echo "cr_emergency_deployed_at" ;;
        cr-closed)          echo "cr_closed_at"             ;;
        *)                  return 1 ;;
    esac
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# _kb_cr_stamp_state_entry — force-write <new_state> AND stamp its entry
# timestamp, preserving any timestamp already present.
#
#   _kb_cr_stamp_state_entry <board_file> <cr_idx> <cr_id> <new_state>
#
# This is the SHARED implementation behind every force-write state change:
#   * `kb-cr transition` (CLI)                     — _kb_cr_container_transition
#   * the LCARS CR transition endpoint (XACA-0328) — lcars-ui/server.py
#
# Both previously wrote crState + updatedAt inline and stamped NO timestamp,
# which is why 24 CRs reached cr-closed carrying only 3 cr_closed_at values
# (XACA-0297). server.py's own comment claimed it called the shared helper;
# the code had drifted to a private copy. Route new call sites through HERE
# rather than open-coding a fourth copy.
#
# Delegates to _kb_cr_lifecycle_advance, so the cr_state_changed activity
# event is emitted here — callers must NOT append their own.
# ─────────────────────────────────────────────────────────────────────────────
_kb_cr_stamp_state_entry() {
    local board_file="$1"
    local cr_idx="$2"
    local cr_id="$3"
    local new_state="$4"

    local ts_field
    ts_field=$(_kb_cr_state_entry_ts_field "$new_state")
    if [[ $? -ne 0 ]]; then
        echo "_kb_cr_stamp_state_entry: unknown state '$new_state'." >&2
        return 1
    fi

    local now
    now=$(_kb_cr_timestamp)

    # States that stamp nothing on entry (cr-drafted) still need the state write.
    if [[ -z "$ts_field" ]]; then
        _kb_jq_update "$board_file" '
            .crs[$cidx].crState   = $state |
            .crs[$cidx].updatedAt = $ts |
            .lastUpdated          = $ts
        ' \
        --argjson cidx  "$cr_idx" \
        --arg     state "$new_state" \
        --arg     ts    "$now" \
        || return 1
        return 0
    fi

    # Preserve an existing timestamp: a force-write must not rewrite when the
    # CR first entered this state. Preserving is recoverable via revert;
    # overwriting destroys the original irreversibly.
    local existing
    existing=$(_kb_jq_read "$board_file" \
        ".crs[$cr_idx].timestamps[\"$ts_field\"] // \"\"" -r 2>/dev/null)

    if [[ -n "$existing" ]]; then
        _kb_cr_lifecycle_advance "$board_file" "$cr_idx" "$cr_id" \
            "$new_state" "$ts_field" "$existing" || return 1
    else
        _kb_cr_lifecycle_advance "$board_file" "$cr_idx" "$cr_id" \
            "$new_state" "$ts_field" "$now" || return 1
    fi
    return 0
}

# Echo every canonical state with rank > <target_rank>, ascending by rank,
# one per line. Used by the revert driver to enumerate which states' fields
# may need stripping when walking back to a target state.
_kb_cr_states_above_rank() {
    local target_rank="$1"
    local s r
    for s in cr-drafted cr-submitted cr-rejected cr-held cr-approved implementing deployed-dev deployed-prod emergency-deployed; do
        r=$(_kb_cr_state_rank "$s")
        if (( r > target_rank )); then
            echo "$s"
        fi
    done
}

# _kb_cr_revert_strip_state_data <board_file> <cr_idx> <state>
#
# Strip the fields owned by <state> from .crs[<cr_idx>], capturing their
# old values into a JSON snapshot which is echoed on stdout. The snapshot
# is a flat object keyed by the dotted path:
#     { "timestamps.cr_approved_at": "2026-05-04T...", "approver": {...} }
# Empty snapshot ({}) is echoed if <state> owns no fields (cr-drafted) or if
# all of its fields are already null/absent (no-op revert past that state).
#
# DOES NOT update crState, updatedAt, or lastUpdated — caller (the revert
# driver) is responsible for sequencing those writes once at the end of a
# multi-state strip walk.
#
# Returns non-zero only on hard failure (jq error, unknown state).
_kb_cr_revert_strip_state_data() {
    local board_file="$1"
    local cr_idx="$2"
    local state="$3"

    local spec
    if ! spec=$(_kb_cr_state_strip_spec "$state"); then
        echo "kb-cr: ERROR: _kb_cr_revert_strip_state_data — unknown state '$state'" >&2
        return 1
    fi

    if [[ -z "$spec" ]]; then
        echo "{}"
        return 0
    fi

    # Build capture and strip jq filters in lockstep.
    # capture: starts as `{}` and accumulates `.[<path>] = $cr.<path>`
    # strip:   starts as `.` and accumulates `| del(.crs[$cidx].<path>)`
    # NOTE: avoid `path` as a local-var name — zsh binds lowercase `path` to
    # the PATH env var, so `local path=""` empties PATH inside the function
    # and breaks every external command. Use `field_path` instead.
    local capture_filter='{}'
    local strip_filter='.'
    local kind="" field_path=""
    while IFS=$'\t' read -r kind field_path; do
        [[ -z "$field_path" ]] && continue
        capture_filter+=" | .[\"$field_path\"] = (\$cr.$field_path // null)"
        strip_filter+=" | del(.crs[\$cidx].$field_path)"
    done <<< "$spec"

    # Capture old values BEFORE mutation.
    local snapshot=""
    snapshot=$(_kb_jq_read "$board_file" \
        ".crs[$cr_idx] as \$cr | $capture_filter" 2>/dev/null) || snapshot='{}'

    if [[ -z "$snapshot" ]]; then
        snapshot='{}'
    fi

    # Apply the strip.
    if ! _kb_jq_update "$board_file" "$strip_filter" --argjson cidx "$cr_idx"; then
        echo "kb-cr: ERROR: _kb_cr_revert_strip_state_data — strip write failed for state '$state'" >&2
        return 1
    fi

    echo "$snapshot"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Activity log infrastructure (XACA-0328-002)
#
# File path: <team-kanban-dir>/change-requests/activity/<CR-ID>.json
# Schema: { version, crId, events: [...] } — events are append-only, ts asc.
# ─────────────────────────────────────────────────────────────────────────────

# _kb_cr_activity_path <board_file> <cr_id>
# Echoes the absolute path to the activity log JSON.
# Creates the parent directory if it does not exist.
_kb_cr_activity_path() {
    local board_file="$1"
    local cr_id="$2"
    local board_dir
    board_dir="$(dirname "$board_file")"
    local activity_dir="${board_dir}/change-requests/activity"
    mkdir -p "$activity_dir" 2>/dev/null || true
    echo "${activity_dir}/${cr_id}.json"
}

# _kb_cr_activity_event <type> [key=value ...]
# Builds a JSON event object. Auto-fills ts (UTC ISO 8601) and actor.
# Actor defaults to "kb-cr"; override via KB_CR_ACTOR env var.
# Supported optional key=value pairs: from_state, to_state, field, old_value, new_value, note
# Echoes a JSON object on stdout.
_kb_cr_activity_event() {
    local type="$1"; shift
    local ts actor
    ts=$(_kb_cr_timestamp)
    actor="${KB_CR_ACTOR:-kb-cr}"

    # Start with required fields
    local jq_filter='{ ts: $ts, type: $type, actor: $actor }'
    local -a jq_args=(--arg ts "$ts" --arg type "$type" --arg actor "$actor")

    # Parse optional key=value pairs
    local from_state="" to_state="" field="" old_value="" new_value="" note=""
    local kv key val
    for kv in "$@"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        case "$key" in
            from_state) from_state="$val" ;;
            to_state)   to_state="$val"   ;;
            field)      field="$val"      ;;
            old_value)  old_value="$val"  ;;
            new_value)  new_value="$val"  ;;
            note)       note="$val"       ;;
        esac
    done

    # Conditionally include optional fields
    [[ -n "$from_state" ]] && jq_filter+=' | . + { from_state: $from_state }' && jq_args+=(--arg from_state "$from_state")
    [[ -n "$to_state"   ]] && jq_filter+=' | . + { to_state: $to_state }'     && jq_args+=(--arg to_state "$to_state")
    [[ -n "$field"      ]] && jq_filter+=' | . + { field: $field }'           && jq_args+=(--arg field "$field")
    [[ -n "$old_value"  ]] && jq_filter+=' | . + { old_value: $old_value }'   && jq_args+=(--arg old_value "$old_value")
    [[ -n "$new_value"  ]] && jq_filter+=' | . + { new_value: $new_value }'   && jq_args+=(--arg new_value "$new_value")
    [[ -n "$note"       ]] && jq_filter+=' | . + { note: $note }'             && jq_args+=(--arg note "$note")

    jq -n "${jq_args[@]}" "$jq_filter"
}

# _kb_cr_activity_append <board_file> <cr_id> <event_json>
# Atomically appends an event object to events[].
# Creates the file with skeleton if missing.
# Caps events[] at KB_CR_ACTIVITY_MAX (default 1000) — oldest events drop
# off the front. Set KB_CR_ACTIVITY_MAX=0 to disable the cap.
_kb_cr_activity_append() {
    local board_file="$1"
    local cr_id="$2"
    local event_json="$3"

    local activity_file
    activity_file=$(_kb_cr_activity_path "$board_file" "$cr_id")

    local lock_file="${activity_file}.lock"
    local tmp="${activity_file}.tmp.$$"
    local evt_tmp="${activity_file}.evt.$$"
    local cap="${KB_CR_ACTIVITY_MAX:-1000}"

    # Write event JSON to a temp file to avoid quoting issues across Perl boundary
    printf '%s\n' "$event_json" > "$evt_tmp"

    # Use Perl flock (same pattern as _kb_jq_update in kanban-helpers.sh —
    # macOS ships perl but not the standalone flock command).
    perl - "$activity_file" "$lock_file" "$tmp" "$cr_id" "$evt_tmp" "$cap" <<'PERL'
use strict; use warnings;
use Fcntl qw(:flock);
my ($afile, $lfile, $tmp, $cr_id, $evt_file, $cap) = @ARGV;
$cap = 0 unless defined $cap && $cap =~ /^\d+$/;

open(my $lk, '>>', $lfile) or die "Cannot open lock: $!";
flock($lk, LOCK_EX) or die "Cannot lock: $!";

my $cap_filter = $cap > 0
    ? " | if (.events | length > $cap) then .events |= .[-$cap:] else . end"
    : "";

my $new_content;
if (-f $afile) {
    $new_content = qx{jq --slurpfile evt \Q$evt_file\E '.events += [\$evt[0]]$cap_filter' \Q$afile\E};
} else {
    $new_content = qx{jq -n --arg crId \Q$cr_id\E --slurpfile evt \Q$evt_file\E '{ version: "1.0", crId: \$crId, events: [\$evt[0]] }'};
}

if ($? == 0 && defined $new_content && $new_content ne '') {
    open(my $out, '>', $tmp) or die "Cannot write $tmp: $!";
    print $out $new_content;
    close $out;
    rename($tmp, $afile) or die "Cannot rename $tmp to $afile: $!";
}

flock($lk, LOCK_UN);
close $lk;
PERL

    local perl_rc=$?
    rm -f "$evt_tmp" 2>/dev/null || true
    return $perl_rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Public: kb-cr activity record / list
# ─────────────────────────────────────────────────────────────────────────────

# _kb_cr_activity_record <cr_id> <type> [key=value ...]
# Public CLI entry point — builds event + appends to log.
_kb_cr_activity_record() {
    local cr_id="${1:-}"
    local type="${2:-}"
    if [[ -z "$cr_id" || -z "$type" ]]; then
        echo "Usage: kb-cr activity record <cr_id> <type> [key=value ...]" >&2
        return 1
    fi
    shift 2

    # Resolve the board file for this CR's team
    local board_file
    board_file=$(_kb_cr_activity_resolve_board "$cr_id") || return 1

    local event
    event=$(_kb_cr_activity_event "$type" "$@") || return 1
    _kb_cr_activity_append "$board_file" "$cr_id" "$event"
    echo "Activity recorded: $type for $cr_id"
}

# _kb_cr_activity_list <cr_id> [--json | --pretty]
# Reads and prints events from the activity log.
_kb_cr_activity_list() {
    local cr_id="${1:-}"
    if [[ -z "$cr_id" ]]; then
        echo "Usage: kb-cr activity list <cr_id> [--json | --pretty]" >&2
        return 1
    fi
    local fmt="${2:---pretty}"

    local board_file
    board_file=$(_kb_cr_activity_resolve_board "$cr_id") || return 1

    local activity_file
    activity_file=$(_kb_cr_activity_path "$board_file" "$cr_id")

    if [[ ! -f "$activity_file" ]]; then
        if [[ "$fmt" == "--json" ]]; then
            jq -n --arg crId "$cr_id" '{ crId: $crId, events: [] }'
        else
            echo "No activity log found for $cr_id"
        fi
        return 0
    fi

    if [[ "$fmt" == "--json" ]]; then
        cat "$activity_file"
        return 0
    fi

    # Human-readable output
    jq -r '.events[] | "\(.ts)  \(.type)  [\(.actor)]" +
        (if .from_state then "  \(.from_state) → \(.to_state)" else "" end) +
        (if .field then "  \(.field): \(.old_value // "—") → \(.new_value // "—")" else "" end) +
        (if .note then "  (\(.note))" else "" end)' \
        "$activity_file"
}

# _kb_cr_activity_resolve_board <cr_id>
# Resolves the board file for a CR-ID by examining all known team boards.
# CR-ID format: CR-<TEAM_UPPER>-<YYYYMMDD>-<seq>
# Extracts the team segment and maps to a board file.
_kb_cr_activity_resolve_board() {
    local cr_id="$1"
    # CR-IOS-20260515-0123 → team segment = "IOS" → lower = "ios"
    local team_upper
    team_upper=$(echo "$cr_id" | sed 's/^CR-\([A-Z][A-Z]*\)-.*/\1/')
    if [[ -z "$team_upper" ]]; then
        echo "_kb_cr_activity_resolve_board: cannot parse team from '$cr_id'" >&2
        return 1
    fi
    local team="${team_upper:l}"  # zsh lowercase

    local board_file
    board_file=$(_kb_get_board_file "$team" 2>/dev/null)
    if [[ -z "$board_file" || ! -f "$board_file" ]]; then
        # Fallback: try current context board (useful for dev-team / academy)
        local context
        context=$(_kb_detect_context 2>/dev/null)
        if [[ -n "$context" ]]; then
            local ctx_team="${context%%:*}"
            board_file=$(_kb_get_board_file "$ctx_team" 2>/dev/null)
        fi
    fi
    if [[ -z "$board_file" || ! -f "$board_file" ]]; then
        echo "_kb_cr_activity_resolve_board: no board found for team '$team'" >&2
        return 1
    fi
    echo "$board_file"
}

# ─────────────────────────────────────────────────────────────────────────────
# Container lifecycle subcommands (v2.0 schema)
# Each one: validates predecessor state → calls _kb_cr_lifecycle_advance.
# ─────────────────────────────────────────────────────────────────────────────

# kb-cr submit <CR-ID>
# Predecessor states: cr-drafted, cr-held (re-submit after hold), cr-rejected (re-submit after rework)
# Semantics: "submitted" means a CR-Proper Confluence page link has been appended to the bottom of the
# CR request page and cr_proper_url has been written (by the poller or manually via the LCARS UI).
# This command advances the state manually for back-compat; the poller (XACA-0328-003) is the
# authoritative trigger in automated Confluence-driven workflow.
_kb_cr_container_submit() {
    local cr_id="${1:-}"
    if [[ -z "$cr_id" ]]; then
        echo "Usage: kb-cr submit <CR-ID>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr submit: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    local current_state
    current_state=$(_kb_cr_container_get_state "$_cr_board" "$cr_idx")

    case "$current_state" in
        cr-drafted|cr-held|cr-rejected) ;;
        cr-submitted)
            echo "kb-cr submit: CR '$cr_id' is already in state 'cr-submitted'." >&2
            return 1
            ;;
        cr-approved|implementing|deployed-dev|deployed-prod|emergency-deployed)
            echo "kb-cr submit: CR '$cr_id' is in state '$current_state'; cannot re-submit from this state." >&2
            echo "  Expected one of: cr-drafted, cr-held, cr-rejected" >&2
            return 1
            ;;
        *)
            echo "kb-cr submit: CR '$cr_id' is in unexpected state '$current_state'; expected one of: cr-drafted, cr-held, cr-rejected" >&2
            return 1
            ;;
    esac

    local ts
    ts=$(_kb_cr_timestamp)
    _kb_cr_lifecycle_advance "$_cr_board" "$cr_idx" "$cr_id" "cr-submitted" "cr_submitted_at" "$ts" || return 1
    echo "kb-cr submit: [$cr_id] $current_state -> cr-submitted (cr_submitted_at=$ts)"
}

# kb-cr approve <CR-ID> [--approver <login>] [--approver-name "<name>"]
# Predecessor states: cr-submitted
_kb_cr_container_approve() {
    local cr_id="${1:-}"
    shift 2>/dev/null

    if [[ -z "$cr_id" ]]; then
        echo "Usage: kb-cr approve <CR-ID> [--approver <login>] [--approver-name \"<name>\"]" >&2
        return 1
    fi

    local approver_login="" approver_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --approver)       approver_login="${2:-}";  shift 2 ;;
            --approver=*)     approver_login="${1#--approver=}"; shift ;;
            --approver-name)  approver_name="${2:-}";   shift 2 ;;
            --approver-name=*) approver_name="${1#--approver-name=}"; shift ;;
            *) shift ;;
        esac
    done

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr approve: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    local current_state
    current_state=$(_kb_cr_container_get_state "$_cr_board" "$cr_idx")

    case "$current_state" in
        cr-submitted) ;;
        cr-approved)
            echo "kb-cr approve: CR '$cr_id' is already approved." >&2
            return 1
            ;;
        *)
            echo "kb-cr approve: CR '$cr_id' is in state '$current_state'; expected one of: cr-submitted" >&2
            return 1
            ;;
    esac

    local ts
    ts=$(_kb_cr_timestamp)

    # Advance state + timestamp atomically
    _kb_cr_lifecycle_advance "$_cr_board" "$cr_idx" "$cr_id" "cr-approved" "cr_approved_at" "$ts" || return 1

    # Write approver fields only if provided (preserve existing if flags omitted)
    if [[ -n "$approver_login" || -n "$approver_name" ]]; then
        local -a approver_args=(--argjson cidx "$cr_idx" --arg now "$ts")
        local approver_filter='.crs[$cidx].updatedAt = $now | .lastUpdated = $now'

        if [[ -n "$approver_login" ]]; then
            approver_filter+=' | .crs[$cidx].approver.login = $login'
            approver_args+=(--arg login "$approver_login")
        fi
        if [[ -n "$approver_name" ]]; then
            approver_filter+=' | .crs[$cidx].approver.name = $aname'
            approver_args+=(--arg aname "$approver_name")
        fi

        _kb_jq_update "$_cr_board" "$approver_filter" "${approver_args[@]}" || return 1
    fi

    local approver_msg=""
    [[ -n "$approver_login" ]] && approver_msg+=" approver=$approver_login"
    [[ -n "$approver_name" ]]  && approver_msg+=" ($approver_name)"
    echo "kb-cr approve: [$cr_id] cr-submitted -> cr-approved (cr_approved_at=$ts${approver_msg})"
}

# kb-cr reject <CR-ID> [--reason "<text>"]
# Predecessor states: cr-submitted, cr-held
_kb_cr_container_reject() {
    local cr_id="${1:-}"
    shift 2>/dev/null

    if [[ -z "$cr_id" ]]; then
        echo "Usage: kb-cr reject <CR-ID> [--reason \"<text>\"]" >&2
        return 1
    fi

    local reason=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reason)   reason="${2:-}"; shift 2 ;;
            --reason=*) reason="${1#--reason=}"; shift ;;
            *) shift ;;
        esac
    done

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr reject: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    local current_state
    current_state=$(_kb_cr_container_get_state "$_cr_board" "$cr_idx")

    case "$current_state" in
        cr-submitted|cr-held) ;;
        cr-rejected)
            echo "kb-cr reject: CR '$cr_id' is already rejected." >&2
            return 1
            ;;
        *)
            echo "kb-cr reject: CR '$cr_id' is in state '$current_state'; expected one of: cr-submitted, cr-held" >&2
            return 1
            ;;
    esac

    local ts
    ts=$(_kb_cr_timestamp)

    # Advance state + timestamp, then update pushback fields
    _kb_cr_lifecycle_advance "$_cr_board" "$cr_idx" "$cr_id" "cr-rejected" "cr_rejected_at" "$ts" || return 1

    local -a pushback_args=(--argjson cidx "$cr_idx" --arg ts "$ts")
    local pushback_filter='
        .crs[$cidx].pushback_count = ((.crs[$cidx].pushback_count // 0) + 1) |
        .crs[$cidx].updatedAt = $ts |
        .lastUpdated = $ts
    '
    if [[ -n "$reason" ]]; then
        pushback_filter+=' | .crs[$cidx].pushback_notes = (
            if (.crs[$cidx].pushback_notes // "") == "" then $reason
            else (.crs[$cidx].pushback_notes + "\n" + $reason)
            end
        )'
        pushback_args+=(--arg reason "$reason")
    fi

    _kb_jq_update "$_cr_board" "$pushback_filter" "${pushback_args[@]}" || return 1

    local reason_msg=""
    [[ -n "$reason" ]] && reason_msg=" reason=\"$reason\""
    echo "kb-cr reject: [$cr_id] $current_state -> cr-rejected (pushback_count incremented${reason_msg})"
}

# kb-cr hold <CR-ID> [--reason "<text>"]
# Predecessor states: cr-submitted, cr-approved
_kb_cr_container_hold() {
    local cr_id="${1:-}"
    shift 2>/dev/null

    if [[ -z "$cr_id" ]]; then
        echo "Usage: kb-cr hold <CR-ID> [--reason \"<text>\"]" >&2
        return 1
    fi

    local reason=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reason)   reason="${2:-}"; shift 2 ;;
            --reason=*) reason="${1#--reason=}"; shift ;;
            *) shift ;;
        esac
    done

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr hold: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    local current_state
    current_state=$(_kb_cr_container_get_state "$_cr_board" "$cr_idx")

    case "$current_state" in
        cr-submitted|cr-approved) ;;
        cr-held)
            echo "kb-cr hold: CR '$cr_id' is already on hold." >&2
            return 1
            ;;
        *)
            echo "kb-cr hold: CR '$cr_id' is in state '$current_state'; expected one of: cr-submitted, cr-approved" >&2
            return 1
            ;;
    esac

    local ts
    ts=$(_kb_cr_timestamp)

    _kb_cr_lifecycle_advance "$_cr_board" "$cr_idx" "$cr_id" "cr-held" "cr_held_at" "$ts" || return 1

    # Append reason to pushback_notes and increment pushback_count if reason provided
    if [[ -n "$reason" ]]; then
        local -a hold_args=(--argjson cidx "$cr_idx" --arg reason "$reason" --arg ts "$ts")
        _kb_jq_update "$_cr_board" '
            .crs[$cidx].pushback_count = ((.crs[$cidx].pushback_count // 0) + 1) |
            .crs[$cidx].pushback_notes = (
                if (.crs[$cidx].pushback_notes // "") == "" then $reason
                else (.crs[$cidx].pushback_notes + "\n" + $reason)
                end
            ) |
            .crs[$cidx].updatedAt = $ts |
            .lastUpdated = $ts
        ' "${hold_args[@]}" || return 1
    fi

    local reason_msg=""
    [[ -n "$reason" ]] && reason_msg=" reason=\"$reason\""
    echo "kb-cr hold: [$cr_id] $current_state -> cr-held (cr_held_at=$ts${reason_msg})"
}

# kb-cr close <CR-ID> [--reason "<text>"]
# Transitions a CR to the terminal state cr-closed from any non-closed state.
# Does NOT increment pushback_count — this is manual archival, not a rejection.
_kb_cr_container_close() {
    local cr_id="${1:-}"
    shift 2>/dev/null

    if [[ -z "$cr_id" ]]; then
        echo "Usage: kb-cr close <CR-ID> [--reason \"<text>\"]" >&2
        return 1
    fi

    local reason=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reason)   reason="${2:-}"; shift 2 ;;
            --reason=*) reason="${1#--reason=}"; shift ;;
            *) shift ;;
        esac
    done

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr close: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    local current_state
    current_state=$(_kb_cr_container_get_state "$_cr_board" "$cr_idx")

    # Idempotent guard — already closed
    if [[ "$current_state" == "cr-closed" ]]; then
        echo "kb-cr close: CR '$cr_id' is already closed." >&2
        return 1
    fi

    local ts
    ts=$(_kb_cr_timestamp)

    _kb_cr_lifecycle_advance "$_cr_board" "$cr_idx" "$cr_id" "cr-closed" "cr_closed_at" "$ts" || return 1

    # Write closed_reason if provided (not pushback_notes — not a pushback).
    # Unconditional assignment is safe because the idempotent guard above
    # prevents re-close, so closed_reason is always empty when this runs.
    if [[ -n "$reason" ]]; then
        local -a close_args=(--argjson cidx "$cr_idx" --arg reason "$reason" --arg ts "$ts")
        _kb_jq_update "$_cr_board" '
            .crs[$cidx].closed_reason = $reason |
            .crs[$cidx].updatedAt = $ts |
            .lastUpdated = $ts
        ' "${close_args[@]}" || return 1
    fi

    local reason_msg=""
    [[ -n "$reason" ]] && reason_msg=" reason=\"$reason\""
    echo "kb-cr close: [$cr_id] $current_state -> cr-closed (cr_closed_at=$ts${reason_msg})"
}

# kb-cr deploy-dev <CR-ID>
# Predecessor states: cr-approved, implementing
_kb_cr_container_deploy_dev() {
    local cr_id="${1:-}"
    if [[ -z "$cr_id" ]]; then
        echo "Usage: kb-cr deploy-dev <CR-ID>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr deploy-dev: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    local current_state
    current_state=$(_kb_cr_container_get_state "$_cr_board" "$cr_idx")

    case "$current_state" in
        cr-approved|implementing) ;;
        deployed-dev)
            echo "kb-cr deploy-dev: CR '$cr_id' is already in state 'deployed-dev'." >&2
            return 1
            ;;
        *)
            echo "kb-cr deploy-dev: CR '$cr_id' is in state '$current_state'; expected one of: cr-approved, implementing" >&2
            return 1
            ;;
    esac

    local ts
    ts=$(_kb_cr_timestamp)
    _kb_cr_lifecycle_advance "$_cr_board" "$cr_idx" "$cr_id" "deployed-dev" "cr_deployed_dev_at" "$ts" || return 1
    echo "kb-cr deploy-dev: [$cr_id] $current_state -> deployed-dev (cr_deployed_dev_at=$ts)"
}

# kb-cr deploy-prod <CR-ID>
# Predecessor states: deployed-dev (preferred), cr-approved (skip to prod — warns)
_kb_cr_container_deploy_prod() {
    local cr_id="${1:-}"
    if [[ -z "$cr_id" ]]; then
        echo "Usage: kb-cr deploy-prod <CR-ID>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr deploy-prod: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    local current_state
    current_state=$(_kb_cr_container_get_state "$_cr_board" "$cr_idx")

    local warn_skip_dev=0
    case "$current_state" in
        deployed-dev) ;;
        cr-approved|implementing)
            warn_skip_dev=1
            ;;
        deployed-prod)
            echo "kb-cr deploy-prod: CR '$cr_id' is already in state 'deployed-prod'." >&2
            return 1
            ;;
        *)
            echo "kb-cr deploy-prod: CR '$cr_id' is in state '$current_state'; expected one of: deployed-dev, cr-approved, implementing" >&2
            return 1
            ;;
    esac

    if [[ $warn_skip_dev -eq 1 ]]; then
        echo "kb-cr deploy-prod: WARNING: CR '$cr_id' is skipping deployed-dev (current state: $current_state). Proceeding." >&2
    fi

    local ts
    ts=$(_kb_cr_timestamp)
    _kb_cr_lifecycle_advance "$_cr_board" "$cr_idx" "$cr_id" "deployed-prod" "cr_deployed_prod_at" "$ts" || return 1
    echo "kb-cr deploy-prod: [$cr_id] $current_state -> deployed-prod (cr_deployed_prod_at=$ts)"
}

# kb-cr start-dev <CR-ID>
# Predecessor states: cr-approved
# Sets crState to "implementing" and writes timestamps.cr_started_dev_at.
_kb_cr_container_start_dev() {
    local cr_id="${1:-}"
    if [[ -z "$cr_id" ]]; then
        echo "Usage: kb-cr start-dev <CR-ID>" >&2
        return 1
    fi

    # Check the CR-enabled gate first (disabled-board callers get the standard message).
    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr start-dev: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    local current_state
    current_state=$(_kb_cr_container_get_state "$_cr_board" "$cr_idx")

    case "$current_state" in
        cr-approved) ;;
        implementing)
            echo "kb-cr start-dev: CR '$cr_id' is already in state 'implementing'." >&2
            return 1
            ;;
        *)
            echo "kb-cr start-dev: CR '$cr_id' is in state '$current_state'; expected: cr-approved" >&2
            return 1
            ;;
    esac

    local ts
    ts=$(_kb_cr_timestamp)
    _kb_cr_lifecycle_advance "$_cr_board" "$cr_idx" "$cr_id" "implementing" "cr_started_dev_at" "$ts" || return 1
    echo "kb-cr start-dev: [$cr_id] $current_state -> implementing (cr_started_dev_at=$ts)"
}

# kb-cr start-test <CR-ID>
# Predecessor states: implementing
# Does NOT change crState — writes timestamps.cr_started_test_at only.
# (No "ready-for-test" state exists in the crStates schema; timestamp marks the
# transition point and deploy-dev remains the next state-changing lifecycle step.)
_kb_cr_container_start_test() {
    local cr_id="${1:-}"
    if [[ -z "$cr_id" ]]; then
        echo "Usage: kb-cr start-test <CR-ID>" >&2
        return 1
    fi

    # Check the CR-enabled gate first (disabled-board callers get the standard message).
    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr start-test: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    local current_state
    current_state=$(_kb_cr_container_get_state "$_cr_board" "$cr_idx")

    case "$current_state" in
        implementing) ;;
        *)
            echo "kb-cr start-test: CR '$cr_id' is in state '$current_state'; expected: implementing" >&2
            return 1
            ;;
    esac

    local ts now
    ts=$(_kb_cr_timestamp)
    now=$(_kb_cr_timestamp)

    # Write timestamp only — crState is not changed (no schema state for testing phase).
    _kb_jq_update "$_cr_board" '
        .crs[$cidx].timestamps[$tskey] = $tsval |
        .crs[$cidx].updatedAt          = $now |
        .lastUpdated                   = $now
    ' \
    --argjson cidx  "$cr_idx" \
    --arg     tskey "cr_started_test_at" \
    --arg     tsval "$ts" \
    --arg     now   "$now" \
    || return 1
    echo "kb-cr start-test: [$cr_id] cr_started_test_at=$ts (crState unchanged: $current_state)"
}

# kb-cr emergency-deploy <CR-ID> --justification "<text>"
# --justification is REQUIRED (audit trail).
# Allowed from any state (break-glass path).
_kb_cr_container_emergency_deploy() {
    local cr_id="${1:-}"
    shift 2>/dev/null

    if [[ -z "$cr_id" ]]; then
        echo "Usage: kb-cr emergency-deploy <CR-ID> --justification \"<reason>\"" >&2
        return 1
    fi

    local justification=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --justification)   justification="${2:-}"; shift 2 ;;
            --justification=*) justification="${1#--justification=}"; shift ;;
            *) shift ;;
        esac
    done

    # Check the CR-enabled gate BEFORE validating --justification so that
    # disabled-board callers receive the standard "CR support disabled" message
    # (exit 0) rather than a validation error (exit 1).
    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    if [[ -z "$justification" ]]; then
        echo "kb-cr emergency-deploy: --justification is required. This is the mandatory audit trail for bypassing CAB review." >&2
        echo "Usage: kb-cr emergency-deploy <CR-ID> --justification \"<reason>\"" >&2
        return 1
    fi

    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr emergency-deploy: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    local current_state
    current_state=$(_kb_cr_container_get_state "$_cr_board" "$cr_idx")
    local ts
    ts=$(_kb_cr_timestamp)

    # Break-glass: advance state and timestamp (no predecessor validation)
    _kb_cr_lifecycle_advance "$_cr_board" "$cr_idx" "$cr_id" "emergency-deployed" "cr_emergency_deployed_at" "$ts" || return 1

    # Write emergency_justification field on the container
    _kb_jq_update "$_cr_board" '
        .crs[$cidx].emergency_justification = $just |
        .crs[$cidx].updatedAt = $ts |
        .lastUpdated = $ts
    ' \
    --argjson cidx  "$cr_idx" \
    --arg     just  "$justification" \
    --arg     ts    "$ts" \
    || return 1

    echo "kb-cr emergency-deploy: [$cr_id] $current_state -> emergency-deployed (cr_emergency_deployed_at=$ts)"
    echo "  justification: $justification"
}

# ─────────────────────────────────────────────────────────────────────────────
# _kb_cr_container_revert <CR-ID> [--to <state>] [--reason "<text>"] [--operation revert|undo]
# (XACA-0329-003)
#
# Walk a CR backwards through its lifecycle as an administrative correction.
# Strips later-state timestamps and approver attribution; preserves an audit
# trail in .crs[i].revert_history[]. Multi-item CR support is automatic —
# state lives on the container and propagates to all itemIds[] siblings.
#
# Args:
#   <CR-ID>           — required. Container ID.
#   --to <state>      — optional. Target state. Must have rank strictly less
#                       than the current state's rank. Forward walks are
#                       refused (use `transition` for force-write or use
#                       the forward verbs).
#                       If omitted, the predecessor is computed from the
#                       most-recent timestamp on the container (the latest
#                       (state, ts) pair whose ts < the current state's ts).
#   --reason "<text>" — optional but encouraged. Recorded in revert_history.
#                       Required when reverting from emergency-deployed
#                       (break-glass operations need an audit trail).
#   --operation       — internal. "revert" (default) or "undo". Recorded
#                       in revert_history[].operation; controls the user
#                       message and helps `revert-history` distinguish.
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_container_revert() {
    local cr_id="${1:-}"
    shift 2>/dev/null

    if [[ -z "$cr_id" ]]; then
        echo "Usage: kb-cr revert <CR-ID> [--to <state>] [--reason \"<text>\"]" >&2
        return 1
    fi

    local target_state="" reason="" operation="revert"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to)         target_state="${2:-}"; shift 2 ;;
            --to=*)       target_state="${1#--to=}"; shift ;;
            --reason)     reason="${2:-}"; shift 2 ;;
            --reason=*)   reason="${1#--reason=}"; shift ;;
            --operation)  operation="${2:-}"; shift 2 ;;
            --operation=*) operation="${1#--operation=}"; shift ;;
            *) shift ;;
        esac
    done

    if [[ "$operation" != "revert" && "$operation" != "undo" ]]; then
        echo "kb-cr revert: invalid --operation '$operation' (must be revert|undo)" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr $operation: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    local current_state
    current_state=$(_kb_cr_container_get_state "$_cr_board" "$cr_idx")
    if [[ -z "$current_state" ]]; then
        echo "kb-cr $operation: CR '$cr_id' has no crState — nothing to $operation." >&2
        return 1
    fi

    local current_rank
    current_rank=$(_kb_cr_state_rank "$current_state")
    if (( current_rank < 0 )); then
        echo "kb-cr $operation: CR '$cr_id' is in unknown state '$current_state'; refusing to $operation." >&2
        return 1
    fi

    # ── Compute target state ─────────────────────────────────────────────────
    if [[ -z "$target_state" ]]; then
        # Heuristic: pick the (state, ts) pair with the latest ts among those
        # whose ts is non-null AND < current state's ts. cr-drafted is the
        # implicit floor (always reachable).
        target_state=$(_kb_cr_revert_compute_predecessor "$_cr_board" "$cr_idx" "$current_state")
        if [[ -z "$target_state" ]]; then
            echo "kb-cr $operation: cannot compute predecessor for state '$current_state' on CR '$cr_id'." >&2
            echo "  Pass --to <state> to specify the target explicitly." >&2
            return 1
        fi
    fi

    # ── Validate target ──────────────────────────────────────────────────────
    local target_rank
    target_rank=$(_kb_cr_state_rank "$target_state")
    if (( target_rank < 0 )); then
        echo "kb-cr $operation: target state '$target_state' is not a known crState." >&2
        echo "  Valid: cr-drafted, cr-submitted, cr-rejected, cr-held, cr-approved," >&2
        echo "         implementing, deployed-dev, deployed-prod, emergency-deployed" >&2
        return 1
    fi

    if [[ "$target_state" == "$current_state" ]]; then
        echo "kb-cr $operation: target state '$target_state' equals current state — no-op." >&2
        return 1
    fi

    if (( target_rank >= current_rank )); then
        echo "kb-cr $operation: target state '$target_state' (rank $target_rank) is not strictly earlier than current '$current_state' (rank $current_rank)." >&2
        echo "  $operation only walks backwards. Use 'kb-cr transition' or a forward verb to advance." >&2
        return 1
    fi

    # ── Reason mandatory for emergency-deployed reverts ──────────────────────
    if [[ "$current_state" == "emergency-deployed" && -z "$reason" ]]; then
        echo "kb-cr $operation: --reason is required when reverting from emergency-deployed." >&2
        echo "  Break-glass operations need an audit trail. Pass --reason \"<text>\"." >&2
        return 1
    fi

    # ── Walk states above target_rank, strip evidence-based ──────────────────
    local stripped_states_json='[]'
    local stripped_fields_json='{}'
    local states_to_strip
    states_to_strip=$(_kb_cr_states_above_rank "$target_rank")

    local s="" snapshot="" has_data=""
    while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        snapshot=$(_kb_cr_revert_strip_state_data "$_cr_board" "$cr_idx" "$s") || return 1
        # Only record states whose snapshot has at least one captured field.
        # cr-drafted always returns {}; states with no evidence return {} too.
        if [[ -n "$snapshot" && "$snapshot" != "{}" ]]; then
            has_data=$(echo "$snapshot" | jq -r '[.[] | select(. != null)] | length > 0')
            if [[ "$has_data" == "true" ]]; then
                stripped_states_json=$(echo "$stripped_states_json" | jq --arg s "$s" '. + [$s]')
                stripped_fields_json=$(echo "$stripped_fields_json" | jq --arg s "$s" --argjson v "$snapshot" '. + {($s): $v}')
            fi
        fi
    done <<< "$states_to_strip"

    # ── Set crState = target, bump updatedAt, append revert_history entry ────
    local now actor
    now=$(_kb_cr_timestamp)
    actor="${KB_CR_ACTOR:-kb-cr}"

    local reason_arg="$reason"
    [[ -z "$reason_arg" ]] && reason_arg="null"

    local revert_entry
    if [[ -z "$reason" ]]; then
        revert_entry=$(jq -n \
            --arg ts "$now" \
            --arg actor "$actor" \
            --arg op "$operation" \
            --arg from "$current_state" \
            --arg to "$target_state" \
            --argjson stripped_states "$stripped_states_json" \
            --argjson stripped_fields "$stripped_fields_json" \
            '{ts: $ts, actor: $actor, operation: $op, from_state: $from, to_state: $to, reason: null, stripped_states: $stripped_states, stripped_fields: $stripped_fields}')
    else
        revert_entry=$(jq -n \
            --arg ts "$now" \
            --arg actor "$actor" \
            --arg op "$operation" \
            --arg from "$current_state" \
            --arg to "$target_state" \
            --arg reason "$reason" \
            --argjson stripped_states "$stripped_states_json" \
            --argjson stripped_fields "$stripped_fields_json" \
            '{ts: $ts, actor: $actor, operation: $op, from_state: $from, to_state: $to, reason: $reason, stripped_states: $stripped_states, stripped_fields: $stripped_fields}')
    fi

    _kb_jq_update "$_cr_board" '
        .crs[$cidx].crState = $target |
        .crs[$cidx].updatedAt = $now |
        .crs[$cidx].revert_history = ((.crs[$cidx].revert_history // []) + [$entry]) |
        .lastUpdated = $now
    ' \
    --argjson cidx "$cr_idx" \
    --arg target "$target_state" \
    --arg now "$now" \
    --argjson entry "$revert_entry" \
    || return 1

    # ── Activity log event ───────────────────────────────────────────────────
    local event
    event=$(_kb_cr_activity_event "cr_state_reverted" \
        "from_state=$current_state" "to_state=$target_state" \
        "note=$operation${reason:+ — $reason}" 2>/dev/null || echo "")
    if [[ -n "$event" ]]; then
        _kb_cr_activity_append "$_cr_board" "$cr_id" "$event" 2>/dev/null || true
    fi

    # ── User-facing summary ──────────────────────────────────────────────────
    local n_items
    n_items=$(_kb_jq_read "$_cr_board" ".crs[$cr_idx].itemIds | length" -r 2>/dev/null)
    n_items="${n_items:-0}"

    local stripped_count
    stripped_count=$(echo "$stripped_states_json" | jq -r 'length')

    echo "kb-cr $operation: [$cr_id] $current_state -> $target_state (${stripped_count} state(s) stripped, ${n_items} item(s) affected)"
    if [[ -n "$reason" ]]; then
        echo "  reason: $reason"
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# _kb_cr_revert_compute_predecessor <board> <cr_idx> <current_state>
# Echo the heuristic predecessor for <current_state>: the state with the
# latest timestamp whose rank < rank(current). cr-drafted is implicit floor.
# Empty echo on hard failure (current state has no inferable predecessor).
# ─────────────────────────────────────────────────────────────────────────────
_kb_cr_revert_compute_predecessor() {
    local board_file="$1"
    local cr_idx="$2"
    local current_state="$3"

    local current_rank
    current_rank=$(_kb_cr_state_rank "$current_state")
    if (( current_rank <= 0 )); then
        # cr-drafted (rank 0) or unknown — no predecessor.
        echo ""
        return 0
    fi

    # Read all canonical timestamps in one jq call. Output: <state>\t<ts>
    # Only emit lines where ts is non-null AND state's rank < current_rank.
    local lines=""
    lines=$(_kb_jq_read "$board_file" '
        .crs[($cidx | tonumber)] as $c |
        {
            "cr-submitted":       $c.timestamps.cr_submitted_at,
            "cr-rejected":        $c.timestamps.cr_rejected_at,
            "cr-held":            $c.timestamps.cr_held_at,
            "cr-approved":        $c.timestamps.cr_approved_at,
            "implementing":       $c.timestamps.cr_started_dev_at,
            "deployed-dev":       $c.timestamps.cr_deployed_dev_at,
            "deployed-prod":      $c.timestamps.cr_deployed_prod_at,
            "emergency-deployed": $c.timestamps.cr_emergency_deployed_at
        }
        | to_entries
        | map(select(.value != null and .value != ""))
        | .[]
        | "\(.key)\t\(.value)"
    ' --arg cidx "$cr_idx" -r 2>/dev/null)

    # Pick the candidate with the highest ts whose rank < current_rank.
    # Tie-break on equal timestamps by preferring the HIGHER rank (closer to
    # current) — same-second forward writes (e.g., kb-cr submit then approve
    # then start-dev in rapid succession) would otherwise return the first
    # iterated state instead of the most-recent canonical predecessor.
    local best_state="" best_ts="" best_rank=-1
    local candidate_state="" candidate_ts="" candidate_rank=-1
    local should_update=0
    while IFS=$'\t' read -r candidate_state candidate_ts; do
        [[ -z "$candidate_state" ]] && continue
        candidate_rank=$(_kb_cr_state_rank "$candidate_state")
        (( candidate_rank >= current_rank )) && continue

        should_update=0
        if [[ -z "$best_ts" ]]; then
            should_update=1
        elif [[ "$candidate_ts" > "$best_ts" ]]; then
            should_update=1
        elif [[ "$candidate_ts" == "$best_ts" ]] && (( candidate_rank > best_rank )); then
            should_update=1
        fi

        if (( should_update )); then
            best_state="$candidate_state"
            best_ts="$candidate_ts"
            best_rank="$candidate_rank"
        fi
    done <<< "$lines"

    # Floor: if no candidate found, fall back to cr-drafted (rank 0).
    if [[ -z "$best_state" ]]; then
        echo "cr-drafted"
        return 0
    fi
    echo "$best_state"
}

# ─────────────────────────────────────────────────────────────────────────────
# _kb_cr_container_revert_history <CR-ID>  (XACA-0329-005)
# Read-only display of revert_history[] for a CR. Prints a header, then one
# block per entry in chronological order. Entries are produced by revert/undo;
# this command is purely informational and does not mutate the board.
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_container_revert_history() {
    local cr_id="${1:-}"
    if [[ -z "$cr_id" ]]; then
        echo "Usage: kb-cr revert-history <CR-ID|item-id>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr revert-history: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    local current_state
    current_state=$(_kb_cr_container_get_state "$_cr_board" "$cr_idx")

    local n_entries
    n_entries=$(_kb_jq_read "$_cr_board" \
        ".crs[$cr_idx].revert_history // [] | length" -r 2>/dev/null)
    n_entries="${n_entries:-0}"

    echo "═══════════════════════════════════════════════════════════════════"
    echo " Revert History — $cr_id"
    echo "  current state: $current_state"
    echo "  entries:       $n_entries"
    echo "═══════════════════════════════════════════════════════════════════"

    if [[ "$n_entries" == "0" ]]; then
        echo ""
        echo "  (no revert/undo operations recorded for this CR)"
        echo ""
        return 0
    fi

    # Render each entry. Use jq to format consistently; pipe to read line by
    # line for ordering and section breaks.
    _kb_jq_read "$_cr_board" '
        .crs[($cidx | tonumber)].revert_history // []
        | to_entries
        | .[]
        | "── #\(.key + 1) ─────────────────────────────────────────────\n"
          + "  ts:        \(.value.ts)\n"
          + "  actor:     \(.value.actor)\n"
          + "  operation: \(.value.operation)\n"
          + "  from:      \(.value.from_state)\n"
          + "  to:        \(.value.to_state)\n"
          + "  reason:    \(.value.reason // "(none)")\n"
          + "  stripped:  \((.value.stripped_states // []) | join(", "))"
          + (if ((.value.stripped_fields // {}) | length) > 0 then
                "\n  preserved field snapshot (audit trail):\n"
                + ((.value.stripped_fields // {})
                    | to_entries
                    | map("    [\(.key)]\n"
                          + (.value | to_entries | map("      \(.key) = \(.value | tostring)") | join("\n")))
                    | join("\n"))
            else "" end)
    ' --arg cidx "$cr_idx" -r 2>/dev/null

    echo ""
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# _kb_cr_dispatch_item_lifecycle — DD2 routing helper
#
# When the user runs a lifecycle verb against an item-id, check whether the item
# has a crAssignment.crId back-pointer to a v2 container.  If so, route the
# call to the container variant so that ALL siblings in the CR are advanced
# atomically.  Falls through to the v1 per-item helper when:
#   - CR support is disabled
#   - The item cannot be found on the board
#   - The item has no crAssignment.crId
#   - The crAssignment.crId no longer matches any container (orphaned pointer)
#
# Usage:
#   _kb_cr_dispatch_item_lifecycle <verb> <gerund> <container_fn> <v1_fn> "$@"
#
#   verb         — the subcommand name (submit, approve, …) — used in messages
#   gerund       — present-participle form for the diagnostic line (submitting,
#                  approving, …) — printed to stderr before routing
#   container_fn — name of the _kb_cr_container_* function to call
#   v1_fn        — name of the _kb_cr_<verb> fallback function
#   "$@"         — original positional args: item-id [extra flags…]
#
# Notes:
#   - Container variant is invoked as: $container_fn <cr_id> [extra flags…]
#     (the original item-id is dropped; extra flags like --by are preserved)
#   - v1 variant is invoked unchanged: $v1_fn "$@"
#   - Diagnostic line goes to stderr (Risk #3 mitigation from plan)
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_dispatch_item_lifecycle() {
    local verb="$1"
    local gerund="$2"
    local container_fn="$3"
    local v1_fn="$4"
    shift 4

    local item_id="${1:-}"

    # ── Step 1: resolve board ─────────────────────────────────────────────────
    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1

    # If CR support is disabled, fall through to v1 (v1 has its own disabled check)
    if [[ "$_cr_enabled" != "true" ]]; then
        "$v1_fn" "$@"
        return $?
    fi

    # ── Step 2: resolve item index ────────────────────────────────────────────
    local item_idx
    item_idx=$(_kb_cr_find_item "$_cr_board" "$item_id")
    if [[ "$item_idx" == "-1" ]]; then
        # Item not found — fall through to v1 to produce the standard error message
        "$v1_fn" "$@"
        return $?
    fi

    # ── Step 3: read crAssignment.crId back-pointer ───────────────────────────
    local cr_id
    cr_id=$(_kb_jq_read "$_cr_board" \
        ".backlog[$item_idx].crAssignment.crId // \"\"" -r 2>/dev/null)

    if [[ -z "$cr_id" ]]; then
        # No crAssignment — true legacy single-item CR; fall through to v1
        "$v1_fn" "$@"
        return $?
    fi

    # ── Step 4: verify container exists (guard against orphaned back-pointer) ──
    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr: WARNING: item '$item_id' has crAssignment.crId='$cr_id' but no matching container found." >&2
        echo "  Falling back to v1 per-item path. Consider re-attaching via 'kb-cr attach'." >&2
        "$v1_fn" "$@"
        return $?
    fi

    # ── Step 5: read sibling count and print Risk-#3 confirmation ─────────────
    local n_items
    n_items=$(_kb_jq_read "$_cr_board" \
        ".crs[$cr_idx].itemIds | length" -r 2>/dev/null)
    n_items="${n_items:-0}"

    echo "kb-cr: routing to $cr_id — $gerund $n_items items in this CR." >&2

    # ── Step 6: invoke container variant (drop item-id, preserve extra flags) ──
    shift  # remove item_id; remaining args are extra flags (--by, --name, etc.)
    "$container_fn" "$cr_id" "$@"
    return $?
}

# ─────────────────────────────────────────────────────────────────────────────
# _kb_cr_dispatch_item_revert — revert/undo dispatcher (XACA-0329)
#
# revert/undo are CONTAINER-ONLY operations — there is no v1 per-item fallback
# because revert mutates timestamps owned by the .crs[i] record. When called
# with an item-id, route to the container via crAssignment.crId; if the item
# has no crAssignment, error out with guidance.
#
# Usage:
#   _kb_cr_dispatch_item_revert <verb> <gerund> "$@"
#     verb   ∈ {revert, undo, revert-history}
#     gerund — gerund used in the routing diagnostic line
#     "$@"   — original positional args: item-id [extra flags…]
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_dispatch_item_revert() {
    local verb="$1"
    local gerund="$2"
    shift 2

    local item_id="${1:-}"
    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-cr $verb <CR-ID|item-id> [flags…]" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    if [[ "$_cr_enabled" != "true" ]]; then
        _kb_cr_disabled_exit "$_cr_team"
        return 0
    fi

    local item_idx
    item_idx=$(_kb_cr_find_item "$_cr_board" "$item_id")
    if [[ "$item_idx" == "-1" ]]; then
        echo "kb-cr $verb: item '$item_id' not found in team '$_cr_team' backlog." >&2
        return 1
    fi

    local cr_id
    cr_id=$(_kb_jq_read "$_cr_board" \
        ".backlog[$item_idx].crAssignment.crId // \"\"" -r 2>/dev/null)
    if [[ -z "$cr_id" ]]; then
        echo "kb-cr $verb: item '$item_id' has no crAssignment — no container CR to $verb." >&2
        echo "  $verb is a container-level operation. v1 single-item CRs are not supported." >&2
        return 1
    fi

    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr $verb: item '$item_id' has crAssignment.crId='$cr_id' but no matching container found." >&2
        echo "  Refusing to $verb on an orphaned back-pointer. Re-attach via 'kb-cr attach' first." >&2
        return 1
    fi

    local n_items
    n_items=$(_kb_jq_read "$_cr_board" ".crs[$cr_idx].itemIds | length" -r 2>/dev/null)
    n_items="${n_items:-0}"
    echo "kb-cr: routing to $cr_id — $gerund $n_items items in this CR." >&2

    shift  # drop item_id; remaining args (--to, --reason, etc.) preserved
    case "$verb" in
        revert)          _kb_cr_container_revert "$cr_id" --operation revert "$@" ;;
        undo)            _kb_cr_container_revert "$cr_id" --operation undo "$@" ;;
        revert-history)  _kb_cr_container_revert_history "$cr_id" "$@" ;;
        *)
            echo "kb-cr: ERROR: _kb_cr_dispatch_item_revert — unknown verb '$verb'" >&2
            return 1
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# kb-cr — main dispatcher
# ─────────────────────────────────────────────────────────────────────────────

kb-cr() {
    _kb_ensure_jq || return 1

    local subcmd="${1:-help}"
    shift 2>/dev/null

    case "$subcmd" in
        # ── CR Container (v2.0 schema) ────────────────────────────────────────
        create)      _kb_cr_container_create "$@" ;;
        add-item)    _kb_cr_container_add_item "$@" ;;
        remove-item) _kb_cr_container_remove_item "$@" ;;
        list|ls)     _kb_cr_container_list "$@" ;;
        transition)  _kb_cr_container_transition "$@" ;;
        close)       _kb_cr_container_close "$@" ;;
        set-doc-link) _kb_cr_container_set_doc_link "$@" ;;
        reschedule)  _kb_cr_container_reschedule "$@" ;;
        migrate-legacy) _kb_cr_migrate_legacy "$@" ;;
        show)        _kb_cr_show_dispatch "$@" ;;
        # ── Lifecycle: route by ID prefix — CR-* → container, else → per-item ─
        # Container lifecycle (v2.0): argument starts with "CR-"
        # Per-item lifecycle (v1 / legacy): argument starts with item ID (e.g., XACA-…)
        #
        # The *) arm uses _kb_cr_dispatch_item_lifecycle (DD2): if the item has a
        # crAssignment.crId, the call is transparently rewritten to the container
        # variant so all siblings advance atomically.  Items without crAssignment
        # fall back to the v1 per-item helper unchanged.
        submit)
            case "${1:-}" in
                CR-*) _kb_cr_container_submit "$@" ;;
                *)    _kb_cr_dispatch_item_lifecycle \
                          submit submitting \
                          _kb_cr_container_submit _kb_cr_submit "$@" ;;
            esac ;;
        approve)
            case "${1:-}" in
                CR-*) _kb_cr_container_approve "$@" ;;
                *)    _kb_cr_dispatch_item_lifecycle \
                          approve approving \
                          _kb_cr_container_approve _kb_cr_approve "$@" ;;
            esac ;;
        reject)
            case "${1:-}" in
                CR-*) _kb_cr_container_reject "$@" ;;
                *)    _kb_cr_dispatch_item_lifecycle \
                          reject rejecting \
                          _kb_cr_container_reject _kb_cr_reject "$@" ;;
            esac ;;
        hold)
            case "${1:-}" in
                CR-*) _kb_cr_container_hold "$@" ;;
                *)    _kb_cr_dispatch_item_lifecycle \
                          hold holding \
                          _kb_cr_container_hold _kb_cr_hold "$@" ;;
            esac ;;
        deploy-dev)
            case "${1:-}" in
                CR-*) _kb_cr_container_deploy_dev "$@" ;;
                *)    _kb_cr_dispatch_item_lifecycle \
                          deploy-dev "deploying dev for" \
                          _kb_cr_container_deploy_dev _kb_cr_deploy_dev "$@" ;;
            esac ;;
        deploy-prod)
            case "${1:-}" in
                CR-*) _kb_cr_container_deploy_prod "$@" ;;
                *)    _kb_cr_dispatch_item_lifecycle \
                          deploy-prod "deploying prod for" \
                          _kb_cr_container_deploy_prod _kb_cr_deploy_prod "$@" ;;
            esac ;;
        # ── Emergency deploy (container only — no v1 equivalent with this name) ─
        emergency-deploy) _kb_cr_container_emergency_deploy "$@" ;;
        # ── Per-item only lifecycle (v1) ──────────────────────────────────────
        draft)       _kb_cr_draft "$@" ;;
        publish)     _kb_cr_publish "$@" ;;
        _set_confluence_url) _kb_cr_set_confluence_url "$@" ;;
        _set_publish_stamps) _kb_cr_set_publish_stamps "$@" ;;
        _get_publish_stamps) _kb_cr_get_publish_stamps "$@" ;;
        attach)      _kb_cr_attach "$@" ;;
        detach)      _kb_cr_detach "$@" ;;
        start-dev)
            case "${1:-}" in
                CR-*) _kb_cr_container_start_dev "$@" ;;
                *)    _kb_cr_dispatch_item_lifecycle \
                          start-dev "starting dev for" \
                          _kb_cr_container_start_dev _kb_cr_start_dev "$@" ;;
            esac ;;
        start-test)
            case "${1:-}" in
                CR-*) _kb_cr_container_start_test "$@" ;;
                *)    _kb_cr_dispatch_item_lifecycle \
                          start-test "starting test for" \
                          _kb_cr_container_start_test _kb_cr_start_test "$@" ;;
            esac ;;
        emergency)   _kb_cr_emergency "$@" ;;
        # complete has no container variant — routes to v1 only; propagation is
        # a no-op until _kb_cr_container_complete is implemented (XACA-0327-003).
        complete)    _kb_cr_complete "$@" ;;
        # ── Revert / Undo / Revert-History (XACA-0329) ────────────────────────
        # Container-only — no v1 fallback. CR-* prefix → direct container call;
        # item-id prefix → routed via crAssignment.crId.
        revert)
            case "${1:-}" in
                CR-*) _kb_cr_container_revert "$@" ;;
                *)    _kb_cr_dispatch_item_revert revert reverting "$@" ;;
            esac ;;
        undo)
            # Reject --to on undo (undo is exactly one step; --to belongs on revert)
            local _ud_arg=""
            for _ud_arg in "$@"; do
                if [[ "$_ud_arg" == "--to" || "$_ud_arg" == --to=* ]]; then
                    echo "kb-cr undo: --to is not valid on undo. Use 'kb-cr revert <ID> --to <state>' for explicit targets." >&2
                    return 1
                fi
            done
            case "${1:-}" in
                CR-*) _kb_cr_container_revert "$1" --operation undo "${@:2}" ;;
                *)    _kb_cr_dispatch_item_revert undo "undoing one step of" "$@" ;;
            esac ;;
        revert-history)
            case "${1:-}" in
                CR-*) _kb_cr_container_revert_history "$@" ;;
                *)    _kb_cr_dispatch_item_revert revert-history "showing revert history of" "$@" ;;
            esac ;;
        backfill)    _kb_cr_backfill "$@" ;;
        # ── CR ↔ Release bidirectional link (XACA-0657) ───────────────────────
        assign-release)   _kb_cr_container_assign_release "$@" ;;
        unassign-release) _kb_cr_container_unassign_release "$@" ;;
        # ── Activity log (XACA-0328-002) ──────────────────────────────────────
        activity)
            local activity_sub="${1:-}"
            shift 2>/dev/null
            case "$activity_sub" in
                record) _kb_cr_activity_record "$@" ;;
                list)   _kb_cr_activity_list "$@" ;;
                *)
                    echo "kb-cr activity: unknown subcommand '${activity_sub}'. Use: record | list" >&2
                    return 1
                    ;;
            esac ;;
        audit)       _kb_cr_audit "$@" ;;
        summary)     _kb_cr_summary_main "$@" ;;
        help|--help|-h) _kb_cr_help ;;
        *)
            echo "kb-cr: unknown subcommand '$subcmd'. Run 'kb-cr help' for usage." >&2
            return 1
            ;;
    esac
}

# Route show to container show (CR-ID) or legacy item show (item-ID).
# CR-IDs start with "CR-"; item-IDs start with "X".
_kb_cr_show_dispatch() {
    local arg="${1:-}"
    case "$arg" in
        CR-*) _kb_cr_container_show "$@" ;;
        "")
            echo "Usage: kb-cr show <CR-ID|item-id>" >&2
            return 1
            ;;
        *) _kb_cr_show "$@" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Container helpers — shared preamble (no item-id required)
# ─────────────────────────────────────────────────────────────────────────────

# Shared board preamble for container commands (no item resolution).
# Sets caller-scoped: _cr_team, _cr_board, _cr_enabled
# Returns 1 on hard failure; returns 0 with _cr_enabled="false" when disabled.
_kb_cr_board_preamble() {
    local context
    context=$(_kb_detect_context 2>/dev/null)
    if [[ -z "$context" ]]; then
        echo "kb-cr: ERROR: cannot detect kanban context. Is tmux running?" >&2
        return 1
    fi

    _cr_team="${context%%:*}"
    _cr_board=$(_kb_get_board_file "$_cr_team")

    if [[ ! -f "$_cr_board" ]]; then
        echo "kb-cr: ERROR: no board found for team '$_cr_team'" >&2
        return 1
    fi

    _cr_enabled=$(_kb_cr_is_enabled "$_cr_board")
    return 0
}

# Ensure the crs[] array and nextCrSeq counter exist on the board.
_kb_cr_ensure_container_support() {
    local board_file="$1"
    local ts
    ts=$(_kb_cr_timestamp)

    _kb_jq_update "$board_file" '
        if has("crs") then .
        else . + {"crs": [], "nextCrSeq": 1}
        end |
        .lastUpdated = $ts
    ' --arg ts "$ts"
}

# Generate a CR container ID: CR-<TEAM_UPPER>-<YYYYMMDD>-<seq padded to 4 digits>
_kb_cr_generate_id() {
    local board_file="$1"
    local team="$2"

    local date_part seq_part team_upper
    date_part=$(date -u +%Y%m%d)
    seq_part=$(_kb_jq_read "$board_file" '.nextCrSeq // 1' -r 2>/dev/null)
    team_upper="${team:u}"

    printf "CR-%s-%s-%04d" "$team_upper" "$date_part" "$seq_part"
}

# Increment nextCrSeq on the board.
_kb_cr_increment_seq() {
    local board_file="$1"
    local ts
    ts=$(_kb_cr_timestamp)

    _kb_jq_update "$board_file" \
        '.nextCrSeq = ((.nextCrSeq // 1) + 1) | .lastUpdated = $ts' \
        --arg ts "$ts"
}

# Resolve a CR-ID to its index in .crs[].
# Echoes the numeric index or "-1" if not found.
_kb_cr_find_container() {
    local board_file="$1"
    local cr_id="$2"

    _kb_jq_read "$board_file" \
        '(.crs // [] | to_entries[] | select(.value.id == $id) | .key) // -1' \
        --arg id "$cr_id" -r 2>/dev/null || echo "-1"
}

# ─────────────────────────────────────────────────────────────────────────────
# CR ↔ Release bidirectional link subcommands (XACA-0657)
#
# FIELD CONTRACT on .crs[] records (readers must default cleanly when absent):
#
#   CR record gets:
#     "releaseAssignment": {
#       "releaseId":   "<REL-ID>",          -- release this CR is assigned to
#       "releaseName": "<snapshot>",         -- name snapshot at link time
#       "assignedAt":  "<ISO8601>"           -- link timestamp
#     }
#   ABSENT (never null) when unlinked. A CR links to AT MOST ONE release.
#
# SHARED WRITE LOGIC lives in kanban-helpers.sh:
#   _kb_cr_release_link <board> <team> <cr_id> <rel_id>  — writes all 3 sites
#   _kb_cr_release_unlink <board> <team> <cr_id>          — clears all 3 sites
# These functions are defined BEFORE kb-cr.sh is sourced, so they are always
# available here. The kb-release link-cr / unlink-cr entry points in
# kanban-helpers.sh are thin wrappers over the same functions — no parallel copy.
#
# MIGRATION NOTE: absence of releaseAssignment on any existing CR record simply
# means "unlinked" — no migration script needed. Readers must use
#   .crs[$i].releaseAssignment // null | select(. != null)
# or equivalent (//-null guards) when reading this field.
# ─────────────────────────────────────────────────────────────────────────────

# kb-cr assign-release <CR-ID> <REL-ID>
# Link a CR container to a release. Snapshots titles. Writes all three sites:
#   CR.releaseAssignment, release.linkedCRs[], manifest crIds[].
# If the CR is already linked to a different release, unlinks it first.
_kb_cr_container_assign_release() {
    local cr_id="${1-}"
    local rel_id="${2-}"

    if [[ -z "$cr_id" || -z "$rel_id" ]]; then
        echo "Usage: kb-cr assign-release <CR-ID> <REL-ID>" >&2
        echo "  CR-ID:  CR container ID (e.g., CR-TEAM-20260601-0001)" >&2
        echo "  REL-ID: Release ID (e.g., REL-IOS-2026-Q2-001)" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    # Delegate to the shared write function in kanban-helpers.sh.
    # _kb_cr_release_link validates CR and release existence, handles re-link.
    _kb_cr_release_link "$_cr_board" "$_cr_team" "$cr_id" "$rel_id"
}

# kb-cr unassign-release <CR-ID>
# Remove the release link from a CR container. Clears all three sites.
_kb_cr_container_unassign_release() {
    local cr_id="${1-}"

    if [[ -z "$cr_id" ]]; then
        echo "Usage: kb-cr unassign-release <CR-ID>" >&2
        echo "  CR-ID: CR container ID (e.g., CR-TEAM-20260601-0001)" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    # Delegate to the shared write function in kanban-helpers.sh.
    _kb_cr_release_unlink "$_cr_board" "$_cr_team" "$cr_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Container subcommand: create
# Usage: kb-cr create <title> [--type major|emergency|fyi]
#                              [--platform ios|android|firebase|crossplatform]
#                              [--summary "text"]
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_container_create() {
    local title=""
    local cr_type="major"
    local platform=""
    local summary=""
    local deploy_window=""

    # Parse args — positional title first, then flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type)     cr_type="${2:-}";   shift 2 ;;
            --type=*)   cr_type="${1#--type=}"; shift ;;
            --platform) platform="${2:-}";  shift 2 ;;
            --platform=*) platform="${1#--platform=}"; shift ;;
            --summary)  summary="${2:-}";   shift 2 ;;
            --summary=*) summary="${1#--summary=}"; shift ;;
            --deploy-window) deploy_window="${2:-}"; shift 2 ;;
            --deploy-window=*) deploy_window="${1#--deploy-window=}"; shift ;;
            --help|-h)
                echo "Usage: kb-cr create <title> [--type major|emergency|fyi]"
                echo "                             [--platform ios|android|firebase|crossplatform]"
                echo "                             [--summary \"text\"]"
                echo "                             [--deploy-window <YYYY-MM-DD|YYYY-MM-DDTHH:MM:SSZ>]"
                return 0
                ;;
            *)
                if [[ -z "$title" ]]; then
                    title="$1"
                else
                    echo "kb-cr create: unexpected argument: $1" >&2
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$title" ]]; then
        echo "kb-cr create: <title> is required" >&2
        echo "Usage: kb-cr create <title> [--type major|emergency|fyi]" >&2
        return 1
    fi

    case "$cr_type" in
        major|emergency|fyi) ;;
        *)
            echo "kb-cr create: invalid type '$cr_type'. Must be: major | emergency | fyi" >&2
            return 1
            ;;
    esac

    if [[ -n "$platform" ]]; then
        case "$platform" in
            ios|android|firebase|crossplatform) ;;
            *)
                echo "kb-cr create: invalid platform '$platform'. Must be: ios | android | firebase | crossplatform" >&2
                return 1
                ;;
        esac
    fi

    # Validate and normalize deploy_window before touching the board
    local deploy_window_normalized=""
    if [[ -n "$deploy_window" ]]; then
        deploy_window_normalized=$(_kb_cr_normalize_iso_date "$deploy_window") || return 1
    fi

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    _kb_cr_ensure_container_support "$_cr_board"

    local cr_id ts
    cr_id=$(_kb_cr_generate_id "$_cr_board" "$_cr_team")
    ts=$(_kb_cr_timestamp)

    # Build the new CR record as a jq object, then conditionally add optional fields.
    # All optional fields are passed as args; jq decides whether to include them
    # based on whether they are empty strings.
    _kb_jq_update "$_cr_board" '
        (.crs // []) as $existing |
        ($existing + [{
            "id":           $id,
            "title":        $title,
            "type":         $crtype,
            "crState":      "cr-drafted",
            "itemIds":      [],
            "pushback_count": 0,
            "createdAt":    $ts,
            "updatedAt":    $ts,
            "timestamps":   {}
        }]) as $new_crs |
        .crs = (
            $new_crs |
            if $platform != "" then (last | .platform = $platform) as $rec |
                (.[:-1] + [$rec])
            else . end
        ) |
        if $summary != "" then (.crs[-1].summary = $summary) else . end |
        if $deploywin != "" then (.crs[-1].deploy_window_planned = $deploywin) else . end |
        .lastUpdated = $ts
    ' \
    --arg id        "$cr_id" \
    --arg title     "$title" \
    --arg crtype    "$cr_type" \
    --arg ts        "$ts" \
    --arg platform  "$platform" \
    --arg summary   "$summary" \
    --arg deploywin "$deploy_window_normalized" \
    || return 1

    # Append activity log entries (best-effort — never block the create path)
    local _create_event
    _create_event=$(_kb_cr_activity_event "cr_created" \
        "to_state=cr-drafted" \
        "note=CR container created via kb-cr create${platform:+; platform=${platform}}${cr_type:+; type=${cr_type}}") || true
    if [[ -n "$_create_event" ]]; then
        _kb_cr_activity_append "$_cr_board" "$cr_id" "$_create_event" 2>/dev/null || true
    fi

    # Emit deploy-window event when set at create time (003)
    if [[ -n "$deploy_window_normalized" ]]; then
        local _win_event
        _win_event=$(_kb_cr_activity_event "cr_deploy_window_set" \
            "field=deploy_window_planned" \
            "new_value=${deploy_window_normalized}" \
            "note=deploy_window_planned set at create time via --deploy-window") || true
        if [[ -n "$_win_event" ]]; then
            _kb_cr_activity_append "$_cr_board" "$cr_id" "$_win_event" 2>/dev/null || true
        fi
    fi

    _kb_cr_increment_seq "$_cr_board"

    # Doc creation is deferred to first kb-cr add-item — the LCARS UI resolves
    # CR docs by <item-id>-CR.md filename, so creating the doc here (keyed on
    # cr_id) would produce an orphan file invisible to the UI. The doc
    # materializes in _kb_cr_container_add_item when the first item is linked.

    echo "Created CR [$cr_id]: $title"
    echo "  Type:  $cr_type"
    echo "  State: cr-drafted"
    [[ -n "$platform" ]] && echo "  Platform: $platform"
    [[ -n "$summary" ]] && echo "  Summary: ${summary:0:80}"
    [[ -n "$deploy_window_normalized" ]] && echo "  Deploy Window: $deploy_window_normalized"
    echo ""
    echo "  Next steps:"
    echo "    kb-cr add-item $cr_id <item-id>"
    echo "    kb-cr list"
    echo "  Local CR markdown will be created on first kb-cr add-item."
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal helper: create the local CR markdown file from the shipped
# template at <AITEAMFORGE_DIR>/templates/kanban/cr-doc-template.md.
#
# PHASE 3 (XACA-0308-002):
#   Canonical path: <team-kanban>/cr-docs/<ITEM-ID>-CR.md
#   The ITEM-ID argument is the primary backlog item ID that "owns" this CR
#   (resolved by the caller — _kb_cr_draft passes the item being drafted;
#   _kb_cr_container_create passes its own cr_id as a fallback when there are
#   no items yet).
#
#   Template placeholders substituted:
#     {{ITEM_ID}}       primary item ID
#     {{CR_ID}}         CR container ID (e.g., CR-ACADEMY-20260506-0001)
#     {{CR_TYPE}}       uppercased cr_type (MAJOR / EMERGENCY / FYI)
#     {{DRAFT_DATE}}    today's date UTC (YYYY-MM-DD)
#     {{TEAM}}          team slug
#     {{CR_STATE}}      "CR DRAFTED"
#     {{TITLE}}         item/CR title
#     {{SUMMARY}}       summary or placeholder
#     {{DEPLOY_WINDOW}} "TBD"
#     {{ITEM_LIST}}     "- <ITEM-ID>"
#     {{CONFLUENCE_URL}} "(not yet published)"
#
#   Idempotent: if the file already exists, emit a note and return 0 with
#   the existing path — never overwrite.
#   Does NOT write cr_doc_link to the board. cr_confluence_url is written
#   only by kb-cr publish (XACA-0308-002) after a successful Confluence push.
#
# Returns 0 on success or skip; non-zero only if the file write itself fails.
# ─────────────────────────────────────────────────────────────────────────────
_kb_cr_create_doc_file() {
    local board="$1"
    local cr_id="$2"
    local title="$3"
    local cr_type="$4"
    # $5 (platform) is accepted for backward-compat with _kb_cr_container_create
    # callers but is not used in the Phase 3 template substitution.
    local summary="$6"
    # $7 is the primary item ID (optional; falls back to cr_id when absent)
    local item_id="${7:-$cr_id}"

    local board_dir cr_docs_dir team
    board_dir=$(dirname "$board")
    cr_docs_dir="${board_dir}/cr-docs"
    mkdir -p "$cr_docs_dir" 2>/dev/null || return 1

    # ── Template resolution (worktree-agnostic; derives current repo via git
    #    so any active worktree finds the Phase 3 template; falls back to
    #    main-repo and tap paths in order) ─────────────────────────────────────
    local template=""
    # Current git tree root (works for main repo OR any active worktree)
    local _git_root=""
    _git_root=$(git rev-parse --show-toplevel 2>/dev/null)
    if [[ -n "$_git_root" && -f "${_git_root}/templates/cr-doc-template.md" ]]; then
        template="${_git_root}/templates/cr-doc-template.md"
    # Main-repo tracked path (after PR merge, has the Phase 3 version)
    elif [[ -f "${HOME}/dev-team/templates/cr-doc-template.md" ]]; then
        template="${HOME}/dev-team/templates/cr-doc-template.md"
    # AITEAMFORGE_DIR (installed tap or dev-team root)
    elif [[ -n "${AITEAMFORGE_DIR:-}" && -f "${AITEAMFORGE_DIR}/templates/cr-doc-template.md" ]]; then
        template="${AITEAMFORGE_DIR}/templates/cr-doc-template.md"
    elif [[ -n "${AITEAMFORGE_DIR:-}" && -f "${AITEAMFORGE_DIR}/templates/kanban/cr-doc-template.md" ]]; then
        template="${AITEAMFORGE_DIR}/templates/kanban/cr-doc-template.md"
    # Homebrew-tap submodule fallback
    elif [[ -f "${HOME}/dev-team/homebrew-tap/share/templates/kanban/cr-doc-template.md" ]]; then
        template="${HOME}/dev-team/homebrew-tap/share/templates/kanban/cr-doc-template.md"
    else
        echo "kb-cr: WARNING: cr-doc-template.md not found; skipping local md creation" >&2
        return 0
    fi

    # ── Derive team slug from board path for the {{TEAM}} placeholder ─────────
    # Board path is typically <team-kanban-dir>/<team>-board.json; extract slug
    # from the filename (e.g., "academy" from "academy-board.json").
    local board_basename
    board_basename=$(basename "$board")
    team="${board_basename%-board.json}"
    [[ -z "$team" ]] && team="unknown"

    local draft_date
    draft_date=$(date -u +%Y-%m-%d)

    # ── Canonical Phase 3 output path: cr-docs/<ITEM-ID>-CR.md ───────────────
    local out="${cr_docs_dir}/${item_id}-CR.md"
    if [[ -e "$out" ]]; then
        echo "kb-cr: NOTE: CR doc already exists at cr-docs/${item_id}-CR.md — leaving untouched" >&2
        printf '%s\n' "$out"
        return 0
    fi

    # ── Substitute Phase 3 template placeholders via awk ─────────────────────
    # Use awk variable injection (not shell expansion) to safely handle special
    # characters in title/summary without breaking awk's gsub patterns.
    awk -v ITEM_ID="$item_id" \
        -v CR_ID="$cr_id" \
        -v CR_TYPE="$(printf '%s' "${cr_type:-major}" | tr '[:lower:]' '[:upper:]')" \
        -v DRAFT_DATE="$draft_date" \
        -v TEAM="$team" \
        -v CR_STATE="CR DRAFTED" \
        -v TITLE="${title:-$item_id}" \
        -v SUMMARY="${summary:-(add a description)}" \
        -v DEPLOY_WINDOW="TBD" \
        -v ITEM_LIST="- ${item_id}" \
        -v CONFLUENCE_URL="(not yet published)" \
        '{
            gsub(/\{\{ITEM_ID\}\}/,       ITEM_ID);
            gsub(/\{\{CR_ID\}\}/,         CR_ID);
            gsub(/\{\{CR_TYPE\}\}/,       CR_TYPE);
            gsub(/\{\{DRAFT_DATE\}\}/,    DRAFT_DATE);
            gsub(/\{\{TEAM\}\}/,          TEAM);
            gsub(/\{\{CR_STATE\}\}/,      CR_STATE);
            gsub(/\{\{TITLE\}\}/,         TITLE);
            gsub(/\{\{SUMMARY\}\}/,       SUMMARY);
            gsub(/\{\{DEPLOY_WINDOW\}\}/, DEPLOY_WINDOW);
            gsub(/\{\{ITEM_LIST\}\}/,     ITEM_LIST);
            gsub(/\{\{CONFLUENCE_URL\}\}/,CONFLUENCE_URL);
            print
        }' "$template" > "$out" || return 1

    echo "  Doc:   cr-docs/${item_id}-CR.md"
    printf '%s\n' "$out"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Container subcommand: add-item
# Usage: kb-cr add-item <CR-ID> <ITEM-ID>
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_container_add_item() {
    local cr_id="${1:-}"
    local item_id="${2:-}"

    if [[ -z "$cr_id" || -z "$item_id" ]]; then
        echo "Usage: kb-cr add-item <CR-ID> <item-id>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    # Resolve CR container
    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr add-item: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    # Resolve backlog item
    local item_idx
    item_idx=$(_kb_cr_find_item "$_cr_board" "$item_id")
    if [[ "$item_idx" == "-1" ]]; then
        echo "kb-cr add-item: item '$item_id' not found in team '$_cr_team' backlog." >&2
        return 1
    fi

    # Refuse if item already has a crAssignment to a DIFFERENT CR
    local existing_cr_id
    existing_cr_id=$(_kb_jq_read "$_cr_board" \
        ".backlog[$item_idx].crAssignment.crId // \"\"" -r 2>/dev/null)

    if [[ -n "$existing_cr_id" && "$existing_cr_id" != "$cr_id" ]]; then
        echo "kb-cr add-item: item '$item_id' is already assigned to CR '$existing_cr_id'." >&2
        echo "  Remove it first with: kb-cr remove-item $existing_cr_id $item_id" >&2
        return 1
    fi

    local ts cr_title cr_type _pre_count
    ts=$(_kb_cr_timestamp)
    cr_title=$(_kb_jq_read "$_cr_board" ".crs[$cr_idx].title" -r 2>/dev/null)
    cr_type=$(_kb_jq_read "$_cr_board" ".crs[$cr_idx].type // \"major\"" -r 2>/dev/null)

    # Capture itemIds length BEFORE the update so we know when this is the first item.
    _pre_count=$(_kb_jq_read "$_cr_board" ".crs[$cr_idx].itemIds | length" -r 2>/dev/null)

    # Append item to CR's itemIds (de-dupe) and write crAssignment back-pointer on item.
    # crTitle is a snapshot at assign-time — updates to the CR title do not propagate.
    # Use kb-cr show for the canonical title.
    _kb_jq_update "$_cr_board" '
        .crs[$cidx].itemIds += [$itemId] |
        .crs[$cidx].itemIds |= unique |
        .crs[$cidx].updatedAt = $ts |
        .backlog[$iidx].crAssignment = {
            "crId":       $crId,
            "crTitle":    $crTitle,
            "assignedAt": $ts
        } |
        .lastUpdated = $ts
    ' \
    --argjson cidx  "$cr_idx" \
    --argjson iidx  "$item_idx" \
    --arg     itemId  "$item_id" \
    --arg     crId    "$cr_id" \
    --arg     crTitle "$cr_title" \
    --arg     ts      "$ts" \
    || return 1

    # Materialize the CR doc on the FIRST item linked — keyed on item_id so the
    # LCARS UI can resolve it via /api/kanban/<item-id>/cr-content.
    # Idempotent: _kb_cr_create_doc_file returns 0 with a note if file exists.
    # _KB_CR_SKIP_DOC_FILE=1: suppressed when called from _kb_cr_draft, which
    # retains exclusive control of doc creation (with proper summary metadata).
    if [[ "${_pre_count:-0}" -eq 0 && "${_KB_CR_SKIP_DOC_FILE:-}" != "1" ]]; then
        _kb_cr_create_doc_file "$_cr_board" "$cr_id" "$cr_title" "$cr_type" "" "" "$item_id" || true
    fi

    echo "Added item [$item_id] to CR [$cr_id]"
}

# ─────────────────────────────────────────────────────────────────────────────
# Container subcommand: remove-item
# Usage: kb-cr remove-item <CR-ID> <ITEM-ID>
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_container_remove_item() {
    local cr_id="${1:-}"
    local item_id="${2:-}"

    if [[ -z "$cr_id" || -z "$item_id" ]]; then
        echo "Usage: kb-cr remove-item <CR-ID> <item-id>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    # Resolve CR container
    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr remove-item: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    # Resolve backlog item
    local item_idx
    item_idx=$(_kb_cr_find_item "$_cr_board" "$item_id")
    if [[ "$item_idx" == "-1" ]]; then
        echo "kb-cr remove-item: item '$item_id' not found in team '$_cr_team' backlog." >&2
        return 1
    fi

    local ts
    ts=$(_kb_cr_timestamp)

    # Remove item from CR's itemIds and clear all CR linkage from the item.
    # Deletes both the v2 crAssignment object and the legacy v1 flat fields
    # (cr_id, cr_type, cr_created_at, crState) that the attach/draft path
    # writes for backward compat with LCARS v1 readers (XACA-0348).
    _kb_jq_update "$_cr_board" '
        .crs[$cidx].itemIds -= [$itemId] |
        .crs[$cidx].updatedAt = $ts |
        .backlog[$iidx] |= del(.crAssignment, .cr_id, .cr_type, .cr_created_at, .crState) |
        .lastUpdated = $ts
    ' \
    --argjson cidx   "$cr_idx" \
    --argjson iidx   "$item_idx" \
    --arg     itemId "$item_id" \
    --arg     ts     "$ts" \
    || return 1

    echo "Removed item [$item_id] from CR [$cr_id]"
}

# ─────────────────────────────────────────────────────────────────────────────
# Item-perspective alias: attach
# Usage: kb-cr attach <item-id> --to <CR-ID>
# Thin wrapper over _kb_cr_container_add_item.  All validation lives there.
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_attach() {
    local item_id=""
    local cr_id=""

    # First positional arg is the item-id; remainder are flags.
    if [[ -n "${1:-}" && "${1}" != --* ]]; then
        item_id="$1"
        shift
    fi

    # Parse --to <CR-ID> or --to=<CR-ID>
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to=*)  cr_id="${1#--to=}" ; shift ;;
            --to)    cr_id="${2:-}"     ; shift 2 ;;
            *)       shift ;;
        esac
    done

    if [[ -z "$item_id" || -z "$cr_id" ]]; then
        echo "Usage: kb-cr attach <item-id> --to <CR-ID>" >&2
        return 1
    fi

    _kb_cr_container_add_item "$cr_id" "$item_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Item-perspective alias: detach
# Usage: kb-cr detach <item-id>
# Resolves the item's current crAssignment.crId, then delegates to
# _kb_cr_container_remove_item.  All write logic lives there.
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_detach() {
    local item_id="${1:-}"

    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-cr detach <item-id>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    # Resolve the item's index so we can read its crAssignment.crId.
    local item_idx
    item_idx=$(_kb_cr_find_item "$_cr_board" "$item_id")
    if [[ "$item_idx" == "-1" ]]; then
        echo "kb-cr detach: item '$item_id' not found in team '$_cr_team' backlog." >&2
        return 1
    fi

    local resolved_cr_id
    resolved_cr_id=$(_kb_jq_read "$_cr_board" \
        ".backlog[$item_idx].crAssignment.crId // \"\"" -r 2>/dev/null)

    if [[ -z "$resolved_cr_id" ]]; then
        echo "kb-cr detach: item '$item_id' has no crAssignment — nothing to detach." >&2
        return 1
    fi

    _kb_cr_container_remove_item "$resolved_cr_id" "$item_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Container subcommand: set-doc-link
# Usage: kb-cr set-doc-link <CR-ID> <url>
#
# DEPRECATED (XACA-0308): This subcommand writes cr_doc_link on the CR record.
# Phase 3 replaces cr_doc_link with cr_confluence_url. Use `kb-cr publish`
# (implemented in subitem 002) instead — it writes cr_confluence_url and is
# idempotent (re-publish updates the same Confluence page).
#
# This function is retained for backward compatibility until Phase 3 data
# migration (subitem 006) removes all cr_doc_link fields from board records.
# After migration, callers should switch to kb-cr publish.
#
# Previously: used by /main-event-cr after publishing the Confluence CR page.
# Phase 3 target: cr_confluence_url on crs[] records (set by kb-cr publish).
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_container_set_doc_link() {
    local cr_id="${1:-}"
    local doc_url="${2:-}"

    if [[ -z "$cr_id" || -z "$doc_url" ]]; then
        echo "Usage: kb-cr set-doc-link <CR-ID> <url>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr set-doc-link: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    local ts
    ts=$(_kb_cr_timestamp)

    _kb_jq_update "$_cr_board" '
        .crs[$cidx].cr_doc_link = $url |
        .crs[$cidx].updatedAt = $ts |
        .lastUpdated = $ts
    ' \
    --argjson cidx "$cr_idx" \
    --arg     url  "$doc_url" \
    --arg     ts   "$ts" \
    || return 1

    echo "Set doc link for CR [$cr_id]: $doc_url"
}

# ─────────────────────────────────────────────────────────────────────────────
# Subcommand: reschedule <CR-ID> <date>
#
# Post-hoc setter for deploy_window_planned. Valid at any crState.
# Normalizes the supplied date to ISO 8601 UTC via _kb_cr_normalize_iso_date.
# Accepts: YYYY-MM-DD | YYYY-MM-DDTHH:MM:SSZ | YYYY-MM-DDTHH:MMZ
# Emits a cr_deploy_window_set activity-log event (best-effort).
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_container_reschedule() {
    local cr_id="${1:-}"
    local date_input="${2:-}"

    if [[ -z "$cr_id" || -z "$date_input" ]]; then
        echo "Usage: kb-cr reschedule <CR-ID> <date>" >&2
        return 1
    fi

    # Validate/normalize the date BEFORE touching the board (matches create) so
    # a bad date fails fast with no board read.
    local normalized
    normalized=$(_kb_cr_normalize_iso_date "$date_input") || return 1

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr reschedule: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    local ts
    ts=$(_kb_cr_timestamp)

    _kb_jq_update "$_cr_board" '
        .crs[$cidx].deploy_window_planned = $win |
        .crs[$cidx].updatedAt = $ts |
        .lastUpdated = $ts
    ' \
    --argjson cidx "$cr_idx" \
    --arg     win  "$normalized" \
    --arg     ts   "$ts" \
    || return 1

    # Emit activity-log event (best-effort — never block the write) (003)
    local _win_event
    _win_event=$(_kb_cr_activity_event "cr_deploy_window_set" \
        "field=deploy_window_planned" \
        "new_value=${normalized}" \
        "note=deploy_window_planned updated post-hoc via kb-cr reschedule") || true
    if [[ -n "$_win_event" ]]; then
        _kb_cr_activity_append "$_cr_board" "$cr_id" "$_win_event" 2>/dev/null || true
    fi

    echo "Set deploy window for CR [$cr_id]: $normalized"
}

# ─────────────────────────────────────────────────────────────────────────────
# Subcommand: migrate-legacy <item-id> [--apply]
#
# Per-item shell wrapper around scripts/migrate-cr-schema.py. Lifts a single
# v1-shape backlog item (cr_id + cr_*_at fields on the item) into the v2
# container shape (a record under .crs[] + a crAssignment back-pointer on
# the item). Idempotent: no-op on already-v2 items.
#
# Defaults to dry-run; pass --apply to actually mutate the board.
# Returns the underlying Python exit code so programmatic callers can
# distinguish "item not found" (5) from "no CR data" (6) from generic failure.
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_migrate_legacy() {
    local item_id=""
    local apply_flag=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --apply|--dry-run) apply_flag="$1"; shift ;;
            -*) echo "kb-cr migrate-legacy: unknown flag '$1'" >&2; return 1 ;;
            *)
                if [[ -z "$item_id" ]]; then
                    item_id="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-cr migrate-legacy <item-id> [--apply]" >&2
        echo "       Dry-run by default; pass --apply to write changes." >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local migrate_script="${HOME}/dev-team/scripts/migrate-cr-schema.py"
    if [[ ! -f "$migrate_script" ]]; then
        echo "kb-cr migrate-legacy: ERROR: migration script not found: $migrate_script" >&2
        return 1
    fi

    local py_args=(--item "$item_id" --board "$_cr_board")
    [[ "$apply_flag" == "--apply" ]] && py_args+=(--apply)

    local output exit_code
    output=$(python3 "$migrate_script" "${py_args[@]}" 2>&1)
    exit_code=$?

    echo "$output"

    case $exit_code in
        0) return 0 ;;
        5) echo "kb-cr migrate-legacy: item '$item_id' not found on team '$_cr_team' board." >&2 ;;
        6) echo "kb-cr migrate-legacy: item '$item_id' has no CR data to migrate." >&2 ;;
    esac
    return $exit_code
}

# ─────────────────────────────────────────────────────────────────────────────
# Container subcommand: show
# Usage: kb-cr show <CR-ID>
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_container_show() {
    local cr_id="${1:-}"

    if [[ -z "$cr_id" ]]; then
        echo "Usage: kb-cr show <CR-ID>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr show: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    local cr_json
    cr_json=$(_kb_jq_read "$_cr_board" ".crs[$cr_idx]" 2>/dev/null)

    local title cr_type cr_state platform deploy_window cr_doc_link
    local approver_login approver_name pushback_count pushback_notes summary
    local emergency_justification created_at updated_at item_count

    title=$(printf '%s' "$cr_json" | jq -r '.title // ""')
    cr_type=$(printf '%s' "$cr_json" | jq -r '.type // ""')
    cr_state=$(printf '%s' "$cr_json" | jq -r '.crState // ""')
    platform=$(printf '%s' "$cr_json" | jq -r '.platform // ""')
    deploy_window=$(printf '%s' "$cr_json" | jq -r '.deploy_window_planned // ""')
    cr_doc_link=$(printf '%s' "$cr_json" | jq -r '.cr_doc_link // ""')
    approver_login=$(printf '%s' "$cr_json" | jq -r '.approver.login // ""')
    approver_name=$(printf '%s' "$cr_json" | jq -r '.approver.name // ""')
    pushback_count=$(printf '%s' "$cr_json" | jq -r '.pushback_count // 0')
    pushback_notes=$(printf '%s' "$cr_json" | jq -r '.pushback_notes // ""')
    summary=$(printf '%s' "$cr_json" | jq -r '.summary // ""')
    emergency_justification=$(printf '%s' "$cr_json" | jq -r '.emergency_justification // ""')
    created_at=$(printf '%s' "$cr_json" | jq -r '.createdAt // ""')
    updated_at=$(printf '%s' "$cr_json" | jq -r '.updatedAt // ""')
    item_count=$(printf '%s' "$cr_json" | jq -r '.itemIds | length')

    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    printf "║ CR: [%s] %s\n" "$cr_id" "$title"
    echo "╠═══════════════════════════════════════════════════════════╣"
    printf "║ Type:     %-18s State: %s\n" "$cr_type" "$cr_state"
    [[ -n "$platform" ]] && printf "║ Platform: %s\n" "$platform"
    [[ -n "$deploy_window" ]] && printf "║ Deploy Window: %s\n" "$deploy_window"
    [[ -n "$cr_doc_link" ]] && printf "║ Doc Link: %s\n" "$cr_doc_link"
    if [[ -n "$approver_name" ]]; then
        printf "║ Approver: %s (%s)\n" "$approver_name" "$approver_login"
    elif [[ -n "$approver_login" ]]; then
        printf "║ Approver: %s\n" "$approver_login"
    fi
    [[ "$pushback_count" -gt 0 ]] && printf "║ Pushbacks: %s\n" "$pushback_count"
    [[ -n "$summary" ]] && printf "║ Summary:  %s\n" "${summary:0:80}"
    [[ -n "$emergency_justification" ]] && printf "║ Emergency: %s\n" "${emergency_justification:0:80}"
    [[ -n "$pushback_notes" ]] && printf "║ Pushback Notes: %s\n" "${pushback_notes:0:80}"
    echo "╠═══════════════════════════════════════════════════════════╣"
    # ── Lifecycle progress arrow ─────────────────────────────────────────────
    # Canonical main-path phases (in display order). Off-path states handled below.
    local -a _lc_phases
    _lc_phases=(drafted submitted approved implementing "deployed-dev" "deployed-prod")
    local _lc_state_label
    case "$cr_state" in
        cr-drafted)         _lc_state_label="drafted"       ;;
        cr-submitted)       _lc_state_label="submitted"     ;;
        cr-approved)        _lc_state_label="approved"      ;;
        implementing)       _lc_state_label="implementing"  ;;
        deployed-dev)       _lc_state_label="deployed-dev"  ;;
        deployed-prod)      _lc_state_label="deployed-prod" ;;
        emergency-deployed) _lc_state_label="EMERGENCY"     ;;
        cr-rejected)        _lc_state_label="REJECTED"      ;;
        cr-held)            _lc_state_label="HELD"          ;;
        *)                  _lc_state_label="$cr_state"     ;;
    esac

    local _lc_arrow="" _lc_phase _lc_reached="false"
    for _lc_phase in "${_lc_phases[@]}"; do
        if [[ "$_lc_phase" == "$_lc_state_label" ]]; then
            [[ -n "$_lc_arrow" ]] && _lc_arrow+=" ->"
            _lc_arrow+=" ${_lc_phase} [CURRENT]"
            _lc_reached="true"
        elif [[ "$_lc_reached" == "false" ]]; then
            [[ -n "$_lc_arrow" ]] && _lc_arrow+=" ->"
            _lc_arrow+=" ${_lc_phase}"
        else
            _lc_arrow+=" -> (${_lc_phase})"
        fi
    done
    if [[ "$_lc_state_label" == "EMERGENCY" || "$_lc_state_label" == "REJECTED" || "$_lc_state_label" == "HELD" ]]; then
        _lc_arrow=" [off-path: ${_lc_state_label}]${_lc_arrow}"
    fi
    # Smart truncation: keep [CURRENT] visible. If marker fits in head window,
    # right-truncate; otherwise anchor slice to marker_start so [CURRENT] sits
    # at the front of the visible window. Sandwich-truncate when even the
    # marker+context can't fit in _LC_MAX-3 chars.
    local _LC_MAX=46
    if (( ${#_lc_arrow} > _LC_MAX )); then
        if [[ "$_lc_arrow" == *"[CURRENT]"* ]]; then
            local _before_marker="${_lc_arrow%%\[CURRENT\]*}"
            local _marker_start=${#_before_marker}
            local _marker_end=$(( _marker_start + 9 ))
            if (( _marker_end <= _LC_MAX )); then
                _lc_arrow="${_lc_arrow:0:$((_LC_MAX-3))}..."
            else
                local _tail_len=$(( ${#_lc_arrow} - _marker_start ))
                if (( _tail_len <= _LC_MAX - 3 )); then
                    _lc_arrow="...${_lc_arrow:$_marker_start}"
                else
                    _lc_arrow="...${_lc_arrow:$_marker_start:$((_LC_MAX-6))}..."
                fi
            fi
        else
            _lc_arrow="${_lc_arrow:0:$((_LC_MAX-3))}..."
        fi
    fi
    printf "║ LIFECYCLE:%s\n" "$_lc_arrow"

    echo "╠═══════════════════════════════════════════════════════════╣"
    echo "║ ITEMS ($item_count):"

    local items_json
    items_json=$(printf '%s' "$cr_json" | jq -r '.itemIds[]? // empty')
    if [[ -z "$items_json" ]]; then
        echo "║   (no items assigned)"
    else
        # Single-pass lookup + row formatting: one _kb_jq_read call joins
        # itemIds → backlog metadata (title, status, crTitle), formats each
        # printf-ready row, and streams them along with a ROLLUP summary
        # and stale-crTitle warning count. O(1) jq invocations regardless
        # of itemIds count.
        local item_ids_json
        item_ids_json=$(printf '%s' "$cr_json" | jq -c '.itemIds // []')
        # jq emits one TSV row per item ("id<TAB>status<TAB>title") plus
        # rollup/stale summary tagged lines. Shell handles padding via printf
        # so jq's role stays simple (one batched read, no string-format gymnastics).
        local lookup_output
        lookup_output=$(_kb_jq_read "$_cr_board" '
            ([.backlog[]? | select(.id as $id | $itemids | index($id) != null)]
                | map({(.id): {title: .title, status: (.status // "unknown"),
                               crTitle: (.crAssignment.crTitle // "")}})
                | add // {}) as $items |
            (
                ($itemids | map(
                    ($items[.] // {title: "", status: "unknown", crTitle: ""}) as $i |
                    [., $i.status, $i.title] | @tsv
                ))[],
                "ROLLUP_LINE:" + ([$items | to_entries[] | .value.status] | group_by(.) | sort_by(.[0]) | map("\(length) \(.[0])") | join(" · ")),
                "STALE_COUNT:" + ([$items | to_entries[] | select(.value.crTitle != "" and .value.crTitle != $crtitle)] | length | tostring)
            )
        ' --argjson itemids "$item_ids_json" --arg crtitle "$title" -r 2>/dev/null)

        local rollup_line="" stale_count="0"
        while IFS=$'\t' read -r _row_id _row_status _row_title; do
            case "$_row_id" in
                ROLLUP_LINE:*) rollup_line="${_row_id#ROLLUP_LINE:}" ;;
                STALE_COUNT:*) stale_count="${_row_id#STALE_COUNT:}" ;;
                "") ;;
                *) printf "║   %-15s %-12s %s\n" "[${_row_status}]" "$_row_id" "${_row_title:0:40}" ;;
            esac
        done <<< "$lookup_output"

        echo "╠═══════════════════════════════════════════════════════════╣"
        printf "║ ROLLUP: %s\n" "${rollup_line:-none}"
        if [[ -n "$stale_count" && "$stale_count" -gt 0 ]]; then
            printf "║ WARNING: %s item(s) have stale crTitle snapshot\n" "$stale_count"
        fi
    fi

    echo "╠═══════════════════════════════════════════════════════════╣"
    echo "║ TIMESTAMPS:"

    local ts_json
    ts_json=$(printf '%s' "$cr_json" | jq -r '.timestamps // {}')
    local ts_created ts_submitted ts_approved ts_dev_started ts_testing ts_deployed_dev
    local ts_deployed_prod ts_emergency ts_completed

    ts_created=$(printf '%s' "$ts_json" | jq -r '.cr_created_at // ""')
    ts_submitted=$(printf '%s' "$ts_json" | jq -r '.cr_submitted_at // ""')
    ts_approved=$(printf '%s' "$ts_json" | jq -r '.cr_approved_at // ""')
    ts_dev_started=$(printf '%s' "$ts_json" | jq -r '.cr_dev_started_at // ""')
    ts_testing=$(printf '%s' "$ts_json" | jq -r '.cr_testing_started_at // ""')
    ts_deployed_dev=$(printf '%s' "$ts_json" | jq -r '.cr_deployed_dev_at // ""')
    ts_deployed_prod=$(printf '%s' "$ts_json" | jq -r '.cr_deployed_prod_at // ""')
    ts_emergency=$(printf '%s' "$ts_json" | jq -r '.cr_emergency_deployed_at // ""')
    ts_completed=$(printf '%s' "$ts_json" | jq -r '.cr_completed_at // ""')

    [[ -n "$ts_created" ]]        && printf "║   drafted:            %s\n" "$ts_created"
    [[ -n "$ts_submitted" ]]      && printf "║   submitted:          %s\n" "$ts_submitted"
    [[ -n "$ts_approved" ]]       && printf "║   approved:           %s\n" "$ts_approved"
    [[ -n "$ts_dev_started" ]]    && printf "║   dev-started:        %s\n" "$ts_dev_started"
    [[ -n "$ts_testing" ]]        && printf "║   testing-started:    %s\n" "$ts_testing"
    [[ -n "$ts_deployed_dev" ]]   && printf "║   deployed-dev:       %s\n" "$ts_deployed_dev"
    [[ -n "$ts_deployed_prod" ]]  && printf "║   deployed-prod:      %s\n" "$ts_deployed_prod"
    [[ -n "$ts_emergency" ]]      && printf "║   emergency-deployed: %s\n" "$ts_emergency"
    [[ -n "$ts_completed" ]]      && printf "║   completed:          %s\n" "$ts_completed"
    printf "║   createdAt:          %s\n" "$created_at"
    printf "║   updatedAt:          %s\n" "$updated_at"
    echo "╚═══════════════════════════════════════════════════════════╝"
}

# ─────────────────────────────────────────────────────────────────────────────
# Container subcommand: list
# Usage: kb-cr list [--state <state>] [--platform <name>]
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_container_list() {
    local filter_state=""
    local filter_platform=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --state)    filter_state="${2:-}";    shift 2 ;;
            --state=*)  filter_state="${1#--state=}"; shift ;;
            --platform) filter_platform="${2:-}"; shift 2 ;;
            --platform=*) filter_platform="${1#--platform=}"; shift ;;
            --help|-h)
                echo "Usage: kb-cr list [--state <state>] [--platform <name>]"
                echo ""
                echo "Valid states: cr-drafted, cr-submitted, cr-approved, cr-rejected,"
                echo "              cr-held, implementing, deployed-dev, deployed-prod,"
                echo "              emergency-deployed"
                return 0
                ;;
            *) shift ;;
        esac
    done

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    # Build jq filter with optional predicates
    local jq_select='.crs // []'
    local -a list_args=()

    if [[ -n "$filter_state" ]]; then
        jq_select+=' | map(select(.crState == $state))'
        list_args+=(--arg state "$filter_state")
    fi

    if [[ -n "$filter_platform" ]]; then
        jq_select+=' | map(select(.platform == $platform))'
        list_args+=(--arg platform "$filter_platform")
    fi

    local cr_count
    cr_count=$(_kb_jq_read "$_cr_board" "(${jq_select}) | length" "${list_args[@]}" -r 2>/dev/null)

    echo "Change Requests for ${_cr_team}: ($cr_count CRs)"
    if [[ -n "$filter_state" || -n "$filter_platform" ]]; then
        local filters=""
        [[ -n "$filter_state" ]]    && filters+=" state=${filter_state}"
        [[ -n "$filter_platform" ]] && filters+=" platform=${filter_platform}"
        echo "  Filters:${filters}"
    fi
    echo "═══════════════════════════════════════════════════════════════"

    if [[ "$cr_count" -eq 0 ]]; then
        echo "  (no CRs)"
        echo "═══════════════════════════════════════════════════════════════"
        return 0
    fi

    _kb_jq_read "$_cr_board" \
        "(${jq_select})[] |
         \"  [\(.id)] \(.crState | ascii_upcase | .[0:12] | . + \" \" * (12 - length)) \(.type | ascii_upcase | .[0:9] | . + \" \" * (9 - length)) \(.title) (\(.itemIds | length) items)\"" \
        "${list_args[@]}" -r 2>/dev/null

    echo "═══════════════════════════════════════════════════════════════"
}

# ─────────────────────────────────────────────────────────────────────────────
# Container subcommand: transition
# Usage: kb-cr transition <CR-ID> <new-state>
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_container_transition() {
    local cr_id="${1:-}"
    local new_state="${2:-}"

    if [[ -z "$cr_id" || -z "$new_state" ]]; then
        echo "Usage: kb-cr transition <CR-ID> <new-state>" >&2
        echo "Valid states: cr-drafted, cr-submitted, cr-approved, cr-rejected," >&2
        echo "              cr-held, implementing, deployed-dev, deployed-prod," >&2
        echo "              emergency-deployed, cr-closed" >&2
        return 1
    fi

    # Validate the new state against the schema's crStates list
    case "$new_state" in
        cr-drafted|cr-submitted|cr-approved|cr-rejected|cr-held|\
        implementing|deployed-dev|deployed-prod|emergency-deployed|cr-closed) ;;
        *)
            echo "kb-cr transition: invalid state '$new_state'." >&2
            echo "Valid states: cr-drafted, cr-submitted, cr-approved, cr-rejected," >&2
            echo "              cr-held, implementing, deployed-dev, deployed-prod," >&2
            echo "              emergency-deployed, cr-closed" >&2
            return 1
            ;;
    esac

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local cr_idx
    cr_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id")
    if [[ "$cr_idx" == "-1" ]]; then
        echo "kb-cr transition: CR '$cr_id' not found on board '$_cr_team'." >&2
        return 1
    fi

    local old_state ts_field before
    old_state=$(_kb_jq_read "$_cr_board" ".crs[$cr_idx].crState // \"\"" -r 2>/dev/null)

    # Resolve the field first, purely so the CLI can report what it did.
    # The write itself is delegated — see _kb_cr_stamp_state_entry.
    ts_field=$(_kb_cr_state_entry_ts_field "$new_state")
    if [[ $? -ne 0 ]]; then
        echo "kb-cr transition: no timestamp mapping for state '$new_state'." >&2
        return 1
    fi
    if [[ -n "$ts_field" ]]; then
        before=$(_kb_jq_read "$_cr_board" \
            ".crs[$cr_idx].timestamps[\"$ts_field\"] // \"\"" -r 2>/dev/null)
    fi

    _kb_cr_stamp_state_entry "$_cr_board" "$cr_idx" "$cr_id" "$new_state" || return 1

    if [[ -z "$ts_field" ]]; then
        echo "Transitioned CR [$cr_id]: $old_state -> $new_state (no entry timestamp for this state)"
    elif [[ -n "$before" ]]; then
        echo "Transitioned CR [$cr_id]: $old_state -> $new_state (preserved existing $ts_field=$before)"
    else
        local written
        written=$(_kb_jq_read "$_cr_board" \
            ".crs[$cr_idx].timestamps[\"$ts_field\"] // \"\"" -r 2>/dev/null)
        echo "Transitioned CR [$cr_id]: $old_state -> $new_state ($ts_field=$written)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Subcommand implementations (per-item lifecycle, v1)
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_draft() {
    local item_id="${1:-}"
    shift 2>/dev/null

    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-cr draft <item-id> --type <major|emergency|fyi>" >&2
        return 1
    fi

    local cr_type=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type) cr_type="${2:-}"; shift 2 ;;
            --type=*) cr_type="${1#--type=}"; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$cr_type" ]]; then
        echo "kb-cr draft: --type is required (major | emergency | fyi)" >&2
        return 1
    fi

    case "$cr_type" in
        major|emergency|fyi) ;;
        *)
            echo "kb-cr draft: invalid type '$cr_type'. Must be: major | emergency | fyi" >&2
            return 1
            ;;
    esac

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "$item_id" || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    # Guard: if the item already has a crAssignment, do not create a second container.
    local existing_cr_id
    existing_cr_id=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].crAssignment.crId // \"\"" -r 2>/dev/null)
    if [[ -n "$existing_cr_id" ]]; then
        local board_dir doc_path
        board_dir=$(dirname "$_cr_board")
        doc_path="${board_dir}/cr-docs/${item_id}-CR.md"
        printf "NOTE: [%s] already has a CR draft — %s\n" "$item_id" "$existing_cr_id"
        printf "  Doc:  %s\n" "$doc_path"
        printf "  Use \`kb-cr show %s\` to review the existing draft.\n" "$item_id"
        return 0
    fi

    # Read the item title to use as the CR container title.
    local item_title
    item_title=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].title" -r 2>/dev/null)
    [[ -z "$item_title" ]] && item_title="$item_id"

    # Step 1: Create the v2 container record in .crs[].
    # _kb_cr_container_create declares its own local _cr_team/_cr_board/_cr_enabled so
    # it will not clobber our outer variables resolved by _kb_cr_preamble above.
    # Capture stdout to parse the generated CR-ID; the function prints:
    #   "Created CR [<CR-ID>]: <title>"
    #
    # _KB_CR_SKIP_DOC_FILE suppresses doc creation inside container_create so
    # we can create it here with the correct <ITEM-ID>-CR.md canonical path.
    local create_output cr_id
    _KB_CR_SKIP_DOC_FILE=1
    export _KB_CR_SKIP_DOC_FILE
    create_output=$(_kb_cr_container_create "$item_title" --type "$cr_type")
    local _container_rc=$?
    unset _KB_CR_SKIP_DOC_FILE
    if [[ $_container_rc -ne 0 ]]; then
        echo "kb-cr draft: failed to create CR container." >&2
        return 1
    fi
    # Parse CR-ID from the "Created CR [CR-TEAM-DATE-NNNN]: ..." line (inside brackets).
    cr_id=$(printf '%s' "$create_output" | grep -m1 '^Created CR \[' | sed -n 's/^Created CR \[\(CR-[^]]*\)\].*/\1/p')
    if [[ -z "$cr_id" ]]; then
        echo "kb-cr draft: could not parse CR-ID from container_create output." >&2
        echo "$create_output" >&2
        return 1
    fi

    # Echo the container creation output so the caller sees it.
    printf '%s\n' "$create_output"

    # Step 2: Write crAssignment back-pointer on the backlog item and append to
    # .crs[CR].itemIds. _kb_cr_container_add_item also uses its own local scope.
    # Keep _KB_CR_SKIP_DOC_FILE=1 in scope so add-item's first-item doc
    # materialization is suppressed — _kb_cr_draft owns doc creation (Step 2b).
    _KB_CR_SKIP_DOC_FILE=1 _kb_cr_container_add_item "$cr_id" "$item_id" || {
        echo "kb-cr draft: WARNING: container created ($cr_id) but add-item back-pointer failed." \
             "Run: kb-cr add-item $cr_id $item_id" >&2
        return 1
    }

    # Step 2b: Create the canonical Phase 3 local doc at cr-docs/<ITEM-ID>-CR.md.
    # Done AFTER add-item so we can pass item_id as the 7th arg (filename owner).
    # This also reads the item title already captured above.
    # Failure is non-fatal — the container + back-pointer are already written.
    local item_summary
    item_summary=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].description // \"\"" -r 2>/dev/null)
    _kb_cr_create_doc_file "$_cr_board" "$cr_id" "$item_title" "$cr_type" "" "$item_summary" "$item_id" || true

    local ts
    ts=$(_kb_cr_timestamp)

    # DEPRECATED: legacy flat fields kept for backward compat with LCARS v1 readers
    # (lcars-cr-tab.js reads cr_id/cr_type/cr_created_at directly off backlog items;
    # server.py uses them as fallback alongside crAssignment). Remove once LCARS is
    # fully migrated to reading from .crs[] via crAssignment.crId. (XACA-0327)
    _kb_jq_update "$_cr_board" \
        '.backlog[$idx].crState = "cr-drafted" |
         .backlog[$idx].cr_created_at = $ts |
         .backlog[$idx].cr_id = $crid |
         .backlog[$idx].cr_type = $crtype |
         .lastUpdated = $lu' \
        --argjson idx "$_cr_idx" \
        --arg ts "$ts" \
        --arg crid "$cr_id" \
        --arg crtype "$cr_type" \
        --arg lu "$ts"

    echo "kb-cr: [$item_id] drafted — crState=cr-drafted, cr_id=$cr_id, cr_type=$cr_type"
}

# ─────────────────────────────────────────────────────────────────────────────
# Subcommand: publish <item-id>
# Phase 3 (XACA-0308-002)
#
# Reads the canonical local CR doc at <team-kanban>/cr-docs/<ITEM-ID>-CR.md,
# invokes the Main Event CR skill (via Claude Code's Skill tool) to
# create/update the Confluence page in DPD2, then writes the returned URL
# to cr_confluence_url on the CR container record (.crs[]).
#
# SKILL HANDSHAKE (for subitem 005 — Main Event CR skill rewire):
#   Currently the Main Event CR skill reads source from RELNOTES or explicit
#   scope, not from a local md path. Until subitem 005 lands, kb-cr publish
#   will:
#     1. Read the local md path and verify it exists.
#     2. Echo a "Skill invocation prepared" block with the local md path and
#        platform so the operator (or a future automated caller) knows what to
#        pass to the skill.
#     3. If KB_CR_PUBLISH_DRY_RUN=1 (env var), stop here — no skill invocation.
#     4. Otherwise, attempt to invoke the skill via a claude -p subprocess,
#        passing the local md path as On-Demand scope. If the subprocess is
#        unavailable, emit an actionable message and return 1.
#
#   Subitem 005 MUST update the skill to:
#     - Accept a local md file path as scope source (On-Demand Mode).
#     - After creating/updating the Confluence page, write the URL back via:
#         kb-cr _set_confluence_url <item-id> <URL>
#       (internal plumbing wired in this subcommand — see _kb_cr_set_confluence_url).
#
# Re-run behavior:
#   If cr_confluence_url is already set on the CR container, the skill is
#   expected to update the existing page (same URL); this command passes the
#   existing URL through to the skill as a hint. Whether update-in-place is
#   supported is the skill's responsibility (subitem 005).
#
# Idempotent: if the local md doesn't exist, error clearly and suggest
# running kb-cr draft first.
# ─────────────────────────────────────────────────────────────────────────────
_kb_cr_publish() {
    local item_id="${1:-}"
    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-cr publish <item-id>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "$item_id" || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local board_dir cr_doc_path
    board_dir=$(dirname "$_cr_board")
    cr_doc_path="${board_dir}/cr-docs/${item_id}-CR.md"

    # ── Guard: local doc must exist before publishing ─────────────────────────
    if [[ ! -f "$cr_doc_path" ]]; then
        echo "kb-cr publish: Local CR document not found — run \`kb-cr draft ${item_id}\` first." >&2
        echo "  Expected path: ${cr_doc_path}" >&2
        return 1
    fi

    # ── Resolve the CR container record to get cr_id + existing confluence URL ─
    local cr_id_assigned cr_container_idx
    cr_id_assigned=$(_kb_jq_read "$_cr_board" \
        ".backlog[$_cr_idx].crAssignment.crId // \"\"" -r 2>/dev/null)

    # Fallback: read legacy cr_id flat field
    if [[ -z "$cr_id_assigned" ]]; then
        cr_id_assigned=$(_kb_jq_read "$_cr_board" \
            ".backlog[$_cr_idx].cr_id // \"\"" -r 2>/dev/null)
    fi

    if [[ -z "$cr_id_assigned" ]]; then
        echo "kb-cr publish: item '$item_id' has no CR assignment. Run \`kb-cr draft ${item_id} --type major\` first." >&2
        return 1
    fi

    cr_container_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id_assigned")

    local existing_confluence_url=""
    if [[ "$cr_container_idx" != "-1" && -n "$cr_container_idx" ]]; then
        existing_confluence_url=$(_kb_jq_read "$_cr_board" \
            ".crs[$cr_container_idx].cr_confluence_url // \"\"" -r 2>/dev/null)
    fi

    # ── Print invocation block ────────────────────────────────────────────────
    echo ""
    echo "kb-cr publish: Preparing Confluence publish for [$item_id]"
    echo "  CR container:  $cr_id_assigned"
    echo "  Local doc:     $cr_doc_path"
    echo "  Team:          $_cr_team"
    if [[ -n "$existing_confluence_url" ]]; then
        echo "  Existing URL:  $existing_confluence_url  (will update page)"
    else
        echo "  Existing URL:  (none — new page will be created)"
    fi
    echo ""

    # ── Dry-run mode: stop before invoking the skill ──────────────────────────
    if [[ "${KB_CR_PUBLISH_DRY_RUN:-0}" == "1" ]]; then
        echo "kb-cr publish: DRY-RUN mode (KB_CR_PUBLISH_DRY_RUN=1) — stopping before skill invocation."
        echo ""
        echo "  To publish, run without KB_CR_PUBLISH_DRY_RUN=1."
        echo "  Skill invocation spec (for subitem 005):"
        echo "    Mode: On-Demand"
        echo "    Scope source: local md file at ${cr_doc_path}"
        echo "    Existing Confluence URL (update hint): ${existing_confluence_url:-(none)}"
        echo "    Expected output: Confluence URL, Version, and Title strings"
        echo "    After publish: skill must call:"
        echo "      kb-cr _set_confluence_url ${item_id} <URL>"
        echo "      kb-cr _set_publish_stamps ${item_id} <VERSION> <TITLE>   (Guard 4, XACA-0896-001)"
        echo ""
        return 0
    fi

    # ── Skill invocation (subitem 005 wire-up) ────────────────────────────────
    # Until subitem 005 rewires the Main Event CR skill to accept a local md
    # path as On-Demand scope, this block attempts a subprocess invocation and
    # documents the expected interface for skill rewire.
    #
    # Interface contract (subitem 005 must implement):
    #   - The claude subprocess invokes the "Main Event CR" skill in On-Demand Mode.
    #   - Scope source: the content of ${cr_doc_path} passed via stdin or --input.
    #   - The skill creates/updates the Confluence page.
    #   - The skill outputs a line matching: "Confluence URL: <url>"
    #   - After outputting the URL, the skill calls:
    #       kb-cr _set_confluence_url <item_id> <url>
    #     OR the URL is captured here and written via _kb_cr_set_confluence_url.
    #
    # Check for claude CLI availability.
    if ! command -v claude >/dev/null 2>&1; then
        echo "kb-cr publish: 'claude' CLI not found on PATH." >&2
        echo "  Cannot invoke Main Event CR skill automatically." >&2
        echo ""
        echo "  Manual publish steps:" >&2
        echo "    1. Open the local CR doc: ${cr_doc_path}" >&2
        echo "    2. Invoke the Main Event CR skill in On-Demand Mode with the doc content as scope." >&2
        echo "    3. After the Confluence page is created, run:" >&2
        echo "         kb-cr _set_confluence_url ${item_id} <confluence-url>" >&2
        echo "         kb-cr _set_publish_stamps ${item_id} <version> <title>   (Guard 4, XACA-0896-001)" >&2
        echo ""
        return 1
    fi

    # Build the skill invocation prompt. Passes the local md path as the scope
    # source. The skill is expected to return a Confluence URL.
    #
    # Interface contract addition (XACA-0896-001, Guard 4): the skill is now
    # ALSO asked for "Confluence Version:" and "Confluence Title:" lines,
    # mirroring the pre-existing "Confluence URL:" contract above. These feed
    # _kb_cr_set_publish_stamps immediately below. The skill side of this
    # contract (actually emitting the lines) ships with the Guard 1/2/3 skill
    # rewrite (subitem 005) — until then extraction below degrades to a
    # non-fatal warning rather than blocking the pre-existing URL write-back.
    local skill_prompt
    skill_prompt="$(cat <<PROMPT
/Main Event CR

Publish this CR doc to Confluence in On-Demand Mode.
Scope source: local markdown file at ${cr_doc_path}
Read the file, translate content to plain business language per skill rules,
create/update the Confluence page in DPD2 space.
If existing Confluence URL is set (${existing_confluence_url:-none}), update that page.
After publishing, output three lines in EXACTLY this format (one value per line,
no extra commentary on the line itself):
  Confluence URL: <url>
  Confluence Version: <version>
  Confluence Title: <exact page title as published>
Then run:
  kb-cr _set_confluence_url ${item_id} <url>
  kb-cr _set_publish_stamps ${item_id} <version> <exact page title as published>
PROMPT
)"

    echo "kb-cr publish: Invoking Main Event CR skill..."
    echo "(Set KB_CR_PUBLISH_DRY_RUN=1 to stop here without invoking the skill)"
    echo ""

    # Invoke the skill. Capture stdout to extract the Confluence URL.
    # `claude -p` (--print) runs one-shot non-interactive mode; reads prompt from stdin.
    local skill_output
    skill_output=$(printf '%s\n' "$skill_prompt" | claude -p 2>&1) || {
        echo "kb-cr publish: skill invocation failed (exit $?)." >&2
        echo "$skill_output" >&2
        return 1
    }

    # Extract the Confluence URL from skill output.
    local conf_url
    conf_url=$(printf '%s\n' "$skill_output" | grep -oE 'Confluence URL: https?://[^ ]+' | head -1 | sed 's/Confluence URL: //')

    if [[ -z "$conf_url" ]]; then
        # Try a broader URL extraction as fallback
        conf_url=$(printf '%s\n' "$skill_output" | grep -oE 'https://mainevent\.atlassian\.net/wiki/spaces/DPD2/pages/[^ ]+' | head -1)
    fi

    if [[ -z "$conf_url" ]]; then
        echo "kb-cr publish: skill ran but no Confluence URL found in output." >&2
        echo "" >&2
        echo "Skill output:" >&2
        printf '%s\n' "$skill_output" >&2
        echo "" >&2
        echo "  If the page was created, manually run:" >&2
        echo "    kb-cr _set_confluence_url ${item_id} <url>" >&2
        return 1
    fi

    # Write the URL back to the board.
    _kb_cr_set_confluence_url "$item_id" "$conf_url" || return 1

    # ── Guard 4 (XACA-0896-001): stamp what was actually published ───────────
    # Only reached after cr_confluence_url has been confirmed written above —
    # this is the "publish actually succeeded" moment, not "publish was
    # attempted". Extraction is best-effort: until the skill rewire (subitem
    # 005) emits the "Confluence Version:"/"Confluence Title:" lines, this
    # warns rather than failing the publish outright — the pre-existing URL
    # write-back must not regress because of a not-yet-shipped sibling.
    local conf_version conf_title
    conf_version=$(printf '%s\n' "$skill_output" | grep -oE 'Confluence Version: .+' | head -1 | sed 's/^Confluence Version: //')
    conf_title=$(printf '%s\n' "$skill_output" | grep -oE 'Confluence Title: .+' | head -1 | sed 's/^Confluence Title: //')

    if [[ -n "$conf_version" && -n "$conf_title" ]]; then
        if _kb_cr_set_publish_stamps "$item_id" "$conf_version" "$conf_title"; then
            echo "  Publish stamps: version=$conf_version title=\"$conf_title\""
        else
            echo "kb-cr publish: WARNING: cr_confluence_url was written but publish stamps failed to write." >&2
            echo "  Run manually: kb-cr _set_publish_stamps ${item_id} \"$conf_version\" \"$conf_title\"" >&2
        fi
    else
        echo "kb-cr publish: WARNING: skill output did not include 'Confluence Version:' / 'Confluence Title:' lines — publish stamps NOT written." >&2
        echo "  Guards that compare an incoming publish against the last stamped publish cannot run until this" >&2
        echo "  CR has a stamp. Once the skill rewire (XACA-0896 subitem 005) emits these lines, stamps populate" >&2
        echo "  automatically. Until then, run manually if needed:" >&2
        echo "    kb-cr _set_publish_stamps ${item_id} <version> <title>" >&2
    fi

    echo "kb-cr publish: Published successfully."
    echo "  Confluence URL: $conf_url"
    echo ""
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal plumbing: _kb_cr_set_confluence_url <item-id> <url>
# Phase 3 (XACA-0308-002)
#
# Writes cr_confluence_url to the CR container record (.crs[cr_container_idx]).
# Called by:
#   - _kb_cr_publish (after successful skill invocation)
#   - kb-cr _set_confluence_url <item-id> <url>  (public CLI plumbing for skill use)
#
# Field placement: on the .crs[] container record (same location as cr_doc_link
# was written by set-doc-link). This mirrors the migration script which reads/
# writes cr_confluence_url on the container record.
# ─────────────────────────────────────────────────────────────────────────────
_kb_cr_set_confluence_url() {
    local item_id="${1:-}"
    local conf_url="${2:-}"

    if [[ -z "$item_id" || -z "$conf_url" ]]; then
        echo "Usage: kb-cr _set_confluence_url <item-id> <url>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "$item_id" || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    # Resolve the CR container for this item.
    local cr_id_assigned cr_container_idx
    cr_id_assigned=$(_kb_jq_read "$_cr_board" \
        ".backlog[$_cr_idx].crAssignment.crId // \"\"" -r 2>/dev/null)
    if [[ -z "$cr_id_assigned" ]]; then
        cr_id_assigned=$(_kb_jq_read "$_cr_board" \
            ".backlog[$_cr_idx].cr_id // \"\"" -r 2>/dev/null)
    fi
    if [[ -z "$cr_id_assigned" ]]; then
        echo "kb-cr _set_confluence_url: item '$item_id' has no CR assignment." >&2
        return 1
    fi

    cr_container_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id_assigned")
    if [[ "$cr_container_idx" == "-1" ]]; then
        echo "kb-cr _set_confluence_url: CR container '$cr_id_assigned' not found." >&2
        return 1
    fi

    local ts
    ts=$(_kb_cr_timestamp)

    # Write cr_confluence_url on the container record (.crs[]).
    _kb_jq_update "$_cr_board" '
        .crs[$cidx].cr_confluence_url = $url |
        .crs[$cidx].updatedAt = $ts |
        .lastUpdated = $ts
    ' \
    --argjson cidx "$cr_container_idx" \
    --arg url "$conf_url" \
    --arg ts "$ts" \
    || return 1

    # Record the publish event in the activity log.
    local event
    event=$(_kb_cr_activity_event "confluence_published" \
        "field=cr_confluence_url" \
        "new_value=${conf_url}" \
        "note=Published to Confluence; URL written to CR container record") || true
    if [[ -n "$event" ]]; then
        _kb_cr_activity_append "$_cr_board" "$cr_id_assigned" "$event" 2>/dev/null || true
    fi

    echo "cr_confluence_url set on CR [$cr_id_assigned]: $conf_url"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal plumbing: _kb_cr_set_publish_stamps <item-id> <version> <title>
# Guard 4 (XACA-0896-001, corrected XACA-0896-001-fix)
#
# Writes cr_published_version / cr_published_title to the CR container
# record (.crs[]) — advisory metadata about WHAT was published. This
# function does NOT stamp a timestamp. It originally also wrote
# cr_published_at flat on the same record, which was wrong: every other
# lifecycle instant in this schema lives under timestamps.* and is written
# and STRIPPED by the shared state-transition machinery
# (_kb_cr_state_strip_spec, which `kb-cr revert` depends on exclusively for
# timestamps.* paths). A flat cr_published_at was structurally invisible to
# that machinery — reverting a published CR strips timestamps.cr_published_at
# but would leave a flat sibling untouched, so a reverted record would keep
# asserting a publish that no longer holds. That is the exact "two fields
# that can disagree" failure mode XACA-0896 exists to eliminate, reproduced
# inside its own fix. cr_published_at now lives exclusively at
# .crs[].timestamps.cr_published_at, owned and written by XACA-0895's state
# advance — NOT by this function. Do not add it back here.
#
# Called by:
#   - _kb_cr_publish, immediately after _kb_cr_set_confluence_url succeeds
#     (same successful-publish moment, so cr_confluence_url and the publish
#     stamps are always written together — never a version/title update
#     with a stale or missing confluence_url, or vice versa).
#   - kb-cr _set_publish_stamps <item-id> <version> <title>  (public CLI
#     plumbing for skill use, mirrors _set_confluence_url)
#
# Field placement: on the .crs[cr_container_idx] container record — same
# location as cr_confluence_url/cr_doc_link/cr_proper_url.
#
# Read back via: kb-cr _get_publish_stamps <item-id>  (see below) — which
# reads cr_published_at from the NESTED timestamps.cr_published_at path,
# not from this record.
# ─────────────────────────────────────────────────────────────────────────────
_kb_cr_set_publish_stamps() {
    local item_id="${1:-}"
    local version="${2:-}"
    local title="${3:-}"

    if [[ -z "$item_id" || -z "$version" || -z "$title" ]]; then
        echo "Usage: kb-cr _set_publish_stamps <item-id> <version> <title>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "$item_id" || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    # Resolve the CR container for this item.
    local cr_id_assigned cr_container_idx
    cr_id_assigned=$(_kb_jq_read "$_cr_board" \
        ".backlog[$_cr_idx].crAssignment.crId // \"\"" -r 2>/dev/null)
    if [[ -z "$cr_id_assigned" ]]; then
        cr_id_assigned=$(_kb_jq_read "$_cr_board" \
            ".backlog[$_cr_idx].cr_id // \"\"" -r 2>/dev/null)
    fi
    if [[ -z "$cr_id_assigned" ]]; then
        echo "kb-cr _set_publish_stamps: item '$item_id' has no CR assignment." >&2
        return 1
    fi

    cr_container_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id_assigned")
    if [[ "$cr_container_idx" == "-1" ]]; then
        echo "kb-cr _set_publish_stamps: CR container '$cr_id_assigned' not found." >&2
        return 1
    fi

    local ts
    ts=$(_kb_cr_timestamp)

    # Write cr_published_version/cr_published_title on the container record
    # (.crs[]) — advisory metadata only. ts here is the record's own
    # updatedAt/lastUpdated bookkeeping, NOT a cr_published_at stamp: the
    # lifecycle "when was this published" timestamp lives exclusively at
    # .crs[].timestamps.cr_published_at, owned by XACA-0895's state-advance
    # machinery. Writing it here would recreate the flat/nested divergence
    # XACA-0896-001-fix removed — do not add it back.
    _kb_jq_update "$_cr_board" '
        .crs[$cidx].cr_published_version = $version |
        .crs[$cidx].cr_published_title   = $title   |
        .crs[$cidx].updatedAt            = $ts      |
        .lastUpdated                     = $ts
    ' \
    --argjson cidx "$cr_container_idx" \
    --arg version "$version" \
    --arg title "$title" \
    --arg ts "$ts" \
    || return 1

    # Record the publish-stamp event in the activity log.
    local event
    event=$(_kb_cr_activity_event "cr_publish_stamped" \
        "field=cr_published_version,cr_published_title" \
        "new_value=${version} | ${title}" \
        "note=Publish confirmed successful; version/title stamped on CR container record (cr_published_at is a separate lifecycle timestamp owned by XACA-0895, not written here)") || true
    if [[ -n "$event" ]]; then
        _kb_cr_activity_append "$_cr_board" "$cr_id_assigned" "$event" 2>/dev/null || true
    fi

    echo "publish stamps set on CR [$cr_id_assigned]: version=$version title=\"$title\" (updatedAt=$ts)"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal plumbing: _kb_cr_get_publish_stamps <item-id>
# Guard 4 (XACA-0896-001, corrected XACA-0896-001-fix)
#
# Reader counterpart to _kb_cr_set_publish_stamps. Echoes a single-line JSON
# object so Guards 1 and 3 (and anything else that needs to ask "what is
# currently stamped on this CR?") never have to re-derive the item-id ->
# CR-container resolution or hand-parse board JSON themselves:
#   {"cr_published_version":"2.10.7","cr_published_title":"...","cr_published_at":"..."}
# Any field not yet stamped (e.g. a CR that has never been published) comes
# back as JSON null, not an empty string — callers should use `jq -e` /
# `// empty` style checks rather than string-empty checks.
#
# cr_published_at is read from the NESTED .crs[].timestamps.cr_published_at
# path (owned by XACA-0895's state-advance machinery), NOT from a flat
# sibling field — there is no flat fallback, deliberately. Falling back to
# a flat field when the nested one is absent would resurrect the exact
# flat/nested divergence XACA-0896-001-fix removed: nested-or-null, never
# nested-or-flat. Until XACA-0895 lands, this will legitimately return null
# for cr_published_at on every CR — that is correct and safe (an absent
# stamp is read as suspicious by every guard that consults this, never as
# permission), not a bug to paper over here.
#
# Usage: kb-cr _get_publish_stamps <item-id>
# ─────────────────────────────────────────────────────────────────────────────
_kb_cr_get_publish_stamps() {
    local item_id="${1:-}"

    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-cr _get_publish_stamps <item-id>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "$item_id" || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local cr_id_assigned cr_container_idx
    cr_id_assigned=$(_kb_jq_read "$_cr_board" \
        ".backlog[$_cr_idx].crAssignment.crId // \"\"" -r 2>/dev/null)
    if [[ -z "$cr_id_assigned" ]]; then
        cr_id_assigned=$(_kb_jq_read "$_cr_board" \
            ".backlog[$_cr_idx].cr_id // \"\"" -r 2>/dev/null)
    fi
    if [[ -z "$cr_id_assigned" ]]; then
        echo "kb-cr _get_publish_stamps: item '$item_id' has no CR assignment." >&2
        return 1
    fi

    cr_container_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id_assigned")
    if [[ "$cr_container_idx" == "-1" ]]; then
        echo "kb-cr _get_publish_stamps: CR container '$cr_id_assigned' not found." >&2
        return 1
    fi

    _kb_jq_read "$_cr_board" '
        {
            cr_id: $cid,
            cr_published_version: (.crs[$cidx].cr_published_version // null),
            cr_published_title:   (.crs[$cidx].cr_published_title   // null),
            cr_published_at:      (.crs[$cidx].timestamps.cr_published_at // null)
        }
    ' --argjson cidx "$cr_container_idx" --arg cid "$cr_id_assigned" -c
}

_kb_cr_submit() {
    local item_id="${1:-}"
    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-cr submit <item-id>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "$item_id" || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local ts
    ts=$(_kb_cr_timestamp)

    _kb_cr_write_state "$_cr_board" "$_cr_idx" "cr-submitted" "cr_submitted_at" "$ts" \
    && echo "kb-cr: [$item_id] submitted — crState=cr-submitted, cr_submitted_at=$ts"
}

_kb_cr_approve() {
    local item_id="${1:-}"
    shift 2>/dev/null

    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-cr approve <item-id> [--by <login>] [--name <display-name>]" >&2
        return 1
    fi

    local approver_login="" approver_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --by) approver_login="${2:-}"; shift 2 ;;
            --by=*) approver_login="${1#--by=}"; shift ;;
            --name) approver_name="${2:-}"; shift 2 ;;
            --name=*) approver_name="${1#--name=}"; shift ;;
            *) shift ;;
        esac
    done

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "$item_id" || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local ts
    ts=$(_kb_cr_timestamp)

    local filter jq_args
    filter='.backlog[$idx].crState = "cr-approved" |
            .backlog[$idx].cr_approved_at = $ts'
    local -a jq_args=(--argjson idx "$_cr_idx" --arg ts "$ts")

    if [[ -n "$approver_login" ]]; then
        filter+=' | .backlog[$idx].cr_approved_by = $login'
        jq_args+=(--arg login "$approver_login")
    fi
    if [[ -n "$approver_name" ]]; then
        filter+=' | .backlog[$idx].cr_approver_name = $aname'
        jq_args+=(--arg aname "$approver_name")
    fi

    filter+=' | .lastUpdated = $lu'
    jq_args+=(--arg lu "$ts")

    _kb_jq_update "$_cr_board" "$filter" "${jq_args[@]}" \
    && echo "kb-cr: [$item_id] approved — crState=cr-approved, cr_approved_at=$ts${approver_login:+", by=$approver_login"}"
}

_kb_cr_reject() {
    local item_id="${1:-}"
    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-cr reject <item-id>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "$item_id" || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    # Rejection: no timestamp recorded; it is not a positive lifecycle event.
    # Increment pushback count.
    local ts
    ts=$(_kb_cr_timestamp)

    _kb_jq_update "$_cr_board" \
        '.backlog[$idx].crState = "cr-rejected" |
         .backlog[$idx].cr_pushback_count = ((.backlog[$idx].cr_pushback_count // 0) + 1) |
         .lastUpdated = $lu' \
        --argjson idx "$_cr_idx" \
        --arg lu "$ts" \
    && echo "kb-cr: [$item_id] rejected — crState=cr-rejected (pushback count incremented)"
}

_kb_cr_hold() {
    local item_id="${1:-}"
    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-cr hold <item-id>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "$item_id" || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local ts
    ts=$(_kb_cr_timestamp)

    _kb_jq_update "$_cr_board" \
        '.backlog[$idx].crState = "cr-held" | .lastUpdated = $lu' \
        --argjson idx "$_cr_idx" \
        --arg lu "$ts" \
    && echo "kb-cr: [$item_id] held — crState=cr-held"
}

_kb_cr_start_dev() {
    local item_id="${1:-}"
    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-cr start-dev <item-id>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "$item_id" || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local ts
    ts=$(_kb_cr_timestamp)

    _kb_cr_write_state "$_cr_board" "$_cr_idx" "implementing" "cr_dev_started_at" "$ts" \
    && echo "kb-cr: [$item_id] dev started — crState=implementing, cr_dev_started_at=$ts"
}

_kb_cr_start_test() {
    local item_id="${1:-}"
    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-cr start-test <item-id>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "$item_id" || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    # start-test does NOT change crState — the item's status field tracks testing.
    local ts
    ts=$(_kb_cr_timestamp)

    _kb_cr_write_ts_only "$_cr_board" "$_cr_idx" "cr_testing_started_at" "$ts" \
    && echo "kb-cr: [$item_id] testing started — cr_testing_started_at=$ts (crState unchanged)"
}

_kb_cr_deploy_dev() {
    local item_id="${1:-}"
    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-cr deploy-dev <item-id>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "$item_id" || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local ts
    ts=$(_kb_cr_timestamp)

    _kb_cr_write_state "$_cr_board" "$_cr_idx" "deployed-dev" "cr_deployed_dev_at" "$ts" \
    && echo "kb-cr: [$item_id] deployed to dev — crState=deployed-dev, cr_deployed_dev_at=$ts"
}

_kb_cr_deploy_prod() {
    local item_id="${1:-}"
    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-cr deploy-prod <item-id>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "$item_id" || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local ts
    ts=$(_kb_cr_timestamp)

    _kb_cr_write_state "$_cr_board" "$_cr_idx" "deployed-prod" "cr_deployed_prod_at" "$ts" \
    && echo "kb-cr: [$item_id] deployed to prod — crState=deployed-prod, cr_deployed_prod_at=$ts"
}

_kb_cr_emergency() {
    local item_id="${1:-}"
    shift 2>/dev/null

    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-cr emergency <item-id> --justification \"reason\"" >&2
        return 1
    fi

    local justification=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --justification) justification="${2:-}"; shift 2 ;;
            --justification=*) justification="${1#--justification=}"; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$justification" ]]; then
        echo "kb-cr emergency: --justification is required for emergency deployments." >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "$item_id" || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local ts
    ts=$(_kb_cr_timestamp)

    _kb_jq_update "$_cr_board" \
        '.backlog[$idx].crState = "emergency-deployed" |
         .backlog[$idx].cr_emergency_deployed_at = $ts |
         .backlog[$idx].emergency_justification = $just |
         .lastUpdated = $lu' \
        --argjson idx "$_cr_idx" \
        --arg ts "$ts" \
        --arg just "$justification" \
        --arg lu "$ts" \
    && echo "kb-cr: [$item_id] emergency deployed — crState=emergency-deployed, cr_emergency_deployed_at=$ts"
}

_kb_cr_complete() {
    local item_id="${1:-}"
    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-cr complete <item-id>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "$item_id" || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local ts
    ts=$(_kb_cr_timestamp)

    _kb_cr_write_ts_only "$_cr_board" "$_cr_idx" "cr_completed_at" "$ts" \
    && echo "kb-cr: [$item_id] CR lifecycle complete — cr_completed_at=$ts" \
    && echo "       Run 'kb-done' to move the item to completed status."
}

# ─────────────────────────────────────────────────────────────────────────────
# kb-cr backfill — infer crState from existing timestamp fields (legacy data)
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_backfill() {
    local apply=0
    local deploy_timestamps=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --apply)              apply=1;              shift ;;
            --deploy-timestamps)  deploy_timestamps=1;  shift ;;
            --help|-h)
                cat <<'EOF'
kb-cr backfill — infer missing CR fields on legacy items.

Modes:
  kb-cr backfill [--apply]
      Infer crState for items with cr_* timestamps but no crState field.

  kb-cr backfill --deploy-timestamps [--apply]
      Scrape activity logs to fill missing deployStartAt / deployCompletedAt
      on CRs whose items have deploy-verb activity entries.

Both modes are dry-run by default. Pass --apply to write changes.
EOF
                return 0 ;;
            *) shift ;;
        esac
    done

    if [[ $deploy_timestamps -eq 1 ]]; then
        _kb_cr_backfill_deploy_timestamps "$apply"
        return $?
    fi

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "" || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    if [[ $apply -eq 0 ]]; then
        echo "kb-cr backfill [DRY RUN] — pass --apply to write changes."
    else
        echo "kb-cr backfill [APPLY MODE] — writing inferred crState values."
    fi

    # Single-pass: ask jq for the index, id, and inferred crState of every
    # eligible item. Replaces a per-item loop that previously issued 6+ jq
    # invocations per backlog entry (XACA-0291-014).
    #
    # Output format: one TSV line per eligible item — "<idx>\t<id>\t<state>"
    local candidates
    candidates=$(_kb_jq_read "$_cr_board" \
        '[.backlog | to_entries[]
          | select((.value.crState // "") == "")
          | . as $e
          | (
              if   ($e.value.cr_deployed_prod_at  // "") != "" then "deployed-prod"
              elif ($e.value.cr_deployed_dev_at   // "") != "" then "deployed-dev"
              elif ($e.value.cr_dev_started_at    // "") != "" then "implementing"
              elif ($e.value.cr_approved_at       // "") != "" then "cr-approved"
              elif ($e.value.cr_submitted_at      // "") != "" then "cr-submitted"
              elif ($e.value.cr_id                // "") != "" then "cr-drafted"
              else                                                  ""
              end
            ) as $state
          | select($state != "")
          | "\($e.key)\t\($e.value.id // "[index \($e.key)]")\t\($state)"
         ] | .[]' -r 2>/dev/null)

    local found=0
    local idx item_id_val inferred_state line
    while IFS=$'\t' read -r idx item_id_val inferred_state; do
        [[ -z "$idx" ]] && continue
        found=$((found + 1))
        echo "Item $item_id_val: would set crState=$inferred_state"

        if [[ $apply -eq 1 ]]; then
            local ts
            ts=$(_kb_cr_timestamp)
            _kb_jq_update "$_cr_board" \
                ".backlog[$idx].crState = \$state | .lastUpdated = \$lu" \
                --arg state "$inferred_state" \
                --arg lu "$ts" \
            && echo "  → written: crState=$inferred_state"
        fi
    done <<< "$candidates"

    if [[ $found -eq 0 ]]; then
        echo "kb-cr backfill: no eligible items found (all have crState or no CR fields)."
    else
        if [[ $apply -eq 0 ]]; then
            echo ""
            echo "[$found item(s) would be updated. Re-run with --apply to write.]"
        else
            echo ""
            echo "[$found item(s) updated.]"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# _kb_cr_backfill_deploy_timestamps — scrape activity logs for deploy events
# and propose (or apply) deployStartAt / deployCompletedAt on container CRs.
#
# Usage (called from _kb_cr_backfill with $1=apply):
#   _kb_cr_backfill_deploy_timestamps <apply_flag>   (0=dry-run, 1=write)
#
# Detection strategy:
#   1. Primary: activity log entries with action == "deploy_started" / "deploy_completed"
#      whose target matches any itemId in crs[i].itemIds[].
#   2. Fallback: entries with action containing "deploy" (case-insensitive) and
#      "deploy_window_planned" timestamp as anchor — logs a note but does not write.
#
# Only proposes writes for container CRs (.crs[]) that are missing the field.
# DRY-RUN by default; requires --apply from the parent verb.
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_backfill_deploy_timestamps() {
    local apply="${1:-0}"

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "" || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

    local board_dir
    board_dir=$(dirname "$_cr_board")
    local activity_dir="${board_dir}/activity"

    if [[ $apply -eq 0 ]]; then
        echo "kb-cr backfill --deploy-timestamps [DRY RUN] — pass --apply to write changes."
    else
        echo "kb-cr backfill --deploy-timestamps [APPLY MODE] — writing inferred deploy timestamps."
    fi

    # Read all container CRs
    local cr_count
    cr_count=$(_kb_jq_read "$_cr_board" '(.crs // []) | length' -r 2>/dev/null || echo "0")

    local found=0
    local cidx=0
    while [[ $cidx -lt $cr_count ]]; do
        local cr_id cr_state has_start has_completed
        cr_id=$(_kb_jq_read "$_cr_board" ".crs[$cidx].id // \"\"" -r 2>/dev/null)
        cr_state=$(_kb_jq_read "$_cr_board" ".crs[$cidx].crState // \"cr-drafted\"" -r 2>/dev/null)
        has_start=$(_kb_jq_read "$_cr_board" ".crs[$cidx].timestamps.deployStartAt // \"\"" -r 2>/dev/null)
        has_completed=$(_kb_jq_read "$_cr_board" ".crs[$cidx].timestamps.deployCompletedAt // \"\"" -r 2>/dev/null)

        # Only examine CRs that are missing at least one deploy timestamp
        if [[ -n "$has_start" && -n "$has_completed" ]]; then
            cidx=$((cidx + 1))
            continue
        fi

        # Collect all itemIds for this CR
        local item_ids_json
        item_ids_json=$(_kb_jq_read "$_cr_board" ".crs[$cidx].itemIds // []" 2>/dev/null)

        # Scan activity logs for each item
        local inferred_start="" inferred_completed=""
        local item_id
        while IFS= read -r item_id; do
            [[ -z "$item_id" ]] && continue
            local log_file="${activity_dir}/${item_id}.json"
            [[ ! -f "$log_file" ]] && continue

            # Primary detection: action == deploy_started / deploy_completed
            local start_ts
            start_ts=$(jq -r '
                [.entries[]
                 | select(.action == "deploy_started" or
                          (.action | ascii_downcase | test("deploy.*start")))
                 | .timestamp] | sort | first // ""
            ' "$log_file" 2>/dev/null)

            local completed_ts
            completed_ts=$(jq -r '
                [.entries[]
                 | select(.action == "deploy_completed" or
                          (.action | ascii_downcase | test("deploy.*complet")))
                 | .timestamp] | sort | last // ""
            ' "$log_file" 2>/dev/null)

            # Fallback: any entry with "deploy" in the action, use newValue or timestamp
            if [[ -z "$start_ts" ]]; then
                start_ts=$(jq -r '
                    [.entries[]
                     | select(.action | ascii_downcase | test("deploy"))
                     | select(.newValue // "" | test("start|begin"; "i"))
                     | .timestamp] | sort | first // ""
                ' "$log_file" 2>/dev/null)
            fi
            if [[ -z "$completed_ts" ]]; then
                completed_ts=$(jq -r '
                    [.entries[]
                     | select(.action | ascii_downcase | test("deploy"))
                     | select(.newValue // "" | test("complet|done|finish"; "i"))
                     | .timestamp] | sort | last // ""
                ' "$log_file" 2>/dev/null)
            fi

            # Keep earliest start and latest completed across all items
            if [[ -n "$start_ts" ]]; then
                if [[ -z "$inferred_start" || "$start_ts" < "$inferred_start" ]]; then
                    inferred_start="$start_ts"
                fi
            fi
            if [[ -n "$completed_ts" ]]; then
                if [[ -z "$inferred_completed" || "$completed_ts" > "$inferred_completed" ]]; then
                    inferred_completed="$completed_ts"
                fi
            fi
        done < <(printf '%s\n' "$item_ids_json" | jq -r '.[]' 2>/dev/null)

        # Report findings
        local needs_write=0
        if [[ -z "$has_start" && -n "$inferred_start" ]]; then
            echo "  CR $cr_id ($cr_state): would set timestamps.deployStartAt=$inferred_start"
            needs_write=1
        fi
        if [[ -z "$has_completed" && -n "$inferred_completed" ]]; then
            echo "  CR $cr_id ($cr_state): would set timestamps.deployCompletedAt=$inferred_completed"
            needs_write=1
        fi
        if [[ $needs_write -eq 0 ]]; then
            if [[ -z "$inferred_start" && -z "$inferred_completed" ]]; then
                echo "  CR $cr_id ($cr_state): no deploy activity entries found in item logs — skipping"
            fi
        fi

        if [[ $needs_write -eq 1 ]]; then
            found=$((found + 1))
            if [[ $apply -eq 1 ]]; then
                local now
                now=$(_kb_cr_timestamp)
                local update_filter="" update_args=()
                update_args+=(--argjson cidx "$cidx" --arg now "$now")

                if [[ -z "$has_start" && -n "$inferred_start" ]]; then
                    update_filter+=" | .crs[\$cidx].timestamps.deployStartAt = \$deployStart"
                    update_args+=(--arg deployStart "$inferred_start")
                fi
                if [[ -z "$has_completed" && -n "$inferred_completed" ]]; then
                    update_filter+=" | .crs[\$cidx].timestamps.deployCompletedAt = \$deployCompleted"
                    update_args+=(--arg deployCompleted "$inferred_completed")
                fi

                # Strip leading " | "
                update_filter="${update_filter# | }"
                update_filter+=" | .crs[\$cidx].updatedAt = \$now | .lastUpdated = \$now"

                _kb_jq_update "$_cr_board" \
                    "${update_filter}" \
                    "${update_args[@]}" \
                && echo "    → written for CR $cr_id"
            fi
        fi

        cidx=$((cidx + 1))
    done

    echo ""
    if [[ $found -eq 0 ]]; then
        echo "kb-cr backfill --deploy-timestamps: no CRs found with missing deploy timestamps and matching activity log entries."
    else
        if [[ $apply -eq 0 ]]; then
            echo "[$found CR(s) have inferable deploy timestamps. Re-run with --apply to write.]"
        else
            echo "[$found CR(s) updated with deploy timestamps.]"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# kb-cr show — display CR lifecycle fields for an item
# This is the canonical CR display path when kb-backlog show cannot be extended.
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_show() {
    local item_id="${1:-}"
    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-cr show <item-id>" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled _cr_item_id _cr_idx
    _kb_cr_preamble "$item_id" || return 1

    # When CR support is disabled, show nothing (disabled-state parity invariant).
    [[ "$_cr_enabled" != "true" ]] && return 0

    # Read all CR fields from the item
    local cr_id cr_type cr_state deploy_window cr_approved_by cr_approver_name
    local cr_pushback_count cr_summary
    local cr_created cr_submitted cr_approved cr_dev_started cr_testing_started
    local cr_deployed_dev cr_deployed_prod cr_emergency_deployed cr_completed
    local emergency_justification

    cr_id=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].cr_id // \"\"" -r 2>/dev/null)

    # Read crAssignment.crId early — needed to determine whether the item has
    # ANY CR association before deciding to early-return.
    local cr_id_assigned
    cr_id_assigned=$(_kb_jq_read "$_cr_board" \
        ".backlog[$_cr_idx].crAssignment.crId // \"\"" -r 2>/dev/null)

    # If BOTH legacy cr_id AND crAssignment.crId are absent, the item has no CR
    # association at all — emit a diagnostic and return non-zero.
    if [[ -z "$cr_id" && -z "$cr_id_assigned" ]]; then
        printf "kb-cr show: item '%s' has no CR assignment.\n" "$_cr_item_id" >&2
        return 1
    fi

    # ── Legacy flat-field block: render only when cr_id is present ────────────
    # Items created via kb-cr draft (post -001) have BOTH cr_id AND crAssignment.
    # Items created via kb-cr attach ONLY have crAssignment (no legacy fields).
    if [[ -n "$cr_id" ]]; then
        cr_type=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].cr_type // \"\"" -r 2>/dev/null)
        cr_state=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].crState // \"\"" -r 2>/dev/null)
        deploy_window=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].deploy_window_planned // \"\"" -r 2>/dev/null)
        cr_approved_by=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].cr_approved_by // \"\"" -r 2>/dev/null)
        cr_approver_name=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].cr_approver_name // \"\"" -r 2>/dev/null)
        cr_pushback_count=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].cr_pushback_count // 0" -r 2>/dev/null)
        cr_summary=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].cr_summary // \"\"" -r 2>/dev/null)
        emergency_justification=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].emergency_justification // \"\"" -r 2>/dev/null)

        cr_created=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].cr_created_at // \"\"" -r 2>/dev/null)
        cr_submitted=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].cr_submitted_at // \"\"" -r 2>/dev/null)
        cr_approved=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].cr_approved_at // \"\"" -r 2>/dev/null)
        cr_dev_started=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].cr_dev_started_at // \"\"" -r 2>/dev/null)
        cr_testing_started=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].cr_testing_started_at // \"\"" -r 2>/dev/null)
        cr_deployed_dev=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].cr_deployed_dev_at // \"\"" -r 2>/dev/null)
        cr_deployed_prod=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].cr_deployed_prod_at // \"\"" -r 2>/dev/null)
        cr_emergency_deployed=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].cr_emergency_deployed_at // \"\"" -r 2>/dev/null)
        cr_completed=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].cr_completed_at // \"\"" -r 2>/dev/null)

        echo ""
        echo "─── CR Lifecycle ──────────────────────────────────────────────"
        printf "  CR ID:      %s\n" "$cr_id"
        printf "  Type:       %s\n" "${cr_type:-—}"
        printf "  State:      %s\n" "${cr_state:-—}"
        [[ -n "$deploy_window" ]] && printf "  Deploy Win: %s\n" "$deploy_window"
        [[ -n "$cr_approver_name" ]] && printf "  Approver:   %s (%s)\n" "$cr_approver_name" "$cr_approved_by"
        [[ -n "$cr_approved_by" ]] && [[ -z "$cr_approver_name" ]] && printf "  Approver:   %s\n" "$cr_approved_by"
        [[ "$cr_pushback_count" -gt 0 ]] && printf "  Pushbacks:  %s\n" "$cr_pushback_count"
        [[ -n "$cr_summary" ]] && printf "  Summary:    %s\n" "${cr_summary:0:80}"
        [[ -n "$emergency_justification" ]] && printf "  Emergency:  %s\n" "${emergency_justification:0:80}"

        echo "  Timestamps (chronological):"
        [[ -n "$cr_created" ]]          && printf "    drafted:          %s\n" "$cr_created"
        [[ -n "$cr_submitted" ]]        && printf "    submitted:        %s\n" "$cr_submitted"
        [[ -n "$cr_approved" ]]         && printf "    approved:         %s\n" "$cr_approved"
        [[ -n "$cr_dev_started" ]]      && printf "    dev-started:      %s\n" "$cr_dev_started"
        [[ -n "$cr_testing_started" ]]  && printf "    testing-started:  %s\n" "$cr_testing_started"
        [[ -n "$cr_deployed_dev" ]]     && printf "    deployed-dev:     %s\n" "$cr_deployed_dev"
        [[ -n "$cr_deployed_prod" ]]    && printf "    deployed-prod:    %s\n" "$cr_deployed_prod"
        [[ -n "$cr_emergency_deployed" ]] && printf "    emergency-deployed: %s\n" "$cr_emergency_deployed"
        [[ -n "$cr_completed" ]]        && printf "    completed:        %s\n" "$cr_completed"
        echo "───────────────────────────────────────────────────────────────"
    fi

    # ── crAssignment-only minimum item view ────────────────────────────────────
    # Rendered when the item was attached via kb-cr attach (no legacy flat fields).
    # When cr_id IS also present, this block is skipped — the legacy block above
    # already captured all available item-level metadata.
    if [[ -z "$cr_id" && -n "$cr_id_assigned" ]]; then
        local item_title item_state cr_assigned_at
        item_title=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].title // \"\"" -r 2>/dev/null)
        item_state=$(_kb_jq_read "$_cr_board" ".backlog[$_cr_idx].status // \"\"" -r 2>/dev/null)
        cr_assigned_at=$(_kb_jq_read "$_cr_board" \
            ".backlog[$_cr_idx].crAssignment.assignedAt // \"\"" -r 2>/dev/null)

        echo ""
        echo "╔═══════════════════════════════════════════════════════════╗"
        printf "║ Item: [%s] %s\n" "$_cr_item_id" "${item_title:0:50}"
        printf "║ State: %s\n" "${item_state:-—}"
        printf "║ CR Assignment: %s" "$cr_id_assigned"
        [[ -n "$cr_assigned_at" ]] && printf " — assigned %s" "$cr_assigned_at"
        printf "\n"
    fi

    # ── Sibling section: rendered whenever crAssignment.crId is present ────────
    # Uses ╠ (continuation) when a legacy block or minimum-view header was printed
    # above; uses ╔ only for the attach-only path where we opened ╔ just above.
    if [[ -n "$cr_id_assigned" ]]; then
        local cr_container_idx
        cr_container_idx=$(_kb_cr_find_container "$_cr_board" "$cr_id_assigned")

        if [[ "$cr_container_idx" == "-1" ]] || [[ -z "$cr_container_idx" ]]; then
            echo ""
            printf "║ WARNING: crAssignment.crId=\"%s\" but no matching .crs[] entry found.\n" \
                "$cr_id_assigned"
        else
            # Read all itemIds from the container
            local item_ids_json sibling_count
            item_ids_json=$(_kb_jq_read "$_cr_board" \
                ".crs[$cr_container_idx].itemIds // []" -c 2>/dev/null)
            sibling_count=$(printf '%s' "$item_ids_json" | jq 'length' 2>/dev/null)
            sibling_count="${sibling_count:-0}"

            echo ""
            if [[ -n "$cr_id" ]]; then
                # Continuing from legacy block — use ╠ connector
                echo "╠═══════════════════════════════════════════════════════════╣"
            else
                # Continuing from minimum-view ╔ header — use ╠ connector
                echo "╠═══════════════════════════════════════════════════════════╣"
            fi
            printf "║ SIBLINGS ON CR [%s] (%s items):\n" \
                "$cr_id_assigned" "$sibling_count"

            if [[ "$sibling_count" -eq 0 ]]; then
                echo "║   (no items in container)"
            else
                # Single-pass title lookup + row formatting: one _kb_jq_read call
                # joins itemIds → backlog titles, computes the per-row marker
                # (→ for self, space otherwise), and streams printf-ready rows.
                # O(1) jq invocations regardless of sibling count (XACA-0327-015).
                _kb_jq_read "$_cr_board" '
                    ([.backlog[]? | select(.id as $id | $itemids | index($id) != null)]
                        | map({(.id): .title}) | add // {}) as $titles |
                    $itemids | map(
                        ($titles[.] // "") as $t |
                        (if . == $self then "→" else " " end) as $m |
                        if $t == "" then "║ \($m) [\(.)]"
                        else "║ \($m) [\(.)] \($t[0:50])"
                        end
                    ) | .[]
                ' --argjson itemids "$item_ids_json" \
                  --arg     self    "$_cr_item_id" -r 2>/dev/null
            fi

            echo "╚═══════════════════════════════════════════════════════════╝"
        fi
    fi

    # ── Phase 3 (XACA-0308-002): local md path + cr_confluence_url ──────────
    # Displayed at the bottom of show output, after all CR state/sibling blocks,
    # so it's visible regardless of which display path fired above.
    local board_dir cr_doc_path
    board_dir=$(dirname "$_cr_board")
    cr_doc_path="${board_dir}/cr-docs/${item_id}-CR.md"

    local show_cr_id_for_url="$cr_id_assigned"
    [[ -z "$show_cr_id_for_url" && -n "$cr_id" ]] && show_cr_id_for_url="$cr_id"

    local cr_confluence_url=""
    if [[ -n "$show_cr_id_for_url" ]]; then
        local url_container_idx
        url_container_idx=$(_kb_cr_find_container "$_cr_board" "$show_cr_id_for_url" 2>/dev/null)
        if [[ -n "$url_container_idx" && "$url_container_idx" != "-1" ]]; then
            cr_confluence_url=$(_kb_jq_read "$_cr_board" \
                ".crs[$url_container_idx].cr_confluence_url // \"\"" -r 2>/dev/null)
        fi
    fi

    echo ""
    echo "── Phase 3 CR Doc ───────────────────────────────────────────"
    if [[ -f "$cr_doc_path" ]]; then
        printf "  Local CR doc:   %s\n" "$cr_doc_path"
    else
        printf "  Local CR doc:   (not created — run: kb-cr draft %s)\n" "$item_id"
    fi
    if [[ -n "$cr_confluence_url" ]]; then
        printf "  Published to Confluence: %s\n" "$cr_confluence_url"
    else
        printf "  Confluence URL: (not yet published — run: kb-cr publish %s)\n" "$item_id"
    fi
    echo "─────────────────────────────────────────────────────────────"
}

# ─────────────────────────────────────────────────────────────────────────────
# kb-cr audit — orchestrate collector + renderer + optional Confluence publish
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_audit() {
    # ── Locate the scripts dir via module-level variable (set at source time) ──
    # BASH_SOURCE[0] is unreliable inside functions when the file is sourced
    # in zsh — it resolves to the caller's script, not this file.
    # $_KB_CR_SCRIPT_DIR is captured at the top of this file during sourcing.
    local script_dir="${_KB_CR_SCRIPT_DIR}"

    local collector="${script_dir}/kb-cr-audit.py"
    local renderer="${script_dir}/kb-cr-audit-render.py"
    local publisher="${script_dir}/kb-cr-audit-publish.py"

    # ── Dependency check before touching any args ──────────────────────────
    local missing=()
    [[ -f "$collector" ]]  || missing+=("scripts/kb-cr-audit.py")
    [[ -f "$renderer" ]]   || missing+=("scripts/kb-cr-audit-render.py")
    [[ -f "$publisher" ]]  || missing+=("scripts/kb-cr-audit-publish.py")
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "kb-cr audit: pipeline incomplete — missing ${missing[*]}" >&2
        return 2
    fi

    # ── Defaults ───────────────────────────────────────────────────────────
    local team=""
    local from_date to_date
    from_date=$(date -u +%Y-%m-01T00:00:00Z)   # first day of current month
    to_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)     # now
    local format="both"
    local out_dir="./cab-audit-output"
    local publish_confluence=0
    local apply_flag=0
    local parent_page_id=""

    # ── Arg parse ──────────────────────────────────────────────────────────
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --team)             team="$2";           shift 2 ;;
            --from)             from_date="$2";      shift 2 ;;
            --to)               to_date="$2";        shift 2 ;;
            --format)           format="$2";         shift 2 ;;
            --out-dir)          out_dir="$2";        shift 2 ;;
            --publish-confluence) publish_confluence=1; shift ;;
            --apply)            apply_flag=1;        shift ;;
            --parent-page-id)   parent_page_id="$2"; shift 2 ;;
            --help|-h)
                _kb_cr_audit_help
                return 0
                ;;
            *)
                echo "kb-cr audit: unknown option '$1'. Run 'kb-cr audit --help' for usage." >&2
                return 2
                ;;
        esac
    done

    # ── Required: --team ───────────────────────────────────────────────────
    if [[ -z "$team" ]]; then
        echo "kb-cr audit: --team <slug> is required." >&2
        echo "Usage: kb-cr audit --team <slug> [--from <ISO8601>] [--to <ISO8601>]" >&2
        echo "                   [--format md|json|both] [--out-dir <path>]" >&2
        echo "                   [--publish-confluence] [--apply] [--parent-page-id <id>]" >&2
        return 2
    fi

    # Reject team slugs that aren't safe to interpolate into filenames.
    if [[ ! "$team" =~ ^[a-z0-9_-]+$ ]]; then
        echo "kb-cr audit: --team must match [a-z0-9_-]+ (got: '$team')." >&2
        return 2
    fi

    # ── Validate --format ──────────────────────────────────────────────────
    case "$format" in
        md|json|both) ;;
        *)
            echo "kb-cr audit: --format must be md, json, or both (got: '$format')." >&2
            return 2
            ;;
    esac

    # ── Build output paths ─────────────────────────────────────────────────
    # Normalise date tokens for safe filenames: strip colons and sub-second parts.
    local from_token to_token
    from_token="${from_date//:/}"   # e.g. 2026-05-01T000000Z
    to_token="${to_date//:/}"
    local json_out="${out_dir}/cab-audit-${team}-${from_token}-${to_token}.json"
    local md_out="${out_dir}/cab-audit-${team}-${from_token}-${to_token}.md"

    # ── Create output directory ────────────────────────────────────────────
    mkdir -p "$out_dir" || {
        echo "kb-cr audit: cannot create output directory '${out_dir}'." >&2
        return 1
    }

    # ── Step 1: Run collector → JSON ───────────────────────────────────────
    echo "kb-cr audit: collecting data for team '${team}' [${from_date} → ${to_date}]..."
    local audit_json
    audit_json=$(python3 "$collector" --team "$team" --from "$from_date" --to "$to_date" --pretty)
    local collector_exit=$?
    if [[ $collector_exit -ne 0 ]]; then
        echo "kb-cr audit: collector exited $collector_exit — aborting." >&2
        return $collector_exit
    fi

    # ── Step 2: Save JSON ──────────────────────────────────────────────────
    local wrote_json=0
    if [[ "$format" != "md" ]]; then
        printf '%s\n' "$audit_json" > "$json_out" || {
            echo "kb-cr audit: failed to write JSON to '${json_out}'." >&2
            return 1
        }
        wrote_json=1
        echo "kb-cr audit: JSON written → ${json_out}"
    fi

    # ── Step 3: Render markdown ────────────────────────────────────────────
    local wrote_md=0
    if [[ "$format" != "json" ]]; then
        echo "kb-cr audit: rendering markdown..."
        local md_content
        md_content=$(printf '%s\n' "$audit_json" | python3 "$renderer")
        local renderer_exit=$?
        if [[ $renderer_exit -ne 0 ]]; then
            echo "kb-cr audit: renderer exited $renderer_exit — aborting." >&2
            return $renderer_exit
        fi
        printf '%s\n' "$md_content" > "$md_out" || {
            echo "kb-cr audit: failed to write markdown to '${md_out}'." >&2
            return 1
        }
        wrote_md=1
        echo "kb-cr audit: Markdown written → ${md_out}"
    fi

    # ── Step 4: Optional Confluence publish ────────────────────────────────
    local publish_result=""
    if [[ $publish_confluence -eq 1 ]]; then
        echo "kb-cr audit: publishing to Confluence (team=${team})..."
        local publish_args=(--team "$team")
        [[ -n "$parent_page_id" ]] && publish_args+=(--parent-page-id "$parent_page_id")
        [[ $apply_flag -eq 1 ]] && publish_args+=(--apply)

        local publish_output
        publish_output=$(printf '%s\n' "$audit_json" | python3 "$publisher" "${publish_args[@]}")
        local publish_exit=$?
        if [[ $publish_exit -ne 0 ]]; then
            echo "kb-cr audit: publisher exited $publish_exit." >&2
            echo "$publish_output" >&2
            return $publish_exit
        fi
        echo "$publish_output"
        # Extract URL from output if present (publisher should emit it)
        local conf_url
        conf_url=$(printf '%s\n' "$publish_output" | grep -oE 'https?://[^ ]+' | head -1)
        if [[ -n "$conf_url" ]]; then
            publish_result="Published: ${conf_url}"
        elif [[ $apply_flag -eq 0 ]]; then
            publish_result="Dry-run: see above"
        else
            publish_result="Published (no URL in output)"
        fi
    fi

    # ── Summary line ───────────────────────────────────────────────────────
    local summary_parts=()
    [[ $wrote_md -eq 1 ]]   && summary_parts+=("${md_out}")
    [[ $wrote_json -eq 1 ]] && summary_parts+=("${json_out}")
    local files_summary
    IFS=' · ' eval 'files_summary="${summary_parts[*]}"'
    if [[ -n "$publish_result" ]]; then
        echo ""
        echo "Wrote: ${files_summary} · ${publish_result}"
    else
        echo ""
        echo "Wrote: ${files_summary}"
    fi

    return 0
}

# Print audit-specific help (called by --help and by _kb_cr_help).
_kb_cr_audit_help() {
    echo ""
    echo "kb-cr audit — generate a team-scoped CAB workflow audit report"
    echo ""
    echo "Usage: kb-cr audit --team <slug> [options]"
    echo ""
    echo "Options:"
    echo "  --team <slug>          REQUIRED. Team identifier (e.g. mainevent, academy)."
    echo "  --from <ISO8601>       Window start (default: first day of current month)."
    echo "  --to   <ISO8601>       Window end   (default: now)."
    echo "  --format md|json|both  Output format (default: both)."
    echo "  --out-dir <path>       Output directory (default: ./cab-audit-output/)."
    echo "  --publish-confluence   Pipe JSON through the Confluence publisher."
    echo "  --apply                With --publish-confluence: write to Confluence."
    echo "                         Without it: dry-run only (default)."
    echo "  --parent-page-id <id>  Confluence parent page for the new audit page."
    echo ""
    echo "Pipeline:"
    echo "  1. kb-cr-audit.py        — collects CR data → JSON"
    echo "  2. kb-cr-audit-render.py — renders JSON → Markdown"
    echo "  3. kb-cr-audit-publish.py (optional, --publish-confluence)"
    echo "                           — publishes to Confluence"
    echo ""
    echo "Example:"
    echo "  kb-cr audit --team mainevent --from 2026-04-01 --to 2026-05-01 \\"
    echo "               --format both --out-dir /tmp/audit"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary subcommand — XACA-0296-003 (Automation 4)
# Generates a bi-weekly markdown summary report for external stakeholders
# (e.g. Cheri Clark). Output is plain markdown — no Confluence publish.
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_summary_main() {
    local script_dir="${_KB_CR_SCRIPT_DIR}"
    local collector="${script_dir}/kb-cr-audit.py"

    if [[ ! -f "$collector" ]]; then
        echo "kb-cr summary: collector missing at scripts/kb-cr-audit.py" >&2
        return 2
    fi

    # ── Defaults ───────────────────────────────────────────────────────────
    local team="" period="2w" from_date="" to_date="" output_file="" verbose=0

    # ── Arg parse ──────────────────────────────────────────────────────────
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --team)    team="$2";        shift 2 ;;
            --period)  period="$2";      shift 2 ;;
            --from)    from_date="$2";   shift 2 ;;
            --to)      to_date="$2";     shift 2 ;;
            --output)  output_file="$2"; shift 2 ;;
            --verbose) verbose=1;        shift   ;;
            --help|-h)
                _kb_cr_summary_help
                return 0
                ;;
            *)
                echo "kb-cr summary: unknown option '$1'. Run 'kb-cr summary --help' for usage." >&2
                return 2
                ;;
        esac
    done

    # ── Required: --team ───────────────────────────────────────────────────
    if [[ -z "$team" ]]; then
        echo "kb-cr summary: --team <slug> is required." >&2
        echo "Usage: kb-cr summary --team <slug> [--period 2w] [--from <ISO8601>] [--to <ISO8601>]" >&2
        echo "                     [--output <FILE.md>] [--verbose]" >&2
        return 2
    fi

    if [[ ! "$team" =~ ^[a-z0-9_-]+$ ]]; then
        echo "kb-cr summary: --team must match [a-z0-9_-]+ (got: '$team')." >&2
        return 2
    fi

    # ── Validate --period (only when --from/--to not both supplied) ───────
    if [[ -z "$from_date" || -z "$to_date" ]]; then
        if [[ ! "$period" =~ ^[0-9]+[wd]$ ]]; then
            echo "kb-cr summary: --period must look like 2w, 4w, 7d, etc. (got: '$period')." >&2
            return 2
        fi
    fi

    # ── Build python command ───────────────────────────────────────────────
    local cmd=(python3 "$collector" summary-report --team "$team")
    [[ -n "$period" ]]    && cmd+=(--period "$period")
    [[ -n "$from_date" ]] && cmd+=(--from "$from_date")
    [[ -n "$to_date" ]]   && cmd+=(--to "$to_date")
    [[ $verbose -eq 1 ]]  && cmd+=(--verbose)

    # ── Run + emit ─────────────────────────────────────────────────────────
    local output
    output=$("${cmd[@]}")
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        return $rc
    fi

    if [[ -n "$output_file" ]]; then
        printf '%s\n' "$output" | tee "$output_file"
        echo "kb-cr summary: written → ${output_file}" >&2
    else
        printf '%s\n' "$output"
    fi

    return 0
}

_kb_cr_summary_help() {
    echo ""
    echo "kb-cr summary — bi-weekly CAB workflow summary for external stakeholders"
    echo ""
    echo "Usage: kb-cr summary --team <slug> [options]"
    echo ""
    echo "Options:"
    echo "  --team <slug>      REQUIRED. Team identifier (e.g. mainevent, academy)."
    echo "  --period <PERIOD>  Reporting window (e.g. 2w, 4w, 7d). Default: 2w."
    echo "  --from <ISO8601>   Window start (overrides --period when both --from and --to set)."
    echo "  --to   <ISO8601>   Window end   (overrides --period when both --from and --to set)."
    echo "  --output <FILE.md> Write to FILE.md AND print to stdout (tee)."
    echo "  --verbose          Enable debug output."
    echo ""
    echo "Sections in the report:"
    echo "  1. Header (period, team, generated timestamp)"
    echo "  2. Executive summary (throughput trend headline)"
    echo "  3. Throughput comparison (pre-CAB baseline vs post-CAB)"
    echo "  4. Estimate-vs-actual deploy accuracy (per-CR delta + aggregate hit rate)"
    echo "  5. Cycle-time analysis (7 segments, median + P25/P75)"
    echo "  6. Pushback patterns (rejection / hold reasons + retry count)"
    echo "  7. Volume by type (major/emergency/fyi)"
    echo "  8. Volume by approver (top approvers + median approval speed)"
    echo "  9. Footnotes"
    echo ""
    echo "Output:"
    echo "  Plain markdown — paste into email, Slack, or Confluence (no auto-publish)."
    echo ""
    echo "Example:"
    echo "  kb-cr summary --team academy --period 2w --output /tmp/cab-summary.md"
    echo "  kb-cr summary --team mainevent --from 2026-04-21 --to 2026-05-04"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Help
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_help() {
    echo ""
    echo "kb-cr — CR (Change Request) manager (v2.0 unified lifecycle — XACA-0327)"
    echo ""
    echo "Usage: kb-cr <subcommand> [args]"
    echo ""
    echo "── Container Commands (v2.0 schema) ──────────────────────────────────"
    echo "  create <title> [--type major|emergency|fyi]"
    echo "                 [--platform ios|android|firebase|crossplatform]"
    echo "                 [--summary \"text\"]"
    echo "                 [--deploy-window <YYYY-MM-DD|YYYY-MM-DDTHH:MM:SSZ>]"
    echo "              Create a new CR container record. Returns CR-ID."
    echo "              --deploy-window sets deploy_window_planned (UTC-normalized);"
    echo "              accepts date-only (padded to T00:00:00Z) or full UTC timestamp."
    echo ""
    echo "  add-item <CR-ID> <item-id>"
    echo "              Container-perspective: assign item to CR. Writes back-pointer."
    echo "  remove-item <CR-ID> <item-id>"
    echo "              Container-perspective: unassign item from CR."
    echo "  attach <item-id> --to <CR-ID>"
    echo "              Item-perspective: assign item to CR. Same as add-item but"
    echo "              inverted arguments. Refuses if item already in different CR."
    echo "  detach <item-id>"
    echo "              Item-perspective: unassign item from its CR. Resolves CR-ID"
    echo "              from item's crAssignment. Refuses if item has no crAssignment."
    echo ""
    echo "  show <CR-ID>"
    echo "              Display CR container details, items, and timestamps."
    echo "              Phase 3 (XACA-0308): also shows canonical local md path"
    echo "              (<team-kanban>/cr-docs/<ITEM-ID>-CR.md) and cr_confluence_url"
    echo "              when set. cr_doc_link is deprecated — use cr_confluence_url."
    echo "  list [--state <state>] [--platform <name>]"
    echo "              List all CRs on the board (filterable)."
    echo "  transition <CR-ID> <new-state>"
    echo "              Update crState. Does NOT write cr_*_at timestamps."
    echo "              Valid states: cr-drafted, cr-submitted, cr-approved,"
    echo "              cr-rejected, cr-held, implementing, deployed-dev,"
    echo "              deployed-prod, emergency-deployed"
    echo "  reschedule <CR-ID> <date>"
    echo "              Post-hoc setter for deploy_window_planned (UTC-normalized)."
    echo "              Valid at any crState — no state transition occurs."
    echo "              <date> accepts: YYYY-MM-DD | YYYY-MM-DDTHH:MM:SSZ | YYYY-MM-DDTHH:MMZ"
    echo "              Writes deploy_window_planned on the .crs[] record."
    echo "              Emits a cr_deploy_window_set activity-log event."
    echo "  assign-release <CR-ID> <REL-ID>  [XACA-0657]"
    echo "              Link a CR to a release. Writes all three sites atomically:"
    echo "              CR.releaseAssignment (snapshot of release name),"
    echo "              release.linkedCRs[] (snapshot of CR title),"
    echo "              manifest crIds[] (<kanban>/releases/<REL-ID>.json)."
    echo "              A CR links to AT MOST ONE release. Re-linking unlinks the old."
    echo "              Mirror of: kb-release link-cr <REL-ID> <CR-ID>"
    echo "  unassign-release <CR-ID>  [XACA-0657]"
    echo "              Remove a CR's release link. Clears all three sites."
    echo "              Mirror of: kb-release unlink-cr <REL-ID> <CR-ID>"
    echo ""
    echo "── Container Lifecycle Commands (v2.0 — state + timestamp, atomic) ──"
    echo "  NOTE: When the first argument starts with 'CR-', these subcommands"
    echo "        target the crs[] container. Lifecycle verbs passed an item-id"
    echo "        (starting with XACA/XIOS/etc.) are intercepted and routed"
    echo "        through the item's crAssignment.crId if present (propagation),"
    echo "        or fall through to the v1 per-item helper if not."
    echo ""
    echo "  submit  <CR-ID>"
    echo "              cr-drafted|cr-held|cr-rejected → cr-submitted"
    echo "              Writes timestamps.cr_submitted_at."
    echo "              'cr-submitted' means a CR-Proper Confluence page link has been"
    echo "              appended to the bottom of the CR request page (cr_proper_url set)."
    echo "              In automated workflow the Confluence poller (XACA-0328-003) triggers"
    echo "              this transition; this CLI path exists for manual/back-compat use."
    echo "  approve <CR-ID> [--approver <login>] [--approver-name \"<name>\"]"
    echo "              cr-submitted → cr-approved"
    echo "              Writes timestamps.cr_approved_at + approver{login,name}."
    echo "  reject  <CR-ID> [--reason \"<text>\"]"
    echo "              cr-submitted|cr-held → cr-rejected"
    echo "              Writes timestamps.cr_rejected_at; increments pushback_count;"
    echo "              appends reason to pushback_notes."
    echo "  hold    <CR-ID> [--reason \"<text>\"]"
    echo "              cr-submitted|cr-approved → cr-held"
    echo "              Writes timestamps.cr_held_at; appends reason to pushback_notes;"
    echo "              increments pushback_count."
    echo "  start-dev <CR-ID>"
    echo "              cr-approved → implementing"
    echo "              Writes timestamps.cr_started_dev_at."
    echo "  start-test <CR-ID>"
    echo "              implementing → (state unchanged)"
    echo "              Writes timestamps.cr_started_test_at. No state change"
    echo "              (no ready-for-test state in schema; use deploy-dev next)."
    echo "  deploy-dev <CR-ID>"
    echo "              cr-approved|implementing → deployed-dev"
    echo "              Writes timestamps.cr_deployed_dev_at."
    echo "  deploy-prod <CR-ID>"
    echo "              deployed-dev → deployed-prod (warns if skipping deployed-dev)"
    echo "              Writes timestamps.cr_deployed_prod_at."
    echo "  emergency-deploy <CR-ID> --justification \"<reason>\""
    echo "              Any state → emergency-deployed  [BREAK-GLASS — no state check]"
    echo "              --justification is REQUIRED (mandatory audit trail)."
    echo "              Writes timestamps.cr_emergency_deployed_at + emergency_justification."
    echo ""
    echo "── Backwards Lifecycle (XACA-0329 — administrative correction) ──────────"
    echo "  NOTE: revert/undo are DISTINCT from 'reject' (a CAB-process pushback)."
    echo "        Use revert/undo to correct a state-write made in error;"
    echo "        use reject to record a normal CAB rework decision."
    echo ""
    echo "  revert <CR-ID|item-id> [--to <state>] [--reason \"<text>\"]"
    echo "              Walk the CR backwards through its lifecycle. Strips"
    echo "              the timestamps + auxiliary fields owned by every state"
    echo "              with rank > target's rank, preserving the snapshot in"
    echo "              .crs[i].revert_history[] for forensic audit."
    echo "              --to defaults to the heuristic predecessor (most-recent"
    echo "                   timestamp on the container with rank < current)."
    echo "              --reason is REQUIRED when reverting from emergency-deployed."
    echo "              Forward walks (target rank ≥ current) are refused."
    echo "              Multi-item CRs propagate atomically (state lives on .crs[i])."
    echo "              pushback_count and pushback_notes are PRESERVED."
    echo "  undo   <CR-ID|item-id> [--reason \"<text>\"]"
    echo "              One-step convenience: same as 'revert' with no --to."
    echo "              The --to flag is rejected on undo; use revert for explicit targets."
    echo "  revert-history <CR-ID|item-id>"
    echo "              Read-only display of revert_history[] entries."
    echo "              Shows ts, actor, operation (revert|undo), from→to,"
    echo "              reason, stripped state list, and field-snapshot audit trail."
    echo ""
    echo "── PROPAGATION: Item-ID Lifecycle Routing ──────────────────────────────"
    echo "  When you run 'kb-cr <verb> <item-id>' (where verb is submit, approve,"
    echo "  reject, hold, start-dev, deploy-dev, deploy-prod, or start-test),"
    echo "  the dispatcher intercepts the call and checks for crAssignment.crId."
    echo ""
    echo "  If the item has crAssignment.crId=CR-XXXX:"
    echo "    → Call is transparently rewritten to 'kb-cr <verb> CR-XXXX'"
    echo "    → ALL siblings in that CR advance atomically (same state, timestamp)"
    echo "    → Diagnostic line to stderr: 'kb-cr: routing to CR-XXXX — <gerund> N items'"
    echo ""
    echo "  If the item has NO crAssignment:"
    echo "    → Falls through to v1 per-item helper (true legacy single-item CR)"
    echo "    → No propagation; only the one item's state changes"
    echo ""
    echo "  KNOWN LIMITATION: 'kb-cr complete <item-id>' does NOT propagate."
    echo "    No container variant for complete exists yet (see XACA-0327 plan)."
    echo ""
    echo "── Per-item Lifecycle Commands (v1 / legacy — argument is an item-id) ─"
    echo "  draft   <id> --type <major|emergency|fyi>"
    echo "              Create a CR draft for a backlog item. Bridges to container"
    echo "              creation: produces both .crs[] entry AND crAssignment back-pointer."
    echo "              Phase 3 (XACA-0308-002): creates canonical local doc at"
    echo "              <team-kanban>/cr-docs/<ITEM-ID>-CR.md from cr-doc-template.md."
    echo "              Idempotent: re-run leaves existing doc untouched."
    echo "              Does NOT write cr_doc_link. Confluence URL is stored separately"
    echo "              in cr_confluence_url on the .crs[] record after kb-cr publish."
    echo "  publish <id>"
    echo "              Phase 3 (XACA-0308-002): reads <team-kanban>/cr-docs/<ITEM-ID>-CR.md,"
    echo "              invokes Main Event CR skill (On-Demand Mode) to create/update"
    echo "              the Confluence page in DPD2 space, then writes the resulting URL"
    echo "              to cr_confluence_url on the .crs[] container record."
    echo "              Errors clearly if local doc is missing — run kb-cr draft first."
    echo "              Set KB_CR_PUBLISH_DRY_RUN=1 to stop before skill invocation."
    echo "              Re-run updates the existing Confluence page (URL unchanged)."
    echo "              Honors crSupport.enabled gate."
    echo "  _set_confluence_url <id> <url>"
    echo "              Internal plumbing: write cr_confluence_url directly."
    echo "              Used by the Main Event CR skill after it publishes a page."
    echo "              Records a 'confluence_published' activity log entry."
    echo "  _set_publish_stamps <id> <version> <title>"
    echo "              Guard 4 (XACA-0896-001): stamp cr_published_version /"
    echo "              cr_published_title on the .crs[] container record."
    echo "              Does NOT write cr_published_at — that lifecycle timestamp"
    echo "              lives at .crs[].timestamps.cr_published_at (XACA-0895's"
    echo "              state-advance), not here (XACA-0896-001-fix). Called by"
    echo "              kb-cr publish immediately after a successful"
    echo "              _set_confluence_url — i.e. only when a publish has"
    echo "              actually landed, never on a merely-attempted publish."
    echo "              Records a 'cr_publish_stamped' activity log entry."
    echo "  _get_publish_stamps <id>"
    echo "              Read back the publish stamps as one-line JSON:"
    echo "              {\"cr_id\":..,\"cr_published_version\":..,\"cr_published_title\":..,\"cr_published_at\":..}"
    echo "              cr_published_at is read from the NESTED"
    echo "              .crs[].timestamps.cr_published_at path — null until"
    echo "              XACA-0895 lands and writes it; no flat fallback."
    echo "              Unstamped fields come back as JSON null. For guards that"
    echo "              need to compare an incoming publish against what's live."
    echo "  submit  <id>     [propagates if crAssignment present; v1 fallback if not]"
    echo "              Submit the CR for CAB review."
    echo "              In the Confluence-driven workflow, cr-submitted means a CR-Proper"
    echo "              page link is appended to the request page (cr_proper_url populated)."
    echo "  approve <id> [--by <login>] [--name <display>]  [propagates; v1 fallback]"
    echo "              Mark CR as approved."
    echo "  reject  <id>     [propagates; v1 fallback]"
    echo "              Return the CR for rework. Increments pushback counter."
    echo "  hold    <id>     [propagates; v1 fallback]"
    echo "              Place the CR on hold (crState=cr-held)."
    echo "  start-dev <id>   [propagates; v1 fallback]"
    echo "              Record that implementation started (crState=implementing)."
    echo "  start-test <id>  [propagates; v1 fallback]"
    echo "              Record testing start timestamp (crState unchanged)."
    echo "  deploy-dev <id>  [propagates; v1 fallback]"
    echo "              Record DEV deployment (crState=deployed-dev)."
    echo "  deploy-prod <id> [propagates; v1 fallback]"
    echo "              Record PROD deployment (crState=deployed-prod)."
    echo "  emergency <id> --justification \"reason\"  [v1 only; NO propagation]"
    echo "              Record emergency deployment (crState=emergency-deployed)."
    echo "  complete <id>    [v1 only; NO propagation; no container variant]"
    echo "              Record CR lifecycle completion timestamp."
    echo "              Also run 'kb-done' to move item to completed status."
    echo "  backfill [--apply]"
    echo "              Infer crState for items with cr_* fields but no crState."
    echo "              Dry-run by default. Pass --apply to write."
    echo "  backfill --deploy-timestamps [<CR-ID>] [--apply]"
    echo "              Scrape activity logs to fill missing deployStartAt/"
    echo "              deployCompletedAt on CRs (legacy data). Dry-run by default."
    echo "  show <item-id>"
    echo "              Display CR lifecycle fields for an item. When item has"
    echo "              crAssignment, also shows sibling list from container."
    echo "              Phase 3 (XACA-0308-002): also prints local md path at"
    echo "              <team-kanban>/cr-docs/<ITEM-ID>-CR.md (exists or not)"
    echo "              and cr_confluence_url when set."
    echo ""
    echo "── Audit ─────────────────────────────────────────────────────────────────"
    echo "  audit --team <slug> [--from <ISO8601>] [--to <ISO8601>]"
    echo "        [--format md|json|both] [--out-dir <path>]"
    echo "        [--publish-confluence] [--apply] [--parent-page-id <id>]"
    echo "              Generate a team-scoped CAB workflow audit report."
    echo "              Orchestrates collector (kb-cr-audit.py),"
    echo "              renderer (kb-cr-audit-render.py), and optionally the"
    echo "              Confluence publisher (kb-cr-audit-publish.py)."
    echo ""
    echo "── Bi-weekly Summary ─────────────────────────────────────────────────"
    echo "  summary --team <slug> [--period 2w|4w|...] [--from DATE] [--to DATE]"
    echo "          [--output FILE.md] [--verbose]"
    echo "              Generate a bi-weekly summary report for external stakeholders."
    echo "              Sections: throughput, estimate accuracy, cycle time, pushback,"
    echo "              volume by type, volume by approver. Output is plain markdown."
    echo "              --team is REQUIRED. --period defaults to 2w (14 days)."
    echo "              --from and --to override --period when both supplied."
    echo "              --output writes to FILE.md AND prints to stdout (tee)."
    echo "              Exit 0 on success; exit 2 on user error; exit 1 on Python error."
    echo "              No Confluence publish — output is a local file for manual handoff."
    echo "              Defaults: --from first day of month · --to now"
    echo "                        --format both · --out-dir ./cab-audit-output/"
    echo "              --publish-confluence is dry-run unless --apply is also passed."
    echo "              Example: kb-cr audit --team mainevent --from 2026-04-01"
    echo ""
    echo "  help"
    echo "              Show this help."
    echo ""
    echo "── Phase 3 Schema (XACA-0308) ───────────────────────────────────────────"
    echo "  CANONICAL LOCAL PATH: <team-kanban>/cr-docs/<ITEM-ID>-CR.md"
    echo "    The local markdown file is the source of truth. Created by:"
    echo "      kb-cr draft <ITEM-ID> --type <major|emergency|fyi>  [subitem 002]"
    echo ""
    echo "  cr_confluence_url (NEW on crs[] records): holds the published Confluence"
    echo "    page URL after a successful kb-cr publish. Null means not yet published."
    echo "    Written by: kb-cr publish <ITEM-ID>  [subitem 002]"
    echo ""
    echo "  cr_doc_link (DEPRECATED): previously held a Confluence URL or file path."
    echo "    Removed by migrate-cr-schema-phase3.py (XACA-0308-001)."
    echo "    To run the schema migration (dry-run):"
    echo "      python3 ~/dev-team/scripts/migrate-cr-schema-phase3.py"
    echo "    To apply: add --apply (run by subitem 006 after iOS team coordination)."
    echo ""
    echo "  set-doc-link (DEPRECATED): writes cr_doc_link. Use kb-cr publish instead"
    echo "    (subitem 002). Retained until Phase 3 migration completes."
    echo ""
    echo "INVARIANT: All subcommands are no-ops when teamConfig.crSupport.enabled=false."
    echo "           Enable via SETTINGS → TEAM CONFIG → 'Enable CR (CAB) support'."
    echo ""
    echo "Timestamps use ISO 8601 UTC (e.g., 2026-05-04T18:00:00Z)."
    echo "Cycle-time fields (cr_cycle_*_days) are DERIVED at read time — never stored."
    echo ""
}
