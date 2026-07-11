#!/bin/bash

# test-xaca-0771-upgrade-materialize-missing.sh
#
# Regression tests for XACA-0771: `aiteamforge upgrade` must CREATE two classes
# of mandatory files when missing, not just refresh them when already present.
#
# DEFECT A (aliases): update_shell_helpers' alias loop (aiteamforge-upgrade.sh)
# had `if [ ! -f "$target" ]; then continue; fi` — a missing
# share/aliases/cc-aliases.sh was NEVER created on upgrade, only refreshed if
# it already existed. cc-aliases.sh defines the `cc` alias/function that
# redirects the bare `cc` command away from /usr/bin/cc (clang); a box whose
# copy was never laid down (pre-XACA-0494 install) or got deleted silently
# fell through to clang with no upgrade path back to a fix.
#
# DEFECT B (hooks): aiteamforge-upgrade.sh had NO function that ever touched
# ~/.claude/hooks/ at all. install_hooks() (install-claude-config.sh) only
# runs from install_claude_config(), reached on a FRESH `aiteamforge setup` —
# never from `aiteamforge upgrade`. settings.json.template wires
# {{CLAUDE_CONFIG_DIR}}/hooks/inject-time-context.sh as the UserPromptSubmit
# hook; a box whose hooks/ predates that file (or lost it) silently ran with
# time-context injection broken, with no upgrade path to fix it. Compounding
# this, install_hooks() itself never copied inject-time-context.sh even on a
# FRESH install (install-side parity gap, also fixed by this ticket).
#
# Fix (aiteamforge-upgrade.sh):
#   - update_shell_helpers' alias loop: a missing target is now CREATED (not
#     skipped) when its basename is in the MANDATORY set
#     (_xaca0771_mandatory_alias_basenames — all three shipped alias files
#     today). A non-mandatory alias file would still skip-if-absent (none
#     exist today, but the branching preserves that option).
#   - new update_claude_hooks(): reuses install_hooks() verbatim (same idiom
#     as update_knowledge_repo/update_knowledge_sync reusing their installer
#     counterparts) in a `set -u`-isolating, fail-soft subshell. Wired into
#     the run sequence right after update_shell_helpers.
#   - Both add an assert-present pass afterward: loudly print_warning any
#     mandatory file still missing (never a hard failure).
#
# Fix (install-claude-config.sh): install_hooks() now also copies
# inject-time-context.sh (mirrors the existing block-icloud-paths.py
# read-only-guard + chmod pattern) — closes the fresh-install parity gap.
#
# Assertions in this suite:
#   T1  MISSING-ALIAS-CREATED: missing cc-aliases.sh is CREATED by
#       update_shell_helpers (the exact clang-breakage symptom from the ticket).
#   T2  EXISTING-ALIAS-REFRESHED: an alias file that already exists AND is
#       older than its template still gets refreshed (untouched-by-this-fix
#       regression guard).
#   T3  ALIAS-ASSERT-PRESENT-WARNS: if the shipped template source for a
#       mandatory alias is itself missing, update_shell_helpers emits a
#       print_warning naming the file (loud, non-fatal).
#   T4  ALIAS-DRY-RUN: DRY_RUN=true does not create a missing alias file.
#   T5  HOOK-INJECT-TIME-CONTEXT-CREATED: missing inject-time-context.sh is
#       CREATED in the sandboxed CLAUDE_CONFIG_DIR/hooks/ by update_claude_hooks.
#   T6  HOOK-BLOCK-ICLOUD-CREATED: missing block-icloud-paths.py is CREATED.
#   T7  HOOK-DAMAGE-CONTROL-CREATED: missing damage-control/*.py hook scripts
#       are CREATED.
#   T8  HOOK-DRY-RUN: DRY_RUN=true does not create any missing hook file.
#   T9  HOOK-ASSERT-PRESENT-WARNS: if TEMPLATE_DIR resolves somewhere with no
#       hooks templates at all, update_claude_hooks emits print_warning naming
#       each still-missing mandatory hook (loud, non-fatal — never aborts).
#   T10 STRUCTURAL: update_claude_hooks() is DEFINED in aiteamforge-upgrade.sh.
#   T11 STRUCTURAL: update_claude_hooks is CALLED (bare line) in the run
#       sequence — the assertion that would have caught the original bug (a
#       defined-but-never-called function means existing fleet machines never
#       receive the hook files on upgrade; mirrors the XACA-0751/XACA-0761
#       "would have caught it" guard tests).
#   T12 STRUCTURAL: install_hooks() (install-claude-config.sh) now references
#       inject-time-context.sh (install-side fresh-install parity fix).
#
# Non-vacuous precondition guards (feedback_parity_test_wrong_shell_passes_
# vacuously): every CREATED assertion first confirms the target is ABSENT
# before invoking the function under test, then confirms it exists after.
#
# All filesystem activity is sandboxed under TEST_TMP_DIR. NEVER touches real
# $HOME/.claude or ~/aiteamforge — installer-test safety rule. This suite only
# READS the real tap tree (share/templates/{aliases,claude/hooks}) as fixture
# SOURCE content; it never writes there.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
CLAUDE_INSTALLER="$TAP_ROOT/libexec/installers/install-claude-config.sh"

