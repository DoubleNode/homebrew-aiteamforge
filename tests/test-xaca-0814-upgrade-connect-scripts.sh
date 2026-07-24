#!/bin/bash
# test-xaca-0814-upgrade-connect-scripts.sh
#
# XACA-0814: `aiteamforge upgrade` must regenerate per-team *-connect.sh /
# *-disconnect.sh cockpit scripts.
#
# install-team.sh --connect-only renders ${INSTANCE_ID}-connect.sh and
# ${INSTANCE_ID}-disconnect.sh into WORKING_DIR, but its ONLY call sites are
# bin/aiteamforge-setup.sh's cockpit-mode pass and its full-mode "render
# remaining teams" pass — both reached only from `aiteamforge setup`, NEVER
# from `aiteamforge upgrade`. So when XACA-0785 fixed a defect in the connect-
# script generator itself, every machine that had ALREADY installed under the
# broken generator never received the fix, even after upgrading — `aiteamforge
# upgrade` bumped every other component and left the stale connect/disconnect
# scripts untouched forever. XACA-0814 adds update_connect_scripts() to
# aiteamforge-upgrade.sh's run sequence, delegating to install-team.sh
# --connect-only (same idiom install-team.sh's CONNECT-ONLY EARLY EXIT block
# is designed for) so INSTANCE_ID computation is never duplicated here.
#
# Same bug class as XACA-0608 / XACA-0673 / XACA-0751 / XACA-0771 (K113:
# "install path grows a step, upgrade path never learns about it") — this is
# the 5th sighting.
#
# Assertions in this suite:
#   S1  STRUCTURAL: update_connect_scripts() is DEFINED in aiteamforge-upgrade.sh
#   S2  STRUCTURAL: update_connect_scripts is CALLED (bare line) in the run
#       sequence — the assertion that would have caught the original bug.
#   S3  STRUCTURAL: update_connect_scripts is registered AFTER update_team_scripts
#       (both are per-team script refreshers; keeping them adjacent is intentional).
#   F1  REFRESH-EXISTING: a team whose connect/disconnect scripts already exist
#       on this machine gets them re-rendered (installer invoked, content changes).
#   F2  SKIP-ABSENT: a team whose connect script was never rendered on this
#       machine (never installed / opted out) is NOT materialized on upgrade.
#   F3  DRY-RUN: DRY_RUN=true does not invoke the installer and does not change
#       an existing connect script's content.
#   F4  MISSING-TEAMS-DIR: FRAMEWORK_DIR/share/teams absent -> fail-soft warning,
#       function returns 0, installer never invoked.
#   F5  MISSING-INSTALLER: install-team.sh absent -> fail-soft warning, function
#       returns 0, no crash.
#   F6  PROJECT-AUGMENTED-INSTANCE-ID: the refresh-only guard's glob
#       "${team_id}*-connect.sh" matches an XACA-0485 project-augmented instance
#       id (e.g. finance -> finance-personal-connect.sh), not just the bare id.
#   F7  INSTALLER-FAILURE-IS-FAIL-SOFT: a non-zero exit from install-team.sh for
#       one team is caught, warned about, and does not abort update_connect_scripts
#       or the calling shell (upgrade must survive one bad team).
#
# All filesystem activity is sandboxed under TEST_TMP_DIR with a STUBBED
# install-team.sh (a real install-team.sh render is exercised by manual/
# integration testing, not this unit suite) — never touches real $HOME/
# aiteamforge or the real share/teams directory's install-team.sh invocation.
#
# Runs standalone (`bash tests/test-xaca-0814-upgrade-connect-scripts.sh`) OR
# via test-runner.sh. Exit 0 = all pass, exit 1 = any fail.

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
    TEST_TMP_DIR="$(mktemp -d -t xaca0814-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true; fi; }
trap cleanup EXIT

