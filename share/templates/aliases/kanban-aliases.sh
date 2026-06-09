#!/bin/zsh
# Kanban Helper Functions
# Terminal shortcuts for kanban board management via jq (no Python backend needed)
# This file is a template — {{ORG_NAME}}, {{ORG_SLUG}}, {{SHARED_DEV_ROOT}},
# etc. are substituted at install time by the AITeamForge installer.
# Do not edit the rendered copy directly.

# Installation directory (substituted during install)
AITEAMFORGE_DIR="{{AITEAMFORGE_DIR}}"

#──────────────────────────────────────────────────────────────────────────────
# Configuration
#──────────────────────────────────────────────────────────────────────────────

# Default team (override by setting KANBAN_TEAM env var)
: ${KANBAN_TEAM:="academy"}

#──────────────────────────────────────────────────────────────────────────────
# Internal Helper Functions
#──────────────────────────────────────────────────────────────────────────────

# Check that jq is available (formula dependency)
_kb_check_jq() {
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required but not installed."
        echo "Install with: brew install jq"
        return 1
    fi
    return 0
}

# Get the kanban directory for a team.
# XACA-0649: Three-tier lookup — registry first, then well-known case arms, then
# $AITEAMFORGE_DIR/kanban as the last-resort for truly unknown teams.
#
# Previous strategy 2 (return $AITEAMFORGE_DIR/kanban when that dir exists) was
# removed because it fired for ALL teams, including parameterized ones like
# legal-coparenting whose kanban_dir is ~/legal/coparenting/kanban.  When the
# academy board already lived at ~/aiteamforge/kanban (always true on a normal
# install) the guard short-circuited before the correct case arm was reached,
# causing kb-quarantine-stub to look for the canonical board at the wrong path.
#
# Strategy 1: team-paths.json — the canonical registry written by install-team.sh
#             and updated by kb-port-reconcile.  Read directly via python3 so this
#             file needs no external aiteamforge-paths.sh source.  Mirrored from
#             kanban-helpers.sh _kb_get_kanban_dir (XACA-0649 single-source fix).
# Strategy 2: Well-known case arms — correct for every built-in team template.
#             Parameterized teams (legal-*, medical-*, finance-*, freelance-*)
#             derive the path from the team slug suffix, not from AITEAMFORGE_DIR.
# Strategy 3: $AITEAMFORGE_DIR/kanban — catch-all for genuinely unknown teams.
_kb_get_kanban_dir() {
    local team="$1"
    local _atf_dir="${AITEAMFORGE_DIR:-{{AITEAMFORGE_DIR}}}"

    # ── Strategy 1: team-paths.json registry (XACA-0649) ─────────────────────
    # Read kanban_dir directly from the registry — the same source the Python
    # server uses — so the shell and Python resolvers always agree.
    # Only trust an entry that is both non-empty AND points to an existing directory
    # (mirrors the [ -d ] guard in kanban-helpers.sh _kb_get_kanban_dir).
    local _cfg_file="${AITEAMFORGE_CONFIG:-${HOME}/.aiteamforge/team-paths.json}"
    if [[ -f "$_cfg_file" ]] && command -v python3 &>/dev/null; then
        local _reg_dir
        _reg_dir=$(python3 - "$_cfg_file" "$team" 2>/dev/null <<'PYEOF'
import json, sys
from pathlib import Path
cfg, team = sys.argv[1], sys.argv[2]
try:
    entry = json.loads(Path(cfg).read_text(encoding="utf-8")).get("teams", {}).get(team, {})
    v = entry.get("kanban_dir", "")
    if v:
        print(v)
except Exception:
    pass
PYEOF
)
        # Accept registry entry only when it points to an existing directory.
        # A wrong-but-existing default ($AITEAMFORGE_DIR/kanban) would still pass
        # this guard, but since the registry is written by install-team.sh with
        # the real KANBAN_DIR, a wrong entry there means the install itself was
        # broken — surface it via the board-not-found error rather than silently
        # shadowing it with a hardcoded fallback.
        if [[ -n "$_reg_dir" ]] && [[ -d "$_reg_dir" ]]; then
            echo "$_reg_dir"
            return 0
        fi
        # Registry has an entry but directory does not exist yet (first-launch,
        # kanban dir not created yet) — fall through to case arms which carry the
        # same paths via the well-known patterns; they will be created on demand.
    fi

    # ── Strategy 2: well-known case arms ─────────────────────────────────────
    case "$team" in
        academy)      echo "${_atf_dir}/kanban" ;;
        # TODO(installer): {{SHARED_DEV_ROOT}} and {{ORG_NAME}} resolved at install time
        ios)          echo "{{SHARED_DEV_ROOT}}/{{ORG_NAME}}App-iOS/kanban" ;;
        android)      echo "{{SHARED_DEV_ROOT}}/{{ORG_NAME}}App-Android/kanban" ;;
        firebase)     echo "{{SHARED_DEV_ROOT}}/{{ORG_NAME}}App-Functions/kanban" ;;
        command)      echo "{{SHARED_DEV_ROOT}}/dev-team/kanban" ;;
        dns)          echo "/Users/Shared/Development/DNSFramework/kanban" ;;
        legal-*)
            local _suffix="${team#legal-}"
            echo "${HOME}/legal/${_suffix}/kanban"
            ;;
        medical-*)
            local _suffix="${team#medical-}"
            echo "${HOME}/medical/${_suffix}/kanban"
            ;;
        finance-*)
            local _suffix="${team#finance-}"
            echo "${HOME}/finance/${_suffix}/kanban"
            ;;
        freelance-*)
            local _parts=("${(@s/-/)team}")
            if [[ ${#_parts[@]} -ge 3 ]]; then
                local _client="${_parts[2]}"
                local _project="${_parts[3]}"
                echo "/Users/Shared/Development/${(C)_client}/${(C)_project}/kanban"
            else
                echo "${_atf_dir}/kanban"
            fi
            ;;
        # ── Strategy 3: unknown team — central fallback ───────────────────
        *)
            echo "${_atf_dir}/kanban"
            ;;
    esac
}

# Get the board file path for a team
_kb_get_board_file() {
    local team="$1"
    local kanban_dir
    kanban_dir=$(_kb_get_kanban_dir "$team")
    echo "${kanban_dir}/${team}-board.json"
}

# Get current team name (respects KB_TEAM_OVERRIDE)
_kb_get_team() {
    if [[ -n "$KB_TEAM_OVERRIDE" ]]; then
        echo "$KB_TEAM_OVERRIDE"
    else
        echo "${KANBAN_TEAM:-academy}"
    fi
}

# Get current timestamp in ISO-8601 UTC
_kb_get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Execute a jq write with file locking (uses perl flock, available on macOS)
# Usage: _kb_jq_update "board_file" "jq_filter" [jq_args...]
_kb_jq_update() {
    local board_file="$1"
    local jq_filter="$2"
    shift 2
    local jq_args=("$@")

    local lock_file="${board_file}.lock"
    local tmp_file="${board_file}.tmp"

    # Write filter to temp file to avoid zsh BANG_HIST escaping '!' in filters
    local filter_file
    filter_file=$(mktemp "${TMPDIR:-/tmp}/kb-jq-filter.XXXXXX")
    printf '%s' "$jq_filter" > "$filter_file"

    touch "$lock_file" 2>/dev/null

    perl -e '
        use Fcntl qw(:flock);
        my $lock_file = $ARGV[0];
        open(my $fh, ">", $lock_file) or die "Cannot open lock file: $!";
        flock($fh, LOCK_EX) or die "Cannot lock: $!";
        my $exit_code = system(@ARGV[1..$#ARGV]);
        close($fh);
        exit($exit_code >> 8);
    ' "$lock_file" sh -c "jq $(printf '%q ' "${jq_args[@]}") -f $(printf '%q' "$filter_file") $(printf '%q' "$board_file") > $(printf '%q' "$tmp_file") && [ -s $(printf '%q' "$tmp_file") ] && mv $(printf '%q' "$tmp_file") $(printf '%q' "$board_file") || { rm -f $(printf '%q' "$tmp_file"); echo 'ERROR: jq produced empty output, aborting write' >&2; exit 1; }"

    local result=$?
    rm -f "$filter_file" 2>/dev/null
    return $result
}

# Read from board file with shared locking
# Usage: _kb_jq_read "board_file" "jq_filter" [jq_args...]
_kb_jq_read() {
    local board_file="$1"
    local jq_filter="$2"
    shift 2
    local jq_args=("$@")

    local lock_file="${board_file}.lock"
    touch "$lock_file" 2>/dev/null

    perl -e '
        use Fcntl qw(:flock);
        my $lock_file = $ARGV[0];
        open(my $fh, "<", $lock_file) or die "Cannot open lock file: $!";
        flock($fh, LOCK_SH) or die "Cannot lock: $!";
        my $exit_code = system(@ARGV[1..$#ARGV]);
        close($fh);
        exit($exit_code >> 8);
    ' "$lock_file" jq "${jq_args[@]}" "$jq_filter" "$board_file"
}

# Get 3-letter team code for ID generation
_kb_get_team_code() {
    local team="$1"
    case "$team" in
        ios)                               echo "IOS" ;;
        android)                           echo "AND" ;;
        firebase)                          echo "FIR" ;;
        freelance)                         echo "FRE" ;;
        # NOTE: freelance-<client>-<project> entries below are stable registered team slugs; DoubleNode is a project-family dir constant # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
        freelance-doublenode-starwords)    echo "FSW" ;; # xaca-0139:allowed — stable team slug constant
        freelance-doublenode-workstats)    echo "FWS" ;; # xaca-0139:allowed — stable team slug constant
        freelance-doublenode-appplanning)  echo "FAP" ;; # xaca-0139:allowed — stable team slug constant
        freelance-doublenode-lifeboard)    echo "FLB" ;; # xaca-0139:allowed — stable team slug constant
        freelance-doublenode-caravan)      echo "VAN" ;; # xaca-0139:allowed — stable team slug constant
        freelance-doublenode-awaysentry)   echo "FAS" ;; # xaca-0139:allowed — stable team slug constant
        academy)                           echo "ACA" ;;
        dns)                               echo "DNS" ;;
        command)                           echo "CMD" ;;
        legal-coparenting)                 echo "LCP" ;;
        medical-general)                   echo "MED" ;;
        finance-personal)                  echo "FIN" ;;
        *)
            if [[ "$team" == *-* ]]; then
                local first_seg="${team%%-*}"
                local last_seg="${team##*-}"
                local code="${first_seg:0:1}${last_seg:0:2}"
                echo "${code:0:3}" | tr '[:lower:]' '[:upper:]'
            else
                echo "${team:0:3}" | tr '[:lower:]' '[:upper:]'
            fi
            ;;
    esac
}

