#!/bin/bash

#
#  ci-runner-job-started.sh
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 DoubleNode.com. All rights reserved.
#

# XACA-1442-003: job-started hook, fork defence in depth (plan Requirement 9).
# Referenced by ACTIONS_RUNNER_HOOK_JOB_STARTED (spike E8: honoured on a JIT
# runner; a non-zero exit fails the job before any step runs). Installed
# root-owned (guest /usr/local/sbin, host /usr/local/libexec) so the job cannot
# edit it. Runs in the guest and on the host: stdlib python3 only.
#
# Verdict, from $GITHUB_EVENT_NAME / $GITHUB_EVENT_PATH / $GITHUB_REPOSITORY.
# The rule is by PAYLOAD SHAPE, not by an event-name allowlist (XACA-1442-013):
#   * payload has a top-level `pull_request` key (any value):
#       .pull_request.head.repo.full_name must exist and equal
#       $GITHUB_REPOSITORY, else FAIL (a fork PR, a deleted fork, a payload
#       without it). This covers pull_request, pull_request_target,
#       pull_request_review, pull_request_review_comment (their merge ref is
#       the FORK's code, and a fork author can trigger the review events on
#       their own PR) and any future event that carries a PR.
#   * payload has a top-level `workflow_run` key: its
#       .workflow_run.head_repository.full_name likewise.
#   * STRICT events (pull_request*, workflow_run): the shape is REQUIRED. A
#       payload that is missing, unreadable, not an object, or lacks the head
#       repo FAILS, and so does a missing GITHUB_EVENT_PATH/GITHUB_REPOSITORY.
#   * any other event whose payload has neither key: PASS (push, schedule,
#       workflow_dispatch, issue_comment, check_run, check_suite,
#       merge_group...: they run base-repo code; issue_comment only nests a
#       PR URL stub, check_* carry no full_name to compare). An unreadable
#       payload on such an event PASSES: the runner writes it, a job cannot.
#
# Messages go to stderr and never include the payload.
#
# XACA-1468-003: job attribution capture. AFTER the fork verdict has passed
# (a denied job exits 1 first and writes nothing), the hook also reads the
# Kanban trailers the committing agent stamped into the commit/PR text:
#   push                         .head_commit.message
#   payload with `pull_request`  .pull_request.body
# Trailers come from the LAST trailer-shaped paragraph (every non-blank line is
# `Key: value`); PR bodies end in a non-trailer "Generated with" line, so the
# literal last paragraph would miss the block; lines
#   Kanban-Item: <ID>   Kanban-Team: <team>   Kanban-Agent: <name>
# and the first occurrence of each key wins. Each value is validated on its
# own and a failing one is dropped, never repaired:
#   item  ^[A-Z]{3,5}-[0-9]{3,5}$        team  ^[a-z0-9][a-z0-9-]{0,47}$
#   agent 1-96 printable characters (longer is rejected, NOT truncated)
# The survivors are written as {"item","team","agent"} (any subset) to
#   <runner-root>/_attribution/<GITHUB_RUN_ID>.json
# (GITHUB_RUN_ID must be 1-20 digits; no surviving key = no file). The file is
# written atomically (temp + rename) at 0644 into a 0755 directory, and files
# there older than 7 days are pruned. ci-runner-reporter.sh reads it by run_id.
#
# RUNNER ROOT = the install dir that contains `_diag/` (what the reporter
# globs `_diag/Worker_*.log` under). Layouts, from provision-host.sh and the
# JIT scripts: host /Users/ci-runner/actions-runner-macos and
# /Users/ci-runner/actions-runner-jit-macos-<slot>; guest /opt/actions-runner-<N>
# and /opt/actions-runner-jit-<slot>. In every layout the runner puts the job
# workspace under <root>/_work, so the root is found by taking the first of
# RUNNER_TEMP, RUNNER_WORKSPACE, RUNNER_TOOL_CACHE, GITHUB_WORKSPACE, then the
# hook's cwd, walking up to the ancestor named `_work`, and using its parent,
# provided that parent contains a `_diag` directory. No candidate resolves =
# write nothing. This needs no host-specific path, so macOS and Linux share it.
#
# NEVER-FAIL RULE: the fork verdict is the ONLY thing that may exit non-zero.
# Every attribution problem (bad payload, no runner root, unwritable dir, any
# exception) is swallowed, at most with a terse stderr note that never contains
# payload text, and the exit status stays 0.
#
# Bash 3.2 compatible (macOS /bin/bash).

set -u

event="${GITHUB_EVENT_NAME:-}"
strict=0
case "$event" in
    pull_request|pull_request_*|workflow_run) strict=1 ;;
esac

if [ -z "${GITHUB_EVENT_PATH:-}" ] || [ -z "${GITHUB_REPOSITORY:-}" ]; then
    [ "$strict" = 1 ] || exit 0
    echo "ci-runner-job-started: ${event} event without GITHUB_EVENT_PATH/GITHUB_REPOSITORY; refusing" >&2
    exit 1
fi

python3 - "$event" "$GITHUB_EVENT_PATH" "$GITHUB_REPOSITORY" "$strict" <<'PY'
import json
import os
import re
import stat
import sys
import time

event, path, repo, strict = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"


def deny(msg):
    sys.stderr.write("ci-runner-job-started: refusing %s: %s\n" % (event, msg))
    sys.exit(1)


