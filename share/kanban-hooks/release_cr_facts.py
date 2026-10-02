"""CR-stage fact-set assembler (XACA-1349-001 / -013; spec RELEASE-LIFECYCLE.md 8.3 steps 2-5, 10.1).

Pure functions: plain dicts in, plain dicts out. NO I/O, no server/board imports, inputs never mutated.
The CR-stage orchestrator (a later subitem) owns the I/O: it loads the board, calls these, publishes the
Testing Log, stores the URL, calls ``rebuild_after_testing_log_publish`` and drafts the CR.

All fact computation is delegated to ``scripts/release_fact_dictionary.build_fact_set()`` -- this module
never hand-builds the fact dict (XACA-1349-013). It only (a) prepares the release record the dictionary
reads, and (b) sequences the build the way spec 8.3 requires. Contract: docs/release-workflow/FACT-DICTIONARY.md
"Contract for XACA-1349".

DO RELEASE ITEMS CARRY A CATEGORY TAG? (answer, measured on the Academy board 2026-10-02)
  A release record does NOT store items at all: membership is ``backlog[].releaseAssignment.releaseId`` on
  the BOARD item. Board items have NO guaranteed category. 4 of 1391 items have a top-level ``category``
  string (one is null; the rest "feature"); 287 have a free-form ``tags`` list (infrastructure, feature,
  lcars, bugfix, ...). So the tag path of XACA-1343-006 is OPTIONAL data. This module maps, per item:
    1. non-blank string ``category``            -> row ``category``
    2. else non-empty list-of-strings ``tags``   -> row ``categories`` (board tags ARE the de-facto category
                                                    vocabulary; disable with ``use_tags=False``)
    3. else nothing -> the dictionary falls back to whole-word title matching.
  A profile's ``excludedFromScope.categories`` must therefore use the team's board tag words, or rely on
  title text. An item with an empty ``tags`` list gets NO category field (so the title fallback still runs;
  an explicit empty ``categories`` would have disabled it).
"""
from __future__ import annotations

import copy
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

_HERE = Path(__file__).resolve().parent
for _cand in (_HERE.parent / "scripts", _HERE / "scripts", _HERE):  # repo layout, tap share layout, flat
    if (_cand / "release_fact_dictionary.py").is_file():
        if str(_cand) not in sys.path:
            sys.path.insert(0, str(_cand))
        break

import release_fact_dictionary as fd  # noqa: E402

FactSetError = fd.FactSetError
DEFAULT_TZ = fd.DEFAULT_TZ


def release_items_from_board(board: Dict[str, Any], release_id: str, *, use_tags: bool = True,
                             include_cancelled: bool = False) -> List[Dict[str, Any]]:
    """Release items = board items whose ``releaseAssignment.releaseId`` is ``release_id``, in board order.

    Each row is ``{id, title[, category | categories]}`` (see module docstring for the tag answer).
    Cancelled items are dropped unless ``include_cancelled`` (they are not shipping). This is membership,
    NOT scope exclusion: ``excludedFromScope`` is applied later by build_fact_set().
    """
    if not isinstance(board, dict):
        raise FactSetError("board is %s, expected an object" % type(board).__name__)
    backlog = board.get("backlog")
    if backlog is None:
        backlog = []
    if not isinstance(backlog, list):
        raise FactSetError("board.backlog is %s, expected an array" % type(backlog).__name__)
    out: List[Dict[str, Any]] = []
    for i, it in enumerate(backlog):
        if not isinstance(it, dict):
            raise FactSetError("board.backlog[%d] is %s, expected an object" % (i, type(it).__name__))
        ra = it.get("releaseAssignment")
        if not isinstance(ra, dict) or ra.get("releaseId") != release_id:
            continue
        if it.get("status") == "cancelled" and not include_cancelled:
            continue
        row: Dict[str, Any] = {"id": str(it.get("id", "")), "title": str(it.get("title", ""))}
        cat = it.get("category")
        tags = it.get("tags")
        if isinstance(cat, str) and cat.strip():
            row["category"] = cat
        elif use_tags and isinstance(tags, list) and tags and all(isinstance(t, str) for t in tags):
            row["categories"] = list(tags)
        out.append(row)
    return out


