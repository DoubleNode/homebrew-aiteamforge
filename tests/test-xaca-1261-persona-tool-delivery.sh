#!/bin/bash

# test-xaca-1261-persona-tool-delivery.sh
# Regression tests for XACA-1261-004/006: kb-sync-personas + personas-manifest.json
# delivery to tap consumers.
#
# DEFECT: before this ticket, kb-sync-personas (the persona deployment/drift-check
# tool) and its personas-manifest.json config had ZERO delivery path to any tap
# consumer — no sync_file mapping, no installer laydown, no upgrade refresh. The
# tool existed only at ~/dev-team/scripts/kb-sync-personas on the dev machine.
# Verified directly against the pre-fix tree (git show HEAD:...): grep for
# "kb-sync-personas" over the pre-fix install-kanban.sh returns ZERO matches, and
# the pre-fix aiteamforge-upgrade.sh's _xaca0608_aux_script_map /
# _xaca1143_aux_mandatory_materialize_basenames carry no entry for it either — the
# same shape XACA-0771/0814/0925 record ("install-time additions routinely skipped
# by the upgrade path"): install and upgrade read two DIFFERENT hand-maintained
# lists (install-kanban.sh:653's own comment admits this), so a fix that only
# touches one is not a fix.
#
# Fix (subitem 004, in this same tap checkout, uncommitted):
#   - install-kanban.sh gains install_kb_sync_personas_script(), called from
#     install_kanban_system().
#   - aiteamforge-upgrade.sh gains a kb-sync-personas entry in
#     _xaca0608_aux_script_map() + _xaca1143_aux_mandatory_materialize_basenames()
#     (mandatory-materialize, since every existing consumer is missing this
#     brand-new file), plus a dedicated update_personas_manifest() for the JSON
#     config (plain cp — must ship unmodified, no sed-rewrite, no chmod +x).
#
# THIS FILE covers XACA-1261-006's three required assertions (test names below
# are labeled TEST 1x / TEST 2x / NEGATIVE CONTROL 3x / TEST 4x in-line):
#   1. A sandboxed INSTALL lays the script (and manifest) down          -> "TEST 1a/1b/1c"
#   2. A sandboxed UPGRADE lays them down too, starting from a tree     -> "TEST 2 precondition" + "TEST 2a/2b/2c"
#      where the files are ABSENT (simulating an existing v0.20.15
#      consumer) — the upgrade path ALONE must create them, never
#      relying on install having run first in the same test.
#   3. NEGATIVE CONTROLS proving both assertions FAIL against the       -> "NEGATIVE CONTROL 3a"-"3f"
#      pre-fix tree (materialized via `git show HEAD:<path>` — this
#      worktree's uncommitted changes ARE the fix, so HEAD is exactly
#      the pre-fix state).
#   4. Delivery-layer confirmation that the SHIPPED copy actually       -> "TEST 4a/4b"
#      contains the XACA-1261 consumer-mode/hosted-filter logic that
#      selftest Test 21 exercises at the unit level (not a re-run of
#      Test 21 itself — that is out of scope here, per the brief).
#
# NOTE ON FIXTURE SOURCING: sync-tap.sh has NOT been run in write mode against
# this tap checkout (forbidden by this ticket's own constraints), so
# $TAP_ROOT/share/scripts/kb-sync-personas and .../personas-manifest.json do not
# exist yet in this checkout — only the sync_file MAPPING for them exists (in the
# sibling dev-team worktree's sync-tap.sh, uncommitted, not this repo). Tests here
# therefore build a synthetic FIXTURE_ROOT/share/scripts/ from the worktree's
# already-shipped canonical files (scripts/kb-sync-personas,
# .claude/personas-manifest.json) to stand in for "what sync-tap.sh will place
# there" — exactly the synthetic-fixture recommendation in
# docs/plans/XACA-1261/002-design.md ("Recommend the synthetic-fixture route for
# 006's negative control since it does not depend on another ticket's timeline").
# This does not test sync-tap.sh's own mapping (that is XACA-1261-004's own
# sync-tap.sh diff, reviewed separately) — only the installer/upgrade half this
# subitem is chartered to verify.
#
# All filesystem activity is sandboxed to TEST_TMP_DIR. NEVER touches real
# $HOME / ~/.aiteamforge — installer-test safety rule. No `brew install`/
# `--HEAD`/`reinstall`, no `brew tap`, no launchd agents.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$TAP_ROOT/libexec/installers/install-kanban.sh"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
# NOTE: this test file is designed to run from the MAIN checkout's
# homebrew-tap/ (per this ticket's own constraints, the XACA-1261 WORKTREE's
# homebrew-tap/ submodule is deliberately left uninitialized throughout, so
# there is no test-runner to invoke from there). $TAP_ROOT/.. in the main
# checkout is ~/dev-team itself (NOT the worktree) — its scripts/kb-sync-personas
# is the OLD pre-XACA-1261 copy (verified: 0 occurrences of _is_hosted_here vs.
# 8 in the worktree's copy), so deriving the canonical source from $TAP_ROOT's
# parent would silently build the fixture from the WRONG (unfixed) source and
# make Test 4a/4b pass or fail for the wrong reason. Point explicitly at the
# XACA-1261 worktree instead; overridable for portability across machines/
# sessions via XACA1261_CANONICAL_DEVTEAM.
DEVTEAM_WORKTREE="${XACA1261_CANONICAL_DEVTEAM:-$HOME/dev-team/worktrees/xaca-1261}"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (works sourced by test-runner.sh OR invoked directly).
# Mirrors test-xaca-0588 / test-xaca-0673 conventions.
# ─────────────────────────────────────────────────────────────────────────────
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
if ! type -t assert_file_exists >/dev/null 2>&1; then
    assert_file_exists() { [ -f "$1" ] || { test_fail "${2:-Expected file to exist: $1}"; return 1; }; }
