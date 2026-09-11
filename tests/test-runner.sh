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
# It brackets each suite with a snapshot-before / assert-after of the SEVEN
# attested real-machine leak vectors:
#   1. Plist CREATION under the real ~/Library/LaunchAgents/com.aiteamforge.*
#   2. Plist REWRITE — same filename, changed mtime/size/content
#   3. launchctl-registered jobs with NO plist on disk (invisible to `ls`)
#   4. The opt-out sentinel ~/.aiteamforge/launchagents.optout appearing/changing
#   5. ~/.claude/settings.json gaining a hook registration
#   6. Abandoned sandbox directories left at the top of ${TMPDIR:-/tmp} —
#      MEASURED the highest-volume vector of the seven (orchestrator sweep,
#      2026-09-10 13:56: 1,525 `tmp.*`-prefixed dirs outstanding, ~750/day
#      regrowth after a manual cleanup), so this is weighted as the primary
#      check, not an afterthought.
#   7. XACA-0787 recurrence #4 (2026-09-10/11): the real per-instance LCARS
#      port registry ~/.aiteamforge/team-paths.json changing content, and its
#      install-team.sh-authored backup family
#      (team-paths.json.bak-xaca0463-installer-*) growing. This is a
#      DIFFERENT sink from vectors 1-6 (which all watch launchd/Claude-
#      settings state) — a test that sandboxes AITEAMFORGE_DIR without also
#      sandboxing HOME or pinning AITEAMFORGE_CONFIG falls through to
#      $HOME/.aiteamforge/team-paths.json (install-team.sh's own fallback;
#      see aiteamforge_config_path() in aiteamforge-paths.sh for the same
#      contract) and mutates the REAL registry. MEASURED: 91
#      team-paths.json.bak-xaca0463-installer-* backups accumulated on this
#      machine 2026-09-04 through 2026-09-10 — a week-long drip vector 1-6
#      could not have caught, and did not.
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
# XACA-0787-033: the directory vector 7 (team-paths.json + its backup
# family) watches, as an indirection variable — same pattern as
# _LEAK_GUARD_LAUNCHCTL_BIN above. Defaults to the real
# $HOME/.aiteamforge — production behavior UNCHANGED. The only reason this
# is a variable is so vector 7 itself can be proven to fire (and to NOT
# fire) in an automated, CI-safe test: point it at a fixture directory that
# exists regardless of whether a real registry does, so the assertion is
# real on a bare CI runner where $HOME/.aiteamforge/team-paths.json is
# always __absent__ before and after. Never override this outside such a
# test of the guard itself.
_LEAK_GUARD_AITEAMFORGE_DIR="${_LEAK_GUARD_AITEAMFORGE_DIR:-$HOME/.aiteamforge}"

# ─────────────────────────────────────────────────────────────────────────
# XACA-0787-021: portable stat/hash probing. `stat -f`/`md5 -q` are
# BSD/macOS-only. This suite's sibling harness (tests/bats/run.sh) runs on
# ubuntu-latest, where neither exists — every `|| echo '?'` fallback fires
# for every file, so a plist fingerprint collapses to the literal
# `path|?|?|?` REGARDLESS of actual mtime/size/content. Two plists with
# entirely different content then fingerprint identically, and the
# plist-rewrite + settings.json leak vectors report clean no matter what
# happens — the exact "reassuring but wrong" defect class this whole ticket
# exists to eliminate, reproduced inside the fix for it.
#
# Probed ONCE per process (memoized) and resolved via a definitive signal,
# not an ambiguous flag guess: GNU coreutils' `stat --version` prints a
# recognizable banner and exits 0; BSD/macOS `stat` has no `--version` and
# exits non-zero treating it as a bad option. Checking that FIRST avoids
# relying on `stat -f '%m'` erroring out on GNU — GNU's `-f` flag means
# "filesystem status" with a DIFFERENT format-code vocabulary (%a %b %c %d
# %f %i %l %n %s %S %t %T; no %m), and whether an invalid directive there
# reliably fails is exactly the kind of assumption this ticket exists to
# stop trusting untested.
#
# FAIL LOUD, NEVER FAIL OPEN: if no usable stat/hash tool is found, this
# aborts the whole runner immediately (distinct exit code) rather than
# continuing with fingerprinting silently degraded to a shared '?' — a
# guard that can't tell two files apart is worse than no guard, because it
# reports clean.
_LEAK_GUARD_TOOLS_PROBED=false
_LEAK_GUARD_STAT_FLAVOR=""
_LEAK_GUARD_HASH_CMD=""

