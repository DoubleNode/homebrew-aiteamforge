#!/usr/bin/env bash
# install-power-guard.sh - install / upgrade / remove the power-guard root LaunchDaemon
# (XACA-1394-005, EPIC-0067 D4 option (a)).
#
#   sudo bash install-power-guard.sh install   [--dry-run]
#   sudo bash install-power-guard.sh uninstall [--dry-run]
#        bash install-power-guard.sh status
#
# Run it from YOUR account via sudo (one-time password, expected on each mini). The
# daemon is configured for the INVOKING user (SUDO_USER, else the current user); it is
# never configured for root.
#
# WHAT INSTALL DOES (idempotent: a re-run IS the upgrade)
#   1. refuses on the dev-team source machine (M3Pro). No override flag exists.
#   2. copies power-guard-runner.py + power-guard.py into a ROOT-OWNED dir
#      (/usr/local/libexec/aiteamforge/power-guard). Root executes them every 30 s, so
#      they must not live anywhere the user (or a process running as the user) can write.
#   3. renders power-guard-daemon.template.plist -> /Library/LaunchDaemons/
#      com.aiteamforge.power-guard.plist (root:wheel 644), plutil -lint checked.
#   4. seeds ~/.aiteamforge/power-guard-policy.json from config/templates/
#      power-guard-policy.example.json ONLY IF ABSENT (owned by the user, mode 600).
#      An existing policy is NEVER touched: it may have been armed after a drill.
#   5. creates the ROOT-OWNED debounce-counter dir /var/db/aiteamforge (root:wheel 0700).
#      Root writes the counter every 30 s, so it must not live in the user-writable
#      ~/.aiteamforge/run, where a symlink could steer root's file creates
#      (XACA-1394-013). The runner re-verifies the dir on every run.
#   6. launchctl bootout (ignored if not loaded) then bootstrap.
# It does NOT arm anything: the seeded policy is enabled=false, dry_run=true.
#
# UPS SLEEP CHECK (XACA-1502): install and status also print an ADVISORY "ups-sleep:" line.
# The Mac holding the UPS USB data link uses the separate "UPS Power" energy profile; if
# that has sleep > 0 the Mac sleeps on battery, stops reporting, and the cooperative
# shutdown never fires (XACA-1395 drill). Read-only: it never changes a setting and never
# affects exit codes. Fix, if warned: sudo pmset -u sleep 0 womp 1
#
# UNINSTALL: bootout, remove the plist, the root-owned dir and the debounce counter
# (runtime state). The policy and the logs under /Library/Logs/aiteamforge are LEFT in
# place (evidence of what the guard saw).
#
# TEST SEAMS: PG_LAUNCHD_DIR PG_LOG_DIR PG_LIBEXEC_DIR PG_CLIENT_DIR PG_USER_HOME PG_COUNTER_DIR are
# honoured ONLY when PG_TESTING=1. Without it the real system paths are used.
#
# Exit codes: 0 ok | 1 failure / not root / not installed (status) | 2 usage
#             10 refused: dev-team source machine | 11 refused: install dir is a git work-tree
#
# Bash 3.2 compatible (macOS /bin/bash): no associative arrays, no ${x,,}.

set -euo pipefail

LABEL="com.aiteamforge.power-guard"
PG_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PG_ROOT="$(cd "${PG_SELF_DIR}/../.." 2>/dev/null && pwd -P)"

LAUNCHD_DIR="/Library/LaunchDaemons"
LOG_DIR="/Library/Logs/aiteamforge"
LIBEXEC_DIR="/usr/local/libexec/aiteamforge/power-guard"
COUNTER_DIR="/var/db/aiteamforge"
CLIENT_DIR="${PG_SELF_DIR}/client"
SUDO_BIN="/usr/bin/sudo"
if [ "${PG_TESTING:-}" = "1" ]; then
  LAUNCHD_DIR="${PG_LAUNCHD_DIR:-$LAUNCHD_DIR}"
  LOG_DIR="${PG_LOG_DIR:-$LOG_DIR}"
  LIBEXEC_DIR="${PG_LIBEXEC_DIR:-$LIBEXEC_DIR}"
  CLIENT_DIR="${PG_CLIENT_DIR:-$CLIENT_DIR}"
  COUNTER_DIR="${PG_COUNTER_DIR:-$COUNTER_DIR}"
  SUDO_BIN="${PG_SUDO_BIN:-$SUDO_BIN}"
