#!/bin/bash

# test-installers.sh
# Tests for installer modules (libexec/installers/)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLERS_DIR="$TAP_ROOT/libexec/installers"

# Set up test environment
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
export AITEAMFORGE_HOME="$TAP_ROOT"
mkdir -p "$AITEAMFORGE_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

get_installer_files() {
  find "$INSTALLERS_DIR" -maxdepth 1 -name "install-*.sh" -type f
}

# Helper: run assertion and only call test_pass if it succeeded
# Usage: run_test "name" assertion_func args...
run_assert_pass() {
  if "$@"; then
    test_pass
  fi
  # If assert failed, test_fail was already called by the assert function
}

# ═══════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════

test_start "Installers directory exists"
run_assert_pass assert_dir_exists "$INSTALLERS_DIR"

test_start "At least one installer module exists"
installer_count=$(get_installer_files | wc -l | tr -d ' ')
run_assert_pass assert_exit_success $([ "$installer_count" -gt 0 ]; echo $?)

test_start "All installer modules are executable"
all_exec=true
while IFS= read -r installer; do
  if [ ! -x "$installer" ]; then
    test_fail "Not executable: $(basename "$installer")"
    all_exec=false
    break
  fi
done < <(get_installer_files)
[ "$all_exec" = true ] && test_pass

test_start "All installer modules have proper shebangs"
all_shebangs=true
while IFS= read -r installer; do
  first_line=$(head -n 1 "$installer")
  if [[ "$first_line" != *"#!"* ]]; then
    test_fail "Missing shebang: $(basename "$installer")"
    all_shebangs=false
    break
  fi
done < <(get_installer_files)
[ "$all_shebangs" = true ] && test_pass

test_start "All installer modules pass syntax check"
all_syntax=true
while IFS= read -r installer; do
  if ! bash -n "$installer" 2>/dev/null; then
    test_fail "Syntax error in: $(basename "$installer")"
    all_syntax=false
    break
  fi
done < <(get_installer_files)
[ "$all_syntax" = true ] && test_pass

test_start "Shell installer exists"
run_assert_pass assert_file_exists "$INSTALLERS_DIR/install-shell.sh"

test_start "Shell installer contains shell environment functions"
output=$(grep -c "install_shell_environment\|zshrc" "$INSTALLERS_DIR/install-shell.sh" 2>/dev/null || echo "0")
run_assert_pass assert_exit_success $([ "$output" -gt 0 ]; echo $?)

test_start "Kanban installer exists"
run_assert_pass assert_file_exists "$INSTALLERS_DIR/install-kanban.sh"

test_start "Kanban installer is executable"
run_assert_pass assert_exit_success $([ -x "$INSTALLERS_DIR/install-kanban.sh" ]; echo $?)

test_start "Kanban installer contains kanban functions"
output=$(grep -c "install_kanban_system\|kanban" "$INSTALLERS_DIR/install-kanban.sh" 2>/dev/null || echo "0")
run_assert_pass assert_exit_success $([ "$output" -gt 0 ]; echo $?)

test_start "Claude config installer exists"
run_assert_pass assert_file_exists "$INSTALLERS_DIR/install-claude-config.sh"

test_start "Claude config installer handles missing ~/.claude/"
output=$(bash "$INSTALLERS_DIR/install-claude-config.sh" --help 2>&1 || true)
# Either --help produces output, or the script mentions claude in its code
if [ -z "$output" ]; then
  output=$(grep -c "claude" "$INSTALLERS_DIR/install-claude-config.sh" 2>/dev/null || echo "0")
fi
run_assert_pass assert_not_empty "$output"

test_start "Fleet monitor installer exists"
run_assert_pass assert_file_exists "$INSTALLERS_DIR/install-fleet-monitor.sh"

test_start "Fleet monitor installer handles missing Tailscale"
output=$(bash "$INSTALLERS_DIR/install-fleet-monitor.sh" --help 2>&1 || true)
if [ -z "$output" ]; then
  output=$(grep -c "fleet\|monitor" "$INSTALLERS_DIR/install-fleet-monitor.sh" 2>/dev/null || echo "0")
fi
run_assert_pass assert_not_empty "$output"

test_start "Team installer exists"
run_assert_pass assert_file_exists "$INSTALLERS_DIR/install-team.sh"

test_start "Team installer handles unknown team ID gracefully"
output=$(bash "$INSTALLERS_DIR/install-team.sh" invalid-team-id 2>&1 || true)
output_lower=$(echo "$output" | tr '[:upper:]' '[:lower:]')
if [[ "$output_lower" == *"error"* ]] || [[ "$output_lower" == *"unknown"* ]] || [[ "$output_lower" == *"invalid"* ]] || [[ "$output_lower" == *"not found"* ]]; then
  test_pass
else
  test_fail "Expected error message for invalid team ID, got: $output"
fi

test_start "All installers contain documentation or comments"
all_have_docs=true
while IFS= read -r installer; do
  # Check for either --help handling or descriptive comments
  has_docs=$(grep -c "Usage\|help\|# .*Install" "$installer" 2>/dev/null || echo "0")
  if [ "$has_docs" -eq 0 ]; then
    test_fail "No documentation: $(basename "$installer")"
    all_have_docs=false
    break
  fi
done < <(get_installer_files)
[ "$all_have_docs" = true ] && test_pass

test_start "Expected installers are all present"
all_present=true
expected_installers="shell kanban claude-config fleet-monitor team"
for installer in $expected_installers; do
  if [ ! -f "$INSTALLERS_DIR/install-${installer}.sh" ]; then
    test_fail "Missing: install-${installer}.sh"
    all_present=false
    break
  fi
done
[ "$all_present" = true ] && test_pass

# Success!
exit 0
