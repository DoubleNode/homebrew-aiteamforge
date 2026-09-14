#!/bin/bash
# test-xaca-1211-setup-mandatory-only.sh
#
# XACA-1211: `aiteamforge setup` could not provision a machine whose only team
# is the mandatory Space Dock. Two gaps in bin/aiteamforge-setup.sh Step 2:
#
#   1. The "No teams selected. At least one team is required." guard ran BEFORE
#      _atf_apply_mandatory_teams, so a mandatory team never counted toward it.
#   2. There was no way to ask for zero OPTIONAL teams non-interactively:
#      `${AITEAMFORGE_TEAMS:-all}` turns an empty value into `all`, and `none`
#      was rejected as an invalid choice.
#
# MEASURED on M1Mini with v0.20.11:
#   AITEAMFORGE_TEAMS=none aiteamforge setup --dry-run --non-interactive
#   -> "No teams selected. At least one team is required."  (exit 1)
#
# Method: extract the PRODUCTION Step-2 block (from the non-interactive
# team_choices read through the "Selected teams:" echo) and the real
# _atf_apply_mandatory_teams() function, then run them in a child bash with a
# stubbed team list and a stubbed atf_mandatory_teams. If the extracted block
# does not itself call _atf_apply_mandatory_teams (the pre-fix layout), the
# harness calls it afterwards, exactly as the real script continues — so the
# pre-fix file is exercised faithfully and goes red.
#
# Pre-fix proof: SETUP_SH=/path/to/old/aiteamforge-setup.sh bash <this file>
#
# Nothing is installed; no real $HOME path is read or written.

_STANDALONE=false
if ! type test_pass >/dev/null 2>&1; then
    _STANDALONE=true
    if [ -z "${TEST_TMP_DIR:-}" ]; then
        TEST_TMP_DIR=$(mktemp -d -t aiteamforge-xaca1211-test.XXXXXX)
        trap 'rm -rf "$TEST_TMP_DIR"' EXIT INT TERM
    else
        mkdir -p "$TEST_TMP_DIR" || { echo "cannot create TEST_TMP_DIR=$TEST_TMP_DIR" >&2; exit 1; }
    fi
    _PASS_COUNT=0
    _FAIL_COUNT=0
    test_start() { _CURRENT_TEST="$1"; }
    test_pass() {
        _PASS_COUNT=$(( _PASS_COUNT + 1 ))
        printf "PASS: %s\n" "$_CURRENT_TEST"
    }
    test_fail() {
        _FAIL_COUNT=$(( _FAIL_COUNT + 1 ))
        printf "FAIL: %s — %s\n" "$_CURRENT_TEST" "$1" >&2
    }
fi

