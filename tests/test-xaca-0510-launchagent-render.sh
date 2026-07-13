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

# launchctl stub.
#
# XACA-0734 review #5: this used to be `launchctl() { return 0; }` — a stub that
# emitted NOTHING. The load-verify in update_launchagents is
# `launchctl list | <is-loaded?>`, so against a silent stub the answer was always
# "not loaded" and the SUCCESS branch ("Installed and loaded ...") was never once
# executed by this suite. A test stub that can only produce one outcome does not
# test a branch, it hides it.
#
# So: `launchctl list` now emits a plausible three-column listing
# ("PID\tStatus\tLabel"), which is what the real one prints. LAUNCHCTL_LOADED
# controls which labels appear, so a test can exercise BOTH the registered and
# the rejected-by-launchd paths.
#
# Everything else still returns 0 and does nothing — this must NEVER reach real
# launchd (see XACA-0787: the full runner has leaked live agents into the real
# ~/Library/LaunchAgents before).
LAUNCHCTL_LOADED="com.aiteamforge.kanban-backup com.aiteamforge.lcars-health com.aiteamforge.auto-upgrade"
export LAUNCHCTL_LOADED

launchctl() {
  if [ "${1:-}" = "list" ]; then
    printf 'PID\tStatus\tLabel\n'
    local _l
    for _l in ${LAUNCHCTL_LOADED:-}; do
      printf -- '-\t0\t%s\n' "$_l"
    done
    return 0
  fi
  return 0
}
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

# ═══════════════════════════════════════════════════════════════════════════
# XACA-0734 review, BLOCKING 1 — THE APPLICABILITY GATE
#
# Some installs RECORD, at setup time, that they deliberately have NO
# LaunchAgents. The first cut of this ticket read the opt-out sentinel and
# nothing else, so it would have "self-healed" those boxes by installing three
# agents they never wanted — two of which point at an lcars-ui/ and a kanban
# backup script that do not exist there, i.e. recurring FAILING launchd jobs on
# a machine that was perfectly healthy. Same bug as the one this ticket fixes,
# roles reversed: intent WAS recorded, the code just didn't read the file.
# ═══════════════════════════════════════════════════════════════════════════

_write_install_profile() { printf '%s\n' "$1" > "$FAKE_WORKING/.install-profile"; }
_write_config_kanban() {
  cat > "$FAKE_WORKING/.aiteamforge-config" <<EOF
{
  "version": "0.0.0",
  "install_profile": "full",
  "features": {
    "shell_environment": true,
    "claude_code_config": true,
    "lcars_kanban": $1,
    "fleet_monitor": false
  }
}
EOF
}
# Clear BOTH markers — the default state of every pre-existing box.
_clear_markers() { rm -f "$FAKE_WORKING/.install-profile" "$FAKE_WORKING/.aiteamforge-config"; }
# Full reset: plists, sentinel, AND markers.
reset_all() { reset_launchagents; _clear_markers; }

test_start "Gate: NO markers (every pre-existing box) -> APPLICABLE (fails OPEN)"
reset_all
# This is the M1Pro case and the single most important property of the gate:
# absence of a marker is NOT intent. Inferring intent from absence IS the bug.
if ! _xaca0734_launchagents_applicable "$FAKE_WORKING"; then
  test_fail "an install with no recorded markers MUST be applicable — fail-open is what makes the M1Pro fix work"
fi
test_pass

test_start "Gate: .install-profile=cockpit -> NOT applicable"
reset_all
_write_install_profile "cockpit"
if _xaca0734_launchagents_applicable "$FAKE_WORKING"; then
  test_fail "a cockpit install records that it has no LaunchAgents — the gate must read .install-profile"
fi
test_pass

test_start "Gate: .install-profile=full -> applicable"
reset_all
_write_install_profile "full"
if ! _xaca0734_launchagents_applicable "$FAKE_WORKING"; then
  test_fail "a full install must be applicable"
fi
test_pass

test_start "Gate: config lcars_kanban=false (user declined kanban) -> NOT applicable"
reset_all
_write_config_kanban "false"
if _xaca0734_launchagents_applicable "$FAKE_WORKING"; then
  test_fail "answering 'no' to 'Install LCARS Kanban?' is recorded in .aiteamforge-config — the gate must read it"
fi
test_pass

test_start "Gate: config lcars_kanban=true -> applicable"
reset_all
_write_config_kanban "true"
if ! _xaca0734_launchagents_applicable "$FAKE_WORKING"; then
  test_fail "a box that installed kanban must get its mandatory agents"
fi
test_pass

test_start "Gate: skip reason names cockpit when the profile marker closed the gate"
reset_all
_write_install_profile "cockpit"
_reason="$(_xaca0734_launchagents_skip_reason "$FAKE_WORKING")"
assert_contains "$_reason" "cockpit" "the reason must tell the user WHY nothing was installed"
test_pass

