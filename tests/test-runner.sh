#!/bin/bash

# test-runner.sh
# Test framework for aiteamforge Homebrew Tap
# Discovers and runs test files, provides assert functions, reports results

set -eo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════════════

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Test discovery
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="${TEST_DIR:-$SCRIPT_DIR}"

# Test state
VERBOSE=false
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
# XACA-0862-031: a genuine SKIP (host/environment precondition not met — e.g.
# the outer dev-team monorepo not reachable) must never be tallied as a PASS.
# Prior to this counter, test files recorded a skip by calling test_pass(),
# so a suite that skipped everything reported a fully-covered, all-green run
# — exactly the "reassuring but wrong" defect class this ticket exists to
# eliminate. SKIPPED_TESTS is counted separately and never folds into
# PASSED_TESTS, so PASSED_TESTS < TOTAL_TESTS whenever anything skipped —
# a suite can no longer look fully covered by skipping.
SKIPPED_TESTS=0
CURRENT_TEST_FILE=""
CURRENT_TEST_NAME=""
TEST_FAILED=false

# Temp directory for test isolation
TEST_TMP_DIR=""
TEST_RESULTS_FILE=""

# ═══════════════════════════════════════════════════════════════════════════
# Output Functions
# ═══════════════════════════════════════════════════════════════════════════

print_success() {
  echo -e "${GREEN}✓${NC} $1"
}

print_error() {
  echo -e "${RED}✗${NC} $1" >&2
}

print_warning() {
  echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
  echo -e "${BLUE}ℹ${NC} $1"
}

