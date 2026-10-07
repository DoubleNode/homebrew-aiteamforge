#!/usr/bin/env bash
# ci-headroom.sh - memory headroom check + VM sizing for `aiteamforge ci enable` (XACA-1443-002).
#
# SOURCEABLE LIBRARY. Sourcing defines functions and constants only: no output, no `exit`, no
# change to the caller's `set` options. Read-only: the only commands it runs are
# `memory_pressure`, `vm_stat` and `sysctl -n hw.memsize|hw.ncpu`. Never sudo, never writes.
#
# THRESHOLDS (MEMORY ONLY, XACA-1443-012; measured on M1Mini, see kanban/plans/XACA-1443/
# XACA-1443-012_headroom.md). There is deliberately NO swap rule: macOS swap is elastic
# (XACA-1436-024). REFUSE if EITHER:
#   1. `memory_pressure` "System-wide memory free percentage" < CI_HR_MIN_FREE_PCT (25)
#   2. (Pages free + inactive + purgeable) x page size < CI_HR_MIN_FIP_BYTES (1.5 GiB)
#      page size is read from the vm_stat header, never assumed; speculative pages are excluded.
# FAIL CLOSED: a missing/empty/non-numeric reading refuses; it never passes by default.
# The binding value over several samples is the MINIMUM of each metric (the 012 doc's method).
#
# API
#   ci_headroom_measure          takes CI_HR_SAMPLES (3) samples CI_HR_INTERVAL (2) s apart.
#       rc 0 ok | 3 unreadable/unparseable (fail closed)
#       sets CI_HR_FREE_PCT, CI_HR_FIP_BYTES (minimums), CI_HR_MEMSIZE, CI_HR_NCPU
#   ci_headroom_verdict          needs a successful measure.
#       rc 0 pass | 1 free% below floor | 2 free+inactive+purgeable below floor | 3 not measured
#       (both low => 1 and CI_HR_REASONS names both)
#       sets CI_HR_REASONS (human text per failed rule)
#   ci_headroom_size             needs a successful measure. Proposes the guest size.
#       rc 0 fits | 4 no size fits. sets CI_HR_VM_GIB, CI_HR_VM_CPUS, CI_HR_LINUX_SLOTS
#
# SIZING (judgement, NOT measured - calibrated on one 16 GiB / 8 core host; re-measure after
# a week of real CI load, 012 doc):
#   vm_gib  = min( 4,                              hard cap: "do not give the VM more than 4 GiB"
#                  floor(memsize / 4 GiB),         never more than a quarter of host RAM
#                  floor((fip - 1.5 GiB) / GiB) )  what is left above the refusal floor
#   vm_cpus = min( 4, floor(ncpu / 2) )            never more than half the cores
#   slots   = 2 when vm_gib >= 3 else 1            (a shell suite/bats/pytest job needs ~1-1.5 GiB)
#   REFUSE (rc 4) when vm_gib < 2 or vm_cpus < 2.
#   M1Mini (16 GiB, 8 cpu, min fip 5.28 GiB) => 3 GiB / 4 vCPU / 2 slots.
#
# Env (tests/operators): CI_HR_SAMPLES, CI_HR_INTERVAL. Commands are found via PATH.
# Portability: /bin/bash 3.2 and bash 5. Public names ci_headroom_*, internals _cihr_*.

CI_HR_MIN_FREE_PCT=25
CI_HR_MIN_FIP_BYTES=1610612736      # 1.5 GiB
CI_HR_VM_GIB_CAP=4
CI_HR_VM_CPU_CAP=4
CI_HR_VM_GIB_MIN=2
CI_HR_VM_CPU_MIN=2

_cihr_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# One sample -> "<free_pct> <fip_bytes>" on stdout, rc 0; rc 1 on anything unparseable.
_cihr_sample() {
    local mp vs pct fip
    mp="$(memory_pressure 2>/dev/null)" || return 1
    vs="$(vm_stat 2>/dev/null)" || return 1
    pct="$(printf '%s\n' "$mp" | awk -F': ' '/System-wide memory free percentage/{gsub(/[% \r]/,"",$2); print $2; exit}')"
    _cihr_uint "$pct" || return 1
    [ "$pct" -le 100 ] || return 1
    fip="$(printf '%s\n' "$vs" | awk '
        /page size of/ { ps=$8 }
        /^Pages free:/        { n+=$NF; f=1 }
        /^Pages inactive:/    { n+=$NF; i=1 }
        /^Pages purgeable:/   { n+=$NF; p=1 }
        END { if (ps+0 > 0 && f && i && p) printf "%d", n*ps }')"
    _cihr_uint "$fip" || return 1
    echo "$pct $fip"
}

