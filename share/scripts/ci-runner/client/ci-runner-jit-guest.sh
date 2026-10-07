#!/bin/bash

#
#  ci-runner-jit-guest.sh
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 DoubleNode.com. All rights reserved.
#

# XACA-1442-003: guest side of the Fleet CI Pool JIT runner (Lima VM, Linux).
# Installed in the guest as /usr/local/sbin/ci-runner-jit.sh (root 755) by
# provision-host.sh stage_guest_jit; called by ci-pool-agent.py through
#   sudo -n -u ci-runner -H limactl shell --workdir /tmp <vm> -- \
#       sudo -n /usr/local/sbin/ci-runner-jit.sh <command> ...
#
#   start <slot> <runnerName>   JIT config = ONE line on stdin. Wipes and
#                               re-extracts /opt/actions-runner-jit-<slot>,
#                               parks the config on tmpfs for the instant it
#                               takes the wrapper to start, then runs the
#                               listener as user `runner` under a transient
#                               systemd unit fcp-jit-<slot>. Returns at once.
#   status [slot ...]           One line per slot (all slots found if none):
#                                 slot=<n> unit=<active|failed|exited|lost|none> exit=<n|-> dir=<yes|no>
#                               exited = PROVEN clean exit 0 (exit marker, or
#                               systemd still holds ExecMainCode=exited,
#                               status 0, Result=success).
#                               failed = exit code n (signal -> 128+sig).
#                               lost   = the runner is gone WITHOUT a proven
#                               exit: VM reboot / crash (unit gone, marker
#                               wiped with /run), SIGTERM stop, killed or
#                               dumped. The agent reports it `failed`,
#                               never `completed` (XACA-1442-014).
#   clean <slot> [runnerName]   Stop the unit (kills the job's whole cgroup),
#                               archive _diag (logs only) to
#                               /opt/fcp-jit-diag/<runnerName>/ (newest 50
#                               kept), delete the slot directory. Exit 0 only
#                               when the directory is really gone.
#   _exec <slot> <runnerName>   INTERNAL: the systemd wrapper (see below).
#   _stoppost <slot>            INTERNAL: systemd ExecStopPost. Records how the
#                               runner ended in /run/fcp-jit/<slot>.exit
#                               (tmpfs: a reboot wipes it, which is exactly
#                               what makes "dir but no unit, no marker" LOST).
#
# The config is a credential. It is NEVER in argv, never in a unit property
# (no --setenv: `systemctl show` would read it back) and never on persistent
# disk. It lives in /run/fcp-jit/<slot>.cfg (tmpfs, root, mode 600) only until
# the wrapper reads and removes it, then reaches the listener through the
# environment (ACTIONS_RUNNER_INPUT_JITCONFIG, spike E5).
#
# Spike A7: umask 077 before the runner starts (credential files were 664).
#
# Why a marker (XACA-1442-014): systemd collects a unit that exited cleanly, and
# treats a SIGTERM stop as success, so `inactive`/"not loaded" cannot tell a
# finished job from a lost one. ExecStopPost sees $EXIT_CODE (exited|killed|
# dumped) and $EXIT_STATUS and writes them down before the unit disappears.
#
# Deviation from the plan: no `systemd-run --collect`. --collect unloads a
# FAILED unit at once, which would lose ExecMainStatus (the job's exit code).
# Without it a failed unit lingers until `clean` runs reset-failed; a unit that
# exited 0 is collected by systemd anyway (shown as unit=exited).
#
# TEST-ONLY override: FCP_JIT_ROOT is prefixed to every absolute path this
# script uses (/opt, /run, /usr/local/sbin). It is unset in production, where
# `sudo` also scrubs the environment. Never set it on a real host.
#
# bash 4+/5 in the guest, but written to also run under macOS /bin/bash 3.2.

set -u

ROOT="${FCP_JIT_ROOT:-}"
OPT="${ROOT}/opt"
RUN_DIR="${ROOT}/run/fcp-jit"
DIST="${OPT}/runner-dist"
DIAG_ROOT="${OPT}/fcp-jit-diag"
HOOK="${ROOT}/usr/local/sbin/ci-runner-job-started.sh"
SELF="/usr/local/sbin/ci-runner-jit.sh"
if [ -n "$ROOT" ]; then   # tests only: the sandboxed copy being run
    SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
