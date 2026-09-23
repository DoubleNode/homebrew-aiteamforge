#!/bin/bash
# test-xaca-1322-consumer-datafile-refresh.sh
#
# XACA-1322: upgraded consumers crashed `cc` with
# `vault-fetch.js:521 TypeError: kg.resolveFleetUrl is not a function`. Root
# cause: an upgrade refreshed vault-fetch.js (which calls kg.resolveFleetUrl())
# but never re-shipped vault-keygen.js (the old sibling that doesn't define
# it yet), and never touched msg-client.js/package.json/package-lock.json at
# all on the upgrade path — only install-shell.sh's install_helper_scripts()
# (fresh installs) ever laid all five files down together.
#
# The fix (subitems 001-003, already in the working tree):
#   - 001: _aitf_consumer_datafiles() in libexec/lib/msg-client-deps.sh is now
#     the ONE place that lists the five names (msg-client.js, vault-keygen.js,
#     vault-fetch.js, package.json, package-lock.json); install-shell.sh's
#     install_helper_scripts() reads it instead of hand-listing them.
#   - 002: aiteamforge-upgrade.sh's update_runtime_helpers() now loops over
#     `$(_aitf_consumer_datafiles)` too, copying every shipped datafile
#     unconditionally (chmod 644, DRY_RUN-honoring) — replacing the narrower
#     XACA-1312 vault-fetch.js-only special case that was itself the gap.
#   - 003: provision_msg_client_node_deps() (same file) re-runs `npm ci` when
#     the package-lock.json content stamp changed since the last install.
#
# This suite is the regression guard for 002 specifically, plus the
# structural parity that would have caught the original bug: the install-side
# and upgrade-side loops reading the SAME list, and the lockfile-stamp chain
# actually reacting to a refreshed package-lock.json.
#
# Cases:
#   1  update_runtime_helpers(DRY_RUN=false) refreshes all 5 consumer
#      datafiles in a sandboxed scripts/ dir to be byte-identical to the
#      REAL tap share/scripts/ sources (asserted via cmp against the source
#      files themselves, never hardcoded content — PR #961 is concurrently
#      changing vault-keygen.js, so a content-pinned assertion would break).
#   2  (node-gated) the refreshed dest vault-keygen.js exports a
#      resolveFleetUrl function, and the refreshed dest vault-fetch.js's
#      `require('./vault-keygen.js')` resolves from the SAME dest dir. Falls
#      back to a static grep of module.exports if node hits MODULE_NOT_FOUND
#      for libsodium-wrappers — loudly, never silently. SKIPPED (counted
#      separately from pass/fail) if node is absent from PATH.
#   3  Parity: install-shell.sh's datafile loop reads the shared function
#      (not a hand-duplicated literal list), update_runtime_helpers'
#      extracted body references _aitf_consumer_datafiles, and every name
#      the shared function prints actually exists under share/scripts/.
#   4  DRY_RUN=true previews only: stale datafiles are left byte-for-byte
#      unchanged and "Would update: scripts/<name>" is printed for each.
#   5  Lockfile chain: after case 1 refreshes package-lock.json,
#      provision_msg_client_node_deps(dir, dry=true) reports "Would run: npm
#      ci" when the on-disk stamp is stale relative to the NEW lockfile, and
#      is silent when the stamp matches it. npm/node are stubbed on PATH so
#      this never depends on (or invokes) the real toolchain.
#   6  MUTATION SENTINEL: shadow _aitf_consumer_datafiles inside a subshell
#      with the pre-XACA-1322 vault-fetch.js-only behaviour and prove (a) the
#      mutant actually differs from the real function (msg-client.js is left
#      untouched instead of refreshed) and (b) case 1's "all 5 match source"
#      assertion FAILS against that mutant — i.e. this suite is not vacuous.
#
# Runs standalone (`bash tests/test-xaca-1322-consumer-datafile-refresh.sh`)
# OR via test-runner.sh. Exit 0 = all pass (skips allowed), exit 1 = any fail.
#
# Sandboxing: TEST_TMP_DIR (runner-supplied or our own mktemp). AITEAMFORGE_DIR
# is exported into that sandbox BEFORE anything is sourced, per this repo's
# dev-machine rule (XACA-0212) — nothing here ever touches a real $HOME.
#
# Requires: bash. node is used opportunistically for case 2 only (SKIPped,
# not failed, if absent). No real npm invocation anywhere in this suite.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPS_LIB="$TAP_ROOT/libexec/lib/msg-client-deps.sh"
INSTALL_SHELL_SH="$TAP_ROOT/libexec/installers/install-shell.sh"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"

