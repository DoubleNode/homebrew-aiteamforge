#!/bin/bash

# test-xaca-0651-consumer-doctor-gaps.sh
# Regression tests for XACA-0651: three consumer-side doctor/installer gaps.
#
# Fix 1 — aiteamforge-doctor.sh check_launchagents(): LCARS health-script-present
#   check uses ${working_dir}/lcars-health-check.sh (via get_working_dir()) instead
#   of bare ${AITEAMFORGE_DIR}/lcars-health-check.sh.
#   Root cause: AITEAMFORGE_DIR is unset in the doctor context on consumers,
#   which collapsed the path to /lcars-health-check.sh (root) → false FAILURE.
#
# Fix 2 — aiteamforge-doctor.sh check_git(): the else-branch (no .git present)
#   now emits print_info instead of check_result warn, so consumers see an info
#   note (not a WARNING) when their working dir has no .git (expected on tap installs).
#
# Fix 3 — install-kanban.sh install_backup_launchagent():
#   a) mkdir -p ~/aiteamforge-backups/kanban is called in the loader (log-dir fix)
#   b) empty/non-numeric KANBAN_BACKUP_INTERVAL falls back to 900 (plist guard)
#   c) launchctl load || true + launchctl list verification instead of
#      if launchctl load; then success; else warning; fi
#
# Strategy:
#   Fix 1 and Fix 2 are verified by static source-text assertions (fastest and
#   most precise — they pin the exact code change and are resilient to the doctor's
#   heavy dependency on real-system state for full execution). Behavioral assertions
#   use a minimal driver subshell modelled after test-xaca-0650-doctor-venv.sh.
#
#   Fix 3 is verified by: (1) source-text assertions for the guard and mkdir, and
#   (2) a sandboxed functional test of plist rendering with a stubbed launchctl.
#
# All filesystem activity is sandboxed to TEST_TMP_DIR.
# NEVER touches real $HOME/Library/LaunchAgents — M3Pro install-ban rule.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCTOR_CMD="$TAP_ROOT/libexec/commands/aiteamforge-doctor.sh"
INSTALLER="$TAP_ROOT/libexec/installers/install-kanban.sh"

# ── Standalone framework (mirrors test-xaca-0585 pattern) ────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""

    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }

    assert_file_exists() {
        local file="$1" msg="${2:-Expected file to exist: $1}"
        [ -f "$file" ] || { test_fail "$msg"; return 1; }
    }
    assert_file_not_exists() {
        local file="$1" msg="${2:-Expected file to not exist: $1}"
        [ ! -f "$file" ] || { test_fail "$msg"; return 1; }
    }
    assert_dir_exists() {
        local dir="$1" msg="${2:-Expected directory to exist: $1}"
        [ -d "$dir" ] || { test_fail "$msg"; return 1; }
    }
    assert_contains() {
        local haystack="$1" needle="$2" msg="${3:-Expected to find '$2' in output}"
        [[ "$haystack" == *"$needle"* ]] || { test_fail "$msg"; return 1; }
    }
    assert_not_contains() {
        local haystack="$1" needle="$2" msg="${3:-Expected NOT to find '$2' in output}"
        [[ "$haystack" != *"$needle"* ]] || { test_fail "$msg"; return 1; }
    }
    assert_exit_success() {
        local code="$1" msg="${2:-Expected exit 0 but got $1}"
        [ "$code" -eq 0 ] || { test_fail "$msg"; return 1; }
    }
fi

# ── Temp directory ────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0651-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi

_cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap _cleanup EXIT

SANDBOX="$TEST_TMP_DIR/xaca0651"
mkdir -p "$SANDBOX"

# ════════════════════════════════════════════════════════════════════════════
# PRECONDITIONS
# ════════════════════════════════════════════════════════════════════════════

test_start "XACA-0651 precondition: doctor.sh exists"
assert_file_exists "$DOCTOR_CMD" "aiteamforge-doctor.sh not found at $DOCTOR_CMD"
test_pass

test_start "XACA-0651 precondition: install-kanban.sh exists"
assert_file_exists "$INSTALLER" "install-kanban.sh not found at $INSTALLER"
test_pass

