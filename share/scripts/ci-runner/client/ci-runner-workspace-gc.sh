#!/bin/bash

#
#  ci-runner-workspace-gc.sh
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 DoubleNode.com. All rights reserved.
#

# XACA-1537-002: job-started hook that consolidates git packs in the reused
# workspace of a PERSISTENT Linux runner (/opt/actions-runner-<N>/_work/...).
#
# WHY. actions/checkout runs `git config --local gc.auto 0` on the superproject
# AND `git submodule foreach --recursive git config --local gc.auto 0` on every
# job, so git never repacks and the workspace only grows. Measured in
# XACA-1537-001 (kanban/plans/XACA-1537/XACA-1537-001_measurement.md):
#   M4Mini runners: 44-46 packs + ~400 MiB loose objects in the superproject,
#     67-69 packs + ~125 MiB loose in .git/modules/homebrew-tap.
#   M1Mini earlier reached 625 packs / 20 GiB and filled the 60 GiB guest disk.
#   A healthy clone is ~5 packs / 464-700 MiB.
# JIT slots get a fresh `git init` per job and are NOT a target: the default
# root glob is /opt/actions-runner-[0-9]*/_work/, which matches the persistent
# runner dirs (/opt/actions-runner-1, -2, ...) and NOT /opt/actions-runner-jit-N
# (XACA-1537-011: the earlier `actions-runner-*` glob matched JIT dirs too).
#
# WHEN. The runner executes ACTIONS_RUNNER_HOOK_JOB_STARTED as the `runner`
# user after "Set up job" and BEFORE any step, so before actions/checkout and
# with GITHUB_WORKSPACE set. Nothing else touches this workspace at that moment
# (one job per persistent runner, and the previous job has finished).
#
# CONTRACT: THIS SCRIPT ALWAYS EXITS 0. A non-zero exit from a job-started hook
# FAILS THE JOB, and housekeeping must never do that. Every problem (git
# missing, gc error, timeout, unreadable dir) prints one
# `ci-runner-workspace-gc: WARN ...` line to stderr and moves on. The disk
# alarm (XACA-1537-004) is the backstop for a gc that keeps failing.
#
# WHAT. Targets, each judged and consolidated independently:
#   * the superproject git dir  $GITHUB_WORKSPACE/.git  (only if a real
#     directory, not a symlink or a gitfile)
#   * EVERY submodule git dir under .git/modules/, nested ones included
#     (a directory holding HEAD + objects/). Superproject gc does NOT touch
#     these; the tap submodule alone was ~560 MiB on M4Mini.
# A target is consolidated only if packs > MAX_PACKS or loose > MAX_LOOSE.
# Counting packs is a glob and loose is `git count-objects -v`; no repack runs
# unless a threshold trips, so the common job pays milliseconds.
#
# HOW: `git --git-dir=<d> -c gc.auto=0 gc --prune=now --quiet`.
#   gc (not a bare repack) because it also prunes the loose objects, which on
#   M4Mini were a third of the bloat; repack -a -d alone leaves them behind.
#   --prune=now is NORMALLY unsafe: a concurrent fetch/commit may have written
#   an unreferenced object that is about to be referenced, and prune would
#   delete it. It is safe HERE because this runner is the sole user of its
#   workspace and the hook runs before checkout, so no other git process is
#   writing. Do not reuse this pattern on a shared or live repo.
#   -c gc.auto=0 stops gc from re-detaching/auto-spawning anything itself.
#   No `-c safe.directory=*`: the runner user owns the workspace, and
#   safe.directory only matters for a git dir owned by someone else. Adding it
#   would silently widen what git will operate on.
#   A job in this workspace can write to .git/config before us (it is the
#   previous job's code), but the hook runs as the same user that job ran as,
#   so gc config cannot cross a privilege boundary here.
#
# SCOPE GUARD. Acts only if GITHUB_WORKSPACE, symlinks resolved, sits under the
# allowed root glob. Anything else logs "skip: outside allowed root".
#
# ENV KNOBS (all optional; a non-numeric value falls back to the default)
#   CI_WORKSPACE_GC_ALLOWED_ROOT_GLOB  default /opt/actions-runner-[0-9]*/_work/
#       shell glob (case pattern); the workspace plus a trailing / must match
#       it followed by anything. Tests point this at a sandbox.
#   CI_WORKSPACE_GC_MAX_PACKS   default 20    consolidate when packs  > this
#   CI_WORKSPACE_GC_MAX_LOOSE   default 2000  consolidate when loose  > this
#   CI_WORKSPACE_GC_TIMEOUT     default 600   seconds, per git call (uses
#       timeout/gtimeout when present; otherwise the call is unbounded)
#
# OUTPUT (stderr only, one line per target, lands in the job log; no env dumps):
#   ci-runner-workspace-gc: <target> packs A->B loose C->D size-pack X->Y MiB (Ns)
#   ci-runner-workspace-gc: <target> ok (below threshold: packs A loose C)
#
# INSTALL / WIRING. Installed root-owned at guest /usr/local/sbin/
# ci-runner-workspace-gc.sh (like ci-runner-job-started.sh) and wired into the
# persistent runners' ACTIONS_RUNNER_HOOK_JOB_STARTED by XACA-1537-003.
# Bash 3.2 / BSD safe (tests run on macOS); production is Ubuntu.

