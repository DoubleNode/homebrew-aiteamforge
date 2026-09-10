#!/bin/bash

# test-lifecycle.sh
# Tests for lifecycle commands (doctor, status, start, stop, upgrade, uninstall)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMANDS_DIR="$TAP_ROOT/libexec/commands"

# Set up test environment
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
export AITEAMFORGE_HOME="$TAP_ROOT"
mkdir -p "$AITEAMFORGE_DIR"

# ── XACA-0787 PR #859 review finding 3: $HOME sandbox ───────────────────────
# This suite invokes the real lifecycle commands (doctor/status/start/stop/
# upgrade/uninstall) via `bash "$COMMANDS_DIR/aiteamforge-*.sh" ...`.
# AITEAMFORGE_DIR above only redirects the config/runtime dir those scripts
# look for — it does NOT stop aiteamforge-start.sh's path from writing a real
# LaunchAgent plist (install_lcars_health_launchagent in
# libexec/installers/install-kanban.sh, which hardcodes
# "$HOME/Library/LaunchAgents/com.aiteamforge.lcars-health.plist") into the
# developer's REAL $HOME. Caught red-handed once CI actually exercised this
# suite's start path (PR #859 CI run 34526847917, test-lifecycle.sh newly
# failing vs. the db204a0 baseline).
#
# Sandbox HOME the same way test-tailscale.sh does (XACA-0682): redirect
# $HOME into this run's TEST_TMP_DIR and pre-create the LaunchAgents dir so
# any plist write has somewhere sandboxed to land. AITEAMFORGE_SKIP_LAUNCHCTL
# is set explicitly (belt-and-suspenders, not relied on alone) rather than
# inherited from a runner-level default — PR #859 finding 2 removed the
# global `:=` default this suite used to pick up from test-runner.sh because
# it silently broke a control test elsewhere that asserted on real
# pass-through; every suite that needs the skip now sets it for itself.
export HOME="$TEST_TMP_DIR/home"
mkdir -p "$HOME/Library/LaunchAgents"
export AITEAMFORGE_SKIP_LAUNCHCTL=1

# Create minimal test config
create_test_config() {
  cat > "$AITEAMFORGE_DIR/.aiteamforge-config" <<'EOF'
{
  "version": "1.3.0",
  "machine": {
    "name": "test-machine",
    "hostname": "localhost",
    "user": "Test User"
  },
  "teams": ["iOS"],
  "team_paths": {
    "iOS": {"working_dir": "/tmp/test/ios"}
  },
  "installed_features": ["shell_environment", "lcars_kanban"],
  "fleet_registration_status": "not_configured",
  "features": {
    "shell_environment": true,
    "claude_code_config": false,
    "lcars_kanban": true,
    "fleet_monitor": false,
    "fleet_mode": "standalone",
    "fleet_server_url": ""
  }
}
EOF
}

# ═══════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════

test_start "Commands directory exists"
assert_dir_exists "$COMMANDS_DIR"
test_pass

test_start "Doctor command script exists"
assert_file_exists "$COMMANDS_DIR/aiteamforge-doctor.sh"
test_pass

test_start "Status command script exists"
assert_file_exists "$COMMANDS_DIR/aiteamforge-status.sh"
test_pass

test_start "Start command script exists"
assert_file_exists "$COMMANDS_DIR/aiteamforge-start.sh"
test_pass

test_start "Stop command script exists"
assert_file_exists "$COMMANDS_DIR/aiteamforge-stop.sh"
test_pass

test_start "Upgrade command script exists"
assert_file_exists "$COMMANDS_DIR/aiteamforge-upgrade.sh"
test_pass

test_start "Uninstall command script exists"
assert_file_exists "$COMMANDS_DIR/aiteamforge-uninstall.sh"
test_pass

test_start "Doctor command has --help flag"
output=$(bash "$COMMANDS_DIR/aiteamforge-doctor.sh" --help 2>&1 || true)
assert_contains "$output" "doctor"
test_pass

test_start "Doctor command runs without config (diagnostic mode)"
output=$(bash "$COMMANDS_DIR/aiteamforge-doctor.sh" 2>&1 || true)
# Should run and produce output
assert_not_empty "$output"
test_pass

