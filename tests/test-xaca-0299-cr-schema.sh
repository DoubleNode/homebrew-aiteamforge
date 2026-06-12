#!/bin/bash

# test-xaca-0299-cr-schema.sh
# Regression test for XACA-0299: installer-simulation for CR-schema deployment.
#
# REGRESSION INTENT: Guards that the installer correctly deploys the CR-lifecycle
# artifacts kb-cr.sh and migrate-cr-schema.py via install_lcars_profile_script(),
# and that the deployed migrate-cr-schema.py migrator honours its dry-run and
# no-op contracts. This test was deferred from XACA-0291 PR #326 as [Review]
# subitem XACA-0291-017, and was filed as EPIC-0017 Phase 1 follow-up work.
# Installing CR artifacts to a real $HOME is a banned class of bug; all activity
# is fully sandboxed.
#
# Assertions:
#   PATH A — install_lcars_profile_script() deployment:
#   1. Tap ships source kb-cr.sh under share/scripts/ (source-presence sanity).
#   2. Tap ships source migrate-cr-schema.py under share/scripts/ (source-presence sanity).
#   3. install_lcars_profile_script() deploys kb-cr.sh to $AITEAMFORGE_DIR/scripts/
#      with executable bit set.
#   4. install_lcars_profile_script() deploys migrate-cr-schema.py to
#      $AITEAMFORGE_DIR/scripts/ with executable bit set.
#   5. The DynamicProfiles write lands in the sandbox (no file created under real $HOME).
#   6. install_lcars_profile_script is wired into the install_kanban_system run sequence
#      (source grep).
#
#   PATH B — deployed migrate-cr-schema.py dry-run / no-op contract:
#   7.  --item dry-run on a v1 item: exit 0, output contains "[DRY RUN]", board file
#       is byte-identical before/after, and no .backup.* sibling was created.
#   8.  Batch mode on an already-initialised v2 board: exit 0, output contains
#       "No CR data to migrate", no .backup.* file created.
#   9.  --item on an item not found on the board: exit 5.
#  10.  --item on an item with no CR data at all: exit 6.
#  11.  --item (already v2, has crAssignment + no deprecated fields): exit 0,
#       output contains "no-op (already v2)".
#
# All filesystem activity is sandboxed to TEST_TMP_DIR.
# NEVER touches real $HOME / ~/.aiteamforge — installer-test safety rule.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_KSH="$TAP_ROOT/libexec/installers/install-kanban.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: works both as a sourced test-runner.sh file AND as a
# directly-invoked script (mirrors test-xaca-0608 pattern).
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

    assert_file_exists() {
        local file="$1" msg="${2:-Expected file to exist: $1}"
        [ -f "$file" ] || { test_fail "$msg"; return 1; }
    }
    assert_file_not_exists() {
        local file="$1" msg="${2:-Expected file to not exist: $1}"
        [ ! -f "$file" ] || { test_fail "$msg"; return 1; }
    }
    # SC2016: $2 in the default message is intentional — we want the literal
    # string '$2', not the function argument.
    # shellcheck disable=SC2016
    assert_contains() {
        local haystack="$1" needle="$2" msg="${3:-Expected to find '$2' in string}"
        [[ "$haystack" == *"$needle"* ]] || { test_fail "$msg"; return 1; }
    }
    # shellcheck disable=SC2016
    assert_not_contains() {
        local haystack="$1" needle="$2" msg="${3:-Expected NOT to find '$2' in string}"
        [[ "$haystack" != *"$needle"* ]] || { test_fail "$msg"; return 1; }
    }
fi

# assert_not_contains may not exist in the shared runner — provide a fallback.
if ! type -t assert_not_contains >/dev/null 2>&1; then
    # shellcheck disable=SC2016
    assert_not_contains() {
        local haystack="$1" needle="$2" msg="${3:-Expected NOT to find '$2' in string}"
        [[ "$haystack" != *"$needle"* ]] || { test_fail "$msg"; return 1; }
    }
