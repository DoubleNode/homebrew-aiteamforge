#!/usr/bin/env bash
# teardown-host.sh - undo provision-host.sh / create-ci-runner-user.sh on ONE host
# (XACA-1443-003). The root half of `aiteamforge ci disable`.
#
# Run ON the host, under sudo, by an operator who read it (the CLI prints the one line):
#   sudo bash teardown-host.sh --host <name> [--remove-user] [--kill-running] [--vm-gone] [--no-linux] [--dry-run]
#
# It is the mirror of provision-host.sh, in the REVERSE order, and idempotent: every step
# checks what is on disk first, so a second run (or a run on a half-provisioned host) is safe.
#
#   1. refuse while a pool job is starting/busy/cleaning (slots.json), unless --kill-running
#   2. bootout the daemons: agent FIRST (stops new work), then slots.json is read AGAIN (XACA-1443-017: a job
#      can start between step 1 and the bootout); busy now and no --kill-running = refuse rc 3 BEFORE the VM is
#      touched, with the agent stopped and the way to resume printed. Then reporter, macos, lima-vm
#   3. (--kill-running) kill the macOS Runner.Listener and clean the macOS slot directories
#   4. delete the Lima VM `ci-linux-<host>` as ci-runner (`limactl delete -f`); it carries the
#      Linux runners, so no registration survives inside it. NO-LINUX HOSTS (XACA-1461): `--no-linux`
#      (what `ci disable` passes for a lane=macos host) skips the VM stop and delete and NEVER invokes
#      limactl. Independently of the flag, the step is a clean no-op, limactl or not, when the host has
#      no lima-vm plist AND ~ci-runner/.lima/<vm> is positively absent (root can read it). The flag is
#      recorded intent; it is not trusted over evidence: if a lima-vm plist exists, --no-linux is
#      ignored with a WARN and the VM is torn down as usual (deleting the plist of a live VM would orphan
#      it). FAILURE HERE STOPS THE SCRIPT
#      BEFORE THE PLISTS ARE REMOVED: the plists are the "teardown finished" marker that
#      `aiteamforge ci disable --confirm` reads, so a half teardown can never read as done.
#   5. remove the secrets and config: agent key + agent.json + slots.json + agent log dir,
#      the reporter's fleet-config.json (holds the fct_ telemetry key), the XACA-1440 pause
#      marker `<host>.pause.json` and its lock dir, and the provision manifest `<host>.provision-manifest`
#   6. remove the root-owned copies in /usr/local/libexec (agent, reporter, JIT scripts)
#   7. remove the four LaunchDaemon plists  (com.doublenode.ci-runner.<host>.{agent,reporter,macos,lima-vm})
#   8. (--remove-user) delete the ci-runner user, its group and its home. DEFAULT: KEEP the user.
#
# Steps 5, 6 and the agent dirs are machine-level (the names carry no host suffix). They are
# kept while ANY other com.doublenode.ci-runner* plist is still installed, and --remove-user is
# refused (rc 4) in that case: the user would still own that other host's VM.
#
# RUNNER REGISTRATIONS. `ci enable` provisions with --no-register, so no persistent runner is
# registered. JIT runners are single-use: GitHub drops them when their one job ends and the
# dispatcher deletes any orphan; nothing here calls GitHub. If this host was ALSO provisioned
# the persistent way (a --token-file run by hand), those runners stay listed on GitHub: this
# script warns and leaves removing them to you (docs/ci-runner-runbook.md section 5), because
# deregistering needs a removal token this script must never hold.
# NOT done here (server side, admin): revoke the agent + telemetry keys, drop the machine
# record, trim the allowlist. The output lists them.
#
# Exit codes (the last stdout line is RESULT: <NAME> host=<h> rc=<n>):
#   0 done (or already clean, or --dry-run)   1 a step failed (see WARN lines; plists kept if the VM step failed)
#   2 usage / invalid input                   3 REFUSED: a job is running (re-run with --kill-running)
#   4 REFUSED: --remove-user while another host's artifacts remain      5 not root
#
# Test overrides (a sudo'd root script does not inherit the caller's environment, so these are
# not an injection route): CI_LAUNCHDAEMONS_DIR CI_LIBEXEC_DIR CI_AGENT_CFG_DIR
# CI_AGENT_STATE_DIR CI_AGENT_LOG_DIR CIH_STATE_DIR CI_RUNNER_USER CI_RUNNER_HOME CI_LIMACTL_PATH.
#
# Bash 3.2 compatible (macOS /bin/bash). No `set -e`: every return code is explicit.

