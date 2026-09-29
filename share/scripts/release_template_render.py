#!/usr/bin/env python3
"""Minimal Handlebars-like template renderer over the release fact dictionary.

XACA-1343 Phase 2 (subitem -004). Shared by kb-wiki (XACA-1344) and kb-notify
(XACA-1345). Stdlib only; runs under /usr/bin/python3 3.9.

Public API (stable):
    render(template_str, facts) -> str
    TemplateRenderError

Five behaviors: the four constructs below plus HTML comment stripping.
Anything else is an error, never a silent pass-through: a template that needs
more surfaces as a renderer gap.

    {{a.b.c}}                       dotted-path substitution
    {{#each path}}...{{/each}}      iterate a list; {{this}} / {{this.field}}
    {{#if path}}...{{/if}}          conditional block
    {{a.b?}}                        trailing '?': when the value is missing, None or
                                    empty drop the token, or the whole line if the
                                    line has no other content (see hybrid drop)

Scoping
    Inside #each, `this` is the current element (innermost loop wins).
    Any path not starting with `this` resolves against the root facts.

Truthiness (#if and the `?` suffix)
    None, False, 0, "", [] and {} are falsy; everything else is truthy.
    A path that does not exist is falsy for #if and for `?`.

Value formatting (plain {{path}} substitution)
    str   -> as-is
    int   -> str(int)
    float -> str(float)
    bool  -> "Yes" / "No"   (checked before int, bool is an int subclass)
    dict / list / None / anything else -> TemplateRenderError
    An empty string "" renders as empty: it is a deliberate fact value.
    An absent key or None is an error (fail closed): a CR with a blank field
    must never ship to approvers.

Fail closed
    Missing required path, unbalanced/unknown block tags, malformed tags,
    an unterminated `{{`, and #each over a non-list all raise
    TemplateRenderError naming the path and the 1-based source line.

Line semantics (decided per SOURCE line, never inside the recursive renderer)
    A "source line" is a line of the template AFTER comment stripping (so a
    multi-line comment that shares its first and last line with text yields one
    merged line). Newlines may be "\\n" or "\\r\\n"; both are handled and the
    original newline text is preserved in the output.

    Standalone block lines: a line whose only non-whitespace content is block
    tags ({{#each}}, {{/each}}, {{#if}}, {{/if}}; one or several side by side)
    is removed together with its whitespace and newline, so block markers do
    not leave blank lines. A block tag that shares its line with ANY text or
    substitution is inline and keeps everything around it.

    Open tag ending a line: when an inline `{{#if}}`/`{{#each}}` is the last
    thing on a line that has other content before it (`Name: {{n}} {{#if a}}`),
    that line's newline is emitted OUTSIDE the block, so the line stays a line
    whether the block renders or not. The block body then starts on the next line.

    `?` hybrid drop: `{{path?}}` whose value is missing/None/empty is dropped,
    and the SOURCE line that contains it is judged on its TEMPLATE text (not on
    rendered output). Remove every `?` tag and every block tag from the line;
    if what is left has no alphanumeric character (`str.isalnum()`, Unicode) and
    no plain `{{path}}` substitution, the line has no content of its own:
      * no content -> the WHOLE line is dropped (text, punctuation such as
        `- | * > #`, newline, everything the line produced), e.g. `{{x?}}`,
        `- {{x?}}`, `| {{x?}} |`;
      * has content -> only the empty `?` token is dropped and the rest of the
        line is kept verbatim (`Fixed X. {{x?}} |` -> `Fixed X.  |`; spaces are
        not collapsed).
    A required `{{path}}` that renders to "" still counts as content. Several
    `?` tags on one line: the rule is applied once per line; the line is
    dropped only if it has no content and NO `?` on it produced a value
    (all evaluated `?` tags empty, at least one evaluated). Block tags on a
    dropped line still take effect (a `{{#if b}}` opened there still opens; its
    body lines and closing tag are unaffected). Inside a `#each` that spans
    lines the drop applies to that iteration's copy of the line only,
    INCLUDING the text after the open tag on the opening line:
    `{{#each L}}- {{this.v?}}` NEWLINE `{{/each}}` over [{v:""},{v:"q"}]
    renders `- q` NEWLINE (the empty iteration's whole line is dropped). An
    `#each` that opens AND closes on the same line as the `?` is part of that
    one line. Text
    after the closing `{{/each}}` of a multi-line `#each` on the same source
    line belongs to the outer copy of that line.

    Nesting is capped at 100 open blocks (MAX_DEPTH); deeper raises
    TemplateRenderError. Every scanning pass is linear (str.find based).

No HTML escaping
    Output is Markdown, not HTML. Values are emitted verbatim.

Injection guard
    Fact values are never re-scanned: output is built by concatenating parsed
    template nodes with already-resolved values, so a value containing
    "{{x}}" renders literally.

HTML comment stripping (template only, before parsing)
    `<!-- ... -->` blocks (non-greedy, may span lines) are removed first, so a
    `{{...}}` inside a comment is never evaluated and never reaches the output.
    A comment that is alone on its line(s) is removed together with those
    lines, newline included (no blank line left); a comment inline with other
    text is removed and the surrounding text is kept. An unterminated `<!--`
    raises TemplateRenderError naming its line. Error line numbers still refer
    to the ORIGINAL template. Fact values are never stripped: a value that
    contains `<!-- -->` renders literally.
"""
from __future__ import annotations

