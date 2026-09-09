#!/usr/bin/env bash

# iTerm2 Badge Helper for Claude Code
#
# Functions provided:
#   iterm2_set_user_var     — low-level: fire OSC 1337 SetUserVar (tmux-aware)
#   set_claude_badge        — set the claude_badge user-var to the agent name
#   clear_claude_badge      — clear the claude_badge user-var
#   set_claude_active       — increment per-tab refcount; prepend "C " to the tab title
#                             when count goes 0→1 (via iTerm2 Python API)
#   clear_claude_active     — decrement per-tab refcount; strip "C " from the tab title
#                             when count hits 0 (via iTerm2 Python API)
#   _iterm_tab_id           — resolve the current iTerm2 tab identity (ITERM_SESSION_ID or TTY)
#   _iterm_refcount_file    — resolve the path to this tab's refcount file
#   _fire_claude_tab_prefix — internal: call scripts/iterm2_tab_title_prefix.py
#
# Design note (XACA-0214 round 2):
# The original design used OSC 1337 SetUserVar=claude_active combined with a
# Dynamic Profile `Custom Tab Title: \(user.claude_active)\(session.name)` format
# string. iTerm2 only renders the format when no tab title override is set, and
# academy-startup.sh sets every tab's title via `\033]0;<label>\007`, creating an
# override that bypasses the format. Switched to writing `tab.titleOverride`
# directly via iTerm2's Python API, which co-exists with academy's existing
# per-tab label scheme.

# ---------------------------------------------------------------------------
# Refcount directory (created lazily)
# ---------------------------------------------------------------------------
ITERM_REFCOUNT_DIR="${HOME}/.claude/.iterm_tab_refcount"

