#!/bin/bash

# test-xaca-0510-launchagent-render.sh
# Tests for update_launchagents() render-from-template logic (XACA-0510),
# extended by XACA-0734 with the mandatory-materialize decision table.
#
# All filesystem activity is sandboxed to $TEST_TMP_DIR.
# NEVER touches ~/Library/LaunchAgents — see M3Pro install-ban rule.
#
# ─────────────────────────────────────────────────────────────────────────────
# XACA-0734 CONTRACT CHANGE — READ THIS BEFORE "RESTORING" AN OLD ASSERTION
# ─────────────────────────────────────────────────────────────────────────────
# This suite used to assert:
#
#     "Missing targets: both plists absent -> function skips both"
#
# That assertion ENCODED THE BUG. `update_launchagents` skipped every absent
# plist, inferring "absent == the user opted out". That inference cannot tell
# "user deliberately removed this" from "this plist did not exist when this box
# was installed" — so every NET-NEW mandatory LaunchAgent was permanently
# unreachable on every already-installed box. M1Pro had no auto-upgrade plist,
# and auto-upgrade is the agent that PERFORMS upgrades, so it could never
# self-heal (XACA-0734-001).
#
# The opt-in guard still exists — it is just driven by RECORDED intent (the
# opt-out sentinel) instead of INFERRED intent (disk state). The tests below now
# assert the full decision table:
#
#   plist on disk | in mandatory set | in optout sentinel | action
#   --------------|------------------|--------------------|-------------------
#   present       | -                | -                  | refresh
#   absent        | yes              | no                 | RENDER + LOAD
#   absent        | yes              | yes                | skip (respect intent)
#   absent        | no               | -                  | skip
#
# The "skip an absent plist" behavior the original test cared about is still
# covered — by the row-3 and row-4 cases below.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
LAUNCHAGENTS_LIB="$TAP_ROOT/libexec/lib/launchagents.sh"
TEMPLATES_DIR="$TAP_ROOT/share/templates/kanban"
AU_TEMPLATES_DIR="$TAP_ROOT/share/templates/auto-upgrade"

# ═══════════════════════════════════════════════════════════════════════════
# Sandbox setup
# ═══════════════════════════════════════════════════════════════════════════

SANDBOX_DIR="$TEST_TMP_DIR/xaca0510"
FAKE_LAUNCHAGENTS="$SANDBOX_DIR/LaunchAgents"
FAKE_FRAMEWORK="$SANDBOX_DIR/framework"
FAKE_WORKING="$SANDBOX_DIR/working"

mkdir -p "$FAKE_LAUNCHAGENTS"
mkdir -p "$FAKE_FRAMEWORK/share/templates/kanban"
mkdir -p "$FAKE_FRAMEWORK/share/templates/auto-upgrade"
mkdir -p "$FAKE_WORKING"

# Copy real templates into sandbox framework. XACA-0734: the auto-upgrade
# templates are now required too — auto-upgrade is in the MANDATORY set, and the
# two watch templates must be present so that "non-mandatory absent -> skipped"
# is genuinely testing the mandatory gate rather than accidentally passing
# because the template happened to be missing.
cp "$TEMPLATES_DIR/backup-plist.template"          "$FAKE_FRAMEWORK/share/templates/kanban/"
cp "$TEMPLATES_DIR/lcars-health-plist.template"    "$FAKE_FRAMEWORK/share/templates/kanban/"
cp "$AU_TEMPLATES_DIR/auto-upgrade-launchagent.template.plist" "$FAKE_FRAMEWORK/share/templates/auto-upgrade/"
cp "$AU_TEMPLATES_DIR/lcars-watch-launchagent.template.plist"  "$FAKE_FRAMEWORK/share/templates/auto-upgrade/"
cp "$AU_TEMPLATES_DIR/cellar-watch-launchagent.template.plist" "$FAKE_FRAMEWORK/share/templates/auto-upgrade/"

