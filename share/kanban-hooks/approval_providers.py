"""
approval_providers.py -- CR approval-provider strategy interface (XACA-1348, spec 9).

Pure module: stdlib only, py3.9-safe (zoneinfo is stdlib from 3.9). No hidden clock:
every time-dependent function takes `now` explicitly.

A provider is a strategy object:
    name                         str
    applies_to(cr)               -> bool
    compute_expected(cr, profile)-> ISO-8601 UTC string ("...Z") | None

Providers:
    manual            compute_expected -> None (a human approves; nothing is auto-computed)
    assumed-schedule  spec 9.1: next meeting day strictly AFTER the local submit date, at
                      approveAt wall-clock in the team's IANA tz (DST-correct via zoneinfo,
                      NEVER a fixed UTC offset)
    wiki-signal       reserved for future clients; selecting it raises ProviderError

Profile (assumed-schedule): {"tz": "America/Chicago", "meetingDays": ["Mon","Wed"],
                             "approveAt": "12:00", "approver": "Charles Price, per assumption"}
meetingDays accepts 3-letter or full English day names, case-insensitive.

Output instants are UTC with a `Z` suffix (e.g. 2026-11-02T18:00:00Z). Input timestamps may
carry `Z` or a numeric offset; a naive timestamp is rejected (ambiguous). py3.9
fromisoformat rejects `Z`, so it is normalised here.

Board-level core (XACA-1348-005) -- the ONE implementation of the assumed-approval rules:
    stamp_assumed_approvals(board, now, actor, cr_ids, events) mutates a board dict in place;
    set_expected_approval(board, cr_id)                        computes cr_approval_expected_at.
Per-team profile: board.teamConfig.crSupport.approval =
    {provider: manual|assumed-schedule|wiki-signal, tz, meetingDays, approveAt, approver}.
Absent -> manual (nothing is ever assumed). Malformed -> ProviderError, nothing is stamped.
kb-cr.sh takes the board lock, runs the `stamp-board` / `set-expected` CLI modes below under
it (kanban-helpers' _kb_jq_atomic_write) and appends the returned events to the CR activity
log with its own writer; it has NO copy of the rules.

CR timestamps live under cr["timestamps"] on a board record; readers here fall back to the
top level so flat dicts keep working.

CLI (JSON on stdout, message on stderr + nonzero exit on error):
    approval_providers.py compute       --provider NAME --submitted ISO [--profile-json JSON]
    approval_providers.py should-stamp  --cr-json JSON --now ISO
    approval_providers.py stamp-payload --cr-json JSON --profile-json JSON --now ISO
    approval_providers.py stamp-board   --board FILE --now ISO [--cr-id ID ...] [--actor A]
                                        [--events-out FILE] [--dry-run]   (board JSON on stdout)
    approval_providers.py set-expected  --board FILE --cr-id ID           (board JSON on stdout)
"""
import argparse
import copy
import json
import re
import sys
from datetime import datetime, time, timedelta, timezone

try:
    from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
except ImportError:  # pragma: no cover - py<3.9
    ZoneInfo = None
    ZoneInfoNotFoundError = Exception

BASIS_ASSUMED = "assumed-schedule"
STATE_SUBMITTED = "cr-submitted"

_DAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")   # index == date.weekday()
_FULL = {"monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
         "friday": 4, "saturday": 5, "sunday": 6}
_HHMM = re.compile(r"([01][0-9]|2[0-3]):([0-5][0-9])")


class ProviderError(Exception):
    """Bad input, unknown provider, or a reserved/unimplemented provider."""


def cr_ts(cr, key):
    """A CR timestamp: cr["timestamps"][key], falling back to cr[key]. "" / None -> None."""
    if not isinstance(cr, dict):
        return None
    t = cr.get("timestamps")
    v = t.get(key) if isinstance(t, dict) else None
    if not v:
        v = cr.get(key)
    return v or None


# -- time helpers -------------------------------------------------------------

def parse_iso(value, field="timestamp"):
    """Parse ISO-8601 to an AWARE datetime. Accepts `Z`; rejects naive values."""
    if not isinstance(value, str) or not value.strip():
        raise ProviderError("%s: expected an ISO-8601 string, got %r" % (field, value))
    s = value.strip()
    if s[-1] in "zZ":
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        raise ProviderError("%s: not ISO-8601: %r" % (field, value))
    if dt.tzinfo is None:
        raise ProviderError("%s: timestamp has no timezone (use Z or an offset): %r" % (field, value))
    return dt


