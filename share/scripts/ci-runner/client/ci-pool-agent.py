#!/usr/bin/python3
"""ci-pool-agent.py - Fleet CI Pool machine agent (XACA-1442).

Sibling of ci-runner-reporter.sh (which stays untouched, D1). Runs as root
(D2); every job-side action drops to ci-runner with `sudo -n -u ci-runner -H`.

Constraints: stdlib only, must run under /usr/bin/python3 (3.9). No match
statements, no `X | Y` annotations. Subprocesses are argv lists only, never
shell=True.

This file holds XACA-1442-001 (capacity collectors, config/logging) and
XACA-1442-002 (poll loop, HTTP, outbox, supervisor interface + no-slot stub) and
XACA-1442-003 (SlotSupervisor: runs one-job runners in the Lima guest / as
ci-runner on macOS, cleans up, persists + re-adopts slots).

Contract: kanban/plans/XACA-1441/XACA-1441_ci_dispatcher.md section C3.
"""
import http.client
import json
import logging
import os
import random
import re
import signal
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

AGENT_VERSION = "1.0.0"
SCHEMA_VERSION = 1
DEFAULT_CONFIG_PATH = "/usr/local/etc/ci-pool-agent/agent.json"
DEFAULT_LIMACTL = "/opt/homebrew/bin/limactl"
DEFAULT_MARKER_DIR = "/usr/local/etc/ci-runner"  # XACA-1440 CIH_STATE_DIR
DEFAULT_LOG_PATH = "/Library/Logs/ci-pool-agent/agent.log"
CI_USER = "ci-runner"
COLLECTOR_TIMEOUT = 5          # seconds, per subprocess (D7)
SLOW_CACHE_TTL = 30.0          # memory_pressure + limactl list (D7)

log = logging.getLogger("ci-pool-agent")


# ---------------------------------------------------------------------------
# Config + logging
# ---------------------------------------------------------------------------
def load_config(path=None):
    """Load agent.json (non-secret). Path from CI_POOL_AGENT_CONFIG.

    Raises ValueError on unreadable / malformed config: the caller decides
    (main() exits non-zero; launchd KeepAlive retries).
    """
    path = path or os.environ.get("CI_POOL_AGENT_CONFIG") or DEFAULT_CONFIG_PATH
    try:
        with open(path) as f:
            raw = json.load(f)
    except (OSError, ValueError) as e:
        raise ValueError("cannot load config %s: %s" % (path, e))
    if not isinstance(raw, dict):
        raise ValueError("config %s is not a JSON object" % path)
    try:
        linux_slots = int(raw.get("linuxSlots", 0) or 0)
        mac_slots = int(raw.get("macSlots", 0) or 0)
    except (TypeError, ValueError) as e:
        raise ValueError("config %s: bad slot count: %s" % (path, e))
    return {
        "serverUrl": raw.get("serverUrl"),
        "machine": raw.get("machine"),
        "vmName": raw.get("vmName") or "",
        "linuxSlots": linux_slots,
        "macSlots": mac_slots,
        "limactl": raw.get("limactl") or DEFAULT_LIMACTL,
        "markerDir": raw.get("markerDir") or DEFAULT_MARKER_DIR,
        "logPath": raw.get("logPath") or DEFAULT_LOG_PATH,
        "keyPath": raw.get("keyPath") or DEFAULT_KEY_PATH,
        "statePath": raw.get("statePath") or DEFAULT_STATE_PATH,
        # see build_poll_body: only an explicit JSON true enables it
        "sendPauseMarker": raw.get("sendPauseMarker") is True,
        # XACA-1445-012 persistent-runner switch (all optional)
        "persistentStatePath": raw.get("persistentStatePath") or DEFAULT_PERSIST_PATH,
        "launchctl": raw.get("launchctl") or DEFAULT_LAUNCHCTL,
        "plistDir": raw.get("plistDir") or DEFAULT_PLIST_DIR,
        "macLabel": raw.get("macLabel") or "",
    }


def setup_logging(log_path=None, stream=None):
    """Log to file (D8) or a stream. Never log keys, JIT configs or job env."""
    handler = None
    if log_path:
        try:
            os.makedirs(os.path.dirname(log_path), exist_ok=True)
            handler = logging.FileHandler(log_path)
        except OSError:
            handler = None
    if handler is None:
        handler = logging.StreamHandler(stream or sys.stderr)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.handlers = [handler]
    log.setLevel(logging.INFO)
    log.propagate = False
    return log


# ---------------------------------------------------------------------------
# Subprocess helper (argv only, 5 s timeout, None on any failure)
# ---------------------------------------------------------------------------
def run_cmd(argv, timeout=COLLECTOR_TIMEOUT, ok_rcs=(0,)):
    """Run argv (a list, never a shell). Return stdout text, or None on failure."""
    if not isinstance(argv, (list, tuple)):
        raise TypeError("argv must be a list")
    try:
        p = subprocess.run(list(argv), stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=timeout, universal_newlines=True)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    if p.returncode not in ok_rcs:
        return None
    return p.stdout


# ---------------------------------------------------------------------------
# Pure parsers (unit-testable, no I/O). Each returns None on malformed input.
# ---------------------------------------------------------------------------
_PAGE_SIZE_RE = re.compile(r"page size of (\d+) bytes")
_PAGES_RE = re.compile(r"^Pages\s+(free|inactive|purgeable):\s+(\d+)\.?\s*$", re.M)


def parse_vm_stat(text):
    """(free + inactive + purgeable pages) * page size, in bytes (D7)."""
    if not text:
        return None
    m = _PAGE_SIZE_RE.search(text)
    if not m:
        return None
    page = int(m.group(1))
    if page <= 0:
        return None
    pages = {}
    for kind, n in _PAGES_RE.findall(text):
        pages[kind] = int(n)
    if set(pages) != {"free", "inactive", "purgeable"}:
        return None  # a missing term would silently under-report headroom
    return (pages["free"] + pages["inactive"] + pages["purgeable"]) * page


def parse_int(text):
    """sysctl -n hw.memsize / hw.ncpu."""
    try:
        v = int((text or "").strip())
    except ValueError:
        return None
    return v if v > 0 else None


_SWAP_RE = re.compile(r"(total|used)\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?)", re.I)
_UNIT = {"": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4}


def parse_swapusage(text):
    """'total = 3072.00M  used = 2270.25M ...' -> (used_bytes, total_bytes)."""
    if not text:
        return None
    got = {}
    for key, num, unit in _SWAP_RE.findall(text):
        got[key.lower()] = int(float(num) * _UNIT[unit.upper()])
    if "total" not in got or "used" not in got:
        return None
    return got["used"], got["total"]


def parse_loadavg(text):
    """'{ 3.20 2.90 2.50 }' -> (load1, load5, load15)."""
    if not text:
        return None
    nums = re.findall(r"[0-9]+(?:\.[0-9]+)?", text)
    if len(nums) < 3:
        return None
    return tuple(float(n) for n in nums[:3])


_MEMFREE_RE = re.compile(r"System-wide memory free percentage:\s*(\d{1,3})\s*%")


def parse_memory_pressure(text):
    """memFreePct from memory_pressure output (0..100)."""
    if not text:
        return None
    m = _MEMFREE_RE.search(text)
    if not m:
        return None
    v = int(m.group(1))
    return v if 0 <= v <= 100 else None


def parse_pids(text):
    """pgrep output -> set of int pids (empty output is a valid empty set)."""
    if text is None:
        return None
    pids = set()
    for tok in text.split():
        if not tok.isdigit():
            return None
        pids.add(int(tok))
    return pids


def map_vm_status(text):
    """Same mapping as collect_vm_state in ci-runner-reporter.sh."""
    s = "".join((text or "").split()).lower()
    if s in ("running", "stopped", "broken"):
        return s
    return "unknown"


# ---------------------------------------------------------------------------
# Collectors (subprocess + parse). None == failed == field omitted.
# ---------------------------------------------------------------------------
def collect_mem_reclaimable():
    return parse_vm_stat(run_cmd(["/usr/bin/vm_stat"]))


def collect_mem_total():
    return parse_int(run_cmd(["/usr/sbin/sysctl", "-n", "hw.memsize"]))


def collect_ncpu():
    return parse_int(run_cmd(["/usr/sbin/sysctl", "-n", "hw.ncpu"]))


def collect_swap():
    return parse_swapusage(run_cmd(["/usr/sbin/sysctl", "-n", "vm.swapusage"]))


def collect_load():
    return parse_loadavg(run_cmd(["/usr/sbin/sysctl", "-n", "vm.loadavg"]))


def collect_mem_free_pct():
    return parse_memory_pressure(run_cmd(["/usr/bin/memory_pressure"]))


def collect_team_sessions():
    """claude processes minus those owned by ci-runner (D7). pgrep rc 1 = none."""
    all_p = parse_pids(run_cmd(["/usr/bin/pgrep", "-x", "claude"], ok_rcs=(0, 1)))
    ci_p = parse_pids(run_cmd(["/usr/bin/pgrep", "-x", "-u", CI_USER, "claude"],
                              ok_rcs=(0, 1)))
    if all_p is None or ci_p is None:
        return None
    return len(all_p - ci_p)