set -u

TAG="ci-runner-workspace-gc"

log()  { printf '%s: %s\n' "$TAG" "$*" >&2; }
warn() { printf '%s: WARN %s\n' "$TAG" "$*" >&2; }

# num_or_default VALUE DEFAULT : VALUE if all digits (and non-empty), else DEFAULT
num_or_default() {
    case "${1:-}" in
        ''|*[!0-9]*) printf '%s' "$2" ;;
        *) printf '%s' "$1" ;;
    esac
}

MAX_PACKS=$(num_or_default "${CI_WORKSPACE_GC_MAX_PACKS:-}" 20)
MAX_LOOSE=$(num_or_default "${CI_WORKSPACE_GC_MAX_LOOSE:-}" 2000)
TIMEOUT_SECS=$(num_or_default "${CI_WORKSPACE_GC_TIMEOUT:-}" 600)
ALLOWED_GLOB="${CI_WORKSPACE_GC_ALLOWED_ROOT_GLOB:-/opt/actions-runner-[0-9]*/_work/}"

TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
fi

# run_git ARGS... : git under a timeout when one is available
run_git() {
    if [ -n "$TIMEOUT_CMD" ]; then
        "$TIMEOUT_CMD" "$TIMEOUT_SECS" git "$@"
    else
        git "$@"
    fi
}

# count_packs GITDIR : number of *.pack files (a glob, no git process)
count_packs() {
    local n=0 p
    for p in "$1"/objects/pack/*.pack; do
        [ -e "$p" ] && n=$((n + 1))
    done
    printf '%s' "$n"
}

# read_stats GITDIR : sets S_LOOSE, S_KIB (size-pack in KiB). Returns 1 if
# `git count-objects -v` fails; callers treat the numbers as 0 then.
S_LOOSE=0
S_KIB=0
read_stats() {
    local out k v
    S_LOOSE=0
    S_KIB=0
    out=$(run_git --git-dir="$1" count-objects -v 2>/dev/null) || return 1
    while IFS=': ' read -r k v; do
        case "$k" in
            count)     S_LOOSE=$(num_or_default "$v" 0) ;;
            size-pack) S_KIB=$(num_or_default "$v" 0) ;;
        esac
    done <<EOF
$out
EOF
    return 0
}

# gc_target GITDIR LABEL : judge, and consolidate if over threshold
gc_target() {
    local d="$1" label="$2"
    local packs0 loose0 kib0 packs1 loose1 kib1 start out rc first
    packs0=$(count_packs "$d")
    if ! read_stats "$d"; then
        warn "$label: git count-objects failed, judging on pack count only"
    fi
    loose0=$S_LOOSE
    kib0=$S_KIB

    if [ "$packs0" -le "$MAX_PACKS" ] && [ "$loose0" -le "$MAX_LOOSE" ]; then
        log "$label ok (below threshold: packs $packs0 loose $loose0)"
        return 0
    fi

    start=$SECONDS
    out=$(run_git --git-dir="$d" -c gc.auto=0 gc --prune=now --quiet 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        first="${out%%$'\n'*}"
        warn "$label: gc failed (rc=$rc, packs $packs0 loose $loose0; 124 = timeout) ${first:0:200}"
        return 0
    fi
    packs1=$(count_packs "$d")
    read_stats "$d" || warn "$label: git count-objects failed after gc"
    loose1=$S_LOOSE
    kib1=$S_KIB
    log "$label packs $packs0->$packs1 loose $loose0->$loose1 size-pack $((kib0 / 1024))->$((kib1 / 1024)) MiB ($((SECONDS - start))s)"
    return 0
}

main() {
    local ws_raw ws gd m mod

    ws_raw="${GITHUB_WORKSPACE:-}"
    if [ -z "$ws_raw" ]; then
        log "skip: GITHUB_WORKSPACE not set"
        return 0
    fi
    if [ ! -d "$ws_raw" ]; then
        log "skip: workspace does not exist yet"
        return 0
    fi
    # Resolve symlinks. `realpath` is not on every box; cd -P is builtin.
    ws=$(cd -P "$ws_raw" 2>/dev/null && pwd) || {
        warn "cannot resolve workspace"
        return 0
    }

    # shellcheck disable=SC2254  # the glob is meant to be a pattern
    case "$ws/" in
        $ALLOWED_GLOB*) ;;
        *)
            log "skip: outside allowed root"
            return 0
            ;;
    esac

    gd="$ws/.git"
    if [ -L "$gd" ] || [ ! -d "$gd" ]; then
        log "skip: no git directory in workspace (first job or not a checkout)"
        return 0
    fi
    if ! command -v git >/dev/null 2>&1; then
        warn "git not found on PATH, nothing done"
        return 0
    fi

    gc_target "$gd" ".git"

    if [ -d "$gd/modules" ] && [ ! -L "$gd/modules" ]; then
        # -prune on objects: stop descent into the 256 fan-out dirs
        while IFS= read -r m; do
            mod="${m%/objects}"
            [ -f "$mod/HEAD" ] || continue
            [ -L "$mod" ] && continue
            gc_target "$mod" "${mod#"$ws"/}"
        done < <(find "$gd/modules" -type d -name objects -prune -print 2>/dev/null)
    fi
    return 0
}

main "$@" || warn "unexpected failure in main (ignored)"
exit 0
