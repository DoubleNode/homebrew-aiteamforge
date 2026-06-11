#!/bin/bash

# test-xaca-0673-mandatory-materialize.sh
# Regression tests for XACA-0673: update_runtime_helpers must MATERIALISE
# mandatory shared modules on upgrade even when the working-dir target is ABSENT.
#
# REGRESSION INTENT: XACA-0608's update_runtime_helpers refreshes ONLY scripts a
# machine already installed (`[ -f "$target" ] || continue`) — correct for
# optional/layout-specific helpers (CR pollers, station scripts). But it is fatal
# for a BRAND-NEW shared module introduced by a release and imported by an
# ALREADY-INSTALLED script: the importer is refreshed in place (gaining the new
# `import <module>` line) while the module itself is skipped (absent target),
# leaving the consumer with an importer but no module.
#
# Originating incident: iterm2_venv_bootstrap.py (added by XACA-0652, imported by
# iterm-browser.py / iterm2_window_manager.py). M4Mini auto-upgraded to 0.13.4:
# iterm-browser.py was refreshed and now did `import iterm2_venv_bootstrap`, but
# the module was never laid down on disk → `import iterm2` failed → the LCARS web
# cockpit tab failed to create. Same refresh-gap class as XACA-0558 / 0585 / 0608.
#
# Assertions:
#   1. update_runtime_helpers MATERIALISES a mandatory module (iterm2_venv_bootstrap.py)
#      when it is ABSENT from WORKING_DIR/scripts/ but a sibling IS installed.
#   2. The materialised module is valid Python (py_compile) and keeps its exec bit.
#   3. REGRESSION GUARD: an OPTIONAL absent helper (agent-panel-display.sh) is
#      STILL NOT materialised — the XACA-0608 intentional skip is preserved.
#   4. --dry-run does not materialise the mandatory module.
#   5. iterm2_venv_bootstrap.py is registered in the mandatory set (explicit).
#   6. PARITY GUARD (anti-drift): EVERY share/scripts/*.py module that is
#      imported by another shipped .py under share/ MUST appear in the mandatory
#      set. A newly shipped sibling-imported module that is forgotten here fails
#      this test — so the set can never silently drift behind the code.
#
# All filesystem activity is sandboxed to TEST_TMP_DIR.
# NEVER touches real $HOME / ~/.aiteamforge — installer-test safety rule.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"

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
if ! type -t assert_contains >/dev/null 2>&1; then
    assert_contains() { [[ "$1" == *"$2"* ]] || { test_fail "${3:-Expected to find '$2'}"; return 1; }; }
fi

# print_* stubs used by the extracted function.
for _p in print_section print_info print_success print_warning print_error; do
    if ! declare -f "$_p" >/dev/null 2>&1; then eval "${_p}() { :; }"; fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory (runner-supplied or our own).
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0673-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Extract the functions under test from upgrade.sh without sourcing the whole
# script (its main body has side effects). Each captured from `name() {` through
# the first column-0 `}`.
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$UPGRADE_SH"
}
for _fn in _xaca0608_render_team_script _xaca0608_aux_script_map \
           _xaca0608_aux_scriptdir_basenames _xaca0673_mandatory_materialize_basenames \
           update_runtime_helpers; do
    _src="$(_extract_fn "$_fn")"
    if [ -z "$_src" ]; then echo "FATAL: could not extract $_fn from upgrade.sh"; exit 1; fi
    eval "$_src"
    declare -f "$_fn" >/dev/null || { echo "FATAL: $_fn not defined after extraction"; exit 1; }
done

SANDBOX="$TEST_TMP_DIR/xaca0673"
RH_WORKING="$SANDBOX/rh-working"
RH_SCRIPTS="$RH_WORKING/scripts"
mkdir -p "$RH_SCRIPTS"

run_update_runtime_helpers() {
    FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$RH_WORKING" update_runtime_helpers 2>&1
}

MANDATORY_NAME="iterm2_venv_bootstrap.py"
MANDATORY_SRC="$TAP_ROOT/share/scripts/$MANDATORY_NAME"
SIBLING_SRC="$TAP_ROOT/share/scripts/iterm2_window_manager.py"

# ═══════════════════════════════════════════════════════════════════════════
# TEST 1: mandatory module is MATERIALISED when absent (sibling installed)
# ═══════════════════════════════════════════════════════════════════════════
test_start "update_runtime_helpers materialises an ABSENT mandatory module (iterm2_venv_bootstrap.py)"
if [ -f "$MANDATORY_SRC" ]; then
    # Seed a sibling that IS installed (mirrors the real M4Mini layout: the
    # importer is present and refreshed, but the bootstrap module is absent).
    if [ -f "$SIBLING_SRC" ]; then
        printf '#!/usr/bin/env python3\n# pre-existing sibling\n' > "$RH_SCRIPTS/iterm2_window_manager.py"
        chmod +x "$RH_SCRIPTS/iterm2_window_manager.py"
    fi
    rm -f "$RH_SCRIPTS/$MANDATORY_NAME"   # the brand-new module is NOT yet installed
    FORCE=false DRY_RUN=false run_update_runtime_helpers >/dev/null 2>&1
    assert_file_exists "$RH_SCRIPTS/$MANDATORY_NAME" \
        "Mandatory module must be materialised on upgrade even though its target was absent" \
        && test_pass
