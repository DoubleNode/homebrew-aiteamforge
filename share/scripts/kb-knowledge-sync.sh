#!/usr/bin/env bash
# kb-knowledge-sync.sh — XACA-0749 Phase 1
#
# Keeps a `~/knowledge` git clone in sync across the fleet by running
# `git pull --rebase` followed by `git push`. Designed to be invoked
# periodically by a LaunchAgent (com.devteam.knowledge-sync, wired up in
# Phase 2 via scripts/generate-launchagents.py) on a ~30 min timer, but it
# is a plain, dependency-light script that also runs fine by hand or from
# a test harness.
#
# ─────────────────────────────────────────────────────────────────────────
# DEGRADE GRACEFULLY — the whole design philosophy
# ─────────────────────────────────────────────────────────────────────────
# On most of the fleet (M1Pro/M4Mini, pre-XACA-0747/0750) `~/knowledge` is
# currently just a plain directory with no git repo and no auth. This
# script MUST no-op cleanly in that world and simply start doing real work
# the moment a real clone + credentials show up — without anyone having to
# touch a LaunchAgent or plist. Every degraded condition (not a repo yet,
# lock already held, mid-rebase, rebase conflict, push rejected/offline/
# no-auth) is logged and treated as an ORDINARY outcome, not a script
# failure. The only thing that must NEVER happen is a wedged, half-rebased
# ~/knowledge left behind for a human to discover days later.
#
# ─────────────────────────────────────────────────────────────────────────
# XACA-1266 — the dirty-tree contract, and why it changed
# ─────────────────────────────────────────────────────────────────────────
# Before XACA-1266, ANY dirty tree (`git status --porcelain` non-empty)
# skipped BOTH halves of the sync outright (`skipped-dirty`, now RETIRED —
# see kanban/plans/XACA-1266/XACA-1266-003-design-decision.md §3.5). Since
# nothing in the codebase ever commits to ~/knowledge
# (kb-knowledge-add lands entries untracked), the tree is dirty
# essentially always on an authoring machine — so that guard made the
# daemon a permanent, silent no-op on exactly the machines that most need
# it, for weeks at a stretch (measured: 38/38 consecutive ticks on M3Pro).
#
# We still NEVER stash. Stashing someone else's in-flight, uncommitted
# knowledge entry behind their back is exactly the kind of "clever"
# surprise this daemon must never pull — a knowledge commit is authored via
# kb-knowledge-add and a dirty tree here always means a human is mid-edit.
# What changed is HOW we protect that invariant: instead of a guard that
# refuses to touch the tree at all whenever it's dirty, we now delegate
# enforcement to git itself, which is a categorically stronger position.
#
#   - `git fetch` is measured to never touch the working tree, the index,
#     or HEAD (see 002 §1.1) — there is no dirty-tree hazard to guard
#     against, so it now runs UNCONDITIONALLY, every tick, dirty or clean.
#   - On a DIRTY tree we integrate ONLY via `git merge --ff-only @{u}`,
#     never `rebase`, never a plain `merge`, and never `--autostash`
#     (measured exiting 0 while leaving conflict markers behind — see 002
#     §1.5 — which is worse than the guard it would replace). `--ff-only`
#     is structurally incapable of overwriting a modified or untracked
#     path: it refuses (exit 1, HEAD unchanged, local content verbatim) on
#     both collision shapes, and refuses just as cleanly (HEAD unchanged,
#     no rebase dir left behind) when the branch has genuinely diverged
#     and a fast-forward is impossible. No state exists in which
#     `--ff-only` leaves the repo worse than it found it.
#   - On a CLEAN tree, nothing changes: `git pull --rebase`, same as
#     before.
#   - The PUSH side: see the XACA-1291 section immediately below. The
#     clean-tree push gate described in earlier revisions of this comment
#     is GONE.
#
# ─────────────────────────────────────────────────────────────────────────
# XACA-1291 — the OUTBOUND half: daemon-side auto-commit
# ─────────────────────────────────────────────────────────────────────────
# XACA-1266 fixed RECEIVING. Sending stayed permanently closed: push was
# gated on a clean tree and nothing ever committed, so an authoring machine
# never shared a single entry. The tick is now:
#
#   guards -> fetch -> UNWIND own unpushed auto-commits (diverged + dirty)
#          -> integrate (unchanged) -> AUTO-COMMIT complete entries
#          -> dup-slot gate -> PUSH when ahead > 0 and behind == 0 (clean OR
#             dirty) -> ONE notify-state write (inbound + outbound counters)
#
# Auto-commit only commits allowlisted (agents/ subjects/ teams/) entries
# that are COMPLETE (valid SPEC §3 frontmatter, non-empty tags, no
# kb-knowledge-add scaffold markers, a real body), QUIESCENT (untouched for
# 15 min, no editor swap/lock file) and not carrying the author opt-out
# `<!-- knowledge-sync: hold -->`, plus an INDEX.md only when every row it
# adds points at a committed entry. The commit is built in a PRIVATE temp
# index seeded from HEAD — never `git add`, never the human's index — so a
# half-written entry or another session's staging can never be swept in.
# Hooks always run; a refusal quarantines the named entry by content hash,
# an unattributed refusal (a broken hook) backs off for 24h. Kill switch:
# KB_KNOWLEDGE_SYNC_AUTOCOMMIT=0 or $HOME/.aiteamforge/knowledge-sync-
# autocommit.off (the sentinel exists because launchd cannot see shell env).
#
# Pushing from a dirty tree is safe: push reads refs and objects only, never
# the worktree or the index (measured byte-identical, design §1.6). The only
# real precondition is behind == 0, which is checked explicitly.
#
# Normative design: kanban/plans/XACA-1291/XACA-1291_outbound_autocommit_
# design.md. This comment summarizes it; that document wins.
#
# See kanban/plans/XACA-1266/XACA-1266-003-design-decision.md for the full
# INBOUND design (this comment summarizes it; that document is normative).
#
# Usage:
#   kb-knowledge-sync.sh [repo-path]
#
# Repo path resolution (highest precedence first):
#   1. First positional argument, if given.
#   2. $KB_KNOWLEDGE_REPO env var, if set.
#   3. $HOME/knowledge (default).
#
# Env vars:
#   KB_KNOWLEDGE_REPO                Override the target repo path (see above).
#   KB_KNOWLEDGE_SYNC_LOCK_DIR        Override the lock directory (default is
#                                     derived from the repo path under
#                                     $TMPDIR/tmp so distinct fixture repos in
#                                     tests naturally get distinct locks).
#   KB_KNOWLEDGE_SYNC_LOCK_STALE_SECONDS
#                                     Age (seconds) after which a held lock is
#                                     considered abandoned by a crashed prior
#                                     run and reclaimed. Default 3600 (2x the
#                                     30-min LaunchAgent interval).
#   KB_KNOWLEDGE_SYNC_STATE_FILE      Override the (d)-notify state file path
#                                     (default $HOME/.aiteamforge/run/
#                                     knowledge-sync-state.json). The daemon
#                                     COMPUTES this path itself, the same way
#                                     it computes KB_KNOWLEDGE_SYNC_LOCK_DIR
#                                     above — it is NOT derived from the log
#                                     path (which is plist-assigned per host
#                                     and not daemon-knowable; see design doc
#                                     §10). Consumers (the SessionStart guard
#                                     hook, the health-check script) read this
#                                     same env var / default so they resolve
#                                     the identical path without either side
#                                     hardcoding the other's internals.
#   KB_KNOWLEDGE_SYNC_AUTOCOMMIT      XACA-1291 kill switch: `0` disables
#                                     unwind + auto-commit (any other value,
#                                     or unset, = enabled). The sentinel file
#                                     $HOME/.aiteamforge/knowledge-sync-
#                                     autocommit.off disables it too — that is
#                                     the one a LaunchAgent can actually see.
#   KB_KNOWLEDGE_SYNC_AUTOCOMMIT_QUIESCE_SECONDS
#                                     Minimum age (mtime) before an entry is a
#                                     commit candidate. Default 900.
#   KB_KNOWLEDGE_SYNC_QUARANTINE_FILE Writer-private quarantine sidecar
#                                     (default: STATE_FILE with .json swapped
#                                     for .quarantine). No consumer reads it.
#
# Exit-code policy:
#   This script exits 0 in essentially every normal AND degraded case —
#   not-a-repo, lock-held, fetch-failure, a fast-forward refusal (dirty or
#   diverged), rebase-conflict, push-failure are all ordinary outcomes for a
#   best-effort background sync and must never mark the LaunchAgent job as
#   failed. Non-zero exit is reserved ONLY for actual script-usage bugs
#   (e.g. too many arguments) or genuine data-integrity defects (Guard 1b
#   PII containment, Guard 4 duplicate ID-slot collision) — never for an
#   ordinary git/network condition. Grep the log output (tagged
#   `[kb-knowledge-sync]`) to see what actually happened on a given run.
#
# XACA-0749, XACA-1266

set -uo pipefail
# NOTE: deliberately no `set -e` — this script's entire contract is to keep
# running past git/network failures, log them, and still exit 0. `set -e`
# would abort mid-guard on the first non-zero command (e.g. a failed `git
# pull`) before we get a chance to run `git rebase --abort` and log the
# outcome. Errors are handled explicitly at each step instead.