# Sandbox the opt-out sentinel. Never let it resolve to the real
# ~/.aiteamforge/launchagents.optout.
export AITF_LAUNCHAGENT_OPTOUT_FILE="$SANDBOX_DIR/launchagents.optout"

# ═══════════════════════════════════════════════════════════════════════════
# Stubs — CRITICAL: must never reach real launchd.
# ═══════════════════════════════════════════════════════════════════════════

# Stubs for upgrade.sh's print helpers — these are exported by test-runner.sh
# (print_success / print_error / print_warning / print_info) but the script
# also uses print_section. Provide a no-op if not already defined.
if ! declare -f print_section >/dev/null 2>&1; then
  print_section() { :; }
fi

# No-op launchctl stub. Override before loading any code that might call it.
launchctl() { return 0; }
export -f launchctl

# _aitf_launchctl normally comes from lib/common.sh (not sourced here — it would
# clobber the test-runner's print_* helpers). Stub it directly so the mutating
# load/unload calls in update_launchagents are inert.
_aitf_launchctl() { return 0; }
export -f _aitf_launchctl

# ═══════════════════════════════════════════════════════════════════════════
# Load the code under test.
#
# XACA-0734: _render_launchagent_template MOVED to libexec/lib/launchagents.sh
# (along with the agent->template map, the mandatory set, and the opt-out
# sentinel helpers), because `aiteamforge doctor --fix` needed the same renderer
# and would otherwise have become a FOURTH copy of it. So we now SOURCE the lib
# rather than text-scraping the renderer out of upgrade.sh.
#
# update_launchagents itself still lives in upgrade.sh (it is upgrade-specific
# orchestration), and upgrade.sh's main body has side effects (arg parsing,
# is_configured / get_framework_dir calls), so that one is still extracted.
# ═══════════════════════════════════════════════════════════════════════════

# shellcheck source=../libexec/lib/launchagents.sh
source "$LAUNCHAGENTS_LIB"

declare -f _render_launchagent_template >/dev/null || \
  { echo "FATAL: _render_launchagent_template not provided by $LAUNCHAGENTS_LIB"; exit 1; }
declare -f _xaca0734_launchagent_map >/dev/null || \
  { echo "FATAL: _xaca0734_launchagent_map not provided by $LAUNCHAGENTS_LIB"; exit 1; }

# Extract and eval _cleanup_upgrade_tmpfiles + update_launchagents from
# upgrade.sh. We grab from the cleanup helper comment through to the closing
# brace of update_launchagents. TWO top-level closing braces expected (one per
# function) — this was THREE before XACA-0734 moved the renderer into the lib.
_extracted_funcs="$(awk '
  /^# Cleanup helper invoked by update_launchagents/ { capture=1 }
  capture { print }
  /^}$/ && capture {
    brace_count++
    if (brace_count == 2) { capture=0 }
  }
' "$UPGRADE_SH")"

if [ -z "$_extracted_funcs" ]; then
  test_start "Sanity: can extract functions from upgrade.sh"
  test_fail "Failed to extract _cleanup_upgrade_tmpfiles and update_launchagents — awk returned empty"
  return 0
fi

eval "$_extracted_funcs"

# Hard precondition: if awk extracted something but the functions weren't
# defined, all downstream tests would give cryptic failures. Abort loudly.
declare -f _cleanup_upgrade_tmpfiles >/dev/null || \
  { echo "FATAL: _cleanup_upgrade_tmpfiles not extracted from upgrade.sh"; exit 1; }
declare -f update_launchagents >/dev/null || \
  { echo "FATAL: update_launchagents not extracted from upgrade.sh"; exit 1; }

# Guard against silent regression of the extraction itself: if someone moves
# update_launchagents or changes the brace shape, the awk above could capture a
# truncated function that still "defines" but misbehaves. Assert it references
# the shared map (proving we got the XACA-0734 body, not a stale copy).
test_start "Extraction sanity: update_launchagents uses the shared XACA-0734 agent map"
assert_contains "$_extracted_funcs" "_xaca0734_launchagent_map" \
  "extracted update_launchagents must iterate the shared agent map from lib/launchagents.sh"
