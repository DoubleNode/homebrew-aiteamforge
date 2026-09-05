#!/bin/bash
# test-xaca-1097-doctor-phantom-deps.sh
#
# XACA-1097 defect 2: both doctor entry points resolve external tools with
# a bare `command -v <tool>`, which only searches $PATH:
#
#     homebrew-tap/bin/aiteamforge-doctor.sh                 (check_dependencies(), ~line 203)
#     homebrew-tap/libexec/commands/aiteamforge-doctor.sh    (check_dependencies(), ~line 332)
#
# Under a non-login shell PATH that excludes /opt/homebrew/bin (and any
# other non-default bin dir a tool happens to live in — e.g. `~/.local/bin`,
# where `claude` actually lives on the machine this was measured on; see
# the NOTE below), the check reports Node.js / GitHub CLI / Claude Code as
# NOT FOUND even though the binaries demonstrably exist on disk and are
# fully functional — a phantom-missing false FAIL a human or CI would act
# on by (re-)installing something that is already installed.
#
# NOTE on the ticket's stated tool locations (evidence over hypothesis —
# see task instructions): the ticket claims all three tools live at
# /opt/homebrew/bin/{node,gh,claude}. Measured on THIS machine (M3Pro):
#     node   -> Herd/nvm-managed, NOT under /opt/homebrew/bin, /usr/local/bin,
#               or ~/.local/bin at all — see WIDENED REQUIREMENT below.
#     gh     -> /opt/homebrew/bin/gh      (matches the ticket)
#     claude -> ~/.local/bin/claude       (does NOT match — a symlink into
#                                          ~/.local/share/claude/versions/…,
#                                          not a Homebrew install at all)
# Measured separately on M1Pro: node/gh/claude/brew -> /opt/homebrew/bin;
# jq/git/python3 -> /usr/bin; tailscale -> /usr/local/bin.
#
# WIDENED REQUIREMENT (correction folded in after initial drafting): a fixed
# candidate-directory list — even one with three entries — is measurably
# insufficient. On THIS machine `command -v node` (ambient, unrestricted
# PATH — i.e. what a login shell resolves) returns:
#     /Users/darrenehlers/Library/Application Support/Herd/config/nvm/versions/node/v22.22.3/bin/node
# which matches NONE of /opt/homebrew/bin, /usr/local/bin, or ~/.local/bin,
# and CONTAINS A SPACE ("Application Support") — a real, not synthesized,
# case that breaks any resolver that word-splits an unquoted path. The tests
# below therefore treat "whatever the ambient/login PATH resolves" as the
# ground truth for node (not a hardcoded directory check), and assert the
# space-containing, off-list path explicitly.
#
# HONEST LIMITATION (stated plainly, not swept under the rug): this machine
# ALSO has a second, different node install at /opt/homebrew/bin/node (brew
# Cellar, v26.0.0 — separate from the Herd-managed v22.22.3 that ambient
# PATH actually resolves to). That coincidence means a fix which merely
# widens its candidate-directory list to include /opt/homebrew/bin would
# still find *A* node here and pass the "not reported missing" assertions
# below, even though it located a DIFFERENT install than the one a login
# shell would use — this suite cannot mechanically distinguish "found the
# right node" from "found a different, coincidentally-present node" without
# either mutating real /opt/homebrew (forbidden — outside tests/ sandbox,
# machine-wide, and dangerous) or fully synthesizing away from the genuine
# measured case (which the correction explicitly said not to do for the
# space-path assertion). What this suite DOES mechanically guarantee: (a)
# the ambient-resolved node path is proven, by direct assertion, to sit
# outside all three named candidate directories and to contain a space,
# and (b) the check must still not report "Node.js not found" when that is
# the only node reachable under a PATH restricted to bare system dirs. A
# fix that hardcodes exactly the three named directories and nothing else
# will correctly FAIL this suite on a machine where /opt/homebrew/bin/node
# does not independently exist (e.g. an nvm-only dev box); it will pass here
# by coincidence. Flagging this for the fix author/reviewer rather than
# claiming false certainty.
#
# SEPARATE FINDING (not covered by this suite, out of scope for tests/ — for
# the fix author): both doctor copies' existing Tailscale check probes
# `command -v tailscale`, `/opt/homebrew/bin/tailscale`, and
# `/Applications/Tailscale.app/...` but NOT `/usr/local/bin/tailscale` —
# confirmed by reading bin/aiteamforge-doctor.sh:263-271 and
# libexec/commands/aiteamforge-doctor.sh:406-414,1822-1839. Tailscale
# resolves to /usr/local/bin on BOTH machines measured. Do not treat that
# block as a correct reference model to imitate when fixing node/gh/claude.
#
# Line/command-count grounding (re-verified against THIS worktree's base
# 1e502d3 — the ticket's original numbers were measured against shipped
# 0.20.4 and are STALE for this branch): informational only, see the
# "grounding" test block below for why these are no longer hard-pinned.
#     bin/aiteamforge-doctor.sh                 795 lines, 10 `command -v`
#     libexec/commands/aiteamforge-doctor.sh   2051 lines, 20 `command -v`
#
# This test extracts the REAL check_result()/check_dependencies() function
# bodies verbatim (via sed range, not reimplemented) from both files, so it
# exercises the actual authoritative logic rather than a stand-in.
#
# Verified against unfixed code at 1e502d3 — this test FAILS today.
#
# Designed to run standalone OR via test-runner.sh (matches the
# test-xaca-1095-017-helpers-drift-check.sh convention).

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DOCTOR="$TAP_ROOT/bin/aiteamforge-doctor.sh"
LIBEXEC_DOCTOR="$TAP_ROOT/libexec/commands/aiteamforge-doctor.sh"
COMMON_LIB="$TAP_ROOT/libexec/lib/common.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: fallbacks ONLY when test-runner.sh hasn't already
# exported test_start/test_pass/test_fail.
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
_PASS=0
_FAIL=0
_CURRENT_TEST=""

