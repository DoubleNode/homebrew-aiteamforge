#!/bin/bash
# vault-drift.sh
# Shared vault-fetch.js / vault-keygen.js drift detector (XACA-1322-013/014/015)
#
# vault-fetch.js require()s ./vault-keygen.js (a same-directory sibling in
# scripts/) and calls a handful of kg.* members on it to locate/talk to the
# fleet-monitor relay. An upgrade that refreshes vault-fetch.js but leaves a
# stale vault-keygen.js beside it crashes `cc` at runtime with
# "kg.<name> is not a function".
#
# ONE implementation, sourced by BOTH libexec/lib/validate-install.sh and
# libexec/commands/aiteamforge-doctor.sh — the two previously carried
# near-identical copies (_val_check_vault_drift / check_vault_keygen_drift)
# that had drifted: only ONE of the copies was hardened against a request()
# throw shadowing a real drift, and neither actually checked every kg.*
# member vault-fetch.js uses (both hardcoded resolveFleetUrl). A single
# shared implementation is the fix for that class of defect, not just the
# specific symptom (XACA-1322-013/014, PR #965 review).
#
# Callers only render this module's result in their own PASS/WARN/FAIL
# style — see _val_check_vault_drift() and check_vault_keygen_drift().
#
# ─── Public API ────────────────────────────────────────────────────────────
#
#   _aitf_vault_drift_check <installed_scripts_dir> <shipped_scripts_dir>
#
#   Sets globals _AITF_VD_STATUS (PASS|WARN|FAIL|SKIP) and _AITF_VD_MSG.
#   Always returns 0 -- callers branch on _AITF_VD_STATUS, not the return
#   code (this is a report generator, not a boolean gate).
#
#     SKIP  vault-fetch.js is not installed -- nothing to check. Its own
#           presence/absence is a separate, existing check.
#     FAIL  vault-keygen.js is missing, or (node probe) is missing one or
#           more kg.* members vault-fetch.js actually uses, or (no-node
#           fallback) differs byte-for-byte from the shipped copy.
#     WARN  inconclusive -- nothing could be verified either way. Never
#           silently upgraded to PASS.
#     PASS  every required member is present (node probe), or the
#           installed files are byte-identical to the shipped copies
#           (no-node fallback).
#
# Required members are DERIVED from the INSTALLED vault-fetch.js
# (`grep -oE 'kg\.[A-Za-z_$][A-Za-z0-9_$]*'`), not hardcoded -- so a future
# vault-fetch.js that starts using a new kg.* member is covered
# automatically, with no matching edit required in this file.