# ── Usage guard (the ONE case that exits non-zero) ───────────────────────────
if [ $# -gt 1 ]; then
    echo "Usage: $(basename "$0") [repo-path]" >&2
    exit 64  # EX_USAGE
fi

# ── Logging ───────────────────────────────────────────────────────────────────

log() {
    printf '[%s] [kb-knowledge-sync] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

# Logs a (possibly multi-line) command output block, one prefixed line per
# input line, under a label. No-op if content is empty.
log_block() {
    local label="$1" content="$2"
    [ -n "$content" ] || return 0
    while IFS= read -r _line; do
        log "${label}: ${_line}"
    done <<< "$content"
}

# ── Repo path resolution ──────────────────────────────────────────────────────

REPO_DIR="${1:-}"
if [ -z "$REPO_DIR" ]; then
    REPO_DIR="${KB_KNOWLEDGE_REPO:-$HOME/knowledge}"
fi

# ── Guard 1: git-repo detection ───────────────────────────────────────────────
# Missing dir, or a plain (non-git) directory — no-op, exit 0. This is the
# expected steady-state on fleet machines until XACA-0747/0750 land.
if [ ! -d "$REPO_DIR" ] || ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "no-op-not-a-repo: ${REPO_DIR} does not exist or is not yet a git repository — nothing to sync"
    exit 0
fi

# Normalize to an absolute, symlink-resolved path now that we know it exists.
REPO_DIR="$(cd "$REPO_DIR" && pwd)"

# ── Guard 1b: PII containment (XACA-0754) ────────────────────────────────────
# finance-personal/legal-coparenting/medical-general knowledge entries carry
# PII and are written under KB_KNOWLEDGE_LOCAL_ROOT (default ~/knowledge-local)
# specifically so THIS daemon can never see them — see
# kanban/plans/XACA-0754/DESIGN.md §6. If local_root ever resolves inside (or
# equal to) REPO_DIR — a misconfigured env var, or a future refactor that
# nests knowledge-local under knowledge/ — that separation is broken and this
# daemon could push PII to every machine on the fleet. This is exactly the
# kind of config/programming bug that must abort loudly, unlike every other
# guard in this script (which degrades quietly because ordinary git/network
# conditions are expected). Non-zero exit here is deliberate.
LOCAL_ROOT="${KB_KNOWLEDGE_LOCAL_ROOT:-$HOME/knowledge-local}"
if [ -d "$LOCAL_ROOT" ]; then
    LOCAL_ROOT_REAL="$(cd "$LOCAL_ROOT" && pwd -P)"
else
    LOCAL_ROOT_REAL="$LOCAL_ROOT"
fi
# Resolve REPO_DIR the SAME way (pwd -P) for this comparison only — REPO_DIR
# itself stays as normalized above (plain `pwd`) for the rest of the script.
# On macOS, $TMPDIR (and /tmp) is a symlink into /private/..., so `pwd -P` on
# one side and plain `pwd` on the other can textually diverge for the exact
# same physical directory, producing a false-negative (guard silently does
# not fire) for any fixture/test rooted under /tmp — caught by CASE 12 in
# scripts/tests/test-kb-knowledge-sync.sh.
REPO_DIR_REAL="$(cd "$REPO_DIR" && pwd -P)"
case "$LOCAL_ROOT_REAL" in
    "$REPO_DIR_REAL"|"$REPO_DIR_REAL"/*)
        log "FATAL: KB_KNOWLEDGE_LOCAL_ROOT (${LOCAL_ROOT}) resolves inside the synced repo (${REPO_DIR}) — PII containment is broken. Refusing to sync. Fix KB_KNOWLEDGE_LOCAL_ROOT / KB_KNOWLEDGE_REPO (or the REPO_DIR argument) and re-run."
        exit 78  # EX_CONFIG
        ;;
esac

# ── Guard 2: lock file (prevents overlapping launchd ticks) ──────────────────
# macOS ships no `flock` binary by default, so this uses an atomic
# `mkdir`-based lock (mkdir is atomic even over NFS) with a pidfile inside it
# for liveness checking and an mtime-based staleness fallback in case the
# lock holder was killed before it could clean up (e.g. SIGKILL bypasses the
# EXIT trap).
_slugify() {
    # Replace every non-alphanumeric character with '_' so the repo path can
    # be embedded in a filesystem-safe lock-directory name. Deliberately
    # collapses to a long-ish but readable slug rather than hashing, so the
    # lock path is self-describing when inspected by a human.
    printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'
}

LOCK_STALE_SECONDS="${KB_KNOWLEDGE_SYNC_LOCK_STALE_SECONDS:-3600}"
LOCK_DIR="${KB_KNOWLEDGE_SYNC_LOCK_DIR:-${TMPDIR:-/tmp}/kb-knowledge-sync.$(_slugify "$REPO_DIR").lock}"
LOCK_PID_FILE="${LOCK_DIR}/pid"
_LOCK_HELD=false

# shellcheck disable=SC2329  # invoked indirectly via the trap below, not by direct call
release_lock() {
    # XACA-1291: the per-tick scratch dir (temp index, blobs, commit message)
    # lives next to the lock's lifetime, so it goes when the lock goes.
    if [ -n "${TICK_TMP:-}" ] && [ -d "$TICK_TMP" ]; then
        rm -rf "$TICK_TMP" 2>/dev/null || true
    fi
    if [ "$_LOCK_HELD" = "true" ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
}
trap release_lock EXIT INT TERM

_acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_PID_FILE" 2>/dev/null || true
        _LOCK_HELD=true
        return 0
    fi
    return 1
}

if ! _acquire_lock; then
    _held_pid=""
    [ -f "$LOCK_PID_FILE" ] && _held_pid="$(cat "$LOCK_PID_FILE" 2>/dev/null || true)"

    if [ -n "$_held_pid" ] && kill -0 "$_held_pid" 2>/dev/null; then
        log "skipped-lock-held: another sync is in progress for ${REPO_DIR} (pid ${_held_pid}) — exiting"
        exit 0
    fi

    # Holder is gone (or pidfile unreadable) — check for staleness by mtime
    # before reclaiming, so we don't race a holder that is between `mkdir`
    # and writing its pidfile.
    _lock_epoch="$(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)"
    _now_epoch="$(date +%s)"
    _lock_age=$(( _now_epoch - _lock_epoch ))

    if [ "$_lock_age" -ge "$LOCK_STALE_SECONDS" ]; then
        log "reclaiming stale lock at ${LOCK_DIR} (age ${_lock_age}s, held-pid='${_held_pid:-unknown}' not alive)"
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        if ! _acquire_lock; then
            log "skipped-lock-held: could not reclaim lock for ${REPO_DIR} after cleanup — exiting"
            exit 0
        fi
    else
        log "skipped-lock-held: lock for ${REPO_DIR} exists (age ${_lock_age}s, below staleness threshold ${LOCK_STALE_SECONDS}s) — exiting"
        exit 0
    fi
fi

# ── (d) notify state (XACA-1266 §4) ──────────────────────────────────────────
# A throttled, daemon-written state file so a machine that cannot converge
# says so LOUDLY instead of no-opping quietly forever (the failure mode
# this ticket exists to kill — a 1004-run, ~21-day silent stall on M4Mini).
# Trigger is "failure to converge over time", NEVER mere dirtiness — after
# the fix below, a dirty tree converges inbound on its own, so the old
# "warn whenever dirty" signal (which fired on ~100% of ticks on a heavy-
# authoring machine and trained everyone to ignore it) is retired outright.
#
# Fail-direction split (design §4.4), deliberate and asymmetric:
#   - WRITER (here): an unwritable state file logs `notify-state-unwritable`
#     and the sync CONTINUES NORMALLY. Degrading the actual sync because a
#     counter could not be persisted would be strictly worse than the bug
#     being fixed here.
#   - READER (claude-hooks/kb-knowledge-sync-guard.sh,
#     scripts/kb-knowledge-sync-health-check.sh): a missing, unreadable, or
#     stale state file must be treated as UNKNOWN — NOT healthy — never as
#     "no stall". Mirrors the existing STALE-CACHE fail-closed philosophy
#     exactly: absence of a problem report is not a report of absence.
#
# STATE_FILE is COMPUTED the same way LOCK_DIR above is: an env-var override
# with a sensible, non-hardcoded default. It is deliberately NOT derived
# from $KB_KNOWLEDGE_SYNC_LOG_PATH — that path is assigned per-host by each
# machine's LaunchAgent plist (StandardOutPath/StandardErrorPath) and is
# therefore fundamentally NOT knowable from inside this script (see design
# doc §10); a consumer hardcoding it goes blind on hosts where it differs
# (measured: M4Mini). This file's path, by contrast, is the SAME formula on
# every host and every consumer, so nothing needs to rediscover it per host.
STATE_FILE="${KB_KNOWLEDGE_SYNC_STATE_FILE:-$HOME/.aiteamforge/run/knowledge-sync-state.json}"

_now_iso() {
    date -u +'%Y-%m-%dT%H:%M:%SZ'
}

# Minimal scalar-field reader for the single-line JSON this script itself
# writes (see _update_notify_state below) — deliberately NOT a general JSON
# parser, just enough to read back the known, controlled field shapes this
# script produces (a bare integer, a double-quoted string, or a literal
# null) without adding a jq dependency, matching this script's existing
# dependency-light philosophy (see the inline Guard 4 duplicate-slot check
# further down, which avoids sourcing the zsh validator for the same
# reason). Prints "" if the key or file is absent/unreadable/malformed.
_json_field() {
    local file="$1" key="$2"
    [ -r "$file" ] || { printf ''; return 0; }
    sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p' "$file" 2>/dev/null | head -1
}

# Backslash- and quote-escape a value for embedding in the JSON this script
# writes. Values here are always paths/tokens/timestamps we generate
# ourselves, but escape anyway rather than assume.
_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# ── XACA-1291 outbound configuration (design §4.1) ──────────────────────────
AC_SENTINEL="${HOME}/.aiteamforge/knowledge-sync-autocommit.off"
AC_QUIESCE_SECONDS="${KB_KNOWLEDGE_SYNC_AUTOCOMMIT_QUIESCE_SECONDS:-900}"
case "$AC_QUIESCE_SECONDS" in ''|*[!0-9]*) AC_QUIESCE_SECONDS=900 ;; esac
QUARANTINE_FILE="${KB_KNOWLEDGE_SYNC_QUARANTINE_FILE:-${STATE_FILE%.json}.quarantine}"
AUTOCOMMIT_MAX_PATHS=200
ENTRY_MAX_BYTES=262144
COMMIT_ATTEMPTS_PER_TICK=2
QUARANTINE_MAX_LINES=500
HOOK_ERROR_BACKOFF_SECONDS=86400
AC_COMMITTER_NAME="knowledge-sync daemon"
AC_TRAILER_MARK="Knowledge-Sync-Autocommit: v1"

# Outbound bookkeeping carried into the ONE _update_notify_state call per
# tick (design §5.2). Set by the tick body below; defaults mean "nothing
# happened".
OUT_WITHHELD_PATHS=0
OUT_QUARANTINED=0
OUT_HAS_WITHHELD=0
AC_HOOK_ERR_KEY=""
AC_HOOK_ERR_AT=""
AC_RESYNC_PENDING=""
AC_NONALLOW_FP_PREV=""
_RES_OTHER_FP=""

# _notify_milestone_due <counter> <threshold> <prev_threshold>
#
# Returns 0 when a notify line is due. Extracted (XACA-1291 §5.3) from the
# XACA-1266-013 inline logic so the inbound AND outbound counters share ONE
# milestone rule instead of two copies that can drift apart.
#
# XACA-1266-013: the ORIGINAL implementation walked an exact-match
# milestone sequence (threshold, threshold*4, threshold*16, …) starting
# from the CURRENT tick's threshold and fired ONLY when the counter landed
# EXACTLY on one of those values. That silently drops the first notify
# when the threshold ESCALATES mid-streak: e.g. five ordinary unproductive
# ticks accumulate under threshold=6 (no fire — correctly, 5<6), then the
# sixth tick's token is blocked-ff-diverged, dropping the threshold to 2.
# The counter is now 6, but the escalated sequence is 2, 8, 32, … — 6
# matches none of them, so the alert that is already overdue under the NEW
# threshold is silently deferred. FIX: keep the exact-match sequence (it
# is correct for the constant-threshold case, and tests/test-xaca-1266-006
# CASE5/6 assert its silence-between-milestones property directly), and
# ADD a second, independent condition that catches ONLY the escalation
# transition: the threshold just dropped relative to what applied last
# tick AND the counter is already at/past the new, lower threshold. It
# fires on the exact tick of the drop and never again under the same
# (now-stable) threshold, so the backed-off cadence resumes afterwards.
_notify_milestone_due() {
    local n="$1" t="$2" pt="$3" m
    [ "$n" -ge "$t" ] && [ "$t" -gt 0 ] || return 1
    m=$t
    while [ "$m" -le "$n" ]; do
        [ "$m" -eq "$n" ] && return 0
        m=$(( m * 4 ))
    done
    [ "$t" -lt "$pt" ] && return 0
    return 1
}

# Outbound threshold (design §5.3): 2 for the two states that cannot
# self-heal without a human (a hook refusal needs an author edit, a broken
# hook needs a hook fix), else 48 ticks (~24h). Authoring legitimately
# leaves incomplete dirt for hours; this signal must mean "this machine
# has not shared something for a day", not "someone is typing".
_outbound_threshold() {
    case "$1" in
        autocommit-refused|autocommit-hook-error) echo 2 ;;
        *) echo 48 ;;
    esac
}

# _update_notify_state <inbound-token> <outbound-token> <measured-ahead> <measured-behind>
#
# Called ONCE per tick (XACA-1291 §5.1). The inbound half is unchanged from
# XACA-1266: it takes the phase token that determines convergence
# (fetch-failed / blocked-ff-conflict / blocked-ff-diverged /
# rebase-conflict-aborted / converged-ff / fetch-only-dirty /
# rebased-advanced / already-current / synced — see design doc §3.5 for the
# full token vocabulary). Reads the PREVIOUS counters from $STATE_FILE (if
# present/readable), advances them per the tables below, writes the new
# state atomically (temp file + mv so a reader never sees a half-written
# file), and — only at a backed-off milestone — logs a greppable
# `notify-stall` / `notify-outbound-stall` line to THIS script's own log.
#
#   Inbound increment on: fetch-failed, blocked-ff-conflict, blocked-ff-diverged,
#                 rebase-conflict-aborted   (design §5's fail-direction table)
#   Inbound reset to 0 on: converged-ff, rebased-advanced, already-current,
#                  fetch-only-dirty, synced   (design §4.2)
#   Inbound threshold 6, escalated to 2 for blocked-ff-diverged.
#
#   Outbound (XACA-1291 §5.3): a SECOND, independent counter in the SAME
#   file and the SAME write. Never a second mechanism.
#     reset on: pushed, outbound-current (and autocommit-disabled when
#               nothing is withheld)
#     neutral: outbound-not-attempted. Inbound did not converge and the
#               inbound counter already reports it. The counter AND the
#               last outbound token are left as they were: recording
#               "not-attempted" as the last token would silently lower an
#               escalated threshold (2) back to 48 in the reader.
#     +1 on everything else; threshold 48, or 2 for autocommit-refused /
#               autocommit-hook-error.
_update_notify_state() {
    local token="$1" ob_token="${2:-}" m_ahead="${3:-}" m_behind="${4:-}"
    local prev_counter prev_first new_counter threshold

    prev_counter="$(_json_field "$STATE_FILE" consecutive_unproductive_ticks)"
    case "$prev_counter" in ''|*[!0-9]*) prev_counter=0 ;; esac
    prev_first="$(_json_field "$STATE_FILE" first_unproductive_at)"

    # XACA-1266-013: the threshold that applied on the PREVIOUS tick, read
    # from the state file's OWN last_outcome_token — the same pure function
    # of a token used to compute THIS tick's threshold below. Used only to
    # detect an ESCALATION (see _notify_milestone_due); an absent or
    # unrecognized prior token defaults to the non-escalated 6.
    local prev_token prev_threshold
    prev_token="$(_json_field "$STATE_FILE" last_outcome_token)"
    prev_threshold=6
    [ "$prev_token" = "blocked-ff-diverged" ] && prev_threshold=2

    case "$token" in
        fetch-failed|blocked-ff-conflict|blocked-ff-diverged|rebase-conflict-aborted)
            new_counter=$(( prev_counter + 1 ))
            if [ "$prev_counter" -eq 0 ]; then
                prev_first="$(_now_iso)"
            fi
            ;;
        converged-ff|rebased-advanced|already-current|fetch-only-dirty|synced)
            new_counter=0
            prev_first=""
            ;;
        *)
            # An unrecognized token — leave the counter exactly as it was
            # rather than guess in either direction.
            new_counter="$prev_counter"
            ;;
    esac

    threshold=6
    [ "$token" = "blocked-ff-diverged" ] && threshold=2

    if _notify_milestone_due "$new_counter" "$threshold" "$prev_threshold"; then
        log "notify-stall: ${new_counter} consecutive unproductive tick(s) on ${REPO_DIR} (last=${token}, threshold=${threshold}) — ahead=${m_ahead:-unknown} behind=${m_behind:-unknown}, first unproductive at ${prev_first:-unknown}"
    fi

    # ── Outbound counter (XACA-1291 §5.2/§5.3) ─────────────────────────────
    local ob_prev ob_first ob_prev_token ob_new ob_threshold ob_prev_threshold ob_record
    ob_prev="$(_json_field "$STATE_FILE" consecutive_outbound_withheld_ticks)"
    case "$ob_prev" in ''|*[!0-9]*) ob_prev=0 ;; esac
    ob_first="$(_json_field "$STATE_FILE" first_outbound_withheld_at)"
    [ "$ob_first" = "null" ] && ob_first=""
    ob_prev_token="$(_json_field "$STATE_FILE" last_outbound_token)"
    [ "$ob_prev_token" = "null" ] && ob_prev_token=""
    ob_record="$ob_token"
    case "$ob_token" in
        pushed|outbound-current)
            ob_new=0; ob_first="" ;;
        ''|outbound-not-attempted)
            ob_new="$ob_prev"
            ob_record="${ob_prev_token:-outbound-not-attempted}" ;;
        autocommit-disabled)
            if [ "$OUT_HAS_WITHHELD" -eq 1 ]; then
                ob_new=$(( ob_prev + 1 ))
            else
                ob_new=0; ob_first=""
            fi ;;
        *)
            ob_new=$(( ob_prev + 1 )) ;;
    esac
    if [ "$ob_new" -gt 0 ] && [ -z "$ob_first" ]; then
        ob_first="$(_now_iso)"
    fi
    if [ "$ob_new" -gt "$ob_prev" ]; then
        ob_threshold="$(_outbound_threshold "$ob_record")"
        ob_prev_threshold="$(_outbound_threshold "$ob_prev_token")"
        if _notify_milestone_due "$ob_new" "$ob_threshold" "$ob_prev_threshold"; then
            log "notify-outbound-stall: ${ob_new} consecutive outbound-withheld tick(s) on ${REPO_DIR} (last=${ob_record}, threshold=${ob_threshold}) — this machine is RECEIVING but not SENDING; withheld_paths=${OUT_WITHHELD_PATHS} quarantined=${OUT_QUARANTINED}, first withheld at ${ob_first:-unknown}"
        fi
    fi

    local state_dir tmp_file
    state_dir="${STATE_FILE%/*}"
    if [ "$state_dir" = "$STATE_FILE" ]; then
        state_dir="."
    fi
    if ! mkdir -p "$state_dir" 2>/dev/null; then
        log "notify-state-unwritable: could not create ${state_dir} for ${STATE_FILE} — sync continuing normally"
        return 0
    fi

    tmp_file="${STATE_FILE}.tmp.$$"
    {
        printf '{'
        printf '"consecutive_unproductive_ticks":%d,' "$new_counter"
        if [ -n "$prev_first" ]; then
            printf '"first_unproductive_at":"%s",' "$(_json_escape "$prev_first")"
        else
            printf '"first_unproductive_at":null,'
        fi
        printf '"last_outcome_token":"%s",' "$(_json_escape "$token")"
        printf '"last_fetch_at":"%s",' "$(_json_escape "$(_now_iso)")"
        printf '"measured_ahead":%s,' "${m_ahead:-null}"
        printf '"measured_behind":%s,' "${m_behind:-null}"
        printf '"repo_path":"%s",' "$(_json_escape "$REPO_DIR")"
        printf '"consecutive_outbound_withheld_ticks":%d,' "$ob_new"
        if [ -n "$ob_first" ]; then
            printf '"first_outbound_withheld_at":"%s",' "$(_json_escape "$ob_first")"
        else
            printf '"first_outbound_withheld_at":null,'
        fi
        printf '"last_outbound_token":"%s",' "$(_json_escape "$ob_record")"
        printf '"outbound_withheld_paths":%d,' "$OUT_WITHHELD_PATHS"
        printf '"outbound_quarantined":%d,' "$OUT_QUARANTINED"
        printf '"outbound_nonallowlisted_paths":%d,' "${_RES_OTHER:-0}"
        if [ -n "$_RES_OTHER_FP" ]; then
            printf '"outbound_nonallowlisted_fingerprint":"%s",' "$(_json_escape "$_RES_OTHER_FP")"
        else
            printf '"outbound_nonallowlisted_fingerprint":null,'
        fi
        if [ -n "$AC_HOOK_ERR_KEY" ]; then
            printf '"autocommit_hook_error_key":"%s",' "$(_json_escape "$AC_HOOK_ERR_KEY")"
            printf '"autocommit_hook_error_at":"%s",' "$(_json_escape "$AC_HOOK_ERR_AT")"
        else
            printf '"autocommit_hook_error_key":null,"autocommit_hook_error_at":null,'
        fi
        if [ -n "$AC_RESYNC_PENDING" ]; then
            printf '"autocommit_index_resync_pending":"%s"' "$(_json_escape "$AC_RESYNC_PENDING")"
        else
            printf '"autocommit_index_resync_pending":null'
        fi
        printf '}\n'
    } > "$tmp_file" 2>/dev/null

    if [ ! -s "$tmp_file" ] || ! mv "$tmp_file" "$STATE_FILE" 2>/dev/null; then
        log "notify-state-unwritable: could not write ${STATE_FILE} — sync continuing normally"
        rm -f "$tmp_file" 2>/dev/null || true
        return 0
    fi
    return 0
}

# ══ XACA-1291: outbound auto-commit library (design §4) ══════════════════════
# Everything below is called from the tick body further down. None of it
# writes the working tree: the only object-writing operations are
# `hash-object -w` (objects), temp-index `read-tree` / `update-index` /
# `commit` (a PRIVATE index file + objects + the branch ref), the unwind's
# CAS `update-ref` + real-index `read-tree -m HEAD` (ref once, then index
# only) and real-index `update-index --cacheinfo` (index only, resync
# only). There is deliberately no `git add` anywhere in this file: a
# `git add` of any shape reads the working tree by pathspec and is exactly
# how another session's half-written entry gets swept in.

_AC_TAB="$(printf '\t')"
AC_RESULT="none"
AC_Q_SKIPPED=0
AC_COMMIT_OUT=""
AC_NO_PUSH=0   # XACA-1291-008: set on a lost race / failed verify — never push that tick
TICK_TMP=""

_ac_enabled() {
    [ "${KB_KNOWLEDGE_SYNC_AUTOCOMMIT:-1}" = "0" ] && return 1
    [ -e "$AC_SENTINEL" ] && return 1
    return 0
}

_ac_host() {
    local h
    h="$(scutil --get LocalHostName 2>/dev/null || true)"
    [ -n "$h" ] || h="$(hostname -s 2>/dev/null || true)"
    [ -n "$h" ] || h="unknown-host"
    printf '%s' "$h" | tr -c 'A-Za-z0-9-' '-'
}
AC_HOST="$(_ac_host)"

# Per-tick scratch dir (removed by release_lock). Call as a plain statement,
# never inside $(...), or the assignment dies with the subshell.
_ac_tmp() {
    if [ -z "$TICK_TMP" ]; then
        TICK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/kb-knowledge-sync-tick.XXXXXX" 2>/dev/null || true)"
    fi
    [ -n "$TICK_TMP" ] && [ -d "$TICK_TMP" ]
}

_ac_git() { git -C "$REPO_DIR" "$@"; }

_ac_sha1() {
    if command -v shasum >/dev/null 2>&1; then
        shasum | awk '{print $1}'
    elif command -v sha1sum >/dev/null 2>&1; then
        sha1sum | awk '{print $1}'
    else
        cksum | awk '{print $1 "-" $2}'
    fi
}

_ac_mtime() {
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || true
}

_ac_iso_to_epoch() {
    local t="$1" e=""
    [ -n "$t" ] || { printf ''; return 0; }
    e="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$t" '+%s' 2>/dev/null || true)"
    [ -n "$e" ] || e="$(date -u -d "$t" '+%s' 2>/dev/null || true)"
    case "$e" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$e" ;; esac
}

_ac_count_lines() {
    local n
    n="$(wc -l < "$1" 2>/dev/null || echo 0)"
    echo $(( n + 0 ))
}

# P4: any git operation in progress, or the real index locked.
_ac_git_busy() {
    local f
    for f in MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD sequencer BISECT_LOG index.lock; do
        if [ -e "${GIT_DIR}/${f}" ]; then
            _AC_BUSY_WHY="$f"
            return 0
        fi
    done
    return 1
}

# ── §4.2 path allowlist (ERE, anchored). The character class also makes every
# accepted path shell- and pathspec-safe; paths still always go after `--`.
_AC_SEG='[a-z0-9][a-z0-9_-]*'
_AC_NAME='[a-z]+[0-9]{3,}-[a-z0-9][a-z0-9_-]*\.md'
AC_ENTRY_RE="^(agents|teams)/${_AC_SEG}/${_AC_NAME}\$|^subjects/${_AC_SEG}(/${_AC_SEG})?/${_AC_NAME}\$"
AC_INDEX_RE="^(agents|teams)/${_AC_SEG}/INDEX\\.md\$|^subjects/${_AC_SEG}(/${_AC_SEG})?/INDEX\\.md\$"

# _ac_classify <repo-relative-path> -> prints "index", "entry <tier>", or
# nothing (not a candidate). The filename prefix must match the tier
# (k=agent, s=subject, t=team); a wrong prefix is not a candidate.
_ac_classify() {
    local p="$1" top b pfx tier
    if [[ "$p" =~ $AC_INDEX_RE ]]; then
        echo "index"
        return 0
    fi
    if [[ "$p" =~ $AC_ENTRY_RE ]]; then
        top="${p%%/*}"
        b="${p##*/}"
        case "$top" in
            agents) pfx=k; tier=agent ;;
            subjects) pfx=s; tier=subject ;;
            teams) pfx=t; tier=team ;;
            *) return 0 ;;
        esac
        case "$b" in
            "${pfx}"[0-9]*) echo "entry ${tier}" ;;
        esac
    fi
    return 0
}