fi
if ! type -t assert_file_not_exists >/dev/null 2>&1; then
    assert_file_not_exists() { [ ! -f "$1" ] || { test_fail "${2:-Expected file to not exist: $1}"; return 1; }; }
fi
if ! type -t assert_contains >/dev/null 2>&1; then
    assert_contains() { [[ "$1" == *"$2"* ]] || { test_fail "${3:-Expected to find '$2'}"; return 1; }; }
fi

# print_* / info / warning / success stubs used by extracted functions.
for _p in print_section print_info print_success print_warning print_error \
          info warning success error; do
    if ! declare -f "$_p" >/dev/null 2>&1; then
        eval "${_p}() { :; }"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory (runner-supplied or our own). UNIQUE per XACA-0453/1230
# knowledge — shared $TMPDIR leak counts from other sessions must never be
# attributed to this run.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1261-delivery-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

SANDBOX="$TEST_TMP_DIR/xaca1261"
mkdir -p "$SANDBOX"

# ─────────────────────────────────────────────────────────────────────────────
# Build the synthetic fixture root: share/scripts/{kb-sync-personas,
# personas-manifest.json}, copied from this worktree's already-shipped
# canonical sources (subitem 004's own script changes + the manifest). This
# stands in for what sync-tap.sh's (uncommitted, sibling-repo) mapping will
# place at $TAP_ROOT/share/scripts/ once run — see the file-header note above.
# ─────────────────────────────────────────────────────────────────────────────
FIXTURE_ROOT="$TEST_TMP_DIR/fixture-root"
mkdir -p "$FIXTURE_ROOT/share/scripts"

CANONICAL_SCRIPT="$DEVTEAM_WORKTREE/scripts/kb-sync-personas"
CANONICAL_MANIFEST="$DEVTEAM_WORKTREE/.claude/personas-manifest.json"