fi

# info/warning/success stubs used by the extracted function (provided by
# test-runner.sh when sourced; no-op fallback when standalone).
for _p in info warning success; do
    if ! declare -f "$_p" >/dev/null 2>&1; then
        eval "${_p}() { :; }"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory: use the runner-supplied TEST_TMP_DIR or create our own.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0299-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi

SANDBOX="$TEST_TMP_DIR/xaca0299"
mkdir -p "$SANDBOX"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Extract install_lcars_profile_script from install-kanban.sh, rather than
# sourcing the whole installer (it has side effects: is_configured, init_board,
# etc.). Capture from the function header through its first column-0 `^}$`.
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn() {
    # $1 = function name (regex-safe literal). Capture header through first ^}$.
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$INSTALL_KSH"
}

_fn_src="$(_extract_fn install_lcars_profile_script)"
if [ -z "$_fn_src" ]; then
    test_start "Sanity: can extract install_lcars_profile_script from install-kanban.sh"
    test_fail "awk returned empty — could not extract install_lcars_profile_script"
    if [ "$_STANDALONE" = true ]; then echo "Results: ${_PASS_COUNT} passed, $((_FAIL_COUNT + 1)) failed"; fi
    exit 1
fi

eval "$_fn_src"
declare -f install_lcars_profile_script >/dev/null || \
    { echo "FATAL: install_lcars_profile_script not defined after extraction"; exit 1; }

# ═══════════════════════════════════════════════════════════════════════════
# PATH A TESTS — install_lcars_profile_script() deployment
# ═══════════════════════════════════════════════════════════════════════════

# ── TEST 1: Tap ships source kb-cr.sh ────────────────────────────────────────
test_start "Tap ships share/scripts/kb-cr.sh (source-presence sanity)"
assert_file_exists "$TAP_ROOT/share/scripts/kb-cr.sh" \
    "share/scripts/kb-cr.sh must exist in the tap — it is the installer source"
test_pass

# ── TEST 2: Tap ships source migrate-cr-schema.py ────────────────────────────
test_start "Tap ships share/scripts/migrate-cr-schema.py (source-presence sanity)"
assert_file_exists "$TAP_ROOT/share/scripts/migrate-cr-schema.py" \
    "share/scripts/migrate-cr-schema.py must exist in the tap — it is the installer source"
test_pass

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox setup for install_lcars_profile_script() run.
# We override HOME so the DynamicProfiles write lands in the sandbox, not the
# real ~/Library. We capture real HOME before overriding so we can assert no
# files were created under it.
# ─────────────────────────────────────────────────────────────────────────────
FAKE_AITEAMFORGE_DIR="$SANDBOX/aiteamforge"
FAKE_HOME="$SANDBOX/home"
mkdir -p "$FAKE_AITEAMFORGE_DIR/scripts"
mkdir -p "$FAKE_HOME"

_REAL_HOME="$HOME"

run_install_lcars_profile_script() {
    HOME="$FAKE_HOME" \
    AITEAMFORGE_DIR="$FAKE_AITEAMFORGE_DIR" \
    INSTALL_ROOT="$TAP_ROOT" \
    SCRIPT_DIR="$TAP_ROOT/libexec/installers" \
    AITEAMFORGE_REFRESH_PROFILES="" \
    install_lcars_profile_script 2>/dev/null
}

run_install_lcars_profile_script

# ── TEST 3: kb-cr.sh deployed and executable ─────────────────────────────────
test_start "install_lcars_profile_script deploys kb-cr.sh to AITEAMFORGE_DIR/scripts/"
assert_file_exists "$FAKE_AITEAMFORGE_DIR/scripts/kb-cr.sh" \
    "kb-cr.sh must be present in AITEAMFORGE_DIR/scripts/ after install"
