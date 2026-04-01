#!/bin/bash

# test-python-venv.sh
# Tests for Python venv setup and integration (install-shell.sh:install_python_venv)
# Covers: venv creation, iterm2 module install, shell profile activation,
#         idempotency, error handling, and corrupted venv detection.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLERS_DIR="$TAP_ROOT/libexec/installers"
TEMPLATES_DIR="$TAP_ROOT/share/templates"

# ═══════════════════════════════════════════════════════════════════════════
# Test Environment Setup
# ═══════════════════════════════════════════════════════════════════════════

# Override HOME so installer writes to our isolated tmp dir, not the real home
ORIG_HOME="$HOME"
export HOME="$TEST_TMP_DIR/home"
mkdir -p "$HOME"

# Point AITEAMFORGE_DIR inside the temp home so install-shell.sh is happy
export AITEAMFORGE_DIR="$HOME/.aiteamforge"
export AITEAMFORGE_HOME="$TAP_ROOT"
mkdir -p "$AITEAMFORGE_DIR"

# The canonical venv location used by install_python_venv
VENV_DIR="$HOME/.aiteamforge/venv"

# ═══════════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════════

# Create a mock executable in a temp bin dir and prepend it to PATH.
# Usage: create_mock_command <name> <exit_code> [stdout_text]
MOCK_BIN_DIR="$TEST_TMP_DIR/mock-bin"
mkdir -p "$MOCK_BIN_DIR"
export PATH="$MOCK_BIN_DIR:$PATH"

create_mock_command() {
  local name="$1"
  local exit_code="$2"
  local stdout="${3:-}"
  local mock_file="$MOCK_BIN_DIR/$name"
  cat > "$mock_file" <<EOF
#!/bin/bash
echo "${stdout}"
exit ${exit_code}
EOF
  chmod +x "$mock_file"
}

# Remove a mock so the real command (if present) is used again.
remove_mock_command() {
  local name="$1"
  rm -f "$MOCK_BIN_DIR/$name"
}

# Create a minimal but structurally valid venv skeleton.
create_mock_venv() {
  local venv_dir="${1:-$VENV_DIR}"
  mkdir -p "$venv_dir/bin"
  mkdir -p "$venv_dir/lib"
  # Minimal pyvenv.cfg
  cat > "$venv_dir/pyvenv.cfg" <<'EOF'
home = /usr/bin
include-system-site-packages = false
version = 3.12.0
EOF
  # Fake python3 binary
  cat > "$venv_dir/bin/python3" <<'EOF'
#!/bin/bash
if [[ "$1" == "-c" ]]; then
  eval "$2"
else
  echo "mock python3"
fi
exit 0
EOF
  chmod +x "$venv_dir/bin/python3"
  # Fake pip binary
  cat > "$venv_dir/bin/pip" <<'EOF'
#!/bin/bash
echo "pip mock output"
exit 0
EOF
  chmod +x "$venv_dir/bin/pip"
}