fi
# Ownership flags. Under PG_TESTING the suite is not root, so it cannot chown to root:wheel;
# production (PG_TESTING unset) always sets root:wheel. Unquoted on purpose (word-split flags).
ROOT_OWN="-o root -g wheel"
[ "${PG_TESTING:-}" = "1" ] && ROOT_OWN=""
PLIST="${LAUNCHD_DIR}/${LABEL}.plist"
TEMPLATE="${PG_SELF_DIR}/power-guard-daemon.template.plist"
PAYLOAD="power-guard-runner.py power-guard.py"
COUNTER_FILE="${COUNTER_DIR}/power-guard-counter.json"

err() { echo "ERROR: $*" >&2; }
info() { echo "$*"; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash install-power-guard.sh install   [--dry-run]   install or upgrade the daemon
  sudo bash install-power-guard.sh uninstall [--dry-run]   remove the daemon (policy + logs kept)
       bash install-power-guard.sh status                  read-only health report

--dry-run prints what would happen, changes nothing and needs no root.

install and status also print an advisory 'ups-sleep:' line: the Mac with the UPS USB
data link must have sleep 0 in its 'UPS Power' energy profile, or it sleeps on battery and
the cooperative shutdown never fires. Read-only; the fix is: sudo pmset -u sleep 0 womp 1
EOF
}

# ---- argument parsing ------------------------------------------------------
MODE=""
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    install|uninstall|status) [ -z "$MODE" ] || { err "only one of install|uninstall|status"; exit 2; }; MODE="$1" ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$MODE" ] || { usage >&2; exit 2; }

# ---- dev-machine guard (install only; NO override, ever) --------------------
# Signals (the same family ci-enable-guard.sh uses, XACA-0497 / XACA-0564):
#   a. .aiteamforge-source-tree sentinel at the root of the tree THIS SCRIPT RUNS FROM
#   b. the sentinel at the resolved AITEAMFORGE_DIR, or at $HOME/dev-team
#      (the invoking user's too: sudo may have reset HOME)
#   c. AITEAMFORGE_DIR is a git work-tree root, or has git-tracked files
# Not hostname inference: hostnames get renamed and duplicated. A root daemon that can
# power the machine off is exactly what must never land on the dev source, so unlike
# the XACA-0564 guard there is no AITEAMFORGE_ALLOW_DEV_OVERWRITE escape hatch.
dev_machine_guard() {
  local aitf real user_home
  aitf="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
  real="$(cd "$aitf" 2>/dev/null && pwd -P)" || real=""
  user_home="$(resolve_user_home 2>/dev/null)" || user_home=""

  if [ -f "${PG_ROOT}/.aiteamforge-source-tree" ] \
     || { [ -n "$real" ] && [ -f "$real/.aiteamforge-source-tree" ]; } \
     || [ -f "${HOME:-/nonexistent}/dev-team/.aiteamforge-source-tree" ] \
     || { [ -n "$user_home" ] && [ -f "$user_home/dev-team/.aiteamforge-source-tree" ]; }; then
    err "this is the AITeamForge dev-team source machine (.aiteamforge-source-tree sentinel found)."
    err "power-guard is a ROOT shutdown daemon and must never be installed here (XACA-0212 / XACA-0497)."
    err "Install it on a consumer machine. There is no override."
    return 10
  fi

  if command -v git >/dev/null 2>&1 && [ -n "$real" ]; then
    local top nd nt is_repo=0
    top="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$real" rev-parse --show-toplevel 2>/dev/null)" || top=""
    if [ -n "$top" ]; then
      nd="$(cd "$real" && pwd -P)"
      nt="$(cd "$top" 2>/dev/null && pwd -P)" || nt="$top"
      [ "$nd" = "$nt" ] && is_repo=1
      if [ "$is_repo" = 0 ] && env -u GIT_DIR -u GIT_WORK_TREE git -C "$real" ls-files --error-unmatch kanban-helpers.sh >/dev/null 2>&1; then
        is_repo=1
      fi
      if [ "$is_repo" = 0 ] && [ -n "$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$real" ls-files 2>/dev/null)" ]; then
        is_repo=1
      fi
    fi
    if [ "$is_repo" = 1 ]; then
      err "$real is inside a git work-tree or has git-tracked files; refusing to install a root daemon on a source checkout."
      err "There is no override."
      return 11
    fi
  fi
  return 0
}

