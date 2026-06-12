#!/bin/bash

# test-xaca-0683-skip-launchctl.sh
# XACA-0683: bare `launchctl` load/unload/bootstrap/bootout calls in the
# installer + lifecycle scripts are routed through the `_aitf_launchctl`
# wrapper, which no-ops (returns 0 without touching the GUI domain) when
# AITEAMFORGE_SKIP_LAUNCHCTL=1. The wrapper's single canonical home is
# libexec/lib/common.sh (XACA-0682 originally inlined it in two scripts;
# XACA-0683 converged it and routed the remaining scripts).
#
# This guards three things:
#   1. The wrapper is defined exactly once, in common.sh.
#   2. The wrapper honors AITEAMFORGE_SKIP_LAUNCHCTL (skip vs pass-through).
#   3. No EXECUTED bare mutating `launchctl` call survives in the guarded
#      scripts (sibling-drift / regression guard).

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
