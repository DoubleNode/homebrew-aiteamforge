#!/bin/bash

# test-xaca-0512-migrate-launchagent-render.sh
# Tests for aiteamforge-migrate.sh::update_launchagents() render-from-template
# logic (XACA-0512). Sibling of test-xaca-0510-launchagent-render.sh — covers
# the three-agent case with per-template-family dispatch (kanban vs fleet-monitor).
#
# All filesystem activity is sandboxed to $TEST_TMP_DIR.
# NEVER touches ~/Library/LaunchAgents — see M3Pro install-ban rule.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MIGRATE_SH="$TAP_ROOT/libexec/commands/aiteamforge-migrate.sh"
KANBAN_TEMPLATES_DIR="$TAP_ROOT/share/templates/kanban"
FLEET_TEMPLATES_DIR="$TAP_ROOT/share/templates/fleet-monitor"

# ═══════════════════════════════════════════════════════════════════════════
# Sandbox setup
# ═══════════════════════════════════════════════════════════════════════════

SANDBOX_DIR="$TEST_TMP_DIR/xaca0512"
FAKE_LAUNCHAGENTS="$SANDBOX_DIR/LaunchAgents"
FAKE_FRAMEWORK="$SANDBOX_DIR/framework"
FAKE_NEW_DATA="$SANDBOX_DIR/.aiteamforge"

mkdir -p "$FAKE_LAUNCHAGENTS"
mkdir -p "$FAKE_FRAMEWORK/share/templates/kanban"
mkdir -p "$FAKE_FRAMEWORK/share/templates/fleet-monitor"
mkdir -p "$FAKE_NEW_DATA"

# Copy real templates into sandbox framework
cp "$KANBAN_TEMPLATES_DIR/backup-plist.template"        "$FAKE_FRAMEWORK/share/templates/kanban/"
cp "$KANBAN_TEMPLATES_DIR/lcars-health-plist.template"  "$FAKE_FRAMEWORK/share/templates/kanban/"
cp "$FLEET_TEMPLATES_DIR/fleet-launchagent.template.plist" "$FAKE_FRAMEWORK/share/templates/fleet-monitor/"

# ═══════════════════════════════════════════════════════════════════════════
# Load only the helper functions from migrate.sh. The script main body has
# side effects (sets up MIGRATION_LOG redirects, parses argv) so we extract
# the four functions we care about instead of sourcing.
# ═══════════════════════════════════════════════════════════════════════════

# Stub print/log helpers if test-runner.sh hasn't defined them.
if ! declare -f section  >/dev/null 2>&1; then section()  { :; }; fi
if ! declare -f info     >/dev/null 2>&1; then info()     { echo "$@"; }; fi
if ! declare -f success  >/dev/null 2>&1; then success()  { echo "$@"; }; fi
if ! declare -f warning  >/dev/null 2>&1; then warning()  { echo "$@" >&2; }; fi
if ! declare -f log      >/dev/null 2>&1; then log()      { echo "$@"; }; fi

# Stub get_framework_dir — overridden per-call via FRAMEWORK_DIR env injection,
# but the function needs to *exist* for the unsourced extraction to evaluate.
get_framework_dir() { echo "$FAKE_FRAMEWORK"; }

# No-op launchctl stub — CRITICAL: must never call the real launchctl here.
launchctl() { return 0; }
export -f launchctl

# No-op brew stub so _render_fleet_template doesn't depend on host brew prefix.
brew() {
  if [ "$1" = "--prefix" ]; then echo "/opt/homebrew"; return 0; fi
  return 0
}
export -f brew

# Extract from the cleanup helper comment through update_launchagents (4 funcs,
# 4 closing top-level braces).
_extracted_funcs="$(awk '
  /^# Cleanup helper invoked by update_launchagents/ { capture=1 }
  capture { print }
  /^}$/ && capture {
    brace_count++
    if (brace_count == 4) { capture=0 }
  }
' "$MIGRATE_SH")"

if [ -z "$_extracted_funcs" ]; then
  test_start "Sanity: can extract functions from migrate.sh"
  test_fail "Failed to extract helpers + update_launchagents from migrate.sh — awk returned empty"
  return 0
fi

# Defaults that the extracted functions reference (normally set at script top).
# shellcheck disable=SC2034  # referenced by eval'd functions; shellcheck can't trace eval
readonly XACA_0512_KANBAN_BACKUP_INTERVAL_DEFAULT=900
# shellcheck disable=SC2034  # referenced by eval'd functions; shellcheck can't trace eval
readonly XACA_0512_FLEET_MONITOR_PORT_DEFAULT=3000

eval "$_extracted_funcs"

# Hard precondition: abort loudly if extraction was incomplete.
declare -f _cleanup_migrate_tmpfiles  >/dev/null || \
  { echo "FATAL: _cleanup_migrate_tmpfiles not extracted from migrate.sh"; exit 1; }