# ════════════════════════════════════════════════════════════════════════════
# FIX 1 — check_launchagents() health-script check uses working_dir, not AITEAMFORGE_DIR
# ════════════════════════════════════════════════════════════════════════════
#
# Anti-regression: the code must NOT contain a bare ${AITEAMFORGE_DIR}/lcars-health-check.sh
# reference in check_launchagents(). If it did, the path would collapse to
# /lcars-health-check.sh when AITEAMFORGE_DIR is unset (the consumer context).

_DOCTOR_SRC="$(cat "$DOCTOR_CMD")"

test_start "Fix 1 (static): check_launchagents references \${working_dir}/lcars-health-check.sh"
assert_contains "$_DOCTOR_SRC" \
    '${working_dir}/lcars-health-check.sh' \
    "check_launchagents must reference \${working_dir}/lcars-health-check.sh (not bare \${AITEAMFORGE_DIR})"
test_pass

test_start "Fix 1 (static): check_launchagents does NOT use bare \${AITEAMFORGE_DIR}/lcars-health-check.sh"
# The check_launchagents function must not access lcars-health-check.sh via AITEAMFORGE_DIR
# directly — that path collapses to /lcars-health-check.sh on consumers where AITEAMFORGE_DIR is unset.
# We look specifically for the pattern in check_launchagents (extract it first).
_LAUNCHAGENTS_FUNC="$(awk '/^check_launchagents\(\)/,/^}$/' "$DOCTOR_CMD")"
assert_not_contains "$_LAUNCHAGENTS_FUNC" \
    '${AITEAMFORGE_DIR}/lcars-health-check.sh' \
    "check_launchagents must not reference bare \${AITEAMFORGE_DIR}/lcars-health-check.sh (collapses to / on consumers)"
test_pass

test_start "Fix 1 (static): local working_dir declared in check_launchagents"
assert_contains "$_LAUNCHAGENTS_FUNC" \
    'working_dir' \
    "check_launchagents must declare a local working_dir variable"
test_pass

test_start "Fix 1 (static): get_working_dir called in check_launchagents"
assert_contains "$_LAUNCHAGENTS_FUNC" \
    'get_working_dir' \
    "check_launchagents must call get_working_dir to resolve the working directory"
test_pass

# Behavioral: with health script present at working_dir, doctor reports PASS not FAIL.
# We use a minimal driver that stubs the doctor's heavy dependencies so the
# check_launchagents function can execute in a controlled environment.
_build_launchagents_driver() {
    local working_dir_path="$1"
    local driver_dir="$SANDBOX/fix1-driver-$$-$RANDOM"
    local libexec_dir="$driver_dir/libexec"
    local lib_dir="$libexec_dir/lib"
    mkdir -p "$lib_dir"

    # Symlink real tap lib files (same pattern as test-xaca-0650-doctor-venv.sh)
    for f in common.sh config.sh constants.sh; do
        ln -sf "$TAP_ROOT/libexec/lib/$f" "$lib_dir/$f"
    done

    # Extract check_result and check_launchagents from doctor.sh
    local check_result_src check_launchagents_src
    check_result_src="$(awk '/^check_result\(\)/,/^}$/' "$DOCTOR_CMD")"
    check_launchagents_src="$(awk '/^check_launchagents\(\)/,/^}$/' "$DOCTOR_CMD")"

    cat > "$driver_dir/driver.sh" <<DRIVER
#!/bin/bash
set -eo pipefail

LIBEXEC_DIR="${lib_dir}/.."
AITEAMFORGE_DIR=""           # intentionally unset — simulates consumer context
VERBOSE=false
FIX=false
TOTAL_CHECKS=0; PASSED_CHECKS=0; FAILED_CHECKS=0; WARNING_CHECKS=0

source "${lib_dir}/common.sh"
source "${lib_dir}/config.sh"
source "${lib_dir}/constants.sh"

# Override get_working_dir to return our controlled path
get_working_dir() { echo "${working_dir_path}"; }

# Stub launchctl so it never actually queries the system
launchctl() { return 1; }   # not loaded — so the loaded-check always warns; harmless

print_section() { :; }

${check_result_src}
${check_launchagents_src}

check_launchagents
DRIVER
    chmod +x "$driver_dir/driver.sh"
    echo "$driver_dir"
}

