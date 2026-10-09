"""Notice-type catalog + notify.json v2 routing resolution (XACA-1399, EPIC-0068).

Pure logic, no network, no secrets, no jsonschema dependency (so it also runs
under the macOS system python3.9 that has no jsonschema). The schemas
(`notice-types.schema.json`, `notify-v2.schema.json`) are the declarative twin;
tests/test_epic0068_notice_routing.py asserts the two agree.

CATALOG LAYERING (EPIC-0068 D3, same idea as XACA-1343 profiles)
  1. canonical Academy default: kanban-hooks/notice_types.json (ships with the tap)
  2. optional team layer: <team kanban>/config/notice_types.json
     (next to notify.json, so it is team-owned and never shared)
  A team file may ADD new types (id + defaultSeverity + description all
  required) and OVERRIDE `defaultSeverity` / `description` of an existing id.
  It may NOT delete a type, rename one, or repeat an id. A present-but-invalid
  team file is an error, never silently ignored (fail closed).

DECISIONS
  * Quiet hours: window is [start, end) in the configured zone and may span
    midnight. `critical` always bypasses. start == end is rejected (ambiguous:
    empty or all-day) rather than guessed.
  * Dedupe: key = "<team>|<type>|<ref>"; window defaults to 300 s when
    `dedupeWindow` is absent, 0 disables. This module only EXPOSES key+window;
    the hub (XACA-1400) owns the "seen" state.
  * Unknown notice type is always an error (NoticeRoutingError), never a
    pass-through.

All error text names only validated ids / static strings, never config values.
"""
from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional

SEVERITIES = ("info", "warning", "high", "critical")  # ascending
CATALOG_FILE = "notice_types.json"
DEFAULT_DEDUPE_WINDOW_SECONDS = 300
ID_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}(?![\s\S])")  # not $: it matches before a final \n
HHMM_RE = re.compile(r"^([01][0-9]|2[0-3]):([0-5][0-9])(?![\s\S])")
V2_SCHEMA_TAG = "release-notify/v2"
CATALOG_TAG = "notice-types/v1"
_TYPE_KEYS = {"id", "defaultSeverity", "description"}


class NoticeRoutingError(Exception):
    """Catalog / routing failure. Messages never carry config values."""


def _safe_id(value: Any) -> str:
    return value if isinstance(value, str) and ID_RE.match(value) else "<invalid-id>"


# ---------------------------------------------------------------- catalog


def default_catalog_path() -> Path:
    """kanban-hooks/notice_types.json: next to this module in the dev tree and
    in the tap's share/kanban-hooks layout."""
    return Path(__file__).resolve().parent / CATALOG_FILE


def team_catalog_path(kanban_dir) -> Path:
    return Path(kanban_dir) / "config" / CATALOG_FILE


def _validate_entries(doc: Any, *, full: bool, label: str) -> List[str]:
    errs: List[str] = []
    if not isinstance(doc, dict):
        return ["%s: must be a JSON object" % label]
    extra = set(doc) - {"$schema", "schemaVersion", "types"}
    if extra:
        errs.append("%s: unexpected top-level field(s)" % label)
    if doc.get("$schema") != CATALOG_TAG:
        errs.append("%s: $schema must be %s" % (label, CATALOG_TAG))
    if doc.get("schemaVersion") != 1 or isinstance(doc.get("schemaVersion"), bool):
        errs.append("%s: schemaVersion must be 1" % label)
    types = doc.get("types")
    if not isinstance(types, list) or not types:
        errs.append("%s: types must be a non-empty list" % label)
        return errs
    seen = set()
    for i, ent in enumerate(types):
        where = "%s.types[%d]" % (label, i)
        if not isinstance(ent, dict):
            errs.append("%s: must be an object" % where)
            continue
        tid = ent.get("id")
        if not isinstance(tid, str) or not ID_RE.match(tid):
            errs.append("%s: id missing or malformed" % where)
            continue
        if tid in seen:
            errs.append("%s: duplicate id '%s'" % (where, tid))
        seen.add(tid)
        if set(ent) - _TYPE_KEYS:
            errs.append("%s '%s': unexpected field(s)" % (where, tid))
        sev = ent.get("defaultSeverity")
        if "defaultSeverity" in ent and sev not in SEVERITIES:
            errs.append("%s '%s': defaultSeverity is not one of %s" % (where, tid, "|".join(SEVERITIES)))
        desc = ent.get("description")
        if "description" in ent and (not isinstance(desc, str) or not desc.strip() or len(desc) > 200):
            errs.append("%s '%s': description must be 1-200 chars" % (where, tid))
        if full:
            for key in ("defaultSeverity", "description"):
                if key not in ent:
                    errs.append("%s '%s': %s is required" % (where, tid, key))
    return errs


