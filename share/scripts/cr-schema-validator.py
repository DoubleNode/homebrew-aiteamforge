#!/usr/bin/env python3
"""
cr-schema-validator.py — Validates a migrated team board against the CR schema (v2.2).

Usage:
    cr-schema-validator.py <board.json> [--schema <cr-schema.json>] [--verbose]

Exit codes:
    0 — PASS (all checks passed)
    1 — FAIL (one or more validation errors)
    2 — file not found / unreadable
    3 — invalid JSON
"""

import json
import re
import sys
from pathlib import Path

# ISO 8601 UTC validator — matches strings like 2026-05-15T22:00:00Z or
# 2026-05-15T22:00:00.000Z (the formats produced by kb-cr and Python's
# datetime.utcnow().isoformat() + "Z").
_ISO8601_UTC_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$"
)


def _is_iso8601_utc(value: str) -> bool:
    """Return True if value is a non-empty ISO 8601 UTC string."""
    return bool(value and _ISO8601_UTC_RE.match(value))

# ── CR lifecycle evidence maps (XACA-0924) ───────────────────────────────────
# Consumed by check7 (presence) and check8 (monotonicity). See the block
# comments on those checks for the derivation and for why several timestamps
# deliberately carry no prerequisite.

# crState -> the single timestamps.<field> stamped on ENTRY to that state.
# Hand-synced with _kb_cr_state_entry_ts_field() in scripts/kb-cr.sh.
STATE_ENTRY_TS = {
    "cr-drafted":         None,                          # stamped by `kb-cr create`
    "cr-published":       "cr_published_at",
    "cr-submitted":       "cr_submitted_at",
    "cr-rejected":        "cr_rejected_at",
    "cr-held":            "cr_held_at",
    "cr-approved":        "cr_approved_at",
    "implementing":       "cr_started_dev_at",
    "deployed-dev":       "cr_deployed_dev_at",
    "deployed-prod":      "cr_deployed_prod_at",
    "emergency-deployed": "cr_emergency_deployed_at",
    "cr-closed":          "cr_closed_at",
}

# Lifecycle timestamps stamped WITHOUT a state change, mapped to the crState
# whose rank they inherit. XACA-0924-011.
#
# STATE_ENTRY_TS is a state -> field map, so it structurally cannot express a
# timestamp that belongs to no state — and exactly one does. `kb-cr start-test`
# writes cr_started_test_at and deliberately leaves crState alone (there is no
# ready-for-test state in the schema), so the field fell through every evidence
# map in all three files: this validator's two, and the Confluence guard's
# POST_APPROVAL_EVIDENCE. It was not exempted for a reason; it was invisible to
# the shape the maps are written in.
#
# Naming it here rather than special-casing it keeps both invariants the pins
# enforce intact — "every field in EVIDENCE_PREREQS is a real lifecycle
# timestamp" (the typo guard, which is what stops a misspelled dependent from
# making its own rule unfireable) and "prerequisites rank strictly below their
# dependents" — while letting them see a field that has no state of its own.
#
# XACA-1239. cr_approval_waived_at is ALSO stateless — kb-cr waive-approval
# (XACA-1239-002) records it without changing crState, same shape as
# start-test — so it belongs here too. It borrows cr-approved's rank
# deliberately: a waiver occupies the same evidentiary SLOT approval does (see
# the OR-group note on EVIDENCE_PREREQS below), even though it is never
# approval and must never be confused with it by a reader.
NON_STATE_ENTRY_TS = {
    # start-test accepts ONLY crState `implementing`, so this timestamp implies
    # everything `implementing` implies and ranks with it.
    "cr_started_test_at": "implementing",
    # kb-cr waive-approval is allowed only from cr-submitted/cr-held (D3) and
    # stands in for cr_approved_at as an OR-group member below, so it ranks
    # with cr-approved.
    "cr_approval_waived_at": "cr-approved",
}

