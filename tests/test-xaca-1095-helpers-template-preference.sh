#!/bin/bash
# test-xaca-1095-helpers-template-preference.sh
#
# Regression coverage for XACA-1095: install_kanban_helpers()
# (libexec/installers/install-kanban.sh) and update_shell_helpers()
# (libexec/commands/aiteamforge-upgrade.sh) both preferred the tiny,
# 20-function share/templates/aliases/kanban-aliases.sh over the full,
# 61+-function share/templates/kanban/kanban-helpers.template.sh — backwards,
# since a real consumer install always has the full template available (it
# ships in the tap unconditionally). Every real consumer therefore received a
# helper file with no kb-sweep (the protected-subitem PR merge gate), no
# kb-epic, no kb-release*, and none of the kb-run/kb-work/kb-pick/kb-recover
# lifecycle family: 48 of 61 shipped kb-* commands missing, measured
# identical on two live consumers.
#
# A second, independent defect in the SAME function: update_shell_helpers'
# staleness check was `[ "$_kanban_src" -nt "$kanban_target" ]` (mtime-based).
# `git checkout` only touches the mtime of files that actually changed
# between tags, so a template unmodified across several release tags keeps
# whatever mtime it had at its ORIGINAL checkout — which can easily predate
# (and therefore never be "-nt") a target rendered more recently. That
# silently wedges a consumer on a stale kanban-helpers.sh across every
# subsequent release with no self-correction. Measured: two consumer
# machines' ~/aiteamforge/.installed-version stuck at a 2026-08-18 render
# across four subsequent Cellar upgrades.
#
# Fix (commit 1d49bfb): both functions now try kanban-helpers.template.sh
# FIRST, falling back to kanban-aliases.sh only if the template is absent;
# update_shell_helpers' staleness check now compares RENDERED CONTENT
# (`cmp -s` against a freshly-rendered temp copy) instead of mtimes.
#
# This suite existed nowhere before XACA-1095-007 — the defect that shipped
# for four releases had NO regression test watching for it. Every test below
# either exercises current (post-fix) behavior directly, or additionally
# PROVES the assertion would have failed against the pre-fix commit by
# extracting and running the SAME function from that commit's blob in an
# identical sandbox (never asserted from reading the diff — actually run).
#
# Functions are extracted via awk (mirrors test-xaca-0771-upgrade-materialize-
# missing.sh's _extract_fn) rather than sourcing the whole file, both to avoid
# side effects in aiteamforge-upgrade.sh's main body and to let the SAME
# extraction technique pull a function out of an arbitrary git revision's
# blob without needing that revision checked out on disk anywhere.
#
# All filesystem activity is sandboxed under TEST_TMP_DIR. NEVER touches real
# $HOME/.aiteamforge or ~/aiteamforge — installer-test safety rule. This suite
# only READS the real tap tree (share/templates/{kanban,aliases}) and the
# local git history as fixture SOURCE content; it never writes to either.
#
# Designed to run standalone OR via test-runner.sh.
# Exit 0 = all cases pass (or skipped due to missing git history).
# Exit 1 = at least one case failed (standalone only — see the _STANDALONE
# note below for why non-standalone always exits 0 and relies on the
# runner's own FAIL: aggregation instead).

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_KANBAN="$TAP_ROOT/libexec/installers/install-kanban.sh"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
REAL_TEMPLATE="$TAP_ROOT/share/templates/kanban/kanban-helpers.template.sh"
REAL_ALIASES="$TAP_ROOT/share/templates/aliases/kanban-aliases.sh"

# The commit immediately BEFORE the XACA-1095 fix. Resolved via `git`'s own
# revision-walk syntax (never a hand-typed/guessed SHA) so this stays correct
# even if history is rewritten; if it cannot be resolved (e.g. a shallow
# clone missing this history), the "proof" cases below SKIP rather than
# fail — the current-behavior assertions do not depend on it and still run.
PRE_FIX_REV="1d49bfb^"

for _need in "$INSTALL_KANBAN" "$UPGRADE_SH" "$REAL_TEMPLATE" "$REAL_ALIASES"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
        echo "  This test must run from inside the homebrew-tap checkout." >&2
        exit 1
    fi
