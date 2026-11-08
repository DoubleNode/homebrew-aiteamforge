#!/bin/bash
# test-xaca-1624-managed-policy-surfacing.sh
#
# XACA-1624-005: doctor + upgrade SURFACE the Claude Code L1 managed policy status.
#
# Unit under test (tap-native):
#   libexec/lib/managed-policy-status.sh   atf_mp_evaluate <aiteamforge_dir>
#       -> ATF_MP_VERDICT SKIP|OK|ACTION|UNKNOWN, ATF_MP_SUMMARY, ATF_MP_HINT
#       reads `python3 <dir>/scripts/kb-sync-plugins managed-policy --status`
#   check_managed_policy   in bin/aiteamforge-doctor.sh AND libexec/commands/aiteamforge-doctor.sh
#   surface_managed_policy_status   in libexec/commands/aiteamforge-upgrade.sh
#
# Covered:
#   1  helper verdict matrix, run in a child bash 5 AND /bin/bash (3.2 on macOS)
#   2  both doctors end to end (`--check managed-policy`): PASS / WARN / WARN-cannot-determine,
#      counts treat it as a warning (not a fail, not a pass), all-checks list membership
#   3  upgrade surface function under `set -eo pipefail`: warns, returns 0, never --install, never sudo
#   4  delivery: lib in the tree, Formula asserts it, every consumer sources it from a path that
#      exists in the installed (Cellar libexec) layout
#   5  mutation sentinels, IN-FILE on temp copies (each proves its sed changed the file)
#
# Hermetic: HOME, CLAUDE_CONFIG_DIR, AITEAMFORGE_DIR and TMPDIR are all inside TEST_TMP_DIR; the
# status tool is a python stub generated here; sudo is a logging stub that fails. Nothing touches
# the real ~/.claude, ~/aiteamforge or /Library/Application Support/ClaudeCode. This file is itself
# bash 3.2 compatible and is run under both shells by the matrix below.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$TAP_ROOT/libexec/lib/managed-policy-status.sh"
BIN_DOCTOR="$TAP_ROOT/bin/aiteamforge-doctor.sh"
LIBEXEC_DOCTOR="$TAP_ROOT/libexec/commands/aiteamforge-doctor.sh"
UPGRADE="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
FORMULA="$TAP_ROOT/Formula/aiteamforge.rb"

# ── harness: use the runner's functions when present, else a minimal standalone set ──
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "  PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "  FAIL: $_CURRENT_TEST -- $1" >&2; }
fi

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/xaca1624-test.XXXXXX")"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
trap '[ "$_OWN_TMP" = true ] && rm -rf "$TEST_TMP_DIR"' EXIT

T="$TEST_TMP_DIR/xaca1624"
rm -rf "$T"
mkdir -p "$T/home/.claude" "$T/atf/scripts" "$T/emptybin" "$T/stubbin" "$T/tmp"
STUBLOG="$T/atf/scripts/argv.log"
SUDOLOG="$T/sudo.log"

# eq <label> <expected> <actual>
eq() {
    test_start "$1"
    if [ "$2" = "$3" ]; then test_pass; else test_fail "expected [$2] got [$3]"; fi
}
# has <label> <haystack> <needle>
has() {
    test_start "$1"
    case "$2" in *"$3"*) test_pass ;; *) test_fail "missing [$3] in: $2" ;; esac
}
# lacks <label> <haystack> <needle>
lacks() {
    test_start "$1"
    case "$2" in *"$3"*) test_fail "unexpected [$3] in: $2" ;; *) test_pass ;; esac
}
# ok <label> <rc-of-condition>
ok() {
    test_start "$1"
    if [ "$2" -eq 0 ]; then test_pass; else test_fail "condition false"; fi
}

# ── status tool stub (self-contained, generated inside the sandbox) ──
cat > "$T/atf/scripts/kb-sync-plugins" <<'PYSTUB'
#!/usr/bin/env python3
import os, signal, sys, pathlib

here = pathlib.Path(__file__).resolve().parent
with open(str(here / "argv.log"), "a") as fh:
    fh.write(" ".join(sys.argv[1:]) + "\n")
case = (here / "case").read_text().strip()
if sys.argv[1:3] != ["managed-policy", "--status"]:
    sys.exit(99)

