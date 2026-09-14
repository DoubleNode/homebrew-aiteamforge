#!/bin/bash
# test-xaca-1212-setup-missing-avatars.sh
#
# XACA-1212: `aiteamforge setup` runs under `set -eo pipefail`. Its persona/logo
# copy loop copied `share/personas/<team>/avatars/*.png` (and logos) with an
# unguarded glob and stderr discarded. For a team with no PNGs the glob does not
# expand, the copy exits 1, and set -e ABORTED THE WHOLE INSTALLER with no
# message. Space Dock ships no avatars and is mandatory (XACA-1070), so every
# fresh setup since v0.20.10 died there.
#
# MEASURED on M1Mini, v0.20.12: setup exited 1 immediately after
# "Skills (Kanban Manager, git-worktree, Project Planner)".
#
# Method: extract the PRODUCTION loop (from `_personas_copied=0` through the
# `[ $_logos_copied -gt 0 ]` summary line — NOT the "Terminal logos (" text,
# which also appears in a comment inside the loop and truncates the extraction) and run it under `set -eo pipefail` against a
# fixture AITEAMFORGE_HOME with three teams:
#   noassets    — agents only, no avatars/ dir contents, no terminals/ dir
#   hasassets   — agents, avatars, logos
#   emptylogos  — agents, avatars, and an EMPTY terminals/<team>/logos/ dir
#   emptypersonas — personas dir with EMPTY agents/ and avatars/ (XACA-1212-011)
# The loop must complete, hasassets' files must land in both destinations, and
# the "copied" counters must count only teams where a copy actually succeeded
# (personas=3: noassets, hasassets, emptylogos; logos=1: hasassets).
#
# Pre-fix proof: SETUP_SH=/path/to/old/aiteamforge-setup.sh bash <this file>
# Nothing is installed; everything lives under TEST_TMP_DIR.

_STANDALONE=false
if ! type test_pass >/dev/null 2>&1; then
    _STANDALONE=true
    if [ -z "${TEST_TMP_DIR:-}" ]; then
        TEST_TMP_DIR=$(mktemp -d -t aiteamforge-xaca1212-test.XXXXXX)
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

printf "=== XACA-1212: setup copy loop with missing avatars/logos (%s) ===\n" "$SETUP_SH"

# ── Extraction ───────────────────────────────────────────────────────────────
LOOP="$TEST_TMP_DIR/copy-loop.sh"
awk '
    /^_personas_copied=0$/ { p=1 }
    p { print }
    p && /^\[ \$_logos_copied -gt 0 \]/ { exit }
' "$SETUP_SH" > "$LOOP"
grep -q '^for team_id in "\${SELECTED_TEAMS\[@\]}"; do$' "$LOOP" \
    && grep -q 'share/personas/\${team_id}/avatars/' "$LOOP" \
    && grep -q '^\[ \$_logos_copied -gt 0 \]' "$LOOP" && "$BASH_BIN" -n "$LOOP"; r=$?
check "E0: extracted the production persona/logo copy loop ($(grep -c . "$LOOP") lines)" "$r" "anchors missing — loop empty or truncated"

# ── Fixture ──────────────────────────────────────────────────────────────────
H="$TEST_TMP_DIR/home-share"
I="$TEST_TMP_DIR/install"
mkdir -p "$H/share/personas/noassets/agents" \
         "$H/share/personas/hasassets/agents" "$H/share/personas/hasassets/avatars" \
         "$H/share/terminals/hasassets/logos" \
         "$H/share/personas/emptylogos/agents" "$H/share/personas/emptylogos/avatars" \
         "$H/share/terminals/emptylogos/logos" \
         "$H/share/personas/emptypersonas/agents" "$H/share/personas/emptypersonas/avatars" "$I"
printf 'x\n' > "$H/share/personas/noassets/agents/noassets_a.md"
printf 'x\n' > "$H/share/personas/hasassets/agents/hasassets_a.md"
printf 'png\n' > "$H/share/personas/hasassets/avatars/hasassets_a_avatar.png"
printf 'png\n' > "$H/share/terminals/hasassets/logos/hasassets_logo.png"
printf 'x\n' > "$H/share/personas/emptylogos/agents/emptylogos_a.md"
printf 'png\n' > "$H/share/personas/emptylogos/avatars/emptylogos_a_avatar.png"

"$BASH_BIN" -c '
    set -eo pipefail
    AITEAMFORGE_HOME="$1"; INSTALL_DIR="$2"; INSTALL_PROFILE=full
    GREEN=""; NC=""
    SELECTED_TEAMS=(noassets hasassets emptylogos emptypersonas)
    . "$3"
    echo "LOOP_COMPLETED personas=$_personas_copied logos=$_logos_copied"
' _ "$H" "$I" "$LOOP" > "$TEST_TMP_DIR/run.out" 2>&1
RC=$?
OUT=$(cat "$TEST_TMP_DIR/run.out")

# ── A: the loop survives teams without assets ────────────────────────────────
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'LOOP_COMPLETED'; r=$?
check "A1: loop completes under set -eo pipefail with a team lacking avatars and an empty logos dir" "$r" "rc=$RC out=[$OUT]"
printf '%s' "$OUT" | grep -q 'LOOP_COMPLETED personas=3 logos=1'; r=$?
check "A2: counters count only teams where a copy succeeded (personas=3, logos=1; empty dirs not counted)" "$r" "out=[$OUT]"

# ── B: teams with assets still get them ──────────────────────────────────────
[ -f "$I/hasassets/personas/avatars/hasassets_a_avatar.png" ] && [ -f "$I/avatars/hasassets_a_avatar.png" ]; r=$?
check "B1: hasassets avatar copied to per-team dir AND flat avatars pool" "$r" "missing avatar copies under $I"
[ -f "$I/hasassets/terminals/logos/hasassets_logo.png" ] && [ -f "$I/avatars/hasassets_logo.png" ]; r=$?
check "B2: hasassets logo copied to per-team dir AND flat avatars pool" "$r" "missing logo copies under $I"
[ -f "$I/noassets/personas/agents/noassets_a.md" ] && [ -f "$I/emptylogos/personas/avatars/emptylogos_a_avatar.png" ]; r=$?
check "B3: teams processed after a no-asset team still get their agents/avatars" "$r" "later teams skipped"

# ── C: shipped Space Dock assets exist in the tap ────────────────────────────
n_av=$(ls "$TAP_ROOT/share/personas/spacedock/avatars/"*.png 2>/dev/null | wc -l | tr -d ' ')
n_lg=$(ls "$TAP_ROOT/share/terminals/spacedock/logos/"*.png 2>/dev/null | wc -l | tr -d ' ')
[ "$n_av" -gt 0 ] && [ "$n_lg" -gt 0 ]; r=$?
check "C1: tap ships Space Dock avatars ($n_av) and terminal logos ($n_lg)" "$r" "spacedock assets missing from share/"

# ── G: assertion-count pin (counted before G1) ───────────────────────────────
[ "$_ASSERTIONS" -eq 7 ]; r=$?
check "G1: assertion-count pin (7 expected, $_ASSERTIONS ran)" "$r" "assertion count drifted"

if [ "$_STANDALONE" = true ]; then
    printf "\nResults: %d passed, %d failed\n" "$_PASS_COUNT" "$_FAIL_COUNT"
    [ "$_FAIL_COUNT" -eq 0 ] || exit 1
    [ "$_PASS_COUNT" -gt 0 ] || { echo "no assertions passed — refusing to report success" >&2; exit 1; }
fi
