#!/usr/bin/env bash
# test-xaca-1028-ttyd-template-resolver.sh
#
# XACA-1028: kb-ttyd-bridge.sh's _resolve_template() missed on every tap
# install, so update_ttyd_bridge failed, and because `aiteamforge upgrade` runs
# under `set -eo pipefail` that abort killed the SIX phases after it —
# update_imgcat, update_shell_helpers, update_team_personas, update_claude_hooks,
# update_skills, update_launchagents — plus "Upgrade Complete". Measured on both
# live consumers 2026-09-06: .installed-version sat at 0.20.0 while brew had
# advanced to 0.20.5, and kanban-helpers.sh was missing 46 kb-* commands.
#
# The defect: on a tap install _KB_TTYD_SELF_DIR is <libexec>/share/scripts, so
# the candidate "${SELF}/../share/templates/terminal-bridge/..." resolves to
# <libexec>/share/share/templates/ — the "double-share" miss. The real location
# is <libexec>/share/templates/terminal-bridge/, i.e. "${SELF}/../templates/...".
#
# NEGATIVE CONTROL NOTE (XACA-1095 lesson): the pre-fix behaviour is reproduced
# by stripping the new candidate line out of a COPY of the script at run time,
# NOT by extracting an older revision from git. A git-history-based control goes
# permanently inert the moment the fix is committed, and inert again in CI where
# actions/checkout uses a depth-1 shallow clone. This control runs everywhere,
# forever.

# NOTE: deliberately NOT `set -u`. test-runner.sh exports its own test_start/
# test_pass/test_fail into this child process, and those reference runner
# internals (TOTAL_TESTS et al) that are NOT exported alongside them. Under
# `set -u` the first test_start dies with "TOTAL_TESTS: unbound variable",
# the file aborts before recording anything, and the runner reports
# "Total Tests: 0" — passing standalone while failing in CI. Matches the
# house convention (14 of 30 tests use exactly this).
set -o pipefail

_STANDALONE=false
_PASS=0
_FAIL=0
_FAIL_AT_START=0
_CURRENT_TEST=""

if ! declare -F test_start &>/dev/null; then
    _STANDALONE=true
    test_start() { _CURRENT_TEST="$1"; printf "TEST: %s\n" "$1"; }
    test_pass()  { _PASS=$((_PASS + 1)); printf "  PASS: %s\n" "$_CURRENT_TEST"; }
    test_fail()  { _FAIL=$((_FAIL + 1)); printf "  FAIL: %s — %s\n" "$_CURRENT_TEST" "${1:-}" >&2; }
fi

# Case-level gating that works under BOTH the local shim and test-runner.sh's
# exported harness (XACA-1095): assert_* record only on FAILURE, so an
# unconditional trailing test_pass would make a failing case report a PASS too
# and leave the pass total unable to move.
_LOCAL_FAILS=0
_LOCAL_FAILS_AT_START=0
_t_start() { _LOCAL_FAILS_AT_START="$_LOCAL_FAILS"; test_start "$@"; }
_t_fail()  { _LOCAL_FAILS=$((_LOCAL_FAILS + 1)); test_fail "$@"; }
_t_pass()  {
    # MUST call test_pass (the harness function), never _t_pass — a mechanical
    # call-site rewrite once matched this line and made the function recurse
    # into itself (SIGSEGV, exit 139, every run).
    if [ "$_LOCAL_FAILS" -ne "$_LOCAL_FAILS_AT_START" ]; then return 0; fi
    test_pass
}

_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_TAP_ROOT="$(cd "$_TEST_DIR/.." && pwd)"
SCRIPT="$_TAP_ROOT/share/scripts/kb-ttyd-bridge.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "FATAL: kb-ttyd-bridge.sh not found at: $SCRIPT" >&2
    exit 1
fi

_OWN_TMP=false
if [ -z "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/xaca1028-XXXXXX")"
    _OWN_TMP=true
fi
WORK_ROOT="$(mktemp -d "$TEST_TMP_DIR/xaca1028-XXXXXX")"
PLIST_NAME="ttyd-bridge-launchagent.template.plist"