if [ ! -f "$CANONICAL_SCRIPT" ] || [ ! -f "$CANONICAL_MANIFEST" ]; then
    echo "FATAL: cannot find canonical sources to build the fixture:" >&2
    echo "  $CANONICAL_SCRIPT" >&2
    echo "  $CANONICAL_MANIFEST" >&2
    echo "This test must run from the homebrew-tap submodule checkout inside the" >&2
    echo "XACA-1261 worktree (dev-team/worktrees/xaca-1261/homebrew-tap)." >&2
    exit 1
fi

cp "$CANONICAL_SCRIPT" "$FIXTURE_ROOT/share/scripts/kb-sync-personas"
chmod +x "$FIXTURE_ROOT/share/scripts/kb-sync-personas"
cp "$CANONICAL_MANIFEST" "$FIXTURE_ROOT/share/scripts/personas-manifest.json"

# ─────────────────────────────────────────────────────────────────────────────
# Function extraction helper (test-xaca-0673/0608 pattern): pull one function's
# source out of a script by literal text, without sourcing the whole file (whose
# main bodies/side effects we don't want). Works on any text blob, not just a
# file on disk, so the SAME helper serves both the current tree and a `git show
# HEAD:...`-materialized pre-fix blob.
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn_from_text() {
    # $1 = function name, $2 = source text (already read into a variable)
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' <<< "$2"
}
_extract_fn_from_file() {
    # $1 = function name, $2 = file path
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$2"
}

CURRENT_INSTALL_TEXT="$(cat "$INSTALLER")"
CURRENT_UPGRADE_TEXT="$(cat "$UPGRADE_SH")"
PREFIX_INSTALL_TEXT="$(git -C "$TAP_ROOT" show HEAD:libexec/installers/install-kanban.sh 2>/dev/null)"
PREFIX_UPGRADE_TEXT="$(git -C "$TAP_ROOT" show HEAD:libexec/commands/aiteamforge-upgrade.sh 2>/dev/null)"

if [ -z "$PREFIX_INSTALL_TEXT" ] || [ -z "$PREFIX_UPGRADE_TEXT" ]; then
    echo "FATAL: could not materialize pre-fix (HEAD) content via git show -- needed for the" >&2
    echo "required negative-control tests. Is $TAP_ROOT a git repo with a HEAD commit?" >&2
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# ASSERTION 1 — a sandboxed INSTALL lays the script (and manifest) down
# ═══════════════════════════════════════════════════════════════════════════

INSTALL_FN_POSTFIX="$(_extract_fn_from_text install_kb_sync_personas_script "$CURRENT_INSTALL_TEXT")"

test_start "Sanity: install_kb_sync_personas_script is extractable from the CURRENT (post-fix) install-kanban.sh"
if [ -n "$INSTALL_FN_POSTFIX" ]; then
    test_pass
else
    test_fail "Could not extract install_kb_sync_personas_script from $INSTALLER -- cannot proceed with Test 1"
fi

CASE1_DIR="$SANDBOX/case1-install"
mkdir -p "$CASE1_DIR"

test_start "TEST 1a: sandboxed install lays kb-sync-personas at AITEAMFORGE_DIR/scripts/, executable, byte-identical to source"
CASE1_RC=1
if [ -n "$INSTALL_FN_POSTFIX" ]; then
    (
        eval "$INSTALL_FN_POSTFIX"
        INSTALL_ROOT="$FIXTURE_ROOT"
        AITEAMFORGE_DIR="$CASE1_DIR"
        install_kb_sync_personas_script
    ) >$TEST_TMP_DIR/t1a.out 2>&1
    CASE1_RC=$?
fi
if [ "$CASE1_RC" -eq 0 ] \
   && [ -f "$CASE1_DIR/scripts/kb-sync-personas" ] \
   && [ -x "$CASE1_DIR/scripts/kb-sync-personas" ] \
   && diff -q "$FIXTURE_ROOT/share/scripts/kb-sync-personas" "$CASE1_DIR/scripts/kb-sync-personas" >/dev/null 2>&1; then
    test_pass
