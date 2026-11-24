"""
orchestrator_contention.py -- file-contention predictor for the release orchestrator (XACA-1543-001).

Stdlib only, py3.9-safe, deterministic (every output is sorted). Reusable library + CLI: XACA-1286 (the overlap
check that cannot see in-flight siblings) can call the CLI. Read-only: it never writes a board or a plan doc.

PUBLIC API
  extract_paths(plan_text, description=None, repo_root=None, anchors=None) -> list[str]
  extract_paths_report(plan_text, description=None, repo_root=None, anchors=None) -> {"paths", "plan_paths", "unparsed"}
  find_plan_doc(item, kanban_dir, repo_root=None) -> str | None
  DEFAULT_HOTSPOTS
  load_hotspots(repo_root, config=None) -> list[str]
  predict(paths_by_item, hotspots=()) -> list[dict]          (low level; does NOT fail closed)
  predict_closed(reports_by_item, hotspots=()) -> {"conflicts", "no_paths", "unparsed"}  (THE fail-closed rule; plan() + CLI call it)

PATH EXTRACTION
  Sources: the plan doc's "Files to Modify" section and backticked tokens in the item description.
  Section detection: a "#" heading whose text contains one of SECTION_TITLES ("Files to Modify", "Files Changed",
  "Files to Create", "Affected Files", "Files Modified"), at any level (the section runs to the next
  heading of the same or a shallower level, so "New Files to Create" / "Existing Files to Modify" subsections are
  included), OR a bold pseudo-heading ("**Files to Modify:**" / "**Files to Modify**" / "**Files to Modify**:"), which
  runs to the next "#" heading or the next bold-only pseudo-heading that is not itself file-ish (title containing
  file / creat / modif / new / exist). Text after a bold pseudo-heading on the same line counts as section text.
  In the section, a table row contributes the path-like tokens of ANY column (the path is not always column one); a
  bullet / numbered line contributes all its tokens. Backticked tokens are always taken; the UN-backticked remainder of a
  bullet / table cell / fenced-code line is scanned too, but only for words that are unmistakably files (_strict_plain_tokens: known
  extension, EXTENSIONLESS_FILES such as Makefile / Dockerfile, a bare root script name like "kanban-helpers", or a dotted
  file under a real top-level dir), so "- `a.py` and kanban-helpers.sh" and a plain table column both count while "read/write",
  "and/or", "Node.js" and "finance/legal/medical" do not (XACA-1543-021). Lines inside ``` / ~~~ fences within the section are
  candidates too and are never read as headings. Path-like globs / absolute paths found this way land in `unparsed`.
  Plain prose lines contribute nothing.
  Normalisation: backticks stripped, a comma/space separated list inside one pair of backticks is split into
  tokens, leading "./" removed, "//" collapsed, trailing line refs removed (":123", ":12-30", ":~123", "#L12",
  "#L12-L30", "(~:123)"). A token must be path-like: contain "/" or end in a known file extension (_EXTS).
  Repo-absolute prefixes are RE-ANCHORED to repo-relative first (REPO_ANCHOR_PATTERNS: "~/dev-team/",
  "$HOME/dev-team/", "/Users/<u>/dev-team/", any absolute ".../dev-team/" incl. "/Users/Shared/Development/...",
  ".../dev-team/worktrees/<name>/", and the installed "~/aiteamforge/", whose layout mirrors repo-relative paths:
  kanban-helpers.sh, kanban-hooks/...), plus the repo_root abspath/realpath and any `anchors` given. URLs are dropped.

FAIL CLOSED (XACA-1543 QA round)
  A path the extractor cannot parse must never read as "conflicts with nothing". extract_paths_report() returns,
  besides the paths, the `unparsed` tokens: path-like tokens that were dropped, i.e. an absolute / "~" / "$VAR" FILE path (known extension) no
  anchor resolves ("~/knowledge/x.md", "/opt/x/y.py") and path-like globs / templates ("kanban-hooks/*.py",
  "changelog.d/<ITEM-ID>.md"). A glob names no concrete file so it is still not a path, but it is reported so a
  glob-only section is visible. URLs and code such as "foo()" are not reported.
  The release planner treats a candidate with ZERO paths (no section at all, prose-only paths, glob-only section,
  unparseable list) as conflicting with every other candidate and warns NO_PATHS; one with unparsed tokens warns
  UNPARSED_PATHS. WHY serialise (option b) rather than refuse with a NO_FILE_SET code (the reviewer's option a): both
  are fail-closed, but serialising keeps the item runnable (alone in its wave) without forcing a plan-doc edit,
  whereas a refusal would block it. Option (a) is the REJECTED alternative.

GLOB / TEMPLATE DECISION
  Tokens containing glob or template characters (* ? [ ] { } < >) are DROPPED from `paths` (and listed in `unparsed`), e.g.
  "tests/test-xaca-15xx-*.{sh,py}" or "changelog.d/<ITEM-ID>.md". A glob names no concrete file, and per-item
  templates are unique by construction, so neither can be an exact-match conflict; keeping them would only
  manufacture false conflicts (or, worse, a glob "matching" a sibling's real file). predict() therefore never sees one.

HOTSPOTS
  A hotspot is a shared serialization point, not a file two items must both name. Two items conflict on a hotspot
  when each touches ANY path matching it. An entry ending in "/" is a directory prefix (matches everything under
  it); any other entry matches that exact path. load_hotspots() = DEFAULT_HOTSPOTS + the canonical sources that
  sync-tap.sh mirrors to the tap (parsed statically from its sync_file / sync_dir calls) + optional config entries.
  sync-tap.sh PARSE: a line "sync_file|sync_dir \"$SOURCE_DIR/<path>\" ..." (leading whitespace only; comment lines
  never match). A literal path is used as is (sync_dir -> directory prefix). A path containing a shell variable
  ("scripts/ci-runner/${f}") contributes its literal directory prefix; a sync_file prefix with fewer than two
  segments is skipped as too broad. The `find ... | while read` loop that mirrors every kanban-hooks/*.py is NOT
  turned into a hotspot: it is a pattern, not a path list, and would serialize all Python hook work. If sync-tap.sh
  is missing or unreadable the defaults are used; it never raises.

find_plan_doc RESOLUTION (mirrors kanban-helpers.sh _kb_pick_plan_doc, XACA-0478)
  Search <kanban_dir>/plans/<ID>/ first, then the flat <kanban_dir>/ ; match "<ID>_*.md" (not *_RETROSPECTIVE.md);
  prefer files carrying '<!-- plan_doc: canonical -->', then the lexicographically first. A subitem id
  (XACA-1543-001) resolves through its parent (XACA-1543). item may be an item dict or an id string. Returns an
  absolute path or None. repo_root is accepted for API symmetry and used only to resolve a relative kanban_dir.

CLI
  orchestrator_contention.py paths   --kanban-dir D --item ID [--json]
  orchestrator_contention.py predict --kanban-dir D --items ID1,ID2,... [--repo-root R] [--json]
  D holds <team>-board.json and plans/; a relative D is made absolute once in main().
  Exit codes (same in --help):
    0  every file set known, no conflicts
    1  conflicts found (synthetic "reason": "NO_PATHS" conflicts included)
    2  usage / error (bad args, missing dir, unknown item)
    3  an item's file set is UNKNOWN (plan doc yields no paths) and there is no conflict to report: a single-item predict,
       or `paths`. UNKNOWN is never clean. Unparsed tokens alone (known set + dropped glob/absolute token) do not change rc.
  predict --json prints {"conflicts": [...], "no_paths": [ids], "unparsed": {id: [tokens]}}; paths --json prints
  {"item","paths","unparsed","file_set_known"}. An item counts as NO_PATHS when its PLAN DOC yields no paths: description
  paths only add to a known set and never mask an empty plan doc; no plan doc at all (description only) is NO_PATHS.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys

DEFAULT_HOTSPOTS = (
    "kanban-helpers.sh",
    "scripts/templates/tap/kanban-helpers.template.sh",
    "claude/CLAUDE.md",
    "CHANGELOG.md",
)

_EXTS = frozenset((
    "py", "sh", "zsh", "bash", "md", "rst", "txt", "json", "yml", "yaml", "toml", "ini", "cfg", "plist",
    "js", "mjs", "ts", "css", "html", "htm", "swift", "kt", "java", "go", "rb", "sql", "lock", "conf", "env",
    "xml", "csv", "tsx", "jsx", "scss", "rs", "svg", "gradle", "kts",
))
# Extensionless / dotfile names that are files, not words (XACA-1543-021). Case-sensitive on purpose: "License" is prose.
EXTENSIONLESS_FILES = frozenset((
    "Makefile", "Dockerfile", "Brewfile", "Gemfile", "Procfile", "LICENSE", "VERSION", "Rakefile", "Podfile", "Fastfile",
    "Vagrantfile", "Jenkinsfile", "Justfile", "CODEOWNERS", ".gitignore", ".gitattributes", ".gitmodules",
    ".editorconfig", ".dockerignore", ".nvmrc",
))
# Product names that look like "<word>.<known ext>" but are prose.
_PROSE_DOTTED = frozenset(("node.js", "vue.js", "next.js", "react.js", "express.js", "d3.js", "three.js", "chart.js",
                           "alpine.js", "nuxt.js", "socket.io"))
_PLAIN_WRAP = "()[]\"'<>,;"
_BARE_RE = re.compile(r"^[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)+$")
_BACKTICK_RE = re.compile(r"`([^`\n]+)`")
_HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
_BULLET_RE = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+")
_TEMPLATE_CHARS = set("*?[]{}<>")
_LINEREF_PAREN_RE = re.compile(r"\s*\(~?:?[\d,\-–~]+\)\s*$")
_LINEREF_COLON_RE = re.compile(r":~?[\d,\-–~]+$")
_LINEREF_HASH_RE = re.compile(r"#L?\d+(?:[-–]L?\d+)?$")
_SYNC_RE = re.compile(r'^\s*sync_(file|dir)\s+"\$(?:\{SOURCE_DIR\}|SOURCE_DIR)/([^"]+)"')
_SPLIT_RE = re.compile(r"(?<!\\)\|")
_LIST_SPLIT_RE = re.compile(r"[,\s]+")
_BOLD_RE = re.compile(r"^\s*(?:[-*+]\s+)?\*\*(.+?)\*\*\s*:?\s*(.*)$")
_FILEISH = ("file", "creat", "modif", "new", "exist", "affected", "changed")
SECTION_TITLES = ("files to modify", "files changed", "files to create", "affected files", "files modified")

# Repo-absolute prefixes re-anchored to repo-relative (first match wins, applied only to "/", "~", "$" tokens).
# Order matters: worktree checkouts before the generic dev-team segment.
REPO_ANCHOR_PATTERNS = (
    r"^[^\s]*?/dev-team/worktrees/[^/]+/",
    r"^(?:~|\$HOME|\$\{HOME\}|/Users/[^/]+|/home/[^/]+)/(?:dev-team|aiteamforge)/",
    r"^/[^\s]*?/dev-team/",
    r"^/[^\s]*?/worktrees/[^/]+/",   # XACA-1938: a worktree of a checkout at ANY path (not only ".../dev-team/")
)
_ANCHOR_RES = tuple(re.compile(p) for p in REPO_ANCHOR_PATTERNS)
# After a root prefix is stripped, "worktrees/<name>/F" is still F in a worktree of that root (XACA-1938).
_WORKTREE_RESIDUE_RE = re.compile(r"^worktrees/[^/]+/")


def _strip_worktree_residue(t):
    while True:
        m = _WORKTREE_RESIDUE_RE.match(t)
        if not m or len(t) <= m.end():
            return t
        t = t[m.end():]


def _reanchor(t, literal_prefixes=()):
    """Strip the first matching repo-absolute prefix, then any "worktrees/<name>/" left under that root; return t
    unchanged if none matches or nothing would remain. The residue strip applies ONLY after an anchor matched, so a
    plain repo-relative "worktrees/..." token is never rewritten."""
    for pre in literal_prefixes:
        if pre and t.startswith(pre) and len(t) > len(pre):
            return _strip_worktree_residue(t[len(pre):])
    for rx in _ANCHOR_RES:
        m = rx.match(t)
        if m and len(t) > m.end():
            return _strip_worktree_residue(t[m.end():])
    return t


def _literal_prefixes(repo_root, anchors):
    out = set()
    for a in list(anchors or ()) + [repo_root]:
        if isinstance(a, str) and a.strip():
            a = a.strip()
            for v in {a, os.path.abspath(a), os.path.realpath(a)}:
                v = v.rstrip("/")
                out.add(v + "/")
                head, sep, tail = v.rpartition("/worktrees/")
                if (sep and head and tail and "/" not in tail
                        and os.path.isfile(os.path.join(v, ".git")) and os.path.exists(os.path.join(head, ".git"))):
                    # root is a REAL git worktree (.git file) of a checkout at head (.git present): that checkout
                    # anchors sibling worktrees too. A plain dir merely named "worktrees" anchors nothing extra.
                    out.add(head + "/")
    return sorted(out, key=lambda x: (-len(x), x))


def _strip_refs(t):
    t = t.strip().strip("`").strip()
    prev = None
    while prev != t:  # peel stacked suffixes: "a.py:12 (~:12)", "a.py#L3"
        prev = t
        t = _LINEREF_PAREN_RE.sub("", t)
        t = _LINEREF_COLON_RE.sub("", t)
        t = _LINEREF_HASH_RE.sub("", t)
    return t.strip().rstrip(".,;:")


def _classify(token, literal_prefixes=()):
    """-> (path|None, unparsed|None). `unparsed` is set only for a path-like token dropped for a non-deliberate reason."""
    if not isinstance(token, str):
        return None, None
    t = _strip_refs(token)
    if not t or any(c.isspace() for c in t) or "://" in t:
        return None, None
    if any(c in _TEMPLATE_CHARS for c in t):
        # glob / template: names no concrete file, but a path-like one is reported so it cannot hide an empty set
        if re.match(r"^\d*[<>]", t):
            return None, None   # shell redirection such as 2>/dev/null
        if ("/" in t or re.search(r"\.[A-Za-z*{]", t)) and "(" not in t and "=" not in t and not t.startswith(("<", "[", "{")):
            return None, t
        return None, None
    if t.startswith(("/", "~", "$")):
        t = _reanchor(t, literal_prefixes)
        if t.startswith(("/", "~", "$")):
            last = t.rstrip("/").rsplit("/", 1)[-1]
            ext = last.rpartition(".")[2].lower() if "." in last else ""
            if "/" in t.strip("/") and not t.endswith("/") and ext in _EXTS and "(" not in t and "=" not in t:
                return None, t   # absolute/~/$VAR FILE path no anchor resolves: cannot be judged repo-relative
                                 # (URL routes like "/api/x/" and directories are not file paths: not reported)
            return None, None
    if "$" in t or "(" in t or "=" in t:
        return None, None
    while t.startswith("./"):
        t = t[2:]
    t = re.sub(r"/{2,}", "/", t)
    if not t or t in (".", "..") or t.startswith("../"):
        return None, None
    base = t.rstrip("/").rsplit("/", 1)[-1]
    if "/" in t.rstrip("/"):
        return t, None
    if t.endswith("/"):
        return t, None  # top-level directory, e.g. "lcars-ui/"
    stem, dot, ext = base.rpartition(".")
    if dot and stem and ext.lower() in _EXTS:
        return t, None
    if base in EXTENSIONLESS_FILES:
        return t, None
    return None, None


def _normalize(token, literal_prefixes=()):
    """Normalise one candidate; return the path or None if it is not a concrete repo-relative path."""
    return _classify(token, literal_prefixes)[0]


def _split_list(tok):
    """Split on commas / whitespace that are OUTSIDE braces, so "tests/x-*.{sh,py}" stays one token."""
    parts, cur, depth = [], [], 0
    for ch in tok:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth = max(0, depth - 1)
        if depth == 0 and (ch == "," or ch.isspace()):
            if cur:
                parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    if cur:
        parts.append("".join(cur))
    return parts


def _tokens(text):
    """Backticked tokens; a comma/space separated list inside one pair of backticks yields one token per item."""
    out = []
    for m in _BACKTICK_RE.finditer(text):
        tok = _LINEREF_PAREN_RE.sub("", m.group(1).strip())
        out.extend(_split_list(tok))
    return out


def _section_items(plan_text):
    """(line, fenced) pairs inside the 'Files to Modify' section(s), subsections included (# headings or bold
    pseudo-headings). Fenced code lines are emitted with fenced=True and are NEVER read as headings (a "# comment" inside a
    fence must neither open nor close a section); the fence delimiter lines themselves are dropped."""
    out, level, bold, fence = [], None, False, None
    for line in plan_text.splitlines():
        ls = line.lstrip()
        if fence is None and (ls.startswith("```") or ls.startswith("~~~")):
            fence = ls[:3]
            continue
        if fence is not None:
            if ls.startswith(fence):
                fence = None
            elif level is not None:
                out.append((line, True))
            continue
        m = _HEADING_RE.match(line)
        if m:
            lvl = len(m.group(1))
            if bold:
                level, bold = None, False
            if level is not None and lvl <= level:
                level = None
            if level is None and any(k in m.group(2).lower() for k in SECTION_TITLES):
                level = lvl
            continue
        bm = _BOLD_RE.match(line)
        if bm:
            title, rest = bm.group(1), bm.group(2)
            if any(k in title.lower() for k in SECTION_TITLES):
                if level is None or bold:
                    level, bold = 7, True
                if rest.strip():
                    out.append((rest, False))
                continue
            if bold and not rest.strip() and not any(k in title.lower() for k in _FILEISH):
                level, bold = None, False
                continue
        if level is not None:
            out.append((line, False))
    return out


def _section_lines(plan_text):
    """Non-fenced lines of the section(s); kept for callers that only want the prose-level structure."""
    return [ln for ln, fenced in _section_items(plan_text) if not fenced]


# PROCESS-GLOBAL cache of the checkout's top-level layout, keyed by repo_root. Fine for the one-shot CLI; a LONG-LIVED importer
# (e.g. XACA-1286) sees a stale view if top-level dirs change underneath it and must call clear_root_cache().
_ROOT_CACHE = {}


def clear_root_cache():
    """Drop the process-global _ROOT_CACHE (for long-lived importers; the CLI never needs it)."""
    _ROOT_CACHE.clear()


def _root_facts(repo_root):
    """(top-level directory names, {bare stem: filename}) of repo_root UNION the checkout containing this module. Used only to
    recognise un-backticked paths ("kanban-hooks/x" under a real top dir) and bare script names ("kanban-helpers" ->
    kanban-helpers.sh when exactly one root file has that stem). Never raises. Results are cached in the process-global
    _ROOT_CACHE (see clear_root_cache)."""
    key = repo_root if isinstance(repo_root, str) else None
    if key in _ROOT_CACHE:
        return _ROOT_CACHE[key]
    dirs, stems, dup = set(), {}, set()
    for root in {r for r in (key, default_repo_root()) if r}:
        try:
            names = sorted(os.listdir(root))
        except OSError:
            continue
        for n in names:
            if n.startswith("."):
                continue
            full = os.path.join(root, n)
            if os.path.isdir(full):
                dirs.add(n)
                continue
            stem, dot, ext = n.rpartition(".")
            if dot and stem and ext.lower() in _EXTS:
                if stem in stems and stems[stem] != n:
                    dup.add(stem)
                stems[stem] = n
    for d in dup:
        stems.pop(d, None)
    _ROOT_CACHE[key] = (frozenset(dirs), stems)
    return _ROOT_CACHE[key]


def _resolve_bare(tok, stems):
    """A hyphen/underscore bare name with no extension ("kanban-helpers") -> the unique root file it names, else None."""
    return stems.get(tok) if isinstance(tok, str) and _BARE_RE.match(tok) else None


_WORD_SEG_RE = re.compile(r"^[a-z]+$")
_PATHLIKE_SEG_RE = re.compile(r"^[\w.@+\-]+$")
_PATHLIKE_EXT_RE = re.compile(r"\.[A-Za-z][A-Za-z0-9]{1,7}$")


def _exists_under(rel, repo_root):
    for root in {r for r in (repo_root if isinstance(repo_root, str) else None, default_repo_root()) if r}:
        if os.path.exists(os.path.join(root, rel.rstrip("/"))):
            return True
    return False


def _strict_plain_tokens(text, dirs, stems, lead=False, unparsed=None, repo_root=None):
    """Path-like words of PROSE-ish text (the un-backticked remainder of a mixed bullet, a non-first table cell, a fenced
    line, a plain bullet). A word counts as a path, in ANY position, when it is (a) a known-extension file, (b) an
    extensionless-file name, (c) a bare root script ("kanban-helpers"), or (d) has 2+ segments or a trailing "/" AND its first
    segment is a real top-level directory of the checkout (`dirs`): "scripts/kb-pr-monitor", "homebrew-tap/",
    "kanban-hooks/foo_dir/". Trailing punctuation is stripped first. A path-like token whose first segment is NOT a real
    directory but which has a "/" plus an extension ("nowhere/x.xyz") is added to the `unparsed` set (if given) rather than
    dropped. Slash lists of plain words whose first segment is not a real dir ("read/write", "and/or", "4/4") are prose and yield
    nothing. Because team names double as top-level dirs here ("finance/legal/medical", "docs/"), an all-lowercase-word token
    with no extension is only accepted when it exists on disk. `lead` is retained for callers but no longer narrows
    anything: position does not matter. NOTE: `dirs` comes from the process-global _ROOT_CACHE (see clear_root_cache)."""
    out = []
    for w in text.replace("**", "").split():
        w = w.strip(_PLAIN_WRAP)
        if "::" in w:
            w = w.split("::", 1)[0]
        if not w or "://" in w:
            continue
        core = _strip_refs(w)
        if not core or core.lower() in _PROSE_DOTTED:
            continue
        if core in EXTENSIONLESS_FILES:
            out.append(core)
            continue
        segs = [x for x in core.rstrip("/").split("/") if x]
        last = segs[-1] if segs else ""
        ext = last.rpartition(".")[2].lower() if "." in last[1:] else ""
        if "/" in core:
            if any(c in _TEMPLATE_CHARS for c in core):
                if re.search(r"\.[A-Za-z*{]", last):
                    out.append(core)          # path-like glob: _classify reports it as unparsed
            elif ext in _EXTS:
                out.append(core)
            elif segs and segs[0] in dirs and (len(segs) >= 2 or core.endswith("/")):
                word_list = not ext and all(_WORD_SEG_RE.match(x) for x in segs)
                if not word_list or _exists_under(core, repo_root):
                    out.append(core)
                elif unparsed is not None:
                    # A word-only path under a real top dir that is not on disk (a file/dir the plan will CREATE,
                    # e.g. scripts/release, docs/academy/) is UNKNOWN, not absent: always report it (UNPARSED_PATHS),
                    # never drop it. No team-list exemption: prose like finance/legal/medical only costs a warning
                    # (warnings never serialize waves), whereas a silent drop co-schedules a real conflict.
                    unparsed.add(core)
            elif (unparsed is not None and segs and (len(segs) >= 2 or core.endswith("/"))
                  and segs[0].lower() in {d.lower() for d in dirs}):
                # Wrong-case real top dir (Scripts/release on a case-insensitive FS): unknown -> report, never drop.
                unparsed.add(core)
            elif (unparsed is not None and len(segs) >= 2 and all(_PATHLIKE_SEG_RE.match(x) for x in segs)
                  and _PATHLIKE_EXT_RE.search(last)):
                unparsed.add(core)
        elif ext in _EXTS and last.rpartition(".")[0]:
            out.append(core)
        else:
            res = _resolve_bare(core, stems)
            if res:
                out.append(res)
    return out


def extract_paths_report(plan_text, description=None, repo_root=None, anchors=None):
    """{"paths": all sorted repo-relative paths, "plan_paths": the subset found in the PLAN DOC alone, "unparsed": sorted
    path-like tokens dropped non-deliberately}. `plan_paths` decides whether the file set is KNOWN (see predict_closed):
    description paths only ADD to a known set, they never make an empty plan-doc extraction look known."""
    lit = _literal_prefixes(repo_root, anchors)
    found, unparsed, plan_found = set(), set(), set()

    def take(tokens, from_plan=False):
        for c in tokens:
            n, u = _classify(c, lit)
            if n:
                found.add(n)
                if from_plan:
                    plan_found.add(n)
            elif u:
                unparsed.add(u)

    if isinstance(plan_text, str) and plan_text:
        dirs, stems = _root_facts(repo_root)
        for line, fenced in _section_items(plan_text):
            stripped = line.strip()
            if fenced:
                toks = _strict_plain_tokens(re.sub(r"^(?:[$>]\s+|[-*+]\s+)", "", stripped), dirs, stems, unparsed=unparsed, repo_root=repo_root)
            elif stripped.startswith("|"):
                cells = _SPLIT_RE.split(stripped.strip("|"))
                toks = []
                for cell in cells:
                    toks.extend(_tokens(cell))
                    rest = _BACKTICK_RE.sub(" ", cell)
                    toks.extend(_strict_plain_tokens(rest, dirs, stems, unparsed=unparsed, repo_root=repo_root))
                first = cells[0] if cells else ""
                if not toks and "`" not in first:
                    toks = _strict_plain_tokens(first, dirs, stems, lead=True, unparsed=unparsed, repo_root=repo_root)
            elif _BULLET_RE.match(line):
                body = _BULLET_RE.sub("", line, count=1)
                toks = _tokens(line)
                if toks:
                    toks.extend(_strict_plain_tokens(_BACKTICK_RE.sub(" ", body), dirs, stems, unparsed=unparsed, repo_root=repo_root))
                else:
                    toks = _strict_plain_tokens(body, dirs, stems, lead=True, unparsed=unparsed, repo_root=repo_root)
            else:
                continue
            toks = [_resolve_bare(t, stems) or t for t in toks]
            take(toks, True)
    if isinstance(description, str) and description:
        take(_tokens(description))
    return {"paths": sorted(found), "plan_paths": sorted(plan_found), "unparsed": sorted(unparsed)}


def extract_paths(plan_text, description=None, repo_root=None, anchors=None):
    """Sorted, deduped repo-relative paths from a plan doc's Files-to-Modify section + description tokens."""
    return extract_paths_report(plan_text, description, repo_root, anchors)["paths"]


