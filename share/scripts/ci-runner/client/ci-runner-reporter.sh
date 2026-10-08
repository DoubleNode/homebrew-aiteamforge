#!/usr/bin/env bash

#
#  ci-runner-reporter.sh
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 DoubleNode.com. All rights reserved.
#

# CI Runner Telemetry Reporter (XACA-1387-002)
#
# Runs ON a self-hosted GitHub Actions runner host (today: M1Mini) once per
# invocation (schedule it every 60 s) and POSTs ONE structured payload to
# POST /api/ci-runners-push. Contract: fleet-monitor/docs/DATA_SCHEMA.md
# § "CI Runner Telemetry" (authoritative). Host topology: scripts/ci-runner/
# provision-host.sh and docs/ci-runner-runbook.md.
#
# Usage:
#   ci-runner-reporter.sh [--dry-run] [--help]
#     --dry-run   print the payload (pretty JSON) to stdout, do not POST
#
# Must run as the user that owns the VM and can read the runner dirs
# (ci-runner on M1Mini): `limactl` only sees instances under its owner's
# ~/.lima, and as any other user it reports NO instances (which this script
# would then report as "no VM").
#
# NO RAW LOGS (normative): the only thing derived from runner _diag logs is
# the structured fields below, extracted by anchored regexes in the embedded
# parser, sanitised (single line, control chars stripped, length-capped) and
# shape-validated before they leave the host. No log line, step output,
# stack trace, env var, command line or _work path is ever copied, and
# .runner / .credentials* / dotenv files are never opened.
#
# Bash 3.2 compatible (no associative arrays, no ${var,,}, no mapfile, no |&).
# Deliberately NOT `set -e`: every collector must degrade to `unknown` /
# an omitted optional field on failure, never abort the whole report.
#
# Environment overrides (all optional; tests use them):
#   CI_RUNNER_MACHINE        machine id (default: machine.json .machineName, else hostname -s)
#   CI_RUNNER_SERVER_URL     server base URL (default: fleet-config.json centralServer.apiEndpoint minus /api/*)
#   CI_RUNNER_API_KEY        bearer token (default: fleet-config.json centralServer.authToken, the host's
#                            per-host fct_ telemetry key, XACA-1422). The fleet-wide $FLEET_AUTH_TOKEN is
#                            NEVER used: the server rejects it on the push route (401), and a runner host
#                            must not hold it. No token = the push is skipped, nothing is sent.
#   CI_RUNNER_FLEET_CONFIG   fleet config path
#   CI_RUNNER_MACHINE_CONFIG machine config path
#   CI_RUNNER_MAC_RUNNER     "name=dir" for the host runner  (default m1mini-macos-1=/Users/ci-runner/actions-runner-macos;
#                            set but EMPTY = this host has no macOS runner, none is reported)
#   CI_RUNNER_MAC_LABEL      launchd label of the host runner (default com.doublenode.ci-runner.macos)
#   CI_RUNNER_MAC_USER       user owning the listener process (default ci-runner)
#   CI_RUNNER_LINUX_RUNNERS  space-separated "name=dir" guest runners (default m1mini-linux-1=/opt/actions-runner-1 m1mini-linux-2=/opt/actions-runner-2)
#   CI_RUNNER_VM_NAME        Lima instance (default ci-linux; empty = this host has no VM)
#   CI_RUNNER_LIMACTL        limactl binary (default /opt/homebrew/bin/limactl)
#   CI_RUNNER_GUEST_SUDO     prefix for guest commands (default "sudo -n"; the guest user has passwordless sudo)
#   CI_RUNNER_LABELS_MAC / CI_RUNNER_LABELS_LINUX   comma-separated labels
#   CI_RUNNER_REPO           owner/name used when a log lacks the repository (default DoubleNode/dev-team)
#   CI_RUNNER_DISK_PATH      path whose volume is reported (default: parent of the host runner dir)
#   CI_RUNNER_BUSY_MAX_AGE   seconds an unfinished Worker log may sit idle and still count as a running job (default 21600)
#   CI_RUNNER_UPTIME_SECONDS override uptime (tests)
#   CI_RUNNER_HOSTNAME       override host.hostname (tests); omitted from the payload if the server would reject it
#   CI_RUNNER_PYTHON, CI_RUNNER_LAUNCHCTL, CI_RUNNER_PGREP, CI_RUNNER_SYSTEMCTL   binaries (tests)

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
set -uo pipefail