# §4.3 test 4: editor artifacts for this basename. They are gitignored, so
# they are checked on the filesystem. `-L` as well as `-e`: the emacs lock
# `.#b` is a DANGLING symlink, which `-e` alone reports as absent.
_ac_editor_artifact() {
    local abs="$1" d b f
    d="${abs%/*}"
    b="${abs##*/}"
    for f in "$d/.$b".sw? "$d/.$b".tmp* "$d/$b~" "$d/#$b#" "$d/.#$b" "$d/$b.tmp"; do
        if [ -e "$f" ] || [ -L "$f" ]; then
            return 0
        fi
    done
    return 1
}

# §4.3 tests 2–4 on the worktree file, BEFORE hashing (so a file still being
# typed never writes a loose object). Prints the hold reason on failure.
_ac_precheck() {
    local abs="$REPO_DIR/$1" sz m now age
    if [ ! -f "$abs" ] || [ -L "$abs" ]; then echo "not-regular-file"; return 1; fi
    if [ -x "$abs" ]; then echo "executable"; return 1; fi
    sz="$(wc -c < "$abs" 2>/dev/null || echo 0)"
    sz=$(( sz + 0 ))
    if [ "$sz" -lt 1 ] || [ "$sz" -gt "$ENTRY_MAX_BYTES" ]; then echo "size-out-of-bounds"; return 1; fi
    m="$(_ac_mtime "$abs")"
    case "$m" in ''|*[!0-9]*) echo "mtime-unreadable"; return 1 ;; esac
    now="$(date +%s)"
    age=$(( now - m ))
    # A future mtime (negative age) is NOT quiescent.
    if [ "$age" -lt 0 ] || [ "$age" -lt "$AC_QUIESCE_SECONDS" ]; then echo "not-quiescent"; return 1; fi
    if _ac_editor_artifact "$abs"; then echo "editor-artifact"; return 1; fi
    return 0
}

# Hash the file ONCE (the exact bytes that will be committed) and re-read its
# mtime afterwards: a write that landed during the hash makes it
# not-quiescent. Sets _AC_SHA. Call as a plain statement.
_ac_hash() {
    local abs="$REPO_DIR/$1" m0 m1
    m0="$(_ac_mtime "$abs")"
    _AC_SHA="$(_ac_git hash-object -w -- "$1" 2>/dev/null </dev/null || true)"
    m1="$(_ac_mtime "$abs")"
    [ -n "$_AC_SHA" ] && [ "$m0" = "$m1" ]
}

# XACA-1291-008: another entry in the same directory already uses this NNN
# slot (committed, or sitting in the worktree). Committing it would create
# the exact cross-entry collision Guard 4 exists to stop, and would then
# block every push; hold it for the author to renumber instead.
_ac_slot_collides() {
    local abs="$REPO_DIR/$1" d b slot f
    d="${abs%/*}"
    b="${abs##*/}"
    slot="${b%%-*}"
    for f in "$d/$slot"-*.md; do
        [ -e "$f" ] || continue
        [ "$f" = "$abs" ] && continue
        return 0
    done
    if _ac_git ls-tree --name-only HEAD -- "${1%/*}/" 2>/dev/null </dev/null \
        | awk -F/ -v s="$slot" -v me="$b" '{ n = $NF } index(n, s "-") == 1 && n != me && n ~ /\.md$/ { f = 1 } END { exit (f ? 0 : 1) }'; then
        return 0
    fi
    return 1
}

# NUL-byte test on a blob file (§4.3 test 2, evaluated on the committed bytes).
_ac_blob_has_nul() {
    local all nonul
    all="$(wc -c < "$1")"
    nonul="$(tr -d '\000' < "$1" | wc -c)"
    [ "$(( all + 0 ))" -ne "$(( nonul + 0 ))" ]
}