else
    test_fail "Expected $CASE1_DIR/scripts/kb-sync-personas to exist, be executable, and be byte-identical to the fixture source (fn rc=$CASE1_RC); output: $(cat $TEST_TMP_DIR/t1a.out 2>/dev/null)"
fi

test_start "TEST 1b: sandboxed install lays personas-manifest.json at AITEAMFORGE_DIR/.claude/, byte-identical, UNMODIFIED"
if [ -f "$CASE1_DIR/.claude/personas-manifest.json" ] \
   && diff -q "$FIXTURE_ROOT/share/scripts/personas-manifest.json" "$CASE1_DIR/.claude/personas-manifest.json" >/dev/null 2>&1; then
    test_pass
else
    test_fail "Expected $CASE1_DIR/.claude/personas-manifest.json to exist and be byte-identical to the fixture source (manifest must ship UNMODIFIED per XACA-1261-002)"
fi

test_start "TEST 1c: sandboxed install with source ABSENT skips gracefully (exit 0, no file written)"
CASE1C_DIR="$SANDBOX/case1c-missing-source"
mkdir -p "$CASE1C_DIR"
EMPTY_FIXTURE="$TEST_TMP_DIR/empty-fixture-root"
mkdir -p "$EMPTY_FIXTURE/share/scripts"
(
    eval "$INSTALL_FN_POSTFIX"
    INSTALL_ROOT="$EMPTY_FIXTURE"
    AITEAMFORGE_DIR="$CASE1C_DIR"
    install_kb_sync_personas_script
) >$TEST_TMP_DIR/t1c.out 2>&1
CASE1C_RC=$?
if [ "$CASE1C_RC" -eq 0 ] && [ ! -f "$CASE1C_DIR/scripts/kb-sync-personas" ]; then
    test_pass
else
    test_fail "Expected graceful skip (exit 0, no file) when source is missing; rc=$CASE1C_RC, output: $(cat $TEST_TMP_DIR/t1c.out)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# ASSERTION 2 — a sandboxed UPGRADE lays them down too, starting from a tree
# where the files are ABSENT (simulating an existing v0.20.15 consumer). This
# is the assertion that matters most (install and upgrade read two DIFFERENT
# hand-maintained lists -- see file header). It must NOT depend on install
# having run in this process: CASE2_DIR below is fresh and install is never
# invoked against it.
# ═══════════════════════════════════════════════════════════════════════════

AUX_MAP_POSTFIX="$(_extract_fn_from_text _xaca0608_aux_script_map "$CURRENT_UPGRADE_TEXT")"
MANDATORY_POSTFIX="$(_extract_fn_from_text _xaca1143_aux_mandatory_materialize_basenames "$CURRENT_UPGRADE_TEXT")"
RENDER_POSTFIX="$(_extract_fn_from_text _xaca0608_render_team_script "$CURRENT_UPGRADE_TEXT")"
UPDATE_AUX_POSTFIX="$(_extract_fn_from_text update_aux_scripts "$CURRENT_UPGRADE_TEXT")"
UPDATE_MANIFEST_POSTFIX="$(_extract_fn_from_text update_personas_manifest "$CURRENT_UPGRADE_TEXT")"

test_start "Sanity: all five upgrade-path functions extractable from the CURRENT (post-fix) aiteamforge-upgrade.sh"
if [ -n "$AUX_MAP_POSTFIX" ] && [ -n "$MANDATORY_POSTFIX" ] && [ -n "$RENDER_POSTFIX" ] \
   && [ -n "$UPDATE_AUX_POSTFIX" ] && [ -n "$UPDATE_MANIFEST_POSTFIX" ]; then
    test_pass
else
    test_fail "One or more of _xaca0608_aux_script_map / _xaca1143_aux_mandatory_materialize_basenames / _xaca0608_render_team_script / update_aux_scripts / update_personas_manifest could not be extracted from $UPGRADE_SH -- cannot proceed with Test 2"
