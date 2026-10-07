#!/usr/bin/env bash
# provision-host.sh — Provision the self-hosted GitHub Actions runners on a CI
# host (XACA-1385-003/-004/-005; generalized from provision-m1mini.sh by
# XACA-1436-001 so a second host such as M4Mini can reuse it).
#
# Run ON the host, once, under sudo, AFTER create-ci-runner-user.sh:
#   sudo bash provision-host.sh --host <name> --token-file <path-to-token>
#
# M1Mini keeps its exact historical configuration in the thin wrapper
# provision-m1mini.sh (same runner names, labels, VM, daemons as before).
#
# Host-shaped knobs (everything else is identical per host):
#   --host <name>        REQUIRED. Runner names <host>-linux-N / <host>-macos-1,
#                        the runner label <host>, reporter machine name, and the
#                        default VM + daemon names (so hosts never collide).
#   --linux-count <N>    Linux runners in the VM (default 2).
#   --vm-cpus <N> / --vm-memory <GiB>   VM size (default 4 / 6; disk fixed 60GiB).
#   --no-macos           Linux side only: no macOS runner, no macOS daemon.
#   --label <extra>      Extra runner label, repeatable (default: none).
#   --legacy-names       Keep the pre-XACA-1436 unsuffixed VM/daemon names
#                        (ci-linux, com.doublenode.ci-runner.*). Only for the
#                        M1Mini wrapper, whose live artifacts carry those names.
#   --no-register        Register NO GitHub runner (XACA-1442): VM + guest
#                        baseline + runner tarball cache + reporter daemon only;
#                        no token needed, no persistent runner, no macOS runner
#                        daemon. Under the JIT model runners are minted per job.
#                        Mutually exclusive with --token-file. Consumed by
#                        XACA-1443 (`aiteamforge ci enable`).
#   --with-agent         Also install the Fleet CI Pool agent (see "AGENT").
#                        Opt-in; without it nothing agent-related happens.
#   --agent-key-file <p> The per-host dispatch key (fcp_...); needs --with-agent.
#   --server-url <url>   Fleet Monitor base URL for the agent; needs --with-agent.
#   --telemetry-key-file <p>  The per-host CI telemetry key (fct_ + 43 chars; XACA-1422)
#                        the reporter pushes with. Refused unless it has that exact shape,
#                        so the fleet-wide token can never be placed. Without it a
#                        re-provision keeps an existing fct_ key and otherwise leaves the
#                        reporter with NO key (WARN). Mint one with
#                        POST /api/ci-pool/machines/<host>/telemetry-key (runbook 11).
#
# Other modes:
#   --dry-run   print what WOULD happen (with current state where it can be
#               read); changes nothing, needs no root.
#   --status    read-only health report; exit 0 = everything up, 1 = something
#               down, 2 = macOS side up but Linux side NOT checked (no sudo).
#
# Idempotent: every step checks state first. A re-run converges, never
# re-registers an existing runner (skips when `.runner` exists), and never
# needs a token unless a runner is actually missing.
#
# ── WHAT IT BUILDS ─────────────────────────────────────────────────────────
#   Lima vz VM `ci-linux-<host>` (default 4 CPU / 6 GiB / 60 GiB; `ci-linux`
#   under --legacy-names), owned by `ci-runner`
#     * NO host mounts (--mount-none, verified in the guest). A Lima default
#       mount would expose /Users/ci-runner — where the macOS runner's
#       credentials live — to every job that runs in the guest.
#     * no containerd/nerdctl (the workflows use no services:/container:)
#     * guest user `runner` + passwordless sudo (workflows `sudo apt-get`;
#       the VM, not sudo, is the isolation boundary)
#     * --linux-count runners: /opt/actions-runner-{1..N}, systemd services
#   LaunchDaemon com.doublenode.ci-runner.<host>.lima-vm   starts the VM at boot
#   macOS runner  ~ci-runner/actions-runner-macos          (unless --no-macos)
#   LaunchDaemon com.doublenode.ci-runner.<host>.macos     keeps it running
#   LaunchDaemon com.doublenode.ci-runner.<host>.reporter  telemetry push every
#                60 s (XACA-1387-004; see "REPORTER" below)
#   (.<host> is omitted from the daemon labels under --legacy-names.)
#
# Daemons (System domain, UserName=ci-runner) rather than LaunchAgents: an
# agent needs a GUI login session; a daemon runs at boot with nobody logged
# in. Proven in the XACA-1385-002 spike (vz VM boots under a daemon).
#
# ── REPORTER (XACA-1387-004) ───────────────────────────────────────────────
# fleet-monitor/client/ci-runner-reporter.sh is copied to ${REPORTER_DEST}
# (root-owned) and run by a System LaunchDaemon as ci-runner every 60 s, the
# same domain/user as the runners, because only ci-runner can see the Lima VM.
# Server URL + telemetry key: the reporter reads
# $HOME/.aiteamforge/fleet-config.json (centralServer.apiEndpoint/authToken).
# This script places a MINIMAL file at ~ci-runner/.aiteamforge/fleet-config.json,
# mode 600, and the FLEET-WIDE token is never copied into it (XACA-1422):
#   * apiEndpoint  copied from the invoking sudo user's fleet-config (or
#                  --fleet-config <path>), else kept from the existing file.
#   * authToken    the per-host fct_ key from --telemetry-key-file; without the
#                  flag, the existing authToken is kept ONLY if it already is an
#                  fct_ key. Anything else is REMOVED (WARN), so every run leaves
#                  no fleet token on the host. The source file's authToken is
#                  never read. A host with no key cannot report until re-run
#                  with --telemetry-key-file.
# The key is never in the plist or any argv (python reads the file). Missing
# source config = WARN, not abort: telemetry must not block provisioning.
#
# ── TOKEN HANDLING ─────────────────────────────────────────────────────────
# The one registration token (1 h, single purpose) registers every
# runner. It is read from --token-file and travels only on stdin (host
# redirect -> sudo -> limactl -> ssh -> guest) and into config.sh through
# the ACTIONS_RUNNER_INPUT_TOKEN environment variable, so it is never in any
# argv (`ps`), never written to disk by this script, never logged. The host
# token file is deleted on exit, success OR failure (trap).
#
# ── AGENT (XACA-1442) ──────────────────────────────────────────────────────
# Opt-in (--with-agent). Dormant otherwise: without the flag the behaviour and
# the --dry-run output are byte-identical to before the agent existed.
# fleet-monitor/client/ci-pool-agent.py is installed to ${AGENT_DEST} and run by
# a System LaunchDaemon (com.doublenode.ci-runner.<host>.agent) WITHOUT UserName,
# i.e. as ROOT: every macOS job runs as ci-runner, so an agent running as
# ci-runner would let a job read the dispatch key (plan D2).
#   * key:    --agent-key-file is read through a stdin redirect into
#             `install -m 600 -o root -g wheel /dev/stdin ${AGENT_KEY}`, so it is
#             never in any argv. Anything not starting `fcp_` is refused (rc 2)
#             BEFORE anything is written, so the fleet-wide token cannot be
#             placed by mistake. The source file is deleted on exit (trap), like
#             --token-file; a REFUSED file is left alone. Never in the plist.
#   * config: ${AGENT_CFG} {serverUrl,machine,vmName,linuxSlots,macSlots},
#             root:wheel 0644, no secrets. The key is re-read each poll, so
#             rotation = re-run with a new --agent-key-file, no restart.
#   * stages: stage_guest_jit (guest ci-runner-jit.sh + job-started hook),
#             stage_mac_jit (macOS slot script + hook), stage_agent (script,
#             config, key, plist, daemon). XACA-1443 reuses these.
#
# Bash 3.2 compatible (macOS /bin/bash): no associative arrays, no ${x,,}.

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────
# Root-owned locations. Each can be redirected with the SAME env names teardown-host.sh uses (XACA-1443-015),
# so the idempotency / manifest tests can run this script for real in a sandbox. A sudo'd script does not
# inherit the caller's environment (env_reset), so these are not an injection route; unset = the real paths.
CI_USER="${CI_RUNNER_USER:-ci-runner}"
CI_GROUP="ci-runner"
CI_HOME="${CI_RUNNER_HOME:-/Users/${CI_USER}}"
CI_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
LIMACTL="${CI_LIMACTL_PATH:-/opt/homebrew/bin/limactl}"
LD_DIR="${CI_LAUNCHDAEMONS_DIR:-/Library/LaunchDaemons}"
LIBEXEC_DIR="${CI_LIBEXEC_DIR:-/usr/local/libexec}"
MANIFEST_DIR="${CIH_STATE_DIR:-/usr/local/etc/ci-runner}"   # XACA-1440 pause markers live here too

# Host-shaped values: set from flags, names derived in derive_names() after
# parsing. Defaults reproduce the M1Mini shape.
HOST=""
LEGACY_NAMES=0
NO_MACOS=0
EXTRA_LABELS=""        # comma-joined --label values
VM_NAME=""             # derived unless --vm-name
VM_CPUS=4
VM_MEMORY_GIB=6
VM_MEMORY=""           # derived: <GiB>GiB
VM_DISK="60GiB"

REPO_URL="https://github.com/DoubleNode/dev-team"
RUNNER_LABELS=""         # derived: <host>[,extra]; config.sh itself adds self-hosted, <OS>, <ARCH>
# XACA-1443-014: the actions/runner version is resolved by lib/ci-runner-version.sh (GitHub latest + its published
# sha256, else the runner already staged, else the PINNED fallback in runner-pin.conf; never an unverified download).
# The old hard-coded RUNNER_VERSION_FALLBACK is gone: the pin is data that ships with each release.
RUNNER_SHA_LINUX=""; RUNNER_SHA_OSX=""; RUNNER_SOURCE=""; RUNNER_CHECKED_AT=""

LINUX_RUNNER_COUNT=2
MAC_RUNNER_NAME=""       # derived: <host>-macos-1
MAC_RUNNER_DIR="${CI_HOME}/actions-runner-macos"

LOG_DIR="${CI_HOME}/Library/Logs/ci-runner"
LABEL_VM=""              # derived (see derive_names)
LABEL_MAC=""
PLIST_VM=""
PLIST_MAC=""

GUEST_SCRIPT="/usr/local/sbin/ci-runner-install.sh"

# Reporter (XACA-1387-004)
LABEL_REPORTER=""        # derived
PLIST_REPORTER=""
REPORTER_DEST="${LIBEXEC_DIR}/ci-runner-reporter.sh"
REPORTER_MACHINE=""      # derived: <host>
REPORTER_INTERVAL=60
REPORTER_CFG_DIR="${CI_HOME}/.aiteamforge"
REPORTER_CFG="${REPORTER_CFG_DIR}/fleet-config.json"
# XACA-1443-001: client payload resolves from the dev-team tree (../../fleet-monitor/client)
# OR, in the shipped tap layout ($AITEAMFORGE_DIR/scripts/ci-runner/), from the sibling
# client/ dir that the tap bundles beside this script. First hit wins; dev tree is first so
# canonical-tree behaviour (and its tests) is unchanged.
_PH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -d "${_PH_DIR}/../../fleet-monitor/client" ]; then
  _PH_CLIENT="${_PH_DIR}/../../fleet-monitor/client"
else
  _PH_CLIENT="${_PH_DIR}/client"
