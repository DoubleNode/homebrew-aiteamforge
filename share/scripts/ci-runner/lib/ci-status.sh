#!/usr/bin/env bash
# ci-status.sh - CI capability state classifier (XACA-1443-004).
#
# SOURCEABLE LIBRARY. Sourcing defines functions only: no output, no `exit`, no change to the caller's
# `set` options. Written to be safe under the caller's `set -e` / `set -u` (the tap doctor runs `set -eo
# pipefail`). Two callers must agree on the answer, so there is exactly one classifier:
#   * `aiteamforge ci status`      (tap-only CLI, libexec/commands/aiteamforge-ci.sh)
#   * `aiteamforge doctor`         (check_ci_capability in libexec/commands/aiteamforge-doctor.sh)
# READ-ONLY. Never runs sudo, launchctl, dscl, limactl, curl or gh and never calls the GitHub / Fleet APIs.
# It runs `id -u`, `ls -ldn`, `grep`, `awk`, `sed`, `sort` and shell tests, and sources two bundle libraries
# (ci-enable-guard.sh, ci-provision-version.sh) when they are present.
#
#   ci_capability_state        rc 0 = level ok | 1 = warn | 2 = fail    (the doctor's own levels)
#
# Sets (all plain strings; list values are newline separated, one `class: text` per line):
#   CI_STATUS_STATE   exactly one of: dormant | enable-pending | enabled | paused | disable-pending | misconfigured
#   CI_STATUS_LEVEL   ok | warn | fail
#   CI_STATUS_HOST    host named by the state file, empty when there is no usable state file
#   CI_STATUS_LANE    linux | both | macos (XACA-1461), empty when there is no usable state file. Absent `lane` key =
#                     legacy file: derived from with_macos (0 -> linux, 1 -> both). NEVER inferred from missing artefacts.
#   CI_STATUS_REASONS why (every probe that contributed; also notes that do not change the verdict)
#   CI_STATUS_SKEW    in-sync | skewed | unknown | n/a     (n/a: only an `enabled`/`paused` host is compared)
#   CI_STATUS_SKEW_REASONS / CI_STATUS_SKEW_UNSEEN / CI_STATUS_SKEW_BLIND   copied from ci_provision_skew
#   CI_STATUS_UNSEEN  probes that could not run (their presence makes the state `misconfigured`, never dormant)
#   CI_STATUS_NEXT    one command line / instruction for the operator, empty when nothing is needed
#   CI_STATUS_DEV     1 on the dev-team source machine (ci_enable_guard rc 10), else 0
#
# Env (same names the enable/disable/refresh commands and the root scripts use; all default to the real path):
#   AITEAMFORGE_DIR CI_LAUNCHDAEMONS_DIR CI_RUNNER_USER CI_LIBEXEC_DIR CI_AGENT_CFG_DIR CIH_STATE_DIR
#
# THE RULES (every one is covered by tests/test-xaca-1443-ci-status.sh)
#  1. FAIL CLOSED. `dormant` needs POSITIVE evidence: the state file is absent (stat says "no such file", not
#     "could not read it"), no daemon plist / pause marker / manifest / root-owned copy remains, the user probe
#     answered, and every directory we had to look into was looked into. Any probe that cannot run is recorded in
#     CI_STATUS_UNSEEN and yields `misconfigured`. A failed read is never `dormant` and never `enabled`.
#  2. A leftover state file means NOT dormant (contract 002). A state file we cannot read, whose mode is not 600,
#     that is not ours, that is not schema 1 / a known state / a valid host, or is a symlink or a directory, is
#     `misconfigured`.
#  3. `paused` is derived, never stored: the XACA-1440 pause marker <CIH_STATE_DIR>/<host>.pause.json of an
#     `enabled` host (draining / paused / resuming all read as paused, the reason says which). A marker we cannot
#     parse is `misconfigured`.
#  4. A state/artefact disagreement is `misconfigured`: enabled without the ci-runner user or one of the host's
#     daemon plists; plists or other CI artefacts with no state file; plists of a host the state file does not name.
#     EXCEPTION, deliberately: the ci-runner USER alone (no state file, no plist, no marker, no copies) is
#     `dormant` with a note, because `ci disable` keeps the user by default (`--remove-user` is opt-in).
#  5. SKEW is a WARN inside `enabled`/`paused`, not `misconfigured`: the host works, and skew follows every
#     `brew upgrade`, so a FAIL would make doctor red after each upgrade and train operators to ignore it. But
#     `unknown` is never healthy: it is a WARN too, with what could not be seen. Skew is judged only for an
#     enabled/paused host (013 contract) and never for any other state.
#  6. It cannot see inside ci-runner's 700 home (the Lima VM, fleet-config.json), nor which daemons are loaded
#     or what a plist contains. That is reported in CI_STATUS_SKEW_BLIND for enabled hosts, never assumed OK.
#  7. Dev-team source machine (ci_enable_guard rc 10): the CI capability is disabled by design, so the shipped
#     bundle is not required. A clean machine is `dormant`; ANY state file or CI artefact there is
#     `misconfigured` (the M3Pro stray-LaunchAgent history, XACA-0212).
#
#  8. LANE (XACA-1461). The state file records which lanes the host runs: linux (VM only) | both | macos (macOS only,
#     NO Lima VM). The required daemon plists follow the lane: linux = agent+reporter+lima-vm; both = + macos;
#     macos = agent+reporter+macos and NO lima-vm plist (one on a macos host is a state/artefact disagreement). A
#     macos-lane host never calls limactl and never claims to have looked at a VM. lane=macos needs with_macos=1; an
#     unknown lane, or a lane that contradicts with_macos, is `misconfigured`. The lane is RECORDED, never inferred:
#     a linux/both host whose lima-vm plist is missing is `misconfigured`, not "macOS-only".
#
# HOOK for XACA-1443-014 (actions/runner binary lifecycle): if a function named ci_status_runner_probe exists
# when an `enabled`/`paused` host is classified, it is called as `ci_status_runner_probe <host>` and may call
# `_cis_warn "<runner: text>"` (verdict becomes warn) or `_cis_unseen "<runner: text>"`. XACA-1443-014 implements it in
# lib/ci-runner-version.sh (loaded with lib/ci-provision-version.sh): it only warns, and "unknown" is a warn too.
#
# Portability: /bin/bash 3.2 and bash 5. Public names ci_status_* / ci_capability_state, internals _cis_*.