P = " path=/Library/x\n"
table = {
    "ok": (0, "POLICY_STATUS=OK" + P),
    "absent": (1, "POLICY_STATUS=POLICY_ABSENT" + P),
    "stale": (1, "POLICY_STATUS=POLICY_STALE" + P + "detail line\n"),
    "rc2": (2, "usage: unrecognized arguments\n"),
    "rc3": (3, "POLICY_STATUS=UNVERIFIABLE" + P),
    "rc3ok": (3, "POLICY_STATUS=OK" + P),
    "rc7ok": (7, "POLICY_STATUS=OK" + P),
    "garbage": (0, "hello world\n"),
    "empty": (0, ""),
    "nopath": (0, "POLICY_STATUS=OK\n"),
    "okrc1": (1, "POLICY_STATUS=OK" + P),
    "absentrc0": (0, "POLICY_STATUS=POLICY_ABSENT" + P),
    "bogusword": (1, "POLICY_STATUS=BOGUS" + P),
    "notfirst": (0, "banner\nPOLICY_STATUS=OK" + P),
}
if case == "stderrnoise":
    sys.stderr.write("POLICY_STATUS=POLICY_ABSENT path=/stderr-must-be-ignored\n")
    sys.stdout.write("POLICY_STATUS=OK" + P)
    sys.exit(0)
if case == "crash":
    raise RuntimeError("stub crash")
if case == "killed":
    os.kill(os.getpid(), signal.SIGKILL)
rc, txt = table[case]
sys.stdout.write(txt)
sys.exit(rc)
PYSTUB
chmod +x "$T/atf/scripts/kb-sync-plugins"
setcase() { echo "$1" > "$T/atf/scripts/case"; }

# sudo stub: logs and FAILS. Any call from the code under test is a violation.
cat > "$T/stubbin/sudo" <<SUDO
#!/bin/sh
echo "sudo \$*" >> "$SUDOLOG"
exit 1
SUDO
chmod +x "$T/stubbin/sudo"

# ── helper driver: prints V:/S: lines then the hint after a --- line ──
cat > "$T/driver.sh" <<'DRV'
#!/bin/bash
set -e
. "$MPLIB"
atf_mp_evaluate "$AITEAMFORGE_DIR"
echo "V:$ATF_MP_VERDICT"
echo "S:$ATF_MP_SUMMARY"
echo "---"
printf '%s\n' "$ATF_MP_HINT"
exit 0
DRV

# Shells: bash 5 (child) and /bin/bash (3.2 on macOS).
BASH5=""
for _c in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash)"; do
    [ -n "$_c" ] && [ -x "$_c" ] || continue
    _m="$("$_c" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)"
    if [ "${_m:-0}" -ge 4 ] 2>/dev/null; then BASH5="$_c"; break; fi
done
BASH3="/bin/bash"
SHELLS="$BASH3"
[ -n "$BASH5" ] && [ "$BASH5" != "$BASH3" ] && SHELLS="$BASH5 $BASH3"
echo "  shells under test: $SHELLS ($($BASH3 -c 'echo $BASH_VERSION'))"

SYSPATH="/usr/bin:/bin:/opt/homebrew/bin"
MP_V=""; MP_S=""; MP_H=""
# mp_eval <shell> <mplib> <aiteamforge_dir> <config_dir|-> [extra env VAR=val...]
mp_eval() {
    local sh="$1" mplib="$2" dir="$3" cfg="$4" out
    shift 4
    if [ "$cfg" = "-" ]; then
        out="$(env -i PATH="$SYSPATH" HOME="$T/home" TMPDIR="$T/tmp" AITEAMFORGE_DIR="$dir" MPLIB="$mplib" "$@" "$sh" "$T/driver.sh" 2>&1)"
    else
        out="$(env -i PATH="$SYSPATH" HOME="$T/home" TMPDIR="$T/tmp" CLAUDE_CONFIG_DIR="$cfg" AITEAMFORGE_DIR="$dir" MPLIB="$mplib" "$@" "$sh" "$T/driver.sh" 2>&1)"
    fi
    MP_V="$(printf '%s\n' "$out" | sed -n 's/^V://p')"
    MP_S="$(printf '%s\n' "$out" | sed -n 's/^S://p')"
    MP_H="$(printf '%s\n' "$out" | sed -n '/^---$/,$p' | sed '1d')"
}

# ════════════════════════════════════════════════════════════════════════════
# 0. Preconditions
# ════════════════════════════════════════════════════════════════════════════
for _f in "$LIB" "$BIN_DOCTOR" "$LIBEXEC_DOCTOR" "$UPGRADE" "$FORMULA"; do
    test_start "precondition: exists $(basename "$_f")"
    if [ -f "$_f" ]; then test_pass; else test_fail "missing $_f"; fi
done

# ════════════════════════════════════════════════════════════════════════════
# 1. Helper matrix, both shells
# ════════════════════════════════════════════════════════════════════════════
INSTALL_LINE="python3 $T/atf/scripts/kb-sync-plugins managed-policy --install"

# case-name | expected verdict
MATRIX="ok|OK
absent|ACTION
stale|ACTION
rc2|UNKNOWN
rc3|UNKNOWN
rc3ok|UNKNOWN
rc7ok|UNKNOWN
garbage|UNKNOWN
empty|UNKNOWN
nopath|UNKNOWN
okrc1|UNKNOWN
absentrc0|UNKNOWN
bogusword|UNKNOWN
notfirst|UNKNOWN
stderrnoise|OK
crash|UNKNOWN
killed|UNKNOWN"

