#!/bin/zsh
# Agent Panel Display - Terminal-based agent info display
# Renders avatar via imgcat + agent info with ANSI formatting
# Runs in a narrow split pane, refreshes when data changes
#
# Usage: agent-panel-display.sh <session-code>
# Example: agent-panel-display.sh firebase-ops

# Disable trace mode (set -x) if inherited from parent shell.
# trace output would pollute the panel display with variable assignment lines
# like "subagent_file=..." that have nothing to do with the panel content.
{ set +x; } 2>/dev/null

SESSION_CODE="${1:?Usage: agent-panel-display.sh <session-code>}"
IMGCAT="$HOME/.iterm2/imgcat"
SCRIPT_PATH="${0:A}"
SCRIPT_DIR="${SCRIPT_PATH:h}"
SCRIPT_MTIME=$(stat -f %m "$SCRIPT_PATH" 2>/dev/null)

# Source the shared LCARS tmp dir helper to resolve per-team kanban/tmp/ directories.
# Falls back to /tmp/ if the helper is unavailable (standalone / older install).
if [[ -f "${SCRIPT_DIR}/lcars-tmp-dir.sh" ]]; then
    source "${SCRIPT_DIR}/lcars-tmp-dir.sh"
    LCARS_TMP=$(_get_lcars_tmp_dir "$SESSION_CODE")
else
    LCARS_TMP="/tmp/"
fi

JSON_BASE="${LCARS_TMP}lcars-agent-${SESSION_CODE}"
JSON_FILE="${JSON_BASE}.json"

# ── Display mode detection ─────────────────────────────────────────────────────
# iTerm2-native mode: active when $TMUX is unset (no tmux session).
# In this mode the panel runs directly in an iTerm2 split pane — no window-index
# tracking, no tmux hooks. imgcat/imgcat still works; resize uses iterm2_window_manager.py.
# Tmux mode: existing behaviour, unchanged.
if [[ -z "${TMUX:-}" ]]; then
    ITERM2_NATIVE_MODE=true
else
    ITERM2_NATIVE_MODE=false
fi

# ── Avatar directory resolution ───────────────────────────────────────────────
# Priority order for avatar files:
#   1. $AITEAMFORGE_DIR/avatars/          — flat aggregated pool (standalone install)
#   2. $AITEAMFORGE_DIR/<team>/personas/avatars/ — per-team install layout (install-team.sh)
#   3. $HOME/aiteamforge/fleet-monitor/server/public/avatars — legacy / dev-team
#
# AITEAMFORGE_DIR is read from:
#   a. $AITEAMFORGE_DIR environment variable (set by startup scripts)
#   b. install_dir from $HOME/aiteamforge/.aiteamforge-config
#   c. default: $HOME/aiteamforge
_resolve_aiteamforge_dir() {
    if [[ -n "${AITEAMFORGE_DIR:-}" ]]; then
        echo "$AITEAMFORGE_DIR"
        return
    fi
    local cfg
    for cfg in "$HOME/aiteamforge/.aiteamforge-config" "$HOME/.aiteamforge/.aiteamforge-config"; do
        if [[ -f "$cfg" ]]; then
            local dir
            dir=$(jq -r '.install_dir // empty' "$cfg" 2>/dev/null || true)
            if [[ -n "$dir" && -d "$dir" ]]; then
                echo "$dir"
                return
            fi
        fi
    done
    echo "$HOME/aiteamforge"
}

_AITEAMFORGE_DIR="$(_resolve_aiteamforge_dir)"

# Build ordered list of avatar search directories (populated after team is known)
# AVATARS_SEARCH_DIRS is set at render time once we know the team from the JSON file.
# For crew avatars (team-agnostic glob), all dirs are searched.
AVATARS_LEGACY_DIR="$_AITEAMFORGE_DIR/fleet-monitor/server/public/avatars"
AVATARS_FLAT_DIR="$_AITEAMFORGE_DIR/avatars"

# Find an avatar file by searching all known locations.
# Usage: _find_avatar <filename> [team_id]
# Returns the first matching absolute path, or empty string if not found.
_find_avatar() {
    local filename="$1"
    local team_id="${2:-}"
    # 1. Flat aggregated pool
    if [[ -f "${AVATARS_FLAT_DIR}/${filename}" ]]; then
        echo "${AVATARS_FLAT_DIR}/${filename}"
        return
    fi
    # 2. Per-team personas avatars dir (if team known)
    if [[ -n "$team_id" && -f "${_AITEAMFORGE_DIR}/${team_id}/personas/avatars/${filename}" ]]; then
        echo "${_AITEAMFORGE_DIR}/${team_id}/personas/avatars/${filename}"
        return
    fi
    # 3. Legacy fleet-monitor dir
    if [[ -f "${AVATARS_LEGACY_DIR}/${filename}" ]]; then
        echo "${AVATARS_LEGACY_DIR}/${filename}"
        return
    fi
    # Not found
    echo ""
}

