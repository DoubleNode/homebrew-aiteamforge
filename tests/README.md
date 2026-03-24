# AITeamForge Homebrew Tap - Test Suite

Comprehensive end-to-end test suite for the aiteamforge Homebrew Tap system. Tests cover everything from CLI dispatch through setup wizard, installers, lifecycle commands, and migration tools.

## Quick Start

```bash
# Run all tests
cd /path/to/homebrew-tap/tests
./test-runner.sh

# Run with verbose output
./test-runner.sh --verbose

# Run specific test file
./test-runner.sh test-cli.sh

# Run multiple specific tests
./test-runner.sh test-cli.sh test-config.sh test-teams.sh
```

## Test Files

### Core Framework Tests

#### `test-cli.sh` - CLI Dispatcher Tests
Tests the main CLI entry point (`bin/aiteamforge-cli.sh`):
- Help and version commands
- Command routing (setup, doctor, status, etc.)
- Unknown command handling
- Configuration requirement checks
- All command flags and options

**Run:** `./test-runner.sh test-cli.sh`

#### `test-wizard-ui.sh` - UI Library Tests
Tests the wizard UI library (`libexec/lib/wizard-ui.sh`):
- Color function outputs
- Print functions (success, error, warning, info)
- Banner generation
- Progress indicators
- Status display functions

**Run:** `./test-runner.sh test-wizard-ui.sh`

#### `test-config.sh` - Configuration Tests
Tests the configuration loader (`libexec/lib/config.sh`):
- Config file reading and validation
- Value getters (nested and top-level)
- Missing file handling
- Invalid JSON detection
- Fallback behavior without jq

**Run:** `./test-runner.sh test-config.sh`

### Configuration Tests

#### `test-teams.sh` - Team Configuration Tests
Tests team definitions (`share/teams/`):
- Registry JSON validity
- All .conf files are parseable
- Required fields in each team definition
- No duplicate team IDs
- Registry ↔ .conf file consistency

**Run:** `./test-runner.sh test-teams.sh`

### Workflow Tests

#### `test-setup-wizard.sh` - Setup Wizard Tests
Tests the interactive setup wizard (`bin/aiteamforge-setup.sh`):
- Command-line flags (--help, --dry-run, etc.)
- Non-interactive mode
- All 7 setup stages execute
- Config generation
- Prerequisite checking

**Run:** `./test-runner.sh test-setup-wizard.sh`

#### `test-lifecycle.sh` - Lifecycle Command Tests
Tests daily-use commands (`libexec/commands/`):
- Doctor (diagnostics)
- Status (--json, --brief modes)
- Start/Stop (graceful handling of missing services)
- Upgrade (--dry-run preview)
- Uninstall (confirmation requirement)

**Run:** `./test-runner.sh test-lifecycle.sh`

#### `test-migration.sh` - Migration Tests
Tests migration tools (`libexec/commands/aiteamforge-migrate*.sh`):
- Migration check (readiness assessment)
- Dry-run migration
- Backup creation
- Risk assessment
- Rollback detection

**Run:** `./test-runner.sh test-migration.sh`

### Installer Tests

#### `test-installers.sh` - Installer Module Tests
Tests all installer modules (`libexec/installers/`):
- Shell environment installer
- Kanban system installer
- Claude config installer
- Fleet monitor installer
- Team configuration installer
- Missing dependency handling
- Unknown team ID handling

**Run:** `./test-runner.sh test-installers.sh`

### End-to-End Tests

#### `test-integration.sh` - Integration Tests
Tests complete workflows:
- Setup → Doctor → Status → Stop → Uninstall flow
- Idempotency (running setup twice)
- Config file validation
- All commands work together
- Dry-run mode throughout

**Run:** `./test-runner.sh test-integration.sh`

## Test Framework

### Test Runner (`test-runner.sh`)

The test runner provides:
- **Test discovery** - Automatically finds `test-*.sh` files
- **Isolated environments** - Each test gets a clean temp directory
- **Assert functions** - Rich set of assertions for validation
- **Result reporting** - Clear pass/fail summary with colors
- **Cleanup** - Automatic cleanup even on test failure

### Assert Functions

```bash
# Equality
assert_equal <expected> <actual> [message]
assert_not_equal <unexpected> <actual> [message]

# String matching
assert_contains <haystack> <needle> [message]
assert_not_contains <haystack> <needle> [message]
assert_matches <string> <regex> [message]

# File system
assert_file_exists <path> [message]
assert_file_not_exists <path> [message]
assert_dir_exists <path> [message]
assert_dir_not_exists <path> [message]

# Exit codes
assert_exit_success <exit_code> [message]
assert_exit_failure <exit_code> [message]
assert_exit_code <expected> <actual> [message]

# Commands
assert_success <command>
assert_failure <command>

# Values
assert_empty <value> [message]
assert_not_empty <value> [message]

# JSON
assert_valid_json <json_string> [message]
assert_file_valid_json <file_path> [message]
```