# ── XACA-0734-013: WHY is only half a message; the user also needs the WAY BACK ──
# "Your agents are suppressed" without "here is how to un-suppress them" is how a
# user concludes they are stuck. `aiteamforge setup` is a real recovery path (it
# forces INSTALL_KANBAN=yes on a non-cockpit re-run and rewrites both markers), so
# it belongs in the message that reports the suppression — the mirror of
# _xaca0734_print_optout_hint, which prints the opt-OUT command at the moment we
# are about to materialize.

test_start "Skip reason (XACA-0734-013): cockpit branch names the opt-back-IN path"
reset_all
_write_install_profile "cockpit"
_reason="$(_xaca0734_launchagents_skip_reason "$FAKE_WORKING")"
assert_contains "$_reason" "aiteamforge setup" \
  "reporting agents as suppressed without naming the recovery command leaves the user believing they are stuck"
test_pass

test_start "Skip reason (XACA-0734-013): declined-kanban branch names the opt-back-IN path"
reset_all
_write_config_kanban "false"
_reason="$(_xaca0734_launchagents_skip_reason "$FAKE_WORKING")"
assert_contains "$_reason" "lcars_kanban" "the reason must still name WHICH marker closed the gate"
assert_contains "$_reason" "aiteamforge setup" \
  "...and how to reverse it — the whole marker design rests on setup rewriting this key"
test_pass

# ─────────────────────────────────────────────────────────────────────────
# THE BLOCKING-1 REGRESSION TEST the reviewer asked for.
# ─────────────────────────────────────────────────────────────────────────
test_start "BLOCKING 1: cockpit profile -> ROW 2 DOES NOT FIRE (no plist is materialized)"
reset_all
_write_install_profile "cockpit"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "$AUTO_UPGRADE_PLIST" "cockpit box must NOT get auto-upgrade.plist — deliberately never installed there"
assert_file_not_exists "$LCARS_PLIST"        "cockpit box must NOT get lcars-health.plist — LCARS runs on a REMOTE host; this would fail every tick"
assert_file_not_exists "$BACKUP_PLIST"       "cockpit box must NOT get kanban-backup.plist — there is no local kanban to back up"
test_pass

test_start "BLOCKING 1: cockpit upgrade EXPLAINS itself (does not silently no-op)"
reset_all
_write_install_profile "cockpit"
output="$(FORCE=false DRY_RUN=false run_update_launchagents 2>&1)"
assert_contains "$output" "No mandatory LaunchAgents on this install" "the upgrade must say why it installed nothing"
assert_contains "$output" "cockpit" "...and name the reason"
test_pass

test_start "BLOCKING 1: cockpit -> assert-present does NOT warn about correctly-absent agents"
reset_all
_write_install_profile "cockpit"
output="$(FORCE=false DRY_RUN=false run_update_launchagents 2>&1)"
assert_not_contains "$output" "Mandatory LaunchAgent still missing" \
  "on a cockpit box every mandatory agent is absent BY DESIGN — warning 3x per upgrade trains users to ignore warnings"
test_pass

test_start "BLOCKING 1: kanban declined -> ROW 2 DOES NOT FIRE either"
reset_all
_write_config_kanban "false"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "$AUTO_UPGRADE_PLIST" "a user who declined kanban expressed intent as explicitly as one who edits the sentinel"
assert_file_not_exists "$LCARS_PLIST"        "declined-kanban box must not get lcars-health.plist"
assert_file_not_exists "$BACKUP_PLIST"       "declined-kanban box must not get kanban-backup.plist"
test_pass

test_start "BLOCKING 1: FORCE=true does NOT override the applicability gate"
reset_all
_write_install_profile "cockpit"
FORCE=true DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "$AUTO_UPGRADE_PLIST" "--force must not punch through a RECORDED 'this box has no LaunchAgents'"
test_pass

test_start "BLOCKING 1: ROW 1 (refresh an EXISTING plist) stays UNCONDITIONAL on cockpit"
reset_all
_write_install_profile "cockpit"
# If a cockpit box somehow DOES have a plist, keeping its content current is still
# correct — the gate governs MATERIALIZING absent agents, not refreshing present ones.
printf 'STALE — {{AITEAMFORGE_DIR}} never resolved\n' > "$BACKUP_PLIST"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
_content="$(cat "$BACKUP_PLIST")"
assert_not_contains "$_content" "STALE" "an existing plist must still be refreshed even on a gated install"
assert_not_contains "$_content" "{{"    "the refreshed plist must be fully rendered"
assert_file_not_exists "$AUTO_UPGRADE_PLIST" "...but a still-absent agent must NOT be materialized by the refresh pass"
test_pass

test_start "Gate: markers cleared -> mandatory agents materialize again (opt-back-in works)"
reset_all
_write_config_kanban "true"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_exists "$AUTO_UPGRADE_PLIST" "re-running setup and installing kanban rewrites the marker; the gate must then OPEN"
test_pass
reset_all

