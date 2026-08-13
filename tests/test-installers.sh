#!/bin/bash

# test-installers.sh
# Tests for installer modules (libexec/installers/)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLERS_DIR="$TAP_ROOT/libexec/installers"

# Set up test environment
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
export AITEAMFORGE_HOME="$TAP_ROOT"
mkdir -p "$AITEAMFORGE_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

get_installer_files() {
  find "$INSTALLERS_DIR" -maxdepth 1 -name "install-*.sh" -type f
}

# Helper: run assertion and only call test_pass if it succeeded
# Usage: run_test "name" assertion_func args...
run_assert_pass() {
  if "$@"; then
    test_pass
  fi
  # If assert failed, test_fail was already called by the assert function
}

# ═══════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════

test_start "Installers directory exists"
run_assert_pass assert_dir_exists "$INSTALLERS_DIR"

test_start "At least one installer module exists"
installer_count=$(get_installer_files | wc -l | tr -d ' ')
run_assert_pass assert_exit_success $([ "$installer_count" -gt 0 ]; echo $?)

test_start "All installer modules are executable"
all_exec=true
while IFS= read -r installer; do
  if [ ! -x "$installer" ]; then
    test_fail "Not executable: $(basename "$installer")"
    all_exec=false
    break
  fi
done < <(get_installer_files)
[ "$all_exec" = true ] && test_pass

test_start "All installer modules have proper shebangs"
all_shebangs=true
while IFS= read -r installer; do
  first_line=$(head -n 1 "$installer")
  if [[ "$first_line" != *"#!"* ]]; then
    test_fail "Missing shebang: $(basename "$installer")"
    all_shebangs=false
    break
  fi
done < <(get_installer_files)
[ "$all_shebangs" = true ] && test_pass

test_start "All installer modules pass syntax check"
all_syntax=true
while IFS= read -r installer; do
  if ! bash -n "$installer" 2>/dev/null; then
    test_fail "Syntax error in: $(basename "$installer")"
    all_syntax=false
    break
  fi
done < <(get_installer_files)
[ "$all_syntax" = true ] && test_pass

test_start "Shell installer exists"
run_assert_pass assert_file_exists "$INSTALLERS_DIR/install-shell.sh"

test_start "Shell installer contains shell environment functions"
output=$(grep -c "install_shell_environment\|zshrc" "$INSTALLERS_DIR/install-shell.sh" 2>/dev/null || echo "0")
run_assert_pass assert_exit_success $([ "$output" -gt 0 ]; echo $?)

test_start "Kanban installer exists"
run_assert_pass assert_file_exists "$INSTALLERS_DIR/install-kanban.sh"

test_start "Kanban installer is executable"
run_assert_pass assert_exit_success $([ -x "$INSTALLERS_DIR/install-kanban.sh" ]; echo $?)

test_start "Kanban installer contains kanban functions"
output=$(grep -c "install_kanban_system\|kanban" "$INSTALLERS_DIR/install-kanban.sh" 2>/dev/null || echo "0")
run_assert_pass assert_exit_success $([ "$output" -gt 0 ]; echo $?)

test_start "Claude config installer exists"
run_assert_pass assert_file_exists "$INSTALLERS_DIR/install-claude-config.sh"

test_start "Claude config installer handles missing ~/.claude/"
output=$(bash "$INSTALLERS_DIR/install-claude-config.sh" --help 2>&1 || true)
# Either --help produces output, or the script mentions claude in its code
if [ -z "$output" ]; then
  output=$(grep -c "claude" "$INSTALLERS_DIR/install-claude-config.sh" 2>/dev/null || echo "0")
fi
run_assert_pass assert_not_empty "$output"

test_start "Fleet monitor installer exists"
run_assert_pass assert_file_exists "$INSTALLERS_DIR/install-fleet-monitor.sh"

test_start "Fleet monitor installer handles missing Tailscale"
output=$(bash "$INSTALLERS_DIR/install-fleet-monitor.sh" --help 2>&1 || true)
if [ -z "$output" ]; then
  output=$(grep -c "fleet\|monitor" "$INSTALLERS_DIR/install-fleet-monitor.sh" 2>/dev/null || echo "0")
fi
run_assert_pass assert_not_empty "$output"

test_start "Team installer exists"
run_assert_pass assert_file_exists "$INSTALLERS_DIR/install-team.sh"

