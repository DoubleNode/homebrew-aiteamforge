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
# ─────────────────────────────────────────────────────────────────────────────
# Board-less alias marker (XACA-0794 / XACA-0794-013)
# ─────────────────────────────────────────────────────────────────────────────
#
# A board-less team owns NO kanban board but keeps its other identities (LCARS
# port, team_code, crew launcher, personas). "mainevent" is the only one today: a
# coordination/port identity (LCARS 8400, team_code MEV) whose operative kanban
# identity is "command".
#
# WHY THIS EXISTS (XACA-0794-013): this resolver never had a board-less guard --
# not even XACA-0727's, which only ever landed on the dev-tree copy. So on a
# CONSUMER box a kb-* call for 'mainevent' read kanban_dir=null from the registry,
# failed Strategy 1's [[ -d ]] test, matched no case arm, and fell through to the
# Strategy-3 catch-all -- silently resolving to ACADEMY's board and operating on
# the wrong team's data. Erroring clearly beats corrupting a bystander.
#
# Contract: echo the alias target and return 0 when $1 is board-less; return 1
# otherwise. Mirrors board_less_alias_of() in kanban-hooks/aiteamforge_paths.py --
# EXPLICIT OVERLAY MARKER FIRST, built-in fallback second.
_kb_board_less_builtin_alias_of() {
    case "${1-}" in
        mainevent) echo "command"; return 0 ;;
    esac
    return 1
}

_kb_board_less_alias_of() {
    local team="${1-}"
    [[ -z "$team" ]] && return 1

    # 1. Explicit overlay marker -- authoritative once the overlay is migrated.
    #    The helper exits non-zero for "not board-less" AND for "config unreadable";
    #    both correctly mean "fall through to the built-in table" below.
    local _cfg_file="${AITEAMFORGE_CONFIG:-${HOME}/.aiteamforge/team-paths.json}"
    if [[ -f "$_cfg_file" ]] && command -v python3 &>/dev/null; then
        local _alias
        if _alias=$(python3 - "$_cfg_file" "$team" 2>/dev/null <<'PYEOF'
import json, sys
from pathlib import Path
cfg, team = sys.argv[1], sys.argv[2]
try:
    entry = json.loads(Path(cfg).read_text(encoding="utf-8")).get("teams", {}).get(team, {})
except Exception:
    sys.exit(1)
if not isinstance(entry, dict) or entry.get("board_less") is not True:
    sys.exit(1)
alias = entry.get("alias_of")
# Absence is representable as missing / null / "null" / "" -- normalize all four
# (_ABSENT_SENTINELS in aiteamforge_paths.py).
if alias not in (None, "", "null"):
    print(alias)
sys.exit(0)
PYEOF
        ); then
            if [[ -n "$_alias" ]]; then
                echo "$_alias"
            else
                # Overlay marks the team board-less but omits alias_of. Python's
                # board_less_alias_of() falls back to DEFAULT_TEAMS here; mirror it,
                # or the error message below loses its "use 'command'" guidance.
                _kb_board_less_builtin_alias_of "$team" || true
            fi
            return 0
        fi
    fi

    # 2. Built-in fallback -- un-migrated overlay, or no overlay at all.
    if _kb_board_less_builtin_alias_of "$team"; then
        return 0
    fi

    return 1
}

