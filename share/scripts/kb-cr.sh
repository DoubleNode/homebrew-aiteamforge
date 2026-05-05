#!/usr/bin/env zsh
# kb-cr.sh — CR (Change Request) lifecycle helpers for AITeamForge kanban.
#
# Sourced by kanban-helpers.sh. Provides the kb-cr dispatcher.
#
# LOAD-BEARING INVARIANT:
#   If teamConfig.crSupport.enabled is false (or absent) on the team board,
#   ALL subcommands exit 0 with a single informational line. No reads, no writes,
#   no state transitions. This is the isolation gate for non-CR teams.
#
# Usage:
#   Container commands (v2.0):
#   kb-cr create  <title> [--type major|emergency|fyi] [--platform …] [--summary "…"]
#   kb-cr add-item     <CR-ID> <item-id>
#   kb-cr remove-item  <CR-ID> <item-id>
#   kb-cr list         [--state <state>] [--platform <name>]
#   kb-cr transition   <CR-ID> <new-state>
#   kb-cr show         <CR-ID>
#
#   Container lifecycle (v2.0 — state + timestamp, atomic — argument starts with CR-):
#   kb-cr submit  <CR-ID>
#   kb-cr approve <CR-ID> [--approver <login>] [--approver-name "<name>"]
#   kb-cr reject  <CR-ID> [--reason "<text>"]
#   kb-cr hold    <CR-ID> [--reason "<text>"]
#   kb-cr deploy-dev  <CR-ID>
#   kb-cr deploy-prod <CR-ID>
#   kb-cr emergency-deploy <CR-ID> --justification "<text>"
#
#   Per-item lifecycle (v1 / legacy — argument is an item-id):
#   kb-cr draft   <item-id> --type <major|emergency|fyi>
#   kb-cr submit  <item-id>
#   kb-cr approve <item-id> --by <login> --name <display-name>
#   kb-cr reject  <item-id>
#   kb-cr hold    <item-id>
#   kb-cr start-dev   <item-id>
#   kb-cr start-test  <item-id>
#   kb-cr deploy-dev  <item-id>
#   kb-cr deploy-prod <item-id>
#   kb-cr emergency   <item-id> --justification "text"
#   kb-cr complete    <item-id>
#   kb-cr backfill    [--apply]
#   kb-cr show        <item-id>
#   kb-cr help

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
# Container lifecycle subcommands (v2.0 schema)
# Each one: validates predecessor state → calls _kb_cr_lifecycle_advance.
# ─────────────────────────────────────────────────────────────────────────────

# kb-cr submit <CR-ID>
# Predecessor states: cr-drafted, cr-held (re-submit after hold), cr-rejected (re-submit after rework)
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

    if [[ -z "$justification" ]]; then
        echo "kb-cr emergency-deploy: --justification is required. This is the mandatory audit trail for bypassing CAB review." >&2
        echo "Usage: kb-cr emergency-deploy <CR-ID> --justification \"<reason>\"" >&2
        return 1
    fi

    local _cr_team _cr_board _cr_enabled
    _kb_cr_board_preamble || return 1
    [[ "$_cr_enabled" != "true" ]] && { _kb_cr_disabled_exit "$_cr_team"; return 0; }

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
        show)        _kb_cr_show_dispatch "$@" ;;
        # ── Lifecycle: route by ID prefix — CR-* → container, else → per-item ─
        # Container lifecycle (v2.0): argument starts with "CR-"
        # Per-item lifecycle (v1 / legacy): argument starts with item ID (e.g., XACA-…)
        submit)
            case "${1:-}" in
                CR-*) _kb_cr_container_submit "$@" ;;
                *)    _kb_cr_submit "$@" ;;
            esac ;;
        approve)
            case "${1:-}" in
                CR-*) _kb_cr_container_approve "$@" ;;
                *)    _kb_cr_approve "$@" ;;
            esac ;;
        reject)
            case "${1:-}" in
                CR-*) _kb_cr_container_reject "$@" ;;
                *)    _kb_cr_reject "$@" ;;
            esac ;;
        hold)
            case "${1:-}" in
                CR-*) _kb_cr_container_hold "$@" ;;
                *)    _kb_cr_hold "$@" ;;
            esac ;;
        deploy-dev)
            case "${1:-}" in
                CR-*) _kb_cr_container_deploy_dev "$@" ;;
                *)    _kb_cr_deploy_dev "$@" ;;
            esac ;;
        deploy-prod)
            case "${1:-}" in
                CR-*) _kb_cr_container_deploy_prod "$@" ;;
                *)    _kb_cr_deploy_prod "$@" ;;
            esac ;;
        # ── Emergency deploy (container only — no v1 equivalent with this name) ─
        emergency-deploy) _kb_cr_container_emergency_deploy "$@" ;;
        # ── Per-item only lifecycle (v1) ──────────────────────────────────────
        draft)       _kb_cr_draft "$@" ;;
        start-dev)   _kb_cr_start_dev "$@" ;;
        start-test)  _kb_cr_start_test "$@" ;;
        emergency)   _kb_cr_emergency "$@" ;;
        complete)    _kb_cr_complete "$@" ;;
        backfill)    _kb_cr_backfill "$@" ;;
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

    # Append item to CR's itemIds (de-dupe) and write crAssignment back-pointer on item
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
    [[ "$_cr_enabled" != "true" ]] && return 0

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
    echo "║ ITEMS ($item_count):"

    local items_json item_title
    items_json=$(printf '%s' "$cr_json" | jq -r '.itemIds[]? // empty')
    if [[ -z "$items_json" ]]; then
        echo "║   (no items assigned)"
    else
        while IFS= read -r iid; do
            item_title=$(_kb_jq_read "$_cr_board" \
                '.backlog[]? | select(.id == $id) | .title' \
                --arg id "$iid" -r 2>/dev/null)
            if [[ -n "$item_title" ]]; then
                printf "║   [%s] %s\n" "$iid" "${item_title:0:50}"
            else
                printf "║   [%s]\n" "$iid"
            fi
        done <<< "$items_json"
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

    local ts
    ts=$(_kb_cr_timestamp)

    # Generate cr_id: CR-<TEAM_UPPER>-<YYYYMMDD>-<item_seq>
    local date_part seq_part team_upper cr_id
    date_part=$(date -u +%Y%m%d)
    seq_part="${item_id##*-}"
    team_upper="${_cr_team:u}"
    cr_id="CR-${team_upper}-${date_part}-${seq_part}"

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
        --arg lu "$ts" \
    && echo "kb-cr: [$item_id] drafted — crState=cr-drafted, cr_id=$cr_id, cr_type=$cr_type"
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
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --apply) apply=1; shift ;;
            *) shift ;;
        esac
    done

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

    # If no cr_id set, the item has no CR lifecycle data — show nothing.
    [[ -z "$cr_id" ]] && return 0

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
}

