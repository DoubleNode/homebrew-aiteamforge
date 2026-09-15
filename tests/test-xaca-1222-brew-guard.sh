#!/bin/bash
# tests/test-xaca-1222-brew-guard.sh
#
# XACA-1222-004: negative control proving tests/lib/brew-guard.sh (XACA-1222)
# actually catches a real, unstubbed, MUTATING `brew` call — and that it does
# so WITHOUT ever reaching a real brew (a fake "real brew" stands in, so this
# suite is deterministic and network-free on a developer box AND on a
# brew-less ubuntu CI runner alike).
#
# SHELL: no self re-exec (tests/ci-manifest's XACA-0931 note: that workaround
# is for suites that must specifically verify /bin/bash 3.2 SHIPPED-CODE
# behaviour; this suite instead just writes itself in bash-3.2-safe syntax so
# it runs correctly under whichever bash invokes it — see the CI invocation
# note in the header of run_nested() below).
#
# WHAT THIS PROVES (mapped to XACA-1222-004's acceptance criteria):
#   1. Negative control THROUGH THE RUNNER: an unstubbed fixture that does
#      `brew install <bogus> || true` (mirroring install-team.sh's own
#      exit-swallowing pattern) is run via a NESTED `bash test-runner.sh`
#      (discovery mode, TEST_DIR pointed at a throwaway sandbox) and the
#      nested run is asserted to exit non-zero, print "BREW GUARD TRIPPED",
#      and name the blocked argv.
#   2. The real brew is NEVER invoked for the blocked call — a fake "real
#      brew" is placed first on PATH and records every invocation to a log
#      file; that log is asserted empty after the blocked negative control.
#   3. Positive controls: an allowlisted read-only call (`brew --prefix`)
#      passes through to the fake real brew and does not trip; an
#      unrecognized subcommand (`brew frobnicate`) trips; a suite that
#      prepends its OWN stub brew ahead of the guard is not tripped (its
#      stub wins — PATH is a stack).
#   4. Standalone: the same shape of fixture, when it `source`s
#      test-runner.sh directly (never calling main()), still gets the shim
#      installed and the blocked call still exits 97 with the loud message.
#   5. No-brew host: with NO brew anywhere on PATH, brew_guard_install must
#      leave PATH untouched and `command -v brew` must still fail.
#   6. Cleanup: the shim dir is removed when its OWNER process exits /
#      cleans up; a process that only INHERITED the guard (a child) must
#      never delete it.
#
# Fixtures are generated at RUNTIME under $TEST_TMP_DIR (never committed
# under tests/), specifically so a normal full `test-runner.sh` discovery
# run never picks them up (discover_tests() globs `$TEST_DIR/test-*.sh`,
# and our fixtures never live under the real tests/ directory).
#
# SANDBOX: HOME lives under TEST_TMP_DIR. No fixture here ever reaches a
# real brew — every nested/standalone invocation unsets the inherited
# AITEAMFORGE_BREW_GUARD_* vars and puts a FAKE "real brew" (never the host
# brew) first on PATH before the guard's own shim re-derives things.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER_PATH="$SCRIPT_DIR/test-runner.sh"
LIB_PATH="$SCRIPT_DIR/lib/brew-guard.sh"

for _need in "$RUNNER_PATH" "$LIB_PATH"; do
  if [ ! -f "$_need" ]; then
    echo "FATAL: required file not found: $_need" >&2
    exit 1
  fi
done

# ── Sandbox first — before any source/eval ─────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
  TEST_TMP_DIR="$(mktemp -d -t xaca1222bg-test.XXXXXX)"
  _OWN_TMP=true
else
  _OWN_TMP=false
fi
# Canonical path: macOS /var -> /private/var would otherwise make path
# comparisons (dir-exists checks below) disagree with what a subshell reports.
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
export TEST_TMP_DIR
WORK_DIR="$TEST_TMP_DIR/xaca1222bg"
mkdir -p "$WORK_DIR"
export HOME="$WORK_DIR/home"
mkdir -p "$HOME"
unset TMUX TMUX_PANE

cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

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

_tail() { tail -n 20 "$1" 2>/dev/null; }

# ═══════════════════════════════════════════════════════════════════════════
# Fake "real brew" — never the host brew. Logs every invocation (when
# AITEAMFORGE_TEST_FAKE_BREW_LOG is set) and always exits 0. This is what
# nested/standalone invocations resolve as `command -v brew` before the
# guard's own shim goes in front of it.
# ═══════════════════════════════════════════════════════════════════════════
FAKE_BREW_BIN_DIR="$WORK_DIR/fake-real-brew-bin"
mkdir -p "$FAKE_BREW_BIN_DIR"
cat > "$FAKE_BREW_BIN_DIR/brew" <<'FAKEBREW_EOF'
#!/bin/bash
# XACA-1222-004 fixture: stands in for the REAL brew. Never the host brew.
_log="${AITEAMFORGE_TEST_FAKE_BREW_LOG:-}"
if [ -n "$_log" ]; then
  echo "$*" >> "$_log"
fi
case "${1:-}" in
  --prefix) echo "/fake/homebrew/prefix" ;;
  --version) echo "Homebrew 0.0.0-fake" ;;
  *) : ;;
esac
exit 0
FAKEBREW_EOF
chmod +x "$FAKE_BREW_BIN_DIR/brew"