set -u

HOST=""; REMOVE_USER=0; KILL_RUNNING=0; DRY=0; VM_GONE=0; NO_LINUX=0
CI_USER="${CI_RUNNER_USER:-ci-runner}"
LD_DIR="${CI_LAUNCHDAEMONS_DIR:-/Library/LaunchDaemons}"
LIBEXEC_DIR="${CI_LIBEXEC_DIR:-/usr/local/libexec}"
AGENT_CFG_DIR="${CI_AGENT_CFG_DIR:-/usr/local/etc/ci-pool-agent}"
AGENT_STATE_DIR="${CI_AGENT_STATE_DIR:-/usr/local/var/ci-pool-agent}"
AGENT_LOG_DIR="${CI_AGENT_LOG_DIR:-/Library/Logs/ci-pool-agent}"
PAUSE_DIR="${CIH_STATE_DIR:-/usr/local/etc/ci-runner}"
CI_HOME="${CI_RUNNER_HOME:-/Users/${CI_USER}}"
LIMACTL="${CI_LIMACTL_PATH:-/opt/homebrew/bin/limactl}"
CI_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
FAILS=0

usage() {
  cat <<'EOF'
Usage: sudo bash teardown-host.sh --host <name> [--remove-user] [--kill-running] [--vm-gone] [--no-linux] [--dry-run]

  --host <name>     the host name used at provisioning (runner/VM/daemon suffix)
  --remove-user     ALSO delete the ci-runner user, its group and /Users/ci-runner (default: keep)
  --kill-running    proceed although a pool job is starting/busy/cleaning (kills the macOS
                    listener; deleting the VM ends the Linux ones)
  --vm-gone         ONLY for a host whose limactl was removed while the ci-runner user still exists:
                    you state the Lima VM is gone and accept that it is not verified or deleted.
                    (Without the flag an absent ~ci-runner/.lima/<vm> directory is accepted on its own;
                    an unreadable directory never is.)
  --no-linux        the host has no Linux lane (lane=macos, XACA-1461): skip the VM stop/delete and never run limactl.
                    Ignored with a WARN when a lima-vm daemon plist exists for this host (that VM must not be orphaned).
                    Without the flag the VM step is ALSO a no-op, with no limactl needed, when there is no lima-vm
                    plist and the VM directory is positively absent.
  --dry-run         print the plan and what exists now; change nothing (no root needed)
EOF
}

log()  { printf '[teardown-%s] %s\n' "${HOST:-?}" "$*"; }
warn() { printf '[teardown-%s] WARN: %s\n' "${HOST:-?}" "$*" >&2; }
result() { # NAME rc
  printf 'RESULT: %s host=%s rc=%s\n' "$1" "${HOST:-}" "$2"
}
usage_err() { echo "teardown-host.sh: $*" >&2; usage >&2; result USAGE 2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host) [ $# -ge 2 ] || usage_err "--host needs a value"; HOST="$2"; shift 2 ;;
    --remove-user) REMOVE_USER=1; shift ;;
    --kill-running) KILL_RUNNING=1; shift ;;
    --vm-gone) VM_GONE=1; shift ;;
    --no-linux) NO_LINUX=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_err "unknown option: $1" ;;
  esac