# ---------------------------------------------------------------------------
# Resolve the iTerm2 tab-title helper and the Python interpreter that can run
# it. Prefer the dev-team venv (has the `iterm2` PyPI package); fall back to
# system python3 if the venv is missing. Both paths are silent no-ops if
# unresolvable — this helper is best-effort UI decoration.
# ---------------------------------------------------------------------------
_fire_claude_tab_prefix() {
    local action="$1"   # --activate or --deactivate
    # Resolve the helper relative to this file's location, so the call works
    # whether sourced from ~/dev-team, a worktree, or any other checkout.
    local helper_dir
    helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || return 0
    local helper="$helper_dir/scripts/iterm2_tab_title_prefix.py"
    [ -f "$helper" ] || return 0

    local python_bin=""
    if [ -x "$helper_dir/.venv/bin/python3" ]; then
        python_bin="$helper_dir/.venv/bin/python3"
    elif command -v python3 >/dev/null 2>&1; then
        python_bin="$(command -v python3)"
    else
        return 0
    fi

    "$python_bin" "$helper" "$action" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Low-level: fire OSC 1337 SetUserVar (works with tmux DCS passthrough)
# ---------------------------------------------------------------------------
iterm2_set_user_var() {
    local name="$1"
    local value="$2"
    # base64 produces a trailing newline on macOS; strip it so the encoded value
    # is clean when embedded in the escape sequence.
    local encoded
    encoded=$(printf '%s' "$value" | base64 | tr -d '\n')

    if [ -n "${TMUX:-}" ]; then
        # In tmux: wrap with DCS passthrough so tmux forwards the inner OSC 1337
        # to the enclosing terminal (iTerm2). The doubled \033 before ]1337 is
        # required by the tmux DCS passthrough specification.
        printf "\033Ptmux;\033\033]1337;SetUserVar=%s=%s\007\033\\" "$name" "$encoded"
    else
        # Direct iTerm2 (no tmux): standard OSC 1337
        printf "\033]1337;SetUserVar=%s=%s\007" "$name" "$encoded"
    fi
}

# ---------------------------------------------------------------------------
# Badge helpers (existing — unchanged)
# ---------------------------------------------------------------------------

# Set Claude Code badge to the given agent name.
set_claude_badge() {
    local agent="${1:-general-purpose}"
    iterm2_set_user_var claude_badge "🤖 $agent"
}

# Clear the claude_badge user-var.
clear_claude_badge() {
    iterm2_set_user_var claude_badge ""
}

# ---------------------------------------------------------------------------
# Tab-identity helpers
# ---------------------------------------------------------------------------

# _iterm_tab_id — echo a stable identifier for the current iTerm2 tab.
#
# Preference order:
#   1. tmux client_tty (when TMUX and TMUX_PANE are set) — each iTerm2 pane
#      hosting a `tmux attach` has its own client_tty, stable for the life
#      of that attach. Required inside the academy fleet because
#      ITERM_SESSION_ID is STALE in tmux panes: the tmux server was spawned
#      from the Startup tab, so every pane it hosts inherits Startup's ID,
#      causing all Claude Code hooks in all tabs to target the wrong tab.
#   2. $ITERM_SESSION_ID (UUID set by iTerm2; correct when not in tmux)
#   3. $TTY (fallback for non-iTerm2 environments)
#   4. $(tty) (last resort)
#   5. "unknown" (no tty context at all)
#
# Returns 0 always; callers must check for "unknown" and no-op if desired.
_iterm_tab_id() {
    if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
        local client_tty
        client_tty=$(tmux display-message -p -t "$TMUX_PANE" '#{client_tty}' 2>/dev/null || true)
        if [ -n "$client_tty" ]; then
            printf '%s' "$client_tty"
            return 0
        fi
    fi

    if [ -n "${ITERM_SESSION_ID:-}" ]; then
        printf '%s' "$ITERM_SESSION_ID"
        return 0
    fi

    local tty_val="${TTY:-}"
    if [ -z "$tty_val" ]; then
        tty_val=$(tty 2>/dev/null || true)
    fi

    if [ -n "$tty_val" ] && [ "$tty_val" != "not a tty" ]; then
        printf '%s' "$tty_val"
        return 0
    fi

    printf 'unknown'
    return 0
}

# _iterm_refcount_file [tab_id] — echo the full path to the refcount file for this tab.
#
# Optional $1: explicit tab_id (skips _iterm_tab_id resolver). When omitted,
# resolves via _iterm_tab_id as before. The tab id is sanitized: forward
# slashes (which appear in TTY paths like /dev/ttys001) are replaced with
# underscores so the id is safe as a filename.
_iterm_refcount_file() {
    local tab_id
    if [ -n "${1:-}" ]; then
        tab_id="$1"
    else
        tab_id=$(_iterm_tab_id)
    fi
    # Replace / with _ to make TTY paths safe as filenames.
    local safe_id
    safe_id=$(printf '%s' "$tab_id" | tr '/' '_')
    printf '%s/%s' "$ITERM_REFCOUNT_DIR" "$safe_id"
}

# ---------------------------------------------------------------------------
# Concurrency: flock-or-spin helpers
#
# macOS ships with bash 3.x and does NOT include the Linux `flock` utility.
# We check for flock at runtime and use it when present; otherwise fall back
# to a mkdir-based spin-lock (atomic on POSIX filesystems).
#
# Spin-lock protocol:
#   Lock dir: <refcount-file>.lock
#   Acquire:  mkdir <lock-dir>  — succeeds only if dir doesn't exist (atomic)
#   Release:  rmdir <lock-dir>
#   Timeout:  50 ms poll, 2-second max wait before giving up and proceeding.
# ---------------------------------------------------------------------------

# _acquire_lock <lock_dir>
# Returns 0 on success (lock acquired), 1 on timeout (caller proceeds unlocked).
# Uses atomic mkdir — only one caller wins the race on POSIX filesystems.
_acquire_lock() {
    local lock_dir="$1"
    local attempts=0
    local max_attempts=40  # 40 × 50 ms = 2 seconds

    while [ "$attempts" -lt "$max_attempts" ]; do
        if mkdir "$lock_dir" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
        attempts=$((attempts + 1))
    done
    # Timed out — log to stderr only in debug mode; proceed unlocked.
    if [ "${CLAUDE_ACTIVE_DEBUG:-0}" = "1" ]; then
        printf '[iterm2_badge_helper] WARNING: lock timeout on %s; proceeding unlocked\n' \
               "$lock_dir" >&2
    fi
    return 1
}

# _release_lock <lock_dir>
_release_lock() {
    local lock_dir="$1"
    rmdir "$lock_dir" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# claude_active: set (increment refcount)
# ---------------------------------------------------------------------------

# set_claude_active [tab_id] — increment the per-tab refcount.
# Optional $1: explicit tab_id; when omitted, resolved via _iterm_tab_id.
# When the count transitions from 0 to 1:
#   - fires _fire_claude_tab_prefix --activate, which mutates titleOverride
#     directly via the LOCAL iTerm2 Python API (XACA-0214 round 2/3). This is
#     the mechanism for a Claude session running on the SAME machine as the
#     iTerm2 it must update; it is a silent no-op on a remote/headless box
#     with no local iTerm2 to call into.
#   - (XACA-1144) ALSO fires iterm2_set_user_var claude_active "1" — the same
#     OSC 1337 transport already used for claude_badge above, now reused to
#     carry the active/idle signal across ssh+tmux (via tmux DCS passthrough)
#     to a REMOTE team's viewing terminal. A window-scoped local watcher
#     (scripts/iterm2_claude_active_watch.py, started by <team>-connect.sh)
#     subscribes to this var on the viewing side and mutates that tab's
#     titleOverride there. Harmless on a local (non-remote) session: nothing
#     currently reads user.claude_active locally (the Dynamic Profile
#     format-string route that would have read it was rejected — see
#     DESIGN-DECISION-005.md R2), so this just sets an unused var.
# Safe to call from Claude Code hooks; never crashes the caller.
set_claude_active() {
    (
        # Resolve tab_id: use explicit arg if provided, else call resolver.
        local tab_id
        if [ -n "${1:-}" ]; then
            tab_id="$1"
            if [ "${CLAUDE_ACTIVE_DEBUG:-0}" = "1" ]; then
                printf '[iterm2_badge_helper] set_claude_active: tab_id from arg: %s\n' "$tab_id" >&2
            fi
        else
            tab_id=$(_iterm_tab_id)
            if [ "${CLAUDE_ACTIVE_DEBUG:-0}" = "1" ]; then
                printf '[iterm2_badge_helper] set_claude_active: tab_id from resolver: %s\n' "$tab_id" >&2
            fi
        fi
        # No-op if we cannot determine tab context.
        if [ "$tab_id" = "unknown" ]; then
            if [ "${CLAUDE_ACTIVE_DEBUG:-0}" = "1" ]; then
                printf '[iterm2_badge_helper] set_claude_active: no tab context, skipping\n' >&2
            fi
            return 0
        fi

        mkdir -p "$ITERM_REFCOUNT_DIR"
        local refcount_file
        refcount_file=$(_iterm_refcount_file "$tab_id")
        local lock_dir="${refcount_file}.lock"

        # Acquire lock (flock preferred; spin-lock fallback).
        local lock_fd=""
        if command -v flock >/dev/null 2>&1; then
            # flock is available — use it on the refcount file itself.
            # Open in APPEND mode (>>) so the file is not truncated before we
            # read the current count. flock works on the fd regardless of mode.
            # shellcheck disable=SC2094
            # SC2094: flock does not read/write the file descriptor here.
            exec 9>>"$refcount_file"
            flock 9
            lock_fd="9"
        else
            _acquire_lock "$lock_dir"
        fi

        # Read current count (default 0 if file absent or unreadable).
        local count=0
        if [ -f "$refcount_file" ]; then
            count=$(cat "$refcount_file" 2>/dev/null || echo "0")
            # Strip whitespace/newlines; default to 0 if non-numeric.
            count=$(printf '%s' "$count" | tr -d '[:space:]')
            case "$count" in
                ''|*[!0-9]*) count=0 ;;
            esac
        fi

        # Prepend "C " to the tab title when transitioning from 0 to active.
        if [ "$count" -eq 0 ]; then
            _fire_claude_tab_prefix --activate
            # XACA-1144: also fire the transport-level OSC so a remote
            # viewing terminal's window-scoped watcher can mirror this
            # transition. Writes to this function's stdout — the caller
            # (kanban-session-start.py) redirects that to the pane's tty so
            # the escape reaches the terminal instead of being captured.
            iterm2_set_user_var claude_active "1"
        fi

        local new_count=$((count + 1))

        # Write new count atomically (write to .tmp, then mv).
        printf '%s\n' "$new_count" > "${refcount_file}.tmp"
        mv "${refcount_file}.tmp" "$refcount_file"

        # Release lock.
        if [ -n "$lock_fd" ]; then
            exec 9>&-
        else
            _release_lock "$lock_dir"
        fi
    ) || true
}

# ---------------------------------------------------------------------------
# claude_active: clear (decrement refcount)
# ---------------------------------------------------------------------------

# clear_claude_active [tab_id] — decrement the per-tab refcount.
# Optional $1: explicit tab_id; when omitted, resolved via _iterm_tab_id.
# When the count reaches (or is already) 0:
#   - fires _fire_claude_tab_prefix --deactivate (LOCAL iTerm2 Python API,
#     see set_claude_active's comment above for why this is a no-op remotely)
#   - (XACA-1144) ALSO fires iterm2_set_user_var claude_active "0" over the
#     same OSC 1337 transport, for the window-scoped remote-team watcher
#     (scripts/iterm2_claude_active_watch.py) to pick up.
# and deletes the refcount file. Never lets count go below 0.
# Safe to call from Claude Code hooks; never crashes the caller.
clear_claude_active() {
    (
        # Resolve tab_id: use explicit arg if provided, else call resolver.
        local tab_id
        if [ -n "${1:-}" ]; then
            tab_id="$1"
            if [ "${CLAUDE_ACTIVE_DEBUG:-0}" = "1" ]; then
                printf '[iterm2_badge_helper] clear_claude_active: tab_id from arg: %s\n' "$tab_id" >&2
            fi
        else
            tab_id=$(_iterm_tab_id)
            if [ "${CLAUDE_ACTIVE_DEBUG:-0}" = "1" ]; then
                printf '[iterm2_badge_helper] clear_claude_active: tab_id from resolver: %s\n' "$tab_id" >&2
            fi
        fi
        # No-op if we cannot determine tab context.
        if [ "$tab_id" = "unknown" ]; then
            if [ "${CLAUDE_ACTIVE_DEBUG:-0}" = "1" ]; then
                printf '[iterm2_badge_helper] clear_claude_active: no tab context, skipping\n' >&2
            fi
            return 0
        fi

        local refcount_file
        refcount_file=$(_iterm_refcount_file "$tab_id")
        local lock_dir="${refcount_file}.lock"

        # If file doesn't exist, refcount is already 0 — ensure the tab prefix is clear.
        if [ ! -f "$refcount_file" ]; then
            _fire_claude_tab_prefix --deactivate
            iterm2_set_user_var claude_active "0"
            return 0
        fi

        mkdir -p "$ITERM_REFCOUNT_DIR"

        # Acquire lock.
        local lock_fd=""
        if command -v flock >/dev/null 2>&1; then
            # APPEND mode (>>) — truncate mode (>) would zero the file before
            # we read, making every invocation see count=0.
            # shellcheck disable=SC2094
            exec 9>>"$refcount_file"
            flock 9
            lock_fd="9"
        else
            _acquire_lock "$lock_dir"
        fi

        # Read current count.
        local count=0
        if [ -f "$refcount_file" ]; then
            count=$(cat "$refcount_file" 2>/dev/null || echo "0")
            count=$(printf '%s' "$count" | tr -d '[:space:]')
            case "$count" in
                ''|*[!0-9]*) count=0 ;;
            esac
        fi

        # Decrement, clamped to 0.
        local new_count=$((count - 1))
        if [ "$new_count" -lt 0 ]; then
            new_count=0
        fi

        if [ "$new_count" -eq 0 ]; then
            # Last session gone — strip the "C " prefix and remove the state file.
            _fire_claude_tab_prefix --deactivate
            iterm2_set_user_var claude_active "0"
            # Release lock before removing the file to avoid orphaned locks.
            if [ -n "$lock_fd" ]; then
                exec 9>&-
                lock_fd=""
            else
                _release_lock "$lock_dir"
            fi
            rm -f "$refcount_file"
        else
            # Still sessions active — write decremented count.
            printf '%s\n' "$new_count" > "${refcount_file}.tmp"
            mv "${refcount_file}.tmp" "$refcount_file"
            if [ -n "$lock_fd" ]; then
                exec 9>&-
            else
                _release_lock "$lock_dir"
            fi
        fi
    ) || true
}

