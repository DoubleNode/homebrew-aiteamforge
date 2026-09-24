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
# ─── XACA-1322 rounds 2–5: why this file does NOT parse JavaScript ─────────
#
# PR #965 rounds 2 through 5 iterated a static awk-based JS lexer here
# (regex/division disambiguation, string/template/comment stripping, a
# token-accounting ratchet enumerating every "kg" occurrence) that tried to
# derive the required kg.* member set directly from an installed
# vault-fetch.js and verify a node probe (or the lexer itself, when no node
# was on PATH) against it. Each round closed one desync the reviewer
# demonstrated and the reviewer found the next one: regex-vs-division after
# `if (…)`, `i++ / 2`, a template literal immediately before `/`,
# `await`/`yield` as regex-permitting keywords the lexer's keyword table
# didn't carry. Static JS lexing without a real parser is an open-ended
# adversarial surface — every fix bought one more round, not soundness —
# and every desync in THIS direction (mis-lexed division read as a regex
# start, or vice versa) manifests as a MISSED `kg.*` reference, which
# reads as a false PASS on a real drift. That is the one failure mode this
# check exists to prevent, so the user decided to remove static JS parsing
# from the runtime check entirely rather than keep chasing round 6.
#
# What replaces it: byte comparison against the shipped copy. The upgrade
# bug this ticket exists to catch — a refreshed vault-fetch.js left beside
# a stale vault-keygen.js, or vice versa — is exactly a case where the
# INSTALLED file differs from what THIS tap release shipped. `cmp` needs no
# parsing, has no heuristic, and cannot be desynchronized by JS syntax it
# was never asked to understand. The trade-off: byte-compare cannot catch a
# tap release that ships a vault-fetch.js and vault-keygen.js that are
# already mutually inconsistent with each other (both installed exactly as
# shipped, but the shipped pair itself is broken). That case is covered
# separately — see tests/test-xaca-1322-shipped-kg-contract.sh, a CI-time
# contract test that runs once against the fixed, trusted shipped files
# (not arbitrary installed input), where a simple grep-derived member list
# plus a real `node -e require()` is sound because the input isn't
# adversarial.
#
# ─── Public API ────────────────────────────────────────────────────────────
#
#   _aitf_vault_drift_check <installed_scripts_dir> <shipped_scripts_dir>
#
#   Sets globals _AITF_VD_STATUS (PASS|WARN|FAIL|SKIP) and _AITF_VD_MSG.
#   Always returns 0 -- callers branch on _AITF_VD_STATUS, not the return
#   code (this is a report generator, not a boolean gate). Every internal
#   command substitution / pipeline below is guarded, or is the condition
#   of an `if`, specifically so this holds even under a caller's
#   `set -eo pipefail` (XACA-1322-016). A bare, unguarded assignment whose
#   command substitution fails is exactly what let this function abort the
#   WHOLE calling script (doctor.sh / a sourcing validate-install.sh caller)
#   instead of reporting WARN/FAIL, on the one consumer this file exists to
#   protect: a machine with no node on PATH -- and byte comparison needs no
#   node at all, so that consumer is now the common case, not a fallback.
#
#     SKIP  vault-fetch.js is not installed -- nothing to check. Its own
#           presence/absence is a separate, existing check.
#     FAIL  vault-keygen.js is missing entirely, or the installed
#           vault-keygen.js and/or vault-fetch.js differ byte-for-byte from
#           the copies shipped with this tap release -- naming which
#           file(s) differ.
#     WARN  inconclusive -- the shipped copies are unavailable/unreadable
#           (nothing to compare against), or an installed file that should
#           exist is not readable. Never silently upgraded to PASS.
#     PASS  both installed files are byte-identical to the shipped copies.

# Guard against double-sourcing.
if [[ -n "${_VAULT_DRIFT_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_VAULT_DRIFT_SH_LOADED=1

_AITF_VD_STATUS=""
_AITF_VD_MSG=""

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

    # No shipped copy to compare against -- inconclusive, never a silent
    # PASS. This covers an unset shipped_scripts_dir, a missing shipped
    # dir, and an unreadable shipped file (e.g. a partial/corrupt tap
    # checkout) all the same way: there is nothing sound to compare here.
    local shipped_fetch="${shipped_scripts_dir}/vault-fetch.js"
    local shipped_keygen="${shipped_scripts_dir}/vault-keygen.js"
    if [ -z "$shipped_scripts_dir" ] || [ ! -r "$shipped_keygen" ] || [ ! -r "$shipped_fetch" ]; then
        _AITF_VD_STATUS="WARN"
        _AITF_VD_MSG="could not verify (shipped copies unavailable) -- looked in: ${shipped_scripts_dir:-<none>}"
        return 0
    fi

    if [ ! -r "$keygen_js" ]; then
        _AITF_VD_STATUS="WARN"
        _AITF_VD_MSG="could not verify vault-keygen.js -- installed file exists but is not readable"
        return 0
    fi

    if [ ! -r "$fetch_js" ]; then
        _AITF_VD_STATUS="WARN"
        _AITF_VD_MSG="could not verify vault-fetch.js -- installed file exists but is not readable"
        return 0
    fi

    # Byte comparison only -- no JS parsing of any kind (see the header
    # comment above for why). `cmp -s` is the condition of an `if`, not a
    # bare assignment, so a differing-files exit status (1) can never abort
    # the calling script under a caller's `set -eo pipefail`.
    local keygen_cmp_rc fetch_cmp_rc
    if cmp -s "$keygen_js" "$shipped_keygen"; then keygen_cmp_rc=0; else keygen_cmp_rc=1; fi
    if cmp -s "$fetch_js" "$shipped_fetch"; then fetch_cmp_rc=0; else fetch_cmp_rc=1; fi

    if [ "$keygen_cmp_rc" -eq 0 ] && [ "$fetch_cmp_rc" -eq 0 ]; then
        _AITF_VD_STATUS="PASS"
        _AITF_VD_MSG="vault-keygen.js and vault-fetch.js match the shipped copy"
        return 0
    fi

    if [ "$keygen_cmp_rc" -ne 0 ] && [ "$fetch_cmp_rc" -ne 0 ]; then
        _AITF_VD_STATUS="FAIL"
        _AITF_VD_MSG="vault-keygen.js and vault-fetch.js both differ from the shipped copy -- stale files beside a current install. Run: aiteamforge upgrade --non-interactive"
    elif [ "$keygen_cmp_rc" -ne 0 ]; then
        _AITF_VD_STATUS="FAIL"
        _AITF_VD_MSG="vault-keygen.js differs from the shipped copy -- stale file beside a current install. Run: aiteamforge upgrade --non-interactive"
    else
        _AITF_VD_STATUS="FAIL"
        _AITF_VD_MSG="vault-fetch.js differs from the shipped copy -- stale file beside a current install. Run: aiteamforge upgrade --non-interactive"
    fi
    return 0
}