# ─────────────────────────────────────────────────────────────────────────────
# Help
# ─────────────────────────────────────────────────────────────────────────────

_kb_cr_help() {
    echo ""
    echo "kb-cr — CR (Change Request) manager"
    echo ""
    echo "Usage: kb-cr <subcommand> [args]"
    echo ""
    echo "── Container Commands (v2.0 schema) ──────────────────────────────────"
    echo "  create <title> [--type major|emergency|fyi]"
    echo "                 [--platform ios|android|firebase|crossplatform]"
    echo "                 [--summary \"text\"]"
    echo "              Create a new CR container record."
    echo "  add-item <CR-ID> <item-id>"
    echo "              Assign a backlog item to a CR container."
    echo "  remove-item <CR-ID> <item-id>"
    echo "              Remove a backlog item from a CR container."
    echo "  show <CR-ID>"
    echo "              Display CR container details, items, and timestamps."
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
    echo "        target the crs[] container and write timestamps into"
    echo "        .crs[].timestamps.<key>. Otherwise they fall through to the"
    echo "        per-item v1 path below."
    echo ""
    echo "  submit  <CR-ID>"
    echo "              cr-drafted|cr-held|cr-rejected → cr-submitted"
    echo "              Writes timestamps.cr_submitted_at."
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
    echo "── Per-item Lifecycle Commands (v1 / legacy — argument is an item-id) ─"
    echo "  draft   <id> --type <major|emergency|fyi>"
    echo "              Create a CR draft for a backlog item."
    echo "  submit  <id>"
    echo "              Submit the CR for CAB review (per-item path)."
    echo "  approve <id> [--by <login>] [--name <display>]"
    echo "              Mark CR as approved (per-item path)."
    echo "  reject  <id>"
    echo "              Return the CR for rework. Increments pushback counter."
    echo "  hold    <id>"
    echo "              Place the CR on hold (crState=cr-held)."
    echo "  start-dev <id>"
    echo "              Record that implementation started (crState=implementing)."
    echo "  start-test <id>"
    echo "              Record testing start timestamp (crState unchanged)."
    echo "  deploy-dev <id>"
    echo "              Record DEV deployment (crState=deployed-dev)."
    echo "  deploy-prod <id>"
    echo "              Record PROD deployment (crState=deployed-prod)."
    echo "  emergency <id> --justification \"reason\""
    echo "              Record emergency deployment (crState=emergency-deployed)."
    echo "  complete <id>"
    echo "              Record CR lifecycle completion timestamp."
    echo "              Also run 'kb-done' to move item to completed status."
    echo "  backfill [--apply]"
    echo "              Infer crState for items with cr_* fields but no crState."
    echo "              Dry-run by default. Pass --apply to write."
    echo "  show <item-id>"
    echo "              Display CR lifecycle fields for an item (routes by ID prefix)."
    echo ""
    echo "  help"
    echo "              Show this help."
    echo ""
    echo "INVARIANT: All subcommands are no-ops when teamConfig.crSupport.enabled=false."
    echo "           Enable via SETTINGS → TEAM CONFIG → 'Enable CR (CAB) support'."
    echo ""
    echo "Timestamps use ISO 8601 UTC (e.g., 2026-05-04T18:00:00Z)."
    echo "Cycle-time fields (cr_cycle_*_days) are DERIVED at read time — never stored."
    echo ""
}