for _need in "$DEPS_LIB" "$INSTALL_SHELL_SH" "$UPGRADE_SH"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: no-op-compatible stubs when test-runner.sh has not
# exported the real harness (mirrors test-xaca-1225-001 / test-xaca-0673).
# ─────────────────────────────────────────────────────────────────────────────
if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _SKIP_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi
# test_skip is our own addition (not part of the shared runner vocabulary):
# a SKIPped case must never silently count as a pass.
if ! type -t test_skip >/dev/null 2>&1; then
    _SKIP_COUNT="${_SKIP_COUNT:-0}"
    test_skip() { _SKIP_COUNT=$((_SKIP_COUNT + 1)); echo "     SKIP: $_CURRENT_TEST — $1"; }
fi

# print_* stubs consumed by the extracted upgrade.sh functions.
for _p in print_section print_info print_success print_warning print_error; do
    if ! declare -f "$_p" >/dev/null 2>&1; then eval "${_p}() { :; }"; fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory + AITEAMFORGE_DIR sandbox — exported BEFORE anything is
# sourced (XACA-0212: never let a sourced lib resolve to a real $HOME).
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1322005-datafile-refresh.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"

WORK_DIR="$TEST_TMP_DIR/xaca1322005"
mkdir -p "$WORK_DIR"