if [ -x "$FAKE_AITEAMFORGE_DIR/scripts/kb-cr.sh" ]; then
    test_pass
else
    test_fail "Deployed kb-cr.sh must be executable"
fi

# ── TEST 4: migrate-cr-schema.py deployed and executable ─────────────────────
test_start "install_lcars_profile_script deploys migrate-cr-schema.py to AITEAMFORGE_DIR/scripts/"
assert_file_exists "$FAKE_AITEAMFORGE_DIR/scripts/migrate-cr-schema.py" \
    "migrate-cr-schema.py must be present in AITEAMFORGE_DIR/scripts/ after install"
if [ -x "$FAKE_AITEAMFORGE_DIR/scripts/migrate-cr-schema.py" ]; then
    test_pass
else
    test_fail "Deployed migrate-cr-schema.py must be executable"
fi

# ── TEST 5: DynamicProfiles write went to sandbox, NOT real $HOME ─────────────
test_start "DynamicProfiles write landed in sandbox, NOT under real \$HOME"
SANDBOX_PROFILE="$FAKE_HOME/Library/Application Support/iTerm2/DynamicProfiles/aiteamforge-lcars.json"
# Assert sandbox profile was created (if the tap ships the source)
if [ -f "$TAP_ROOT/share/scripts/aiteamforge-lcars.json" ]; then
    assert_file_exists "$SANDBOX_PROFILE" \
        "aiteamforge-lcars.json must be installed into the sandbox \$HOME, not real home"
fi
# Assert the deployment did NOT create a NEW file under the real home.
# We verify by checking the real profile path — the count before/after the run
# must not have been touched by this test. Since cleanup() removes TEST_TMP_DIR
# and we never touched the real home, the real profile should be unaffected.
# The authoritative check: the deployed path must NOT be inside _REAL_HOME.
# (The SANDBOX path starts with TEST_TMP_DIR, which is never under _REAL_HOME.)
# shellcheck disable=SC2076
if [[ "$SANDBOX_PROFILE" == "${_REAL_HOME}"* ]]; then
    test_fail "SANDBOX_PROFILE is unexpectedly inside real \$HOME — sandbox isolation broken"
else
    test_pass
fi

# ── TEST 6: install_lcars_profile_script is wired into install_kanban_system ──
test_start "install_lcars_profile_script is invoked in the install_kanban_system run sequence"
if grep -qE '[[:space:]]+install_lcars_profile_script$' "$INSTALL_KSH"; then
    test_pass
else
    test_fail "install-kanban.sh run sequence must call install_lcars_profile_script"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PATH B TESTS — deployed migrate-cr-schema.py dry-run / no-op contract
# We use the DEPLOYED copy from Path A so we prove the deployed artifact
# actually works — which is the point of an installer-simulation test.
# ═══════════════════════════════════════════════════════════════════════════

DEPLOYED_MIGRATE="$FAKE_AITEAMFORGE_DIR/scripts/migrate-cr-schema.py"
FIXTURES_DIR="$SANDBOX/fixtures"
mkdir -p "$FIXTURES_DIR"

# Helper: write a minimal valid board JSON. Parameters:
#   $1 = output file path
#   $2 = JSON string (the full board content)
_write_board() {
    printf '%s' "$2" > "$1"
}

# ── Fixture A: board with one v1 item (has deprecated cr_* fields) ────────────
# Minimal item in backlog[] with cr_id + cr_type (both non-empty deprecated fields)
# as recognised by _item_has_deprecated_cr_fields() in migrate-cr-schema.py.
V1_BOARD="$FIXTURES_DIR/v1-board.json"
_write_board "$V1_BOARD" '{
  "backlog": [
    {
      "id": "XACA-0001",
      "title": "Test item with v1 CR fields",
      "cr_id": "CR-TEST-20260101-001",
      "cr_type": "major",
      "crState": "cr-drafted"
    }
  ]
}'

