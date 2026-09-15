#!/bin/bash
# test-xaca-1221-upgrade-image-assets.sh
#
# XACA-1221 (subitem 004): `aiteamforge upgrade` never delivered team logos to
# ANY already-provisioned machine (no upgrade path ever copied
# share/terminals/<t>/logos), and never refreshed avatars either — a team
# provisioned before its PNGs existed in the tap (Space Dock, backfilled on
# M4Mini 0.20.11 before its avatars/logos landed) or before a shipped PNG was
# later updated in a tap release never received it. `update_team_image_assets`
# fixes this: a refresh-only step, wired into the run sequence right after
# `deploy_flat_team_personas` and before `update_claude_hooks`, that mirrors
# a shipped avatar/logo PNG into both the per-team dir and the flat
# `${WORKING_DIR}/avatars` pool for every already-provisioned team.
#
# SHELL: like test-xaca-1216-flat-persona-deploy.sh, NOT a self-re-exec suite
# (tests/ci-manifest says that XACA-0931 pattern is a workaround, not to be
# copied). This suite runs under WHATEVER bash executes it — `/bin/bash
# tests/<this>` exercises Apple bash 3.2, CI's PATH bash exercises 5.x. Run
# it explicitly under both; see the file's own "Interpreter under test" line.
#
# SANDBOX: HOME, FRAMEWORK_DIR-equivalent (fw/) and WORKING_DIR-equivalent
# (aiteamforge/) all live under TEST_TMP_DIR, exported BEFORE anything is
# sourced. TMUX/TMUX_PANE unset. The real tap tree is only READ (its
# print_*/valid-team-id/update_team_image_assets function bodies are
# extracted with `_extract_fn`, never sourced whole — sourcing the whole file
# would run its top-level `source lib/*.sh` chain against a real $HOME).
#
# Cases (design doc XACA-1221 Decision 4, "Upgrade" half):
#   (a) provisioned team, empty avatars/logos dirs -> PNGs land in the team
#       dir AND the flat pool
#   (b) team ships assets but has no WORKING_DIR/<t> dir -> not created
#   (c) re-run on an already-refreshed root -> 0 written, all current
#   (d) a user-added extra PNG survives; a changed shipped PNG is overwritten
#   (e) DRY_RUN=true -> writes nothing, reports would-write counts
#   (f) a team whose source dirs exist but hold no PNGs survives `set -e`
#       (the XACA-1212 errexit-on-empty-glob class)
#   (g) an unwritable destination -> failed>0, fn rc 0, CONTINUED_PAST_CALL
#   (h) negative control: pinned pre-change ref (not HEAD), function absent
#   (i) registration: the call sits between deploy_flat_team_personas and
#       update_claude_hooks in the run sequence

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Last tap main commit before XACA-1221 (see section (h)).
PRECHANGE_REF="${XACA1221_PRECHANGE_REF:-d26fd75}"

# ── Sandbox first — before any source/eval ─────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1221-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
# Canonical path: macOS /var -> /private/var would otherwise make path
# comparisons disagree.
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
export TEST_TMP_DIR
WORK_DIR="$TEST_TMP_DIR/xaca1221"
mkdir -p "$WORK_DIR"
export HOME="$WORK_DIR/home"
mkdir -p "$HOME"
unset TMUX TMUX_PANE AITEAMFORGE_CONFIG AITEAMFORGE_HOME KB_TEAM KB_TERMINAL \
      GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE AITEAMFORGE_DIR
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

_next_sandbox() { mktemp -d "$WORK_DIR/sbx-XXXXXX"; }

# ── Framework (standalone or sourced by test-runner.sh) ─────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST -- $1" >&2; }
fi
_SKIP_COUNT=0
test_skip() { _SKIP_COUNT=$((_SKIP_COUNT + 1)); echo "     SKIP (not a pass): $_CURRENT_TEST -- $1"; }

# ── Inputs ──────────────────────────────────────────────────────────────────
UPGRADE_REL="libexec/commands/aiteamforge-upgrade.sh"
UPGRADE_ABS="$TAP_ROOT/$UPGRADE_REL"

if [ ! -f "$UPGRADE_ABS" ]; then
    echo "FATAL: required file not found: $UPGRADE_ABS" >&2
    exit 1
fi

echo ""
echo "Interpreter under test: $BASH ($BASH_VERSION)"

# ── Shared helpers ──────────────────────────────────────────────────────────