# Evaluate ONLY _resolve_template from a given script copy, with a controlled
# self-dir and environment. Echoes the resolved path, or nothing on failure.
_probe() {
    local script="$1" self_dir="$2" override="${3:-}" atf_dir="${4:-/nonexistent-atf}"
    /bin/bash -c '
        _KB_TTYD_SELF_DIR="$1"
        KB_TTYD_TEMPLATE="$2"
        AITEAMFORGE_DIR="$3"
        eval "$(awk "/^_resolve_template\(\)/,/^}/" "$4")"
        _resolve_template 2>/dev/null || true
    ' _ "$self_dir" "$override" "$atf_dir" "$script"
}

# ─── Fixtures ────────────────────────────────────────────────────────────────
# Tap layout: script under <root>/share/scripts, template under <root>/share/templates
TAP_FX="$WORK_ROOT/tap"
mkdir -p "$TAP_FX/share/scripts" "$TAP_FX/share/templates/terminal-bridge"
printf '<plist>tap-fixture</plist>\n' > "$TAP_FX/share/templates/terminal-bridge/$PLIST_NAME"

# Dev layout: script under <repo>/scripts, template under <repo>/scripts/templates
DEV_FX="$WORK_ROOT/dev"
mkdir -p "$DEV_FX/scripts/templates"
printf '<plist>dev-fixture</plist>\n' > "$DEV_FX/scripts/templates/$PLIST_NAME"

# Empty layout: nothing anywhere
EMPTY_FX="$WORK_ROOT/empty"
mkdir -p "$EMPTY_FX/share/scripts"

# Pre-fix copy: the shipped script with the XACA-1028 candidate removed.
PREFIX_SCRIPT="$WORK_ROOT/kb-ttyd-bridge.prefix.sh"
grep -v '/\.\./templates/terminal-bridge/' "$SCRIPT" > "$PREFIX_SCRIPT"

# ─── Cases ───────────────────────────────────────────────────────────────────

_t_start "T1: tap layout resolves (the XACA-1028 fix)"
_R1="$(_probe "$SCRIPT" "$TAP_FX/share/scripts")"
if [ -z "$_R1" ]; then
    _t_fail "tap layout did not resolve — the consumer-install case is still broken"
elif [ ! -f "$_R1" ]; then
    _t_fail "resolver returned a path that does not exist: $_R1"
else
    _t_pass
fi

_t_start "T2 (negative control): the SAME tap fixture FAILS without the new candidate"
_R2="$(_probe "$PREFIX_SCRIPT" "$TAP_FX/share/scripts")"
if [ -n "$_R2" ]; then
    _t_fail "pre-fix script resolved '$_R2' — the control does not discriminate, so T1 proves nothing"
else
    _t_pass
fi

_t_start "T3: dev layout still resolves (no regression to the canonical repo)"
_R3="$(_probe "$SCRIPT" "$DEV_FX/scripts")"
if [ -z "$_R3" ] || [ ! -f "$_R3" ]; then
    _t_fail "dev layout stopped resolving — regression"
else
    _t_pass
fi

_t_start "T4: explicit KB_TTYD_TEMPLATE override still wins over discovery"
printf '<plist>override</plist>\n' > "$WORK_ROOT/explicit.plist"
_R4="$(_probe "$SCRIPT" "$EMPTY_FX/share/scripts" "$WORK_ROOT/explicit.plist")"
if [ "$_R4" != "$WORK_ROOT/explicit.plist" ]; then
    _t_fail "override ignored; got '${_R4:-<empty>}'"
else
    _t_pass
fi

_t_start "T5: all candidates missing still fails closed (no phantom path)"
_R5="$(_probe "$SCRIPT" "$EMPTY_FX/share/scripts")"
if [ -n "$_R5" ]; then
    _t_fail "resolver invented a path with nothing on disk: $_R5"
else
    _t_pass
fi

