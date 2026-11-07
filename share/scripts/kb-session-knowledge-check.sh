#!/usr/bin/env bash
# KB Session Knowledge Check — SessionStart Hook
# Detects the current kanban item (from worktree branch or board state),
# extracts search terms, and outputs a Prior Knowledge summary.
#
# Runs AFTER kanban-session-start.py (which resolves workingOnId).
# Output goes to stdout → agent sees it as a system message.
#
# IMPORTANT: Must be fast — SessionStart hooks should complete in <5s.
# Silently exits 0 if no item detected or no knowledge found.
#
# XACA-0721: the knowledge search is now performed BY the real
# kb-knowledge-search() (zsh, in kanban-helpers.sh) so its telemetry-logging
# block fires (closing the zero-telemetry hole), while this hook still renders
# its own compact "Prior Knowledge" block. The routed search is BOUNDED to the
# N highest-signal terms to stay inside the <5s budget (see the search section).

set -euo pipefail

# XACA-1753-002: board directories come from the per-machine TEAM REGISTRY
# (the same file kanban-hooks/aiteamforge_paths.py loads: team-paths.json,
# default ~/.aiteamforge/team-paths.json, override $AITEAMFORGE_CONFIG; schema
# {"teams": {"<slug>": {"kanban_dir": "/abs/path", "team_code": "ACA", ...}}}).
# The old hardcoded per-team case arms (a fixed home-relative checkout path)
# were a real checkout only on M3Pro; everywhere else they pointed at nothing and the
# hook exited silently. A missing/unreadable registry is now REPORTED.
# bash 3.2 compatible (macOS /bin/bash): no associative arrays, no ${v^^}.
# Pure python3, no jq dependency.
_kbskc_registry_path() {
    local _p="${AITEAMFORGE_CONFIG:-}"
    [[ -n "$_p" ]] || _p="${HOME}/.aiteamforge/team-paths.json"
    case "$_p" in
        "~/"*) _p="${HOME}/${_p#"~/"}" ;;
    esac
    printf '%s' "$_p"
}

# Prints the registry's kanban_dir for a team slug.
# Return: 0 found | 1 registry readable but team has no kanban_dir (board-less
# or unregistered: a definitive answer) | 2 registry file missing |
# 3 registry present but unreadable/invalid or python3 unavailable.
_kbskc_overlay_kanban_dir() {
    local _team="$1" _ovl _rc
    _ovl="$(_kbskc_registry_path)"
    [[ -f "$_ovl" ]] || return 2
    command -v python3 &>/dev/null || return 3
    python3 - "$_ovl" "$_team" <<'PYEOF'
import json, sys
path, team = sys.argv[1], sys.argv[2]
try:
    with open(path) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(3)
teams = data.get("teams", data) if isinstance(data, dict) else None
if not isinstance(teams, dict):
    sys.exit(3)
entry = teams.get(team)
if not isinstance(entry, dict):
    sys.exit(1)
# Same absence rules as kanban-hooks/aiteamforge_paths.py (XACA-0794 board_less
# marker first, then _ABSENT_SENTINELS None/""/"null"): a board-less team is a
# definitive "no board", never a path named "null" (XACA-1753-015).
if entry.get("board_less") is True:
    sys.exit(1)
val = entry.get("kanban_dir")
if val in (None, "", "null"):
    sys.exit(1)
if not isinstance(val, str):
    sys.exit(3)
import os
print(os.path.expanduser(val))
PYEOF
}

# Reverse: 3-letter CODE -> slug via the registry's team_code fields (so
# per-client/project freelance slugs, which are registry-only, resolve).
_kbskc_overlay_code_to_slug() {
    local _code="$1" _ovl
    _ovl="$(_kbskc_registry_path)"
    [[ -f "$_ovl" ]] || return 1
    command -v python3 &>/dev/null || return 1
    python3 - "$_ovl" "$_code" <<'PYEOF'
import json, sys
path, code = sys.argv[1], sys.argv[2].upper()
try:
    with open(path) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)
