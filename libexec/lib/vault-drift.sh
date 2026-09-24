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
#   U:<description>      a `kg` occurrence the scanner cannot account for
#                        as a recognized member access or the one allowed
#                        require() binding -- see the token-accounting
#                        ratchet below (XACA-1322-021). Includes the
#                        former named categories (bracket/computed access
#                        `kg['x']`, destructuring `} = kg`, aliasing
#                        `= kg;`) as well as every other shape.
#                        _aitf_vault_drift_check downgrades an otherwise-
#                        PASS result to WARN when any U: line is present
#                        (XACA-1322-018) -- a FAIL is never downgraded;
#                        the blocking signal wins.
#
# A member seen BOTH called and not-called somewhere in the file is only
# ever reported as CALLED (the stricter requirement -- see the `delete`
# below).
#
# ── Token-accounting ratchet (XACA-1322-021) ────────────────────────────
# 018's bracket/destructure/alias detectors each recognized exactly one
# named shape and let everything else through with NO output at all --
# `kg?.x`, `kg .x`, `kg<TAB>.x`, `kg\n  .x` (a chain broken across a
# line), `(kg).x`, `helper(kg)`, `[kg]`, a bare `let k = kg` with no
# trailing `;`/`,`, and `obj.kg.x` (kg itself as somebody else's member)
# were all invisible to both the required-member derivation AND the U:
# downgrade -- a file mixing one of these with an ordinary `kg.` call
# read as a clean PASS even though the member reached only that way could
# be genuinely missing. The fix closes the CLASS instead of enumerating
# more variants: every standalone `kg` IDENTIFIER TOKEN in the file (an
# occurrence of the two characters `k`,`g` bounded on both sides by
# start/end-of-string or a character NOT in [A-Za-z0-9_$] -- so `pkg`,
# `kgx`, `_kg` and `$kg` are never tokens at all) must be accounted for as
# exactly one of: (a) a recognized member access -- `kg.<member>` with an
# IMMEDIATE dot, subject to the left-boundary rule below (so `obj.kg.x`'s
# `kg` token, itself preceded by a plain `.`, is NOT a recognized access
# even though it IS a token); or (b) the single require() binding
# matching `(const|let|var)[ \t]+kg[ \t]*=[ \t]*require\(`, allowed at
# most once -- only the FIRST such match in the file is the accounted
# binding; a second `const kg = require(...)` is itself an extra,
# unaccounted token. Any other token occurrence emits exactly one
# `U:unaccounted kg token: <snippet>` line and can never fall through
# silently.
#
# ── Comment handling ────────────────────────────────────────────────────
# `//` to end of line and `/* ... */` (including multi-line) are stripped
# BEFORE scanning, so a mere mention inside a comment or dead code is never
# counted as a real reference (a prior version of this scanner did no
# stripping at all and reported a false FAIL off exactly this -- a `//
# TODO: use kg.futureMember()` comment with no real call, XACA-1322-018
# review). The stripper is a small single-pass lexer (POSIX/BWK-awk
# compatible, no gawk extensions), not just a "//"/"/*" scanner -- it
# tracks single- and double-quoted strings, template literals (including
# `${...}` substitutions, which are lexed as real code, including nested
# strings/comments/templates), and regex-vs-division disambiguation. A
# literal "//" or "/*" INSIDE a string/template/regex (e.g. a
# "http://..." URL) is no longer misread as a comment start -- string,
# template and regex CONTENTS are kept verbatim in the scanned text (never
# blanked), so a `kg` mention inside one can still only produce a WARN or
# FAIL (via the token-accounting ratchet below), never a false PASS
# (XACA-1322-023/024 review, fixing the XACA-1322-018 known limitation).
# FAIL-CLOSED AT EOF: if the file ends mid string/template/regex/block
# comment, or with an unclosed `${` substitution, the lexer emits a single
# `U:unterminated <kind>` line rather than silently treating whatever was
# scanned as complete.
#
# ── Left-boundary rule for RECOGNIZED member access (XACA-1322-017) ─────
# left_ok(), below, gates only whether an immediate `kg.<member>` counts
# as a RECOGNIZED access (case (a) in the token-accounting ratchet above)
# -- it is narrower than the token-boundary check the ratchet applies
# first. A `kg.` counts as recognized only when the character immediately
# before "kg" is: the start of the file, any character NOT in
# [A-Za-z0-9_$.], or the char sequence is the three-dot spread `...`. This
# excludes `pkg.version` (preceded by an identifier char -- not even a
# token) and `obj.kg.x` (its "kg" IS a standalone token -- preceded by a
# plain "." -- but is somebody else's member, not the free variable, so
# it falls through to the ratchet's unaccounted case) -- while still
# counting the real `{ ...kg.fleetFetchInit(), ... }` spread shape used
# in the shipped file.
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
        # is_regex_start(tok): true when a "/" seen immediately after
        # token/char "tok" (the last significant token/char, "" meaning
        # start-of-file or start of a `${...}` substitution) begins a
        # regex literal rather than division (XACA-1322-023/024 review).
        function is_regex_start(tok) {
            if (tok == "") return 1
            if (tok in KW) return 1
            if (length(tok) == 1 && index(REGEX_CHARS, tok) > 0) return 1
            return 0
        }
        BEGIN {
            # KW: the keywords after which a following "/" starts a regex,
            # not division (XACA-1322-023/024 spec).
            KW["return"] = 1; KW["typeof"] = 1; KW["case"] = 1; KW["do"] = 1
            KW["else"] = 1; KW["in"] = 1; KW["of"] = 1; KW["new"] = 1
            KW["delete"] = 1; KW["void"] = 1; KW["throw"] = 1
            KW["instanceof"] = 1
            # Single characters after which a following "/" starts a
            # regex, not division.
            REGEX_CHARS = "(,=:[!&|?{};+-*%<>~^"

            # Special characters, built via sprintf so none of them need
            # to appear literally inside this single-quoted shell string.
            SQC = sprintf("%c", 39)   # single quote
            DQC = sprintf("%c", 34)   # double quote
            BQC = sprintf("%c", 96)   # backtick
            BSC = sprintf("%c", 92)   # backslash

            # Lexer state: "CODE", "SQ" (single-quoted string), "DQ"
            # (double-quoted string), "TPL" (template literal content),
            # "REGEX" (regex literal), or "BCOMMENT" (block comment).
            # depth/stk_type track a stack of template ("TPL") and
            # template-substitution ("SUBST") frames so `${...}` nests to
            # any depth; subst_brace[depth] counts unmatched "{" inside a
            # SUBST frame so an inner object literal or block does not
            # close the substitution early.
            state = "CODE"
            depth = 0
            prev_tok = ""
            in_class = 0
            cleaned = ""

            while ((getline line < fetch_js) > 0) {
                out = ""
                i = 1
                n = length(line)
                while (i <= n) {
                    c1 = substr(line, i, 1)
                    c2 = substr(line, i, 2)

                    if (state == "BCOMMENT") {
                        if (c2 == "*/") { state = "CODE"; i += 2 }
                        else { i += 1 }
                        continue
                    }

                    if (state == "SQ" || state == "DQ") {
                        qc = (state == "SQ") ? SQC : DQC
                        if (c1 == BSC) {
                            if (i == n) { out = out c1; i += 1 }
                            else { out = out substr(line, i, 2); i += 2 }
                        } else if (c1 == qc) {
                            out = out c1; state = "CODE"; prev_tok = "VALUE"; i += 1
                        } else {
                            out = out c1; i += 1
                        }
                        continue
                    }

                    if (state == "TPL") {
                        if (c1 == BSC) {
                            if (i == n) { out = out c1; i += 1 }
                            else { out = out substr(line, i, 2); i += 2 }
                        } else if (c2 == "${") {
                            out = out c2
                            depth++
                            stk_type[depth] = "SUBST"
                            subst_brace[depth] = 1
                            state = "CODE"
                            prev_tok = ""
                            i += 2
                        } else if (c1 == BQC) {
                            out = out c1
                            depth--
                            state = (depth == 0) ? "CODE" : (stk_type[depth] == "TPL" ? "TPL" : "CODE")
                            i += 1
                        } else {
                            out = out c1; i += 1
                        }
                        continue
                    }

                    if (state == "REGEX") {
                        if (c1 == BSC) {
                            if (i == n) { out = out c1; i += 1 }
                            else { out = out substr(line, i, 2); i += 2 }
                        } else if (c1 == "[") {
                            in_class = 1; out = out c1; i += 1
                        } else if (c1 == "]") {
                            in_class = 0; out = out c1; i += 1
                        } else if (c1 == "/" && !in_class) {
                            out = out c1; state = "CODE"; prev_tok = "VALUE"; i += 1
                        } else {
                            out = out c1; i += 1
                        }
                        continue
                    }

                    # state == "CODE"
                    if (c2 == "//") {
                        i = n + 1
                    } else if (c2 == "/*") {
                        state = "BCOMMENT"; i += 2
                    } else if (c1 == SQC) {
                        state = "SQ"; out = out c1; i += 1
                    } else if (c1 == DQC) {
                        state = "DQ"; out = out c1; i += 1
                    } else if (c1 == BQC) {
                        depth++; stk_type[depth] = "TPL"; state = "TPL"; out = out c1; i += 1
                    } else if (c1 == "/") {
                        if (is_regex_start(prev_tok)) {
                            state = "REGEX"; in_class = 0; out = out c1; i += 1
                        } else {
                            out = out c1; prev_tok = "/"; i += 1
                        }
                    } else if (c1 == "{") {
                        if (depth > 0) subst_brace[depth]++
                        out = out c1; prev_tok = "{"; i += 1
                    } else if (c1 == "}" && depth > 0) {
                        subst_brace[depth]--
                        out = out c1
                        if (subst_brace[depth] == 0) {
                            depth--
                            state = (depth == 0) ? "CODE" : (stk_type[depth] == "TPL" ? "TPL" : "CODE")
                        } else {
                            prev_tok = "}"
                        }
                        i += 1
                    } else if (c1 ~ /[A-Za-z_$]/) {
                        rest = substr(line, i)
                        match(rest, /^[A-Za-z_$][A-Za-z0-9_$]*/)
                        word = substr(rest, 1, RLENGTH)
                        out = out word
                        prev_tok = (word in KW) ? word : "VALUE"
                        i += RLENGTH
                    } else if (c1 ~ /[0-9]/) {
                        rest = substr(line, i)
                        match(rest, /^[0-9][0-9A-Za-z_.]*/)
                        numtxt = substr(rest, 1, RLENGTH)
                        out = out numtxt
                        prev_tok = "VALUE"
                        i += RLENGTH
                    } else if (c1 ~ /[ \t\r]/) {
                        out = out c1; i += 1
                    } else {
                        out = out c1; prev_tok = c1; i += 1
                    }
                }
                cleaned = cleaned out "\n"
            }
            close(fetch_js)

            # FAIL-CLOSED AT EOF (XACA-1322-023/024): the lexer ending
            # mid-construct means the rest of the file was never really
            # scanned as code -- report exactly one unterminated-<kind>
            # line rather than silently trusting whatever was captured.
            if (state == "BCOMMENT") {
                unrec_n++; unrec_order[unrec_n] = "unterminated block comment"
            } else if (state == "SQ") {
                unrec_n++; unrec_order[unrec_n] = "unterminated single-quoted string"
            } else if (state == "DQ") {
                unrec_n++; unrec_order[unrec_n] = "unterminated double-quoted string"
            } else if (state == "REGEX") {
                unrec_n++; unrec_order[unrec_n] = "unterminated regex literal"
            } else if (state == "TPL") {
                unrec_n++; unrec_order[unrec_n] = "unterminated template literal"
            } else if (depth > 0) {
                unrec_n++; unrec_order[unrec_n] = "unterminated ${ substitution"
            }

            s = cleaned
            slen = length(s)

            # ── XACA-1322-021 token-accounting ratchet ───────────────────
            # Step 1: locate the ONE allowed require() binding, if any --
            # only its FIRST occurrence in the file counts. Find the "kg"
            # inside that match by literal index() (the pattern contains
            # no other "kg" substring), not a second regex.
            require_kg_abs = 0
            if (match(s, /(const|let|var)[ \t]+kg[ \t]*=[ \t]*require\(/)) {
                bind_match = substr(s, RSTART, RLENGTH)
                bind_off = index(bind_match, "kg")
                if (bind_off > 0) require_kg_abs = RSTART + bind_off - 1
            }

            # Step 2: walk every standalone "kg" TOKEN in the file (bounded
            # on both sides by start/end-of-string or a character NOT in
            # [A-Za-z0-9_$] -- so "pkg"/"kgx"/"_kg"/"$kg" never match) and
            # account for each one individually.
            pos = 1
            while (pos <= slen) {
                rest = substr(s, pos)
                if (!match(rest, /kg/)) break
                abs = pos + RSTART - 1

                tok_prevc = (abs > 1) ? substr(s, abs - 1, 1) : ""
                tok_nextc = substr(s, abs + 2, 1)
                left_is_boundary  = (abs == 1) || (tok_prevc !~ /[A-Za-z0-9_$]/)
                right_is_boundary = (tok_nextc == "") || (tok_nextc !~ /[A-Za-z0-9_$]/)

                if (left_is_boundary && right_is_boundary) {
                    if (abs == require_kg_abs) {
                        # (b) the one allowed require() binding -- silent,
                        # no M: or U: output.
                        pos = abs + 2
                        continue
                    }
                    recognized = 0
                    if (tok_nextc == "." && left_ok(s, abs)) {
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
                            recognized = 1
                        }
                    }
                    if (!recognized) {
                        # (c) unaccounted -- fail-closed, exactly one U:
                        # line per occurrence (position-keyed, so two
                        # textually-identical occurrences each still get
                        # their own line rather than being deduplicated
                        # away, and a shape already caught above -- e.g. a
                        # recognized kg.<member> -- never reaches here, so
                        # there is no risk of a double report per
                        # occurrence, XACA-1322-022).
                        snippet = substr(s, (abs > 10 ? abs - 10 : 1), 40)
                        gsub(/[\n\r\t]/, " ", snippet)
                        unrec_n++
                        unrec_order[unrec_n] = "unaccounted kg token: " snippet
                    }
                }
                pos = abs + 2
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