def _item_id(item):
    if isinstance(item, dict):
        item = item.get("id")
    return item if isinstance(item, str) and item else None


_SUBITEM_RE = re.compile(r"^(.+?)-\d{3}$")


def _pick(directory, iid):
    try:
        names = sorted(n for n in os.listdir(directory)
                       if n.startswith(iid + "_") and n.endswith(".md") and not n.endswith("_RETROSPECTIVE.md")
                       and os.path.isfile(os.path.join(directory, n)))
    except OSError:
        return None
    if not names:
        return None
    for n in names:
        try:
            with open(os.path.join(directory, n), encoding="utf-8", errors="replace") as fh:
                if "<!-- plan_doc: canonical -->" in fh.read():
                    return os.path.join(directory, n)
        except OSError:
            continue
    return os.path.join(directory, names[0])


def find_plan_doc(item, kanban_dir, repo_root=None):
    """Absolute path of the item's plan doc, or None. See module docstring for the resolution order."""
    iid = _item_id(item)
    if not iid or not isinstance(kanban_dir, str) or not kanban_dir:
        return None
    base = kanban_dir
    if not os.path.isabs(base) and isinstance(repo_root, str) and repo_root:
        base = os.path.join(repo_root, base)
    base = os.path.abspath(base)
    ids = [iid]
    m = _SUBITEM_RE.match(iid)
    if m:
        ids.append(m.group(1))
    for i in ids:
        for d in (os.path.join(base, "plans", i), base):
            hit = _pick(d, i)
            if hit:
                return os.path.abspath(hit)
    return None


