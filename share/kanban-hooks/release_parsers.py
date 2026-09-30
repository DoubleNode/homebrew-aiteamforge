"""
release_parsers.py -- test-output parsers for release providers (XACA-1347, spec RELEASE-LIFECYCLE 6.2/6.4/7.1/7.2).

Pure module: no subprocess, no file I/O (parsers receive strings), stdlib only, py3.9-safe.
Parsers produce PROTO-results; the runner turns them into full spec 6.2 records
(id, ts, sha, stage, runBy, supersededBy).

Proto-result shape:
    {"test": str, "result": "PASS"|"FAIL"|"SKIP", "notes": str,
     "children": [{"test": <parent> + CHILD_SEP + <child>, "result": ..., "notes": ...}]}

Rules enforced here (spec 6.4): exit code alone is never trusted; a parent is PASS only if
exit 0 AND no child FAIL AND at least one parseable result; a provider crash, timeout or
unparseable output becomes a FAIL record named "<provider>::harness". FAIL and SKIP always
carry non-empty notes so the records validate.

Deliberate fail-closed choices (a stream that hits one has zero results, which grades FAIL):
  * TAP: a pass line is lowercase `ok` followed by a test number, `-`, or end of line. Bare
    `ok some prose` is valid TAP but is treated as noise, never as a pass (XACA-1347-024).
    `not ok` detection stays case/whitespace tolerant and accepts any trailing text.
  * JUnit: the whole tree is checked against a structural (element, allowed parents) allowlist
    (_JUNIT_PARENTS); unknown, namespaced, case-variant or misplaced elements are parse errors
    (XACA-1347-025/-026). Every <testcase> is graded exactly once and every failure/error must
    sit directly in a graded <testcase>. Declared failures/errors
    are parse errors. `tests=` is NOT reconciled (pytest 9 counts subtests; see _check_junit_counts).
    Surefire flaky*/rerun* elements are allowed but never grade; rerun* without a failure/error and
    flaky* beside one are parse errors (XACA-1347-027/-028).

What each parser accepts, rejects and how it grades, with the incident behind each rule:
docs/release-workflow/test-output-formats.md (keep it in step with this module).
"""
import json
import re
import xml.etree.ElementTree as ET

from release_schema import TEST_RESULTS

CHILD_SEP = " › "   # "file > check" (U+203A), spec 6.2 `test` field
PARSERS = ("tap", "junit", "jsonl", "line-regex")
_NO_MSG = {"FAIL": "failed (no message from test output)",
           "SKIP": "skipped (no reason given)"}


class ParseResult(object):
    """results: list of proto-results; error: str when output is unparseable/malformed, else None."""

    def __init__(self, results=None, error=None):
        self.results = results if results is not None else []
        self.error = error

    def __repr__(self):
        return "ParseResult(results=%r, error=%r)" % (self.results, self.error)


class _ParseError(Exception):
    pass


# --------------------------------------------------------------------- helpers
def _notes(result, notes):
    """FAIL/SKIP must have non-empty notes; PASS keeps whatever it has."""
    notes = (notes or "").strip()
    if not notes and result in _NO_MSG:
        return _NO_MSG[result]
    return notes


def _child(parent, name, result, notes):
    return {"test": parent + CHILD_SEP + name, "result": result, "notes": _notes(result, notes)}


def _finish_parent(name, explicit, notes, children):
    """Build a proto-result; a parent's result folds in its children (any FAIL -> FAIL;
    all SKIP -> SKIP; else PASS). An explicit FAIL/SKIP on the parent itself is kept."""
    kids = [c["result"] for c in children]
    failed = [c["test"] for c in children if c["result"] == "FAIL"]
    if explicit == "FAIL" or failed:
        result = "FAIL"
        if not (notes or "").strip() and failed:
            notes = "child failed: " + ", ".join(failed[:5]) + (" ..." if len(failed) > 5 else "")
    elif explicit == "SKIP":
        result = "SKIP"
    elif kids and all(k == "SKIP" for k in kids):
        result = "SKIP"
        if not (notes or "").strip():
            notes = "all children skipped"
    else:
        result = "PASS"
    return {"test": name, "result": result, "notes": _notes(result, notes), "children": children}