# (field, [earlier fields its presence implies]) — ordered for stable output.
#
# OR-GROUP NOTATION (XACA-1239, D2). An entry in a prereq tuple may be a
# single field ("cr_submitted_at") or a "|"-joined token
# ("cr_approved_at|cr_approval_waived_at"), meaning check8 treats the line as
# satisfied if ANY ONE of the piped fields is present — never requiring all of
# them. This mirrors scripts/kb-cr.sh's _kb_cr_state_required_evidence, which
# uses the identical notation for the identical reason: a CR moved to
# implementing / deployed-dev / deployed-prod with a recorded approval WAIVER
# instead of a real approval is not incoherent — it is the one documented
# lifecycle shape XACA-1239 adds — so it must not trip check8. A CR carrying
# neither cr_approved_at NOR cr_approval_waived_at (e.g. one moved with
# --force and no waiver) still fails check8, reported against the FULL
# "a|b" token so the message can name both alternatives.
EVIDENCE_PREREQS = (
    ("cr_rejected_at",      ("cr_submitted_at",)),
    ("cr_held_at",          ("cr_submitted_at",)),
    ("cr_approved_at",      ("cr_submitted_at",)),
    # XACA-1239. A waiver is only valid from cr-submitted/cr-held (D3), so it
    # requires cr_submitted_at exactly as cr_approved_at does — analogous
    # treatment to the real approval it stands in for evidentially, without
    # ever being treated as one (it is its own field, never merged into
    # cr_approved_at's row).
    ("cr_approval_waived_at", ("cr_submitted_at",)),
    ("cr_started_dev_at",   ("cr_submitted_at", "cr_approved_at|cr_approval_waived_at")),
    # XACA-0924-011 (reconciliation pass). cr_started_test_at was the one
    # stamped lifecycle timestamp absent from every evidence map, in all three
    # files, because it is the only one that belongs to no crState: `kb-cr
    # start-test` writes it WITHOUT a state change (there is no ready-for-test
    # state in the schema), so a state->field map cannot reach it and neither
    # of the field maps had been derived independently. It nonetheless implies
    # approval by exactly the argument the line above uses: start-test accepts
    # ONLY crState `implementing`, which requires cr_submitted_at +
    # (cr_approved_at OR cr_approval_waived_at, XACA-1239). Measured across the
    # 6 real team boards when added: zero CRs carry it, so this introduced no
    # new findings on existing data.
    ("cr_started_test_at",  ("cr_submitted_at", "cr_approved_at|cr_approval_waived_at")),
    ("cr_deployed_dev_at",  ("cr_submitted_at", "cr_approved_at|cr_approval_waived_at")),
    ("cr_deployed_prod_at", ("cr_submitted_at", "cr_approved_at|cr_approval_waived_at")),
)

# Terminal state whose violations are reported as warnings rather than errors.
_TERMINAL_STATE = "cr-closed"

# Default schema path (resolved relative to this script's location)
_DEFAULT_SCHEMA = Path(__file__).parent.parent / "homebrew-tap" / "share" / "templates" / "kanban" / "cr-schema.json"


def _load_json(path: Path) -> dict:
    if not path.exists():
        print(f"ERROR: file not found: {path}", file=sys.stderr)
        sys.exit(2)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        print(f"ERROR: cannot read {path}: {e}", file=sys.stderr)
        sys.exit(2)
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        print(f"ERROR: {path} is not valid JSON: {e}", file=sys.stderr)
        sys.exit(3)


