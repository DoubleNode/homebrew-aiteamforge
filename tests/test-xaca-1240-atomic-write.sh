#!/bin/bash
# test-xaca-1240-atomic-write.sh
# Unit coverage for _aitf_atomic_write_script (libexec/lib/atomic-write.sh),
# XACA-1240 gate finding: when <dst> is a SYMLINK the temp+rename must write
# THROUGH the link (old `> "$dst"` semantics), not replace the link with a
# regular file and leave the real target stale.
#
# Cases: symlinked dst, relative link in another dir, 2-hop chain, dangling link
# (documented: link replaced at the original path), cycle (same), failing cmd
# (dst untouched, temp removed, rc != 0), mode preservation, default mode 755,
# plain-file regression.
#
# Sandboxed to TEST_TMP_DIR; never touches the real HOME.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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
    TEST_TMP_DIR="$(mktemp -d -t xaca1240-aw.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
_aw_cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap _aw_cleanup EXIT

SBX="$TEST_TMP_DIR/xaca1240-aw"
mkdir -p "$SBX/home"
export AITEAMFORGE_DIR="$SBX/aiteamforge"
export HOME="$SBX/home"
unset TMUX TMUX_PANE

# shellcheck source=../libexec/lib/atomic-write.sh
source "$ATOMIC_SH"

_inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }
_mode()  { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
_leftovers() { find "$@" -maxdepth 1 -name '.*.??????' 2>/dev/null | wc -l | tr -d ' '; }

_N=0
_fresh() { _N=$((_N + 1)); D="$SBX/c$_N"; mkdir -p "$D"; }

# ── symlinked dst, same dir ──────────────────────────────────────────────────
_fresh; mkdir "$D/real"
printf 'old\n' > "$D/real/target.sh"; chmod 751 "$D/real/target.sh"
ln -s real/target.sh "$D/link.sh"
ino_before="$(_inode "$D/real/target.sh")"
_aitf_atomic_write_script "$D/link.sh" printf 'new\n'; rc=$?
test_start "symlink dst: link kept, target updated, new inode, mode kept, no temps"
if [ "$rc" -eq 0 ] && [ -L "$D/link.sh" ] && [ "$(readlink "$D/link.sh")" = "real/target.sh" ] \
   && [ "$(cat "$D/real/target.sh")" = "new" ] \
   && [ "$(_inode "$D/real/target.sh")" != "$ino_before" ] \
   && [ "$(_mode "$D/real/target.sh")" = "751" ] \
   && [ "$(_leftovers "$D" "$D/real")" = "0" ]; then test_pass
else test_fail "rc=$rc content=$(cat "$D/real/target.sh") mode=$(_mode "$D/real/target.sh") temps=$(_leftovers "$D" "$D/real")"; fi

# ── relative link into another dir; cwd must not matter ──────────────────────
_fresh; mkdir -p "$D/bin" "$D/lib/deep"
printf 'old\n' > "$D/lib/deep/t.sh"; chmod 755 "$D/lib/deep/t.sh"
ln -s ../lib/deep/t.sh "$D/bin/t.sh"
(cd / && _aitf_atomic_write_script "$D/bin/t.sh" printf 'rel\n'); rc=$?
test_start "relative symlink in another dir resolves against the LINK's dir (cwd-independent)"
if [ "$rc" -eq 0 ] && [ -L "$D/bin/t.sh" ] && [ "$(cat "$D/lib/deep/t.sh")" = "rel" ] \
   && [ "$(_leftovers "$D/bin" "$D/lib/deep")" = "0" ]; then test_pass
else test_fail "rc=$rc content=$(cat "$D/lib/deep/t.sh") temps=$(_leftovers "$D/bin" "$D/lib/deep")"; fi

# ── 2-hop chain (relative then absolute) ─────────────────────────────────────
_fresh; mkdir -p "$D/a" "$D/b" "$D/c"
printf 'old\n' > "$D/c/real.sh"
ln -s "$D/c/real.sh" "$D/b/hop2.sh"
ln -s ../b/hop2.sh "$D/a/hop1.sh"
_aitf_atomic_write_script "$D/a/hop1.sh" printf 'chain\n'; rc=$?
test_start "2-hop symlink chain: both links kept, final target updated"
if [ "$rc" -eq 0 ] && [ -L "$D/a/hop1.sh" ] && [ -L "$D/b/hop2.sh" ] \
   && [ "$(cat "$D/c/real.sh")" = "chain" ] \
   && [ "$(_leftovers "$D/a" "$D/b" "$D/c")" = "0" ]; then test_pass
else test_fail "rc=$rc content=$(cat "$D/c/real.sh") temps=$(_leftovers "$D/a" "$D/b" "$D/c")"; fi

# ── dangling link: documented behavior = link replaced at the original path ──
_fresh
ln -s nowhere.sh "$D/dangle.sh"
_aitf_atomic_write_script "$D/dangle.sh" printf 'd\n'; rc=$?
test_start "dangling symlink: replaced by a regular file at the original path (documented)"
if [ "$rc" -eq 0 ] && [ ! -L "$D/dangle.sh" ] && [ -f "$D/dangle.sh" ] \
   && [ "$(cat "$D/dangle.sh")" = "d" ] && [ ! -e "$D/nowhere.sh" ] \
   && [ "$(_leftovers "$D")" = "0" ]; then test_pass
else test_fail "rc=$rc"; fi

# ── cycle: bounded, same documented fallback ─────────────────────────────────
_fresh
ln -s y.sh "$D/x.sh"; ln -s x.sh "$D/y.sh"
_aitf_atomic_write_script "$D/x.sh" printf 'cyc\n'; rc=$?
test_start "symlink cycle: terminates, link replaced at the original path"
if [ "$rc" -eq 0 ] && [ ! -L "$D/x.sh" ] && [ "$(cat "$D/x.sh")" = "cyc" ] \
   && [ "$(_leftovers "$D")" = "0" ]; then test_pass
else test_fail "rc=$rc"; fi

# ── failing cmd: dst untouched, temp removed, rc != 0 (via link AND plain) ───
_fresh; mkdir "$D/real"
printf 'keep\n' > "$D/real/t.sh"; ln -s real/t.sh "$D/l.sh"; printf 'plain\n' > "$D/p.sh"
ino_t="$(_inode "$D/real/t.sh")"; ino_p="$(_inode "$D/p.sh")"
_aitf_atomic_write_script "$D/l.sh" sh -c 'echo partial; exit 3'; rc1=$?
_aitf_atomic_write_script "$D/p.sh" sh -c 'echo partial; exit 3'; rc2=$?
test_start "failing cmd: rc != 0, dst and target untouched, no temp left"
if [ "$rc1" -ne 0 ] && [ "$rc2" -ne 0 ] && [ -L "$D/l.sh" ] \
   && [ "$(cat "$D/real/t.sh")" = "keep" ] && [ "$(cat "$D/p.sh")" = "plain" ] \
   && [ "$(_inode "$D/real/t.sh")" = "$ino_t" ] && [ "$(_inode "$D/p.sh")" = "$ino_p" ] \
   && [ "$(_leftovers "$D" "$D/real")" = "0" ]; then test_pass
else test_fail "rc1=$rc1 rc2=$rc2 temps=$(_leftovers "$D" "$D/real")"; fi

# ── mode: existing mode kept (+x added), brand-new dst defaults to 755 ───────
_fresh
printf 'x\n' > "$D/m.sh"; chmod 640 "$D/m.sh"
_aitf_atomic_write_script "$D/m.sh" printf 'm\n'; rc1=$?
_aitf_atomic_write_script "$D/fresh.sh" printf 'f\n'; rc2=$?
m1="$(_mode "$D/m.sh")"; m2="$(_mode "$D/fresh.sh")"
test_start "mode: existing 640 keeps its bits and gains +x; new dst -> 755"
case "$m1" in 7[45]*|6[45]*) m1_ok=1 ;; *) m1_ok=0 ;; esac
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$m1_ok" = 1 ] && [ -x "$D/m.sh" ] \
   && [ "$m2" = "755" ]; then test_pass