def _leaf(name, result, notes):
    return {"test": name, "result": result, "notes": _notes(result, notes), "children": []}


# ------------------------------------------------------------------------- TAP
# Asymmetric on purpose (fails closed): `not ok` is case- and whitespace-tolerant, because a line
# that LOOKS like a failing test ("NOT OK", "not  ok", "not okay") must never be dropped as noise.
# A passing `ok` must be lowercase (TAP spec) and followed by whitespace or end of line, so log
# noise such as "OK: connected" / "okay" / "OK 1 - a" is never counted as a pass (XACA-1347-019).
# DELIBERATE fail-closed tightening (XACA-1347-024): a passing line is `ok` then a test number,
# `-`, or end of line. Bare `ok some prose` is valid TAP (number optional) but is indistinguishable
# from log noise, so it is NOT a test line; a stream of only such lines has zero results = FAIL.
# `not ok` keeps accepting any trailing text, so a failure is never dropped.
_TAP_TEST = re.compile(r"^(\s*)((?i:not\s+ok)|ok(?=\s+(?:\d|-)|\s*$))\s*(\d+)?\s*(?:-\s*)?(.*)$")
_TAP_PLAN = re.compile(r"^1\.\.(\d+)\s*(?:#.*)?$")
_TAP_DIRECTIVE = re.compile(r"\s#\s*(SKIP\w*|TODO)\b[\s:]*(.*)$", re.IGNORECASE)
_TAP_BAIL = re.compile(r"^\s*Bail out!\s*(.*)$", re.IGNORECASE)


def _parse_tap(text, default_test):
    tests = []       # top-level entries: [name, explicit, notes, children]
    pending = []     # indented (subtest) results waiting for their parent line
    plan = None
    last = None      # last test entry, for YAML `message:` capture
    in_yaml = False
    for raw in text.splitlines():
        bail = _TAP_BAIL.match(raw)
        if bail:
            raise _ParseError("TAP bailed out: " + (bail.group(1).strip() or "(no reason)"))
        stripped = raw.strip()
        if stripped == "---" and raw[:1].isspace():    # YAML blocks are indented under a test line
            in_yaml = True
            continue
        if in_yaml:
            if stripped and not raw[:1].isspace():
                raise _ParseError("TAP YAML block not terminated by '...' before line %r" % stripped[:40])
            if stripped == "...":
                in_yaml = False
            elif last is not None and stripped.startswith("message:") and not last[2]:
                last[2] = stripped[len("message:"):].strip().strip("'\"")
            continue
        plan_m = _TAP_PLAN.match(raw)
        if plan_m:                       # only a column-0 plan counts; subtest plans are ignored
            plan = int(plan_m.group(1))
            continue
        m = _TAP_TEST.match(raw)
        if not m:
            continue                     # noise / comments / "TAP version" / "# Subtest:"
        indent, status, num, desc = m.group(1), m.group(2), m.group(3), m.group(4).strip()
        result = "PASS" if status.lower() == "ok" else "FAIL"
        notes = ""
        d = _TAP_DIRECTIVE.search(" " + desc)
        if d:
            kind, reason = d.group(1).upper(), d.group(2).strip()
            desc = _TAP_DIRECTIVE.sub("", " " + desc).strip()
            result = "SKIP"              # TODO must yield neither FAIL nor PASS
            if kind == "TODO":
                notes = "TODO: " + (reason or "(no reason given)")
            else:
                notes = reason
        name = desc or ("test %s" % num if num else "test %d" % (len(tests) + len(pending) + 1))
        if indent:
            pending.append({"name": name, "result": result, "notes": notes})
            continue
        entry = [name, result, notes, pending]
        pending = []
        tests.append(entry)
        last = entry
    if in_yaml:
        raise _ParseError("TAP YAML block not terminated by '...' (output truncated?)")
    if pending:                          # subtests with no following parent line
        tests.append([default_test or "(unnamed)", None, "", pending])
    if plan is not None and plan != len(tests):
        raise _ParseError("TAP plan 1..%d but %d test line(s) found" % (plan, len(tests)))
    results = []
    for name, explicit, notes, kids in tests:
        if kids:
            children = [_child(name, k["name"], k["result"], k["notes"]) for k in kids]
            results.append(_finish_parent(name, explicit, notes, children))
        else:
            results.append(_leaf(name, explicit, notes))
    return results


