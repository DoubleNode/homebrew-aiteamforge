#!/bin/bash
# test-xaca-1097-resolver-call-sites.sh
#
# XACA-1097 defect 2, subitem 022 (review round): the resolver-consolidation
# fix (_x1097_resolve()) landed for check_dependencies() under earlier
# subitems, but FIVE more bare `command -v jq` / `command -v python3` call
# sites shared the exact same non-login-PATH blind spot and were left
# unfixed until subitem 022:
#
#     libexec/commands/aiteamforge-doctor.sh
#         check_board_resolution()            bare `command -v jq`
#                                              + 3 downstream bare `jq` calls
#         _connect_scripts_install_profile()  bare `command -v python3`
#                                              + 1 downstream bare python3 heredoc
#         check_connect_scripts()             bare `command -v python3`
#                                              + 1 downstream bare python3 heredoc
#     bin/aiteamforge-doctor.sh
#         check_config()                      bare `command -v jq`
#                                              + 2 downstream bare `jq` calls
#
# This suite is the MISSING regression coverage for that fix. The two
# existing XACA-1097 suites (test-xaca-1097-doctor-phantom-deps.sh,
# test-xaca-1097-launchagent-disabled-autofix.sh) contain zero jq/python3/
# board/connect-scripts assertions -- a green gate that does not exercise
# the fix it is meant to guard is exactly the vacuous-coverage problem this
# ticket exists to close.
#
# Every block below asserts BOTH halves of the fix, because detecting a tool
# is only half the job:
#   (a) RESOLUTION -- under a PATH that hides jq/python3 from a bare
#       `command -v`, the check must not report the tool unavailable.
#   (b) INVOCATION -- the check must actually RUN the tool through the
#       resolved path and produce its REAL result (an exact parsed count, a
#       real profile-derived branch), not merely omit the word "unavailable".
#       A fix that resolves the path but still invokes the bare tool name
#       trades a phantom MISSING for a phantom BROKEN -- found, then failed
#       to run. Two dedicated HALF-FIX blocks (surgically patched from the
#       live post-fix source) prove this suite would catch that class of
#       regression, not just assert it away.
#
# Grounded reference behavior (re-derive, never trust the transcription):
# under a PATH that hides jq/python3 (see RESOLVER_HIDDEN_PATH below),
#   PRE-FIX  check_board_resolution(): "Cannot validate board JSON -- no
#            Python venv or jq available"
#   PRE-FIX  check_connect_scripts(): "python3 unavailable -- cannot
#            cross-check connect scripts against installed teams"
#   POST-FIX check_board_resolution(): "Board resolves + parses: ... (team=
#            '...', backlog=N)" with the REAL parsed team/count.
#   POST-FIX check_connect_scripts(): real per-instance verdicts (e.g.
#            "Connect script present for academy") or, for the cockpit-
#            profile fixture, "Cockpit install -- N connect script(s)
#            present; orphan cross-check skipped".
#
# This suite tests the LIVE files (bin/aiteamforge-doctor.sh, libexec/
# commands/aiteamforge-doctor.sh) as they stand -- i.e. it is a forward
# regression gate against the FIXED code, matching the convention of
# test-xaca-1097-doctor-phantom-deps.sh. To reproduce the "fails against
# pre-fix code" proof this ticket's task explicitly required, BIN_DOCTOR and
# LIBEXEC_DOCTOR are overridable via X1097_022_TEST_BIN_DOCTOR /
# X1097_022_TEST_LIBEXEC_DOCTOR -- point them at throwaway files populated
# via `git -C homebrew-tap show 5643ba2:<path>` (5643ba2 is the commit
# immediately BEFORE this fix, which is otherwise uncommitted) to re-run
# this exact suite against the unfixed sites and confirm exit 1. Normal CI
# runs never set these and always exercise the real, current files.
#
# Designed to run standalone OR via test-runner.sh (matches the
# test-xaca-1095-017-helpers-drift-check.sh / test-xaca-1097-doctor-phantom-
# deps.sh convention).

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DOCTOR="${X1097_022_TEST_BIN_DOCTOR:-$TAP_ROOT/bin/aiteamforge-doctor.sh}"
LIBEXEC_DOCTOR="${X1097_022_TEST_LIBEXEC_DOCTOR:-$TAP_ROOT/libexec/commands/aiteamforge-doctor.sh}"
COMMON_LIB="$TAP_ROOT/libexec/lib/common.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: fallbacks ONLY when test-runner.sh hasn't already
# exported test_start/test_pass/test_fail. Mirrors
# test-xaca-1097-doctor-phantom-deps.sh verbatim (house convention).
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

# Block helpers (test-xaca-1097-007 hardening pattern): a block that fails
# never ALSO prints a pass for the same test name.
_BLOCK_FAILED=false
_block_start() { _BLOCK_FAILED=false; test_start "$1"; }
_block_note_fail() { _BLOCK_FAILED=true; test_fail "$1"; }
_block_end() { [ "$_BLOCK_FAILED" = false ] && test_pass; return 0; }

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
# A bare assert_not_contains PASSES vacuously on an empty haystack. Every
# negative assertion in this suite is paired with a positive one proving the
# fixture actually produced output (XACA-1097-007 Problem 1, closed twice
# already on this ticket -- do not reopen it here).
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
if [ ! -f "$COMMON_LIB" ]; then
    echo "FATAL: libexec/lib/common.sh not found at: $COMMON_LIB" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Grounding: the four call sites this suite exercises must still exist,
# verbatim by name, or the sed-range extractions below go silently empty.
# ─────────────────────────────────────────────────────────────────────────────
_block_start "grounding: bin/aiteamforge-doctor.sh defines check_result()/_x1097_resolve()/_x1097_prime_login_path()/check_config()"
for _fn in check_result _x1097_prime_login_path _x1097_resolve check_config; do
    grep -q "^${_fn}()" "$BIN_DOCTOR" || _block_note_fail "bin/aiteamforge-doctor.sh no longer defines ${_fn}() at file scope -- sed-range extraction below would go silently empty"
done
_block_end

_block_start "grounding: libexec/commands/aiteamforge-doctor.sh defines check_result()/_x1097_resolve()/_x1097_prime_login_path()/check_board_resolution()/_connect_scripts_install_profile()/check_connect_scripts()"
for _fn in check_result _x1097_prime_login_path _x1097_resolve check_board_resolution _connect_scripts_install_profile check_connect_scripts; do
    grep -q "^${_fn}()" "$LIBEXEC_DOCTOR" || _block_note_fail "libexec/commands/aiteamforge-doctor.sh no longer defines ${_fn}() at file scope -- sed-range extraction below would go silently empty"
done
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# Fixture sandbox
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1097-resolver-sites-test.XXXXXX)"
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

SANDBOX="$TEST_TMP_DIR/xaca1097-resolver-sites"
mkdir -p "$SANDBOX"

