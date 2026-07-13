#!/bin/bash

# test-doctor-fix.sh
# Tests for aiteamforge doctor --fix mode
#
# Covers:
#   - --fix flag is accepted without error
#   - --fix flag with each --check component
#   - --fix combined with --verbose
#   - Idempotency: running --fix twice produces the same output/exit code
#   - Partial fix scenarios (some checks fixable, others not)
#   - Output messaging when --fix is active
#   - Exit codes: fully-healthy (0), warnings-only (1), failures present (2)
#   - Dry-run distinction (doctor has no --dry-run; tests confirm absence)
#   - --fix with unknown/invalid component
#
# IMPLEMENTATION NOTE (REFRESHED — XACA-0734-014):
#   This header used to say auto-remediation was a STUB, and two tests below
#   asserted that stub's message:
#     "(Auto-fix not yet implemented - run: aiteamforge setup --upgrade)"
#   That has not been true since XACA-0655 (commit 33a73ff) made `--fix` actually
#   remediate; the string is gone from the doctor entirely. The assertions kept
#   passing right up until the doctor's output changed shape, then failed for a
#   reason that had nothing to do with what they were guarding — they were stale,
#   not broken. (They fail identically on the v0.17.7 baseline, so they are not a
#   XACA-0734 regression; XACA-0734 is simply the ticket that noticed.)
#
#   THE CURRENT CONTRACT, which the refreshed tests assert:
#     * SAFE remediations (venv, keepalive, server) are auto-applied INLINE at
#       each failing check when --apply/--fix is set.
#     * RISKY ones (config/board rewrites via `aiteamforge setup`) are print-only,
#       tagged [manual], never auto-applied.
#     * With failures + --fix, the doctor ALWAYS reports its remediation outcome —
#       either a "Remediation Summary (--fix)" section listing the tagged actions,
#       or an explicit "No auto-remediable issues detected" line. It never accepts
#       --fix and then says nothing.
#
#   DO NOT assert on the literal word "setup" here. It appears only when a
#   board/setup-KIND check happens to fail, which varies by machine (that is
#   exactly how the old assertion rotted). Assert the contract, not the weather.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCTOR_CMD="$TAP_ROOT/libexec/commands/aiteamforge-doctor.sh"

# ── Test environment ──────────────────────────────────────────────────────────
# Use TEST_TMP_DIR provided by the test runner (or create our own for standalone)
if [ -z "$TEST_TMP_DIR" ]; then
  TEST_TMP_DIR=$(mktemp -d -t aiteamforge-doctor-fix.XXXXXX)
  _OWN_TMP_DIR=true
  trap 'rm -rf "$TEST_TMP_DIR"' EXIT
else
  _OWN_TMP_DIR=false
fi

# Bootstrap: source test-runner.sh helpers if not already loaded (standalone mode)
if ! type test_start &>/dev/null 2>&1; then
    if [ -f "$SCRIPT_DIR/test-runner.sh" ]; then
        source "$SCRIPT_DIR/test-runner.sh"
    else
        echo "ERROR: test-runner.sh not found at $SCRIPT_DIR" >&2
        exit 1
    fi
fi

_FAKE_HOME="$TEST_TMP_DIR/home"
_FAKE_AITEAMFORGE="$_FAKE_HOME/aiteamforge"

mkdir -p "$_FAKE_AITEAMFORGE"
mkdir -p "$_FAKE_HOME/Library/LaunchAgents"

