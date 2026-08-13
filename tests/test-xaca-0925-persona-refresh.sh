#!/bin/bash

# test-xaca-0925-persona-refresh.sh
#
# Regression + structural tests for XACA-0925: `aiteamforge upgrade` never
# refreshed working-dir persona sources (${WORKING_DIR}/<team>/personas/agents),
# so persona CONTENT froze at install time while the Cellar advanced with every
# tap release. Measured on darren-m4-mini 2026-08-12: 9 of 11 teams stale, 54
# files differing from the Cellar. Working-dir mtimes 2026-06-05..06-08 vs
# Cellar 2026-08-12 — but the mtime gap is a RED HERRING: kb-sync-personas
# re-stamps deployed copies with today's date on every sync, so mtime is the
# one signal that actively CONCEALS this bug class. This is why every
# assertion below that exercises the refresh logic is content-based (cmp),
# never mtime-based, and T3 deliberately inverts the mtime relationship to
# prove the fix does not fall into the same trap.
#
# This is the FIFTH instance of "install-time provisioning the upgrade path
# cannot reach" (XACA-0578, 0594, 0771, 0814, now 0925). XACA-0771's
# retrospective (kanban/XACA-0771_upgrade_materialize_missing_RETROSPECTIVE.md)
# names the guard that would have caught the original bug: a structural test
# that the new update_* function is CALLED in the run sequence, not merely
# defined. T10/T11 below are that guard for this ticket.
#
# CONTRACT UNDER TEST (XACA-0925-006 — independent of whatever the sibling
# implementation subitem, XACA-0925-001, actually writes; these assertions are
# derived from the ticket's decided design, not from reading the fix):
#   New function `update_team_personas()` in aiteamforge-upgrade.sh:
#     1. Refreshes ${FRAMEWORK_DIR}/share/personas/<team>/agents/*.md into the
#        working-dir persona dir, UNCONDITIONALLY — no skip-if-modified.
#     2. Uses `cmp` for comparison, NEVER mtime/`-nt`.
#     3. Backs up the existing dir to
#        ~/aiteamforge-backups/personas/<team>/<YYYYMMDD-HHMMSS>/ before the
#        FIRST write for that team, ONLY when at least one file differs.
#     4. If nothing differs: no write, no backup (idempotent no-op).
#     5. Never deletes; orphan working-dir files survive and produce ONE
#        summary warning.
#     6. Honors DRY_RUN — writes nothing, takes no backup.
#     7. Creates the persona dir for installed teams that lack one (dns,
#        mainevent shape).
#     8. Enumerates teams from `.teams[]` in `.aiteamforge-config`, NOT a glob
#        of share/personas/*/.
#     9. Is CALLED in the run sequence after update_runtime_helpers, before
#        update_claude_hooks.
#
# ADDITIONAL CONTRACT (T13-T18, added resolving the 5 merge-gating findings
# filed against PR #745 by the test/review bots — XACA-0925-013/014/015/016/
# 017):
#    10. A failed backup MUST block the write — the destination is left
#        exactly as it was, never partially or fully overwritten
#        (XACA-0925-013/015, T13).
#    11. A failed per-file cp does not abort the whole team's write: other
#        files that CAN be written still are; the reported count is the
#        TRUE (not attempted) count; no success message is printed on
#        partial failure (XACA-0925-013/015, T14).
#    12. The caller's `if ! _xaca0925_refresh_team_personas; then` fail-soft
#        branch is a LIVE code path (it was dead code before this fix, since
#        the helper always returned 0): one team's failure warns and does
#        not stop remaining teams from refreshing (XACA-0925-013/015, T15).
#    13. An unreadable (permission-denied) shipped persona source dir logs
#        DISTINGUISHABLY from a genuinely empty one — never the same message
#        (XACA-0925-014, T16).
#    14. ~/aiteamforge-backups/personas/<team>/ backups are pruned to a
#        bounded keep-count, per team, never touching another team's backups
#        (XACA-0925-016, T17).
#    15. A team id containing characters outside [A-Za-z0-9_-] is skipped
#        with a warning and never interpolated into a path (XACA-0925-017,
#        T18).
#
# EXPECTED RESULT AS WRITTEN (before XACA-0925-001 lands): every functional
# test (T1-T8) and every structural test (T9-T12) FAILS, because
# update_team_personas() does not exist yet in aiteamforge-upgrade.sh at the
# time this suite was authored (confirmed: `grep -n update_team_personas
# libexec/commands/aiteamforge-upgrade.sh` returned nothing). That failure
# IS this suite's negative control — see the retrospective doc alongside this
# file's PR for the captured pre-fix run. Once XACA-0925-001 lands, re-running
# this file with no code changes should flip every case to PASS. T13-T18 were
# added later against the already-landed implementation, resolving the 5
# merge-gating subitems above — see each test's header for its own before/
# after evidence (captured in the PR discussion, not repeated here).
#
# Non-vacuous precondition guards throughout (feedback_parity_test_wrong_
# shell_passes_vacuously / feedback_negctrl_seed_placement_and_self_satisfying_
# anchor): every test confirms its starting condition (stale content present,
# mtime relationship inverted, etc.) before invoking the function under test.
#
# All filesystem activity is sandboxed under TEST_TMP_DIR, including a fake
# $HOME so backup-directory assertions never touch the real
# ~/aiteamforge-backups/. NEVER touches real $HOME/aiteamforge or
# ~/aiteamforge-backups — installer-test safety rule. This suite only READS
# the real tap tree (libexec/lib/config.sh, for get_configured_teams) as a
# dependency; all persona fixture content is synthetic and sandboxed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
CONFIG_LIB="$TAP_ROOT/libexec/lib/config.sh"