try:
    with open(path) as f:
        payload = json.load(f)
except (OSError, ValueError):
    if strict:
        deny("event payload unreadable")
    sys.exit(0)

if not isinstance(payload, dict):
    if strict:
        deny("event payload is not an object")
    sys.exit(0)

checks = []     # (label, head repository object or None)
if "pull_request" in payload or (strict and event != "workflow_run"):
    node = payload.get("pull_request")
    inner = node.get("head") if isinstance(node, dict) else None
    checks.append(("pull_request", inner.get("repo") if isinstance(inner, dict) else None))
if event == "workflow_run" or "workflow_run" in payload:
    node = payload.get("workflow_run")
    checks.append(("workflow_run", node.get("head_repository") if isinstance(node, dict) else None))

for label, head in checks:
    full = head.get("full_name") if isinstance(head, dict) else None
    if not isinstance(full, str) or not full:
        deny("%s head repository missing from payload" % label)
    if full.lower() != repo.lower():
        deny("%s head repository differs from %s (fork)" % (label, repo))


# ---- XACA-1468-003: attribution (runs only after the fork verdict passed) ----
KEY_RE = re.compile(r"(Kanban-Item|Kanban-Team|Kanban-Agent):[ \t]*(.*?)[ \t]*\Z", re.I)
TRAILER_LINE_RE = re.compile(r"[A-Za-z0-9-]+: ")
ITEM_RE = re.compile(r"[A-Z]{3,5}-[0-9]{3,5}")
TEAM_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,47}")
RUN_ID_RE = re.compile(r"[0-9]{1,20}")
PRUNE_AGE = 7 * 24 * 3600


def trailer_shaped(para):
    """Every non-blank line is `Key: value` (or an indented continuation)."""
    lines = [l for l in para.split("\n") if l.strip()]
    return bool(lines) and all(
        TRAILER_LINE_RE.match(l) or (i > 0 and l[:1] in " \t") for i, l in enumerate(lines))


def trailers(text):
    """First Kanban-* value per key from the LAST trailer-shaped paragraph of text.

    Not the literal last paragraph: PR bodies must END with the "Generated with
    Claude Code" line, which is not trailer-shaped, so the Kanban block sits just
    above it. A paragraph of prose that merely mentions "Kanban-Item:" is not
    trailer-shaped (the key must start the line), so it never counts."""
    if not isinstance(text, str):
        return {}
    text = text.replace("\r\n", "\n").replace("\r", "\n").rstrip()
    paras = re.split(r"\n[ \t]*\n", text)
    found = {}
    for para in reversed(paras):
        if not trailer_shaped(para):
            continue
        for line in para.split("\n"):
            m = KEY_RE.match(line)
            if m:
                found.setdefault(m.group(1).lower()[len("kanban-"):], m.group(2))
        break
    return found


def valid(key, val):
    if key == "agent":
        return 1 <= len(val) <= 96 and val.isprintable()
    return (ITEM_RE if key == "item" else TEAM_RE).fullmatch(val) is not None


def runner_root():
    cands = [os.environ.get(k, "") for k in
             ("RUNNER_TEMP", "RUNNER_WORKSPACE", "RUNNER_TOOL_CACHE", "GITHUB_WORKSPACE")]
    try:
        cands.append(os.getcwd())
    except OSError:
        pass
    for c in cands:
        if not c or not os.path.isabs(c):
            continue
        cur = os.path.normpath(c)
        while True:
            parent = os.path.dirname(cur)
            if parent == cur:
                break
            if os.path.basename(cur) == "_work":
                if os.path.isdir(os.path.join(parent, "_diag")):
                    return parent
                break
            cur = parent
    return None


def prune(adir):
    cutoff = time.time() - PRUNE_AGE
    try:
        names = os.listdir(adir)
    except OSError:
        return
    for n in names:
        p = os.path.join(adir, n)
        try:
            st = os.lstat(p)
            if stat.S_ISREG(st.st_mode) and st.st_mtime < cutoff:
                os.unlink(p)
        except OSError:
            pass


def write_attribution():
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    if not RUN_ID_RE.fullmatch(run_id):
        return
    if "pull_request" in payload:
        node = payload.get("pull_request")
        text = node.get("body") if isinstance(node, dict) else None
    elif event == "push":
        node = payload.get("head_commit")
        text = node.get("message") if isinstance(node, dict) else None
    else:
        return
    raw = trailers(text)
    out = {}
    for key in ("item", "team", "agent"):
        if key in raw and valid(key, raw[key]):
            out[key] = raw[key]
    if not out:
        return
    root = runner_root()
    if root is None:
        return
    adir = os.path.join(root, "_attribution")
    if os.path.islink(adir):
        return
    if not os.path.isdir(adir):
        os.mkdir(adir, 0o755)
        os.chmod(adir, 0o755)
    final = os.path.join(adir, run_id + ".json")
    tmp = os.path.join(adir, ".tmp.%d.%s" % (os.getpid(), run_id))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(out, f)
        os.chmod(tmp, 0o644)
        os.rename(tmp, final)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    prune(adir)


try:
    write_attribution()
except BaseException:
    try:
        sys.stderr.write("ci-runner-job-started: attribution skipped\n")
    except Exception:
        pass
sys.exit(0)
PY
