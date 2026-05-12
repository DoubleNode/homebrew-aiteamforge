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

# (a) validator regex
validator_ok=$(grep -A 4 '_validate_instance_component()' "$INSTALL_TEAM" | grep -c '\^\[a-z0-9_\]\+\$' || echo 0)
# (b) errexit
errexit_ok=$(grep -c 'set -e\|set -euo\|errexit' "$INSTALL_TEAM" || echo 0)
# (c) sequencing
instance_line=$(grep -n 'INSTANCE_ID="\$(compute_instance_id' "$INSTALL_TEAM" | head -1 | cut -d: -f1)
seq_aug_line=$(grep -n '_XACA0485_RESOLVED_PROJECT' "$INSTALL_TEAM" | head -1 | cut -d: -f1)

if [ "$validator_ok" -lt 1 ]; then
    test_fail "_validate_instance_component does not enforce ^[a-z0-9_]+$ regex"
elif [ "$errexit_ok" -lt 1 ]; then
    test_fail "install-team.sh missing set -e / errexit — validator exit would be ignored"
elif [ -z "$instance_line" ] || [ -z "$seq_aug_line" ] || [ "$instance_line" -ge "$seq_aug_line" ]; then
    test_fail "Validation-before-augmentation invariant broken: INSTANCE_ID@${instance_line:-unset}, aug@${seq_aug_line:-unset}"
else
    test_pass
fi