declare -f _render_kanban_template    >/dev/null || \
  { echo "FATAL: _render_kanban_template not extracted from migrate.sh"; exit 1; }
declare -f _render_fleet_template     >/dev/null || \
  { echo "FATAL: _render_fleet_template not extracted from migrate.sh"; exit 1; }
declare -f update_launchagents        >/dev/null || \
  { echo "FATAL: update_launchagents not extracted from migrate.sh"; exit 1; }

# ═══════════════════════════════════════════════════════════════════════════
# Helper: run update_launchagents with our sandbox variables injected
# ═══════════════════════════════════════════════════════════════════════════

# shellcheck disable=SC2120,SC2119
run_update_launchagents() {
  FRAMEWORK_DIR="$FAKE_FRAMEWORK" \
  NEW_DATA_DIR="$FAKE_NEW_DATA" \
  LAUNCHAGENTS_DIR="$FAKE_LAUNCHAGENTS" \
  HOME="$SANDBOX_DIR/home" \
  KANBAN_BACKUP_INTERVAL="900" \
  FLEET_MONITOR_PORT="3000" \
  update_launchagents 2>&1
}

reset_launchagents() {
  rm -rf "$FAKE_LAUNCHAGENTS"
  mkdir -p "$FAKE_LAUNCHAGENTS"
}

BACKUP_PLIST="$FAKE_LAUNCHAGENTS/com.aiteamforge.kanban-backup.plist"
LCARS_PLIST="$FAKE_LAUNCHAGENTS/com.aiteamforge.lcars-health.plist"
FLEET_PLIST="$FAKE_LAUNCHAGENTS/com.aiteamforge.fleet-monitor.plist"

# ═══════════════════════════════════════════════════════════════════════════
# TEST 1: Missing targets — all three absent → all three skipped (opt-in guard)
# ═══════════════════════════════════════════════════════════════════════════

test_start "Missing targets: all three plists absent → function skips all"
reset_launchagents
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "$BACKUP_PLIST" "kanban-backup.plist must not be created when absent"
assert_file_not_exists "$LCARS_PLIST"  "lcars-health.plist must not be created when absent"
assert_file_not_exists "$FLEET_PLIST"  "fleet-monitor.plist must not be created when absent"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 2: In-place sed regression — old code did `sed -i.bak`, creating .bak
# files. Render-from-template flow must NOT leave .bak or .bak2 droppings.
# ═══════════════════════════════════════════════════════════════════════════

test_start "Regression: no .bak/.bak2 files left behind (old sed -i.bak behavior gone)"
reset_launchagents
touch "$BACKUP_PLIST"
touch "$LCARS_PLIST"
touch "$FLEET_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "${BACKUP_PLIST}.bak"  "kanban-backup.plist.bak must not exist (sed -i.bak removed)"
assert_file_not_exists "${BACKUP_PLIST}.bak2" "kanban-backup.plist.bak2 must not exist (sed -i.bak2 removed)"
assert_file_not_exists "${FLEET_PLIST}.bak"   "fleet-monitor.plist.bak must not exist (sed -i.bak removed)"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 3: Fresh render — kanban targets present → rendered, no placeholders
# ═══════════════════════════════════════════════════════════════════════════

test_start "Fresh render: kanban plists rendered with no {{...}} placeholders"
reset_launchagents
touch "$BACKUP_PLIST"
touch "$LCARS_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
backup_content="$(cat "$BACKUP_PLIST")"
lcars_content="$(cat "$LCARS_PLIST")"
assert_not_contains "$backup_content" "{{" "kanban-backup.plist must contain no {{ placeholders"
assert_not_contains "$lcars_content"  "{{" "lcars-health.plist must contain no {{ placeholders"
test_pass

test_start "Fresh render: kanban plists contain resolved NEW_DATA_DIR path"
reset_launchagents
touch "$BACKUP_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
backup_content="$(cat "$BACKUP_PLIST")"
assert_contains "$backup_content" "$FAKE_NEW_DATA" "kanban-backup.plist must contain resolved NEW_DATA_DIR (migrate uses NEW_DATA_DIR, not WORKING_DIR)"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 4: Fleet-monitor template (the migrate-specific wrinkle) — separate
# template dir, different substitution map.
# ═══════════════════════════════════════════════════════════════════════════

test_start "Fleet-monitor: target present → rendered from fleet-monitor template dir"
reset_launchagents
touch "$FLEET_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_exists "$FLEET_PLIST" "fleet-monitor.plist must exist after render"
fleet_content="$(cat "$FLEET_PLIST")"
assert_not_contains "$fleet_content" "{{" "fleet-monitor.plist must contain no {{ placeholders"
test_pass

