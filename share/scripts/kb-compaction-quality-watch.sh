#!/usr/bin/env bash
# kb-compaction-quality-watch.sh — XACA-1283-002
#
# Watches whether CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 (P=50) is hurting WORK
# QUALITY, and recommends (never performs) a revert when it is. The design,
# every threshold and the reasoning behind each one live in
# docs/compaction-quality-watch.md — that doc is authoritative; this header only
# summarises it so a reader on a tap machine (no docs/ checkout) is not lost.
#
# SIGNAL. A transcript file's ANCHOR is its first assistant turn whose context
# (input + cache_read + cache_creation tokens) reaches T(model) — 490,000 for
# the 1M family (claude-{opus,sonnet,fable}-5*), 90,000 for claude-haiku-4-5* —
# or an earlier auto compact_boundary. The anchor exists identically with and
# without P=50, so pre/post around it is workload-paired inside each session.
#   E_pre  = errors/results over the last  K tool_result blocks BEFORE the anchor
#   E_post = errors/results over the first K tool_result blocks AFTER  the anchor
#   M      = pooled E_post − pooled E_pre, in percentage points, per family
#   X      = M_window − M_baseline
# S1 (validity guard, 1M only): of the anchored files that auto-compacted or grew
# past 540,000, the fraction whose FIRST auto compaction had preTokens <= 540,000.
# S2 (report-only): count and Σ durationMs of auto compactions.
#
# VERDICTS / EXIT CODES (precedence 2 > 1 > 3 > 0):
#   0 OK                  floor met on both sides, S1 >= 0.8, X < +2.0 pp
#   1 REVERT_RECOMMENDED  X >= +2.0 pp. A human decides; this script never reverts.
#   2 usage/environment   bad flag, unreadable root, malformed baseline, K mismatch,
#                         missing baseline file, python3 missing or crashed
#   3 INSUFFICIENT_DATA   BELOW_FLOOR | BASELINE_BELOW_FLOOR | NOT_BOUND | NO_BASELINE
#                         — never a pass. Thin machines live here permanently.
# Floor, per family and per side: >= 20 anchored files, >= 600 pre results,
# >= 600 post results.
#
# GATING FAMILY. Only family "1M" decides 0-vs-3. Family "haiku" is always
# measured and reported, and can raise rc=1 if it ever meets the floor and
# exceeds the threshold (S1 is undefined for Haiku, so the NOT_BOUND guard does
# not apply to it — an alarm must be able to surface), but its
# INSUFFICIENT_DATA does not gate: Haiku has had
# 0 anchors ever (peak 80,702 < 90,000), so letting it gate would make rc=0
# unreachable and gate G6 of the doc impossible. Haiku safety is
# kb-compaction-premise-check.sh check C (doc §1).
#
# MODES
#   (default, report)         measure + print; rc=3 (NO_BASELINE) at best,
#                             because no threshold was judged.
#   --capture-baseline <out>  measure + write a self-describing baseline JSON;
#                             rc=0 even when INSUFFICIENT_DATA (capture ≠ judgment).
#   --baseline <file>         compare mode; --since is REQUIRED.
#
# Each run appends exactly ONE line to the watch log (default
# ~/aiteamforge-backups/compaction-watch/watch.log, override with
# $COMPACTION_WATCH_LOG — the test suite always does):
#   kb-compaction-quality-watch: RESULT=<verdict> host=<h> since=<t> anchors=<n>
#     M=<pp> X=<pp> s1=<r> rc=<n> mode=<m> at=<ISO8601 UTC>      (one line)
# Figures on that line are family 1M's. ERROR runs log RESULT=ERROR.
#
# RUNTIME CONTRACT (doc §4): /bin/bash 3.2 and bash 5.x; python3 STDLIB ONLY;
# no jq, no git, no repo-relative paths, no sourcing of kanban-helpers.sh or
# aiteamforge_paths — this file is SELF-CONTAINED because it is mirrored to tap
# machines that have no dev-team clone. Files are streamed line by line behind a
# cheap substring prefilter (M3Pro holds ~3.6 GB of transcripts). Unreadable
# files and unparseable lines are counted and reported, never silently dropped.
#
# CRASH-vs-VERDICT GUARD. An uncaught Python exception (or a syntax error in the
# heredoc) exits 1 — the same number as REVERT_RECOMMENDED. So the Python side
# records the rc it DELIBERATELY chose in a side file, and this wrapper maps any
# exit that does not match that record to rc=2. A crash can never read as a
# revert recommendation, nor a revert as a crash.

