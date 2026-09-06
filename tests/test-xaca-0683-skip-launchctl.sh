#!/bin/bash

# test-xaca-0683-skip-launchctl.sh
# XACA-0683: bare `launchctl` load/unload/bootstrap/bootout calls in the
# installer + lifecycle scripts are routed through the `_aitf_launchctl`
# wrapper, which no-ops (returns 0 without touching the GUI domain) when
# AITEAMFORGE_SKIP_LAUNCHCTL=1. The wrapper's single canonical home is
# libexec/lib/common.sh (XACA-0682 originally inlined it in two scripts;
# XACA-0683 converged it and routed the remaining scripts).
#
# This guards four things:
#   1. The wrapper is defined exactly once, in common.sh.
#   2. The wrapper honors AITEAMFORGE_SKIP_LAUNCHCTL (skip vs pass-through).
#   3. No EXECUTED bare mutating `launchctl` call survives in the guarded
#      scripts (sibling-drift / regression guard).
#   4. XACA-1097 review finding (PR #824, subitem 19): AITEAMFORGE_SKIP_LAUNCHCTL=1
#      does NOT cover the whole LaunchAgents load seam any more. See the test
#      block below for the full contract this now documents/locks in.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_LIB="$TAP_ROOT/libexec/lib/common.sh"

# Scripts that XACA-0682 + XACA-0683 guard. Paths are relative to TAP_ROOT.
GUARDED_SCRIPTS=(
  "libexec/lib/validate-install.sh"
  "libexec/installers/install-kanban.sh"
  "libexec/installers/install-fleet-monitor.sh"
  "bin/aiteamforge-setup.sh"
  "libexec/commands/aiteamforge-start.sh"
  "libexec/commands/aiteamforge-stop.sh"
  "libexec/commands/aiteamforge-upgrade.sh"
  "libexec/commands/aiteamforge-migrate.sh"
  "libexec/commands/aiteamforge-uninstall.sh"
  "libexec/commands/aiteamforge-doctor.sh"
)

# ─── 1. Wrapper defined exactly once, in common.sh ───────────────────────────
test_start "wrapper _aitf_launchctl is defined exactly once (canonical: common.sh)"
def_count=0
def_locations=""
while IFS= read -r line; do
  def_count=$((def_count + 1))
  def_locations="$def_locations $line"
done < <(grep -rln "_aitf_launchctl()" "$TAP_ROOT/libexec" "$TAP_ROOT/bin" 2>/dev/null)
assert_equal "1" "$def_count" "exactly one _aitf_launchctl() definition (found:$def_locations)"
assert_contains "$def_locations" "libexec/lib/common.sh" "the one definition lives in common.sh"
test_pass

# ─── 2a. SKIP=1 → no-op, returns 0, never calls real launchctl ───────────────
test_start "AITEAMFORGE_SKIP_LAUNCHCTL=1 suppresses mutating launchctl (no pass-through)"
mock_dir="$TEST_TMP_DIR/skip-mock-bin"
mock_log="$TEST_TMP_DIR/skip-launchctl.log"
mkdir -p "$mock_dir"
cat > "$mock_dir/launchctl" <<EOF
#!/bin/bash
echo "launchctl \$*" >> "$mock_log"
EOF
chmod +x "$mock_dir/launchctl"

: > "$mock_log"
skip_rc=0
PATH="$mock_dir:$PATH" AITEAMFORGE_SKIP_LAUNCHCTL=1 bash -c "
  source '$COMMON_LIB'
  _aitf_launchctl load /tmp/xaca0683.plist
" || skip_rc=$?
assert_equal "0" "$skip_rc" "wrapper returns 0 under SKIP=1"
# Log file exists (we truncated it) but MUST be empty — no real launchctl ran.
skip_log_contents="$(cat "$mock_log" 2>/dev/null)"
assert_empty "$skip_log_contents" "real launchctl was NOT invoked under SKIP=1"
test_pass

# ─── 2b. SKIP unset → passes through to real launchctl ───────────────────────
test_start "wrapper passes through to launchctl when AITEAMFORGE_SKIP_LAUNCHCTL is unset"
: > "$mock_log"
PATH="$mock_dir:$PATH" bash -c "
  unset AITEAMFORGE_SKIP_LAUNCHCTL
  source '$COMMON_LIB'
  _aitf_launchctl unload /tmp/xaca0683.plist
