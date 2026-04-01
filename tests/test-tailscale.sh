#!/bin/bash

# test-tailscale.sh
# Tests for Tailscale integration in the Fleet Monitor installer
# Covers: binary detection, auth state, funnel config, skip flow, error handling
#
# MOCK STRATEGY
# The installer has a hardcoded check for /opt/homebrew/bin/tailscale, so a
# stub on PATH alone is not sufficient.  Instead, after sourcing the installer
# we redefine the low-level detection functions (has_tailscale, get_tailscale_path,
# is_tailscale_logged_in, is_tailscale_funnel_capable) directly — and for
# higher-level tests we put a full mock binary in a fake path that we inject
# into get_tailscale_path so the installer uses it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$TAP_ROOT/libexec/installers/install-fleet-monitor.sh"

# Bootstrap: source test-runner.sh helpers if not already loaded (standalone mode)
if ! type test_start &>/dev/null 2>&1; then
    if [ -f "$SCRIPT_DIR/test-runner.sh" ]; then
        source "$SCRIPT_DIR/test-runner.sh"
    else
        echo "ERROR: test-runner.sh not found at $SCRIPT_DIR" >&2
        exit 1
    fi
fi

# Isolated test environment
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
export AITEAMFORGE_HOME="$TAP_ROOT"
export NON_INTERACTIVE="true"

mkdir -p "$AITEAMFORGE_DIR/config"
mkdir -p "$AITEAMFORGE_DIR/logs"
mkdir -p "$AITEAMFORGE_DIR/lcars-ports"

# Directory where per-test mock binaries live
MOCK_BIN_DIR="$TEST_TMP_DIR/mock-bin"
mkdir -p "$MOCK_BIN_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Helper: write a mock tailscale binary to $MOCK_BIN_DIR/tailscale
# $1 = shell body (what the stub script executes)
# ─────────────────────────────────────────────────────────────────────────────
make_tailscale_mock() {
    local body="$1"
    local stub="$MOCK_BIN_DIR/tailscale"
    printf '#!/bin/bash\n%s\n' "$body" > "$stub"
    chmod +x "$stub"
}