# ═══════════════════════════════════════════════════════════════════════════
# XACA-0734-010 / XACA-0734-012 — MARKER 2 READS THE KEY, NOT THE FILE
#
# The gate used to detect "kanban declined" with a file-WIDE substring grep:
#     grep -qE '"lcars_kanban"[[:space:]]*:[[:space:]]*false'
# Correct against today's schema; silently catastrophic against tomorrow's. Any
# SECOND occurrence of that byte pattern anywhere in the config — an audit-history
# array recording a PAST false, a per-team override, a stale key — closes the gate
# on a box whose LIVE key is `true`.
#
# That fails CLOSED, which is the one direction this gate must never fail in: it
# suppresses every mandatory agent (including auto-upgrade, the agent that PERFORMS
# upgrades) while every check still reports the box healthy — turning this whole
# ticket into a silent no-op on the exact machines it exists to fix.
#
# So: only an explicit, correctly-PARSED features.lcars_kanban === false may close
# this gate. EVERY degraded input — no jq, bad JSON, empty file, unreadable file,
# missing block, missing key — must fall through to APPLICABLE.
# ═══════════════════════════════════════════════════════════════════════════

# A PATH that has every tool the gate could possibly fall back to — EXCEPT jq.
#
# NOT an empty dir. An empty PATH removes `grep` along with `jq`, so a reinstated
# grep fallback could not run either and the "no jq -> applicable" test below would
# pass for entirely the wrong reason — it would be asserting "an empty PATH breaks
# everything", not "the gate refuses to guess without a parser". (Caught by running
# the negative control: with an empty-PATH fixture, deliberately adding a grep
# fallback back into the gate did NOT turn the test red. A test that cannot fail is
# not a test.) Symlinking the real tools in means jq's absence is the ONLY variable.
_NOJQ_BIN="$SANDBOX_DIR/no-jq-bin"
mkdir -p "$_NOJQ_BIN"
for _t in grep tr sed cat awk; do
  _tp="$(command -v "$_t" 2>/dev/null || true)"
  [ -n "$_tp" ] && ln -sf "$_tp" "$_NOJQ_BIN/$_t"
done
unset _t _tp

_write_raw_config() { printf '%s' "$1" > "$FAKE_WORKING/.aiteamforge-config"; }

# Live key TRUE, but a PAST `false` recorded elsewhere in the file. This is the
# regression test: the old grep matched the history entry and closed the gate.
_write_config_decoy_past_false() {
  cat > "$FAKE_WORKING/.aiteamforge-config" <<'EOF'
{
  "version": "0.0.0",
  "install_profile": "full",
  "installed_features": ["shell_environment", "lcars_kanban"],
  "feature_history": [
    {"date": "2026-01-01", "features": {"lcars_kanban": false}},
    {"date": "2026-02-01", "features": {"lcars_kanban": true}}
  ],
  "features": {
    "shell_environment": true,
    "lcars_kanban": true,
    "fleet_monitor": false
  }
}
EOF
}

# The mirror: live key FALSE, with a decoy `true` in the history. Proves the new
# read is actually reading the LIVE key and not merely always-opening.
_write_config_decoy_past_true() {
  cat > "$FAKE_WORKING/.aiteamforge-config" <<'EOF'
{
  "version": "0.0.0",
  "install_profile": "full",
  "feature_history": [
    {"date": "2026-01-01", "features": {"lcars_kanban": true}}
  ],
  "features": {
    "shell_environment": true,
    "lcars_kanban": false,
    "fleet_monitor": false
  }
}
EOF
}

test_start "Marker2 (XACA-0734-010): a PAST lcars_kanban=false elsewhere in the file must NOT close the gate"
reset_all
_write_config_decoy_past_false
if ! _xaca0734_launchagents_applicable "$FAKE_WORKING"; then
  test_fail "live features.lcars_kanban is TRUE — a stale 'false' in an audit array must not suppress every mandatory agent (this is the false-CLOSE the flat grep allowed)"
fi
test_pass

test_start "Marker2: ...and it must not suppress row 2 end-to-end either"
reset_all
_write_config_decoy_past_false
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_exists "$AUTO_UPGRADE_PLIST" \
  "the whole ticket: a box whose LIVE key says kanban=true must still get auto-upgrade.plist"
test_pass

test_start "Marker2: live lcars_kanban=false STILL closes the gate (decoy 'true' in history ignored)"
reset_all
_write_config_decoy_past_true
if _xaca0734_launchagents_applicable "$FAKE_WORKING"; then
  test_fail "the LIVE key is false — the gate must still close, or the key-scoped read is just always-open"
fi
test_pass

test_start "Marker2: 'lcars_kanban' as an installed_features ARRAY element is not a declined key"
reset_all
_write_raw_config '{"installed_features":["lcars_kanban"],"features":{"lcars_kanban":true}}'
if ! _xaca0734_launchagents_applicable "$FAKE_WORKING"; then
  test_fail "the bare string in the array is a FEATURE NAME, not a key:false — it must never be read as intent"