def _norm_hotspot(entry):
    if not isinstance(entry, str):
        return None
    e = entry.strip()
    while e.startswith("./"):
        e = e[2:]
    e = re.sub(r"/{2,}", "/", e)
    return e or None


def _parse_sync_tap(text):
    out = set()
    for line in text.splitlines():
        m = _SYNC_RE.match(line)
        if not m:
            continue
        kind, path = m.group(1), m.group(2)
        if "$" in path:
            prefix = path.split("$", 1)[0]
            prefix = prefix[:prefix.rfind("/") + 1] if "/" in prefix else ""
            if not prefix or (kind == "file" and prefix.rstrip("/").count("/") < 1):
                continue
            out.add(prefix)
        elif any(c in path for c in "*?[]"):
            continue
        elif kind == "dir":
            out.add(path.rstrip("/") + "/")
        else:
            out.add(path)
    return out


def default_repo_root():
    """The checkout containing this module (parent of kanban-hooks/)."""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_hotspots(repo_root=None, config=None):
    """DEFAULT_HOTSPOTS + sync-tap.sh mirrored canonical sources + optional config entries. Sorted, deduped.
    repo_root None / non-string -> default_repo_root() (the checkout containing this module), never an error."""
    found = set(DEFAULT_HOTSPOTS)
    if not isinstance(repo_root, str) or not repo_root:
        repo_root = default_repo_root()
    try:
        with open(os.path.join(repo_root, "sync-tap.sh"), encoding="utf-8", errors="replace") as fh:
            found |= _parse_sync_tap(fh.read())
    except (OSError, TypeError, ValueError):
        pass
    if isinstance(config, (list, tuple)):
        for e in config:
            n = _norm_hotspot(e)
            if n:
                found.add(n)
    return sorted(found)


