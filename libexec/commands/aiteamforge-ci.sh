#!/bin/bash
# aiteamforge-ci.sh - `aiteamforge ci ...` (XACA-1443). TAP-NATIVE: edit it here, it has no
# canonical source in dev-team (commit with the trailer `Tap-Only-Edit: intentional`).
#
#   aiteamforge ci enable [flags]    XACA-1443-002 (this file)
#   aiteamforge ci disable           XACA-1443-003 (this file; root half: bundle teardown-host.sh)
#   aiteamforge ci refresh           XACA-1443-013/-015 (this file; root half: bundle provision-host.sh again;
#                                    skew logic: bundle lib/ci-provision-version.sh, sourceable by 004)
#   aiteamforge ci status            XACA-1443-004 (this file; classifier: bundle lib/ci-status.sh, shared with `aiteamforge doctor`)
#
# `ci enable` runs as the INVOKING USER and NEVER runs sudo, launchctl, dscl, limactl, curl or
# gh. It checks, validates, records a state file and PRINTS one sudo command for the operator
# to read and run. The bundle it prints a path into is the dormant one the tap placed under
# $AITEAMFORGE_DIR/scripts/ci-runner/ (XACA-1443-001); nothing else in the tap references it.
#
# State file contract: kanban/plans/XACA-1443/XACA-1443-002_ci_state_contract.md (dev-team).
# Portability: /bin/bash 3.2 and bash 5. No `set -e`/`-u`: every return code below is explicit.

set -o pipefail

AITEAMFORGE_DIR="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
CI_BUNDLE_DIR="${AITEAMFORGE_DIR}/scripts/ci-runner"
CI_STATE_FILE="${AITEAMFORGE_DIR}/.aiteamforge-ci-state"
CI_LIMACTL_PATH="${CI_LIMACTL_PATH:-/opt/homebrew/bin/limactl}"   # provision-host.sh hardcodes this path
CI_LAUNCHDAEMONS_DIR="${CI_LAUNCHDAEMONS_DIR:-/Library/LaunchDaemons}"
CI_RUNNER_USER="${CI_RUNNER_USER:-ci-runner}"
# Root-owned paths `ci disable` READS (never writes) to verify a teardown; same names teardown-host.sh uses.
CI_LIBEXEC_DIR="${CI_LIBEXEC_DIR:-/usr/local/libexec}"
CI_AGENT_CFG_DIR="${CI_AGENT_CFG_DIR:-/usr/local/etc/ci-pool-agent}"
CIH_STATE_DIR="${CIH_STATE_DIR:-/usr/local/etc/ci-runner}"

# Exit codes (also in `ci enable --help`).
RC_OK=0 RC_ENV=1 RC_USAGE=2
RC_HEADROOM=12 RC_NO_FIT=13 RC_NO_LIMA=14 RC_PROBE=16 RC_STATE=17 RC_NOT_PROVISIONED=18
RC_LEFTOVERS=19   # disable --confirm: teardown artefacts remain
RC_REFRESH_PENDING=20   # refresh --confirm: the host does not match the keg yet (or cannot be verified)
RC_STATUS_USAGE=21      # ci status: bad option (status itself exits 0 ok | 1 warn | 2 fail, the doctor's levels)
# 10 / 11 are ci_enable_guard's own codes, passed through unchanged.

_err()  { echo "ERROR: $*" >&2; }
_warn() { echo "WARNING: $*" >&2; }
_now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

usage() {
  cat <<'EOF'
Usage: aiteamforge ci <enable|disable|refresh|status> [options]

  enable     Check this machine, record the CI configuration, print ONE sudo command
  disable    Tear CI down: print ONE sudo teardown command, then verify with --confirm
  refresh    Bring an ENABLED host up to date after an upgrade: print ONE sudo command, then --confirm
  status     Report dormant|enable-pending|enabled|paused|disable-pending|misconfigured + provision skew (read-only)

CI is dormant on every install until you run `aiteamforge ci enable`.
For details: aiteamforge ci enable --help | aiteamforge ci disable --help | aiteamforge ci refresh --help | aiteamforge ci status --help
EOF
}

enable_usage() {
  cat <<'EOF'
Usage: aiteamforge ci enable --github-app-install-id <id> --repo <owner/repo> [--repo ...]
                             --agent-key-file <path> --telemetry-key-file <path>
                             [--server-url <https-url>] [--host <name>] [--with-macos]
                             [--dry-run]
       aiteamforge ci enable --confirm
       aiteamforge ci enable --help

Runs as YOU. It never runs sudo. It checks the machine, records a state file
($AITEAMFORGE_DIR/.aiteamforge-ci-state, mode 600) and prints ONE sudo command that you read
and run yourself. Missing required values are prompted for on a terminal; without one they
are an error.

  --github-app-install-id <id>  numeric installation id of YOUR GitHub App (see runbook 13.1)
  --repo <owner/repo>           allowlisted repo, repeatable; also --repos a/b,c/d (exact names,
                                no wildcards). Must match the repos ticked on the App install.
  --agent-key-file <path>       per-host dispatch key file (fcp_ + 43 chars; XACA-1441)
  --telemetry-key-file <path>   per-host telemetry key file (fct_ + 43 chars; XACA-1422)
                                Key VALUES never go on the command line, in the state file, or
                                in this command's output; only file paths do.
  --server-url <url>            Fleet Monitor base URL (https only); default: the one in
                                your fleet config
  --host <name>                 machine name registered in Fleet Monitor (default: this
                                machine's short hostname, lower-cased)
  --with-macos                  also provision the macOS runner lane (default: Linux VM only)
  --dry-run                     do every check and print the plan and the command, but write
                                NOTHING (no state file)
  --confirm                     AFTER you ran the sudo command: verify the host is provisioned
                                and promote the state enabled-pending -> enabled

Refuses (nothing written) when: this is the dev-team source machine or a git work-tree install
(10/11), memory headroom is short (12), no VM size fits (13), limactl is missing (14), the
probe cannot read memory (16), CI is already enabled (17).

Headroom (memory only; swap is elastic and never gates): refuse if memory free < 25% or
free+inactive+purgeable < 1.5 GiB. Guest sizing (a judgement calibrated on one 16 GiB host):
RAM = min(4 GiB, host RAM/4, headroom above the 1.5 GiB floor); vCPU = min(4, cores/2);
refuse below 2 GiB or 2 vCPU.

Exit codes: 0 ok | 1 environment (not configured, bundle missing) | 2 usage / invalid input
  10 dev-team source machine | 11 git work-tree install | 12 headroom refusal | 13 no VM size fits
  14 limactl missing (run `brew install lima` as yourself first) | 16 memory probe unreadable
  17 CI already enabled | 18 --confirm: host not provisioned yet
EOF
}

# ---------------------------------------------------------------- validation helpers

_is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# Installation id: positive integer, no leading zero, <= 15 digits.
_valid_install_id() {
  _is_uint "$1" || return 1
  case "$1" in 0*) return 1 ;; esac
  [ "${#1}" -le 15 ]
}

# owner/repo, exact. owner: [A-Za-z0-9-], no leading/trailing '-', <= 39. repo: [A-Za-z0-9._-],
# <= 100, not '.', '..' or '*.git'. No wildcards, no whitespace, no second slash.
_valid_repo() {
  local o r
  case "$1" in */*/*|/*|*/) return 1 ;; */*) ;; *) return 1 ;; esac
  o="${1%%/*}"; r="${1#*/}"
  [ -n "$o" ] && [ -n "$r" ] || return 1
  [ "${#o}" -le 39 ] && [ "${#r}" -le 100 ] || return 1
  case "$o" in -*|*-|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;; esac
  case "$r" in .|..|*.git|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) return 1 ;; esac
  return 0
}

# Same rules as provision-host.sh --host / agent_url_ok (it re-validates; this fails earlier).
_valid_host() {
  case "$1" in
    '') return 1 ;;
    [!a-z0-9]*|*[!a-z0-9-]*|*-) return 1 ;;
  esac
  [ "${#1}" -le 40 ]
}
_valid_url() {
  case "$1" in https://?*) ;; *) return 1 ;; esac
  case "$1" in *[!A-Za-z0-9._~:/%+=-]*) return 1 ;; esac
  return 0
}