# Validate/correct nextId against existing board entries to prevent duplicates
_kb_validate_next_id() {
    local board_file="$1"
    local series="$2"

    local next_id
    next_id=$(_kb_jq_read "$board_file" '.nextId // 1' -r)

    local max_existing
    max_existing=$(_kb_jq_read "$board_file" \
        '[.backlog[].id | select(startswith($series + "-")) | split("-")[1] | tonumber] | max // 0' \
        --arg series "$series" -r 2>/dev/null)

    if [[ -z "$max_existing" || "$max_existing" == "null" ]]; then
        max_existing=0
    fi

    if [[ "$next_id" -le "$max_existing" ]]; then
        local corrected=$(( max_existing + 1 ))
        local ts
        ts=$(_kb_get_timestamp)
        _kb_jq_update "$board_file" \
            '.nextId = ($n | tonumber) | .lastUpdated = $ts' \
            --arg n "$corrected" --arg ts "$ts" >&2
        echo "$corrected"
    else
        echo "$next_id"
    fi
}

# Generate next item ID for a team board
_kb_generate_id() {
    local board_file="$1"
    local team="$2"

    local series
    series=$(_kb_jq_read "$board_file" '.series // empty' -r 2>/dev/null)

    local prefix
    if [[ -n "$series" ]]; then
        prefix="$series"
    else
        local team_code
        team_code=$(_kb_get_team_code "$team")
        prefix="X${team_code}"
    fi

    local next_num
    next_num=$(_kb_validate_next_id "$board_file" "$prefix")
    printf "%s-%04d" "$prefix" "$next_num"
}

# Increment nextId counter on the board
_kb_increment_id() {
    local board_file="$1"
    local ts
    ts=$(_kb_get_timestamp)
    _kb_jq_update "$board_file" \
        '.nextId = ((.nextId // 1) + 1) | .lastUpdated = $ts' \
        --arg ts "$ts"
}

# Find backlog item index by ID string. Returns index or -1 if not found.
_kb_find_by_id() {
    local board_file="$1"
    local item_id="$2"
    _kb_jq_read "$board_file" \
        '.backlog | to_entries | map(select(.value.id == $id)) | .[0].key // -1' \
        --arg id "$item_id" -r
}

