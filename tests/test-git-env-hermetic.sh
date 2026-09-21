#!/bin/bash

# test-git-env-hermetic.sh
# Regression suite for tests/lib/git-env-hermetic.sh: an inherited GIT_DIR /
# GIT_WORK_TREE must never let a fixture's bare `git init`/`git config` reach a
# real repository.
#
# The incident (2026-09-08): suites were run with GIT_DIR/GIT_WORK_TREE exported
# at the dev machine's main tap checkout. test-xaca-0761's Case 3 fixture
# (`cd "$C3_ROOT"; git init; git config user.name "Sandbox"`) wrote
# `Sandbox <test@example.com>` into that checkout's config instead of the
# fixture's, and 18 tap commits (17 pushed) were authored under it.
#
# Sections:
#   1  positive control — with a hostile GIT_DIR, the fixture pattern DOES
#      mutate the target repo (proves the checks below can see a leak)
#   2  the library unsets every repository-local var git itself lists
#   3  after the library, the same fixture pattern leaves the target repo's
#      config byte-identical and gives the fixture its own .git
#   4  END TO END: a probe suite run through the REAL test-runner.sh with a
#      hostile GIT_DIR/GIT_WORK_TREE exported sees neither variable
#   5  every suite with a bare `git config user.*` sources the library before
#      it (standalone-run coverage), and a mutant without it is flagged
#
# Every repository touched here is created under TEST_TMP_DIR.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/git-env-hermetic.sh"
RUNNER="$SCRIPT_DIR/test-runner.sh"

WORK="${TEST_TMP_DIR:?TEST_TMP_DIR must be set by test-runner.sh}/git-env-hermetic"
mkdir -p "$WORK"

# A throwaway repo standing in for "the real repo the caller pointed GIT_DIR at".
_make_target() { # _make_target <dir>
    git init -q "$1" && git -C "$1" config --local --get-regexp '.' > "$1.cfg-before" 2>/dev/null
    return 0
}
_target_cfg() { git -C "$1" config --local --list 2>/dev/null; }

# The exact fixture shape from test-xaca-0761 Case 3, parameterised.
FIXTURE_BLOCK='cd "$FIX" || exit 1; git init -q; git config user.email test@example.com; git config user.name "Sandbox"'

# ─── Section 1 ────────────────────────────────────────────────────────────────
test_start "positive control: hostile GIT_DIR redirects a fixture's git config into the target repo"
T1="$WORK/target1"; F1="$WORK/fixture1"; mkdir -p "$F1"; _make_target "$T1"
before="$(_target_cfg "$T1")"
env GIT_DIR="$T1/.git" GIT_WORK_TREE="$T1" FIX="$F1" GIT_CONFIG_NOSYSTEM=1 \
    bash -c "$FIXTURE_BLOCK" >/dev/null 2>&1 || true
after="$(_target_cfg "$T1")"
assert_not_equal "$before" "$after"
assert_contains "$after" "user.name=Sandbox"
if [ -d "$F1/.git" ]; then
    test_fail "fixture got its own .git even though GIT_DIR was hostile — control did not reproduce the leak"
else
    test_pass
fi

