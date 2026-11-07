#!/usr/bin/env bash
# kanban-crash-detect.sh — SessionStart hook (XACA-0778-003)
#
# Detects whether the PREVIOUS Claude Code session on this machine exited
# via a crash (Mac/tmux crash, force-quit, kill -9) rather than the graceful
# Stop path, and — only when there is actually orphaned in_progress work to
# recover — nudges the agent toward `kb-recover`.
#
# ---------------------------------------------------------------------------
# THE SENTINEL: ~/.aiteamforge/run/kanban-clean-shutdown.sentinel
# ---------------------------------------------------------------------------
# Written by kanban-hooks/kanban-stop.py, ONLY on the confirmed-real-exit
# branch of its background daemon (never on a turn-end Stop — see
# write_clean_shutdown_sentinel() there). Presence means "the most recent
# real Claude exit we know of, since this file was last consumed here, went
# through the graceful Stop path."
#
# State machine (consume-on-read, "test and reset" pattern):
#   PRESENT at SessionStart -> nothing crashed since the last graceful Stop.
#       Consume it (delete) and stay silent. Deleting NOW means the NEXT
#       SessionStart will correctly read ABSENT unless a fresh graceful Stop
#       re-arms it first — i.e. presence is a one-shot "all clear" token,
#       not a durable state.
#   ABSENT at SessionStart -> no graceful Stop has been observed since the
#       sentinel was last consumed. This is the crash signal, BUT absence
#       alone is not sufficient to nudge: most sessions end via `/exit`-less
#       tmux detach or a still-open window, which is completely normal WIP
#       and not evidence of a crash. So: check the board for ORPHANED
#       in_progress work (kb-recover --json, which classifies via LIVE tmux
#       liveness — the actually-authoritative check, independent of this
#       sentinel). Nudge ONLY if that count is > 0. Either way, re-establish
#       (write) the sentinel afterward so we don't repeat the same nudge on
#       every subsequent window opened before the next real crash — the
#       nudge is meant to be a one-time "heads up", not a recurring nag.
#
# KNOWN LIMITATION (documented per XACA-0778-003 instructions, not solved
# here): this is a single machine-global boolean, not a per-window reference
# count. With N concurrent windows open, ANY one of them exiting gracefully
# re-arms the sentinel for ALL of them — if a second window then crashes
# before the next SessionStart, that specific crash can be masked by the
# earlier window's clean exit. The real, precise detector is
# `kb-recover`/`_kb_reconcile_inprogress`, which checks LIVE tmux state at
# query time, not a stale flag — the sentinel only gates WHEN we bother to
# ask, to avoid nagging on completely ordinary "left WIP for tomorrow"
# sessions. Concurrent SessionStart hooks racing to read/write the sentinel
# is safe (idempotent, atomic write, last-writer-wins on a timestamp) but can
# produce redundant nudges for the same crash — acceptable, informational
# only, never blocks anything.
#
# Must be fast and MUST NEVER block/fail SessionStart — every risky step is
# guarded and the script always exits 0.
# ---------------------------------------------------------------------------

set -uo pipefail  # deliberately NOT -e: most steps here are best-effort

# KB_CRASH_SENTINEL_PATH lets tests point at a scratch file instead of the
# real machine-wide sentinel. Must stay in sync with CLEAN_SHUTDOWN_SENTINEL
# in kanban-hooks/kanban-stop.py for production use (default, unset case).
SENTINEL="${KB_CRASH_SENTINEL_PATH:-${HOME}/.aiteamforge/run/kanban-clean-shutdown.sentinel}"
SENTINEL_DIR="$(dirname "$SENTINEL")"

# Atomic write (tmp file + mv within the same dir) so a concurrent reader
# never observes a torn/partial file.
_write_sentinel() {
    mkdir -p "$SENTINEL_DIR" 2>/dev/null || return 0
    local ts tmp
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || return 0
    tmp="${SENTINEL}.tmp.$$"
    printf '%s\n' "$ts" > "$tmp" 2>/dev/null || return 0
    mv -f "$tmp" "$SENTINEL" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    return 0
}