fi
test_pass

# ── FAIL OPEN on every degraded input ────────────────────────────────────────
# Each of these must return APPLICABLE. A gate that cannot parse its input has
# learned nothing, and "I learned nothing" must never mean "suppress everything".

test_start "Marker2 fail-open: MALFORMED/truncated JSON -> applicable"
reset_all
_write_raw_config '{ "features": { "lcars_kanban": false'
if ! _xaca0734_launchagents_applicable "$FAKE_WORKING"; then
  test_fail "a config we cannot parse is not a recorded opt-out — it must fail OPEN"
fi
test_pass

test_start "Marker2 fail-open: EMPTY config file -> applicable"
reset_all
: > "$FAKE_WORKING/.aiteamforge-config"
if ! _xaca0734_launchagents_applicable "$FAKE_WORKING"; then
  test_fail "an empty config records no intent"
fi
test_pass

test_start "Marker2 fail-open: config with NO features block -> applicable"
reset_all
_write_raw_config '{"version":"0.0.0","install_dir":"/tmp/x"}'
if ! _xaca0734_launchagents_applicable "$FAKE_WORKING"; then
  test_fail "a config predating the features block (every old install) must be applicable"
fi
test_pass

test_start "Marker2 fail-open: features block present but lcars_kanban key MISSING -> applicable"
reset_all
_write_raw_config '{"features":{"shell_environment":true,"fleet_monitor":false}}'
if ! _xaca0734_launchagents_applicable "$FAKE_WORKING"; then
  test_fail "a missing key is not a false key — absence of a marker is never intent"
fi
test_pass

test_start "Marker2 fail-open: NON-OBJECT JSON root -> applicable (must not error out)"
reset_all
_write_raw_config '[1,2,3]'
if ! _xaca0734_launchagents_applicable "$FAKE_WORKING"; then
  test_fail "indexing .features on an array is a jq hard error — the gate must swallow it and fail open"
fi
test_pass

test_start "Marker2 fail-open: UNREADABLE config (chmod 000) -> applicable"
reset_all
if [ "$(id -u)" = "0" ]; then
  test_pass   # root can read anything; the chmod cannot be exercised
else
  _write_config_kanban "false"
  chmod 000 "$FAKE_WORKING/.aiteamforge-config"
  set +e
  _xaca0734_launchagents_applicable "$FAKE_WORKING"
  _rc=$?
  set -e
  chmod 644 "$FAKE_WORKING/.aiteamforge-config"
  if [ "$_rc" -ne 0 ]; then
    test_fail "a config we cannot READ tells us nothing — claiming it said 'no' is fabricating intent"
  fi
  test_pass
fi

test_start "Marker2 fail-open: jq UNAVAILABLE -> applicable EVEN WITH lcars_kanban=false"
reset_all
_write_config_kanban "false"
# The interpreter is the one dependency the gate cannot verify in advance. With no
# jq on PATH there is deliberately NO grep fallback: the flat grep is exactly the
# false-CLOSE hazard this section exists to remove, and reinstating it on the boxes
# that are ALREADY degraded (no jq) is the worst possible place to put it. No
# parser => no verdict => applicable.
#
# FIXTURE GUARDS — this test is only meaningful if jq is genuinely gone AND a
# fallback tool is genuinely present. Assert both, or a broken fixture makes the
# test silently vacuous (which is precisely what an empty-PATH fixture did).
if ( PATH="$_NOJQ_BIN"; command -v jq >/dev/null 2>&1 ); then
  test_fail "fixture broken: jq is still reachable on the no-jq PATH — this test proves nothing"
fi
if ! ( PATH="$_NOJQ_BIN"; command -v grep >/dev/null 2>&1 ); then
  test_fail "fixture broken: grep is ALSO missing, so this test cannot tell 'refused to guess' from 'no tools at all' — a reinstated grep fallback would slip straight through"
fi
if ! ( PATH="$_NOJQ_BIN"; _xaca0734_launchagents_applicable "$FAKE_WORKING" ); then
  test_fail "no jq means the key could not be read — that is DOUBT, and doubt must fail OPEN, never suppress every mandatory agent"
fi
test_pass
reset_all

# ═══════════════════════════════════════════════════════════════════════════
# XACA-0734-002 — the sentinel is HAND-EDITED, so parse it like a human wrote it
#
# is_opted_out used a raw [ "$line" = "$agent" ] with no trimming, so a trailing
# \r or a stray space made the entry silently NOT match — and the agent the user
# explicitly declined got re-materialized anyway. Silent intent loss: the exact
# failure class this ticket exists to kill.
# ═══════════════════════════════════════════════════════════════════════════