set -u

_cqw_log_error() {
    # Last-resort ERROR line when Python never got to write one.
    _cqw_log="${COMPACTION_WATCH_LOG:-$HOME/aiteamforge-backups/compaction-watch/watch.log}"
    _cqw_dir=$(dirname "$_cqw_log")
    mkdir -p "$_cqw_dir" 2>/dev/null
    _cqw_host=$(hostname 2>/dev/null | tr -s ' \t' '__')
    _cqw_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf 'kb-compaction-quality-watch: RESULT=ERROR host=%s reason=%s rc=2 at=%s\n' \
        "${_cqw_host:-unknown}" "$1" "$_cqw_now" >>"$_cqw_log" 2>/dev/null
}

if ! command -v python3 >/dev/null 2>&1; then
    echo "kb-compaction-quality-watch: python3 not found on PATH ($PATH) — cannot measure (rc=2)" >&2
    _cqw_log_error PYTHON3_MISSING
    exit 2
fi

CQW_RC_FILE=$(mktemp "${TMPDIR:-/tmp}/cqw-rc.XXXXXX") || {
    echo "kb-compaction-quality-watch: mktemp failed — cannot run (rc=2)" >&2
    _cqw_log_error MKTEMP_FAILED
    exit 2
}
trap 'rm -f "$CQW_RC_FILE"' EXIT
export CQW_RC_FILE

python3 - "$@" <<'PY'
import datetime
import hashlib
import json
import os
import re
import socket
import sys
from collections import deque
from fractions import Fraction

SCHEMA_VERSION = 1
TOOL = "kb-compaction-quality-watch"
T_1M = 490000
T_HAIKU = 90000
S1_CUTOFF = 540000
S1_MIN = Fraction(4, 5)          # 0.8
FLOOR_ANCHORS = 20
FLOOR_PRE = 600
FLOOR_POST = 600
THRESHOLD_PP = Fraction(2)       # X >= +2.0 pp -> REVERT_RECOMMENDED
DEFAULT_K = 40
FAMILIES = ("1M", "haiku")
GATING_FAMILY = "1M"
MAX_VERSIONS = 50

_1M_RE = re.compile(r"^claude-(opus|sonnet|fable)-5(?![0-9.])")

RC_OK, RC_REVERT, RC_ERR, RC_INSUF = 0, 1, 2, 3

USAGE = """usage: kb-compaction-quality-watch.sh [--root DIR] [--since ISO8601] [--until ISO8601]
                                     [--k N] [--json]
                                     [--capture-baseline OUT.json | --baseline FILE.json]
                                     [--host NAME] [--provenance LABEL] [--source-sha256 HEX]

  --root DIR             transcript root (default ~/.claude/projects); an extracted
                         snapshot directory is accepted
  --since/--until TS     window by ANCHOR timestamp, [since, until). --since is
                         required with --baseline
  --k N                  pre/post window size (default 40); must match the baseline's
  --json                 machine-readable output on stdout
  --capture-baseline F   write a baseline JSON to F (exit 0 even if INSUFFICIENT_DATA)
  --baseline F           compare against baseline F
  --host NAME            record/compare as this host (default: hostname). Use when
                         capturing a baseline from ANOTHER machine's snapshot
  --provenance LABEL     baseline provenance label (default: captured)
  --source-sha256 HEX    sha256 of the snapshot archive the root was extracted from

exit: 0 OK · 1 REVERT_RECOMMENDED · 2 usage/env error · 3 INSUFFICIENT_DATA
log:  one line per run to $COMPACTION_WATCH_LOG
      (default ~/aiteamforge-backups/compaction-watch/watch.log)
"""


class UsageError(Exception):
    def __init__(self, reason, msg):
        Exception.__init__(self, msg)
        self.reason = reason


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc)


def iso(dt):
    return dt.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


