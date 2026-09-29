#!/usr/bin/env python3
"""
release_fact_dictionary.py -- XACA-1343-001.

The engine-fact placeholder dictionary for release content profiles
(docs/release-workflow/RELEASE-LIFECYCLE.md § 11.3, "The full fact dictionary is
part of the Academy handoff") and the assembler that builds the fact set a
template renders against (§ 10.1 "Templates render ... against a fact set").

Human-readable form: docs/release-workflow/FACT-DICTIONARY.md. Its canonical
table is GENERATED from CANONICAL_FACTS (``python3 release_fact_dictionary.py
--emit-table``), so this file is the single source of truth.

Three kinds of name appear in a template, and only the first is an engine fact:

  * CANONICAL_FACTS  -- engine facts, supplied by build_fact_set().
  * CONTENT_SLOTS    -- ``content.*`` prose slots the CALLER (the CR-stage
                        drafting session, XACA-1349) supplies. Never engine facts.
  * DEPRECATED_ALIASES -- older / spec-text names that still resolve, kept for
                        compatibility. New templates must use the canonical name.

Row-level ``this.*`` fields inside ``{{#each}}`` blocks are declared in
ROW_SHAPES, keyed by the iterated array's canonical name.

Stdlib only; runs under /usr/bin/python3 3.9.
"""
from __future__ import annotations

import copy
import re
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_TZ = "America/Chicago"