test_start "Sentinel: CRLF line ending still matches (file edited on/synced from Windows)"
reset_all
printf 'com.aiteamforge.auto-upgrade.plist\r\n' > "$AITF_LAUNCHAGENT_OPTOUT_FILE"
if ! _xaca0734_is_opted_out "com.aiteamforge.auto-upgrade.plist"; then
  test_fail "a trailing CR must not silently reverse a hand-recorded opt-out"
fi
test_pass

test_start "Sentinel: leading/trailing SPACES still match"
reset_all
printf '   com.aiteamforge.auto-upgrade.plist   \n' > "$AITF_LAUNCHAGENT_OPTOUT_FILE"
if ! _xaca0734_is_opted_out "com.aiteamforge.auto-upgrade.plist"; then
  test_fail "padding spaces must be trimmed, not treated as part of the basename"
fi
test_pass

test_start "Sentinel: TAB-indented entry still matches"
reset_all
printf '\tcom.aiteamforge.lcars-health.plist\t\n' > "$AITF_LAUNCHAGENT_OPTOUT_FILE"
if ! _xaca0734_is_opted_out "com.aiteamforge.lcars-health.plist"; then
  test_fail "tabs must be trimmed too"
fi
test_pass

test_start "Sentinel: a '#' COMMENT line is NOT an opt-out (a user WILL add comments)"
reset_all
printf '# com.aiteamforge.auto-upgrade.plist  <- disabled once, changed my mind\n' > "$AITF_LAUNCHAGENT_OPTOUT_FILE"
if _xaca0734_is_opted_out "com.aiteamforge.auto-upgrade.plist"; then
  test_fail "a commented-out entry must NOT suppress the agent — that is the opposite of what the comment says"
fi
test_pass

test_start "Sentinel: blank lines and comments coexist with real entries"
reset_all
printf '# my opt-outs\n\n   \ncom.aiteamforge.auto-upgrade.plist\n\n# end\n' > "$AITF_LAUNCHAGENT_OPTOUT_FILE"
if ! _xaca0734_is_opted_out "com.aiteamforge.auto-upgrade.plist"; then
  test_fail "a real entry must still be found among comments and blank lines"
fi
if _xaca0734_is_opted_out "com.aiteamforge.lcars-health.plist"; then
  test_fail "an agent that is NOT listed must not be reported as opted out"
fi
test_pass

test_start "Sentinel: CRLF entry actually SUPPRESSES row 2 end-to-end"
reset_all
printf 'com.aiteamforge.auto-upgrade.plist\r\n' > "$AITF_LAUNCHAGENT_OPTOUT_FILE"
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_not_exists "$AUTO_UPGRADE_PLIST" \
  "the whole point: a CRLF-terminated hand-written opt-out must actually prevent materialization"
assert_file_exists "$LCARS_PLIST" "...while agents that were NOT opted out still materialize"
test_pass

test_start "Sentinel: clear_optout removes a whitespace/CRLF-padded entry"
reset_all
printf '  com.aiteamforge.auto-upgrade.plist  \r\ncom.aiteamforge.lcars-health.plist\n' > "$AITF_LAUNCHAGENT_OPTOUT_FILE"
_xaca0734_clear_optout "com.aiteamforge.auto-upgrade.plist"
if _xaca0734_is_opted_out "com.aiteamforge.auto-upgrade.plist"; then
  test_fail "clear must remove any entry that is_opted_out can SEE, or the user is stuck opted out with no way back"
fi
if ! _xaca0734_is_opted_out "com.aiteamforge.lcars-health.plist"; then
  test_fail "clear_optout must not remove OTHER agents' entries"
fi
test_pass

test_start "Sentinel: clear_optout PRESERVES the user's comments and blank lines"
reset_all
printf '# keep me\ncom.aiteamforge.auto-upgrade.plist\n\n# and me\n' > "$AITF_LAUNCHAGENT_OPTOUT_FILE"
_xaca0734_clear_optout "com.aiteamforge.auto-upgrade.plist"
_after="$(cat "$AITF_LAUNCHAGENT_OPTOUT_FILE")"
assert_contains "$_after" "# keep me" "a hand-maintained file's comments must survive a clear"
assert_contains "$_after" "# and me"  "...all of them"
assert_not_contains "$_after" "com.aiteamforge.auto-upgrade.plist" "...but the cleared entry must be gone"
test_pass

test_start "Sentinel: clear_optout does NOT truncate an UNREADABLE sentinel"
reset_all
if [ "$(id -u)" = "0" ]; then
  test_pass