def _dir_file_overlap(pa, pb):
    """Paths from pa/pb where one is a directory ("x/") containing (or equal to) the other: the more specific path."""
    out = set()
    for d in pa:
        if d.endswith("/"):
            out |= {q for q in pb if q.startswith(d) or q == d.rstrip("/")}
    for d in pb:
        if d.endswith("/"):
            out |= {q for q in pa if q.startswith(d) or q == d.rstrip("/")}
    return out


def _matches(path, hotspot):
    if hotspot.endswith("/"):
        return path.startswith(hotspot) or path == hotspot.rstrip("/")
    return path == hotspot


def predict(paths_by_item, hotspots=()):
    """Pairwise conflicts: [{"a","b","paths","hotspots"}], a < b, sorted by (a, b). Clean pairs omitted."""
    spots = sorted({h for h in (_norm_hotspot(x) for x in (hotspots or ())) if h})
    touched = {}
    if isinstance(paths_by_item, dict):
        for iid, paths in paths_by_item.items():
            ps = set()
            if isinstance(paths, (list, tuple, set, frozenset)):
                for p in paths:
                    if isinstance(p, str):
                        n = p.strip()
                        while n.startswith("./"):
                            n = n[2:]
                        n = re.sub(r"/{2,}", "/", n)
                        if n:
                            ps.add(n)
            touched[str(iid)] = (ps, {h for h in spots if any(_matches(p, h) for p in ps)})
    ids = sorted(touched)
    out = []
    for i, a in enumerate(ids):
        for b in ids[i + 1:]:
            paths = sorted((touched[a][0] & touched[b][0]) | _dir_file_overlap(touched[a][0], touched[b][0]))
            hot = sorted(touched[a][1] & touched[b][1])
            if paths or hot:
                out.append({"a": a, "b": b, "paths": paths, "hotspots": hot})
    return out