# ----------------------------------------------------------------------- JUnit
def _junit_int(suite, attr):
    raw = suite.get(attr)
    if raw is None:
        return None
    try:
        val = int(raw.strip())
    except ValueError:
        raise _ParseError("JUnit <%s %s=%r> is not an integer" % (suite.tag, attr, raw))
    if val < 0:
        raise _ParseError("JUnit <%s %s=%r> is negative" % (suite.tag, attr, raw))
    return val


def _check_junit_counts(suite):
    """Declared failures+errors must be matched by at least that many <failure>/<error> ELEMENTS in
    the suite's subtree, else the report is lying or truncated (fail closed). Applied at every level.
    Declared LOWER than actual is fine: the failing cases still FAIL. Elements are counted, not
    failing testcases, because pytest 9 emits one <failure> per failing SUBTEST and several can sit
    in one <testcase> (measured: failures="3" with 2 failing testcases and 3 <failure> elements).

    `tests=` is deliberately NOT reconciled (XACA-1347-025 round 4): producers disagree on what it
    counts. Measured, pytest 9 counts subtests, e.g. tests="106" over 38 <testcase> for a report
    with no failure at all, so any equality or over-declaration check false-fails a genuine pass.
    Truncation is caught two other ways: a cut-off XML report does not parse (already an error), and
    tests that never ran fail the gate through the expected set built from listCommand. The value is
    still required to be a non-negative integer when present."""
    _junit_int(suite, "tests")
    declared = sum(v for v in (_junit_int(suite, "failures"), _junit_int(suite, "errors")) if v)
    actual = sum(1 for el in suite.iter() if el.tag in ("failure", "error"))
    if declared > actual:
        name = suite.get("name") or suite.tag
        raise _ParseError("JUnit <%s> %r declares %d failure(s)/error(s) but only %d <failure>/<error> in its subtree"
                          % (suite.tag, name, declared, actual))


# XACA-1347-025/-026: structural allowlist. element -> tags allowed as its parent (None = may be the
# root). Every element of the document must appear here under an allowed parent, else the report
# is rejected. Anything not listed (unknown, namespaced `{ns}tag`, case variants such as <Failure>)
# has no grading path, so accepting it could silently drop a recorded result: fail closed instead.
_JUNIT_RERUN_TAGS = ("flakyFailure", "flakyError", "rerunFailure", "rerunError")
_JUNIT_PARENTS = {
    "testsuites": (None,),
    "testsuite": (None, "testsuites", "testsuite"),
    "testcase": ("testsuite",),
    "failure": ("testcase",),
    "error": ("testcase",),
    "skipped": ("testcase",),
    "properties": ("testsuites", "testsuite", "testcase"),
    "property": ("properties",),
    # XACA-1347-027/-028: Maven Surefire rerunFailingTestsCount elements (surefire-test-report.xsd).
    # NON-grading, testcase-only; contents are exactly stackTrace/system-out/system-err (text only).
    "flakyFailure": ("testcase",),
    "flakyError": ("testcase",),
    "rerunFailure": ("testcase",),
    "rerunError": ("testcase",),
    "stackTrace": _JUNIT_RERUN_TAGS,
    "system-out": ("testsuites", "testsuite", "testcase") + _JUNIT_RERUN_TAGS,
    "system-err": ("testsuites", "testsuite", "testcase") + _JUNIT_RERUN_TAGS,
}
_JUNIT_FLAKY_TAGS = ("flakyFailure", "flakyError")


def _check_junit_structure(root):
    """Validate the WHOLE tree against _JUNIT_PARENTS; return the child->parent map."""
    parent_of = {}
    for par in root.iter():
        for child in par:
            parent_of[child] = par
    for el in root.iter():
        par = parent_of.get(el)
        ptag = par.tag if par is not None else None
        allowed = _JUNIT_PARENTS.get(el.tag) if isinstance(el.tag, str) else None
        if allowed is None or ptag not in allowed:
            raise _ParseError("JUnit element <%s> is not allowed under %s (allowed JUnit structure only; "
                              "unknown, namespaced and case-variant elements are rejected)"
                              % (el.tag, "<%s>" % ptag if ptag else "the document root"))
    return parent_of