def to_iso_z(dt):
    """Aware datetime -> UTC ISO string with `Z`, second precision."""
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _zone(tz):
    if not isinstance(tz, str) or not tz:
        raise ProviderError("profile.tz: required IANA zone name (e.g. America/Chicago)")
    if ZoneInfo is None:
        raise ProviderError("zoneinfo unavailable (python >= 3.9 required)")
    try:
        return ZoneInfo(tz)
    except (ZoneInfoNotFoundError, ValueError, OSError):
        raise ProviderError("profile.tz: unknown IANA zone %r" % (tz,))


def _meeting_weekdays(days):
    if not isinstance(days, (list, tuple)) or not days:
        raise ProviderError('profile.meetingDays: non-empty list required, e.g. ["Mon","Wed"]')
    out = set()
    for d in days:
        key = d.strip().lower() if isinstance(d, str) else None
        if key in _DAYS:
            out.add(_DAYS.index(key))
        elif key in _FULL:
            out.add(_FULL[key])
        else:
            raise ProviderError("profile.meetingDays: unrecognised day %r (use Mon..Sun)" % (d,))
    return out


def _approve_at(value):
    m = _HHMM.fullmatch(value) if isinstance(value, str) else None
    if not m:
        raise ProviderError('profile.approveAt: "HH:MM" 24h required, got %r' % (value,))
    return time(int(m.group(1)), int(m.group(2)))


def validate_assumed_profile(profile):
    """Return (ZoneInfo, weekday-set, time, approver) or raise ProviderError."""
    if not isinstance(profile, dict):
        raise ProviderError("profile: object required")
    zone = _zone(profile.get("tz"))
    days = _meeting_weekdays(profile.get("meetingDays"))
    at = _approve_at(profile.get("approveAt"))
    approver = profile.get("approver")
    if not isinstance(approver, str) or not approver.strip():
        raise ProviderError("profile.approver: non-empty string required")
    return zone, days, at, approver


# -- providers ----------------------------------------------------------------

class ManualProvider:
    name = "manual"

    def applies_to(self, cr):
        return True

    def compute_expected(self, cr, profile):
        return None


class AssumedScheduleProvider:
    name = BASIS_ASSUMED

    def applies_to(self, cr):
        return isinstance(cr, dict) and bool(cr_ts(cr, "cr_submitted_at"))

    def compute_expected(self, cr, profile):
        zone, days, at, _approver = validate_assumed_profile(profile)
        submitted = parse_iso(cr_ts(cr, "cr_submitted_at"), "cr_submitted_at")
        # LOCAL date of submission (not the UTC date), then strictly the next day onward.
        d = submitted.astimezone(zone).date() + timedelta(days=1)
        while d.weekday() not in days:
            d += timedelta(days=1)
        # Wall-clock in the zone; zoneinfo resolves the DST offset for THAT date.
        local = datetime.combine(d, at, tzinfo=zone)
        # XACA-1348 (PR B review, unfiled observation): a wall-clock time inside a DST
        # spring-forward gap does not exist on that date (zoneinfo fold=0 would silently
        # read 02:30 as 03:30 local). Fail closed instead of inventing a time: refuse, so no
        # expected time is recorded and nothing is auto-approved for this CR (the lead
        # approves explicitly, or reschedule-approval picks a real time). Chosen over
        # rejecting the profile outright because the gap exists on ONE date per year, so a
        # profile-level rejection would be too coarse (it would also refuse every other
        # day), and it cannot be decided without the date. A repeated time (fall-back fold)
        # is NOT refused: fold=0, the first occurrence, is a real instant and the earlier of
        # the two -- documented, pinned by a test.
        rt = local.astimezone(timezone.utc).astimezone(zone)
        if (rt.year, rt.month, rt.day, rt.hour, rt.minute) != (d.year, d.month, d.day, at.hour, at.minute):
            raise ProviderError(
                "profile.approveAt %s does not exist on %s in %s (DST spring-forward gap); "
                "pick an approveAt outside the gap hour" % (at.strftime("%H:%M"), d.isoformat(), profile.get("tz")))
        return to_iso_z(local)


class WikiSignalProvider:
    name = "wiki-signal"

    def applies_to(self, cr):
        return True

    def compute_expected(self, cr, profile):
        raise ProviderError("approval provider 'wiki-signal' is reserved for future clients "
                            "and not implemented in v1")


_REGISTRY = {p.name: p for p in (ManualProvider(), AssumedScheduleProvider(), WikiSignalProvider())}