# §4.3 tests 5–7 on the blob <sha> for entry <path> of <tier>. Prints the
# hold reason on failure. The scaffold markers are EXACT strings: a bare
# `<!--` is not a test, because finished entries legitimately carry HTML
# comments inside code samples (13 measured in HEAD, design §1.4).
_ac_validate_entry_blob() {
    local sha="$1" p="$2" tier="$3" f want_id
    f="$TICK_TMP/blob.validate"
    if ! _ac_git cat-file blob "$sha" > "$f" 2>/dev/null; then echo "blob-unreadable"; return 1; fi
    if _ac_blob_has_nul "$f"; then echo "contains-nul"; return 1; fi
    if grep -qF -e '<!-- knowledge-sync: hold -->' "$f"; then echo "hold-marker"; return 1; fi
    # XACA-1291 (review): the template placeholders (K###, YYYY-MM-DD, ...)
    # are matched ONLY as the whole scaffold LINES knowledge_entry_template.md
    # emits — never as substrings. Finished, committed entries legitimately
    # discuss `YYYY-MM-DD` formats and cite `K###` in prose (6 of 1,699
    # measured), and a substring match held such an entry forever.
    if grep -qF \
        -e '<!-- Describe the symptom and root cause. -->' \
        -e '<!-- The fix, workaround, or correct approach. -->' \
        -e '<!-- What could go wrong next time if forgotten. -->' \
        -e '<!-- PREFERRED CREATION PATH' \
        "$f" \
        || LC_ALL=C grep -qE \
        -e '^id:[[:space:]]*k###-short-slug' \
        -e '^date:[[:space:]]*YYYY-MM-DD[[:space:]]*$' \
        -e '^# K###:' \
        -e '^\*\*Date:\*\*[[:space:]]*YYYY-MM-DD[[:space:]]*$' \
        -e '^\*\*Source:\*\*[[:space:]]*\[XACA-XXXX\]' \
        -e '^- K### .*\[Related entry title\]' \
        -e '^- \[XACA-XXXX\] .*Source kanban item' \
        "$f"; then
        echo "scaffold-marker"
        return 1
    fi
    want_id="${p##*/}"
    want_id="${want_id%.md}"
    # Values are compared RAW (trimmed, never unquoted): the tracked
    # .githooks/pre-commit compares raw values too, and the daemon must be at
    # least as strict as the hook, or a daemon-approved entry could be refused.
    awk -v want_id="$want_id" -v want_tier="$tier" '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
        BEGIN { state = 0; body = 0; reason = ""; tags_ok = 0; intags = 0 }
        NR == 1 {
            if ($0 ~ /^---[ \t\r]*$/) { state = 1; next }
            reason = "no-frontmatter"; exit
        }
        state == 1 {
            if ($0 ~ /^---[ \t\r]*$/) { state = 2; next }
            if (NR > 40) { reason = "frontmatter-unclosed"; exit }
            if (intags) {
                if ($0 ~ /^[ \t]+- [^ \t]/) { tags_ok = 1; next }
                intags = 0
            }
            if (match($0, /^[A-Za-z_][A-Za-z0-9_-]*:/)) {
                key = substr($0, 1, RLENGTH - 1)
                val = trim(substr($0, RLENGTH + 1))
                if (key == "id") fid = val
                else if (key == "tier") ftier = val
                else if (key == "date") fdate = val
                else if (key == "agent") fagent = val
                else if (key == "team") fteam = val
                else if (key == "tags") {
                    if (val == "") intags = 1
                    else if (val ~ /^\[.*\]$/) {
                        inner = substr(val, 2, length(val) - 2)
                        if (inner ~ /[^ \t]/) tags_ok = 1
                    }
                }
            }
            next
        }
        state == 2 {
            if ($0 !~ /^[ \t\r]*$/ && $0 !~ /^#/ && $0 !~ /^---[ \t\r]*$/) body++
        }
        END {
            if (reason != "") { print reason; exit 1 }
            if (state != 2) { print "frontmatter-unclosed"; exit 1 }
            if (fid != want_id) { print "id-mismatch"; exit 1 }
            if (ftier != want_tier) { print "tier-mismatch"; exit 1 }
            if (fdate !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { print "bad-date"; exit 1 }
            if (!tags_ok) { print "tags-empty"; exit 1 }
            if (want_tier == "agent" && fagent == "") { print "agent-empty"; exit 1 }
            if (want_tier == "team" && fteam == "") { print "team-empty"; exit 1 }
            if (body < 3) { print "body-empty"; exit 1 }
        }
    ' "$f"
}

# INDEX reference extractor (design §1.7): the two measured forms,
# '**File:** `x.md`' and '](./x.md)'. Refs resolve in the INDEX's own dir.
_ac_refs() {
    local f
    f="$(cat)"
    {
        # shellcheck disable=SC2016  # the backticks are literal INDEX markdown, not command substitution
        printf '%s\n' "$f" | sed -n 's/^\*\*File:\*\* `\([^`/][^`/]*\.md\)`.*/\1/p'
        printf '%s\n' "$f" | grep -oE '\]\(\./[^)/]+\.md\)' | sed 's/^\](\.\///; s/)$//'
    } | LC_ALL=C sort -u
}

_ac_is_quarantined() {
    [ -r "$QUARANTINE_FILE" ] || return 1
    awk -F'\t' -v s="$2" -v p="$1" '$1 == s && $2 == p { f = 1 } END { exit (f ? 0 : 1) }' "$QUARANTINE_FILE" 2>/dev/null
}

# §4.6 quarantine sidecar: self-compacting (drop lines whose path is gone or
# whose blob no longer matches the worktree), capped, atomic (tmp + mv).
# Optional $1 = file of new lines to append. Sets OUT_QUARANTINED. Returns 1
# only if the sidecar could not be written.
_ac_quarantine_refresh() {
    local add="${1:-}" line sha rest p out cur_cmp
    out="$TICK_TMP/quarantine.new"
    : > "$out"
    if [ -r "$QUARANTINE_FILE" ]; then
        while IFS= read -r line <&4; do
            [ -n "$line" ] || continue
            sha="${line%%"$_AC_TAB"*}"
            rest="${line#*"$_AC_TAB"}"
            p="${rest%%"$_AC_TAB"*}"
            [ -f "$REPO_DIR/$p" ] || continue
            [ "$(_ac_git hash-object -- "$p" 2>/dev/null </dev/null || true)" = "$sha" ] || continue
            printf '%s\n' "$line" >> "$out"
        done 4< "$QUARANTINE_FILE"
    fi
    if [ -n "$add" ] && [ -s "$add" ]; then
        cat "$add" >> "$out"
    fi
    tail -n "$QUARANTINE_MAX_LINES" "$out" > "${out}.capped" 2>/dev/null || cp "$out" "${out}.capped"
    OUT_QUARANTINED="$(_ac_count_lines "${out}.capped")"
    cur_cmp=1
    if [ -f "$QUARANTINE_FILE" ]; then
        cmp -s "${out}.capped" "$QUARANTINE_FILE" && cur_cmp=0
    elif [ ! -s "${out}.capped" ]; then
        cur_cmp=0
    fi
    [ "$cur_cmp" -eq 0 ] && return 0
    if mkdir -p "${QUARANTINE_FILE%/*}" 2>/dev/null \
        && cp "${out}.capped" "${QUARANTINE_FILE}.tmp.$$" 2>/dev/null \
        && mv "${QUARANTINE_FILE}.tmp.$$" "$QUARANTINE_FILE" 2>/dev/null; then
        return 0
    fi
    rm -f "${QUARANTINE_FILE}.tmp.$$" 2>/dev/null || true
    log "quarantine-unwritable: could not write ${QUARANTINE_FILE} — refused path(s) are held this tick and will be re-attempted once next tick"
    return 1
}

# §4.6 hook-error key: the effective pre-commit hook's content (or "none")
# plus the configured hooks directory. `--git-path` resolves the hooks
# directory setting itself, so a replaced hook changes the key. READ-ONLY:
# the daemon never sets, overrides or bypasses the hook location.
_ac_hook_key() {
    local hp hook
    hp="$(_ac_git config --get core.hooksPath 2>/dev/null || true)"
    hook="$(_ac_git rev-parse --git-path hooks/pre-commit 2>/dev/null || true)"
    case "$hook" in
        /*|'') ;;
        *) hook="$REPO_DIR/$hook" ;;
    esac
    # XACA-1291-008: hash the EFFECTIVE chain. On dispatcher hosts the
    # installed hook just execs the tracked .githooks/pre-commit, so fixing
    # the tracked hook must change the key (and end the backoff) too.
    {
        if [ -n "$hook" ] && [ -f "$hook" ]; then cat "$hook"; else printf 'none'; fi
        printf '\nhooks-dir=%s\n' "$hp"
        if [ -f "$REPO_DIR/.githooks/pre-commit" ]; then
            printf 'tracked:\n'
            cat "$REPO_DIR/.githooks/pre-commit"
        fi
    } | _ac_sha1
}

# P7: tripped while the recorded key equals the CURRENT hook's key and the
# record is < 24h old. A changed hook, or a day passing, earns ONE attempt.
_ac_hook_error_tripped() {
    local cur at_e now age
    [ -n "$AC_HOOK_ERR_KEY" ] || return 1
    cur="$(_ac_hook_key)"
    if [ "$cur" != "$AC_HOOK_ERR_KEY" ]; then
        log "autocommit-hook-changed: the pre-commit hook changed since the last hook error — making one attempt this tick"
        return 1
    fi
    at_e="$(_ac_iso_to_epoch "$AC_HOOK_ERR_AT")"
    [ -n "$at_e" ] || return 1
    now="$(date +%s)"
    age=$(( now - at_e ))
    if [ "$age" -ge 0 ] && [ "$age" -lt "$HOOK_ERROR_BACKOFF_SECONDS" ]; then
        return 0
    fi
    return 1
}

_ac_load_prior_state() {
    AC_HOOK_ERR_KEY="$(_json_field "$STATE_FILE" autocommit_hook_error_key)"
    [ "$AC_HOOK_ERR_KEY" = "null" ] && AC_HOOK_ERR_KEY=""
    AC_HOOK_ERR_AT="$(_json_field "$STATE_FILE" autocommit_hook_error_at)"
    [ "$AC_HOOK_ERR_AT" = "null" ] && AC_HOOK_ERR_AT=""
    AC_RESYNC_PENDING="$(_json_field "$STATE_FILE" autocommit_index_resync_pending)"
    [ "$AC_RESYNC_PENDING" = "null" ] && AC_RESYNC_PENDING=""
    AC_NONALLOW_FP_PREV="$(_json_field "$STATE_FILE" outbound_nonallowlisted_fingerprint)"
    [ "$AC_NONALLOW_FP_PREV" = "null" ] && AC_NONALLOW_FP_PREV=""
    # carried forward unchanged by any tick that exits before _ac_residual
    _RES_OTHER_FP="$AC_NONALLOW_FP_PREV"
    return 0
}

_ac_index_blob() {
    _ac_git ls-files -s -- "$1" 2>/dev/null </dev/null | awk 'NR == 1 { print $2 }'
}

# Real-index update for ONE path, retrying while index.lock is held.
_ac_update_real_index() {
    local i=0
    while [ "$i" -lt 5 ]; do
        if _ac_git update-index --add --cacheinfo "100644,$2,$1" >/dev/null 2>&1 </dev/null; then
            return 0
        fi
        i=$(( i + 1 ))
        sleep 1
    done
    return 1
}

# §4.5 step 9, re-run FIRST on the next tick for anything a held index.lock
# blocked (before P6, so a stale index never trips P6 permanently). The
# pre-commit blob is recovered from the parent of the last commit touching
# the path; a path a human has since changed in the index is left alone.
_ac_repair_pending_resync() {
    local item p sha head_blob cur c old still=""
    [ -n "$AC_RESYNC_PENDING" ] || return 0
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        p="${item%%=*}"
        sha="${item#*=}"
        head_blob="$(_ac_git rev-parse -q --verify "HEAD:$p" 2>/dev/null </dev/null || true)"
        [ "$head_blob" = "$sha" ] || continue
        cur="$(_ac_index_blob "$p")"
        [ "$cur" = "$sha" ] && continue
        c="$(_ac_git log -1 --format=%H -- "$p" 2>/dev/null </dev/null || true)"
        old=""
        [ -n "$c" ] && old="$(_ac_git rev-parse -q --verify "${c}^:$p" 2>/dev/null </dev/null || true)"
        if [ -z "$cur" ] || [ "$cur" = "$old" ]; then
            if ! _ac_update_real_index "$p" "$sha"; then
                still="${still:+$still;}${p}=${sha}"
            fi
        fi
    done <<EOF_PENDING
$(printf '%s\n' "$AC_RESYNC_PENDING" | tr ';' '\n')
EOF_PENDING
    if [ -n "$still" ]; then
        log "autocommit-index-resync-pending: the real index is still locked; ${still} will be repaired on a later tick"
    else
        log "autocommit-index-resynced: repaired the real index after a previously blocked resync"
    fi
    AC_RESYNC_PENDING="$still"
    return 0
}

# §4.4 OWN_AUTOCOMMIT: committer is the daemon AND the body carries both
# trailers, with THIS host. Any other commit (a human's, another host's)
# means no unwind.
_ac_all_own_ahead() {
    local list c cn body
    list="$(_ac_git rev-list "@{u}..${_unwind_head:-HEAD}" 2>/dev/null </dev/null || true)"
    [ -n "$list" ] || return 1
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        cn="$(_ac_git log -1 --format=%cn "$c" 2>/dev/null </dev/null || true)"
        [ "$cn" = "$AC_COMMITTER_NAME" ] || return 1
        body="$(_ac_git log -1 --format=%B "$c" 2>/dev/null </dev/null || true)"
        printf '%s\n' "$body" | grep -qxF "$AC_TRAILER_MARK" || return 1
        printf '%s\n' "$body" | grep -qxF "Knowledge-Sync-Host: ${AC_HOST}" || return 1
    done <<EOF_OWN
$list
EOF_OWN
    return 0
}

# Record a hold reason; log it only when (path, key, reason) is new since the
# last tick, so an abandoned stub is not re-logged every 30 minutes.
_ac_hold() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$TICK_TMP/held"
}

_ac_flush_hold_log() {
    local heldlog="${STATE_FILE%.json}.held" p reason key
    [ -f "$TICK_TMP/held" ] || : > "$TICK_TMP/held"
    LC_ALL=C sort -u "$TICK_TMP/held" > "$TICK_TMP/held.sorted"
    while IFS="$_AC_TAB" read -r p reason key <&4; do
        if [ -r "$heldlog" ] && grep -qxF "${p}${_AC_TAB}${reason}${_AC_TAB}${key}" "$heldlog" 2>/dev/null; then
            continue
        fi
        log "autocommit-held: ${p} (${reason}) — not committed; it stays local and is re-evaluated every tick"
    done 4< "$TICK_TMP/held.sorted"
    if ! cmp -s "$TICK_TMP/held.sorted" "$heldlog" 2>/dev/null; then
        if mkdir -p "${heldlog%/*}" 2>/dev/null && cp "$TICK_TMP/held.sorted" "${heldlog}.tmp.$$" 2>/dev/null; then
            mv "${heldlog}.tmp.$$" "$heldlog" 2>/dev/null || rm -f "${heldlog}.tmp.$$" 2>/dev/null || true
        fi
    fi
    return 0
}

# §4.5 INDEX coupling rule: commit an INDEX.md only when it is referentially
# closed — no ref removed, dir not human-touched, and every added ref is in
# HEAD or in this same commit. Reads $TICK_TMP/{indexcands,entries,touched},
# writes $TICK_TMP/idxset; holds go to $TICK_TMP/held.
_ac_index_rule() {
    local p sha d reason r
    : > "$TICK_TMP/idxset"
    cut -f1 "$TICK_TMP/entries" > "$TICK_TMP/entrypaths"
    while IFS="$_AC_TAB" read -r p sha <&4; do
        [ -n "$p" ] || continue
        d="${p%/INDEX.md}"
        _ac_git cat-file blob "$sha" 2>/dev/null </dev/null | _ac_refs > "$TICK_TMP/refs.new"
        if _ac_git cat-file -e "HEAD:$p" 2>/dev/null </dev/null; then
            _ac_git cat-file blob "HEAD:$p" 2>/dev/null </dev/null | _ac_refs > "$TICK_TMP/refs.old"
        else
            : > "$TICK_TMP/refs.old"
        fi
        LC_ALL=C comm -23 "$TICK_TMP/refs.new" "$TICK_TMP/refs.old" > "$TICK_TMP/refs.added"
        LC_ALL=C comm -13 "$TICK_TMP/refs.new" "$TICK_TMP/refs.old" > "$TICK_TMP/refs.removed"
        reason=""
        if [ -s "$TICK_TMP/refs.removed" ]; then
            reason="index-drops-refs"
        elif grep -qxF -- "$d" "$TICK_TMP/touched" 2>/dev/null; then
            reason="dir-human-touched"
        else
            while IFS= read -r r <&5; do
                [ -n "$r" ] || continue
                _ac_git cat-file -e "HEAD:$d/$r" 2>/dev/null </dev/null && continue
                grep -qxF -- "$d/$r" "$TICK_TMP/entrypaths" 2>/dev/null && continue
                reason="index-refs-uncommitted"
                break
            done 5< "$TICK_TMP/refs.added"
        fi
        if [ -n "$reason" ]; then
            _ac_hold "$p" "$reason" "$sha"
        else
            printf '%s\t%s\n' "$p" "$sha" >> "$TICK_TMP/idxset"
        fi
    done 4< "$TICK_TMP/indexcands"
    return 0
}

# _ac_run_hook <name> <temp-index> [args...] — run the repo's EFFECTIVE hook
# exactly the way `git commit` would: resolved through `rev-parse --git-path
# hooks/<name>` (so core.hooksPath / dispatcher layouts are honoured), only if
# it is an executable file, from the worktree top, with GIT_INDEX_FILE pointing
# at the index being committed. Output is appended to AC_COMMIT_OUT. There is
# no way to skip it: the function has no bypass argument, and every commit
# attempt calls it (XACA-1291 §4.6 — hooks always run).
_ac_run_hook() {
    local name="$1" ti="$2" hook out rc
    shift 2
    hook="$(_ac_git rev-parse --git-path "hooks/$name" 2>/dev/null </dev/null || true)"
    case "$hook" in
        /*|'') ;;
        *) hook="$REPO_DIR/$hook" ;;
    esac
    if [ -z "$hook" ] || [ ! -f "$hook" ] || [ ! -x "$hook" ]; then
        return 0
    fi
    out="$(cd "$REPO_DIR" && GIT_INDEX_FILE="$ti" GIT_EDITOR=: "$hook" "$@" 2>&1 </dev/null)"
    rc=$?
    if [ -n "$out" ]; then
        AC_COMMIT_OUT="${AC_COMMIT_OUT}${out}
"
    fi
    return "$rc"
}

# One commit attempt. Returns:
#   0 committed, landed and verified
#   1 refused by a hook, >=1 path attributed ($TICK_TMP/attributed)
#   2 nothing to commit        3 could not build the temp index / tree
#   4 landed but verify failed — ROLLED BACK (compare-and-swap), nothing kept
#   5 lost the race: HEAD moved while we were building/hooking — nothing landed
#   6 unattributed refusal (hook error, signing failure, ...)
#
# XACA-1291-008 (race fix). The commit is built on a pre_head captured FIRST
# and seeded into the temp index with `read-tree "$pre_head"`; the hooks run
# against that index; the commit object is made with `commit-tree -p
# "$pre_head"`; and it lands ONLY via `update-ref HEAD <new> <pre_head>`, which
# git refuses atomically if the branch moved. A human commit that lands at ANY
# point in the attempt therefore makes us lose cleanly (rc 5) instead of the
# old failure mode, where `git commit` parented our tree — built from the OLD
# HEAD — onto the human's new commit and silently reverted their change.
_ac_commit_attempt() {
    local n="$1" ti msg name email ne ni word subj p sha pre_head line tree new bad=0 refused=0
    ti="$TICK_TMP/index.$n"
    msg="$TICK_TMP/msg.$n"
    : > "$TICK_TMP/attributed"
    AC_COMMIT_OUT=""
    cat "$TICK_TMP/entries" "$TICK_TMP/idxset" > "$TICK_TMP/commitlist"
    [ -s "$TICK_TMP/commitlist" ] || return 2

    pre_head="$(_ac_git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null </dev/null || true)"
    [ -n "$pre_head" ] || return 3
    AC_PRE_HEAD="$pre_head"

    # Env is a per-command prefix ONLY. GIT_INDEX_FILE is never exported:
    # push, reset and status later in this tick must see the REAL index.
    GIT_INDEX_FILE="$ti" _ac_git read-tree "$pre_head" >/dev/null 2>&1 </dev/null || return 3
    while IFS="$_AC_TAB" read -r p sha <&4; do
        GIT_INDEX_FILE="$ti" _ac_git update-index --add --cacheinfo "100644,$sha,$p" >/dev/null 2>&1 </dev/null || bad=1
    done 4< "$TICK_TMP/commitlist"
    [ "$bad" -eq 0 ] || return 3
    if GIT_INDEX_FILE="$ti" _ac_git diff --cached --quiet "$pre_head" -- 2>/dev/null </dev/null; then
        return 2
    fi

    ne="$(_ac_count_lines "$TICK_TMP/entries")"
    ni="$(_ac_count_lines "$TICK_TMP/idxset")"
    word="entries"
    [ "$ne" -eq 1 ] && word="entry"
    subj="knowledge-sync: auto-commit ${ne} ${word}"
    [ "$ni" -gt 0 ] && subj="${subj} + ${ni} INDEX"
    subj="${subj} from ${AC_HOST}"
    {
        printf '%s\n\n' "$subj"
        cut -f1 "$TICK_TMP/commitlist" | LC_ALL=C sort
        printf '\n%s\nKnowledge-Sync-Host: %s\n' "$AC_TRAILER_MARK" "$AC_HOST"
    } > "$msg"

    # Hooks RUN, in git commit's order. The daemon never skips, disables or
    # re-points them.
    if ! _ac_run_hook pre-commit "$ti"; then
        refused=1
    elif ! _ac_run_hook prepare-commit-msg "$ti" "$msg" message; then
        refused=1
    elif ! _ac_run_hook commit-msg "$ti" "$msg"; then
        refused=1
    fi
    if [ "$refused" -eq 1 ]; then
        # Attribution: a COMMIT_SET path named on a [FAIL]/[BLOCK] line (the
        # installed and tracked hook formats respectively).
        while IFS="$_AC_TAB" read -r p sha <&4; do
            line="$(printf '%s\n' "$AC_COMMIT_OUT" | grep -F -e '[FAIL]' -e '[BLOCK]' | grep -F -- "$p" | head -1)"
            if [ -n "$line" ]; then
                printf '%s\t%s\t%s\t%s\n' "$sha" "$p" "$(_now_iso)" "$(printf '%s' "$line" | tr '\t\n' '  ')" >> "$TICK_TMP/attributed"
            fi
        done 4< "$TICK_TMP/commitlist"
        [ -s "$TICK_TMP/attributed" ] && return 1
        return 6
    fi

    # A pre-commit hook may legitimately rewrite the index it was given (a
    # formatter); like `git commit`, the tree is taken AFTER the hooks.
    tree="$(GIT_INDEX_FILE="$ti" _ac_git write-tree 2>/dev/null </dev/null || true)"
    [ -n "$tree" ] || return 3
    _ac_git stripspace < "$msg" > "${msg}.clean" 2>/dev/null || cp "$msg" "${msg}.clean"
    name="$(_ac_git config --get user.name 2>/dev/null || true)"
    email="$(_ac_git config --get user.email 2>/dev/null || true)"
    new="$(GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" \
        GIT_COMMITTER_NAME="$AC_COMMITTER_NAME" GIT_COMMITTER_EMAIL="knowledge-sync@${AC_HOST}.local" \
        git -C "$REPO_DIR" commit-tree "$tree" -p "$pre_head" -F "${msg}.clean" 2>"$TICK_TMP/commit-tree.err" </dev/null)"
    if [ -z "$new" ]; then
        AC_COMMIT_OUT="${AC_COMMIT_OUT}$(cat "$TICK_TMP/commit-tree.err" 2>/dev/null)"
        return 6
    fi

    # Land it — compare-and-swap on the branch. Refused if HEAD moved.
    if ! _ac_git update-ref -m "commit: ${subj}" HEAD "$new" "$pre_head" >/dev/null 2>"$TICK_TMP/update-ref.err" </dev/null; then
        AC_COMMIT_OUT="${AC_COMMIT_OUT}$(cat "$TICK_TMP/update-ref.err" 2>/dev/null)"
        return 5
    fi

    # §4.5 step 8, belt and braces: our commit sits directly on pre_head and
    # carries exactly the validated blobs. If not, roll back (again by CAS).
    if [ "$(_ac_git rev-parse -q --verify 'HEAD^' 2>/dev/null </dev/null || true)" != "$pre_head" ]; then
        bad=1
    fi
    while IFS="$_AC_TAB" read -r p sha <&4; do
        if [ "$(_ac_git rev-parse -q --verify "HEAD:$p" 2>/dev/null </dev/null || true)" != "$sha" ]; then
            bad=1
        fi
    done 4< "$TICK_TMP/commitlist"
    if [ "$bad" -ne 0 ]; then
        _ac_git update-ref -m "knowledge-sync: roll back unverified auto-commit" HEAD "$pre_head" "$new" >/dev/null 2>&1 </dev/null || true
        return 4
    fi

    # post-commit, like git: its exit status is ignored.
    _ac_run_hook post-commit "$ti" || true
    return 0
}

# §4.5 step 9: move the REAL index forward for our paths, but only where it
# still holds the pre-commit state. A path a human re-staged after P6 wins.
_ac_resync_real_index() {
    local p sha cur pre pending=""
    while IFS="$_AC_TAB" read -r p sha <&4; do
        cur="$(_ac_index_blob "$p")"
        pre="$(_ac_git rev-parse -q --verify "${AC_PRE_HEAD}:$p" 2>/dev/null </dev/null || true)"
        if [ -z "$cur" ] || [ "$cur" = "$pre" ]; then
            if ! _ac_update_real_index "$p" "$sha"; then
                pending="${pending:+$pending;}${p}=${sha}"
            fi
        fi
    done 4< "$TICK_TMP/commitlist"
    if [ -n "$pending" ]; then
        log "autocommit-index-resync-pending: the real index was locked after the commit; it will be repaired first next tick (${pending})"
        AC_RESYNC_PENDING="${AC_RESYNC_PENDING:+$AC_RESYNC_PENDING;}${pending}"
    fi
    return 0
}

# §4.5 AUTOCOMMIT. Precondition P2 (converged) and P3 (0 behind) are the
# caller's; P1 and P4–P8 are checked here. Sets AC_RESULT to one of:
# none | committed | refused | hook-error | deferred-staged |
# deferred-git-busy | no-identity | disabled.
_ac_autocommit() {
    local rec xy p cls reason attempt rc ntrunc name email
    AC_RESULT="none"
    AC_Q_SKIPPED=0

    if ! _ac_enabled; then
        AC_RESULT="disabled"
        log "autocommit-disabled: kill switch is on (KB_KNOWLEDGE_SYNC_AUTOCOMMIT=0 or ${AC_SENTINEL}) — local entries are not being shared"
        return 0
    fi
    if _ac_git_busy; then
        AC_RESULT="deferred-git-busy"
        log "autocommit-deferred-git-busy: ${_AC_BUSY_WHY} present in ${GIT_DIR} — a git operation is in progress; not committing this tick"
        return 0
    fi
    if ! _ac_git symbolic-ref -q HEAD >/dev/null 2>&1; then
        AC_RESULT="deferred-git-busy"
        log "autocommit-deferred-git-busy: HEAD is detached in ${REPO_DIR} — not committing this tick"
        return 0
    fi
    if ! _ac_git diff --cached --quiet 2>/dev/null </dev/null; then
        AC_RESULT="deferred-staged"
        log "autocommit-deferred-staged: a human has changes staged in ${REPO_DIR} — the daemon stays out of the whole repo this tick"
        return 0
    fi
    if _ac_hook_error_tripped; then
        AC_RESULT="hook-error"
        log "autocommit-hook-error: the pre-commit hook failed without naming an entry at ${AC_HOOK_ERR_AT} and has not changed since — backing off (one retry per 24h). Fix the hook (install the tracked .githooks/pre-commit); the daemon never bypasses it"
        return 0
    fi
    name="$(_ac_git config --get user.name 2>/dev/null || true)"
    email="$(_ac_git config --get user.email 2>/dev/null || true)"
    if [ -z "$name" ] || [ -z "$email" ]; then
        AC_RESULT="no-identity"
        log "autocommit-no-identity: git user.name/user.email not configured for ${REPO_DIR} — cannot author an auto-commit"
        return 0
    fi
    if ! _ac_tmp; then
        AC_RESULT="deferred-git-busy"
        log "autocommit-deferred-git-busy: could not create a scratch directory under ${TMPDIR:-/tmp}"
        return 0
    fi

    # 1. candidates, straight from git status (NUL-separated; bash 3.2 read -d '').
    : > "$TICK_TMP/cands"
    : > "$TICK_TMP/touched"
    : > "$TICK_TMP/entries"
    : > "$TICK_TMP/indexcands"
    : > "$TICK_TMP/held"
    if ! _ac_git status --porcelain=v1 -z --untracked-files=all --no-renames > "$TICK_TMP/status" 2>/dev/null </dev/null; then
        AC_RESULT="deferred-git-busy"
        log "autocommit-deferred-git-busy: git status failed in ${REPO_DIR}"
        return 0
    fi
    while IFS= read -r -d '' rec; do
        xy="${rec:0:2}"
        p="${rec:3}"
        cls="$(_ac_classify "$p")"
        [ -n "$cls" ] || continue
        case "$xy" in
            '??'|' M') printf '%s\t%s\n' "$p" "$cls" >> "$TICK_TMP/cands" ;;
            *) printf '%s\n' "${p%/*}" >> "$TICK_TMP/touched"
               _ac_hold "$p" "human-touched-${xy// /_}" "status" ;;
        esac
    done < "$TICK_TMP/status"
    LC_ALL=C sort -u "$TICK_TMP/cands" > "$TICK_TMP/cands.sorted"
    ntrunc="$(_ac_count_lines "$TICK_TMP/cands.sorted")"
    if [ "$ntrunc" -gt "$AUTOCOMMIT_MAX_PATHS" ]; then
        log "autocommit-truncated: ${ntrunc} candidates this tick; evaluating the first ${AUTOCOMMIT_MAX_PATHS} in sorted order, the rest next tick"
        head -n "$AUTOCOMMIT_MAX_PATHS" "$TICK_TMP/cands.sorted" > "$TICK_TMP/cands"
    else
        cp "$TICK_TMP/cands.sorted" "$TICK_TMP/cands"
    fi

    # 2. hash + validate on the blob.
    while IFS="$_AC_TAB" read -r p cls <&4; do
        [ -n "$p" ] || continue
        if ! reason="$(_ac_precheck "$p")"; then
            _ac_hold "$p" "$reason" "mtime:$(_ac_mtime "$REPO_DIR/$p")"
            continue
        fi
        if [ "$cls" != "index" ] && _ac_slot_collides "$p"; then
            _ac_hold "$p" "slot-collision" "mtime:$(_ac_mtime "$REPO_DIR/$p")"
            continue
        fi
        if ! _ac_hash "$p"; then
            _ac_hold "$p" "not-quiescent" "mtime:$(_ac_mtime "$REPO_DIR/$p")"
            continue
        fi
        if _ac_is_quarantined "$p" "$_AC_SHA"; then
            AC_Q_SKIPPED=$(( AC_Q_SKIPPED + 1 ))
            _ac_hold "$p" "quarantined" "$_AC_SHA"
            continue
        fi
        if [ "$cls" = "index" ]; then
            _ac_git cat-file blob "$_AC_SHA" > "$TICK_TMP/blob.index" 2>/dev/null </dev/null
            if _ac_blob_has_nul "$TICK_TMP/blob.index"; then
                _ac_hold "$p" "contains-nul" "$_AC_SHA"
                continue
            fi
            printf '%s\t%s\n' "$p" "$_AC_SHA" >> "$TICK_TMP/indexcands"
            continue
        fi
        if ! reason="$(_ac_validate_entry_blob "$_AC_SHA" "$p" "${cls#entry }")"; then
            _ac_hold "$p" "${reason:-invalid}" "$_AC_SHA"
            continue
        fi
        printf '%s\t%s\n' "$p" "$_AC_SHA" >> "$TICK_TMP/entries"
    done 4< "$TICK_TMP/cands"

    # 3–7. INDEX rule, temp index, commit; at most COMMIT_ATTEMPTS_PER_TICK
    # attempts, each with a strictly smaller path set.
    attempt=1
    while [ "$attempt" -le "$COMMIT_ATTEMPTS_PER_TICK" ]; do
        _ac_index_rule
        _ac_commit_attempt "$attempt"
        rc=$?
        case "$rc" in
            0)
                [ "$AC_RESULT" = "refused" ] || AC_RESULT="committed"
                AC_HOOK_ERR_KEY=""
                AC_HOOK_ERR_AT=""
                log "autocommit: $(head -1 "$TICK_TMP/msg.$attempt") as $(_ac_git rev-parse --short HEAD 2>/dev/null </dev/null)"
                log_block "autocommit path" "$(cut -f1 "$TICK_TMP/commitlist" | LC_ALL=C sort)"
                _ac_resync_real_index
                break
                ;;
            1)
                AC_RESULT="refused"
                log "autocommit-refused: the pre-commit hook refused attempt ${attempt}; quarantining the named entr(y|ies) by content hash (an edit releases them)"
                log_block "hook output" "$(printf '%s\n' "$AC_COMMIT_OUT" | head -20)"
                if ! _ac_quarantine_refresh "$TICK_TMP/attributed"; then
                    :   # held this tick; re-attempted once next tick (still bounded)
                fi
                cut -f2 "$TICK_TMP/attributed" > "$TICK_TMP/attributed.paths"
                while IFS="$_AC_TAB" read -r _q_sha p _q_rest; do
                    _ac_hold "$p" "hook-refused" "$_q_sha"
                done < "$TICK_TMP/attributed"
                awk -F'\t' 'NR == FNR { drop[$1] = 1; next } !($1 in drop)' "$TICK_TMP/attributed.paths" "$TICK_TMP/entries" > "$TICK_TMP/entries.next"
                mv "$TICK_TMP/entries.next" "$TICK_TMP/entries"
                awk -F'\t' 'NR == FNR { drop[$1] = 1; next } !($1 in drop)' "$TICK_TMP/attributed.paths" "$TICK_TMP/indexcands" > "$TICK_TMP/indexcands.next"
                mv "$TICK_TMP/indexcands.next" "$TICK_TMP/indexcands"
                attempt=$(( attempt + 1 ))
                ;;
            2)
                break
                ;;
            3)
                AC_RESULT="deferred-git-busy"
                log "autocommit-deferred-git-busy: could not build the private temp index — not committing this tick"
                break
                ;;
            4)
                AC_RESULT="deferred-git-busy"
                AC_NO_PUSH=1
                log "autocommit-verify-failed: the landed commit did not carry exactly the validated blobs on the expected parent — rolled back, NOT pushing this tick, retrying next tick"
                break
                ;;
            5)
                AC_RESULT="deferred-git-busy"
                AC_NO_PUSH=1
                log "autocommit-lost-race: HEAD moved while the auto-commit was being built (a concurrent commit) — nothing landed, the real index is untouched, NOT pushing this tick; retrying next tick on top of the new HEAD"
                log_block "git output" "$(printf '%s\n' "$AC_COMMIT_OUT" | head -20)"
                break
                ;;
            *)
                AC_RESULT="hook-error"
                AC_HOOK_ERR_KEY="$(_ac_hook_key)"
                AC_HOOK_ERR_AT="$(_now_iso)"
                log "autocommit-hook-error: the commit was refused but no entry was named (a broken hook, a signing failure, or another environment fault). No entry is quarantined. Backing off: one retry per 24h or when the hook changes. The daemon never bypasses the hook — fix it (install the tracked .githooks/pre-commit)."
                log_block "git commit output" "$(printf '%s\n' "$AC_COMMIT_OUT" | head -20)"
                break
                ;;
        esac
    done
    _ac_flush_hold_log
    return 0
}

# Residual dirt after the tick's commit (design §5.2 outbound_withheld_paths):
# everything still dirty, split into allowlisted (held/incomplete) and
# non-allowlisted. Sets OUT_WITHHELD_PATHS (ALLOWLISTED only), _RES_ALLOWED,
# _RES_OTHER and _RES_OTHER_FP (a fingerprint of the non-allowlisted paths
# AND their current bytes, for the once-per-change informational log).
#
# XACA-1291 (review): a non-allowlisted dirty path (e.g. projects/…/INDEX.md,
# permanent on M3Pro) is NOT withheld outbound — the daemon never commits
# outside its allowlist by design, so counting it made OUTBOUND-STUCK alarm
# forever on a state no tick can change. It is reported, not counted.
_ac_residual() {
    local rec p h
    OUT_WITHHELD_PATHS=0
    _RES_ALLOWED=0
    _RES_OTHER=0
    _RES_OTHER_FP=""
    _ac_tmp || return 0
    _ac_git status --porcelain=v1 -z --untracked-files=all --no-renames > "$TICK_TMP/status.post" 2>/dev/null </dev/null || return 0
    : > "$TICK_TMP/residual.other"
    while IFS= read -r -d '' rec; do
        p="${rec:3}"
        if [ -n "$(_ac_classify "$p")" ]; then
            _RES_ALLOWED=$(( _RES_ALLOWED + 1 ))
            OUT_WITHHELD_PATHS=$(( OUT_WITHHELD_PATHS + 1 ))
        else
            _RES_OTHER=$(( _RES_OTHER + 1 ))
            h="-"
            [ -f "$REPO_DIR/$p" ] && h="$(_ac_git hash-object -- "$p" 2>/dev/null </dev/null || echo "?")"
            printf '%s\t%s\t%s\n' "${rec:0:2}" "$p" "$h" >> "$TICK_TMP/residual.other"
        fi
    done < "$TICK_TMP/status.post"
    if [ "$_RES_OTHER" -gt 0 ]; then
        _RES_OTHER_FP="$(LC_ALL=C sort "$TICK_TMP/residual.other" | _ac_sha1)"
    fi
    return 0
}

# Informational, once per CONTENT change (not per tick): non-allowlisted dirt.
_ac_report_nonallowlisted() {
    [ "$_RES_OTHER" -gt 0 ] || return 0
    [ "$_RES_OTHER_FP" = "$AC_NONALLOW_FP_PREV" ] && return 0
    log "outbound-nonallowlisted-info: ${_RES_OTHER} dirty path(s) in ${REPO_DIR} are outside the auto-commit allowlist and are NOT counted as withheld. The daemon never commits outside agents/, subjects/ and teams/ entries + INDEX.md, so a human commits these by hand (logged once per content change):"
    log_block "non-allowlisted dirty paths" "$(cut -f1,2 "$TICK_TMP/residual.other" | LC_ALL=C sort | head -50)"
    return 0
}

# XACA-1291 (review): phantom-deletion push guard. If the real-index resync
# after an auto-commit is blocked (index.lock held), the real index still
# lacks the entry the daemon just committed. A human `git commit` in that gap
# records the entry as DELETED although the file is on disk. The outgoing
# NET diff (@{u}..HEAD) is the only thing a push changes on the fleet, so it
# is checked directly, whatever the timing: an allowlisted path the push
# would delete while the file still exists here is a stale-index artifact,
# never an intended deletion (a real `git rm` removes the file too). While
# any such path exists, nothing is pushed; the next auto-commit re-adds the
# file, the net deletion disappears, and the push resumes by itself.
# Fail CLOSED: if the diff cannot be computed, report it and do not push.
_ac_phantom_deletions() {
    local p
    _PHANTOM_DEL=""
    if ! _ac_tmp; then _PHANTOM_DEL="(scratch dir unavailable)"; return 0; fi
    if ! _ac_git diff --name-only -z --no-renames --diff-filter=D '@{u}' HEAD > "$TICK_TMP/outgoing.del" 2>/dev/null </dev/null; then
        _PHANTOM_DEL="(outgoing diff failed)"
        return 0
    fi
    while IFS= read -r -d '' p; do
        [ -n "$(_ac_classify "$p")" ] || continue
        [ -e "$REPO_DIR/$p" ] || continue
        _PHANTOM_DEL="${_PHANTOM_DEL:+$_PHANTOM_DEL, }$p"
    done < "$TICK_TMP/outgoing.del"
    [ -n "$_PHANTOM_DEL" ]
}

_ac_counts() {
    _AHEAD="$(git -C "$REPO_DIR" rev-list --count '@{u}..HEAD' 2>/dev/null || true)"
    case "$_AHEAD" in ''|*[!0-9]*) _AHEAD=0 ;; esac
    _BEHIND="$(git -C "$REPO_DIR" rev-list --count 'HEAD..@{u}' 2>/dev/null || true)"
    case "$_BEHIND" in ''|*[!0-9]*) _BEHIND=0 ;; esac
}

# ── Guard 3: quiescent-tree detection + fetch/integrate (XACA-1266) ─────────
# We never stash: a dirty tree here means a human is mid-edit (knowledge
# commits are authored via kb-knowledge-add), and stashing someone else's
# in-flight work behind their back is exactly the kind of "clever" surprise
# this daemon must never pull. That invariant is now enforced by git itself
# (see the XACA-1266 header comment above) rather than by refusing to act
# at all — a dirty tree no longer skips the sync, it changes HOW we
# integrate.
GIT_DIR="$(git -C "$REPO_DIR" rev-parse --absolute-git-dir 2>/dev/null || true)"
if [ -z "$GIT_DIR" ]; then
    log "no-op-not-a-repo: could not resolve git-dir for ${REPO_DIR} — exiting"
    exit 0
fi

if [ -d "${GIT_DIR}/rebase-merge" ] || [ -d "${GIT_DIR}/rebase-apply" ] || [ -f "${GIT_DIR}/MERGE_HEAD" ]; then
    log "skipped-rebase-in-progress: ${REPO_DIR} already has a rebase or merge in progress — leaving it for a human"
    exit 0
fi

# XACA-1291 §4.5 step 9 (deferred half): carry the hook-error key and any
# blocked real-index resync forward from the last tick, and repair the
# latter FIRST — before the dirty check and before P6 — so a stale index left
# by a held index.lock can never read as "a human staged something" forever.
_ac_load_prior_state
if [ -n "$AC_RESYNC_PENDING" ] && [ ! -e "${GIT_DIR}/index.lock" ]; then
    _ac_repair_pending_resync
fi

# Dirty flag only — no longer an exit. Selects the integrate strategy below.
_dirty="$(git -C "$REPO_DIR" status --porcelain 2>&1)"

PRE_SYNC_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"

# No upstream configured (e.g. a detached clone, or a fixture repo without a
# tracking branch set up) — nothing to fetch or integrate against; no-op
# cleanly. Moved AHEAD of the dirty branch below (XACA-1266 design §3.1):
# fetching requires an upstream, and the new unconditional fetch has to run
# before we decide how to integrate.
if ! git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    log "no-op-no-upstream: ${REPO_DIR} has no upstream tracking branch configured — nothing to sync"
    exit 0
fi

# ── Step: fetch (unconditional — this is the fix) ────────────────────────────
# Measured (design doc §2, 002 §1.1): fetch touches neither the working
# tree, the index, nor HEAD. There is no dirty-tree hazard here, which is
# exactly why gating it behind the old dirty-check bought nothing except a
# stall — on M3Pro the fetch step did not execute once in 38 consecutive
# ticks, because the old guard exited before ever reaching it.
log "fetching: git -C ${REPO_DIR} fetch"
FETCH_OUTPUT="$(git -C "$REPO_DIR" fetch 2>&1)"
FETCH_EXIT=$?

if [ "$FETCH_EXIT" -ne 0 ]; then
    log "fetch-failed: git fetch failed in ${REPO_DIR} (offline / no auth / remote unreachable?) — refs, HEAD, and tree all unchanged; will retry next tick"
    log_block "git fetch output" "$FETCH_OUTPUT"
    _update_notify_state "fetch-failed" "outbound-not-attempted" "" ""
    exit 0
fi

# ── Guard 4 helpers: post-merge duplicate ID-slot gate (XACA-0818 fleet backstop) ─
# The per-directory allocation lock added to kb-knowledge-add/-promote in
# XACA-0818 serializes writers WITHIN one host, but it cannot stop two DIFFERENT
# hosts from each allocating the same NNN slot offline and then git-merging both
# entries cleanly (distinct slug filenames => no git conflict, two files silently
# sharing e.g. k004). A fast-forward — clean-tree rebase or dirty-tree ff-only —
# is exactly where such a cross-host collision materializes. Surface it
# immediately as a HARD, loud failure so the colliding state is never pushed
# onward to the rest of the fleet. Factored into functions (XACA-1266) because
# there are now TWO successful-integration call sites (clean rebase, dirty
# fast-forward) that both need it, where before there was only one.
#
# This mirrors the "Duplicate ID slots within one tier dir" check in
# kb-knowledge-validate (XACA-0802) — reimplemented inline here rather than
# invoking that zsh function, to keep this bash daemon dependency-light and to
# gate ONLY on slot collisions (not the validator's unrelated frontmatter/xref
# checks, which must never turn a benign sync into a failure). Like the Guard 1b
# PII-containment abort above, this is a deliberate exception to the script's
# otherwise exit-0-always contract: a data collision is a genuine defect, not an
# ordinary git/network condition. We do NOT auto-remediate — renumbering entries
# is the operator's call (see the XACA-0818 remediation).
#
# XACA-1291-008 (scope): the scan reads the COMMITTED tree (HEAD), not the
# working tree. The gate's job is "never push a colliding state onward", and
# only committed content can be pushed. Scanning the worktree made a LOCAL,
# UNTRACKED half-entry that happened to share a slot block every push forever
# (exit 65, nothing in notify state) now that push no longer needs a clean
# tree. A local collision is the author's in-progress state: kb-knowledge-
# validate reports it, and the auto-commit refuses to commit INTO a
# collision (hold reason slot-collision), so the daemon never manufactures a
# committed one either.
# XACA-1291-024 (live performance defect, first real tick post-merge,
# 2026-09-22): the per-file `while read ... | sed -n '...'` shape above
# forked TWO processes (a `printf` subshell + a `sed`) per candidate file.
# Measured live against the real ~/knowledge (2,301 .md files) on M-series
# hardware at LaunchAgent Nice 15 / LowPriorityIO: still inside this loop
# 7+ minutes after the tick's commit landed, sampled mid-stall waiting on
# the per-file sed forks. `_check_dup_slots` runs at up to 3 call sites per
# tick (successful clean-rebase integration, successful dirty fast-forward,
# and again for the same two paths further down), so the fork storm could
# repeat multiple times in one tick.
#
# Replaced with a SINGLE awk process reading `git ls-tree`'s output once,
# doing the basename/dir split and the slot-prefix match inline (POSIX
# awk only — match()/substr(), no gawk-only 3-arg match() or {n,m} interval
# needed, so this runs unmodified under macOS's /usr/bin/awk, the "one true
# awk" derivative the LaunchAgent actually executes under). Semantics are
# byte-identical to the old per-file loop (proven by
# tests/test-xaca-1291-dup-slots-perf-equivalence.sh, which keeps the retired
# implementation as a literal reference and diffs both against fixtures AND
# a read-only clone of the real ~/knowledge):
#   - only *.md files, INDEX.md excluded
#   - dir = the path up to the last "/", prefixed with "$REPO_DIR/" exactly
#     as before (so collision output text is unchanged)
#   - slot = the leading lowercase-letter + THREE-OR-MORE-digit prefix
#     immediately before a literal "-" (k004, t001, k1000, … — XACA-1155's
#     "3 digits or more", not exactly 3)
#   - identical collision line format: "<dir>  slot=<slot>  collides:
#     <first> + <this>"
#
# NUL-delimited, quoting-proof (XACA-1291-025). An earlier revision of this
# rewrite read `git ls-tree -r --name-only HEAD` WITHOUT -z, reasoning that
# the allocator's slug grammar keeps every legitimate name plain ASCII. That
# was the wrong premise: the grammar constrains the BASENAME, not the
# directory (agents/zoë/…), and it constrains the allocator, not a hand-made
# or cross-host file. Without -z git C-quotes any path containing non-ASCII
# bytes (core.quotePath, default true), `"` or `\` — e.g. "agents/zo\303\253/
# k001-a.md", WITH the surrounding quotes — so the quoted form fails the slot
# match and the file vanishes from the scan. Measured on the equivalence
# suite's PART D fixture: -z finds all 6 collisions, the non-z version 1 (4
# with core.quotePath=false), so the daemon would push a duplicate onward
# instead of exiting 65. With -z, git emits the raw bytes and
# core.quotePath has no effect at all.
#
# NUL -> record separator: POSIX awk (and macOS's /usr/bin/awk) cannot use
# NUL as RS, so `tr '\n\0' '\001\n'` first maps any literal NEWLINE inside a
# path to \001, then each NUL terminator to a newline. The one path shape
# that would otherwise be lost — a filename containing a newline — therefore
# stays ONE record, keeps its dir/slot, and is counted like any other file
# (conservative: it can only ADD a collision, never hide one or split into a
# phantom second record). It is displayed with "\n" in place of the byte.
# (The retired per-file loop silently skipped such a basename; this is a
# deliberate strict improvement, pinned by the equivalence suite's
# newline case.) A genuine \001 byte in a path displays as "\n" too —
# cosmetic only; grouping uses the unmodified bytes.
# LC_ALL=C makes awk byte-oriented: no multibyte decoding of non-UTF-8 names,
# and [a-z] means exactly ASCII a-z whatever the host locale.
#
# XACA-1291-028: LC_ALL=C must pin EVERY stage, not just awk. An earlier
# revision pinned only awk, leaving `tr` in the CALLER's locale. macOS/BSD
# `tr` decodes its input as characters, so under ANY UTF-8 locale
# (LANG/LC_CTYPE/LC_ALL = en_US.UTF-8, C.UTF-8) it aborts with "Illegal byte
# sequence" at the FIRST byte in the stream that is not valid UTF-8 —
# anywhere in the tree, including inside a non-.md filename that the scan
# would have skipped anyway. Everything at or after that byte in tree order
# is then lost. Measured on the PART F fixture: under en_US.UTF-8 the
# unpinned pipeline found 2 of 5 collisions (0 of 5 when the bad byte sorts
# first) and reported them as a CLEAN scan, so the daemon would push the
# duplicate onward instead of exiting 65. Such a path cannot be created on
# APFS, but it can be in a TREE that a Linux host committed and this host
# fetched — and `ls-tree` reads the tree, not the worktree. The LaunchAgent
# sets no LANG so the daemon itself has always been on the C path, but
# docs/knowledge-sync-daemon.md tells humans to run this script by hand,
# which inherits their LANG.
#
# MEASURED (XACA-1291-028), so nobody has to re-derive it: `git ls-tree -r -z
# --name-only HEAD` is byte-identical under C, en_US.UTF-8 and C.UTF-8, with
# an invalid-UTF-8 path present, and `core.quotePath` has no effect under -z
# — git writes the tree's raw path bytes with no transcoding. The LC_ALL=C on
# the git stage below is therefore belt-and-braces (it pins the whole
# pipeline so the invariant is obvious and survives a future git), NOT the
# fix; `tr` is where the locale actually bit.
#
# FAIL LOUD, never silently empty (XACA-1291-028). Before this, a failure of
# ANY stage produced an empty $_DUP_SLOTS_FOUND — byte-identical to "no
# collisions found" — so a broken scan read as a clean bill of health and the
# push proceeded. That is the same fail-open family this ticket keeps hitting.
# Two guards, both cheap, close it:
#   1. The pipeline's exit status. `set -o pipefail` is on script-wide (see
#      the top of this file), so the command substitution's status is the
#      rightmost non-zero stage — this catches a failed `git ls-tree` (unborn
#      HEAD, corrupt object store), a failed `tr`, and a failed `awk` alike.
#   2. An END sentinel carrying awk's record count. If the sentinel line is
#      absent, awk did not reach END (killed, truncated, syntax error) and the
#      output cannot be trusted even at rc 0. If it says 0 records while HEAD's
#      tree is NOT empty, the stream was lost somewhere upstream.
# Either guard sets $_DUP_SLOTS_SCAN_ERROR, which _handle_dup_slots_fatal
# turns into the same loud exit 65 as a real collision: a gate that could not
# run certifies nothing, so it must refuse to push rather than wave the tick
# through. The "0 paths" probe runs ONLY on the already-suspicious path, so
# the happy path pays nothing for it.
_check_dup_slots() {
    _DUP_SLOTS_FOUND=""
    _DUP_SLOTS_SCAN_ERROR=""
    _dup_raw="$(
        LC_ALL=C git -C "$REPO_DIR" ls-tree -r -z --name-only HEAD 2>/dev/null \
        | LC_ALL=C tr '\n\0' '\001\n' \
        | LC_ALL=C awk -v repo="$REPO_DIR" '
            BEGIN { nl = sprintf("%c", 1) }
            {
                path = $0
                slash = 0
                for (i = length(path); i >= 1; i--) {
                    if (substr(path, i, 1) == "/") { slash = i; break }
                }
                if (slash > 0) {
                    dir  = repo "/" substr(path, 1, slash - 1)
                    base = substr(path, slash + 1)
                } else {
                    dir  = repo
                    base = path
                }
                if (base !~ /\.md$/) next
                if (base == "INDEX.md") next
                if (!match(base, /^[a-z]+[0-9][0-9][0-9]+-/)) next
                slot = substr(base, 1, RLENGTH - 1)
                key = dir "\t" slot
                c[key]++
                if (c[key] == 1) {
                    first[key] = base
                } else {
                    line = dir "  slot=" slot "  collides: " first[key] " + " base
                    gsub(nl, "\\n", line)
                    print line
                }
            }
            END { printf "__KBSCAN__%d\n", NR }
        '
    )"
    _dup_rc=$?

    if [ "$_dup_rc" -ne 0 ]; then
        # An UNBORN HEAD is not a failed scan: a freshly provisioned machine
        # whose knowledge remote is still empty has nothing committed, so
        # nothing colliding can be pushed. Treat it as genuinely clean, or the
        # gate would wedge such a machine at exit 65 on every tick. Any OTHER
        # rc with a HEAD that DOES resolve (corrupt object store, a `tr` that
        # aborted on a locale, a broken awk program) is a real failure.
        if ! git -C "$REPO_DIR" rev-parse -q --verify HEAD >/dev/null 2>&1; then
            return 0
        fi
        _DUP_SLOTS_SCAN_ERROR="scan-pipeline-exit: the ls-tree | tr | awk pipeline exited ${_dup_rc}"
        return 0
    fi

    # The sentinel is always the LAST line (collision lines can never contain a
    # raw newline — awk mapped any embedded one to \001 and renders it "\n").
    _dup_last="${_dup_raw##*$'\n'}"
    case "$_dup_last" in
        __KBSCAN__[0-9]*)
            _dup_n="${_dup_last#__KBSCAN__}"
            ;;
        *)
            _DUP_SLOTS_SCAN_ERROR="scan-sentinel-missing: awk never reached END, so its output is truncated or absent"
            return 0
            ;;
    esac

    if [ "$_dup_n" -eq 0 ] \
       && [ -n "$(LC_ALL=C git -C "$REPO_DIR" ls-tree --name-only HEAD 2>/dev/null)" ]; then
        _DUP_SLOTS_SCAN_ERROR="scan-read-zero-paths: the scan read 0 paths but HEAD's tree is not empty"
        return 0
    fi

    if [ "$_dup_raw" != "$_dup_last" ]; then
        _DUP_SLOTS_FOUND="${_dup_raw%$'\n'*}"
    fi
}

_handle_dup_slots_fatal() {
    if [ -n "${_DUP_SLOTS_SCAN_ERROR:-}" ]; then
        log "FATAL: the duplicate-ID-slot scan (Guard 4) could not be completed in ${REPO_DIR} — ${_DUP_SLOTS_SCAN_ERROR}. This gate's whole job is to certify that no colliding slot state leaves this machine; a scan that did not run certifies nothing, so this tick REFUSES TO PUSH rather than reporting a clean tree (XACA-1291-028). Reproduce with: LC_ALL=C git -C ${REPO_DIR} ls-tree -r -z --name-only HEAD | LC_ALL=C tr '\\n\\0' '\\001\\n' | LC_ALL=C awk 'END{print NR}'"
        exit 65  # EX_DATAERR — a gate that cannot run is a hard failure, not a clean tick
    fi
    if [ -n "$_DUP_SLOTS_FOUND" ]; then
        log "FATAL: duplicate knowledge ID slot(s) detected in ${REPO_DIR} after sync — a cross-host merge landed two entries in the same NNN slot (XACA-0818). NOT auto-remediating and NOT pushing. Run kb-knowledge-validate to confirm, then apply the XACA-0818 remediation (renumber the colliding entry) and re-run sync."
        log_block "duplicate ID slots" "$_DUP_SLOTS_FOUND"
        exit 65  # EX_DATAERR — deliberate loud failure (see Guard 1b precedent)
    fi
}

# ── Step: UNWIND own unpushed auto-commits (XACA-1291 §4.4) ──────────────────
# New-reachable state once the daemon commits: our auto-commit is unpushed,
# upstream advanced, and the tree is dirty again. A dirty diverged tree can
# never fast-forward, so without this the daemon would wedge itself
# (blocked-ff-diverged, forever). The unwind moves only the branch ref and the
# index — NEVER the worktree (measured byte-identical, design §1.6) — and only
# ever over commits that are (a) not on the upstream and (b) provably OURS:
# daemon committer + both trailers naming THIS host. A human's commit or
# another host's makes this skip, and the tick reaches today's
# blocked-ff-diverged, which needs a human by design.
#
# XACA-1291-008 race contract — HEAD moves EXACTLY ONCE, by compare-and-swap:
#   1. `update-ref HEAD <mb> <examined-head>` — git refuses atomically if a
#      human commit landed after the ownership check. Refusal = clean skip.
#   2. `read-tree -m HEAD` — INDEX ONLY. It never writes a ref, and it takes
#      index.lock before resolving HEAD, so it cannot interleave with a human
#      `git commit` (which holds index.lock across its own HEAD update). If a
#      human commit landed between 1 and 2, the index simply follows THEIR
#      commit, which is exactly what their own `git commit` left it as.
#      (This used to be `reset --mixed <mb>`: a SECOND, non-CAS HEAD move that
#      dropped a human commit landing between 1 and 2 off the branch, left its
#      change as an uncommitted edit, and let this tick auto-commit and push
#      over it. Mutation-tested in the race suite, T35.)
#   3. HEAD re-read: anything but <mb> means we lost a race.
# If step 2 fails (index.lock held), the ref move is rolled back by the same
# CAS in reverse so the index and HEAD agree again; if even that is refused a
# human moved HEAD, and their commit stands.
# Any lost race or failure ENDS THE TICK right here: no integrate (no rebase
# or merge of the human's fresh commit), no auto-commit, no push, and no
# notify-state write (a transient race is not an unproductive tick). The next
# tick re-evaluates from whatever HEAD the human left.
if [ -n "$_dirty" ] && _ac_enabled; then
    _unwind_head="$(git -C "$REPO_DIR" rev-parse -q --verify HEAD 2>/dev/null || true)"
    _ac_counts
    if [ -n "$_unwind_head" ] && [ "$_AHEAD" -gt 0 ] && [ "$_BEHIND" -gt 0 ] && ! _ac_git_busy \
        && git -C "$REPO_DIR" diff --cached --quiet 2>/dev/null \
        && _ac_all_own_ahead; then
        _unwind_mb="$(git -C "$REPO_DIR" merge-base "$_unwind_head" '@{u}' 2>/dev/null || true)"
        _unwind_end=1
        if [ -z "$_unwind_mb" ]; then
            _unwind_end=0
            log "autocommit-unwind-skipped: no merge-base between HEAD and upstream in ${REPO_DIR} — leaving it as found"
        elif ! git -C "$REPO_DIR" update-ref -m "knowledge-sync: unwind own unpushed auto-commit(s)" HEAD "$_unwind_mb" "$_unwind_head" >/dev/null 2>&1; then
            log "autocommit-unwind-lost-race: HEAD in ${REPO_DIR} moved after the ownership check (a concurrent commit) — the compare-and-swap refused; branch and index left exactly as found"
        elif ! git -C "$REPO_DIR" read-tree -m HEAD >/dev/null 2>&1; then
            if git -C "$REPO_DIR" update-ref -m "knowledge-sync: roll back unwind (index busy)" HEAD "$_unwind_head" "$_unwind_mb" >/dev/null 2>&1; then
                log "autocommit-unwind-index-busy: the branch ref moved but the index could not be reset (index.lock held?) — ref rolled back by compare-and-swap, ${REPO_DIR} left as found"
            else
                log "autocommit-unwind-index-busy: the branch ref moved but the index could not be reset, and the rollback was refused because HEAD moved again (a concurrent commit) — that commit stands on the branch"
            fi
        else
            _unwind_now="$(git -C "$REPO_DIR" rev-parse -q --verify HEAD 2>/dev/null || true)"
            if [ "$_unwind_now" != "$_unwind_mb" ]; then
                log "autocommit-unwind-lost-race: a concurrent commit (${_unwind_now}) landed on ${REPO_DIR} during the unwind — it is kept on the branch (HEAD is never moved a second time) and the index follows it"
            else
                _unwind_end=0
                log "autocommit-unwound: ${_AHEAD} own unpushed auto-commit(s) returned to the working tree to fast-forward over upstream (worktree untouched)"
                _dirty="$(git -C "$REPO_DIR" status --porcelain 2>&1)"
            fi
        fi
        if [ "$_unwind_end" -eq 1 ]; then
            log "tick-ended-unwind-race: ${REPO_DIR} — not integrating, committing or pushing this tick; the next tick re-evaluates from the current HEAD"
            exit 0
        fi
    fi
fi

INBOUND_TOKEN=""

if [ -n "$_dirty" ]; then
    # ── DIRTY tree: integrate ONLY by fast-forward ───────────────────────────
    _pre_behind="$(git -C "$REPO_DIR" rev-list --count 'HEAD..@{u}' 2>/dev/null || true)"
    case "$_pre_behind" in ''|*[!0-9]*) _pre_behind=0 ;; esac
    _pre_ahead="$(git -C "$REPO_DIR" rev-list --count '@{u}..HEAD' 2>/dev/null || true)"
    case "$_pre_ahead" in ''|*[!0-9]*) _pre_ahead=0 ;; esac

    if [ "$_pre_behind" -eq 0 ]; then
        log "fetch-only-dirty: ${REPO_DIR} is dirty but already at upstream tip (0 behind) — nothing to fast-forward"
        INBOUND_TOKEN="fetch-only-dirty"
    else
        log "attempting fast-forward on a dirty tree: git -C ${REPO_DIR} merge --ff-only @{u} (${_pre_behind} commit(s) behind)"
        MERGE_OUTPUT="$(git -C "$REPO_DIR" merge --ff-only '@{u}' 2>&1)"
        MERGE_EXIT=$?

        if [ "$MERGE_EXIT" -eq 0 ]; then
            log "converged-ff: ${REPO_DIR} advanced ${_pre_behind} commit(s) via fast-forward on a dirty tree — uncommitted local work is byte-identical, untouched (no stash was needed or created)"
            log_block "git merge --ff-only output" "$MERGE_OUTPUT"
            _check_dup_slots
            _handle_dup_slots_fatal  # exits 65 and does not return if a collision is found
            INBOUND_TOKEN="converged-ff"
        elif [ "$MERGE_EXIT" -eq 1 ]; then
            log "blocked-ff-conflict: fast-forward refused in ${REPO_DIR} — incoming change(s) collide with the dirty tree (colliding path(s) named below by git itself). HEAD and local content are unchanged; git refused rather than clobbered. This machine CANNOT RECEIVE this content until the colliding local path is committed or removed by a human; it will keep retrying every tick."
            log_block "git merge --ff-only output" "$MERGE_OUTPUT"
            _update_notify_state "blocked-ff-conflict" "outbound-not-attempted" "$_pre_ahead" "$_pre_behind"
            exit 0
        else
            log "blocked-ff-diverged: ${REPO_DIR} is dirty AND has diverged from its upstream (${_pre_ahead} ahead, ${_pre_behind} behind) — a fast-forward is impossible. HEAD and local content are unchanged; no rebase was attempted or left in progress. This machine CANNOT RECEIVE until a human resolves it (the daemon unwinds only its OWN unpushed auto-commits, never a human's or another host's) — it needs a human, not another tick."
            log_block "git merge --ff-only output" "$MERGE_OUTPUT"
            _update_notify_state "blocked-ff-diverged" "outbound-not-attempted" "$_pre_ahead" "$_pre_behind"
            exit 0
        fi
    fi
else
    # ── CLEAN tree: unchanged behaviour — git pull --rebase ──────────────────
    # `git pull --rebase` performs its own internal fetch; the unconditional
    # fetch above already ran, so this is redundant-but-harmless on the common
    # path (nothing new to fetch) and remains the real fetch attempt on the
    # rare case where connectivity drops in between (see the
    # pull-failed-no-rebase-started branch below, unchanged from before this
    # ticket). Own auto-commits are rebased here like any other local commit.
    log "pulling: git -C ${REPO_DIR} pull --rebase"
    PULL_OUTPUT="$(git -C "$REPO_DIR" pull --rebase 2>&1)"
    PULL_EXIT=$?

    if [ "$PULL_EXIT" -ne 0 ]; then
        log_block "git pull --rebase output" "$PULL_OUTPUT"

        # A `git pull --rebase` can fail in two distinct ways, and ops reading the
        # log needs to tell them apart:
        #   1. The fetch/rebase actually started and hit a conflict → a rebase-merge/
        #      rebase-apply dir exists and MUST be aborted to unwedge the tree.
        #   2. It failed BEFORE any rebase began (network/fetch error, remote
        #      unreachable) → no rebase dir, nothing to abort, tree already untouched.
        REBASE_WAS_STARTED=0
        if [ -d "${GIT_DIR}/rebase-merge" ] || [ -d "${GIT_DIR}/rebase-apply" ]; then
            REBASE_WAS_STARTED=1
            log "rebase conflict detected in ${REPO_DIR} — running git rebase --abort"
            if ! git -C "$REPO_DIR" rebase --abort >/dev/null 2>&1; then
                log "WARNING: git rebase --abort itself failed in ${REPO_DIR} — manual intervention required"
            fi
        fi

        POST_ABORT_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"
        if [ -n "$PRE_SYNC_HEAD" ] && [ "$POST_ABORT_HEAD" != "$PRE_SYNC_HEAD" ]; then
            log "WARNING: HEAD in ${REPO_DIR} changed unexpectedly during a failed pull (was ${PRE_SYNC_HEAD}, now ${POST_ABORT_HEAD})"
        fi

        if [ "$REBASE_WAS_STARTED" -eq 1 ]; then
            log "rebase-conflict-aborted: rebase conflict in ${REPO_DIR} — aborted, tree left at pre-sync HEAD (${PRE_SYNC_HEAD})"
            _update_notify_state "rebase-conflict-aborted" "outbound-not-attempted" "" ""
        else
            log "pull-failed-no-rebase-started: git pull --rebase failed before any rebase began in ${REPO_DIR} (offline / fetch error?) — tree untouched at ${PRE_SYNC_HEAD}, will retry next tick"
        fi
        exit 0
    fi

    POST_PULL_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$PRE_SYNC_HEAD" ] && [ "$POST_PULL_HEAD" != "$PRE_SYNC_HEAD" ]; then
        # 001 measured "pull-succeeded" printing the IDENTICAL string whether or
        # not a fast-forward/rebase actually moved HEAD, making the
        # content-bearing pull fraction unmeasurable. Distinguish for real, and
        # carry the commit count (design §3.5's "two measurement defects").
        _advanced_count="$(git -C "$REPO_DIR" rev-list --count "${PRE_SYNC_HEAD}..${POST_PULL_HEAD}" 2>/dev/null || true)"
        case "$_advanced_count" in ''|*[!0-9]*) _advanced_count="unknown" ;; esac
        log "rebased-advanced: ${REPO_DIR} advanced ${_advanced_count} commit(s) via rebase (${PRE_SYNC_HEAD} -> ${POST_PULL_HEAD})"
        INBOUND_TOKEN="rebased-advanced"
    else
        log "already-current: ${REPO_DIR} is up to date with upstream — pull was a no-op"
        INBOUND_TOKEN="already-current"
    fi

    _check_dup_slots
    _handle_dup_slots_fatal  # exits 65 and does not return if a collision is found
fi
_DUP_CHECKED_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"

# ── Step: AUTOCOMMIT (XACA-1291 §4.5) ───────────────────────────────────────
# Only on a converged tick (P2 — every non-converged branch above has
# already exited) and only at 0 behind (P3): committing on a tree that is
# behind turns a fast-forwardable state into a diverged one.
_ac_counts
OUTBOUND_TOKEN=""
AC_RESULT="none"
if [ "$_BEHIND" -gt 0 ]; then
    OUTBOUND_TOKEN="outbound-not-attempted"
elif [ -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ]; then
    _ac_autocommit
elif ! _ac_enabled; then
    AC_RESULT="disabled"
fi

# ── Step: push (XACA-1291 §4.7 — relaxed gate) ──────────────────────────────
# Pushes on the dirty AND the clean path. `git push` reads refs and the
# object store only; it never reads or writes the worktree or the index
# (measured: dirt byte-identical before and after, design §1.6). The old
# "push requires a clean tree" gate protected nothing the push touches — it
# was a side effect of the pre-XACA-1266 whole-sync dirty guard. The one
# real precondition, behind == 0, is checked explicitly. Never --force.
PUSH_RESULT="none"
if [ "$OUTBOUND_TOKEN" != "outbound-not-attempted" ]; then
    _ac_counts
    if [ "$AC_NO_PUSH" -eq 1 ]; then
        # A concurrent commit raced the auto-commit. Whatever HEAD is now was
        # not produced by a clean tick of ours; do not ship it on this tick.
        log "push-deferred-race: not pushing ${REPO_DIR} this tick (the auto-commit lost a race with a concurrent commit); next tick re-evaluates from the new HEAD"
        PUSH_RESULT="deferred"
    elif [ "$_AHEAD" -gt 0 ] && [ "$_BEHIND" -eq 0 ] && _ac_phantom_deletions; then
        log "outbound-withheld-phantom-deletion: not pushing ${REPO_DIR} — the outgoing commits would DELETE ${_PHANTOM_DEL} from the fleet while the file still exists here (a commit made from a stale index). The next auto-commit re-adds it and the push resumes; if the deletion is intended, delete the local file too"
        PUSH_RESULT="phantom-deletion"
    elif [ "$_AHEAD" -gt 0 ] && [ "$_BEHIND" -eq 0 ]; then
        # The dup-slot gate must cover whatever is about to leave this machine
        # (an auto-commit, or a human commit pushed from a dirty tree).
        if [ "$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)" != "$_DUP_CHECKED_HEAD" ] || [ -n "$_dirty" ]; then
            _check_dup_slots
            _handle_dup_slots_fatal  # exits 65 and does not return if a collision is found
        fi
        log "pushing: ${_AHEAD} local commit(s) ahead of upstream in ${REPO_DIR}"
        PUSH_OUTPUT="$(git -C "$REPO_DIR" push 2>&1)"
        PUSH_EXIT=$?
        if [ "$PUSH_EXIT" -ne 0 ]; then
            log "push-failed: git push failed in ${REPO_DIR} (offline / no auth / rejected?) — will retry next tick, NOT force-pushing"
            log_block "git push output" "$PUSH_OUTPUT"
            PUSH_RESULT="failed"
        else
            log "synced: pushed ${_AHEAD} commit(s) from ${REPO_DIR} to upstream"
            PUSH_RESULT="pushed"
            case "$INBOUND_TOKEN" in
                already-current|rebased-advanced) INBOUND_TOKEN="synced" ;;
            esac
        fi
    elif [ "$_AHEAD" -gt 0 ]; then
        log "outbound-withheld-diverged: ${REPO_DIR} is ${_AHEAD} ahead and ${_BEHIND} behind after integrate — a push would be rejected; not pushing"
        PUSH_RESULT="diverged"
    else
        log "up-to-date: ${REPO_DIR} has no local commits ahead of upstream — nothing to push"
    fi
fi

# ── Outbound token (design §5.3 precedence, first match wins) ───────────────
if [ -n "${TICK_TMP:-}" ] || _ac_tmp; then
    if [ -r "$QUARANTINE_FILE" ]; then
        _ac_quarantine_refresh "" || true
    fi
fi
_ac_residual
_ac_report_nonallowlisted
_ac_counts
OUT_HAS_WITHHELD=0
if [ "$OUT_WITHHELD_PATHS" -gt 0 ] || [ "$_AHEAD" -gt 0 ]; then
    OUT_HAS_WITHHELD=1
fi
if [ "$OUTBOUND_TOKEN" != "outbound-not-attempted" ]; then
    if [ "$AC_RESULT" = "hook-error" ]; then
        OUTBOUND_TOKEN="autocommit-hook-error"
    elif [ "$AC_RESULT" = "refused" ] || [ "$AC_Q_SKIPPED" -gt 0 ]; then
        OUTBOUND_TOKEN="autocommit-refused"
    elif [ "$PUSH_RESULT" = "failed" ]; then
        OUTBOUND_TOKEN="push-failed"
    elif [ "$PUSH_RESULT" = "diverged" ]; then
        OUTBOUND_TOKEN="outbound-withheld-diverged"
    elif [ "$PUSH_RESULT" = "phantom-deletion" ]; then
        OUTBOUND_TOKEN="outbound-withheld-phantom-deletion"
    elif [ "$AC_RESULT" = "deferred-staged" ] || [ "$AC_RESULT" = "deferred-git-busy" ] || [ "$AC_RESULT" = "no-identity" ]; then
        case "$AC_RESULT" in
            no-identity) OUTBOUND_TOKEN="autocommit-no-identity" ;;
            *) OUTBOUND_TOKEN="autocommit-${AC_RESULT}" ;;
        esac
    elif [ "$AC_RESULT" = "disabled" ]; then
        OUTBOUND_TOKEN="autocommit-disabled"
    elif [ "$_RES_ALLOWED" -gt 0 ]; then
        OUTBOUND_TOKEN="outbound-withheld-incomplete"
    elif [ "$PUSH_RESULT" = "pushed" ]; then
        OUTBOUND_TOKEN="pushed"
    else
        OUTBOUND_TOKEN="outbound-current"
    fi
fi

_update_notify_state "$INBOUND_TOKEN" "$OUTBOUND_TOKEN" "$_AHEAD" "$_BEHIND"
exit 0
