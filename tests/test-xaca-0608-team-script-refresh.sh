#!/bin/bash

# test-xaca-0608-team-script-refresh.sh
# Regression tests for XACA-0608: update_team_scripts() upgrade refresh.
#
# REGRESSION INTENT: Guards against the class of bug where the install path lays
# per-team launch scripts into WORKING_DIR (install-team.sh parametric branch,
# XACA-0483/0484: <team>-startup.sh, <team>-shutdown.sh, and <team>/scripts/*.sh
# station scripts, with a ~/dev-team -> $AITEAMFORGE_DIR path rewrite) but the
# upgrade command never refreshes them. Before this fix, a `brew upgrade` that
# shipped a newer <team>-startup.sh to the Cellar left the working-dir copy
# FROZEN at install-time (e.g. M1Pro on 0.12.12 still ran the old cksum LCARS
# port logic instead of the XACA-0590 resolve_lcars_port resolver). Same refresh-
# gap class as XACA-0558 (kanban-hooks) / XACA-0585 (lcars-health).
#
# Assertions:
#   1. Tap ships team scripts under share/scripts/teams/ (at least one *-startup.sh).
#   2. update_team_scripts() refreshes an ALREADY-INSTALLED <team>-startup.sh and
#      applies the ~/dev-team -> WORKING_DIR path rewrite (matches install).
#   3. update_team_scripts() does NOT materialise a team that is not installed
#      (no working-dir target present -> left absent).
#   4. Station scripts under <team>/scripts/ are refreshed (with rewrite) when the
#      station dir already exists.
#   5. Refreshed scripts keep their exec bit.
#   6. --dry-run makes no on-disk changes.
#   7. Missing source dir -> function skips gracefully (exit 0, no crash).
#   8. update_team_scripts is wired into the upgrade run sequence (source grep).
#
# All filesystem activity is sandboxed to TEST_TMP_DIR.
# NEVER touches real $HOME / ~/.aiteamforge — installer-test safety rule.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: works both as a sourced test-runner.sh file AND as a
# directly-invoked script (mirrors test-xaca-0585 / 0588 pattern).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""

    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }

    assert_file_exists() {
        local file="$1" msg="${2:-Expected file to exist: $1}"
        [ -f "$file" ] || { test_fail "$msg"; return 1; }
    }
    assert_file_not_exists() {
        local file="$1" msg="${2:-Expected file to not exist: $1}"
        [ ! -f "$file" ] || { test_fail "$msg"; return 1; }
    }
    assert_contains() {
        local haystack="$1" needle="$2" msg="${3:-Expected to find '$2' in string}"
        [[ "$haystack" == *"$needle"* ]] || { test_fail "$msg"; return 1; }
    }
    assert_not_contains() {
        local haystack="$1" needle="$2" msg="${3:-Expected NOT to find '$2' in string}"
        [[ "$haystack" != *"$needle"* ]] || { test_fail "$msg"; return 1; }
    }
fi

# assert_not_contains may not exist in the shared runner — provide a fallback.
if ! type -t assert_not_contains >/dev/null 2>&1; then
    assert_not_contains() {
        local haystack="$1" needle="$2" msg="${3:-Expected NOT to find '$2' in string}"
        [[ "$haystack" != *"$needle"* ]] || { test_fail "$msg"; return 1; }
    }
fi

# print_* stubs used by the extracted function (provided by test-runner.sh when
# sourced; no-op fallback when standalone).
for _p in print_section print_info print_success print_warning print_error; do
    if ! declare -f "$_p" >/dev/null 2>&1; then
        eval "${_p}() { :; }"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory: use the runner-supplied TEST_TMP_DIR or create our own.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0608-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Extract update_team_scripts + its renderer helper from upgrade.sh, rather than
# sourcing the whole script (the main body has side effects: is_configured,
# get_framework_dir, etc.). Capture from the renderer helper through the closing
# brace of update_team_scripts — two top-level closing braces.
# ─────────────────────────────────────────────────────────────────────────────
_extracted_funcs="$(awk '
  /^_xaca0608_render_team_script\(\) \{/ { capture=1 }
  capture { print }
  /^}$/ && capture {
    brace_count++
    if (brace_count == 2) { capture=0 }
  }
' "$UPGRADE_SH")"

