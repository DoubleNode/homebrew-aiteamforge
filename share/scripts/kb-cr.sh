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
# kb-cr — main dispatcher
# ─────────────────────────────────────────────────────────────────────────────

kb-cr() {
    _kb_ensure_jq || return 1

    local subcmd="${1:-help}"
    shift 2>/dev/null

    case "$subcmd" in
        draft)       _kb_cr_draft "$@" ;;
        submit)      _kb_cr_submit "$@" ;;
        approve)     _kb_cr_approve "$@" ;;
        reject)      _kb_cr_reject "$@" ;;
        hold)        _kb_cr_hold "$@" ;;
        start-dev)   _kb_cr_start_dev "$@" ;;
        start-test)  _kb_cr_start_test "$@" ;;
        deploy-dev)  _kb_cr_deploy_dev "$@" ;;
        deploy-prod) _kb_cr_deploy_prod "$@" ;;
        emergency)   _kb_cr_emergency "$@" ;;
        complete)    _kb_cr_complete "$@" ;;
        backfill)    _kb_cr_backfill "$@" ;;
        show)        _kb_cr_show "$@" ;;
        help|--help|-h) _kb_cr_help ;;
        *)
            echo "kb-cr: unknown subcommand '$subcmd'. Run 'kb-cr help' for usage." >&2
            return 1
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Subcommand implementations
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
    echo "kb-cr — CR (Change Request) lifecycle manager"
    echo ""
    echo "Usage: kb-cr <subcommand> [args]"
    echo ""
    echo "Subcommands:"
    echo "  draft   <id> --type <major|emergency|fyi>"
    echo "              Create a CR draft for a backlog item."
    echo "  submit  <id>"
    echo "              Submit the CR for CAB review."
    echo "  approve <id> [--by <login>] [--name <display>]"
    echo "              Mark CR as approved (records approver if provided)."
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
    echo "  show    <id>"
    echo "              Display CR lifecycle fields for an item."
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