teams = data.get("teams", data) if isinstance(data, dict) else None
if not isinstance(teams, dict):
    sys.exit(1)
for slug, entry in teams.items():
    if isinstance(entry, dict) and str(entry.get("team_code", "")).upper() == code:
        print(slug)
        sys.exit(0)
sys.exit(1)
PYEOF
}

# Visible, never silent: say WHY the board could not be located. Only the two
# registry-trouble codes report; code 1 (readable registry, team not in it) is
# a definitive "no board registered", not a failure to check.
_kbskc_report_nodir() {
    local _team="$1" _rc="$2"
    case "$_rc" in
        2) echo "kb-session-knowledge-check: could not check: team registry $(_kbskc_registry_path) not found (cannot resolve the kanban dir for team '${_team}'; run 'aiteamforge doctor' or set AITEAMFORGE_CONFIG)" ;;
        3) echo "kb-session-knowledge-check: could not check: team registry $(_kbskc_registry_path) is unreadable or invalid (cannot resolve the kanban dir for team '${_team}')" ;;
    esac
}

# Resolve a team's board dir from the registry. Same return codes as
# _kbskc_overlay_kanban_dir; prints the dir on success.
_get_kanban_dir() {
    _kbskc_overlay_kanban_dir "$1"
}

# --- Detect item ID from git branch ---
ITEM_ID=""
GIT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")

if [[ -n "$GIT_BRANCH" ]]; then
    # Match patterns like xaca-0012, xfsw-0007 (4 letters + 4 digits)
    if [[ "$GIT_BRANCH" =~ ([a-zA-Z]{4})-([0-9]{4}) ]]; then
        PREFIX="${BASH_REMATCH[1]}"
        NUMBER="${BASH_REMATCH[2]}"
        _PFX_UC="$(printf '%s' "$PREFIX" | tr '[:lower:]' '[:upper:]')"
        ITEM_ID="${_PFX_UC}-${NUMBER}"
    fi
fi

# If no item from branch, try board workingOnId via tmux context
if [[ -z "$ITEM_ID" ]]; then
    PANE_TARGET="${TMUX_PANE:-}"
    SESSION_NAME=""
    WINDOW_NAME=""
    if [[ -n "$PANE_TARGET" ]]; then
        SESSION_NAME=$(tmux display-message -t "$PANE_TARGET" -p '#S' 2>/dev/null || echo "")
        WINDOW_NAME=$(tmux display-message -t "$PANE_TARGET" -p '#W' 2>/dev/null || echo "main")
    else
        SESSION_NAME=$(tmux display-message -p '#S' 2>/dev/null || echo "")
        WINDOW_NAME=$(tmux display-message -p '#W' 2>/dev/null || echo "main")
    fi

    if [[ -n "$SESSION_NAME" ]]; then
        TERMINAL="${SESSION_NAME##*-}"
        WINDOW_ID="${TERMINAL}:${WINDOW_NAME}"
        TEAM="${SESSION_NAME%-*}"

        # Resolve board file path (registry; see _get_kanban_dir above)
        KANBAN_DIR=""
        _kd_rc=0
        KANBAN_DIR=$(_get_kanban_dir "$TEAM") || _kd_rc=$?
        if [[ "$_kd_rc" -ne 0 ]]; then
            _kbskc_report_nodir "$TEAM" "$_kd_rc"
            exit 0
        fi
        BOARD_FILE="${KANBAN_DIR}/${TEAM}-board.json"

        if [[ -f "$BOARD_FILE" ]] && command -v jq &>/dev/null; then
            ITEM_ID=$(jq -r --arg wid "$WINDOW_ID" \
                '(.activeWindows[] | select(.id == $wid) | .workingOnId) // ""' \
                "$BOARD_FILE" 2>/dev/null || echo "")
        fi
    fi
