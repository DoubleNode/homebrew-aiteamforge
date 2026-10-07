#!/usr/bin/env bash
# create-ci-runner-user.sh — Create the dedicated, non-admin `ci-runner` macOS
# user that owns the self-hosted GitHub Actions runners on M1Mini (XACA-1385).
#
# Run ON the runner host, as an admin, under sudo:
#   sudo bash create-ci-runner-user.sh
#
# Idempotent: every step checks current state first, so re-running is safe and
# converges an existing account to the same shape.
#
# ── WHAT IT CREATES ────────────────────────────────────────────────────────
#   * group `ci-runner` (dedicated gid) and user `ci-runner`, non-admin
#   * PrimaryGroupID = the dedicated gid, NOT staff (20). macOS homes default
#     to 750 root-group `staff`, so a staff-primary CI user could read every
#     other user's home. CI jobs execute arbitrary repo code; they must not.
#   * hidden from the login window (IsHidden=1); random password that is
#     printed nowhere and stored nowhere — the account is driven only by
#     launchd (UserName=ci-runner) and `sudo -u`, never by interactive login.
#   * home /Users/ci-runner at mode 700.
#
# ── WHAT IT DOES NOT DO ────────────────────────────────────────────────────
#   No runner registration, no LaunchDaemons, no Lima VM. Those belong to the
#   provisioning script. It also never changes OTHER users' home modes — it
#   only REPORTS what ci-runner can read, so the operator can decide.
#
# Exit: 0 = account in place and isolation report printed; 1 = failure.

set -euo pipefail

# CI_RUNNER_USER / CI_RUNNER_HOME: the same test overrides teardown-host.sh and provision-host.sh honour
# (XACA-1443-015: the refresh idempotency test runs this script for real, in a sandbox). sudo's env_reset
# drops them for a real run, so unset = /Users/ci-runner.
CI_USER="${CI_RUNNER_USER:-ci-runner}"
CI_GROUP="ci-runner"
CI_FULLNAME="CI Runner"
CI_HOME="${CI_RUNNER_HOME:-/Users/${CI_USER}}"
GID_RANGE_START=600
GID_RANGE_END=699

log() { printf '[create-ci-runner-user] %s\n' "$*"; }
die() { printf '[create-ci-runner-user] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only"
[ "$(id -u)" -eq 0 ] || die "run under sudo"

# ── 1. Dedicated group ────────────────────────────────────────────────────
if dscl . -read "/Groups/${CI_GROUP}" PrimaryGroupID >/dev/null 2>&1; then
  CI_GID=$(dscl . -read "/Groups/${CI_GROUP}" PrimaryGroupID | awk '{print $2}')
  log "group ${CI_GROUP} exists (gid ${CI_GID})"
else
  CI_GID=""
  used_gids=$(dscl . -list /Groups PrimaryGroupID | awk '{print $2}')
  for gid in $(seq "$GID_RANGE_START" "$GID_RANGE_END"); do
    if ! grep -qx "$gid" <<<"$used_gids"; then CI_GID=$gid; break; fi
  done
  [ -n "$CI_GID" ] || die "no free gid in ${GID_RANGE_START}-${GID_RANGE_END}"
  dseditgroup -o create -i "$CI_GID" -r "CI Runner" "$CI_GROUP"
  log "created group ${CI_GROUP} (gid ${CI_GID})"
fi

# ── 2. User ───────────────────────────────────────────────────────────────
if id "$CI_USER" >/dev/null 2>&1; then
  log "user ${CI_USER} exists (uid $(id -u "$CI_USER"))"
else
  pw=$(openssl rand -base64 33)
  sysadminctl -addUser "$CI_USER" -fullName "$CI_FULLNAME" \
    -password "$pw" -home "$CI_HOME" -shell /bin/zsh
  unset pw
  id "$CI_USER" >/dev/null 2>&1 || die "sysadminctl did not create ${CI_USER}"
  log "created user ${CI_USER} (uid $(id -u "$CI_USER"))"
fi

# ── 3. Converge account shape ─────────────────────────────────────────────
if dseditgroup -o checkmember -m "$CI_USER" admin >/dev/null 2>&1; then
  dseditgroup -o edit -d "$CI_USER" -t user admin
  log "removed ${CI_USER} from admin"
fi
dscl . -create "/Users/${CI_USER}" PrimaryGroupID "$CI_GID"
dscl . -create "/Users/${CI_USER}" IsHidden 1
dseditgroup -o edit -a "$CI_USER" -t user "$CI_GROUP"

if [ ! -d "$CI_HOME" ]; then
  createhomedir -c -u "$CI_USER" >/dev/null
fi
[ -d "$CI_HOME" ] || die "home ${CI_HOME} missing after createhomedir"
chown -R "${CI_USER}:${CI_GROUP}" "$CI_HOME"
chmod 700 "$CI_HOME"
log "account converged: non-admin, hidden, primary group ${CI_GROUP}, home 700"

# ── 4. Isolation report (measured, read-only) ─────────────────────────────
# Mode bits alone don't answer this — group membership can be indirect — so
# ask the kernel by actually trying, as ci-runner.
log "id: $(id "$CI_USER")"
if dseditgroup -o checkmember -m "$CI_USER" admin >/dev/null 2>&1; then
  die "${CI_USER} is still an admin"
fi
log "isolation report — what ${CI_USER} can read in other homes:"
exposed=0
for home in /Users/*; do
  owner=$(basename "$home")
  case "$owner" in Shared|Library|"$CI_USER") continue ;; esac
  [ -d "$home" ] || continue
  if sudo -u "$CI_USER" ls "$home" >/dev/null 2>&1; then
    log "  READABLE  ${home}  ($(stat -f '%Sp %Su:%Sg' "$home"))"
    exposed=$((exposed + 1))
  else
    log "  blocked   ${home}"
  fi
done
if [ "$exposed" -gt 0 ]; then
  log "WARNING: ${exposed} other home(s) readable by ${CI_USER}; CI jobs could read them."
  log "         Not changed automatically — decide per home (e.g. chmod 750/700)."
fi
log "done"