_leak_guard_probe_tools() {
  [ "$_LEAK_GUARD_TOOLS_PROBED" = true ] && return 0
  _LEAK_GUARD_TOOLS_PROBED=true

  if stat --version >/dev/null 2>&1 && stat --version 2>/dev/null | grep -qi 'GNU coreutils'; then
    _LEAK_GUARD_STAT_FLAVOR="gnu"
  elif stat -f '%m' . >/dev/null 2>&1; then
    _LEAK_GUARD_STAT_FLAVOR="bsd"
  else
    print_error "LEAK GUARD FATAL (XACA-0787-021): no usable 'stat' found (tried GNU 'stat --version' banner detection and BSD 'stat -f'). Refusing to continue with fingerprinting silently degraded to '?' for every file — that would make the plist-rewrite and settings.json leak vectors report clean no matter what happens. Install a supported stat (coreutils or BSD) or run on a supported host."
    exit 97
  fi

  if command -v md5 >/dev/null 2>&1; then
    _LEAK_GUARD_HASH_CMD="md5"
  elif command -v md5sum >/dev/null 2>&1; then
    _LEAK_GUARD_HASH_CMD="md5sum"
  elif command -v shasum >/dev/null 2>&1; then
    _LEAK_GUARD_HASH_CMD="shasum"
  else
    print_error "LEAK GUARD FATAL (XACA-0787-021): none of 'md5', 'md5sum', 'shasum' is available. Refusing to continue with content fingerprinting silently degraded to '?' for every file — that would make the plist-rewrite and settings.json leak vectors report clean no matter what happens. Install one of these tools."
    exit 97
  fi
}

_leak_guard_stat_mtime() {
  case "$_LEAK_GUARD_STAT_FLAVOR" in
    bsd) stat -f '%m' "$1" 2>/dev/null ;;
    gnu) stat -c '%Y' "$1" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

_leak_guard_stat_size() {
  case "$_LEAK_GUARD_STAT_FLAVOR" in
    bsd) stat -f '%z' "$1" 2>/dev/null ;;
    gnu) stat -c '%s' "$1" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

_leak_guard_hash() {
  case "$_LEAK_GUARD_HASH_CMD" in
    md5) md5 -q "$1" 2>/dev/null ;;
    md5sum) md5sum "$1" 2>/dev/null | awk '{print $1}' ;;
    shasum) shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' ;;
    *) return 1 ;;
  esac
}
# ─────────────────────────────────────────────────────────────────────────

# Real (un-sandboxed) LaunchAgents plists for this product. run_test_file()
# executes in the RUNNER's own process — only the child `bash "$test_file"`
# subshell ever exports a sandboxed $HOME, and that export does not survive
# back into this parent process — so plain $HOME here is always the real one.
_leak_guard_plist_glob() {
  ls -1 "$HOME/Library/LaunchAgents"/com.aiteamforge.*.plist 2>/dev/null || true
}