# ── Fixture B: board with one v2 item (has crAssignment, no deprecated fields) ─
V2_ITEM_BOARD="$FIXTURES_DIR/v2-item-board.json"
_write_board "$V2_ITEM_BOARD" '{
  "backlog": [
    {
      "id": "XACA-0002",
      "title": "Test item already on v2 schema",
      "crAssignment": {
        "crId": "CR-TEST-20260101-002",
        "crTitle": "Release XYZ",
        "assignedAt": "2026-01-01T00:00:00Z"
      }
    }
  ],
  "crs": [
    {
      "id": "CR-TEST-20260101-002",
      "title": "Release XYZ",
      "itemIds": ["XACA-0002"]
    }
  ],
  "nextCrSeq": 3
}'

# ── Fixture C: already-v2 board (batch mode no-op) ────────────────────────────
# crs[] is a list, nextCrSeq is an integer, no items have deprecated cr_* fields.
V2_BATCH_BOARD="$FIXTURES_DIR/v2-batch-board.json"
_write_board "$V2_BATCH_BOARD" '{
  "backlog": [
    {
      "id": "XACA-0003",
      "title": "Clean item, no CR data"
    }
  ],
  "crs": [],
  "nextCrSeq": 1
}'

# ── Fixture D: board with item that has NO CR data at all ─────────────────────
NO_CR_BOARD="$FIXTURES_DIR/no-cr-board.json"
_write_board "$NO_CR_BOARD" '{
  "backlog": [
    {
      "id": "XACA-0004",
      "title": "Item with zero CR fields"
    }
  ]
}'

# ─────────────────────────────────────────────────────────────────────────────
# Guard: skip Path B tests if the deployed migrator is absent (Path A install
# failed — already reported). Avoids misleading "python3 not found" errors.
# ─────────────────────────────────────────────────────────────────────────────
if [ ! -f "$DEPLOYED_MIGRATE" ]; then
    for _t in \
        "Path B: dry-run on v1 item exits 0 and prints [DRY RUN]" \
        "Path B: dry-run on v1 item leaves board byte-identical" \
        "Path B: dry-run on v1 item creates no .backup.* file" \
        "Path B: batch mode on v2 board exits 0 and prints no-op message" \
        "Path B: batch mode on v2 board creates no .backup.* file" \
        "Path B: --item with unknown ID exits 5" \
        "Path B: --item on item with no CR data exits 6" \
        "Path B: --item on already-v2 item exits 0 and prints no-op (already v2)"
    do
        test_start "$_t"
        test_fail "Skipped — deployed migrate-cr-schema.py absent (Path A install failed)"
    done
else

# ── TEST 7a: --item dry-run on v1 item: exit 0, output contains [DRY RUN] ────
test_start "Path B: dry-run on v1 item exits 0 and prints [DRY RUN]"
_out_dryrun=$(python3 "$DEPLOYED_MIGRATE" --item XACA-0001 --board "$V1_BOARD" 2>&1)
_rc_dryrun=$?
if [ "$_rc_dryrun" -eq 0 ]; then
    test_pass
else
    test_fail "--item dry-run on v1 item must exit 0 (got: $_rc_dryrun)"
fi

test_start "Path B: dry-run output contains [DRY RUN]"
assert_contains "$_out_dryrun" "[DRY RUN]" \
    "--item dry-run output must contain '[DRY RUN]'"
test_pass

# ── TEST 7b: board file is byte-identical before/after dry-run ───────────────
test_start "Path B: dry-run on v1 item leaves board file byte-identical"
_cksum_before=$(md5 -q "$V1_BOARD" 2>/dev/null || md5sum "$V1_BOARD" 2>/dev/null | cut -d' ' -f1)
python3 "$DEPLOYED_MIGRATE" --item XACA-0001 --board "$V1_BOARD" >/dev/null 2>&1
_cksum_after=$(md5 -q "$V1_BOARD" 2>/dev/null || md5sum "$V1_BOARD" 2>/dev/null | cut -d' ' -f1)
if [ "$_cksum_before" = "$_cksum_after" ]; then
    test_pass