REPORTER_VERSION="1.0.0"

PY="${CI_RUNNER_PYTHON:-python3}"
LIMACTL="${CI_RUNNER_LIMACTL:-/opt/homebrew/bin/limactl}"
LAUNCHCTL="${CI_RUNNER_LAUNCHCTL:-launchctl}"
PGREP="${CI_RUNNER_PGREP:-pgrep}"
VM_NAME="${CI_RUNNER_VM_NAME-ci-linux}"
GUEST_SUDO="${CI_RUNNER_GUEST_SUDO-sudo -n}"
MAC_RUNNER="${CI_RUNNER_MAC_RUNNER-m1mini-macos-1=/Users/ci-runner/actions-runner-macos}"
MAC_LABEL="${CI_RUNNER_MAC_LABEL:-com.doublenode.ci-runner.macos}"
MAC_USER="${CI_RUNNER_MAC_USER:-ci-runner}"
# `-` not `:-` (XACA-1461): provision-host.sh --no-linux writes these as set-but-EMPTY ("no Linux side"); `:-` would turn
# that back into the m1mini defaults and report two phantom guest runners. Unset still gets the defaults.
LINUX_RUNNERS="${CI_RUNNER_LINUX_RUNNERS-m1mini-linux-1=/opt/actions-runner-1 m1mini-linux-2=/opt/actions-runner-2}"
[ -n "$VM_NAME" ] || LINUX_RUNNERS=""   # no VM => no guest runners, whatever else says
LABELS_MAC="${CI_RUNNER_LABELS_MAC:-self-hosted,macOS,ARM64,m1mini}"
LABELS_LINUX="${CI_RUNNER_LABELS_LINUX-self-hosted,Linux,ARM64,m1mini}"
DEFAULT_REPO="${CI_RUNNER_REPO:-DoubleNode/dev-team}"
BUSY_MAX_AGE="${CI_RUNNER_BUSY_MAX_AGE:-21600}"

DRY_RUN=false
TMP_DIR=""

log() { printf '%s\n' "$*" >&2; }
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ============================================================================
# EMBEDDED PYTHON (parser + payload builder + config reader)
# The same source is piped to the Lima guest for the Linux runners' logs, so
# it must stay 3.9-compatible (host /usr/bin/python3) and stdlib-only.
# ============================================================================
ci_py() {
cat <<'PY'
import sys, os, re, json, glob, subprocess, time, calendar

TS_RE = re.compile(r'^\[(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)(?:\.\d+)?Z ')
RESULT_RE = re.compile(r'(?:Job result after all job steps finish|Finishing job with result|completed with result)\s*:\s*([A-Za-z]+)')
GUID_RE = re.compile(r'"jobId"\s*:\s*"([0-9a-fA-F-]{36})"')
GUID2_RE = re.compile(r'Job ID ([0-9a-fA-F-]{36})')
DISPLAY_RE = re.compile(r'"jobDisplayName"\s*:\s*"((?:[^"\\]|\\.)*)"')
NAME_RE = re.compile(r'^[A-Za-z0-9._-]{1,64}$')
REPO_RE = re.compile(r'^[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}$')
ID_RE = re.compile(r'^[A-Za-z0-9._:-]{1,128}$')
URL_RE = re.compile(r'^https://github\.com/[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}/actions/runs/[0-9]+(/attempts/[0-9]+)?(/job/[0-9]+)?$')
ISO_RE = re.compile(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
CTRL_RE = re.compile(r'[\x00-\x1f\x7f]')
# Same rule as the server's HOSTNAME_RE (ci-runners-routes.js): first char
# alphanumeric, <=255. A hostname it would reject 400s the WHOLE push, so an
# unacceptable one is OMITTED (host.hostname is optional), never sent (XACA-1387-020).
HOST_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,254}')
EVENT_RE = re.compile(r'^[A-Za-z0-9_.-]{1,64}$')
JOBNUM_RE = re.compile(r'^[0-9]{1,20}$')
MAX_FILES = 60
HEAD = 1048576
TAIL = 524288

def iso(e):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(e))