# _extract_fn <name> <file> — a top-level `name() {` ... `}` function.
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$2"
}

# _build_fns <upgrade.sh> <out> — extract the functions under test.
_build_fns() {
    local up="$1" out="$2" fn src
    : > "$out"
    for fn in update_team_image_assets _xaca0925_valid_team_id; do
        src="$(_extract_fn "$fn" "$up")"
        [ -n "$src" ] || return 1
        printf '%s\n\n' "$src" >> "$out"
    done
}

FNS_FILE="$WORK_DIR/fns.sh"
if ! _build_fns "$UPGRADE_ABS" "$FNS_FILE"; then
    echo "FATAL: could not extract update_team_image_assets / _xaca0925_valid_team_id from $UPGRADE_ABS" >&2
    exit 1
fi

# _mk_png <path> <content> — a fixture "PNG" (this function never validates
# magic bytes; that's server.py's job, a different subitem). Content just
# needs to be comparable across cmp -s calls.
_mk_png() {
    mkdir -p "$(dirname "$1")" || return 1
    printf '%s' "$2" > "$1"
}

# _fixture — lays out a sandbox root with:
#   teamA: ships 1 avatar + 1 logo in fw/share/, IS provisioned (aiteamforge/teamA exists)
#   teamB: ships 1 avatar in fw/share/, is NOT provisioned (no aiteamforge/teamB)
#   teamF: provisioned, but its fw/share source dirs exist and are EMPTY (case f)
# prints the root path.
_fixture() {
    local root; root="$(_next_sandbox)"
    mkdir -p "$root/fw/share" "$root/aiteamforge"

    _mk_png "$root/fw/share/personas/teamA/avatars/teamA_geordi_avatar.png" "AVATAR-v1"
    _mk_png "$root/fw/share/terminals/teamA/logos/teamA_lcars_logo.png"     "LOGO-v1"
    mkdir -p "$root/aiteamforge/teamA"

    _mk_png "$root/fw/share/personas/teamB/avatars/teamB_worf_avatar.png"  "AVATAR-B"
    # deliberately NOT creating $root/aiteamforge/teamB

    mkdir -p "$root/fw/share/personas/teamF/avatars" "$root/fw/share/terminals/teamF/logos"
    mkdir -p "$root/aiteamforge/teamF"

    printf '%s' "$root"
}