def _parse_junit(text, default_test):
    lowered = text.lower()
    if "<!doctype" in lowered or "<!entity" in lowered:
        raise _ParseError("JUnit XML rejected: DOCTYPE/ENTITY declarations are not allowed")
    try:
        root = ET.fromstring(text.encode("utf-8"))
    except (ET.ParseError, ValueError) as exc:
        raise _ParseError("invalid or truncated JUnit XML: %s" % exc)
    if root.tag not in ("testsuite", "testsuites"):
        raise _ParseError("JUnit root element must be <testsuites> or <testsuite>, got <%s>" % root.tag)
    parent_of = _check_junit_structure(root)
    suites = list(root.iter("testsuite"))   # includes root and NESTED suites: none may be skipped
    if root.tag == "testsuites":
        _check_junit_counts(root)    # the aggregate root is reconciled too (XACA-1347-015)
    results = []
    graded = []
    for suite in suites:
        cases = suite.findall("testcase")
        _check_junit_counts(suite)
        if not cases:
            continue
        name = suite.get("name") or suite.get("file") or default_test or "(unnamed suite)"
        children = []
        for tc in cases:
            graded.append(tc)
            cname = tc.get("name") or "(unnamed)"
            if tc.get("classname"):
                cname = tc.get("classname") + "." + cname
            result, notes = "PASS", ""
            bad = tc.find("failure")
            if bad is None:
                bad = tc.find("error")
            skip = tc.find("skipped")
            flakes = [el for el in tc if el.tag in _JUNIT_FLAKY_TAGS]
            reruns = [el for el in tc if el.tag in ("rerunFailure", "rerunError")]
            # Surefire rerun elements never grade. A flake means the test ultimately PASSED, so a
            # failure/error beside it is a contradiction; a rerun means every retry failed, so the
            # terminal failure/error must be there. Either shape is a malformed report: fail closed.
            if flakes and bad is not None:
                raise _ParseError("JUnit <testcase> %r has <%s> (passed on rerun) AND <%s> (failed): contradictory report"
                                  % (cname, flakes[0].tag, bad.tag))
            if reruns and bad is None:
                raise _ParseError("JUnit <testcase> %r has <%s> but no <failure>/<error>: malformed surefire report"
                                  % (cname, reruns[0].tag))
            if bad is not None:
                result = "FAIL"
                first = (bad.text or "").strip().splitlines()
                notes = bad.get("message") or (first[0] if first else "")
            elif skip is not None:
                result = "SKIP"
                notes = skip.get("message") or (skip.text or "").strip()
            if flakes:
                flaky_note = "flaky: passed on rerun after %d failure(s)" % len(flakes)
                notes = (notes + "; " + flaky_note) if notes else flaky_note
            children.append(_child(name, cname, result, notes))
        results.append(_finish_parent(name, None, "", children))
    # Invariant: every <testcase> in the document is graded exactly once. A case under a wrapper
    # element or nested in another <testcase> has no grading path, so it must not vanish silently.
    graded_ids = [id(tc) for tc in graded]
    if len(graded_ids) != len(set(graded_ids)):
        raise _ParseError("JUnit <testcase> graded more than once (internal inconsistency)")
    seen = set(graded_ids)
    # Result carriers: every failure/error must be a direct child of a graded testcase (belt and
    # braces over the structure walk; it makes "a recorded failure is never dropped" self-evident).
    for el in root.iter():
        if el.tag in ("failure", "error") and id(parent_of.get(el)) not in seen:
            raise _ParseError("JUnit <%s> is not inside a graded <testcase> (would be ungraded)" % el.tag)
    orphans = [tc for tc in root.iter("testcase") if id(tc) not in seen]
    if orphans:
        names = ", ".join(repr((tc.get("classname") + "." if tc.get("classname") else "") + (tc.get("name") or "(unnamed)"))
                          for tc in orphans[:5])
        raise _ParseError("JUnit %d <testcase> not directly inside a <testsuite> (would be ungraded): %s%s"
                          % (len(orphans), names, " ..." if len(orphans) > 5 else ""))
    return results


