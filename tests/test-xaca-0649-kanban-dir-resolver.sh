#!/bin/bash
# test-xaca-0649-kanban-dir-resolver.sh
# Regression + parity tests for XACA-0649: _kb_get_kanban_dir() must consult
# team-paths.json BEFORE falling back to $AITEAMFORGE_DIR/kanban, so parametric
# teams like legal-coparenting are not silently mis-routed to the academy's
# central kanban directory.
#
# BUG THAT WAS FIXED:
#   Old code contained an early-exit guard:
#     if [[ -d "${_atf_dir}/kanban" ]]; then echo "${_atf_dir}/kanban"; return 0; fi
#   This fired for ALL teams (including legal-coparenting) when the academy kanban
#   dir already existed on disk, completely bypassing the correct case arms.
#   On any tap-installed consumer the academy board always creates that directory,
#   so kb-quarantine-stub legal-coparenting would say "no canonical board found"
#   because it looked in the wrong place.
#
# THREE COPIES OF THIS FUNCTION MUST ALL PASS (XACA-0649 anti-drift, k501):
#   1. kanban-aliases.sh           — fresh-install source (Cases 1-7)
#   2. kanban-helpers.template.sh  — upgrade-path source (Cases 8-14 parity)
#
# Designed to run standalone OR via test-runner.sh.
# Exit 0 = all cases pass.  Exit 1 = at least one case failed.
#
# Requires: bash, python3 (for the Strategy 1 registry lookup inside the function)

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ALIASES_PATH="$TAP_ROOT/share/templates/aliases/kanban-aliases.sh"
TEMPLATE_PATH="$TAP_ROOT/share/templates/kanban/kanban-helpers.template.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Minimal self-contained test framework
# ─────────────────────────────────────────────────────────────────────────────
_PASS=0
_FAIL=0
_CURRENT_TEST=""

if ! declare -F test_start &>/dev/null; then
    test_start() { _CURRENT_TEST="$1"; }
fi
if ! declare -F test_pass &>/dev/null; then
    test_pass() {
        _PASS=$((_PASS + 1))
        printf "  PASS: %s\n" "$_CURRENT_TEST"
    }
fi
if ! declare -F test_fail &>/dev/null; then
    test_fail() {
        _FAIL=$((_FAIL + 1))
        printf "  FAIL: %s — %s\n" "$_CURRENT_TEST" "${1:-}" >&2
    }
fi

if [ ! -f "$ALIASES_PATH" ]; then
    echo "FATAL: Shipped aliases file not found at: $ALIASES_PATH" >&2
    exit 1
fi
if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "FATAL: kanban-helpers.template.sh not found at: $TEMPLATE_PATH" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox helpers
# ─────────────────────────────────────────────────────────────────────────────
_TEST_TMP=""
_PROCESSED_ALIASES=""   # placeholder-substituted copy of kanban-aliases.sh
_PROCESSED_TEMPLATE=""  # placeholder-substituted copy of kanban-helpers.template.sh
_STDOUT_FILE="/tmp/xaca0649-resolver-stdout.$$"
_STDERR_FILE="/tmp/xaca0649-resolver-stderr.$$"