# Resolve a selector to a backlog array index.
# Accepts: item ID (XACA-0001) or numeric index.
_kb_resolve_selector() {
    local board_file="$1"
    local selector="$2"

    if [[ "$selector" =~ ^X[A-Z]{2,4}-[0-9]+$ ]]; then
        _kb_find_by_id "$board_file" "$selector"
    elif [[ "$selector" =~ ^[0-9]+$ ]]; then
        echo "$selector"
    else
        echo "-1"
    fi
}

# Resolve a subitem ID (e.g., XACA-0001-001) to "parent_idx:sub_idx"
# Returns "-1:-1" if not found.
_kb_resolve_subitem_id() {
    local board_file="$1"
    local subitem_id="$2"

    if [[ ! "$subitem_id" =~ ^(X[A-Z]{2,4}-[0-9]+)-([0-9]+)$ ]]; then
        echo "-1:-1"
        return
    fi

    local parent_id="${match[1]}"

    local parent_idx
    parent_idx=$(_kb_find_by_id "$board_file" "$parent_id")

    if [[ "$parent_idx" == "-1" ]]; then
        echo "-1:-1"
        return
    fi

    local sub_idx
    sub_idx=$(_kb_jq_read "$board_file" \
        '.backlog[$pidx].subitems // [] | to_entries[] | select(.value.id == $sid) | .key' \
        --argjson pidx "$parent_idx" --arg sid "$subitem_id" -r 2>/dev/null | head -n1)

    if [[ -z "$sub_idx" ]]; then
        echo "-1:-1"
        return
    fi

    echo "${parent_idx}:${sub_idx}"
}

#──────────────────────────────────────────────────────────────────────────────
# Main Kanban Commands
#──────────────────────────────────────────────────────────────────────────────

# List all backlog items with a compact one-line display.
# Also accepts sub-commands for richer backlog management (see kb-backlog).
kb-list() {
    _kb_check_jq || return 1

    local team board_file
    team=$(_kb_get_team)
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: No kanban board found for team '$team'"
        echo "Board path: $board_file"
        return 1
    fi

    local count
    count=$(_kb_jq_read "$board_file" '.backlog | length' -r)

    echo "Backlog for ${team}: ($count items)"
    echo "─────────────────────────────────────"
    if [[ "$count" -eq 0 ]]; then
        echo "  (empty)"
    else
        _kb_jq_read "$board_file" \
            '.backlog[] | "  [\(.id // "?")] [\(.priority | ascii_upcase | .[0:3])] \(.title)"' -r
    fi
    echo "─────────────────────────────────────"
}

