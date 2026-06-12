#!/usr/bin/env bash
# test-xaca-0470-cr-enable.sh
# Sandboxed regression tests for XACA-0470: per-team CR enable prompt +
# Atlassian credentials capture helpers in install-kanban.sh.
#
# Functions under test (extracted from install-kanban.sh):
#   cr_config_file, cr_credentials_file, _cr_interactive,
#   cr_already_prompted, write_cr_config, write_confluence_credentials,
#   maybe_migrate_cr_config, _cr_reconcile_disabled_plists
#
# IMPORTANT: This script MUST run under bash (not zsh) because the helper
# functions use bare $csv word-splitting which does NOT happen in zsh.
# All filesystem activity is sandboxed to TEST_TMP_DIR — real $HOME is never
# touched.
#
# Run:  bash tests/test-xaca-0470-cr-enable.sh
# Exit: 0 = all pass, non-zero = at least one failure.

# ─────────────────────────────────────────────────────────────────────────────
# Guard: must run under bash, not zsh (word-splitting requirement)
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${BASH_VERSION:-}" ]; then
    echo "FATAL: This test must be run under bash (not zsh)." >&2
    echo "  Run: bash $(basename "$0")" >&2
    exit 1
fi

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$TAP_ROOT/libexec/installers/install-kanban.sh"

if [ ! -f "$INSTALLER" ]; then
    echo "FATAL: install-kanban.sh not found at: $INSTALLER" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Minimal self-contained test framework
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
fi

assert_equal() {
    local got="$1" expected="$2" msg="${3:-Expected '$expected', got '$got'}"
    [ "$got" = "$expected" ] || { test_fail "$msg"; return 1; }
}
assert_file_exists()     { [ -f "$1" ] || { test_fail "${2:-Expected file to exist: $1}"; return 1; }; }
assert_file_not_exists() { [ ! -f "$1" ] || { test_fail "${2:-Expected file to NOT exist: $1}"; return 1; }; }
assert_contains()        { [[ "$1" == *"$2"* ]] || { test_fail "${3:-Expected to find '$2' in output}"; return 1; }; }

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox: isolated $HOME so no real ~/.config or ~/Library is touched
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0470-cr-enable.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

# Override HOME → sandbox so cr_config_file / cr_credentials_file resolve into it
export HOME="$TEST_TMP_DIR/home"
mkdir -p "$HOME"

# Sandboxed AITEAMFORGE_DIR (used by maybe_migrate_cr_config)
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
mkdir -p "$AITEAMFORGE_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Stub output helpers and launchctl BEFORE extracting functions.
# This prevents sourcing the full install-kanban.sh (which has side-effect
# code at top-level) while still giving the functions their dependencies.
# ─────────────────────────────────────────────────────────────────────────────
info()       { :; }
warning()    { :; }
success()    { :; }
header()     { :; }
error()      { :; }
print_info()    { :; }
print_warning() { :; }
print_success() { :; }
print_error()   { :; }
print_section() { :; }
launchctl()  { :; }   # stub — prevents any real launchd interaction

# ─────────────────────────────────────────────────────────────────────────────
# Extract and eval the target functions from install-kanban.sh.
# Handles two forms:
#   1. One-liner: `name()      { ... }` (entire definition on one line)
#   2. Multi-line: `name() {` ... column-0 `}` terminator
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "[ \t]*\\(\\)[ \t]*\\{") {
          capture=1
          print
          # If this same line also ends the function body (one-liner), stop.
          if (/\}[ \t]*$/ && NF > 2) { exit }
          next
      }
      capture { print }
      capture && /^}$/ { exit }
    ' "$INSTALLER"
}