_kb_get_kanban_dir() {
    local team="$1"
    local _atf_dir="${AITEAMFORGE_DIR}"

    # ── Strategy 0: board-less guard (XACA-0727 / XACA-0794-013) ─────────────
    # Refuse BEFORE any resolution strategy. A board-less alias has no board, so
    # every strategy below would be answering the wrong question -- and the
    # catch-all would answer it with someone else's board.
    local _bl_alias
    if _bl_alias=$(_kb_board_less_alias_of "$team"); then
        if [[ -n "$_bl_alias" ]]; then
            echo "kb: '$team' is a board-less alias (no kanban board) — this is intentional, not corruption. Use '$_bl_alias' instead. (XACA-0727/XACA-0794)" >&2
        else
            echo "kb: '$team' is a board-less alias (no kanban board) — this is intentional, not corruption. (XACA-0727/XACA-0794)" >&2
        fi
        return 1
    fi

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

# Run an argv command (no shell) under an exclusive flock, capturing its
# stdout to tmp_file and atomically renaming it onto target_file on success.
# Usage: _kb_jq_atomic_write <lock_file> <tmp_file> <target_file> <error_label> <argv...>
#   <argv...>       the command to run (e.g. jq --arg x "$v" -f filter board)
#   <error_label>   text appended after "ERROR: " to stderr on failure
# Returns 0 on success (target_file now holds the new content), 1 on failure
# (tmp_file removed, nothing written to target_file).
#
# XACA-0935: the code this replaced built a shell command STRING via zsh's
# `printf '%q'` and ran it through a freshly spawned `sh -c "..."`. Any
# --arg/--argjson VALUE containing embedded newlines makes zsh's `printf '%q'`
# emit bash/zsh-only `$'...'` ANSI-C quoting; macOS's default /bin/sh (bash in
# posix mode) tolerates that, but Linux's dash /bin/sh does not understand
# `$'...'` and silently mis-parses the argument boundary, corrupting the JSON
# payload before jq ever sees it. This primitive hands argv straight to
# Perl's system(LIST) form (the same technique the sibling _kb_jq_read
# already used), which execs via execvp with NO shell involved at all, so no
# argument, however it's shaped, is ever re-parsed or re-quoted.
_kb_jq_atomic_write() {
    local lock_file="$1"
    local tmp_file="$2"
    local target_file="$3"
    local error_label="$4"
    shift 4
    local cmd_argv=("$@")

    touch "$lock_file" 2>/dev/null

    perl -e '
        use Fcntl qw(:flock);
        my $lock_file   = shift @ARGV;
        my $tmp_file    = shift @ARGV;
        my $target_file = shift @ARGV;

        # Structural guarantee, not just an incidental fact: this primitive
        # must never be able to degenerate into system()'"'"'s single-scalar
        # shell-metacharacter-check form, which (unlike the execvp() LIST
        # form) re-parses the argv through a shell. The real caller here
        # always passes jq with well over a dozen argv elements.
        die "_kb_jq_atomic_write: refusing to run with fewer than 2 argv elements (got " . scalar(@ARGV) . ") -- this primitive must never shell out\n"
            if scalar(@ARGV) < 2;

        # A die() between here and the successful rename() below must not
        # leave $tmp_file behind. An END block fires on every exit path,
        # die()s included, so cleanup can never be skipped. $cleanup_tmp is
        # cleared only after a successful rename, where $tmp_file no longer
        # exists anyway.
        my $cleanup_tmp = 1;
        END { unlink($tmp_file) if $cleanup_tmp && defined($tmp_file) && -e $tmp_file; }

        open(my $fh, ">", $lock_file) or die "Cannot open lock file: $!";
        flock($fh, LOCK_EX) or die "Cannot lock: $!";

        # Capture the child'"'"'s stdout to tmp_file by redirecting our own
        # STDOUT fd before exec (system() children inherit it) -- no shell
        # redirection operator needed.
        open(my $out, ">", $tmp_file) or die "Cannot open tmp file: $!";
        open(my $saved_stdout, ">&STDOUT") or die "Cannot save stdout: $!";
        open(STDOUT, ">&", $out) or die "Cannot redirect stdout: $!";
        # Indirect-object form forces execvp() LIST-form dispatch
        # unconditionally, regardless of how many elements @ARGV has --
        # unlike plain system(@ARGV), this can never degenerate into the
        # single-scalar shell path even if the die guard above were bypassed.
        my $status = system { $ARGV[0] } @ARGV;  # zsh-index-ok: Perl, 0-indexed by design
        open(STDOUT, ">&", $saved_stdout) or die "Cannot restore stdout: $!";
        close($saved_stdout);
        close($out);

        # SAFETY: gate on the FULL $status, never `$status >> 8` alone. A
        # child killed by a signal (SIGTERM/SIGINT/...) sets the low 7 bits
        # of $status and leaves the high byte (the shifted "exit code") at 0
        # -- `>> 8` alone reads that as a clean exit(0) and would rename a
        # partially-flushed tmp file over the target. Only a literal
        # $status == 0 (no signal, exit code 0) counts as success.
        if ($status == 0 && -s $tmp_file) {
            rename($tmp_file, $target_file) or die "Cannot rename tmp file: $!";
            $cleanup_tmp = 0;
            close($fh);
            exit(0);
        }

        # Failure path: report a specific reason instead of letting the
        # caller'"'"'s generic $error_label stand in for every cause -- a
        # signal kill, a nonzero jq exit, and a genuine empty-output guard
        # trip are different failure classes.
        my $exit_code;
        if ($status == -1) {
            print STDERR "_kb_jq_atomic_write: failed to execute command: $!\n";
            $exit_code = 1;
        } elsif ($status & 127) {
            my $sig = $status & 127;
            print STDERR "_kb_jq_atomic_write: command killed by signal $sig\n";
            $exit_code = 128 + $sig;
        } elsif ($status != 0) {
            my $rc = $status >> 8;
            print STDERR "_kb_jq_atomic_write: command exited with status $rc\n";
            $exit_code = $rc;
        } else {
            print STDERR "_kb_jq_atomic_write: command produced empty output\n";
            $exit_code = 1;
        }

        # XACA-0935: unlink $tmp_file HERE, while the flock is still held,
        # instead of leaving it to the END block. $tmp_file is a fixed,
        # non-unique name (${board_file}.tmp) shared by every writer racing
        # for this lock -- an END-only unlink runs AFTER close($fh) below
        # releases the lock, so a slow failing process could delete the tmp
        # file a different, already-relocked writer just created. Cleaning
        # up in-lock, before close($fh), removes that window; END remains a
        # safety net for `die` exits, all of which (once $tmp_file exists)
        # happen before $fh is closed, so it still always fires in-lock.
        unlink($tmp_file) if defined($tmp_file) && -e $tmp_file;
        $cleanup_tmp = 0;
        close($fh);
        exit($exit_code);
    ' "$lock_file" "$tmp_file" "$target_file" "${cmd_argv[@]}"

    local result=$?
    [[ $result -ne 0 ]] && echo "ERROR: ${error_label}" >&2
    return $result
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

    # Write filter to temp file to avoid zsh BANG_HIST escaping '!' in
    # filters -- this used to matter because the filter round-tripped
    # through `sh -c`; that round-trip is gone (XACA-0935, see
    # _kb_jq_atomic_write above), but the temp-file approach is kept anyway
    # since it keeps long/multi-line filter bodies out of argv.
    local filter_file
    filter_file=$(mktemp "${TMPDIR:-/tmp}/kb-jq-filter.XXXXXX")
    printf '%s' "$jq_filter" > "$filter_file"

    _kb_jq_atomic_write "$lock_file" "$tmp_file" "$board_file" \
        "jq produced empty output, aborting write" \
        jq "${jq_args[@]}" -f "$filter_file" "$board_file"
    local result=$?

    rm -f "$filter_file" 2>/dev/null
    return $result
}

# ─────────────────────────────────────────────────────────────────────────────
# Shared jq status-resolution library (XACA-0948).
#
# Implements kanban/plans/XACA-0948/ITEM_STATUS_CONTRACT.md §1.5 (backlog-item
# precedence) and §1.1's recursive subitem-layer rule, as jq `def`s. Prefix
# this string onto any jq PROGRAM passed to `_kb_jq_read`/`jq` whose filter
# calls `kb_resolve_item_status` (item, `.` = the item object) or
# `kb_resolve_subitem_status` (subitem, `.` = the subitem object).
#
# Rules encoded here (see the contract for full rationale + edge-case matrix):
#   R1 — a RECORDED status (key present, value not null, and -- after
#        trimming whitespace -- not "") always wins verbatim, INCLUDING
#        non-canonical tokens (backlog/pending/ongoing, §1.4) and terminal
#        states (completed/cancelled). jq's `//` alone does not catch `""`
#        (contract §1.1, Case O) -- that is why this is a `def`, not `//`.
#   R2 — unrecorded + a live (non-cancelled) subitem in in_progress,
#        in_review, blocked, or completed -> "in_progress".
#   R3 — unrecorded + activelyWorking truthy -> "in_progress".
#   R4 — unrecorded + startedAt present -> "in_progress".
#   R5 — unrecorded, no evidence -> "todo" (the board-convention default).
# Ceiling: unrecorded NEVER resolves to a terminal state (completed/
# cancelled) or to "blocked" -- completion/cancellation/blocking are always
# DECLARED (recorded), never inferred (contract §1.2/§1.3).
#
# Subitems recurse into kb_resolve_subitem_status for the SAME R1/"" handling
# but have no evidence branch of their own (contract §1.1: subitems have no
# subitems, so R2-R4 do not apply at that layer) -- absent/null/"" -> "todo".
# ─────────────────────────────────────────────────────────────────────────────
_KB_ITEM_STATUS_JQ_DEFS='
def kb_recorded_or_null:
  (.status) as $raw |
  if ($raw != null) and (($raw|tostring) as $s | ($s|gsub("^[[:space:]]+|[[:space:]]+$";"")) != "") then $raw else null end;

def kb_resolve_subitem_status:
  (kb_recorded_or_null) as $rec | if $rec != null then $rec else "todo" end;

def kb_resolve_item_status:
  (kb_recorded_or_null) as $rec |
  if $rec != null then $rec
  else
    ( ((.subitems // []) | map(kb_resolve_subitem_status) | map(select(. != "cancelled"))) as $live |
      if ($live | any(. == "in_progress" or . == "in_review" or . == "blocked" or . == "completed")) then "in_progress"
      elif (.activelyWorking // false) then "in_progress"
      elif ((.startedAt // null) != null) then "in_progress"
      else "todo"
      end )
  end;
'

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
            # XACA-0948: ITEM_STATUS_CONTRACT.md §1.5 resolution (kb-backlog show).
            # R5's board-convention default is "todo" -- not the "backlog"
            # literal this line used to fall back to.
            item_status=$(_kb_jq_read "$board_file" "${_KB_ITEM_STATUS_JQ_DEFS} .backlog[$index] | kb_resolve_item_status" -r)
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
                # XACA-0948: subitem-layer resolution (ITEM_STATUS_CONTRACT.md §1.1).
                _kb_jq_read "$board_file" \
                    "${_KB_ITEM_STATUS_JQ_DEFS} .backlog[$index].subitems[] | \"    [\(.id // \"?\")] [\((. | kb_resolve_subitem_status) | ascii_upcase | .[0:4])] \(.title)\"" -r
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
                        # XACA-0948: subitem-layer resolution (ITEM_STATUS_CONTRACT.md §1.1).
                        _kb_jq_read "$board_file" \
                            "${_KB_ITEM_STATUS_JQ_DEFS} .backlog[$parent_idx].subitems | to_entries[] | \"  [\(.key)] [\(.value.id // \"?\")] [\((.value | kb_resolve_subitem_status) | ascii_upcase | .[0:4])] \(.value.title)\"" \
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
# XACA-0948 audit: this standalone alias-file kb-done unconditionally WRITES
# status = "completed" -- it never READS the item's prior status (unlike the
# richer kanban-helpers.template.sh kb-done, which captures sub_old_status
# before an auto-complete cascade). ITEM_STATUS_CONTRACT.md governs resolving
# an unrecorded status for READ purposes; there is no read site here for it
# to apply to. Left as-is.
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
    # XACA-0862: _kb_get_board_file is EXISTENCE-GATED — it errors out (return 1)
    # whenever the team's kanban directory does not exist yet, instead of
    # returning the path a fresh setup would create. For a genuinely-not-yet-
    # provisioned team (exactly the "no canonical board exists" scenario
    # --force-no-canonical exists to handle) that collapsed the intended
    # "Refusing to quarantine: no canonical board found" message below into a
    # generic "could not resolve" error instead. Fix: compute canonical_path
    # directly from the same deterministic per-team directories used for
    # stub_path above, for the 3 unambiguous personal-org teams this function
    # already knows about. This never requires the directory to pre-exist, so
    # the existence check just below is what decides "no canonical board".
    # Ported from kanban-helpers.sh (canonical); see that file for full detail.
    local canonical_path=""
    case "$team" in
        legal-coparenting)
            canonical_path="${HOME}/legal/coparenting/kanban/legal-coparenting-board.json"
            ;;
        medical-general)
            canonical_path="${HOME}/medical/general/kanban/medical-general-board.json"
            ;;
        finance-personal)
            canonical_path="${HOME}/finance/personal/kanban/finance-personal-board.json"
            ;;
        *)
            canonical_path=$(_kb_get_board_file "$team" 2>/dev/null) || {
                echo "kb-quarantine-stub: could not resolve canonical board path for team '$team'." >&2
                return 1
            }
            ;;
    esac

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
    local quarantine_base="${AITEAMFORGE_DIR}/quarantine/runtime-stub-stash"
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

# kb-variance — XACA-0630 estimate-vs-actual handicap analytics reporter
# (ported to the tap aliases template in XACA-0632 so installed-tap users have
#  the CLI alongside the LCARS variance panel).
#
# Usage: kb-variance [--json] [--board-file <path>] [-h|--help]
#
# Default output: human-readable table with global weighted handicap, global
# median, excluded tallies, and per-bucket rows.
#
# --json: emit only the canonical §7 payload to stdout (pipe to jq . to
#         pretty-print or diff against the server).
#
# --board-file <path>: override the default board file (useful for testing
#                      against a synthetic fixture; default resolves via the
#                      current team context exactly like other kb-* reporters).
#
# PARITY NOTE (XACA-0632): the jq payload + table below are kept byte-identical
# to the canonical kb-variance in dev `kanban-helpers.sh`. The ONLY tap-side
# adaptations are the two helper calls — _kb_check_jq (vs _kb_ensure_jq) and
# the _kb_get_team/_kb_get_board_file board resolution (vs _kb_detect_context).
# Keep both copies in lock-step; test_xaca0630_parity.py guards the --json shape.
kb-variance() {
    _kb_check_jq || return 1

    # Parse arguments — declare all locals before any loop (zsh local-in-loop
    # stdout-leak rule: never declare a reassigned `local` inside a loop).
    local emit_json=0
    local board_file_override=""
    local show_help=0

    while [[ $# -gt 0 ]]; do
        case "${1-}" in
            --json)            emit_json=1; shift ;;
            --board-file)
                if [[ -z "${2-}" ]]; then
                    echo "Error: --board-file requires a path argument" >&2
                    return 2
                fi
                board_file_override="${2}"; shift 2
                ;;
            -h|--help)         show_help=1; shift ;;
            *)
                echo "Unknown argument: ${1-}" >&2
                echo "Usage: kb-variance [--json] [--board-file <path>] [-h|--help]" >&2
                return 2
                ;;
        esac
    done

    if [[ "$show_help" -eq 1 ]]; then
        cat <<'USAGE'
kb-variance — Estimate-vs-actual handicap analytics (XACA-0630)

Usage: kb-variance [--json] [--board-file <path>] [-h|--help]

Options:
  --json              Emit the canonical §7 JSON payload to stdout only.
                      Suitable for piping to jq or diffing against the server.
  --board-file <path> Override the board file (default: team board via context).
  -h, --help          Show this help.

Output (default human mode):
  Global weighted handicap + median, excluded item tallies, and a row per
  size bucket (<=1h, 1-4h, 4-8h, >8h) with count, handicap, median, and
  estimated/actual hour sums.

  "handicap > 1.0" means work consistently takes longer than estimated.
  "handicap < 1.0" means we tend to overestimate effort.

Empty state: when no eligible (completed + both fields set) items exist,
  human mode prints "Not enough tracked data yet"; --json emits the §7.3
  null-filled payload.
USAGE
        return 0
    fi

    # ── Resolve board file ──────────────────────────────────────────────────
    local board_file
    if [[ -n "$board_file_override" ]]; then
        board_file="$board_file_override"
    else
        local team
        team=$(_kb_get_team)
        board_file=$(_kb_get_board_file "$team")
    fi

    if [[ ! -f "$board_file" ]]; then
        echo "Error: board file not found: $board_file" >&2
        return 1
    fi

    # ── Derive team slug for the payload ───────────────────────────────────
    # Extract from filename: <dir>/<team>-board.json → <team>
    local team_slug
    team_slug=$(basename "$board_file" "-board.json")

    # ── Compute payload via jq ─────────────────────────────────────────────
    # All math at full float precision; rounding to 2dp only at the final
    # output stage.  Uses round() which is "round half away from zero" for
    # positive values — matches spec §6 exactly.
    #
    # jq != filter avoidance: never use != in jq expressions called from the
    #   aliases template; use == with swapped if/else branches.
    #
    # Eligibility (spec §2):
    #   status == "completed"
    #   AND points != null AND (points|type)=="number" AND points > 0
    #   AND timeWorkedMs != null AND (timeWorkedMs|type)=="number" AND timeWorkedMs > 0
    #
    # Exclusion buckets (only for status=="completed" items):
    #   no_estimate:  timeWorkedMs > 0 AND (points is null/missing/<= 0)
    #   no_time:      points > 0       AND (timeWorkedMs is null/missing/<= 0)
    #   both_missing: both absent/null/<= 0
    #
    # Non-completed items are silently ignored (not counted in any exclusion bucket).
    #
    # Median (spec §4.2): sort ratios asc; odd n → middle; even n → mean of two middles.

    local now_utc
    now_utc=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

    # ── Single-pass jq: full §7 payload ────────────────────────────────────
    local payload
    payload=$(jq \
        --arg team "$team_slug" \
        --arg generated_at "$now_utc" \
        '
        # ── helpers ─────────────────────────────────────────────────────────
        # round2: "round half to even" (banker'"'"'s rounding) matching Python
        # round(x, 2) semantics — the spec §6 example 1.125 → 1.12 proves this.
        # Algorithm: scale by 100, compute floor; if fractional part is exactly
        # 0.5 round to even (floor if floor is even, floor+1 if floor is odd);
        # otherwise standard round-half-away-from-zero.
        def round2:
            . * 100 as $s |
            ($s | floor) as $f |
            ($s - $f) as $frac |
            if $frac < 0.5 then $f / 100
            elif $frac > 0.5 then ($f + 1) / 100
            else
                if (($f % 2) == 0) then $f / 100
                else ($f + 1) / 100
                end
            end;

        def sort_and_median:
            sort as $s |
            length as $n |
            if $n == 0 then null
            elif (($n % 2) == 1) then $s[($n / 2 | floor)]
            else ($s[($n / 2) - 1] + $s[$n / 2]) / 2
            end;

        def is_pos_num: (. != null) and ((. | type) == "number") and (. > 0);

        # ── collect completed top-level items ────────────────────────────────
        [ .backlog[] ] as $all_items |
        [ $all_items[] | select(.status == "completed") ] as $completed |

        # ── eligible: completed + points>0 + timeWorkedMs>0 ─────────────────
        [ $completed[] | select((.points | is_pos_num) and (.timeWorkedMs | is_pos_num)) ] as $eligible |

        # ── exclusion counts ─────────────────────────────────────────────────
        ($completed | map(
            select(
                ((.points | is_pos_num) | not) and
                (.timeWorkedMs | is_pos_num)
            )
        ) | length) as $excl_no_estimate |

        ($completed | map(
            select(
                (.points | is_pos_num) and
                ((.timeWorkedMs | is_pos_num) | not)
            )
        ) | length) as $excl_no_time |

        ($completed | map(
            select(
                ((.points | is_pos_num) | not) and
                ((.timeWorkedMs | is_pos_num) | not)
            )
        ) | length) as $excl_both_missing |

        # ── global aggregates ────────────────────────────────────────────────
        ($eligible | length) as $n_eligible |
        ($eligible | map(.points) | add // 0) as $sum_est |
        ($eligible | map(.timeWorkedMs / 3600000) | add // 0) as $sum_act |
        ([ $eligible[] | (.timeWorkedMs / 3600000) / .points ] | sort_and_median) as $global_median_raw |

        # ── build payload ────────────────────────────────────────────────────
        {
            generatedAt: $generated_at,
            team: $team,
            eligible: $n_eligible,
            excluded: {
                no_estimate:  $excl_no_estimate,
                no_time:      $excl_no_time,
                both_missing: $excl_both_missing,
                total:        ($excl_no_estimate + $excl_no_time + $excl_both_missing)
            },
            global: {
                handicap:          (if $n_eligible == 0 then null else ($sum_act / $sum_est) | round2 end),
                median:            (if $n_eligible == 0 then null else $global_median_raw | round2 end),
                sumEstimatedHours: ($sum_est | round2),
                sumActualHours:    ($sum_act | round2)
            },
            buckets: [
                # Bucket 0: <=1h  (points > 0 and points <= 1)
                (
                    [ $eligible[] | select(.points > 0 and .points <= 1) ] as $b |
                    ($b | length) as $bn |
                    ($b | map(.points) | add // 0) as $be |
                    ($b | map(.timeWorkedMs / 3600000) | add // 0) as $ba |
                    {
                        label: "<=1h", n: $bn,
                        handicap:          (if $bn == 0 then null else ($ba / $be) | round2 end),
                        median:            (if $bn == 0 then null else [ $b[] | (.timeWorkedMs / 3600000) / .points ] | sort_and_median | round2 end),
                        sumEstimatedHours: ($be | round2),
                        sumActualHours:    ($ba | round2)
                    }
                ),
                # Bucket 1: 1-4h  (points > 1 and points <= 4)
                (
                    [ $eligible[] | select(.points > 1 and .points <= 4) ] as $b |
                    ($b | length) as $bn |
                    ($b | map(.points) | add // 0) as $be |
                    ($b | map(.timeWorkedMs / 3600000) | add // 0) as $ba |
                    {
                        label: "1-4h", n: $bn,
                        handicap:          (if $bn == 0 then null else ($ba / $be) | round2 end),
                        median:            (if $bn == 0 then null else [ $b[] | (.timeWorkedMs / 3600000) / .points ] | sort_and_median | round2 end),
                        sumEstimatedHours: ($be | round2),
                        sumActualHours:    ($ba | round2)
                    }
                ),
                # Bucket 2: 4-8h  (points > 4 and points <= 8)
                (
                    [ $eligible[] | select(.points > 4 and .points <= 8) ] as $b |
                    ($b | length) as $bn |
                    ($b | map(.points) | add // 0) as $be |
                    ($b | map(.timeWorkedMs / 3600000) | add // 0) as $ba |
                    {
                        label: "4-8h", n: $bn,
                        handicap:          (if $bn == 0 then null else ($ba / $be) | round2 end),
                        median:            (if $bn == 0 then null else [ $b[] | (.timeWorkedMs / 3600000) / .points ] | sort_and_median | round2 end),
                        sumEstimatedHours: ($be | round2),
                        sumActualHours:    ($ba | round2)
                    }
                ),
                # Bucket 3: >8h   (points > 8)
                (
                    [ $eligible[] | select(.points > 8) ] as $b |
                    ($b | length) as $bn |
                    ($b | map(.points) | add // 0) as $be |
                    ($b | map(.timeWorkedMs / 3600000) | add // 0) as $ba |
                    {
                        label: ">8h", n: $bn,
                        handicap:          (if $bn == 0 then null else ($ba / $be) | round2 end),
                        median:            (if $bn == 0 then null else [ $b[] | (.timeWorkedMs / 3600000) / .points ] | sort_and_median | round2 end),
                        sumEstimatedHours: ($be | round2),
                        sumActualHours:    ($ba | round2)
                    }
                )
            ]
        }
        ' "$board_file" 2>&1)

    local jq_exit=$?
    if [[ $jq_exit -ne 0 ]]; then
        echo "Error: jq failed to parse board file: $board_file" >&2
        echo "$payload" >&2
        return 1
    fi

    # ── Emit ────────────────────────────────────────────────────────────────
    if [[ "$emit_json" -eq 1 ]]; then
        # --json mode: emit ONLY the payload, nothing else
        printf '%s\n' "$payload"
        return 0
    fi

    # ── Human-readable table ─────────────────────────────────────────────────
    local n_eligible
    n_eligible=$(printf '%s\n' "$payload" | jq -r '.eligible')

    if [[ "$n_eligible" -eq 0 ]]; then
        local team_display excl_total
        team_display=$(printf '%s\n' "$payload" | jq -r '.team')
        excl_total=$(printf '%s\n' "$payload" | jq -r '.excluded.total')
        echo "kb-variance: Not enough tracked data yet (team: ${team_display})"
        echo "─────────────────────────────────────────────────────────────"
        echo "  No eligible items found — an item is eligible when it is"
        echo "  completed AND has both an estimate (points) and tracked time."
        if [[ "$excl_total" -gt 0 ]]; then
            local ne nt bm
            ne=$(printf '%s\n' "$payload" | jq -r '.excluded.no_estimate')
            nt=$(printf '%s\n' "$payload" | jq -r '.excluded.no_time')
            bm=$(printf '%s\n' "$payload" | jq -r '.excluded.both_missing')
            echo ""
            echo "  Completed items excluded ($excl_total total):"
            echo "    no estimate (points missing):  $ne"
            echo "    no time tracked:               $nt"
            echo "    both missing:                  $bm"
        fi
        echo ""
        echo "  Items become eligible as they are completed with both"
        echo "  kb-backlog points <id> <hours> AND active time tracking."
        return 0
    fi

    # Populated state — print the table
    printf '%s\n' "$payload" | jq -r '
        "kb-variance: Estimate-vs-Actual Handicap  (team: \(.team))",
        "═══════════════════════════════════════════════════════",
        "  Eligible items: \(.eligible)",
        "  Excluded: no_estimate=\(.excluded.no_estimate)  no_time=\(.excluded.no_time)  both_missing=\(.excluded.both_missing)  total=\(.excluded.total)",
        "",
        "  Global weighted handicap : \(.global.handicap)    (>1.0 = under-estimated)",
        "  Global median ratio      : \(.global.median)",
        "  Sum estimated hours      : \(.global.sumEstimatedHours)h",
        "  Sum actual hours         : \(.global.sumActualHours)h",
        "",
        "  ─── Per-bucket breakdown ────────────────────────────────",
        ([ "Bucket", "n", "Handicap", "Median", "Est hrs", "Act hrs" ] | @tsv),
        "  ─────────────────────────────────────────────────────────",
        (.buckets[] |
            [
                .label,
                (.n | tostring),
                (if .handicap == null then "—" else (.handicap | tostring) end),
                (if .median == null   then "—" else (.median   | tostring) end),
                (.sumEstimatedHours | tostring) + "h",
                (.sumActualHours    | tostring) + "h"
            ] | @tsv
        ),
        "  ─────────────────────────────────────────────────────────"
    '
}

#──────────────────────────────────────────────────────────────────────────────
# Knowledge System Helpers (XACA-0746 — ported from dev-team/kanban-helpers.sh,
# four-tier schema per XACA-0222). Context-safe: no tmux/$TMUX_PANE/~/dev-team
# dependency — see the _kb_get_team adaptation inside kb-knowledge-search below.
# Spec: ~/knowledge/SPEC.md
#──────────────────────────────────────────────────────────────────────────────

# Internal: resolve the global knowledge root (honours KB_KNOWLEDGE_GLOBAL_ROOT)
_kb_knowledge_global_root() {
    echo "${KB_KNOWLEDGE_GLOBAL_ROOT:-${HOME}/knowledge}"
}

# ─────────────────────────────────────────────────────────────────────────────
# XACA-0770 — Local-only team knowledge (PII containment), ported from
# dev-team/kanban-helpers.sh (XACA-0754/XACA-0754-013/XACA-0754-014).
# finance-personal / legal-coparenting / medical-general carry PII and must
# NEVER leave this host. _kb_knowledge_local_root() resolves a SECOND root,
# parallel to the global one, that the knowledge sync daemon (XACA-0749 — not
# yet in the tap, see XACA-0761) physically cannot see: it only ever operates
# on the global root. Search reads both roots; kb-knowledge-add routes writes
# to whichever root the target team/persona belongs to.
#
# Context-adaptation note (mirrors the XACA-0746 _kb_get_team pattern used
# elsewhere in this file): this file has no _kb_detect_context (the
# tmux-pane/.kb-team-sentinel resolver used by the full dev-team
# kanban-helpers.sh and the fallback kanban-helpers.template.sh) — it is
# deliberately context-safe. _kb_current_session_is_local_only_team and
# _kb_context_resolved below use _kb_get_team instead (KB_TEAM_OVERRIDE ->
# KANBAN_TEAM -> "academy" default; never errors, always resolves to
# SOMETHING) — this file's own canonical team-resolution helper.
# ─────────────────────────────────────────────────────────────────────────────

# Internal: locate the team-paths.json overlay config (honours AITEAMFORGE_CONFIG).
# Ported from dev-team/kanban-helpers.sh — HOME-based, no dev-team coupling.
_kb_overlay_config_path() {
    printf '%s\n' "${AITEAMFORGE_CONFIG:-${HOME}/.aiteamforge/team-paths.json}"
}

# Internal: resolve the local (unsynced) knowledge root (honours KB_KNOWLEDGE_LOCAL_ROOT)
_kb_knowledge_local_root() {
    echo "${KB_KNOWLEDGE_LOCAL_ROOT:-${HOME}/knowledge-local}"
}

# Internal: the git-tracked, hardcoded floor of local-only (PII) teams.
# THIS is the authoritative safety control, not team-paths.json (see
# _kb_is_local_only_team below) — a regenerated or missing team-paths.json
# must never be able to flip one of these three teams to shareable. Extend
# this list (and re-run sync-tap.sh) when a new personal team is created;
# do not rely solely on the team-paths.json flag for a team that already
# carries PII.
_kb_local_only_teams_hardcoded() {
    printf '%s\n' finance-personal legal-coparenting medical-general
}

# Internal: the git-tracked, hardcoded floor of local-only (PII) agent-tier
# personas — the resolved D1 roster (17 slugs), mirroring
# _kb_local_only_teams_hardcoded's role for the team tier.
#
# Why this exists: _kb_is_local_persona's OTHER path resolves its roster via
# _kb_local_personas_for_team, which reads either a persisted
# "local_personas" array in team-paths.json OR a scan of
# ~/dev-team/.claude/agents-master/. On the machine this design actually
# protects (a bare tap host such as M4Mini) NEITHER exists — agents-master is
# an Academy/dev-team-only checkout and the local-scaffold step that persists
# the array has not necessarily run yet — so the roster could resolve empty,
# _kb_is_local_persona would return false, and kb-knowledge-add's write_root
# would stay $global_root: a finance/legal/medical persona's agent-tier entry
# would leak into the SYNCED repo. This hardcoded list requires zero external
# state, so it can never silently fall through to global on a bare machine.
_kb_local_personas_hardcoded() {
    # finance-personal
    printf '%s\n' brunt nog quark-fin rom zek
    # legal-coparenting
    printf '%s\n' advocate casemanager courtclerk lawclerk mediator paralegal
    # medical-general
    printf '%s\n' cameron chase cuddy foreman house wilson
}

# _kb_is_local_only_team <team-id>
# True (0) if the team's knowledge MUST be routed to the local, unsynced root
# instead of the shared ~/knowledge repo.
#
# Fail-safe toward local: checks TWO independent sources and returns true if
# EITHER says so —
#   1. The hardcoded allowlist above (git-tracked, ships with the tool,
#      cannot be silently regenerated away).
#   2. An optional "local_only": true flag in team-paths.json (extensibility
#      for future personal teams, without a code change).
# Source 1 is checked first and unconditionally — a missing/corrupt/
# regenerated team-paths.json can therefore never misclassify a known PII
# team as shareable; at worst it fails to extend protection to a NEW team
# that hasn't been added to the hardcoded list yet.
_kb_is_local_only_team() {
    local team="${1-}"
    [[ -z "$team" ]] && return 1

    local t
    for t in $(_kb_local_only_teams_hardcoded); do
        [[ "$t" == "$team" ]] && return 0
    done

    local config_path
    config_path=$(_kb_overlay_config_path)
    [[ -f "$config_path" ]] || return 1

    local flag_value
    if command -v jq &>/dev/null; then
        flag_value=$(jq -r --arg t "$team" '.teams[$t].local_only // false' "$config_path" 2>/dev/null)
    elif command -v python3 &>/dev/null; then
        flag_value=$(python3 - "$config_path" "$team" <<'PYEOF'
import sys, json
from pathlib import Path
config_path, team = sys.argv[1], sys.argv[2]
try:
    config = json.loads(Path(config_path).read_text(encoding='utf-8'))
    v = config.get('teams', {}).get(team, {}).get('local_only', False)
    print('true' if v is True else 'false')
except Exception:
    print('false')
PYEOF
)
    else
        flag_value="false"
    fi
    [[ "$flag_value" == "true" ]]
}

# _kb_current_session_is_local_only_team
# True (0) if the CURRENT SESSION's team (resolved via _kb_get_team — this
# file's own team resolver; see the context-adaptation note above) is
# local-only. Used by kb-knowledge-add for tiers that aren't keyed by an
# explicit team/persona argument — subject and (bare) project — where the
# only signal available is "which team is this session running as."
#
# _kb_get_team never fails (KB_TEAM_OVERRIDE -> KANBAN_TEAM -> "academy"
# default), so on THIS file's model there is no genuinely unresolvable state
# the way there is with the full dev-team _kb_detect_context's 4-layer tmux/
# env/.kb-team-sentinel chain. This function can therefore only return false
# for "resolved to a real, known non-local team" here — see
# _kb_context_resolved immediately below, which documents that consequence
# explicitly for the fail-closed check in kb-knowledge-add.
_kb_current_session_is_local_only_team() {
    local team
    team=$(_kb_get_team 2>/dev/null)
    [[ -z "$team" ]] && return 1
    _kb_is_local_only_team "$team"
}

# _kb_context_resolved
# True (0) if _kb_get_team resolved to a non-empty team. On this file's
# single-env-var team model (KB_TEAM_OVERRIDE -> KANBAN_TEAM -> "academy"
# default) this is effectively ALWAYS true — unlike the full dev-team
# _kb_detect_context, there is no tmux-pane/.kb-team-sentinel chain here that
# can hard-fail through to an "unknown" state. Kept as a named predicate
# (rather than inlined) so _kb_ambiguous_tier_write_guard's shape stays
# identical to the canonical dev-team version: the guard becomes a
# documented, harmless no-op on this file rather than a silently-dropped
# safety check.
_kb_context_resolved() {
    local team
    team=$(_kb_get_team 2>/dev/null)
    [[ -n "$team" ]]
}

# _kb_ambiguous_tier_write_guard <allow_global:true|false>
# Fail-closed guard for kb-knowledge-add's subject/project tiers ONLY.
# agent/team tiers key off an explicit persona/team argument and are
# unaffected — this guard is not, and should not be, called for them.
#
# Ported from dev-team/kanban-helpers.sh (XACA-0754-014) for structural
# parity. On this file's team model _kb_context_resolved is effectively
# always true (see above), so in practice this guard is a documented no-op
# today. It is kept anyway so a future change to _kb_get_team (e.g. adding a
# genuine "unset" state) is automatically covered by the same fail-closed
# logic without another port.
_kb_ambiguous_tier_write_guard() {
    local allow_global="${1:-false}"

    _kb_context_resolved && return 0
    _kb_current_session_is_local_only_team && return 0  # defensive; shouldn't be reachable if unresolved

    if [[ "$allow_global" == "true" ]]; then
        echo "Warning: kb-knowledge-add could not resolve the current session's team — it can't verify this isn't a finance/legal/medical (PII) session. Proceeding to the SHARED/synced knowledge root anyway because --force was passed." >&2
        return 0
    fi

    echo "Error: kb-knowledge-add could not resolve the current session's team, so it can't verify this write isn't from a finance/legal/medical (PII) session. Refusing to write to the shared/synced knowledge root." >&2
    echo "  Fix: set KANBAN_TEAM=<team> to disambiguate (e.g. KANBAN_TEAM=academy kb-knowledge-add subject ...), or pass --force to intentionally write to the shared root anyway." >&2
    return 1
}

# Internal: map a local-only team's team-paths.json id to its agents-master
# persona-group directory name (used only by _kb_local_personas_for_team's
# fallback scan below). The two naming schemes differ (team-paths.json uses
# the full kanban team id, agents-master groups by short family name).
_kb_local_team_persona_group() {
    case "${1-}" in
        finance-personal)  echo "finance" ;;
        legal-coparenting) echo "legal" ;;
        medical-general)   echo "medical" ;;
        *) return 1 ;;
    esac
}

# _kb_local_personas_for_team <team-id>
# Resolves the kb agent-tier slug roster for a local-only team, one slug per
# line.
#
# Fast path: a persisted "local_personas" array in team-paths.json (written
# once by kb-knowledge-local-scaffold) — a lookup, not a filesystem scan.
# Fallback: scan ~/dev-team/.claude/agents-master/<group>/*.md and read each
# file's frontmatter `name:` field. That checkout does NOT exist on this
# file's target machines (bare tap hosts have no ~/dev-team) — the
# [[ -d "$master_dir" ]] guard below makes that a clean, silent no-op
# (return 1, no output, no error), never a leak or a crash. The hardcoded
# persona floor (_kb_local_personas_hardcoded, checked FIRST in
# _kb_is_local_persona) is what actually protects a bare machine; this
# function is only the extension path for a FUTURE local-only team not yet
# added to that floor.
_kb_local_personas_for_team() {
    local team="${1-}"
    [[ -z "$team" ]] && return 1

    local config_path
    config_path=$(_kb_overlay_config_path)
    if [[ -f "$config_path" ]]; then
        local persisted=""
        if command -v jq &>/dev/null; then
            persisted=$(jq -r --arg t "$team" '.teams[$t].local_personas // [] | .[]' "$config_path" 2>/dev/null)
        elif command -v python3 &>/dev/null; then
            persisted=$(python3 - "$config_path" "$team" <<'PYEOF'
import sys, json
from pathlib import Path
config_path, team = sys.argv[1], sys.argv[2]
try:
    config = json.loads(Path(config_path).read_text(encoding='utf-8'))
    for p in config.get('teams', {}).get(team, {}).get('local_personas', []) or []:
        print(p)
except Exception:
    pass
PYEOF
)
        fi
        if [[ -n "$persisted" ]]; then
            printf '%s\n' "$persisted"
            return 0
        fi
    fi

    local group
    group=$(_kb_local_team_persona_group "$team") || return 1
    local master_dir="${HOME}/dev-team/.claude/agents-master/${group}"
    [[ -d "$master_dir" ]] || return 1

    local f name
    for f in "${master_dir}"/*.md; do
        [[ -f "$f" ]] || continue
        name=$(_kb_knowledge_yaml_field "$f" "name")
        [[ -n "$name" ]] && echo "$name"
    done
}

# _kb_is_local_persona <persona-slug>
# True (0) if the given kb agent-tier slug belongs to one of the three known
# local-only teams' persona rosters (no intra-machine isolation — one shared
# local_root, all local personas are peers on this host). Used by
# kb-knowledge-add to route agent-tier writes to the local root.
#
# Fail-safe toward local (mirrors _kb_is_local_only_team's two-source shape):
# checks the hardcoded 17-persona floor (_kb_local_personas_hardcoded) FIRST
# and unconditionally — it requires no agents-master checkout and no
# persisted team-paths.json array, so it holds even on a bare tap machine
# that has neither. Only if the slug isn't in that floor does it fall
# through to the roster-resolution loop (_kb_local_personas_for_team), the
# extension path for a FUTURE local-only team not yet in the hardcoded floor.
_kb_is_local_persona() {
    local persona="${1-}"
    [[ -z "$persona" ]] && return 1

    local hp
    for hp in $(_kb_local_personas_hardcoded); do
        [[ "$hp" == "$persona" ]] && return 0
    done

    local team p
    for team in $(_kb_local_only_teams_hardcoded); do
        for p in $(_kb_local_personas_for_team "$team" 2>/dev/null); do
            [[ "$p" == "$persona" ]] && return 0
        done
    done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# XACA-0802 — Knowledge host affinity (WHICH BOX may author a team's knowledge)
#
# XACA-0754 answered "which ROOT does this write go to" (~/knowledge vs
# ~/knowledge-local). It never answered "is THIS HOST the one that owns this
# team", because nothing in the system could express that. ~/.aiteamforge/
# team-paths.json registers every team on every machine — it is a superset
# REGISTRY, not an ownership record — and every team's kanban_dir resolves to an
# existing directory on every box, so directory presence is not a usable proxy
# either. Consequence (XACA-0779): `kb-knowledge-add team legal-coparenting ...`
# run on a NON-owning host cheerfully mkdir -p'd a legal tree under
# ~/knowledge-local and wrote an entry there. The knowledge is correct,
# contained, and permanently invisible to the box that is supposed to have it.
#
# It also silently forked the entry-id counter. Ids are allocated by scanning the
# LOCAL target dir for the highest <prefix>NNN — and ~/knowledge-local never syncs
# between hosts by design, so two hosts each independently allocated t001 in
# legal-coparenting AND in medical-general. Four entries, two ids, no warning.
# Restoring a SINGLE authorized writer per team is what makes that counter
# authoritative again; a cross-host id scheme is deliberately not attempted.
#
# The declared owner is the optional per-team `primary_host` field in the
# team-paths overlay, materialized there by aiteamforge_paths.py's backfill pass.
# ABSENT is the normal, expected state for most teams — see the fail-open ruling
# in the guard below.
#
# Consumer note: this block matters MORE on a tap host than on the dev box. The
# PII teams live on consumer machines, so the guard has to ship here to protect
# anything at all.
# ─────────────────────────────────────────────────────────────────────────────

# Internal: normalize a host identity for comparison — lowercased, trailing
# ".local" stripped. macOS hands out the same box under several spellings
# (a capitalized name from scutil, a lowercased one from hostname -s, plus a
# ".local" suffix from anything mDNS-flavoured); a guard that fires on the very
# host it is supposed to protect is worse than no guard at all, so normalize
# aggressively.
_kb_host_normalize() {
    local h
    h=$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')
    h="${h%.local}"
    printf '%s\n' "$h"
}

# _kb_this_host_id
# This host's canonical identity. Primary source is `scutil --get ComputerName`
# (the user-facing name, matching how the fleet is referred to in docs); falls
# back to `hostname -s` when scutil is unavailable (non-macOS, stripped PATH) or
# returns empty. Never fails — worst case it echoes an empty line, which the
# guard treats as "unknown host" and reports verbatim.
_kb_this_host_id() {
    local id=""
    if command -v scutil &>/dev/null; then
        id=$(scutil --get ComputerName 2>/dev/null)
    fi
    if [[ -z "$id" ]]; then
        id=$(hostname -s 2>/dev/null)
    fi
    printf '%s\n' "$id"
}

# _kb_team_primary_host <team-id>
# Echoes the team's declared `primary_host` from the team-paths overlay, or
# nothing when the field is absent/empty/null. Same jq-then-python3-then-give-up
# ladder as _kb_is_local_only_team — and deliberately NOT _kb_overlay_lookup,
# whose team_code gate would reject the very entries this needs to read (a
# local-only overlay entry may carry no team_code).
_kb_team_primary_host() {
    local team="${1-}"
    [[ -z "$team" ]] && return 1

    local config_path
    config_path=$(_kb_overlay_config_path)
    [[ -f "$config_path" ]] || return 1

    local host=""
    if command -v jq &>/dev/null; then
        host=$(jq -r --arg t "$team" '.teams[$t].primary_host // ""' "$config_path" 2>/dev/null)
    elif command -v python3 &>/dev/null; then
        host=$(python3 - "$config_path" "$team" <<'PYEOF'
import sys, json
from pathlib import Path
config_path, team = sys.argv[1], sys.argv[2]
try:
    config = json.loads(Path(config_path).read_text(encoding='utf-8'))
    print(config.get('teams', {}).get(team, {}).get('primary_host', '') or '')
except Exception:
    print('')
PYEOF
)
    fi
    [[ "$host" == "null" ]] && host=""
    printf '%s\n' "$host"
}

# _kb_host_matches <declared> <actual>
# True (0) when <declared> names THIS box. Comparison is case-insensitive, with
# a trailing ".local" stripped from both sides, and <declared> is matched against
# <actual> OR either live form (`scutil --get ComputerName`, `hostname -s`) —
# a declared value only has to agree with ONE of the names this Mac answers to.
# That breadth is intentional: false-negative == a legitimate author locked out
# of their own knowledge tree, which is strictly worse than the leak-free
# over-permission of accepting a second correct spelling of the same host.
_kb_host_matches() {
    local declared="${1-}" actual="${2-}"
    [[ -z "$declared" ]] && return 1

    local want
    want=$(_kb_host_normalize "$declared")
    [[ -z "$want" ]] && return 1

    local scutil_name="" short_name=""
    if command -v scutil &>/dev/null; then
        scutil_name=$(scutil --get ComputerName 2>/dev/null)
    fi
    short_name=$(hostname -s 2>/dev/null)

    local cand
    for cand in "$actual" "$scutil_name" "$short_name"; do
        [[ -z "$cand" ]] && continue
        [[ "$(_kb_host_normalize "$cand")" == "$want" ]] && return 0
    done
    return 1
}

# _kb_team_for_local_persona <persona-slug>
# Echoes the local-only team that owns an agent-tier persona slug, or returns 1
# when the slug belongs to no local-only team (the common case — every ordinary
# persona). Mirrors _kb_is_local_persona's two-source shape: the hardcoded
# 17-slug floor FIRST and unconditionally (it needs no agents-master checkout and
# no persisted overlay array, so it holds on a bare tap machine), then the
# roster-resolution fallback for a FUTURE local-only team not yet in the floor.
# Keep the case arms in lockstep with _kb_local_personas_hardcoded.
_kb_team_for_local_persona() {
    local persona="${1-}"
    [[ -z "$persona" ]] && return 1

    case "$persona" in
        brunt|nog|quark-fin|rom|zek)
            printf '%s\n' finance-personal; return 0 ;;
        advocate|casemanager|courtclerk|lawclerk|mediator|paralegal)
            printf '%s\n' legal-coparenting; return 0 ;;
        cameron|chase|cuddy|foreman|house|wilson)
            printf '%s\n' medical-general; return 0 ;;
    esac

    local team p
    for team in $(_kb_local_only_teams_hardcoded); do
        for p in $(_kb_local_personas_for_team "$team" 2>/dev/null); do
            if [[ "$p" == "$persona" ]]; then
                printf '%s\n' "$team"
                return 0
            fi
        done
    done
    return 1
}

# _kb_knowledge_host_affinity_guard <target> <kind:agent|team> [allow_foreign:true|false]
# The policy function. Returns 0 to proceed, 1 to refuse the write. MUST be
# called after the local-only classification and BEFORE mkdir -p / id allocation
# — a refusal has to leave no directory and no file behind.
#
# Three outcomes, in the order they are decided:
#
#  1. No declared host → FAIL OPEN with one warning line. This is a deliberate
#     ruling, not an oversight: `primary_host` is absent for most teams and was
#     absent everywhere the instant this shipped, so failing closed would brick
#     local-only authoring across the entire fleet before a single host was
#     populated. Authorization may arrive progressively; ROUTING is already
#     backstopped by the hardcoded PII floor, which is the control that actually
#     contains the data.
#
#  2. Local-only target on the wrong host → REFUSE. ~/knowledge-local never
#     syncs, so this write is unrecoverable-in-place: invisible to the owner,
#     and it forks the id counter (XACA-0779). The message names the correct
#     host and the override flag. Overridable via --allow-foreign-host, which
#     downgrades it to a warning for the operator who genuinely means it.
#
#  3. Fleet-synced team on the wrong host → WARN ONLY, proceed. ~/knowledge IS
#     synced: the entry shows up everywhere, the id counter still sees it, and
#     the write is trivially fixable. Blocking here would be friction with no
#     safety payoff — do not over-block.
_kb_knowledge_host_affinity_guard() {
    local target="${1-}" kind="${2-}" allow_foreign="${3:-false}"
    [[ -z "$target" ]] && return 0

    # Resolve the team whose ownership governs this write, plus whether the
    # target is local-only (which decides refuse-vs-warn on a mismatch).
    local team="" is_local=false
    if [[ "$kind" == "agent" ]]; then
        team=$(_kb_team_for_local_persona "$target" 2>/dev/null) || team=""
        if _kb_is_local_persona "$target"; then
            is_local=true
        fi
    else
        team="$target"
        if _kb_is_local_only_team "$target"; then
            is_local=true
        fi
    fi

    # An agent-tier persona owned by no local-only team has no governing team —
    # nothing to enforce, and no team-paths entry to consult.
    [[ -z "$team" ]] && return 0

    local declared
    declared=$(_kb_team_primary_host "$team" 2>/dev/null) || declared=""
    if [[ -z "$declared" ]]; then
        # Fail open. The warning is scoped to local-only targets deliberately:
        # most teams will never declare a primary_host, so warning on every
        # ordinary `kb-knowledge-add team <t> ...` would be pure noise on the
        # path where a stranded write is impossible anyway (the global root
        # syncs). An undeclared LOCAL-ONLY team is the case worth saying out
        # loud — that is a host whose overlay has not been backfilled yet,
        # i.e. exactly the XACA-0779 exposure, still open.
        if [[ "$is_local" == "true" ]]; then
            echo "Warning: no primary_host declared for '${team}' — cannot verify this host is authorized to author its local-only knowledge. Proceeding (XACA-0802 fails open on an undeclared host)." >&2
        fi
        return 0
    fi

    local actual
    actual=$(_kb_this_host_id)
    if _kb_host_matches "$declared" "$actual"; then
        return 0
    fi

    if [[ "$is_local" == "true" ]]; then
        if [[ "$allow_foreign" == "true" ]]; then
            echo "Warning: '${target}' knowledge is authored on '${declared}' (this host is '${actual}') — writing here anyway because --allow-foreign-host was passed. The entry will stay on THIS host and may collide with an entry id already used on '${declared}'." >&2
            return 0
        fi
        echo "Error: '${target}' knowledge is authored on '${declared}' (this host is '${actual}')." >&2
        echo "  Fix: run this kb-knowledge-add on '${declared}'. Its knowledge root never syncs between hosts, so an entry written here is stranded and invisible there (XACA-0779)." >&2
        echo "  Override: pass --allow-foreign-host to write here anyway, accepting a stranded entry and a possible entry-id collision." >&2
        return 1
    fi

    echo "Warning: '${team}' knowledge is authored on '${declared}' (this host is '${actual}'). Proceeding — this tier writes to the fleet-synced knowledge root, so the entry is visible everywhere and easy to relocate." >&2
    return 0
}

# Internal: validate a single name component (persona, team, subject segment).
# Valid: starts with lowercase letter, followed by lowercase letters, digits, underscores, hyphens.
# Rejects path-traversal characters (/, .., \, null bytes) and uppercase names.
_kb_validate_name_component() {
    local name="${1-}"
    if [[ "$name" =~ ^[a-z][a-z0-9_-]*$ ]]; then
        return 0
    fi
    return 1
}

# Internal: validate a subject path (slash-separated components, each must pass _kb_validate_name_component).
_kb_validate_subject_path() {
    local subj_path="${1-}"
    local component
    # Split on / and validate each component
    local IFS_save="$IFS"
    IFS='/'
    local -a components
    components=( ${=subj_path} )
    IFS="$IFS_save"
    if [[ ${#components[@]} -eq 0 ]]; then
        return 1
    fi
    for component in "${components[@]}"; do
        if ! _kb_validate_name_component "$component"; then
            return 1
        fi
    done
    return 0
}

# Internal: slugify a string → lowercase, hyphen-separated, no non-alnum chars
_kb_knowledge_slugify() {
    local s="${1-}"
    echo "$s" | tr '[:upper:]' '[:lower:]' | tr -s ' _' '-' | tr -cd 'a-z0-9-' | sed 's/^-//;s/-$//'
}

# Internal: parse a simple YAML value from frontmatter
# Usage: _kb_knowledge_yaml_field <file> <field>
_kb_knowledge_yaml_field() {
    local file="${1-}" field="${2-}"
    grep -m1 "^${field}:" "$file" 2>/dev/null | sed "s/^${field}:[[:space:]]*//" | tr -d '"'"'"
}

# ─────────────────────────────────────────────────────────────────────────────
# _kb_canonical_kanban_dir_for_repo [<repo_root>] (XACA-0883-001)
# ─────────────────────────────────────────────────────────────────────────────
#
# Resolves the CANONICAL kanban/ directory that owns a given repo root — the
# container-level kanban/ for container-layout teams (iOS/Android/Firebase/
# DNS), where the git work-tree is a CHILD of the container and
# kanban/ is a SIBLING of the work-tree (e.g.
# .../{{ORG_NAME}}App-iOS/DEV → .../{{ORG_NAME}}App-iOS/kanban), and the repo's own
# kanban/ for kanban-inside-repo teams (Academy/Command/Finance/Legal/
# Medical), where repo_root IS the container (e.g. a repo whose own top level
# holds kanban/ directly).
#
# Exists because _kb_knowledge_project_path's case-2 template expansion
# ({repo_root}/kanban/knowledge/project, below) silently assumes
# repo_root == container, which is false for container-layout teams — it was
# writing knowledge into a SHADOW kanban/ under the work-tree instead of the
# canonical one (XACA-0883). This resolver is the layout-aware
# replacement for that assumption; callers use it to build a {kanban_dir}
# token instead of a fixed offset from {repo_root}.
#
# Input: a repo root path (a git work-tree root). If omitted, derives it the
# same worktree-aware way _kb_knowledge_project_path does (git rev-parse
# --git-common-dir, XACA-0278) — a feature worktree resolves to the MAIN repo
# root, never the ephemeral worktree.
#
# Resolution order:
#   1. Registry reverse-lookup (primary, source of truth): read
#      ~/.aiteamforge/team-paths.json (path via _kb_overlay_config_path) and
#      find every team entry whose working_dir equals, or is an ancestor of,
#      repo_root. Prefer the DEEPEST (longest) matching working_dir. Several
#      team ids legitimately map to the SAME kanban_dir (e.g. a platform team id and
#      a longer alias for it) — that is normal, not an error; only
#      matches at the SAME depth whose kanban_dir VALUES disagree are
#      genuinely ambiguous, and those fail closed.
#   2. Sibling probe (fallback, bounded to 3 levels — never walks to /): a
#      directory named exactly "kanban" that sits BESIDE repo_root or one of
#      its near ancestors (i.e. parent(repo_root)/kanban,
#      grandparent(repo_root)/kanban, ...) AND contains at least one
#      *-board.json file — the marker that proves it's a real kanban dir,
#      not a directory that merely happens to share the name.
#   3. Neither resolves → return 1, print nothing.
#
# EXIT CODES (callers must distinguish 1 from 2):
#   0 — resolved; the canonical kanban dir is on stdout.
#   1 — NO ANSWER: no registry entry claims this repo and the sibling probe
#       found nothing. Callers that merely resolve a path treat this as
#       "fail open" and keep pre-XACA-0883 behaviour, which is what keeps
#       unregistered container projects working.
#   2 — AMBIGUOUS: registry entries at the same depth claim this repo with
#       DIFFERENT kanban_dir values. This is a hard refusal for any WRITE —
#       the layout guard turns it into T3 and refuses without creating a
#       directory or writing a file. (XACA-0883-019: the guard used to tell
#       these apart by grepping this function's stderr through a temp file;
#       the numeric code removed that filesystem dependency entirely.)
#   stdout is EMPTY on both 1 and 2 — a function that returns non-zero while
#   still printing is the live hazard here, since callers substitute stdout.
#
# FAILS CLOSED by design: a wrong answer here silently redirects knowledge
# writes into another team's tree, which is strictly worse than an error the
# caller can see and act on. Every registry candidate is gated on
# [ -d "$dir" ] — team-paths.json is known to carry at least one stale entry
# (teams.command.kanban_dir → a removed /var/folders/... test path,
# XACA-0883 landmine L1) that must never be trusted blind.
#
# zsh notes: no `echo "$VAR" | jq` (control chars) — JSON is read straight off
# disk via jq (preferred) or python3, mirroring _kb_local_personas_for_team's
# dual-path style. BARE_GLOB_QUAL is scoped LOCAL_OPTIONS so the `(N)`
# qualifier below parses even under an interactive shell's
# `setopt NO_BARE_GLOB_QUAL` (XACA-0737). No `[[ ]] &&` as this function's
# last statement (a `set -e` caller would abort on a false match).
_kb_canonical_kanban_dir_for_repo() {
    setopt LOCAL_OPTIONS NO_NOMATCH BARE_GLOB_QUAL

    local repo_root="${1-}"

    if [[ -z "$repo_root" ]]; then
        local git_common_dir
        git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
        if [[ -z "$git_common_dir" ]]; then
            return 1
        fi
        if [[ "$git_common_dir" == ".git" ]]; then
            repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
        else
            repo_root=$(dirname "$git_common_dir")
        fi
    fi

    if [[ -z "$repo_root" ]] || [[ ! -d "$repo_root" ]]; then
        return 1
    fi

    # Normalize away a trailing slash so the ancestor prefix comparisons
    # below aren't fooled by "/a/b/" vs "/a/b".
    repo_root="${repo_root%/}"

    # XACA-0883-015: normalize symlinks before any prefix comparison. `git
    # rev-parse` hands back a symlink-RESOLVED path while team-paths.json's
    # working_dir may be unresolved (the classic macOS "/var" vs "/private/var"
    # split). A raw string prefix test then misses a registry entry that in fact
    # owns this repo, and resolution falls through to the sibling probe — which,
    # if it also finds no *-board.json within its hop budget, fails open to the
    # legacy per-case resolution and SILENTLY REINTRODUCES the shadow-base bug
    # this whole function exists to close. Normalizing both sides removes that
    # failure mode instead of relying on the probe to mask it.
    # `realpath` is not on stock macOS, so use a subshell cd + `pwd -P`; a
    # failure here is non-fatal, we simply keep the unnormalized value.
    local _cn_resolved
    _cn_resolved=$(cd "$repo_root" 2>/dev/null && pwd -P) || _cn_resolved=""
    [[ -n "$_cn_resolved" ]] && repo_root="$_cn_resolved"

    # ---- 1. Registry reverse-lookup ----
    local cfg
    cfg=$(_kb_overlay_config_path)
    if [[ -f "$cfg" ]]; then
        local pairs=""
        if command -v jq &>/dev/null; then
            pairs=$(jq -r '
                .teams
                | to_entries[]
                | select(.value.working_dir != null and .value.kanban_dir != null and .value.working_dir != "" and .value.kanban_dir != "")
                | "\(.value.working_dir)\t\(.value.kanban_dir)"
            ' "$cfg" 2>/dev/null)
        elif command -v python3 &>/dev/null; then
            pairs=$(python3 - "$cfg" <<'PYEOF'
import json, sys
cfg = sys.argv[1]
try:
    with open(cfg) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
for entry in data.get("teams", {}).values():
    if not isinstance(entry, dict):
        continue
    wd = entry.get("working_dir")
    kd = entry.get("kanban_dir")
    if wd and kd:
        print(f"{wd}\t{kd}")
PYEOF
)
        fi

        if [[ -n "$pairs" ]]; then
            # NOTE: every one of these is declared HERE, outside the while loop.
            # A bare `local X` re-executed inside a loop makes zsh echo "X=<value>"
            # to STDOUT and corrupt this function's return value (the PR #755
            # review finding). Do not move any of these inside the loop.
            local best_depth=-1 best_kanban="" ambiguous="false" wd kd depth _wd_resolved
            while IFS=$'\t' read -r wd kd; do
                if [[ -z "$wd" ]] || [[ -z "$kd" ]]; then
                    continue
                fi
                wd="${wd%/}"
                # XACA-0883-015: symlink-normalize the registry side too, so the
                # ancestor test compares like with like (repo_root was already
                # normalized above). Without this a registry working_dir spelled
                # "/var/..." never matches a repo_root git reported as
                # "/private/var/...", and a legitimately-owned repo silently
                # falls through to the probe. Non-fatal: an unresolvable wd keeps
                # its literal value and is simply compared as-is.
                _wd_resolved=$(cd "$wd" 2>/dev/null && pwd -P) || _wd_resolved=""
                [[ -n "$_wd_resolved" ]] && wd="$_wd_resolved"
                # Ancestor test: repo_root == wd, or repo_root is nested under wd.
                if [[ "$repo_root" != "$wd" ]] && [[ "$repo_root" != "$wd"/* ]]; then
                    continue
                fi
                # L1: gate every registry candidate on existence — stale entries
                # (e.g. a removed test tmpdir) must never be trusted blind.
                if [[ ! -d "$kd" ]]; then
                    continue
                fi
                depth=${#wd}
                if (( depth > best_depth )); then
                    best_depth=$depth
                    best_kanban="$kd"
                    ambiguous="false"
                elif (( depth == best_depth )); then
                    # L2: multiple team ids sharing one working_dir/kanban_dir is
                    # normal (e.g. a platform team id and a longer alias for
                    # it) — only a same-depth DISAGREEMENT is genuinely
                    # ambiguous.
                    if [[ "$kd" != "$best_kanban" ]]; then
                        ambiguous="true"
                    fi
                fi
            done <<< "$pairs"

            if (( best_depth >= 0 )); then
                if [[ "$ambiguous" == "true" ]]; then
                    echo "kb: _kb_canonical_kanban_dir_for_repo: conflicting registry entries at the same depth for '$repo_root' — refusing to guess." >&2
                    # XACA-0883-019: exit code 2 means AMBIGUOUS (conflicting
                    # claims), distinct from 1 = no answer at all. Callers must
                    # tell these apart — ambiguity is a hard refusal while
                    # no-answer fails open. Previously the only signal was a
                    # substring match on stderr, which forced the caller to
                    # capture stderr through a temp file just to classify the
                    # failure. A numeric code needs no filesystem at all.
                    return 2
                fi
                echo "$best_kanban"
                return 0
            fi
        fi
    fi

    # ---- 2. Sibling probe (fallback) ----
    local anc="$repo_root" parent sib hops=0
    while (( hops < 3 )); do
        parent=$(dirname "$anc")
        if [[ "$parent" == "$anc" ]]; then
            break  # reached filesystem root — never walk past it
        fi
        sib="${parent}/kanban"
        if [[ -d "$sib" ]]; then
            local -a _board_markers
            _board_markers=("${sib}"/*-board.json(N))
            if (( ${#_board_markers[@]} > 0 )); then
                echo "$sib"
                return 0
            fi
        fi
        anc="$parent"
        hops=$((hops + 1))
    done

    return 1
}

# Internal: XACA-0883 T3 diagnostic — enumerate the DISAGREEING same-depth
# registry candidates for a repo, so the layout guard's refusal can name
# names. Mirrors _kb_canonical_kanban_dir_for_repo's registry-lookup pass
# (never the sibling probe — T3 is a registry-only condition, see the guard
# contract §3.2) but additionally carries the team id, which the resolver's
# own stdout contract deliberately omits (it returns a bare path). Kept
# separate from the resolver so its hot, common-case path stays a single pass
# with no team-id bookkeeping — this only runs after the resolver has already
# told us (via its stderr) that this repo hit the ambiguous branch.
# Usage: _kb_knowledge_layout_guard_report_t3 <repo_root> <resolved_path>
_kb_knowledge_layout_guard_report_t3() {
    local repo_root="${1-}" resolved_path="${2-}"
    [[ -z "$repo_root" ]] && return 0
    repo_root="${repo_root%/}"

    # XACA-0883-022 (sibling drift): this reporter re-runs the resolver's
    # ancestor test to name the conflicting teams, so it MUST normalize paths
    # exactly as the resolver does. It originally did not, and the consequence
    # was worse than the bug it replaced: with a symlinked working_dir every
    # candidate missed, the empty-candidate branch fired, and the reporter
    # printed a confident "no registry entry claims it" one line below the
    # resolver's own "conflicting registry entries" on stderr — a complete,
    # plausible, WRONG diagnosis. If the ancestor test here ever changes, change
    # it in _kb_canonical_kanban_dir_for_repo too; these two are mirrors.
    local _rr_resolved
    _rr_resolved=$(cd "$repo_root" 2>/dev/null && pwd -P) || _rr_resolved=""
    [[ -n "$_rr_resolved" ]] && repo_root="$_rr_resolved"

    local cfg
    cfg=$(_kb_overlay_config_path)
    # best_lines carries one "<team> -> <kanban_dir>" entry per team id at
    # the winning depth (for the printed listing); best_kd carries just the
    # kanban_dir side of the same entries, in the same order, so the count
    # below can be de-duplicated to DISTINCT values (XACA-0883-027) without
    # re-parsing best_lines' "tid -> kd" strings.
    local -a best_lines best_kd
    if [[ -f "$cfg" ]]; then
        local triples=""
        if command -v jq &>/dev/null; then
            triples=$(jq -r '
                .teams
                | to_entries[]
                | select(.value.working_dir != null and .value.kanban_dir != null and .value.working_dir != "" and .value.kanban_dir != "")
                | "\(.key)\t\(.value.working_dir)\t\(.value.kanban_dir)"
            ' "$cfg" 2>/dev/null)
        elif command -v python3 &>/dev/null; then
            triples=$(python3 - "$cfg" <<'PYEOF'
import json, sys
cfg = sys.argv[1]
try:
    with open(cfg) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
for tid, entry in data.get("teams", {}).items():
    if not isinstance(entry, dict):
        continue
    wd = entry.get("working_dir")
    kd = entry.get("kanban_dir")
    if wd and kd:
        print(f"{tid}\t{wd}\t{kd}")
PYEOF
)
        fi

        if [[ -n "$triples" ]]; then
            local best_depth=-1 tid wd kd depth _wd_resolved
            while IFS=$'\t' read -r tid wd kd; do
                [[ -z "$wd" || -z "$kd" ]] && continue
                wd="${wd%/}"
                # XACA-0883-022: mirror the resolver's symlink normalization.
                _wd_resolved=$(cd "$wd" 2>/dev/null && pwd -P) || _wd_resolved=""
                [[ -n "$_wd_resolved" ]] && wd="$_wd_resolved"
                if [[ "$repo_root" != "$wd" ]] && [[ "$repo_root" != "$wd"/* ]]; then
                    continue
                fi
                # Same existence gate as the resolver (L1) — a stale entry
                # must not be listed as a live conflicting candidate.
                [[ ! -d "$kd" ]] && continue
                depth=${#wd}
                if (( depth > best_depth )); then
                    best_depth=$depth
                    best_lines=("${tid} -> ${kd}")
                    best_kd=("$kd")
                elif (( depth == best_depth )); then
                    best_lines+=("${tid} -> ${kd}")
                    best_kd+=("$kd")
                fi
            done <<< "$triples"
        fi
    fi

    # XACA-0883-027: group the winning-depth entries by kanban_dir VALUE, not
    # by team id. Several team ids legitimately sharing one kanban_dir is
    # normal (L2, same rule the resolver applies) — the resolver's own count
    # in _kb_canonical_kanban_dir_for_repo already reflects DISTINCT values;
    # this reporter used to count best_lines (one line per team id) instead,
    # so two AGREEING team ids plus one genuinely divergent "stray" printed
    # "3 registry entries claim it with DIFFERENT values" when only 2
    # distinct values exist. `${(u)best_kd}` is zsh's
    # unique-array expansion — no extra loop needed to de-dupe.
    # Declared here (function scope, not inside the loop below) per this
    # repo's zsh `local`-in-loop rule: a bare `local` re-executed inside a
    # loop leaks the assignment to stdout and corrupts the caller's capture.
    local -a distinct_kd
    distinct_kd=("${(u)best_kd[@]}")
    local _kd_key _t
    local -a _tid_list
    local -A kd_teams

    {
        # XACA-0883-020: with an empty candidate list the old wording emitted
        # "0 registry entries claim it with DIFFERENT values", which is
        # self-contradictory and sends the reader hunting for a conflict that
        # does not exist. Report the actual condition instead.
        if (( ${#best_lines[@]} == 0 )); then
            echo "Error: cannot determine the canonical kanban directory for this repo — no registry entry claims it, and no sibling kanban directory with a board file was found."
        else
    # XACA-0883-033: the singular form of this message would be
    # self-contradictory -- one distinct kanban directory is not a conflict at
    # all. It is also unreachable: this reporter's sole caller invokes it only
    # when the resolver returns rc=2, and the resolver sets that only after
    # seeing a same-depth candidate whose kanban_dir DIFFERS from the first one
    # recorded at that depth, so at least 2 distinct values exist. This reporter
    # re-derives distinct_kd over the identical filter chain, so it can never be
    # 1 here. Do not reintroduce a singular/plural branch without first proving
    # distinct_kd can be 1 when rc=2.
            echo "Error: cannot determine the canonical kanban directory for this repo — ${#distinct_kd[@]} distinct kanban directories are claimed by ${#best_lines[@]} registry entries at the same depth:"
        fi
        # Group by kanban_dir value so agreeing team ids (normal, L2) are
        # visually distinct from a genuinely conflicting value, rather than
        # a flat "tid -> value" list that reads as N-way disagreement.
        local _bi _bi_tid _bi_kd
        for _bi in "${best_lines[@]}"; do
            _bi_tid="${_bi%% -> *}"
            _bi_kd="${_bi#* -> }"
            if [[ -n "${kd_teams[$_bi_kd]-}" ]]; then
                kd_teams[$_bi_kd]="${kd_teams[$_bi_kd]} ${_bi_tid}"
            else
                kd_teams[$_bi_kd]="$_bi_tid"
            fi
        done
        for _kd_key in "${distinct_kd[@]}"; do
            _tid_list=(${=kd_teams[$_kd_key]})
            echo "  ${_kd_key} (${#_tid_list[@]} $([[ ${#_tid_list[@]} -eq 1 ]] && echo entry || echo entries)):"
            for _t in "${_tid_list[@]}"; do
                echo "    ${_t}"
            done
        done
        echo "Refusing to write project knowledge to a base that cannot be attributed to one team (XACA-0883)."
        echo "  Fix: correct the divergent kanban_dir entries in ~/.aiteamforge/team-paths.json (see kb-port-reconcile's sibling problem), or set KB_KNOWLEDGE_PROJECT_PATH to an explicit absolute path for this session."
        echo "  Override: pass --allow-nonstandard-base to write to ${resolved_path} as resolved, accepting an unattributed base."
    } >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# _kb_knowledge_project_layout_guard <resolved_path> <allow_nonstandard:true|false> \
#                                     [<force_noninteractive:true|false>]
# (XACA-0883-004, per the 005 guard contract; 3rd param added XACA-0883-021/024)
# ─────────────────────────────────────────────────────────────────────────────
#
# force_noninteractive (default false): when "true", the T1 interactive
# prompt branch is skipped even under a real tty, and the non-interactive
# (redirect + report, never block) branch runs instead. Exists solely for
# kb-knowledge-promote's dry-run mode: a preview must not ask the user a
# question it isn't going to act on. Omitting this argument (every existing
# caller, including kb-knowledge-add) leaves behavior byte-identical to
# before this parameter existed — plain tty detection, same as always.
#
# stdout: the path the caller MUST use (possibly redirected to the canonical
#         base). return: 0 = proceed with the path on stdout; 1 = refuse.
#
# Protects DESTINATION CORRECTNESS, not PII — that is
# _kb_ambiguous_tier_write_guard's job, an independent, orthogonal invariant.
# Ordering is load-bearing: the PII guard MUST run FIRST, on the pre-redirect
# path, before this guard is even called — see the required call-site shape
# at kb-knowledge-add's bare-project branch. Running this guard first would
# open a real bypass: redirecting the path out from under
# ${global_root}/projects/ makes the PII gate's prefix test
# (`[[ "$target_dir" == "${global_root}/projects/"* ]]`) stop matching,
# silently skipping a PII check that should have fired.
#
# "Fail closed" here means REDIRECT-TO-CANONICAL, not refuse — the canonical
# kanban dir is the vouched-for destination, so redirecting to it IS the
# fail-closed action; writing to the unvouched, unredirected path is the
# fail-open one. Only T3 (an unattributable repo — a genuine same-depth
# registry disagreement) refuses outright. This is the counterintuitive part
# of the contract; do not "fix" it by making T1 refuse instead of redirect.
#
# T1 (structural, GATING): resolved_path is inside a git work-tree, the
#   canonical kanban dir for that work-tree resolves AND exists, and
#   resolved_path is not already under it. Trips → redirect (interactive:
#   ask first; non-interactive: redirect + report, never block).
# T2 (branch/env-token slug, ADVISORY ONLY): never gates on its own — observed
#   false negatives (umbrella sub-repos with wrong bases behind
#   legitimate-looking slugs) and false positives (a repo genuinely named
#   'main-app'/'release-tools') make the token heuristic unfit to gate. Its
#   sole job is one extra diagnostic sentence inside T1's message.
# T3 (ambiguous canonical, GATING, REFUSE): _kb_canonical_kanban_dir_for_repo
#   resolves more than one SAME-DEPTH registry candidate and the candidates
#   DISAGREE (an agreeing multi-match, e.g. two team ids that legitimately
#   share one kanban_dir, is normal and is already collapsed silently by the
#   resolver — L2).
#   Guessing here is exactly how a write lands in another team's live base;
#   refusing is recoverable, a misattributed write is not.
#
# FAIL-OPEN when T1's structural condition can't be established at all — no
# git work-tree, or the canonical resolver returns nothing (not disagreement,
# just no answer): unregistered container/freelance projects and umbrella
# sub-repos, and any repo the sibling probe can't reach, must not be blocked.
# Absence of a canonical answer is not evidence of a wrong destination.
_kb_knowledge_project_layout_guard() {
    local resolved_path="${1-}"
    local allow_nonstandard="${2:-false}"
    local force_noninteractive="${3:-false}"

    if [[ -z "$resolved_path" ]]; then
        echo "$resolved_path"
        return 0
    fi

    # --allow-nonstandard-base short-circuits everything: write to the
    # resolved path exactly as given, no probing, no prompt, no warning.
    # Does NOT waive the PII guard — that already ran, separately, before
    # this function was ever called.
    if [[ "$allow_nonstandard" == "true" ]]; then
        echo "$resolved_path"
        return 0
    fi

    # T1.1: is resolved_path inside a git work-tree? Probe from the nearest
    # EXISTING ancestor — the target project-knowledge dir itself normally
    # doesn't exist yet (kb-knowledge-add mkdir -p's it downstream).
    local probe_dir="$resolved_path" parent
    while [[ ! -d "$probe_dir" ]]; do
        parent=$(dirname "$probe_dir")
        [[ "$parent" == "$probe_dir" ]] && break
        probe_dir="$parent"
    done
    if [[ ! -d "$probe_dir" ]]; then
        echo "$resolved_path"
        return 0
    fi

    local wt
    wt=$(git -C "$probe_dir" rev-parse --show-toplevel 2>/dev/null)
    if [[ -z "$wt" ]]; then
        # Not inside a git work-tree at all — T1's structural condition
        # doesn't hold. Fail open.
        echo "$resolved_path"
        return 0
    fi
    wt="${wt%/}"

    # T1.2 / T3: resolve the canonical kanban dir for this work-tree.
    # _kb_canonical_kanban_dir_for_repo already fails closed on a same-depth
    # registry DISAGREEMENT (prints its own diagnostic to stderr, returns 1)
    # and collapses an AGREEING multi-match silently (L2) — capture its
    # stderr so the two rc=1 cases (disagreement vs. plain "no answer") can
    # be told apart below.
    # XACA-0883-019: classify the failure by EXIT CODE, not by grepping stderr.
    # The previous implementation captured stderr into a temp file purely to
    # tell "ambiguous" from "no answer", and fell back to a predictable
    # "$$"-suffixed path when mktemp failed — a symlink/clobber vector. The
    # resolver now returns 2 for ambiguous and 1 for no-answer, so there is no
    # temp file, no fallback path, and no filesystem dependency. Diagnostics
    # still flow to the caller's stderr, where a human can actually see them.
    local canon
    canon=$(_kb_canonical_kanban_dir_for_repo "$wt")
    local canon_rc=$?

    if (( canon_rc != 0 )); then
        if (( canon_rc == 2 )); then
            # T3: ambiguous canonical — GATING, REFUSE, no redirect, no
            # directory created, no file written.
            _kb_knowledge_layout_guard_report_t3 "$wt" "$resolved_path"
            return 1
        fi
        # No canonical answer at all (no registry hit, no sibling-probe
        # match) — T1.2 fails open, silently. This is the common, expected
        # case for unregistered/freelance/umbrella-sub-repo projects.
        echo "$resolved_path"
        return 0
    fi

    if [[ -z "$canon" ]] || [[ ! -d "$canon" ]]; then
        # Belt-and-suspenders: the resolver already gates every candidate on
        # [ -d ] (L1), so this shouldn't fire — fail open anyway rather than
        # trust an rc=0/empty-or-gone combination blind.
        echo "$resolved_path"
        return 0
    fi

    # T1.3: resolved_path already under the canonical base → nothing to do.
    # This is the common case once the XACA-0883 case-2 fix in
    # _kb_knowledge_project_path is in effect; this guard exists for the
    # residue (an in-repo .knowledge-config.yml override, a caller-supplied
    # path, or a session that hasn't picked up the fixed template yet).
    if [[ "$resolved_path" == "$canon" ]] || [[ "$resolved_path" == "${canon}/"* ]]; then
        echo "$resolved_path"
        return 0
    fi

    # T1 has tripped: resolved_path is inside the work-tree, the canonical
    # dir resolves and exists, and resolved_path is NOT under it.
    local canonical_path="${canon}/knowledge/project"

    # T2 (advisory only — never gates): does the work-tree's own basename, or
    # its current branch name, look like a branch/environment slug rather
    # than a project name? Case-insensitive per contract; zsh [[ =~ ]] is
    # case-sensitive by default, so lowercase both sides via ${(L)...}
    # instead of relying on a shell option.
    local repo_basename branch_name t2_hit=false
    repo_basename=$(basename "$wt")
    local repo_basename_lc="${(L)repo_basename}"
    if [[ "$repo_basename_lc" =~ ^(dev|qa|prod|stage|staging|uat|develop|development|main|master|trunk|release|hotfix|feature)([-_/].*)?$ ]]; then
        t2_hit=true
    else
        branch_name=$(git -C "$wt" branch --show-current 2>/dev/null)
        if [[ -n "$branch_name" ]] && [[ "$repo_basename_lc" == "${(L)branch_name}" ]]; then
            t2_hit=true
        fi
    fi

    # Interactive vs non-interactive: shape differs by who's watching
    # (contract §3.3). Disclosure goes to stderr, so test -t 2 as well as
    # -t 0 — prompting when stderr is redirected would be an invisible
    # prompt. Precedent for the TTY test: kanban-helpers.sh:9980, :10121.
    # force_noninteractive short-circuits this even under a real tty — see
    # this function's header comment (XACA-0883-021/024, kb-knowledge-promote
    # dry-run). Defaults to false, so every caller that omits the 3rd
    # argument (including kb-knowledge-add) is unaffected.
    if [[ "$force_noninteractive" != "true" ]] && [[ -t 0 ]] && [[ -t 2 ]]; then
        {
            echo "Warning: this project-knowledge write resolves INSIDE the git work-tree, but this repo's canonical kanban directory is a sibling of it (XACA-0883)."
            echo "  Resolved:  ${resolved_path}"
            echo "  Canonical: ${canonical_path}"
            if $t2_hit; then
                echo "  The project id '${repo_basename}' looks like a branch or environment name, not a project — that is the signature of this bug."
            fi
            echo "Writing to the resolved path creates a SECOND, invisible knowledge base that kb-knowledge-search will not read."
        } >&2
        local layout_confirm
        printf "Write to the canonical base instead? [Y/n] " >&2
        read -r layout_confirm
        # XACA-0883-018: accept the full word too. Matching only a single
        # character meant a user who typed "no" fell through to the DEFAULT
        # (redirect) — i.e. their explicit refusal was silently inverted.
        # Leading/trailing whitespace is trimmed so " n " still declines.
        layout_confirm="${layout_confirm#"${layout_confirm%%[![:space:]]*}"}"
        layout_confirm="${layout_confirm%"${layout_confirm##*[![:space:]]}"}"
        if [[ "$layout_confirm" == [Nn] ]] || [[ "$layout_confirm" == [Nn][Oo] ]]; then
            echo "Warning: writing to the non-canonical base ${resolved_path} as instructed. This entry will not be visible to sessions resolving the canonical base." >&2
            echo "$resolved_path"
            return 0
        fi
        echo "$canonical_path"
        return 0
    fi

    # Non-interactive (agent, hook, pipe, CI): redirect + report. Do NOT
    # prompt, do NOT block — blocking here would break the mandatory
    # retrospective/knowledge-capture step at the end of every project, and
    # losing the entry is strictly worse than writing it to the correct base.
    echo "Warning: project-knowledge write redirected from ${resolved_path} to ${canonical_path} — the resolved path is inside the git work-tree, but this repo's canonical kanban directory is a sibling (XACA-0883). Pass --allow-nonstandard-base to write to the resolved path instead." >&2
    echo "$canonical_path"
    return 0
}

# Internal: resolve project knowledge path
# Precedence: .knowledge-config.yml → KB_KNOWLEDGE_PROJECT_PATH → default
# Writes result to stdout; returns 1 if not inside a git repo.
_kb_knowledge_project_path() {
    local repo_root project_slug

    # Worktree-aware root resolution: --show-toplevel returns the worktree dir, not
    # the main repo. Use --git-common-dir to locate the shared .git, then derive the
    # main repo root from it — project knowledge must always resolve to the main worktree.
    local git_common_dir
    git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
    if [[ -z "$git_common_dir" ]]; then
        # Not inside a git repo — use default under global root with "unknown" slug
        echo "$(_kb_knowledge_global_root)/projects/unknown"
        return 0
    fi
    if [[ "$git_common_dir" == ".git" ]]; then
        # Main worktree: --git-common-dir is relative, --show-toplevel is correct
        repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
    else
        # Feature worktree: --git-common-dir is the absolute main .git; parent is main repo
        repo_root=$(dirname "$git_common_dir")
    fi

    project_slug=$(basename "$repo_root")

    # 1. Per-project config file
    #
    # XACA-0883: probe TWO locations, in priority order:
    #   (i)  ${repo_root}/.knowledge-config.yml      — the historical location
    #   (ii) ${container_root}/.knowledge-config.yml — where scripts/kb-init-team
    #        (_create_dir_tree) actually WRITES it: at the team's registry
    #        working_dir, which for a container-layout team is the CONTAINER, not
    #        the git work-tree. For those teams (i) and (ii) never coincide, so a
    #        config written by kb-init-team was invisible to this reader. The gap
    #        is dormant only while no .knowledge-config.yml exists anywhere;
    #        because case 1 OUTRANKS case 2, the first kb-init-team run would
    #        otherwise silently defeat this ticket's entire case-2 fix.
    #
    # A relative ./path is expanded against the directory the config was FOUND in,
    # NOT blindly against repo_root. Expanding a container-written
    # './kanban/knowledge/project' against the work-tree would reintroduce the
    # exact shadow-base bug this ticket exists to close.
    local -a _kc_candidates
    _kc_candidates=( "${repo_root}/.knowledge-config.yml" )
    local _kc_canonical _kc_container
    _kc_canonical=$(_kb_canonical_kanban_dir_for_repo "$repo_root" 2>/dev/null) || _kc_canonical=""
    if [[ -n "$_kc_canonical" ]]; then
        _kc_container=$(dirname "$_kc_canonical")
        if [[ -n "$_kc_container" && "$_kc_container" != "$repo_root" ]]; then
            _kc_candidates+=( "${_kc_container}/.knowledge-config.yml" )
        fi
    fi

    # NOTE (zsh trap): both `config_file` and `config_path` MUST be declared here,
    # OUTSIDE the loop. A bare `local X` re-executed for an already-declared local
    # makes zsh print "X=<value>" to STDOUT, so a second loop iteration would
    # prepend a junk line to this function's return value. That happens whenever
    # the first candidate exists but yields no usable value. Caught in review of
    # PR #755; regression-tested in kb-knowledge-project-path-layout.bats.
    local config_file config_path
    for config_file in "${_kc_candidates[@]}"; do
        [[ -f "$config_file" ]] || continue
        config_path=$(grep -m1 '^project_knowledge_path:' "$config_file" 2>/dev/null | sed 's/^project_knowledge_path:[[:space:]]*//' | tr -d '"'"'")
        # Trim leading/trailing whitespace without xargs (which splits on whitespace and corrupts paths with spaces)
        config_path="${config_path## }"
        config_path="${config_path%% }"
        if [[ -n "$config_path" ]]; then
            # Expand leading ./ relative to the config file's OWN directory (see above)
            if [[ "$config_path" == ./* ]]; then
                config_path="$(dirname "$config_file")/${config_path#./}"
            fi
            echo "$config_path"
            return 0
        fi
    done

    # 2. KB_KNOWLEDGE_PROJECT_PATH env var (template-expand {repo_root},
    #    {project}, and {kanban_dir})
    if [[ -n "$KB_KNOWLEDGE_PROJECT_PATH" ]]; then
        # XACA-0883 (D1): resolve the canonical kanban dir once so both halves
        # of the fix can use it — (a) the new {kanban_dir} token, and (b) the
        # layout-correction rewrite below. Fails open (empty var) when the repo
        # can't be attributed with confidence — see the fail-open block below.
        local canonical_kanban_dir=""
        canonical_kanban_dir=$(_kb_canonical_kanban_dir_for_repo "$repo_root" 2>/dev/null) || canonical_kanban_dir=""

        local expanded="${KB_KNOWLEDGE_PROJECT_PATH//\{repo_root\}/$repo_root}"
        expanded="${expanded//\{project\}/$project_slug}"
        # (a) New token (XACA-0883 D1a): the going-forward way to reference the
        # canonical kanban dir directly, instead of deriving it from
        # {repo_root}. Left UNEXPANDED (literal "{kanban_dir}") when the repo
        # can't be resolved — there is no deployed usage of this token yet to
        # protect with a fallback, so leaving it literal surfaces the problem
        # instead of silently guessing.
        if [[ -n "$canonical_kanban_dir" ]]; then
            expanded="${expanded//\{kanban_dir\}/$canonical_kanban_dir}"
        fi

        # (b) Layout-correct the existing {repo_root}-derived form (XACA-0883
        # D1b). Deployed team shells commonly export the identical
        # '{repo_root}/kanban/knowledge/project'. For container-layout teams
        # (iOS/Android/Firebase/DNS) repo_root is the git work-tree,
        # a CHILD of the container, while the real kanban/ is the container's —
        # a SIBLING of the work-tree. Unpatched, that template expands to a
        # shadow kanban/ under the work-tree instead of the canonical one.
        # Re-root any expansion whose "kanban" segment came from {repo_root}
        # onto the canonical kanban dir, preserving whatever comes after
        # "kanban" verbatim (a team could point the template somewhere other
        # than knowledge/project under kanban/, so this must not hardcode
        # that suffix).
        #
        # FAIL-OPEN, non-negotiable (XACA-0883 guard contract §3.2): if the
        # canonical dir can't be resolved with confidence, or it's identical
        # to {repo_root}/kanban (the kanban-inside-repo case, where no
        # rewrite is needed), emit exactly what the pre-fix code emitted.
        # There are unregistered container/freelance projects the registry
        # cannot resolve; breaking them would be a worse regression than the
        # bug being fixed. Silent — no warning spam on every call.
        if [[ -n "$canonical_kanban_dir" ]] && [[ "$canonical_kanban_dir" != "${repo_root}/kanban" ]]; then
            local legacy_kanban_prefix="${repo_root}/kanban"
            # XACA-0883-017: the prefix must end on a PATH-SEGMENT boundary.
            # A bare "$prefix"* also matches sibling directories that merely
            # start with the same characters — '{repo_root}/kanban-archive/...'
            # or '{repo_root}/kanbanX' would be silently re-rooted onto the
            # canonical kanban dir, corrupting a path this fix has no business
            # touching. Accept only an exact match or a real child.
            if [[ "$expanded" == "$legacy_kanban_prefix" ]] || [[ "$expanded" == "${legacy_kanban_prefix}"/* ]]; then
                expanded="${canonical_kanban_dir}${expanded#${legacy_kanban_prefix}}"
            fi
        fi

        echo "$expanded"
        return 0
    fi

    # 3. Default
    echo "$(_kb_knowledge_global_root)/projects/${project_slug}"
}

# ─────────────────────────────────────────────────────────────────────────────
# _kb_knowledge_project_path_legacy (TRANSITIONAL — XACA-0883)
# ─────────────────────────────────────────────────────────────────────────────
#
# Returns the LEGACY (pre-XACA-0883) case-2 resolution — i.e. exactly what
# _kb_knowledge_project_path would have returned before this ticket's layout
# fix, with no {kanban_dir} token and no {repo_root}/kanban re-rooting.
# Cases 1 and 3 are byte-identical to the current resolver (this ticket did
# not touch them) and are duplicated here only so this function is a complete,
# self-contained "what used to happen" answer.
#
# Why this exists: pre-fix installs may already have knowledge entries sitting
# in shadow bases created by the pre-fix resolver — some of them another
# team's LIVE, actively-written base, which is deliberately NOT ours to
# reconcile/move as part of this fix. The instant the writer/reader resolver
# flips to the canonical path, kb-knowledge-search stops finding those entries
# unless something still looks in the old place. That "something" is this
# function, consumed ONLY by kb-knowledge-search's project-tier reader (never
# by any writer — writers must target the canonical base exclusively).
#
# DELETE CONDITION: once a shadow-base sweep confirms every legacy base is
# empty (or reconciled), delete this function and its call site in
# kb-knowledge-search's project-tier resolution.
_kb_knowledge_project_path_legacy() {
    local repo_root project_slug

    local git_common_dir
    git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
    if [[ -z "$git_common_dir" ]]; then
        echo "$(_kb_knowledge_global_root)/projects/unknown"
        return 0
    fi
    if [[ "$git_common_dir" == ".git" ]]; then
        repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
    else
        repo_root=$(dirname "$git_common_dir")
    fi

    project_slug=$(basename "$repo_root")

    # 1. Per-project config file (unchanged by XACA-0883 — duplicated verbatim)
    local config_file="${repo_root}/.knowledge-config.yml"
    if [[ -f "$config_file" ]]; then
        local config_path
        config_path=$(grep -m1 '^project_knowledge_path:' "$config_file" 2>/dev/null | sed 's/^project_knowledge_path:[[:space:]]*//' | tr -d '"'"'")
        config_path="${config_path## }"
        config_path="${config_path%% }"
        if [[ -n "$config_path" ]]; then
            if [[ "$config_path" == ./* ]]; then
                config_path="${repo_root}/${config_path#./}"
            fi
            echo "$config_path"
            return 0
        fi
    fi

    # 2. KB_KNOWLEDGE_PROJECT_PATH env var — LEGACY expansion: {repo_root} and
    #    {project} only, no {kanban_dir} token, no re-rooting rewrite.
    if [[ -n "$KB_KNOWLEDGE_PROJECT_PATH" ]]; then
        local expanded="${KB_KNOWLEDGE_PROJECT_PATH//\{repo_root\}/$repo_root}"
        expanded="${expanded//\{project\}/$project_slug}"
        echo "$expanded"
        return 0
    fi

    # 3. Default (unchanged by XACA-0883 — duplicated verbatim)
    echo "$(_kb_knowledge_global_root)/projects/${project_slug}"
}

# _kb_knowledge_project_path_effective
# Same as _kb_knowledge_project_path, EXCEPT: when that resolution falls all
# the way through to case 3 (the bare "${global_root}/projects/<slug>"
# default) AND the current session's team is local-only, redirect to the
# equivalent path under local_root instead (XACA-0754-013, ported XACA-0770).
#
# Why only case 3: cases 1 (.knowledge-config.yml) and 2
# (KB_KNOWLEDGE_PROJECT_PATH) already point project knowledge OUTSIDE
# $KB_KNOWLEDGE_GLOBAL_ROOT entirely (typically in-repo) — they are never at
# risk of syncing PII fleet-wide, so redirecting them would be pointless
# indirection.
#
# Used by BOTH the writer (kb-knowledge-add's bare-project branch) and the
# reader (kb-knowledge-search's unfiltered "current project" resolution, and
# kb-knowledge-reindex's project_path reindex) so a local-redirected write is
# never orphaned from search/reindex.
_kb_knowledge_project_path_effective() {
    local base
    base=$(_kb_knowledge_project_path) || return $?

    local global_root
    global_root=$(_kb_knowledge_global_root)
    if [[ "$base" == "${global_root}/projects/"* ]] && _kb_current_session_is_local_only_team; then
        local local_root
        local_root=$(_kb_knowledge_local_root)
        echo "${local_root}/projects/${base#${global_root}/projects/}"
        return 0
    fi
    echo "$base"
}

# Internal: derive a human-readable project display name from the project knowledge dir path.
# Resolution order:
#   a. .kb-project sentinel in $dir or ancestors (up to 3 levels up) — first non-blank line
#   b. In-repo layout: */kanban/knowledge/project → owning project's name (XACA-0883:
#      layout-aware — see below, NOT a naive dirname^3 of $dir)
#   c. Fallback: basename($dir)
#
# NOTE on .kb-project sentinel (XACA-0389 / F-08-009):
#   .kb-project is an OPTIONAL, per-machine, user-created file (not committed to
#   any repo). It is absent by default. Its sole purpose is overriding the
#   display name shown in kb-knowledge-search output for projects whose directory
#   basename is not a friendly name. When absent, resolution falls through to (b)
#   or (c), both of which always produce a non-empty result — absence is expected,
#   not an error condition.
#
# NOTE on branch (b) and container layouts (XACA-0883):
#   dirname^3($dir) (strip "/kanban/knowledge/project") assumes the "kanban"
#   directory directly above is the CANONICAL one — true for kanban-inside-repo
#   teams (Academy/Command/Finance/Legal/Medical: dirname^3 IS the repo root),
#   but false for container-layout teams (iOS/Android/Firebase/DNS),
#   where the git work-tree is a CHILD of the container and the real kanban/ is
#   a SIBLING of it. A path rooted at the work-tree's shadow kanban/ (e.g.
#   .../{{ORG_NAME}}App-iOS/DEV/kanban/knowledge/project — still reachable here via
#   a caller-supplied --dir, or via the XACA-0883 transitional legacy-base
#   union while shadow entries remain unswept) would naively yield the
#   work-tree's basename ("DEV") instead of the project's ("{{ORG_NAME}}App-iOS").
#   Fixed by resolving the CANONICAL kanban dir for the naive container and
#   using its parent's basename instead; falls open to the naive dirname^3
#   result when the canonical resolver can't attribute the repo (unregistered
#   project, no sibling probe match) — same fail-open contract as
#   _kb_canonical_kanban_dir_for_repo's other callers.
# Usage: _kb_knowledge_project_display_name <project_knowledge_dir>
_kb_knowledge_project_display_name() {
    setopt LOCAL_OPTIONS NO_NOMATCH
    local dir="${1-}"

    # (a) .kb-project sentinel search: $dir and up to 3 ancestor levels
    local search_dir="$dir"
    local sentinel_val=""
    local level
    for level in 0 1 2 3; do
        local sentinel_file="${search_dir}/.kb-project"
        if [[ -f "$sentinel_file" ]]; then
            # Read first non-blank, trimmed line
            sentinel_val=$(grep -m1 '[^[:space:]]' "$sentinel_file" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$sentinel_val" ]]; then
                echo "$sentinel_val"
                return 0
            fi
            break  # found sentinel but it was empty — fall through
        fi
        search_dir=$(dirname "$search_dir")
    done

    # (b) In-repo layout: .../kanban/knowledge/project → owning project's name
    if [[ "$dir" == */kanban/knowledge/project ]]; then
        # Strip "/kanban/knowledge/project" to get the naive container — correct
        # as-is for kanban-inside-repo teams, but for container-layout teams this
        # may be the work-tree (e.g. .../{{ORG_NAME}}App-iOS/DEV), not the container.
        local naive_container
        naive_container=$(dirname "$(dirname "$(dirname "$dir")")")

        # Resolve the CANONICAL kanban dir for that container (registry lookup +
        # sibling probe, XACA-0883-001) and report ITS parent's basename instead
        # — this is what re-attributes a work-tree path back to the project it
        # actually belongs to. Fails open to the naive basename when the
        # resolver can't attribute the repo (unregistered project, no sibling
        # match): a wrong display name is a cosmetic regression, but inventing
        # one from a resolver that admitted it couldn't attribute the repo
        # would be worse.
        local canonical_kanban_dir=""
        canonical_kanban_dir=$(_kb_canonical_kanban_dir_for_repo "$naive_container" 2>/dev/null) || canonical_kanban_dir=""

        if [[ -n "$canonical_kanban_dir" ]]; then
            echo "$(basename "$(dirname "$canonical_kanban_dir")")"
        else
            echo "$(basename "$naive_container")"
        fi
        return 0
    fi

    # (c) Fallback
    echo "$(basename "$dir")"
}

# Internal: return numeric rank for a tier name (low = narrow, high = broad).
# Used by kb-knowledge-promote to enforce SPEC §7 (upward-only movement).
# Empty output (and no echo) means the tier is unknown.
_kb_knowledge_tier_rank() {
    case "${1-}" in
        agents)   echo 1 ;;
        project)  echo 2 ;;
        teams)    echo 3 ;;
        subjects) echo 4 ;;
        *)        return 1 ;;
    esac
}

# Internal: resolve a cross-reference string to an absolute file path
# Returns 0+path on success, 1 on error
_kb_knowledge_resolve_ref() {
    local ref="${1-}" global_root="${2-}"
    local tier="${ref%%:*}"
    local remainder="${ref#*:}"

    # Helper: given a target_dir and entry_id, resolve to actual file path.
    # Short 3-digit IDs (e.g. k001) glob-expand to k001-actual-slug.md.
    _kb_resolve_entry_path() {
        local target_dir="${1-}" entry_id="${2-}"
        # If it looks like a bare short ID (prefix + exactly 3 digits, no dash), glob-expand
        if [[ "$entry_id" =~ ^[ktspmv][0-9][0-9][0-9]$ ]]; then
            local -a glob_matches
            glob_matches=( "${target_dir}/${entry_id}-"*.md )
            if [[ ${#glob_matches[@]} -gt 0 ]] && [[ -e "${glob_matches[1]}" ]]; then
                echo "${glob_matches[1]}"
                return 0
            fi
        fi
        echo "${target_dir}/${entry_id}.md"
    }

    case "$tier" in
        agents)
            local persona="${remainder%%:*}"
            local entry_id="${remainder#*:}"
            if ! _kb_validate_name_component "$persona"; then
                echo "Error: invalid persona name '${persona}' in ref '${ref}' — must match ^[a-z][a-z0-9_-]*$ (no path traversal)" >&2
                return 1
            fi
            _kb_resolve_entry_path "${global_root}/agents/${persona}" "$entry_id"
            ;;
        teams)
            local team="${remainder%%:*}"
            local entry_id="${remainder#*:}"
            if ! _kb_validate_name_component "$team"; then
                echo "Error: invalid team name '${team}' in ref '${ref}' — must match ^[a-z][a-z0-9_-]*$ (no path traversal)" >&2
                return 1
            fi
            _kb_resolve_entry_path "${global_root}/teams/${team}" "$entry_id"
            ;;
        subjects)
            # All tokens except the last form the path; last token is the entry ID
            local last_token="${remainder##*:}"
            local path_part="${remainder%:*}"
            # If remainder has no colon, there's only an entry ID (no path)
            if [[ "$path_part" == "$remainder" ]]; then
                echo "Error: subjects ref needs at least subjects:<path>:<entry-id>" >&2
                return 1
            fi
            local subj_path
            subj_path=$(printf '%s' "$path_part" | tr ':' '/')
            if ! _kb_validate_subject_path "$subj_path"; then
                echo "Error: invalid subject path '${subj_path}' in ref '${ref}' — each component must match ^[a-z][a-z0-9_-]*$ (no path traversal)" >&2
                return 1
            fi
            _kb_resolve_entry_path "${global_root}/subjects/${subj_path}" "$last_token"
            ;;
        project)
            local tokens=( ${(s.:.)remainder} )
            if [[ ${#tokens[@]} -ge 2 ]]; then
                # project:<slug>:<entry-id>
                local proj_slug="${tokens[1]}"
                if ! _kb_validate_name_component "$proj_slug"; then
                    echo "Error: invalid project slug '${proj_slug}' in ref '${ref}' — must match ^[a-z][a-z0-9_-]*$ (no path traversal)" >&2
                    return 1
                fi
                _kb_resolve_entry_path "${global_root}/projects/${proj_slug}" "${tokens[2]}"
            else
                # project:<entry-id>
                local proj_path
                proj_path=$(_kb_knowledge_project_path)
                _kb_resolve_entry_path "$proj_path" "$remainder"
            fi
            ;;
        *)
            echo "Error: unknown tier '${tier}' in ref '${ref}'" >&2
            return 1
            ;;
    esac
}

# Internal: regenerate INDEX.md for a single tier directory
_kb_knowledge_reindex_one() {
    setopt LOCAL_OPTIONS NO_NOMATCH
    local dir="${1-}"
    local today=$(date +%Y-%m-%d)
    local index_file="${dir}/INDEX.md"

    # Determine tier from directory location
    local global_root=$(_kb_knowledge_global_root)
    local local_root=$(_kb_knowledge_local_root)
    local dir_tier
    if [[ "$dir" == "${global_root}/agents/"* ]] || [[ "$dir" == "${local_root}/agents/"* ]]; then
        dir_tier="agent"
    elif [[ "$dir" == "${global_root}/teams/"* ]] || [[ "$dir" == "${local_root}/teams/"* ]]; then
        dir_tier="team"
    elif [[ "$dir" == "${global_root}/subjects/"* ]] || [[ "$dir" == "${local_root}/subjects/"* ]]; then
        dir_tier="subject"
    else
        dir_tier="project"
    fi

    # Determine display name from directory path
    local dir_name=$(basename "$dir")
    # Capitalize first letter for agent tier headers (e.g. thok → Thok)
    local dir_name_cap="${(C)dir_name[1]}${dir_name:1}"
    local display_name
    case "$dir_tier" in
        agent)   display_name="${dir_name_cap} Knowledge Index" ;;
        team)    display_name="${dir_name} Team Knowledge Index" ;;
        subject) display_name="${dir_name} — ${dir_name} Knowledge" ;;
        project) display_name="Project Knowledge — $(_kb_knowledge_project_display_name "$dir")" ;;
        *)       display_name="${dir_name} Knowledge Index" ;;
    esac

    # Determine file prefix for this tier
    local exp_prefix
    case "$dir_tier" in
        agent)   exp_prefix="k" ;;
        team)    exp_prefix="t" ;;
        subject) exp_prefix="s" ;;
        project) exp_prefix="p" ;;
        *)       exp_prefix="" ;;
    esac

    # Collect all entry files, sorted by ID
    local -a entries
    local -a load_first_entries
    local ef
    for ef in "${dir}/${exp_prefix}"[0-9][0-9][0-9]-*.md; do
        [[ -f "$ef" ]] || continue
        entries+=("$ef")
    done

    if [[ ${#entries[@]} -eq 0 ]]; then
        echo "  [skip] No entries in ${dir}"
        return 0
    fi

    # Build tag map: tag → space-separated list of short IDs (e.g. K001, not k001-full-slug)
    local -A tag_map
    local eid tags_raw tag short_id display_id lf_raw

    for ef in "${entries[@]}"; do
        eid=$(basename "$ef" .md)
        # Extract short ID: strip everything after first dash (k001-some-slug → k001)
        short_id="${eid%%-*}"
        # Capitalize first letter for display (k001 → K001)
        display_id="${(C)short_id[1]}${short_id:1}"
        tags_raw=$(_kb_knowledge_yaml_field "$ef" "tags")
        # Parse YAML list or comma-list: [tag1, tag2] or tag1, tag2
        tags_raw="${tags_raw#\[}"; tags_raw="${tags_raw%\]}"
        # Split on commas — use zsh parameter expansion (IFS splitting doesn't work in zsh without SH_WORD_SPLIT)
        for tag in "${(@s:,:)tags_raw}"; do
            tag="${tag## }"; tag="${tag%% }"   # trim leading/trailing spaces
            tag="${tag//\"/}"                  # strip double quotes
            tag="${tag//\'/}"                  # strip single quotes
            [[ -z "$tag" ]] && continue
            if [[ -n "${tag_map[$tag]:-}" ]]; then
                tag_map[$tag]="${tag_map[$tag]}, ${display_id}"
            else
                tag_map[$tag]="${display_id}"
            fi
        done
        # Collect load_first entries for the "Before Every Project" quick-reference section
        lf_raw=$(_kb_knowledge_yaml_field "$ef" "load_first")
        lf_raw="${lf_raw## }"; lf_raw="${lf_raw%% }"; lf_raw="${lf_raw//\"/}"; lf_raw="${lf_raw//\'/}"
        case "${lf_raw:l}" in
            true|yes|1) load_first_entries+=("$ef") ;;
        esac
    done

    # Find the last/highest ID
    local last_entry_id=$(basename "${entries[-1]}" .md)

    # Preserve "Relevant Subjects" section from existing project INDEX (if present)
    local relevant_subjects_block=""
    if [[ "$dir_tier" == "project" ]] && [[ -f "$index_file" ]]; then
        relevant_subjects_block=$(awk '/^## Relevant Subjects/,/^## [^R]/{if(/^## [^R]/){exit}; print}' "$index_file" 2>/dev/null)
    fi

    # Roundtrip-preserve the curated H1 title and Project line for project tier.
    # This prevents reindex from clobbering hand-edited titles like
    # "Project Knowledge — dev-team (Academy)" with "Project Knowledge — project".
    local curated_h1="" curated_proj_val=""
    if [[ "$dir_tier" == "project" ]] && [[ -f "$index_file" ]]; then
        curated_h1=$(grep -m1 '^# ' "$index_file" 2>/dev/null | sed 's/^# //')
        curated_proj_val=$(grep -m1 '^\*\*Project:\*\*' "$index_file" 2>/dev/null | sed 's/^\*\*Project:\*\*[[:space:]]*//')
    fi
    # If a curated H1 was found, honour it verbatim; otherwise the helper-derived display_name stands.
    [[ -n "$curated_h1" ]] && display_name="$curated_h1"

    # Pre-declare loop variables used inside the {} block to avoid local -A trace leaks on re-declaration
    local etitle edate esource estatus esummary display_eid sdir sname retro_file retro_name
    local agent_name team_name proj_name lf_ef lf_title lf_summary lf_eid lf_display_eid lf_short_id

    # Write the new INDEX.md
    {
        echo "# ${display_name}"
        echo ""

        if [[ "$dir_tier" == "agent" ]]; then
            agent_name=$(basename "$dir")
            echo "**Agent:** ${agent_name}"
        elif [[ "$dir_tier" == "team" ]]; then
            team_name=$(basename "$dir")
            echo "**Team:** ${team_name}"
        elif [[ "$dir_tier" == "project" ]]; then
            if [[ -n "$curated_proj_val" ]]; then
                proj_name="$curated_proj_val"
            else
                proj_name=$(_kb_knowledge_project_display_name "$dir")
            fi
            echo "**Project:** ${proj_name}"
        fi
        echo "**Last Updated:** ${today} (${last_entry_id} added)"
        echo ""
        echo "---"
        echo ""

        # Before Every Project section (any tier — only if load_first entries exist)
        if [[ ${#load_first_entries[@]} -gt 0 ]]; then
            echo "## Before Every Project"
            echo ""
            echo "> Read these entries at the start of every session for this ${dir_tier}."
            echo ""
            for lf_ef in "${load_first_entries[@]}"; do
                lf_eid=$(basename "$lf_ef" .md)
                lf_short_id="${lf_eid%%-*}"
                lf_display_eid="${(C)lf_short_id[1]}${lf_short_id:1}"
                lf_title=$(grep -m1 '^# ' "$lf_ef" 2>/dev/null | sed 's/^# //' | head -1)
                [[ -z "$lf_title" ]] && lf_title="${lf_eid}"
                lf_summary=$(_kb_knowledge_yaml_field "$lf_ef" "summary")
                if [[ -z "$lf_summary" ]]; then
                    lf_summary=$(awk '/^---$/{count++; next} count>=2 && /^[^#[:space:]]/{print; exit}' "$lf_ef" 2>/dev/null | head -1)
                fi
                [[ -z "$lf_summary" ]] && lf_summary="*(add one-sentence summary)*"
                echo "- **${lf_display_eid}:** [${lf_title}](./${lf_eid}.md) — ${lf_summary}"
            done
            echo ""
            echo "---"
            echo ""
        fi

        # Relevant Subjects section (project only)
        if [[ "$dir_tier" == "project" ]]; then
            if [[ -n "$relevant_subjects_block" ]]; then
                echo "$relevant_subjects_block"
                echo ""
            else
                echo "## Relevant Subjects"
                echo ""
                echo "This project's knowledge should be read in conjunction with:"
                echo "- *(add subjects:* references here)*"
                echo ""
            fi
        fi

        # Sub-subjects section (subject parent only)
        if [[ "$dir_tier" == "subject" ]]; then
            local has_subdirs=false
            for sdir in "${dir}"/*/; do
                [[ -d "$sdir" ]] || continue
                has_subdirs=true
                break
            done
            if $has_subdirs; then
                echo "## Sub-subjects"
                echo ""
                for sdir in "${dir}"/*/; do
                    [[ -d "$sdir" ]] || continue
                    sname=$(basename "$sdir")
                    echo "- [${sname}](./${sname}/INDEX.md)"
                done
                echo ""
            fi
        fi

        # Tag Index
        echo "## Tag Index"
        echo ""
        echo "| Tag | Entries |"
        echo "|-----|---------|"
        for tag in "${(@k)tag_map}"; do
            echo "| ${tag} | ${tag_map[$tag]} |"
        done
        echo ""
        echo "---"
        echo ""

        # Entries section
        echo "## Entries"
        echo ""
        for ef in "${entries[@]}"; do
            eid=$(basename "$ef" .md)
            etitle=$(grep -m1 '^# ' "$ef" 2>/dev/null | sed 's/^# //' | head -1)
            [[ -z "$etitle" ]] && etitle="${eid}"
            edate=$(_kb_knowledge_yaml_field "$ef" "date")
            esource=$(_kb_knowledge_yaml_field "$ef" "source")
            estatus=$(_kb_knowledge_yaml_field "$ef" "status")
            # Pull summary from frontmatter, or fall back to first non-blank body line
            esummary=$(_kb_knowledge_yaml_field "$ef" "summary")
            if [[ -z "$esummary" ]]; then
                esummary=$(awk '/^---$/{count++; next} count>=2 && /^[^#[:space:]]/{print; exit}' "$ef" 2>/dev/null | head -1)
            fi
            [[ -z "$esummary" ]] && esummary="*(add one-sentence summary)*"

            display_eid="${eid[1]:u}${eid:1}"
            echo "### ${display_eid}: ${etitle}"
            echo "**File:** \`${eid}.md\`"
            [[ -n "$edate" ]]   && echo "**Date:** ${edate}"
            [[ -n "$esource" ]] && echo "**Source:** ${esource}"
            [[ -n "$estatus" ]] && [[ "$estatus" != "active" ]] && echo "**Status:** ${estatus}"
            echo "**Summary:** ${esummary}"
            echo ""
        done

        # Retrospectives section (project only)
        if [[ "$dir_tier" == "project" ]]; then
            echo "---"
            echo ""
            echo "## Retrospectives"
            echo ""
            local retro_dir="${dir}/retrospectives"
            if [[ -d "$retro_dir" ]]; then
                for retro_file in "${retro_dir}"/*.md; do
                    [[ -f "$retro_file" ]] || continue
                    retro_name=$(basename "$retro_file")
                    echo "- [${retro_name}](./retrospectives/${retro_name})"
                done
            else
                echo "- *(none yet)*"
            fi
            echo ""
        fi
    } > "$index_file"

    echo "  [rebuilt] ${index_file}"
    return 0
}

# kb-knowledge-local-scaffold — ported from dev-team/kanban-helpers.sh (XACA-0754 C7, XACA-0770)
#
# Creates the local (unsynced, PII) knowledge tree for the three known
# local-only teams: ${local_root}/teams/<team>/INDEX.md +
# ${local_root}/agents/<persona>/INDEX.md for each team's persona roster
# (resolved via the hardcoded floor when no agents-master checkout exists,
# which is the normal case on a bare tap machine). Mirrors the team/agent
# INDEX.md template kb-init-team writes for the global tiers. Idempotent —
# never clobbers an existing INDEX.md, safe to re-run.
#
# Honours KB_KNOWLEDGE_LOCAL_ROOT so it can be pointed at a sandbox in tests;
# this function does NOT run automatically anywhere — it is an explicit,
# one-time provisioning step for a machine that will host these teams.
kb-knowledge-local-scaffold() {
    setopt LOCAL_OPTIONS NO_NOMATCH
    local local_root
    local_root=$(_kb_knowledge_local_root)
    local today
    today=$(date +%Y-%m-%d)

    mkdir -p "${local_root}/agents" "${local_root}/teams"

    local team
    for team in $(_kb_local_only_teams_hardcoded); do
        local team_dir="${local_root}/teams/${team}"
        mkdir -p "$team_dir"
        local team_index="${team_dir}/INDEX.md"
        if [[ ! -f "$team_index" ]]; then
            cat > "$team_index" <<EOF
# ${team} — Team Knowledge Index (local-only)

**Team:** ${team}
**Tier:** team
**Storage:** LOCAL ONLY — this tree is never synced off this machine (XACA-0754)
**Last Updated:** ${today}

---

## Tag Index

| Tag | Entries |
|-----|---------|
| _none yet_ | |

---

## Entries

_No entries yet._
EOF
            echo "  [created] ${team_index}"
        fi

        local persona
        # Prefer the hardcoded persona floor for this team (works with zero
        # external state — the correct default on a bare tap machine).
        # _kb_local_personas_for_team is still consulted so a persisted
        # team-paths.json "local_personas" array or a future agents-master
        # checkout can extend the roster without a code change; the two
        # sources are simply unioned here (dedup via the existing INDEX.md
        # idempotency guard, not an explicit set operation).
        for persona in $(_kb_local_personas_hardcoded) $(_kb_local_personas_for_team "$team" 2>/dev/null); do
            [[ -z "$persona" ]] && continue
            _kb_is_local_persona "$persona" || continue
            local agent_dir="${local_root}/agents/${persona}"
            mkdir -p "$agent_dir"
            local agent_index="${agent_dir}/INDEX.md"
            if [[ ! -f "$agent_index" ]]; then
                cat > "$agent_index" <<EOF
# ${persona} Knowledge Index (local-only)

**Agent:** ${persona}
**Storage:** LOCAL ONLY — this tree is never synced off this machine (XACA-0754)
**Last Updated:** ${today}

---

## Tag Index

| Tag | Entries |
|-----|---------|
| _none yet_ | |

---

## Entries

_No entries yet._
EOF
                echo "  [created] ${agent_index}"
            fi
        done
    done

    echo ""
    echo "  Local knowledge scaffold complete under: ${local_root}"
    echo ""
}

# Search knowledge entries across the four-tier schema
# Usage: kb-knowledge-search [<term>] [--agent <name>] [--subject <path>]
#        [--project [<slug>]] [--tag <tag>] [--tier <agent|team|subject|project>]
#        [--all-projects]
#
# Searches the new four-tier ~/knowledge/ structure:
#   agents/*/     subjects/**/     teams/*/     <project_path>/
#
# Backward-compatible: the old --team flag is accepted as an alias for --agent.
# Discovery precedence when multiple tiers match: project > team > subject > agent.
kb-knowledge-search() {
    # NO_NOMATCH: empty globs expand to nothing instead of erroring (XACA-0255).
    # BARE_GLOB_QUAL: force-on so the team-tier `(/DN)` qualifier at the team
    # glob below parses even when the user's interactive shell opted out via
    # `setopt NO_BARE_GLOB_QUAL` — without this, that glob throws 'bad pattern'
    # in such shells and team-tier results are silently lost (XACA-0737).
    # LOCAL_OPTIONS scopes both to this function — neither leaks to the caller.
    setopt LOCAL_OPTIONS NO_NOMATCH BARE_GLOB_QUAL
    local -a search_terms=()  # OR-match terms; populated by positional args (XACA-0738)
    local -a _retry_argv=()   # XACA-0800 D4/D11: FINAL argv for the zero-result OR-fallback,
                               # assembled AFTER parsing (see below) as: recognized flags/values
                               # (verbatim) + a `--` end-of-options terminator + word-split
                               # positional terms. The terminator guarantees a term that begins
                               # with '-' (e.g. a phrase like "how to use -exact matching") can
                               # never be mis-parsed as a flag on the recursive retry call, or by
                               # a human pasting the printed suggestion (XACA-0800-011). Never
                               # reconstructed from filter_* vars — that's a second, divergent
                               # source of truth (sibling-heuristic drift trap, knowledge k501).
    local -a _retry_flags=()  # flags/values copied verbatim, in original order, DURING parsing
    local -a _retry_terms=()  # positional terms, word-split (${=1}), DURING parsing
    local filter_agent="" filter_subject="" filter_project=""
    local filter_tag="" filter_tier="" flag_all_projects=false flag_project_limit=false
    local show_help=false flag_porcelain=false flag_json=false
    local _kb_zero_result_hint=false  # XACA-0800: did the literal-phrase hint fire? (telemetry field)
    local _kb_ks_end_of_opts=false    # XACA-0800-011: true once a literal `--` has been consumed

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        # Once `--` has been seen, EVERY remaining token is a positional search
        # term verbatim — even one that looks like a flag (leading '-') or is
        # itself another literal `--`. This is the standard end-of-options
        # convention and is what lets the OR-fallback below safely hand back
        # dash-leading words without them being re-parsed as flags.
        if $_kb_ks_end_of_opts; then
            _retry_terms+=(${=1})
            search_terms+=("${1-}")
            shift
            continue
        fi
        case "${1-}" in
            --)
                _kb_ks_end_of_opts=true
                shift ;;
            --help|-h)
                _retry_flags+=("${1-}")
                show_help=true; shift ;;
            --agent)
                _retry_flags+=("${1-}" "${2-}")
                filter_agent="${2-}"; shift 2 ;;
            --team)
                _retry_flags+=("${1-}" "${2-}")
                # Backward-compat alias: --team maps to --agent
                filter_agent="${2-}"; shift 2 ;;
            --subject)
                _retry_flags+=("${1-}" "${2-}")
                filter_subject="${2-}"; shift 2 ;;
            --project)
                flag_project_limit=true
                # Optional argument: next token may be the slug or another flag
                if [[ $# -gt 1 ]] && [[ "${2-}" != --* ]]; then
                    _retry_flags+=("${1-}" "${2-}")
                    filter_project="${2-}"; shift 2
                else
                    _retry_flags+=("${1-}")
                    shift
                fi
                ;;
            --tag)
                _retry_flags+=("${1-}" "${2-}")
                filter_tag="${2-}"; shift 2 ;;
            --tier)
                _retry_flags+=("${1-}" "${2-}")
                filter_tier="${2-}"; shift 2 ;;
            --all-projects)
                _retry_flags+=("${1-}")
                flag_all_projects=true; shift ;;
            --porcelain)
                _retry_flags+=("${1-}")
                flag_porcelain=true; shift ;;
            --json)
                _retry_flags+=("${1-}")
                flag_json=true; shift ;;
            -*)
                echo "Unknown flag: ${1-}" >&2
                show_help=true; shift ;;
            *)
                # XACA-0800 D4: word-split the positional so a quoted multi-word
                # phrase becomes separate OR'd terms on the fallback retry.
                _retry_terms+=(${=1})
                search_terms+=("${1-}")
                shift ;;
        esac
    done

    # XACA-0800-011: assemble the final retry argv AFTER parsing — recognized
    # flags first (so they still parse as flags on the retry), then a `--`
    # terminator (only when there are terms to protect), then the word-split
    # terms verbatim. This is what both the recursive fallback call and the
    # printed copy-paste suggestion use below, so a leading-dash term (or a
    # term that is literally `--`) is handled identically and safely in both.
    _retry_argv=("${_retry_flags[@]}")
    if [[ ${#_retry_terms[@]} -gt 0 ]]; then
        _retry_argv+=("--" "${_retry_terms[@]}")
    fi

    # Reject combining --porcelain and --json: they are mutually exclusive output modes.
    if $flag_porcelain && $flag_json; then
        echo "kb-knowledge-search: --porcelain and --json are mutually exclusive" >&2
        return 1
    fi

    # If a scope flag was set without an explicit --tier, imply the matching tier.
    # When multiple scope flags are set we leave filter_tier empty so each tier's
    # own filter (filter_agent, filter_subject, filter_project) narrows its block —
    # the per-tier `if` blocks below already handle that case.
    if [[ -z "$filter_tier" ]]; then
        local _scope_flags_set=0
        [[ -n "$filter_agent"   ]] && _scope_flags_set=$((_scope_flags_set+1))
        [[ -n "$filter_subject" ]] && _scope_flags_set=$((_scope_flags_set+1))
        $flag_project_limit         && _scope_flags_set=$((_scope_flags_set+1))
        if [[ "$_scope_flags_set" -eq 1 ]]; then
            if   [[ -n "$filter_agent"   ]]; then filter_tier="agent"
            elif [[ -n "$filter_subject" ]]; then filter_tier="subject"
            elif $flag_project_limit;        then filter_tier="project"
            fi
        fi
    fi

    # Capture multi-flag state for tier-block gating below.
    # When ANY scope flag is set the unfiltered else-branches must not add
    # their whole tier root — only the explicitly-requested tiers should fire.
    local any_scope_flag_set=false
    if [[ -n "$filter_agent" ]] || [[ -n "$filter_subject" ]] || $flag_project_limit; then
        any_scope_flag_set=true
    fi

    if $show_help || { [[ ${#search_terms[@]} -eq 0 ]] && [[ -z "$filter_tag" ]] && [[ -z "$filter_tier" ]] && [[ -z "$filter_agent" ]] && [[ -z "$filter_subject" ]] && ! $flag_project_limit; }; then
        echo "Usage: kb-knowledge-search [<term>] [flags]"
        echo ""
        echo "  <term>                Text to search in filenames and file contents"
        echo ""
        echo "Scope flags (narrow to one tier or sub-path):"
        echo "  --agent <name>        Limit to one persona's directory  (alias: --team)"
        echo "  --subject <path>      Limit to one subject path, e.g. ios or ios/swift"
        echo "  --project [<slug>]    Limit to one project (current if no arg)"
        echo "  --tier <name>         Limit to tier: agent | team | subject | project"
        echo "  --all-projects        Also scan Relevant Subjects from project INDEX.md"
        echo "                        (opt-in; the 'relevant' tier is only populated when"
        echo "                        this flag is passed — worth adding on pre-task reads)"
        echo ""
        echo "Tier inference: when one scope flag (--agent / --subject / --project) is"
        echo "  set without --tier, the search is auto-scoped to that tier only. Combine"
        echo "  flags (e.g. --agent X --subject Y) to search multiple tiers at once."
        echo "  Explicit --tier always wins."
        echo ""
        echo "Filter flags:"
        echo "  --tag <tag>           Filter by tag in frontmatter tags: field"
        echo ""
        echo "Output flags (mutually exclusive; suppress all decorative output):"
        echo "  --porcelain           Machine-readable TSV: tier<TAB>title<TAB>tags<TAB>path"
        echo "                        One line per result; empty stdout on zero results. (XACA-0738)"
        echo "  --json                JSON array of objects: [{\"tier\",\"title\",\"tags\",\"path\"}]"
        echo "                        Emits [] on zero results. Tags field empty when unset. (XACA-0738)"
        echo ""
        echo "Multi-term OR search: pass multiple positional args — entry matches if ANY term hits."
        echo "  Example: kb-knowledge-search XACA-0001 \"authentication refactor\""
        echo ""
        echo "⚠ A SINGLE quoted arg is matched as a LITERAL PHRASE, not OR'd words:"
        echo "  kb-knowledge-search \"authentication refactor\"   → substring match, often 0 results"
        echo "  kb-knowledge-search authentication refactor     → OR match, usually what you want"
        echo "  A zero-result multi-word query auto-suggests and retries the OR form (XACA-0800)."
        echo ""
        echo "Discovery precedence: project > team > subject > agent"
        return 1
    fi

    local global_root
    global_root=$(_kb_knowledge_global_root)
    local local_root
    local_root=$(_kb_knowledge_local_root)

    # Resolve project path for this session. Uses the "effective" resolver
    # (XACA-0754-013, ported XACA-0770) so a local-only session's current-
    # project path — if kb-knowledge-add redirected it to local_root — is
    # read from the SAME place it was written, not silently orphaned under
    # global_root.
    local project_path
    project_path=$(_kb_knowledge_project_path_effective)

    # TRANSITIONAL UNION (XACA-0883, delete per _kb_knowledge_project_path_legacy's
    # doc comment once a shadow-base sweep confirms every legacy base is empty
    # or reconciled): the layout fix moves the canonical project path for
    # container-layout teams; some installs may still have entries sitting at
    # the pre-fix location (possibly another team's LIVE base — not ours to
    # reconcile/move). Cheap in the common case: computed once, and only
    # pushed onto search_roots (the thing that costs real work below) when it
    # differs from project_path AND exists AND is non-empty. Reader-only —
    # writers must target project_path alone.
    local project_path_legacy=""
    project_path_legacy=$(_kb_knowledge_project_path_legacy 2>/dev/null)
    local project_path_legacy_usable=false
    if [[ -n "$project_path_legacy" ]] && [[ "$project_path_legacy" != "$project_path" ]] && [[ -d "$project_path_legacy" ]]; then
        local -a _legacy_probe
        _legacy_probe=("${project_path_legacy}"/*(N))
        (( ${#_legacy_probe[@]} > 0 )) && project_path_legacy_usable=true
    fi

    # ── Build the list of search roots, in discovery-precedence order ──────────
    # Order: project, team (reserved, included when populated), subject, agent
    local -a search_roots
    local -a root_tier_labels  # parallel array: tier label for each root

    # Tier: project
    if [[ -z "$filter_tier" ]] || [[ "$filter_tier" == "project" ]]; then
        if $flag_project_limit; then
            if [[ -n "$filter_project" ]]; then
                local named_path="${global_root}/projects/${filter_project}"
                search_roots+=("$named_path")
                root_tier_labels+=("project:${filter_project}")

                # XACA-0754-013 (ported XACA-0770): also check local_root for
                # a same-named local project (mirrors the local team/agent
                # merge blocks below) — a local-only session's named project
                # entry lives here instead of global_root.
                local local_named_path="${local_root}/projects/${filter_project}"
                if [[ -d "$local_named_path" ]]; then
                    search_roots+=("$local_named_path")
                    root_tier_labels+=("project:${filter_project}")
                fi
            else
                search_roots+=("$project_path")
                root_tier_labels+=("project")
                if $project_path_legacy_usable; then
                    search_roots+=("$project_path_legacy")
                    root_tier_labels+=("project")
                fi
            fi
        else
            if ! $any_scope_flag_set; then
                if [[ -d "$project_path" ]]; then
                    search_roots+=("$project_path")
                    root_tier_labels+=("project")
                fi
                # Pushed independently of $project_path's existence: a fresh
                # canonical base with no entries yet must not hide a
                # non-empty legacy shadow base (XACA-0883 transitional union).
                if $project_path_legacy_usable; then
                    search_roots+=("$project_path_legacy")
                    root_tier_labels+=("project")
                fi
            fi
        fi
    fi

    # Tier: team (reserved — include when dirs exist under teams/)
    if [[ -z "$filter_tier" ]] || [[ "$filter_tier" == "team" ]]; then
        if ! $any_scope_flag_set || [[ "$filter_tier" == "team" ]]; then
            local team_root="${global_root}/teams"
            if [[ -d "$team_root" ]]; then
                local tdir
                local -a _team_dirs
                # (/DN) belt-and-suspenders alongside the function-scoped
                # `setopt NO_NOMATCH` (XACA-0255): self-documents intent at the
                # call site so future readers don't remove it as redundant.
                # NOTE (XACA-0717): the qualifier MUST be `/` (directories), not
                # `.` (plain files). Team-tier knowledge entries are directories
                # under teams/<team>/; `.` matched nothing → 0 team-tier hits.
                # NOTE (XACA-0737): this bare `(/DN)` qualifier requires the
                # BARE_GLOB_QUAL option — force-set at the top of this function
                # so it parses even under interactive `setopt NO_BARE_GLOB_QUAL`.
                _team_dirs=("${team_root}"/*/(/DN))
                for tdir in "${_team_dirs[@]}"; do
                    [[ -d "$tdir" ]] || continue
                    search_roots+=("$tdir")
                    root_tier_labels+=("team:$(basename "$tdir")")
                done
            fi

            # XACA-0754 (ported XACA-0770): local-only teams (finance-personal/
            # legal-coparenting/medical-general) keep their team-tier entries
            # under local_root instead of global_root — merge them in here so
            # they're discoverable from any local-team session on this host.
            # Same (/DN) qualifier + tier label convention as the global
            # block above.
            local local_team_root="${local_root}/teams"
            if [[ -d "$local_team_root" ]]; then
                local -a _local_team_dirs
                _local_team_dirs=("${local_team_root}"/*/(/DN))
                for tdir in "${_local_team_dirs[@]}"; do
                    [[ -d "$tdir" ]] || continue
                    search_roots+=("$tdir")
                    root_tier_labels+=("team:$(basename "$tdir")")
                done
            fi
        fi
    fi

    # Tier: subject
    if [[ -z "$filter_tier" ]] || [[ "$filter_tier" == "subject" ]]; then
        local subject_root="${global_root}/subjects"
        if [[ -n "$filter_subject" ]]; then
            local subject_dir="${subject_root}/${filter_subject}"
            search_roots+=("$subject_dir")
            root_tier_labels+=("subject:${filter_subject}")
        else
            if [[ -d "$subject_root" ]] && ! $any_scope_flag_set; then
                search_roots+=("$subject_root")
                root_tier_labels+=("subject")
            fi
        fi

        # XACA-0754-013 (ported XACA-0770): merge local_root/subjects the
        # same way (no intra-host isolation — once written, visible from any
        # session on this host, same as the local team/agent merge blocks).
        # No per-leaf (/DN) glob needed here — subject entries can nest
        # arbitrarily deep and the per-root matching below already recurses,
        # exactly like the unfiltered global subject_root case above.
        local local_subject_root="${local_root}/subjects"
        if [[ -n "$filter_subject" ]]; then
            local local_subject_dir="${local_subject_root}/${filter_subject}"
            if [[ -d "$local_subject_dir" ]]; then
                search_roots+=("$local_subject_dir")
                root_tier_labels+=("subject:${filter_subject}")
            fi
        else
            if [[ -d "$local_subject_root" ]] && ! $any_scope_flag_set; then
                search_roots+=("$local_subject_root")
                root_tier_labels+=("subject")
            fi
        fi
    fi

    # Tier: agent
    if [[ -z "$filter_tier" ]] || [[ "$filter_tier" == "agent" ]]; then
        local agent_root="${global_root}/agents"
        if [[ -n "$filter_agent" ]]; then
            local agent_dir="${agent_root}/${filter_agent}"
            search_roots+=("$agent_dir")
            root_tier_labels+=("agent:${filter_agent}")
        else
            if [[ -d "$agent_root" ]] && ! $any_scope_flag_set; then
                search_roots+=("$agent_root")
                root_tier_labels+=("agent")
            fi
        fi

        # XACA-0754 (ported XACA-0770): local-only personas (finance/legal/
        # medical personal-team agents) live under local_root/agents instead
        # of global_root/agents. Merge in whichever slice applies — a
        # specific --agent dir if it exists there, or the whole local
        # agent_root in the unfiltered case — mirroring the global block's
        # shape exactly.
        local local_agent_root="${local_root}/agents"
        if [[ -n "$filter_agent" ]]; then
            local local_agent_dir="${local_agent_root}/${filter_agent}"
            if [[ -d "$local_agent_dir" ]]; then
                search_roots+=("$local_agent_dir")
                root_tier_labels+=("agent:${filter_agent}")
            fi
        else
            if [[ -d "$local_agent_root" ]] && ! $any_scope_flag_set; then
                search_roots+=("$local_agent_root")
                root_tier_labels+=("agent")
            fi
        fi
    fi

    # ── Optionally pull in declared Relevant Subjects from project INDEX ────────
    if $flag_all_projects && [[ -f "${project_path}/INDEX.md" ]]; then
        # Extract subjects:* references from the Relevant Subjects section
        local rel_subj
        while IFS= read -r rel_subj; do
            rel_subj="${rel_subj#- }"
            if [[ "$rel_subj" == subjects:* ]]; then
                local subj_path="${rel_subj#subjects:}"
                subj_path=$(printf '%s' "$subj_path" | tr ':' '/')  # replace each : with / (nested subjects)
                # Validate before use (matches sibling sites ~11448/11656). Skip a malformed
                # INDEX entry (e.g. a path-traversal ref) rather than aborting the whole search.
                if ! _kb_validate_subject_path "$subj_path"; then
                    echo "Warning: skipping invalid relevant-subject path '${subj_path}' from ${project_path}/INDEX.md (each component must match ^[a-z][a-z0-9_-]*$; no path traversal)" >&2
                    continue
                fi
                local extra_dir="${global_root}/subjects/${subj_path}"
                if [[ -d "$extra_dir" ]]; then
                    search_roots+=("$extra_dir")
                    root_tier_labels+=("relevant:${subj_path}")
                fi
            fi
        done < <(grep '^\- subjects:' "${project_path}/INDEX.md" 2>/dev/null)
    fi

    # ── Print header (human mode only) ──────────────────────────────────────────
    if ! $flag_porcelain && ! $flag_json; then
        local _term_str="${search_terms[*]:-}"
        echo ""
        echo "═══════════════════════════════════════════════════════════════════════════"
        if [[ -n "$_term_str" ]] && [[ -n "$filter_tag" ]]; then
            echo "  KNOWLEDGE SEARCH: \"${_term_str}\" | tag: ${filter_tag}"
        elif [[ -n "$filter_tag" ]]; then
            echo "  KNOWLEDGE SEARCH: tag: ${filter_tag}"
        elif [[ -n "$_term_str" ]]; then
            echo "  KNOWLEDGE SEARCH: \"${_term_str}\""
        else
            echo "  KNOWLEDGE SEARCH (all entries)"
        fi
        [[ -n "$filter_tier" ]]    && echo "  (tier: ${filter_tier})"
        [[ -n "$filter_agent" ]]   && echo "  (agent: ${filter_agent})"
        [[ -n "$filter_subject" ]] && echo "  (subject: ${filter_subject})"
        $flag_project_limit        && echo "  (project: ${filter_project:-current})"
        echo "  Root: ${global_root}"
        echo "═══════════════════════════════════════════════════════════════════════════"
        echo ""
    fi

    local result_count=0
    # XACA-0502: per-tier hit distribution. The single `tier` field only ever
    # captured the --tier *filter flag*, never which tiers the results came
    # from — so the audit could not compute per-tier read distribution. Count
    # matches per base tier here and emit them as a nested `result_tiers`
    # object alongside the existing total. Plain integer counters (not an
    # associative array) for macOS bash 3.2 portability.
    local _kb_rt_agent=0 _kb_rt_subject=0 _kb_rt_team=0 _kb_rt_project=0 _kb_rt_relevant=0
    local tier_label md_files filepath basename_f is_index matched title tags_line rel_path tags_val
    local _st _jt _jti _jtg _jp  # multi-term loop var + JSON field escape buffers (XACA-0738)
    local _pc_title _pc_tags  # porcelain TSV sanitize buffers — declared OUT of the loop (zsh local-in-loop stdout leak, k501) (XACA-0738)
    local _json_entries="" _json_first=true  # JSON array accumulator (XACA-0738)
    # Batched-matching scratch (XACA-0721) — ALL declared before the loop so no
    # `local` runs inside it (zsh local-in-loop stdout-leak trap, k501).
    local _all_md _matched_set _tag_hits _body_hits _f _bnlc _stlc _extract _bn
    local -a _grep_e_args
    local _sep=$'\034'  # 0x1C field separator for the title<sep>tags awk extract

    # XACA-0265: array base differs by shell — zsh defaults to 1-indexed, bash
    # (and zsh under KSH_ARRAYS) is 0-indexed. Probe at runtime so the parallel
    # `root_tier_labels` lookup tracks `search_roots` regardless of shell.
    local _kb_idx_base=0
    local _kb_probe=("first")
    [[ "${_kb_probe[1]:-}" == "first" ]] && _kb_idx_base=1
    local root_idx=$_kb_idx_base

    for search_root in "${search_roots[@]}"; do
        tier_label="${root_tier_labels[$root_idx]}"
        root_idx=$((root_idx + 1))

        [[ -d "$search_root" ]] || continue

        # ── Batched per-root matching (XACA-0721) ──────────────────────────────
        # Replaces the prior per-file walk (tag + filename + body greps run on
        # EVERY .md file) with a small fixed number of batched passes per root,
        # then loops ONLY the matched set for the cheap title/tags extract + emit.
        # The result SET and result_count are identical to the per-file walk —
        # ONLY intra-root ordering changes (sort -u → lexical, vs find's traversal
        # order). Cross-root tier precedence (project > team > subject > agent) is
        # preserved by the enclosing per-root loop, which is untouched.
        #
        # Multi-term OR (XACA-0738) is preserved:
        #   • body  → ONE recursive `grep -rliF` with one `-e <term>` per term →
        #             OR-union of every term in a single filesystem walk.
        #   • file  → pure-shell scan of the find list; a file matches if its
        #             lowercased basename contains ANY term (break on first hit).
        # INDEX.md is excluded from every candidate set (it is never an emitted
        # entry regardless of how it matched), exactly as the old walk's emit guard.
        _all_md=$(find "$search_root" -type f -name "*.md" 2>/dev/null)
        [[ -z "$_all_md" ]] && continue

        _matched_set=""
        if [[ ${#search_terms[@]} -eq 0 ]] && [[ -z "$filter_tag" ]]; then
            # No term and no tag → every non-INDEX entry under this root.
            _matched_set=$(printf '%s\n' "$_all_md" | grep -v '/INDEX\.md$' 2>/dev/null)
        else
            # ── Tag filter: ONE batched `grep -rH '^tags:'` pass ───────────────
            # Mirrors the old per-file `grep -m1 '^tags:' | sed … | grep -Fqi`:
            #   • first `^tags:` line per file — contiguity guard: grep -r emits a
            #     file's lines contiguously, so we keep only the first per path.
            #   • strip the leading `tags:`+spaces, then literal case-insensitive
            #     substring test against the filter value (mirrors grep -Fqi).
            if [[ -n "$filter_tag" ]]; then
                _tag_hits=$(grep -rH --include='*.md' '^tags:' "$search_root" 2>/dev/null \
                    | awk -v tag="$filter_tag" '
                        { ci=index($0,":"); if(ci==0) next;
                          path=substr($0,1,ci-1); rest=substr($0,ci+1);
                          if(path==lastpath) next; lastpath=path;
                          sub(/^tags:[[:space:]]*/,"",rest);
                          if(index(tolower(rest),tolower(tag))>0) print path }')
                [[ -n "$_tag_hits" ]] && _matched_set+="$_tag_hits"$'\n'
            fi

            # ── Term filter: body (batched recursive grep) + filename (shell) ──
            if [[ ${#search_terms[@]} -gt 0 ]]; then
                # Body: one recursive fixed-string, case-insensitive pass. Every
                # term becomes a `-e` arg → OR-union of all terms in one walk.
                _grep_e_args=()
                for _st in "${search_terms[@]}"; do _grep_e_args+=(-e "$_st"); done
                _body_hits=$(grep -rliF --include='*.md' "${_grep_e_args[@]}" "$search_root" 2>/dev/null)
                [[ -n "$_body_hits" ]] && _matched_set+="$_body_hits"$'\n'

                # Filename: pure-shell scan over the find list. A file matches if
                # its lowercased basename contains ANY term (break on first hit).
                # Quote the term in the glob so grep -F literal semantics hold —
                # metachars in a term match literally, not as shell wildcards.
                while IFS= read -r _f; do
                    [[ -z "$_f" ]] && continue
                    _bnlc="${_f##*/}"; _bnlc="${(L)_bnlc}"
                    for _st in "${search_terms[@]}"; do
                        _stlc="${(L)_st}"
                        if [[ "$_bnlc" == *"$_stlc"* ]]; then
                            _matched_set+="$_f"$'\n'; break
                        fi
                    done
                done <<< "$_all_md"
            fi
        fi

        # Dedup + drop blank lines + drop INDEX.md (never an emitted entry,
        # regardless of how it matched). sort -u also yields deterministic
        # intra-root ordering — the ONLY observable change vs. the old walk.
        _matched_set=$(printf '%s\n' "$_matched_set" | grep -v '^$' | grep -v '/INDEX\.md$' 2>/dev/null | sort -u)
        [[ -z "$_matched_set" ]] && continue

        # ── Emit loop over the matched set ─────────────────────────────────────
        while IFS= read -r filepath; do
            [[ -z "$filepath" ]] && continue
            _bn="${filepath##*/}"; _bn="${_bn%.md}"
            # ONE awk pass per matched file: first `# `/`## ` heading → title
            # (fallback: basename without .md), first `^tags:` line → tags (≤40
            # chars). The two fields are joined by 0x1C (absent from text, so it
            # can never collide with content) and split back in the shell below.
            # This reproduces the old `grep -m1 … | sed …` title/tags extraction.
            _extract=$(awk -v bn="$_bn" -v sep="$_sep" '
                !ht && ($0 ~ /^# / || $0 ~ /^## /) { t=$0; sub(/^#* /,"",t); title=t; ht=1 }
                !hg && /^tags:/ { g=$0; sub(/^tags:[[:space:]]*/,"",g); tags=g; hg=1 }
                END { if(title=="") title=bn; printf "%s%s%s", title, sep, substr(tags,1,40) }
            ' "$filepath" 2>/dev/null)
            [[ -z "$_extract" ]] && _extract="${_bn}${_sep}"
            title="${_extract%%${_sep}*}"
            tags_line="${_extract#*${_sep}}"

            rel_path="${filepath#${HOME}/}"

            # Emit branches below are byte-preserved from the per-file walk
            # (XACA-0738): porcelain TSV / JSON accumulator / human 2-line, then
            # result_count + the per-base-tier result_tiers tally (XACA-0502).
                if $flag_porcelain; then
                    # TSV: tier<TAB>title<TAB>tags<TAB>path  (path is HOME-relative, no leading ~/)
                    # Sanitize embedded TAB/newline in fields → space so a stray delimiter
                    # in a title/tags value cannot shift columns for the TSV consumer (XACA-0738
                    # [Review] PR #658). tier_label/rel_path are structurally TAB-free; title/tags
                    # come from file content, so guard them.
                    _pc_title="${title//[$'\t\n\r']/ }"
                    _pc_tags="${tags_line//[$'\t\n\r']/ }"
                    printf '%s\t%s\t%s\t%s\n' "$tier_label" "$_pc_title" "${_pc_tags:-}" "$rel_path"
                elif $flag_json; then
                    # Accumulate JSON objects; emit array after the loop.
                    # JSON-escape each field using the same idiom as the telemetry writer below.
                    _jt="$tier_label"
                    _jt=${_jt//\\/\\\\}; _jt=${_jt//\"/\\\"}; _jt=${_jt//$'\n'/\\n}; _jt=${_jt//$'\r'/\\r}; _jt=${_jt//$'\t'/\\t}
                    _jti="$title"
                    _jti=${_jti//\\/\\\\}; _jti=${_jti//\"/\\\"}; _jti=${_jti//$'\n'/\\n}; _jti=${_jti//$'\r'/\\r}; _jti=${_jti//$'\t'/\\t}
                    _jtg="${tags_line:-}"
                    _jtg=${_jtg//\\/\\\\}; _jtg=${_jtg//\"/\\\"}; _jtg=${_jtg//$'\n'/\\n}; _jtg=${_jtg//$'\r'/\\r}; _jtg=${_jtg//$'\t'/\\t}
                    _jp="$rel_path"
                    _jp=${_jp//\\/\\\\}; _jp=${_jp//\"/\\\"}; _jp=${_jp//$'\n'/\\n}; _jp=${_jp//$'\r'/\\r}; _jp=${_jp//$'\t'/\\t}
                    if [[ "$_json_first" == "true" ]]; then
                        _json_entries="{\"tier\":\"$_jt\",\"title\":\"$_jti\",\"tags\":\"$_jtg\",\"path\":\"$_jp\"}"
                        _json_first=false
                    else
                        _json_entries="${_json_entries},{\"tier\":\"$_jt\",\"title\":\"$_jti\",\"tags\":\"$_jtg\",\"path\":\"$_jp\"}"
                    fi
                else
                    printf "  %-26s %-32s %s\n" "[${tier_label}]" "$title" "${tags_line:-—}"
                    printf "  %-26s %s\n" "" "~/$rel_path"
                    echo ""
                fi
                result_count=$((result_count + 1))
                # Tally the match under its base tier (the segment before ':'
                # in tier_label, e.g. "agent:emh" → agent, "relevant:..." →
                # relevant) for the result_tiers distribution (XACA-0502).
                case "${tier_label%%:*}" in
                    agent)    _kb_rt_agent=$((_kb_rt_agent + 1)) ;;
                    subject)  _kb_rt_subject=$((_kb_rt_subject + 1)) ;;
                    team)     _kb_rt_team=$((_kb_rt_team + 1)) ;;
                    project)  _kb_rt_project=$((_kb_rt_project + 1)) ;;
                    relevant) _kb_rt_relevant=$((_kb_rt_relevant + 1)) ;;
                esac
        done <<< "$_matched_set"
    done

    if $flag_json; then
        # Emit the accumulated JSON array (empty string in _json_entries → [] on zero results).
        printf '[%s]\n' "$_json_entries"
    elif ! $flag_porcelain; then
        # Human footer: result summary + decorative trailer.
        if [[ "$result_count" -eq 0 ]]; then
            echo "  No knowledge entries found."
            echo ""
            echo "  Suggestions:"
            echo "    • Try broader search terms"
            echo "    • Check INDEX.md files in ${global_root}/agents/ or subjects/"
            echo "    • Use --agent <name> or --subject <path> to narrow the search"
            echo "    • Use --tier to limit to one tier"

            # XACA-0800 D2: a quoted multi-word term is matched as a literal
            # PHRASE (grep -F), not OR'd words — the #1 cause of a false-zero on
            # a genuinely populated corpus (XACA-0793). Trigger ONLY when a
            # search_terms element contains whitespace, so a real single-word
            # corpus miss never sees this (no crying wolf). The recursion guard
            # (_KB_KS_NO_FALLBACK) also gates the hint itself, not just the
            # fallback call below — the retry's terms are always single words so
            # the whitespace check alone would suffice, but D3 explicitly wants
            # non-recursion to be an invariant, not a coincidence of that fact.
            if [[ -z "${_KB_KS_NO_FALLBACK:-}" ]]; then
                local _kb_zrh_term _kb_zrh_multiword=false
                for _kb_zrh_term in "${search_terms[@]}"; do
                    if [[ "$_kb_zrh_term" == *[[:space:]]* ]]; then
                        _kb_zrh_multiword=true
                        break
                    fi
                done

                if $_kb_zrh_multiword; then
                    _kb_zero_result_hint=true
                    echo ""
                    echo "  ⚠ Hint: a quoted multi-word term is matched as a LITERAL PHRASE,"
                    echo "    not OR'd words — that's almost certainly why this returned zero."
                    echo "    Pass each word as its own argument to match ANY of them instead:"
                    echo ""
                    echo "      kb-knowledge-search ${(j: :)_retry_argv}"
                    echo ""
                    echo "  ── no literal match — showing term matches (OR-fallback) ──"
                    echo ""
                    KB_SEARCH_TELEMETRY_DISABLED=1 _KB_KS_NO_FALLBACK=1 kb-knowledge-search "${_retry_argv[@]}"
                fi
            fi
        else
            echo "  Found ${result_count} matching entry(ies)."
        fi

        echo "═══════════════════════════════════════════════════════════════════════════"
        echo ""
    fi
    # Porcelain: zero results → empty stdout; non-zero → TSV lines already emitted above.
    # Telemetry fires unconditionally below regardless of output mode.

    # XACA-0500 telemetry: log each search to kanban-logs/kb-search.jsonl.
    # Why: prior audit (2026-05-14) found zero usage signal — can't tell which
    #   entries are read vs. dead weight. Opt out: KB_SEARCH_TELEMETRY_DISABLED=1.
    # How to apply: any failure here is swallowed; telemetry must never break the search.
    if [[ "${KB_SEARCH_TELEMETRY_DISABLED:-0}" != "1" ]]; then
        # INTENTIONAL DIVERGENCE FROM CANONICAL (XACA-0810, do not "fix" to parity).
        #   canonical kanban-helpers.sh uses: "${AITEAMFORGE_DIR:-$HOME/dev-team}/kanban-logs"
        #   this tap copy deliberately uses:  "${AITEAMFORGE_DIR}/kanban-logs"  (no fallback)
        # Why: the $HOME/dev-team fallback is a DEV-MACHINE default. On a tap consumer
        #   box there is no ~/dev-team checkout, so that fallback would silently
        #   manufacture a phantom ~/dev-team/kanban-logs tree — precisely the failure
        #   XACA-0746 fixed here and that XACA-0760's own canonical-side comment cites as
        #   the reason for the change. AITEAMFORGE_DIR is always set by the tap's shell
        #   init before this file is sourced, so the fallback is unreachable-by-design on
        #   consumers and only harmful if it ever did fire.
        # Per XACA-0340 the canonical file remains authoritative for everything else in
        #   this function; this single line is an environment adaptation, not drift.
        local _kb_log_dir="${AITEAMFORGE_DIR}/kanban-logs"  # XACA-0746: context-safe (no ~/dev-team dependency)
        local _kb_log_file="$_kb_log_dir/kb-search.jsonl"
        local _kb_ts _kb_persona _kb_q _kb_agent _kb_subject _kb_project _kb_tier _kb_tag _kb_pwd
        _kb_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        # Persona resolution (XACA-0502): prefer an explicit LCARS_TEAM (set by
        # live LCARS tmux sessions), else fall through to the canonical context
        # resolver _kb_detect_context (tmux session → KB_TEAM env → .kb-team
        # sentinel). The prior chain was LCARS_TEAM → KB_DETECTED_TEAM, but
        # KB_DETECTED_TEAM is set by NOTHING in the codebase and KB_TEAM (the
        # variable every other kb-* helper resolves through) was never consulted
        # — so every subagent / worktree / non-interactive shell logged
        # persona=unknown, blanking the audit signal this telemetry exists to
        # provide. Reusing _kb_detect_context avoids adding a divergent fifth
        # persona-resolution site (sibling-drift trap, see k501).
        _kb_persona="${LCARS_TEAM:-}"
        if [[ -z "$_kb_persona" ]]; then
            # XACA-0746 aliases-file adaptation: this file has no _kb_detect_context
            # (the tmux-pane/.kb-team-sentinel resolver used by the full dev-team
            # kanban-helpers.sh) — it is deliberately context-safe. Use _kb_get_team
            # instead (KB_TEAM_OVERRIDE -> KANBAN_TEAM -> "academy" default; never
            # errors), which is this file's own canonical team-resolution helper.
            local _kb_ctx_team
            _kb_ctx_team=$(_kb_get_team 2>/dev/null)
            if [[ -n "$_kb_ctx_team" ]]; then
                _kb_persona="$_kb_ctx_team"
            else
                _kb_persona="unknown"
            fi
        fi
        # JSON-escape each string field. Order MATTERS:
        #   1. Backslash first (doubles every \ in the source)
        #   2. Double-quote next
        #   3. Then control chars (newline/CR/tab) — these introduce literal \n/\r/\t
        #      that must NOT be re-doubled by step 1, so step 1 has to precede them.
        # Persona is escaped too (XACA-0500 review fix): a LCARS_TEAM containing a
        # quote or newline would otherwise corrupt the JSONL line.
        _kb_persona=${_kb_persona//\\/\\\\};    _kb_persona=${_kb_persona//\"/\\\"}
        _kb_persona=${_kb_persona//$'\n'/\\n};  _kb_persona=${_kb_persona//$'\r'/\\r}; _kb_persona=${_kb_persona//$'\t'/\\t}
        # Join terms with a literal space, independent of the caller's IFS (zsh (j::)
        # flag) — deterministic regardless of shell state (XACA-0738 [Review] PR #658).
        # Single-term stays identical; empty array → "" via the :- default.
        _kb_q="${(j: :)search_terms:-}"
        _kb_q=${_kb_q//\\/\\\\};               _kb_q=${_kb_q//\"/\\\"}
        _kb_q=${_kb_q//$'\n'/\\n};              _kb_q=${_kb_q//$'\r'/\\r};             _kb_q=${_kb_q//$'\t'/\\t}
        _kb_agent=${filter_agent//\\/\\\\};     _kb_agent=${_kb_agent//\"/\\\"}
        _kb_agent=${_kb_agent//$'\n'/\\n};      _kb_agent=${_kb_agent//$'\r'/\\r};     _kb_agent=${_kb_agent//$'\t'/\\t}
        _kb_subject=${filter_subject//\\/\\\\}; _kb_subject=${_kb_subject//\"/\\\"}
        _kb_subject=${_kb_subject//$'\n'/\\n};  _kb_subject=${_kb_subject//$'\r'/\\r}; _kb_subject=${_kb_subject//$'\t'/\\t}
        _kb_project=${filter_project//\\/\\\\}; _kb_project=${_kb_project//\"/\\\"}
        _kb_project=${_kb_project//$'\n'/\\n};  _kb_project=${_kb_project//$'\r'/\\r}; _kb_project=${_kb_project//$'\t'/\\t}
        _kb_tier=${filter_tier//\\/\\\\};       _kb_tier=${_kb_tier//\"/\\\"}
        _kb_tier=${_kb_tier//$'\n'/\\n};        _kb_tier=${_kb_tier//$'\r'/\\r};       _kb_tier=${_kb_tier//$'\t'/\\t}
        _kb_tag=${filter_tag//\\/\\\\};         _kb_tag=${_kb_tag//\"/\\\"}
        _kb_tag=${_kb_tag//$'\n'/\\n};          _kb_tag=${_kb_tag//$'\r'/\\r};         _kb_tag=${_kb_tag//$'\t'/\\t}
        _kb_pwd=${PWD//\\/\\\\};                _kb_pwd=${_kb_pwd//\"/\\\"}
        _kb_pwd=${_kb_pwd//$'\n'/\\n};          _kb_pwd=${_kb_pwd//$'\r'/\\r};         _kb_pwd=${_kb_pwd//$'\t'/\\t}
        # result_tiers (XACA-0502): nested object of per-base-tier hit counts.
        # Emitted raw (%s, not a quoted string) so consumers can read e.g.
        # `.result_tiers.agent`. `tier` remains the --tier filter-flag capture.
        local _kb_result_tiers
        _kb_result_tiers=$(printf '{"agent":%d,"subject":%d,"team":%d,"project":%d,"relevant":%d}' \
            "$_kb_rt_agent" "$_kb_rt_subject" "$_kb_rt_team" "$_kb_rt_project" "$_kb_rt_relevant")
        # flag_all_projects (XACA-0715): raw JSON boolean — true when --all-projects was
        # passed, false otherwise. Without this, a relevant-tier miss (result_tiers.relevant=0)
        # is indistinguishable from "the flag was never invoked", which blinded the
        # XACA-0589/0712 audits. Emitted raw (%s) so consumers read it as a boolean, not
        # a string. Normalized defensively even though flag_all_projects is set to the
        # literals "true"/"false" by the arg-parser above.
        local _kb_flag_ap="false"; [[ "$flag_all_projects" == "true" ]] && _kb_flag_ap="true"
        # zero_result_hint (XACA-0800): additive field — true only when the human-mode
        # literal-phrase hint fired on THIS invocation. result_count above is untouched
        # (still 0 on the primary/literal query) — this stays a truthful adoption-gate
        # signal (XACA-0724/0780) rather than laundering a miss into a hit.
        local _kb_zrh_json="false"; [[ "$_kb_zero_result_hint" == "true" ]] && _kb_zrh_json="true"
        { mkdir -p "$_kb_log_dir" 2>/dev/null && \
          printf '{"ts":"%s","persona":"%s","query":"%s","tier":"%s","agent":"%s","subject":"%s","project":"%s","tag":"%s","results":%d,"result_tiers":%s,"flag_all_projects":%s,"zero_result_hint":%s,"cwd":"%s"}\n' \
            "$_kb_ts" "$_kb_persona" "$_kb_q" "$_kb_tier" "$_kb_agent" "$_kb_subject" "$_kb_project" "$_kb_tag" "$result_count" "$_kb_result_tiers" "$_kb_flag_ap" "$_kb_zrh_json" "$_kb_pwd" \
            >> "$_kb_log_file" 2>/dev/null; } || true
    fi
}

# XACA-0818: atomically reserve the next available knowledge-entry slot in
# target_dir, closing the scan→compute→create TOCTOU race in the id
# allocator. Concurrent kb-knowledge-add/kb-knowledge-promote callers all
# read the SAME highest NNN before any of them writes its file, then each
# writes a DISTINCT slug into the SAME NNN slot (e.g. k002-foo.md AND
# k002-bar.md — both creates succeed because the filenames differ, so an
# O_EXCL/noclobber guard on the FINAL filename cannot fix this). The atomic
# unit is the whole "scan existing files → compute next NNN → reserve the
# slot", NOT the final file.
#
# The lock is deliberately kept OUTSIDE the synced knowledge tree, under
# TMPDIR and keyed by a hash of the target dir — NOT inside target_dir.
# kb-knowledge-sync.sh Guard 3 treats ANY non-empty porcelain as "dirty →
# skip sync", so the first add/promote on a host WEDGED that host's knowledge
# sync permanently. Keying the lock by dir-hash under TMPDIR still serializes
# writers to the SAME dir (identical hash) while letting different dirs proceed
# in parallel, and leaves the synced tree clean.
#
# Reuses the Perl-flock discipline from _kb_jq_update (macOS ships no flock(1);
# bash's `200>file` redirect syntax fails under zsh). Under the lock we scan for
# the highest NNN and immediately create an empty placeholder at
# <prefix>NNN-<slug>.md INSIDE target_dir — that reserved real entry is the
# unchanged placeholder mechanism, so the NEXT locked caller's scan sees it and
# advances to NNN+1. Real content is written into the reserved file by the
# caller AFTER the lock releases (safe: the filename is uniquely ours).
#
# Args:   <target_dir> <prefix> <slug>   (target_dir must already exist)
# Stdout: absolute path of the reserved (empty, 0-byte) placeholder file.
# Returns non-zero (and prints nothing usable) on failure.
_kb_alloc_slot() {
    local target_dir="${1:?_kb_alloc_slot: target_dir required}"
    local prefix="${2:?_kb_alloc_slot: prefix required}"
    local slug="${3:?_kb_alloc_slot: slug required}"

    # Normalize to an absolute path so the lock key is stable regardless of the
    # caller's cwd. Callers mkdir -p target_dir before calling, so it exists;
    # fall back to the raw value if the cd somehow fails.
    local abs_dir
    abs_dir=$(cd "$target_dir" 2>/dev/null && pwd) || abs_dir="$target_dir"

    local dir_hash
    dir_hash=$(printf '%s' "$abs_dir" | cksum | awk '{print $1}')
    local alloc_lock="${TMPDIR:-/tmp}/kb-alloc-${dir_hash}.lock"

    perl -e '
        use Fcntl qw(:flock);
        my $lock_file = $ARGV[0];  # zsh-index-ok: Perl, 0-indexed by design
        open(my $fh, ">", $lock_file) or die "Cannot open lock file: $!";
        flock($fh, LOCK_EX) or die "Cannot lock: $!";
        my $rc = system(@ARGV[1..$#ARGV]);
        close($fh);
        exit($rc >> 8);
    ' "$alloc_lock" sh -c '
        dir=$1; pfx=$2; slug=$3
        highest=0
        for f in "$dir/$pfx"[0-9][0-9][0-9]-*.md; do
            [ -f "$f" ] || continue
            b=${f##*/}
            num=${b#"$pfx"}
            num=${num%%-*}
            num=$(printf %s "$num" | sed "s/^0*//")
            [ -z "$num" ] && num=0
            if [ "$num" -gt "$highest" ] 2>/dev/null; then highest=$num; fi
        done
        next=$((highest + 1))
        padded=$(printf %03d "$next")
        file="$dir/$pfx$padded-$slug.md"
        : > "$file" || exit 3
        printf %s "$file"
    ' sh "$abs_dir" "$prefix" "$slug"
}

# Scaffold a new knowledge entry at the correct tier location
# Usage: kb-knowledge-add <tier> [<target>] "<title>"
#
# Examples:
#   kb-knowledge-add agent emh "kapt error patterns"
#   kb-knowledge-add subject ios/swift "actor isolation"
#   kb-knowledge-add project "viper wizard wiring"
#   kb-knowledge-add team mobile-platform "release coordination"
kb-knowledge-add() {
    setopt LOCAL_OPTIONS NO_NOMATCH
    local tier="${1:-}"
    local show_help=false

    if [[ -z "$tier" ]] || [[ "$tier" == "--help" ]] || [[ "$tier" == "-h" ]]; then
        show_help=true
    fi

    if $show_help; then
        echo "Usage: kb-knowledge-add <tier> [<target>] \"<title>\" [--force] [--allow-foreign-host] [--allow-nonstandard-base]"
        echo ""
        echo "  tier       agent | subject | project | team"
        echo "  target     Agent name, subject path, team name, or (project) optional slug"
        echo "  title      Human-readable title for the entry"
        echo "  --force    subject/project tiers only (XACA-0754-014, ported XACA-0770):"
        echo "             proceed with a shared/synced write even when the session's team"
        echo "             could not be resolved at all — normally refused, since an"
        echo "             unresolvable session might be a finance/legal/medical (PII) one."
        echo "             Ignored for agent/team tiers."
        echo "             Does NOT waive --allow-nonstandard-base's layout check."
        echo "  --allow-foreign-host"
        echo "             agent/team tiers only (XACA-0802): write a local-only team's"
        echo "             entry on a host that is NOT that team's declared primary_host."
        echo "             Normally refused, because the local knowledge root never syncs"
        echo "             — the entry would be stranded here and invisible on the owning"
        echo "             host, and its entry id can collide with one allocated there."
        echo "  --allow-nonstandard-base"
        echo "             project tier only (XACA-0883): write project knowledge to the"
        echo "             path as resolved, even when it lands inside the git work-tree"
        echo "             while this repo's canonical kanban directory is a sibling of"
        echo "             it. Normally the write is redirected to the canonical base,"
        echo "             because the resolved path creates a second knowledge base that"
        echo "             search will not read. Does NOT waive --force's PII check."
        echo ""
        echo "Examples:"
        echo "  kb-knowledge-add agent emh \"kapt error patterns\""
        echo "  kb-knowledge-add subject ios/swift \"actor isolation\""
        echo "  kb-knowledge-add project \"viper wizard wiring\""
        echo "  kb-knowledge-add team mobile-platform \"release coordination\""
        echo ""
        echo "Set KB_KNOWLEDGE_OPEN_AFTER_ADD=1 to open in \$EDITOR after creation."
        return 1
    fi

    shift  # consumed $1 (tier)

    # XACA-0754-014 (ported XACA-0770): --force is recognized anywhere in the
    # remaining args and stripped out BEFORE tier-specific positional parsing
    # runs — otherwise it would get swept into title_raw (which greedily
    # joins "${*:2}"/"$*"). Only subject/project tiers consult it; agent/team
    # tiers ignore it silently (harmless no-op, not an error).
    #
    # XACA-0802: --allow-foreign-host is stripped the same way, for the same
    # reason. It is the agent/team-tier counterpart of --force (host
    # authorization rather than PII-session disambiguation); subject/project
    # tiers ignore it silently.
    #
    # XACA-0883: --allow-nonstandard-base is stripped the same way, and is a
    # SEPARATE flag from --force by design (guard contract §3.5) — a user
    # silencing a layout-correctness warning must not thereby also silence a
    # PII control. Neither flag implies the other, in either direction.
    # project tier only (agent/team/subject tiers ignore it silently — same
    # treatment as --force).
    local flag_allow_global=false
    local flag_allow_foreign_host=false
    local flag_allow_nonstandard_base=false
    local -a _kb_add_filtered_args=()
    local _kb_add_arg
    for _kb_add_arg in "$@"; do
        if [[ "$_kb_add_arg" == "--force" ]]; then
            flag_allow_global=true
        elif [[ "$_kb_add_arg" == "--allow-foreign-host" ]]; then
            flag_allow_foreign_host=true
        elif [[ "$_kb_add_arg" == "--allow-nonstandard-base" ]]; then
            flag_allow_nonstandard_base=true
        else
            _kb_add_filtered_args+=("$_kb_add_arg")
        fi
    done
    set -- "${_kb_add_filtered_args[@]}"

    local global_root
    global_root=$(_kb_knowledge_global_root)
    local local_root
    local_root=$(_kb_knowledge_local_root)

    # XACA-0754/XACA-0754-013 (ported XACA-0770): which root a write actually
    # lands under. Defaults to global; flipped to local_root below whenever
    # the write targets a local-only (PII) team. agent/team tiers key off the
    # explicit persona/team-name argument (_kb_is_local_persona /
    # _kb_is_local_only_team). subject and bare-project tiers have no such
    # argument — they key off the CURRENT SESSION's team instead
    # (_kb_current_session_is_local_only_team), and named-project keys off
    # the session too (a project slug carries no team information of its
    # own). Over-containment is the safe direction: a local session's
    # subject/project entry going local is correct even for a generic topic.
    local write_root="$global_root"

    local target_dir prefix title_raw tier_field=""

    case "$tier" in
        agent)
            local persona="${1:-}"
            if [[ -z "$persona" ]] || [[ $# -lt 2 ]]; then
                echo "Error: agent tier requires <persona> and <title>" >&2
                echo "  Example: kb-knowledge-add agent emh \"title here\"" >&2
                return 1
            fi
            if ! _kb_validate_name_component "$persona"; then
                echo "Error: invalid persona name '${persona}' — must match ^[a-z][a-z0-9_-]*$ (no path traversal, no uppercase)" >&2
                return 1
            fi
            if _kb_is_local_persona "$persona"; then
                write_root="$local_root"
            fi
            # XACA-0802: routing is settled; now ask whether THIS HOST is allowed
            # to author it. Must run before mkdir -p / id allocation below so a
            # refusal leaves no directory and no file.
            _kb_knowledge_host_affinity_guard "$persona" agent "$flag_allow_foreign_host" || return 1
            title_raw="${*:2}"
            target_dir="${write_root}/agents/${persona}"
            prefix="k"
            tier_field="agent: ${persona}"
            ;;
        subject)
            local subj_path="${1:-}"
            if [[ -z "$subj_path" ]] || [[ $# -lt 2 ]]; then
                echo "Error: subject tier requires <subject-path> and <title>" >&2
                echo "  Example: kb-knowledge-add subject ios/swift \"title here\"" >&2
                return 1
            fi
            if ! _kb_validate_subject_path "$subj_path"; then
                echo "Error: invalid subject path '${subj_path}' — each component must match ^[a-z][a-z0-9_-]*$ (no path traversal, no uppercase)" >&2
                return 1
            fi
            # XACA-0754-014 (ported XACA-0770): fail closed if the
            # session's team is genuinely unresolvable (ambiguous — could be
            # PII). No-op when it resolved, whether local or not.
            _kb_ambiguous_tier_write_guard "$flag_allow_global" || return 1
            if _kb_current_session_is_local_only_team; then
                write_root="$local_root"
            fi
            title_raw="${*:2}"
            target_dir="${write_root}/subjects/${subj_path}"
            prefix="s"
            ;;
        project)
            # Optional slug arg — if next arg looks like a path slug (no spaces), use it; otherwise title only
            if [[ $# -ge 2 ]] && echo "${1-}" | grep -qE '^[a-z0-9_/-]+$'; then
                local proj_slug="${1-}"
                if ! _kb_validate_subject_path "$proj_slug"; then
                    echo "Error: invalid project slug '${proj_slug}' — each component must match ^[a-z][a-z0-9_-]*$ (no path traversal)" >&2
                    return 1
                fi
                # XACA-0754-014 (ported XACA-0770): same fail-closed
                # guard as subject — a named project slug carries no team
                # information of its own either.
                _kb_ambiguous_tier_write_guard "$flag_allow_global" || return 1
                if _kb_current_session_is_local_only_team; then
                    write_root="$local_root"
                fi
                title_raw="${*:2}"
                target_dir="${write_root}/projects/${proj_slug}"
            else
                title_raw="$*"
                # XACA-0754-013 (ported XACA-0770): use the "effective"
                # resolver, which redirects only the bare
                # ${global_root}/projects/<slug> fallback case to local_root
                # for a local-only session — an in-repo .knowledge-config.yml
                # / KB_KNOWLEDGE_PROJECT_PATH override already points outside
                # the synced repo and passes through unchanged.
                target_dir=$(_kb_knowledge_project_path_effective)
                # XACA-0754-014: only the global-root FALLBACK case is
                # ambiguity-sensitive — an in-repo/env-var override already
                # points somewhere outside the synced repo regardless of
                # whether the session's team can be resolved.
                #
                # ORDERING IS LOAD-BEARING (XACA-0883 guard contract §3.5):
                # the PII gate MUST run FIRST, on the pre-redirect $target_dir
                # — running the layout guard first would open a real bypass,
                # because redirecting target_dir out from under
                # ${global_root}/projects/ makes THIS prefix test stop
                # matching, silently skipping the PII check for a write that
                # was inside the synced root a moment earlier.
                if [[ "$target_dir" == "${global_root}/projects/"* ]]; then
                    _kb_ambiguous_tier_write_guard "$flag_allow_global" || return 1
                fi
                # Layout gate SECOND; may rewrite target_dir to the canonical
                # base (XACA-0883). Independent of the PII guard above — see
                # _kb_knowledge_project_layout_guard's header comment.
                target_dir=$(_kb_knowledge_project_layout_guard "$target_dir" "$flag_allow_nonstandard_base") || return 1
            fi
            prefix="p"
            ;;
        team)
            local team_name="${1:-}"
            if [[ -z "$team_name" ]] || [[ $# -lt 2 ]]; then
                echo "Error: team tier requires <team-name> and <title>" >&2
                echo "  Example: kb-knowledge-add team mobile-platform \"title here\"" >&2
                return 1
            fi
            if ! _kb_validate_name_component "$team_name"; then
                echo "Error: invalid team name '${team_name}' — must match ^[a-z][a-z0-9_-]*$ (no path traversal, no uppercase)" >&2
                return 1
            fi
            if _kb_is_local_only_team "$team_name"; then
                write_root="$local_root"
            fi
            # XACA-0802: same host-authorization check as the agent tier — see
            # the comment there. Refuses BEFORE mkdir -p / id allocation.
            _kb_knowledge_host_affinity_guard "$team_name" team "$flag_allow_foreign_host" || return 1
            title_raw="${*:2}"
            target_dir="${write_root}/teams/${team_name}"
            prefix="t"
            tier_field="team: ${team_name}"
            ;;
        *)
            echo "Error: unknown tier '${tier}'. Expected: agent | subject | project | team" >&2
            return 1
            ;;
    esac

    # Ensure target directory exists
    if [[ ! -d "$target_dir" ]]; then
        echo "Creating directory: $target_dir"
        mkdir -p "$target_dir"
    fi

    # Compute the title slug up front — it is title-derived and independent of
    # any other entry, so it needs no serialization.
    local title_slug
    title_slug=$(_kb_knowledge_slugify "$title_raw")

    # XACA-0818: close the scan→compute→create TOCTOU race in the id allocator.
    # See _kb_alloc_slot's header comment for the full race description. It
    # serializes the whole critical section under an exclusive lock (kept
    # under TMPDIR, keyed by target-dir hash — NOT inside the synced tree, so
    # it can't wedge kb-knowledge-sync's Guard-3 dirty check) and reserves an
    # empty placeholder <prefix>NNN-<slug>.md inside target_dir. The real
    # content is written into that reserved file below, after the lock
    # releases (safe: the filename is uniquely ours).
    local new_file
    new_file=$(_kb_alloc_slot "$target_dir" "$prefix" "$title_slug")

    if [[ -z "$new_file" || ! -f "$new_file" ]]; then
        echo "Error: failed to atomically allocate a knowledge entry id in ${target_dir}" >&2
        return 1
    fi

    # Derive the id fields from the atomically reserved filename.
    local entry_id padded_id
    entry_id=$(basename "$new_file" .md)
    padded_id="${entry_id#${prefix}}"
    padded_id="${padded_id%%-*}"

    # Determine the template to use
    local template_file="${global_root}/templates/knowledge_entry_template.md"

    # Write the frontmatter scaffold
    local today
    today=$(date +%Y-%m-%d)

    # Compose frontmatter — inject tier-specific field (agent: <persona>, team: <name>)
    # only when applicable. Per SPEC §3, agent and team tiers REQUIRE this field.
    local frontmatter
    if [[ -n "$tier_field" ]]; then
        frontmatter=$(printf -- '---\nid: %s\ntier: %s\n%s\ndate: %s\ntags: []\n---' \
            "$entry_id" "$tier" "$tier_field" "$today")
    else
        frontmatter=$(printf -- '---\nid: %s\ntier: %s\ndate: %s\ntags: []\n---' \
            "$entry_id" "$tier" "$today")
    fi

    if [[ -f "$template_file" ]]; then
        # Use template but replace the header placeholder
        # Swap in actual id/tier/date and a real title heading
        local display_prefix
        display_prefix=$(echo "${prefix}" | tr '[:lower:]' '[:upper:]')
        local display_num="${display_prefix}${padded_id}"

        cat > "$new_file" <<FRONTMATTER
${frontmatter}

# ${display_num}: ${title_raw}

## Problem

<!-- Describe the symptom and root cause. -->

## Solution

<!-- The fix, workaround, or correct approach. -->

## Why this matters

<!-- What could go wrong next time if forgotten. -->

---
FRONTMATTER
    else
        cat > "$new_file" <<FRONTMATTER
${frontmatter}

# $(echo "${prefix}" | tr '[:lower:]' '[:upper:]')${padded_id}: ${title_raw}

## Problem



## Solution



## Why this matters


FRONTMATTER
    fi

    echo "Created: ${new_file}"

    # XACA-0263: scaffold INDEX.md immediately so a fresh tier dir is queryable
    # without a follow-up `kb-knowledge-reindex` call. Silent on success;
    # failure here doesn't block entry creation (file is already on disk).
    _kb_knowledge_reindex_one "$target_dir" >/dev/null 2>&1 || true

    if [[ "${KB_KNOWLEDGE_OPEN_AFTER_ADD:-0}" == "1" ]] && [[ -n "${EDITOR:-}" ]]; then
        "${EDITOR}" "$new_file"
    fi
}

# Promote a knowledge entry from one tier to another
# Usage: kb-knowledge-promote <source-ref> <target-ref>
#
# Source ref format:  agents:emh:k042  OR  agents:emh:k042-state-reset
# Target ref format:  subjects:ios/swift  OR  subjects:ios/swift:s003-state-reset-pattern
#
# If target includes an entry ID it is used verbatim; otherwise the next
# available ID in the target directory is assigned.
# Pass --confirm to actually execute (cross-repo moves print plan and require --confirm).
kb-knowledge-promote() {
    setopt LOCAL_OPTIONS NO_NOMATCH
    local source_ref="${1:-}" target_ref="${2:-}" flag_confirm=false
    # XACA-0883-021/024: independent of --confirm in both directions, same
    # design precedent as kb-knowledge-add's --allow-nonstandard-base
    # (XACA-0883-004 guard contract §3.5) — a user silencing a layout warning
    # must not thereby also silence the dry-run/execute control, or vice versa.
    local flag_allow_nonstandard_base=false

    shift 2 2>/dev/null
    while [[ $# -gt 0 ]]; do
        case "${1-}" in
            --confirm) flag_confirm=true; shift ;;
            --allow-nonstandard-base) flag_allow_nonstandard_base=true; shift ;;
            *) echo "Unknown flag: ${1-}" >&2; shift ;;
        esac
    done

    if [[ -z "$source_ref" ]] || [[ -z "$target_ref" ]]; then
        echo "Usage: kb-knowledge-promote <source-ref> <target-ref> [--confirm] [--allow-nonstandard-base]"
        echo ""
        echo "  source-ref   agents:<persona>:<entry-id>"
        echo "  target-ref   subjects:<path>  OR  subjects:<path>:<entry-id>"
        echo ""
        echo "  --confirm"
        echo "             Execute the promotion. Without it, this is a dry-run: prints"
        echo "             the plan (including the project-tier destination the real run"
        echo "             would use) and exits without creating any directory or writing"
        echo "             any file."
        echo "  --allow-nonstandard-base"
        echo "             project tier only (XACA-0883): write to the target path as"
        echo "             resolved, even when it lands inside the git work-tree while"
        echo "             this repo's canonical kanban directory is a sibling of it."
        echo "             Normally the write is redirected to the canonical base, or"
        echo "             refused outright if the canonical base is ambiguous (an"
        echo "             unattributable, disagreeing registry). Independent of"
        echo "             --confirm in both directions — neither implies the other."
        echo ""
        echo "Examples:"
        echo "  kb-knowledge-promote agents:emh:k042 subjects:ios/swift"
        echo "  kb-knowledge-promote agents:emh:k042-state-reset subjects:ios/swift:s003-state-reset-pattern"
        return 1
    fi

    # ── SPEC §7 tier-ordering guard (cheap early exit, no filesystem reads) ────
    # Promotions only flow upward (applicability broadens). Same-tier and
    # downward moves are refused. To move content downward, copy manually and
    # mark the source obsolete (per SPEC §7 prose).
    local source_tier target_tier
    source_tier="${source_ref%%:*}"
    target_tier="${target_ref%%:*}"

    # XACA-0883-029: --allow-nonstandard-base is the project-tier layout
    # guard's own override (XACA-0883-021/024) — it only has meaning when
    # the target tier is "project", since the layout guard is never
    # consulted for agents/teams/subjects targets. Refuse explicitly instead
    # of silently accepting a flag that has no effect on any other tier.
    if $flag_allow_nonstandard_base && [[ "$target_tier" != "project" ]]; then
        echo "Error: --allow-nonstandard-base only applies to a project-tier target (XACA-0883); target tier here is '${target_tier}'." >&2
        return 1
    fi

    local source_rank target_rank
    source_rank=$(_kb_knowledge_tier_rank "$source_tier")
    target_rank=$(_kb_knowledge_tier_rank "$target_tier")
    if [[ -z "$source_rank" ]]; then
        echo "Error: unknown source tier '${source_tier}'. Expected: agents | teams | subjects | project" >&2
        return 1
    fi
    if [[ -z "$target_rank" ]]; then
        echo "Error: unknown target tier '${target_tier}'. Expected: agents | teams | subjects | project" >&2
        return 1
    fi
    if (( target_rank <= source_rank )); then
        echo "Error: refusing downward/same-tier promotion (SPEC §7)." >&2
        echo "  Source tier: ${source_tier} (rank ${source_rank})" >&2
        echo "  Target tier: ${target_tier} (rank ${target_rank})" >&2
        echo "  Promotions must flow strictly upward as applicability broadens:" >&2
        echo "    agents (1) → project (2) → teams (3) → subjects (4)" >&2
        if (( target_rank == source_rank )); then
            echo "  Same-tier moves are not promotions. Rename the file directly if relocating within a tier." >&2
        else
            echo "  To move content downward, copy it manually to the narrower tier" >&2
            echo "  and mark the original entry obsolete (per SPEC §7 prose)." >&2
        fi
        return 1
    fi

    local global_root
    global_root=$(_kb_knowledge_global_root)

    # ── Resolve source file ─────────────────────────────────────────────────────
    local source_file
    source_file=$(_kb_knowledge_resolve_ref "$source_ref" "$global_root")
    if [[ $? -ne 0 ]] || [[ -z "$source_file" ]]; then
        echo "Error: cannot resolve source ref '${source_ref}'" >&2
        return 1
    fi
    if [[ ! -f "$source_file" ]]; then
        echo "Error: source file not found: ${source_file}" >&2
        return 1
    fi

    # ── Parse source info ───────────────────────────────────────────────────────
    local source_id
    source_id=$(_kb_knowledge_yaml_field "$source_file" "id")
    [[ -z "$source_id" ]] && source_id="$(basename "$source_file" .md)"

    # ── Guard: refuse to re-promote an existing promotion stub (XACA-0257) ──────
    # A stub has status:promoted and a promoted_to pointer. Re-promoting would
    # overwrite that pointer and lose the original target reference.
    local source_status
    source_status=$(_kb_knowledge_yaml_field "$source_file" "status")
    if [[ "$source_status" == "promoted" ]]; then
        local existing_target
        existing_target=$(_kb_knowledge_yaml_field "$source_file" "promoted_to")
        echo "Error: source '${source_ref}' is already a promotion stub." >&2
        echo "       Already promoted to: ${existing_target:-<unknown>}" >&2
        echo "       Refusing to re-promote — that would overwrite the existing pointer." >&2
        echo "       Edit the target entry directly, or delete the stub manually to start over." >&2
        return 1
    fi

    # ── Resolve target directory and optional target ID ─────────────────────────
    # target_tier already resolved above by the SPEC §7 guard.
    local target_dir="" target_entry_id="" target_prefix target_tier_field=""
    local target_path_part target_entry_part
    local target_remainder="${target_ref#*:}"

    case "$target_tier" in
        subjects)
            # Last token is an entry ID if it matches sNNN-*
            if echo "$target_remainder" | grep -qE ':[sp][0-9]+-'; then
                target_path_part="${target_remainder%:*}"
                target_entry_part="${target_remainder##*:}"
            else
                target_path_part="$target_remainder"
                target_entry_part=""
            fi
            local target_subj_path
            target_subj_path=$(printf '%s' "$target_path_part" | tr ':' '/')
            if ! _kb_validate_subject_path "$target_subj_path"; then
                echo "Error: invalid subject path '${target_subj_path}' in ref '${target_ref}' — each component must match ^[a-z][a-z0-9_-]*$ (no path traversal)" >&2
                return 1
            fi
            target_dir="${global_root}/subjects/${target_subj_path}"
            target_prefix="s"
            ;;
        agents)
            target_path_part="${target_remainder%%:*}"
            target_entry_part="${target_remainder#*:}"
            [[ "$target_entry_part" == "$target_path_part" ]] && target_entry_part=""
            if ! _kb_validate_name_component "$target_path_part"; then
                echo "Error: invalid persona name '${target_path_part}' in ref '${target_ref}' — must match ^[a-z][a-z0-9_-]*$ (no path traversal, no uppercase)" >&2
                return 1
            fi
            target_dir="${global_root}/agents/${target_path_part}"
            target_prefix="k"
            target_tier_field="agent: ${target_path_part}"
            ;;
        teams)
            target_path_part="${target_remainder%%:*}"
            target_entry_part="${target_remainder#*:}"
            [[ "$target_entry_part" == "$target_path_part" ]] && target_entry_part=""
            if ! _kb_validate_name_component "$target_path_part"; then
                echo "Error: invalid team name '${target_path_part}' in ref '${target_ref}' — must match ^[a-z][a-z0-9_-]*$ (no path traversal, no uppercase)" >&2
                return 1
            fi
            target_dir="${global_root}/teams/${target_path_part}"
            target_prefix="t"
            target_tier_field="team: ${target_path_part}"
            ;;
        project)
            target_path_part=""
            target_entry_part="$target_remainder"
            target_dir=$(_kb_knowledge_project_path)
            # XACA-0883-021/024: route through the same layout guard
            # kb-knowledge-add's bare-project branch uses, so an
            # ambiguous-registry (T3) work-tree REFUSES here too instead of
            # silently promoting into a shadow base. A non-zero return
            # aborts the whole promotion before the plan is even printed and
            # before target_dir is used for anything — no directory
            # created, no file written.
            #
            # Dry-run (no --confirm) must not prompt: force_noninteractive so
            # a preview never blocks on stdin, while still showing (via the
            # guard's own stderr disclosure + the plan's "Target:" line
            # below) the destination a NON-interactive run would use.
            # --confirm gets the guard's normal behavior (interactive prompt
            # on a real tty, same as kb-knowledge-add) — and on a real tty a
            # user who DECLINES that prompt gets the ORIGINAL resolved
            # (non-canonical) path back instead, which this preview cannot
            # predict (XACA-0883-028: see the disclosed caveat in the
            # dry-run branch below, keyed off target_dir_pre_guard).
            local target_dir_pre_guard="$target_dir"
            local promote_force_noninteractive=true
            $flag_confirm && promote_force_noninteractive=false
            target_dir=$(_kb_knowledge_project_layout_guard "$target_dir" "$flag_allow_nonstandard_base" "$promote_force_noninteractive") || return 1
            target_prefix="p"
            ;;
        # No default branch: unknown tiers are caught upstream by the SPEC §7
        # guard. Reaching this case statement implies target_tier is one of the
        # four enumerated values.
    esac

    # Determine target entry ID
    # XACA-0818: track whether the id was auto-allocated. When it was, the
    # plan-time max+1 scan below is only a non-atomic ESTIMATE for the printed
    # plan — the authoritative slot is re-resolved under an exclusive per-dir
    # lock at execute time (after mkdir -p). An explicitly named target skips
    # that re-resolution and keeps its caller-supplied id.
    local target_entry_auto=false
    if [[ -n "$target_entry_part" ]]; then
        target_entry_id="$target_entry_part"
    else
        target_entry_auto=true
        # Find next available NNN in target dir.
        # Use `find` instead of a literal glob: zsh aborts the function with
        # "no matches found" when the glob expands to nothing (and target_dir
        # may not exist yet on the first promotion into a new subjects path).
        local highest_id=0
        local ef en
        if [[ -d "$target_dir" ]]; then
            while IFS= read -r ef; do
                [[ -f "$ef" ]] || continue
                en=$(basename "$ef" | grep -oE "^${target_prefix}[0-9]+" | tr -d "$target_prefix")
                en="${en#0}"; en="${en:-0}"
                [[ "$en" -gt "$highest_id" ]] && highest_id="$en"
            done < <(find "$target_dir" -maxdepth 1 -type f -name "${target_prefix}[0-9][0-9][0-9]-*.md" 2>/dev/null)
        fi
        local next_num=$(( highest_id + 1 ))
        local padded_num; printf -v padded_num "%03d" "$next_num"
        # Derive slug from source file basename
        local source_slug; source_slug=$(basename "$source_file" .md | sed 's/^[ktspmv][0-9]*-//')
        target_entry_id="${target_prefix}${padded_num}-${source_slug}"
    fi

    local target_file="${target_dir}/${target_entry_id}.md"

    # ── Print the plan ──────────────────────────────────────────────────────────
    echo ""
    echo "PROMOTION PLAN"
    echo "──────────────────────────────────────────────────────────────"
    echo "  Source:   ${source_file}"
    echo "  Target:   ${target_file}"
    echo "  Stub at:  ${source_file}  (2-line promotion stub)"
    echo ""
    echo "  Steps:"
    echo "  1. Create target directory if needed: ${target_dir}"
    echo "  2. Copy source content to target with updated frontmatter"
    echo "  3. Replace source with promotion stub"
    echo "  4. Update source INDEX.md"
    echo "  5. Update or create target INDEX.md entry"
    echo "──────────────────────────────────────────────────────────────"

    if ! $flag_confirm; then
        echo ""
        # XACA-0883-028: this preview's "Target:" line above reflects the
        # NON-interactive redirect outcome (dry-run always forces that
        # branch — see promote_force_noninteractive above). A real --confirm
        # run on an actual terminal instead hits the guard's interactive
        # prompt, and a user who declines it gets the ORIGINAL,
        # non-canonical path back — a genuinely different destination this
        # preview cannot predict. Disclose that only when it's actually
        # possible (target_dir_pre_guard is set only for the project tier,
        # and only differs from target_dir when the guard actually
        # redirected — no redirect means no divergence risk).
        if [[ "$target_tier" == "project" ]] && [[ "$target_dir" != "$target_dir_pre_guard" ]]; then
            echo "  Note: the Target above is the non-interactive (redirected/canonical) outcome. A --confirm run on a real terminal will prompt first; declining there writes into ${target_dir_pre_guard} instead, not the Target shown above (XACA-0883-028)."
        fi
        echo "  Dry-run only. Pass --confirm to execute."
        echo ""
        return 0
    fi

    # ── Execute ─────────────────────────────────────────────────────────────────
    local today; today=$(date +%Y-%m-%d)

    # 1. Ensure target dir
    mkdir -p "$target_dir"

    # XACA-0818: when the target id was auto-allocated, re-resolve the slot now
    # via the shared atomic allocator so two concurrent promotions into the same
    # tier dir cannot both land on the same NNN. _kb_alloc_slot keeps the lock
    # under TMPDIR (NOT inside the synced tree — see its header) and reserves an
    # empty placeholder so the next locked caller advances to NNN+1. The
    # plan-time id printed above is a non-atomic estimate; this is the
    # authoritative allocation. Skipped when the caller named the target entry
    # explicitly (behavior unchanged there).
    if $target_entry_auto; then
        local reserve_slug reserved_file
        reserve_slug=$(basename "$source_file" .md | sed 's/^[ktspmv][0-9]*-//')
        reserved_file=$(_kb_alloc_slot "$target_dir" "$target_prefix" "$reserve_slug")
        if [[ -z "$reserved_file" || ! -f "$reserved_file" ]]; then
            echo "Error: failed to atomically allocate a promotion target id in ${target_dir}" >&2
            return 1
        fi
        target_file="$reserved_file"
        target_entry_id=$(basename "$target_file" .md)
    fi

    # Capture source frontmatter BEFORE any write — the stub-write block below
    # truncates source_file via `> "$source_file"` redirection, which would
    # otherwise leave tier/date blank when read inside the block.
    local source_date source_tags source_source
    source_tier=$(_kb_knowledge_yaml_field "$source_file" "tier")
    source_date=$(_kb_knowledge_yaml_field "$source_file" "date")
    source_tags=$(_kb_knowledge_yaml_field "$source_file" "tags")
    source_source=$(_kb_knowledge_yaml_field "$source_file" "source")

    # 2. Copy content with updated frontmatter
    # Write target file: update id, tier fields in frontmatter.
    # Per SPEC §3, tier:agent REQUIRES `agent:` and tier:team REQUIRES `team:`.
    # target_tier_field is set by the case block above for those tiers (XACA-0272).
    {
        echo "---"
        echo "id: ${target_entry_id}"
        echo "tier: ${target_tier%s}"
        [[ -n "$target_tier_field" ]] && echo "$target_tier_field"
        echo "date: ${source_date}"
        [[ -n "$source_tags" ]] && echo "tags: ${source_tags}"
        [[ -n "$source_source" ]] && echo "source: ${source_source}"
        echo "promoted_from: ${source_ref}"
        echo "---"
        echo ""
        # Copy body (everything after the closing ---)
        awk '/^---/{count++; if(count==2){found=1; next}} found{print}' "$source_file"
    } > "$target_file"

    # 3. Replace source with stub
    local display_id
    display_id=$(basename "$source_file" .md | sed 's/-.*$//' | tr '[:lower:]' '[:upper:]')
    {
        echo "---"
        echo "id: ${source_id}"
        echo "tier: ${source_tier}"
        echo "date: ${source_date}"
        echo "status: promoted"
        echo "promoted_to: ${target_tier}:${target_path_part:+${target_path_part}:}${target_entry_id}"
        echo "---"
        echo ""
        echo "# ${display_id} (promoted)"
        echo "This entry was promoted to \`${target_tier}:${target_path_part:+${target_path_part}:}${target_entry_id}\` on ${today}."
    } > "$source_file"

    echo "  Wrote target:  ${target_file}"
    echo "  Wrote stub:    ${source_file}"

    # 4. Reindex both affected directories
    kb-knowledge-reindex --dir "$(dirname "$source_file")" 2>/dev/null && echo "  Reindexed: $(dirname "$source_file")"
    kb-knowledge-reindex --dir "$target_dir" 2>/dev/null && echo "  Reindexed: ${target_dir}"

    echo ""
    echo "Promotion complete."
    echo "Suggested commit message:"
    echo "  promote: ${source_ref} → ${target_tier}:${target_path_part:+${target_path_part}:}${target_entry_id}"
}
# ─────────────────────────────────────────────────────────────────────────────
# XACA-0842 — kb-knowledge-merge: LATERAL (same-tier) agent-dir consolidation
#
# WHY THIS EXISTS, AND WHY IT IS NOT kb-knowledge-promote
# ~/knowledge/agents/ accumulated duplicate directories per persona (e.g.
# `jett-reno` alongside `reno`), stranding ~55 entries that kb-knowledge-search
# never surfaces. Consolidating them is a SAME-TIER move (agents → agents).
# kb-knowledge-promote deliberately refuses exactly that: SPEC §7 makes
# promotion strictly upward (agents 1 → project 2 → teams 3 → subjects 4) and
# its rank guard hard-fails `target_rank <= source_rank`. That guard is CORRECT
# and is left untouched — this is a separate, purpose-built sibling verb rather
# than a weakening of the promotion contract.
#
# THE HARD PART IS NOT MOVING FILES — IT IS NOT ORPHANING REFERENCES.
# Both directories number from k001, so every source entry must be renumbered
# into the target's next free slots. Renumbering silently invalidates every
# existing citation, so this function rewrites references across the WHOLE
# knowledge base (all tiers + per-repo project knowledge + retrospectives).
#
# Reference-repair rules — deliberately conservative, because two classes of
# false positive would be actively destructive:
#
#   1. `[[...]]` is NOT a safe blanket target. The knowledge base is full of
#      shell snippets like `[[ -d "$WORKTREE_ROOT/homebrew-tap/share" ]]` and
#      `[[ $# -gt 0 ]]` (9+ real occurrences). The matcher therefore requires
#      an id token IMMEDIATELY after `[[` (`[a-z]\d{3}`), so a space — which
#      every shell test has — excludes it.
#
#   2. Bare ids are AMBIGUOUS ACROSS PERSONAS. Nearly every persona dir has a
#      k012. A bare `K012` or `[[k012]]` sitting in subjects/ or a retro cannot
#      be attributed to the source persona from the token alone. Blindly
#      rewriting those would corrupt citations that point at OTHER personas.
#      So bare ids are rewritten only where attribution is certain:
#        * inside a MOVED COPY (mode=own) — within the source persona's own
#          entry set, a bare id unambiguously meant that persona's entry; or
#        * on a line carrying an explicit `agents/<source>` / `agents:<source>`
#          qualifier (the documented citation form, e.g. "K012 (agents/nahla)").
#      Everything else is reported LOUDLY as unresolved (never silently
#      dropped, and never silently rewritten).
#
#   Full-slug links (`[[k012-dependency-aware-subitem-delegation]]`) carry
#   their own disambiguator and are rewritten anywhere they appear.
#
#   NOTE the target's PRE-EXISTING entries are treated as FOREIGN, not own: a
#   bare `[[k005]]` in a target-owned entry means the TARGET's k005, and
#   rewriting it would be flatly wrong. Only the moved copies get own-mode.
#
# The source directory is left in place — a later subitem replaces it with a
# README pointer. Nothing here deletes it.
# ─────────────────────────────────────────────────────────────────────────────

# Internal: single-pass reference rewriter for kb-knowledge-merge.
#
# Usage: _kb_knowledge_merge_rewrite <mapfile> <apply:0|1> <own|foreign> <src-persona> <file>...
#
# mapfile is TSV: <old-full-id>\t<new-full-id>\t<old-short-id>\t<new-short-id>
#
# Emits on stdout (tab-separated, machine-readable):
#   SUB\t<file>\t<substitution-count>      — per file that changed (or would)
#   UNRES\t<file>\t<lineno>\t<token>       — reference it could NOT attribute
#
# Rewrites are ONE pass per rule, so a renumber chain (k001→k016 while
# k016→k031 in the same batch) can never double-apply: Perl's s///ge does not
# rescan its own replacement text. The two rules cannot feed each other either,
# because rule 1 emits lowercase ids and rule 2 only matches uppercase `K`.
_kb_knowledge_merge_rewrite() {
    local mapfile="${1-}" apply="${2-}" mode="${3-}" src_persona="${4-}"
    shift 4 2>/dev/null || return 0
    [[ $# -eq 0 ]] && return 0

    perl -e '
use strict;
use warnings;

my ($mapfile, $apply, $mode, $src) = splice(@ARGV, 0, 4);

my (%full, %short);
open(my $mh, "<", $mapfile) or die "kb-knowledge-merge: cannot read id map: $!";
while (my $l = <$mh>) {
    chomp $l;
    next unless length $l;
    my ($of, $nf, $os, $ns) = split(/\t/, $l, 4);
    next unless defined $ns;
    $full{$of}  = $nf;
    $short{$os} = $ns;
}
close $mh;

# Explicit persona qualifier, e.g. "K012 (agents/nahla)" or "agents:nahla:k012".
#
# XACA-0842 (PR #718 review): the qualifier binds to the TOKEN it governs, never
# to the whole line. The original implementation computed ONE line-level boolean
# and consumed it in every callback on that line, so:
#
#     See K001 (agents/nahla-ake) and also K003 (agents/emh)
#
# authorised rewriting K003 — which belongs to emh, not the merge source — and,
# because the qualified branch skips the else, never reported it. That breaks
# the core contract of this tool: a reference is either repaired correctly or
# reported loudly, never silently rewritten.
#
# Binding rules, deliberately conservative. A false "unresolved" costs a human
# 30 seconds; a silent wrong rewrite is undetectable and permanent.
#   * A qualifier governs a token only when it lies within $ADJACENT characters
#     of it AND no OTHER id token sits between the two. Proximity is what makes
#     "K001 (agents/nahla-ake)" resolve to the k001 of nahla-ake.
#   * Among governing candidates, the CLOSEST wins.
#   * If candidates naming DIFFERENT personas tie at the same distance, the
#     token is ambiguous — reported, never rewritten.
#   * A governing qualifier naming a persona OTHER than the merge source
#     SUPPRESSES its token: unambiguously not ours, so neither rewritten nor
#     reported as ambiguous. It is emitted as SUPPR so it cannot silently
#     vanish from the report.
#   * No governing qualifier -> prior behaviour (foreign mode reports it
#     unresolved; own mode still rewrites, since inside a moved copy a bare id
#     unambiguously meant the entry of that persona).
my $ADJACENT = 40;
my $qual_re  = qr{agents[:/]([a-z][a-z0-9_-]*)};

# Which qualifier, if any, governs $tok. Returns (persona, ambiguous_flag).
sub _governing {
    my ($tok, $quals, $toks, $adjacent) = @_;
    my @cand;
    for my $q (@$quals) {
        my ($gap, $lo, $hi);
        if    ($q->{start} >= $tok->{end})   { $gap = $q->{start} - $tok->{end};  ($lo, $hi) = ($tok->{end}, $q->{start}); }
        elsif ($q->{end}   <= $tok->{start}) { $gap = $tok->{start} - $q->{end};  ($lo, $hi) = ($q->{end}, $tok->{start}); }
        else                                 { $gap = 0; ($lo, $hi) = (0, 0); }
        next if $gap > $adjacent;
        # An intervening id token breaks the association: in
        # "K001 and K003 (agents/emh)" the emh qualifier cannot reach K001.
        my $blocked = 0;
        if ($hi > $lo) {
            for my $o (@$toks) {
                next if $o == $tok;
                if ($o->{start} >= $lo && $o->{end} <= $hi) { $blocked = 1; last; }
            }
        }
        next if $blocked;
        push @cand, { persona => $q->{persona}, gap => $gap };
    }
    return (undef, 0) unless @cand;
    my ($min) = sort { $a <=> $b } map { $_->{gap} } @cand;
    my %names = map { $_->{persona} => 1 } grep { $_->{gap} == $min } @cand;
    my @n = keys %names;
    return (undef, 1) if @n > 1;
    # This is PERL, not zsh. Perl arrays are 0-indexed, so $n[0] is the first
    # element and is correct here. The XACA-0812 guard skips quoted HEREDOC
    # bodies but not `perl -e ...` single-quoted strings, so it scans this block
    # as if it were zsh. @n holds exactly one element at this point: the >1 case
    # returned above, the empty case at the `unless @cand` guard. The pragma sits
    # on the statement itself because the guard only honours it there or on the
    # single line immediately above.
    return ($n[0], 0);  # zsh-index-ok (Perl array, 0-indexed by definition)
}

for my $file (@ARGV) {
    open(my $fh, "<", $file) or next;
    my @lines = <$fh>;
    close $fh;

    my $subs   = 0;
    my $lineno = 0;
    my (@unres, @suppr);

    # Aliasing loop: modifying $line writes back into @lines.
    for my $line (@lines) {
        $lineno++;

        my @quals;
        while ($line =~ /$qual_re/g) {
            push @quals, { persona => $1, start => $-[0], end => $+[0] };
        }

        # ONE combined scan so both token kinds share a coordinate space, which
        # the "no other id token between" test above depends on. The id token
        # must abut "[[" so shell test syntax ("[[ -d ... ]]") can never match.
        my @toks;
        while ($line =~ m{\[\[([a-z]\d{3})((?:-[A-Za-z0-9._-]+)?)\]\]|\bK(\d{3})\b}g) {
            my ($ws, $wr, $kn) = ($1, $2, $3);
            my %t = (start => $-[0], end => $+[0], text => substr($line, $-[0], $+[0] - $-[0]));
            if (defined $kn) { $t{kind} = "K"; $t{short} = "k$kn"; }
            else             { $t{kind} = "W"; $t{short} = $ws; $t{full} = $ws . (defined $wr ? $wr : ""); }
            push @toks, \%t;
        }
        next unless @toks;

        for my $t (@toks) {
            my $repl;
            if ($t->{kind} eq "W" && $t->{full} ne $t->{short} && exists $full{$t->{full}}) {
                # Full-slug link carries its own disambiguator — always safe.
                $repl = "[[" . $full{$t->{full}} . "]]";
                $subs++;
            } elsif (exists $short{$t->{short}}) {
                my $rewrite = 0;
                if ($mode eq "own") {
                    $rewrite = 1;
                } else {
                    my ($gov, $amb) = _governing($t, \@quals, \@toks, $ADJACENT);
                    if    ($amb)             { push @unres, [$lineno, $t->{text}]; }
                    elsif (!defined $gov)    { push @unres, [$lineno, $t->{text}]; }
                    elsif ($gov eq $src)     { $rewrite = 1; }
                    else                     { push @suppr, [$lineno, $t->{text}, $gov]; }
                }
                if ($rewrite) {
                    if ($t->{kind} eq "K") {
                        my $ns = $short{$t->{short}}; $ns =~ s/^k//;
                        $repl = "K" . $ns;
                    } else {
                        $repl = "[[" . $short{$t->{short}} . "]]";
                    }
                    $subs++;
                }
            }
            $t->{repl} = $repl;
        }

        # Rebuild in ONE left-to-right pass. Tokens never overlap, so a splice
        # can never re-scan its own output: a renumber chain (k001->k016 while
        # k016->k031 in the same batch) cannot double-apply.
        my $outl = ""; my $prev = 0;
        for my $t (@toks) {
            $outl .= substr($line, $prev, $t->{start} - $prev);
            $outl .= defined $t->{repl} ? $t->{repl} : $t->{text};
            $prev  = $t->{end};
        }
        $outl .= substr($line, $prev);
        $line  = $outl;
    }

    if ($subs > 0 && $apply eq "1") {
        open(my $out, ">", $file) or die "kb-knowledge-merge: cannot write $file: $!";
        print $out @lines;
        close $out;
    }

    print "SUB\t$file\t$subs\n" if $subs > 0;
    print "UNRES\t$file\t$_->[0]\t$_->[1]\n" for @unres;
    print "SUPPR\t$file\t$_->[0]\t$_->[1]\t$_->[2]\n" for @suppr;
}
' "$mapfile" "$apply" "$mode" "$src_persona" "$@"
}

# Internal: enumerate the roots kb-knowledge-merge sweeps for referrers.
# Global + local knowledge roots, this repo's project-tier knowledge, this
# repo's retrospectives, plus any colon-separated KB_KNOWLEDGE_MERGE_EXTRA_ROOTS
# (fleet sweeps across sibling repos).
#
# KB_KNOWLEDGE_MERGE_SCAN_ROOTS (colon-separated) REPLACES the whole default set
# — an explicit allow-list that bounds the blast radius. This matters because the
# repo-derived roots below resolve to the MAIN worktree's real
# <repo>/kanban/{knowledge/project,plans} via .knowledge-config.yml, which
# KB_KNOWLEDGE_GLOBAL_ROOT does NOT sandbox (that config file takes precedence
# over every env var in _kb_knowledge_project_path). Without this allow-list a
# --confirm run driven from a test/CI sandbox would happily rewrite live
# retrospectives. The bats suite sets it; so should any dry-runnable automation.
_kb_knowledge_merge_search_roots() {
    setopt LOCAL_OPTIONS NO_NOMATCH
    local -a roots
    local r

    if [[ -n "${KB_KNOWLEDGE_MERGE_SCAN_ROOTS:-}" ]]; then
        for r in "${(@s/:/)KB_KNOWLEDGE_MERGE_SCAN_ROOTS}"; do
            [[ -n "$r" && -d "$r" ]] && roots+=("$r")
        done
        [[ ${#roots[@]} -eq 0 ]] && return 0
        printf '%s\n' "${roots[@]}"
        return 0
    fi

    roots+=("$(_kb_knowledge_global_root)")

    local local_root
    local_root=$(_kb_knowledge_local_root 2>/dev/null)
    [[ -n "$local_root" && -d "$local_root" ]] && roots+=("$local_root")

    # Project-tier knowledge and retrospectives live in the MAIN repo worktree.
    local proj
    proj=$(_kb_knowledge_project_path 2>/dev/null)
    if [[ -n "$proj" && -d "$proj" ]]; then
        roots+=("$proj")
        # Retros sit beside project knowledge under <repo>/kanban/plans.
        local plans="${proj:h:h}/plans"
        [[ -d "$plans" ]] && roots+=("$plans")
    fi

    if [[ -n "${KB_KNOWLEDGE_MERGE_EXTRA_ROOTS:-}" ]]; then
        for r in "${(@s/:/)KB_KNOWLEDGE_MERGE_EXTRA_ROOTS}"; do
            [[ -n "$r" && -d "$r" ]] && roots+=("$r")
        done
    fi

    [[ ${#roots[@]} -eq 0 ]] && return 0
    printf '%s\n' "${roots[@]}"
}

# Internal: report a reference-rewriter failure and say what it means.
#
# XACA-0842 (PR #718 review, subitem 009): the rewriter used to be invoked with
# its stderr sent to /dev/null and its exit status never checked. When perl
# die()d partway through a sweep, the output captured was empty or truncated,
# every awk counter therefore read 0, and the tool cheerfully printed
# "MERGE COMPLETE / References rewritten: 0" — reporting success it had not
# earned, AFTER the entries were already copied. That is the exact defect class
# this whole ticket exists to close: a reassuring result from a check that never
# actually ran.
#
# Args: <phase-label> <exit-code> <stderr-file> <entries-already-copied: yes|no>
# Always writes to stderr; callers must return non-zero afterwards.
_kb_knowledge_merge_rewrite_failed() {
    local phase="${1-}" rc="${2-}" errfile="${3-}" copied="${4-}"
    echo "" >&2
    echo "✗ kb-knowledge-merge FAILED: the reference rewriter exited ${rc} during the ${phase} phase." >&2
    echo "  This run did NOT complete. Do not treat any part of it as successful." >&2
    if [[ -s "$errfile" ]]; then
        echo "" >&2
        echo "  Rewriter error output:" >&2
        sed 's/^/      /' "$errfile" >&2
    else
        echo "  The rewriter produced no error output — it was most likely killed," >&2
        echo "  or perl is not available on PATH." >&2
    fi
    echo "" >&2
    if [[ "$copied" == "yes" ]]; then
        echo "  ⚠️  ENTRIES WERE ALREADY COPIED into the target directory before this" >&2
        echo "      failure. Reference repair is therefore INCOMPLETE and some references" >&2
        echo "      are now orphaned. Your next steps:" >&2
        echo "        * Do NOT retire the source directory — it is still the intact copy." >&2
        echo "        * Fix the cause, then re-run the merge, or restore the knowledge" >&2
        echo "          tree from backup before retrying." >&2
    else
        echo "  No files were created or modified — this failed during dry-run analysis," >&2
        echo "  before any copy or rewrite took place. Fix the cause and re-run." >&2
    fi
    echo "" >&2
}

# Consolidate one agent knowledge directory into another (same tier).
# Usage: kb-knowledge-merge <source-persona> <target-persona> [--dry-run] [--confirm]
#
# Examples:
#   kb-knowledge-merge jett-reno reno              # plan only, changes nothing
#   kb-knowledge-merge jett-reno reno --dry-run    # explicit plan
#   kb-knowledge-merge jett-reno reno --confirm    # execute
kb-knowledge-merge() {
    setopt LOCAL_OPTIONS NO_NOMATCH
    local source_persona="${1:-}" target_persona="${2:-}"
    local flag_confirm=false flag_dryrun=false

    shift 2 2>/dev/null
    while [[ $# -gt 0 ]]; do
        case "${1-}" in
            --confirm) flag_confirm=true; shift ;;
            --dry-run) flag_dryrun=true; shift ;;
            *) echo "Unknown flag: ${1-}" >&2; shift ;;
        esac
    done

    if [[ -z "$source_persona" ]] || [[ -z "$target_persona" ]]; then
        echo "Usage: kb-knowledge-merge <source-persona> <target-persona> [--dry-run] [--confirm]"
        echo ""
        echo "  Consolidates agents/<source-persona>/ into agents/<target-persona>/."
        echo "  Same-tier (agents → agents) lateral move. For UPWARD tier movement"
        echo "  use kb-knowledge-promote — it refuses same-tier moves by design (SPEC §7)."
        echo ""
        echo "  Source entries are renumbered into the target's next free ids (slug"
        echo "  preserved); a target entry is never overwritten. Every reference to a"
        echo "  renumbered entry is repaired across all knowledge tiers, per-repo"
        echo "  project knowledge, and retrospectives. References that cannot be"
        echo "  attributed with certainty are reported, never silently rewritten."
        echo ""
        echo "  --dry-run    Print the plan and change nothing (this is the default)."
        echo "  --confirm    Actually execute. Required for any write."
        echo ""
        echo "  The source directory is NOT deleted."
        echo ""
        echo "Examples:"
        echo "  kb-knowledge-merge jett-reno reno"
        echo "  kb-knowledge-merge jett-reno reno --confirm"
        return 1
    fi

    # --dry-run wins if both are passed: the safe reading of a contradictory
    # instruction is "do not write".
    if $flag_dryrun; then
        flag_confirm=false
    fi

    if ! _kb_validate_name_component "$source_persona"; then
        echo "Error: invalid source persona '${source_persona}' — must match ^[a-z][a-z0-9_-]*$ (no path traversal, no uppercase)" >&2
        return 1
    fi
    if ! _kb_validate_name_component "$target_persona"; then
        echo "Error: invalid target persona '${target_persona}' — must match ^[a-z][a-z0-9_-]*$ (no path traversal, no uppercase)" >&2
        return 1
    fi
    if [[ "$source_persona" == "$target_persona" ]]; then
        echo "Error: source and target persona are the same ('${source_persona}') — nothing to merge." >&2
        return 1
    fi

    local global_root
    global_root=$(_kb_knowledge_global_root)
    local source_dir="${global_root}/agents/${source_persona}"
    local target_dir="${global_root}/agents/${target_persona}"

    if [[ ! -d "$source_dir" ]]; then
        echo "Error: source directory not found: ${source_dir}" >&2
        return 1
    fi
    if [[ ! -d "$target_dir" ]]; then
        echo "Error: target directory not found: ${target_dir}" >&2
        echo "       Refusing to create it — a missing target is usually a typo." >&2
        return 1
    fi

    # ── Enumerate source entries ────────────────────────────────────────────────
    # find, not a literal glob: zsh aborts the function on a no-match glob.
    local -a source_files
    local f
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        source_files+=("$f")
    done < <(find "$source_dir" -maxdepth 1 -type f \
                \( -name 'k[0-9][0-9][0-9]-*.md' -o -name 'k[0-9][0-9][0-9].md' \) 2>/dev/null | sort)

    if [[ ${#source_files[@]} -eq 0 ]]; then
        echo "Error: no knowledge entries found in ${source_dir}" >&2
        return 1
    fi

    # ── Find the target's highest existing id ───────────────────────────────────
    local highest=0 en
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        en=$(basename "$f" | sed -n 's/^k0*\([0-9][0-9]*\).*/\1/p')
        [[ -z "$en" ]] && continue
        if [[ "$en" -gt "$highest" ]] 2>/dev/null; then
            highest="$en"
        fi
    done < <(find "$target_dir" -maxdepth 1 -type f \
                \( -name 'k[0-9][0-9][0-9]-*.md' -o -name 'k[0-9][0-9][0-9].md' \) 2>/dev/null)

    # ── Build the renumbering map ───────────────────────────────────────────────
    local tmpdir="${TMPDIR:-/tmp}/kb-knowledge-merge-$$"
    mkdir -p "$tmpdir" || { echo "Error: cannot create temp dir ${tmpdir}" >&2; return 1; }
    local mapfile="${tmpdir}/idmap.tsv"
    : > "$mapfile"

    local -a plan_lines
    local next="$highest"
    local old_full old_short slug new_num new_short new_full
    for f in "${source_files[@]}"; do
        old_full=$(basename "$f" .md)
        old_short="${old_full%%-*}"
        slug="${old_full#*-}"
        [[ "$slug" == "$old_full" ]] && slug=""

        next=$(( next + 1 ))
        printf -v new_num "%03d" "$next"
        new_short="k${new_num}"
        if [[ -n "$slug" ]]; then
            new_full="${new_short}-${slug}"
        else
            new_full="$new_short"
        fi

        # Never overwrite a target entry. ids are allocated above the target's
        # current maximum so this should be unreachable — assert anyway.
        if [[ -e "${target_dir}/${new_full}.md" ]]; then
            echo "Error: refusing to overwrite existing target entry ${target_dir}/${new_full}.md" >&2
            rm -f "$mapfile"
            rmdir "$tmpdir" 2>/dev/null
            return 1
        fi

        printf '%s\t%s\t%s\t%s\n' "$old_full" "$new_full" "$old_short" "$new_short" >> "$mapfile"
        plan_lines+=("    ${old_full}.md  →  ${new_full}.md")
    done

    # ── Collect referrer candidates across every search root ────────────────────
    # Deduped: a file reached through two overlapping roots must be rewritten
    # exactly once, or a renumber chain could double-apply.
    # Source-dir files are excluded (the dir is being retired untouched), as are
    # generated INDEX.md files (rebuilt from entry frontmatter, not rewritten).
    local -a scan_files
    local root
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        [[ "$f" == "${source_dir}/"* ]] && continue
        [[ "$(basename "$f")" == "INDEX.md" ]] && continue
        scan_files+=("$f")
    done < <(
        while IFS= read -r root; do
            [[ -d "$root" ]] || continue
            find "$root" -type f -name '*.md' 2>/dev/null
        done < <(_kb_knowledge_merge_search_roots) | sort -u
    )

    # ── Print the plan ──────────────────────────────────────────────────────────
    echo ""
    echo "KNOWLEDGE MERGE PLAN"
    echo "──────────────────────────────────────────────────────────────"
    echo "  Source dir:  ${source_dir}"
    echo "  Target dir:  ${target_dir}"
    echo "  Entries:     ${#source_files[@]}  (renumbered from k$(printf '%03d' $(( highest + 1 ))) upward)"
    echo "  Referrer scan candidates: ${#scan_files[@]} file(s)"
    echo ""
    echo "  Renumbering:"
    local pl
    for pl in "${plan_lines[@]}"; do
        echo "$pl"
    done
    echo ""
    echo "  Steps:"
    echo "  1. Copy each source entry into the target dir under its new id"
    echo "  2. Rewrite id:/agent: frontmatter in each moved copy"
    echo "  3. Repair self-references inside the moved copies"
    echo "  4. Repair [[links]] and K### citations across all knowledge tiers,"
    echo "     per-repo project knowledge, and retrospectives"
    echo "  5. Rebuild ${target_dir}/INDEX.md"
    echo "  6. Leave the source dir in place (README pointer is a later step)"
    echo "──────────────────────────────────────────────────────────────"

    # ── Dry-run: analyse without writing, then stop ─────────────────────────────
    if ! $flag_confirm; then
        # Rewriter stderr is CAPTURED, not discarded, and the exit status is
        # checked. `dry_out` is declared on its own line first: `local x=$(...)`
        # would make $? the status of `local`, not the command substitution —
        # the same class of trap as reading $? after a trailing pipeline.
        local dry_out dry_rc
        local dry_err="${tmpdir}/rewrite-dryrun.err"
        dry_out=$(
            {
                _kb_knowledge_merge_rewrite "$mapfile" 0 own "$source_persona" "${source_files[@]}" || exit 1
                if [[ ${#scan_files[@]} -gt 0 ]]; then
                    _kb_knowledge_merge_rewrite "$mapfile" 0 foreign "$source_persona" "${scan_files[@]}" || exit 1
                fi
            } 2>"$dry_err"
        )
        dry_rc=$?
        if [[ "$dry_rc" -ne 0 ]]; then
            # A silently-failing dry-run is arguably worse than a failing
            # execute: the operator reads a clean plan and then confirms it.
            _kb_knowledge_merge_rewrite_failed "dry-run analysis" "$dry_rc" "$dry_err" "no"
            rm -f "$mapfile" "$dry_err"
            rmdir "$tmpdir" 2>/dev/null
            return 1
        fi
        local dry_subs dry_unres
        dry_subs=$(printf '%s\n' "$dry_out" | awk -F'\t' '$1=="SUB"{n+=$3} END{print n+0}')
        dry_unres=$(printf '%s\n' "$dry_out" | awk -F'\t' '$1=="UNRES"{n++} END{print n+0}')
        local dry_suppr
        dry_suppr=$(printf '%s\n' "$dry_out" | awk -F'\t' '$1=="SUPPR"{n++} END{print n+0}')

        echo ""
        echo "  Projected: ${dry_subs} reference(s) would be rewritten."
        if [[ "$dry_suppr" -gt 0 ]]; then
            echo "  Suppressed: ${dry_suppr} reference(s) qualified to another persona (left alone)."
        fi
        if [[ "$dry_unres" -gt 0 ]]; then
            echo ""
            echo "  ⚠️  ${dry_unres} AMBIGUOUS reference(s) would NOT be rewritten:"
            printf '%s\n' "$dry_out" | awk -F'\t' '$1=="UNRES"{printf "      %s:%s  %s\n", $2, $3, $4}'
        fi
        echo ""
        echo "  Dry-run only. Pass --confirm to execute."
        echo ""
        rm -f "$mapfile"
        rmdir "$tmpdir" 2>/dev/null
        return 0
    fi

    # ── Execute ─────────────────────────────────────────────────────────────────
    local moved=0
    local -a moved_files
    local i=0
    local dest
    for f in "${source_files[@]}"; do
        i=$(( i + 1 ))
        new_full=$(awk -F'\t' -v n="$i" 'NR==n{print $2}' "$mapfile")
        if [[ -z "$new_full" ]]; then
            echo "Error: internal id-map lookup failed for ${f}" >&2
            rm -f "$mapfile"
            rmdir "$tmpdir" 2>/dev/null
            return 1
        fi
        dest="${target_dir}/${new_full}.md"

        # Paranoia: re-check immediately before the write.
        if [[ -e "$dest" ]]; then
            echo "Error: refusing to overwrite existing target entry ${dest}" >&2
            rm -f "$mapfile"
            rmdir "$tmpdir" 2>/dev/null
            return 1
        fi

        # Copy, rewriting the two tier-scoped frontmatter fields. Only the FIRST
        # occurrence of each is touched (frontmatter), leaving any body prose
        # that happens to start with "id:" alone.
        awk -v newid="$new_full" -v newagent="$target_persona" '
            BEGIN { done_id = 0; done_agent = 0 }
            !done_id && /^id:[[:space:]]/       { print "id: " newid;       done_id = 1; next }
            !done_agent && /^agent:[[:space:]]/ { print "agent: " newagent; done_agent = 1; next }
            { print }
        ' "$f" > "$dest"

        if [[ ! -s "$dest" ]]; then
            echo "Error: failed to write ${dest} (source left intact)" >&2
            rm -f "$dest"
            rm -f "$mapfile"
            rmdir "$tmpdir" 2>/dev/null
            return 1
        fi

        moved_files+=("$dest")
        moved=$(( moved + 1 ))
    done

    # Repair references. own-mode covers ONLY the moved copies; the target's
    # pre-existing entries are foreign (their bare ids mean the TARGET's ids).
    # As above: stderr captured, status checked, and `exec_out` declared
    # separately so $? belongs to the command substitution.
    local exec_out exec_rc
    local exec_err="${tmpdir}/rewrite-exec.err"
    exec_out=$(
        {
            _kb_knowledge_merge_rewrite "$mapfile" 1 own "$source_persona" "${moved_files[@]}" || exit 1
            if [[ ${#scan_files[@]} -gt 0 ]]; then
                _kb_knowledge_merge_rewrite "$mapfile" 1 foreign "$source_persona" "${scan_files[@]}" || exit 1
            fi
        } 2>"$exec_err"
    )
    exec_rc=$?
    if [[ "$exec_rc" -ne 0 ]]; then
        # Entries are already on disk at this point — the operator's recovery
        # path depends entirely on knowing that, so say it explicitly.
        _kb_knowledge_merge_rewrite_failed "reference repair" "$exec_rc" "$exec_err" "yes"
        rm -f "$mapfile" "$exec_err"
        rmdir "$tmpdir" 2>/dev/null
        return 1
    fi

    local refs_rewritten refs_files unresolved_count
    refs_rewritten=$(printf '%s\n' "$exec_out" | awk -F'\t' '$1=="SUB"{n+=$3} END{print n+0}')
    refs_files=$(printf '%s\n' "$exec_out" | awk -F'\t' '$1=="SUB"{n++} END{print n+0}')
    unresolved_count=$(printf '%s\n' "$exec_out" | awk -F'\t' '$1=="UNRES"{n++} END{print n+0}')
    local suppressed_count
    suppressed_count=$(printf '%s\n' "$exec_out" | awk -F'\t' '$1=="SUPPR"{n++} END{print n+0}')

    # Rebuild the target index from the merged entry set.
    _kb_knowledge_reindex_one "$target_dir" >/dev/null 2>&1 || true

    rm -f "$mapfile"
    rmdir "$tmpdir" 2>/dev/null

    # ── Report ──────────────────────────────────────────────────────────────────
    echo ""
    echo "MERGE COMPLETE"
    echo "──────────────────────────────────────────────────────────────"
    echo "  Entries moved:        ${moved}"
    echo "  Ids renumbered:       ${moved}"
    echo "  References rewritten: ${refs_rewritten}  (across ${refs_files} file(s))"
    echo "  Unresolved refs:      ${unresolved_count}"
    echo "  Suppressed refs:      ${suppressed_count}  (qualified to another persona — correctly left alone)"
    echo "  Target INDEX.md rebuilt: ${target_dir}/INDEX.md"
    echo "  Source dir left in place: ${source_dir}"

    if [[ "$suppressed_count" -gt 0 ]]; then
        echo ""
        echo "  Suppressed (a qualifier names a DIFFERENT persona, so these are"
        echo "  unambiguously not ours — neither rewritten nor flagged ambiguous):"
        printf '%s\n' "$exec_out" | awk -F'\t' '$1=="SUPPR"{printf "      %s:%s  %s  -> belongs to %s\n", $2, $3, $4, $5}'
    fi

    if [[ "$unresolved_count" -gt 0 ]]; then
        echo ""
        echo "  ⚠️  UNRESOLVED REFERENCES — these were NOT rewritten and now point"
        echo "      at the OLD ids. They are ambiguous (a bare id matches several"
        echo "      personas), so rewriting them automatically risked corrupting a"
        echo "      citation to a different persona. Review each by hand:"
        printf '%s\n' "$exec_out" | awk -F'\t' '$1=="UNRES"{printf "      %s:%s  %s\n", $2, $3, $4}'
        echo ""
        echo "      Tip: add an explicit qualifier (e.g. \"K012 (agents/${source_persona})\")"
        echo "      and re-run, or fix the citation to the new id directly."
    fi
    echo "──────────────────────────────────────────────────────────────"
    echo ""
    echo "Suggested commit message:"
    echo "  merge: knowledge agents/${source_persona} → agents/${target_persona} (${moved} entries)"
}

# ══════════════════════════════════════════════════════════════════════════════
# Duplicate persona-directory detection (XACA-0842)
# ══════════════════════════════════════════════════════════════════════════════
#
# Background — the defect this exists to prevent recurring:
#   A past migration slugified persona DISPLAY BYLINES into directory names
#   instead of using the canonical agent id. `~/knowledge/agents/thok-tuvok/`
#   was created from the byline "**Agent:** Thok/Tuvok (Academy Cadet Master,
#   QA Testing)" while `~/knowledge/agents/thok/` already existed. Same for
#   jett-reno/reno, nahla-ake/nahla, captain-sisko/sisko, captain-archer/archer,
#   travis-mayweather/mayweather. Result: ~55 entries stranded — invisible to
#   kb-knowledge-search, which resolves the canonical agent id only.
#
# This is a GATE, not a report. kb-knowledge-validate raises each finding via
# _kb_val_error (not _kb_val_warn), so a fragmented tree exits non-zero. A
# warning was explicitly rejected: the original fragmentation accumulated for
# months precisely because nothing failed.
#
# ── Detection: two mechanisms, deliberately kept separate ───────────────────
#
#   1. HEURISTIC (byline-slug shape). A hyphenated directory whose components
#      include the name of another existing directory is flagged:
#      `jett-reno` + `reno`, `captain-sisko` + `sisko`, `nahla-ake` + `nahla`.
#      This is a guess based on NAME SHAPE ALONE — it has no knowledge of who
#      any persona actually is. It can produce false positives; that is what
#      the allow-list below is for.
#
#   2. DECLARED ALIASES. Some duplicates share no substring at all —
#      `counselor` is the display title of `deanna`, `doctor` of `emh`. No
#      heuristic can derive that from the strings; pretending otherwise would
#      be dishonest. These pairs are hand-declared and must be maintained by a
#      human when a new display-name alias appears.
#
# The two mechanisms are unioned, pairs are normalised (alphabetically ordered)
# and de-duplicated, then the allow-list suppresses known-distinct pairs.
#
# Both mechanisms see only directories that actually CONTAIN entries. Retired
# pointer directories (README.md only, no `kNNN-*.md`) are skipped, because the
# gate exists to catch STRANDED ENTRIES and an entry-free directory strands
# nothing. See the _kb_kpd_has_entries block inside the function for the full
# rationale and for why the allow-list was NOT the right place for these.
#
# Output: one `<lo>|<hi>|<reason>` line per finding on stdout; no output means
# no duplicates. Non-zero exit is NOT used to signal findings (callers read the
# lines) — a non-zero return here means the directory was unreadable.
_kb_knowledge_persona_dup_pairs() {
    setopt LOCAL_OPTIONS NO_NOMATCH
    local agents_dir="${1:-}"
    agents_dir="${agents_dir%/}"
    [[ -d "$agents_dir" ]] || return 0

    # ── ALLOW-LIST: pairs that LOOK like duplicates but are DISTINCT personas ──
    #
    # Every entry MUST carry a justification. A bare list rots: six months from
    # now nobody remembers whether an entry was a real exemption or somebody
    # silencing a finding they did not want to fix. If you add a pair here
    # WITHOUT a reason, you have disabled the gate for that pair, permanently.
    #
    # Format: "<name-a>|<name-b>" — order does not matter, the lookup normalises.
    # Verified against the upstream persona master directory on 2026-07-24.
    local -a _KB_KNOWLEDGE_PERSONA_DISTINCT_PAIRS
    _KB_KNOWLEDGE_PERSONA_DISTINCT_PAIRS=(
        # MainEvent deliberately suffixes `-me` on two personas to avoid a name
        # collision with the Command team's Janeway/Paris. Both sides are real,
        # separately-defined agents with their own knowledge:
        #   command/command_janeway_strategic_persona.md      -> name: janeway
        #   mainevent/mainevent_janeway_leadfeature_persona.md -> name: janeway-me
        # Documented in ~/.claude/CLAUDE.md § "Per-Team Persona Layout".
        "janeway|janeway-me"
        #   command/command_paris_communications_persona.md   -> name: paris
        #   mainevent/mainevent_paris_ux_persona.md           -> name: paris-me
        "paris|paris-me"

        # `doctor` is NOT a display-title alias of Academy's `emh`, despite both
        # being EMH-flavoured. It is its own MainEvent agent:
        #   mainevent/mainevent_doctor_bugfix_persona.md      -> name: doctor
        #   academy/academy_emh_documentation_persona.md      -> name: emh
        # Different teams, different roles (bugfix vs documentation). This pair
        # IS in the declared-alias list below — the allow-list is what overrides
        # it. Remove this line and the gate starts failing on a legitimate tree.
        "doctor|emh"

        # `tuvok` is a real MainEvent security/test lead, not a byline fragment
        # of Academy's Vulcan QA persona `thok`:
        #   mainevent/mainevent_tuvok_security_persona.md     -> name: tuvok
        #   academy/academy_thok_testing_persona.md           -> name: thok
        # (Note: `thok-tuvok` is NOT exempt — that directory really is a byline
        # slug of `thok` and must be consolidated away.)
        "thok|tuvok"
    )

    # ── DECLARED display-name aliases ──────────────────────────────────────────
    # "<display-title-slug>|<canonical-agent-id>". These CANNOT be found by any
    # string heuristic — they are asserted by a human who knows the personas.
    # Add a line here whenever a persona's display title gets its own directory.
    local -a _KB_KNOWLEDGE_PERSONA_DECLARED_ALIASES
    _KB_KNOWLEDGE_PERSONA_DECLARED_ALIASES=(
        # NOTE the orientation: STRAY first, CANONICAL second. The canonical id
        # is the persona's frontmatter `name:` (SPEC 2.1) — NEVER the entry count
        # and NEVER the persona FILEname. ios_deanna_documentation_persona.md
        # declares `name: counselor`, so `counselor` is canonical and `deanna`
        # (the filename/display-derived spelling) is the stray. Getting this
        # backwards makes the gate print a command that folds the CANONICAL
        # directory into the stray — the same data-destroying inversion already
        # regression-tested on the heuristic path (travis-mayweather).
        "deanna|counselor"   # display/filename "Deanna" -> canonical id `counselor`
        "doctor|emh"         # "The Doctor"     -> canonical id `emh`  (see allow-list)
        "tuvok|thok"         # byline "Thok/Tuvok"                      (see allow-list)
    )

    # ── Does this directory hold any actual knowledge? (XACA-0842) ─────────────
    #
    # THE GATE DETECTS STRANDED ENTRIES. AN ENTRY-FREE DIRECTORY STRANDS NOTHING.
    #
    # That single sentence is the whole rule. After consolidation, the seven
    # byline-slug directories are RETIRED rather than deleted: each keeps a
    # README.md pointing at its canonical home so old references still resolve.
    # They therefore still exist, and still look like duplicate-persona pairs by
    # name — so without this filter the gate would fire on them forever.
    #
    # Allow-listing them was the obvious alternative and it is wrong. The
    # allow-list means, precisely, "these are DIFFERENT agents". Retired
    # pointers are the same agent. Putting them there would corrupt the one
    # contract that makes the allow-list trustworthy, and every future reader
    # would have to guess which entries were real exemptions.
    #
    # The entry count is the property that actually matters, and it is
    # self-maintaining: add a real entry to a retired directory and it re-enters
    # the roster, so the gate fires again — which is the correct behaviour,
    # because at that moment the directory really is hiding knowledge from
    # kb-knowledge-search.
    #
    # Deliberately NOT used as the test: the `status: retired` /
    # `consolidated_into:` frontmatter the READMEs carry. It is a fine secondary
    # signal but a bad primary one — a future author can omit it, misspell it,
    # or retire a directory without it, and the gate would then fire on a
    # correctly-retired pointer. Presence of entries cannot be forgotten.
    #
    # Consequence worth stating plainly: a pair fires only when BOTH sides hold
    # entries. The asymmetric case (stray has entries, canonical is empty) is
    # therefore skipped. That is intentional — an empty canonical directory is
    # indistinguishable from an absent one, and an absent one would produce no
    # pair either. Entries sitting under a wrong-but-unpaired directory name are
    # a naming defect, not a duplication defect, and a pair detector is the
    # wrong tool for it.
    #
    # Entry shape is the agent tier's `kNNN-<slug>.md`. README.md, INDEX.md and
    # anything else are explicitly NOT entries.
    local _kb_kpd_ent_f _kb_kpd_ent_bn _kb_kpd_ent_stem
    _kb_kpd_has_entries() {
        for _kb_kpd_ent_f in "${1}"/*.md; do
            [[ -f "$_kb_kpd_ent_f" ]] || continue
            _kb_kpd_ent_bn="${_kb_kpd_ent_f##*/}"
            case "$_kb_kpd_ent_bn" in
                k*-*.md) ;;
                *) continue ;;
            esac
            # Require DIGITS between the 'k' and the first hyphen, so a stray
            # file like `kb-notes.md` is not mistaken for an entry.
            _kb_kpd_ent_stem="${_kb_kpd_ent_bn#k}"
            _kb_kpd_ent_stem="${_kb_kpd_ent_stem%%-*}"
            case "$_kb_kpd_ent_stem" in
                ''|*[!0-9]*) continue ;;
            esac
            return 0
        done
        return 1
    }

    # ── Collect the directory roster ───────────────────────────────────────────
    local -a _kb_kpd_dirs
    local d base
    for d in "${agents_dir}"/*/; do
        [[ -d "$d" ]] || continue
        base="${d%/}"
        base="${base##*/}"
        [[ -n "$base" ]] || continue
        # Retired pointer dirs (and any other entry-free dir) are invisible to
        # the detector — see the block above.
        _kb_kpd_has_entries "${d%/}" || continue
        _kb_kpd_dirs+=("$base")
    done
    [[ ${#_kb_kpd_dirs[@]} -gt 0 ]] || return 0

    # Newline-delimited membership blobs. Avoids associative arrays, whose
    # declaration syntax and iteration order differ between bash and zsh.
    local _kb_kpd_roster=$'\n'
    for d in "${_kb_kpd_dirs[@]}"; do _kb_kpd_roster+="${d}"$'\n'; done

    local _kb_kpd_allow=$'\n' _kb_kpd_seen=$'\n'
    local p lo hi swap
    for p in "${_KB_KNOWLEDGE_PERSONA_DISTINCT_PAIRS[@]}"; do
        lo="${p%%|*}"; hi="${p##*|}"
        if [[ "$lo" > "$hi" ]]; then swap="$lo"; lo="$hi"; hi="$swap"; fi
        _kb_kpd_allow+="${lo}|${hi}"$'\n'
    done

    # Membership test against the roster.
    _kb_kpd_has() {
        case "$_kb_kpd_roster" in
            *$'\n'"${1}"$'\n'*) return 0 ;;
        esac
        return 1
    }

    # _kb_kpd_emit <suspected-non-canonical> <suspected-canonical> <why>
    #
    # DIRECTION MATTERS. Callers pass the pair oriented: arg 1 is the directory
    # believed to be the stray (the byline slug / display-name alias), arg 2 the
    # believed canonical agent id. That orientation is preserved on the output
    # line so the caller can render a correctly-ordered `kb-knowledge-merge
    # <from> <to>` — printing an alphabetically-sorted pair instead would emit
    # `kb-knowledge-merge mayweather travis-mayweather`, i.e. instructions to
    # merge the canonical directory INTO the stray. Sorting is used ONLY to
    # build the order-independent key for allow-list lookup and de-duplication.
    #
    # The direction is the detector's best guess, not a proven fact — the
    # rendered message says so, and the operator confirms before merging.
    # Return code carries whether a finding was actually PRINTED (0) or
    # suppressed (1 — same-name no-op, allow-listed exemption, or an
    # already-emitted identical pair). Callers that walk MULTIPLE candidate
    # matches for one stray directory (see the heuristic pass below) rely on
    # this to know when to stop looking: a suppressed match means try the
    # next candidate; a printed match means the stray already has its one
    # finding for this run.
    _kb_kpd_emit() {
        local from="${1}" to="${2}" why="${3}" _lo _hi _swap
        [[ "$from" == "$to" ]] && return 1
        _lo="$from"; _hi="$to"
        if [[ "$_lo" > "$_hi" ]]; then _swap="$_lo"; _lo="$_hi"; _hi="$_swap"; fi
        case "$_kb_kpd_allow" in
            *$'\n'"${_lo}|${_hi}"$'\n'*) return 1 ;;
        esac
        case "$_kb_kpd_seen" in
            *$'\n'"${_lo}|${_hi}"$'\n'*) return 1 ;;
        esac
        _kb_kpd_seen+="${_lo}|${_hi}"$'\n'
        printf '%s|%s|%s\n' "$from" "$to" "$why"
        return 0
    }

    # 1. Heuristic pass — every hyphen-separated component of every hyphenated
    #    directory name, tested against the roster.
    #
    # ONE finding per stray directory (XACA-0846-010): a name like
    # `thok-tuvok` hyphen-splits into two components that BOTH happen to sit
    # on the roster (`thok` and `tuvok`), so without a stopping rule this pass
    # would print two FAIL lines accusing one directory of duplicating two
    # different canonical personas — noise, since only one is the real merge
    # target. Components are tried leftmost-first (matching the existing
    # naming convention that the byline's primary name comes first, e.g. the
    # `thok-tuvok` comment above), and the loop stops at the first component
    # whose match is ACTUALLY PRINTED. A component whose match is suppressed
    # (already allow-listed, or an identical pair already seen) is not a
    # finding, so the scan continues to the next component — a stray that
    # collides with two genuinely distinct canonical directories still needs
    # its real duplicate caught, not silently swallowed by the first,
    # exempted candidate.
    local rest comp
    for d in "${_kb_kpd_dirs[@]}"; do
        case "$d" in
            *-*) ;;
            *) continue ;;
        esac
        rest="$d"
        while :; do
            comp="${rest%%-*}"
            if [[ -n "$comp" && "$comp" != "$d" ]] && _kb_kpd_has "$comp"; then
                _kb_kpd_emit "$d" "$comp" "heuristic: '${d}' looks like a display-byline slug of '${comp}'" && break
            fi
            case "$rest" in
                *-*) rest="${rest#*-}" ;;
                *) break ;;
            esac
        done
    done

    # 2. Declared-alias pass — flagged only when BOTH directories actually exist.
    #    Map order is "<display-name>|<canonical-id>", which is already the
    #    orientation _kb_kpd_emit wants (stray first, canonical second).
    local alias_name canon_name
    for p in "${_KB_KNOWLEDGE_PERSONA_DECLARED_ALIASES[@]}"; do
        alias_name="${p%%|*}"; canon_name="${p##*|}"
        if _kb_kpd_has "$alias_name" && _kb_kpd_has "$canon_name"; then
            _kb_kpd_emit "$alias_name" "$canon_name" \
                "declared alias: '${alias_name}' is a known display name for '${canon_name}'"
        fi
    done

    unset -f _kb_kpd_has _kb_kpd_emit _kb_kpd_has_entries 2>/dev/null
    return 0
}


# Validate cross-reference integrity, INDEX correctness, orphan detection
# Usage: kb-knowledge-validate [--quiet] [--fix]
#
# Checks:
#   - YAML frontmatter parses (required fields: id, tier, date, tags)
#   - id field matches filename
#   - tier matches directory location
#   - Cross-references in frontmatter (related:, promoted_to:, promoted_from:) resolve
#   - Files on disk match entries in INDEX.md (orphan detection)
#   - Subject depth <= 4 levels
#   - Filename prefix is lowercase
#   - Duplicate ID slots within one tier dir (XACA-0802)
#   - Duplicate persona directories under agents/ (XACA-0842) — FAILS, not warns
kb-knowledge-validate() {
    setopt LOCAL_OPTIONS NO_NOMATCH
    local flag_quiet=false flag_fix=false

    while [[ $# -gt 0 ]]; do
        case "${1-}" in
            --quiet|-q) flag_quiet=true; shift ;;
            --fix)      flag_fix=true;   shift ;;
            --help|-h)
                echo "Usage: kb-knowledge-validate [--quiet] [--fix]"
                echo ""
                echo "  --quiet    Show only failures"
                echo "  --fix      Auto-fix safe issues (INDEX regeneration, casing warnings)"
                return 0
                ;;
            *) echo "Unknown flag: ${1-}" >&2; shift ;;
        esac
    done

    local global_root
    global_root=$(_kb_knowledge_global_root)
    # XACA-0802: second root, parallel shape, may legitimately not exist on a
    # host that has never held PII-team knowledge. Absent => silently skipped.
    local local_root
    local_root=$(_kb_knowledge_local_root)

    local project_path
    project_path=$(_kb_knowledge_project_path)

    local error_count=0
    local warning_count=0
    local pass_count=0
    # Pre-declare loop variables at function top to avoid zsh local-A trace leaks on re-declaration
    local val_dir expected_tier cur_root dir_label exp_prefix index_file ef fname lc_fname
    local dup_slots dup_slot dup_files root_label
    local has_id has_tier has_date has_tags has_agent has_team file_id file_tier xref_line xref resolved_xref resolver_rc idx_id idx_file
    local xref_frontmatter
    local -a entry_files index_ids

    _kb_val_error()   { echo "  [FAIL] $*" >&2; error_count=$((error_count + 1)); }
    _kb_val_warn()    { echo "  [WARN] $*" >&2; warning_count=$((warning_count + 1)); }
    _kb_val_pass()    { $flag_quiet || echo "  [OK]   $*"; pass_count=$((pass_count + 1)); }

    # ── Collect search directories ──────────────────────────────────────────────
    # val_roots tracks, per collected dir, WHICH root it came from. Two reasons:
    # (1) cross-refs must resolve against their own root — a local-only entry's
    #     `teams:finance-personal:t001` lives under ~/knowledge-local, and
    #     resolving it against the global root would report a false broken ref;
    # (2) findings stay attributable to a store in the output.
    local -a val_dirs val_tiers val_roots

    # Subject dirs — walk recursively, tracking depth. Reads _kb_val_cur_root
    # (set by the collector below) so recursion doesn't need to thread the root
    # through every frame.
    local _kb_val_cur_root=""
    _kb_val_walk_subjects() {
        # Strip trailing slash from base; glob expansion of */ already appends one,
        # so "${base}/*/" with a slash-suffixed base yields "ios//swift/" on recursion.
        local base="${1%/}" depth="${2:-1}"
        local sdir
        for sdir in "${base}"/*/; do
            [[ -d "$sdir" ]] || continue
            val_dirs+=("$sdir"); val_tiers+=("subject"); val_roots+=("$_kb_val_cur_root")
            if [[ $depth -ge 4 ]]; then
                _kb_val_warn "Subject depth >= 4: ${sdir} — consider consolidating with tags"
            fi
            _kb_val_walk_subjects "$sdir" $((depth + 1))
        done
    }

    # XACA-0802: one collector, applied to each root. Both roots have the SAME
    # four-tier shape (agents/ teams/ subjects/ projects/), so the global and
    # local stores get identical treatment — no second, drift-prone code path.
    _kb_val_collect_root() {
        local root="${1%/}"
        # Absent root is not an error: a host with no PII-team knowledge simply
        # has no ~/knowledge-local. Skip silently.
        [[ -d "$root" ]] || return 0
        _kb_val_cur_root="$root"

        local cdir
        for cdir in "${root}/agents"/*/; do
            [[ -d "$cdir" ]] || continue
            val_dirs+=("$cdir"); val_tiers+=("agent"); val_roots+=("$root")
        done
        for cdir in "${root}/teams"/*/; do
            [[ -d "$cdir" ]] || continue
            val_dirs+=("$cdir"); val_tiers+=("team"); val_roots+=("$root")
        done
        _kb_val_walk_subjects "${root}/subjects"
        # XACA-0532: scan ALL projects/*/ (mirrors agents/teams/subjects)
        for cdir in "${root}/projects"/*/; do
            [[ -d "$cdir" ]] || continue
            val_dirs+=("$cdir"); val_tiers+=("project"); val_roots+=("$root")
        done
    }

    _kb_val_collect_root "$global_root"
    # Skip the local pass when the two roots resolve to the same path (possible
    # if someone points KB_KNOWLEDGE_LOCAL_ROOT at the global root) — otherwise
    # every entry would be validated, and counted, twice.
    if [[ "${local_root%/}" != "${global_root%/}" ]]; then
        _kb_val_collect_root "$local_root"
    fi

    # Also include the resolved project_path ONLY if it lives outside BOTH roots
    # (in-repo layout: .knowledge-config.yml / KB_KNOWLEDGE_PROJECT_PATH pointing
    # elsewhere). Skip if already covered by a glob above to avoid double-validating.
    if [[ -d "$project_path" \
       && "$project_path" != "${global_root}/projects/"* \
       && "$project_path" != "${local_root}/projects/"* ]]; then
        val_dirs+=("$project_path"); val_tiers+=("project"); val_roots+=("$global_root")
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "  KNOWLEDGE VALIDATE"
    echo "  Global root: ${global_root}"
    if [[ "${local_root%/}" == "${global_root%/}" ]]; then
        echo "  Local root:  ${local_root}  (same as global root — validated once)"
    elif [[ -d "$local_root" ]]; then
        echo "  Local root:  ${local_root}  (unsynced / PII — XACA-0754)"
    else
        echo "  Local root:  ${local_root}  (absent — skipped)"
    fi
    echo "  Projects:    ${global_root}/projects/*  (resolved context: ${project_path})"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""

    # XACA-0265: array base differs by shell — zsh defaults to 1-indexed, bash
    # (and zsh under KSH_ARRAYS) is 0-indexed. Probe at runtime so the parallel
    # `val_tiers` lookup tracks `val_dirs` regardless of shell.
    local _kb_idx_base=0
    local _kb_probe=("first")
    [[ "${_kb_probe[1]:-}" == "first" ]] && _kb_idx_base=1
    local dir_idx=$_kb_idx_base

    for val_dir in "${val_dirs[@]}"; do
        expected_tier="${val_tiers[$dir_idx]}"
        cur_root="${val_roots[$dir_idx]}"
        dir_idx=$((dir_idx + 1))

        [[ -d "$val_dir" ]] || continue

        # XACA-0802: tag every directory line with its store so a user can tell
        # at a glance which root a finding came from. A bare ~/-relative label
        # is not enough — KB_KNOWLEDGE_LOCAL_ROOT may point anywhere (tests do).
        if [[ "${cur_root%/}" == "${local_root%/}" && "${local_root%/}" != "${global_root%/}" ]]; then
            root_label="local"
        else
            root_label="global"
        fi
        # Only re-add the ~/ shorthand when the strip actually fired — a root
        # pointed outside $HOME (sandboxed tests) otherwise renders as "~//tmp/…".
        dir_label="${val_dir#${HOME}/}"
        [[ "$dir_label" != "$val_dir" ]] && dir_label="~/${dir_label}"
        $flag_quiet || echo "  Directory: [${root_label}] ${dir_label}"

        # Determine expected prefix for this tier
        case "$expected_tier" in
            agent)   exp_prefix="k" ;;
            team)    exp_prefix="t" ;;
            subject) exp_prefix="s" ;;
            project) exp_prefix="p" ;;
            *)       exp_prefix="" ;;
        esac

        # Collect entry files (not INDEX.md, not retrospectives/)
        entry_files=()
        index_ids=()
        for ef in "${val_dir}"/*.md; do
            [[ -f "$ef" ]] || continue
            [[ "$(basename "$ef")" == "INDEX.md" ]] && continue
            entry_files+=("$ef")
        done

        # ── Duplicate ID-slot check (XACA-0802) ────────────────────────────────
        # kb-knowledge-add allocates the next entry ID by scanning the TARGET
        # dir for the highest <prefix>NNN. That scan is per-host, and the local
        # root never syncs (XACA-0754), so two machines independently handed out
        # the same slot in the same team dir — four entries, two colliding IDs,
        # zero warnings (XACA-0795). Two files claiming one slot means one of
        # them will be silently clobbered by any merge or migration, so this is
        # an ERROR, not a warning. Applies to both roots.
        if [[ ${#entry_files[@]} -gt 0 ]]; then
            dup_slots=$(for ef in "${entry_files[@]}"; do
                             basename "$ef" .md | sed -n 's/^\([a-zA-Z][0-9][0-9]*\)-.*$/\1/p'
                         done | sort | uniq -d)
            if [[ -n "$dup_slots" ]]; then
                while IFS= read -r dup_slot; do
                    [[ -n "$dup_slot" ]] || continue
                    dup_files=$(for ef in "${entry_files[@]}"; do
                                    fname=$(basename "$ef" .md)
                                    case "$fname" in
                                        "${dup_slot}"-*) printf '%s.md ' "$fname" ;;
                                    esac
                                done)
                    _kb_val_error "Duplicate ID slot '${dup_slot}' in ${val_dir} — files: ${dup_files% }"
                done <<< "$dup_slots"
            fi
        fi

        # Check INDEX.md
        index_file="${val_dir}/INDEX.md"
        if [[ ! -f "$index_file" ]]; then
            _kb_val_warn "No INDEX.md in ${val_dir}"
            if $flag_fix; then
                kb-knowledge-reindex --dir "$val_dir" 2>/dev/null
                echo "    Auto-fixed: regenerated INDEX.md"
            fi
        else
            # Collect IDs mentioned in INDEX.md
            while IFS= read -r line; do
                if echo "$line" | grep -qE '`([ktspmv][0-9]+-[^`]+)`'; then
                    idx_id=$(echo "$line" | grep -oE '`[ktspmv][0-9]+-[^`]+`' | tr -d '`' | head -1)
                    [[ -n "$idx_id" ]] && index_ids+=("$idx_id")
                fi
            done < "$index_file"
        fi

        # Validate each entry file
        for ef in "${entry_files[@]}"; do
            fname=$(basename "$ef" .md)

            # Casing check
            if echo "$fname" | grep -qE '^[KTSPMV]'; then
                _kb_val_warn "Uppercase prefix in ${ef}"
                if $flag_fix; then
                    lc_fname=$(echo "$fname" | tr '[:upper:]' '[:lower:]')
                    mv "$ef" "${val_dir}/${lc_fname}.md" 2>/dev/null && \
                        echo "    Auto-fixed: renamed to ${lc_fname}.md"
                fi
            fi

            # Prefix check
            if [[ -n "$exp_prefix" ]]; then
                if ! echo "$fname" | grep -qE "^${exp_prefix}[0-9]+"; then
                    _kb_val_warn "File ${fname}.md does not start with expected prefix '${exp_prefix}' for tier '${expected_tier}'"
                fi
            fi

            # Required frontmatter fields
            has_id=$(grep -c '^id:' "$ef" 2>/dev/null || true)
            has_tier=$(grep -c '^tier:' "$ef" 2>/dev/null || true)
            has_date=$(grep -c '^date:' "$ef" 2>/dev/null || true)
            has_tags=$(grep -c '^tags:' "$ef" 2>/dev/null || true)

            [[ "$has_id" -eq 0 ]]   && _kb_val_error "Missing 'id:' in ${ef}"
            [[ "$has_tier" -eq 0 ]] && _kb_val_error "Missing 'tier:' in ${ef}"
            [[ "$has_date" -eq 0 ]] && _kb_val_error "Missing 'date:' in ${ef}"
            [[ "$has_tags" -eq 0 ]] && _kb_val_error "Missing 'tags:' in ${ef}"

            # Tier-specific required fields (per SPEC.md §3)
            if [[ "$expected_tier" == "agent" ]]; then
                has_agent=$(grep -c '^agent:' "$ef" 2>/dev/null || true)
                [[ "$has_agent" -eq 0 ]] && _kb_val_error "Missing 'agent:' in ${ef} (required for tier 'agent')"
            fi
            if [[ "$expected_tier" == "team" ]]; then
                has_team=$(grep -c '^team:' "$ef" 2>/dev/null || true)
                [[ "$has_team" -eq 0 ]] && _kb_val_error "Missing 'team:' in ${ef} (required for tier 'team')"
            fi

            # id field matches filename
            if [[ "$has_id" -gt 0 ]]; then
                file_id=$(_kb_knowledge_yaml_field "$ef" "id")
                # id may be "kNNN-slug" and fname is same — strip .md
                if [[ "$file_id" != "$fname" ]]; then
                    _kb_val_error "id mismatch: file='${fname}', id field='${file_id}' in ${ef}"
                fi
            fi

            # tier matches directory
            if [[ "$has_tier" -gt 0 ]]; then
                file_tier=$(_kb_knowledge_yaml_field "$ef" "tier")
                if [[ "$file_tier" != "$expected_tier" ]]; then
                    _kb_val_error "Tier mismatch: file in '${expected_tier}' dir but tier='${file_tier}' in ${ef}"
                fi
            fi

            # Validate cross-references — scan YAML frontmatter only (between the two ^---$ lines).
            # Scanning the full file body causes false positives when cross-ref tokens appear in
            # code samples, prose discussions, or quoted text (see XACA-0222 review subitem 014).
            xref_frontmatter=$(awk '/^---$/{if(found){exit}; found=1; next} found{print}' "$ef" 2>/dev/null | head -50)
            while IFS= read -r xref_line; do
                # Extract bare cross-refs (tokens like agents:*, subjects:*, project:*, teams:*)
                while read -r xref; do
                    # XACA-0802: resolve against the entry's OWN root — a
                    # local-only entry's refs point at siblings under
                    # ~/knowledge-local, and resolving those against the global
                    # root would report every one of them as broken.
                    resolved_xref=$(_kb_knowledge_resolve_ref "$xref" "$cur_root" 2>/dev/null)
                    resolver_rc=$?
                    if [[ $resolver_rc -ne 0 ]]; then
                        _kb_val_error "Broken cross-ref '${xref}' in ${ef} (resolver rejected — invalid format)"
                    elif [[ -n "$resolved_xref" ]] && [[ ! -f "$resolved_xref" ]]; then
                        _kb_val_error "Broken cross-ref '${xref}' in ${ef}"
                    fi
                done < <(echo "$xref_line" | grep -oE '(agents|teams|subjects|project):[a-z0-9/:_-]+')
            done <<< "$xref_frontmatter"

            _kb_val_pass "$(basename "$ef")"
        done

        # Orphan check: files in INDEX but not on disk (D3: idx_id already contains .md suffix)
        for idx_id in "${index_ids[@]}"; do
            idx_file="${val_dir}/${idx_id%.md}.md"
            if [[ ! -f "$idx_file" ]]; then
                _kb_val_warn "INDEX.md lists '${idx_id}' but file not found: ${idx_file}"
            fi
        done

        echo ""
    done

    # ── Duplicate persona-directory check (XACA-0842) ───────────────────────────
    # Runs ONCE per root over agents/ as a whole (not per-directory) — the check
    # is about RELATIONSHIPS BETWEEN sibling directories, so it needs the full
    # roster, which the per-directory loop above never has.
    #
    # These are _kb_val_error (hard failure, non-zero exit), never _kb_val_warn.
    # See _kb_knowledge_persona_dup_pairs for the detection rationale and the
    # allow-list of genuinely-distinct look-alike pairs.
    local -a dup_roots
    dup_roots=("$global_root")
    if [[ "${local_root%/}" != "${global_root%/}" ]]; then
        dup_roots+=("$local_root")
    fi

    # dup_stray / dup_canon are ORIENTED by the detector: stray first, believed
    # canonical second. Keep that order when rendering the merge command.
    local dup_root dup_stray dup_canon dup_why dup_root_label
    for dup_root in "${dup_roots[@]}"; do
        [[ -d "${dup_root}/agents" ]] || continue
        if [[ "${dup_root%/}" == "${local_root%/}" && "${local_root%/}" != "${global_root%/}" ]]; then
            dup_root_label="local"
        else
            dup_root_label="global"
        fi
        while IFS='|' read -r dup_stray dup_canon dup_why; do
            [[ -n "$dup_stray" && -n "$dup_canon" ]] || continue
            _kb_val_error "Duplicate persona directories [${dup_root_label}]: '${dup_root}/agents/${dup_stray}' and '${dup_root}/agents/${dup_canon}'
           Why flagged: ${dup_why}
           Impact: kb-knowledge-search resolves the canonical agent id only, so
                   every entry in the non-canonical directory is STRANDED.
           Fix (pick one):
             1. Consolidate — fold the stray into the canonical agent id
                (direction below is this check's best guess — confirm it first):
                  kb-knowledge-merge ${dup_stray} ${dup_canon}
                That COPIES — it deliberately leaves the source entries in place,
                so this check keeps firing until you also RETIRE the source.
                Retire it by removing the k*.md entries and the now-stale
                INDEX.md from '${dup_stray}' (git rm, so the content stays
                recoverable), keeping ONLY a README.md pointer naming
                '${dup_canon}'. Do not delete the directory itself — the pointer
                is what lets historical references still resolve, and an
                entry-free directory is skipped by this check.
                (then run: kb-knowledge-reindex && kb-knowledge-validate)
             2. Exempt — if '${dup_stray}' and '${dup_canon}' are genuinely DIFFERENT
                personas, they need a \"${dup_stray}|${dup_canon}\" entry in the
                allow-list constant _KB_KNOWLEDGE_PERSONA_DISTINCT_PAIRS, which is
                defined inside _kb_knowledge_persona_dup_pairs. That allow-list
                ships as part of the installed helpers, so an edit to your local
                copy is reverted by the next upgrade — the exemption only sticks
                if it lands in the AITeamForge source. If you maintain that
                source, change it there and re-sync; otherwise report the pair
                upstream and leave both directories in place meanwhile. Either
                way the entry MUST carry a justification naming the two persona
                definitions that prove the ids are distinct — an entry without
                one is not acceptable."
        done < <(_kb_knowledge_persona_dup_pairs "${dup_root}/agents")
    done

    # ── Summary ─────────────────────────────────────────────────────────────────
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "  RESULTS: ${pass_count} passed  |  ${warning_count} warnings  |  ${error_count} errors"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""

    [[ "$error_count" -eq 0 ]]
}

# Regenerate INDEX.md for one or all knowledge tier directories
# Usage: kb-knowledge-reindex [--dir <path>]
#
# If --dir is given: regenerate that one INDEX.md.
# If no flag: regenerate ALL INDEXes under ~/knowledge/ (agents, teams, subjects, project).
kb-knowledge-reindex() {
    setopt LOCAL_OPTIONS NO_NOMATCH
    local target_dir=""

    while [[ $# -gt 0 ]]; do
        case "${1-}" in
            --dir)
                target_dir="${2-}"; shift 2 ;;
            --help|-h)
                echo "Usage: kb-knowledge-reindex [--dir <path>]"
                echo ""
                echo "  --dir <path>   Regenerate only this directory's INDEX.md"
                echo "  (no flags)     Regenerate ALL INDEXes under KB_KNOWLEDGE_GLOBAL_ROOT"
                return 0
                ;;
            *)
                echo "Unknown flag: ${1-}" >&2; shift ;;
        esac
    done

    local global_root
    global_root=$(_kb_knowledge_global_root)
    local local_root
    local_root=$(_kb_knowledge_local_root)

    # XACA-0754-013 (ported XACA-0770): effective resolver so the "reindex
    # the current project if it lives outside the glob-walked roots" check
    # below also honours a local-redirected bare-project path, not just the
    # raw in-repo/env-var cases.
    local project_path
    project_path=$(_kb_knowledge_project_path_effective)

    if [[ -n "$target_dir" ]]; then
        target_dir="${target_dir/#\~/$HOME}"
        if [[ ! -d "$target_dir" ]]; then
            echo "Error: directory not found: ${target_dir}" >&2
            return 1
        fi
        _kb_knowledge_reindex_one "$target_dir"
        return $?
    fi

    # Rebuild all: collect all tier directories
    local rebuilt=0 skipped=0
    local rdir

    # Agent dirs
    for rdir in "${global_root}/agents"/*/; do
        [[ -d "$rdir" ]] || continue
        _kb_knowledge_reindex_one "$rdir" && rebuilt=$((rebuilt + 1)) || skipped=$((skipped + 1))
    done

    # Team dirs
    for rdir in "${global_root}/teams"/*/; do
        [[ -d "$rdir" ]] || continue
        _kb_knowledge_reindex_one "$rdir" && rebuilt=$((rebuilt + 1)) || skipped=$((skipped + 1))
    done

    # XACA-0754/XACA-0754-013 (ported XACA-0770): local root's agent/team
    # dirs (PII, unsynced — same shape as global root, just a different base
    # path).
    for rdir in "${local_root}/agents"/*/; do
        [[ -d "$rdir" ]] || continue
        _kb_knowledge_reindex_one "$rdir" && rebuilt=$((rebuilt + 1)) || skipped=$((skipped + 1))
    done
    for rdir in "${local_root}/teams"/*/; do
        [[ -d "$rdir" ]] || continue
        _kb_knowledge_reindex_one "$rdir" && rebuilt=$((rebuilt + 1)) || skipped=$((skipped + 1))
    done

    # Subject dirs (recursive)
    _kb_reindex_subjects() {
        local base="${1-}"
        local sdir
        for sdir in "${base}"/*/; do
            [[ -d "$sdir" ]] || continue
            _kb_knowledge_reindex_one "$sdir" && rebuilt=$((rebuilt + 1)) || skipped=$((skipped + 1))
            _kb_reindex_subjects "$sdir"
        done
    }
    _kb_reindex_subjects "${global_root}/subjects"
    _kb_reindex_subjects "${local_root}/subjects"

    # Project dirs — XACA-0532: scan ALL projects/*/ under global root (mirrors agents/teams/subjects)
    local pdir
    for pdir in "${global_root}/projects"/*/; do
        [[ -d "$pdir" ]] || continue
        _kb_knowledge_reindex_one "$pdir" && rebuilt=$((rebuilt + 1)) || skipped=$((skipped + 1))
    done
    # XACA-0754-013 (ported XACA-0770): same glob-walk under local_root/projects
    # (a local-only session's named-project or local-redirected bare-project entries).
    for pdir in "${local_root}/projects"/*/; do
        [[ -d "$pdir" ]] || continue
        _kb_knowledge_reindex_one "$pdir" && rebuilt=$((rebuilt + 1)) || skipped=$((skipped + 1))
    done
    # Also reindex the resolved project_path ONLY if it lives outside BOTH
    # glob-walked roots above (in-repo layout: .knowledge-config.yml /
    # KB_KNOWLEDGE_PROJECT_PATH pointing elsewhere). Skip if already covered
    # by either glob to avoid double-reindexing.
    if [[ -d "$project_path" ]] \
        && [[ "$project_path" != "${global_root}/projects/"* ]] \
        && [[ "$project_path" != "${local_root}/projects/"* ]]; then
        _kb_knowledge_reindex_one "$project_path" && rebuilt=$((rebuilt + 1)) || skipped=$((skipped + 1))
    fi

    echo ""
    echo "  INDEX.md regeneration complete: ${rebuilt} rebuilt, ${skipped} skipped."
    echo ""
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
    echo "Reporting / Analytics:"
    echo "  kb-variance [--json]            Estimate-vs-actual handicap report"
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
