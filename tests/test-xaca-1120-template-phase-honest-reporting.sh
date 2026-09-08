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
#      Every one of the 17 shipped templates hit `[ ! -f "$target_file" ]` and
#      `continue`d silently, templates_updated stayed 0, and the function fell
#      through to a success line that could not fail. A check that cannot fail
#      is not a check.
#
#      PRECISION (PR #836 review corrected an earlier, sloppier claim here):
#      it is NOT true that "nothing ever creates ${WORKING_DIR}/config/".
#      install-fleet-monitor.sh does `mkdir -p "$AITEAMFORGE_DIR/config"` (:880)
#      and writes fleet-config.json (:109) and machine-identity.json (:189)
#      there, and get_working_dir() resolves to that same directory — so it
#      exists fleet-wide. The true and narrower statement is that no shipped
#      *.template BASENAME has ever had an installed counterpart in it: all 17
#      basenames were compared against that directory's two occupants and the
#      overlap is empty. Case 1 below is what actually pins the defect, and it
#      does not depend on the directory being absent.
#
#      The original claim was reached by grepping only the BRACED form
#      (`${AITEAMFORGE_DIR}/config`); the fleet installer writes the unbraced
#      `$AITEAMFORGE_DIR/config`. An audit grep that covers one quoting variant
#      returns a clean, confident, wrong answer.
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
# which is how fiction gets accepted). If that history is unavailable (a shallow
# clone), the negative controls FAIL -- they do not skip. They are the suite's
# reason to exist: without them the remaining cases assert only that the code
# does what it currently does. A run that skipped its way to zero failures has
# established nothing, so the exit gate consults the SKIP count as well as the
# FAIL count, in both standalone and runner modes.
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
    # PR #836 review: test_skip MUST be defined inside this standalone guard.
    # test-runner.sh exports its own test_skip (:456) which writes a SKIP:
    # marker to TEST_RESULTS_FILE and feeds SKIPPED_TESTS (:134, :493) --
    # machinery added by XACA-0862-031 precisely so a skipped run cannot read
    # as a covered one. Defining ours unconditionally clobbered that export, so
    # under the runner a skip left NO marker, bumped a counter that is never
    # printed (the summary is gated to _STANDALONE), and the file reported
    # passes with zero skips.
    test_skip() { _SKIP_COUNT=$((_SKIP_COUNT + 1)); echo "     SKIP: $_CURRENT_TEST - $1"; }
fi

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
# Second pre-fix revision, self-located the same way: PR #836 review round 2,
# BLOCKING FIX 1. `cmp -s` (introduced by the FIRST self-located fix above)
# made the templates-current gate go from "never fires against a git-sourced
# Cellar" to "fires on every upgrade whose installed file differs from the
# shipped template by even one byte" -- which a POPULATED secrets.env always
# does the moment a real key replaces the placeholder. The never-overwrite
# basename check is what stops that render from being installed. Anchored on
# the function definition line, which exists in NO revision before this fix.
# ─────────────────────────────────────────────────────────────────────────────
_PRE_FIX_AVAILABLE_SECRETS=false
PRE_FIX_REV_SECRETS=""
if command -v git >/dev/null 2>&1; then
    _fix_commit_secrets="$(git -C "$TAP_ROOT" log -S'_aitf_is_never_overwrite_basename() {' \
        --format='%H' -1 -- libexec/commands/aiteamforge-upgrade.sh 2>/dev/null)"
    if [ -n "$_fix_commit_secrets" ] && git -C "$TAP_ROOT" cat-file -e "${_fix_commit_secrets}^" 2>/dev/null; then
        PRE_FIX_REV_SECRETS="${_fix_commit_secrets}^"
        # Confirm the parent genuinely predates the fix: it must NOT yet
        # define the guard function. Same pipefail hazard as above -- capture
        # first, match in-shell, no pipeline.
        _parent_blob_secrets="$(git -C "$TAP_ROOT" show "${PRE_FIX_REV_SECRETS}:libexec/commands/aiteamforge-upgrade.sh" 2>/dev/null)"
        case "$_parent_blob_secrets" in
            *'_aitf_is_never_overwrite_basename() {'*) : ;;   # already present -> not pre-fix, leave false
            *) _PRE_FIX_AVAILABLE_SECRETS=true ;;
        esac
        unset _parent_blob_secrets
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
# PR #836: update_templates and update_shell_helpers now delegate
# render+validate+install to shared _aitf_* helpers defined in the same file.
# Any runner that extracts one of those functions in isolation MUST pull the
# helpers in too -- otherwise the function under test dies with
# "_aitf_render_template: command not found", which surfaces as a plausible
# "render failed / incomplete file" RESULT rather than an obvious harness
# error. That is a failure mode worth naming: the harness would be reporting a
# product defect that does not exist.
_extract_aitf_helpers() {
    local _h
    for _h in _aitf_sed_repl_escape _aitf_file_mode _aitf_render_template _aitf_install_rendered; do
        _extract_fn_from_file "$UPGRADE_SH" "$_h"
    done
    # _aitf_is_never_overwrite_basename() (PR #836 review round 2, BLOCKING fix
    # 1) reads a plain top-level variable assignment, not another function, so
    # it does not fit the function-extraction loop above. Pull the assignment
    # line verbatim, then the function. Grepped rather than hardcoded so this
    # stays byte-for-byte in sync with the shipped list instead of silently
    # drifting from it.
    grep '^_AITF_NEVER_OVERWRITE_BASENAMES=' "$UPGRADE_SH"
    _extract_fn_from_file "$UPGRADE_SH" "_aitf_is_never_overwrite_basename"
}

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
        eval "$(_extract_aitf_helpers)"
        eval "$fn_src"
        update_templates
    ) 2>&1
}