for _need in "$UPGRADE_SH" "$CLAUDE_INSTALLER"; do
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
# Temp directory (runner-supplied or our own).
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0771-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

WORK_DIR="$TEST_TMP_DIR/xaca0771"
mkdir -p "$WORK_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Extract the functions under test from upgrade.sh without sourcing the whole
# script (its main body has side effects) — mirrors test-xaca-0610's _extract_fn.
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$UPGRADE_SH"
}

EXTRACTED="$WORK_DIR/extracted-functions.sh"
: > "$EXTRACTED"
for _fn in _xaca0771_mandatory_alias_basenames update_shell_helpers \
           _xaca0771_mandatory_hook_basenames update_claude_hooks; do
    _src="$(_extract_fn "$_fn")"
    if [ -z "$_src" ]; then
        echo "FATAL: could not extract $_fn from $UPGRADE_SH" >&2
        exit 1
    fi
    printf '%s\n\n' "$_src" >> "$EXTRACTED"
done

# print_* stubs that ALSO record output so tests can grep for specific
# warning text (mirrors test-xaca-0751's printf-based stubs, not test-xaca-0610's
# no-op stubs — this suite needs to observe the assert-present warning text).
_STUB_LOG="$WORK_DIR/stub-output.log"
_install_print_stubs() {
    : > "$_STUB_LOG"
    for _p in print_section print_info print_success print_warning print_error; do
        eval "${_p}() { printf '%s\n' \"\$*\" >> \"\$_STUB_LOG\"; }"
    done
}
_install_print_stubs
export _STUB_LOG

# shellcheck disable=SC1090
source "$EXTRACTED"
for _fn in _xaca0771_mandatory_alias_basenames update_shell_helpers \
           _xaca0771_mandatory_hook_basenames update_claude_hooks; do
    declare -f "$_fn" >/dev/null || { echo "FATAL: $_fn not defined after extraction"; exit 1; }
done

# ─────────────────────────────────────────────────────────────────────────────
# Shared fixture data (read-only references into the real tap tree).
# ─────────────────────────────────────────────────────────────────────────────
ALIASES_SRC_DIR="$TAP_ROOT/share/templates/aliases"
HOOKS_SRC_DIR="$TAP_ROOT/share/templates/claude/hooks"
for _f in "$ALIASES_SRC_DIR/cc-aliases.sh" "$ALIASES_SRC_DIR/agent-aliases.sh" \
          "$ALIASES_SRC_DIR/worktree-aliases.sh" "$HOOKS_SRC_DIR/inject-time-context.sh" \
          "$HOOKS_SRC_DIR/block-icloud-paths.py"; do
    if [ ! -f "$_f" ]; then
        echo "FATAL: expected shipped fixture source missing: $_f" >&2
        exit 1
    fi
done

_next_sandbox() { mktemp -d "$WORK_DIR/sbx-XXXXXX"; }

# ═══════════════════════════════════════════════════════════════════════════
# T1 — MISSING-ALIAS-CREATED: missing cc-aliases.sh is CREATED on upgrade
# ═══════════════════════════════════════════════════════════════════════════
test_start "T1: missing cc-aliases.sh is CREATED by update_shell_helpers (was: strands cc to clang)"
T1_WORKING="$(_next_sandbox)"
mkdir -p "$T1_WORKING/share/aliases"
# Seed the OTHER two alias files so this models a "partial install" (one file
# deleted / never laid down), not a from-scratch fresh install.
sed -e "s|{{AITEAMFORGE_DIR}}|${T1_WORKING}|g" "$ALIASES_SRC_DIR/agent-aliases.sh" \
    > "$T1_WORKING/share/aliases/agent-aliases.sh"
