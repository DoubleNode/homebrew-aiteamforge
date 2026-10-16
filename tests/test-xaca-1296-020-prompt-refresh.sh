#!/bin/bash

# test-xaca-1296-020-prompt-refresh.sh
#
# Regression test for XACA-1296-020: `aiteamforge upgrade` never refreshed a
# team's shipped .txt system-prompt content
# (${WORKING_DIR}/<team>/scripts/prompts/*.txt). install-team.sh
# (libexec/installers/install-team.sh:2122-2153) is the ONLY code that ever
# copies share/personas/<team>/prompts/*.txt into that destination, and it
# runs only at first install — never on an already-installed team.
# update_team_personas()/_xaca0925_refresh_team_personas() (XACA-0925)
# refreshes personas/agents/*.md on upgrade, but never touched prompts/*.txt.
# So a shipped prompt fix (this very ticket's own spacedock scope-rule
# wording change) froze at install-time content on every already-installed
# machine, forever, until this fix.
#
# CONTRACT UNDER TEST (derived from the ticket's decided design — see
# aiteamforge-upgrade.sh's own header comment above PROMPT_REFRESH_TEAMS /
# update_team_prompts / _xaca1296_refresh_team_prompts, XACA-1296-020):
#   1. New function `update_team_prompts()` in aiteamforge-upgrade.sh refreshes
#      ${FRAMEWORK_DIR}/share/personas/<team>/prompts/*.txt into
#      ${WORKING_DIR}/<team>/scripts/prompts/, for every team named in the
#      `PROMPT_REFRESH_TEAMS` array.
#   2. PROMPT_REFRESH_TEAMS contains ONLY `spacedock` — this is a deliberate,
#      narrow scope matching sync-tap.sh's own spacedock-only prompt mirror
#      (every other team's tap-shipped prompt is intentionally un-mirrored and
#      free to drift from canonical; refreshing it here would be a behaviour
#      change for those teams, not a bugfix). A team NOT in this list is never
#      touched, no matter how stale its installed prompts are.
#   3. A team is refreshed ONLY when it is already installed on this machine
#      (${WORKING_DIR}/<team> exists). Upgrade never MATERIALIZES a team —
#      an absent team dir is left absent; scripts/prompts/ is never created
#      for a team that was never installed.
#   4. Uses `cmp` for comparison, never mtime.
#   5. Honors DRY_RUN — writes nothing.
#   6. install-team.sh's own prompt-seed step does not back these files up
#      before overwriting (verified: no `backup` call anywhere near
#      install-team.sh:2122-2153) — so this refresh does not either. No
#      ~/aiteamforge-backups/... directory is created for a prompt refresh.
#   7. A failed write is reported loudly (a print_warning naming the failure)
#      and the helper returns non-zero — never a silent skip.
#   8. `update_team_prompts` is CALLED in the run sequence, immediately after
#      `update_team_personas` (XACA-0925's own guard-the-call-site lesson,
#      restated here for this new function — see
#      kanban/plans/XACA-0771/XACA-0771_upgrade_materialize_missing_RETROSPECTIVE.md).
#
# EXPECTED RESULT AS WRITTEN (before XACA-1296-020 lands): every functional
# test (T1-T6) and the structural test (T7) FAILS, because
# update_team_prompts() does not exist yet in aiteamforge-upgrade.sh. That
# failure IS this suite's negative control.
#
# All filesystem activity is sandboxed under TEST_TMP_DIR, including a fake
# $HOME, so backup-directory assertions (T4) never touch the real
# ~/aiteamforge-backups/. NEVER touches real $HOME/aiteamforge or
# ~/aiteamforge-backups — installer-test safety rule. This suite only READS
# the real tap tree (aiteamforge-upgrade.sh itself, to extract the function
# under test); all fixture content (FRAMEWORK_DIR, WORKING_DIR) is synthetic
# and sandboxed.
#
# SHELL: deliberately NOT a self-re-exec suite (tests/ci-manifest says the
# XACA-0931 re-exec pattern is a workaround, not to be copied into new
# suites). Runs the extracted function under WHATEVER bash invokes this file,
# so `/bin/bash tests/<this>` exercises Apple bash 3.2 directly and CI's
# unqualified `bash tests/<this>` exercises whatever bash test-runner.sh's
# job installs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"