import re
from bisect import bisect_left, bisect_right
from typing import Any, Callable, List, Optional, Set, Tuple

__all__ = ["render", "TemplateRenderError", "MAX_DEPTH"]

#: Maximum number of simultaneously open block tags.
MAX_DEPTH = 100


class TemplateRenderError(ValueError):
    """Raised for any template or fact problem. Never swallowed silently."""


_PATH_RE = re.compile(r"^(?:this|[A-Za-z_][A-Za-z0-9_-]*)(?:\.[A-Za-z0-9_][A-Za-z0-9_-]*)*$")
_MISSING = object()


# ------------------------------------------------------------ comment stripping

def _strip_comments(src: str) -> Tuple[str, Callable[[int], int]]:
    """Remove HTML comments (linear, str.find based).

    Returns (text, line_of): line_of(p) is the ORIGINAL 1-based line of offset
    p of the returned text. Kept text is a concatenation of chunks that each lie
    on ONE original line, so a per-chunk line table is enough.
    """
    spans: List[Tuple[int, int]] = []
    pos = 0
    while True:
        i = src.find("<!--", pos)
        if i == -1:
            break
        j = src.find("-->", i + 4)
        if j == -1:
            raise TemplateRenderError(
                "unterminated '<!--' at line %d" % (src.count("\n", 0, i) + 1))
        spans.append((i, j + 3))
        pos = j + 3

    nlpos: List[int] = []
    p = src.find("\n")
    while p != -1:
        nlpos.append(p)
        p = src.find("\n", p + 1)
    if not spans:
        return src, lambda q: bisect_left(nlpos, q) + 1

    kept: List[Tuple[int, str]] = []          # (orig_offset, text)
    cur: List[Optional[Tuple[int, str]]] = []  # None marks a removed comment

    def flush() -> None:
        if not cur:
            return
        has_c = any(x is None for x in cur)
        only_ws = all(x is None or not x[1].strip(" \t\r\n") for x in cur)
        if not (has_c and only_ws):
            kept.extend(x for x in cur if x is not None)
        cur.clear()

    def segment(a: int, b: int) -> None:
        p = a
        while p < b:
            nl = src.find("\n", p, b)
            if nl == -1:
                cur.append((p, src[p:b]))
                return
            cur.append((p, src[p:nl + 1]))
            flush()
            p = nl + 1

    prev = 0
    for s, e in spans:
        segment(prev, s)
        cur.append(None)
        prev = e
    segment(prev, len(src))
    flush()

    starts: List[int] = []
    lines: List[int] = []
    off = 0
    for o, t in kept:
        starts.append(off)
        lines.append(bisect_left(nlpos, o) + 1)
        off += len(t)
    if not kept:
        return "", lambda q: 1
    return ("".join(t for _o, t in kept),
            lambda q: lines[bisect_right(starts, q) - 1])


