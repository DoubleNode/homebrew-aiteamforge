#!/bin/bash
# test-xaca-1095-atomic-install-and-render-guard.sh
#
# Coverage for two hardening changes to update_shell_helpers()
# (libexec/commands/aiteamforge-upgrade.sh) made in response to PR #820
# review findings, AFTER the tester bot's original pass — neither behaviour
# had dedicated test coverage (flagged as a gap in XACA-1095-017/018's
# sibling review of this PR).
#
# BEHAVIOUR 1 — Atomic install. The final write used to be
#   `cat "$_kanban_rendered" > "$kanban_target"`
# whose bare `>` truncates the target BEFORE any content is written, so an
# interrupted or failing write leaves a TRUNCATED kanban-helpers.sh on disk —
# strictly worse than leaving the stale-but-working file in place. The fix:
#   `chmod +x "$temp" && mv -f "$temp" "$target"`
# with the temp file created as a SIBLING of the target
# (`mktemp "${kanban_target}.XXXXXX"`, not under $TMPDIR) so the rename is a
# same-filesystem atomic rename, never a degrade-to-copy+unlink.
#
# BEHAVIOUR 2 — Render-integrity guard. Before a render becomes eligible to
# install, it is validated three ways: sed's own exit status, non-empty
# output, and a line-count match against the source (the substitutions are
# pure `s|...|g`, so a correct render is always line-for-line with its
# source). On failure the function warns "Refusing to install" and leaves
# the existing installed copy untouched — otherwise a failed/short render
# would `cmp` as "differs" and get installed anyway, clobbering a working
# file with an empty or partial one.
#
# Strategy: extract update_shell_helpers (and its
# _xaca0771_mandatory_alias_basenames dependency, called later in the same
# function body) via awk, exactly as test-xaca-1095-helpers-template-
# preference.sh does, rather than sourcing the whole upgrade script (which
# executes its entire upgrade flow top-level on source). Behavioral
# assertions run the REAL function in a sandboxed subshell; failure-injection
# assertions stub `mv`/`sed` as shell functions inside that same subshell —
# a function defined before the call shadows the builtin/external command for
# the whole subshell, and bash still performs any `>` redirection on the
# call site before invoking the (stubbed) command, so this reproduces a real
# truncation-on-failure scenario deterministically rather than needing to
# kill a process mid-write.
#
# The atomic-install proof (T-A3) additionally runs the PRE-HARDENING version
# of update_shell_helpers, extracted from `git show HEAD:...` (this repo's
# working tree has these hardening changes UNCOMMITTED as of this test's
# authorship — HEAD is genuinely the pre-hardening blob; if that ever stops
# being true this case degrades to a SKIP, never a false pass).
#
# All filesystem activity is sandboxed under TEST_TMP_DIR. Never touches real
# $HOME/aiteamforge or ~/.aiteamforge.
#
# Designed to run standalone OR via test-runner.sh.
# Exit 0 = all cases pass (standalone). Exit 1 = at least one case failed
# (standalone only — see the _STANDALONE note below).

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
REAL_TEMPLATE="$TAP_ROOT/share/templates/kanban/kanban-helpers.template.sh"
REAL_ALIASES="$TAP_ROOT/share/templates/aliases/kanban-aliases.sh"

for _need in "$UPGRADE_SH" "$REAL_TEMPLATE" "$REAL_ALIASES"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
        echo "  This test must run from inside the homebrew-tap checkout." >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework — printed summary gated on _STANDALONE, not on whether