# run_matrix <mplib> -> prints "case:verdict" lines for the current shell loop
for SH in $SHELLS; do
    TAG="[$(basename "$SH") $($SH -c 'echo ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}')]"
    while IFS='|' read -r c want; do
        [ -n "$c" ] || continue
        setcase "$c"
        mp_eval "$SH" "$LIB" "$T/atf" "$T/home/.claude"
        eq "$TAG matrix $c -> $want" "$want" "$MP_V"
        if [ "$want" = "UNKNOWN" ]; then
            test_start "$TAG matrix $c: UNKNOWN is never PASS-shaped (cannot determine, not-a-pass hint)"
            case "$MP_S" in *"cannot determine"*) case "$MP_H" in *"Not a pass"*) test_pass ;; *) test_fail "hint=[$MP_H]" ;; esac ;; *) test_fail "summary=[$MP_S]" ;; esac
        fi
    done <<EOF
$MATRIX
EOF

    for c in absent stale; do
        setcase "$c"
        mp_eval "$SH" "$LIB" "$T/atf" "$T/home/.claude"
        has "$TAG $c hint has the full-path install command" "$MP_H" "$INSTALL_LINE"
        has "$TAG $c hint says local terminal" "$MP_H" "local terminal"
        has "$TAG $c hint names check --host --probe" "$MP_H" "check --host --probe"
        has "$TAG $c hint carries the SSH note" "$MP_H" "SSH"
    done
    setcase absent
    mp_eval "$SH" "$LIB" "$T/atf" "$T/home/.claude"
    has "$TAG absent summary names POLICY_ABSENT" "$MP_S" "POLICY_ABSENT"
    setcase stale
    mp_eval "$SH" "$LIB" "$T/atf" "$T/home/.claude"
    has "$TAG stale summary names POLICY_STALE" "$MP_S" "POLICY_STALE"

    setcase rc2
    mp_eval "$SH" "$LIB" "$T/atf" "$T/home/.claude"
    has "$TAG rc2 summary says predates" "$MP_S" "predates"

    setcase ok
    mp_eval "$SH" "$LIB" "$T/atf" "$T/home/.claude"
    eq "$TAG ok has empty hint" "" "$(printf '%s' "$MP_H" | tr -d '[:space:]')"

    mp_eval "$SH" "$LIB" "$T/nonexistent" "$T/home/.claude"
    eq "$TAG tool missing -> UNKNOWN" "UNKNOWN" "$MP_V"
    has "$TAG tool missing summary" "$MP_S" "not installed"

    # python3 absent from PATH
    test_start "$TAG python3 absent from PATH -> UNKNOWN"
    _o="$(env -i PATH="$T/emptybin" HOME="$T/home" CLAUDE_CONFIG_DIR="$T/home/.claude" AITEAMFORGE_DIR="$T/atf" MPLIB="$LIB" "$SH" "$T/driver.sh" 2>&1)"
    case "$_o" in *"V:UNKNOWN"*) test_pass ;; *) test_fail "$_o" ;; esac

    # SKIP guards
    setcase absent
    mp_eval "$SH" "$LIB" "$T/atf" "$T/stage"
    eq "$TAG staged CLAUDE_CONFIG_DIR -> SKIP" "SKIP" "$MP_V"
    mp_eval "$SH" "$LIB" "$T/atf" "-" CLAUDE_SANDBOX=1
    eq "$TAG CLAUDE_SANDBOX=1 (config dir unset) -> SKIP" "SKIP" "$MP_V"
    mp_eval "$SH" "$LIB" "$T/atf" "-"
    eq "$TAG no CLAUDE_CONFIG_DIR, default ~/.claude -> evaluated (ACTION)" "ACTION" "$MP_V"
    mkdir -p "$T/home/dev-team/.claude/agents-master"
    mp_eval "$SH" "$LIB" "$T/atf" "$T/home/.claude"
    eq "$TAG dev-machine anchor -> SKIP" "SKIP" "$MP_V"
    has "$TAG dev-machine skip summary" "$MP_S" "dev machine"
    rm -rf "$T/home/dev-team"
done

# stderr noise never becomes line 1 (and the tool was only ever asked for --status)
test_start "tool only ever invoked with managed-policy --status"
_bad="$(grep -vx 'managed-policy --status' "$STUBLOG" 2>/dev/null | head -1)"
if [ -z "$_bad" ]; then test_pass; else test_fail "unexpected argv: $_bad"; fi

