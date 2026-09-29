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

`facts` is optional. It is only used to resolve linkPolicy.standardLinks[]
`sourcePlaceholder` values (e.g. "{{links.testingLog}}") to the concrete URL, so
each standard link can be identified individually. Without it, standard links
are matched as a pool (see LINKS).

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
    `<a href="...">`, or a bare http(s)/ftp/mailto URL. Relative and `#anchor`
    targets count too (fail closed). Bare URLs are counted because the default
    templates render `{{links.testingLog}}` as a bare URL. A `[t](url)` is one
    link, not two (the span is masked before the bare-URL scan).
    Simple shape {allowed, maxLinks}: a link is permitted iff its URL starts
    with an `allowed` entry or its host equals one; an empty `allowed` permits
    nothing. Permitted links beyond maxLinks are a violation.
    Seed shape {defaultAllowLinks, standardLinks[], supersedesException,
    everythingElseBanned}, evaluated in this order:
      a. standardLinks entry whose sourcePlaceholder resolves (via `facts`) to a
         URL claims links equal to it (count <= maxCount when present; absent
         with required:true is a violation);
      b. supersedesException (only if allowed: true): up to maxLinksPerPage
         (default 1) leftover links that sit on a line mentioning
         supersede/cancel/replace, outside a References/Appendix section, and not
         a github host. `mustResolveUnderFolder`, `appliesTo`,
         `needsLeadDecision` are publish-time / prose and are not enforced here;
      c. standardLinks entries that cannot be resolved share a pool: capacity =
         sum of their maxCount (an entry without maxCount is unbounded), and
         at least as many links as unresolved required entries must exist;
      d. anything left is "everything else" and is a violation unless
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
    Python's `re` has no timeout. Bounds: body <= MAX_BODY_CHARS (over -> one
    `body-too-large` violation, no regex is run on it); title <= MAX_TITLE_CHARS;
    pattern <= MAX_PATTERN_CHARS; every profile regex is compiled once; and a
    static screen rejects nested unbounded quantifiers such as `(a+)+`
    (`unsafe-pattern`). The screen is a heuristic, not a proof: profiles are
    team-owned config, not hostile input, and this keeps accidents out.