# The bundle files `aiteamforge ci` needs on disk. MUST equal libexec/lib/ci-runner-bundle.sh's list
# (tests/test-xaca-1443-ci-status.sh pins the two together; it also covers this file itself).
CI_STATUS_BUNDLE_FILES="provision-host.sh ci-host.sh create-ci-runner-user.sh teardown-host.sh runner-pin.conf lib/ci-host-lib.sh lib/ci-enable-guard.sh lib/ci-headroom.sh lib/ci-provision-version.sh lib/ci-runner-version.sh lib/ci-status.sh client/ci-pool-agent.py client/ci-runner-jit-guest.sh client/ci-runner-jit-macos.sh client/ci-runner-job-started.sh client/ci-runner-reporter.sh"

_cis_add() { # var-name line   (append a line to a newline list)
    eval "$1=\"\${$1:+\${$1}
}\$2\""
}
_cis_reason() { _cis_add CI_STATUS_REASONS "$1"; }
_cis_unseen() { _cis_add CI_STATUS_UNSEEN "$1"; _cis_add CI_STATUS_REASONS "unseen: $1"; _CIS_MIS=1; }
_cis_warn()   { _cis_add CI_STATUS_REASONS "$1"; _CIS_WARN=1; }
_cis_bad()    { _cis_add CI_STATUS_REASONS "$1"; _CIS_MIS=1; }