fi
REPORTER_SRC="${_PH_CLIENT}/ci-runner-reporter.sh"
FLEET_CONFIG_SRC="${FLEET_CONFIG_SRC:-}"   # --fleet-config / env; default resolved from $SUDO_USER

# Fleet CI Pool agent (XACA-1442). Only used under --with-agent.
WITH_AGENT=0
NO_REGISTER=0
REFUSE_IF_BUSY=0         # XACA-1443-015: `ci refresh` re-provisions an ENABLED host; refuse (rc 3) while a pool job runs
AGENT_KEY_FILE=""
TELEMETRY_KEY_FILE=""    # XACA-1422: per-host fct_ key for the reporter
SERVER_URL=""
LABEL_AGENT=""           # derived
PLIST_AGENT=""
AGENT_DEST="${LIBEXEC_DIR}/ci-pool-agent.py"
AGENT_CFG_DIR="${CI_AGENT_CFG_DIR:-/usr/local/etc/ci-pool-agent}"
AGENT_CFG="${AGENT_CFG_DIR}/agent.json"
AGENT_KEY="${AGENT_CFG_DIR}/agent.key"
AGENT_STATE_DIR="${CI_AGENT_STATE_DIR:-/usr/local/var/ci-pool-agent}"
AGENT_LOG_DIR="${CI_AGENT_LOG_DIR:-/Library/Logs/ci-pool-agent}"
AGENT_SRC="${_PH_CLIENT}/ci-pool-agent.py"
GUEST_JIT_SRC="${_PH_CLIENT}/ci-runner-jit-guest.sh"
MAC_JIT_SRC="${_PH_CLIENT}/ci-runner-jit-macos.sh"
JOB_STARTED_SRC="${_PH_CLIENT}/ci-runner-job-started.sh"
GUEST_JIT_DEST="/usr/local/sbin/ci-runner-jit.sh"
GUEST_JOB_STARTED_DEST="/usr/local/sbin/ci-runner-job-started.sh"
MAC_JIT_DEST="${LIBEXEC_DIR}/ci-runner-jit-macos.sh"
MAC_JOB_STARTED_DEST="${LIBEXEC_DIR}/ci-runner-job-started.sh"

# ── Args ──────────────────────────────────────────────────────────────────
MODE="provision"      # provision | dry-run | status | baseline-only
TOKEN_FILE=""
VM_NAME_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage:
  sudo bash provision-host.sh --host <name> --token-file <path>   provision / register missing runners
  sudo bash provision-host.sh --host <name>                       converge only (all runners registered)
  ... [--fleet-config <path>]   fleet-config.json the reporter's apiEndpoint is copied from
                                (default: ~$SUDO_USER/.aiteamforge/fleet-config.json);
                                its authToken (the fleet token) is NEVER copied
  ... [--telemetry-key-file <p>] per-host telemetry key file (one line: fct_ + 43 chars of
                                [A-Za-z0-9_-]); becomes the reporter's authToken, then the
                                file is deleted. Without it an existing fct_ key is kept and
                                anything else is removed (the reporter then cannot report)
       bash provision-host.sh --host <name> --dry-run [--token-file <path>]
       bash provision-host.sh --host <name> --status              (sudo for full detail)

Host shape (all optional except --host):
  --host <name>        host name: runner names <name>-linux-N / <name>-macos-1, label <name>
  --linux-count <N>    Linux runners in the VM (default 2)
  --vm-cpus <N>        VM CPUs (default 4)
  --vm-memory <GiB>    VM memory in GiB (default 6)
  --vm-name <name>     override the derived VM name (ci-linux-<host>)
  --no-macos           skip the macOS runner (and its daemon) entirely
  --label <extra>      extra runner label, repeatable
  --legacy-names       unsuffixed VM/daemon names (M1Mini wrapper only)
  --no-register        register no GitHub runner (VM + baseline + cache + reporter only);
                       no token needed; not combinable with --token-file
  --refuse-if-busy     exit 3, changing nothing, while the agent's slots.json shows a pool job
                       starting/busy/cleaning (or cannot be read). `aiteamforge ci refresh` passes it.

Fleet CI Pool agent (XACA-1442, opt-in; nothing is installed without --with-agent):
  --with-agent         install the agent daemon (runs as root) + JIT scripts
  --agent-key-file <p> per-host dispatch key file (must start fcp_); needs --with-agent
  --server-url <url>   Fleet Monitor base URL (https://...); needs --with-agent
                       (default: origin of the invoking user's centralServer.apiEndpoint)

Development aid (runs as the CURRENT user, no daemons, no registration):
       bash provision-host.sh --host <name> --baseline-only --vm-name <vm>
EOF
}

# Positive-integer flag value or a usage error.
need_uint() { # flag value
  case "$2" in ''|*[!0-9]*) echo "provision-host.sh: $1 needs a positive integer, got '$2'" >&2; usage >&2; exit 2 ;; esac
  [ "$2" -ge 1 ] || { echo "provision-host.sh: $1 must be >= 1" >&2; usage >&2; exit 2; }
}

# Name-shaped flag value (VM name, runner label): letters, digits, '.', '_', '-',
# starting alphanumeric. Rejects empty, spaces, commas (labels are comma-joined,
# so "a,b" would silently register two labels) and path separators.
need_name() { # flag value
  case "$2" in
    ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) echo "provision-host.sh: $1 must match [A-Za-z0-9][A-Za-z0-9._-]*, got '$2'" >&2; usage >&2; exit 2 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --token-file) [ $# -ge 2 ] || { usage >&2; exit 2; }; TOKEN_FILE="$2"; shift 2 ;;
    --fleet-config) [ $# -ge 2 ] || { usage >&2; exit 2; }; FLEET_CONFIG_SRC="$2"; shift 2 ;;
    --dry-run) MODE="dry-run"; shift ;;
    --status) MODE="status"; shift ;;
    --baseline-only) MODE="baseline-only"; shift ;;
    --vm-name) [ $# -ge 2 ] || { usage >&2; exit 2; }; need_name "$1" "$2"; VM_NAME_OVERRIDE="$2"; shift 2 ;;
    --host) [ $# -ge 2 ] || { usage >&2; exit 2; }; HOST="$2"; shift 2 ;;
    --linux-count) [ $# -ge 2 ] || { usage >&2; exit 2; }; need_uint "$1" "$2"; LINUX_RUNNER_COUNT="$2"; shift 2 ;;
    --vm-cpus) [ $# -ge 2 ] || { usage >&2; exit 2; }; need_uint "$1" "$2"; VM_CPUS="$2"; shift 2 ;;
    --vm-memory) [ $# -ge 2 ] || { usage >&2; exit 2; }; need_uint "$1" "$2"; VM_MEMORY_GIB="$2"; shift 2 ;;
    --label) [ $# -ge 2 ] || { usage >&2; exit 2; }; need_name "$1" "$2"; EXTRA_LABELS="${EXTRA_LABELS:+${EXTRA_LABELS},}$2"; shift 2 ;;
    --no-macos) NO_MACOS=1; shift ;;
    --legacy-names) LEGACY_NAMES=1; shift ;;
    --no-register) NO_REGISTER=1; shift ;;
    --with-agent) WITH_AGENT=1; shift ;;
    --refuse-if-busy) REFUSE_IF_BUSY=1; shift ;;
    --agent-key-file) [ $# -ge 2 ] || { usage >&2; exit 2; }; [ -n "$2" ] || { echo "provision-host.sh: --agent-key-file needs a path, got ''" >&2; exit 2; }; AGENT_KEY_FILE="$2"; shift 2 ;;
    --telemetry-key-file) [ $# -ge 2 ] || { usage >&2; exit 2; }; [ -n "$2" ] || { echo "provision-host.sh: --telemetry-key-file needs a path, got ''" >&2; exit 2; }; TELEMETRY_KEY_FILE="$2"; shift 2 ;;
    --server-url) [ $# -ge 2 ] || { usage >&2; exit 2; }; [ -n "$2" ] || { echo "provision-host.sh: --server-url needs a URL, got ''" >&2; exit 2; }; SERVER_URL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

# --host is interpolated into runner names, labels, paths and plist keys, so
# keep it to a conservative DNS-label shape. Required: defaulting it would let a
# forgotten flag silently act as another host.
case "$HOST" in
  '') echo "provision-host.sh: --host <name> is required" >&2; usage >&2; exit 2 ;;
  [!a-z0-9]*|*[!a-z0-9-]*|*-) echo "provision-host.sh: --host must match [a-z0-9]([a-z0-9-]*[a-z0-9])?, got '${HOST}'" >&2; exit 2 ;;
esac

# --legacy-names reproduces M1Mini's live unsuffixed VM/daemon names. On any
# other host it would plan a colliding `ci-linux` VM (and its 6 GiB default),
# so it is M1Mini-only (XACA-1436-014).
if [ "$LEGACY_NAMES" = "1" ] && [ "$HOST" != "m1mini" ]; then
  echo "provision-host.sh: --legacy-names is only valid with --host m1mini, got '${HOST}'" >&2
  exit 2
fi

# ── Agent / --no-register flag validation (XACA-1442), all rc 2 ──────────
agent_usage_err() { echo "provision-host.sh: $*" >&2; exit 2; }
if [ "$WITH_AGENT" != "1" ]; then
  [ -z "$AGENT_KEY_FILE" ] || agent_usage_err "--agent-key-file requires --with-agent"
  [ -z "$SERVER_URL" ] || agent_usage_err "--server-url requires --with-agent"
fi
if [ "$WITH_AGENT" = "1" ] && [ "$MODE" = "baseline-only" ]; then
  agent_usage_err "--with-agent cannot be combined with --baseline-only"
fi
if [ "$NO_REGISTER" = "1" ]; then
  [ -z "$TOKEN_FILE" ] || agent_usage_err "--no-register and --token-file are mutually exclusive"
  [ "$MODE" != "baseline-only" ] || agent_usage_err "--no-register cannot be combined with --baseline-only"
fi
case "$AGENT_KEY_FILE" in
  -*) agent_usage_err "--agent-key-file must be a path, got '${AGENT_KEY_FILE}'" ;;
esac

# Server URL: https only, and a conservative character set, because the value
# is written into agent.json by printf (no JSON escaping) and must never carry
# whitespace, quotes or a backslash. '@' (userinfo), '?' (query) and '#'
# (fragment) are refused too: the agent's validate_server_url rejects them, so
# a host provisioned with one would be installed but never poll. Returns 0 ok /
# 1 refused.
agent_url_ok() {
  case "$1" in
    https://?*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._~:/%+=-]*) return 1 ;;
  esac
  return 0
}
if [ -n "$SERVER_URL" ] && ! agent_url_ok "$SERVER_URL"; then
  agent_usage_err "--server-url must be an https:// URL using only [A-Za-z0-9._~:/%+=-] (no userinfo, query or fragment), got '${SERVER_URL}'"
fi

