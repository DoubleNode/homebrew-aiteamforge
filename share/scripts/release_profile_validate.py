#!/usr/bin/env python3
"""Post-draft mechanical validator for rendered release documents.

XACA-1343 Phase 3 (subitem -005). Spec: docs/release-workflow/RELEASE-LIFECYCLE.md
§ 11.3 "Validation after drafting is mechanical": a failure blocks publish.
Consumed by kb-wiki (XACA-1344) and kb-notify (XACA-1345). Stdlib only; runs
under /usr/bin/python3 3.9.

Public API (stable):
    validate_draft(rendered_body, title, profile, *, facts=None) -> list[Violation]
    assert_draft_valid(rendered_body, title, profile, *, facts=None) -> None
    Violation                (frozen dataclass: rule, detail, line; .to_dict())
    DraftValidationError     (.violations; message never echoes the body)

An empty list means valid. A profile carrying none of requiredSections,
bannedTokenPatterns, linkPolicy, titlePattern is valid for every body.
Everything here FAILS CLOSED: a malformed profile, an invalid or risky regex,
an oversized body all produce violations (never a crash, never a pass).

`facts` resolves linkPolicy.standardLinks[] `sourcePlaceholder` values (e.g.
"{{links.testingLog}}") to the concrete URL, so each standard link is identified
individually. It is REQUIRED in practice whenever the profile has a required,
placeholder-backed standard link: without it (or when the value is missing, '',
None, blank or not a string) that link cannot be identified and the draft FAILS
(`link-required-unresolved`); see LINKS.

SECTIONS (requiredSections)
    A section is located by its `label` (flat-string sugar: label == id). The
    first occurrence wins. Comparison ignores case, surrounding Markdown
    emphasis (** __ `), whitespace runs, and one trailing colon, but is
    otherwise EXACT: "Date/Time of change:" does not satisfy
    "Anticipated Date/Time of change:". Three forms are recognised, tried in
    this order per line (lines inside ``` fences are ignored):
      1. ATX heading   `## Label`. Section text = the lines after the heading up
                       to (not including) the next heading of the SAME OR HIGHER
                       level (level number <=), or end of document. Deeper
                       sub-headings belong to the section.
      2. Table row     `| Label: | value ... |`. Section text = the row's
                       remaining cells (everything after the first cell, one
                       line). This is how the Academy default `cr` template and
                       the Main Event seed render.
      3. Label line    `**LABEL**` alone on a line, or `**Label:** text` /
                       `Label: text` (inline text is allowed only when the label
                       itself ends in a colon). Section text = the inline text
                       plus following lines up to the next boundary: any ATX
                       heading, any standalone-bold line (`**Other**`), or the
                       start of any other required section, or end of document.
    `required` defaults to true. A required section that is absent is a
    violation; one that is present but whitespace-only is a violation too.
    An optional (`required: false`) section is only checked when present.

    Nested sub-rules apply to THAT section's text only, and only when the
    profile string is explicitly a regex: a `format` or `accuracyGuardrail[]`
    string beginning with `regex:` (or `re:`). `format` regex must be found
    (re.search, MULTILINE) in the section text; an `accuracyGuardrail` regex
    must NOT be found. Prose strings (every one in today's seed/defaults, e.g.
    "1-3 sentences", "Never claim ...") are descriptions for the drafter, not
    machine rules, and are ignored. See the friction notes in the ticket report.

BANNED TOKENS (bannedTokenPatterns)
    Flat string == {pattern: s, reason: ""}. Each pattern runs (re.search style
    finditer, MULTILINE) over the FULL body. Violation carries the pattern, the
    1-based line of the match start and the match truncated to 40 chars (never
    the whole line). At most 10 matches per pattern are listed. `standaloneOnly`
    counts a match only when it is the entire content of its line (or of its
    table cell) once list markers, emphasis, quote marks and table pipes are
    ignored. `scopeNote` is prose and is not enforced.

LINKS (linkPolicy)
    A link is any of: Markdown inline link or image `[t](url)` / `![t](url)`,
    reference definition `[ref]: url`, autolink `<https://...>`, HTML
    `<a href="...">`, a bare http(s)/ftp/mailto URL, and the GFM extended
    autolinks GitHub renders without a scheme: `www.host/path` (recorded and
    judged as `http://www.host/path`, boundary rules as GFM: line start or after
    whitespace or one of * _ ~ ( < > quotes [, trailing punctuation and an
    unbalanced `)` trimmed) and a bare `user@host.tld` email (recorded and judged
    as `mailto:user@host.tld`; the host needs a dot). Relative and `#anchor`
    targets count too (fail closed). Any HTML attribute that takes a URL (href, src,
    srcset, action, formaction, poster, data, cite, ...) on ANY tag is a link,
    quoted or unquoted; each srcset candidate is one. Markdown link text may nest
    brackets, span lines, contain `\\]` and be any length (a linear bracket-stack
    pass). A link is counted once: the brackets and target of `[t](url)` (and the
    text too when it is just a displayed URL) or the span of `<url>` are blanked
    before the scheme-less scans; other link text stays scanned.

    DECODE FIRST. HTML character references (`&amp;`, `&#38;`, `&#x26;`, `&#64;`, ...)
    are decoded once over the WHOLE body before extraction and the residual scan, and
    every extracted target is decoded once more; a target that still holds a
    reference after that (double encoding) is refused. Only `&name;` / `&#n;` forms
    with the semicolon are decoded (so a real `?a=1&section=2` is untouched). Decoding
    can only make more text look like a link, never hide one; the price is that an
    escaped code sample (`&lt;a href=..&gt;`) is flagged. Line numbers in link
    violations refer to the decoded body. Link TEXT is never exempt: it goes through
    every scan, and only text byte-for-byte equal to its own target is deduplicated.

    STRICT SYNTAX (`link-syntax-forbidden`, same "restricts links" rule as below).
    Under a restrictive policy only plain Markdown links (`[t](url)`, reference
    links) and bare URLs may carry a link. Refused outright: raw HTML link-bearing
    tags (a, img, area, iframe, object, embed, link, meta, form, svg, video, audio,
    source, base, ... and ANY tag carrying a URL attribute) and CommonMark angle
    autolinks (`<scheme:...>`, `<x@y>`). HTML comments and ordinary `<` text are fine.
    An UNTERMINATED forbidden tag counts as prose (`latency <a few ms`) only when the
    whole body has no other tag-like `<`, no block-opening tag name and no `>` after
    it (see `_relaxation_ok`); otherwise it is refused. One leading U+FEFF is dropped.

    RESIDUAL SCAN (the class guard, `link-unrecognized`). The extractor only
    IDENTIFIES links (which is testingLog, counting, maxCount); it is not the
    policy's boundary, because any syntax it misses would escape the policy. So when
    the profile RESTRICTS links, the body left after every recognised link is
    blanked is scanned for ANY link-like token, whatever the syntax: `//` + a
    host-ish char (protocol-relative), a `scheme:` from a broad list (https, ftp,
    mailto, tel, sms, javascript, data, file, vbscript, ssh, git, ws, ...) or any
    `scheme://`, `www.`, a bare `x@y.tld`, an HTML URL attribute name followed by
    `=` (href/src/srcset/action/formaction/poster/data/... , any case, optional
    whitespace), CSS `url(`/`url=`/`@import`, and the Markdown constructs `](`,
    `]:` and `][` (a `[text][label]` use of a recognised definition is exempt, as is
    a `[^n]:` footnote). Each hit is a violation naming its line (10 max). Over-
    matching costs a false alarm on odd prose; under-matching is the fail-open
    direction, so it errs toward the former.
    "Restricts links": the simple shape ({allowed, maxLinks}) always; the seed shape
    unless defaultAllowLinks is true AND everythingElseBanned is empty/absent (an
    empty `{}` policy reads as the banned seed shape). A profile with NO linkPolicy
    key restricts nothing, so it gets no residual check.
    Link targets over 2048 chars are kept as an unpermittable stub, never skipped.

    URL matching is STRUCTURAL, never a string prefix (`_url_permitted`):
      * scheme equal, case-insensitive; a host-only entry means http or https.
      * hostname equal after lower-casing. A plain host does NOT permit its
        subdomains; an entry starting `.` or `*.` (e.g. `*.example.com`) permits
        subdomains ONLY, not the apex. Any link with userinfo (`user@host`), a
        backslash, whitespace or no host is refused outright.
      * effective port equal (explicit, else the scheme default 80/443/21).
      * path: the entry path must equal the link path or continue it at a `/`
        (`/space` permits `/space/x`, not `/spaceevil`); paths are case-sensitive;
        a `..` segment (also %2e-encoded) is refused when the entry has a path.
      * mailto: EVERY recipient (path, and to/cc/bcc headers) must match:
        `mailto:ops@x.com` is that exact address (case-insensitive);
        `mailto:x.com` / `mailto:@x.com` is any address at exactly that domain.
        Recipients are percent-decoded ONCE, split on ',' ';' and whitespace, and
        each must be a plain unquoted addr-spec (`[A-Za-z0-9._+-]+@host.tld`): a
        quoted local part, a second '@', a leftover '%' or anything else refuses
        the whole link (`_mail_addresses` -> None), as does a query holding
        `;to=` / `;cc=` / `;bcc=` (some clients read ';' as a header separator).
      * relative / `#anchor` targets and non-http(s)/ftp/mailto schemes are never
        permitted by `allowed`. An entry that does not parse matches nothing.
    Standard-link identity (`_same_url`) uses the same scheme/host/port rules and
    additionally compares path (one trailing `/` tolerated), query and fragment.

    Simple shape {allowed, maxLinks}: a link is permitted iff it matches an
    `allowed` entry as above; an empty `allowed` permits nothing. Permitted links
    beyond maxLinks are a violation.
    Seed shape {defaultAllowLinks, standardLinks[], supersedesException,
    everythingElseBanned}, evaluated in this order:
      a. each standardLinks entry whose sourcePlaceholder resolves (via `facts`) to
         a non-blank string claims the links equal to it (count <= maxCount when
         present; absent with required:true is `link-required-missing`);
         an entry that does NOT resolve claims nothing: if it is required it is a
         `link-required-unresolved` violation naming its placeholder (there is no
         pool: an unidentifiable required link is never satisfied by "some" link);
         if it is optional it is inert and permits no link;
      b. supersedesException (only if allowed: true): up to maxLinksPerPage
         (default 1) leftover http(s) links (no userinfo) that sit on a line
         mentioning supersede/cancel/replace, outside a References/Appendix
         section, and not a github host. `mustResolveUnderFolder`, `appliesTo`,
         `needsLeadDecision` are publish-time / prose and are not enforced here;
      c. anything left is "everything else" and is a violation unless
         defaultAllowLinks is true AND everythingElseBanned is empty/absent.
         (Absent keys mean banned: fail closed.)

TITLE (titlePattern)
    Always matched against the `title` argument, never the body, as a FULL match.
    If the pattern contains `<Placeholder>` tokens (and no `(?`), it is a
    template: literal text is matched verbatim (whitespace runs flexible),
    `<MMM DD YYYY>`-style tokens made of MMM/DD/YYYY match a date such as
    `Sep 28 2026` or `Sep 28, 2026`, and any other `<Name>` matches one or more
    non-blank characters. Otherwise the pattern is a regular expression.

LIMITS
    Python's `re` has no timeout, so profile regexes are BOUNDED BY EXECUTION:
    every banned-token, section format/guardrail and title regex runs in one
    stdlib-only child interpreter (`sys.executable -I <this file> --regex-child`,
    no fork, no multiprocessing start method, identical under macOS spawn) with a
    hard wall-clock limit of REGEX_TIMEOUT_SECONDS (5s) for the whole draft, counted
    from the child's `ready` line (interpreter start-up on a loaded machine has its own
    CHILD_STARTUP_GRACE_SECONDS, 30s, after which it is `pattern-scan-failed`). On
    timeout the child is killed and the result is a fail-closed `pattern-timeout`
    violation naming the pattern that was running; a child that cannot start or
    crashes is `pattern-scan-failed`. A slow machine can therefore block a publish
    (retry); it can never pass one. Other bounds: body <= MAX_BODY_CHARS (over ->
    one `body-too-large` violation, no regex is run on it); title <=
    MAX_TITLE_CHARS; pattern <= MAX_PATTERN_CHARS; every profile regex is compiled
    once. A static screen still runs first and rejects the obvious nested
    unbounded quantifiers such as `(a+)+` (`unsafe-pattern`) cheaply. It is a
    heuristic and known NOT to catch overlapping alternation or bounded nests --
    `(a|a)*b`, `(a|aa)+$`, `(.*a){25}`, `(a{1,99}){1,99}b` -- which is why the
    execution bound exists; do not treat the screen as a safety boundary. The
    validator's own link/section scans are linear-time (per-line supersede flags,
    an '@' walk instead of a regex for emails, a bracket-stack pass for links).
"""
from __future__ import annotations