fi

# No item detected — exit silently
[[ -z "$ITEM_ID" ]] && exit 0

# --- Resolve team from item ID and find board ---
_get_team_from_code() {
    local id="$1"
    local code="${id:1:3}"
    # XACA-0628: codes registered in the overlay (per-client/project freelance)
    # reverse-resolve to their slug ahead of the hardcoded arms.
    local _ovl_slug
    if _ovl_slug=$(_kbskc_overlay_code_to_slug "$code") && [[ -n "$_ovl_slug" ]]; then
        echo "$_ovl_slug"
        return 0
    fi
    case "$code" in
        IOS) echo "ios" ;;
        AND) echo "android" ;;
        FIR) echo "firebase" ;;
        FRE) echo "freelance" ;;
        ACA) echo "academy" ;;
        DNS) echo "dns" ;;
        CMD) echo "command" ;;
        MEV) echo "mainevent" ;;
        LCP) echo "legal-coparenting" ;;
        MED) echo "medical" ;;
        FIN) echo "finance-personal" ;;
        SDK) echo "spacedock" ;;
        AFC) echo "richmond" ;;
        *)   echo "" ;;
    esac
}

ITEM_TEAM=$(_get_team_from_code "$ITEM_ID")
[[ -z "$ITEM_TEAM" ]] && exit 0

# Re-resolve board path for the item's team (may differ from session team)
KANBAN_DIR=""
_kd_rc=0
KANBAN_DIR=$(_get_kanban_dir "$ITEM_TEAM") || _kd_rc=$?
if [[ "$_kd_rc" -ne 0 ]]; then
    _kbskc_report_nodir "$ITEM_TEAM" "$_kd_rc"
    exit 0
fi
BOARD_FILE="${KANBAN_DIR}/${ITEM_TEAM}-board.json"

if [[ ! -f "$BOARD_FILE" ]]; then
    # Registry names a kanban_dir but its board is absent: an input is missing,
    # so say so (XACA-1753 Requirement 3) rather than exit 0 silently.
    echo "kb-session-knowledge-check: could not check: board ${BOARD_FILE} not found (team '${ITEM_TEAM}' kanban_dir from the team registry)"
    exit 0
fi

# --- Extract item title and description for search terms ---
if ! command -v jq &>/dev/null; then
    echo "kb-session-knowledge-check: could not check: jq not found on PATH (needed to read ${BOARD_FILE})"
    exit 0
fi

# Search backlog for item, including subitems (strip subitem suffix first)
PARENT_ID="$ITEM_ID"
if [[ "$ITEM_ID" =~ ^[A-Z]{4}-[0-9]{4}-[0-9]{3}$ ]]; then
    PARENT_ID="${ITEM_ID%-*}"
fi

ITEM_TITLE=$(jq -r --arg id "$PARENT_ID" \
    '(.backlog[] | select(.id == $id) | .title) // ""' \
    "$BOARD_FILE" 2>/dev/null || echo "")

ITEM_TAGS=$(jq -r --arg id "$PARENT_ID" \
    '(.backlog[] | select(.id == $id) | .tags // [] | join(" "))' \
    "$BOARD_FILE" 2>/dev/null || echo "")

# Use title + tags for search terms (description is too verbose/noisy)
RAW_TEXT="$ITEM_TITLE $ITEM_TAGS"

# If we have no text to search with, exit
[[ -z "${RAW_TEXT// /}" ]] && exit 0