# The per-host key must be ONE line shaped fcp_ + exactly 43 [A-Za-z0-9_-] (the
# XACA-1441 contract C1; the agent's HOST_KEY_RE refuses any other length, so a
# shorter or longer key would be installed and then never poll). The
# fleet-wide telemetry token has no such prefix, so it is refused here, before
# any mode touches anything. Read via redirect; the value is never printed and
# never in argv. Returns 0 ok, 1 refused (wrong shape), 2 unreadable.
agent_key_check() { # path
  local first="" second=""
  [ -f "$1" ] && [ -r "$1" ] || return 2
  { IFS= read -r first || true; IFS= read -r second || true; } <"$1"
  first="${first%$'\r'}"
  second="${second%$'\r'}"
  [ -z "$second" ] || return 1       # a second non-empty line: not a bare key file
  case "$first" in
    fcp_?*) ;;
    *) return 1 ;;
  esac
  case "${first#fcp_}" in
    # Spelled out, not [A-Za-z]: bash 3.2 collates ranges by locale (XACA-1422-014).
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*) return 1 ;;
  esac
  [ "${#first}" -eq 47 ] || return 1   # "fcp_" (4) + 43
  return 0
}
if [ -n "$AGENT_KEY_FILE" ] && [ "$MODE" != "status" ]; then
  _rc=0; agent_key_check "$AGENT_KEY_FILE" || _rc=$?
  case "$_rc" in
    0) ;;
    1) agent_usage_err "--agent-key-file does not hold a per-host key (one line, fcp_ + 43 chars of [A-Za-z0-9_-]); refusing. The fleet-wide token must never be placed here (XACA-1422)." ;;
    *) [ "$MODE" = "dry-run" ] || agent_usage_err "--agent-key-file not readable: ${AGENT_KEY_FILE}" ;;
  esac
fi

# XACA-1422: the reporter's per-host telemetry key is ONE line shaped fct_ +
# exactly 43 [A-Za-z0-9_-] (server TELEMETRY_KEY_RE). The fleet-wide token and
# the fcp_ dispatch key do not match, so they are refused before any mode
# touches anything. Read via redirect; never printed, never in argv.
# Returns 0 ok, 1 refused (wrong shape), 2 unreadable.
telemetry_key_check() { # path
  local first="" second=""
  [ -f "$1" ] && [ -r "$1" ] || return 2
  { IFS= read -r first || true; IFS= read -r second || true; } <"$1"
  first="${first%$'\r'}"
  second="${second%$'\r'}"
  [ -z "$second" ] || return 1
  case "$first" in
    fct_?*) ;;
    *) return 1 ;;
  esac
  case "${first#fct_}" in
    # Spelled out, not [A-Za-z]: bash 3.2 collates ranges by locale (XACA-1422-014).
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*) return 1 ;;
  esac
  [ "${#first}" -eq 47 ] || return 1   # "fct_" (4) + 43
  return 0
}
case "$TELEMETRY_KEY_FILE" in
  -*) agent_usage_err "--telemetry-key-file must be a path, got '${TELEMETRY_KEY_FILE}'" ;;
esac
if [ -n "$TELEMETRY_KEY_FILE" ] && [ "$MODE" = "baseline-only" ]; then
  agent_usage_err "--telemetry-key-file cannot be combined with --baseline-only (no reporter is staged)"
fi
if [ -n "$TELEMETRY_KEY_FILE" ] && [ "$MODE" != "status" ]; then
  _rc=0; telemetry_key_check "$TELEMETRY_KEY_FILE" || _rc=$?
  case "$_rc" in
    0) ;;
    1) agent_usage_err "--telemetry-key-file does not hold a per-host telemetry key (one line, fct_ + 43 chars of [A-Za-z0-9_-]); refusing. The fleet-wide token must never be placed on this host (XACA-1422)." ;;
    *) [ "$MODE" = "dry-run" ] || agent_usage_err "--telemetry-key-file not readable: ${TELEMETRY_KEY_FILE}" ;;
  esac
fi

# Everything that used to be a hardcoded `m1mini` / unsuffixed constant.
derive_names() {
  local sfx=".${HOST}"
  VM_MEMORY="${VM_MEMORY_GIB}GiB"
  RUNNER_LABELS="${HOST}${EXTRA_LABELS:+,${EXTRA_LABELS}}"
  MAC_RUNNER_NAME="${HOST}-macos-1"
  REPORTER_MACHINE="$HOST"
  if [ "$LEGACY_NAMES" = "1" ]; then
    sfx=""
    VM_NAME="ci-linux"
  else
    VM_NAME="ci-linux-${HOST}"
  fi
  [ -z "$VM_NAME_OVERRIDE" ] || VM_NAME="$VM_NAME_OVERRIDE"
  LABEL_VM="com.doublenode.ci-runner${sfx}.lima-vm"
  LABEL_MAC="com.doublenode.ci-runner${sfx}.macos"
  LABEL_REPORTER="com.doublenode.ci-runner${sfx}.reporter"
  LABEL_AGENT="com.doublenode.ci-runner${sfx}.agent"
  PLIST_VM="${LD_DIR}/${LABEL_VM}.plist"
  PLIST_MAC="${LD_DIR}/${LABEL_MAC}.plist"
  PLIST_REPORTER="${LD_DIR}/${LABEL_REPORTER}.plist"
  PLIST_AGENT="${LD_DIR}/${LABEL_AGENT}.plist"
}
derive_names

log()  { printf '[provision-%s] %s\n' "$HOST" "$*"; }
warn() { printf '[provision-%s] WARN: %s\n' "$HOST" "$*" >&2; }
die()  { printf '[provision-%s] ERROR: %s\n' "$HOST" "$*" >&2; exit 1; }
plan() { printf '[dry-run] %s\n' "$*"; }

# ── Helpers ───────────────────────────────────────────────────────────────
# Run a command as ci-runner with a known PATH/HOME. In baseline-only mode we
# are a developer on a scratch VM, so run as ourselves. `sudo -n`: never
# prompt (status/dry-run as a non-sudoer must fail fast, not hang).
as_ci() {
  if [ "$MODE" = "baseline-only" ] || [ "$(id -un)" = "$CI_USER" ]; then
    env PATH="$CI_PATH" "$@"
  else
    sudo -n -u "$CI_USER" -H env PATH="$CI_PATH" "$@"
  fi
}

# Can we act as ci-runner at all (root, or passwordless sudo)?
can_as_ci() {
  [ "$MODE" = "baseline-only" ] && return 0
  [ "$(id -un)" = "$CI_USER" ] && return 0
  sudo -n -u "$CI_USER" true >/dev/null 2>&1
}

# Guest commands. stdin is forwarded; --workdir /tmp because with no mounts
# there is no host cwd to chdir into.
guest() { as_ci "$LIMACTL" shell --workdir /tmp "$VM_NAME" -- "$@"; }

# Run a multi-line/quoted snippet in the guest via stdin. `limactl shell`
# re-parses argv through ssh's remote shell, so quoting through argv is
# fragile; stdin is not.
guest_sh() { printf '%s\n' "$1" | guest bash -s; }