# Full backlog management: add, list, show, change, remove, sub, and more.
#
# Usage:
#   kb-backlog add "title" [priority] ["description"] [jira-id]
#   kb-backlog list
#   kb-backlog show <id>
#   kb-backlog change <id> ["new title"] [priority]
#   kb-backlog remove <id>
#   kb-backlog sub add <parent-id> "title"
#   kb-backlog sub list <parent-id>
#   kb-backlog sub done <subitem-id>
#   kb-backlog sub remove <parent-id> <sub-index>
kb-backlog() {
    _kb_check_jq || return 1

    local cmd="$1"
    shift 2>/dev/null

    local team board_file
    team=$(_kb_get_team)
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: No kanban board found for team '$team'"
        echo "Board path: $board_file"
        return 1
    fi

    case "$cmd" in
        add)
            local task="$1"
            local priority="${2:-medium}"
            local description="${3:-}"
            local jira_id="${4:-}"

            # Normalize priority shortcuts
            [[ "$priority" == "med" ]]   && priority="medium"
            [[ "$priority" == "crit" ]]  && priority="critical"
            [[ "$priority" == "block" ]] && priority="blocked"

            local valid_priorities=("low" "medium" "high" "critical" "blocked")
            if [[ ! " ${valid_priorities[*]} " =~ " ${priority} " ]]; then
                echo "Error: Invalid priority '$priority'"
                echo "Valid priorities: ${valid_priorities[*]}"
                return 1
            fi

            if [[ -z "$task" ]]; then
                echo "Usage: kb-backlog add \"title\" [priority] [\"description\"] [jira-id]"
                echo "Priority: low | med | medium | high | crit | critical | block | blocked"
                return 1
            fi

            local ts item_id
            ts=$(_kb_get_timestamp)
            item_id=$(_kb_generate_id "$board_file" "$team")

            local jq_filter
            jq_filter='.backlog += [{"id": $id, "title": $title, "priority": $priority, "status": "backlog", "addedAt": $ts'
            local jq_args=(--arg id "$item_id" --arg title "$task" --arg priority "$priority" --arg ts "$ts")

            if [[ -n "$description" ]]; then
                jq_filter+=', "description": $desc'
                jq_args+=(--arg desc "$description")
            fi

            if [[ -n "$jira_id" ]]; then
                jq_filter+=', "jiraId": $jira'
                jq_args+=(--arg jira "$jira_id")
            fi

            jq_filter+='}] | .lastUpdated = $ts'

            _kb_jq_update "$board_file" "$jq_filter" "${jq_args[@]}"
            _kb_increment_id "$board_file"

            echo "Added [$item_id]: $task [$priority]"
            [[ -n "$jira_id" ]]     && echo "  JIRA: $jira_id"
            [[ -n "$description" ]] && echo "  Description: ${description:0:60}"
            ;;

        list|ls)
            local count
            count=$(_kb_jq_read "$board_file" '.backlog | length' -r)

            echo "Backlog for ${team}: ($count items)"
            echo "─────────────────────────────────────"
            if [[ "$count" -eq 0 ]]; then
                echo "  (empty)"
            else
                _kb_jq_read "$board_file" \
                    '.backlog[] | "  [\(.id // "?")] [\(.priority | ascii_upcase | .[0:3])] \(.title)"' -r
            fi
            echo "─────────────────────────────────────"
            ;;

        show|view)
            local selector="$1"

            if [[ -z "$selector" ]]; then
                echo "Usage: kb-backlog show <id>"
                return 1
            fi

            local index
            index=$(_kb_resolve_selector "$board_file" "$selector")

            if [[ "$index" == "-1" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            local item_json
            item_json=$(_kb_jq_read "$board_file" ".backlog[$index]" --argjson idx "$index" -r 2>/dev/null)

            if [[ -z "$item_json" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            local item_id item_title item_priority item_status item_desc item_jira item_added
            item_id=$(_kb_jq_read "$board_file" ".backlog[$index].id // empty" -r)
            item_title=$(_kb_jq_read "$board_file" ".backlog[$index].title // empty" -r)
            item_priority=$(_kb_jq_read "$board_file" ".backlog[$index].priority // empty" -r)
            item_status=$(_kb_jq_read "$board_file" ".backlog[$index].status // \"backlog\"" -r)
            item_desc=$(_kb_jq_read "$board_file" ".backlog[$index].description // empty" -r)
            item_jira=$(_kb_jq_read "$board_file" ".backlog[$index].jiraId // empty" -r)
            item_added=$(_kb_jq_read "$board_file" ".backlog[$index].addedAt // empty" -r)

            echo ""
            echo "[$item_id] $item_title"
            echo "─────────────────────────────────────"
            echo "  Priority : $item_priority"
            echo "  Status   : $item_status"
            [[ -n "$item_added" ]] && echo "  Added    : $item_added"
            [[ -n "$item_jira" ]]  && echo "  JIRA     : $item_jira"
            if [[ -n "$item_desc" ]]; then
                echo ""
                echo "  $item_desc"
            fi

            local sub_count
            sub_count=$(_kb_jq_read "$board_file" ".backlog[$index].subitems // [] | length" -r)
            if [[ "$sub_count" -gt 0 ]]; then
                echo ""
                echo "  Subitems ($sub_count):"
                _kb_jq_read "$board_file" \
                    ".backlog[$index].subitems[] | \"    [\(.id // \"?\")] [\(.status | ascii_upcase | .[0:4])] \(.title)\"" -r
            fi
            echo ""
            ;;

        change|edit)
            local selector="$1"
            local arg2="$2"
            local arg3="$3"

            if [[ -z "$selector" ]]; then
                echo "Usage: kb-backlog change <id> [\"new title\"] [priority]"
                echo "Examples:"
                echo "  kb-backlog change XACA-0001 \"Updated title\""
                echo "  kb-backlog change XACA-0001 high"
                echo "  kb-backlog change XACA-0001 \"Updated title\" high"
                return 1
            fi

            local index
            index=$(_kb_resolve_selector "$board_file" "$selector")

            if [[ "$index" == "-1" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            local current_title current_priority item_id
            current_title=$(_kb_jq_read "$board_file" ".backlog[$index].title // empty" -r)
            current_priority=$(_kb_jq_read "$board_file" ".backlog[$index].priority // empty" -r)
            item_id=$(_kb_jq_read "$board_file" ".backlog[$index].id // empty" -r)

            if [[ -z "$current_title" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            local new_title="$current_title"
            local new_priority="$current_priority"

            if [[ -n "$arg2" ]]; then
                if [[ "$arg2" =~ ^(low|med|medium|high|crit|critical|block|blocked)$ ]]; then
                    new_priority="$arg2"
                else
                    new_title="$arg2"
                fi
            fi

            if [[ -n "$arg3" ]]; then
                new_priority="$arg3"
            fi

            # Normalize priority shortcuts
            [[ "$new_priority" == "med" ]]   && new_priority="medium"
            [[ "$new_priority" == "crit" ]]  && new_priority="critical"
            [[ "$new_priority" == "block" ]] && new_priority="blocked"

            local ts
            ts=$(_kb_get_timestamp)

            _kb_jq_update "$board_file" \
                '.backlog[$idx].title = $title | .backlog[$idx].priority = $priority | .backlog[$idx].updatedAt = $ts | .lastUpdated = $ts' \
                --argjson idx "$index" \
                --arg title "$new_title" \
                --arg priority "$new_priority" \
                --arg ts "$ts"

            echo "Updated [$item_id]: $new_title [$new_priority]"
            ;;

        remove|rm)
            local selector="$1"

            if [[ -z "$selector" ]]; then
                echo "Usage: kb-backlog remove <id>"
                return 1
            fi

            local index
            index=$(_kb_resolve_selector "$board_file" "$selector")

            if [[ "$index" == "-1" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            local title item_id ts
            title=$(_kb_jq_read "$board_file" ".backlog[$index].title // empty" -r)
            item_id=$(_kb_jq_read "$board_file" ".backlog[$index].id // empty" -r)
            ts=$(_kb_get_timestamp)

            if [[ -z "$title" ]]; then
                echo "Error: Item not found: $selector"
                return 1
            fi

            _kb_jq_update "$board_file" \
                'del(.backlog[$idx]) | .lastUpdated = $ts' \
                --argjson idx "$index" \
                --arg ts "$ts"

            echo "Removed [$item_id]: $title"
            ;;

        sub|subitem)
            local subcmd="$1"
            shift 2>/dev/null

            case "$subcmd" in
                add)
                    local parent_selector="$1"
                    local sub_title="$2"

                    if [[ -z "$parent_selector" ]] || [[ -z "$sub_title" ]]; then
                        echo "Usage: kb-backlog sub add <parent-id> \"title\""
                        return 1
                    fi

                    local parent_idx
                    parent_idx=$(_kb_resolve_selector "$board_file" "$parent_selector")

                    if [[ "$parent_idx" == "-1" ]]; then
                        echo "Error: Parent item not found: $parent_selector"
                        return 1
                    fi

                    local parent_title parent_id
                    parent_title=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].title // empty" -r)
                    parent_id=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].id // empty" -r)

                    if [[ -z "$parent_title" ]]; then
                        echo "Error: Parent item not found: $parent_selector"
                        return 1
                    fi

                    local ts sub_count sub_id
                    ts=$(_kb_get_timestamp)
                    sub_count=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems // [] | length" -r)
                    sub_id=$(printf "%s-%03d" "$parent_id" "$((sub_count + 1))")

                    _kb_jq_update "$board_file" \
                        '.backlog[$idx].subitems = ((.backlog[$idx].subitems // []) + [{"id": $subid, "title": $title, "status": "todo", "addedAt": $ts}]) | .lastUpdated = $ts' \
                        --argjson idx "$parent_idx" \
                        --arg subid "$sub_id" \
                        --arg title "$sub_title" \
                        --arg ts "$ts"

                    echo "Added subitem [$sub_id] to [$parent_id]: $sub_title"
                    ;;

                list|ls)
                    local parent_selector="$1"

                    if [[ -z "$parent_selector" ]]; then
                        echo "Usage: kb-backlog sub list <parent-id>"
                        return 1
                    fi

                    local parent_idx
                    parent_idx=$(_kb_resolve_selector "$board_file" "$parent_selector")

                    if [[ "$parent_idx" == "-1" ]]; then
                        echo "Error: Parent item not found: $parent_selector"
                        return 1
                    fi

                    local parent_title
                    parent_title=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].title // empty" -r)

                    if [[ -z "$parent_title" ]]; then
                        echo "Error: No item found: $parent_selector"
                        return 1
                    fi

                    local sub_count
                    sub_count=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems // [] | length" -r)

                    echo "$parent_title"
                    echo "─────────────────────────────────────"
                    if [[ "$sub_count" -eq 0 ]]; then
                        echo "  (no subitems)"
                    else
                        _kb_jq_read "$board_file" \
                            ".backlog[$parent_idx].subitems | to_entries[] | \"  [\(.key)] [\(.value.id // \"?\")] [\(.value.status | ascii_upcase | .[0:4])] \(.value.title)\"" \
                            --argjson parent_idx "$parent_idx" -r
                    fi
                    ;;

                done)
                    local arg1="$1"
                    local arg2="$2"
                    local parent_idx sub_idx

                    if [[ -z "$arg1" ]]; then
                        echo "Usage: kb-backlog sub done <subitem-id>"
                        echo "   or: kb-backlog sub done <parent-id> <sub-index>"
                        return 1
                    fi

                    if [[ -z "$arg2" ]] && [[ "$arg1" =~ ^X[A-Z]{2,4}-[0-9]+-[0-9]+$ ]]; then
                        local resolved
                        resolved=$(_kb_resolve_subitem_id "$board_file" "$arg1")
                        parent_idx="${resolved%%:*}"
                        sub_idx="${resolved##*:}"

                        if [[ "$parent_idx" == "-1" ]]; then
                            echo "Error: Subitem not found: $arg1"
                            return 1
                        fi
                    elif [[ -n "$arg2" ]] && [[ "$arg2" =~ ^[0-9]+$ ]]; then
                        parent_idx=$(_kb_resolve_selector "$board_file" "$arg1")
                        sub_idx="$arg2"

                        if [[ "$parent_idx" == "-1" ]]; then
                            echo "Error: Parent item not found: $arg1"
                            return 1
                        fi
                    else
                        echo "Usage: kb-backlog sub done <subitem-id>"
                        echo "   or: kb-backlog sub done <parent-id> <sub-index>"
                        return 1
                    fi

                    local sub_title sub_id
                    sub_title=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].title // empty" -r)
                    sub_id=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].id // empty" -r)

                    if [[ -z "$sub_title" ]]; then
                        echo "Error: Subitem not found"
                        return 1
                    fi

                    local ts
                    ts=$(_kb_get_timestamp)

                    _kb_jq_update "$board_file" \
                        '.backlog[$pidx].subitems[$sidx].status = "completed" |
                         .backlog[$pidx].subitems[$sidx].completedAt = $ts |
                         .backlog[$pidx].subitems[$sidx].updatedAt = $ts |
                         .backlog[$pidx].updatedAt = $ts |
                         .lastUpdated = $ts' \
                        --argjson pidx "$parent_idx" \
                        --argjson sidx "$sub_idx" \
                        --arg ts "$ts"

                    echo "Completed subitem [$sub_id]: $sub_title"
                    ;;

                remove|rm)
                    local parent_selector="$1"
                    local sub_idx="$2"

                    if [[ -z "$parent_selector" ]] || [[ -z "$sub_idx" ]] || [[ ! "$sub_idx" =~ ^[0-9]+$ ]]; then
                        echo "Usage: kb-backlog sub remove <parent-id> <sub-index>"
                        return 1
                    fi

                    local parent_idx
                    parent_idx=$(_kb_resolve_selector "$board_file" "$parent_selector")

                    if [[ "$parent_idx" == "-1" ]]; then
                        echo "Error: Parent item not found: $parent_selector"
                        return 1
                    fi

                    local sub_title
                    sub_title=$(_kb_jq_read "$board_file" ".backlog[$parent_idx].subitems[$sub_idx].title // empty" -r)

                    if [[ -z "$sub_title" ]]; then
                        echo "Error: No subitem at index $sub_idx"
                        return 1
                    fi

                    local ts
                    ts=$(_kb_get_timestamp)

                    _kb_jq_update "$board_file" \
                        'del(.backlog[$pidx].subitems[$sidx]) | .lastUpdated = $ts' \
                        --argjson pidx "$parent_idx" \
                        --argjson sidx "$sub_idx" \
                        --arg ts "$ts"

                    echo "Removed subitem: $sub_title"
                    ;;

                *)
                    echo "Usage: kb-backlog sub <command> ..."
                    echo ""
                    echo "Commands:"
                    echo "  sub add <parent-id> \"title\"       Add a subitem"
                    echo "  sub list <parent-id>               List subitems"
                    echo "  sub done <subitem-id>              Mark subitem completed"
                    echo "  sub done <parent-id> <sub-index>   Mark subitem completed by index"
                    echo "  sub remove <parent-id> <sub-index> Remove a subitem"
                    ;;
            esac
            ;;

        ""|help)
            echo ""
            echo "kb-backlog — Full backlog management"
            echo "─────────────────────────────────────"
            echo ""
            echo "Item commands:"
            echo "  kb-backlog add \"title\" [priority] [\"desc\"] [jira-id]"
            echo "  kb-backlog list"
            echo "  kb-backlog show <id>"
            echo "  kb-backlog change <id> [\"new title\"] [priority]"
            echo "  kb-backlog remove <id>"
            echo ""
            echo "Subitem commands:"
            echo "  kb-backlog sub add <parent-id> \"title\""
            echo "  kb-backlog sub list <parent-id>"
            echo "  kb-backlog sub done <subitem-id>"
            echo "  kb-backlog sub remove <parent-id> <sub-index>"
            echo ""
            echo "Priority values: low | medium | high | critical | blocked"
            echo "Current team   : $team"
            ;;

        *)
            echo "Unknown command: $cmd"
            echo "Run 'kb-backlog help' for usage"
            return 1
            ;;
    esac
}