NO_PATHS = "NO_PATHS"


def predict_closed(reports_by_item, hotspots=(), _predict=None):
    """THE fail-closed contention rule, shared by release_orchestrator.plan() and the CLI so they cannot drift.

    reports_by_item = {id: extract_paths_report(...) output}. An item's file set is UNKNOWN when its PLAN DOC yielded no
    paths (`plan_paths`; a report without that key falls back to `paths`). Unknown never means "touches nothing": the item
    conflicts with EVERY other item through a synthetic {"a","b","paths":[],"hotspots":[],"reason":"NO_PATHS"} entry
    (skipped for a pair that already has a real conflict). Returns
    {"conflicts": [...sorted by (a, b)], "no_paths": [sorted ids], "unparsed": {id: [tokens]}} (unparsed: non-empty only).
    A single unknown item has no peer to conflict with, so it shows up only in `no_paths`: callers must treat a
    non-empty `no_paths` as "cannot judge", never as clean. `_predict` is a test seam (default: predict)."""
    reports = {}
    if isinstance(reports_by_item, dict):
        for iid, rep in reports_by_item.items():
            reports[str(iid)] = rep if isinstance(rep, dict) else {}
    paths_by_item = {i: list(r.get("paths") or []) for i, r in reports.items()}
    no_paths = sorted(i for i, r in reports.items() if not (r["plan_paths"] if "plan_paths" in r else r.get("paths")))
    conflicts = list((_predict or predict)(paths_by_item, hotspots))
    have = {frozenset((c.get("a"), c.get("b"))) for c in conflicts if isinstance(c, dict)}
    for i in no_paths:
        for j in sorted(reports):
            if j != i and frozenset((i, j)) not in have:
                have.add(frozenset((i, j)))
                a, b = sorted((i, j))
                conflicts.append({"a": a, "b": b, "paths": [], "hotspots": [], "reason": NO_PATHS})
    conflicts.sort(key=lambda c: (c["a"], c["b"]))
    unparsed = {i: sorted(r.get("unparsed") or []) for i, r in sorted(reports.items()) if r.get("unparsed")}
    return {"conflicts": conflicts, "no_paths": no_paths, "unparsed": unparsed}