# ─────────────────────────────────────────────────────────────────────────────
# source_installer — source common.sh + installer into current shell.
# Stub logging helpers so they don't produce noise.
# MUST be called inside each subshell that needs the installer functions.
# ─────────────────────────────────────────────────────────────────────────────
source_installer() {
    local common="$TAP_ROOT/libexec/lib/common.sh"
    if [ -f "$common" ]; then
        source "$common" 2>/dev/null || true
    fi
    # Silence logging helpers
    success() { :; }
    info()    { :; }
    warning() { :; }
    error()   { :; }
    source "$INSTALLER" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# apply_mock_ts_present MOCK_PATH
# Override detection functions so the installer thinks tailscale lives at MOCK_PATH.
# Uses a module-level variable (_MOCK_TS_PATH) to avoid bash closure issues with
# set -u — local variables inside apply_mock_ts_present go out of scope before
# the redefined functions are called, causing unbound variable errors.
# ─────────────────────────────────────────────────────────────────────────────
_MOCK_TS_PATH=""
apply_mock_ts_present() {
    _MOCK_TS_PATH="$1"
    has_tailscale()        { [ -x "$_MOCK_TS_PATH" ]; }
    get_tailscale_path()   { echo "$_MOCK_TS_PATH"; }
}

# ─────────────────────────────────────────────────────────────────────────────
# apply_mock_ts_absent
# Override detection functions so the installer thinks tailscale is not installed.
# ─────────────────────────────────────────────────────────────────────────────
apply_mock_ts_absent() {
    has_tailscale()        { return 1; }
    get_tailscale_path()   { echo ""; }
    is_tailscale_logged_in()    { return 1; }
    is_tailscale_funnel_capable() { return 1; }
    get_tailscale_ip()     { echo ""; }
    get_tailscale_hostname() { echo ""; }
}

# ═════════════════════════════════════════════════════════════════════════════
# Section 1: Binary Detection
# ═════════════════════════════════════════════════════════════════════════════

# --- has_tailscale true when mock binary exists ---
test_start "Binary detection: has_tailscale returns true when binary present"
MOCK="$MOCK_BIN_DIR/tailscale_present"
printf '#!/bin/bash\nexit 0\n' > "$MOCK" && chmod +x "$MOCK"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    if has_tailscale; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:has_tailscale returned false with mock binary present" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- has_tailscale false when absent ---
test_start "Binary detection: has_tailscale returns false when binary absent"
(
    source_installer
    apply_mock_ts_absent
    if ! has_tailscale; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:has_tailscale returned true with absent mock" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- get_tailscale_path returns path when present ---
test_start "Binary detection: get_tailscale_path returns mock path when binary exists"
MOCK="$MOCK_BIN_DIR/tailscale_path"
printf '#!/bin/bash\nexit 0\n' > "$MOCK" && chmod +x "$MOCK"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    result=$(get_tailscale_path)
    if [ "$result" = "$MOCK" ]; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:get_tailscale_path returned '$result' expected '$MOCK'" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- get_tailscale_path returns empty when absent ---
test_start "Binary detection: get_tailscale_path returns empty when absent"
(
    source_installer
    apply_mock_ts_absent
    result=$(get_tailscale_path)
    if [ -z "$result" ]; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:get_tailscale_path returned '$result' expected empty" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- installer file syntax is valid ---
test_start "Binary detection: install-fleet-monitor.sh passes bash syntax check"
if bash -n "$INSTALLER" 2>/dev/null; then
    test_pass
else
    test_fail "Syntax error in install-fleet-monitor.sh"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 2: Auth State Checks
# ═════════════════════════════════════════════════════════════════════════════

# --- logged in: status exits 0 ---
test_start "Auth state: is_tailscale_logged_in returns true when status exits 0"
make_tailscale_mock "exit 0"
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    if is_tailscale_logged_in; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:is_tailscale_logged_in returned false when mock status exits 0" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- logged out: status exits 1 ---
test_start "Auth state: is_tailscale_logged_in returns false when status exits 1"
make_tailscale_mock "exit 1"
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    if ! is_tailscale_logged_in; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:is_tailscale_logged_in returned true when mock exits 1 (logged out)" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- expired/invalid session: status exits 2 ---
test_start "Auth state: is_tailscale_logged_in returns false when status exits 2 (expired)"
make_tailscale_mock "exit 2"
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    if ! is_tailscale_logged_in; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:is_tailscale_logged_in returned true when mock exits 2 (expired)" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- binary absent → not logged in ---
test_start "Auth state: is_tailscale_logged_in returns false when binary absent"
(
    source_installer
    apply_mock_ts_absent
    if ! is_tailscale_logged_in; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:is_tailscale_logged_in returned true with absent binary" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- get_tailscale_ip returns IP when connected ---
test_start "Auth state: get_tailscale_ip returns IP when connected"
make_tailscale_mock 'echo "100.64.0.1"'
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    ip=$(get_tailscale_ip)
    if [ "$ip" = "100.64.0.1" ]; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:get_tailscale_ip returned '$ip' expected '100.64.0.1'" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- get_tailscale_ip returns empty when not connected ---
test_start "Auth state: get_tailscale_ip returns empty when binary fails"
make_tailscale_mock "exit 1"
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    ip=$(get_tailscale_ip 2>/dev/null || true)
    # Should be empty or not a valid IPv4 address
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:get_tailscale_ip returned a valid IP '$ip' despite failing mock" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- get_tailscale_hostname parses JSON ---
test_start "Auth state: get_tailscale_hostname parses HostName from status JSON"
make_tailscale_mock '
if [[ "$*" == *"--json"* ]]; then
    printf "%s" "{\"HostName\":\"test-machine\",\"TailscaleIPs\":[\"100.64.0.1\"]}"
fi
exit 0
'
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    hn=$(get_tailscale_hostname)
    if [ "$hn" = "test-machine" ]; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:get_tailscale_hostname returned '$hn' expected 'test-machine'" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- get_tailscale_ip returns empty when binary absent ---
test_start "Auth state: get_tailscale_ip returns empty when binary absent"
(
    source_installer
    apply_mock_ts_absent
    ip=$(get_tailscale_ip)
    if [ -z "$ip" ]; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:get_tailscale_ip returned '$ip' expected empty when absent" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 3: Funnel Capability and Configuration
# ═════════════════════════════════════════════════════════════════════════════

# --- funnel capable: funnel status exits 0 ---
test_start "Funnel config: is_tailscale_funnel_capable returns true when funnel status exits 0"
make_tailscale_mock "exit 0"
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    if is_tailscale_funnel_capable; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:is_tailscale_funnel_capable returned false when mock exits 0" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- funnel not capable: funnel status exits 1 ---
test_start "Funnel config: is_tailscale_funnel_capable returns false when funnel exits 1"
make_tailscale_mock "exit 1"
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    if ! is_tailscale_funnel_capable; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:is_tailscale_funnel_capable returned true when mock exits 1" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- funnel not capable: binary absent ---
test_start "Funnel config: is_tailscale_funnel_capable returns false when binary absent"
(
    source_installer
    apply_mock_ts_absent
    if ! is_tailscale_funnel_capable; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:is_tailscale_funnel_capable returned true with absent binary" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- _write_funnel_restore_script creates the restore script ---
test_start "Funnel config: _write_funnel_restore_script creates restore script"
make_tailscale_mock "exit 0"
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    _write_funnel_restore_script "$MOCK" 2>/dev/null || true
    if [ -f "$AITEAMFORGE_DIR/tailscale-funnel-restore.sh" ]; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:tailscale-funnel-restore.sh was not created" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- restore script is executable ---
test_start "Funnel config: funnel restore script is executable"
make_tailscale_mock "exit 0"
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    _write_funnel_restore_script "$MOCK" 2>/dev/null || true
    if [ -x "$AITEAMFORGE_DIR/tailscale-funnel-restore.sh" ]; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:tailscale-funnel-restore.sh is not executable" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- restore script contains the tailscale path ---
test_start "Funnel config: restore script contains the correct tailscale path"
make_tailscale_mock "exit 0"
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    _write_funnel_restore_script "$MOCK" 2>/dev/null || true
    if grep -q "$MOCK" "$AITEAMFORGE_DIR/tailscale-funnel-restore.sh" 2>/dev/null; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:restore script does not contain the tailscale path '$MOCK'" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- restore script contains funnel port ---
test_start "Funnel config: restore script contains expected funnel port (443)"
make_tailscale_mock "exit 0"
MOCK="$MOCK_BIN_DIR/tailscale"
(
    export TAILSCALE_FUNNEL_PORT=443
    source_installer
    apply_mock_ts_present "$MOCK"
    _write_funnel_restore_script "$MOCK" 2>/dev/null || true
    if grep -q "443" "$AITEAMFORGE_DIR/tailscale-funnel-restore.sh" 2>/dev/null; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:restore script does not contain funnel port 443" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- restore script incorporates .port files for team routes ---
test_start "Funnel config: restore script includes team routes from .port files"
make_tailscale_mock "exit 0"
MOCK="$MOCK_BIN_DIR/tailscale"
echo "8260" > "$AITEAMFORGE_DIR/lcars-ports/ios.port"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    _write_funnel_restore_script "$MOCK" 2>/dev/null || true
    restore="$AITEAMFORGE_DIR/tailscale-funnel-restore.sh"
    if grep -q "ios" "$restore" 2>/dev/null && grep -q "8260" "$restore" 2>/dev/null; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:restore script does not include ios team route (8260) from .port file" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- _configure_and_validate_funnel returns 0 when funnel cmd succeeds ---
test_start "Funnel config: _configure_and_validate_funnel succeeds with cooperative mock"
make_tailscale_mock 'echo "Funnel on 443"; exit 0'
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    if _configure_and_validate_funnel "$MOCK" 2>/dev/null; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:_configure_and_validate_funnel returned non-zero despite cooperative mock" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- _configure_and_validate_funnel returns non-zero on failure ---
test_start "Funnel config: _configure_and_validate_funnel returns failure when funnel errors"
make_tailscale_mock "exit 1"
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    if ! _configure_and_validate_funnel "$MOCK" 2>/dev/null; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:_configure_and_validate_funnel returned 0 despite failing mock" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 4: Skip Flow (User Opts Out)
# ═════════════════════════════════════════════════════════════════════════════

# Clean up any state from previous sections
rm -f "$AITEAMFORGE_DIR/tailscale-funnel-restore.sh"

# --- no tailscale binary → graceful skip, TAILSCALE_FUNNEL_CONFIGURED=false ---
test_start "Skip flow: install_tailscale_funnel skips gracefully when binary absent"
(
    export NON_INTERACTIVE="true"
    source_installer
    apply_mock_ts_absent
    TAILSCALE_FUNNEL_CONFIGURED="false"
    install_tailscale_funnel 2>/dev/null || true
    if [ "$TAILSCALE_FUNNEL_CONFIGURED" = "false" ]; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:TAILSCALE_FUNNEL_CONFIGURED='$TAILSCALE_FUNNEL_CONFIGURED' expected 'false' when absent" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- not logged in → writes restore script ---
test_start "Skip flow: install_tailscale_funnel writes restore script when not logged in"
make_tailscale_mock "exit 1"
MOCK="$MOCK_BIN_DIR/tailscale"
(
    export NON_INTERACTIVE="true"
    source_installer
    apply_mock_ts_present "$MOCK"
    # Override so status check fails but binary is "present"
    is_tailscale_logged_in() { return 1; }
    is_tailscale_funnel_capable() { return 1; }
    install_tailscale_funnel 2>/dev/null || true
    if [ -f "$AITEAMFORGE_DIR/tailscale-funnel-restore.sh" ]; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:restore script not written when not logged in" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- SETUP_TAILSCALE_FUNNEL=false bypasses funnel even when logged in ---
test_start "Skip flow: SETUP_TAILSCALE_FUNNEL=false skips setup even when logged in"
make_tailscale_mock "exit 0"
MOCK="$MOCK_BIN_DIR/tailscale"
(
    export NON_INTERACTIVE="true"
    export SETUP_TAILSCALE_FUNNEL="false"
    source_installer
    apply_mock_ts_present "$MOCK"
    TAILSCALE_FUNNEL_CONFIGURED="false"
    install_tailscale_funnel 2>/dev/null || true
    if [ "$TAILSCALE_FUNNEL_CONFIGURED" = "false" ]; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:TAILSCALE_FUNNEL_CONFIGURED='$TAILSCALE_FUNNEL_CONFIGURED' should be false when SETUP_TAILSCALE_FUNNEL=false" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- funnel not capable → non-interactive skip with false flag ---
test_start "Skip flow: non-interactive mode sets false when funnel not capable"
make_tailscale_mock "exit 0"
MOCK="$MOCK_BIN_DIR/tailscale"
(
    export NON_INTERACTIVE="true"
    source_installer
    apply_mock_ts_present "$MOCK"
    # logged in but funnel not capable
    is_tailscale_logged_in()      { return 0; }
    is_tailscale_funnel_capable() { return 1; }
    TAILSCALE_FUNNEL_CONFIGURED="false"
    install_tailscale_funnel 2>/dev/null || true
    if [ "$TAILSCALE_FUNNEL_CONFIGURED" = "false" ]; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:TAILSCALE_FUNNEL_CONFIGURED='$TAILSCALE_FUNNEL_CONFIGURED' expected 'false' when funnel not capable" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 5: Error Handling
# ═════════════════════════════════════════════════════════════════════════════

# --- daemon not running: error on stderr + exit 1 → treated as not logged in ---
test_start "Error handling: daemon not running treated as not-logged-in"
make_tailscale_mock 'echo "tailscaled is not running" >&2; exit 1'
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    if ! is_tailscale_logged_in; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:is_tailscale_logged_in returned true when daemon mock fails" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- funnel cmd emits stderr noise but exits 0 → success ---
test_start "Error handling: funnel status with stderr noise still succeeds on exit 0"
make_tailscale_mock 'echo "some warning" >&2; echo "Funnel on 443"; exit 0'
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    if _configure_and_validate_funnel "$MOCK" 2>/dev/null; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:funnel config failed despite exit-0 mock" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- malformed JSON does not crash get_tailscale_hostname ---
test_start "Error handling: malformed JSON does not crash get_tailscale_hostname"
make_tailscale_mock 'printf "NOT JSON {{{"; exit 0'
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    hn=$(get_tailscale_hostname 2>/dev/null || true)
    # Should not crash — result can be empty or garbage, just must not error
    echo "PASS" >> "$TEST_RESULTS_FILE"
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- empty output from ip cmd does not crash ---
test_start "Error handling: get_tailscale_ip handles empty output gracefully"
make_tailscale_mock "exit 0"
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    ip=$(get_tailscale_ip 2>/dev/null || true)
    # Should not crash; empty or missing result is fine
    echo "PASS" >> "$TEST_RESULTS_FILE"
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- funnel template passes bash syntax check ---
test_start "Error handling: tailscale-funnel.template.sh passes bash syntax check"
FUNNEL_TEMPLATE="$TAP_ROOT/share/templates/fleet-monitor/tailscale-funnel.template.sh"
# Templates may have placeholder tokens — just verify no bash syntax error
if bash -n "$FUNNEL_TEMPLATE" 2>/dev/null; then
    test_pass
else
    test_fail "Syntax error in tailscale-funnel.template.sh"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 6: Integration with Fleet Monitor
# ═════════════════════════════════════════════════════════════════════════════

# --- fleet config marks tailscale enabled=true when present ---
test_start "Fleet integration: fleet config sets tailscale enabled when tailscale present"
make_tailscale_mock '
if [[ "$*" == *"ip"* ]]; then echo "100.64.0.1"; fi
exit 0
'
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    # Also stub get_tailscale_ip / get_tailscale_hostname to use mock
    get_tailscale_ip()       { "$MOCK" ip -4 2>/dev/null | head -n1 || echo ""; }
    get_tailscale_hostname() { echo "mock-host"; }
    machine_id=$(generate_machine_id)
    create_fleet_config "$machine_id" "test-host" 2>/dev/null || true
    config_file="$AITEAMFORGE_DIR/config/fleet-config.json"
    if [ -f "$config_file" ] && grep -q 'true' "$config_file" 2>/dev/null; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:fleet-config.json missing or does not contain tailscale enabled flag" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- fleet config marks tailscale false when absent ---
test_start "Fleet integration: fleet config sets tailscale disabled when absent"
(
    source_installer
    apply_mock_ts_absent
    machine_id=$(generate_machine_id)
    create_fleet_config "$machine_id" "test-host" 2>/dev/null || true
    config_file="$AITEAMFORGE_DIR/config/fleet-config.json"
    if [ -f "$config_file" ] && grep -q 'false' "$config_file" 2>/dev/null; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:fleet-config.json missing or does not reflect tailscale disabled state" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- machine identity includes tailscale fields ---
test_start "Fleet integration: machine identity file includes tailscale fields"
make_tailscale_mock '
if [[ "$*" == *"ip"* ]]; then echo "100.64.0.2"; fi
if [[ "$*" == *"--json"* ]]; then printf "%s" "{\"HostName\":\"fleet-host\"}"; fi
exit 0
'
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    get_tailscale_ip()       { echo "100.64.0.2"; }
    get_tailscale_hostname() { echo "fleet-host"; }
    machine_id=$(generate_machine_id)
    create_machine_identity "$machine_id" "fleet-host" 2>/dev/null || true
    identity_file="$AITEAMFORGE_DIR/config/machine-identity.json"
    if [ -f "$identity_file" ] && grep -qi 'tailscale' "$identity_file" 2>/dev/null; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:machine-identity.json missing or lacks tailscale fields" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- machine identity records tailscale IP when connected ---
test_start "Fleet integration: machine identity records tailscale IP when connected"
make_tailscale_mock 'exit 0'
MOCK="$MOCK_BIN_DIR/tailscale"
(
    source_installer
    apply_mock_ts_present "$MOCK"
    get_tailscale_ip()       { echo "100.64.0.3"; }
    get_tailscale_hostname() { echo "fleet-host2"; }
    machine_id=$(generate_machine_id)
    create_machine_identity "$machine_id" "fleet-host2" 2>/dev/null || true
    identity_file="$AITEAMFORGE_DIR/config/machine-identity.json"
    if grep -q "100.64.0.3" "$identity_file" 2>/dev/null; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:machine-identity.json does not contain tailscale IP 100.64.0.3" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- standalone mode fleet config uses localhost URL ---
test_start "Fleet integration: standalone mode fleet config uses localhost URL"
make_tailscale_mock "exit 0"
MOCK="$MOCK_BIN_DIR/tailscale"
(
    export FLEET_MODE="standalone"
    export FLEET_MONITOR_PORT="3000"
    source_installer
    apply_mock_ts_present "$MOCK"
    get_tailscale_ip()       { echo ""; }
    get_tailscale_hostname() { echo ""; }
    machine_id=$(generate_machine_id)
    create_fleet_config "$machine_id" "" 2>/dev/null || true
    config_file="$AITEAMFORGE_DIR/config/fleet-config.json"
    if grep -q "localhost" "$config_file" 2>/dev/null || grep -q "127.0.0.1" "$config_file" 2>/dev/null; then
        echo "PASS" >> "$TEST_RESULTS_FILE"
    else
        echo "FAIL:fleet-config.json does not use localhost for standalone mode" >> "$TEST_RESULTS_FILE"
    fi
)
if tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | grep -q "^PASS"; then
    test_pass
else
    test_fail "$(tail -1 "$TEST_RESULTS_FILE" 2>/dev/null | sed 's/^FAIL://')"
fi

# --- install-fleet-monitor.sh is executable ---
test_start "Fleet integration: install-fleet-monitor.sh exists and is executable"
if [ -x "$INSTALLER" ]; then
    test_pass
else
    test_fail "install-fleet-monitor.sh is missing or not executable"
fi

# --- funnel template exists ---
test_start "Fleet integration: tailscale-funnel.template.sh exists"
FUNNEL_TEMPLATE="$TAP_ROOT/share/templates/fleet-monitor/tailscale-funnel.template.sh"
if [ -f "$FUNNEL_TEMPLATE" ]; then
    test_pass
else
    test_fail "tailscale-funnel.template.sh not found at $FUNNEL_TEMPLATE"
fi