# Key file shape (one line: <prefix> + 43 chars of [A-Za-z0-9_-]); the value is read through a
# redirect and never printed or put in argv. rc 0 ok | 1 wrong shape | 2 unreadable.
# Mirrors provision-host.sh agent_key_check / telemetry_key_check, which re-check at run time.
_key_check() { # path prefix
  local first="" second=""
  [ -f "$1" ] && [ -r "$1" ] || return 2
  { IFS= read -r first || true; IFS= read -r second || true; } <"$1"
  first="${first%$'\r'}"; second="${second%$'\r'}"
  [ -z "$second" ] || return 1
  case "$first" in "$2"?*) ;; *) return 1 ;; esac
  case "${first#"$2"}" in
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*) return 1 ;;
  esac
  [ "${#first}" -eq $((${#2} + 43)) ]
}

_abs_path() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }

_state_get() { # key -> value of the first matching line, else empty
  [ -f "$CI_STATE_FILE" ] || return 0
  awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$CI_STATE_FILE"
}

_gib() { awk -v b="$1" 'BEGIN { printf "%.2f", b / 1073741824 }'; }
_sha256() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

# XACA-1443-016: the client payload the root half installs must be in the bundle BEFORE the sudo line is printed:
# the line starts with create-ci-runner-user.sh, so a payload that is missing only at install time would leave a
# created user and a half-provisioned host. provision-host.sh re-checks (payload_preflight) before any change.
# usage: _ci_payload_check <with_macos 0|1>; rc 0 ok | RC_ENV (names what is missing)
_ci_payload_check() {
  local f missing="" need="ci-runner-reporter.sh ci-pool-agent.py ci-runner-jit-guest.sh ci-runner-job-started.sh"
  [ "${1:-1}" = 1 ] && need="$need ci-runner-jit-macos.sh"
  for f in $need; do [ -f "$CI_BUNDLE_DIR/client/$f" ] || missing="${missing} client/${f}"; done
  [ -z "$missing" ] && return 0
  _err "CI bundle incomplete ($CI_BUNDLE_DIR is missing:${missing}). Run: aiteamforge upgrade"
  return $RC_ENV
}

# Load the provision-version / skew library (XACA-1443-013) from the bundle. rc 0 | RC_ENV.
_load_pv_lib() {
  local l="$CI_BUNDLE_DIR/lib/ci-provision-version.sh"
  if [ ! -r "$l" ]; then _err "CI bundle incomplete ($l missing). Run: aiteamforge upgrade"; return $RC_ENV; fi
  # shellcheck source=/dev/null
  . "$l" || { _err "cannot load $l"; return $RC_ENV; }
}

# Rewrite the state file atomically: each `key=value` argument REPLACES the key's line(s) in place, or is
# appended when the key is absent; every other line (unknown keys, comments) is kept. Mode 600.
_ci_state_set() {
  local tmp old_umask pairs=""
  while [ $# -gt 0 ]; do pairs="${pairs}${1}
"; shift; done
  old_umask="$(umask)"; umask 077
  tmp="$(mktemp "${CI_STATE_FILE}.XXXXXX")" || { umask "$old_umask"; _err "cannot create a temp file next to $CI_STATE_FILE"; return $RC_ENV; }
  PAIRS="$pairs" awk '
    BEGIN { n = split(ENVIRON["PAIRS"], a, "\n")
            for (i = 1; i <= n; i++) { if (a[i] == "") continue; e = index(a[i], "="); k = substr(a[i], 1, e - 1); v[k] = substr(a[i], e + 1); order[++m] = k } }
    { k = $0; sub(/=.*/, "", k)
      if ($0 !~ /^#/ && (k in v)) { print k "=" v[k]; seen[k] = 1; next }
      print }
    END { for (i = 1; i <= m; i++) if (!(order[i] in seen)) print order[i] "=" v[order[i]] }' "$CI_STATE_FILE" >"$tmp" \
    && chmod 600 "$tmp" && mv -f "$tmp" "$CI_STATE_FILE" \
    || { umask "$old_umask"; rm -f "$tmp"; _err "cannot update $CI_STATE_FILE"; return $RC_ENV; }
  umask "$old_umask"
  return 0
}

_prompt() { # varname label  (terminal only; the answers are ids/paths/URLs, never secrets)
  local ans=""
  printf '%s: ' "$2" >&2
  IFS= read -r ans || ans=""
  eval "$1=\$ans"
}

# ---------------------------------------------------------------- enable

# Guard (XACA-1443-005), shared by enable and disable. Returns the guard's own rc (10/11) or RC_ENV.
_run_guard() {
  local guard_lib="$CI_BUNDLE_DIR/lib/ci-enable-guard.sh" grc=0
  if [ ! -r "$guard_lib" ]; then
    _err "CI bundle missing ($guard_lib). Run: aiteamforge upgrade"
    return $RC_ENV
  fi
  # shellcheck source=/dev/null
  . "$guard_lib" || { _err "cannot load $guard_lib"; return $RC_ENV; }
  ci_enable_guard || grc=$?
  return "$grc"
}


cmd_enable() {
  local a
  for a in "$@"; do
    case "$a" in -h|--help) enable_usage; return $RC_OK ;; esac
  done

  # ---- 1. GUARD FIRST (XACA-1443-005): before parsing, prompting, measuring or writing anything.
  _run_guard || return $?

  # ---- 2. flags
  local install_id="" repos_raw="" agent_key="" tele_key="" server_url="" host="" with_macos=0
  local dry=0 confirm=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --github-app-install-id) [ $# -ge 2 ] || { _err "$1 needs a value"; return $RC_USAGE; }; install_id="$2"; shift 2 ;;
      --repo|--repos)          [ $# -ge 2 ] || { _err "$1 needs a value"; return $RC_USAGE; }; repos_raw="${repos_raw:+${repos_raw},}$2"; shift 2 ;;
      --agent-key-file)        [ $# -ge 2 ] || { _err "$1 needs a path"; return $RC_USAGE; }; agent_key="$2"; shift 2 ;;
      --telemetry-key-file)    [ $# -ge 2 ] || { _err "$1 needs a path"; return $RC_USAGE; }; tele_key="$2"; shift 2 ;;
      --server-url)            [ $# -ge 2 ] || { _err "$1 needs a URL"; return $RC_USAGE; }; server_url="$2"; shift 2 ;;
      --host)                  [ $# -ge 2 ] || { _err "$1 needs a name"; return $RC_USAGE; }; host="$2"; shift 2 ;;
      --with-macos) with_macos=1; shift ;;
      --dry-run)    dry=1; shift ;;
      --confirm)    confirm=1; shift ;;
      *) _err "unknown option: $1"; enable_usage >&2; return $RC_USAGE ;;
    esac
  done

  if [ ! -f "$AITEAMFORGE_DIR/.aiteamforge-config" ]; then
    _err "AITeamForge is not configured ($AITEAMFORGE_DIR/.aiteamforge-config missing). Run: aiteamforge setup"
    return $RC_ENV
  fi

  if [ "$confirm" = 1 ]; then
    [ -z "$install_id$repos_raw$agent_key$tele_key$server_url$host" ] && [ "$with_macos" = 0 ] && [ "$dry" = 0 ] \
      || { _err "--confirm takes no other options"; return $RC_USAGE; }
    cmd_enable_confirm
    return $?
  fi

  # ---- 3. gather missing values (terminal) / validate everything (before any measurement)
  if [ -t 0 ]; then
    [ -n "$install_id" ] || _prompt install_id "GitHub App installation id (numeric)"
    [ -n "$repos_raw" ]  || _prompt repos_raw  "Repo allowlist (owner/repo, comma separated)"
    [ -n "$agent_key" ]  || _prompt agent_key  "Path to the per-host dispatch key file (fcp_...)"
    [ -n "$tele_key" ]   || _prompt tele_key   "Path to the per-host telemetry key file (fct_...)"
  fi
  if [ -z "$host" ]; then
    host="$(hostname -s 2>/dev/null | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n-' '-' | sed 's/^-*//; s/-*$//')"
  fi

  local bad=0
  _valid_install_id "$install_id" || { _err "--github-app-install-id must be a positive integer (digits only, <= 15), got '${install_id}'"; bad=1; }
  _valid_host "$host" || { _err "--host must match [a-z0-9]([a-z0-9-]*[a-z0-9])?, got '${host}'"; bad=1; }
  if [ -n "$server_url" ] && ! _valid_url "$server_url"; then
    _err "--server-url must be an https:// URL using only [A-Za-z0-9._~:/%+=-], got '${server_url}'"; bad=1
  fi

  local allow="" n=0 entry rest
  if [ -z "$repos_raw" ]; then
    _err "a repo allowlist is required (--repo owner/repo, repeatable)"; bad=1
  else
    rest="$repos_raw,"
    while [ -n "$rest" ]; do
      entry="${rest%%,*}"; rest="${rest#*,}"
      if ! _valid_repo "$entry"; then
        _err "invalid allowlist entry '${entry}': expected exact owner/repo (no wildcards, no spaces)"; bad=1; continue
      fi
      case ",$allow," in *",$entry,"*) continue ;; esac
      allow="${allow:+${allow},}${entry}"; n=$((n + 1))
    done
    [ "$n" -le 100 ] || { _err "allowlist is capped at 100 repos, got $n"; bad=1; }
  fi

  local krc
  if [ -z "$agent_key" ]; then _err "--agent-key-file is required (the per-host fcp_ dispatch key)"; bad=1
  else
    krc=0; _key_check "$agent_key" "fcp_" || krc=$?
    case "$krc" in
      0) ;;
      1) _err "--agent-key-file does not hold a per-host dispatch key (one line, fcp_ + 43 chars); refusing. The fleet-wide token must never be placed here."; bad=1 ;;
      *) if [ "$dry" = 1 ]; then _warn "--agent-key-file not readable yet: $agent_key"; else _err "--agent-key-file not readable: $agent_key"; bad=1; fi ;;
    esac
  fi
  if [ -z "$tele_key" ]; then _err "--telemetry-key-file is required (the per-host fct_ key; enable refuses to run on the fleet-wide token)"; bad=1
  else
    krc=0; _key_check "$tele_key" "fct_" || krc=$?
    case "$krc" in
      0) ;;
      1) _err "--telemetry-key-file does not hold a per-host telemetry key (one line, fct_ + 43 chars); refusing. The fleet-wide token must never be placed on this host."; bad=1 ;;
      *) if [ "$dry" = 1 ]; then _warn "--telemetry-key-file not readable yet: $tele_key"; else _err "--telemetry-key-file not readable: $tele_key"; bad=1; fi ;;
    esac
  fi
  [ "$bad" = 0 ] || { echo "Run: aiteamforge ci enable --help" >&2; return $RC_USAGE; }
  agent_key="$(_abs_path "$agent_key")"; tele_key="$(_abs_path "$tele_key")"

  # ---- 4. limactl (D4: never install software; tell the operator, stop)
  if [ ! -x "$CI_LIMACTL_PATH" ]; then
    _err "limactl not found at $CI_LIMACTL_PATH."
    echo "Step 0, as yourself (Homebrew refuses root):  brew install lima" >&2
    echo "Then re-run: aiteamforge ci enable ..." >&2
    return $RC_NO_LIMA
  fi

  # ---- 5. existing state
  local prev
  prev="$(_state_get state)"
  case "$prev" in
    enabled|disable-pending)
      _err "CI is already '${prev}' on this machine ($CI_STATE_FILE). Disable it first: aiteamforge ci disable"
      return $RC_STATE ;;
  esac

  # ---- 6. headroom (read-only)
  local hr_lib="$CI_BUNDLE_DIR/lib/ci-headroom.sh" mrc=0 vrc=0 srcc=0
  if [ ! -r "$hr_lib" ]; then _err "CI bundle incomplete ($hr_lib missing). Run: aiteamforge upgrade"; return $RC_ENV; fi
  # shellcheck source=/dev/null
  . "$hr_lib" || { _err "cannot load $hr_lib"; return $RC_ENV; }
  echo "Measuring memory headroom (${CI_HR_SAMPLES:-3} samples; memory only, swap never gates)..."
  ci_headroom_measure || mrc=$?
  if [ "$mrc" -ne 0 ]; then
    _err "could not read this machine's memory state (memory_pressure / vm_stat / sysctl). Refusing: an unreadable probe is a refusal, not a pass."
    return $RC_PROBE
  fi
  ci_headroom_verdict || vrc=$?
  echo "  memory free            : ${CI_HR_FREE_PCT}%   (refuse below ${CI_HR_MIN_FREE_PCT}%)"
  echo "  free+inactive+purgeable: $(_gib "$CI_HR_FIP_BYTES") GiB   (refuse below $(_gib "$CI_HR_MIN_FIP_BYTES") GiB)"
  echo "  host                   : $(_gib "$CI_HR_MEMSIZE") GiB RAM, ${CI_HR_NCPU} cores"
  if [ "$vrc" -ne 0 ]; then
    _err "not enough memory headroom: ${CI_HR_REASONS}. Free some memory and re-run."
    return $RC_HEADROOM
  fi
  ci_headroom_size || srcc=$?
  if [ "$srcc" -ne 0 ]; then
    _err "headroom passes but no guest size fits (needs >= ${CI_HR_VM_GIB_MIN} GiB RAM and >= ${CI_HR_VM_CPU_MIN} vCPU; computed ${CI_HR_VM_GIB} GiB / ${CI_HR_VM_CPUS} vCPU)."
    return $RC_NO_FIT
  fi
  echo "  proposed guest         : ${CI_HR_VM_GIB} GiB RAM / ${CI_HR_VM_CPUS} vCPU / ${CI_HR_LINUX_SLOTS} Linux job slot(s)   (judgement, calibrated on one 16 GiB host)"

  _ci_payload_check "$with_macos" || return $?

  # ---- 7. the ONE sudo command
  local create_sh="$CI_BUNDLE_DIR/create-ci-runner-user.sh" prov_sh="$CI_BUNDLE_DIR/provision-host.sh"
  local pargs=(--host "$host" --no-register --vm-cpus "$CI_HR_VM_CPUS" --vm-memory "$CI_HR_VM_GIB"
               --linux-count "$CI_HR_LINUX_SLOTS")
  [ "$with_macos" = 1 ] || pargs=("${pargs[@]}" --no-macos)
  pargs=("${pargs[@]}" --with-agent --agent-key-file "$agent_key" --telemetry-key-file "$tele_key")
  [ -z "$server_url" ] || pargs=("${pargs[@]}" --server-url "$server_url")
  local sudo_line="sudo /bin/bash -c 'bash \"\$1\" && shift && exec bash \"\$@\"' _ $(printf '%q' "$create_sh") $(printf '%q' "$prov_sh")"
  local p
  for p in "${pargs[@]}"; do sudo_line="$sudo_line $(printf '%q' "$p")"; done
  local dry_line="bash $(printf '%q' "$prov_sh")"
  for p in "${pargs[@]}"; do dry_line="$dry_line $(printf '%q' "$p")"; done
  dry_line="$dry_line --dry-run"

  # ---- 8. state file (never in --dry-run)
  local ts; ts="$(_now)"
  if [ "$dry" = 1 ]; then
    echo "[dry-run] would write $CI_STATE_FILE (state=enabled-pending). Nothing was written."
  else
    local tmp old_umask created
    created="$(_state_get created_at)"; [ -n "$created" ] || created="$ts"
    old_umask="$(umask)"; umask 077
    tmp="$(mktemp "${CI_STATE_FILE}.XXXXXX")" || { umask "$old_umask"; _err "cannot create a temp file next to $CI_STATE_FILE"; return $RC_ENV; }
    {
      echo "# aiteamforge CI state v1 - written by 'aiteamforge ci enable'. No secrets. Contract: XACA-1443-002."
      echo "schema=1"
      echo "state=enabled-pending"
      echo "host=$host"
      echo "vm_cpus=$CI_HR_VM_CPUS"
      echo "vm_memory_gib=$CI_HR_VM_GIB"
      echo "linux_slots=$CI_HR_LINUX_SLOTS"
      echo "with_macos=$with_macos"
      echo "github_app_install_id=$install_id"
      echo "allowlist=$allow"
      echo "server_url=$server_url"
      echo "has_agent_key_file=1"
      echo "has_telemetry_key_file=1"
      echo "headroom_free_pct=$CI_HR_FREE_PCT"
      echo "headroom_fip_bytes=$CI_HR_FIP_BYTES"
      echo "headroom_checked_at=$ts"
      echo "bundle_dir=$CI_BUNDLE_DIR"
      echo "provision_version="
      echo "created_at=$created"
      echo "updated_at=$ts"
      echo "enabled_at="
    } >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$CI_STATE_FILE" \
      || { umask "$old_umask"; rm -f "$tmp"; _err "cannot write $CI_STATE_FILE"; return $RC_ENV; }
    umask "$old_umask"
    echo "State recorded: $CI_STATE_FILE (state=enabled-pending, mode 600)"
  fi

  # ---- 9. hand-off
  echo
  echo "GitHub App (yours, runbook 13.1): installation ${install_id}"
  echo "  review/adjust the repo selection: https://github.com/settings/installations/${install_id}"
  echo "  (organisation-owned App: https://github.com/organizations/<org>/settings/installations/${install_id})"
  echo "  Repo allowlist recorded (${n}): ${allow}"
  echo "  The allowlist is enforced by Fleet Monitor, not by this machine: register it with the admin"
  echo "  call in runbook 13.2 (PUT /api/ci-pool/config) and register machine '${host}' there."
  echo
  echo "Before you run it, inspect what will run as root (sha256):"
  echo "  $(_sha256 "$create_sh")  $create_sh"
  echo "  $(_sha256 "$prov_sh")  $prov_sh"
  echo "  $(_sha256 "$CI_BUNDLE_DIR/lib/ci-provision-version.sh")  $CI_BUNDLE_DIR/lib/ci-provision-version.sh   (sourced by provision-host.sh to write the provision manifest)"
  echo "  $(_sha256 "$CI_BUNDLE_DIR/lib/ci-runner-version.sh")  $CI_BUNDLE_DIR/lib/ci-runner-version.sh   (sourced by provision-host.sh: picks and sha256-verifies the actions/runner it stages)"
  echo "  $(_sha256 "$CI_BUNDLE_DIR/runner-pin.conf")  $CI_BUNDLE_DIR/runner-pin.conf   (data: the pinned fallback runner + digests)"
  echo
  echo "Preview, no root, changes nothing:"
  echo "$dry_line"
  echo
  echo "Then run this ONE command yourself (creates the ci-runner user, then provisions the host):"
  echo "$sudo_line"
  echo
  echo "Afterwards run: aiteamforge ci enable --confirm"
  return $RC_OK
}