test_start "Fix 1 (behavioral): health-script PASS when present at working_dir path"
_CASE1_WORKING="$SANDBOX/fix1-working-present"
mkdir -p "$_CASE1_WORKING"
touch "$_CASE1_WORKING/lcars-health-check.sh"
_DRV1="$(_build_launchagents_driver "$_CASE1_WORKING")"
_OUT1="$(bash "$_DRV1/driver.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
assert_contains "$_OUT1" \
    "LCARS health check script present" \
    "Doctor must report PASS when lcars-health-check.sh exists at working_dir"
assert_not_contains "$_OUT1" \
    "/lcars-health-check.sh" \
    "FAIL message must not reference the root path /lcars-health-check.sh"
test_pass

test_start "Fix 1 (behavioral): health-script FAIL message names working_dir, not root path"
_CASE2_WORKING="$SANDBOX/fix1-working-absent"
mkdir -p "$_CASE2_WORKING"
# Deliberately NO lcars-health-check.sh in the working dir
_DRV2="$(_build_launchagents_driver "$_CASE2_WORKING")"
_OUT2="$(bash "$_DRV2/driver.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
assert_contains "$_OUT2" \
    "$_CASE2_WORKING/lcars-health-check.sh" \
    "FAIL message must name the working_dir-resolved path, not a root / path"
assert_not_contains "$_OUT2" \
    "LCARS health check script present" \
    "Doctor must NOT report PASS when script is absent"
# Anti-regression: must NOT contain the collapsed root path
assert_not_contains "$_OUT2" \
    ": /lcars-health-check.sh" \
    "FAIL message must not reference the bare /lcars-health-check.sh root path (AITEAMFORGE_DIR collapse regression)"
test_pass

# ════════════════════════════════════════════════════════════════════════════
# FIX 2 — check_git() else-branch: no warning on consumer (no .git)
# ════════════════════════════════════════════════════════════════════════════
#
# Anti-regression: the else-branch must NOT call check_result warn
# "Dev-team not a git repository". It must call print_info instead.

_GIT_FUNC="$(awk '/^check_git\(\)/,/^}$/' "$DOCTOR_CMD")"

test_start "Fix 2 (static): check_git else-branch does NOT call check_result warn for missing .git"
# The old code was: check_result warn "Dev-team not a git repository"
# This must no longer appear in the function.
assert_not_contains "$_GIT_FUNC" \
    'check_result warn "Dev-team not a git repository"' \
    "check_git else-branch must not emit check_result warn for missing .git (consumer regression)"
test_pass

test_start "Fix 2 (static): check_git else-branch calls print_info (consumer install note)"
# The fix replaces the warn with a print_info informational message.
assert_contains "$_GIT_FUNC" \
    'print_info' \
    "check_git else-branch must call print_info for the consumer (no .git) case"
test_pass

test_start "Fix 2 (static): check_git else-branch message mentions consumer install"
# The info message should indicate this is a consumer install context.
assert_contains "$_GIT_FUNC" \
    'Consumer install' \
    "check_git else-branch info message must mention 'Consumer install'"
test_pass

test_start "Fix 2 (behavioral): check_git with no .git emits no warning (WARNING_CHECKS stays 0)"
_CASE3_WORKING="$SANDBOX/fix2-consumer-working"
mkdir -p "$_CASE3_WORKING"
# No .git directory — consumer install context

_GIT_DRIVER="$SANDBOX/fix2-git-driver"
mkdir -p "$_GIT_DRIVER"
_GIT_LIBEXEC="$_GIT_DRIVER/libexec"
_GIT_LIB="$_GIT_LIBEXEC/lib"
mkdir -p "$_GIT_LIB"
for f in common.sh config.sh constants.sh; do
    ln -sf "$TAP_ROOT/libexec/lib/$f" "$_GIT_LIB/$f"
done

_CHECK_RESULT_SRC="$(awk '/^check_result\(\)/,/^}$/' "$DOCTOR_CMD")"
_CHECK_GIT_SRC="$(awk '/^check_git\(\)/,/^}$/' "$DOCTOR_CMD")"

cat > "$_GIT_DRIVER/driver.sh" <<GITDRIVER
#!/bin/bash
set -eo pipefail