# the local counters are nonzero (the vacuous-green shape XACA-1095-018 fixed
# elsewhere in this suite; see knowledge k070).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
_PASS=0
_FAIL=0
_FAIL_AT_START=0
_CURRENT_TEST=""
if ! declare -F test_start &>/dev/null; then
    _STANDALONE=true
    # XACA-1095: test_pass must NOT be unconditional. assert_* records only on
    # FAILURE, so an unconditional trailing test_pass makes a case that failed an
    # assertion report BOTH a FAIL and a PASS — and makes _PASS equal the case
    # count regardless of outcome, i.e. evidence of nothing. Demonstrated by
    # negative control while building this suite: mutating the subject produced
    # "PASS=16 FAIL=1" with the PASS total unchanged. The exit code stayed correct,
    # but a pass total that cannot move is the same displayed-vs-actual divergence
    # this whole ticket exists to close. Gate the pass on "no failure was recorded
    # since this case started".
    test_start() { _CURRENT_TEST="$1"; _FAIL_AT_START=$_FAIL; printf "TEST: %s\n" "$1"; }
    test_pass()  {
        if [ "${_FAIL:-0}" -ne "${_FAIL_AT_START:-0}" ]; then return 0; fi
        _PASS=$((_PASS + 1)); printf "  PASS: %s\n" "$_CURRENT_TEST"
    }
    test_fail()  { _FAIL=$((_FAIL + 1)); printf "  FAIL: %s — %s\n" "$_CURRENT_TEST" "${1:-}" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# XACA-1095 [Review] (PR #820): case-level pass gating that works under BOTH
# invocation paths.
#
# The first attempt at this redefined test_pass inside the
# `if ! declare -F test_start` standalone shim. That is INERT under
# test-runner.sh: the runner exports its own test_start/test_pass before
# sourcing each file, so the shim never installs and a failing case still
# reported a PASS in CI — the exact divergence the fix claimed to close, just
# relocated to the path that actually matters.
#
# These wrappers are defined unconditionally and used at every call site, so
# the gating holds whether test_pass comes from the local shim or from the
# runner. _LOCAL_FAILS is our own tally; it is incremented by the assert_*
# helpers below (which are also always locally defined) and by _t_fail.
# ─────────────────────────────────────────────────────────────────────────────
_LOCAL_FAILS=0
_LOCAL_FAILS_AT_START=0
_t_start() { _LOCAL_FAILS_AT_START="$_LOCAL_FAILS"; test_start "$@"; }
_t_fail()  { _LOCAL_FAILS=$((_LOCAL_FAILS + 1)); test_fail "$@"; }
_t_pass()  {
    # NOTE: the call below MUST stay `test_pass` (the underlying harness
    # function), never `_t_pass`. An earlier mechanical rewrite of call sites
    # matched this very line and made this function call itself — infinite
    # recursion, SIGSEGV (exit 139) on every run. Kept explicit as a warning.
    if [ "$_LOCAL_FAILS" -ne "$_LOCAL_FAILS_AT_START" ]; then return 0; fi
    test_pass
}

assert_eq() {
    local got="$1" expected="$2" msg="${3:-Expected '$2', got '$1'}"
    [ "$got" = "$expected" ] || _t_fail "$msg"
}
assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-Expected to find '$2' in output}"
    [[ "$haystack" == *"$needle"* ]] || _t_fail "$msg"
}

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1095-atomic-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
_cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap _cleanup EXIT INT TERM

WORK_ROOT="$TEST_TMP_DIR/xaca1095-atomic"
mkdir -p "$WORK_ROOT"
_next_sandbox() { mktemp -d "$WORK_ROOT/sbx-XXXXXX"; }

# ─────────────────────────────────────────────────────────────────────────────
# Extraction helpers (mirrors test-xaca-1095-helpers-template-preference.sh)
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn_from_content() {
    local fn="$1"
    awk -v fn="$fn" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    '
}
_extract_fn_from_file() {
    local file="$1" fn="$2"
    _extract_fn_from_content "$fn" < "$file"
}
_extract_fn_from_rev() {
    local rev="$1" relpath="$2" fn="$3"
    git -C "$TAP_ROOT" show "${rev}:${relpath}" 2>/dev/null | _extract_fn_from_content "$fn"
}