sed -e "s|{{AITEAMFORGE_DIR}}|${T1_WORKING}|g" "$ALIASES_SRC_DIR/worktree-aliases.sh" \
    > "$T1_WORKING/share/aliases/worktree-aliases.sh"

if [ -f "$T1_WORKING/share/aliases/cc-aliases.sh" ]; then
    test_fail "PRECONDITION FAILED: cc-aliases.sh already present in T1 sandbox — test would be vacuous"
else
    _install_print_stubs
    FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T1_WORKING" DRY_RUN=false FORCE=false \
        update_shell_helpers >/dev/null 2>&1
    if [ -f "$T1_WORKING/share/aliases/cc-aliases.sh" ] \
        && grep -q "AITEAMFORGE_DIR=\"${T1_WORKING}\"" "$T1_WORKING/share/aliases/cc-aliases.sh"; then
        test_pass
    else
        test_fail "cc-aliases.sh was not created (or template substitution did not apply) — content: $(cat "$T1_WORKING/share/aliases/cc-aliases.sh" 2>/dev/null | head -3 || echo MISSING)"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T2 — EXISTING-ALIAS-REFRESHED: an existing, stale alias file still refreshes
# ═══════════════════════════════════════════════════════════════════════════
test_start "T2: an EXISTING stale alias file is still refreshed when the template is newer"
T2_WORKING="$(_next_sandbox)"
mkdir -p "$T2_WORKING/share/aliases"
STALE_MARKER="# STALE-ALIAS-PROBE-XACA0771"
printf '#!/bin/zsh\n%s\n' "$STALE_MARKER" > "$T2_WORKING/share/aliases/worktree-aliases.sh"
# Force the target to be OLDER than the shipped template regardless of local
# checkout mtimes (git checkout mtimes are unreliable across clones/CI).
touch -t 200001010000 "$T2_WORKING/share/aliases/worktree-aliases.sh"

_before="$(cat "$T2_WORKING/share/aliases/worktree-aliases.sh")"
if [[ "$_before" != *"$STALE_MARKER"* ]]; then
    test_fail "PRECONDITION FAILED: stale marker not found before upgrade — test is vacuous"
else
    _install_print_stubs
    FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T2_WORKING" DRY_RUN=false FORCE=false \
        update_shell_helpers >/dev/null 2>&1
    _after="$(cat "$T2_WORKING/share/aliases/worktree-aliases.sh")"
    if [[ "$_after" != *"$STALE_MARKER"* ]] && grep -q "$T2_WORKING" "$T2_WORKING/share/aliases/worktree-aliases.sh"; then
        test_pass
    else
        test_fail "stale worktree-aliases.sh was not refreshed"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T3 — ALIAS-ASSERT-PRESENT-WARNS: missing shipped template -> loud warning
# ═══════════════════════════════════════════════════════════════════════════
test_start "T3: update_shell_helpers warns (does not silently pass) when a mandatory alias template itself is missing"
T3_WORKING="$(_next_sandbox)"
T3_FRAMEWORK="$(_next_sandbox)"
mkdir -p "$T3_WORKING/share/aliases" "$T3_FRAMEWORK/share/templates/aliases"
# Ship only agent-aliases.sh + worktree-aliases.sh templates — cc-aliases.sh's
# TEMPLATE is missing (models a corrupted/incomplete Cellar payload).
cp "$ALIASES_SRC_DIR/agent-aliases.sh" "$T3_FRAMEWORK/share/templates/aliases/"
cp "$ALIASES_SRC_DIR/worktree-aliases.sh" "$T3_FRAMEWORK/share/templates/aliases/"

if [ -f "$T3_FRAMEWORK/share/templates/aliases/cc-aliases.sh" ]; then
    test_fail "PRECONDITION FAILED: cc-aliases.sh template unexpectedly present in T3 sandbox framework"