_ASSERTIONS=0
check() {
    _ASSERTIONS=$(( _ASSERTIONS + 1 ))
    test_start "$1"
    if [ "$2" -eq 0 ]; then test_pass; else test_fail "$3"; fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP_SH="${SETUP_SH:-$TAP_ROOT/bin/aiteamforge-setup.sh}"
BASH_BIN="${BASH:-/bin/bash}"

printf "=== XACA-1211: setup with only mandatory teams (%s) ===\n" "$SETUP_SH"

# ── Extraction ───────────────────────────────────────────────────────────────
BLOCK="$TEST_TMP_DIR/step2-block.sh"
FN="$TEST_TMP_DIR/apply-fn.sh"
# Anchor on the Step-2 team_choices assignment itself, then include the
# `if [ "$MODE" = "non-interactive" ]` line immediately above it. The `if` line
# alone is NOT unique — the machine-name step uses the same test earlier in the
# file, and matching that one sources a truncated, syntactically broken block.
awk '
    !p && /team_choices="\$\{AITEAMFORGE_TEAMS:-all\}"/ { p=1; print prev }
    p { print }
    p && /Selected teams: / { exit }
    { prev=$0 }
' "$SETUP_SH" > "$BLOCK"
head -1 "$BLOCK" | grep -q '^if \[ "\$MODE" = "non-interactive" \]; then$'; _e0_head=$?
awk '
    /^_atf_apply_mandatory_teams\(\) \{$/ { p=1 }
    p { print }
    p && /^\}$/ { exit }
' "$SETUP_SH" > "$FN"

[ "$_e0_head" -eq 0 ] && grep -q 'team_choices=' "$BLOCK" && grep -q 'Selected teams: ' "$BLOCK" \
    && grep -q 'At least one team is required' "$BLOCK" && "$BASH_BIN" -n "$BLOCK"; r=$?
check "E0: extracted the Step-2 selection block ($(grep -c . "$BLOCK") lines)" "$r" "anchors missing — block empty or truncated"
grep -q '^_atf_apply_mandatory_teams() {' "$FN" && grep -q 'SELECTED_TEAMS+=' "$FN"; r=$?
check "E1: extracted the real _atf_apply_mandatory_teams() ($(grep -c . "$FN") lines)" "$r" "function not found"

# run_step2 <AITEAMFORGE_TEAMS value or __UNSET__> <mandatory ids, space-separated or "">
run_step2() {
    local teams="$1" mandatory="$2"
    "$BASH_BIN" -c '
        BLOCK="$1"; FN="$2"; TEAMS="$3"; MAND="$4"
        RED=""; GREEN=""; YELLOW=""; NC=""
        MODE="non-interactive"
        if [ "$TEAMS" != "__UNSET__" ]; then export AITEAMFORGE_TEAMS="$TEAMS"; else unset AITEAMFORGE_TEAMS; fi
        AVAILABLE_TEAMS=(academy command freelance)
        SELECTED_TEAMS=()
        atf_mandatory_teams() { for m in $MAND; do printf "%s\n" "$m"; done; }
        . "$FN"
        . "$BLOCK"
        if ! grep -q "^_atf_apply_mandatory_teams$" "$BLOCK"; then
            _atf_apply_mandatory_teams >/dev/null
        fi
        printf "SELECTED=[%s]\n" "${SELECTED_TEAMS[*]}"
    ' _ "$BLOCK" "$FN" "$teams" "$mandatory" >"$TEST_TMP_DIR/run.out" 2>&1
    RUN_RC=$?
    RUN_SEL=$(sed -n 's/^SELECTED=\[\(.*\)\]$/\1/p' "$TEST_TMP_DIR/run.out")
    RUN_OUT=$(cat "$TEST_TMP_DIR/run.out")
}

# ── A: the reported case ─────────────────────────────────────────────────────
run_step2 none "spacedock"
[ "$RUN_RC" -eq 0 ] && [ "$RUN_SEL" = "spacedock" ]; r=$?
check "A1: AITEAMFORGE_TEAMS=none + mandatory spacedock → selects exactly spacedock, exit 0" "$r" "rc=$RUN_RC selected=[$RUN_SEL] out=[$RUN_OUT]"
printf '%s' "$RUN_OUT" | grep -q 'Skipping invalid choice'; r=$?
[ "$r" -ne 0 ]; r=$?
check "A2: 'none' is not reported as an invalid choice" "$r" "out=[$RUN_OUT]"

# ── B: guard still fires with no mandatory team ──────────────────────────────
run_step2 none ""
[ "$RUN_RC" -ne 0 ] && printf '%s' "$RUN_OUT" | grep -q 'At least one team is required'; r=$?
check "B1: none + registry declaring no mandatory team → still exit 1 with the guard message" "$r" "rc=$RUN_RC out=[$RUN_OUT]"

# ── C: existing selections unchanged ─────────────────────────────────────────
run_step2 all "spacedock"
[ "$RUN_RC" -eq 0 ] && [ "$RUN_SEL" = "academy command freelance spacedock" ]; r=$?
check "C1: all + mandatory → every available team plus spacedock" "$r" "rc=$RUN_RC selected=[$RUN_SEL]"

run_step2 __UNSET__ "spacedock"
[ "$RUN_RC" -eq 0 ] && [ "$RUN_SEL" = "academy command freelance spacedock" ]; r=$?
check "C2: AITEAMFORGE_TEAMS unset still means all (no behaviour change for existing automation)" "$r" "rc=$RUN_RC selected=[$RUN_SEL]"

run_step2 "1 3" "spacedock"
[ "$RUN_RC" -eq 0 ] && [ "$RUN_SEL" = "academy freelance spacedock" ]; r=$?
check "C3: numeric '1 3' + mandatory → academy freelance spacedock" "$r" "rc=$RUN_RC selected=[$RUN_SEL]"

run_step2 "1" ""
[ "$RUN_RC" -eq 0 ] && [ "$RUN_SEL" = "academy" ]; r=$?
check "C4: numeric '1' with no mandatory team → academy only" "$r" "rc=$RUN_RC selected=[$RUN_SEL]"

run_step2 "1" "academy"
[ "$RUN_RC" -eq 0 ] && [ "$RUN_SEL" = "academy" ]; r=$?
check "C5: a mandatory team already selected is not duplicated" "$r" "rc=$RUN_RC selected=[$RUN_SEL]"

# ── G: assertion-count pin (counted before G1) ───────────────────────────────
[ "$_ASSERTIONS" -eq 10 ]; r=$?
check "G1: assertion-count pin (10 expected, $_ASSERTIONS ran)" "$r" "assertion count drifted"

if [ "$_STANDALONE" = true ]; then
    printf "\nResults: %d passed, %d failed\n" "$_PASS_COUNT" "$_FAIL_COUNT"
    [ "$_FAIL_COUNT" -eq 0 ] || exit 1
    [ "$_PASS_COUNT" -gt 0 ] || { echo "no assertions passed — refusing to report success" >&2; exit 1; }
fi