def as_ci(argv):
    """Prefix argv to drop root -> ci-runner (D2). No sudoers rule needed as root."""
    return ["sudo", "-n", "-u", CI_USER, "-H"] + list(argv)


def collect_vm_state(limactl, vm_name):
    """running|stopped|broken|unknown|none, same vocabulary as the reporter."""
    if not vm_name:
        return "none"
    names = run_cmd(as_ci([limactl, "list", "--format", "{{.Name}}"]))
    if names is None:
        return "unknown"
    if vm_name not in names.split():
        return "none"
    status = run_cmd(as_ci([limactl, "list", "--format", "{{.Status}}", vm_name]))
    if status is None:
        return "unknown"
    return map_vm_status(status)


def read_pause_marker(marker_dir, machine):
    """State of the XACA-1440 marker <dir>/<machine>.pause.json.

    Returns absent|draining|paused|resuming|corrupt, or None when it cannot
    be determined (field omitted). Validation mirrors _CIH_PY_MARKER in
    scripts/ci-runner/lib/ci-host-lib.sh: schema_version 1, host matches,
    state in the enum, otherwise `corrupt`. Read-only; never writes.
    """
    if not machine or not re.match(r"^[A-Za-z0-9._-]+$", machine):
        return None
    path = os.path.join(marker_dir, machine + ".pause.json")
    try:
        with open(path) as f:
            d = json.load(f)
    except FileNotFoundError:
        return "absent"
    except ValueError:
        return "corrupt"
    except OSError:
        return None
    if (not isinstance(d, dict) or d.get("schema_version") != 1
            or d.get("host") != machine
            or d.get("state") not in ("draining", "paused", "resuming")):
        return "corrupt"
    return d["state"]


# ---------------------------------------------------------------------------
# Cache for the slow collectors (memory_pressure, limactl list)
# ---------------------------------------------------------------------------
class TTLCache(object):
    """Cache a collector result for ttl seconds. Expired entries are
    re-collected; a failed re-collect yields None (field omitted), never the
    old number."""

    def __init__(self, ttl=SLOW_CACHE_TTL, clock=time.monotonic):
        self.ttl = ttl
        self.clock = clock
        self._store = {}

    def get(self, key, fn):
        now = self.clock()
        hit = self._store.get(key)
        if hit is not None and now - hit[0] < self.ttl:
            return hit[1]
        val = fn()
        self._store[key] = (now, val)
        return val


# ---------------------------------------------------------------------------
# Capacity report builder (Contract C3)
# ---------------------------------------------------------------------------
def collect_capacity(config, slots_state, cache=None):
    """Build the C3 poll-request body. Failed collectors omit their field.

    slots_state: list of {"os","index","state","assignmentId"} (owned by the
    supervisor, XACA-1442-003; empty until then). The extra top-level key
    `pauseMarker` reports the XACA-1440 marker for drift detection
    (EPIC-0070 decision 2026-10-06). It is NOT in the C3 example, so the
    server's allowlist must accept it (flagged to XACA-1441).
    """
    cache = cache if cache is not None else TTLCache()
    cap = {}

    def put(key, val):
        if val is not None:
            cap[key] = val

    put("memTotalBytes", collect_mem_total())
    put("memReclaimableBytes", collect_mem_reclaimable())
    put("memFreePct", cache.get("memory_pressure", collect_mem_free_pct))
    swap = collect_swap()
    if swap is not None:
        cap["swapUsedBytes"], cap["swapTotalBytes"] = swap
    load = collect_load()
    if load is not None:
        cap["load1"], cap["load5"], cap["load15"] = load
    put("ncpu", collect_ncpu())
    put("teamSessions", collect_team_sessions())
    put("vmState", cache.get(
        "vmState", lambda: collect_vm_state(config.get("limactl") or DEFAULT_LIMACTL,
                                            config.get("vmName"))))

    report = {
        "schemaVersion": SCHEMA_VERSION,
        "agentVersion": AGENT_VERSION,
        "capacity": cap,
        "slots": [dict(s) for s in (slots_state or [])],
    }
    marker = read_pause_marker(config.get("markerDir") or DEFAULT_MARKER_DIR,
                               config.get("machine"))
    if marker is not None:
        report["pauseMarker"] = marker
    return report