# `ci enable --confirm`: user-level, read-only probes; promotes enabled-pending -> enabled.
cmd_enable_confirm() {
  local st host plist ts pv=""
  st="$(_state_get state)"
  case "$st" in
    enabled) echo "CI is already enabled (host $(_state_get host))."; return $RC_OK ;;
    enabled-pending) ;;
    *) _err "no pending enable to confirm (state='${st:-none}'). Run: aiteamforge ci enable ..."; return $RC_STATE ;;
  esac
  host="$(_state_get host)"
  _valid_host "$host" || { _err "state file has an invalid host '${host}'; re-run: aiteamforge ci enable"; return $RC_STATE; }
  plist="$CI_LAUNCHDAEMONS_DIR/com.doublenode.ci-runner.${host}.agent.plist"
  if ! id -u "$CI_RUNNER_USER" >/dev/null 2>&1 || [ ! -f "$plist" ]; then
    _err "host not provisioned yet: need user '${CI_RUNNER_USER}' and ${plist}. Run the sudo command 'ci enable' printed, then confirm."
    return $RC_NOT_PROVISIONED
  fi
  ts="$(_now)"
  # XACA-1443-015: record the provision version the root script wrote. A host provisioned by an older
  # provision-host.sh has no manifest: that must not block going live, but it is reported, never hidden.
  if _load_pv_lib 2>/dev/null; then
    if ci_provision_manifest_load "$host"; then pv="$CI_PM_VERSION"
    else _warn "no usable provision manifest for ${host} (${CI_PM_WHY:-absent}); provision_version left empty. Run: aiteamforge ci refresh"; fi
  else
    _warn "provision-version library missing; provision_version left empty"
  fi
  _ci_state_set state=enabled updated_at="$ts" enabled_at="$ts" provision_version="$pv" || return $?
  echo "CI enabled on ${host} (state=enabled, ${ts}${pv:+, provision version ${pv}})."
  return $RC_OK
}