# run_nested <sandbox-dir> <out-log> [extra test-runner.sh args...]
#
# Invokes test-runner.sh as a fresh CHILD `bash` process (never as `sh`/zsh —
# test-runner.sh is bash-only) with:
#   - the inherited AITEAMFORGE_BREW_GUARD_* vars unset, so this child's own
#     top-level `brew_guard_install` call is NOT a no-op (it only no-ops when
#     ACTIVE=1 is already exported — see tests/lib/brew-guard.sh);
#   - PATH's first `brew` pointed at FAKE_BREW_BIN_DIR (never the host brew);
#   - TEST_DIR pointed at the given sandbox, so discover_tests() finds ONLY
#     the fixture(s) placed there.
# Whatever bash is first on the CALLER's PATH runs this child (unqualified
# `bash`) — this suite is written to be correct under 3.2 and 5.x alike, so
# it does not matter which one that is.
run_nested() {
  local _sbx="$1" _log="$2"
  shift 2
  (
    unset AITEAMFORGE_BREW_GUARD_ACTIVE AITEAMFORGE_BREW_GUARD_DIR \
          AITEAMFORGE_BREW_GUARD_MARKER AITEAMFORGE_BREW_GUARD_OWNER_PID \
          AITEAMFORGE_BREW_GUARD_REAL_BREW
    export PATH="$FAKE_BREW_BIN_DIR:$PATH"
    export TEST_DIR="$_sbx"
    bash "$RUNNER_PATH" "$@"
  ) >"$_log" 2>&1
  return $?
}

# ═══════════════════════════════════════════════════════════════════════════
# (1)+(2) Negative control: unstubbed, swallowed `brew install` — through
# the runner, via discovery, in a nested child.
# ═══════════════════════════════════════════════════════════════════════════
NEG_DIR="$WORK_DIR/sbx-negative"
mkdir -p "$NEG_DIR"
cat > "$NEG_DIR/test-xaca-1222-ctrl-negative.sh" <<'FIXTURE_EOF'
#!/bin/bash
# Deliberately UNSTUBBED. Mirrors install-team.sh's own
# `brew install "$dep" || { warn ...; }` exit-swallowing pattern.
echo "fixture: calling brew install (unstubbed, negative control)"
brew install xaca-1222-nonexistent-formula || true
echo "fixture: continued after swallowed exit"
exit 0
FIXTURE_EOF
chmod +x "$NEG_DIR/test-xaca-1222-ctrl-negative.sh"

NEG_LOG="$WORK_DIR/nested-negative.log"
NEG_CALL_LOG="$WORK_DIR/neg-fake-brew-calls.log"
: > "$NEG_CALL_LOG"
# VERBOSE=true (env, not the -v CLI flag): brew_guard_install runs at
# test-runner.sh TOP LEVEL, before main() ever parses argv, so a -v flag
# arrives too late to affect its own "installed (shim=...)" verbose line —
# only a pre-exported VERBOSE env var is visible at that point in time.
AITEAMFORGE_TEST_FAKE_BREW_LOG="$NEG_CALL_LOG" VERBOSE=true run_nested "$NEG_DIR" "$NEG_LOG"
NEG_RC=$?

test_start "NEG1: nested runner exits non-zero for an unstubbed, swallowed 'brew install' fixture"
if [ "$NEG_RC" -ne 0 ]; then
  test_pass
else
  test_fail "nested run exited 0 — the guard did not fail the run. Log tail:
$(_tail "$NEG_LOG")"
fi

test_start "NEG2: nested output contains the BREW GUARD TRIPPED marker"
if grep -F -q -- "BREW GUARD TRIPPED" "$NEG_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "no 'BREW GUARD TRIPPED' in nested output. Log tail:
$(_tail "$NEG_LOG")"
fi

test_start "NEG3: nested output names the blocked argv (brew install xaca-1222-nonexistent-formula)"
if grep -F -q -- "brew install xaca-1222-nonexistent-formula" "$NEG_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "blocked argv not named in output. Log tail:
$(_tail "$NEG_LOG")"
fi

test_start "NEG4: the fake 'real brew' was NEVER invoked for the blocked install"
if [ ! -s "$NEG_CALL_LOG" ]; then
  test_pass
else
  test_fail "fake real brew recorded call(s) it should never have received: $(cat "$NEG_CALL_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# (6a) Cleanup, real-world half: the shim dir the NESTED runner (above)
# created for itself must be gone once that child process has exited.
# Requires -v on the run above so brew_guard_install's verbose line
# ("installed (shim=<dir>/brew, ...)") is in the log to extract from.
# ═══════════════════════════════════════════════════════════════════════════
test_start "CLEANUP1: the nested runner's own shim dir is removed after it exits"
_neg_shim_dir="$(sed -n 's/.*shim=\(.*\)\/brew,.*/\1/p' "$NEG_LOG" 2>/dev/null | head -1)"
if [ -z "$_neg_shim_dir" ]; then
  test_fail "could not extract a shim dir from the nested (-v) log — cannot check its removal. Log tail:
$(_tail "$NEG_LOG")"
elif [ ! -d "$_neg_shim_dir" ]; then
  test_pass
else
  test_fail "shim dir $_neg_shim_dir still exists after the owning nested runner exited"
fi

# ═══════════════════════════════════════════════════════════════════════════
# (3a) Positive control: an allowlisted read-only call passes through to the
# fake real brew and does not trip the guard.
# ═══════════════════════════════════════════════════════════════════════════
POS_DIR="$WORK_DIR/sbx-allow"
mkdir -p "$POS_DIR"
cat > "$POS_DIR/test-xaca-1222-ctrl-allow.sh" <<'FIXTURE_EOF'
#!/bin/bash
out="$(brew --prefix)"
echo "fixture: brew --prefix -> $out"
brew tap
exit 0
FIXTURE_EOF
chmod +x "$POS_DIR/test-xaca-1222-ctrl-allow.sh"

POS_LOG="$WORK_DIR/nested-allow.log"
POS_CALL_LOG="$WORK_DIR/pos-fake-brew-calls.log"
: > "$POS_CALL_LOG"
AITEAMFORGE_TEST_FAKE_BREW_LOG="$POS_CALL_LOG" run_nested "$POS_DIR" "$POS_LOG"
POS_RC=$?