# ---------------------------------------------------------------------------
# XACA-1442-002: pull loop (agent-initiated poll, no inbound port)
# Contract: fleet-monitor/docs/CI-POOL-API-CONTRACT.md on feature/xaca-1441
# (C1-C8 + AS BUILT). Where the plan doc and that copy disagree, that copy wins.
# ---------------------------------------------------------------------------
DEFAULT_KEY_PATH = "/usr/local/etc/ci-pool-agent/agent.key"
HOST_KEY_RE = re.compile(r"^fcp_[A-Za-z0-9_-]{43}$")                  # C1
ASSIGNMENT_ID_RE = re.compile(                                          # server ID_RE
    r"^a_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
REPO_RE = re.compile(r"^[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}$")
RUNNER_NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
OS_VALUES = ("Linux", "macOS")
REPORT_STATES = ("started", "completed", "failed", "cancelled")
MAX_POLL_BYTES = 16 * 1024      # C3 / AS BUILT: over this the server answers 413
MAX_STATE_BYTES = 2 * 1024      # server MAX_STATE_BYTES (not in the plan doc)
MAX_RESPONSE_BYTES = 1024 * 1024
MAX_ASSIGNMENTS = 32
MAX_CANCELS = 256
MAX_JIT_CHARS = 128 * 1024
HTTP_TIMEOUT = 15               # seconds (D8)
POLL_AFTER_DEFAULT = 10
POLL_AFTER_MIN = 5
POLL_AFTER_MAX = 300
BACKOFF_MIN = 10                # D8: network error / 5xx, exponential 10 -> 120
BACKOFF_MAX = 120
UNAUTHORIZED_HOLD = 300         # D8: 401 -> stop polling for 5 min
KEY_RETRY_SECONDS = 30          # bad/missing key file: no request, re-read soon
CONFIG_RETRY_SECONDS = 60
OUTBOX_MAX = 1024

# Result kinds
OK = "ok"
UNAUTHORIZED = "unauthorized"        # 401
BAD_REQUEST = "bad-request"          # 400
TOO_LARGE = "too-large"              # 413
NOT_FOUND = "not-found"              # 404
CONFLICT = "conflict"                # 409
SERVER_ERROR = "server-error"        # 5xx
NETWORK = "network"                  # connect/timeout/TLS/DNS
OTHER = "other"                      # 3xx and anything unexpected
KEY_INVALID = "key-invalid"          # key file unreadable or wrong shape; nothing sent
BAD_CONFIG = "bad-config"            # serverUrl not https (or malformed); nothing sent
LOCAL_TOO_LARGE = "local-too-large"  # body over the cap; nothing sent
BAD_RESPONSE = "bad-response"        # 2xx but failed allowlist validation
TRANSIENT = (SERVER_ERROR, NETWORK, OTHER, UNAUTHORIZED, KEY_INVALID, BAD_CONFIG)


class Result(object):
    """Outcome of one HTTP exchange. `data` is parsed JSON (or the validated
    poll response). Never holds the key."""
    __slots__ = ("kind", "status", "data", "detail")

    def __init__(self, kind, status=None, data=None, detail=""):
        self.kind = kind
        self.status = status
        self.data = data
        self.detail = detail

    def __repr__(self):
        return "Result(%s status=%s)" % (self.kind, self.status)


def _clean(text, limit=120):
    """Server-supplied text for a log line: printable ASCII only, truncated."""
    s = "".join(c if 32 <= ord(c) < 127 else "?" for c in str(text))
    return s[:limit]


def read_key(path=None):
    """Read the per-host key fresh (called every request; rotation needs no
    restart, Requirement 10). Returns the key, or None when unreadable or not
    shaped fcp_<43 base64url> (C1). Never logs the key or any part of it."""
    path = path or DEFAULT_KEY_PATH
    try:
        with open(path) as f:
            raw = f.read(512)
    except (OSError, UnicodeDecodeError):
        log.error("key file unreadable: %s", path)
        return None
    key = raw.strip()
    if not HOST_KEY_RE.match(key):
        log.error("key file %s does not hold a per-host key (fcp_ + 43 chars); "
                  "refusing to poll", path)
        return None
    return key


def validate_server_url(url, allow_insecure=False):
    """Return the normalised base URL, or raise ValueError. https only (C1);
    `allow_insecure` exists for the unit tests and is never read from config."""
    if not isinstance(url, str) or not url.strip():
        raise ValueError("serverUrl missing")
    p = urllib.parse.urlsplit(url.strip())
    schemes = ("https", "http") if allow_insecure else ("https",)
    if p.scheme not in schemes or not p.hostname:
        raise ValueError("serverUrl must be https://host[/prefix]")
    if p.username or p.password or p.query or p.fragment:
        raise ValueError("serverUrl must not carry credentials, query or fragment")
    return urllib.parse.urlunsplit((p.scheme, p.netloc, p.path.rstrip("/"), "", ""))


def build_poll_body(report, send_pause_marker=False):
    """C3 body from collect_capacity()'s report.

    `pauseMarker` is collected for drift logging but is NOT in the C3 contract
    and the XACA-1441 server answers 400 to any unknown field (the machine
    would then read stale and ineligible). It is therefore dropped unless
    agent.json sets "sendPauseMarker": true. OPEN CONTRACT QUESTION: XACA-1441
    must add `pauseMarker` to its allowlist (validatePoll) before that flag is
    safe to turn on.
    """
    body = dict(report)
    if not send_pause_marker:
        body.pop("pauseMarker", None)
    return body


# -- response validation (C4), allowlist copy ---------------------------------
class Assignment(object):
    """One validated C4 assignment. repr/str never include the JIT config:
    `jit_config` is an opaque credential, held in memory only, dropped by the
    supervisor once the listener is started."""
    __slots__ = ("id", "os", "runner_name", "labels", "repo", "intended_job",
                 "jit_config", "start_by", "job_bind_timeout")

    def __repr__(self):
        return "Assignment(id=%s os=%s runner=%s)" % (self.id, self.os, self.runner_name)


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and v == v


def _is_str(v, lo=0, hi=1024):
    return isinstance(v, str) and lo <= len(v) <= hi


def _validate_assignment(a):
    """Return an Assignment or None. Only known fields are copied."""
    if not isinstance(a, dict):
        return None
    if not (isinstance(a.get("id"), str) and ASSIGNMENT_ID_RE.match(a["id"])):
        return None
    if a.get("os") not in OS_VALUES:
        return None
    if not (isinstance(a.get("runnerName"), str) and RUNNER_NAME_RE.match(a["runnerName"])):
        return None
    if not (isinstance(a.get("repo"), str) and REPO_RE.match(a["repo"])):
        return None
    labels = a.get("labels")
    if not (isinstance(labels, list) and 0 < len(labels) <= 32
            and all(_is_str(x, 1, 64) and all(32 <= ord(c) < 127 for c in x)
                    for x in labels)):
        return None
    jit = a.get("jitConfig")
    if not _is_str(jit, 1, MAX_JIT_CHARS):
        return None
    job = a.get("intendedJob")
    intended = None
    if job is not None:
        if not isinstance(job, dict):
            return None
        intended = {}
        if "id" in job:
            if not _is_int(job["id"]):
                return None
            intended["id"] = job["id"]
        if "runId" in job and job["runId"] is not None:
            if not _is_int(job["runId"]):
                return None
            intended["runId"] = job["runId"]
        if "name" in job and job["name"] is not None:
            if not _is_str(job["name"], 0, 256):
                return None
            intended["name"] = job["name"]
    start_by = a.get("startBy")
    if start_by is not None and not _is_str(start_by, 0, 64):
        return None
    bind = a.get("jobBindTimeoutSeconds")
    if bind is not None and not _is_int(bind):
        return None
    out = Assignment()
    out.id, out.os, out.runner_name = a["id"], a["os"], a["runnerName"]
    out.repo, out.labels, out.intended_job = a["repo"], list(labels), intended
    out.jit_config, out.start_by, out.job_bind_timeout = jit, start_by, bind
    return out


def validate_response(data):
    """C4 allowlist validation. Returns a fresh dict of known fields, or None
    (reject the WHOLE response) on any type error. Unknown fields are ignored
    (C8: additive optional fields do not bump the version)."""
    if not isinstance(data, dict):
        return None
    sv = data.get("schemaVersion")
    if not _is_int(sv) or sv != SCHEMA_VERSION:
        return None
    if not isinstance(data.get("enabled"), bool) or not isinstance(data.get("paused"), bool):
        return None
    reason = data.get("pauseReason")
    if reason is not None and not isinstance(reason, str):
        return None
    after = data.get("pollAfterSeconds", POLL_AFTER_DEFAULT)
    if not _is_num(after):
        return None
    raw_assign, raw_cancel = data.get("assignments"), data.get("cancel")
    if not isinstance(raw_assign, list) or len(raw_assign) > MAX_ASSIGNMENTS:
        return None
    if not isinstance(raw_cancel, list) or len(raw_cancel) > MAX_CANCELS:
        return None
    assignments = []
    for a in raw_assign:
        v = _validate_assignment(a)
        if v is None:
            return None
        assignments.append(v)
    cancel = []
    for c in raw_cancel:
        if not (isinstance(c, str) and ASSIGNMENT_ID_RE.match(c)):
            return None
        cancel.append(c)
    return {
        "enabled": data["enabled"],
        "paused": data["paused"],
        "pauseReason": _clean(reason, 200) if reason is not None else None,
        "pollAfterSeconds": clamp_poll_after(after),
        "assignments": assignments,
        "cancel": cancel,
    }


def clamp_poll_after(v):
    if not _is_num(v):
        return float(POLL_AFTER_DEFAULT)
    return max(float(POLL_AFTER_MIN), min(float(POLL_AFTER_MAX), float(v)))


# -- HTTP ------------------------------------------------------------------------
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect: the bearer key must go to serverUrl and nowhere
    else (urllib would replay the headers to the redirect target)."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def build_opener(allow_insecure=False):
    handlers = [_NoRedirect(), urllib.request.HTTPSHandler(context=ssl.create_default_context())]
    if allow_insecure:                       # tests: loopback fake server, ignore env proxies
        handlers.append(urllib.request.ProxyHandler({}))
    return urllib.request.build_opener(*handlers)


def _classify(status):
    if 200 <= status < 300:
        return OK
    return {401: UNAUTHORIZED, 400: BAD_REQUEST, 413: TOO_LARGE,
            404: NOT_FOUND, 409: CONFLICT}.get(status, SERVER_ERROR if status >= 500 else OTHER)


def _post(config, path, payload, max_bytes, allow_insecure=False, opener=None,
          timeout=HTTP_TIMEOUT):
    """POST JSON to serverUrl+path with the per-host key. The Authorization
    header is built here, in process: the key is never in argv."""
    try:
        base = validate_server_url(config.get("serverUrl"), allow_insecure)
    except ValueError as e:
        return Result(BAD_CONFIG, detail=str(e))
    key = read_key(config.get("keyPath") or DEFAULT_KEY_PATH)
    if key is None:
        return Result(KEY_INVALID)
    data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    if len(data) > max_bytes:
        log.error("refusing to send %s: body %d bytes exceeds %d", path, len(data), max_bytes)
        return Result(LOCAL_TOO_LARGE)
    req = urllib.request.Request(
        base + path, data=data, method="POST",
        headers={"Authorization": "Bearer " + key,
                 "Content-Type": "application/json", "Accept": "application/json"})
    opener = opener or build_opener(allow_insecure)
    try:
        try:
            with opener.open(req, timeout=timeout) as resp:
                status, raw = resp.status, resp.read(MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as e:
            status = e.code
            try:
                raw = e.read(MAX_RESPONSE_BYTES + 1)
            except (OSError, http.client.HTTPException):
                raw = b""
            e.close()
    except (urllib.error.URLError, OSError, http.client.HTTPException, ValueError) as e:
        # only the exception class is kept: reason text can echo URLs
        return Result(NETWORK, detail=type(e).__name__)
    if len(raw) > MAX_RESPONSE_BYTES:
        return Result(SERVER_ERROR, status, detail="response too large")
    try:
        parsed = json.loads(raw.decode("utf-8")) if raw else None
    except (ValueError, UnicodeDecodeError):
        parsed = None
    kind = _classify(status)
    if kind == OK and parsed is None:
        return Result(BAD_RESPONSE, status, detail="unparseable body")
    return Result(kind, status, parsed)


def poll(config, body, allow_insecure=False, opener=None):
    """POST /api/ci-pool/agent/poll. On OK, `data` is the validate_response()
    dict; a response that fails validation is BAD_RESPONSE (whole thing rejected)."""
    res = _post(config, "/api/ci-pool/agent/poll", body, MAX_POLL_BYTES,
                allow_insecure, opener)
    if res.kind != OK:
        return res
    valid = validate_response(res.data)
    if valid is None:
        return Result(BAD_RESPONSE, res.status, detail="response failed validation")
    return Result(OK, res.status, valid)


def _check_report(assignment_id, to, fields):
    """Return the cleaned body dict, or None when invalid."""
    if not (isinstance(assignment_id, str) and ASSIGNMENT_ID_RE.match(assignment_id)):
        return None
    if to not in REPORT_STATES:
        return None
    body = {"state": to}
    for k, v in fields.items():
        if k == "exitCode":
            if not _is_int(v) or not -255 <= v <= 255:
                return None
            body["exitCode"] = v
        elif k == "reason":
            if not isinstance(v, str):
                return None
            body["reason"] = v[:200]
        else:
            return None                      # server rejects unknown fields
    return body


def report_state(config, assignment_id, to, allow_insecure=False, opener=None, **fields):
    """POST /api/ci-pool/assignments/:id/state. The id is validated against the
    server's id pattern BEFORE it goes into the URL path."""
    body = _check_report(assignment_id, to, fields)
    if body is None:
        return Result(BAD_REQUEST, detail="invalid report")
    return _post(config, "/api/ci-pool/assignments/%s/state" % assignment_id, body,
                 MAX_STATE_BYTES, allow_insecure, opener)


# -- outbox: durable-in-memory retry of state reports ---------------------------------
class Outbox(object):
    """Pending lifecycle reports. A report stays queued until the server
    acknowledges it (2xx) or answers something a retry cannot fix (400/404/409/
    413). Network, 5xx and auth failures keep it queued. The server is
    idempotent (C5), so a duplicate delivery is harmless.

    The queue lives in MEMORY ONLY (XACA-1442-016). If the agent restarts while a
    report is queued, it is lost: the slot was already reset to `idle` and
    slots.json holds no outcome for it. The server does NOT reconcile from the
    poll body's slots[]; it recovers only through its own assignment timeouts
    (contract C5: delivered 120 s -> expired, started + no job 300 s ->
    cancelled, running 375 min -> lost, each with a registration DELETE, and a
    late `completed`/`failed` is still accepted). See docs/ci-runner-runbook.md
    section 12 "Known limits". Persisting this queue (no secrets in it) is the
    follow-up that would close the gap."""

    def __init__(self, maxlen=OUTBOX_MAX):
        self.maxlen = maxlen
        self._items = []

    def __len__(self):
        return len(self._items)

    def pending(self):
        return [(i["id"], i["to"]) for i in self._items]

    def add(self, assignment_id, to, **fields):
        body = _check_report(assignment_id, to, fields)
        if body is None:
            log.error("dropping invalid state report (id=%s to=%s)", _clean(assignment_id, 80),
                      _clean(to, 20))
            return False
        for it in self._items:
            if it["id"] == assignment_id and it["to"] == to:
                return True                  # already queued
        if len(self._items) >= self.maxlen:
            dropped = self._items.pop(0)
            log.error("outbox full; dropping oldest report id=%s to=%s",
                      dropped["id"], dropped["to"])
        self._items.append({"id": assignment_id, "to": to, "fields": dict(fields)})
        return True

    def drain(self, send):
        """send(id, to, fields) -> Result. Stops at the first transient failure
        so ordering is preserved. Returns the number delivered or settled."""
        settled = 0
        for it in list(self._items):
            res = send(it["id"], it["to"], it["fields"])
            if res.kind in TRANSIENT:
                break
            if res.kind == OK:
                log.info("reported id=%s state=%s", it["id"], it["to"])
            else:
                log.warning("report id=%s state=%s not retried: %s %s", it["id"], it["to"],
                            res.kind, res.status)
            self._items.remove(it)
            settled += 1
        return settled


# -- supervisor interface (XACA-1442-003 implements it) --------------------------------
class Supervisor(object):
    """What run_loop needs from the job supervisor. The reporter is injected so
    the supervisor can queue lifecycle reports (`self.report(id, to, **f)`)."""

    def __init__(self):
        self.report = lambda assignment_id, to, **fields: False

    def bind_reporter(self, fn):
        self.report = fn

    def adopt_on_start(self):                # called once before the first poll
        raise NotImplementedError

    def slots_state(self):                   # list of C3 slot dicts
        raise NotImplementedError

    def start(self, assignment):             # one validated Assignment
        raise NotImplementedError

    def cancel(self, assignment_id):         # kill an unbound listener, report `cancelled`
        raise NotImplementedError

    def reap(self):                          # observe finished jobs, report completed/failed
        raise NotImplementedError


class NoSlotSupervisor(Supervisor):  # kept for tests and as a no-slots fallback
    """Stand-in until the real supervisor lands: it owns no slots, so it reports
    no slots and fails every assignment `no-slot` (plan: the server then expires
    and re-places it). Drops the JIT config immediately."""

    def adopt_on_start(self):
        return []

    def slots_state(self):
        return []

    def start(self, assignment):
        self.report(assignment.id, "failed", reason="no-slot")

    def cancel(self, assignment_id):
        self.report(assignment_id, "cancelled")

    def reap(self):
        return None


# -- XACA-1442-003: the real slot supervisor ------------------------------------------
DEFAULT_STATE_PATH = "/usr/local/var/ci-pool-agent/slots.json"
LINUX_JIT_SCRIPT = "/usr/local/sbin/ci-runner-jit.sh"          # in the Lima guest
MAC_JIT_SCRIPT = "/usr/local/libexec/ci-runner-jit-macos.sh"   # on the host
JIT_NAME_RE = re.compile(r"^fcp-[a-z0-9-]{1,40}$")             # the scripts' own rule
SLOT_STATES = ("idle", "starting", "busy", "cleaning", "broken")
START_TIMEOUT = 90                # seconds: limactl shell + extract + systemd-run
CLEAN_TIMEOUT = 60
STATUS_TIMEOUT = 30
TERM_GRACE = 30.0                 # D5: SIGTERM, then SIGKILL after 30 s
KILL_GIVE_UP = 60.0               # still alive this long after SIGKILL -> broken
STATE_FIELDS = ("os", "index", "state", "assignmentId", "runnerName", "startedAt",
                "pid", "pgid", "termAt", "outcome")
_STATUS_LINE_RE = re.compile(
    r"^slot=(\d{1,2}) unit=(active|failed|exited|lost|none) exit=(-|\d{1,3}) dir=(yes|no)$")


def run_with_input(argv, stdin_text, timeout):
    """Run argv (list, never a shell) feeding `stdin_text` on stdin. This is
    the ONLY way a JIT config leaves agent memory for a Linux runner. Returns
    (rc, stdout) or (None, "") when the process could not be run or timed out.
    stdout/stderr are discarded for the start call: nothing here may echo it."""
    if not isinstance(argv, (list, tuple)):
        raise TypeError("argv must be a list")
    try:
        p = subprocess.run(list(argv), input=stdin_text, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=timeout,
                           universal_newlines=True)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None, ""
    return p.returncode, p.stdout


def _clamp_exit(n):
    return max(-255, min(255, int(n)))


def parse_slot_status(text):
    """Guest `ci-runner-jit.sh status` output -> {slot: (unit, exit|None, has_dir)}.
    Lines that do not match exactly are ignored (never guessed at)."""
    out = {}
    for line in (text or "").splitlines():
        m = _STATUS_LINE_RE.match(line.strip())
        if not m:
            continue
        out[int(m.group(1))] = (m.group(2), None if m.group(3) == "-" else int(m.group(3)),
                                m.group(4) == "yes")
    return out


class SlotSupervisor(Supervisor):
    """Owns the host's CI slots: starts one-job runners, watches them, cleans up.

    Slots come from agent.json linuxSlots / macSlots. Per-slot state is
    idle | starting | busy | cleaning | broken (Contract C3) and is persisted,
    WITHOUT secrets, to slots.json (0600, atomic) so a restart can re-adopt
    running jobs (Requirement 11).

    A `broken` slot (cleanup failed) takes no work until the operator clears
    it: delete that slot's entry from slots.json (or the whole file when
    nothing runs). It is noticed within one poll, no restart needed.

    The JIT config is held in a local variable for the duration of start() and
    then dropped; it is passed ONLY on a child's stdin.
    """

    def __init__(self, config, state_path=None, clock=time.time):
        Supervisor.__init__(self)
        self.cfg = config
        self.limactl = config.get("limactl") or DEFAULT_LIMACTL
        self.vm = config.get("vmName") or ""
        self.state_path = state_path or config.get("statePath") or DEFAULT_STATE_PATH
        self.clock = clock
        self.slots = {}
        self.procs = {}                     # (os, index) -> Popen (this process's own children)
        self._adopt_pending = False
        for os_name, count in (("Linux", config.get("linuxSlots", 0)),
                               ("macOS", config.get("macSlots", 0))):
            for i in range(1, int(count or 0) + 1):
                self.slots[(os_name, i)] = self._blank(os_name, i)

    # -- state ---------------------------------------------------------------------
    @staticmethod
    def _blank(os_name, index):
        return {"os": os_name, "index": index, "state": "idle", "assignmentId": None,
                "runnerName": None, "startedAt": None, "pid": None, "pgid": None,
                "termAt": None, "outcome": None}

    def _reset(self, slot):
        slot.update(self._blank(slot["os"], slot["index"]))
        self.procs.pop((slot["os"], slot["index"]), None)

    def slots_state(self):
        out = []
        for key in sorted(self.slots, key=lambda k: (k[0] != "Linux", k[1])):
            s = self.slots[key]
            bound = s["state"] in ("starting", "busy", "cleaning")
            out.append({"os": s["os"], "index": s["index"], "state": s["state"],
                        "assignmentId": s["assignmentId"] if bound else None})
        return out

    def _save(self):
        entries = {}
        for (os_name, i), s in self.slots.items():
            if s["state"] != "idle":
                entries["%s-%d" % (os_name, i)] = {k: s[k] for k in STATE_FIELDS
                                                   if s.get(k) is not None}
        tmp = "%s.tmp.%d" % (self.state_path, os.getpid())
        try:
            os.makedirs(os.path.dirname(self.state_path), mode=0o700, exist_ok=True)
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump({"version": 1, "slots": entries}, f, sort_keys=True)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, self.state_path)
        except OSError as e:
            log.error("cannot persist slot state: %s", type(e).__name__)

    def _load(self):
        """{ 'Linux-1': entry } ({} when absent), or None when unreadable. A
        corrupt file is set aside (never silently dropped) and reads as None."""
        try:
            with open(self.state_path) as f:
                raw = json.load(f)
        except FileNotFoundError:
            return {}
        except (OSError, ValueError):
            try:
                os.replace(self.state_path, self.state_path + ".corrupt")
                log.error("slots.json unreadable; moved aside to slots.json.corrupt")
            except OSError:
                log.error("slots.json unreadable")
            return None
        slots = raw.get("slots") if isinstance(raw, dict) else None
        return slots if isinstance(slots, dict) else None

    @staticmethod
    def _valid_entry(key, e):
        if not isinstance(e, dict) or e.get("os") not in OS_VALUES:
            return False
        idx = e.get("index")
        if not _is_int(idx) or not 1 <= idx <= 99 or key != "%s-%d" % (e["os"], idx):
            return False
        if e.get("state") not in SLOT_STATES or e["state"] == "idle":
            return False
        aid_ = e.get("assignmentId")
        if aid_ is not None and not (isinstance(aid_, str) and ASSIGNMENT_ID_RE.match(aid_)):
            return False
        name = e.get("runnerName")
        if name is not None and not (isinstance(name, str) and JIT_NAME_RE.match(name)):
            return False
        for k in ("pid", "pgid"):
            if e.get(k) is not None and not _is_int(e[k]):
                return False
        for k in ("startedAt", "termAt"):
            if e.get(k) is not None and not _is_num(e[k]):
                return False
        out = e.get("outcome")
        if out is not None:
            if not (isinstance(out, dict) and out.get("to") in REPORT_STATES
                    and isinstance(out.get("fields", {}), dict)):
                return False
        return True

    # -- command builders (argv only; the JIT config never appears in one) ---------
    def _guest(self, *args):
        return as_ci([self.limactl, "shell", "--workdir", "/tmp", self.vm, "--",
                      "sudo", "-n", LINUX_JIT_SCRIPT] + [str(a) for a in args])

    @staticmethod
    def _mac(*args):
        return as_ci([MAC_JIT_SCRIPT] + [str(a) for a in args])

    # -- start -----------------------------------------------------------------------
    def _idle_slot(self, os_name):
        for key in sorted(self.slots):
            if key[0] == os_name and self.slots[key]["state"] == "idle":
                return self.slots[key]
        return None

    def start(self, assignment):
        a = assignment
        jit, a.jit_config = a.jit_config, None      # the Assignment never keeps it
        try:
            self._start(a, jit)
        finally:
            jit = None

    def _start(self, a, jit):
        for s in self.slots.values():
            if s["assignmentId"] == a.id and s["state"] != "idle":
                log.warning("assignment id=%s already bound to a slot; ignoring", a.id)
                return
        if not JIT_NAME_RE.match(a.runner_name):
            log.error("assignment id=%s runner name not accepted by the slot scripts", a.id)
            self.report(a.id, "failed", reason="bad-runner-name")
            return
        slot = self._idle_slot(a.os)
        if slot is None:
            self.report(a.id, "failed", reason="no-slot")
            return
        slot.update(state="starting", assignmentId=a.id, runnerName=a.runner_name,
                    startedAt=None, pid=None, pgid=None, termAt=None, outcome=None)
        self._save()
        ok = self._start_linux(slot, jit) if a.os == "Linux" else self._start_mac(slot, jit)
        if ok:
            slot.update(state="busy", startedAt=self.clock())
            self._save()
            log.info("slot %s-%d started id=%s runner=%s", slot["os"], slot["index"],
                     a.id, a.runner_name)
            self.report(a.id, "started")
        else:
            log.error("slot %s-%d failed to start id=%s", slot["os"], slot["index"], a.id)
            self._begin_cleanup(slot, "failed", reason="start-failed")

    def _start_linux(self, slot, jit):
        if not self.vm:
            return False
        argv = self._guest("start", slot["index"], slot["runnerName"])
        rc, _ = run_with_input(argv, jit + "\n", START_TIMEOUT)
        return rc == 0

    def _start_mac(self, slot, jit):
        argv = self._mac("start", slot["index"], slot["runnerName"])
        try:
            proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL, start_new_session=True,
                                    close_fds=True)
        except (OSError, ValueError):
            return False
        try:
            proc.stdin.write((jit + "\n").encode("utf-8"))
            proc.stdin.close()
        except (OSError, ValueError):
            self._kill_and_reap(proc)
            return False
        try:
            pgid = os.getpgid(proc.pid)
        except OSError:
            pgid = proc.pid
        slot["pid"], slot["pgid"] = proc.pid, pgid
        self.procs[(slot["os"], slot["index"])] = proc
        return True

    @staticmethod
    def _kill_and_reap(proc):
        """Kill our own child AND wait() on it: an unreaped child is a zombie
        (XACA-1442-012). Best effort; never raises."""
        try:
            proc.kill()
        except OSError:
            pass
        try:
            proc.wait(timeout=5)
        except (OSError, subprocess.SubprocessError):
            pass

    def _reap_leader(self, slot):
        """Collect the exit status of our own macOS leader (the `sudo` Popen
        child), if we have one. A child that died stays a zombie, and a zombie
        is still a member of its process group, until somebody wait()s on it;
        `killpg(pgid, 0)` then reads the group alive for ever (XACA-1442-012).
        Safe to call any number of times. Adopted pids are not our children:
        launchd reaps those, so there is nothing to collect."""
        proc = self.procs.get((slot["os"], slot["index"]))
        if proc is None:
            return None
        try:
            return proc.poll()
        except OSError:
            return None

    # -- cancel ----------------------------------------------------------------------
    def cancel(self, assignment_id):
        for s in self.slots.values():
            if s["assignmentId"] == assignment_id and s["state"] in ("starting", "busy"):
                log.info("cancelling listener id=%s slot %s-%d", assignment_id, s["os"],
                         s["index"])
                self._begin_cleanup(s, "cancelled")
                return
            if s["assignmentId"] == assignment_id and s["state"] == "cleaning":
                return                       # already on its way out; it reports itself
        # nothing to kill: acknowledge so the server stops listing the id (A4)
        self.report(assignment_id, "cancelled")

    # -- observe + clean up ----------------------------------------------------------
    def reap(self):
        self._reload_broken()
        if self._adopt_pending:
            self._adopt_linux()
        self._reap_linux()
        self._reap_mac()
        for key in sorted(self.slots):
            if self.slots[key]["state"] == "cleaning":
                self._drive(self.slots[key])

    def _reload_broken(self):
        broken = [s for s in self.slots.values() if s["state"] == "broken"]
        if not broken:
            return
        disk = self._load()
        if disk is None:
            return                           # unreadable: never clear on a guess
        cleared = False
        for s in broken:
            e = disk.get("%s-%d" % (s["os"], s["index"]))
            if not isinstance(e, dict) or e.get("state") != "broken":
                log.warning("slot %s-%d cleared by operator", s["os"], s["index"])
                self._reset(s)
                cleared = True
        if cleared:
            self._save()

    def _linux_status(self, slots):
        argv = self._guest("status", *[s["index"] for s in slots])
        text = run_cmd(argv, timeout=STATUS_TIMEOUT)
        return None if text is None else parse_slot_status(text)

    def _reap_linux(self):
        busy = [s for k, s in sorted(self.slots.items()) if k[0] == "Linux"
                and s["state"] == "busy"]
        if not busy or self._adopt_pending:
            return
        status = self._linux_status(busy)
        if status is None:
            log.warning("guest status unavailable; leaving %d slot(s) as they are", len(busy))
            return
        for s in busy:
            got = status.get(s["index"])
            if got is None:
                continue
            unit, code, _has_dir = got
            if unit == "active":
                continue
            if unit == "exited":
                self._begin_cleanup(s, "completed", exitCode=0)
            elif unit == "lost":
                # XACA-1442-014: the runner died without a clean exit (VM reboot,
                # SIGTERM stop). `completed` would skip the server's registration
                # DELETE; `failed` is the truthful state the contract accepts.
                self._begin_cleanup(s, "failed", reason="runner-lost")
            elif unit == "failed" and code is not None:
                self._begin_cleanup(s, "failed" if code else "completed",
                                    exitCode=_clamp_exit(code))
            elif unit == "failed":
                self._begin_cleanup(s, "failed", reason="exit-unknown")
            else:
                self._begin_cleanup(s, "failed", reason="slot-vanished")

    def _reap_mac(self):
        for key in sorted(self.slots):
            s = self.slots[key]
            if key[0] != "macOS" or s["state"] != "busy":
                continue
            proc = self.procs.get(key)
            if proc is not None:
                rc = proc.poll()
                if rc is None:
                    continue
                if rc == 0:
                    self._begin_cleanup(s, "completed", exitCode=0)
                else:
                    self._begin_cleanup(s, "failed", exitCode=_clamp_exit(rc))
            elif self._pid_matches(s):
                continue
            else:
                # adopted job that ended while we could not wait on it: no exit code
                self._begin_cleanup(s, "completed", reason="exit-unknown (adopted)")

    def _pid_matches(self, slot):
        """pid alive AND its command line is our macOS start script for this
        runner name (guards against pid reuse after a restart/reboot)."""
        if not _is_int(slot.get("pid")) or slot["pid"] <= 1:
            return False
        text = run_cmd(["/bin/ps", "-o", "command=", "-p", str(slot["pid"])])
        return bool(text and "ci-runner-jit-macos.sh" in text
                    and slot.get("runnerName") and slot["runnerName"] in text)

    def _begin_cleanup(self, slot, to, **fields):
        slot.update(state="cleaning", termAt=None,
                    outcome={"to": to, "fields": fields})
        self._save()
        self._drive(slot)

    def _group_ours_and_alive(self, slot):
        """True while the macOS job's process group still has members that are
        provably ours: this process spawned it, or the recorded pid is still
        our start script. NEVER a user-wide sweep (pkill -u ci-runner)."""
        key = (slot["os"], slot["index"])
        pgid = slot.get("pgid")
        if not _is_int(pgid) or pgid <= 1 or pgid == os.getpgrp():
            return False
        if key not in self.procs and not self._pid_matches(slot):
            return False
        # Reap our own leader BEFORE probing: a dead-but-unreaped leader keeps
        # the group "alive" (EPERM on macOS, success as root). After this,
        # EPERM can only mean a live member we may not signal: treat it as
        # alive (the safe direction: keep signalling, never clean under a job).
        self._reap_leader(slot)
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return False
        except OSError:
            return True
        return True

    def _signal_group(self, slot, sig):
        try:
            os.killpg(slot["pgid"], sig)
        except OSError:
            pass

    def _drive(self, slot):
        """Advance a `cleaning` slot as far as it can go without blocking."""
        if slot["os"] == "Linux":
            ok = False
            if self.vm:
                extra = [slot["runnerName"]] if slot["runnerName"] else []
                ok = run_cmd(self._guest("clean", slot["index"], *extra),
                             timeout=CLEAN_TIMEOUT) is not None
            self._finish(slot, ok)
            return
        now = self.clock()
        self._reap_leader(slot)              # even when the group probe is skipped
        if self._group_ours_and_alive(slot):
            if slot["termAt"] is None:
                self._signal_group(slot, signal.SIGTERM)
                slot["termAt"] = now
                self._save()
            elif now - slot["termAt"] >= TERM_GRACE + KILL_GIVE_UP:
                log.error("slot %s-%d: process group survived SIGKILL", slot["os"], slot["index"])
                self._finish(slot, False)
            elif now - slot["termAt"] >= TERM_GRACE:
                self._signal_group(slot, signal.SIGKILL)
            return
        ok = run_cmd(self._mac("clean", slot["index"]), timeout=CLEAN_TIMEOUT) is not None
        self._finish(slot, ok)

    def _finish(self, slot, ok):
        outcome, aid_ = slot["outcome"], slot["assignmentId"]
        if outcome and aid_:
            self.report(aid_, outcome["to"], **outcome.get("fields", {}))
        if ok:
            log.info("slot %s-%d cleaned", slot["os"], slot["index"])
            self._reset(slot)
        else:
            log.error("slot %s-%d cleanup FAILED: marked broken; clear it by deleting its "
                      "entry from %s", slot["os"], slot["index"], self.state_path)
            slot.update(state="broken", outcome=None, termAt=None)
            self.procs.pop((slot["os"], slot["index"]), None)
        self._save()

    # -- adoption after an agent restart (D6) ----------------------------------------
    def adopt_on_start(self):
        data = self._load()
        if not data:
            return []
        adopted = []
        for key, e in sorted(data.items()):
            if not self._valid_entry(key, e):
                log.error("slots.json: ignoring invalid entry %s", _clean(key, 20))
                continue
            slot = self.slots.get((e["os"], e["index"]))
            if slot is None:
                slot = self._blank(e["os"], e["index"])
                self.slots[(e["os"], e["index"])] = slot
            slot.update({k: e.get(k) for k in STATE_FIELDS})
            adopted.append(slot)
        for s in adopted:
            if s["os"] == "macOS" and s["state"] in ("starting", "busy"):
                self._adopt_verdict(s, self._pid_matches(s))
        self._adopt_linux()
        for s in adopted:
            if s["state"] == "cleaning":
                self._drive(s)
        self._save()
        return [dict(s) for s in adopted]

    def _adopt_linux(self):
        pending = [s for k, s in sorted(self.slots.items()) if k[0] == "Linux"
                   and s["state"] in ("starting", "busy")]
        if not pending:
            self._adopt_pending = False
            return
        status = self._linux_status(pending)
        if status is None:
            if not self._adopt_pending:
                log.warning("guest unreachable at start; adoption of %d Linux slot(s) deferred",
                            len(pending))
            self._adopt_pending = True
            return
        self._adopt_pending = False
        for s in pending:
            got = status.get(s["index"])
            self._adopt_verdict(s, got is not None and got[0] == "active")
        self._save()

    def _adopt_verdict(self, slot, live):
        if live:
            if slot["state"] == "starting":
                slot["state"] = "busy"
                if slot["startedAt"] is None:
                    slot["startedAt"] = self.clock()
                self.report(slot["assignmentId"], "started")   # was never confirmed
            log.info("adopted slot %s-%d id=%s", slot["os"], slot["index"], slot["assignmentId"])
            return
        log.warning("slot %s-%d lost across restart id=%s", slot["os"], slot["index"],
                    slot["assignmentId"])
        slot.update(state="cleaning", termAt=None,
                    outcome={"to": "failed", "fields": {"reason": "agent-restart-lost"}})