# ---------------------------------------------------------------- disable

disable_usage() {
  cat <<'EOF'
Usage: aiteamforge ci disable [--remove-user] [--kill-running] [--vm-gone] [--dry-run]
       aiteamforge ci disable --confirm [--remove-user]
       aiteamforge ci disable --force [--host <name>] [...]      (recovery, see below)
       aiteamforge ci disable --help

Runs as YOU. It never runs sudo. Like `ci enable` it records the step in the state file
($AITEAMFORGE_DIR/.aiteamforge-ci-state: state=disable-pending) and prints ONE sudo command that
you read and run yourself. That command (the bundle's teardown-host.sh) stops and removes the
agent, reporter and VM daemons, deletes the Lima VM, removes the agent key / config, the reporter
fleet-config (holds the telemetry key), the pause marker, the root-owned copies and the plists.
Then `ci disable --confirm` verifies nothing is left and removes the state file: CI is dormant again.

  --remove-user     ALSO delete the ci-runner user, its group and /Users/ci-runner. Default: KEEP
                    the user (it is cheap and re-used by the next `ci enable`).
  --kill-running    pass through to the teardown: proceed although a pool job is running
                    (without it the teardown refuses, rc 3; if the job appears while the agent is being stopped the
                    agent stays stopped, nothing else is touched, and the way to resume is printed)
  --vm-gone         pass through to the teardown: limactl was removed from this machine but the ci-runner user
                    remains, so the Lima VM cannot be checked; you state it is gone. (An absent
                    ~ci-runner/.lima/<vm> directory is accepted without it; an unreadable one never is.)
  --dry-run         do the checks and print the plan and the command; write NOTHING
  --confirm         AFTER you ran the sudo command: verify the teardown and go dormant.
                    Refuses (rc 19, state kept) while any artefact remains.
  --force           the state file is missing, corrupt or wrong: ignore it and derive the host
                    from the daemon plists on disk (--host <name> to choose when several exist)

From dormant (no state file, nothing found) it is a no-op, rc 0. If the machine was `enabled-pending`
and nothing was ever provisioned (no plists, no ci-runner user) the state file is just removed: no
sudo needed. Refuses on the dev-team source machine / a git work-tree exactly like `ci enable`
(rc 10/11): the printed sudo line would act on THIS machine's launchd and users.

Runner registrations: `ci enable` provisions with --no-register and JIT runners are single-use, so
nothing persists on GitHub. Server-side items (revoke the keys, machine record, allowlist) are
listed by the teardown; they need a Fleet Monitor admin and are never done from here.

Exit codes: 0 ok / dormant / dry-run | 1 environment (bundle or teardown script missing)
  2 usage / invalid input (also: --force found no single host) | 10 dev-team source machine
  11 git work-tree install | 17 state conflict (corrupt state without --force; --confirm before
  `ci disable`) | 19 --confirm: teardown artefacts remain (listed)
The teardown script's own codes (run it by hand): 0 ok, 1 step failed, 2 usage, 3 job running,
4 --remove-user refused (other hosts), 5 not root.
EOF
}

# Daemon plists of ONE host on disk (the 4 labels provision-host.sh derives for a non-legacy host).
_ci_host_plists() { # host -> existing plist paths
  local k
  for k in agent reporter macos lima-vm; do
    [ -f "$CI_LAUNCHDAEMONS_DIR/com.doublenode.ci-runner.$1.$k.plist" ] && echo "$CI_LAUNCHDAEMONS_DIR/com.doublenode.ci-runner.$1.$k.plist"
  done
  return 0
}

# Number of com.doublenode.ci-runner* plists that do NOT belong to host $1 (other hosts, legacy names).
_ci_other_plists() { # host
  local f b n=0 k own
  for f in "$CI_LAUNCHDAEMONS_DIR"/com.doublenode.ci-runner*.plist; do
    [ -e "$f" ] || continue
    b="${f##*/}"; own=0
    for k in agent reporter macos lima-vm; do [ "$b" = "com.doublenode.ci-runner.$1.$k.plist" ] && own=1; done
    [ "$own" = 1 ] || n=$((n + 1))
  done
  echo "$n"
}

# Hosts that have a CI daemon plist on disk, one per line (state file NOT consulted).
_ci_hosts_on_disk() {
  local f b rest kind host
  for f in "$CI_LAUNCHDAEMONS_DIR"/com.doublenode.ci-runner.*.plist; do
    [ -e "$f" ] || continue
    b="${f##*/}"; rest="${b#com.doublenode.ci-runner.}"; rest="${rest%.plist}"
    case "$rest" in *.*) ;; *) continue ;; esac     # legacy unsuffixed: com.doublenode.ci-runner.<kind>
    kind="${rest##*.}"; host="${rest%.*}"
    case "$kind" in agent|reporter|macos|lima-vm) ;; *) continue ;; esac
    _valid_host "$host" || continue
    echo "$host"
  done | sort -u
}