# --- Extract search terms ---
# Remove stopwords and common verbs, keep meaningful keywords (3+ chars)
SEARCH_TERMS=$(echo "$RAW_TEXT" | tr '[:upper:]' '[:lower:]' | \
    # Replace non-alphanumeric with spaces
    sed 's/[^a-z0-9]/ /g' | \
    # Collapse whitespace
    tr -s ' ' | sed 's/^ //;s/ $//' | \
    # Split to words, filter stopwords and short words, rejoin
    tr ' ' '\n' | grep -vxE '(add|fix|update|implement|create|remove|delete|change|modify|refactor|move|make|use|set|get|the|a|an|and|or|for|to|in|of|on|is|it|be|as|at|by|from|with|that|this|into|not|all|new|when|which|where|how|what|so|if|its|our|has|had|have|can|will|should|does|do|been|are|was|were|being|each|every|also|just|more|than|very|but|only|other|some|any|no|then|up|out|about|after|before|over|between|through|during|without|within|across|current|based|using|ensure|run|output|detect|rather|requiring|agent|agents|remember|makes|soft|enforcement|audit|effortless|summary|relevant|terms|state|working|support|existing|system|enable|check|include)' | \
    awk 'length >= 3' | \
    tr '\n' ' ' | sed 's/ $//')

[[ -z "$SEARCH_TERMS" ]] && exit 0

# --- Route the search through the REAL kb-knowledge-search() (XACA-0721) ---
# WHY: the hook previously ran its OWN private grep, so kb-knowledge-search()'s
# telemetry block never fired for the single most common knowledge read (session
# start) — a zero-telemetry hole in the usage audit. We now call the real zsh
# function so each query logs a row to kanban-logs/kb-search.jsonl, while STILL
# rendering our own compact "Prior Knowledge" block (we deliberately do NOT dump
# the function's verbose boxed native output into the session).
#
# BUDGET (the key constraint): the function is ~0.3-1.6s/term even after the
# XACA-0721 subitem-4 batching optimization. Routing all ~18 extracted terms
# (~1s each) would blow the <5s SessionStart budget, so we CAP to the N
# highest-signal terms. Heuristic: dedup, then sort LONGEST-FIRST (longer words
# are rarer / more specific => higher signal), take the top N; prepend the
# ITEM_ID itself, since an exact-ticket match is the strongest signal of all
# (scored 10 below, mirroring the pre-XACA-0721 behavior). Measured on this
# machine: ITEM_ID + 5 terms = 6 calls in a single zsh process ≈ 2.5s, leaving
# comfortable headroom under 5s. Tune via KB_HOOK_MAX_TERMS.
KB_HOOK_MAX_TERMS="${KB_HOOK_MAX_TERMS:-5}"

PICKED_TERMS=()
while IFS= read -r _pt; do
    [[ -n "$_pt" ]] && PICKED_TERMS+=("$_pt")
done < <(
    printf '%s\n' $SEARCH_TERMS \
      | awk 'NF && !seen[$0]++' \
      | awk '{print length"\t"$0}' \
      | sort -rn -k1,1 \
      | awk -v n="$KB_HOOK_MAX_TERMS" 'NR<=n+0' \
      | cut -f2-
)

# kb-knowledge-search lives in kanban-helpers.sh (zsh-only). The COMMITTED hook
# sources the canonical PRODUCTION copy via the shared resolver (aitf-root.sh) — that is
# where the optimized function lands after merge. Tests override KB_HELPERS_PATH
# to point at a worktree copy, so they exercise the optimized function rather
# than main/develop's slower one.
# XACA-1753: located via the shared resolver; a miss is reported, not silent.
HELPERS="${KB_HELPERS_PATH:-}"
_AITF_SELF="${BASH_SOURCE[0]:-$0}"
_AITF_SELF="$(readlink -f "$_AITF_SELF" 2>/dev/null || printf '%s' "$_AITF_SELF")"
_AITF_LIB="$(dirname "$_AITF_SELF")/aitf-root.sh"
_LOOKED="$_AITF_LIB (aitf-root.sh missing)"
if [[ -f "$_AITF_LIB" ]]; then
    . "$_AITF_LIB"
    aitf_init "$_AITF_SELF"
    [[ -n "$HELPERS" ]] || { aitf_locate kanban-helpers.sh || true; HELPERS="$AITF_FOUND"; }
    _LOOKED="${HELPERS:-$AITF_LOOKED}"