# Helper: write a minimal valid config into the fake working dir
_write_config() {
  cat > "$_FAKE_AITEAMFORGE/.aiteamforge-config" <<'EOF'
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

# Helper: remove config to simulate unconfigured state
_remove_config() {
  rm -f "$_FAKE_AITEAMFORGE/.aiteamforge-config"
}

# ── launchd containment (XACA-0787) ───────────────────────────────────────────
# `doctor --fix` is no longer a stub: its keepalive remediation RENDERS a plist and
# `launchctl load`s it. HOME is faked below, so the plist lands in the sandbox — but
# launchctl is not a filesystem operation. Loading a sandbox plist registers a REAL
# job in the developer's REAL launchd session, which outlives the test and the temp
# dir it points at. That is the XACA-0787 leak class, and this suite is squarely in
# it now that --fix actually does something.
#
# AITEAMFORGE_SKIP_LAUNCHCTL=1 short-circuits _aitf_launchctl (lib/common.sh), which
# is the single chokepoint for every load/unload in the render path. The read-only
# `launchctl list` used for load-verification is unaffected (and harmless).
#
# Behavior-neutral for every assertion in this file: nothing here asserts on
# keepalive text or on whether a job registered. Verified by running the suite both
# ways — identical results.
export AITEAMFORGE_SKIP_LAUNCHCTL=1

# Helper: run doctor with arbitrary args, capturing output and exit code
# Usage: _run_doctor [args...]
_run_doctor() {
  local output exit_code=0
  output=$(AITEAMFORGE_DIR="$_FAKE_AITEAMFORGE" \
           AITEAMFORGE_HOME="$TAP_ROOT" \
           HOME="$_FAKE_HOME" \
           AITEAMFORGE_SKIP_LAUNCHCTL=1 \
           bash "$DOCTOR_CMD" "$@" 2>&1) || exit_code=$?
  # Return output via stdout, exit code via a temp file to survive subshell
  echo "$output"
  return $exit_code
}

# Helper: run doctor and capture exit code separately
# Sets _LAST_OUTPUT and _LAST_EXIT_CODE
_run_doctor_full() {
  _LAST_EXIT_CODE=0
  _LAST_OUTPUT=$(AITEAMFORGE_DIR="$_FAKE_AITEAMFORGE" \
                 AITEAMFORGE_HOME="$TAP_ROOT" \
                 HOME="$_FAKE_HOME" \
                 AITEAMFORGE_SKIP_LAUNCHCTL=1 \
                 bash "$DOCTOR_CMD" "$@" 2>&1) || _LAST_EXIT_CODE=$?
}

# ══════════════════════════════════════════════════════════════════════════════
# Section 1: Preconditions
# ══════════════════════════════════════════════════════════════════════════════

test_start "Doctor script exists and is executable"
assert_file_exists "$DOCTOR_CMD"
[ -x "$DOCTOR_CMD" ] || chmod +x "$DOCTOR_CMD"
assert_exit_success 0
test_pass

# ══════════════════════════════════════════════════════════════════════════════
# Section 2: --fix flag acceptance
# ══════════════════════════════════════════════════════════════════════════════

test_start "--fix flag is accepted without argument error"
_run_doctor_full --fix
# Doctor should not error on unknown flag; it may exit 0, 1, or 2 depending on
# system state, but must NOT produce "Unknown option" error
assert_not_contains "$_LAST_OUTPUT" "Unknown option"
assert_not_contains "$_LAST_OUTPUT" "unknown option"
test_pass

test_start "--fix produces non-empty output"
_run_doctor_full --fix
assert_not_empty "$_LAST_OUTPUT"
test_pass

test_start "--fix output includes health check sections"
_run_doctor_full --fix
# Doctor always runs its check sections regardless of --fix
assert_contains "$_LAST_OUTPUT" "HEALTH CHECK"
test_pass

test_start "--fix flag alone does not cause exit code > 2"
_run_doctor_full --fix
# Valid exit codes are 0 (all pass), 1 (warnings), 2 (failures)
[ "$_LAST_EXIT_CODE" -le 2 ]
assert_exit_success $? "--fix produced unexpected exit code: $_LAST_EXIT_CODE"
test_pass

# ══════════════════════════════════════════════════════════════════════════════
# Section 3: --fix output messaging
# ══════════════════════════════════════════════════════════════════════════════

test_start "--fix shows remediation guidance when failures exist"
_remove_config
_run_doctor_full --fix
# Doctor detects missing config as a failure; with --fix it shows fix guidance.
# The doctor must show SOMETHING about fixing rather than silently ignoring --fix.
assert_contains "$_LAST_OUTPUT" "fix"
test_pass

# XACA-0734-014: REFRESHED from "--fix references setup command in remediation
# guidance" (assert_contains "setup"). That assertion only ever held in the STUB
# era, when an empty remediation log sent the doctor down the
# "No auto-remediable issues detected / Run: aiteamforge setup" branch. Now that
# --fix produces real remediations it takes the OTHER branch, where the word
# "setup" appears only if a board/setup-kind check happens to have failed — which
# is machine-dependent. The DURABLE contract is that --fix always reports its
# outcome; that is what we assert.
test_start "--fix always reports a remediation outcome (never silently swallows --fix)"
_remove_config
_run_doctor_full --fix
case "$_LAST_OUTPUT" in
  *"Remediation Summary"*|*"No auto-remediable issues detected"*) : ;;
  *) test_fail "with failures present, --fix must either list its remediations or say there were none — accepting --fix and reporting nothing is the one thing it may not do" ;;
esac
test_pass