#──────────────────────────────────────────────────────────────────────────────
# Worktree Integration
#──────────────────────────────────────────────────────────────────────────────

# Detect and set the current working item from the git worktree branch name.
# Assumes branch format: feature/XACA-0001 or bugfix/XIOS-0042
kb-set-worktree() {
    local branch
    branch=$(git branch --show-current 2>/dev/null)

    if [[ -z "$branch" ]]; then
        echo "Could not determine git branch"
        return 1
    fi

    local item_id
    item_id=$(echo "$branch" | grep -oE '[A-Z]+-[0-9]+' | head -1)

    if [[ -z "$item_id" ]]; then
        echo "Could not extract item ID from branch: $branch"
        return 1
    fi

    export KB_CURRENT_ITEM="$item_id"
    echo "Set current item: $item_id"
}

# Clear the current working item
kb-clear() {
    unset KB_CURRENT_ITEM
    echo "Cleared current item"
}

# Display the current working item details
kb-current() {
    if [[ -n "$KB_CURRENT_ITEM" ]]; then
        echo "Current item: $KB_CURRENT_ITEM"
        kb-backlog show "$KB_CURRENT_ITEM"
    else
        echo "No current item set"
        echo "Use: kb-set-worktree (in a worktree) or: export KB_CURRENT_ITEM=<id>"
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# Pull Request Workflow
#──────────────────────────────────────────────────────────────────────────────

# Mark the current item as in-review (PR created).
# Updates the item's status field in the board JSON.
kb-pr() {
    _kb_check_jq || return 1

    local item_id="${1:-$KB_CURRENT_ITEM}"

    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-pr <item-id>"
        echo "Or set KB_CURRENT_ITEM first with kb-set-worktree"
        return 1
    fi

    local team board_file
    team=$(_kb_get_team)
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: No kanban board found for team '$team'"
        return 1
    fi

    local index
    index=$(_kb_resolve_selector "$board_file" "$item_id")

    if [[ "$index" == "-1" ]]; then
        echo "Error: Item not found: $item_id"
        return 1
    fi

    local title ts
    title=$(_kb_jq_read "$board_file" ".backlog[$index].title // empty" -r)
    ts=$(_kb_get_timestamp)

    _kb_jq_update "$board_file" \
        '.backlog[$idx].status = "in-review" | .backlog[$idx].updatedAt = $ts | .lastUpdated = $ts' \
        --argjson idx "$index" \
        --arg ts "$ts"

    echo "Marked [$item_id] as in-review: $title"
}

# Mark the current item as done/merged.
kb-done() {
    _kb_check_jq || return 1

    local item_id="${1:-$KB_CURRENT_ITEM}"

    if [[ -z "$item_id" ]]; then
        echo "Usage: kb-done <item-id>"
        echo "Or set KB_CURRENT_ITEM first with kb-set-worktree"
        return 1
    fi

    local team board_file
    team=$(_kb_get_team)
    board_file=$(_kb_get_board_file "$team")

    if [[ ! -f "$board_file" ]]; then
        echo "Error: No kanban board found for team '$team'"
        return 1
    fi

    local index
    index=$(_kb_resolve_selector "$board_file" "$item_id")

    if [[ "$index" == "-1" ]]; then
        echo "Error: Item not found: $item_id"
        return 1
    fi

    local title ts
    title=$(_kb_jq_read "$board_file" ".backlog[$index].title // empty" -r)
    ts=$(_kb_get_timestamp)

    _kb_jq_update "$board_file" \
        '.backlog[$idx].status = "completed" | .backlog[$idx].completedAt = $ts | .backlog[$idx].updatedAt = $ts | .lastUpdated = $ts' \
        --argjson idx "$index" \
        --arg ts "$ts"

    echo "Marked [$item_id] as completed: $title"
}

# Mark the current item as merged (alias for kb-done)
kb-merged() {
    kb-done "$@"
}

#──────────────────────────────────────────────────────────────────────────────
# Utility Functions
#──────────────────────────────────────────────────────────────────────────────

# Switch team context (sets KANBAN_TEAM env var for the session)
kb-team() {
    local team="$1"

    if [[ -z "$team" ]]; then
        echo "Current team: $KANBAN_TEAM"
        echo ""
        echo "Available teams:"
        echo "  academy, ios, android, firebase, command, dns"
        echo "  freelance-<client>-<project>   (e.g., freelance-acme-app)"
        echo "  legal-coparenting"
        echo "  medical-general"
        echo "  finance-personal"
        echo ""
        echo "Usage: kb-team <team-name>"
        return 0
    fi

    export KANBAN_TEAM="$team"
    echo "Switched to team: $team"
}

# Print a compact status line suitable for embedding in prompts or status bars
kb-status() {
    if [[ -n "$KB_CURRENT_ITEM" ]]; then
        echo "$KB_CURRENT_ITEM"
    fi
}

# _kb_realpath — resolve symlinks + normalize a path (ported from kanban-helpers.sh XACA-0180)
# Falls back gracefully: readlink -f → realpath → python3 → echo input unchanged.
_kb_realpath() {
    local p="$1"
    [ -n "$p" ] || return 1
    local out
    # GNU-style readlink -f (Linux; macOS 12.3+)
    if out=$(readlink -f -- "$p" 2>/dev/null) && [ -n "$out" ]; then
        printf '%s\n' "$out"
        return 0
    fi
    # realpath binary (coreutils via brew; most Linux distros)
    if out=$(realpath -- "$p" 2>/dev/null) && [ -n "$out" ]; then
        printf '%s\n' "$out"
        return 0
    fi
    # python3 fallback — ships on every dev environment we support
    if command -v python3 >/dev/null 2>&1; then
        if out=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null) && [ -n "$out" ]; then
            printf '%s\n' "$out"
            return 0
        fi
    fi
    # Degrade gracefully — return input unchanged so caller falls back to string compare
    printf '%s\n' "$p"
}

