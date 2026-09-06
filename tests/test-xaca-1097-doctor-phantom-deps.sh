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
# XACA-1097-019 hardening: the login-PATH probe was split out of
# _x1097_resolve() into its own file-scope function, _x1097_prime_login_path(),
# so it can be called EAGERLY (and directly, never via `$( )`) as the first
# statement of check_dependencies() -- that is what makes the memoization
# genuinely take effect process-wide instead of being reset every subshell.
# It must stay at file scope (same rationale as _x1097_resolve() above) or
# the sandboxed extraction below goes silently empty/undefined.
grep -q '^_x1097_prime_login_path()' "$BIN_DOCTOR" || _block_note_fail "bin/aiteamforge-doctor.sh no longer defines _x1097_prime_login_path() at file scope — sed-range extraction below would go silently empty, and _x1097_resolve()/check_dependencies() would call an undefined function"
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
# XACA-1097-019 hardening: see the matching bin/ grounding block above for
# the full rationale -- the login-PATH probe now lives in its own file-scope
# function so it can be primed eagerly, outside any `$( )` subshell.
grep -q '^_x1097_prime_login_path()' "$LIBEXEC_DOCTOR" || _block_note_fail "libexec/commands/aiteamforge-doctor.sh no longer defines _x1097_prime_login_path() at file scope — sed-range extraction below would go silently empty, and _x1097_resolve()/check_dependencies() would call an undefined function"
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

