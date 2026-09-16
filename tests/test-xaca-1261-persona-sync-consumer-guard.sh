#!/bin/bash

# test-xaca-1261-persona-sync-consumer-guard.sh
# Regression tests for a blocking defect found while implementing XACA-1261:
# libexec/installers/install-claude-config.sh's invoke_persona_sync() gated an
# automatic `kb-sync-personas sync --all` WRITE on `command -v kb-sync-personas`
# -- a proxy for "am I the dev machine?" that only ever held because the tool
# had never been shipped anywhere else.
#
# DEFECT: XACA-1261 (this ticket) ships kb-sync-personas to EVERY tap consumer
# (install_kb_sync_personas_script() + the aux-script-map upgrade entry, see
# test-xaca-1261-persona-tool-delivery.sh), and kanban-helpers.sh already puts
# ${AITEAMFORGE_DIR}/scripts on PATH. So from this ticket forward,
# `command -v kb-sync-personas` resolves TRUE on a consumer whenever the
# installer/upgrade inherits a shell that has sourced kanban-helpers.sh --
# turning a routine install/upgrade into an UNREQUESTED `kb-sync-personas sync
# --all` WRITE across every team working dir registered in team-paths.json,
# including client-owned freelance repos. That write was never designed:
# XACA-1261-002 explicitly deferred the client-repo-write policy question to
# XACA-1260-002 on the stated assumption that consumer DELIVERY does not itself
# introduce a write. Shipping the tool without a guard here would have made
# that assumption false. (tests/test-xaca-0787-012-claude-config-flag-guard.sh
# already sanitises PATH around a related call in this same file, which is
# independent corroboration that ambient-PATH sensitivity here is real, not
# hypothetical.)
#
# FIX (already applied, uncommitted, in this same tap checkout): an early guard
# at the top of invoke_persona_sync() -- if ${HOME}/dev-team/.claude/agents-master
# is ABSENT (i.e. not a dev machine), log and `return 0`, preserving the
# consumer's pre-existing no-op exactly. This anchors on the same dev-master
# signal kb-sync-personas' own KBSP_MODE detection uses.
#
# THIS FILE:
#   TEST 1: with HOME pointed at a sandbox that has NO .claude/agents-master,
#           and a STUB kb-sync-personas present and resolvable on PATH,
#           invoke_persona_sync must NOT invoke the stub (no sentinel written)
#           and must return 0.
#   TEST 2: sanity/wiring check -- with HOME's .claude/agents-master PRESENT
#           (dev-machine shape), the SAME stub IS invoked (sentinel written).
#           This rules out "the stub never fires for some unrelated reason" as
#           an explanation for Test 1's pass -- the stub demonstrably works,
#           the guard is what suppresses it in Test 1.
#   TEST 3 (NEGATIVE CONTROL, LOAD-BEARING): re-run TEST 1's exact scenario
#           (same sandboxed HOME with agents-master ABSENT, same stub on PATH)
#           against the PRE-FIX invoke_persona_sync, materialized via
#           `git show HEAD:libexec/installers/install-claude-config.sh` (the
#           guard fix is uncommitted, so HEAD is exactly the pre-fix code).
#           The stub MUST be invoked (sentinel written) -- proving the guard is
#           load-bearing, not decorative: the pre-fix code cannot reproduce
#           Test 1's safe outcome.
#
# Per the "a non-zero exit is not proof your assertion fired" trap already hit
# once on this ticket: every assertion below reads the actual sentinel file
# and/or a recorded invocation log, never just an exit code.
#
# All filesystem activity is sandboxed: HOME is redirected to a throwaway
# mktemp dir for every invocation below -- NEVER the real $HOME. No real
# kb-sync-personas is ever put on PATH or invoked; only a local stub that
# writes a marker file.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAUDE_CONFIG_INSTALLER="$TAP_ROOT/libexec/installers/install-claude-config.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (works sourced by test-runner.sh OR invoked directly).
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

# log_* stubs used by invoke_persona_sync (both pre- and post-fix versions).
for _p in log_info log_success log_warning log_error; do
    if ! declare -f "$_p" >/dev/null 2>&1; then
        eval "${_p}() { :; }"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory (runner-supplied or our own). Unique per run.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1261-guard-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Function extraction (test-xaca-0673/0608/1261-delivery pattern): pull