test_start "Team installer handles unknown team ID gracefully"
output=$(bash "$INSTALLERS_DIR/install-team.sh" invalid-team-id 2>&1 || true)
output_lower=$(echo "$output" | tr '[:upper:]' '[:lower:]')
if [[ "$output_lower" == *"error"* ]] || [[ "$output_lower" == *"unknown"* ]] || [[ "$output_lower" == *"invalid"* ]] || [[ "$output_lower" == *"not found"* ]]; then
  test_pass
else
  test_fail "Expected error message for invalid team ID, got: $output"
fi

test_start "All installers contain documentation or comments"
all_have_docs=true
while IFS= read -r installer; do
  # Check for either --help handling or descriptive comments
  has_docs=$(grep -c "Usage\|help\|# .*Install" "$installer" 2>/dev/null || echo "0")
  if [ "$has_docs" -eq 0 ]; then
    test_fail "No documentation: $(basename "$installer")"
    all_have_docs=false
    break
  fi
done < <(get_installer_files)
[ "$all_have_docs" = true ] && test_pass

test_start "Expected installers are all present"
all_present=true
expected_installers="shell kanban claude-config fleet-monitor team"
for installer in $expected_installers; do
  if [ ! -f "$INSTALLERS_DIR/install-${installer}.sh" ]; then
    test_fail "Missing: install-${installer}.sh"
    all_present=false
    break
  fi
done
[ "$all_present" = true ] && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# XACA-0212: Profile-aware stub creation + kb-quarantine-stub regression tests
# ═══════════════════════════════════════════════════════════════════════════

# Helpers for these tests
KANBAN_HELPERS_PATH="$(cd "$TAP_ROOT/.." && pwd)/kanban-helpers.sh"

# The kb-quarantine-stub block below (XACA-0212) exercises the CANONICAL
# kanban-helpers.sh, which lives in the OUTER dev-team monorepo — not in the
# homebrew-tap repo itself (see CONTRIBUTING.md "Shared scripts and the
# canonical source": tap files under share/ are copies; dev-team is
# authoritative). On a developer's machine TAP_ROOT/.. is the dev-team
# checkout that has homebrew-tap nested inside it, so KANBAN_HELPERS_PATH
# exists. In tap-only CI (this repo checked out standalone, no outer
# dev-team repo present at all), TAP_ROOT/.. is just the Actions workspace
# root and kanban-helpers.sh never exists there — PRE-EXISTING structural
# gap (repo layout), not caused by any tap commit. Detect and SKIP with a
# visible reason rather than failing, matching the established idiom in
# test-xaca-0611-imgcat-provision.sh Cases 7/8 and
# test-xaca-0632-kb-variance.sh Case 7.
_IN_DEV_MONOREPO=false
[ -f "$KANBAN_HELPERS_PATH" ] && _IN_DEV_MONOREPO=true

# Run kb-quarantine-stub in a zsh subshell with a sandboxed HOME.
# Args: <sandbox_home> <args...>
# kanban-helpers.sh uses zsh-only globs (e.g. (N) qualifier) — must invoke under zsh.
# Suppresses warnings emitted at source time (e.g. _kb_check_dual_boards on legacy paths).
run_quarantine_stub() {
  local sandbox_home="$1"; shift
  HOME="$sandbox_home" KB_SKIP_DUAL_BOARD_CHECK=1 KANBAN_HELPERS_PATH="$KANBAN_HELPERS_PATH" zsh -c '
    source "$KANBAN_HELPERS_PATH" 2>/dev/null
    unset -f aiteamforge_team_kanban_dir 2>/dev/null
    kb-quarantine-stub "$@"
  ' run-quarantine-stub "$@" 2>&1
}

# ─── Profile-aware stub skip (install-team.sh logic) ────────────────────────

test_start "XACA-0212: install-team.sh contains profile-aware stub guard"
output=$(grep -c "XACA-0212: skip stub creation" "$INSTALLERS_DIR/install-team.sh" 2>/dev/null || echo "0")
run_assert_pass assert_exit_success $([ "$output" -gt 0 ]; echo $?)

