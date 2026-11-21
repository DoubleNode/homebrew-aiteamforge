#!/bin/bash
# shellcheck disable=SC2016  # single-quoted bash -c / sh -c bodies expand in the child, on purpose
# test-xaca-1926-statusline-upgrade-refresh.sh
#
# XACA-1926: FUNCTIONAL suite for the receipt-guarded
# ~/.claude/statusline-command.sh refresh on the UPGRADE path.
#
# Code under test:
#   libexec/installers/install-claude-config.sh
#     install_statusline()             writes ${AITEAMFORGE_DIR}/.statusline-command.receipt
#     _xaca1926_refresh_statusline()   rc 0 current | 1 soft-fail | 2 refreshed
#                                      | 3 left untouched (+ .new sidecar) | 4 no live file
#   libexec/commands/aiteamforge-upgrade.sh
#     update_statusline()              fail-soft wrapper, wired after update_tmux_conf
#
# EXECUTES the real installer functions, sourced in a child bash the way the
# upgrade does. Cases:
#   C1  fresh install writes receipt == live file, live is executable
#   C2  pristine (receipt match) + changed template -> rc 2, refreshed, backup, 755
#   C3  pristine + unchanged template -> rc 0, file not rewritten
#   C4  customized (receipt mismatch) -> rc 3, untouched, sidecar == template
#   C4b stale receipt but live == current render -> rc 0, receipt re-synced, no sidecar
#   C5  pre-receipt Mac on the v0.20.9..v0.21.26 template (fixture d620080,
#       sha256-pinned to the installer's constant) -> rc 2, receipt written
#   C6  pre-receipt, foreign content -> rc 3, untouched, sidecar
#   C7  symlink -> rc 3, link and its destination untouched
#   C8  no statusline -> rc 4, nothing created
#   C9  idempotence: second run after a refresh -> rc 0
#   C10 the SHIPPED template uses no apply_template placeholder (the premise
#       that makes the sha256 bootstrap machine-independent)
#   C11 wiring: update_statusline runs right after update_tmux_conf; real body
#       reports a refresh, honours --dry-run, survives an exploding installer
#   C12 soft-fail paths (missing template, unwritable backup dir) -> rc 1
#
# ISOLATION: every case builds its own mktemp HOME, AITEAMFORGE_DIR,
# CLAUDE_CONFIG_DIR and TEMPLATE_DIR. GIT_DIR/GIT_WORK_TREE are unset.
# Mutation seam: XACA1926_INSTALLER / XACA1926_UPGRADE_SH.
# Exit 0 = all pass with >=1 assertion; 1 = any fail or zero assertions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="${XACA1926_INSTALLER:-$TAP_ROOT/libexec/installers/install-claude-config.sh}"
UPGRADE_SH="${XACA1926_UPGRADE_SH:-$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh}"
SHIPPED_TMPL="$TAP_ROOT/share/templates/claude/statusline-command.sh"

# The template every fleet Mac ran from v0.20.9 to v0.21.26 (tap blob at
# d620080), committed byte-exact. The installer embeds its sha256.
HIST_SHA256="ea7de4043815daec4498aaa91e72e86892c386ffb4af10e64f68f2ef9fbfc53a"
HIST_FIXTURE="$SCRIPT_DIR/fixtures/xaca-1926/statusline-command.sh.d620080"

for _need in "$INSTALLER" "$UPGRADE_SH" "$HIST_FIXTURE"; do
    [ -f "$_need" ] || { echo "FATAL: missing $_need" >&2; exit 1; }
done
if [ "$(shasum -a 256 "$HIST_FIXTURE" | awk '{print $1}')" != "$HIST_SHA256" ]; then
    echo "FATAL: fixture sha256 drifted from $HIST_SHA256" >&2
    exit 1
fi