for _fn in cr_config_file cr_credentials_file _cr_interactive cr_already_prompted \
           write_cr_config write_confluence_credentials \
           _cr_prompt_credentials_and_write \
           maybe_migrate_cr_config _cr_reconcile_disabled_plists; do
    _src="$(_extract_fn "$_fn")"
    if [ -z "$_src" ]; then
        echo "FATAL: could not extract '$_fn' from install-kanban.sh" >&2
        exit 1
    fi
    eval "$_src"
    declare -f "$_fn" >/dev/null || { echo "FATAL: '$_fn' not defined after extraction" >&2; exit 1; }
done

# Verify jq is available (required by the functions under test)
if ! command -v jq &>/dev/null; then
    echo "FATAL: jq is not installed — required by functions under test" >&2
    exit 1
fi

# Helper: reset the sandbox config dir between tests
_reset_config() {
    rm -rf "$HOME/.config"
    mkdir -p "$HOME/.config/aiteamforge"
}

# ─────────────────────────────────────────────────────────────────────────────
# CASE A: write_cr_config multi-team word-splitting (bash-specific)
# Asserts:
#   - enabled='mainevent' all='academy mainevent' → teams.academy=false,
#     teams.mainevent=true, .prompted=true, .version=1
#   - BASH TRAP: verifies the all_csv actually word-splits into 2 keys
#     (under zsh "academy mainevent" stays as one key — false green)
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case A: write_cr_config splits multi-team csv correctly (bash word-splitting)"
_reset_config
write_cr_config "mainevent" "academy mainevent"
cfg_file="$(cr_config_file)"
assert_file_exists "$cfg_file" "cr-config.json must be created" || { _done_a=fail; }

if [ -f "$cfg_file" ]; then
    version="$(jq -r '.version'  "$cfg_file")"
    prompted="$(jq -r '.prompted' "$cfg_file")"
    acad_flag="$(jq -r '.teams.academy'    "$cfg_file")"
    me_flag="$(jq -r   '.teams.mainevent'  "$cfg_file")"
    key_count="$(jq '.teams | length' "$cfg_file")"

    _ok=true
    assert_equal "$version"   "1"    ".version must be 1"     || _ok=false
    assert_equal "$prompted"  "true" ".prompted must be true"  || _ok=false
    assert_equal "$acad_flag" "false" ".teams.academy must be false" || _ok=false
    assert_equal "$me_flag"   "true"  ".teams.mainevent must be true" || _ok=false
    # BASH trap: zsh collapses "academy mainevent" to one key → key_count would be 1
    assert_equal "$key_count" "2" "teams must have 2 keys (bash word-splitting trap guard)" || _ok=false
    [ "$_ok" = true ] && test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE B: write_cr_config merge — second call adds a team, preserves prior flags
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case B: write_cr_config merges with prior config, preserving existing flags"
# Config from Case A already has academy=false, mainevent=true.
# Now add 'firebase' as enabled, re-pass all three teams.
write_cr_config "mainevent firebase" "academy mainevent firebase"
cfg_file="$(cr_config_file)"
if [ -f "$cfg_file" ]; then
    acad_flag="$(jq -r '.teams.academy'   "$cfg_file")"
    me_flag="$(jq -r   '.teams.mainevent' "$cfg_file")"
    fb_flag="$(jq -r   '.teams.firebase'  "$cfg_file")"
    key_count="$(jq '.teams | length' "$cfg_file")"

    _ok=true
    assert_equal "$acad_flag" "false" "academy must still be false after merge" || _ok=false
    assert_equal "$me_flag"   "true"  "mainevent must remain true after merge"  || _ok=false
    assert_equal "$fb_flag"   "true"  "firebase must be added as true"          || _ok=false
    assert_equal "$key_count" "3"     "teams must have 3 keys after merge"      || _ok=false
    [ "$_ok" = true ] && test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE C: write_confluence_credentials — file mode 600, correct token, default
#         set, second call merges (both teams present)
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case C: write_confluence_credentials — mode 600, token stored, default set"
_reset_config
write_confluence_credentials "mainevent" "user@example.com" "tok123" "example.atlassian.net" "DPD"
creds_file="$(cr_credentials_file)"
assert_file_exists "$creds_file" "credentials file must be created" || true