# XACA-1095-020: pin the PRE-HARDENING commit explicitly; do NOT use HEAD.
# This negative control's whole value is running the OLD `cat > target` body and
# showing it genuinely truncates. Resolving the baseline as HEAD worked only
# while the hardening was uncommitted -- the moment it landed, HEAD contained
# `mv -f`, the guard below flipped, and the proof case degraded to a permanent
# SKIP. A negative control that can never execute again is not a control; it is
# a comment that costs CI time. 75b3ef1 is the last tap commit before the
# hardening (aaf3689) and is an ancestor of main, so it stays resolvable.
# CI CAVEAT (known, deliberate): the tap's workflows use actions/checkout@v4
# with no fetch-depth, i.e. a depth-1 shallow clone, so this rev is NOT
# reachable in CI and this one case degrades to SKIP there. That is honest
# skipping -- you cannot run history you do not have -- and the suite's other
# cases, which test CURRENT behaviour, all still run. The control executes on
# any full checkout (developer machines, and any job that sets fetch-depth: 0).
# Embedding the 197-line historical function as a literal fixture was
# considered and rejected: a frozen copy that large is its own maintenance
# liability and would drift silently. Raising CI to a full clone for one
# negative control is a workflow-wide change that belongs in its own ticket,
# not in a bugfix PR.
_PRE_HARDENING_REV="75b3ef1"
_PRE_HARDENING_AVAILABLE=true
_PRE_HARDENING_SRC="$(_extract_fn_from_rev "$_PRE_HARDENING_REV" "libexec/commands/aiteamforge-upgrade.sh" "update_shell_helpers")"
if [ -z "$_PRE_HARDENING_SRC" ]; then
    # The pinned rev is genuinely unreachable (shallow clone, or a consumer tap
    # checkout without full history). Cannot prove what is not there -- skip,
    # and say why.
    _PRE_HARDENING_AVAILABLE=false
elif printf '%s' "$_PRE_HARDENING_SRC" | grep -q 'mv -f'; then
    # Reachable but ALREADY hardened: the pin is wrong, not the environment.
    # This must be loud. Silently skipping here is how the control rotted the
    # first time.
    echo "FATAL: _PRE_HARDENING_REV ($_PRE_HARDENING_REV) already contains the hardening -- the pin is stale. Update it to the commit before the atomic-install change." >&2
    exit 1
fi

_build_framework_sandbox() {
    local dir="$1"
    mkdir -p "$dir/share/templates/kanban" "$dir/share/templates/aliases"
    cp "$REAL_TEMPLATE" "$dir/share/templates/kanban/kanban-helpers.template.sh"
    cp "$REAL_ALIASES" "$dir/share/templates/aliases/kanban-aliases.sh"
}

# Runner: extracts update_shell_helpers (current file, or HEAD blob when
# which=pre-hardening) plus its _xaca0771_mandatory_alias_basenames
# dependency, and calls it in an isolated subshell. `extra_stub_src`, if
# given, is eval'd AFTER the extracted functions are defined but BEFORE
# update_shell_helpers is invoked — used to shadow mv/sed for failure
# injection.
_run_update_shell_helpers() {
    local which="$1" framework_dir="$2" working_dir="$3" extra_stub_src="${4:-}"
    local fn_src alias_fn_src
    alias_fn_src="$(_extract_fn_from_file "$UPGRADE_SH" "_xaca0771_mandatory_alias_basenames")"
    if [ "$which" = "pre-hardening" ]; then
        fn_src="$_PRE_HARDENING_SRC"
    else
        fn_src="$(_extract_fn_from_file "$UPGRADE_SH" "update_shell_helpers")"
    fi
    if [ -z "$fn_src" ] || [ -z "$alias_fn_src" ]; then
        echo "EXTRACT_FAILED: update_shell_helpers ($which)" >&2
        return 2
    fi
    (
        for _p in print_section print_info print_success print_warning print_error; do
            eval "${_p}() { echo \"[\${FUNCNAME[0]:-msg}] \$*\"; }"
        done
        eval "$alias_fn_src"
        eval "$fn_src"
        if [ -n "$extra_stub_src" ]; then
            eval "$extra_stub_src"
        fi
        FRAMEWORK_DIR="$framework_dir" WORKING_DIR="$working_dir" DRY_RUN=false FORCE=false \
            update_shell_helpers
    )
}