def prepare_release_record(release: Dict[str, Any], *, board: Optional[Dict[str, Any]] = None,
                           release_type: Optional[str] = None, brief_title: Optional[str] = None,
                           scope_note: Optional[str] = None, use_tags: bool = True) -> Dict[str, Any]:
    """Return a COPY of the release record with the fields the dictionary needs but no spec section names.

    * ``releaseType`` / ``briefTitle`` / ``scopeNote``: an explicit argument wins, else the record's own
      value is kept. Unset ones are left absent so the dictionary's defaults apply ("Release"; ``name`` for
      briefTitle; the 12.3 scope note). An empty briefTitle (and no ``name``) renders a gap in the CR title,
      so ``missing_cr_title_inputs()`` lets the orchestrator refuse to draft.
    * ``items``: if the record carries none and ``board`` is given, derived via release_items_from_board().
    """
    if not isinstance(release, dict):
        raise FactSetError("release is %s, expected an object" % type(release).__name__)
    rel = copy.deepcopy(release)
    for key, val in (("releaseType", release_type), ("briefTitle", brief_title), ("scopeNote", scope_note)):
        if val is not None:
            if not isinstance(val, str):
                raise FactSetError("%s is %s, expected a string" % (key, type(val).__name__))
            rel[key] = val
    if rel.get("items") is None and board is not None:
        rel["items"] = release_items_from_board(board, str(rel.get("id", "")), use_tags=use_tags)
    return rel


def missing_cr_title_inputs(facts: Dict[str, Any]) -> List[str]:
    """Fact names a CR draft needs and that are empty (currently just ``release.briefTitle``)."""
    return [n for n, v in (("release.briefTitle", facts["release"]["briefTitle"]),) if not str(v).strip()]


def build_cr_fact_set(release: Dict[str, Any], cr: Optional[Dict[str, Any]] = None, *,
                      board: Optional[Dict[str, Any]] = None, content: Optional[Dict[str, Any]] = None,
                      excluded_from_scope: Optional[Dict[str, Any]] = None, tz: str = DEFAULT_TZ,
                      platform_name: str = "", now: Optional[datetime] = None,
                      release_type: Optional[str] = None, brief_title: Optional[str] = None,
                      scope_note: Optional[str] = None, use_tags: bool = True) -> Dict[str, Any]:
    """CR-stage fact set (spec 8.3 step 2): item titles, per-stage totals, waivers, dates, deploy window.

    Thin wrapper over release_fact_dictionary.build_fact_set(). ``content`` is the draft-time ``content.*``
    dict (pass-through; unsupplied slots render empty). ``excluded_from_scope`` is the resolved profile's
    block, forwarded untouched -- items are NOT filtered here. ``cr`` may be None before the CR exists.
    Raises FactSetError / ExcludedScopeError on malformed input (fail closed).
    """
    rel = prepare_release_record(release, board=board, release_type=release_type, brief_title=brief_title,
                                 scope_note=scope_note, use_tags=use_tags)
    return fd.build_fact_set(rel, cr, content=content, tz=tz, platform_name=platform_name, now=now,
                             excluded_from_scope=excluded_from_scope)


def rebuild_after_testing_log_publish(release: Dict[str, Any], cr: Optional[Dict[str, Any]],
                                      testing_log_url: str, **kwargs: Any) -> Dict[str, Any]:
    """Spec 8.3 steps 3-5: the Testing Log is published FIRST, its URL stored, then facts are rebuilt so
    ``links.testingLog`` is set before the CR is drafted. Entry point the CR-stage orchestrator calls.

    Stores the URL on COPIES of both records (``links.testingLog``; the orchestrator persists the real
    records) and delegates to build_cr_fact_set(**kwargs). A blank/non-string URL raises FactSetError: a
    rebuild with no URL would silently draft a CR with an empty link.
    """
    if not isinstance(testing_log_url, str) or not testing_log_url.strip():
        raise FactSetError("testing_log_url must be a non-blank string")
    rel = copy.deepcopy(release) if isinstance(release, dict) else release
    crr = copy.deepcopy(cr) if isinstance(cr, dict) else cr
    for rec, name in ((rel, "release"), (crr, "cr")):
        if rec is None:
            continue
        if not isinstance(rec, dict):
            raise FactSetError("%s is %s, expected an object" % (name, type(rec).__name__))
        links = rec.get("links")
        if links is None:
            links = {}
        if not isinstance(links, dict):
            raise FactSetError("%s.links is %s, expected an object" % (name, type(links).__name__))
        links["testingLog"] = testing_log_url.strip()
        rec["links"] = links
    return build_cr_fact_set(rel, crr, **kwargs)