if [ -f "$creds_file" ]; then
    file_mode="$(stat -f "%A" "$creds_file" 2>/dev/null || stat -c "%a" "$creds_file" 2>/dev/null)"
    stored_token="$(jq -r '.teams.mainevent.api_token' "$creds_file")"
    default_team="$(jq -r '.default' "$creds_file")"

    _ok=true
    assert_equal "$file_mode"    "600"     "credentials file mode must be 600"    || _ok=false
    assert_equal "$stored_token" "tok123"  "api_token must match the supplied one" || _ok=false
    assert_equal "$default_team" "mainevent" ".default must be set to first team"  || _ok=false
    [ "$_ok" = true ] && test_pass
fi

test_start "Case C (merge): write_confluence_credentials merges — both teams present"
# Add a second team; existing mainevent entry must persist
write_confluence_credentials "firebase" "user@example.com" "tok456" "example.atlassian.net" "FIRE"
if [ -f "$creds_file" ]; then
    me_token="$(jq -r '.teams.mainevent.api_token' "$creds_file")"
    fb_token="$(jq -r '.teams.firebase.api_token'  "$creds_file")"
    default_team="$(jq -r '.default' "$creds_file")"
    key_count="$(jq '.teams | length' "$creds_file")"

    _ok=true
    assert_equal "$me_token"     "tok123"    "mainevent token must persist after merge"   || _ok=false
    assert_equal "$fb_token"     "tok456"    "firebase token must be added"               || _ok=false
    assert_equal "$default_team" "mainevent" "default must remain first team after merge" || _ok=false
    assert_equal "$key_count"    "2"         "both teams must be present after merge"     || _ok=false
    [ "$_ok" = true ] && test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE D: cr_already_prompted — false when no cr-config; true after write_cr_config
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case D: cr_already_prompted returns false when no cr-config.json exists"
_reset_config
if cr_already_prompted; then
    test_fail "cr_already_prompted must return false when cr-config.json is absent"
else
    test_pass
fi

test_start "Case D: cr_already_prompted returns true after write_cr_config"
write_cr_config "mainevent" "academy mainevent"
if cr_already_prompted; then
    test_pass
else
    test_fail "cr_already_prompted must return true after write_cr_config sets prompted=true"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE E: maybe_migrate_cr_config — Case 1 (infer from existing credentials)
# Pre-create a credentials file with teams {mainevent:...} and NO cr-config.
# After call: cr-config exists with mainevent:true, prompted:true.
# No prompt was shown (non-interactive path would also be fine here since we
# are in a test shell without a TTY, but we verify via file content).
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case E: maybe_migrate_cr_config infers CR config from existing credentials (Case 1)"
_reset_config
# Manually write a credentials file with one team — no cr-config yet
creds_file="$(cr_credentials_file)"
mkdir -p "$(dirname "$creds_file")"
( umask 077
  jq -n '{"teams":{"mainevent":{"site":"example.atlassian.net","email":"u@e.com","api_token":"t","space_key":"D"}},"default":"mainevent"}' > "$creds_file" )
chmod 600 "$creds_file"

cfg_file="$(cr_config_file)"
# Verify cr-config does NOT exist before the call
assert_file_not_exists "$cfg_file" "cr-config must not exist before migration" || true

# Run the migration; it must NOT prompt (Case 1 path is silent)
maybe_migrate_cr_config

assert_file_exists "$cfg_file" "cr-config must be created by Case 1 migration" || true
if [ -f "$cfg_file" ]; then
    prompted="$(jq -r '.prompted' "$cfg_file")"
    me_flag="$(jq -r '.teams.mainevent // "MISSING"' "$cfg_file")"

    _ok=true
    assert_equal "$prompted" "true" "cr-config.prompted must be true after migration" || _ok=false
    assert_equal "$me_flag"  "true" "cr-config.teams.mainevent must be inferred as true" || _ok=false
    [ "$_ok" = true ] && test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE F: maybe_migrate_cr_config — Case 2 (non-interactive no-op)