done
case "$HOST" in
  '') usage_err "--host <name> is required" ;;
  [!a-z0-9]*|*[!a-z0-9-]*|*-) usage_err "--host must match [a-z0-9]([a-z0-9-]*[a-z0-9])?, got '${HOST}'" ;;
esac
[ "${#HOST}" -le 40 ] || usage_err "--host is longer than 40 characters"

# Every path below is rm'd: refuse anything that is not a plain absolute path.
for _p in "$LD_DIR" "$LIBEXEC_DIR" "$AGENT_CFG_DIR" "$AGENT_STATE_DIR" "$AGENT_LOG_DIR" "$PAUSE_DIR" "$CI_HOME"; do
  case "$_p" in
    /|//*|'') usage_err "refusing unsafe path '$_p'" ;;
    /?*) ;;
    *) usage_err "refusing non-absolute path '$_p'" ;;
  esac
  case "$_p" in *[[:space:]]*|*..*) usage_err "refusing path with whitespace or '..': '$_p'" ;; esac
done
case "$CI_USER" in ''|*[!a-z0-9_-]*|-*) usage_err "bad CI_RUNNER_USER '$CI_USER'" ;; esac

if [ "$DRY" = 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "teardown-host.sh: run under sudo (or use --dry-run)" >&2; result NOT_ROOT 5; exit 5
fi

LABELS_ORDER="agent reporter macos lima-vm"
label_of() { printf 'com.doublenode.ci-runner.%s.%s' "$HOST" "$1"; }
plist_of() { printf '%s/%s.plist' "$LD_DIR" "$(label_of "$1")"; }

# Other hosts' (or the legacy unsuffixed) daemons still installed?
count_other_plists() {
  local f n=0 b own k
  for f in "$LD_DIR"/com.doublenode.ci-runner*.plist; do
    [ -e "$f" ] || continue
    b="${f##*/}"; own=0
    for k in $LABELS_ORDER; do [ "$b" = "$(label_of "$k").plist" ] && own=1; done
    [ "$own" = 1 ] || n=$((n + 1))
  done
  echo "$n"
}

# run <desc> <cmd...>: dry-run prints, else executes; a failure counts and returns 1.
run() {
  local desc="$1"; shift
  if [ "$DRY" = 1 ]; then log "[dry-run] would: ${desc}"; return 0; fi
  if "$@"; then log "${desc}: done"; return 0; fi
  warn "${desc}: FAILED"; FAILS=$((FAILS + 1)); return 1
}
as_ci() { sudo -n -u "$CI_USER" -H env PATH="$CI_PATH" "$@"; }
user_exists() { id -u "$CI_USER" >/dev/null 2>&1; }
# absent | present | unknown for ~ci-runner/.lima/<vm>. "absent" needs a readable, searchable home (and .lima), so a
# permission failure is never mistaken for "not there".
vm_dir_state() {
  local lima="$CI_HOME/.lima"
  [ -d "$CI_HOME" ] && [ -r "$CI_HOME" ] && [ -x "$CI_HOME" ] || { echo unknown; return; }
  if [ ! -e "$lima" ] && [ ! -L "$lima" ]; then echo absent; return; fi
  [ -d "$lima" ] && [ -r "$lima" ] && [ -x "$lima" ] || { echo unknown; return; }
  if [ -e "$lima/$VM_NAME" ] || [ -L "$lima/$VM_NAME" ]; then echo present; else echo absent; fi
}

OTHERS="$(count_other_plists)"

# ---- VM name (agent.json is authoritative; else the provision-host default) ------------------
VM_NAME="ci-linux-${HOST}"
if [ -f "$AGENT_CFG_DIR/agent.json" ]; then
  _v="$(sed -n 's/.*"vmName": *"\([A-Za-z0-9][A-Za-z0-9._-]*\)".*/\1/p' "$AGENT_CFG_DIR/agent.json" | head -n 1)"
  [ -z "$_v" ] || VM_NAME="$_v"
fi

# ---- 1. busy slots ------------------------------------------------------------------------------
SLOTS="$AGENT_STATE_DIR/slots.json"
if [ -e "$SLOTS" ]; then
  busy=0
  if [ ! -r "$SLOTS" ]; then busy=1   # unreadable: fail closed
  elif grep -Eq '"state": ?"(starting|busy|cleaning)"' "$SLOTS" 2>/dev/null; then busy=1; fi
  if [ "$busy" = 1 ] && [ "$KILL_RUNNING" = 0 ]; then
    echo "teardown-host.sh: a pool job is running (or $SLOTS is unreadable). Nothing was changed." >&2
    echo "Wait for it to finish, or re-run with --kill-running to end it." >&2
    result BUSY 3; exit 3
  fi
fi

# ---- 8-precheck: refuse --remove-user while other hosts remain, before touching anything -------
if [ "$REMOVE_USER" = 1 ] && [ "$OTHERS" -gt 0 ]; then
  echo "teardown-host.sh: --remove-user refused: $OTHERS other com.doublenode.ci-runner* daemon plist(s) remain in $LD_DIR; the user still owns them. Nothing was changed." >&2
  result REFUSED_OTHER_HOSTS 4; exit 4
fi

# XACA-1461: --no-linux is intent, evidence wins. A lima-vm plist of THIS host means a VM may exist.
if [ "$NO_LINUX" = 1 ] && { [ -e "$(plist_of lima-vm)" ] || [ -L "$(plist_of lima-vm)" ]; }; then
  warn "--no-linux given but $(plist_of lima-vm) exists: tearing the VM down as usual (a VM must not be orphaned)"
  NO_LINUX=0
fi
log "plan: host=${HOST} vm=${VM_NAME} user=${CI_USER} remove-user=${REMOVE_USER} kill-running=${KILL_RUNNING} no-linux=${NO_LINUX} dry-run=${DRY} other-hosts-plists=${OTHERS}"

# ---- 2. daemons -----------------------------------------------------------------------------------
boot_one() { # key
  local l; l="$(label_of "$1")"
  if [ "$DRY" = 1 ]; then
    log "[dry-run] would: bootout system/${l} (loaded now: $(launchctl print "system/$l" >/dev/null 2>&1 && echo yes || echo no))"
  elif launchctl print "system/$l" >/dev/null 2>&1; then
    run "bootout system/${l}" launchctl bootout "system/$l"
  else
    log "daemon ${l}: not loaded"
  fi
}
# The agent goes first: it is what dispatches new work. Once it is down nothing can START a job, so the second
# slots.json read below is final (XACA-1443-017; the check in step 1 only narrows the window, it cannot close it).
boot_one agent
if [ "$DRY" = 0 ] && [ -e "$SLOTS" ] && [ "$KILL_RUNNING" = 0 ]; then
  busy2=0
  if [ ! -r "$SLOTS" ]; then busy2=1
  elif grep -Eq '"state": ?"(starting|busy|cleaning)"' "$SLOTS" 2>/dev/null; then busy2=1; fi
  if [ "$busy2" = 1 ]; then
    echo "teardown-host.sh: a pool job started (or $SLOTS became unreadable) while the agent was being stopped." >&2
    echo "The agent daemon is now STOPPED (no new job will start). The VM, the other daemons, the keys and the plists were NOT touched." >&2
    echo "  Resume as before:  sudo launchctl bootstrap system $(plist_of agent)" >&2
    echo "  Or finish the job first and re-run this script, or re-run it with --kill-running to end the job." >&2
    result BUSY_AGENT_STOPPED 3; exit 3
  fi
fi
for k in $LABELS_ORDER; do
  [ "$k" != agent ] || continue
  [ "$k" != lima-vm ] || [ "$NO_LINUX" = 0 ] || { log "no Linux lane: no lima-vm daemon to stop"; continue; }
  boot_one "$k"
done

# ---- 3. running macOS work ---------------------------------------------------------------------------
if [ "$KILL_RUNNING" = 1 ]; then
  if user_exists; then
    run "kill the macOS Runner.Listener (user ${CI_USER})" pkill -u "$CI_USER" -f Runner.Listener
    if [ -r "$SLOTS" ]; then
      for n in $(grep -o '"macOS-[0-9]*"' "$SLOTS" | tr -d '"' | sed 's/^macOS-//' | sort -u); do
        [ -x "$LIBEXEC_DIR/ci-runner-jit-macos.sh" ] || continue
        run "clean macOS slot ${n}" as_ci "$LIBEXEC_DIR/ci-runner-jit-macos.sh" clean "$n"
      done
    fi
  fi
fi

# ---- 4. the VM (must succeed before the plists go) ---------------------------------------------------
VM_FAILED=0
if [ "$NO_LINUX" = 1 ]; then
  log "no Linux lane (--no-linux): no VM to stop or delete; limactl is not used"
elif [ ! -e "$(plist_of lima-vm)" ] && [ ! -L "$(plist_of lima-vm)" ] && [ "$(vm_dir_state)" = absent ]; then
  # no daemon plist and root can see that the VM directory is not there: nothing to delete, and limactl is not needed
  log "VM ${VM_NAME}: no lima-vm plist and ${CI_HOME}/.lima/${VM_NAME} is absent; nothing to delete (limactl not consulted)"
elif user_exists && [ -x "$LIMACTL" ]; then
  st=""
  if [ "$DRY" = 0 ]; then st="$(as_ci "$LIMACTL" list --format '{{.Status}}' "$VM_NAME" 2>/dev/null)" || st=""; fi
  if [ "$DRY" = 1 ]; then
    log "[dry-run] would: delete VM ${VM_NAME} if present (limactl delete -f)"
  elif [ -n "$st" ]; then
    run "delete VM ${VM_NAME} (was: ${st})" as_ci "$LIMACTL" delete -f "$VM_NAME" || VM_FAILED=1
  else
    log "VM ${VM_NAME}: absent"
  fi
elif user_exists; then
  # limactl is gone but the user is still here: the VM can never be listed or deleted through limactl. Root can look at
  # the VM directory itself; an ABSENT one is positive evidence there is nothing to delete. Anything unreadable stays
  # unknown and fails closed (XACA-1443-018).
  _vs="$(vm_dir_state)"
  if [ "$_vs" = absent ]; then
    log "limactl not found at ${LIMACTL}, and ${CI_HOME}/.lima/${VM_NAME} does not exist: VM ${VM_NAME} is absent"
  elif [ "$VM_GONE" = 1 ]; then
    log "limactl not found at ${LIMACTL}: --vm-gone given, so VM ${VM_NAME} is taken as already gone (not verified)"
    [ "$_vs" != present ] || warn "${CI_HOME}/.lima/${VM_NAME} is still on disk: nothing here deletes it; remove it yourself if the VM is really gone"
  else
    warn "limactl not found at ${LIMACTL}: cannot verify or delete VM ${VM_NAME} (its directory is $([ "$_vs" = present ] && echo 'still on disk' || echo 'unreadable')); plists will be KEPT"
    warn "if the VM is already gone, re-run with --vm-gone (aiteamforge ci disable --vm-gone)"
    FAILS=$((FAILS + 1)); VM_FAILED=1
  fi
else
  log "user ${CI_USER}: absent, so no VM can exist"
fi
if [ "$VM_FAILED" = 1 ] && [ "$DRY" = 0 ]; then
  warn "stopping before the plists and config are removed, so 'ci disable --confirm' keeps refusing. Fix the VM (limactl as ${CI_USER}), then re-run."
  result INCOMPLETE 1; exit 1
fi

# Persistent runner left behind by a hand-run (--token-file) provisioning? Warn, never act.
if [ -f "$CI_HOME/actions-runner-macos/.runner" ] 2>/dev/null; then
  warn "a PERSISTENT macOS runner registration exists (${CI_HOME}/actions-runner-macos/.runner): GitHub still lists it. Remove it per docs/ci-runner-runbook.md section 5 (Settings, Actions, Runners)."
fi

# ---- 5. secrets, config, pause marker -------------------------------------------------------------------
rm_file() { # path
  [ -e "$1" ] || [ -L "$1" ] || { log "absent: $1"; return 0; }
  run "remove $1" rm -f "$1"
}
rm_dir() { # path (a dedicated directory this installer created)
  [ -e "$1" ] || { log "absent: $1"; return 0; }
  run "remove directory $1" rm -rf "$1"
}
rm_file "$PAUSE_DIR/${HOST}.pause.json"
rm_file "$PAUSE_DIR/${HOST}.provision-manifest"   # XACA-1443-015: the record provision-host.sh made of this host
rm_dir  "$PAUSE_DIR/.${HOST}.lock"
if [ "$DRY" = 0 ]; then rmdir "$PAUSE_DIR" 2>/dev/null || true; fi
if [ "$OTHERS" -eq 0 ]; then
  rm_file "$CI_HOME/.aiteamforge/fleet-config.json"
  rm_dir  "$AGENT_CFG_DIR"
  rm_dir  "$AGENT_STATE_DIR"
  rm_dir  "$AGENT_LOG_DIR"
  # ---- 6. root-owned copies (no host suffix in the names: shared) ----------------------------------
  for f in ci-pool-agent.py ci-runner-reporter.sh ci-runner-jit-macos.sh ci-runner-job-started.sh; do
    rm_file "$LIBEXEC_DIR/$f"
  done
else
  log "${OTHERS} other ci-runner daemon plist(s) installed: keeping the shared agent dirs, fleet-config and ${LIBEXEC_DIR} copies"
fi

# ---- 7. plists last --------------------------------------------------------------------------------------
if [ "$FAILS" -gt 0 ] && [ "$DRY" = 0 ]; then
  warn "an earlier step failed: plists KEPT so 'ci disable --confirm' refuses"
else
  for k in $LABELS_ORDER; do rm_file "$(plist_of "$k")"; done
fi

# ---- 8. the user (opt-in) ------------------------------------------------------------------------------------
if [ "$REMOVE_USER" = 1 ]; then
  if user_exists; then
    run "delete user ${CI_USER} (sysadminctl -deleteUser)" sysadminctl -deleteUser "$CI_USER"
  else
    log "user ${CI_USER}: already absent"
  fi
  if dscl . -read "/Groups/${CI_USER}" PrimaryGroupID >/dev/null 2>&1; then
    run "delete group ${CI_USER}" dseditgroup -o delete "$CI_USER"
  fi
  if [ -d "$CI_HOME" ]; then
    case "${CI_HOME##*/}" in
      "$CI_USER") run "remove home ${CI_HOME}" rm -rf "$CI_HOME" ;;
      *) warn "not removing ${CI_HOME}: its name is not '${CI_USER}'"; FAILS=$((FAILS + 1)) ;;
    esac
  fi
else
  log "user ${CI_USER} kept (pass --remove-user to delete it, its group and its home)"
fi

cat <<EOF

Not done by this script (server side, needs a Fleet Monitor admin):
  - revoke the keys:  DELETE /api/ci-pool/machines/${HOST}/key  and  .../telemetry-key
  - drop the machine record and trim the repo allowlist (runbook 13.2)
  - GitHub: JIT runners are single-use and need no removal; remove the GitHub App install yourself if unwanted
EOF

if [ "$FAILS" -gt 0 ]; then result INCOMPLETE 1; exit 1; fi
if [ "$DRY" = 1 ]; then result DRY_RUN 0; else result TEARDOWN_OK 0; fi
exit 0