_cis_host_ok() { # same charset/length rule as aiteamforge-ci.sh::_valid_host and provision-host.sh --host
    case "${1:-}" in '') return 1 ;; [!a-z0-9]*|*[!a-z0-9-]*|*-) return 1 ;; esac
    [ "${#1}" -le 40 ]
}

# value of KEY in the state file: first match wins, value = everything after the first `=` (contract 002).
_cis_get() { awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$2" 2>/dev/null; }

# Does path $1 exist as ANY kind of directory entry (symlinks included, dangling too)?
_cis_present() { [ -e "$1" ] || [ -L "$1" ]; }

# _cis_scan_dir <dir> <glob-suffix> <label>  -> prints present paths; rc 0 looked, rc 3 could not look.
# A directory that does not exist is a definite "nothing there"; one that exists but cannot be searched is not.
_cis_dir_state() { # dir -> 0 searchable | 1 absent | 2 present but not searchable/readable
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then return 1; fi
    if [ -d "$1" ] && [ -r "$1" ] && [ -x "$1" ]; then return 0; fi
    return 2
}

# mode string (first 10 chars of ls -l) of $1; empty when ls fails.
_cis_mode() { local m; m="$(ls -ldn "$1" 2>/dev/null)" || return 1; m="${m%% *}"; printf '%s' "${m%"${m#??????????}"}"; }

# ---------------------------------------------------------------------------------------------------------------

ci_capability_state() {
    local aitf="${AITEAMFORGE_DIR:-${HOME:-}/aiteamforge}"
    local ld="${CI_LAUNCHDAEMONS_DIR:-/Library/LaunchDaemons}"
    local cuser="${CI_RUNNER_USER:-ci-runner}"
    local libx="${CI_LIBEXEC_DIR:-/usr/local/libexec}"
    local agcfg="${CI_AGENT_CFG_DIR:-/usr/local/etc/ci-pool-agent}"
    local pdir="${CIH_STATE_DIR:-/usr/local/etc/ci-runner}"
    local bundle="${aitf}/scripts/ci-runner" sf="${aitf}/.aiteamforge-ci-state"

    CI_STATUS_STATE="misconfigured"; CI_STATUS_LEVEL="fail"; CI_STATUS_HOST=""; CI_STATUS_REASONS=""
    CI_STATUS_SKEW="n/a"; CI_STATUS_SKEW_REASONS=""; CI_STATUS_SKEW_UNSEEN=""; CI_STATUS_SKEW_BLIND=""
    CI_STATUS_UNSEEN=""; CI_STATUS_NEXT=""; CI_STATUS_DEV=0
    _CIS_MIS=0; _CIS_WARN=0

    local rel f rc d
    local have_state=0 state_ok=0 state_val="" s_host="" with_macos="0" recorded_pv="" lane=""
    CI_STATUS_LANE=""
    local plists="" nplists=0 own=0 other=0 user=unseen art_list="" bundle_ok=1 bn

    # ---- 0. dev-team source machine (guard rc 10). Guard output is not wanted here.
    if [ -r "${bundle}/lib/ci-enable-guard.sh" ]; then
        rc=0
        # shellcheck source=/dev/null
        ( . "${bundle}/lib/ci-enable-guard.sh" && ci_enable_guard ) >/dev/null 2>&1 || rc=$?
        [ "$rc" != 10 ] || CI_STATUS_DEV=1
    elif [ -f "${HOME:-/nonexistent}/dev-team/.aiteamforge-source-tree" ] || [ -f "${aitf}/.aiteamforge-source-tree" ]; then
        CI_STATUS_DEV=1      # the guard library is gone but the XACA-0497 sentinel is not
    fi
    [ "$CI_STATUS_DEV" = 0 ] || _cis_reason "note: dev-team source machine (XACA-0497 sentinel): the CI capability is disabled by design here"

    # ---- 1. the shipped bundle (not required on the dev machine)
    if [ "$CI_STATUS_DEV" = 0 ]; then
        for rel in $CI_STATUS_BUNDLE_FILES; do
            if [ ! -f "${bundle}/${rel}" ]; then
                bundle_ok=0; _cis_add CI_STATUS_REASONS "bundle: ${rel} is missing from ${bundle}"
            elif [ ! -r "${bundle}/${rel}" ]; then
                bundle_ok=0; _cis_add CI_STATUS_REASONS "bundle: ${rel} in ${bundle} is not readable"
            fi
        done
        [ "$bundle_ok" = 1 ] || _CIS_MIS=1
    fi

    # ---- 2. the state file
    if _cis_present "$sf"; then
        have_state=1
        if [ -L "$sf" ] || [ ! -f "$sf" ]; then
            _cis_bad "state: ${sf} is not a regular file (symlink or directory)"
        elif [ ! -r "$sf" ]; then
            _cis_bad "state: ${sf} exists but cannot be read"
        else
            state_ok=1
            f="$(_cis_mode "$sf")" || f=""
            if [ -z "$f" ]; then _cis_unseen "state: cannot read the mode of ${sf}"; state_ok=0
            elif [ "$f" != "-rw-------" ]; then _cis_bad "state: ${sf} has mode ${f} (must be -rw------- / 600)"; state_ok=0; fi
            [ -O "$sf" ] || { _cis_bad "state: ${sf} is not owned by the invoking user"; state_ok=0; }
            # every non-comment, non-blank line must be key=value (keys: lowercase, digits, underscore)
            if ! awk '/^[[:space:]]*$/ { next } /^#/ { next } /^[a-z][a-z0-9_]*=/ { next } { bad = 1 } END { exit bad ? 1 : 0 }' "$sf" 2>/dev/null; then
                _cis_bad "state: ${sf} is corrupt (a line is not key=value or a # comment)"; state_ok=0
            else
                [ "$(_cis_get schema "$sf")" = 1 ] || { _cis_bad "state: unknown or missing schema '$(_cis_get schema "$sf")' (want 1)"; state_ok=0; }
                state_val="$(_cis_get state "$sf")"
                case "$state_val" in
                    enabled-pending|enabled|disable-pending) ;;
                    *) _cis_bad "state: unknown state value '${state_val}'"; state_ok=0 ;;
                esac
                s_host="$(_cis_get host "$sf")"
                _cis_host_ok "$s_host" || { _cis_bad "state: invalid host '${s_host}'"; state_ok=0; }
                with_macos="$(_cis_get with_macos "$sf")"
                # XACA-1461: the lane. Absent key = legacy file (derive from with_macos); a PRESENT key must be a known lane
                # (an empty `lane=` is not "absent"), and it must agree with with_macos.
                if awk -F= '$1=="lane" { f = 1 } END { exit f ? 0 : 1 }' "$sf" 2>/dev/null; then
                    lane="$(_cis_get lane "$sf")"
                    case "$lane" in
                        linux) [ "$with_macos" != 1 ] || { _cis_bad "state: lane=linux contradicts with_macos=1"; state_ok=0; } ;;
                        both)  [ "$with_macos" = 1 ] || { _cis_bad "state: lane=both needs with_macos=1 (got '${with_macos}')"; state_ok=0; } ;;
                        macos) [ "$with_macos" = 1 ] || { _cis_bad "state: lane=macos needs with_macos=1 (got '${with_macos}')"; state_ok=0; } ;;
                        *) _cis_bad "state: unknown lane '${lane}' (want linux, both or macos)"; state_ok=0 ;;
                    esac
                elif [ "$with_macos" = 1 ]; then lane=both
                else lane=linux; fi
                recorded_pv="$(_cis_get provision_version "$sf")"
            fi
            [ "$state_ok" = 1 ] && { CI_STATUS_HOST="$s_host"; CI_STATUS_LANE="$lane"; }
        fi
    elif [ -d "$aitf" ] && [ -r "$aitf" ] && [ -x "$aitf" ]; then
        :   # looked: no state file
    else
        _cis_unseen "state: cannot look into ${aitf}"
    fi

    # ---- 3. artefacts a user can see (no sudo)
    #   daemon plists (any com.doublenode.ci-runner*, legacy names included)
    rc=0; _cis_dir_state "$ld" || rc=$?
    case $rc in
        0) for f in "$ld"/com.doublenode.ci-runner*.plist; do
               if _cis_present "$f"; then plists="${plists:+${plists}
}${f}"; nplists=$((nplists + 1)); fi
           done ;;
        1) _cis_unseen "launchdaemons: ${ld} does not exist" ;;
        *) _cis_unseen "launchdaemons: cannot look into ${ld}" ;;
    esac
    #   the ci-runner user
    if command -v id >/dev/null 2>&1; then
        rc=0; id -u "$cuser" >/dev/null 2>&1 || rc=$?
        case "$rc" in 0) user=yes ;; 1) user=no ;; *) _cis_unseen "user: 'id -u ${cuser}' failed with rc ${rc}" ;; esac
    else
        _cis_unseen "user: id(1) is not available"
    fi
    #   pause markers, provision manifests (state dir), root-owned copies and agent config (read-only existence)
    local pm_list="" mf_list="" inst_list=""
    rc=0; _cis_dir_state "$pdir" || rc=$?
    case $rc in
        0) for f in "$pdir"/*.pause.json; do _cis_present "$f" && pm_list="${pm_list:+${pm_list}
}${f}"; done
           for f in "$pdir"/*.provision-manifest; do _cis_present "$f" && mf_list="${mf_list:+${mf_list}
}${f}"; done ;;
        1) : ;;
        *) _cis_unseen "state-dir: cannot look into ${pdir}" ;;
    esac
    rc=0; _cis_dir_state "$libx" || rc=$?
    if [ "$rc" = 2 ]; then _cis_unseen "libexec: cannot look into ${libx}"; fi
    rc=0; _cis_dir_state "$agcfg" || rc=$?
    if [ "$rc" = 2 ]; then _cis_unseen "agent-config: cannot look into ${agcfg}"; fi
    for f in "$libx/ci-pool-agent.py" "$libx/ci-runner-reporter.sh" "$libx/ci-runner-jit-macos.sh" "$libx/ci-runner-job-started.sh" \
             "$agcfg/agent.key" "$agcfg/agent.json"; do
        _cis_present "$f" && inst_list="${inst_list:+${inst_list}
}${f}"
    done

    # plists that belong to the state file's host / do not
    if [ -n "$plists" ]; then
        while IFS= read -r f; do
            bn="${f##*/}"; d=0
            if [ "$state_ok" = 1 ]; then
                for rel in agent reporter macos lima-vm; do [ "$bn" = "com.doublenode.ci-runner.${s_host}.${rel}.plist" ] && d=1; done
            fi
            if [ "$d" = 1 ]; then own=$((own + 1)); else other=$((other + 1)); _cis_add art_list "daemon plist: ${f}"; fi
        done <<EOF_PL