ci_headroom_measure() {
    local n="${CI_HR_SAMPLES:-3}" gap="${CI_HR_INTERVAL:-2}" i=0 s pct fip mem cpu
    local minp="" minf=""
    CI_HR_FREE_PCT=""; CI_HR_FIP_BYTES=""; CI_HR_MEMSIZE=""; CI_HR_NCPU=""
    _cihr_uint "$n" && [ "$n" -ge 1 ] || n=3
    _cihr_uint "$gap" || gap=2
    mem="$(sysctl -n hw.memsize 2>/dev/null)" || return 3
    cpu="$(sysctl -n hw.ncpu 2>/dev/null)" || return 3
    _cihr_uint "$mem" && [ "$mem" -gt 0 ] || return 3
    _cihr_uint "$cpu" && [ "$cpu" -gt 0 ] || return 3
    while [ "$i" -lt "$n" ]; do
        [ "$i" -eq 0 ] || { [ "$gap" -eq 0 ] || sleep "$gap"; }
        s="$(_cihr_sample)" || return 3
        pct="${s% *}"; fip="${s#* }"
        if [ -z "$minp" ] || [ "$pct" -lt "$minp" ]; then minp="$pct"; fi
        if [ -z "$minf" ] || [ "$fip" -lt "$minf" ]; then minf="$fip"; fi
        i=$((i + 1))
    done
    CI_HR_FREE_PCT="$minp"; CI_HR_FIP_BYTES="$minf"; CI_HR_MEMSIZE="$mem"; CI_HR_NCPU="$cpu"
    return 0
}

ci_headroom_verdict() {
    local rc=0
    CI_HR_REASONS=""
    if ! _cihr_uint "${CI_HR_FREE_PCT:-}" || ! _cihr_uint "${CI_HR_FIP_BYTES:-}"; then
        CI_HR_REASONS="memory could not be measured"
        return 3
    fi
    if [ "$CI_HR_FREE_PCT" -lt "$CI_HR_MIN_FREE_PCT" ]; then
        CI_HR_REASONS="memory free ${CI_HR_FREE_PCT}% < ${CI_HR_MIN_FREE_PCT}%"
        rc=1
    fi
    if [ "$CI_HR_FIP_BYTES" -lt "$CI_HR_MIN_FIP_BYTES" ]; then
        CI_HR_REASONS="${CI_HR_REASONS:+${CI_HR_REASONS}; }free+inactive+purgeable ${CI_HR_FIP_BYTES} B < ${CI_HR_MIN_FIP_BYTES} B (1.5 GiB)"
        [ "$rc" -ne 0 ] || rc=2
    fi
    return "$rc"
}

ci_headroom_size() {
    local gib=1073741824 by_ram by_fip
    CI_HR_VM_GIB=0; CI_HR_VM_CPUS=0; CI_HR_LINUX_SLOTS=0
    _cihr_uint "${CI_HR_MEMSIZE:-}" && _cihr_uint "${CI_HR_NCPU:-}" && _cihr_uint "${CI_HR_FIP_BYTES:-}" || return 4
    by_ram=$((CI_HR_MEMSIZE / (4 * gib)))
    if [ "$CI_HR_FIP_BYTES" -gt "$CI_HR_MIN_FIP_BYTES" ]; then
        by_fip=$(((CI_HR_FIP_BYTES - CI_HR_MIN_FIP_BYTES) / gib))
    else
        by_fip=0
    fi
    CI_HR_VM_GIB="$CI_HR_VM_GIB_CAP"
    [ "$by_ram" -ge "$CI_HR_VM_GIB" ] || CI_HR_VM_GIB="$by_ram"
    [ "$by_fip" -ge "$CI_HR_VM_GIB" ] || CI_HR_VM_GIB="$by_fip"
    CI_HR_VM_CPUS=$((CI_HR_NCPU / 2))
    [ "$CI_HR_VM_CPUS" -le "$CI_HR_VM_CPU_CAP" ] || CI_HR_VM_CPUS="$CI_HR_VM_CPU_CAP"
    if [ "$CI_HR_VM_GIB" -lt "$CI_HR_VM_GIB_MIN" ] || [ "$CI_HR_VM_CPUS" -lt "$CI_HR_VM_CPU_MIN" ]; then
        CI_HR_LINUX_SLOTS=0
        return 4
    fi
    if [ "$CI_HR_VM_GIB" -ge 3 ]; then CI_HR_LINUX_SLOTS=2; else CI_HR_LINUX_SLOTS=1; fi
    return 0
}
