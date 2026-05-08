#!/bin/bash
# test-kb-quarantine-stub.sh
# Drift-detection test for kb-quarantine-stub and _kb_realpath in the SHIPPED
# tap aliases file.  Catches future deletions, renames, or contract breakage
# before they reach users.
#
# Designed to run standalone OR via test-runner.sh.
# Exit 0 = all cases pass.  Exit 1 = at least one case failed.

set -o pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Locate the SHIPPED aliases file — the whole point of this test.
# Source-of-truth is kanban-helpers.sh in dev-team; THIS file is the tap copy.
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ALIASES_PATH="$TAP_ROOT/share/templates/aliases/kanban-aliases.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Minimal self-contained test framework
# (Falls through to runner-exported functions if available — no conflict.)
# ─────────────────────────────────────────────────────────────────────────────
_PASS=0
_FAIL=0
_CURRENT_TEST=""

if ! declare -F test_start &>/dev/null; then
    test_start() { _CURRENT_TEST="$1"; }
fi
if ! declare -F test_pass &>/dev/null; then
    test_pass() {
        _PASS=$((_PASS + 1))
        printf "  PASS: %s\n" "$_CURRENT_TEST"
    }
fi
if ! declare -F test_fail &>/dev/null; then
    test_fail() {
        _FAIL=$((_FAIL + 1))
        printf "  FAIL: %s — %s\n" "$_CURRENT_TEST" "${1:-}" >&2
    }
fi
if ! declare -F assert_contains &>/dev/null; then
    assert_contains() {
        local haystack="$1" needle="$2"
        if [[ "$haystack" != *"$needle"* ]]; then
            test_fail "Expected to find '$needle'"
        fi
    }
fi
if ! declare -F assert_exit_success &>/dev/null; then
    assert_exit_success() {
        if [ "${1:-1}" -ne 0 ]; then test_fail "Expected exit 0, got ${1}"; fi
    }
fi
if ! declare -F assert_file_exists &>/dev/null; then
    assert_file_exists() {
        if [ ! -f "$1" ]; then test_fail "Expected file to exist: $1"; fi
    }
fi
if ! declare -F assert_file_not_exists &>/dev/null; then
    assert_file_not_exists() {
        if [ -f "$1" ]; then test_fail "Expected file to NOT exist: $1"; fi
    }
fi

# Hard-stop on missing aliases file — nothing else can be tested.
if [ ! -f "$ALIASES_PATH" ]; then
    echo "FATAL: Shipped aliases file not found at: $ALIASES_PATH" >&2
    echo "  This test must run from inside the homebrew-tap checkout." >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Shared sandbox helpers
# ─────────────────────────────────────────────────────────────────────────────
_TEST_TMP=""
_setup_sandbox() {
    _TEST_TMP=$(mktemp -d -t kq-stub-test.XXXXXX)
    # Stub path: $HOME/finance/kanban/finance-board.json  (as per shipped code)
    # Canonical:  $HOME/finance/personal/kanban/finance-personal-board.json
    mkdir -p "$_TEST_TMP/finance/kanban"
    mkdir -p "$_TEST_TMP/finance/personal/kanban"
    # Empty stub (empty backlog)
    printf '{"backlog":[]}\n' > "$_TEST_TMP/finance/kanban/finance-board.json"
    # Canonical board
    printf '{"backlog":[]}\n' > "$_TEST_TMP/finance/personal/kanban/finance-personal-board.json"
    # AITEAMFORGE_DIR inside sandbox
    mkdir -p "$_TEST_TMP/aiteamforge"
}
_teardown_sandbox() {
    [ -n "$_TEST_TMP" ] && [ -d "$_TEST_TMP" ] && rm -rf "$_TEST_TMP"
    _TEST_TMP=""
}

# Source the aliases into a subshell and run a command, returning stdout,
# stderr, and exit code.  We use a wrapper so that AITEAMFORGE_DIR and HOME
# are scoped to each invocation.
#
# IMPORTANT: The shipped template file unconditionally sets
#   AITEAMFORGE_DIR="{{AITEAMFORGE_DIR}}"
# at the top level (line 9), overwriting any env-inherited value.
# We therefore OVERRIDE AITEAMFORGE_DIR *after* sourcing so the test sandbox
# path wins everywhere the function uses it.
#
# Usage: _run_in_sandbox <home_dir> <atf_dir> <command...>
#   Writes stdout  to /tmp/kqs-stdout.$$
#   Writes stderr  to /tmp/kqs-stderr.$$
#   Returns exit code.
_STDOUT_FILE="/tmp/kqs-stdout.$$"
_STDERR_FILE="/tmp/kqs-stderr.$$"