def clean(s, cap, default):
    if s is None:
        return default
    s = CTRL_RE.sub(' ', s)
    s = re.sub(r'\s+', ' ', s).strip()
    if not s:
        return default
    return s[:cap]

def unjson(s):
    try:
        return json.loads('"' + s + '"')
    except Exception:
        return s

def read_text(path):
    size = os.path.getsize(path)
    with open(path, 'rb') as f:
        if size > HEAD + TAIL:
            head = f.read(HEAD)
            f.seek(size - TAIL)
            data = head + b'\n' + f.read(TAIL)
        else:
            data = f.read()
    return data.decode('utf-8', 'ignore')

def ctx(text, key, numeric=False):
    val = r'(\d+)' if numeric else r'"((?:[^"\\]|\\.)*)"'
    pre = r'"(?:k|Key)"\s*:\s*"' + re.escape(key) + r'"\s*,\s*"(?:v|Value)"\s*:\s*'
    if numeric:
        pre += r'"?'
    m = re.search(pre + val, text)
    if not m:
        return None
    return m.group(1) if numeric else unjson(m.group(1))

def safe_str(v, cap):
    # Strict (reject, not repair): a branch/event with control chars is attacker
    # noise, so it becomes null rather than a mangled lookalike.
    if not isinstance(v, str) or not v or len(v) > cap or CTRL_RE.search(v):
        return None
    return v

def branch_of(text):
    b = safe_str(ctx(text, 'ref_name'), 255)
    if b:
        return b
    ref = ctx(text, 'ref')
    if isinstance(ref, str) and ref.startswith('refs/heads/'):
        return safe_str(ref[len('refs/heads/'):], 255)
    return None

def parse_file(runner, path, now, busy_age, default_repo):
    text = read_text(path)
    stamps = []
    result_ts = None
    result = None
    for line in text.split('\n'):
        m = TS_RE.match(line)
        if not m:
            continue
        e = calendar.timegm(tuple(int(x) for x in m.groups()) + (0, 0, 0))
        stamps.append(e)
        rm = RESULT_RE.search(line)
        if rm:
            result = rm.group(1).lower()
            result_ts = e
    if not stamps:
        return None
    started = stamps[0]
    mtime = os.path.getmtime(path)
    stem = os.path.splitext(os.path.basename(path))[0]
    m = GUID_RE.search(text) or GUID2_RE.search(text)
    jid = m.group(1) if m else runner + '-' + stem
    jid = re.sub(r'[^A-Za-z0-9._:-]', '_', jid)[:128]
    dm = DISPLAY_RE.search(text)
    job_name = clean(unjson(dm.group(1)) if dm else None, 128, 'unknown')
    workflow = clean(ctx(text, 'workflow'), 128, 'unknown')
    repo = clean(ctx(text, 'repository'), 140, default_repo)
    if not REPO_RE.match(repo):
        repo = default_repo
    run_id = ctx(text, 'run_id', True)
    run_url = None
    if run_id and len(run_id) <= 20:
        run_url = 'https://github.com/%s/actions/runs/%s' % (repo, run_id)
    ev = safe_str(ctx(text, 'event_name'), 64)
    if ev is not None and not EVENT_RE.match(ev):
        ev = None
    # NUMERIC job id: only a numeric-only value under a known github-context key
    # is ever used; absent/non-numeric -> null (never guessed from the log GUID).
    job_url = None
    if run_url:
        for key in ('check_run_id', 'job_check_run_id'):
            n = ctx(text, key, True)
            if n and JOBNUM_RE.match(n):
                job_url = run_url + '/job/' + n
                break
    base = {'id': jid, 'workflow': workflow, 'jobName': job_name, 'repo': repo,
            'runUrl': run_url, 'startedAt': iso(started),
            'branch': branch_of(text), 'event': ev, 'jobUrl': job_url}
    if result is not None:
        kind = {'succeeded': 'success', 'succeededwithissues': 'success', 'failed': 'failure',
                'canceled': 'cancelled', 'cancelled': 'cancelled'}.get(result, 'unknown')
        return ('done', mtime, base, kind, result_ts)
    if now - mtime <= busy_age:
        return ('current', mtime, base, None, None)
    return ('done', mtime, base, 'unknown', stamps[-1])