# ═══════════════════════════════════════════════════════════════════════════
# BEHAVIOUR 1 — Atomic install
# ═══════════════════════════════════════════════════════════════════════════

_t_start "T-A1: successful install is never observed truncated and matches the rendered template line-for-line"
TA1_FW="$(_next_sandbox)"; TA1_WORK="$(_next_sandbox)"
_build_framework_sandbox "$TA1_FW"
printf '#!/bin/zsh\n# stale placeholder\n' > "$TA1_WORK/kanban-helpers.sh"
touch -t 200001010000 "$TA1_WORK/kanban-helpers.sh"
_run_update_shell_helpers current "$TA1_FW" "$TA1_WORK" >/dev/null 2>&1
_TA1_SRC_LINES=$(wc -l < "$REAL_TEMPLATE" | tr -d '[:space:]')
_TA1_OUT_LINES=$(wc -l < "$TA1_WORK/kanban-helpers.sh" 2>/dev/null | tr -d '[:space:]')
if [ ! -s "$TA1_WORK/kanban-helpers.sh" ]; then
    _t_fail "installed kanban-helpers.sh is empty after a successful update — this IS a truncation"
elif [ "$_TA1_OUT_LINES" != "$_TA1_SRC_LINES" ]; then
    _t_fail "installed file has $_TA1_OUT_LINES lines, template has $_TA1_SRC_LINES — truncated or malformed"
else
    _t_pass
fi

_t_start "T-A2: successful install leaves no stray sibling temp file (kanban-helpers.sh.XXXXXX)"
_TA2_STRAY=$(find "$TA1_WORK" -maxdepth 1 -name 'kanban-helpers.sh.??????' 2>/dev/null)
if [ -n "$_TA2_STRAY" ]; then
    _t_fail "stray temp file(s) left behind after successful install: $_TA2_STRAY"
else
    _t_pass
fi

_t_start "T-A5: successful install leaves mode 755 — NOT 0711 (mktemp is 0600; symbolic +x on 0600 yields execute-without-read)"
# XACA-1095 [Review] (PR #820): this case exists because the atomic-install fix
# originally used `chmod +x` on the mktemp'd temp file. mktemp creates at 0600
# regardless of umask, symbolic +x turns that into 0711, and `mv` carries that
# mode onto the installed file — silently stripping group/other READ, which a
# shell script needs in order to be sourced at all. The rest of this suite passed
# green through that regression because nothing asserted permission bits.
# 755 is the canonical mode: what a fresh install produces, and what the live
# consumers measurably carry (-rwxr-xr-x).
_TA5_MODE=$(stat -f '%Lp' "$TA1_WORK/kanban-helpers.sh" 2>/dev/null \
            || stat -c '%a' "$TA1_WORK/kanban-helpers.sh" 2>/dev/null)
if [ -z "$_TA5_MODE" ]; then
    _t_fail "could not stat installed kanban-helpers.sh to read its mode"
elif [ "$_TA5_MODE" != "755" ]; then
    _t_fail "installed kanban-helpers.sh is mode ${_TA5_MODE}, expected 755 — a shell script needs READ, not just execute, to be sourced"
else
    _t_pass
fi

