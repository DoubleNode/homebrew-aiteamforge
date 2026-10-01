"""
release_schema.py -- release-record schema helpers (XACA-1346, spec RELEASE-LIFECYCLE 3.4/6.1/6.2).

Pure module: no I/O, stdlib only, py3.9-safe. The gate evaluator, the server and
scripts/migrate-release-schema.py all import it so the record shape lives in ONE place.
"""
import copy
import re

STAGES = ("PLANNED", "DEV", "QA", "ALPHA", "BETA", "CR", "GAMMA", "PROD")
STAGE_STATUSES = ("pending", "running", "passed", "failed", "waived")  # spec 3.4
TEST_TYPES = ("Automated", "Manual")
TEST_RESULTS = ("PASS", "FAIL", "SKIP")

# Test-record fields (spec 6.2), in canonical order.
TEST_FIELDS = ("id", "stage", "type", "ts", "env", "sha", "test", "result",
               "runBy", "notes", "parent", "supersededBy")
_STR_FIELDS = ("id", "ts", "env", "sha", "test", "runBy")
_NULLABLE_STR = ("parent", "supersededBy")


def release_defaults():
    """Fresh migration-safe defaults for the spec 6.1 release additions."""
    return {
        "stageSha": {},
        "rollbackSha": None,
        "stages": {},
        "tests": [],
        "notices": [],
        "branch": None,
        "branchBaseSha": None,
    }


def validate_test_record(rec):
    """Return a list of problems with a spec 6.2 test record ([] = valid)."""
    if not isinstance(rec, dict):
        return ["record must be an object"]
    errs = []
    for f in TEST_FIELDS:
        if f not in rec:
            errs.append("missing field: %s" % f)
    for f in rec:
        if f not in TEST_FIELDS:
            errs.append("unknown field: %s" % f)
    if errs:
        return errs
    for f in _STR_FIELDS:
        if not isinstance(rec[f], str) or not rec[f].strip():
            errs.append("%s must be a non-empty string" % f)
    if isinstance(rec["id"], str) and rec["id"].startswith("sha:"):
        errs.append("id must not start with 'sha:' (reserved for supersede placeholders)")
    if rec["stage"] not in STAGES:
        errs.append("stage must be one of %s" % (list(STAGES),))
    if rec["type"] not in TEST_TYPES:
        errs.append("type must be one of %s" % (list(TEST_TYPES),))
    if rec["result"] not in TEST_RESULTS:
        errs.append("result must be one of %s" % (list(TEST_RESULTS),))
    if not isinstance(rec["notes"], str):
        errs.append("notes must be a string")
    elif rec["result"] in ("FAIL", "SKIP") and not rec["notes"].strip():
        errs.append("notes is required when result is FAIL or SKIP")
    for f in _NULLABLE_STR:
        if rec[f] is not None and not isinstance(rec[f], str):
            errs.append("%s must be a string or null" % f)
    return errs


def validate_stage_status(status):
    """True if status is a legal spec 3.4 stage status."""
    return status in STAGE_STATUSES


def append_test_record(tests, rec):
    """Return a NEW tests[] with rec appended (spec 6.3 append-only).

    Rejects an invalid record or a duplicate id. Never mutates the input list.
    """
    problems = validate_test_record(rec)
    if problems:
        raise ValueError("invalid test record: " + "; ".join(problems))
    if any(t.get("id") == rec["id"] for t in tests):
        raise ValueError("duplicate test record id: %s" % rec["id"])
    return list(tests) + [copy.deepcopy(rec)]