# Like _run_update_templates, but takes an explicit revision instead of
# assuming the suite's ORIGINAL self-located PRE_FIX_REV. This suite now
# self-locates TWO different fix commits (see the two self-location blocks
# above); the original runner only knew about the first one.
_run_update_templates_rev() {
    local rev="$1" sbx="$2" force="${3:-false}" dry="${4:-false}"
    local fn_src
    if [ "$rev" = "current" ]; then
        fn_src="$(_extract_fn_from_file "$UPGRADE_SH" "update_templates")"
    else
        fn_src="$(_extract_fn_from_rev "$rev" "libexec/commands/aiteamforge-upgrade.sh" "update_templates")"
    fi
    if [ -z "$fn_src" ]; then
        echo "EXTRACT_FAILED: update_templates ($rev)" >&2
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
        eval "$(_extract_aitf_helpers)"
        eval "$fn_src"
        update_templates
    ) 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox shaped like a real secrets.env deployment: a shipped
# secrets.env.template (placeholder credentials) and a POPULATED
# ${WORKING_DIR}/config/secrets.env carrying a marker that stands in for a
# real ANTHROPIC_API_KEY/GITHUB_TOKEN, at the 600 mode installers elsewhere
# deliberately create it at (install-kanban.sh:1565). The populated file's
# content is byte-for-byte DIFFERENT from the rendered template -- exactly
# the condition that flips the `cmp -s` staleness gate from "current" to
# "differs" the instant a real key replaces the placeholder.
# ─────────────────────────────────────────────────────────────────────────────
_SECRETS_LIVE_MARKER='export ANTHROPIC_API_KEY="sk-ant-LIVE-MARKER-not-a-real-key"'
_make_secrets_sandbox() {
    local sbx="$1"
    mkdir -p "$sbx/framework/share/templates"
    mkdir -p "$sbx/working/config"
    cat > "$sbx/framework/share/templates/secrets.env.template" <<'TPL'
# AITeamForge Secrets Configuration Template
export ANTHROPIC_API_KEY="your-api-key-here"
export GITHUB_TOKEN="ghp_..."
# org: {{ORG_NAME}} dir: {{AITEAMFORGE_DIR}} shared: {{SHARED_DEV_ROOT}}
TPL
    cat > "$sbx/working/config/secrets.env" <<EOF
# populated by a real operator, not the installer
${_SECRETS_LIVE_MARKER}
export GITHUB_TOKEN="ghp_ALSO_A_LIVE_MARKER"
EOF
    chmod 600 "$sbx/working/config/secrets.env"
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
    # NOT a skip (PR #836 review). These two controls are the suite's reason to
    # exist: without them the current-behaviour cases assert only that the code
    # does what it currently does. Degrading to SKIP would leave the suite
    # exiting 0 with its only real evidence silently disarmed -- a strictly
    # worse vacuous green than the pipefail bug this file already fixed once.
    # If this fires in CI the cause is a shallow checkout; deepen it
    # (fetch-depth: 0), do not tolerate the skip.
    test_fail "pre-fix revision could not be resolved, so the negative controls cannot run. This is a FAILURE, not a skip: deepen the clone (fetch-depth: 0) or repair the git log -S anchor."
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
    # NOT a skip (PR #836 review). These two controls are the suite's reason to
    # exist: without them the current-behaviour cases assert only that the code
    # does what it currently does. Degrading to SKIP would leave the suite
    # exiting 0 with its only real evidence silently disarmed -- a strictly
    # worse vacuous green than the pipefail bug this file already fixed once.
    # If this fires in CI the cause is a shallow checkout; deepen it
    # (fetch-depth: 0), do not tolerate the skip.
    test_fail "pre-fix revision could not be resolved, so the negative controls cannot run. This is a FAILURE, not a skip: deepen the clone (fetch-depth: 0) or repair the git log -S anchor."
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
# CASE 5b — mode preservation on a CREDENTIALS-shaped target (PR #836 review).
# The install is `mv`, which replaces the inode, so the installed mode is the
# temp's. mktemp creates at 0600 and an explicit `chmod 644` would have silently
# widened a rendered secrets file — which is a real target here: the shipped
# secrets template renders an ANTHROPIC_API_KEY and a GitHub PAT slot, and
# installers elsewhere deliberately create such files at 600.
# ─────────────────────────────────────────────────────────────────────────────
# Read permission bits as octal, portably -- and validate the OUTPUT rather than
# trusting an exit status to tell the two `stat` implementations apart.
#
# `stat -f '%Lp' f || stat -c '%a' f` is WRONG on GNU: coreutils `stat -f` is a
# valid flag meaning "display filesystem status", so on Linux it exits 0 and
# prints a multi-line filesystem block (Namelen, Block size, Inodes). The `||`
# never fires and the caller gets that block where it expected "600". This
# helper had that bug and so did the code under test; CI on ubuntu-latest caught
# both, having passed cleanly on macOS where `stat -f` happens to mean the
# intended thing. A fallback chain that discriminates on exit status only works
# when the wrong tool actually fails.
_mode_of() {
    local m=""
    m="$(stat -c '%a' "$1" 2>/dev/null)"        # GNU coreutils
    case "$m" in ''|*[!0-7]*) m="" ;; esac
    if [ -z "$m" ]; then
        m="$(stat -f '%Lp' "$1" 2>/dev/null)"   # BSD / macOS
        case "$m" in ''|*[!0-7]*) m="" ;; esac
    fi
    printf '%s' "$m"
}

