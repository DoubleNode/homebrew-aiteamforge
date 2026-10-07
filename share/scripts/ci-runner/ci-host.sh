#!/usr/bin/env bash
# ci-host.sh - pause / resume / status of a self-hosted CI host (XACA-1440).
#
# Thin CLI over lib/ci-host-lib.sh. Run it ON the CI host as an admin user
# (privileged steps use `sudo -n`; no SSH anywhere). Design:
# kanban/plans/XACA-1440/XACA-1440_ci_host_design.md
#
#   ci-host.sh pause  --host H [--reason TEXT] [--drain-timeout SECS] [--redirect-to HOST] [--force] [--dry-run]
#   ci-host.sh resume --host H [--online-timeout SECS] [--dry-run]
#   ci-host.sh status --host H [--json]
#
# The last stdout line is always:  RESULT: <NAME> host=<h> rc=<n> detail=<...>
# (with `status --json` the RESULT line goes to stderr so stdout stays pure JSON).
set -u

_CIH_CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci-host-lib.sh
. "${CIH_LIB:-$_CIH_CLI_DIR/lib/ci-host-lib.sh}"

usage() {
  cat <<'USAGE'
Usage:
  ci-host.sh pause  --host H [--reason TEXT] [--drain-timeout SECS] [--redirect-to HOST] [--force] [--dry-run]
  ci-host.sh resume --host H [--online-timeout SECS] [--dry-run]
  ci-host.sh status --host H [--json]

H is m1mini or m4mini (any case). Run ON the CI host as an admin user.
pause drains (never cancels a job), then stops the runners and the VM.
Defaults: --drain-timeout 3600, --online-timeout 300.
--drain-timeout must be at least two poll intervals (30 s at the default 15 s poll); smaller is a usage error (rc 2).

Exit codes (stable; the last stdout line is `RESULT: <NAME> host=<h> rc=<n> detail=<...>`):
  rc  NAME            Meaning
   0  OK / NOOP       Done, or already in the requested state (idempotent re-run; `NOOP` in the RESULT line). `status`: active and healthy.
   1  INTERNAL        Bug or unexpected condition.
   2  USAGE           Bad or missing flag, unknown host.
   3  REFUSED         Routing precondition (R1, R2 fallback dead, malformed variable, `--redirect-to` target offline). Zero mutating calls made.
   4  DRAIN_TIMEOUT   H still busy, or still has pinned queued jobs, at `--drain-timeout`. Routing already moved; nothing stopped.
   5  ENV             Host not provisioned on this machine (`PLIST_VM` absent), `sudo -n` unavailable, `limactl` or python3 missing. Checked before any GitHub call.
   6  GITHUB          `gh` unauthenticated or not admin, an API/network error, an identity conflict, zero runners for H, or any response not classifiable as exactly what was asked for.
   7  LOCAL_SERVICE   A unit, daemon, VM stop or VM start failed, or the VM did not reach `Stopped`/`Running` within 120 s.
   8  ONLINE_TIMEOUT  `resume`: H's runners not all `online` within `--online-timeout` (default 300 s). Variables not restored.
   9  STATE_CONFLICT  Corrupt or foreign marker, live lock, saved-vs-live mismatch on re-pause, or `pause` during `resuming`. Refuses to guess.
  10  PAUSED          `status` only: marker `paused`, reality agrees.
  11  TRANSITIONAL    `status` only: `draining`/`resuming`, drift, or corrupt marker.
  12  DEGRADED        `status` only: active (no marker), but VM down or H's runners not online.
USAGE
}

main() {
  local cmd="${1:-}" rc json=0 a
  case "$cmd" in
    -h|--help|help) usage; return 0 ;;
    pause|resume|status) shift ;;
    '') usage >&2; CIH_HOST=""; CIH_RESULT_NAME=USAGE; CIH_RESULT_DETAIL="no command"; _emit 2; return 2 ;;
    *)  usage >&2; CIH_HOST=""; CIH_RESULT_NAME=USAGE; CIH_RESULT_DETAIL="unknown command '$cmd'"; _emit 2; return 2 ;;
  esac
  for a in "$@"; do
    case "$a" in -h|--help) usage; return 0 ;; --json) json=1 ;; esac
  done
  trap '[ -z "${CIH_HOST:-}" ] || cih_lock_release "$CIH_HOST"' EXIT
  "cih_cmd_$cmd" "$@"; rc=$?
  [ "$json" = "1" ] && [ "$cmd" = "status" ] && _CIH_RESULT_TO_STDERR=1
  _emit "$rc"
  return "$rc"
}

_emit() { # RC
  local rc="$1" name="${CIH_RESULT_NAME:-}" detail="${CIH_RESULT_DETAIL:-}"
  [ -n "$name" ] || name="$(_cih_name_for_rc "$rc")"
  [ -n "$detail" ] || { [ "$rc" = "0" ] && detail="ok" || detail="see messages above"; }
  detail="$(printf '%s' "$detail" | tr '\n' ' ')"
  if [ -n "${_CIH_RESULT_TO_STDERR:-}" ]; then
    printf 'RESULT: %s host=%s rc=%s detail=%s\n' "$name" "${CIH_HOST:-}" "$rc" "$detail" >&2
  else
    printf 'RESULT: %s host=%s rc=%s detail=%s\n' "$name" "${CIH_HOST:-}" "$rc" "$detail"
  fi
}

main "$@"
exit $?