LIBEXEC_DIR="${_GIT_LIB}/.."
AITEAMFORGE_DIR=""
VERBOSE=false
FIX=false
TOTAL_CHECKS=0; PASSED_CHECKS=0; FAILED_CHECKS=0; WARNING_CHECKS=0

source "${_GIT_LIB}/common.sh"
source "${_GIT_LIB}/config.sh"
source "${_GIT_LIB}/constants.sh"

get_working_dir() { echo "${_CASE3_WORKING}"; }
print_section() { :; }

${_CHECK_RESULT_SRC}
${_CHECK_GIT_SRC}

check_git
echo "WARNING_CHECKS=\${WARNING_CHECKS}"
GITDRIVER
chmod +x "$_GIT_DRIVER/driver.sh"

_GIT_OUT="$(bash "$_GIT_DRIVER/driver.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
assert_contains "$_GIT_OUT" \
    "WARNING_CHECKS=0" \
    "check_git with no .git must not increment WARNING_CHECKS (consumer should not see a warning)"
test_pass

test_start "Fix 2 (behavioral): check_git with .git present still runs clean/dirty checks"
_CASE4_WORKING="$SANDBOX/fix2-dev-working"
mkdir -p "$_CASE4_WORKING/.git"
# Seed a minimal bare git repo so git commands don't fail
git -C "$_CASE4_WORKING" init -q 2>/dev/null || true

cat > "$_GIT_DRIVER/driver-dev.sh" <<DEVDRIVER
#!/bin/bash
set -eo pipefail

LIBEXEC_DIR="${_GIT_LIB}/.."
AITEAMFORGE_DIR=""
VERBOSE=false
FIX=false
TOTAL_CHECKS=0; PASSED_CHECKS=0; FAILED_CHECKS=0; WARNING_CHECKS=0

source "${_GIT_LIB}/common.sh"
source "${_GIT_LIB}/config.sh"
source "${_GIT_LIB}/constants.sh"

get_working_dir() { echo "${_CASE4_WORKING}"; }
print_section() { :; }

${_CHECK_RESULT_SRC}
${_CHECK_GIT_SRC}

check_git
echo "PASSED_CHECKS=\${PASSED_CHECKS}"
DEVDRIVER
chmod +x "$_GIT_DRIVER/driver-dev.sh"

_DEV_OUT="$(bash "$_GIT_DRIVER/driver-dev.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
# Should pass the "Dev-team git repository" check
assert_contains "$_DEV_OUT" \
    "Dev-team git repository" \
    "check_git must still report the git repository check when .git is present"
test_pass

# ════════════════════════════════════════════════════════════════════════════
# FIX 3 — install_backup_launchagent() three sub-fixes
# ════════════════════════════════════════════════════════════════════════════

_INSTALLER_SRC="$(cat "$INSTALLER")"

# 3a. Source-text: mkdir -p ~/aiteamforge-backups/kanban present in install_backup_launchagent
_BACKUP_LAUNCHAGENT_FUNC="$(awk '/^install_backup_launchagent\(\)/,/^}$/' "$INSTALLER")"

test_start "Fix 3a (static): install_backup_launchagent contains mkdir -p aiteamforge-backups/kanban"
assert_contains "$_BACKUP_LAUNCHAGENT_FUNC" \
    'mkdir -p' \
    "install_backup_launchagent must create the log dir with mkdir -p"
assert_contains "$_BACKUP_LAUNCHAGENT_FUNC" \
    'aiteamforge-backups/kanban' \
    "install_backup_launchagent must mkdir aiteamforge-backups/kanban (log dir fix)"
test_pass

# 3b. Source-text: numeric guard for KANBAN_BACKUP_INTERVAL with 900 fallback
test_start "Fix 3b (static): numeric guard falls back to 900 when KANBAN_BACKUP_INTERVAL is empty/non-numeric"
assert_contains "$_BACKUP_LAUNCHAGENT_FUNC" \
    ':-900' \
    "install_backup_launchagent must default KANBAN_BACKUP_INTERVAL to 900"
assert_contains "$_BACKUP_LAUNCHAGENT_FUNC" \
    'backup_interval=900' \
    "install_backup_launchagent numeric guard must assign backup_interval=900 as fallback"