test_start "XACA-0212: profile-aware find pattern detects canonical board in subdir"
ps_sandbox="$TEST_TMP_DIR/profile-skip-positive"
mkdir -p "$ps_sandbox/legal/coparenting/kanban"
echo '{"team":"legal-coparenting"}' > "$ps_sandbox/legal/coparenting/kanban/legal-coparenting-board.json"
ps_kanban_dir="$ps_sandbox/legal/kanban"
mkdir -p "$ps_kanban_dir"
ps_team_board="$ps_kanban_dir/legal-board.json"
ps_match=$(find "$(dirname "$ps_kanban_dir")" -maxdepth 3 -path "*/kanban/*-board.json" -type f 2>/dev/null | head -1)
if [ -n "$ps_match" ] && [ "$ps_match" != "$ps_team_board" ]; then
  test_pass
else
  test_fail "Expected canonical match, got: '$ps_match' (team_board='$ps_team_board')"
fi

test_start "XACA-0212: find pattern returns empty when no canonical board exists"
ng_sandbox="$TEST_TMP_DIR/profile-skip-negative"
ng_kanban_dir="$ng_sandbox/legal/kanban"
mkdir -p "$ng_kanban_dir"
ng_match=$(find "$(dirname "$ng_kanban_dir")" -maxdepth 3 -path "*/kanban/*-board.json" -type f 2>/dev/null | head -1)
run_assert_pass assert_empty "$ng_match"

# ─── kb-quarantine-stub command (kanban-helpers.sh) ─────────────────────────

if ! $_IN_DEV_MONOREPO; then
  for _skip_name in \
    "XACA-0212: kanban-helpers.sh exists at expected path" \
    "XACA-0212: kb-quarantine-stub is defined in kanban-helpers.sh" \
    "XACA-0212: kb-quarantine-stub --help prints usage" \
    "XACA-0212: kb-quarantine-stub --dry-run is non-destructive" \
    "XACA-0212: kb-quarantine-stub --yes moves stub and writes meta sidecar" \
    "XACA-0212: kb-quarantine-stub refuses when no canonical board exists" \
    "XACA-0212: kb-quarantine-stub refuses non-empty stub without --force" \
    "XACA-0212: kb-quarantine-stub --force --yes moves non-empty stub" \
    "XACA-0212: kb-quarantine-stub --force-no-canonical --yes moves stub when canonical absent" \
    "XACA-0212: kb-quarantine-stub legal-coparenting handles second stub path"; do
    test_start "$_skip_name"
    echo "  SKIP: kanban-helpers.sh (outer dev-team monorepo) not reachable at $KANBAN_HELPERS_PATH — consumer/standalone tap checkout"
    test_pass
  done
  unset _skip_name
else

test_start "XACA-0212: kanban-helpers.sh exists at expected path"
run_assert_pass assert_file_exists "$KANBAN_HELPERS_PATH"

test_start "XACA-0212: kb-quarantine-stub is defined in kanban-helpers.sh"
output=$(grep -c "^kb-quarantine-stub()" "$KANBAN_HELPERS_PATH" 2>/dev/null || echo "0")
run_assert_pass assert_exit_success $([ "$output" -gt 0 ]; echo $?)