# ---------------------------------------------------------------- tokenizing

class _Tok:
    __slots__ = ("kind", "text", "line", "sline", "droppable")

    def __init__(self, kind: str, text: str, line: int, sline: int) -> None:
        self.kind = kind          # "text" | "nl" | "tag"
        self.text = text
        self.line = line          # 1-based ORIGINAL line (error messages)
        self.sline = sline        # 0-based line of the comment-stripped text
        self.droppable = False    # `?` tags: the line has no content of its own


def _tokenize(src: str, orig: Callable[[int], int]) -> List[_Tok]:
    """Linear scan into text / newline / tag tokens. Every `{{` must open a
    valid same-line tag; anything else raises (not just the template tail)."""
    toks: List[_Tok] = []
    n = len(src)
    state = [0]  # current source line index

    def add_text(a: int, b: int) -> None:
        p = a
        while p < b:
            nl = src.find("\n", p, b)
            if nl == -1:
                toks.append(_Tok("text", src[p:b], orig(p), state[0]))
                return
            end = nl - 1 if nl > p and src[nl - 1] == "\r" else nl
            if end > p:
                toks.append(_Tok("text", src[p:end], orig(p), state[0]))
            toks.append(_Tok("nl", src[end:nl + 1], orig(end), state[0]))
            state[0] += 1
            p = nl + 1

    pos = 0
    while pos < n:
        i = src.find("{{", pos)
        if i == -1:
            add_text(pos, n)
            break
        if i > pos:
            add_text(pos, i)
        j = src.find("}}", i + 2)
        if j == -1 or src.find("\n", i + 2, j) != -1:
            raise TemplateRenderError("unterminated '{{' at line %d" % orig(i))
        toks.append(_Tok("tag", src[i + 2:j].strip(), orig(i), state[0]))
        pos = j + 2
    return toks


def _is_block(tag: str) -> bool:
    return tag.startswith("#") or tag.startswith("/")


def _layout(toks: List[_Tok]) -> List[_Tok]:
    """Per-SOURCE-line decisions, made once, before parsing/rendering:
    standalone block lines are removed, an open tag ending a content line has
    its newline hoisted before it, and `?` tags learn whether their line has
    content of its own (the hybrid drop rule)."""
    out: List[_Tok] = []
    i, n = 0, len(toks)
    while i < n:
        s = toks[i].sline
        j = i
        while j < n and toks[j].sline == s:
            j += 1
        line = toks[i:j]
        i = j
        sig = [t for t in line
               if t.kind == "tag" or (t.kind == "text" and t.text.strip(" \t"))]
        if sig and all(t.kind == "tag" and _is_block(t.text) for t in sig):
            out.extend(sig)  # standalone block line: no ws, no newline
            continue
        content = any(
            (t.kind == "text" and any(c.isalnum() for c in t.text))
            or (t.kind == "tag" and not _is_block(t.text) and not t.text.endswith("?"))
            for t in line)
        for t in line:
            if t.kind == "tag" and not _is_block(t.text) and t.text.endswith("?"):
                t.droppable = not content
        # trailing run of open tags after real content: keep the newline outside
        k = len(sig)
        while k > 0 and sig[k - 1].kind == "tag" and sig[k - 1].text.startswith("#"):
            k -= 1
        if 0 < k < len(sig) and any(
                not (t.kind == "tag" and _is_block(t.text)) for t in sig[:k]):
            first = line.index(sig[k])
            rest = line[first:]
            opens = [t for t in rest if t.kind == "tag"]
            others = [t for t in rest if t.kind != "tag"]
            line = line[:first] + others + opens
        out.extend(line)
    return out