# Glob for avatars matching a pattern across all known search dirs.
# Usage: _glob_avatars <pattern>  (e.g., "*_reno_avatar_panel.png")
# Outputs matching paths one per line.
_glob_avatars() {
    local pattern="$1"
    local found=()
    for dir in "$AVATARS_FLAT_DIR" "$AVATARS_LEGACY_DIR"; do
        [[ -d "$dir" ]] || continue
        local matches=(${dir}/${~pattern}(N))
        found+=("${matches[@]}")
    done
    # Also search per-team persona dirs
    if [[ -d "$_AITEAMFORGE_DIR" ]]; then
        local tdir
        for tdir in "$_AITEAMFORGE_DIR"/*/personas/avatars; do
            [[ -d "$tdir" ]] || continue
            local matches=(${tdir}/${~pattern}(N))
            found+=("${matches[@]}")
        done
    fi
    (( ${#found[@]} )) && printf '%s\n' "${found[@]}"
}
LAST_WINDOW_INDEX=""
LAST_CONTENT_FINGERPRINT=""
LAST_CREW_LIST=""

# ═══════════════════════════════════════
# SLEEP/WAKE DETECTION + STAGGERED POLLING
# ═══════════════════════════════════════
# Compute a per-panel stagger offset (0.0–1.5s) based on session code hash
# This prevents all panels from polling at the exact same instant
STAGGER_HASH=$(printf '%s' "$SESSION_CODE" | md5 | tr -cd '0-9' | cut -c1-8)
STAGGER_MOD=$(echo "$STAGGER_HASH % 150" | bc)
STAGGER_OFFSET=$(echo "scale=2; $STAGGER_MOD / 100" | bc)
SLEEP_THRESHOLD=5  # If sleep 2 takes longer than this, system was asleep

# Derive tmux socket from session code (team name is the prefix before first hyphen)
# e.g., "academy-engineering" → socket "academy", "firebase-ops" → socket "firebase"
# In iTerm2-native mode these are set but never used (tmux calls are guarded below).
TMUX_SOCKET="${SESSION_CODE%%-*}"
# Handle special cases: dns-framework sessions use "dns" socket
[[ "$TMUX_SOCKET" == "dns" ]] && true  # already correct
TMUX_CMD=(tmux -L "$TMUX_SOCKET")

# ANSI color codes
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
GOLD="\033[38;5;178m"
RED="\033[38;5;167m"
BLUE="\033[38;5;74m"
GREEN="\033[38;5;114m"
TEAL="\033[38;5;73m"
ORANGE="\033[38;5;208m"
GRAY="\033[38;5;245m"
WHITE="\033[38;5;255m"

CYAN="\033[38;5;81m"
YELLOW="\033[38;5;226m"

# Word-wrap text at word boundaries to fit within pane width.
# Usage: word_wrap "long text here" [max_width]
# Outputs wrapped lines, one per echo. Caller applies color codes per line.
word_wrap() {
    local text="$1"
    local max_width="${2:-$TARGET_COLS}"
    local line=""

    for word in ${=text}; do
        if [[ -z "$line" ]]; then
            line="$word"
        elif (( ${#line} + 1 + ${#word} <= max_width )); then
            line="$line $word"
        else
            echo "$line"
            line="$word"
        fi
    done
    [[ -n "$line" ]] && echo "$line"
}

# Print word-wrapped text with ANSI color prefix/suffix on each line.
# Usage: print_wrapped "text" "prefix_codes" "suffix_codes" [max_width]
print_wrapped() {
    local text="$1"
    local prefix="$2"
    local suffix="${3:-$RESET}"
    local max_width="${4:-$TARGET_COLS}"

    word_wrap "$text" "$max_width" | while IFS= read -r line; do
        echo "${prefix}${line}${suffix}"
    done
}

# Theme color map
get_theme_color() {
    case "${1:l}" in
        command)        echo "$RED" ;;
        operations)     echo "$GOLD" ;;
        sciences|science) echo "$TEAL" ;;
        engineering)    echo "$ORANGE" ;;
        security)       echo "$RED" ;;
        observation)    echo "$BLUE" ;;
        incident)       echo "$RED" ;;
        promenade)      echo "$GOLD" ;;
        *)              echo "$GOLD" ;;
    esac
}

# Active window file (written by tmux session-window-changed hook)
ACTIVE_WINDOW_FILE="${LCARS_TMP}lcars-active-window-${SESSION_CODE}"

if [[ "$ITERM2_NATIVE_MODE" == "false" ]]; then
    # Ensure the tmux hook is set for window-change detection
    "${TMUX_CMD[@]}" set-hook -g session-window-changed \
        "run-shell 'echo #{window_index} > ${LCARS_TMP}lcars-active-window-#{session_name}'" 2>/dev/null

    # Initialize the active-window file if it doesn't exist
    if [[ ! -f "$ACTIVE_WINDOW_FILE" ]]; then
        local_idx=$("${TMUX_CMD[@]}" list-windows -t "$SESSION_CODE" -F '#{window_active}:#{window_index}' 2>/dev/null | grep '^1:' | cut -d: -f2)
        [[ -n "$local_idx" ]] && echo "$local_idx" > "$ACTIVE_WINDOW_FILE"
    fi
fi

# Get the active tmux window index from hook-written file.
# In iTerm2-native mode returns "" — get_active_json() falls back to main JSON.
get_window_index() {
    [[ "$ITERM2_NATIVE_MODE" == "true" ]] && return
    cat "$ACTIVE_WINDOW_FILE" 2>/dev/null | tr -d '[:space:]'
}

# Get the JSON file for the currently active tmux window
get_active_json() {
    local win_idx
    win_idx=$(get_window_index)
    if [[ -n "$win_idx" ]]; then
        local win_file="${JSON_BASE}-w${win_idx}.json"
        if [[ -f "$win_file" ]]; then
            echo "$win_file"
            return
        fi
    fi
    # Fallback to main session JSON
    echo "$JSON_FILE"
}

# Read JSON field (uses RENDER_JSON_FILE set by render_panel)
json_field() {
    local jf="${RENDER_JSON_FILE:-$JSON_FILE}"
    [[ -f "$jf" ]] && jq -r ".$1 // empty" "$jf" 2>/dev/null
}

# Batch-read all panel fields in a single jq invocation.
# Returns one field per line (avoids zsh IFS collapse on consecutive tab delimiters
# which caused amb_handle to be empty when worktree was empty).
json_read_all() {
    local jf="${RENDER_JSON_FILE:-$JSON_FILE}"
    [[ -f "$jf" ]] || return
    jq -r '.team // "", .developer // "", .role // "", .location // "", .terminal // "", .terminal_desc // "", .theme // "", .avatar // "", .worktree // "", .amb_handle // ""' "$jf" 2>/dev/null
}

# Get the kanban board file path for this session
get_board_file() {
    local board_prefix="${SESSION_CODE%-*}"
    for search_dir in \
        "${_AITEAMFORGE_DIR}/kanban" \
        "/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban" \
        "/Users/Shared/Development/Main Event/MainEventApp-Android/kanban" \
        "/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban" \
        "/Users/Shared/Development/Main Event/aiteamforge/kanban" \
        "/Users/Shared/Development/DNSFramework/kanban" \
        "/Users/Shared/Development/DoubleNode/Starwords/kanban" \
        "/Users/Shared/Development/DoubleNode/appPlanning/kanban" \
        "/Users/Shared/Development/DoubleNode/WorkStats/kanban" \
        "$HOME/finance/personal/kanban" \
        "$HOME/legal/coparenting/kanban" \
        "$HOME/medical/general/kanban" \
    ; do
        local candidate="${search_dir}/${board_prefix}-board.json"
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return
        fi
    done
}

# Extract kanban info from board file via jq (returns JSON)
get_kanban_info() {
    local board_file="$1"
    local terminal_id="$2"   # e.g., "engineering"
    local window_name="$3"   # e.g., "scripts"
    [[ -z "$board_file" || ! -f "$board_file" ]] && return
    local window_id="${terminal_id}:${window_name}"
    jq -c --arg wid "$window_id" '
        (.activeWindows // []) as $wins |
        (.backlog // []) as $bl |
        ($wins | map(select(.id == $wid)) | first // null) as $aw |
        if $aw == null then {}
        else
            {task: ($aw.task // ""), win_status: ($aw.status // ""), work_mode: ($aw.workMode // "")} +
            (if $aw.workingOnId then
                ($bl | map(select(.id == $aw.workingOnId)) | first // null) as $item |
                if $item then {item_id: $item.id, item_title: $item.title, item_status: ($item.status // "")}
                else {}
                end
            else
                ($bl | map(
                    if .worktreeWindowId == $wid then
                        {item_id: .id, item_title: .title, item_status: (.status // "")}
                    elif ((.subitems // []) | map(select(.worktreeWindowId == $wid)) | length) > 0 then
                        (.subitems | map(select(.worktreeWindowId == $wid)) | first) as $sub |
                        {item_id: $sub.id, item_title: $sub.title, item_status: ($sub.status // "")}
                    else null
                    end
                ) | map(select(. != null)) | first // {})
            end)
        end
    ' "$board_file" 2>/dev/null || echo '{}'
}

# Read a field from kanban JSON result
kanban_field() {
    echo "$KANBAN_JSON" | jq -r ".$1 // empty" 2>/dev/null
}

# Get crew avatars from subagent tracking file (Task tool subagents spawned by this session)
# Supports both legacy format (["reno"]) and new expiry format ([{"type":"reno","expires":null}])
# In iTerm2-native mode (no tmux windows) falls back to session-level tracking file.
get_crew_avatars() {
    local win_idx=$(get_window_index)
    local subagent_file
    if [[ -n "$win_idx" ]]; then
        subagent_file="${LCARS_TMP}lcars-subagents-${SESSION_CODE}-w${win_idx}.json"
    else
        subagent_file="${LCARS_TMP}lcars-subagents-${SESSION_CODE}.json"
    fi
    [[ ! -f "$subagent_file" ]] && return

    # Skip stale files (>10 min old = likely orphaned)
    local file_mtime=$(stat -f %m "$subagent_file" 2>/dev/null || echo 0)
    local file_age=$(( $(date +%s) - file_mtime ))
    (( file_age > 600 )) && return

    # Extract unique agent types from tracking file
    # Handles both legacy string format and current object format
    jq -r '
        if type == "array" and length > 0 then
            map(if type == "string" then . elif type == "object" and .type then .type else empty end)
            | unique | if length > 0 then join(" ") else empty end
        else empty
        end
    ' "$subagent_file" 2>/dev/null
}

# Create composite crew avatar images (4 per row, rounded rectangle)
render_crew_strip() {
    local agents=("$@")
    local per_row=4
    local total=${#agents[@]}
    local row=0
    local idx=1  # zsh arrays are 1-indexed
    local size=40
    local radius=8
    local spacing=6

    command -v magick &>/dev/null || return

    # Clean up stale row strip files before regenerating.
    # Without this, shrinking the crew (e.g., 5→2 agents) leaves old r1.png on disk
    # and the cached display loop would show stale avatars below the current strip.
    # NOTE: Use (N) glob qualifier to avoid zsh "no matches found" error
    # when no strip files exist (zsh evaluates globs before the command runs)
    local stale_crew=(${LCARS_TMP}lcars-crew-${SESSION_CODE}-r*.png(N))
    (( ${#stale_crew[@]} )) && rm -f "${stale_crew[@]}"

    while (( idx <= total )); do
        local magick_args=()
        local row_count=0

        for (( i=idx; i <= total && i < idx+per_row; i++ )); do
            local agent="${agents[$i]}"
            # Glob across all avatar search dirs for this agent (prefer _panel.png)
            local agent_panel_lines agent_lines agent_thumb_lines
            agent_panel_lines=($(_glob_avatars "*_${agent}_avatar_panel.png"))
            agent_lines=($(_glob_avatars "*_${agent}_avatar.png"))
            agent_thumb_lines=($(_glob_avatars "*_${agent}_avatar_thumb.png"))
            local agent_files=("${agent_panel_lines[@]}")
            [[ ${#agent_files[@]} -eq 0 ]] && agent_files=("${agent_lines[@]}")
            [[ ${#agent_files[@]} -eq 0 ]] && agent_files=("${agent_thumb_lines[@]}")
            [[ ${#agent_files[@]} -eq 0 ]] && continue
            local agent_file="${agent_files[1]}"
            # Add spacer before each avatar after the first
            if (( row_count > 0 )); then
                magick_args+=(\( -size ${spacing}x${size} xc:none \))
            fi
            magick_args+=(\( "$agent_file" -resize ${size}x${size} \
                \( -size ${size}x${size} xc:black -fill white \
                   -draw "roundrectangle 0,0,$((size-1)),$((size-1)),${radius},${radius}" \) \
                -alpha off -compose CopyOpacity -composite \))
            ((row_count++))
        done

        if [[ $row_count -gt 0 ]]; then
            local crew_strip="${LCARS_TMP}lcars-crew-${SESSION_CODE}-r${row}.png"
            magick "${magick_args[@]}" +append PNG32:"$crew_strip" 2>/dev/null && \
            "$IMGCAT" -H 3 -W 100% "$crew_strip"
        fi

        (( idx += per_row ))
        (( row++ ))
    done
}

# Detect if this session is running in remote mode
is_remote_session() {
    # Check for port forward PID files for this session
    # NOTE: Use find instead of ls glob to avoid zsh "no matches found" error
    # when no .pid files exist (zsh evaluates globs before the command runs)
    local port_forward_count=$(find /tmp/lcars-port-forwards -name '*.pid' 2>/dev/null | wc -l)
    if [[ $port_forward_count -gt 0 ]]; then
        return 0  # Remote mode
    fi

    # Check for REMOTE_HOST environment variable
    if [[ -n "$REMOTE_HOST" ]]; then
        return 0  # Remote mode
    fi

    # Check for agent data sync process
    if [[ -f "/tmp/agent-data-sync-${SESSION_CODE}.pid" ]]; then
        local sync_pid=$(cat "/tmp/agent-data-sync-${SESSION_CODE}.pid" 2>/dev/null)
        if [[ -n "$sync_pid" ]] && ps -p "$sync_pid" > /dev/null 2>&1; then
            return 0  # Remote mode
        fi
    fi

    return 1  # Local mode
}

# Get remote host info if in remote mode
get_remote_host_info() {
    # Try to extract from sync PID filename or env var
    if [[ -n "$REMOTE_HOST" ]]; then
        echo "$REMOTE_HOST"
        return
    fi

    # Try to extract from port forward files
    local port_forward_file=$(find /tmp/lcars-port-forwards -name '*.pid' 2>/dev/null | head -1)
    if [[ -n "$port_forward_file" ]]; then
        # Extract hostname from filename pattern: hostname-port.pid
        local basename="${port_forward_file##*/}"
        local hostname="${basename%-*.pid}"
        echo "$hostname"
        return
    fi

    echo "remote"  # Generic fallback
}