TEST_BASH="${BASH:-bash}"
PASS=0
FAIL=0
CASE=""
CASE_FAILED=0
begin_case() { CASE="$1"; CASE_FAILED=0; echo "  >> $1"; }
fail_note()  { CASE_FAILED=1; echo "     note: $*" >&2; }
check() {    # check <label> <cmd...>
    local label="$1"; shift
    if "$@"; then :; else fail_note "$label"; fi
}
check_rc() { [ "$2" = "$3" ] || fail_note "$1: expected rc $2, got $3 (out: $OUT)"; }
end_case() {
    if [ "$CASE_FAILED" -eq 0 ]; then PASS=$((PASS + 1)); echo "     PASS"
    else FAIL=$((FAIL + 1)); echo "     FAIL: $CASE" >&2; fi
}
same_bytes() { cmp -s "$1" "$2"; }
mode_of() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1" 2>/dev/null; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xaca1926.XXXXXX")" || exit 1
trap 'find "$ROOT" -depth -delete 2>/dev/null' EXIT

new_sandbox() {
    S="$(mktemp -d "$ROOT/case.XXXXXX")"
    HOME_T="$S/home"; AITF="$S/aitf"; CCD="$HOME_T/.claude"; TMPL_ROOT="$S/templates"
    mkdir -p "$HOME_T" "$AITF" "$CCD" "$TMPL_ROOT/claude"
    TMPL="$TMPL_ROOT/claude/statusline-command.sh"
    LIVE="$CCD/statusline-command.sh"
    RECEIPT="$AITF/.statusline-command.receipt"
    printf '#!/usr/bin/env bash\necho "statusline v2"\n' > "$TMPL"
    printf '#!/usr/bin/env bash\necho "statusline v1"\n' > "$S/old"
}

# run_fn <function>: source the REAL installer in a child bash, then call it.
run_fn() {
    OUT="$( env -u GIT_DIR -u GIT_WORK_TREE -u CLAUDE_SANDBOX \
        HOME="$HOME_T" USER=xaca1926 AITEAMFORGE_DIR="$AITF" \
        CLAUDE_CONFIG_DIR="$CCD" TEMPLATE_DIR="$TMPL_ROOT" \
        "$TEST_BASH" -c 'source "$1" >/dev/null 2>&1; shift; "$@"' _ "$INSTALLER" "$@" 2>&1 </dev/null )"
    RC=$?
}
refresh() { run_fn _xaca1926_refresh_statusline; }

# ─────────────────────────────────────────────────────────────────────────────
echo "== XACA-1926 statusline upgrade refresh =="

begin_case "C1: install_statusline writes the receipt and an executable statusline"
new_sandbox
run_fn install_statusline
check "live installed from template" same_bytes "$LIVE" "$TMPL"
check "receipt == live" same_bytes "$RECEIPT" "$LIVE"
check "live is executable" test -x "$LIVE"
end_case

begin_case "C2: pristine (receipt) + changed template -> rc 2, refreshed, backed up, 755"
new_sandbox
cp "$S/old" "$LIVE"; chmod 755 "$LIVE"; cp "$S/old" "$RECEIPT"
refresh
check_rc "refresh" 2 "$RC"
check "live == template" same_bytes "$LIVE" "$TMPL"
check "receipt updated" same_bytes "$RECEIPT" "$LIVE"
# BACKUP_DIR is set when the installer is sourced (timestamped), so find the copy.
bk="$(find "$AITF/.backups" -name statusline-command.sh -type f 2>/dev/null | head -1)"
check "backup holds the old bytes ($bk)" same_bytes "${bk:-/nonexistent}" "$S/old"
check "mode 755" test "$(mode_of "$LIVE")" = 755
end_case

begin_case "C3: pristine + unchanged template -> rc 0, not rewritten"
new_sandbox
cp "$TMPL" "$LIVE"; cp "$TMPL" "$RECEIPT"; touch -t 200001010000 "$LIVE"
before="$(ls -li "$LIVE")"
refresh
check_rc "refresh" 0 "$RC"
check "file untouched (inode+mtime)" test "$(ls -li "$LIVE")" = "$before"
end_case

begin_case "C4: customized (receipt mismatch) -> rc 3, untouched, sidecar"
new_sandbox
printf '#!/usr/bin/env bash\necho mine\n' > "$LIVE"; cp "$LIVE" "$S/mine"; cp "$S/old" "$RECEIPT"
refresh
check_rc "refresh" 3 "$RC"
check "live untouched" same_bytes "$LIVE" "$S/mine"
check "sidecar == template" same_bytes "$LIVE.new" "$TMPL"
end_case