_setup_sandbox() {
    _TEST_TMP=$(mktemp -d -t xaca0649-resolver.XXXXXX)
    # Academy's central kanban dir (exists on all consumers — THIS is what the bug
    # wrongly returned for every team)
    mkdir -p "$_TEST_TMP/aiteamforge/kanban"
    # Canonical dirs for parametric teams
    mkdir -p "$_TEST_TMP/legal/coparenting/kanban"
    mkdir -p "$_TEST_TMP/medical/general/kanban"
    mkdir -p "$_TEST_TMP/finance/personal/kanban"

    # The template file uses {{AITEAMFORGE_DIR}} as a placeholder that gets
    # substituted at install time.  In the raw template, bash parses the default
    # expression ${AITEAMFORGE_DIR:-{{AITEAMFORGE_DIR}}} in a way that appends
    # stray "}}" to _atf_dir even when AITEAMFORGE_DIR is set.  Pre-substitute
    # the placeholder so the tests run against the same form a real install would.
    local atf_dir_for_template="$_TEST_TMP/aiteamforge"
    ATF_DIR_FOR_TEMPLATE="$atf_dir_for_template"

    _PROCESSED_ALIASES="$_TEST_TMP/kanban-aliases-substituted.sh"
    sed "s|{{AITEAMFORGE_DIR}}|${atf_dir_for_template}|g; \
         s|{{SHARED_DEV_ROOT}}|${_TEST_TMP}/shared|g; \
         s|{{ORG_NAME}}|TestOrg|g" \
        "$ALIASES_PATH" > "$_PROCESSED_ALIASES"
    chmod +x "$_PROCESSED_ALIASES"

    # Also substitute the kanban-helpers.template.sh for parity tests.
    _PROCESSED_TEMPLATE="$_TEST_TMP/kanban-helpers-template-substituted.sh"
    sed "s|{{AITEAMFORGE_DIR}}|${atf_dir_for_template}|g; \
         s|{{SHARED_DEV_ROOT}}|${_TEST_TMP}/shared|g; \
         s|{{ORG_NAME}}|TestOrg|g" \
        "$TEMPLATE_PATH" > "$_PROCESSED_TEMPLATE"
    chmod +x "$_PROCESSED_TEMPLATE"
}

_teardown_sandbox() {
    [ -n "$_TEST_TMP" ] && [ -d "$_TEST_TMP" ] && rm -rf "$_TEST_TMP"
    _TEST_TMP=""
    _PROCESSED_ALIASES=""
    _PROCESSED_TEMPLATE=""
}

# Write a minimal team-paths.json to the sandbox.
# Usage: _write_registry [json-object-for-teams-field]
#   If no arg given, writes an empty registry (no teams registered).
_write_registry() {
    local teams_json="${1:-{}}"
    mkdir -p "$_TEST_TMP/.aiteamforge"
    printf '{"schema_version":1,"teams":%s}\n' "$teams_json" \
        > "$_TEST_TMP/.aiteamforge/team-paths.json"
}

# Run a command inside a sandboxed bash subshell that has sourced the
# SUBSTITUTED kanban-aliases.sh (placeholders already resolved).
# The AITEAMFORGE_CONFIG env-var points the resolver at the sandbox's team-paths.json.
# Usage: _run <home_dir> <atf_dir> <command...>
_run() {
    local home_dir="$1" atf_dir="$2"
    shift 2
    local _quoted_cmd
    _quoted_cmd=$(printf '%q ' "$@")
    env -i \
        HOME="$home_dir" \
        PATH="$PATH" \
        TERM="${TERM:-dumb}" \
        AITEAMFORGE_CONFIG="$home_dir/.aiteamforge/team-paths.json" \
        bash --noprofile --norc -c "
            source '$_PROCESSED_ALIASES' 2>/dev/null
            AITEAMFORGE_DIR='$atf_dir'
            $_quoted_cmd
        " >"$_STDOUT_FILE" 2>"$_STDERR_FILE"
}

# Same as _run but sources kanban-helpers.template.sh (the upgrade-path copy).
# Used by parity tests (Cases 8-14) to verify the template file exhibits the
# same correct behaviour as kanban-aliases.sh.
_run_template() {
    local home_dir="$1" atf_dir="$2"
    shift 2
    local _quoted_cmd
    _quoted_cmd=$(printf '%q ' "$@")
    env -i \
        HOME="$home_dir" \
        PATH="$PATH" \
        TERM="${TERM:-dumb}" \
        AITEAMFORGE_CONFIG="$home_dir/.aiteamforge/team-paths.json" \
        bash --noprofile --norc -c "
            source '$_PROCESSED_TEMPLATE' 2>/dev/null
            AITEAMFORGE_DIR='$atf_dir'
            $_quoted_cmd
        " >"$_STDOUT_FILE" 2>"$_STDERR_FILE"
}

# The shipped kanban-aliases.sh prints "Kanban helpers loaded (team: ...)" to
# stdout when sourced.  Extract only the last line (the actual function output).
_stdout() { tail -1 "$_STDOUT_FILE" 2>/dev/null; }
_stderr() { cat "$_STDERR_FILE" 2>/dev/null; }