# name -> {type, source, example, kinds}. ``kinds`` lists the profile kinds that
# use the fact in the Academy defaults or the Main Event seed; the fact set itself
# is one shared dict for every kind. ``source`` names the engine record field.
CANONICAL_FACTS: Dict[str, Dict[str, Any]] = {
    # ---- release.* -------------------------------------------------------
    "release.id": {"type": "string", "source": "release record `id`", "example": "REL-0042",
                   "kinds": ["cr", "testing-log", "cr-record"]},
    "release.version": {"type": "string", "source": "release record `version`", "example": "1.2.0",
                        "kinds": ["cr", "testing-log", "cr-record"]},
    "release.platform": {"type": "string",
                         "source": "release record `platform`; falls back to wiki.json `platformName`",
                         "example": "iOS", "kinds": ["cr", "testing-log", "cr-record"]},
    "release.branch": {"type": "string", "source": "release record `branch`", "example": "releases/1.2.0",
                       "kinds": ["testing-log"]},
    "release.stageSha": {"type": "string",
                         "source": "release record `stageSha[<currentStage>]` (scalar, for the current stage only)",
                         "example": "9f2c1ab", "kinds": ["testing-log"]},
    "release.currentStage": {"type": "string", "source": "release record `currentStage`", "example": "QA",
                             "kinds": ["testing-log"]},
    "release.items": {"type": "array of {id, title}",
                      "source": "release record `items`, after `excludedFromScope` (XACA-1343-006)",
                      "example": "[{\"id\": \"XYZ-12\", \"title\": \"Faster checkout\"}]",
                      "kinds": ["testing-log", "cr-record"]},
    "release.foldedItemCount": {"type": "integer",
                                "source": "count of items removed by `excludedFromScope` with action `fold`; 0 otherwise",
                                "example": "3", "kinds": ["cr"]},
    "release.scopeNote": {"type": "string",
                          "source": "release record `scopeNote`; default \"This page records release integration testing only.\" (§ 12.3)",
                          "example": "This page records release integration testing only.",
                          "kinds": ["testing-log"]},
    "release.stages": {"type": "array of {name, enteredAt, completedAt, status}",
                       "source": "release record `stages` (spec § 6.1), in stage order, timestamps ISO-8601 UTC",
                       "example": "[{\"name\": \"QA\", \"status\": \"passed\", ...}]", "kinds": ["cr-record"]},
    "release.dateMMMDDYYYY": {"type": "string",
                              "source": "CR `deploy_window_planned` date, else the assembly date, team timezone, `MMM DD YYYY`",
                              "example": "Sep 28 2026", "kinds": ["cr"]},
    "release.releaseType": {"type": "string", "source": "release record `releaseType`, title-cased; default \"Release\"",
                            "example": "Release", "kinds": ["cr"]},
    "release.briefTitle": {"type": "string",
                           "source": "release record `briefTitle`, else `name`; empty if neither is set",
                           "example": "Faster checkout and fixes", "kinds": ["cr"]},
    "release.scheduledDate": {"type": "string", "source": "CR `deploy_window_planned`, date part, team timezone",
                              "example": "Oct 02 2026", "kinds": ["cr"]},
    "release.scheduledTime": {"type": "string", "source": "CR `deploy_window_planned`, time part, team timezone",
                              "example": "06:00 AM CDT", "kinds": ["cr"]},
    # ---- cr.* ------------------------------------------------------------
    "cr.id": {"type": "string", "source": "CR record `id`", "example": "CR-0107",
              "kinds": ["cr-record"]},
    "cr.title": {"type": "string", "source": "CR record `title`", "example": "[Sep 28 2026] Release: iOS Faster checkout",
                 "kinds": ["cr-record", "notice"]},
    "cr.risk": {"type": "string", "source": "CR record `risk`", "example": "Low", "kinds": ["cr-record"]},
    "cr.scheduledWindow": {"type": "string", "source": "CR record `deploy_window_planned`, as recorded",
                           "example": "Oct 02 2026 06:00-08:00 CT", "kinds": ["cr-record", "notice"]},
    "cr.approver": {"type": "string", "source": "CR record `approver`", "example": "Change Advisory Board",
                    "kinds": ["cr-record"]},
    "cr.approvalAssumed": {"type": "boolean", "source": "CR record `approval_assumed`", "example": "true",
                           "kinds": ["cr-record"]},
    "cr.approvalBasis": {"type": "string", "source": "CR record `approval_basis`", "example": "assumed-schedule",
                         "kinds": ["cr-record"]},
    "cr.approvalExpectedAt": {"type": "string",
                              "source": "CR record `cr_approval_expected_at`, team timezone",
                              "example": "Sep 30 2026 09:00 AM CDT", "kinds": ["notice"]},
    "cr.stateHistory": {"type": "array of {state, verb, actor, timestampCT, note}",
                        "source": "CR activity log, one row per transition (row count == transition count, § 12.4)",
                        "example": "[{\"state\": \"cr-submitted\", \"verb\": \"submit\", ...}]",
                        "kinds": ["cr-record"]},
    # ---- links.* / prod.* ------------------------------------------------
    "links.testingLog": {"type": "string (URL)",
                         "source": "release/CR record `links.testingLog` (stored at publish, § 8.3 step 5)",
                         "example": "https://wiki.example/x/123", "kinds": ["cr", "cr-record", "notice"]},
    "links.crRequestPage": {"type": "string (URL)", "source": "CR record `links.crRequestPage`",
                            "example": "https://wiki.example/x/456", "kinds": ["cr-record", "notice"]},
    "prod.deployedSha": {"type": "string", "source": "release record `stageSha.GAMMA`", "example": "9f2c1ab",
                         "kinds": ["cr-record"]},
    "prod.deployedAt": {"type": "string", "source": "CR record `cr_deployed_prod_at`, team timezone",
                        "example": "Oct 02 2026 06:12 AM CDT", "kinds": ["cr-record"]},
    "prod.soak2h": {"type": "string", "source": "release `soak.2h`, else result of the GAMMA test named like `soak` + `2h`; \"pending\" if none",
                    "example": "PASS", "kinds": ["cr-record"]},
    "prod.soak24h": {"type": "string", "source": "as `prod.soak2h`, for `24h`", "example": "pending",
                     "kinds": ["cr-record"]},
    # ---- stage.* (single-stage view) ------------------------------------
    "stage.name": {"type": "string", "source": "the stage being rendered (default: `release.currentStage`)",
                   "example": "QA", "kinds": ["testing-log"]},
    "stage.tests": {"type": "array of test rows",
                    "source": "release record `tests` filtered to `stage.name`, in append order, superseded rows kept",
                    "example": "[{\"n\": 1, \"result\": \"PASS\", ...}]", "kinds": ["testing-log"]},
    "stage.totals.automated": {"type": "integer", "source": "count of current (not superseded) Automated tests in the stage",
                               "example": "12", "kinds": ["testing-log"]},
    "stage.totals.manual": {"type": "integer", "source": "count of current Manual tests in the stage",
                            "example": "3", "kinds": ["testing-log"]},
    "stage.totals.pass": {"type": "integer", "source": "current tests with result PASS", "example": "14",
                          "kinds": ["testing-log"]},
    "stage.totals.fail": {"type": "integer", "source": "current non-PASS tests NOT covered by a waiver",
                          "example": "0", "kinds": ["testing-log"]},
    "stage.totals.waived": {"type": "integer", "source": "current non-PASS tests covered by a waiver's `tests[]`",
                            "example": "1", "kinds": ["testing-log"]},
    # ---- tests.* / waivers / notices ------------------------------------
    "tests.byStage": {"type": "array of {stage, automated, manual, pass, fail, waived}",
                      "source": "per-stage totals, same counting rules as `stage.totals.*`",
                      "example": "[{\"stage\": \"QA\", \"automated\": 12, ...}]", "kinds": ["cr-record"]},
    "tests.failuresAndReruns": {"type": "array of {failedRow, supersededByRow, stage, notes}",
                                "source": "every FAIL record; `supersededByRow` is the row number of its superseding record, empty if none (§ 12.3)",
                                "example": "[{\"failedRow\": 4, \"supersededByRow\": 7, ...}]",
                                "kinds": ["testing-log"]},
    "waivers": {"type": "array of {by, reason, ts, tests[]}",
                "source": "every `stages.<STAGE>.waiver` on the release record (spec § 6.4); `ts` is ISO-8601 UTC as recorded",
                "example": "[{\"by\": \"Lead\", \"reason\": \"Known flaky\", ...}]",
                "kinds": ["testing-log", "cr-record"]},
    "notices": {"type": "array of {ts, provider, alias, template, ok, error}",
                "source": "release/CR record `notices` (kb-notify receipts, spec § 10.1); `ts` is ISO-8601 UTC as recorded",
                "example": "[{\"alias\": \"cr-approver\", \"ok\": true, ...}]", "kinds": ["cr-record"]},
}

