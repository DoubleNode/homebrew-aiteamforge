"""
orchestrator_routing.py -- pure routing helpers for the release orchestrator (XACA-1542-003).

Stdlib only, py3.9-safe, NO I/O in the library functions, deterministic. Imported by release_orchestrator.py
(XACA-1543). Two questions are answered here:

  classify(item, plan_doc_paths)  -> which KIND of work is this ticket? ("code" | "test" | "docs" | "ui")
  role_fit(kind, terminals)       -> which terminals may take it? (input = `kb-terminals status --json` terminals[])

CLASSIFICATION PRECEDENCE (first level that yields ANY match wins; lower levels are not consulted):

  1. Title prefix  -- the most explicit statement of intent. "Test:" / "[Test]" / "QA:", "Docs:" / "[Docs]",
                      "UI:" / "[UI]" / "UX:" / "[UX]". Only the FIRST word/bracket of the title counts.
  2. Tags          -- case-insensitive, whitespace-stripped. See _TAG_KINDS for the vocabulary.
  3. Paths         -- plan-doc / Files-to-Modify paths, one vote per path (see _path_kind and _paths_kind):
                      a. BOOKKEEPING paths never vote (see _BOOKKEEPING_DIRS / _NOTES_RE: changelog.d/,
                         CHANGELOG, RELNOTES[_env], kanban/plans/, .pytest-counts, .shell-suites.d/ -- at any depth): every ticket lists them by convention, so
                         letting them vote would route the commonest shape (one fix + its changelog fragment) to docs.
                      b. If ANY code or ui path remains, test/docs paths are SUPPORTING and do not vote: a fix plus
                         its regression test, or code plus a README touch-up, is "code" work. Between code and ui the
                         majority wins; a tie goes to "code" (the generalist; backend-heavy LCARS work is common).
                      c. Otherwise (only test/docs paths remain) the majority wins; a tie goes to "test".
  4. Default       -- "code".

TIE RULE for levels 1-2 (title, tags): when more than one kind matches (tags ["ui", "testing"]) the kind earliest
in _TIE_ORDER wins: test > docs > ui > code. An explicit title/tag says the ticket is *about* tests or docs, so it
goes to the specialist. Level 3 uses its own rule above, because paths describe what is touched, not intent.

Per-path order (so lcars-ui/tests/x.py is a test, not ui): bookkeeping, test, docs, ui, code.

ROLE FIT is FAIL-CLOSED: a terminal is eligible only if every positive condition is positively established.
Missing/None/mistyped fields make it ineligible, never eligible. Unknown kind raises ValueError (a typo must not
silently route to nobody). coordinatorOnly must be absent/None/False: anything else, including the string "true",
is treated as coordinator-only, and the check is by IDENTITY (`is None` / `is False`) because 0 == False and
0.0 == False in Python would otherwise let 0 through as "not coordinator" (the jq normalizer treats 0 as
coordinator; both halves must agree). Order: fewest lane_windows first, then name; a non-int (or bool, or negative)
lane_windows makes the terminal INELIGIBLE (we cannot judge its load, so we do not hand it work).
"""
from __future__ import annotations

import json
import re
import sys

KINDS = ("code", "test", "docs", "ui")

# Tie-break order, most specific first. Must contain exactly KINDS.
_TIE_ORDER = ("test", "docs", "ui", "code")

# Tag vocabulary (checked against the real academy board tag census, 2026-11). Lowercased.
_TAG_KINDS = {
    "test": "test", "tests": "test", "testing": "test", "qa": "test",
    "docs": "docs", "doc": "docs", "documentation": "docs",
    "ui": "ui", "ux": "ui", "lcars": "ui", "lcars-ui": "ui", "frontend": "ui", "fleet-monitor": "ui",
}

# Title prefix words -> kind.
_PREFIX_KINDS = {
    "test": "test", "tests": "test", "qa": "test",
    "docs": "docs", "doc": "docs", "documentation": "docs",
    "ui": "ui", "ux": "ui",
}
_PREFIX_RE = re.compile(r"^\s*(?:\[\s*([A-Za-z]+)\s*\]|([A-Za-z]+)\s*:)")

_UI_DIRS = ("lcars-ui/", "fleet-monitor/")
# Markup/style is UI wherever it lives; .js only counts as UI inside a UI dir (scripts/, harness/ JS is code).
_UI_EXTS = (".html", ".htm", ".css")
# BOOKKEEPING ALLOWLIST (precedence 3a). Explicit names, not prefixes: a prefix rule ("changelog*") also swallows
# real code such as scripts/changelog-assemble. Every rule matches at ANY depth, so nested (homebrew-tap/...) and
# absolute (/abs/repo/...) paths behave the same as repo-relative ones.
#   - a directory named changelog.d or .shell-suites.d anywhere in the path
#   - the directory pair kanban/plans anywhere in the path
#   - a basename matching _NOTES_RE (CHANGELOG[.md|.txt|.rst], RELNOTES[_<env>][.md|.txt|.rst])
#   - the basename .pytest-counts
_BOOKKEEPING_DIRS = ("changelog.d", ".shell-suites.d")
_BOOKKEEPING_NAMES = (".pytest-counts",)
_NOTES_RE = re.compile(r"^(?:changelog|relnotes(?:[_-](?:dev|qa|alpha|beta|gamma|prod))?)(?:\.(?:md|txt|rst))?$")

