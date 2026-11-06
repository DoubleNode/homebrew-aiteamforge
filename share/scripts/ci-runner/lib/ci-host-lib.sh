#!/usr/bin/env bash
# shellcheck disable=SC2153
# ci-host-lib.sh - pause / resume / status of a self-hosted CI host (XACA-1440).
#
# SOURCEABLE LIBRARY. Sourcing defines functions and `: "${CIH_X:=default}"`
# defaults only: no output, no `exit`, no change to the caller's `set` options.
# Every function returns the exit-code contract (design section 3) and never
# exits; scripts/ci-runner/ci-host.sh is the thin CLI that turns a return code
# into an exit status plus the final `RESULT:` line.
#
# Design: kanban/plans/XACA-1440/XACA-1440_ci_host_design.md (binding contract).
# Runs ON the CI host as the operator's admin user; privileged steps use
# `sudo -n`. No SSH anywhere.
#
# Portability: /bin/bash 3.2 and bash 5. No associative arrays, no mapfile, no
# ${var,,} (tr instead), no `local -n`, no empty-array expansion under set -u.
#
# Test seams: every external command goes through a CIH_* variable (CIH_GH,
# CIH_SUDO, CIH_LIMACTL, CIH_LAUNCHCTL, CIH_PYTHON, CIH_SLEEP, CIH_DATE,
# CIH_INSTALL, CIH_CURL). CIH_STATE_DIR, CIH_REPO, CIH_KNOWN_HOSTS,
# CIH_POLL_SECS, CIH_PLIST_ROOT and CIH_PROVISION_SCRIPT are overridable.
# With CIH_TEST_MODE=1, cih_require_stubbed refuses to run unless the command
# variables resolve under $CIH_TEST_ROOT (a real gh must never be reached).
#
# Naming: public cih_*, internals _cih_*, globals CIH_* / _CIH_*.
#
# RECYCLE (XACA-1708-004): `recycle` restarts the Lima VM when the host is idle, reusing
# cih_stop_services / cih_start_services (one VM stop/start path, plain `limactl stop`,
# never -f). Its record is the SENTINEL <state-dir>/<host>.recycle.json, the same
# file format family as the pause marker but a separate file (see _CIH_PY_MARKER).
# _CIH_MARKER_KIND (pause|recycle) selects which file the marker helpers address;
# _CIH_RECYCLING=1 makes the stop/start helpers leave the macOS daemon and the launchd
# disable flags alone (the VM job has RunAtLoad only, so a reboot mid-recycle restarts it).
#
# recycle needs NO GitHub access (the scheduled run is root's launchd context, which has no gh
# login): its busy detection is LOCAL (_cih_recycle_idle_check) and its post-start wait is local
# (_cih_wait_units_active). pause/resume/status keep using GitHub exactly as before.

[ -n "${_CIH_LIB_LOADED:-}" ] && return 0
_CIH_LIB_LOADED=1

_CIH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${CIH_GH:=gh}"
: "${CIH_SUDO:=sudo}"
: "${CIH_LIMACTL:=/opt/homebrew/bin/limactl}"
: "${CIH_LAUNCHCTL:=/bin/launchctl}"
: "${CIH_PYTHON:=/usr/bin/python3}"
: "${CIH_SLEEP:=sleep}"
: "${CIH_DATE:=date}"
: "${CIH_INSTALL:=/usr/bin/install}"
: "${CIH_CURL:=curl}"
: "${CIH_PGREP:=pgrep}"   # recycle local busy check (macOS Runner.Worker); never needs GitHub
: "${CIH_PS:=ps}"         # orphaned-sentinel check: is the recorded recycle pid a live ci-host process
: "${CIH_AGENT_STATE_DIR:=/usr/local/var/ci-pool-agent}"   # holds the pool agent slots.json
: "${CIH_PROVISION_SCRIPT:=${_CIH_LIB_DIR}/../provision-host.sh}"
: "${CIH_STATE_DIR:=/usr/local/etc/ci-runner}"
: "${CIH_REPO:=DoubleNode/dev-team}"
: "${CIH_KNOWN_HOSTS:=m1mini m4mini}"
: "${CIH_POLL_SECS:=15}"
: "${CIH_PLIST_ROOT:=}"
: "${CIH_CI_USER:=ci-runner}"
: "${CIH_CI_PATH:=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
: "${CIH_VM_STOP_SECS:=120}"
: "${CIH_DEFAULT_DRAIN_TIMEOUT:=3600}"
: "${CIH_DEFAULT_ONLINE_TIMEOUT:=300}"

# The three routing variables, in marker order.
_CIH_VARS="CI_LINUX_RUNNER_HEAVY CI_LINUX_RUNNER CI_MACOS_RUNNER"

# ---------------------------------------------------------------------------
# Result plumbing
# ---------------------------------------------------------------------------
CIH_RESULT_NAME=""
CIH_RESULT_DETAIL=""

_cih_log()  { printf '[ci-host:%s] %s\n' "${CIH_HOST:-?}" "$*"; }
_cih_warn() { printf '[ci-host:%s] WARN: %s\n' "${CIH_HOST:-?}" "$*" >&2; }
_cih_err()  { printf '[ci-host:%s] ERROR: %s\n' "${CIH_HOST:-?}" "$*" >&2; }

# _cih_fail NAME DETAIL: record the result, print the detail to stderr, return
# the contract number. Use as: `_cih_fail REFUSED "why"; return $?`.
_cih_fail() {
  CIH_RESULT_NAME="$1"
  CIH_RESULT_DETAIL="${2:-}"
  [ -z "$2" ] || _cih_err "$2"
  case "$1" in
    OK|NOOP) return 0 ;;
    INTERNAL) return 1 ;;
    USAGE) return 2 ;;
    REFUSED) return 3 ;;
    DRAIN_TIMEOUT) return 4 ;;
    ENV) return 5 ;;
    GITHUB) return 6 ;;
    LOCAL_SERVICE) return 7 ;;
    ONLINE_TIMEOUT) return 8 ;;
    STATE_CONFLICT) return 9 ;;
    PAUSED) return 10 ;;
    TRANSITIONAL) return 11 ;;
    DEGRADED) return 12 ;;
    BUSY) return 13 ;;
    RECYCLE_PENDING) return 14 ;;
    *) return 1 ;;
  esac
}

_cih_ok() { # NAME DETAIL (OK or NOOP): record, no stderr noise
  CIH_RESULT_NAME="$1"
  CIH_RESULT_DETAIL="${2:-}"
  return 0
}

# Map a numeric rc back to a name (for functions that propagate library rcs).
_cih_name_for_rc() {
  case "$1" in
    0) echo OK ;; 2) echo USAGE ;; 3) echo REFUSED ;; 4) echo DRAIN_TIMEOUT ;;
    5) echo ENV ;; 6) echo GITHUB ;; 7) echo LOCAL_SERVICE ;;
    8) echo ONLINE_TIMEOUT ;; 9) echo STATE_CONFLICT ;; 10) echo PAUSED ;;
    11) echo TRANSITIONAL ;; 12) echo DEGRADED ;; 13) echo BUSY ;;
    14) echo RECYCLE_PENDING ;; *) echo INTERNAL ;;
  esac
}

# Propagate a nested rc: keep a more specific result if one was recorded.
_cih_propagate() { # RC STEP
  if [ -z "$CIH_RESULT_NAME" ] || [ "$CIH_RESULT_NAME" = "OK" ] || [ "$CIH_RESULT_NAME" = "NOOP" ]; then
    CIH_RESULT_NAME="$(_cih_name_for_rc "$1")"
    CIH_RESULT_DETAIL="${2:-step failed} (rc $1)"
  fi
  return "$1"
}