def systemd_state(d):
    try:
        with open(os.path.join(d, '.service')) as f:
            svc = f.readline().strip()
        if not re.match(r'^[A-Za-z0-9@._:\\-]{1,256}$', svc):
            return 'unknown'
        p = subprocess.run([os.environ.get('CI_RUNNER_SYSTEMCTL', 'systemctl'), 'is-active', svc],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
        out = p.stdout.decode('utf-8', 'ignore').strip()
    except Exception:
        return 'unknown'
    if out == 'active':
        return 'up'
    if out in ('inactive', 'failed', 'deactivating'):
        return 'down'
    return 'unknown'

def cmd_parse(args):
    systemd = False
    busy_age = 21600
    repo = 'DoubleNode/dev-team'
    pairs = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == '--systemd':
            systemd = True
        elif a == '--busy-age':
            i += 1
            busy_age = int(args[i])
        elif a == '--repo':
            i += 1
            repo = args[i]
        elif '=' in a:
            pairs.append(a.split('=', 1))
        i += 1
    now = time.time()
    out = {'runners': {}, 'jobs': []}
    for name, d in pairs:
        if not NAME_RE.match(name):
            continue
        entry = {'currentJob': None}
        if systemd:
            entry['state'] = systemd_state(d)
        out['runners'][name] = entry
        files = glob.glob(os.path.join(d, '_diag', 'Worker_*.log'))
        files.sort(key=lambda p: os.path.getmtime(p), reverse=True)
        cur = None
        for p in files[:MAX_FILES]:
            try:
                r = parse_file(name, p, now, busy_age, repo)
            except Exception:
                continue
            if r is None:
                continue
            kind, mtime, base, result, ended = r
            if kind == 'current':
                if cur is None:
                    cur = base
                continue
            s = calendar.timegm(time.strptime(base['startedAt'], '%Y-%m-%dT%H:%M:%SZ'))
            e = max(ended, s)
            j = dict(base)
            j['runner'] = name
            j['endedAt'] = iso(e)
            j['result'] = result
            j['minutes'] = round(min(max((e - s) / 60.0, 0), 7200), 2)
            j['durationSeconds'] = int(min(max(e - s, 0), 432000))
            out['jobs'].append(j)
        entry['currentJob'] = cur
    out['jobs'].sort(key=lambda j: j['endedAt'], reverse=True)
    out['jobs'] = out['jobs'][:50]
    json.dump(out, sys.stdout)

def load(path):
    if not path:
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None

def valid_job(j):
    try:
        return (ID_RE.match(j['id']) and NAME_RE.match(j['runner']) and len(j['workflow']) <= 128
                and len(j['jobName']) <= 128 and REPO_RE.match(j['repo'])
                and (j['runUrl'] is None or URL_RE.match(j['runUrl']))
                and ISO_RE.match(j['startedAt']) and ISO_RE.match(j['endedAt'])
                and j['endedAt'] >= j['startedAt']
                and j['result'] in ('success', 'failure', 'cancelled', 'unknown')
                and 0 <= j['minutes'] <= 7200
                and 0 <= j['durationSeconds'] <= 432000
                and (j['branch'] is None or safe_str(j['branch'], 255))
                and (j['event'] is None or EVENT_RE.match(j['event']))
                and (j['jobUrl'] is None or (URL_RE.match(j['jobUrl']) and '/job/' in j['jobUrl'])))
    except Exception:
        return False

def cmd_build(args):
    e = os.environ
    pretty = args[0] == 'pretty'
    mac = load(e.get('B_MAC_JSON'))
    lin = load(e.get('B_LINUX_JSON'))
    labels_mac = [x for x in e.get('B_LABELS_MAC', '').split(',') if x][:32]
    labels_lin = [x for x in e.get('B_LABELS_LINUX', '').split(',') if x][:32]
    host = {'uptimeSeconds': int(e['B_UPTIME'])}
    hn = e.get('B_HOSTNAME', '').strip()
    if HOST_RE.fullmatch(hn):
        host['hostname'] = hn
    if e.get('B_DISK_TOTAL', '').isdigit() and e.get('B_DISK_FREE', '').isdigit():
        host['disk'] = {'path': e.get('B_DISK_PATH', '')[:256], 'totalBytes': int(e['B_DISK_TOTAL']),
                        'freeBytes': int(e['B_DISK_FREE'])}
    vm_state = e.get('B_VM_STATE', 'none')
    vm = None if vm_state == 'none' else {'name': e.get('B_VM_NAME', '')[:64], 'state': vm_state}
    runners = []
    jobs = []
    mname = e.get('B_MAC_NAME', '')
    if mname:
        cur = None
        if mac and mname in mac['runners']:
            cur = mac['runners'][mname].get('currentJob')
        st = e.get('B_MAC_STATE', 'unknown')
        cur = cur if st == 'up' else None
        runners.append({'name': mname, 'serviceState': st, 'labels': labels_mac,
                        'os': 'macOS', 'busy': cur is not None, 'currentJob': cur})
        if mac:
            jobs.extend(mac['jobs'])
    if vm is not None:
        for pair in e.get('B_LINUX_NAMES', '').split():
            n = pair.split('=', 1)[0]
            st = 'unknown'
            cur = None
            if vm_state == 'running' and lin and n in lin['runners']:
                st = lin['runners'][n].get('state', 'unknown')
                cur = lin['runners'][n].get('currentJob')
            cur = cur if st == 'up' else None
            runners.append({'name': n, 'serviceState': st, 'labels': labels_lin,
                            'os': 'Linux', 'busy': cur is not None, 'currentJob': cur})
        if vm_state == 'running' and lin:
            jobs.extend(lin['jobs'])
    runners = [r for r in runners if NAME_RE.match(r['name'])]
    seen = set()
    uniq = []
    for r in runners:
        if r['name'] not in seen:
            seen.add(r['name'])
            uniq.append(r)
    jobs = [j for j in jobs if valid_job(j)]
    jobs.sort(key=lambda j: j['endedAt'], reverse=True)
    payload = {'schema_version': 1, 'machine': e['B_MACHINE'], 'reportedAt': iso(time.time()),
               'reporterVersion': e['B_VERSION'], 'host': host, 'vm': vm,
               'runners': uniq[:16], 'jobs': jobs[:50]}
    if pretty:
        print(json.dumps(payload, indent=2))
    else:
        sys.stdout.write(json.dumps(payload, separators=(',', ':')))

def cmd_get(args):
    d = load(args[0])
    for path in args[1:]:
        v = d
        for k in path.split('.'):
            v = v.get(k) if isinstance(v, dict) else None
        print(v if isinstance(v, str) else '')

def main():
    sub = sys.argv[1]
    rest = sys.argv[2:]
    {'parse': cmd_parse, 'build': cmd_build, 'get': cmd_get}[sub](rest)

main()
PY
}