if ! declare -F test_start &>/dev/null; then
    _STANDALONE=true
    test_start() { _CURRENT_TEST="$1"; printf "TEST: %s\n" "$1"; }
    test_pass()  { _PASS=$((_PASS + 1)); printf "  PASS: %s\n" "$_CURRENT_TEST"; }
    test_fail()  { _FAIL=$((_FAIL + 1)); printf "  FAIL: %s -- %s\n" "$_CURRENT_TEST" "${1:-}" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# XACA-1097-007 hardening (Problem 2): whichever test_start/test_pass/
# test_fail are in scope above (our own standalone fallbacks, OR the ones
# test-runner.sh exported into this process) do NOT gate test_pass on
# whether test_fail already fired for the current block — test-runner.sh's
# own test_pass() unconditionally increments PASSED_TESTS regardless of
# TEST_FAILED. Fixing that framework-wide is out of scope (it would touch
# every suite, not just this ticket's two files) — instead every assertion
# in THIS file is routed through _block_note_fail(), which records the
# failure via the real test_fail() AND raises a local flag, and every block
# ends with _block_end() instead of a bare test_pass(), so a block that
# failed never ALSO prints a PASS line for the same test name.
# ─────────────────────────────────────────────────────────────────────────────
_BLOCK_FAILED=false

_block_start() {
    _BLOCK_FAILED=false
    test_start "$1"
}

_block_note_fail() {
    _BLOCK_FAILED=true
    test_fail "$1"
}

_block_end() {
    if [ "$_BLOCK_FAILED" = false ]; then
        test_pass
    fi
    # else: test_fail already ran (via _block_note_fail) for this block —
    # do not also record a PASS for the same test name.
}

assert_eq() {
    local got="$1" expected="$2" msg="${3:-Expected [$2], got [$1]}"
    [ "$got" = "$expected" ] || _block_note_fail "$msg"
}
assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-Expected to find [$2] in output}"
    [[ "$haystack" == *"$needle"* ]] || _block_note_fail "$msg"
}
assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-Expected NOT to find [$2] in output}"
    [[ "$haystack" != *"$needle"* ]] || _block_note_fail "$msg"
}
# XACA-1097-007 hardening (Problem 1): a bare assert_not_contains PASSES
# vacuously when its haystack is the empty string — proved directly:
#     haystack=""; [[ "$haystack" != *"needle"* ]]  -> TRUE, "passes"
# assert_not_empty() exists so every negative assertion below can be paired
# with a positive one proving the fixture actually produced output, per the
# task's Problem 1 requirement.
assert_not_empty() {
    local val="$1" msg="${2:-Expected non-empty captured output (fixture produced nothing)}"
    [ -n "$val" ] || _block_note_fail "$msg"
}