# Caller-supplied prose slots. NOT engine facts: build_fact_set() passes ``content``
# through untouched under the ``content`` key; the drafting session fills it.
CONTENT_SLOTS: Dict[str, str] = {
    "content.descriptionOutcomes": "Description field: user-visible outcomes.",
    "content.descriptionOutcomesShort": "Short variant of the Description field.",
    "content.reasonForChange": "Reason for change field.",
    "content.reasonForChangeShort": "Short variant of the reason field.",
    "content.testingNarrative": "Plain-language summary of testing.",
    "content.testingNarrativeFirebase": "Testing summary variant for Firebase deploys (seed-observed).",
    "content.implementationPlan": "Implementation plan field.",
    "content.implementationPlanShort": "Short variant of the implementation plan.",
    "content.rollbackPlanText": "Rollback plan field.",
    "content.behindScenesLine": "Optional behind-the-scenes line (seed-observed); Academy default uses `release.foldedItemCount` instead.",
}

# alias -> canonical target. A trailing ``[]`` on either side means "the array".
DEPRECATED_ALIASES: Dict[str, str] = {
    "items[]": "release.items[]",
    "platform.name": "release.platform",
    "links.crPage": "links.crRequestPage",
    "deploy.sha": "prod.deployedSha",
    "cr.history": "cr.stateHistory[]",
    "notices.receipts": "notices[]",
}

# Fields available as ``this.<field>`` inside ``{{#each <array>}}``.
ROW_SHAPES: Dict[str, List[str]] = {
    "release.items": ["id", "title"],
    "release.stages": ["name", "enteredAt", "completedAt", "status"],
    "cr.stateHistory": ["state", "verb", "actor", "timestampCT", "note"],
    "stage.tests": ["n", "timestampCT", "type", "env", "test", "result", "runBy", "notes",
                    "notesWithShaAndSuperseded"],
    "tests.byStage": ["stage", "automated", "manual", "pass", "fail", "waived"],
    "tests.failuresAndReruns": ["failedRow", "supersededByRow", "stage", "notes"],
    "waivers": ["by", "reason", "ts", "tests"],
    "notices": ["ts", "provider", "alias", "template", "ok", "error"],
}

STAGE_ORDER = ["DEV", "QA", "ALPHA", "BETA", "CR", "GAMMA"]
DEFAULT_SCOPE_NOTE = "This page records release integration testing only."


# ---------------------------------------------------------------- helpers
def _tzinfo(name: str):
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo(name)
    except Exception:  # missing tz database: degrade to UTC rather than fail a draft
        return timezone.utc


def _parse_iso(value: Any) -> Optional[datetime]:
    if not isinstance(value, str) or not value:
        return None
    try:
        dt = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _fmt_ts(value: Any, tz: str) -> str:
    """Team-timezone display string, or the value unchanged if it is not ISO-8601."""
    dt = _parse_iso(value)
    if dt is None:
        return "" if value is None else str(value)
    return dt.astimezone(_tzinfo(tz)).strftime("%b %d %Y %I:%M %p %Z")


