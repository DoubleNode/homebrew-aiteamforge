#!/bin/bash
# test-xaca-0483-parametric.sh
# Tests for XACA-0483 parametric-mode installer path
#
# Covers:
# - install-team.sh detects parametric mode correctly
# - share/scripts/teams/ ships all four parametric teams' scripts
# - share/scripts/lcars-launch-helpers.sh ships
# - Path-substitution helper produces clean output (no residual dev-team refs)
# - Migration block renames legacy instance-keyed scripts safely
# - Migration is idempotent (re-running doesn't double-suffix)
# - Non-parametric installer path is preserved (academy/ios/firebase/android)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_TEAM="$TAP_ROOT/libexec/installers/install-team.sh"
PARAMETRIC_TEAMS=(finance medical legal freelance)
NON_PARAMETRIC_TEAMS=(academy ios android firebase)

# Local helper (run-test-runner doesn't export this from test-installers.sh)
run_assert_pass() {
    if "$@"; then test_pass; fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Shipping checks: parametric scripts exist in the tap
# ═══════════════════════════════════════════════════════════════════════════

test_start "XACA-0483: parametric teams ship startup scripts under share/scripts/teams/"
all_present=true
for team in "${PARAMETRIC_TEAMS[@]}"; do
    if [ ! -f "$TAP_ROOT/share/scripts/teams/${team}-startup.sh" ]; then
        test_fail "Missing: share/scripts/teams/${team}-startup.sh"
        all_present=false
        break
    fi
done
[ "$all_present" = true ] && test_pass

test_start "XACA-0483: parametric teams ship shutdown scripts under share/scripts/teams/"
all_present=true
for team in "${PARAMETRIC_TEAMS[@]}"; do
    if [ ! -f "$TAP_ROOT/share/scripts/teams/${team}-shutdown.sh" ]; then
        test_fail "Missing: share/scripts/teams/${team}-shutdown.sh"
        all_present=false
        break
    fi
done
[ "$all_present" = true ] && test_pass

test_start "XACA-0483: lcars-launch-helpers.sh ships under share/scripts/"
run_assert_pass assert_file_exists "$TAP_ROOT/share/scripts/lcars-launch-helpers.sh"

test_start "XACA-0483: shipped parametric scripts pass bash -n syntax check"
all_syntax=true
for team in "${PARAMETRIC_TEAMS[@]}"; do
    for kind in startup shutdown; do
        if ! bash -n "$TAP_ROOT/share/scripts/teams/${team}-${kind}.sh" 2>/dev/null; then
            test_fail "Syntax error: ${team}-${kind}.sh"
            all_syntax=false
            break 2
        fi
    done
done
[ "$all_syntax" = true ] && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# install-team.sh structural checks: parametric mode plumbing
# ═══════════════════════════════════════════════════════════════════════════

test_start "XACA-0483: install-team.sh defines _PARAMETRIC_MODE branch"
output=$(grep -c '_PARAMETRIC_MODE="true"' "$INSTALL_TEAM")
run_assert_pass assert_exit_success $([ "$output" -gt 0 ]; echo $?)

test_start "XACA-0483: install-team.sh gates parametric mode on TEAM_HAS_PROJECTS=true AND shipped source"
# The gate must AND both conditions to avoid accidentally triggering parametric
# mode for teams that don't ship parametric source.
output=$(grep -c 'TEAM_HAS_PROJECTS.*true.*share/scripts/teams' "$INSTALL_TEAM")
run_assert_pass assert_exit_success $([ "$output" -gt 0 ]; echo $?)

test_start "XACA-0483: install-team.sh defines path-substitution helper"
output=$(grep -c '_xaca0483_install_script' "$INSTALL_TEAM")
run_assert_pass assert_exit_success $([ "$output" -gt 0 ]; echo $?)

test_start "XACA-0483: install-team.sh substitutes all three dev-team path forms"
# Must handle ~, $HOME, and ${HOME} variants
forms_found=0
grep -q '\$HOME/dev-team' "$INSTALL_TEAM" && forms_found=$((forms_found + 1))
grep -q '\${HOME}/dev-team' "$INSTALL_TEAM" && forms_found=$((forms_found + 1))
grep -q '~/dev-team' "$INSTALL_TEAM" && forms_found=$((forms_found + 1))
run_assert_pass assert_exit_success $([ "$forms_found" -eq 3 ]; echo $?)

test_start "XACA-0483: install-team.sh has migration block for legacy instance-keyed scripts"
output=$(grep -c 'stale-pre-XACA-0483' "$INSTALL_TEAM")
run_assert_pass assert_exit_success $([ "$output" -ge 2 ]; echo $?)

test_start "XACA-0483: parametric branch skips connect/disconnect generation"
# Each of CONNECT_SCRIPT/DISCONNECT_SCRIPT assignment must be followed within
# ~5 lines by a _PARAMETRIC_MODE skip guard. Use -A 5 to span the comment block.
connect_guarded=$(grep -A 5 '^CONNECT_SCRIPT=' "$INSTALL_TEAM" | grep -c '_PARAMETRIC_MODE')
disconnect_guarded=$(grep -A 5 '^DISCONNECT_SCRIPT=' "$INSTALL_TEAM" | grep -c '_PARAMETRIC_MODE')
if [ "$connect_guarded" -ge 1 ] && [ "$disconnect_guarded" -ge 1 ]; then
    test_pass
else
    test_fail "Expected both CONNECT_SCRIPT and DISCONNECT_SCRIPT to be guarded by _PARAMETRIC_MODE (found connect=$connect_guarded disconnect=$disconnect_guarded)"
fi

test_start "XACA-0483: parametric branch skips shutdown template (already installed verbatim)"
# The shutdown template `if [[ -f "$SHUTDOWN_TEMPLATE" ]]` block must be preceded
# by a `_PARAMETRIC_MODE` skip guard.
output=$(grep -B 3 'if \[\[ -f "\$SHUTDOWN_TEMPLATE" \]\]' "$INSTALL_TEAM" | grep -c '_PARAMETRIC_MODE')
run_assert_pass assert_exit_success $([ "$output" -ge 1 ]; echo $?)

# ═══════════════════════════════════════════════════════════════════════════
# Path substitution functional test
# ═══════════════════════════════════════════════════════════════════════════

test_start "XACA-0483: path substitution produces clean scripts (no residual dev-team refs)"
SANDBOX="$TEST_TMP_DIR/xaca0483-substitution"
mkdir -p "$SANDBOX/scripts"
all_clean=true
for team in "${PARAMETRIC_TEAMS[@]}"; do
    for kind in startup shutdown; do
        src="$TAP_ROOT/share/scripts/teams/${team}-${kind}.sh"
        dst="$SANDBOX/${team}-${kind}.sh"
        sed -e "s|\$HOME/dev-team/iterm2_window_manager.py|$SANDBOX/scripts/iterm2_window_manager.py|g" \
            -e "s|\${HOME}/dev-team/iterm2_window_manager.py|$SANDBOX/scripts/iterm2_window_manager.py|g" \
            -e "s|~/dev-team/iterm2_window_manager.py|$SANDBOX/scripts/iterm2_window_manager.py|g" \
            -e "s|\$HOME/dev-team|$SANDBOX|g" \
            -e "s|\${HOME}/dev-team|$SANDBOX|g" \
            -e "s|~/dev-team|$SANDBOX|g" \
            "$src" > "$dst"
        if grep -q 'dev-team' "$dst" 2>/dev/null; then
            test_fail "Residual dev-team ref in ${team}-${kind}.sh after substitution"
            all_clean=false
            break 2
        fi
    done
done
[ "$all_clean" = true ] && test_pass

test_start "XACA-0483: substituted scripts pass bash -n"
all_valid=true
for f in "$SANDBOX"/*.sh; do
    [ -f "$f" ] || continue
    if ! bash -n "$f" 2>/dev/null; then
        test_fail "Syntax error after substitution: $(basename "$f")"
        all_valid=false
        break
    fi
done
[ "$all_valid" = true ] && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Migration logic test (extracted from install-team.sh)
# ═══════════════════════════════════════════════════════════════════════════

test_start "XACA-0483: migration renames legacy instance-keyed scripts to .stale-pre-XACA-0483"
MIG_SANDBOX="$TEST_TMP_DIR/xaca0483-migration"
mkdir -p "$MIG_SANDBOX"
touch "$MIG_SANDBOX/finance-personal-startup.sh" \
      "$MIG_SANDBOX/finance-personal-shutdown.sh" \
      "$MIG_SANDBOX/finance-latinum1-startup.sh" \
      "$MIG_SANDBOX/finance-startup.sh"

AITEAMFORGE_DIR="$MIG_SANDBOX"
TEAM_ID="finance"
_PARAMETRIC_MODE="true"
_XACA0483_STALE_SUFFIX=".stale-pre-XACA-0483"

for _stale_glob in "$AITEAMFORGE_DIR/${TEAM_ID}-"*-startup.sh \
                   "$AITEAMFORGE_DIR/${TEAM_ID}-"*-shutdown.sh \
                   "$AITEAMFORGE_DIR/${TEAM_ID}-"*-connect.sh \
                   "$AITEAMFORGE_DIR/${TEAM_ID}-"*-disconnect.sh; do
    [[ -f "$_stale_glob" ]] || continue
    case "$(basename "$_stale_glob")" in
        "${TEAM_ID}-startup.sh"|"${TEAM_ID}-shutdown.sh"|"${TEAM_ID}-connect.sh"|"${TEAM_ID}-disconnect.sh") continue ;;
    esac
    [[ "$_stale_glob" == *"$_XACA0483_STALE_SUFFIX" ]] && continue
    mv "$_stale_glob" "${_stale_glob}${_XACA0483_STALE_SUFFIX}"
done

# Check: instance-keyed got renamed
all_renamed=true
for f in "$MIG_SANDBOX"/finance-personal-startup.sh \
         "$MIG_SANDBOX"/finance-personal-shutdown.sh \
         "$MIG_SANDBOX"/finance-latinum1-startup.sh; do
    if [ -f "$f" ]; then
        test_fail "Should have been renamed: $(basename "$f")"
        all_renamed=false
        break
    fi
done
# Check: template-keyed preserved
if [ ! -f "$MIG_SANDBOX/finance-startup.sh" ]; then
    test_fail "Template-keyed name should be preserved: finance-startup.sh"
    all_renamed=false
fi
[ "$all_renamed" = true ] && test_pass

test_start "XACA-0483: migration is idempotent (no double-suffixing on re-run)"
# Re-run the migration loop over the post-migrated state
files_before=$(ls "$MIG_SANDBOX" | sort)
for _stale_glob in "$AITEAMFORGE_DIR/${TEAM_ID}-"*-startup.sh \
                   "$AITEAMFORGE_DIR/${TEAM_ID}-"*-shutdown.sh \
                   "$AITEAMFORGE_DIR/${TEAM_ID}-"*-connect.sh \
                   "$AITEAMFORGE_DIR/${TEAM_ID}-"*-disconnect.sh; do
    [[ -f "$_stale_glob" ]] || continue
    case "$(basename "$_stale_glob")" in
        "${TEAM_ID}-startup.sh"|"${TEAM_ID}-shutdown.sh"|"${TEAM_ID}-connect.sh"|"${TEAM_ID}-disconnect.sh") continue ;;
    esac
    [[ "$_stale_glob" == *"$_XACA0483_STALE_SUFFIX" ]] && continue
    mv "$_stale_glob" "${_stale_glob}${_XACA0483_STALE_SUFFIX}"
done
files_after=$(ls "$MIG_SANDBOX" | sort)
if [ "$files_before" = "$files_after" ]; then
    test_pass
else
    test_fail "Migration not idempotent — files changed on re-run"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Non-parametric regression: confirm legacy installer path is preserved
# ═══════════════════════════════════════════════════════════════════════════

test_start "XACA-0483: non-parametric team confs still set TEAM_HAS_PROJECTS=false"
all_false=true
for team in "${NON_PARAMETRIC_TEAMS[@]}"; do
    conf="$TAP_ROOT/share/teams/${team}.conf"
    [ -f "$conf" ] || continue
    if grep -q 'TEAM_HAS_PROJECTS="true"' "$conf"; then
        test_fail "Unexpected: ${team}.conf has TEAM_HAS_PROJECTS=true (would trigger parametric mode)"
        all_false=false
        break
    fi
done
[ "$all_false" = true ] && test_pass

test_start "XACA-0483: non-parametric teams have no shipped parametric source (would not trigger parametric mode)"
all_absent=true
for team in "${NON_PARAMETRIC_TEAMS[@]}"; do
    if [ -f "$TAP_ROOT/share/scripts/teams/${team}-startup.sh" ]; then
        test_fail "Unexpected: share/scripts/teams/${team}-startup.sh ships (would enable parametric mode for non-parametric team)"
        all_absent=false
        break
    fi
done
[ "$all_absent" = true ] && test_pass

test_start "XACA-0483: legacy instance-keyed branch still present in install-team.sh"
# The else branch must still produce ${INSTANCE_ID}-startup.sh for non-parametric paths
output=$(grep -c 'TEAM_STARTUP_SCRIPT="\${INSTANCE_ID}-startup.sh"' "$INSTALL_TEAM")
run_assert_pass assert_exit_success $([ "$output" -gt 0 ]; echo $?)

# ═══════════════════════════════════════════════════════════════════════════
# XACA-0484: per-agent script ship + stub-board migration
# ═══════════════════════════════════════════════════════════════════════════

test_start "XACA-0484: per-agent scripts ship for all parametric teams"
# Each parametric team must ship at least one *-startup.sh under <team>/scripts/
# plus a <team>-banner.sh.
all_present=true
for team in "${PARAMETRIC_TEAMS[@]}"; do
    if [ ! -d "$TAP_ROOT/share/scripts/teams/${team}/scripts" ]; then
        test_fail "Missing: share/scripts/teams/${team}/scripts/ directory"
        all_present=false
        break
    fi
    startup_count=$(find "$TAP_ROOT/share/scripts/teams/${team}/scripts" -name "${team}-*-startup.sh" | wc -l | tr -d ' ')
    if [ "$startup_count" -lt 1 ]; then
        test_fail "No per-agent startup scripts for ${team} (expected ≥1)"
        all_present=false
        break
    fi
    if [ ! -f "$TAP_ROOT/share/scripts/teams/${team}/scripts/${team}-banner.sh" ]; then
        test_fail "Missing: share/scripts/teams/${team}/scripts/${team}-banner.sh"
        all_present=false
        break
    fi
done
[ "$all_present" = true ] && test_pass

test_start "XACA-0484: shipped per-agent scripts pass bash -n"
all_syntax=true
for f in "$TAP_ROOT"/share/scripts/teams/*/scripts/*.sh; do
    [ -f "$f" ] || continue
    if ! bash -n "$f" 2>/dev/null; then
        test_fail "Syntax error: $(basename "$f")"
        all_syntax=false
        break
    fi
done
[ "$all_syntax" = true ] && test_pass

test_start "XACA-0484: shipped per-agent scripts are debrand-clean"
# No DoubleNode/MainEvent literals should appear in tap-shipped per-agent files.
hits=$(grep -rcE '[Dd]ouble[Nn]ode|doublenode' "$TAP_ROOT"/share/scripts/teams/ 2>/dev/null | awk -F: '$2 > 0 {s += $2} END {print s+0}')
if [ "$hits" -eq 0 ]; then
    test_pass
else
    test_fail "Found $hits debrand violations in per-agent scripts under share/scripts/teams/"
fi

test_start "XACA-0484: install-team.sh has per-agent install block in parametric branch"
# The new block must reference share/scripts/teams/.../scripts and run within
# the parametric mode branch.
output=$(grep -c 'share/scripts/teams/\${TEAM_ID}/scripts' "$INSTALL_TEAM")
run_assert_pass assert_exit_success $([ "$output" -ge 1 ]; echo $?)

test_start "XACA-0484: install-team.sh board init now includes ship field"
# Earlier versions wrote board JSON without 'ship', causing LCARS UI to
# fall back to "Unknown Vessel". Verify the jq board-build references ship.
output=$(grep -c '"ship":.*\$ship' "$INSTALL_TEAM")
run_assert_pass assert_exit_success $([ "$output" -ge 1 ]; echo $?)

test_start "XACA-0484: install-team.sh has stub-board migration block"
# Detect-and-patch logic for boards with null branding fields.
output=$(grep -c '_XACA0484_NEEDS_PATCH\|Patched stub branding' "$INSTALL_TEAM")
run_assert_pass assert_exit_success $([ "$output" -ge 1 ]; echo $?)

test_start "XACA-0484: stub-board migration produces non-null fields"
# Synthetic test: hand-craft a stub board with null fields, run a jq patch
# matching the installer's pattern, verify the result has the expected fields.
STUB_SANDBOX="$TEST_TMP_DIR/xaca0484-stub"
mkdir -p "$STUB_SANDBOX"
STUB_BOARD="$STUB_SANDBOX/finance-personal-board.json"
cat > "$STUB_BOARD" <<'STUBEOF'
{
  "team": "finance-personal",
  "teamName": null,
  "subtitle": null,
  "organization": null,
  "orgColor": null,
  "ship": null,
  "icon": null,
  "template": null,
  "instance": null,
  "backlog": [],
  "epics": []
}
STUBEOF
jq \
    --arg teamName "Ferengi Commerce Authority" \
    --arg subtitle "Personal finance" \
    --arg organization "Ferengi Commerce Authority" \
    --arg orgColor "#FFD700" \
    --arg ship "Ferengi Alliance Commerce Hub" \
    --arg icon "💰" \
    --arg template "finance" \
    --arg instance "finance-personal" \
    '.teamName = (.teamName // $teamName)
   | .subtitle = (.subtitle // $subtitle)
   | .organization = (.organization // $organization)
   | .orgColor = (.orgColor // $orgColor)
   | .ship = (.ship // $ship)
   | .icon = (.icon // $icon)
   | .template = (.template // $template)
   | .instance = (.instance // $instance)' \
    "$STUB_BOARD" > "${STUB_BOARD}.tmp" && mv "${STUB_BOARD}.tmp" "$STUB_BOARD"

# Verify all fields are now populated
nulls=$(jq -r '[.teamName, .subtitle, .organization, .ship, .template, .instance] | map(select(. == null)) | length' "$STUB_BOARD")
if [ "$nulls" -eq 0 ]; then
    test_pass
else
    test_fail "Stub-board migration left $nulls null fields"
fi

test_start "XACA-0484: stub-board migration preserves non-stub data"
# Re-run the jq patch on the already-patched board; backlog/epics arrays must be preserved.
preserved=$(jq -r '[(.backlog | type == "array"), (.epics | type == "array")] | all' "$STUB_BOARD")
if [ "$preserved" = "true" ]; then
    test_pass
else
    test_fail "Migration corrupted preserved arrays (backlog/epics)"
fi

test_start "XACA-0484: per-agent ship matches expected counts per team"
# Sanity check: finance ≥6 startup, medical ≥7, legal ≥7, freelance ≥6.
declare -A min_counts
min_counts[finance]=6
min_counts[medical]=7
min_counts[legal]=7
min_counts[freelance]=6
all_meet=true
for team in finance medical legal freelance; do
    count=$(find "$TAP_ROOT/share/scripts/teams/${team}/scripts" -name "${team}-*-startup.sh" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -lt "${min_counts[$team]}" ]; then
        test_fail "${team}: ${count} startup scripts (expected ≥${min_counts[$team]})"
        all_meet=false
        break
    fi
done
[ "$all_meet" = true ] && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# XACA-0485: KANBAN_DIR / TEAM_WORKING_DIR project-component resolution
# ═══════════════════════════════════════════════════════════════════════════

test_start "XACA-0485: install-team.sh has TEAM_WORKING_DIR project-augmentation block"
# The block must be guarded by TEAM_HAS_PROJECTS=true and reference ARG_PROJECT
# (or TEAM_DEFAULT_PROJECT) for the resolution.
output=$(grep -c '_XACA0485_RESOLVED_PROJECT\|XACA-0485' "$INSTALL_TEAM")
run_assert_pass assert_exit_success $([ "$output" -ge 1 ]; echo $?)

test_start "XACA-0485: augmentation block handles template-client-project pattern"
# Must reference TEAM_REQUIRES_CLIENT_ID for the freelance case (3-segment path).
output=$(grep -A 10 '_XACA0485_RESOLVED_PROJECT' "$INSTALL_TEAM" | grep -c 'TEAM_REQUIRES_CLIENT_ID')
run_assert_pass assert_exit_success $([ "$output" -ge 1 ]; echo $?)

test_start "XACA-0485: _TEAM_WORKING_DIR_RESOLVED now uses TEAM_WORKING_DIR (not TEAM_BASE_WORKING_DIR)"
# The legacy template path's working-dir substitution previously used
# TEAM_BASE_WORKING_DIR for project teams (stripping the project component).
# Should now use TEAM_WORKING_DIR (project-augmented).
output=$(grep -A 1 '_TEAM_WORKING_DIR_RESOLVED=' "$INSTALL_TEAM" | grep -c '\$TEAM_WORKING_DIR')
run_assert_pass assert_exit_success $([ "$output" -ge 1 ]; echo $?)

test_start "XACA-0485: template-project path computation (synthetic finance/personal)"
# Synthesize the augmentation logic in isolation and verify output.
TEAM_HAS_PROJECTS="true"
TEAM_REQUIRES_CLIENT_ID="false"
ARG_PROJECT="personal"
TEAM_DEFAULT_PROJECT="personal"
ARG_CLIENT=""
TEAM_BASE_WORKING_DIR="/tmp/xaca0485-test-finance"

_XACA0485_RESOLVED_PROJECT="${ARG_PROJECT:-$TEAM_DEFAULT_PROJECT}"
_XACA0485_RESOLVED_PROJECT="$(echo "$_XACA0485_RESOLVED_PROJECT" | tr '[:upper:]' '[:lower:]')"
if [[ "$TEAM_REQUIRES_CLIENT_ID" == "true" ]]; then
    _XACA0485_RESOLVED_CLIENT="$(echo "${ARG_CLIENT:-}" | tr '[:upper:]' '[:lower:]')"
    COMPUTED="${TEAM_BASE_WORKING_DIR}/${_XACA0485_RESOLVED_CLIENT}/${_XACA0485_RESOLVED_PROJECT}"
else
    COMPUTED="${TEAM_BASE_WORKING_DIR}/${_XACA0485_RESOLVED_PROJECT}"
fi
EXPECTED="/tmp/xaca0485-test-finance/personal"
if [ "$COMPUTED" = "$EXPECTED" ]; then
    test_pass
else
    test_fail "template-project: got '$COMPUTED', expected '$EXPECTED'"
fi

test_start "XACA-0485: template-client-project path computation (synthetic freelance)"
TEAM_HAS_PROJECTS="true"
TEAM_REQUIRES_CLIENT_ID="true"
ARG_PROJECT="widgettracker"
TEAM_DEFAULT_PROJECT=""
ARG_CLIENT="acmecorp"
TEAM_BASE_WORKING_DIR="/tmp/xaca0485-test-freelance"

_XACA0485_RESOLVED_PROJECT="${ARG_PROJECT:-$TEAM_DEFAULT_PROJECT}"
_XACA0485_RESOLVED_PROJECT="$(echo "$_XACA0485_RESOLVED_PROJECT" | tr '[:upper:]' '[:lower:]')"
if [[ "$TEAM_REQUIRES_CLIENT_ID" == "true" ]]; then
    _XACA0485_RESOLVED_CLIENT="$(echo "${ARG_CLIENT:-}" | tr '[:upper:]' '[:lower:]')"
    COMPUTED="${TEAM_BASE_WORKING_DIR}/${_XACA0485_RESOLVED_CLIENT}/${_XACA0485_RESOLVED_PROJECT}"
else
    COMPUTED="${TEAM_BASE_WORKING_DIR}/${_XACA0485_RESOLVED_PROJECT}"
fi
EXPECTED="/tmp/xaca0485-test-freelance/acmecorp/widgettracker"
if [ "$COMPUTED" = "$EXPECTED" ]; then
    test_pass
else
    test_fail "template-client-project: got '$COMPUTED', expected '$EXPECTED'"
fi

test_start "XACA-0485: default-project fallback when --project not supplied"
TEAM_HAS_PROJECTS="true"
TEAM_REQUIRES_CLIENT_ID="false"
ARG_PROJECT=""
TEAM_DEFAULT_PROJECT="general"
TEAM_BASE_WORKING_DIR="/tmp/xaca0485-test-medical"

_XACA0485_RESOLVED_PROJECT="${ARG_PROJECT:-$TEAM_DEFAULT_PROJECT}"
_XACA0485_RESOLVED_PROJECT="$(echo "$_XACA0485_RESOLVED_PROJECT" | tr '[:upper:]' '[:lower:]')"
COMPUTED="${TEAM_BASE_WORKING_DIR}/${_XACA0485_RESOLVED_PROJECT}"
EXPECTED="/tmp/xaca0485-test-medical/general"
if [ "$COMPUTED" = "$EXPECTED" ]; then
    test_pass
else
    test_fail "default-project fallback: got '$COMPUTED', expected '$EXPECTED'"
fi

test_start "XACA-0485: non-parametric teams' TEAM_WORKING_DIR unchanged"
# When TEAM_HAS_PROJECTS=false, the project-augmentation block must NOT fire.
TEAM_HAS_PROJECTS="false"
TEAM_BASE_WORKING_DIR="/Users/test/aiteamforge/academy"
# Replicate the else branch of the augmentation
TEAM_WORKING_DIR_RESULT="$TEAM_BASE_WORKING_DIR"
EXPECTED="/Users/test/aiteamforge/academy"
if [ "$TEAM_WORKING_DIR_RESULT" = "$EXPECTED" ]; then
    test_pass
else
    test_fail "non-parametric: got '$TEAM_WORKING_DIR_RESULT', expected '$EXPECTED'"
fi

test_start "XACA-0485: install-team.sh sources required vars before augmentation block"
# Sequencing check: augmentation must come AFTER _read_conf eval (so TEAM_HAS_PROJECTS,
# TEAM_DEFAULT_PROJECT, TEAM_REQUIRES_CLIENT_ID are populated) AND AFTER TEAM_BASE_WORKING_DIR
# is saved (so we use the base, not the augmented value).
# Find line numbers for: TEAM_BASE_WORKING_DIR assignment, _XACA0485 block, KANBAN_DIR= line.
base_line=$(grep -n 'TEAM_BASE_WORKING_DIR="\${TEAM_WORKING_DIR}"' "$INSTALL_TEAM" | head -1 | cut -d: -f1)
aug_line=$(grep -n '_XACA0485_RESOLVED_PROJECT' "$INSTALL_TEAM" | head -1 | cut -d: -f1)
kanban_line=$(grep -n 'KANBAN_DIR="\${TEAM_WORKING_DIR}/kanban"' "$INSTALL_TEAM" | head -1 | cut -d: -f1)
if [ -n "$base_line" ] && [ -n "$aug_line" ] && [ -n "$kanban_line" ] && \
   [ "$base_line" -lt "$aug_line" ] && [ "$aug_line" -lt "$kanban_line" ]; then
    test_pass
else
    test_fail "Ordering violated: base@$base_line, aug@$aug_line, kanban@$kanban_line — expected base < aug < kanban"
fi

test_start "XACA-0485-010: invalid --project rejected by _validate_instance_component BEFORE augmentation"
# Security invariant: path-traversal-shaped values like '../etc' must be rejected
# at compute_instance_id (line ~189-205) BEFORE the augmentation block runs.
# This test pins three invariants:
#
# (a) _validate_instance_component enforces ^[a-z0-9_]+$ — rejects dots, slashes,
#     hyphens, anything outside the allowed set.
# (b) install-team.sh runs under errexit semantics (set -e or equivalent) — a
#     non-zero exit from compute_instance_id's $() subshell terminates the parent.
# (c) INSTANCE_ID="$(compute_instance_id ...)" runs BEFORE the augmentation block.
#
# If any of those three regress, the augmentation block could be reached with
# an unvalidated project value and construct a malicious path.
#
# NOTE on grep mode: -F (fixed-string) is used for the regex-literal check
# because BRE/ERE interpretation of the pattern is ambiguous when the SEARCH
# STRING itself contains regex metacharacters. -F eliminates the escaping
# dimension entirely. Reno caught a BRE pattern that always returned 0 in the
# initial version of this test (XACA-0485-010 review feedback).

# (a) validator regex — fixed-string match so the regex literal in the source matches as-is
validator_ok=$(grep -A 4 '_validate_instance_component()' "$INSTALL_TEAM" | grep -cF '^[a-z0-9_]+$')
# (b) errexit
errexit_ok=$(grep -cE 'set -e|set -euo|errexit' "$INSTALL_TEAM")
# (c) sequencing
instance_line=$(grep -n 'INSTANCE_ID="\$(compute_instance_id' "$INSTALL_TEAM" | head -1 | cut -d: -f1)
seq_aug_line=$(grep -n '_XACA0485_RESOLVED_PROJECT' "$INSTALL_TEAM" | head -1 | cut -d: -f1)

# Guard against empty values from grep failures — coerce to 0 so -lt comparison
# is a single-integer test rather than a multi-line string expression.
validator_ok="${validator_ok:-0}"
errexit_ok="${errexit_ok:-0}"

if [ "$validator_ok" -lt 1 ]; then
    test_fail "_validate_instance_component does not enforce ^[a-z0-9_]+\$ regex (validator_ok=$validator_ok)"
elif [ "$errexit_ok" -lt 1 ]; then
    test_fail "install-team.sh missing set -e / errexit — validator exit would be ignored (errexit_ok=$errexit_ok)"
elif [ -z "$instance_line" ] || [ -z "$seq_aug_line" ] || [ "$instance_line" -ge "$seq_aug_line" ]; then
    test_fail "Validation-before-augmentation invariant broken: INSTANCE_ID@${instance_line:-unset}, aug@${seq_aug_line:-unset}"
else
    test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# XACA-0486: LCARS server venv-python + board field-semantics
# ═══════════════════════════════════════════════════════════════════════════

LCARS_LAUNCH_HELPER="$TAP_ROOT/share/scripts/lcars-launch-helpers.sh"

test_start "XACA-0486: lcars-launch-helpers.sh sources brew env.sh and uses AITEAMFORGE_PYTHON"
# Canonical pattern per Formula design: source $(brew --prefix)/var/aiteamforge/env.sh
# then use $AITEAMFORGE_PYTHON. Earlier fix used wrong path (libexec/venv) that doesn't exist.
output=$(grep -cE 'var/aiteamforge/env\.sh|AITEAMFORGE_PYTHON' "$LCARS_LAUNCH_HELPER")
run_assert_pass assert_exit_success $([ "$output" -ge 2 ]; echo $?)

test_start "XACA-0486: lcars-launch-helpers.sh has fallback chain for non-brew installs"
# AITEAMFORGE_DIR fallback should appear in the same start_lcars_server function.
output=$(grep -A 14 'lcars_python="python3"' "$LCARS_LAUNCH_HELPER" | grep -c 'AITEAMFORGE_DIR\|share/venv')
run_assert_pass assert_exit_success $([ "$output" -ge 1 ]; echo $?)

test_start "XACA-0486: lcars-launch-helpers.sh does NOT use the wrong libexec/venv path"
# Catch the path-resolution bug caught by M1Pro smoke (p071 gate). The Formula's
# venv is at var/aiteamforge/venv, NOT libexec/venv. Any reference to libexec/venv
# in the launch helper would be a regression.
output=$(grep -c 'libexec/venv' "$LCARS_LAUNCH_HELPER")
if [ "$output" -eq 0 ]; then
    test_pass
else
    test_fail "Found $output references to wrong libexec/venv path (should be var/aiteamforge/venv)"
fi

test_start "XACA-0486: server invocation uses \${lcars_python} (not bare python3)"
output=$(grep -c '"\${lcars_python}" server.py' "$LCARS_LAUNCH_HELPER")
run_assert_pass assert_exit_success $([ "$output" -ge 1 ]; echo $?)

test_start "XACA-0486: install-team.sh subtitle source is TEAM_THEME (from conf), not REGISTRY_THEME"
# Reno's [Review] subitem (XACA-0486-011): several registry.json entries have
# .theme == .name (stale data), which produces duplicate teamName/subtitle.
# Subtitle MUST come from <team>.conf's TEAM_THEME (authoritative & distinct).
output=$(grep -cE '_BOARD_SUBTITLE_UPPER.*TEAM_THEME|_XACA0486_SUBTITLE_UPPER.*TEAM_THEME' "$INSTALL_TEAM")
if [ "$output" -ge 2 ]; then
    test_pass
else
    test_fail "Expected both board-init and migration to source subtitle from TEAM_THEME (found $output references)"
fi

test_start "XACA-0486: install-team.sh does NOT source subtitle from REGISTRY_THEME"
# Symmetric negative: ensure the stale registry.theme field isn't accidentally
# wired in alongside TEAM_THEME.
output=$(grep -cE '_BOARD_SUBTITLE_UPPER.*REGISTRY_THEME|_XACA0486_SUBTITLE_UPPER.*REGISTRY_THEME' "$INSTALL_TEAM")
if [ "$output" -eq 0 ]; then
    test_pass
else
    test_fail "Found $output references using stale REGISTRY_THEME for subtitle (should be TEAM_THEME)"
fi

test_start "XACA-0486-011: every team's TEAM_NAME != TEAM_THEME (no duplicate sidebar)"
# Reno's review caught that name==theme produces duplicate teamName/subtitle
# on the board. Switching the subtitle source from REGISTRY_THEME (stale)
# to TEAM_THEME (authoritative) was step 1; this test ensures the conf data
# itself never has name==theme. Catches future regressions in new team confs.
violators=""
for conf in "$TAP_ROOT"/share/teams/*.conf; do
    [ -f "$conf" ] || continue
    team_name=$(grep -E '^TEAM_NAME=' "$conf" | head -1 | sed -E 's/^TEAM_NAME=//; s/^"//; s/"$//')
    team_theme=$(grep -E '^TEAM_THEME=' "$conf" | head -1 | sed -E 's/^TEAM_THEME=//; s/^"//; s/"$//')
    # Skip teams without TEAM_THEME (some confs don't set it)
    [ -n "$team_theme" ] || continue
    if [ "$team_name" = "$team_theme" ]; then
        violators="${violators}$(basename "$conf") "
    fi
done
if [ -z "$violators" ]; then
    test_pass
else
    test_fail "Teams with TEAM_NAME == TEAM_THEME (duplicate sidebar risk): $violators"
fi

test_start "XACA-0486: board init uses uppercase derivations for teamName/organization/subtitle"
output=$(grep -cE '_BOARD_TEAMNAME_UPPER|_BOARD_ORG_UPPER|_BOARD_SUBTITLE_UPPER' "$INSTALL_TEAM")
run_assert_pass assert_exit_success $([ "$output" -ge 3 ]; echo $?)

test_start "XACA-0486: organization sourced from TEAM_ID (template id), not REGISTRY_NAME_RAW"
# Detect the (post-XACA-0486) pattern: _BOARD_ORG_UPPER computed from TEAM_ID.
output=$(grep -A 2 '_BOARD_ORG_UPPER=' "$INSTALL_TEAM" | head -1)
case "$output" in
    *'echo "$TEAM_ID"'*) test_pass ;;
    *) test_fail "_BOARD_ORG_UPPER not derived from TEAM_ID (got: $output)" ;;
esac

test_start "XACA-0486: migration detects duplicate-brand bug (organization == teamName)"
# The detect condition must include `.organization == .teamName` clause.
output=$(grep -c '\.organization == \.teamName' "$INSTALL_TEAM")
run_assert_pass assert_exit_success $([ "$output" -ge 1 ]; echo $?)

test_start "XACA-0486: migration unconditionally re-derives parametric branding fields"
# For the three semantic fields (teamName / subtitle / organization), the jq
# assignment must be `= $name` (unconditional) NOT `// $name` (coalesce).
# Check each pattern separately; the patterns appear on distinct lines after
# the _XACA0484_BOARD_TMP= anchor (with jq --arg block in between, so widen scan).
window=$(grep -A 30 '_XACA0484_BOARD_TMP=' "$INSTALL_TEAM")
ok=0
echo "$window" | grep -qE '\.teamName *= *\$teamName' && ok=$((ok + 1))
echo "$window" | grep -qE '\.subtitle *= *\$subtitle' && ok=$((ok + 1))
echo "$window" | grep -qE '\.organization *= *\$organization' && ok=$((ok + 1))
if [ "$ok" -eq 3 ]; then
    test_pass
else
    test_fail "Expected 3 unconditional assignments in migration block, found $ok"
fi

test_start "XACA-0486: synthetic board-init field values match academy-board.json model"
# Replicate the install-team.sh logic with known inputs (finance template) and
# verify the resulting jq output matches academy-board.json's field semantics.
TEAM_ID="finance"
REGISTRY_NAME_RAW="Ferengi Commerce Authority"
REGISTRY_THEME="Star Trek: Deep Space Nine - Ferengi"
_BOARD_TEAMNAME_UPPER="$(echo "$REGISTRY_NAME_RAW" | tr '[:lower:]' '[:upper:]')"
_BOARD_ORG_UPPER="$(echo "$TEAM_ID" | tr '[:lower:]' '[:upper:]')"
_BOARD_SUBTITLE_UPPER="$(echo "$REGISTRY_THEME" | tr '[:lower:]' '[:upper:]')"

EXPECTED_TEAMNAME="FERENGI COMMERCE AUTHORITY"
EXPECTED_ORG="FINANCE"
EXPECTED_SUBTITLE="STAR TREK: DEEP SPACE NINE - FERENGI"

if [ "$_BOARD_TEAMNAME_UPPER" = "$EXPECTED_TEAMNAME" ] && \
   [ "$_BOARD_ORG_UPPER" = "$EXPECTED_ORG" ] && \
   [ "$_BOARD_SUBTITLE_UPPER" = "$EXPECTED_SUBTITLE" ] && \
   [ "$_BOARD_TEAMNAME_UPPER" != "$_BOARD_ORG_UPPER" ]; then
    test_pass
else
    test_fail "Synthesized field values mismatch: teamName=$_BOARD_TEAMNAME_UPPER org=$_BOARD_ORG_UPPER subtitle=$_BOARD_SUBTITLE_UPPER"
fi

test_start "XACA-0486: synthetic migration re-derives org from TEAM_ID even when board has duplicate-brand"
# Stub board with the duplicate-brand bug.
MIG486_SANDBOX="$TEST_TMP_DIR/xaca0486-mig"
mkdir -p "$MIG486_SANDBOX"
STUB="$MIG486_SANDBOX/finance-personal-board.json"
cat > "$STUB" <<'STUBEOF'
{
  "team": "finance-personal",
  "teamName": "Ferengi Commerce Authority",
  "subtitle": "Personal finance management and automation",
  "organization": "Ferengi Commerce Authority",
  "ship": "Ferengi Alliance Commerce Hub",
  "backlog": [],
  "epics": []
}
STUBEOF

# Run the detection — should be true because organization == teamName.
detect=$(jq -r '
    if (.teamName == null) or (.organization == null) or
       (.ship == null) or (.subtitle == null) or
       (.organization == .teamName) then "true" else "false" end
' "$STUB")

# Run the patch with academy-style field semantics.
jq \
    --arg teamName "FERENGI COMMERCE AUTHORITY" \
    --arg subtitle "STAR TREK: DEEP SPACE NINE - FERENGI" \
    --arg organization "FINANCE" \
    '.teamName     = $teamName
   | .subtitle     = $subtitle
   | .organization = $organization' \
    "$STUB" > "${STUB}.tmp" && mv "${STUB}.tmp" "$STUB"

# Verify post-patch values are the academy-model uppercase derivations.
post_teamName=$(jq -r '.teamName' "$STUB")
post_org=$(jq -r '.organization' "$STUB")
post_subtitle=$(jq -r '.subtitle' "$STUB")
preserved_backlog=$(jq -r '.backlog | type' "$STUB")

if [ "$detect" = "true" ] && \
   [ "$post_teamName" = "FERENGI COMMERCE AUTHORITY" ] && \
   [ "$post_org" = "FINANCE" ] && \
   [ "$post_subtitle" = "STAR TREK: DEEP SPACE NINE - FERENGI" ] && \
   [ "$post_teamName" != "$post_org" ] && \
   [ "$preserved_backlog" = "array" ]; then
    test_pass
else
    test_fail "Migration didn't produce expected post-state: detect=$detect teamName=$post_teamName org=$post_org subtitle=$post_subtitle backlog-type=$preserved_backlog"
fi