if [ ! -f "$BIN_DOCTOR" ]; then
    echo "FATAL: bin/aiteamforge-doctor.sh not found at: $BIN_DOCTOR" >&2
    exit 1
fi
if [ ! -f "$LIBEXEC_DOCTOR" ]; then
    echo "FATAL: libexec/commands/aiteamforge-doctor.sh not found at: $LIBEXEC_DOCTOR" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# XACA-1097-007 hardening (Problem 3): the original grounding block hard-
# pinned exact line counts and `command -v` occurrence counts (795/10,
# 2051/20). The fix this ticket exists to enable modifies exactly those
# `command -v` lines and ADDS lines (a login-shell/broader-resolution
# fallback) — those snapshots WILL drift the moment the fix lands, and a
# naive re-read would mistake expected drift for a regression, or worse,
# require hand-updating a magic number on every future edit (a maintenance
# trap, not a test).
#
# Replaced with INVARIANTS the suite actually depends on and actually
# cares about surviving the fix:
#   1. Both files still define check_dependencies() and check_result() —
#      the sed-range extraction below assumes these function headers exist
#      verbatim; if a refactor renames/removes them, the extraction goes
#      silently empty and this grounding block is what catches it (not a
#      vacuous downstream pass — see Problem 1 fix above for the second
#      line of defense).
#   2. Both copies still reference each tool-check marker this suite's
#      later assertions depend on ("Node.js", "GitHub CLI", "Claude Code",
#      "Git (" ,"not found") — i.e. the two copies stay IN STEP with each
#      other and with what this test asserts, rather than a byte-count
#      snapshot of one moment in time.
# Line/command-count are still MEASURED and printed for human debugging
# context, but no longer asserted.
# ─────────────────────────────────────────────────────────────────────────────
_block_start "grounding: bin/aiteamforge-doctor.sh defines check_dependencies()+check_result()+_x1097_resolve() and stays in step with the markers this suite asserts"
_BIN_LINES="$(wc -l < "$BIN_DOCTOR" | tr -d '[:space:]')"
_BIN_CMDV="$(grep -c 'command -v' "$BIN_DOCTOR" | tr -d '[:space:]')"
echo "    (informational, not asserted) bin/aiteamforge-doctor.sh: ${_BIN_LINES} lines, ${_BIN_CMDV} 'command -v' occurrences"
grep -q '^check_dependencies()' "$BIN_DOCTOR" || _block_note_fail "bin/aiteamforge-doctor.sh no longer defines check_dependencies() — sed-range extraction below would go silently empty"
grep -q '^check_result()' "$BIN_DOCTOR" || _block_note_fail "bin/aiteamforge-doctor.sh no longer defines check_result() — sed-range extraction below would go silently empty"
# XACA-1097-016 hardening: the tool resolver was consolidated from TWO
# helpers (a nested one inside check_dependencies() plus, in the libexec
# copy only, a second file-scope brew-only one) down to ONE, at file scope,
# named _x1097_resolve() in BOTH copies -- see that function's comment in
# each file for the dual-doctor-drift rationale. It must be defined at
# file scope (column 0, i.e. NOT indented/nested) so a regression back to
# nesting it inside check_dependencies() is caught here rather than by the
# extraction below silently going empty.
grep -q '^_x1097_resolve()' "$BIN_DOCTOR" || _block_note_fail "bin/aiteamforge-doctor.sh no longer defines _x1097_resolve() at file scope — sed-range extraction below would go silently empty"
for _marker in "Node.js" "GitHub CLI" "Claude Code" "Git (" "not found"; do
    grep -qF -- "$_marker" "$BIN_DOCTOR" || _block_note_fail "bin/aiteamforge-doctor.sh no longer contains marker [$_marker] this suite's assertions depend on"
