#!/bin/bash
# test-xaca-1120-template-phase-honest-reporting.sh
#
# Regression coverage for XACA-1120.
#
# WHAT THE TICKET SAID vs WHAT WAS TRUE
# -------------------------------------
# XACA-1120 was filed CRITICAL with this stated root cause: "the Updating
# Templates phase prints 'All templates up to date' and short-circuits before
# re-rendering kanban-helpers.sh, and --force does not override that path."
#
# That attribution was wrong, and the misattribution is the interesting part.
# update_templates() globs `-name "*.template"` and writes into
# ${WORKING_DIR}/config/. kanban-helpers.template.sh does not match that glob
# (it ends `.sh`), and its target is ${WORKING_DIR}/kanban-helpers.sh, not
# under config/. update_templates() therefore CANNOT re-render
# kanban-helpers.sh and never has. The file is rendered by
# update_shell_helpers(), whose staleness test XACA-1095 had already converted
# from mtime to rendered-content comparison, and which works.
#
# So why did a careful operator conclude otherwise? Because BOTH phases lied by
# omission, in opposite directions, and the two lies composed:
#
#   1. update_templates() printed "All templates up to date" unconditionally.
#      Nothing in the tap ever creates ${WORKING_DIR}/config/ (verified: the
#      only non-test reference to that path in the entire tap was the read
#      inside update_templates itself). So every one of the 17 shipped
#      templates hit `[ ! -f "$target_file" ]` and `continue`d silently,
#      templates_updated stayed 0, and the function fell through to a success
#      line that could not fail. A check that cannot fail is not a check.
#
#   2. update_shell_helpers() printed NOTHING when the kanban-helpers.sh
#      render was a verified no-op, "matching this function's existing quiet
#      convention". So "rendered and byte-identical", "never reached", and
#      "skipped by a guard" all looked the same in the log.
#
# Net effect: the only "templates"-flavoured line in an upgrade log came from
# the phase that does not handle kanban-helpers.sh, and the phase that does
# handle it was silent. The ticket was filed against the wrong function.
#
# A THIRD defect, latent behind the dead path: update_templates did a raw
# `cp "$template" "$target_file"` under a comment reading "Re-process template
# (this would call template processor) / For now, just copy". Had any config/
# target ever existed, that would have installed literal {{AITEAMFORGE_DIR}},
# {{ORG_NAME}} and {{SHARED_DEV_ROOT}} placeholders over a live config file.
#
# WHAT THIS SUITE ASSERTS
# -----------------------
# Every current-behavior case is paired with a NEGATIVE CONTROL that extracts
# the SAME function from the pre-fix commit and runs it in an identical
# sandbox, proving the assertion would actually have failed before the fix.
# Nothing here is asserted by reading a diff.
#
# The pre-fix revision is SELF-LOCATED via `git log -S` on the removed string
# (never a hand-typed SHA -- a typed abbreviation resolves to whatever exists,
# which is how fiction gets accepted). If that history is unavailable (shallow
# clone), the negative controls SKIP; the current-behavior cases do not depend
# on git and still run.
#
# All filesystem activity is sandboxed under TEST_TMP_DIR. NEVER touches the
# real $HOME/.aiteamforge or ~/aiteamforge -- installer-test safety rule. This
# suite only READS the real tap tree and local git history as fixture source.
#
# Designed to run standalone OR via test-runner.sh.

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
# Standalone framework (works sourced by test-runner.sh OR invoked directly).
# Local _PASS/_FAIL always tally; the summary print is gated to standalone so
# we never emit a vacuous "PASS=0 FAIL=0" under the runner.
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
_PASS_COUNT=0
_FAIL_COUNT=0
_SKIP_COUNT=0
_CURRENT_TEST=""
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST - $1" >&2; }
fi
test_skip() { _SKIP_COUNT=$((_SKIP_COUNT + 1)); echo "     SKIP: $_CURRENT_TEST - $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory (runner-supplied or our own).
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1120-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

WORK_DIR="$TEST_TMP_DIR/xaca1120"
mkdir -p "$WORK_DIR"
_next_sandbox() { mktemp -d "$WORK_DIR/sbx-XXXXXX"; }

# ─────────────────────────────────────────────────────────────────────────────
# Pre-fix revision, self-located. `git log -S<string>` finds commits that
# CHANGED the number of occurrences of the string; the most recent such commit
# touching this file is the XACA-1120 fix itself (which removed the emitter),
# so its parent is the pre-fix tree. Resolved, never typed.
# ─────────────────────────────────────────────────────────────────────────────
_PRE_FIX_AVAILABLE=false
PRE_FIX_REV=""
if command -v git >/dev/null 2>&1; then
    # Anchor on the EMITTER CALL, not the bare phrase. The fix deliberately
    # retains the phrase inside an explanatory comment, so a `-S` on the phrase
    # alone would see occurrence count 1 -> 1 and never identify the fix
    # commit. Matching `print_success "All templates up to date"` moves the
    # count 1 -> 0 and pins the right commit.
    _fix_commit="$(git -C "$TAP_ROOT" log -S'print_success "All templates up to date"' \
        --format='%H' -1 -- libexec/commands/aiteamforge-upgrade.sh 2>/dev/null)"
    if [ -n "$_fix_commit" ] && git -C "$TAP_ROOT" cat-file -e "${_fix_commit}^" 2>/dev/null; then
        PRE_FIX_REV="${_fix_commit}^"
        # Confirm the parent really is pre-fix: it must still contain the
        # unfalsifiable emitter. Guards against -S landing on an unrelated
        # commit if history is ever rewritten.
        #
        # Deliberately NOT `git show ... | grep -q`. This file sets
        # `set -o pipefail`, and the emitter sits ~340 lines into a 3100-line
        # file: `grep -q` exits at the first match, `git show` takes SIGPIPE on
        # its next write, and pipefail reports the whole pipeline as FAILED even
        # though the string was found. That silently forced _PRE_FIX_AVAILABLE
        # to false, which SKIPped both negative controls -- the suite still
        # printed an all-green summary while its two most important assertions
        # were inert. Capture first, match in-shell, no pipeline.
        _parent_blob="$(git -C "$TAP_ROOT" show "${PRE_FIX_REV}:libexec/commands/aiteamforge-upgrade.sh" 2>/dev/null)"
        case "$_parent_blob" in
            *'print_success "All templates up to date"'*) _PRE_FIX_AVAILABLE=true ;;
        esac
        unset _parent_blob
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Extraction helpers (mirrors test-xaca-1095's _extract_fn family).
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn_from_content() {
    local fn="$1"
    awk -v fn="$fn" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    '
}
_extract_fn_from_file() { _extract_fn_from_content "$2" < "$1"; }
_extract_fn_from_rev() {
    git -C "$TAP_ROOT" show "${1}:${2}" 2>/dev/null | _extract_fn_from_content "$3"
}

# ─────────────────────────────────────────────────────────────────────────────
# Build a sandbox that looks like a framework install: a FRAMEWORK_DIR holding
# share/templates/<name>.template, and a WORKING_DIR that may or may not have
# a config/ subdirectory.
# ─────────────────────────────────────────────────────────────────────────────
_make_sandbox() {
    local sbx="$1"
    mkdir -p "$sbx/framework/share/templates"
    mkdir -p "$sbx/working"
    # A template carrying every placeholder the renderer substitutes, so a raw
    # `cp` is distinguishable from a real render by inspecting the output.
    cat > "$sbx/framework/share/templates/demo.conf.template" <<'TPL'
# demo config
aiteamforge_dir={{AITEAMFORGE_DIR}}
shared_dev_root={{SHARED_DEV_ROOT}}
org_name={{ORG_NAME}}
TPL
}

# Run update_templates (current or pre-fix) against a sandbox, capturing output.
_run_update_templates() {
    local which="$1" sbx="$2" force="${3:-false}" dry="${4:-false}"
    local fn_src
    if [ "$which" = "current" ]; then
        fn_src="$(_extract_fn_from_file "$UPGRADE_SH" "update_templates")"
    else
        fn_src="$(_extract_fn_from_rev "$PRE_FIX_REV" "libexec/commands/aiteamforge-upgrade.sh" "update_templates")"
    fi
    if [ -z "$fn_src" ]; then
        echo "EXTRACT_FAILED: update_templates ($which)" >&2
        return 2
    fi
    (
        print_section() { echo "== $* =="; }
        print_info()    { echo "INFO: $*"; }
        print_success() { echo "OK: $*"; }
        print_warning() { echo "WARN: $*"; }
        FRAMEWORK_DIR="$sbx/framework"
        WORKING_DIR="$sbx/working"
        SHARED_DEV_ROOT="/Sandbox/Shared"
        ORG_NAME="SandboxOrg"
        FORCE="$force"
        DRY_RUN="$dry"
        eval "$fn_src"
        update_templates
    ) 2>&1
}

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  XACA-1120: Updating Templates phase honesty + render correctness"
echo "═══════════════════════════════════════════════════════════════════"

# ─────────────────────────────────────────────────────────────────────────────
# CASE 1 — the headline defect. No config/ targets installed (the real state of
# every consumer). The phase must NOT claim everything is up to date.
# ─────────────────────────────────────────────────────────────────────────────
test_start "no installed config targets: does NOT emit an unfalsifiable 'All templates up to date'"
_sbx="$(_next_sandbox)"; _make_sandbox "$_sbx"
_out="$(_run_update_templates current "$_sbx")"
if echo "$_out" | grep -q 'All templates up to date'; then
    test_fail "still emits the unconditional success line: $_out"
elif echo "$_out" | grep -q 'no installed counterpart'; then
    test_pass
else
    test_fail "expected an explicit 'no installed counterpart' report, got: $_out"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 2 — NEGATIVE CONTROL for case 1. Prove the pre-fix function really did
# emit the unfalsifiable line in this exact sandbox.
# ─────────────────────────────────────────────────────────────────────────────
test_start "NEGATIVE CONTROL: pre-fix update_templates emits 'All templates up to date' with zero targets"
if [ "$_PRE_FIX_AVAILABLE" != true ]; then
    test_skip "pre-fix revision unavailable (shallow clone?)"
else
    _sbx="$(_next_sandbox)"; _make_sandbox "$_sbx"
    _out_old="$(_run_update_templates old "$_sbx")"
    if echo "$_out_old" | grep -q 'All templates up to date'; then
        test_pass
    else
        test_fail "negative control did not reproduce the defect - the case-1 assertion proves nothing. Got: $_out_old"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 3 — an installed target that already matches must be reported as
# current, and must NOT be rewritten.
# ─────────────────────────────────────────────────────────────────────────────
test_start "installed target already current: reported as current, file untouched"
_sbx="$(_next_sandbox)"; _make_sandbox "$_sbx"
mkdir -p "$_sbx/working/config"
sed -e "s|{{AITEAMFORGE_DIR}}|$_sbx/working|g" \
    -e "s|{{SHARED_DEV_ROOT}}|/Sandbox/Shared|g" \
    -e "s|{{ORG_NAME}}|SandboxOrg|g" \
    "$_sbx/framework/share/templates/demo.conf.template" > "$_sbx/working/config/demo.conf"
_before="$(cksum < "$_sbx/working/config/demo.conf")"
_out="$(_run_update_templates current "$_sbx")"
_after="$(cksum < "$_sbx/working/config/demo.conf")"
if [ "$_before" != "$_after" ]; then
    test_fail "an already-current file was rewritten"
elif echo "$_out" | grep -q 'already current'; then
    test_pass
else
    test_fail "expected an 'already current' report, got: $_out"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 4 — a stale installed target must be updated AND fully rendered. This is
# the raw-`cp` landmine: no {{PLACEHOLDER}} may survive into the target.
# ─────────────────────────────────────────────────────────────────────────────
test_start "stale installed target: updated, and placeholders are SUBSTITUTED not copied literally"
_sbx="$(_next_sandbox)"; _make_sandbox "$_sbx"
mkdir -p "$_sbx/working/config"
printf '# stale\naiteamforge_dir=/old\nshared_dev_root=/old\norg_name=old\n' > "$_sbx/working/config/demo.conf"
_out="$(_run_update_templates current "$_sbx")"
if grep -q '{{' "$_sbx/working/config/demo.conf"; then
    test_fail "unsubstituted placeholder survived into the installed file: $(grep '{{' "$_sbx/working/config/demo.conf")"
elif grep -q "aiteamforge_dir=$_sbx/working" "$_sbx/working/config/demo.conf" \
     && grep -q 'org_name=SandboxOrg' "$_sbx/working/config/demo.conf"; then
    test_pass
else
    test_fail "target not correctly rendered. Content: $(cat "$_sbx/working/config/demo.conf")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 5 — NEGATIVE CONTROL for case 4. The pre-fix raw `cp` must leave literal
# placeholders behind, proving case 4 tests a real change.
# ─────────────────────────────────────────────────────────────────────────────
test_start "NEGATIVE CONTROL: pre-fix update_templates copies placeholders literally"
if [ "$_PRE_FIX_AVAILABLE" != true ]; then
    test_skip "pre-fix revision unavailable (shallow clone?)"
else
    _sbx="$(_next_sandbox)"; _make_sandbox "$_sbx"
    mkdir -p "$_sbx/working/config"
    printf '# stale\n' > "$_sbx/working/config/demo.conf"
    # Pre-fix used an mtime test, so make the template unambiguously newer.
    touch "$_sbx/working/config/demo.conf"
    sleep 1
    touch "$_sbx/framework/share/templates/demo.conf.template"
    _run_update_templates old "$_sbx" >/dev/null 2>&1
    if grep -q '{{AITEAMFORGE_DIR}}' "$_sbx/working/config/demo.conf" 2>/dev/null; then
        test_pass
    else
        test_fail "negative control did not reproduce the literal-placeholder copy - case 4 proves nothing. Content: $(cat "$_sbx/working/config/demo.conf" 2>/dev/null)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 6 — the anti-misdiagnosis guard. The phase must state, in operator-
# visible output, that it does not cover kanban-helpers.sh. This is the line
# whose absence cost a CRITICAL ticket filed against the wrong function.
# ─────────────────────────────────────────────────────────────────────────────
test_start "phase output disclaims kanban-helpers.sh scope (anti-misdiagnosis guard)"
_sbx="$(_next_sandbox)"; _make_sandbox "$_sbx"
_out="$(_run_update_templates current "$_sbx")"
if echo "$_out" | grep -q 'kanban-helpers.sh'; then
    test_pass
else
    test_fail "phase output never mentions kanban-helpers.sh scope. Got: $_out"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 7 — structural proof that update_templates cannot render
# kanban-helpers.sh: the shipped template's name does not match the glob the
# function uses. Asserted against the REAL tap tree, not a fixture.
# ─────────────────────────────────────────────────────────────────────────────
test_start "structural: kanban-helpers.template.sh does not match update_templates' '*.template' glob"
_matched="$(find "$TAP_ROOT/share/templates" -name '*.template' 2>/dev/null | grep -c 'kanban-helpers' || true)"
if [ "${_matched:-0}" -eq 0 ]; then
    test_pass
else
    test_fail "kanban-helpers template unexpectedly matches the glob ($_matched hit(s)) - the scope note in update_templates is now wrong"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 8 — subitem -006: after update_shell_helpers renders kanban-helpers.sh,
# the installed file's kb-* function inventory must match the shipped template.
# ─────────────────────────────────────────────────────────────────────────────
_count_kb_fns() { grep -cE '^kb-[A-Za-z0-9_-]+\(\)' "$1" 2>/dev/null || echo 0; }

_run_update_shell_helpers() {
    local sbx="$1"
    local fn_src
    fn_src="$(_extract_fn_from_file "$UPGRADE_SH" "update_shell_helpers")"
    if [ -z "$fn_src" ]; then
        echo "EXTRACT_FAILED: update_shell_helpers" >&2
        return 2
    fi
    (
        print_section() { echo "== $* =="; }
        print_info()    { echo "INFO: $*"; }
        print_success() { echo "OK: $*"; }
        print_warning() { echo "WARN: $*"; }
        FRAMEWORK_DIR="$sbx/framework"
        WORKING_DIR="$sbx/working"
        SHARED_DEV_ROOT="/Sandbox/Shared"
        ORG_NAME="SandboxOrg"
        FORCE=false
        DRY_RUN=false
        eval "$fn_src"
        update_shell_helpers
    ) 2>&1
}

_make_helpers_sandbox() {
    local sbx="$1"
    mkdir -p "$sbx/framework/share/templates/kanban"
    mkdir -p "$sbx/framework/share/templates/aliases"
    mkdir -p "$sbx/working"
    cp "$REAL_TEMPLATE" "$sbx/framework/share/templates/kanban/kanban-helpers.template.sh"
    cp "$REAL_ALIASES"  "$sbx/framework/share/templates/aliases/kanban-aliases.sh"
}

test_start "kb-* inventory of the rendered helper matches the shipped template"
_sbx="$(_next_sandbox)"; _make_helpers_sandbox "$_sbx"
# Start from a deliberately stale render (the tiny aliases file) to force work.
cp "$REAL_ALIASES" "$_sbx/working/kanban-helpers.sh"
_run_update_shell_helpers "$_sbx" >/dev/null 2>&1
_tpl_n="$(_count_kb_fns "$_sbx/framework/share/templates/kanban/kanban-helpers.template.sh")"
_got_n="$(_count_kb_fns "$_sbx/working/kanban-helpers.sh")"
if [ "${_tpl_n:-0}" -lt 20 ]; then
    test_fail "fixture sanity failed: shipped template reports only ${_tpl_n} kb-* functions"
elif [ "$_tpl_n" = "$_got_n" ]; then
    test_pass
else
    test_fail "rendered helper has ${_got_n} kb-* functions, shipped template has ${_tpl_n}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 9 — NEGATIVE CONTROL for case 8: if the render is skipped, the inventory
# must NOT match. Proves case 8 can actually fail.
# ─────────────────────────────────────────────────────────────────────────────
test_start "NEGATIVE CONTROL: a skipped render leaves the kb-* inventory mismatched"
_sbx="$(_next_sandbox)"; _make_helpers_sandbox "$_sbx"
cp "$REAL_ALIASES" "$_sbx/working/kanban-helpers.sh"
# Do NOT run the render.
_tpl_n="$(_count_kb_fns "$_sbx/framework/share/templates/kanban/kanban-helpers.template.sh")"
_got_n="$(_count_kb_fns "$_sbx/working/kanban-helpers.sh")"
if [ "$_tpl_n" != "$_got_n" ]; then
    test_pass
else
    test_fail "aliases and template have the same kb-* count (${_tpl_n}) - case 8 cannot distinguish rendered from skipped"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 10 — the second silence. A verified no-op render must SAY SO, so an
# operator can tell "rendered, identical" from "never ran".
# ─────────────────────────────────────────────────────────────────────────────
test_start "no-op kanban-helpers.sh render is reported, not silent"
_sbx="$(_next_sandbox)"; _make_helpers_sandbox "$_sbx"
cp "$REAL_ALIASES" "$_sbx/working/kanban-helpers.sh"
_run_update_shell_helpers "$_sbx" >/dev/null 2>&1   # first pass renders
_out="$(_run_update_shell_helpers "$_sbx")"          # second pass is a no-op
if echo "$_out" | grep -q 'kanban-helpers.sh already current'; then
    test_pass
else
    test_fail "a verified no-op render printed no attribution line. Got: $_out"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone only).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "───────────────────────────────────────────────────────────────────"
    echo "  XACA-1120: PASS=$_PASS_COUNT FAIL=$_FAIL_COUNT SKIP=$_SKIP_COUNT"
    echo "───────────────────────────────────────────────────────────────────"
    [ "$_FAIL_COUNT" -eq 0 ] || exit 1
fi
exit 0