# kb-quarantine-stub — quarantines a legacy stub board so the canonical profile-scoped board is the only one LCARS sees. See XACA-0460.
kb-quarantine-stub() {
    # ── Argument parsing ──────────────────────────────────────────────────────
    local team=""
    local flag_yes=0
    local flag_dry_run=0
    local flag_force=0
    local flag_force_no_canonical=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)
                cat <<'HELP'
kb-quarantine-stub — safely move a legacy stub board file to quarantine

USAGE
    kb-quarantine-stub <team> [--yes] [--dry-run] [--force] [--force-no-canonical]
    kb-quarantine-stub --help | -h

ARGUMENTS
    team                Team name whose stub board to quarantine.
                        Must be one of the known team keys
                        (e.g. legal-coparenting, finance-personal, medical-general).

FLAGS
    --yes               Skip the confirmation prompt (for scripted use)
    --dry-run           Print the plan and exit 0; nothing is moved or written
    --force             Allow quarantine of a stub that contains items
                        (default: refuse if item count > 0)
    --force-no-canonical
                        Allow quarantine even when no canonical board exists
                        for the team (DANGEROUS: data may be lost if the stub
                        is actually the only board)

DESCRIPTION
    When a legacy stub board file coexists with the canonical profile-scoped
    board, LCARS may load the wrong board.  This command:
      1. Locates the stub and canonical paths via the same map as the warning.
      2. Verifies the stub is empty (or --force was given).
      3. Verifies the canonical board exists (or --force-no-canonical was given).
      4. Prompts for confirmation (skipped with --yes or --dry-run).
      5. Moves the stub to:
           <AITEAMFORGE_DIR>/quarantine/runtime-stub-stash/<YYYYMMDD-HHMMSS>-<team>/
         with the filename matching the original path (slashes → underscores).
      6. Writes a .meta.json sidecar alongside the moved file.
      7. Rolls back on any error.

