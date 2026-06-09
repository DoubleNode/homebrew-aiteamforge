#!/bin/bash

# test-xaca-0650-doctor-venv.sh
# Tests for aiteamforge doctor check_python_venv — requirements.txt parsing (XACA-0650)
#
# Covers:
#   - check_python_venv reads package names from share/requirements.txt dynamically
#   - A dep added to the fixture requirements file IS checked (the k501 drift case)
#   - Version pins (pkg==x.y) are stripped — bare package name used for pip show
#   - Comment lines and blank lines in requirements.txt are skipped
#   - Fallback to known set when requirements.txt is missing/unreadable
#
# Design: check_python_venv uses LIBEXEC_DIR (set by doctor at startup from
# BASH_SOURCE) and calls check_result/print_section from doctor.sh scope.
# We exercise it via a generated driver script that:
#   1. Sets LIBEXEC_DIR to a fixture tree (share/requirements.txt, lib/ stubs)
#   2. Defines the helper functions (check_result, print_section, etc.) from
#      common.sh + a minimal shim
#   3. Sources just the check_python_venv body extracted from doctor.sh
#   4. Calls check_python_venv and captures stdout

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCTOR_CMD="$TAP_ROOT/libexec/commands/aiteamforge-doctor.sh"

# ── Bootstrap test helpers ────────────────────────────────────────────────────
# source test-runner.sh FIRST — it sets TEST_TMP_DIR="" at source time,
# so we create our own tmp dir AFTER sourcing it.
if ! type test_start &>/dev/null 2>&1; then
  if [ -f "$SCRIPT_DIR/test-runner.sh" ]; then
    source "$SCRIPT_DIR/test-runner.sh"
  else
    echo "ERROR: test-runner.sh not found at $SCRIPT_DIR" >&2
    exit 1
  fi
fi

# ── Standalone tmp dir (after sourcing runner so it doesn't clobber) ──────────
if [ -z "${TEST_TMP_DIR:-}" ]; then
  TEST_TMP_DIR=$(mktemp -d -t aiteamforge-0650-venv.XXXXXX)
  _OWN_TMP_DIR=true
  trap 'rm -rf "$TEST_TMP_DIR"' EXIT
else
  _OWN_TMP_DIR=false
fi

# ── Fixture and driver helpers ────────────────────────────────────────────────
#
# We extract check_result (doctor-internal helper) and check_python_venv from
# doctor.sh by line range. These line numbers are stable across edits because:
#   check_result starts at the first /^check_result()/ and ends at its /^}/
#   check_python_venv starts at /^check_python_venv()/ and ends at its /^}/
#
# The driver script layout:
# Fixture layout mirrors the real tap structure so LIBEXEC_DIR/../share resolves:
#   $DRIVER_DIR/
#     libexec/             — LIBEXEC_DIR (so ../share = $DRIVER_DIR/share)
#       lib/
#         common.sh        — symlink to real tap lib
#         config.sh        — symlink to real tap lib
#         constants.sh     — symlink to real tap lib
#     share/
#       requirements.txt   — controlled package list
#     fake-bin/
#       python3            — always returns version string
#       pip                — honours INSTALLED list baked into the script

_DRIVER_DIR=""

_extract_function() {
  local file="$1"
  local funcname="$2"
  sed -n "/^${funcname}()/,/^}$/p" "$file"
}