_TS_RE = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})"
    r"(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?)?"
    r"(Z|[+-]\d{2}:?\d{2})?$"
)


def parse_ts(s):
    """Parse ISO8601 (Z, offset, fractional seconds of any length, or date only).
    A value with no zone is taken as UTC. Returns an aware datetime or None."""
    if not isinstance(s, str):
        return None
    m = _TS_RE.match(s.strip())
    if not m:
        return None
    y, mo, d, hh, mi, ss, frac, tz = m.groups()
    try:
        micro = int((frac or "0")[:6].ljust(6, "0"))
        dt = datetime.datetime(int(y), int(mo), int(d), int(hh or 0), int(mi or 0),
                               int(ss or 0), micro)
    except ValueError:
        return None
    if tz in (None, "Z"):
        off = datetime.timedelta(0)
    else:
        sign = 1 if tz[0] == "+" else -1
        digits = tz[1:].replace(":", "")
        off = sign * datetime.timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
    return dt.replace(tzinfo=datetime.timezone(off))


def family_of(model):
    m = model or ""
    if m.startswith("claude-haiku-4-5"):
        return "haiku"
    if _1M_RE.match(m):
        return "1M"
    return None


def threshold_of(model):
    return T_HAIKU if (model or "").startswith("claude-haiku-4-5") else T_1M


def as_int(v):
    if isinstance(v, bool):
        return 0
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return int(v)
    return 0


def parse_args(argv):
    a = {"root": None, "since": None, "until": None, "k": None, "json": False,
         "capture": None, "baseline": None, "host": None, "provenance": None,
         "source_sha256": None, "help": False}
    valued = {"--root": "root", "--since": "since", "--until": "until", "--k": "k",
              "--capture-baseline": "capture", "--baseline": "baseline",
              "--host": "host", "--provenance": "provenance",
              "--source-sha256": "source_sha256"}
    i = 0
    while i < len(argv):
        arg = argv[i]
        key, val = arg, None
        if arg.startswith("--") and "=" in arg:
            key, val = arg.split("=", 1)
        if key in ("-h", "--help"):
            a["help"] = True
        elif key == "--json":
            if val is not None:
                raise UsageError("BAD_FLAG", "--json takes no value")
            a["json"] = True
        elif key in valued:
            if val is None:
                if i + 1 >= len(argv):
                    raise UsageError("BAD_FLAG", "%s requires a value" % key)
                i += 1
                val = argv[i]
            if val == "":
                raise UsageError("BAD_FLAG", "%s requires a non-empty value" % key)
            if a[valued[key]] is not None:
                raise UsageError("BAD_FLAG", "%s given more than once" % key)
            a[valued[key]] = val
        else:
            raise UsageError("BAD_FLAG", "unknown argument: %s" % arg)
        i += 1
    return a