$plists
EOF_PL
    fi
    if [ "$state_ok" = 1 ]; then
        [ -z "$pm_list" ] || while IFS= read -r f; do [ "${f##*/}" = "${s_host}.pause.json" ] || _cis_add art_list "pause marker: ${f}"; done <<EOF_PM
$pm_list
EOF_PM
        [ -z "$mf_list" ] || while IFS= read -r f; do [ "${f##*/}" = "${s_host}.provision-manifest" ] || _cis_add art_list "provision manifest: ${f}"; done <<EOF_MF
$mf_list
EOF_MF
    else
        [ -z "$pm_list" ] || while IFS= read -r f; do _cis_add art_list "pause marker: ${f}"; done <<EOF_PM2
$pm_list
EOF_PM2
        [ -z "$mf_list" ] || while IFS= read -r f; do _cis_add art_list "provision manifest: ${f}"; done <<EOF_MF2
$mf_list
EOF_MF2
        [ -z "$inst_list" ] || while IFS= read -r f; do _cis_add art_list "installed file: ${f}"; done <<EOF_IN
$inst_list
EOF_IN
    fi

    # ---- 4. decide
    if [ "$have_state" = 0 ]; then
        # (a) no state file: dormant ONLY on positive evidence that nothing is left
        if [ -n "$art_list" ]; then
            _cis_bad "stray: CI artefacts remain but there is no state file (a hand provision or a half teardown):"
            while IFS= read -r f; do _cis_add CI_STATUS_REASONS "  ${f}"; done <<EOF_A