def validate_board(board: dict, schema: dict, board_path: str, verbose: bool = False) -> list:
    """
    Run all validation checks against the board.
    Returns a list of error strings (empty = PASS).
    """
    errors = []
    warnings = []

    # ── Check 1: required board-level fields ─────────────────────────────────
    crs = board.get("crs")
    next_cr_seq = board.get("nextCrSeq")

    if crs is None:
        errors.append("FAIL [check1]: top-level 'crs' field is absent — board has not been migrated")
    elif not isinstance(crs, list):
        errors.append(f"FAIL [check1]: 'crs' must be an array, got {type(crs).__name__}")
    else:
        if verbose:
            print(f"  PASS [check1]: crs[] present with {len(crs)} record(s)")

    if next_cr_seq is None:
        warnings.append("WARN [check1]: 'nextCrSeq' is absent — ID generation will start from 1")
    elif not isinstance(next_cr_seq, int) or next_cr_seq < 1:
        errors.append(f"FAIL [check1]: 'nextCrSeq' must be a positive integer, got {next_cr_seq!r}")
    else:
        if verbose:
            print(f"  PASS [check1]: nextCrSeq = {next_cr_seq}")

    # Can't do further CR-level checks if crs[] is invalid
    if not isinstance(crs, list):
        return errors

    # ── Check 2: every CR record has required fields ──────────────────────────
    valid_cr_states = set(schema.get("crStates", []))
    cr_by_id: dict = {}
    cr_required_fields = ["id", "title", "type", "crState", "itemIds"]

    for i, cr in enumerate(crs):
        if not isinstance(cr, dict):
            errors.append(f"FAIL [check2]: crs[{i}] is not an object ({type(cr).__name__})")
            continue

        cr_id = cr.get("id", f"<crs[{i}]>")
        missing = [f for f in cr_required_fields if f not in cr]
        if missing:
            errors.append(f"FAIL [check2]: CR '{cr_id}' is missing required fields: {missing}")
        else:
            if verbose:
                print(f"  PASS [check2]: CR '{cr_id}' has all required fields")

        # Validate crState is a known state. This is schema-driven — crStates
        # already lists "cr-published" (XACA-0895), so no hardcoded addition
        # is needed here; the enum check below accepts it automatically as
        # soon as the schema file does.
        cr_state = cr.get("crState")
        if cr_state and valid_cr_states and cr_state not in valid_cr_states:
            errors.append(
                f"FAIL [check2]: CR '{cr_id}' has invalid crState '{cr_state}'. "
                f"Must be one of: {sorted(valid_cr_states)}"
            )

        # Validate itemIds is a list
        item_ids = cr.get("itemIds")
        if item_ids is not None and not isinstance(item_ids, list):
            errors.append(f"FAIL [check2]: CR '{cr_id}'.itemIds must be an array, got {type(item_ids).__name__}")

        # Validate optional Phase 4 automation idempotency key fields (XACA-0294)
        # Both are optional; if present they must be non-empty ISO 8601 UTC strings.
        for iso_field in ("cr_drafted_reminder_last_at", "delay_flagged_at"):
            val = cr.get(iso_field)
            if val is not None:
                if not isinstance(val, str) or not _is_iso8601_utc(val):
                    errors.append(
                        f"FAIL [check2]: CR '{cr_id}'.{iso_field} must be a non-empty ISO 8601 UTC "
                        f"string (e.g. 2026-05-15T22:00:00Z), got {val!r}"
                    )
                elif verbose:
                    print(f"  PASS [check2]: CR '{cr_id}'.{iso_field} = {val!r}")

        # Validate optional Phase-4 automation timestamp fields (schema v2.1/v2.2)
        # These fields are idempotency keys written by daemon processes.
        # If present they must be valid ISO 8601 UTC strings; absent is fine.
        #
        # cr_published_at (XACA-0896-001, Guard 4) is deliberately NOT in this
        # list. It originally was, checked here as a flat field on the
        # container — that was wrong, and XACA-0896-001-fix removed it:
        # cr_published_at is a lifecycle timestamp, not a flat idempotency
        # key, so it lives at .timestamps.cr_published_at like every other
        # lifecycle instant in this schema, not flat on `cr`. XACA-0895's
        # check7 owns validating it at that nested path — this check must
        # not also validate a flat sibling that no longer exists in the
        # schema, or a stray flat field would pass here while the guards
        # that actually consult cr_published_at (which read the nested path
        # exclusively — see kb-cr.sh's _kb_cr_get_publish_stamps) ignore it.
        _optional_iso_fields = (
            "cr_drafted_reminder_last_at",
            # XACA-0895: cr-published's own reminder idempotency key. Deliberately
            # a SEPARATE field from cr_drafted_reminder_last_at (see
            # cr-lifecycle-monitor.py's REMINDER_STATE_CONFIG and CR_WORKFLOW.md)
            # — the two pre-submission states do not share a clock, so the
            # validator must know about both or this one goes unchecked.
            "cr_published_reminder_last_at",
            "delay_flagged_at",
            "cr_approval_candidate_at",
        )
        for field in _optional_iso_fields:
            val = cr.get(field)
            if val is not None:
                if not isinstance(val, str) or not _is_iso8601_utc(val):
                    errors.append(
                        f"FAIL [check2b]: CR '{cr_id}'.{field} = {val!r} "
                        f"is not a valid ISO 8601 UTC string "
                        f"(expected format: YYYY-MM-DDTHH:MM:SSZ)"
                    )
                elif verbose:
                    print(f"  PASS [check2b]: CR '{cr_id}'.{field} = {val!r} is valid ISO 8601")

        # Build id index for cross-reference checks
        if isinstance(cr.get("id"), str):
            cr_by_id[cr["id"]] = cr

    # ── Check 3: every item with crAssignment.crId references a known CR ─────
    # Also build set of all item IDs for reverse check
    all_item_ids: set = set()
    items_with_assignment: dict = {}  # item_id -> crId

    for container_key in ["backlog", "items", "active", "inProgress", "inReview",
                          "done", "completed", "cancelled", "paused", "blocked"]:
        container = board.get(container_key)
        if not isinstance(container, list):
            continue
        for item in container:
            if not isinstance(item, dict):
                continue
            item_id = item.get("id", "")
            if item_id:
                all_item_ids.add(item_id)

            assignment = item.get("crAssignment")
            if assignment is None:
                continue
            if not isinstance(assignment, dict):
                errors.append(f"FAIL [check3]: item '{item_id}'.crAssignment must be an object")
                continue

            cr_id_ref = assignment.get("crId", "")
            if not cr_id_ref:
                errors.append(f"FAIL [check3]: item '{item_id}'.crAssignment.crId is empty")
                continue

            if cr_id_ref not in cr_by_id:
                errors.append(
                    f"FAIL [check3]: item '{item_id}'.crAssignment.crId='{cr_id_ref}' "
                    f"references a CR that does not exist in crs[]"
                )
            else:
                if verbose:
                    print(f"  PASS [check3]: item '{item_id}' references known CR '{cr_id_ref}'")
            items_with_assignment[item_id] = cr_id_ref

    # ── Check 4: every CR's itemIds[] references items that exist ─────────────
    for cr in crs:
        if not isinstance(cr, dict):
            continue
        cr_id = cr.get("id", "<unknown>")
        item_ids_list = cr.get("itemIds", [])
        if not isinstance(item_ids_list, list):
            continue
        for item_id_ref in item_ids_list:
            if not isinstance(item_id_ref, str):
                errors.append(f"FAIL [check4]: CR '{cr_id}'.itemIds contains non-string: {item_id_ref!r}")
                continue
            if item_id_ref not in all_item_ids:
                errors.append(
                    f"FAIL [check4]: CR '{cr_id}'.itemIds references item '{item_id_ref}' "
                    f"which does not exist on the board"
                )
            else:
                if verbose:
                    print(f"  PASS [check4]: CR '{cr_id}' itemIds['{item_id_ref}'] is a known item")

    # ── Check 5: no item has BOTH crAssignment AND deprecated cr_* fields ─────
    deprecated_cr_fields = {
        "cr_id", "cr_type", "crState", "cr_approved_by", "cr_approver_name",
        "cr_pushback_count", "cr_pushback_notes", "cr_summary", "cr_doc_link",
        "deploy_window_planned", "emergency_justification",
        "cr_created_at", "cr_submitted_at", "cr_approved_at",
        "cr_dev_started_at", "cr_testing_started_at",
        "cr_deployed_dev_at", "cr_deployed_prod_at",
        "cr_emergency_deployed_at", "cr_completed_at",
    }
    for container_key in ["backlog", "items", "active", "inProgress", "inReview",
                          "done", "completed", "cancelled", "paused", "blocked"]:
        container = board.get(container_key)
        if not isinstance(container, list):
            continue
        for item in container:
            if not isinstance(item, dict):
                continue
            item_id = item.get("id", "?")
            if not item.get("crAssignment"):
                continue
            present_deprecated = [k for k in deprecated_cr_fields if item.get(k) not in (None, "", 0)]
            if present_deprecated:
                errors.append(
                    f"FAIL [check5]: item '{item_id}' has crAssignment AND deprecated cr_* fields: "
                    f"{present_deprecated} — run migrate-cr-schema.py to clean up"
                )
            else:
                if verbose:
                    print(f"  PASS [check5]: item '{item_id}' has no deprecated cr_* fields alongside crAssignment")

    # ── Check 6: nextCrSeq > max(crs[*] sequence numbers) ────────────────────
    if isinstance(next_cr_seq, int) and isinstance(crs, list) and crs:
        seqs = []
        for cr in crs:
            if not isinstance(cr, dict):
                continue
            cr_id = cr.get("id", "")
            if not isinstance(cr_id, str):
                continue
            parts = cr_id.rsplit("-", 1)
            if len(parts) == 2:
                try:
                    seqs.append(int(parts[1]))
                except ValueError:
                    pass
        if seqs:
            max_seq = max(seqs)
            if next_cr_seq <= max_seq:
                errors.append(
                    f"FAIL [check6]: nextCrSeq={next_cr_seq} is not greater than max CR sequence={max_seq} "
                    f"— ID collision risk"
                )
            else:
                if verbose:
                    print(f"  PASS [check6]: nextCrSeq={next_cr_seq} > max_seq={max_seq}")

    # ── Check 7: a CR at state X must carry X's entry timestamp (XACA-0924) ──
    # Generalised from the cr-published-only form this check shipped with in
    # XACA-0895. The narrow version asked the past about exactly ONE state, so
    # a record laundered into cr-approved with zero approval evidence validated
    # clean — the validator was a spell-checker, not a laundering detector.
    #
    # STATE_ENTRY_TS is the same state -> entry-timestamp map that
    # _kb_cr_state_entry_ts_field() implements in scripts/kb-cr.sh. The two are
    # kept in sync BY HAND (kb-cr.sh's own header says the same about its two
    # sibling maps) — adding a crState means extending both.
    #
    # cr-drafted maps to None: it stamps no entry timestamp (its moment is
    # cr_created_at, written by `kb-cr create`), so there is nothing to require.
    #
    # SEVERITY SPLIT — see the block comment on check8 below. Measured, not
    # assumed: across the 6 real team boards (45 CRs) this check finds 0
    # violations at live states and 1 at cr-closed.
    for cr in crs:
        if not isinstance(cr, dict):
            continue
        state = cr.get("crState")
        if state not in STATE_ENTRY_TS:
            continue                      # unknown state — check2's problem
        entry_field = STATE_ENTRY_TS[state]
        if entry_field is None:
            continue                      # cr-drafted stamps nothing on entry
        cr_id = cr.get("id", "<unknown>")
        cr_ts = cr.get("timestamps")
        value = cr_ts.get(entry_field) if isinstance(cr_ts, dict) else None
        if not isinstance(value, str) or not _is_iso8601_utc(value):
            msg = (
                f"CR '{cr_id}' has crState='{state}' but "
                f"timestamps.{entry_field} is missing/invalid — got {value!r} "
                f"(expected ISO 8601 UTC, e.g. 2026-05-15T22:00:00Z)"
            )
            if state == _TERMINAL_STATE:
                warnings.append(f"WARN [check7]: {msg} — closed history, not blocking")
            else:
                errors.append(f"FAIL [check7]: {msg}")
        elif verbose:
            print(f"  PASS [check7]: CR '{cr_id}' {state} has valid {entry_field}={value!r}")

    # ── Check 8: evidence monotonicity — later rank implies earlier (XACA-0924)
    # THIS is the check that actually detects laundering. check7 asks "does the
    # state you are AT have its own timestamp"; a forced write that stamps the
    # target state's timestamp satisfies that trivially. check8 asks the
    # question authorization actually depends on: "did this CR ever legitimately
    # REACH here?" A record carrying deployed-prod evidence with no approval
    # evidence is incoherent — no sequence of the documented lifecycle verbs can
    # produce it — and incoherent is the signature of a force-write that skipped
    # the ranks in between.
    #
    # EVIDENCE_PREREQS mirrors the predecessor states each `kb-cr` verb already
    # enforces (kb-cr.sh's "Predecessor states:" header comments), so it encodes
    # the shipped lifecycle rather than a stricter one invented here:
    #   * approve/reject/hold are reachable only from cr-submitted
    #     -> those three timestamps require cr_submitted_at.
    #   * start-dev/deploy-dev are reachable only from cr-approved (deploy-dev
    #     also from implementing) -> require cr_approved_at, and transitively
    #     cr_submitted_at.
    #   * deploy-prod is reachable from deployed-dev OR, with a warning, direct
    #     from cr-approved -> requires cr_approved_at but deliberately NOT
    #     cr_deployed_dev_at, because skipping dev is a documented path.
    # Deliberately absent, and each for a reason rather than an oversight:
    #   * cr_published_at — rank 5, BELOW cr-submitted. Publishing a draft to
    #     Confluence is not submitting it for review, and XACA-0465's one-stage
    #     path reaches a Confluence page without `kb-cr publish` at all. It has
    #     no prerequisite, so it can never be incoherent.
    #   * cr_emergency_deployed_at — break-glass. `kb-cr emergency-deploy` is
    #     documented as "allowed from any state"; requiring approval evidence
    #     would flag the one path whose entire purpose is bypassing approval.
    #     Its audit trail is emergency_justification, not a predecessor.
    #   * cr_closed_at — `kb-cr close` is reachable from any state.
    #
    # SEVERITY SPLIT (both checks): a violation on a CR at a LIVE state is an
    # error; the same violation on a cr-closed CR is a warning. Measured across
    # the 6 real team boards: 0 violations at live states, 52 at cr-closed. The
    # closed ones are the pre-XACA-0297 data debt that ticket documented (CRs
    # reached cr-closed carrying almost no timestamps) — real history, not
    # laundering, and failing on it would make this validator red everywhere on
    # day one and therefore ignored. cr-closed is also terminal and grants
    # nothing. Errors are reserved for live states, where the boards are clean
    # today, so a FAIL here means something new and wrong — which is the only
    # way a backstop stays worth reading.
    for cr in crs:
        if not isinstance(cr, dict):
            continue
        cr_ts = cr.get("timestamps")
        if not isinstance(cr_ts, dict):
            continue
        state = cr.get("crState")
        cr_id = cr.get("id", "<unknown>")
        for field, prereqs in EVIDENCE_PREREQS:
            if not cr_ts.get(field):
                continue
            # OR-group aware (XACA-1239, D2): a prereq entry may be a single
            # field or a "|"-joined token. It is satisfied if ANY member is
            # present; when none is, the FULL token — not one member — is what
            # gets reported, so a reader sees every alternative that was
            # accepted (e.g. "cr_approved_at|cr_approval_waived_at" names both
            # a real approval and a recorded waiver as valid evidence).
            missing = [
                p for p in prereqs
                if not any(cr_ts.get(member) for member in p.split("|"))
            ]
            if not missing:
                continue
            msg = (
                f"CR '{cr_id}' (crState='{state}') carries "
                f"timestamps.{field} but is missing the earlier evidence it "
                f"implies: {', '.join(missing)} — no documented kb-cr verb "
                f"sequence produces this shape"
            )
            if state == _TERMINAL_STATE:
                warnings.append(f"WARN [check8]: {msg} — closed history, not blocking")
            else:
                errors.append(f"FAIL [check8]: {msg}")

    # ── Check 9: a waiver timestamp must carry its record (XACA-1239) ────────
    # cr_approval_waived_at satisfies the approval OR-group in check8, so on its
    # own it would let a bare timestamp stand in for an approval with no reason
    # and no actor — exactly the unexplained shape the waiver exists to replace.
    # The only writer (_kb_cr_waive_approval in kb-cr.sh) sets the timestamp and
    # approvalWaiver{reason,actor,at} in one jq write, so a timestamp without a
    # complete record means hand edits or a partial write, never a verb. The
    # reverse (record without timestamp) is already caught by check8, because
    # only the timestamp satisfies the OR-group. Same severity split as check7/8.
    for cr in crs:
        if not isinstance(cr, dict):
            continue
        cr_ts = cr.get("timestamps")
        if not isinstance(cr_ts, dict) or not cr_ts.get("cr_approval_waived_at"):
            continue
        waiver = cr.get("approvalWaiver")
        problems = []
        if not isinstance(waiver, dict):
            problems.append("approvalWaiver record is missing")
        else:
            for key in ("reason", "actor"):
                val = waiver.get(key)
                if not isinstance(val, str) or not val.strip():
                    problems.append(f"approvalWaiver.{key} is missing/blank")
        if not problems:
            continue
        state = cr.get("crState")
        cr_id = cr.get("id", "<unknown>")
        msg = (
            f"CR '{cr_id}' (crState='{state}') carries "
            f"timestamps.cr_approval_waived_at but {'; '.join(problems)} — "
            f"a waiver must record who waived approval and why"
        )
        if state == _TERMINAL_STATE:
            warnings.append(f"WARN [check9]: {msg} — closed history, not blocking")
        else:
            errors.append(f"FAIL [check9]: {msg}")

    for w in warnings:
        print(f"  {w}")

    return errors


