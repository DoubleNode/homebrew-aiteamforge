#!/bin/bash
# test-xaca-1599-plugin-tool-delivery.sh  (XACA-1599-006 tap side)
#
# kb-sync-plugins + plugins-manifest.json reach a tap host, and the L1 managed policy is OFFERED
# (never silent) and removed on uninstall:
#
#   A  install-kanban.sh  install_kb_sync_plugins_script   -> $AITEAMFORGE_DIR/scripts/kb-sync-plugins (+x)
#                                                             and $AITEAMFORGE_DIR/.claude/plugins-manifest.json
#   B  aiteamforge-upgrade.sh  aux map + mandatory-materialize entry, update_plugins_manifest(), call order
#   C  install-claude-config.sh  invoke_managed_policy_offer  (dev machine / sandbox / no-tty / tty arms)
#   D  aiteamforge-uninstall.sh  remove_managed_policy          (absent / no tool / no-tty / tty arms)
#
# Drivers extract the real functions from the real files (the XACA-0650 pattern) and run them in a
# mktemp sandbox. `python3` is a shell function that RECORDS its argv instead of running anything,
# so no row can reach sudo or a real managed dir. Terminal rows run the driver on a pty and are
# skipped loudly where none exists. Sentinels break the no-terminal guard in C and D and demand RED.

# shellcheck disable=SC2016  # the drivers are generated source text: single quotes are intentional
TAP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_KANBAN="$TAP_ROOT/libexec/installers/install-kanban.sh"
UPGRADE="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
INSTALL_CLAUDE="$TAP_ROOT/libexec/installers/install-claude-config.sh"
UNINSTALL="$TAP_ROOT/libexec/commands/aiteamforge-uninstall.sh"