fi

CASE2_DIR="$SANDBOX/case2-upgrade-from-absent"
mkdir -p "$CASE2_DIR"

test_start "TEST 2 precondition: simulated pre-upgrade consumer tree has NEITHER file (starting state IS absence, not a stale copy)"
if [ ! -f "$CASE2_DIR/scripts/kb-sync-personas" ] && [ ! -f "$CASE2_DIR/.claude/personas-manifest.json" ]; then
    test_pass
else
    test_fail "Test setup error: CASE2_DIR should start with neither file present"
fi

test_start "TEST 2a: update_aux_scripts (upgrade path) MATERIALISES kb-sync-personas when absent, from a FRESH tree where install never ran"
(
    eval "$RENDER_POSTFIX"
    eval "$AUX_MAP_POSTFIX"
    eval "$MANDATORY_POSTFIX"
    eval "$UPDATE_AUX_POSTFIX"
    FRAMEWORK_DIR="$FIXTURE_ROOT"
    WORKING_DIR="$CASE2_DIR"
    FORCE=false
    DRY_RUN=false
    update_aux_scripts
) >$TEST_TMP_DIR/t2a.out 2>&1
CASE2A_RC=$?
# NOTE: unlike install (a plain `cp`), update_aux_scripts routes EVERY
# aux-mapped entry through _xaca0608_render_team_script's rewrite-aware
# render (XACA-0608 convention, applies uniformly to every entry in the map
# -- not special-cased for kb-sync-personas). That render sed-rewrites any
# literal `~/dev-team`-shaped path to WORKING_DIR. kb-sync-personas' own
# DEV_TEAM resolution is dynamic (dirname "$SCRIPT_DIR", never a literal
# path), so this cannot change its BEHAVIOR -- but its help text/comments do
# contain a handful of illustrative "~/dev-team/..." example paths that the
# sed genuinely rewrites (measured: 5 lines differ, all comments/heredoc help
# text, e.g. "# Sources: ~/dev-team/.claude/personas-manifest.json"). A bare
# byte-identical check against the un-rendered fixture source is therefore
# the WRONG assertion for the upgrade path (it would fail even though
# delivery is correct) -- instead assert byte-identity against what the
# SAME render function produces when applied directly to the fixture with
# the same WORKING_DIR. This proves update_aux_scripts delivered exactly the
# rendered form the codebase's own renderer defines, not a corrupted or
# stale copy.
EXPECTED_RENDERED="$TEST_TMP_DIR/expected-rendered-kb-sync-personas"
(
    eval "$RENDER_POSTFIX"
    WORKING_DIR="$CASE2_DIR"
    _xaca0608_render_team_script "$FIXTURE_ROOT/share/scripts/kb-sync-personas" "$EXPECTED_RENDERED"
)
if [ "$CASE2A_RC" -eq 0 ] \
   && [ -f "$CASE2_DIR/scripts/kb-sync-personas" ] \
   && [ -x "$CASE2_DIR/scripts/kb-sync-personas" ] \
   && diff -q "$EXPECTED_RENDERED" "$CASE2_DIR/scripts/kb-sync-personas" >/dev/null 2>&1; then
    test_pass
else
    test_fail "Expected update_aux_scripts alone (no install call in this process) to materialise $CASE2_DIR/scripts/kb-sync-personas, executable, matching the rewrite-aware render of the fixture source (rc=$CASE2A_RC); diff vs expected-rendered: $(diff "$EXPECTED_RENDERED" "$CASE2_DIR/scripts/kb-sync-personas" 2>&1 | head -10); output: $(cat $TEST_TMP_DIR/t2a.out)"
fi