else
    _install_print_stubs
    FRAMEWORK_DIR="$T3_FRAMEWORK" WORKING_DIR="$T3_WORKING" DRY_RUN=false FORCE=false \
        update_shell_helpers >/dev/null 2>&1
    if grep -q "Mandatory alias file still missing" "$_STUB_LOG" \
        && grep -q "cc-aliases.sh" "$_STUB_LOG"; then
        test_pass
    else
        test_fail "expected a 'Mandatory alias file still missing' warning naming cc-aliases.sh; stub log: $(cat "$_STUB_LOG")"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T4 — ALIAS-DRY-RUN: DRY_RUN=true must not create a missing alias file
# ═══════════════════════════════════════════════════════════════════════════
test_start "T4: DRY_RUN=true does not create a missing cc-aliases.sh"
T4_WORKING="$(_next_sandbox)"
mkdir -p "$T4_WORKING/share/aliases"
sed -e "s|{{AITEAMFORGE_DIR}}|${T4_WORKING}|g" "$ALIASES_SRC_DIR/agent-aliases.sh" \
    > "$T4_WORKING/share/aliases/agent-aliases.sh"
sed -e "s|{{AITEAMFORGE_DIR}}|${T4_WORKING}|g" "$ALIASES_SRC_DIR/worktree-aliases.sh" \
    > "$T4_WORKING/share/aliases/worktree-aliases.sh"

if [ -f "$T4_WORKING/share/aliases/cc-aliases.sh" ]; then
    test_fail "PRECONDITION FAILED: cc-aliases.sh already present in T4 sandbox"
else
    _install_print_stubs
    FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T4_WORKING" DRY_RUN=true FORCE=false \
        update_shell_helpers >/dev/null 2>&1
    assert_file_not_exists "$T4_WORKING/share/aliases/cc-aliases.sh" \
        "DRY_RUN=true must not create cc-aliases.sh" && test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# T5 — HOOK-INJECT-TIME-CONTEXT-CREATED
# ═══════════════════════════════════════════════════════════════════════════
test_start "T5: missing inject-time-context.sh is CREATED by update_claude_hooks"
T5_WORKING="$(_next_sandbox)"
T5_CLAUDE="$(_next_sandbox)/.claude"
mkdir -p "$T5_WORKING"

if [ -f "$T5_CLAUDE/hooks/inject-time-context.sh" ]; then
    test_fail "PRECONDITION FAILED: inject-time-context.sh already present in T5 sandbox"
else
    _install_print_stubs
    (
        LIBEXEC_DIR="$TAP_ROOT/libexec" FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T5_WORKING" \
        CLAUDE_CONFIG_DIR="$T5_CLAUDE" DRY_RUN=false FORCE=false \
        update_claude_hooks
    ) >/dev/null 2>&1
    if [ -f "$T5_CLAUDE/hooks/inject-time-context.sh" ]; then
        test_pass
    else
        test_fail "inject-time-context.sh was not created at $T5_CLAUDE/hooks/; stub log: $(cat "$_STUB_LOG")"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T6 — HOOK-BLOCK-ICLOUD-CREATED
# ═══════════════════════════════════════════════════════════════════════════
test_start "T6: missing block-icloud-paths.py is CREATED by update_claude_hooks"
if [ -f "$T5_CLAUDE/hooks/block-icloud-paths.py" ]; then
    test_pass
else
    test_fail "block-icloud-paths.py was not created at $T5_CLAUDE/hooks/ (reusing T5's run)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T7 — HOOK-DAMAGE-CONTROL-CREATED
# ═══════════════════════════════════════════════════════════════════════════
test_start "T7: missing damage-control/*.py hook scripts are CREATED by update_claude_hooks"
_T7_ALL_PRESENT=true
for _dc in bash-tool-damage-control.py edit-tool-damage-control.py write-tool-damage-control.py; do
    if [ ! -f "$T5_CLAUDE/hooks/damage-control/$_dc" ]; then
        _T7_ALL_PRESENT=false
        break
    fi
done
if [ "$_T7_ALL_PRESENT" = true ]; then
    test_pass
else
    test_fail "one or more damage-control/*.py hook scripts missing under $T5_CLAUDE/hooks/damage-control/ (reusing T5's run)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T8 — HOOK-DRY-RUN: DRY_RUN=true must not create any missing hook file
# ═══════════════════════════════════════════════════════════════════════════
test_start "T8: DRY_RUN=true does not create any missing hook file"
T8_WORKING="$(_next_sandbox)"
T8_CLAUDE="$(_next_sandbox)/.claude"

