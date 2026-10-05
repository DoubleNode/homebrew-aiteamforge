#!/bin/bash

# test-xaca-1240-self-rewrite.sh
# Regression test for XACA-1240: `aiteamforge upgrade` rewrote the RUNNING
# ~/aiteamforge/scripts/auto-upgrade.sh in place.
#
# REGRESSION INTENT: update_aux_scripts -> _xaca0608_render_team_script used to
# write `sed ... "$src" > "$dst"`, i.e. truncate + rewrite the SAME inode. When
# $dst is the script that is executing the upgrade (auto-upgrade.sh,
# cellar-watch-trigger.sh), bash resumes at its old byte offset inside the new,
# longer content and dies with a syntax error (launchd rc 2, no completion
# marker). The fix (_aitf_atomic_write_script: temp file + mv -f) swaps in a NEW
# inode, so the running process keeps its open fd on the old one.
#
# The driver is deliberately OLD-SHAPE (top-level code, NOT wrapped in main() with
# a trailing `main "$@"; exit $?`), which isolates the WRITER fix from the
# defence-in-depth wrapper (XACA-1240-004).
#
# Cases (each runs the identical driver flow; only the renderer differs):
#   POSITIVE  real update_aux_scripts + real renderer from the tap
#             -> rc 0, marker printed, content replaced, inode changed, no temps.
#   NEG-OLD   same flow, renderer = inline copy of the PRE-FIX in-place body
#             (inline, not `git show`, so shallow CI clones stay deterministic)
#             -> must FAIL: rc != 0, no marker, inode unchanged.
#   NEG-MUT   same flow, real tap file but with the atomic helper call mutated
#             back to `> "$dst"` in a scratch copy -> must FAIL (proves the
#             positive case really depends on the helper, not coincidence).
#
# All filesystem activity is sandboxed to TEST_TMP_DIR. The child drives the
# REAL update_aux_scripts (extracted by awk) with FRAMEWORK_DIR/WORKING_DIR
# pointed into the sandbox. NEVER touches real $HOME / ~/aiteamforge.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
ATOMIC_SH="$TAP_ROOT/libexec/lib/atomic-write.sh"

_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1240-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

# Sandbox BEFORE anything else; strip tmux; never touch the real HOME.
SBX="$TEST_TMP_DIR/xaca1240"
mkdir -p "$SBX/home"
export AITEAMFORGE_DIR="$SBX/aiteamforge"
export HOME="$SBX/home"
unset TMUX TMUX_PANE

# Portable inode (GNU first: on BSD `stat -c` fails, on GNU `stat -f` is fs info).
_inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }

# ── Pre-fix renderer: the in-place body from before f03b44f6 (inline copy). ──
OLD_RENDERER="$SBX/old-renderer.sh"
cat > "$OLD_RENDERER" <<'OLD'
_xaca0608_render_team_script() {
  local src="$1" dst="$2"
  sed -e "s|~/dev-team|${WORKING_DIR}|g" "$src" > "$dst"   # SAME inode (the bug)
  chmod +x "$dst"
}
OLD

# ── Mutant: real tap file, atomic helper call reverted to the redirect. ──────
MUTANT_SH="$SBX/upgrade-mutant.sh"
awk '
  /^_xaca0608_render_team_script\(\) \{/ { inr=1 }
  inr && /_aitf_atomic_write_script "\$dst" sed -e/ { sub(/_aitf_atomic_write_script "\$dst" sed -e/, "sed -e") }
  inr && /^      "\$src"$/ { print "      \"$src\" > \"$dst\""; next }
  inr && /^}$/ { inr=0 }
  { print }
' "$UPGRADE_SH" > "$MUTANT_SH"

# ── Child: loads the REAL update_aux_scripts path and renders onto the driver ─
CHILD="$SBX/child.sh"
cat > "$CHILD" <<'CHILD_EOF'
#!/bin/bash
# usage: child.sh <upgrade-sh> <atomic-write.sh> <renderer-override-or-empty>
UP="$1"; ATOMIC="$2"; OVERRIDE="$3"
unset TMUX TMUX_PANE
FORCE=true; DRY_RUN=false
for _p in print_section print_info print_success print_warning print_error; do eval "${_p}() { :; }"; done
. "$ATOMIC"
_ex() { # $1 fn: header through first column-0 closing brace
  awk -v fn="$1" '$0 ~ ("^" fn "\\(\\) \\{") {c=1} c {print} c && /^}$/ {exit}' "$UP"
}
for fn in _xaca0608_render_team_script _xaca0608_aux_script_map \
          _xaca1143_aux_mandatory_materialize_basenames update_aux_scripts; do
  src="$(_ex "$fn")"
  [ -n "$src" ] || { echo "CHILD-FATAL: cannot extract $fn" >&2; exit 90; }
  eval "$src"
done
[ -z "$OVERRIDE" ] || . "$OVERRIDE"
update_aux_scripts
CHILD_EOF

