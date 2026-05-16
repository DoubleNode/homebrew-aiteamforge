#!/bin/bash

# test-xaca-0510-launchagent-render.sh
# Tests for update_launchagents() render-from-template logic (XACA-0510).
#
# All filesystem activity is sandboxed to $TEST_TMP_DIR.
# NEVER touches ~/Library/LaunchAgents — see M3Pro install-ban rule.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
TEMPLATES_DIR="$TAP_ROOT/share/templates/kanban"

# ═══════════════════════════════════════════════════════════════════════════
# Sandbox setup
# ═══════════════════════════════════════════════════════════════════════════

SANDBOX_DIR="$TEST_TMP_DIR/xaca0510"
FAKE_LAUNCHAGENTS="$SANDBOX_DIR/LaunchAgents"
FAKE_FRAMEWORK="$SANDBOX_DIR/framework"
FAKE_WORKING="$SANDBOX_DIR/working"

mkdir -p "$FAKE_LAUNCHAGENTS"
mkdir -p "$FAKE_FRAMEWORK/share/templates/kanban"
mkdir -p "$FAKE_WORKING"

# Copy real templates into sandbox framework
cp "$TEMPLATES_DIR/backup-plist.template"     "$FAKE_FRAMEWORK/share/templates/kanban/"
cp "$TEMPLATES_DIR/lcars-health-plist.template" "$FAKE_FRAMEWORK/share/templates/kanban/"

# ═══════════════════════════════════════════════════════════════════════════
# Load only the two helper functions from upgrade.sh.
# We extract them rather than sourcing the whole script, because the script
# main body has side effects (is_configured, get_framework_dir calls, etc.).
# ═══════════════════════════════════════════════════════════════════════════

# Stubs for upgrade.sh's print helpers — these are exported by test-runner.sh
# (print_success / print_error / print_warning / print_info) but the script
# also uses print_section. Provide a no-op if not already defined.
if ! declare -f print_section >/dev/null 2>&1; then
  print_section() { :; }
fi

# No-op launchctl stub — CRITICAL: must never call the real launchctl here.
# Override before extracting functions so any inline call during source is safe.
launchctl() { return 0; }
export -f launchctl

# Extract and eval _render_launchagent_template + update_launchagents from
# upgrade.sh using awk. We grab from the render helper comment through to
# the closing brace of update_launchagents.
_extracted_funcs="$(awk '
  /^# Render a LaunchAgent template/ { capture=1 }
  capture { print }
  /^}$/ && capture {
    brace_count++
    if (brace_count == 2) { capture=0 }
  }
' "$UPGRADE_SH")"

if [ -z "$_extracted_funcs" ]; then
  test_start "Sanity: can extract functions from upgrade.sh"
  test_fail "Failed to extract _render_launchagent_template and update_launchagents — awk returned empty"
  return 0
fi

eval "$_extracted_funcs"

# Verify both functions are now defined
if ! declare -f _render_launchagent_template >/dev/null 2>&1; then
  test_start "Sanity: _render_launchagent_template defined"
  test_fail "_render_launchagent_template not defined after extraction"
  return 0
fi
if ! declare -f update_launchagents >/dev/null 2>&1; then
  test_start "Sanity: update_launchagents defined"
  test_fail "update_launchagents not defined after extraction"
  return 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# Helper: run update_launchagents with our sandbox variables injected
# ═══════════════════════════════════════════════════════════════════════════

# shellcheck disable=SC2120,SC2119
run_update_launchagents() {
  # Callers set FORCE / DRY_RUN before calling this wrapper.
  # update_launchagents takes no positional arguments.
  FRAMEWORK_DIR="$FAKE_FRAMEWORK" \
  WORKING_DIR="$FAKE_WORKING" \
  LAUNCHAGENTS_DIR="$FAKE_LAUNCHAGENTS" \
  HOME="$SANDBOX_DIR/home" \
  KANBAN_BACKUP_INTERVAL="900" \
  update_launchagents 2>&1
}