# Teardown artefacts a USER can see (root-owned dirs are world-searchable; ci-runner's home is not,
# so the VM and fleet-config.json cannot be probed from here: the teardown deletes the VM BEFORE the
# plists, so absent plists imply a deleted VM). One line per leftover. $1 host, $2 remove_user 0|1.
_ci_leftovers() {
  local host="$1" rm_user="$2" p others f
  while IFS= read -r p; do [ -n "$p" ] && echo "daemon plist: $p"; done <<EOF_PL
$(_ci_host_plists "$host")
EOF_PL
  [ ! -e "$CIH_STATE_DIR/${host}.pause.json" ] || echo "pause marker: $CIH_STATE_DIR/${host}.pause.json"
  [ ! -e "$CIH_STATE_DIR/${host}.provision-manifest" ] || echo "provision manifest: $CIH_STATE_DIR/${host}.provision-manifest"
  others="$(_ci_other_plists "$host")"
  if [ "$others" = 0 ]; then
    for f in "$CI_AGENT_CFG_DIR/agent.key" "$CI_AGENT_CFG_DIR/agent.json" \
             "$CI_LIBEXEC_DIR/ci-pool-agent.py" "$CI_LIBEXEC_DIR/ci-runner-reporter.sh" \
             "$CI_LIBEXEC_DIR/ci-runner-jit-macos.sh" "$CI_LIBEXEC_DIR/ci-runner-job-started.sh"; do
      [ ! -e "$f" ] || echo "installed file: $f"
    done
  fi
  if [ "$rm_user" = 1 ] && id -u "$CI_RUNNER_USER" >/dev/null 2>&1; then
    echo "user: ${CI_RUNNER_USER} still exists (--remove-user)"
  fi
  return 0
}

# A state file we can act on: schema 1, known state, valid host.
_ci_state_healthy() {
  [ -f "$CI_STATE_FILE" ] || return 1
  [ "$(_state_get schema)" = 1 ] || return 1
  case "$(_state_get state)" in enabled-pending|enabled|disable-pending) ;; *) return 1 ;; esac
  _valid_host "$(_state_get host)"
}

# Record state=disable-pending (+ remove_user, disable_requested_at). A healthy file keeps every key
# it has (unknown keys included); a missing/corrupt one is replaced by a minimal fresh file.
_ci_write_disable_state() { # host remove_user
  local host="$1" rmu="$2" ts tmp old_umask created
  ts="$(_now)"
  old_umask="$(umask)"; umask 077
  tmp="$(mktemp "${CI_STATE_FILE}.XXXXXX")" || { umask "$old_umask"; _err "cannot create a temp file next to $CI_STATE_FILE"; return $RC_ENV; }
  if _ci_state_healthy; then
    awk -v ts="$ts" -v rmu="$rmu" '
      /^state=/                { print "state=disable-pending"; next }
      /^updated_at=/           { print "updated_at=" ts; next }
      /^remove_user=/          { next }
      /^disable_requested_at=/ { next }
      { print }
      END { print "remove_user=" rmu; print "disable_requested_at=" ts }' "$CI_STATE_FILE" >"$tmp"
  else
    created="$(_state_get created_at)"
    case "$created" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;; *) created="$ts" ;; esac
    {
      echo "# aiteamforge CI state v1 - rebuilt by 'aiteamforge ci disable --force'. No secrets. Contract: XACA-1443-002."
      echo "schema=1"
      echo "state=disable-pending"
      echo "host=$host"
      echo "bundle_dir=$CI_BUNDLE_DIR"
      echo "created_at=$created"
      echo "updated_at=$ts"
      echo "remove_user=$rmu"
      echo "disable_requested_at=$ts"
    } >"$tmp"
  fi
  chmod 600 "$tmp" && mv -f "$tmp" "$CI_STATE_FILE" \
    || { umask "$old_umask"; rm -f "$tmp"; _err "cannot write $CI_STATE_FILE"; return $RC_ENV; }
  umask "$old_umask"
  return 0
}