_cleanup() {
    rm -f "$_STDOUT_FILE" "$_STDERR_FILE"
    _teardown_sandbox
    # Scrub any placeholder dirs bash brace-expansion leaks to cwd
    local d
    for d in "$PWD"/'{{AITEAMFORGE_DIR'*; do
        [ -d "$d" ] || continue
        find "$d" -depth -delete 2>/dev/null
    done
}
trap '_cleanup' EXIT INT TERM

# ─────────────────────────────────────────────────────────────────────────────
# Setup
# ─────────────────────────────────────────────────────────────────────────────
_setup_sandbox

# ATF_DIR is the directory that CAUSED the bug (it exists — all consumers have
# an academy board so $AITEAMFORGE_DIR/kanban always exists on a real install).
ATF_DIR="$_TEST_TMP/aiteamforge"
HOME_DIR="$_TEST_TMP"

# ─────────────────────────────────────────────────────────────────────────────
# CASE 1 (BUG REGRESSION):
#   With the old code, once $AITEAMFORGE_DIR/kanban existed on disk the function
#   returned it for every team — including legal-coparenting — without consulting
#   the registry or case arms.  The fixed code consults the registry first and
#   falls to the case arm if not registered, so this must return the coparenting
#   path, not the academy path.
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case 1 (regression): legal-coparenting NOT routed to \$AITEAMFORGE_DIR/kanban when that dir exists"
_write_registry '{}'   # empty registry — forces case-arm path
_run "$HOME_DIR" "$ATF_DIR" _kb_get_kanban_dir legal-coparenting
rc=$?
got="$(_stdout)"
expected_dir="$HOME_DIR/legal/coparenting/kanban"
if [ "$rc" -ne 0 ]; then
    test_fail "_kb_get_kanban_dir exited $rc"
elif [ "$got" = "$ATF_DIR/kanban" ]; then
    test_fail "BUG REGRESSED: returned \$AITEAMFORGE_DIR/kanban ('$got') — parametric team routed to academy dir"
elif [ "$got" != "$expected_dir" ]; then
    test_fail "Unexpected path: got '$got', expected '$expected_dir'"
else
    test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 2: Registry-first — registered kanban_dir wins over case arm
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case 2: registered kanban_dir from team-paths.json is returned for legal-coparenting"
REGISTERED_DIR="$HOME_DIR/legal/coparenting/kanban"   # canonical registered path
_write_registry "$(printf '{"legal-coparenting":{"kanban_dir":"%s","team_code":"LCP"}}' "$REGISTERED_DIR")"
# The registered dir must exist for Strategy 1 to pass its -d guard
mkdir -p "$REGISTERED_DIR"
_run "$HOME_DIR" "$ATF_DIR" _kb_get_kanban_dir legal-coparenting
rc=$?
got="$(_stdout)"
if [ "$rc" -ne 0 ]; then
    test_fail "_kb_get_kanban_dir exited $rc"
elif [ "$got" != "$REGISTERED_DIR" ]; then
    test_fail "Expected registered dir '$REGISTERED_DIR', got '$got'"
else
    test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 3: No registry → case arm provides correct parametric path
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case 3: no registry file → legal-coparenting uses case-arm path \$HOME/legal/coparenting/kanban"
rm -f "$HOME_DIR/.aiteamforge/team-paths.json"
_run "$HOME_DIR" "$ATF_DIR" _kb_get_kanban_dir legal-coparenting
rc=$?
got="$(_stdout)"
expected_dir="$HOME_DIR/legal/coparenting/kanban"
if [ "$rc" -ne 0 ]; then
    test_fail "_kb_get_kanban_dir exited $rc"
elif [ "$got" != "$expected_dir" ]; then
    test_fail "Expected '$expected_dir', got '$got'"
else
    test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 4: Registry exists but legal-coparenting not registered → case arm used
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case 4: registry present but team not in it → case arm path returned"
_write_registry '{"academy":{"kanban_dir":"/tmp/unrelated","team_code":"ACA"}}'
_run "$HOME_DIR" "$ATF_DIR" _kb_get_kanban_dir legal-coparenting
rc=$?
got="$(_stdout)"
expected_dir="$HOME_DIR/legal/coparenting/kanban"
if [ "$rc" -ne 0 ]; then
    test_fail "_kb_get_kanban_dir exited $rc"