def validate_catalog(doc: Any) -> List[str]:
    """Errors for a canonical (complete) catalog document; [] means valid."""
    return _validate_entries(doc, full=True, label="catalog")


def validate_team_override(doc: Any) -> List[str]:
    """Errors for a team notice_types.json (partial entries allowed)."""
    return _validate_entries(doc, full=False, label="team notice_types.json")


def merge_catalog(canonical: Mapping[str, Any], team: Optional[Mapping[str, Any]]) -> Dict[str, Dict[str, str]]:
    """canonical + team layer -> {id: {id, defaultSeverity, description, source}}.
    source is 'default', 'override' (team changed a default type) or 'team'
    (team-added). severitySource is 'catalog' or 'team-catalog' (team changed
    or added the severity). Raises NoticeRoutingError on any invalid layer."""
    errs = validate_catalog(canonical)
    if errs:
        raise NoticeRoutingError("notice-type catalog invalid: " + "; ".join(errs))
    merged: Dict[str, Dict[str, str]] = {}
    for ent in canonical["types"]:
        merged[ent["id"]] = {"id": ent["id"], "defaultSeverity": ent["defaultSeverity"],
                             "description": ent["description"], "source": "default",
                             "severitySource": "catalog"}
    if team is None:
        return merged
    errs = validate_team_override(team)
    if errs:
        raise NoticeRoutingError("team notice_types.json invalid: " + "; ".join(errs))
    for ent in team["types"]:
        tid = ent["id"]
        if tid in merged:
            if "defaultSeverity" in ent and ent["defaultSeverity"] != merged[tid]["defaultSeverity"]:
                merged[tid]["severitySource"] = "team-catalog"
            for key in ("defaultSeverity", "description"):
                if key in ent:
                    merged[tid][key] = ent[key]
            merged[tid]["source"] = "override"
        else:
            missing = [k for k in ("defaultSeverity", "description") if k not in ent]
            if missing:
                raise NoticeRoutingError(
                    "team notice_types.json: new type '%s' must define %s" % (tid, " and ".join(missing)))
            merged[tid] = {"id": tid, "defaultSeverity": ent["defaultSeverity"],
                           "description": ent["description"], "source": "team",
                           "severitySource": "team-catalog"}
    return merged