# Compute a fingerprint of all data sources that feed the panel render.
# Uses stat (mtime+size) instead of full file reads — orders of magnitude cheaper.
# With 7+ teams × multiple panels polling every 2s, cat+md5 on 100KB kanban files
# was causing massive unnecessary I/O. stat syscalls cost almost nothing by comparison.
compute_content_fingerprint() {
    local active_json=$(get_active_json)
    local win_idx=$(get_window_index)
    local subagent_file
    if [[ -n "$win_idx" ]]; then
        subagent_file="${LCARS_TMP}lcars-subagents-${SESSION_CODE}-w${win_idx}.json"
    else
        subagent_file="${LCARS_TMP}lcars-subagents-${SESSION_CODE}.json"
    fi
    local board_file=$(get_board_file)

    # Use stat (mtime+size) instead of full file reads — orders of magnitude cheaper
    local fp=""
    if [[ -f "$active_json" ]]; then
        fp+=$(stat -f "%m:%z" "$active_json" 2>/dev/null)
    fi
    fp+="|"
    if [[ -n "$board_file" && -f "$board_file" ]]; then
        fp+=$(stat -f "%m:%z" "$board_file" 2>/dev/null)
    fi
    fp+="|"
    if [[ -f "$subagent_file" ]]; then
        fp+=$(stat -f "%m:%z" "$subagent_file" 2>/dev/null)
    fi
    fp+="|${win_idx}"

    # AMB badge cache — only check every 5 minutes (not every 2s poll cycle).
    # Uses a timestamp file per-session instead of jq parsing on every cycle.
    # This prevents 30 panels × jq invocations every 2 seconds.
    fp+="|"
    local amb_ts_file="${LCARS_TMP}lcars-amb-fpcheck-${SESSION_CODE}"
    local now_epoch=$(date +%s)
    local last_amb_check=0
    [[ -f "$amb_ts_file" ]] && last_amb_check=$(cat "$amb_ts_file" 2>/dev/null)
    if (( now_epoch - last_amb_check >= 300 )); then
        echo "$now_epoch" > "$amb_ts_file"
        # Only now do the expensive AMB cache stat lookup
        local amb_cache_glob=(${LCARS_TMP}lcars-amb-*.json(N))
        for amb_f in "${amb_cache_glob[@]}"; do
            fp+=$(stat -f "%m:%z" "$amb_f" 2>/dev/null)
        done
    fi

    echo "$fp"
}