# invoke_persona_sync's source text out of a file OR a git-show blob, without
# sourcing the whole installer (which has other top-level default-assignment
# side effects we don't need here).
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn_from_text() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' <<< "$2"
}

CURRENT_TEXT="$(cat "$CLAUDE_CONFIG_INSTALLER")"
PREFIX_TEXT="$(git -C "$TAP_ROOT" show HEAD:libexec/installers/install-claude-config.sh 2>/dev/null)"

if [ -z "$PREFIX_TEXT" ]; then
    echo "FATAL: could not materialize pre-fix (HEAD) install-claude-config.sh via git show -- needed for the required negative control." >&2
    exit 1
fi

INVOKE_POSTFIX="$(_extract_fn_from_text invoke_persona_sync "$CURRENT_TEXT")"
INVOKE_PREFIX="$(_extract_fn_from_text invoke_persona_sync "$PREFIX_TEXT")"

test_start "Sanity: invoke_persona_sync is extractable from BOTH the current (post-fix) and pre-fix (HEAD) install-claude-config.sh"
if [ -n "$INVOKE_POSTFIX" ] && [ -n "$INVOKE_PREFIX" ]; then
    test_pass
else
    test_fail "Extraction failed -- post-fix len=${#INVOKE_POSTFIX} pre-fix len=${#INVOKE_PREFIX}; cannot proceed"
fi

test_start "Sanity: the post-fix extraction actually differs from pre-fix (the guard text is really there)"
if [ "$INVOKE_POSTFIX" != "$INVOKE_PREFIX" ] && [[ "$INVOKE_POSTFIX" == *"agents-master"* ]]; then
    test_pass
else
    test_fail "post-fix invoke_persona_sync does not appear to contain the new agents-master guard -- did the fix land somewhere else?"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Build a stub kb-sync-personas on a scratch PATH dir. It records every
# invocation (args included) to a log file and touches a sentinel marker, then
# exits 0. This never touches any real team repo -- it is a pure recorder.
# ─────────────────────────────────────────────────────────────────────────────
_make_stub_bin() {
    local bindir="$1" sentinel="$2" logfile="$3"
    mkdir -p "$bindir"
    cat > "$bindir/kb-sync-personas" <<STUB
#!/bin/bash
echo "CALLED with args: \$*" >> "$logfile"
touch "$sentinel"
exit 0
STUB
    chmod +x "$bindir/kb-sync-personas"
}

# Runs invoke_persona_sync (given its extracted source text) with HOME and PATH
# overridden, capturing the function's own exit code via an explicit echo (the
# `cmd | tail` exit-code trap does not apply here -- no pipe is used -- but we
# still capture $? immediately, before any other command, per house style).
_run_invoke_persona_sync() {
    local fn_text="$1" home_dir="$2" stub_bindir="$3"
    (
        eval "$fn_text"
        HOME="$home_dir"
        PATH="${stub_bindir}:${PATH}"
        invoke_persona_sync
    )
    echo $?
}

# ═══════════════════════════════════════════════════════════════════════════
# TEST 1 — consumer shape (no dev-master), stub resolvable on PATH:
# invoke_persona_sync must NOT call it.
# ═══════════════════════════════════════════════════════════════════════════
T1_HOME="$TEST_TMP_DIR/t1-consumer-home"
mkdir -p "$T1_HOME"
T1_STUBBIN="$TEST_TMP_DIR/t1-stubbin"
T1_SENTINEL="$TEST_TMP_DIR/t1-sentinel"
T1_LOG="$TEST_TMP_DIR/t1-log"
_make_stub_bin "$T1_STUBBIN" "$T1_SENTINEL" "$T1_LOG"

test_start "TEST 1 precondition: sandbox HOME has NO \${HOME}/dev-team/.claude/agents-master (consumer shape)"
if [ ! -d "$T1_HOME/dev-team/.claude/agents-master" ]; then
    test_pass
else
    test_fail "Test setup error: T1_HOME should not have agents-master"
fi

T1_RC="$(_run_invoke_persona_sync "$INVOKE_POSTFIX" "$T1_HOME" "$T1_STUBBIN")"

test_start "TEST 1a: post-fix invoke_persona_sync returns 0 when agents-master is absent"
if [ "$T1_RC" = "0" ]; then
    test_pass
else
    test_fail "Expected return 0, got: $T1_RC"
fi

test_start "TEST 1b (the actual regression guard): post-fix invoke_persona_sync does NOT invoke kb-sync-personas when agents-master is absent, even though a stub IS resolvable on PATH"
if [ ! -e "$T1_SENTINEL" ]; then
    test_pass