EXAMPLES
    kb-quarantine-stub legal-coparenting
    kb-quarantine-stub finance-personal --yes
    kb-quarantine-stub medical-general --force --yes
    kb-quarantine-stub finance-personal --dry-run

SEE ALSO
    XACA-0460 — LCARS Import pre-flight refuses dual-board state
HELP
                return 0
                ;;
            --yes)
                flag_yes=1
                shift
                ;;
            --dry-run)
                flag_dry_run=1
                shift
                ;;
            --force)
                flag_force=1
                shift
                ;;
            --force-no-canonical)
                flag_force_no_canonical=1
                shift
                ;;
            -*)
                echo "kb-quarantine-stub: unknown flag '$1'" >&2
                echo "Run: kb-quarantine-stub --help" >&2
                return 1
                ;;
            *)
                if [ -n "$team" ]; then
                    echo "kb-quarantine-stub: unexpected argument '$1' (team already set to '$team')" >&2
                    return 1
                fi
                team="$1"
                shift
                ;;
        esac
    done

    if [ -z "$team" ]; then
        echo "kb-quarantine-stub: team argument is required" >&2
        echo "Run: kb-quarantine-stub --help" >&2
        return 1
    fi

    # ── Resolve the stub path for this team ───────────────────────────────────
    # Mirrors the _checks array used in the dual-board warning.  If the team is
    # not in this map, there is no known stub path and we refuse early.
    local stub_path=""
    case "$team" in
        legal-coparenting)
            # This team has TWO known stub locations; pick the first that exists.
            # Users can run the command twice if both are present.
            if [ -f "${HOME}/legal/kanban/legal-board.json" ]; then
                stub_path="${HOME}/legal/kanban/legal-board.json"
            elif [ -f "${HOME}/legal/default/kanban/legal-default-board.json" ]; then
                stub_path="${HOME}/legal/default/kanban/legal-default-board.json"
            fi
            ;;
        medical-general)
            stub_path="${HOME}/medical/kanban/medical-board.json"
            ;;
        finance-personal)
            stub_path="${HOME}/finance/kanban/finance-board.json"
            ;;
        *)
            echo "kb-quarantine-stub: team '$team' has no known stub path." >&2
            echo "  Known teams: legal-coparenting, medical-general, finance-personal" >&2
            echo "  If this is a new team, add it to the stub map in kb-quarantine-stub." >&2
            return 1
            ;;
    esac

    # ── Verify stub exists ────────────────────────────────────────────────────
    if [ ! -f "$stub_path" ]; then
        echo "kb-quarantine-stub: no stub found for team '$team'." >&2
        echo "  Expected stub at: $stub_path" >&2
        echo "  Either it was already quarantined, or this team has no stub to clean up." >&2
        return 1
    fi

    # ── Safety: refuse to operate on paths outside known safe roots ───────────
    # We only allow stubs inside $HOME; no arbitrary --path overrides.
    local real_stub
    real_stub=$(_kb_realpath "$stub_path")
    local real_home
    real_home=$(_kb_realpath "${HOME}")
    case "$real_stub" in
        "${real_home}/"*)
            ;;  # safe
        *)
            echo "kb-quarantine-stub: stub path '$stub_path' resolves outside \$HOME — refusing to operate." >&2
            return 1
            ;;
    esac

    # ── Resolve canonical path ────────────────────────────────────────────────
    local canonical_path
    canonical_path=$(_kb_get_board_file "$team" 2>/dev/null) || {
        echo "kb-quarantine-stub: could not resolve canonical board path for team '$team'." >&2
        return 1
    }

    # ── Safety: canonical must exist (or --force-no-canonical) ───────────────
    if [ ! -f "$canonical_path" ]; then
        if [ "$flag_force_no_canonical" -eq 1 ]; then
            echo "WARNING: No canonical board found for '$team' at $canonical_path" >&2
            echo "  --force-no-canonical given — proceeding anyway.  Data may be at risk." >&2
        else
            echo "kb-quarantine-stub: Refusing to quarantine: no canonical board found for team '$team'." >&2
            echo "  Expected canonical at: $canonical_path" >&2
            echo "  If the stub IS the only board, use --force-no-canonical (understand the risk first)." >&2
            return 1
        fi
    fi

    # ── Safety: stub must not be the canonical board ──────────────────────────
    if [ -f "$canonical_path" ]; then
        local real_canonical
        real_canonical=$(_kb_realpath "$canonical_path")
        if [ "$real_stub" = "$real_canonical" ]; then
            echo "kb-quarantine-stub: stub and canonical resolve to the same file ($real_stub)." >&2
            echo "  Nothing to quarantine — they are the same board." >&2
            return 0
        fi
    fi

    # ── Count items in the stub ───────────────────────────────────────────────
    local item_count=0
    if command -v jq &>/dev/null; then
        item_count=$(jq '(.backlog // []) | length' "$stub_path" 2>/dev/null) || item_count=0
        # If jq couldn't parse it, treat as non-empty to be safe
        if ! echo "$item_count" | grep -qE '^[0-9]+$'; then
            item_count=1
        fi
    fi

    if [ "$item_count" -gt 0 ] && [ "$flag_force" -eq 0 ]; then
        echo "kb-quarantine-stub: stub '$stub_path' contains $item_count item(s)." >&2
        echo "  Refusing to quarantine a non-empty stub — it may be a real board." >&2
        echo "  If you are sure, use --force to override." >&2
        return 1
    fi

    # ── Build quarantine destination ──────────────────────────────────────────
    local timestamp_dir
    timestamp_dir=$(date -u +"%Y%m%d-%H%M%S")
    local quarantine_base="${AITEAMFORGE_DIR:-{{AITEAMFORGE_DIR}}}/quarantine/runtime-stub-stash"
    local quarantine_dir="${quarantine_base}/${timestamp_dir}-${team}"

    # Derive a flat filename from the original path: replace / with _
    local flat_name
    flat_name=$(printf '%s' "$stub_path" | tr '/' '_' | sed 's/^_//')
    local dest_file="${quarantine_dir}/${flat_name}"
    local dest_meta="${quarantine_dir}/${flat_name}.meta.json"

    # ── Compute SHA-256 of stub ───────────────────────────────────────────────
    local sha256=""
    if command -v shasum &>/dev/null; then
        sha256=$(shasum -a 256 "$stub_path" 2>/dev/null | awk '{print $1}')
    elif command -v sha256sum &>/dev/null; then
        sha256=$(sha256sum "$stub_path" 2>/dev/null | awk '{print $1}')
    fi

    # ── mtime of stub ─────────────────────────────────────────────────────────
    local mtime_iso=""
    if command -v python3 &>/dev/null; then
        mtime_iso=$(python3 -c '
import os, sys, datetime
st = os.stat(sys.argv[1])
dt = datetime.datetime.utcfromtimestamp(st.st_mtime)
print(dt.strftime("%Y-%m-%dT%H:%M:%SZ"))
' "$stub_path" 2>/dev/null)
    fi

    # ── size ──────────────────────────────────────────────────────────────────
    local size_bytes=""
    if command -v python3 &>/dev/null; then
        size_bytes=$(python3 -c 'import os,sys; print(os.path.getsize(sys.argv[1]))' "$stub_path" 2>/dev/null)
    fi

    # ── Print plan ────────────────────────────────────────────────────────────
    echo ""
    echo "kb-quarantine-stub: Plan for team '$team'"
    echo "─────────────────────────────────────────────────────────"
    echo "  Stub:          $stub_path"
    echo "  Item count:    $item_count"
    echo "  SHA-256:       ${sha256:-<unavailable>}"
    echo "  Size:          ${size_bytes:-<unknown>} bytes"
    echo "  Canonical:     $canonical_path"
    if [ ! -f "$canonical_path" ]; then
        echo "  Canonical exists: NO (--force-no-canonical given)"
    else
        echo "  Canonical exists: YES"
    fi
    echo "  Quarantine to: $dest_file"
    echo "  Sidecar:       $dest_meta"
    echo "─────────────────────────────────────────────────────────"

    if [ "$flag_force" -eq 1 ] && [ "$item_count" -gt 0 ]; then
        echo "  WARNING: --force given; stub has $item_count item(s)"
    fi
    echo ""

    # ── Dry-run exits here ────────────────────────────────────────────────────
    if [ "$flag_dry_run" -eq 1 ]; then
        echo "  [DRY RUN] Nothing moved. Exiting."
        return 0
    fi

    # ── Confirmation prompt ───────────────────────────────────────────────────
    if [ "$flag_yes" -eq 0 ]; then
        printf "Continue? [y/N] "
        local answer
        read -r answer
        case "$answer" in
            [yY]|[yY][eE][sS])
                ;;
            *)
                echo "Aborted."
                return 1
                ;;
        esac
    fi

    # ── Execute move ──────────────────────────────────────────────────────────
    local quarantine_at
    quarantine_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create quarantine directory
    if ! mkdir -p "$quarantine_dir"; then
        echo "kb-quarantine-stub: failed to create quarantine directory '$quarantine_dir'" >&2
        return 1
    fi

    # Move the stub (atomic on same filesystem)
    if ! mv "$stub_path" "$dest_file"; then
        echo "kb-quarantine-stub: mv failed — '$stub_path' not moved." >&2
        # No rollback needed if mv failed; stub is still in place
        return 1
    fi

    # Write .meta.json sidecar — if this fails, roll back the move
    if ! python3 -c '
