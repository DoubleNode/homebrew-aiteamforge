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
# lock already held, dirty tree, mid-rebase, rebase conflict, push
# rejected/offline/no-auth) is logged and treated as an ORDINARY outcome,
# not a script failure. The only thing that must NEVER happen is a wedged,
# half-rebased ~/knowledge left behind for a human to discover days later.
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
#
# Exit-code policy:
#   This script exits 0 in essentially every normal AND degraded case —
#   not-a-repo, lock-held, dirty-tree, rebase-conflict, push-failure are all
#   ordinary outcomes for a best-effort background sync and must never mark
#   the LaunchAgent job as failed. Non-zero exit is reserved ONLY for actual
#   script-usage bugs (e.g. too many arguments) — never for a git/network
#   condition. Grep the log output (tagged `[kb-knowledge-sync]`) to see what
#   actually happened on a given run.
#
# XACA-0749

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

# ── Guard 3: quiescent tree (no in-progress rebase/merge, no dirty tree) ─────
# We never stash: a dirty tree here means a human is mid-edit (knowledge
# commits are authored via kb-knowledge-add), and stashing someone else's
# in-flight work behind their back is exactly the kind of "clever" surprise
# this daemon must never pull.
GIT_DIR="$(git -C "$REPO_DIR" rev-parse --absolute-git-dir 2>/dev/null || true)"
if [ -z "$GIT_DIR" ]; then
    log "no-op-not-a-repo: could not resolve git-dir for ${REPO_DIR} — exiting"
    exit 0
fi

if [ -d "${GIT_DIR}/rebase-merge" ] || [ -d "${GIT_DIR}/rebase-apply" ] || [ -f "${GIT_DIR}/MERGE_HEAD" ]; then
    log "skipped-rebase-in-progress: ${REPO_DIR} already has a rebase or merge in progress — leaving it for a human"
    exit 0
fi

_dirty="$(git -C "$REPO_DIR" status --porcelain 2>&1)"
if [ -n "$_dirty" ]; then
    log "skipped-dirty: ${REPO_DIR} has uncommitted changes — not touching it"
    log_block "dirty status" "$_dirty"
    exit 0
fi

PRE_SYNC_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"

# No upstream configured (e.g. a detached clone, or a fixture repo without a
# tracking branch set up) — nothing to pull or push against; no-op cleanly
# rather than letting `git pull --rebase` fail with a generic error.
if ! git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    log "no-op-no-upstream: ${REPO_DIR} has no upstream tracking branch configured — nothing to sync"
    exit 0
fi

# ── Step: fetch + rebase ──────────────────────────────────────────────────────
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
        log "rebase-aborted: rebase conflict in ${REPO_DIR} — aborted, tree left at pre-sync HEAD (${PRE_SYNC_HEAD})"
    else
        log "pull-failed-no-rebase-started: git pull --rebase failed before any rebase began in ${REPO_DIR} (offline / fetch error?) — tree untouched at ${PRE_SYNC_HEAD}, will retry next tick"
    fi
    exit 0
fi

log "pull-succeeded: ${REPO_DIR} is up to date with upstream"

# ── Step: push (only if we actually have local commits ahead) ───────────────
AHEAD="$(git -C "$REPO_DIR" rev-list --count '@{u}..HEAD' 2>/dev/null || true)"
case "$AHEAD" in
    ''|*[!0-9]*) AHEAD=0 ;;
esac

if [ "$AHEAD" -eq 0 ]; then
    log "up-to-date: ${REPO_DIR} has no local commits ahead of upstream — nothing to push"
    exit 0
fi

log "pushing: ${AHEAD} local commit(s) ahead of upstream in ${REPO_DIR}"
PUSH_OUTPUT="$(git -C "$REPO_DIR" push 2>&1)"
PUSH_EXIT=$?

if [ "$PUSH_EXIT" -ne 0 ]; then
    log "push-failed: git push failed in ${REPO_DIR} (offline / no auth / rejected?) — will retry next tick, NOT force-pushing"
    log_block "git push output" "$PUSH_OUTPUT"
    exit 0
fi

log "synced: pushed ${AHEAD} commit(s) from ${REPO_DIR} to upstream"
exit 0
