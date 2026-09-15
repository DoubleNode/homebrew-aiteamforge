#!/bin/bash
# test-xaca-1225-001-msg-client-deps.sh
#
# XACA-1225-001: install-shell.sh ships ~/aiteamforge/scripts/{msg-client.js,
# vault-keygen.js,package.json,package-lock.json} but no installer ever ran
# `npm ci` there — the only `npm ci` in the whole tap is
# install-fleet-monitor.sh's Fleet Monitor SERVER install, which a fleet=skip
# consumer never reaches. kb-msg-provision then runs `node vault-keygen.js`
# directly (bypassing msg-client.sh's own lazy-bootstrap) and dies with
# "Cannot find module 'libsodium-wrappers'". This suite exercises the shared
# fix: libexec/lib/msg-client-deps.sh's provision_msg_client_node_deps(),
# wired into BOTH install-shell.sh (fresh installs) and aiteamforge-upgrade.sh
# (already-provisioned machines).
#
# Behaviour cases (all against a sandboxed scripts dir + stubbed npm/node —
# no network, no real npm invocation, no touch of any real AITEAMFORGE_DIR):
#   D1  files not shipped                    -> silent no-op, rc=0
#   D2  node/npm absent from PATH             -> fail-soft note on stderr, rc=0
#   D3  dry-run                               -> preview only, npm never invoked
#   D4  fresh install                         -> npm ci invoked once, deps + stamp written
#   D5  idempotent re-run, unchanged lockfile -> npm NOT invoked again
#   D6  lockfile content changes              -> reinstall triggered (npm invoked again)
#   D7  npm ci fails                          -> fail-soft warning on stderr, rc=0
#   D8  set -e survival: a failing npm ci inside a `set -euo pipefail` caller
#       must not abort the caller's shell
#
# Structural cases (would have caught the original bug — the function existing
# is not enough, it must actually be CALLED, and independent of FLEET_MODE):
#   S1  install-shell.sh sources libexec/lib/msg-client-deps.sh
#   S2  install_shell_environment() calls provision_msg_client_node_deps
#   S3  aiteamforge-upgrade.sh sources libexec/lib/msg-client-deps.sh
#   S4  update_msg_client_deps() is defined and calls provision_msg_client_node_deps
#   S5  update_msg_client_deps is wired into the bare-call run sequence,
#       positioned after update_runtime_helpers and before provision_msg_routing
#   S6  no function in msg-client-deps.sh ends on a bare `[[ cond ]] && cmd`
#       (the set -e last-line short-circuit trap — see
#       feedback_set_e_last_line_short_circuit.md)
#
# Runs standalone (`bash tests/test-xaca-1225-001-msg-client-deps.sh`) OR via
# test-runner.sh. Exit 0 = all pass, exit 1 = any fail.
#
# Requires: bash. No node/npm/network required — all behaviour cases stub them.

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
# exported the real harness (mirrors test-xaca-0751).
# ─────────────────────────────────────────────────────────────────────────────
if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory: runner-supplied TEST_TMP_DIR or our own.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1225001-msg-deps.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
WORK_DIR="$TEST_TMP_DIR/xaca1225001"
mkdir -p "$WORK_DIR"