# ════════════════════════════════════════════════════════════════════════════
# 2. Doctors end to end (installed layout: a copy of bin/ + libexec/, as the Cellar libexec)
# ════════════════════════════════════════════════════════════════════════════
make_tree() { # make_tree <dest>
    rm -rf "$1"; mkdir -p "$1"
    cp -R "$TAP_ROOT/bin" "$1/bin"
    cp -R "$TAP_ROOT/libexec" "$1/libexec"
    [ -f "$TAP_ROOT/VERSION" ] && cp "$TAP_ROOT/VERSION" "$1/VERSION"
    return 0
}
make_tree "$T/tree"

DOC_OUT=""; DOC_RC=0
# doctor_run <bin|libexec> <treedir> [extra env...]
doctor_run() {
    local which="$1" tree="$2" script
    shift 2
    if [ "$which" = bin ]; then script="$tree/bin/aiteamforge-doctor.sh"; else script="$tree/libexec/commands/aiteamforge-doctor.sh"; fi
    DOC_OUT="$(env -i PATH="$T/stubbin:$SYSPATH" HOME="$T/home" TMPDIR="$T/tmp" CLAUDE_CONFIG_DIR="$T/home/.claude" \
        AITEAMFORGE_DIR="$T/atf" AITEAMFORGE_HOME="$tree" "$@" /bin/bash "$script" --check managed-policy 2>&1 </dev/null)"
    DOC_RC=$?
    DOC_OUT="$(printf '%s\n' "$DOC_OUT" | sed $'s/\x1b\\[[0-9;]*m//g')"
}
count_of() { printf '%s\n' "$DOC_OUT" | sed -n "s/^$1: *\([0-9][0-9]*\).*/\1/p" | head -1; }

for WH in bin libexec; do
    : > "$SUDOLOG"
    setcase ok
    doctor_run "$WH" "$T/tree"
    has "$WH doctor OK: PASS line" "$DOC_OUT" "managed policy is installed and current"
    eq "$WH doctor OK: Passed=1" "1" "$(count_of Passed)"
    eq "$WH doctor OK: Warnings=0" "0" "$(count_of Warnings)"
    eq "$WH doctor OK: Failed=0" "0" "$(count_of Failed)"
    eq "$WH doctor OK: exit 0" "0" "$DOC_RC"
    # Existing exit convention: bin doctor exits 0 on warnings; libexec doctor exits 1 on warnings
    # and 2 only on failures. A managed-policy warning must land on the WARNING code, never the failure code.
    WARN_RC=0; [ "$WH" = libexec ] && WARN_RC=1

    for c in absent stale; do
        setcase $c
        doctor_run "$WH" "$T/tree"
        has "$WH doctor $c: warning marker" "$DOC_OUT" "⚠ Claude Code managed policy"
        has "$WH doctor $c: install line printed WITHOUT --verbose" "$DOC_OUT" "$INSTALL_LINE"
        has "$WH doctor $c: local terminal" "$DOC_OUT" "local terminal"
        eq "$WH doctor $c: Passed=0 (not a pass)" "0" "$(count_of Passed)"
        eq "$WH doctor $c: Warnings=1" "1" "$(count_of Warnings)"
        eq "$WH doctor $c: Failed=0 (not a failure)" "0" "$(count_of Failed)"
        eq "$WH doctor $c: exit is the warning code $WARN_RC (never the failure code)" "$WARN_RC" "$DOC_RC"
    done

    for c in rc2 rc3 garbage crash; do
        setcase $c
        doctor_run "$WH" "$T/tree"
        has "$WH doctor $c: WARN cannot determine" "$DOC_OUT" "⚠ Claude Code managed policy: cannot determine status"
        eq "$WH doctor $c: Passed=0" "0" "$(count_of Passed)"
        eq "$WH doctor $c: Warnings=1" "1" "$(count_of Warnings)"
        eq "$WH doctor $c: Failed=0" "0" "$(count_of Failed)"
        eq "$WH doctor $c: exit is the warning code $WARN_RC" "$WARN_RC" "$DOC_RC"
    done
    setcase rc2
    doctor_run "$WH" "$T/tree"
    has "$WH doctor rc2: mentions predates" "$DOC_OUT" "predates"

    # skipped: staged config dir -> INFO, not counted at all
    setcase absent
    doctor_run "$WH" "$T/tree" CLAUDE_CONFIG_DIR="$T/stage"
    has "$WH doctor staged: not checked" "$DOC_OUT" "not checked"
    eq "$WH doctor staged: Total=0 (not counted)" "0" "$(count_of 'Total checks')"
    lacks "$WH doctor staged: no install line" "$DOC_OUT" "managed-policy --install"

    # lib missing from the installed layout -> WARN cannot determine, never PASS
    make_tree "$T/tree-nolib"
    rm -f "$T/tree-nolib/libexec/lib/managed-policy-status.sh"
    setcase ok
    doctor_run "$WH" "$T/tree-nolib"
    has "$WH doctor lib missing: WARN cannot determine" "$DOC_OUT" "cannot determine status (managed-policy-status.sh not available)"
    eq "$WH doctor lib missing: Passed=0" "0" "$(count_of Passed)"
    eq "$WH doctor lib missing: Warnings=1" "1" "$(count_of Warnings)"

    test_start "$WH doctor never called sudo"
    if [ ! -s "$SUDOLOG" ]; then test_pass; else test_fail "$(cat "$SUDOLOG")"; fi