def main() -> int:
    args = sys.argv[1:]
    board_path_str = None
    schema_path_str = None
    verbose = False

    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--schema" and i + 1 < len(args):
            schema_path_str = args[i + 1]
            i += 2
        elif arg.startswith("--schema="):
            schema_path_str = arg[len("--schema="):]
            i += 1
        elif arg == "--verbose" or arg == "-v":
            verbose = True
            i += 1
        elif not arg.startswith("--"):
            board_path_str = arg
            i += 1
        else:
            print(f"ERROR: unknown argument: {arg}", file=sys.stderr)
            return 1

    if not board_path_str:
        print("Usage: cr-schema-validator.py <board.json> [--schema <cr-schema.json>] [--verbose]",
              file=sys.stderr)
        return 1

    board_path = Path(board_path_str)
    schema_path = Path(schema_path_str) if schema_path_str else _DEFAULT_SCHEMA

    if not schema_path.exists():
        # Try the main repo path as fallback when running from a worktree
        import subprocess
        try:
            git_common = subprocess.check_output(
                ["git", "rev-parse", "--git-common-dir"],
                cwd=str(Path(__file__).parent),
                stderr=subprocess.DEVNULL,
                text=True,
            ).strip()
            main_repo = Path(git_common).parent
            fallback = main_repo / "homebrew-tap" / "share" / "templates" / "kanban" / "cr-schema.json"
            if fallback.exists():
                schema_path = fallback
        except (subprocess.SubprocessError, OSError):
            pass

    schema = _load_json(schema_path)
    board = _load_json(board_path)

    print(f"Validating: {board_path}")
    print(f"Schema:     {schema_path}")
    print()

    errors = validate_board(board, schema, str(board_path), verbose=verbose)

    if errors:
        print(f"RESULT: FAIL — {len(errors)} error(s)")
        for err in errors:
            print(f"  {err}")
        return 1

    print(f"RESULT: PASS — all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