def _fmt_date(value: Any, tz: str) -> Optional[str]:
    dt = _parse_iso(value)
    return dt.astimezone(_tzinfo(tz)).strftime("%b %d %Y") if dt else None


def _fmt_time(value: Any, tz: str) -> Optional[str]:
    dt = _parse_iso(value)
    return dt.astimezone(_tzinfo(tz)).strftime("%I:%M %p %Z") if dt else None


def _get(rec: Optional[Dict[str, Any]], *names: str, default: Any = "") -> Any:
    """First present key among ``names`` (snake_case spec name, then camelCase)."""
    for n in names:
        if rec and rec.get(n) is not None:
            return rec[n]
    return default


# ----------------------------------------------------- scope-exclusion hook
def apply_excluded_from_scope(items: List[Dict[str, Any]],
                              excluded: Optional[Dict[str, Any]]) -> Tuple[List[Dict[str, Any]], int]:
    """HOOK for XACA-1343-006 (Phase 3). Returns ``(items, folded_count)``.

    Called by build_fact_set() on the assembled item list, before rendering.
    Phase 2 deliberately does not filter: it returns the items unchanged and a
    fold count of 0. -006 implements ``profile.json`` ``excludedFromScope``
    ({categories[], action: fold|omit}) here, without changing any caller.
    """
    return list(items), 0


# ------------------------------------------------------------ assembly
def _items(release: Dict[str, Any]) -> List[Dict[str, Any]]:
    out = []
    for it in release.get("items") or []:
        if isinstance(it, dict):
            row = {"id": str(it.get("id", "")), "title": str(it.get("title", ""))}
            if it.get("category") is not None:
                row["category"] = it["category"]  # carried for -006's tag path; not part of ROW_SHAPES
            out.append(row)
        else:
            out.append({"id": "", "title": str(it)})
    return out


def _stage_names(release: Dict[str, Any]) -> List[str]:
    names = list((release.get("stages") or {}).keys())
    for t in release.get("tests") or []:
        if t.get("stage") and t["stage"] not in names:
            names.append(t["stage"])
    return sorted(names, key=lambda s: STAGE_ORDER.index(s) if s in STAGE_ORDER else len(STAGE_ORDER))


def _waived_ids(release: Dict[str, Any]) -> set:
    ids = set()
    for st in (release.get("stages") or {}).values():
        for tid in ((st or {}).get("waiver") or {}).get("tests") or []:
            ids.add(tid)
    return ids


def build_stage_facts(release_record: Dict[str, Any], stage_name: str, *, tz: str = DEFAULT_TZ) -> Dict[str, Any]:
    """The ``stage`` view for one stage: name, test rows, totals.

    build_fact_set() calls this for ``release.currentStage``. A caller that
    renders one table per stage calls it per stage and sets ``facts["stage"]``.
    """
    recs = [t for t in (release_record.get("tests") or []) if t.get("stage") == stage_name]
    row_of = {t.get("id"): i + 1 for i, t in enumerate(recs)}
    waived = _waived_ids(release_record)
    rows, totals = [], {"automated": 0, "manual": 0, "pass": 0, "fail": 0, "waived": 0}
    for i, t in enumerate(recs, start=1):
        sup = t.get("supersededBy")
        note = str(t.get("notes") or "")
        extra = "sha %s" % str(t.get("sha", ""))[:7] if t.get("sha") else ""
        if sup:
            extra = (extra + "; " if extra else "") + "superseded by row %s" % row_of.get(sup, sup)
        rows.append({
            "n": i, "timestampCT": _fmt_ts(t.get("ts"), tz), "type": t.get("type", ""),
            "env": t.get("env", ""), "test": t.get("test", ""), "result": t.get("result", ""),
            "runBy": t.get("runBy", ""), "notes": note,
            "notesWithShaAndSuperseded": (note + (" (" + extra + ")" if extra else "")).strip(),
        })
        if sup:
            continue  # superseded rows are shown but never counted
        totals["automated" if t.get("type") == "Automated" else "manual"] += 1
        if t.get("result") == "PASS":
            totals["pass"] += 1
        elif t.get("id") in waived:
            totals["waived"] += 1
        else:
            totals["fail"] += 1
    return {"name": stage_name, "tests": rows, "totals": totals}


def _by_stage(release: Dict[str, Any], tz: str) -> List[Dict[str, Any]]:
    out = []
    for name in _stage_names(release):
        t = build_stage_facts(release, name, tz=tz)["totals"]
        out.append(dict(stage=name, **t))
    return out