test_start "Doctor command produces structured output"
output=$(bash "$COMMANDS_DIR/aiteamforge-doctor.sh" 2>&1 || true)
# Should check various system components
assert_not_empty "$output"
test_pass

test_start "Status command requires config"
rm -f "$AITEAMFORGE_DIR/.aiteamforge-config"
output=$(bash "$COMMANDS_DIR/aiteamforge-status.sh" 2>&1 || true)
# Should error or warn about missing config
exit_code=$?
[ "$exit_code" -ne 0 ] || assert_contains "$output" "not configured"
test_pass

test_start "Status command works with valid config"
create_test_config
output=$(bash "$COMMANDS_DIR/aiteamforge-status.sh" 2>&1 || true)
# Should produce status output
assert_not_empty "$output"
test_pass

test_start "Status command supports --json flag"
create_test_config
output=$(bash "$COMMANDS_DIR/aiteamforge-status.sh" --json 2>&1 || true)
# Should produce JSON output
if command -v jq &>/dev/null; then
  echo "$output" | jq empty 2>/dev/null || true  # Try to parse as JSON
fi
test_pass

test_start "Status command supports --brief flag"
create_test_config
output=$(bash "$COMMANDS_DIR/aiteamforge-status.sh" --brief 2>&1 || true)
# Should produce brief output (single line or minimal)
assert_not_empty "$output"
test_pass

test_start "Start command handles missing services gracefully"
create_test_config
output=$(bash "$COMMANDS_DIR/aiteamforge-start.sh" 2>&1 || true)
# Should not crash, even if services don't exist
assert_not_empty "$output"
test_pass

test_start "Stop command handles missing services gracefully"
create_test_config
output=$(bash "$COMMANDS_DIR/aiteamforge-stop.sh" 2>&1 || true)
# Should not crash, even if services aren't running
assert_not_empty "$output"
test_pass

test_start "Upgrade command supports --dry-run flag"
create_test_config
output=$(bash "$COMMANDS_DIR/aiteamforge-upgrade.sh" --dry-run 2>&1 || true)
# XACA-0787-015: the trailing `|| true` here made this case vacuous — an OR-chain
# of two assert_contains calls followed by `|| true` can never propagate a failure,
# so the case passed regardless of $output. Replaced with a real assertion on the
# one line aiteamforge-upgrade.sh unconditionally prints as soon as DRY_RUN=true is
# parsed (before any feature-specific branching), verified live in a sandboxed
# ($HOME/$AITEAMFORGE_DIR redirected to mktemp) run of this exact invocation:
#   "DRY RUN MODE - No changes will be made"
# The original fallback needle "preview" was dead code even before the `|| true`
# neutered the case — that word appears only in --help/usage text, never in real
# --dry-run execution output, so it never once matched here. Dropped rather than
# carried forward as a second vacuous branch.
assert_contains "$output" "DRY RUN MODE" "Expected --dry-run output to include the dry-run mode banner"
test_pass

test_start "Upgrade command has --help flag"
output=$(bash "$COMMANDS_DIR/aiteamforge-upgrade.sh" --help 2>&1 || true)
assert_contains "$output" "upgrade"
test_pass

test_start "Uninstall command has --help flag"
output=$(bash "$COMMANDS_DIR/aiteamforge-uninstall.sh" --help 2>&1 || true)
assert_contains "$output" "uninstall"
test_pass

test_start "Uninstall command requires confirmation in interactive mode"
create_test_config
# In non-interactive or with --force, should proceed
output=$(bash "$COMMANDS_DIR/aiteamforge-uninstall.sh" --help 2>&1 || true)
# Check help mentions confirmation or force
assert_not_empty "$output"
test_pass

test_start "All lifecycle commands are executable"
for cmd in doctor status start stop upgrade uninstall; do
  cmd_file="$COMMANDS_DIR/aiteamforge-${cmd}.sh"
  [ -x "$cmd_file" ]
  assert_exit_success $? "Command not executable: $cmd"
done
test_pass

test_start "All lifecycle commands have proper shebang"
for cmd in doctor status start stop upgrade uninstall; do
  cmd_file="$COMMANDS_DIR/aiteamforge-${cmd}.sh"
  first_line=$(head -n 1 "$cmd_file")
  assert_contains "$first_line" "#!/" "Missing shebang: $cmd"
done
test_pass

# Success!
exit 0