def testing_log_stages(release: Dict[str, Any], *, include_empty: bool = False) -> List[str]:
    """Stages to render in the Testing Log, in lifecycle order: those with test records (or, with
    ``include_empty``, every stage in ``stages``). Unknown stage names sort after the known ones."""
    if not isinstance(release, dict):
        raise FactSetError("release is %s, expected an object" % type(release).__name__)
    tests = release.get("tests")
    if tests is None:
        tests = []
    if not isinstance(tests, list):
        raise FactSetError("release.tests is %s, expected an array" % type(tests).__name__)
    present = {t.get("stage") for t in tests if isinstance(t, dict)}
    if include_empty:
        stages = release.get("stages")
        present |= set(stages) if isinstance(stages, dict) else set()
    present.discard(None)
    order = {n: i for i, n in enumerate(fd.STAGE_ORDER)}
    return sorted(present, key=lambda n: (order.get(n, len(order)), str(n)))


def build_testing_log_stage_views(release: Dict[str, Any], *, tz: str = DEFAULT_TZ,
                                  stages: Optional[Iterable[str]] = None) -> List[Dict[str, Any]]:
    """One ``stage`` view per stage (build_stage_facts), for a Testing Log with a table per stage."""
    names = list(stages) if stages is not None else testing_log_stages(release)
    return [fd.build_stage_facts(release, n, tz=tz) for n in names]


def facts_for_stage(facts: Dict[str, Any], stage_view: Dict[str, Any]) -> Dict[str, Any]:
    """Copy of ``facts`` with ``facts["stage"]`` set to ``stage_view`` (render once per stage)."""
    out = dict(facts)
    out["stage"] = copy.deepcopy(stage_view)
    return out


# --------------------------------------------------------------------------------------------------
# Board-record adapter (XACA-1349-002/003). The board stores a release as {platforms: {<p>: {version}},
# ...} and a CR as {timestamps: {...}, approver: {login, name}, wikiPages: {...}} with an activity log on
# disk as {type, from_state, to_state, ...}; build_fact_set() reads the flat dictionary shapes. These two
# functions are the only place that translation lives. Pure: dicts in, dicts out, inputs never mutated.
# --------------------------------------------------------------------------------------------------

PLATFORM_DISPLAY = {"ios": "iOS", "android": "Android", "firebase": "Firebase", "web": "Web",
                    "crossplatform": "Cross-platform"}


def resolve_release_platform(release: Dict[str, Any], cr: Optional[Dict[str, Any]] = None,
                             platform: Optional[str] = None) -> str:
    """The key of ``release.platforms`` the CR describes. Explicit ``platform`` wins, then the CR's own
    ``platform``, then the only platform the release has. Anything ambiguous raises (never guesses a
    version for a multi-platform release). Matching is case-insensitive; the release's own key spelling
    is returned."""
    plats = release.get("platforms")
    if plats is None:
        plats = {}
    if not isinstance(plats, dict):
        raise FactSetError("release.platforms is %s, expected an object" % type(plats).__name__)
    by_lower = {str(k).lower(): k for k in plats}
    for want in (platform, (cr or {}).get("platform")):
        if isinstance(want, str) and want.strip():
            key = by_lower.get(want.strip().lower())
            if key is None:
                raise FactSetError("release %s has no platform '%s' (has: %s)"
                                   % (release.get("id", "?"), want, ", ".join(sorted(plats)) or "none"))
            return key
    if len(plats) == 1:
        return next(iter(plats))
    raise FactSetError("release %s has %d platforms (%s) and neither the CR nor the caller names one"
                       % (release.get("id", "?"), len(plats), ", ".join(sorted(plats)) or "none"))


def release_record_for_facts(release: Dict[str, Any], *, cr: Optional[Dict[str, Any]] = None,
                             platform: Optional[str] = None, platform_name: str = "") -> Dict[str, Any]:
    """COPY of the board release with the flat ``version`` / ``platform`` the dictionary reads, taken from
    ``platforms.<P>.version`` (spec 3.2 PLANNED). A release with no ``platforms`` block keeps whatever
    ``version`` / ``platform`` it already carries. ``platform_name`` (wiki.json ``platformName``) wins as
    the display name; else a known key maps to its display spelling (ios -> iOS); else the key."""
    if not isinstance(release, dict):
        raise FactSetError("release is %s, expected an object" % type(release).__name__)
    rel = copy.deepcopy(release)
    if rel.get("platforms"):
        key = resolve_release_platform(rel, cr, platform)
        block = rel["platforms"][key]
        ver = block.get("version") if isinstance(block, dict) else None
        if not isinstance(ver, str) or not ver.strip():
            raise FactSetError("release %s platforms.%s.version is not set" % (rel.get("id", "?"), key))
        rel["version"] = ver.strip()
        rel["platform"] = platform_name.strip() or PLATFORM_DISPLAY.get(key.lower(), key)
    elif platform_name.strip() and not rel.get("platform"):
        rel["platform"] = platform_name.strip()
    return rel


