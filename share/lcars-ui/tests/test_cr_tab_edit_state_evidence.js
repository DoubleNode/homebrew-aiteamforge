//
//  test_cr_tab_edit_state_evidence.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * test_cr_tab_edit_state_evidence.js — Node-native tests for XACA-1239-005
 * (EDIT STATE modal: evidence-aware target states + APPROVAL NOT RECEIVED
 * waiver section + waived indicator).
 *
 * Two subjects, two techniques:
 *
 *   (A) lcars-ui/js/lcars-cr-evidence-helpers.js — a plain Node-loadable
 *       module (window.lcarsCrEvidenceHelpers / module.exports, same pattern
 *       as lcars-cr-age-helpers.js). require()'d directly.
 *
 *   (B) lcars-ui/js/lcars-cr-tab.js — a browser-only IIFE with no
 *       module.exports. Following this repo's own established precedent
 *       (lcars-ui/tests/test_cr_tab_publish_regression.js), the pure /
 *       DOM-light source slices under test are extracted from the SHIPPED
 *       file by unique start/end text markers and evaluated in a vm
 *       context — never reimplemented by hand, which would test a copy of
 *       the logic instead of the logic itself. If a marker goes missing
 *       (the surrounding code was refactored) extraction fails loudly.
 *
 * Fixture generation (per the subitem brief: "avoid a hand-written map that
 * can drift"): the evidence-map fixture used below is NOT hand-typed. It is
 * derived at test-run time by running the EXACT mechanical rule
 * server.py::_derive_cr_evidence_map documents (STATE_ENTRY_TS row ->
 * EVIDENCE_PREREQS lookup) against the REAL, current
 * scripts/cr-schema-validator.py in this worktree, via a python3 child
 * process. This file does not import lcars-ui/server.py directly: that
 * module needs a substantial stub-module scaffold to import safely
 * (kanban_utils, integrations, calendar.*, etc. — see
 * lcars-ui/tests/test_xaca1239_evidence_map_and_waiver.py, which owns
 * pinning server.py's OWN derivation against the shell map). This file's
 * job is different: given whatever shape that derivation produces, does the
 * MODAL consume it correctly? So it re-derives the same small, documented
 * rule directly from the validator file's own STATE_ENTRY_TS +
 * EVIDENCE_PREREQS dicts — the authoritative source both the endpoint and
 * scripts/kb-cr.sh's _kb_cr_state_required_evidence() are derived from —
 * rather than duplicating server.py's stub-heavy import machinery.
 *
 * XACA-1019 note: this file reads scripts/cr-schema-validator.py from THIS
 * WORKTREE (REPO_ROOT resolved from __dirname), never a default ~/dev-team
 * resolution — see memory feedback_source_worktree_helpers_not_since_...
 *
 * Usage:
 *   node --test lcars-ui/tests/test_cr_tab_edit_state_evidence.js
 *
 * No external dependencies beyond `python3` on PATH. Node ≥18 required
 * (node:test, node:vm built-in).
 */

'use strict';

var test   = require('node:test');
var assert = require('node:assert/strict');
var path   = require('path');
var fs     = require('fs');
var vm     = require('vm');
var { execFileSync } = require('node:child_process');

// ─── Load lcars-cr-evidence-helpers.js (Node-loadable, real module) ───────────

var HELPERS_PATH = path.join(__dirname, '../js/lcars-cr-evidence-helpers.js');
var helpers = require(HELPERS_PATH);

var _crMissingEvidence       = helpers._crMissingEvidence;
var _crApprovalOnlyGap       = helpers._crApprovalOnlyGap;
var _crEvidenceTokenLabel    = helpers._crEvidenceTokenLabel;
var _crMissingEvidenceLabels = helpers._crMissingEvidenceLabels;
var _crGapInfo               = helpers._crGapInfo;
var _crWaiverSubmitAllowed   = helpers._crWaiverSubmitAllowed;
var _crWaiverPayloadFields   = helpers._crWaiverPayloadFields;

// ─── Derive the REAL evidence map from scripts/cr-schema-validator.py ─────────
// (mirrors server.py::_derive_cr_evidence_map's documented mechanical rule —
// see the file header comment above for why this doesn't import server.py)

var REPO_ROOT     = path.join(__dirname, '..', '..');
var VALIDATOR_PY  = path.join(REPO_ROOT, 'scripts', 'cr-schema-validator.py');

var DERIVE_SNIPPET = [
    'import importlib.util, json, sys',
    "spec = importlib.util.spec_from_file_location('crval', sys.argv[1])",
    'mod = importlib.util.module_from_spec(spec)',
    'spec.loader.exec_module(mod)',
    'prereqs = dict(mod.EVIDENCE_PREREQS)',
    'states = {}',
    'for state, entry_field in mod.STATE_ENTRY_TS.items():',
    '    states[state] = list(prereqs.get(entry_field, ())) if entry_field else []',
    "print(json.dumps({'states': states, 'orSeparator': '|', 'source': 'cr-schema-validator.py'}))",
].join('\n');

var EVIDENCE_MAP;
try {
    var out = execFileSync('python3', ['-c', DERIVE_SNIPPET, VALIDATOR_PY], { encoding: 'utf8' });
    EVIDENCE_MAP = JSON.parse(out);
} catch (e) {
    throw new Error(
        'Could not derive the real evidence map from ' + VALIDATOR_PY +
        ' via python3 — is python3 on PATH, and does scripts/cr-schema-validator.py ' +
        'still define STATE_ENTRY_TS + EVIDENCE_PREREQS? Underlying error: ' + e.message
    );
}

test('sanity: derived evidence map has the expected shape and matches measured XACA-1239 D2 OR-groups', () => {
    assert.ok(EVIDENCE_MAP && EVIDENCE_MAP.states, 'Expected a {states: {...}} map');
    assert.equal(EVIDENCE_MAP.orSeparator, '|');
    assert.deepEqual(EVIDENCE_MAP.states['cr-drafted'], []);
    assert.deepEqual(EVIDENCE_MAP.states['cr-submitted'], []);
    assert.deepEqual(EVIDENCE_MAP.states['implementing'],
        ['cr_submitted_at', 'cr_approved_at|cr_approval_waived_at']);
    assert.deepEqual(EVIDENCE_MAP.states['deployed-dev'],
        ['cr_submitted_at', 'cr_approved_at|cr_approval_waived_at']);
    assert.deepEqual(EVIDENCE_MAP.states['deployed-prod'],
        ['cr_submitted_at', 'cr_approved_at|cr_approval_waived_at']);
    assert.deepEqual(EVIDENCE_MAP.states['cr-approved'], ['cr_submitted_at']);
});

// ─── Fixture CRs (raw records — cr.timestamps shape, per cr-schema.json) ──────

function crSubmittedOnly() {
    return {
        id: 'CR-FIXTURE-SUBMITTED',
        crState: 'cr-submitted',
        timestamps: {
            cr_created_at:   '2026-09-01T00:00:00Z',
            cr_published_at: '2026-09-02T00:00:00Z',
            cr_submitted_at: '2026-09-03T00:00:00Z',
        },
    };
}

function crDraftedOnly() {
    return {
        id: 'CR-FIXTURE-DRAFTED',
        crState: 'cr-drafted',
        timestamps: {
            cr_created_at: '2026-09-01T00:00:00Z',
        },
    };
}

function crSubmittedAndWaived() {
    return {
        id: 'CR-FIXTURE-WAIVED',
        crState: 'cr-submitted',
        timestamps: {
            cr_created_at:         '2026-09-01T00:00:00Z',
            cr_submitted_at:       '2026-09-03T00:00:00Z',
            cr_approval_waived_at: '2026-09-04T00:00:00Z',
        },
        approvalWaiver: { reason: 'No approval notice received.', actor: 'jsmith', at: '2026-09-04T00:00:00Z' },
    };
}

// ─── (A) _crMissingEvidence / _crApprovalOnlyGap — the two named pure helpers ──

test('_crMissingEvidence: cr-submitted CR -> implementing reports ONLY the approval OR-group missing', () => {
    var missing = _crMissingEvidence(crSubmittedOnly(), 'implementing', EVIDENCE_MAP);
    assert.deepEqual(missing, ['cr_approved_at|cr_approval_waived_at']);
});

test('_crApprovalOnlyGap: true for the implementing gap above', () => {
    var missing = _crMissingEvidence(crSubmittedOnly(), 'implementing', EVIDENCE_MAP);
    assert.equal(_crApprovalOnlyGap(missing, EVIDENCE_MAP.orSeparator), true);
});

// Task brief posed this as an open question ("deployed-prod gap includes more
// than approval?"). MEASURED against the real derived map (not assumed): for
// a cr-submitted-only CR, deployed-dev and deployed-prod's prerequisite list
// is IDENTICAL to implementing's (both require cr_submitted_at, already
// satisfied, + the approval OR-group) — so they are ALSO approval-only gaps
// from this fixture, not "more than approval". A CR that also lacked
// cr_submitted_at would show a mixed gap instead (covered below).
test('_crApprovalOnlyGap: deployed-dev and deployed-prod are ALSO approval-only from a cr-submitted-only CR (measured, not assumed)', () => {
    ['deployed-dev', 'deployed-prod'].forEach(function (state) {
        var missing = _crMissingEvidence(crSubmittedOnly(), state, EVIDENCE_MAP);
        assert.deepEqual(missing, ['cr_approved_at|cr_approval_waived_at'], 'state=' + state);
        assert.equal(_crApprovalOnlyGap(missing, EVIDENCE_MAP.orSeparator), true, 'state=' + state);
    });
});

test('_crMissingEvidence / _crApprovalOnlyGap: a cr-drafted CR moving to cr-approved is missing cr_submitted_at — NOT an approval-only gap', () => {
    var missing = _crMissingEvidence(crDraftedOnly(), 'cr-approved', EVIDENCE_MAP);
    assert.deepEqual(missing, ['cr_submitted_at']);
    assert.equal(_crApprovalOnlyGap(missing, EVIDENCE_MAP.orSeparator), false);
});

test('_crMissingEvidence / _crApprovalOnlyGap: a bare-drafted CR moving to implementing has a MIXED gap (submission AND approval) — not approval-only', () => {
    var missing = _crMissingEvidence(crDraftedOnly(), 'implementing', EVIDENCE_MAP);
    assert.deepEqual(missing, ['cr_submitted_at', 'cr_approved_at|cr_approval_waived_at']);
    assert.equal(_crApprovalOnlyGap(missing, EVIDENCE_MAP.orSeparator), false,
        'Not every missing token contains cr_approval_waived_at (cr_submitted_at does not) — must not offer a waiver here.');
});

test('OR-group satisfied by waiver: a CR with cr_approval_waived_at (no cr_approved_at) shows NO gap for implementing', () => {
    var missing = _crMissingEvidence(crSubmittedAndWaived(), 'implementing', EVIDENCE_MAP);
    assert.deepEqual(missing, [], 'cr_approval_waived_at must satisfy the OR-group exactly like cr_approved_at would');
});

test('_crMissingEvidence: empty/no-prerequisite states never report anything missing', () => {
    assert.deepEqual(_crMissingEvidence(crDraftedOnly(), 'cr-drafted', EVIDENCE_MAP), []);
    assert.deepEqual(_crMissingEvidence(crDraftedOnly(), 'cr-submitted', EVIDENCE_MAP), []);
});

test('_crMissingEvidence: returns [] (not a throw) when evidenceMap is null/absent — "map unavailable" is the CALLER\'s concern', () => {
    assert.deepEqual(_crMissingEvidence(crSubmittedOnly(), 'implementing', null), []);
    assert.deepEqual(_crMissingEvidence(crSubmittedOnly(), 'implementing', undefined), []);
});

// ─── (A) Label derivation ───────────────────────────────────────────────────

test('_crEvidenceTokenLabel: named table entries', () => {
    assert.equal(_crEvidenceTokenLabel('cr_submitted_at'), 'submission');
    assert.equal(_crEvidenceTokenLabel('cr_approved_at|cr_approval_waived_at'), 'approval');
    assert.equal(_crEvidenceTokenLabel('cr_started_dev_at'), 'implementing');
});

test('_crEvidenceTokenLabel: generic fallback for a token not in the named table', () => {
    assert.equal(_crEvidenceTokenLabel('cr_totally_unmapped_at'), 'totally unmapped');
});

test('_crEvidenceTokenLabel: an OR-group not in the named table falls back via its non-waiver member', () => {
    assert.equal(_crEvidenceTokenLabel('cr_totally_unmapped_at|cr_approval_waived_at'), 'totally unmapped');
});

test('_crMissingEvidenceLabels: de-dupes and preserves order', () => {
    var labels = _crMissingEvidenceLabels(
        ['cr_submitted_at', 'cr_approved_at|cr_approval_waived_at', 'cr_submitted_at'],
        '|'
    );
    assert.deepEqual(labels, ['submission', 'approval']);
});

// ─── (A) _crGapInfo — combined decision object ─────────────────────────────

test('_crGapInfo: mapAvailable is false and every field is a safe empty default when evidenceMap is falsy', () => {
    var gap = _crGapInfo(crSubmittedOnly(), 'implementing', null);
    assert.deepEqual(gap, { mapAvailable: false, missing: [], approvalOnlyGap: false, missingLabels: [] });
});

test('_crGapInfo: full decision object for the approval-only implementing case', () => {
    var gap = _crGapInfo(crSubmittedOnly(), 'implementing', EVIDENCE_MAP);
    assert.equal(gap.mapAvailable, true);
    assert.deepEqual(gap.missing, ['cr_approved_at|cr_approval_waived_at']);
    assert.equal(gap.approvalOnlyGap, true);
    assert.deepEqual(gap.missingLabels, ['approval']);
});

// ─── (A) SUBMIT enablement (evidence-gap portion) — item 3 (blank/whitespace disabled) ──

test('_crWaiverSubmitAllowed: map unavailable -> allowed (server remains the backstop, per D6 fallback)', () => {
    var gap = _crGapInfo(crSubmittedOnly(), 'implementing', null);
    assert.equal(_crWaiverSubmitAllowed(gap, ''), true);
});

test('_crWaiverSubmitAllowed: no gap -> allowed regardless of reason text', () => {
    var gap = _crGapInfo(crSubmittedAndWaived(), 'implementing', EVIDENCE_MAP); // fully satisfied
    assert.equal(gap.missing.length, 0);
    assert.equal(_crWaiverSubmitAllowed(gap, ''), true);
});

test('_crWaiverSubmitAllowed: non-approval-only gap -> never allowed, no matter the reason text', () => {
    var gap = _crGapInfo(crDraftedOnly(), 'cr-approved', EVIDENCE_MAP); // missing cr_submitted_at
    assert.equal(_crWaiverSubmitAllowed(gap, 'even a perfectly good reason'), false);
});

test('_crWaiverSubmitAllowed: approval-only gap + blank reason -> disabled', () => {
    var gap = _crGapInfo(crSubmittedOnly(), 'implementing', EVIDENCE_MAP);
    assert.equal(_crWaiverSubmitAllowed(gap, ''), false);
});

test('_crWaiverSubmitAllowed: approval-only gap + whitespace-only reason -> disabled', () => {
    var gap = _crGapInfo(crSubmittedOnly(), 'implementing', EVIDENCE_MAP);
    assert.equal(_crWaiverSubmitAllowed(gap, '   \n\t  '), false);
});

test('_crWaiverSubmitAllowed: approval-only gap + non-blank reason -> allowed', () => {
    var gap = _crGapInfo(crSubmittedOnly(), 'implementing', EVIDENCE_MAP);
    assert.equal(_crWaiverSubmitAllowed(gap, 'Approval not received; proceeding per manager sign-off.'), true);
});

// ─── (A) Payload assembly — item 5 (approval_waiver present, approver absent) ──

test('_crWaiverPayloadFields: adds approval_waiver.reason (trimmed) for an approval-only gap', () => {
    var gap = _crGapInfo(crSubmittedOnly(), 'implementing', EVIDENCE_MAP);
    var fields = _crWaiverPayloadFields(gap, '  A good reason.  ', { deploy_estimate: '2026-09-10T00:00' });
    assert.deepEqual(fields, { deploy_estimate: '2026-09-10T00:00', approval_waiver: { reason: 'A good reason.' } });
});

test('_crWaiverPayloadFields: strips a pre-existing approver key when a waiver is added (server rejects approver+waiver combined)', () => {
    var gap = _crGapInfo(crSubmittedOnly(), 'implementing', EVIDENCE_MAP);
    var fields = _crWaiverPayloadFields(gap, 'reason', { approver: { login: 'x', name: 'y' } });
    assert.deepEqual(fields, { approval_waiver: { reason: 'reason' } });
    assert.ok(!('approver' in fields), 'approver must never be sent alongside approval_waiver');
});

test('_crWaiverPayloadFields: leaves fields untouched when the gap is not approval-only', () => {
    var gap = _crGapInfo(crDraftedOnly(), 'cr-approved', EVIDENCE_MAP);
    var base = { approver: { login: 'x', name: 'y' } };
    var fields = _crWaiverPayloadFields(gap, 'reason', base);
    assert.deepEqual(fields, base);
});

test('_crWaiverPayloadFields: leaves fields untouched when the reason is blank, even for an approval-only gap', () => {
    var gap = _crGapInfo(crSubmittedOnly(), 'implementing', EVIDENCE_MAP);
    var base = { deploy_estimate: '2026-09-10T00:00' };
    var fields = _crWaiverPayloadFields(gap, '   ', base);
    assert.deepEqual(fields, base);
});

test('_crWaiverPayloadFields: never mutates baseFields', () => {
    var gap = _crGapInfo(crSubmittedOnly(), 'implementing', EVIDENCE_MAP);
    var base = { deploy_estimate: '2026-09-10T00:00' };
    var frozen = JSON.parse(JSON.stringify(base));
    _crWaiverPayloadFields(gap, 'reason', base);
    assert.deepEqual(base, frozen, 'baseFields must not be mutated by the helper');
});

// ─── (A) DEFAULT_WAIVER_REASON — single source of truth, exact wording (D3) ──

test('DEFAULT_WAIVER_REASON matches the plan\'s exact required default text', () => {
    assert.equal(
        helpers.DEFAULT_WAIVER_REASON,
        'No approval notice received — IT Connect approval signal not integrated (XACA-0899).'
    );
});

// ═══════════════════════════════════════════════════════════════════════════
// (B) lcars-cr-tab.js — vm-sliced source under test (see file header comment)
// ═══════════════════════════════════════════════════════════════════════════

var CR_TAB_PATH = path.join(__dirname, '../js/lcars-cr-tab.js');
var SRC = fs.readFileSync(CR_TAB_PATH, 'utf8');

function slice(startMarker, endMarker) {
    var start = SRC.indexOf(startMarker);
    assert.ok(start !== -1, 'Could not locate start marker in lcars-cr-tab.js: ' + JSON.stringify(startMarker));
    var end = SRC.indexOf(endMarker, start + startMarker.length);
    assert.ok(end !== -1, 'Could not locate end marker in lcars-cr-tab.js: ' + JSON.stringify(endMarker));
    return SRC.slice(start, end);
}

function escapeHtmlStub(s) {
    // Real escapeHtml also encodes <>&"' — none of the fixtures below need
    // that, so a passthrough stub (same convention test_cr_tab_publish_
    // regression.js uses) keeps assertions readable without testing
    // escapeHtml itself, which is out of scope here.
    return s === null || s === undefined ? '' : String(s);
}

// ── (B1) _renderStateCondFields + its two new render helpers + the plain-field
//         renderer they compose with. Slice from the default-reason constant
//         (referenced by _renderApprovalWaiverSection) through the end of
//         _collectStateCondFields (just before _showCRStateChangeDialog's own
//         JSDoc) — one contiguous region in the shipped file. ─────────────────

var condFieldsSrc = slice(
    'const _CR_APPROVAL_WAIVER_DEFAULT_REASON =',
    'function _showCRStateChangeDialog(view) {'
);

function buildCondFieldsSandbox(fakeElements) {
    var sandbox = {
        escapeHtml: escapeHtmlStub,
        // Real module, not a reimplementation — proves the shipped file's
        // _CR_EVID wiring actually calls through to lcars-cr-evidence-helpers.js.
        // The slice under test does not include the file's own
        // `const _CR_EVID = (window.lcarsCrEvidenceHelpers) || {}` line (that
        // lives earlier in the file, alongside _loadCREvidenceMap), so it is
        // provided directly here — same object, same behaviour.
        _CR_EVID: helpers,
        window: { lcarsCrEvidenceHelpers: helpers },
        document: {
            getElementById: function (id) {
                return Object.prototype.hasOwnProperty.call(fakeElements || {}, id)
                    ? fakeElements[id]
                    : null;
            },
        },
    };
    vm.createContext(sandbox);
    vm.runInContext(
        condFieldsSrc +
        '\nthis._renderStateCondFields = _renderStateCondFields;' +
        '\nthis._validateStateCondFields = _validateStateCondFields;' +
        '\nthis._collectStateCondFields = _collectStateCondFields;' +
        '\nthis._CR_APPROVAL_WAIVER_DEFAULT_REASON = _CR_APPROVAL_WAIVER_DEFAULT_REASON;',
        sandbox
    );
    return sandbox;
}

test('extraction sanity: _renderStateCondFields / _validateStateCondFields / _collectStateCondFields load from the shipped file', () => {
    var sb = buildCondFieldsSandbox({});
    assert.equal(typeof sb._renderStateCondFields, 'function');
    assert.equal(typeof sb._validateStateCondFields, 'function');
    assert.equal(typeof sb._collectStateCondFields, 'function');
});

test('_renderStateCondFields: no gapInfo -> unchanged legacy behaviour ("no additional fields")', () => {
    var sb = buildCondFieldsSandbox({});
    var html = sb._renderStateCondFields('implementing', null);
    assert.ok(html.indexOf('No additional fields required for this state.') !== -1, html);
    assert.ok(html.indexOf('APPROVAL NOT RECEIVED') === -1, html);
});

test('_renderStateCondFields: map unavailable (mapAvailable:false) -> unchanged legacy behaviour', () => {
    var sb = buildCondFieldsSandbox({});
    var gap = { mapAvailable: false, missing: [], approvalOnlyGap: false, missingLabels: [] };
    var html = sb._renderStateCondFields('implementing', gap);
    assert.ok(html.indexOf('No additional fields required for this state.') !== -1, html);
});

test('_renderStateCondFields: no gap (map available, nothing missing) -> unchanged legacy behaviour', () => {
    var sb = buildCondFieldsSandbox({});
    var gap = { mapAvailable: true, missing: [], approvalOnlyGap: false, missingLabels: [] };
    var html = sb._renderStateCondFields('implementing', gap);
    assert.ok(html.indexOf('No additional fields required for this state.') !== -1, html);
    assert.ok(html.indexOf('APPROVAL NOT RECEIVED') === -1, html);
});

test('_renderStateCondFields: approval-only gap for "implementing" (no other fields) shows ONLY the waiver section, pre-filled with the default reason', () => {
    var sb = buildCondFieldsSandbox({});
    var gap = _crGapInfo(crSubmittedOnly(), 'implementing', EVIDENCE_MAP);
    var html = sb._renderStateCondFields('implementing', gap);
    assert.ok(html.indexOf('APPROVAL NOT RECEIVED') !== -1, html);
    assert.ok(html.indexOf('id="cr-sc-waiver-reason"') !== -1, html);
    assert.ok(html.indexOf('aria-describedby="cr-sc-waiver-explain"') !== -1, 'reason textarea must be aria-described by the explanatory text');
    assert.ok(html.indexOf(sb._CR_APPROVAL_WAIVER_DEFAULT_REASON) !== -1, 'textarea must be pre-filled with the default reason');
    assert.ok(html.indexOf('cr-sc-gap-blocked') === -1, 'must not ALSO show the blocking message');
    assert.ok(html.indexOf('No additional fields required') === -1);
});

test('_renderStateCondFields: approval-only gap for "deployed-prod" shows the waiver section IN ADDITION TO the existing DEPLOY TIMESTAMP field', () => {
    var sb = buildCondFieldsSandbox({});
    var gap = _crGapInfo(crSubmittedOnly(), 'deployed-prod', EVIDENCE_MAP);
    assert.equal(gap.approvalOnlyGap, true, 'precondition: deployed-prod must be an approval-only gap for this fixture');
    var html = sb._renderStateCondFields('deployed-prod', gap);
    assert.ok(html.indexOf('DEPLOY TIMESTAMP') !== -1, 'existing required field must still render: ' + html);
    assert.ok(html.indexOf('APPROVAL NOT RECEIVED') !== -1, 'waiver section must ALSO render: ' + html);
});

test('_renderStateCondFields: a non-approval gap shows the blocking message (naming the missing step) and NOT the waiver section', () => {
    var sb = buildCondFieldsSandbox({});
    var gap = _crGapInfo(crDraftedOnly(), 'cr-approved', EVIDENCE_MAP); // missing cr_submitted_at
    var html = sb._renderStateCondFields('cr-approved', gap);
    assert.ok(html.indexOf('cr-sc-gap-blocked') !== -1, html);
    assert.ok(html.indexOf('submission') !== -1, 'blocking message must name the missing step: ' + html);
    assert.ok(html.indexOf('APPROVAL NOT RECEIVED') === -1, 'no waiver may be offered for a non-approval gap: ' + html);
});

test('_validateStateCondFields: approval-only gap, blank reason -> SUBMIT disabled (false)', () => {
    var sb = buildCondFieldsSandbox({ 'cr-sc-waiver-reason': { value: '' } });
    var gap = _crGapInfo(crSubmittedOnly(), 'implementing', EVIDENCE_MAP);
    assert.equal(sb._validateStateCondFields('implementing', gap), false);
});

test('_validateStateCondFields: approval-only gap, whitespace-only reason -> SUBMIT disabled (false)', () => {
    var sb = buildCondFieldsSandbox({ 'cr-sc-waiver-reason': { value: '   ' } });
    var gap = _crGapInfo(crSubmittedOnly(), 'implementing', EVIDENCE_MAP);
    assert.equal(sb._validateStateCondFields('implementing', gap), false);
});

test('_validateStateCondFields: approval-only gap, non-blank reason -> SUBMIT enabled (true)', () => {
    var sb = buildCondFieldsSandbox({ 'cr-sc-waiver-reason': { value: 'A real reason.' } });
    var gap = _crGapInfo(crSubmittedOnly(), 'implementing', EVIDENCE_MAP);
    assert.equal(sb._validateStateCondFields('implementing', gap), true);
});

test('_validateStateCondFields: non-approval gap -> SUBMIT disabled regardless of any waiver textarea state', () => {
    var sb = buildCondFieldsSandbox({ 'cr-sc-waiver-reason': { value: 'irrelevant' } });
    var gap = _crGapInfo(crDraftedOnly(), 'cr-approved', EVIDENCE_MAP);
    assert.equal(sb._validateStateCondFields('cr-approved', gap), false);
});

test('_validateStateCondFields: evidence map unavailable -> falls back to legacy per-field validation only (server remains the backstop)', () => {
    var sb = buildCondFieldsSandbox({});
    // 'implementing' has zero _CR_STATE_FIELDS entries, so legacy behaviour is "always valid".
    assert.equal(sb._validateStateCondFields('implementing', null), true);
});

test('_collectStateCondFields: approval-only gap + reason -> payload carries fields.approval_waiver and never fields.approver', () => {
    var sb = buildCondFieldsSandbox({ 'cr-sc-waiver-reason': { value: '  Proceeding without approval per manager.  ' } });
    var gap = _crGapInfo(crSubmittedOnly(), 'implementing', EVIDENCE_MAP);
    var fields = sb._collectStateCondFields('implementing', gap);
    assert.deepEqual(fields, { approval_waiver: { reason: 'Proceeding without approval per manager.' } });
    assert.ok(!('approver' in fields));
});

test('_collectStateCondFields: approval-only gap for deployed-prod -> payload carries BOTH deploy_estimate and approval_waiver', () => {
    var sb = buildCondFieldsSandbox({
        'cr-sc-field-deploy_estimate': { value: '2026-09-10T12:00' },
        'cr-sc-waiver-reason':         { value: 'Proceeding without approval.' },
    });
    var gap = _crGapInfo(crSubmittedOnly(), 'deployed-prod', EVIDENCE_MAP);
    var fields = sb._collectStateCondFields('deployed-prod', gap);
    assert.deepEqual(fields, {
        deploy_estimate: '2026-09-10T12:00',
        approval_waiver: { reason: 'Proceeding without approval.' },
    });
});

test('_collectStateCondFields: no gapInfo -> unchanged legacy payload (no approval_waiver key at all)', () => {
    var sb = buildCondFieldsSandbox({});
    var fields = sb._collectStateCondFields('implementing', null);
    assert.deepEqual(fields, {});
    assert.ok(!('approval_waiver' in fields));
});

// ── (B2) _crWaivedChip — row/detail "APPROVAL WAIVED" indicator ────────────

var chipSrc = slice('function _crWaivedChip(item) {', 'function _formatDeployWindow(value) {');

function buildChipSandbox() {
    var sandbox = { escapeHtml: escapeHtmlStub };
    vm.createContext(sandbox);
    vm.runInContext(chipSrc + '\nthis._crWaivedChip = _crWaivedChip;', sandbox);
    return sandbox;
}

test('_crWaivedChip: empty string when the CR was never waived', () => {
    var sb = buildChipSandbox();
    assert.equal(sb._crWaivedChip({ cr_approval_waived_at: '' }), '');
    assert.equal(sb._crWaivedChip({}), '');
});

test('_crWaivedChip: renders "APPROVAL WAIVED" with actor/reason/at in the tooltip when waived', () => {
    var sb = buildChipSandbox();
    var html = sb._crWaivedChip({
        cr_approval_waived_at:     '2026-09-04T00:00:00Z',
        cr_approval_waived_actor:  'jsmith',
        cr_approval_waived_reason: 'IT Connect signal not integrated.',
    });
    assert.ok(html.indexOf('APPROVAL WAIVED') !== -1, html);
    assert.ok(html.indexOf('jsmith') !== -1, html);
    assert.ok(html.indexOf('IT Connect signal not integrated.') !== -1, html);
    assert.ok(html.indexOf('cr-waived-chip') !== -1, 'must use the amber waived-chip class, not a state-approved-style class');
});

// ── (B3) _crActivityDetails — distinct "Approval waived by <actor>: <reason>" rendering ──

var activitySrc = slice('function _crActivityDetails(evt) {', 'function _renderCRActivityLog(data) {');

function buildActivitySandbox() {
    var sandbox = { escapeHtml: escapeHtmlStub };
    vm.createContext(sandbox);
    vm.runInContext(activitySrc + '\nthis._crActivityDetails = _crActivityDetails;', sandbox);
    return sandbox;
}

test('_crActivityDetails: cr_approval_waived renders "Approval waived by <actor>: <reason>", distinct from the generic note fallback', () => {
    var sb = buildActivitySandbox();
    // Shape per scripts/kb-cr.sh _kb_cr_waive_approval -> _kb_cr_activity_event:
    // {ts, type:'cr_approval_waived', actor, field:'cr_approval_waived_at', note:<trimmed reason>}
    var evt = { type: 'cr_approval_waived', actor: 'jsmith', field: 'cr_approval_waived_at', note: 'No approval notice received.' };
    var html = sb._crActivityDetails(evt);
    assert.equal(html, '<span class="cr-activity-waiver">Approval waived by jsmith: No approval notice received.</span>');
    assert.ok(html.indexOf('cr-activity-note') === -1, 'must not fall through to the generic evt.note branch');
});

test('_crActivityDetails: cr_approval_waived with no actor still renders (falls back to "unknown")', () => {
    var sb = buildActivitySandbox();
    var html = sb._crActivityDetails({ type: 'cr_approval_waived', note: 'reason text' });
    assert.ok(html.indexOf('Approval waived by unknown: reason text') !== -1, html);
});

test('sanity: an unrelated event type with a note still uses the generic fallback (unaffected by the new branch)', () => {
    var sb = buildActivitySandbox();
    var html = sb._crActivityDetails({ type: 'some_other_event', note: 'plain note' });
    assert.ok(html.indexOf('cr-activity-note') !== -1, html);
});
