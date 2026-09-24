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
#   code (this is a report generator, not a boolean gate). Every internal
#   command substitution / pipeline below is guarded (`|| true`, or is the
#   condition of an `if`) specifically so this holds even under a caller's
#   `set -eo pipefail` -- see the XACA-1322-016 comments inline. A bare,
#   unguarded assignment whose command substitution fails is exactly what
#   let this function abort the WHOLE calling script (doctor.sh / a sourcing
#   validate-install.sh caller) instead of reporting WARN/FAIL, on the one
#   consumer this file exists to protect: a machine with no node on PATH.
#
#     SKIP  vault-fetch.js is not installed -- nothing to check. Its own
#           presence/absence is a separate, existing check.
#     FAIL  vault-keygen.js is missing, or (node probe) is missing one or
#           more kg.* members vault-fetch.js actually uses -- or exports one
#           as something other than a function when vault-fetch.js CALLS it
#           -- or (no-node fallback) differs byte-for-byte from the shipped
#           copy.
#     WARN  inconclusive -- nothing could be verified either way, OR the
#           node probe verified every kg.* member it could statically
#           resolve but the scan also found an access pattern it cannot
#           safely resolve (bracket/computed access, destructuring, or
#           aliasing -- see _aitf_vd_scan_kg_usage). Never silently
#           upgraded to PASS: an unresolvable pattern can still hide a
#           stale/missing member.
#     PASS  every required member is present (node probe) with the right
#           JS type (a function, for every member vault-fetch.js actually
#           CALLS -- not just merely present, XACA-1322-019), and no
#           unresolvable access pattern was found; or the installed files
#           are byte-identical to the shipped copies (no-node fallback).
#
# Required members are DERIVED from the INSTALLED vault-fetch.js
# (_aitf_vd_scan_kg_usage, below), not hardcoded -- so a future
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

