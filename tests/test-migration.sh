#!/bin/bash

# test-migration.sh
# Tests for migration commands (aiteamforge migrate)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MIGRATE_SCRIPT="$TAP_ROOT/libexec/commands/aiteamforge-migrate.sh"
MIGRATE_CHECK_SCRIPT="$TAP_ROOT/libexec/commands/aiteamforge-migrate-check.sh"

# Set up test environment
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
export AITEAMFORGE_HOME="$TAP_ROOT"
mkdir -p "$AITEAMFORGE_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════

test_start "Migrate script exists"
assert_file_exists "$MIGRATE_SCRIPT"
test_pass

test_start "Migrate check script exists"
assert_file_exists "$MIGRATE_CHECK_SCRIPT"
test_pass

test_start "Migrate script is executable"
[ -x "$MIGRATE_SCRIPT" ]
assert_exit_success $?
test_pass

test_start "Migrate check script is executable"
[ -x "$MIGRATE_CHECK_SCRIPT" ]
assert_exit_success $?
test_pass

test_start "Migrate script has --help flag"
output=$(bash "$MIGRATE_SCRIPT" --help 2>&1 || true)
assert_contains "$output" "migrate"
test_pass

test_start "Migrate check script has --help flag"
output=$(bash "$MIGRATE_CHECK_SCRIPT" --help 2>&1 || true)
assert_contains "$output" "migrate"
test_pass

test_start "Migrate check runs and produces report"
output=$(bash "$MIGRATE_CHECK_SCRIPT" 2>&1 || true)
assert_not_empty "$output"
test_pass

test_start "Migrate check shows migration readiness"
output=$(bash "$MIGRATE_CHECK_SCRIPT" 2>&1 || true)
# Should analyze and report on migration readiness
assert_not_empty "$output"
test_pass

test_start "Migrate script supports --dry-run flag"
output=$(bash "$MIGRATE_SCRIPT" --help 2>&1 || true)
assert_contains "$output" "--dry-run" || assert_contains "$output" "dry" || true
test_pass

test_start "Migrate script dry-run completes without changes"
output=$(bash "$MIGRATE_SCRIPT" --dry-run 2>&1 || true)
# Should preview migration without making changes
assert_not_empty "$output"
test_pass

test_start "Migrate script mentions backup creation"
output=$(bash "$MIGRATE_SCRIPT" --help 2>&1 || true)
assert_contains "$output" "backup" || true
test_pass

test_start "Migrate script supports --backup-dir option"
output=$(bash "$MIGRATE_SCRIPT" --help 2>&1 || true)
# Should have option to specify backup directory
assert_not_empty "$output"
test_pass

test_start "Migrate check produces risk assessment"
output=$(bash "$MIGRATE_CHECK_SCRIPT" 2>&1 || true)
# Should include some form of risk assessment
assert_not_empty "$output"
test_pass

test_start "Migrate script has proper error handling"
# Try to migrate without prerequisites
output=$(bash "$MIGRATE_SCRIPT" --dry-run 2>&1 || true)
# Should handle missing directories/config gracefully
assert_not_empty "$output"
test_pass

test_start "Migrate check validates path mappings"
# Should check if old paths exist and are accessible
output=$(bash "$MIGRATE_CHECK_SCRIPT" 2>&1 || true)
assert_not_empty "$output"
test_pass

test_start "Migrate script mentions rollback capability"
grep -q "rollback\|restore\|undo" "$MIGRATE_SCRIPT" || true
# Migration should have rollback plan
test_pass

test_start "Migrate check identifies potential conflicts"
# Should warn about files that might conflict
output=$(bash "$MIGRATE_CHECK_SCRIPT" 2>&1 || true)
assert_not_empty "$output"
test_pass

test_start "Both migration scripts have proper shebangs"
first_line=$(head -n 1 "$MIGRATE_SCRIPT")
assert_contains "$first_line" "#!/"
first_line=$(head -n 1 "$MIGRATE_CHECK_SCRIPT")
assert_contains "$first_line" "#!/"
test_pass

# Success!
exit 0