# Fetch AMB badges for an agent handle (cached with 5-min TTL)
# Uses curl -o to write directly to file (preserves emoji UTF-8 bytes)
# Returns "ok" if badges exist, empty string if none
get_amb_badges() {
    local handle="$1"
    [[ -z "$handle" ]] && return

    local cache_file="${LCARS_TMP}lcars-amb-${handle}.json"
    local cache_ttl=300  # 5 minutes

    # Check cache freshness
    if [[ -f "$cache_file" ]]; then
        local cache_mtime=$(stat -f %m "$cache_file" 2>/dev/null || echo 0)
        local cache_age=$(( $(date +%s) - cache_mtime ))
        if (( cache_age < cache_ttl )); then
            # Cache is fresh — check if it has badges
            local count=$(jq '[.data[]?] | length' "$cache_file" 2>/dev/null)
            [[ "$count" -gt 0 ]] 2>/dev/null && echo "ok"
            return
        fi
    fi

    # Fetch from AMB API — write directly to file (not through shell variable)
    local api_url="https://dev.agentbadges.com/api/v1/agents/${handle}/patches"
    local tmp_file="${cache_file}.tmp"
    curl -s --connect-timeout 5 --max-time 10 -o "$tmp_file" "$api_url" 2>/dev/null

    if [[ -f "$tmp_file" ]] && jq -e '.data' "$tmp_file" &>/dev/null; then
        mv "$tmp_file" "$cache_file"
        local count=$(jq '[.data[]?] | length' "$cache_file" 2>/dev/null)
        [[ "$count" -gt 0 ]] 2>/dev/null && echo "ok"
    else
        rm -f "$tmp_file"
        # API failed — use stale cache if available
        if [[ -f "$cache_file" ]]; then
            local count=$(jq '[.data[]?] | length' "$cache_file" 2>/dev/null)
            [[ "$count" -gt 0 ]] 2>/dev/null && echo "ok"
        fi
    fi
}