done
_block_end

_block_start "grounding: libexec/commands/aiteamforge-doctor.sh defines check_dependencies()+check_result()+_x1097_resolve() and stays in step with the markers this suite asserts"
_LIB_LINES="$(wc -l < "$LIBEXEC_DOCTOR" | tr -d '[:space:]')"
_LIB_CMDV="$(grep -c 'command -v' "$LIBEXEC_DOCTOR" | tr -d '[:space:]')"
echo "    (informational, not asserted) libexec/commands/aiteamforge-doctor.sh: ${_LIB_LINES} lines, ${_LIB_CMDV} 'command -v' occurrences"
grep -q '^check_dependencies()' "$LIBEXEC_DOCTOR" || _block_note_fail "libexec/commands/aiteamforge-doctor.sh no longer defines check_dependencies() — sed-range extraction below would go silently empty"
grep -q '^check_result()' "$LIBEXEC_DOCTOR" || _block_note_fail "libexec/commands/aiteamforge-doctor.sh no longer defines check_result() — sed-range extraction below would go silently empty"
grep -q '^_x1097_resolve()' "$LIBEXEC_DOCTOR" || _block_note_fail "libexec/commands/aiteamforge-doctor.sh no longer defines _x1097_resolve() at file scope — sed-range extraction below would go silently empty"
# XACA-1097-016 hardening: fail loudly if the OLD brew-only helper name
# reappears (or a nested duplicate resolver is reintroduced) -- both would
# be a regression back to the two-helpers-per-file drift this fix removed.
grep -q '_xaca1097_brew_path' "$LIBEXEC_DOCTOR" && _block_note_fail "libexec/commands/aiteamforge-doctor.sh still references the retired _xaca1097_brew_path helper -- resolver consolidation regressed"
for _marker in "Node.js" "GitHub CLI" "Claude Code" "Git (" "not found"; do
    grep -qF -- "$_marker" "$LIBEXEC_DOCTOR" || _block_note_fail "libexec/commands/aiteamforge-doctor.sh no longer contains marker [$_marker] this suite's assertions depend on"
done
_block_end

_block_start "grounding: both doctor copies stay IN STEP with each other (same tool-check markers present in both)"
for _marker in "Node.js" "GitHub CLI" "Claude Code" "Git (" "not found"; do
    _in_bin=false; _in_lib=false
    grep -qF -- "$_marker" "$BIN_DOCTOR" && _in_bin=true
    grep -qF -- "$_marker" "$LIBEXEC_DOCTOR" && _in_lib=true
    if [ "$_in_bin" != "$_in_lib" ]; then
        _block_note_fail "marker [$_marker] present in only ONE doctor copy (bin=$_in_bin libexec=$_in_lib) — the two copies have drifted out of step"
    fi
done
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# Fixture sandbox — extract the REAL check_result()/check_dependencies()
# function bodies verbatim via sed range (not reimplemented) so the test
# exercises the actual authoritative logic.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1097-doctor-deps-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi

_cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap _cleanup EXIT INT TERM

SANDBOX="$TEST_TMP_DIR/xaca1097-doctor-deps"
mkdir -p "$SANDBOX"

# XACA-1097-016: the resolver used by check_dependencies() was consolidated
# to a single FILE-SCOPE helper, _x1097_resolve() (previously nested inside
# check_dependencies() itself, which is why the original extraction below
# didn't need a separate range for it -- it rode along inside the
# check_dependencies() range). File-scope placement means it now lives
# OUTSIDE that range, so it needs its own sed extraction here, ordered
# before check_dependencies() so the function is defined before it's called
# in the sandboxed source. Without this, the sandboxed check_dependencies()
# would call an undefined _x1097_resolve and crash -- exactly the failure
# mode the file-scope-vs-nested design comment in both doctor copies warns
# about.
BIN_EXTRACT="$SANDBOX/bin-check-dependencies.sh"
{
    sed -n '/^check_result()/,/^}/p' "$BIN_DOCTOR"
    echo
    sed -n '/^_x1097_resolve()/,/^}/p' "$BIN_DOCTOR"
    echo
    sed -n '/^check_dependencies()/,/^}/p' "$BIN_DOCTOR"
} > "$BIN_EXTRACT"