print_verbose() {
  if [ "$VERBOSE" = true ]; then
    echo -e "${CYAN}▸${NC} $1"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Test Management
# ═══════════════════════════════════════════════════════════════════════════

# Create isolated temp directory for test
setup_test_env() {
  # On macOS, `mktemp -t PREFIX` treats the entire argument as a filename prefix
  # and appends its own random suffix — the literal ".XXXXXX" is NOT expanded as
  # a template here (unlike `mktemp -d /tmp/foo.XXXXXX`).  The resulting dir is
  # named "aiteamforge-test.XXXXXX.<random>".  This is intentional and harmless.
  TEST_TMP_DIR=$(mktemp -d -t aiteamforge-test.XXXXXX)
  TEST_RESULTS_FILE="$TEST_TMP_DIR/.test-results"
  touch "$TEST_RESULTS_FILE"
  print_verbose "Created test temp dir: $TEST_TMP_DIR"
  export TEST_TMP_DIR
  export TEST_RESULTS_FILE
}

# Clean up temp directory
cleanup_test_env() {
  if [ -n "$TEST_TMP_DIR" ] && [ -d "$TEST_TMP_DIR" ]; then
    rm -rf "$TEST_TMP_DIR"
    print_verbose "Cleaned up test temp dir"
  fi
}

# Trap to ensure cleanup even on failure
trap cleanup_test_env EXIT INT TERM

# Start a new test
test_start() {
  local test_name="$1"
  CURRENT_TEST_NAME="$test_name"
  TEST_FAILED=false
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  # Write to results file for parent process
  if [ -n "$TEST_RESULTS_FILE" ]; then
    echo "START" >> "$TEST_RESULTS_FILE"
  fi
  print_verbose "Running: $test_name"
}

# Mark test as passed
test_pass() {
  PASSED_TESTS=$((PASSED_TESTS + 1))
  # Write to results file for parent process
  if [ -n "$TEST_RESULTS_FILE" ]; then
    echo "PASS" >> "$TEST_RESULTS_FILE"
  fi
  if [ "$VERBOSE" = true ]; then
    print_success "$CURRENT_TEST_NAME"
  else
    echo -n "."
  fi
}

# Mark test as SKIPPED — distinct from test_pass(). Use when a test's
# precondition (host tool, outer monorepo, platform) is not met in the
# current environment. NEVER call test_pass() to represent a skip: that
# was the XACA-0862-031 defect (a run that skipped everything read as a
# fully-covered pass).
test_skip() {
  local message="${1:-}"
  SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
  # Write to results file for parent process
  if [ -n "$TEST_RESULTS_FILE" ]; then
    echo "SKIP:$message" >> "$TEST_RESULTS_FILE"
  fi
  if [ "$VERBOSE" = true ]; then
    print_warning "SKIP: $CURRENT_TEST_NAME${message:+ ($message)}"
  else
    echo -n "s"
  fi
}

# Mark test as failed
test_fail() {
  local message="$1"
  FAILED_TESTS=$((FAILED_TESTS + 1))
  TEST_FAILED=true
  # Write to results file for parent process
  if [ -n "$TEST_RESULTS_FILE" ]; then
    echo "FAIL:$message" >> "$TEST_RESULTS_FILE"
  fi

  if [ "$VERBOSE" = true ]; then
    print_error "$CURRENT_TEST_NAME: $message"
  else
    echo -n "F"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Assert Functions
# ═══════════════════════════════════════════════════════════════════════════

# Assert two values are equal
assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="${3:-Expected '$expected' but got '$actual'}"

  if [ "$expected" = "$actual" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert two values are not equal
assert_not_equal() {
  local unexpected="$1"
  local actual="$2"
  local message="${3:-Expected value to not be '$unexpected'}"

  if [ "$unexpected" != "$actual" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert string contains substring
assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="${3:-Expected to find '$needle' in '$haystack'}"

  if [[ "$haystack" == *"$needle"* ]]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert string does not contain substring
assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="${3:-Expected to not find '$needle' in '$haystack'}"

  if [[ "$haystack" != *"$needle"* ]]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert file exists
assert_file_exists() {
  local file="$1"
  local message="${2:-Expected file to exist: $file}"

  if [ -f "$file" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert file does not exist
assert_file_not_exists() {
  local file="$1"
  local message="${2:-Expected file to not exist: $file}"

  if [ ! -f "$file" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert directory exists
assert_dir_exists() {
  local dir="$1"
  local message="${2:-Expected directory to exist: $dir}"

  if [ -d "$dir" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert directory does not exist
assert_dir_not_exists() {
  local dir="$1"
  local message="${2:-Expected directory to not exist: $dir}"

  if [ ! -d "$dir" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert exit code is zero (success)
assert_exit_success() {
  local exit_code="$1"
  local message="${2:-Expected command to succeed (exit 0) but got exit $exit_code}"

  if [ "$exit_code" -eq 0 ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert exit code is non-zero (failure)
assert_exit_failure() {
  local exit_code="$1"
  local message="${2:-Expected command to fail (exit non-zero) but got exit $exit_code}"

  if [ "$exit_code" -ne 0 ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert exit code matches specific value
assert_exit_code() {
  local expected="$1"
  local actual="$2"
  local message="${3:-Expected exit code $expected but got $actual}"

  if [ "$expected" -eq "$actual" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert command succeeds
assert_success() {
  local cmd="$*"

  if eval "$cmd" >/dev/null 2>&1; then
    return 0
  else
    test_fail "Command failed: $cmd"
    return 1
  fi
}

# Assert command fails
assert_failure() {
  local cmd="$*"

  if ! eval "$cmd" >/dev/null 2>&1; then
    return 0
  else
    test_fail "Command succeeded (expected failure): $cmd"
    return 1
  fi
}

# Assert string matches regex
assert_matches() {
  local string="$1"
  local pattern="$2"
  local message="${3:-Expected '$string' to match pattern '$pattern'}"

  if [[ "$string" =~ $pattern ]]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert value is empty
assert_empty() {
  local value="$1"
  local message="${2:-Expected value to be empty}"

  if [ -z "$value" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert value is not empty
assert_not_empty() {
  local value="$1"
  local message="${2:-Expected value to not be empty}"

  if [ -n "$value" ]; then
    return 0
  else
    test_fail "$message"
    return 1
  fi
}

# Assert valid JSON
assert_valid_json() {
  local json="$1"
  local message="${2:-Expected valid JSON}"

  if command -v jq &>/dev/null; then
    if echo "$json" | jq empty >/dev/null 2>&1; then
      return 0
    else
      test_fail "$message"
      return 1
    fi
  else
    print_warning "jq not available, skipping JSON validation"
    return 0
  fi
}

# Assert file contains valid JSON
assert_file_valid_json() {
  local file="$1"
  local message="${2:-Expected file to contain valid JSON: $file}"

  if [ ! -f "$file" ]; then
    test_fail "File does not exist: $file"
    return 1
  fi

  if command -v jq &>/dev/null; then
    if jq empty "$file" >/dev/null 2>&1; then
      return 0
    else
      test_fail "$message"
      return 1
    fi
  else
    print_warning "jq not available, skipping JSON validation"
    return 0
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# XACA-0787-003/006: Self-policing real-$HOME leak guard
# ═══════════════════════════════════════════════════════════════════════════
# Instance-by-instance remediation of tap-test $HOME leaks was tried FOUR
# times (2026-07-12, 07-24, 08-13, 09-05/06) and the CLASS survived every
# one, because nothing made a leaking test FAIL — it just silently wrote
# into the developer's real $HOME and the run still reported green. This
# guard closes the class at the harness level: it runs around EVERY suite
# `run_test_file` executes, regardless of whether that suite itself
# remembers to sandbox $HOME (the individual-suite fix subitem 015 proved
# sufficient per-suite; this is the backstop for the suite that forgets).
#
# It brackets each suite with a snapshot-before / assert-after of the SIX
# attested real-machine leak vectors:
#   1. Plist CREATION under the real ~/Library/LaunchAgents/com.aiteamforge.*
#   2. Plist REWRITE — same filename, changed mtime/size/content
#   3. launchctl-registered jobs with NO plist on disk (invisible to `ls`)
#   4. The opt-out sentinel ~/.aiteamforge/launchagents.optout appearing/changing
#   5. ~/.claude/settings.json gaining a hook registration
#   6. Abandoned sandbox directories left at the top of ${TMPDIR:-/tmp} —
#      MEASURED the highest-volume vector of the six (orchestrator sweep,
#      2026-09-10 13:56: 1,525 `tmp.*`-prefixed dirs outstanding, ~750/day
#      regrowth after a manual cleanup), so this is weighted as the primary
#      check, not an afterthought.
#
# IMPORTANT — this guard only brackets the run_test_file() path (i.e. `bash
# test-runner.sh [file...]`, which is how both CI and the documented
# workflow invoke every suite in this directory — see
# .github/workflows/tap-installer-tests.yml). A suite executed standalone
# (`bash homebrew-tap/tests/test-foo.sh` directly, bypassing test-runner.sh's
# main()) is NOT bracketed by this guard — standalone mode only sources this
# file for its assert/test_* functions, it never calls run_test_file(). That
# is a known, documented gap, not a silent one.
#
# FAIL LOUD, NEVER SILENT (design constraint): every check below prefers a
# false positive over a false negative. Bash 3.2 compatible (this fleet's
# /bin/bash) — no associative arrays. `|| true` guards every command whose
# natural "nothing found" exit status would otherwise trip `set -eo
# pipefail` and abort the whole runner instead of reporting a clean gate.

LEAK_GUARD_STATE_DIR=""
LEAK_GUARD_TRIPPED=false
# XACA-0787-019: the launchctl binary this guard's OWN detection/remediation
# calls, as an indirection variable rather than a bare literal. Defaults to
# the real absolute path — production behavior is UNCHANGED, every suite
# still gets the real thing regardless of PATH tricks. The only reason this
# is a variable at all is so this guard's own bootout-by-label remediation
# logic can be exercised against a MOCK launchctl in a test of the guard
# itself (record invocations to a file, assert the right labels/args),
# without ever touching the real machine's launchd. Never override this
# outside such a test.
_LEAK_GUARD_LAUNCHCTL_BIN="${_LEAK_GUARD_LAUNCHCTL_BIN:-/bin/launchctl}"
# LEAK_GUARD_TMPROOT is the temp root snapshotted for vector 6. It MUST be
# captured before TEST_TMP_DIR exists (this function runs before
# setup_test_env in run_test_file) so TEST_TMP_DIR's own directory doesn't
# register as a false-positive "new" entry once the suite creates it.
LEAK_GUARD_TMPROOT="${TMPDIR:-/tmp}"

# Real (un-sandboxed) LaunchAgents plists for this product. run_test_file()
# executes in the RUNNER's own process — only the child `bash "$test_file"`
# subshell ever exports a sandboxed $HOME, and that export does not survive
# back into this parent process — so plain $HOME here is always the real one.
_leak_guard_plist_glob() {
  ls -1 "$HOME/Library/LaunchAgents"/com.aiteamforge.*.plist 2>/dev/null || true
}

# Fingerprint every real plist as "path|mtime|size|md5". Content-sensitive
# (not just mtime/size) so a rewrite that happens to land in the same second
# with the same byte count is still caught.
_leak_guard_plist_fingerprint() {
  local p
  for p in $(_leak_guard_plist_glob); do
    [ -f "$p" ] || continue
    local mtime size sum
    mtime=$(stat -f '%m' "$p" 2>/dev/null || echo '?')
    size=$(stat -f '%z' "$p" 2>/dev/null || echo '?')
    sum=$(md5 -q "$p" 2>/dev/null || echo '?')
    printf '%s|%s|%s|%s\n' "$p" "$mtime" "$size" "$sum"
  done | sort
}

# Real launchctl jobs for this product, keyed by label only (never touches
# the mock: this runs in the parent process, whose PATH a child's `export
# PATH="$MOCK_BIN_DIR:$PATH"` cannot reach — and it uses the ABSOLUTE path
# (via $_LEAK_GUARD_LAUNCHCTL_BIN, which defaults to it) defensively anyway,
# exactly like the tailscale suite's own cleanup does).
_leak_guard_launchctl_jobs() {
  "$_LEAK_GUARD_LAUNCHCTL_BIN" list 2>/dev/null | awk '{print $3}' | grep '^com\.aiteamforge\.' | sort || true
}

_leak_guard_file_fingerprint() {
  local f="$1"
  if [ -f "$f" ]; then
    md5 -q "$f" 2>/dev/null || echo '?'
  else
    echo '__absent__'
  fi
}

# Vector 6: top-level entries under the temp root. Filtered to test-shaped
# names (aiteamforge/xaca/tap-test naming families actually observed across
# this suite's mktemp templates — see XACA-0787-003 census) so an unrelated
# process creating/removing its own top-level temp dir in the same window
# doesn't flap this gate; the filter is deliberately broad rather than an
# exact enumeration, because the failure mode this guard exists to prevent
# is a NEW template nobody thought to sandbox — an exact list would miss
# exactly that case.
_leak_guard_tmproot_snapshot() {
  find "$LEAK_GUARD_TMPROOT" -maxdepth 1 -type d \
    \( -iname '*aiteamforge*' -o -iname 'xaca*' -o -iname '*tap-test*' -o -iname 'tmp.*' \) \
    2>/dev/null | sort || true
}

leak_guard_snapshot() {
  LEAK_GUARD_STATE_DIR="$(mktemp -d -t aiteamforge-leakguard.XXXXXX)"
  _leak_guard_plist_fingerprint > "$LEAK_GUARD_STATE_DIR/plists.before"
  # XACA-0787-019: plain PATH list (not the fingerprint), kept separately so
  # remediation can compute exactly which plists are NEW via `comm -13`
  # against paths.after — the fingerprint file mixes "new" and "rewritten"
  # together (both show up as a diff), and only "new" is safe to remediate.
  # A pre-existing real plist that got REWRITTEN is still reported by the
  # fingerprint diff below, but deliberately left untouched by remediation:
  # auto-reverting a real, already-installed job's plist is a different and
  # riskier operation than cleaning up something this run itself created,
  # and is out of scope here.
  _leak_guard_plist_glob > "$LEAK_GUARD_STATE_DIR/plist-paths.before"
  _leak_guard_launchctl_jobs > "$LEAK_GUARD_STATE_DIR/launchctl.before"
  _leak_guard_file_fingerprint "$HOME/.aiteamforge/launchagents.optout" > "$LEAK_GUARD_STATE_DIR/optout.before"
  _leak_guard_file_fingerprint "$HOME/.claude/settings.json" > "$LEAK_GUARD_STATE_DIR/claude-settings.before"
  _leak_guard_tmproot_snapshot > "$LEAK_GUARD_STATE_DIR/tmproot.before"
}

# XACA-0787-019: deregister ONE launchd job by LABEL. Never `unload -w
# <path>` — that requires a plist file to read and fails with "Input/output
# error" when the file is already gone (measured on M3Pro 2026-09-10), which
# is exactly the vector-3 case (job registered, no plist on disk) this
# exists to clear. `bootout` addresses the label directly; no file needed.
#
# Idempotent/backstop-safe by construction: bootout's own exit code is
# NEVER trusted as proof of removal — a variety of real launchd outcomes
# (including "already gone", which is the whole point) can report non-zero
# here even though the end state is exactly what's wanted. The actual
# post-condition — is the label still registered? — is re-queried directly
# via `launchctl list` afterward. That is the only thing this function
# believes.
#
# Returns 0 if the label is confirmed NOT registered afterward (whether
# bootout did the work or it was already gone), 1 if it is STILL registered
# — the caller must treat 1 as a loud failure, never swallow it.
_leak_guard_bootout_label() {
  local label="$1"
  [ -n "$label" ] || return 0
  "$_LEAK_GUARD_LAUNCHCTL_BIN" bootout "gui/$(id -u)/${label}" >/dev/null 2>&1 || true
  if "$_LEAK_GUARD_LAUNCHCTL_BIN" list 2>/dev/null | awk '{print $3}' | grep -qx -- "$label"; then
    return 1
  fi
  return 0
}

# Returns 0 clean, 1 tripped. Prints a precise report to stderr on trip —
# never degrades a real diff into a pass (test-e2e-setup-launch.sh:616's
# quoted-glob no-op is exactly the bug class this must not repeat).
leak_guard_assert() {
  if [ -z "$LEAK_GUARD_STATE_DIR" ] || [ ! -d "$LEAK_GUARD_STATE_DIR" ]; then
    print_error "LEAK GUARD INTERNAL ERROR: assert called with no snapshot for $CURRENT_TEST_FILE — treating as a trip rather than silently passing."
    return 1
  fi

  local tripped=false

  _leak_guard_plist_fingerprint > "$LEAK_GUARD_STATE_DIR/plists.after"
  if ! diff -q "$LEAK_GUARD_STATE_DIR/plists.before" "$LEAK_GUARD_STATE_DIR/plists.after" >/dev/null 2>&1; then
    tripped=true
    print_error "LEAK [plist] real ~/Library/LaunchAgents/com.aiteamforge.* changed during $CURRENT_TEST_FILE:"
    diff -u "$LEAK_GUARD_STATE_DIR/plists.before" "$LEAK_GUARD_STATE_DIR/plists.after" 2>&1 | sed 's/^/    /' >&2 || true
  fi

  _leak_guard_launchctl_jobs > "$LEAK_GUARD_STATE_DIR/launchctl.after"
  if ! diff -q "$LEAK_GUARD_STATE_DIR/launchctl.before" "$LEAK_GUARD_STATE_DIR/launchctl.after" >/dev/null 2>&1; then
    tripped=true
    print_error "LEAK [launchctl] real launchctl gained/lost a com.aiteamforge.* job during $CURRENT_TEST_FILE (no plist required for this vector):"
    diff -u "$LEAK_GUARD_STATE_DIR/launchctl.before" "$LEAK_GUARD_STATE_DIR/launchctl.after" 2>&1 | sed 's/^/    /' >&2 || true
  fi

  # ─────────────────────────────────────────────────────────────────────────
  # XACA-0787-019: REMEDIATION — deregister by LABEL anything this suite
  # newly registered, so a detected leak also gets cleared off the real
  # machine, not just reported. Scoped strictly to what THIS run ADDED
  # (comm -13 of the before/after snapshots) — never a blanket sweep of
  # every com.aiteamforge.* job currently on the box. That distinction is
  # the entire safety margin: a blanket `bootout` of every matching label
  # would tear down a developer's or CI runner's own pre-existing,
  # legitimately-installed AITeamForge jobs, which this guard must never
  # touch. Anything already present in the "before" snapshot — including a
  # pre-existing plist that got REWRITTEN (still flagged above as a [plist]
  # leak) — is left completely alone here; auto-reverting a real job's
  # plist is a different, riskier operation than clearing what this run
  # itself created, and is out of scope.
  _leak_guard_plist_glob > "$LEAK_GUARD_STATE_DIR/plist-paths.after"
  local new_plist_paths new_launchctl_labels
  new_plist_paths=$(comm -13 "$LEAK_GUARD_STATE_DIR/plist-paths.before" "$LEAK_GUARD_STATE_DIR/plist-paths.after" 2>/dev/null || true)
  new_launchctl_labels=$(comm -13 "$LEAK_GUARD_STATE_DIR/launchctl.before" "$LEAK_GUARD_STATE_DIR/launchctl.after" 2>/dev/null || true)

  local remediate_file="$LEAK_GUARD_STATE_DIR/remediate-labels"
  {
    if [ -n "$new_plist_paths" ]; then
      printf '%s\n' "$new_plist_paths" | while IFS= read -r p; do
        if [ -n "$p" ]; then
          basename "$p" .plist
        fi
      done
    fi
    if [ -n "$new_launchctl_labels" ]; then
      printf '%s\n' "$new_launchctl_labels"
    fi
  } | sed '/^$/d' | sort -u > "$remediate_file" 2>/dev/null || true

  local remediation_failed=false
  if [ -s "$remediate_file" ]; then
    local label_count label
    label_count=$(wc -l < "$remediate_file" 2>/dev/null | tr -d ' ' || echo '?')
    print_error "LEAK REMEDIATION: booting out ${label_count:-?} label(s) $CURRENT_TEST_FILE newly registered, by LABEL — never 'unload -w <path>' (fails with Input/output error once the plist is already gone, which is exactly the vector-3 case this exists for):"
    while IFS= read -r label; do
      [ -n "$label" ] || continue
      if _leak_guard_bootout_label "$label"; then
        print_error "  cleared: $label"
      else
        remediation_failed=true
        print_error "  STILL REGISTERED after bootout: $label — teardown could NOT clear this. Manual cleanup required: launchctl bootout gui/$(id -u)/$label"
      fi
    done < "$remediate_file"

    # Only remove the leaked plist FILE once its label is confirmed clear —
    # never the reverse order, so a job that's still registered doesn't
    # also lose its only on-disk trace before a human can look at it.
    if [ "$remediation_failed" = false ] && [ -n "$new_plist_paths" ]; then
      printf '%s\n' "$new_plist_paths" | while IFS= read -r np; do
        if [ -n "$np" ] && [ -f "$np" ]; then
          rm -f -- "$np" 2>/dev/null || true
        fi
      done
    fi
  fi

  if [ "$remediation_failed" = true ]; then
    tripped=true
    print_error "LEAK GUARD REMEDIATION FAILED for $CURRENT_TEST_FILE — see 'STILL REGISTERED' line(s) above. This is WORSE than a cleanly-remediated leak: the job is still live on the real machine after this run ended. Do not treat this run as clean."
  fi
  # ─────────────────────────────────────────────────────────────────────────

  _leak_guard_file_fingerprint "$HOME/.aiteamforge/launchagents.optout" > "$LEAK_GUARD_STATE_DIR/optout.after"
  if ! diff -q "$LEAK_GUARD_STATE_DIR/optout.before" "$LEAK_GUARD_STATE_DIR/optout.after" >/dev/null 2>&1; then
    tripped=true
    print_error "LEAK [optout] real ~/.aiteamforge/launchagents.optout appeared or changed during $CURRENT_TEST_FILE — on a real consumer box this permanently suppresses the auto-upgrade LaunchAgent."
  fi

  _leak_guard_file_fingerprint "$HOME/.claude/settings.json" > "$LEAK_GUARD_STATE_DIR/claude-settings.after"
  if ! diff -q "$LEAK_GUARD_STATE_DIR/claude-settings.before" "$LEAK_GUARD_STATE_DIR/claude-settings.after" >/dev/null 2>&1; then
    tripped=true
    print_error "LEAK [claude-settings] real ~/.claude/settings.json changed during $CURRENT_TEST_FILE (possible hook registration pointing into a sandbox)."
  fi

  _leak_guard_tmproot_snapshot > "$LEAK_GUARD_STATE_DIR/tmproot.after"
  if ! diff -q "$LEAK_GUARD_STATE_DIR/tmproot.before" "$LEAK_GUARD_STATE_DIR/tmproot.after" >/dev/null 2>&1; then
    local new_entries
    new_entries=$(comm -13 "$LEAK_GUARD_STATE_DIR/tmproot.before" "$LEAK_GUARD_STATE_DIR/tmproot.after" 2>/dev/null || true)
    if [ -n "$new_entries" ]; then
      # PR #859 review finding 5: split vector 6 by ATTRIBUTABILITY, not just
      # existence. Two risks were in tension: downgrading this vector
      # wholesale would weaken the highest-volume leak check (measured
      # 1,525 outstanding sandboxes, ~750/day regrowth); but treating every
      # match as this suite's own leak is wrong too — bare "tmp.*" is
      # mktemp -d's OWN DEFAULT prefix for ANY process on this box, and this
      # snapshot is a diff over the ENTIRE shared $TMPDIR, not something
      # scoped to this suite's children. Confirmed LIVE during this PR's own
      # review: a from-scratch sandboxed run of test-lifecycle.sh here
      # tripped on bare tmp.* AND on aiteamforge-0799.*/aiteamforge-
      # allocator-test.*/xaca-1122-008.* dirs that this run never created —
      # concurrent unrelated activity on the same shared machine, exactly
      # the false-attribution shape the PR review body warned about.
      #
      # Resolution: entries attributable to THE RUNNING SUITE stay a HARD
      # FAILURE; everything else is reported loudly but does not fail.
      #
      # XACA-0787 round-3: the first cut of this keyed on the naming FAMILIES
      # (aiteamforge*, xaca*, tap-test*), which was too broad and produced the
      # very false positives it was added to stop. Those patterns match any
      # OTHER concurrent session's sandboxes too. Observed twice on this shared
      # machine: a stray `xaca-1122-*` dir and an `aiteamforge-xaca1161-test.*`
      # dir were each attributed to an unrelated suite and hard-failed it.
      # A family prefix says "some AITeamForge test made this", which is not
      # the question; the question is "did THIS suite make it".
      #
      # So attribute on either of two things we actually know:
      #   1. the dir is (or is under) this runner's OWN sandbox, TEST_TMP_DIR;
      #   2. the basename carries this suite's own ticket token, e.g.
      #      test-xaca-0611-*.sh -> "0611", which matches its xaca0611-sandbox.*
      #      leftovers and nothing belonging to another ticket's run.
      # A suite with no ticket token in its filename simply has no
      # attributable bucket — correct, since we then have no evidence tying a
      # stray dir to it, and its real leaks are still caught by vectors 1-5.
      # A bare "tmp.*" entry that matches NONE of those prefixes is reported
      # LOUDLY, with full paths, but does NOT fail the run on its own —
      # it cannot be attributed to $CURRENT_TEST_FILE specifically. This
      # must stay loud and explicit, never silent: the defect class this
      # whole ticket is about is a check that silently degrades to success,
      # and a deliberate, visible severity split is a different thing —
      # never let this be mistaken for that antipattern.
      local attributable_entries="" bare_tmp_entries="" _lg_entry _lg_base _lg_is_ours
      local _lg_own_sandbox="" _lg_suite_token=""
      [ -n "${TEST_TMP_DIR:-}" ] && _lg_own_sandbox=$(basename "$TEST_TMP_DIR")
      # Ticket token from the running suite's filename: test-xaca-0611-*.sh -> 0611
      _lg_suite_token=$(printf '%s' "${CURRENT_TEST_FILE##*/}" \
        | sed -n 's/.*[Xx][Aa][Cc][Aa][-_]*\([0-9][0-9]*\).*/\1/p')
      while IFS= read -r _lg_entry; do
        [ -n "$_lg_entry" ] || continue
        _lg_base=$(basename "$_lg_entry")
        _lg_is_ours=false
        # (1) our own runner sandbox. Guard against an empty value, which would
        #     turn the glob into *""* and match every entry.
        if [ -n "$_lg_own_sandbox" ]; then
          case "$_lg_base" in
            "$_lg_own_sandbox"|"$_lg_own_sandbox".*) _lg_is_ours=true ;;
          esac
        fi
        # (2) this suite's own ticket token. Same empty-value guard.
        if [ "$_lg_is_ours" = false ] && [ -n "$_lg_suite_token" ]; then
          case "$_lg_base" in
            *"$_lg_suite_token"*) _lg_is_ours=true ;;
          esac
        fi
        if [ "$_lg_is_ours" = true ]; then
          attributable_entries="${attributable_entries}${_lg_entry}
"
        else
          bare_tmp_entries="${bare_tmp_entries}${_lg_entry}
"
        fi
      done <<LEAK_GUARD_ENTRIES_EOF
$new_entries
LEAK_GUARD_ENTRIES_EOF

      if [ -n "$bare_tmp_entries" ]; then
        print_error "LEAK [abandoned-sandbox:unattributed] temp dir(s) appeared under $LEAK_GUARD_TMPROOT during $CURRENT_TEST_FILE's run window but are NOT attributable to it — they are neither this runner's own sandbox nor named for this suite's ticket. NOT failing on these alone: on a shared \$TMPDIR another concurrent session's dirs land in this window (observed twice). Reported loudly, not silently, so a real pattern here stays visible:"
        printf '%s\n' "$bare_tmp_entries" | sed '/^$/d;s/^/    /' >&2
      fi
      if [ -n "$attributable_entries" ]; then
        tripped=true
        print_error "LEAK [abandoned-sandbox] $CURRENT_TEST_FILE left temp dir(s) behind under $LEAK_GUARD_TMPROOT that ARE test/suite-identifiable by name (highest-volume vector, XACA-0787 measured 2026-09-10):"
        printf '%s\n' "$attributable_entries" | sed '/^$/d;s/^/    /' >&2
      fi
    fi
  fi

  command rm -rf "$LEAK_GUARD_STATE_DIR" 2>/dev/null || true
  LEAK_GUARD_STATE_DIR=""

  if [ "$tripped" = true ]; then
    LEAK_GUARD_TRIPPED=true
    return 1
  fi
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Test Discovery and Execution
# ═══════════════════════════════════════════════════════════════════════════

# Discover test files
discover_tests() {
  local test_pattern="${1:-test-*.sh}"

  # Exclude test-runner.sh itself
  find "$TEST_DIR" -maxdepth 1 -name "$test_pattern" -type f ! -name "test-runner.sh" | sort
}

# Run a single test file
run_test_file() {
  local test_file="$1"
  CURRENT_TEST_FILE="$(basename "$test_file")"

  if [ ! -f "$test_file" ]; then
    print_error "Test file not found: $test_file"
    return 1
  fi

  if [ ! -x "$test_file" ]; then
    print_warning "Test file not executable, making executable: $test_file"
    chmod +x "$test_file"
  fi

  print_info "Running: $CURRENT_TEST_FILE"

  # XACA-0787-003/006: snapshot the real $HOME leak vectors BEFORE the suite
  # (and before setup_test_env creates this run's own TEST_TMP_DIR, so that
  # tracked, properly-cleaned-up directory never counts as a false positive
  # for vector 6 below). See the leak_guard_* functions' own header comment
  # for the full rationale and the six vectors covered.
  leak_guard_snapshot

  # Set up test environment
  setup_test_env

  # Export variables and test framework functions
  export VERBOSE
  export -f test_start test_pass test_fail test_skip
  export -f assert_equal assert_not_equal assert_contains assert_not_contains
  export -f assert_file_exists assert_file_not_exists assert_dir_exists assert_dir_not_exists
  export -f assert_exit_success assert_exit_failure assert_exit_code
  export -f assert_success assert_failure assert_matches
  export -f assert_empty assert_not_empty assert_valid_json assert_file_valid_json
  export -f print_success print_error print_warning print_info print_verbose

  # XACA-0787-019 tried defaulting every suite to AITEAMFORGE_SKIP_LAUNCHCTL=1
  # via `: "${AITEAMFORGE_SKIP_LAUNCHCTL:=1}"` here, as prevention on top of
  # the leak_guard_assert bootout-by-label remediation below. REMOVED during
  # PR #859 review (blocking finding 2): the `:=` claim was "does not
  # clobber", which is true only for suites that explicitly `unset` it
  # inside their own `bash -c`/subshell child (test-xaca-0683-skip-
  # launchctl.sh, test-xaca-1097-launchagent-disabled-autofix.sh) — it is
  # FALSE for a suite that neither sets nor unsets it and asserts on the
  # wrapper's real pass-through behavior. test-tailscale.sh's "launchctl mock
  # records load call against sandbox plist path" test does exactly that: it
  # runs `_write_funnel_restore_script` in a bare subshell with no explicit
  # AITEAMFORGE_SKIP_LAUNCHCTL handling, expecting _aitf_launchctl to reach
  # its PATH-mocked `launchctl` and log the call. With this default filled in
  # ahead of the subshell, the wrapper short-circuited before the mock was
  # ever invoked and the assertion — which exists specifically to prove
  # pass-through still works — failed. Measured: this suite's CI run
  # regressed by exactly this defaulted-var, not by anything in the suite
  # itself.
  #
  # Per XACA-0787 subitem 015 (validated, not assumed): HOME sandboxing alone
  # is sufficient to contain the leak this default was trying to prevent —
  # the plist FILE never lands under the real $HOME/Library/LaunchAgents once
  # HOME is sandboxed (setup_test_env, above, already does this for every
  # suite run through this runner). `launchctl` registration is per-USER not
  # per-HOME, so a stray real registration (vector 3) can still occur even
  # with HOME sandboxed — but that residual is exactly what
  # leak_guard_assert's bootout-by-label remediation (below, after the suite
  # exits) exists to catch and clear. That backstop does not depend on this
  # default and is unaffected by its removal. A blanket ahead-of-time default
  # that a well-behaved control test cannot see itself out of is not worth
  # keeping for a gap the backstop already covers.

  # Run the test file
  local test_exit_code=0
  bash "$test_file" || test_exit_code=$?

  # Aggregate results from results file
  if [ -f "$TEST_RESULTS_FILE" ]; then
    local starts passes fails skips
    starts=$(grep -c "^START" "$TEST_RESULTS_FILE" 2>/dev/null || echo "0")
    passes=$(grep -c "^PASS" "$TEST_RESULTS_FILE" 2>/dev/null || echo "0")
    fails=$(grep -c "^FAIL:" "$TEST_RESULTS_FILE" 2>/dev/null || echo "0")
    # XACA-0862-031: SKIP is its own marker line (written by test_skip()),
    # counted separately so it can never inflate `passes`.
    skips=$(grep -c "^SKIP:" "$TEST_RESULTS_FILE" 2>/dev/null || echo "0")

    # Ensure values are numeric (strip whitespace, default to 0)
    starts=$(echo "$starts" | tr -d ' ')
    passes=$(echo "$passes" | tr -d ' ')
    fails=$(echo "$fails" | tr -d ' ')
    skips=$(echo "$skips" | tr -d ' ')

    # Validate and default to 0 if not numeric
    [[ "$starts" =~ ^[0-9]+$ ]] || starts=0
    [[ "$passes" =~ ^[0-9]+$ ]] || passes=0
    [[ "$fails" =~ ^[0-9]+$ ]] || fails=0
    [[ "$skips" =~ ^[0-9]+$ ]] || skips=0

    TOTAL_TESTS=$((TOTAL_TESTS + starts))
    PASSED_TESTS=$((PASSED_TESTS + passes))
    FAILED_TESTS=$((FAILED_TESTS + fails))
    SKIPPED_TESTS=$((SKIPPED_TESTS + skips))

    if [ "$fails" -eq 0 ] && [ "$test_exit_code" -eq 0 ]; then
      print_success "Completed: $CURRENT_TEST_FILE"
    else
      print_error "Failed: $CURRENT_TEST_FILE"
      # XACA-0653: suites that keep their OWN pass/fail counters (not the
      # runner's test_pass/test_fail) write no "FAIL:" lines, so a hard failure
      # leaves fails=0. Previously this branch only PRINTED "Failed:" and never
      # incremented FAILED_TESTS, so a non-zero suite exit was reported as
      # "All tests passed!" (runner exit 0) — silently green-lighting a broken
      # gate (the e2e fresh-install driver is exactly such a suite). Count the
      # exit-code failure here, but only when no "FAIL:" lines were recorded
      # (otherwise it is already counted in the aggregation above — no double).
      if [ "$fails" -eq 0 ] && [ "$test_exit_code" -ne 0 ]; then
        FAILED_TESTS=$((FAILED_TESTS + 1))
      fi
    fi
  else
    if [ "$test_exit_code" -ne 0 ]; then
      print_error "Crashed: $CURRENT_TEST_FILE"
      FAILED_TESTS=$((FAILED_TESTS + 1))
    else
      print_success "Completed: $CURRENT_TEST_FILE"
    fi
  fi

  # Clean up test environment
  cleanup_test_env

  # XACA-0787-003/006: assert AFTER cleanup_test_env removes this run's own
  # TEST_TMP_DIR, so only genuinely abandoned/leaked state remains to trip
  # the guard. Deliberately NOT `leak_guard_assert || true` — a real trip
  # must flip this suite's result to failing, never pass through silently.
  # It is intentionally evaluated separately from the fails/test_exit_code
  # branch above (which already printed Completed:/Failed:/Crashed:) rather
  # than folded into it, so a leak is reported as its own loud, unambiguous
  # signal instead of being absorbed into — and possibly masked by — the
  # suite's own pass/fail bookkeeping.
  if ! leak_guard_assert; then
    print_error "LEAK GUARD TRIPPED: $CURRENT_TEST_FILE touched the real \$HOME — see LEAK [...] lines above. Failing this run regardless of the suite's own pass/fail result."
    FAILED_TESTS=$((FAILED_TESTS + 1))
  fi

  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# Main Runner
# ═══════════════════════════════════════════════════════════════════════════

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [TEST_FILE...]

Test runner for aiteamforge Homebrew Tap

OPTIONS:
  -v, --verbose     Verbose output (show each test)
  -h, --help        Show this help message

ARGUMENTS:
  TEST_FILE         Specific test file(s) to run
                    If not specified, runs all test-*.sh files

EXAMPLES:
  # Run all tests
  $(basename "$0")

  # Run specific test file
  $(basename "$0") test-cli.sh

  # Run multiple test files with verbose output
  $(basename "$0") -v test-cli.sh test-config.sh

  # Run all tests with verbose output
  $(basename "$0") --verbose

EOF
}

main() {
  local test_files=()

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose)
        VERBOSE=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
      *)
        test_files+=("$1")
        shift
        ;;
    esac
  done

  # Print banner
  echo ""
  echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  AITeamForge Homebrew Tap Test Suite${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
  echo ""

  # Discover tests if no specific files provided
  if [ ${#test_files[@]} -eq 0 ]; then
    print_info "Discovering tests..."
    while IFS= read -r test_file; do
      test_files+=("$test_file")
    done < <(discover_tests)
  else
    # Convert relative paths to absolute
    local resolved_files=()
    for test_file in "${test_files[@]}"; do
      if [ -f "$test_file" ]; then
        resolved_files+=("$test_file")
      elif [ -f "$TEST_DIR/$test_file" ]; then
        resolved_files+=("$TEST_DIR/$test_file")
      else
        print_error "Test file not found: $test_file"
        exit 1
      fi
    done
    test_files=("${resolved_files[@]}")
  fi

  if [ ${#test_files[@]} -eq 0 ]; then
    print_warning "No test files found matching pattern: test-*.sh"
    exit 0
  fi

  print_info "Found ${#test_files[@]} test file(s)"
  echo ""

  # Run tests
  for test_file in "${test_files[@]}"; do
    run_test_file "$test_file"
  done

  # Print summary
  echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  Test Summary${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  Total Tests:  $TOTAL_TESTS"
  echo -e "  ${GREEN}Passed:       $PASSED_TESTS${NC}"

  if [ $FAILED_TESTS -gt 0 ]; then
    echo -e "  ${RED}Failed:       $FAILED_TESTS${NC}"
  else
    echo -e "  Failed:       $FAILED_TESTS"
  fi

  # XACA-0862-031: skips are surfaced distinctly, never folded into Passed.
  # A skip is not evidence the guarded behavior was verified — see the
  # counter's own comment above (SKIPPED_TESTS) for why this line exists.
  if [ "$SKIPPED_TESTS" -gt 0 ]; then
    echo -e "  ${YELLOW}Skipped:      $SKIPPED_TESTS${NC}"
  fi

  echo ""

  # Exit with appropriate code
  if [ $FAILED_TESTS -eq 0 ]; then
    print_success "All tests passed!"
    echo ""
    exit 0
  else
    print_error "$FAILED_TESTS test(s) failed"
    echo ""
    exit 1
  fi
}

# Run main if executed directly
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
  main "$@"
fi
