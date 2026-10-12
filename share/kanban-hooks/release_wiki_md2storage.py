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
from typing import List, Optional, Tuple

__all__ = ["md_to_storage"]

_COMMENT_RE = re.compile(r"^[ \t]*<!--.*?-->[ \t]*$", re.DOTALL | re.MULTILINE)
_CTRL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")
_FENCE_RE = re.compile(r"^\s*```\s*([\w+#.-]*)\s*$")
_HEADING_RE = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$")
_HR_RE = re.compile(r"^\s{0,3}(?:-{3,}|\*{3,}|_{3,})\s*$")
_LIST_RE = re.compile(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$")
_IMG_LINE_RE = re.compile(r"^\s*!\[([^\]]*)\]\(\s*([^()\s]+)\s*\)\s*$")
_TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$")
_BR_RE = re.compile(r"<br\s*/?>", re.IGNORECASE)
_NUM_ITEM_RE = re.compile(r"^\s*\d+[.)]\s+(.*)$", re.DOTALL)
_BUL_ITEM_RE = re.compile(r"^\s*[-*+]\s+(.*)$", re.DOTALL)

_CODE_RE = re.compile(r"(?<!`)(`{1,3})(?!`)(.+?)(?<!`)\1(?!`)")  # bounded run: no backtracking blow-up on long ``` lines
_IMG_RE = re.compile(r"!\[([^\]]*)\]\(\s*([^()\s]+)\s*\)")
_LINK_RE = re.compile(
    r"\[((?:[^\[\]\\]|\\.)*)\]\(\s*"
    r"([^()\s]+(?:\([^()\s]*\)[^()\s]*)*)(?:\s+\"[^\"]*\")?\s*\)"
)
_URL_RE = re.compile(r"https?://[^\s<>\"'`\x00]+")
_BOLD_RE = re.compile(r"\*\*(?=\S)(.+?)(?<=\S)\*\*|(?<!\w)__(?=\S)(.+?)(?<=\S)__(?!\w)")
_ITAL_RE = re.compile(
    r"(?<![\w*])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\w*])|(?<!\w)_(?=[^\s_])(.+?)(?<=[^\s_])_(?!\w)"
)
_PH_RE = re.compile("\x00(\\d+)\x00")
_SAFE_SCHEME_RE = re.compile(r"^(?:https?|mailto):", re.IGNORECASE)
_ANY_SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


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


def _inline(text: str, autolink: bool = True) -> str:
    """Render inline markdown. Complete elements are parked in placeholders so
    emphasis processing can never cut through them or through attributes."""
    store: List[str] = []

    def park(html: str) -> str:
        store.append(html)
        return "\x00%d\x00" % (len(store) - 1)

    def code(m):
        return park("<code>%s</code>" % _esc(m.group(2).strip("\n")))

    def img(m):
        out = _image_xml(m.group(1), m.group(2))
        return park(out) if out is not None else park(_esc(m.group(1)))

    def link(m):
        label = _inline(m.group(1).replace("\\[", "[").replace("\\]", "]"), autolink=False)
        url = m.group(2)
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
    s = _IMG_RE.sub(img, s)
    s = _LINK_RE.sub(link, s)
    s = _BR_RE.sub(lambda m: park("<br />"), s)
    if autolink:  # never nest an <a> inside a link label
        s = _URL_RE.sub(url, s)
    s = _esc(s)
    s = _BOLD_RE.sub(lambda m: "<strong>%s</strong>" % (m.group(1) or m.group(2)), s)
    s = _ITAL_RE.sub(lambda m: "<em>%s</em>" % (m.group(1) or m.group(2)), s)
    # Restore (placeholders may be nested inside each other's already-final
    # html only via link labels, which were rendered before parking).
    return _PH_RE.sub(lambda m: store[int(m.group(1))], s)


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


def _table(rows: List[List[str]], kv: bool) -> str:
    ncols = len(rows[0])
    width = max(len(r) for r in rows)
    rows = [r + [""] * (width - len(r)) for r in rows]
    out = ["<table><tbody>"]
    if kv and ncols == 2 and width == 2:
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


def md_to_storage(text: str, *, kv_two_column: bool = True,
                  drop_leading_h1: bool = False) -> str:
    """Convert the CR/Testing-Log markdown subset to Confluence storage XHTML.

    Empty / whitespace-only input returns "". Whole-line HTML comments
    (`<!-- ... -->`, possibly multi-line, as in the seed templates) are dropped. With drop_leading_h1 the first
    line is dropped only when it is the first non-blank line and is a
    single-`#` heading. A 2-column pipe table is a LABEL/VALUE table when
    kv_two_column (every row is data: first cell <th>, second <td>).
    """
    text = (text or "").lstrip("\ufeff")  # a leading BOM would hide the first heading
    text = _CTRL_RE.sub("", text.replace("\r\n", "\n").replace("\r", "\n"))
    text = _COMMENT_RE.sub("", text)  # block-level HTML comments (template notes)
    lines = text.expandtabs(4).split("\n")
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
        ln = lines[i]
        if not ln.strip():
            i += 1
            continue

        m = _FENCE_RE.match(ln)
        if m:
            lang, body = m.group(1), []
            i += 1
            while i < n and not re.match(r"^\s*```\s*$", lines[i]):
                body.append(lines[i])
                i += 1
            i += 1  # closing fence (or EOF)
            param = ('<ac:parameter ac:name="language">%s</ac:parameter>' % _esc(lang)) if lang else ""
            cdata = "\n".join(body).replace("]]>", "]]]]><![CDATA[>")
            out.append('<ac:structured-macro ac:name="code">%s<ac:plain-text-body>'
                       "<![CDATA[%s]]></ac:plain-text-body></ac:structured-macro>" % (param, cdata))
            continue

        m = _HEADING_RE.match(ln)
        if m:
            lvl = len(m.group(1))
            out.append("<h%d>%s</h%d>" % (lvl, _inline(m.group(2)), lvl))
            i += 1
            continue

        if _is_table_start(lines, i):
            rows = [_split_row(ln)]
            i += 2
            while i < n and lines[i].lstrip().startswith("|"):
                rows.append(_split_row(lines[i]))
                i += 1
            out.append(_table(rows, kv_two_column))
            continue

        if _HR_RE.match(ln):
            out.append("<hr />")
            i += 1
            continue

        m = _IMG_LINE_RE.match(ln)
        if m:
            img = _image_xml(m.group(1), m.group(2))
            out.append("<p>%s</p>" % (img if img is not None else _esc(m.group(1))))
            i += 1
            continue

        if _LIST_RE.match(ln):
            i = _list(lines, i, out)
            continue

        para = [ln.strip()]
        i += 1
        while i < n and lines[i].strip() and not _starts_block(lines, i):
            para.append(lines[i].strip())
            i += 1
        out.append("<p>%s</p>" % _inline(" ".join(para)))

    return "\n".join(out)


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