def get_provider(name):
    try:
        return _REGISTRY[name]
    except (KeyError, TypeError):
        raise ProviderError("unknown approval provider %r (known: %s)"
                            % (name, ", ".join(sorted(_REGISTRY))))


# -- stamping (spec 9.2 / 9.3) ------------------------------------------------

def backdate_refusal(cr):
    """Reason string if stamping `cr` would backdate / mis-date the approval, else None.

    XACA-1348-020 (second layer; kb-cr reschedule-approval is the first). The stamp writes
    cr_approved_at = cr_approval_expected_at, so an expected time EARLIER than cr_submitted_at
    would date an approval before the CR was even submitted (and make the deploy timing gate
    pass at once). `reschedule-approval --at`, a hand edit or an LCARS write could all produce
    one. Fail closed: refuse when expected < submitted, or when EITHER value is missing or
    unparseable (an approval we cannot place in time is not stamped). `expected == submitted`
    is not a backdate. Pure: never raises.
    """
    expected = cr_ts(cr, "cr_approval_expected_at")
    submitted = cr_ts(cr, "cr_submitted_at")
    try:
        exp_dt = parse_iso(expected, "cr_approval_expected_at")
        sub_dt = parse_iso(submitted, "cr_submitted_at")
    except ProviderError as e:
        return "cannot place the approval in time (%s)" % e
    if exp_dt < sub_dt:
        return ("cr_approval_expected_at %s is before cr_submitted_at %s; refusing to stamp a "
                "backdated approval" % (expected, submitted))
    return None


def assumption_suppressed(cr):
    """True unless approval_assumption_suppressed is absent/None or the bool False.

    Identity checks, not ``in (None, False)``: 0 == False in Python, so a membership
    test would read a stored 0 as "not suppressed" and let the sweep stamp (XACA-1348-022).
    """
    value = cr.get("approval_assumption_suppressed")
    return not (value is None or value is False)


def should_stamp(cr, now):
    """True only for a still-cr-submitted, not-yet-approved CR whose expected time has passed.

    `now` is an aware datetime or ISO string; the caller owns the clock.
    """
    if not isinstance(cr, dict):
        return False
    if cr.get("crState") != STATE_SUBMITTED or cr_ts(cr, "cr_approved_at"):
        return False
    # Spec 9.3: a hold recorded before the approval was stamped (even one placed after the
    # expected time but before the sweep ran) suppresses the assumed approval for good; resume
    # does not resurrect it. kb-cr.sh hold sets the flag, reschedule-approval clears it.
    # Fail-closed: any value other than absent / null / false counts as suppressed.
    if assumption_suppressed(cr):
        return False
    expected = cr_ts(cr, "cr_approval_expected_at")
    if not expected:
        return False
    now_dt = now if isinstance(now, datetime) else parse_iso(now, "now")
    if now_dt.tzinfo is None:
        raise ProviderError("now: timestamp has no timezone")
    if backdate_refusal(cr):                  # XACA-1348-020: fail closed, never stamp
        return False
    return now_dt >= parse_iso(expected, "cr_approval_expected_at")


def stamp_payload(cr, profile):
    """Fields for an assumed approval. cr_approved_at is the EXPECTED time, never wall-clock."""
    expected = cr_ts(cr, "cr_approval_expected_at")
    if not expected:
        raise ProviderError("cr_approval_expected_at: missing; nothing to stamp")
    refusal = backdate_refusal(cr)
    if refusal:
        raise ProviderError(refusal)
    _z, _d, _a, approver = validate_assumed_profile(profile)
    return {
        "cr_approved_at": to_iso_z(parse_iso(expected, "cr_approval_expected_at")),
        "approver": approver,
        "approval_basis": BASIS_ASSUMED,
        "approval_assumed": True,
    }


# -- board-level core (XACA-1348-005) ----------------------------------------------------------

LIFECYCLE_MARKER = "v2"
STATE_APPROVED = "cr-approved"


def board_profile(board):
    """(provider, profile) from board.teamConfig.crSupport.approval.

    Absent (no teamConfig / crSupport / approval key) -> (manual provider, {}). Anything present
    but not a usable object, or naming an unknown provider, raises ProviderError: a half-written
    profile must never degrade to 'manual' silently on one path and 'stamp' on another.
    """
    cs = ((board or {}).get("teamConfig") or {})
    cs = cs.get("crSupport") if isinstance(cs, dict) else None
    if not isinstance(cs, dict) or "approval" not in cs:
        return get_provider("manual"), {}
    prof = cs["approval"]
    if not isinstance(prof, dict):
        raise ProviderError("teamConfig.crSupport.approval: object required")
    provider = get_provider(prof.get("provider", "manual"))
    if provider.name == "assumed-schedule":
        validate_assumed_profile(prof)          # raises on any malformed field
    return provider, prof