done

# all-checks list + usage text
for pair in "bin:$BIN_DOCTOR" "libexec:$LIBEXEC_DOCTOR"; do
    WH="${pair%%:*}"; F="${pair#*:}"
    _all="$(awk '/^case "\$CHECK_COMPONENT" in/{f=1} f&&/^  all\)/{a=1;next} a&&/^    ;;/{exit} a{print}' "$F")"
    has "$WH doctor: all) arm runs check_managed_policy" "$_all" "check_managed_policy"
    _arm="$(awk '/^case "\$CHECK_COMPONENT" in/{f=1} f&&/^  managed-policy\)/{a=1;next} a&&/^    ;;/{exit} a{print}' "$F")"
    has "$WH doctor: managed-policy) arm dispatches check_managed_policy" "$_arm" "check_managed_policy"
    has "$WH doctor: usage lists managed-policy" "$(grep -n 'managed-policy  ' "$F")" "managed-policy"
done

# ════════════════════════════════════════════════════════════════════════════
# 3. Upgrade surface function under set -eo pipefail
# ════════════════════════════════════════════════════════════════════════════
extract_upgrade_fn() { # extract_upgrade_fn <upgrade.sh> <dest>
    sed -n '/^surface_managed_policy_status() {/,/^}/p' "$1" > "$2"
}
build_up_driver() { # build_up_driver <fn-file> <lib-ok true|false> <dest>
    cat > "$3" <<EOF
set -eo pipefail
print_info(){ echo "INFO: \$*"; }; print_success(){ echo "OK: \$*"; }; print_warning(){ echo "WARN: \$*"; }
WORKING_DIR="$T/atf"
_UPGRADE_MANAGED_POLICY_LIB_OK=$2
. "$LIB"
$(cat "$1")
surface_managed_policy_status
echo "CONTINUED rc=\$?"
EOF
}
extract_upgrade_fn "$UPGRADE" "$T/up-fn.sh"
test_start "upgrade: surface_managed_policy_status extracted (non-empty)"
if [ -s "$T/up-fn.sh" ]; then test_pass; else test_fail "function not found in $UPGRADE"; fi
build_up_driver "$T/up-fn.sh" true "$T/up.sh"

UP_OUT=""
up_run() { # up_run <shell> <driver> [extra env...]
    local sh="$1" drv="$2"; shift 2
    UP_OUT="$(env -i PATH="$T/stubbin:$SYSPATH" HOME="$T/home" TMPDIR="$T/tmp" CLAUDE_CONFIG_DIR="$T/home/.claude" "$@" "$sh" "$drv" 2>&1 </dev/null)"
}
for SH in $SHELLS; do
    TAG="[$(basename "$SH") $($SH -c 'echo ${BASH_VERSINFO[0]}')]"
    : > "$SUDOLOG"; : > "$STUBLOG"
    setcase absent
    up_run "$SH" "$T/up.sh"
    has "$TAG upgrade absent: WARN printed" "$UP_OUT" "WARN: Claude Code managed policy is NOT installed"
    has "$TAG upgrade absent: install command printed" "$UP_OUT" "$INSTALL_LINE"
    has "$TAG upgrade absent: returns 0 and continues" "$UP_OUT" "CONTINUED rc=0"
    setcase stale
    up_run "$SH" "$T/up.sh"
    has "$TAG upgrade stale: WARN printed" "$UP_OUT" "WARN: Claude Code managed policy is STALE"
    setcase ok
    up_run "$SH" "$T/up.sh"
    has "$TAG upgrade ok: success line" "$UP_OUT" "OK: Claude Code managed policy is installed and current"
    lacks "$TAG upgrade ok: no install command" "$UP_OUT" "--install"
    for c in rc2 garbage crash killed empty; do
        setcase $c
        up_run "$SH" "$T/up.sh"
        has "$TAG upgrade $c: does not abort (continues rc=0)" "$UP_OUT" "CONTINUED rc=0"
        has "$TAG upgrade $c: WARN cannot determine" "$UP_OUT" "WARN: Claude Code managed policy: cannot determine status"
        lacks "$TAG upgrade $c: never an OK line" "$UP_OUT" "OK: Claude Code managed policy"
    done
    setcase absent
    up_run "$SH" "$T/up.sh" CLAUDE_CONFIG_DIR="$T/stage"
    has "$TAG upgrade staged: INFO not checked" "$UP_OUT" "INFO: Claude Code managed policy: not checked"
    has "$TAG upgrade staged: continues" "$UP_OUT" "CONTINUED rc=0"
    build_up_driver "$T/up-fn.sh" false "$T/up-nolib.sh"
    up_run "$SH" "$T/up-nolib.sh"
    has "$TAG upgrade lib flag false: WARN cannot determine" "$UP_OUT" "WARN: Claude Code managed policy: cannot determine status (managed-policy-status.sh not available)"
    has "$TAG upgrade lib flag false: continues" "$UP_OUT" "CONTINUED rc=0"

    test_start "$TAG upgrade never invoked --install (stub argv log)"
    if ! grep -q -- '--install' "$STUBLOG"; then test_pass; else test_fail "$(cat "$STUBLOG")"; fi
    test_start "$TAG upgrade never called sudo (TTY-less)"
    if [ ! -s "$SUDOLOG" ]; then test_pass; else test_fail "$(cat "$SUDOLOG")"; fi