def scan(root, k, since, until):
    """Stream every *.jsonl under root (recursively, subagents/ included)."""
    inp = {"files": 0, "bytes": 0, "unreadable_files": 0, "unreadable_dirs": 0,
           "bad_lines": 0, "file_list_sha256": None}
    fam = {}
    for f in FAMILIES:
        fam[f] = {"anchors": 0, "full_windows": 0, "pre_n": 0, "pre_err": 0,
                  "post_n": 0, "post_err": 0, "s1_eligible": 0, "s1_bound": 0,
                  "s2_count": 0, "s2_duration_ms": 0, "versions": set()}
    other = {"unclassified_anchors": 0, "unclassified_models": set(),
             "undated_anchors": 0, "anchors_outside_window": 0}

    def on_walk_error(_e):
        inp["unreadable_dirs"] += 1

    paths = []
    for dirpath, dirnames, filenames in os.walk(root, onerror=on_walk_error):
        dirnames.sort()
        for fn in filenames:
            if fn.endswith(".jsonl"):
                paths.append(os.path.join(dirpath, fn))
    paths.sort()
    listing = hashlib.sha256()

    for p in paths:
        rel = os.path.relpath(p, root)
        try:
            size = os.path.getsize(p)
        except OSError:
            size = -1
        listing.update(("%s\t%d\n" % (rel, size)).encode("utf-8", "replace"))
        inp["files"] += 1
        if size > 0:
            inp["bytes"] += size
        try:
            fh = open(p, "r", encoding="utf-8", errors="replace")
        except OSError:
            inp["unreadable_files"] += 1
            continue

        model = None
        anchored = False
        anchor_ts = None
        anchor_model = None
        pre = deque(maxlen=k)
        post_n = post_err = 0
        first_auto_pre = None
        auto_seen = False
        peak = 0
        s2c = s2ms = 0
        versions = set()
        try:
            with fh:
                for line in fh:
                    # Cheap prefilter: only three line shapes carry anything we use.
                    if ('"tool_result"' not in line and '"usage"' not in line
                            and "compact_boundary" not in line):
                        continue
                    try:
                        d = json.loads(line)
                    except ValueError:
                        inp["bad_lines"] += 1
                        continue
                    if not isinstance(d, dict):
                        inp["bad_lines"] += 1
                        continue
                    v = d.get("version")
                    if isinstance(v, str) and len(versions) < MAX_VERSIONS:
                        versions.add(v)
                    if d.get("subtype") == "compact_boundary":
                        cm = d.get("compactMetadata")
                        if not isinstance(cm, dict):
                            cm = {}
                        if cm.get("trigger") == "auto":
                            s2c += 1
                            s2ms += as_int(cm.get("durationMs"))
                            if not auto_seen:
                                auto_seen = True
                                pt = cm.get("preTokens")
                                first_auto_pre = pt if isinstance(pt, int) and not isinstance(pt, bool) else None
                            if not anchored:
                                anchored = True
                                anchor_ts = d.get("timestamp")
                                anchor_model = model
                        continue
                    msg = d.get("message")
                    if not isinstance(msg, dict):
                        continue
                    if d.get("type") == "assistant":
                        mm = msg.get("model")
                        if isinstance(mm, str) and mm and mm != "<synthetic>":
                            model = mm
                        u = msg.get("usage")
                        if isinstance(u, dict):
                            ctx = (as_int(u.get("input_tokens"))
                                   + as_int(u.get("cache_read_input_tokens"))
                                   + as_int(u.get("cache_creation_input_tokens")))
                            if ctx > peak:
                                peak = ctx
                            if not anchored and model and ctx >= threshold_of(model):
                                anchored = True
                                anchor_ts = d.get("timestamp")
                                anchor_model = model
                    content = msg.get("content")
                    if isinstance(content, list):
                        for b in content:
                            if isinstance(b, dict) and b.get("type") == "tool_result":
                                err = b.get("is_error") is True
                                if not anchored:
                                    pre.append(err)
                                elif post_n < k:
                                    post_n += 1
                                    post_err += 1 if err else 0
        except OSError:
            inp["unreadable_files"] += 1
            continue

        if not anchored:
            continue
        fam_name = family_of(anchor_model or model)
        if fam_name is None:
            other["unclassified_anchors"] += 1
            other["unclassified_models"].add(str(anchor_model or model))
            continue
        ats = parse_ts(anchor_ts)
        if ats is None:
            other["undated_anchors"] += 1
            continue
        if (since is not None and ats < since) or (until is not None and ats >= until):
            other["anchors_outside_window"] += 1
            continue
        c = fam[fam_name]
        c["anchors"] += 1
        if len(pre) >= k and post_n >= k:
            c["full_windows"] += 1
        c["pre_n"] += len(pre)
        c["pre_err"] += sum(1 for e in pre if e)
        c["post_n"] += post_n
        c["post_err"] += post_err
        if auto_seen or peak > S1_CUTOFF:
            c["s1_eligible"] += 1
            if first_auto_pre is not None and first_auto_pre <= S1_CUTOFF:
                c["s1_bound"] += 1
        c["s2_count"] += s2c
        c["s2_duration_ms"] += s2ms
        for v in versions:
            if len(c["versions"]) < MAX_VERSIONS:
                c["versions"].add(v)

    inp["file_list_sha256"] = listing.hexdigest()
    return inp, fam, other