# --- Presence branch: consume and go silent ---------------------------------
if [[ -f "$SENTINEL" ]]; then
    rm -f "$SENTINEL" 2>/dev/null || true
    exit 0
fi

# --- Absence branch: possible crash — check for actual orphaned work --------
# kanban-helpers.sh is zsh-only (kb-recover / _kb_reconcile_inprogress are
# zsh functions), so it must be sourced inside a zsh subshell — mirrors the
# pattern in kb-session-knowledge-check.sh. KB_HELPERS_PATH lets tests point
# at a worktree copy instead of the production copy.
# XACA-1753: located via the shared resolver (own location, AITEAMFORGE_DIR,
# legacy checkout) instead of a hardcoded checkout path.
HELPERS="${KB_HELPERS_PATH:-}"
# shellcheck disable=SC2034
_AITF_SELF="${BASH_SOURCE[0]:-$0}"
_AITF_SELF="$(readlink -f "$_AITF_SELF" 2>/dev/null || printf '%s' "$_AITF_SELF")"
_AITF_LIB="$(dirname "$_AITF_SELF")/aitf-root.sh"
if [[ -f "$_AITF_LIB" ]]; then
    . "$_AITF_LIB"
    aitf_init "$_AITF_SELF"
    [[ -n "$HELPERS" ]] || { aitf_locate kanban-helpers.sh || true; HELPERS="$AITF_FOUND"; }
    _LOOKED="${HELPERS:-$AITF_LOOKED}"
else
    HELPERS=""
    _LOOKED="$_AITF_LIB (aitf-root.sh missing)"
fi

if [[ -z "$HELPERS" || ! -f "$HELPERS" ]]; then
    # Can't check — don't claim a crash we couldn't verify, but SAY SO (XACA-1753:
    # this used to exit silently, an all-clear). Still write the sentinel so we
    # are not permanently wedged in the "check every startup" state.
    echo "kanban-crash-detect: could not check: kanban-helpers.sh not found (looked in ${_LOOKED:-$HELPERS})"
    _write_sentinel
    exit 0
fi

RECOVER_JSON=$(
    KB_TEAM="${KB_TEAM:-}" KB_TERMINAL="${KB_TERMINAL:-agent}" zsh -c '
        helpers="$1"
        source "$helpers" >/dev/null 2>&1 || exit 0
        command -v kb-recover >/dev/null 2>&1 || exit 0
        # No --team: kb-recover resolves the CURRENT team via _kb_detect_context
        # (tmux pane -> session name), matching this session'"'"'s own team scope.
        # If context can'"'"'t be resolved (no tmux, headless), kb-recover exits
        # non-zero with an empty/error stderr — swallowed below, ORPHAN_COUNT=0.
        kb-recover --json 2>/dev/null
    ' _ "$HELPERS" 2>/dev/null
) || true

ORPHAN_COUNT=0
if command -v jq >/dev/null 2>&1 && [[ -n "$RECOVER_JSON" ]]; then
    ORPHAN_COUNT=$(printf '%s' "$RECOVER_JSON" | jq 'if type == "array" then length else 0 end' 2>/dev/null)
fi
[[ "$ORPHAN_COUNT" =~ ^[0-9]+$ ]] || ORPHAN_COUNT=0

if [[ "$ORPHAN_COUNT" -gt 0 ]]; then
    if [[ "$ORPHAN_COUNT" -eq 1 ]]; then
        echo "⚠️  Unclean shutdown detected — 1 in-progress item may be orphaned. Run kb-recover to see the resume manifest."
    else
        echo "⚠️  Unclean shutdown detected — ${ORPHAN_COUNT} in-progress item(s) may be orphaned. Run kb-recover to see the resume manifest."
    fi
fi

# Re-establish a clean baseline regardless of whether we nudged — avoids
# repeating the same nudge on every subsequent window opened before the next
# real graceful Stop (see state-machine comment above).
_write_sentinel

exit 0