# -- the loop --------------------------------------------------------------------
class Backoff(object):
    """Exponential 10 -> 120 s with +/-20% jitter, hard-capped at 120."""

    def __init__(self, rand=random.random):
        self.rand = rand
        self.n = 0

    def next(self):
        raw = BACKOFF_MIN * (2 ** self.n)
        if raw < BACKOFF_MAX:
            self.n += 1
        return min(float(BACKOFF_MAX), min(BACKOFF_MAX, raw) * (0.8 + 0.4 * self.rand()))

    def reset(self):
        self.n = 0


class StopFlag(object):
    def __init__(self):
        self._set = False

    def set(self):
        self._set = True

    def is_set(self):
        return self._set


def _interruptible_sleep(seconds, stop, tick=1.0):
    """time.sleep that notices SIGTERM within `tick` seconds."""
    end = time.monotonic() + seconds
    while not stop.is_set():
        left = end - time.monotonic()
        if left <= 0:
            return
        time.sleep(min(tick, left))


class PollLoop(object):
    """One iteration = reap -> collect -> poll -> obey -> drain; step() returns
    the number of seconds to sleep."""

    def __init__(self, config, supervisor, outbox=None, rand=random.random,
                 allow_insecure=False, opener=None, cache=None):
        self.config = config
        self.sup = supervisor
        self.outbox = outbox if outbox is not None else Outbox()
        self.backoff = Backoff(rand)
        self.allow_insecure = allow_insecure
        self.opener = opener
        self.cache = cache if cache is not None else TTLCache()
        self.poll_after = float(POLL_AFTER_DEFAULT)
        self._last_kind = None
        self._last_marker = None
        self._last_control = None
        self.sup.bind_reporter(self.outbox.add)

    def _note(self, kind, level, msg, *args):
        """Log on a change of outcome only, so a dead server is not 8,000 lines/day."""
        if kind != self._last_kind:
            log.log(level, msg, *args)
        self._last_kind = kind

    def _guard(self, what, fn, *args):
        try:
            return fn(*args)
        except Exception as e:                          # a supervisor bug must not kill the loop
            log.error("%s failed: %s", what, type(e).__name__)
            return None

    def step(self):
        self._guard("reap", self.sup.reap)
        slots = self._guard("slots_state", self.sup.slots_state) or []
        report = collect_capacity(self.config, slots, self.cache)
        marker = report.get("pauseMarker")
        if marker != self._last_marker:
            log.info("pause marker: %s", marker)
            self._last_marker = marker
        body = build_poll_body(report, self.config.get("sendPauseMarker") is True)
        res = poll(self.config, body, self.allow_insecure, self.opener)
        delay = self._handle(res)
        if res.kind not in (UNAUTHORIZED, KEY_INVALID, BAD_CONFIG):
            self.outbox.drain(lambda i, t, f: report_state(
                self.config, i, t, self.allow_insecure, self.opener, **f))
        return delay

    def _handle(self, res):
        k = res.kind
        if k == OK:
            self.backoff.reset()
            self._note(OK, logging.INFO, "poll ok")
            self.poll_after = res.data["pollAfterSeconds"]
            self._apply(res.data)
            return self.poll_after
        if k == UNAUTHORIZED:
            log.error("key rejected (401); holding polling for %ds, running jobs untouched",
                      UNAUTHORIZED_HOLD)
            self._last_kind = k
            return UNAUTHORIZED_HOLD
        if k == KEY_INVALID:
            self._last_kind = k
            return KEY_RETRY_SECONDS
        if k == BAD_CONFIG:
            self._note(k, logging.ERROR, "bad config: %s", _clean(res.detail))
            return CONFIG_RETRY_SECONDS
        if k in (BAD_REQUEST, TOO_LARGE, LOCAL_TOO_LARGE, BAD_RESPONSE):
            # keep polling at the normal cadence, start nothing (D8, C8)
            msg = ""
            if isinstance(res.data, dict) and "error" in res.data:
                msg = _clean(res.data["error"])
            self._note(k, logging.ERROR, "poll refused or unusable (%s %s) %s", k, res.status, msg)
            return self.poll_after
        delay = self.backoff.next()
        self._note(k, logging.WARNING, "poll failed (%s %s %s); backing off %.0fs",
                   k, res.status, _clean(res.detail, 40), delay)
        return delay

    def _apply(self, resp):
        control = (resp["enabled"], resp["paused"], resp["pauseReason"])
        if control != self._last_control:
            log.info("control: enabled=%s paused=%s reason=%s", *control)
            self._last_control = control
        for cid in resp["cancel"]:
            log.info("cancel requested id=%s", cid)
            self._guard("cancel", self.sup.cancel, cid)
        runnable = resp["enabled"] and not resp["paused"]
        for a in resp["assignments"]:
            if not runnable:
                # Contract says this list is empty when paused/disabled. If it is not,
                # start NOTHING; fail the assignment so the server frees it.
                log.warning("assignment id=%s received while paused/disabled; not started", a.id)
                self.outbox.add(a.id, "failed", reason="agent-paused")
                continue
            log.info("assignment id=%s os=%s runner=%s", a.id, a.os, a.runner_name)
            try:
                self.sup.start(a)
            except Exception as e:
                log.error("start id=%s failed: %s", a.id, type(e).__name__)
                self.outbox.add(a.id, "failed", reason="start-error")