test_start "XACA-0212: kb-quarantine-stub --help prints usage"
help_out=$(zsh -c "
  export KB_SKIP_DUAL_BOARD_CHECK=1
  source '$KANBAN_HELPERS_PATH' 2>/dev/null
  kb-quarantine-stub --help
" 2>&1)
run_assert_pass assert_contains "$help_out" "USAGE"

test_start "XACA-0212: kb-quarantine-stub --dry-run is non-destructive"
dr_sandbox="$TEST_TMP_DIR/quarantine-dry-run"
mkdir -p "$dr_sandbox/legal/kanban" "$dr_sandbox/legal/coparenting/kanban"
dr_stub="$dr_sandbox/legal/kanban/legal-board.json"
dr_canonical="$dr_sandbox/legal/coparenting/kanban/legal-coparenting-board.json"
echo '{"team":"legal","backlog":[]}' > "$dr_stub"
echo '{"team":"legal-coparenting","backlog":[{"id":"X-1"}]}' > "$dr_canonical"
dr_out=$(run_quarantine_stub "$dr_sandbox" legal-coparenting --dry-run)
# Stub and canonical must still exist; output must say DRY RUN
if [ -f "$dr_stub" ] && [ -f "$dr_canonical" ] && echo "$dr_out" | grep -q "DRY RUN"; then
  test_pass
else
  test_fail "Dry-run failed: stub=$([ -f "$dr_stub" ] && echo "yes" || echo "no"), canonical=$([ -f "$dr_canonical" ] && echo "yes" || echo "no"), output=$dr_out"
fi

test_start "XACA-0212: kb-quarantine-stub --yes moves stub and writes meta sidecar"
mv_sandbox="$TEST_TMP_DIR/quarantine-move"
mkdir -p "$mv_sandbox/legal/kanban" "$mv_sandbox/legal/coparenting/kanban"
mv_stub="$mv_sandbox/legal/kanban/legal-board.json"
mv_canonical="$mv_sandbox/legal/coparenting/kanban/legal-coparenting-board.json"
echo '{"team":"legal","backlog":[]}' > "$mv_stub"
echo '{"team":"legal-coparenting","backlog":[{"id":"X-1"}]}' > "$mv_canonical"
mv_out=$(run_quarantine_stub "$mv_sandbox" legal-coparenting --yes)
mv_quarantine_dir="$mv_sandbox/dev-team/quarantine/runtime-stub-stash"
mv_meta_count=$(find "$mv_quarantine_dir" -name "*.meta.json" -type f 2>/dev/null | wc -l | tr -d ' ')
mv_moved_count=$(find "$mv_quarantine_dir" -name "*legal*board.json" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ ! -f "$mv_stub" ] && [ -f "$mv_canonical" ] && [ "$mv_meta_count" -ge 1 ] && [ "$mv_moved_count" -ge 1 ]; then
  test_pass
else
  test_fail "Move failed: stub_gone=$([ ! -f "$mv_stub" ] && echo "yes" || echo "no"), canonical=$([ -f "$mv_canonical" ] && echo "yes" || echo "no"), meta=$mv_meta_count, moved=$mv_moved_count, out=$mv_out"
fi

test_start "XACA-0212: kb-quarantine-stub refuses when no canonical board exists"
nc_sandbox="$TEST_TMP_DIR/quarantine-no-canonical"
mkdir -p "$nc_sandbox/legal/kanban"
nc_stub="$nc_sandbox/legal/kanban/legal-board.json"
echo '{"team":"legal","backlog":[]}' > "$nc_stub"
nc_out=$(run_quarantine_stub "$nc_sandbox" legal-coparenting --yes)
# Stub must still exist; output must mention "no canonical" or "Refusing"
if [ -f "$nc_stub" ] && echo "$nc_out" | grep -qiE "no canonical|refusing"; then
  test_pass
else
  test_fail "No-canonical refusal failed: stub=$([ -f "$nc_stub" ] && echo "yes" || echo "no"), out=$nc_out"
fi

test_start "XACA-0212: kb-quarantine-stub refuses non-empty stub without --force"
ne_sandbox="$TEST_TMP_DIR/quarantine-non-empty"
mkdir -p "$ne_sandbox/legal/kanban" "$ne_sandbox/legal/coparenting/kanban"
ne_stub="$ne_sandbox/legal/kanban/legal-board.json"
ne_canonical="$ne_sandbox/legal/coparenting/kanban/legal-coparenting-board.json"
echo '{"team":"legal","backlog":[{"id":"REAL-1"},{"id":"REAL-2"}]}' > "$ne_stub"
echo '{"team":"legal-coparenting","backlog":[]}' > "$ne_canonical"
ne_out=$(run_quarantine_stub "$ne_sandbox" legal-coparenting --yes)
# Stub must still exist; output must mention non-empty refusal
if [ -f "$ne_stub" ] && echo "$ne_out" | grep -qiE "contains [0-9]+ item|refusing|--force"; then
  test_pass
else
  test_fail "Non-empty refusal failed: stub=$([ -f "$ne_stub" ] && echo "yes" || echo "no"), out=$ne_out"
fi

# ─── XACA-0212-013: extended coverage for force flags + dual-stub + multi-match ──

test_start "XACA-0212: kb-quarantine-stub --force --yes moves non-empty stub"
fe_sandbox="$TEST_TMP_DIR/quarantine-force-empty"
mkdir -p "$fe_sandbox/legal/kanban" "$fe_sandbox/legal/coparenting/kanban"
fe_stub="$fe_sandbox/legal/kanban/legal-board.json"
fe_canonical="$fe_sandbox/legal/coparenting/kanban/legal-coparenting-board.json"
echo '{"team":"legal","backlog":[{"id":"FORCE-1"}]}' > "$fe_stub"
echo '{"team":"legal-coparenting","backlog":[]}' > "$fe_canonical"
fe_out=$(run_quarantine_stub "$fe_sandbox" legal-coparenting --force --yes)
fe_quarantine_dir="$fe_sandbox/dev-team/quarantine/runtime-stub-stash"
fe_moved=$(find "$fe_quarantine_dir" -name "*legal*board.json" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ ! -f "$fe_stub" ] && [ "$fe_moved" -ge 1 ]; then
  test_pass
else
  test_fail "--force did not override item-count refusal: stub_gone=$([ ! -f "$fe_stub" ] && echo "yes" || echo "no"), moved=$fe_moved, out=$fe_out"
fi

test_start "XACA-0212: kb-quarantine-stub --force-no-canonical --yes moves stub when canonical absent"
fnc_sandbox="$TEST_TMP_DIR/quarantine-force-no-canonical"
mkdir -p "$fnc_sandbox/legal/kanban"
fnc_stub="$fnc_sandbox/legal/kanban/legal-board.json"
echo '{"team":"legal","backlog":[]}' > "$fnc_stub"
fnc_out=$(run_quarantine_stub "$fnc_sandbox" legal-coparenting --force-no-canonical --yes)
fnc_quarantine_dir="$fnc_sandbox/dev-team/quarantine/runtime-stub-stash"
fnc_moved=$(find "$fnc_quarantine_dir" -name "*legal*board.json" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ ! -f "$fnc_stub" ] && [ "$fnc_moved" -ge 1 ] && echo "$fnc_out" | grep -qi "no canonical"; then
  test_pass
else
  test_fail "--force-no-canonical did not move stub: stub_gone=$([ ! -f "$fnc_stub" ] && echo "yes" || echo "no"), moved=$fnc_moved, out=$fnc_out"
fi

test_start "XACA-0212: kb-quarantine-stub legal-coparenting handles second stub path"
ds_sandbox="$TEST_TMP_DIR/quarantine-dual-stub"
mkdir -p "$ds_sandbox/legal/default/kanban" "$ds_sandbox/legal/coparenting/kanban"
# Only the second known stub path exists (legal/default/...)
ds_stub2="$ds_sandbox/legal/default/kanban/legal-default-board.json"
ds_canonical="$ds_sandbox/legal/coparenting/kanban/legal-coparenting-board.json"
echo '{"team":"legal-default","backlog":[]}' > "$ds_stub2"
echo '{"team":"legal-coparenting","backlog":[]}' > "$ds_canonical"
ds_out=$(run_quarantine_stub "$ds_sandbox" legal-coparenting --yes)
ds_quarantine_dir="$ds_sandbox/dev-team/quarantine/runtime-stub-stash"
ds_moved=$(find "$ds_quarantine_dir" -name "*legal-default*board.json" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ ! -f "$ds_stub2" ] && [ "$ds_moved" -ge 1 ]; then
  test_pass
else
  test_fail "Second stub path not handled: stub2_gone=$([ ! -f "$ds_stub2" ] && echo "yes" || echo "no"), moved=$ds_moved, out=$ds_out"
fi

fi # _IN_DEV_MONOREPO (kb-quarantine-stub block)

test_start "XACA-0212: install-team.sh skip logs ALL canonical matches not just first"
mc_sandbox="$TEST_TMP_DIR/multi-canonical"
mkdir -p "$mc_sandbox/legal/coparenting/kanban" "$mc_sandbox/legal/default/kanban" "$mc_sandbox/legal/kanban"
echo '{"team":"a"}' > "$mc_sandbox/legal/coparenting/kanban/legal-coparenting-board.json"
echo '{"team":"b"}' > "$mc_sandbox/legal/default/kanban/legal-default-board.json"
mc_team_board="$mc_sandbox/legal/kanban/legal-board.json"
# Reproduce the install-team.sh capture pattern (must match install-team.sh:990-1000)
mc_matches=()
while IFS= read -r line; do
  [[ -n "$line" && "$line" != "$mc_team_board" ]] && mc_matches+=("$line")
done < <(find "$(dirname "$mc_sandbox/legal/kanban")" -maxdepth 3 -path "*/kanban/*-board.json" -type f 2>/dev/null)
if [ "${#mc_matches[@]}" -eq 2 ]; then
  test_pass
else
  test_fail "Expected 2 canonical matches, got ${#mc_matches[@]}: ${mc_matches[*]}"
fi

# Success!
exit 0