if [ -e "$T8_CLAUDE" ]; then
    test_fail "PRECONDITION FAILED: T8 CLAUDE_CONFIG_DIR already exists"
else
    _install_print_stubs
    (
        LIBEXEC_DIR="$TAP_ROOT/libexec" FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T8_WORKING" \
        CLAUDE_CONFIG_DIR="$T8_CLAUDE" DRY_RUN=true FORCE=false \
        update_claude_hooks
    ) >/dev/null 2>&1
    if [ ! -e "$T8_CLAUDE/hooks/inject-time-context.sh" ] \
        && [ ! -e "$T8_CLAUDE/hooks/block-icloud-paths.py" ] \
        && [ ! -e "$T8_CLAUDE/hooks/damage-control" ]; then
        test_pass
    else
        test_fail "DRY_RUN=true created hook file(s) it should not have: $(find "$T8_CLAUDE" 2>/dev/null)"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T9 — HOOK-ASSERT-PRESENT-WARNS: no hook templates at all -> loud warnings,
# fail-soft (never aborts the calling shell).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T9: update_claude_hooks warns (fail-soft) when hook templates are entirely absent"
T9_WORKING="$(_next_sandbox)"
T9_CLAUDE="$(_next_sandbox)/.claude"
T9_FRAMEWORK="$(_next_sandbox)"
mkdir -p "$T9_FRAMEWORK/share/templates"   # templates/claude/hooks/ deliberately absent

_install_print_stubs
_T9_RC=0
(
    set -eo pipefail
    LIBEXEC_DIR="$TAP_ROOT/libexec" FRAMEWORK_DIR="$T9_FRAMEWORK" WORKING_DIR="$T9_WORKING" \
    CLAUDE_CONFIG_DIR="$T9_CLAUDE" DRY_RUN=false FORCE=false \
    update_claude_hooks
    echo "SHELL_SURVIVED"
) >"$WORK_DIR/t9-stdout.log" 2>&1 || _T9_RC=$?

if [ "$_T9_RC" = "0" ] && grep -q "SHELL_SURVIVED" "$WORK_DIR/t9-stdout.log" \
    && grep -q "Mandatory Claude Code hook still missing" "$_STUB_LOG" \
    && grep -q "inject-time-context.sh" "$_STUB_LOG"; then
    test_pass
else
    test_fail "rc=$_T9_RC; expected fail-soft warnings naming missing hooks; stub log: $(cat "$_STUB_LOG"); stdout: $(cat "$WORK_DIR/t9-stdout.log")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T10 — STRUCTURAL: update_claude_hooks() is DEFINED in aiteamforge-upgrade.sh
# ═══════════════════════════════════════════════════════════════════════════
test_start "T10: update_claude_hooks() is defined in aiteamforge-upgrade.sh"
if grep -qE '^update_claude_hooks\(\) \{' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "no 'update_claude_hooks() {' definition found in $UPGRADE_SH"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T11 — STRUCTURAL: update_claude_hooks is CALLED (bare line) in the run
# sequence. This is the assertion that would have caught the original bug.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T11: update_claude_hooks is invoked (bare call) in the upgrade run sequence"
if grep -qE '^update_claude_hooks$' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "aiteamforge-upgrade.sh run sequence must call update_claude_hooks (bare line) — a defined-but-never-called function means EXISTING fleet machines never receive the hook files on upgrade (XACA-0771 / XACA-0751 lesson)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T12 — STRUCTURAL: install_hooks() (install-claude-config.sh) now covers
# inject-time-context.sh (fresh-install parity fix).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T12: install_hooks() in install-claude-config.sh references inject-time-context.sh"
INSTALL_HOOKS_FN_SRC="$WORK_DIR/install_hooks.extracted.sh"
awk '
  /^install_hooks\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$CLAUDE_INSTALLER" > "$INSTALL_HOOKS_FN_SRC"
if [ -s "$INSTALL_HOOKS_FN_SRC" ] && grep -q "inject-time-context.sh" "$INSTALL_HOOKS_FN_SRC"; then
    test_pass
else
    test_fail "install_hooks() must copy inject-time-context.sh (fresh-install parity gap XACA-0771 fixes) — not found in extracted function body"
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