WORK_DIR="$TEST_TMP_DIR/xaca0814"
mkdir -p "$WORK_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# S1 / S2 / S3 — STRUCTURAL assertions against the real, unmodified file.
# These are the assertions that would have caught the original bug: a defined-
# but-never-called function means existing fleet machines never receive the
# connect-script refresh on upgrade (mirrors the XACA-0751/XACA-0771 "would
# have caught it" guard tests).
# ═══════════════════════════════════════════════════════════════════════════
test_start "S1: update_connect_scripts() is defined in aiteamforge-upgrade.sh"
if grep -qE '^update_connect_scripts\(\) \{' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "no 'update_connect_scripts() {' definition found in $UPGRADE_SH"
fi

test_start "S2: update_connect_scripts is invoked (bare call) in the upgrade run sequence"
if grep -qE '^update_connect_scripts$' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "aiteamforge-upgrade.sh run sequence must call update_connect_scripts (bare line) — a defined-but-never-called function means EXISTING fleet machines never receive the connect/disconnect script refresh on upgrade (XACA-0814)"
fi

test_start "S3: update_connect_scripts is registered after update_team_scripts in the run sequence"
_TEAM_SCRIPTS_LINE="$(grep -nE '^update_team_scripts$' "$UPGRADE_SH" | head -1 | cut -d: -f1)"
_CONNECT_SCRIPTS_LINE="$(grep -nE '^update_connect_scripts$' "$UPGRADE_SH" | head -1 | cut -d: -f1)"
if [ -n "$_TEAM_SCRIPTS_LINE" ] && [ -n "$_CONNECT_SCRIPTS_LINE" ] \
    && [ "$_CONNECT_SCRIPTS_LINE" -gt "$_TEAM_SCRIPTS_LINE" ]; then
    test_pass
else
    test_fail "expected update_connect_scripts (line ${_CONNECT_SCRIPTS_LINE:-MISSING}) after update_team_scripts (line ${_TEAM_SCRIPTS_LINE:-MISSING}) in the run sequence"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Extract update_connect_scripts() from aiteamforge-upgrade.sh (do NOT source
# the whole script — its main body has side effects: is_configured,
# get_framework_dir, brew checks, the upgrade itself).
#
# XACA-0834 UPDATE: update_connect_scripts() now calls a second helper,
# _connect_script_team_flags(), to read TEAM_HAS_PROJECTS/
# TEAM_REQUIRES_CLIENT_ID from the matched conf. That helper must be
# extracted and sourced too — without it, every call silently resolves to
# "command not found" inside a `$( ... )` substitution, which yields an
# empty $flags and therefore an always-false has_projects/requires_client
# regardless of what a fixture's conf actually says (this bit F6 below: the
# fixture's own conf content was correct, but the helper it depends on was
# never sourced, so it had no effect either way).
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$UPGRADE_SH"
}

FLAGS_FN_SRC="$WORK_DIR/connect_script_team_flags.extracted.sh"
UPD_FN_SRC="$WORK_DIR/update_connect_scripts.extracted.sh"
_extract_fn _connect_script_team_flags > "$FLAGS_FN_SRC"
_extract_fn update_connect_scripts > "$UPD_FN_SRC"

if [ ! -s "$UPD_FN_SRC" ]; then
    echo "FATAL: could not extract update_connect_scripts from $UPGRADE_SH" >&2
    if [ "$_STANDALONE" = true ]; then
        echo ""
        echo "XACA-0814 upgrade-connect-scripts tests: ${_PASS_COUNT} passed, $((_FAIL_COUNT + 1)) failed"
    fi
    exit 1
fi
# _connect_script_team_flags is a XACA-0834 addition; tolerate its absence on
# an older checkout (pre-0834) so this suite still runs against history, but
# warn loudly since every functional case below now implicitly depends on it.
if [ ! -s "$FLAGS_FN_SRC" ]; then
    echo "WARNING: _connect_script_team_flags not found in $UPGRADE_SH — functional tests below may behave as pre-XACA-0834" >&2