test_start "Fleet-monitor: rendered plist contains all fleet-specific substitutions"
reset_launchagents
touch "$FLEET_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
fleet_content="$(cat "$FLEET_PLIST")"
assert_not_contains "$fleet_content" "{{NODE_PATH}}"         "{{NODE_PATH}} placeholder must be substituted"
assert_not_contains "$fleet_content" "{{FLEET_SERVER_PATH}}" "{{FLEET_SERVER_PATH}} placeholder must be substituted"
assert_not_contains "$fleet_content" "{{LOG_DIR}}"           "{{LOG_DIR}} placeholder must be substituted"
assert_not_contains "$fleet_content" "{{HOMEBREW_PREFIX}}"   "{{HOMEBREW_PREFIX}} placeholder must be substituted"
assert_not_contains "$fleet_content" "{{HOME_DIR}}"          "{{HOME_DIR}} placeholder must be substituted"
assert_not_contains "$fleet_content" "{{FLEET_PORT}}"        "{{FLEET_PORT}} placeholder must be substituted"
assert_not_contains "$fleet_content" "{{AITEAMFORGE_DIR}}"   "{{AITEAMFORGE_DIR}} placeholder must be substituted"
test_pass

test_start "Fleet-monitor: rendered plist contains resolved FLEET_PORT default (3000)"
reset_launchagents
touch "$FLEET_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
fleet_content="$(cat "$FLEET_PLIST")"
assert_contains "$fleet_content" "<string>3000</string>" "fleet-monitor.plist must contain resolved FLEET_PORT value"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 5: Selective opt-in — kanban present, fleet absent → only kanban rendered
# ═══════════════════════════════════════════════════════════════════════════

test_start "Selective opt-in: kanban-backup present, fleet absent → fleet not materialised"
reset_launchagents
touch "$BACKUP_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_exists     "$BACKUP_PLIST" "kanban-backup.plist must be rendered (was present)"
assert_file_not_exists "$LCARS_PLIST"  "lcars-health.plist must not be created (was absent)"
assert_file_not_exists "$FLEET_PLIST"  "fleet-monitor.plist must not be created (was absent)"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 6: No-op on second run — same template → unchanged file
# ═══════════════════════════════════════════════════════════════════════════

test_start "No-op: second run with same template leaves file mtime unchanged"
reset_launchagents
touch "$BACKUP_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
mtime_first="$(stat -f '%m' "$BACKUP_PLIST" 2>/dev/null || stat -c '%Y' "$BACKUP_PLIST" 2>/dev/null)"
sleep 1
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
mtime_second="$(stat -f '%m' "$BACKUP_PLIST" 2>/dev/null || stat -c '%Y' "$BACKUP_PLIST" 2>/dev/null)"
assert_equal "$mtime_first" "$mtime_second" "File mtime must be unchanged on no-op second run"
assert_file_not_exists "${BACKUP_PLIST}.new" "No .new tempfile must remain after no-op run"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 7: FORCE=true → re-renders even when target is up to date
# ═══════════════════════════════════════════════════════════════════════════

test_start "FORCE=true: re-renders plist even when target is up to date"
reset_launchagents
touch "$BACKUP_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
mtime_first="$(stat -f '%m' "$BACKUP_PLIST" 2>/dev/null || stat -c '%Y' "$BACKUP_PLIST" 2>/dev/null)"
sleep 1
FORCE=true DRY_RUN=false run_update_launchagents >/dev/null 2>&1
mtime_force="$(stat -f '%m' "$BACKUP_PLIST" 2>/dev/null || stat -c '%Y' "$BACKUP_PLIST" 2>/dev/null)"
assert_not_equal "$mtime_first" "$mtime_force" "File mtime must change after FORCE=true run"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 8: DRY_RUN=true → writes nothing to target
# ═══════════════════════════════════════════════════════════════════════════

test_start "DRY_RUN=true: writes nothing to target plist"
reset_launchagents
echo "SENTINEL_DO_NOT_OVERWRITE" > "$BACKUP_PLIST"
FORCE=false DRY_RUN=true run_update_launchagents >/dev/null 2>&1
content="$(cat "$BACKUP_PLIST")"
assert_equal "SENTINEL_DO_NOT_OVERWRITE" "$content" "DRY_RUN must not overwrite target plist"
test_pass

test_start "DRY_RUN=true: prints '[DRY RUN] Would update' for changed agent"
reset_launchagents
echo "SENTINEL_DO_NOT_OVERWRITE" > "$BACKUP_PLIST"
output="$(FORCE=false DRY_RUN=true run_update_launchagents 2>&1)"
assert_contains "$output" "Would update" "DRY_RUN must print 'Would update' for changed agent"
test_pass