if [ -z "$_extracted_funcs" ]; then
    test_start "Sanity: can extract update_team_scripts from upgrade.sh"
    test_fail "awk returned empty — could not extract _xaca0608_render_team_script + update_team_scripts"
    if [ "$_STANDALONE" = true ]; then echo "Results: ${_PASS_COUNT} passed, $((_FAIL_COUNT + 1)) failed"; fi
    exit 1
fi

eval "$_extracted_funcs"

declare -f _xaca0608_render_team_script >/dev/null || \
    { echo "FATAL: _xaca0608_render_team_script not extracted from upgrade.sh"; exit 1; }
declare -f update_team_scripts >/dev/null || \
    { echo "FATAL: update_team_scripts not extracted from upgrade.sh"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Pick a real shipped team to drive the data-bearing tests. Derive from the tap's
# share/scripts/teams/*-startup.sh — self-maintaining, like the function itself.
# ─────────────────────────────────────────────────────────────────────────────
TEAMS_SRC="$TAP_ROOT/share/scripts/teams"
TEST_TEAM=""
for _s in "$TEAMS_SRC"/*-startup.sh; do
    [ -f "$_s" ] || continue
    TEST_TEAM="$(basename "$_s" -startup.sh)"
    break
done

# ═══════════════════════════════════════════════════════════════════════════
# TEST 1: Tap ships team launch scripts
# ═══════════════════════════════════════════════════════════════════════════

test_start "Tap ships at least one <team>-startup.sh under share/scripts/teams/"
if [ -n "$TEST_TEAM" ]; then
    test_pass
else
    test_fail "No *-startup.sh found under $TEAMS_SRC — nothing for upgrade to refresh"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Sandbox: a fake WORKING_DIR seeded with a STALE installed copy of the team
# startup script (path already rewritten, but content marked stale) so we can
# prove the refresh overwrites it with current framework content.
# ═══════════════════════════════════════════════════════════════════════════

SANDBOX="$TEST_TMP_DIR/xaca0608"
FAKE_WORKING="$SANDBOX/working"
mkdir -p "$FAKE_WORKING"

run_update_team_scripts() {
    # Callers set FORCE / DRY_RUN before calling.
    FRAMEWORK_DIR="$TAP_ROOT" \
    WORKING_DIR="$FAKE_WORKING" \
    update_team_scripts 2>&1
}

if [ -n "$TEST_TEAM" ]; then
    INSTALLED_STARTUP="$FAKE_WORKING/${TEST_TEAM}-startup.sh"

    # ═══════════════════════════════════════════════════════════════════════
    # TEST 2: installed startup is refreshed + path rewrite applied
    # ═══════════════════════════════════════════════════════════════════════
    test_start "update_team_scripts refreshes an installed <team>-startup.sh"
    # Seed a stale installed copy
    printf '#!/bin/zsh\n# STALE-SENTINEL-XACA-0608\necho stale\n' > "$INSTALLED_STARTUP"
    chmod +x "$INSTALLED_STARTUP"
    FORCE=false DRY_RUN=false run_update_team_scripts >/dev/null 2>&1
    REFRESHED="$(cat "$INSTALLED_STARTUP" 2>/dev/null)"
    assert_not_contains "$REFRESHED" "STALE-SENTINEL-XACA-0608" \
        "Stale installed startup should be overwritten with current framework content"
    test_pass

    test_start "Refreshed startup matches current framework content (modulo path rewrite)"
    # The framework source has ~/dev-team refs; the refreshed copy must NOT.
    # SC2088: the tilde here is a LITERAL substring we assert is ABSENT, not a path
    # to be expanded — leaving it unexpanded is exactly the intent.
    # shellcheck disable=SC2088
    assert_not_contains "$REFRESHED" "~/dev-team" \
        "Refreshed script must have ~/dev-team rewritten to WORKING_DIR"
    # And it must contain the rewritten WORKING_DIR where the source had a dev-team path.
    if grep -q "dev-team" "$TEAMS_SRC/${TEST_TEAM}-startup.sh" 2>/dev/null; then
        assert_contains "$REFRESHED" "$FAKE_WORKING" \
            "Refreshed script must contain WORKING_DIR after ~/dev-team rewrite"
    fi
    test_pass

    test_start "Refreshed startup retains exec bit"
    if [ -x "$INSTALLED_STARTUP" ]; then
        test_pass
    else
        test_fail "Refreshed <team>-startup.sh must remain executable"
    fi

    # ═══════════════════════════════════════════════════════════════════════
    # TEST 3: not-installed team is NOT materialised
    # ═══════════════════════════════════════════════════════════════════════
    test_start "update_team_scripts does NOT create scripts for a non-installed team"
    rm -f "$INSTALLED_STARTUP" "$FAKE_WORKING/${TEST_TEAM}-shutdown.sh"
    FORCE=false DRY_RUN=false run_update_team_scripts >/dev/null 2>&1
    assert_file_not_exists "$INSTALLED_STARTUP" \
        "Upgrade must not materialise <team>-startup.sh for a team the user never installed"
    test_pass

    # ═══════════════════════════════════════════════════════════════════════
    # TEST 4: station scripts refreshed when the station dir already exists
    # ═══════════════════════════════════════════════════════════════════════
    STATION_SRC_DIR="$TEAMS_SRC/${TEST_TEAM}/scripts"
    if [ -d "$STATION_SRC_DIR" ]; then
        # find a station script name
        STATION_NAME=""
        for _ss in "$STATION_SRC_DIR"/*.sh; do
            [ -f "$_ss" ] || continue
            STATION_NAME="$(basename "$_ss")"
            break
        done
        if [ -n "$STATION_NAME" ]; then
            test_start "Station scripts refreshed when <team>/scripts/ already exists"
            mkdir -p "$FAKE_WORKING/${TEST_TEAM}/scripts"
            INSTALLED_STATION="$FAKE_WORKING/${TEST_TEAM}/scripts/${STATION_NAME}"
            printf '#!/bin/zsh\n# STALE-STATION-XACA-0608\n' > "$INSTALLED_STATION"
            chmod +x "$INSTALLED_STATION"
            FORCE=false DRY_RUN=false run_update_team_scripts >/dev/null 2>&1
            STATION_AFTER="$(cat "$INSTALLED_STATION" 2>/dev/null)"
            assert_not_contains "$STATION_AFTER" "STALE-STATION-XACA-0608" \
                "Installed station script should be refreshed with current framework content"
            # shellcheck disable=SC2088
            assert_not_contains "$STATION_AFTER" "~/dev-team" \
                "Refreshed station script must have ~/dev-team rewritten"
            test_pass

            test_start "Refreshed station script retains exec bit"
            if [ -x "$INSTALLED_STATION" ]; then test_pass; else
                test_fail "Refreshed station script must remain executable"; fi
        fi
    fi

    # ═══════════════════════════════════════════════════════════════════════
    # TEST 5: --dry-run makes no on-disk changes
    # ═══════════════════════════════════════════════════════════════════════
    test_start "--dry-run does not modify an installed startup"
    printf '#!/bin/zsh\n# DRYRUN-SENTINEL-XACA-0608\n' > "$INSTALLED_STARTUP"
    chmod +x "$INSTALLED_STARTUP"
    FORCE=false DRY_RUN=true run_update_team_scripts >/dev/null 2>&1
    DRY_AFTER="$(cat "$INSTALLED_STARTUP" 2>/dev/null)"
    assert_contains "$DRY_AFTER" "DRYRUN-SENTINEL-XACA-0608" \
        "--dry-run must leave the installed file unchanged"
    test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 6: missing source dir -> graceful skip (exit 0, no crash)
# ═══════════════════════════════════════════════════════════════════════════
test_start "Missing share/scripts/teams source -> function skips gracefully (exit 0)"
MISSING_EXIT=$(
    (
        FRAMEWORK_DIR="$SANDBOX/fake-empty-framework" \
        WORKING_DIR="$FAKE_WORKING" \
        DRY_RUN=false FORCE=false \
        update_team_scripts >/dev/null 2>&1
    )
    echo $?
)
if [ "$MISSING_EXIT" = "0" ]; then
    test_pass
else
    test_fail "update_team_scripts must exit 0 when source dir missing (got: $MISSING_EXIT)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 7: update_team_scripts is wired into the upgrade run sequence
# ═══════════════════════════════════════════════════════════════════════════
test_start "update_team_scripts is invoked in the upgrade run sequence"
# The run sequence is a series of bare function-call lines near the bottom.
# Require the call to appear as a standalone line (not just the definition).
if grep -qE '^update_team_scripts$' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "aiteamforge-upgrade.sh run sequence must call update_team_scripts"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone mode only — test-runner.sh tallies from its own counters).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    if [ "$_FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
fi
exit 0