def set_expected_approval(board, cr_id):
    """Compute + store timestamps.cr_approval_expected_at for a v2 CR; True iff one is now set.

    manual -> any stale value is removed (nothing is assumed). Mutates `board` in place.
    """
    provider, prof = board_profile(board)
    for cr in (board or {}).get("crs") or []:
        if not isinstance(cr, dict) or cr.get("id") != cr_id:
            continue
        if cr.get("cr_lifecycle") != LIFECYCLE_MARKER:
            return False
        ts = cr.setdefault("timestamps", {})
        if provider.name == "manual":
            ts.pop("cr_approval_expected_at", None)
            return False
        ts["cr_approval_expected_at"] = provider.compute_expected(cr, prof)
        return True
    raise ProviderError("CR %r not found on board" % (cr_id,))


def _state_event(actor, now_iso, note):
    # Same keys, same order as kb-cr.sh _kb_cr_activity_event "cr_state_changed" + note.
    return {"ts": now_iso, "type": "cr_state_changed", "actor": actor,
            "from_state": STATE_SUBMITTED, "to_state": STATE_APPROVED, "note": note}


def stamp_assumed_approvals(board, now, actor="kb-cr", cr_ids=None, events=None, refusals=None):
    """Stamp every due assumed approval on `board` (in place); return the stamped CR ids.

    The rules, applied to each v2 CR (optionally restricted to `cr_ids`), RE-CHECKED here against
    the board as passed (the caller holds the lock and loaded it moments ago):
      marker cr_lifecycle == "v2"  AND  should_stamp (state cr-submitted, no cr_approved_at,
      now >= expected).  A held / rejected / already-approved CR therefore never qualifies.
    A stamp writes cr_approved_at = cr_approval_expected_at (NEVER `now`), approver, approval_basis
    "assumed-schedule", approval_assumed true, and enters cr-approved the way
    kb-cr.sh _kb_cr_lifecycle_advance does (crState, timestamps.cr_approved_at, updatedAt,
    lastUpdated). `events` (a list, optional) receives (cr_id, event-dict) per stamp for the
    caller to append to the CR activity log. `refusals` (a list, optional) receives
    (cr_id, reason) for each otherwise-due CR refused by backdate_refusal (XACA-1348-020).

    manual provider -> []. Malformed profile -> ProviderError before anything is touched.
    """
    now_dt = now if isinstance(now, datetime) else parse_iso(now, "now")
    now_iso = to_iso_z(now_dt)
    provider, prof = board_profile(board)
    if provider.name == "manual":
        return []
    if provider.name != "assumed-schedule":
        raise ProviderError("approval provider %r cannot stamp approvals" % provider.name)
    wanted = set(cr_ids) if cr_ids is not None else None
    stamped = []
    for cr in (board or {}).get("crs") or []:
        if not isinstance(cr, dict):
            continue
        if wanted is not None and cr.get("id") not in wanted:
            continue
        if cr.get("cr_lifecycle") != LIFECYCLE_MARKER:
            continue
        if not should_stamp(cr, now_dt):
            # Report a due-but-refused CR (backdate guard) so the refusal is visible, not silent.
            if refusals is not None and cr.get("crState") == STATE_SUBMITTED \
                    and not cr_ts(cr, "cr_approved_at") and cr_ts(cr, "cr_approval_expected_at") \
                    and not assumption_suppressed(cr):
                reason = backdate_refusal(cr)
                if reason:
                    refusals.append((cr.get("id"), reason))
            continue
        payload = stamp_payload(cr, prof)
        cr["crState"] = STATE_APPROVED
        ts = cr.setdefault("timestamps", {})
        ts["cr_approved_at"] = payload["cr_approved_at"]
        cr["approver"] = {"name": payload["approver"]}
        cr["approval_basis"] = payload["approval_basis"]
        cr["approval_assumed"] = payload["approval_assumed"]
        cr["updatedAt"] = now_iso
        board["lastUpdated"] = now_iso
        stamped.append(cr.get("id"))
        if events is not None:
            events.append((cr.get("id"), _state_event(
                actor, now_iso,
                "approve --assumed (assumed-schedule; cr_approved_at=%s)" % payload["cr_approved_at"])))
    return stamped