# Echoes Running | Stopped | absent | unknown. Capture-first so a failed
# limactl is "absent/unknown", not a silently empty string.
vm_state() {
  local out rc
  if ! can_as_ci; then echo unknown; return 0; fi
  rc=0
  out=$(as_ci "$LIMACTL" list --format '{{.Status}}' "$VM_NAME" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then echo absent; else echo "${out:-absent}"; fi
}

daemon_loaded() { launchctl print "system/$1" >/dev/null 2>&1; }

daemon_state() { # echoes running | loaded-idle | not-loaded
  local out
  if ! out=$(launchctl print "system/$1" 2>/dev/null); then echo "not-loaded"; return 0; fi
  if grep -q 'state = running' <<<"$out"; then echo running; else echo loaded-idle; fi
}

# XACA-1443-014. Sets VERSION, RUNNER_SHA_LINUX, RUNNER_SHA_OSX, RUNNER_SOURCE (latest|explicit|pinned|kept) and
# RUNNER_CHECKED_AT; returns 1 (CI_RUNNER_WHY set) when no VERIFIABLE runner can be chosen. Loud, never silent, when it
# could not reach GitHub. JIT one-job runners cannot disable self-update (the setting is in the server-generated JIT
# config), so the cached tarball is what keeps them current: see docs/ci-runner-runbook.md section 8.
resolve_runner_try() {
  local lib="${_PH_DIR}/lib/ci-runner-version.sh" kv="" ksl="" kso="" kat=""
  if [ ! -r "$lib" ]; then CI_RUNNER_WHY="${lib} is missing"; return 1; fi
  # shellcheck source=/dev/null
  . "$lib"
  # A runner staged earlier lets a refresh that cannot reach GitHub KEEP it rather than fall back to an older pin.
  if ci_runner_manifest_record "$HOST" 2>/dev/null && [ -n "$CI_RR_LINUX" ]; then
    set -- $CI_RR_LINUX; kv="$1"; ksl="$2"
    if [ -n "$CI_RR_OSX" ]; then set -- $CI_RR_OSX; if [ "$1" = "$kv" ]; then kso="$2"; fi; fi
    # --no-macos hosts record no macOS runner; the macOS digest is unused there, so any valid digest will do.
    if [ "$NO_MACOS" = "1" ] && [ -z "$kso" ]; then kso="$ksl"; fi
    kat="$CI_RR_CHECKED_AT"
  fi
  ci_runner_resolve "${_PH_DIR}/runner-pin.conf" "${RUNNER_VERSION:-}" "$kv" "$ksl" "$kso" "$kat" || return 1
  VERSION="$CI_RUNNER_VERSION"; RUNNER_SHA_LINUX="$CI_RUNNER_SHA_LINUX"; RUNNER_SHA_OSX="$CI_RUNNER_SHA_OSX"
  RUNNER_SOURCE="$CI_RUNNER_SOURCE"
  RUNNER_CHECKED_AT="${CI_RUNNER_CHECKED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  return 0
}
resolve_runner() {
  resolve_runner_try || die "cannot choose an actions/runner to stage: ${CI_RUNNER_WHY}"
  if [ -n "$CI_RUNNER_NOTICE" ]; then warn "${CI_RUNNER_NOTICE}"; fi
  log "actions/runner version: ${VERSION} (${RUNNER_SOURCE}; sha256 linux-arm64 ${RUNNER_SHA_LINUX%${RUNNER_SHA_LINUX#????????}}..., osx-arm64 ${RUNNER_SHA_OSX%${RUNNER_SHA_OSX#????????}}...)"
}

# Install a LaunchDaemon plist produced by generator function $2. Returns 0 if
# it wrote a changed file, 1 if the installed file already matched. (A
# generator, not stdin: `die` inside a pipeline stage would only exit that
# subshell and read as "unchanged".)
install_plist() {
  local dest="$1" gen="$2" tmp
  tmp=$(mktemp /tmp/ci-runner-plist.XXXXXX)
  "$gen" >"$tmp"
  if ! plutil -lint "$tmp" >/dev/null; then rm -f "$tmp"; die "generated plist for $dest failed plutil -lint"; fi
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 1; fi
  install -m 644 -o root -g wheel "$tmp" "$dest"
  rm -f "$tmp"
  return 0
}

# (Re)load a daemon: bootstrap if absent, bootout+bootstrap if its plist
# changed. Sets LOADED_FRESH=1 when this call (re)started the job.
LOADED_FRESH=0
ensure_daemon_loaded() { # label plist changed(0|1)
  local label="$1" plist="$2" changed="$3"
  LOADED_FRESH=0
  if daemon_loaded "$label" && [ "$changed" = "1" ]; then
    launchctl bootout "system/$label" || warn "bootout $label returned non-zero"
  fi
  if ! daemon_loaded "$label"; then
    launchctl bootstrap system "$plist"
    LOADED_FRESH=1
    log "loaded daemon $label"
  else
    log "daemon $label already loaded"
  fi
}

# ── Lima VM definition ────────────────────────────────────────────────────
# `mounts: []` in YAML does NOT remove the template's default home mount
# (measured on Lima 2.2.0: lists merge). Only `--mount-none` does. The YAML
# line is kept as documentation; the flag is the control; the post-start
# guest check is the proof.
vm_yaml() {
  cat <<EOF
minimumLimaVersion: "2.0.0"
base: template:ubuntu-24.04
vmType: vz
cpus: ${VM_CPUS}
memory: ${VM_MEMORY}
disk: ${VM_DISK}
mounts: []
containerd:
  system: false
  user: false
EOF
}

# ── LaunchDaemon plists ───────────────────────────────────────────────────
plist_vm() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL_VM}</string>
  <key>UserName</key><string>${CI_USER}</string>
  <key>GroupName</key><string>${CI_GROUP}</string>
  <!-- XACA-1386: after an UNCLEAN host shutdown (crash/power loss, measured
       2026-10-02) lima leaves a stale ha.sock/ha.pid, and a bare
       \`limactl start\` dies on it ("dial unix .../ha.sock: connection refused"),
       so this run-once job never brought the VM back. If the VM is not
       Running, remove the stale *.pid / *.sock / *.tmp files (the same set
       \`limactl stop -f\` removes), then start. Deliberately NOT \`stop -f\`:
       it SIGKILLs the PIDs recorded in the stale pid files, and after a
       reboot those PIDs belong to unrelated processes (measured: it tried to
       kill PID 341, refused only because another user owned it; a ci-runner
       process such as the macOS Runner.Listener would have been killed).
       A Running VM is left alone (manual kickstart is safe). Cleanup runs
       ONLY on a positively observed Stopped/Broken status: if \`limactl list\`
       itself fails (empty or unexpected status) nothing is deleted, because
       the VM might be live (PR #1025 review, XACA-1386-024). -->
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string><string>-c</string>
    <string>st=\$("\$0" list --format '{{.Status}}' "\$1" 2>/dev/null); case "\$st" in Running) exit 0 ;; Stopped|Broken) d="\$HOME/.lima/\$1"; [ -d "\$d" ] &amp;&amp; rm -f "\$d"/*.pid "\$d"/*.sock "\$d"/*.tmp ;; esac; exec "\$0" start --tty=false "\$1"</string>
    <string>${LIMACTL}</string><string>${VM_NAME}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${CI_HOME}</string>
    <key>PATH</key><string>${CI_PATH}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <!-- limactl start exits once the VM is booted; the hostagent that keeps it
       alive is its child. Without this launchd reaps it when the job exits. -->
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>${LOG_DIR}/lima-vm.out.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/lima-vm.err.log</string>
</dict>
</plist>
EOF
}

plist_mac() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL_MAC}</string>
  <key>UserName</key><string>${CI_USER}</string>
  <key>GroupName</key><string>${CI_GROUP}</string>
  <key>WorkingDirectory</key><string>${MAC_RUNNER_DIR}</string>
  <key>ProgramArguments</key>
  <array><string>${MAC_RUNNER_DIR}/runsvc.sh</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${CI_HOME}</string>
    <key>PATH</key><string>${CI_PATH}</string>
    <key>ACTIONS_RUNNER_SVC</key><string>1</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${LOG_DIR}/macos-runner.out.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/macos-runner.err.log</string>
</dict>
</plist>
EOF
}

# Reporter environment, derived from the SAME values the stage_* functions
# provision, so the telemetry describes this host and not the reporter's
# built-in M1Mini defaults (XACA-1436-017). Names/dirs/labels are validated
# (need_name / --host regex) so nothing here needs XML escaping.
reporter_linux_runners() { # "<host>-linux-1=/opt/actions-runner-1 ..."
  local i=1 out=""
  while [ "$i" -le "$LINUX_RUNNER_COUNT" ]; do
    out="${out:+${out} }${HOST}-linux-${i}=/opt/actions-runner-${i}"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# The plist <dict> body for the macOS side. Under --no-macos the reporter gets
# an explicitly EMPTY CI_RUNNER_MAC_RUNNER (set-but-empty = "no macOS runner";
# unset would fall back to the M1Mini default and report a phantom runner).
reporter_mac_env() {
  if [ "$NO_REGISTER" = "1" ]; then
    # XACA-1442: nothing is registered, so there is no persistent macOS runner
    # to report either (same explicit-empty override as --no-macos).
    printf '    <key>CI_RUNNER_MAC_RUNNER</key><string></string>\n'
  elif [ "$NO_MACOS" = "1" ]; then
    printf '    <key>CI_RUNNER_MAC_RUNNER</key><string></string>\n'
  else
    printf '    <key>CI_RUNNER_MAC_RUNNER</key><string>%s=%s</string>\n' "$MAC_RUNNER_NAME" "$MAC_RUNNER_DIR"
    printf '    <key>CI_RUNNER_MAC_LABEL</key><string>%s</string>\n' "$LABEL_MAC"
    printf '    <key>CI_RUNNER_MAC_USER</key><string>%s</string>\n' "$CI_USER"
    printf '    <key>CI_RUNNER_LABELS_MAC</key><string>self-hosted,macOS,ARM64,%s</string>\n' "$RUNNER_LABELS"
  fi
}

plist_reporter() {
  local linux_runners mac_env
  linux_runners=$(reporter_linux_runners)
  mac_env=$(reporter_mac_env)
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL_REPORTER}</string>
  <key>UserName</key><string>${CI_USER}</string>
  <key>GroupName</key><string>${CI_GROUP}</string>
  <!-- One run per launch. launchd never overlaps a still-running instance, so
       a slow run just skips ticks. No secret here: URL and key come from
       ${REPORTER_CFG} (mode 600). Homebrew is not on launchd's PATH; the
       reporter and this PATH use full locations. -->
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>${REPORTER_DEST}</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${CI_HOME}</string>
    <key>PATH</key><string>${CI_PATH}</string>
    <key>CI_RUNNER_MACHINE</key><string>${REPORTER_MACHINE}</string>
    <key>CI_RUNNER_VM_NAME</key><string>${VM_NAME}</string>
    <key>CI_RUNNER_LINUX_RUNNERS</key><string>${linux_runners}</string>
    <key>CI_RUNNER_LABELS_LINUX</key><string>self-hosted,Linux,ARM64,${RUNNER_LABELS}</string>
    <key>CI_RUNNER_DISK_PATH</key><string>${CI_HOME}</string>
${mac_env}
  </dict>
  <key>StartInterval</key><integer>${REPORTER_INTERVAL}</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>${LOG_DIR}/reporter.out.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/reporter.err.log</string>
</dict>
</plist>
EOF
}

# Fleet CI Pool agent daemon (XACA-1442). Deliberately NO UserName/GroupName:
# launchd then runs it as root (plan D2: a ci-runner-owned agent would hand the
# dispatch key to every macOS job). No secret here: the key lives in
# ${AGENT_KEY} (root:wheel 0600) and is read by the agent each poll; the only
# environment is PATH and the config path.
plist_agent() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL_AGENT}</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/python3</string><string>${AGENT_DEST}</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>${CI_PATH}</string>
    <key>CI_POOL_AGENT_CONFIG</key><string>${AGENT_CFG}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>${AGENT_LOG_DIR}/launchd.out.log</string>
  <key>StandardErrorPath</key><string>${AGENT_LOG_DIR}/launchd.err.log</string>
</dict>
</plist>
EOF
}

# ── Guest-side scripts (run inside the VM as root) ────────────────────────
guest_baseline_script() {
  cat <<'GUEST'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
PKGS="git curl ca-certificates unzip jq zsh bats expect tmux build-essential python3 python3-pip python3-venv gh shellcheck net-tools"
missing=""
for p in $PKGS; do dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"; done
if [ -n "$missing" ]; then
  echo "apt: installing:$missing"
  apt-get update -qq
  # shellcheck disable=SC2086  # word-splitting of the package list is intended
  apt-get install -y -qq $missing
else
  echo "apt: baseline packages already present"
fi
if ! id runner >/dev/null 2>&1; then
  useradd -m -s /bin/bash runner
  echo "created guest user runner"
fi
# GitHub-hosted runners give the job user passwordless sudo and workflows
# rely on it (sudo apt-get). The VM is the boundary, not sudo.
SUDOERS=/etc/sudoers.d/90-runner
if ! grep -qs '^runner ALL=(ALL) NOPASSWD:ALL$' "$SUDOERS"; then
  echo 'runner ALL=(ALL) NOPASSWD:ALL' >"$SUDOERS.tmp"
  chmod 440 "$SUDOERS.tmp"
  visudo -cf "$SUDOERS.tmp" >/dev/null
  mv "$SUDOERS.tmp" "$SUDOERS"
  echo "installed $SUDOERS"
fi
GUEST
}

# Args: IDX VERSION NAME LABELS URL REGISTER(1|0) SHA256. Token = first stdin line. SHA256 = the expected digest of the
# linux-arm64 tarball (XACA-1443-014): required, 64 hex. No digest, or a mismatch, refuses to stage (it used to skip the
# check when the digest could not be read). A cached tarball is re-verified too, and other versions are pruned.
guest_runner_script() {
  cat <<'GUEST'
#!/bin/bash
set -euo pipefail
IDX="$1"; VER="$2"; NAME="$3"; LABELS="$4"; URL="$5"; REGISTER="$6"; WANT="${7:-}"
case "$WANT" in ''|*[!0-9a-f]*) echo "ERROR: no valid expected sha256 for runner ${VER}; refusing to stage an unverified runner" >&2; exit 1 ;; esac
[ "${#WANT}" -eq 64 ] || { echo "ERROR: expected sha256 for runner ${VER} is not 64 hex; refusing" >&2; exit 1; }
DIR="/opt/actions-runner-${IDX}"
DIST="/opt/runner-dist"
TB="${DIST}/actions-runner-linux-arm64-${VER}.tar.gz"

mkdir -p "$DIST" "$DIR"
chown runner:runner "$DIR"

if [ -s "$TB" ] && [ "$(sha256sum "$TB" | awk '{print $1}')" != "$WANT" ]; then
  echo "cached ${TB} does not match the expected sha256; discarding it"; rm -f "$TB"
fi
if [ ! -s "$TB" ]; then
  echo "downloading actions-runner ${VER} (linux-arm64)"
  curl -fsSL -o "${TB}.part" \
    "https://github.com/actions/runner/releases/download/v${VER}/actions-runner-linux-arm64-${VER}.tar.gz"
  actual=$(sha256sum "${TB}.part" | awk '{print $1}')
  if [ "$WANT" != "$actual" ]; then
    rm -f "${TB}.part"; echo "ERROR: sha256 mismatch for runner ${VER}: expected ${WANT}, got ${actual}" >&2; exit 1
  fi
  mv "${TB}.part" "$TB"
fi
# One tarball stays in the cache: the JIT launcher extracts the NEWEST file here for every job, so an older one must go.
for f in "${DIST}"/actions-runner-linux-arm64-*.tar.gz; do
  [ -e "$f" ] || continue
  [ "$f" = "$TB" ] || rm -f "$f"
done

if [ ! -x "${DIR}/config.sh" ]; then
  sudo -u runner tar xzf "$TB" -C "$DIR"
  # Noisy (apt probes libicu80..74); keep the log, show it only on failure.
  if ! "${DIR}/bin/installdependencies.sh" >"/var/log/ci-runner-installdeps-${IDX}.log" 2>&1; then
    tail -30 "/var/log/ci-runner-installdeps-${IDX}.log" >&2; exit 1
  fi
  echo "extracted runner ${VER} into ${DIR}"
fi

if [ ! -f "${DIR}/.runner" ]; then
  if [ "$REGISTER" != "1" ]; then echo "baseline-only: not registering ${NAME}"; exit 0; fi
  # `|| true`, not `|| [ -n ... ]`: on empty stdin the latter is false and
  # set -e would exit silently before the error below could explain why.
  TOKEN=""
  IFS= read -r TOKEN || true
  TOKEN="${TOKEN%$'\r'}"
  [ -n "$TOKEN" ] || { echo "ERROR: ${NAME} is not registered and no registration token was given; re-run with --token-file" >&2; exit 1; }
  # Env var, not --token: keeps it out of every argv in the guest too.
  export ACTIONS_RUNNER_INPUT_TOKEN="$TOKEN"
  unset TOKEN
  ( cd "$DIR" && sudo -u runner -H --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN \
      ./config.sh --unattended --url "$URL" --name "$NAME" \
      --labels "$LABELS" --work _work --replace )
  unset ACTIONS_RUNNER_INPUT_TOKEN
else
  echo "${NAME}: already registered (.runner present) — not re-registering"
fi

[ "$REGISTER" = "1" ] || exit 0
if [ ! -f "${DIR}/.service" ]; then
  ( cd "$DIR" && ./svc.sh install runner )
fi
svc=$(cat "${DIR}/.service")
if ! systemctl is-active --quiet "$svc"; then
  ( cd "$DIR" && ./svc.sh start )
fi
systemctl is-active "$svc"
GUEST
}

# ── Stages ────────────────────────────────────────────────────────────────
check_no_host_mounts() {
  local cfg mounts
  cfg=$(as_ci "$LIMACTL" list --format '{{len .Config.Mounts}}' "$VM_NAME")
  [ "$cfg" = "0" ] || die "VM ${VM_NAME} has ${cfg} host mount(s) configured; refusing to continue. Delete it (limactl delete -f ${VM_NAME}) and re-run."
  mounts=$(guest_sh 'mount | grep -Ei "virtiofs|9p|sshfs" || true')
  [ -z "$mounts" ] || die "guest shows host-share mounts: ${mounts}"
  log "isolation OK: 0 configured mounts, no virtiofs/9p/sshfs in guest"
}

stage_vm() {
  local state
  state=$(vm_state)
  if [ "$state" = "absent" ]; then
    log "creating Lima VM ${VM_NAME} (${VM_CPUS} CPU / ${VM_MEMORY} / ${VM_DISK}, no mounts)"
    vm_yaml | as_ci "$LIMACTL" create --name="$VM_NAME" --tty=false --mount-none -
  else
    log "VM ${VM_NAME} exists (${state})"
  fi
}

stage_vm_running() {
  local i state
  if [ "$MODE" = "baseline-only" ]; then
    state=$(vm_state)
    [ "$state" = "Running" ] || as_ci "$LIMACTL" start --tty=false "$VM_NAME"
    return 0
  fi
  # Daemon-driven start, so what we verify is what a reboot will do.
  local changed=0 fresh_wait=0
  if install_plist "$PLIST_VM" plist_vm; then changed=1; log "wrote $PLIST_VM"; fi
  ensure_daemon_loaded "$LABEL_VM" "$PLIST_VM" "$changed"
  [ "$LOADED_FRESH" = "1" ] && fresh_wait=1

  state=$(vm_state)
  if [ "$state" != "Running" ] && [ "$fresh_wait" = "0" ]; then
    log "VM is ${state} though its daemon is loaded; kickstarting"
    launchctl kickstart -k "system/$LABEL_VM"
    fresh_wait=1
  fi
  i=0
  while [ "$(vm_state)" != "Running" ]; do
    i=$((i + 1)); [ "$i" -le 60 ] || die "VM ${VM_NAME} not Running after 5 min; see ${LOG_DIR}/lima-vm.*.log"
    sleep 5
  done
  log "VM ${VM_NAME} is Running"
  if [ "$fresh_wait" = "1" ]; then
    log "daemon was just loaded: waiting 60 s to prove the hostagent survives job exit"
    sleep 60
    [ "$(vm_state)" = "Running" ] || die "VM stopped after the launchd job exited (AbandonProcessGroup not effective?)"
    log "VM still Running after 60 s"
  fi
}

stage_guest_baseline() {
  log "guest baseline (apt packages, runner user, sudoers)"
  guest_baseline_script | guest sudo bash -s
}

stage_linux_runners() {
  local version="$1" register="$2" i name
  guest_runner_script | guest sudo install -m 755 /dev/stdin "$GUEST_SCRIPT"
  i=1
  while [ "$i" -le "$LINUX_RUNNER_COUNT" ]; do
    name="${HOST}-linux-${i}"
    log "linux runner ${name}"
    if [ "$register" = "1" ]; then
      # No token file = converge-only run: the guest script skips registered
      # runners and fails with a clear message on an unregistered one.
      guest sudo "$GUEST_SCRIPT" "$i" "$version" "$name" "$RUNNER_LABELS" "$REPO_URL" 1 "$RUNNER_SHA_LINUX" <"${TOKEN_FILE:-/dev/null}"
    else
      guest sudo "$GUEST_SCRIPT" "$i" "$version" "$name" "$RUNNER_LABELS" "$REPO_URL" 0 "$RUNNER_SHA_LINUX" </dev/null
    fi
    i=$((i + 1))
  done
}

stage_macos_runner() {
  local version="$1" dist tb expected actual f
  if [ "$NO_MACOS" = "1" ]; then log "macOS runner skipped (--no-macos)"; return 0; fi
  as_ci mkdir -p "$LOG_DIR" "${CI_HOME}/runner-dist" "$MAC_RUNNER_DIR"
  dist="${CI_HOME}/runner-dist"
  tb="${dist}/actions-runner-osx-arm64-${version}.tar.gz"
  # XACA-1443-014: verified against the digest resolve_runner took from the release notes (or runner-pin.conf). A cached
  # tarball is re-verified; a download that does not match is deleted; no digest is never a pass.
  if [ -s "$tb" ] && ! ci_runner_verify_file "$tb" "$RUNNER_SHA_OSX"; then
    warn "cached ${tb} does not match the expected sha256 (or cannot be verified); discarding it"
    as_ci rm -f "$tb"
  fi
  if [ ! -s "$tb" ]; then
    log "downloading actions-runner ${version} (osx-arm64)"
    as_ci curl -fsSL -o "${tb}.part" \
      "https://github.com/actions/runner/releases/download/v${version}/actions-runner-osx-arm64-${version}.tar.gz"
    actual=$(as_ci shasum -a 256 "${tb}.part" | awk '{print $1}')
    expected="$RUNNER_SHA_OSX"
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
      as_ci rm -f "${tb}.part"; die "sha256 mismatch for macOS runner ${version}: expected ${expected:-<none>}, got ${actual:-<none>}"
    fi
    as_ci mv "${tb}.part" "$tb"
  fi
  # One tarball stays in the cache: the JIT launcher extracts the NEWEST file here for every job.
  for f in "${dist}"/actions-runner-osx-arm64-*.tar.gz; do
    [ -e "$f" ] || continue
    [ "$f" = "$tb" ] || as_ci rm -f "$f"
  done
  if [ "$NO_REGISTER" = "1" ]; then
    # XACA-1442: JIT model. The tarball cache above is all the agent needs;
    # no persistent runner is extracted, registered or daemonized.
    log "macOS runner not registered (--no-register): tarball cached only, no runner daemon"
    return 0
  fi
  if [ ! -x "${MAC_RUNNER_DIR}/config.sh" ]; then
    as_ci tar xzf "$tb" -C "$MAC_RUNNER_DIR"
    log "extracted macOS runner into ${MAC_RUNNER_DIR}"
  fi
  if [ ! -f "${MAC_RUNNER_DIR}/.runner" ]; then
    [ -n "$TOKEN_FILE" ] || die "${MAC_RUNNER_NAME} is not registered and no registration token was given; re-run with --token-file"
    log "registering ${MAC_RUNNER_NAME}"
    # Token via stdin -> shell variable -> env of config.sh only. The PATH
    # given here is what config.sh records in .path for the service.
    as_ci /bin/bash -c '
      cd "$1" || exit 1
      IFS= read -r T || [ -n "${T:-}" ]
      T=$(printf "%s" "$T" | tr -d "\r")
      [ -n "$T" ] || { echo "empty token" >&2; exit 1; }
      ACTIONS_RUNNER_INPUT_TOKEN="$T" exec ./config.sh --unattended \
        --url "$2" --name "$3" --labels "$4" --work _work --replace
    ' _ "$MAC_RUNNER_DIR" "$REPO_URL" "$MAC_RUNNER_NAME" "$RUNNER_LABELS" <"$TOKEN_FILE"
  else
    log "${MAC_RUNNER_NAME}: already registered (.runner present) — not re-registering"
  fi
  # runsvc.sh is what the runner's own darwin svc.sh copies from bin/ and
  # points its launchd template at: it wraps RunnerService.js, which supervises
  # Runner.Listener, performs the self-update restart, and turns launchd's
  # SIGTERM into the listener's graceful SIGINT. run.sh would work but lacks
  # that supervisor. (Official template also sets ProcessType=Interactive and
  # SessionCreate; omitted — they target a login-session agent, not a daemon.)
  as_ci cp "${MAC_RUNNER_DIR}/bin/runsvc.sh" "${MAC_RUNNER_DIR}/runsvc.sh"
  as_ci chmod 755 "${MAC_RUNNER_DIR}/runsvc.sh"

  local changed=0 i
  if install_plist "$PLIST_MAC" plist_mac; then changed=1; log "wrote $PLIST_MAC"; fi
  ensure_daemon_loaded "$LABEL_MAC" "$PLIST_MAC" "$changed"
  i=0
  while ! pgrep -u "$CI_USER" -f 'Runner.Listener' >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -le 12 ] || die "macOS Runner.Listener not running after 60 s; see ${LOG_DIR}/macos-runner.*.log"
    sleep 5
  done
  log "macOS runner listener is running"
}

# Candidate fleet-config.json on the invoking user's side. Echoes a path or "".
reporter_cfg_source() {
  local c
  if [ -n "$FLEET_CONFIG_SRC" ]; then echo "$FLEET_CONFIG_SRC"; return 0; fi
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    for c in "/Users/${SUDO_USER}/.aiteamforge/fleet-config.json" "/Users/${SUDO_USER}/.dev-team/fleet-config.json"; do
      if [ -f "$c" ]; then echo "$c"; return 0; fi
    done
  fi
  echo ""
}

# Write a MINIMAL fleet-config (centralServer.apiEndpoint + authToken only) to
# stdout (XACA-1422). Args: <source fleet-config or ""> <telemetry key file or
# ""> <existing ci-runner config>. The source's authToken (the FLEET token) is
# never read. authToken = the key file's content, else the existing authToken
# only when it is already an fct_ key; anything else is dropped. Files are read
# by python, never put in argv/env. Exit 0 = endpoint + key both present; else a
# bitmask on top of valid stdout: 2 = no key, 4 = no endpoint, 8 = a non-fct_
# token was dropped from the existing file. 1 = python error (no usable stdout).
reporter_cfg_generate() {
  "${PROVISION_PYTHON:-python3}" - "$1" "$2" "$3" <<'PY'
import json, re, sys
KEY = re.compile(r"fct_[A-Za-z0-9_-]{43}")
def cs_of(path):
    if not path:
        return {}
    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return {}
    cs = d.get("centralServer") if isinstance(d, dict) else None
    return cs if isinstance(cs, dict) else {}
src, keyfile, cur = sys.argv[1:4]
old = cs_of(cur)
ep = cs_of(src).get("apiEndpoint")
if not (isinstance(ep, str) and ep):
    ep = old.get("apiEndpoint")
tok, rc = None, 0
if keyfile:
    with open(keyfile) as f:
        line = f.readline().rstrip("\r\n")
    if not KEY.fullmatch(line):
        sys.exit(1)
    tok = line
else:
    t = old.get("authToken")
    if isinstance(t, str) and KEY.fullmatch(t):
        tok = t
    elif t:
        rc |= 8
cs = {}
if isinstance(ep, str) and ep:
    cs["apiEndpoint"] = ep
else:
    rc |= 4
if tok:
    cs["authToken"] = tok
else:
    rc |= 2
json.dump({"centralServer": cs}, sys.stdout, indent=2)
sys.stdout.write("\n")
sys.exit(rc)
PY
}

# Install file $1 to $2 (mode $3, owner $4, group $5) only when content
# differs. Returns 0 if it wrote, 1 if already identical.
install_if_changed() {
  local src="$1" dest="$2" mode="$3" owner="$4" group="$5"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then return 1; fi
  install -m "$mode" -o "$owner" -g "$group" "$src" "$dest"
  return 0
}

stage_reporter() {
  local tmp src cfg_ok=0 pchanged=0
  [ -f "$REPORTER_SRC" ] || die "reporter source not found: ${REPORTER_SRC}"

  # 1. the script: root-owned, so a job running as ci-runner cannot edit what
  #    the daemon executes next minute.
  install -d -m 755 -o root -g wheel "$(dirname "$REPORTER_DEST")"
  if install_if_changed "$REPORTER_SRC" "$REPORTER_DEST" 755 root wheel; then
    log "installed ${REPORTER_DEST}"
  else
    log "${REPORTER_DEST} already current"
  fi

  # 2. URL + per-host telemetry key for ci-runner (mode 600, never in the
  #    plist). XACA-1422: the fleet token is never copied; see reporter_cfg_generate.
  install -d -m 700 -o "$CI_USER" -g "$CI_GROUP" "$REPORTER_CFG_DIR"
  src=$(reporter_cfg_source)
  [ -n "$src" ] && [ -f "$src" ] || src=""
  if [ -z "$src" ] && [ -z "$TELEMETRY_KEY_FILE" ] && [ ! -f "$REPORTER_CFG" ]; then
    warn "no fleet-config.json source (pass --fleet-config <path>) and no --telemetry-key-file; the reporter will load but cannot POST until ${REPORTER_CFG} exists"
  else
    tmp=$(mktemp /tmp/ci-runner-fleetcfg.XXXXXX)
    chmod 600 "$tmp"
    local grc=0
    reporter_cfg_generate "$src" "$TELEMETRY_KEY_FILE" "$REPORTER_CFG" >"$tmp" 2>/dev/null || grc=$?
    if [ "$grc" = "1" ]; then
      rm -f "$tmp"
      # An unreadable/odd existing file may still hold a fleet token: never leave it.
      [ ! -f "$REPORTER_CFG" ] || die "could not rewrite ${REPORTER_CFG}; refusing to leave a possible fleet token on this host"
      warn "could not build ${REPORTER_CFG}; not touching it"
    elif [ "$grc" = "6" ] && [ ! -f "$REPORTER_CFG" ]; then
      rm -f "$tmp"
      warn "${src:-no source} has no centralServer.apiEndpoint and no telemetry key was given; not creating ${REPORTER_CFG}"
    else
      if [ $((grc & 8)) -ne 0 ]; then
        warn "removed a non-per-host authToken from ${REPORTER_CFG}: the fleet-wide token must not live on this host (XACA-1422)"
      fi
      if [ $((grc & 4)) -ne 0 ]; then
        warn "no centralServer.apiEndpoint (pass --fleet-config <path>); the reporter cannot POST"
      fi
      if [ $((grc & 2)) -ne 0 ]; then
        warn "no per-host telemetry key in ${REPORTER_CFG}: the reporter will NOT report until this script is re-run with --telemetry-key-file <path> (mint: runbook section 11)"
      fi
      [ "$grc" != "0" ] || cfg_ok=1
      if install_if_changed "$tmp" "$REPORTER_CFG" 600 "$CI_USER" "$CI_GROUP"; then
        log "wrote ${REPORTER_CFG} (apiEndpoint${src:+ from ${src}}; telemetry key $([ -n "$TELEMETRY_KEY_FILE" ] && echo 'from --telemetry-key-file' || echo 'kept/absent'); mode 600)"
      else
        log "${REPORTER_CFG} already current"
      fi
      rm -f "$tmp"
    fi
  fi

  # 3. the daemon (System domain, like the runners). A script/config change
  #    needs no reload (every tick re-reads both); only a plist change does.
  if install_plist "$PLIST_REPORTER" plist_reporter; then pchanged=1; log "wrote $PLIST_REPORTER"; fi
  ensure_daemon_loaded "$LABEL_REPORTER" "$PLIST_REPORTER" "$pchanged"
  [ "$cfg_ok" = "1" ] || warn "reporter daemon loaded without a usable URL + telemetry key"
  return 0
}

# ── Fleet CI Pool agent stages (XACA-1442; run only under --with-agent) ───
# Install guest-side JIT scripts into the VM. Same stdin technique as
# stage_linux_runners: the file travels on stdin, never in argv.
stage_guest_jit() {
  local f
  [ -f "$GUEST_JIT_SRC" ] || die "guest JIT script source not found: ${GUEST_JIT_SRC}"
  [ -f "$JOB_STARTED_SRC" ] || die "job-started hook source not found: ${JOB_STARTED_SRC}"
  log "guest JIT scripts: ${GUEST_JIT_DEST}, ${GUEST_JOB_STARTED_DEST}"
  guest sudo install -m 755 /dev/stdin "$GUEST_JIT_DEST" <"$GUEST_JIT_SRC"
  guest sudo install -m 755 /dev/stdin "$GUEST_JOB_STARTED_DEST" <"$JOB_STARTED_SRC"
  f=$(guest_sh "ls -l ${GUEST_JIT_DEST} ${GUEST_JOB_STARTED_DEST} | wc -l" | tr -d ' ')
  [ "$f" = "2" ] || die "guest JIT scripts not present after install"
}

# Install the macOS slot script + hook (root-owned: a job running as ci-runner
# must not be able to edit what the agent executes). Skipped under --no-macos.
stage_mac_jit() {
  if [ "$NO_MACOS" = "1" ]; then log "macOS JIT scripts skipped (--no-macos)"; return 0; fi
  [ -f "$MAC_JIT_SRC" ] || die "macOS JIT script source not found: ${MAC_JIT_SRC}"
  [ -f "$JOB_STARTED_SRC" ] || die "job-started hook source not found: ${JOB_STARTED_SRC}"
  install -d -m 755 -o root -g wheel "$(dirname "$MAC_JIT_DEST")"
  if install_if_changed "$MAC_JIT_SRC" "$MAC_JIT_DEST" 755 root wheel; then log "installed ${MAC_JIT_DEST}"; else log "${MAC_JIT_DEST} already current"; fi
  if install_if_changed "$JOB_STARTED_SRC" "$MAC_JOB_STARTED_DEST" 755 root wheel; then log "installed ${MAC_JOB_STARTED_DEST}"; else log "${MAC_JOB_STARTED_DEST} already current"; fi
}

# Server URL for agent.json: --server-url, else the ORIGIN (scheme://host[:port])
# of centralServer.apiEndpoint in the invoking user's fleet-config (the same
# source stage_reporter uses). Echoes the URL or "" when none can be derived.
agent_server_url() {
  local src
  if [ -n "$SERVER_URL" ]; then echo "$SERVER_URL"; return 0; fi
  src=$(reporter_cfg_source)
  if [ -z "$src" ] || [ ! -f "$src" ]; then echo ""; return 0; fi
  "${PROVISION_PYTHON:-python3}" - "$src" <<'PY' 2>/dev/null || true
import json, sys
from urllib.parse import urlsplit
with open(sys.argv[1]) as f:
    ep = (json.load(f).get("centralServer") or {}).get("apiEndpoint")
if isinstance(ep, str) and ep:
    u = urlsplit(ep)
    # Origin only. An endpoint carrying userinfo is refused (empty output): the
    # agent's validate_server_url would reject it and nothing would ever poll.
    if u.scheme and u.netloc and "@" not in u.netloc:
        sys.stdout.write("%s://%s\n" % (u.scheme, u.netloc))
PY
}

# agent.json body (no secrets). Every interpolated value is validated: HOST by
# the --host regex, VM_NAME by need_name, the URL by agent_url_ok, slots are ints.
agent_cfg_json() { # serverUrl
  local mac=1
  if [ "$NO_MACOS" = "1" ]; then mac=0; fi
  printf '{"serverUrl": "%s", "machine": "%s", "vmName": "%s", "linuxSlots": %s, "macSlots": %s}\n' \
    "$1" "$HOST" "$VM_NAME" "$LINUX_RUNNER_COUNT" "$mac"
}

stage_agent() {
  local url tmp pchanged=0 have_key=0
  [ -f "$AGENT_SRC" ] || die "agent source not found: ${AGENT_SRC}"
  url=$(agent_server_url)
  [ -n "$url" ] || die "no agent server URL: pass --server-url https://... (or have centralServer.apiEndpoint in the invoking user's fleet-config)"
  agent_url_ok "$url" || die "agent server URL is not an acceptable https:// URL: ${url}"

  install -d -m 755 -o root -g wheel "$(dirname "$AGENT_DEST")" "$AGENT_CFG_DIR" "$AGENT_LOG_DIR"
  install -d -m 700 -o root -g wheel "$AGENT_STATE_DIR"
  if install_if_changed "$AGENT_SRC" "$AGENT_DEST" 755 root wheel; then log "installed ${AGENT_DEST}"; else log "${AGENT_DEST} already current"; fi

  tmp=$(mktemp /tmp/ci-pool-agent-cfg.XXXXXX)
  agent_cfg_json "$url" >"$tmp"
  if install_if_changed "$tmp" "$AGENT_CFG" 644 root wheel; then log "wrote ${AGENT_CFG}"; else log "${AGENT_CFG} already current"; fi
  rm -f "$tmp"

  # Key: stdin redirect only (never argv), 0600 root:wheel, umask 077 so even
  # a temp file install creates is never group/world readable.
  if [ -n "$AGENT_KEY_FILE" ]; then
    ( umask 077; install -m 600 -o root -g wheel /dev/stdin "$AGENT_KEY" <"$AGENT_KEY_FILE" )
    log "installed agent key ${AGENT_KEY} (root:wheel 600)"
    have_key=1
  elif [ -f "$AGENT_KEY" ]; then
    log "no --agent-key-file; keeping existing ${AGENT_KEY}"
    have_key=1
  fi

  if install_plist "$PLIST_AGENT" plist_agent; then pchanged=1; log "wrote $PLIST_AGENT"; fi
  ensure_daemon_loaded "$LABEL_AGENT" "$PLIST_AGENT" "$pchanged"
  [ "$have_key" = "1" ] || warn "agent daemon loaded without a key; it cannot poll until ${AGENT_KEY} exists (re-run with --agent-key-file)"
  return 0
}

# ── Status ────────────────────────────────────────────────────────────────
do_status() {
  local rc=0 st nomac="$NO_MACOS"
  # --no-register (XACA-1442): no persistent macOS runner/daemon exists to check.
  if [ "$NO_REGISTER" = "1" ]; then nomac=1; fi
  log "== macOS daemons =="
  for l in "$LABEL_VM" "$LABEL_MAC"; do
    [ "$nomac" = "0" ] || [ "$l" != "$LABEL_MAC" ] || continue
    st=$(daemon_state "$l"); log "  ${l}: ${st}"
  done
  # lima-vm job is run-once: loaded-idle is its healthy state.
  [ "$(daemon_state "$LABEL_VM")" != "not-loaded" ] || rc=1
  if [ "$nomac" = "1" ]; then
    log "  macOS runner: not provisioned ($([ "$NO_MACOS" = "1" ] && echo --no-macos || echo --no-register))"
  else
    [ "$(daemon_state "$LABEL_MAC")" = "running" ] || rc=1
    if pgrep -u "$CI_USER" -f 'Runner.Listener' >/dev/null 2>&1; then
      log "  macOS Runner.Listener process: up"
    else
      log "  macOS Runner.Listener process: DOWN"; rc=1
    fi
  fi
  log "== CI telemetry reporter =="
  st=$(daemon_state "$LABEL_REPORTER"); log "  ${LABEL_REPORTER}: ${st}  (interval job: loaded-idle is healthy)"
  [ "$st" != "not-loaded" ] || rc=1
  if [ -f "$REPORTER_DEST" ]; then log "  script: ${REPORTER_DEST}"; else log "  script MISSING: ${REPORTER_DEST}"; rc=1; fi
  if [ -f "$REPORTER_CFG" ]; then log "  credentials: ${REPORTER_CFG} present"; else log "  credentials MISSING: ${REPORTER_CFG}"; rc=1; fi
  log "  last exit: $(launchctl print "system/${LABEL_REPORTER}" 2>/dev/null | sed -n 's/^[[:space:]]*last exit code = //p' | awk 'NR==1')"
  if [ "$WITH_AGENT" = "1" ]; then
    log "== CI pool agent (XACA-1442) =="
    st=$(daemon_state "$LABEL_AGENT"); log "  ${LABEL_AGENT}: ${st}  (KeepAlive: running is healthy)"
    [ "$st" = "running" ] || rc=1
    if [ -f "$AGENT_DEST" ]; then log "  script: ${AGENT_DEST}"; else log "  script MISSING: ${AGENT_DEST}"; rc=1; fi
    if [ -f "$AGENT_CFG" ]; then log "  config: ${AGENT_CFG} present"; else log "  config MISSING: ${AGENT_CFG}"; rc=1; fi
    if [ -f "$AGENT_KEY" ]; then log "  key: ${AGENT_KEY} present (value never shown)"; else log "  key MISSING: ${AGENT_KEY}"; rc=1; fi
  fi
  log "== Linux VM ${VM_NAME} =="
  if ! can_as_ci; then
    # The Linux side was never checked, so "0 = everything up" would be a
    # false green. 2 = macOS side healthy, Linux side unverified.
    log "  NOT CHECKED (no sudo): VM and Linux runners unverified — re-run with sudo"
    [ "$rc" -ne 0 ] || rc=2
    return "$rc"
  fi
  st=$(vm_state); log "  VM state: ${st}"
  if [ "$st" = "Running" ]; then
    local nmounts
    nmounts=$(guest_sh 'mount | grep -Eic "virtiofs|9p|sshfs" || true' | tr -d ' ')
    log "  guest mounts of host shares: ${nmounts}  (want 0)"
    # A host share in the guest breaks the isolation boundary: unhealthy.
    # Anything unparseable is unhealthy too, never a silent pass.
    [ "$nmounts" = "0" ] || { log "  ISOLATION BROKEN: host share(s) mounted in guest"; rc=1; }
    log "  runner services in guest:"
    guest_sh "systemctl list-units --type=service --no-legend --plain 'actions.runner.*' | awk '{print \"    \" \$1 \" \" \$3 \"/\" \$4}'"
    local active
    active=$(guest_sh "systemctl list-units --type=service --no-legend --plain --state=active 'actions.runner.*' | wc -l" | tr -d ' ')
    [ "$NO_REGISTER" = "1" ] || [ "$active" -ge "$LINUX_RUNNER_COUNT" ] || { log "  expected ${LINUX_RUNNER_COUNT} active runner services, saw ${active}"; rc=1; }
  else
    rc=1
  fi
  log "GitHub-side view:  gh api repos/DoubleNode/dev-team/actions/runners --jq '.runners[]|[.name,.status,([.labels[].name]|join(\",\"))]|@tsv'"
  return "$rc"
}

do_dry_run() {
  local st i linux_names="" linux_idx=""
  i=1
  while [ "$i" -le "$LINUX_RUNNER_COUNT" ]; do
    linux_names="${linux_names:+${linux_names}, }${HOST}-linux-${i}"
    linux_idx="${linux_idx:+${linux_idx},}${i}"
    i=$((i + 1))
  done
  plan "preflight: macOS arm64, user ${CI_USER} exists: $(id -u "$CI_USER" >/dev/null 2>&1 && echo yes || echo 'NO (run create-ci-runner-user.sh first)'); limactl at ${LIMACTL}: $([ -x "$LIMACTL" ] && echo yes || echo NO)"
  if [ -n "$TOKEN_FILE" ]; then plan "token file ${TOKEN_FILE}: $([ -s "$TOKEN_FILE" ] && echo present || echo MISSING) (would be deleted on exit)"; else plan "token file: none given (fine when every runner is already registered; required to register a missing one)"; fi
  plan "resolve actions/runner: \$RUNNER_VERSION, else GitHub latest + its published sha256 (no credentials); if GitHub cannot be asked: keep the staged runner, else the PINNED fallback in runner-pin.conf (announced, sha256-verified); refuse if nothing can be verified. Would use: $( if resolve_runner_try; then echo "${VERSION} (${RUNNER_SOURCE})${CI_RUNNER_NOTICE:+ - NOTICE: ${CI_RUNNER_NOTICE}}"; else echo "REFUSED: ${CI_RUNNER_WHY}"; fi )"
  st=$(vm_state)
  plan "VM ${VM_NAME}: current state ${st}$([ "$st" = unknown ] && echo ' (needs sudo to read)')"
  plan "  would: if absent, limactl create ${VM_NAME} --mount-none (vz, ${VM_CPUS} CPU / ${VM_MEMORY} / ${VM_DISK}, containerd off)"
  plan "  would: write ${PLIST_VM} ($([ -f "$PLIST_VM" ] && echo exists || echo absent)); daemon $(daemon_state "$LABEL_VM"); load it, wait Running, hold 60 s if freshly loaded"
  plan "  would: verify 0 host mounts in config and in guest (virtiofs/9p/sshfs)"
  # The package list lives only in the guest script (single copy, pinned by the
  # XACA-1386 parity check), so read it from there rather than restating it.
  plan "guest: apt baseline $(guest_baseline_script | sed -n 's/^PKGS="\(.*\)"$/\1/p') (skips if present); user runner + /etc/sudoers.d/90-runner"
  plan "guest: ${linux_names} in /opt/actions-runner-{${linux_idx}}: download+sha256 verify, installdependencies.sh, config.sh --labels ${RUNNER_LABELS} (skip if .runner exists), svc.sh install/start"
  if [ "$NO_MACOS" = "1" ]; then
    plan "macOS: SKIPPED (--no-macos): no macOS runner, no ${LABEL_MAC} daemon"
  else
    plan "macOS: ${MAC_RUNNER_NAME} in ${MAC_RUNNER_DIR} (osx-arm64), labels ${RUNNER_LABELS} (+ self-hosted,macOS,ARM64); logs ${LOG_DIR}"
    plan "  would: write ${PLIST_MAC} ($([ -f "$PLIST_MAC" ] && echo exists || echo absent)); daemon $(daemon_state "$LABEL_MAC"); runs runsvc.sh, KeepAlive"
  fi
  plan "reporter: install ${REPORTER_SRC##*/} -> ${REPORTER_DEST} (root, 755: $([ -f "$REPORTER_DEST" ] && echo exists || echo absent)); minimal fleet-config -> ${REPORTER_CFG} (600, ci-runner: $([ -f "$REPORTER_CFG" ] && echo exists || echo absent)); apiEndpoint source: ${FLEET_CONFIG_SRC:-\$SUDO_USER default} (its authToken is never copied)"
  local tk="none given (keeps an existing fct_ key, otherwise the reporter gets NO key)" tkc=0
  if [ -n "$TELEMETRY_KEY_FILE" ]; then
    telemetry_key_check "$TELEMETRY_KEY_FILE" || tkc=$?
    case "$tkc" in
      0) tk="${TELEMETRY_KEY_FILE}: present, fct_ shape OK (value not shown; would be deleted on exit)" ;;
      *) tk="${TELEMETRY_KEY_FILE}: MISSING or unreadable" ;;
    esac
  fi
  plan "  would: telemetry key -> ${REPORTER_CFG} authToken (600, never argv): ${tk}"
  plan "  would: write ${PLIST_REPORTER} ($([ -f "$PLIST_REPORTER" ] && echo exists || echo absent)); daemon $(daemon_state "$LABEL_REPORTER"); StartInterval ${REPORTER_INTERVAL}, CI_RUNNER_MACHINE=${REPORTER_MACHINE}"
  local f lint
  lint=$(mktemp /tmp/ci-runner-dryrun.XXXXXX)
  for f in plist_vm plist_mac plist_reporter; do
    [ "$NO_MACOS" = "0" ] || [ "$f" != "plist_mac" ] || continue
    "$f" >"$lint"
    if plutil -lint "$lint" >/dev/null; then plan "${f}: generated plist passes plutil -lint"; else plan "${f}: plist LINT FAILED"; fi
  done
  rm -f "$lint"
  if [ "$NO_REGISTER" = "1" ]; then
    plan "--no-register: register NO runner (no token needed): guest runner scripts/tarball cache only, no macOS runner extract/daemon; reporter reports no macOS runner"
  fi
  if [ "$WITH_AGENT" = "1" ]; then
    local k="none given (keeps an existing ${AGENT_KEY})" kc=0 url alint
    if [ -n "$AGENT_KEY_FILE" ]; then
      agent_key_check "$AGENT_KEY_FILE" || kc=$?
      case "$kc" in
        0) k="${AGENT_KEY_FILE}: present, fcp_ prefix OK (value not shown; would be deleted on exit)" ;;
        *) k="${AGENT_KEY_FILE}: MISSING or unreadable" ;;
      esac
    fi
    url=$(agent_server_url)
    plan "agent (XACA-1442): install ${AGENT_SRC##*/} -> ${AGENT_DEST} (root, 755: $([ -f "$AGENT_DEST" ] && echo exists || echo absent)); runs as ROOT (no UserName)"
    plan "  would: write ${AGENT_CFG} (root:wheel 644): serverUrl ${url:-<UNRESOLVED: pass --server-url>}, machine ${HOST}, vmName ${VM_NAME}, linuxSlots ${LINUX_RUNNER_COUNT}, macSlots $([ "$NO_MACOS" = "1" ] && echo 0 || echo 1)"
    plan "  would: key -> ${AGENT_KEY} (root:wheel 600, via stdin, never argv): ${k}"
    plan "  would: guest ${GUEST_JIT_DEST} + ${GUEST_JOB_STARTED_DEST}; $([ "$NO_MACOS" = "1" ] && echo 'macOS JIT scripts SKIPPED (--no-macos)' || echo "host ${MAC_JIT_DEST} + ${MAC_JOB_STARTED_DEST}")"
    plan "  would: write ${PLIST_AGENT} ($([ -f "$PLIST_AGENT" ] && echo exists || echo absent)); daemon $(daemon_state "$LABEL_AGENT"); KeepAlive, state ${AGENT_STATE_DIR}, logs ${AGENT_LOG_DIR}"
    alint=$(mktemp /tmp/ci-runner-dryrun.XXXXXX)
    plist_agent >"$alint"
    if plutil -lint "$alint" >/dev/null; then plan "plist_agent: generated plist passes plutil -lint"; else plan "plist_agent: plist LINT FAILED"; fi
    rm -f "$alint"
  fi
  plan "finish: print status; delete ${TOKEN_FILE:-<token file>}"
}

# ── Provision manifest (XACA-1443-013/-015) ───────────────────────────────
# After a COMPLETE provision, record what was installed from which bundle file (sha256) in a root-owned,
# world-readable manifest next to the pause markers. `aiteamforge ci` (a plain user, no sudo) compares it with
# the keg to tell an enabled host that `brew upgrade` left behind. The format and the comparison live in
# lib/ci-provision-version.sh (one copy, shared with the CLI). A manifest is all-or-nothing: if any entry
# cannot be hashed, none is written (a partial one would hide drift), and the host keeps reading as behind.
_PH_SELF="${BASH_SOURCE[0]:-$0}"
write_provision_manifest() {
  local lib="${_PH_DIR}/lib/ci-provision-version.sh" tmp ok=1 ts
  if [ ! -r "$lib" ]; then
    warn "provision manifest NOT written: ${lib} is missing; 'aiteamforge ci' will keep reporting this host as behind"
    return 0
  fi
  # shellcheck source=/dev/null
  . "$lib"
  ci_provision_entry_reset
  ci_provision_entry step provision-host.sh - "$_PH_SELF" || ok=0
  if [ -f "${_PH_DIR}/create-ci-runner-user.sh" ]; then
    ci_provision_entry step create-ci-runner-user.sh - "${_PH_DIR}/create-ci-runner-user.sh" || ok=0
  fi
  ci_provision_entry libexec client/ci-runner-reporter.sh "$REPORTER_DEST" "$REPORTER_SRC" || ok=0
  if [ "$WITH_AGENT" = "1" ]; then
    ci_provision_entry libexec client/ci-pool-agent.py "$AGENT_DEST" "$AGENT_SRC" || ok=0
    ci_provision_entry guest client/ci-runner-jit-guest.sh "$GUEST_JIT_DEST" "$GUEST_JIT_SRC" || ok=0
    ci_provision_entry guest client/ci-runner-job-started.sh "$GUEST_JOB_STARTED_DEST" "$JOB_STARTED_SRC" || ok=0
    if [ "$NO_MACOS" != "1" ]; then
      ci_provision_entry libexec client/ci-runner-jit-macos.sh "$MAC_JIT_DEST" "$MAC_JIT_SRC" || ok=0
      ci_provision_entry libexec client/ci-runner-job-started.sh "$MAC_JOB_STARTED_DEST" "$JOB_STARTED_SRC" || ok=0
    fi
  fi
  # XACA-1443-014: the staged actions/runner. R lines are part of provision_version; runner_checked_at is not.
  ci_provision_runner_entry linux-arm64 "$VERSION" "$RUNNER_SHA_LINUX" "$RUNNER_SOURCE" || ok=0
  if [ "$NO_MACOS" != "1" ]; then
    ci_provision_runner_entry osx-arm64 "$VERSION" "$RUNNER_SHA_OSX" "$RUNNER_SOURCE" || ok=0
  fi
  CI_PM_RUNNER_CHECKED_AT_W="$RUNNER_CHECKED_AT"
  if [ "$ok" != "1" ]; then
    warn "provision manifest NOT written: a bundle file could not be hashed; 'aiteamforge ci' will keep reporting this host as behind"
    return 0
  fi
  # The dir is shared with the XACA-1440 pause markers, whose writer (ci-host.sh) expects root:admin 0775.
  [ -d "$MANIFEST_DIR" ] || install -d -m 0775 -o root -g admin "$MANIFEST_DIR"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp=$(mktemp /tmp/ci-provision-manifest.XXXXXX)
  if ! ci_provision_manifest_render "$HOST" "$ts" >"$tmp"; then
    command rm -f "$tmp"; warn "provision manifest NOT written (render failed)"; return 0
  fi
  install -m 644 -o root -g wheel "$tmp" "$(ci_provision_manifest_path "$HOST")"
  command rm -f "$tmp"
  log "recorded provision version $(awk -F= '$1=="provision_version"{print $2;exit}' "$(ci_provision_manifest_path "$HOST")") in $(ci_provision_manifest_path "$HOST")"
}

# ── Main ──────────────────────────────────────────────────────────────────
# Test seam: `PROVISION_SOURCE_ONLY=1 source provision-host.sh --host <h>`
# defines the functions/constants without running anything.
if [ "${PROVISION_SOURCE_ONLY:-}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

case "$MODE" in
  status)  do_status; exit $? ;;
  dry-run) do_dry_run; exit 0 ;;
esac

[ "$(uname -s)" = "Darwin" ] || die "macOS only"
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon only"
[ -x "$LIMACTL" ] || die "limactl not found at ${LIMACTL}"
id "$CI_USER" >/dev/null 2>&1 || die "user ${CI_USER} missing; run create-ci-runner-user.sh first"

REGISTER=1
if [ "$MODE" = "baseline-only" ]; then
  REGISTER=0
else
  [ "$(id -u)" -eq 0 ] || die "run under sudo"
  # XACA-1443-015: `ci refresh` re-provisions an ENABLED host. A running pool job must not be disturbed
  # (a changed plist boots the daemon out and back in), so refuse BEFORE anything is touched, and before
  # the key-file trap below is armed (a refused run leaves its key files alone). Same test and the same
  # fail-closed reading as teardown-host.sh: an unreadable slots.json counts as busy.
  if [ "$REFUSE_IF_BUSY" = "1" ] && [ -e "${AGENT_STATE_DIR}/slots.json" ]; then
    _busy=0
    if [ ! -r "${AGENT_STATE_DIR}/slots.json" ]; then _busy=1
    elif grep -Eq '"state": ?"(starting|busy|cleaning)"' "${AGENT_STATE_DIR}/slots.json" 2>/dev/null; then _busy=1; fi
    if [ "$_busy" = "1" ]; then
      echo "provision-host.sh: a pool job is running (or ${AGENT_STATE_DIR}/slots.json is unreadable). Nothing was changed." >&2
      echo "Wait for it to finish, or run without --refuse-if-busy (a changed daemon plist restarts that daemon)." >&2
      exit 3
    fi
  fi
  # Shape of the agent / telemetry key files already enforced (rc 2) at flag
  # validation, before anything ran. Resolve before cd /; delete on ANY exit
  # from here on, like --token-file. A REFUSED file never gets this far.
  case "$AGENT_KEY_FILE" in ''|/*) ;; *) AGENT_KEY_FILE="$(pwd)/${AGENT_KEY_FILE}" ;; esac
  case "$TELEMETRY_KEY_FILE" in ''|/*) ;; *) TELEMETRY_KEY_FILE="$(pwd)/${TELEMETRY_KEY_FILE}" ;; esac
  cleanup_sources() { rm -f "${TOKEN_FILE:-}" ${AGENT_KEY_FILE:+"$AGENT_KEY_FILE"} ${TELEMETRY_KEY_FILE:+"$TELEMETRY_KEY_FILE"}; log "token/key source files removed"; }
  if [ -n "$AGENT_KEY_FILE" ] || [ -n "$TELEMETRY_KEY_FILE" ]; then trap cleanup_sources EXIT; fi
  if [ "$NO_REGISTER" = "1" ]; then
    # XACA-1442 JIT model: nothing is registered, so no token is needed.
    REGISTER=0
    log "--no-register: no runner will be registered; VM, baseline, runner cache, reporter only"
  elif [ -n "$TOKEN_FILE" ]; then
    [ -f "$TOKEN_FILE" ] || die "token file not found: ${TOKEN_FILE}"
    # Resolve before cd / so the path stays valid; delete on ANY exit.
    case "$TOKEN_FILE" in /*) ;; *) TOKEN_FILE="$(pwd)/${TOKEN_FILE}" ;; esac
    # (the agent/telemetry key sources, when given, are deleted by this same trap)
    trap cleanup_sources EXIT
    [ -s "$TOKEN_FILE" ] || die "token file is empty"
  else
    # Converge-only: a token is needed only to register a missing runner.
    # Fail fast on the cases readable without booting the VM; an unregistered
    # Linux runner inside an existing VM fails later with the same advice.
    [ "$NO_MACOS" = "1" ] || [ -f "${MAC_RUNNER_DIR}/.runner" ] || die "${MAC_RUNNER_NAME} is not registered; a registration token is required (--token-file)"
    [ "$(vm_state)" != "absent" ] || die "VM ${VM_NAME} does not exist; a fresh provision needs --token-file"
    log "no --token-file: converging existing runners only (nothing will be registered)"
  fi
fi
# ci-runner may not be able to read the invoker's cwd; limactl/sudo dislike that.
cd /

resolve_runner

# launchd will not create StandardOutPath's directory; the VM daemon needs it first.
if [ "$MODE" != "baseline-only" ]; then as_ci mkdir -p "$LOG_DIR"; fi

stage_vm
stage_vm_running
check_no_host_mounts
stage_guest_baseline
stage_linux_runners "$VERSION" "$REGISTER"
if [ "$MODE" != "baseline-only" ]; then
  stage_macos_runner "$VERSION"
  stage_reporter
  if [ "$WITH_AGENT" = "1" ]; then
    stage_guest_jit
    stage_mac_jit
    stage_agent
  fi
  log "provisioning complete; status:"
  do_status || warn "status reports something not up — see above"
  write_provision_manifest
fi
log "done"