def append_test_records(tests, recs):
    """Batch append_test_record -> (new tests[], [(index into recs, message)]). Same validation and
    the same messages, but ids are tracked in a set and the list is copied once: calling
    append_test_record per record re-scanned and re-copied tests[] each time, O(N^2) for a large
    post under the board lock (PR #1010 round 1). A rejected record is skipped, not appended;
    callers that must be all-or-nothing check `problems` before saving. Never mutates the input."""
    out = list(tests)
    seen = {t.get("id") for t in tests if isinstance(t, dict) and isinstance(t.get("id"), str)}
    problems = []
    for i, rec in enumerate(recs):
        bad = validate_test_record(rec)
        if bad:
            problems.append((i, "invalid test record: " + "; ".join(bad)))
            continue
        if rec["id"] in seen:
            problems.append((i, "duplicate test record id: %s" % rec["id"]))
            continue
        seen.add(rec["id"])
        out.append(copy.deepcopy(rec))
    return out, problems


def _ids(tests):
    return {t["id"]: t for t in tests if isinstance(t, dict) and isinstance(t.get("id"), str)}


def _index(tests):
    """(id -> record [last wins, as _ids], id -> FIRST position). Built once per snapshot so a batch of
    transitions is O(N), not O(N) per transition (PR #1010 round 1: O(N^2) under the board lock)."""
    order = {}
    for i, t in enumerate(tests):
        if isinstance(t, dict) and isinstance(t.get("id"), str):
            order.setdefault(t["id"], i)
    return _ids(tests), order


def supersede_transition_ok(rec, new_value, tests, _idx=None):
    """THE single supersededBy transition rule (spec 6.5), used by set_superseded AND
    check_append_only. `rec` is the record as it stands, `tests` the snapshot that
    must contain the target. Spec 6.5: the target is "the first new record for the
    same test". Every SHA comparison is case-insensitive (lower() on BOTH sides).
    Legal transitions are exactly:

      null       -> "sha:<X>" with X non-empty LOWER-case hex and X != rec.sha
                    (placeholder until a record exists; upper-case is REFUSED, not
                    normalised, so the value written is the value matched later; a
                    record can never point at its own SHA)
      null       -> a record id T where T exists, T is not rec, T.test == rec.test,
                    T.sha != rec.sha (a new SHA: the stage moved), and T appears LATER
                    in tests[] than rec
      "sha:<X>"  -> a record id T with T.sha == X, T.sha != rec.sha (this also closes a
                    legacy placeholder that already names rec's own SHA), T.test == rec.test,
                    T not rec, and T LATER than rec in tests[]

    A record id starting with "sha:" is reserved (validate_test_record refuses it) and can
    never be a target. Everything else is illegal: id -> other id, sha -> other sha,
    anything -> null/""/non-string, "sha:" with an empty/non-hex/upper-case value.

    Ordering caveat (ACCEPTED limitation): SHAs cannot be ordered without git, so a later
    record at an OLDER SHA is not detectable. "Later position in tests[] + different sha"
    is the enforceable proxy (records are append-only, so position is time order).
    """
    if not isinstance(new_value, str) or not new_value:
        return False
    old = rec.get("supersededBy")
    rec_sha = str(rec.get("sha")).lower()
    if old is None and new_value.startswith("sha:"):
        x = new_value[4:]
        return re.fullmatch(r"[0-9a-f]+", x) is not None and x.lower() != rec_sha
    is_placeholder = isinstance(old, str) and old.startswith("sha:")
    if old is not None and not is_placeholder:
        return False
    if new_value.startswith("sha:"):
        return False  # reserved prefix: never an id target
    ids, order = _idx if _idx is not None else _index(tests)
    target = ids.get(new_value)
    if target is None or new_value == rec.get("id") or target.get("test") != rec.get("test"):
        return False
    if rec.get("id") not in order or order[new_value] <= order[rec["id"]]:
        return False
    target_sha = str(target.get("sha")).lower()
    if target_sha == rec_sha:
        return False
    return target_sha == old[4:].lower() if is_placeholder else True


def set_superseded(tests, rec_id, superseded_by):
    """Return a NEW tests[] with supersededBy set on rec_id -- the ONLY permitted edit.

    Applies supersede_transition_ok; raises ValueError on an unknown record or an
    illegal transition (dangling/self target, id -> other id, sha -> other sha, ...).
    """
    rec = _ids(tests).get(rec_id)
    if rec is None:
        raise ValueError("no test record with id: %s" % rec_id)
    if not supersede_transition_ok(rec, superseded_by, tests):
        raise ValueError("illegal supersededBy transition for %s: %r -> %r"
                         % (rec_id, rec.get("supersededBy"), superseded_by))
    return [dict(t, supersededBy=superseded_by) if t is rec else t for t in tests]