# XACA-0734-014: REFRESHED from "--fix with failures shows auto-fix stub message"
# (assert_contains "Auto-fix not yet implemented"). The stub was deleted by
# XACA-0655; asserting its presence now asserts a regression. Inverted to guard
# the real behavior: the stub must stay gone, and --fix must show its work.
test_start "--fix with failures actually remediates (the XACA-0655 stub is gone for good)"
_remove_config
_run_doctor_full --fix
assert_not_contains "$_LAST_OUTPUT" "Auto-fix not yet implemented" \
  "the auto-fix stub was removed by XACA-0655 — if this string is back, --fix has regressed to a no-op"
# ...and it must TAG what it did. [fix] = auto-applied, [manual] = you must run it,
# or the explicit "nothing to remediate" line. Any of the three is a real report.
case "$_LAST_OUTPUT" in
  *"[fix]"*|*"[manual]"*|*"No auto-remediable issues detected"*) : ;;
  *) test_fail "--fix must tag its remediation actions ([fix]/[manual]) or state there were none" ;;
esac
test_pass

test_start "--fix with failures still exits with code 2"
_remove_config
_run_doctor_full --fix
assert_exit_code 2 "$_LAST_EXIT_CODE"
test_pass

# XACA-0505: scoped to --check config so the test runs on CI (vanilla GHA
# macOS runners don't have the aiteamforge tap installed, so a full --fix
# pass trips framework/dependency failures unrelated to this assertion).
# --check config is bounded by AITEAMFORGE_DIR (which the test fixture
# already mocks), so it reports zero failures when _write_config has been
# called. The assertion — no stub when there are no failures — is preserved.
test_start "--fix --check config without failures does not show stub message"
_write_config
_run_doctor_full --fix --check config
assert_not_contains "$_LAST_OUTPUT" "Auto-fix not yet implemented"
test_pass

test_start "Without --fix flag, output suggests running with --fix"
_remove_config
_run_doctor_full
# When there are failures and FIX is false, doctor tells user about --fix
assert_contains "$_LAST_OUTPUT" "--fix"
test_pass

# ══════════════════════════════════════════════════════════════════════════════
# Section 4: --fix combined with --verbose
# ══════════════════════════════════════════════════════════════════════════════

test_start "--fix --verbose is accepted without error"
_run_doctor_full --fix --verbose
assert_not_contains "$_LAST_OUTPUT" "Unknown option"
test_pass

test_start "--verbose --fix order also works"
_run_doctor_full --verbose --fix
assert_not_contains "$_LAST_OUTPUT" "Unknown option"
test_pass