fi

# print_* stubs that ALSO record output so functional tests can grep for
# specific message text (mirrors test-xaca-0771's printf-based stubs).
_STUB_LOG="$WORK_DIR/stub-output.log"
_install_print_stubs() {
    : > "$_STUB_LOG"
    for _p in print_section print_info print_success print_warning print_error; do
        eval "${_p}() { printf '%s\n' \"\$*\" >> \"\$_STUB_LOG\"; }"
    done
}
_install_print_stubs

# shellcheck disable=SC1090
[ -s "$FLAGS_FN_SRC" ] && source "$FLAGS_FN_SRC"
# shellcheck disable=SC1090
source "$UPD_FN_SRC"
declare -f update_connect_scripts >/dev/null || { echo "FATAL: update_connect_scripts not defined after extraction"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Stubbed install-team.sh --connect-only. Records every invocation's team id
# to STUB_CALL_LOG so tests can assert whether the installer was invoked
# (skip-guard behavior) without depending on the real, heavy install-team.sh.
# Honors STUB_INSTANCE_ID (models XACA-0485 project-augmented instance ids)
# and STUB_FAIL (models a single team's render failing).
# ─────────────────────────────────────────────────────────────────────────────
STUB_LIBEXEC="$WORK_DIR/stub-libexec"
mkdir -p "$STUB_LIBEXEC/installers"
STUB_INSTALLER="$STUB_LIBEXEC/installers/install-team.sh"
cat > "$STUB_INSTALLER" <<'STUB'
#!/bin/bash
set -eu
TEAM="$1"; shift
CONNECT_ONLY=false
INSTALL_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --connect-only) CONNECT_ONLY=true; shift ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done
: "${STUB_CALL_LOG:?STUB_CALL_LOG must be set}"
echo "$TEAM" >> "$STUB_CALL_LOG"
if [ "$CONNECT_ONLY" != "true" ]; then
    echo "stub install-team.sh: only --connect-only is supported by this stub" >&2
    exit 1
fi
if [ "${STUB_FAIL:-false}" = "true" ]; then
    echo "stub install-team.sh: simulated failure for $TEAM" >&2
    exit 1
fi
INSTANCE_ID="${STUB_INSTANCE_ID:-$TEAM}"
mkdir -p "$INSTALL_DIR"
echo "connect-rendered-for-${INSTANCE_ID}-$$" > "${INSTALL_DIR}/${INSTANCE_ID}-connect.sh"
echo "disconnect-rendered-for-${INSTANCE_ID}-$$" > "${INSTALL_DIR}/${INSTANCE_ID}-disconnect.sh"
chmod +x "${INSTALL_DIR}/${INSTANCE_ID}-connect.sh" "${INSTALL_DIR}/${INSTANCE_ID}-disconnect.sh"
echo "stub install-team.sh: rendered ${INSTANCE_ID} connect/disconnect scripts"
exit 0
STUB
chmod +x "$STUB_INSTALLER"

_next_sandbox() { mktemp -d "$WORK_DIR/sbx-XXXXXX"; }

# ═══════════════════════════════════════════════════════════════════════════
# F1 — REFRESH-EXISTING: an already-rendered team's connect/disconnect scripts
# are re-rendered by the installer.
# ═══════════════════════════════════════════════════════════════════════════
test_start "F1: existing academy-connect.sh is refreshed (installer invoked, content changes)"
F1_FRAMEWORK="$(_next_sandbox)"
F1_WORKING="$(_next_sandbox)"
mkdir -p "$F1_FRAMEWORK/share/teams"
: > "$F1_FRAMEWORK/share/teams/academy.conf"
echo "stale-pre-upgrade-connect-content" > "$F1_WORKING/academy-connect.sh"
echo "stale-pre-upgrade-disconnect-content" > "$F1_WORKING/academy-disconnect.sh"
F1_BEFORE="$(cat "$F1_WORKING/academy-connect.sh")"

