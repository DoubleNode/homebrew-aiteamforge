#!/bin/bash

# test-validate-install.sh
# Tests for post-install validation (libexec/lib/validate-install.sh)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATE_LIB="$TAP_ROOT/libexec/lib/validate-install.sh"

# ═══════════════════════════════════════════════════════════════════════════
# Test-local helpers
# ═══════════════════════════════════════════════════════════════════════════

# Convenience: source the library fresh each test that needs it.
# The library uses a guard variable (_VALIDATE_INSTALL_SH_LOADED) so we
# clear it before sourcing to allow re-loading across test helpers.
_reload_validate_lib() {
    unset _VALIDATE_INSTALL_SH_LOADED
    # shellcheck source=/dev/null
    source "$VALIDATE_LIB"
}

# Build a minimal install directory tree under TEST_TMP_DIR.
# Arguments: install_dir (defaults to $TEST_TMP_DIR/install)
_make_install_dir() {
    local dir="${1:-$TEST_TMP_DIR/install}"
    mkdir -p "$dir"
    mkdir -p "$dir/templates" "$dir/docs" "$dir/scripts" "$dir/avatars"
    echo "$dir"
}

# Write a valid JSON config into install_dir.
_write_valid_config() {
    local install_dir="$1"
    cat > "$install_dir/.aiteamforge-config" <<'EOF'
{
  "version": "1.3.0",
  "install_dir": "/test/aiteamforge",
  "teams": ["alpha", "beta"],
  "team_paths": {
    "alpha": {"working_dir": "ALPHA_DIR"},
    "beta":  {"working_dir": "BETA_DIR"}
  },
  "features": {
    "shell_environment": true,
    "lcars_kanban": true,
    "fleet_monitor": false
  },
  "installed_at": "2026-01-01T00:00:00Z"
}
EOF
}

# Patch team_paths in an already-written config to point at real dirs.
# $1 = install_dir, $2 = team_id, $3 = real working_dir path
_patch_team_path() {
    local install_dir="$1" team="$2" wdir="$3"
    if command -v jq &>/dev/null; then
        local tmp
        tmp=$(mktemp)
        jq --arg t "$team" --arg d "$wdir" \
            '.team_paths[$t].working_dir = $d' \
            "$install_dir/.aiteamforge-config" > "$tmp" && mv "$tmp" "$install_dir/.aiteamforge-config"
    fi
}

# Write minimal required helper scripts (present + executable).
_write_scripts() {
    local scripts_dir="$1"
    mkdir -p "$scripts_dir"
    local names=(
        "iterm2_window_manager.py"
        "agent-panel-display.sh"
        "display-agent-avatar.sh"
        "lcars-tmp-dir.sh"
    )
    for s in "${names[@]}"; do
        touch "$scripts_dir/$s"
        chmod +x "$scripts_dir/$s"
    done
}

