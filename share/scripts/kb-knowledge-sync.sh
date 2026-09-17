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
#   - The PUSH side is UNCHANGED and stays gated on a clean tree — pushing
#     from a dirty tree was never safe and still isn't. Since the tree is
#     essentially never clean on an authoring machine, this means push
#     stays permanently closed until a separate, out-of-scope change
#     (commit-on-write) lands; see the design doc §6/§7. This ticket fixes
#     INBOUND convergence only. A machine will reliably RECEIVE the
#     fleet's knowledge and reliably REPORT when it cannot. It will still
#     never SHARE its own.
#
# See kanban/plans/XACA-1266/XACA-1266-003-design-decision.md for the full
# design (this comment summarizes it; that document is normative).
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

# _update_notify_state <token> <measured-ahead> <measured-behind>
#
# Called once per tick with the phase token that determines convergence
# (fetch-failed / blocked-ff-conflict / blocked-ff-diverged /
# rebase-conflict-aborted / converged-ff / fetch-only-dirty /
# rebased-advanced / already-current / synced — see design doc §3.5 for the
# full token vocabulary). Reads the PREVIOUS counter from $STATE_FILE (if
# present/readable), advances it per the increment/reset table below,
# writes the new state atomically (temp file + mv so a reader never sees a
# half-written file), and — only at a backed-off milestone threshold — logs
# a greppable `notify-stall` line to THIS script's own log (distinct from
# the SessionStart hook's user-facing banner, which reads the state file
# independently).
#
#   Increment on: fetch-failed, blocked-ff-conflict, blocked-ff-diverged,
#                 rebase-conflict-aborted   (design §5's fail-direction table)
#   Reset to 0 on: converged-ff, rebased-advanced, already-current,
#                  fetch-only-dirty, synced   (design §4.2)
#
# Threshold is 6 consecutive unproductive ticks (~3h at the 30-min cadence)
# normally, escalated to 2 (~1h) when the LATEST token is blocked-ff-
# diverged — that state cannot self-heal (no human action, no future tick,
# fixes a diverged+dirty tree) and needs a human by definition. Beyond the
# threshold, notify only at backed-off milestones (threshold, threshold*4,
# threshold*16, …) — never every tick, so this cannot become the same
# alert-fatigue noise the old unconditional dirty warning was.
_update_notify_state() {
    local token="$1" m_ahead="${2:-}" m_behind="${3:-}"
    local prev_counter prev_first new_counter threshold

    prev_counter="$(_json_field "$STATE_FILE" consecutive_unproductive_ticks)"
    case "$prev_counter" in ''|*[!0-9]*) prev_counter=0 ;; esac
    prev_first="$(_json_field "$STATE_FILE" first_unproductive_at)"

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

    if [ "$new_counter" -ge "$threshold" ] && [ "$threshold" -gt 0 ]; then
        local _milestone=$threshold
        while [ "$_milestone" -le "$new_counter" ]; do
            if [ "$_milestone" -eq "$new_counter" ]; then
                log "notify-stall: ${new_counter} consecutive unproductive tick(s) on ${REPO_DIR} (last=${token}, threshold=${threshold}) — ahead=${m_ahead:-unknown} behind=${m_behind:-unknown}, first unproductive at ${prev_first:-unknown}"
                break
            fi
            _milestone=$(( _milestone * 4 ))
        done
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
        printf '"repo_path":"%s"' "$(_json_escape "$REPO_DIR")"
        printf '}\n'
    } > "$tmp_file" 2>/dev/null

    if [ ! -s "$tmp_file" ] || ! mv "$tmp_file" "$STATE_FILE" 2>/dev/null; then
        log "notify-state-unwritable: could not write ${STATE_FILE} — sync continuing normally"
        rm -f "$tmp_file" 2>/dev/null || true
        return 0
    fi
    return 0
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

# Dirty flag only — no longer an exit. Selects the integrate strategy
# below and separately gates the push at the very end.
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
    _update_notify_state "fetch-failed" "" ""
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
_check_dup_slots() {
    _DUP_SLOTS_FOUND="$(
        find "$REPO_DIR" -type f -name '*.md' ! -name 'INDEX.md' -not -path '*/.git/*' -print0 2>/dev/null \
        | while IFS= read -r -d '' _f; do
            _d="${_f%/*}"; _b="${_f##*/}"
            # slot key = leading lowercase prefix + THREE-OR-MORE digits (k004, t001,
            # k1000, …). XACA-1155: this was exactly 3 digits, so a cross-host
            # collision on any slot past k999 was invisible here and got pushed.
            _slot="$(printf '%s\n' "$_b" | sed -n 's/^\([a-z][a-z]*[0-9][0-9][0-9][0-9]*\)-.*\.md$/\1/p')"
            [ -n "$_slot" ] && printf '%s\t%s\t%s\n' "$_d" "$_slot" "$_b"
          done \
        | awk -F'\t' '{ key=$1 "\t" $2; c[key]++; if (c[key]==1) { first[key]=$3 } else { print $1 "  slot=" $2 "  collides: " first[key] " + " $3 } }'
    )"
}