else
  printf 'com.aiteamforge.auto-upgrade.plist\ncom.aiteamforge.lcars-health.plist\n' > "$AITF_LAUNCHAGENT_OPTOUT_FILE"
  chmod 000 "$AITF_LAUNCHAGENT_OPTOUT_FILE"
  set +e
  _xaca0734_clear_optout "com.aiteamforge.auto-upgrade.plist" >/dev/null 2>&1
  _rc=$?
  set -e
  chmod 644 "$AITF_LAUNCHAGENT_OPTOUT_FILE"
  # The old code ran `grep -v ... || true` then mv'd UNCONDITIONALLY: grep exits 2
  # on a read error, `|| true` swallowed it, and an EMPTY tempfile was moved over
  # the user's entire opt-out list. Silent total data loss.
  _after="$(cat "$AITF_LAUNCHAGENT_OPTOUT_FILE")"
  assert_contains "$_after" "com.aiteamforge.auto-upgrade.plist" "an unreadable sentinel must be left INTACT, never truncated"
  assert_contains "$_after" "com.aiteamforge.lcars-health.plist" "...every entry preserved"
  if [ "$_rc" -eq 0 ]; then
    test_fail "clear_optout must REPORT failure (non-zero) when it cannot read the sentinel"
  fi
  test_pass
fi
reset_all

# ═══════════════════════════════════════════════════════════════════════════
# XACA-0734 review #4/#5 — LOAD VERIFY
#
# `launchctl load` returns 0 even when launchd REJECTS the job, so registration
# is confirmed via `launchctl list`. Both branches are exercised here; before
# this, the stub emitted nothing, so the SUCCESS branch had never once run.
# ═══════════════════════════════════════════════════════════════════════════

test_start "Load-verify: SUCCESS branch reports 'Installed and loaded' (never exercised before)"
reset_all
LAUNCHCTL_LOADED="com.aiteamforge.kanban-backup com.aiteamforge.lcars-health com.aiteamforge.auto-upgrade"
output="$(FORCE=false DRY_RUN=false run_update_launchagents 2>&1)"
assert_contains "$output" "Installed and loaded com.aiteamforge.auto-upgrade.plist" \
  "when launchctl list SHOWS the label, the success branch must run"
assert_not_contains "$output" "did not register" "...and the failure branch must not"
test_pass

test_start "Load-verify: REJECTED branch reports 'did not register' (launchctl load lies with exit 0)"
reset_all
LAUNCHCTL_LOADED=""
output="$(FORCE=false DRY_RUN=false run_update_launchagents 2>&1)"
assert_contains "$output" "did not register" \
  "launchd rejecting the job must be surfaced — 'load' returning 0 proves nothing"
test_pass

test_start "Load-verify: a SUPERSTRING label must NOT count as loaded (substring bug)"
reset_all
LAUNCHCTL_LOADED="com.aiteamforge.auto-upgrade.disabled"
output="$(FORCE=false DRY_RUN=false run_update_launchagents 2>&1)"
assert_contains "$output" "did not register" \
  "'...auto-upgrade.disabled' must NOT satisfy the check for '...auto-upgrade' — grep -q was a substring match"
test_pass

test_start "Load-verify: dots are LITERAL, not regex wildcards"
reset_all
LAUNCHCTL_LOADED="comXaiteamforgeXauto-upgrade"
output="$(FORCE=false DRY_RUN=false run_update_launchagents 2>&1)"
assert_contains "$output" "did not register" \
  "grep -q treats the label's dots as 'any char' — an exact field match must not"
test_pass

test_start "Load-verify helper: exact-label match, positive and negative"
LAUNCHCTL_LOADED="com.aiteamforge.auto-upgrade"
if ! _xaca0734_launchctl_is_loaded "com.aiteamforge.auto-upgrade"; then
  test_fail "an exactly-matching label must be reported as loaded"
fi
if _xaca0734_launchctl_is_loaded "com.aiteamforge.lcars-health"; then
  test_fail "a label absent from launchctl list must not be reported as loaded"
fi
test_pass

# Restore the default stub state.
LAUNCHCTL_LOADED="com.aiteamforge.kanban-backup com.aiteamforge.lcars-health com.aiteamforge.auto-upgrade"
reset_all

# ═══════════════════════════════════════════════════════════════════════════
# XACA-0734 review, BLOCKING 2 — AN ABORTED BATCH UNINSTALL MUST NOT POISON
# THE SENTINEL
#
# install-kanban.sh runs under `set -euo pipefail`. Every uninstall_<x>_launchagent
# used to APPEND its agent to the sentinel, and only the END of the batch wiped it
# again. A Ctrl-C — a completely normal response to an uninstall you started by
# mistake — landing between the two left the sentinel listing every mandatory
# agent, and NOTHING downstream ever clears it (installers refuse an opted-out
# agent; upgrade skips it). Reinstall then produced a box where auto-upgrade could
# never be installed by ANY code path: the original self-sealing bug, resurrected.
#
# These tests drive the REAL functions, extracted from install-kanban.sh.
# ═══════════════════════════════════════════════════════════════════════════

INSTALL_KANBAN_SH="$TAP_ROOT/libexec/installers/install-kanban.sh"

# Pull one top-level function verbatim out of install-kanban.sh.
_extract_func() {
  awk -v fn="$1" '
    index($0, fn "() {") == 1 { c = 1 }
    c { print }
    c && /^\}$/ { exit }
  ' "$INSTALL_KANBAN_SH"
}