if [[ "$F1_BEFORE" != "stale-pre-upgrade-connect-content" ]]; then
    test_fail "PRECONDITION FAILED: stale marker not seeded correctly"
else
    _install_print_stubs
    F1_CALL_LOG="$WORK_DIR/f1-calls.txt"; : > "$F1_CALL_LOG"
    STUB_CALL_LOG="$F1_CALL_LOG" STUB_INSTANCE_ID="" STUB_FAIL=false \
    FRAMEWORK_DIR="$F1_FRAMEWORK" WORKING_DIR="$F1_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=false \
        update_connect_scripts >/dev/null 2>&1
    F1_AFTER="$(cat "$F1_WORKING/academy-connect.sh" 2>/dev/null)"
    if grep -q "^academy$" "$F1_CALL_LOG" \
        && [ "$F1_AFTER" != "$F1_BEFORE" ] \
        && [[ "$F1_AFTER" == connect-rendered-for-academy-* ]] \
        && [ -f "$F1_WORKING/academy-disconnect.sh" ]; then
        test_pass
    else
        test_fail "expected installer invoked for academy + content refreshed; call_log=$(cat "$F1_CALL_LOG"); after=$F1_AFTER"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# F2 — SKIP-ABSENT: a team whose connect script was never rendered on this
# machine must NOT be materialized on upgrade.
# ═══════════════════════════════════════════════════════════════════════════
test_start "F2: a team with no existing connect script is skipped (not materialized)"
F2_FRAMEWORK="$(_next_sandbox)"
F2_WORKING="$(_next_sandbox)"
mkdir -p "$F2_FRAMEWORK/share/teams"
: > "$F2_FRAMEWORK/share/teams/ios.conf"
# Deliberately do NOT seed ios-connect.sh in F2_WORKING.

if [ -f "$F2_WORKING/ios-connect.sh" ]; then
    test_fail "PRECONDITION FAILED: ios-connect.sh unexpectedly present in F2 sandbox"
else
    _install_print_stubs
    F2_CALL_LOG="$WORK_DIR/f2-calls.txt"; : > "$F2_CALL_LOG"
    STUB_CALL_LOG="$F2_CALL_LOG" STUB_INSTANCE_ID="" STUB_FAIL=false \
    FRAMEWORK_DIR="$F2_FRAMEWORK" WORKING_DIR="$F2_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=false \
        update_connect_scripts >/dev/null 2>&1
    if [ ! -s "$F2_CALL_LOG" ] && [ ! -f "$F2_WORKING/ios-connect.sh" ]; then
        test_pass
    else
        test_fail "installer must NOT be invoked for a never-installed team; call_log=$(cat "$F2_CALL_LOG" 2>/dev/null); ios-connect.sh exists=$([ -f "$F2_WORKING/ios-connect.sh" ] && echo yes || echo no)"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# F3 — DRY-RUN: DRY_RUN=true must not invoke the installer or change content.
# ═══════════════════════════════════════════════════════════════════════════
test_start "F3: DRY_RUN=true does not invoke the installer or change existing content"
F3_FRAMEWORK="$(_next_sandbox)"
F3_WORKING="$(_next_sandbox)"
mkdir -p "$F3_FRAMEWORK/share/teams"
: > "$F3_FRAMEWORK/share/teams/academy.conf"
echo "unchanged-dry-run-content" > "$F3_WORKING/academy-connect.sh"

_install_print_stubs
F3_CALL_LOG="$WORK_DIR/f3-calls.txt"; : > "$F3_CALL_LOG"
STUB_CALL_LOG="$F3_CALL_LOG" STUB_INSTANCE_ID="" STUB_FAIL=false \
FRAMEWORK_DIR="$F3_FRAMEWORK" WORKING_DIR="$F3_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=true \
    update_connect_scripts >/dev/null 2>&1