_t_start "T-A3: a failed rename (mv stubbed to fail) leaves the OLD installed copy UNCHANGED, not truncated"
TA3_FW="$(_next_sandbox)"; TA3_WORK="$(_next_sandbox)"
_build_framework_sandbox "$TA3_FW"
# NOTE: no trailing newline in this fixture string — `$(cat ...)` command
# substitution always strips trailing newlines, so comparing against a
# fixture that HAS one would spuriously "differ" even when the file is
# byte-identical to what was written.
_TA3_OLD_CONTENT=$'#!/bin/zsh\nkb-run() { :; }'
printf '%s' "$_TA3_OLD_CONTENT" > "$TA3_WORK/kanban-helpers.sh"
touch -t 200001010000 "$TA3_WORK/kanban-helpers.sh"
_run_update_shell_helpers current "$TA3_FW" "$TA3_WORK" 'mv() { return 1; }' >/dev/null 2>&1
_TA3_AFTER="$(cat "$TA3_WORK/kanban-helpers.sh" 2>/dev/null)"
if [ "$_TA3_AFTER" != "$_TA3_OLD_CONTENT" ]; then
    _t_fail "target was modified despite a failed mv — expected byte-identical old content to survive a failed rename"
else
    _t_pass
fi

_t_start "T-A4 (proof): PRE-HARDENING update_shell_helpers (cat > target) DOES truncate the target on a failed write"
if [ "$_PRE_HARDENING_AVAILABLE" != true ]; then
    echo "  SKIP: pre-hardening HEAD blob not available or already hardened — T-A1/T-A2/T-A3 above are unaffected"
else
    TA4_FW="$(_next_sandbox)"; TA4_WORK="$(_next_sandbox)"
    _build_framework_sandbox "$TA4_FW"
    _TA4_OLD_CONTENT=$'#!/bin/zsh\nkb-run() { :; }'
    printf '%s' "$_TA4_OLD_CONTENT" > "$TA4_WORK/kanban-helpers.sh"
    touch -t 200001010000 "$TA4_WORK/kanban-helpers.sh"
    # cat() as a shell function still lets the `>` redirection at the call
    # site truncate the target BEFORE the (stubbed, failing) function runs —
    # this is exactly the real-world torn-write mechanism, not a simulation
    # of its symptom.
    _run_update_shell_helpers pre-hardening "$TA4_FW" "$TA4_WORK" 'cat() { return 1; }' >/dev/null 2>&1
    _TA4_AFTER="$(cat "$TA4_WORK/kanban-helpers.sh" 2>/dev/null)"
    if [ -z "$_TA4_AFTER" ] && [ "$_TA4_AFTER" != "$_TA4_OLD_CONTENT" ]; then
        _t_pass
    else
        _t_fail "expected the pre-hardening code path to leave the target TRUNCATED (empty) after a failed cat — got: '$_TA4_AFTER' — proof invalid, verify the extracted pre-hardening blob"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# BEHAVIOUR 2 — Render-integrity guard
# ═══════════════════════════════════════════════════════════════════════════
# Three independent broken-render triggers, matching the guard's three checks
# (sed exit status / non-empty output / line-count match), each proven NOT
# to clobber a good installed helper.

_RG_OLD_CONTENT=$'#!/bin/zsh\nkb-run() { :; }\nkb-pick() { :; }'

_t_start "T-R1: sed exit failure — guard refuses to install, old copy untouched"
TR1_FW="$(_next_sandbox)"; TR1_WORK="$(_next_sandbox)"
_build_framework_sandbox "$TR1_FW"
printf '%s' "$_RG_OLD_CONTENT" > "$TR1_WORK/kanban-helpers.sh"
touch -t 200001010000 "$TR1_WORK/kanban-helpers.sh"
_TR1_OUT="$(_run_update_shell_helpers current "$TR1_FW" "$TR1_WORK" 'sed() { return 1; }' 2>&1)"
_TR1_AFTER="$(cat "$TR1_WORK/kanban-helpers.sh" 2>/dev/null)"
assert_contains "$_TR1_OUT" "Refusing to install" "Expected the render-integrity guard to fire and refuse install"
if [ "$_TR1_AFTER" != "$_RG_OLD_CONTENT" ]; then
    _t_fail "old installed copy was modified after a sed-exit-failure render — guard must leave it untouched"
else
    _t_pass
fi