# ---- who is the consuming user ---------------------------------------------
resolve_user() {
  local u="${SUDO_USER:-}"
  [ -n "$u" ] || u="$(id -un)"
  if [ -z "$u" ] || [ "$u" = "root" ]; then
    err "cannot determine a non-root consuming user. Run this from your own account: sudo bash $0 $MODE"
    return 1
  fi
  case "$u" in
    *[!A-Za-z0-9._-]*|-*) err "refusing unsafe user name: $u"; return 1 ;;
  esac
  printf '%s\n' "$u"
}

resolve_user_home() {
  local u h
  u="$(resolve_user)" || return 1
  h=""
  if [ "${PG_TESTING:-}" = "1" ] && [ -n "${PG_USER_HOME:-}" ]; then
    h="$PG_USER_HOME"
  elif command -v dscl >/dev/null 2>&1; then
    h="$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p' | head -n 1)" || h=""
  fi
  [ -n "$h" ] || h="$(eval "printf '%s' ~$u")"
  case "$h" in
    /*) ;;
    *) err "could not resolve an absolute home directory for $u (got '$h')"; return 1 ;;
  esac
  case "$h" in
    *[\<\>\&\"\'\\\|]*) err "home directory contains characters that cannot be rendered safely: $h"; return 1 ;;
  esac
  if [ "$(printf '%s' "$h" | wc -l | tr -d ' ')" != "0" ]; then err "home directory contains a newline"; return 1; fi
  printf '%s\n' "$h"
}

# ---- helpers ---------------------------------------------------------------
run() { # run <cmd...>: executes, or only prints under --dry-run
  if [ "$DRY" = 1 ]; then info "  [dry-run] $*"; else "$@"; fi
}

# run_as_user <user> <cmd...>: anything created under the user's HOME is created
# BY the user, never by root (XACA-1394-014/015). Root following a user-placed
# symlink (~/.aiteamforge, ~/.aiteamforge/run, or the policy file itself) could
# write anywhere; the user following it can only write where the user already can.
# The SAME code path runs in production and under test: only SUDO_BIN differs
# (PG_SUDO_BIN, honoured solely under PG_TESTING, points at a pass-through stub).
run_as_user() {
  local u="$1"; shift
  run "$SUDO_BIN" -n -u "$u" -- "$@"
}

# seed_user_dir <user> <dir> <mode>: create a MISSING directory as the user with
# <mode>. An existing one (or a symlink to one) is left exactly as it is: never
# re-moded. `install -d -m` would chmod a pre-existing dir, and ~/.aiteamforge/run
# is an owner-only 0700 dir (XACA-0385) that must never be widened (XACA-1394-018).
seed_user_dir() {
  local u="$1" d="$2" m="$3"
  [ -d "$d" ] && return 0
  run_as_user "$u" mkdir -m "$m" "$d"
}

render_plist() { # render_plist <out> <user> <user_home>
  sed -e "s|{{INSTALL_DIR}}|${LIBEXEC_DIR}|g" \
      -e "s|{{USER_HOME}}|$3|g" \
      -e "s|{{USERNAME}}|$2|g" \
      -e "s|{{LOG_DIR}}|${LOG_DIR}|g" \
      -e "s|{{COUNTER_DIR}}|${COUNTER_DIR}|g" "$TEMPLATE" >"$1"
  if grep -q '{{[A-Z_]*}}' "$1"; then err "unsubstituted placeholder left in rendered plist"; return 1; fi
}

lint_plist() {
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$1" >/dev/null || { err "plutil -lint rejected $1"; return 1; }
  else
    info "WARNING: plutil not found; rendered plist not linted"
  fi
}

policy_template() {
  local c
  for c in "${PG_ROOT}/config/templates/power-guard-policy.example.json" \
           "${PG_SELF_DIR}/power-guard-policy.example.json"; do
    [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

payload_preflight() {
  local f missing=0
  [ -f "$TEMPLATE" ] || { err "plist template missing: $TEMPLATE"; missing=1; }
  for f in $PAYLOAD; do
    [ -f "${CLIENT_DIR}/$f" ] || { err "payload file missing: ${CLIENT_DIR}/$f"; missing=1; }
  done
  policy_template >/dev/null || { err "policy example missing: config/templates/power-guard-policy.example.json"; missing=1; }
  [ "$missing" = 0 ] || { err "Nothing was changed."; return 1; }
}

# ---- UPS power-profile sleep check (XACA-1502) ------------------------------
# _pg_pmset_capture <pmset args...>: run pmset with a 3 s ceiling, output -> PG_PMSET_OUT.
# Returns 0 ok | 1 pmset not found | 2 timed out | 3 failed / no output. No timeout(1) on
# stock macOS, so poll the background pid (same approach as fleet-reporter's
# _system_collect_power). Never aborts the caller under set -e: callers use `|| rc=$?`.
PG_PMSET_OUT=""
_pg_pmset_capture() {
  PG_PMSET_OUT=""
  command -v pmset >/dev/null 2>&1 || return 1
  local tmp pid i=0 rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/power-guard-pmset.XXXXXX" 2>/dev/null)" || return 3
  pmset "$@" >"$tmp" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge 30 ]; then
      disown "$pid" 2>/dev/null || true
      kill -9 "$pid" 2>/dev/null || true
      rm "$tmp" 2>/dev/null || true
      return 2
    fi
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid" 2>/dev/null || rc=$?
  PG_PMSET_OUT="$(cat "$tmp" 2>/dev/null || true)"
  rm "$tmp" 2>/dev/null || true
  [ "$rc" -eq 0 ] || return 3
  [ -n "$PG_PMSET_OUT" ] || return 3
  return 0
}

# ups_sleep_check: ADVISORY. If this Mac holds a UPS data link, its "UPS Power" energy
# profile must have sleep 0 or it sleeps on battery, stops reporting, and the cooperative
# shutdown never fires (XACA-1395 drill, 2026-10-11). Prints "ups-sleep:" line(s); exactly
# one outcome. Detect and advise only: never changes a power setting. Always returns 0.
# Anything it cannot verify is "could not determine", never an OK.
ups_sleep_check() {
  local rc=0 line="" in_ups=0 saw_ups=0 has_ups=0 has_anchor=0 sleep_v="" womp_v="" k="" v="" rest=""

  _pg_pmset_capture -g ps || rc=$?
  case "$rc" in
    0) ;;
    1) info "ups-sleep: could not determine UPS sleep setting (pmset not found)"; return 0 ;;
    2) info "ups-sleep: could not determine UPS sleep setting (pmset -g ps timed out)"; return 0 ;;
    *) info "ups-sleep: could not determine UPS sleep setting (pmset -g ps failed)"; return 0 ;;
  esac
  # A UPS is a power-source device line (" -Name (id=..)") that is not the internal battery,
  # or either of pmset's UPS-only lines (drawing from 'UPS Power', a "UPS settings:" block).
  # "Not applicable" is an all-clear, so it needs the "Now drawing from" anchor line: output
  # in a format we don't recognise is "could not determine", never "no UPS".
  while IFS= read -r line; do
    case "$line" in
      "Now drawing from 'UPS Power'"*) has_ups=1; has_anchor=1 ;;
      "Now drawing from "*) has_anchor=1 ;;
      "UPS settings:"*) has_ups=1 ;;
      " -InternalBattery"*) ;;
      " -"*) has_ups=1 ;;
    esac
  done <<EOF
$PG_PMSET_OUT
EOF
  if [ "$has_ups" = 0 ]; then
    if [ "$has_anchor" = 0 ]; then
      info "ups-sleep: could not determine UPS sleep setting (unrecognised pmset -g ps output)"
    else
      info "ups-sleep: not applicable (no UPS attached)"
    fi
    return 0
  fi

  rc=0
  _pg_pmset_capture -g custom || rc=$?
  case "$rc" in
    0) ;;
    2) info "ups-sleep: could not determine UPS sleep setting (pmset -g custom timed out)"; return 0 ;;
    *) info "ups-sleep: could not determine UPS sleep setting (pmset -g custom failed)"; return 0 ;;
  esac
  # Scope to the "UPS Power:" section: unindented header up to the next unindented header.
  while IFS= read -r line; do
    case "$line" in
      "UPS Power:"*) in_ups=1; saw_ups=1; continue ;;
      [[:space:]]*) ;;
      *) in_ups=0; continue ;;
    esac
    [ "$in_ups" = 1 ] || continue
    k=""; v=""; rest=""
    read -r k v rest <<EOF2 || true
$line
EOF2
    case "$k" in
      sleep) sleep_v="$v" ;;
      womp) womp_v="$v" ;;
    esac
  done <<EOF
$PG_PMSET_OUT
EOF
  if [ "$saw_ups" = 0 ]; then
    info "ups-sleep: could not determine UPS sleep setting (UPS attached but pmset -g custom has no 'UPS Power:' section)"
    return 0
  fi
  case "$sleep_v" in
    "") info "ups-sleep: could not determine UPS sleep setting (no 'sleep' value in the UPS Power profile)"; return 0 ;;
    *[!0-9]*) info "ups-sleep: could not determine UPS sleep setting (non-numeric sleep value '$sleep_v')"; return 0 ;;
  esac
  if [ "$sleep_v" -eq 0 ]; then
    info "ups-sleep: OK (UPS Power profile: sleep 0, womp ${womp_v:-unknown})"
  else
    info "ups-sleep: WARNING UPS Power profile has sleep $sleep_v (womp ${womp_v:-unknown}): this Mac holds the UPS data link, so it will sleep on battery, stop reporting, and the cooperative shutdown will never fire."
    if [ "$womp_v" = "0" ]; then info "ups-sleep: WARNING womp is 0 too: wake-on-network is off, so it cannot be woken remotely."; fi
    info "ups-sleep: fix (not applied; you own this machine's power policy): sudo pmset -u sleep 0 womp 1"
  fi
  return 0
}

require_root() {
  [ "$DRY" = 1 ] && return 0
  if [ "$(id -u)" != "0" ]; then
    err "$MODE needs root. Run it once with your password:"
    err "  sudo bash $PG_SELF_DIR/$(basename "$0") $MODE"
    return 1
  fi
}

# ---- install ---------------------------------------------------------------
do_install() {
  dev_machine_guard || exit $?
  require_root || exit 1
  local user uhome tmp existed=0 f pol
  user="$(resolve_user)" || exit 1
  uhome="$(resolve_user_home)" || exit 1
  payload_preflight || exit 1
  [ -f "$PLIST" ] && existed=1
  [ "$existed" = 1 ] && info "power-guard already installed: refreshing (upgrade)." || info "Installing power-guard for user $user ($uhome)."

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/power-guard-install.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  render_plist "$tmp/rendered.plist" "$user" "$uhome" || exit 1
  lint_plist "$tmp/rendered.plist" || exit 1

  run mkdir -p "$LIBEXEC_DIR" "$LOG_DIR" "$LAUNCHD_DIR"
  [ -z "$ROOT_OWN" ] || run chown root:wheel "$LOG_DIR"
  run chmod 755 "$LOG_DIR"
  for f in $PAYLOAD; do
    run install -m 755 $ROOT_OWN "${CLIENT_DIR}/$f" "${LIBEXEC_DIR}/$f"
  done
  [ -z "$ROOT_OWN" ] || run chown root:wheel "$LIBEXEC_DIR"
  run chmod 755 "$LIBEXEC_DIR"
  run install -m 644 $ROOT_OWN "$tmp/rendered.plist" "$PLIST"
  # Debounce counter: root-owned 0700, outside the user's home (XACA-1394-013).
  run install -d -m 700 $ROOT_OWN "$COUNTER_DIR"

  # Policy: seed ONLY if absent. Never overwrite, never chmod an existing one.
  pol="${uhome}/.aiteamforge/power-guard-policy.json"
  # The seeding writes run AS THE USER (run_as_user), so a symlinked parent dir or
  # policy file can only redirect the write somewhere the user could write anyway.
  # A symlinked policy LEAF is still refused outright: a missing policy is the
  # disarmed state, so declining to seed fails closed.
  if [ -L "$pol" ]; then
    err "Policy path is a symlink, not seeding (power-guard stays disarmed): $pol"
  elif [ -e "$pol" ]; then
    info "Policy exists, left untouched: $pol"
  else
    # A failure here (e.g. ~/.aiteamforge is a regular file) must not abort the
    # install half-done under set -e: no policy == disarmed, so report and go on.
    if seed_user_dir "$user" "${uhome}/.aiteamforge" 755 \
       && seed_user_dir "$user" "${uhome}/.aiteamforge/run" 700 \
       && run_as_user "$user" install -m 600 "$(policy_template)" "$pol"; then
      info "Seeded DISARMED policy (enabled=false, dry_run=true): $pol"
    else
      err "Could not seed the policy as $user at $pol (power-guard stays disarmed until one exists)"
    fi
  fi

  if [ "$DRY" = 1 ]; then
    info "  [dry-run] launchctl bootout system/${LABEL}"
    info "  [dry-run] launchctl bootstrap system $PLIST"
  else
    launchctl bootout "system/${LABEL}" >/dev/null 2>&1 || true
    launchctl bootstrap system "$PLIST" || { err "launchctl bootstrap failed for $PLIST"; exit 1; }
  fi
  ups_sleep_check || true
  info "power-guard $([ "$existed" = 1 ] && echo upgraded || echo installed). Log: ${LOG_DIR}/power-guard.log"
  info "It is DISARMED. Arm only after the supervised drill (XACA-1395)."
}

# ---- uninstall -------------------------------------------------------------
do_uninstall() {
  require_root || exit 1
  if [ "$DRY" = 1 ]; then
    info "  [dry-run] launchctl bootout system/${LABEL}"
  else
    launchctl bootout "system/${LABEL}" >/dev/null 2>&1 || true
  fi
  local f
  run rm -f "$PLIST"
  for f in $PAYLOAD; do run rm -f "${LIBEXEC_DIR}/$f"; done
  if [ "$DRY" = 1 ]; then info "  [dry-run] rmdir ${LIBEXEC_DIR}"; else rmdir "$LIBEXEC_DIR" 2>/dev/null || true; fi
  run rm -f "$COUNTER_FILE"
  if [ "$DRY" = 1 ]; then info "  [dry-run] rmdir ${COUNTER_DIR}"; else rmdir "$COUNTER_DIR" 2>/dev/null || true; fi
  info "power-guard removed. Policy (~/.aiteamforge/power-guard-policy.json) and logs (${LOG_DIR}) were left in place."
}

# ---- status ----------------------------------------------------------------
do_status() {
  local rc=0 f user uhome
  if [ -f "$PLIST" ]; then info "plist:    present ($PLIST)"; else info "plist:    ABSENT"; rc=1; fi
  for f in $PAYLOAD; do
    if [ -f "${LIBEXEC_DIR}/$f" ]; then
      if [ -f "${CLIENT_DIR}/$f" ] && ! cmp -s "${CLIENT_DIR}/$f" "${LIBEXEC_DIR}/$f"; then
        info "payload:  $f present but DIFFERS from the shipped copy (re-run install to upgrade)"
      else
        info "payload:  $f present"
      fi
    else
      info "payload:  $f ABSENT"; rc=1
    fi
  done
  if launchctl print "system/${LABEL}" >/dev/null 2>&1; then info "launchd:  loaded"; else info "launchd:  not loaded (or needs root to query)"; rc=1; fi
  if user="$(resolve_user 2>/dev/null)" && uhome="$(resolve_user_home 2>/dev/null)"; then
    if [ -f "${uhome}/.aiteamforge/power-guard-policy.json" ]; then info "policy:   present (${uhome}/.aiteamforge/power-guard-policy.json)"; else info "policy:   ABSENT"; fi
  fi
  ups_sleep_check || true
  return $rc
}

case "$MODE" in
  install) do_install ;;
  uninstall) do_uninstall ;;
  status) do_status ;;
esac