# -- release.cr gate feed (XACA-1349-014) ------------------------------------------------------

# Canonical crState ranks (kb-cr.sh _kb_cr_state_rank). cr-closed is deliberately absent, as there.
_CR_RANK = {"cr-drafted": 0, "cr-published": 5, "cr-submitted": 10, "cr-rejected": 11,
            "cr-held": 12, "cr-approved": 20, "implementing": 30, "deployed-dev": 40,
            "deployed-prod": 50, "emergency-deployed": 60, "cr-completed": 70}
_CR_RETIRED = ("cr-closed", "cr-rejected")   # spec 8.3 step 1 / G8: one CR = one approval decision


# Keys a CR record may carry for the SHA its approval was written for. cr-stage stamps the first one
# (XACA-1349 QA F1); the others are tolerated spellings. The first non-empty value wins.
_STAGE_SHA_KEYS = ("cr_stage_sha", "stage_sha", "stageSha")


def cr_stamped_sha(cr):
    """The SHA stamped on a CR record (see _STAGE_SHA_KEYS), or None when absent/blank/not a string."""
    for k in _STAGE_SHA_KEYS:
        v = cr.get(k) if isinstance(cr, dict) else None
        if isinstance(v, str) and v.strip():
            return v.strip()
    return None


def is_engine_managed(cr):
    """True when `cr` carries an engine stamp: ANY of _STAGE_SHA_KEYS present (the same key set the gate
    reads via cr_stamped_sha), whatever the CR's lifecycle. Only `kb-release cr-stage` step 1 writes
    cr_stage_sha. A present-but-malformed stamp (not a string, e.g. a number or object) counts as
    managed (fail closed); None and blank strings count as absent. Anything unreadable answers True.

    INVARIANT (XACA-1349 PR #1036 round 3): the `kb-cr submit` receipt guard and the Confluence poller
    skip key on THIS predicate, never on release linkage (kb-cr assign-release / kb-release link-cr also
    write releaseAssignment, XACA-0657/0897). That is safe because release_cr_feed refuses any CR at
    cr-approved or later whose stamp is absent or != stageSha.CR: linkage alone can never open CR exit.
    So: gate allows CR exit  =>  CR is engine-managed AND guarded."""
    try:
        if not isinstance(cr, dict):
            return True
        for k in _STAGE_SHA_KEYS:
            v = cr.get(k)
            if v is None:
                continue
            if not isinstance(v, str) or v.strip():
                return True
        return False
    except Exception:  # noqa: BLE001
        return True


def _fail_closed_feed(reason, ids=(), stale=None):
    # state None: release_gate reports "CR state is 'None', must be cr-approved" and refuses.
    # `stale` (XACA-1349 F1) carries the distinct stale-approval reason release_gate also prints.
    return {"state": None, "approvedAt": None, "deployWindowPlanned": None, "crIds": list(ids),
            "crStatus": None, "cr_approved_at": None, "cr_approval_expected_at": None,
            "stageSha": None, "approvalAssumed": False, "stamped": [], "refusals": [],
            "staleApproval": stale, "error": reason}


# -- CR <-> release linkage: ONE rule, ONE implementation (XACA-1349 PR #1036 round 3) -----------
# LINKAGE (the gate feed and cr-stage) goes through _linked_crs / is_release_linked: a half-unlink
# (the LCARS unlink endpoint is two separate writes) leaves a CR in release.linkedCRs[] with no
# releaseAssignment, and the gate still drives it.
# GUARD / SKIP (the `kb-cr submit` receipt guard, the Confluence poller skip, CLI mode
# `is-engine-managed`) key on is_engine_managed (the cr_stage_sha stamp), NOT on linkage: the gate
# refuses unstamped CRs, so linkage alone can never open CR exit, while hand-linked CRs
# (kb-cr assign-release, XACA-0657/0897) keep their pre-PR submit path.

def _assignment_rid(cr):
    """The release id a CR's own releaseAssignment names ('' when absent/blank/not a dict)."""
    ra = cr.get("releaseAssignment") if isinstance(cr, dict) else None
    return str(ra.get("releaseId") or "").strip() if isinstance(ra, dict) else ""


def _listed_cr_ids(release):
    """Ids named by release.linkedCRs[] (entries are {crId: ..} objects or bare id strings).
    Raises TypeError on a non-list linkedCRs so callers can fail closed."""
    lst = release.get("linkedCRs")
    if lst is None:
        return []
    if not isinstance(lst, list):
        raise TypeError("linkedCRs is not a list")
    return [ent.get("crId") if isinstance(ent, dict) else ent for ent in lst]