# Run one scenario. Sets R_RC R_OUT R_MARK R_INODE_CHANGED R_REPLACED R_TEMPS.
run_scenario() {
    local name="$1" up="$2" override="$3"
    local base="$SBX/$name"
    local wd="$base/aiteamforge"
    local fw="$base/framework"
    mkdir -p "$wd/scripts" "$fw/share/scripts"

    # LONGER replacement template for the driver's own path. Every line carries
    # stray `fi` closers, so a resume at ANY offset (line start or mid-line --
    # the offset depends on the sandbox path length) is a syntax error, as in
    # the field failure. The template is never executed in the positive case.
    {
        echo '#!/bin/bash'
        echo 'echo "NEW-VERSION-HEAD"'
        local i
        for i in $(seq 1 40); do
            echo "echo NEW-BLOCK-$i ; fi ; fi ; fi   # new longer content"
        done
        echo 'echo "NEW-VERSION-TAIL"'
    } > "$fw/share/scripts/auto-upgrade.sh"

    # OLD-SHAPE driver: top-level code, no main() wrapper.
    local driver="$wd/scripts/auto-upgrade.sh" pad="" i
    for i in $(seq 1 12); do
        pad="$pad# padding line $i ..............................................
"
    done
    cat > "$driver" <<EOF
#!/bin/bash
echo "===== auto-upgrade start ====="
$pad
WORKING_DIR="$wd" FRAMEWORK_DIR="$fw" "$BASH" "$CHILD" "$up" "$ATOMIC_SH" "$override"
echo "child rc=\$?"
echo "more line 1"
echo "more line 2"
echo "more line 3"
echo "===== auto-upgrade complete ====="
EOF
    chmod 755 "$driver"

    local i0 i1
    i0="$(_inode "$driver")"
    # capture-first: rc must be the driver's, not a pipeline's
    R_OUT="$(cd "$base" && env -u TMUX -u TMUX_PANE HOME="$HOME" AITEAMFORGE_DIR="$AITEAMFORGE_DIR" "$BASH" "$driver" 2>&1)"
    R_RC=$?
    i1="$(_inode "$driver")"
    R_INODE_CHANGED=no; [ "$i0" != "$i1" ] && R_INODE_CHANGED=yes
    R_MARK=no; case "$R_OUT" in *"===== auto-upgrade complete ====="*) R_MARK=yes ;; esac
    R_REPLACED=no; grep -q 'NEW-VERSION-TAIL' "$driver" 2>/dev/null && R_REPLACED=yes
    R_TEMPS="$(find "$wd/scripts" -maxdepth 1 -name '.auto-upgrade.sh.*' 2>/dev/null | wc -l | tr -d ' ')"
    echo "     [$name] rc=$R_RC marker=$R_MARK replaced=$R_REPLACED inode_changed=$R_INODE_CHANGED temps=$R_TEMPS"
}

# ═══ Sanity: extraction + mutant really differ ═══════════════════════════════
test_start "Sanity: mutant differs from the real tap file and real renderer uses the helper"
if cmp -s "$UPGRADE_SH" "$MUTANT_SH"; then
    test_fail "mutation did not change the upgrade script (sentinel would be vacuous)"
elif ! grep -q '"\$src" > "\$dst"' "$MUTANT_SH"; then
    test_fail "mutant lacks the in-place redirect"
elif ! grep -q '_aitf_atomic_write_script "\$dst" sed' "$UPGRADE_SH"; then
    test_fail "real renderer does not call _aitf_atomic_write_script"
else
    test_pass
fi

# ═══ POSITIVE ════════════════════════════════════════════════════════════════
run_scenario positive "$UPGRADE_SH" ""
test_start "POSITIVE: driver survives its own rewrite (rc 0, completion marker printed)"
if [ "$R_RC" -eq 0 ] && [ "$R_MARK" = yes ]; then test_pass
else test_fail "rc=$R_RC marker=$R_MARK output: $R_OUT"; fi

test_start "POSITIVE: destination content actually replaced with the new template"
if [ "$R_REPLACED" = yes ]; then test_pass; else test_fail "new content not present at dst"; fi

test_start "POSITIVE: destination got a NEW inode (atomic rename)"
if [ "$R_INODE_CHANGED" = yes ]; then test_pass; else test_fail "inode unchanged"; fi

test_start "POSITIVE: no .auto-upgrade.sh.* temp files left behind"
if [ "$R_TEMPS" = 0 ]; then test_pass; else test_fail "$R_TEMPS temp file(s) remain"; fi

# ═══ NEGATIVE CONTROL: pre-fix in-place body ═════════════════════════════════
run_scenario negold "$UPGRADE_SH" "$OLD_RENDERER"
test_start "NEG-OLD: pre-fix in-place renderer FAILS (rc != 0, no marker)"
if [ "$R_RC" -ne 0 ] && [ "$R_MARK" = no ]; then test_pass
else test_fail "old renderer unexpectedly survived: rc=$R_RC marker=$R_MARK (test is vacuous)"; fi

test_start "NEG-OLD: in-place variant kept the SAME inode"
if [ "$R_INODE_CHANGED" = no ] && [ "$R_REPLACED" = yes ]; then test_pass
else test_fail "inode_changed=$R_INODE_CHANGED replaced=$R_REPLACED"; fi

# ═══ MUTATION: real tap file with the helper call reverted ═══════════════════
run_scenario mutant "$MUTANT_SH" ""
test_start "NEG-MUT: reverting the helper call in a scratch copy makes the flow FAIL"
if [ "$R_RC" -ne 0 ] && [ "$R_MARK" = no ] && [ "$R_INODE_CHANGED" = no ]; then test_pass
else test_fail "mutant survived: rc=$R_RC marker=$R_MARK inode_changed=$R_INODE_CHANGED"; fi

if [ "$_STANDALONE" = true ]; then
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -eq 0 ]
    exit $?
fi