test_start "DRY_RUN=true: no .new tempfile leaked after run"
reset_launchagents
echo "SENTINEL_DO_NOT_OVERWRITE" > "$BACKUP_PLIST"
FORCE=false DRY_RUN=true run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "${BACKUP_PLIST}.new" "No .new tempfile must remain after DRY_RUN run"
test_pass

# Per-renderer DRY_RUN coverage — the three tests above all exercise
# _render_kanban_template via the kanban-backup target. The fleet-monitor
# target routes through _render_fleet_template, which has a different
# substitution map. XACA-0512-002 [Review] from PR #32 — exercise DRY_RUN
# on the fleet-monitor path so a regression in the fleet renderer's
# DRY_RUN handling can't slip through.

test_start "DRY_RUN=true (fleet-monitor): sentinel preserved, no .new leak, 'Would update' printed"
reset_launchagents
echo "FLEET_SENTINEL_DO_NOT_OVERWRITE" > "$FLEET_PLIST"
output="$(FORCE=false DRY_RUN=true run_update_launchagents 2>&1)"
fleet_content="$(cat "$FLEET_PLIST")"
assert_equal "FLEET_SENTINEL_DO_NOT_OVERWRITE" "$fleet_content" "DRY_RUN must not overwrite fleet-monitor target plist"
assert_file_not_exists "${FLEET_PLIST}.new" "No .new tempfile must remain after fleet-monitor DRY_RUN run"
assert_contains "$output" "fleet-monitor" "DRY_RUN output must reference fleet-monitor agent"
assert_contains "$output" "Would update" "DRY_RUN must print 'Would update' for fleet-monitor change"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 9: Missing template → reports cleanly without aborting
# ═══════════════════════════════════════════════════════════════════════════

test_start "Missing template: function reports warning and continues without crash"
reset_launchagents
touch "$BACKUP_PLIST"
touch "$LCARS_PLIST"

MISSING_FRAMEWORK="$SANDBOX_DIR/framework-missing"
mkdir -p "$MISSING_FRAMEWORK/share/templates/kanban"
mkdir -p "$MISSING_FRAMEWORK/share/templates/fleet-monitor"
# Only copy lcars-health template; leave backup-plist.template absent
cp "$KANBAN_TEMPLATES_DIR/lcars-health-plist.template" "$MISSING_FRAMEWORK/share/templates/kanban/"

set +e
output="$(FRAMEWORK_DIR="$MISSING_FRAMEWORK" \
          NEW_DATA_DIR="$FAKE_NEW_DATA" \
          LAUNCHAGENTS_DIR="$FAKE_LAUNCHAGENTS" \
          HOME="$SANDBOX_DIR/home" \
          KANBAN_BACKUP_INTERVAL="900" \
          FLEET_MONITOR_PORT="3000" \
          FORCE=false DRY_RUN=false \
          update_launchagents 2>&1)"
exit_code=$?
set -e

assert_exit_success "$exit_code" "update_launchagents must not crash when a template is missing"
assert_contains "$output" "not found" "Missing template must produce a 'not found' warning"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 10: All three sentinels present → all three rendered cleanly
# ═══════════════════════════════════════════════════════════════════════════

test_start "All three sentinels: all plists rendered with no placeholders"
reset_launchagents
touch "$BACKUP_PLIST"
touch "$LCARS_PLIST"
touch "$FLEET_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
backup_content="$(cat "$BACKUP_PLIST")"
lcars_content="$(cat "$LCARS_PLIST")"
fleet_content="$(cat "$FLEET_PLIST")"
assert_not_contains "$backup_content" "{{" "kanban-backup.plist must contain no {{ placeholders"
assert_not_contains "$lcars_content"  "{{" "lcars-health.plist must contain no {{ placeholders"
assert_not_contains "$fleet_content"  "{{" "fleet-monitor.plist must contain no {{ placeholders"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 11: DRY_RUN + no-change path — tempfile cleanup, target untouched,
# summary reports "All LaunchAgents up to date".
# ═══════════════════════════════════════════════════════════════════════════

test_start "DRY_RUN=true + no-change: target unchanged, no tempfile, 'up to date' summary"
reset_launchagents
touch "$BACKUP_PLIST"
# Seed target with real rendered content so diff is clean
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
content_before="$(cat "$BACKUP_PLIST")"
output="$(FORCE=false DRY_RUN=true run_update_launchagents 2>&1)"
content_after="$(cat "$BACKUP_PLIST")"
assert_equal "$content_before" "$content_after" "DRY_RUN=true + no-change must leave target file unmodified"
assert_file_not_exists "${BACKUP_PLIST}.new" "No .new tempfile must remain after DRY_RUN no-change run"
assert_contains "$output" "All LaunchAgents up to date" "No-change run must report 'All LaunchAgents up to date'"
test_pass