done

_PRE_FIX_AVAILABLE=true
if ! command -v git >/dev/null 2>&1 || ! git -C "$TAP_ROOT" cat-file -e "${PRE_FIX_REV}" 2>/dev/null; then
    _PRE_FIX_AVAILABLE=false
fi

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (works sourced by test-runner.sh OR invoked directly).
# Local _PASS/_FAIL always tally (so the case-level fail-guard below never
# has to distinguish standalone vs runner); the trailing summary print is
# gated to standalone only, matching the fix in test-xaca-0632-kb-variance.sh
# (an ungated own-summary is exactly what produced that file's vacuous
# "PASS=0 FAIL=0" line under the runner — see XACA-1095-007 investigation).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
_PASS_COUNT=0
_FAIL_COUNT=0
_CURRENT_TEST=""
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory (runner-supplied or our own).
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1095-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

WORK_DIR="$TEST_TMP_DIR/xaca1095"
mkdir -p "$WORK_DIR"
_next_sandbox() { mktemp -d "$WORK_DIR/sbx-XXXXXX"; }

# ─────────────────────────────────────────────────────────────────────────────
# Extraction helpers.
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn_from_content() {
    local fn="$1"
    awk -v fn="$fn" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    '
}
_extract_fn_from_file() {
    local file="$1" fn="$2"
    _extract_fn_from_content "$fn" < "$file"
}
_extract_fn_from_rev() {
    local rev="$1" relpath="$2" fn="$3"
    git -C "$TAP_ROOT" show "${rev}:${relpath}" 2>/dev/null | _extract_fn_from_content "$fn"
}

# ─────────────────────────────────────────────────────────────────────────────
# install_kanban_helpers runner. Extracts the function (current file, or a
# given git revision's blob) and calls it in an isolated subshell with
# logging functions stubbed — mirrors test-xaca-0564's run_guard but via
# awk-extraction instead of sourcing the whole installer, so an OLD
# revision's function body can be exercised without checking that revision
# out anywhere (install-kanban.sh's real BASH_SOURCE-relative `source
# "$SCRIPT_DIR/../lib/..."` calls would otherwise resolve wrongly for content
# copied outside libexec/installers/).
#
# which: "current" | "old"   install_root: sandbox with share/templates/...
# aiteam_dir: plain (non-git) target dir — the guard's dev-repo branch is not
# under test here (test-xaca-0564-kanban-helpers-overwrite-guard.sh owns that).
# ─────────────────────────────────────────────────────────────────────────────
_run_install_kanban_helpers() {
    local which="$1" install_root="$2" aiteam_dir="$3"
    local fn_src
    if [ "$which" = "current" ]; then
        fn_src="$(_extract_fn_from_file "$INSTALL_KANBAN" "install_kanban_helpers")"
    else
        fn_src="$(_extract_fn_from_rev "$PRE_FIX_REV" "libexec/installers/install-kanban.sh" "install_kanban_helpers")"
    fi
    if [ -z "$fn_src" ]; then
        echo "EXTRACT_FAILED: install_kanban_helpers ($which)" >&2
        return 2
    fi
    (
        info() { :; }; warning() { :; }; error() { :; }; success() { :; }
        export INSTALL_ROOT="$install_root"
        export AITEAMFORGE_DIR="$aiteam_dir"
        eval "$fn_src"
        install_kanban_helpers
    )
}