for _need in "$UPGRADE_SH" "$CONFIG_LIB"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (works sourced by test-runner.sh OR invoked directly).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi
if ! type -t assert_file_exists >/dev/null 2>&1; then
    assert_file_exists() { [ -f "$1" ] || { test_fail "${2:-Expected file to exist: $1}"; return 1; }; }
fi
if ! type -t assert_file_not_exists >/dev/null 2>&1; then
    assert_file_not_exists() { [ ! -f "$1" ] || { test_fail "${2:-Expected file to not exist: $1}"; return 1; }; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory (runner-supplied or our own). Includes a fake $HOME so
# ~/aiteamforge-backups assertions NEVER touch the real home directory.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0925-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

WORK_DIR="$TEST_TMP_DIR/xaca0925"
mkdir -p "$WORK_DIR"
FAKE_HOME="$WORK_DIR/fake-home"
mkdir -p "$FAKE_HOME"

# ─────────────────────────────────────────────────────────────────────────────
# Extract update_team_personas() from upgrade.sh WITHOUT sourcing the whole
# script (its main body has side effects) — mirrors test-xaca-0610/0771's
# _extract_fn. Deliberately NON-FATAL when the function is absent: this is
# expected pre-fix (see header) and every functional test below must record a
# real FAIL, not abort the suite before the negative-control evidence exists.
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$UPGRADE_SH"
}

# The contract names ONE public function (update_team_personas) but does not
# forbid private helpers — and the implementation may define any number of
# them (_xaca0925_* or otherwise). Extract update_team_personas AND every
# top-level function it references by name, so a helper split across
# functions doesn't produce a spurious "command not found" at call time
# (this suite hit exactly that on its first run against a real
# implementation: update_team_personas delegated to
# _xaca0925_refresh_team_personas, which extracting only the caller left
# undefined). Discovery is iterative/transitive: after each extraction pass,
# re-scan the accumulated source for any additional bare identifiers that
# are themselves top-level function definitions in UPGRADE_SH but not yet
# extracted, and fold them in — this matches the file's own naming
# convention loosely enough to survive an implementation detail changing
# without hand-maintaining a helper name list here.
FN_MISSING=false
_ALL_TOPLEVEL_FNS="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\) \{' "$UPGRADE_SH" | sed -E 's/\(\) \{$//')"
_FN_SRC="$(_extract_fn update_team_personas)"
if [ -z "$_FN_SRC" ]; then
    FN_MISSING=true
    echo "  !! update_team_personas() not found in $UPGRADE_SH — feature not yet implemented." >&2
    echo "     Every functional test below (T1-T8) will FAIL. This is the expected negative control." >&2
else
    _COMBINED_SRC="$_FN_SRC"
    _EXTRACTED_NAMES=$'\n'"update_team_personas"$'\n'
    _pass=0
    while [ $_pass -lt 5 ]; do
        _pass=$((_pass + 1))
        _added_this_pass=false
        for _cand in $_ALL_TOPLEVEL_FNS; do
            case "$_EXTRACTED_NAMES" in
                *$'\n'"${_cand}"$'\n'*) continue ;;   # already extracted
            esac
            # Only pull it in if something already extracted actually calls it
            # (a bare word, not part of a longer identifier).
            if printf '%s\n' "$_COMBINED_SRC" | grep -qE "(^|[^A-Za-z0-9_])${_cand}([^A-Za-z0-9_(]|\$)"; then
                _helper_src="$(_extract_fn "$_cand")"
                [ -z "$_helper_src" ] && continue
                _COMBINED_SRC="${_helper_src}"$'\n\n'"${_COMBINED_SRC}"
                _EXTRACTED_NAMES="${_EXTRACTED_NAMES}${_cand}"$'\n'
                _added_this_pass=true
            fi
        done
        [ "$_added_this_pass" = true ] || break
    done

    EXTRACTED="$WORK_DIR/extracted-persona-fn.sh"
    printf '%s\n' "$_COMBINED_SRC" > "$EXTRACTED"
    # config.sh is a dependency-free library (no print_* calls, no sourcing) —
    # safe to source directly for get_configured_teams()/get_config_file(),
    # which the real upgrade.sh also has available at call time.
    # shellcheck disable=SC1090
    source "$CONFIG_LIB"
    # shellcheck disable=SC1090
    source "$EXTRACTED"
    declare -f update_team_personas >/dev/null || FN_MISSING=true
fi

# print_* stubs that record output so tests can grep for specific warning text
# (mirrors test-xaca-0771's printf-based stubs).
_STUB_LOG="$WORK_DIR/stub-output.log"
_install_print_stubs() {
    : > "$_STUB_LOG"
    for _p in print_section print_info print_success print_warning print_error; do
        eval "${_p}() { printf '%s\n' \"\$*\" >> \"\$_STUB_LOG\"; }"
    done
}
_install_print_stubs

_next_sandbox() { mktemp -d "$WORK_DIR/sbx-XXXXXX"; }