# ----------------------------------------------------------------------- JSONL
_JSONL_KEYS = ("test", "result", "notes", "parent")


class _DupKey(ValueError):
    pass


def _no_dup_keys(pairs):
    """object_pairs_hook: a repeated key is ambiguous (last-wins would let FAIL then PASS grade
    PASS), so it is rejected. Unknown keys are rejected by the caller with the line number."""
    seen = {}
    for k, v in pairs:
        if k in seen:
            raise _DupKey(k)
        seen[k] = v
    return seen


def _parse_jsonl(text, default_test):
    entries = []
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            obj = json.loads(line, object_pairs_hook=_no_dup_keys)
        except _DupKey as exc:
            raise _ParseError("line %d: duplicate JSON key %s" % (n, exc))
        except ValueError as exc:
            raise _ParseError("line %d: invalid JSON (%s)" % (n, exc))
        if not isinstance(obj, dict):
            raise _ParseError("line %d: expected a JSON object" % n)
        for key in obj:
            if key not in _JSONL_KEYS:
                raise _ParseError("line %d: unknown key %r (allowed: %s); result-bearing keys such as "
                                  "children/status/outcome are not supported" % (n, key, ", ".join(_JSONL_KEYS)))
        test = obj.get("test")
        if not isinstance(test, str) or not test.strip():
            raise _ParseError("line %d: 'test' must be a non-empty string" % n)
        res = obj.get("result")
        if not isinstance(res, str) or res.upper() not in TEST_RESULTS:
            raise _ParseError("line %d: 'result' must be one of %s" % (n, list(TEST_RESULTS)))
        notes = obj.get("notes", "")
        if notes is None:
            notes = ""
        if not isinstance(notes, str):
            raise _ParseError("line %d: 'notes' must be a string" % n)
        parent = obj.get("parent")
        if parent is not None and (not isinstance(parent, str) or not parent.strip()):
            raise _ParseError("line %d: 'parent' must be a non-empty string" % n)
        entries.append({"test": test, "result": res.upper(), "notes": notes, "parent": parent, "line": n})
    top = [e for e in entries if not e["parent"]]
    top_names = set(t["test"] for t in top)
    child_names = set(e["test"] for e in entries if e["parent"])
    for e in entries:
        if e["parent"] and e["parent"] in child_names:
            raise _ParseError("line %d: nested parents are not supported (%r)" % (e["line"], e["parent"]))
    order, kids = [], {}
    for e in entries:
        if e["parent"]:
            kids.setdefault(e["parent"], []).append(e)
            if e["parent"] not in top_names and e["parent"] not in order:
                order.append(e["parent"])        # synthesized parent, keeps first-seen order
        elif e["test"] not in order:
            order.append(e["test"])
    explicit = {}
    for t in top:
        if t["test"] in explicit:      # first-wins would let a later FAIL vanish
            raise _ParseError("line %d: duplicate top-level test %r (first seen line %d)"
                              % (t["line"], t["test"], explicit[t["test"]]["line"]))
        explicit[t["test"]] = t
    results = []
    for name in order:
        children = [_child(name, k["test"], k["result"], k["notes"]) for k in kids.get(name, [])]
        if name in explicit:
            ex = explicit[name]
            if children:
                results.append(_finish_parent(name, ex["result"], ex["notes"], children))
            else:
                results.append(_leaf(name, ex["result"], ex["notes"]))
        else:
            results.append(_finish_parent(name, None, "", children))
    return results


# ------------------------------------------------------------------ line-regex
_TOKENS = {"pass": "PASS", "ok": "PASS", "passed": "PASS",
           "fail": "FAIL", "failed": "FAIL", "error": "FAIL", "not ok": "FAIL",
           "skip": "SKIP", "skipped": "SKIP"}