cmd_disable() {
  local a
  for a in "$@"; do
    case "$a" in -h|--help) disable_usage; return $RC_OK ;; esac
  done

  # ---- 1. GUARD FIRST, same as enable (the printed sudo line would act on THIS machine)
  _run_guard || return $?

  local rm_user=0 kill_run=0 vm_gone=0 dry=0 confirm=0 force=0 host_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --remove-user)  rm_user=1; shift ;;
      --kill-running) kill_run=1; shift ;;
      --vm-gone)      vm_gone=1; shift ;;
      --dry-run)      dry=1; shift ;;
      --confirm)      confirm=1; shift ;;
      --force)        force=1; shift ;;
      --host)         [ $# -ge 2 ] || { _err "--host needs a name"; return $RC_USAGE; }; host_arg="$2"; shift 2 ;;
      *) _err "unknown option: $1"; disable_usage >&2; return $RC_USAGE ;;
    esac
  done
  if [ -n "$host_arg" ]; then
    [ "$force" = 1 ] || { _err "--host is only for --force recovery (the host is otherwise read from the state file)"; return $RC_USAGE; }
    _valid_host "$host_arg" || { _err "--host must match [a-z0-9]([a-z0-9-]*[a-z0-9])?, got '${host_arg}'"; return $RC_USAGE; }
  fi
  if [ "$confirm" = 1 ] && [ "$kill_run" = 1 ]; then _err "--kill-running belongs to the teardown, not to --confirm"; return $RC_USAGE; fi
  if [ "$confirm" = 1 ] && [ "$vm_gone" = 1 ]; then _err "--vm-gone belongs to the teardown, not to --confirm"; return $RC_USAGE; fi

  # ---- 2. which host / which state
  local healthy=0 st="" host="" derived n
  _ci_state_healthy && healthy=1
  if [ "$healthy" = 1 ]; then st="$(_state_get state)"; host="$(_state_get host)"; fi

  if [ "$healthy" = 0 ] && [ -f "$CI_STATE_FILE" ] && [ "$force" = 0 ]; then
    _err "state file $CI_STATE_FILE is unreadable or has an unknown schema/state/host. Not guessing."
    _err "Re-run with --force to derive the teardown from the daemon plists on disk."
    return $RC_STATE
  fi
  if [ "$healthy" = 0 ] && [ ! -f "$CI_STATE_FILE" ] && [ "$force" = 0 ]; then
    derived="$(_ci_hosts_on_disk | tr '\n' ' ')"
    echo "CI is dormant on this machine (no state file)."
    [ -z "$derived" ] || echo "NOTE: CI daemon plists exist on disk for: ${derived}. To tear them down anyway: aiteamforge ci disable --force"
    return $RC_OK
  fi

  # --force: ignore an unhealthy file; the host comes from --host, a healthy file, or the disk.
  if [ -n "$host_arg" ]; then
    if [ "$healthy" = 1 ] && [ "$host_arg" != "$host" ]; then
      _err "--host ${host_arg} disagrees with the state file (host=${host}); refusing."
      return $RC_USAGE
    fi
    host="$host_arg"
  elif [ -z "$host" ]; then
    derived="$(_ci_hosts_on_disk)"
    n=0; [ -z "$derived" ] || n="$(printf '%s\n' "$derived" | wc -l | tr -d ' ')"
    if [ "$n" = 0 ]; then
      if [ -f "$CI_STATE_FILE" ] && [ "$dry" = 0 ]; then
        rm -f "$CI_STATE_FILE" && echo "No CI daemon plists on disk; removed the unusable state file. CI is dormant."
      else
        echo "No CI daemon plists on disk and no usable state. CI is dormant."
      fi
      return $RC_OK
    elif [ "$n" -gt 1 ]; then
      _err "several hosts have CI daemon plists here: $(printf '%s' "$derived" | tr '\n' ' '). Pick one with --host <name>."
      return $RC_USAGE
    fi
    host="$derived"
  fi
  # remove_user: this call's flag OR what an earlier `ci disable` recorded.
  [ "$healthy" = 0 ] || [ "$(_state_get remove_user)" != 1 ] || rm_user=1

  if [ "$confirm" = 1 ]; then
    cmd_disable_confirm "$host" "$rm_user" "$healthy" "$st" "$force" "$dry"
    return $?
  fi

  # ---- 3. nothing provisioned: no sudo needed
  local lo; lo="$(_ci_leftovers "$host" "$rm_user")"
  if [ -z "$lo" ] && ! id -u "$CI_RUNNER_USER" >/dev/null 2>&1; then
    if [ "$dry" = 1 ]; then
      echo "[dry-run] nothing is provisioned for host ${host} (no plists, no ${CI_RUNNER_USER} user): would just remove the state file. Nothing was written."
    else
      rm -f "$CI_STATE_FILE"
      echo "Nothing was provisioned for host ${host} (no plists, no ${CI_RUNNER_USER} user). State file removed: CI is dormant."
    fi
    return $RC_OK
  fi

  # ---- 4. the teardown script
  local td_sh="$CI_BUNDLE_DIR/teardown-host.sh" p
  if [ ! -r "$td_sh" ]; then
    _err "teardown script missing ($td_sh). Run: aiteamforge upgrade"
    return $RC_ENV
  fi
  local targs=(--host "$host")
  [ "$rm_user" = 0 ] || targs=("${targs[@]}" --remove-user)
  [ "$kill_run" = 0 ] || targs=("${targs[@]}" --kill-running)
  [ "$vm_gone" = 0 ] || targs=("${targs[@]}" --vm-gone)
  local sudo_line="sudo /bin/bash $(printf '%q' "$td_sh")"
  local dry_line="bash $(printf '%q' "$td_sh")"
  for p in "${targs[@]}"; do
    sudo_line="$sudo_line $(printf '%q' "$p")"; dry_line="$dry_line $(printf '%q' "$p")"
  done
  dry_line="$dry_line --dry-run"

  if [ "$dry" = 1 ]; then
    echo "[dry-run] would write $CI_STATE_FILE (state=disable-pending, host=${host}, remove_user=${rm_user}). Nothing was written."
  else
    _ci_write_disable_state "$host" "$rm_user" || return $?
    echo "State recorded: $CI_STATE_FILE (state=disable-pending, mode 600)"
  fi

  echo
  echo "Host ${host}: this removes the agent/reporter/VM daemons, the Lima VM ci-linux-${host}, the agent key and"
  echo "config, the telemetry key file, the pause marker, the installed copies and the plists."
  if [ "$rm_user" = 1 ]; then echo "  ALSO: the ${CI_RUNNER_USER} user, its group and its home (--remove-user)."
  else echo "  KEPT: the ${CI_RUNNER_USER} user and its home (add --remove-user to delete them)."; fi
  echo "  No GitHub runner registration persists (JIT runners are single-use; ci enable used --no-register)."
  echo "  Server side (not done by it): revoke the agent + telemetry keys, drop the machine record."
  echo
  echo "Before you run it, inspect what will run as root (sha256):"
  echo "  $(_sha256 "$td_sh")  $td_sh"
  echo
  echo "Preview, no root, changes nothing:"
  echo "$dry_line"
  echo
  echo "Then run this ONE command yourself:"
  echo "$sudo_line"
  echo
  echo "Afterwards run: aiteamforge ci disable --confirm"
  return $RC_OK
}

# `ci disable --confirm`: user-level, read-only probes; removes the state file when nothing is left.
cmd_disable_confirm() { # host rm_user healthy st force dry
  local host="$1" rm_user="$2" healthy="$3" st="$4" force="$5" dry="$6" lo
  if [ "$healthy" = 1 ] && [ "$st" != disable-pending ] && [ "$force" = 0 ]; then
    _err "CI is '${st}', not disable-pending. Run: aiteamforge ci disable   (then the sudo command, then --confirm)"
    return $RC_STATE
  fi
  lo="$(_ci_leftovers "$host" "$rm_user")"
  if [ -n "$lo" ]; then
    _err "teardown is not finished for host ${host}; refusing to go dormant (state kept):"
    printf '%s\n' "$lo" | sed 's/^/  - /' >&2
    _err "Run the sudo command 'ci disable' printed (it is idempotent), then --confirm again."
    return $RC_LEFTOVERS
  fi
  if [ "$dry" = 1 ]; then
    echo "[dry-run] teardown verified for host ${host}: would remove $CI_STATE_FILE. Nothing was removed."
    return $RC_OK
  fi
  rm -f "$CI_STATE_FILE" || { _err "cannot remove $CI_STATE_FILE"; return $RC_ENV; }
  echo "CI disabled on ${host}: teardown verified, state file removed. CI is dormant."
  if [ "$rm_user" = 0 ] && id -u "$CI_RUNNER_USER" >/dev/null 2>&1; then
    echo "The ${CI_RUNNER_USER} user was kept (a later 'ci enable' re-uses it)."
  fi
  return $RC_OK
}

# ---------------------------------------------------------------- refresh (XACA-1443-013/-015)

refresh_usage() {
  cat <<'EOF'
Usage: aiteamforge ci refresh [--force] [--allow-busy] [--dry-run]
       aiteamforge ci refresh --confirm [--dry-run]
       aiteamforge ci refresh --help

For a host that is already ENABLED. `brew upgrade` replaces the keg but not what provisioning put on this
machine: the root-owned copies in /usr/local/libexec, the guest scripts inside the VM, and (when
provision-host.sh itself changed) the plists, VM config and user setup. `ci refresh` compares the host with
the keg (read-only, no sudo) and, when it is behind, records nothing and prints ONE sudo command that
re-runs the bundle's provisioning with the SAME flags `ci enable` used (read from the state file). The run
is idempotent: it keeps the ci-runner user, the VM and the keys, replaces changed copies and plists, and
pushes the current guest scripts. Then `ci refresh --confirm` re-reads the host's provision manifest and
records the new provision_version in the state file.

  --force        print the sudo command even when the host reads as in sync (re-apply anyway)
  --allow-busy   do not pass --refuse-if-busy: by default the root script exits 3, changing nothing, while a
                 pool job is starting/busy/cleaning (or its slot file cannot be read)
  --dry-run      do every check and print the plan and the commands; with --confirm, show what would be
                 recorded. Writes nothing (refresh itself writes nothing before --confirm)
  --confirm      AFTER you ran the sudo command: verify the host now matches the keg and record
                 provision_version. rc 20 (state untouched) while it does not, or cannot be verified

Refuses (rc 17) from dormant, enabled-pending and disable-pending, and on a corrupt state file. Refuses on
the dev-team source machine / a git work-tree exactly like `ci enable` (rc 10/11).

What it can and cannot see without sudo: the host's provision manifest and the root-owned copies in
/usr/local/libexec (world-readable), and the keg. NOT the VM or ci-runner's 700 home: the guest scripts are
judged from the manifest's record of what was pushed, so a guest script edited by hand inside the VM is not
detected. Anything it cannot read is reported as unknown, never as in sync.

Not done by refresh: the VM's size (a VM that exists keeps its CPU/RAM; change it with `ci disable` then
`ci enable`), key rotation (provision-host.sh keeps the installed keys; rotate with --agent-key-file by hand
or re-enable), the actions/runner binaries (XACA-1443-014).