test_start "--fix --verbose produces more output than --fix alone"
_remove_config
_run_doctor_full --fix
_basic_len=${#_LAST_OUTPUT}
_run_doctor_full --fix --verbose
_verbose_len=${#_LAST_OUTPUT}
# Verbose output should be at least as long as non-verbose
[ "$_verbose_len" -ge "$_basic_len" ]
assert_exit_success $? "--fix --verbose output not longer than --fix alone"
test_pass

# ══════════════════════════════════════════════════════════════════════════════
# Section 5: --fix with specific component checks
# ══════════════════════════════════════════════════════════════════════════════

test_start "--fix --check dependencies is accepted"
_run_doctor_full --fix --check dependencies
assert_not_contains "$_LAST_OUTPUT" "Unknown option"
test_pass

test_start "--fix --check framework is accepted"
_run_doctor_full --fix --check framework
assert_not_contains "$_LAST_OUTPUT" "Unknown option"
test_pass

test_start "--fix --check config is accepted"
_run_doctor_full --fix --check config
assert_not_contains "$_LAST_OUTPUT" "Unknown option"
test_pass

test_start "--fix --check services is accepted"
_run_doctor_full --fix --check services
assert_not_contains "$_LAST_OUTPUT" "Unknown option"
test_pass

test_start "--fix --check launchagents is accepted"
_run_doctor_full --fix --check launchagents
assert_not_contains "$_LAST_OUTPUT" "Unknown option"
test_pass

test_start "--fix --check git is accepted"
_run_doctor_full --fix --check git
assert_not_contains "$_LAST_OUTPUT" "Unknown option"
test_pass

test_start "--fix --check network is accepted"
_run_doctor_full --fix --check network
assert_not_contains "$_LAST_OUTPUT" "Unknown option"
test_pass

test_start "--fix --check disk is accepted"
_run_doctor_full --fix --check disk
assert_not_contains "$_LAST_OUTPUT" "Unknown option"
test_pass

test_start "--fix --check all is accepted"
_run_doctor_full --fix --check all
assert_not_contains "$_LAST_OUTPUT" "Unknown option"
test_pass

test_start "--fix --check with invalid component exits non-zero"
_run_doctor_full --fix --check nonexistent_component
assert_exit_failure "$_LAST_EXIT_CODE"
test_pass

test_start "--fix --check with invalid component shows error message"
_run_doctor_full --fix --check nonexistent_component
assert_contains "$_LAST_OUTPUT" "Unknown component"
test_pass

# ══════════════════════════════════════════════════════════════════════════════
# Section 6: Idempotency — running --fix twice produces the same result
# ══════════════════════════════════════════════════════════════════════════════

test_start "Running --fix twice produces the same exit code (no config)"
_remove_config
_run_doctor_full --fix
_first_exit="$_LAST_EXIT_CODE"
_run_doctor_full --fix
_second_exit="$_LAST_EXIT_CODE"
assert_equal "$_first_exit" "$_second_exit" "Exit codes differ: first=$_first_exit second=$_second_exit"
test_pass

test_start "Running --fix twice produces the same exit code (with config)"
_write_config
_run_doctor_full --fix
_first_exit="$_LAST_EXIT_CODE"
_run_doctor_full --fix
_second_exit="$_LAST_EXIT_CODE"
assert_equal "$_first_exit" "$_second_exit" "Exit codes differ: first=$_first_exit second=$_second_exit"
test_pass

test_start "Running --fix twice does not produce conflicting summary counts"
_write_config
_run_doctor_full --fix
_first_summary=$(echo "$_LAST_OUTPUT" | grep -E "^(Total|Passed|Warnings|Failed):" || true)
_run_doctor_full --fix
_second_summary=$(echo "$_LAST_OUTPUT" | grep -E "^(Total|Passed|Warnings|Failed):" || true)
assert_equal "$_first_summary" "$_second_summary" "Summary counts changed between runs"
test_pass

test_start "Running --fix three times is still idempotent (exit code)"
_remove_config
_run_doctor_full --fix; _e1=$_LAST_EXIT_CODE
_run_doctor_full --fix; _e2=$_LAST_EXIT_CODE
_run_doctor_full --fix; _e3=$_LAST_EXIT_CODE
assert_equal "$_e1" "$_e2" "Run 1 vs 2 exit codes differ"
assert_equal "$_e2" "$_e3" "Run 2 vs 3 exit codes differ"
test_pass

test_start "Idempotency: --fix --check config with missing config"
_remove_config
_run_doctor_full --fix --check config; _e1=$_LAST_EXIT_CODE
_run_doctor_full --fix --check config; _e2=$_LAST_EXIT_CODE
assert_equal "$_e1" "$_e2"
test_pass

test_start "Idempotency: --fix --check config with valid config"
_write_config
_run_doctor_full --fix --check config; _e1=$_LAST_EXIT_CODE
_run_doctor_full --fix --check config; _e2=$_LAST_EXIT_CODE
assert_equal "$_e1" "$_e2"
test_pass

# ══════════════════════════════════════════════════════════════════════════════
# Section 7: Partial fix scenarios
# ══════════════════════════════════════════════════════════════════════════════

test_start "Partial scenario: config present but kanban dir missing still runs"
_write_config
rm -rf "$_FAKE_AITEAMFORGE/kanban"
_run_doctor_full --fix --check config
# Should not crash; kanban missing is a warning not a failure
assert_not_contains "$_LAST_OUTPUT" "Unknown option"
assert_not_empty "$_LAST_OUTPUT"
test_pass

test_start "Partial scenario: config present but lcars-ui missing still runs"
_write_config
rm -rf "$_FAKE_AITEAMFORGE/lcars-ui"
_run_doctor_full --fix --check config
assert_not_empty "$_LAST_OUTPUT"
test_pass

test_start "Partial scenario: dependencies check always runs regardless of config"
_remove_config
_run_doctor_full --fix --check dependencies
# Dependencies check does not need a config file
assert_contains "$_LAST_OUTPUT" "Dependencies"
test_pass

test_start "Partial scenario: framework check with no AITEAMFORGE_HOME set"
_remove_config
_run_doctor_full --fix --check framework
# Should produce output even when framework dir doesn't match
assert_not_empty "$_LAST_OUTPUT"
test_pass

test_start "Partial scenario: disk check runs without config"
_remove_config
_run_doctor_full --fix --check disk
assert_contains "$_LAST_OUTPUT" "Disk"
test_pass

test_start "Partial scenario: git check produces output for working dir"
_write_config
_run_doctor_full --fix --check git
assert_contains "$_LAST_OUTPUT" "Git"
test_pass

# ══════════════════════════════════════════════════════════════════════════════
# Section 8: Exit codes with --fix
# ══════════════════════════════════════════════════════════════════════════════

test_start "Exit code 2 when failures exist (with --fix)"
_remove_config
_run_doctor_full --fix
assert_exit_code 2 "$_LAST_EXIT_CODE"
test_pass

test_start "Exit code is not 0 when running with no installed config"
_remove_config
_run_doctor_full --fix
[ "$_LAST_EXIT_CODE" -ne 0 ]
assert_exit_success $? "Expected non-zero exit when config is missing"
test_pass

test_start "Exit code range is always 0-2 with --fix"
for component in dependencies framework config services launchagents git network disk; do
  _run_doctor_full --fix --check "$component"
  [ "$_LAST_EXIT_CODE" -le 2 ]
  if [ $? -ne 0 ]; then
    assert_exit_success 1 "Exit code out of range for --check $component: $_LAST_EXIT_CODE"
  fi
done
test_pass

test_start "Exit code is 2 with --fix when config is missing (check config)"
_remove_config
_run_doctor_full --fix --check config
assert_exit_code 2 "$_LAST_EXIT_CODE"
test_pass

# ══════════════════════════════════════════════════════════════════════════════
# Section 9: Dry-run (not supported — verify --fix is the only remediation flag)
# ══════════════════════════════════════════════════════════════════════════════

test_start "Doctor does not support --dry-run flag (exits non-zero)"
_run_doctor_full --dry-run
assert_exit_failure "$_LAST_EXIT_CODE"
test_pass

test_start "--dry-run produces 'Unknown option' error message"
_run_doctor_full --dry-run
assert_contains "$_LAST_OUTPUT" "Unknown option"
test_pass

test_start "--fix is the only auto-remediation flag (help confirms)"
output=$(AITEAMFORGE_DIR="$_FAKE_AITEAMFORGE" \
         AITEAMFORGE_HOME="$TAP_ROOT" \
         HOME="$_FAKE_HOME" \
         bash "$DOCTOR_CMD" --help 2>&1 || true)
assert_contains "$output" "--fix"
assert_not_contains "$output" "--dry-run"
test_pass

# ══════════════════════════════════════════════════════════════════════════════
# Section 10: Summary section with --fix
# ══════════════════════════════════════════════════════════════════════════════

test_start "--fix run always produces Summary section"
_run_doctor_full --fix
assert_contains "$_LAST_OUTPUT" "Summary"
test_pass

test_start "--fix summary includes numeric check counts"
_run_doctor_full --fix
assert_matches "$_LAST_OUTPUT" "[0-9]+"
test_pass

test_start "--fix output includes Total checks line"
_run_doctor_full --fix
assert_contains "$_LAST_OUTPUT" "Total checks"
test_pass

test_start "--fix output includes Passed count"
_run_doctor_full --fix
assert_contains "$_LAST_OUTPUT" "Passed"
test_pass

test_start "--fix output includes Failed count"
_run_doctor_full --fix
assert_contains "$_LAST_OUTPUT" "Failed"
test_pass

test_start "--fix output includes Warnings count"
_run_doctor_full --fix
assert_contains "$_LAST_OUTPUT" "Warnings"
test_pass

# ══════════════════════════════════════════════════════════════════════════════
# Section 11: --fix does not corrupt state
# ══════════════════════════════════════════════════════════════════════════════

test_start "--fix does not delete existing config file"
_write_config
_run_doctor_full --fix
assert_file_exists "$_FAKE_AITEAMFORGE/.aiteamforge-config"
test_pass

test_start "--fix does not corrupt existing config JSON"
_write_config
_run_doctor_full --fix
if command -v jq &>/dev/null; then
  jq empty "$_FAKE_AITEAMFORGE/.aiteamforge-config" >/dev/null 2>&1
  assert_exit_success $? "Config JSON corrupted by --fix run"
fi
test_pass

test_start "--fix does not create unexpected files in working dir"
_write_config
# Capture contents before
_before_files=$(find "$_FAKE_AITEAMFORGE" -type f | sort)
_run_doctor_full --fix
_after_files=$(find "$_FAKE_AITEAMFORGE" -type f | sort)
# Since auto-fix is a stub, no new files should be created
assert_equal "$_before_files" "$_after_files" "--fix created unexpected files in working dir"
test_pass

# ══════════════════════════════════════════════════════════════════════════════
# Cleanup
# ══════════════════════════════════════════════════════════════════════════════

# Standalone mode: exit with summary code so caller knows pass/fail.
# The EXIT trap installed above handles temp dir cleanup.
# When running under test-runner.sh, do NOT exit here — let the runner collect results.
if [ "$_OWN_TMP_DIR" = "true" ]; then
  exit 0
fi
