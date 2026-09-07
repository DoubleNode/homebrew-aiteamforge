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

_t_start "T6: AITEAMFORGE_DIR working-dir candidate resolves when populated"
ATF_FX="$WORK_ROOT/atf"
mkdir -p "$ATF_FX/share/templates/terminal-bridge"
printf '<plist>atf-fixture</plist>\n' > "$ATF_FX/share/templates/terminal-bridge/$PLIST_NAME"
_R6="$(_probe "$SCRIPT" "$EMPTY_FX/share/scripts" "" "$ATF_FX")"
if [ -z "$_R6" ] || [ ! -f "$_R6" ]; then
    _t_fail "working-dir candidate did not resolve even when the template is present"
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