if [ ! -f "$UPGRADE_SH" ]; then
    echo "FATAL: required file not found: $UPGRADE_SH" >&2
    exit 1
fi

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

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory (runner-supplied or our own). Includes a fake $HOME so
# ~/aiteamforge-backups assertions (T4) never touch the real home directory.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1296020-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
WORK_DIR="$TEST_TMP_DIR/xaca1296020"
mkdir -p "$WORK_DIR"
FAKE_HOME="$WORK_DIR/fake-home"
mkdir -p "$FAKE_HOME"
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Extract update_team_prompts() (+ every top-level function it transitively
# calls) from upgrade.sh WITHOUT sourcing the whole script (its main body has
# side effects) — mirrors test-xaca-0925-persona-refresh.sh's _extract_fn.
# Deliberately NON-FATAL when the function is absent: expected pre-fix (see
# header), and every functional test below must record a real FAIL, not abort
# the suite before the negative-control evidence exists.
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$UPGRADE_SH"
}

FN_MISSING=false
_ALL_TOPLEVEL_FNS="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\) \{' "$UPGRADE_SH" | sed -E 's/\(\) \{$//')"
_FN_SRC="$(_extract_fn update_team_prompts)"
if [ -z "$_FN_SRC" ]; then
    FN_MISSING=true
    echo "  !! update_team_prompts() not found in $UPGRADE_SH — feature not yet implemented." >&2
    echo "     Every functional test below (T1-T6) will FAIL. This is the expected negative control." >&2
else
    _COMBINED_SRC="$_FN_SRC"
    _EXTRACTED_NAMES=$'\n'"update_team_prompts"$'\n'
    _pass=0
    while [ $_pass -lt 5 ]; do
        _pass=$((_pass + 1))
        _added_this_pass=false
        for _cand in $_ALL_TOPLEVEL_FNS; do
            case "$_EXTRACTED_NAMES" in
                *$'\n'"${_cand}"$'\n'*) continue ;;   # already extracted
            esac
            # Strip full-line comments before call-detection — prose that
            # merely NAMES another function is not a call (see XACA-0925/0931
            # precedent this pattern is copied from).
            if printf '%s\n' "$_COMBINED_SRC" | sed -E '/^[[:space:]]*#/d' | grep -qE "(^|[^A-Za-z0-9_])${_cand}([^A-Za-z0-9_(]|\$)"; then
                _helper_src="$(_extract_fn "$_cand")"
                [ -z "$_helper_src" ] && continue
                _COMBINED_SRC="${_helper_src}"$'\n\n'"${_COMBINED_SRC}"
                _EXTRACTED_NAMES="${_EXTRACTED_NAMES}${_cand}"$'\n'
                _added_this_pass=true
            fi
        done
        [ "$_added_this_pass" = true ] || break
    done

    # PROMPT_REFRESH_TEAMS is a plain top-level array assignment, not a
    # function — the loop above only extracts `name() {` definitions, so pull
    # it in explicitly from the source file.
    _ARRAY_LINE="$(grep -E '^PROMPT_REFRESH_TEAMS=\(' "$UPGRADE_SH" | head -1)"

    EXTRACTED="$WORK_DIR/extracted-prompt-fn.sh"
    {
        printf '%s\n' "$_ARRAY_LINE"
        printf '%s\n' "$_COMBINED_SRC"
    } > "$EXTRACTED"
    # shellcheck disable=SC1090
    source "$EXTRACTED"
    declare -f update_team_prompts >/dev/null || FN_MISSING=true
    if [ -z "$_ARRAY_LINE" ]; then
        echo "  !! PROMPT_REFRESH_TEAMS=(...) not found as a top-level assignment in $UPGRADE_SH" >&2
        FN_MISSING=true
    fi