begin_case "C4b: stale receipt but live == current render -> rc 0, receipt re-synced, no sidecar"
new_sandbox
cp "$TMPL" "$LIVE"; cp "$S/old" "$RECEIPT"
refresh
check_rc "refresh" 0 "$RC"
check "receipt re-synced" same_bytes "$RECEIPT" "$LIVE"
check "no sidecar" test ! -e "$LIVE.new"
end_case

begin_case "C5: pre-receipt Mac on the d620080 template -> rc 2, receipt written"
new_sandbox
check "installer embeds the fixture's sha256" grep -q "^${HIST_SHA256}\$" "$INSTALLER"
cp "$HIST_FIXTURE" "$LIVE"; chmod 755 "$LIVE"
refresh
check_rc "refresh" 2 "$RC"
check "live == template" same_bytes "$LIVE" "$TMPL"
check "receipt written" same_bytes "$RECEIPT" "$LIVE"
end_case

begin_case "C6: pre-receipt, foreign content -> rc 3, untouched, sidecar"
new_sandbox
printf '#!/usr/bin/env bash\necho hand-authored\n' > "$LIVE"; cp "$LIVE" "$S/mine"
refresh
check_rc "refresh" 3 "$RC"
check "live untouched" same_bytes "$LIVE" "$S/mine"
check "sidecar == template" same_bytes "$LIVE.new" "$TMPL"
check "no receipt invented" test ! -e "$RECEIPT"
end_case

begin_case "C7: symlink whose bytes match the receipt -> rc 3, link and destination untouched"
new_sandbox
cp "$S/old" "$S/dest"; cp "$S/old" "$RECEIPT"; ln -s "$S/dest" "$LIVE"
refresh
check_rc "refresh" 3 "$RC"
check "still a symlink" test -L "$LIVE"
check "link target unchanged" test "$(readlink "$LIVE")" = "$S/dest"
check "destination untouched" same_bytes "$S/dest" "$S/old"
end_case

begin_case "C8: no statusline -> rc 4, nothing created"
new_sandbox
refresh
check_rc "refresh" 4 "$RC"
check "nothing created" test ! -e "$LIVE"
check "no receipt" test ! -e "$RECEIPT"
end_case

begin_case "C9: idempotence after a refresh -> rc 0"
new_sandbox
cp "$S/old" "$LIVE"; cp "$S/old" "$RECEIPT"
refresh; check_rc "first run" 2 "$RC"
refresh; check_rc "second run" 0 "$RC"
end_case

begin_case "C10: the shipped template uses no apply_template placeholder"
if [ -f "$SHIPPED_TMPL" ]; then
    n="$(grep -c -E '\{\{(AITEAMFORGE_DIR|HOME|CLAUDE_CONFIG_DIR|USER)\}\}' "$SHIPPED_TMPL")"
    check "0 placeholders (got $n): the sha256 bootstrap would be machine-dependent" test "$n" = 0
    hist="$(awk '/^_xaca1926_statusline_historical_sha256\(\)/{f=1;next} f&&/<<.HIST.$/{h=1;next} h&&/^HIST$/{exit} h' "$INSTALLER")"
check "historical list is non-empty" test -n "$hist"
check "every embedded sha256 is 64 hex chars" test -z "$(printf '%s\n' "$hist" | grep -v -E '^[0-9a-f]{64}$')"
check "the fixture's sha256 is in that list" sh -c 'printf "%s\n" "$1" | grep -qx "$2"' _ "$hist" "$HIST_SHA256"
else
    fail_note "shipped template missing: $SHIPPED_TMPL"
fi
end_case

