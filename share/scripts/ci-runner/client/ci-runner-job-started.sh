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
import sys

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
sys.exit(0)
PY