F3_AFTER="$(cat "$F3_WORKING/academy-connect.sh")"
if [ ! -s "$F3_CALL_LOG" ] && [ "$F3_AFTER" = "unchanged-dry-run-content" ] \
    && grep -qi "would refresh" "$_STUB_LOG"; then
    test_pass
else
    test_fail "DRY_RUN=true must not invoke installer or change content; call_log=$(cat "$F3_CALL_LOG" 2>/dev/null); after=$F3_AFTER; stub_log=$(cat "$_STUB_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# F4 — MISSING-TEAMS-DIR: fail-soft warning, return 0, installer never invoked.
# ═══════════════════════════════════════════════════════════════════════════
test_start "F4: missing share/teams dir is fail-soft (warns, returns 0, no installer call)"
F4_FRAMEWORK="$(_next_sandbox)"   # share/teams deliberately absent
F4_WORKING="$(_next_sandbox)"

_install_print_stubs
F4_CALL_LOG="$WORK_DIR/f4-calls.txt"; : > "$F4_CALL_LOG"
F4_RC=0
STUB_CALL_LOG="$F4_CALL_LOG" STUB_INSTANCE_ID="" STUB_FAIL=false \
FRAMEWORK_DIR="$F4_FRAMEWORK" WORKING_DIR="$F4_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=false \
    update_connect_scripts >/dev/null 2>&1 || F4_RC=$?
if [ "$F4_RC" = "0" ] && [ ! -s "$F4_CALL_LOG" ] && grep -qi "not found" "$_STUB_LOG"; then
    test_pass
else
    test_fail "rc=$F4_RC call_log=$(cat "$F4_CALL_LOG" 2>/dev/null); stub_log=$(cat "$_STUB_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# F5 — MISSING-INSTALLER: install-team.sh absent -> fail-soft, no crash.
# ═══════════════════════════════════════════════════════════════════════════
test_start "F5: missing install-team.sh is fail-soft (warns, returns 0, no crash)"
F5_FRAMEWORK="$(_next_sandbox)"
F5_WORKING="$(_next_sandbox)"
mkdir -p "$F5_FRAMEWORK/share/teams"
: > "$F5_FRAMEWORK/share/teams/academy.conf"
F5_BAD_LIBEXEC="$WORK_DIR/no-such-libexec"

_install_print_stubs
F5_RC=0
FRAMEWORK_DIR="$F5_FRAMEWORK" WORKING_DIR="$F5_WORKING" LIBEXEC_DIR="$F5_BAD_LIBEXEC" DRY_RUN=false \
    update_connect_scripts >/dev/null 2>&1 || F5_RC=$?
if [ "$F5_RC" = "0" ] && grep -qi "not found" "$_STUB_LOG"; then
    test_pass
else
    test_fail "rc=$F5_RC; stub_log=$(cat "$_STUB_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# F6 — PROJECT-AUGMENTED-INSTANCE-ID: the refresh-only guard's glob must match
