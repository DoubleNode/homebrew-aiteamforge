#!/usr/bin/env python3
# ============================================================================
# token_scan — transcript scan for kb-token-report (XACA-1300-002, XACA-1808-001)
# ============================================================================
# Extracted VERBATIM from scripts/kb-token-report so other tools can import the
# same scan instead of re-implementing it. No behaviour change. Standard
# library only, no import-time side effects, runs on /usr/bin/python3 (3.9).
#
# Public surface (names and signatures are a contract; do not rename):
#   scan_file(path, want_classifier) -> FileScan
#   FileScan: .usage {key: (ts, model, tokens)}, .order, .cwd, .branch,
#             .unreadable, .malformed, .no_id, .no_ts, .torn_final, ...
#   valid_usage, add_tokens, empty_tokens, CORE, SYNTHETIC_MODEL, parse_ts,
#   classify
#
# AUTHORITATIVE DESIGN: kanban/plans/XACA-1300/XACA-1300-001_schema.md
#
# DEDUP (design §0, normative). Claude Code writes one `type:"assistant"`
#   line PER CONTENT BLOCK, each carrying the same message.id and a copy of
#   message.usage. Summing per line overcounts ~2x. Usage is keyed by
#   (transcript file, message.id) and the LAST occurrence wins (only
#   output_tokens changes across repeats, and it only grows). The week/day
#   of a message is taken from that same last line's top-level `timestamp`
#   (never file mtime).
#
# CLASSIFIER (design §2). One class per MAIN session, first match wins:
#   gate (title / kb-run-* prompt opener) > ticket (title / kb-run task
#   prompt / worktree cwd / gitBranch) > scheduled (first user record carries
#   scheduledTaskId|cron, or majority entrypoint sdk-cli outside a temp dir)
#   > other. Subagents INHERIT the parent's class, ticket, team and account;
#   their own sidecar agentType is a separate dimension.
#
# FAIL-CLOSED (design §7), the scan-level rules:
#   - transcript unreadable ........................ FileScan.unreadable set
#   - unparseable JSON line ........................ counted; a file where
#       they exceed 1% of lines is treated as unreadable. A single torn FINAL
#       line (live session mid-write) is counted but does not trip the 1%
#       rule — that is the case the tolerance exists for.
#   - usage dict missing a core field / non-integer . counted in .malformed
#   - assistant usage without message.id ........... counted in .no_id
#   - assistant usage without a timestamp .......... counted in .no_ts
# ============================================================================

import datetime as dt
import json
import re


CORE = (
    ("input", "input_tokens"),
    ("output", "output_tokens"),
    ("cache_creation", "cache_creation_input_tokens"),
    ("cache_read", "cache_read_input_tokens"),
)
SYNTHETIC_MODEL = "<synthetic>"

TICKET = r"([A-Z][A-Z0-9]{1,7}-\d{3,5})"
RX_GATE_TITLE = re.compile(r"^\[(Review|Test|UX)\]\s+" + TICKET)
RX_DEBUG_TITLE = re.compile(r"^\[Debug\]\s+" + TICKET)
RX_TASK_TITLE = re.compile(r"^" + TICKET + r":")
RX_P_REVIEW = re.compile(r"^You are reviewing a Pull Request for kanban item \[" + TICKET + r"\]")
RX_P_TEST = re.compile(r"^You are QA testing a Pull Request for kanban item \[" + TICKET + r"\]")
RX_P_UX = re.compile(
    r"^You are the UX expert conducting a UX/UI evaluation of a Pull Request for kanban item \["
    + TICKET + r"\]")
RX_P_TASK = re.compile(r"^Build a todo list to accomplish this task:\s*## Task ID: " + TICKET)
RX_WT = re.compile(r"/worktrees/([a-z][a-z0-9]{1,7}-\d{3,5})(?:/|$)")
RX_BR = re.compile(r"^(?:feature|bugfix|refactor|hotfix|chore)/([a-z][a-z0-9]{1,7}-\d{3,5})", re.I)
RX_TMP_CWD = re.compile(r"^(/tmp|/private/tmp|/var/folders|/private/var/folders)(/|$)")

UNPARSEABLE_FILE_THRESHOLD = 0.01


def parse_ts(s):
    if not isinstance(s, str) or not s:
        return None
    try:
        t = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    if t.tzinfo is None:
        t = t.replace(tzinfo=dt.timezone.utc)
    return t.astimezone(dt.timezone.utc)


def empty_tokens():
    return {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0, "total": 0}


def add_tokens(acc, u):
    for short, _ in CORE:
        acc[short] += u[short]
    acc["total"] = acc["input"] + acc["output"] + acc["cache_creation"] + acc["cache_read"]


# ---------------------------------------------------------------------------
# Transcript scanning
# ---------------------------------------------------------------------------

def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(b.get("text", "") for b in content
                       if isinstance(b, dict) and b.get("type") == "text"
                       and isinstance(b.get("text"), str))
    return ""