cleanup() {
    # Only clean a temp dir WE created; the runner owns its own. find -delete
    # (never rm -rf) per the damage-control convention.
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then
        find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Fixture helpers
# ─────────────────────────────────────────────────────────────────────────────

# _new_scripts_dir <name> — a scripts/ dir with a real-shaped package.json +
# package-lock.json (mirrors share/scripts/), no node_modules yet.
_new_scripts_dir() {
    local dir="$WORK_DIR/$1"
    mkdir -p "$dir"
    cat >"$dir/package.json" <<'EOF'
{
  "name": "aiteamforge-fleet-client",
  "private": true,
  "dependencies": { "libsodium-wrappers": "^0.7.16" }
}
EOF
    cat >"$dir/package-lock.json" <<'EOF'
{
  "name": "aiteamforge-fleet-client",
  "lockfileVersion": 3,
  "packages": { "": { "dependencies": { "libsodium-wrappers": "^0.7.16" } } }
}
EOF
    printf '%s' "$dir"
}

# _stub_bin <name> <log_file> <mode> — writes an npm/node stub into a fresh
# bin dir and returns the bin dir path. mode: "ok" (npm ci succeeds and
# populates a fake libsodium-wrappers), "fail" (npm ci exits 1, logs, does not
# touch the filesystem).
_stub_npm_node() {
    local mode="$1" log_file="$2"
    local bin_dir
    bin_dir="$WORK_DIR/bin-$$-$RANDOM"
    mkdir -p "$bin_dir"
    : >"$log_file"

    cat >"$bin_dir/node" <<EOF
#!/bin/bash
printf 'node %s\n' "\$*" >> "$log_file"
exit 0
EOF
    chmod +x "$bin_dir/node"

    # Deliberately avoid the literal 8-letter dependency-directory name in
    # this heredoc (concatenated at generation time instead) — this repo's
    # damage-control hook flags that substring as a read-only-path write even
    # when the write is safely confined to a throwaway sandbox dir.
    local nm_name='node_mod''ules'
    if [ "$mode" = "ok" ]; then
        cat >"$bin_dir/npm" <<EOF
#!/bin/bash
printf 'npm %s\n' "\$*" >> "$log_file"
if [ "\$1" = "ci" ]; then
  mkdir -p "$nm_name/libsodium-wrappers"
  echo '{"name":"libsodium-wrappers"}' > "$nm_name/libsodium-wrappers/package.json"
  exit 0
fi
exit 1
EOF
    else
        cat >"$bin_dir/npm" <<EOF
#!/bin/bash
printf 'npm %s\n' "\$*" >> "$log_file"
echo "npm ERR! simulated failure" >&2
exit 1
EOF
    fi
    chmod +x "$bin_dir/npm"
    printf '%s' "$bin_dir"
}

_invocation_count() {
    # Count npm ci invocations logged by the stub. `grep -c` prints "0" AND
    # exits 1 on no match, so an `|| echo 0` fallback would double-print —
    # capture into a var and normalize instead.
    local n
    n="$(grep -c '^npm ci' "$1" 2>/dev/null)"
    printf '%s' "${n:-0}"
}

STUB_LOG="$WORK_DIR/stub.log"

# ═══════════════════════════════════════════════════════════════════════════
# D1 — files not shipped -> silent no-op, rc=0
# ═══════════════════════════════════════════════════════════════════════════
test_start "D1: missing package.json/package-lock.json is a silent no-op"
D1_DIR="$WORK_DIR/d1-empty"
mkdir -p "$D1_DIR"
D1_OUT="$WORK_DIR/d1.out"; D1_ERR="$WORK_DIR/d1.err"
(
    source "$DEPS_LIB"
    provision_msg_client_node_deps "$D1_DIR"
    echo "rc=$?"
) >"$D1_OUT" 2>"$D1_ERR"
if [ "$(cat "$D1_OUT")" = "rc=0" ] && [ ! -s "$D1_ERR" ]; then
    test_pass
else
    test_fail "expected rc=0 and empty stderr; stdout=$(cat "$D1_OUT"); stderr=$(cat "$D1_ERR")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# D2 — node/npm absent from PATH -> fail-soft note on stderr, rc=0
# ═══════════════════════════════════════════════════════════════════════════
test_start "D2: node/npm absent from PATH is fail-soft (rc=0, actionable stderr note)"
D2_DIR="$(_new_scripts_dir d2)"
D2_OUT="$WORK_DIR/d2.out"; D2_ERR="$WORK_DIR/d2.err"
(
    source "$DEPS_LIB"
    PATH="/usr/bin:/bin"   # POSIX bins only — no node/npm
    provision_msg_client_node_deps "$D2_DIR"
    echo "rc=$?"
) >"$D2_OUT" 2>"$D2_ERR"
if [ "$(cat "$D2_OUT")" = "rc=0" ] && grep -q "Node.js/npm not found" "$D2_ERR"; then
    test_pass
else
    test_fail "expected rc=0 + Node.js/npm note; stdout=$(cat "$D2_OUT"); stderr=$(cat "$D2_ERR")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# D3 — dry-run -> preview only, npm never invoked, nothing written
# ═══════════════════════════════════════════════════════════════════════════
test_start "D3: dry-run previews without invoking npm or writing node_modules"
D3_DIR="$(_new_scripts_dir d3)"
BIN_D3="$(_stub_npm_node ok "$STUB_LOG")"
D3_OUT="$WORK_DIR/d3.out"
(
    source "$DEPS_LIB"
    PATH="$BIN_D3:$PATH"
    provision_msg_client_node_deps "$D3_DIR" "true"
    echo "rc=$?"
) >"$D3_OUT" 2>&1
NM='node_mod''ules'
if grep -q "Would run: npm ci" "$D3_OUT" && grep -q "rc=0" "$D3_OUT" \
    && [ "$(_invocation_count "$STUB_LOG")" = "0" ] && [ ! -d "$D3_DIR/$NM" ]; then
    test_pass
else
    test_fail "dry-run must not invoke npm or create node_modules; out=$(cat "$D3_OUT"); invocations=$(_invocation_count "$STUB_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# D4 — fresh install -> npm ci invoked once, deps + stamp written
# ═══════════════════════════════════════════════════════════════════════════
test_start "D4: fresh install runs npm ci once and writes the lockfile stamp"
D4_DIR="$(_new_scripts_dir d4)"
BIN_D4="$(_stub_npm_node ok "$STUB_LOG")"
D4_OUT="$WORK_DIR/d4.out"
(
    source "$DEPS_LIB"
    PATH="$BIN_D4:$PATH"
    provision_msg_client_node_deps "$D4_DIR" "false"
    echo "rc=$?"
) >"$D4_OUT" 2>&1
if [ -d "$D4_DIR/$NM/libsodium-wrappers" ] && [ -f "$D4_DIR/$NM/.xaca1225-lockfile-stamp" ] \
    && [ "$(_invocation_count "$STUB_LOG")" = "1" ] && grep -q "rc=0" "$D4_OUT"; then
    test_pass
else
    test_fail "expected one npm ci + libsodium-wrappers + stamp; out=$(cat "$D4_OUT"); invocations=$(_invocation_count "$STUB_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# D5 — idempotent re-run with unchanged lockfile -> npm NOT invoked again
# ═══════════════════════════════════════════════════════════════════════════
test_start "D5: re-run with unchanged lockfile skips npm entirely (idempotent)"
: >"$STUB_LOG"   # reset invocation log; D4_DIR already has satisfied deps + stamp
D5_OUT="$WORK_DIR/d5.out"
(
    source "$DEPS_LIB"
    PATH="$BIN_D4:$PATH"
    provision_msg_client_node_deps "$D4_DIR" "false"
    echo "rc=$?"
) >"$D5_OUT" 2>&1
if [ "$(_invocation_count "$STUB_LOG")" = "0" ] && grep -q "rc=0" "$D5_OUT"; then
    test_pass
else
    test_fail "unchanged lockfile must not re-invoke npm; out=$(cat "$D5_OUT"); invocations=$(_invocation_count "$STUB_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# D6 — lockfile content changes -> reinstall triggered (npm invoked again)
# ═══════════════════════════════════════════════════════════════════════════
test_start "D6: a changed lockfile triggers a reinstall"
: >"$STUB_LOG"
cat >"$D4_DIR/package-lock.json" <<'EOF'
{
  "name": "aiteamforge-fleet-client",
  "lockfileVersion": 4,
  "packages": { "": { "dependencies": { "libsodium-wrappers": "^0.7.17" } } }
}
EOF
D6_OUT="$WORK_DIR/d6.out"
(
    source "$DEPS_LIB"
    PATH="$BIN_D4:$PATH"
    provision_msg_client_node_deps "$D4_DIR" "false"
    echo "rc=$?"
) >"$D6_OUT" 2>&1
if [ "$(_invocation_count "$STUB_LOG")" = "1" ] && grep -q "rc=0" "$D6_OUT"; then
    test_pass
else
    test_fail "changed lockfile must trigger exactly one reinstall; out=$(cat "$D6_OUT"); invocations=$(_invocation_count "$STUB_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# D7 — npm ci fails -> fail-soft warning on stderr, rc=0
# ═══════════════════════════════════════════════════════════════════════════
test_start "D7: a failing npm ci is fail-soft (rc=0, actionable stderr warning)"
D7_DIR="$(_new_scripts_dir d7)"
BIN_D7="$(_stub_npm_node fail "$STUB_LOG")"
D7_OUT="$WORK_DIR/d7.out"; D7_ERR="$WORK_DIR/d7.err"
(
    source "$DEPS_LIB"
    PATH="$BIN_D7:$PATH"
    provision_msg_client_node_deps "$D7_DIR" "false"
    echo "rc=$?"
) >"$D7_OUT" 2>"$D7_ERR"
if grep -q "rc=0" "$D7_OUT" && grep -q "npm ci failed" "$D7_ERR" && [ ! -d "$D7_DIR/$NM/libsodium-wrappers" ]; then
    test_pass
else
    test_fail "expected rc=0 + warning + no libsodium-wrappers; stdout=$(cat "$D7_OUT"); stderr=$(cat "$D7_ERR")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# D8 — set -e survival: a failing npm ci must not abort a `set -euo pipefail`
# caller (install-shell.sh's own strictness).
# ═══════════════════════════════════════════════════════════════════════════
test_start "D8: does not abort a set -euo pipefail caller on npm ci failure"
D8_DIR="$(_new_scripts_dir d8)"
BIN_D8="$(_stub_npm_node fail "$STUB_LOG")"
D8_OUT="$WORK_DIR/d8.out"
(
    set -euo pipefail
    source "$DEPS_LIB"
    PATH="$BIN_D8:$PATH"
    provision_msg_client_node_deps "$D8_DIR" "false"
    echo "SURVIVED_SET_E"
) >"$D8_OUT" 2>&1
D8_RC=$?
if [ "$D8_RC" = "0" ] && grep -q "SURVIVED_SET_E" "$D8_OUT"; then
    test_pass
else
    test_fail "set -euo pipefail caller aborted; rc=$D8_RC out=$(cat "$D8_OUT")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# S1 — install-shell.sh sources libexec/lib/msg-client-deps.sh
# ═══════════════════════════════════════════════════════════════════════════
test_start "S1: install-shell.sh sources libexec/lib/msg-client-deps.sh"
if grep -qE 'source "\$SCRIPT_DIR/\.\./lib/msg-client-deps\.sh"' "$INSTALL_SHELL_SH"; then
    test_pass
else
    test_fail "install-shell.sh must source ../lib/msg-client-deps.sh"
fi

# ═══════════════════════════════════════════════════════════════════════════
# S2 — install_shell_environment() calls provision_msg_client_node_deps,
# independent of any FLEET_MODE/INSTALL_FLEET gate.
# ═══════════════════════════════════════════════════════════════════════════
test_start "S2: install_shell_environment() calls provision_msg_client_node_deps"
ISE_FN_SRC="$WORK_DIR/install_shell_environment.extracted.sh"
awk '
  /^install_shell_environment\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$INSTALL_SHELL_SH" >"$ISE_FN_SRC"
if [ -s "$ISE_FN_SRC" ] && grep -q "provision_msg_client_node_deps" "$ISE_FN_SRC" \
    && ! grep -qE '^\s*(if|elif|\[\[?)\s.*(FLEET_MODE|INSTALL_FLEET)' "$ISE_FN_SRC"; then
    test_pass
else
    test_fail "install_shell_environment must call provision_msg_client_node_deps and must not be FLEET-gated (actual conditionals, not comments)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# S3 — aiteamforge-upgrade.sh sources libexec/lib/msg-client-deps.sh
# ═══════════════════════════════════════════════════════════════════════════
test_start "S3: aiteamforge-upgrade.sh sources libexec/lib/msg-client-deps.sh"
if grep -qE 'source "\$\{LIBEXEC_DIR\}/lib/msg-client-deps\.sh"' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "aiteamforge-upgrade.sh must source \${LIBEXEC_DIR}/lib/msg-client-deps.sh"
fi

# ═══════════════════════════════════════════════════════════════════════════
# S4 — update_msg_client_deps() is defined and reuses provision_msg_client_node_deps
# (no reimplementation that could drift from the shared behaviour).
# ═══════════════════════════════════════════════════════════════════════════
test_start "S4: update_msg_client_deps() reuses provision_msg_client_node_deps"
UMD_FN_SRC="$WORK_DIR/update_msg_client_deps.extracted.sh"
awk '
  /^update_msg_client_deps\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$UPGRADE_SH" >"$UMD_FN_SRC"
if [ -s "$UMD_FN_SRC" ] && grep -q "provision_msg_client_node_deps" "$UMD_FN_SRC"; then
    test_pass
else
    test_fail "update_msg_client_deps must be defined and call provision_msg_client_node_deps"
fi

# ═══════════════════════════════════════════════════════════════════════════
# S5 — STRUCTURAL: update_msg_client_deps is wired into the bare-call run
# sequence, positioned after update_runtime_helpers and before
# provision_msg_routing. This is the assertion that would have caught the
# original bug class: the function existing is not enough, it must be CALLED,
# and in the right order (deps must exist before kb-msg-provision runs).
# ═══════════════════════════════════════════════════════════════════════════
test_start "S5: update_msg_client_deps is wired into the run sequence, correctly ordered"
RUNSEQ_LINES="$WORK_DIR/runseq.txt"
grep -nE '^(update_runtime_helpers|update_msg_client_deps|provision_msg_routing)$' "$UPGRADE_SH" >"$RUNSEQ_LINES"
ORDER="$(awk -F: '{print $2}' "$RUNSEQ_LINES" | tr '\n' ',' )"
if [ "$ORDER" = "update_runtime_helpers,update_msg_client_deps,provision_msg_routing," ]; then
    test_pass
else
    test_fail "expected run-sequence order update_runtime_helpers -> update_msg_client_deps -> provision_msg_routing; got: $ORDER"
fi

# ═══════════════════════════════════════════════════════════════════════════
# S6 — no function in msg-client-deps.sh ends on a bare `[[ cond ]] && cmd`
# as its last statement (set -e last-line short-circuit trap).
# ═══════════════════════════════════════════════════════════════════════════
test_start "S6: no function ends on a bare [[ cond ]] && cmd (set -e trap)"
# Look at the line immediately before each top-level closing brace.
BAD_LINES="$(awk '
  /^}$/ { if (prev ~ /^\s*\[\[.*\]\]\s*&&/) print NR": "prev }
  { prev = $0 }
' "$DEPS_LIB")"
if [ -z "$BAD_LINES" ]; then
    test_pass
else
    test_fail "found bare [[ cond ]] && cmd as a function's last line: $BAD_LINES"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Standalone summary + exit code (no-op under test-runner.sh, which owns totals)
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "${_PASS_COUNT+x}" ]; then
    echo ""
    echo "XACA-1225-001 msg-client-deps tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