# ─── Section 2 ────────────────────────────────────────────────────────────────
test_start "library unsets every repository-local variable git lists"
VARS="$(git rev-parse --local-env-vars | tr '\n' ' ')"
assert_not_empty "$VARS"
# Word splitting of the generated VAR=value list is intentional (SC2046);
# single quotes keep the inner script literal for bash -c (SC2016).
# shellcheck disable=SC2046,SC2016
left="$(env $(for v in $VARS; do printf '%s=%s ' "$v" "$WORK/hostile-$v"; done) \
    bash -c '. "$1" || exit 9; for v in $2; do eval "[ -n \"\${$v+x}\" ] && printf \"%s \" \"$v\""; done; exit 0' _ "$LIB" "$VARS")"
rc=$?
assert_equal "0" "$rc"
assert_empty "$left"
test_pass

# ─── Section 3 ────────────────────────────────────────────────────────────────
test_start "after the library, the fixture pattern leaves the target repo untouched"
T3="$WORK/target3"; F3="$WORK/fixture3"; mkdir -p "$F3"; _make_target "$T3"
before="$(_target_cfg "$T3")"
env GIT_DIR="$T3/.git" GIT_WORK_TREE="$T3" FIX="$F3" LIB="$LIB" GIT_CONFIG_NOSYSTEM=1 \
    bash -c ". \"\$LIB\" || exit 9; $FIXTURE_BLOCK" >/dev/null 2>&1
rc=$?
assert_equal "0" "$rc"
assert_equal "$before" "$(_target_cfg "$T3")"
assert_dir_exists "$F3/.git"
assert_equal "Sandbox" "$(git -C "$F3" config --local user.name)"
test_pass

# ─── Section 4 ────────────────────────────────────────────────────────────────
test_start "END TO END: a suite run through the real test-runner.sh never sees a hostile GIT_DIR"
T4="$WORK/target4"; _make_target "$T4"
PROBE_DIR="$WORK/probe"; mkdir -p "$PROBE_DIR"
PROBE="$PROBE_DIR/test-probe-git-env.sh"
PROBE_OUT="$WORK/probe.out"
cat > "$PROBE" <<EOF
#!/bin/bash
test_start "probe"
printf 'GIT_DIR=%s GIT_WORK_TREE=%s GIT_INDEX_FILE=%s\n' "\${GIT_DIR-unset}" "\${GIT_WORK_TREE-unset}" "\${GIT_INDEX_FILE-unset}" > "$PROBE_OUT"
FIX="$WORK/fixture4"; mkdir -p "\$FIX"
( $FIXTURE_BLOCK )
test_pass
EOF
before="$(_target_cfg "$T4")"
SB4="$WORK/home4"; mkdir -p "$SB4"
env GIT_DIR="$T4/.git" GIT_WORK_TREE="$T4" GIT_INDEX_FILE="$T4/.git/index" \
    HOME="$SB4" AITEAMFORGE_DIR="$SB4/aiteamforge" CLAUDE_CONFIG_DIR="$SB4/.claude" \
    AITEAMFORGE_SKIP_LAUNCHCTL=1 AITF_LAUNCHAGENT_OPTOUT_FILE="$SB4/.aiteamforge/launchagents.optout" \
    bash "$RUNNER" "$PROBE" > "$WORK/runner4.log" 2>&1
rc=$?
assert_equal "0" "$rc"
assert_file_exists "$PROBE_OUT"
assert_equal "GIT_DIR=unset GIT_WORK_TREE=unset GIT_INDEX_FILE=unset" "$(cat "$PROBE_OUT" 2>/dev/null)"
assert_equal "$before" "$(_target_cfg "$T4")"
assert_dir_exists "$WORK/fixture4/.git"
test_pass

# ─── Section 5 ────────────────────────────────────────────────────────────────
# A suite that writes a git identity with a bare `git config user.*` (no -C,
# no --file, no --global) must source the library BEFORE that line, so it is
# covered when run standalone, not only via test-runner.sh.
_unguarded() { # prints "<file>:<line>" for each suite writing identity before sourcing the lib
    awk '
        FNR == 1 { src = 0 }
        /^[[:space:]]*(\.|source)[[:space:]]+[^#]*lib\/git-env-hermetic\.sh/ { src = 1 }
        /^[[:space:]]*git config (--local )?user\./ && !src { print FILENAME ":" FNR; nextfile }
    ' "$@"
}

test_start "every suite with a bare 'git config user.*' sources the library first"
writers=$(grep -lE '^[[:space:]]*git config (--local )?user\.' "$SCRIPT_DIR"/test-*.sh | grep -c .)
if [ "$writers" -lt 4 ]; then
    test_fail "found only $writers identity-writing suites (expected >= 4) — the scan is wrong, so the check would be vacuous"
else
    assert_empty "$(_unguarded "$SCRIPT_DIR"/test-*.sh)"
    test_pass
fi

test_start "guard is not vacuous: a suite without the source line is flagged"
MUT="$WORK/test-mutant-0761.sh"
grep -v 'lib/git-env-hermetic\.sh' "$SCRIPT_DIR/test-xaca-0761-knowledge-sync-launchagent.sh" > "$MUT"
assert_contains "$(_unguarded "$MUT")" "test-mutant-0761.sh:"
test_pass