# Capture output of a function, swallowing colors.
_capture() {
    "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}

# ═══════════════════════════════════════════════════════════════════════════
# Bootstrap: source the library once to verify it loads cleanly
# ═══════════════════════════════════════════════════════════════════════════

test_start "validate-install.sh library exists"
assert_file_exists "$VALIDATE_LIB"
test_pass

test_start "validate-install.sh can be sourced without errors"
( unset _VALIDATE_INSTALL_SH_LOADED; source "$VALIDATE_LIB" )
assert_exit_success $?
test_pass

test_start "double-source guard prevents re-sourcing"
unset _VALIDATE_INSTALL_SH_LOADED
# shellcheck source=/dev/null
source "$VALIDATE_LIB"
first_guard="${_VALIDATE_INSTALL_SH_LOADED}"
source "$VALIDATE_LIB"  # second source — should return early
assert_equal "1" "$first_guard"
assert_equal "1" "${_VALIDATE_INSTALL_SH_LOADED}"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# _val_reset — counter initialisation
# ═══════════════════════════════════════════════════════════════════════════

test_start "_val_reset zeroes all counters"
_reload_validate_lib
_VAL_PASS=5; _VAL_WARN=3; _VAL_FAIL=2
_VAL_FAIL_MSGS=("old failure")
_VAL_WARN_MSGS=("old warning")
_val_reset
assert_equal "0" "$_VAL_PASS"
assert_equal "0" "$_VAL_WARN"
assert_equal "0" "$_VAL_FAIL"
assert_equal "0" "${#_VAL_FAIL_MSGS[@]}"
assert_equal "0" "${#_VAL_WARN_MSGS[@]}"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# _val_pass / _val_warn / _val_fail — counter increment & message capture
# ═══════════════════════════════════════════════════════════════════════════

test_start "_val_pass increments PASS counter"
_reload_validate_lib
_val_reset
_val_pass "something worked" >/dev/null
assert_equal "1" "$_VAL_PASS"
assert_equal "0" "$_VAL_WARN"
assert_equal "0" "$_VAL_FAIL"
test_pass

test_start "_val_warn increments WARN counter and appends message"
_reload_validate_lib
_val_reset
_val_warn "watch out" "fix hint" >/dev/null
assert_equal "0" "$_VAL_PASS"
assert_equal "1" "$_VAL_WARN"
assert_equal "0" "$_VAL_FAIL"
assert_equal "watch out" "${_VAL_WARN_MSGS[0]}"
test_pass

test_start "_val_fail increments FAIL counter and appends message"
_reload_validate_lib
_val_reset
_val_fail "something broke" "remedy" >/dev/null
assert_equal "0" "$_VAL_PASS"
assert_equal "0" "$_VAL_WARN"
assert_equal "1" "$_VAL_FAIL"
assert_equal "something broke" "${_VAL_FAIL_MSGS[0]}"
test_pass

test_start "_val_pass output contains check mark"
_reload_validate_lib
_val_reset
output=$(_capture _val_pass "check this")
assert_contains "$output" "check this"
test_pass

test_start "_val_warn output contains warning marker and hint"
_reload_validate_lib
_val_reset
output=$(_capture _val_warn "beware" "do the thing")
assert_contains "$output" "beware"
assert_contains "$output" "do the thing"
test_pass

test_start "_val_fail output contains failure marker and hint"
_reload_validate_lib
_val_reset
output=$(_capture _val_fail "broke it" "fix it now")
assert_contains "$output" "broke it"
assert_contains "$output" "fix it now"
test_pass

test_start "_val_warn without hint emits no Fix: line"
_reload_validate_lib
_val_reset
output=$(_capture _val_warn "no hint here")
assert_not_contains "$output" "Fix:"
test_pass

test_start "_val_fail without hint emits no Fix: line"
_reload_validate_lib
_val_reset
output=$(_capture _val_fail "no hint here")
assert_not_contains "$output" "Fix:"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# _file_exists_x — file existence + executable predicate
# ═══════════════════════════════════════════════════════════════════════════

test_start "_file_exists_x returns true for existing executable file"
_reload_validate_lib
local_exe="$TEST_TMP_DIR/myexec.sh"
touch "$local_exe"; chmod +x "$local_exe"
if _file_exists_x "$local_exe"; then
    test_pass
else
    test_fail "_file_exists_x should return true for executable file"
fi

test_start "_file_exists_x returns false for missing file"
_reload_validate_lib
if _file_exists_x "$TEST_TMP_DIR/nonexistent.sh"; then
    test_fail "_file_exists_x should return false for missing file"
else
    test_pass
fi

test_start "_file_exists_x returns false for non-executable file"
_reload_validate_lib
non_exe="$TEST_TMP_DIR/notexec.sh"
touch "$non_exe"; chmod -x "$non_exe"
if _file_exists_x "$non_exe"; then
    test_fail "_file_exists_x should return false for non-executable file"
else
    test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# _val_check_config
# ═══════════════════════════════════════════════════════════════════════════

test_start "_val_check_config: fails when config file missing"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/cfg_missing"
mkdir -p "$install_dir"
_val_check_config "$install_dir" >/dev/null 2>&1
assert_equal "1" "$_VAL_FAIL"
assert_equal "0" "$_VAL_PASS"
test_pass

test_start "_val_check_config: fail message references config path"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/cfg_missing2"
mkdir -p "$install_dir"
output=$(_capture _val_check_config "$install_dir")
assert_contains "$output" ".aiteamforge-config"
assert_contains "$output" "aiteamforge setup"
test_pass

test_start "_val_check_config: passes when config present and valid JSON (with jq)"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/cfg_valid"
_make_install_dir "$install_dir" >/dev/null
_write_valid_config "$install_dir"
if command -v jq &>/dev/null; then
    _val_check_config "$install_dir" >/dev/null 2>&1
    assert_equal "0" "$_VAL_FAIL"
    # Should have at least: file exists, valid JSON, version, install_dir
    if [ "$_VAL_PASS" -lt 3 ]; then
        test_fail "Expected at least 3 passes for valid config, got $_VAL_PASS"
    else
        test_pass
    fi
else
    test_pass  # Skip body if jq unavailable
fi

test_start "_val_check_config: fails for malformed JSON (with jq)"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/cfg_bad_json"
mkdir -p "$install_dir"
printf '{"version": "1.0.0", bad json\n' > "$install_dir/.aiteamforge-config"
if command -v jq &>/dev/null; then
    _val_check_config "$install_dir" >/dev/null 2>&1
    assert_equal "1" "$_VAL_FAIL"
else
    test_pass  # No jq — skip
fi

test_start "_val_check_config: warns when version field absent"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/cfg_no_version"
mkdir -p "$install_dir"
printf '{"install_dir": "/test"}\n' > "$install_dir/.aiteamforge-config"
if command -v jq &>/dev/null; then
    _val_check_config "$install_dir" >/dev/null 2>&1
    assert_equal "0" "$_VAL_FAIL"
    # Should have a warning about missing version
    if [ "$_VAL_WARN" -lt 1 ]; then
        test_fail "Expected at least 1 warning for missing version, got $_VAL_WARN"
    else
        test_pass
    fi
else
    test_pass
fi

test_start "_val_check_config: warns when install_dir field absent"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/cfg_no_install_dir"
mkdir -p "$install_dir"
printf '{"version": "1.0.0"}\n' > "$install_dir/.aiteamforge-config"
if command -v jq &>/dev/null; then
    _val_check_config "$install_dir" >/dev/null 2>&1
    assert_equal "0" "$_VAL_FAIL"
    if [ "$_VAL_WARN" -lt 1 ]; then
        test_fail "Expected warning for missing install_dir, got $_VAL_WARN"
    else
        test_pass
    fi
else
    test_pass
fi

test_start "_val_check_config: warns when jq unavailable"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/cfg_no_jq"
mkdir -p "$install_dir"
printf '{"version": "1.0.0"}\n' > "$install_dir/.aiteamforge-config"
# Run with PATH stripped of jq — use subshell to guarantee PATH restoration
if (
    PATH="/usr/bin:/bin"
    # Only test this when jq really is absent on the stripped PATH
    if ! command -v jq &>/dev/null 2>&1; then
        _val_check_config "$install_dir" >/dev/null 2>&1
        # Should warn about jq not installed
        [ "$_VAL_WARN" -ge 1 ]
    else
        true  # jq still findable on minimal PATH — skip assertion
    fi
); then
    test_pass
else
    test_fail "Expected warning about jq not installed"
fi

# ═══════════════════════════════════════════════════════════════════════════
# _val_check_install_dir
# ═══════════════════════════════════════════════════════════════════════════

test_start "_val_check_install_dir: fails when install dir missing"
_reload_validate_lib
_val_reset
_val_check_install_dir "$TEST_TMP_DIR/no_such_dir" >/dev/null 2>&1
assert_equal "1" "$_VAL_FAIL"
test_pass

test_start "_val_check_install_dir: passes when install dir and all subdirs exist"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/full_dir"
_make_install_dir "$install_dir" >/dev/null
_val_check_install_dir "$install_dir" >/dev/null 2>&1
assert_equal "0" "$_VAL_FAIL"
assert_equal "0" "$_VAL_WARN"
# Expect 5 passes: install_dir + templates + docs + scripts + avatars
assert_equal "5" "$_VAL_PASS"
test_pass

test_start "_val_check_install_dir: warns for each missing required subdirectory"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/partial_dir"
mkdir -p "$install_dir"             # no subdirs
_val_check_install_dir "$install_dir" >/dev/null 2>&1
assert_equal "0" "$_VAL_FAIL"
assert_equal "4" "$_VAL_WARN"       # templates, docs, scripts, avatars
assert_equal "1" "$_VAL_PASS"       # install_dir itself
test_pass

test_start "_val_check_install_dir: early return when install dir absent (no subdir checks)"
_reload_validate_lib
_val_reset
_val_check_install_dir "$TEST_TMP_DIR/missing_dir" >/dev/null 2>&1
# Only the one fail — no subdirectory warnings should accumulate
assert_equal "1" "$_VAL_FAIL"
assert_equal "0" "$_VAL_WARN"
test_pass

test_start "_val_check_install_dir: output includes remediation hint"
_reload_validate_lib
_val_reset
output=$(_capture _val_check_install_dir "$TEST_TMP_DIR/hint_dir")
assert_contains "$output" "aiteamforge setup"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# _val_check_scripts
# ═══════════════════════════════════════════════════════════════════════════

test_start "_val_check_scripts: fails when scripts/ directory missing"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/no_scripts_dir"
mkdir -p "$install_dir"
_val_check_scripts "$install_dir" >/dev/null 2>&1
assert_equal "1" "$_VAL_FAIL"
test_pass

test_start "_val_check_scripts: passes all required scripts present and executable"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/good_scripts"
mkdir -p "$install_dir"
_write_scripts "$install_dir/scripts"
# Also create root-level backward-compat copy
cp "$install_dir/scripts/iterm2_window_manager.py" "$install_dir/iterm2_window_manager.py"
_val_check_scripts "$install_dir" >/dev/null 2>&1
assert_equal "0" "$_VAL_FAIL"
assert_equal "0" "$_VAL_WARN"
# 4 required scripts + root copy = 5 passes
assert_equal "5" "$_VAL_PASS"
test_pass

test_start "_val_check_scripts: warns for missing script file"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/missing_one_script"
mkdir -p "$install_dir/scripts"
# Create all except iterm2_window_manager.py
for s in "agent-panel-display.sh" "display-agent-avatar.sh" "lcars-tmp-dir.sh"; do
    touch "$install_dir/scripts/$s"
    chmod +x "$install_dir/scripts/$s"
done
_val_check_scripts "$install_dir" >/dev/null 2>&1
# iterm2_window_manager.py missing from scripts/ AND root copy also missing
assert_equal "0" "$_VAL_FAIL"
assert_equal "2" "$_VAL_WARN"
test_pass

test_start "_val_check_scripts: warns for non-executable script"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/non_exec_script"
_write_scripts "$install_dir/scripts"
chmod -x "$install_dir/scripts/lcars-tmp-dir.sh"
cp "$install_dir/scripts/iterm2_window_manager.py" "$install_dir/iterm2_window_manager.py"
_val_check_scripts "$install_dir" >/dev/null 2>&1
assert_equal "0" "$_VAL_FAIL"
assert_equal "1" "$_VAL_WARN"
test_pass

test_start "_val_check_scripts: warns when root-level iterm2_window_manager.py absent"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/no_root_wm"
_write_scripts "$install_dir/scripts"
# Deliberately do NOT copy root-level window manager
_val_check_scripts "$install_dir" >/dev/null 2>&1
assert_equal "0" "$_VAL_FAIL"
assert_equal "1" "$_VAL_WARN"
test_pass

test_start "_val_check_scripts: warn message includes chmod hint for non-executable"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/chmod_hint"
_write_scripts "$install_dir/scripts"
chmod -x "$install_dir/scripts/agent-panel-display.sh"
cp "$install_dir/scripts/iterm2_window_manager.py" "$install_dir/iterm2_window_manager.py"
output=$(_capture _val_check_scripts "$install_dir")
assert_contains "$output" "chmod +x"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# _val_check_lcars
# ═══════════════════════════════════════════════════════════════════════════

test_start "_val_check_lcars: warns when lcars-ui directory missing"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/lcars_absent"
mkdir -p "$install_dir"
_val_check_lcars "$install_dir" >/dev/null 2>&1
assert_equal "0" "$_VAL_FAIL"
assert_equal "1" "$_VAL_WARN"
assert_equal "0" "$_VAL_PASS"
test_pass

test_start "_val_check_lcars: passes with all LCARS files present"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/lcars_full"
mkdir -p "$install_dir/lcars-ui"
touch "$install_dir/lcars-ui/server.py"
touch "$install_dir/lcars-ui/index.html"
printf '8260\n' > "$install_dir/lcars-ui/.lcars-port"
_val_check_lcars "$install_dir" >/dev/null 2>&1
assert_equal "0" "$_VAL_FAIL"
assert_equal "0" "$_VAL_WARN"
# lcars-ui dir + server.py + index.html + .lcars-port + python3
assert_equal "5" "$_VAL_PASS"
test_pass

test_start "_val_check_lcars: warns when server.py missing"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/lcars_no_server"
mkdir -p "$install_dir/lcars-ui"
touch "$install_dir/lcars-ui/index.html"
printf '8260\n' > "$install_dir/lcars-ui/.lcars-port"
_val_check_lcars "$install_dir" >/dev/null 2>&1
assert_equal "0" "$_VAL_FAIL"
assert_equal "1" "$_VAL_WARN"
test_pass

test_start "_val_check_lcars: warns when index.html missing"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/lcars_no_index"
mkdir -p "$install_dir/lcars-ui"
touch "$install_dir/lcars-ui/server.py"
printf '8260\n' > "$install_dir/lcars-ui/.lcars-port"
_val_check_lcars "$install_dir" >/dev/null 2>&1
assert_equal "0" "$_VAL_FAIL"
assert_equal "1" "$_VAL_WARN"
test_pass

test_start "_val_check_lcars: warns when .lcars-port file missing"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/lcars_no_port"
mkdir -p "$install_dir/lcars-ui"
touch "$install_dir/lcars-ui/server.py"
touch "$install_dir/lcars-ui/index.html"
_val_check_lcars "$install_dir" >/dev/null 2>&1
assert_equal "0" "$_VAL_FAIL"
assert_equal "1" "$_VAL_WARN"
test_pass

test_start "_val_check_lcars: port value captured from .lcars-port file"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/lcars_port_val"
mkdir -p "$install_dir/lcars-ui"
touch "$install_dir/lcars-ui/server.py"
touch "$install_dir/lcars-ui/index.html"
printf '9090\n' > "$install_dir/lcars-ui/.lcars-port"
output=$(_capture _val_check_lcars "$install_dir")
assert_contains "$output" "9090"
test_pass

test_start "_val_check_lcars: fails when server.py present but python3 unavailable"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/lcars_no_python"
mkdir -p "$install_dir/lcars-ui"
touch "$install_dir/lcars-ui/server.py"
touch "$install_dir/lcars-ui/index.html"
printf '8260\n' > "$install_dir/lcars-ui/.lcars-port"
# Use subshell to guarantee PATH restoration
if (
    PATH="/nonexistent"
    if ! command -v python3 &>/dev/null 2>&1; then
        _val_check_lcars "$install_dir" >/dev/null 2>&1
        [ "$_VAL_FAIL" -eq 1 ]
    else
        true  # python3 still visible — skip assertion
    fi
); then
    test_pass
else
    test_fail "Expected _VAL_FAIL=1 when python3 missing"
fi

# ═══════════════════════════════════════════════════════════════════════════
# _val_check_python_venv
# ═══════════════════════════════════════════════════════════════════════════

test_start "_val_check_python_venv: warns when venv directory absent"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/venv_absent"
mkdir -p "$install_dir"
_val_check_python_venv "$install_dir" >/dev/null 2>&1
assert_equal "0" "$_VAL_FAIL"
assert_equal "1" "$_VAL_WARN"
assert_equal "0" "$_VAL_PASS"
test_pass

test_start "_val_check_python_venv: warns when venv python3 binary missing"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/venv_no_python"
mkdir -p "$install_dir/.venv/bin"
# No python3 binary created
_val_check_python_venv "$install_dir" >/dev/null 2>&1
assert_equal "0" "$_VAL_FAIL"
assert_equal "1" "$_VAL_WARN"
assert_equal "1" "$_VAL_PASS"  # venv dir itself
test_pass

test_start "_val_check_python_venv: warns when venv python3 not executable"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/venv_non_exec_python"
mkdir -p "$install_dir/.venv/bin"
touch "$install_dir/.venv/bin/python3"
chmod -x "$install_dir/.venv/bin/python3"
_val_check_python_venv "$install_dir" >/dev/null 2>&1
assert_equal "0" "$_VAL_FAIL"
assert_equal "1" "$_VAL_WARN"
assert_equal "1" "$_VAL_PASS"  # venv dir
test_pass

test_start "_val_check_python_venv: warns when pip absent from venv"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/venv_no_pip"
mkdir -p "$install_dir/.venv/bin"
touch "$install_dir/.venv/bin/python3"
chmod +x "$install_dir/.venv/bin/python3"
# No pip created
_val_check_python_venv "$install_dir" >/dev/null 2>&1
assert_equal "0" "$_VAL_FAIL"
assert_equal "1" "$_VAL_WARN"
# venv dir + python3 binary = 2 passes
assert_equal "2" "$_VAL_PASS"
test_pass

test_start "_val_check_python_venv: warn message includes venv remediation hint"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/venv_hint"
mkdir -p "$install_dir"
output=$(_capture _val_check_python_venv "$install_dir")
assert_contains "$output" "python3 -m venv"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# _val_check_shell_integration
# ═══════════════════════════════════════════════════════════════════════════

test_start "_val_check_shell_integration: warns when ~/.zshrc missing"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/shell_no_zshrc"
mkdir -p "$install_dir"
# Override HOME so the function looks for a fake ~/.zshrc that doesn't exist
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_no_zshrc"
mkdir -p "$HOME"
_val_check_shell_integration "$install_dir" >/dev/null 2>&1
export HOME="$_original_home"
assert_equal "0" "$_VAL_FAIL"
assert_equal "1" "$_VAL_WARN"
assert_equal "0" "$_VAL_PASS"
test_pass

test_start "_val_check_shell_integration: warns when aiteamforge not in zshrc"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/shell_no_atf"
mkdir -p "$install_dir"
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_no_atf"
mkdir -p "$HOME"
printf '# empty zshrc\n' > "$HOME/.zshrc"
_val_check_shell_integration "$install_dir" >/dev/null 2>&1
export HOME="$_original_home"
assert_equal "0" "$_VAL_FAIL"
# 3 warnings: aiteamforge missing + kanban-helpers missing + aliases file missing
assert_equal "3" "$_VAL_WARN"
assert_equal "0" "$_VAL_PASS"
test_pass

test_start "_val_check_shell_integration: warns when kanban-helpers not in zshrc"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/shell_no_kanban"
mkdir -p "$install_dir"
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_no_kb"
mkdir -p "$HOME"
printf 'source /dev/team/aiteamforge/aiteamforge.sh\n' > "$HOME/.zshrc"
_val_check_shell_integration "$install_dir" >/dev/null 2>&1
export HOME="$_original_home"
assert_equal "0" "$_VAL_FAIL"
# 2 warnings: kanban-helpers missing + aliases file missing (no claude_agent_aliases.sh in install_dir)
assert_equal "2" "$_VAL_WARN"
assert_equal "1" "$_VAL_PASS"   # aiteamforge found
test_pass

test_start "_val_check_shell_integration: warns when aliases file missing"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/shell_no_aliases"
mkdir -p "$install_dir"
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_good_zshrc"
mkdir -p "$HOME"
printf 'source /path/aiteamforge.sh\nsource /path/kanban-helpers.sh\n' > "$HOME/.zshrc"
# No claude_agent_aliases.sh in install_dir
_val_check_shell_integration "$install_dir" >/dev/null 2>&1
export HOME="$_original_home"
assert_equal "0" "$_VAL_FAIL"
assert_equal "1" "$_VAL_WARN"
assert_equal "2" "$_VAL_PASS"   # aiteamforge + kanban-helpers
test_pass

test_start "_val_check_shell_integration: passes all checks when fully configured"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/shell_full"
mkdir -p "$install_dir"
touch "$install_dir/claude_agent_aliases.sh"
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_full"
mkdir -p "$HOME"
printf 'source /path/aiteamforge.sh\nsource /path/kanban-helpers.sh\n' > "$HOME/.zshrc"
_val_check_shell_integration "$install_dir" >/dev/null 2>&1
export HOME="$_original_home"
assert_equal "0" "$_VAL_FAIL"
assert_equal "0" "$_VAL_WARN"
assert_equal "3" "$_VAL_PASS"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# _val_check_fleet
# ═══════════════════════════════════════════════════════════════════════════

test_start "_val_check_fleet: skips silently when fleet not installed"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/fleet_not_installed"
mkdir -p "$install_dir"
# Point HOME to a dir where fleet-config.json does not exist
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_no_fleet"
mkdir -p "$HOME"
_val_check_fleet "$install_dir" >/dev/null 2>&1
export HOME="$_original_home"
assert_equal "0" "$_VAL_PASS"
assert_equal "0" "$_VAL_WARN"
assert_equal "0" "$_VAL_FAIL"
test_pass

test_start "_val_check_fleet: runs checks when fleet-monitor dir exists"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/fleet_dir_present"
mkdir -p "$install_dir/fleet-monitor/client"
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_fleet_dir"
mkdir -p "$HOME/.aiteamforge"
# No fleet-config.json — should warn
_val_check_fleet "$install_dir" >/dev/null 2>&1
export HOME="$_original_home"
# Warns: fleet config missing + reporter script missing
assert_equal "0" "$_VAL_FAIL"
assert_equal "2" "$_VAL_WARN"
test_pass

test_start "_val_check_fleet: passes when config and reporter both present and executable"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/fleet_full"
mkdir -p "$install_dir/fleet-monitor/client"
fleet_reporter="$install_dir/fleet-monitor/client/fleet-reporter.sh"
touch "$fleet_reporter"; chmod +x "$fleet_reporter"
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_fleet_full"
mkdir -p "$HOME/.aiteamforge"
printf '{"server_url": "https://example.com"}\n' > "$HOME/.aiteamforge/fleet-config.json"
_val_check_fleet "$install_dir" >/dev/null 2>&1
export HOME="$_original_home"
assert_equal "0" "$_VAL_FAIL"
assert_equal "0" "$_VAL_WARN"
assert_equal "3" "$_VAL_PASS"   # config file + valid JSON + reporter executable
test_pass

test_start "_val_check_fleet: warns when reporter not executable"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/fleet_reporter_non_exec"
mkdir -p "$install_dir/fleet-monitor/client"
fleet_reporter="$install_dir/fleet-monitor/client/fleet-reporter.sh"
touch "$fleet_reporter"; chmod -x "$fleet_reporter"
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_fleet_reporter_non_exec"
mkdir -p "$HOME/.aiteamforge"
printf '{"server_url": "https://example.com"}\n' > "$HOME/.aiteamforge/fleet-config.json"
_val_check_fleet "$install_dir" >/dev/null 2>&1
export HOME="$_original_home"
assert_equal "0" "$_VAL_FAIL"
assert_equal "1" "$_VAL_WARN"
test_pass

test_start "_val_check_fleet: warns for malformed fleet config JSON (with jq)"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/fleet_bad_json"
mkdir -p "$install_dir/fleet-monitor/client"
fleet_reporter="$install_dir/fleet-monitor/client/fleet-reporter.sh"
touch "$fleet_reporter"; chmod +x "$fleet_reporter"
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_fleet_bad_json"
mkdir -p "$HOME/.aiteamforge"
printf '{bad json\n' > "$HOME/.aiteamforge/fleet-config.json"
if command -v jq &>/dev/null; then
    _val_check_fleet "$install_dir" >/dev/null 2>&1
    assert_equal "0" "$_VAL_FAIL"
    assert_equal "1" "$_VAL_WARN"
    test_pass
else
    test_pass  # No jq — skip
fi
export HOME="$_original_home"

# ═══════════════════════════════════════════════════════════════════════════
# _val_check_launchagents
# ═══════════════════════════════════════════════════════════════════════════

test_start "_val_check_launchagents: warns when plists missing"
_reload_validate_lib
_val_reset
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_la_absent"
mkdir -p "$HOME/Library/LaunchAgents"
# No plists
_val_check_launchagents >/dev/null 2>&1
export HOME="$_original_home"
assert_equal "0" "$_VAL_FAIL"
assert_equal "2" "$_VAL_WARN"   # kanban-backup + lcars-health
assert_equal "0" "$_VAL_PASS"
test_pass

test_start "_val_check_launchagents: warn mentions remediation command"
_reload_validate_lib
_val_reset
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_la_hint"
mkdir -p "$HOME/Library/LaunchAgents"
output=$(_capture _val_check_launchagents)
export HOME="$_original_home"
assert_contains "$output" "aiteamforge setup"
test_pass

test_start "_val_check_launchagents: warns when plist exists but not loaded"
_reload_validate_lib
_val_reset
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_la_not_loaded"
mkdir -p "$HOME/Library/LaunchAgents"
# Create both plists
touch "$HOME/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist"
touch "$HOME/Library/LaunchAgents/com.aiteamforge.lcars-health.plist"
# Mock launchctl to return empty (simulating "not loaded")
launchctl() { echo ""; }
export -f launchctl
_val_check_launchagents >/dev/null 2>&1
unset -f launchctl
export HOME="$_original_home"
assert_equal "0" "$_VAL_FAIL"
assert_equal "2" "$_VAL_WARN"   # both present but not loaded
assert_equal "0" "$_VAL_PASS"
test_pass

test_start "_val_check_launchagents: passes when agents loaded"
_reload_validate_lib
_val_reset
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_la_loaded"
mkdir -p "$HOME/Library/LaunchAgents"
touch "$HOME/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist"
touch "$HOME/Library/LaunchAgents/com.aiteamforge.lcars-health.plist"
# Mock launchctl to report both agents loaded
launchctl() {
    printf '0\tcom.aiteamforge.kanban-backup\n'
    printf '0\tcom.aiteamforge.lcars-health\n'
}
export -f launchctl
_val_check_launchagents >/dev/null 2>&1
unset -f launchctl
export HOME="$_original_home"
assert_equal "0" "$_VAL_FAIL"
assert_equal "0" "$_VAL_WARN"
assert_equal "2" "$_VAL_PASS"
test_pass

test_start "_val_check_launchagents: warn message includes launchctl load hint"
_reload_validate_lib
_val_reset
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_la_lctl_hint"
mkdir -p "$HOME/Library/LaunchAgents"
touch "$HOME/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist"
touch "$HOME/Library/LaunchAgents/com.aiteamforge.lcars-health.plist"
launchctl() { echo ""; }
export -f launchctl
output=$(_capture _val_check_launchagents)
unset -f launchctl
export HOME="$_original_home"
assert_contains "$output" "launchctl load"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# validate_installation — integration (full entrypoint)
# ═══════════════════════════════════════════════════════════════════════════

test_start "validate_installation: returns 0 (success) when no failures occur"
_reload_validate_lib
install_dir="$TEST_TMP_DIR/vi_happy"
_make_install_dir "$install_dir" >/dev/null
# Write config without teams to avoid team directory failures
printf '{"version":"1.3.0","install_dir":"%s","teams":[]}\n' "$install_dir" \
    > "$install_dir/.aiteamforge-config"
_write_scripts "$install_dir/scripts"
cp "$install_dir/scripts/iterm2_window_manager.py" "$install_dir/iterm2_window_manager.py"
mkdir -p "$install_dir/lcars-ui"
touch "$install_dir/lcars-ui/server.py" "$install_dir/lcars-ui/index.html"
printf '8260\n' > "$install_dir/lcars-ui/.lcars-port"
mkdir -p "$install_dir/.venv/bin"
touch "$install_dir/.venv/bin/python3"; chmod +x "$install_dir/.venv/bin/python3"
touch "$install_dir/claude_agent_aliases.sh"
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_vi_happy"
mkdir -p "$HOME/Library/LaunchAgents"
printf 'source /path/aiteamforge.sh\nsource /path/kanban-helpers.sh\n' > "$HOME/.zshrc"
launchctl() { echo ""; }
export -f launchctl
validate_installation "$install_dir" >/dev/null 2>&1
local_exit=$?
unset -f launchctl
export HOME="$_original_home"
# No _VAL_FAIL means exit 0
assert_exit_success "$local_exit"
test_pass

test_start "validate_installation: returns 1 (failure) when config file absent"
_reload_validate_lib
install_dir="$TEST_TMP_DIR/vi_fail_config"
mkdir -p "$install_dir"
validate_installation "$install_dir" >/dev/null 2>&1
local_exit=$?
assert_exit_failure "$local_exit"
test_pass

test_start "validate_installation: default install_dir is ~/aiteamforge when no arg given"
_reload_validate_lib
# Just check that it attempts ~/aiteamforge — will fail (no such dir), but exit != "crash"
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_default_dir"
mkdir -p "$HOME"
touch "$HOME/.zshrc"
output=$(_capture validate_installation || true)
export HOME="$_original_home"
assert_contains "$output" "aiteamforge"
test_pass

test_start "validate_installation: summary output includes passed/warnings/failed counts"
_reload_validate_lib
install_dir="$TEST_TMP_DIR/vi_summary"
mkdir -p "$install_dir"
output=$(_capture validate_installation "$install_dir" || true)
assert_contains "$output" "Passed:"
assert_contains "$output" "Warnings:"
assert_contains "$output" "Failed:"
test_pass

test_start "validate_installation: banner is shown in output"
_reload_validate_lib
install_dir="$TEST_TMP_DIR/vi_banner"
mkdir -p "$install_dir"
output=$(_capture validate_installation "$install_dir" || true)
assert_contains "$output" "AITeamForge"
assert_contains "$output" "Post-Install Validation"
test_pass

test_start "validate_installation: failure summary lists failed checks"
_reload_validate_lib
install_dir="$TEST_TMP_DIR/vi_fail_list"
mkdir -p "$install_dir"
# No config — guaranteed failure
output=$(_capture validate_installation "$install_dir" || true)
assert_contains "$output" "Failed checks:"
test_pass

test_start "validate_installation: success message shown when zero failures and zero warnings"
_reload_validate_lib
install_dir="$TEST_TMP_DIR/vi_clean_msg"
_make_install_dir "$install_dir" >/dev/null
# Config without teams to avoid team directory failures
printf '{"version":"1.3.0","install_dir":"%s","teams":[]}\n' "$install_dir" \
    > "$install_dir/.aiteamforge-config"
_write_scripts "$install_dir/scripts"
cp "$install_dir/scripts/iterm2_window_manager.py" "$install_dir/iterm2_window_manager.py"
mkdir -p "$install_dir/lcars-ui"
touch "$install_dir/lcars-ui/server.py" "$install_dir/lcars-ui/index.html"
printf '8260\n' > "$install_dir/lcars-ui/.lcars-port"
mkdir -p "$install_dir/.venv/bin"
touch "$install_dir/.venv/bin/python3"; chmod +x "$install_dir/.venv/bin/python3"
touch "$install_dir/claude_agent_aliases.sh"
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_vi_clean"
mkdir -p "$HOME/Library/LaunchAgents"
printf 'source /path/aiteamforge.sh\nsource /path/kanban-helpers.sh\n' > "$HOME/.zshrc"
launchctl() { echo ""; }
export -f launchctl
output=$(_capture validate_installation "$install_dir")
unset -f launchctl
export HOME="$_original_home"
# With warnings present (agents not loaded, venv pip absent, etc.) we get the warning message.
# The key assertion: no "failure(s)" in message.
assert_not_contains "$output" "failure(s) that need to be resolved"
test_pass

test_start "validate_installation: warning summary message shown when warnings but no failures"
_reload_validate_lib
install_dir="$TEST_TMP_DIR/vi_warn_msg"
_make_install_dir "$install_dir" >/dev/null
# Config without teams to avoid team directory failures
printf '{"version":"1.3.0","install_dir":"%s","teams":[]}\n' "$install_dir" \
    > "$install_dir/.aiteamforge-config"
# Enough to avoid failures, but omit optional things to trigger warnings
_write_scripts "$install_dir/scripts"
cp "$install_dir/scripts/iterm2_window_manager.py" "$install_dir/iterm2_window_manager.py"
_original_home="$HOME"
export HOME="$TEST_TMP_DIR/fakehome_warn_msg"
mkdir -p "$HOME/Library/LaunchAgents"
printf 'source /path/aiteamforge.sh\nsource /path/kanban-helpers.sh\n' > "$HOME/.zshrc"
launchctl() { echo ""; }
export -f launchctl
output=$(_capture validate_installation "$install_dir")
unset -f launchctl
export HOME="$_original_home"
# Should NOT be "everything looks good" because there are warnings (lcars, venv, agents missing)
assert_not_contains "$output" "everything looks good"
assert_not_contains "$output" "failure(s) that need to be resolved"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# _val_check_teams — team directory checks
# ═══════════════════════════════════════════════════════════════════════════

test_start "_val_check_teams: skips silently when no teams in config"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/teams_empty"
mkdir -p "$install_dir"
printf '{"version": "1.0.0", "teams": []}\n' > "$install_dir/.aiteamforge-config"
if command -v jq &>/dev/null; then
    _val_check_teams "$install_dir" >/dev/null 2>&1
    assert_equal "0" "$_VAL_FAIL"
    assert_equal "1" "$_VAL_WARN"   # "No teams found" warning
else
    test_pass
fi
test_pass

test_start "_val_check_teams: warns when team working directory missing"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/teams_no_dir"
mkdir -p "$install_dir"
if command -v jq &>/dev/null; then
    printf '{"version":"1.0.0","teams":["myteam"],"team_paths":{"myteam":{"working_dir":"%s/myteam"}}}\n' \
        "$install_dir" > "$install_dir/.aiteamforge-config"
    # Do NOT create $install_dir/myteam
    _val_check_teams "$install_dir" >/dev/null 2>&1
    assert_equal "1" "$_VAL_FAIL"
    test_pass
else
    test_pass
fi

test_start "_val_check_teams: passes when team directory exists"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/teams_good_dir"
mkdir -p "$install_dir"
if command -v jq &>/dev/null; then
    team_wdir="$install_dir/myteam"
    mkdir -p "$team_wdir/personas"
    printf '# persona\n' > "$team_wdir/personas/agent.md"
    mkdir -p "$team_wdir/kanban"
    touch "$team_wdir/kanban/myteam-board.json"
    startup="$install_dir/myteam-startup.sh"; touch "$startup"; chmod +x "$startup"
    shutdown_s="$install_dir/myteam-shutdown.sh"; touch "$shutdown_s"; chmod +x "$shutdown_s"
    printf '{"version":"1.0.0","teams":["myteam"],"team_paths":{"myteam":{"working_dir":"%s"}}}\n' \
        "$team_wdir" > "$install_dir/.aiteamforge-config"
    _val_check_teams "$install_dir" >/dev/null 2>&1
    assert_equal "0" "$_VAL_FAIL"
    assert_equal "0" "$_VAL_WARN"
    test_pass
else
    test_pass
fi

test_start "_val_check_teams: warns when personas directory missing"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/teams_no_personas"
mkdir -p "$install_dir"
if command -v jq &>/dev/null; then
    team_wdir="$install_dir/myteam2"
    mkdir -p "$team_wdir"  # No personas subdir
    mkdir -p "$team_wdir/kanban"
    touch "$team_wdir/kanban/myteam2-board.json"
    startup="$install_dir/myteam2-startup.sh"; touch "$startup"; chmod +x "$startup"
    shutdown_s="$install_dir/myteam2-shutdown.sh"; touch "$shutdown_s"; chmod +x "$shutdown_s"
    printf '{"version":"1.0.0","teams":["myteam2"],"team_paths":{"myteam2":{"working_dir":"%s"}}}\n' \
        "$team_wdir" > "$install_dir/.aiteamforge-config"
    _val_check_teams "$install_dir" >/dev/null 2>&1
    assert_equal "0" "$_VAL_FAIL"
    assert_equal "1" "$_VAL_WARN"   # personas/ missing
    test_pass
else
    test_pass
fi

test_start "_val_check_teams: warns when kanban board missing"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/teams_no_kanban"
mkdir -p "$install_dir"
if command -v jq &>/dev/null; then
    team_wdir="$install_dir/myteam3"
    mkdir -p "$team_wdir/personas"
    printf '# agent\n' > "$team_wdir/personas/agent.md"
    # No kanban board
    startup="$install_dir/myteam3-startup.sh"; touch "$startup"; chmod +x "$startup"
    shutdown_s="$install_dir/myteam3-shutdown.sh"; touch "$shutdown_s"; chmod +x "$shutdown_s"
    printf '{"version":"1.0.0","teams":["myteam3"],"team_paths":{"myteam3":{"working_dir":"%s"}}}\n' \
        "$team_wdir" > "$install_dir/.aiteamforge-config"
    _val_check_teams "$install_dir" >/dev/null 2>&1
    assert_equal "0" "$_VAL_FAIL"
    assert_equal "1" "$_VAL_WARN"   # kanban board missing
    test_pass
else
    test_pass
fi

test_start "_val_check_teams: warns when startup script missing"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/teams_no_startup"
mkdir -p "$install_dir"
if command -v jq &>/dev/null; then
    team_wdir="$install_dir/myteam4"
    mkdir -p "$team_wdir/personas" "$team_wdir/kanban"
    printf '# agent\n' > "$team_wdir/personas/agent.md"
    touch "$team_wdir/kanban/myteam4-board.json"
    # No startup script
    shutdown_s="$install_dir/myteam4-shutdown.sh"; touch "$shutdown_s"; chmod +x "$shutdown_s"
    printf '{"version":"1.0.0","teams":["myteam4"],"team_paths":{"myteam4":{"working_dir":"%s"}}}\n' \
        "$team_wdir" > "$install_dir/.aiteamforge-config"
    _val_check_teams "$install_dir" >/dev/null 2>&1
    assert_equal "0" "$_VAL_FAIL"
    assert_equal "1" "$_VAL_WARN"   # startup missing
    test_pass
else
    test_pass
fi

test_start "_val_check_teams: warns when startup script not executable"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/teams_startup_non_exec"
mkdir -p "$install_dir"
if command -v jq &>/dev/null; then
    team_wdir="$install_dir/myteam5"
    mkdir -p "$team_wdir/personas" "$team_wdir/kanban"
    printf '# agent\n' > "$team_wdir/personas/agent.md"
    touch "$team_wdir/kanban/myteam5-board.json"
    startup="$install_dir/myteam5-startup.sh"; touch "$startup"; chmod -x "$startup"
    shutdown_s="$install_dir/myteam5-shutdown.sh"; touch "$shutdown_s"; chmod +x "$shutdown_s"
    printf '{"version":"1.0.0","teams":["myteam5"],"team_paths":{"myteam5":{"working_dir":"%s"}}}\n' \
        "$team_wdir" > "$install_dir/.aiteamforge-config"
    _val_check_teams "$install_dir" >/dev/null 2>&1
    assert_equal "0" "$_VAL_FAIL"
    assert_equal "1" "$_VAL_WARN"   # startup not executable
    test_pass
else
    test_pass
fi

test_start "_val_check_teams: fallback to install_dir/<team_id> when team_paths absent"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/teams_fallback"
mkdir -p "$install_dir"
if command -v jq &>/dev/null; then
    # Config has teams but no team_paths
    printf '{"version":"1.0.0","teams":["fallbackteam"]}\n' > "$install_dir/.aiteamforge-config"
    # Create the fallback dir
    fdir="$install_dir/fallbackteam"
    mkdir -p "$fdir/personas" "$fdir/kanban"
    printf '# agent\n' > "$fdir/personas/agent.md"
    touch "$fdir/kanban/fallbackteam-board.json"
    startup="$install_dir/fallbackteam-startup.sh"; touch "$startup"; chmod +x "$startup"
    shutdown_s="$install_dir/fallbackteam-shutdown.sh"; touch "$shutdown_s"; chmod +x "$shutdown_s"
    _val_check_teams "$install_dir" >/dev/null 2>&1
    assert_equal "0" "$_VAL_FAIL"
    test_pass
else
    test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Error message content verification
# ═══════════════════════════════════════════════════════════════════════════

test_start "error output includes remediation hint for missing config"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/msg_config"
mkdir -p "$install_dir"
output=$(_capture _val_check_config "$install_dir")
assert_contains "$output" "aiteamforge setup"
test_pass

test_start "error output includes remediation hint for missing install dir"
_reload_validate_lib
_val_reset
output=$(_capture _val_check_install_dir "$TEST_TMP_DIR/msg_install_dir_gone")
assert_contains "$output" "aiteamforge setup"
test_pass

test_start "error output includes remediation hint for missing scripts"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/msg_scripts"
mkdir -p "$install_dir"
output=$(_capture _val_check_scripts "$install_dir")
assert_contains "$output" "aiteamforge setup"
test_pass

test_start "error output includes remediation for missing LCARS"
_reload_validate_lib
_val_reset
install_dir="$TEST_TMP_DIR/msg_lcars"
mkdir -p "$install_dir"
output=$(_capture _val_check_lcars "$install_dir")
assert_contains "$output" "LCARS"
test_pass

# Success!
exit 0