done

# static: the function body has no install / sudo; the call site lives in the success branch only
_fn="$(cat "$T/up-fn.sh")"
lacks "upgrade fn body: no sudo" "$_fn" "sudo "
lacks "upgrade fn body: no --install" "$_fn" "--install"
lacks "upgrade fn body: no read prompt" "$_fn" "read "

call_site_check() { # call_site_check <upgrade.sh> -> 0 when the call site is correct
    local f="$1" sum elif_l else_l call_l fi_l ncalls
    sum="$(grep -n '^print_section "Upgrade Complete"' "$f" | head -1 | cut -d: -f1)"
    [ -n "$sum" ] || return 1
    elif_l="$(awk -v s="$sum" 'NR>s && /^elif \[ "\$UPGRADE_BREW_FAILED" = true \]; then/{print NR; exit}' "$f")"
    [ -n "$elif_l" ] || return 1
    else_l="$(awk -v s="$elif_l" 'NR>s && /^else$/{print NR; exit}' "$f")"
    [ -n "$else_l" ] || return 1
    fi_l="$(awk -v s="$else_l" 'NR>s && /^fi$/{print NR; exit}' "$f")"
    [ -n "$fi_l" ] || return 1
    ncalls="$(grep -c '^  surface_managed_policy_status || true$' "$f")"
    [ "$ncalls" = "1" ] || return 1
    call_l="$(grep -n '^  surface_managed_policy_status || true$' "$f" | head -1 | cut -d: -f1)"
    [ "$call_l" -gt "$else_l" ] && [ "$call_l" -lt "$fi_l" ]
}
call_site_check "$UPGRADE"; ok "upgrade: single guarded call site, in the success else-branch after DRY_RUN and brew-failed branches" $?
test_start "upgrade: no other caller of surface_managed_policy_status"
_n="$(grep -c 'surface_managed_policy_status' "$UPGRADE")"
# definition + comment-free call: definition line, call line, header comment mentions? count non-comment lines
_n="$(grep -v '^[[:space:]]*#' "$UPGRADE" | grep -c 'surface_managed_policy_status')"
if [ "$_n" = "2" ]; then test_pass; else test_fail "expected definition + 1 call, found $_n"; fi

# ════════════════════════════════════════════════════════════════════════════
# 4. Delivery
# ════════════════════════════════════════════════════════════════════════════
ok "lib present at libexec/lib/managed-policy-status.sh" "$([ -f "$TAP_ROOT/libexec/lib/managed-policy-status.sh" ]; echo $?)"
has "Formula test asserts the lib ships" "$(cat "$FORMULA")" 'assert_path_exists libexec/"libexec/lib/managed-policy-status.sh"'
has "bin doctor sources from \$AITEAMFORGE_HOME/libexec/lib" "$(cat "$BIN_DOCTOR")" '$AITEAMFORGE_HOME/libexec/lib/managed-policy-status.sh'
has "libexec doctor sources from \${LIBEXEC_DIR}/lib" "$(cat "$LIBEXEC_DOCTOR")" '${LIBEXEC_DIR}/lib/managed-policy-status.sh'
has "upgrade sources from \${LIBEXEC_DIR}/lib" "$(cat "$UPGRADE")" '${LIBEXEC_DIR}/lib/managed-policy-status.sh'
# Installed layout resolves (tree = Cellar libexec shape): both doctors PASSed above from $T/tree and
# WARNed from $T/tree-nolib, which only differ by the file's presence.
test_start "installed-layout copy resolves the lib from every consumer path"
_ok=true
[ -f "$T/tree/libexec/lib/managed-policy-status.sh" ] || _ok=false
# bin doctor: $AITEAMFORGE_HOME/libexec/lib ; libexec doctor/upgrade: <libexec>/commands/../lib
[ -f "$T/tree/libexec/commands/../lib/managed-policy-status.sh" ] || _ok=false
if [ "$_ok" = true ]; then test_pass; else test_fail "lib not reachable in installed layout"; fi