test_pass

# 3c. Source-text: launchctl load || true + launchctl list verification
test_start "Fix 3c (static): launchctl load uses || true (not if-then pattern)"
assert_contains "$_BACKUP_LAUNCHAGENT_FUNC" \
    'launchctl load' \
    "install_backup_launchagent must call launchctl load"
assert_contains "$_BACKUP_LAUNCHAGENT_FUNC" \
    '|| true' \
    "launchctl load must be followed by || true (tolerates non-zero even on real load)"
# Anti-regression: the old pattern was 'if launchctl load; then ... else warning; fi'
# That caused false-success on consumers because launchctl load returned 0 even when rejected.
# Verify the function now uses launchctl list for the actual registration check.
assert_contains "$_BACKUP_LAUNCHAGENT_FUNC" \
    'launchctl list' \
    "install_backup_launchagent must verify registration via launchctl list (not trust exit code)"
test_pass

# 3b (functional): rendered plist with empty KANBAN_BACKUP_INTERVAL → <integer>900</integer>
test_start "Fix 3b (functional): empty KANBAN_BACKUP_INTERVAL renders <integer>900</integer> not <integer></integer>"
_PLIST_TEMPLATE="$TAP_ROOT/share/templates/kanban/backup-plist.template"
if [ ! -f "$_PLIST_TEMPLATE" ]; then
    test_fail "backup-plist.template not found at $_PLIST_TEMPLATE — cannot render plist"
else
    _PLIST_OUT="$SANDBOX/rendered-backup.plist"
    # Replicate exactly what install_backup_launchagent does: guard then sed substitution
    _backup_interval=""
    case "$_backup_interval" in
        ''|*[!0-9]*) _backup_interval=900 ;;
    esac
    _fake_home="$SANDBOX/fake-home"
    _fake_atf_dir="$SANDBOX/fake-aiteamforge"
    _fake_python="/usr/bin/python3"
    mkdir -p "$_fake_home" "$_fake_atf_dir"
    sed -e "s|{{USER_HOME}}|${_fake_home}|g" \
        -e "s|{{AITEAMFORGE_DIR}}|${_fake_atf_dir}|g" \
        -e "s|{{BACKUP_INTERVAL}}|${_backup_interval}|g" \
        -e "s|{{PYTHON3_PATH}}|${_fake_python}|g" \
        "$_PLIST_TEMPLATE" > "$_PLIST_OUT"

    _PLIST_CONTENT="$(cat "$_PLIST_OUT")"
    assert_contains "$_PLIST_CONTENT" \
        "<integer>900</integer>" \
        "Rendered plist must contain <integer>900</integer> when KANBAN_BACKUP_INTERVAL is empty"
    assert_not_contains "$_PLIST_CONTENT" \
        "<integer></integer>" \
        "Rendered plist must NOT contain <integer></integer> (empty interval — invalid plist)"
    # Validate with plutil if available
    if command -v plutil >/dev/null 2>&1; then
        plutil -lint "$_PLIST_OUT" >/dev/null 2>&1
        assert_exit_success $? "plutil -lint must pass on rendered plist with fallback interval"
    fi
    test_pass
fi

test_start "Fix 3b (functional): non-numeric KANBAN_BACKUP_INTERVAL renders <integer>900</integer>"
_PLIST_OUT2="$SANDBOX/rendered-backup-nonnumeric.plist"
_backup_interval="not-a-number"
case "$_backup_interval" in
    ''|*[!0-9]*) _backup_interval=900 ;;
esac
sed -e "s|{{USER_HOME}}|${_fake_home}|g" \
    -e "s|{{AITEAMFORGE_DIR}}|${_fake_atf_dir}|g" \
    -e "s|{{BACKUP_INTERVAL}}|${_backup_interval}|g" \
    -e "s|{{PYTHON3_PATH}}|${_fake_python}|g" \
    "$_PLIST_TEMPLATE" > "$_PLIST_OUT2"

_PLIST_CONTENT2="$(cat "$_PLIST_OUT2")"
assert_contains "$_PLIST_CONTENT2" \
    "<integer>900</integer>" \
    "Rendered plist must fall back to 900 for non-numeric KANBAN_BACKUP_INTERVAL"