else
    test_fail "share/scripts/$MANDATORY_NAME missing — cannot exercise materialisation"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 2: materialised module is valid Python + keeps exec bit
# ═══════════════════════════════════════════════════════════════════════════
test_start "Materialised mandatory module is valid Python and executable"
if [ -f "$RH_SCRIPTS/$MANDATORY_NAME" ]; then
    if python3 -m py_compile "$RH_SCRIPTS/$MANDATORY_NAME" 2>/dev/null && [ -x "$RH_SCRIPTS/$MANDATORY_NAME" ]; then
        test_pass
    else
        test_fail "Materialised module must compile cleanly and retain its exec bit"
    fi
else
    test_fail "Materialised module absent — cannot validate"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 3: REGRESSION — an OPTIONAL absent helper is STILL not materialised
# ═══════════════════════════════════════════════════════════════════════════
test_start "Optional absent helper (agent-panel-display.sh) is NOT materialised (XACA-0608 skip preserved)"
rm -f "$RH_SCRIPTS/agent-panel-display.sh"
FORCE=false DRY_RUN=false run_update_runtime_helpers >/dev/null 2>&1
assert_file_not_exists "$RH_SCRIPTS/agent-panel-display.sh" \
    "Optional helpers must still NOT be materialised when absent — only the mandatory set is exempt" \
    && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 4: --dry-run does not materialise the mandatory module
# ═══════════════════════════════════════════════════════════════════════════
test_start "--dry-run does not materialise the mandatory module"
DRY_SCRIPTS="$SANDBOX/dry-working/scripts"
mkdir -p "$DRY_SCRIPTS"
[ -f "$SIBLING_SRC" ] && { printf '#!/usr/bin/env python3\n' > "$DRY_SCRIPTS/iterm2_window_manager.py"; chmod +x "$DRY_SCRIPTS/iterm2_window_manager.py"; }
FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$SANDBOX/dry-working" DRY_RUN=true FORCE=false update_runtime_helpers >/dev/null 2>&1
assert_file_not_exists "$DRY_SCRIPTS/$MANDATORY_NAME" \
    "--dry-run must not write the mandatory module to disk" \
    && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 5: mandatory set explicitly contains iterm2_venv_bootstrap.py
# ═══════════════════════════════════════════════════════════════════════════
test_start "Mandatory set registers iterm2_venv_bootstrap.py"
MANDATORY_SET="$(_xaca0673_mandatory_materialize_basenames)"
assert_contains $'\n'"$MANDATORY_SET"$'\n' $'\n'"$MANDATORY_NAME"$'\n' \
    "iterm2_venv_bootstrap.py must be in the mandatory-materialise set" \
    && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 6: PARITY GUARD — every sibling-imported shipped module is mandatory.
# Auto-detects future drift: if a new share/scripts/*.py module is imported by
# another shipped script but not added to the mandatory set, this FAILS.
# ═══════════════════════════════════════════════════════════════════════════
test_start "PARITY: every sibling-imported share/scripts module is in the mandatory set"
MISSING="$(
python3 - "$TAP_ROOT/share" <<'PY'
import os, re, glob, sys
share = sys.argv[1]
mods = {os.path.splitext(os.path.basename(p))[0]: os.path.normpath(p)
        for p in glob.glob(os.path.join(share, "scripts", "*.py"))}
imported = set()
for root, _, files in os.walk(share):
    for fn in files:
        if not fn.endswith(".py"):
            continue
        path = os.path.normpath(os.path.join(root, fn))
        try:
            txt = open(path, encoding="utf-8", errors="ignore").read()
        except Exception:
            continue
        for stem, modpath in mods.items():
            if path == modpath:
                continue
            if re.search(rf'(?m)^\s*(import\s+{re.escape(stem)}\b|from\s+{re.escape(stem)}\s+import)', txt):
                imported.add(stem + ".py")
# Print the sibling-imported module basenames (one per line).
for name in sorted(imported):
    print(name)
PY
)"
MANDATORY_SET="$(_xaca0673_mandatory_materialize_basenames)"
_parity_ok=true
while IFS= read -r mod; do
    [ -n "$mod" ] || continue
    case $'\n'"$MANDATORY_SET"$'\n' in
        *$'\n'"$mod"$'\n'*) : ;;
        *) _parity_ok=false; echo "     DRIFT: '$mod' is imported by a shipped script but missing from the mandatory set" >&2 ;;
    esac
done <<< "$MISSING"
if [ "$_parity_ok" = true ]; then
    test_pass
else
    test_fail "Sibling-imported shipped module(s) missing from _xaca0673_mandatory_materialize_basenames — add them"
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