"
passthru_log="$(cat "$mock_log" 2>/dev/null)"
assert_contains "$passthru_log" "unload /tmp/xaca0683.plist" "real launchctl invoked when guard not set"
test_pass

# ─── 2c. SKIP=0 (any value other than exactly "1") → passes through ──────────
test_start "only the exact value 1 skips (SKIP=0 still passes through)"
: > "$mock_log"
PATH="$mock_dir:$PATH" AITEAMFORGE_SKIP_LAUNCHCTL=0 bash -c "
  source '$COMMON_LIB'
  _aitf_launchctl load /tmp/xaca0683.plist
"
zero_log="$(cat "$mock_log" 2>/dev/null)"
assert_contains "$zero_log" "load /tmp/xaca0683.plist" "SKIP=0 does NOT skip"
test_pass

# ─── 3. No EXECUTED bare mutating launchctl survives in guarded scripts ──────
# Heuristic: strip comments (#…) and double-quoted strings, then look for a
# `launchctl <mutating-verb>` token at a command position (not preceded by a
# word char, so the converted `_aitf_launchctl` calls are excluded). Read-only
# `launchctl list` and user-facing "Run: launchctl load …" strings are ignored.
test_start "no executed bare mutating launchctl remains in guarded scripts"
offenders=""
for rel in "${GUARDED_SCRIPTS[@]}"; do
  f="$TAP_ROOT/$rel"
  [ -f "$f" ] || { offenders="$offenders [missing:$rel]"; continue; }
  hit="$(sed -e 's/#.*//' -e 's/"[^"]*"//g' "$f" \
        | grep -nE '(^|[^_[:alnum:]])launchctl[[:space:]]+(load|unload|bootstrap|bootout|enable|disable|kickstart)' || true)"
  if [ -n "$hit" ]; then
    offenders="$offenders\n  $rel:\n$hit"
  fi
done
assert_empty "$offenders" "every mutating launchctl call routes through _aitf_launchctl"
test_pass

# ─── 4. validate-install.sh resolves the wrapper when sourced standalone ─────
# It is a standalone-sourceable lib (does not go through common.sh's callers),
# so it must pull common.sh itself to obtain the wrapper.
test_start "validate-install.sh obtains _aitf_launchctl when sourced standalone"
standalone_out="$(cd "$TAP_ROOT/libexec/lib" && bash -c \
  'source ./validate-install.sh 2>/dev/null; type _aitf_launchctl >/dev/null 2>&1 && echo OK || echo MISSING')"
assert_equal "OK" "$standalone_out" "wrapper resolves via validate-install.sh standalone source"
test_pass

# ─── 5. XACA-1097 (PR #824, review subitem 19): SKIP=1 no longer covers the
#        WHOLE LaunchAgents load seam ─────────────────────────────────────────
#
# _val_check_launchagents() (libexec/lib/validate-install.sh) verifies the
# actual POST-CONDITION of a load attempt via _xaca0734_launchctl_is_loaded()
# and classifies a disabled service up front via
# _xaca1097_launchctl_is_disabled() (both in libexec/lib/launchagents.sh).
# Both of those call `launchctl list` / `launchctl print-disabled` DIRECTLY —
# by design (they are read-only; see each function's own header comment) —
# rather than through the _aitf_launchctl wrapper this whole file is about.
#
# That is an intentional, pre-existing design choice for `list`/`print`, but
# it has a consequence XACA-1097 introduced without documenting: under
# AITEAMFORGE_SKIP_LAUNCHCTL=1, `_aitf_launchctl load "$plist"` now correctly
# no-ops (covered above), but the POST-CONDITION check that follows it is NOT
# skipped — it queries the REAL launchctl. Before XACA-1097, the auto-fix
# branch trusted `load`'s exit code directly, so under SKIP=1 (exit 0, no-op)
# it recorded a silent PASS ("loaded ... auto-fixed") regardless of reality.
# Now, under SKIP=1, nothing was actually loaded (the mutating call was
# suppressed) and the real `launchctl list` truthfully reports it as absent,
# so the site now reports "plist exists but could not load" instead. This is
# a real behavior change for any existing SKIP=1 consumer that relied on the
# old silent-pass shape — read-only, so not DANGEROUS (XACA-1097-019 review
# note), but a contract change that was undocumented and untested until now.
#
# This test locks in and documents the CURRENT (intentional) contract:
#   - `load` is genuinely suppressed under SKIP=1 (never reaches real launchctl)
#   - `list` (the post-condition verify) is NOT suppressed and DOES reach the
#     fake/real launchctl on PATH
#   - the net effect is a WARN ("could not load"), not a PASS, under SKIP=1 —
#     if a future change makes SKIP=1 swallow the read-only calls too (or
#     reintroduces a silent PASS), this test must be revisited deliberately,
#     not regress unnoticed.
test_start "AITEAMFORGE_SKIP_LAUNCHCTL=1 skips the mutating load but NOT the read-only post-condition verify (XACA-1097 PR #824 subitem 19 — documented, not a bug)"
VALIDATE_LIB="$TAP_ROOT/libexec/lib/validate-install.sh"
skip_seam_mock_dir="$TEST_TMP_DIR/skip-seam-mock-bin"
skip_seam_log="$TEST_TMP_DIR/skip-seam-launchctl.log"
skip_seam_home="$TEST_TMP_DIR/skip-seam-home"
mkdir -p "$skip_seam_mock_dir" "$skip_seam_home/Library/LaunchAgents"