Exit codes: 0 ok / in sync / dry-run | 1 environment (bundle, library or state unreadable)
  2 usage | 10 dev-team source machine | 11 git work-tree install
  17 state conflict (dormant, enabled-pending, disable-pending, corrupt state)
  20 --confirm: the host does not match the keg yet, or could not be verified
The root script's own codes (run it by hand): 0 ok, 1 a step failed, 2 usage, 3 refused (a pool job is running).
EOF
}

# True when every reason line is a `record:` line (the host itself matches; only the state file is stale).
_ci_skew_only_record() {
  [ -n "$CI_SKEW_REASONS" ] || return 1
  [ -z "$(printf '%s\n' "$CI_SKEW_REASONS" | grep -v '^record:')" ]
}

_ci_print_skew() { # host
  echo "Provision status of host ${1}: ${CI_SKEW_STATE}"
  [ -z "$CI_SKEW_REASONS" ] || printf '%s\n' "$CI_SKEW_REASONS" | sed 's/^/  - /'
  [ -z "$CI_SKEW_UNSEEN" ] || printf '%s\n' "$CI_SKEW_UNSEEN" | sed 's/^/  - (not seen) /'
}

cmd_refresh() {
  local a
  for a in "$@"; do
    case "$a" in -h|--help) refresh_usage; return $RC_OK ;; esac
  done

  # ---- 1. GUARD FIRST: the printed sudo line would act on THIS machine
  _run_guard || return $?

  local dry=0 confirm=0 force=0 busy_ok=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)    dry=1; shift ;;
      --confirm)    confirm=1; shift ;;
      --force)      force=1; shift ;;
      --allow-busy) busy_ok=1; shift ;;
      *) _err "unknown option: $1"; refresh_usage >&2; return $RC_USAGE ;;
    esac
  done
  if [ "$confirm" = 1 ] && { [ "$force" = 1 ] || [ "$busy_ok" = 1 ]; }; then
    _err "--confirm takes only --dry-run"; return $RC_USAGE
  fi
  if [ ! -f "$AITEAMFORGE_DIR/.aiteamforge-config" ]; then
    _err "AITeamForge is not configured ($AITEAMFORGE_DIR/.aiteamforge-config missing). Run: aiteamforge setup"
    return $RC_ENV
  fi

  # ---- 2. only an ENABLED host with a healthy state file
  if [ ! -f "$CI_STATE_FILE" ]; then
    _err "CI is dormant on this machine (no state file); nothing to refresh. To turn it on: aiteamforge ci enable ..."
    return $RC_STATE
  fi
  if ! _ci_state_healthy; then
    _err "state file $CI_STATE_FILE is unreadable or has an unknown schema/state/host. Not guessing."
    return $RC_STATE
  fi
  local st host vcpu vmem slots wmac surl
  st="$(_state_get state)"; host="$(_state_get host)"
  case "$st" in
    enabled) ;;
    enabled-pending) _err "CI is 'enabled-pending': finish the enable first (run the sudo command it printed, then: aiteamforge ci enable --confirm)."; return $RC_STATE ;;
    disable-pending) _err "CI is 'disable-pending': a teardown is in progress. Finish it (aiteamforge ci disable --confirm) before anything else."; return $RC_STATE ;;
    *) _err "CI state is '${st}', not enabled."; return $RC_STATE ;;
  esac
  # The flags `ci enable` recorded. A value that no longer validates means the file was edited or damaged:
  # refuse rather than print a root command built from it.
  vcpu="$(_state_get vm_cpus)"; vmem="$(_state_get vm_memory_gib)"; slots="$(_state_get linux_slots)"
  wmac="$(_state_get with_macos)"; surl="$(_state_get server_url)"
  local bad=0
  _is_uint "$vcpu" && [ "$vcpu" -ge 1 ] || { _err "state file: vm_cpus='${vcpu}' is not a positive integer"; bad=1; }
  _is_uint "$vmem" && [ "$vmem" -ge 1 ] || { _err "state file: vm_memory_gib='${vmem}' is not a positive integer"; bad=1; }
  _is_uint "$slots" && [ "$slots" -ge 1 ] || { _err "state file: linux_slots='${slots}' is not a positive integer"; bad=1; }
  case "$wmac" in 0|1) ;; *) _err "state file: with_macos='${wmac}' is not 0 or 1"; bad=1 ;; esac
  if [ -n "$surl" ] && ! _valid_url "$surl"; then _err "state file: server_url is not an acceptable https URL"; bad=1; fi
  [ "$bad" = 0 ] || { _err "Not guessing the flags. Fix the state file, or: aiteamforge ci disable && aiteamforge ci enable ..."; return $RC_STATE; }

  # ---- 3. skew (read-only)
  _load_pv_lib || return $?
  local src=0
  ci_provision_skew "$host" "$CI_BUNDLE_DIR" "$(_state_get provision_version)" || src=$?

  if [ "$confirm" = 1 ]; then
    cmd_refresh_confirm "$host" "$src" "$dry"
    return $?
  fi

  _ci_print_skew "$host"
  if [ "$src" = 0 ] && [ "$force" = 0 ]; then
    echo "Host ${host} matches this release (provision version ${CI_SKEW_RECORDED_VERSION}). Nothing to do. (--force re-applies anyway.)"
    return $RC_OK
  fi
  if [ "$src" = 1 ] && _ci_skew_only_record && [ "$force" = 0 ]; then
    echo "The host itself matches this release; only the state file's provision_version is stale. Run: aiteamforge ci refresh --confirm"
    return $RC_OK
  fi

  # ---- 4. the ONE sudo command: the enable line minus the key files, plus the busy guard
  local create_sh="$CI_BUNDLE_DIR/create-ci-runner-user.sh" prov_sh="$CI_BUNDLE_DIR/provision-host.sh" pv_lib="$CI_BUNDLE_DIR/lib/ci-provision-version.sh"
  if [ ! -r "$create_sh" ] || [ ! -r "$prov_sh" ]; then
    _err "provisioning scripts missing from $CI_BUNDLE_DIR. Run: aiteamforge upgrade"
    return $RC_ENV
  fi
  _ci_payload_check "$wmac" || return $?
  local pargs=(--host "$host" --no-register --vm-cpus "$vcpu" --vm-memory "$vmem" --linux-count "$slots")
  [ "$wmac" = 1 ] || pargs=("${pargs[@]}" --no-macos)
  pargs=("${pargs[@]}" --with-agent)
  [ -z "$surl" ] || pargs=("${pargs[@]}" --server-url "$surl")
  [ "$busy_ok" = 1 ] || pargs=("${pargs[@]}" --refuse-if-busy)
  local sudo_line="sudo /bin/bash -c 'bash \"\$1\" && shift && exec bash \"\$@\"' _ $(printf '%q' "$create_sh") $(printf '%q' "$prov_sh")"
  local dry_line="bash $(printf '%q' "$prov_sh")" p
  for p in "${pargs[@]}"; do
    sudo_line="$sudo_line $(printf '%q' "$p")"; dry_line="$dry_line $(printf '%q' "$p")"
  done
  dry_line="$dry_line --dry-run"

  [ "$dry" = 0 ] || echo "[dry-run] nothing is written by 'ci refresh' (it writes only on --confirm)."
  echo
  echo "Host ${host}: this re-runs the provisioning with the flags 'ci enable' recorded. It is idempotent: the"
  echo "  ci-runner user, the VM and the installed keys are kept; changed root-owned copies, plists and guest"
  echo "  scripts are replaced; a changed daemon plist restarts that daemon."
  if [ "$busy_ok" = 1 ]; then
    echo "  --allow-busy: it will NOT refuse while a pool job is running."
  else
    echo "  It refuses (exit 3, nothing changed) while a pool job is starting/busy/cleaning."
  fi
  echo "  NOT changed: the VM's size, the keys, runner directories that are already extracted."
  echo "  Re-resolved: the cached actions/runner tarball (newest release GitHub publishes, sha256-verified; if GitHub cannot be asked the staged one is kept or the pinned fallback is used, and it says so)."
  echo
  echo "Before you run it, inspect what will run as root (sha256):"
  echo "  $(_sha256 "$create_sh")  $create_sh"
  echo "  $(_sha256 "$prov_sh")  $prov_sh"
  echo "  $(_sha256 "$pv_lib")  $pv_lib   (sourced by provision-host.sh to write the provision manifest)"
  echo "  $(_sha256 "$CI_BUNDLE_DIR/lib/ci-runner-version.sh")  $CI_BUNDLE_DIR/lib/ci-runner-version.sh   (sourced by provision-host.sh: picks and sha256-verifies the actions/runner it stages)"
  echo "  $(_sha256 "$CI_BUNDLE_DIR/runner-pin.conf")  $CI_BUNDLE_DIR/runner-pin.conf   (data: the pinned fallback runner + digests)"
  echo
  echo "Preview, no root, changes nothing:"
  echo "$dry_line"
  echo
  echo "Then run this ONE command yourself:"
  echo "$sudo_line"
  echo
  echo "Afterwards run: aiteamforge ci refresh --confirm"
  return $RC_OK
}

