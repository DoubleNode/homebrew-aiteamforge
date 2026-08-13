#!/bin/bash

# test-org-config.sh
# Automated tests for _ensure_org_config() in libexec/installers/install-team.sh
#
# XACA-0254: Covers the four manually-verified scenarios:
#   1. Tty guard fires when /dev/tty is unavailable → rc=1, remediation message
#   2. Env override short-circuits → rc=0, no yaml written
#   3. Pre-existing yaml short-circuits → rc=0, yaml unchanged
#   4. Successful interactive write via expect → rc=0, valid yaml with user values

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_TEAM_SH="$TAP_ROOT/libexec/installers/install-team.sh"

# ─── Extract _ensure_org_config function body from install-team.sh ──────────
# PRE-EXISTING BUG surfaced by the tap-CI manifest-drain fix (XACA-0862): this
# used to be a HARDCODED `sed -n '152,262p'` line range. That range was already
# wrong before XACA-0862 ever touched this file (verified against the
# pre-XACA-0862 baseline: the function lived at lines 419-530 there, not
# 152-262 — the hardcoding had drifted independent of this ticket) and drifted
# further as install-team.sh grew (XACA-0862 alone added net +238 lines to
# it). Extract by MARKER instead, mirroring the awk-based `_extract_fn`
# pattern in test-xaca-0834-connect-script-recovery.sh — the extraction stays
# correct across any future reflow of the file instead of needing a manual
# line-number update every time.
FUNC_TMPFILE="$TEST_TMP_DIR/ensure_org_config_fn.sh"
awk '
  /^_ensure_org_config\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$INSTALL_TEAM_SH" > "$FUNC_TMPFILE"

# Sanity check: bail early if extraction failed (line numbers drifted)
if ! bash -c "source '$FUNC_TMPFILE'" 2>/dev/null; then
    test_start "_ensure_org_config extraction sanity check"
    test_fail "Failed to source extracted function from $FUNC_TMPFILE — line numbers may have drifted in install-team.sh"
    exit 1
fi
if ! grep -q "^_ensure_org_config()" "$FUNC_TMPFILE"; then
    test_start "_ensure_org_config extraction sanity check"
    test_fail "Extracted file does not contain _ensure_org_config() — sed range may be wrong"
    exit 1
fi

# ─── Helper: run function in a sandboxed subshell ───────────────────────────
# Each invocation creates a fresh sandbox HOME so tests never touch real $HOME.
# Usage: run_org_config_sandboxed <sandbox_dir> [env_vars...] [< /dev/null for no-tty]
# Callers run: OUTPUT=$(run_in_sandbox <dir> [VAR=val ...]) [< /dev/null]
# Returns rc via subshell exit code captured with '|| rc=$?'

# ═══════════════════════════════════════════════════════════════════════════
# Scenario 1: /dev/tty unavailable — guard fires, rc=1, remediation shown
# ═══════════════════════════════════════════════════════════════════════════

