#!/bin/bash
# aiteamforge-ci.sh - `aiteamforge ci ...` (XACA-1443). TAP-NATIVE: edit it here, it has no
# canonical source in dev-team (commit with the trailer `Tap-Only-Edit: intentional`).
#
#   aiteamforge ci enable [flags]    XACA-1443-002 (this file)
#   aiteamforge ci disable           XACA-1443-003 (stub: rc 2)
#   aiteamforge ci status            XACA-1443-004 (stub: rc 2)
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

# Exit codes (also in `ci enable --help`).
RC_OK=0 RC_ENV=1 RC_USAGE=2
RC_HEADROOM=12 RC_NO_FIT=13 RC_NO_LIMA=14 RC_PROBE=16 RC_STATE=17 RC_NOT_PROVISIONED=18
# 10 / 11 are ci_enable_guard's own codes, passed through unchanged.

_err()  { echo "ERROR: $*" >&2; }
_warn() { echo "WARNING: $*" >&2; }
_now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

usage() {
  cat <<'EOF'
Usage: aiteamforge ci <enable|disable|status> [options]

  enable     Check this machine, record the CI configuration, print ONE sudo command
  disable    Tear CI down                        (not yet implemented)
  status     Report dormant|enabled|paused|...   (not yet implemented)

CI is dormant on every install until you run `aiteamforge ci enable`.
For details: aiteamforge ci enable --help
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

_prompt() { # varname label  (terminal only; the answers are ids/paths/URLs, never secrets)
  local ans=""
  printf '%s: ' "$2" >&2
  IFS= read -r ans || ans=""
  eval "$1=\$ans"
}

# ---------------------------------------------------------------- enable

cmd_enable() {
  local a
  for a in "$@"; do
    case "$a" in -h|--help) enable_usage; return $RC_OK ;; esac
  done

  # ---- 1. GUARD FIRST (XACA-1443-005): before parsing, prompting, measuring or writing anything.
  local guard_lib="$CI_BUNDLE_DIR/lib/ci-enable-guard.sh" grc=0
  if [ ! -r "$guard_lib" ]; then
    _err "CI bundle missing ($guard_lib). Run: aiteamforge upgrade"
    return $RC_ENV
  fi
  # shellcheck source=/dev/null
  . "$guard_lib" || { _err "cannot load $guard_lib"; return $RC_ENV; }
  ci_enable_guard || grc=$?
  if [ "$grc" -ne 0 ]; then
    return "$grc"
  fi

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
  local st host plist ts tmp old_umask
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
  old_umask="$(umask)"; umask 077
  tmp="$(mktemp "${CI_STATE_FILE}.XXXXXX")" || { umask "$old_umask"; return $RC_ENV; }
  awk -v ts="$ts" '
    /^state=/      { print "state=enabled"; next }
    /^updated_at=/ { print "updated_at=" ts; next }
    /^enabled_at=/ { print "enabled_at=" ts; next }
    { print }' "$CI_STATE_FILE" >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$CI_STATE_FILE" \
    || { umask "$old_umask"; rm -f "$tmp"; _err "cannot update $CI_STATE_FILE"; return $RC_ENV; }
  umask "$old_umask"
  echo "CI enabled on ${host} (state=enabled, ${ts})."
  return $RC_OK
}

# ---------------------------------------------------------------- dispatch

case "${1:-}" in
  enable)  shift; cmd_enable "$@"; exit $? ;;
  disable) echo "aiteamforge ci disable: not yet implemented (XACA-1443-003)." >&2; exit 2 ;;
  status)  echo "aiteamforge ci status: not yet implemented (XACA-1443-004)." >&2; exit 2 ;;
  -h|--help|help|"") usage; exit 0 ;;
  *) _err "unknown ci subcommand: $1"; usage >&2; exit 2 ;;
esac