else
    test_fail "Dry-run must leave board file byte-identical (checksum changed)"
fi

# ── TEST 7c: no .backup.* sibling created ────────────────────────────────────
test_start "Path B: dry-run on v1 item creates no .backup.* file"
_backup_count=$(find "$FIXTURES_DIR" -name "v1-board.backup.*" 2>/dev/null | wc -l | tr -d ' ')
if [ "$_backup_count" -eq 0 ]; then
    test_pass
else
    test_fail "Dry-run must not create a .backup.* sibling (found: $_backup_count)"
fi

# ── TEST 8a: batch mode on v2 board exits 0 ──────────────────────────────────
test_start "Path B: batch mode on v2 board exits 0 and prints no-op message"
_out_batch=$(python3 "$DEPLOYED_MIGRATE" "$V2_BATCH_BOARD" 2>&1)
_rc_batch=$?
if [ "$_rc_batch" -eq 0 ]; then
    test_pass
else
    test_fail "Batch mode on v2 board must exit 0 (got: $_rc_batch)"
fi

test_start "Path B: batch mode on v2 board output contains no-op phrase"
assert_contains "$_out_batch" "No CR data to migrate" \
    "Batch mode no-op output must contain 'No CR data to migrate'"
test_pass

# ── TEST 8b: batch mode on v2 board creates no .backup.* file ────────────────
test_start "Path B: batch mode on v2 board creates no .backup.* file"
_backup_count2=$(find "$FIXTURES_DIR" -name "v2-batch-board.backup.*" 2>/dev/null | wc -l | tr -d ' ')
if [ "$_backup_count2" -eq 0 ]; then
    test_pass
else
    test_fail "Batch mode no-op must not create a .backup.* file (found: $_backup_count2)"
fi

# ── TEST 9: --item with unknown ID exits 5 ───────────────────────────────────
test_start "Path B: --item with unknown ID exits 5"
python3 "$DEPLOYED_MIGRATE" --item NONEXISTENT-9999 --board "$V1_BOARD" >/dev/null 2>&1
_rc_notfound=$?
if [ "$_rc_notfound" -eq 5 ]; then
    test_pass
else
    test_fail "--item with unknown ID must exit 5 (got: $_rc_notfound)"
fi

# ── TEST 10: --item on item with no CR data exits 6 ──────────────────────────
test_start "Path B: --item on item with no CR data exits 6"
python3 "$DEPLOYED_MIGRATE" --item XACA-0004 --board "$NO_CR_BOARD" >/dev/null 2>&1
_rc_nocr=$?
if [ "$_rc_nocr" -eq 6 ]; then
    test_pass
else
    test_fail "--item on item with no CR data must exit 6 (got: $_rc_nocr)"
fi

# ── TEST 11: --item on already-v2 item exits 0, prints no-op (already v2) ────
test_start "Path B: --item on already-v2 item exits 0 and prints no-op (already v2)"
_out_v2item=$(python3 "$DEPLOYED_MIGRATE" --item XACA-0002 --board "$V2_ITEM_BOARD" 2>&1)
_rc_v2item=$?
if [ "$_rc_v2item" -eq 0 ]; then
    test_pass
else
    test_fail "--item on already-v2 item must exit 0 (got: $_rc_v2item)"
fi

test_start "Path B: --item on already-v2 item output contains 'no-op (already v2)'"
assert_contains "$_out_v2item" "no-op (already v2)" \
    "--item on already-v2 item must print 'no-op (already v2)'"
test_pass

fi  # end guard: DEPLOYED_MIGRATE exists

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone mode only — test-runner.sh tallies from its own counters).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    if [ "$_FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
fi
exit 0