# ─────────────────────────────────────────────────────────────────────────────
# update_shell_helpers runner. Same extraction technique; also pulls in
# _xaca0771_mandatory_alias_basenames (called from the alias-file loop later
# in the same function body — unchanged by XACA-1095, confirmed via
# `git diff 1d49bfb^ 1d49bfb -- libexec/commands/aiteamforge-upgrade.sh`,
# so it is safe to always extract the CURRENT copy regardless of which
# revision of update_shell_helpers itself is under test).
# ─────────────────────────────────────────────────────────────────────────────
_run_update_shell_helpers() {
    local which="$1" framework_dir="$2" working_dir="$3" force="${4:-false}" dry_run="${5:-false}"
    local fn_src alias_fn_src
    alias_fn_src="$(_extract_fn_from_file "$UPGRADE_SH" "_xaca0771_mandatory_alias_basenames")"
    if [ "$which" = "current" ]; then
        fn_src="$(_extract_fn_from_file "$UPGRADE_SH" "update_shell_helpers")"
    else
        fn_src="$(_extract_fn_from_rev "$PRE_FIX_REV" "libexec/commands/aiteamforge-upgrade.sh" "update_shell_helpers")"
    fi
    if [ -z "$fn_src" ] || [ -z "$alias_fn_src" ]; then
        echo "EXTRACT_FAILED: update_shell_helpers ($which)" >&2
        return 2
    fi
    (
        for _p in print_section print_info print_success print_warning print_error; do
            eval "${_p}() { :; }"
        done
        eval "$alias_fn_src"
        eval "$fn_src"
        FRAMEWORK_DIR="$framework_dir" WORKING_DIR="$working_dir" DRY_RUN="$dry_run" FORCE="$force" \
            update_shell_helpers
    )
}

_build_install_sandbox() {
    local dir="$1"
    mkdir -p "$dir/share/templates/kanban" "$dir/share/templates/aliases"
    cp "$REAL_TEMPLATE" "$dir/share/templates/kanban/kanban-helpers.template.sh"
    cp "$REAL_ALIASES" "$dir/share/templates/aliases/kanban-aliases.sh"
}
_build_upgrade_framework_sandbox() {
    local dir="$1"
    mkdir -p "$dir/share/templates/kanban" "$dir/share/templates/aliases"
    cp "$REAL_TEMPLATE" "$dir/share/templates/kanban/kanban-helpers.template.sh"
    cp "$REAL_ALIASES" "$dir/share/templates/aliases/kanban-aliases.sh"
}

_pre_fix_skip_msg() {
    printf "  SKIP: pre-fix revision %s not reachable in this checkout (shallow clone?) — current-behavior assertions above are unaffected\n" "$PRE_FIX_REV"
}

# ═══════════════════════════════════════════════════════════════════════════
# GROUP 1 — SOURCE SELECTION: install and upgrade both prefer the template
# ═══════════════════════════════════════════════════════════════════════════

test_start "T1: install_kanban_helpers (current) selects kanban-helpers.template.sh over kanban-aliases.sh"
T1_ROOT="$(_next_sandbox)"; T1_TARGET="$(_next_sandbox)"
_build_install_sandbox "$T1_ROOT"
_run_install_kanban_helpers current "$T1_ROOT" "$T1_TARGET" >/dev/null 2>&1
if [ -f "$T1_TARGET/kanban-helpers.sh" ] && grep -q '^kb-sweep()' "$T1_TARGET/kanban-helpers.sh"; then
    test_pass
else
    test_fail "kb-sweep not found in rendered kanban-helpers.sh — template was not selected (or install failed)"
fi

test_start "T2 (proof): pre-fix install_kanban_helpers selected kanban-aliases.sh instead — T1's assertion would have FAILED"
if [ "$_PRE_FIX_AVAILABLE" != true ]; then
    _pre_fix_skip_msg
else
    T2_ROOT="$(_next_sandbox)"; T2_TARGET="$(_next_sandbox)"
    _build_install_sandbox "$T2_ROOT"
    _run_install_kanban_helpers old "$T2_ROOT" "$T2_TARGET" >/dev/null 2>&1
    if [ -f "$T2_TARGET/kanban-helpers.sh" ] && ! grep -q '^kb-sweep()' "$T2_TARGET/kanban-helpers.sh"; then
        test_pass
    else
        test_fail "pre-fix install_kanban_helpers unexpectedly selected the template (or produced no output) — proof invalid, verify PRE_FIX_REV"
    fi
fi

test_start "T3: update_shell_helpers (current) selects kanban-helpers.template.sh over kanban-aliases.sh"
T3_FW="$(_next_sandbox)"; T3_WORK="$(_next_sandbox)"
_build_upgrade_framework_sandbox "$T3_FW"
printf '#!/bin/zsh\n# placeholder — will be refreshed\n' > "$T3_WORK/kanban-helpers.sh"
touch -t 200001010000 "$T3_WORK/kanban-helpers.sh"
_run_update_shell_helpers current "$T3_FW" "$T3_WORK" false false >/dev/null 2>&1
if grep -q '^kb-sweep()' "$T3_WORK/kanban-helpers.sh"; then
    test_pass