test_start "Tty guard fires: returns rc=1 when /dev/tty unavailable"
sc1_sandbox="$TEST_TMP_DIR/sc1-no-tty"
mkdir -p "$sc1_sandbox"
sc1_rc=0
sc1_out=$(bash -c "
    source '$FUNC_TMPFILE'
    HOME='$sc1_sandbox' _ensure_org_config
" < /dev/null 2>&1) || sc1_rc=$?
assert_exit_failure "$sc1_rc" "Expected rc=1 when /dev/tty unavailable, got rc=$sc1_rc"
if [ "$TEST_FAILED" = false ]; then test_pass; fi

test_start "Tty guard fires: error message mentions /dev/tty unavailable"
assert_contains "$sc1_out" "/dev/tty is not available"
if [ "$TEST_FAILED" = false ]; then test_pass; fi

test_start "Tty guard fires: remediation option 1 (run interactively) present"
assert_contains "$sc1_out" "Run interactively in a terminal"
if [ "$TEST_FAILED" = false ]; then test_pass; fi

test_start "Tty guard fires: remediation option 2 (pre-populate yaml) present"
assert_contains "$sc1_out" "Pre-populate ~/.aiteamforge/organization.yaml"
if [ "$TEST_FAILED" = false ]; then test_pass; fi

test_start "Tty guard fires: remediation option 3 (AITEAMFORGE_ORG_CONFIG env) present"
assert_contains "$sc1_out" "AITEAMFORGE_ORG_CONFIG"
if [ "$TEST_FAILED" = false ]; then test_pass; fi

test_start "Tty guard fires: no organization.yaml written"
assert_file_not_exists "$sc1_sandbox/.aiteamforge/organization.yaml"
if [ "$TEST_FAILED" = false ]; then test_pass; fi

# ═══════════════════════════════════════════════════════════════════════════
# Scenario 2: AITEAMFORGE_ORG_CONFIG env override — short-circuits, rc=0
# ═══════════════════════════════════════════════════════════════════════════

test_start "Env override short-circuits: returns rc=0"
sc2_sandbox="$TEST_TMP_DIR/sc2-env-override"
mkdir -p "$sc2_sandbox"
sc2_rc=0
sc2_out=$(bash -c "
    source '$FUNC_TMPFILE'
    HOME='$sc2_sandbox' AITEAMFORGE_ORG_CONFIG='/some/external/path.yaml' _ensure_org_config
" 2>&1) || sc2_rc=$?
assert_equal "0" "$sc2_rc" "Expected rc=0 with env override, got rc='$sc2_rc'"
if [ "$TEST_FAILED" = false ]; then test_pass; fi

test_start "Env override short-circuits: no organization.yaml written"
assert_file_not_exists "$sc2_sandbox/.aiteamforge/organization.yaml"
if [ "$TEST_FAILED" = false ]; then test_pass; fi

test_start "Env override short-circuits: no prompts emitted"
# Function returns at the AITEAMFORGE_ORG_CONFIG check before any echo/printf, so stdout+stderr should be empty.
assert_empty "$sc2_out" "Expected no output with env override, got: '$sc2_out'"
if [ "$TEST_FAILED" = false ]; then test_pass; fi

# ═══════════════════════════════════════════════════════════════════════════
# Scenario 3: Pre-existing organization.yaml — short-circuits, file unchanged
# ═══════════════════════════════════════════════════════════════════════════

test_start "Pre-existing yaml short-circuits: returns rc=0"
sc3_sandbox="$TEST_TMP_DIR/sc3-preexisting"
mkdir -p "$sc3_sandbox/.aiteamforge"
cat > "$sc3_sandbox/.aiteamforge/organization.yaml" <<'YAMLEOF'
organization:
  slug: "existing-org"
  name: "Existing Organization"
  domain: "existing.com"
YAMLEOF
sc3_rc=0
sc3_out=$(bash -c "
    source '$FUNC_TMPFILE'
    HOME='$sc3_sandbox' _ensure_org_config
" 2>&1) || sc3_rc=$?
assert_equal "0" "$sc3_rc" "Expected rc=0 with pre-existing yaml, got rc='$sc3_rc'"
if [ "$TEST_FAILED" = false ]; then test_pass; fi

test_start "Pre-existing yaml short-circuits: file content unchanged"
sc3_content=$(cat "$sc3_sandbox/.aiteamforge/organization.yaml")
assert_contains "$sc3_content" "existing-org"
assert_contains "$sc3_content" "Existing Organization"
if [ "$TEST_FAILED" = false ]; then test_pass; fi

test_start "Pre-existing yaml short-circuits: no prompts emitted"
# Function returns at the [[ -f organization.yaml ]] check before any echo/printf, so stdout+stderr should be empty.
assert_empty "$sc3_out" "Expected no output with pre-existing yaml, got: '$sc3_out'"
if [ "$TEST_FAILED" = false ]; then test_pass; fi

# ═══════════════════════════════════════════════════════════════════════════
# Scenario 4: Successful interactive write (expect-driven)
# Only runs when 'expect' is available; skipped otherwise.
# ═══════════════════════════════════════════════════════════════════════════

if command -v expect > /dev/null 2>&1; then
    EXPECT_SCRIPT="$TEST_TMP_DIR/test-org-config-interactive.exp"
    sc4_sandbox="$TEST_TMP_DIR/sc4-interactive"
    mkdir -p "$sc4_sandbox"

    cat > "$EXPECT_SCRIPT" << EXPEOF
#!/usr/bin/expect -f
set timeout 15
set sandbox   [lindex \$argv 0]
set tap_root  [lindex \$argv 1]
set func_file [lindex \$argv 2]

spawn bash -c "
source \"\$func_file\"
export HOME=\"\$sandbox\"
export HOMEBREW_TAP_ROOT=\"\$tap_root\"
_ensure_org_config
echo FINAL_RC:\\\$?
"

expect {
    "Organization slug" { send "autotest-org\\r" }
    timeout { puts "EXPECT_TIMEOUT: waiting for slug prompt"; exit 1 }
}
expect {
    "Organization name" { send "Autotest Organization\\r" }
    timeout { puts "EXPECT_TIMEOUT: waiting for name prompt"; exit 1 }
}
expect {
    "Display short" { send "AutoTest\\r" }
    timeout { puts "EXPECT_TIMEOUT: waiting for short prompt"; exit 1 }
}
expect {
    "Primary domain" { send "autotest.example.com\\r" }
    timeout { puts "EXPECT_TIMEOUT: waiting for domain prompt"; exit 1 }
}
expect {
    "FINAL_RC:0" { puts "EXPECT_RC:0" }
    timeout      { puts "EXPECT_TIMEOUT: waiting for FINAL_RC"; exit 1 }
}
expect eof
EXPEOF

    test_start "Interactive write: expect drives all prompts and returns rc=0"
    sc4_out=$(expect "$EXPECT_SCRIPT" "$sc4_sandbox" "$TAP_ROOT" "$FUNC_TMPFILE" 2>&1) || true
    if echo "$sc4_out" | grep -q "EXPECT_RC:0"; then
        test_pass
    else
        test_fail "expect run did not produce EXPECT_RC:0 — output: $sc4_out"
    fi

    test_start "Interactive write: organization.yaml is created"
    assert_file_exists "$sc4_sandbox/.aiteamforge/organization.yaml"
    if [ "$TEST_FAILED" = false ]; then test_pass; fi

    test_start "Interactive write: yaml contains user-provided slug"
    if [ -f "$sc4_sandbox/.aiteamforge/organization.yaml" ]; then
        sc4_yaml=$(cat "$sc4_sandbox/.aiteamforge/organization.yaml")
        assert_contains "$sc4_yaml" "autotest-org"
        if [ "$TEST_FAILED" = false ]; then test_pass; fi
    else
        test_fail "organization.yaml not present — cannot check slug"
    fi

    test_start "Interactive write: yaml contains user-provided name"
    if [ -f "$sc4_sandbox/.aiteamforge/organization.yaml" ]; then
        assert_contains "$sc4_yaml" "Autotest Organization"
        if [ "$TEST_FAILED" = false ]; then test_pass; fi
    else
        test_fail "organization.yaml not present — cannot check name"
    fi

    test_start "Interactive write: yaml contains user-provided domain"
    if [ -f "$sc4_sandbox/.aiteamforge/organization.yaml" ]; then
        assert_contains "$sc4_yaml" "autotest.example.com"
        if [ "$TEST_FAILED" = false ]; then test_pass; fi
    else
        test_fail "organization.yaml not present — cannot check domain"
    fi

    test_start "Interactive write: yaml contains no example-org placeholder"
    if [ -f "$sc4_sandbox/.aiteamforge/organization.yaml" ]; then
        # Only check the slug: line specifically — the comment section may still
        # reference example-org as documentation context in the template file.
        sc4_slug_line=$(grep 'slug:' "$sc4_sandbox/.aiteamforge/organization.yaml" | head -1)
        assert_not_contains "$sc4_slug_line" "example-org"
        if [ "$TEST_FAILED" = false ]; then test_pass; fi
    else
        test_fail "organization.yaml not present — cannot check placeholder"
    fi
else
    # expect not available — log as informational (counted as pass with note)
    test_start "Interactive write: [skipped — expect not available on this host]"
    test_pass
fi

exit 0