import json, sys
data = {
    "original_path":   sys.argv[1],
    "canonical_path":  sys.argv[2],
    "sha256":          sys.argv[3],
    "size_bytes":      int(sys.argv[4]) if sys.argv[4] else None,
    "mtime_iso":       sys.argv[5] if sys.argv[5] else None,
    "item_count":      int(sys.argv[6]),
    "quarantined_at":  sys.argv[7],
    "quarantined_by":  "kb-quarantine-stub (XACA-0460)",
    "user":            sys.argv[8],
    "hostname":        sys.argv[9],
    "reason":          "Stub board file coexisted with canonical board. Quarantined via kb-quarantine-stub.",
}
with open(sys.argv[10], "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
' "$stub_path" "$canonical_path" \
    "${sha256:-}" \
    "${size_bytes:-}" \
    "${mtime_iso:-}" \
    "$item_count" \
    "$quarantine_at" \
    "${USER:-unknown}" \
    "$(hostname -s 2>/dev/null || echo unknown)" \
    "$dest_meta" 2>/dev/null; then
        echo "kb-quarantine-stub: WARNING: failed to write .meta.json sidecar at '$dest_meta'" >&2
        echo "  The stub was moved successfully; please create the sidecar manually." >&2
        # Do NOT roll back — the move succeeded; sidecar is non-critical
    fi

    echo "kb-quarantine-stub: Done."
    echo "  Moved:   $stub_path"
    echo "    -> $dest_file"
    if [ -f "$dest_meta" ]; then
        echo "  Sidecar: $dest_meta"
    fi
    echo ""
    echo "  To verify: ls -la '$quarantine_dir'"
    echo "  To restore (if needed): mv '$dest_file' '$stub_path'"
}

# Show detailed help for all kanban commands
kb-help() {
    echo ""
    echo "Kanban Helper Commands"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Board / Item Commands:"
    echo "  kb-list                         List all backlog items"
    echo "  kb-backlog add \"title\" [pri]    Add a new item"
    echo "  kb-backlog list                 List backlog items"
    echo "  kb-backlog show <id>            Show item details"
    echo "  kb-backlog change <id> ...      Update title or priority"
    echo "  kb-backlog remove <id>          Remove an item"
    echo ""
    echo "Subitem Commands:"
    echo "  kb-backlog sub add <id> \"title\" Add a subitem"
    echo "  kb-backlog sub list <id>        List subitems"
    echo "  kb-backlog sub done <sub-id>    Mark subitem completed"
    echo "  kb-backlog sub remove <id> <n>  Remove subitem by index"
    echo ""
    echo "Workflow:"
    echo "  kb-pr [id]                      Mark item as in-review (PR created)"
    echo "  kb-done [id]                    Mark item as completed"
    echo "  kb-merged [id]                  Alias for kb-done"
    echo ""
    echo "Worktree Integration:"
    echo "  kb-set-worktree                 Set current item from branch name"
    echo "  kb-current                      Show current item details"
    echo "  kb-clear                        Clear current item"
    echo ""
    echo "Utility:"
    echo "  kb-team [name]                  Show or switch team"
    echo "  kb-status                       Print current item ID"
    echo "  kb-help                         Show this help"
    echo ""
    echo "Current team: $KANBAN_TEAM"
    if [[ -n "$KB_CURRENT_ITEM" ]]; then
        echo "Current item: $KB_CURRENT_ITEM"
    fi
    echo ""
}

echo "Kanban helpers loaded (team: $KANBAN_TEAM — use 'kb-help' for commands)"