# Guard against double-sourcing.
if [[ -n "${_VAULT_DRIFT_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_VAULT_DRIFT_SH_LOADED=1

_AITF_VD_STATUS=""
_AITF_VD_MSG=""

# ─── Internal helpers ───────────────────────────────────────────────────────

# Resolve a node binary. aiteamforge-doctor.sh defines a richer, PATH-aware
# resolver (_x1097_resolve -- probes a login shell's PATH, not just the
# current one) that this file has no business re-implementing; use it when
# the sourcing shell already has it (i.e. we were sourced from
# aiteamforge-doctor.sh). validate-install.sh has no such helper, so its
# callers always fall through to the plain `command -v node`.
_aitf_vd_resolve_node() {
    if command -v _x1097_resolve >/dev/null 2>&1; then
        _x1097_resolve node
        return $?
    fi
    command -v node 2>/dev/null
}

# Derive the sorted, unique, bare (no "kg." prefix) member names an
# installed vault-fetch.js references. Prints one name per line; prints
# nothing if the file is unreadable or references none.
_aitf_vd_required_members() {
    local fetch_js="$1"
    [ -r "$fetch_js" ] || return 0
    grep -oE 'kg\.[A-Za-z_$][A-Za-z0-9_$]*' "$fetch_js" 2>/dev/null \
        | sed 's/^kg\.//' \
        | sort -u
}

# ─── Public entrypoint ──────────────────────────────────────────────────────

_aitf_vault_drift_check() {
    local installed_scripts_dir="$1"
    local shipped_scripts_dir="$2"

    _AITF_VD_STATUS=""
    _AITF_VD_MSG=""

    local fetch_js="${installed_scripts_dir}/vault-fetch.js"
    local keygen_js="${installed_scripts_dir}/vault-keygen.js"

    # Nothing to check if vault-fetch.js itself isn't installed -- its own
    # presence/absence is covered by a separate, existing check.
    if [ ! -f "$fetch_js" ]; then
        _AITF_VD_STATUS="SKIP"
        _AITF_VD_MSG="vault-fetch.js not installed -- vault drift check not applicable"
        return 0
    fi

    if [ ! -f "$keygen_js" ]; then
        _AITF_VD_STATUS="FAIL"
        _AITF_VD_MSG="vault-keygen.js missing but vault-fetch.js requires it -- kb-msg vault ops will crash. Run: aiteamforge upgrade --non-interactive"
        return 0
    fi

    # Derive the required set from the INSTALLED vault-fetch.js -- not a
    # hardcoded name -- so a future member vault-fetch.js starts using is
    # covered automatically (XACA-1322-014).
    local required_members
    required_members="$(_aitf_vd_required_members "$fetch_js")"

    if [ -z "$required_members" ]; then
        _AITF_VD_STATUS="WARN"
        _AITF_VD_MSG="could not determine which vault-keygen.js exports vault-fetch.js requires (no kg.* references found in ${fetch_js}, or it is unreadable)"
        return 0
    fi

    # bash-3.2-safe: build the array via a while-read loop over a heredoc
    # (NOT a pipe -- a pipe would fork a subshell and the array populated
    # inside it would be lost the moment the loop exits).
    local -a required_arr
    required_arr=()
    local _vd_line
    while IFS= read -r _vd_line; do
        # `if`, not a bare `[ ] && cmd` -- see the node-probe comment below
        # for why a bare compound statement that can evaluate falsy is
        # unsafe under a caller's `set -e`.
        if [ -n "$_vd_line" ]; then
            required_arr+=("$_vd_line")
        fi
    done <<EOF_AITF_VD_REQUIRED
$required_members
EOF_AITF_VD_REQUIRED

    # ── Primary check: a real node probe, when node is resolvable ──────────
    # A require() failure for an UNRELATED reason (e.g. libsodium-wrappers
    # not installed) says nothing about whether THIS file exports the
    # members vault-fetch.js needs -- fall through to the fallback below
    # rather than reporting PASS or FAIL off an unrelated error.
    local node_bin=""
    node_bin="$(_aitf_vd_resolve_node)"

    if [ -n "$node_bin" ] && [ -x "$node_bin" ]; then
        local probe_out probe_rc
        # NOTE: this MUST be the condition of an `if` (not a bare
        # `probe_out=$(...); probe_rc=$?`) -- both callers of this shared
        # lib run under `set -e` (aiteamforge-doctor.sh unconditionally; a
        # sourcing shell may too), and a bare assignment statement whose
        # command substitution exits non-zero (exactly what happens on
        # every FAIL probe, process.exit(1)) aborts the WHOLE calling
        # script right here under `set -e`. As the condition of an `if`,
        # the exit status is consumed by the `if`, not by `set -e`.
        if probe_out="$("$node_bin" -e '
            let kg;
            try {
                kg = require(process.argv[1]);
            } catch (e) {
                console.error("REQUIRE_FAILED:" + (e && e.message ? e.message : String(e)));
                process.exit(2);
            }
            var required = process.argv.slice(2);
            var missing = [];
            for (var i = 0; i < required.length; i++) {
                if (typeof kg[required[i]] === "undefined") missing.push(required[i]);
            }
            if (missing.length > 0) {
                console.log(missing.join(","));
                process.exit(1);
            }
            process.exit(0);
        ' "$keygen_js" "${required_arr[@]}" 2>&1)"; then
            probe_rc=0
        else
            probe_rc=$?
        fi

        if [ "$probe_rc" -eq 0 ]; then
            _AITF_VD_STATUS="PASS"
            _AITF_VD_MSG="vault-keygen.js exports all ${#required_arr[@]} kg.* member(s) vault-fetch.js uses (verified via node require)"
            return 0
        elif [ "$probe_rc" -eq 1 ]; then
            local missing_csv missing_count missing_first
            missing_csv="$probe_out"
            missing_count="$(printf '%s' "$missing_csv" | awk -F',' '{print NF}')"
            missing_first="${missing_csv%%,*}"
            _AITF_VD_STATUS="FAIL"
            if [ "$missing_count" -eq 1 ]; then
                _AITF_VD_MSG="vault-keygen.js loads but does NOT export kg.${missing_first} -- stale copy beside a current vault-fetch.js (kg.${missing_first} is not a function). Run: aiteamforge upgrade --non-interactive"
            else
                _AITF_VD_MSG="vault-keygen.js loads but does NOT export ${missing_count} member(s) vault-fetch.js requires: ${missing_csv} -- stale copy beside a current vault-fetch.js. Run: aiteamforge upgrade --non-interactive"
            fi
            return 0
        fi
        # probe_rc == 2 (or anything else): require() itself threw --
        # inconclusive about THIS file. Fall through to the fallback below
        # instead of reporting drift off an unrelated error.
        unset probe_out probe_rc
    fi

    # ── Fallback: no node, or its require() probe above could not complete.
    # NO JS text parsing -- a prior static grep/awk fallback misdiagnosed
    # real files (false PASS on an indented/one-line exports block that
    # merely mentions the required name later in the file; false FAIL when
    # an earlier nested flush-left brace truncated the scan -- XACA-1322-015,
    # PR #965 review). Byte-compare the installed files against the shipped
    # copies instead: no parsing, no heuristic, no false signal.
    local shipped_fetch="${shipped_scripts_dir}/vault-fetch.js"
    local shipped_keygen="${shipped_scripts_dir}/vault-keygen.js"

    if [ -z "$shipped_scripts_dir" ] || [ ! -r "$shipped_keygen" ] || [ ! -r "$shipped_fetch" ]; then
        _AITF_VD_STATUS="WARN"
        _AITF_VD_MSG="could not verify vault-keygen.js/vault-fetch.js -- node probe unavailable and the shipped copy is missing or unreadable (looked in: ${shipped_scripts_dir:-<none>})"
        return 0
    fi

    if [ ! -r "$keygen_js" ] || [ ! -r "$fetch_js" ]; then
        _AITF_VD_STATUS="WARN"
        _AITF_VD_MSG="could not verify vault-keygen.js/vault-fetch.js -- node probe unavailable and the installed file is not readable"
        return 0
    fi

    # Same `set -e` hazard as the node probe above: cmp -s returns 1 when
    # the files differ, which is the FAIL case we specifically need to
    # detect -- so it must never be a bare statement here.
    local keygen_cmp_rc fetch_cmp_rc
    if cmp -s "$keygen_js" "$shipped_keygen"; then keygen_cmp_rc=0; else keygen_cmp_rc=$?; fi
    if cmp -s "$fetch_js" "$shipped_fetch"; then fetch_cmp_rc=0; else fetch_cmp_rc=$?; fi

    if [ "$keygen_cmp_rc" -eq 0 ] && [ "$fetch_cmp_rc" -eq 0 ]; then
        _AITF_VD_STATUS="PASS"
        _AITF_VD_MSG="vault-keygen.js and vault-fetch.js match the shipped copy; node probe unavailable"
    elif [ "$keygen_cmp_rc" -le 1 ] && [ "$fetch_cmp_rc" -le 1 ]; then
        # Both comparisons RAN (cmp -s: 0 identical, 1 differ) -- a clean
        # drift signal.
        _AITF_VD_STATUS="FAIL"
        _AITF_VD_MSG="vault-keygen.js/vault-fetch.js differ from the shipped copy -- node probe unavailable to check exports directly. Run: aiteamforge upgrade --non-interactive"
    else
        # cmp itself could not run (>1: e.g. a race removed a file between
        # the readability check above and here) -- inconclusive, not FAIL.
        _AITF_VD_STATUS="WARN"
        _AITF_VD_MSG="could not verify vault-keygen.js/vault-fetch.js -- byte comparison against the shipped copy did not complete"
    fi
    return 0
}