# ============================================================================
# HELPERS
# ============================================================================

# run_with_timeout SECS STDIN_FILE CMD... : stdout passes through, rc 124 on timeout.
# STDIN_FILE is redirected explicitly because a backgrounded command in a
# non-interactive bash otherwise gets /dev/null on stdin.
run_with_timeout() {
    local secs="$1" infile="$2" pid watcher rc
    shift 2
    "$@" <"$infile" &
    pid=$!
    ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    watcher=$!
    wait "$pid" 2>/dev/null
    rc=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    [ "$rc" -ge 128 ] && rc=124
    return "$rc"
}

py() { "$PY" -c "$PY_SRC" "$@"; }

usage() {
    sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
}

# ============================================================================
# COLLECTORS (each degrades to unknown / omitted, never aborts)
# ============================================================================

collect_machine_id() {
    local id="${CI_RUNNER_MACHINE:-}" mc
    if [ -z "$id" ]; then
        for mc in "${CI_RUNNER_MACHINE_CONFIG:-}" "$HOME/.aiteamforge/machine.json" "$HOME/.dev-team/machine.json"; do
            if [ -n "$mc" ] && [ -f "$mc" ]; then
                id=$(py get "$mc" machineName 2>/dev/null)
                [ -n "$id" ] && break
            fi
        done
    fi
    [ -z "$id" ] && id=$(hostname -s 2>/dev/null)
    # schema: ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$
    id=$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '-' | tr 'A-Z' 'a-z' | sed 's/^[^a-z0-9]*//' | cut -c1-128)
    printf '%s' "$id"
}