def run_loop(config, supervisor, stop=None, sleep=None, rand=random.random,
             allow_insecure=False, opener=None, cache=None, outbox=None):
    """Poll until `stop` is set. SIGTERM finishes the current iteration and
    returns 0; it never touches running jobs (Requirement 11)."""
    stop = stop or StopFlag()
    sleep = sleep or (lambda s: _interruptible_sleep(s, stop))
    loop = PollLoop(config, supervisor, outbox, rand, allow_insecure, opener, cache)
    while not stop.is_set():
        try:
            delay = loop.step()
        except Exception as e:                          # last-ditch: back off, keep running
            log.error("iteration failed: %s", type(e).__name__)
            delay = loop.backoff.next()
        if stop.is_set():
            break
        sleep(delay)
    log.info("stop requested; exiting without touching running jobs")
    return 0


# ---------------------------------------------------------------------------
# XACA-1445-012: reversible disable/enable of the host's PERSISTENT runners
# ---------------------------------------------------------------------------
# CLI (run as root on the host, same config as the daemon):
#   ci-pool-agent.py persistent-status [--json]   what exists and its state
#   ci-pool-agent.py persistent-disable [--force] stop + disable, KEEP registrations
#   ci-pool-agent.py persistent-enable            restore exactly what disable stopped
# Exit: 0 ok, 2 usage/config, 3 a unit/daemon step failed (names it), 4 refused: a
# persistent runner is mid-job (or cannot be proven idle) and --force was not given.
#
# What it touches: the Linux guest's actions.runner.* systemd units (VM must be
# Running) and, when its plist exists, the macOS runner LaunchDaemon. It NEVER runs
# config.sh remove: registrations stay, so rollback R1 needs no registration token.
# Hard removal is a separate, later step (runbook section 5).
#
# State marker (persistent.json, 0600, atomic, written after EVERY step so a partial
# failure is still restorable): the units disable stopped and their prior state. The
# marker's presence tells the JIT loop (see main()) that persistent units are
# intentionally off. enable restores exactly the recorded units, drops each from the
# marker only once it is verified back, and deletes the marker when none remain.
# Both directions are idempotent.
DEFAULT_PERSIST_PATH = "/usr/local/var/ci-pool-agent/persistent.json"
DEFAULT_LAUNCHCTL = "/bin/launchctl"
DEFAULT_PLIST_DIR = "/Library/LaunchDaemons"
GUEST_UNIT_GLOB = "actions.runner.*"
UNIT_RE = re.compile(r"^actions\.runner\.[A-Za-z0-9_.@:-]{1,200}\.service$")
LABEL_RE = re.compile(r"^[A-Za-z0-9_.-]{1,200}$")
PERSIST_COMMANDS = ("persistent-status", "persistent-disable", "persistent-enable")
EXIT_FAILED = 3
EXIT_BUSY = 4
# Guest probe (argv $1 = unit): exit 0 = a Runner.Worker lives in the unit's cgroup
# (a job is running), 1 = idle, anything else = could not tell (treated as busy).
_GUEST_BUSY_SH = ('cg=$(systemctl show -p ControlGroup --value "$1" 2>/dev/null) || exit 2; '
                  '[ -n "$cg" ] || exit 1; f="/sys/fs/cgroup${cg}/cgroup.procs"; '
                  '[ -r "$f" ] || exit 1; '
                  'for p in $(cat "$f"); do tr "\\0" " " </proc/$p/cmdline 2>/dev/null; echo; done '
                  '| grep -q "Runner.Worker" && exit 0; exit 1')
