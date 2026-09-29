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
    {{a.b?}}                        trailing '?': drop the WHOLE LINE when the
                                    value is missing, None or empty

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

Standalone block lines
    A block tag ({{#each}}, {{/each}}, {{#if}}, {{/if}}) that is alone on its
    line (whitespace only around it) is removed together with its newline, so
    block markers do not leave blank lines. Inline block tags keep their
    surrounding text.

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
from typing import Any, List, Optional, Tuple

__all__ = ["render", "TemplateRenderError"]


class TemplateRenderError(ValueError):
    """Raised for any template or fact problem. Never swallowed silently."""


_TAG_RE = re.compile(r"\{\{(.*?)\}\}")
_PATH_RE = re.compile(r"^(?:this|[A-Za-z_][A-Za-z0-9_-]*)(?:\.[A-Za-z0-9_][A-Za-z0-9_-]*)*$")
_COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
_MISSING = object()


def _strip_comments(src: str) -> Tuple[str, List[int]]:
    """Remove HTML comments; return (text, orig_line) with orig_line[i] the
    1-based ORIGINAL line of stripped-text character i."""
    orig_line: List[int] = []
    n = 1
    for ch in src:
        orig_line.append(n)
        if ch == "\n":
            n += 1
    items: list = []  # (char, orig_offset) or None for a removed comment
    pos = 0
    for m in _COMMENT_RE.finditer(src):
        items.extend((src[i], i) for i in range(pos, m.start()))
        items.append(None)
        pos = m.end()
    idx = src.find("<!--", pos)
    if idx != -1:
        raise TemplateRenderError(
            "unterminated '<!--' at line %d" % (src.count("\n", 0, idx) + 1))
    items.extend((src[i], i) for i in range(pos, len(src)))
    chars: List[str] = []
    lines: List[int] = []
    line: list = []
    for it in items + [("\0", -1)]:
        last = it == ("\0", -1)
        if not last:
            line.append(it)
        if last or (it is not None and it[0] == "\n"):
            has_c = any(x is None for x in line)
            only_ws = all(x is None or x[0] in " \t\r\n" for x in line)
            if not (has_c and only_ws):
                for x in line:
                    if x is not None:
                        chars.append(x[0])
                        lines.append(orig_line[x[1]])
            line = []
    return "".join(chars), lines


# ---------------------------------------------------------------- tokenizing

class _Tok:
    __slots__ = ("kind", "text", "line")

    def __init__(self, kind: str, text: str, line: int) -> None:
        self.kind = kind  # "text" | "tag"
        self.text = text
        self.line = line


def _tokenize(src: str, lines: List[int]) -> List[_Tok]:
    toks: List[_Tok] = []
    pos = 0
    for m in _TAG_RE.finditer(src):
        if m.start() > pos:
            toks.append(_Tok("text", src[pos:m.start()], lines[pos]))
        toks.append(_Tok("tag", m.group(1).strip(), lines[m.start()]))
        pos = m.end()
    tail = src[pos:]
    if "{{" in tail:
        line = lines[pos + tail.index("{{")]
        raise TemplateRenderError("unterminated '{{' at line %d" % line)
    if tail:
        toks.append(_Tok("text", tail, lines[pos]))
    return toks


def _is_block(tag: str) -> bool:
    return tag.startswith("#") or tag.startswith("/")


def _strip_standalone(toks: List[_Tok]) -> None:
    """Remove block tags' own lines (in place on adjacent text tokens)."""
    for i, t in enumerate(toks):
        if t.kind != "tag" or not _is_block(t.text):
            continue
        prev = toks[i - 1] if i > 0 else None
        nxt = toks[i + 1] if i + 1 < len(toks) else None
        # text before the tag on its line
        if prev is None:
            before_ok, before_cut = True, 0
        elif prev.kind == "text":
            nl = prev.text.rfind("\n")
            seg = prev.text[nl + 1:]
            before_ok = seg.strip(" \t") == ""
            before_cut = len(seg)
        else:
            before_ok, before_cut = False, 0
        if not before_ok:
            continue
        if nxt is None:
            after_ok, after_cut = True, 0
        elif nxt.kind == "text":
            nl = nxt.text.find("\n")
            if nl == -1:
                seg = nxt.text
                after_ok = seg.strip(" \t") == ""
                after_cut = len(seg)
            else:
                seg = nxt.text[:nl]
                after_ok = seg.strip(" \t") == ""
                after_cut = nl + 1
        else:
            after_ok, after_cut = False, 0
        if not after_ok:
            continue
        if prev is not None and prev.kind == "text" and before_cut:
            prev.text = prev.text[:-before_cut]
        if nxt is not None and nxt.kind == "text" and after_cut:
            nxt.text = nxt.text[after_cut:]


# ------------------------------------------------------------------- parsing
# Node forms (tuples):
#   ("text", str)
#   ("var", path, optional, line)
#   ("each", path, [nodes], line)
#   ("if", path, [nodes], line)

def _check_path(path: str, line: int, raw: str) -> None:
    if not _PATH_RE.match(path):
        raise TemplateRenderError("invalid tag '{{%s}}' at line %d" % (raw, line))


def _parse(toks: List[_Tok]) -> list:
    root: list = []
    # stack of (kind, path, nodes, line)
    stack: List[Tuple[str, str, list, int]] = []
    cur = root
    for t in toks:
        if t.kind == "text":
            if t.text:
                cur.append(("text", t.text))
            continue
        tag = t.text
        if tag.startswith("#"):
            parts = tag[1:].split(None, 1)
            if len(parts) != 2 or parts[0] not in ("each", "if"):
                raise TemplateRenderError("unknown block tag '{{%s}}' at line %d" % (tag, t.line))
            kind, path = parts[0], parts[1].strip()
            _check_path(path, t.line, tag)
            node_children: list = []
            node = (kind, path, node_children, t.line)
            cur.append(node)
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
            cur = parent
        else:
            optional = tag.endswith("?")
            path = tag[:-1] if optional else tag
            _check_path(path, t.line, tag)
            cur.append(("var", path, optional, t.line))
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


class _Out:
    """Output buffer supporting whole-line drop for the `?` suffix."""

    def __init__(self) -> None:
        self.parts: List[str] = []

    def write(self, s: str) -> None:
        if s:
            self.parts.append(s)

    def truncate_current_line(self) -> None:
        # Remove everything written since the last newline.
        while self.parts:
            last = self.parts[-1]
            nl = last.rfind("\n")
            if nl == -1:
                self.parts.pop()
            else:
                self.parts[-1] = last[:nl + 1]
                return


def _render_nodes(nodes: list, root: Any, this: Any, has_this: bool, out: _Out) -> None:
    dropping = False
    for node in nodes:
        kind = node[0]
        if dropping:
            # Skip the rest of the source line, resume after its newline.
            if kind == "text":
                nl = node[1].find("\n")
                if nl != -1:
                    dropping = False
                    out.write(node[1][nl + 1:])
            continue
        if kind == "text":
            out.write(node[1])
        elif kind == "var":
            _k, path, optional, line = node
            val = _resolve(path, root, this, has_this)
            if optional:
                if not _truthy(val):
                    out.truncate_current_line()
                    dropping = True
                    continue
            elif val is _MISSING or val is None:
                raise TemplateRenderError(
                    "missing required path '%s' at line %d" % (path, line))
            out.write(_fmt(val, path, line))
        elif kind == "if":
            _k, path, children, _line = node
            if _truthy(_resolve(path, root, this, has_this)):
                _render_nodes(children, root, this, has_this, out)
        elif kind == "each":
            _k, path, children, line = node
            seq = _resolve(path, root, this, has_this)
            if seq is _MISSING or seq is None:
                raise TemplateRenderError(
                    "missing required path '%s' at line %d" % (path, line))
            if not isinstance(seq, (list, tuple)):
                raise TemplateRenderError(
                    "#each path '%s' at line %d is a %s, not a list"
                    % (path, line, type(seq).__name__))
            for item in seq:
                _render_nodes(children, root, item, True, out)


def render(template_str: str, facts: Optional[dict]) -> str:
    """Render `template_str` against the fact dictionary `facts`.

    Raises TemplateRenderError on any template or fact problem.
    """
    if not isinstance(template_str, str):
        raise TemplateRenderError("template must be a str")
    if not isinstance(facts, dict):
        raise TemplateRenderError("facts must be a dict")
    template_str, lines = _strip_comments(template_str)
    toks = _tokenize(template_str, lines)
    _strip_standalone(toks)
    nodes = _parse(toks)
    out = _Out()
    _render_nodes(nodes, facts, None, False, out)
    return "".join(out.parts)