_handle_dup_slots_fatal() {
    if [ -n "$_DUP_SLOTS_FOUND" ]; then
        log "FATAL: duplicate knowledge ID slot(s) detected in ${REPO_DIR} after sync — a cross-host merge landed two entries in the same NNN slot (XACA-0818). NOT auto-remediating and NOT pushing. Run kb-knowledge-validate to confirm, then apply the XACA-0818 remediation (renumber the colliding entry) and re-run sync."
        log_block "duplicate ID slots" "$_DUP_SLOTS_FOUND"
        exit 65  # EX_DATAERR — deliberate loud failure (see Guard 1b precedent)
    fi
}

if [ -n "$_dirty" ]; then
    # ── DIRTY tree: integrate ONLY by fast-forward ───────────────────────────
    _pre_behind="$(git -C "$REPO_DIR" rev-list --count 'HEAD..@{u}' 2>/dev/null || true)"
    case "$_pre_behind" in ''|*[!0-9]*) _pre_behind=0 ;; esac
    _pre_ahead="$(git -C "$REPO_DIR" rev-list --count '@{u}..HEAD' 2>/dev/null || true)"
    case "$_pre_ahead" in ''|*[!0-9]*) _pre_ahead=0 ;; esac

    if [ "$_pre_behind" -eq 0 ]; then
        log "fetch-only-dirty: ${REPO_DIR} is dirty but already at upstream tip (0 behind) — nothing to fast-forward"
        _update_notify_state "fetch-only-dirty" "$_pre_ahead" "0"
        log "push-withheld-dirty: ${REPO_DIR} has uncommitted changes — push withheld (push requires a clean tree)"
        exit 0
    fi

    log "attempting fast-forward on a dirty tree: git -C ${REPO_DIR} merge --ff-only @{u} (${_pre_behind} commit(s) behind)"
    MERGE_OUTPUT="$(git -C "$REPO_DIR" merge --ff-only '@{u}' 2>&1)"
    MERGE_EXIT=$?

    if [ "$MERGE_EXIT" -eq 0 ]; then
        log "converged-ff: ${REPO_DIR} advanced ${_pre_behind} commit(s) via fast-forward on a dirty tree — uncommitted local work is byte-identical, untouched (no stash was needed or created)"
        log_block "git merge --ff-only output" "$MERGE_OUTPUT"
        _check_dup_slots
        _handle_dup_slots_fatal  # exits 65 and does not return if a collision is found
        _update_notify_state "converged-ff" "$_pre_ahead" "0"
        log "push-withheld-dirty: ${REPO_DIR} has uncommitted changes — push withheld (push requires a clean tree)"
        exit 0
    elif [ "$MERGE_EXIT" -eq 1 ]; then
        log "blocked-ff-conflict: fast-forward refused in ${REPO_DIR} — incoming change(s) collide with the dirty tree (colliding path(s) named below by git itself). HEAD and local content are unchanged; git refused rather than clobbered. This machine CANNOT RECEIVE this content until the colliding local path is committed or removed by a human; it will keep retrying every tick."
        log_block "git merge --ff-only output" "$MERGE_OUTPUT"
        _update_notify_state "blocked-ff-conflict" "$_pre_ahead" "$_pre_behind"
        log "push-withheld-dirty: ${REPO_DIR} has uncommitted changes — push withheld (push requires a clean tree)"
        exit 0
    else
        log "blocked-ff-diverged: ${REPO_DIR} is dirty AND has diverged from its upstream (${_pre_ahead} ahead, ${_pre_behind} behind) — a fast-forward is impossible. HEAD and local content are unchanged; no rebase was attempted or left in progress. This machine CANNOT RECEIVE until a human resolves the dirty tree (this daemon never stashes or rebases a dirty tree) — it needs a human, not another tick."
        log_block "git merge --ff-only output" "$MERGE_OUTPUT"
        _update_notify_state "blocked-ff-diverged" "$_pre_ahead" "$_pre_behind"
        log "push-withheld-dirty: ${REPO_DIR} has uncommitted changes — push withheld (push requires a clean tree)"
        exit 0
    fi
fi

# ── CLEAN tree: unchanged behaviour — git pull --rebase ──────────────────────
# `git pull --rebase` performs its own internal fetch; the unconditional
# fetch above already ran, so this is redundant-but-harmless on the common
# path (nothing new to fetch) and remains the real fetch attempt on the
# rare case where connectivity drops in between (see the
# pull-failed-no-rebase-started branch below, unchanged from before this
# ticket).
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
        _update_notify_state "rebase-conflict-aborted" "" ""
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
    _update_notify_state "rebased-advanced" "" "$_advanced_count"
else
    log "already-current: ${REPO_DIR} is up to date with upstream — pull was a no-op"
    _update_notify_state "already-current" "" "0"
fi

_check_dup_slots
_handle_dup_slots_fatal  # exits 65 and does not return if a collision is found

# ── Step: push (only if we actually have local commits ahead) ───────────────
# Gate is UNCHANGED and remains exactly as strict as before this ticket:
# push only ever runs here, on the path reached ONLY by a clean tree (the
# dirty branch above always exits before reaching this point, logging
# push-withheld-dirty itself). Pushing from a dirty tree was never safe and
# still isn't — see the XACA-1266 header comment for why this half of the
# contract stays broken (nothing ever commits to ~/knowledge, so this gate
# is in practice permanently closed on an authoring machine until a
# separate, out-of-scope commit-on-write change lands).
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
_update_notify_state "synced" "0" "0"
exit 0