# ════════════════════════════════════════════════════════════════════════════
# 4b. XACA-1624-017: hints stay copy-pasteable when AITEAMFORGE_DIR has a space or a quote
# ════════════════════════════════════════════════════════════════════════════
QDIR="$T/at f'x"
mkdir -p "$QDIR/scripts"
cp "$T/atf/scripts/kb-sync-plugins" "$QDIR/scripts/kb-sync-plugins"
# qhint_tool <hint>: the argv word after `python3` on the Install: line, as a shell would parse it
qhint_tool() {
    local line
    line="$(printf '%s\n' "$1" | sed -n 's/^Install: //p' | head -1)"
    [ -n "$line" ] || return 1
    bash -c 'eval "set -- $1"; printf "%s|%s|%s" "$1" "$2" "$#"' _ "$line"
}
for SH in $SHELLS; do
    TAG="[$(basename "$SH") $($SH -c 'echo ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}')]"
    echo absent > "$QDIR/scripts/case"
    mp_eval "$SH" "$LIB" "$QDIR" "$T/home/.claude"
    eq "$TAG quoted dir: absent -> ACTION" "ACTION" "$MP_V"
    eq "$TAG quoted dir: the pasted install command parses to python3 + the real tool path (4 words)" \
        "python3|$QDIR/scripts/kb-sync-plugins|4" "$(qhint_tool "$MP_H")"
    setcase absent
    mp_eval "$SH" "$LIB" "$T/atf" "$T/home/.claude"
    eq "$TAG plain dir: the install line is printed unquoted (unchanged)" \
        "$INSTALL_LINE" "$(printf '%s\n' "$MP_H" | sed -n 's/^Install: //p' | head -1)"
done

# ════════════════════════════════════════════════════════════════════════════
# 5. Mutation sentinels (IN-FILE, on temp copies; each proves its sed changed the file)
# ════════════════════════════════════════════════════════════════════════════
mutate() { # mutate <src> <dest> <sed-expr>  -> 0 only when the copy differs from the source
    sed "$3" "$1" > "$2"
    if cmp -s "$1" "$2"; then return 1; fi
    chmod +x "$2" 2>/dev/null
    return 0
}
mutate_lib() { # mutate_lib <name> <sed-expr> -> sets MUT_LIB, returns 0 if sed matched
    MUT_LIB="$T/mut-$1.sh"
    mutate "$LIB" "$MUT_LIB" "$2"
}

# (a) loosen the rc/status agreement: OK accepted for any rc
mutate_lib a 's/^    OK:0)/    OK:*)/'; ok "sentinel (a): sed matched" $?
setcase rc3ok; mp_eval "$BASH3" "$MUT_LIB" "$T/atf" "$T/home/.claude"
test_start "sentinel (a): rc3+OK row goes RED (mutant returns OK, pristine returns UNKNOWN)"
if [ "$MP_V" = "OK" ]; then test_pass; else test_fail "mutant verdict=$MP_V (sentinel is not sensitive)"; fi
setcase rc3ok; mp_eval "$BASH3" "$LIB" "$T/atf" "$T/home/.claude"
eq "sentinel (a): pristine control rc3+OK = UNKNOWN" "UNKNOWN" "$MP_V"

# (b) drop the line-1 strictness: the status may sit on any line
mutate_lib b 's/^    "POLICY_STATUS=OK path="?\*)/    *"POLICY_STATUS=OK path="?*)/;s/^  line1=.*$/  line1="$out"/'; ok "sentinel (b): sed matched" $?
setcase notfirst; mp_eval "$BASH3" "$MUT_LIB" "$T/atf" "$T/home/.claude"
test_start "sentinel (b): status-not-on-line-1 row goes RED (mutant returns OK)"
if [ "$MP_V" = "OK" ]; then test_pass; else test_fail "mutant verdict=$MP_V (sentinel is not sensitive)"; fi
setcase notfirst; mp_eval "$BASH3" "$LIB" "$T/atf" "$T/home/.claude"
eq "sentinel (b): pristine control notfirst = UNKNOWN" "UNKNOWN" "$MP_V"

# (c) UNKNOWN mapped to PASS in ONE doctor; the other doctor must stay green
for WH in bin libexec; do
    make_tree "$T/tree-c-$WH"
    if [ "$WH" = bin ]; then M="$T/tree-c-$WH/bin/aiteamforge-doctor.sh"; else M="$T/tree-c-$WH/libexec/commands/aiteamforge-doctor.sh"; fi
    cp "$M" "$M.orig"
    sed -i.bak 's/^    OK) check_result pass "\$ATF_MP_SUMMARY" ;;/    OK|UNKNOWN) check_result pass "$ATF_MP_SUMMARY" ;;/' "$M"
    test_start "sentinel (c) $WH: sed matched"
    if ! cmp -s "$M" "$M.orig"; then test_pass; else test_fail "sed did not change $M"; fi
    setcase rc2
    doctor_run "$WH" "$T/tree-c-$WH"
    test_start "sentinel (c) $WH: rc2 row goes RED (mutant doctor PASSes an unreadable status)"
    if [ "$(count_of Passed)" = "1" ]; then test_pass; else test_fail "Passed=$(count_of Passed) (sentinel is not sensitive)"; fi
    OTHER=libexec; [ "$WH" = libexec ] && OTHER=bin
    doctor_run "$OTHER" "$T/tree-c-$WH"
    eq "sentinel (c) $WH: the OTHER doctor ($OTHER, unmutated in this tree) still Passed=0 on rc2" "0" "$(count_of Passed)"