# _run_fn <root> <out> [dry] — run update_team_image_assets in a subshell
# under `set -eo pipefail` (matching the real script), prints fn rc.
_run_fn() {
    local root="$1" out="$2" dry="${3:-false}" rc=0
    ( set -eo pipefail
      for _p in print_section print_info print_success print_warning print_error; do
          eval "${_p}() { printf '%s: %s\n' ${_p} \"\$*\"; }"
      done
      # shellcheck disable=SC1090
      . "$FNS_FILE"
      FRAMEWORK_DIR="$root/fw"
      WORKING_DIR="$root/aiteamforge"
      DRY_RUN="$dry"
      update_team_image_assets
      echo "FN_RC=$?"
      echo "CONTINUED_PAST_CALL"
    ) >"$out" 2>&1 || rc=$?
    printf '%s' "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== (a)/(c)/(d) provisioned team: initial refresh, idempotent re-run, survive/overwrite ==="

ROOT="$(_fixture)"
OUT_A="$WORK_DIR/a.out"
RC_A="$(_run_fn "$ROOT" "$OUT_A")"

test_start "A1: fn exits 0, run completes (CONTINUED_PAST_CALL), no premature errexit abort"
if [ "$RC_A" = "0" ] && grep -q '^FN_RC=0$' "$OUT_A" && grep -q '^CONTINUED_PAST_CALL$' "$OUT_A"; then
    test_pass
else
    test_fail "rc=$RC_A out: $(tr '\n' '|' < "$OUT_A")"
fi

test_start "A2: teamA avatar copied into <t>/personas/avatars AND the flat pool, with source bytes"
if [ "$(cat "$ROOT/aiteamforge/teamA/personas/avatars/teamA_geordi_avatar.png" 2>/dev/null)" = "AVATAR-v1" ] \
    && [ "$(cat "$ROOT/aiteamforge/avatars/teamA_geordi_avatar.png" 2>/dev/null)" = "AVATAR-v1" ]; then
    test_pass
else
    test_fail "team-dir=[$(cat "$ROOT/aiteamforge/teamA/personas/avatars/teamA_geordi_avatar.png" 2>/dev/null)] pool=[$(cat "$ROOT/aiteamforge/avatars/teamA_geordi_avatar.png" 2>/dev/null)]"
fi

test_start "A3: teamA logo copied into <t>/terminals/logos AND the flat pool, with source bytes"
if [ "$(cat "$ROOT/aiteamforge/teamA/terminals/logos/teamA_lcars_logo.png" 2>/dev/null)" = "LOGO-v1" ] \
    && [ "$(cat "$ROOT/aiteamforge/avatars/teamA_lcars_logo.png" 2>/dev/null)" = "LOGO-v1" ]; then
    test_pass
else
    test_fail "team-dir=[$(cat "$ROOT/aiteamforge/teamA/terminals/logos/teamA_lcars_logo.png" 2>/dev/null)] pool=[$(cat "$ROOT/aiteamforge/avatars/teamA_lcars_logo.png" 2>/dev/null)]"
fi

test_start "A4: summary line reports targets/written/current/failed, ends with success (0 failed)"
# 2 files * 2 destinations (team-dir + pool) = 4 written for teamA; teamF (case f,
# empty source dirs) is also a target (WORKING_DIR/teamF exists) contributing 0/0.
if grep -q '^print_success: Team image assets: 2 team(s): 4 written, 0 current, 0 failed$' "$OUT_A"; then
    test_pass
else
    test_fail "out: $(tr '\n' '|' < "$OUT_A")"
fi

test_start "A5: teamB (ships assets, not provisioned -- no WORKING_DIR/teamB) is never created"
if [ ! -e "$ROOT/aiteamforge/teamB" ]; then
    test_pass
else
    test_fail "$ROOT/aiteamforge/teamB unexpectedly exists: $(ls -la "$ROOT/aiteamforge/teamB" 2>&1)"
fi

# --- (d) mutate the refreshed root: add an extra user PNG, change a shipped one ---
_mk_png "$ROOT/aiteamforge/teamA/personas/avatars/teamA_extra_avatar.png" "USER-ADDED"
_mk_png "$ROOT/aiteamforge/teamA/personas/avatars/teamA_geordi_avatar.png" "STALE-CONTENT"
_mk_png "$ROOT/fw/share/personas/teamA/avatars/teamA_geordi_avatar.png" "AVATAR-v2"

OUT_D="$WORK_DIR/d.out"
RC_D="$(_run_fn "$ROOT" "$OUT_D")"

test_start "D1: user-added extra PNG (not shipped by the tap) survives the refresh untouched"
if [ "$RC_D" = "0" ] && [ "$(cat "$ROOT/aiteamforge/teamA/personas/avatars/teamA_extra_avatar.png" 2>/dev/null)" = "USER-ADDED" ]; then
    test_pass
else
    test_fail "rc=$RC_D content=[$(cat "$ROOT/aiteamforge/teamA/personas/avatars/teamA_extra_avatar.png" 2>/dev/null)]"
fi

test_start "D2: a shipped PNG that drifted from the release (STALE-CONTENT) is overwritten back to the release bytes (AVATAR-v2) in BOTH destinations"
if [ "$(cat "$ROOT/aiteamforge/teamA/personas/avatars/teamA_geordi_avatar.png" 2>/dev/null)" = "AVATAR-v2" ] \
    && [ "$(cat "$ROOT/aiteamforge/avatars/teamA_geordi_avatar.png" 2>/dev/null)" = "AVATAR-v2" ]; then
    test_pass
else
    test_fail "team-dir=[$(cat "$ROOT/aiteamforge/teamA/personas/avatars/teamA_geordi_avatar.png" 2>/dev/null)] pool=[$(cat "$ROOT/aiteamforge/avatars/teamA_geordi_avatar.png" 2>/dev/null)]"
fi

# --- (c) re-run again: everything now matches the release, expect 0 written ---
OUT_C="$WORK_DIR/c.out"
RC_C="$(_run_fn "$ROOT" "$OUT_C")"
test_start "C1: idempotent re-run on an already-current root reports 0 written, all current, 0 failed"
if [ "$RC_C" = "0" ] && grep -q '^print_success: Team image assets: 2 team(s): 0 written, 4 current, 0 failed$' "$OUT_C"; then
    test_pass
else
    test_fail "rc=$RC_C out: $(tr '\n' '|' < "$OUT_C")"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== (e) --dry-run: nothing written, would-write counts reported ==="

ROOT_E="$(_fixture)"
OUT_E="$WORK_DIR/e.out"
RC_E="$(_run_fn "$ROOT_E" "$OUT_E" true)"

test_start "E1: dry-run does not create the destination files"
if [ "$RC_E" = "0" ] && [ ! -e "$ROOT_E/aiteamforge/teamA/personas/avatars/teamA_geordi_avatar.png" ] \
    && [ ! -e "$ROOT_E/aiteamforge/avatars/teamA_geordi_avatar.png" ] \
    && [ ! -e "$ROOT_E/aiteamforge/teamA/terminals/logos/teamA_lcars_logo.png" ]; then
    test_pass
else
    test_fail "rc=$RC_E avatar_exists=$([ -e "$ROOT_E/aiteamforge/teamA/personas/avatars/teamA_geordi_avatar.png" ] && echo yes || echo no)"
fi

test_start "E2: dry-run summary reports would-write counts with a (dry run) suffix"
if grep -q '^print_success: Team image assets (dry run): 2 team(s): 4 written, 0 current, 0 failed$' "$OUT_E"; then
    test_pass
else
    test_fail "out: $(tr '\n' '|' < "$OUT_E")"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== (f) team with source dirs present but zero PNGs survives set -e (XACA-1212 class) ==="

# Reuses ROOT from the (a)/(c)/(d) block above: teamF has empty
# fw/share/{personas/teamF/avatars,terminals/teamF/logos} and an existing
# aiteamforge/teamF working dir, so it IS a target but contributes 0/0/0.
test_start "F1: teamF (empty source dirs) never aborts the run; teamF destinations stay absent"
if [ "$RC_C" = "0" ] && grep -q '^CONTINUED_PAST_CALL$' "$OUT_C" \
    && [ ! -e "$ROOT/aiteamforge/teamF/personas" ] && [ ! -e "$ROOT/aiteamforge/teamF/terminals" ]; then
    test_pass
else
    test_fail "rc=$RC_C out: $(tr '\n' '|' < "$OUT_C")"
fi

# Isolated single-team fixture, purely for a clean errexit-survival assertion.
ROOT_F="$(_next_sandbox)"
mkdir -p "$ROOT_F/fw/share/personas/teamOnly/avatars" "$ROOT_F/fw/share/terminals/teamOnly/logos" "$ROOT_F/aiteamforge/teamOnly"
OUT_F2="$WORK_DIR/f2.out"
RC_F2="$(_run_fn "$ROOT_F" "$OUT_F2")"
test_start "F2: a sandbox with ONLY an empty-source team never trips 'set -eo pipefail' (no glob-on-nothing abort)"
if [ "$RC_F2" = "0" ] && grep -q '^FN_RC=0$' "$OUT_F2" && grep -q '^CONTINUED_PAST_CALL$' "$OUT_F2" \
    && grep -q '^print_success: Team image assets: 1 team(s): 0 written, 0 current, 0 failed$' "$OUT_F2"; then
    test_pass
else
    test_fail "rc=$RC_F2 out: $(tr '\n' '|' < "$OUT_F2")"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== (g) unwritable destination -> failed>0, fn rc 0, run continues ==="

ROOT_G="$(_next_sandbox)"
mkdir -p "$ROOT_G/fw/share/personas/teamG/avatars" "$ROOT_G/aiteamforge/teamG/personas/avatars"
_mk_png "$ROOT_G/fw/share/personas/teamG/avatars/teamG_data_avatar.png" "AVATAR-G"
chmod 555 "$ROOT_G/aiteamforge/teamG/personas/avatars"
_g_restore() { chmod 755 "$ROOT_G/aiteamforge/teamG/personas/avatars" 2>/dev/null || true; }
trap '_g_restore; cleanup' EXIT

OUT_G="$WORK_DIR/g.out"
RC_G="$(_run_fn "$ROOT_G" "$OUT_G")"
_g_restore
trap cleanup EXIT

test_start "G1: an unwritable per-team destination is counted failed>0, warned, fn still returns 0, run continues"
if [ "$RC_G" = "0" ] && grep -q '^FN_RC=0$' "$OUT_G" && grep -q '^CONTINUED_PAST_CALL$' "$OUT_G" \
    && grep -Eq '^print_warning: \[teamG\] could not write .*/teamG_data_avatar\.png$' "$OUT_G" \
    && grep -Eq '^print_warning: Team image assets: 1 team\(s\): [0-9]+ written, 0 current, [1-9][0-9]* failed$' "$OUT_G"; then
    test_pass
else
    test_fail "rc=$RC_G out: $(tr '\n' '|' < "$OUT_G")"
fi

test_start "G2: the flat pool copy (a writable destination) still succeeds even though the team-dir copy failed"
if [ "$(cat "$ROOT_G/aiteamforge/avatars/teamG_data_avatar.png" 2>/dev/null)" = "AVATAR-G" ]; then
    test_pass
else
    test_fail "pool content=[$(cat "$ROOT_G/aiteamforge/avatars/teamG_data_avatar.png" 2>/dev/null)]"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== (h) negative control: the pre-change upgrade script ($PRECHANGE_REF) ==="

# Pinned to a PRE-CHANGE ref, never HEAD: once this change is committed, HEAD
# contains the function and a HEAD-based control goes vacuous (it did, on the
# first commit of this test). Override with XACA1221_PRECHANGE_REF.
test_start "H1: pre-change upgrade.sh does NOT define update_team_image_assets"
_pre_src=""
if ! git -C "$TAP_ROOT" cat-file -e "${PRECHANGE_REF}^{commit}" 2>/dev/null; then
    test_skip "pre-change ref $PRECHANGE_REF is not in this clone (shallow?) -- set XACA1221_PRECHANGE_REF; the control did NOT run"
else
    _pre_src="$(git -C "$TAP_ROOT" show "${PRECHANGE_REF}:${UPGRADE_REL}" 2>/dev/null)"
    if [ -z "$_pre_src" ]; then
        test_fail "could not read ${PRECHANGE_REF}:${UPGRADE_REL}"
    elif printf '%s\n' "$_pre_src" | grep -q '^update_team_image_assets() {'; then
        test_fail "NEGATIVE CONTROL: $PRECHANGE_REF already defines update_team_image_assets -- the control is vacuous"
    else
        test_pass
    fi
fi

test_start "H2: pre-change run sequence never calls update_team_image_assets (no logo/avatar refresh on upgrade)"
if [ -z "$_pre_src" ]; then
    test_skip "pre-change source unavailable -- see H1"
elif printf '%s\n' "$_pre_src" | grep -qE '^[[:space:]]*update_team_image_assets[[:space:]]*$'; then
    test_fail "NEGATIVE CONTROL: $PRECHANGE_REF already calls update_team_image_assets"
else
    test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== (i) registration: the call sits between deploy_flat_team_personas and update_claude_hooks ==="

test_start "I1: run sequence calls update_team_image_assets somewhere after deploy_flat_team_personas and before update_claude_hooks (comments may intervene, but no other bare call does)"
_i_between="$(awk '
    /^deploy_flat_team_personas$/ { inzone=1; next }
    inzone && /^update_claude_hooks$/ { exit }
    inzone && $0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/ { print }
' "$UPGRADE_ABS")"
if [ "$_i_between" = "update_team_image_assets" ]; then
    test_pass
else
    test_fail "bare (non-comment, non-blank) line(s) found between the two calls: [$_i_between]"
fi

test_start "I2: update_team_image_assets is defined exactly once, as a top-level function"
_i_def_count="$(grep -c '^update_team_image_assets() {' "$UPGRADE_ABS")"
if [ "$_i_def_count" = "1" ]; then
    test_pass
else
    test_fail "definition count=$_i_def_count (expected exactly 1)"
fi

test_start "I3: ci-manifest lists this test file (completeness gate would otherwise fail CI)"
_manifest="$TAP_ROOT/tests/ci-manifest"
if [ -f "$_manifest" ] && grep -q '^test-xaca-1221-upgrade-image-assets\.sh[[:space:]]' "$_manifest"; then
    test_pass
else
    test_fail "no 'test-xaca-1221-upgrade-image-assets.sh  plain-shell' line in $_manifest"
fi

# ─────────────────────────────────────────────────────────────────────────────
if [ "${_STANDALONE:-false}" != true ] && [ -n "${TEST_RESULTS_FILE:-}" ] && [ -f "${TEST_RESULTS_FILE}" ]; then
    _x1221_fail_lines="$(grep '^FAIL:' "$TEST_RESULTS_FILE" 2>/dev/null || true)"
    if [ -n "$_x1221_fail_lines" ]; then
        echo "─── XACA-1221 failure detail ───"
        printf '%s\n' "$_x1221_fail_lines"
    fi
fi

if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed, ${_SKIP_COUNT} skipped"
    [ "$_FAIL_COUNT" -eq 0 ]
fi
