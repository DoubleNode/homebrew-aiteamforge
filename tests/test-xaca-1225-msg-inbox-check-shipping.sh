#!/bin/bash
# test-xaca-1225-msg-inbox-check-shipping.sh
#
# XACA-1225 (orchestrator addendum, alongside -001/-002): the kb-msg inbox
# hook script, claude-hooks/msg-inbox-check.sh, never shipped to ANY
# consumer. A sibling change adds the sync-tap.sh mapping that mirrors it
# into homebrew-tap/share/scripts/msg-inbox-check.sh, but until that sync
# runs the real share/ copy does not exist in this checkout — so every case
# here is sandboxed against a STUB share/scripts/msg-inbox-check.sh fixture,
# never the real tree, exactly as instructed.
#
# This suite covers the shipping path end to end:
#   ST1  install-shell.sh's helper copy loop names msg-inbox-check.sh
#   ST2  validate-install.sh's required_scripts list names msg-inbox-check.sh
#   ST3  aiteamforge-upgrade.sh's mandatory-materialize basenames names
#        msg-inbox-check.sh (so an ALREADY-INSTALLED box that never had this
#        brand-new file gets it on upgrade, not just a fresh install)
#   B1   BEHAVIOUR: install_helper_scripts() copies a stub
#        share/scripts/msg-inbox-check.sh to $AITEAMFORGE_DIR/scripts/ with
#        the executable bit set
#   B2   BEHAVIOUR: update_runtime_helpers() MATERIALISES msg-inbox-check.sh
#        on an upgrade even though the target was never present before
#        (mirrors test-xaca-0673's mandatory-materialize regression shape)
#   B3   BEHAVIOUR: update_runtime_helpers() --dry-run does NOT materialise it
#
# Runs standalone (`bash tests/test-xaca-1225-msg-inbox-check-shipping.sh`)
# OR via test-runner.sh. Exit 0 = all pass, exit 1 = any fail.
#
# Requires: bash. No network. Never touches real $HOME / ~/.aiteamforge.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SHELL_SH="$TAP_ROOT/libexec/installers/install-shell.sh"
VALIDATE_SH="$TAP_ROOT/libexec/lib/validate-install.sh"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"

for _need in "$INSTALL_SHELL_SH" "$VALIDATE_SH" "$UPGRADE_SH"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework.
# ─────────────────────────────────────────────────────────────────────────────
if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

for _p in print_section print_info print_success print_warning print_error \
          header info success warning error; do
    if ! declare -f "$_p" >/dev/null 2>&1; then eval "${_p}() { :; }"; fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1225-msg-inbox-check.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
WORK_DIR="$TEST_TMP_DIR/xaca1225-inbox"
mkdir -p "$WORK_DIR"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then
        find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

_extract_fn() {
    local file="$1" fn="$2"
    awk -v fn="$fn" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$file"
}

# ═══════════════════════════════════════════════════════════════════════════
# ST1 — install-shell.sh's helper copy loop names msg-inbox-check.sh
# ═══════════════════════════════════════════════════════════════════════════
test_start "ST1: install-shell.sh's helper copy loop includes msg-inbox-check.sh"
IHS_SRC="$WORK_DIR/install_helper_scripts.extracted.sh"
_extract_fn "$INSTALL_SHELL_SH" install_helper_scripts >"$IHS_SRC"
if [ -s "$IHS_SRC" ] && grep -qE '\bmsg-inbox-check\.sh\b' "$IHS_SRC" \
    && grep -qE 'for helper in.*msg-inbox-check\.sh|msg-inbox-check\.sh.*; do' "$IHS_SRC"; then
    test_pass
else
    test_fail "install_helper_scripts must copy msg-inbox-check.sh via the executable helper loop"
fi

# ═══════════════════════════════════════════════════════════════════════════
# ST2 — validate-install.sh's required_scripts list names msg-inbox-check.sh
# ═══════════════════════════════════════════════════════════════════════════
test_start "ST2: validate-install.sh's required_scripts includes msg-inbox-check.sh"
VAL_SRC="$WORK_DIR/val_check_scripts.extracted.sh"
_extract_fn "$VALIDATE_SH" _val_check_scripts >"$VAL_SRC"
if [ -s "$VAL_SRC" ] && grep -qE '"msg-inbox-check\.sh"' "$VAL_SRC"; then
    test_pass
else
    test_fail "_val_check_scripts must list msg-inbox-check.sh among required_scripts"
fi