fi
DIAG_KEEP=50
RUNNER_USER="runner"

die() { echo "ci-runner-jit: $*" >&2; exit "${2:-1}"; }

valid_slot() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 2 ]; }

valid_name() {
    case "$1" in
        fcp-*) ;;
        *) return 1 ;;
    esac
    local rest="${1#fcp-}"
    [ -n "$rest" ] && [ "${#rest}" -le 40 ] || return 1
    case "$rest" in *[!a-z0-9-]*) return 1 ;; esac
    return 0
}

slot_dir() { echo "${OPT}/actions-runner-jit-$1"; }
unit_of()  { echo "fcp-jit-$1"; }

# Newest cached runner tarball (provision-host.sh fills the cache).
newest_tarball() {
    local f
    # shellcheck disable=SC2012  # names are controlled; mtime ordering wanted
    f=$(ls -1t "${DIST}"/actions-runner-linux-arm64-*.tar.gz 2>/dev/null | head -n 1)
    [ -n "$f" ] || return 1
    echo "$f"
}

cmd_start() {
    local slot="${1:-}" name="${2:-}" dir unit tb cfg line
    valid_slot "$slot" || die "bad slot '$slot'" 2
    valid_name "$name" || die "bad runner name" 2
    dir=$(slot_dir "$slot"); unit=$(unit_of "$slot")
    cfg="${RUN_DIR}/${slot}.cfg"

    umask 077
    # One stdin line, no trailing newline needed. IFS= keeps it byte-exact.
    IFS= read -r line || true
    [ -n "$line" ] || die "no JIT config on stdin" 2

    # A live unit means the slot is busy: refuse before touching anything.
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        die "slot ${slot} unit is still active" 3
    fi
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true

    tb=$(newest_tarball) || die "no runner tarball in ${DIST}" 4
    rm -rf "$dir" || die "cannot wipe ${dir}"
    mkdir -p "$dir" || die "cannot create ${dir}"
    tar xzf "$tb" -C "$dir" || { rm -rf "$dir"; die "extract failed"; }
    chown -R "${RUNNER_USER}:${RUNNER_USER}" "$dir" || { rm -rf "$dir"; die "chown failed"; }

    mkdir -p "$RUN_DIR" || die "cannot create ${RUN_DIR}"
    chmod 700 "$RUN_DIR" || die "cannot secure ${RUN_DIR}"
    rm -f "$cfg" "${RUN_DIR}/${slot}.exit"
    # printf is a builtin: the config never reaches an argv. umask 077 above.
    printf '%s\n' "$line" > "$cfg" || { rm -f "$cfg"; die "cannot write config"; }
    line=""
    printf '%s\n' "$name" > "${RUN_DIR}/${slot}.name" 2>/dev/null || true

    # The wrapper is this very script (`_exec`): systemd-run argv carries only
    # the slot number and the runner name.
    if ! systemd-run --quiet --unit="$unit" --property=KillMode=control-group \
            --property="ExecStopPost=${SELF} _stoppost ${slot}" \
            -- "$SELF" _exec "$slot" "$name" >/dev/null; then
        rm -f "$cfg"
        die "systemd-run failed"
    fi
    return 0
}

