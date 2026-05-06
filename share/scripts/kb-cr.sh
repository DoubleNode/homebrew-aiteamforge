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
        set-doc-link) _kb_cr_container_set_doc_link "$@" ;;
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
        backfill)    _kb_cr_backfill "$@" ;;
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

    # Parse args — positional title first, then flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type)     cr_type="${2:-}";   shift 2 ;;
            --type=*)   cr_type="${1#--type=}"; shift ;;
            --platform) platform="${2:-}";  shift 2 ;;
            --platform=*) platform="${1#--platform=}"; shift ;;
            --summary)  summary="${2:-}";   shift 2 ;;
            --summary=*) summary="${1#--summary=}"; shift ;;
            --help|-h)
                echo "Usage: kb-cr create <title> [--type major|emergency|fyi]"
                echo "                             [--platform ios|android|firebase|crossplatform]"
                echo "                             [--summary \"text\"]"
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
        .lastUpdated = $ts
    ' \
    --arg id       "$cr_id" \
    --arg title    "$title" \
    --arg crtype   "$cr_type" \
    --arg ts       "$ts" \
    --arg platform "$platform" \
    --arg summary  "$summary" \
    || return 1

    _kb_cr_increment_seq "$_cr_board"

    # Materialize the local source-of-truth markdown for this CR.
    # The LCARS CR-doc modal reads this file; the Confluence CR page is
    # generated FROM this document. Failure here is non-fatal — the CR
    # record is already written.
    #
    # _KB_CR_SKIP_DOC_FILE: set by _kb_cr_draft so the per-item draft path
    # can create the doc at <ITEM-ID>-CR.md (not <CR-ID>-CR.md) after it
    # knows the item_id. When this env var is non-empty, doc creation is
    # suppressed here and delegated to _kb_cr_draft.
    if [[ -z "${_KB_CR_SKIP_DOC_FILE:-}" ]]; then
        _kb_cr_create_doc_file "$_cr_board" "$cr_id" "$title" "$cr_type" "$platform" "$summary" || true
    fi

    echo "Created CR [$cr_id]: $title"
    echo "  Type:  $cr_type"
    echo "  State: cr-drafted"
    [[ -n "$platform" ]] && echo "  Platform: $platform"
    [[ -n "$summary" ]] && echo "  Summary: ${summary:0:80}"
    echo ""
    echo "  Next steps:"
    echo "    kb-cr add-item $cr_id <item-id>"
    echo "    kb-cr list"
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

    # ── Template resolution (worktree-first so Phase 3 template is used during
    #    development; falls back to main-repo and tap paths in order) ──────────
    local template=""
    # Worktree path (xaca-0308 branch — has the Phase 3 template with {{ITEM_ID}} etc.)
    if [[ -f "${HOME}/dev-team/worktrees/xaca-0308/templates/cr-doc-template.md" ]]; then
        template="${HOME}/dev-team/worktrees/xaca-0308/templates/cr-doc-template.md"
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

    local ts cr_title
    ts=$(_kb_cr_timestamp)
    cr_title=$(_kb_jq_read "$_cr_board" ".crs[$cr_idx].title" -r 2>/dev/null)

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

    # Remove item from CR's itemIds and delete crAssignment from item
    _kb_jq_update "$_cr_board" '
        .crs[$cidx].itemIds -= [$itemId] |
        .crs[$cidx].updatedAt = $ts |
        .backlog[$iidx] |= del(.crAssignment) |
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
        echo "              emergency-deployed" >&2
        return 1
    fi

    # Validate the new state against the schema's crStates list
    case "$new_state" in
        cr-drafted|cr-submitted|cr-approved|cr-rejected|cr-held|\
        implementing|deployed-dev|deployed-prod|emergency-deployed) ;;
        *)
            echo "kb-cr transition: invalid state '$new_state'." >&2
            echo "Valid states: cr-drafted, cr-submitted, cr-approved, cr-rejected," >&2
            echo "              cr-held, implementing, deployed-dev, deployed-prod," >&2
            echo "              emergency-deployed" >&2
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

    local old_state ts
    old_state=$(_kb_jq_read "$_cr_board" ".crs[$cr_idx].crState // \"\"" -r 2>/dev/null)
    ts=$(_kb_cr_timestamp)

    # NOTE: cr_*_at timestamp fields are NOT written here.
    # That is subitem 004's job (lifecycle helpers).
    _kb_jq_update "$_cr_board" '
        .crs[$cidx].crState    = $state |
        .crs[$cidx].updatedAt  = $ts |
        .lastUpdated = $ts
    ' \
    --argjson cidx  "$cr_idx" \
    --arg     state "$new_state" \
    --arg     ts    "$ts" \
    || return 1

    echo "Transitioned CR [$cr_id]: $old_state -> $new_state"
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
    _kb_cr_container_add_item "$cr_id" "$item_id" || {
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
        echo "    Expected output: Confluence URL string"
        echo "    After publish: skill must call:"
        echo "      kb-cr _set_confluence_url ${item_id} <URL>"
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
        echo ""
        return 1
    fi

    # Build the skill invocation prompt. Passes the local md path as the scope
    # source. The skill is expected to return a Confluence URL.
    local skill_prompt
    skill_prompt="$(cat <<PROMPT
/Main Event CR

Publish this CR doc to Confluence in On-Demand Mode.
Scope source: local markdown file at ${cr_doc_path}
Read the file, translate content to plain business language per skill rules,
create/update the Confluence page in DPD2 space.
If existing Confluence URL is set (${existing_confluence_url:-none}), update that page.
After publishing, output a line in EXACTLY this format:
  Confluence URL: <url>
Then run:
  kb-cr _set_confluence_url ${item_id} <url>
PROMPT
)"

    echo "kb-cr publish: Invoking Main Event CR skill..."
    echo "(Set KB_CR_PUBLISH_DRY_RUN=1 to stop here without invoking the skill)"
    echo ""

    # Invoke the skill. Capture stdout to extract the Confluence URL.
    local skill_output
    skill_output=$(printf '%s\n' "$skill_prompt" | claude --no-interactive 2>&1) || {
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
    echo "              Create a new CR container record. Returns CR-ID."
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