# Derive every kg.* / kg[...] usage an installed vault-fetch.js contains.
# Prints one line per finding on stdout:
#
#   M:CALLED:<name>      kg.<name>(...) -- a real call. The node probe must
#                        find a FUNCTION (XACA-1322-019); merely being
#                        defined (e.g. null/a string/an object) is NOT
#                        enough -- kg.<name>() still throws at runtime.
#   M:NOTCALLED:<name>   kg.<name> referenced but never invoked. The probe
#                        only needs the member to be defined at all.
#   U:<description>      an access pattern the scanner cannot statically
#                        resolve to a plain kg.<name> reference: bracket /
#                        computed access (kg['x'], kg[x]), destructuring
#                        (`} = kg` / `}=kg`), or aliasing (`= kg;` /
#                        `= kg,`). _aitf_vault_drift_check downgrades an
#                        otherwise-PASS result to WARN when any U: line is
#                        present (XACA-1322-018) -- a FAIL is never
#                        downgraded; the blocking signal wins.
#
# A member seen BOTH called and not-called somewhere in the file is only
# ever reported as CALLED (the stricter requirement -- see the `delete`
# below).
#
# ── Comment handling ────────────────────────────────────────────────────
# `//` to end of line and `/* ... */` (including multi-line) are stripped
# BEFORE scanning, so a mere mention inside a comment or dead code is never
# counted as a real reference (a prior version of this scanner did no
# stripping at all and reported a false FAIL off exactly this -- a `//
# TODO: use kg.futureMember()` comment with no real call, XACA-1322-018
# review). LIMITATION: the stripper is a plain per-character state machine,
# not a JS tokenizer -- it does not know about string/template literals, so
# a literal "//" or "/*" INSIDE a string (e.g. a "http://..." URL) would be
# misread as the start of a comment and eat real code after it. The real
# vault-fetch.js does not currently contain such a literal; this is a
# known, accepted limitation rather than a full parser (XACA-1322-018
# review).
#
# ── Left-boundary rule (XACA-1322-017) ──────────────────────────────────
# A `kg.`/`kg[` match only counts when the character immediately before
# "kg" is: the start of the file, any character NOT in [A-Za-z0-9_$.], or
# the char sequence is the three-dot spread `...`. This excludes
# `pkg.version` (preceded by an identifier char), `_kg.x` (preceded by
# `_`), and `obj.kg.x` (preceded by a plain `.` that is not part of a `...`
# spread) -- while still counting the real
# `{ ...kg.fleetFetchInit(), ... }` spread shape used in the shipped file.
_aitf_vd_scan_kg_usage() {
    local fetch_js="$1"
    [ -r "$fetch_js" ] || return 0
    awk -v fetch_js="$fetch_js" '
        function left_ok(s, p,    prevc, three) {
            if (p == 1) return 1
            prevc = substr(s, p - 1, 1)
            if (prevc !~ /[A-Za-z0-9_$.]/) return 1
            if (p >= 4) {
                three = substr(s, p - 3, 3)
                if (three == "...") return 1
            }
            return 0
        }
        BEGIN {
            in_comment = 0
            cleaned = ""
            while ((getline line < fetch_js) > 0) {
                out = ""
                i = 1
                n = length(line)
                while (i <= n) {
                    if (in_comment) {
                        rest = substr(line, i)
                        p = index(rest, "*/")
                        if (p > 0) { i = i + p + 1; in_comment = 0 }
                        else { i = n + 1 }
                    } else {
                        c2 = substr(line, i, 2)
                        if (c2 == "//") {
                            i = n + 1
                        } else if (c2 == "/*") {
                            rest = substr(line, i + 2)
                            p = index(rest, "*/")
                            if (p > 0) { i = i + 2 + p + 1 }
                            else { in_comment = 1; i = n + 1 }
                        } else {
                            out = out substr(line, i, 1)
                            i++
                        }
                    }
                }
                cleaned = cleaned out "\n"
            }
            close(fetch_js)

            s = cleaned
            slen = length(s)

            # ── kg.<member> -- membership + called/not-called ───────────
            pos = 1
            while (pos <= slen) {
                rest = substr(s, pos)
                if (!match(rest, /kg\./)) break
                abs = pos + RSTART - 1
                if (left_ok(s, abs)) {
                    after = substr(s, abs + 3)
                    if (match(after, /^[A-Za-z_$][A-Za-z0-9_$]*/)) {
                        member = substr(after, 1, RLENGTH)
                        tail = substr(after, RLENGTH + 1)
                        sub(/^[ \t\r\n]*/, "", tail)
                        if (substr(tail, 1, 1) == "(") {
                            called[member] = 1
                        } else {
                            notcalled[member] = 1
                        }
                        pos = abs + 3 + RLENGTH
                        continue
                    }
                }
                pos = abs + 1
            }

            # ── kg[ -- bracket / computed access (unrecognized) ─────────
            pos = 1
            while (pos <= slen) {
                rest = substr(s, pos)
                if (!match(rest, /kg\[/)) break
                abs = pos + RSTART - 1
                if (left_ok(s, abs)) {
                    snippet = substr(s, abs, 30)
                    gsub(/[\n\r]/, " ", snippet)
                    key = "bracket:" snippet
                    if (!(key in unrec)) { unrec[key] = 1; unrec_order[++unrec_n] = "bracket/computed access: " snippet }
                }
                pos = abs + 2
            }

            # ── destructuring: "} = kg" / "}=kg" (unrecognized) ─────────
            pos = 1
            while (pos <= slen) {
                rest = substr(s, pos)
                if (!match(rest, /}[ \t]*=[ \t]*kg/)) break
                abs = pos + RSTART - 1
                mlen = RLENGTH
                nextc = substr(s, abs + mlen, 1)
                if (nextc !~ /[A-Za-z0-9_$]/) {
                    snippet = substr(s, abs, mlen)
                    gsub(/[\n\r]/, " ", snippet)
                    key = "destructure:" snippet
                    if (!(key in unrec)) { unrec[key] = 1; unrec_order[++unrec_n] = "destructuring from kg: " snippet }
                }
                pos = abs + mlen
            }

            # ── aliasing: "= kg;" / "= kg," (unrecognized) ──────────────
            pos = 1
            while (pos <= slen) {
                rest = substr(s, pos)
                if (!match(rest, /=[ \t]*kg[ \t]*[;,]/)) break
                abs = pos + RSTART - 1
                mlen = RLENGTH
                prevc = (abs > 1) ? substr(s, abs - 1, 1) : ""
                # Exclude "}" too -- "}=kg;"/"}= kg," is the destructuring
                # shape above, already reported as destructure; without
                # this the same text would be double-reported as an alias.
                if (prevc !~ /[=!<>}]/) {
                    snippet = substr(s, abs, mlen)
                    gsub(/[\n\r]/, " ", snippet)
                    key = "alias:" snippet
                    if (!(key in unrec)) { unrec[key] = 1; unrec_order[++unrec_n] = "kg aliased to another name: " snippet }
                }
                pos = abs + mlen
            }

            # A member seen both called and not-called anywhere in the
            # file is reported CALLED only -- the stricter requirement.
            for (m in called) if (m in notcalled) delete notcalled[m]

            for (m in called) print "M:CALLED:" m
            for (m in notcalled) print "M:NOTCALLED:" m
            for (k = 1; k <= unrec_n; k++) print "U:" unrec_order[k]
        }
    ' 2>/dev/null
    return 0
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
    #
    # XACA-1322-016: `|| true` is REQUIRED here, not cosmetic. Both callers
    # of this shared lib run under `set -eo pipefail` (doctor.sh
    # unconditionally; a sourcing validate-install.sh caller may too), and
    # _aitf_vd_scan_kg_usage's internal awk can legitimately report "no
    # matches" for a file with zero kg.* references -- without the guard, a
    # bare `var=$(...)` whose command substitution exits non-zero aborts
    # the WHOLE calling script right here, silently, before the WARN below
    # is ever reached. See the doctor-wrapper / validate-install-wrapper
    # `set -eo pipefail` rows in tests/test-xaca-1322-vault-drift.sh.
    local scan_output=""
    scan_output="$(_aitf_vd_scan_kg_usage "$fetch_js")" || true

    # bash-3.2-safe: build the arrays via a while-read loop over a heredoc
    # (NOT a pipe -- a pipe would fork a subshell and the arrays populated
    # inside it would be lost the moment the loop exits).
    local -a called_arr notcalled_arr unrec_arr
    called_arr=()
    notcalled_arr=()
    unrec_arr=()
    local _vd_line
    while IFS= read -r _vd_line; do
        # `case`, not a bare `[ ] && cmd` -- see the node-probe comment
        # below for why a bare compound statement that can evaluate falsy
        # is unsafe under a caller's `set -e`.
        case "$_vd_line" in
            M:CALLED:*) called_arr+=("${_vd_line#M:CALLED:}") ;;
            M:NOTCALLED:*) notcalled_arr+=("${_vd_line#M:NOTCALLED:}") ;;
            U:*) unrec_arr+=("${_vd_line#U:}") ;;
            *) : ;;
        esac
    done <<EOF_AITF_VD_SCAN