# Build a synthetic FRAMEWORK_DIR fixture: share/personas/<team>/agents/*.md
# with caller-supplied content. All content is invented for this suite — never
# depends on the real share/personas/ tree, so this test is immune to future
# persona-content edits.
_seed_framework_team() {
    local fw="$1" team="$2"; shift 2
    mkdir -p "${fw}/share/personas/${team}/agents"
    while [ $# -ge 2 ]; do
        printf '%s\n' "$2" > "${fw}/share/personas/${team}/agents/$1"
        shift 2
    done
}

# Write a minimal .aiteamforge-config with the given space-separated team list
# into WORKING_DIR — matches the shape get_configured_teams()/jq '.teams[]'
# reads (config.sh line ~104), NOT a glob of share/personas/*/.
_seed_config() {
    local wd="$1"; shift
    local teams_json=""
    local t
    for t in "$@"; do
        [ -n "$teams_json" ] && teams_json="${teams_json}, "
        teams_json="${teams_json}\"${t}\""
    done
    printf '{\n  "schema_version": 1,\n  "teams": [%s]\n}\n' "$teams_json" > "${wd}/.aiteamforge-config"
}

# Invoke update_team_personas() in the real script's execution regime
# (set -eo pipefail, exactly as aiteamforge-upgrade.sh runs it) inside a
# subshell so a bug in the function under test can never abort THIS suite.
# Echoes the subshell's exit code on stdout via the caller-supplied var name.
_run_utp() {
    local home="$1" fw="$2" wd="$3" dry="$4" logfile="$5"
    _install_print_stubs
    (
        set -eo pipefail
        HOME="$home" AITEAMFORGE_DIR="$wd" FRAMEWORK_DIR="$fw" WORKING_DIR="$wd" \
        DRY_RUN="$dry" FORCE=false \
        update_team_personas
    ) >"$logfile" 2>&1
}

# Invoke the private helper _xaca0925_refresh_team_personas() DIRECTLY (not
# through update_team_personas()/get_configured_teams()) so T13/T14/T16/T18
# below can assert on its exact return code and on the true post-write
# filesystem state for exactly one team, without needing a .aiteamforge-
# config fixture. _XACA0925_PERSONAS_SOURCE_ROOT is normally a `local` set by
# update_team_personas(); bash's dynamic scoping only makes a caller's local
# visible to callees it invokes, so calling the helper directly requires
# setting it explicitly here.
#
# CRITICAL: the call MUST be wrapped in `if ! ...; then` here, exactly as
# the real call site (update_team_personas()) wraps it. Confirmed under this
# repo's target /bin/bash 3.2: when a function call is the direct condition
# of `if !`, `set -e` is suppressed for that function's ENTIRE body (not
# just the top-level call) for as long as the call is running — see the
# "Fail-soft" header comment in aiteamforge-upgrade.sh above
# _xaca0925_refresh_team_personas(). A bare (unwrapped) call under `set -e`
# aborts the function at its FIRST failing command instead of continuing
# past it — which silently produces a different, more-forgiving failure
# shape than production ever sees, and would make T13/T14 pass against the
# OLD pre-fix code for the wrong reason (an early `set -e` abort, not the
# real "unconditional overwrite" / "loop keeps going after one cp fails"
# bug this suite exists to catch). Verified by hand: the unwrapped form let
# T13 false-pass against pre-fix code before this fix was written.
_run_refresh_direct() {
    local home="$1" fw="$2" wd="$3" team="$4" dry="$5" logfile="$6"
    _install_print_stubs
    (
        set -eo pipefail
        HOME="$home"
        WORKING_DIR="$wd"
        DRY_RUN="$dry"
        FORCE=false
        _XACA0925_PERSONAS_SOURCE_ROOT="${fw}/share/personas"
        if ! _xaca0925_refresh_team_personas "$team"; then
            exit 1
        fi
        exit 0
    ) >"$logfile" 2>&1
}

# Invoke the private helper _xaca0925_prune_persona_backups() directly for T17.
_run_prune_direct() {
    local home="$1" team="$2" logfile="$3"
    _install_print_stubs
    (
        set -eo pipefail
        HOME="$home" \
        _xaca0925_prune_persona_backups "$team"
    ) >"$logfile" 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════
# T1 — STALE-FILE-REFRESHED-AND-MISSING-FILE-CREATED (contract #1)
# ═══════════════════════════════════════════════════════════════════════════
test_start "T1: a stale existing file is refreshed AND a missing file is created, from Cellar content"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_personas() not implemented yet (expected pre-fix negative control)"
else
    T1_FW="$(_next_sandbox)"; T1_WD="$(_next_sandbox)"; T1_HOME="$(_next_sandbox)"
    _seed_framework_team "$T1_FW" academy a.md "CELLAR-CONTENT-A-v2" b.md "CELLAR-CONTENT-B-v1"
    _seed_config "$T1_WD" academy
    mkdir -p "$T1_WD/academy/personas/agents"
    printf 'OLD-STALE-CONTENT-A\n' > "$T1_WD/academy/personas/agents/a.md"
    # b.md deliberately absent — models a file added to a team's persona set
    # since this box's last install (or last successful upgrade).
    if [ -f "$T1_WD/academy/personas/agents/b.md" ]; then
        test_fail "PRECONDITION FAILED: b.md unexpectedly pre-exists — test would be vacuous"
    elif cmp -s "$T1_WD/academy/personas/agents/a.md" "$T1_FW/share/personas/academy/agents/a.md"; then
        test_fail "PRECONDITION FAILED: a.md already matches Cellar content — test would be vacuous"
    else
        _run_utp "$T1_HOME" "$T1_FW" "$T1_WD" false "$WORK_DIR/t1.log"
        if cmp -s "$T1_WD/academy/personas/agents/a.md" "$T1_FW/share/personas/academy/agents/a.md" \
            && cmp -s "$T1_WD/academy/personas/agents/b.md" "$T1_FW/share/personas/academy/agents/b.md" 2>/dev/null; then
            test_pass
        else
            test_fail "a.md/b.md do not match Cellar content after refresh; log: $(cat "$WORK_DIR/t1.log")"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T2 — IDENTICAL-NOOP-NO-BACKUP-NO-WRITE (contract #4)
# ═══════════════════════════════════════════════════════════════════════════
test_start "T2: identical content is a true no-op — no write (mtime unchanged), no backup taken"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_personas() not implemented yet (expected pre-fix negative control)"
else
    T2_FW="$(_next_sandbox)"; T2_WD="$(_next_sandbox)"; T2_HOME="$(_next_sandbox)"
    _seed_framework_team "$T2_FW" academy a.md "SAME-CONTENT-A"
    _seed_config "$T2_WD" academy
    mkdir -p "$T2_WD/academy/personas/agents"
    printf 'SAME-CONTENT-A\n' > "$T2_WD/academy/personas/agents/a.md"
    touch -t 202001010000 "$T2_WD/academy/personas/agents/a.md"
    _before_mtime="$(stat -f %m "$T2_WD/academy/personas/agents/a.md" 2>/dev/null || stat -c %Y "$T2_WD/academy/personas/agents/a.md")"
    if ! cmp -s "$T2_WD/academy/personas/agents/a.md" "$T2_FW/share/personas/academy/agents/a.md"; then
        test_fail "PRECONDITION FAILED: a.md does not already match Cellar content — test would be vacuous"
    else
        _run_utp "$T2_HOME" "$T2_FW" "$T2_WD" false "$WORK_DIR/t2.log"
        _after_mtime="$(stat -f %m "$T2_WD/academy/personas/agents/a.md" 2>/dev/null || stat -c %Y "$T2_WD/academy/personas/agents/a.md")"
        if [ "$_before_mtime" = "$_after_mtime" ] && [ ! -d "$T2_HOME/aiteamforge-backups/personas/academy" ]; then
            test_pass
        else
            test_fail "expected no write (mtime $_before_mtime -> $_after_mtime) and no backup dir; backup listing: $(find "$T2_HOME/aiteamforge-backups" 2>/dev/null); log: $(cat "$WORK_DIR/t2.log")"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T3 — MTIME-POISON-IMMUNE (contract #2): target has a NEWER mtime than the
# Cellar source but STALE content — the exact real-world shape (kb-sync-
# personas re-stamps deployed copies with today's date). A mtime/-nt-based
# implementation would wrongly treat the target as "already current" and
# skip it; a cmp-based implementation must refresh it regardless.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T3: stale content with a NEWER mtime than the Cellar source is still refreshed (proves content-only comparison)"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_personas() not implemented yet (expected pre-fix negative control)"
else
    T3_FW="$(_next_sandbox)"; T3_WD="$(_next_sandbox)"; T3_HOME="$(_next_sandbox)"
    _seed_framework_team "$T3_FW" academy a.md "CELLAR-CONTENT-A-v3"
    touch -t 202001010000 "$T3_FW/share/personas/academy/agents/a.md"
    _seed_config "$T3_WD" academy
    mkdir -p "$T3_WD/academy/personas/agents"
    printf 'OLD-STALE-CONTENT-A\n' > "$T3_WD/academy/personas/agents/a.md"
    touch "$T3_WD/academy/personas/agents/a.md"   # "now" — deliberately newer than the Cellar file above

    if [ ! "$T3_WD/academy/personas/agents/a.md" -nt "$T3_FW/share/personas/academy/agents/a.md" ]; then
        test_fail "PRECONDITION FAILED: target is not actually newer than source by mtime — mtime-poison scenario not set up"
    elif cmp -s "$T3_WD/academy/personas/agents/a.md" "$T3_FW/share/personas/academy/agents/a.md"; then
        test_fail "PRECONDITION FAILED: content already matches — test would be vacuous"
    else
        _run_utp "$T3_HOME" "$T3_FW" "$T3_WD" false "$WORK_DIR/t3.log"
        if cmp -s "$T3_WD/academy/personas/agents/a.md" "$T3_FW/share/personas/academy/agents/a.md"; then
            test_pass
        else
            test_fail "target still does not match Cellar content despite refresh — comparison logic appears mtime-gated, not content-gated; log: $(cat "$WORK_DIR/t3.log")"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T4 — ORPHAN-SURVIVES-SINGLE-WARNING (contract #5)
# ═══════════════════════════════════════════════════════════════════════════
test_start "T4: orphan working-dir files (not in the Cellar) survive unmodified and produce ONE summary warning, not one per file"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_personas() not implemented yet (expected pre-fix negative control)"
else
    T4_FW="$(_next_sandbox)"; T4_WD="$(_next_sandbox)"; T4_HOME="$(_next_sandbox)"
    _seed_framework_team "$T4_FW" academy a.md "SAME-CONTENT-A"
    _seed_config "$T4_WD" academy
    mkdir -p "$T4_WD/academy/personas/agents"
    printf 'SAME-CONTENT-A\n' > "$T4_WD/academy/personas/agents/a.md"
    printf 'ORPHAN-ONE\n' > "$T4_WD/academy/personas/agents/orphan1.md"
    printf 'ORPHAN-TWO\n' > "$T4_WD/academy/personas/agents/orphan2.md"

    if [ ! -f "$T4_WD/academy/personas/agents/orphan1.md" ] || [ ! -f "$T4_WD/academy/personas/agents/orphan2.md" ]; then
        test_fail "PRECONDITION FAILED: orphan fixtures not seeded"
    else
        _run_utp "$T4_HOME" "$T4_FW" "$T4_WD" false "$WORK_DIR/t4.log"
        _orphan_warn_lines="$(grep -ic "orphan" "$_STUB_LOG" || true)"
        if [ -f "$T4_WD/academy/personas/agents/orphan1.md" ] \
            && [ -f "$T4_WD/academy/personas/agents/orphan2.md" ] \
            && grep -q "ORPHAN-ONE" "$T4_WD/academy/personas/agents/orphan1.md" \
            && grep -q "ORPHAN-TWO" "$T4_WD/academy/personas/agents/orphan2.md" \
            && [ "$_orphan_warn_lines" -eq 1 ]; then
            test_pass
        else
            test_fail "orphan(s) missing/modified, or warning line count != 1 (got $_orphan_warn_lines); stub log: $(cat "$_STUB_LOG"); log: $(cat "$WORK_DIR/t4.log")"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T5 — DRY-RUN-NO-MUTATION (contract #6)
# ═══════════════════════════════════════════════════════════════════════════
test_start "T5: DRY_RUN=true writes nothing and takes no backup, even when content differs"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_personas() not implemented yet (expected pre-fix negative control)"
else
    T5_FW="$(_next_sandbox)"; T5_WD="$(_next_sandbox)"; T5_HOME="$(_next_sandbox)"
    _seed_framework_team "$T5_FW" academy a.md "CELLAR-CONTENT-A-v2"
    _seed_config "$T5_WD" academy
    mkdir -p "$T5_WD/academy/personas/agents"
    printf 'OLD-STALE-CONTENT-A\n' > "$T5_WD/academy/personas/agents/a.md"

    if cmp -s "$T5_WD/academy/personas/agents/a.md" "$T5_FW/share/personas/academy/agents/a.md"; then
        test_fail "PRECONDITION FAILED: content already matches Cellar — test would be vacuous"
    else
        _run_utp "$T5_HOME" "$T5_FW" "$T5_WD" true "$WORK_DIR/t5.log"
        if grep -q 'OLD-STALE-CONTENT-A' "$T5_WD/academy/personas/agents/a.md" \
            && [ ! -d "$T5_HOME/aiteamforge-backups/personas/academy" ]; then
            test_pass
        else
            test_fail "DRY_RUN=true mutated the target file and/or created a backup; content: $(cat "$T5_WD/academy/personas/agents/a.md"); backups: $(find "$T5_HOME/aiteamforge-backups" 2>/dev/null); log: $(cat "$WORK_DIR/t5.log")"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T6 — BACKUP-SHAPE-AND-SINGLE-DIR-PER-TEAM (contract #3)
# ═══════════════════════════════════════════════════════════════════════════
test_start "T6: a diff triggers exactly one ~/aiteamforge-backups/personas/<team>/<YYYYMMDD-HHMMSS>/ dir, preserving pre-refresh content"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_personas() not implemented yet (expected pre-fix negative control)"
else
    T6_FW="$(_next_sandbox)"; T6_WD="$(_next_sandbox)"; T6_HOME="$(_next_sandbox)"
    _seed_framework_team "$T6_FW" academy a.md "CELLAR-CONTENT-A-v2" b.md "CELLAR-CONTENT-B-v1"
    _seed_config "$T6_WD" academy
    mkdir -p "$T6_WD/academy/personas/agents"
    printf 'OLD-STALE-CONTENT-A\n' > "$T6_WD/academy/personas/agents/a.md"
    printf 'CELLAR-CONTENT-B-v1\n' > "$T6_WD/academy/personas/agents/b.md"   # already current

    if [ -d "$T6_HOME/aiteamforge-backups" ]; then
        test_fail "PRECONDITION FAILED: fake HOME already has a backups dir — test would be vacuous"
    else
        _run_utp "$T6_HOME" "$T6_FW" "$T6_WD" false "$WORK_DIR/t6.log"
        _backup_team_dir="$T6_HOME/aiteamforge-backups/personas/academy"
        _n_ts_dirs=0
        _ts_dir=""
        if [ -d "$_backup_team_dir" ]; then
            _n_ts_dirs="$(find "$_backup_team_dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
            _ts_dir="$(find "$_backup_team_dir" -mindepth 1 -maxdepth 1 -type d | head -1)"
        fi
        _ts_name="$(basename "${_ts_dir:-__none__}")"
        # Locate the backed-up a.md wherever it landed under the timestamp dir
        # (e.g. .../<ts>/agents/a.md if the backup preserves the agents/
        # subtree, or .../<ts>/a.md if it's flat) — the contract only requires
        # pre-refresh content to be preserved, not a specific internal layout.
        _backed_up_a=""
        if [ -n "$_ts_dir" ]; then
            _backed_up_a="$(find "$_ts_dir" -name "a.md" -type f | head -1)"
        fi
        if [ "$_n_ts_dirs" = "1" ] \
            && [[ "$_ts_name" =~ ^[0-9]{8}-[0-9]{6}$ ]] \
            && [ -n "$_backed_up_a" ] \
            && grep -q "OLD-STALE-CONTENT-A" "$_backed_up_a"; then
            test_pass
        else
            test_fail "expected exactly 1 timestamped backup dir (YYYYMMDD-HHMMSS) preserving pre-refresh a.md content somewhere under it; found $_n_ts_dirs dir(s) named '$_ts_name' under $_backup_team_dir (backed-up a.md: '${_backed_up_a:-none}'); tree: $(find "$_backup_team_dir" 2>/dev/null); log: $(cat "$WORK_DIR/t6.log")"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T7 — MISSING-TEAM-DIR-CREATED (contract #7, dns/mainevent shape)
# ═══════════════════════════════════════════════════════════════════════════
test_start "T7: a configured team with NO working-dir persona directory at all gets one created, populated from the Cellar"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_personas() not implemented yet (expected pre-fix negative control)"
else
    T7_FW="$(_next_sandbox)"; T7_WD="$(_next_sandbox)"; T7_HOME="$(_next_sandbox)"
    _seed_framework_team "$T7_FW" dns d.md "CELLAR-CONTENT-D-v1"
    _seed_config "$T7_WD" dns
    # T7_WD/dns deliberately does not exist at all (dns/mainevent's real shape).

    if [ -e "$T7_WD/dns" ]; then
        test_fail "PRECONDITION FAILED: dns dir already exists in T7 sandbox — test would be vacuous"
    else
        _run_utp "$T7_HOME" "$T7_FW" "$T7_WD" false "$WORK_DIR/t7.log"
        if [ -f "$T7_WD/dns/personas/agents/d.md" ] \
            && cmp -s "$T7_WD/dns/personas/agents/d.md" "$T7_FW/share/personas/dns/agents/d.md"; then
            test_pass
        else
            test_fail "dns/personas/agents/d.md was not created with Cellar content; find: $(find "$T7_WD" 2>/dev/null); log: $(cat "$WORK_DIR/t7.log")"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T8 — ENUMERATION-FROM-CONFIG-NOT-GLOB (contract #8)
# ═══════════════════════════════════════════════════════════════════════════
test_start "T8: a team present in the Cellar's share/personas/ but ABSENT from .aiteamforge-config .teams[] is never touched (not a directory glob)"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_personas() not implemented yet (expected pre-fix negative control)"
else
    T8_FW="$(_next_sandbox)"; T8_WD="$(_next_sandbox)"; T8_HOME="$(_next_sandbox)"
    _seed_framework_team "$T8_FW" academy a.md "CELLAR-CONTENT-A-v2"
    _seed_framework_team "$T8_FW" ghostteam g.md "CELLAR-CONTENT-G-v1"
    _seed_config "$T8_WD" academy   # ghostteam deliberately NOT listed
    mkdir -p "$T8_WD/academy/personas/agents"
    printf 'OLD-STALE-CONTENT-A\n' > "$T8_WD/academy/personas/agents/a.md"

    if [ -e "$T8_WD/ghostteam" ]; then
        test_fail "PRECONDITION FAILED: ghostteam dir already exists in T8 sandbox — test would be vacuous"
    else
        _run_utp "$T8_HOME" "$T8_FW" "$T8_WD" false "$WORK_DIR/t8.log"
        if [ ! -e "$T8_WD/ghostteam" ]; then
            test_pass
        else
            test_fail "ghostteam was materialised even though it is not in .teams[] — team enumeration appears to glob share/personas/*/ instead of reading .aiteamforge-config; find: $(find "$T8_WD" 2>/dev/null); log: $(cat "$WORK_DIR/t8.log")"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T9 — STRUCTURAL: update_team_personas() is DEFINED in aiteamforge-upgrade.sh
# ═══════════════════════════════════════════════════════════════════════════
test_start "T9: update_team_personas() is defined in aiteamforge-upgrade.sh"
if grep -qE '^update_team_personas\(\) \{' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "no 'update_team_personas() {' definition found in $UPGRADE_SH"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T10 — STRUCTURAL: update_team_personas is CALLED (bare line) in the run
# sequence. This is the guard XACA-0771's retrospective identifies as the one
# that would have caught the original defect class: a defined-but-never-
# called function means existing fleet machines never receive the refresh.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T10: update_team_personas is invoked (bare call) in the upgrade run sequence"
if grep -qE '^update_team_personas$' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "aiteamforge-upgrade.sh run sequence must call update_team_personas (bare line) — a defined-but-never-called function means EXISTING fleet machines never receive persona refreshes (XACA-0925 / XACA-0771 lesson)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T11 — STRUCTURAL: call ORDER — after update_runtime_helpers, before
# update_claude_hooks (contract #9).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T11: update_team_personas is called AFTER update_runtime_helpers and BEFORE update_claude_hooks in the run sequence"
_line_runtime="$(grep -nE '^update_runtime_helpers$' "$UPGRADE_SH" | tail -1 | cut -d: -f1)"
_line_personas="$(grep -nE '^update_team_personas$' "$UPGRADE_SH" | tail -1 | cut -d: -f1)"
_line_hooks="$(grep -nE '^update_claude_hooks$' "$UPGRADE_SH" | tail -1 | cut -d: -f1)"
if [ -z "$_line_runtime" ] || [ -z "$_line_personas" ] || [ -z "$_line_hooks" ]; then
    test_fail "one or more of the three run-sequence bare calls not found (update_runtime_helpers=$_line_runtime update_team_personas=$_line_personas update_claude_hooks=$_line_hooks)"
elif [ "$_line_runtime" -lt "$_line_personas" ] && [ "$_line_personas" -lt "$_line_hooks" ]; then
    test_pass
else
    test_fail "expected run-sequence order update_runtime_helpers($_line_runtime) < update_team_personas($_line_personas) < update_claude_hooks($_line_hooks)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T12 — STRUCTURAL: the extracted function body uses `cmp` and never a
# `-nt`/mtime-based newer-than test (contract #2, static complement to T3's
# behavioral proof).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T12: update_team_personas() (+ any helpers it calls) uses cmp for comparison and contains no -nt (mtime newer-than) test"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_personas() not implemented yet (expected pre-fix negative control)"
else
    if echo "$_COMBINED_SRC" | grep -q "cmp " && ! echo "$_COMBINED_SRC" | grep -qE -- '-nt[[:space:]]'; then
        test_pass
    else
        test_fail "expected the extracted source to call cmp and to never use a -nt mtime comparison; extracted names: $_EXTRACTED_NAMES; body: $_COMBINED_SRC"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T13 — BACKUP-FAILURE-BLOCKS-OVERWRITE (XACA-0925-013/015, the critical one).
# The backup IS the safety property the unconditional-clobber design rests
# on. If it fails, the destination must be left exactly as it was — no
# partial or full overwrite — and the helper must report failure, not a
# false "Updated N persona file(s)" success.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T13: a failed backup does NOT overwrite — dest content unchanged, helper returns non-zero, no success message"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_personas() not implemented yet (expected pre-fix negative control)"
else
    T13_FW="$(_next_sandbox)"; T13_WD="$(_next_sandbox)"; T13_HOME="$(_next_sandbox)"
    _seed_framework_team "$T13_FW" academy a.md "CELLAR-CONTENT-A-v2"
    mkdir -p "$T13_WD/academy/personas/agents"
    printf 'OLD-STALE-CONTENT-A\n' > "$T13_WD/academy/personas/agents/a.md"
    # Force the backup mkdir to fail: seed ~/aiteamforge-backups as a PLAIN
    # FILE so `mkdir -p .../personas/academy/<ts>` cannot create it as a dir.
    printf 'not a directory\n' > "$T13_HOME/aiteamforge-backups"

    if [ ! -f "$T13_HOME/aiteamforge-backups" ]; then
        test_fail "PRECONDITION FAILED: could not seed aiteamforge-backups as a blocking file"
    elif cmp -s "$T13_WD/academy/personas/agents/a.md" "$T13_FW/share/personas/academy/agents/a.md"; then
        test_fail "PRECONDITION FAILED: a.md already matches Cellar content — test would be vacuous"
    else
        _run_refresh_direct "$T13_HOME" "$T13_FW" "$T13_WD" academy false "$WORK_DIR/t13.log"
        _RC=$?
        if [ "$_RC" -ne 0 ] \
            && grep -q 'OLD-STALE-CONTENT-A' "$T13_WD/academy/personas/agents/a.md" \
            && ! cmp -s "$T13_WD/academy/personas/agents/a.md" "$T13_FW/share/personas/academy/agents/a.md" \
            && ! grep -qi "updated.*persona file" "$_STUB_LOG"; then
            test_pass
        else
            test_fail "expected non-zero return, unchanged dest content, and no success message; rc=$_RC content=$(cat "$T13_WD/academy/personas/agents/a.md" 2>/dev/null); stub log: $(cat "$_STUB_LOG"); log: $(cat "$WORK_DIR/t13.log")"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T14 — PARTIAL-WRITE-FAILURE-TRUE-COUNT (XACA-0925-013/015). Reproduces the
# reviewer's own repro: one dest file is not writable (mode 444). The helper
# must return non-zero, print no success message, still write the OTHER
# file that CAN be written, and report the true (not attempted) count.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T14: a failed per-file cp returns non-zero, prints no success message, and reports the TRUE written count"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_personas() not implemented yet (expected pre-fix negative control)"
else
    T14_FW="$(_next_sandbox)"; T14_WD="$(_next_sandbox)"; T14_HOME="$(_next_sandbox)"
    _seed_framework_team "$T14_FW" academy a.md "CELLAR-CONTENT-A-v2" b.md "CELLAR-CONTENT-B-v1"
    mkdir -p "$T14_WD/academy/personas/agents"
    printf 'OLD-STALE-CONTENT-A\n' > "$T14_WD/academy/personas/agents/a.md"
    chmod 444 "$T14_WD/academy/personas/agents/a.md"
    # b.md deliberately absent at dest — its write must still succeed.

    if [ -w "$T14_WD/academy/personas/agents/a.md" ]; then
        test_fail "PRECONDITION FAILED: could not make a.md read-only — test would be vacuous (running as root?)"
    else
        _run_refresh_direct "$T14_HOME" "$T14_FW" "$T14_WD" academy false "$WORK_DIR/t14.log"
        _RC=$?
        chmod 644 "$T14_WD/academy/personas/agents/a.md" 2>/dev/null || true
        if [ "$_RC" -ne 0 ] \
            && ! grep -qi "^\[academy\] Updated" "$_STUB_LOG" \
            && grep -q "1/2 file(s) actually written" "$_STUB_LOG" \
            && cmp -s "$T14_WD/academy/personas/agents/b.md" "$T14_FW/share/personas/academy/agents/b.md" \
            && grep -q "OLD-STALE-CONTENT-A" "$T14_WD/academy/personas/agents/a.md"; then
            test_pass
        else
            test_fail "expected non-zero return, no success message, '1/2' reported, b.md written, a.md left stale; rc=$_RC stub log: $(cat "$_STUB_LOG"); a.md: $(cat "$T14_WD/academy/personas/agents/a.md" 2>/dev/null); log: $(cat "$WORK_DIR/t14.log")"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T15 — CALLER-FAIL-SOFT-BRANCH-LIVE (XACA-0925-013/015). The caller's
# `if ! _xaca0925_refresh_team_personas; then print_warning ...` branch was
# dead code before this fix (the helper always returned 0). One team failing
# must warn and NOT stop the remaining teams from refreshing.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T15: caller's fail-soft branch is reachable — one team's write failure warns and does not stop remaining teams from refreshing"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_personas() not implemented yet (expected pre-fix negative control)"
else
    T15_FW="$(_next_sandbox)"; T15_WD="$(_next_sandbox)"; T15_HOME="$(_next_sandbox)"
    _seed_framework_team "$T15_FW" academy a.md "CELLAR-CONTENT-A-v2"
    _seed_framework_team "$T15_FW" iota c.md "CELLAR-CONTENT-C-v1"
    _seed_config "$T15_WD" academy iota
    mkdir -p "$T15_WD/academy/personas/agents" "$T15_WD/iota/personas/agents"
    printf 'OLD-STALE-CONTENT-A\n' > "$T15_WD/academy/personas/agents/a.md"
    chmod 444 "$T15_WD/academy/personas/agents/a.md"   # forces academy's write to fail
    printf 'OLD-STALE-CONTENT-C\n' > "$T15_WD/iota/personas/agents/c.md"   # iota should still refresh

    if [ -w "$T15_WD/academy/personas/agents/a.md" ]; then
        test_fail "PRECONDITION FAILED: could not make academy/a.md read-only — test would be vacuous"
    else
        _run_utp "$T15_HOME" "$T15_FW" "$T15_WD" false "$WORK_DIR/t15.log"
        _RC=$?
        chmod 644 "$T15_WD/academy/personas/agents/a.md" 2>/dev/null || true
        if [ "$_RC" -eq 0 ] \
            && grep -qi "\[academy\].*did not complete cleanly" "$_STUB_LOG" \
            && cmp -s "$T15_WD/iota/personas/agents/c.md" "$T15_FW/share/personas/iota/agents/c.md"; then
            test_pass
        else
            test_fail "expected update_team_personas to return 0 (fail-soft), warn for academy, and STILL refresh iota; rc=$_RC stub log: $(cat "$_STUB_LOG"); iota c.md: $(cat "$T15_WD/iota/personas/agents/c.md" 2>/dev/null); log: $(cat "$WORK_DIR/t15.log")"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T16 — UNREADABLE-SOURCE-LOGS-DISTINGUISHABLY (XACA-0925-014). A permission-
# denied shipped persona source dir must NOT log identically to a genuinely
# empty one.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T16: an unreadable (permission-denied) source dir logs DISTINGUISHABLY from a genuinely empty one"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_personas() not implemented yet (expected pre-fix negative control)"
else
    T16_FW="$(_next_sandbox)"; T16_WD="$(_next_sandbox)"; T16_HOME="$(_next_sandbox)"
    _seed_framework_team "$T16_FW" academy a.md "CELLAR-CONTENT-A-v2"
    chmod 000 "$T16_FW/share/personas/academy/agents"

    if [ -r "$T16_FW/share/personas/academy/agents" ]; then
        test_fail "PRECONDITION FAILED: could not make source dir unreadable — test would be vacuous (running as root?)"
    else
        _run_refresh_direct "$T16_HOME" "$T16_FW" "$T16_WD" academy false "$WORK_DIR/t16.log"
        chmod 755 "$T16_FW/share/personas/academy/agents" 2>/dev/null || true
        if grep -qi "not readable" "$_STUB_LOG" && ! grep -qi "No \.md persona files shipped" "$_STUB_LOG"; then
            test_pass
        else
            test_fail "expected a distinguishable 'not readable' warning, not the generic empty-set message; stub log: $(cat "$_STUB_LOG"); log: $(cat "$WORK_DIR/t16.log")"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T17 — RETENTION-PRUNES-BEYOND-KEEP-COUNT (XACA-0925-016). 15 timestamped
# backups seeded for one team (5 more than the keep=10 constant); the 5
# OLDEST must be pruned, the 10 NEWEST must survive, and a second team's
# backups must be completely untouched.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T17: backup retention prunes beyond the keep-count for one team and never touches another team's backups"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_personas() not implemented yet (expected pre-fix negative control)"
else
    T17_HOME="$(_next_sandbox)"
    mkdir -p "$T17_HOME/aiteamforge-backups/personas/academy" "$T17_HOME/aiteamforge-backups/personas/otherteam"
    _i=1
    while [ $_i -le 15 ]; do
        _ts=$(printf '20260101-%06d' "$_i")
        mkdir -p "$T17_HOME/aiteamforge-backups/personas/academy/${_ts}/agents"
        printf 'backup-%d\n' "$_i" > "$T17_HOME/aiteamforge-backups/personas/academy/${_ts}/agents/a.md"
        _i=$((_i + 1))
    done
    _j=1
    while [ $_j -le 3 ]; do
        _ts=$(printf '20260101-%06d' "$_j")
        mkdir -p "$T17_HOME/aiteamforge-backups/personas/otherteam/${_ts}/agents"
        _j=$((_j + 1))
    done

    _academy_before="$(find "$T17_HOME/aiteamforge-backups/personas/academy" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
    _other_before="$(find "$T17_HOME/aiteamforge-backups/personas/otherteam" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
    if [ "$_academy_before" != "15" ] || [ "$_other_before" != "3" ]; then
        test_fail "PRECONDITION FAILED: expected 15 academy dirs and 3 otherteam dirs, got $_academy_before / $_other_before"
    else
        _run_prune_direct "$T17_HOME" academy "$WORK_DIR/t17.log"
        _academy_after="$(find "$T17_HOME/aiteamforge-backups/personas/academy" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
        _other_after="$(find "$T17_HOME/aiteamforge-backups/personas/otherteam" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
        _oldest_survives="no"
        [ -d "$T17_HOME/aiteamforge-backups/personas/academy/20260101-000001" ] && _oldest_survives="yes"
        _newest_survives="no"
        [ -d "$T17_HOME/aiteamforge-backups/personas/academy/20260101-000015" ] && _newest_survives="yes"
        if [ "$_academy_after" = "10" ] && [ "$_other_after" = "3" ] \
            && [ "$_oldest_survives" = "no" ] && [ "$_newest_survives" = "yes" ]; then
            test_pass
        else
            test_fail "expected 10 academy dirs (newest kept, oldest pruned) and 3 untouched otherteam dirs; academy_after=$_academy_after other_after=$_other_after oldest_survives=$_oldest_survives newest_survives=$_newest_survives; log: $(cat "$WORK_DIR/t17.log")"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T18 — MALFORMED-TEAM-ID-SKIPPED (XACA-0925-017). A team id containing
# characters outside [A-Za-z0-9_-] must be skipped with a warning, and must
# NEVER be interpolated into a path (path-traversal defense-in-depth).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T18: a malformed team id is skipped with a warning and never used to construct a path"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_personas() not implemented yet (expected pre-fix negative control)"
else
    T18_FW="$(_next_sandbox)"; T18_WD="$(_next_sandbox)"; T18_HOME="$(_next_sandbox)"
    _BAD_TEAM='../evil'
    mkdir -p "$T18_FW/share/personas"
    # Deliberately NOT seeding a source dir for the malformed id — the
    # validation guard must fire before any -d/-r check on a path built from it.

    _run_refresh_direct "$T18_HOME" "$T18_FW" "$T18_WD" "$_BAD_TEAM" false "$WORK_DIR/t18.log"
    _RC=$?
    _escaped_dir_created="no"
    [ -e "$(dirname "$T18_WD")/evil" ] && _escaped_dir_created="yes"
    if [ "$_RC" -eq 0 ] \
        && grep -qi "path-safety guard" "$_STUB_LOG" \
        && [ "$_escaped_dir_created" = "no" ]; then
        test_pass
    else
        test_fail "expected return 0 (deliberate skip), a path-safety warning, and no directory created via the malformed id; rc=$_RC stub log: $(cat "$_STUB_LOG"); escaped_dir_created=$_escaped_dir_created; log: $(cat "$WORK_DIR/t18.log")"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone only).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