# an XACA-0485 project-augmented instance id (e.g. finance -> finance-personal),
# not just the bare team id.
#
# XACA-0834 UPDATE: update_connect_scripts() was rewritten (file-iteration +
# anchored-shape recovery, replacing the conf-iteration + unanchored-glob
# design this test was originally written against — see
# test-xaca-0834-connect-script-recovery.sh for the dedicated regression
# suite covering that rewrite in depth). The rewrite reads TEAM_HAS_PROJECTS
# from the conf to decide how to split a recovered instance id, so this
# fixture's conf must now carry real values — an EMPTY conf (the original
# fixture) defaults to TEAM_HAS_PROJECTS=false, which makes the new code
# correctly SKIP a "finance-personal" instance ("template takes no
# parameters") instead of refreshing it, breaking this assertion for a
# reason that has nothing to do with the property F6 exists to guard. Fixed
# by giving finance.conf the same TEAM_HAS_PROJECTS=true /
# TEAM_REQUIRES_CLIENT_ID=false shape the real share/teams/finance.conf
# ships (this test's stub ignores --client/--project — it renders whatever
# STUB_INSTANCE_ID says regardless — so only the has_projects gate needed
# fixing for this fixture to reach the installer call again).
# ═══════════════════════════════════════════════════════════════════════════
test_start "F6: refresh-only guard matches a project-augmented instance id (finance -> finance-personal)"
F6_FRAMEWORK="$(_next_sandbox)"
F6_WORKING="$(_next_sandbox)"
mkdir -p "$F6_FRAMEWORK/share/teams"
cat > "$F6_FRAMEWORK/share/teams/finance.conf" <<'CONF'
TEAM_ID="finance"
TEAM_HAS_PROJECTS="true"
TEAM_REQUIRES_CLIENT_ID="false"
TEAM_DEFAULT_PROJECT="personal"
CONF
echo "stale-instance-augmented-connect" > "$F6_WORKING/finance-personal-connect.sh"
echo "stale-instance-augmented-disconnect" > "$F6_WORKING/finance-personal-disconnect.sh"

_install_print_stubs
F6_CALL_LOG="$WORK_DIR/f6-calls.txt"; : > "$F6_CALL_LOG"
STUB_CALL_LOG="$F6_CALL_LOG" STUB_INSTANCE_ID="finance-personal" STUB_FAIL=false \
FRAMEWORK_DIR="$F6_FRAMEWORK" WORKING_DIR="$F6_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=false \
    update_connect_scripts >/dev/null 2>&1
F6_AFTER="$(cat "$F6_WORKING/finance-personal-connect.sh" 2>/dev/null)"
if grep -q "^finance$" "$F6_CALL_LOG" \
    && [[ "$F6_AFTER" == connect-rendered-for-finance-personal-* ]]; then
    test_pass
else
    test_fail "expected installer invoked for base id 'finance' + finance-personal-connect.sh refreshed; call_log=$(cat "$F6_CALL_LOG" 2>/dev/null); after=$F6_AFTER"
fi

# ═══════════════════════════════════════════════════════════════════════════
# F7 — INSTALLER-FAILURE-IS-FAIL-SOFT: one team's render failing must not abort
# update_connect_scripts or the calling shell.
# ═══════════════════════════════════════════════════════════════════════════
test_start "F7: an installer failure for one team is fail-soft (warns, function still returns 0)"
F7_FRAMEWORK="$(_next_sandbox)"
F7_WORKING="$(_next_sandbox)"
mkdir -p "$F7_FRAMEWORK/share/teams"
: > "$F7_FRAMEWORK/share/teams/academy.conf"
echo "pre-existing-connect-content" > "$F7_WORKING/academy-connect.sh"

_install_print_stubs
F7_CALL_LOG="$WORK_DIR/f7-calls.txt"; : > "$F7_CALL_LOG"
F7_RC=0
(
    set -eo pipefail   # upgrade.sh's exact options — deliberately WITHOUT -u
    STUB_CALL_LOG="$F7_CALL_LOG" STUB_INSTANCE_ID="" STUB_FAIL=true \
    FRAMEWORK_DIR="$F7_FRAMEWORK" WORKING_DIR="$F7_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=false \
        update_connect_scripts
    echo "CALLING_SHELL_SURVIVED"
) >"$WORK_DIR/f7-stdout.log" 2>&1 || F7_RC=$?
if [ "$F7_RC" = "0" ] && grep -q "CALLING_SHELL_SURVIVED" "$WORK_DIR/f7-stdout.log" \
    && grep -qi "failed to refresh" "$_STUB_LOG"; then
    test_pass
else
    test_fail "rc=$F7_RC; stdout=$(cat "$WORK_DIR/f7-stdout.log"); stub_log=$(cat "$_STUB_LOG")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone only; test-runner.sh owns totals when sourced by it).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "XACA-0814 upgrade-connect-scripts tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