else test_fail "m1=$m1 m2=$m2 rc1=$rc1 rc2=$rc2"; fi

# ── plain file regression: new inode, content replaced ───────────────────────
_fresh
printf 'old\n' > "$D/r.sh"; ino="$(_inode "$D/r.sh")"
_aitf_atomic_write_script "$D/r.sh" printf 'new\n'; rc=$?
test_start "plain file: content replaced via NEW inode, no temps"
if [ "$rc" -eq 0 ] && [ "$(cat "$D/r.sh")" = "new" ] && [ "$(_inode "$D/r.sh")" != "$ino" ] \
   && [ "$(_leftovers "$D")" = "0" ]; then test_pass
else test_fail "rc=$rc"; fi

# ── directory dst (and a link to one): fail loudly, write nothing (PR #1056 -017) ─
_fresh; mkdir "$D/dir" "$D/real"
ln -s real "$D/dlink"
_aitf_atomic_write_script "$D/dir" printf 'x\n'; rc1=$?
_aitf_atomic_write_script "$D/dlink" printf 'x\n'; rc2=$?
test_start "directory dst / link to directory: rc != 0, nothing written inside, link kept"
if [ "$rc1" -ne 0 ] && [ "$rc2" -ne 0 ] && [ -d "$D/dir" ] && [ -L "$D/dlink" ] \
   && [ -z "$(ls -A "$D/dir")" ] && [ -z "$(ls -A "$D/real")" ] \
   && [ "$(_leftovers "$D" "$D/dir" "$D/real")" = "0" ]; then test_pass
else test_fail "rc1=$rc1 rc2=$rc2 dir=[$(ls -A "$D/dir")] real=[$(ls -A "$D/real")]"; fi

if [ "$_STANDALONE" = true ]; then
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -eq 0 ]
    exit $?
fi