# ── C11: upgrade wiring ─────────────────────────────────────────────────────
UPD_BODY="$ROOT/update_statusline.sh"
awk '/^update_statusline\(\) \{/{c=1} c{print} c&&/^}$/{exit}' "$UPGRADE_SH" > "$UPD_BODY"
run_upd() {   # run_upd <libexec-root> <dry true|false>
    OUT="$( env -u GIT_DIR -u GIT_WORK_TREE -u CLAUDE_SANDBOX HOME="$HOME_T" USER=xaca1926 CLAUDE_CONFIG_DIR="$CCD" \
        WORKING_DIR="$AITF" FRAMEWORK_DIR="$S/framework" LIBEXEC_DIR="$1" DRY_RUN="$2" \
        "$TEST_BASH" -c '
            print_section() { echo "SECTION: $*"; }
            print_info()    { echo "INFO: $*"; }
            print_success() { echo "SUCCESS: $*"; }
            print_warning() { echo "WARNING: $*"; }
            source "$1"
            update_statusline
            echo "FUNC_RC=$?"' _ "$UPD_BODY" 2>&1 )"
    RC=$?
}
upgrade_sandbox() {
    new_sandbox
    mkdir -p "$S/framework/share" "$S/libexec/installers"
    ln -s "$TMPL_ROOT" "$S/framework/share/templates"
    cp "$INSTALLER" "$S/libexec/installers/install-claude-config.sh"
}

begin_case "C11a: update_statusline is defined and runs right after update_tmux_conf"
check "body extracted" test -s "$UPD_BODY"
seq="$(grep -n -E '^update_(tmux_conf|statusline|claude_settings)$' "$UPGRADE_SH" | cut -d: -f2 | tr '\n' ' ')"
check "run order tmux -> statusline -> settings (got: $seq)" test "$seq" = "update_tmux_conf update_statusline update_claude_settings "
end_case

begin_case "C11b: real update_statusline body refreshes a stale pristine file"
upgrade_sandbox
cp "$HIST_FIXTURE" "$LIVE"
run_upd "$S/libexec" false
check_rc "process" 0 "$RC"
case "$OUT" in *"FUNC_RC=0"*) ;; *) fail_note "function rc: $OUT" ;; esac
case "$OUT" in *"SUCCESS: Statusline refreshed"*) ;; *) fail_note "no refresh line: $OUT" ;; esac
check "live == template" same_bytes "$LIVE" "$TMPL"
end_case

begin_case "C11c: --dry-run changes nothing"
upgrade_sandbox
cp "$HIST_FIXTURE" "$LIVE"
run_upd "$S/libexec" true
case "$OUT" in *"Would check ~/.claude/statusline-command.sh"*) ;; *) fail_note "no dry-run line: $OUT" ;; esac
check "live untouched" same_bytes "$LIVE" "$HIST_FIXTURE"
end_case

begin_case "C11d: an installer that dies while sourced -> warning, rc 0, upgrade continues"
upgrade_sandbox
printf '%s\n' 'echo "installer exploded" >&2' 'exit 7' > "$S/libexec/installers/install-claude-config.sh"
run_upd "$S/libexec" false
check_rc "process" 0 "$RC"
case "$OUT" in *"FUNC_RC=0"*) ;; *) fail_note "function rc: $OUT" ;; esac
case "$OUT" in *"WARNING: "*) ;; *) fail_note "no warning: $OUT" ;; esac
end_case

begin_case "C12: soft-fail paths -> rc 1, file untouched"
new_sandbox
cp "$S/old" "$LIVE"; cp "$S/old" "$RECEIPT"
rm -f "$TMPL"
refresh
check_rc "missing template" 1 "$RC"
check "untouched (missing template)" same_bytes "$LIVE" "$S/old"
new_sandbox
cp "$S/old" "$LIVE"; cp "$S/old" "$RECEIPT"
mkdir -p "$AITF/.backups"; chmod 555 "$AITF/.backups"
refresh
chmod 755 "$AITF/.backups"
check_rc "unwritable backup dir" 1 "$RC"
check "untouched (no backup, no overwrite)" same_bytes "$LIVE" "$S/old"
end_case

echo
echo "Results: $PASS passed, $FAIL failed"
[ $((PASS + FAIL)) -gt 0 ] || { echo "FAIL: zero cases ran (vacuous)" >&2; exit 1; }
[ "$FAIL" -eq 0 ]