fi
if [[ -z "$HELPERS" || ! -f "$HELPERS" ]]; then
    echo "kb-session-knowledge-check: could not check: kanban-helpers.sh not found (looked in $_LOOKED)"
    exit 0
fi

# Run EVERY query inside ONE zsh subprocess (source helpers EXACTLY once — never
# source-per-term). Each query is preceded by a 0x1C-prefixed marker line so the
# bash parser below can attribute hits to the ITEM_ID query (strong, +10) vs a
# term query (+1). KB_TEAM/KB_TERMINAL are exported so the function's telemetry
# logs an accurate persona instead of "unknown". Every failure is swallowed —
# this hook must NEVER error the session.
SEARCH_RAW=$(
    KB_TEAM="$ITEM_TEAM" KB_TERMINAL="agent" zsh -c '
        helpers="$1"; shift
        source "$helpers" >/dev/null 2>&1 || exit 0
        command -v kb-knowledge-search >/dev/null 2>&1 || exit 0
        # Optional self-test channel: write the count of the optimized marker
        # ("grep -rliF" appears only in the batched implementation) so tests can
        # ASSERT the optimized function is the one loaded. Production leaves
        # KB_HOOK_DEBUG_FILE unset => no-op.
        if [[ -n "${KB_HOOK_DEBUG_FILE:-}" ]]; then
            functions kb-knowledge-search 2>/dev/null | grep -c "grep -rliF" > "$KB_HOOK_DEBUG_FILE" 2>/dev/null
        fi
        first=1
        for t in "$@"; do
            if [[ $first -eq 1 ]]; then printf "\034KBQ:1\n"; first=0; else printf "\034KBQ:0\n"; fi
            kb-knowledge-search "$t" 2>/dev/null
        done
    ' _ "$HELPERS" "$ITEM_ID" ${PICKED_TERMS[@]+"${PICKED_TERMS[@]}"} 2>/dev/null
) || true

# --- Parse the function output + aggregate scores ---
# Per-entry shape emitted by kb-knowledge-search:
#       [tier_label]               Title                     tags
#                                  ~/relative/path.md
# We key on the path line (the only line containing "~/"); the most recent
# bracketed token before it is the tier label. Score = sum over the queries that
# returned the file: +10 if the ITEM_ID query returned it, +1 per term query —
# deduped WITHIN each query block so one query never double-counts a file.
# bash 3.2: no associative arrays. The loop emits one record per (query block,
# file) hit as "block<TAB>inc<TAB>label<TAB>path"; awk then dedups within a
# block, sums, and applies the relevance bar.
_cur_is_itemid=0
_cur_label=""
_block=0
HITS=""
_TAB=$'\t'