def m_of(c):
    """M in percentage points as an exact Fraction, or None when undefined."""
    if not c["pre_n"] or not c["post_n"]:
        return None
    return (Fraction(c["post_err"], c["post_n"]) - Fraction(c["pre_err"], c["pre_n"])) * 100


def floor_met(c):
    return (c["anchors"] >= FLOOR_ANCHORS and c["pre_n"] >= FLOOR_PRE
            and c["post_n"] >= FLOOR_POST)


def s1_of(fname, c):
    if fname != "1M" or not c["s1_eligible"]:
        return None
    return Fraction(c["s1_bound"], c["s1_eligible"])


def fnum(x, nd=3):
    return None if x is None else round(float(x), nd)


def load_baseline(path, k):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            b = json.load(fh)
    except (OSError, IOError) as e:
        raise UsageError("BASELINE_UNREADABLE",
                         "cannot read baseline %s: %s (the M3Pro baseline is produced by "
                         "XACA-1283-006; until it exists the watch cannot judge)" % (path, e))
    except ValueError as e:
        raise UsageError("BASELINE_MALFORMED", "baseline %s is not valid JSON: %s" % (path, e))
    if not isinstance(b, dict) or b.get("schema_version") != SCHEMA_VERSION:
        raise UsageError("BASELINE_MALFORMED",
                         "baseline %s: missing or unsupported schema_version (want %d)"
                         % (path, SCHEMA_VERSION))
    if b.get("tool") != TOOL or b.get("mode") != "capture":
        raise UsageError("BASELINE_MALFORMED",
                         "baseline %s was not written by --capture-baseline" % path)
    bk = b.get("k")
    if not isinstance(bk, int) or isinstance(bk, bool) or bk < 1:
        raise UsageError("BASELINE_MALFORMED", "baseline %s: k missing or invalid" % path)
    if bk != k:
        raise UsageError("K_MISMATCH",
                         "baseline %s was captured with k=%d but this run uses k=%d"
                         % (path, bk, k))
    fams = b.get("families")
    if not isinstance(fams, dict):
        raise UsageError("BASELINE_MALFORMED", "baseline %s: families missing" % path)
    out = {}
    for f in FAMILIES:
        c = fams.get(f)
        if not isinstance(c, dict):
            raise UsageError("BASELINE_MALFORMED", "baseline %s: family %s missing" % (path, f))
        cc = {}
        for key in ("anchors", "pre_n", "pre_err", "post_n", "post_err"):
            v = c.get(key)
            if not isinstance(v, int) or isinstance(v, bool) or v < 0:
                raise UsageError("BASELINE_MALFORMED",
                                 "baseline %s: families.%s.%s missing or not a "
                                 "non-negative integer" % (path, f, key))
            cc[key] = v
        if cc["pre_err"] > cc["pre_n"] or cc["post_err"] > cc["post_n"]:
            raise UsageError("BASELINE_MALFORMED",
                             "baseline %s: family %s has more errors than results" % (path, f))
        out[f] = cc
    return b, out


def log_line(verdict, host, since, fields, rc, mode):
    path = os.environ.get("COMPACTION_WATCH_LOG") or os.path.join(
        os.path.expanduser("~"), "aiteamforge-backups", "compaction-watch", "watch.log")
    h = re.sub(r"\s+", "_", host or "unknown")
    line = "%s: RESULT=%s host=%s since=%s" % (TOOL, verdict, h, since or "-")
    for kk, vv in fields:
        line += " %s=%s" % (kk, "NA" if vv is None else vv)
    line += " rc=%d mode=%s at=%s\n" % (rc, mode, iso(now_utc()))
    try:
        d = os.path.dirname(path)
        if d and not os.path.isdir(d):
            os.makedirs(d)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError as e:
        sys.stderr.write("%s: WARNING: could not append to watch log %s: %s\n" % (TOOL, path, e))


def finish(rc):
    rcf = os.environ.get("CQW_RC_FILE")
    if rcf:
        try:
            with open(rcf, "w") as fh:
                fh.write("%d\n" % rc)
        except OSError:
            pass
    sys.stdout.flush()
    sys.exit(rc)