test_start "a 600 (credentials) target keeps mode 600 across an update"
_sbx="$(_next_sandbox)"; _make_sandbox "$_sbx"
mkdir -p "$_sbx/working/config"
printf '# stale\n' > "$_sbx/working/config/demo.conf"
chmod 600 "$_sbx/working/config/demo.conf"
_run_update_templates current "$_sbx" >/dev/null 2>&1
_m="$(_mode_of "$_sbx/working/config/demo.conf")"
if [ "$_m" = "600" ]; then
    test_pass
else
    test_fail "mode widened from 600 to ${_m} — a rendered credentials file would be exposed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 5c — the other half: 13 of the 17 shipped targets are *.sh, so a flat
# 644 would strip the exec bit instead of widening.
# ─────────────────────────────────────────────────────────────────────────────
test_start "a 755 (executable) target keeps mode 755 across an update"
_sbx="$(_next_sandbox)"; _make_sandbox "$_sbx"
mkdir -p "$_sbx/working/config"
printf '# stale\n' > "$_sbx/working/config/demo.conf"
chmod 755 "$_sbx/working/config/demo.conf"
_run_update_templates current "$_sbx" >/dev/null 2>&1
_m="$(_mode_of "$_sbx/working/config/demo.conf")"
if [ "$_m" = "755" ]; then
    test_pass