"""
from __future__ import annotations

import re
from bisect import bisect_right
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlsplit

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
]

MAX_BODY_CHARS = 200_000
MAX_TITLE_CHARS = 1_000
MAX_PATTERN_CHARS = 2_000
MAX_MATCHES_PER_PATTERN = 10
SNIPPET_CHARS = 40


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


def _check_section_rules(sec: _Section, text: str, first_line: int) -> List[Violation]:
    out: List[Violation] = []
    fmt = sec.spec.get("format")
    if isinstance(fmt, str) and _RX_PREFIX.match(fmt):
        pat = _RX_PREFIX.sub("", fmt, count=1)
        rx, bad = _compile(pat, "section '%s' format" % sec.id)
        if bad:
            out.append(bad)
        elif not rx.search(text):
            out.append(Violation(
                "section-format",
                "section '%s': text does not match format /%s/" % (sec.id, _clip(pat, 80)),
                first_line))
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
            m = rx.search(text)
            if m:
                out.append(Violation(
                    "section-guardrail",
                    "section '%s': forbidden /%s/ matched '%s'"
                    % (sec.id, _clip(pat, 80), _snippet(m.group(0))),
                    first_line + text.count("\n", 0, m.start())))
    return out


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


def _check_banned(body: str, starts: List[int], profile: dict) -> List[Violation]:
    raw = profile.get("bannedTokenPatterns")
    if raw is None:
        return []
    if not isinstance(raw, list):
        return [Violation("profile-malformed", "bannedTokenPatterns must be a list")]
    out: List[Violation] = []
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
        listed = 0
        for m in rx.finditer(body):
            if standalone and not _is_standalone(body, m.start(), m.end()):
                continue
            if listed >= MAX_MATCHES_PER_PATTERN:
                out.append(Violation(
                    "banned-token",
                    "/%s/: further matches omitted" % _clip(pat, 80)))
                break
            listed += 1
            detail = "/%s/ matched '%s'" % (_clip(pat, 80), _snippet(m.group(0)))
            if reason:
                detail += " - " + _clip(reason, 100)
            out.append(Violation("banned-token", detail, _line_of(starts, m.start())))
    return out


# ---------------------------------------------------------------------- links

class _Link:
    __slots__ = ("url", "line", "start")

    def __init__(self, url: str, line: int, start: int):
        self.url, self.line, self.start = url, line, start


_MD_INLINE = re.compile(
    r"!?\[[^\]\n]*\]\(\s*<?([^)\s>]+)>?(?:\s+(?:\"[^\"]*\"|'[^']*'))?\s*\)")
_REF_DEF = re.compile(r"^[ \t]{0,3}\[([^\]\n]+)\]:[ \t]*<?(\S+?)>?(?=\s|$)", re.M)
_AUTOLINK = re.compile(r"<((?:https?|ftp)://[^>\s]+|mailto:[^>\s]+)>")
_HTML_A = re.compile(r"<a\s[^>]*?href\s*=\s*[\"']([^\"']*)[\"'][^>]*>", re.I)
_BARE = re.compile(r"(?:(?:https?|ftp)://|mailto:)[^\s<>\[\]()\"']+", re.I)
_TRAIL = ".,;:!?*_"


def _mask(text: str, start: int, end: int) -> str:
    seg = re.sub(r"[^\n]", " ", text[start:end])
    return text[:start] + seg + text[end:]


def _extract_links(body: str, starts: List[int]) -> List[_Link]:
    found: List[_Link] = []
    work = body

    def scan(rx, group: int, filt=None):
        nonlocal work
        for m in list(rx.finditer(work)):
            url = m.group(group)
            if filt and not filt(m):
                continue
            if rx is _BARE:
                url = url.rstrip(_TRAIL)
            found.append(_Link(url.strip(), _line_of(starts, m.start()), m.start()))
            work = _mask(work, m.start(), m.end())

    scan(_MD_INLINE, 1)
    scan(_REF_DEF, 2, lambda m: not m.group(1).startswith("^"))
    scan(_AUTOLINK, 1)
    scan(_HTML_A, 1)
    scan(_BARE, 0)
    found.sort(key=lambda l: l.start)
    return [l for l in found if l.url]


def _norm_url(u: str) -> str:
    return u.strip().rstrip("/")


def _resolve_placeholder(ph: Any, facts: Any) -> Optional[str]:
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
    return cur if isinstance(cur, str) and cur.strip() else None


_SUPERSEDE_LINE = re.compile(r"\b(supersed\w*|cancel+ed|cancel+ation|replac(?:e|es|ed|ement))\b", re.I)
_BAD_HEADING = re.compile(r"^\s*(references?|appendix)\b", re.I)


def _url_permitted(url: str, allowed: List[str]) -> bool:
    try:
        host = (urlsplit(url).hostname or "").lower()
    except ValueError:
        host = ""
    for a in allowed:
        if not isinstance(a, str) or not a:
            continue
        if url.lower().startswith(a.lower()) or (host and host == a.lower()):
            return True
    return False


def _check_links(body: str, lines: List[str], starts: List[int], profile: dict,
                 facts: Any) -> List[Violation]:
    pol = profile.get("linkPolicy")
    if pol is None:
        return []
    if not isinstance(pol, dict):
        return [Violation("profile-malformed", "linkPolicy must be an object")]
    links = _extract_links(body, starts)
    simple = ("allowed" in pol) or ("maxLinks" in pol)
    seed = any(k in pol for k in (
        "defaultAllowLinks", "standardLinks", "supersedesException", "everythingElseBanned"))
    if simple and seed:
        return [Violation("profile-malformed", "linkPolicy mixes the simple and the seed shape")]
    if simple:
        return _links_simple(links, pol)
    return _links_seed(body, lines, links, pol, facts)


def _links_simple(links: List[_Link], pol: dict) -> List[Violation]:
    allowed, mx = pol.get("allowed"), pol.get("maxLinks")
    if (not isinstance(allowed, list) or isinstance(mx, bool)
            or not isinstance(mx, int) or mx < 0):
        return [Violation("profile-malformed",
                          "linkPolicy needs allowed:[...] and maxLinks:int>=0 together")]
    out: List[Violation] = []
    ok: List[_Link] = []
    for l in links:
        if _url_permitted(l.url, allowed):
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

    # a. resolved standard links
    unresolved: List[dict] = []
    for e in std:
        url = _resolve_placeholder(e.get("sourcePlaceholder"), facts)
        if url is None:
            unresolved.append(e)
            continue
        mine = [l for l in remaining if _norm_url(l.url) == _norm_url(url)]
        remaining = [l for l in remaining if l not in mine]
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
        elig = [l for l in remaining if _supersede_eligible(l, lines)]
        taken = elig[:cap]
        remaining = [l for l in remaining if l not in taken]
    elif exc is not None and not isinstance(exc, dict):
        out.append(Violation("profile-malformed", "supersedesException must be an object"))

    # c. pooled (unresolvable) standard links
    if unresolved:
        cap: Optional[int] = 0
        need = 0
        for e in unresolved:
            mc = e.get("maxCount")
            if isinstance(mc, int) and not isinstance(mc, bool):
                if cap is not None:
                    cap += mc
            else:
                cap = None
            if e.get("required") is True:
                need += 1
        take = remaining if cap is None else remaining[:cap]
        remaining = [] if cap is None else remaining[cap:]
        if len(take) < need:
            ids = ", ".join(str(e.get("id")) for e in unresolved if e.get("required") is True)
            out.append(Violation(
                "link-required-missing",
                "expected at least %d standard link(s) (%s), found %d" % (need, ids, len(take))))

    # d. everything else
    banned = not (pol.get("defaultAllowLinks") is True and not pol.get("everythingElseBanned"))
    if banned:
        for l in remaining[:MAX_MATCHES_PER_PATTERN]:
            out.append(Violation(
                "link-not-allowed",
                "link '%s' is not covered by linkPolicy.standardLinks" % _clip(l.url, 60), l.line))
        if len(remaining) > MAX_MATCHES_PER_PATTERN:
            out.append(Violation("link-not-allowed", "further uncovered links omitted"))
    return out


def _supersede_eligible(link: _Link, lines: List[str]) -> bool:
    if not (1 <= link.line <= len(lines)):
        return False
    if not _SUPERSEDE_LINE.search(lines[link.line - 1]):
        return False
    try:
        if "github" in (urlsplit(link.url).hostname or "").lower():
            return False
    except ValueError:
        return False
    for j in range(link.line - 1, -1, -1):
        hm = _HEADING.match(lines[j])
        if hm:
            return not _BAD_HEADING.match(hm.group(2))
    return True


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


def _check_title(title: Any, profile: dict) -> List[Violation]:
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
    if not rx.fullmatch(title):
        return [Violation(
            "title-pattern",
            "title '%s' does not match titlePattern '%s'" % (_clip(title, 80), _clip(pat, 80)))]
    return []


# ------------------------------------------------------------------ public API

def validate_draft(rendered_body: str, title: str, profile: dict, *,
                   facts: Optional[dict] = None) -> List[Violation]:
    """Mechanically validate a rendered draft. [] means valid."""
    if not isinstance(rendered_body, str):
        raise TypeError("rendered_body must be a str")
    if not isinstance(profile, dict):
        return [Violation("profile-malformed", "profile must be an object")]
    out = _check_title(title, profile)
    if len(rendered_body) > MAX_BODY_CHARS:
        out.append(Violation(
            "body-too-large",
            "body is %d chars, limit is %d; not validated" % (len(rendered_body), MAX_BODY_CHARS)))
        return out
    body = rendered_body.replace("\r\n", "\n").replace("\r", "\n")
    lines = body.split("\n")
    starts = _line_starts(body)
    out.extend(_check_sections(body, lines, profile))
    out.extend(_check_banned(body, starts, profile))
    out.extend(_check_links(body, lines, starts, profile, facts))
    return out


def assert_draft_valid(rendered_body: str, title: str, profile: dict, *,
                       facts: Optional[dict] = None) -> None:
    """Raise DraftValidationError (carrying .violations) unless the draft is valid."""
    v = validate_draft(rendered_body, title, profile, facts=facts)
    if v:
        raise DraftValidationError(v)