else
    test_fail "Sentinel $T1_SENTINEL exists -- kb-sync-personas stub WAS invoked despite no dev-machine persona master. Log: $(cat "$T1_LOG" 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 2 — sanity/wiring: dev-machine shape (agents-master present) -> the
# SAME stub IS invoked. Rules out "the stub is broken / never fires" as an
# alternative explanation for Test 1b's pass.
# ═══════════════════════════════════════════════════════════════════════════
T2_HOME="$TEST_TMP_DIR/t2-devmachine-home"
mkdir -p "$T2_HOME/dev-team/.claude/agents-master"
T2_STUBBIN="$TEST_TMP_DIR/t2-stubbin"
T2_SENTINEL="$TEST_TMP_DIR/t2-sentinel"
T2_LOG="$TEST_TMP_DIR/t2-log"
_make_stub_bin "$T2_STUBBIN" "$T2_SENTINEL" "$T2_LOG"

T2_RC="$(_run_invoke_persona_sync "$INVOKE_POSTFIX" "$T2_HOME" "$T2_STUBBIN")"

test_start "TEST 2 (wiring sanity): with agents-master PRESENT (dev-machine shape), the stub IS invoked"
if [ -e "$T2_SENTINEL" ] && grep -q "sync --all" "$T2_LOG" 2>/dev/null; then
    test_pass
else
    test_fail "Expected the stub to be invoked with 'sync --all' when agents-master is present; sentinel exists=$([ -e "$T2_SENTINEL" ] && echo yes || echo no), log: $(cat "$T2_LOG" 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 3 — NEGATIVE CONTROL (LOAD-BEARING): re-run TEST 1's exact scenario
# (agents-master ABSENT, stub resolvable on PATH) against the PRE-FIX
# invoke_persona_sync. The stub MUST be invoked -- proving the guard, not
# some other factor, is what makes Test 1 pass post-fix.
# ═══════════════════════════════════════════════════════════════════════════
T3_HOME="$TEST_TMP_DIR/t3-consumer-home-prefix"
mkdir -p "$T3_HOME"
T3_STUBBIN="$TEST_TMP_DIR/t3-stubbin"
T3_SENTINEL="$TEST_TMP_DIR/t3-sentinel"
T3_LOG="$TEST_TMP_DIR/t3-log"
_make_stub_bin "$T3_STUBBIN" "$T3_SENTINEL" "$T3_LOG"

test_start "NEGATIVE CONTROL precondition: T3 sandbox HOME also has NO agents-master (identical shape to Test 1)"
if [ ! -d "$T3_HOME/dev-team/.claude/agents-master" ]; then
    test_pass
else
    test_fail "Test setup error: T3_HOME should not have agents-master"
fi

T3_RC="$(_run_invoke_persona_sync "$INVOKE_PREFIX" "$T3_HOME" "$T3_STUBBIN")"

test_start "NEGATIVE CONTROL (LOAD-BEARING): pre-fix invoke_persona_sync DOES invoke kb-sync-personas even with agents-master absent (proves the guard is load-bearing)"
echo "     [diagnostic] pre-fix invoke_persona_sync rc=$T3_RC"
echo "     [diagnostic] sentinel exists: $([ -e "$T3_SENTINEL" ] && echo yes || echo no)"
echo "     [diagnostic] stub invocation log:"
sed 's/^/       /' "$T3_LOG" 2>/dev/null || echo "       (no log -- stub was never called)"
if [ -e "$T3_SENTINEL" ] && grep -q "sync --all" "$T3_LOG" 2>/dev/null; then
    test_pass
else
    test_fail "REGRESSION IN THE NEGATIVE CONTROL ITSELF: pre-fix invoke_persona_sync did NOT invoke the stub under the same conditions Test 1 uses -- this control is supposed to demonstrate the pre-fix gap and just failed to. Either the extraction is wrong, or the pre-fix code is not what this test assumes."
fi

test_start "NEGATIVE CONTROL cross-check: pre-fix invoke_persona_sync's own source has NO agents-master guard text at all"
if [[ "$INVOKE_PREFIX" != *"agents-master"* ]]; then
    test_pass
else
    test_fail "Expected pre-fix invoke_persona_sync to contain NO reference to agents-master; found one -- HEAD may already include a form of this guard, invalidating the premise of this test file"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone only).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