elif [ "$got" != "$expected_dir" ]; then
    test_fail "Expected '$expected_dir', got '$got'"
else
    test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 5: medical-general — verify another parametric family is also correct
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case 5: medical-general not mis-routed to \$AITEAMFORGE_DIR/kanban"
_write_registry '{}'
_run "$HOME_DIR" "$ATF_DIR" _kb_get_kanban_dir medical-general
rc=$?
got="$(_stdout)"
if [ "$got" = "$ATF_DIR/kanban" ]; then
    test_fail "BUG: medical-general returned academy kanban dir '$got'"
elif [ "$rc" -ne 0 ]; then
    test_fail "_kb_get_kanban_dir exited $rc"
else
    test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 6: Truly unknown team gets the $AITEAMFORGE_DIR/kanban fallback (Strategy 3)
#   This is correct behaviour — unknown teams should fall back to the central dir.
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case 6: unknown team falls back to \$AITEAMFORGE_DIR/kanban (Strategy 3)"
_write_registry '{}'
_run "$HOME_DIR" "$ATF_DIR" _kb_get_kanban_dir totally-unknown-team
rc=$?
got="$(_stdout)"
if [ "$rc" -ne 0 ]; then
    test_fail "_kb_get_kanban_dir exited $rc"
elif [ "$got" != "$ATF_DIR/kanban" ]; then
    test_fail "Expected '$ATF_DIR/kanban' for unknown team, got '$got'"
else
    test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 7: academy still resolves to $AITEAMFORGE_DIR/kanban (no regression)
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case 7: academy still resolves to \$AITEAMFORGE_DIR/kanban"
_write_registry '{}'
_run "$HOME_DIR" "$ATF_DIR" _kb_get_kanban_dir academy
rc=$?
got="$(_stdout)"
if [ "$rc" -ne 0 ]; then
    test_fail "_kb_get_kanban_dir exited $rc"
elif [ "$got" != "$ATF_DIR/kanban" ]; then
    test_fail "Expected '$ATF_DIR/kanban' for academy, got '$got'"
else
    test_pass
fi

# =============================================================================
# PARITY TESTS: kanban-helpers.template.sh (upgrade-path copy, Cases 8-14)
#
# XACA-0649 anti-drift (k501): the same three-tier fix must be present in ALL
# three copies of _kb_get_kanban_dir.  These cases mirror Cases 1-7 above but
# source kanban-helpers.template.sh instead of kanban-aliases.sh.  A future
# edit to one file that is not mirrored in the other will fail here.
# =============================================================================
echo ""
echo "── Parity tests: kanban-helpers.template.sh (upgrade-path copy) ─────────"

# CASE 8 (parity of Case 1): legal-coparenting NOT routed to $AITEAMFORGE_DIR/kanban
test_start "Case 8 (parity/template): legal-coparenting NOT mis-routed to \$AITEAMFORGE_DIR/kanban"
_write_registry '{}'
_run_template "$HOME_DIR" "$ATF_DIR" _kb_get_kanban_dir legal-coparenting
rc=$?
got="$(_stdout)"
expected_dir="$HOME_DIR/legal/coparenting/kanban"
if [ "$rc" -ne 0 ]; then
    test_fail "_kb_get_kanban_dir (template) exited $rc"
elif [ "$got" = "$ATF_DIR/kanban" ]; then
    test_fail "BUG REGRESSED in template: returned \$AITEAMFORGE_DIR/kanban ('$got') — upgrade path is broken"
elif [ "$got" != "$expected_dir" ]; then
    test_fail "Unexpected path: got '$got', expected '$expected_dir'"
else
    test_pass
fi

# CASE 9 (parity of Case 2): registry-first wins for legal-coparenting
test_start "Case 9 (parity/template): registered kanban_dir from team-paths.json returned for legal-coparenting"
REGISTERED_DIR="$HOME_DIR/legal/coparenting/kanban"
_write_registry "$(printf '{"legal-coparenting":{"kanban_dir":"%s","team_code":"LCP"}}' "$REGISTERED_DIR")"
mkdir -p "$REGISTERED_DIR"
_run_template "$HOME_DIR" "$ATF_DIR" _kb_get_kanban_dir legal-coparenting
rc=$?
got="$(_stdout)"
if [ "$rc" -ne 0 ]; then
    test_fail "_kb_get_kanban_dir (template) exited $rc"
