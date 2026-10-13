"""Markdown -> Confluence storage-format (XHTML) converter (XACA-1509-001).

kb-wiki sends --body-file to Confluence as representation=storage, but the CR
and Testing Log templates are written in markdown, so raw `#`, `**` and `|`
text used to land in a single <p>. This module is the pure converter; the
caller (release_wiki*/kb-wiki) decides when to apply it.

Pure and deterministic: no I/O, no global state. stdlib only, Python 3.9-safe.

Public contract (do not change; callers import exactly this):

    md_to_storage(text, *, kv_two_column=True, drop_leading_h1=False) -> str

Security / well-formedness: every text run is XML-escaped, the only raw markup
passed through is <br> (emitted as <br />), link/image targets are limited to
http(s)/mailto/relative, and no HTML named entities are ever produced, so the
output parses as XML once wrapped in a root declaring the ac:/ri: namespaces.
"""
from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
from typing import List, Optional, Tuple

__all__ = ["md_to_storage", "leading_h1_text"]

# HTML comments are stripped by _strip_comments (a str.find scan, not a regex):
# a comment ends at the FIRST "-->" after its "<!--" exactly as in HTML, so text
# after it is never swallowed (XACA-1509-014) and a nested "<!--" stays inside
# the comment (XACA-1509-020). Linear time: once no "-->" follows an opener, no
# later opener can close either, so the scan stops (XACA-1509 round 2).
# The "never cross your own opener" rule bounds the emphasis/image scans.
# Anything that is not a legal XML 1.0 Char (this also drops lone surrogates,
# U+FFFE and U+FFFF). Tab/LF/CR survive; CR is normalised before this runs.
_CTRL_RE = re.compile("[^\x09\x0a\x0d\x20-\ud7ff\ue000-\ufffd\U00010000-\U0010ffff]")
_FENCE_RE = re.compile(r"^\s*```\s*([\w+#.-]*)\s*$")
_FENCE_CLOSE_RE = re.compile(r"^\s*```\s*$")
_HEADING_RE = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$")
_HR_RE = re.compile(r"^\s{0,3}(?:-{3,}|\*{3,}|_{3,})\s*$")
_LIST_RE = re.compile(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$")
_IMG_LINE_RE = re.compile(r"^\s*!\[([^\]]*)\]\(\s*([^()\s]+)\s*\)\s*$")
_TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$")
_BR_RE = re.compile(r"<br\s*/?>", re.IGNORECASE)
_NUM_ITEM_RE = re.compile(r"^\s*\d+[.)]\s+(.*)$", re.DOTALL)
_BUL_ITEM_RE = re.compile(r"^\s*[-*+]\s+(.*)$", re.DOTALL)

_CODE_RE = re.compile(r"(?<!`)(`{1,3})(?!`)(.+?)(?<!`)\1(?!`)")  # bounded run: no backtracking blow-up on long ``` lines
_IMG_RE = re.compile(r"!\[([^\[\]]*)\]\(\s*([^()\s]+)\s*\)")
# Links are scanned by _sub_links (label, then tail) rather than by one regex:
# as a single pattern the label body re-scanned to end-of-line from every
# unclosed "[" preceded by escaped brackets -> quadratic (XACA-1523-001).
_LINK_LABEL_RE = re.compile(r"\[((?:[^\[\]\\]|\\.)*)")
_LINK_TAIL_RE = re.compile(
    r"\]\(\s*([^()\s]+(?:\([^()\s]*\)[^()\s]*)*)(?:\s+\"[^\"]*\")?\s*\)"
)
_URL_RE = re.compile(r"https?://[^\s<>\"'`\x00]+")
_BOLD_RE = re.compile(r"\*\*(?=\S)((?:(?!\*\*).)+?)(?<=\S)\*\*|(?<!\w)__(?=\S)((?:(?!__).)+?)(?<=\S)__(?!\w)")
_ITAL_RE = re.compile(
    r"(?<![\w*])\*(?=[^\s*])((?:[^*]|\*\*)+?)(?<=[^\s*])\*(?![\w*])|(?<!\w)_(?=[^\s_])((?:[^_]|__)+?)(?<=[^\s_])_(?!\w)"
)
_EMPH_RE = re.compile(_BOLD_RE.pattern + "|" + _ITAL_RE.pattern)
_PH_RE = re.compile("\x00(\\d+)\x00")
_SAFE_SCHEME_RE = re.compile(r"^(?:https?|mailto):", re.IGNORECASE)
_ANY_SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


def _sub_links(s: str, repl) -> str:
    """Replace every `[label](url)` with repl(label, url), in linear time.
    The label body is deterministic (it ends at the first unescaped bracket), so
    when a label fails to close into a link, every later "[" inside that body
    (necessarily an escaped one) would end at the same place and fail the same
    way: resume at the body's end instead of re-scanning it (XACA-1523-001)."""
    out: List[str] = []
    last = i = 0
    while True:
        m = _LINK_LABEL_RE.search(s, i)
        if not m:
            break
        e = m.end()
        t = _LINK_TAIL_RE.match(s, e)
        if t:
            out.append(s[last:m.start()])
            out.append(repl(m.group(1), t.group(1)))
            last = i = t.end()
        else:
            i = e + 1 if s.startswith("]", e) else e
    out.append(s[last:])
    return "".join(out)


def _esc(s: str) -> str:
    """Escape for XML text and double-quoted attribute values."""
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;"))


def _safe_target(url: str) -> bool:
    """http(s)/mailto/relative only; anything else with a scheme is rejected."""
    if _SAFE_SCHEME_RE.match(url):
        return True
    # Relative: no scheme, and no embedded whitespace/control tricks.
    return not _ANY_SCHEME_RE.match(url) and not url.lstrip().lower().startswith(("//",))


def _is_http(url: str) -> bool:
    return bool(re.match(r"^https?://", url, re.IGNORECASE))


def _image_xml(alt: str, target: str) -> Optional[str]:
    if not _safe_target(target):
        return None
    if _is_http(target):
        ref = '<ri:url ri:value="%s" />' % _esc(target)
    else:
        name = target.split("#")[0].split("?")[0].rstrip("/").split("/")[-1]
        if not name:
            return None
        ref = '<ri:attachment ri:filename="%s" />' % _esc(name)
    return '<ac:image ac:alt="%s">%s</ac:image>' % (_esc(alt), ref)


def _restore(s: str, store: List[Tuple[str, str]]) -> str:
    """Substitute placeholders back. Parked html may itself hold placeholders
    (a link label), so repeat; an unknown index yields "" and never raises."""
    def sub(m):
        k = int(m.group(1))
        return store[k][0] if k < len(store) else ""
    for _ in range(8):
        if "\x00" not in s:
            break
        s = _PH_RE.sub(sub, s)
    return _PH_RE.sub("", s)


def _plain(s: str, store: List[Tuple[str, str]]) -> str:
    """Placeholder-free plain text, for use inside XML attribute values."""
    def sub(m):
        k = int(m.group(1))
        return store[k][1] if k < len(store) else ""
    return _PH_RE.sub(sub, s)


def _strip_comments(text: str) -> str:
    """Remove inline HTML comments, keeping the surrounding text. A comment ends
    at the FIRST "-->"; an unclosed one is left visible (never drop text)."""
    out, pos = [], 0
    while True:
        i = text.find("<!--", pos)
        if i < 0:
            break
        j = text.find("-->", i + 4)
        if j < 0:
            break  # and no later opener can close either: linear
        out.append(text[pos:i])
        pos = j + 3
    out.append(text[pos:])
    return "".join(out)

def _emph(s: str) -> str:
    """Bold/italic in ONE left-to-right pass. re.sub matches never overlap and
    each match's inner text is rendered recursively, so the emitted tags are
    balanced by construction (XACA-1509-013)."""
    def rep(m):
        tag = "strong" if (m.group(1) or m.group(2)) else "em"
        inner = m.group(1) or m.group(2) or m.group(3) or m.group(4)
        return "<%s>%s</%s>" % (tag, _emph(inner), tag)
    return _EMPH_RE.sub(rep, s)


def _inline(text: str, autolink: bool = True,
            store: Optional[List[Tuple[str, str]]] = None) -> str:
    """Render inline markdown. Complete elements are parked in placeholders so
    emphasis processing can never cut through them or through attributes.

    ONE store is shared through the whole recursion (link labels are rendered
    by a nested call); only the outermost call restores placeholders
    (XACA-1509-012). Store entries are (html, plain-text) pairs."""
    top = store is None
    if store is None:
        store = []

    def park(html: str, plain: str = "") -> str:
        store.append((html, plain))
        return "\x00%d\x00" % (len(store) - 1)

    def code(m):
        body = m.group(2).strip("\n")
        return park("<code>%s</code>" % _esc(body), body)

    def img(m):
        alt = _plain(m.group(1), store)
        out = _image_xml(alt, _plain(m.group(2), store))
        return park(out) if out is not None else park(_esc(alt), alt)

    def link(raw_label, raw_url):
        label = _inline(raw_label.replace("\\[", "[").replace("\\]", "]"),
                        autolink=False, store=store)
        url = _plain(raw_url, store)
        if not _safe_target(url):
            return park(label)
        return park('<a href="%s">%s</a>' % (_esc(url), label))

    def url(m):
        raw = m.group(0)
        # Trailing punctuation belongs to the sentence/table, not the URL.
        while raw and raw[-1] in ".,;:!?|*_]'":
            raw = raw[:-1]
        while raw.endswith(")") and raw.count(")") > raw.count("("):
            raw = raw[:-1]
            while raw and raw[-1] in ".,;:!?|*_]'":
                raw = raw[:-1]
        tail = m.group(0)[len(raw):]
        if len(raw) <= len("https://"):
            return m.group(0)
        return park('<a href="%s">%s</a>' % (_esc(raw), _esc(raw))) + tail

    s = _CODE_RE.sub(code, text)
    stripped = _strip_comments(s)  # code spans are parked: they keep "<!--"
    if stripped != s:
        s = stripped.strip()
    s = _IMG_RE.sub(img, s)
    s = _sub_links(s, link)
    s = _BR_RE.sub(lambda m: park("<br />", " "), s)
    if autolink:  # never nest an <a> inside a link label
        s = _URL_RE.sub(url, s)
    s = _emph(_esc(s))
    return _restore(s, store) if top else s


# ------------------------------------------------------------------ tables

def _split_row(line: str) -> List[str]:
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    cells: List[str] = []
    cur: List[str] = []
    i = 0
    in_code = False
    while i < len(s):
        ch = s[i]
        if ch == "\\" and i + 1 < len(s) and s[i + 1] == "|":
            cur.append("|")
            i += 2
            continue
        if ch == "`":
            in_code = not in_code
        if ch == "|" and not in_code:
            cells.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
        i += 1
    tail = "".join(cur).strip()
    if tail or not s.rstrip().endswith("|"):
        cells.append(tail)
    return cells


def _cell(content: str) -> str:
    parts = _BR_RE.split(content)
    if len(parts) >= 2:
        for rx, tag in ((_NUM_ITEM_RE, "ol"), (_BUL_ITEM_RE, "ul")):
            ms = [rx.match(p) for p in parts]
            if all(ms):
                return "<%s>%s</%s>" % (
                    tag, "".join("<li>%s</li>" % _inline(m.group(1).strip()) for m in ms), tag)
    return _inline(content)


# A 2-column label/value table's first row is data (`| Subject: | ... |`), except
# when it is one of these generic column-label pairs (`| Field | Value |`).
_KV_HEADER_PAIRS = frozenset(
    [(k, "value") for k in ("field", "key", "name", "property", "item", "setting")]
    + [("area", "impact")])


def _is_kv_header(row: List[str]) -> bool:
    return tuple(c.strip().strip("*_").strip().rstrip(":").strip().lower() for c in row) in _KV_HEADER_PAIRS


def _table(rows: List[List[str]], kv: bool) -> str:
    ncols = len(rows[0])
    width = max(len(r) for r in rows)
    rows = [r + [""] * (width - len(r)) for r in rows]
    out = ["<table><tbody>"]
    if kv and ncols == 2 and width == 2:
        if _is_kv_header(rows[0]):
            out.append("<tr><th>%s</th><th>%s</th></tr>" % (_cell(rows[0][0]), _cell(rows[0][1])))
            rows = rows[1:]
        for r in rows:
            out.append("<tr><th>%s</th><td>%s</td></tr>" % (_cell(r[0]), _cell(r[1])))
    else:
        out.append("<tr>%s</tr>" % "".join("<th>%s</th>" % _cell(c) for c in rows[0]))
        for r in rows[1:]:
            out.append("<tr>%s</tr>" % "".join("<td>%s</td>" % _cell(c) for c in r))
    out.append("</tbody></table>")
    return "".join(out)


# ------------------------------------------------------------------- main

def _is_table_start(lines: List[str], i: int) -> bool:
    return (lines[i].lstrip().startswith("|") and i + 1 < len(lines)
            and "-" in lines[i + 1] and bool(_TABLE_SEP_RE.match(lines[i + 1]))
            and "|" in lines[i + 1])


def _starts_block(lines: List[str], i: int) -> bool:
    ln = lines[i]
    return bool(_FENCE_RE.match(ln) or _HEADING_RE.match(ln) or _HR_RE.match(ln)
                or _LIST_RE.match(ln) or _IMG_LINE_RE.match(ln) or _is_table_start(lines, i))


def _prep(text: str) -> List[str]:
    text = (text or "").lstrip("\ufeff")  # a leading BOM would hide the first heading
    text = _CTRL_RE.sub("", text.replace("\r\n", "\n").replace("\r", "\n"))
    return [ln.expandtabs(4) for ln in _strip_block_comments(text.split("\n"))]


def _strip_block_comments(lines: List[str]) -> List[str]:
    """Drop block-level HTML comments (template notes) in ONE left-to-right scan
    that tracks comments and fences together, so whichever opens first wins, as
    in CommonMark (XACA-1509-021/-022/-023):
      * a fence that opens first is literal to its closing fence (or EOF), so a
        "<!--" inside it is kept;
      * a "<!--" that opens a line (only blanks before it) hides everything up to
        its FIRST "-->", fence lines included. Text after the "-->" stays on that
        line (never swallowed, XACA-1509-014); a comment owning whole lines
        leaves one blank line;
      * an unclosed comment stays visible and later fences still render. Once a
        "-->" search fails none can succeed later, so the scan stays linear.
    Comments that open mid-line are left for the inline pass."""
    out: List[str] = []
    i, n, no_close = 0, len(lines), False
    tbl = held = False  # inside a pipe table / a comment-owned blank is owed

    def add(x: str, nxt: Optional[str] = None) -> None:
        nonlocal tbl, held
        row = x.lstrip().startswith("|")
        # The comment really did separate blocks: a non-row follows, or the row
        # is the header of a NEW table (row + separator), which develop rendered
        # as a second table (XACA-1523 gate round 2).
        if held and (not row or (nxt is not None and _is_table_start([x, nxt], 0))):
            out.append("")
            tbl = False
        held = False
        # Same table notion as the renderer: a header row + separator (with or
        # without a leading "|") opens it, every following "|" line continues it.
        if tbl:
            tbl = row
        else:
            tbl = bool(out) and _is_table_start([out[-1], x], 0)
        out.append(x)

    while i < n:
        ln = lines[i]
        if _FENCE_RE.match(ln):
            add(ln)
            i += 1
            while i < n and not _FENCE_CLOSE_RE.match(lines[i]):
                out.append(lines[i])
                i += 1
            if i < n:
                out.append(lines[i])
                i += 1
            continue
        c = ln.find("<!--")
        if c < 0 or no_close or ln[:c].strip(" \t"):
            add(ln, lines[i + 1] if i + 1 < n else None)
            i += 1
            continue
        j, e = i, ln.find("-->", c + 4)
        while e < 0 and j + 1 < n:
            j += 1
            e = lines[j].find("-->")
        if e < 0:
            no_close = True
            add(ln, lines[i + 1] if i + 1 < n else None)
            i += 1
            continue
        rest = lines[j][e + 3:]
        if rest.strip(" \t"):
            lines[j] = rest  # re-scan the remainder: it may open another comment
            i = j
        else:
            if tbl:
                held = True  # a comment-only line inside a table is dropped; the
                # table goes on if a row follows (XACA-1523-002)
            else:
                add("")
            i = j + 1
    return out


def leading_h1_text(text: str) -> Optional[str]:
    """Text of the first non-blank line if it is a single-`#` heading (exactly
    what drop_leading_h1 would drop), else None."""
    for ln in _prep(text):
        if ln.strip():
            m = _HEADING_RE.match(ln)
            return m.group(2) if m and len(m.group(1)) == 1 else None
    return None


def md_to_storage(text: str, *, kv_two_column: bool = True,
                  drop_leading_h1: bool = False) -> str:
    """Convert the CR/Testing-Log markdown subset to Confluence storage XHTML.

    Empty / whitespace-only input returns "". Whole-line HTML comments
    (`<!-- ... -->`, possibly multi-line, as in the seed templates) are dropped;
    inline comments are stripped and the surrounding text kept. A comment never
    spans past its own first `-->`. Every block is verified well-formed and
    falls back to escaped plain text if not. With drop_leading_h1 the first
    line is dropped only when it is the first non-blank line and is a
    single-`#` heading. A 2-column pipe table is a LABEL/VALUE table when
    kv_two_column (every row is data: first cell <th>, second <td>).
    """
    lines = _prep(text)
    out: List[str] = []
    i, n = 0, len(lines)

    if drop_leading_h1:
        j = 0
        while j < n and not lines[j].strip():
            j += 1
        if j < n:
            m = _HEADING_RE.match(lines[j])
            if m and len(m.group(1)) == 1:
                i = j + 1

    while i < n:
        start, before = i, len(out)
        i = _block(lines, i, out, kv_two_column)
        if len(out) > before:
            _guard(out, before, lines[start:i])

    return "\n".join(out)


_ROOT_OPEN = '<r xmlns:ac="urn:xaca1509:ac" xmlns:ri="urn:xaca1509:ri">'


def _well_formed(html: str) -> bool:
    try:
        ET.fromstring(_ROOT_OPEN + html + "</r>")
        return True
    except ET.ParseError:
        return False


def _guard(out: List[str], before: int, raw_lines: List[str]) -> None:
    """Safety net (XACA-1509-013): a block that is not well-formed XML is
    replaced by its escaped plain source text. Never emit malformed storage."""
    if _well_formed("".join(out[before:])):
        return
    raw = " ".join(l.strip() for l in raw_lines if l.strip())
    out[before:] = ["<p>%s</p>" % _esc(raw)]


def _block(lines: List[str], i: int, out: List[str], kv_two_column: bool) -> int:
    """Render ONE block starting at lines[i] into out; return the next index."""
    n = len(lines)
    ln = lines[i]
    if not ln.strip():
        i += 1
        return i

    m = _FENCE_RE.match(ln)
    if m:
        lang, body = m.group(1), []
        i += 1
        while i < n and not _FENCE_CLOSE_RE.match(lines[i]):
            body.append(lines[i])
            i += 1
        i += 1  # closing fence (or EOF)
        param = ('<ac:parameter ac:name="language">%s</ac:parameter>' % _esc(lang)) if lang else ""
        cdata = "\n".join(body).replace("]]>", "]]]]><![CDATA[>")
        out.append('<ac:structured-macro ac:name="code">%s<ac:plain-text-body>'
                   "<![CDATA[%s]]></ac:plain-text-body></ac:structured-macro>" % (param, cdata))
        return i

    m = _HEADING_RE.match(ln)
    if m:
        lvl = len(m.group(1))
        out.append("<h%d>%s</h%d>" % (lvl, _inline(m.group(2)), lvl))
        i += 1
        return i

    if _is_table_start(lines, i):
        rows = [_split_row(ln)]
        i += 2
        while i < n and lines[i].lstrip().startswith("|"):
            rows.append(_split_row(lines[i]))
            i += 1
        out.append(_table(rows, kv_two_column))
        return i

    if _HR_RE.match(ln):
        out.append("<hr />")
        i += 1
        return i

    m = _IMG_LINE_RE.match(ln)
    if m:
        img = _image_xml(m.group(1), m.group(2))
        out.append("<p>%s</p>" % (img if img is not None else _esc(m.group(1))))
        i += 1
        return i

    if _LIST_RE.match(ln):
        i = _list(lines, i, out)
        return i

    para = [ln.strip()]
    i += 1
    while i < n and lines[i].strip() and not _starts_block(lines, i):
        para.append(lines[i].strip())
        i += 1
    out.append("<p>%s</p>" % _inline(" ".join(para)))

    return i


def _list(lines: List[str], i: int, out: List[str]) -> int:
    """Render consecutive list items starting at lines[i]; return next index."""
    n = len(lines)
    html: List[str] = []
    stack: List[Tuple[int, str]] = []  # (indent, tag); the top <li> stays open

    def close_top():
        _, tag = stack.pop()
        html.append("</li></%s>" % tag)

    while i < n:
        m = _LIST_RE.match(lines[i])
        if not m:
            if not lines[i].strip():
                # Blank line: a loose list continues only if the next
                # non-blank line is another list item.
                j = i
                while j < n and not lines[j].strip():
                    j += 1
                if j < n and _LIST_RE.match(lines[j]):
                    i = j
                    continue
                break
            if lines[i].startswith((" ", "\t")) and stack and not _starts_block(lines, i):
                html.append(" " + _inline(lines[i].strip()))  # continuation text
                i += 1
                continue
            break
        indent = len(m.group(1))
        tag = "ol" if m.group(2)[0].isdigit() else "ul"
        while stack and indent < stack[-1][0]:
            close_top()
        if stack and indent == stack[-1][0]:
            if tag != stack[-1][1]:
                close_top()
                stack.append((indent, tag))
                html.append("<%s><li>" % tag)
            else:
                html.append("</li><li>")
        elif stack and indent > stack[-1][0]:
            stack.append((indent, tag))
            html.append("<%s><li>" % tag)
        else:
            stack.append((indent, tag))
            html.append("<%s><li>" % tag)
        html.append(_inline(m.group(3).strip()))
        i += 1
    while stack:
        close_top()
    out.append("".join(html))
    return i


def _main(argv: List[str]) -> int:
    if not argv or len(argv) > 2 or argv[0] in ("-h", "--help"):
        sys.stderr.write("usage: release_wiki_md2storage.py IN [OUT]\n")
        return 2
    with open(argv[0], encoding="utf-8") as fh:
        res = md_to_storage(fh.read())
    if len(argv) == 2:
        with open(argv[1], "w", encoding="utf-8") as fh:
            fh.write(res + "\n")
    else:
        sys.stdout.write(res + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