# ═══════════════════════════════════════════════════════════════════════════
# ST3 — aiteamforge-upgrade.sh's mandatory-materialize basenames names it
# (STRUCTURAL: net-new file, so the default "refresh only what already
# exists" rule would otherwise skip it forever on every existing box).
# ═══════════════════════════════════════════════════════════════════════════
test_start "ST3: mandatory-materialize basenames includes msg-inbox-check.sh"
if grep -qE '^msg-inbox-check\.sh$' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "_xaca0673_mandatory_materialize_basenames must list msg-inbox-check.sh (exact line)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Fixture: a fake framework tree with ONLY a stub share/scripts/msg-inbox-check.sh
# — never the real tree, per the orchestrator's instruction (the real mirror
# does not exist yet in this checkout).
# ═══════════════════════════════════════════════════════════════════════════
FAKE_FRAMEWORK="$WORK_DIR/fake-framework"
mkdir -p "$FAKE_FRAMEWORK/share/scripts"
cat >"$FAKE_FRAMEWORK/share/scripts/msg-inbox-check.sh" <<'EOF'
#!/bin/bash
# stub fixture — XACA-1225 test double, not the real msg-inbox-check.sh
echo "stub msg-inbox-check"
EOF
chmod +x "$FAKE_FRAMEWORK/share/scripts/msg-inbox-check.sh"

# ═══════════════════════════════════════════════════════════════════════════
# B1 — install_helper_scripts() copies the stub to $AITEAMFORGE_DIR/scripts/
# with the executable bit set.
# ═══════════════════════════════════════════════════════════════════════════
test_start "B1: install_helper_scripts copies msg-inbox-check.sh, executable"
B1_HOME="$WORK_DIR/b1-home"
mkdir -p "$B1_HOME/aiteamforge"
(
    source "$IHS_SRC"
    AITEAMFORGE_DIR="$B1_HOME/aiteamforge"
    INSTALL_ROOT="$FAKE_FRAMEWORK"
    install_helper_scripts
) >"$WORK_DIR/b1.out" 2>&1
B1_DEST="$B1_HOME/aiteamforge/scripts/msg-inbox-check.sh"
if [ -x "$B1_DEST" ] && grep -q "stub msg-inbox-check" "$B1_DEST"; then
    test_pass
else
    test_fail "expected executable $B1_DEST containing the stub marker; out=$(cat "$WORK_DIR/b1.out")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# B2 — update_runtime_helpers() MATERIALISES msg-inbox-check.sh on upgrade
# even though the target was never present before (mirrors test-xaca-0673's
# mandatory-materialize regression shape for a brand-new file).
# ═══════════════════════════════════════════════════════════════════════════
UMH_DEPS_OK=true
URH_SRC="$WORK_DIR/update_runtime_helpers.extracted.sh"
for _fn in _xaca0608_render_team_script _xaca0608_aux_script_map \
           _xaca0608_aux_scriptdir_basenames _xaca0673_mandatory_materialize_basenames \
           update_runtime_helpers; do
    _fn_src="$(_extract_fn "$UPGRADE_SH" "$_fn")"
    if [ -z "$_fn_src" ]; then
        UMH_DEPS_OK=false
        break
    fi
    printf '%s\n' "$_fn_src" >>"$URH_SRC"
done

test_start "B2: update_runtime_helpers materialises an ABSENT msg-inbox-check.sh on upgrade"
if [ "$UMH_DEPS_OK" != "true" ]; then
    test_fail "could not extract update_runtime_helpers and its dependencies from aiteamforge-upgrade.sh"
else
    B2_WORKING="$WORK_DIR/b2-working"
    B2_SCRIPTS="$B2_WORKING/scripts"
    mkdir -p "$B2_SCRIPTS"
    # msg-inbox-check.sh deliberately absent — the "already-installed box that
    # never had this brand-new file" scenario.
    (
        source "$URH_SRC"
        FRAMEWORK_DIR="$FAKE_FRAMEWORK"
        WORKING_DIR="$B2_WORKING"
        DRY_RUN=false
        update_runtime_helpers
    ) >"$WORK_DIR/b2.out" 2>&1
    if [ -x "$B2_SCRIPTS/msg-inbox-check.sh" ] && grep -q "stub msg-inbox-check" "$B2_SCRIPTS/msg-inbox-check.sh"; then
        test_pass
    else
        test_fail "expected upgrade to materialise executable $B2_SCRIPTS/msg-inbox-check.sh; out=$(cat "$WORK_DIR/b2.out")"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# B3 — --dry-run does NOT materialise it (no filesystem writes on preview).
# ═══════════════════════════════════════════════════════════════════════════
test_start "B3: update_runtime_helpers --dry-run does not materialise msg-inbox-check.sh"
if [ "$UMH_DEPS_OK" != "true" ]; then
    test_fail "could not extract update_runtime_helpers and its dependencies from aiteamforge-upgrade.sh"
else
    B3_WORKING="$WORK_DIR/b3-working"
    B3_SCRIPTS="$B3_WORKING/scripts"
    mkdir -p "$B3_SCRIPTS"
    (
        source "$URH_SRC"
        FRAMEWORK_DIR="$FAKE_FRAMEWORK"
        WORKING_DIR="$B3_WORKING"
        DRY_RUN=true
        update_runtime_helpers
    ) >"$WORK_DIR/b3.out" 2>&1
    if [ ! -e "$B3_SCRIPTS/msg-inbox-check.sh" ]; then
        test_pass
    else
        test_fail "dry-run must not create $B3_SCRIPTS/msg-inbox-check.sh"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# Standalone summary + exit code
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "${_PASS_COUNT+x}" ]; then
    echo ""
    echo "XACA-1225 msg-inbox-check-shipping tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