for _fn in uninstall_backup_launchagent \
           uninstall_cellar_watch_launchagent \
           uninstall_auto_upgrade_launchagent \
           uninstall_lcars_watch_launchagent \
           uninstall_kanban_system; do
  _body="$(_extract_func "$_fn")"
  if [ -z "$_body" ]; then
    test_start "Extraction sanity: ${_fn} can be pulled from install-kanban.sh"
    test_fail "awk extracted nothing for ${_fn} — the uninstall tests below would be vacuous"
  fi
  eval "$_body"
done
unset _fn _body

# Helpers the extracted functions call, which live elsewhere in install-kanban.sh
# or lib/common.sh. Stubbed inert — nothing here may touch real launchd or a real HOME.
header()  { :; }
info()    { :; }
success() { :; }
warning() { :; }
prompt_yes_no() { return 1; }   # always answer "no" to "Remove kanban board data?"
uninstall_cr_confluence_poller_launchagent() { :; }
uninstall_lcars_runatload_launchagent()      { :; }
uninstall_knowledge_sync_launchagent()       { :; }
# Normally from lib/constants.sh. Referenced only inside the functions eval'd
# above, which shellcheck cannot see into — hence the disable, not a real unused var.
# shellcheck disable=SC2034
KANBAN_BACKUP_LABEL="com.aiteamforge.kanban-backup"

UNINSTALL_HOME="$SANDBOX_DIR/uninstall-home"
UNINSTALL_ROOT="$SANDBOX_DIR/uninstall-root"

_uninstall_sandbox_reset() {
  rm -rf "$UNINSTALL_HOME" "$UNINSTALL_ROOT"
  mkdir -p "$UNINSTALL_HOME/Library/LaunchAgents" "$UNINSTALL_ROOT"
  rm -f "$AITF_LAUNCHAGENT_OPTOUT_FILE"
}

test_start "Extraction sanity: uninstall_kanban_system sets the batch flag"
_uks="$(_extract_func uninstall_kanban_system)"
assert_contains "$_uks" "_XACA0734_BATCH_UNINSTALL=1" \
  "the batch teardown must mark itself, or the per-agent helpers will record opt-outs"
test_pass

test_start "XACA-0734-011: the batch flag is EXPORTED, not a plain shell var"
_uks="$(_extract_func uninstall_kanban_system)"
assert_contains "$_uks" "export _XACA0734_BATCH_UNINSTALL=1" \
  "uninstall_kanban_system is export -f'd, so it is reachable from a separate bash process — a plain var does not travel with it and the child would record an opt-out for every mandatory agent"
test_pass

test_start "Extraction sanity: per-agent uninstall helpers route through the batch-aware recorder"
_uba="$(_extract_func uninstall_auto_upgrade_launchagent)"
assert_contains "$_uba" "_xaca0734_record_optout_unless_batch" \
  "a raw _xaca0734_record_optout here is what poisoned the sentinel on abort"
test_pass

# ─────────────────────────────────────────────────────────────────────────
# XACA-0734-011 — the guard must SURVIVE A PROCESS BOUNDARY.
#
# uninstall_kanban_system is `export -f`'d, so running the teardown in a separate
# bash process (`bash -c`, a find -exec / xargs wrapper, a future installer that
# shells out) is a legitimate, reachable shape. A plain shell variable does not
# cross that boundary: the child runs the entire batch with the guard UNSET, every
# helper falls through to _xaca0734_record_optout, and the sentinel comes out
# listing every mandatory agent — the poisoned, self-sealing box that BLOCKING 2
# exists to prevent, reintroduced by nothing but the caller's choice of invocation.
# ─────────────────────────────────────────────────────────────────────────

test_start "XACA-0734-011: an EXPORTED batch guard suppresses recording across a bash -c boundary"
_uninstall_sandbox_reset
(
  export _XACA0734_BATCH_UNINSTALL=1
  bash -c 'set -euo pipefail; source "$1"; _xaca0734_record_optout_unless_batch "com.aiteamforge.auto-upgrade.plist"' \
    _ "$LAUNCHAGENTS_LIB"
) >/dev/null 2>&1
if [ -f "$AITF_LAUNCHAGENT_OPTOUT_FILE" ]; then
  _got="$(cat "$AITF_LAUNCHAGENT_OPTOUT_FILE")"
  test_fail "the guard must reach the child process; instead the child recorded: ${_got}"
fi
test_pass

# The CONTROL that keeps the test above honest. If a non-exported guard ALSO
# suppressed recording, the test above would pass for the wrong reason and prove
# nothing about the export. This asserts the process boundary is real: with the
# guard set as a plain var (the pre-fix code), the child genuinely DOES record.
test_start "XACA-0734-011 control: a NON-exported guard IS lost across bash -c (boundary is real)"
_uninstall_sandbox_reset
(
  unset _XACA0734_BATCH_UNINSTALL
  _XACA0734_BATCH_UNINSTALL=1          # plain assignment — deliberately NOT exported
  bash -c 'set -euo pipefail; source "$1"; _xaca0734_record_optout_unless_batch "com.aiteamforge.auto-upgrade.plist"' \
    _ "$LAUNCHAGENTS_LIB"
) >/dev/null 2>&1
if [ ! -f "$AITF_LAUNCHAGENT_OPTOUT_FILE" ]; then
  test_fail "control failed: the child recorded nothing even WITHOUT the guard, so the exported-guard test above is vacuous"