_run_in_sandbox() {
    local home_dir="$1" atf_dir="$2"
    shift 2
    local cmd=("$@")
    # Run in a clean bash subshell (not zsh) so declare -F works predictably.
    # The aliases file is written as zsh but the functions are POSIX-compatible
    # enough for bash sourcing in tests; where zsh-only constructs appear
    # (array slicing) we avoid exercising them here.
    # Shell-escape each cmd element before splicing into the bash -c body so
    # arguments containing spaces or special chars survive intact.
    local _quoted_cmd
    _quoted_cmd=$(printf '%q ' "${cmd[@]}")
    env -i \
        HOME="$home_dir" \
        KANBAN_TEAM="finance-personal" \
        PATH="$PATH" \
        TERM="${TERM:-dumb}" \
        bash --noprofile --norc -c "
            source '$ALIASES_PATH' 2>/dev/null
            # Override AFTER sourcing — the template unconditionally sets the var.
            AITEAMFORGE_DIR='$atf_dir'
            $_quoted_cmd
        " >"$_STDOUT_FILE" 2>"$_STDERR_FILE"
}

_stdout() { cat "$_STDOUT_FILE" 2>/dev/null; }
_stderr() { cat "$_STDERR_FILE" 2>/dev/null; }
_cleanup_tmp_files() {
    rm -f "$_STDOUT_FILE" "$_STDERR_FILE"
}
# Belt-and-suspenders: scrub any literal-placeholder dirs that bash brace-parsing
# of `${VAR:-{{PLACEHOLDER}}}` produces when AITEAMFORGE_DIR isn't overridden in
# time. These are always created in the test runner's cwd (never elsewhere).
_cleanup_placeholder_leaks() {
    local d
    for d in "$PWD"/'{{AITEAMFORGE_DIR'*; do
        [ -d "$d" ] || continue
        find "$d" -depth -delete 2>/dev/null
    done
}
trap '_cleanup_tmp_files; _teardown_sandbox; _cleanup_placeholder_leaks' EXIT INT TERM

# ─────────────────────────────────────────────────────────────────────────────
# CASE 1: Function kb-quarantine-stub is defined in the shipped file
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case 1: kb-quarantine-stub is defined after sourcing shipped aliases"
env -i HOME="$HOME" AITEAMFORGE_DIR="${AITEAMFORGE_DIR:-$HOME/aiteamforge}" PATH="$PATH" \
    bash --noprofile --norc -c "
        source '$ALIASES_PATH' 2>/dev/null
        declare -F kb-quarantine-stub >/dev/null 2>&1
    "
rc=$?
if [ "$rc" -eq 0 ]; then
    test_pass
else
    test_fail "declare -F kb-quarantine-stub returned $rc (function not defined)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 2: Helper _kb_realpath is defined in the shipped file
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case 2: _kb_realpath is defined after sourcing shipped aliases"
env -i HOME="$HOME" AITEAMFORGE_DIR="${AITEAMFORGE_DIR:-$HOME/aiteamforge}" PATH="$PATH" \
    bash --noprofile --norc -c "
        source '$ALIASES_PATH' 2>/dev/null
        declare -F _kb_realpath >/dev/null 2>&1
    "
rc=$?
if [ "$rc" -eq 0 ]; then
    test_pass
else
    test_fail "declare -F _kb_realpath returned $rc (function not defined)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 3: --help exits 0 and contains required strings
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case 3: kb-quarantine-stub --help exits 0 and contains expected strings"
env -i HOME="$HOME" AITEAMFORGE_DIR="${AITEAMFORGE_DIR:-$HOME/aiteamforge}" PATH="$PATH" \
    bash --noprofile --norc -c "
        source '$ALIASES_PATH' 2>/dev/null
        kb-quarantine-stub --help
    " >"$_STDOUT_FILE" 2>"$_STDERR_FILE"
rc=$?
help_out="$(_stdout)"
if [ "$rc" -ne 0 ]; then
    test_fail "--help exited $rc (expected 0)"
else
    all_ok=1
    for needle in "USAGE" "legal-coparenting" "medical-general" "finance-personal"; do
        if [[ "$help_out" != *"$needle"* ]]; then
            test_fail "--help output missing expected string: '$needle'"
            all_ok=0
            break
        fi
    done
    [ "$all_ok" -eq 1 ] && test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 4: Unknown team is rejected (exit non-zero + stderr mentions no known stub path)
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case 4: Unknown team 'zaphod' is rejected with no known stub path message"
env -i HOME="$HOME" AITEAMFORGE_DIR="${AITEAMFORGE_DIR:-$HOME/aiteamforge}" PATH="$PATH" \
    bash --noprofile --norc -c "
        source '$ALIASES_PATH' 2>/dev/null
        kb-quarantine-stub zaphod
    " >"$_STDOUT_FILE" 2>"$_STDERR_FILE"