# No credentials file; AITEAMFORGE_NONINTERACTIVE=1 forces non-interactive.
# A .aiteamforge-config with teams is present.
# After call: NO cr-config written; exits cleanly (never blocks).
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case F: maybe_migrate_cr_config non-interactive with teams configured — no cr-config written"
_reset_config
# Write .aiteamforge-config with teams list
mkdir -p "$AITEAMFORGE_DIR"
jq -n '{"teams":["academy","mainevent"]}' > "$AITEAMFORGE_DIR/.aiteamforge-config"
# No credentials file

cfg_file="$(cr_config_file)"
creds_file="$(cr_credentials_file)"
assert_file_not_exists "$cfg_file"   "cr-config must not exist at test start"   || true
assert_file_not_exists "$creds_file" "credentials must not exist at test start" || true

# Force non-interactive mode
AITEAMFORGE_NONINTERACTIVE=1 maybe_migrate_cr_config
rc=$?

assert_file_not_exists "$cfg_file"   "cr-config must NOT be written in non-interactive mode" || true
assert_equal "$rc" "0" "maybe_migrate_cr_config must exit 0 in non-interactive mode (never blocks)" || true
test_pass  # If we reached here without abort, Case F logic is correct

# ─────────────────────────────────────────────────────────────────────────────
# CASE G: maybe_migrate_cr_config — Case 3 (already prompted, must be no-op)
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case G: maybe_migrate_cr_config is a no-op when already prompted"
_reset_config
# Write cr-config with prompted=true
write_cr_config "mainevent" "academy mainevent"
cfg_file="$(cr_config_file)"
cfg_before="$(cat "$cfg_file")"

# Call maybe_migrate_cr_config — must return immediately, not modify cr-config
maybe_migrate_cr_config
cfg_after="$(cat "$cfg_file")"

assert_equal "$cfg_before" "$cfg_after" "cr-config must be unchanged when already prompted" && test_pass

# ─────────────────────────────────────────────────────────────────────────────
# CASE H: _cr_reconcile_disabled_plists
# Create fake plist files for an enabled team and a disabled team.
# cr-config marks enabled=true, disabled=false.
# After call: disabled plist removed, enabled plist remains.
# launchctl is already stubbed to a no-op so no real launchd interaction.
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case H: _cr_reconcile_disabled_plists removes disabled-team plists, preserves enabled-team plist"
_reset_config

# Set up sandboxed LaunchAgents dir inside fake HOME
launch_agents="$HOME/Library/LaunchAgents"
mkdir -p "$launch_agents"

# Create fake plist files for two teams
enabled_plist="$launch_agents/com.aiteamforge.cr-confluence-poller.mainevent.plist"
disabled_plist="$launch_agents/com.aiteamforge.cr-confluence-poller.academy.plist"
printf '<?xml version="1.0"?>\n<plist></plist>\n' > "$enabled_plist"
printf '<?xml version="1.0"?>\n<plist></plist>\n' > "$disabled_plist"

# Write cr-config: mainevent=true, academy=false
write_cr_config "mainevent" "academy mainevent"

assert_file_exists "$enabled_plist"  "enabled plist must exist before reconcile"  || true
assert_file_exists "$disabled_plist" "disabled plist must exist before reconcile" || true

# Run reconcile (launchctl is stubbed — safe)
_cr_reconcile_disabled_plists

_ok=true
assert_file_exists     "$enabled_plist"  "enabled team plist must REMAIN after reconcile"        || _ok=false
assert_file_not_exists "$disabled_plist" "disabled team plist must be REMOVED after reconcile"   || _ok=false
[ "$_ok" = true ] && test_pass

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