# The transient unit's process (root). Reads + removes the tmpfs config, then
# becomes the runner. `exec`: no root shell lingers holding the config.
cmd_exec() {
    local slot="${1:-}" name="${2:-}" cfg line
    valid_slot "$slot" || die "bad slot" 2
    valid_name "$name" || die "bad runner name" 2
    cfg="${RUN_DIR}/${slot}.cfg"
    umask 077
    [ -f "$cfg" ] || die "no staged config" 70
    IFS= read -r line < "$cfg" || true
    rm -f "$cfg"
    [ -n "$line" ] || die "empty staged config" 70
    # XACA-1443-014 DECISION: self-update is NOT disabled here and cannot be. DisableUpdate is a config.sh flag stored in
    # the runner's .runner file; a JIT runner takes that file from the server-generated JIT config (generate-jitconfig has
    # no such field), so `run.sh --disableupdate` would change nothing and disabling it would turn GitHub's 30-day rule into
    # a hard cliff. The robust lever is the cache: the tarball extracted above is the newest VERIFIED release, kept fresh by
    # provision-host.sh / `aiteamforge ci refresh` (runner-pin.conf, lib/ci-runner-version.sh). A runner that is still
    # behind self-updates, which delays that one job; `aiteamforge ci status` warns before it gets there.
    ACTIONS_RUNNER_INPUT_JITCONFIG="$line"
    export ACTIONS_RUNNER_INPUT_JITCONFIG
    ACTIONS_RUNNER_HOOK_JOB_STARTED="$HOOK"
    export ACTIONS_RUNNER_HOOK_JOB_STARTED
    line=""
    cd "$(slot_dir "$slot")" || die "slot dir missing" 71
    exec runuser -u "$RUNNER_USER" -- ./run.sh
}

# systemd ExecStopPost (root). EXIT_CODE is exited|killed|dumped, EXIT_STATUS a
# number or a signal name; both come from systemd, but are scrubbed anyway.
cmd_stoppost() {
    local slot="${1:-}" code status tmp
    valid_slot "$slot" || die "bad slot" 2
    umask 077
    code=$(printf '%s' "${EXIT_CODE:-}" | tr -cd 'A-Za-z0-9_-' | cut -c1-16)
    status=$(printf '%s' "${EXIT_STATUS:-}" | tr -cd 'A-Za-z0-9_-' | cut -c1-16)
    mkdir -p "$RUN_DIR" || die "cannot create ${RUN_DIR}"
    chmod 700 "$RUN_DIR" || die "cannot secure ${RUN_DIR}"
    tmp="${RUN_DIR}/${slot}.exit.tmp.$$"
    printf 'code=%s status=%s\n' "$code" "$status" > "$tmp" || die "cannot write exit marker"
    mv -f "$tmp" "${RUN_DIR}/${slot}.exit" || { rm -f "$tmp"; die "cannot publish exit marker"; }
    return 0
}

# "<exited|1|killed|...> <status>" -> "<unit> <exit>": only a numeric exit is
# an outcome; a signal, a dump or anything unparseable is LOST.
classify_exit() {
    case "$1" in
        exited|1)
            case "$2" in
                ''|*[!0-9]*) echo "lost -" ;;
                *) if [ "${#2}" -gt 3 ]; then echo "lost -"
                   elif [ "$((10#$2))" -eq 0 ]; then echo "exited 0"
                   else echo "failed $((10#$2))"; fi ;;
            esac ;;
        *) echo "lost -" ;;
    esac
}

status_one() {
    local slot="$1" unit dir out active result code mcode load unitstate="none" ex="-" hasdir=no
    local marker verdict l kv m_code="" m_status=""
    unit=$(unit_of "$slot"); dir=$(slot_dir "$slot"); marker="${RUN_DIR}/${slot}.exit"
    [ -d "$dir" ] && hasdir=yes
    out=$(systemctl show "$unit" -p LoadState -p ActiveState -p Result -p ExecMainCode -p ExecMainStatus 2>/dev/null) || out=""
    load=$(printf '%s\n' "$out" | sed -n 's/^LoadState=//p' | head -n 1)
    active=$(printf '%s\n' "$out" | sed -n 's/^ActiveState=//p' | head -n 1)
    result=$(printf '%s\n' "$out" | sed -n 's/^Result=//p' | head -n 1)
    mcode=$(printf '%s\n' "$out" | sed -n 's/^ExecMainCode=//p' | head -n 1)
    code=$(printf '%s\n' "$out" | sed -n 's/^ExecMainStatus=//p' | head -n 1)
    if [ -f "$marker" ]; then
        l=""; IFS= read -r l < "$marker" || true
        for kv in $l; do
            case "$kv" in code=*) m_code="${kv#code=}" ;; status=*) m_status="${kv#status=}" ;; esac
        done
    fi
    if [ -n "$load" ] && [ "$load" != "not-found" ]; then
        case "$active" in
            # deactivating = ExecStopPost (_stoppost) is still writing the
            # marker: not finished yet, so the next poll reads the verdict
            # instead of reporting a clean exit as slot-vanished (XACA-1442-017).
            active|activating|reloading|deactivating) unitstate=active ;;
            failed)
                unitstate=failed
                case "$code" in ''|*[!0-9]*) ex="-" ;; *)
                    if [ "$result" = "signal" ]; then ex=$((128 + code)); else ex="$code"; fi ;;
                esac ;;
            inactive)
                if [ -f "$marker" ]; then
                    verdict=$(classify_exit "$m_code" "$m_status")
                elif [ "$result" = "success" ]; then
                    verdict=$(classify_exit "$mcode" "$code")
                else
                    verdict="lost -"
                fi
                unitstate="${verdict% *}"; ex="${verdict#* }" ;;
            *) unitstate=none ;;
        esac
    elif [ "$hasdir" = yes ]; then
        # unit collected or gone (clean-exit GC, or a VM reboot): only a marker
        # that proves a numeric exit makes it finished; anything else is LOST.
        if [ -f "$marker" ]; then
            verdict=$(classify_exit "$m_code" "$m_status")
        else
            verdict="lost -"
        fi
        unitstate="${verdict% *}"; ex="${verdict#* }"
    fi
    echo "slot=${slot} unit=${unitstate} exit=${ex} dir=${hasdir}"
}