$art_list
EOF_A
        fi
        if [ "$user" = yes ] && [ -z "$art_list" ]; then
            _cis_reason "note: the ${cuser} user exists (kept by 'ci disable' unless --remove-user); no CI daemon or state remains"
        fi
        if [ "$_CIS_MIS" = 1 ]; then
            CI_STATUS_STATE="misconfigured"; CI_STATUS_LEVEL="fail"
        else
            CI_STATUS_STATE="dormant"; CI_STATUS_LEVEL="ok"
            if [ "$CI_STATUS_DEV" = 1 ]; then
                _cis_reason "dormant (dev-team source machine; CI capability disabled by design)"
            else
                _cis_reason "dormant: no state file, no CI daemon, marker, manifest or installed copy (the shipped default)"
            fi
        fi
    elif [ "$state_ok" = 0 ]; then
        # (b) a state file we cannot trust: misconfigured, whatever else is on disk
        CI_STATUS_STATE="misconfigured"; CI_STATUS_LEVEL="fail"
        [ -z "$art_list" ] || { _cis_add CI_STATUS_REASONS "also present:"; while IFS= read -r f; do _cis_add CI_STATUS_REASONS "  ${f}"; done <<EOF_B
$art_list
EOF_B
        }
        [ "$nplists" = 0 ] || _cis_add CI_STATUS_REASONS "daemon plists on disk: ${nplists}"
    else
        # (c) a usable state file: it must agree with the artefacts
        local need="agent reporter lima-vm" k lane_txt=""
        case "$lane" in
            both)  need="${need} macos" ;;
            macos) need="agent reporter macos"; lane_txt=" (macOS-only lane)" ;;
        esac
        local agent_plist=0
        _cis_present "$ld/com.doublenode.ci-runner.${s_host}.agent.plist" && agent_plist=1
        if [ "$other" != 0 ]; then
            _cis_bad "stray: CI artefacts that do not belong to host ${s_host}:"
            while IFS= read -r f; do _cis_add CI_STATUS_REASONS "  ${f}"; done <<EOF_C
