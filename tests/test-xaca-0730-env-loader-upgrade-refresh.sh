#!/bin/bash
# test-xaca-0730-env-loader-upgrade-refresh.sh
#
# XACA-0730: `aiteamforge upgrade` never rendered/refreshed
# $AITEAMFORGE_DIR/share/aiteamforge-env.sh. Only install_env_loader()
# (install-shell.sh, reached from `aiteamforge setup`) wrote it, so M1Pro kept
# a May-dated copy WITHOUT the XACA-0494 worktree-helpers sourcing block
# through ~10 upgrades. The fix is update_env_loader() in
# aiteamforge-upgrade.sh, rendering through the SAME shared renderer
# (lib/env-loader.sh, aitf_render_env_loader) that install_env_loader uses.
#
# The defect is "file exists but is stale", so every acceptance check below
# DIFFS the installed file against an independently rendered template. An
# existence check would have passed on M1Pro the whole time.
#
# Checks:
#   S1  update_env_loader is invoked (bare line) in the upgrade run sequence
#   S2  update_env_loader and install_env_loader both call the shared renderer,
#       and neither carries its own {{AITEAMFORGE_DIR}} sed (one renderer)
#   F1  ABSENT  -> installed; content == rendered template; exec bit set
#   F2  STALE   (old copy lacking the worktree-helpers block) -> replaced;
#       content == rendered template; verified backup holds the old content
#   F3  CURRENT -> untouched: content unchanged, mtime preserved, no backup
#   F4  placeholder fully substituted ({{...}} gone, AITEAMFORGE_DIR = sandbox)
#   F5  DRY_RUN on a stale copy writes nothing (content, mtime, no backup)
#   F6  install_env_loader (fresh install) and update_env_loader (upgrade)
#       produce byte-identical files — the two paths cannot drift
#
# Sandboxed: AITEAMFORGE_DIR / WORKING_DIR point under TEST_TMP_DIR before
# anything is sourced. Never touches real $HOME or ~/aiteamforge.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
INSTALL_SH="$TAP_ROOT/libexec/installers/install-shell.sh"
ENV_LIB="$TAP_ROOT/libexec/lib/env-loader.sh"
TEMPLATE="$TAP_ROOT/share/templates/aiteamforge-env.sh"

for _need in "$UPGRADE_SH" "$INSTALL_SH" "$ENV_LIB" "$TEMPLATE"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
        exit 1
    fi
done

if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0730-env-loader.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then
        find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Sandbox BEFORE sourcing anything.
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
WORK_ROOT="$TEST_TMP_DIR/xaca0730"
mkdir -p "$WORK_ROOT"

_extract_fn() {
    awk -v fn="$2" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$1"
}

_mtime() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null; }

# Independent oracle: what the installed file MUST equal for a given dir.
_expected_render() { sed -e "s|{{AITEAMFORGE_DIR}}|$1|g" "$TEMPLATE"; }

# Run update_env_loader against <working_dir> in a child shell, with the
# real helpers it depends on extracted from the upgrade script.
#   $1 working_dir   $2 dry_run (true|false)
_run_upgrade_step() {
    local wd="$1" dry="${2:-false}"
    (
        set -eo pipefail   # the upgrade script's own strictness
        # shellcheck source=/dev/null
        source "$TAP_ROOT/libexec/lib/common.sh"
        # shellcheck source=/dev/null
        source "$ENV_LIB"
        eval "$(_extract_fn "$UPGRADE_SH" _aitf_file_mode)"
        eval "$(_extract_fn "$UPGRADE_SH" _aitf_install_rendered)"
        eval "$(_extract_fn "$UPGRADE_SH" update_env_loader)"
        if ! type -t update_env_loader >/dev/null 2>&1; then
            echo "EXTRACT_FAILED: update_env_loader" >&2
            exit 99
        fi
        # Exported only so shellcheck sees them used (read by the eval'd fn).
        export FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$wd" AITEAMFORGE_DIR="$wd" DRY_RUN="$dry"
        update_env_loader
    )
}

# ═══════════════════════════════════════════════════════════════════════════
# S1 — invoked in the run sequence (a correct function nothing calls is the
# whole bug class here)
# ═══════════════════════════════════════════════════════════════════════════
test_start "S1: update_env_loader is invoked (bare call) in the upgrade run sequence"
if grep -qE '^update_env_loader$' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "aiteamforge-upgrade.sh never calls update_env_loader — upgraded machines keep a stale aiteamforge-env.sh (XACA-0730)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# S2 — one renderer, shared by install and upgrade
# ═══════════════════════════════════════════════════════════════════════════
test_start "S2: install and upgrade both use aitf_render_env_loader (no second sed copy)"
_UP_FN="$(_extract_fn "$UPGRADE_SH" update_env_loader)"
_IN_FN="$(_extract_fn "$INSTALL_SH" install_env_loader)"
if [[ "$_UP_FN" == *aitf_render_env_loader* ]] && [[ "$_IN_FN" == *aitf_render_env_loader* ]] \
   && [[ "$_UP_FN" != *'{{AITEAMFORGE_DIR}}'* ]] && [[ "$_IN_FN" != *'{{AITEAMFORGE_DIR}}'* ]]; then
    test_pass
