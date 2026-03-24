#!/usr/bin/env zsh

# test-wizard.sh
# Quick test script to verify the setup wizard works

set -euo pipefail

echo "═══════════════════════════════════════════════════════════════════════════"
echo "  AITEAMFORGE SETUP WIZARD - TEST SCRIPT"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

# Test 1: Help output
echo "Test 1: Help output"
echo "-------------------"
./bin/aiteamforge-setup --help
if [ $? -eq 0 ]; then
  echo "✓ Help output works"
else
  echo "✗ Help output failed"
  exit 1
fi
echo ""

# Test 2: Dry run mode
echo "Test 2: Dry run mode"
echo "--------------------"
echo "Running wizard in dry-run mode (no changes will be made)..."
echo ""
./bin/aiteamforge-setup --dry-run --non-interactive > /dev/null 2>&1
exit_code=$?
if [ $exit_code -eq 0 ]; then
  echo "✓ Dry run mode works"
else
  echo "✗ Dry run mode failed (exit code: $exit_code)"
  echo "  Run './bin/aiteamforge-setup --dry-run --non-interactive' to see output"
  exit 1
fi
echo ""

# Test 3: Check generated files
echo "Test 3: File structure"
echo "----------------------"
files_ok=true

if [ ! -f "./libexec/aiteamforge-setup.sh" ]; then
  echo "✗ Missing: libexec/aiteamforge-setup.sh"
  files_ok=false
fi

if [ ! -f "./libexec/lib/wizard-ui.sh" ]; then
  echo "✗ Missing: libexec/lib/wizard-ui.sh"
  files_ok=false
fi

if [ ! -f "./bin/aiteamforge-setup" ]; then
  echo "✗ Missing: bin/aiteamforge-setup"
  files_ok=false
fi

if [ ! -x "./bin/aiteamforge-setup" ]; then
  echo "✗ Not executable: bin/aiteamforge-setup"
  files_ok=false
fi

if [ ! -f "./docs/SETUP_WIZARD.md" ]; then
  echo "✗ Missing: docs/SETUP_WIZARD.md"
  files_ok=false
fi

if [ "$files_ok" = true ]; then
  echo "✓ All required files present and executable"
else
  echo "✗ Some files missing or not executable"
  exit 1
fi
echo ""

# Test 4: UI library functions
echo "Test 4: UI library functions"
echo "----------------------------"
source ./libexec/lib/wizard-ui.sh

print_success "Success message test"
print_error "Error message test"
print_warning "Warning message test"
print_info "Info message test"
echo "✓ UI library functions work"
echo ""

# Summary
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  ALL TESTS PASSED"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo "Setup wizard is ready for use!"
echo ""
echo "Try it:"
echo "  ./bin/aiteamforge-setup --help"
echo "  ./bin/aiteamforge-setup --dry-run"
echo ""