PASS=0
FAIL=0
QUIET=0
say()  { [ "$QUIET" = 1 ] || echo "$@"; }
pass() { PASS=$((PASS + 1)); say "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); say "  FAIL: $1"; }
eq()   { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/xaca1599-delivery.XXXXXX")" || exit 2
trap 'cd /; case "$WORK" in */xaca1599-delivery.*) /bin/rm -rf -- "$WORK" ;; esac' EXIT
N=0
newdir() { N=$((N + 1)); D="$WORK/d$N"; mkdir -p "$D"; }

fn_src() { sed -n "/^${2}()/,/^}\$/p" "$1"; }

pty_ok() {
  python3 -c 'import pty,os
pid, fd = pty.fork()
if pid == 0:
    os._exit(0)
os.waitpid(pid, 0)' >/dev/null 2>&1
}

# run_in_pty <script> : stdout of the script as seen on a terminal (OUT).
run_in_pty() {
  OUT="$(python3 -c '
import os, pty, select, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", sys.argv[1]])
buf = b""
end = time.time() + 30
while time.time() < end:
    r, _w, _x = select.select([fd], [], [], 0.2)
    if r:
        try:
            c = os.read(fd, 4096)
        except OSError:
            break
        if not c:
            break
        buf += c
_p, st = os.waitpid(pid, 0)
sys.stdout.write(buf.decode("utf-8", "replace"))
sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 99)
' "$1" 2>&1)"
}

# ---------------------------------------------------------------- A: installer
scn_install() {
  say "=== A: install_kb_sync_plugins_script ==="
  newdir
  local root="$D/root" aif="$D/aif"
  mkdir -p "$root/share/scripts"
  printf '#!/usr/bin/env python3\nprint(1)\n' >"$root/share/scripts/kb-sync-plugins"
  printf '{"schemaVersion":1}\n' >"$root/share/scripts/plugins-manifest.json"
  {
    echo 'info() { :; }; success() { :; }; warning() { echo "WARN:$*"; }'
    echo "INSTALL_ROOT='$root'; AITEAMFORGE_DIR='$aif'"
    fn_src "$INSTALL_KANBAN" install_kb_sync_plugins_script
    echo 'install_kb_sync_plugins_script; echo "RC=$?"'
  } >"$D/drv.sh"
  OUT="$(bash "$D/drv.sh" 2>&1)"
  eq "script installed" "1" "$([ -f "$aif/scripts/kb-sync-plugins" ] && echo 1 || echo 0)"
  eq "script is executable" "1" "$([ -x "$aif/scripts/kb-sync-plugins" ] && echo 1 || echo 0)"
  eq "script is byte-identical to the shipped copy" "1" "$(cmp -s "$root/share/scripts/kb-sync-plugins" "$aif/scripts/kb-sync-plugins" && echo 1 || echo 0)"
  eq "manifest lands where the tool resolves it (\$AITEAMFORGE_DIR/.claude)" "1" "$(cmp -s "$root/share/scripts/plugins-manifest.json" "$aif/.claude/plugins-manifest.json" && echo 1 || echo 0)"
  eq "the manifest is not made executable" "0" "$([ -x "$aif/.claude/plugins-manifest.json" ] && echo 1 || echo 0)"
  eq "rc 0" "RC=0" "$(printf '%s\n' "$OUT" | grep '^RC=')"
  eq "the installer never runs sync (no settings.json written under any team dir)" "0" "$(find "$D" -name settings.json | wc -l | tr -d ' ')"

  rm "$root/share/scripts/kb-sync-plugins"
  newdir
  local aif2="$D/aif"
  {
    echo 'info() { :; }; success() { :; }; warning() { echo "WARN:$*"; }'
    echo "INSTALL_ROOT='$root'; AITEAMFORGE_DIR='$aif2'"
    fn_src "$INSTALL_KANBAN" install_kb_sync_plugins_script
    echo 'install_kb_sync_plugins_script; echo "RC=$?"'
  } >"$D/drv.sh"
  OUT="$(bash "$D/drv.sh" 2>&1)"
  eq "missing source: warns, rc 0, installs nothing" "1" "$(printf '%s\n' "$OUT" | grep -c 'WARN:kb-sync-plugins not found')"
  eq "missing source: nothing created" "0" "$([ -e "$aif2" ] && echo 1 || echo 0)"
  eq "the installer calls it right after the persona tool" "1" \
    "$(grep -A1 '^    install_kb_sync_personas_script$' "$INSTALL_KANBAN" | grep -c '^    install_kb_sync_plugins_script$')"
}

# ---------------------------------------------------------------- B: upgrade
scn_upgrade() {
  say "=== B: upgrade wiring ==="
  newdir
  local fw="$D/fw" wd="$D/wd"
  mkdir -p "$fw/share/scripts" "$wd"
  printf '{"schemaVersion":1}\n' >"$fw/share/scripts/plugins-manifest.json"
  {
    echo 'print_section() { :; }; print_info() { :; }; print_success() { echo "OK:$*"; }; print_warning() { echo "WARN:$*"; }'
    echo "FRAMEWORK_DIR='$fw'; WORKING_DIR='$wd'; DRY_RUN=\${DRY_RUN:-false}; FORCE=false"
    fn_src "$UPGRADE" update_plugins_manifest
    fn_src "$UPGRADE" _xaca0608_aux_script_map
    fn_src "$UPGRADE" _xaca1143_aux_mandatory_materialize_basenames
    echo 'case "$1" in map) _xaca0608_aux_script_map ;; must) _xaca1143_aux_mandatory_materialize_basenames ;; *) update_plugins_manifest ;; esac'
  } >"$D/drv.sh"
  eq "aux map ships kb-sync-plugins to \$WORKING_DIR/scripts" "1" "$(bash "$D/drv.sh" map | grep -c "^kb-sync-plugins|$wd/scripts/kb-sync-plugins\$")"
  eq "mandatory-materialize list carries kb-sync-plugins (existing consumers lack it)" "1" "$(bash "$D/drv.sh" must | grep -c '^kb-sync-plugins$')"
  eq "dry run: says what it would do" "1" "$(DRY_RUN=true bash "$D/drv.sh" | grep -c 'Would update')"
  eq "dry run: wrote nothing" "0" "$([ -e "$wd/.claude/plugins-manifest.json" ] && echo 1 || echo 0)"
  bash "$D/drv.sh" >/dev/null
  eq "absent target: created" "1" "$(cmp -s "$fw/share/scripts/plugins-manifest.json" "$wd/.claude/plugins-manifest.json" && echo 1 || echo 0)"
  eq "up to date: says so" "1" "$(bash "$D/drv.sh" | grep -c 'up to date')"
  printf '{"schemaVersion":1,"v":2}\n' >"$fw/share/scripts/plugins-manifest.json"
  touch -t 203001010000 "$fw/share/scripts/plugins-manifest.json"
  bash "$D/drv.sh" >/dev/null
  eq "newer source: refreshed" "1" "$(cmp -s "$fw/share/scripts/plugins-manifest.json" "$wd/.claude/plugins-manifest.json" && echo 1 || echo 0)"
  local lp lm lt
  lp="$(grep -n '^update_personas_manifest$' "$UPGRADE" | cut -d: -f1)"
  lm="$(grep -n '^update_plugins_manifest$' "$UPGRADE" | cut -d: -f1)"
  lt="$(grep -n '^update_team_scripts$' "$UPGRADE" | cut -d: -f1)"
  eq "update_plugins_manifest runs right after update_personas_manifest" "1" \
    "$([ -n "$lp" ] && [ -n "$lm" ] && [ -n "$lt" ] && [ "$lp" -lt "$lm" ] && [ "$lm" -lt "$lt" ] && echo 1 || echo 0)"
}

# ---------------------------------------------------------------- C / D: terminal-gated actions
# mkdriver <kind> <function-source> : writes $D/drv.sh. python3 is a recorder.
mkdriver() {
  local kind="$1" src="$2"
  {
    echo "CALLS='$D/calls'; : >\"\$CALLS\""
    echo 'python3() { echo "python3 $*" >>"$CALLS"; return "${STUB_RC:-0}"; }'
    if [ "$kind" = offer ]; then
      echo 'log_info() { echo "INFO:$*"; }; log_warning() { echo "WARN:$*"; }; log_success() { echo "OK:$*"; }'
      echo "HOME='$D/home'; AITEAMFORGE_DIR='$D/aif'; CLAUDE_CONFIG_DIR=\"\${CLAUDE_CONFIG_DIR:-$D/home/.claude}\""
      echo "$src"
      echo 'invoke_managed_policy_offer; echo "RC=$?"'
    else
      echo 'print_section() { :; }; print_info() { echo "INFO:$*"; }; print_warning() { echo "WARN:$*"; }; print_success() { echo "OK:$*"; }'
      echo "WORKING_DIR='$D/aif'; CLAUDE_MANAGED_DIR='$D/managed'"
      echo "$src"
      echo 'remove_managed_policy; echo "RC=$?"'
    fi
  } >"$D/drv.sh"
}

ncalls() { wc -l <"$D/calls" | tr -d ' '; }

scn_offer() {
  say "=== C: invoke_managed_policy_offer ==="
  local src
  src="$(fn_src "$INSTALL_CLAUDE" invoke_managed_policy_offer)"
  [ -n "${1:-}" ] && src="$1"
  newdir
  mkdir -p "$D/home/.claude" "$D/aif/scripts"
  : >"$D/aif/scripts/kb-sync-plugins"
  mkdriver offer "$src"
  OUT="$(bash "$D/drv.sh" </dev/null 2>&1)"
  eq "no terminal: nothing is run" "0" "$(ncalls)"
  eq "no terminal: says PENDING and how to install later" "1" "$(printf '%s\n' "$OUT" | grep -c 'PENDING (no terminal')"
  eq "no terminal: the installer carries on (rc 0)" "RC=0" "$(printf '%s\n' "$OUT" | grep '^RC=')"

  mkdir -p "$D/home/dev-team/.claude/agents-master"
  OUT="$(bash "$D/drv.sh" </dev/null 2>&1)"
  eq "dev machine: skipped" "1" "$(printf '%s\n' "$OUT" | grep -c 'dev machine')"
  eq "dev machine: nothing is run" "0" "$(ncalls)"
  rmdir "$D/home/dev-team/.claude/agents-master"

  OUT="$(CLAUDE_CONFIG_DIR="$D/stage" bash "$D/drv.sh" </dev/null 2>&1)"
  eq "staged/sandbox install: skipped" "1" "$(printf '%s\n' "$OUT" | grep -c 'staged/sandbox')"
  eq "staged/sandbox install: nothing is run" "0" "$(ncalls)"

  unlink "$D/aif/scripts/kb-sync-plugins"
  OUT="$(bash "$D/drv.sh" </dev/null 2>&1)"
  eq "tool not delivered yet: deferred, not failed" "1" "$(printf '%s\n' "$OUT" | grep -c 'deferred')"
  eq "tool not delivered yet: rc 0" "RC=0" "$(printf '%s\n' "$OUT" | grep '^RC=')"

  : >"$D/aif/scripts/kb-sync-plugins"
  if pty_ok; then
    run_in_pty "$D/drv.sh"
    eq "terminal: runs the tool's own prompted install, once" "python3 $D/aif/scripts/kb-sync-plugins managed-policy --install" "$(cat "$D/calls")"
    eq "terminal, rc 0: reported current" "1" "$(printf '%s\n' "$OUT" | grep -c 'policy is current')"
    STUB_RC=4 run_in_pty "$D/drv.sh"
    eq "terminal, rc 4 (declined): PENDING with the later command" "1" "$(printf '%s\n' "$OUT" | grep -c 'PENDING (declined)')"
    STUB_RC=1 run_in_pty "$D/drv.sh"
    eq "terminal, rc 1: a warning, installer carries on (rc 0)" "1" "$(printf '%s\n' "$OUT" | grep -c 'RC=0')"
  else
    say "  SKIP: no pseudo-terminal (the terminal rows cannot run here)"
  fi
}

scn_uninstall() {
  say "=== D: remove_managed_policy ==="
  local src
  src="$(fn_src "$UNINSTALL" remove_managed_policy)"
  [ -n "${1:-}" ] && src="$1"
  newdir
  mkdir -p "$D/aif/scripts"
  : >"$D/aif/scripts/kb-sync-plugins"
  mkdriver uninstall "$src"
  OUT="$(bash "$D/drv.sh" </dev/null 2>&1)"
  eq "not installed: nothing is run" "0" "$(ncalls)"
  eq "not installed: says so" "1" "$(printf '%s\n' "$OUT" | grep -c 'No managed policy installed')"

  mkdir -p "$D/managed/managed-settings.d"
  : >"$D/managed/managed-settings.d/50-aiteamforge.json"
  OUT="$(bash "$D/drv.sh" </dev/null 2>&1)"
  eq "installed, no terminal: nothing is run" "0" "$(ncalls)"
  eq "installed, no terminal: NOT removed, with the manual command" "1" "$(printf '%s\n' "$OUT" | grep -c 'NOT removed. Run: python3')"
  eq "installed, no terminal: the uninstall carries on (rc 0)" "RC=0" "$(printf '%s\n' "$OUT" | grep '^RC=')"

  unlink "$D/aif/scripts/kb-sync-plugins"
  OUT="$(bash "$D/drv.sh" </dev/null 2>&1)"
  eq "installed, tool missing: nothing is run, file named" "1" "$(printf '%s\n' "$OUT" | grep -c '50-aiteamforge.json')"
  eq "installed, tool missing: nothing is run (calls)" "0" "$(ncalls)"

  : >"$D/aif/scripts/kb-sync-plugins"
  if pty_ok; then
    run_in_pty "$D/drv.sh"
    eq "terminal: runs the tool's own prompted --remove, once" "python3 $D/aif/scripts/kb-sync-plugins managed-policy --remove" "$(cat "$D/calls")"
    eq "terminal, rc 0: reported removed" "1" "$(printf '%s\n' "$OUT" | grep -c 'Managed policy removed')"
    STUB_RC=4 run_in_pty "$D/drv.sh"
    eq "terminal, declined: NOT removed, uninstall carries on" "1" "$(printf '%s\n' "$OUT" | grep -c 'NOT removed (rc=4)')"
  else
    say "  SKIP: no pseudo-terminal (the terminal rows cannot run here)"
  fi
}

# sentinel <name> <fn> <original-source> <needle> <replacement>
sentinel() {
  local name="$1" fn="$2" src="$3" needle="$4" repl="$5" mutated pf ff
  say "--- sentinel: $name ---"
  mutated="${src/"$needle"/$repl}"
  if [ "$mutated" = "$src" ]; then
    fail "sentinel $name: could not apply the mutation (needle moved?)"
    return
  fi
  pf=$PASS; ff=$FAIL
  QUIET=1
  "$fn" "$mutated"
  local caught=$((FAIL - ff))
  QUIET=0
  PASS=$pf; FAIL=$ff
  if [ "$caught" -gt 0 ]; then pass "sentinel $name: breaking the guard turned $fn RED ($caught failing checks)"
  else fail "sentinel $name: guard broken but $fn stayed green -- vacuous"; fi
}

scn_install
scn_upgrade
scn_offer ""
scn_uninstall ""

say "=== mutation sentinels ==="
sentinel offer-no-terminal scn_offer "$(fn_src "$INSTALL_CLAUDE" invoke_managed_policy_offer)" \
  'if [[ ! -t 0 || ! -t 1 ]]; then' 'if false; then'
sentinel offer-sandbox scn_offer "$(fn_src "$INSTALL_CLAUDE" invoke_managed_policy_offer)" \
  'if [[ "${CLAUDE_CONFIG_DIR}" != "${HOME}/.claude" ]]; then' 'if false; then'
sentinel uninstall-no-terminal scn_uninstall "$(fn_src "$UNINSTALL" remove_managed_policy)" \
  'if [ ! -t 0 ] || [ ! -t 1 ]; then' 'if false; then'

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
