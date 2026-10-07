#!/bin/bash

#
#  ci-runner-jit-macos.sh
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 DoubleNode.com. All rights reserved.
#

# XACA-1442-003: macOS side of the Fleet CI Pool JIT runner.
# Installed as /usr/local/libexec/ci-runner-jit-macos.sh (root 755) by
# provision-host.sh stage_mac_jit. ci-pool-agent.py (root) runs it as
#   sudo -n -u ci-runner -H /usr/local/libexec/ci-runner-jit-macos.sh start <slot> <runnerName>
# with the JIT config as ONE stdin line and start_new_session=True, so the
# whole job lives in its own process group (the agent signals that group).
#
#   start <slot> <runnerName>   wipe + extract /Users/ci-runner/actions-runner-jit-macos-<slot>
#                               from ~ci-runner/runner-dist, read the config from
#                               stdin into a shell variable, export it as
#                               ACTIONS_RUNNER_INPUT_JITCONFIG, `exec ./run.sh`.
#                               Runs in the FOREGROUND until the runner exits:
#                               NO nohup (it exits 127 under sudo without a tty,
#                               spike A7) and no backgrounding; the agent owns
#                               the process.
#   clean <slot>                delete the slot directory (the agent has already
#                               stopped the process group). Exit 0 only when gone.
#
# The config is never in argv or on disk: stdin -> variable -> environment.
# Never `pkill -u ci-runner` here or anywhere: ci-runner also owns the Lima VM
# and the persistent macOS runner.
#
# TEST-ONLY overrides (unset in production): FCP_JIT_MAC_HOME replaces
# /Users/ci-runner, FCP_JIT_ROOT is prefixed to the hook path.
#
# Bash 3.2 compatible (macOS /bin/bash): no associative arrays, no ${x,,}.

set -u

HOME_BASE="${FCP_JIT_MAC_HOME:-/Users/ci-runner}"
DIST="${HOME_BASE}/runner-dist"
HOOK="${FCP_JIT_ROOT:-}/usr/local/libexec/ci-runner-job-started.sh"

die() { echo "ci-runner-jit-macos: $*" >&2; exit "${2:-1}"; }

valid_slot() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 2 ]; }

valid_name() {
    case "$1" in fcp-*) ;; *) return 1 ;; esac
    local rest="${1#fcp-}"
    [ -n "$rest" ] && [ "${#rest}" -le 40 ] || return 1
    case "$rest" in *[!a-z0-9-]*) return 1 ;; esac
    return 0
}

slot_dir() { echo "${HOME_BASE}/actions-runner-jit-macos-$1"; }

cmd_start() {
    local slot="${1:-}" name="${2:-}" dir tb line
    valid_slot "$slot" || die "bad slot '$slot'" 2
    valid_name "$name" || die "bad runner name" 2
    dir=$(slot_dir "$slot")
    umask 077

    # Read the config first: a bare invocation fails before wiping anything.
    IFS= read -r line || true
    [ -n "$line" ] || die "no JIT config on stdin" 2

    # shellcheck disable=SC2012  # names are controlled; mtime ordering wanted
    tb=$(ls -1t "${DIST}"/actions-runner-osx-arm64-*.tar.gz 2>/dev/null | head -n 1)
    [ -n "$tb" ] || die "no runner tarball in ${DIST}" 4

    rm -rf "$dir" || die "cannot wipe ${dir}"
    mkdir -p "$dir" || die "cannot create ${dir}"
    tar xzf "$tb" -C "$dir" || { rm -rf "$dir"; die "extract failed"; }

    ACTIONS_RUNNER_INPUT_JITCONFIG="$line"
    export ACTIONS_RUNNER_INPUT_JITCONFIG
    ACTIONS_RUNNER_HOOK_JOB_STARTED="$HOOK"
    export ACTIONS_RUNNER_HOOK_JOB_STARTED
    line=""
    cd "$dir" || die "cannot enter ${dir}" 71
    exec ./run.sh
}

cmd_clean() {
    local slot="${1:-}" dir
    valid_slot "$slot" || die "bad slot '$slot'" 2
    dir=$(slot_dir "$slot")
    rm -rf "$dir"
    [ ! -e "$dir" ] || die "slot directory ${dir} still present after cleanup" 5
    return 0
}

main() {
    local c="${1:-}"
    [ "$#" -gt 0 ] && shift
    case "$c" in
        start) cmd_start "$@" ;;
        clean) cmd_clean "$@" ;;
        *) die "usage: $0 start <slot> <runnerName> | clean <slot>" 2 ;;
    esac
}

main "$@"