# Reset sandbox LaunchAgents dir between tests
reset_launchagents() {
  rm -rf "$FAKE_LAUNCHAGENTS"
  mkdir -p "$FAKE_LAUNCHAGENTS"
}

BACKUP_PLIST="$FAKE_LAUNCHAGENTS/com.aiteamforge.kanban-backup.plist"
LCARS_PLIST="$FAKE_LAUNCHAGENTS/com.aiteamforge.lcars-health.plist"

# ═══════════════════════════════════════════════════════════════════════════
# TEST 1: Missing targets — both agents absent → both skipped (opt-in guard)
# ═══════════════════════════════════════════════════════════════════════════

test_start "Missing targets: both plists absent → function skips both"
reset_launchagents
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "$BACKUP_PLIST" "kanban-backup.plist should not be created when absent"
assert_file_not_exists "$LCARS_PLIST"  "lcars-health.plist should not be created when absent"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 2: Fresh render — sentinel target present → function renders content
# ═══════════════════════════════════════════════════════════════════════════

test_start "Fresh render: sentinel target present → renders and writes plist"
reset_launchagents
# Simulate user having previously installed the kanban-backup agent
touch "$BACKUP_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_exists "$BACKUP_PLIST" "kanban-backup.plist should exist after render"
test_pass

test_start "Fresh render: rendered plist contains resolved HOME value (no placeholder)"
reset_launchagents
touch "$BACKUP_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
content="$(cat "$BACKUP_PLIST")"
assert_not_contains "$content" "{{USER_HOME}}" "Rendered plist must not contain {{USER_HOME}} placeholder"
assert_not_contains "$content" "{{AITEAMFORGE_DIR}}" "Rendered plist must not contain {{AITEAMFORGE_DIR}} placeholder"
assert_not_contains "$content" "{{BACKUP_INTERVAL}}" "Rendered plist must not contain {{BACKUP_INTERVAL}} placeholder"
assert_not_contains "$content" "{{PYTHON3_PATH}}" "Rendered plist must not contain {{PYTHON3_PATH}} placeholder"
test_pass

test_start "Fresh render: rendered plist contains resolved AITEAMFORGE_DIR (WORKING_DIR)"
reset_launchagents
touch "$BACKUP_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
content="$(cat "$BACKUP_PLIST")"
assert_contains "$content" "$FAKE_WORKING" "Rendered plist must contain resolved WORKING_DIR path"
test_pass

test_start "Fresh render: lcars-health target absent → not rendered"
reset_launchagents
touch "$BACKUP_PLIST"
# lcars-health plist NOT touched — should still be absent after run
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "$LCARS_PLIST" "lcars-health.plist should not be created when absent"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 3: No-op on second run — same template → unchanged file
# ═══════════════════════════════════════════════════════════════════════════

test_start "No-op: second run with same template produces no tempfile leak"
reset_launchagents
touch "$BACKUP_PLIST"
# First run — renders content
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
mtime_first="$(stat -f '%m' "$BACKUP_PLIST" 2>/dev/null || stat -c '%Y' "$BACKUP_PLIST" 2>/dev/null)"
# Brief sleep to allow mtime to change if file were rewritten
sleep 1
# Second run — should be a no-op diff, file untouched
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
mtime_second="$(stat -f '%m' "$BACKUP_PLIST" 2>/dev/null || stat -c '%Y' "$BACKUP_PLIST" 2>/dev/null)"
assert_equal "$mtime_first" "$mtime_second" "File mtime should be unchanged on no-op second run"
# Verify no *.new tempfile leaked
assert_file_not_exists "${BACKUP_PLIST}.new" "No .new tempfile should remain after no-op run"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 4: FORCE=true → re-renders even when target is up to date
# ═══════════════════════════════════════════════════════════════════════════