def _cr_linked_to(cr_id, assigned_rid, release_id, listed_ids):
    """THE predicate. A CR's own releaseAssignment wins (it links to AT MOST ONE release); the
    release's linkedCRs[] mirror counts only for a CR that carries no assignment."""
    if assigned_rid:
        return assigned_rid == release_id
    return cr_id in listed_ids


def _linked_crs(board, release):
    """(crs, missing_ids): the board CRs linked to `release`. A linkedCRs id with no CR on the
    board is reported as missing. Linkage rule: _cr_linked_to."""
    rid = release.get("id")
    listed = _listed_cr_ids(release)
    by_id = {c.get("id"): c for c in (board.get("crs") or []) if isinstance(c, dict)}
    out, seen, missing = [], set(), []
    for cr in by_id.values():
        if _assignment_rid(cr) and _cr_linked_to(cr.get("id"), _assignment_rid(cr), rid, listed):
            out.append(cr)
            seen.add(cr.get("id"))
    for cid in listed:
        if cid in seen:
            continue
        cr = by_id.get(cid)
        if cr is None:
            missing.append(cid)
        elif _cr_linked_to(cid, _assignment_rid(cr), rid, listed):
            out.append(cr)
            seen.add(cid)
    return out, missing


def is_release_linked(board, cr):
    """True when `cr` (a CR record from `board`) is linked to ANY release under the _linked_crs
    rule: releaseAssignment.releaseId set (even if that release is missing), or its id listed in
    any release's linkedCRs[]. FAILS CLOSED: any malformation (releases / linkedCRs not lists,
    non-dict release, unreadable record) answers True so the receipt guard applies."""
    try:
        if _assignment_rid(cr):
            return True
        ids = {i for i in (cr.get("id"), cr.get("crId")) if i}
        releases = board.get("releases")
        if releases is None:
            return False
        if not isinstance(releases, list):
            return True
        for rel in releases:
            if not isinstance(rel, dict):
                return True
            listed = _listed_cr_ids(rel)
            if any(_cr_linked_to(i, "", rel.get("id"), listed) for i in ids):
                return True
        return False
    except Exception:  # noqa: BLE001
        return True


def open_linked_cr_ids(board, release):
    """Ids of the open (not closed/rejected) CRs linked to `release`; [] on any malformation."""
    try:
        return [c.get("id") for c in _linked_crs(board, release)[0]
                if c.get("crState") not in _CR_RETIRED and isinstance(c.get("id"), str)]
    except Exception:  # noqa: BLE001
        return []


def _release_at_cr(release):
    """True when the release is at CR by the GATE's own derivation (release_gate.current_stage: explicit
    stage, else furthest stages{}.enteredAt, else legacy platform environments). FAILS CLOSED: if the
    stage cannot be determined (module missing, malformed record) answer True so the stamp check runs.
    (A feed that tested only the explicit `stage` let an unstamped approved CR open the CR exit on a
    release whose stage was only derived.)"""
    try:
        import release_gate  # noqa: PLC0415 - lazy: keeps this module importable standalone
        return release_gate.current_stage(release) == "CR"
    except Exception:  # noqa: BLE001
        return True