# ---------------------------------------------------------------------------
# Export functions
#
# Bash-only. In zsh, `export -f NAME` is equivalent to `typeset -gxf NAME`,
# which PRINTS the function body to stdout — so sourcing this helper from an
# interactive zsh (as claude_code_cc_aliases.sh does after `claude` exits)
# dumped all ten function definitions to the user's terminal on every CC
# exit. Guard with BASH_VERSION so zsh skips the block. The functions are
# still defined (definitions run earlier); we only lose function export to
# child processes, which zsh doesn't honor in bash's format anyway.
# ---------------------------------------------------------------------------
if [ -n "${BASH_VERSION:-}" ]; then
    export -f iterm2_set_user_var
    export -f set_claude_badge
    export -f clear_claude_badge
    export -f set_claude_active
    export -f clear_claude_active
    export -f _iterm_tab_id
    export -f _iterm_refcount_file
    export -f _acquire_lock
    export -f _release_lock
    export -f _fire_claude_tab_prefix
fi

# ---------------------------------------------------------------------------
# Default behaviour when sourced (not invoked with test-refcount)
# ---------------------------------------------------------------------------
if [ "${1:-}" != "test-refcount" ] && [ "$#" -gt 0 ]; then
    set_claude_badge "$@"
fi

# ---------------------------------------------------------------------------
# Self-test block — invoke as: ./iterm2_badge_helper.sh test-refcount
#
# Exercises set_claude_active / clear_claude_active refcount semantics.
# Does NOT require iTerm2 or tmux to be running — fires are no-ops without a
# real terminal but the state-file logic is fully exercised.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "test-refcount" ]; then
    # Use a temporary directory so we don't pollute real refcount state.
    TEST_DIR=$(mktemp -d)
    # shellcheck disable=SC2064
    # SC2064: we want $TEST_DIR expanded now so cleanup uses the current value.
    trap "rm -rf '$TEST_DIR'" EXIT

    # Override the refcount dir and force a known tab id. We unset TMUX/
    # TMUX_PANE so _iterm_tab_id falls through to ITERM_SESSION_ID — otherwise
    # (when run inside tmux) it would resolve to the real client_tty and the
    # test file name would vary at runtime.
    ITERM_REFCOUNT_DIR="$TEST_DIR"
    unset TMUX
    unset TMUX_PANE
    export ITERM_SESSION_ID="test-tab-selftest"

    PASS=0
    FAIL=0

    _assert_count() {
        local label="$1"
        local expected="$2"
        local file="${TEST_DIR}/test-tab-selftest"
        local actual=0
        if [ -f "$file" ]; then
            actual=$(cat "$file" | tr -d '[:space:]')
        fi
        if [ "$actual" = "$expected" ]; then
            printf 'PASS: %s (count=%s)\n' "$label" "$actual"
            PASS=$((PASS + 1))
        else
            printf 'FAIL: %s — expected %s, got %s\n' "$label" "$expected" "$actual"
            FAIL=$((FAIL + 1))
        fi
    }

    _assert_file_absent() {
        local label="$1"
        local file="${TEST_DIR}/test-tab-selftest"
        if [ ! -f "$file" ]; then
            printf 'PASS: %s (file absent)\n' "$label"
            PASS=$((PASS + 1))
        else
            printf 'FAIL: %s — file still present with content: %s\n' \
                   "$label" "$(cat "$file")"
            FAIL=$((FAIL + 1))
        fi
    }

    # --- Test 1: three increments → count = 3 ---
    set_claude_active
    set_claude_active
    set_claude_active
    _assert_count "after 3x set_claude_active" "3"

    # --- Test 2: three decrements → count = 0, file deleted ---
    clear_claude_active
    clear_claude_active
    clear_claude_active
    _assert_file_absent "after 3x clear_claude_active (file should be deleted)"

    # --- Test 3: extra decrement does not go negative ---
    # After file is gone, one more clear should be a no-op (or reset to 0).
    clear_claude_active
    _assert_file_absent "after extra clear_claude_active (count must not go negative)"

    # --- Test 4: _iterm_tab_id prefers tmux client_tty over ITERM_SESSION_ID ---
    # Verify the XACA-0214 round-3 fix: in tmux, the stale ITERM_SESSION_ID
    # must NOT be used. The resolver should fall back to a non-stale source.
    # We can't fake a real tmux client_tty in a pure-shell test, so we simulate
    # by setting TMUX/TMUX_PANE to empty placeholders that cause the tmux
    # display-message call to fail — _iterm_tab_id should then skip past the
    # tmux branch and reach the ITERM_SESSION_ID fallback. That confirms the
    # branch structure is correct even if tmux resolution fails.
    (
        export TMUX="/tmp/fake-tmux-socket-selftest"
        export TMUX_PANE="%999"
        tab_id=$(_iterm_tab_id)
        if [ "$tab_id" = "test-tab-selftest" ]; then
            printf 'PASS: tmux branch falls back to ITERM_SESSION_ID when tmux resolution fails (got %s)\n' "$tab_id"
        else
            printf 'FAIL: tmux fallback — expected test-tab-selftest, got %s\n' "$tab_id"
            exit 1
        fi
    )
    if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

    # -----------------------------------------------------------------------
    # Helpers for parameterised assertions (Tests 5–8).
    # -----------------------------------------------------------------------
    _assert_file_count() {
        local label="$1" file="$2" expected="$3" actual=0
        if [ -f "$file" ]; then
            actual=$(cat "$file" | tr -d '[:space:]')
        fi
        if [ "$actual" = "$expected" ]; then
            printf 'PASS: %s (count=%s)\n' "$label" "$actual"
            PASS=$((PASS + 1))
        else
            printf 'FAIL: %s — expected %s, got %s\n' "$label" "$expected" "$actual"
            FAIL=$((FAIL + 1))
        fi
    }

    _assert_file_absent_at() {
        local label="$1" file="$2"
        if [ ! -f "$file" ]; then
            printf 'PASS: %s (file absent)\n' "$label"
            PASS=$((PASS + 1))
        else
            printf 'FAIL: %s — file still present\n' "$label"
            FAIL=$((FAIL + 1))
        fi
    }

    # --- Test 5: explicit tab_id creates file at expected path ---
    # Unset ITERM_SESSION_ID so the resolver cannot kick in accidentally.
    unset ITERM_SESSION_ID
    set_claude_active "explicit-test-tab-5"
    _assert_file_count "T5: explicit set creates refcount file (count=1)" \
        "${TEST_DIR}/explicit-test-tab-5" "1"
    clear_claude_active "explicit-test-tab-5"
    _assert_file_absent_at "T5: explicit clear deletes refcount file" \
        "${TEST_DIR}/explicit-test-tab-5"

    # --- Test 6: explicit vs resolver use different refcount files ---
    export ITERM_SESSION_ID="resolver-test-tab-6"
    unset TMUX
    unset TMUX_PANE
    set_claude_active                       # resolver → resolver-test-tab-6
    set_claude_active "explicit-test-tab-6" # explicit  → explicit-test-tab-6
    _assert_file_count "T6: resolver set creates its own file (count=1)" \
        "${TEST_DIR}/resolver-test-tab-6" "1"
    _assert_file_count "T6: explicit set creates separate file (count=1)" \
        "${TEST_DIR}/explicit-test-tab-6" "1"
    clear_claude_active                       # resolver path
    clear_claude_active "explicit-test-tab-6" # explicit path
    unset ITERM_SESSION_ID

    # --- Test 7: explicit tab_id with slashes gets sanitized ---
    unset ITERM_SESSION_ID
    set_claude_active "/dev/ttys999"
    _assert_file_count "T7: slash-containing tab_id sanitized to underscores (count=1)" \
        "${TEST_DIR}/_dev_ttys999" "1"
    clear_claude_active "/dev/ttys999"
    _assert_file_absent_at "T7: clear with slash tab_id deletes sanitized file" \
        "${TEST_DIR}/_dev_ttys999"

    # --- Test 8: empty explicit arg falls through to resolver ---
    export ITERM_SESSION_ID="fallback-test-tab-8"
    unset TMUX
    unset TMUX_PANE
    set_claude_active ""   # empty string → treated as no arg → resolver
    _assert_file_count "T8: empty arg falls through to resolver (count=1)" \
        "${TEST_DIR}/fallback-test-tab-8" "1"
    clear_claude_active "" # empty string → resolver path
    unset ITERM_SESSION_ID

    printf '\n'
    printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"

    if [ "$FAIL" -eq 0 ]; then
        exit 0
    else
        exit 1
    fi
fi