# XACA-1097 review round 3, finding 1b: a flat reap-pid file, drained
# unconditionally by _cleanup(), so a hung-$SHELL fixture spawned later in
# this file (the set -e hazard block) can never leak a stray process on
# ANY exit path -- normal completion, an assertion that short-circuits the
# block, Ctrl-C, or this whole script being killed by an outer runner
# timeout. Matches the convention in test-xaca-1097-resolver-call-sites.sh
# BLOCK E's own reap-tracking, added for the same finding.
_X1097_REAP_FILE="$(mktemp -t xaca1097-deps-reap.XXXXXX 2>/dev/null || echo /tmp/xaca1097-deps-reap.$$)"
_reap_track() {
    [ -n "${1:-}" ] && echo "$1" >> "$_X1097_REAP_FILE"
}
_cleanup() {
    if [ -n "${_X1097_REAP_FILE:-}" ] && [ -f "$_X1097_REAP_FILE" ]; then
        local _rp
        while IFS= read -r _rp; do
            [ -n "$_rp" ] && kill -TERM "$_rp" 2>/dev/null
        done < "$_X1097_REAP_FILE"
        sleep 0.2
        while IFS= read -r _rp; do
            [ -n "$_rp" ] && kill -KILL "$_rp" 2>/dev/null
        done < "$_X1097_REAP_FILE"
        rm -f "$_X1097_REAP_FILE"
    fi
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
#
# XACA-1097-019: _x1097_resolve() itself now delegates its login-PATH probe
# to a SEPARATE file-scope function, _x1097_prime_login_path() (split out so
# check_dependencies() can call it eagerly, directly, before any `$( )`
# subshell -- see that function's header comment in both doctor copies for
# why). It must be extracted here too, ordered BEFORE _x1097_resolve() (which
# calls it) and BEFORE check_dependencies() (which also calls it directly as
# its first statement) -- both would otherwise call an undefined function in
# the sandboxed source.
BIN_EXTRACT="$SANDBOX/bin-check-dependencies.sh"
{
    sed -n '/^check_result()/,/^}/p' "$BIN_DOCTOR"
    echo
    sed -n '/^_x1097_prime_login_path()/,/^}/p' "$BIN_DOCTOR"
    echo
    sed -n '/^_x1097_resolve()/,/^}/p' "$BIN_DOCTOR"
    echo
    sed -n '/^check_dependencies()/,/^}/p' "$BIN_DOCTOR"
} > "$BIN_EXTRACT"

LIBEXEC_EXTRACT="$SANDBOX/libexec-check-dependencies.sh"
{
    sed -n '/^check_result()/,/^}/p' "$LIBEXEC_DOCTOR"
    echo
    sed -n '/^_x1097_prime_login_path()/,/^}/p' "$LIBEXEC_DOCTOR"
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

# XACA-1097-019 hardening (CI portability, review finding on PR #824): the
# original version of this block hard-REQUIRED all three of node/gh/claude
# to exist on disk, and hard-REQUIRED the ambient node path specifically to
# contain a space and sit outside three named directories. Both were true on
# the M3Pro dev box this suite was drafted on, and NEITHER is guaranteed
# elsewhere: `claude` is a niche third-party CLI the CI job's `brew install
# jq bash tmux` step never installs, and a CI runner's node (however it got
# there) has no particular reason to live under a space-containing path the
# way this box's Herd/nvm install happens to.
#
# Every probe below is now CONDITIONAL: present -> assert against it;
# absent -> print a loud, unambiguous SKIP line and make NO assertion for
# that tool. A skip must never be able to masquerade as a pass -- these are
# not `assert_*` calls returning true on an empty haystack, they are `echo`
# lines that run INSTEAD of an assertion, so nothing is silently satisfied.
# On THIS dev box all three tools are present and the space-containing case
# is real, so every conditional below still fires and the suite still
# DISCRIMINATES exactly as before (see the per-tool "must not report ...
# missing" blocks below, which are the actual regression check and are
# gated the same way).
_x1097_test_present_tools=""
[ -n "$REAL_NODE" ]   && _x1097_test_present_tools="${_x1097_test_present_tools}node "
[ -n "$REAL_GH" ]     && _x1097_test_present_tools="${_x1097_test_present_tools}gh "
[ -n "$REAL_CLAUDE" ] && _x1097_test_present_tools="${_x1097_test_present_tools}claude "

_block_start "sanity: at least one of node/gh/claude genuinely exists on disk (ambient/login-shell resolution, not a hardcoded directory guess) -- per-tool checks below are conditional, not hard-required"
if [ -n "$REAL_NODE" ]; then
    [ -x "$REAL_NODE" ] || _block_note_fail "fixture broken: 'command -v node' resolved to ${REAL_NODE} but it is not executable"
else
    echo "    SKIP: node not resolvable on this machine/runner -- the phantom-missing assertion for node below will also skip"
fi
if [ -n "$REAL_GH" ]; then
    [ -x "$REAL_GH" ] || _block_note_fail "fixture broken: 'command -v gh' resolved to ${REAL_GH} but it is not executable"
else
    echo "    SKIP: gh not resolvable on this machine/runner -- the phantom-missing assertion for gh below will also skip"
fi
if [ -n "$REAL_CLAUDE" ]; then
    [ -x "$REAL_CLAUDE" ] || _block_note_fail "fixture broken: 'command -v claude' resolved to ${REAL_CLAUDE} but it is not executable"
else
    echo "    SKIP: claude not resolvable on this machine/runner (expected in CI -- it is a third-party CLI the test job never installs) -- the phantom-missing assertion for claude below will also skip"
fi
# A run where ALL THREE are absent tests nothing beyond the "Git (" marker
# below -- that is a genuinely broken/pathological runner (git/jq/python3
# are always present via Apple's /usr/bin stubs; node and gh ship on
# GitHub's macos-latest image by default), not merely "no claude". Fail
# loudly rather than let a fully-skipped run report success on assertions
# it never made.
[ -n "$_x1097_test_present_tools" ] || _block_note_fail "fixture provides ZERO phantom-deps candidates (node, gh, AND claude all unresolvable) -- this suite cannot exercise its core assertion on this runner at all; investigate the runner/PATH, this is not just 'claude is absent'"
_block_end

_block_start "widened requirement: IF any probed tool's ambient path contains a space, the resolver must still be exercised against a candidate outside the 3 static directories"
_X1097_SPACE_TOOL=""
_X1097_SPACE_PATH=""
for _x1097_pair in "node:$REAL_NODE" "gh:$REAL_GH" "claude:$REAL_CLAUDE"; do
    _x1097_cand_name="${_x1097_pair%%:*}"
    _x1097_cand_path="${_x1097_pair#*:}"
    case "$_x1097_cand_path" in
        *" "*)
            _X1097_SPACE_TOOL="$_x1097_cand_name"
            _X1097_SPACE_PATH="$_x1097_cand_path"
            break
            ;;
    esac
done
if [ -z "$_X1097_SPACE_TOOL" ]; then
    echo "    SKIP: no probed tool (node/gh/claude) resolves to a space-containing ambient path in this environment -- cannot demonstrate the widened (space-containing, off-the-3-static-dirs) case here. No assertion is being silently satisfied by an empty haystack: none is being made for this specific case at all. (Measured on the original dev box: Herd/nvm node contains a space; a CI runner's node/gh typically will not.)"
else
    echo "    (informational) demonstrating the widened case via: ${_X1097_SPACE_TOOL} -> ${_X1097_SPACE_PATH}"
    assert_not_contains "$_X1097_SPACE_PATH" "/opt/homebrew/bin/" \
        "expected the ambient-resolved ${_X1097_SPACE_TOOL} to sit OUTSIDE /opt/homebrew/bin on this machine — if this fails, this run's environment no longer demonstrates the widened case, re-verify before trusting the rest of this block"
    assert_not_contains "$_X1097_SPACE_PATH" "/usr/local/bin/" \
        "expected the ambient-resolved ${_X1097_SPACE_TOOL} to sit OUTSIDE /usr/local/bin on this machine"
    assert_not_contains "$_X1097_SPACE_PATH" "$HOME/.local/bin/" \
        "expected the ambient-resolved ${_X1097_SPACE_TOOL} to sit OUTSIDE ~/.local/bin on this machine"
fi
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
# XACA-1097-019 hardening (CI portability): conditional on the tool actually
# being resolvable in THIS environment (see the sanity block above) — never
# hard-required. Absent tool -> loud SKIP, no assertion made (never a
# vacuous pass). Present tool -> the real regression assertion, unchanged.
if [ -n "$REAL_NODE" ]; then
    assert_not_contains "$BIN_OUTPUT" "Node.js not found" \
        "node exists at ${REAL_NODE} but was reported not found under a restricted PATH"
else
    echo "    SKIP: node not resolvable in this environment -- cannot assert non-phantom detection for a tool that doesn't exist here"
fi
if [ -n "$REAL_GH" ]; then
    assert_not_contains "$BIN_OUTPUT" "GitHub CLI not found" \
        "gh exists at ${REAL_GH} but was reported not found under a restricted PATH"
else
    echo "    SKIP: gh not resolvable in this environment -- cannot assert non-phantom detection for a tool that doesn't exist here"
fi
if [ -n "$REAL_CLAUDE" ]; then
    assert_not_contains "$BIN_OUTPUT" "Claude Code not found" \
        "claude exists at ${REAL_CLAUDE} but was reported not found under a restricted PATH"
else
    echo "    SKIP: claude not resolvable in this environment (expected in CI) -- cannot assert non-phantom detection for a tool that doesn't exist here"
fi
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
# XACA-1097-019 hardening (CI portability) — see the matching bin/ block
# above for the full rationale: conditional per tool, loud SKIP (never a
# vacuous pass) when a tool is not resolvable in this environment.
if [ -n "$REAL_NODE" ]; then
    assert_not_contains "$LIBEXEC_OUTPUT" "Node.js not found" \
        "node exists at ${REAL_NODE} but was reported not found under a restricted PATH"
else
    echo "    SKIP: node not resolvable in this environment -- cannot assert non-phantom detection for a tool that doesn't exist here"
fi
if [ -n "$REAL_GH" ]; then
    assert_not_contains "$LIBEXEC_OUTPUT" "GitHub CLI not found" \
        "gh exists at ${REAL_GH} but was reported not found under a restricted PATH"
else
    echo "    SKIP: gh not resolvable in this environment -- cannot assert non-phantom detection for a tool that doesn't exist here"
fi
if [ -n "$REAL_CLAUDE" ]; then
    assert_not_contains "$LIBEXEC_OUTPUT" "Claude Code not found" \
        "claude exists at ${REAL_CLAUDE} but was reported not found under a restricted PATH"
else
    echo "    SKIP: claude not resolvable in this environment (expected in CI) -- cannot assert non-phantom detection for a tool that doesn't exist here"
fi
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# XACA-1097 review round 3, finding 1b: no existing suite EVER runs
# check_dependencies()/_x1097_prime_login_path() under the shell options the
# SHIPPED script actually uses. _run_check() above sources the extraction
# under a bare `/bin/bash -c` with NO `set -eo pipefail` -- so a defect that
# only manifests under `set -e` (round 3 finding 1: a bare `kill -KILL`
# returning nonzero on an already-reaped pid aborted the ENTIRE script
# before a single dependency verdict was printed -- measured end-to-end
# against the real script: exit 1, last line "Install Profile: full", 0
# warnings, 0 dependency verdicts) passed every existing test, including
# this one, unchanged. This block closes that gap: it runs the SAME
# extracted check_dependencies() under `set -eo pipefail` (matching
# bin/aiteamforge-doctor.sh:5 / libexec/commands/aiteamforge-doctor.sh:6
# exactly) with a $SHELL that hangs past the configured probe timeout, and
# asserts the run actually COMPLETES, prints the fallback warning, AND
# produces real dependency verdicts -- not merely "did not crash".
#
# PRE-FIX negative control: commit 513500a is the exact commit this
# finding's fix sits on top of (review round 2's landing, immediately
# before round 3) -- not a hand-typed guess, same convention as BLOCK E in
# test-xaca-1097-resolver-call-sites.sh. Re-running this same harness
# against that commit's doctor copies must reproduce the historical defect
# (run aborts partway, 0 verdicts) -- proving this suite would have caught
# it before it shipped.
# ─────────────────────────────────────────────────────────────────────────────
SETE_SANDBOX="$SANDBOX/sete-hazard"
mkdir -p "$SETE_SANDBOX"
X1097_SETE_PREFIX_COMMIT="513500a"

FAKE_HANG_SHELL_SETE="$SETE_SANDBOX/fake-shell-hang.sh"
cat > "$FAKE_HANG_SHELL_SETE" <<'FAKESHELL'
#!/bin/bash
# Simulates a stuck ~/.zshrc during "$SHELL -ilc ...": hangs well past any
# configured probe timeout, and records its own pid first so this suite can
# verify (and, if needed, force-clean) it afterward. Bash-3.2-safe: no
# $BASHPID (bash 4+ only, measured silently empty under macOS's shipped
# /bin/bash) -- $$ inside a real child process (not a `()` subshell) is
# correct on 3.2.
: "${X1097_SETE_HANG_PIDFILE:?X1097_SETE_HANG_PIDFILE must be set}"
echo "$$" > "$X1097_SETE_HANG_PIDFILE"
exec sleep 1000000
FAKESHELL
chmod +x "$FAKE_HANG_SHELL_SETE"

# Runs the given extraction's check_dependencies() under set -eo pipefail
# (matching the shipped script's own top-of-file option, not the bare
# /bin/bash -c every OTHER block in this file uses), backgrounded with an
# outer poll bound so a genuinely-unbounded regression fails this suite in
# bounded time instead of hanging it. Prints "RC:<n>" then the raw
# (ANSI-colored) combined stdout+stderr, capture-first -- never `cmd | tail`
# (see feedback_pipefail_hides_exit_code.md).
_run_check_sete() {
    local extract="$1" fake_shell="$2" outfile="$3"; shift 3
    local hang_pidfile="$SETE_SANDBOX/$$.hangpid"
    rm -f "$hang_pidfile"
    (
        X1097_SETE_HANG_PIDFILE="$hang_pidfile" \
        PATH="$RESTRICTED_PATH" SHELL="$fake_shell" \
        AITEAMFORGE_LOGIN_PROBE_TIMEOUT_SECS=1 \
        /bin/bash -c "
            set -eo pipefail
            TOTAL_CHECKS=0 PASSED_CHECKS=0 FAILED_CHECKS=0 WARNING_CHECKS=0 VERBOSE=false
            RED='' GREEN='' YELLOW='' NC=''
            unset AITEAMFORGE_PYTHON
            $* 2>/dev/null
            source '$extract'
            check_dependencies
            printf '__SETE_SUITE_COMPLETED__\n'
        " > "$outfile" 2>&1
        echo "$?" > "${outfile}.rc"
    ) &
    local wrap_pid=$!
    _reap_track "$wrap_pid"
    local waited=0
    while [ "$waited" -lt 8 ] && kill -0 "$wrap_pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$wrap_pid" 2>/dev/null; then
        local hang_pid
        hang_pid="$(cat "$hang_pidfile" 2>/dev/null || true)"
        _reap_track "$hang_pid"
        _reap_track "$wrap_pid"
        kill -TERM "$wrap_pid" "$hang_pid" 2>/dev/null
        sleep 0.3
        kill -KILL "$wrap_pid" "$hang_pid" 2>/dev/null
        wait "$wrap_pid" 2>/dev/null
        echo "TIMEOUT" > "${outfile}.timedout"
    else
        wait "$wrap_pid" 2>/dev/null
        local hang_pid
        hang_pid="$(cat "$hang_pidfile" 2>/dev/null || true)"
        # Force-clean defensively even on the fast path: if the fixed code's
        # process-group kill worked, this is already dead; if not, don't
        # leak it just because THIS block isn't the one testing that part.
        [ -n "$hang_pid" ] && { kill -TERM "$hang_pid" 2>/dev/null; sleep 0.2; kill -KILL "$hang_pid" 2>/dev/null; }
    fi
}

SETE_POST_OUT="$SETE_SANDBOX/post.out"
_block_start "XACA-1097 defect [set -e hazard, POST-FIX]: bin/aiteamforge-doctor.sh's check_dependencies() completes, warns, and produces real verdicts under set -eo pipefail with a hung \$SHELL"
_run_check_sete "$BIN_EXTRACT" "$FAKE_HANG_SHELL_SETE" "$SETE_POST_OUT"
if [ -f "${SETE_POST_OUT}.timedout" ]; then
    _block_note_fail "did not return within the 8s outer bound -- a hung \$SHELL under set -eo pipefail is not just aborting early, it is HANGING; this would have hung whatever CI job ran it"
else
    SETE_POST_RC="$(cat "${SETE_POST_OUT}.rc" 2>/dev/null || echo "")"
    SETE_POST_TEXT="$(cat "$SETE_POST_OUT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
    assert_not_empty "$SETE_POST_TEXT" "fixture produced no output at all -- broken control"
    assert_eq "$SETE_POST_RC" "0" \
        "expected the FIXED extraction to exit 0 under set -eo pipefail with a hung \$SHELL; got rc=${SETE_POST_RC}, output: $SETE_POST_TEXT"
    assert_contains "$SETE_POST_TEXT" "__SETE_SUITE_COMPLETED__" \
        "check_dependencies() did not run to completion under set -eo pipefail -- the script aborted partway (this is the exact XACA-1097 round 3 finding 1 shape); output: $SETE_POST_TEXT"
    assert_contains "$SETE_POST_TEXT" "exceeded" \
        "expected the fallback warning ('...exceeded Ns and was aborted...') to print -- its absence means the timeout branch never ran or the script died before reaching it; output: $SETE_POST_TEXT"
    assert_contains "$SETE_POST_TEXT" "Git (" \
        "expected a REAL dependency verdict (git, reachable under the restricted PATH via /usr/bin/git) -- its absence means 0 verdicts were produced, matching the pre-fix symptom; output: $SETE_POST_TEXT"
fi
_block_end

SETE_POST_LIB_OUT="$SETE_SANDBOX/post-lib.out"
_block_start "XACA-1097 defect [set -e hazard, POST-FIX]: libexec/commands/aiteamforge-doctor.sh's check_dependencies() completes, warns, and produces real verdicts under set -eo pipefail with a hung \$SHELL"
_run_check_sete "$LIBEXEC_EXTRACT" "$FAKE_HANG_SHELL_SETE" "$SETE_POST_LIB_OUT" "source '$COMMON_LIB'"
if [ -f "${SETE_POST_LIB_OUT}.timedout" ]; then
    _block_note_fail "did not return within the 8s outer bound -- a hung \$SHELL under set -eo pipefail is not just aborting early, it is HANGING; this would have hung whatever CI job ran it"
else
    SETE_POST_LIB_RC="$(cat "${SETE_POST_LIB_OUT}.rc" 2>/dev/null || echo "")"
    SETE_POST_LIB_TEXT="$(cat "$SETE_POST_LIB_OUT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
    assert_not_empty "$SETE_POST_LIB_TEXT" "fixture produced no output at all -- broken control"
    assert_eq "$SETE_POST_LIB_RC" "0" \
        "expected the FIXED extraction to exit 0 under set -eo pipefail with a hung \$SHELL; got rc=${SETE_POST_LIB_RC}, output: $SETE_POST_LIB_TEXT"
    assert_contains "$SETE_POST_LIB_TEXT" "__SETE_SUITE_COMPLETED__" \
        "check_dependencies() did not run to completion under set -eo pipefail -- the script aborted partway; output: $SETE_POST_LIB_TEXT"
    assert_contains "$SETE_POST_LIB_TEXT" "exceeded" \
        "expected the fallback warning to print; output: $SETE_POST_LIB_TEXT"
    assert_contains "$SETE_POST_LIB_TEXT" "Git (" \
        "expected a REAL dependency verdict -- its absence means 0 verdicts were produced, matching the pre-fix symptom; output: $SETE_POST_LIB_TEXT"
fi
_block_end

_block_start "XACA-1097 defect [set -e hazard, PRE-FIX negative control, commit $X1097_SETE_PREFIX_COMMIT]: reproduces the historical abort -- proves this suite would have caught it"
SETE_PRE_FULL="$SETE_SANDBOX/pre-fix-full.sh"
if git -C "$TAP_ROOT" cat-file -e "$X1097_SETE_PREFIX_COMMIT" 2>/dev/null && \
   git -C "$TAP_ROOT" show "$X1097_SETE_PREFIX_COMMIT:bin/aiteamforge-doctor.sh" > "$SETE_PRE_FULL" 2>/dev/null; then
    if grep -q '^check_dependencies()' "$SETE_PRE_FULL"; then
        SETE_PRE_EXTRACT="$SETE_SANDBOX/pre-fix-extract.sh"
        {
            sed -n '/^check_result()/,/^}/p' "$SETE_PRE_FULL"
            echo
            sed -n '/^_x1097_prime_login_path()/,/^}/p' "$SETE_PRE_FULL"
            echo
            sed -n '/^_x1097_resolve()/,/^}/p' "$SETE_PRE_FULL"
            echo
            sed -n '/^check_dependencies()/,/^}/p' "$SETE_PRE_FULL"
        } > "$SETE_PRE_EXTRACT"
        assert_not_empty "$(cat "$SETE_PRE_EXTRACT")" "pre-fix extraction produced nothing -- fixture broken"
        # Check the SPECIFIC kill -KILL line this finding is about, not a
        # blanket "no '|| true' anywhere" scan -- _x1097_prime_login_path()
        # already had an unrelated, legitimate `|| true` on its `mktemp`
        # line at commit 513500a (pre-dating this finding entirely), so a
        # blanket scan false-fails this grounding check every time.
        assert_contains "$(cat "$SETE_PRE_EXTRACT")" 'kill -KILL -- "-$_x1097_probe_pid" 2>/dev/null' \
            "pre-fix fixture (commit $X1097_SETE_PREFIX_COMMIT) does not contain the exact unguarded kill -KILL line this finding is about -- fixture selection is wrong"
        assert_not_contains "$(cat "$SETE_PRE_EXTRACT")" 'kill -KILL -- "-$_x1097_probe_pid" 2>/dev/null || true' \
            "pre-fix fixture (commit $X1097_SETE_PREFIX_COMMIT) already guards its kill -KILL with '|| true' -- this is not the pre-fix shape, fixture selection is wrong"
        SETE_PRE_OUT="$SETE_SANDBOX/pre.out"
        _run_check_sete "$SETE_PRE_EXTRACT" "$FAKE_HANG_SHELL_SETE" "$SETE_PRE_OUT"
        if [ -f "${SETE_PRE_OUT}.timedout" ]; then
            _block_note_fail "pre-fix (commit $X1097_SETE_PREFIX_COMMIT) fixture did not return within the 8s outer bound -- unexpected shape (finding 1 is a fast abort, not a hang); investigate before trusting this control"
        else
            SETE_PRE_RC="$(cat "${SETE_PRE_OUT}.rc" 2>/dev/null || echo "")"
            SETE_PRE_TEXT="$(cat "$SETE_PRE_OUT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
            if [ "$SETE_PRE_RC" = "0" ] && [[ "$SETE_PRE_TEXT" == *"__SETE_SUITE_COMPLETED__"* ]]; then
                _block_note_fail "expected the pre-fix code to ABORT partway under set -eo pipefail with a hung \$SHELL, but it completed normally (rc=0, completion marker present) -- this negative control did not reproduce the historical defect; output: $SETE_PRE_TEXT"
            fi
            assert_not_contains "$SETE_PRE_TEXT" "Git (" \
                "expected the pre-fix code to produce ZERO dependency verdicts (aborted before reaching them, matching the measured real-script symptom), but a real verdict is present -- this negative control did not reproduce the historical defect; output: $SETE_PRE_TEXT"
        fi
    else
        _block_note_fail "commit $X1097_SETE_PREFIX_COMMIT no longer defines check_dependencies() -- cannot build the pre-fix fixture"
    fi
else
    echo "    SKIP: commit $X1097_SETE_PREFIX_COMMIT not resolvable in this checkout -- pre-fix negative control skipped; POST-FIX assertions above still run and still gate the suite"
fi
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