$art_list
EOF_C
        fi
        case "$state_val" in
            enabled-pending)
                if [ "$_CIS_MIS" = 1 ]; then :
                elif [ "$user" = yes ] && [ "$agent_plist" = 1 ]; then
                    CI_STATUS_STATE="enable-pending"; CI_STATUS_LEVEL="warn"
                    _cis_reason "enable-pending: host ${s_host} looks provisioned (user and agent daemon exist) but 'ci enable --confirm' has not promoted it"
                    CI_STATUS_NEXT="aiteamforge ci enable --confirm"
                else
                    CI_STATUS_STATE="enable-pending"; CI_STATUS_LEVEL="warn"
                    _cis_reason "enable-pending: host ${s_host} is recorded but not provisioned yet (ci-runner user: ${user}; agent plist: $([ "$agent_plist" = 1 ] && echo present || echo missing))"
                    CI_STATUS_NEXT="run the sudo command printed by 'aiteamforge ci enable' (re-run it to print it again), then 'aiteamforge ci enable --confirm'"
                fi ;;
            disable-pending)
                if [ "$_CIS_MIS" != 1 ]; then
                    CI_STATUS_STATE="disable-pending"; CI_STATUS_LEVEL="warn"
                    _cis_reason "disable-pending: teardown of host ${s_host} was requested and not confirmed yet (daemon plists on disk for it: ${own})"
                    CI_STATUS_NEXT="run the sudo teardown command printed by 'aiteamforge ci disable', then 'aiteamforge ci disable --confirm'"
                fi ;;
            enabled)
                if [ "$user" != yes ]; then _cis_bad "enabled: the state file says enabled but the ${cuser} user is ${user}"; fi
                for k in $need; do
                    _cis_present "$ld/com.doublenode.ci-runner.${s_host}.${k}.plist" || { _cis_bad "enabled: the ${k} daemon plist for ${s_host} is missing from ${ld}"; }
                done
                if [ "$lane" = macos ] && _cis_present "$ld/com.doublenode.ci-runner.${s_host}.lima-vm.plist"; then
                    _cis_bad "enabled: lane=macos records no Linux VM, but the lima-vm daemon plist for ${s_host} exists in ${ld} (state and artefacts disagree)"
                fi
                if [ "$_CIS_MIS" = 1 ]; then
                    :
                else
                    CI_STATUS_STATE="enabled"; CI_STATUS_LEVEL="ok"
                    # paused? derived from the XACA-1440 marker
                    local mk="${pdir}/${s_host}.pause.json" mst=""
                    if _cis_present "$mk"; then
                        if [ -f "$mk" ] && [ ! -L "$mk" ] && [ -r "$mk" ] \
                           && grep -Eq '^  "schema_version": 1,?$' "$mk" 2>/dev/null \
                           && grep -Eq "^  \"host\": \"${s_host}\",?\$" "$mk" 2>/dev/null; then
                            mst="$(sed -n -E 's/^  "state": "(draining|paused|resuming)",?$/\1/p' "$mk" 2>/dev/null)" || mst=""
                            mst="${mst%%