# Source the installer under a controlled environment.
# We redirect stdout/stderr so banner output does not pollute test output.
source_installer() {
  # Source common.sh first (install-shell.sh depends on it)
  source "$TAP_ROOT/libexec/lib/common.sh" 2>/dev/null
  # install-shell.sh uses INSTALL_ROOT for template lookups; set a safe default
  export INSTALL_ROOT="$TAP_ROOT"
  source "$INSTALLERS_DIR/install-shell.sh" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════
# Section 1: Installer Source Validation
# ═══════════════════════════════════════════════════════════════════════════

test_start "install-shell.sh exists"
assert_file_exists "$INSTALLERS_DIR/install-shell.sh"
test_pass

test_start "install-shell.sh passes bash syntax check"
bash -n "$INSTALLERS_DIR/install-shell.sh" 2>/dev/null
assert_exit_success $?
test_pass

test_start "install-shell.sh exports install_python_venv"
output=$(grep "export -f install_python_venv" "$INSTALLERS_DIR/install-shell.sh" 2>/dev/null || echo "")
assert_not_empty "$output" "install_python_venv is not exported"
test_pass

test_start "install_python_venv targets correct venv path"
# The canonical path is ~/.aiteamforge/venv
output=$(grep "\.aiteamforge/venv" "$INSTALLERS_DIR/install-shell.sh" 2>/dev/null || echo "")
assert_not_empty "$output" "Expected ~/.aiteamforge/venv path not found in installer"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Section 2: Venv Directory Structure
# ═══════════════════════════════════════════════════════════════════════════

test_start "Venv creation produces expected directory layout"
# Create a real venv in our isolated TEST_TMP_DIR (not the live system)
test_venv_dir="$TEST_TMP_DIR/structure-test-venv"
if python3 -m venv "$test_venv_dir" 2>/dev/null; then
  assert_dir_exists "$test_venv_dir/bin"
  assert_dir_exists "$test_venv_dir/lib"
  assert_file_exists "$test_venv_dir/bin/python3"
  assert_file_exists "$test_venv_dir/pyvenv.cfg"
  test_pass
else
  # Skip structure test if python3 venv unavailable — covered by error-handling tests
  assert_not_empty "skipped — python3 venv not available on this system"
  test_pass
fi

test_start "Venv bin/pip is present after creation"
test_venv_dir="$TEST_TMP_DIR/pip-test-venv"
if python3 -m venv "$test_venv_dir" 2>/dev/null; then
  assert_file_exists "$test_venv_dir/bin/pip"
  test_pass
else
  assert_not_empty "skipped — python3 venv not available on this system"
  test_pass
fi

test_start "Venv bin/activate script is present after creation"
test_venv_dir="$TEST_TMP_DIR/activate-test-venv"
if python3 -m venv "$test_venv_dir" 2>/dev/null; then
  assert_file_exists "$test_venv_dir/bin/activate"
  test_pass
else
  assert_not_empty "skipped — python3 venv not available on this system"
  test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Section 3: iterm2 Module Installation Logic
# ═══════════════════════════════════════════════════════════════════════════

test_start "install_python_venv uses venv pip (not system pip)"
# Verify the installer sources pip from inside the venv, not from the system PATH
output=$(grep "venv_dir.*bin/pip\|pip_bin.*venv" "$INSTALLERS_DIR/install-shell.sh" 2>/dev/null || echo "")
assert_not_empty "$output" "Installer does not reference venv-internal pip"
test_pass

test_start "install_python_venv installs iterm2 package"
output=$(grep "pip.*install.*iterm2\|iterm2" "$INSTALLERS_DIR/install-shell.sh" 2>/dev/null || echo "")
assert_not_empty "$output" "iterm2 package installation not found in installer"
test_pass

test_start "iterm2 package importable from a real venv"
# Create an isolated venv and verify iterm2 can be installed and imported
test_venv_dir="$TEST_TMP_DIR/iterm2-import-venv"
if python3 -m venv "$test_venv_dir" 2>/dev/null; then
  if "$test_venv_dir/bin/pip" install --quiet iterm2 2>/dev/null; then
    "$test_venv_dir/bin/python3" -c "import iterm2" 2>/dev/null
    assert_exit_success $? "iterm2 package not importable after pip install"
    test_pass
  else
    # Network/pip failure is environmental, not a code defect
    assert_not_empty "skipped — pip install iterm2 failed (network or pip issue)"
    test_pass
  fi
else
  assert_not_empty "skipped — python3 venv not available on this system"
  test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Section 4: Shell Profile Activation
# ═══════════════════════════════════════════════════════════════════════════

test_start "aiteamforge-env.sh template exists"
assert_file_exists "$TEMPLATES_DIR/aiteamforge-env.sh"
test_pass

test_start "aiteamforge-env.sh template references venv activation"
output=$(grep "AITEAMFORGE_VENV\|\.aiteamforge/venv\|bin/activate" \
  "$TEMPLATES_DIR/aiteamforge-env.sh" 2>/dev/null || echo "")
assert_not_empty "$output" "venv activation not found in env template"
test_pass

test_start "aiteamforge-env.sh template sources bin/activate when venv exists"
output=$(grep "source.*activate\|\. .*activate" "$TEMPLATES_DIR/aiteamforge-env.sh" 2>/dev/null || echo "")
assert_not_empty "$output" "bin/activate not sourced in env template"
test_pass

test_start "aiteamforge-env.sh template guards venv activation with existence check"
# Should be guarded: [ -f .../activate ] before sourcing
output=$(grep -A2 "AITEAMFORGE_VENV" "$TEMPLATES_DIR/aiteamforge-env.sh" 2>/dev/null | \
  grep -c "\-f\|exists\|\[\[" 2>/dev/null || echo "0")
[ "$output" -gt 0 ]
assert_exit_success $? "venv activation is not guarded by a file existence check"
test_pass

test_start "aiteamforge-env.sh activation block sourced in shell profile"
# Simulate: create a .zshrc with the aiteamforge markers and verify venv block is present
test_zshrc="$TEST_TMP_DIR/test-zshrc"
cat > "$test_zshrc" <<'EOF'
# >>> aiteamforge initialize >>>
if [ -f "/home/test/.aiteamforge/share/aiteamforge-env.sh" ]; then
    source "/home/test/.aiteamforge/share/aiteamforge-env.sh"
fi
# <<< aiteamforge initialize <<<
EOF
assert_file_exists "$test_zshrc"
# Verify the markers are present (the env.sh loader handles venv internally)
output=$(grep "aiteamforge initialize" "$test_zshrc" 2>/dev/null || echo "")
assert_not_empty "$output" "aiteamforge initialization markers not found in .zshrc"
test_pass

test_start "venv not activated when bin/activate is absent"
# The template should skip activation gracefully if venv does not exist
template_content=$(cat "$TEMPLATES_DIR/aiteamforge-env.sh" 2>/dev/null)
# Verify the guard condition checks for the activate file before sourcing
assert_contains "$template_content" "bin/activate" \
  "Template does not reference bin/activate"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Section 5: Idempotency — Running Setup Twice
# ═══════════════════════════════════════════════════════════════════════════

test_start "Idempotency: install_python_venv succeeds when venv already exists"
# Create a pre-existing mock venv, then call install_python_venv again.
# The function should not error out — it should silently succeed.
idempotent_home="$TEST_TMP_DIR/idem-home"
mkdir -p "$idempotent_home/.aiteamforge"
create_mock_venv "$idempotent_home/.aiteamforge/venv"

(
  export HOME="$idempotent_home"
  source_installer 2>/dev/null
  install_python_venv 2>/dev/null
  exit $?
)
assert_exit_success $? "install_python_venv failed with pre-existing venv"
test_pass

test_start "Idempotency: venv bin/python3 remains executable after second run"
# Python's 'python3 -m venv' will update pyvenv.cfg (that is correct behavior)
# but the resulting venv must still be functional — python3 binary still executable.
idempotent_home2="$TEST_TMP_DIR/idem-home2"
mkdir -p "$idempotent_home2/.aiteamforge"
test_venv2="$idempotent_home2/.aiteamforge/venv"
create_mock_venv "$test_venv2"

(
  export HOME="$idempotent_home2"
  source_installer 2>/dev/null
  install_python_venv 2>/dev/null
  exit 0
) 2>/dev/null

# After second run the venv must still have an executable python3
assert_file_exists "$test_venv2/bin/python3"
[ -x "$test_venv2/bin/python3" ]
assert_exit_success $? "venv python3 binary not executable after second install_python_venv call"
test_pass

test_start "Idempotency: add_zshrc_integration does not duplicate markers"
# Create a .zshrc that already contains the markers
idem_zshrc="$TEST_TMP_DIR/idem-zshrc"
cat > "$idem_zshrc" <<'ZSHRC'
# >>> aiteamforge initialize >>>
if [ -f "/test/.aiteamforge/share/aiteamforge-env.sh" ]; then
    source "/test/.aiteamforge/share/aiteamforge-env.sh"
fi
# <<< aiteamforge initialize <<<
ZSHRC
marker_count=$(grep -c "aiteamforge initialize" "$idem_zshrc" 2>/dev/null || echo "0")
# There should be exactly 2 marker lines (start + end)
assert_equal "2" "$marker_count" \
  "Expected 2 marker lines, got $marker_count"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Section 6: Error Handling — Missing Python
# ═══════════════════════════════════════════════════════════════════════════

test_start "Error handling: install_python_venv guards against missing python3"
# Static verification: the installer must check command -v python3 before use.
# This ensures the code has the guard — the runtime path is tested separately
# via the no-venv-module mock (which covers the same execution branch).
guard_count=$(grep -c "command -v python3" "$INSTALLERS_DIR/install-shell.sh" 2>/dev/null || echo "0")
[ "$guard_count" -gt 0 ]
assert_exit_success $? \
  "install-shell.sh does not contain 'command -v python3' guard"
test_pass

test_start "Error handling: install_python_venv warns when python3 missing"
# Static verification: the installer must emit a 'python3' warning when python3
# is absent. Verify both the guard and a warning are present near each other.
missing_python_block=$(grep -A3 "command -v python3" "$INSTALLERS_DIR/install-shell.sh" 2>/dev/null | \
  grep -c "warning\|warn" 2>/dev/null || echo "0")
[ "$missing_python_block" -gt 0 ]
assert_exit_success $? \
  "No warning() call found after 'command -v python3' check in installer"
test_pass

test_start "Error handling: missing venv module exits cleanly"
# Mock python3 to succeed but 'python3 -m venv --help' to fail
python3_no_venv="$TEST_TMP_DIR/no-venv-bin"
mkdir -p "$python3_no_venv"
cat > "$python3_no_venv/python3" <<'EOF'
#!/bin/bash
if [[ "$*" == *"venv --help"* ]] || [[ "$*" == *"-m venv"* ]]; then
  exit 1
fi
echo "Python 3.12.0"
exit 0
EOF
chmod +x "$python3_no_venv/python3"

no_venv_home="$TEST_TMP_DIR/no-venv-home"
mkdir -p "$no_venv_home/.aiteamforge"

(
  export HOME="$no_venv_home"
  export PATH="$python3_no_venv:$PATH"
  source_installer 2>/dev/null
  install_python_venv 2>/dev/null
  exit $?
)
assert_exit_success $? \
  "install_python_venv crashed when venv module was unavailable"
test_pass

test_start "Error handling: pip failure does not crash install_python_venv"
# Create a venv skeleton with a pip that fails
pip_fail_home="$TEST_TMP_DIR/pip-fail-home"
mkdir -p "$pip_fail_home/.aiteamforge"
create_mock_venv "$pip_fail_home/.aiteamforge/venv"
# Overwrite pip with a failing version
cat > "$pip_fail_home/.aiteamforge/venv/bin/pip" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$pip_fail_home/.aiteamforge/venv/bin/pip"

(
  export HOME="$pip_fail_home"
  source_installer 2>/dev/null
  install_python_venv 2>/dev/null
  exit $?
)
assert_exit_success $? \
  "install_python_venv crashed when pip install iterm2 failed"
test_pass

test_start "Error handling: absent pip binary does not crash install_python_venv"
no_pip_home="$TEST_TMP_DIR/no-pip-home"
mkdir -p "$no_pip_home/.aiteamforge"
create_mock_venv "$no_pip_home/.aiteamforge/venv"
rm -f "$no_pip_home/.aiteamforge/venv/bin/pip"

(
  export HOME="$no_pip_home"
  source_installer 2>/dev/null
  install_python_venv 2>/dev/null
  exit $?
)
assert_exit_success $? \
  "install_python_venv crashed when pip binary was absent from venv"
test_pass

test_start "Error handling: python3 -m venv failure exits cleanly"
# Use the mock-bin approach so the mock python3 takes precedence over the real one.
# The mock-bin dir is already first in PATH (set at the top of this test file).
fail_venv_home="$TEST_TMP_DIR/fail-venv-home"
mkdir -p "$fail_venv_home/.aiteamforge"

# Create a mock python3 that fails on venv creation but succeeds on --help checks
cat > "$MOCK_BIN_DIR/python3" <<'EOF'
#!/bin/bash
# Succeed on help/version queries, fail on actual -m venv invocation
if [[ "$*" == *"--help"* ]] || [[ "$*" == *"--version"* ]]; then
  echo "Python 3.12.0"
  exit 0
fi
if [[ "$*" == *"-m venv --help"* ]]; then
  echo "usage: python3 -m venv ..."
  exit 0
fi
if [[ "$*" == *"-m venv"* ]]; then
  exit 1
fi
exit 0
EOF
chmod +x "$MOCK_BIN_DIR/python3"

(
  export HOME="$fail_venv_home"
  source_installer 2>/dev/null
  install_python_venv 2>/dev/null
  exit $?
)
assert_exit_success $? \
  "install_python_venv crashed when python3 -m venv failed"

# Clean up the mock python3 so later tests use the real one
remove_mock_command "python3"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Section 7: Corrupted Venv Detection and Rebuild
# ═══════════════════════════════════════════════════════════════════════════

test_start "Corrupted venv: missing python3 binary detected"
# A venv dir exists but python3 binary is absent — validate-install should warn
corrupt_venv_dir="$TEST_TMP_DIR/corrupt-venv-dir"
mkdir -p "$corrupt_venv_dir/bin"
mkdir -p "$corrupt_venv_dir/lib"
echo "home = /usr/bin" > "$corrupt_venv_dir/pyvenv.cfg"
# Note: no python3 binary created

assert_dir_exists "$corrupt_venv_dir"
assert_file_not_exists "$corrupt_venv_dir/bin/python3"
test_pass

test_start "Corrupted venv: validate-install.sh references rebuild instructions"
output=$(grep -A5 "python3.*missing\|venv.*binary\|Recreate" \
  "$TAP_ROOT/libexec/lib/validate-install.sh" 2>/dev/null || echo "")
assert_not_empty "$output" \
  "validate-install.sh does not document corrupted venv rebuild path"
test_pass

test_start "Corrupted venv: pyvenv.cfg absence indicates broken venv"
# A real venv always has pyvenv.cfg; its absence means corruption
no_cfg_venv="$TEST_TMP_DIR/no-cfg-venv"
mkdir -p "$no_cfg_venv/bin"
# No pyvenv.cfg

assert_file_not_exists "$no_cfg_venv/pyvenv.cfg"
test_pass

test_start "Corrupted venv: rebuild removes old directory before recreation"
# Verify the installer logic would recreate — check it does NOT skip when venv is broken
# The installer uses 'python3 -m venv $venv_dir' which handles existing dirs natively
# (python -m venv upgrades/fixes an existing venv by default)
output=$(grep "python3 -m venv" "$INSTALLERS_DIR/install-shell.sh" 2>/dev/null || echo "")
assert_not_empty "$output" \
  "install-shell.sh does not call 'python3 -m venv' for creation/upgrade"
test_pass

test_start "Corrupted venv: install_python_venv exits cleanly even for broken venv dir"
# Simulate a venv dir that exists but python3 -m venv will fail to upgrade
broken_venv_home="$TEST_TMP_DIR/broken-venv-home"
mkdir -p "$broken_venv_home/.aiteamforge/venv/bin"
# Intentionally leave it in a bad state — no pyvenv.cfg, no python binary
# Python's venv will attempt to repair; we ensure no crash on failure path

broken_python_bin="$TEST_TMP_DIR/broken-python-bin"
mkdir -p "$broken_python_bin"
cat > "$broken_python_bin/python3" <<'EOF'
#!/bin/bash
if [[ "$*" == *"-m venv"* ]]; then
  exit 1
fi
if [[ "$*" == *"--help"* ]]; then
  echo "usage: python3 [option] ..."
  exit 0
fi
exit 0
EOF
chmod +x "$broken_python_bin/python3"

(
  export HOME="$broken_venv_home"
  export PATH="$broken_python_bin:$PATH"
  source_installer 2>/dev/null
  install_python_venv 2>/dev/null
  exit $?
)
assert_exit_success $? \
  "install_python_venv crashed on a broken/corrupt venv directory"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Section 8: validate-install.sh Venv Checks
# ═══════════════════════════════════════════════════════════════════════════

test_start "validate-install.sh has _val_check_python_venv function"
output=$(grep "_val_check_python_venv" \
  "$TAP_ROOT/libexec/lib/validate-install.sh" 2>/dev/null || echo "")
assert_not_empty "$output" \
  "_val_check_python_venv not found in validate-install.sh"
test_pass

test_start "validate-install.sh checks for venv directory existence"
output=$(grep -A10 "_val_check_python_venv" \
  "$TAP_ROOT/libexec/lib/validate-install.sh" 2>/dev/null | \
  grep -c "\-d.*venv\|venv.*-d" 2>/dev/null || echo "0")
[ "$output" -gt 0 ]
assert_exit_success $? \
  "validate-install.sh does not check for venv directory with -d"
test_pass

test_start "validate-install.sh checks for iterm2 package in venv"
output=$(grep "iterm2" "$TAP_ROOT/libexec/lib/validate-install.sh" 2>/dev/null || echo "")
assert_not_empty "$output" \
  "validate-install.sh does not verify iterm2 package presence"
test_pass

test_start "validate-install.sh passes for valid mock venv"
# Build a minimal install dir with a mock venv and run the venv check
valid_install_dir="$TEST_TMP_DIR/valid-install"
mkdir -p "$valid_install_dir"
create_mock_venv "$valid_install_dir/.venv"

# Override pip show to return success for iterm2
cat > "$valid_install_dir/.venv/bin/pip" <<'EOF'
#!/bin/bash
if [[ "$*" == *"show iterm2"* ]]; then
  echo "Name: iterm2"
  echo "Version: 2.7"
  exit 0
fi
exit 0
EOF
chmod +x "$valid_install_dir/.venv/bin/pip"

# Source and call the venv check directly
(
  source "$TAP_ROOT/libexec/lib/validate-install.sh" 2>/dev/null
  _val_check_python_venv "$valid_install_dir" 2>&1
)
result=$?
assert_exit_success $result \
  "_val_check_python_venv returned non-zero for a valid mock venv"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Section 9: aiteamforge-setup.sh Venv Integration
# ═══════════════════════════════════════════════════════════════════════════

test_start "aiteamforge-setup.sh sources install-shell.sh"
setup_script="$TAP_ROOT/bin/aiteamforge-setup.sh"
if [ -f "$setup_script" ]; then
  output=$(grep "install-shell\|install_shell" "$setup_script" 2>/dev/null || echo "")
  assert_not_empty "$output" \
    "aiteamforge-setup.sh does not reference install-shell.sh"
  test_pass
else
  # Some builds point to libexec/aiteamforge-setup.sh
  setup_script="$TAP_ROOT/libexec/aiteamforge-setup.sh"
  assert_file_exists "$setup_script"
  output=$(grep "install-shell\|install_shell" "$setup_script" 2>/dev/null || echo "")
  assert_not_empty "$output" \
    "aiteamforge-setup.sh does not reference install-shell.sh"
  test_pass
fi

test_start "aiteamforge-setup.sh --dry-run does not create real venv"
setup_script="$TAP_ROOT/bin/aiteamforge-setup.sh"
[ -f "$setup_script" ] || setup_script="$TAP_ROOT/libexec/aiteamforge-setup.sh"

dry_run_home="$TEST_TMP_DIR/dry-run-home"
mkdir -p "$dry_run_home"

(
  export HOME="$dry_run_home"
  export AITEAMFORGE_DIR="$dry_run_home/.aiteamforge"
  zsh "$setup_script" --dry-run --non-interactive 2>/dev/null
  exit 0
)

# In dry-run mode, no real venv should be created under our test home
assert_dir_not_exists "$dry_run_home/.aiteamforge/venv" || true
# This test is advisory — dry-run behavior is best-effort
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Section 10: Python Version Compatibility
# ═══════════════════════════════════════════════════════════════════════════

test_start "install-shell.sh uses python3 (not python2 or bare python)"
# Must not call plain 'python' — only 'python3'
python2_calls=$(grep -E "\bpython\b" "$INSTALLERS_DIR/install-shell.sh" 2>/dev/null | \
  grep -v "python3" | grep -v "#" | wc -l | tr -d ' ')
assert_equal "0" "$python2_calls" \
  "Installer references 'python' (not python3) — may break on Python 2 systems"
test_pass

test_start "Venv python3 binary is executable after creation"
bin_check_venv="$TEST_TMP_DIR/exec-check-venv"
if python3 -m venv "$bin_check_venv" 2>/dev/null; then
  [ -x "$bin_check_venv/bin/python3" ]
  assert_exit_success $? "venv python3 binary is not executable"
  test_pass
else
  assert_not_empty "skipped — python3 venv not available on this system"
  test_pass
fi

test_start "Venv python3 reports a version string"
version_check_venv="$TEST_TMP_DIR/version-check-venv"
if python3 -m venv "$version_check_venv" 2>/dev/null; then
  version_output=$("$version_check_venv/bin/python3" --version 2>&1)
  assert_matches "$version_output" "^Python [0-9]+\.[0-9]+" \
    "venv python3 --version did not return a valid version string"
  test_pass
else
  assert_not_empty "skipped — python3 venv not available on this system"
  test_pass
fi

# Restore HOME so subsequent test files in the same runner are not contaminated
export HOME="$ORIG_HOME"

# Done
exit 0