collect_uptime() {
    local boot now
    if [ -n "${CI_RUNNER_UPTIME_SECONDS:-}" ]; then printf '%s' "$CI_RUNNER_UPTIME_SECONDS"; return 0; fi
    boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ *sec = \([0-9][0-9]*\),.*/\1/p')   # anchored: greedy .*sec would match "usec"
    [ -n "$boot" ] || return 1
    now=$(date +%s)
    printf '%s' "$((now - boot))"
}

# echoes "total free" in bytes, or nothing on failure (disk then omitted)
collect_disk() {
    local line total free
    line=$(df -k -P "$1" 2>/dev/null | tail -n 1)
    [ -n "$line" ] || return 1
    total=$(printf '%s\n' "$line" | awk '{print $2}')
    free=$(printf '%s\n' "$line" | awk '{print $4}')
    case "$total$free" in *[!0-9]*|"") return 1 ;; esac
    printf '%s %s' "$((total * 1024))" "$((free * 1024))"
}

# echoes none | running | stopped | broken | unknown
#   none    = host has no VM (limactl absent, or instance not listed)
#   unknown = the query itself failed
collect_vm_state() {
    local out rc
    [ -n "$VM_NAME" ] || { echo none; return 0; }
    if ! command -v "$LIMACTL" >/dev/null 2>&1; then echo none; return 0; fi
    : >"$TMP_DIR/empty"
    out=$(run_with_timeout 15 "$TMP_DIR/empty" "$LIMACTL" list --format '{{.Name}}' 2>/dev/null); rc=$?
    if [ "$rc" -ne 0 ]; then echo unknown; return 0; fi
    if ! grep -qx "$VM_NAME" <<<"$out"; then echo none; return 0; fi
    out=$(run_with_timeout 15 "$TMP_DIR/empty" "$LIMACTL" list --format '{{.Status}}' "$VM_NAME" 2>/dev/null); rc=$?
    if [ "$rc" -ne 0 ]; then echo unknown; return 0; fi
    case "$(printf '%s' "$out" | tr -d '[:space:]' | tr 'A-Z' 'a-z')" in
        running) echo running ;;
        stopped) echo stopped ;;
        broken)  echo broken ;;
        *)       echo unknown ;;
    esac
}