cat > "$skip_seam_mock_dir/launchctl" <<EOF
#!/bin/bash
echo "\$*" >> "$skip_seam_log"
case "\$1" in
  list) exit 0 ;;              # never shows the label -- agent genuinely not loaded
  print-disabled) exit 0 ;;    # empty output -- not disabled
  load) exit 0 ;;              # would "succeed" if it were ever actually called
  *) exit 0 ;;
esac
EOF
chmod +x "$skip_seam_mock_dir/launchctl"

cat > "$skip_seam_home/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist><dict><key>Label</key><string>com.aiteamforge.kanban-backup</string></dict></plist>
PLIST

: > "$skip_seam_log"
skip_seam_out="$(
  HOME="$skip_seam_home" \
  PATH="$skip_seam_mock_dir:/usr/bin:/bin" \
  AITEAMFORGE_SKIP_LAUNCHCTL=1 \
  /bin/bash -c "
    source '$VALIDATE_LIB'
    _VAL_PASS=0 _VAL_WARN=0
    # Isolate to a single agent so the log/assertions below aren't diluted
    # by the other two agents' identical (skipped-plist) no-op path.
    _val_section() { :; }
    agent='com.aiteamforge.kanban-backup'
    plist=\"\$HOME/Library/LaunchAgents/\${agent}.plist\"
    if type _xaca0734_launchctl_is_loaded >/dev/null 2>&1 && _xaca0734_launchctl_is_loaded \"\$agent\"; then
      echo 'RESULT=PASS(already-loaded)'
    elif type _xaca1097_launchctl_is_disabled >/dev/null 2>&1 && _xaca1097_launchctl_is_disabled \"\$agent\"; then
      echo 'RESULT=WARN(disabled)'
    else
      _aitf_launchctl load \"\$plist\" >/dev/null 2>&1 || true
      if _xaca0734_launchctl_is_loaded \"\$agent\"; then
        echo 'RESULT=PASS(auto-fixed)'
      else
        echo 'RESULT=WARN(could-not-load)'
      fi
    fi
  " 2>&1
)"

seam_log_contents="$(cat "$skip_seam_log" 2>/dev/null)"
# `load` must NEVER reach the fake launchctl -- SKIP=1 genuinely suppresses
# the mutating call (same guarantee as test 2a above, exercised through the
# real production seam this time rather than the wrapper in isolation).
case "$seam_log_contents" in
  *load*) test_fail "SKIP=1 leaked a real 'launchctl load' invocation through the production seam: $seam_log_contents" ;;
esac
# `list` (the post-condition verify) and `print-disabled` (the up-front
# disabled classification) MUST still reach the fake launchctl -- this is
# the documented, intentional part of the contract this test locks in.
assert_contains "$seam_log_contents" "list" "read-only post-condition check (launchctl list) must still run even under SKIP=1 -- it is NOT routed through _aitf_launchctl by design"
assert_contains "$seam_log_contents" "print-disabled" "read-only disabled-classification check (launchctl print-disabled) must still run even under SKIP=1 -- it is NOT routed through _aitf_launchctl by design"
# Net effect: a WARN, not a silent PASS -- the documented behavior change.
assert_contains "$skip_seam_out" "RESULT=WARN(could-not-load)" "expected the documented SKIP=1 net effect (a truthful WARN, since nothing was actually loaded) -- got: $skip_seam_out"
test_pass