def main(argv):
    host_default = socket.gethostname() or "unknown"
    mode = "report"
    since_raw = None
    try:
        a = parse_args(argv)
        if a["help"]:
            sys.stdout.write(USAGE)
            finish(RC_OK)
        if a["capture"] and a["baseline"]:
            raise UsageError("BAD_FLAG", "--capture-baseline and --baseline are mutually exclusive")
        mode = "capture" if a["capture"] else ("compare" if a["baseline"] else "report")
        since_raw = a["since"]
        k = DEFAULT_K
        if a["k"] is not None:
            if not re.match(r"^[0-9]+$", a["k"]) or int(a["k"]) < 1 or int(a["k"]) > 100000:
                raise UsageError("BAD_FLAG", "--k must be a positive integer, got %r" % a["k"])
            k = int(a["k"])
        since = until = None
        if a["since"] is not None:
            since = parse_ts(a["since"])
            if since is None:
                raise UsageError("BAD_FLAG", "--since is not ISO8601: %r" % a["since"])
        if a["until"] is not None:
            until = parse_ts(a["until"])
            if until is None:
                raise UsageError("BAD_FLAG", "--until is not ISO8601: %r" % a["until"])
        if since is not None and until is not None and until <= since:
            raise UsageError("BAD_FLAG", "--until must be later than --since")
        if mode == "compare" and since is None:
            raise UsageError("BAD_FLAG", "--since is required with --baseline (compare mode)")
        if a["source_sha256"] is not None and not re.match(r"^[0-9a-f]{64}$", a["source_sha256"]):
            raise UsageError("BAD_FLAG", "--source-sha256 must be 64 lowercase hex characters")
        host = a["host"] or host_default
        root = os.path.expanduser(a["root"] or "~/.claude/projects")
        if not os.path.isdir(root):
            raise UsageError("ROOT_MISSING", "transcript root is not a directory: %s" % root)
        try:
            os.listdir(root)
        except OSError as e:
            raise UsageError("ROOT_UNREADABLE", "transcript root unreadable: %s (%s)" % (root, e))

        baseline_doc = baseline_fams = None
        if mode == "compare":
            baseline_doc, baseline_fams = load_baseline(a["baseline"], k)
        if mode == "capture":
            outdir = os.path.dirname(os.path.abspath(a["capture"]))
            if not os.path.isdir(outdir):
                raise UsageError("CAPTURE_DIR_MISSING",
                                 "baseline output directory does not exist: %s" % outdir)
    except UsageError as e:
        sys.stderr.write("%s: ERROR (%s): %s\n" % (TOOL, e.reason, e))
        if e.reason == "BAD_FLAG":
            sys.stderr.write(USAGE)
        log_line("ERROR", host_default, since_raw, [("reason", e.reason)], RC_ERR, mode)
        finish(RC_ERR)

    inp, fam, other = scan(root, k, since, until)

    warnings = []
    if baseline_doc is not None and baseline_doc.get("host") != host:
        warnings.append("CROSS_MACHINE_BASELINE: baseline host=%s, this host=%s"
                        % (baseline_doc.get("host"), host))
    if inp["unreadable_files"] or inp["unreadable_dirs"] or inp["bad_lines"]:
        warnings.append("INPUT_DEFECTS: unreadable_files=%d unreadable_dirs=%d bad_lines=%d"
                        % (inp["unreadable_files"], inp["unreadable_dirs"], inp["bad_lines"]))
    if other["unclassified_anchors"]:
        warnings.append("UNCLASSIFIED_MODELS: %d anchored file(s) on models outside both "
                        "families were excluded: %s" % (other["unclassified_anchors"],
                                                        ", ".join(sorted(other["unclassified_models"]))))

    fam_out = {}
    fam_rc = {}
    for f in FAMILIES:
        c = fam[f]
        M = m_of(c)
        s1 = s1_of(f, c)
        rec = {
            "anchors": c["anchors"], "full_windows": c["full_windows"],
            "pre_n": c["pre_n"], "pre_err": c["pre_err"],
            "post_n": c["post_n"], "post_err": c["post_err"],
            "E_pre": fnum(Fraction(c["pre_err"], c["pre_n"]) * 100 if c["pre_n"] else None),
            "E_post": fnum(Fraction(c["post_err"], c["post_n"]) * 100 if c["post_n"] else None),
            "M": fnum(M),
            "s1_binding_rate": fnum(s1),
            "s1_bound": c["s1_bound"], "s1_eligible": c["s1_eligible"],
            "s2_count": c["s2_count"], "s2_duration_ms": c["s2_duration_ms"],
            "versions_seen": sorted(c["versions"]),
            "floor_met": floor_met(c),
            "gating": f == GATING_FAMILY,
        }
        if mode == "compare":
            b = baseline_fams[f]
            Mb = m_of(b)
            rec["baseline_M"] = fnum(Mb)
            rec["baseline_floor_met"] = floor_met(b)
            X = (M - Mb) if (M is not None and Mb is not None) else None
            rec["X"] = fnum(X)
            if not floor_met(c):
                v, r, rc = "INSUFFICIENT_DATA", "BELOW_FLOOR", RC_INSUF
            elif not floor_met(b):
                v, r, rc = "INSUFFICIENT_DATA", "BASELINE_BELOW_FLOOR", RC_INSUF
            elif X is None:
                # Unreachable while the floor holds (it guarantees non-zero n on both
                # sides); kept so a future floor change degrades to "cannot judge",
                # never to a TypeError that surfaces as rc=2.
                v, r, rc = "INSUFFICIENT_DATA", "BELOW_FLOOR", RC_INSUF
            elif f == "1M" and (s1 is None or s1 < S1_MIN):
                # S1 is defined for the 1M family only (doc §1). An unmeasurable S1
                # is NOT_BOUND — "cannot be evaluated" never counts as bound.
                v, r, rc = "INSUFFICIENT_DATA", "NOT_BOUND", RC_INSUF
            elif X >= THRESHOLD_PP:
                v, r, rc = "REVERT_RECOMMENDED", "THRESHOLD_EXCEEDED", RC_REVERT
            else:
                v, r, rc = "OK", "BELOW_THRESHOLD", RC_OK
        else:
            rec["X"] = None
            if not floor_met(c):
                v, r, rc = "INSUFFICIENT_DATA", "BELOW_FLOOR", RC_INSUF
            else:
                v, r, rc = "MEASURED", "NO_BASELINE", RC_INSUF
        rec["verdict"], rec["reason"] = v, r
        fam_out[f] = rec
        fam_rc[f] = rc

    # Overall: precedence 2 > 1 > 3 > 0. Any family at 1 wins; otherwise the gating
    # family (1M) decides. rc=2 cases already exited above.
    g = fam_out[GATING_FAMILY]
    if any(fam_rc[f] == RC_REVERT for f in FAMILIES):
        rc = RC_REVERT
        verdict, reason = "REVERT_RECOMMENDED", "THRESHOLD_EXCEEDED"
    elif mode == "compare":
        rc = fam_rc[GATING_FAMILY]
        verdict, reason = g["verdict"], g["reason"]
    else:
        rc = RC_INSUF
        verdict = "INSUFFICIENT_DATA"
        reason = g["reason"] if g["verdict"] == "INSUFFICIENT_DATA" else "NO_BASELINE"
    if mode == "capture":
        verdict, reason_cap = "BASELINE_CAPTURED", reason
        rc = RC_OK

    result = {
        "schema_version": SCHEMA_VERSION, "tool": TOOL, "mode": mode,
        "host": host, "generated_at": iso(now_utc()),
        "root": os.path.abspath(root), "k": k,
        "window": {"since": iso(since) if since else None, "until": iso(until) if until else None,
                   "selected_by": "anchor_timestamp"},
        "constants": {"T_1M": T_1M, "T_haiku": T_HAIKU, "s1_cutoff": S1_CUTOFF,
                      "s1_min": float(S1_MIN), "floor_anchors": FLOOR_ANCHORS,
                      "floor_pre": FLOOR_PRE, "floor_post": FLOOR_POST,
                      "threshold_pp": float(THRESHOLD_PP)},
        "input": inp,
        "other": {"unclassified_anchors": other["unclassified_anchors"],
                  "unclassified_models": sorted(other["unclassified_models"]),
                  "undated_anchors": other["undated_anchors"],
                  "anchors_outside_window": other["anchors_outside_window"]},
        "families": fam_out,
        "warnings": warnings,
        "verdict": verdict, "reason": reason if mode != "capture" else reason_cap,
        "exit_code": rc,
    }
    if mode == "compare":
        result["baseline"] = {"path": os.path.abspath(a["baseline"]),
                              "host": baseline_doc.get("host"),
                              "captured_at": baseline_doc.get("captured_at"),
                              "provenance": baseline_doc.get("provenance"),
                              "window": baseline_doc.get("window"),
                              "k": baseline_doc.get("k")}
    if mode == "capture":
        result["provenance"] = a["provenance"] or "captured"
        result["captured_at"] = result["generated_at"]
        result["source_sha256"] = a["source_sha256"]
        result["file_list_sha256"] = inp["file_list_sha256"]
        tmp = a["capture"] + ".tmp.%d" % os.getpid()
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(result, fh, indent=2, sort_keys=True)
                fh.write("\n")
            os.rename(tmp, a["capture"])
        except OSError as e:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            sys.stderr.write("%s: ERROR (CAPTURE_WRITE_FAILED): %s\n" % (TOOL, e))
            log_line("ERROR", host, since_raw, [("reason", "CAPTURE_WRITE_FAILED")], RC_ERR, mode)
            finish(RC_ERR)

    for w in warnings:
        sys.stderr.write("%s: %s\n" % (TOOL, w))

    if a["json"]:
        sys.stdout.write(json.dumps(result, indent=2, sort_keys=True) + "\n")
    else:
        out = sys.stdout
        out.write("%s  host=%s  mode=%s  k=%d  root=%s\n" % (TOOL, host, mode, k, result["root"]))
        out.write("window (anchor ts): since=%s until=%s\n"
                  % (result["window"]["since"] or "-", result["window"]["until"] or "-"))
        out.write("input: files=%d bytes=%d unreadable_files=%d bad_lines=%d\n"
                  % (inp["files"], inp["bytes"], inp["unreadable_files"], inp["bad_lines"]))
        for f in FAMILIES:
            r = fam_out[f]
            out.write("  [%s]%s anchors=%d pre=%d/%d post=%d/%d M=%s pp X=%s pp s1=%s (%d/%d) "
                      "s2=%d/%dms floor=%s -> %s (%s)\n"
                      % (f, "*" if r["gating"] else "", r["anchors"], r["pre_err"], r["pre_n"],
                         r["post_err"], r["post_n"], r["M"], r["X"], r["s1_binding_rate"],
                         r["s1_bound"], r["s1_eligible"], r["s2_count"], r["s2_duration_ms"],
                         "met" if r["floor_met"] else "UNMET", r["verdict"], r["reason"]))
        if mode == "capture":
            out.write("baseline written: %s\n" % os.path.abspath(a["capture"]))
        out.write("RESULT=%s reason=%s rc=%d\n" % (verdict, result["reason"], rc))

    log_line(verdict, host, since_raw,
             [("anchors", g["anchors"]), ("M", g["M"]), ("X", g["X"]),
              ("s1", g["s1_binding_rate"]), ("reason", result["reason"])], rc, mode)
    finish(rc)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except SystemExit:
        raise
    except KeyboardInterrupt:
        sys.stderr.write("%s: interrupted\n" % TOOL)
        finish(RC_ERR)
    except Exception as e:  # never let a crash masquerade as rc=1
        import traceback
        traceback.print_exc()
        sys.stderr.write("%s: ERROR (INTERNAL): %s\n" % (TOOL, e))
        try:
            log_line("ERROR", socket.gethostname(), None, [("reason", "INTERNAL")], RC_ERR, "?")
        except Exception:
            pass
        finish(RC_ERR)
PY
rc=$?
recorded=$(cat "$CQW_RC_FILE" 2>/dev/null | tr -d '[:space:]')
if [ "$recorded" != "$rc" ]; then
    echo "kb-compaction-quality-watch: python3 exited rc=$rc without recording a verdict (recorded='${recorded}') — interpreter failure, reporting rc=2" >&2
    _cqw_log_error "INTERPRETER_EXIT_$rc"
    exit 2
fi
exit "$rc"