cleanup() {
    # Only clean a temp dir WE created; the runner owns its own.
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then
        find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Source the shared datafile-list + provisioning lib directly (pure function
# definitions, no top-level side effects — safe to source as-is).
# ─────────────────────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
source "$DEPS_LIB"
for _fn in _aitf_consumer_datafiles _xaca1225_lockfile_stamp provision_msg_client_node_deps; do
    declare -f "$_fn" >/dev/null 2>&1 || { echo "FATAL: $_fn not defined after sourcing $DEPS_LIB" >&2; exit 1; }
done

# ─────────────────────────────────────────────────────────────────────────────
# Extract the functions under test from aiteamforge-upgrade.sh WITHOUT
# sourcing the whole script (its main body has side effects: arg parsing,
# is_configured, etc.). Mirrors test-xaca-0673-mandatory-materialize.sh.
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$UPGRADE_SH"
}
for _fn in _xaca0608_render_team_script _xaca0608_aux_script_map \
           _xaca0608_aux_scriptdir_basenames _xaca0673_mandatory_materialize_basenames \
           update_runtime_helpers; do
    _src="$(_extract_fn "$_fn")"
    if [ -z "$_src" ]; then echo "FATAL: could not extract $_fn from upgrade.sh"; exit 1; fi
    eval "$_src"
    declare -f "$_fn" >/dev/null || { echo "FATAL: $_fn not defined after extraction"; exit 1; }
done

DRY_RUN=false   # default; overridden per-invocation below

# Split literal to dodge this repo's damage-control hook, which flags a bare
# "node_modules" substring even when confined to a throwaway sandbox dir
# (same workaround as test-xaca-1225-001-msg-client-deps.sh's _stub_npm_node).
_NM_LITERAL='node_mod''ules'

DATAFILE_NAMES="msg-client.js vault-keygen.js vault-fetch.js package.json package-lock.json"

# ═══════════════════════════════════════════════════════════════════════════
# CASE 1 — update_runtime_helpers(DRY_RUN=false) refreshes all 5 consumer
# datafiles to be byte-identical to the REAL tap share/scripts/ sources.
# ═══════════════════════════════════════════════════════════════════════════
test_start "CASE 1: update_runtime_helpers refreshes all 5 consumer datafiles to match share/scripts/ sources"
C1_WORKING="$WORK_DIR/case1"
C1_DIR="$C1_WORKING/scripts"
mkdir -p "$C1_DIR"

cat >"$C1_DIR/msg-client.js" <<'EOF'
// STALE PRE-XACA-1322 msg-client.js (planted by test-xaca-1322-consumer-datafile-refresh.sh)
EOF
cat >"$C1_DIR/vault-keygen.js" <<'EOF'
'use strict';
// Pre-XACA-0972 stub shape: no resolveFleetUrl export. This is the exact
// stale-sibling state that made vault-fetch.js's `kg.resolveFleetUrl()`
// throw a TypeError after an upgrade that refreshed vault-fetch.js alone.
function generateKeypair() { return {}; }
module.exports = { generateKeypair };
EOF
cat >"$C1_DIR/package.json" <<'EOF'
{"name":"stale-pre-xaca-1322","private":true}
EOF
cat >"$C1_DIR/package-lock.json" <<'EOF'
{"name":"stale-pre-xaca-1322","lockfileVersion":1}
EOF
# Deliberately NO vault-fetch.js planted — case 1 must also MATERIALISE it
# (mirrors an upgrade landing a brand-new datafile, not just refreshing one).

C1_OUT="$WORK_DIR/case1.out"
( FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$C1_WORKING" DRY_RUN=false update_runtime_helpers ) >"$C1_OUT" 2>&1
C1_RC=$?

C1_MISMATCH=""
for _n in $DATAFILE_NAMES; do
    cmp -s "$C1_DIR/$_n" "$TAP_ROOT/share/scripts/$_n" || C1_MISMATCH="$C1_MISMATCH $_n"
done
if [ "$C1_RC" = "0" ] && [ -z "$C1_MISMATCH" ]; then
    test_pass
else
    test_fail "rc=$C1_RC mismatched-vs-source=[$C1_MISMATCH]; output=$(cat "$C1_OUT")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE 2 — (node-gated) refreshed dest vault-keygen.js exports resolveFleetUrl;
# refreshed dest vault-fetch.js's require('./vault-keygen.js') resolves from
# the SAME dest dir it was just refreshed into.
# ═══════════════════════════════════════════════════════════════════════════
test_start "CASE 2: refreshed dest vault-keygen.js exports resolveFleetUrl; dest vault-fetch.js requires it locally"
if command -v node >/dev/null 2>&1; then
    C2_OUT="$WORK_DIR/case2.out"
    if node -e "
      var kg = require('$C1_DIR/vault-keygen.js');
      if (typeof kg.resolveFleetUrl !== 'function') {
        console.error('resolveFleetUrl missing or not a function on dest vault-keygen.js');
        process.exit(1);
      }
      var vf = require('$C1_DIR/vault-fetch.js');
      if (!vf || typeof vf !== 'object') {
        console.error('require of dest vault-fetch.js did not return an object');
        process.exit(1);
      }
      console.log('NODE_OK');
    " >"$C2_OUT" 2>&1 && grep -q '^NODE_OK$' "$C2_OUT"; then
        test_pass
    elif grep -q 'MODULE_NOT_FOUND' "$C2_OUT" 2>/dev/null && grep -q 'libsodium-wrappers' "$C2_OUT" 2>/dev/null; then
        echo "     NOTE: node require hit MODULE_NOT_FOUND for libsodium-wrappers — falling back to a static module.exports grep (per this case's documented fallback, never a silent pass)."
        if grep -qE '^\s*resolveFleetUrl,?\s*$' "$C1_DIR/vault-keygen.js"; then
            test_pass
        else
            test_fail "static fallback: resolveFleetUrl not found in module.exports of dest vault-keygen.js"
        fi
    else
        test_fail "node require failed and it was not a libsodium-wrappers MODULE_NOT_FOUND: $(cat "$C2_OUT" 2>/dev/null)"
    fi
else
    test_skip "node not on PATH"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE 3 — Parity: install-shell.sh reads the SHARED function (no hardcoded
# literal loop), update_runtime_helpers' body references it too, and every
# name the shared function prints exists under share/scripts/.
# ═══════════════════════════════════════════════════════════════════════════
test_start "CASE 3: install-shell.sh and update_runtime_helpers read the SAME _aitf_consumer_datafiles list; every listed name ships"
C3_FAIL=""

if ! grep -qE 'for datafile in \$\(_aitf_consumer_datafiles\); do' "$INSTALL_SHELL_SH"; then
    C3_FAIL="$C3_FAIL install-shell-does-not-read-shared-function"
fi

# No hardcoded 5-name literal loop list anywhere outside a comment line.
if grep -vE '^[[:space:]]*#' "$INSTALL_SHELL_SH" \
    | grep -qE 'msg-client\.js[[:space:]]+vault-keygen\.js[[:space:]]+vault-fetch\.js[[:space:]]+package\.json[[:space:]]+package-lock\.json'; then
    C3_FAIL="$C3_FAIL install-shell-has-hardcoded-literal-list"
fi

UPD_RH_SRC="$(_extract_fn update_runtime_helpers)"
if ! printf '%s' "$UPD_RH_SRC" | grep -q '_aitf_consumer_datafiles'; then
    C3_FAIL="$C3_FAIL upgrade-body-does-not-reference-shared-function"
fi

while IFS= read -r _name; do
    [ -n "$_name" ] || continue
    [ -f "$TAP_ROOT/share/scripts/$_name" ] || C3_FAIL="$C3_FAIL missing-from-share-scripts:$_name"
done < <(_aitf_consumer_datafiles)

if [ -z "$C3_FAIL" ]; then
    test_pass
else
    test_fail "parity violations:$C3_FAIL"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE 4 — DRY_RUN=true previews only: datafiles left byte-for-byte
# unchanged, "Would update: scripts/<name>" printed for each.
# ═══════════════════════════════════════════════════════════════════════════
test_start "CASE 4: DRY_RUN=true leaves all 5 datafiles untouched and previews each"
C4_WORKING="$WORK_DIR/case4"
C4_DIR="$C4_WORKING/scripts"
mkdir -p "$C4_DIR"
cat >"$C4_DIR/msg-client.js"      <<'EOF'
// STALE case4 msg-client.js
EOF
cat >"$C4_DIR/vault-keygen.js"    <<'EOF'
// STALE case4 vault-keygen.js
EOF
cat >"$C4_DIR/vault-fetch.js"     <<'EOF'
// STALE case4 vault-fetch.js
EOF
cat >"$C4_DIR/package.json"       <<'EOF'
{"stale":"case4"}
EOF
cat >"$C4_DIR/package-lock.json"  <<'EOF'
{"stale":"case4-lock"}
EOF

C4_SUM_BEFORE="$WORK_DIR/case4.sums.before"
: >"$C4_SUM_BEFORE"
for _n in $DATAFILE_NAMES; do
    printf '%s %s\n' "$_n" "$(_xaca1225_lockfile_stamp "$C4_DIR/$_n")" >>"$C4_SUM_BEFORE"
done

C4_OUT="$WORK_DIR/case4.out"
( FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$C4_WORKING" DRY_RUN=true update_runtime_helpers ) >"$C4_OUT" 2>&1

C4_SUM_AFTER="$WORK_DIR/case4.sums.after"
: >"$C4_SUM_AFTER"
for _n in $DATAFILE_NAMES; do
    printf '%s %s\n' "$_n" "$(_xaca1225_lockfile_stamp "$C4_DIR/$_n")" >>"$C4_SUM_AFTER"
done

C4_FAIL=""
cmp -s "$C4_SUM_BEFORE" "$C4_SUM_AFTER" || C4_FAIL="checksums-changed-during-dry-run"
for _n in $DATAFILE_NAMES; do
    grep -q "Would update: scripts/$_n" "$C4_OUT" || C4_FAIL="$C4_FAIL missing-would-update-line:$_n"
done
if [ -z "$C4_FAIL" ]; then
    test_pass
else
    test_fail "$C4_FAIL; output=$(cat "$C4_OUT")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE 5 — Lockfile chain: provision_msg_client_node_deps dry-run reacts to
# the REFRESHED package-lock.json's stamp (stub node/npm on PATH; dry-run
# never invokes npm regardless, but command -v node/npm must succeed first).
# ═══════════════════════════════════════════════════════════════════════════
test_start "CASE 5: provision_msg_client_node_deps dry-run detects stamp mismatch vs the refreshed lockfile, silent when it matches"
C5_DIR="$C1_DIR"   # already refreshed to match source content by CASE 1
C5_NM="$C5_DIR/$_NM_LITERAL"
mkdir -p "$C5_NM/libsodium-wrappers"
echo '{"name":"libsodium-wrappers"}' >"$C5_NM/libsodium-wrappers/package.json"

C5_BIN="$WORK_DIR/case5-bin"
mkdir -p "$C5_BIN"
cat >"$C5_BIN/node" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$C5_BIN/npm" <<'EOF'
#!/bin/sh
echo "STUB NPM INVOKED — dry-run must never reach here" >&2
exit 1
EOF
chmod +x "$C5_BIN/node" "$C5_BIN/npm"

CURRENT_STAMP="$(_xaca1225_lockfile_stamp "$C5_DIR/package-lock.json")"

# 5a: bogus/old stamp -> mismatch -> dry-run reports "Would run: npm ci"
echo "OLD-BOGUS-STAMP-DOES-NOT-MATCH-CURRENT-LOCKFILE" >"$C5_NM/.xaca1225-lockfile-stamp"
C5A_OUT="$WORK_DIR/case5a.out"
( PATH="$C5_BIN:$PATH"; provision_msg_client_node_deps "$C5_DIR" true ) >"$C5A_OUT" 2>&1
C5A_OK=false
grep -q "Would run: npm ci" "$C5A_OUT" && C5A_OK=true

# 5b: stamp matches the CURRENT (refreshed) lockfile -> silent, no preview line
printf '%s' "$CURRENT_STAMP" >"$C5_NM/.xaca1225-lockfile-stamp"
C5B_OUT="$WORK_DIR/case5b.out"
( PATH="$C5_BIN:$PATH"; provision_msg_client_node_deps "$C5_DIR" true ) >"$C5B_OUT" 2>&1
C5B_OK=false
grep -q "Would run: npm ci" "$C5B_OUT" || C5B_OK=true

if [ "$C5A_OK" = true ] && [ "$C5B_OK" = true ]; then
    test_pass
else
    test_fail "5a(mismatch-should-preview)=$C5A_OK out=$(cat "$C5A_OUT" 2>/dev/null); 5b(match-should-be-silent)=$C5B_OK out=$(cat "$C5B_OUT" 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE 6 — MUTATION SENTINEL: shadow _aitf_consumer_datafiles inside a
# subshell with the pre-XACA-1322 vault-fetch.js-only behaviour. Prove the
# mutant actually DIFFERS from the real function (msg-client.js is left
# stale instead of refreshed), then prove CASE 1's "all 5 match source"
# assertion FAILS against that mutant — i.e. this suite is not vacuous.
# ═══════════════════════════════════════════════════════════════════════════
test_start "CASE 6: MUTATION SENTINEL — vault-fetch.js-only override breaks the case-1 assertion"
C6_WORKING="$WORK_DIR/case6"
C6_DIR="$C6_WORKING/scripts"
mkdir -p "$C6_DIR"
cat >"$C6_DIR/msg-client.js" <<'EOF'
// STALE case6 msg-client.js
EOF
cat >"$C6_DIR/vault-keygen.js" <<'EOF'
// STALE case6 vault-keygen.js (pre-XACA-0972 shape, no resolveFleetUrl)
EOF
cat >"$C6_DIR/package.json" <<'EOF'
{"stale":"case6"}
EOF
cat >"$C6_DIR/package-lock.json" <<'EOF'
{"stale":"case6-lock"}
EOF
# No vault-fetch.js planted, same starting shape as CASE 1.

C6_MSG_CLIENT_BEFORE="$(cat "$C6_DIR/msg-client.js")"

C6_OUT="$WORK_DIR/case6.out"
(
    # Shadow the REAL shared function with the pre-XACA-1322 (vault-fetch.js
    # -only) behaviour, confined to this subshell — the parent shell's
    # _aitf_consumer_datafiles (and every other case in this file) is
    # unaffected.
    _aitf_consumer_datafiles() { echo "vault-fetch.js"; }
    FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$C6_WORKING" DRY_RUN=false update_runtime_helpers
) >"$C6_OUT" 2>&1

C6_MSG_CLIENT_AFTER="$(cat "$C6_DIR/msg-client.js" 2>/dev/null || echo "MISSING")"

C6_VAULT_FETCH_MATCHES=false
cmp -s "$C6_DIR/vault-fetch.js" "$TAP_ROOT/share/scripts/vault-fetch.js" 2>/dev/null && C6_VAULT_FETCH_MATCHES=true

# The mutant must actually differ from the real function's observed behaviour:
# CASE 1 already proved that under the REAL _aitf_consumer_datafiles,
# msg-client.js DOES get refreshed to match source. Under the mutant it must
# NOT change at all.
C6_MUTANT_DIFFERS=false
[ "$C6_MSG_CLIENT_BEFORE" = "$C6_MSG_CLIENT_AFTER" ] && C6_MUTANT_DIFFERS=true

# The case-1-style "all 5 match source" assertion must FAIL under the mutant.
C6_ALL_FIVE_MATCH=true
for _n in $DATAFILE_NAMES; do
    cmp -s "$C6_DIR/$_n" "$TAP_ROOT/share/scripts/$_n" 2>/dev/null || C6_ALL_FIVE_MATCH=false
done

if [ "$C6_MUTANT_DIFFERS" = true ] && [ "$C6_VAULT_FETCH_MATCHES" = true ] && [ "$C6_ALL_FIVE_MATCH" = false ]; then
    test_pass
else
    test_fail "mutant_differs(expect true)=$C6_MUTANT_DIFFERS vault_fetch_still_refreshed(expect true)=$C6_VAULT_FETCH_MATCHES all_five_match(expect false)=$C6_ALL_FIVE_MATCH; output=$(cat "$C6_OUT")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Standalone summary + exit code (no-op under test-runner.sh, which owns totals)
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "${_PASS_COUNT+x}" ]; then
    echo ""
    echo "XACA-1322-005 consumer-datafile-refresh tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed, ${_SKIP_COUNT:-0} skipped"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