assert_contains "$_extracted_funcs" "_xaca0734_is_mandatory" \
  "extracted update_launchagents must consult the mandatory set"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Helpers
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

# Reset sandbox LaunchAgents dir AND the opt-out sentinel between tests.
reset_launchagents() {
  rm -rf "$FAKE_LAUNCHAGENTS"
  mkdir -p "$FAKE_LAUNCHAGENTS"
  rm -f "$AITF_LAUNCHAGENT_OPTOUT_FILE"
}

# Mandatory (materialize-when-absent)
BACKUP_PLIST="$FAKE_LAUNCHAGENTS/com.aiteamforge.kanban-backup.plist"
LCARS_PLIST="$FAKE_LAUNCHAGENTS/com.aiteamforge.lcars-health.plist"
AUTO_UPGRADE_PLIST="$FAKE_LAUNCHAGENTS/com.aiteamforge.auto-upgrade.plist"
# Non-mandatory (skip-when-absent)
LCARS_WATCH_PLIST="$FAKE_LAUNCHAGENTS/com.aiteamforge.lcars-watch.plist"
CELLAR_WATCH_PLIST="$FAKE_LAUNCHAGENTS/com.aiteamforge.cellar-watch.plist"

# ═══════════════════════════════════════════════════════════════════════════
# XACA-0734 — the mandatory set and the map agree with what we test
# ═══════════════════════════════════════════════════════════════════════════

test_start "XACA-0734: mandatory set is exactly {auto-upgrade, lcars-health, kanban-backup}"
_mandatory="$(_xaca0734_mandatory_launchagent_basenames)"
assert_contains "$_mandatory" "com.aiteamforge.auto-upgrade.plist" "auto-upgrade must be mandatory (it performs upgrades)"
assert_contains "$_mandatory" "com.aiteamforge.lcars-health.plist" "lcars-health must be mandatory"
assert_contains "$_mandatory" "com.aiteamforge.kanban-backup.plist" "kanban-backup must be mandatory"
assert_not_contains "$_mandatory" "com.aiteamforge.lcars-watch.plist" "lcars-watch is an accelerator, NOT mandatory"
assert_not_contains "$_mandatory" "com.aiteamforge.cellar-watch.plist" "cellar-watch is an accelerator, NOT mandatory"
assert_not_contains "$_mandatory" "cr-confluence-poller" "cr-confluence-poller is config-gated, NOT mandatory"
test_pass

test_start "XACA-0734: retired lcars-runatload is absent from the agent map"
assert_not_contains "$(_xaca0734_launchagent_map)" "lcars-runatload" \
  "retired agent (XACA-0763-005) must never be re-rendered"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Opt-out sentinel helpers
# ═══════════════════════════════════════════════════════════════════════════

test_start "Sentinel: missing file means nothing is opted out"
reset_launchagents
assert_file_not_exists "$AITF_LAUNCHAGENT_OPTOUT_FILE" "sentinel should not exist after reset"
if _xaca0734_is_opted_out "com.aiteamforge.auto-upgrade.plist"; then
  test_fail "a missing sentinel file must mean NOTHING is opted out"
fi
test_pass

test_start "Sentinel: record then detect; record is idempotent (no duplicate lines)"
reset_launchagents
_xaca0734_record_optout "com.aiteamforge.auto-upgrade.plist"
_xaca0734_record_optout "com.aiteamforge.auto-upgrade.plist"
_xaca0734_record_optout "com.aiteamforge.auto-upgrade.plist"
if ! _xaca0734_is_opted_out "com.aiteamforge.auto-upgrade.plist"; then
  test_fail "recorded agent must read back as opted out"