test_start "TEST 2b: update_personas_manifest (upgrade path) MATERIALISES personas-manifest.json when absent, UNMODIFIED, no exec bit forced"
(
    eval "$UPDATE_MANIFEST_POSTFIX"
    FRAMEWORK_DIR="$FIXTURE_ROOT"
    WORKING_DIR="$CASE2_DIR"
    FORCE=false
    DRY_RUN=false
    update_personas_manifest
) >$TEST_TMP_DIR/t2b.out 2>&1
CASE2B_RC=$?
if [ "$CASE2B_RC" -eq 0 ] \
   && [ -f "$CASE2_DIR/.claude/personas-manifest.json" ] \
   && diff -q "$FIXTURE_ROOT/share/scripts/personas-manifest.json" "$CASE2_DIR/.claude/personas-manifest.json" >/dev/null 2>&1; then
    test_pass
else
    test_fail "Expected update_personas_manifest alone to materialise $CASE2_DIR/.claude/personas-manifest.json, byte-identical (rc=$CASE2B_RC); output: $(cat $TEST_TMP_DIR/t2b.out)"
fi

test_start "TEST 2c: --dry-run does not materialise kb-sync-personas on upgrade"
CASE2C_DIR="$SANDBOX/case2c-dryrun"
mkdir -p "$CASE2C_DIR"
(
    eval "$RENDER_POSTFIX"
    eval "$AUX_MAP_POSTFIX"
    eval "$MANDATORY_POSTFIX"
    eval "$UPDATE_AUX_POSTFIX"
    FRAMEWORK_DIR="$FIXTURE_ROOT"
    WORKING_DIR="$CASE2C_DIR"
    FORCE=false
    DRY_RUN=true
    update_aux_scripts
) >$TEST_TMP_DIR/t2c.out 2>&1
assert_file_not_exists "$CASE2C_DIR/scripts/kb-sync-personas" \
    "--dry-run must not write kb-sync-personas to disk" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# ASSERTION 3 — NEGATIVE CONTROLS: the same assertions must FAIL against the
# pre-fix tree (materialized via `git show HEAD:...`; this worktree's changes
# to install-kanban.sh / aiteamforge-upgrade.sh are UNCOMMITTED, so HEAD is
# exactly the pre-fix code). A test that passes both before and after the fix
# asserts nothing -- these prove it does not.
# ═══════════════════════════════════════════════════════════════════════════

test_start "NEGATIVE CONTROL 3a: install_kb_sync_personas_script does NOT exist in the pre-fix (HEAD) install-kanban.sh"
INSTALL_FN_PREFIX="$(_extract_fn_from_text install_kb_sync_personas_script "$PREFIX_INSTALL_TEXT")"
if [ -z "$INSTALL_FN_PREFIX" ]; then
    test_pass
else
    test_fail "Expected install_kb_sync_personas_script to be ABSENT from pre-fix install-kanban.sh (this is supposed to be the negative control); got a non-empty extraction: $INSTALL_FN_PREFIX"
fi

test_start "NEGATIVE CONTROL 3b: pre-fix install-kanban.sh contains ZERO references to kb-sync-personas at all"
PREFIX_INSTALL_HITS="$(grep -c "kb-sync-personas" <<< "$PREFIX_INSTALL_TEXT" || true)"
if [ "${PREFIX_INSTALL_HITS:-0}" -eq 0 ]; then
    test_pass
else
    test_fail "Expected 0 occurrences of 'kb-sync-personas' in pre-fix install-kanban.sh; got $PREFIX_INSTALL_HITS (grep -n output follows)"
    grep -n "kb-sync-personas" <<< "$PREFIX_INSTALL_TEXT" >&2
fi

test_start "NEGATIVE CONTROL 3c: pre-fix _xaca0608_aux_script_map has NO kb-sync-personas entry"
AUX_MAP_PREFIX="$(_extract_fn_from_text _xaca0608_aux_script_map "$PREFIX_UPGRADE_TEXT")"
if [[ "$AUX_MAP_PREFIX" != *"kb-sync-personas"* ]]; then
    test_pass
else
    test_fail "Expected the pre-fix aux-script map to have NO kb-sync-personas line; got: $AUX_MAP_PREFIX"