# ---------------------------------------------------------------------------------------------- CLI
def _load_items(kanban_dir):
    """id -> item dict from every <team>-board.json in kanban_dir (read-only, no lock files)."""
    items = {}
    for bf in sorted(glob.glob(os.path.join(kanban_dir, "*-board.json"))):
        try:
            with open(bf, encoding="utf-8") as fh:
                board = json.load(fh)
        except (OSError, ValueError):
            continue
        for it in (board.get("backlog") if isinstance(board, dict) else None) or []:
            if isinstance(it, dict) and isinstance(it.get("id"), str):
                items.setdefault(it["id"], it)
    return items


def _item_report(iid, items, kanban_dir):
    """extract_paths_report for one item (plan doc + description), or None when the item does not exist."""
    item = items.get(iid)
    if item is None:
        m = _SUBITEM_RE.match(iid)
        parent = items.get(m.group(1)) if m else None
        sub = None
        for s in (parent or {}).get("subitems") or []:
            if isinstance(s, dict) and s.get("id") == iid:
                sub = s
        if sub is None:
            return None
        item = {"id": iid, "description": sub.get("description")}
    doc = find_plan_doc(item, kanban_dir)
    text = ""
    if doc:
        try:
            with open(doc, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            text = ""
    desc = item.get("description")
    return extract_paths_report(text, desc if isinstance(desc, str) else None)


EXIT_UNKNOWN = 3
EXIT_DOC = ("Exit codes: 0 every file set known and no conflicts; 1 conflicts found (a NO_PATHS item conflicts with every "
            "other item); 3 an item's file set is UNKNOWN (no paths in its plan doc) and there is no conflict to report "
            "(e.g. a single item, or `paths`); 2 usage/error. Never read anything but 0 as clean.")


def main(argv=None):
    ap = argparse.ArgumentParser(prog="orchestrator_contention.py", add_help=True)
    sub = ap.add_subparsers(dest="cmd")
    p1 = sub.add_parser("paths")
    p1.add_argument("--kanban-dir", required=True)
    p1.add_argument("--item", required=True)
    p1.add_argument("--json", action="store_true")
    p2 = sub.add_parser("predict")
    p2.add_argument("--kanban-dir", required=True)
    p2.add_argument("--items", required=True)
    p2.add_argument("--repo-root", default=None)
    p2.add_argument("--json", action="store_true")
    for _p in (ap, p1, p2):
        _p.epilog = EXIT_DOC
        _p.formatter_class = argparse.RawDescriptionHelpFormatter
    try:
        args = ap.parse_args(sys.argv[1:] if argv is None else list(argv))
    except SystemExit as exc:
        return 0 if exc.code in (0, None) else 2
    if args.cmd is None:
        ap.print_usage(sys.stderr)
        return 2
    kdir = os.path.abspath(args.kanban_dir)
    if not os.path.isdir(kdir):
        print("orchestrator_contention: kanban dir not found: %s" % kdir, file=sys.stderr)
        return 2
    items = _load_items(kdir)
    if args.cmd == "paths":
        rep = _item_report(args.item, items, kdir)
        if rep is None:
            print("orchestrator_contention: item not found: %s" % args.item, file=sys.stderr)
            return 2
        unknown = not rep["plan_paths"]
        if args.json:
            print(json.dumps({"item": args.item, "paths": rep["paths"], "unparsed": rep["unparsed"],
                              "file_set_known": not unknown}, indent=2, sort_keys=True))
        else:
            for p in rep["paths"]:
                print(p)
            for u in rep["unparsed"]:
                print("UNPARSED: %s" % u)
            if unknown:
                print("NO_PATHS: %s has no file paths in its plan doc; file set unknown" % args.item)
        return EXIT_UNKNOWN if unknown else 0
    ids = sorted({s.strip() for s in args.items.split(",") if s.strip()})
    if not ids:
        print("orchestrator_contention: --items is empty", file=sys.stderr)
        return 2
    reports = {}
    for iid in ids:
        rep = _item_report(iid, items, kdir)
        if rep is None:
            print("orchestrator_contention: item not found: %s" % iid, file=sys.stderr)
            return 2
        reports[iid] = rep
    root = os.path.abspath(args.repo_root) if args.repo_root else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    res = predict_closed(reports, load_hotspots(root))
    if args.json:
        print(json.dumps(res, indent=2, sort_keys=True))
    else:
        for c in res["conflicts"]:
            print("%s <-> %s  paths=[%s]  hotspots=[%s]%s" % (c["a"], c["b"], ", ".join(c["paths"]), ", ".join(c["hotspots"]),
                                                              ("  reason=" + c["reason"]) if c.get("reason") else ""))
        for i in res["no_paths"]:
            print("NO_PATHS: %s has no file paths in its plan doc; file set unknown" % i)
        for i, toks in res["unparsed"].items():
            print("UNPARSED: %s: %s" % (i, ", ".join(toks)))
    if res["conflicts"]:
        return 1
    return EXIT_UNKNOWN if res["no_paths"] else 0


if __name__ == "__main__":
    sys.exit(main())