rc=$?
err_out="$(_stderr)"
if [ "$rc" -eq 0 ]; then
    test_fail "Expected non-zero exit for unknown team, got exit 0"
elif [[ "$err_out" != *"no known stub path"* ]]; then
    test_fail "Expected stderr to contain 'no known stub path', got: $err_out"
else
    test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 5: Missing team argument rejected (exit non-zero + stderr mentions team argument is required)
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case 5: Missing team argument rejected with 'team argument is required'"
env -i HOME="$HOME" AITEAMFORGE_DIR="${AITEAMFORGE_DIR:-$HOME/aiteamforge}" PATH="$PATH" \
    bash --noprofile --norc -c "
        source '$ALIASES_PATH' 2>/dev/null
        kb-quarantine-stub
    " >"$_STDOUT_FILE" 2>"$_STDERR_FILE"
rc=$?
err_out="$(_stderr)"
if [ "$rc" -eq 0 ]; then
    test_fail "Expected non-zero exit for missing arg, got exit 0"
elif [[ "$err_out" != *"team argument is required"* ]]; then
    test_fail "Expected stderr to contain 'team argument is required', got: $err_out"
else
    test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 6: Dry-run on dual-board sandbox exits 0 and prints plan
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case 6: Dry-run prints plan for finance-personal, exits 0, stub not moved"
_setup_sandbox
_run_in_sandbox "$_TEST_TMP" "$_TEST_TMP/aiteamforge" \
    kb-quarantine-stub finance-personal --dry-run
rc=$?
dry_out="$(_stdout)"
stub_still_exists=0
[ -f "$_TEST_TMP/finance/kanban/finance-board.json" ] && stub_still_exists=1

if [ "$rc" -ne 0 ]; then
    test_fail "Dry-run exited $rc (expected 0); stdout: $dry_out; stderr: $(_stderr)"
elif [[ "$dry_out" != *"Plan for team 'finance-personal'"* ]]; then
    test_fail "Dry-run output did not contain \"Plan for team 'finance-personal'\"; got: $dry_out"
elif [ "$stub_still_exists" -ne 1 ]; then
    test_fail "Stub was moved during dry-run (expected it to remain)"
else
    test_pass
fi
_teardown_sandbox

# ─────────────────────────────────────────────────────────────────────────────
# CASE 7: Dry-run quarantine path uses AITEAMFORGE_DIR, not a dev-team hardcode
#
# NOTE: The shipped template file unconditionally sets
#   AITEAMFORGE_DIR="{{AITEAMFORGE_DIR}}" at the top level, and the
#   quarantine_base line uses ${AITEAMFORGE_DIR:-{{AITEAMFORGE_DIR}}}.
# When sourced in bash with our sandbox AITEAMFORGE_DIR override applied after
# sourcing, bash's parameter expansion appends the literal tail '}}' to the
# path (because the `:-{{AITEAMFORGE_DIR}}` fallback default contains `{{`
# which bash parses with one `}` closing the expansion and the second `}`
# being a literal suffix — see https://www.gnu.org/software/bash/manual).
# The effective quarantine root in tests is therefore:
#   $_TEST_TMP/aiteamforge}}/quarantine/runtime-stub-stash/...
# This is a test-harness artifact; at installed-product runtime the template
# placeholder is substituted by the installer before the file is sourced.
#
# The test verifies the correct structural property: AITEAMFORGE_DIR is in the
# path (not a hardcoded ~/dev-team path), confirmed by checking that:
#   (a) quarantine/runtime-stub-stash appears in the planned destination, AND
#   (b) dev-team/quarantine does NOT appear.
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case 7: Dry-run quarantine destination uses AITEAMFORGE_DIR (not dev-team)"
_setup_sandbox
_run_in_sandbox "$_TEST_TMP" "$_TEST_TMP/aiteamforge" \
    kb-quarantine-stub finance-personal --dry-run
dry_out="$(_stdout)"

if [[ "$dry_out" != *"quarantine/runtime-stub-stash"* ]]; then
    test_fail "Quarantine path does not contain 'quarantine/runtime-stub-stash'; got: $dry_out"
elif [[ "$dry_out" == *"dev-team/quarantine"* ]]; then
    test_fail "Quarantine path contains 'dev-team/quarantine' — dev-team source was copy-pasted"