def _approver_text(value: Any) -> str:
    if isinstance(value, dict):
        name, login = value.get("name"), value.get("login")
        name = name.strip() if isinstance(name, str) else ""
        login = login.strip() if isinstance(login, str) else ""
        return name or login
    return value.strip() if isinstance(value, str) else ""


def wiki_page_url(record: Optional[Dict[str, Any]], doc: str) -> str:
    """``record.wikiPages[doc].url`` or ''. Tolerant read (the page handle is optional)."""
    pages = (record or {}).get("wikiPages")
    page = pages.get(doc) if isinstance(pages, dict) else None
    url = page.get("url") if isinstance(page, dict) else None
    return url.strip() if isinstance(url, str) else ""


def activity_rows(events: Optional[Iterable[Any]]) -> List[Dict[str, Any]]:
    """Board activity events {ts, type, actor, from_state, to_state, note, ...} -> dictionary rows
    {verb, actor, ts, to, note}. ONE row per event, so the row count equals the log's (spec 12.4)."""
    rows: List[Dict[str, Any]] = []
    for i, e in enumerate(events or []):
        if not isinstance(e, dict):
            raise FactSetError("cr activity event %d is %s, expected an object" % (i, type(e).__name__))
        rows.append({"verb": str(e.get("type") or ""), "actor": str(e.get("actor") or ""),
                     "ts": e.get("ts", ""), "to": str(e.get("to_state") or ""),
                     "note": str(e.get("note") or "")})
    return rows


def cr_record_for_facts(cr: Dict[str, Any], *, release: Optional[Dict[str, Any]] = None,
                        activity: Optional[Iterable[Any]] = None) -> Dict[str, Any]:
    """COPY of the board CR in the shape build_fact_set() reads (spec 8.1 / FACT-DICTIONARY contract 1):
    ``timestamps.cr_approval_expected_at`` / ``cr_deployed_prod_at`` flattened to the top level, the
    ``approver`` {login, name} object collapsed to a string, ``links{testingLog, crRequestPage}`` taken from
    the STORED WIKI PAGES (release ``testing-log``, CR ``cr``) with any older ``links`` value as fallback,
    and ``activity`` mapped by activity_rows(). Absent values stay absent (the dictionary renders empty)."""
    if not isinstance(cr, dict):
        raise FactSetError("cr is %s, expected an object" % type(cr).__name__)
    out = copy.deepcopy(cr)
    ts = out.get("timestamps")
    if ts is not None and not isinstance(ts, dict):
        raise FactSetError("cr.timestamps is %s, expected an object" % type(ts).__name__)
    for key in ("cr_approval_expected_at", "cr_deployed_prod_at"):
        if (ts or {}).get(key):
            out[key] = ts[key]
    if "approver" in out:
        out["approver"] = _approver_text(out["approver"])
    links = out.get("links")
    if links is None:
        links = {}
    if not isinstance(links, dict):
        raise FactSetError("cr.links is %s, expected an object" % type(links).__name__)
    rel_links = (release or {}).get("links")
    rel_links = rel_links if isinstance(rel_links, dict) else {}
    testing = wiki_page_url(release, "testing-log") or wiki_page_url(cr, "testing-log") or \
        str(links.get("testingLog") or rel_links.get("testingLog") or "")
    request = wiki_page_url(cr, "cr") or str(links.get("crRequestPage") or rel_links.get("crRequestPage") or "")
    links = dict(links)
    if testing:
        links["testingLog"] = testing
    if request:
        links["crRequestPage"] = request
    out["links"] = links
    if activity is not None:
        out["activity_log"] = activity_rows(activity)
    return out


def build_cr_fact_set_from_board(release: Dict[str, Any], cr: Optional[Dict[str, Any]] = None, *,
                                 activity: Optional[Iterable[Any]] = None, platform: Optional[str] = None,
                                 platform_name: str = "", **kwargs: Any) -> Dict[str, Any]:
    """build_cr_fact_set() fed BOARD records: the adapter above, then the existing wrapper. ``kwargs`` are
    build_cr_fact_set's (board, content, excluded_from_scope, tz, now, release_type, brief_title, ...)."""
    crr = cr_record_for_facts(cr, release=release, activity=activity) if cr is not None else None
    rel = release_record_for_facts(release, cr=cr, platform=platform, platform_name=platform_name)
    return build_cr_fact_set(rel, crr, platform_name=platform_name, **kwargs)