def _parse_line_regex(text, pattern):
    if pattern is None or (isinstance(pattern, str) and not pattern):
        raise _ParseError("line-regex parser requires a pattern")
    try:
        rx = re.compile(pattern) if isinstance(pattern, str) else pattern
    except re.error as exc:
        raise _ParseError("invalid line-regex pattern: %s" % exc)
    groups = rx.groupindex
    if "test" not in groups or "result" not in groups:
        raise _ParseError("line-regex pattern needs named groups 'test' and 'result'")
    results = []
    for n, line in enumerate(text.splitlines(), 1):
        m = rx.search(line)
        if not m:
            continue
        token = (m.group("result") or "").strip().lower()
        if token not in _TOKENS:
            raise _ParseError("line %d: unmapped result token %r" % (n, m.group("result")))
        name = (m.group("test") or "").strip()
        if not name:
            raise _ParseError("line %d: empty test name" % n)
        notes = m.groupdict().get("notes") or ""
        results.append(_leaf(name, _TOKENS[token], notes))
    return results


# ------------------------------------------------------------------- public API
def parse(parser, text, *, default_test=None, pattern=None):
    """Parse provider output into a ParseResult. Unknown parser / malformed output -> .error set.

    default_test: parent name for formats with no natural parent. It is the fallback name for
    nameless suites/tests, and when every result is flat (no children) they are wrapped as
    children of ONE parent named default_test (per-file runs: parent = the file).
    """
    if parser not in PARSERS:
        return ParseResult([], "unknown parser %r (expected one of %s)" % (parser, list(PARSERS)))
    if not isinstance(text, str):
        return ParseResult([], "output must be a string")
    try:
        if parser == "tap":
            results = _parse_tap(text, default_test)
        elif parser == "junit":
            results = _parse_junit(text, default_test)
        elif parser == "jsonl":
            results = _parse_jsonl(text, default_test)
        else:
            results = _parse_line_regex(text, pattern)
    except _ParseError as exc:
        return ParseResult([], str(exc))
    # ONE shared invariant for every parser (XACA-1347-031): a full test name (top-level or child) appears
    # once per output. The gate grades the LATEST record per name, so FAIL-then-PASS under one name would
    # grade PASS; it is a parse error -> harness FAIL, exactly as a duplicate JSONL test already was.
    seen_names, dups = set(), []
    for r in results:
        for n in [r["test"]] + [c["test"] for c in r["children"]]:
            if n in seen_names and n not in dups:
                dups.append(n)
            seen_names.add(n)
    if dups:
        return ParseResult([], "duplicate test name(s) in one output (the gate would grade only the last): %s%s"
                           % (", ".join(repr(d) for d in dups[:5]), " ..." if len(dups) > 5 else ""))
    if default_test and results and not any(r["children"] for r in results):
        kids = [_child(default_test, r["test"], r["result"], r["notes"]) for r in results]
        results = [_finish_parent(default_test, None, "", kids)]
    return ParseResult(results, None)


def grade_parent(exit_code, parse_result, *, timed_out=False):
    """Spec 6.4 parent rule for a whole provider/file run -> (result, notes).

    FAIL: timeout, nonzero/missing exit, parse error, zero parseable results, any FAIL anywhere.
    SKIP: everything parsed was SKIP (never invent a pass). PASS: exit 0, no FAIL, >=1 result.
    """
    if timed_out:
        return "FAIL", "timed out"
    if isinstance(exit_code, bool) or not isinstance(exit_code, int):
        return "FAIL", "no exit code recorded (%r)" % (exit_code,)
    if exit_code != 0:
        return "FAIL", "exited with code %d" % exit_code
    if parse_result.error:
        return "FAIL", "unparseable output: %s" % parse_result.error
    results = parse_result.results
    if not results:
        return "FAIL", "exited 0 but produced no parseable results"
    failed = []
    for r in results:
        if r["result"] == "FAIL":
            failed.append(r["test"])
        failed.extend(c["test"] for c in r["children"] if c["result"] == "FAIL")
    if failed:
        return "FAIL", "%d failing: %s" % (len(failed), ", ".join(failed[:5]) + (" ..." if len(failed) > 5 else ""))
    if all(r["result"] == "SKIP" for r in results):
        reasons = "; ".join(r["notes"] for r in results[:3])
        return "SKIP", "all results skipped: " + reasons
    return "PASS", ""


def harness_fail(provider_name, reason):
    """Proto-result for a provider crash/timeout/unparseable output: never passes silently."""
    return {"test": "%s::harness" % provider_name, "result": "FAIL",
            "notes": (reason or "").strip() or "provider harness failed (no reason given)",
            "children": []}