LIBEXEC_EXTRACT="$SANDBOX/libexec-check-dependencies.sh"
{
    sed -n '/^check_result()/,/^}/p' "$LIBEXEC_DOCTOR"
    echo
    sed -n '/^_x1097_resolve()/,/^}/p' "$LIBEXEC_DOCTOR"
    echo
    sed -n '/^check_dependencies()/,/^}/p' "$LIBEXEC_DOCTOR"
} > "$LIBEXEC_EXTRACT"

# Restricted, non-login-shell-shaped PATH: excludes /opt/homebrew/bin,
# /usr/local/bin, ~/.local/bin, AND the Herd/nvm bin dir — only the stock
# macOS system directories remain. Confirmed empty-handed for node/gh under
# this PATH directly (see header WIDENED REQUIREMENT note); git/python3/jq
# remain reachable here via Apple's /usr/bin stubs — that's what makes them
# usable as the Problem-1 positive marker below.
RESTRICTED_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# ─────────────────────────────────────────────────────────────────────────────
# Ground truth: ambient (unrestricted) PATH resolution — i.e. what a login
# shell actually finds — NOT a hardcoded candidate-directory check. See
# header WIDENED REQUIREMENT / HONEST LIMITATION notes for why this
# replaced the original `[ -x "/opt/homebrew/bin/node" ]` style check.
# ─────────────────────────────────────────────────────────────────────────────
REAL_NODE="$(command -v node 2>/dev/null || true)"
REAL_GH="$(command -v gh 2>/dev/null || true)"
REAL_CLAUDE="$(command -v claude 2>/dev/null || true)"

_block_start "sanity: node/gh/claude genuinely exist on disk (ambient/login-shell resolution, not a hardcoded directory guess)"
[ -n "$REAL_NODE" ] && [ -x "$REAL_NODE" ] || _block_note_fail "fixture broken: no real 'node' binary resolvable on this machine at all"
[ -n "$REAL_GH" ] && [ -x "$REAL_GH" ] || _block_note_fail "fixture broken: no real 'gh' binary resolvable on this machine at all"
[ -n "$REAL_CLAUDE" ] && [ -x "$REAL_CLAUDE" ] || _block_note_fail "fixture broken: no real 'claude' binary resolvable on this machine at all"
_block_end

_block_start "widened requirement: ambient node path is evidence a fixed 3-directory candidate list is insufficient"
case "$REAL_NODE" in
    *" "*) : ;; # contains a space, as expected/measured — no action
    *) echo "    (informational) ambient node path has no space on this run: $REAL_NODE" ;;
esac
assert_not_contains "$REAL_NODE" "/opt/homebrew/bin/" \
    "expected the ambient-resolved node to sit OUTSIDE /opt/homebrew/bin on this machine (measured Herd/nvm path) — if this fails, this run's environment no longer demonstrates the widened case (a stock Homebrew-only node), re-verify before trusting the rest of this block"
assert_not_contains "$REAL_NODE" "/usr/local/bin/" \
    "expected the ambient-resolved node to sit OUTSIDE /usr/local/bin on this machine"
assert_not_contains "$REAL_NODE" "$HOME/.local/bin/" \
    "expected the ambient-resolved node to sit OUTSIDE ~/.local/bin on this machine"
assert_contains "$REAL_NODE" " " \
    "expected the ambient-resolved node path to contain a space (measured Herd 'Application Support' path) — a resolver that word-splits an unquoted path will break on this"
_block_end

