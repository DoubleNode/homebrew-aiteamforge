"""
release_walkthrough.py -- manual walkthrough protocol (XACA-1347-005, spec RELEASE-LIFECYCLE 6.6).

Stdlib only, py3.9-safe. PURE logic (pending_cases / format_case / answer_record / run_walkthrough)
is split from I/O: the driver takes INJECTED callables, so it is testable without a terminal,
network or board.

The six 6.6 points and where they live:
  1. one case at a time, with ID/title/preconditions/steps/expected/env/device -> format_case + loop
  2. device prerequisite confirmed BEFORE the first case; not confirmed -> nothing posted, the stage
     stays running (status "device-not-confirmed")
  3. Pass / Fail / Skip; Fail and Skip demand a note (a Skip note is its reason)
  4. each answer is POSTED immediately, one record per post, BEFORE the next case is shown. A failed
     post STOPS the walkthrough: the next case is never shown over an unrecorded answer.
  5. resumable: "pending" is DERIVED FROM RECORDS (cases with no current record at the stage SHA),
     never from a counter file. Interrupted after N answers -> N records -> next run starts at N+1.
  6. a Fail does not end the walkthrough; the lead is asked "continue or stop?".

Injected callables:
  prompt(question, choices) -> str   choices is a list of labels (answer must match one, case-
                                     insensitive, first-letter shortcut allowed) or None for free text.
  post(records) -> ids               records is a list of PROTO records (one per call). Must RAISE on
                                     any failure (transport error, 409 stale sha, ...).
  after_record(record, ids)          OPTIONAL hook, called after each SUCCESSFUL post. Spec 6.6.4 has
                                     the Testing Log re-published after every answer from CR onward;
                                     that is another ticket, this is where it plugs in. An exception
                                     in the hook is caught and listed in summary["hookErrors"] (the
                                     answer is already recorded; the hook must not undo or halt it).
  now()                              answer-time clock (datetime or ISO string); default is the current UTC time.

Extra lead choice beyond the spec: "Quit" at a case prompt stops cleanly WITHOUT recording (the lead
can leave; resume picks the case up again). Bad input / a blank note is re-asked up to MAX_ASKS times
and then the walkthrough stops (nothing is recorded) -- no infinite loop on a dead terminal.

"Pending" = no CURRENT record (release_gate._current_record: latest record for that test at the
stage SHA with supersededBy null) -- a FAIL is an answer, so a failed case is not re-asked; the lead
re-tests it through the supersede flow, not by re-walking.
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from release_gate import _current_index  # noqa: E402
from release_runner import RunnerError, _iso, _under, build_expected, load_cases  # noqa: E402

MAX_ASKS = 3
PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"
_ANSWERS = ("Pass", "Fail", "Skip", "Quit")


def case_test_name(case):
    """Expected-set name for a manual case (matches release_runner._manual_expected)."""
    return "%s %s" % (case["id"], case["title"])


def pending_cases(cases, tests, stage, sha, test_name=case_test_name):
    """Cases with NO current record at `sha` for `stage`, in case-file order (resume-at-N+1).
    Superseded records and records at another SHA do not count as answers."""
    current = _current_index(tests, stage, sha)   # one pass, not one scan per case
    return [c for c in cases if current.get(test_name(c)) is None]


def format_case(case, provider):
    """Human-readable presentation of one case (6.6.1)."""
    provider = provider or {}
    device = provider.get("device") if isinstance(provider.get("device"), dict) else {}
    lines = ["%s: %s" % (case["id"], case["title"])]
    lines.append("Environment: %s" % (provider.get("envLabel") or "(not declared)"))
    lines.append("Device: %s" % (device.get("description") or
                                 ("required" if device.get("required") else "none required")))
    lines.append("Preconditions: %s" % (case.get("preconditions") or "none"))
    lines.append("Steps:")
    for i, s in enumerate(case.get("steps") or [], 1):
        lines.append("  %d. %s" % (i, s))
    lines.append("Expected: %s" % (case.get("expected") or "(not specified)"))
    return "\n".join(lines)


def answer_record(case, stage, sha, env_label, lead, result, note, now=None):
    """Build the proto `Manual` record for one answer. Raises RunnerError on an invalid answer."""
    if not isinstance(lead, str) or not lead.strip():
        raise RunnerError("lead name is required (runBy of a manual record must be non-empty)")
    result = (result or "").upper()
    if result not in (PASS, FAIL, SKIP):
        raise RunnerError("result must be PASS, FAIL or SKIP (got %r)" % result)
    note = (note or "").strip()
    if result in (FAIL, SKIP) and not note:
        raise RunnerError("a %s answer requires a note%s" % (result, " (the reason)" if result == SKIP else ""))
    if not env_label or not str(env_label).strip():
        raise RunnerError("env label is required (provider envLabel)")
    return {"ref": "m1", "parentRef": None, "stage": stage, "type": "Manual", "ts": _iso(now),
            "env": env_label, "sha": sha, "test": case_test_name(case), "result": result,
            "runBy": lead.strip(), "notes": note}


def _ask(prompt, question, choices):
    """Ask up to MAX_ASKS times for a valid answer; return the canonical choice / text or None."""
    for _ in range(MAX_ASKS):
        try:
            raw = prompt(question, choices)
        except (EOFError, KeyboardInterrupt):
            return None
        raw = (raw or "").strip()
        if choices is None:
            if raw:
                return raw
            continue
        low = raw.lower()
        for c in choices:
            if low and (low == c.lower() or low == c[0].lower()):
                return c
    return None


def _filter_cases(provider, stage, cases):
    if stage == "GAMMA" or provider.get("filter") == "prodSafe":
        if provider.get("filter") != "prodSafe":
            raise RunnerError("GAMMA runs against production; manual provider %r lacks filter 'prodSafe'; "
                              "refusing to walk it" % provider.get("name"))
        return [c for c in cases if c.get("prodSafe")]
    return list(cases)


def _summary(status, answered, remaining, hook_errors, detail=None):
    s = {"status": status, "answered": answered, "remaining": remaining, "hookErrors": hook_errors}
    if detail:
        s["detail"] = detail
    return s


def run_walkthrough(provider, cases, release, stage, *, lead, prompt, post, now=None, after_record=None):
    """Drive the walkthrough. `release` supplies stageSha[stage] and tests[] (read once, at start).
    Returns {status: complete|stopped|device-not-confirmed|post-failed, answered, remaining, ...}.
    Raises RunnerError for a refusal before anything is shown (empty lead, GAMMA without prodSafe)."""
    if not isinstance(lead, str) or not lead.strip():
        raise RunnerError("lead name is required")
    sha = (release.get("stageSha") or {}).get(stage)
    if not sha:
        raise RunnerError("release has no stageSha for %s; record the stage SHA first" % stage)
    env_label = provider.get("envLabel") or stage
    todo = pending_cases(_filter_cases(provider, stage, cases), release.get("tests"), stage, sha)
    answered, hook_errors = 0, []
    if not todo:
        return _summary("complete", 0, 0, hook_errors)

    device = provider.get("device") if isinstance(provider.get("device"), dict) else {}
    if device.get("required"):
        q = "Device prerequisite: %s -- confirmed and ready?" % (device.get("description") or "required device")
        if _ask(prompt, q, ["Yes", "No"]) != "Yes":
            return _summary("device-not-confirmed", 0, len(todo), hook_errors)

    for i, case in enumerate(todo):
        q = "%s\n\nResult for %s?" % (format_case(case, provider), case["id"])
        ans = _ask(prompt, q, list(_ANSWERS))
        if ans is None or ans == "Quit":
            return _summary("stopped", answered, len(todo) - i, hook_errors)
        note = ""
        if ans in ("Fail", "Skip"):
            note = _ask(prompt, "Note for %s (%s)" % (case["id"], "reason for skipping" if ans == "Skip"
                                                      else "what failed"), None)
            if note is None:
                return _summary("stopped", answered, len(todo) - i, hook_errors, "no note given")
        rec = answer_record(case, stage, sha, env_label, lead, ans.upper(), note, now)
        try:
            ids = post([rec])
        except Exception as e:  # noqa: BLE001 -- ANY post failure must stop before the next case
            return _summary("post-failed", answered, len(todo) - i, hook_errors, "%s" % (e,))
        answered += 1
        if after_record is not None:
            try:
                after_record(rec, ids)
            except Exception as e:  # noqa: BLE001
                hook_errors.append("%s: %s" % (case["id"], e))
        left = len(todo) - i - 1
        if ans == "Fail" and left:
            if _ask(prompt, "%s failed. Continue with the %d remaining case(s) or stop?" % (case["id"], left),
                    ["Continue", "Stop"]) != "Continue":
                return _summary("stopped", answered, left, hook_errors)
    return _summary("complete", answered, 0, hook_errors)


# ---------------------------------------------------------------- thin CLI (I/O only)

class PostError(Exception):
    pass


def _bearer_key():
    """Bearer key via scripts/kb-api-key (same source as kanban-helpers' _kb_lcars_auth_args)."""
    for base in (os.environ.get("AITEAMFORGE_DIR"), os.path.expanduser("~/dev-team")):
        exe = os.path.join(base, "scripts", "kb-api-key") if base else None
        if exe and os.access(exe, os.X_OK):
            try:
                out = subprocess.run(["bash", exe, "show"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     timeout=10).stdout.decode().strip()
            except (OSError, subprocess.SubprocessError):
                return ""
            return out
    return ""


def _entry_name(e):
    return e if isinstance(e, str) else (e.get("test") if isinstance(e, dict) else None)


def expected_to_send(manual_expected, release, stage, sha):
    """The `expected` to put in the NEXT post, or None for a records-only post.

    The /tests endpoint (B1, XACA-1347-031/-008) 409s a records-only post while
    stages.<S>.expectedSha != the graded SHA, and once a set is recorded for the SHA it may only be
    ADDED to. So: nothing stored for this SHA -> the manual set; stored (e.g. by an automated
    `kb-release test`) -> the stored entries untouched PLUS the manual names it lacks (a superset,
    never a relaxation); stored already has every manual name -> None (records-only is valid).
    `release` is a FRESH read of the board, not the snapshot taken at walkthrough start."""
    manual = list(manual_expected)
    st = (release.get("stages") or {}).get(stage) if isinstance(release.get("stages"), dict) else None
    st = st if isinstance(st, dict) else {}
    stored = st.get("expected")
    if not isinstance(stored, list) or str(st.get("expectedSha") or "").lower() != str(sha).lower():
        return manual
    have = {_entry_name(e) for e in stored}
    missing = [e for e in manual if _entry_name(e) not in have]
    return list(stored) + missing if missing else None


def _http_send(url, payload, timeout=30):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    key = _bearer_key()
    if key:
        req.add_header("Authorization", "Bearer " + key)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        raise PostError("HTTP %d: %s" % (e.code, e.read().decode(errors="replace")[:300]))
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise PostError("transport failure: %s" % (e,))


def make_poster(base_url, release_id, stage, sha, timeout=30, *, manual_expected=None, read_release=None,
                send=None):
    """post(records) -> ids over POST /api/releases/<id>/stages/<STAGE>/tests. Raises PostError.

    With `manual_expected` + `read_release` the poster satisfies B1's expected lock (see
    expected_to_send): until ONE post has succeeded it re-reads the board and attaches the (union)
    expected set; after that the set is locked in for this SHA and posts are records-only. A failed
    first post keeps it armed. An unreadable board raises (nothing is posted blind). `send` is the
    injectable transport (url, payload) -> dict."""
    url = "%s/api/releases/%s/stages/%s/tests" % (base_url.rstrip("/"), release_id, stage)
    send = send or (lambda u, payload: _http_send(u, payload, timeout))
    state = {"locked": manual_expected is None}

    def post(records):
        payload = {"sha": sha, "records": records}
        if not state["locked"]:
            try:
                exp = expected_to_send(manual_expected, read_release(), stage, sha)
            except Exception as e:  # noqa: BLE001 -- never post without knowing the stored set
                raise PostError("cannot read the stored expected set: %s" % (e,))
            if exp is not None:
                payload = {"sha": sha, "expected": exp, "records": records}
        out = send(url, payload)
        state["locked"] = True
        return out.get("ids", [])
    return post


def _load_release(kanban_dir, release_id):
    for path in sorted(glob.glob(os.path.join(kanban_dir, "*-board.json"))):
        with open(path, "r", encoding="utf-8") as fh:
            for r in (json.load(fh).get("releases") or []):
                if r.get("id") == release_id:
                    return r
    raise RunnerError("release %s not found under %s" % (release_id, kanban_dir))


def main(argv=None):
    ap = argparse.ArgumentParser(description="Manual release walkthrough (spec 6.6)")
    ap.add_argument("--release", required=True)
    ap.add_argument("--stage", required=True)
    ap.add_argument("--provider", required=True, help="manual provider name")
    ap.add_argument("--kanban-dir", required=True)
    ap.add_argument("--lead", required=True)
    ap.add_argument("--port", type=int, default=int(os.environ.get("KB_LCARS_PORT", "0") or 0))
    a = ap.parse_args(argv)
    try:
        from release_providers import load_providers, providers_for_stage
        if not a.port:
            raise RunnerError("LCARS port unknown: pass --port or set KB_LCARS_PORT")
        release = _load_release(a.kanban_dir, a.release)
        doc = load_providers(os.path.join(a.kanban_dir, "config", "test-providers.json"))
        prov = [p for p in providers_for_stage(doc, a.stage) if p.get("name") == a.provider and p.get("kind") == "manual"]
        if not prov:
            raise RunnerError("no manual provider %r declared for %s" % (a.provider, a.stage))
        # same containment as the runner's manual expected set: a `cases` path / symlink cannot escape kanban_dir
        cases = load_cases(_under(a.kanban_dir, prov[0]["cases"], "cases"))
        sha = (release.get("stageSha") or {}).get(a.stage)
        # The manual expected set, built by the SAME code the runner uses for a manual provider (names,
        # optional flag, prodSafe filter), so it can never disagree with `kb-release test`'s set.
        manual, problems = build_expected([prov[0]], repo_dir=None, kanban_dir=a.kanban_dir)
        if problems:
            raise RunnerError("; ".join(problems))
        post = make_poster("http://localhost:%d" % a.port, a.release, a.stage, sha, manual_expected=manual,
                           read_release=lambda: _load_release(a.kanban_dir, a.release))

        def prompt(q, choices):
            return input("\n%s%s\n> " % (q, " [%s]" % "/".join(choices) if choices else ""))
        s = run_walkthrough(prov[0], cases, release, a.stage, lead=a.lead, prompt=prompt, post=post)
    except Exception as e:  # noqa: BLE001 -- CLI boundary: one-line named error, nonzero exit
        print("release_walkthrough: %s" % (e,), file=sys.stderr)
        return 2
    print(json.dumps(s))
    return 0 if s["status"] == "complete" else 1


if __name__ == "__main__":
    sys.exit(main())