cmd_status() {
    local slot d
    if [ "$#" -gt 0 ]; then
        for slot in "$@"; do
            valid_slot "$slot" || die "bad slot '$slot'" 2
        done
        for slot in "$@"; do status_one "$slot"; done
        return 0
    fi
    for d in "${OPT}"/actions-runner-jit-*; do
        [ -d "$d" ] || continue
        slot="${d##*-}"
        valid_slot "$slot" && status_one "$slot"
    done
    return 0
}

cmd_clean() {
    local slot="${1:-}" name="${2:-}" dir unit arch d
    valid_slot "$slot" || die "bad slot '$slot'" 2
    dir=$(slot_dir "$slot"); unit=$(unit_of "$slot")
    umask 077

    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
    rm -f "${RUN_DIR}/${slot}.cfg" "${RUN_DIR}/${slot}.exit"

    if [ -z "$name" ] && [ -f "${RUN_DIR}/${slot}.name" ]; then
        IFS= read -r name < "${RUN_DIR}/${slot}.name" || true
    fi
    valid_name "$name" || name="fcp-slot${slot}-$(date +%s)"

    # _diag is job-controlled: never follow a symlink (root is copying).
    if [ -d "${dir}/_diag" ] && [ ! -L "${dir}/_diag" ]; then
        arch="${DIAG_ROOT}/${name}"
        mkdir -p "$arch" 2>/dev/null && chmod 700 "$DIAG_ROOT" "$arch" 2>/dev/null
        cp -RP "${dir}/_diag/." "${arch}/" 2>/dev/null || echo "ci-runner-jit: _diag archive failed (continuing)" >&2
    fi
    # keep the newest DIAG_KEEP archives; only ever touch names we mint
    if [ -d "$DIAG_ROOT" ]; then
        # shellcheck disable=SC2012  # names are validated before use; mtime order wanted
        ls -1t "$DIAG_ROOT" 2>/dev/null | tail -n +$((DIAG_KEEP + 1)) | while IFS= read -r d; do
            if valid_name "$d"; then rm -rf "${DIAG_ROOT:?}/${d}"; fi
        done
    fi

    rm -rf "$dir"
    rm -f "${RUN_DIR}/${slot}.name"
    [ ! -e "$dir" ] || die "slot directory ${dir} still present after cleanup" 5
    return 0
}

main() {
    local c="${1:-}"
    [ "$#" -gt 0 ] && shift
    case "$c" in
        start)  cmd_start "$@" ;;
        status) cmd_status "$@" ;;
        clean)  cmd_clean "$@" ;;
        _exec)  cmd_exec "$@" ;;
        _stoppost) cmd_stoppost "$@" ;;
        *) die "usage: $0 start <slot> <runnerName> | status [slot...] | clean <slot> [runnerName]" 2 ;;
    esac
}

main "$@"