def release_cr_feed(board, release, now, actor="lcars-release-gate"):
    """The `release.cr` dict release_gate reads, built from the board's CRs (XACA-1349-014).

    Pure: `board` is NOT mutated (assumed approvals are stamped on a deep copy of the CRs, with the
    SAME stamp_assumed_approvals the kb-cr sweep uses, so the gate sees what the sweep will write).
    The caller holds the board lock and passes the board it read under it. No I/O, no shell-out.

    Shape (keys release_gate reads first, then the ones the GAMMA gate will read):
      state                 lowest-ranked crState across the linked CRs (the gate wants cr-approved,
                            emergency-deployed, or on GAMMA exit cr-completed)
      approvedAt            LATEST cr_approved_at; None if any CR lacks one
      deployWindowPlanned   LATEST deploy_window_planned; None if any CR lacks one
      crIds, crStatus (== state), cr_approved_at (== approvedAt), cr_approval_expected_at (latest
      present), stageSha (release.stageSha.CR, else stages.CR.sha, else None), staleApproval (None, or the
      refusal text when an approved CR's cr_stage_sha is absent/!= stageSha.CR; state is then None),
      approvalAssumed, stamped, refusals

    Fail closed: no linked CR, a linkedCRs id missing from the board, a non-dict CR, an unknown
    crState, or ANY exception (malformed approval profile included) yields state None with an
    `error`. It can never produce an approved state it did not read from a CR.
    """
    try:
        if not isinstance(board, dict) or not isinstance(release, dict):
            return _fail_closed_feed("board or release is not an object")
        crs, missing = _linked_crs(board, release)
        ids = [c.get("id") for c in crs]
        if missing:
            return _fail_closed_feed("linked CR(s) not found on the board: %s" % ", ".join(map(str, missing)), ids)
        if not crs:
            return _fail_closed_feed("no CR is linked to this release")
        # G8: a rejected CR is closed and a re-CR links a NEW one to the same release, so retired CRs
        # must not drag the minimum state down (or be read stale). None open = not approved.
        crs = [c for c in crs if c.get("crState") not in _CR_RETIRED]
        ids = [c.get("id") for c in crs]
        if not crs:
            return _fail_closed_feed("every CR linked to this release is closed or rejected", ids)
        work = {"teamConfig": board.get("teamConfig"), "crs": copy.deepcopy(crs)}
        events, refusals = [], []
        stamped = stamp_assumed_approvals(work, now, actor=actor, cr_ids=ids, events=events,
                                          refusals=refusals)
        states = [c.get("crState") for c in work["crs"]]
        ranks = [_CR_RANK.get(st, -1) if isinstance(st, str) else -1 for st in states]
        low = min(range(len(ranks)), key=lambda i: ranks[i])
        state = states[low] if ranks[low] >= 0 else None
        if state is None:
            return _fail_closed_feed("a linked CR has an unknown or missing crState", ids)

        def _ts(key):
            return [cr_ts(c, key) for c in work["crs"]]

        def _latest(vals, require_all):
            if require_all and not all(vals):
                return None
            parsed = [(parse_iso(v, "timestamp"), v) for v in vals if v]
            return max(parsed, key=lambda t: t[0])[1] if parsed else None

        approved = _latest(_ts("cr_approved_at"), True)
        window = _latest([c.get("deploy_window_planned") for c in work["crs"]], True)
        # The authoritative SHA is release.stageSha.CR (what the gate reads).
        sha = (release.get("stageSha") or {}).get("CR") or \
            ((release.get("stages") or {}).get("CR") or {}).get("sha")
        # XACA-1349 QA F1: an approval is bound to the code it approved. cr-stage stamps the SHA on the
        # CR record (cr_stage_sha); an open CR that carries an approval (rank >= cr-approved) but whose
        # stamp is ABSENT or != release.stageSha.CR is NOT approved for the CR exit (fail closed).
        # An ABSENT stamp failing closed is deliberate and safe: the engine is new on this branch, so
        # there are no in-flight engine CRs without a stamp. emergency-deployed is exempt: the 13.5 path
        # approves retroactively and never goes through cr-stage. Only while the release is at CR: the
        # GAMMA exit asks for cr-completed, not for an approval.
        if sha and _release_at_cr(release):
            for c in work["crs"]:
                st = c.get("crState")
                if st == "emergency-deployed" or _CR_RANK.get(st, -1) < _CR_RANK["cr-approved"]:
                    continue
                stamp = cr_stamped_sha(c)
                if stamp is None or stamp.lower() != str(sha).lower():
                    why = ("CR %s approved SHA %s != stageSha.CR %s: close it superseded "
                           "(kb-cr close %s --reason \"superseded by new SHA %s\") and re-run cr-stage"
                           % (c.get("id"), (stamp[:12] if stamp else "<none stamped>"), str(sha)[:12], c.get("id"),
                              str(sha)[:12]))
                    return _fail_closed_feed(why, ids, stale=why)
        return {"state": state, "approvedAt": approved, "deployWindowPlanned": window,
                "crIds": ids, "crStatus": state, "cr_approved_at": approved,
                "cr_approval_expected_at": _latest(_ts("cr_approval_expected_at"), False),
                "stageSha": sha or None, "staleApproval": None,
                "approvalAssumed": any(c.get("approval_assumed") is True for c in work["crs"]),
                "stamped": stamped, "refusals": [list(r) for r in refusals], "error": None}
    except Exception as e:  # noqa: BLE001 - the gate must see "not approved", whatever went wrong
        return _fail_closed_feed("%s: %s" % (type(e).__name__, e))


# -- CLI ----------------------------------------------------------------------

def _json_arg(raw, label):
    try:
        return json.loads(raw)
    except (TypeError, ValueError) as e:
        raise ProviderError("%s: invalid JSON (%s)" % (label, e))