### Writing a New Test

1. Create `test-yourfeature.sh`:

```bash
#!/bin/bash
# test-yourfeature.sh
# Tests for your feature

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Set up test environment
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
export AITEAMFORGE_HOME="$TAP_ROOT"

# Tests
test_start "Your feature works"
output=$(your_command)
assert_contains "$output" "expected text"
test_pass

test_start "Your feature handles errors"
your_command --invalid 2>&1 || exit_code=$?
assert_exit_failure $exit_code
test_pass

# Always exit 0 for test file
exit 0
```

2. Make it executable:
```bash
chmod +x test-yourfeature.sh
```

3. Run it:
```bash
./test-runner.sh test-yourfeature.sh
```

### Test Isolation

Every test gets a clean environment:
- `$TEST_TMP_DIR` - Isolated temp directory (auto-cleaned)
- `$AITEAMFORGE_DIR` - Points to test-specific directory
- `$AITEAMFORGE_HOME` - Points to tap root
- No modification of real system files

## Test Coverage

| Component | Test File | Coverage |
|-----------|-----------|----------|
| CLI Dispatcher | `test-cli.sh` | ✓ All commands, flags |
| UI Library | `test-wizard-ui.sh` | ✓ All output functions |
| Config Loader | `test-config.sh` | ✓ Reading, validation, fallbacks |
| Team Definitions | `test-teams.sh` | ✓ All .conf files, registry |
| Setup Wizard | `test-setup-wizard.sh` | ✓ All stages, modes |
| Lifecycle Commands | `test-lifecycle.sh` | ✓ Doctor, status, start, stop, upgrade, uninstall |
| Migration | `test-migration.sh` | ✓ Check, migrate, dry-run |
| Installers | `test-installers.sh` | ✓ All installer modules |
| Integration | `test-integration.sh` | ✓ Full workflows |

## CI/CD Integration

### GitHub Actions

```yaml
name: Test AITeamForge Tap

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install dependencies
        run: |
          brew install jq

      - name: Run test suite
        run: |
          cd homebrew-tap/tests
          ./test-runner.sh --verbose
```

### Pre-commit Hook

```bash
#!/bin/bash
# .git/hooks/pre-commit

cd "$(git rev-parse --show-toplevel)/homebrew-tap/tests"
./test-runner.sh

if [ $? -ne 0 ]; then
  echo "Tests failed. Commit aborted."
  exit 1
fi
```

## Troubleshooting

### Tests Fail with "jq not found"

Install jq:
```bash
brew install jq
```

Some tests skip JSON validation if jq is unavailable, but it's recommended for full coverage.

### Tests Fail with "zsh not found"

The setup wizard and UI library use zsh. On macOS, zsh is installed by default. If missing:
```bash
brew install zsh
```

### Temp Directory Not Cleaned Up

The test runner uses `trap` to ensure cleanup. If tests are interrupted (Ctrl+C), cleanup should still occur. If temp files remain:
```bash
rm -rf /tmp/aiteamforge-test.*
```

### Verbose Output Shows Nothing

The `--verbose` flag enables detailed per-test output. Without it, you get dots (`.`) for pass and `F` for fail, with a summary at the end.

### Test Hangs on Interactive Prompt

All tests use `--non-interactive` or `--dry-run` modes to avoid prompts. If a test hangs, it may be calling a script without these flags. Check the test file for proper flag usage.

## Performance

Expected runtime:
- Individual test file: **< 5 seconds**
- Full test suite: **< 60 seconds**

If tests run slower, check:
- Disk I/O (temp directory on slow filesystem)
- External command overhead (jq, zsh initialization)

## Test Philosophy

1. **No Real System Modification** - All tests use isolated temp directories
2. **Fast Feedback** - Tests run in under 60 seconds total
3. **Clear Failures** - Assert messages explain what went wrong
4. **Idempotent** - Tests can run multiple times without side effects
5. **Independent** - Each test file can run standalone
6. **Comprehensive** - Cover happy paths, edge cases, and error conditions

## Contributing

When adding new features to the tap:

1. **Write tests first** (TDD approach preferred)
2. **Update this README** if adding new test files
3. **Ensure < 60s runtime** for full suite
4. **Use existing assert functions** (don't reinvent)
5. **Test isolation** - Always use `$TEST_TMP_DIR`

## License

Same as aiteamforge project (MIT).

---

**Last Updated:** 2026-02-17
**Maintained By:** Academy Team (Lura Thok, Cadet Master - Testing & QA)