# host runner service: launchd first (matches the runbook), process check as fallback
collect_mac_service_state() {
    local out rc
    out=$("$LAUNCHCTL" print "system/$MAC_LABEL" 2>/dev/null); rc=$?
    if [ "$rc" -eq 0 ]; then
        case "$out" in *"state = running"*) echo up ;; *) echo down ;; esac
        return 0
    fi
    "$PGREP" -u "$MAC_USER" -f Runner.Listener >/dev/null 2>&1; rc=$?
    case "$rc" in 0) echo up ;; 1) echo down ;; *) echo unknown ;; esac
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=true ;;
            -h|--help) usage; return 0 ;;
            *) log "unknown argument: $arg"; usage >&2; return 2 ;;
        esac
    done

    if ! command -v "$PY" >/dev/null 2>&1; then log "ERROR: python3 not found (set CI_RUNNER_PYTHON)"; return 1; fi
    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ci-runner-reporter.XXXXXX") || { log "ERROR: mktemp failed"; return 1; }
    PY_SRC=$(ci_py)

    local mac_name="${MAC_RUNNER%%=*}" mac_dir="${MAC_RUNNER#*=}"
    local machine uptime disk disk_path vm_state mac_state
    machine=$(collect_machine_id)
    [ -n "$machine" ] || { log "ERROR: could not determine machine id (set CI_RUNNER_MACHINE)"; return 1; }
    uptime=$(collect_uptime) || { log "ERROR: could not read uptime; refusing to report a made-up 0"; return 1; }

    # No macOS runner (set-but-empty CI_RUNNER_MAC_RUNNER): there is no runner dir
    # to take the parent of, so fall back to $HOME (the ci-runner home volume).
    if [ -n "$MAC_RUNNER" ]; then
        disk_path="${CI_RUNNER_DISK_PATH:-$(dirname "$mac_dir")}"
    else
        disk_path="${CI_RUNNER_DISK_PATH:-${HOME:-/}}"
    fi
    disk=$(collect_disk "$disk_path") || disk=""

    vm_state=$(collect_vm_state)
    mac_state=unknown
    [ -z "$MAC_RUNNER" ] || mac_state=$(collect_mac_service_state)

    # Host runner logs (local)
    local mac_json="$TMP_DIR/mac.json" lin_json="$TMP_DIR/linux.json"
    [ -z "$MAC_RUNNER" ] || py parse --busy-age "$BUSY_MAX_AGE" --repo "$DEFAULT_REPO" "$MAC_RUNNER" >"$mac_json" 2>/dev/null ||rm -f "$mac_json"

    # Guest runners: one limactl call, script on stdin (argv through ssh is
    # re-parsed by a remote shell; the names/dirs here are validated safe).
    if [ "$vm_state" = "running" ]; then
        printf '%s\n' "$PY_SRC" >"$TMP_DIR/parser.py"
        # shellcheck disable=SC2086
        run_with_timeout 45 "$TMP_DIR/parser.py" "$LIMACTL" shell --workdir /tmp "$VM_NAME" -- \
            $GUEST_SUDO python3 - parse --systemd --busy-age "$BUSY_MAX_AGE" --repo "$DEFAULT_REPO" $LINUX_RUNNERS \
            >"$lin_json" 2>/dev/null || rm -f "$lin_json"
    fi

    local pretty=compact
    [ "$DRY_RUN" = true ] && pretty=pretty
    local payload_file="$TMP_DIR/payload.json"
    B_HOSTNAME="${CI_RUNNER_HOSTNAME-$(hostname 2>/dev/null | awk 'NR==1')}" \
    B_MACHINE="$machine" B_VERSION="$REPORTER_VERSION" B_UPTIME="$uptime" \
    B_DISK_PATH="$disk_path" B_DISK_TOTAL="${disk%% *}" B_DISK_FREE="${disk##* }" \
    B_VM_NAME="$VM_NAME" B_VM_STATE="$vm_state" \
    B_MAC_NAME="$mac_name" B_MAC_STATE="$mac_state" B_MAC_JSON="$mac_json" \
    B_LINUX_NAMES="$LINUX_RUNNERS" B_LINUX_JSON="$lin_json" \
    B_LABELS_MAC="$LABELS_MAC" B_LABELS_LINUX="$LABELS_LINUX" \
        py build "$pretty" >"$payload_file" || { log "ERROR: payload build failed"; return 1; }

    if [ "$DRY_RUN" = true ]; then
        cat "$payload_file"
        echo
        return 0
    fi

    send_payload "$payload_file"
}