fi
test_pass
_uninstall_sandbox_reset

test_start "BLOCKING 2: a COMPLETE batch uninstall records NO opt-outs"
_uninstall_sandbox_reset
( HOME="$UNINSTALL_HOME"; AITEAMFORGE_DIR="$UNINSTALL_ROOT"; uninstall_kanban_system ) >/dev/null 2>&1
if [ -f "$AITF_LAUNCHAGENT_OPTOUT_FILE" ]; then
  _got="$(cat "$AITF_LAUNCHAGENT_OPTOUT_FILE")"
  test_fail "batch uninstall must not write the sentinel at all; it contains: ${_got}"
fi
test_pass

test_start "BLOCKING 2: an ABORTED batch uninstall (Ctrl-C) leaves NO poisoned sentinel"
_uninstall_sandbox_reset
# Abort AFTER auto-upgrade has been torn down — exactly where the old code had
# already appended auto-upgrade to the sentinel and had not yet reached the wipe.
set +e
(
  set -euo pipefail
  HOME="$UNINSTALL_HOME"
  AITEAMFORGE_DIR="$UNINSTALL_ROOT"
  uninstall_lcars_watch_launchagent() { exit 130; }   # simulated SIGINT mid-teardown
  uninstall_kanban_system
) >/dev/null 2>&1
_abort_rc=$?
set -e
if [ "$_abort_rc" -eq 0 ]; then
  test_fail "the abort simulation did not actually abort — this test would be vacuous"
fi
if _xaca0734_is_opted_out "com.aiteamforge.auto-upgrade.plist"; then
  test_fail "ABORTED uninstall left auto-upgrade opted out FOREVER — the box can now never self-upgrade by ANY code path"
fi
if _xaca0734_is_opted_out "com.aiteamforge.kanban-backup.plist"; then
  test_fail "aborted uninstall left kanban-backup opted out"
fi
test_pass

test_start "BLOCKING 2: after an aborted uninstall, a reinstall's upgrade STILL materializes the agents"
# The real-world consequence, end to end: the sentinel is clean, so the box heals.
reset_launchagents
FORCE=false DRY_RUN=false run_update_launchagents >/dev/null 2>&1
assert_file_exists "$AUTO_UPGRADE_PLIST" \
  "this is the payoff — an aborted uninstall must not permanently seal the box against auto-upgrade"
test_pass

test_start "BLOCKING 2: batch uninstall does NOT destroy a user's HAND-EDITED opt-outs"
_uninstall_sandbox_reset
# The old code wiped the ENTIRE sentinel at the end of the batch. Now that nothing
# records during the batch, that wipe is gone — and it MUST be, because its only
# remaining effect would be to silently delete opt-outs a human typed on purpose.
printf '# I run LCARS on the NAS\ncom.aiteamforge.lcars-health.plist\n' > "$AITF_LAUNCHAGENT_OPTOUT_FILE"
( HOME="$UNINSTALL_HOME"; AITEAMFORGE_DIR="$UNINSTALL_ROOT"; uninstall_kanban_system ) >/dev/null 2>&1
if ! _xaca0734_is_opted_out "com.aiteamforge.lcars-health.plist"; then
  test_fail "a hand-recorded opt-out must survive a kanban teardown — silently deleting it is the same intent-loss bug"
fi
_after="$(cat "$AITF_LAUNCHAGENT_OPTOUT_FILE")"
assert_contains "$_after" "# I run LCARS on the NAS" "the user's comment must survive too"
test_pass

test_start "BLOCKING 2: a TARGETED (non-batch) uninstall still DOES record an opt-out"
_uninstall_sandbox_reset
# The primitive must stay correct for a future single-agent uninstall entry point:
# suppressing the record inside the batch must not break recording outside it.
# (AITEAMFORGE_DIR is read by the eval'd installer functions — SC2034 can't see that.)
# shellcheck disable=SC2034
( HOME="$UNINSTALL_HOME"; AITEAMFORGE_DIR="$UNINSTALL_ROOT"; uninstall_auto_upgrade_launchagent ) >/dev/null 2>&1
if ! _xaca0734_is_opted_out "com.aiteamforge.auto-upgrade.plist"; then
  test_fail "a targeted removal IS an opt-out and must be recorded — otherwise upgrade would reinstall what the user just removed"
fi
test_pass

rm -f "$AITF_LAUNCHAGENT_OPTOUT_FILE"
reset_all