MAC_WORKER_PATTERN = "actions-runner-macos/bin/Runner.Worker"


def run_rc(argv, timeout=60):
    """Run argv (list, never a shell). Return (rc, stdout); rc is None when it
    could not be run or timed out. stderr is discarded."""
    if not isinstance(argv, (list, tuple)):
        raise TypeError("argv must be a list")
    try:
        p = subprocess.run(list(argv), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=timeout,
                           universal_newlines=True)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None, ""
    return p.returncode, p.stdout


def mac_label(config):
    """The macOS runner LaunchDaemon label, as provision-host.sh derives it
    (m1mini keeps the legacy unsuffixed name)."""
    if config.get("macLabel"):
        return config["macLabel"]
    host = config.get("machine") or ""
    return "com.doublenode.ci-runner.macos" if host == "m1mini" \
        else "com.doublenode.ci-runner.%s.macos" % host


class PersistentRunners(object):
    def __init__(self, config, out=None, clock=time.time):
        self.cfg = config
        self.limactl = config.get("limactl") or DEFAULT_LIMACTL
        self.vm = config.get("vmName") or ""
        self.launchctl = config.get("launchctl") or DEFAULT_LAUNCHCTL
        self.plist_dir = config.get("plistDir") or DEFAULT_PLIST_DIR
        self.path = config.get("persistentStatePath") or DEFAULT_PERSIST_PATH
        self.label = mac_label(config)
        self.plist = os.path.join(self.plist_dir, self.label + ".plist")
        self.out = out if out is not None else sys.stdout
        self.clock = clock

    def say(self, text):
        self.out.write(text + "\n")

    # -- marker --------------------------------------------------------------------
    def load_marker(self):
        """{'units': [...]} ; {} when absent. Raises ValueError when unreadable (we
        refuse to guess what was stopped)."""
        try:
            with open(self.path) as f:
                raw = json.load(f)
        except FileNotFoundError:
            return {}
        except (OSError, ValueError) as e:
            raise ValueError("cannot read marker %s: %s" % (self.path, e))
        if not isinstance(raw, dict) or not isinstance(raw.get("units"), list):
            raise ValueError("marker %s is malformed" % self.path)
        for u in raw["units"]:
            if not (isinstance(u, dict) and u.get("kind") in ("linux-unit", "macos-daemon")
                    and isinstance(u.get("name"), str)):
                raise ValueError("marker %s has a malformed unit entry" % self.path)
        return raw

    def save_marker(self, marker):
        marker["version"] = 1
        tmp = "%s.tmp.%d" % (self.path, os.getpid())
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(marker, f, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.path)

    def drop_marker(self):
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass

    # -- guest / host primitives ---------------------------------------------------
    def _guest(self, *args):
        return as_ci([self.limactl, "shell", "--workdir", "/tmp", self.vm, "--"] + list(args))

    def vm_running(self):
        return bool(self.vm) and collect_vm_state(self.limactl, self.vm) == "running"

    def linux_units(self):
        """[(unit, enabled, active)] for every guest actions.runner.* service, or
        None when the guest cannot be read."""
        rc, out = run_rc(self._guest("systemctl", "list-unit-files", "--no-legend",
                                     "--plain", "--type=service", GUEST_UNIT_GLOB))
        if rc != 0:
            return None
        units = []
        for line in out.splitlines():
            parts = line.split()
            if len(parts) < 2 or not UNIT_RE.match(parts[0]):
                continue
            arc, _ = run_rc(self._guest("systemctl", "is-active", "--quiet", parts[0]))
            if arc is None:
                return None
            units.append((parts[0], parts[1] == "enabled", arc == 0))
        return units

    def linux_busy(self, unit):
        """True busy / False idle / None unknown."""
        rc, _ = run_rc(self._guest("sh", "-c", _GUEST_BUSY_SH, "sh", unit))
        return True if rc == 0 else False if rc == 1 else None

    def mac_present(self):
        return os.path.isfile(self.plist)

    def mac_loaded(self):
        rc, _ = run_rc([self.launchctl, "print", "system/" + self.label])
        return rc == 0

    def mac_disabled(self):
        rc, out = run_rc([self.launchctl, "print-disabled", "system"])
        if rc != 0:
            return None
        m = re.search(r'"%s"\s*=>\s*(disabled|enabled|true|false)' % re.escape(self.label), out)
        return None if not m else m.group(1) in ("disabled", "true")

    def mac_busy(self):
        rc, _ = run_rc(["pgrep", "-f", MAC_WORKER_PATTERN])
        return True if rc == 0 else False if rc == 1 else None

    # -- commands ------------------------------------------------------------------
    def status(self, as_json=False):
        try:
            marker = self.load_marker()
        except ValueError as e:
            self.say("persistent-status: %s" % e)
            return EXIT_FAILED
        rows = []
        vm_state = collect_vm_state(self.limactl, self.vm) if self.vm else "none"
        if vm_state == "running":
            units = self.linux_units()
            if units is None:
                self.say("persistent-status: cannot list guest runner units")
                return EXIT_FAILED
            rows += [{"kind": "linux-unit", "name": u, "enabled": e, "active": a}
                     for (u, e, a) in units]
        if self.mac_present():
            rows.append({"kind": "macos-daemon", "name": self.label,
                         "loaded": self.mac_loaded(), "disabled": self.mac_disabled()})
        if as_json:
            self.say(json.dumps({"vm": vm_state, "units": rows,
                                 "markerPresent": bool(marker),
                                 "markerUnits": [u["name"] for u in marker.get("units", [])]},
                                sort_keys=True))
            return 0
        self.say("vm: %s" % vm_state)
        for r in rows:
            if r["kind"] == "linux-unit":
                self.say("linux-unit %s enabled=%s active=%s" % (
                    r["name"], "yes" if r["enabled"] else "no", "yes" if r["active"] else "no"))
            else:
                self.say("macos-daemon %s loaded=%s disabled=%s" % (
                    r["name"], "yes" if r["loaded"] else "no",
                    "unknown" if r["disabled"] is None else "yes" if r["disabled"] else "no"))
        self.say("marker: %s" % ("present (%s)" % ", ".join(u["name"] for u in marker["units"])
                                 if marker else "absent"))
        return 0

    def disable(self, force=False):
        try:
            marker = self.load_marker()
        except ValueError as e:
            self.say("persistent-disable: %s" % e)
            return EXIT_FAILED
        marker.setdefault("units", [])
        known = set((u["kind"], u["name"]) for u in marker["units"])
        plan = []                                     # entries still to stop
        if self.vm:
            if not self.vm_running():
                self.say("persistent-disable: VM '%s' is not running; guest units cannot be "
                         "controlled (start it, or this host is already paused)" % self.vm)
                return EXIT_FAILED
            units = self.linux_units()
            if units is None:
                self.say("persistent-disable: cannot list guest runner units")
                return EXIT_FAILED
            for (u, enabled, active) in units:
                if enabled or active:
                    plan.append({"kind": "linux-unit", "name": u,
                                 "wasEnabled": enabled, "wasActive": active})
        if self.mac_present():
            loaded = self.mac_loaded()
            dis = self.mac_disabled()
            if loaded or dis is not True:
                plan.append({"kind": "macos-daemon", "name": self.label,
                             "wasEnabled": dis is not True, "wasActive": loaded})
        # Busy gate runs for EVERYTHING before anything is stopped.
        if not force:
            busy = []
            for e in plan:
                if not e["wasActive"]:
                    continue
                b = self.linux_busy(e["name"]) if e["kind"] == "linux-unit" else self.mac_busy()
                if b is not False:
                    busy.append("%s (%s)" % (e["name"], "mid-job" if b else "cannot tell if idle"))
            if busy:
                self.say("persistent-disable: refusing, nothing was stopped. Busy: %s. "
                         "Wait for the job, or use --force." % ", ".join(busy))
                return EXIT_BUSY
        failed = []
        for e in plan:
            ok = self._stop_linux(e) if e["kind"] == "linux-unit" else self._stop_mac(e)
            if not ok:
                failed.append(e["name"])
            # record even a half-stopped unit so enable can put it back
            if (e["kind"], e["name"]) not in known:
                marker["units"].append(e)
                known.add((e["kind"], e["name"]))
            marker["disabledAt"] = int(self.clock())
            self.save_marker(marker)
        if failed:
            self.say("persistent-disable: FAILED for: %s (marker kept; persistent-enable restores)"
                     % ", ".join(failed))
            return EXIT_FAILED
        self.say("persistent-disable: ok; %d unit(s) off, registrations untouched%s" % (
            len(marker["units"]), "" if plan else " (already off)"))
        return 0

    def _stop_linux(self, e):
        u = e["name"]
        rc, _ = run_rc(self._guest("sudo", "-n", "systemctl", "disable", "--now", u))
        if rc != 0:
            return False
        arc, _ = run_rc(self._guest("systemctl", "is-active", "--quiet", u))
        erc, _ = run_rc(self._guest("systemctl", "is-enabled", "--quiet", u))
        return arc not in (0, None) and erc not in (0, None)

    def _stop_mac(self, e):
        rc, _ = run_rc([self.launchctl, "disable", "system/" + self.label])
        if rc != 0:
            return False
        if self.mac_loaded():
            rc, _ = run_rc([self.launchctl, "bootout", "system/" + self.label])
            if rc != 0:
                return False
        return not self.mac_loaded()

    def enable(self):
        try:
            marker = self.load_marker()
        except ValueError as e:
            self.say("persistent-enable: %s" % e)
            return EXIT_FAILED
        todo = marker.get("units", [])
        if not todo:
            self.say("persistent-enable: nothing to restore (no marker); ok")
            return 0
        if any(e["kind"] == "linux-unit" for e in todo) and not self.vm_running():
            self.say("persistent-enable: VM '%s' is not running; start it first" % self.vm)
            return EXIT_FAILED
        failed = []
        remaining = []
        for e in todo:
            ok = self._start_linux(e) if e["kind"] == "linux-unit" else self._start_mac(e)
            if ok:
                continue
            failed.append(e["name"])
            remaining.append(e)
        if remaining:
            marker["units"] = remaining
            self.save_marker(marker)
            self.say("persistent-enable: FAILED for: %s (marker kept for those)" % ", ".join(failed))
            return EXIT_FAILED
        self.drop_marker()
        self.say("persistent-enable: ok; %d unit(s) restored" % len(todo))
        return 0

    def _start_linux(self, e):
        u = e["name"]
        if e.get("wasEnabled"):
            args = ["enable"] + (["--now"] if e.get("wasActive") else []) + [u]
        elif e.get("wasActive"):
            args = ["start", u]
        else:
            return True
        rc, _ = run_rc(self._guest("sudo", "-n", "systemctl", *args))
        if rc != 0:
            return False
        if e.get("wasActive"):
            arc, _ = run_rc(self._guest("systemctl", "is-active", "--quiet", u))
            return arc == 0
        return True

    def _start_mac(self, e):
        if e.get("wasEnabled"):
            rc, _ = run_rc([self.launchctl, "enable", "system/" + self.label])
            if rc != 0:
                return False
        if e.get("wasActive") and not self.mac_loaded():
            rc, _ = run_rc([self.launchctl, "bootstrap", "system", self.plist])
            if rc != 0:
                return False
        return self.mac_loaded() if e.get("wasActive") else True