# ------------------------------------------------------------------- parsing
# Node forms (tuples):
#   ("text", str, sline)
#   ("var", path, optional, line, sline, droppable)
#   ("each", path, [nodes], line, sline, end_sline)  (end_sline set at {{/each}})
#   ("if", path, [nodes], line, sline)

def _check_path(path: str, line: int, raw: str) -> None:
    if not _PATH_RE.match(path):
        raise TemplateRenderError("invalid tag '{{%s}}' at line %d" % (raw, line))


def _parse(toks: List[_Tok]) -> list:
    root: list = []
    stack: List[Tuple[str, str, list, int]] = []  # (kind, path, parent, line)
    cur = root
    for t in toks:
        if t.kind != "tag":
            if t.text:
                cur.append(("text", t.text, t.sline))
            continue
        tag = t.text
        if tag.startswith("#"):
            parts = tag[1:].split(None, 1)
            if len(parts) != 2 or parts[0] not in ("each", "if"):
                raise TemplateRenderError("unknown block tag '{{%s}}' at line %d" % (tag, t.line))
            kind, path = parts[0], parts[1].strip()
            _check_path(path, t.line, tag)
            if len(stack) >= MAX_DEPTH:
                raise TemplateRenderError(
                    "blocks nested deeper than %d at line %d" % (MAX_DEPTH, t.line))
            node_children: list = []
            cur.append((kind, path, node_children, t.line, t.sline))
            stack.append((kind, path, cur, t.line))
            cur = node_children
        elif tag.startswith("/"):
            kind = tag[1:].strip()
            if kind not in ("each", "if"):
                raise TemplateRenderError("unknown block tag '{{%s}}' at line %d" % (tag, t.line))
            if not stack:
                raise TemplateRenderError("unbalanced '{{%s}}' at line %d (no open block)" % (tag, t.line))
            open_kind, _p, parent, open_line = stack.pop()
            if open_kind != kind:
                raise TemplateRenderError(
                    "unbalanced '{{%s}}' at line %d (open '#%s' from line %d)"
                    % (tag, t.line, open_kind, open_line))
            if kind == "each":
                # The each node is the last thing appended to `parent`; record
                # its closing source line so the renderer knows if it spans lines.
                parent[-1] = parent[-1] + (t.sline,)
            cur = parent
        else:
            optional = tag.endswith("?")
            path = tag[:-1] if optional else tag
            _check_path(path, t.line, tag)
            cur.append(("var", path, optional, t.line, t.sline, t.droppable))
    if stack:
        k, p, _parent, ln = stack[-1]
        raise TemplateRenderError("unclosed '{{#%s %s}}' opened at line %d" % (k, p, ln))
    return root


# ----------------------------------------------------------------- rendering

def _resolve(path: str, root: Any, this: Any, has_this: bool) -> Any:
    parts = path.split(".")
    if parts[0] == "this":
        if not has_this:
            return _MISSING
        val: Any = this
        parts = parts[1:]
    else:
        val = root
    for p in parts:
        if isinstance(val, dict) and p in val:
            val = val[p]
        else:
            return _MISSING
    return val


def _truthy(v: Any) -> bool:
    if v is _MISSING or v is None:
        return False
    if isinstance(v, (bool, int, float)):
        return bool(v)
    if isinstance(v, (str, list, dict, tuple)):
        return len(v) > 0
    return True


def _fmt(v: Any, path: str, line: int) -> str:
    if isinstance(v, bool):
        return "Yes" if v else "No"
    if isinstance(v, str):
        return v
    if isinstance(v, (int, float)):
        return str(v)
    raise TemplateRenderError(
        "path '%s' at line %d is a %s and cannot be substituted directly"
        % (path, line, type(v).__name__))