fi
_count="$(grep -c -x -F "com.aiteamforge.auto-upgrade.plist" "$AITF_LAUNCHAGENT_OPTOUT_FILE")"
assert_equal "1" "$_count" "record_optout must dedupe — exactly one line after 3 records"
test_pass

test_start "Sentinel: exact-line membership (no substring false-positives)"
reset_launchagents
_xaca0734_record_optout "com.aiteamforge.lcars-health.plist.disabled"
if _xaca0734_is_opted_out "com.aiteamforge.lcars-health.plist"; then
  test_fail "membership must be an EXACT line match, not a substring match"
fi
test_pass

test_start "Sentinel: clear_optout removes only the named agent"
reset_launchagents
_xaca0734_record_optout "com.aiteamforge.auto-upgrade.plist"
_xaca0734_record_optout "com.aiteamforge.lcars-health.plist"
_xaca0734_clear_optout "com.aiteamforge.auto-upgrade.plist"
if _xaca0734_is_opted_out "com.aiteamforge.auto-upgrade.plist"; then
  test_fail "cleared agent must no longer be opted out"
fi
if ! _xaca0734_is_opted_out "com.aiteamforge.lcars-health.plist"; then
  test_fail "clear_optout must not remove OTHER agents' entries"
fi
test_pass

test_start "Sentinel: clear_all_optouts deletes the whole file (full-uninstall teardown)"
reset_launchagents
_xaca0734_record_optout "com.aiteamforge.auto-upgrade.plist"
_xaca0734_record_optout "com.aiteamforge.lcars-health.plist"
assert_file_exists "$AITF_LAUNCHAGENT_OPTOUT_FILE" "sentinel should exist after recording"
_xaca0734_clear_all_optouts
assert_file_not_exists "$AITF_LAUNCHAGENT_OPTOUT_FILE" \
  "full uninstall must delete the sentinel — a surviving one would suppress every mandatory agent on reinstall"
test_pass

test_start "Sentinel: clear_optout on a missing sentinel is a safe no-op"
reset_launchagents
_xaca0734_clear_optout "com.aiteamforge.auto-upgrade.plist"
_xaca0734_clear_all_optouts
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# DECISION TABLE ROW 2 (THE FIX): absent + mandatory + not opted out -> RENDER
# This is the regression test for XACA-0734. It is the exact inverse of the
# assertion this suite used to make.
# ═══════════════════════════════════════════════════════════════════════════

test_start "Row 2 (THE FIX): absent + mandatory + no opt-out -> plist is materialized"
reset_launchagents
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_exists "$AUTO_UPGRADE_PLIST" "auto-upgrade.plist MUST be created — without it the box can never self-upgrade"
assert_file_exists "$LCARS_PLIST"        "lcars-health.plist MUST be created when absent and mandatory"
assert_file_exists "$BACKUP_PLIST"       "kanban-backup.plist MUST be created when absent and mandatory"
test_pass

test_start "Row 2: materialized plist is fully rendered (no {{ }} placeholders remain)"
reset_launchagents
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_not_contains "$(cat "$AUTO_UPGRADE_PLIST")" "{{" "materialized auto-upgrade.plist must have no unresolved placeholders"
assert_contains     "$(cat "$AUTO_UPGRADE_PLIST")" "$FAKE_WORKING" "materialized plist must reference the resolved working dir"
test_pass

test_start "Row 2: 'Installing' is reported (not 'Updating') for a newly materialized agent"
reset_launchagents
output="$(FORCE=false DRY_RUN=false run_update_launchagents 2>&1)"
assert_contains "$output" "Installing com.aiteamforge.auto-upgrade.plist" \
  "a newly materialized mandatory agent should be reported as an install"
test_pass

# ─────────────────────────────────────────────────────────────────────────
# Opt-out DISCOVERABILITY hint on the materialize path (coordinator follow-up).
# Row 3 (opt-out is respected) is only useful if a user can find out the
# sentinel exists. There is deliberately no new CLI subcommand for it — the
# escape-hatch command is printed right at the moment it becomes relevant:
# when update_launchagents is about to materialize a missing mandatory agent.
# ─────────────────────────────────────────────────────────────────────────