else
    test_fail "kb-sweep not found after update — template was not selected (or update failed)"
fi

test_start "T4 (proof): pre-fix update_shell_helpers selected kanban-aliases.sh instead — T3's assertion would have FAILED"
if [ "$_PRE_FIX_AVAILABLE" != true ]; then
    _pre_fix_skip_msg
else
    T4_FW="$(_next_sandbox)"; T4_WORK="$(_next_sandbox)"
    _build_upgrade_framework_sandbox "$T4_FW"
    printf '#!/bin/zsh\n# placeholder — will be refreshed\n' > "$T4_WORK/kanban-helpers.sh"
    touch -t 200001010000 "$T4_WORK/kanban-helpers.sh"
    _run_update_shell_helpers old "$T4_FW" "$T4_WORK" false false >/dev/null 2>&1
    if ! grep -q '^kb-sweep()' "$T4_WORK/kanban-helpers.sh"; then
        test_pass
    else
        test_fail "pre-fix update_shell_helpers unexpectedly selected the template — proof invalid, verify PRE_FIX_REV"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# GROUP 2 — CONTENT COMPLETENESS: the flip actually restores the commands the
# ticket names as the field-confirmed casualties (kb-sweep is the
# protected-subitem PR merge gate — the single highest-severity one).
# Reuses T1/T3's already-rendered output (no need to re-render).
# ═══════════════════════════════════════════════════════════════════════════

test_start "T5: rendered kanban-helpers.sh (install) contains kb-sweep, kb-epic, kb-release, kb-context-show"
_missing=""
for _marker in kb-sweep kb-epic kb-release kb-context-show; do
    grep -q "^${_marker}()" "$T1_TARGET/kanban-helpers.sh" 2>/dev/null || _missing="${_missing}${_missing:+, }${_marker}"
done
if [ -z "$_missing" ]; then test_pass; else test_fail "missing: $_missing"; fi

test_start "T6: rendered kanban-helpers.sh (upgrade) contains kb-sweep, kb-epic, kb-release, kb-context-show"
_missing=""
for _marker in kb-sweep kb-epic kb-release kb-context-show; do
    grep -q "^${_marker}()" "$T3_WORK/kanban-helpers.sh" 2>/dev/null || _missing="${_missing}${_missing:+, }${_marker}"
done
if [ -z "$_missing" ]; then test_pass; else test_fail "missing: $_missing"; fi

# ═══════════════════════════════════════════════════════════════════════════
# GROUP 3 — AT-RISK PORTED FUNCTIONS: the four functions XACA-1095-007 named
# as newly restored FROM kanban-aliases.sh INTO kanban-helpers.template.sh
# (see that file's "functions restored from ... kanban-aliases.sh" block) —
# confirm the preference flip did not strand them a second time.
# ═══════════════════════════════════════════════════════════════════════════

test_start "T7: rendered kanban-helpers.sh (install) still defines _kb_realpath, kb-quarantine-stub, kb-variance, kb-merged"
_missing=""
for _marker in _kb_realpath kb-quarantine-stub kb-variance kb-merged; do
    grep -q "^${_marker}()" "$T1_TARGET/kanban-helpers.sh" 2>/dev/null || _missing="${_missing}${_missing:+, }${_marker}"
done
if [ -z "$_missing" ]; then test_pass; else test_fail "missing: $_missing"; fi

test_start "T8: rendered kanban-helpers.sh (upgrade) still defines _kb_realpath, kb-quarantine-stub, kb-variance, kb-merged"
_missing=""
for _marker in _kb_realpath kb-quarantine-stub kb-variance kb-merged; do
    grep -q "^${_marker}()" "$T3_WORK/kanban-helpers.sh" 2>/dev/null || _missing="${_missing}${_missing:+, }${_marker}"
done
if [ -z "$_missing" ]; then test_pass; else test_fail "missing: $_missing"; fi