# Sentinel returned by _path_kind for convention files that must not vote (see precedence 3a).
_BOOKKEEPING = "_bookkeeping"


def _pick(kinds):
    """Deterministic winner among an iterable of kinds (tie rule); None if empty."""
    found = set(kinds)
    for k in _TIE_ORDER:
        if k in found:
            return k
    return None


def _title_kind(title):
    if not isinstance(title, str):
        return None
    m = _PREFIX_RE.match(title)
    if not m:
        return None
    return _PREFIX_KINDS.get((m.group(1) or m.group(2)).lower())


def _tag_kind(tags):
    if isinstance(tags, str):
        tags = [tags]
    if not isinstance(tags, (list, tuple)):
        return None
    return _pick(_TAG_KINDS[t.strip().lower()] for t in tags
                 if isinstance(t, str) and t.strip().lower() in _TAG_KINDS)


def _is_bookkeeping(parts):
    dirs, name = parts[:-1], parts[-1]
    if any(d in _BOOKKEEPING_DIRS for d in dirs):
        return True
    if any(dirs[i] == "kanban" and dirs[i + 1] == "plans" for i in range(len(dirs) - 1)):
        return True
    return name in _BOOKKEEPING_NAMES or bool(_NOTES_RE.match(name))


def _path_kind(path):
    if not isinstance(path, str):
        return None
    p = path.strip().replace("\\", "/")
    while p.startswith("./"):
        p = p[2:]
    p = p.lower()
    if not p:
        return None
    parts = p.split("/")
    name = parts[-1]
    if _is_bookkeeping(parts):
        return _BOOKKEEPING
    if ("tests" in parts[:-1] or "test" in parts[:-1] or name.startswith(("test_", "test-"))
            or name.endswith(("_test.py", "-test.sh", ".test.js", ".spec.js"))):
        return "test"
    if "docs" in parts[:-1] or name.endswith((".md", ".rst")):
        return "docs"
    if any(d.rstrip("/") in parts[:-1] for d in _UI_DIRS) or name.endswith(_UI_EXTS):
        return "ui"
    return "code"


def _paths_kind(paths):
    if isinstance(paths, str):
        paths = [paths]
    if not isinstance(paths, (list, tuple)):
        return None
    votes = {}
    for p in paths:
        k = _path_kind(p)
        if k and k != _BOOKKEEPING:
            votes[k] = votes.get(k, 0) + 1
    primary = [k for k in ("code", "ui") if k in votes]
    pool = primary or [k for k in ("test", "docs") if k in votes]
    if not pool:
        return None
    top = max(votes[k] for k in pool)
    # pool is already in tie order: code before ui, test before docs.
    return next(k for k in pool if votes[k] == top)


def classify(item, plan_doc_paths=None):
    """Return one of KINDS for a kanban item dict. Never raises on missing/None/mistyped fields."""
    if not isinstance(item, dict):
        item = {}
    return (_title_kind(item.get("title"))
            or _tag_kind(item.get("tags"))
            or _paths_kind(plan_doc_paths)
            or "code")


def _eligible(kind, t):
    if not isinstance(t, dict):
        return False
    roles = t.get("roles")
    if not isinstance(roles, list) or kind not in roles:
        return False
    co = t.get("coordinatorOnly")
    if not (co is None or co is False):
        return False
    if t.get("state") != "present":
        return False
    lw = t.get("lane_windows")
    if isinstance(lw, bool) or not isinstance(lw, int) or lw < 0:
        return False
    name = t.get("name")
    return isinstance(name, str) and bool(name)


def role_fit(kind, terminals):
    """Eligible terminals for `kind`, least-loaded first (lane_windows, then name). ValueError on unknown kind."""
    if kind not in KINDS:
        raise ValueError("unknown kind %r (expected one of %s)" % (kind, ", ".join(KINDS)))
    if not isinstance(terminals, list):
        return []
    return sorted((t for t in terminals if _eligible(kind, t)),
                  key=lambda t: (t["lane_windows"], t["name"]))


def _load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    usage = ("usage: orchestrator_routing.py classify --item-json FILE [--paths P ...]\n"
             "       orchestrator_routing.py role-fit KIND --terminals-json FILE")
    try:
        if argv[:1] == ["classify"] and argv[1:2] == ["--item-json"] and len(argv) >= 3:
            paths = argv[4:] if argv[3:4] == ["--paths"] else None
            print(classify(_load(argv[2]), paths))
            return 0
        if argv[:1] == ["role-fit"] and len(argv) == 4 and argv[2] == "--terminals-json":
            data = _load(argv[3])
            if isinstance(data, dict):
                data = data.get("terminals")
            print(json.dumps(role_fit(argv[1], data), indent=2))
            return 0
    except (OSError, ValueError) as exc:
        print("orchestrator_routing: %s" % exc, file=sys.stderr)
        return 1
    print(usage, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