def _failures(release: Dict[str, Any], tz: str) -> List[Dict[str, Any]]:
    out = []
    for name in _stage_names(release):
        recs = [t for t in (release.get("tests") or []) if t.get("stage") == name]
        row_of = {t.get("id"): i + 1 for i, t in enumerate(recs)}
        for i, t in enumerate(recs, start=1):
            if t.get("result") == "FAIL":
                sup = t.get("supersededBy")
                out.append({"failedRow": i, "supersededByRow": row_of.get(sup, "") if sup else "",
                            "stage": name, "notes": str(t.get("notes") or "")})
    return out


def _soak(release: Dict[str, Any], which: str) -> str:
    explicit = (release.get("soak") or {}).get(which)
    if explicit:
        return str(explicit)
    for t in release.get("tests") or []:
        name = str(t.get("test", "")).lower()
        if t.get("stage") == "GAMMA" and "soak" in name and which in name and not t.get("supersededBy"):
            return str(t.get("result", "pending"))
    return "pending"


def build_fact_set(release_record: Dict[str, Any], cr_record: Optional[Dict[str, Any]] = None, *,
                   content: Optional[Dict[str, Any]] = None, tz: str = DEFAULT_TZ,
                   platform_name: str = "", now: Optional[datetime] = None,
                   excluded_from_scope: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Assemble the fact set a template renders against.

    ``release_record`` is required; ``cr_record`` may be None (a release with no CR
    yet), in which case every ``cr.*`` string is empty and ``cr.stateHistory`` is [].
    ``content`` is the caller's prose slots, passed through under ``content``.
    ``platform_name`` is the wiki.json ``platformName`` fallback for ``release.platform``.
    ``excluded_from_scope`` is the profile's ``excludedFromScope`` block, forwarded to
    apply_excluded_from_scope() (a no-op until XACA-1343-006).
    Inputs are never mutated.
    """
    rel = copy.deepcopy(release_record or {})
    cr = copy.deepcopy(cr_record) if cr_record is not None else {}
    now = now or datetime.now(timezone.utc)
    window = _get(cr, "deploy_window_planned", "deployWindowPlanned")
    current = str(_get(rel, "currentStage", "stage"))

    items, folded = apply_excluded_from_scope(_items(rel), excluded_from_scope)
    rel_links, cr_links = rel.get("links") or {}, cr.get("links") or {}

    history = [{
        "state": e.get("to", e.get("state", "")), "verb": e.get("verb", ""), "actor": e.get("actor", ""),
        "timestampCT": _fmt_ts(e.get("ts"), tz), "note": str(e.get("note") or ""),
    } for e in (cr.get("activity_log") or cr.get("activityLog") or [])]

    waivers = []
    for st in (rel.get("stages") or {}).values():
        w = (st or {}).get("waiver")
        if w:
            waivers.append({"by": w.get("by", ""), "reason": w.get("reason", ""), "ts": w.get("ts", ""),
                            "tests": list(w.get("tests") or [])})

    notices = [{"ts": n.get("ts", ""), "provider": n.get("provider", ""), "alias": n.get("alias", ""),
                "template": n.get("template", ""), "ok": bool(n.get("ok")), "error": str(n.get("error") or "")}
               for n in list(rel.get("notices") or []) + list(cr.get("notices") or [])]

    facts: Dict[str, Any] = {
        "release": {
            "id": rel.get("id", ""), "version": rel.get("version", ""),
            "platform": rel.get("platform") or platform_name,
            "branch": rel.get("branch", ""),
            "stageSha": (rel.get("stageSha") or {}).get(current, ""),
            "currentStage": current, "items": items, "foldedItemCount": folded,
            "scopeNote": _get(rel, "scopeNote", default=DEFAULT_SCOPE_NOTE),
            "stages": [{"name": n, "enteredAt": (rel["stages"][n] or {}).get("enteredAt", ""),
                        "completedAt": (rel["stages"][n] or {}).get("completedAt") or "",
                        "status": (rel["stages"][n] or {}).get("status", "")}
                       for n in _stage_names(rel) if n in (rel.get("stages") or {})],
            "dateMMMDDYYYY": _fmt_date(window, tz) or now.astimezone(_tzinfo(tz)).strftime("%b %d %Y"),
            "releaseType": str(_get(rel, "releaseType", default="Release")).title(),
            "briefTitle": str(_get(rel, "briefTitle", "name")),
            "scheduledDate": _fmt_date(window, tz) or str(window),
            "scheduledTime": _fmt_time(window, tz) or "",
        },
        "cr": {
            "id": cr.get("id", ""), "title": cr.get("title", ""), "risk": cr.get("risk", ""),
            "scheduledWindow": str(window), "approver": cr.get("approver", ""),
            "approvalAssumed": bool(_get(cr, "approval_assumed", "approvalAssumed", default=False)),
            "approvalBasis": _get(cr, "approval_basis", "approvalBasis"),
            "approvalExpectedAt": _fmt_ts(_get(cr, "cr_approval_expected_at", "approvalExpectedAt", default=None), tz),
            "stateHistory": history,
        },
        "links": {
            "testingLog": _get(cr_links, "testingLog", default=_get(rel_links, "testingLog")),
            "crRequestPage": _get(cr_links, "crRequestPage", default=_get(rel_links, "crRequestPage")),
        },
        "prod": {
            "deployedSha": (rel.get("stageSha") or {}).get("GAMMA", ""),
            "deployedAt": _fmt_ts(_get(cr, "cr_deployed_prod_at", "deployedProdAt", default=None), tz),
            "soak2h": _soak(rel, "2h"), "soak24h": _soak(rel, "24h"),
        },
        "stage": build_stage_facts(rel, current, tz=tz),
        "tests": {"byStage": _by_stage(rel, tz), "failuresAndReruns": _failures(rel, tz)},
        "waivers": waivers,
        "notices": notices,
        "content": dict(content or {}),
    }
    return facts


# --------------------------------------------------------------- aliases
def _strip_arr(path: str) -> str:
    return path[:-2] if path.endswith("[]") else path


def _lookup(facts: Dict[str, Any], path: str) -> Any:
    cur: Any = facts
    for part in path.split("."):
        cur = cur[part]
    return cur


def _assign(facts: Dict[str, Any], path: str, value: Any) -> None:
    parts = path.split(".")
    cur = facts
    for part in parts[:-1]:
        cur = cur.setdefault(part, {})
        if not isinstance(cur, dict):
            return  # alias path runs through an array (notices.receipts): use rewrite_aliases()
    cur.setdefault(parts[-1], value)  # never overwrite a real fact with an alias


def resolve_aliases(facts: Dict[str, Any]) -> Dict[str, Any]:
    """Return a copy of ``facts`` with every deprecated alias path also populated.

    ``items[]`` becomes the top-level key ``items``. Aliases whose path runs through an
    array (``notices.receipts``) cannot be represented on the facts; use
    rewrite_aliases() on the template source, which covers every alias. Bracket forms inside a token (``{{items[].title}}``)
    are not renderer syntax and are not supported; use ``{{#each items}}``.
    """
    out = copy.copy(facts)
    for alias, target in DEPRECATED_ALIASES.items():
        try:
            _assign(out, _strip_arr(alias), _lookup(out, _strip_arr(target)))
        except (KeyError, TypeError):
            continue
    return out


_TOKEN_RE = re.compile(r"\{\{(\s*(?:#each\s+|#if\s+)?)([^{}\s?]+)(\??\s*)\}\}")


def rewrite_aliases(template_text: str) -> str:
    """Rewrite deprecated alias paths in a template's SOURCE to canonical paths.

    Handles every alias, including ones that run through an array
    (``notices.receipts``). ``this.*`` and unknown names are left alone.
    """
    pairs = [(_strip_arr(a), _strip_arr(t)) for a, t in DEPRECATED_ALIASES.items()]

    def sub(m):
        path = m.group(2)
        for a, t in pairs:
            if path == a or path.startswith(a + "."):
                path = t + path[len(a):]
                break
        return "{{%s%s%s}}" % (m.group(1), path, m.group(3))

    return _TOKEN_RE.sub(sub, template_text)


# ------------------------------------------------------------ doc table
def emit_table() -> str:
    """Markdown table of CANONICAL_FACTS, embedded verbatim in FACT-DICTIONARY.md."""
    lines = ["| Fact | Type | Source (engine record field) | Example | Used by kinds |",
             "| --- | --- | --- | --- | --- |"]
    for name, d in CANONICAL_FACTS.items():
        esc = lambda s: str(s).replace("|", "\\|")
        lines.append("| `%s` | %s | %s | `%s` | %s |" % (
            name, esc(d["type"]), esc(d["source"]), esc(d["example"]).replace("`", "'"), ", ".join(d["kinds"])))
    return "\n".join(lines)


if __name__ == "__main__":
    if "--emit-table" in sys.argv:
        print(emit_table())
    else:
        print(__doc__)