# ═══════════════════════════════════════════════════════════════════════════
# GROUP 4 — CONTENT-AWARE REFRESH: the independent "-nt" unsoundness fix.
# Reproduces the exact field symptom (installed-version frozen across four
# upgrades) by giving the INSTALLED target a mtime in the FUTURE relative to
# the freshly-copied source — the scenario a naive `[ source -nt target ]`
# check reads as "target is newer, nothing to do" even though its CONTENT is
# stale garbage. Never relies on real git-checkout mtime timing (unreliable
# across clones/CI) — the future-dated `touch` reproduces it deterministically.
# ═══════════════════════════════════════════════════════════════════════════

_STALE_TARGET_CONTENT='#!/bin/zsh
# STALE-XACA1095-PROBE — deliberately does not match either shipped source
kb-old-stub() { echo "stale"; }
'

test_start "T9: update_shell_helpers (current) refreshes a stale installed copy even when its mtime is NEWER than the shipped source"
T9_FW="$(_next_sandbox)"; T9_WORK="$(_next_sandbox)"
_build_upgrade_framework_sandbox "$T9_FW"
printf '%s' "$_STALE_TARGET_CONTENT" > "$T9_WORK/kanban-helpers.sh"
touch -t 209912312359 "$T9_WORK/kanban-helpers.sh"
if grep -q '^kb-sweep()' "$T9_WORK/kanban-helpers.sh" 2>/dev/null; then
    test_fail "PRECONDITION FAILED: stale fixture already contains kb-sweep — test would be vacuous"
else
    _run_update_shell_helpers current "$T9_FW" "$T9_WORK" false false >/dev/null 2>&1
    if grep -q '^kb-sweep()' "$T9_WORK/kanban-helpers.sh" 2>/dev/null; then
        test_pass
    else
        test_fail "kanban-helpers.sh was NOT refreshed despite content differing from the shipped template — content-aware check regressed to mtime-blindness"
    fi
fi

test_start "T10 (proof): pre-fix update_shell_helpers left the stale copy in place in the identical scenario — reproduces the frozen-.installed-version field bug"
if [ "$_PRE_FIX_AVAILABLE" != true ]; then
    _pre_fix_skip_msg
else
    T10_FW="$(_next_sandbox)"; T10_WORK="$(_next_sandbox)"
    _build_upgrade_framework_sandbox "$T10_FW"
    printf '%s' "$_STALE_TARGET_CONTENT" > "$T10_WORK/kanban-helpers.sh"
    touch -t 209912312359 "$T10_WORK/kanban-helpers.sh"
    _T10_BEFORE="$(cat "$T10_WORK/kanban-helpers.sh")"
    _run_update_shell_helpers old "$T10_FW" "$T10_WORK" false false >/dev/null 2>&1
    _T10_AFTER="$(cat "$T10_WORK/kanban-helpers.sh" 2>/dev/null || echo "")"
    if [ "$_T10_BEFORE" = "$_T10_AFTER" ]; then
        test_pass
    else
        test_fail "pre-fix update_shell_helpers unexpectedly refreshed the stale copy — proof invalid, verify PRE_FIX_REV/staleness fixture"
    fi
fi

test_start "T11: DRY_RUN=true does not modify a stale, future-dated installed copy (bonus dry-run guard on the same fixture as T9)"
T11_FW="$(_next_sandbox)"; T11_WORK="$(_next_sandbox)"
_build_upgrade_framework_sandbox "$T11_FW"
printf '%s' "$_STALE_TARGET_CONTENT" > "$T11_WORK/kanban-helpers.sh"
touch -t 209912312359 "$T11_WORK/kanban-helpers.sh"
_T11_BEFORE="$(cat "$T11_WORK/kanban-helpers.sh")"
_run_update_shell_helpers current "$T11_FW" "$T11_WORK" false true >/dev/null 2>&1
_T11_AFTER="$(cat "$T11_WORK/kanban-helpers.sh" 2>/dev/null || echo "")"
if [ "$_T11_BEFORE" = "$_T11_AFTER" ]; then
    test_pass
else
    test_fail "DRY_RUN=true modified kanban-helpers.sh — dry-run must be a no-op"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone mode only — see header comment).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    if [ "$_FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
fi
exit 0