elif [ "$got" != "$REGISTERED_DIR" ]; then
    test_fail "Expected registered dir '$REGISTERED_DIR', got '$got'"
else
    test_pass
fi

# CASE 10 (parity of Case 3): no registry → case-arm path for legal-coparenting
test_start "Case 10 (parity/template): no registry → legal-coparenting uses case-arm \$HOME/legal/coparenting/kanban"
rm -f "$HOME_DIR/.aiteamforge/team-paths.json"
_run_template "$HOME_DIR" "$ATF_DIR" _kb_get_kanban_dir legal-coparenting
rc=$?
got="$(_stdout)"
expected_dir="$HOME_DIR/legal/coparenting/kanban"
if [ "$rc" -ne 0 ]; then
    test_fail "_kb_get_kanban_dir (template) exited $rc"
elif [ "$got" != "$expected_dir" ]; then
    test_fail "Expected '$expected_dir', got '$got'"
else
    test_pass
fi

# CASE 11 (parity of Case 4): registry present but team not in it → case arm
test_start "Case 11 (parity/template): registry present but team absent → case-arm path returned"
_write_registry '{"academy":{"kanban_dir":"/tmp/unrelated","team_code":"ACA"}}'
_run_template "$HOME_DIR" "$ATF_DIR" _kb_get_kanban_dir legal-coparenting
rc=$?
got="$(_stdout)"
expected_dir="$HOME_DIR/legal/coparenting/kanban"
if [ "$rc" -ne 0 ]; then
    test_fail "_kb_get_kanban_dir (template) exited $rc"
elif [ "$got" != "$expected_dir" ]; then
    test_fail "Expected '$expected_dir', got '$got'"
else
    test_pass
fi

# CASE 12 (parity of Case 5): medical-general not mis-routed
test_start "Case 12 (parity/template): medical-general not mis-routed to \$AITEAMFORGE_DIR/kanban"
_write_registry '{}'
_run_template "$HOME_DIR" "$ATF_DIR" _kb_get_kanban_dir medical-general
rc=$?
got="$(_stdout)"
if [ "$got" = "$ATF_DIR/kanban" ]; then
    test_fail "BUG in template: medical-general returned academy kanban dir '$got'"
elif [ "$rc" -ne 0 ]; then
    test_fail "_kb_get_kanban_dir (template) exited $rc"
else
    test_pass
fi

# CASE 13 (parity of Case 6): unknown team falls back to $AITEAMFORGE_DIR/kanban
test_start "Case 13 (parity/template): unknown team falls back to \$AITEAMFORGE_DIR/kanban (Strategy 3)"
_write_registry '{}'
_run_template "$HOME_DIR" "$ATF_DIR" _kb_get_kanban_dir totally-unknown-team
rc=$?
got="$(_stdout)"
if [ "$rc" -ne 0 ]; then
    test_fail "_kb_get_kanban_dir (template) exited $rc"
elif [ "$got" != "$ATF_DIR/kanban" ]; then
    test_fail "Expected '$ATF_DIR/kanban' for unknown team, got '$got'"
else
    test_pass
fi

# CASE 14 (parity of Case 7): academy still resolves to $AITEAMFORGE_DIR/kanban
test_start "Case 14 (parity/template): academy still resolves to \$AITEAMFORGE_DIR/kanban"
_write_registry '{}'
_run_template "$HOME_DIR" "$ATF_DIR" _kb_get_kanban_dir academy
rc=$?
got="$(_stdout)"
if [ "$rc" -ne 0 ]; then
    test_fail "_kb_get_kanban_dir (template) exited $rc"
elif [ "$got" != "$ATF_DIR/kanban" ]; then
    test_fail "Expected '$ATF_DIR/kanban' for academy, got '$got'"
else
    test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# Final summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $_PASS passed, $_FAIL failed"
[ "$_FAIL" -eq 0 ] && exit 0 || exit 1