test_start "Hint: materializing (non-dry-run) prints the exact opt-out command with the REAL resolved path"
reset_launchagents
output="$(FORCE=false DRY_RUN=false run_update_launchagents 2>&1)"
assert_contains "$output" "To permanently opt out instead" \
  "materializing a mandatory agent must surface the opt-out escape hatch"
assert_contains "$output" "echo \"com.aiteamforge.auto-upgrade.plist\" >> ${AITF_LAUNCHAGENT_OPTOUT_FILE}" \
  "the hint must use the REAL resolved sentinel path (AITF_LAUNCHAGENT_OPTOUT_FILE), not a hardcoded one"
test_pass

test_start "Hint: appears for EACH materialized mandatory agent, not just the first"
reset_launchagents
output="$(FORCE=false DRY_RUN=false run_update_launchagents 2>&1)"
assert_contains "$output" "echo \"com.aiteamforge.lcars-health.plist\" >>"  "lcars-health must get its own hint"
assert_contains "$output" "echo \"com.aiteamforge.kanban-backup.plist\" >>" "kanban-backup must get its own hint"
test_pass

test_start "Hint: DRY_RUN=true ALSO prints the hint (would-be install is exactly when it's useful)"
reset_launchagents
output="$(FORCE=false DRY_RUN=true run_update_launchagents 2>&1)"
assert_contains "$output" "Would install: com.aiteamforge.auto-upgrade.plist" "sanity: this is the would-install path"
assert_contains "$output" "To permanently opt out instead" "DRY_RUN materialize path must also print the hint"
assert_contains "$output" "echo \"com.aiteamforge.auto-upgrade.plist\" >> ${AITF_LAUNCHAGENT_OPTOUT_FILE}" \
  "DRY_RUN hint must also use the real resolved path"
test_pass

test_start "Hint: does NOT appear on routine refresh of an already-installed agent (would be noise)"
reset_launchagents
touch "$BACKUP_PLIST"
touch "$LCARS_PLIST"
touch "$AUTO_UPGRADE_PLIST"
output="$(FORCE=false DRY_RUN=false run_update_launchagents 2>&1)"
assert_not_contains "$output" "To permanently opt out instead" \
  "refreshing agents the user already has must not nag about opting out — nothing is being installed"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# DECISION TABLE ROW 3: absent + mandatory + OPTED OUT -> skip
# This preserves the original opt-in guard — now driven by RECORDED intent.
# ═══════════════════════════════════════════════════════════════════════════

test_start "Row 3: absent + mandatory + opted out -> plist stays absent (intent respected)"
reset_launchagents
_xaca0734_record_optout "com.aiteamforge.auto-upgrade.plist"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "$AUTO_UPGRADE_PLIST" \
  "a recorded opt-out must be respected — upgrade must NOT re-materialize it"
# ...while its non-opted-out siblings are still materialized.
assert_file_exists "$LCARS_PLIST"  "opting out of ONE agent must not suppress the others"
assert_file_exists "$BACKUP_PLIST" "opting out of ONE agent must not suppress the others"
test_pass

test_start "Row 3: opt-out is reported as a deliberate skip"
reset_launchagents
_xaca0734_record_optout "com.aiteamforge.auto-upgrade.plist"
output="$(FORCE=false DRY_RUN=false run_update_launchagents 2>&1)"
assert_contains "$output" "opted out" "an opted-out agent should be reported as such, not silently ignored"
test_pass

test_start "Row 3: opting out of ALL mandatory agents materializes none of them"
reset_launchagents
_xaca0734_record_optout "com.aiteamforge.auto-upgrade.plist"
_xaca0734_record_optout "com.aiteamforge.lcars-health.plist"
_xaca0734_record_optout "com.aiteamforge.kanban-backup.plist"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "$AUTO_UPGRADE_PLIST" "fully opted-out: auto-upgrade must stay absent"
assert_file_not_exists "$LCARS_PLIST"        "fully opted-out: lcars-health must stay absent"
assert_file_not_exists "$BACKUP_PLIST"       "fully opted-out: kanban-backup must stay absent"
test_pass

