#!/bin/zsh
# Kanban Helper Functions
# Terminal shortcuts for kanban board management via jq (no Python backend needed)

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
# Strategy 1: Read working_dir from .aiteamforge-config (authoritative)
# Strategy 2: Use $AITEAMFORGE_DIR/kanban (simple install fallback)
# Strategy 3: Well-known paths for standard teams
_kb_get_kanban_dir() {
    local team="$1"
    local _atf_dir="${AITEAMFORGE_DIR:-{{AITEAMFORGE_DIR}}}"
    local _config_file="${_atf_dir}/.aiteamforge-config"

    if [[ -f "$_config_file" ]] && command -v jq &>/dev/null; then
        local _working_dir
        _working_dir=$(jq -r --arg t "$team" ".team_paths[$t].working_dir // empty" "$_config_file" 2>/dev/null)
        if [[ -n "$_working_dir" ]]; then
            echo "${_working_dir}/kanban"
            return 0
        fi
    fi

    if [[ -d "${_atf_dir}/kanban" ]]; then
        echo "${_atf_dir}/kanban"
        return 0
    fi

    case "$team" in
        academy)      echo "${_atf_dir}/kanban" ;;
        ios)          echo "/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban" ;;
        android)      echo "/Users/Shared/Development/Main Event/MainEventApp-Android/kanban" ;;
        firebase)     echo "/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban" ;;
        command)      echo "/Users/Shared/Development/Main Event/aiteamforge/kanban" ;;
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
        freelance-doublenode-starwords)    echo "FSW" ;;
        freelance-doublenode-workstats)    echo "FWS" ;;
        freelance-doublenode-appplanning)  echo "FAP" ;;
        freelance-doublenode-lifeboard)    echo "FLB" ;;
        freelance-doublenode-caravan)      echo "VAN" ;;
        freelance-doublenode-awaysentry)   echo "FAS" ;;
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
        echo "  freelance-doublenode-starwords"
        echo "  freelance-doublenode-appplanning"
        echo "  freelance-doublenode-workstats"
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