_t_start "T6: the \$AITEAMFORGE_DIR/share/templates candidate resolves when that exact shape exists"
# NOTE (review finding): this exercises candidate 4 as WRITTEN. It is not the
# layout `aiteamforge setup` actually produces — setup copies
# share/templates -> $INSTALL_DIR/templates (no intermediate share/), which is
# what T7-T9 below cover. Kept because candidate 4 is real code that should
# behave predictably, but it is NOT evidence about the field.
ATF_FX="$WORK_ROOT/atf"
mkdir -p "$ATF_FX/share/templates/terminal-bridge"
printf '<plist>atf-fixture</plist>\n' > "$ATF_FX/share/templates/terminal-bridge/$PLIST_NAME"
_R6="$(_probe "$SCRIPT" "$EMPTY_FX/share/scripts" "" "$ATF_FX")"
if [ -z "$_R6" ] || [ ! -f "$_R6" ]; then
    _t_fail "working-dir candidate did not resolve even when the template is present"
else
    _t_pass
fi

# ─── The FIELD layout (XACA-1028 round 2) ────────────────────────────────────
# update_ttyd_bridge invokes ${WORKING_DIR}/scripts/kb-ttyd-bridge.sh, so the
# resolver's self-dir is ~/aiteamforge/scripts and the template must live at
# ~/aiteamforge/templates/terminal-bridge/. Measured on both consumers
# 2026-09-06: templates/ exists (aliases, claude, fleet-monitor, kanban,
# migration) but terminal-bridge is ABSENT, because `aiteamforge setup` seeds
# that tree once and upgrade never refreshes it.
#
# T1 above uses a Cellar-shaped fixture; it is NOT the field case. These three
# are. Written after a review round proved the resolver fix alone still failed
# closed on a real consumer.
UPG_SH="$_TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
FIELD_FW="$WORK_ROOT/field-fw"
FIELD_WD="$WORK_ROOT/field-wd"
mkdir -p "$FIELD_FW/share/templates/terminal-bridge" \
         "$FIELD_WD/scripts" "$FIELD_WD/templates/kanban" "$FIELD_WD/templates/aliases"
printf '<plist>field</plist>\n' > "$FIELD_FW/share/templates/terminal-bridge/$PLIST_NAME"
cp "$SCRIPT" "$FIELD_WD/scripts/kb-ttyd-bridge.sh"

_field_resolve() { _probe "$FIELD_WD/scripts/kb-ttyd-bridge.sh" "$FIELD_WD/scripts" "" "$FIELD_WD"; }

_t_start "T7 (field, pre-state): working-dir layout WITHOUT templates/terminal-bridge fails closed"
_R7="$(_field_resolve)"
if [ -n "$_R7" ]; then
    _t_fail "resolved '$_R7' with no terminal-bridge on disk — fixture does not reproduce the consumer state"
else
    _t_pass
fi

_t_start "T8: update_template_dirs materializes the missing template directory"
/bin/bash -c '
    set -eo pipefail
    print_section(){ :; }; print_info(){ :; }; print_success(){ :; }; print_warning(){ :; }
    DRY_RUN=false; FRAMEWORK_DIR="$1"; WORKING_DIR="$2"
    eval "$(awk "/^_xaca1028_mandatory_template_dirs\(\)/,/^}/" "$3")"
    eval "$(awk "/^update_template_dirs\(\)/,/^}/" "$3")"
    update_template_dirs
' _ "$FIELD_FW" "$FIELD_WD" "$UPG_SH" >/dev/null 2>&1
if [ ! -f "$FIELD_WD/templates/terminal-bridge/$PLIST_NAME" ]; then
    _t_fail "update_template_dirs did not create templates/terminal-bridge/$PLIST_NAME"
else
    _t_pass
fi

_t_start "T9 (field, post-state): the SAME layout now resolves — the two halves together fix it"
_R9="$(_field_resolve)"
if [ -z "$_R9" ] || [ ! -f "$_R9" ]; then
    _t_fail "still fails after materialization — resolver and materializer disagree on the path"
else
    _t_pass
fi

