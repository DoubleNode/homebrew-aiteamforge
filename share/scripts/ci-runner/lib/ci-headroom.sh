#!/usr/bin/env bash
# ci-headroom.sh - memory headroom check, macOS-lane disk floor and VM sizing for
# `aiteamforge ci enable` (XACA-1443-002, XACA-1461-002).
#
# SOURCEABLE LIBRARY. Sourcing defines functions and constants only: no output, no `exit`, no
# change to the caller's `set` options. Read-only: the only commands it runs are
# `memory_pressure`, `vm_stat`, `sysctl -n hw.memsize|hw.ncpu` and `df -Pk <path>`. Never sudo,
# never writes.
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
#   ci_headroom_disk [path]      disk-free floor for the macOS lane (independent of measure).
#       path default: ${CI_RUNNER_HOME:-/Users/ci-runner}; if absent, its nearest existing parent,
#       else /. Reads `df -Pk <path>` (POSIX output, Available column, KiB x 1024).
#       rc 0 free >= CI_HR_MACOS_DISK_MIN_BYTES | 5 below the floor | 3 unreadable (fail closed:
#       df missing/failing, not exactly header+one row, non-numeric or zero-size reading)
#       sets CI_HR_DISK_PATH, CI_HR_DISK_FREE_BYTES, CI_HR_REASONS
#   ci_headroom_size             needs a successful measure. Proposes the guest size.
#       ONLY meaningful when a Linux VM is planned (lane linux|both); a macOS-only lane (no VM)
#       must NOT call it - it has no guest to size. Memory thresholds above apply to every lane.
#       rc 0 fits | 4 no size fits. sets CI_HR_VM_GIB, CI_HR_VM_CPUS, CI_HR_LINUX_SLOTS
#
# MACOS-LANE DISK FLOOR (XACA-1461-002): CI_HR_MACOS_DISK_MIN_BYTES = 54 GiB free. The macOS lane
# is to host Main Event Android CI plus the macOS shell/bats/pytest jobs. Derivation (measured on
# M3Pro 2026-10-07, read-only `du -sk`; "est" = no local evidence, stated estimate):
#   Android SDK without system images (platform-tools, 5 build-tools, 5 platforms, emulator,
#     sources, skins)                          6.61 - 2.89            =  3.72 GiB  measured
#   2 x arm64-v8a system image (1 measured at 2.89 GiB, google_apis_playstore_ps16k)  =  5.79 GiB
#   2 x AVD at the heaviest measured size (Medium_Phone_API_35: 6.71 GiB data qcow2 +
#     0.78 GiB sdcard = 7.53 GiB; its config caps the data partition at 6 GiB)       = 15.06 GiB
#   ~/.gradle (caches 2.5 GiB of 3.3 GiB)                                            =  3.32 GiB  measured
#   Actions runner install: osx-arm64 tarball v2.338.0 = 128,562,863 B (0.12 GiB, GitHub
#     releases API), kept + extracted, rounded                                       =  0.50 GiB  est
#   runner _work (repo checkouts + build outputs + artifacts)                        =  5.00 GiB  est
#   macOS shell/bats/pytest jobs (dev-team checkout, tool caches)                    =  2.00 GiB  est
#   SUM 35.39 GiB; safety margin +50% = 53.09 GiB; rounded UP to a whole GiB         = 54 GiB
# This is a floor, not a promise: re-measure on M1Pro (XACA-1462-005) and adjust. Full table and
# sources: kanban/plans/XACA-1461/XACA-1461-002_macos_disk_floor.md
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
CI_HR_MACOS_DISK_MIN_BYTES=57982058496   # 54 GiB, derivation in the header
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

# Free bytes on the volume holding <path> (default: the ci-runner home, else nearest existing
# parent, else /). Fails closed: any unreadable/unparseable reading is rc 3, never a pass.
ci_headroom_disk() {
    local p="${1:-${CI_RUNNER_HOME:-/Users/ci-runner}}" out data rows kib size
    CI_HR_DISK_PATH=""; CI_HR_DISK_FREE_BYTES=""; CI_HR_REASONS=""
    case "$p" in /*) ;; *) p="/" ;; esac
    while [ ! -e "$p" ] && [ "$p" != "/" ]; do
        p="${p%/*}"; [ -n "$p" ] || p="/"
    done
    CI_HR_DISK_PATH="$p"
    out="$(df -Pk "$p" 2>/dev/null)" || { CI_HR_REASONS="disk free space could not be measured (df failed on $p)"; return 3; }
    rows="$(printf '%s\n' "$out" | awk 'NF{n++} END{print n+0}')"
    if [ "$rows" -ne 2 ]; then
        CI_HR_REASONS="disk free space could not be measured (unexpected df output for $p)"; return 3
    fi
    data="$(printf '%s\n' "$out" | awk 'NF{n++; if(n==2) print}')"
    # POSIX `df -Pk` row: <filesystem> <total> <used> <avail> <N>% <mount point>. The filesystem name (field 1,
    # e.g. "map auto_home") and the mount point (e.g. "/Volumes/Disk 1 2 3 4% x") may both contain spaces and
    # digits, so no column index and no greedy regex is safe. Anchor on the LEFTMOST run of
    # <digits> <digits> <digits> <digits>% starting at field 2 or later (field 1 is always the filesystem): that
    # is the real numeric block, and anything a mount point can hold sits to the right of it. Prints
    # "<total> <avail>" in KiB, or nothing when there is no such run.
    kib="$(printf '%s\n' "$data" | awk '{
        for (i = 2; i + 3 <= NF; i++)
            if ($i ~ /^[0-9]+$/ && $(i+1) ~ /^[0-9]+$/ && $(i+2) ~ /^[0-9]+$/ && $(i+3) ~ /^[0-9]+%$/) { print $i, $(i+2); exit }
    }')"
    size="${kib%% *}"; kib="${kib##* }"
    if ! _cihr_uint "$size" || ! _cihr_uint "$kib" || [ "${#kib}" -gt 15 ] || [ "${#size}" -gt 15 ]; then
        CI_HR_REASONS="disk free space could not be measured (unparseable df output for $p)"; return 3
    fi
    if [ "$size" -eq 0 ]; then   # autofs/synthetic rows report a zero-size volume: not a measurement
        CI_HR_REASONS="disk free space could not be measured (zero-size volume reported for $p)"; return 3
    fi
    CI_HR_DISK_FREE_BYTES=$((kib * 1024))
    if [ "$CI_HR_DISK_FREE_BYTES" -lt "$CI_HR_MACOS_DISK_MIN_BYTES" ]; then
        CI_HR_REASONS="disk free ${CI_HR_DISK_FREE_BYTES} B on $p < ${CI_HR_MACOS_DISK_MIN_BYTES} B (54 GiB macOS-lane floor)"
        return 5
    fi
    return 0
}