# A line INSTANCE is (source line, iteration path): the serials of the
# multi-line #each iterations currently open that were opened on an EARLIER
# source line. An #each opened on the same line does not split the line.
_Inst = Tuple[int, Tuple[int, ...]]


class _State:
    def __init__(self) -> None:
        self.entries: List[Tuple[_Inst, str]] = []
        self.empties: Set[_Inst] = set()   # instances with an empty droppable `?`
        self.kept: Set[_Inst] = set()      # instances where some `?` had a value
        self.iters: List[Tuple[int, int]] = []  # (open source line, serial)
        self.serial = 0

    def inst(self, sline: int) -> _Inst:
        if not self.iters:
            return (sline, ())
        return (sline, tuple(ser for o, ser in self.iters if o != sline))

    def write(self, sline: int, s: str) -> None:
        if s:
            self.entries.append((self.inst(sline), s))

    def optional_empty(self, sline: int, droppable: bool) -> None:
        """The XACA-1343-027 hybrid switch lives here. Empty `?` token: when the
        line has no content of its own (`droppable`) mark the line instance for
        removal; otherwise drop only the token (write nothing). To change the
        rule (e.g. token-only always), change this method."""
        if droppable:
            self.empties.add(self.inst(sline))

    def optional_value(self, sline: int) -> None:
        self.kept.add(self.inst(sline))

    def result(self) -> str:
        drop = self.empties - self.kept
        if not drop:
            return "".join(s for _i, s in self.entries)
        return "".join(s for i, s in self.entries if i not in drop)


def _render_nodes(nodes: list, root: Any, this: Any, has_this: bool, st: _State) -> None:
    for node in nodes:
        kind = node[0]
        if kind == "text":
            st.write(node[2], node[1])
        elif kind == "var":
            _k, path, optional, line, sline, droppable = node
            val = _resolve(path, root, this, has_this)
            if optional:
                if not _truthy(val):
                    st.optional_empty(sline, droppable)
                    continue
                st.optional_value(sline)
            elif val is _MISSING or val is None:
                raise TemplateRenderError(
                    "missing required path '%s' at line %d" % (path, line))
            st.write(sline, _fmt(val, path, line))
        elif kind == "if":
            if _truthy(_resolve(node[1], root, this, has_this)):
                _render_nodes(node[2], root, this, has_this, st)
        elif kind == "each":
            _k, path, children, line, sline, end_sline = node
            # Multi-line #each: text after the open tag on its opening line is
            # part of EACH iteration's line instance (XACA-1343-028). A
            # single-line #each keeps sharing the one line (owner == sline).
            owner = -1 if end_sline > sline else sline
            seq = _resolve(path, root, this, has_this)
            if seq is _MISSING or seq is None:
                raise TemplateRenderError(
                    "missing required path '%s' at line %d" % (path, line))
            if not isinstance(seq, (list, tuple)):
                raise TemplateRenderError(
                    "#each path '%s' at line %d is a %s, not a list"
                    % (path, line, type(seq).__name__))
            for item in seq:
                st.serial += 1
                st.iters.append((owner, st.serial))
                _render_nodes(children, root, item, True, st)
                st.iters.pop()


def render(template_str: str, facts: Optional[dict]) -> str:
    """Render `template_str` against the fact dictionary `facts`.

    Raises TemplateRenderError on any template or fact problem.
    """
    if not isinstance(template_str, str):
        raise TemplateRenderError("template must be a str")
    if not isinstance(facts, dict):
        raise TemplateRenderError("facts must be a dict")
    text, line_of = _strip_comments(template_str)
    toks = _layout(_tokenize(text, line_of))
    nodes = _parse(toks)
    st = _State()
    _render_nodes(nodes, facts, None, False, st)
    return st.result()