import html
import json
import os
import re
import selectors
import subprocess
import sys
import threading
import time
from bisect import bisect_right
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, unquote, urlsplit

__all__ = [
    "validate_draft",
    "assert_draft_valid",
    "Violation",
    "DraftValidationError",
    "MAX_BODY_CHARS",
    "MAX_TITLE_CHARS",
    "MAX_PATTERN_CHARS",
    "MAX_MATCHES_PER_PATTERN",
    "SNIPPET_CHARS",
    "REGEX_TIMEOUT_SECONDS",
    "CHILD_STARTUP_GRACE_SECONDS",
]

MAX_BODY_CHARS = 200_000
MAX_TITLE_CHARS = 1_000
MAX_PATTERN_CHARS = 2_000
MAX_MATCHES_PER_PATTERN = 10
SNIPPET_CHARS = 40
REGEX_TIMEOUT_SECONDS = 5.0
CHILD_STARTUP_GRACE_SECONDS = 30.0


@dataclass(frozen=True)
class Violation:
    rule: str
    detail: str
    line: Optional[int] = None

    def to_dict(self) -> dict:
        return {"rule": self.rule, "detail": self.detail, "line": self.line}


class DraftValidationError(ValueError):
    """Raised by assert_draft_valid. `.violations` carries the full list."""

    def __init__(self, violations: List[Violation]):
        self.violations = list(violations)
        counts: Dict[str, int] = {}
        for v in self.violations:
            counts[v.rule] = counts.get(v.rule, 0) + 1
        summary = ", ".join("%s x%d" % (r, n) for r, n in counts.items())
        first = self.violations[0] if self.violations else None
        msg = "draft failed validation (%d violation(s): %s)" % (
            len(self.violations), summary)
        if first is not None:
            msg += "; first: %s: %s" % (first.rule, _clip(first.detail, 160))
        super().__init__(msg)


def _clip(s: str, n: int) -> str:
    s = str(s).replace("\r", " ").replace("\n", " ")
    return s if len(s) <= n else s[: n - 3] + "..."


def _snippet(s: str) -> str:
    return _clip(s, SNIPPET_CHARS)


# --------------------------------------------------------------- regex safety

_ESC = re.compile(r"\\.", re.S)
_CLASS = re.compile(r"\[\^?\]?[^\]]*\]")
_UNBOUNDED_AFTER = re.compile(r"(?:[+*]|\{\d+,\})")


def _unsafe_pattern(pattern: str) -> Optional[str]:
    """Heuristic screen for nested unbounded quantifiers, e.g. (a+)+ ."""
    s = _CLASS.sub("", _ESC.sub("", pattern))
    stack: List[bool] = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "(":
            stack.append(False)
        elif c == ")":
            inner = stack.pop() if stack else False
            m = _UNBOUNDED_AFTER.match(s, i + 1)
            if m and inner:
                return "nested unbounded quantifier"
            if stack and (inner or m):
                stack[-1] = True
        elif c in "+*":
            if stack and s[i - 1] != ")":
                stack[-1] = True
        elif c == "{":
            m = re.compile(r"\{\d+,\}").match(s, i)
            if m and stack:
                stack[-1] = True
        i += 1
    return None


def _compile(pattern: Any, where: str, flags: int = re.MULTILINE):
    """-> (compiled or None, Violation or None). Compiles once; fails closed."""
    if not isinstance(pattern, str) or not pattern:
        return None, Violation("invalid-pattern", "%s: pattern must be a non-empty string" % where)
    if len(pattern) > MAX_PATTERN_CHARS:
        return None, Violation(
            "invalid-pattern", "%s: pattern longer than %d chars" % (where, MAX_PATTERN_CHARS))
    why = _unsafe_pattern(pattern)
    if why:
        return None, Violation(
            "unsafe-pattern", "%s: /%s/ rejected (%s)" % (where, _clip(pattern, 80), why))
    try:
        return re.compile(pattern, flags), None
    except (re.error, RecursionError, OverflowError, ValueError) as exc:
        return None, Violation(
            "invalid-pattern",
            "%s: /%s/ does not compile (%s)" % (where, _clip(pattern, 80), _clip(str(exc), 80)))


# ------------------------------------------------- bounded regex execution
#
# Python's `re` has no timeout and the static screen above is a heuristic, so
# every profile regex is EXECUTED in a stdlib-only child interpreter (this same
# file, run as a script) under one hard wall-clock limit. Checks do not run a
# profile regex themselves: they emit a `_Job` and a `then` callback that turns
# the child's answer into Violations. No fork and no multiprocessing start method
# is involved (subprocess + a JSON pipe behaves the same under macOS spawn).

_CHILD_FLAG = "--regex-child"


class _Job:
    __slots__ = ("op", "pattern", "flags", "text", "standalone", "then")

    def __init__(self, op: str, pattern: str, flags: int, text: str,
                 then: Callable[[Any], List["Violation"]], standalone: bool = False):
        self.op, self.pattern, self.flags, self.text = op, pattern, int(flags), text
        self.standalone, self.then = standalone, then