_t_start "T-R2: sed produces empty output — guard refuses to install, old copy untouched (not clobbered with an empty file)"
TR2_FW="$(_next_sandbox)"; TR2_WORK="$(_next_sandbox)"
_build_framework_sandbox "$TR2_FW"
printf '%s' "$_RG_OLD_CONTENT" > "$TR2_WORK/kanban-helpers.sh"
touch -t 200001010000 "$TR2_WORK/kanban-helpers.sh"
_TR2_OUT="$(_run_update_shell_helpers current "$TR2_FW" "$TR2_WORK" 'sed() { return 0; }' 2>&1)"
_TR2_AFTER="$(cat "$TR2_WORK/kanban-helpers.sh" 2>/dev/null)"
assert_contains "$_TR2_OUT" "Refusing to install" "Expected the render-integrity guard to fire and refuse install"
if [ "$_TR2_AFTER" != "$_RG_OLD_CONTENT" ]; then
    _t_fail "old installed copy was modified/emptied after a sed-empty-output render — this is precisely the empty-file-clobber the guard exists to prevent"
else
    _t_pass
fi

_t_start "T-R3: sed produces a short/mismatched-line-count render — guard refuses to install, old copy untouched"
TR3_FW="$(_next_sandbox)"; TR3_WORK="$(_next_sandbox)"
_build_framework_sandbox "$TR3_FW"
printf '%s' "$_RG_OLD_CONTENT" > "$TR3_WORK/kanban-helpers.sh"
touch -t 200001010000 "$TR3_WORK/kanban-helpers.sh"
# A stub that exits 0 and produces non-empty output, but far fewer lines than
# the real template — isolates the LINE-COUNT check specifically (distinct
# from the exit-status and empty-output checks above).
_TR3_OUT="$(_run_update_shell_helpers current "$TR3_FW" "$TR3_WORK" 'sed() { echo "#!/bin/zsh — truncated mid-render"; }' 2>&1)"
_TR3_AFTER="$(cat "$TR3_WORK/kanban-helpers.sh" 2>/dev/null)"
assert_contains "$_TR3_OUT" "Refusing to install" "Expected the render-integrity guard to fire on a line-count mismatch"
if [ "$_TR3_AFTER" != "$_RG_OLD_CONTENT" ]; then
    _t_fail "old installed copy was modified after a truncated-render — guard must leave it untouched"
else
    _t_pass
fi

_t_start "T-R4 (negative control): a GOOD render with matching line count is NOT blocked by the guard"
TR4_FW="$(_next_sandbox)"; TR4_WORK="$(_next_sandbox)"
_build_framework_sandbox "$TR4_FW"
printf '%s' "$_RG_OLD_CONTENT" > "$TR4_WORK/kanban-helpers.sh"
touch -t 200001010000 "$TR4_WORK/kanban-helpers.sh"
_TR4_OUT="$(_run_update_shell_helpers current "$TR4_FW" "$TR4_WORK" 2>&1)"
_TR4_AFTER_LINES=$(wc -l < "$TR4_WORK/kanban-helpers.sh" 2>/dev/null | tr -d '[:space:]')
_TR4_SRC_LINES=$(wc -l < "$REAL_TEMPLATE" | tr -d '[:space:]')
if printf '%s' "$_TR4_OUT" | grep -q "Refusing to install"; then
    _t_fail "the render-integrity guard fired on a genuinely GOOD render — false positive"
elif [ "$_TR4_AFTER_LINES" != "$_TR4_SRC_LINES" ]; then
    _t_fail "a real, unblocked install did not end up line-for-line with the template ($_TR4_AFTER_LINES vs $_TR4_SRC_LINES)"
else
    _t_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone mode only)
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "──────────────────────────────────────────────"
    echo "  atomic-install/render-guard test:  PASS=$_PASS  FAIL=$_FAIL"
    echo "──────────────────────────────────────────────"
    [ "$_FAIL" -eq 0 ] || exit 1
fi
exit 0
