#!/bin/bash

# test-runner.sh
# Test framework for aiteamforge Homebrew Tap
# Discovers and runs test files, provides assert functions, reports results

set -eo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════════════

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Test discovery
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="${TEST_DIR:-$SCRIPT_DIR}"

# Test state
VERBOSE=false
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
CURRENT_TEST_FILE=""
CURRENT_TEST_NAME=""
TEST_FAILED=false

# Temp directory for test isolation
TEST_TMP_DIR=""
TEST_RESULTS_FILE=""

# ═══════════════════════════════════════════════════════════════════════════
# Output Functions
# ═══════════════════════════════════════════════════════════════════════════

print_success() {
  echo -e "${GREEN}✓${NC} $1"
}

print_error() {
  echo -e "${RED}✗${NC} $1" >&2
}

print_warning() {
  echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
  echo -e "${BLUE}ℹ${NC} $1"
}

print_verbose() {
  if [ "$VERBOSE" = true ]; then
    echo -e "${CYAN}▸${NC} $1"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Test Management
# ═══════════════════════════════════════════════════════════════════════════

# Create isolated temp directory for test
setup_test_env() {
  TEST_TMP_DIR=$(mktemp -d -t aiteamforge-test.XXXXXX)
  TEST_RESULTS_FILE="$TEST_TMP_DIR/.test-results"
  touch "$TEST_RESULTS_FILE"
  print_verbose "Created test temp dir: $TEST_TMP_DIR"
  export TEST_TMP_DIR
  export TEST_RESULTS_FILE
}

# Clean up temp directory
cleanup_test_env() {
  if [ -n "$TEST_TMP_DIR" ] && [ -d "$TEST_TMP_DIR" ]; then
    rm -rf "$TEST_TMP_DIR"
    print_verbose "Cleaned up test temp dir"
  fi
}

# Trap to ensure cleanup even on failure
trap cleanup_test_env EXIT INT TERM

# Start a new test
test_start() {
  local test_name="$1"
  CURRENT_TEST_NAME="$test_name"
  TEST_FAILED=false
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  # Write to results file for parent process
  if [ -n "$TEST_RESULTS_FILE" ]; then
    echo "START" >> "$TEST_RESULTS_FILE"
  fi
  print_verbose "Running: $test_name"
}

# Mark test as passed
test_pass() {
  PASSED_TESTS=$((PASSED_TESTS + 1))
  # Write to results file for parent process
  if [ -n "$TEST_RESULTS_FILE" ]; then
    echo "PASS" >> "$TEST_RESULTS_FILE"
  fi
  if [ "$VERBOSE" = true ]; then
    print_success "$CURRENT_TEST_NAME"
  else
    echo -n "."
  fi
}

# Mark test as failed
test_fail() {
  local message="$1"
  FAILED_TESTS=$((FAILED_TESTS + 1))
  TEST_FAILED=true
  # Write to results file for parent process
  if [ -n "$TEST_RESULTS_FILE" ]; then
    echo "FAIL:$message" >> "$TEST_RESULTS_FILE"
  fi

  if [ "$VERBOSE" = true ]; then
    print_error "$CURRENT_TEST_NAME: $message"
  else
    echo -n "F"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Assert Functions
# ═══════════════════════════════════════════════════════════════════════════

# Assert two values are equal
assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="${3:-Expected '$expected' but got '$actual'}"

  if [ "$expected" = "$actual" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert two values are not equal
assert_not_equal() {
  local unexpected="$1"
  local actual="$2"
  local message="${3:-Expected value to not be '$unexpected'}"

  if [ "$unexpected" != "$actual" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert string contains substring
assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="${3:-Expected to find '$needle' in '$haystack'}"

  if [[ "$haystack" == *"$needle"* ]]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert string does not contain substring
assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="${3:-Expected to not find '$needle' in '$haystack'}"

  if [[ "$haystack" != *"$needle"* ]]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert file exists
assert_file_exists() {
  local file="$1"
  local message="${2:-Expected file to exist: $file}"

  if [ -f "$file" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert file does not exist
assert_file_not_exists() {
  local file="$1"
  local message="${2:-Expected file to not exist: $file}"

  if [ ! -f "$file" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert directory exists
assert_dir_exists() {
  local dir="$1"
  local message="${2:-Expected directory to exist: $dir}"

  if [ -d "$dir" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert directory does not exist
assert_dir_not_exists() {
  local dir="$1"
  local message="${2:-Expected directory to not exist: $dir}"

  if [ ! -d "$dir" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert exit code is zero (success)
assert_exit_success() {
  local exit_code="$1"
  local message="${2:-Expected command to succeed (exit 0) but got exit $exit_code}"

  if [ "$exit_code" -eq 0 ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert exit code is non-zero (failure)
assert_exit_failure() {
  local exit_code="$1"
  local message="${2:-Expected command to fail (exit non-zero) but got exit $exit_code}"

  if [ "$exit_code" -ne 0 ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert exit code matches specific value
assert_exit_code() {
  local expected="$1"
  local actual="$2"
  local message="${3:-Expected exit code $expected but got $actual}"

  if [ "$expected" -eq "$actual" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert command succeeds
assert_success() {
  local cmd="$*"

  if eval "$cmd" >/dev/null 2>&1; then
    return 0
  else
    test_fail "Command failed: $cmd"
    return 1
  fi
}

# Assert command fails
assert_failure() {
  local cmd="$*"

  if ! eval "$cmd" >/dev/null 2>&1; then
    return 0
  else
    test_fail "Command succeeded (expected failure): $cmd"
    return 1
  fi
}

# Assert string matches regex
assert_matches() {
  local string="$1"
  local pattern="$2"
  local message="${3:-Expected '$string' to match pattern '$pattern'}"

  if [[ "$string" =~ $pattern ]]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert value is empty
assert_empty() {
  local value="$1"
  local message="${2:-Expected value to be empty}"

  if [ -z "$value" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert value is not empty
assert_not_empty() {
  local value="$1"
  local message="${2:-Expected value to not be empty}"

  if [ -n "$value" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert valid JSON
assert_valid_json() {
  local json="$1"
  local message="${2:-Expected valid JSON}"

  if command -v jq &>/dev/null; then
    if echo "$json" | jq empty >/dev/null 2>&1; then
      return 0
    else
      test_fail "$message"
      return 1
    fi
  else
    print_warning "jq not available, skipping JSON validation"
    return 0
  fi
}

# Assert file contains valid JSON
assert_file_valid_json() {
  local file="$1"
  local message="${2:-Expected file to contain valid JSON: $file}"

  if [ ! -f "$file" ]; then
    test_fail "File does not exist: $file"
    return 1
  fi

  if command -v jq &>/dev/null; then
    if jq empty "$file" >/dev/null 2>&1; then
      return 0
    else
      test_fail "$message"
      return 1
    fi
  else
    print_warning "jq not available, skipping JSON validation"
    return 0
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Test Discovery and Execution
# ═══════════════════════════════════════════════════════════════════════════

# Discover test files
discover_tests() {
  local test_pattern="${1:-test-*.sh}"

  # Exclude test-runner.sh itself
  find "$TEST_DIR" -maxdepth 1 -name "$test_pattern" -type f ! -name "test-runner.sh" | sort
}

# Run a single test file
run_test_file() {
  local test_file="$1"
  CURRENT_TEST_FILE="$(basename "$test_file")"

  if [ ! -f "$test_file" ]; then
    print_error "Test file not found: $test_file"
    return 1
  fi

  if [ ! -x "$test_file" ]; then
    print_warning "Test file not executable, making executable: $test_file"
    chmod +x "$test_file"
  fi

  print_info "Running: $CURRENT_TEST_FILE"

  # Set up test environment
  setup_test_env

  # Export variables and test framework functions
  export VERBOSE
  export -f test_start test_pass test_fail
  export -f assert_equal assert_not_equal assert_contains assert_not_contains
  export -f assert_file_exists assert_file_not_exists assert_dir_exists assert_dir_not_exists
  export -f assert_exit_success assert_exit_failure assert_exit_code
  export -f assert_success assert_failure assert_matches
  export -f assert_empty assert_not_empty assert_valid_json assert_file_valid_json
  export -f print_success print_error print_warning print_info print_verbose

  # Run the test file
  local test_exit_code=0
  bash "$test_file" || test_exit_code=$?

  # Aggregate results from results file
  if [ -f "$TEST_RESULTS_FILE" ]; then
    local starts passes fails
    starts=$(grep -c "^START" "$TEST_RESULTS_FILE" 2>/dev/null || echo "0")
    passes=$(grep -c "^PASS" "$TEST_RESULTS_FILE" 2>/dev/null || echo "0")
    fails=$(grep -c "^FAIL:" "$TEST_RESULTS_FILE" 2>/dev/null || echo "0")

    # Ensure values are numeric (strip whitespace, default to 0)
    starts=$(echo "$starts" | tr -d ' ')
    passes=$(echo "$passes" | tr -d ' ')
    fails=$(echo "$fails" | tr -d ' ')

    # Validate and default to 0 if not numeric
    [[ "$starts" =~ ^[0-9]+$ ]] || starts=0
    [[ "$passes" =~ ^[0-9]+$ ]] || passes=0
    [[ "$fails" =~ ^[0-9]+$ ]] || fails=0

    TOTAL_TESTS=$((TOTAL_TESTS + starts))
    PASSED_TESTS=$((PASSED_TESTS + passes))
    FAILED_TESTS=$((FAILED_TESTS + fails))

    if [ "$fails" -eq 0 ] && [ "$test_exit_code" -eq 0 ]; then
      print_success "Completed: $CURRENT_TEST_FILE"
    else
      print_error "Failed: $CURRENT_TEST_FILE"
    fi
  else
    if [ "$test_exit_code" -ne 0 ]; then
      print_error "Crashed: $CURRENT_TEST_FILE"
      FAILED_TESTS=$((FAILED_TESTS + 1))
    else
      print_success "Completed: $CURRENT_TEST_FILE"
    fi
  fi

  # Clean up test environment
  cleanup_test_env

  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# Main Runner
# ═══════════════════════════════════════════════════════════════════════════

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [TEST_FILE...]

Test runner for aiteamforge Homebrew Tap

OPTIONS:
  -v, --verbose     Verbose output (show each test)
  -h, --help        Show this help message

ARGUMENTS:
  TEST_FILE         Specific test file(s) to run
                    If not specified, runs all test-*.sh files

EXAMPLES:
  # Run all tests
  $(basename "$0")

  # Run specific test file
  $(basename "$0") test-cli.sh

  # Run multiple test files with verbose output
  $(basename "$0") -v test-cli.sh test-config.sh

  # Run all tests with verbose output
  $(basename "$0") --verbose

EOF
}

main() {
  local test_files=()

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose)
        VERBOSE=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
      *)
        test_files+=("$1")
        shift
        ;;
    esac
  done

  # Print banner
  echo ""
  echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  AITeamForge Homebrew Tap Test Suite${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
  echo ""

  # Discover tests if no specific files provided
  if [ ${#test_files[@]} -eq 0 ]; then
    print_info "Discovering tests..."
    while IFS= read -r test_file; do
      test_files+=("$test_file")
    done < <(discover_tests)
  else
    # Convert relative paths to absolute
    local resolved_files=()
    for test_file in "${test_files[@]}"; do
      if [ -f "$test_file" ]; then
        resolved_files+=("$test_file")
      elif [ -f "$TEST_DIR/$test_file" ]; then
        resolved_files+=("$TEST_DIR/$test_file")
      else
        print_error "Test file not found: $test_file"
        exit 1
      fi
    done
    test_files=("${resolved_files[@]}")
  fi

  if [ ${#test_files[@]} -eq 0 ]; then
    print_warning "No test files found matching pattern: test-*.sh"
    exit 0
  fi

  print_info "Found ${#test_files[@]} test file(s)"
  echo ""

  # Run tests
  for test_file in "${test_files[@]}"; do
    run_test_file "$test_file"
  done

  # Print summary
  echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  Test Summary${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  Total Tests:  $TOTAL_TESTS"
  echo -e "  ${GREEN}Passed:       $PASSED_TESTS${NC}"

  if [ $FAILED_TESTS -gt 0 ]; then
    echo -e "  ${RED}Failed:       $FAILED_TESTS${NC}"
  else
    echo -e "  Failed:       $FAILED_TESTS"
  fi

  echo ""

  # Exit with appropriate code
  if [ $FAILED_TESTS -eq 0 ]; then
    print_success "All tests passed!"
    echo ""
    exit 0
  else
    print_error "$FAILED_TESTS test(s) failed"
    echo ""
    exit 1
  fi
}

# Run main if executed directly
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
  main "$@"
fi