done

# (d1) upgrade function that installs / calls sudo
mutate "$UPGRADE" "$T/up-d1.sh" 's/^      print_warning "\$ATF_MP_SUMMARY"$/      print_warning "$ATF_MP_SUMMARY"; python3 "${WORKING_DIR}\/scripts\/kb-sync-plugins" managed-policy --install || true; sudo true || true/'
ok "sentinel (d1): sed matched" $?
extract_upgrade_fn "$T/up-d1.sh" "$T/up-d1-fn.sh"
build_up_driver "$T/up-d1-fn.sh" true "$T/up-d1-drv.sh"
: > "$SUDOLOG"; : > "$STUBLOG"; setcase absent
up_run "$BASH3" "$T/up-d1-drv.sh"
test_start "sentinel (d1): install/sudo violation goes RED (mutant leaves --install in argv log and a sudo call)"
if grep -q -- '--install' "$STUBLOG" && [ -s "$SUDOLOG" ]; then test_pass; else test_fail "stub=$(cat "$STUBLOG") sudo=$(cat "$SUDOLOG")"; fi
_fn1="$(cat "$T/up-d1-fn.sh")"
test_start "sentinel (d1): static no-install/no-sudo assertion would also catch it"
case "$_fn1" in *"--install"*) test_pass ;; *) test_fail "mutant body lacks --install" ;; esac

# (d2) function no longer returns 0 -> aborts the upgrade under set -e
mutate "$UPGRADE" "$T/up-d2.sh" '/^surface_managed_policy_status() {/,/^}/ s/^  return 0$/  return 1/'
ok "sentinel (d2): sed matched" $?
extract_upgrade_fn "$T/up-d2.sh" "$T/up-d2-fn.sh"
build_up_driver "$T/up-d2-fn.sh" true "$T/up-d2-drv.sh"
setcase absent
up_run "$BASH3" "$T/up-d2-drv.sh"
test_start "sentinel (d2): non-zero return goes RED (mutant never reaches CONTINUED rc=0)"
case "$UP_OUT" in *"CONTINUED rc=0"*) test_fail "mutant still continued (sentinel is not sensitive)" ;; *) test_pass ;; esac

# (d3) call site loses `|| true`
mutate "$UPGRADE" "$T/up-d3.sh" 's/^  surface_managed_policy_status || true$/  surface_managed_policy_status/'
ok "sentinel (d3): sed matched" $?
test_start "sentinel (d3): call-site check goes RED when the guard is removed"
if call_site_check "$T/up-d3.sh"; then test_fail "call_site_check still passes (sentinel is not sensitive)"; else test_pass; fi
# (d4) call site moved out of the success branch (placed before the summary)
mutate "$UPGRADE" "$T/up-d4.sh" 's/^  surface_managed_policy_status || true$/  : moved/;s/^print_section "Upgrade Complete"$/surface_managed_policy_status || true\nprint_section "Upgrade Complete"/'
ok "sentinel (d4): sed matched" $?
test_start "sentinel (d4): call-site check goes RED when the call runs outside the success branch"
if call_site_check "$T/up-d4.sh"; then test_fail "call_site_check still passes (sentinel is not sensitive)"; else test_pass; fi

# (e) XACA-1624-017: drop the quoting -> the space/quote row goes RED
mutate_lib e 's/^    \*\[!A-Za-z0-9_\.\/~+:@%=-\]\*|"") printf .*# GUARD:mp-shq$/    __never__) : ;;  # GUARD:mp-shq/'; ok "sentinel (e): sed matched" $?
echo absent > "$QDIR/scripts/case"
mp_eval "$BASH3" "$MUT_LIB" "$QDIR" "$T/home/.claude"
test_start "sentinel (e): unquoted hint goes RED (pasted command no longer parses to the real path)"
if [ "$(qhint_tool "$MP_H")" = "python3|$QDIR/scripts/kb-sync-plugins|4" ]; then test_fail "mutant still parses correctly (sentinel is not sensitive)"; else test_pass; fi

# ════════════════════════════════════════════════════════════════════════════
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "XACA-1624 managed-policy surfacing: $_PASS_COUNT passed, $_FAIL_COUNT failed"
    [ "$_FAIL_COUNT" -eq 0 ]
fi