while IFS= read -r line; do
    case "$line" in
        $'\034'KBQ:1) _cur_is_itemid=1; _cur_label=""; _block=$((_block + 1)); continue ;;
        $'\034'KBQ:0) _cur_is_itemid=0; _cur_label=""; _block=$((_block + 1)); continue ;;
    esac
    # Tier-label line (checked FIRST so a title that happens to contain "~/" is
    # never misread as a path — path lines never contain '[').
    if [[ "$line" =~ ^[[:space:]]*\[([^]]+)\] ]]; then
        _cur_label="${BASH_REMATCH[1]}"
        continue
    fi
    # A real entry path line is PURE leading whitespace then "~/<path>" (the
    # function prints `printf "  %-26s %s" "" "~/$rel_path"`). Anchoring on
    # `^[[:space:]]+~/` rejects the function's own header `Root: ~/knowledge`
    # line and the "no results" suggestion text (`... in ~/knowledge/agents/ or
    # subjects/`), which contain "~/" but are preceded by other characters.
    if [[ "$line" =~ ^[[:space:]]+~/(.+)$ ]]; then
        _abs="${HOME}/${BASH_REMATCH[1]}"
        # Belt-and-suspenders: the function already excludes INDEX/templates, but
        # keep the old hook's filter so behavior is identical if that ever changes.
        case "$_abs" in
            */INDEX.md|*/TEMPLATES/*|*/templates/*) continue ;;
        esac
        _inc=1; [[ $_cur_is_itemid -eq 1 ]] && _inc=10
        HITS="${HITS}${_block}${_TAB}${_inc}${_TAB}${_cur_label:-kb}${_TAB}${_abs}"$'\n'
    fi
done <<< "$SEARCH_RAW"

# Relevance bar: score >= 2 (>=2 term-query matches OR an ITEM_ID match) —
# identical to the pre-XACA-0721 behavior, just computed over the bounded query
# set instead of all extracted terms. Keeps the block high-signal.
# Score = sum over the queries that returned the file (+10 ITEM_ID query, +1 per
# term query), deduped WITHIN each query block; label = last label seen.
# Output (highest score first): "score<TAB>label<TAB>path".
MATCHED_LINES=""
if [[ -n "$HITS" ]]; then
    MATCHED_LINES=$(printf '%s' "$HITS" | awk -F'\t' '
        { key = $1 SUBSEP $4; if (key in seen) next; seen[key] = 1
          score[$4] += $2; label[$4] = $3
          if (!($4 in order)) { order[$4] = ++n; paths[n] = $4 } }
        END { for (i = 1; i <= n; i++) { p = paths[i]
                if (score[p] >= 2) printf "%d\t%s\t%s\n", score[p], label[p], p } }' \
        | sort -rn -k1,1)
fi

# No matches — exit silently (no noisy block)
[[ -z "$MATCHED_LINES" ]] && exit 0

# --- Format output ---
# Extract title from frontmatter (name field) or first heading
_get_title() {
    local file="$1"
    # Try frontmatter name field
    local name
    name=$(sed -n '/^---$/,/^---$/{/^name:/s/^name:[[:space:]]*//p;}' "$file" 2>/dev/null | awk 'NR==1')
    if [[ -n "$name" ]]; then
        echo "$name"
        return
    fi
    # Try first markdown heading
    name=$(grep -m1 '^#' "$file" 2>/dev/null | sed 's/^#* *//')
    if [[ -n "$name" ]]; then
        echo "$name"
        return
    fi
    # Fall back to filename
    basename "$file" .md
}

# Build output
OUTPUT=""
OUTPUT+="Prior Knowledge for ${ITEM_ID}: ${ITEM_TITLE}\n"
OUTPUT+="Searched (bounded): ${ITEM_ID} ${PICKED_TERMS[*]-}\n"
OUTPUT+="─────────────────────────────────────────────────\n"

COUNT=0
MAX_RESULTS=10
while IFS="$_TAB" read -r _score label file; do
    [[ -n "$file" ]] || continue
    [[ $COUNT -ge $MAX_RESULTS ]] && break
    title=$(_get_title "$file")
    case "$file" in
        "$HOME"/*) rel_path="~${file#"$HOME"}" ;;   # not ${f/#$HOME/~}: bash 3.2 expands the ~
        *) rel_path="$file" ;;
    esac
    OUTPUT+="  [${label}] ${title}\n"
    OUTPUT+="           ${rel_path}\n"
    COUNT=$((COUNT + 1))
done <<< "$MATCHED_LINES"

if [[ $COUNT -gt 0 ]]; then
    OUTPUT+="─────────────────────────────────────────────────\n"
    OUTPUT+="Found ${COUNT} prior knowledge entries. Review before starting work.\n"
    OUTPUT+="Use: kb-knowledge-search \"<term>\" for deeper searches.\n"
    printf "%b" "$OUTPUT"
fi

exit 0