# Fingerprint every real plist as "path|mtime|size|hash". Content-sensitive
# (not just mtime/size) so a rewrite that happens to land in the same second
# with the same byte count is still caught. Portable across BSD/macOS and
# GNU/Linux — see _leak_guard_probe_tools above (XACA-0787-021).
_leak_guard_plist_fingerprint() {
  _leak_guard_probe_tools
  local p
  for p in $(_leak_guard_plist_glob); do
    [ -f "$p" ] || continue
    local mtime size sum
    mtime=$(_leak_guard_stat_mtime "$p") || mtime='?'
    size=$(_leak_guard_stat_size "$p") || size='?'
    sum=$(_leak_guard_hash "$p") || sum='?'
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
  _leak_guard_probe_tools
  if [ -f "$f" ]; then
    _leak_guard_hash "$f" || echo '?'
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

# Vector 7 (XACA-0787 recurrence #4): count of install-team.sh's own
# XACA-0463 backup family for the REAL registry. install-team.sh writes one
# of these (config_path.name + ".bak-xaca0463-installer-" + UTC timestamp)
# every time it upserts an instance's lcars_port into an EXISTING
# team-paths.json — see install-team.sh's python heredoc under "XACA-0463:
# Persist per-instance lcars_port to team-paths.json". A growing count here
# is the same fingerprint the finder used to first detect this recurrence:
# 91 backups accumulated 2026-09-04 through 2026-09-10 on this machine.
_leak_guard_team_paths_backup_count() {
  # `find`, not `ls <glob>*` — under this file's `set -eo pipefail`, a
  # non-matching `ls` glob (the common case: no backups exist yet) exits
  # non-zero and pipefail surfaces that through the whole pipeline, which
  # `set -e` then treats as this FUNCTION failing — and since both call
  # sites invoke it as a bare statement (`... > file`), that would abort
  # the entire runner mid-suite. `find` on a missing directory has the same
  # failure shape, so the trailing `|| true` is required regardless of
  # which tool is used — verified empirically both ways.
  find "$_LEAK_GUARD_AITEAMFORGE_DIR" -maxdepth 1 -type f \
    -name 'team-paths.json.bak-xaca0463-installer-*' \
    2>/dev/null | wc -l | tr -d ' ' || true
}

# PR #859 round-6 review (XACA-0787-031): is a real team-paths.json write
# attributable to $CURRENT_TEST_FILE at all? Vector 6 answers the analogous
# question with two signals it actually has evidence for — its own
# TEST_TMP_DIR, and a ticket token pulled from the suite's own filename.
# Neither transfers here: team-paths.json is ONE well-known path, not a
# family of differently-named entries, so there is no filename fragment of
# the write itself to match against. The only evidence this guard actually
# has is a DIFFERENT kind: does $CURRENT_TEST_FILE's own source even
# reference an entry point capable of writing the real registry
# (install-team.sh, kb-port-fix.py, or team-paths.json/port-reconcile by
# name)? A suite that never mentions any of those cannot plausibly be the
# cause — exactly the same "no evidence -> don't hard-fail" logic vector 6
# applies to a bare unattributed tmp.* entry.
#
# This is a PLAUSIBILITY proxy, not proof — same as vector 6's ticket-token
# match, which doesn't prove causation either, only that the suite is
# capable of it. A suite that touches the registry only through an
# indirect helper with none of these strings in its own source is a real,
# known gap (mirrors vector 6's 22/91-suites-no-token gap) — reported
# loudly via the non-attributable path below, never silently dropped.
#
# Returns 0 (attributable) / 1 (not). Fails closed on missing evidence: an
# unset or unreadable $CURRENT_TEST_FILE is NOT attributable, never the
# reverse — inventing attribution from nothing is exactly the "weak signal"
# this must not do.
_leak_guard_suite_touches_team_paths() {
  local suite_path
  [ -n "${TEST_DIR:-}" ] && [ -n "${CURRENT_TEST_FILE:-}" ] || return 1
  suite_path="$TEST_DIR/$CURRENT_TEST_FILE"
  [ -f "$suite_path" ] || return 1
  grep -qE 'install-team\.sh|kb-port-fix|team-paths\.json|port-reconcile' "$suite_path" 2>/dev/null
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
  # Vector 7: real team-paths.json content fingerprint + its backup-family count.
  _leak_guard_file_fingerprint "$_LEAK_GUARD_AITEAMFORGE_DIR/team-paths.json" > "$LEAK_GUARD_STATE_DIR/team-paths.before"
  _leak_guard_team_paths_backup_count > "$LEAK_GUARD_STATE_DIR/team-paths-backups.before"
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
      # stray dir to it. XACA-0787-029: an earlier version of this comment
      # claimed such a suite's abandoned-dir leaks are "still caught by
      # vectors 1-5" — that is FALSE. Vectors 1-5 cover plists, launchctl
      # jobs, the opt-out sentinel, and ~/.claude/settings.json; none of them
      # observes a temp directory at all. RE-COUNTED against this suite's
      # current roster (2026-09-10, `find . -maxdepth 1 -name "test-*.sh"
      # -type f ! -name test-runner.sh | grep -vic xaca`): 22 of 91
      # plain-shell suites carry no `xaca`/`XACA` ticket token in their
      # filename, so an abandoned dir left by one of those 22 is caught by
      # NOTHING in this guard — it is reported (loudly, via the unattributed
      # bucket below) but does not fail the run. That is a real, known gap
      # in vector 6's coverage, not a false one papered over by another
      # vector. (The 22/91 figure will drift as suites are added — re-run
      # the command above rather than trusting this comment's number.)
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
        # XACA-0787-030: this MUST be a digit-boundary match, not a bare
        # glob substring — `*"$_lg_suite_token"*` matched "0463" INSIDE the
        # unrelated digit run "10463" (e.g. a stray `xaca-10463-*` dir from
        # a completely different ticket), hard-failing test-xaca-0463-*.sh
        # on someone else's leftover. grep -E anchors the token on a
        # non-digit (or string boundary) on both sides, so it matches
        # "xaca0463-sandbox.*" / "test-xaca-0463-tmp.123" but rejects
        # "xaca-10463-*" and "xaca-04630-*". Token is digits-only (from the
        # sed capture above), so it carries no regex metacharacters that
        # need escaping.
        if [ "$_lg_is_ours" = false ] && [ -n "$_lg_suite_token" ]; then
          if printf '%s' "$_lg_base" | grep -Eq "(^|[^0-9])${_lg_suite_token}([^0-9]|\$)"; then
            _lg_is_ours=true
          fi
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

  # ─────────────────────────────────────────────────────────────────────────
  # Vector 7 (XACA-0787 recurrence #4): the real XACA-0463 LCARS-port
  # registry ~/.aiteamforge/team-paths.json. A DIFFERENT sink from vectors
  # 1-6 (all launchd/Claude-settings state) — see the header comment above
  # for why AITEAMFORGE_DIR sandboxing alone does not cover it. Two
  # independent signals:
  #   (a) the file's content fingerprint changed at all, or
  #   (b) install-team.sh's own timestamped backup family
  #       (team-paths.json.bak-xaca0463-installer-*) changed count — this is
  #       the exact fingerprint the finder used to first detect this
  #       recurrence (91 backups, 2026-09-04 through 2026-09-10 on this
  #       machine).
  # Content-only fingerprinting can miss a write-then-restore: install-team.sh
  # backs up the PRE-write file before every upsert, so a run that writes and
  # then (coincidentally, or via a second write) restores the original
  # content would still leave a new backup file behind — that's why (b) is
  # checked independently of (a), not only as a fallback when (a) is silent.
  #
  # PR #859 round-6 review (XACA-0787-031): a real registry write during the
  # bracketed window is NOT proof $CURRENT_TEST_FILE caused it — this is a
  # SHARED machine, and another concurrent session's install-team.sh or
  # kb-port-fix.py run lands in the same window just as validly as vector 6's
  # shared-$TMPDIR problem did. _leak_guard_suite_touches_team_paths() is the
  # best evidence available (does this suite's own source even reference an
  # entry point capable of this write?) — same PLAUSIBILITY-not-proof
  # standard vector 6's ticket-token match uses. Attributable -> hard
  # failure. Not attributable -> reported loudly, never silently, but does
  # NOT fail the run: inventing attribution where none exists is worse than
  # admitting there isn't any.
  #
  # XACA-0787-032: a SHRINK in the backup count is handled separately from
  # growth and is NEVER attribution-gated — no production code path prunes
  # or deletes team-paths.json.bak-xaca0463-installer-* files (confirmed:
  # only install-team.sh's upsert step ever creates one), so there is no
  # legitimate concurrent-session explanation for a shrink the way there is
  # for growth. A shrink means real backup history — the user's own
  # recovery trail — was destroyed, which is worse than an unexpected write:
  # a content change is at least still visible in the fingerprint diff,
  # whereas a deleted backup is gone. It always trips, regardless of
  # attribution.
  # ─────────────────────────────────────────────────────────────────────────
  local _lg_tp_attributable=false
  if _leak_guard_suite_touches_team_paths; then
    _lg_tp_attributable=true
  fi

  _leak_guard_file_fingerprint "$_LEAK_GUARD_AITEAMFORGE_DIR/team-paths.json" > "$LEAK_GUARD_STATE_DIR/team-paths.after"
  if ! diff -q "$LEAK_GUARD_STATE_DIR/team-paths.before" "$LEAK_GUARD_STATE_DIR/team-paths.after" >/dev/null 2>&1; then
    local _lg_tp_content_msg="real ~/.aiteamforge/team-paths.json content changed during $CURRENT_TEST_FILE. Before: $(cat "$LEAK_GUARD_STATE_DIR/team-paths.before" 2>/dev/null) After: $(cat "$LEAK_GUARD_STATE_DIR/team-paths.after" 2>/dev/null)"
    if [ "$_lg_tp_attributable" = true ]; then
      tripped=true
      print_error "LEAK [team-paths] $_lg_tp_content_msg — this test drove a real installer/port-fixer without sandboxing HOME or pinning AITEAMFORGE_CONFIG."
    else
      print_error "LEAK [team-paths:unattributed] $_lg_tp_content_msg — NOT failing on this alone: $CURRENT_TEST_FILE's own source names no entry point (install-team.sh / kb-port-fix.py / team-paths.json / port-reconcile) capable of this write, so it cannot be attributed to this suite on a shared machine. Reported loudly, not silently."
    fi
  fi

  _leak_guard_team_paths_backup_count > "$LEAK_GUARD_STATE_DIR/team-paths-backups.after"
  if ! diff -q "$LEAK_GUARD_STATE_DIR/team-paths-backups.before" "$LEAK_GUARD_STATE_DIR/team-paths-backups.after" >/dev/null 2>&1; then
    local _lg_tp_before _lg_tp_after
    _lg_tp_before=$(cat "$LEAK_GUARD_STATE_DIR/team-paths-backups.before" 2>/dev/null || echo '?')
    _lg_tp_after=$(cat "$LEAK_GUARD_STATE_DIR/team-paths-backups.after" 2>/dev/null || echo '?')
    # Guard every comparison against a non-numeric/empty value (this
    # ticket's own fail-open shape, XACA-0787-031) — `-gt`/`-lt` on '?' or
    # '' would abort under `set -e` rather than silently mis-comparing, but
    # either way that's the wrong failure mode; require both sides numeric
    # before doing arithmetic, and treat an unreadable count as its own
    # loud, non-fatal report rather than a guess in either direction.
    case "$_lg_tp_before" in ''|*[!0-9]*) _lg_tp_before="" ;; esac
    case "$_lg_tp_after" in ''|*[!0-9]*) _lg_tp_after="" ;; esac
    if [ -z "$_lg_tp_before" ] || [ -z "$_lg_tp_after" ]; then
      print_error "LEAK [team-paths-backup-count:unreadable] could not read a numeric backup count for $CURRENT_TEST_FILE (before='$(cat "$LEAK_GUARD_STATE_DIR/team-paths-backups.before" 2>/dev/null)', after='$(cat "$LEAK_GUARD_STATE_DIR/team-paths-backups.after" 2>/dev/null)') — reporting only, not assuming growth or shrink from an unreadable value."
    elif [ "$_lg_tp_after" -gt "$_lg_tp_before" ]; then
      if [ "$_lg_tp_attributable" = true ]; then
        tripped=true
        print_error "LEAK [team-paths-backup-growth] real ~/.aiteamforge/team-paths.json.bak-xaca0463-installer-* count grew from $_lg_tp_before to $_lg_tp_after during $CURRENT_TEST_FILE — install-team.sh's own XACA-0463 port-persist step wrote a backup of the REAL registry before mutating it."
      else
        print_error "LEAK [team-paths-backup-growth:unattributed] real ~/.aiteamforge/team-paths.json.bak-xaca0463-installer-* count grew from $_lg_tp_before to $_lg_tp_after during $CURRENT_TEST_FILE — NOT failing on this alone: $CURRENT_TEST_FILE's own source names no entry point capable of this write, so it cannot be attributed to this suite on a shared machine. Reported loudly, not silently."
      fi
    elif [ "$_lg_tp_after" -lt "$_lg_tp_before" ]; then
      tripped=true
      print_error "LEAK [team-paths-backup-shrink] real ~/.aiteamforge/team-paths.json.bak-xaca0463-installer-* count DROPPED from $_lg_tp_before to $_lg_tp_after during $CURRENT_TEST_FILE — real backup history was deleted. This ALWAYS fails, regardless of attribution: no production code path prunes this backup family, so there is no legitimate concurrent-session explanation for a shrink the way there is for growth, and destroyed backup history is worse than an unexpected write."
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
  # for the full rationale and the seven vectors covered.
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
    # XACA-0787-026: a trip is its own accounted-for result, not a suite-level
    # test_start/test_pass/test_fail event — nothing upstream (the
    # TEST_RESULTS_FILE aggregation above) ever counted it toward
    # TOTAL_TESTS, so incrementing FAILED_TESTS alone breaks the
    # Total == Passed + Failed + Skipped identity the summary implies (e.g.
    # a printed "Total: 58, Passed: 58, Failed: 6"). Exit code and the
    # Failed line were already correct — a nonzero FAILED_TESTS already
    # fails the run below — this only fixes the arithmetic a log-scraper
    # would otherwise be misled by. Bump TOTAL_TESTS in lockstep so the
    # identity holds; PASSED_TESTS/SKIPPED_TESTS are deliberately untouched.
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
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