fi

test_start "NEGATIVE CONTROL 3d: update_personas_manifest does NOT exist in the pre-fix (HEAD) aiteamforge-upgrade.sh"
UPDATE_MANIFEST_PREFIX="$(_extract_fn_from_text update_personas_manifest "$PREFIX_UPGRADE_TEXT")"
if [ -z "$UPDATE_MANIFEST_PREFIX" ]; then
    test_pass
else
    test_fail "Expected update_personas_manifest to be ABSENT from pre-fix aiteamforge-upgrade.sh; got a non-empty extraction"
fi

# The load-bearing empirical negative control: RUN the pre-fix upgrade machinery
# (its OWN _xaca0608_aux_script_map / _xaca1143_aux_mandatory_materialize_basenames,
# both extracted from HEAD) against a FRESH sandbox, with the SAME FIXTURE_ROOT as
# FRAMEWORK_DIR (so the source file genuinely exists on disk -- proving any miss is
# caused by the pre-fix map/mandatory-list, not by a missing fixture). This is the
# exact scenario Test 2a proves succeeds post-fix; here we show it fails pre-fix.
AUX_MAP_PREFIX_FULL="$(_extract_fn_from_text _xaca0608_aux_script_map "$PREFIX_UPGRADE_TEXT")"
MANDATORY_PREFIX="$(_extract_fn_from_text _xaca1143_aux_mandatory_materialize_basenames "$PREFIX_UPGRADE_TEXT")"
RENDER_PREFIX="$(_extract_fn_from_text _xaca0608_render_team_script "$PREFIX_UPGRADE_TEXT")"
UPDATE_AUX_PREFIX="$(_extract_fn_from_text update_aux_scripts "$PREFIX_UPGRADE_TEXT")"

test_start "NEGATIVE CONTROL 3e (LOAD-BEARING): running the PRE-FIX update_aux_scripts against the SAME fixture (source present on disk) does NOT lay down kb-sync-personas"
CASE3E_DIR="$SANDBOX/case3e-prefix-upgrade"
mkdir -p "$CASE3E_DIR"
if [ -n "$AUX_MAP_PREFIX_FULL" ] && [ -n "$MANDATORY_PREFIX" ] && [ -n "$RENDER_PREFIX" ] && [ -n "$UPDATE_AUX_PREFIX" ]; then
    (
        eval "$RENDER_PREFIX"
        eval "$AUX_MAP_PREFIX_FULL"
        eval "$MANDATORY_PREFIX"
        eval "$UPDATE_AUX_PREFIX"
        FRAMEWORK_DIR="$FIXTURE_ROOT"
        WORKING_DIR="$CASE3E_DIR"
        FORCE=false
        DRY_RUN=false
        update_aux_scripts
    ) >$TEST_TMP_DIR/t3e.out 2>&1
    CASE3E_RC=$?
    echo "     [diagnostic] pre-fix update_aux_scripts rc=$CASE3E_RC, output follows:"
    sed 's/^/       /' $TEST_TMP_DIR/t3e.out
    echo "     [diagnostic] ls of \$CASE3E_DIR/scripts after running pre-fix update_aux_scripts against a fixture root that DOES contain the source file:"
    (ls -la "$CASE3E_DIR/scripts" 2>&1 || echo "       (scripts/ was never created)") | sed 's/^/       /'
    if [ ! -f "$CASE3E_DIR/scripts/kb-sync-personas" ]; then
        test_pass
    else
        test_fail "REGRESSION IN THE NEGATIVE CONTROL ITSELF: pre-fix update_aux_scripts unexpectedly laid down kb-sync-personas -- this control is supposed to demonstrate the pre-fix gap and just failed to."
    fi
else
    test_fail "Could not extract one of the pre-fix upgrade functions needed to run this control (aux_map=${#AUX_MAP_PREFIX_FULL} mandatory=${#MANDATORY_PREFIX} render=${#RENDER_PREFIX} update_aux=${#UPDATE_AUX_PREFIX} chars)"