send_payload() {
    local file="$1" fleet_cfg base token token_ok url attempt=1 code
    fleet_cfg="${CI_RUNNER_FLEET_CONFIG:-}"
    if [ -z "$fleet_cfg" ]; then
        if [ -f "$HOME/.aiteamforge/fleet-config.json" ]; then fleet_cfg="$HOME/.aiteamforge/fleet-config.json"
        else fleet_cfg="$HOME/.dev-team/fleet-config.json"; fi
    fi
    base="${CI_RUNNER_SERVER_URL:-}"
    if [ -z "$base" ] && [ -f "$fleet_cfg" ]; then
        base=$(py get "$fleet_cfg" centralServer.apiEndpoint 2>/dev/null)
        base="${base%/api/*}"
    fi
    token="${CI_RUNNER_API_KEY:-}"
    if [ -z "$token" ] && [ -f "$fleet_cfg" ]; then token=$(py get "$fleet_cfg" centralServer.authToken 2>/dev/null); fi
    # XACA-1422: no $FLEET_AUTH_TOKEN fallback. The push is accepted only with this
    # host's per-host fct_ key; an unauthenticated or fleet-token push can only 401.
    if [ -z "$base" ]; then log "ERROR: no server URL (set CI_RUNNER_SERVER_URL or fleet-config.json centralServer.apiEndpoint)"; return 1; fi
    if [ -z "$token" ]; then
        log "ci-runner-reporter: SKIPPED push: no telemetry key (set CI_RUNNER_API_KEY or centralServer.authToken in ${fleet_cfg}); re-run provision-host.sh with --telemetry-key-file"
        return 1
    fi
    # XACA-1422-013: send ONLY a per-host fct_ key (server TELEMETRY_KEY_RE). Anything else,
    # e.g. a fleet token pasted into the config by hand, could only 401 on this route, so it
    # is never transmitted (the endpoint may be plain http). The token itself is never logged.
    # XACA-1422-014: characters are spelled out, not [A-Za-z] ranges, which bash 3.2 collates
    # by locale (under UTF-8 an accented letter would fall inside the range).
    case "$token" in
        fct_*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*|fct_) token_ok=0 ;;
        fct_*) token_ok=1 ;;
        *) token_ok=0 ;;
    esac
    [ "${#token}" -eq 47 ] || token_ok=0   # "fct_" (4) + 43
    if [ "$token_ok" != 1 ]; then
        log "ci-runner-reporter: SKIPPED push: token is not a per-host fct_ telemetry key; re-run provision-host.sh with --telemetry-key-file"
        return 1
    fi
    url="${base%/}/api/ci-runners-push"

    while [ "$attempt" -le 2 ]; do
        # Token goes via curl's stdin config, not argv (ps-visible).
        code=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -s -o /dev/null -w '%{http_code}' \
            --connect-timeout 10 --max-time 30 -X POST -H "Content-Type: application/json" \
            -K - --data-binary "@$file" "$url" 2>/dev/null)
        case "$code" in
            200|201) log "ci-runner-reporter: reported to $url"; return 0 ;;
        esac
        attempt=$((attempt + 1))
        [ "$attempt" -le 2 ] && sleep 5
    done
    log "ci-runner-reporter: FAILED to report to $url (HTTP ${code:-none})"
    return 1
}

main "$@"