_t_start "T10: a local file NOT shipped in the source survives a refresh"
printf 'local-edit\n' > "$FIELD_WD/templates/terminal-bridge/LOCAL_MARKER"
/bin/bash -c '
    set -eo pipefail
    print_section(){ :; }; print_info(){ :; }; print_success(){ :; }; print_warning(){ :; }
    DRY_RUN=false; FRAMEWORK_DIR="$1"; WORKING_DIR="$2"
    eval "$(awk "/^_xaca1028_mandatory_template_dirs\(\)/,/^}/" "$3")"
    eval "$(awk "/^update_template_dirs\(\)/,/^}/" "$3")"
    update_template_dirs
' _ "$FIELD_FW" "$FIELD_WD" "$UPG_SH" >/dev/null 2>&1
if [ ! -f "$FIELD_WD/templates/terminal-bridge/LOCAL_MARKER" ]; then
    _t_fail "a second run clobbered an existing template directory — local edits are not safe"
else
    _t_pass
fi

# ─── Refresh semantics (XACA-1028 round 3) ───────────────────────────────────
# Review finding, correct: the XACA-0673 convention that update_runtime_helpers
# follows is "refresh every existing target AND materialise the mandatory ones
# when absent" — NOT create-once-never-touch. An absent-only directory copy
# would mean a future content fix to a shipped template never reaches a consumer
# that already has the directory: a narrower instance of the very staleness bug
# this ticket fixes. Both gates also flagged that an existence-only check cannot
# self-heal a partial copy. Per-file, content-compared refresh fixes both.

_run_materializer() {
    /bin/bash -c '
        set -eo pipefail
        print_section(){ :; }; print_info(){ :; }; print_success(){ :; }; print_warning(){ :; }
        DRY_RUN=false; FRAMEWORK_DIR="$1"; WORKING_DIR="$2"
        eval "$(awk "/^_xaca1028_mandatory_template_dirs\(\)/,/^}/" "$3")"
        eval "$(awk "/^update_template_dirs\(\)/,/^}/" "$3")"
        update_template_dirs
    ' _ "$1" "$2" "$UPG_SH" >/dev/null 2>&1
}

_t_start "T11: a CHANGED shipped template is refreshed onto a consumer that already has it"
printf '<plist>v2-corrected</plist>\n' > "$FIELD_FW/share/templates/terminal-bridge/$PLIST_NAME"
_run_materializer "$FIELD_FW" "$FIELD_WD"
if ! grep -q 'v2-corrected' "$FIELD_WD/templates/terminal-bridge/$PLIST_NAME" 2>/dev/null; then
    _t_fail "content fix did not reach the installed copy — absent-only staleness has returned"
else
    _t_pass
fi

_t_start "T12: a partially-copied directory self-heals (missing file restored on the next run)"
rm -f "$FIELD_WD/templates/terminal-bridge/$PLIST_NAME"
if [ ! -d "$FIELD_WD/templates/terminal-bridge" ]; then
    _t_fail "fixture error: directory should still exist for this case to mean anything"
else
    _run_materializer "$FIELD_FW" "$FIELD_WD"
    if [ ! -f "$FIELD_WD/templates/terminal-bridge/$PLIST_NAME" ]; then
        _t_fail "a half-populated directory was treated as done — it can never self-heal"
    else
        _t_pass
    fi
fi

_t_start "T13: an up-to-date tree is a genuine no-op (idempotent, no needless rewrite)"
_T13_BEFORE="$(shasum -a 256 "$FIELD_WD/templates/terminal-bridge/$PLIST_NAME" | cut -d" " -f1)"
_run_materializer "$FIELD_FW" "$FIELD_WD"
_T13_AFTER="$(shasum -a 256 "$FIELD_WD/templates/terminal-bridge/$PLIST_NAME" | cut -d" " -f1)"
if [ "$_T13_BEFORE" != "$_T13_AFTER" ]; then
    _t_fail "content changed on a no-op run"
else
    _t_pass
fi

if [ "$_OWN_TMP" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
    rm -rf "$TEST_TMP_DIR"
fi

if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "──────────────────────────────────────────────"
    echo "  ttyd template resolver test:  PASS=$_PASS  FAIL=$_FAIL"
    echo "──────────────────────────────────────────────"
    [ "$_FAIL" -eq 0 ] || exit 1
fi
exit 0