*}"
                        fi
                        if [ -z "$mst" ]; then _cis_bad "pause: ${mk} exists but is not a valid XACA-1440 marker (schema_version 1, host ${s_host}, state draining|paused|resuming)"
                        else CI_STATUS_STATE="paused"; CI_STATUS_LEVEL="warn"; _cis_reason "paused: the pause marker says ${mst} (host ${s_host} takes no new CI jobs)"
                             CI_STATUS_NEXT="bash ${bundle}/ci-host.sh resume --host ${s_host}   (see ci-host.sh --help)"; fi
                    fi
                    if [ "$_CIS_MIS" != 1 ]; then
                        [ "$CI_STATUS_STATE" != enabled ] || _cis_reason "enabled: host ${s_host}${lane_txt}: ${cuser} user and the $(echo $need | tr ' ' ',') daemon plists exist (loaded state is not inspected)"
                        # skew (013): only for an enabled/paused host
                        local pv_lib="${bundle}/lib/ci-provision-version.sh" src=0
                        if [ -r "$pv_lib" ]; then
                            # shellcheck source=/dev/null
                            . "$pv_lib" 2>/dev/null || src=99
                            if [ "$src" = 99 ]; then
                                CI_STATUS_SKEW="unknown"; CI_STATUS_SKEW_UNSEEN="skew: cannot load ${pv_lib}"
                            else
                                src=0; ci_provision_skew "$s_host" "$bundle" "$recorded_pv" || src=$?
                                case "$src" in
                                    0) CI_STATUS_SKEW="in-sync" ;;
                                    1) CI_STATUS_SKEW="skewed" ;;
                                    *) CI_STATUS_SKEW="unknown" ;;
                                esac
                                # a verdict this classifier does not know is unknown, never in-sync
                                [ "${CI_SKEW_STATE:-}" = "$CI_STATUS_SKEW" ] || CI_STATUS_SKEW="unknown"
                                CI_STATUS_SKEW_REASONS="${CI_SKEW_REASONS:-}"; CI_STATUS_SKEW_UNSEEN="${CI_SKEW_UNSEEN:-}"; CI_STATUS_SKEW_BLIND="${CI_SKEW_BLIND:-}"
                            fi
                        else
                            CI_STATUS_SKEW="unknown"; CI_STATUS_SKEW_UNSEEN="skew: the provision-version library is missing (${pv_lib})"
                        fi
                        case "$CI_STATUS_SKEW" in
                            in-sync) ;;
                            skewed)
                                CI_STATUS_LEVEL="warn"
                                if [ -n "$CI_STATUS_SKEW_REASONS" ] && [ -z "$(printf '%s\n' "$CI_STATUS_SKEW_REASONS" | grep -v '^record:')" ]; then
                                    [ -n "$CI_STATUS_NEXT" ] || CI_STATUS_NEXT="aiteamforge ci refresh --confirm"
                                else
                                    [ "$CI_STATUS_STATE" != paused ] || CI_STATUS_NEXT="${CI_STATUS_NEXT}; then aiteamforge ci refresh"
                                    [ "$CI_STATUS_STATE" = paused ] || CI_STATUS_NEXT="aiteamforge ci refresh"
                                fi ;;
                            *)
                                CI_STATUS_LEVEL="warn"
                                [ -n "$CI_STATUS_NEXT" ] || CI_STATUS_NEXT="aiteamforge ci refresh --dry-run   (could not verify the host against this release)" ;;
                        esac
                        # a macos-lane host has no VM: never claim one was (not) inspected
                        [ "$lane" != macos ] || [ -z "$CI_STATUS_SKEW_BLIND" ] || CI_STATUS_SKEW_BLIND="this host has no Linux VM (lane=macos); loaded daemons and plist contents are not inspected"
                        [ -z "$CI_STATUS_SKEW_BLIND" ] || _cis_add CI_STATUS_REASONS "not inspected: ${CI_STATUS_SKEW_BLIND}"
                        if [ "$(type -t ci_status_runner_probe 2>/dev/null)" = function ]; then
                            ci_status_runner_probe "$s_host" || true
                            [ "$_CIS_MIS" = 1 ] || [ "$_CIS_WARN" = 0 ] || CI_STATUS_LEVEL="warn"
                        fi
                    fi
                fi ;;
        esac
        if [ "$_CIS_MIS" = 1 ]; then CI_STATUS_STATE="misconfigured"; CI_STATUS_LEVEL="fail"; fi
    fi

    # ---- 5. fail closed on the way out: anything unseen or marked bad can never leave as dormant/enabled
    if [ "$_CIS_MIS" = 1 ] && [ "$CI_STATUS_STATE" != misconfigured ]; then
        CI_STATUS_STATE="misconfigured"; CI_STATUS_LEVEL="fail"
    fi
    if [ "$CI_STATUS_STATE" = misconfigured ]; then
        CI_STATUS_SKEW="n/a"
        if [ -z "$CI_STATUS_NEXT" ]; then
            if [ "$bundle_ok" = 0 ]; then CI_STATUS_NEXT="aiteamforge upgrade   (restores the CI bundle)"
            elif [ -n "$CI_STATUS_UNSEEN" ] && [ "$have_state" = 0 ]; then CI_STATUS_NEXT="fix the unreadable path(s) listed above, then re-run 'aiteamforge ci status'"
            elif [ "$have_state" = 1 ] && [ "$state_ok" = 1 ]; then
                if [ "$state_val" = enabled ] || [ "$state_val" = enabled-pending ]; then CI_STATUS_NEXT="aiteamforge ci disable --force   (then 'aiteamforge ci enable' again); a missing daemon needs the sudo line from 'aiteamforge ci refresh --force'"; else CI_STATUS_NEXT="aiteamforge ci disable --force"; fi
            else CI_STATUS_NEXT="aiteamforge ci disable --force   (rebuilds a minimal state and prints the teardown line); a state file with mode != 600: chmod 600 ${sf}"; fi
        fi
    elif [ "$CI_STATUS_STATE" = dormant ] && [ -z "$CI_STATUS_NEXT" ]; then
        [ "$CI_STATUS_DEV" = 1 ] || CI_STATUS_NEXT="aiteamforge ci enable --help   (CI stays off until you run 'ci enable')"
    fi
    case "$CI_STATUS_LEVEL" in ok) return 0 ;; warn) return 1 ;; *) return 2 ;; esac
}