# ─────────────────────────────────────────────────────────────────────────────
# RESOLVER_HIDDEN_PATH -- a PATH that hides jq AND python3 from a bare
# `command -v` while keeping every other standard /usr/bin utility (grep,
# sed, awk, find, tr, basename, mktemp, wc, ...) available, so the target
# functions' OWN plumbing (find, basename, etc.) keeps working and only the
# tool this fix is about goes missing from the ambient PATH.
#
# WHY NOT the simpler RESTRICTED_PATH="/usr/bin:/bin:/usr/sbin:/sbin" used
# by test-xaca-1097-doctor-phantom-deps.sh: on this machine (and any macOS
# release that ships /usr/bin/jq, /usr/bin/python3 as Apple stubs -- measured
# true here, jq-1.7.1-apple / macOS 27), that PATH does NOT hide jq/python3
# at all -- both resolve via /usr/bin even under the "restricted" PATH,
# which would make a bare `command -v jq` succeed BEFORE the fix too and the
# suite would not discriminate. A synthetic directory that mirrors /usr/bin
# minus jq/python3(.*) sidesteps that entirely and remains correct whether
# or not the runner's macOS ships those two tools in /usr/bin.
# ─────────────────────────────────────────────────────────────────────────────
SYNTH_BIN_DIR="$SANDBOX/synth-bin"
mkdir -p "$SYNTH_BIN_DIR"
for _f in /usr/bin/*; do
    [ -f "$_f" ] || continue
    _b="$(basename "$_f")"
    case "$_b" in
        jq|python3|python3.*|python) continue ;;
    esac
    ln -sf "$_f" "$SYNTH_BIN_DIR/$_b" 2>/dev/null
done
RESOLVER_HIDDEN_PATH="$SYNTH_BIN_DIR:/bin:/usr/sbin:/sbin"

# ─────────────────────────────────────────────────────────────────────────────
# Sanity: prove RESOLVER_HIDDEN_PATH genuinely hides jq/python3 from a bare
# `command -v`, and record the ambient (real, unrestricted) locations used
# as ground truth for the positive assertions below. Conditional, per the
# XACA-1097-019 CI-portability convention: absent -> loud SKIP, never a
# silent/vacuous pass.
# ─────────────────────────────────────────────────────────────────────────────
REAL_JQ="$(command -v jq 2>/dev/null || true)"
REAL_PYTHON3="$(command -v python3 2>/dev/null || true)"

_block_start "sanity: RESOLVER_HIDDEN_PATH hides jq/python3 from a bare 'command -v' (both directly and via env -i, so priming's own subshell cannot see them either)"
HIDDEN_JQ="$(env -i PATH="$RESOLVER_HIDDEN_PATH" /bin/bash -c 'command -v jq' 2>/dev/null || true)"
HIDDEN_PY="$(env -i PATH="$RESOLVER_HIDDEN_PATH" /bin/bash -c 'command -v python3' 2>/dev/null || true)"
[ -z "$HIDDEN_JQ" ] || _block_note_fail "sabotage failed: jq still resolves under RESOLVER_HIDDEN_PATH at $HIDDEN_JQ -- this suite would not discriminate pre/post-fix"
[ -z "$HIDDEN_PY" ] || _block_note_fail "sabotage failed: python3 still resolves under RESOLVER_HIDDEN_PATH at $HIDDEN_PY -- this suite would not discriminate pre/post-fix"
if [ -z "$REAL_JQ" ]; then
    echo "    SKIP: jq not resolvable ambiently on this runner at all -- every jq-specific assertion below will also SKIP (no assertion made, never a vacuous pass)"
fi
if [ -z "$REAL_PYTHON3" ]; then
    echo "    SKIP: python3 not resolvable ambiently on this runner at all -- every python3-specific assertion below will also SKIP"
fi
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# Extraction helper: pull named function bodies, verbatim, in dependency
# order, from a doctor source file via sed range (never reimplemented).
# ─────────────────────────────────────────────────────────────────────────────
_extract_fns() {
    local src="$1"; shift
    local fn
    for fn in "$@"; do
        sed -n "/^${fn}()/,/^}/p" "$src"
        echo
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# BLOCK A -- bin/aiteamforge-doctor.sh: check_config()'s jq site
#   (installed_features count + fleet_registration_status)
# ─────────────────────────────────────────────────────────────────────────────
BIN_CFG_EXTRACT="$SANDBOX/bin-check-config.sh"
_extract_fns "$BIN_DOCTOR" check_result _x1097_prime_login_path _x1097_resolve check_config > "$BIN_CFG_EXTRACT"

CFG_SBX="$SANDBOX/cfg-sbx"
mkdir -p "$CFG_SBX"
cat > "$CFG_SBX/.aiteamforge-config" <<'EOF'
{"installed_features": ["kanban", "lcars"], "fleet_registration_status": "registered"}
EOF

_run_check_config() {
    local extract="$1"
    PATH="$RESOLVER_HIDDEN_PATH" HOME="$SANDBOX/home-empty" /bin/bash -c "
        RED='' GREEN='' YELLOW='' NC=''
        TOTAL_CHECKS=0 PASSED_CHECKS=0 FAILED_CHECKS=0 WARNING_CHECKS=0 VERBOSE=false
        INSTALL_PROFILE=full
        AITEAMFORGE_DIR='$CFG_SBX'
        source '$extract'
        check_config
    " 2>&1
}

_block_start "A1 [check_config/bin, XACA-1097-022]: must not silently skip installed_features/fleet_registration when jq is hidden from PATH but resolvable via fallback"
if [ -n "$REAL_JQ" ]; then
    A_OUT="$(_run_check_config "$BIN_CFG_EXTRACT")"
    # Positive control FIRST (paired with every negative assertion below):
    # proves the fixture actually ran the real check_config() logic, not that
    # source/extraction silently produced nothing.
    assert_not_empty "$A_OUT" \
        "check_config() produced NO output at all -- fixture is broken (sed extraction/source likely failed)"
    assert_contains "$A_OUT" "Configuration marker" \
        "expected the real 'Configuration marker' pass line -- its absence means check_config() did not execute its real logic"
    # INVOCATION, not just resolution: assert the EXACT parsed count (2
    # features) and the exact fleet status string, both of which only a
    # REAL jq invocation against the fixture's real JSON can produce. A
    # half-fix that resolves $_jq_path but still calls bare `jq` downstream
    # would silently fall through to the `|| echo "0"` fallback and report
    # 0 features / "not_configured" instead -- see the half-fix negative
    # control in BLOCK A2 below for a direct demonstration of that trap.
    assert_contains "$A_OUT" "installed_features field present (2 feature(s))" \
        "expected the REAL jq-parsed feature count (2) -- jq is hidden from PATH but resolvable via _x1097_resolve's fallback; got: $A_OUT"
    assert_contains "$A_OUT" "Fleet registration: registered" \
        "expected the REAL jq-parsed fleet_registration_status ('registered') -- got: $A_OUT"
else
    echo "    SKIP: jq not resolvable ambiently on this runner -- cannot exercise the resolution+invocation assertion"
fi
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# BLOCK A2 -- half-fix negative control for check_config(): resolver guard
# fixed, but the two DOWNSTREAM jq invocations surgically reverted to the
# bare tool name. Proves BLOCK A's exact-count assertion would catch a
# resolve-but-still-bare-invoke regression (phantom BROKEN, not phantom
# MISSING) -- the trap this ticket's task explicitly calls out as already
# found and closed twice.
# ─────────────────────────────────────────────────────────────────────────────
_block_start "A2 [negative control, invocation]: reverting check_config()'s DOWNSTREAM jq calls to bare 'jq' (guard left fixed) must reproduce the phantom-BROKEN symptom, not the real count"
if [ -n "$REAL_JQ" ]; then
    A2_EXTRACT="$SANDBOX/bin-check-config-halffix.sh"
    A2_PATCH_OK=true
    python3 - "$BIN_CFG_EXTRACT" "$A2_EXTRACT" <<'PYEOF' || A2_PATCH_OK=false
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
needle1 = 'features_count=$("$_jq_path" \''
needle2 = 'fleet_reg_status=$("$_jq_path" -r \''
if needle1 not in text or needle2 not in text:
    sys.exit("PIN FAILED: expected fixed $_jq_path invocations not found -- cannot build half-fix control")
text = text.replace(needle1, 'features_count=$(jq \'')
text = text.replace(needle2, 'fleet_reg_status=$(jq -r \'')
open(dst, "w").write(text)
PYEOF
    if [ "$A2_PATCH_OK" != true ] || [ ! -s "$A2_EXTRACT" ]; then
        _block_note_fail "could not build the half-fix fixture (pin check failed) -- this negative control is not testing anything"
    else
        A2_OUT="$(_run_check_config "$A2_EXTRACT")"
        assert_not_empty "$A2_OUT" "half-fix fixture produced no output at all -- broken control"
        assert_contains "$A2_OUT" "Configuration marker" "half-fix fixture did not run real check_config() logic"
        # The guard still resolves jq fine (unpatched), so the block is
        # entered -- but the bare downstream call fails silently under
        # RESOLVER_HIDDEN_PATH, falling through to the "|| echo" defaults.
        assert_contains "$A2_OUT" "installed_features field missing or empty" \
            "half-fix (bare downstream jq call) should degrade to the '0 features' fallback path, not the real count; got: $A2_OUT"
        assert_not_contains "$A2_OUT" "installed_features field present (2 feature(s))" \
            "half-fix must NOT produce the real parsed count -- if it does, this control cannot distinguish resolve-only fixes from a real invocation fix"
    fi
else
    echo "    SKIP: jq not resolvable ambiently on this runner"
fi
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# BLOCK B -- libexec/commands/aiteamforge-doctor.sh: check_board_resolution()'s
# jq fallback branch (exercised only when AITEAMFORGE_PYTHON is unset, which
# is exactly the sandboxed extraction environment below -- the real script's
# top-of-file python-env.sh sourcing always sets a non-empty AITEAMFORGE_PYTHON
# fallback, so this branch is unreachable via the full CLI on any box; this is
# precisely why the fix's own function must be extracted and driven directly,
# not exercised end-to-end.)
# ─────────────────────────────────────────────────────────────────────────────
LIB_BOARD_EXTRACT="$SANDBOX/lib-check-board.sh"
_extract_fns "$LIBEXEC_DOCTOR" check_result _x1097_prime_login_path _x1097_resolve check_board_resolution > "$LIB_BOARD_EXTRACT"

BOARD_SBX="$SANDBOX/board-sbx"
mkdir -p "$BOARD_SBX/kanban"
cat > "$BOARD_SBX/kanban/academy-board.json" <<'EOF'
{"team": {"id": "academy"}, "backlog": [{"id": 1}, {"id": 2}, {"id": 3}]}
EOF

_run_check_board() {
    local extract="$1"
    PATH="$RESOLVER_HIDDEN_PATH" HOME="$SANDBOX/home-empty" /bin/bash -c "
        VERBOSE=false FIX=false TOTAL_CHECKS=0 PASSED_CHECKS=0 FAILED_CHECKS=0 WARNING_CHECKS=0
        unset AITEAMFORGE_PYTHON
        get_working_dir() { printf '%s\n' '$BOARD_SBX'; }
        _aiteamforge_org_slug() { printf '%s\n' 'myorg'; }
        get_configured_teams() { printf '%s\n' 'academy'; }
        source '$COMMON_LIB'
        source '$extract'
        check_board_resolution
    " 2>&1
}

_block_start "B1 [check_board_resolution, XACA-1097-022]: must not report 'no Python venv or jq available' when jq is hidden from PATH but resolvable via fallback"
if [ -n "$REAL_JQ" ]; then
    B_OUT="$(_run_check_board "$LIB_BOARD_EXTRACT")"
    assert_not_empty "$B_OUT" \
        "check_board_resolution() produced NO output at all -- fixture is broken (sed extraction/source likely failed)"
    assert_contains "$B_OUT" "Kanban directory resolves for 'academy'" \
        "expected the real kanban-dir-resolves pass line -- its absence means check_board_resolution() did not execute its real logic"
    assert_not_contains "$B_OUT" "Cannot validate board JSON" \
        "must not report the pre-fix phantom ('no Python venv or jq available') -- jq is resolvable via fallback; got: $B_OUT"
    # INVOCATION: assert the REAL parsed team + backlog count, not merely the
    # absence of the phantom string.
    assert_contains "$B_OUT" "Board resolves + parses: academy-board.json (team='academy', backlog=3)" \
        "expected the REAL jq-parsed board summary (team='academy', backlog=3); got: $B_OUT"
else
    echo "    SKIP: jq not resolvable ambiently on this runner"
fi
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# BLOCK B2 -- half-fix negative control for check_board_resolution(): the
# resolver GUARD (`elif _jq_path="$(_x1097_resolve jq)"`) left fixed, but
# both downstream jq invocations (`jq empty`, the two `jq -r` parses)
# surgically reverted to the bare tool name. Proves BLOCK B's exact
# team/count assertion would catch "resolved but never actually ran".
# ─────────────────────────────────────────────────────────────────────────────
_block_start "B2 [negative control, invocation]: reverting check_board_resolution()'s DOWNSTREAM jq calls to bare 'jq' (guard left fixed) must reproduce a phantom-BROKEN (badjson) verdict, not the real parse"
if [ -n "$REAL_JQ" ]; then
    B2_EXTRACT="$SANDBOX/lib-check-board-halffix.sh"
    B2_PATCH_OK=true
    python3 - "$LIB_BOARD_EXTRACT" "$B2_EXTRACT" <<'PYEOF' || B2_PATCH_OK=false
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
needles = [
    'if "$_jq_path" empty "$board_file"',
    'board_team=$("$_jq_path" -r \'',
    'board_count=$("$_jq_path" -r \'',
]
for n in needles:
    if n not in text:
        sys.exit("PIN FAILED: expected fixed $_jq_path invocation not found: %r" % n)
text = text.replace('if "$_jq_path" empty "$board_file"', 'if jq empty "$board_file"')
text = text.replace('board_team=$("$_jq_path" -r \'', 'board_team=$(jq -r \'')
text = text.replace('board_count=$("$_jq_path" -r \'', 'board_count=$(jq -r \'')
open(dst, "w").write(text)
PYEOF
    if [ "$B2_PATCH_OK" != true ] || [ ! -s "$B2_EXTRACT" ]; then
        _block_note_fail "could not build the half-fix fixture (pin check failed) -- this negative control is not testing anything"
    else
        B2_OUT="$(_run_check_board "$B2_EXTRACT")"
        assert_not_empty "$B2_OUT" "half-fix fixture produced no output at all -- broken control"
        assert_contains "$B2_OUT" "Kanban directory resolves for 'academy'" "half-fix fixture did not run real check_board_resolution() logic"
        # The guard still resolves jq (unpatched) so we reach the jq branch,
        # but every downstream call is bare and fails silently under
        # RESOLVER_HIDDEN_PATH -- `jq empty` fails, so board_status becomes
        # "badjson", NOT the real "ok" parse.
        assert_contains "$B2_OUT" "Board file is unparseable JSON" \
            "half-fix (bare downstream jq calls) should misreport the file as unparseable (badjson), not parse it; got: $B2_OUT"
        assert_not_contains "$B2_OUT" "Board resolves + parses" \
            "half-fix must NOT produce the real parsed team/backlog result -- if it does, this control cannot distinguish resolve-only fixes from a real invocation fix"
    fi
else
    echo "    SKIP: jq not resolvable ambiently on this runner"
fi
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# BLOCK C -- libexec/commands/aiteamforge-doctor.sh: check_connect_scripts()'s
# OWN top-level python3 guard.
# ─────────────────────────────────────────────────────────────────────────────
LIB_CONNECT_EXTRACT="$SANDBOX/lib-check-connect.sh"
_extract_fns "$LIBEXEC_DOCTOR" check_result _x1097_prime_login_path _x1097_resolve _connect_scripts_install_profile check_connect_scripts > "$LIB_CONNECT_EXTRACT"

CONNECT_SBX="$SANDBOX/connect-sbx"
mkdir -p "$CONNECT_SBX"
cat > "$CONNECT_SBX/.aiteamforge-config" <<'EOF'
{"version": "test", "teams": ["academy"], "team_paths": {}, "install_profile": "full"}
EOF
printf '#!/bin/zsh\necho stub\n' > "$CONNECT_SBX/academy-connect.sh"

_run_check_connect() {
    local extract="$1" working_dir="$2"
    PATH="$RESOLVER_HIDDEN_PATH" HOME="$SANDBOX/home-empty" /bin/bash -c "
        VERBOSE=false FIX=false TOTAL_CHECKS=0 PASSED_CHECKS=0 FAILED_CHECKS=0 WARNING_CHECKS=0
        get_working_dir() { printf '%s\n' '$working_dir'; }
        get_framework_dir() { printf '%s\n' '$TAP_ROOT'; }
        source '$COMMON_LIB'
        source '$extract'
        check_connect_scripts
    " 2>&1
}

_block_start "C1 [check_connect_scripts guard, XACA-1097-022]: must not report python3 unavailable when it is hidden from PATH but resolvable via fallback"
if [ -n "$REAL_PYTHON3" ]; then
    C_OUT="$(_run_check_connect "$LIB_CONNECT_EXTRACT" "$CONNECT_SBX")"
    assert_not_empty "$C_OUT" \
        "check_connect_scripts() produced NO output at all -- fixture is broken (sed extraction/source likely failed)"
    assert_contains "$C_OUT" "Checking Cockpit Connect Scripts" \
        "expected the real print_section header -- its absence means check_connect_scripts() did not execute its real logic"
    assert_not_contains "$C_OUT" "python3 unavailable" \
        "must not report the pre-fix phantom ('python3 unavailable') -- python3 is resolvable via fallback; got: $C_OUT"
    # INVOCATION: assert the REAL per-instance verdict (python3 composed the
    # installed-instance list, cross-checked it against the on-disk script).
    assert_contains "$C_OUT" "Connect script present for academy" \
        "expected the REAL python3-composed verdict for the installed 'academy' instance; got: $C_OUT"
else
    echo "    SKIP: python3 not resolvable ambiently on this runner"
fi
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# BLOCK C2 -- half-fix negative control for check_connect_scripts(): the
# top-level guard left fixed, but the DOWNSTREAM python3 heredoc invocation
# (the one composing the installed-instance list) surgically reverted to
# bare 'python3'. Proves BLOCK C's per-instance assertion would catch
# "python3 resolved but the actual cross-check never ran".
# ─────────────────────────────────────────────────────────────────────────────
_block_start "C2 [negative control, invocation]: reverting check_connect_scripts()'s DOWNSTREAM python3 heredoc call to bare 'python3' (guard left fixed) must misreport the installed instance as an orphan"
if [ -n "$REAL_PYTHON3" ]; then
    C2_EXTRACT="$SANDBOX/lib-check-connect-halffix.sh"
    C2_PATCH_OK=true
    python3 - "$LIB_CONNECT_EXTRACT" "$C2_EXTRACT" <<'PYEOF' || C2_PATCH_OK=false
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
needle = '_installed="$("$_py_path" - "$_install_config" "${_parametric_bases[@]}" <<\'PYEOF\''
if needle not in text:
    sys.exit("PIN FAILED: expected fixed $_py_path downstream invocation not found -- cannot build half-fix control")
text = text.replace(needle, '_installed="$(python3 - "$_install_config" "${_parametric_bases[@]}" <<\'PYEOF\'')
open(dst, "w").write(text)
PYEOF
    if [ "$C2_PATCH_OK" != true ] || [ ! -s "$C2_EXTRACT" ]; then
        _block_note_fail "could not build the half-fix fixture (pin check failed) -- this negative control is not testing anything"
    else
        C2_OUT="$(_run_check_connect "$C2_EXTRACT" "$CONNECT_SBX")"
        assert_not_empty "$C2_OUT" "half-fix fixture produced no output at all -- broken control"
        assert_contains "$C2_OUT" "Checking Cockpit Connect Scripts" "half-fix fixture did not run real check_connect_scripts() logic"
        # Guard still resolves python3 fine (unpatched) so we reach the
        # heredoc -- but the bare downstream call fails silently under
        # RESOLVER_HIDDEN_PATH, so _installed comes back EMPTY: the
        # genuinely-installed 'academy' instance now looks like an orphan
        # on-disk script instead of a present, installed instance.
        assert_contains "$C2_OUT" "matches no installed instance" \
            "half-fix (bare downstream python3 heredoc) should misreport 'academy' as an orphan, not present; got: $C2_OUT"
        assert_not_contains "$C2_OUT" "Connect script present for academy" \
            "half-fix must NOT produce the real present-instance verdict -- if it does, this control cannot distinguish resolve-only fixes from a real invocation fix"
    fi
else
    echo "    SKIP: python3 not resolvable ambiently on this runner"
fi
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# BLOCK D -- libexec/commands/aiteamforge-doctor.sh:
# _connect_scripts_install_profile()'s python3 resolution, isolated from
# check_connect_scripts()'s OWN guard (Block C) via a profile that flips a
# VISIBLY DIFFERENT code path: a "cockpit" install_profile (read from
# .aiteamforge-config via _connect_scripts_install_profile's python3
# heredoc, no .install-profile marker file present) suppresses the
# orphan cross-check entirely and prints a distinct summary line. If
# _connect_scripts_install_profile() cannot resolve python3, it silently
# defaults to "full" (`[ -n "$_p" ] || _p="full"`) and the orphan
# cross-check fires instead -- a completely different, wrong verdict for a
# cockpit box (XACA-0845-016 is the defect class this would resurrect).
# ─────────────────────────────────────────────────────────────────────────────
COCKPIT_SBX="$SANDBOX/cockpit-sbx"
mkdir -p "$COCKPIT_SBX"
cat > "$COCKPIT_SBX/.aiteamforge-config" <<'EOF'
{"version": "test", "teams": [], "team_paths": {}, "install_profile": "cockpit"}
EOF
printf '#!/bin/zsh\necho stub\n' > "$COCKPIT_SBX/academy-connect.sh"
# No .install-profile marker file -- forces _connect_scripts_install_profile()
# down its python3 fallback path (the site this block exists to cover).

_block_start "D1 [_connect_scripts_install_profile, XACA-1097-022]: must read 'cockpit' from .aiteamforge-config via python3 (hidden from PATH but resolvable via fallback), not silently default to 'full'"
if [ -n "$REAL_PYTHON3" ]; then
    D_OUT="$(_run_check_connect "$LIB_CONNECT_EXTRACT" "$COCKPIT_SBX")"
    assert_not_empty "$D_OUT" \
        "check_connect_scripts() produced NO output at all against the cockpit fixture -- fixture is broken"
    assert_contains "$D_OUT" "Checking Cockpit Connect Scripts" \
        "expected the real print_section header -- fixture did not execute real logic"
    # INVOCATION: the profile-specific summary line can ONLY appear if
    # _connect_scripts_install_profile() actually read "cockpit" back out of
    # the config via a REAL python3 invocation.
    assert_contains "$D_OUT" "Cockpit install — 1 connect script(s) present; orphan cross-check skipped" \
        "expected the cockpit-profile summary (proves python3 resolved AND ran against the real config); got: $D_OUT"
    assert_not_contains "$D_OUT" "matches no installed instance" \
        "must not run the orphan cross-check on a cockpit-profile box (that requires _p to have silently defaulted to 'full', i.e. the profile detection failed); got: $D_OUT"
else
    echo "    SKIP: python3 not resolvable ambiently on this runner"
fi
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# NEGATIVE CONTROL (fixture-extraction sabotage, task hard requirement #3):
# deliberately corrupt the sed-range extraction itself (wrong function name,
# simulating a renamed/moved function breaking the seam) and prove the
# resulting run fails LOUDLY (a real shell error, non-zero exit, and no
# accidental real-looking output) rather than silently reporting success.
# ─────────────────────────────────────────────────────────────────────────────
_block_start "NC1 [negative control, extraction sabotage]: a corrupted sed-range extraction (function renamed/missing) must fail LOUDLY, not silently pass"
BROKEN_EXTRACT="$SANDBOX/broken-extract.sh"
{
    _extract_fns "$BIN_DOCTOR" check_result _x1097_prime_login_path _x1097_resolve
    # Deliberately wrong function name -- simulates a broken extraction seam
    # (e.g. check_config() renamed upstream and this suite's sed pattern
    # silently stopped matching).
    sed -n '/^check_config_TYPO_DOES_NOT_EXIST()/,/^}/p' "$BIN_DOCTOR"
} > "$BROKEN_EXTRACT"
if grep -q '^check_config()' "$BROKEN_EXTRACT"; then
    _block_note_fail "sabotage failed: broken extract still contains check_config() -- this negative control is not testing anything"
else
    BROKEN_OUT="$(_run_check_config "$BROKEN_EXTRACT"; echo "EXIT:$?")"
    BROKEN_EXIT="${BROKEN_OUT##*EXIT:}"
    BROKEN_TEXT="${BROKEN_OUT%EXIT:*}"
    assert_contains "$BROKEN_TEXT" "command not found" \
        "a corrupted extraction (undefined check_config) should raise a visible 'command not found' shell error, not fail silently; got: $BROKEN_TEXT"
    assert_not_contains "$BROKEN_TEXT" "installed_features field present" \
        "a corrupted extraction must never coincidentally produce a real pass message"
    [ "$BROKEN_EXIT" != "0" ] || _block_note_fail "a corrupted extraction (undefined check_config) must NOT exit 0 (got exit $BROKEN_EXIT) -- a broken fixture must never look like success"
fi
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# CI-LIKE ENVIRONMENT SIMULATION (task hard requirement #4): a personal dev
# box's $SHELL -ilc priming (stage 2 of _x1097_resolve) can succeed via
# ~/.zshrc customizations a CI runner simply does not have. Re-run BLOCK
# B/C/D's core assertions with HOME pointed at a byte-for-byte EMPTY sandbox
# (no ~/.zshrc, no ~/.bash_profile, no ~/.zprofile) to prove the fix does not
# secretly depend on shell-rc customizations that a CI image lacks -- i.e.
# resolution must still succeed via stage 3 (the static /opt/homebrew/bin,
# /usr/local/bin, ~/.local/bin fallback), independent of stage 2 priming.
# This is a real discrimination check, not a smoke test: it is run against
# the SAME extracts as Block B/C/D above, under the SAME RESOLVER_HIDDEN_PATH,
# with only HOME swapped to an rc-less sandbox.
# ─────────────────────────────────────────────────────────────────────────────
_block_start "CI-SIM [XACA-1097-022]: resolution succeeds under an rc-less HOME (no ~/.zshrc/~/.bash_profile), matching a bare CI runner rather than a customized dev shell"
CI_HOME="$SANDBOX/ci-home-empty"
mkdir -p "$CI_HOME"
if [ -n "$REAL_JQ" ]; then
    CI_BOARD_OUT="$(PATH="$RESOLVER_HIDDEN_PATH" HOME="$CI_HOME" /bin/bash -c "
        VERBOSE=false FIX=false TOTAL_CHECKS=0 PASSED_CHECKS=0 FAILED_CHECKS=0 WARNING_CHECKS=0
        unset AITEAMFORGE_PYTHON
        get_working_dir() { printf '%s\n' '$BOARD_SBX'; }
        _aiteamforge_org_slug() { printf '%s\n' 'myorg'; }
        get_configured_teams() { printf '%s\n' 'academy'; }
        source '$COMMON_LIB'
        source '$LIB_BOARD_EXTRACT'
        check_board_resolution
    " 2>&1)"
    assert_not_empty "$CI_BOARD_OUT" "CI-like board-resolution run produced no output -- fixture broken"
    assert_contains "$CI_BOARD_OUT" "Board resolves + parses: academy-board.json (team='academy', backlog=3)" \
        "resolution must succeed via the static prefix fallback (stage 3) even under an rc-less HOME with no shell customization; got: $CI_BOARD_OUT"
else
    echo "    SKIP: jq not resolvable ambiently on this runner"
fi
if [ -n "$REAL_PYTHON3" ]; then
    CI_CONNECT_OUT="$(PATH="$RESOLVER_HIDDEN_PATH" HOME="$CI_HOME" /bin/bash -c "
        VERBOSE=false FIX=false TOTAL_CHECKS=0 PASSED_CHECKS=0 FAILED_CHECKS=0 WARNING_CHECKS=0
        get_working_dir() { printf '%s\n' '$CONNECT_SBX'; }
        get_framework_dir() { printf '%s\n' '$TAP_ROOT'; }
        source '$COMMON_LIB'
        source '$LIB_CONNECT_EXTRACT'
        check_connect_scripts
    " 2>&1)"
    assert_not_empty "$CI_CONNECT_OUT" "CI-like connect-scripts run produced no output -- fixture broken"
    assert_contains "$CI_CONNECT_OUT" "Connect script present for academy" \
        "resolution must succeed via the static prefix fallback (stage 3) even under an rc-less HOME with no shell customization; got: $CI_CONNECT_OUT"
else
    echo "    SKIP: python3 not resolvable ambiently on this runner"
fi
if [ -z "$REAL_JQ" ] && [ -z "$REAL_PYTHON3" ]; then
    echo "    SKIP: neither jq nor python3 resolvable ambiently on this runner -- CI-like simulation cannot exercise anything here"
fi
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# BLOCK E -- XACA-1097 review round: _x1097_prime_login_path() process-group/
# timeout-bound + trailing-noise regression coverage.
#
# `grep -rE 'LOGIN_PROBE_TIMEOUT|orphan|grandchild|pgid' tests/` returned
# NOTHING before this block -- the "orphan" hits elsewhere in THIS file are
# CONNECT-SCRIPT orphans, an unrelated concept. Two defects shipped in the
# review round specifically because no test exercised this path:
#   Defect 1: `set -m` lived INSIDE the backgrounded `( ... )` subshell,
#             where it cannot setpgid it -- pgid stayed INHERITED from the
#             script, so the timeout branch's `kill -TERM -- -$pid` hit
#             NOTHING (ESRCH), the bound was inoperative, and `wait "$pid"`
#             blocked on the hung shell instead of the configured timeout.
#   Defect 2: the PATH payload was written with `printf '%s'` -- no
#             trailing newline -- so trailing rc output (a login shell's
#             guaranteed ~/.zlogout pass) landed on the SAME LINE and
#             corrupted the LAST PATH entry.
#
# Fixtures below are BASH-3.2-SAFE (no $BASHPID -- that is bash 4+ only and
# was measured to silently return empty under macOS's shipped /bin/bash,
# which would have made the grandchild-tracking pidfile below silently
# blank instead of failing loudly).
#
# PRE-FIX fixture: _x1097_prime_login_path() extracted from commit
# X1097_PRIME_PREFIX_COMMIT -- the actual commit this round's fix sits on
# top of, not a hand-typed guess. Same convention as the
# X1097_022_TEST_BIN_DOCTOR override documented near the top of this file.
# ─────────────────────────────────────────────────────────────────────────────
PRIME_SANDBOX="$SANDBOX/prime-loginpath"
mkdir -p "$PRIME_SANDBOX"
X1097_PRIME_PREFIX_COMMIT="5ff817f"

PRIME_POST_FN="$PRIME_SANDBOX/prime-post-fix.sh"
PRIME_PRE_FULL="$PRIME_SANDBOX/prime-pre-fix-full.sh"
PRIME_PRE_FN="$PRIME_SANDBOX/prime-pre-fix.sh"
PRIME_PREFIX_AVAILABLE=false

_extract_fns "$BIN_DOCTOR" _x1097_prime_login_path > "$PRIME_POST_FN"

_block_start "BLOCK E grounding: POST-FIX extraction is genuinely the fixed shape (parent-scope set -m + disown, trailing-newline PATH printf)"
assert_not_empty "$(cat "$PRIME_POST_FN")" "extraction of _x1097_prime_login_path() from \$BIN_DOCTOR produced nothing"
assert_contains "$(cat "$PRIME_POST_FN")" "disown" \
    "live \$BIN_DOCTOR no longer disowns the probe job -- BLOCK E's POST-FIX assumptions are stale"
PRIME_NEEDLE_TRAILING_NL="$(cat <<'NEEDLE'
printf '%s\n' \"\$PATH\"
NEEDLE
)"
assert_contains "$(cat "$PRIME_POST_FN")" "$PRIME_NEEDLE_TRAILING_NL" \
    "live \$BIN_DOCTOR no longer terminates the PATH payload with a newline -- BLOCK E's POST-FIX assumptions are stale"
_block_end

_block_start "BLOCK E grounding: PRE-FIX fixture (commit $X1097_PRIME_PREFIX_COMMIT) is resolvable and is genuinely the buggy shape"
if git -C "$TAP_ROOT" cat-file -e "$X1097_PRIME_PREFIX_COMMIT" 2>/dev/null && \
   git -C "$TAP_ROOT" show "$X1097_PRIME_PREFIX_COMMIT:bin/aiteamforge-doctor.sh" > "$PRIME_PRE_FULL" 2>/dev/null; then
    if grep -q '^_x1097_prime_login_path()' "$PRIME_PRE_FULL"; then
        _extract_fns "$PRIME_PRE_FULL" _x1097_prime_login_path > "$PRIME_PRE_FN"
        assert_not_empty "$(cat "$PRIME_PRE_FN")" "pre-fix extraction produced nothing"
        assert_not_contains "$(cat "$PRIME_PRE_FN")" "disown" \
            "pre-fix fixture (commit $X1097_PRIME_PREFIX_COMMIT) already disowns the probe job -- this is not the pre-fix shape, fixture selection is wrong"
        assert_contains "$(cat "$PRIME_PRE_FN")" ") &" \
            "pre-fix fixture (commit $X1097_PRIME_PREFIX_COMMIT) does not background a subshell wrapper -- not the shape defect 1 is about"
        PRIME_PREFIX_AVAILABLE=true
    else
        _block_note_fail "commit $X1097_PRIME_PREFIX_COMMIT no longer defines _x1097_prime_login_path() at file scope"
    fi
else
    echo "    SKIP: commit $X1097_PRIME_PREFIX_COMMIT not resolvable in this checkout -- PRE-FIX negative-control runs below will SKIP; POST-FIX assertions still run and still gate the suite"
fi
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# Fake $SHELL fixtures.
# ─────────────────────────────────────────────────────────────────────────────
FAKE_HANG_SHELL="$PRIME_SANDBOX/fake-shell-hang.sh"
cat > "$FAKE_HANG_SHELL" <<'FAKESHELL'
#!/bin/bash
# Simulates a stuck ~/.zshrc during "$SHELL -ilc ...": forks a tracked
# GRANDCHILD, then blocks itself -- so group-kill correctness can be
# measured against a REAL grandchild, not just the direct child. Both
# processes block on `exec sleep 1000000` (never returns on its own inside
# this suite's timeouts) and record their OWN real pid to a file BEFORE
# that exec -- exec preserves pid but replaces argv, so a `ps`/`pgrep`
# command-line match on this script's own path would go stale the instant
# `sleep` replaces it; the pidfile sidesteps that entirely. The grandchild
# is a genuine NEW `/bin/bash -c '...'` process (not a `( ... )` subshell)
# because `$BASHPID` is bash 4+ only and was measured to be silently EMPTY
# under macOS's shipped bash 3.2 -- `$$` inside a real child process is
# correct on 3.2, `$$` inside a `()` subshell is NOT (it stays the
# parent's).
: "${X1097_HANG_PID_PREFIX:?X1097_HANG_PID_PREFIX must be set}"
/bin/bash -c 'echo "$$" > "'"$X1097_HANG_PID_PREFIX"'.grandchild"; exec sleep 1000000' &
echo "$$" > "${X1097_HANG_PID_PREFIX}.child"
exec sleep 1000000
FAKESHELL
chmod +x "$FAKE_HANG_SHELL"

FAKE_TRAILING_SHELL="$PRIME_SANDBOX/fake-shell-trailing.sh"
cat > "$FAKE_TRAILING_SHELL" <<'FAKESHELL'
#!/bin/bash
# Simulates a LOGIN shell's guaranteed logout-file pass (~/.zlogout et al.)
# printing AFTER the probe's own -c command output finishes, on the SAME
# stdout stream, with NO separating newline of its own -- the exact
# XACA-1097 defect-2 shape (measured against a REAL ~/.zlogout during
# triage, reproduced here without depending on the runner's actual rc
# files).
shift
eval "$1"
printf '%s' '== goodbye from .fake-zlogout =='
FAKESHELL
chmod +x "$FAKE_TRAILING_SHELL"

FAKE_LEADING_SHELL="$PRIME_SANDBOX/fake-shell-leading.sh"
cat > "$FAKE_LEADING_SHELL" <<'FAKESHELL'
#!/bin/bash
# Simulates a chatty ~/.zshrc printing a banner line BEFORE the marker+PATH
# payload -- the ORIGINAL XACA-1097-019 leading-banner-noise case. This is
# a "do not regress" guard for a DIFFERENT, already-fixed defect than the
# trailing-noise one above; both must stay inert at once.
echo '== hello from .fake-zshrc =='
shift
eval "$1"
FAKESHELL
chmod +x "$FAKE_LEADING_SHELL"

_prime_elapsed_and_path() {
    # Runs _x1097_prime_login_path() from $1 under $SHELL=$2, PATH=$4, with
    # AITEAMFORGE_LOGIN_PROBE_TIMEOUT_SECS=$3, and prints "ELAPSED:n" then
    # "CAPTURED:<path>" on stdout (stderr passed through separately by the
    # caller via redirection if it wants it).
    local fn_file="$1" fake_shell="$2" timeout_secs="$3" fixed_path="$4"
    PATH="$fixed_path" SHELL="$fake_shell" AITEAMFORGE_LOGIN_PROBE_TIMEOUT_SECS="$timeout_secs" /bin/bash -c "
        source '$fn_file'
        _t0=\$(date +%s)
        _x1097_prime_login_path
        _t1=\$(date +%s)
        printf 'ELAPSED:%s\n' \"\$((_t1 - _t0))\"
        printf 'CAPTURED:%s\n' \"\$_X1097_LOGIN_PATH\"
    "
}

# ─────────────────────────────────────────────────────────────────────────────
# (a)+(b) POST-FIX: hung $SHELL is bounded, no child/grandchild survives.
# ─────────────────────────────────────────────────────────────────────────────
_block_start "XACA-1097 defect 1 [POST-FIX]: hung \$SHELL is bounded within the configured timeout, and neither the child nor the GRANDCHILD survives it"
E1_TIMEOUT=1
E1_PREFIX="$PRIME_SANDBOX/e1"
E1_OUT="$(X1097_HANG_PID_PREFIX="$E1_PREFIX" _prime_elapsed_and_path "$PRIME_POST_FN" "$FAKE_HANG_SHELL" "$E1_TIMEOUT" "/bin:/usr/bin" 2>/dev/null)"
E1_ELAPSED="$(printf '%s\n' "$E1_OUT" | sed -n 's/^ELAPSED://p')"
assert_not_empty "$E1_ELAPSED" "no ELAPSED marker captured -- fixture broken; got: $E1_OUT"
if [ -n "$E1_ELAPSED" ] && [ "$E1_ELAPSED" -gt 6 ] 2>/dev/null; then
    _block_note_fail "hung \$SHELL was NOT bounded -- prime() took ${E1_ELAPSED}s against a configured ${E1_TIMEOUT}s timeout; the wait bound is inoperative"
fi
sleep 0.5
E1_CHILD_PID="$(cat "${E1_PREFIX}.child" 2>/dev/null || true)"
E1_GRANDCHILD_PID="$(cat "${E1_PREFIX}.grandchild" 2>/dev/null || true)"
assert_not_empty "$E1_CHILD_PID" "fixture did not record a child pid -- fixture broken, this block is not testing anything"
assert_not_empty "$E1_GRANDCHILD_PID" "fixture did not record a grandchild pid -- fixture broken, this block is not testing anything"
if [ -n "$E1_CHILD_PID" ] && kill -0 "$E1_CHILD_PID" 2>/dev/null; then
    _block_note_fail "direct child (pid $E1_CHILD_PID) survived the timeout under the FIXED code"
fi
if [ -n "$E1_GRANDCHILD_PID" ] && kill -0 "$E1_GRANDCHILD_PID" 2>/dev/null; then
    _block_note_fail "GRANDCHILD (pid $E1_GRANDCHILD_PID) survived the timeout under the FIXED code -- direct-child-only cleanup is not enough"
fi
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# (a)+(b) PRE-FIX negative control: proves this suite WOULD have caught the
# shipped regression. Runs under OUR OWN outer bound (4x the configured
# probe timeout) so a genuinely inoperative bound -- the actual historical
# defect -- cannot hang this suite: if the wrapper is still alive at that
# point, the historical defect has reproduced, and it does not confirm
# ANYTHING further; we still explicitly force-clean every tracked pid so no
# stray sleep survives this test run.
# ─────────────────────────────────────────────────────────────────────────────
_block_start "XACA-1097 defect 1 [PRE-FIX negative control, commit $X1097_PRIME_PREFIX_COMMIT]: timeout bound is inoperative, child+grandchild survive -- proves this suite would have caught the shipped regression"
if [ "$PRIME_PREFIX_AVAILABLE" = true ]; then
    E2_TIMEOUT=1
    E2_PREFIX="$PRIME_SANDBOX/e2"
    ( X1097_HANG_PID_PREFIX="$E2_PREFIX" _prime_elapsed_and_path "$PRIME_PRE_FN" "$FAKE_HANG_SHELL" "$E2_TIMEOUT" "/bin:/usr/bin" \
        > "$PRIME_SANDBOX/e2.out" 2>/dev/null ) &
    E2_WRAP_PID=$!
    E2_WAITED=0
    while [ "$E2_WAITED" -lt 4 ] && kill -0 "$E2_WRAP_PID" 2>/dev/null; do
        sleep 1
        E2_WAITED=$((E2_WAITED + 1))
    done
    if kill -0 "$E2_WRAP_PID" 2>/dev/null; then
        E2_CHILD_PID="$(cat "${E2_PREFIX}.child" 2>/dev/null || true)"
        E2_GRANDCHILD_PID="$(cat "${E2_PREFIX}.grandchild" 2>/dev/null || true)"
        assert_not_empty "$E2_CHILD_PID" "pre-fix fixture did not record a child pid -- fixture broken"
        assert_not_empty "$E2_GRANDCHILD_PID" "pre-fix fixture did not record a grandchild pid -- fixture broken"
        if [ -n "$E2_CHILD_PID" ] && ! kill -0 "$E2_CHILD_PID" 2>/dev/null; then
            _block_note_fail "expected the pre-fix child (pid $E2_CHILD_PID) to still be alive past its configured ${E2_TIMEOUT}s timeout -- this negative control did not reproduce the historical defect"
        fi
        if [ -n "$E2_GRANDCHILD_PID" ] && ! kill -0 "$E2_GRANDCHILD_PID" 2>/dev/null; then
            _block_note_fail "expected the pre-fix GRANDCHILD (pid $E2_GRANDCHILD_PID) to still be alive past its configured ${E2_TIMEOUT}s timeout -- this negative control did not reproduce the historical defect"
        fi
        # Best-effort cleanup -- never leave a stray sleep/wrapper process
        # behind for the rest of the CI run, regardless of assertion result.
        for _p in "$E2_CHILD_PID" "$E2_GRANDCHILD_PID" "$E2_WRAP_PID"; do
            [ -n "$_p" ] && kill -TERM "$_p" 2>/dev/null
        done
        sleep 0.3
        for _p in "$E2_CHILD_PID" "$E2_GRANDCHILD_PID" "$E2_WRAP_PID"; do
            [ -n "$_p" ] && kill -KILL "$_p" 2>/dev/null
        done
    else
        _block_note_fail "pre-fix (commit $X1097_PRIME_PREFIX_COMMIT) fixture returned within ${E2_WAITED}s of a ${E2_TIMEOUT}s configured timeout -- this negative control no longer reproduces the historical defect (has the fixture drifted, or did upstream history change?)"
    fi
    wait "$E2_WRAP_PID" 2>/dev/null
else
    echo "    SKIP: pre-fix fixture unavailable (see grounding block above)"
fi
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# (c) trailing rc noise must not corrupt the last PATH entry (POST-FIX
# passes; PRE-FIX negative control proves the suite would have caught it).
# ─────────────────────────────────────────────────────────────────────────────
FIXED_PATH_FOR_NOISE="/bin:/usr/bin:/opt/homebrew/bin"
EXPECTED_LAST_ENTRY="/opt/homebrew/bin"

_block_start "XACA-1097 defect 2 [POST-FIX]: TRAILING rc output (a login shell's guaranteed logout-file pass) does not corrupt the last PATH entry"
E3_OUT="$(_prime_elapsed_and_path "$PRIME_POST_FN" "$FAKE_TRAILING_SHELL" 5 "$FIXED_PATH_FOR_NOISE" 2>/dev/null)"
E3_CAPTURED="$(printf '%s\n' "$E3_OUT" | sed -n 's/^CAPTURED://p')"
assert_not_empty "$E3_CAPTURED" "no CAPTURED marker -- fixture broken; got: $E3_OUT"
assert_eq "${E3_CAPTURED##*:}" "$EXPECTED_LAST_ENTRY" \
    "trailing rc noise corrupted the last PATH entry under the FIXED code; full captured value: [$E3_CAPTURED]"
assert_not_contains "$E3_CAPTURED" "goodbye" \
    "captured PATH leaked trailing rc banner text under the FIXED code: [$E3_CAPTURED]"
_block_end

_block_start "XACA-1097 defect 2 [PRE-FIX negative control, commit $X1097_PRIME_PREFIX_COMMIT]: trailing rc noise DOES corrupt the last PATH entry -- proves this suite would have caught the shipped regression"
if [ "$PRIME_PREFIX_AVAILABLE" = true ]; then
    E4_OUT="$(_prime_elapsed_and_path "$PRIME_PRE_FN" "$FAKE_TRAILING_SHELL" 5 "$FIXED_PATH_FOR_NOISE" 2>/dev/null)"
    E4_CAPTURED="$(printf '%s\n' "$E4_OUT" | sed -n 's/^CAPTURED://p')"
    assert_not_empty "$E4_CAPTURED" "no CAPTURED marker -- fixture broken; got: $E4_OUT"
    assert_contains "$E4_CAPTURED" "goodbye" \
        "expected the pre-fix code to leak trailing rc banner text into the captured PATH, but it did not -- this negative control did not reproduce the historical defect: [$E4_CAPTURED]"
    if [ "${E4_CAPTURED##*:}" = "$EXPECTED_LAST_ENTRY" ]; then
        _block_note_fail "expected the pre-fix code's last PATH entry to be corrupted, but it matched the clean value -- this negative control did not reproduce the historical defect"
    fi
else
    echo "    SKIP: pre-fix fixture unavailable (see grounding block above)"
fi
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# (d) LEADING banner noise must still be inert -- regression guard for the
# earlier (already-shipped) XACA-1097-019 fix, unaffected by defects 1/2.
# ─────────────────────────────────────────────────────────────────────────────
_block_start "XACA-1097 [regression guard]: LEADING rc banner noise still does not corrupt the captured PATH (must not regress the earlier XACA-1097-019 fix)"
E5_OUT="$(_prime_elapsed_and_path "$PRIME_POST_FN" "$FAKE_LEADING_SHELL" 5 "$FIXED_PATH_FOR_NOISE" 2>/dev/null)"
E5_CAPTURED="$(printf '%s\n' "$E5_OUT" | sed -n 's/^CAPTURED://p')"
assert_not_empty "$E5_CAPTURED" "no CAPTURED marker -- fixture broken; got: $E5_OUT"
assert_eq "$E5_CAPTURED" "$FIXED_PATH_FOR_NOISE" \
    "leading rc banner noise corrupted the captured PATH; got: [$E5_CAPTURED]"
assert_not_contains "$E5_CAPTURED" "hello" \
    "captured PATH leaked leading rc banner text: [$E5_CAPTURED]"
_block_end


# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone mode only -- test-runner.sh tallies pass/fail from its
# OWN exported functions' output).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "──────────────────────────────────────────────"
    echo "  resolver call-sites test:  PASS=$_PASS  FAIL=$_FAIL"
    echo "──────────────────────────────────────────────"
    [ "$_FAIL" -eq 0 ] || exit 1
fi
exit 0