# ─────────────────────────────────────────────────────────────────────────
# Row 3 reachability via a HAND-WRITTEN sentinel (coordinator follow-up).
#
# Every Row 3 test above populates the sentinel via _xaca0734_record_optout —
# an internal primitive, not what a real user does. The actual reachable path
# today is: the user reads the hint printed above and runs the literal command
# `echo "<agent>" >> ~/.aiteamforge/launchagents.optout` themselves — there is
# no other supported writer (uninstall_<x>_launchagent's record() is only
# reachable via the batch uninstall, which immediately wipes the whole
# sentinel again; see lib/launchagents.sh's LIFECYCLE note). This test proves
# THAT exact user-facing workflow — not the internal helper — actually works,
# using plain `echo >>` / `printf >>` with no test-only shortcuts.
# ─────────────────────────────────────────────────────────────────────────

test_start "Row 3 reachability: a HAND-WRITTEN sentinel line (echo >>, the documented user workflow) is honored"
reset_launchagents
# This is deliberately NOT _xaca0734_record_optout — it is the literal command
# the hint text (and the lib header contract) tells a user to run by hand.
echo "com.aiteamforge.auto-upgrade.plist" >> "$AITF_LAUNCHAGENT_OPTOUT_FILE"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "$AUTO_UPGRADE_PLIST" \
  "a hand-written sentinel line must be honored exactly like a programmatically-recorded one"
assert_file_exists "$LCARS_PLIST" "hand-writing ONE opt-out must not suppress unrelated mandatory agents"
test_pass

test_start "Row 3 reachability: reversing a hand-written opt-out (removing the line) restores materialization"
reset_launchagents
echo "com.aiteamforge.auto-upgrade.plist" >> "$AITF_LAUNCHAGENT_OPTOUT_FILE"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "$AUTO_UPGRADE_PLIST" "precondition: opted out, so absent"
# The documented reversal: edit the file by hand to remove the line (not via
# _xaca0734_clear_optout — that primitive is not invoked by any reachable
# caller today; see the lib's LIFECYCLE note).
grep -v -x -F "com.aiteamforge.auto-upgrade.plist" "$AITF_LAUNCHAGENT_OPTOUT_FILE" > "${AITF_LAUNCHAGENT_OPTOUT_FILE}.tmp" 2>/dev/null || true
mv "${AITF_LAUNCHAGENT_OPTOUT_FILE}.tmp" "$AITF_LAUNCHAGENT_OPTOUT_FILE"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_exists "$AUTO_UPGRADE_PLIST" \
  "removing the hand-written line must restore materialization on the next upgrade run"
test_pass

test_start "Row 3 reachability: hand-written sentinel with blank lines and no trailing newline still parses"
reset_launchagents
# printf, not echo — deliberately no trailing newline, plus a blank line, to
# prove the reader is not fragile to how a human might hand-edit the file.
printf 'com.aiteamforge.lcars-health.plist\n\ncom.aiteamforge.auto-upgrade.plist' > "$AITF_LAUNCHAGENT_OPTOUT_FILE"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "$LCARS_PLIST"        "first line (no surrounding blank-line issues) must be honored"
assert_file_not_exists "$AUTO_UPGRADE_PLIST" "last line WITHOUT a trailing newline must still be honored"
assert_file_exists "$BACKUP_PLIST"           "the agent not listed must still materialize normally"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# DECISION TABLE ROW 4: absent + NOT mandatory -> skip (unchanged behavior)
# The templates for these ARE present in the sandbox, so this proves the skip
# comes from the mandatory gate, not from a missing template.
# ═══════════════════════════════════════════════════════════════════════════