# `ci refresh --confirm`: user-level, read-only probes; records provision_version when the host matches.
cmd_refresh_confirm() { # host skew_rc dry
  local host="$1" src="$2" dry="$3" ts pv
  _ci_print_skew "$host"
  if [ "$src" != 0 ] && ! { [ "$src" = 1 ] && _ci_skew_only_record; }; then
    if [ "$src" = 2 ]; then _err "cannot verify that host ${host} matches this release; refusing to record a version (state kept)."
    else _err "host ${host} does not match this release yet (state kept). Run the sudo command 'ci refresh' printed, then --confirm again."; fi
    return $RC_REFRESH_PENDING
  fi
  pv="$CI_SKEW_RECORDED_VERSION"
  if [ "$dry" = 1 ]; then
    echo "[dry-run] host ${host} matches this release: would record provision_version=${pv}. Nothing was written."
    return $RC_OK
  fi
  ts="$(_now)"
  _ci_state_set provision_version="$pv" updated_at="$ts" provision_refreshed_at="$ts" || return $?
  echo "Host ${host} matches this release; recorded provision_version=${pv} (${ts})."
  return $RC_OK
}

# ---------------------------------------------------------------- status (XACA-1443-004)

status_usage() {
  cat <<'EOF'
Usage: aiteamforge ci status
       aiteamforge ci status --help

Read-only. Reports the CI capability of THIS machine, the same verdict `aiteamforge doctor` shows:

  dormant           CI is off (the shipped default). Nothing is installed, nothing runs.   exit 0
  enabled           provisioned and in sync with this release.                              exit 0
  enabled / paused  works, but see "Provision skew" (an upgrade left it behind, or it could   exit 1
                    not be verified: unknown is never reported as healthy) / the XACA-1440
                    pause marker is present (draining, paused, resuming).
  enable-pending    `ci enable` recorded the host; the sudo line / `ci enable --confirm` is open.   exit 1
  disable-pending   `ci disable` recorded a teardown; the sudo line / `--confirm` is open.          exit 1
  misconfigured     the state file and what is on disk disagree, or a probe could not run   exit 2
                    (corrupt / mis-moded state file, stray CI daemon plists with no state file,
                    enabled without the user or a daemon plist, the CI bundle missing, an
                    unreadable directory). Dormant requires positive evidence; an unreadable
                    path is never read as "nothing there".

Never runs sudo, launchctl, dscl, limactl, curl or gh; never calls GitHub or Fleet Monitor. It cannot
see inside ci-runner's private home (the VM), loaded daemons or plist contents, and says so.
On the dev-team source machine it reports "dormant (dev-team source machine; CI capability disabled by
design)" and exit 0, unless a state file or CI artefact is found there (misconfigured, exit 2).

Exit codes: 0 ok | 1 warn | 2 fail (misconfigured, or the classifier could not run) | 21 bad option.
EOF
}

cmd_status() {
  local a lib="" cand
  for a in "$@"; do
    case "$a" in -h|--help) status_usage; return $RC_OK ;; esac
  done
  if [ $# -gt 0 ]; then
    _err "unknown option for 'ci status': $1"; status_usage >&2; return $RC_STATUS_USAGE
  fi
  # The install dir's bundle copy first; when the bundle is gone, the tap's own copy lets the classifier
  # still run and name the missing bundle. Neither readable = fail closed (misconfigured), never "dormant".
  for cand in "$CI_BUNDLE_DIR/lib/ci-status.sh" "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/share/scripts/ci-runner/lib/ci-status.sh"; do
    if [ -r "$cand" ]; then lib="$cand"; break; fi
  done
  # shellcheck source=/dev/null
  if [ -z "$lib" ] || ! . "$lib"; then
    echo "CI capability: misconfigured   [FAIL]"
    echo "Why:"
    echo "  - the CI classifier (lib/ci-status.sh) is not available in $CI_BUNDLE_DIR; nothing can be verified, so no healthy state is reported"
    echo "Next: aiteamforge upgrade"
    return 2
  fi
  local rc=0 lvl line
  ci_capability_state || rc=$?
  case "$CI_STATUS_LEVEL" in ok) lvl=OK ;; warn) lvl=WARN ;; *) lvl=FAIL ;; esac
  echo "CI capability: ${CI_STATUS_STATE}   [${lvl}]"
  [ -z "$CI_STATUS_HOST" ] || echo "Host: ${CI_STATUS_HOST}"
  if [ -n "$CI_STATUS_REASONS" ]; then
    echo "Why:"
    while IFS= read -r line; do
      [ -z "$line" ] || case "$line" in "  "*) echo "  $line" ;; *) echo "  - $line" ;; esac
    done <<EOF_R
$CI_STATUS_REASONS
EOF_R
  fi
  echo "Provision skew: ${CI_STATUS_SKEW}"
  if [ -n "$CI_STATUS_SKEW_REASONS" ]; then
    while IFS= read -r line; do [ -z "$line" ] || echo "  - $line"; done <<EOF_S
$CI_STATUS_SKEW_REASONS
EOF_S
  fi
  if [ -n "$CI_STATUS_SKEW_UNSEEN" ]; then
    while IFS= read -r line; do [ -z "$line" ] || echo "  - (not seen) $line"; done <<EOF_U
$CI_STATUS_SKEW_UNSEEN
EOF_U
  fi
  [ -z "$CI_STATUS_NEXT" ] || echo "Next: ${CI_STATUS_NEXT}"
  return $rc
}

# ---------------------------------------------------------------- dispatch

case "${1:-}" in
  enable)  shift; cmd_enable "$@"; exit $? ;;
  disable) shift; cmd_disable "$@"; exit $? ;;
  refresh) shift; cmd_refresh "$@"; exit $? ;;
  status)  shift; cmd_status "$@"; exit $? ;;
  -h|--help|help|"") usage; exit 0 ;;
  *) _err "unknown ci subcommand: $1"; usage >&2; exit 2 ;;
esac