else
    test_pass
fi
_teardown_sandbox

# ─────────────────────────────────────────────────────────────────────────────
# CASE 8: Real quarantine moves stub and creates meta sidecar
#
# As noted in Case 7, the effective quarantine tree root under bash test
# harness is $_TEST_TMP/aiteamforge}}/quarantine/runtime-stub-stash.
# We search $_TEST_TMP broadly for the quarantine output so the '}}' artifact
# does not cause a false failure.
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case 8: Real quarantine (--yes) moves stub and creates .meta.json sidecar"
_setup_sandbox
_run_in_sandbox "$_TEST_TMP" "$_TEST_TMP/aiteamforge" \
    kb-quarantine-stub finance-personal --yes
rc=$?

# Stub must be gone
stub_gone=0
[ ! -f "$_TEST_TMP/finance/kanban/finance-board.json" ] && stub_gone=1

# Search the whole sandbox for the moved file under any quarantine subtree
moved_file=$(find "$_TEST_TMP" -path "*/quarantine/runtime-stub-stash/*" \
    -name "*finance-board.json" ! -name "*.meta.json" 2>/dev/null | head -n1)
meta_file=""
[ -n "$moved_file" ] && meta_file="${moved_file}.meta.json"

if [ "$rc" -ne 0 ]; then
    test_fail "Real quarantine exited $rc (expected 0); stderr: $(_stderr)"
elif [ "$stub_gone" -ne 1 ]; then
    test_fail "Stub file still exists after quarantine: $_TEST_TMP/finance/kanban/finance-board.json"
elif [ -z "$moved_file" ]; then
    test_fail "No quarantined file found under $_TEST_TMP (quarantine/runtime-stub-stash subtree)"
elif [ ! -f "$meta_file" ]; then
    test_fail "Meta sidecar not found at: $meta_file"
else
    test_pass
fi
_teardown_sandbox

# ─────────────────────────────────────────────────────────────────────────────
# CASE 9: Refuses non-empty stub without --force
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case 9: Non-empty stub is refused without --force, stderr mentions item count"
_setup_sandbox
# Overwrite stub with one item
printf '{"backlog":[{"id":"A","title":"live item"}]}\n' \
    > "$_TEST_TMP/finance/kanban/finance-board.json"

_run_in_sandbox "$_TEST_TMP" "$_TEST_TMP/aiteamforge" \
    kb-quarantine-stub finance-personal --yes
rc=$?
err_out="$(_stderr)"

if [ "$rc" -eq 0 ]; then
    test_fail "Expected non-zero exit for non-empty stub without --force, got exit 0"
elif [[ "$err_out" != *"item"* ]] && [[ "$err_out" != *"1"* ]]; then
    # The shipped error message says "contains $item_count item(s)"
    test_fail "Expected stderr to mention item count; got: $err_out"
else
    test_pass
fi
_teardown_sandbox

# ─────────────────────────────────────────────────────────────────────────────
# CASE 10: --force overrides non-empty stub check
# ─────────────────────────────────────────────────────────────────────────────
test_start "Case 10: --force --yes quarantines non-empty stub successfully"
_setup_sandbox
printf '{"backlog":[{"id":"A","title":"live item"}]}\n' \
    > "$_TEST_TMP/finance/kanban/finance-board.json"

_run_in_sandbox "$_TEST_TMP" "$_TEST_TMP/aiteamforge" \
    kb-quarantine-stub finance-personal --force --yes
rc=$?

stub_gone=0
[ ! -f "$_TEST_TMP/finance/kanban/finance-board.json" ] && stub_gone=1

# Search broadly (same '}}' artifact as Case 8)
moved_file=$(find "$_TEST_TMP" -path "*/quarantine/runtime-stub-stash/*" \
    -name "*finance-board.json" ! -name "*.meta.json" 2>/dev/null | head -n1)

if [ "$rc" -ne 0 ]; then
    test_fail "--force --yes exited $rc (expected 0); stderr: $(_stderr)"
elif [ "$stub_gone" -ne 1 ]; then
    test_fail "Stub still exists after --force quarantine"
elif [ -z "$moved_file" ]; then
    test_fail "No quarantined file found under quarantine tree after --force"
else
    test_pass
fi
_teardown_sandbox

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
TOTAL=$((_PASS + _FAIL))
echo ""
echo "─────────────────────────────────────────────────────────"
echo "  kb-quarantine-stub drift tests: $_PASS/$TOTAL passed"
echo "─────────────────────────────────────────────────────────"
echo ""

if [ "$_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