class FileScan(object):
    __slots__ = ("path", "unreadable", "lines", "unparseable", "torn_final",
                 "usage", "order", "malformed", "no_id", "no_ts", "assistant_lines",
                 "entrypoints", "titles", "first_prompt", "cwd", "branch",
                 "sched_first", "seen_first_user", "first_parent", "first_uuid_seen")

    def __init__(self, path):
        self.path = path
        self.unreadable = None
        self.lines = 0
        self.unparseable = 0
        self.torn_final = False
        self.usage = {}      # key -> (ts, model, tokens-dict)
        self.order = []      # first-seen order of keys
        self.malformed = 0
        self.no_id = 0
        self.no_ts = 0
        self.assistant_lines = 0
        self.entrypoints = {}
        self.titles = []
        self.first_prompt = ""
        self.cwd = ""
        self.branch = ""
        self.sched_first = False
        self.seen_first_user = False
        self.first_parent = "unset"
        self.first_uuid_seen = False


def valid_usage(u):
    if not isinstance(u, dict):
        return None
    out = {}
    for short, key in CORE:
        v = u.get(key)
        # bool is an int subclass; a boolean is not a token count.
        if not isinstance(v, int) or isinstance(v, bool) or v < 0:
            return None
        out[short] = v
    return out


def scan_file(path, want_classifier):
    fs = FileScan(path)
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as e:
        fs.unreadable = type(e).__name__
        return fs
    lines = raw.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    last_idx = len(lines) - 1
    for idx, bline in enumerate(lines):
        if not bline.strip():
            continue
        fs.lines += 1
        try:
            o = json.loads(bline.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            fs.unparseable += 1
            if idx == last_idx:
                fs.torn_final = True
            continue
        if not isinstance(o, dict):
            fs.unparseable += 1
            continue
        t = o.get("type")
        msg = o.get("message") if isinstance(o.get("message"), dict) else {}
        if t == "assistant" and "usage" in msg:
            fs.assistant_lines += 1
            u = valid_usage(msg.get("usage"))
            if u is None:
                fs.malformed += 1
            else:
                ts = parse_ts(o.get("timestamp"))
                if ts is None:
                    fs.no_ts += 1
                mid = msg.get("id")
                if not isinstance(mid, str) or not mid:
                    fs.no_id += 1
                    key = ("<no-id>", idx)
                else:
                    key = mid
                if key not in fs.usage:
                    fs.order.append(key)
                model = msg.get("model")
                if not isinstance(model, str) or not model:
                    model = "<no-model>"
                fs.usage[key] = (ts, model, u)
        if not want_classifier:
            if not fs.cwd and isinstance(o.get("cwd"), str):
                fs.cwd = o["cwd"]
            continue
        if "uuid" in o and not fs.first_uuid_seen:
            fs.first_uuid_seen = True
            fs.first_parent = o.get("parentUuid")
        ep = o.get("entrypoint")
        if isinstance(ep, str) and ep:
            fs.entrypoints[ep] = fs.entrypoints.get(ep, 0) + 1
        if t == "custom-title" and isinstance(o.get("customTitle"), str) and o["customTitle"]:
            fs.titles.append(o["customTitle"])
        if not fs.cwd and isinstance(o.get("cwd"), str):
            fs.cwd = o["cwd"]
        if not fs.branch and isinstance(o.get("gitBranch"), str):
            fs.branch = o["gitBranch"]
        if t == "user" and not fs.seen_first_user:
            fs.seen_first_user = True
            if o.get("scheduledTaskId") or o.get("cron"):
                fs.sched_first = True
        if (t == "user" and not fs.first_prompt and not o.get("isMeta")
                and not o.get("toolUseResult")):
            tx = text_of(msg.get("content"))
            if tx.strip():
                # Held in memory for regex matching only; never emitted.
                fs.first_prompt = tx.lstrip()[:400]
    # >1% unparseable (a lone torn final line excused) -> unreadable.
    excess = fs.unparseable - (1 if fs.torn_final else 0)
    if fs.lines and excess > 0 and excess > UNPARSEABLE_FILE_THRESHOLD * fs.lines:
        fs.unreadable = "unparseable>1%"
    return fs


def classify(fs):
    """Returns (session_class, signal, ticket_id). Design §2."""
    for ti in fs.titles:
        m = RX_GATE_TITLE.match(ti)
        if m:
            return "gate", "title:" + m.group(1).lower(), m.group(2)
    fp = fs.first_prompt
    for name, rx in (("review", RX_P_REVIEW), ("test", RX_P_TEST), ("ux", RX_P_UX)):
        m = rx.match(fp)
        if m:
            return "gate", "prompt:" + name, m.group(1)
    for ti in fs.titles:
        m = RX_TASK_TITLE.match(ti) or RX_DEBUG_TITLE.match(ti)
        if m:
            return "ticket", "title", m.group(1)
    m = RX_P_TASK.match(fp.replace("\n", " "))
    if m:
        return "ticket", "prompt:task-id", m.group(1)
    m = RX_WT.search(fs.cwd)
    if m:
        return "ticket", "cwd:worktree", m.group(1).upper()
    m = RX_BR.match(fs.branch)
    if m:
        return "ticket", "gitBranch", m.group(1).upper()
    if fs.sched_first:
        return "scheduled", "first-user-record", None
    ep = None
    if fs.entrypoints:
        ep = sorted(fs.entrypoints.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
    if ep == "sdk-cli":
        if RX_TMP_CWD.match(fs.cwd):
            return "other", "sdk-cli:tempdir-cwd", None
        return "scheduled", "sdk-cli:headless", None
    return "other", "none", None