$scan_output
EOF_AITF_VD_SCAN

    # Join unrec_arr for messages (bash-3.2-safe, no `printf -v`/associative
    # array reliance).
    local _unrec_joined="" _u
    for _u in "${unrec_arr[@]}"; do
        if [ -z "$_unrec_joined" ]; then
            _unrec_joined="$_u"
        else
            _unrec_joined="${_unrec_joined}; ${_u}"
        fi
    done

    if [ "${#called_arr[@]}" -eq 0 ] && [ "${#notcalled_arr[@]}" -eq 0 ]; then
        _AITF_VD_STATUS="WARN"
        if [ -n "$_unrec_joined" ]; then
            _AITF_VD_MSG="could not fully verify: ${_unrec_joined}"
        else
            _AITF_VD_MSG="could not determine which vault-keygen.js exports vault-fetch.js requires (no kg.* references found in ${fetch_js}, or it is unreadable)"
        fi
        return 0
    fi

    local total_required=$(( ${#called_arr[@]} + ${#notcalled_arr[@]} ))

    # ── Primary check: a real node probe, when node is resolvable ──────────
    # A require() failure for an UNRELATED reason (e.g. libsodium-wrappers
    # not installed) says nothing about whether THIS file exports the
    # members vault-fetch.js needs -- fall through to the fallback below
    # rather than reporting PASS or FAIL off an unrelated error.
    #
    # XACA-1322-016: `|| node_bin=""` is REQUIRED here too -- when node is
    # not resolvable at all (the exact machine this fallback exists for),
    # both the _x1097_resolve arm and the plain `command -v node` arm
    # return 1, and a bare `node_bin="$(...)"` assignment with no guard
    # aborts the whole calling script under `set -eo pipefail` before the
    # no-node fallback below is ever reached.
    local node_bin=""
    node_bin="$(_aitf_vd_resolve_node)" || node_bin=""

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
            var args = process.argv.slice(2);
            var calledReq = [];
            var notCalledReq = [];
            var mode = null;
            for (var i = 0; i < args.length; i++) {
                if (args[i] === "--called--") { mode = "called"; continue; }
                if (args[i] === "--notcalled--") { mode = "notcalled"; continue; }
                if (mode === "called") calledReq.push(args[i]);
                else if (mode === "notcalled") notCalledReq.push(args[i]);
            }
            var missing = [];
            // XACA-1322-019: a member vault-fetch.js actually CALLS must be
            // a FUNCTION -- merely being defined (null / a string / a
            // plain object) still throws "kg.<name> is not a function" at
            // the real call site. A presence-only check (`!== "undefined"`)
            // cannot see that class of drift.
            for (var i = 0; i < calledReq.length; i++) {
                if (typeof kg[calledReq[i]] !== "function") missing.push(calledReq[i]);
            }
            // A member vault-fetch.js only REFERENCES (never calls) just
            // needs to exist.
            for (var i = 0; i < notCalledReq.length; i++) {
                if (typeof kg[notCalledReq[i]] === "undefined") missing.push(notCalledReq[i]);
            }
            if (missing.length > 0) {
                console.log(missing.join(","));
                process.exit(1);
            }
            process.exit(0);
        ' "$keygen_js" --called-- "${called_arr[@]}" --notcalled-- "${notcalled_arr[@]}" 2>&1)"; then
            probe_rc=0
        else
            probe_rc=$?
        fi

        if [ "$probe_rc" -eq 0 ]; then
            if [ -n "$_unrec_joined" ]; then
                # XACA-1322-018: every dot-member the scanner COULD resolve
                # checked out, but it also found an access pattern it
                # cannot statically resolve (bracket/computed access,
                # destructuring, or aliasing) -- a stale/missing member
                # reached only that way would still crash at runtime while
                # reading PASS here. Downgrade to WARN; never silently
                # upgrade an unresolvable pattern to PASS. A FAIL (below)
                # is never downgraded this way -- the blocking signal wins.
                _AITF_VD_STATUS="WARN"
                _AITF_VD_MSG="vault-keygen.js exports all ${total_required} kg.* member(s) vault-fetch.js references directly (verified via node require), but could not fully verify: ${_unrec_joined} -- inspect manually"
            else
                _AITF_VD_STATUS="PASS"
                _AITF_VD_MSG="vault-keygen.js exports all ${total_required} kg.* member(s) vault-fetch.js uses (verified via node require)"
            fi
            return 0
        elif [ "$probe_rc" -eq 1 ]; then
            local missing_csv missing_count missing_first
            missing_csv="$probe_out"
            missing_count="$(printf '%s' "$missing_csv" | awk -F',' '{print NF}')" || missing_count=1
            missing_count="${missing_count:-1}"
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