def _run_regex_child(jobs: List[_Job]):
    """-> (results {job index: result}, failure (job index, 'timeout'|'failed') or None)."""
    texts: List[str] = []
    tindex: Dict[int, int] = {}
    spec = []
    for j in jobs:
        k = id(j.text)
        if k not in tindex:
            tindex[k] = len(texts)
            texts.append(j.text)
        spec.append({"op": j.op, "pattern": j.pattern, "flags": j.flags,
                     "t": tindex[k], "standalone": j.standalone})
    payload = json.dumps({"texts": texts, "jobs": spec}).encode("ascii")
    here = os.path.abspath(__file__)
    if not sys.executable or not here.endswith(".py"):
        return {}, (0, "failed")
    try:
        proc = subprocess.Popen([sys.executable, "-I", here, _CHILD_FLAG],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
    except OSError:
        return {}, (0, "failed")

    def feed() -> None:
        try:
            proc.stdin.write(payload)
            proc.stdin.close()
        except (OSError, ValueError):
            pass  # child gone (killed or crashed): the reader side reports it

    threading.Thread(target=feed, daemon=True).start()
    # Two clocks. The child prints `ready` as soon as the interpreter is up, so a
    # loaded machine's slow exec/import is charged to CHILD_STARTUP_GRACE_SECONDS, and
    # REGEX_TIMEOUT_SECONDS bounds only the regex work itself (from `ready`).
    fd = proc.stdout.fileno()
    sel = selectors.DefaultSelector()
    sel.register(fd, selectors.EVENT_READ)
    deadline = time.monotonic() + CHILD_STARTUP_GRACE_SECONDS
    ready = timed_out = garbled = False
    buf = b""
    results: Dict[int, Any] = {}
    while len(results) < len(jobs):
        left = deadline - time.monotonic()
        if left <= 0 or not sel.select(left):
            timed_out = True
            break
        chunk = os.read(fd, 65536)
        if not chunk:
            break  # EOF: the child exited early
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            line = line.strip()
            if not line:
                continue
            if line == b"ready" and not ready:
                ready = True
                deadline = time.monotonic() + REGEX_TIMEOUT_SECONDS
                continue
            try:
                idx, res = json.loads(line.decode("ascii"))
                if not isinstance(idx, int) or not 0 <= idx < len(jobs) or res == "error":
                    raise ValueError("bad result")
                results[idx] = res
            except (ValueError, TypeError):
                garbled = True
    sel.close()
    if timed_out or garbled or len(results) < len(jobs):
        proc.kill()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    proc.stdout.close()
    if len(results) == len(jobs) and not garbled and not timed_out:
        return results, None
    culprit = next((i for i in range(len(jobs)) if i not in results), 0)
    return results, (culprit, "timeout" if (timed_out and ready) else "failed")


def _resolve_jobs(items: List[Any]) -> List[Violation]:
    """Run every `_Job` in `items` in ONE bounded child, splice the violations in
    place. A timeout or crash becomes a fail-closed `pattern-timeout` /
    `pattern-scan-failed` violation naming the pattern that was running."""
    jobs = [it for it in items if isinstance(it, _Job)]
    if not jobs:
        return list(items)
    results, failure = _run_regex_child(jobs)
    out: List[Violation] = []
    ji = 0
    for it in items:
        if not isinstance(it, _Job):
            out.append(it)
            continue
        if ji in results:
            out.extend(it.then(results[ji]))
        elif failure is not None and failure[0] == ji:
            if failure[1] == "timeout":
                out.append(Violation(
                    "pattern-timeout",
                    "/%s/ did not finish within %gs (catastrophic backtracking?); draft not validated"
                    % (_clip(it.pattern, 80), REGEX_TIMEOUT_SECONDS)))
            else:
                out.append(Violation(
                    "pattern-scan-failed",
                    "/%s/ could not be evaluated (regex child failed); draft not validated"
                    % _clip(it.pattern, 80)))
        ji += 1
    return out


def _regex_child_main() -> int:
    sys.stdout.write("ready\n")
    sys.stdout.flush()
    data = json.loads(sys.stdin.read())
    texts = data["texts"]
    for idx, j in enumerate(data["jobs"]):
        try:
            rx = re.compile(j["pattern"], j["flags"])
            text = texts[j["t"]]
            if j["op"] == "finditer":
                res: Any = []
                for m in rx.finditer(text):
                    if j["standalone"] and not _is_standalone(text, m.start(), m.end()):
                        continue
                    res.append([m.start(), m.end()])
                    if len(res) > MAX_MATCHES_PER_PATTERN:
                        break
            elif j["op"] == "search":
                m = rx.search(text)
                res = [m.start(), m.end()] if m else None
            else:
                res = rx.fullmatch(text) is not None
        except (re.error, RecursionError, OverflowError, ValueError):
            res = "error"
        sys.stdout.write(json.dumps([idx, res]) + "\n")
        sys.stdout.flush()
    return 0


# --------------------------------------------------------------- line helpers

def _line_starts(body: str) -> List[int]:
    starts = [0]
    p = body.find("\n")
    while p != -1:
        starts.append(p + 1)
        p = body.find("\n", p + 1)
    return starts


def _line_of(starts: List[int], offset: int) -> int:
    return bisect_right(starts, offset)  # 1-based


_FENCE = re.compile(r"^\s{0,3}(```|~~~)")
_HEADING = re.compile(r"^ {0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$")
_BOLD_LINE = re.compile(r"^\s*(?:\*\*|__)[^*_\n]+(?:\*\*|__)\s*:?\s*$")
_TABLE_ROW = re.compile(r"^\s*\|((?:\\.|[^|\\])*)\|(.*)$")


def _fence_mask(lines: List[str]) -> List[bool]:
    mask, fence = [], None
    for ln in lines:
        m = _FENCE.match(ln)
        if fence is None:
            if m:
                fence = m.group(1)
                mask.append(True)
                continue
            mask.append(False)
        else:
            mask.append(True)
            if m and m.group(1) == fence:
                fence = None
    return mask


# ------------------------------------------------------------------- sections

_EM = r"[*_`]*"
_PREFIX = r"\s*(?:>\s*)*(?:(?:[-*+]|\d+[.)])\s+)?"


class _Section:
    def __init__(self, spec: dict, label: str):
        self.spec = spec
        self.id = str(spec.get("id") or label)
        self.label = label
        self.required = spec.get("required", True) is not False
        core_label = label.strip()
        has_colon = core_label.endswith(":")
        words = core_label.rstrip(":").strip().split()
        core = r"\s+".join(re.escape(w) for w in words)
        self.cell = re.compile(
            r"^\s*" + _EM + core + _EM + r"\s*:?\s*" + _EM + r"\s*$", re.I)
        self.line_exact = re.compile(
            "^" + _PREFIX + _EM + core + _EM + r"\s*:?\s*" + _EM + r"\s*$", re.I)
        self.line_inline = (
            re.compile("^" + _PREFIX + _EM + core + _EM + ":" + _EM + r"(?:\s+(.*))?$", re.I)
            if has_colon else None)


def _parse_sections(profile: dict) -> Tuple[List[_Section], List[Violation]]:
    raw = profile.get("requiredSections")
    out: List[_Section] = []
    bad: List[Violation] = []
    if raw is None:
        return out, bad
    if not isinstance(raw, list):
        return out, [Violation("profile-malformed", "requiredSections must be a list")]
    for i, item in enumerate(raw):
        if isinstance(item, str) and item.strip():
            out.append(_Section({"id": item, "label": item, "required": True}, item))
        elif isinstance(item, dict) and isinstance(item.get("label"), str) and item["label"].strip():
            out.append(_Section(item, item["label"]))
        else:
            bad.append(Violation(
                "profile-malformed", "requiredSections[%d] needs a non-empty label" % i))
    return out, bad


def _locate(sec: _Section, lines: List[str], fenced: List[bool]):
    """First occurrence -> (idx, kind, level, rest) or None."""
    for i, ln in enumerate(lines):
        if fenced[i] or not ln.strip():
            continue
        hit = _classify(sec, ln)
        if hit is not None:
            return (i,) + hit
    return None


def _classify(sec: _Section, ln: str):
    """-> (kind, level, rest) when `ln` starts `sec`, else None."""
    m = _HEADING.match(ln)
    if m:
        return ("heading", len(m.group(1)), "") if sec.cell.match(m.group(2)) else None
    t = _TABLE_ROW.match(ln)
    if t:
        if sec.cell.match(t.group(1)):
            rest = t.group(2).rstrip()
            if rest.endswith("|"):
                rest = rest[:-1]
            return ("table", 0, rest.strip())
        return None
    if sec.line_exact.match(ln):
        return ("label", 0, "")
    if sec.line_inline is not None:
        m2 = sec.line_inline.match(ln)
        if m2:
            return ("label", 0, (m2.group(1) or "").strip())
    return None


def _check_sections(body: str, lines: List[str], profile: dict) -> List[Violation]:
    secs, out = _parse_sections(profile)
    if not secs:
        return out
    fenced = _fence_mask(lines)
    # every line that starts ANY required section (boundaries for label-form)
    starts_any = set()
    for i, ln in enumerate(lines):
        if fenced[i] or not ln.strip():
            continue
        for s in secs:
            if _classify(s, ln) is not None:
                starts_any.add(i)
                break

    for sec in secs:
        loc = _locate(sec, lines, fenced)
        if loc is None:
            if sec.required:
                out.append(Violation(
                    "required-section-missing",
                    "required section '%s' (label '%s') not found" % (sec.id, sec.label)))
            continue
        i, kind, level, rest = loc
        if kind == "heading":
            end = len(lines)
            for j in range(i + 1, len(lines)):
                if fenced[j]:
                    continue
                hm = _HEADING.match(lines[j])
                if hm and len(hm.group(1)) <= level:
                    end = j
                    break
            text = "\n".join(lines[i + 1:end])
            first_line = i + 2
        elif kind == "table":
            text = rest
            first_line = i + 1
        else:
            end = len(lines)
            for j in range(i + 1, len(lines)):
                if fenced[j]:
                    continue
                if (_HEADING.match(lines[j]) or _BOLD_LINE.match(lines[j])
                        or j in starts_any):
                    end = j
                    break
            text = "\n".join([rest] + lines[i + 1:end])
            first_line = i + 1
        if sec.required and not text.strip():
            out.append(Violation(
                "required-section-empty", "required section '%s' has no content" % sec.id,
                i + 1))
        out.extend(_check_section_rules(sec, text, first_line))
    return out


_RX_PREFIX = re.compile(r"^(?:regex|re):", re.I)


def _check_section_rules(sec: _Section, text: str, first_line: int) -> List[Any]:
    out: List[Any] = []
    fmt = sec.spec.get("format")
    if isinstance(fmt, str) and _RX_PREFIX.match(fmt):
        pat = _RX_PREFIX.sub("", fmt, count=1)
        rx, bad = _compile(pat, "section '%s' format" % sec.id)
        if bad:
            out.append(bad)
        else:
            out.append(_Job("search", pat, re.MULTILINE, text, _format_then(sec.id, pat, first_line)))
    guards = sec.spec.get("accuracyGuardrail")
    if isinstance(guards, list):
        for g in guards:
            if not (isinstance(g, str) and _RX_PREFIX.match(g)):
                continue  # prose guardrail: advice for the drafter, not a machine rule
            pat = _RX_PREFIX.sub("", g, count=1)
            rx, bad = _compile(pat, "section '%s' accuracyGuardrail" % sec.id)
            if bad:
                out.append(bad)
                continue
            out.append(_Job("search", pat, re.MULTILINE, text,
                            _guardrail_then(sec.id, pat, text, first_line)))
    return out


def _format_then(sid: str, pat: str, first_line: int):
    def then(r):
        if r:
            return []
        return [Violation(
            "section-format",
            "section '%s': text does not match format /%s/" % (sid, _clip(pat, 80)),
            first_line)]
    return then


def _guardrail_then(sid: str, pat: str, text: str, first_line: int):
    def then(r):
        if not r:
            return []
        return [Violation(
            "section-guardrail",
            "section '%s': forbidden /%s/ matched '%s'"
            % (sid, _clip(pat, 80), _snippet(text[r[0]:r[1]])),
            first_line + text.count("\n", 0, r[0]))]
    return then


# --------------------------------------------------------------- banned tokens

_FILL = re.compile(r"^(?:[\s|*_>#`\"'()\[\]+\-.,;:!?]|\d+[.)](?=\s))*$")


def _is_standalone(body: str, ms: int, me: int) -> bool:
    ls = body.rfind("\n", 0, ms) + 1
    le = body.find("\n", me)
    if le == -1:
        le = len(body)
    before, after = body[ls:ms], body[me:le]
    if "\n" in body[ms:me]:
        return False
    if "|" in before:
        before = before[before.rfind("|"):]
    if "|" in after:
        after = after[:after.find("|") + 1]
    return bool(_FILL.match(before)) and bool(_FILL.match(after))


def _check_banned(body: str, starts: List[int], profile: dict) -> List[Any]:
    raw = profile.get("bannedTokenPatterns")
    if raw is None:
        return []
    if not isinstance(raw, list):
        return [Violation("profile-malformed", "bannedTokenPatterns must be a list")]
    out: List[Any] = []
    # A reader sees the DECODED text (`T&#79;DO` reads TODO), so each pattern runs over
    # the raw body AND the entity-decoded body (same decode `_check_links` uses). Every
    # decoded match is mapped back to its RAW offset (`_unescape_map`, linear), so its
    # line is the raw line even when `&#10;` decodes to a newline, and an occurrence both
    # passes see is reported once (keyed on the raw offset) while different occurrences
    # are all kept. Banned-token violations are returned in line order (validate_draft).
    # requiredSections / titlePattern are deliberately NOT
    # decoded: a structural heading or a plain-text title that only exists after decoding
    # is a false FAIL (fail closed), not an evasion.
    dec, to_raw = _unescape_map(body)
    for i, item in enumerate(raw):
        if isinstance(item, str):
            pat, reason, standalone = item, "", False
        elif isinstance(item, dict):
            pat = item.get("pattern")
            reason = item.get("reason") if isinstance(item.get("reason"), str) else ""
            standalone = item.get("standaloneOnly") is True
        else:
            out.append(Violation("profile-malformed", "bannedTokenPatterns[%d] must be a string or object" % i))
            continue
        rx, bad = _compile(pat, "bannedTokenPatterns[%d]" % i)
        if bad:
            out.append(bad)
            continue
        seen: set = set()      # raw offsets the raw pass reported for THIS pattern
        out.append(_Job("finditer", pat, re.MULTILINE, body,
                        _banned_then(pat, reason, body, starts, seen), standalone))
        if to_raw is not None:
            out.append(_Job("finditer", pat, re.MULTILINE, dec,
                            _banned_then(pat, reason, dec, starts, seen, to_raw), standalone))
    return out


def _banned_then(pat: str, reason: str, body: str, starts: List[int], seen: Optional[set] = None,
                 to_raw: Optional[Callable[[int], int]] = None):
    """`then` for one banned pattern over `body`. With `to_raw` (the decoded pass) match
    offsets are mapped back to raw-body offsets: the line is the RAW line, and a match
    whose raw offset the raw pass already reported is skipped (same occurrence)."""
    seen = set() if seen is None else seen

    def then(spans):
        res: List[Violation] = []
        for k, (s, e) in enumerate(spans):
            if k >= MAX_MATCHES_PER_PATTERN:
                res.append(Violation(
                    "banned-token", "/%s/: further matches omitted" % _clip(pat, 80)))
                break
            raw_off = s if to_raw is None else to_raw(s)
            if to_raw is not None and raw_off in seen:
                continue
            if to_raw is None:
                seen.add(raw_off)
            detail = "/%s/ matched '%s'" % (_clip(pat, 80), _snippet(body[s:e]))
            if reason:
                detail += " - " + _clip(reason, 100)
            res.append(Violation("banned-token", detail, _line_of(starts, raw_off)))
        return res
    return then


# ---------------------------------------------------------------------- links

class _Link:
    __slots__ = ("url", "line", "start")

    def __init__(self, url: str, line: int, start: int):
        self.url, self.line, self.start = url, line, start


# Markdown inline links are found by a linear bracket-stack pass (`_md_inline`), not
# a regex: link text may nest brackets, span lines and contain `\\]`, at any length.
_BR_TOK = re.compile(r"\\.|[\[\]]|\n[ \t]*\n", re.S)
_WS = re.compile(r"\s*")
_DEST_END = re.compile(r"[)\s>]")
_MAX_DEST = 2048   # a longer target is recorded as an unpermittable stub, never skipped
_REF_DEF = re.compile(r"^[ \t]{0,3}\[([^\]\n]+)\]:[ \t]*<?(\S+?)>?(?=\s|$)", re.M)
_FOOTNOTE_DEF = re.compile(r"^[ \t]{0,3}\[\^[^\]\n]*\]:", re.M)
_REF_USE = re.compile(r"\]\[([^\]\n]*)\]")
_AUTOLINK = re.compile(r"<((?:https?|ftp)://[^>\s]+|mailto:[^>\s]+)>", re.I)
# Any HTML attribute that takes a URL, on any tag, quoted or unquoted, whitespace
# around '=' allowed, name case-insensitive (`data-href=` is not one: '-' precedes).
_URL_ATTRS = ("href", "src", "srcset", "action", "formaction", "poster", "data", "cite",
              "background", "ping", "longdesc", "manifest", "srcdoc", "lowsrc", "dynsrc", "usemap")
_HTML_ATTR = re.compile(
    r"(?<![A-Za-z0-9_-])(" + "|".join(_URL_ATTRS) + r")\s*=\s*"
    r"(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'<>`]+))", re.I)
_BARE = re.compile(r"(?:(?:https?|ftp)://|mailto:)[^\s<>\[\]()\"']+", re.I)
# GFM extended www autolink: `www.` + a domain, at the start of a line or after
# whitespace or one of * _ ~ ( (widened here with < > quotes [ : more is fail-closed).
_WWW = re.compile(
    "(?:^|(?<=[\\s*_~(<>\"'\\[]))www\\.[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)*[^\\s<]*", re.I | re.M)
_TRAIL = ".,;:!?*_"
_EMAIL_LOCAL = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+-")
_EMAIL_DOMAIN = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
_EMAIL_CAP = 256  # per-side scan cap: keeps the '@' walk linear on hostile bodies


def _trim_autolink(u: str) -> str:
    """GFM: strip trailing punctuation and an unbalanced ')' from an extended autolink."""
    while u:
        c = u[-1]
        if c in ".,;:!?*_~'\"":
            u = u[:-1]
        elif c == ")" and u.count(")") > u.count("("):
            u = u[:-1]
        else:
            break
    return u


def _email_spans(text: str) -> List[Tuple[int, int]]:
    """GFM extended email autolinks (`user@host.tld`), found by walking outward
    from each '@' (a regex here is quadratic on a long run of local-part chars)."""
    out: List[Tuple[int, int]] = []
    i = text.find("@")
    while i != -1:
        a = i
        while a > 0 and i - a < _EMAIL_CAP and text[a - 1] in _EMAIL_LOCAL:
            a -= 1
        b = i + 1
        while b < len(text) and b - i < _EMAIL_CAP and text[b] in _EMAIL_DOMAIN:
            b += 1
        dom = text[i + 1:b].rstrip(".").rstrip("-_").rstrip(".")
        if a < i and dom and "." in dom and dom[0] not in ".-_":
            out.append((a, i + 1 + len(dom)))
        i = text.find("@", i + 1)
    return out


def _mask_spans(text: str, spans: List[Tuple[int, int]]) -> str:
    """Blank out spans (newlines kept, so line numbers survive) in ONE pass."""
    if not spans:
        return text
    parts, pos = [], 0
    for s, e in sorted(spans):
        if e <= pos:
            continue
        s = max(s, pos)
        parts.append(text[pos:s])
        parts.append(re.sub(r"[^\n]", " ", text[s:e]))
        pos = e
    parts.append(text[pos:])
    return "".join(parts)


def _md_inline(body: str):
    """-> [(url, span_start, text_start, text_end, span_end, raw_target)] for every `[t](url)` /
    `![t](url)`. ONE forward pass with a bracket stack (linear): nested brackets,
    newlines and `\\]` in the text and any text length are all fine; a blank line
    ends every open bracket. Nested links are all reported (fail closed). The target
    is parsed by hand (a regex here backtracks quadratically on `](` + spaces); the
    end of a target run is looked up through a one-entry cache, so overlapping
    attempts never rescan it. A target longer than _MAX_DEST is kept as a stub that
    no allow-list matches."""
    out = []
    stack: List[int] = []
    n = len(body)
    cache = (-1, -1)        # (run start, first terminator at/after it); n = none
    for m in _BR_TOK.finditer(body):
        t = m.group(0)
        if t == "[":
            stack.append(m.start())
        elif t == "]":
            if not stack:
                continue
            ts = stack.pop()
            if not body.startswith("(", m.end()):
                continue
            i = _WS.match(body, m.end() + 1).end()
            if body.startswith("<", i):
                i += 1
            if cache[0] <= i <= cache[1]:
                end = cache[1]
            else:
                mm = _DEST_END.search(body, i)
                end = mm.start() if mm else n
                cache = (i, end)
            if end == i:
                continue
            j = end + 1 if body.startswith(">", end) else end
            k = _WS.match(body, j).end()
            if k > j and k < n and body[k] in "\"'":
                q = body.find(body[k], k + 1)
                if q != -1:
                    k = _WS.match(body, q + 1).end()
            if not body.startswith(")", k):
                continue
            url = body[i:end] if end - i <= _MAX_DEST else body[i:i + 32] + "\x00<oversize>"
            ss = ts - 1 if ts > 0 and body[ts - 1] == "!" else ts
            out.append((url, ss, ts + 1, m.start(), k + 1,
                        body[i:end] if end - i <= _MAX_DEST else None))
        elif t[0] == "\n":
            stack.clear()
    return out


# HTML character references. A renderer decodes them in link targets and attribute
# values, so `&amp;bcc=` IS a mailto header separator and `&#64;` IS an '@'. The whole
# body is decoded once before extraction (`_check_links`) and every extracted target is
# decoded again; a target that STILL carries a reference (double encoding) is refused.
# Only `&name;` / `&#n;` / `&#xh;` forms with the semicolon are decoded (html.unescape
# alone would also turn `&section=` or `&copy=` in a real query string into text), plus
# a bare `&amp` not followed by a name character.
_ENTITY = re.compile(r"&(?:#[0-9]{1,10}|#[xX][0-9a-fA-F]{1,8}|[A-Za-z][A-Za-z0-9]{0,31});"
                     r"|&[aA][mM][pP](?![A-Za-z0-9=;])")
_ENTITY_LEFT = re.compile(r"&[#A-Za-z0-9]+;")


def _unescape(text: str) -> str:
    if "&" not in text:
        return text
    return _ENTITY.sub(lambda m: html.unescape(m.group(0)), text)


def _unescape_map(text: str):
    """-> (decoded, to_raw) where to_raw(decoded_offset) is the offset in `text` of the
    same character (an offset inside a decoded reference maps to the reference's start).
    Linear: one pass over the references, then a bisect per lookup. (text, None) when
    nothing decodes."""
    if "&" not in text:
        return text, None
    dec_pos: List[int] = []
    raw_pos: List[int] = []
    plain: List[bool] = []
    parts: List[str] = []
    pr = pd = 0
    for m in _ENTITY.finditer(text):
        if m.start() > pr:
            dec_pos.append(pd), raw_pos.append(pr), plain.append(True)
            parts.append(text[pr:m.start()])
            pd += m.start() - pr
        rep = html.unescape(m.group(0))
        dec_pos.append(pd), raw_pos.append(m.start()), plain.append(False)
        parts.append(rep)
        pd += len(rep)
        pr = m.end()
    if not parts:
        return text, None
    if pr < len(text):
        dec_pos.append(pd), raw_pos.append(pr), plain.append(True)
        parts.append(text[pr:])

    def to_raw(d: int) -> int:
        i = bisect_right(dec_pos, d) - 1
        return raw_pos[i] + (d - dec_pos[i]) if plain[i] else raw_pos[i]

    return "".join(parts), to_raw


def _decode_target(u: str) -> str:
    """-> the target as a renderer / mail client sees it, or an unpermittable stub
    when it still holds a character reference after decoding (double encoding)."""
    d = _unescape(u)
    if _ENTITY_LEFT.search(d):
        return "\x00<entity>" + d[:32]
    return d


def _norm_label(s: str) -> str:
    return " ".join(s.split()).lower()


def _extract(body: str, starts: List[int]):
    """-> (links, residual): every link the way GitHub would render it, and the body
    with every RECOGNISED link span blanked out (newlines kept) - the input of the
    fail-closed residual scan (`_residual_hits`). A `www.x` autolink is recorded as
    `http://www.x` and a bare `user@host.tld` as `mailto:user@host.tld`, so the policy
    checks see the URL a reader would actually follow."""
    found: List[_Link] = []
    work = body

    def scan(rx, group: int, filt=None, record=True):
        nonlocal work
        spans = []
        for m in rx.finditer(work):
            if filt and not filt(m):
                continue
            if record:
                url = m.group(group)
                if rx is _BARE:
                    url = url.rstrip(_TRAIL)
                elif rx is _WWW:
                    url = "http://" + _trim_autolink(url)
                found.append(_Link(url.strip(), _line_of(starts, m.start()), m.start()))
            spans.append((m.start(), m.end()))
        work = _mask_spans(work, spans)

    # [t](url): mask the brackets and the target. The TEXT is never masked on the
    # strength of what it looks like: it goes through every scan below (an autolink,
    # email or tag inside it is a real link to a renderer). The one exception is text
    # that is byte-for-byte its own target (`[https://x](https://x)`): that is the
    # same link, already recorded, so it is deduplicated by masking exactly it.
    spans = []
    for url, ss, ts, te, se, raw in _md_inline(body):
        found.append(_Link(url.strip(), _line_of(starts, ss), ss))
        spans.append((ss, ts))
        spans.append((te, se))
        if raw is not None and te - ts <= _MAX_DEST + 64 and body[ts:te].strip() == raw:
            spans.append((ts, te))
    work = _mask_spans(work, spans)

    scan(_FOOTNOTE_DEF, 0, record=False)          # `[^1]: note` is not a link
    labels = set()

    def is_def(m):
        if m.group(1).startswith("^"):
            return False
        labels.add(_norm_label(m.group(1)))
        return True

    scan(_REF_DEF, 2, is_def)
    # `[text][label]` whose label is a definition we already recognised (and judge)
    scan(_REF_USE, 0, lambda m: _norm_label(m.group(1)) in labels, record=False)
    scan(_AUTOLINK, 1)

    spans = []
    for m in _HTML_ATTR.finditer(work):
        val = next((g for g in m.groups()[1:] if g is not None), "")
        cands = [c.strip().split(None, 1)[0] if c.strip() else ""
                 for c in val.split(",")] if m.group(1).lower() == "srcset" else [val]
        for c in cands:
            found.append(_Link(c.strip(), _line_of(starts, m.start()), m.start()))
        spans.append((m.start(), m.end()))
    work = _mask_spans(work, spans)

    scan(_BARE, 0)
    scan(_WWW, 0)
    spans = _email_spans(work)
    for s, e in spans:
        found.append(_Link("mailto:" + work[s:e], _line_of(starts, s), s))
    work = _mask_spans(work, spans)
    found.sort(key=lambda l: l.start)
    for l in found:
        l.url = _decode_target(l.url)
    return [l for l in found if l.url], work


def _extract_links(body: str, starts: List[int]) -> List[_Link]:
    return _extract(body, starts)[0]


# ---- fail-closed residual scan: the class guard --------------------------------
# The extractor above IDENTIFIES links (which one is testingLog, counting, maxCount).
# It cannot be the whole policy: any syntax it misses would escape the linkPolicy
# altogether. So, when the profile restricts links, whatever is left of the body once
# every recognised link is blanked is scanned for ANY link-like token, independent of
# Markdown/HTML syntax. Over-matching costs a false alarm on odd prose; under-matching
# is a publish that carries an off-policy link.
_SCHEMES = ("https?|ftp|ftps|mailto|tel|sms|javascript|data|file|vbscript|ssh|git|ws|wss|"
            "irc|news|gopher|blob|cid|about|view-source")
_RESIDUAL_TOKENS = (
    ("protocol-relative //host",
     re.compile(r"//[A-Za-z0-9_\[.~%@-]")),
    ("scheme:",
     re.compile(r"(?<![A-Za-z0-9+.\-])(?:" + _SCHEMES + r"):(?=\S)", re.I)),
    ("scheme://",
     re.compile(r"(?<![A-Za-z0-9+.\-])[A-Za-z][A-Za-z0-9+.\-]*://")),
    ("www.", re.compile(r"(?<![A-Za-z0-9])www\.[A-Za-z0-9]", re.I)),
    ("email address", re.compile(r"[^\s@]@[^\s@]*\.[A-Za-z0-9]")),
    ("html url attribute", re.compile(
        r"(?<![A-Za-z0-9_-])(?:" + "|".join(_URL_ATTRS) + r"|xlink:href)\s*=", re.I)),
    ("css/meta url", re.compile(r"(?<![A-Za-z0-9_-])url\s*[(=]|@import\b", re.I)),
    ("markdown link ](", re.compile(r"\]\(")),
    ("markdown reference ]:", re.compile(r"\]:")),
    ("markdown reference ][", re.compile(r"\]\[")),
)


# ---- strict syntax: under a restrictive policy a permitted link may only be plain
# Markdown (`[t](url)`, reference links) or a bare URL. Raw HTML link carriers and
# CommonMark angle autolinks are refused outright (`link-syntax-forbidden`): they have
# too many renderer-side readings to police one variant at a time.
_FORBIDDEN_TAGS = ("a|img|area|iframe|object|embed|link|meta|form|svg|video|audio|source|base|"
                   "frame|frameset|input|button|track|script|style|use|image|picture|param|"
                   "applet|portal|math|blockquote|q|ins|del")
# The forbidden-tag rule and when an UNTERMINATED tag may be read as prose.
#
# `_TAG_FORBIDDEN` matches `<name` (or `</name`) of a forbidden tag with no terminator
# needed: the strict, container-agnostic reading. `_relaxation_ok(body)` lets the caller
# skip it (so `latency <a few ms` is clean) ONLY when all of the following hold for the
# whole decoded body:
#   (1) every `<` followed by [A-Za-z!?/] starts a RELAXABLE candidate, i.e. a forbidden
#       tag name that is not a CommonMark type-1 or type-6 block name. So there is no
#       other tag, closing tag, comment, PI, declaration or CDATA anywhere;
#   (2) (part of 1) a type-1/type-6 name, forbidden or not, is never a relaxable
#       candidate: `<pre <script <style <textarea` and the type-6 list open a block from
#       `<name` + whitespace/EOL alone;
#   (3) no `>` appears after the first candidate, so every candidate is unterminated.
# WHY THIS MAKES "AN HTML BLOCK EXISTS" IMPOSSIBLE, WHATEVER PRECEDES THE LINE (list
# marker, `>`, footnote label `[^1]:`, indent, BOM, anything). Every CommonMark HTML
# block start condition is anchored on the characters `<` + [A-Za-z!?/]: types 2-5 are
# `<!--`, `<?`, `<!X`, `<![CDATA[` (`<!` `<?`); types 1 and 6 are `<`/`</` + a fixed
# name; type 7 is a COMPLETE open/closing tag, which needs a `>`. (1)+(2) exclude every
# such `<` except unterminated relaxable candidates, and (3) leaves no `>` for a type-7
# tag to end on. The container prefix decides only WHERE a block could start, never
# WHETHER one exists, so no prefix list is needed (or kept). With no block, cmark treats
# an unterminated `<a name=x` as inline text (inline raw HTML also needs the `>`) and
# escapes it, and there is no later tag `>` to close it. If ANY of (1)-(3) fails the
# strict match is used. Over-refusal is fine: a release draft has no raw HTML.
# URL-bearing fragments never depend on this: `_TAG_URL_ATTR`, the link extractor and the
# residual scan catch `href=`, `//`, `scheme:` whatever the tag looks like.
_TYPE1_TYPE6_NAMES = frozenset((
    "pre", "script", "style", "textarea",
    "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption",
    "center", "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt",
    "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset",
    "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend",
    "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option",
    "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot", "th",
    "thead", "title", "tr", "track", "ul"))
_RELAXABLE_TAGS = "|".join(sorted(t for t in _FORBIDDEN_TAGS.split("|") if t not in _TYPE1_TYPE6_NAMES))
_TAG_FORBIDDEN = re.compile(r"</?(?:" + _FORBIDDEN_TAGS + r")(?![A-Za-z0-9:_-])", re.I)
_LT_TAGLIKE = re.compile(r"<[A-Za-z!?/]")
_RELAXABLE = re.compile(r"</?(?:" + _RELAXABLE_TAGS + r")(?![A-Za-z0-9:_-])", re.I)


def _relaxation_ok(body: str) -> bool:
    """True when conditions (1)-(3) above hold, i.e. unterminated forbidden tags may be
    treated as prose. Linear: one pass over the `<` positions, O(1) work each."""
    first = -1
    for m in _LT_TAGLIKE.finditer(body):
        if _RELAXABLE.match(body, m.start()) is None:
            return False
        if first < 0:
            first = m.start()
    return first < 0 or body.find(">", first) == -1


_TAG_URL_ATTR = re.compile(
    r"<[A-Za-z][^<>]*?(?<![A-Za-z0-9_-])(?:" + "|".join(_URL_ATTRS) + r"|xlink:href)\s*=", re.I)
_ANGLE_SCHEME = re.compile(r"<[A-Za-z][A-Za-z0-9+.\-]{1,31}:[^<>\s]*>")
_ANGLE_EMAIL = re.compile(r"<[^<>\s@]+@[^<>\s@]+>")
_SYNTAX_TOKENS = (("raw HTML link tag", _TAG_FORBIDDEN), ("raw HTML tag with a URL attribute", _TAG_URL_ATTR),
                  ("angle autolink <scheme:...>", _ANGLE_SCHEME), ("angle autolink <x@y>", _ANGLE_EMAIL))


def _syntax_hits(body: str, starts: List[int]) -> List[Violation]:
    hits = []
    relaxed = _relaxation_ok(body)
    for name, rx in _SYNTAX_TOKENS:
        if relaxed and rx is _TAG_FORBIDDEN:
            continue
        for m in rx.finditer(body):
            hits.append((m.start(), name))
            if len(hits) > 4 * MAX_MATCHES_PER_PATTERN:
                break
    hits.sort()
    out: List[Violation] = []
    seen = set()
    for off, name in hits:
        ln = _line_of(starts, off)
        if (ln, name) in seen:
            continue
        seen.add((ln, name))
        if len(out) >= MAX_MATCHES_PER_PATTERN:
            out.append(Violation("link-syntax-forbidden", "further forbidden link syntax omitted"))
            break
        out.append(Violation(
            "link-syntax-forbidden",
            "%s is not allowed under a restrictive linkPolicy; write a plain Markdown link "
            "or a bare URL instead: '%s'" % (name, _snippet(body[off:off + 40])), ln))
    return out


def _residual_hits(residual: str, body: str, starts: List[int]) -> List[Violation]:
    hits = []
    for name, rx in _RESIDUAL_TOKENS:
        for m in rx.finditer(residual):
            hits.append((m.start(), name))
            if len(hits) > 4 * MAX_MATCHES_PER_PATTERN:
                break
    hits.sort()
    out: List[Violation] = []
    for off, name in hits:
        if len(out) >= MAX_MATCHES_PER_PATTERN:
            out.append(Violation("link-unrecognized", "further unrecognised link-like text omitted"))
            break
        out.append(Violation(
            "link-unrecognized",
            "link-like text (%s) was not recognised as a link, so it cannot be checked "
            "against linkPolicy: '%s'" % (name, _snippet(body[off:off + 40])),
            _line_of(starts, off)))
    return out


# ---------------------------------------------------------------- URL matching

_DEFAULT_PORT = {"http": 80, "https": 443, "ftp": 21}
_BAD_URL_CHARS = re.compile(r"[\x00-\x20\x7f\\]")


def _split_url(raw: Any):
    """-> (scheme, host, port, path, query, fragment), or None when the URL is
    unusable. `port` is the EFFECTIVE port (explicit, else the scheme default).
    Only http/https/ftp/mailto parse; anything with userinfo (`user@host`), a
    backslash, whitespace or a control character, or a missing host is None.
    Callers treat None as 'not permitted' (fail closed)."""
    if not isinstance(raw, str):
        return None
    u = raw.strip()
    if not u or _BAD_URL_CHARS.search(u):
        return None
    try:
        sp = urlsplit(u)
        scheme = sp.scheme.lower()
        if scheme == "mailto":
            return ("mailto", "", None, sp.path, sp.query, sp.fragment)
        if scheme not in _DEFAULT_PORT or "@" in sp.netloc:
            return None
        host, port = sp.hostname, sp.port
    except ValueError:
        return None
    if not host:
        return None
    return (scheme, host.lower(), port if port is not None else _DEFAULT_PORT[scheme],
            sp.path, sp.query, sp.fragment)


_MAIL_STRICT = re.compile(r"[A-Za-z0-9._+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
_MAIL_SPLIT = re.compile(r"[,;\s]+")
_MAIL_HEADERS = ("to", "cc", "bcc")
_MAIL_SEMI_HEADER = re.compile(r";\s*(?:to|cc|bcc)\s*=", re.I)


def _mail_addresses(path: str, query: str) -> Optional[List[str]]:
    """-> the lower-cased recipients of a mailto target (path plus to/cc/bcc headers),
    or None when ANY recipient is not a plain unquoted addr-spec.
    Everything is percent-decoded ONCE first, then split on ',' ';' and whitespace
    (Outlook treats ';' as a separator; '%2C' / '%20' decode into separators), and
    every piece must match `local@domain.tld` with a local part of [A-Za-z0-9._+-]:
    a quoted local part, a second '@', a leftover '%' (double encoding) or anything
    else is refused - fail closed."""
    if _MAIL_SEMI_HEADER.search(unquote(query)):
        return None      # `;to=` / `;cc=` / `;bcc=`: a client may read ';' as a header separator
    raw = [unquote(path)]
    for pair in query.split("&"):       # never on ";": that is a recipient separator
        k, _, v = pair.partition("=")
        if unquote(k).strip().lower() in _MAIL_HEADERS:
            raw.append(unquote(v))
    addrs: List[str] = []
    for chunk in raw:
        for a in _MAIL_SPLIT.split(chunk):
            if not a:
                continue
            if not _MAIL_STRICT.fullmatch(a):
                return None
            addrs.append(a.lower())
    return addrs


class _Allow:
    """One parsed `linkPolicy.allowed` entry. See LINKS in the module docstring."""
    __slots__ = ("mail", "local", "domain", "scheme", "host", "sub", "port", "path")

    def __init__(self):
        self.mail = False
        self.local: Optional[str] = None
        self.domain = ""
        self.scheme: Optional[str] = None
        self.host = ""
        self.sub = False
        self.port: Optional[int] = None
        self.path = ""


def _parse_allowed(entry: Any) -> Optional[_Allow]:
    if not isinstance(entry, str) or not entry.strip():
        return None
    e = entry.strip()
    if _BAD_URL_CHARS.search(e):
        return None
    a = _Allow()
    if e.lower().startswith("mailto:"):
        addr = unquote(e[7:].split("?", 1)[0]).strip().lower()
        if not addr or not re.fullmatch(r"(?:[a-z0-9._+-]*@)?[a-z0-9-]+(?:\.[a-z0-9-]+)*", addr):
            return None
        a.mail = True
        if "@" in addr:
            local, a.domain = addr.rsplit("@", 1)
            a.local = local or None
        else:
            a.domain = addr
        return a if a.domain else None
    if "://" in e:
        scheme, rest = e.split("://", 1)
        a.scheme = scheme.lower()
        if a.scheme not in _DEFAULT_PORT:
            return None
    else:
        rest = e
    if rest.startswith("*.") or rest.startswith("."):
        a.sub = True
        rest = rest[2:] if rest.startswith("*.") else rest[1:]
    try:
        sp = urlsplit("//" + rest)
        if "@" in sp.netloc:
            return None
        host, a.port = sp.hostname, sp.port
    except ValueError:
        return None
    if not host:
        return None
    a.host = host.lower()
    a.path = sp.path.rstrip("/")
    return a


def _parse_allowed_list(allowed: List[Any]) -> List[_Allow]:
    return [a for a in (_parse_allowed(x) for x in allowed) if a is not None]


def _url_permitted(url: str, allowed: List[_Allow]) -> bool:
    """Structural allow-list match (never a string prefix):
      * scheme equal, case-insensitive (a host-only entry means http or https);
      * hostname equal after lower-casing (userinfo never reaches the host: any
        `user@host` link is rejected outright); an entry starting `.` or `*.`
        matches SUBDOMAINS ONLY, not the apex; a plain host does not match its
        subdomains;
      * effective port equal (explicit, else the scheme default);
      * path: the entry path must equal the link path or be followed by `/` in
        it, so `/space` permits `/space/x` but not `/spaceevil`; a link with a
        `..` segment is refused when the entry has a path; case-sensitive;
      * mailto: every recipient (path, and to/cc/bcc headers) must match an
        entry: `mailto:a@x.com` is that exact address, `mailto:x.com` (or
        `mailto:@x.com`) is any address at exactly that domain;
      * relative and `#anchor` targets are never permitted."""
    parts = _split_url(url)
    if parts is None:
        return False
    scheme, host, port, path, query, _frag = parts
    if scheme == "mailto":
        addrs = _mail_addresses(path, query)
        if not addrs:            # None (a recipient is not a strict addr-spec) or empty
            return False
        mails = [a for a in allowed if a.mail]
        for addr in addrs:
            if "@" not in addr:
                return False
            local, dom = addr.rsplit("@", 1)
            if not any(m.domain == dom and (m.local is None or m.local == local) for m in mails):
                return False
        return True
    segs = unquote(path).split("/")
    for a in allowed:
        if a.mail:
            continue
        if a.scheme is None:
            if scheme not in ("http", "https"):
                continue
        elif a.scheme != scheme:
            continue
        if a.sub:
            if not host.endswith("." + a.host):
                continue
        elif host != a.host:
            continue
        if port != (a.port if a.port is not None else _DEFAULT_PORT[scheme]):
            continue
        if a.path and (".." in segs or not (path == a.path or path.startswith(a.path + "/"))):
            continue
        return True
    return False


def _canon_url(u: Any):
    p = _split_url(u)
    if p is None:
        return None
    scheme, host, port, path, query, frag = p
    if scheme == "mailto":
        addrs = _mail_addresses(path, query)
        return None if addrs is None else ("mailto", tuple(addrs))
    return (scheme, host, port, path.rstrip("/"), query, frag)


def _same_url(a: str, b: str) -> bool:
    """Standard-link identity: same scheme, host (case-insensitive), effective
    port, path (one trailing '/' tolerated), query and fragment. A URL that does
    not parse (or carries userinfo) is equal only to a byte-identical string."""
    ca, cb = _canon_url(a), _canon_url(b)
    if ca is not None and cb is not None:
        return ca == cb
    return a.strip() == b.strip()


def _resolve_placeholder(ph: Any, facts: Any) -> Optional[str]:
    """-> the URL a `{{a.b}}` placeholder names in `facts`, or None when it does not
    resolve to a non-blank string (facts None/{}, path missing, '', None, non-str)."""
    if not isinstance(ph, str) or not isinstance(facts, dict):
        return None
    m = re.fullmatch(r"\{\{\s*([A-Za-z0-9_.]+)\s*\}\}", ph.strip())
    if not m:
        return None
    cur: Any = facts
    for part in m.group(1).split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur.strip() if isinstance(cur, str) and cur.strip() else None


_SUPERSEDE_LINE = re.compile(r"\b(supersed\w*|cancel+ed|cancel+ation|replac(?:e|es|ed|ement))\b", re.I)
_BAD_HEADING = re.compile(r"^\s*(references?|appendix)\b", re.I)


def _check_links(body: str, lines: List[str], starts: List[int], profile: dict,
                 facts: Any) -> List[Violation]:
    pol = profile.get("linkPolicy")
    if pol is None:
        return []
    if not isinstance(pol, dict):
        return [Violation("profile-malformed", "linkPolicy must be an object")]
    simple = ("allowed" in pol) or ("maxLinks" in pol)
    seed = any(k in pol for k in (
        "defaultAllowLinks", "standardLinks", "supersedesException", "everythingElseBanned"))
    if simple and seed:
        return [Violation("profile-malformed", "linkPolicy mixes the simple and the seed shape")]
    # Decode HTML character references ONCE, before anything else looks at the body, so
    # every later stage sees what a renderer sees (`&#47;&#47;h`, `&amp;bcc=`, `&#64;`).
    # This can only turn text INTO a recognisable link (never hide one), so it is a
    # fail-closed direction; a `&lt;a href=..&gt;` code sample is therefore flagged.
    # Line numbers below refer to the decoded body.
    body = _unescape(body)
    lines = body.split("\n")
    starts = _line_starts(body)
    links, residual = _extract(body, starts)
    res = _links_simple(links, pol) if simple else _links_seed(body, lines, links, pol, facts)
    if _restricts_links(pol, simple) and not any(v.rule == "profile-malformed" for v in res):
        res = res + _syntax_hits(body, starts) + _residual_hits(residual, body, starts)
    return res


def _restricts_links(pol: dict, simple: bool) -> bool:
    """Does this linkPolicy restrict links (so unrecognised link-like text is a
    violation)? The simple shape always does (`allowed`/`maxLinks`); the seed shape
    does unless defaultAllowLinks is true AND everythingElseBanned is empty/absent
    (the same test `_links_seed` uses for 'everything else'). An empty `{}` policy is
    read as the seed shape with absent keys = banned, so it restricts. A profile with
    NO linkPolicy key never reaches here: nothing is restricted, no residual check."""
    if simple:
        return True
    return not (pol.get("defaultAllowLinks") is True and not pol.get("everythingElseBanned"))


def _links_simple(links: List[_Link], pol: dict) -> List[Violation]:
    allowed, mx = pol.get("allowed"), pol.get("maxLinks")
    if (not isinstance(allowed, list) or isinstance(mx, bool)
            or not isinstance(mx, int) or mx < 0):
        return [Violation("profile-malformed",
                          "linkPolicy needs allowed:[...] and maxLinks:int>=0 together")]
    parsed = _parse_allowed_list(allowed)
    out: List[Violation] = []
    ok: List[_Link] = []
    for l in links:
        if _url_permitted(l.url, parsed):
            ok.append(l)
        elif len(out) < MAX_MATCHES_PER_PATTERN:
            out.append(Violation("link-not-allowed",
                                 "link '%s' is not in linkPolicy.allowed" % _clip(l.url, 60), l.line))
    if len(ok) > mx:
        out.append(Violation("link-limit", "%d permitted links, linkPolicy.maxLinks is %d" % (len(ok), mx)))
    return out


def _links_seed(body: str, lines: List[str], links: List[_Link], pol: dict,
                facts: Any) -> List[Violation]:
    out: List[Violation] = []
    std = pol.get("standardLinks", [])
    if not isinstance(std, list) or any(not isinstance(e, dict) for e in std):
        return [Violation("profile-malformed", "linkPolicy.standardLinks must be a list of objects")]
    remaining = list(links)

    # a. standard links, each identified by its resolved URL
    for e in std:
        url = _resolve_placeholder(e.get("sourcePlaceholder"), facts)
        if url is None:
            # Unresolved: NEVER pooled and never claims a link. A required entry is
            # a violation (its identity is unknown, so nothing can satisfy it); an
            # optional one simply stays inert, and every link stays 'everything else'.
            if e.get("required") is True:
                ph = e.get("sourcePlaceholder")
                out.append(Violation(
                    "link-required-unresolved",
                    "required standard link '%s' cannot be identified: placeholder %s did not "
                    "resolve to a URL in facts" % (
                        _clip(e.get("id"), 40),
                        _clip(ph, 60) if isinstance(ph, str) and ph else "(none declared)")))
            continue
        mine = [l for l in remaining if _same_url(l.url, url)]
        mine_ids = {id(l) for l in mine}
        remaining = [l for l in remaining if id(l) not in mine_ids]
        mc = e.get("maxCount")
        if isinstance(mc, int) and not isinstance(mc, bool) and len(mine) > mc:
            out.append(Violation(
                "link-limit", "standard link '%s' appears %d times, maxCount is %d"
                % (e.get("id"), len(mine), mc), mine[mc].line))
        if e.get("required") is True and not mine:
            out.append(Violation(
                "link-required-missing", "required standard link '%s' is missing" % e.get("id")))

    # b. supersedes exception
    exc = pol.get("supersedesException")
    if isinstance(exc, dict) and exc.get("allowed") is True:
        cap = exc.get("maxLinksPerPage", 1)
        if isinstance(cap, bool) or not isinstance(cap, int) or cap < 0:
            out.append(Violation("profile-malformed", "supersedesException.maxLinksPerPage must be int>=0"))
            cap = 0
        if cap and remaining:
            ok_line = _supersede_line_flags(lines)
            taken_ids = set()
            for l in remaining:
                if len(taken_ids) >= cap:
                    break
                if _supersede_eligible(l, ok_line):
                    taken_ids.add(id(l))
            remaining = [l for l in remaining if id(l) not in taken_ids]
    elif exc is not None and not isinstance(exc, dict):
        out.append(Violation("profile-malformed", "supersedesException must be an object"))

    # c. everything else
    banned = not (pol.get("defaultAllowLinks") is True and not pol.get("everythingElseBanned"))
    if banned:
        for l in remaining[:MAX_MATCHES_PER_PATTERN]:
            out.append(Violation(
                "link-not-allowed",
                "link '%s' is not covered by linkPolicy.standardLinks" % _clip(l.url, 60), l.line))
        if len(remaining) > MAX_MATCHES_PER_PATTERN:
            out.append(Violation("link-not-allowed", "further uncovered links omitted"))
    return out


def _supersede_line_flags(lines: List[str]) -> List[bool]:
    """Per line (0-based): does it mention supersede/cancel/replace AND sit outside
    a References/Appendix section? Built once in O(lines) (the nearest preceding
    heading, if any, decides the section)."""
    flags: List[bool] = []
    in_bad = False
    for ln in lines:
        hm = _HEADING.match(ln)
        if hm:
            in_bad = bool(_BAD_HEADING.match(hm.group(2)))
        flags.append((not in_bad) and bool(_SUPERSEDE_LINE.search(ln)))
    return flags


def _supersede_eligible(link: _Link, ok_line: List[bool]) -> bool:
    """A supersedes-exception link is an http(s) URL without userinfo, not on a
    github host, on a line flagged by `_supersede_line_flags`."""
    if not (1 <= link.line <= len(ok_line)) or not ok_line[link.line - 1]:
        return False
    p = _split_url(link.url)
    return p is not None and p[0] in ("http", "https") and "github" not in p[1]


# ---------------------------------------------------------------------- title

_DATE_TOKEN = re.compile(r"^\s*(?:MMM|DD|YYYY)(?:[\s,.\-/]+(?:MMM|DD|YYYY))*\s*$")
_PLACEHOLDER = re.compile(r"<([A-Za-z][^<>]*)>")


def _title_regex(pattern: str) -> str:
    if "(?" in pattern or not _PLACEHOLDER.search(pattern):
        return pattern  # a plain regex
    out, pos = [], 0
    for m in _PLACEHOLDER.finditer(pattern):
        out.append(_literal(pattern[pos:m.start()]))
        inner = m.group(1)
        if _DATE_TOKEN.match(inner):
            rx = ""
            for p in re.split(r"(MMM|DD|YYYY)", inner.strip()):
                if p == "MMM":
                    rx += r"[A-Za-z]{3,9}\.?"
                elif p == "DD":
                    rx += r"\d{1,2},?"
                elif p == "YYYY":
                    rx += r"\d{4}"
                elif p:
                    rx += r"\s+" if not p.strip() else _literal(p)
            out.append(rx)
        else:
            out.append(r"\S(?:.*?\S)?")
        pos = m.end()
    out.append(_literal(pattern[pos:]))
    return "".join(out)


def _literal(text: str) -> str:
    return r"\s+".join(re.escape(p) for p in re.split(r"\s+", text)) if text else ""


def _check_title(title: Any, profile: dict) -> List[Any]:
    pat = profile.get("titlePattern")
    if pat is None:
        return []
    if not isinstance(pat, str) or not pat:
        return [Violation("profile-malformed", "titlePattern must be a non-empty string")]
    if not isinstance(title, str):
        return [Violation("title-pattern", "title must be a string")]
    if len(title) > MAX_TITLE_CHARS:
        return [Violation("title-pattern", "title longer than %d chars" % MAX_TITLE_CHARS)]
    if "\n" in title or "\r" in title:
        return [Violation("title-pattern", "title must be a single line")]
    rx, bad = _compile(_title_regex(pat), "titlePattern", 0)
    if bad:
        return [bad]
    rxs = _title_regex(pat)

    def then(ok):
        if ok:
            return []
        return [Violation(
            "title-pattern",
            "title '%s' does not match titlePattern '%s'" % (_clip(title, 80), _clip(pat, 80)))]
    return [_Job("fullmatch", rxs, 0, title, then)]


# ------------------------------------------------------------------ public API

def validate_draft(rendered_body: str, title: str, profile: dict, *,
                   facts: Optional[dict] = None) -> List[Violation]:
    """Mechanically validate a rendered draft. [] means valid."""
    if not isinstance(rendered_body, str):
        raise TypeError("rendered_body must be a str")
    if not isinstance(profile, dict):
        return [Violation("profile-malformed", "profile must be an object")]
    out: List[Any] = _check_title(title, profile)
    if len(rendered_body) > MAX_BODY_CHARS:
        out.append(Violation(
            "body-too-large",
            "body is %d chars, limit is %d; not validated" % (len(rendered_body), MAX_BODY_CHARS)))
        return _resolve_jobs(out)
    if rendered_body.startswith("\ufeff"):
        rendered_body = rendered_body[1:]          # cmark drops one leading BOM before parsing
    body = rendered_body.replace("\r\n", "\n").replace("\r", "\n")
    lines = body.split("\n")
    starts = _line_starts(body)
    out.extend(_check_sections(body, lines, profile))
    out.extend(_check_banned(body, starts, profile))
    out.extend(_check_links(body, lines, starts, profile, facts))
    return _sort_banned(_resolve_jobs(out))


def _sort_banned(vs: List[Violation]) -> List[Violation]:
    """Put the banned-token violations in line order (stable), in the slots they
    already occupy; every other violation keeps its place."""
    idx = [i for i, v in enumerate(vs) if v.rule == "banned-token"]
    if len(idx) > 1:
        ordered = sorted((vs[i] for i in idx), key=lambda v: (v.line is None, v.line or 0))
        vs = list(vs)
        for i, v in zip(idx, ordered):
            vs[i] = v
    return vs


def assert_draft_valid(rendered_body: str, title: str, profile: dict, *,
                       facts: Optional[dict] = None) -> None:
    """Raise DraftValidationError (carrying .violations) unless the draft is valid."""
    v = validate_draft(rendered_body, title, profile, facts=facts)
    if v:
        raise DraftValidationError(v)


if __name__ == "__main__" and sys.argv[1:] == [_CHILD_FLAG]:
    sys.exit(_regex_child_main())