def _read_json(path: Path, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise NoticeRoutingError("%s not found" % label) from None
    except (OSError, ValueError) as exc:
        raise NoticeRoutingError("%s unreadable (%s)" % (label, type(exc).__name__)) from None


def load_catalog(kanban_dir=None, *, catalog_path=None) -> Dict[str, Dict[str, str]]:
    """Load the canonical catalog and, when `kanban_dir` is given and the team
    file exists, layer it on top. Missing canonical file is an error."""
    canonical = _read_json(Path(catalog_path) if catalog_path else default_catalog_path(),
                           "notice-type catalog")
    team_doc = None
    if kanban_dir is not None:
        tpath = team_catalog_path(kanban_dir)
        if tpath.exists():
            team_doc = _read_json(tpath, "team notice_types.json")
    return merge_catalog(canonical, team_doc)


# ---------------------------------------------------------------- v2 config


def is_v2(config: Any) -> bool:
    return isinstance(config, dict) and config.get("$schema") == V2_SCHEMA_TAG


def _zone(name: str):
    try:
        import zoneinfo  # noqa: PLC0415 - stdlib on 3.9+
        zone = zoneinfo.ZoneInfo(name)
        # macOS's case-insensitive tz database accepts 'utc'/'posixrules'; Linux
        # does not. Require an exact canonical name so validation agrees everywhere.
        if name not in zoneinfo.available_timezones():
            raise ValueError("non-canonical zone name")
        return zone
    except Exception:  # noqa: BLE001 - ZoneInfoNotFoundError / ValueError / missing tzdata
        raise NoticeRoutingError("quietHours.timezone is not a known IANA zone") from None


def _minutes(hhmm: str) -> int:
    m = HHMM_RE.match(hhmm) if isinstance(hhmm, str) else None
    if not m:
        raise NoticeRoutingError("quietHours time must be HH:MM")
    return int(m.group(1)) * 60 + int(m.group(2))


def validate_v2_semantics(config: Mapping[str, Any], catalog: Mapping[str, Any]) -> List[str]:
    """Cross-checks the JSON schema cannot express. Run AFTER schema validation
    (so every key printed here already matches the id grammar). Unknown notice
    type ids in `routes` / `severityOverrides` fail closed."""
    errs: List[str] = []
    for section in ("routes", "severityOverrides"):
        block = config.get(section)
        if isinstance(block, dict):
            for tid in sorted(block, key=str):
                if tid not in catalog:
                    errs.append("$.%s: unknown notice type '%s'" % (section, _safe_id(tid)))
    if "dedupeWindow" in config:
        w = config["dedupeWindow"]
        # jsonschema treats 1.0 as an integer; the runtime does not.
        if isinstance(w, bool) or not isinstance(w, int) or w < 0:
            errs.append("$.dedupeWindow: must be a non-negative integer (not a float)")
    qh = config.get("quietHours")
    if isinstance(qh, dict):
        try:
            if _minutes(qh.get("start")) == _minutes(qh.get("end")):
                errs.append("$.quietHours: start and end must differ")
            _zone(str(qh.get("timezone")))
        except NoticeRoutingError as exc:
            errs.append("$.quietHours: %s" % exc)
    return errs


def effective_severity(config: Mapping[str, Any], catalog: Mapping[str, Any], notice_type: str):
    """(severity, source): per-type override beats the catalog default.
    source is 'override' (notify.json severityOverrides), 'team-catalog' (the
    team's notice_types.json set/changed defaultSeverity) or 'catalog' (the
    Academy default)."""
    if notice_type not in catalog:
        raise NoticeRoutingError("unknown notice type '%s'" % _safe_id(notice_type))
    override = (config.get("severityOverrides") or {}).get(notice_type)
    if override is not None:
        if override not in SEVERITIES:
            raise NoticeRoutingError("severity override for '%s' is invalid" % notice_type)
        return override, "override"
    entry = catalog[notice_type]
    return entry["defaultSeverity"], entry.get("severitySource", "catalog")


def quiet_hours_decision(severity: str, quiet_hours: Optional[Mapping[str, Any]], now: datetime) -> Dict[str, Any]:
    """Pure: should a notice of `severity` be suppressed at `now` (an AWARE
    datetime, injected so tests control the clock)? `critical` always passes."""
    if severity not in SEVERITIES:
        raise NoticeRoutingError("invalid severity")
    if not quiet_hours:
        return {"configured": False, "suppressed": False, "reason": "no quiet hours configured"}
    if now.tzinfo is None:
        raise NoticeRoutingError("now must be timezone-aware")
    start, end = _minutes(quiet_hours.get("start")), _minutes(quiet_hours.get("end"))
    if start == end:
        raise NoticeRoutingError("quietHours start and end must differ")
    local = now.astimezone(_zone(str(quiet_hours.get("timezone"))))
    cur = local.hour * 60 + local.minute
    inside = (start <= cur < end) if start < end else (cur >= start or cur < end)
    if not inside:
        return {"configured": True, "suppressed": False, "reason": "outside quiet hours"}
    if severity == "critical":
        return {"configured": True, "suppressed": False, "reason": "critical bypasses quiet hours"}
    return {"configured": True, "suppressed": True, "reason": "inside quiet hours and below critical"}


def dedupe_info(config: Mapping[str, Any], team: str, notice_type: str, ref: Optional[str]) -> Dict[str, Any]:
    window = config.get("dedupeWindow", DEFAULT_DEDUPE_WINDOW_SECONDS)
    if isinstance(window, bool) or not isinstance(window, int) or window < 0:
        raise NoticeRoutingError("dedupeWindow must be a non-negative integer")
    return {"key": "%s|%s|%s" % (team, notice_type, ref or ""), "windowSeconds": window}


def resolve_notice(config: Mapping[str, Any], catalog: Mapping[str, Any], team: str, notice_type: str,
                   *, ref: Optional[str] = None, now: datetime) -> Dict[str, Any]:
    """Resolution result for one `--type` send. No delivery happens here
    (hub delivery is XACA-1400/1403)."""
    if not is_v2(config):
        raise NoticeRoutingError("notify.json is not release-notify/v2; --type needs routes")
    severity, source = effective_severity(config, catalog, notice_type)
    connections = list((config.get("routes") or {}).get(notice_type) or [])
    quiet = quiet_hours_decision(severity, config.get("quietHours"), now)
    return {
        "team": team,
        "type": notice_type,
        "severity": severity,
        "severitySource": source,
        "connections": connections,
        "routed": bool(connections),
        "quietHours": quiet,
        "suppressed": quiet["suppressed"],
        "dedupe": dedupe_info(config, team, notice_type, ref),
    }