fi

test_start "NEGATIVE CONTROL 3f: personas-manifest.json is likewise never laid down pre-fix (no update_personas_manifest to even call)"
# update_personas_manifest doesn't exist pre-fix (3d already proved this) -- so
# there is no function to invoke here at all. Confirm calling the bare name in a
# subshell with none of the pre-fix functions defined fails as "command not
# found" (a real, observable failure), and that no manifest file appears.
(
    FRAMEWORK_DIR="$FIXTURE_ROOT"
    WORKING_DIR="$CASE3E_DIR"
    update_personas_manifest
) >$TEST_TMP_DIR/t3f.out 2>&1
CASE3F_RC=$?
echo "     [diagnostic] attempting to call update_personas_manifest with none of the pre-fix upgrade.sh functions in scope: rc=$CASE3F_RC"
sed 's/^/       /' $TEST_TMP_DIR/t3f.out
if [ "$CASE3F_RC" -ne 0 ] && [ ! -f "$CASE3E_DIR/.claude/personas-manifest.json" ]; then
    test_pass
else
    test_fail "Expected calling update_personas_manifest to fail (function does not exist pre-fix) and no manifest file to appear; rc=$CASE3F_RC"
fi

# ═══════════════════════════════════════════════════════════════════════════
# ASSERTION 4 (delivery-layer only; NOT a re-run of selftest Test 21) —
# the copy that actually reaches AITEAMFORGE_DIR/scripts/ via install AND via
# upgrade contains the XACA-1261 consumer-mode / hosted-filter functions, i.e.
# what got delivered is the FIXED script, not a stale pre-004 copy that merely
# happens to have the right filename and exec bit. Test 21 (selftest) already
# proves _is_hosted_here/_resolve_target_repo_for_team behave correctly at the
# unit level (verified via mutation test per the coordinator's brief); this
# test proves that logic actually TRAVELS through the delivery path this
# subitem owns.
# ═══════════════════════════════════════════════════════════════════════════

test_start "TEST 4a: the INSTALLED copy (Test 1) contains the consumer-mode hosted-filter functions"
if grep -q "_is_hosted_here" "$CASE1_DIR/scripts/kb-sync-personas" 2>/dev/null \
   && grep -q "_resolve_target_repo_for_team" "$CASE1_DIR/scripts/kb-sync-personas" 2>/dev/null \
   && grep -q "KBSP_MODE" "$CASE1_DIR/scripts/kb-sync-personas" 2>/dev/null; then
    test_pass
else
    test_fail "Installed copy at $CASE1_DIR/scripts/kb-sync-personas is missing one of _is_hosted_here / _resolve_target_repo_for_team / KBSP_MODE -- delivery may have shipped a stale/wrong copy"
fi

test_start "TEST 4b: the UPGRADED copy (Test 2a) contains the consumer-mode hosted-filter functions AND selftest Test 21"
if grep -q "_is_hosted_here" "$CASE2_DIR/scripts/kb-sync-personas" 2>/dev/null \
   && grep -q "_resolve_target_repo_for_team" "$CASE2_DIR/scripts/kb-sync-personas" 2>/dev/null \
   && grep -q "Test 21" "$CASE2_DIR/scripts/kb-sync-personas" 2>/dev/null; then
    test_pass
else
    test_fail "Upgraded copy at $CASE2_DIR/scripts/kb-sync-personas is missing the hosted-filter functions or its own selftest Test 21 -- delivery may have shipped a stale/wrong copy"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone only).
# ─────────────────────────────────────────────────────────────────────────────
rm -f $TEST_TMP_DIR/t1a.out $TEST_TMP_DIR/t1c.out $TEST_TMP_DIR/t2a.out $TEST_TMP_DIR/t2b.out \
      $TEST_TMP_DIR/t2c.out $TEST_TMP_DIR/t3e.out $TEST_TMP_DIR/t3f.out
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