else
    test_fail "install_env_loader and update_env_loader must both delegate to aitf_render_env_loader and carry no private sed"
fi

# ═══════════════════════════════════════════════════════════════════════════
# F1 — ABSENT
# ═══════════════════════════════════════════════════════════════════════════
test_start "F1: absent env loader is installed and equals the rendered template"
F1="$WORK_ROOT/f1/aiteamforge"
mkdir -p "$F1"   # no share/ dir at all: upgrade must create it
_out="$(_run_upgrade_step "$F1" false 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ]; then
    test_fail "update_env_loader exited $_rc: $_out"
elif [ ! -f "$F1/share/aiteamforge-env.sh" ]; then
    test_fail "not installed. Output: $_out"
elif ! diff <(_expected_render "$F1") "$F1/share/aiteamforge-env.sh" >/dev/null; then
    test_fail "installed file differs from rendered template"
elif [ ! -x "$F1/share/aiteamforge-env.sh" ]; then
    test_fail "installed file lacks exec bit (install_env_loader sets +x)"
elif [[ "$_out" != *"Installed missing aiteamforge-env.sh"* ]]; then
    test_fail "outcome not logged as an install. Output: $_out"
else
    test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# F2 — STALE (the M1Pro case: pre-XACA-0494 copy, no worktree-helpers block)
# ═══════════════════════════════════════════════════════════════════════════
test_start "F2: stale env loader (no worktree-helpers block) is refreshed with a verified backup"
F2="$WORK_ROOT/f2/aiteamforge"
mkdir -p "$F2/share"
_expected_render "$F2" | awk '
    /XACA-0494/ { skip=1 }
    skip && /worktree-helpers\.sh/ { next }
    skip && /^fi$/ { skip=0; next }
    !skip { print }
' > "$F2/share/aiteamforge-env.sh"
chmod 755 "$F2/share/aiteamforge-env.sh"
cp "$F2/share/aiteamforge-env.sh" "$WORK_ROOT/f2-stale-copy"
if grep -q 'worktree-helpers.sh' "$F2/share/aiteamforge-env.sh" \
   || diff <(_expected_render "$F2") "$F2/share/aiteamforge-env.sh" >/dev/null; then
    test_fail "fixture invalid: stale copy still has the worktree-helpers block or equals the template (vacuous)"
else
    _out="$(_run_upgrade_step "$F2" false 2>&1)"; _rc=$?
    _bk="$(find "$F2/share" -name 'aiteamforge-env.sh.backup-*' | head -1)"
    if [ "$_rc" -ne 0 ]; then
        test_fail "update_env_loader exited $_rc: $_out"
    elif ! diff <(_expected_render "$F2") "$F2/share/aiteamforge-env.sh" >/dev/null; then
        test_fail "stale copy NOT refreshed (still differs from rendered template). Output: $_out"
    elif ! grep -q 'source "$AITEAMFORGE_DIR/worktree-helpers.sh"' "$F2/share/aiteamforge-env.sh"; then
        test_fail "refreshed copy is missing the XACA-0494 worktree-helpers block"
    elif [ -z "$_bk" ] || ! cmp -s "$_bk" "$WORK_ROOT/f2-stale-copy"; then
        test_fail "no backup, or backup does not hold the previous content"
    elif [[ "$_out" != *"Refreshed stale aiteamforge-env.sh"* ]]; then
        test_fail "outcome not logged as a refresh. Output: $_out"
    else
        test_pass
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# F3 — CURRENT: untouched, no mtime churn, no backup
# ═══════════════════════════════════════════════════════════════════════════
test_start "F3: current env loader is left untouched (content, mtime, no backup)"
F3="$WORK_ROOT/f3/aiteamforge"
mkdir -p "$F3/share"
_expected_render "$F3" > "$F3/share/aiteamforge-env.sh"
chmod 755 "$F3/share/aiteamforge-env.sh"
touch -t 202001010000 "$F3/share/aiteamforge-env.sh"
_before="$(_mtime "$F3/share/aiteamforge-env.sh")"
_out="$(_run_upgrade_step "$F3" false 2>&1)"; _rc=$?
_after="$(_mtime "$F3/share/aiteamforge-env.sh")"
_nfiles="$(find "$F3/share" -type f | wc -l | tr -d '[:space:]')"
if [ "$_rc" -ne 0 ]; then
    test_fail "update_env_loader exited $_rc: $_out"