_build_driver() {
  local req_content="$1"   # raw text for requirements.txt
  local installed="$2"      # space-separated package names pip "knows"

  _DRIVER_DIR="$TEST_TMP_DIR/driver-$$-$RANDOM"
  local libexec_dir="$_DRIVER_DIR/libexec"
  local lib_dir="$libexec_dir/lib"
  local fake_bin="$_DRIVER_DIR/fake-bin"
  local share_dir="$_DRIVER_DIR/share"

  mkdir -p "$lib_dir" "$fake_bin" "$share_dir"

  # requirements.txt fixture — at LIBEXEC_DIR/../share/requirements.txt
  printf '%s' "$req_content" > "$share_dir/requirements.txt"

  # Fake python3 (always reports a version)
  printf '#!/bin/bash\necho "Python 3.12.0"\nexit 0\n' > "$fake_bin/python3"
  chmod +x "$fake_bin/python3"

  # Fake pip: pip show <pkg> succeeds iff pkg is in INSTALLED
  # We bake INSTALLED into the script to avoid env-var quoting issues.
  local installed_line="INSTALLED=\" ${installed} \""
  printf '#!/bin/bash\n%s\nif [[ "$1" == "show" ]]; then\n  pkg="$2"\n  if [[ "$INSTALLED" == *" $pkg "* ]]; then\n    printf "Name: %%s\\nVersion: 9.9.9\\n" "$pkg"\n    exit 0\n  else\n    exit 1\n  fi\nfi\nexit 0\n' \
    "$installed_line" > "$fake_bin/pip"
  chmod +x "$fake_bin/pip"

  # Symlink real tap lib files into libexec/lib/
  for f in common.sh config.sh constants.sh; do
    ln -sf "$TAP_ROOT/libexec/lib/$f" "$lib_dir/$f"
  done

  # Extract the two functions we need from doctor.sh
  local check_result_src
  check_result_src="$(_extract_function "$DOCTOR_CMD" "check_result")"
  local check_python_venv_src
  check_python_venv_src="$(_extract_function "$DOCTOR_CMD" "check_python_venv")"

  # Generate the driver script
  cat > "$_DRIVER_DIR/driver.sh" <<DRIVER
#!/bin/bash
# Auto-generated driver for check_python_venv (XACA-0650 tests)
set -eo pipefail

# LIBEXEC_DIR set to libexec/ so that ../share resolves to $share_dir
LIBEXEC_DIR="${libexec_dir}"
AITEAMFORGE_PYTHON="${fake_bin}/python3"
VERBOSE=false
FIX=false
TOTAL_CHECKS=0; PASSED_CHECKS=0; FAILED_CHECKS=0; WARNING_CHECKS=0

# Source real common.sh (provides print_success, print_error, print_warning,
# print_section, print_info)
source "${lib_dir}/common.sh"
source "${lib_dir}/config.sh"
source "${lib_dir}/constants.sh"

# Define check_result (extracted from doctor.sh)
${check_result_src}

# Define check_python_venv (extracted from doctor.sh — uses LIBEXEC_DIR above)
${check_python_venv_src}

# Run it
check_python_venv
DRIVER
  chmod +x "$_DRIVER_DIR/driver.sh"
}