# Render AMB badge emojis as circular Twemoji badges via imgcat (2 rows max)
# Each badge: dark circle background (#1a1a2e) with Twemoji emoji centered inside
# Extracts emoji codepoints via Python, downloads Twemoji PNGs (cached forever),
# composites circular badges via ImageMagick (cached until badge data changes)
# Also writes badge names to ${LCARS_TMP}lcars-amb-names-<handle>.txt for label rendering
render_amb_badges() {
    local handle="$1"
    local cache_file="${LCARS_TMP}lcars-amb-${handle}.json"
    [[ ! -f "$cache_file" ]] && return

    command -v magick &>/dev/null || return
    [[ ! -x "$IMGCAT" ]] && return

    local twemoji_dir="${LCARS_TMP}lcars-twemoji"
    local badge_dir="${LCARS_TMP}lcars-twemoji/badges"
    mkdir -p "$twemoji_dir" "$badge_dir"

    # Extract emoji codepoints and badge names via Python
    # Reads file as bytes to handle both raw UTF-8 emoji and JSON surrogate pair escapes
    # Output format: codepoint<TAB>name (one per line)
    local codepoints=()
    local badge_names=()
    while IFS=$'\t' read -r cp bname; do
        [[ -n "$cp" ]] && codepoints+=("$cp") && badge_names+=("$bname")
    done < <(python3 - "$cache_file" <<'PYEOF'
import json, sys
with open(sys.argv[1], 'rb') as f:
    data = json.loads(f.read())
for p in data.get('data', [])[:10]:
    emoji = p.get('emoji', '')
    name = p.get('name', '')
    if not emoji:
        continue
    cps = [f'{ord(c):x}' for c in emoji if ord(c) != 0xfe0f]
    print(f"{'-'.join(cps)}\t{name}")
PYEOF
)

    # Write badge names to file for label rendering
    local names_file="${LCARS_TMP}lcars-amb-names-${handle}.txt"
    printf '%s\n' "${badge_names[@]}" > "$names_file"

    [[ ${#codepoints[@]} -eq 0 ]] && return

    local circle_size=46    # Outer circle diameter
    local emoji_size=18     # Emoji size inside circle
    local spacing=4         # Gap between badges
    local per_row=4         # Badges per row

    # Build circular badge for each codepoint (cached per-emoji)
    local badge_files=()
    for cp in "${codepoints[@]}"; do
        local png_file="${twemoji_dir}/${cp}.png"
        local badge_file="${badge_dir}/${cp}.png"

        # Download Twemoji PNG if not cached
        if [[ ! -f "$png_file" ]]; then
            curl -s --connect-timeout 3 --max-time 5 \
                "https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/72x72/${cp}.png" \
                -o "$png_file" 2>/dev/null
            if [[ ! -f "$png_file" ]] || ! file "$png_file" 2>/dev/null | grep -q PNG; then
                rm -f "$png_file" 2>/dev/null
                continue
            fi
        fi

        # Create circular badge if not cached (or if source emoji PNG is newer)
        if [[ ! -f "$badge_file" || "$png_file" -nt "$badge_file" ]]; then
            local half=$((circle_size / 2))
            magick \
                \( -size ${circle_size}x${circle_size} xc:'#1a1a2e' \
                   -fill '#2a2a3e' -stroke '#3a3a5e' -strokewidth 1 \
                   -draw "circle ${half},${half} ${half},1" \) \
                \( "$png_file" -resize ${emoji_size}x${emoji_size} \) \
                -gravity center -composite \
                \( -size ${circle_size}x${circle_size} xc:black -fill white \
                   -draw "circle ${half},${half} ${half},0" \) \
                -alpha off -compose CopyOpacity -composite \
                PNG32:"$badge_file" 2>/dev/null || continue
        fi

        badge_files+=("$badge_file")
    done

    [[ ${#badge_files[@]} -eq 0 ]] && return

    # Composite badges into row strips (up to 2 rows)

    local total=${#badge_files[@]}
    local row=0
    local idx=1  # zsh arrays are 1-indexed

    while (( idx <= total && row < 2 )); do
        local magick_args=()
        local row_count=0

        for (( i=idx; i <= total && i < idx+per_row; i++ )); do
            if (( row_count > 0 )); then
                magick_args+=(\( -size ${spacing}x${circle_size} xc:none \))
            fi
            magick_args+=(\( "${badge_files[$i]}" \))
            ((row_count++))
        done

        if [[ $row_count -gt 0 ]]; then
            local strip_file="${LCARS_TMP}lcars-amb-strip-${handle}-r${row}.png"
            magick "${magick_args[@]}" +append PNG32:"$strip_file" 2>/dev/null
        fi

        (( idx += per_row ))
        (( row++ ))
    done
}

# Format relative timestamp from an epoch file
# Usage: format_relative_time <epoch_file> <label>
# Example output: "heartbeat 5m ago" or "last ping 2h ago"
format_relative_time() {
    local ts_file="$1"
    local label="$2"
    [[ ! -f "$ts_file" ]] && return

    local epoch=$(cat "$ts_file" 2>/dev/null)
    [[ -z "$epoch" || "$epoch" == "0" ]] && return

    local now_epoch=$(date +%s)
    local diff=$(( now_epoch - epoch ))

    if (( diff < 60 )); then
        echo "${label} just now"
    elif (( diff < 3600 )); then
        echo "${label} $(( diff / 60 ))m ago"
    elif (( diff < 86400 )); then
        echo "${label} $(( diff / 3600 ))h ago"
    else
        echo "${label} $(( diff / 86400 ))d ago"
    fi
}

# Format last heartbeat time (written by kanban-hook.py PostToolUse)
get_amb_last_heartbeat_display() {
    local handle="$1"
    format_relative_time "$HOME/.claude/.last_heartbeat_time_${handle}" "heartbeat"
}

# Format last ping time (written by amb-ping-timestamp.sh)
get_amb_last_ping_display() {
    local handle="$1"
    format_relative_time "$HOME/.claude/.last_ping_time_${handle}" "last ping"
}

render_panel() {
    # Clear screen + scrollback buffer (needed to wipe iTerm2 inline images)
    printf '\033[H\033[2J\033[3J'

    # Resolve which JSON file to read (window-specific or fallback)
    RENDER_JSON_FILE=$(get_active_json)

    # Detect remote mode and show waiting message if data not synced yet
    local is_remote=false
    local remote_host=""
    if is_remote_session; then
        is_remote=true
        remote_host=$(get_remote_host_info)
    fi

    if [[ ! -f "$RENDER_JSON_FILE" ]]; then
        echo ""
        if [[ "$is_remote" == "true" ]]; then
            echo "${DIM}  Awaiting${RESET}"
            echo "${DIM}  remote data...${RESET}"
            echo ""
            echo "${GRAY}Connecting to${RESET}"
            echo "${WHITE}${remote_host}${RESET}"
        else
            echo "${DIM}  Awaiting${RESET}"
            echo "${DIM}  agent...${RESET}"
        fi
        return
    fi

    # Batch-read all fields in ONE jq invocation (one field per line avoids zsh IFS tab collapse)
    local team developer role location terminal_name terminal_desc theme avatar worktree amb_handle
    local panel_data
    panel_data=$(json_read_all)
    if [[ -n "$panel_data" ]]; then
        {
            read -r team
            read -r developer
            read -r role
            read -r location
            read -r terminal_name
            read -r terminal_desc
            read -r theme
            read -r avatar
            read -r worktree
            read -r amb_handle
        } <<< "$panel_data"
    fi

    local TC=$(get_theme_color "$theme")

    # ═══════════════════════════════════════
    # UPPER SECTION: Avatar + Developer Info
    # ═══════════════════════════════════════

    # Display avatar image via imgcat (rounded corners)
    # Search order: _panel.png (200x200) → _avatar.png → _thumb.png fallback
    local avatar_file
    avatar_file="$(_find_avatar "${team}_${avatar}_avatar_panel.png" "$team")"
    [[ -z "$avatar_file" ]] && avatar_file="$(_find_avatar "${team}_${avatar}_avatar.png" "$team")"
    [[ -z "$avatar_file" ]] && avatar_file="$(_find_avatar "${team}_${avatar}_avatar_thumb.png" "$team")"
    if [[ -n "$avatar_file" && -x "$IMGCAT" ]]; then
        local rounded_file="${LCARS_TMP}lcars-avatar-${SESSION_CODE}-${avatar}-rounded.png"
        if command -v magick &>/dev/null; then
            # Cache: only run magick if cached file doesn't exist or source is newer
            if [[ ! -f "$rounded_file" || "$avatar_file" -nt "$rounded_file" ]]; then
                magick "$avatar_file" \
                    $([[ "$avatar_file" != *_panel.png ]] && echo "-resize 200x200") \
                    \( -size 200x200 xc:black -fill white \
                       -draw "roundrectangle 0,0,199,199,30,30" \) \
                    -alpha off -compose CopyOpacity -composite \
                    PNG32:"$rounded_file" 2>/dev/null
            fi
            [[ -f "$rounded_file" ]] && "$IMGCAT" -W 100% -H 12 "$rounded_file"
        else
            "$IMGCAT" -W 100% -H 12 "$avatar_file"
        fi
    fi

    echo ""
    print_wrapped "$developer" "${TC}${BOLD}" "${RESET}"
    print_wrapped "$role" "${TC}" "${RESET}"

    # AMB badges (optional — only for registered agents)
    # Renders as Twemoji circular badge strips via imgcat (terminal font lacks emoji glyphs)
    # Up to 2 rows of 5 badges each, cached at 3 tiers (emoji PNG, badge circle, row strip)
    # PERF: API fetch (curl/jq/python3/magick) only runs every 5 min, not every render.
    if [[ -n "$amb_handle" ]]; then
        # Throttled fetch: only call the AMB API every 5 minutes per handle.
        # The cache file mtime acts as the throttle — get_amb_badges() already checks TTL,
        # but we avoid even calling it (and its jq/stat overhead) unless TTL has expired.
        local cache_file="${LCARS_TMP}lcars-amb-${amb_handle}.json"
        local amb_needs_fetch=false
        if [[ ! -f "$cache_file" ]]; then
            amb_needs_fetch=true
        else
            local cache_mtime=$(stat -f %m "$cache_file" 2>/dev/null || echo 0)
            local cache_age=$(( $(date +%s) - cache_mtime ))
            (( cache_age >= 300 )) && amb_needs_fetch=true
        fi
        if [[ "$amb_needs_fetch" == "true" ]]; then
            get_amb_badges "$amb_handle" > /dev/null
        fi

        echo ""
        echo "${GRAY}@${amb_handle}${RESET}"
        local hb_display=$(get_amb_last_heartbeat_display "$amb_handle")
        [[ -n "$hb_display" ]] && echo "${DIM}${hb_display}${RESET}"
        local ping_display=$(get_amb_last_ping_display "$amb_handle")
        [[ -n "$ping_display" ]] && echo "${DIM}${ping_display}${RESET}"
        # Render badge row strips (cached — only regenerated when badge data changes)
        if [[ -f "$cache_file" ]]; then
            # Check staleness: regenerate if badge data is newer than row-0 strip,
            # or if names file is missing (needed for label rendering)
            local r0_strip="${LCARS_TMP}lcars-amb-strip-${amb_handle}-r0.png"
            local names_file="${LCARS_TMP}lcars-amb-names-${amb_handle}.txt"
            local r0_strip_mtime=$(stat -f %m "$r0_strip" 2>/dev/null || echo 0)
            local cache_data_mtime=$(stat -f %m "$cache_file" 2>/dev/null || echo 0)
            if [[ ! -f "$r0_strip" || ! -f "$names_file" || "$cache_data_mtime" -gt "$r0_strip_mtime" ]]; then
                render_amb_badges "$amb_handle"
            fi
            # Display badge image rows
            for row_idx in 0 1; do
                local row_strip="${LCARS_TMP}lcars-amb-strip-${amb_handle}-r${row_idx}.png"
                if [[ -f "$row_strip" && -x "$IMGCAT" ]]; then
                    "$IMGCAT" -H 3 -W 100% "$row_strip"
                fi
            done
            # List all badge names as individual lines below the images
            if [[ -f "$names_file" ]]; then
                while IFS= read -r bname; do
                    [[ -n "$bname" ]] && echo "${DIM}${bname}${RESET}"
                done < "$names_file"
            fi
        fi
    fi

    # ═══════════════════════════════════════
    # DIVIDER
    # ═══════════════════════════════════════
    echo ""
    echo "${TC}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    # ═══════════════════════════════════════
    # LOWER SECTION: Terminal Logo + Station
    # ═══════════════════════════════════════

    # Derive terminal logo from session code with fallback chain
    # Try _panel.png first, then fall back to full _logo.png
    # Full match: academy-engineering → academy_engineering_logo_panel.png
    # Team + last part: freelance-doublenode-starwords-command → freelance_command_logo_panel.png
    local logo_file=""
    local team_prefix="${SESSION_CODE%%-*}"
    local last_part="${SESSION_CODE##*-}"
    local term_part="${SESSION_CODE#*-}"
    term_part="${term_part//-/_}"
    for suffix in "_logo_panel.png" "_logo.png"; do
        # Try full match
        logo_file="$(_find_avatar "${SESSION_CODE//-/_}${suffix}" "$team_prefix")"
        [[ -n "$logo_file" ]] && break
        # Try team + last segment
        logo_file="$(_find_avatar "${team_prefix}_${last_part}${suffix}" "$team_prefix")"
        [[ -n "$logo_file" ]] && break
        # Try globbing for partial match across all avatar dirs
        local glob_lines=($(_glob_avatars "${team_prefix}_${term_part}*${suffix}"))
        if [[ ${#glob_lines[@]} -gt 0 ]]; then
            logo_file="${glob_lines[1]}"
            break
        fi
    done
    if [[ -f "$logo_file" && -x "$IMGCAT" ]]; then
        local rounded_logo="${LCARS_TMP}lcars-termlogo-${SESSION_CODE}-rounded.png"
        if command -v magick &>/dev/null; then
            # Cache: only run magick if cached file doesn't exist or source is newer
            if [[ ! -f "$rounded_logo" || "$logo_file" -nt "$rounded_logo" ]]; then
                magick "$logo_file" \
                    $([[ "$logo_file" != *_panel.png ]] && echo "-resize 200x200") \
                    \( -size 200x200 xc:black -fill white \
                       -draw "circle 100,100 100,0" \) \
                    -alpha off -compose CopyOpacity -composite \
                    PNG32:"$rounded_logo" 2>/dev/null
            fi
            [[ -f "$rounded_logo" ]] && "$IMGCAT" -W 100% -H 10 "$rounded_logo"
        else
            "$IMGCAT" -W 100% -H 10 "$logo_file"
        fi
    fi

    echo ""
    print_wrapped "$terminal_name" "${WHITE}${BOLD}" "${RESET}"
    print_wrapped "$terminal_desc" "${GRAY}" "${RESET}"

    # ═══════════════════════════════════════
    # MISSION: Current kanban item + subitems
    # ═══════════════════════════════════════
    local board_file=$(get_board_file)
    if [[ -n "$board_file" && -f "$board_file" ]]; then
        local terminal_id="${SESSION_CODE##*-}"
        KANBAN_JSON=$(get_kanban_info "$board_file" "$terminal_id" "$terminal_name")
        local item_id=$(kanban_field item_id)
        local item_title=$(kanban_field item_title)
        local task=$(kanban_field task)
        local win_status=$(kanban_field win_status)
        local work_mode=$(kanban_field work_mode)

        # Map work mode to emoji indicator
        local work_mode_indicator=""
        case "$work_mode" in
            DEV)    work_mode_indicator=" 🔧 DEV" ;;
            TEST)   work_mode_indicator=" 🧪 TEST" ;;
            REVIEW) work_mode_indicator=" 👁  REVIEW" ;;
            DEBUG)  work_mode_indicator=" 🐛 DEBUG" ;;
        esac

        if [[ -n "$item_id" || -n "$task" ]]; then
            echo ""
            echo "${TC}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
            echo "${GRAY}MISSION${RESET}"

            if [[ -n "$item_id" ]]; then
                echo "${CYAN}${BOLD}${item_id}${RESET}${YELLOW}${work_mode_indicator}${RESET}"
                print_wrapped "$item_title" "${WHITE}" "${RESET}"
            fi

            if [[ -n "$task" && "$task" != "Claude Code started" ]]; then
                echo ""
                # Status indicator
                local status_icon=""
                case "$win_status" in
                    coding)     status_icon="${GREEN}●${RESET}" ;;
                    testing)    status_icon="${YELLOW}●${RESET}" ;;
                    planning)   status_icon="${BLUE}●${RESET}" ;;
                    pr_review)  status_icon="${ORANGE}●${RESET}" ;;
                    paused)     status_icon="${RED}●${RESET}" ;;
                    *)          status_icon="${GRAY}●${RESET}" ;;
                esac
                # First line gets the status icon, remaining lines indent to match
                local first=true
                word_wrap "$task" $(( TARGET_COLS - 2 )) | while IFS= read -r line; do
                    if [[ "$first" == "true" ]]; then
                        echo "${status_icon} ${GRAY}${line}${RESET}"
                        first=false
                    else
                        echo "  ${GRAY}${line}${RESET}"
                    fi
                done
            fi
        fi
    fi

    # ═══════════════════════════════════════
    # CREW ON DECK: Subagent avatars (no text)
    # ═══════════════════════════════════════
    local crew_list=($(get_crew_avatars))
    local crew_key="${crew_list[*]}"
    if [[ ${#crew_list[@]} -gt 0 ]]; then
        echo ""
        if [[ "$crew_key" != "$LAST_CREW_LIST" ]]; then
            # Crew changed — regenerate composite strip images via ImageMagick
            LAST_CREW_LIST="$crew_key"
            render_crew_strip "${crew_list[@]}"
        else
            # Crew unchanged — redisplay cached strip images without re-running magick
            local row=0
            while [[ -f "${LCARS_TMP}lcars-crew-${SESSION_CODE}-r${row}.png" ]]; do
                "$IMGCAT" -H 3 -W 100% "${LCARS_TMP}lcars-crew-${SESSION_CODE}-r${row}.png"
                ((row++))
            done
        fi
    fi
}

# Hide cursor for clean display
tput civis 2>/dev/null

# Cleanup on exit
cleanup() {
    tput cnorm 2>/dev/null
    # Kill any child processes we spawned
    jobs -p 2>/dev/null | xargs -r kill 2>/dev/null
    exit 0
}
trap cleanup EXIT INT TERM HUP

# Font is set via the "Agent Panel" iTerm2 profile (created by iterm2_window_manager.py split-agent-panel)

# Capture initial state before render
ACTIVE_JSON=$(get_active_json)
if [[ -f "$ACTIVE_JSON" ]]; then
    LAST_MTIME=$(stat -f %m "$ACTIVE_JSON" 2>/dev/null)
else
    LAST_MTIME=""
fi
LAST_WINDOW_INDEX=$(get_window_index)
BOARD_FILE=$(get_board_file)
LAST_BOARD_MTIME=""
[[ -n "$BOARD_FILE" && -f "$BOARD_FILE" ]] && LAST_BOARD_MTIME=$(stat -f %m "$BOARD_FILE" 2>/dev/null)
LAST_SUBAGENT_MTIME=""
TARGET_COLS=30
LAST_WIDTH_CHECK=0
WINDOW_MGR="${_AITEAMFORGE_DIR}/iterm2_window_manager.py"
[[ ! -f "$WINDOW_MGR" ]] && WINDOW_MGR="${_AITEAMFORGE_DIR}/scripts/iterm2_window_manager.py"
render_panel

# Capture initial content fingerprint
LAST_CONTENT_FINGERPRINT=$(compute_content_fingerprint)

# Poll for changes (window switches, file updates, script self-update)
while true; do
    # Check if iTerm2 is still alive — exit if it died (prevents orphan processes)
    if ! pgrep -f "iTerm.app" > /dev/null 2>&1; then
        echo "iTerm2 not running — exiting agent panel display" >&2
        exit 0
    fi

    # Staggered sleep: base 2s + per-panel offset to prevent simultaneous polling
    # NOTE: no 'local' here — 'local' inside a loop at script top level causes zsh
    # to re-print the variable value on each iteration (T010 stdout-leak pattern).
    loop_start=$(date +%s)
    sleep $(echo "2 + $STAGGER_OFFSET" | bc)

    # ── Sleep/Wake Detection ──────────────────────────────
    # If the sleep took much longer than expected, the system was asleep.
    # Add a staggered wake delay so panels don't all resume at once.
    loop_elapsed=$(( $(date +%s) - loop_start ))
    if (( loop_elapsed > SLEEP_THRESHOLD )); then
        # System just woke up — stagger resume by session-unique offset (0-5s)
        wake_delay=$(echo "scale=2; ($STAGGER_OFFSET * 3) + 1" | bc)
        sleep "$wake_delay"
    fi

    # Self-restart if script file was updated on disk
    CURRENT_SCRIPT_MTIME=$(stat -f %m "$SCRIPT_PATH" 2>/dev/null)
    if [[ "$CURRENT_SCRIPT_MTIME" != "$SCRIPT_MTIME" ]]; then
        tput cnorm 2>/dev/null
        exec "$SCRIPT_PATH" "$SESSION_CODE"
    fi

    # ── Quick mtime checks (cheap) ───────────────────────
    needs_render=false

    # Check if active tmux window changed (tmux mode only — no windows in iTerm2-native mode)
    if [[ "$ITERM2_NATIVE_MODE" == "false" ]]; then
        CURRENT_WINDOW_INDEX=$(get_window_index)
        if [[ "$CURRENT_WINDOW_INDEX" != "$LAST_WINDOW_INDEX" ]]; then
            LAST_WINDOW_INDEX="$CURRENT_WINDOW_INDEX"
            ACTIVE_JSON=$(get_active_json)
            LAST_MTIME=$(stat -f %m "$ACTIVE_JSON" 2>/dev/null)
            needs_render=true
        fi
    fi

    # Check if active JSON file was modified
    if [[ "$needs_render" != "true" ]]; then
        ACTIVE_JSON=$(get_active_json)
        if [[ -f "$ACTIVE_JSON" ]]; then
            CURRENT_MTIME=$(stat -f %m "$ACTIVE_JSON" 2>/dev/null)
            if [[ "$CURRENT_MTIME" != "$LAST_MTIME" ]]; then
                LAST_MTIME="$CURRENT_MTIME"
                needs_render=true
            fi
        fi
    fi

    # Check if kanban board file was modified
    if [[ "$needs_render" != "true" && -n "$BOARD_FILE" && -f "$BOARD_FILE" ]]; then
        current_board_mtime=$(stat -f %m "$BOARD_FILE" 2>/dev/null)
        if [[ "$current_board_mtime" != "$LAST_BOARD_MTIME" ]]; then
            LAST_BOARD_MTIME="$current_board_mtime"
            needs_render=true
        fi
    fi

    # Check if subagent tracking file changed
    # In iTerm2-native mode there are no tmux windows; fall back to a session-level file.
    if [[ "$needs_render" != "true" ]]; then
        sub_win_idx=$(get_window_index)
        if [[ -n "$sub_win_idx" ]]; then
            subagent_file="${LCARS_TMP}lcars-subagents-${SESSION_CODE}-w${sub_win_idx}.json"
        else
            subagent_file="${LCARS_TMP}lcars-subagents-${SESSION_CODE}.json"
        fi
        if [[ -f "$subagent_file" ]]; then
            current_sub_mtime=$(stat -f %m "$subagent_file" 2>/dev/null)
            if [[ "$current_sub_mtime" != "$LAST_SUBAGENT_MTIME" ]]; then
                LAST_SUBAGENT_MTIME="$current_sub_mtime"
                needs_render=true
            fi
        elif [[ -n "$LAST_SUBAGENT_MTIME" ]]; then
            LAST_SUBAGENT_MTIME=""
            needs_render=true
        fi
    fi

    # ── Content fingerprint gate (skip render if data unchanged) ──
    if [[ "$needs_render" == "true" ]]; then
        current_fingerprint=$(compute_content_fingerprint)
        if [[ "$current_fingerprint" == "$LAST_CONTENT_FINGERPRINT" ]]; then
            # mtime changed but content is identical — skip the expensive render
            needs_render=false
        else
            LAST_CONTENT_FINGERPRINT="$current_fingerprint"
        fi
    fi

    # ── Render only if content actually changed ───────────
    if [[ "$needs_render" == "true" ]]; then
        render_panel
    fi

    # Enforce fixed pane width (check every ~10 seconds)
    now=$(date +%s)
    if (( now - LAST_WIDTH_CHECK >= 10 )); then
        LAST_WIDTH_CHECK=$now
        current_cols=$(tput cols 2>/dev/null)
        if [[ -n "$current_cols" && "$current_cols" != "$TARGET_COLS" ]]; then
            python3 "$WINDOW_MGR" -a resize-pane --target-cols "$TARGET_COLS" &>/dev/null
        fi
    fi
done