# ---------------------------------------------------------------------------
# Test safety + command wrappers
# ---------------------------------------------------------------------------
cih_require_stubbed() {
  [ "${CIH_TEST_MODE:-}" = "1" ] || return 0
  [ "${_CIH_STUBBED_OK:-}" = "$CIH_TEST_ROOT" ] && return 0   # verified once per process
  [ -n "${CIH_TEST_ROOT:-}" ] || { _cih_err "CIH_TEST_MODE=1 needs CIH_TEST_ROOT"; return 1; }
  local c p
  for c in "$CIH_GH" "$CIH_SUDO" "$CIH_LIMACTL" "$CIH_LAUNCHCTL" "$CIH_INSTALL" "$CIH_CURL"; do
    p="$(command -v "$c" 2>/dev/null || true)"
    case "$p" in
      "$CIH_TEST_ROOT"/*) ;;
      *) _cih_err "test mode: '$c' resolves to '${p:-nothing}', not under $CIH_TEST_ROOT"; return 1 ;;
    esac
  done
  _CIH_STUBBED_OK="$CIH_TEST_ROOT"
  return 0
}

_cih_gh()       { cih_require_stubbed || return 1; "$CIH_GH" "$@"; }
_cih_sudo()     { cih_require_stubbed || return 1; "$CIH_SUDO" "$@"; }
_cih_launchctl() { _cih_sudo -n "$CIH_LAUNCHCTL" "$@"; }
_cih_sleep()    { "$CIH_SLEEP" "$1"; }
# Embedded helpers are stdlib-only, so skip the site import (-S): it costs ~200 ms
# per interpreter start on a machine with a populated site-packages, x ~20 starts
# per pause (XACA-1440-012). Interpreter flags live here, never in $CIH_PYTHON.
_cih_py()       { "$CIH_PYTHON" -S "$@"; }
_cih_now()      { "$CIH_DATE" -u +%Y-%m-%dT%H:%M:%SZ; }

# Run a command as ci-runner with a known PATH (shape copied from provision-host.sh).
_cih_as_ci() { _cih_sudo -n -u "$CIH_CI_USER" -H env PATH="$CIH_CI_PATH" "$@"; }
_cih_limactl() { _cih_as_ci "$CIH_LIMACTL" "$@"; }
_cih_guest()   { _cih_limactl shell --workdir /tmp "$CIH_VM_NAME" -- "$@"; }

# Poll budget from a timeout in seconds. Iteration-counted (not wall clock) so a
# stubbed CIH_SLEEP stays deterministic; a zero poll interval still terminates.
_cih_max_polls() { # TIMEOUT_SECS
  local p="$CIH_POLL_SECS"
  case "$p" in ''|*[!0-9]*) p=15 ;; esac
  [ "$p" -ge 1 ] || p=1
  echo $(( $1 / p + 1 ))
}

# ---------------------------------------------------------------------------
# Embedded python (stdlib only, 3.9-safe). Single-quoted bash strings: the
# python source therefore uses double quotes only.
# ---------------------------------------------------------------------------
_CIH_PY_MARKER='
import sys, os, json
op, path, host = sys.argv[1:4]
kind = "recycle" if path.endswith(".recycle.json") else "pause"
STATES = ("recycling", "error") if kind == "recycle" else ("draining", "paused", "resuming")
def load():
    try:
        with open(path) as f:
            d = json.load(f)
    except FileNotFoundError:
        return None, "absent"
    except Exception:
        return None, "corrupt"
    if (not isinstance(d, dict) or d.get("schema_version") != 1
            or d.get("host") != host
            or d.get("state") not in STATES):
        return d, "corrupt"
    return d, d["state"]
def walk(d, key, create):
    parts = key.split(".")
    for p in parts[:-1]:
        if p not in d or not isinstance(d[p], dict):
            if not create:
                return None, None
            d[p] = {}
        d = d[p]
    return d, parts[-1]
if op == "state":
    print(load()[1])
    sys.exit(0)
if op == "get" or op == "list":
    d, st = load()
    if st in ("absent", "corrupt"):
        sys.exit(4)
    c, k = walk(d, sys.argv[4], False)
    if c is None or k not in c:
        sys.exit(5)
    v = c[k]
    if op == "list":
        if not isinstance(v, list):
            sys.exit(5)
        for i in v:
            print(i)
    else:
        print(v if isinstance(v, str) else json.dumps(v))
    sys.exit(0)
if op == "retire":
    d, st = load()
    if st == "absent":
        sys.exit(0)
    last = os.path.join(os.path.dirname(path), host + "." + kind + ".last.json")
    if len(sys.argv) > 5 and isinstance(d, dict):
        # retire with a note (XACA-1708-013): write the annotated copy to .last.json atomically,
        # then drop the live file. A crash in between leaves the live file = still fail-closed.
        d["retired_by"], d["retired_at"] = sys.argv[4], sys.argv[5]
        tmp = last + ".tmp"
        with open(tmp, "w") as f:
            f.write(json.dumps(d, indent=2) + "\n")
        os.replace(tmp, last)
        os.unlink(path)
        sys.exit(0)
    os.replace(path, last)
    sys.exit(0)
if op == "write":
    now, by = sys.argv[4], sys.argv[5]
    d, st = load()
    if st == "corrupt":
        sys.exit(9)
    if d is None and kind == "recycle":
        d = {"schema_version": 1, "host": host, "state": "recycling", "since": now,
             "updated": now, "by": by, "phase": None, "pid": None,
             "stopped": {"runner_units": [], "macos_daemon": False, "vm": False},
             "launchd_disabled": [], "last_error": None}
    elif d is None:
        d = {"schema_version": 1, "host": host, "state": "draining", "since": now,
             "updated": now, "by": by, "reason": None, "forced": False,
             "redirect_to": None, "saved_vars": {},
             "stopped": {"runner_units": [], "macos_daemon": False, "vm": False},
             "launchd_disabled": [], "last_error": None}
    for a in sys.argv[6:]:
        i = a.index("=")
        k, v, mode = a[:i], a[i + 1:], "s"
        if k.endswith("+"):
            mode, k = "a", k[:-1]
        elif k.endswith(":"):
            mode, k = "j", k[:-1]
        c, last = walk(d, k, True)
        if mode == "j":
            c[last] = json.loads(v)
        elif mode == "a":
            lst = c.setdefault(last, [])
            if v not in lst:
                lst.append(v)
        else:
            c[last] = v
    d["updated"] = now
    if d.get("state") not in STATES:
        sys.exit(9)
    tmp = os.path.join(os.path.dirname(path), "." + host + "." + kind + ".json.tmp." + str(os.getpid()))
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2, sort_keys=True)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
    sys.exit(0)
sys.exit(1)
'

_CIH_PY_VALUE='
import sys, json
op = sys.argv[1]
try:
    x = json.loads(sys.argv[2])
except Exception:
    sys.exit(3)
if op == "targets":
    h = sys.argv[3]
    ok = (isinstance(x, list) and h in x) or (isinstance(x, str) and x == h)
    sys.exit(0 if ok else 1)
if op == "host-of":
    known = sys.argv[3].split()
    items = x if isinstance(x, list) else [x]
    for i in items:
        if isinstance(i, str) and i in known:
            print(i)
            sys.exit(0)
    sys.exit(1)
if op == "replace":
    a, b = sys.argv[3], sys.argv[4]
    if isinstance(x, list):
        x = [b if i == a else i for i in x]
    elif x == a:
        x = b
    print(json.dumps(x, separators=(",", ":")))
    sys.exit(0)
sys.exit(1)
'

_CIH_PY_STATUS='
import sys, json
host, marker, vm, units, macos, runners, varlines, drift, online_by, all_out, recycle, hyg = sys.argv[1:13]
rs = []
for line in runners.splitlines():
    p = line.split("\t")
    if len(p) >= 4:
        rs.append({"name": p[1], "status": p[2], "busy": p[3]})
vs = {}
for line in varlines.splitlines():
    p = line.split("\t")
    if len(p) >= 4:
        vs[p[0]] = {"present": p[1] == "1", "value": (p[2] if p[1] == "1" else None),
                    "targets_host": {"0": True, "1": False}.get(p[3], None)}
ob = {}
for kv in online_by.split():
    k, _, v = kv.partition("=")
    ob[k] = int(v)
print(json.dumps({
    "host": host, "marker": marker, "vm": vm, "recycle": recycle,
    "units": [u for u in units.split() if u],
    "macos_daemon": macos, "runners": rs, "vars": vs,
    "drift": [d for d in drift.split("|") if d],
    "pool": {"online_linux_by_host": ob, "all_out_of_rotation": all_out == "1"},
    "hygiene": ("unavailable" if hyg == "unavailable" else json.loads(hyg)),
}, indent=2, sort_keys=True))
'

# XACA-1708-006: advisory CI-host hygiene. Parses ONE `top -l 1 -o mem -stats
# pid,command,user,mem,cmprs` capture (argv[1]) and lists non-CI processes whose
# resident+compressed footprint is >= the threshold. Exit 1 = could not parse (the caller
# reports "unavailable"; a parse failure must never read as clean).
_CIH_PY_HYGIENE='
import sys, re, json
raw, thr_mib, ci_user = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    thr = int(thr_mib) * 1048576
    if thr < 0: raise ValueError
except ValueError:
    sys.exit(1)
UNIT = {"B": 1, "K": 1024, "M": 1048576, "G": 1073741824, "T": 1099511627776}
def size(tok):
    m = re.match(r"^(\d+(?:\.\d+)?)([BKMGT])?[+-]?$", tok)
    if not m: raise ValueError(tok)
    return int(float(m.group(1)) * UNIT[m.group(2) or "B"])
EXCL = re.compile(r"limactl|\blima|qemu|Virtualization|\bvz\b|Runner\.(Listener|Worker)|actions\.runner|ci-runner|^top$")
lines = raw.splitlines()
hdr = None
for i, l in enumerate(lines):
    f = l.split()
    if f[:2] == ["PID", "COMMAND"] and f[-2:] == ["MEM", "CMPRS"]:
        hdr = i
        break
if hdr is None:
    sys.exit(1)
procs, rows = [], 0
for l in lines[hdr + 1:]:
    f = l.split()
    if not f: continue
    if len(f) < 5 or not f[0].isdigit():
        sys.exit(1)
    try:
        mem, cmp_ = size(f[-2]), size(f[-1])
    except ValueError:
        sys.exit(1)
    rows += 1
    user, cmd = f[-3], " ".join(f[1:-3])
    if user == ci_user or EXCL.search(cmd):
        continue
    if mem + cmp_ >= thr:
        procs.append({"command": cmd, "user": user, "memBytes": mem, "compressedBytes": cmp_})
if rows == 0:
    sys.exit(1)
procs.sort(key=lambda p: -(p["memBytes"] + p["compressedBytes"]))
warn = ["%s (%s) holds %.1f GiB resident+compressed on a CI host; quit it or cap its scrollback (runbook: CI-host hygiene)"
        % (p["command"], p["user"], (p["memBytes"] + p["compressedBytes"]) / 1073741824.0) for p in procs]
print(json.dumps({"heavyProcs": procs, "warnings": warn, "thresholdMiB": int(thr_mib)}, separators=(",", ":")))
'

_CIH_PY_HYGIENE_TEXT='
import sys, json
d = json.loads(sys.argv[1])
if not d.get("heavyProcs"):
    print("hygiene: clean (no non-CI process >= %d MiB resident+compressed)" % d["thresholdMiB"])
else:
    print("hygiene: %d heavy non-CI process(es) >= %d MiB resident+compressed" % (len(d["heavyProcs"]), d["thresholdMiB"]))
    for w in d["warnings"]: print("hygiene: WARN " + w)
'

# Echo the hygiene JSON, or the literal word unavailable. Always rc 0 (advisory).
_cih_hygiene() {
  local raw top thr
  top="${CIH_TOP:-top}"
  if [ "${CIH_TEST_MODE:-}" = "1" ]; then
    case "$(command -v "$top" 2>/dev/null || true)" in "${CIH_TEST_ROOT:-/nonexistent}"/*) ;; *) echo unavailable; return 0 ;; esac
  fi
  thr="${CIH_HYGIENE_THRESHOLD_MIB:-1024}"
  raw="$("$top" -l 1 -o mem -stats pid,command,user,mem,cmprs 2>/dev/null)" || { echo unavailable; return 0; }
  _cih_py -c "$_CIH_PY_HYGIENE" "$raw" "$thr" "$CIH_CI_USER" 2>/dev/null || echo unavailable
  return 0
}

_CIH_PY_PUBLISH='
import sys, json
print(json.dumps({"paused": sys.argv[1] == "true", "reason": sys.argv[2]}))
'

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
cih_normalize_host() { # RAW -> prints normalized host; rc 2 when unusable
  local h k known=0
  h="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$h" in
    '') _cih_fail USAGE "--host <name> is required"; return $? ;;
    [!a-z0-9]*|*[!a-z0-9-]*|*-) _cih_fail USAGE "--host must match [a-z0-9]([a-z0-9-]*[a-z0-9])?, got '$1'"; return $? ;;
  esac
  for k in $CIH_KNOWN_HOSTS; do [ "$k" = "$h" ] && known=1; done
  [ "$known" = "1" ] || { _cih_fail USAGE "unknown host '$h' (known: $CIH_KNOWN_HOSTS)"; return $?; }
  printf '%s\n' "$h"
}

# Sets CIH_VM_NAME CIH_LABEL_VM CIH_LABEL_MAC CIH_PLIST_VM CIH_PLIST_MAC CIH_HAS_MACOS.
# Names come from provision-host.sh through its PROVISION_SOURCE_ONLY seam, in a
# subshell (it sets -euo pipefail and parses "$@" at top level).
cih_load_names() { # HOST
  local h="$1" legacy="" out
  [ "$h" != "m1mini" ] || legacy="--legacy-names"
  [ -f "$CIH_PROVISION_SCRIPT" ] || { _cih_fail ENV "provision script not found: $CIH_PROVISION_SCRIPT"; return $?; }
  # shellcheck disable=SC2086,SC2034,SC1090
  out="$( ( PROVISION_SOURCE_ONLY=1; . "$CIH_PROVISION_SCRIPT" --host "$h" $legacy >/dev/null 2>&1
            printf '%s\n' "$VM_NAME" "$LABEL_VM" "$LABEL_MAC" "$PLIST_VM" "$PLIST_MAC" ) 2>/dev/null )" || out=""
  {
    IFS= read -r CIH_VM_NAME
    IFS= read -r CIH_LABEL_VM
    IFS= read -r CIH_LABEL_MAC
    IFS= read -r CIH_PLIST_VM
    IFS= read -r CIH_PLIST_MAC
  } <<EOF
$out
EOF
  if [ -z "$CIH_VM_NAME" ] || [ -z "$CIH_LABEL_VM" ] || [ -z "$CIH_PLIST_VM" ]; then
    _cih_fail ENV "could not derive names for host '$h' from $CIH_PROVISION_SCRIPT"; return $?
  fi
  CIH_PLIST_VM="${CIH_PLIST_ROOT}${CIH_PLIST_VM}"
  CIH_PLIST_MAC="${CIH_PLIST_ROOT}${CIH_PLIST_MAC}"
  CIH_HAS_MACOS=0
  [ ! -f "$CIH_PLIST_MAC" ] || CIH_HAS_MACOS=1
  return 0
}

cih_host_provisioned_here() { [ -f "${CIH_PLIST_VM:-/nonexistent}" ]; }

# cih_preflight [--no-github]: local checks first (rc 5), then one runners read (rc 6).
cih_preflight() {
  cih_require_stubbed || { _cih_fail ENV "test-mode stub guard refused"; return $?; }
  command -v "$CIH_PYTHON" >/dev/null 2>&1 || { _cih_fail ENV "python3 not found ($CIH_PYTHON)"; return $?; }
  if ! cih_host_provisioned_here; then
    _cih_fail ENV "host '$CIH_HOST' is not provisioned on this machine (missing ${CIH_PLIST_VM}); run this tool ON the CI host"; return $?
  fi
  command -v "$CIH_LIMACTL" >/dev/null 2>&1 || [ -x "$CIH_LIMACTL" ] || { _cih_fail ENV "limactl not found ($CIH_LIMACTL)"; return $?; }
  if [ -t 0 ]; then _cih_sudo -v 2>/dev/null || true; fi
  _cih_sudo -n true >/dev/null 2>&1 || { _cih_fail ENV "passwordless 'sudo -n' unavailable (run 'sudo -v' first)"; return $?; }
  command -v "$CIH_GH" >/dev/null 2>&1 || [ "${1:-}" = "--no-github" ] || { _cih_fail ENV "gh not found ($CIH_GH)"; return $?; }
  [ "${1:-}" != "--no-github" ] || return 0
  local out rc
  out="$(cih_host_runners "$CIH_HOST")"; rc=$?
  [ "$rc" = "0" ] || return "$rc"
  return 0
}

# ---------------------------------------------------------------------------
# GitHub reads and writes
# ---------------------------------------------------------------------------
# TSV: id <TAB> name <TAB> status <TAB> busy(true|false|null) <TAB> labels(comma)
cih_gh_runners() {
  local out rc line
  out="$(_cih_gh api --paginate "repos/${CIH_REPO}/actions/runners?per_page=100" \
    --jq '.runners[] | [.id, .name, .status, (if .busy == true then "true" elif .busy == false then "false" else "null" end), ([.labels[].name]|join(","))] | @tsv' 2>/dev/null)"; rc=$?
  if [ "$rc" != "0" ]; then
    _cih_fail GITHUB "gh runners API call failed (rc $rc): not authenticated, not repo-admin, or network down"; return $?
  fi
  # Every line must be exactly 5 tab fields with a numeric id, else unclassifiable.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      [0-9]*"	"*"	"*"	"*"	"*) ;;
      *) _cih_fail GITHUB "unclassifiable runners response line: '$line'"; return $? ;;
    esac
  done <<EOF
$out
EOF
  [ -z "$out" ] || printf '%s\n' "$out"
  return 0
}

# Runners of HOST, possibly none. rc 6 on API failure or identity conflict.
_cih_host_runners_raw() { # HOST
  local h="$1" all rc id name status busy labels re
  all="$(cih_gh_runners)"; rc=$?
  [ "$rc" = "0" ] || return "$rc"
  re="^${h}-(linux|macos)-[0-9]+\$"
  while IFS="	" read -r id name status busy labels; do
    [ -n "$id" ] || continue
    local nm=0 lb=0
    [[ $name =~ $re ]] && nm=1
    case ",${labels}," in *",${h},"*) lb=1 ;; esac
    if [ "$nm" != "$lb" ]; then
      _cih_fail GITHUB "runner identity conflict: '$name' (labels: ${labels}) matches host '$h' by only one of name/label"; return $?
    fi
    [ "$nm" = "1" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$status" "$busy" "$labels"
  done <<EOF
$all
EOF
  return 0
}

# Runners of HOST; zero runners for a host provisioned here is unclassifiable (rc 6).
cih_host_runners() { # HOST
  local out rc
  out="$(_cih_host_runners_raw "$1")"; rc=$?
  [ "$rc" = "0" ] || return "$rc"
  if [ -z "$out" ]; then
    _cih_fail GITHUB "GitHub lists zero runners for host '$1' (never read as drained)"; return $?
  fi
  printf '%s\n' "$out"
}

# 0 all idle, 10 at least one busy, 6 unknown (literal 'false' from a successful call only).
cih_runners_idle() { # HOST
  local out rc id name status busy labels busyany=0 unknown=0
  out="$(cih_host_runners "$1")"; rc=$?
  [ "$rc" = "0" ] || return "$rc"
  while IFS="	" read -r id name status busy labels; do
    [ -n "$id" ] || continue
    case "$busy" in
      false) ;;
      true) busyany=1 ;;
      *) unknown=1 ;;
    esac
  done <<EOF
$out
EOF
  if [ "$unknown" = "1" ]; then _cih_fail GITHUB "a runner's busy flag is not literally true/false (unclassifiable)"; return $?; fi
  [ "$busyany" = "0" ] || return 10
  return 0
}

# Single runner's state by name: prints idle|busy; rc 6 when unknown.
_cih_runner_busy_state() { # HOST RUNNER
  local out rc id name status busy labels
  out="$(cih_host_runners "$1")"; rc=$?
  [ "$rc" = "0" ] || return "$rc"
  while IFS="	" read -r id name status busy labels; do
    [ "$name" = "$2" ] || continue
    case "$busy" in
      false) echo idle; return 0 ;;
      true) echo busy; return 0 ;;
      *) _cih_fail GITHUB "runner '$2' busy flag unclassifiable ('$busy')"; return $? ;;
    esac
  done <<EOF
$out
EOF
  _cih_fail GITHUB "runner '$2' not found in the runners API"; return $?
}

# Count of online runners for HOST (prints a number). Zero runners is 0, not an error.
_cih_online_count() { # HOST
  local out rc id name status busy labels n=0
  out="$(_cih_host_runners_raw "$1")"; rc=$?
  [ "$rc" = "0" ] || return "$rc"
  while IFS="	" read -r id name status busy labels; do
    [ -n "$id" ] || continue
    [ "$status" != "online" ] || n=$((n + 1))
  done <<EOF
$out
EOF
  echo "$n"
}

# Prints the number of not-yet-started jobs labelled HOST, across EVERY run that
# is not completed (XACA-1440-013). A job pinned to H waits as queued/waiting/
# pending/requested, and its run can be queued OR in_progress (a multi-job run
# whose first job is running while a later job waits for H): scanning only
# status=queued runs misses that, and the drain would call H drained while work
# is still waiting for it. Bounded cost: one paginated runs listing per non-
# completed status (5), then one paginated jobs listing per returned run.
# Fail-closed: any API error, non-numeric run id, or jq failure on an
# unclassifiable body is rc 6, never a "zero pinned".
cih_queued_pinned() { # HOST
  local h="$1" st runs rc rid jobs n=0 c
  for st in in_progress queued waiting pending requested; do
    runs="$(_cih_gh api --paginate "repos/${CIH_REPO}/actions/runs?status=${st}&per_page=100" --jq '.workflow_runs[].id' 2>/dev/null)"; rc=$?
    if [ "$rc" != "0" ]; then _cih_fail GITHUB "${st}-runs API call failed or was unclassifiable (rc $rc)"; return $?; fi
    while IFS= read -r rid; do
      [ -n "$rid" ] || continue
      case "$rid" in *[!0-9]*) _cih_fail GITHUB "unclassifiable run id '$rid'"; return $? ;; esac
      jobs="$(_cih_gh api --paginate "repos/${CIH_REPO}/actions/runs/${rid}/jobs?per_page=100" \
        --jq '.jobs[] | select(.status=="queued" or .status=="waiting" or .status=="pending" or .status=="requested") | select(any(.labels[]; .=="'"$h"'")) | .id' 2>/dev/null)"; rc=$?
      if [ "$rc" != "0" ]; then _cih_fail GITHUB "run $rid jobs API call failed or was unclassifiable (rc $rc)"; return $?; fi
      c="$(printf '%s' "$jobs" | grep -c '[0-9]')" || true
      n=$((n + ${c:-0}))
    done <<EOF
$runs
EOF
  done
  echo "$n"
}

# cih_var_get NAME: 0 present (value on stdout), 1 absent, 6 anything else.
# Absence is decided only by gh's exact "variable NAME was not found" message.
cih_var_get() {
  local name="$1" errf out rc err
  errf="$(mktemp "${TMPDIR:-/tmp}/cih-err.XXXXXX")" || { _cih_fail ENV "mktemp failed"; return $?; }
  out="$(_cih_gh variable get "$name" --repo "$CIH_REPO" 2>"$errf")"; rc=$?
  err="$(cat "$errf" 2>/dev/null)"; rm -f "$errf"
  [ "$rc" != "0" ] || { printf '%s\n' "$out"; return 0; }
  case "$err" in
    *"variable ${name} was not found"*) return 1 ;;
  esac
  _cih_fail GITHUB "gh variable get $name failed (rc $rc): ${err:-no stderr}"; return $?
}

cih_var_set() { # NAME VALUE
  local rc
  _cih_gh variable set "$1" --repo "$CIH_REPO" --body "$2" >/dev/null 2>&1; rc=$?
  [ "$rc" = "0" ] || { _cih_fail GITHUB "gh variable set $1 failed (rc $rc)"; return $?; }
}

cih_var_delete() { # NAME
  local rc
  _cih_gh variable delete "$1" --repo "$CIH_REPO" >/dev/null 2>&1; rc=$?
  [ "$rc" = "0" ] || { _cih_fail GITHUB "gh variable delete $1 failed (rc $rc)"; return $?; }
}

# 0 targets HOST, 1 does not, 3 malformed JSON.
cih_value_targets_host() { # VALUE HOST
  _cih_py -c "$_CIH_PY_VALUE" targets "$1" "$2"
}

# Prints the known host a value points at (first match); rc 1 none, 3 malformed.
_cih_value_host() { _cih_py -c "$_CIH_PY_VALUE" host-of "$1" "$CIH_KNOWN_HOSTS"; }

# ---------------------------------------------------------------------------
# Marker (state file + lock)
# ---------------------------------------------------------------------------
# KIND pause (default) = operator pause marker; recycle = the recycle sentinel (XACA-1708-004).
cih_marker_path() { printf '%s/%s.%s.json\n' "$CIH_STATE_DIR" "$1" "${_CIH_MARKER_KIND:-pause}"; }
cih_sentinel_path() { printf '%s/%s.recycle.json\n' "$CIH_STATE_DIR" "$1"; }

_cih_marker_py() { # OP HOST [args...]
  local op="$1" h="$2"; shift 2
  _cih_py -c "$_CIH_PY_MARKER" "$op" "$(cih_marker_path "$h")" "$h" "$@"
}

cih_marker_state() { _cih_marker_py state "$1"; } # absent|draining|paused|resuming|corrupt
cih_marker_get()   { _cih_marker_py get "$1" "$2"; }
cih_marker_list()  { _cih_marker_py list "$1" "$2"; }

# cih_marker_write HOST key=val | key:=json | key+=val ...  (atomic tmp+rename)
cih_marker_write() {
  local h="$1" rc; shift
  _cih_marker_py write "$h" "$(_cih_now)" "$(id -un)" "$@"; rc=$?
  [ "$rc" = "0" ] || { _cih_fail "$([ "$rc" = 9 ] && echo STATE_CONFLICT || echo INTERNAL)" "marker write failed for $h (rc $rc)"; return $?; }
}

cih_marker_retire() { # HOST [NOTE]  (NOTE is recorded as retired_by in the .last.json copy)
  if [ -n "${2:-}" ]; then _cih_marker_py retire "$1" "$2" "$(_cih_now)"; else _cih_marker_py retire "$1"; fi
}

# Best-effort last_error update; never changes the caller's result.
_cih_marker_err() { # HOST RC STEP DETAIL
  local d
  # shellcheck disable=SC1003
  d="$(printf '{"rc":%s,"step":"%s","detail":"%s"}' "$2" "$3" "$(printf '%s' "$4" | tr -d '"\\' | tr '\n' ' ')")"
  _cih_marker_py write "$1" "$(_cih_now)" "$(id -un)" "last_error:=$d" >/dev/null 2>&1 || true
}

_cih_ensure_state_dir() {
  if [ -d "$CIH_STATE_DIR" ]; then
    [ -w "$CIH_STATE_DIR" ] || { _cih_fail ENV "state dir $CIH_STATE_DIR is not writable by $(id -un) (expected root:admin 0775)"; return $?; }
    return 0
  fi
  _cih_sudo -n "$CIH_INSTALL" -d -o root -g admin -m 0775 "$CIH_STATE_DIR" >/dev/null 2>&1 \
    || { _cih_fail ENV "cannot create $CIH_STATE_DIR via 'sudo -n install -d -o root -g admin -m 0775'"; return $?; }
}

# mkdir lock holding a pid file. Stale (dead pid) is taken over with a warning.
cih_lock_acquire() { # HOST
  local h="$1" lock pid
  _cih_ensure_state_dir || return $?
  lock="$CIH_STATE_DIR/.${h}.lock"
  if mkdir "$lock" 2>/dev/null; then
    echo $$ >"$lock/pid"; return 0
  fi
  pid="$(cat "$lock/pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    _cih_fail STATE_CONFLICT "another ci-host operation holds the lock for '$h' (pid $pid)"; return $?
  fi
  _cih_warn "taking over stale lock for '$h' (pid ${pid:-unknown} not running)"
  rm -rf "$lock"
  if mkdir "$lock" 2>/dev/null; then echo $$ >"$lock/pid"; return 0; fi
  _cih_fail STATE_CONFLICT "could not take over the lock for '$h'"; return $?
}

cih_lock_release() { # HOST
  local lock="$CIH_STATE_DIR/.${1}.lock" pid
  pid="$(cat "$lock/pid" 2>/dev/null || true)"
  [ "$pid" = "$$" ] && rm -rf "$lock"
  return 0
}

# ---------------------------------------------------------------------------
# Option parsing (shared by the cih_cmd_* entry points)
# ---------------------------------------------------------------------------
_cih_parse_opts() { # CMD args...
  local cmd="$1"; shift
  CIH_HOST=""; CIH_OPT_REASON=""; CIH_OPT_DRAIN_TIMEOUT="$CIH_DEFAULT_DRAIN_TIMEOUT"
  CIH_OPT_ONLINE_TIMEOUT="$CIH_DEFAULT_ONLINE_TIMEOUT"; CIH_OPT_REDIRECT=""
  CIH_OPT_FORCE=0; CIH_OPT_DRYRUN=0; CIH_OPT_JSON=0
  CIH_OPT_MIN_UPTIME=""; CIH_OPT_IFIDLE=0; CIH_OPT_RECOVER=0
  local raw_host=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) [ $# -ge 2 ] || { _cih_fail USAGE "--host needs a value"; return $?; }; raw_host="$2"; shift 2 ;;
      --reason) [ "$cmd" = pause ] && [ $# -ge 2 ] || { _cih_fail USAGE "--reason is pause-only and needs a value"; return $?; }; CIH_OPT_REASON="$2"; shift 2 ;;
      --drain-timeout) [ "$cmd" = pause ] && [ $# -ge 2 ] || { _cih_fail USAGE "--drain-timeout is pause-only and needs a value"; return $?; }; CIH_OPT_DRAIN_TIMEOUT="$2"; shift 2 ;;
      --online-timeout) { [ "$cmd" = resume ] || [ "$cmd" = recycle ]; } && [ $# -ge 2 ] || { _cih_fail USAGE "--online-timeout is resume/recycle-only and needs a value"; return $?; }; CIH_OPT_ONLINE_TIMEOUT="$2"; shift 2 ;;
      --min-uptime) [ "$cmd" = recycle ] && [ $# -ge 2 ] || { _cih_fail USAGE "--min-uptime is recycle-only and needs a value (seconds)"; return $?; }; CIH_OPT_MIN_UPTIME="$2"; shift 2 ;;
      --if-idle) [ "$cmd" = recycle ] || { _cih_fail USAGE "--if-idle is recycle-only"; return $?; }; CIH_OPT_IFIDLE=1; shift ;;
      --recover) [ "$cmd" = recycle ] || { _cih_fail USAGE "--recover is recycle-only"; return $?; }; CIH_OPT_RECOVER=1; shift ;;
      --redirect-to) [ "$cmd" = pause ] && [ $# -ge 2 ] || { _cih_fail USAGE "--redirect-to is pause-only and needs a host"; return $?; }; CIH_OPT_REDIRECT="$2"; shift 2 ;;
      --force) [ "$cmd" = pause ] || { _cih_fail USAGE "--force is pause-only"; return $?; }; CIH_OPT_FORCE=1; shift ;;
      --dry-run) [ "$cmd" != status ] || { _cih_fail USAGE "--dry-run is not valid for status"; return $?; }; CIH_OPT_DRYRUN=1; shift ;;
      --json) [ "$cmd" = status ] || { _cih_fail USAGE "--json is status-only"; return $?; }; CIH_OPT_JSON=1; shift ;;
      *) _cih_fail USAGE "unknown argument '$1' for $cmd"; return $? ;;
    esac
  done
  CIH_HOST="$(cih_normalize_host "$raw_host")" || {
    CIH_HOST="${raw_host:-}"; CIH_RESULT_NAME=USAGE; CIH_RESULT_DETAIL="missing, malformed or unknown --host '${raw_host}'"; return 2
  }
  case "$CIH_OPT_DRAIN_TIMEOUT$CIH_OPT_ONLINE_TIMEOUT" in
    ''|*[!0-9]*) _cih_fail USAGE "timeouts must be non-negative integers (seconds)"; return $? ;;
  esac
  case "$CIH_OPT_MIN_UPTIME" in
    *[!0-9]*) _cih_fail USAGE "--min-uptime must be a non-negative integer (seconds)"; return $? ;;
  esac
  if [ "$CIH_OPT_RECOVER" = "1" ] && { [ -n "$CIH_OPT_MIN_UPTIME" ] || [ "$CIH_OPT_IFIDLE" = "1" ]; }; then
    _cih_fail USAGE "--recover takes no policy flags (--min-uptime/--if-idle)"; return $?
  fi
  # The drain needs two consecutive clean polls, so a budget shorter than two poll
  # intervals can never succeed except by luck of the loop arithmetic: reject it
  # up front instead of reporting a misleading DRAIN_TIMEOUT. Poll 0 (tests) is exempt.
  if [ "$cmd" = pause ]; then
    local pp="$CIH_POLL_SECS"
    case "$pp" in ''|*[!0-9]*) pp=15 ;; esac
    if [ "$pp" -gt 0 ] && [ "$CIH_OPT_DRAIN_TIMEOUT" -lt $((pp * 2)) ]; then
      _cih_fail USAGE "--drain-timeout $CIH_OPT_DRAIN_TIMEOUT is shorter than two poll intervals ($((pp * 2))s at CIH_POLL_SECS=$pp); the drain needs two consecutive clean polls"; return $?
    fi
  fi
  if [ -n "$CIH_OPT_REDIRECT" ]; then
    local r k known=0
    r="$(printf '%s' "$CIH_OPT_REDIRECT" | tr '[:upper:]' '[:lower:]')"
    for k in $CIH_KNOWN_HOSTS; do [ "$k" = "$r" ] && known=1; done
    [ "$known" = "1" ] || { _cih_fail USAGE "--redirect-to '$CIH_OPT_REDIRECT' is not a known host ($CIH_KNOWN_HOSTS)"; return $?; }
    [ "$r" != "$CIH_HOST" ] || { _cih_fail USAGE "--redirect-to cannot be the host being paused"; return $?; }
    CIH_OPT_REDIRECT="$r"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Routing: plan, apply, restore (XACA-1440-002)
# ---------------------------------------------------------------------------
_cih_short() { # VARNAME -> HEAVY|BASE|MAC
  case "$1" in
    CI_LINUX_RUNNER_HEAVY) echo HEAVY ;;
    CI_LINUX_RUNNER) echo BASE ;;
    CI_MACOS_RUNNER) echo MAC ;;
  esac
}

# Reads all three variables into _CIH_PRES_* / _CIH_VAL_* / _CIH_TGT_* (1 present, 0 absent;
# target 0 yes / 1 no / 2 absent). A malformed present value refuses (rc 3). rc 6 on read error.
_cih_read_vars() {
  local v s val rc t
  for v in $_CIH_VARS; do
    s="$(_cih_short "$v")"
    val="$(cih_var_get "$v")"; rc=$?
    case "$rc" in
      0) printf -v "_CIH_PRES_$s" '%s' 1; printf -v "_CIH_VAL_$s" '%s' "$val"
         cih_value_targets_host "$val" "$CIH_HOST"; t=$?
         if [ "$t" = "3" ]; then _cih_fail REFUSED "$v holds malformed JSON ('$val'); fix it first (it already breaks CI routing)"; return $?; fi
         printf -v "_CIH_TGT_$s" '%s' "$t" ;;
      1) printf -v "_CIH_PRES_$s" '%s' 0; printf -v "_CIH_VAL_$s" '%s' ""; printf -v "_CIH_TGT_$s" '%s' 2 ;;
      *) return "$rc" ;;
    esac
  done
  return 0
}

# cih_plan_reroute: rules R1 to R3. Reads the variables, sets the plan globals
#   _CIH_ACT_<S> (none|delete|set), _CIH_NEW_<S>, _CIH_PLAN_FORCED (true|false)
# and returns 0, or 3 (refused, nothing changed) / 6. Pure with respect to GitHub
# writes: it makes none. (Design lists a stdout plan; globals are used because
# bash cannot return both an rc and a populated environment from $(...).)
cih_plan_reroute() {
  _CIH_ACT_HEAVY=none; _CIH_ACT_BASE=none; _CIH_ACT_MAC=none
  _CIH_NEW_HEAVY=""; _CIH_NEW_BASE=""; _CIH_NEW_MAC=""
  _CIH_PLAN_FORCED=false
  _cih_read_vars || return $?
  local macref=0 base_targets="$_CIH_TGT_BASE" base_val="$_CIH_VAL_BASE" base_pres="$_CIH_PRES_BASE"
  [ "$_CIH_TGT_MAC" = "0" ] && [ "$CIH_HAS_MACOS" = "1" ] && macref=1

  # R1: the base Linux / macOS variables target H.
  if [ "$_CIH_TGT_BASE" = "0" ] || [ "$macref" = "1" ]; then
    if [ -n "$CIH_OPT_REDIRECT" ] && [ "$_CIH_TGT_BASE" = "0" ] && [ "$macref" = "0" ]; then
      local oc rc
      oc="$(_cih_online_count "$CIH_OPT_REDIRECT")"; rc=$?
      [ "$rc" = "0" ] || return "$rc"
      if [ "${oc:-0}" -lt 1 ]; then
        _cih_fail REFUSED "--redirect-to $CIH_OPT_REDIRECT: that host has no online runner, redirecting would strand CI"; return $?
      fi
      _CIH_NEW_BASE="$(_cih_py -c "$_CIH_PY_VALUE" replace "$_CIH_VAL_BASE" "$CIH_HOST" "$CIH_OPT_REDIRECT")" \
        || { _cih_fail REFUSED "cannot rewrite CI_LINUX_RUNNER for --redirect-to"; return $?; }
      _CIH_ACT_BASE="set"
      base_targets=1; base_val="$_CIH_NEW_BASE"
    elif [ "$CIH_OPT_FORCE" = "1" ]; then
      _CIH_PLAN_FORCED=true
      _cih_warn "R1 forced: CI_LINUX_RUNNER / CI_MACOS_RUNNER left alone; jobs routed to $CIH_HOST will queue until resume"
    else
      _cih_fail REFUSED "$([ "$_CIH_TGT_BASE" = 0 ] && echo CI_LINUX_RUNNER) $([ "$macref" = 1 ] && echo CI_MACOS_RUNNER) target '$CIH_HOST'; pausing would strand that work. Ways forward: --redirect-to <other host> (Linux only, needs an online runner there) or --force (variables untouched, jobs queue until resume)"
      return $?
    fi
  fi

  # R2: HEAVY targets H: save + delete, but only with a live fallback.
  if [ "$_CIH_TGT_HEAVY" = "0" ]; then
    local fb_ok=0 fh oc rc
    if [ "$base_pres" = "1" ] && [ "$base_targets" != "0" ]; then
      fh="$(_cih_value_host "$base_val")"
      if [ -n "$fh" ] && [ "$fh" != "$CIH_HOST" ]; then
        oc="$(_cih_online_count "$fh")"; rc=$?
        [ "$rc" = "0" ] || return "$rc"
        [ "${oc:-0}" -ge 1 ] && fb_ok=1
      fi
    fi
    if [ "$fb_ok" != "1" ]; then
      if [ "$CIH_OPT_FORCE" = "1" ]; then
        _CIH_PLAN_FORCED=true
        _cih_warn "R2 forced: no live fallback runner for CI_LINUX_RUNNER; deleting HEAVY anyway (jobs may fall back to the billing-blocked hosted image)"
      else
        _cih_fail REFUSED "CI_LINUX_RUNNER_HEAVY targets '$CIH_HOST' but CI_LINUX_RUNNER is unset, targets this host, or its host has no online runner; deleting HEAVY would fall back to billing-blocked ubuntu-latest. Use --force to override"
        return $?
      fi
    fi
    _CIH_ACT_HEAVY=delete
  fi
  return 0
}

_cih_print_plan() {
  local v s a n
  for v in $_CIH_VARS; do
    s="$(_cih_short "$v")"
    eval "a=\$_CIH_ACT_$s; n=\$_CIH_NEW_$s"
    case "$a" in
      delete) _cih_log "plan: delete $v (saved first)" ;;
      set) _cih_log "plan: set $v = $n (saved first)" ;;
      *) _cih_log "plan: leave $v alone" ;;
    esac
  done
  [ "$_CIH_PLAN_FORCED" != "true" ] || _cih_log "plan: FORCED (a routing precondition was overridden)"
}

# Marker snapshot ops for the write-ahead record (one atomic write).
_cih_snapshot_write() { # HOST STATE
  local h="$1" st="$2" v s a n pres val touched
  set -- "state=$st" "reason=$CIH_OPT_REASON" "forced:=$_CIH_PLAN_FORCED"
  if [ -n "$CIH_OPT_REDIRECT" ]; then set -- "$@" "redirect_to=$CIH_OPT_REDIRECT"; fi
  for v in $_CIH_VARS; do
    s="$(_cih_short "$v")"
    eval "a=\$_CIH_ACT_$s; n=\$_CIH_NEW_$s; pres=\$_CIH_PRES_$s; val=\$_CIH_VAL_$s"
    touched=false; [ "$a" = "none" ] || touched=true
    set -- "$@" "saved_vars.$v.touched:=$touched"
    if [ "$pres" = "1" ]; then
      set -- "$@" "saved_vars.$v.present:=true" "saved_vars.$v.value=$val"
    else
      set -- "$@" "saved_vars.$v.present:=false" "saved_vars.$v.value:=null"
    fi
    set -- "$@" "saved_vars.$v.planned=$a" "saved_vars.$v.new_value=$n"
    if [ "$touched" = "true" ]; then set -- "$@" "saved_vars.$v.action=pending"; else set -- "$@" "saved_vars.$v.action=none"; fi
  done
  cih_marker_write "$h" "$@"
}

# Verified variable mutation.
_cih_var_do() { # delete|set NAME [VALUE]
  local op="$1" name="$2" val="${3:-}" got rc
  if [ "$op" = "delete" ]; then
    cih_var_delete "$name" || return $?
    cih_var_get "$name" >/dev/null; rc=$?
    [ "$rc" = "1" ] || { [ "$rc" = "6" ] && return 6; _cih_fail GITHUB "verify failed: $name still present after delete"; return $?; }
  else
    cih_var_set "$name" "$val" || return $?
    got="$(cih_var_get "$name")"; rc=$?
    [ "$rc" = "0" ] || { [ "$rc" = "6" ] && return 6; _cih_fail GITHUB "verify failed: $name absent after set"; return $?; }
    [ "$got" = "$val" ] || { _cih_fail GITHUB "verify failed: $name reads back a different value"; return $?; }
  fi
  return 0
}

# cih_apply_reroute HOST: for each touched variable recorded in the marker,
# bring live state to the post-reroute state, idempotently. Live already in the
# post-reroute state is fine; live equal to the saved value is re-applied; any
# other live value is a conflict (rc 9) unless --force.
cih_apply_reroute() { # HOST
  local h="$1" v planned new saved_pres saved_val live rc touched
  for v in $_CIH_VARS; do
    touched="$(cih_marker_get "$h" "saved_vars.$v.touched" 2>/dev/null)"
    [ "$touched" = "true" ] || continue
    planned="$(cih_marker_get "$h" "saved_vars.$v.planned")"
    new="$(cih_marker_get "$h" "saved_vars.$v.new_value" 2>/dev/null)"
    saved_pres="$(cih_marker_get "$h" "saved_vars.$v.present")"
    saved_val="$(cih_marker_get "$h" "saved_vars.$v.value" 2>/dev/null)"
    live="$(cih_var_get "$v")"; rc=$?
    [ "$rc" = "0" ] || [ "$rc" = "1" ] || return "$rc"
    local in_post=0 in_saved=0
    if [ "$planned" = "delete" ]; then [ "$rc" = "1" ] && in_post=1; else [ "$rc" = "0" ] && [ "$live" = "$new" ] && in_post=1; fi
    if [ "$saved_pres" = "true" ]; then [ "$rc" = "0" ] && [ "$live" = "$saved_val" ] && in_saved=1; else [ "$rc" = "1" ] && in_saved=1; fi
    if [ "$in_post" = "1" ]; then
      :
    elif [ "$in_saved" = "1" ] || [ "$CIH_OPT_FORCE" = "1" ]; then
      [ "$in_saved" = "1" ] || _cih_warn "$v changed since the pause was recorded; --force overrides it"
      _cih_log "$planned $v"
      _cih_var_do "$planned" "$v" "$new" || { _cih_marker_err "$h" "$?" reroute "$planned $v failed"; return 6; }
    else
      _cih_fail STATE_CONFLICT "$v was changed by someone else since the pause was recorded (saved vs live mismatch); refusing to guess. Use --force to override"; return $?
    fi
    cih_marker_write "$h" "saved_vars.$v.action=$([ "$planned" = delete ] && echo deleted || echo set)" || return $?
  done
  return 0
}

# ---------------------------------------------------------------------------
# Drain (XACA-1440-003). The T2 reuse point.
# ---------------------------------------------------------------------------
# cih_drain_wait HOST TIMEOUT: 0 drained, 4 timeout, 6 unclassifiable.
# Drained = all H runners idle AND zero queued jobs labelled H, on two
# consecutive polls. Never cancels anything.
cih_drain_wait() { # HOST TIMEOUT
  local h="$1" max i=0 good=0 rc q
  max="$(_cih_max_polls "$2")"
  while :; do
    cih_runners_idle "$h"; rc=$?
    case "$rc" in
      0)
        q="$(cih_queued_pinned "$h")"; rc=$?
        [ "$rc" = "0" ] || return "$rc"
        if [ "${q:-0}" -gt 0 ]; then good=0; _cih_log "drain: $q queued job(s) pinned to $h"; else good=$((good + 1)); fi
        ;;
      10) good=0; _cih_log "drain: $h runner(s) busy" ;;
      *) return "$rc" ;;
    esac
    [ "$good" -lt 2 ] || return 0
    i=$((i + 1))
    if [ "$i" -ge "$max" ]; then
      _cih_fail DRAIN_TIMEOUT "$h still busy or has pinned queued jobs after ${2}s; nothing was stopped (marker stays 'draining'; re-run pause to keep draining, or resume to undo)"; return $?
    fi
    _cih_sleep "$CIH_POLL_SECS"
  done
}

# ---------------------------------------------------------------------------
# Local services (XACA-1440-003 stop, -004 start)
# ---------------------------------------------------------------------------
# Prints Running|Stopped|... as limactl reports; rc 7 when it cannot be read.
cih_vm_state() {
  local out rc
  out="$(_cih_limactl list --format '{{.Status}}' "$CIH_VM_NAME" 2>/dev/null)"; rc=$?
  out="$(printf '%s' "$out" | tr -d '[:space:]')"
  if [ "$rc" != "0" ] || [ -z "$out" ]; then _cih_fail LOCAL_SERVICE "cannot read VM state for '$CIH_VM_NAME' (limactl rc $rc)"; return $?; fi
  printf '%s\n' "$out"
}

# Guest runner units (first column); empty when the VM is not Running. rc 7 on a failed read of a Running VM.
cih_guest_units() { _cih_guest_units_list; }

# Same listing but INCLUDING inactive/failed units (`list-units --all`): the default listing omits
# an inactive unit, so a unit that was stopped (and never came back) is invisible to it. Only
# `not-found` rows (stale references to a removed unit) are dropped; any other load state, notably
# `error`/`bad-setting` (a broken unit file) or `masked`, is KEPT so it fails the is-active health
# check instead of vanishing from it (XACA-1708-018/019: filtering on == "loaded" hid a broken
# runner and let an orphaned sentinel be NOOP-retired while that runner was offline). Used by the recycle health checks and the recycle start
# path, never by the stop path (stopping an already-inactive unit is pointless churn).
cih_guest_units_all() { _cih_guest_units_list --all; }

_cih_guest_units_list() { # [--all]
  local st out rc
  st="$(cih_vm_state)" || return $?
  [ "$st" = "Running" ] || return 0
  if [ "${1:-}" = "--all" ]; then
    out="$(_cih_guest systemctl list-units --all --plain --no-legend 'actions.runner.*' 2>/dev/null)"; rc=$?
  else
    out="$(_cih_guest systemctl list-units --plain --no-legend 'actions.runner.*' 2>/dev/null)"; rc=$?
  fi
  [ "$rc" = "0" ] || { _cih_fail LOCAL_SERVICE "listing guest runner units failed (rc $rc)"; return $?; }
  if [ "${1:-}" = "--all" ]; then
    printf '%s\n' "$out" | awk 'NF && $2 != "not-found" {print $1}'
  else
    printf '%s\n' "$out" | awk 'NF {print $1}'
  fi
}

cih_wait_vm_state() { # STATE SECS
  local want="$1" max i=0 st
  max="$(_cih_max_polls "$2")"
  while :; do
    st="$(cih_vm_state)" || return $?
    [ "$st" != "$want" ] || return 0
    i=$((i + 1))
    [ "$i" -lt "$max" ] || { _cih_fail LOCAL_SERVICE "VM '$CIH_VM_NAME' did not reach $want within ${2}s (now '$st'). Never escalate with limactl stop -f; see runbook section 10"; return $?; }
    _cih_sleep "$CIH_POLL_SECS"
  done
}

_cih_daemon_loaded() { _cih_launchctl print "system/$1" >/dev/null 2>&1; }

# Runner name for a guest unit (runner names are <host>-linux-N inside the unit name).
_cih_unit_runner() { # UNIT -> runner name or empty
  local unit="$1" out rc id name status busy labels
  out="$(cih_host_runners "$CIH_HOST")" || return $?
  while IFS="	" read -r id name status busy labels; do
    case "$unit" in *".${name}."*|*".${name}") echo "$name"; return 0 ;; esac
  done <<EOF
$out
EOF
  return 0
}

# cih_stop_services HOST: units, macOS daemon, VM, then reboot guard. Records every
# step in the marker. rc 10 = a runner became busy again (caller goes back to drain);
# 7 local failure; 6 GitHub.
cih_stop_services() { # HOST
  local h="$1" st units u rn bs rc
  st="$(cih_vm_state)" || { _cih_marker_err "$h" 7 stop-vm "cannot read VM state"; return 7; }
  if [ "$st" = "Running" ]; then
    units="$(cih_guest_units)" || return $?
    # Units recorded by an earlier partial stop are already down; list only live ones.
    for u in $units; do
      if [ "${_CIH_RECYCLING:-}" = "1" ]; then
        # Recycle is GitHub-free: re-check busy LOCALLY before every unit stop (13 -> back out as 10).
        _cih_recycle_idle_check "$h"; rc=$?
        if [ "$rc" = "13" ]; then _cih_log "a CI job appeared; not stopping $u"; return 10; fi
        [ "$rc" = "0" ] || return "$rc"
        rn=""
      else
      rn="$(_cih_unit_runner "$u")" || return $?
      # A unit that maps to no listed runner cannot be proven idle, and stopping it could
      # kill a running job: refuse as GitHub-side unclassifiable (same family as the
      # drain's "runner identity conflict"), never stop an unverifiable guest unit.
      if [ -z "$rn" ]; then _cih_fail GITHUB "guest unit '$u' maps to no runner in the $h runners API; cannot prove it idle, refusing to stop it"; return $?; fi
      bs="$(_cih_runner_busy_state "$h" "$rn")" || return $?
      [ "$bs" = "idle" ] || { _cih_log "runner $rn became busy again; back to draining"; return 10; }
      fi
      _cih_log "stopping guest unit $u"
      # Write-ahead (XACA-1708-017): record the unit BEFORE stopping it. A crash between the stop
      # and a later record would leave a stopped unit that no recovery check can see; recorded-
      # but-still-active is harmless (start skips active units).
      cih_marker_write "$h" "stopped.runner_units+=$u" || return $?
      _cih_guest sudo systemctl stop "$u" >/dev/null 2>&1 || { _cih_marker_err "$h" 7 stop-unit "systemctl stop $u failed"; _cih_fail LOCAL_SERVICE "systemctl stop $u failed"; return $?; }
      if _cih_guest systemctl is-active "$u" >/dev/null 2>&1; then
        _cih_marker_err "$h" 7 stop-unit "$u still active after stop"; _cih_fail LOCAL_SERVICE "$u still active after stop"; return $?
      fi
    done
  fi
  if [ "$CIH_HAS_MACOS" = "1" ] && [ "${_CIH_RECYCLING:-}" != "1" ]; then
    if _cih_daemon_loaded "$CIH_LABEL_MAC"; then
      rn="${CIH_HOST}-macos-1"
      bs="$(_cih_runner_busy_state "$h" "$rn")" || return $?
      [ "$bs" = "idle" ] || { _cih_log "runner $rn became busy again; back to draining"; return 10; }
      _cih_log "booting out $CIH_LABEL_MAC"
      _cih_launchctl bootout "system/$CIH_LABEL_MAC" >/dev/null 2>&1 || { _cih_marker_err "$h" 7 stop-macos "bootout failed"; _cih_fail LOCAL_SERVICE "launchctl bootout $CIH_LABEL_MAC failed"; return $?; }
      if _cih_daemon_loaded "$CIH_LABEL_MAC"; then _cih_fail LOCAL_SERVICE "$CIH_LABEL_MAC still loaded after bootout"; return $?; fi
    fi
    cih_marker_write "$h" "stopped.macos_daemon:=true" || return $?
  fi
  st="$(cih_vm_state)" || return $?
  if [ "$st" = "Running" ]; then
    _cih_log "stopping VM $CIH_VM_NAME (plain stop, never -f)"
    _cih_limactl stop "$CIH_VM_NAME" >/dev/null 2>&1 || { _cih_marker_err "$h" 7 stop-vm "limactl stop failed"; _cih_fail LOCAL_SERVICE "limactl stop $CIH_VM_NAME failed (see runbook section 10; never use stop -f)"; return $?; }
  fi
  cih_wait_vm_state Stopped "$CIH_VM_STOP_SECS" || { _cih_marker_err "$h" 7 stop-vm "VM not Stopped"; return 7; }
  cih_marker_write "$h" "stopped.vm:=true" || return $?
  local l
  # A recycle never disables launchd jobs: the VM job is RunAtLoad-only, so a reboot while
  # the sentinel exists simply restarts the VM (the recovery path then only clears the sentinel).
  [ "${_CIH_RECYCLING:-}" != "1" ] || return 0
  for l in "$CIH_LABEL_VM" $([ "$CIH_HAS_MACOS" = "1" ] && echo "$CIH_LABEL_MAC"); do
    _cih_launchctl disable "system/$l" >/dev/null 2>&1 || { _cih_marker_err "$h" 7 disable "launchctl disable $l failed"; _cih_fail LOCAL_SERVICE "launchctl disable $l failed"; return $?; }
    cih_marker_write "$h" "launchd_disabled+=$l" || return $?
  done
  return 0
}

# cih_start_services HOST: reverse of stop; every piece is skipped when already up.
cih_start_services() { # HOST
  local h="$1" st l u
  for l in $(cih_marker_list "$h" launchd_disabled 2>/dev/null); do
    _cih_launchctl enable "system/$l" >/dev/null 2>&1 || { _cih_fail LOCAL_SERVICE "launchctl enable $l failed"; return $?; }
  done
  st="$(cih_vm_state)" || return $?
  if [ "$st" != "Running" ]; then
    # launchd's disabled flag persists across boots, so after a reboot (or if the job
    # was booted out by hand while paused) the VM daemon is NOT loaded; `enable` does
    # not load it and kickstart on an unloaded job fails "Could not find service"
    # (rc 113). Mirror the macOS daemon: bootstrap when absent (RunAtLoad starts the
    # VM), kickstart -k when still loaded (XACA-1440-014).
    if _cih_daemon_loaded "$CIH_LABEL_VM"; then
      _cih_log "starting VM via launchctl kickstart -k system/$CIH_LABEL_VM"
      _cih_launchctl kickstart -k "system/$CIH_LABEL_VM" >/dev/null 2>&1 || { _cih_fail LOCAL_SERVICE "launchctl kickstart $CIH_LABEL_VM failed"; return $?; }
    else
      _cih_log "bootstrapping $CIH_LABEL_VM (not loaded: rebooted or booted out while paused)"
      _cih_launchctl bootstrap system "$CIH_PLIST_VM" >/dev/null 2>&1 || { _cih_fail LOCAL_SERVICE "launchctl bootstrap $CIH_PLIST_VM failed"; return $?; }
    fi
    cih_wait_vm_state Running "$CIH_VM_STOP_SECS" || return $?
  fi
  local rec all=""
  rec="$(cih_marker_list "$h" stopped.runner_units 2>/dev/null)" || rec=""
  # Recycle recovery also starts any runner unit that is down but was never recorded: every row of
  # the --all listing except not-found, i.e. including error/bad-setting/masked units. Those cannot
  # start, so the recover fails closed into state=error (a human must fix or remove the unit).
  [ "${_CIH_RECYCLING:-}" != "1" ] || all="$(cih_guest_units_all 2>/dev/null)" || all=""
  for u in $(printf '%s\n%s\n' "$rec" "$all" | awk 'NF && !seen[$0]++'); do
    if ! _cih_guest systemctl is-active "$u" >/dev/null 2>&1; then
      _cih_log "starting guest unit $u"
      _cih_guest sudo systemctl start "$u" >/dev/null 2>&1 || { _cih_fail LOCAL_SERVICE "systemctl start $u failed"; return $?; }
      _cih_guest systemctl is-active "$u" >/dev/null 2>&1 || { _cih_fail LOCAL_SERVICE "$u not active after start"; return $?; }
    fi
  done
  if [ "$CIH_HAS_MACOS" = "1" ] && [ "${_CIH_RECYCLING:-}" != "1" ] && ! _cih_daemon_loaded "$CIH_LABEL_MAC"; then
    _cih_log "bootstrapping $CIH_LABEL_MAC"
    _cih_launchctl bootstrap system "$CIH_PLIST_MAC" >/dev/null 2>&1 || { _cih_fail LOCAL_SERVICE "launchctl bootstrap $CIH_PLIST_MAC failed"; return $?; }
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Resume helpers (XACA-1440-004)
# ---------------------------------------------------------------------------
# cih_wait_online HOST TIMEOUT: 0 all H runners online, 8 timeout, 6 unclassifiable.
# Optional 3rd arg "linux": only the host's Linux runners count (recycle leaves macOS alone).
cih_wait_online() { # HOST TIMEOUT [linux]
  local h="$1" max i=0 out rc id name status busy labels all only="${3:-}"
  max="$(_cih_max_polls "$2")"
  while :; do
    out="$(cih_host_runners "$h")"; rc=$?
    [ "$rc" = "0" ] || return "$rc"
    all=1
    while IFS="	" read -r id name status busy labels; do
      [ -n "$id" ] || continue
      [ "$only" != "linux" ] || case "$name" in *-linux-*) ;; *) continue ;; esac
      [ "$status" = "online" ] || all=0
    done <<EOF
$out
EOF
    [ "$all" != "1" ] || return 0
    i=$((i + 1))
    [ "$i" -lt "$max" ] || { _cih_fail ONLINE_TIMEOUT "$h runners not all online within ${2}s; variables NOT restored (marker stays 'resuming'; re-run resume)"; return $?; }
    _cih_sleep "$CIH_POLL_SECS"
  done
}

# cih_restore_vars HOST: for each touched variable. Live in the post-reroute state
# means restore the saved value; live equal to saved means nothing to do; anything
# else was changed on purpose by someone, so keep it, warn and print the saved value.
cih_restore_vars() { # HOST
  local h="$1" v planned new saved_pres saved_val live rc touched
  for v in $_CIH_VARS; do
    touched="$(cih_marker_get "$h" "saved_vars.$v.touched" 2>/dev/null)"
    [ "$touched" = "true" ] || continue
    planned="$(cih_marker_get "$h" "saved_vars.$v.planned")"
    new="$(cih_marker_get "$h" "saved_vars.$v.new_value" 2>/dev/null)"
    saved_pres="$(cih_marker_get "$h" "saved_vars.$v.present")"
    saved_val="$(cih_marker_get "$h" "saved_vars.$v.value" 2>/dev/null)"
    live="$(cih_var_get "$v")"; rc=$?
    [ "$rc" = "0" ] || [ "$rc" = "1" ] || return "$rc"
    local in_post=0 in_saved=0
    if [ "$planned" = "delete" ]; then [ "$rc" = "1" ] && in_post=1; else [ "$rc" = "0" ] && [ "$live" = "$new" ] && in_post=1; fi
    if [ "$saved_pres" = "true" ]; then [ "$rc" = "0" ] && [ "$live" = "$saved_val" ] && in_saved=1; else [ "$rc" = "1" ] && in_saved=1; fi
    if [ "$in_saved" = "1" ]; then
      _cih_log "$v already holds its saved state"
    elif [ "$in_post" = "1" ]; then
      if [ "$saved_pres" = "true" ]; then
        _cih_log "restoring $v"
        _cih_var_do set "$v" "$saved_val" || return $?
      else
        _cih_log "removing $v (it was absent before the pause)"
        _cih_var_do delete "$v" || return $?
      fi
    else
      if [ "$saved_pres" = "true" ]; then
        _cih_warn "$v was changed during the pause; KEEPING the live value. Saved value was: $saved_val"
      else
        _cih_warn "$v was changed during the pause; KEEPING the live value (it was absent before the pause)"
      fi
    fi
  done
  return 0
}

# No-op unless CIH_POOL_API is set (feature-detected; T2 reuse, design section 8).
# A publish failure only warns: the local change already happened.
cih_publish_pause_flag() { # HOST true|false REASON
  [ -n "${CIH_POOL_API:-}" ] || return 0
  local body
  body="$(_cih_py -c "$_CIH_PY_PUBLISH" "$2" "${3:-}")"
  "$CIH_CURL" -fsS -X PUT -H 'Content-Type: application/json' -d "$body" \
    "${CIH_POOL_API%/}/api/ci-pool/machines/$1" >/dev/null 2>&1 \
    || _cih_warn "could not publish the pause flag to $CIH_POOL_API (variables still enforce routing)"
  return 0
}

# ---------------------------------------------------------------------------
# Pool summary
# ---------------------------------------------------------------------------
# Sets _CIH_POOL_ONLINE ("m1mini=2 m4mini=0") and _CIH_POOL_ALL_OUT (1/0).
_cih_pool_compute() {
  local all rc k n online="" outs=0 total=0 ms
  all="$(cih_gh_runners)"; rc=$?
  [ "$rc" = "0" ] || return "$rc"
  for k in $CIH_KNOWN_HOSTS; do
    n="$(printf '%s\n' "$all" | awk -F'\t' -v h="$k" '$2 ~ ("^" h "-linux-[0-9]+$") && $3=="online" {c++} END {print c+0}')"
    online="${online:+$online }$k=$n"
    total=$((total + 1))
    ms="$(_cih_py -c "$_CIH_PY_MARKER" state "$(cih_marker_path "$k")" "$k" 2>/dev/null || echo absent)"
    if [ "$ms" = "paused" ] || [ "$ms" = "draining" ] || [ "$n" = "0" ]; then outs=$((outs + 1)); fi
  done
  _CIH_POOL_ONLINE="$online"
  _CIH_POOL_ALL_OUT=0
  [ "$outs" -lt "$total" ] || _CIH_POOL_ALL_OUT=1
  return 0
}

cih_pool_summary() {
  _cih_pool_compute || return $?
  _cih_log "pool: online Linux runners by host: $_CIH_POOL_ONLINE"
  [ "$_CIH_POOL_ALL_OUT" != "1" ] || _cih_warn "EVERY known host is out of rotation: no CI capacity is available (jobs will queue)"
  return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
_cih_setup_cmd() { # CMD args...  (parse, names, stub guard)
  local cmd="$1"; shift
  CIH_RESULT_NAME=""; CIH_RESULT_DETAIL=""
  _cih_parse_opts "$cmd" "$@" || return $?
  cih_require_stubbed || { _cih_fail ENV "test-mode stub guard refused"; return $?; }
  cih_load_names "$CIH_HOST" || return $?
  return 0
}

# Pause: P1..P10 (design section 4.1).
cih_cmd_pause() {
  _cih_setup_cmd pause "$@" || return $?
  local h="$CIH_HOST" st rc n=0
  cih_preflight || return $?
  if [ "$CIH_OPT_DRYRUN" != "1" ]; then
    cih_lock_acquire "$h" || return $?
  fi
  st="$(cih_marker_state "$h")"
  case "$st" in
    corrupt) _cih_fail STATE_CONFLICT "marker for '$h' is corrupt (fail-closed); inspect $(cih_marker_path "$h")"; return $? ;;
    resuming)
      if [ "$CIH_OPT_FORCE" != "1" ]; then
        _cih_fail STATE_CONFLICT "a resume of '$h' is in progress; finish it with 'resume' or use --force"; return $?
      fi
      _cih_warn "--force: pausing during a resume; continuing from the recorded snapshot"
      [ "$CIH_OPT_DRYRUN" = "1" ] || cih_marker_write "$h" state=draining || return $? ;;
  esac
  case "$st" in
    absent)
      cih_plan_reroute || return $?
      if [ "$CIH_OPT_DRYRUN" = "1" ]; then
        _cih_print_plan
        _cih_log "dry-run: would drain (timeout ${CIH_OPT_DRAIN_TIMEOUT}s), stop units/macOS daemon/VM, mark paused. Nothing changed."
        _cih_ok OK "dry-run"; return 0
      fi
      _cih_snapshot_write "$h" draining || return $?
      cih_apply_reroute "$h" || return $? ;;
    draining|resuming)
      if [ "$CIH_OPT_DRYRUN" = "1" ]; then _cih_log "dry-run: marker is '$st'; would re-verify re-route, drain and stop"; _cih_ok OK "dry-run"; return 0; fi
      cih_marker_write "$h" state=draining || return $?
      cih_apply_reroute "$h" || return $? ;;
    paused)
      if [ "$CIH_OPT_DRYRUN" = "1" ]; then _cih_log "dry-run: marker is 'paused'; would verify reality and repair drift only"; _cih_ok OK "dry-run"; return 0; fi
      if _cih_paused_reality_ok "$h"; then
        _cih_ok NOOP "already paused"; _cih_log "already paused (reality agrees)"; return 0
      fi
      _cih_warn "marker says paused but reality drifted; repairing"
      cih_marker_write "$h" state=draining || return $?
      cih_apply_reroute "$h" || return $? ;;
  esac
  # P8/P9: drain, then stop. A runner going busy again between the two loops back.
  while :; do
    cih_drain_wait "$h" "$CIH_OPT_DRAIN_TIMEOUT"; rc=$?
    if [ "$rc" != "0" ]; then _cih_marker_err "$h" "$rc" drain "${CIH_RESULT_DETAIL:-drain failed}"; return "$rc"; fi
    cih_stop_services "$h"; rc=$?
    case "$rc" in
      0) break ;;
      10) n=$((n + 1))
          [ "$n" -lt 5 ] || { _cih_fail DRAIN_TIMEOUT "runners kept going busy while stopping $h"; return $?; } ;;
      *) return "$rc" ;;
    esac
  done
  cih_marker_write "$h" state=paused last_error:=null || return $?
  cih_publish_pause_flag "$h" true "$CIH_OPT_REASON"
  cih_pool_summary || _cih_warn "pool summary unavailable"
  _cih_ok OK "paused"
  return 0
}

# Paused marker vs live reality: VM down, no H runner online, touched vars in post state.
_cih_paused_reality_ok() { # HOST
  local h="$1" st v touched planned new live rc out id name status busy labels
  st="$(cih_vm_state)" || return 1
  [ "$st" != "Running" ] || return 1
  out="$(cih_host_runners "$h")" || return 1
  while IFS="	" read -r id name status busy labels; do
    [ "$status" != "online" ] || return 1
  done <<EOF
$out
EOF
  for v in $_CIH_VARS; do
    touched="$(cih_marker_get "$h" "saved_vars.$v.touched" 2>/dev/null)"
    [ "$touched" = "true" ] || continue
    planned="$(cih_marker_get "$h" "saved_vars.$v.planned")"
    new="$(cih_marker_get "$h" "saved_vars.$v.new_value" 2>/dev/null)"
    live="$(cih_var_get "$v")"; rc=$?
    if [ "$planned" = "delete" ]; then [ "$rc" = "1" ] || return 1; else { [ "$rc" = "0" ] && [ "$live" = "$new" ]; } || return 1; fi
  done
  return 0
}

# Resume: S1..S6 (design section 4.2).
cih_cmd_resume() {
  _cih_setup_cmd resume "$@" || return $?
  local h="$CIH_HOST" st rc vst
  cih_preflight || return $?
  if [ "$CIH_OPT_DRYRUN" != "1" ]; then
    cih_lock_acquire "$h" || return $?
  fi
  st="$(cih_marker_state "$h")"
  case "$st" in
    corrupt) _cih_fail STATE_CONFLICT "marker for '$h' is corrupt (fail-closed); inspect $(cih_marker_path "$h")"; return $? ;;
    absent)
      vst="$(cih_vm_state 2>/dev/null)" || vst=unknown
      [ "$vst" = "Running" ] || _cih_warn "'$h' is not paused but its VM is '$vst' (down but not paused: an outage, not a pause)"
      _cih_ok NOOP "not paused"; _cih_log "not paused; nothing to do"; return 0 ;;
  esac
  if [ "$CIH_OPT_DRYRUN" = "1" ]; then
    _cih_log "dry-run: marker is '$st'; would start services, wait online (${CIH_OPT_ONLINE_TIMEOUT}s), restore saved variables, retire the marker. Nothing changed."
    _cih_ok OK "dry-run"; return 0
  fi
  cih_marker_write "$h" state=resuming || return $?
  cih_start_services "$h" || { rc=$?; _cih_marker_err "$h" "$rc" start "${CIH_RESULT_DETAIL:-start failed}"; return "$rc"; }
  cih_wait_online "$h" "$CIH_OPT_ONLINE_TIMEOUT" || { rc=$?; _cih_marker_err "$h" "$rc" online "${CIH_RESULT_DETAIL:-online wait failed}"; return "$rc"; }
  cih_restore_vars "$h" || { rc=$?; _cih_marker_err "$h" "$rc" restore "${CIH_RESULT_DETAIL:-restore failed}"; return "$rc"; }
  cih_marker_retire "$h" || { _cih_fail INTERNAL "could not retire the marker"; return $?; }
  # A recycle sentinel left behind by an interrupted recycle is moot once the host resumed.
  [ "$(_cih_recycle_state "$h")" = "absent" ] || _CIH_MARKER_KIND=recycle cih_marker_retire "$h" || true
  cih_publish_pause_flag "$h" false ""
  cih_pool_summary || _cih_warn "pool summary unavailable"
  _cih_ok OK "resumed"
  return 0
}

# ---------------------------------------------------------------------------
# Recycle (XACA-1708-004): restart the Lima VM ONLY when it is safe.
# ---------------------------------------------------------------------------
# Sentinel: $CIH_STATE_DIR/<host>.recycle.json (cih_sentinel_path), schema_version 1:
#   {"schema_version":1,"host":H,"state":"recycling"|"error","phase":"stopping"|"starting"|
#    "recovering","since":ISO,"updated":ISO,"by":USER,"pid":N,
#    "stopped":{...},"launchd_disabled":[],"last_error":null|{"rc","step","detail"}}
# EXISTS from before the first stop until the VM is back and the host's Linux runners are
# online, then is renamed to <host>.recycle.last.json. state=error means the recycle failed
# and needs a human (or `recycle --recover`); the sentinel stays so the pool agent keeps
# refusing to claim jobs. Anything but "absent" means: do not start work on this host.
_cih_recycle_state() { _CIH_MARKER_KIND=recycle cih_marker_state "$1"; } # absent|recycling|error|corrupt

# Guest uptime in whole seconds (prints a number); rc 7 when unreadable.
_cih_vm_uptime() {
  local out
  out="$(_cih_guest cat /proc/uptime 2>/dev/null | awk 'NR==1 {print int($1)}')"
  case "$out" in ''|*[!0-9]*) _cih_fail LOCAL_SERVICE "cannot read VM uptime from the guest (unreadable /proc/uptime)"; return $? ;; esac
  printf '%s\n' "$out"
}

# Marks the sentinel as failed (best effort) and records why; never changes the caller's rc.
_cih_recycle_fail() { # HOST RC STEP
  _CIH_MARKER_KIND=recycle cih_marker_write "$1" state=error >/dev/null 2>&1 || true
  _cih_marker_err "$1" "$2" "$3" "${CIH_RESULT_DETAIL:-failed}"
  _cih_err "recycle failed at '$3'; sentinel $(cih_sentinel_path "$1") left in state=error (no force-stop attempted). Fix the cause, then: ci-host.sh recycle --host $1 --recover"
}

cih_cmd_recycle() {
  _cih_setup_cmd recycle "$@" || return $?
  local rc
  _CIH_MARKER_KIND=recycle
  _cih_recycle_body; rc=$?
  _CIH_MARKER_KIND=pause; _CIH_RECYCLING=""
  return "$rc"
}

_cih_recycle_body() {
  local h="$CIH_HOST" st rst vst rc up
  cih_preflight --no-github || return $?   # recycle never talks to GitHub (root's launchd has no gh login)
  if [ "$CIH_OPT_DRYRUN" != "1" ]; then
    cih_lock_acquire "$h" || return $?
  fi
  # 1. An operator pause (or its transition, or a corrupt marker) always wins: a recycle must
  #    never fight a pause in progress nor resume a host a human paused.
  st="$(_CIH_MARKER_KIND=pause cih_marker_state "$h")"
  [ "$st" = "absent" ] || { _cih_fail STATE_CONFLICT "host '$h' has a pause marker (state '$st'); a recycle never touches a paused/pausing/resuming host"; return $?; }
  # 2. Sentinel: already recycling, or a crashed/failed recycle.
  rst="$(_cih_recycle_state "$h")"
  if [ "$CIH_OPT_RECOVER" = "1" ]; then
    _cih_recycle_recover "$h" "$rst"; return $?
  fi
  case "$rst" in
    absent) ;;
    corrupt) _cih_fail STATE_CONFLICT "recycle sentinel for '$h' is corrupt (fail-closed); inspect $(cih_sentinel_path "$h")"; return $? ;;
    recycling)
      # XACA-1708-013: the SCHEDULED path heals a sentinel orphaned by a crash/reboot.
      if [ "$CIH_OPT_IFIDLE" = "1" ] && [ "$CIH_OPT_DRYRUN" != "1" ] && [ "$(_cih_recycle_pid_state "$h")" = "dead" ]; then
        _cih_recycle_auto_recover "$h"; return $?
      fi
      _cih_fail RECYCLE_PENDING "recycle sentinel present for '$h' (state '$rst'): a recycle is running or was interrupted. Inspect 'ci-host.sh status --host $h'; if no recycle is running use 'recycle --recover'"; return $? ;;
    *) _cih_fail RECYCLE_PENDING "recycle sentinel present for '$h' (state '$rst'): a recycle is running or was interrupted. Inspect 'ci-host.sh status --host $h'; if no recycle is running use 'recycle --recover'"; return $? ;;
  esac
  # 3. The VM must be a healthy Running VM (we restart healthy VMs, we do not start dead ones).
  vst="$(cih_vm_state)" || return $?
  [ "$vst" = "Running" ] || { _cih_fail REFUSED "VM is '$vst', not Running; recycle only restarts a healthy VM (use status / the runbook for an outage)"; return $?; }
  # 4. Policy: minimum uptime. Unreadable uptime is fail-closed, never "old enough".
  if [ -n "$CIH_OPT_MIN_UPTIME" ]; then
    up="$(_cih_vm_uptime)" || return $?
    if [ "$up" -lt "$CIH_OPT_MIN_UPTIME" ]; then
      _cih_ok NOOP "VM uptime ${up}s is below --min-uptime ${CIH_OPT_MIN_UPTIME}s; nothing to do"
      _cih_log "$CIH_RESULT_DETAIL"; return 0
    fi
  fi
  # 5. Idle, decided LOCALLY (guest/host Runner.Worker + pool agent slots.json). See _cih_recycle_idle_check.
  _cih_recycle_idle_check "$h"; rc=$?
  if [ "$rc" = "13" ]; then
    [ "$CIH_OPT_IFIDLE" = "1" ] || return 13
    _cih_ok NOOP "host busy; skipped (--if-idle). ${CIH_RESULT_DETAIL}"; return 0
  elif [ "$rc" != "0" ]; then
    return "$rc"
  fi
  if [ "$CIH_OPT_DRYRUN" = "1" ]; then
    _cih_log "dry-run: host idle, VM Running, no pause marker, no sentinel. Would write $(cih_sentinel_path "$h"), stop the guest runner units and the VM (plain stop, never -f), start the VM and units, wait for the Linux runners online (${CIH_OPT_ONLINE_TIMEOUT}s), then retire the sentinel. Nothing changed."
    _cih_ok OK "dry-run"; return 0
  fi
  _CIH_RECYCLING=1
  # Write-ahead sentinel BEFORE the first stop, then re-check idle (closes the window in which
  # the pool agent claimed a job between our first check and the sentinel becoming visible).
  cih_marker_write "$h" state=recycling phase=stopping "pid:=$$" || return $?
  _cih_recycle_idle_check "$h"; rc=$?
  if [ "$rc" != "0" ]; then
    _cih_log "became busy after the sentinel was written; abandoning the recycle (nothing stopped)"
    cih_marker_retire "$h" || _cih_warn "could not retire the recycle sentinel after backing out; the next scheduled tick will auto-recover it"
    if [ "$rc" = "13" ] && [ "$CIH_OPT_IFIDLE" = "1" ]; then
      # Same outcome as a busy host at the first check (XACA-1708-013): a scheduled tick is a no-op.
      _cih_ok NOOP "host became busy after the sentinel was written; backed out cleanly, sentinel retired (--if-idle). ${CIH_RESULT_DETAIL}"; return 0
    fi
    return "$rc"
  fi
  cih_stop_services "$h"; rc=$?
  if [ "$rc" = "10" ]; then
    # A runner went busy while stopping: bring back whatever was stopped, drop the sentinel.
    _cih_log "runner became busy while stopping; restoring services and abandoning the recycle"
    if cih_start_services "$h"; then
      cih_marker_retire "$h" || _cih_warn "could not retire the recycle sentinel after restoring services; the next scheduled tick will auto-recover it"
      if [ "$CIH_OPT_IFIDLE" = "1" ]; then _cih_ok NOOP "a runner became busy during the recycle; services restored, sentinel retired (--if-idle), nothing lost"; return 0; fi
      _cih_fail BUSY "a runner became busy during the recycle; services restored, nothing lost"; return $?; fi
    _cih_recycle_fail "$h" 7 restore-after-busy; return 7
  elif [ "$rc" != "0" ]; then
    _cih_recycle_fail "$h" "$rc" stop; return "$rc"
  fi
  _cih_recycle_finish "$h" starting
  return $?
}

# Start the VM back, wait for the Linux runners, retire the sentinel. Shared by the normal
# path and --recover (every step is idempotent, see cih_start_services).
_cih_recycle_finish() { # HOST PHASE
  local h="$1" rc
  cih_marker_write "$h" state=recycling "phase=$2" || return $?
  cih_start_services "$h" || { rc=$?; _cih_recycle_fail "$h" "$rc" start; return "$rc"; }
  _cih_wait_units_active "$h" "$CIH_OPT_ONLINE_TIMEOUT" || { rc=$?; _cih_recycle_fail "$h" "$rc" online; return "$rc"; }
  cih_marker_retire "$h" || { _cih_fail INTERNAL "could not retire the recycle sentinel"; return $?; }
  _cih_ok OK "recycled"
  return 0
}

# LOCAL busy detection for recycle (no GitHub, no token: the scheduled run is root's launchd
# context, which has no gh login). Three independent signals; ANY busy => busy (13), and any
# signal that cannot be read => refuse (7), never idle:
#   1. Linux guest: a Runner.Worker process (limactl shell; the exit status is echoed behind a
#      marker so a failed limactl is never mistaken for pgrep's "no match").
#   2. macOS host (only when the host has a macOS lane): Runner.Worker of the CI user.
#   3. Pool agent: any slot in slots.json that is starting/busy/cleaning. File absent = no
#      agent state = no slots; present but unparseable/unknown state = unreadable.
# The pinned-queue check of the pause drain is deliberately NOT done: the sentinel (written
# before the first stop) already makes the pool agent stop claiming, and a job queued for this
# host simply waits the few minutes a restart takes. 0 idle, 13 busy, 7 unreadable.
_CIH_PY_SLOTS='
import json, sys
try:
    with open(sys.argv[1]) as f:
        raw = json.load(f)
except FileNotFoundError:
    print("idle"); sys.exit(0)
except PermissionError:
    sys.exit(4)   # EACCES: the agent state dir is root 0700 (XACA-1708-014); run via sudo
except (OSError, ValueError):
    sys.exit(3)
slots = raw.get("slots") if isinstance(raw, dict) else None
if not isinstance(slots, dict):
    sys.exit(3)
busy = False
for key, e in slots.items():
    st = e.get("state") if isinstance(e, dict) else None
    if st in ("starting", "busy", "cleaning"):
        busy = True
    elif st not in ("idle", "broken"):
        sys.exit(3)
print("busy" if busy else "idle")
'

_cih_recycle_idle_check() { # HOST
  local h="$1" out rc mark busy_what="" unread=""
  # 1. Linux guest
  out="$(_cih_guest sh -c 'pgrep -f "[R]unner[.]Worker" >/dev/null 2>&1; echo "cih-worker-rc=$?"' 2>/dev/null)"; rc=$?
  mark="$(printf '%s\n' "$out" | sed -n 's/^cih-worker-rc=\([0-9]*\)$/\1/p' | tail -n 1)"
  if [ "$rc" != "0" ]; then unread="${unread}guest probe failed (limactl shell rc $rc); "
  else case "$mark" in
    0) busy_what="${busy_what}Runner.Worker running in the VM; " ;;
    1) ;;
    *) unread="${unread}guest probe unreadable (pgrep rc '${mark:-none}'); " ;;
  esac; fi
  # 2. macOS lane
  if [ "$CIH_HAS_MACOS" = "1" ]; then
    if [ "${CIH_TEST_MODE:-}" = "1" ]; then
      case "$(command -v "$CIH_PGREP" 2>/dev/null || true)" in "$CIH_TEST_ROOT"/*) ;; *) _cih_fail ENV "test mode: CIH_PGREP is not stubbed"; return $? ;; esac
    fi
    "$CIH_PGREP" -u "$CIH_CI_USER" -f '[R]unner[.]Worker' >/dev/null 2>&1; rc=$?
    case "$rc" in
      0) busy_what="${busy_what}Runner.Worker running on the macOS lane; " ;;
      1) ;;
      *) unread="${unread}macOS Runner.Worker probe failed (pgrep rc $rc); " ;;
    esac
  fi
  # 3. pool agent slots
  out="$(_cih_py -c "$_CIH_PY_SLOTS" "$CIH_AGENT_STATE_DIR/slots.json" 2>/dev/null)"; rc=$?
  if [ "$rc" = "4" ]; then unread="${unread}pool agent slots.json permission denied (EACCES: $CIH_AGENT_STATE_DIR is root-only; run as root, i.e. 'sudo ci-host.sh recycle ...'); "
  elif [ "$rc" != "0" ]; then unread="${unread}pool agent slots.json unreadable (corrupt or unparseable); "
  else case "$out" in
    idle) ;;
    busy) busy_what="${busy_what}pool agent slot starting/busy/cleaning; " ;;
    *) unread="${unread}pool agent slots.json unclassifiable; " ;;
  esac; fi
  if [ -n "$busy_what" ]; then
    CIH_RESULT_NAME=BUSY; CIH_RESULT_DETAIL="host '$h' is busy (${busy_what%; }); nothing was stopped"; return 13
  fi
  if [ -n "$unread" ]; then _cih_fail LOCAL_SERVICE "cannot prove host '$h' idle: ${unread%; }(fail-closed)"; return $?; fi
  return 0
}

# Wait (local, no GitHub) until the guest runner units are active again: every unit the recycle
# stopped plus every listed actions.runner.* unit must be active, and there must be at least one.
# rc 0 ok, 8 timeout.
_cih_units_active_now() { # HOST  (single pass, no polling; rc 0 only when >=1 unit and all active)
  local h="$1" listed rec u n=0 all=1
  listed="$(cih_guest_units_all 2>/dev/null)" || listed=""
  rec="$(_CIH_MARKER_KIND=recycle cih_marker_list "$h" stopped.runner_units 2>/dev/null)" || rec=""
  for u in $(printf '%s\n%s\n' "$listed" "$rec" | awk 'NF && !seen[$0]++'); do
    n=$((n + 1))
    _cih_guest systemctl is-active "$u" >/dev/null 2>&1 || all=0
  done
  [ "$n" -gt 0 ] && [ "$all" = "1" ]
}

_cih_wait_units_active() { # HOST TIMEOUT
  local h="$1" max i=0
  max="$(_cih_max_polls "$2")"
  while :; do
    _cih_units_active_now "$h" && return 0
    i=$((i + 1))
    [ "$i" -lt "$max" ] || { _cih_fail ONLINE_TIMEOUT "guest runner units of $h not all active within ${2}s (checked locally; sentinel stays, re-run with --recover)"; return $?; }
    _cih_sleep "$CIH_POLL_SECS"
  done
}

# Is the pid recorded in the recycle sentinel a live ci-host process? Prints alive|dead|unknown.
# Only "dead" ever enables auto-recovery; anything unreadable is "unknown" (fail closed = treated
# like alive). Liveness comes from `ps -p` (not kill -0: as admin kill -0 on a root pid is EPERM
# and would read as dead). A live pid whose command is not ci-host is a REUSED pid (the recorded
# process died, e.g. across a reboot) and counts as dead.
_cih_recycle_pid_state() { # HOST
  local h="$1" pid cmd rc
  pid="$(_CIH_MARKER_KIND=recycle cih_marker_get "$h" pid 2>/dev/null)" || { echo unknown; return 0; }
  case "$pid" in ''|*[!0-9]*|0) echo unknown; return 0 ;; esac
  if [ "${CIH_TEST_MODE:-}" = "1" ]; then
    case "$(command -v "$CIH_PS" 2>/dev/null || true)" in "$CIH_TEST_ROOT"/*) ;; *) echo unknown; return 0 ;; esac
  fi
  # stderr is merged on purpose: rc 1 with NO output at all is ps's "no such pid"; rc 1 with any
  # diagnostic text means we could not prove the pid dead, so it is unknown (-> 14), not dead.
  cmd="$("$CIH_PS" -p "$pid" -o command= 2>&1)"; rc=$?
  if [ "$rc" = "1" ] && [ -z "$cmd" ]; then echo dead; return 0; fi
  [ "$rc" = "0" ] && [ -n "$cmd" ] || { echo unknown; return 0; }
  case "$cmd" in *ci-host*) echo alive ;; *) echo dead ;; esac
}

# Scheduled-path healing of an orphaned sentinel (state=recycling, recorded pid not a live
# ci-host). The lock is already held, so no concurrent ci-host operation exists.
#   VM Running AND all guest runner units active -> nothing is down: retire the sentinel
#     (retired_by: auto-recover) and exit 0 NOOP; the NEXT tick makes the normal recycle decision.
#   otherwise -> run the same idempotent finish path as `--recover` (start VM + units, wait for
#     the runners, retire). Failure leaves state=error, which is never auto-retired (human needed).
_cih_recycle_auto_recover() { # HOST
  local h="$1" vst
  vst="$(cih_vm_state)" || return $?
  if [ "$vst" = "Running" ] && _cih_units_active_now "$h"; then
    cih_marker_retire "$h" "auto-recover" || { _cih_fail INTERNAL "could not retire the orphaned recycle sentinel"; return $?; }
    _cih_ok NOOP "retired orphaned recycle sentinel for '$h' (recorded pid not running, VM Running, runner units active); next tick decides"
    _cih_log "$CIH_RESULT_DETAIL"; return 0
  fi
  _cih_log "orphaned recycle sentinel for '$h' (recorded pid not running) and the VM is '$vst' or units are not active: auto-running the recover path"
  _CIH_RECYCLING=1
  _cih_recycle_finish "$h" recovering
}

# recycle --recover: finish a crashed or failed recycle (VM down, or sentinel in state error).
_cih_recycle_recover() { # HOST SENTINEL-STATE
  local h="$1" rst="$2"
  case "$rst" in
    absent) _cih_ok NOOP "no recycle sentinel; nothing to recover"; _cih_log "$CIH_RESULT_DETAIL"; return 0 ;;
    corrupt) _cih_fail STATE_CONFLICT "recycle sentinel for '$h' is corrupt (fail-closed); inspect $(cih_sentinel_path "$h")"; return $? ;;
  esac
  if [ "$CIH_OPT_DRYRUN" = "1" ]; then
    _cih_log "dry-run: sentinel state '$rst'; would start the VM and units, wait for the Linux runners online, retire the sentinel. Nothing changed."
    _cih_ok OK "dry-run"; return 0
  fi
  _CIH_RECYCLING=1
  _cih_recycle_finish "$h" recovering
}

# Status: rc precedence 6, 5, 11, 10, 12, 0 (design section 3).
cih_cmd_status() {
  _cih_setup_cmd status "$@" || return $?
  local h="$CIH_HOST" st vst units macos out rc id name status busy labels rst
  local drift="" rcs=0 varlines="" v val vrc tgt anyonline=0 anyoffline=0 runners="" live="" hyg=""
  cih_preflight || return $?
  st="$(cih_marker_state "$h")"
  rst="$(_cih_recycle_state "$h")"
  vst="$(cih_vm_state 2>/dev/null)" || vst=unknown
  units="$(cih_guest_units 2>/dev/null | tr '\n' ' ')" || units=""
  macos=none
  if [ "$CIH_HAS_MACOS" = "1" ]; then _cih_daemon_loaded "$CIH_LABEL_MAC" && macos=loaded || macos=not-loaded; fi
  runners="$(cih_host_runners "$h")"; rc=$?
  [ "$rc" = "0" ] || return "$rc"
  while IFS="	" read -r id name status busy labels; do
    [ -n "$id" ] || continue
    if [ "$status" = "online" ]; then anyonline=1; else anyoffline=1; fi
  done <<EOF
$runners
EOF
  for v in $_CIH_VARS; do
    val="$(cih_var_get "$v")"; vrc=$?
    case "$vrc" in
      0) cih_value_targets_host "$val" "$h"; tgt=$?; [ "$tgt" = "3" ] && tgt=x
         varlines="${varlines}${v}	1	${val}	${tgt}
" ;;
      1) varlines="${varlines}${v}	0		2
" ;;
      *) return "$vrc" ;;
    esac
  done
  case "$st" in
    corrupt) drift="corrupt-marker"; rcs=11 ;;
    draining|resuming) drift="transitional-$st"; rcs=11 ;;
    paused)
      rcs=10
      [ "$vst" != "Running" ] || { drift="${drift}|vm-running"; rcs=11; }
      [ "$anyonline" != "1" ] || { drift="${drift}|runner-online"; rcs=11; }
      for v in $_CIH_VARS; do
        [ "$(cih_marker_get "$h" "saved_vars.$v.touched" 2>/dev/null)" = "true" ] || continue
        live="$(cih_var_get "$v")"; vrc=$?
        if [ "$(cih_marker_get "$h" "saved_vars.$v.planned")" = "delete" ]; then
          if [ "$vrc" = "0" ]; then
            if [ "$live" = "$(cih_marker_get "$h" "saved_vars.$v.value" 2>/dev/null)" ]; then
              drift="${drift}|$v-re-armed"; rcs=11
            else
              _cih_warn "$v was re-pointed during the pause; resume will keep the live value"
            fi
          fi
        fi
      done ;;
    absent)
      if [ "$vst" != "Running" ] || [ "$anyoffline" = "1" ]; then drift="down-not-paused"; rcs=12; fi ;;
  esac
  # XACA-1708-004: a recycle sentinel is never "active": an interrupted or failed recycle is
  # TRANSITIONAL (it explains a down VM, so it replaces DEGRADED) until recycle --recover.
  local orph=""
  if [ "$rst" != "absent" ]; then drift="${drift}|recycle-$rst"; rcs=11; fi
  if [ "$rst" = "recycling" ] && [ "$(_cih_recycle_pid_state "$h")" = "dead" ]; then orph=" (orphaned: recorded pid not running)"; drift="${drift}|recycle-orphaned"; fi
  _cih_pool_compute || return $?
  hyg="$(_cih_hygiene)"   # XACA-1708-006: advisory only, never touches rcs
  if [ "$CIH_OPT_JSON" = "1" ]; then
    _cih_py -c "$_CIH_PY_STATUS" "$h" "$st" "$vst" "$units" "$macos" "$runners" "$varlines" "${drift#|}" "$_CIH_POOL_ONLINE" "$_CIH_POOL_ALL_OUT" "$rst" "$hyg"
  else
    _cih_log "marker=$st recycle=$rst${orph} vm=$vst macos_daemon=$macos units=${units:-none}"
    _cih_log "drift: ${drift:-none}"
    _cih_log "pool: online Linux runners by host: $_CIH_POOL_ONLINE"
    if [ "$hyg" = "unavailable" ]; then _cih_log "hygiene: unavailable (top output unreadable; NOT a clean result)"
    else _cih_py -c "$_CIH_PY_HYGIENE_TEXT" "$hyg" | while IFS= read -r hl; do _cih_log "$hl"; done; fi
  fi
  [ "$_CIH_POOL_ALL_OUT" != "1" ] || _cih_warn "EVERY known host is out of rotation: no CI capacity is available (jobs will queue)"
  case "$rcs" in
    0)  _cih_ok OK "active"; return 0 ;;
    10) _cih_ok PAUSED "paused"; return 10 ;;
    11) CIH_RESULT_NAME=TRANSITIONAL; CIH_RESULT_DETAIL="${drift#|}"; return 11 ;;
    12) CIH_RESULT_NAME=DEGRADED; CIH_RESULT_DETAIL="${drift#|}"; return 12 ;;
  esac
}