else
    test_fail "exec bit lost: mode became ${_m}, expected 755"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 5d — direct guard on the portability helper itself. 5b/5c catch a broken
# mode end-to-end, but they cannot say WHY; this one localises the failure to
# `_aitf_file_mode` returning something that is not an octal mode. It exists
# because the first version of that helper used `stat -f` first, which is a
# valid-but-unrelated GNU flag that exits 0 with filesystem information.
# ─────────────────────────────────────────────────────────────────────────────
test_start "_aitf_file_mode returns a plain octal mode on this platform"
_probe="$WORK_DIR/mode-probe"
printf 'x\n' > "$_probe"
chmod 640 "$_probe"
_got="$(
    eval "$(_extract_aitf_helpers)"
    _aitf_file_mode "$_probe"
)"
if [ "$_got" = "640" ]; then
    test_pass
else
    test_fail "expected '640', got '$_got' — on GNU coreutils this is what a 'stat -f' first fallback chain returns (filesystem status, exit 0), which then silently degrades the install to a default mode"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 5e — BLOCKING FIX 1 (PR #836 review round 2). A populated secrets.env
# must survive update_templates with its content AND mode intact — not because
# it happens to compare "current" (round 1 already covers that), but because
# it is on the never-overwrite basename list and is refused BEFORE the
# render/compare/backup machinery ever touches it. This sandbox's secrets.env
# is deliberately NOT byte-identical to the rendered template (a live key
# replacing a placeholder never is), which is exactly the case round 1's
# `cmp -s` gate cannot protect on its own.
# ─────────────────────────────────────────────────────────────────────────────
test_start "a populated secrets.env survives update_templates with content and mode 600 intact"
_sbx="$(_next_sandbox)"; _make_secrets_sandbox "$_sbx"
_before_content="$(cat "$_sbx/working/config/secrets.env")"
_out="$(_run_update_templates_rev current "$_sbx")"
_after_content="$(cat "$_sbx/working/config/secrets.env")"
_after_mode="$(_mode_of "$_sbx/working/config/secrets.env")"
if [ "$_after_content" != "$_before_content" ]; then
    test_fail "secrets.env content changed — a live credentials file was overwritten by the shipped template. Output: $_out"
elif [ "$_after_mode" != "600" ]; then
    test_fail "secrets.env mode changed from 600 to ${_after_mode}"
elif ! echo "$_out" | grep -qi 'secrets.env'; then
    test_fail "the skip was silent — no mention of secrets.env in the phase output: $_out"
else
    test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 5f — the protection is NOT an artifact of the ordinary staleness gate,
# and --force must not bypass it either (the ticket's stated worry is the
# UNATTENDED nightly auto-upgrade, which many fleets run with --force).
# ─────────────────────────────────────────────────────────────────────────────
test_start "secrets.env is never overwritten even under --force"
_sbx="$(_next_sandbox)"; _make_secrets_sandbox "$_sbx"
_before_content="$(cat "$_sbx/working/config/secrets.env")"
_run_update_templates_rev current "$_sbx" true >/dev/null 2>&1
_after_content="$(cat "$_sbx/working/config/secrets.env")"
if [ "$_after_content" = "$_before_content" ]; then
    test_pass
else
    test_fail "--force overwrote a live secrets.env — the never-overwrite list must apply regardless of FORCE"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 5g — NEGATIVE CONTROL for 5e/5f. Prove the pre-fix update_templates
# (round 1's `cmp -s` gate, WITHOUT the never-overwrite basename check) really
# would install the rendered template over this exact populated secrets.env —
# i.e. that BLOCKING FIX 1 closes a real hole, not a hypothetical one.
# ─────────────────────────────────────────────────────────────────────────────
test_start "NEGATIVE CONTROL: pre-fix update_templates overwrites a populated secrets.env"
if [ "$_PRE_FIX_AVAILABLE_SECRETS" != true ]; then
    # NOT a skip — same reasoning as the suite's other negative controls (see
    # header comment). A SKIP here would let this file report all-green while
    # its most consequential assertion never ran.
    test_fail "pre-fix revision for BLOCKING FIX 1 could not be resolved, so this negative control cannot run. This is a FAILURE, not a skip: deepen the clone (fetch-depth: 0) or repair the git log -S anchor ('_aitf_is_never_overwrite_basename() {')."
else
    _sbx="$(_next_sandbox)"; _make_secrets_sandbox "$_sbx"
    _before_content="$(cat "$_sbx/working/config/secrets.env")"
    _out_old="$(_run_update_templates_rev "$PRE_FIX_REV_SECRETS" "$_sbx")"
    _after_content="$(cat "$_sbx/working/config/secrets.env")"
    if [ "$_after_content" != "$_before_content" ] && ! echo "$_after_content" | grep -q "$_SECRETS_LIVE_MARKER"; then
        test_pass
    else
        test_fail "pre-fix update_templates left secrets.env unchanged in this sandbox — the negative control does not reproduce the vulnerability it exists to prove. Output: $_out_old"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# CASE 5h — BLOCKING FIX 2 (PR #836 review round 2). A "preserve" install
# request that cannot read the target's current mode must fail CLOSED, not
# fall back to a guessed 644. Exercised directly on _aitf_install_rendered()
# rather than through update_templates(), because the easiest way to make
# _aitf_file_mode() legitimately return empty is a target that does not exist
# at all -- no root/chmod tricks required, and it is the same code path a
# real unreadable-mode failure would take. On refusal the temp render must be
# left alone (never consumed) and the target must remain absent, not created
# at a guessed mode.
# ─────────────────────────────────────────────────────────────────────────────
test_start "_aitf_install_rendered fails closed when the target's mode cannot be read"
_tmp="$WORK_DIR/install-rendered-probe.tmp"
printf 'rendered content\n' > "$_tmp"
_missing_target="$WORK_DIR/does-not-exist/secrets.env"
_rc=0
(
    eval "$(_extract_aitf_helpers)"
    _aitf_install_rendered "$_tmp" "$_missing_target" preserve
) >/dev/null 2>&1 || _rc=$?
if [ "$_rc" -ne 2 ]; then
    test_fail "expected return code 2 (refuse to install), got ${_rc}"
elif [ -e "$_missing_target" ]; then
    test_fail "target was created despite the mode being unreadable — fail-closed did not hold"
elif [ ! -f "$_tmp" ]; then
    test_fail "the temp render was consumed/removed on a refused install — caller can no longer distinguish this from a successful rename"
else
    test_pass
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
        eval "$(_extract_aitf_helpers)"
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
fi
# A SKIP is not a PASS (PR #836 review). This gate consults BOTH local
# counters, but that only has teeth in STANDALONE mode: a suite that skipped
# its way to zero failures has not established anything, and the previous
# gate (_FAIL_COUNT only) would have exited 0 for it.
#
# Corrected claim (subitem XACA-1120-032, PR #836 review round 2): this is
# NOT true "in both standalone and runner modes" as an earlier version of
# this comment claimed. Under the runner, test_start/test_pass/test_fail/
# test_skip are the RUNNER's exported functions (test-runner.sh:456), not the
# local wrappers defined a few lines above inside the `_STANDALONE` guard --
# and that guard is precisely what round 1 fixed (this file must NOT
# redefine test_skip when the runner already exported one, see the comment
# there). So under the runner, _PASS_COUNT/_FAIL_COUNT/_SKIP_COUNT are never
# touched by anything in this file and stay at 0 structurally, and this exit
# gate always falls through to `exit 0` for THIS subprocess. That is not a
# gap: the runner does its own, separate accounting by grepping SKIP:/FAIL:
# markers out of TEST_RESULTS_FILE (test-runner.sh run_test_file, ~:465-475)
# -- written by its own exported test_fail/test_skip -- and that is the
# authoritative count the runner acts on. This gate is kept outside the
# _STANDALONE guard only so a standalone invocation's exit code is correct;
# under the runner it is inert by construction, not a redundant second check.
if [ "$_FAIL_COUNT" -ne 0 ] || [ "$_SKIP_COUNT" -ne 0 ]; then
    exit 1
fi
exit 0