test_start "FORCE=true: re-renders plist even when target is up to date"
reset_launchagents
touch "$BACKUP_PLIST"
# First run to render proper content
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
mtime_first="$(stat -f '%m' "$BACKUP_PLIST" 2>/dev/null || stat -c '%Y' "$BACKUP_PLIST" 2>/dev/null)"
sleep 1
# Force run — should rewrite even when content identical
FORCE=true DRY_RUN=false run_update_launchagents >/dev/null 2>&1
mtime_force="$(stat -f '%m' "$BACKUP_PLIST" 2>/dev/null || stat -c '%Y' "$BACKUP_PLIST" 2>/dev/null)"
assert_not_equal "$mtime_first" "$mtime_force" "File mtime should change after FORCE=true run"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 5: DRY_RUN=true → writes nothing to target
# ═══════════════════════════════════════════════════════════════════════════

test_start "DRY_RUN=true: writes nothing to target plist"
reset_launchagents
# Place a known sentinel content in the target so we can detect if it changed
echo "SENTINEL_DO_NOT_OVERWRITE" > "$BACKUP_PLIST"
output="$(FORCE=false DRY_RUN=true run_update_launchagents 2>&1)"
content="$(cat "$BACKUP_PLIST")"
assert_equal "SENTINEL_DO_NOT_OVERWRITE" "$content" "DRY_RUN must not overwrite target plist"
test_pass

test_start "DRY_RUN=true: prints 'Would update' for agent that would change"
reset_launchagents
echo "SENTINEL_DO_NOT_OVERWRITE" > "$BACKUP_PLIST"
output="$(FORCE=false DRY_RUN=true run_update_launchagents 2>&1)"
assert_contains "$output" "Would update" "DRY_RUN must print 'Would update' for changed agent"
test_pass

test_start "DRY_RUN=true: no .new tempfile leaked after run"
reset_launchagents
echo "SENTINEL_DO_NOT_OVERWRITE" > "$BACKUP_PLIST"
FORCE=false DRY_RUN=true run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "${BACKUP_PLIST}.new" "No .new tempfile should remain after DRY_RUN run"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 6: Missing template → reports cleanly without aborting
# ═══════════════════════════════════════════════════════════════════════════

test_start "Missing template: function reports warning and continues without crash"
reset_launchagents
touch "$BACKUP_PLIST"
touch "$LCARS_PLIST"

# Remove backup template to simulate missing template
MISSING_FRAMEWORK="$SANDBOX_DIR/framework-missing"
mkdir -p "$MISSING_FRAMEWORK/share/templates/kanban"
# Only copy lcars-health template; leave backup-plist.template absent
cp "$TEMPLATES_DIR/lcars-health-plist.template" "$MISSING_FRAMEWORK/share/templates/kanban/"

set +e
output="$(FRAMEWORK_DIR="$MISSING_FRAMEWORK" \
          WORKING_DIR="$FAKE_WORKING" \
          LAUNCHAGENTS_DIR="$FAKE_LAUNCHAGENTS" \
          HOME="$SANDBOX_DIR/home" \
          KANBAN_BACKUP_INTERVAL="900" \
          FORCE=false DRY_RUN=false \
          update_launchagents 2>&1)"
exit_code=$?
set -e

assert_exit_success "$exit_code" "update_launchagents must not crash when a template is missing"
assert_contains "$output" "not found" "Missing template should produce a 'not found' warning"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 7: Both sentinels present → both rendered and no placeholders remain
# ═══════════════════════════════════════════════════════════════════════════

test_start "Both sentinels present: both plists rendered with no placeholders"
reset_launchagents
touch "$BACKUP_PLIST"
touch "$LCARS_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
backup_content="$(cat "$BACKUP_PLIST")"
lcars_content="$(cat "$LCARS_PLIST")"
assert_not_contains "$backup_content" "{{" "kanban-backup.plist must contain no {{ placeholders"
assert_not_contains "$lcars_content"  "{{" "lcars-health.plist must contain no {{ placeholders"
test_pass