# Run the current fixture's driver; captures stripped output in _LAST_OUTPUT.
_run_driver() {
  _LAST_EXIT_CODE=0
  # Strip ANSI escape sequences for clean string matching
  _LAST_OUTPUT=$(bash "$_DRIVER_DIR/driver.sh" 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g') || _LAST_EXIT_CODE=$?
}

# ── Preconditions ─────────────────────────────────────────────────────────────

test_start "Doctor script exists"
assert_file_exists "$DOCTOR_CMD"
test_pass

test_start "share/requirements.txt exists in tap"
assert_file_exists "$TAP_ROOT/share/requirements.txt"
test_pass

test_start "requirements.txt lists at least one package"
count=$(grep -cE '^[^#[:space:]]' "$TAP_ROOT/share/requirements.txt" 2>/dev/null || echo 0)
[ "$count" -ge 1 ]
assert_exit_success $? "requirements.txt has no non-comment package lines"
test_pass

# ── Core: dynamic parsing ──────────────────────────────────────────────────────

test_start "check_python_venv: iterm2 PASS when installed"
_build_driver $'iterm2==2.15\n' "iterm2"
_run_driver
assert_contains "$_LAST_OUTPUT" "iterm2 package installed"
test_pass

test_start "check_python_venv: iterm2 FAIL when missing"
_build_driver $'iterm2==2.15\n' ""
_run_driver
assert_contains "$_LAST_OUTPUT" "iterm2 package missing"
test_pass

test_start "check_python_venv: pyzipper PASS when installed"
_build_driver $'pyzipper==0.3.6\n' "pyzipper"
_run_driver
assert_contains "$_LAST_OUTPUT" "pyzipper package installed"
test_pass

test_start "check_python_venv: both packages PASS when both installed"
_build_driver $'iterm2==2.15\npyzipper==0.3.6\n' "iterm2 pyzipper"
_run_driver
assert_contains "$_LAST_OUTPUT" "iterm2 package installed"
assert_contains "$_LAST_OUTPUT" "pyzipper package installed"
test_pass

# ── Key anti-regression: the k501 drift case ──────────────────────────────────

test_start "XACA-0650 k501 anti-regression: third dep added to requirements.txt IS checked"
# This is the exact failure mode XACA-0650 exists to prevent.
# With the old hardcoded ("iterm2" "pyzipper") array, adding a third dep to
# requirements.txt would NOT be checked — doctor would silently skip it.
# The fix reads the file dynamically, so newdep must be reported as FAIL here.
_build_driver $'iterm2==2.15\npyzipper==0.3.6\nnewdep==1.0\n' "iterm2 pyzipper"
_run_driver
assert_contains "$_LAST_OUTPUT" "newdep package missing" \
  "A dep added to requirements.txt was silently not checked (k501 drift regression)"
test_pass

test_start "XACA-0650 k501: third dep PASS when installed"
_build_driver $'iterm2==2.15\nnewdep==1.0\n' "iterm2 newdep"
_run_driver
assert_contains "$_LAST_OUTPUT" "newdep package installed"
test_pass

# ── Parsing correctness ────────────────────────────────────────────────────────

test_start "Version pins stripped — bare name used for pip show"
# requirements.txt has pkg==1.2.3; pip show must be called as 'pip show pkg'
# not 'pip show pkg==1.2.3'. Our pip stub only matches bare names, so if
# the pin is NOT stripped the call would fail and we'd see FAIL not PASS.
_build_driver $'iterm2==2.15\n' "iterm2"
_run_driver
assert_contains "$_LAST_OUTPUT" "iterm2 package installed" \
  "Version pin was not stripped — pip show received full pin instead of bare name"
test_pass

test_start "Comment lines are ignored"
_build_driver $'# This is a comment\niterm2==2.15\n' "iterm2"
_run_driver
assert_contains "$_LAST_OUTPUT" "iterm2 package installed"
# The comment must NOT be treated as a package name
assert_not_contains "$_LAST_OUTPUT" "# This is a comment package"
test_pass

test_start "Blank lines are skipped"
_build_driver $'\n\niterm2==2.15\n\npyzipper==0.3.6\n\n' "iterm2 pyzipper"
_run_driver
assert_contains "$_LAST_OUTPUT" "iterm2 package installed"
assert_contains "$_LAST_OUTPUT" "pyzipper package installed"
test_pass

# ── Fallback behaviour ────────────────────────────────────────────────────────

test_start "Fallback to known set when requirements.txt is missing"
_build_driver $'iterm2==2.15\npyzipper==0.3.6\n' "iterm2 pyzipper"
rm -f "$_DRIVER_DIR/share/requirements.txt"
_run_driver
# Fallback set includes both iterm2 and pyzipper
assert_contains "$_LAST_OUTPUT" "iterm2"
assert_contains "$_LAST_OUTPUT" "pyzipper"
test_pass

test_start "Fallback to known set when requirements.txt is empty"
_build_driver "" "iterm2 pyzipper"
_run_driver
assert_contains "$_LAST_OUTPUT" "iterm2"
assert_contains "$_LAST_OUTPUT" "pyzipper"
test_pass

test_start "Fallback: iterm2 FAIL reported when not installed and file missing"
_build_driver "" ""
rm -f "$_DRIVER_DIR/share/requirements.txt"
_run_driver
assert_contains "$_LAST_OUTPUT" "iterm2 package missing"
test_pass

# ── Remediation message ───────────────────────────────────────────────────────

test_start "FAIL output includes 'missing from tap venv' message"
# In default (non-verbose) mode the FAIL line identifies the missing package.
# The brew postinstall remediation detail is shown with --verbose.
_build_driver $'iterm2==2.15\n' ""
_run_driver
assert_contains "$_LAST_OUTPUT" "iterm2 package missing from tap venv" \
  "FAIL line must identify the missing package"
test_pass

test_start "VERBOSE FAIL output includes brew postinstall remediation command"
# With VERBOSE the detail line is printed, which contains the fix command.
_build_driver $'iterm2==2.15\n' ""
# Temporarily re-generate driver with VERBOSE=true
sed -i '' 's/^VERBOSE=false$/VERBOSE=true/' "$_DRIVER_DIR/driver.sh"
_run_driver
assert_contains "$_LAST_OUTPUT" "brew postinstall aiteamforge" \
  "VERBOSE FAIL must include the brew postinstall remediation command"
test_pass

# ── Cleanup ───────────────────────────────────────────────────────────────────

if [ "${_OWN_TMP_DIR:-false}" = "true" ]; then
  exit 0
fi