def persistent_main(argv, config=None, out=None):
    cmd, rest = argv[0], argv[1:]
    allowed = {"persistent-disable": ("--force",), "persistent-status": ("--json",),
               "persistent-enable": ()}[cmd]
    bad = [a for a in rest if a not in allowed]
    if bad:
        sys.stderr.write("ci-pool-agent %s: unknown option %s (allowed: %s)\n"
                         % (cmd, bad[0], " ".join(allowed) or "none"))
        return 2
    if config is None:
        try:
            config = load_config()
        except ValueError as e:
            sys.stderr.write("ci-pool-agent: %s\n" % e)
            return 2
    if config.get("machine") and not LABEL_RE.match(config["machine"]):
        sys.stderr.write("ci-pool-agent: config machine is not a valid host name\n")
        return 2
    pr = PersistentRunners(config, out=out)
    if cmd == "persistent-status":
        return pr.status(as_json="--json" in rest)
    if cmd == "persistent-disable":
        return pr.disable(force="--force" in rest)
    return pr.enable()


def main(argv=None):
    args = sys.argv[1:] if argv is None else list(argv)
    if args and args[0] in PERSIST_COMMANDS:
        return persistent_main(args)
    try:
        cfg = load_config()
    except ValueError as e:
        sys.stderr.write("ci-pool-agent: %s\n" % e)
        return 2
    setup_logging(cfg["logPath"])
    log.info("ci-pool-agent %s starting (machine=%s)", AGENT_VERSION, cfg["machine"])
    try:
        validate_server_url(cfg["serverUrl"])
    except ValueError as e:
        log.error("config: %s", e)
        return 2
    if os.path.exists(cfg.get("persistentStatePath") or DEFAULT_PERSIST_PATH):
        log.info("persistent runner units are intentionally OFF (marker present); "
                 "persistent-enable restores them")
    stop = StopFlag()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda s, f: stop.set())
    outbox = Outbox()
    sup = SlotSupervisor(cfg)
    sup.bind_reporter(outbox.add)    # adoption reports happen before the first poll
    sup.adopt_on_start()
    return run_loop(cfg, sup, stop=stop, outbox=outbox)


if __name__ == "__main__":
    sys.exit(main())