test_start "Row 4: absent + non-mandatory -> plist stays absent (even though template exists)"
reset_launchagents
assert_file_exists "$FAKE_FRAMEWORK/share/templates/auto-upgrade/lcars-watch-launchagent.template.plist" \
  "precondition: the lcars-watch template IS available in the sandbox"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "$LCARS_WATCH_PLIST"  "lcars-watch is not mandatory — absent must stay absent"
assert_file_not_exists "$CELLAR_WATCH_PLIST" "cellar-watch is not mandatory — absent must stay absent"
test_pass

test_start "Row 4: a non-mandatory agent that IS present still gets refreshed"
reset_launchagents
touch "$LCARS_WATCH_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_not_contains "$(cat "$LCARS_WATCH_PLIST")" "{{" "an installed non-mandatory agent must still be re-rendered"
assert_not_empty "$(cat "$LCARS_WATCH_PLIST")" "refreshed non-mandatory plist must have content"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# DECISION TABLE ROW 1: present -> refresh (original XACA-0510 behavior)
# ═══════════════════════════════════════════════════════════════════════════

test_start "Row 1: sentinel target present -> renders and writes plist"
reset_launchagents
touch "$BACKUP_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_exists "$BACKUP_PLIST" "kanban-backup.plist should exist after render"
test_pass

test_start "Row 1: rendered plist contains resolved HOME value (no placeholder)"
reset_launchagents
touch "$BACKUP_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
content="$(cat "$BACKUP_PLIST")"
assert_not_contains "$content" "{{USER_HOME}}" "Rendered plist must not contain {{USER_HOME}} placeholder"
assert_not_contains "$content" "{{AITEAMFORGE_DIR}}" "Rendered plist must not contain {{AITEAMFORGE_DIR}} placeholder"
assert_not_contains "$content" "{{BACKUP_INTERVAL}}" "Rendered plist must not contain {{BACKUP_INTERVAL}} placeholder"
assert_not_contains "$content" "{{PYTHON3_PATH}}" "Rendered plist must not contain {{PYTHON3_PATH}} placeholder"
test_pass

test_start "Row 1: rendered plist contains resolved AITEAMFORGE_DIR (WORKING_DIR)"
reset_launchagents
touch "$BACKUP_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
content="$(cat "$BACKUP_PLIST")"
assert_contains "$content" "$FAKE_WORKING" "Rendered plist must contain resolved WORKING_DIR path"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# No-op on second run — same template -> unchanged file
# ═══════════════════════════════════════════════════════════════════════════

test_start "No-op: second run with same template produces no tempfile leak"
reset_launchagents
# First run — materializes all mandatory agents and renders content
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
assert_file_not_exists "${AUTO_UPGRADE_PLIST}.new" "No .new tempfile should remain for a materialized agent"
test_pass

test_start "No-op: a second run reports 'All LaunchAgents up to date'"
reset_launchagents
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
output="$(FORCE=false DRY_RUN=false run_update_launchagents 2>&1)"
assert_contains "$output" "All LaunchAgents up to date" \
  "once every mandatory agent is materialized, a re-run must be a clean no-op"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# FORCE=true -> re-renders even when target is up to date
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

test_start "FORCE=true: does NOT override a recorded opt-out"
reset_launchagents
_xaca0734_record_optout "com.aiteamforge.auto-upgrade.plist"
FORCE=true DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "$AUTO_UPGRADE_PLIST" \
  "--force must not steamroll recorded user intent"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# DRY_RUN=true -> writes nothing
# ═══════════════════════════════════════════════════════════════════════════

test_start "DRY_RUN=true: writes nothing to an existing target plist"
reset_launchagents
# Place a known sentinel content in the target so we can detect if it changed
echo "SENTINEL_DO_NOT_OVERWRITE" > "$BACKUP_PLIST"
output="$(FORCE=false DRY_RUN=true run_update_launchagents 2>&1)"
content="$(cat "$BACKUP_PLIST")"
assert_equal "SENTINEL_DO_NOT_OVERWRITE" "$content" "DRY_RUN must not overwrite target plist"
test_pass

test_start "DRY_RUN=true: materializes NOTHING for a missing mandatory agent"
reset_launchagents
FORCE=false DRY_RUN=true run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "$AUTO_UPGRADE_PLIST" "DRY_RUN must not create a missing mandatory plist"
assert_file_not_exists "$LCARS_PLIST"        "DRY_RUN must not create a missing mandatory plist"
assert_file_not_exists "$BACKUP_PLIST"       "DRY_RUN must not create a missing mandatory plist"
assert_file_not_exists "${AUTO_UPGRADE_PLIST}.new" "DRY_RUN must not leave a tempfile behind"
test_pass

test_start "DRY_RUN=true: prints 'Would install' for a missing mandatory agent"
reset_launchagents
output="$(FORCE=false DRY_RUN=true run_update_launchagents 2>&1)"
assert_contains "$output" "Would install: com.aiteamforge.auto-upgrade.plist" \
  "DRY_RUN must announce the install it would perform"
test_pass

test_start "DRY_RUN=true: prints 'Would update' for a changed existing agent"
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
# Missing template -> reports cleanly without aborting
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

test_start "Assert-present: warns loudly when a mandatory agent is STILL missing after the run"
reset_launchagents
# framework-missing has no auto-upgrade template, so auto-upgrade cannot be
# materialized — the assert-present loop must say so rather than pass silently.
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
assert_exit_success "$exit_code" "assert-present must warn, never abort the upgrade"
assert_contains "$output" "Mandatory LaunchAgent still missing" \
  "a mandatory agent that could not be materialized must produce a LOUD warning"
assert_contains "$output" "com.aiteamforge.auto-upgrade.plist" \
  "the warning must name the missing agent"
test_pass

test_start "Assert-present: does NOT warn about an agent that is merely opted out"
reset_launchagents
_xaca0734_record_optout "com.aiteamforge.auto-upgrade.plist"
_xaca0734_record_optout "com.aiteamforge.lcars-health.plist"
_xaca0734_record_optout "com.aiteamforge.kanban-backup.plist"
output="$(FORCE=false DRY_RUN=false run_update_launchagents 2>&1)"
assert_not_contains "$output" "Mandatory LaunchAgent still missing" \
  "an intentionally opted-out agent is SUPPOSED to be absent — never warn about it"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Both mandatory sentinels present -> both rendered, no placeholders remain
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

# ═══════════════════════════════════════════════════════════════════════════
# DRY_RUN=true + no-change path — tempfile cleanup and no-op assertion
# ═══════════════════════════════════════════════════════════════════════════

test_start "DRY_RUN=true + no-change: target is unchanged after run"
reset_launchagents
# Seed target with the real rendered content so diff sees no change
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
content_before="$(cat "$BACKUP_PLIST")"
# Now run again with DRY_RUN=true — content is identical, should be a no-op
FORCE=false DRY_RUN=true run_update_launchagents >/dev/null 2>&1
content_after="$(cat "$BACKUP_PLIST")"
assert_equal "$content_before" "$content_after" "DRY_RUN=true + no-change must leave target file unmodified"
test_pass

test_start "DRY_RUN=true + no-change: no .new tempfile remains after run"
reset_launchagents
# Seed with real content so diff is clean
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
FORCE=false DRY_RUN=true run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "${BACKUP_PLIST}.new" "No .new tempfile should remain after DRY_RUN=true no-change run"
test_pass

test_start "DRY_RUN=true + no-change: output reports 'All LaunchAgents up to date'"
reset_launchagents
# Seed with real content so diff is clean (materializes all mandatory agents)
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
output="$(FORCE=false DRY_RUN=true run_update_launchagents 2>&1)"
assert_contains "$output" "All LaunchAgents up to date" "No-change DRY_RUN run must report 'All LaunchAgents up to date'"
test_pass
