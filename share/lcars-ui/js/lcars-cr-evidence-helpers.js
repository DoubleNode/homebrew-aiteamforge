//
//  lcars-cr-evidence-helpers.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * lcars-cr-evidence-helpers.js — EDIT STATE prerequisite-gap helpers (XACA-1239-005)
 *
 * Pure-JS module (browser + Node-loadable), same pattern as
 * lcars-cr-age-helpers.js: no DOM access, no network, dependency-free, so
 * it is unit-testable in isolation and does not become a fifth hand-copied
 * evidence map (XACA-1239, D4 — kb-cr.sh:846 already documents four).
 *
 * The EDIT STATE modal (lcars-cr-tab.js) fetches GET /api/kanban/cr/evidence-map
 * (server.py::handle_cr_evidence_map, DERIVED from scripts/cr-schema-validator.py)
 * and hands the response — `{states: {<crState>: [token, ...]}, orSeparator, source}`
 * — plus a raw CR record to the functions here to work out, per target state:
 *   - which prerequisite tokens are missing (_crMissingEvidence)
 *   - whether the ONLY gap is the approval OR-group, i.e. this target is
 *     eligible for an approval WAIVER instead of a real approval
 *     (_crApprovalOnlyGap)
 *   - human-readable labels for missing tokens (_crEvidenceTokenLabel /
 *     _crMissingEvidenceLabels)
 *   - the combined decision object the modal renders from (_crGapInfo)
 *   - whether SUBMIT should be enabled, and what payload to send, given the
 *     gap and the operator's typed waiver reason (_crWaiverSubmitAllowed /
 *     _crWaiverPayloadFields) — kept here, not in lcars-cr-tab.js, so the
 *     SUBMIT-enablement and payload-shape rules are testable without a DOM.
 *
 * A token is either a plain `timestamps.<field>` name (e.g. "cr_submitted_at")
 * or an "a|b" OR-group (e.g. "cr_approved_at|cr_approval_waived_at") — the
 * separator is read from evidenceMap.orSeparator (server-supplied, default
 * "|"), never hardcoded past that default, mirroring scripts/kb-cr.sh's own
 * notation (XACA-1239, D2).
 *
 * Public API (window.lcarsCrEvidenceHelpers, also module.exports):
 *   DEFAULT_WAIVER_REASON
 *     The exact pre-filled, editable default reason text (XACA-1239, D3).
 *     Single source of truth — lcars-cr-tab.js reads this rather than
 *     duplicating the literal string.
 *
 *   _crMissingEvidence(cr, state, evidenceMap)
 *     Returns the list of tokens from evidenceMap.states[state] that are
 *     NOT satisfied by cr.timestamps. A plain token is satisfied when
 *     cr.timestamps[token] is a non-blank string. An OR-group token is
 *     satisfied when ANY ONE of its "|"-split members is non-blank in
 *     cr.timestamps. Returns [] when the map or the state's token list is
 *     absent (nothing to report as missing — the caller decides how to
 *     treat "no map" as "unavailable", not "zero prerequisites").
 *
 *   _crApprovalOnlyGap(missing, orSeparator)
 *     True when `missing` is non-empty and EVERY missing token's "|"-split
 *     member list contains "cr_approval_waived_at" — i.e. the only thing
 *     standing between this CR and the target state is approval evidence,
 *     which a waiver can supply.
 *
 *   _crEvidenceTokenLabel(token, orSeparator)
 *     Human label for a single token, e.g. "cr_submitted_at" -> "submission",
 *     the approval OR-group -> "approval". Falls back to a generic
 *     derivation (strip "cr_"/"_at", underscores -> spaces) for any token
 *     not in the small named table, so a new prerequisite the validator
 *     adds later degrades to a readable label instead of "undefined".
 *
 *   _crMissingEvidenceLabels(missing, orSeparator)
 *     Unique human labels for a `missing` list, in token order.
 *
 *   _crWaiverAllowedForCrState(crState)
 *     XACA-1239-019 (D3): a waiver may only be RECORDED while the CR's
 *     CURRENT state is 'cr-submitted' or 'cr-held'. This is independent of
 *     approvalOnlyGap — approvalOnlyGap asks "is approval evidence the only
 *     thing missing for the TARGET state"; this asks "is the CR's PRESENT
 *     state one the server will actually accept a waiver write from". A
 *     --force'd CR sitting in 'implementing' (or any state reached via
 *     --force / a rejection) can have an approval-only gap toward, say,
 *     'deployed-dev' while NOT being waiver-eligible at all — the server's
 *     _kb_cr_waive_approval refuses from any other state (kb-cr.sh), and
 *     before this fix the modal offered the waiver anyway, the write failed,
 *     and the transition endpoint answered 500.
 *
 *   _crGapInfo(cr, state, evidenceMap)
 *     Combines the above into one decision object:
 *       { mapAvailable, missing, approvalOnlyGap, missingLabels, waiverAllowed }
 *     mapAvailable is false when evidenceMap itself is falsy (map failed to
 *     load / not yet loaded) — every other field is then a safe empty
 *     default so a caller that forgets to check mapAvailable still reads
 *     "no gap" rather than crashing. waiverAllowed reflects ONLY cr.crState
 *     (via _crWaiverAllowedForCrState) — it does not depend on
 *     approvalOnlyGap, so a caller can distinguish "no gap at all" from "gap
 *     is approval-only but this CR's current state can't record a waiver".
 *
 *   _crWaiverSubmitAllowed(gapInfo, reasonText)
 *     The EVIDENCE-GAP portion of the modal's SUBMIT-enablement decision
 *     (the DOM-facing per-field required/format checks stay in
 *     lcars-cr-tab.js — this only answers "does the evidence gap block
 *     submit"): true when the map is unavailable (server remains the
 *     backstop) or there is no gap; false when the gap is not approval-only
 *     (no waiver is offered for those); false when the gap IS approval-only
 *     but gapInfo.waiverAllowed is false (XACA-1239-019 — the CR's current
 *     state can't record a waiver, so no reason text can unblock this);
 *     otherwise true only once reasonText is non-blank after trim.
 *
 *   _crWaiverPayloadFields(gapInfo, reasonText, baseFields)
 *     Returns a NEW fields object (baseFields is never mutated) with
 *     `approval_waiver: {reason}` added when gapInfo.approvalOnlyGap AND
 *     gapInfo.waiverAllowed are both true and reasonText trims non-blank
 *     (XACA-1239-019 — never send a waiver the server will refuse). Also
 *     strips any `approver` key from the result in that case — defense in
 *     depth, since the server rejects approval_waiver combined with
 *     approver (XACA-1239, D5) and no approval-only-gap target renders an
 *     approver field today, but a future one might.
 *
 * No DOM access. No network. Dependency-free.
 */

'use strict';

(function () {

    // ─── Default waiver reason (XACA-1239, D3) ──────────────────────────────

    var DEFAULT_WAIVER_REASON =
        'No approval notice received — IT Connect approval signal not integrated (XACA-0899).';

    // ─── Missing-evidence computation ───────────────────────────────────────

    function crMissingEvidence(cr, state, evidenceMap) {
        if (!evidenceMap || !evidenceMap.states) return [];
        var tokens = evidenceMap.states[state];
        if (!Array.isArray(tokens) || tokens.length === 0) return [];
        var sep = evidenceMap.orSeparator || '|';
        var ts = (cr && cr.timestamps) || {};
        var missing = [];
        tokens.forEach(function (token) {
            var members = String(token).split(sep);
            var satisfied = members.some(function (m) {
                var v = ts[m];
                return v !== undefined && v !== null && String(v).trim() !== '';
            });
            if (!satisfied) missing.push(token);
        });
        return missing;
    }

    // ─── Approval-only-gap test ──────────────────────────────────────────────

    function crApprovalOnlyGap(missing, orSeparator) {
        var sep = orSeparator || '|';
        if (!Array.isArray(missing) || missing.length === 0) return false;
        return missing.every(function (token) {
            return String(token).split(sep).indexOf('cr_approval_waived_at') !== -1;
        });
    }

    // ─── Waiver-allowed-from-current-state test (XACA-1239-019, D3) ────────────

    // D3: "Allowed only from cr-submitted or cr-held". Kept as a small named
    // set (mirrors TOKEN_LABELS below) rather than importing kb-cr.sh's own
    // state list — this file stays dependency-free and Node-loadable.
    var WAIVER_ALLOWED_CR_STATES = { 'cr-submitted': true, 'cr-held': true };

    function crWaiverAllowedForCrState(crState) {
        return Object.prototype.hasOwnProperty.call(WAIVER_ALLOWED_CR_STATES, crState);
    }

    // ─── Human labels ─────────────────────────────────────────────────────────

    // Small named table for the tokens operators actually see today. Anything
    // else falls through to the generic derivation below — this table is
    // deliberately NOT meant to be exhaustive (D6: "derive labels from token
    // names generically where possible, small label table OK").
    var TOKEN_LABELS = {
        'cr_submitted_at':                             'submission',
        'cr_approved_at|cr_approval_waived_at':        'approval',
        'cr_started_dev_at':                           'implementing',
        'cr_started_test_at':                          'testing',
        'cr_deployed_dev_at':                           'dev deployment',
        'cr_deployed_prod_at':                          'prod deployment',
        'cr_published_at':                              'publish',
        'cr_held_at':                                   'hold',
        'cr_rejected_at':                               'rejection',
        'cr_emergency_deployed_at':                     'emergency deployment',
    };

    function crEvidenceTokenLabel(token, orSeparator) {
        var sep = orSeparator || '|';
        if (Object.prototype.hasOwnProperty.call(TOKEN_LABELS, token)) {
            return TOKEN_LABELS[token];
        }
        if (String(token).indexOf(sep) !== -1) {
            var members = String(token).split(sep);
            var nonWaiver = members.filter(function (m) { return m !== 'cr_approval_waived_at'; });
            if (nonWaiver.length > 0) return crEvidenceTokenLabel(nonWaiver[0], sep);
        }
        return String(token)
            .replace(/^timestamps\./, '')
            .replace(/^cr_/, '')
            .replace(/_at$/, '')
            .replace(/_/g, ' ');
    }

    function crMissingEvidenceLabels(missing, orSeparator) {
        var seen = {};
        var labels = [];
        (missing || []).forEach(function (token) {
            var label = crEvidenceTokenLabel(token, orSeparator);
            if (!Object.prototype.hasOwnProperty.call(seen, label)) {
                seen[label] = true;
                labels.push(label);
            }
        });
        return labels;
    }

    // ─── Combined decision object ────────────────────────────────────────────

    function crGapInfo(cr, state, evidenceMap) {
        if (!evidenceMap) {
            return { mapAvailable: false, missing: [], approvalOnlyGap: false, missingLabels: [], waiverAllowed: false };
        }
        var sep = evidenceMap.orSeparator || '|';
        var missing = crMissingEvidence(cr, state, evidenceMap);
        return {
            mapAvailable:    true,
            missing:         missing,
            approvalOnlyGap: crApprovalOnlyGap(missing, sep),
            missingLabels:   crMissingEvidenceLabels(missing, sep),
            waiverAllowed:   crWaiverAllowedForCrState(cr && cr.crState),
        };
    }

    // ─── SUBMIT enablement (evidence-gap portion only) ──────────────────────

    function crWaiverSubmitAllowed(gapInfo, reasonText) {
        if (!gapInfo || !gapInfo.mapAvailable) return true;     // map unavailable — server is the backstop
        if (!gapInfo.missing || gapInfo.missing.length === 0) return true; // no gap
        if (!gapInfo.approvalOnlyGap) return false;              // blocked — no waiver offered
        if (!gapInfo.waiverAllowed) return false;                // blocked — CR's current state can't record a waiver (XACA-1239-019)
        return !!(reasonText && String(reasonText).trim().length > 0);
    }

    // ─── Payload assembly ─────────────────────────────────────────────────────

    function crWaiverPayloadFields(gapInfo, reasonText, baseFields) {
        var fields = {};
        var src = baseFields || {};
        Object.keys(src).forEach(function (k) { fields[k] = src[k]; });
        if (gapInfo && gapInfo.mapAvailable && gapInfo.approvalOnlyGap && gapInfo.waiverAllowed) {
            var reason = (reasonText || '').toString().trim();
            if (reason) {
                fields.approval_waiver = { reason: reason };
                if (fields.approver) delete fields.approver;
            }
        }
        return fields;
    }

    // ─── Module assembly ──────────────────────────────────────────────────────

    var lcarsCrEvidenceHelpers = {
        DEFAULT_WAIVER_REASON:       DEFAULT_WAIVER_REASON,
        _crMissingEvidence:          crMissingEvidence,
        _crApprovalOnlyGap:          crApprovalOnlyGap,
        _crWaiverAllowedForCrState:  crWaiverAllowedForCrState,
        _crEvidenceTokenLabel:       crEvidenceTokenLabel,
        _crMissingEvidenceLabels:    crMissingEvidenceLabels,
        _crGapInfo:                  crGapInfo,
        _crWaiverSubmitAllowed:      crWaiverSubmitAllowed,
        _crWaiverPayloadFields:      crWaiverPayloadFields,
    };

    // Browser export (loaded via <script> before lcars-cr-tab.js)
    if (typeof window !== 'undefined') {
        window.lcarsCrEvidenceHelpers = lcarsCrEvidenceHelpers;
    }

    // Node export so unit tests can require() this file directly
    if (typeof module !== 'undefined' && module.exports) {
        module.exports = lcarsCrEvidenceHelpers;
    }

}());