fi

# print_* stubs that record output so tests can grep for specific warning text
# (mirrors test-xaca-0925/0771's printf-based stubs).
_STUB_LOG="$WORK_DIR/stub-output.log"
_install_print_stubs() {
    : > "$_STUB_LOG"
    for _p in print_section print_info print_success print_warning print_error; do
        eval "${_p}() { printf '%s\n' \"\$*\" >> \"\$_STUB_LOG\"; }"
    done
}
_install_print_stubs

_next_sandbox() { mktemp -d "$WORK_DIR/sbx-XXXXXX"; }

# Seed a synthetic FRAMEWORK_DIR fixture: share/personas/<team>/prompts/*.txt
# with caller-supplied content. Invented content — never depends on the real
# share/personas/ tree.
_seed_framework_prompts() {
    local fw="$1" team="$2"; shift 2
    mkdir -p "${fw}/share/personas/${team}/prompts"
    while [ $# -ge 2 ]; do
        printf '%s\n' "$2" > "${fw}/share/personas/${team}/prompts/$1"
        shift 2
    done
}

# Invoke update_team_prompts() in the real script's execution regime
# (set -eo pipefail), inside a subshell so a bug in the function under test
# can never abort THIS suite.
_run_utp() {
    local home="$1" fw="$2" wd="$3" dry="$4" logfile="$5"
    _install_print_stubs
    (
        set -eo pipefail
        HOME="$home" AITEAMFORGE_DIR="$wd" FRAMEWORK_DIR="$fw" WORKING_DIR="$wd" \
        DRY_RUN="$dry" FORCE=false \
        update_team_prompts
    ) >"$logfile" 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════
# T1 — an already-installed spacedock's OLD prompt is refreshed to the NEW
# shipped content (contract #1, #3, #4).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T1: existing spacedock install with an OLD prompt gets the NEW shipped one"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_prompts() not implemented yet (expected pre-fix negative control)"
else
    T1_FW="$(_next_sandbox)"; T1_WD="$(_next_sandbox)"; T1_HOME="$(_next_sandbox)"
    _seed_framework_prompts "$T1_FW" spacedock spacedock-dockmaster-prompt.txt "NEW-SCOPE-RULE-CONTENT-v2"
    mkdir -p "$T1_WD/spacedock/scripts/prompts"
    printf 'OLD-SCOPE-RULE-CONTENT-v1\n' > "$T1_WD/spacedock/scripts/prompts/spacedock-dockmaster-prompt.txt"
    if cmp -s "$T1_WD/spacedock/scripts/prompts/spacedock-dockmaster-prompt.txt" \
              "$T1_FW/share/personas/spacedock/prompts/spacedock-dockmaster-prompt.txt"; then
        test_fail "PRECONDITION FAILED: installed prompt already matches shipped content — test would be vacuous"
    else
        _run_utp "$T1_HOME" "$T1_FW" "$T1_WD" false "$WORK_DIR/t1.log"
        if cmp -s "$T1_WD/spacedock/scripts/prompts/spacedock-dockmaster-prompt.txt" \
                  "$T1_FW/share/personas/spacedock/prompts/spacedock-dockmaster-prompt.txt"; then
            test_pass
        else
            test_fail "installed prompt does not match shipped content after refresh; got: $(cat "$T1_WD/spacedock/scripts/prompts/spacedock-dockmaster-prompt.txt" 2>/dev/null); log: $(cat "$WORK_DIR/t1.log")"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T2 — a non-spacedock team's stale prompt is left UNTOUCHED, even though its
# shipped content differs (contract #2 — the whole point of the scope list).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T2: a non-spacedock team's prompts are left untouched"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_prompts() not implemented yet (expected pre-fix negative control)"
else
    T2_FW="$(_next_sandbox)"; T2_WD="$(_next_sandbox)"; T2_HOME="$(_next_sandbox)"
    _seed_framework_prompts "$T2_FW" academy academy-engineering-prompt.txt "NEW-ACADEMY-CONTENT-v2"
    mkdir -p "$T2_WD/academy/scripts/prompts"
    printf 'OLD-ACADEMY-CONTENT-v1\n' > "$T2_WD/academy/scripts/prompts/academy-engineering-prompt.txt"
    if cmp -s "$T2_WD/academy/scripts/prompts/academy-engineering-prompt.txt" \
              "$T2_FW/share/personas/academy/prompts/academy-engineering-prompt.txt"; then
        test_fail "PRECONDITION FAILED: installed prompt already matches shipped content — test would be vacuous"
    else
        _run_utp "$T2_HOME" "$T2_FW" "$T2_WD" false "$WORK_DIR/t2.log"
        if [ "$(cat "$T2_WD/academy/scripts/prompts/academy-engineering-prompt.txt")" = "OLD-ACADEMY-CONTENT-v1" ]; then
            test_pass
        else
            test_fail "academy's prompt was modified — PROMPT_REFRESH_TEAMS scoping did not hold; got: $(cat "$T2_WD/academy/scripts/prompts/academy-engineering-prompt.txt" 2>/dev/null); log: $(cat "$WORK_DIR/t2.log")"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T3 — an ABSENT spacedock team dir is never created, and no scripts/prompts/
# is materialized for it (contract #3 — refresh-only, never installs).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T3: an absent spacedock install is not created by the refresh"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_prompts() not implemented yet (expected pre-fix negative control)"
else
    T3_FW="$(_next_sandbox)"; T3_WD="$(_next_sandbox)"; T3_HOME="$(_next_sandbox)"
    _seed_framework_prompts "$T3_FW" spacedock spacedock-dockmaster-prompt.txt "NEW-CONTENT"
    if [ -d "$T3_WD/spacedock" ]; then
        test_fail "PRECONDITION FAILED: spacedock team dir unexpectedly pre-exists — test would be vacuous"
    else
        _run_utp "$T3_HOME" "$T3_FW" "$T3_WD" false "$WORK_DIR/t3.log"
        if [ ! -d "$T3_WD/spacedock" ]; then
            test_pass
        else
            test_fail "spacedock team dir was created by the refresh (upgrade must never materialize a team); tree: $(find "$T3_WD/spacedock" 2>/dev/null); log: $(cat "$WORK_DIR/t3.log")"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T4 — DRY_RUN honored: content is left untouched and no
# ~/aiteamforge-backups directory appears (contract #5, #6).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T4: --dry-run writes nothing and creates no backup directory"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_prompts() not implemented yet (expected pre-fix negative control)"
else
    T4_FW="$(_next_sandbox)"; T4_WD="$(_next_sandbox)"; T4_HOME="$(_next_sandbox)"
    _seed_framework_prompts "$T4_FW" spacedock spacedock-dockmaster-prompt.txt "NEW-CONTENT-v2"
    mkdir -p "$T4_WD/spacedock/scripts/prompts"
    printf 'OLD-CONTENT-v1\n' > "$T4_WD/spacedock/scripts/prompts/spacedock-dockmaster-prompt.txt"
    _run_utp "$T4_HOME" "$T4_FW" "$T4_WD" true "$WORK_DIR/t4.log"
    if [ "$(cat "$T4_WD/spacedock/scripts/prompts/spacedock-dockmaster-prompt.txt")" = "OLD-CONTENT-v1" ] \
        && [ ! -d "$T4_HOME/aiteamforge-backups" ]; then
        test_pass
    else
        test_fail "expected content unchanged and no backup dir under --dry-run; got: $(cat "$T4_WD/spacedock/scripts/prompts/spacedock-dockmaster-prompt.txt" 2>/dev/null); backup_exists=$([ -d "$T4_HOME/aiteamforge-backups" ] && echo yes || echo no); log: $(cat "$WORK_DIR/t4.log")"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T5 — a real (non-dry-run) refresh that touches spacedock still never
# writes a backup directory (contract #6 — matches install-team.sh's own
# no-backup prompt-seed semantics; prompts are generated content, not
# hand-edited local state).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T5: a real refresh never creates a personas-style backup directory for prompts"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_prompts() not implemented yet (expected pre-fix negative control)"
else
    T5_FW="$(_next_sandbox)"; T5_WD="$(_next_sandbox)"; T5_HOME="$(_next_sandbox)"
    _seed_framework_prompts "$T5_FW" spacedock spacedock-dockmaster-prompt.txt "NEW-CONTENT-v2"
    mkdir -p "$T5_WD/spacedock/scripts/prompts"
    printf 'OLD-CONTENT-v1\n' > "$T5_WD/spacedock/scripts/prompts/spacedock-dockmaster-prompt.txt"
    _run_utp "$T5_HOME" "$T5_FW" "$T5_WD" false "$WORK_DIR/t5.log"
    if [ ! -d "$T5_HOME/aiteamforge-backups" ]; then
        test_pass
    else
        test_fail "expected no ~/aiteamforge-backups dir after a real prompt refresh; tree: $(find "$T5_HOME/aiteamforge-backups" 2>/dev/null); log: $(cat "$WORK_DIR/t5.log")"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T6 — a per-file write failure is reported loudly (a warning naming the
# failure) and is never silently skipped (contract #7).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T6: a write failure is reported loudly, not silently skipped"
if [ "$FN_MISSING" = true ]; then
    test_fail "update_team_prompts() not implemented yet (expected pre-fix negative control)"
else
    T6_FW="$(_next_sandbox)"; T6_WD="$(_next_sandbox)"; T6_HOME="$(_next_sandbox)"
    _seed_framework_prompts "$T6_FW" spacedock spacedock-dockmaster-prompt.txt "NEW-CONTENT-v2"
    mkdir -p "$T6_WD/spacedock/scripts/prompts"
    printf 'OLD-CONTENT-v1\n' > "$T6_WD/spacedock/scripts/prompts/spacedock-dockmaster-prompt.txt"
    # Make the destination FILE itself read-only. Its containing directory
    # stays writable on purpose: overwriting an EXISTING file's content is
    # gated by the FILE's own mode, not the directory's (directory write
    # permission only governs creating/renaming/deleting entries) — a
    # directory-mode guard here would be a vacuous no-op against `cp`
    # overwriting an already-present destination file.
    chmod 0444 "$T6_WD/spacedock/scripts/prompts/spacedock-dockmaster-prompt.txt"
    if [ -w "$T6_WD/spacedock/scripts/prompts/spacedock-dockmaster-prompt.txt" ]; then
        chmod 0644 "$T6_WD/spacedock/scripts/prompts/spacedock-dockmaster-prompt.txt"
        test_fail "PRECONDITION FAILED: could not make dest file read-only — test would be vacuous (running as root?)"
    else
        _run_utp "$T6_HOME" "$T6_FW" "$T6_WD" false "$WORK_DIR/t6.log"
        _RC=$?
        chmod 0644 "$T6_WD/spacedock/scripts/prompts/spacedock-dockmaster-prompt.txt" 2>/dev/null || true
        if [ "$_RC" -ne 0 ] || grep -qi "fail" "$_STUB_LOG"; then
            test_pass
        else
            test_fail "expected a loud failure (non-zero rc and/or a 'fail' warning) when cp cannot write; rc=$_RC stub log: $(cat "$_STUB_LOG"); log: $(cat "$WORK_DIR/t6.log")"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T7 — STRUCTURAL: update_team_prompts is actually CALLED in the run
# sequence, not merely defined (contract #8 — the XACA-0771 lesson: a
# function that exists but is never invoked ships nothing).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T7 (structural): update_team_prompts is called in the run sequence"
# Deliberately reads the REAL file, not the extracted fragment — the call
# site lives in the script's main body, which the extractor above never
# touches (and must not: that body has side effects).
if grep -qE '^update_team_prompts$' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "no bare 'update_team_prompts' call found at the top level of $UPGRADE_SH — function may be defined but never invoked"
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