elif ! diff <(_expected_render "$F3") "$F3/share/aiteamforge-env.sh" >/dev/null; then
    test_fail "current copy content changed"
elif [ -z "$_before" ] || [ "$_before" != "$_after" ]; then
    test_fail "mtime churned ($_before -> $_after) on an already-current file"
elif [ "$_nfiles" != "1" ]; then
    test_fail "expected only the env loader in share/, found $_nfiles files (stray backup/temp?)"
elif [[ "$_out" != *"already current"* ]]; then
    test_fail "outcome not logged as current. Output: $_out"
else
    test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# F4 — placeholder fully substituted
# ═══════════════════════════════════════════════════════════════════════════
test_start "F4: {{AITEAMFORGE_DIR}} fully substituted with the sandbox WORKING_DIR"
if ! grep -q '{{AITEAMFORGE_DIR}}' "$TEMPLATE"; then
    test_fail "fixture invalid: template has no {{AITEAMFORGE_DIR}} placeholder (vacuous)"
elif grep -q '{{' "$F1/share/aiteamforge-env.sh"; then
    test_fail "unsubstituted {{...}} placeholder left in installed file"
elif ! grep -qF "export AITEAMFORGE_DIR=\"$F1\"" "$F1/share/aiteamforge-env.sh"; then
    test_fail "AITEAMFORGE_DIR not set to the sandbox working dir ($F1)"
else
    test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# F5 — DRY_RUN writes nothing
# ═══════════════════════════════════════════════════════════════════════════
test_start "F5: DRY_RUN on a stale copy changes nothing"
F5="$WORK_ROOT/f5/aiteamforge"
mkdir -p "$F5/share"
cp "$WORK_ROOT/f2-stale-copy" "$F5/share/aiteamforge-env.sh"
touch -t 202001010000 "$F5/share/aiteamforge-env.sh"
_before="$(_mtime "$F5/share/aiteamforge-env.sh")"
_out="$(_run_upgrade_step "$F5" true 2>&1)"; _rc=$?
_after="$(_mtime "$F5/share/aiteamforge-env.sh")"
_nfiles="$(find "$F5/share" -type f | wc -l | tr -d '[:space:]')"
if [ "$_rc" -ne 0 ]; then
    test_fail "update_env_loader exited $_rc: $_out"
elif ! cmp -s "$WORK_ROOT/f2-stale-copy" "$F5/share/aiteamforge-env.sh" || [ "$_before" != "$_after" ] || [ "$_nfiles" != "1" ]; then
    test_fail "dry run modified share/ (content/mtime/file count changed)"
elif [[ "$_out" != *"Would refresh"* ]]; then
    test_fail "dry run did not report the pending refresh. Output: $_out"
else
    test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# F6 — install path == upgrade path
# ═══════════════════════════════════════════════════════════════════════════
test_start "F6: install_env_loader output is byte-identical to update_env_loader output"
F6="$WORK_ROOT/f6/aiteamforge"
mkdir -p "$F6/share"
_out="$(
    export AITEAMFORGE_DIR="$F6" INSTALL_ROOT="$TAP_ROOT"
    # shellcheck source=/dev/null
    source "$INSTALL_SH" >/dev/null 2>&1
    install_env_loader 2>&1
)"; _rc=$?
if [ "$_rc" -ne 0 ] || [ ! -f "$F6/share/aiteamforge-env.sh" ]; then
    test_fail "install_env_loader failed (rc=$_rc): $_out"
elif ! diff <(_expected_render "$F6") "$F6/share/aiteamforge-env.sh" >/dev/null; then
    test_fail "install_env_loader output differs from the rendered template"
else
    cp "$F6/share/aiteamforge-env.sh" "$WORK_ROOT/f6-install-copy"
    _out="$(_run_upgrade_step "$F6" false 2>&1)"
    if cmp -s "$WORK_ROOT/f6-install-copy" "$F6/share/aiteamforge-env.sh" && [[ "$_out" == *"already current"* ]]; then
        test_pass
    else
        test_fail "upgrade did not treat a freshly installed file as current — install and upgrade render differently. Output: $_out"
    fi
fi

# Restore the outer sandbox value (F6 subshell exported its own).
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"

if [ -n "${_PASS_COUNT+x}" ]; then
    _TOTAL=$((_PASS_COUNT + _FAIL_COUNT))
    echo ""
    echo "XACA-0730 env-loader upgrade-refresh tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed (${_TOTAL} assertions executed)"
    if [ "$_TOTAL" -eq 0 ]; then
        echo "FATAL: zero assertions executed — this is a vacuous pass, not a real result" >&2
        exit 1
    fi
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