assert_not_contains "$_PLIST_CONTENT2" \
    "not-a-number" \
    "Non-numeric interval must not appear in rendered plist"
test_pass

test_start "Fix 3b (functional): valid numeric KANBAN_BACKUP_INTERVAL is preserved in plist"
_PLIST_OUT3="$SANDBOX/rendered-backup-valid.plist"
_backup_interval="1800"
case "$_backup_interval" in
    ''|*[!0-9]*) _backup_interval=900 ;;
esac
sed -e "s|{{USER_HOME}}|${_fake_home}|g" \
    -e "s|{{AITEAMFORGE_DIR}}|${_fake_atf_dir}|g" \
    -e "s|{{BACKUP_INTERVAL}}|${_backup_interval}|g" \
    -e "s|{{PYTHON3_PATH}}|${_fake_python}|g" \
    "$_PLIST_TEMPLATE" > "$_PLIST_OUT3"

_PLIST_CONTENT3="$(cat "$_PLIST_OUT3")"
assert_contains "$_PLIST_CONTENT3" \
    "<integer>1800</integer>" \
    "Valid numeric interval 1800 must be preserved in rendered plist"
test_pass

# 3 (functional): sandboxed install_backup_launchagent run with stubbed launchctl
# Verify: log dir is created, plist is rendered at target path with valid content.
test_start "Fix 3 (functional): install_backup_launchagent creates log dir and renders plist (sandboxed)"
_SBX_HOME="$SANDBOX/install-home"
_SBX_ATF="$SANDBOX/install-aiteamforge"
_SBX_LAUNCH_AGENTS="$_SBX_HOME/Library/LaunchAgents"
mkdir -p "$_SBX_HOME" "$_SBX_ATF" "$_SBX_LAUNCH_AGENTS"

_INSTALL_RESULT="$(
    (
        export HOME="$_SBX_HOME"
        export AITEAMFORGE_DIR="$_SBX_ATF"
        export INSTALL_ROOT="$TAP_ROOT"
        export AITEAMFORGE_HOME="$TAP_ROOT"
        export TEAM_WORKING_DIRS_STR=""
        export KANBAN_BACKUP_INTERVAL=""         # empty → should fall back to 900
        export AITEAMFORGE_ALLOW_DEV_OVERWRITE=1

        # Stub launchctl: record calls but do not touch real launchd
        launchctl() {
            _LAUNCHCTL_CALLS="${_LAUNCHCTL_CALLS:-}|${*}"
            # Simulate 'list' reporting the label as registered (success path)
            if [ "${1:-}" = "list" ]; then
                echo "com.aiteamforge.kanban-backup"
            fi
            return 0
        }
        export -f launchctl

        source "$INSTALLER" >/dev/null 2>&1
        install_backup_launchagent 2>&1
    )
)"
_PLIST_PATH="$_SBX_LAUNCH_AGENTS/com.aiteamforge.kanban-backup.plist"
_LOG_DIR="$_SBX_HOME/aiteamforge-backups/kanban"

assert_file_exists "$_PLIST_PATH" \
    "install_backup_launchagent must render plist at ~/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist"
assert_dir_exists "$_LOG_DIR" \
    "install_backup_launchagent must mkdir -p ~/aiteamforge-backups/kanban (log dir)"

# Verify rendered plist has no placeholders and valid interval
_RENDERED="$(cat "$_PLIST_PATH")"
assert_not_contains "$_RENDERED" "{{BACKUP_INTERVAL}}" \
    "Rendered plist must not contain {{BACKUP_INTERVAL}} placeholder"
assert_contains "$_RENDERED" "<integer>900</integer>" \
    "Rendered plist must have <integer>900</integer> when KANBAN_BACKUP_INTERVAL is empty"
assert_not_contains "$_RENDERED" "<integer></integer>" \
    "Rendered plist must not have empty <integer></integer> (malformed plist)"

if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$_PLIST_PATH" >/dev/null 2>&1
    assert_exit_success $? "plutil -lint must pass on sandboxed-rendered plist"
fi
test_pass

# ════════════════════════════════════════════════════════════════════════════
# Summary (standalone mode only)
# ════════════════════════════════════════════════════════════════════════════
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    if [ "$_FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
fi
exit 0