# Run the extracted, REAL check_dependencies() under the restricted PATH.
# Strips ANSI color codes for reliable substring assertions (matches
# test-xaca-1095-017-helpers-drift-check.sh's convention).
_run_check() {
    local extract="$1"
    shift
    PATH="$RESTRICTED_PATH" /bin/bash -c "
        TOTAL_CHECKS=0 PASSED_CHECKS=0 FAILED_CHECKS=0 WARNING_CHECKS=0 VERBOSE=false
        RED='' GREEN='' YELLOW='' NC=''
        unset AITEAMFORGE_PYTHON
        $* 2>/dev/null
        source '$extract'
        check_dependencies
    " 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}

# ─────────────────────────────────────────────────────────────────────────────
# bin/aiteamforge-doctor.sh
# ─────────────────────────────────────────────────────────────────────────────
_block_start "bin/aiteamforge-doctor.sh: must not report Node.js/GitHub CLI/Claude Code missing when they exist outside a restricted PATH (XACA-1097)"
BIN_OUTPUT="$(_run_check "$BIN_EXTRACT")"
# XACA-1097-007 hardening (Problem 1): positive assertions FIRST, paired
# with every negative assertion below. If the sed-range extraction seam
# ever breaks (function moved, source() failed, etc.), BIN_OUTPUT would be
# empty and EVERY assert_not_contains below would pass vacuously — proved:
#     haystack=""; [[ "$haystack" != *"needle"* ]] -> TRUE
# "Git (" is a real check_result-emitted marker for a dependency (git) that
# genuinely IS reachable under RESTRICTED_PATH via Apple's /usr/bin/git
# stub (verified: `PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v git`
# resolves) — so its presence proves check_dependencies() actually ran the
# real logic, not that the fixture merely produced SOME text.
assert_not_empty "$BIN_OUTPUT" \
    "bin/aiteamforge-doctor.sh: check_dependencies() produced NO output at all — fixture is broken (sed extraction/source likely failed), every assert_not_contains below would otherwise pass vacuously"
assert_contains "$BIN_OUTPUT" "Git (" \
    "bin/aiteamforge-doctor.sh: expected a real 'Git (' pass line (git is reachable even under the restricted PATH via /usr/bin/git) — its absence means check_dependencies() did not actually execute its real logic"
assert_not_contains "$BIN_OUTPUT" "Node.js not found" \
    "node exists at ${REAL_NODE:-<unresolved>} but was reported not found under a restricted PATH"
assert_not_contains "$BIN_OUTPUT" "GitHub CLI not found" \
    "gh exists at ${REAL_GH:-<unresolved>} but was reported not found under a restricted PATH"
assert_not_contains "$BIN_OUTPUT" "Claude Code not found" \
    "claude exists at ${REAL_CLAUDE:-<unresolved>} but was reported not found under a restricted PATH"
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# libexec/commands/aiteamforge-doctor.sh (sources common.sh for print_success/
# print_error/print_warning, which its check_result() calls)
# ─────────────────────────────────────────────────────────────────────────────
_block_start "libexec/commands/aiteamforge-doctor.sh: must not report Node.js/GitHub CLI/Claude Code missing when they exist outside a restricted PATH (XACA-1097)"
LIBEXEC_OUTPUT="$(_run_check "$LIBEXEC_EXTRACT" "source '$COMMON_LIB'")"
assert_not_empty "$LIBEXEC_OUTPUT" \
    "libexec/commands/aiteamforge-doctor.sh: check_dependencies() produced NO output at all — fixture is broken, every assert_not_contains below would otherwise pass vacuously"
assert_contains "$LIBEXEC_OUTPUT" "Git (" \
    "libexec/commands/aiteamforge-doctor.sh: expected a real 'Git (' pass line (git is reachable even under the restricted PATH via /usr/bin/git) — its absence means check_dependencies() did not actually execute its real logic"
assert_not_contains "$LIBEXEC_OUTPUT" "Node.js not found" \
    "node exists at ${REAL_NODE:-<unresolved>} but was reported not found under a restricted PATH"
assert_not_contains "$LIBEXEC_OUTPUT" "GitHub CLI not found" \
    "gh exists at ${REAL_GH:-<unresolved>} but was reported not found under a restricted PATH"
assert_not_contains "$LIBEXEC_OUTPUT" "Claude Code not found" \
    "claude exists at ${REAL_CLAUDE:-<unresolved>} but was reported not found under a restricted PATH"
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone mode only — test-runner.sh tallies pass/fail from its
# OWN exported functions' output).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "──────────────────────────────────────────────"
    echo "  doctor phantom-missing-deps test:  PASS=$_PASS  FAIL=$_FAIL"
    echo "──────────────────────────────────────────────"
    [ "$_FAIL" -eq 0 ] || exit 1
fi
exit 0