test_start "POS1: nested runner exits 0 for an allowlisted read-only call (brew --prefix)"
if [ "$POS_RC" -eq 0 ]; then
  test_pass
else
  test_fail "nested run exited $POS_RC — expected 0. Log tail:
$(_tail "$POS_LOG")"
fi

test_start "POS2: an allowlisted call does NOT trip the guard"
if grep -F -q -- "BREW GUARD TRIPPED" "$POS_LOG" 2>/dev/null; then
  test_fail "guard tripped on an allowlisted call. Log tail:
$(_tail "$POS_LOG")"
else
  test_pass
fi

test_start "POS3: the allowlisted call actually reached the fake real brew"
if grep -F -q -- "--prefix" "$POS_CALL_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "fake real brew never saw the --prefix call: $(cat "$POS_CALL_LOG" 2>/dev/null)"
fi

test_start "POS4: a BARE 'brew tap' (list-only, as doctor/setup call it) passes through"
if grep -x -q -- "tap" "$POS_CALL_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "fake real brew never saw the bare tap call: $(cat "$POS_CALL_LOG" 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# (3b) Positive control: an unrecognized subcommand trips the guard.
# ═══════════════════════════════════════════════════════════════════════════
UNREC_DIR="$WORK_DIR/sbx-unrecognized"
mkdir -p "$UNREC_DIR"
cat > "$UNREC_DIR/test-xaca-1222-ctrl-unrecognized.sh" <<'FIXTURE_EOF'
#!/bin/bash
echo "fixture: calling brew frobnicate (unrecognized subcommand)"
brew frobnicate --foo-flag || true
brew tap doublenode/xaca-1222-fake || true
echo "fixture: continued after swallowed exit"
exit 0
FIXTURE_EOF
chmod +x "$UNREC_DIR/test-xaca-1222-ctrl-unrecognized.sh"

UNREC_LOG="$WORK_DIR/nested-unrecognized.log"
UNREC_CALL_LOG="$WORK_DIR/unrec-fake-brew-calls.log"
: > "$UNREC_CALL_LOG"
AITEAMFORGE_TEST_FAKE_BREW_LOG="$UNREC_CALL_LOG" run_nested "$UNREC_DIR" "$UNREC_LOG"
UNREC_RC=$?

test_start "UNREC1: nested runner exits non-zero for an unrecognized brew subcommand"
if [ "$UNREC_RC" -ne 0 ]; then
  test_pass
else
  test_fail "nested run exited 0 for 'brew frobnicate'. Log tail:
$(_tail "$UNREC_LOG")"
fi

test_start "UNREC2: nested output names the blocked argv (brew frobnicate --foo-flag)"
if grep -F -q -- "brew frobnicate --foo-flag" "$UNREC_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "blocked argv not named in output. Log tail:
$(_tail "$UNREC_LOG")"
fi

test_start "UNREC4: 'brew tap <name>' (with an argument) is blocked, unlike bare 'brew tap'"
if grep -F -q -- "brew tap doublenode/xaca-1222-fake" "$UNREC_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "guard did not report blocking brew tap <name>. Log tail:
$(_tail "$UNREC_LOG")"
fi

test_start "UNREC3: the fake 'real brew' was never invoked for the unrecognized subcommand"
if [ ! -s "$UNREC_CALL_LOG" ]; then
  test_pass
else
  test_fail "fake real brew recorded call(s) it should never have received: $(cat "$UNREC_CALL_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# (3c) Positive control: a suite that prepends its OWN stub brew ahead of
# the guard is not tripped — PATH is a stack, the suite's own stub wins.
# ═══════════════════════════════════════════════════════════════════════════
OWNSTUB_DIR="$WORK_DIR/sbx-ownstub"
mkdir -p "$OWNSTUB_DIR"
cat > "$OWNSTUB_DIR/test-xaca-1222-ctrl-ownstub.sh" <<'FIXTURE_EOF'
#!/bin/bash
# This suite installs its OWN brew stub, ahead of whatever is already on
# PATH (including the XACA-1222 guard's shim, which test-runner.sh already
# prepended before this fixture ran) — exactly the pattern several existing
# suites (test-xaca-1216-flat-persona-deploy.sh, etc.) already use.
_stubdir="$(mktemp -d)"
_stub_cleanup() { rm -rf "$_stubdir"; }
trap _stub_cleanup EXIT
cat > "$_stubdir/brew" <<'STUBEOF'
#!/bin/bash
exit 0
STUBEOF
chmod +x "$_stubdir/brew"
export PATH="$_stubdir:$PATH"
brew install xaca-1222-suite-owns-its-stub || true
echo "fixture: suite-own-stub scenario completed"
exit 0
FIXTURE_EOF
chmod +x "$OWNSTUB_DIR/test-xaca-1222-ctrl-ownstub.sh"

OWNSTUB_LOG="$WORK_DIR/nested-ownstub.log"
OWNSTUB_CALL_LOG="$WORK_DIR/ownstub-fake-brew-calls.log"
: > "$OWNSTUB_CALL_LOG"
AITEAMFORGE_TEST_FAKE_BREW_LOG="$OWNSTUB_CALL_LOG" run_nested "$OWNSTUB_DIR" "$OWNSTUB_LOG"
OWNSTUB_RC=$?

test_start "OWNSTUB1: nested runner exits 0 when the suite's own stub brew wins the PATH race"
if [ "$OWNSTUB_RC" -eq 0 ]; then
  test_pass
else
  test_fail "nested run exited $OWNSTUB_RC — expected 0. Log tail:
$(_tail "$OWNSTUB_LOG")"
fi

test_start "OWNSTUB2: guard is NOT tripped when the suite's own stub intercepts brew first"
if grep -F -q -- "BREW GUARD TRIPPED" "$OWNSTUB_LOG" 2>/dev/null; then
  test_fail "guard tripped even though the suite's own stub should have won. Log tail:
$(_tail "$OWNSTUB_LOG")"
else
  test_pass
fi

test_start "OWNSTUB3: neither the guard shim nor the fake real brew ever saw this call"
if [ ! -s "$OWNSTUB_CALL_LOG" ]; then
  test_pass
else
  test_fail "fake real brew recorded a call it should never have received (the suite's own stub should have intercepted first): $(cat "$OWNSTUB_CALL_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# (4) Standalone: a fixture that `source`s test-runner.sh directly (never
# calling main()) still gets the shim installed, and the blocked call still
# exits 97 with the loud message.
# ═══════════════════════════════════════════════════════════════════════════
STANDALONE_DIR="$WORK_DIR/sbx-standalone"
mkdir -p "$STANDALONE_DIR"
STANDALONE_FIXTURE="$STANDALONE_DIR/fixture-standalone.sh"
{
  printf '#!/bin/bash\n'
  printf 'source %q\n' "$RUNNER_PATH"
  printf 'echo "fixture: AITEAMFORGE_BREW_GUARD_ACTIVE after source = ${AITEAMFORGE_BREW_GUARD_ACTIVE:-<unset>}"\n'
  printf 'brew install xaca-1222-standalone-nonexistent\n'
  printf 'echo "fixture: reached after blocked call (should NOT print — set -e from test-runner.sh must have aborted first)"\n'
} > "$STANDALONE_FIXTURE"
chmod +x "$STANDALONE_FIXTURE"

STANDALONE_LOG="$WORK_DIR/standalone.log"
STANDALONE_CALL_LOG="$WORK_DIR/standalone-fake-brew-calls.log"
: > "$STANDALONE_CALL_LOG"
(
  unset AITEAMFORGE_BREW_GUARD_ACTIVE AITEAMFORGE_BREW_GUARD_DIR \
        AITEAMFORGE_BREW_GUARD_MARKER AITEAMFORGE_BREW_GUARD_OWNER_PID \
        AITEAMFORGE_BREW_GUARD_REAL_BREW
  export PATH="$FAKE_BREW_BIN_DIR:$PATH"
  export AITEAMFORGE_TEST_FAKE_BREW_LOG="$STANDALONE_CALL_LOG"
  bash "$STANDALONE_FIXTURE"
) >"$STANDALONE_LOG" 2>&1
STANDALONE_RC=$?

test_start "STANDALONE1: sourcing test-runner.sh directly still installs the shim (ACTIVE=1)"
if grep -F -q -- "AITEAMFORGE_BREW_GUARD_ACTIVE after source = 1" "$STANDALONE_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "shim was not reported active after a bare 'source test-runner.sh'. Log tail:
$(_tail "$STANDALONE_LOG")"
fi

test_start "STANDALONE2: the blocked call exits 97 when invoked standalone"
if [ "$STANDALONE_RC" -eq 97 ]; then
  test_pass
else
  test_fail "expected exit 97, got $STANDALONE_RC. Log tail:
$(_tail "$STANDALONE_LOG")"
fi

test_start "STANDALONE3: the loud XACA-1222 BREW GUARD message is printed, naming the blocked argv"
if grep -F -q -- "XACA-1222 BREW GUARD" "$STANDALONE_LOG" 2>/dev/null \
   && grep -F -q -- "brew install xaca-1222-standalone-nonexistent" "$STANDALONE_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "loud message and/or blocked argv not found. Log tail:
$(_tail "$STANDALONE_LOG")"
fi

test_start "STANDALONE4: the script never reached the line after the blocked call ('set -e' from test-runner.sh took effect)"
if grep -F -q -- "reached after blocked call" "$STANDALONE_LOG" 2>/dev/null; then
  test_fail "the fixture continued past the blocked call — set -e did not abort it as expected. Log tail:
$(_tail "$STANDALONE_LOG")"
else
  test_pass
fi

test_start "STANDALONE5: the fake real brew was never invoked for the standalone blocked call"
if [ ! -s "$STANDALONE_CALL_LOG" ]; then
  test_pass
else
  test_fail "fake real brew recorded call(s) it should never have received: $(cat "$STANDALONE_CALL_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# (5) No-brew host: with NO brew anywhere on PATH, brew_guard_install must
# leave PATH untouched and `command -v brew` must still fail afterward.
# ═══════════════════════════════════════════════════════════════════════════
# Build a PATH with every directory that contains a `brew` executable
# stripped out, rather than a hand-rolled minimal PATH — this keeps normal
# tools (mktemp, chmod, date, cat, ...) available so a real defect in
# brew_guard_install (e.g. touching PATH even when it shouldn't) is not
# masked by an unrelated "command not found" from some OTHER tool.
_nobrew_path=""
_old_ifs="$IFS"
IFS=':'
for _d in $PATH; do
  [ -n "$_d" ] || continue
  if [ ! -x "$_d/brew" ]; then
    if [ -z "$_nobrew_path" ]; then
      _nobrew_path="$_d"
    else
      _nobrew_path="$_nobrew_path:$_d"
    fi
  fi
done
IFS="$_old_ifs"

NOBREW_LOG="$WORK_DIR/nobrew.log"
(
  unset AITEAMFORGE_BREW_GUARD_ACTIVE AITEAMFORGE_BREW_GUARD_DIR \
        AITEAMFORGE_BREW_GUARD_MARKER AITEAMFORGE_BREW_GUARD_OWNER_PID \
        AITEAMFORGE_BREW_GUARD_REAL_BREW
  export PATH="$_nobrew_path"
  echo "PATH_BEFORE=$PATH"
  source "$LIB_PATH"
  brew_guard_install
  echo "PATH_AFTER=$PATH"
  if command -v brew >/dev/null 2>&1; then
    echo "BREW_FOUND=yes"
  else
    echo "BREW_FOUND=no"
  fi
  echo "ACTIVE=${AITEAMFORGE_BREW_GUARD_ACTIVE:-<unset>}"
) >"$NOBREW_LOG" 2>&1
NOBREW_RC=$?

test_start "NOBREW1: no-brew subshell setup itself succeeded (rc 0)"
if [ "$NOBREW_RC" -eq 0 ]; then
  test_pass
else
  test_fail "the no-brew subshell exited $NOBREW_RC unexpectedly. Log tail:
$(_tail "$NOBREW_LOG")"
fi

test_start "NOBREW2: brew_guard_install leaves PATH unchanged when no real brew is present"
_nb_before="$(grep '^PATH_BEFORE=' "$NOBREW_LOG" 2>/dev/null | sed 's/^PATH_BEFORE=//')"
_nb_after="$(grep '^PATH_AFTER=' "$NOBREW_LOG" 2>/dev/null | sed 's/^PATH_AFTER=//')"
if [ -n "$_nb_before" ] && [ "$_nb_before" = "$_nb_after" ]; then
  test_pass
else
  test_fail "PATH changed (or could not be read): before=[$_nb_before] after=[$_nb_after]"
fi

test_start "NOBREW3: 'command -v brew' still fails after brew_guard_install on a brew-less host"
if grep -F -q -- "BREW_FOUND=no" "$NOBREW_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "expected BREW_FOUND=no. Log tail:
$(_tail "$NOBREW_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# (6b)+(6c) Cleanup unit test: the OWNER process removes the shim dir on
# brew_guard_cleanup; a CHILD process that only inherited the guard (via
# export) must never delete it, even if it calls brew_guard_cleanup itself.
# ═══════════════════════════════════════════════════════════════════════════
CLEANUP_LOG="$WORK_DIR/cleanup-unit.log"
(
  unset AITEAMFORGE_BREW_GUARD_ACTIVE AITEAMFORGE_BREW_GUARD_DIR \
        AITEAMFORGE_BREW_GUARD_MARKER AITEAMFORGE_BREW_GUARD_OWNER_PID \
        AITEAMFORGE_BREW_GUARD_REAL_BREW
  export PATH="$FAKE_BREW_BIN_DIR:$PATH"
  source "$LIB_PATH"
  brew_guard_install
  echo "SHIM_DIR=${AITEAMFORGE_BREW_GUARD_DIR:-}"
  echo "OWNER_PID=${AITEAMFORGE_BREW_GUARD_OWNER_PID:-}"
  echo "MY_PID=$$"

  # A child process inherits ACTIVE/DIR/OWNER_PID/etc via export. It must
  # NOT be able to delete the shim dir, even if it explicitly tries to.
  bash -c 'source "'"$LIB_PATH"'"; brew_guard_cleanup; echo "child cleanup rc=$?"'

  if [ -d "${AITEAMFORGE_BREW_GUARD_DIR:-/nonexistent-xaca1222-004}" ]; then
    echo "AFTER_CHILD_CLEANUP=EXISTS"
  else
    echo "AFTER_CHILD_CLEANUP=GONE"
  fi

  _saved_dir="${AITEAMFORGE_BREW_GUARD_DIR:-}"
  brew_guard_cleanup
  if [ -n "$_saved_dir" ] && [ -d "$_saved_dir" ]; then
    echo "AFTER_OWNER_CLEANUP=EXISTS"
  else
    echo "AFTER_OWNER_CLEANUP=GONE"
  fi
) >"$CLEANUP_LOG" 2>&1
CLEANUP_SUB_RC=$?

test_start "CLEANUP2: a child process that only inherited the guard does NOT delete the shim dir"
if [ "$CLEANUP_SUB_RC" -ne 0 ]; then
  test_fail "cleanup-unit subshell itself exited $CLEANUP_SUB_RC unexpectedly. Log tail:
$(_tail "$CLEANUP_LOG")"
elif grep -F -q -- "AFTER_CHILD_CLEANUP=EXISTS" "$CLEANUP_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "shim dir was removed by (or before) the child's own cleanup call — owner-PID gating did not hold. Log tail:
$(_tail "$CLEANUP_LOG")"
fi

test_start "CLEANUP3: the OWNER process's own brew_guard_cleanup DOES remove the shim dir"
if grep -F -q -- "AFTER_OWNER_CLEANUP=GONE" "$CLEANUP_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "shim dir still present after the owning process called brew_guard_cleanup. Log tail:
$(_tail "$CLEANUP_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# XACA-1222 BLOCKING FIX regression: SIG1-4 — a signal mid-suite must stop
# the runner outright, never let it resume the for-loop with a possibly-
# lost guard (the exact incident scenario: a hung suite gets Ctrl-C'd,
# cleanup deletes the shim dir, and the OLD shared EXIT/INT/TERM trap let
# execution fall through to the next suite with a real, unstubbed brew on
# PATH and nothing left to notice).
#
# Two fixtures, discovered in order by test-runner.sh's own `sort` (A before
# B): A sends SIGTERM to its own parent (the nested runner — run_test_file()
# invokes each suite as a direct child `bash "$test_file"`, so $PPID there
# IS the runner's PID) and then sleeps, so a regression that resumes the
# loop has a real window in which B could still run before A's own sleep
# ends; B just writes a marker file to prove whether it ran at all.
# ═══════════════════════════════════════════════════════════════════════════
SIG_DIR="$WORK_DIR/sbx-sig"
mkdir -p "$SIG_DIR"
SIG_B_MARKER="$WORK_DIR/sig-b-ran.marker"
rm -f "$SIG_B_MARKER"
export XACA1222_SIG_B_MARKER="$SIG_B_MARKER"

cat > "$SIG_DIR/test-xaca-1222-sigterm-a.sh" <<'FIXTURE_EOF'
#!/bin/bash
# Sorts before sigterm-b.sh. Sends TERM to the runner (its own $PPID, since
# run_test_file() runs `bash "$test_file"` directly, no intermediate fork)
# then sleeps -- if the fix regresses and the runner resumes its for-loop
# instead of exiting, this window gives sigterm-b.sh a real chance to run
# before this process itself wakes back up.
echo "fixture SIG-A: sending TERM to runner pid $PPID"
kill -TERM "$PPID" 2>/dev/null || true
sleep 2
echo "fixture SIG-A: woke up after sleep"
exit 0
FIXTURE_EOF
chmod +x "$SIG_DIR/test-xaca-1222-sigterm-a.sh"

cat > "$SIG_DIR/test-xaca-1222-sigterm-b.sh" <<'FIXTURE_EOF'
#!/bin/bash
: > "${XACA1222_SIG_B_MARKER:?marker path not set}"
echo "fixture SIG-B: ran, marker written"
exit 0
FIXTURE_EOF
chmod +x "$SIG_DIR/test-xaca-1222-sigterm-b.sh"

SIG_LOG="$WORK_DIR/nested-sig.log"
: > "$SIG_LOG"
# Manual background+watchdog timeout (no dependency on GNU coreutils
# timeout/gtimeout, not guaranteed present on a bare macOS runner --
# same idiom as test-xaca-1162-dry-run-is-read-only.sh's run_case()). This
# is purely a backstop in case the fix under test is badly broken (e.g. the
# runner hangs instead of exiting); the primary mechanism is the direct
# SIGTERM sent by fixture A above, which should make the nested runner
# exit almost immediately.
VERBOSE=true run_nested "$SIG_DIR" "$SIG_LOG" &
SIG_PID=$!
( sleep 20; kill -9 "$SIG_PID" 2>/dev/null ) &
SIG_WATCHER=$!
wait "$SIG_PID" 2>/dev/null
SIG_RC=$?
kill "$SIG_WATCHER" 2>/dev/null
wait "$SIG_WATCHER" 2>/dev/null

test_start "SIG1: nested runner exits non-zero when TERM'd mid-suite (does not silently swallow the signal)"
if [ "$SIG_RC" -ne 0 ]; then
  test_pass
else
  test_fail "nested run exited 0 after receiving TERM mid-suite. Log tail:
$(_tail "$SIG_LOG")"
fi

test_start "SIG2: suite B (sorts after A) never ran after the runner was TERM'd mid-A -- its marker was never written"
if [ ! -f "$SIG_B_MARKER" ]; then
  test_pass
else
  test_fail "SIG-B's marker exists -- the runner resumed its for-loop after being interrupted instead of exiting (the XACA-1222 BLOCKING incident shape). Log tail:
$(_tail "$SIG_LOG")"
fi

test_start "SIG3: nested output shows the runner's OWN interrupt handler fired (not just killed from outside)"
if grep -F -q -- "interrupted (SIGTERM)" "$SIG_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "expected an 'interrupted (SIGTERM)' notice in nested output. Log tail:
$(_tail "$SIG_LOG")"
fi

test_start "SIG4: the nested runner's own shim dir was still cleaned up despite exiting via the TERM handler (EXIT trap still ran)"
_sig_shim_dir="$(sed -n 's/.*shim=\(.*\)\/brew,.*/\1/p' "$SIG_LOG" 2>/dev/null | head -1)"
if [ -z "$_sig_shim_dir" ]; then
  test_fail "could not extract a shim dir from the nested (-v) log -- cannot check its removal. Log tail:
$(_tail "$SIG_LOG")"
elif [ ! -d "$_sig_shim_dir" ]; then
  test_pass
else
  test_fail "shim dir $_sig_shim_dir still exists after the TERM'd nested runner exited -- the EXIT trap did not run cleanup"
fi

unset XACA1222_SIG_B_MARKER

# ═══════════════════════════════════════════════════════════════════════════
# XACA-1222 BLOCKING FIX regression: LOST1-5 — brew_guard_assert --strict
# must fail closed ("guard lost") whenever the guard's OWN shim
# dir/executable/marker go missing mid-run, or 'brew' in the calling
# (runner's own) shell no longer resolves to the shim -- independent of
# whether anything was ever logged as a blocked call. Plain (non-strict)
# brew_guard_assert has no way to see any of this (LOST3 demonstrates the
# gap directly), which is exactly why only run_test_file() passes --strict.
# ═══════════════════════════════════════════════════════════════════════════

# LOST1/2/3: whole shim dir removed.
LOST_LOG="$WORK_DIR/lost-unit.log"
(
  unset AITEAMFORGE_BREW_GUARD_ACTIVE AITEAMFORGE_BREW_GUARD_DIR \
        AITEAMFORGE_BREW_GUARD_MARKER AITEAMFORGE_BREW_GUARD_OWNER_PID \
        AITEAMFORGE_BREW_GUARD_REAL_BREW
  export PATH="$FAKE_BREW_BIN_DIR:$PATH"
  # shellcheck disable=SC1091
  source "$LIB_PATH"
  brew_guard_install
  echo "SHIM_DIR=${AITEAMFORGE_BREW_GUARD_DIR:-}"
  rm -rf "${AITEAMFORGE_BREW_GUARD_DIR:-/nonexistent-xaca1222-lost}"
  if brew_guard_assert --strict; then
    echo "STRICT_ASSERT_RC=0"
  else
    echo "STRICT_ASSERT_RC=1"
  fi
  if brew_guard_assert; then
    echo "PLAIN_ASSERT_RC=0"
  else
    echo "PLAIN_ASSERT_RC=1"
  fi
) >"$LOST_LOG" 2>&1

test_start "LOST1: brew_guard_assert --strict returns non-zero when the whole shim dir was deleted mid-run"
if grep -F -q -- "STRICT_ASSERT_RC=1" "$LOST_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "expected STRICT_ASSERT_RC=1. Log tail:
$(_tail "$LOST_LOG")"
fi

test_start "LOST2: brew_guard_assert --strict prints a loud message naming XACA-1222 and 'guard lost'"
if grep -F -q -- "XACA-1222" "$LOST_LOG" 2>/dev/null && grep -F -q -- "guard lost" "$LOST_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "expected both 'XACA-1222' and 'guard lost' in output. Log tail:
$(_tail "$LOST_LOG")"
fi

test_start "LOST3: brew_guard_assert WITHOUT --strict silently returns 0 on the SAME lost guard (the exact gap --strict exists to close)"
if grep -F -q -- "PLAIN_ASSERT_RC=0" "$LOST_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "expected PLAIN_ASSERT_RC=0 -- a non-strict caller has no marker file left to inspect once the whole dir is gone, so it cannot see a lost guard at all; that blind spot is why only --strict is safe to use as a merge-affecting gate. Log tail:
$(_tail "$LOST_LOG")"
fi

# LOST4: only the shim EXECUTABLE removed (dir + marker survive).
LOST4_LOG="$WORK_DIR/lost4-unit.log"
(
  unset AITEAMFORGE_BREW_GUARD_ACTIVE AITEAMFORGE_BREW_GUARD_DIR \
        AITEAMFORGE_BREW_GUARD_MARKER AITEAMFORGE_BREW_GUARD_OWNER_PID \
        AITEAMFORGE_BREW_GUARD_REAL_BREW
  export PATH="$FAKE_BREW_BIN_DIR:$PATH"
  # shellcheck disable=SC1091
  source "$LIB_PATH"
  brew_guard_install
  rm -f "${AITEAMFORGE_BREW_GUARD_DIR:-/nonexistent-xaca1222-lost4}/brew"
  if brew_guard_assert --strict; then
    echo "STRICT_ASSERT_RC=0"
  else
    echo "STRICT_ASSERT_RC=1"
  fi
  # Tidy up: this subshell's own $$ (bash preserves the enclosing script's
  # PID inside a plain "(...)" subshell) matches AITEAMFORGE_BREW_GUARD_OWNER_PID,
  # so this is the legitimate owner cleanup, not a no-op inherited-guard call.
  # Without it, this dir would sit under the REAL $TMPDIR until some LATER
  # brew_guard_install() call (from an unrelated future run) happens to sweep
  # it as a dead-pid sibling -- avoidable litter this suite can clean up now.
  brew_guard_cleanup
) >"$LOST4_LOG" 2>&1

test_start "LOST4: brew_guard_assert --strict returns non-zero when only the shim EXECUTABLE (not the whole dir) was removed"
if grep -F -q -- "STRICT_ASSERT_RC=1" "$LOST4_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "expected STRICT_ASSERT_RC=1. Log tail:
$(_tail "$LOST4_LOG")"
fi

# LOST5: dir/executable/marker all intact, but 'brew' no longer resolves to
# the shim in the calling (runner's own) shell -- simulated by prepending
# another 'brew' ahead of it on PATH in THIS same process, never inside a
# suite's own already-exited child (which is the only place a legitimate
# override is allowed to happen -- see brew_guard_install's own comment).
LOST5_LOG="$WORK_DIR/lost5-unit.log"
(
  unset AITEAMFORGE_BREW_GUARD_ACTIVE AITEAMFORGE_BREW_GUARD_DIR \
        AITEAMFORGE_BREW_GUARD_MARKER AITEAMFORGE_BREW_GUARD_OWNER_PID \
        AITEAMFORGE_BREW_GUARD_REAL_BREW
  export PATH="$FAKE_BREW_BIN_DIR:$PATH"
  # shellcheck disable=SC1091
  source "$LIB_PATH"
  brew_guard_install
  export PATH="$FAKE_BREW_BIN_DIR:$PATH"
  if brew_guard_assert --strict; then
    echo "STRICT_ASSERT_RC=0"
  else
    echo "STRICT_ASSERT_RC=1"
  fi
  # Tidy up (see LOST4's identical comment above for why this is the
  # legitimate owner, not an inherited-guard no-op).
  brew_guard_cleanup
) >"$LOST5_LOG" 2>&1

test_start "LOST5: brew_guard_assert --strict returns non-zero when 'brew' no longer resolves to the guard shim in the runner's own shell"
if grep -F -q -- "STRICT_ASSERT_RC=1" "$LOST5_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "expected STRICT_ASSERT_RC=1. Log tail:
$(_tail "$LOST5_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# [Review] XACA-1222-012 regression: flag hardening on otherwise-allowlisted
# subcommands, and the `shellenv` removal. Invokes the generated shim
# EXECUTABLE directly (no need for a full nested test-runner.sh) since this
# is purely about the shim's own per-call decision.
# ═══════════════════════════════════════════════════════════════════════════
FLAG_LOG="$WORK_DIR/flag-unit.log"
(
  unset AITEAMFORGE_BREW_GUARD_ACTIVE AITEAMFORGE_BREW_GUARD_DIR \
        AITEAMFORGE_BREW_GUARD_MARKER AITEAMFORGE_BREW_GUARD_OWNER_PID \
        AITEAMFORGE_BREW_GUARD_REAL_BREW
  export PATH="$FAKE_BREW_BIN_DIR:$PATH"
  # shellcheck disable=SC1091
  source "$LIB_PATH"
  brew_guard_install
  _shim="$AITEAMFORGE_BREW_GUARD_DIR/brew"

  "$_shim" info --github foo >"$WORK_DIR/flag-info-github.out" 2>&1
  echo "INFO_GITHUB_RC=$?"

  brew_guard_reset
  "$_shim" outdated --fetch-HEAD >"$WORK_DIR/flag-outdated-fetchhead.out" 2>&1
  echo "OUTDATED_FETCHHEAD_RC=$?"

  brew_guard_reset
  "$_shim" info foo >"$WORK_DIR/flag-info-plain.out" 2>&1
  echo "INFO_PLAIN_RC=$?"

  brew_guard_reset
  "$_shim" shellenv >"$WORK_DIR/flag-shellenv.out" 2>&1
  echo "SHELLENV_RC=$?"

  # Tidy up (see LOST4's identical comment above for why this is the
  # legitimate owner, not an inherited-guard no-op).
  brew_guard_cleanup
) >"$FLAG_LOG" 2>&1

test_start "FLAG1: 'brew info --github foo' is BLOCKED (the --github flag reaches the network on an otherwise-allowlisted subcommand)"
if grep -F -q -- "INFO_GITHUB_RC=97" "$FLAG_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "expected INFO_GITHUB_RC=97. Log tail:
$(_tail "$FLAG_LOG")
$(_tail "$WORK_DIR/flag-info-github.out")"
fi

test_start "FLAG2: 'brew outdated --fetch-HEAD' is BLOCKED (forces a live git fetch on an otherwise-allowlisted subcommand)"
if grep -F -q -- "OUTDATED_FETCHHEAD_RC=97" "$FLAG_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "expected OUTDATED_FETCHHEAD_RC=97. Log tail:
$(_tail "$FLAG_LOG")
$(_tail "$WORK_DIR/flag-outdated-fetchhead.out")"
fi

test_start "FLAG3: 'brew info foo' (no blocked flag) still passes through as read-only"
if grep -F -q -- "INFO_PLAIN_RC=0" "$FLAG_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "expected INFO_PLAIN_RC=0 -- the flag check must not affect a plain allowlisted call with no blocked flag. Log tail:
$(_tail "$FLAG_LOG")
$(_tail "$WORK_DIR/flag-info-plain.out")"
fi

test_start "FLAG4: 'brew shellenv' is BLOCKED (removed from the allowlist -- would put the real brew ahead of this shim on PATH)"
if grep -F -q -- "SHELLENV_RC=97" "$FLAG_LOG" 2>/dev/null; then
  test_pass
else
  test_fail "expected SHELLENV_RC=97. Log tail:
$(_tail "$FLAG_LOG")
$(_tail "$WORK_DIR/flag-shellenv.out")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# [Review] XACA-1222-013 regression: brew_guard_install sweeps a sibling dir
# whose embedded PID is dead, and leaves a live-PID sibling strictly alone.
# Fully sandboxed via a private TMPDIR -- never the real $TMPDIR.
# ═══════════════════════════════════════════════════════════════════════════
SWEEP_ROOT="$WORK_DIR/sweep-tmproot"
mkdir -p "$SWEEP_ROOT"

# A guaranteed-dead PID: this child has already printed its own $$ and
# exited by the time command substitution returns.
_sweep_dead_pid="$(bash -c 'echo $$')"
# A guaranteed-live PID for the duration of this test: this very script's
# own PID, which is still running everything below.
_sweep_live_pid="$$"

_sweep_dead_dir="$SWEEP_ROOT/aiteamforge-brewguard.${_sweep_dead_pid}.deadstub"
_sweep_live_dir="$SWEEP_ROOT/aiteamforge-brewguard.${_sweep_live_pid}.livestub"
# A name that does not parse as our naming shape at all -- must be left
# alone too (never swept on a guess).
_sweep_garbage_dir="$SWEEP_ROOT/aiteamforge-brewguard.not-a-pid-at-all"
mkdir -p "$_sweep_dead_dir" "$_sweep_live_dir" "$_sweep_garbage_dir"

SWEEP_LOG="$WORK_DIR/sweep-unit.log"
(
  unset AITEAMFORGE_BREW_GUARD_ACTIVE AITEAMFORGE_BREW_GUARD_DIR \
        AITEAMFORGE_BREW_GUARD_MARKER AITEAMFORGE_BREW_GUARD_OWNER_PID \
        AITEAMFORGE_BREW_GUARD_REAL_BREW
  export TMPDIR="$SWEEP_ROOT"
  export PATH="$FAKE_BREW_BIN_DIR:$PATH"
  # shellcheck disable=SC1091
  source "$LIB_PATH"
  brew_guard_install
  echo "NEW_SHIM_DIR=${AITEAMFORGE_BREW_GUARD_DIR:-}"
) >"$SWEEP_LOG" 2>&1

test_start "SWEEP1: brew_guard_install sweeps a sibling dir named for a DEAD pid"
if [ ! -d "$_sweep_dead_dir" ]; then
  test_pass
else
  test_fail "stale dead-pid dir $_sweep_dead_dir was NOT swept. Log tail:
$(_tail "$SWEEP_LOG")"
fi

test_start "SWEEP2: brew_guard_install leaves a sibling dir named for a LIVE pid alone"
if [ -d "$_sweep_live_dir" ]; then
  test_pass
else
  test_fail "live-pid dir $_sweep_live_dir was incorrectly swept. Log tail:
$(_tail "$SWEEP_LOG")"
fi

test_start "SWEEP3: brew_guard_install leaves a dir whose name does not parse as a pid alone"
if [ -d "$_sweep_garbage_dir" ]; then
  test_pass
else
  test_fail "unparseable-name dir $_sweep_garbage_dir was incorrectly swept -- never sweep on a guess. Log tail:
$(_tail "$SWEEP_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
if [ "${_STANDALONE:-false}" != true ] && [ -n "${TEST_RESULTS_FILE:-}" ] && [ -f "${TEST_RESULTS_FILE}" ]; then
  _x1222_fail_lines="$(grep '^FAIL:' "$TEST_RESULTS_FILE" 2>/dev/null || true)"
  if [ -n "$_x1222_fail_lines" ]; then
    echo "─── XACA-1222-004 failure detail ───"
    printf '%s\n' "$_x1222_fail_lines"
  fi
fi

if [ "$_STANDALONE" = true ]; then
  echo ""
  echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
  [ "$_FAIL_COUNT" -eq 0 ]
fi