def set_superseded_many(tests, updates, skip_illegal=False):
    """Batch form of set_superseded: `updates` is [(rec_id, superseded_by), ...]. Every transition
    is checked by supersede_transition_ok against ONE index of the input snapshot, then all are
    applied in one pass -> (new tests[], [applied rec_ids in update order]). Equivalent to applying
    them one by one because the rule reads only the target's id/test/sha/position and the record's
    OWN supersededBy, so each record may appear at most once (a repeat raises ValueError).
    skip_illegal=False raises on the first illegal transition (nothing applied); True skips it.
    """
    idx = _index(tests)
    ids = idx[0]
    chosen, applied = {}, []
    for rec_id, value in updates:
        if rec_id in chosen:
            raise ValueError("record %s appears twice in one supersede batch" % rec_id)
        rec = ids.get(rec_id)
        if rec is None:
            raise ValueError("no test record with id: %s" % rec_id)
        if not supersede_transition_ok(rec, value, tests, _idx=idx):
            if skip_illegal:
                continue
            raise ValueError("illegal supersededBy transition for %s: %r -> %r"
                             % (rec_id, rec.get("supersededBy"), value))
        chosen[rec_id] = value
        applied.append(rec_id)
    if not chosen:
        return list(tests), applied
    targets = {id(ids[r]): v for r, v in chosen.items()}
    return [dict(t, supersededBy=targets[id(t)]) if id(t) in targets else t for t in tests], applied


def check_append_only(old_tests, new_tests):
    """Return violations between two tests[] snapshots ([] = only legal changes).

    Legal: appended VALID records with fresh ids, and supersededBy changes that
    supersede_transition_ok allows. Existing records are compared by key PRESENCE and
    value, never by .get(). Never raises on malformed input; reports it.
    """
    if not isinstance(old_tests, list) or not isinstance(new_tests, list):
        return ["tests must be lists"]
    errs = ["old[%d]: not an object" % i for i, o in enumerate(old_tests) if not isinstance(o, dict)]
    if errs:
        return errs
    if len(new_tests) < len(old_tests):
        return ["records removed (%d -> %d)" % (len(old_tests), len(new_tests))]
    seen = set()
    idx = _index(new_tests)   # once per snapshot: per-record transition checks stay O(1)
    for i, new in enumerate(new_tests):
        if not isinstance(new, dict):
            errs.append("new[%d]: not an object" % i)
            continue
        rid = new.get("id")
        if i < len(old_tests):
            old = old_tests[i]
            if set(old) != set(new):
                errs.append("%s: keys changed (%s)" % (old.get("id"), sorted(set(old) ^ set(new))))
            for k in set(old) & set(new):
                if k != "supersededBy" and old[k] != new[k]:
                    errs.append("%s: field %s modified" % (rid, k))
            if "supersededBy" in old and "supersededBy" in new and old["supersededBy"] != new["supersededBy"] \
                    and not supersede_transition_ok(old, new["supersededBy"], new_tests, _idx=idx):
                errs.append("%s: illegal supersededBy transition %r -> %r"
                            % (rid, old["supersededBy"], new["supersededBy"]))
        else:
            for p in validate_test_record(new):
                errs.append("appended %s: %s" % (rid, p))
            if new.get("supersededBy") is not None and \
                    not supersede_transition_ok(dict(new, supersededBy=None), new["supersededBy"], new_tests, _idx=idx):
                errs.append("appended %s: illegal supersededBy %r" % (rid, new["supersededBy"]))
        if isinstance(rid, str):
            if rid in seen:
                errs.append("duplicate id: %s" % rid)
            seen.add(rid)
    return errs