def _board_cli(args):
    try:
        with open(args.board, encoding="utf-8") as fh:
            board = json.loads(fh.read())
    except (OSError, ValueError) as e:
        raise ProviderError("cannot read board %s: %s" % (args.board, e))
    if args.mode == "set-expected":
        set_expected_approval(board, args.cr_id)
    else:
        evs = []
        refused = []
        ids = stamp_assumed_approvals(board, args.now, actor=args.actor, cr_ids=args.cr_id,
                                      events=evs, refusals=refused)
        for rid, why in refused:
            sys.stderr.write("approval_providers: REFUSED to stamp %s: %s\n" % (rid, why))
        if args.dry_run:                      # read-only probe: ids on stdout, board untouched
            sys.stdout.write(json.dumps(ids) + "\n")
            return 0
        if args.events_out:
            with open(args.events_out, "w", encoding="utf-8") as fh:
                fh.write(json.dumps([{"cr_id": c, "event": ev} for c, ev in evs]))
    sys.stdout.write(json.dumps(board, indent=2, ensure_ascii=False) + "\n")
    return 0


def _managed_cli(args):
    """Print `yes`/`no` (exit 0); any error exits 2 and the caller must treat it as engine-managed."""
    try:
        with open(args.board, encoding="utf-8") as fh:
            board = json.loads(fh.read())
        crs = board.get("crs")
        if not isinstance(crs, list):
            raise ValueError("board has no crs list")
        if args.cr_index is not None:
            cr = crs[args.cr_index] if 0 <= args.cr_index < len(crs) else None
        else:
            cr = next((c for c in crs if isinstance(c, dict) and args.cr_id in (c.get("id"), c.get("crId"))), None)
        if not isinstance(cr, dict):
            raise ValueError("CR not found on the board")
    except (OSError, ValueError, AttributeError) as e:
        sys.stderr.write("approval_providers: is-engine-managed: %s\n" % e)
        return 2
    sys.stdout.write("yes\n" if is_engine_managed(cr) else "no\n")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="approval_providers.py")
    sub = ap.add_subparsers(dest="mode", required=True)
    c = sub.add_parser("compute")
    c.add_argument("--provider", required=True)
    c.add_argument("--submitted", required=True)
    c.add_argument("--profile-json", default="{}")
    s = sub.add_parser("should-stamp")
    s.add_argument("--cr-json", required=True)
    s.add_argument("--now", required=True)
    p = sub.add_parser("stamp-payload")
    p.add_argument("--cr-json", required=True)
    p.add_argument("--profile-json", required=True)
    p.add_argument("--now", required=True)
    b = sub.add_parser("stamp-board")
    b.add_argument("--board", required=True)
    b.add_argument("--now", required=True)
    b.add_argument("--cr-id", action="append", default=None)
    b.add_argument("--actor", default="kb-cr")
    b.add_argument("--events-out", default=None)
    b.add_argument("--dry-run", action="store_true")
    e = sub.add_parser("set-expected")
    e.add_argument("--board", required=True)
    e.add_argument("--cr-id", required=True)
    r = sub.add_parser("is-engine-managed")
    r.add_argument("--board", required=True)
    g = r.add_mutually_exclusive_group(required=True)
    g.add_argument("--cr-id")
    g.add_argument("--cr-index", type=int)
    args = ap.parse_args(argv)
    try:
        if args.mode == "is-engine-managed":
            return _managed_cli(args)
        if args.mode in ("stamp-board", "set-expected"):
            return _board_cli(args)
        if args.mode == "compute":
            prov = get_provider(args.provider)
            cr = {"cr_submitted_at": args.submitted}
            profile = _json_arg(args.profile_json, "--profile-json")
            out = {"provider": prov.name,
                   "cr_approval_expected_at": prov.compute_expected(cr, profile)}
        elif args.mode == "should-stamp":
            out = {"should_stamp": should_stamp(_json_arg(args.cr_json, "--cr-json"), args.now)}
        else:
            cr = _json_arg(args.cr_json, "--cr-json")
            if not should_stamp(cr, args.now):
                raise ProviderError("should_stamp is false for this CR at now=%s; "
                                    "refusing to build payload" % args.now)
            out = stamp_payload(cr, _json_arg(args.profile_json, "--profile-json"))
    except ProviderError as e:
        sys.stderr.write("approval_providers: %s\n" % e)
        return 2
    sys.stdout.write(json.dumps(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
