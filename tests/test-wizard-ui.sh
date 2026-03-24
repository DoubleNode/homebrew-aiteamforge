#!/bin/bash

# test-wizard-ui.sh
# Tests for wizard UI library (libexec/lib/wizard-ui.sh)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UI_LIB="$TAP_ROOT/libexec/lib/wizard-ui.sh"

# Source the UI library (using zsh if available, bash otherwise)
if command -v zsh &>/dev/null; then
  # UI lib is written in zsh, so source it properly
  # For testing, we'll test individual functions by calling them via subshells
  :
fi

# ═══════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════

test_start "UI library file exists"
assert_file_exists "$UI_LIB"
test_pass

test_start "UI library can be sourced without errors (zsh)"
if command -v zsh &>/dev/null; then
  assert_success zsh -c "source '$UI_LIB'; exit 0"
  test_pass
else
  print_warning "zsh not available, skipping zsh source test"
  test_pass
fi

test_start "UI library defines COLOR constants"
output=$(zsh -c "source '$UI_LIB'; echo \$COLOR_AMBER" 2>/dev/null || echo "")
assert_not_empty "$output"
test_pass

test_start "UI library defines print_success function"
output=$(zsh -c "source '$UI_LIB'; print_success 'test message'" 2>&1 || echo "")
assert_contains "$output" "test message"
test_pass

test_start "UI library defines print_error function"
output=$(zsh -c "source '$UI_LIB'; print_error 'error message'" 2>&1 || echo "")
assert_contains "$output" "error message"
test_pass

test_start "UI library defines print_warning function"
output=$(zsh -c "source '$UI_LIB'; print_warning 'warning message'" 2>&1 || echo "")
assert_contains "$output" "warning message"
test_pass

test_start "UI library defines print_info function"
output=$(zsh -c "source '$UI_LIB'; print_info 'info message'" 2>&1 || echo "")
assert_contains "$output" "info message"
test_pass

test_start "UI library defines print_header function"
output=$(zsh -c "source '$UI_LIB'; print_header 'Test Header'" 2>&1 || echo "")
assert_contains "$output" "Test Header"
test_pass

test_start "UI library defines print_section function"
output=$(zsh -c "source '$UI_LIB'; print_section 'Test Section'" 2>&1 || echo "")
assert_contains "$output" "Test Section"
test_pass

test_start "UI library defines print_progress function"
output=$(zsh -c "source '$UI_LIB'; print_progress 5 10 'test task'" 2>&1 || echo "")
assert_contains "$output" "50%"
assert_contains "$output" "test task"
test_pass

test_start "UI library defines print_status function"
output=$(zsh -c "source '$UI_LIB'; print_status 'test item' 'ok'" 2>&1 || echo "")
assert_contains "$output" "test item"
test_pass

test_start "UI library defines print_welcome_banner function"
output=$(zsh -c "source '$UI_LIB'; print_welcome_banner" 2>&1 || echo "")
assert_contains "$output" "STARFLEET"
assert_contains "$output" "SETUP WIZARD"
test_pass

test_start "UI library defines print_completion_banner function"
output=$(zsh -c "source '$UI_LIB'; print_completion_banner" 2>&1 || echo "")
assert_contains "$output" "COMPLETE"
test_pass

test_start "UI library defines die function"
# die should exit with error
zsh -c "source '$UI_LIB'; die 'test error' 42" 2>&1 || exit_code=$?
assert_exit_code 42 ${exit_code:-0}
test_pass

test_start "UI library print_color produces colored output"
output=$(zsh -c "source '$UI_LIB'; print_color \"\$COLOR_BLUE\" 'blue text'" 2>&1 || echo "")
assert_contains "$output" "blue text"
test_pass

test_start "UI library progress bar shows correct percentage"
output=$(zsh -c "source '$UI_LIB'; print_progress 1 4 'task'" 2>&1 || echo "")
assert_contains "$output" "25%"
test_pass

test_start "UI library status handles 'missing' state"
output=$(zsh -c "source '$UI_LIB'; print_status 'item' 'missing'" 2>&1 || echo "")
assert_contains "$output" "Missing"
test_pass

test_start "UI library status handles 'installed' state"
output=$(zsh -c "source '$UI_LIB'; print_status 'item' 'installed'" 2>&1 || echo "")
assert_contains "$output" "OK"
test_pass

test_start "UI library status handles 'failed' state"
output=$(zsh -c "source '$UI_LIB'; print_status 'item' 'failed'" 2>&1 || echo "")
assert_contains "$output" "Failed"
test_pass

# Success!
exit 0
