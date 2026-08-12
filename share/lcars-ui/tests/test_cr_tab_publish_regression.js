//
//  test_cr_tab_publish_regression.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * test_cr_tab_publish_regression.js — Node-native regression coverage for two
 * XACA-0895-009 defects found in lcars-cr-tab.js's cr-published support:
 *
 *   Defect 1: _normalizeCR() never projected cr_published_at from
 *             timestamps.cr_published_at, so item.cr_published_at was always
 *             undefined and _STAGE_ANCHOR['cr-published'] silently fell
 *             through to cr_created_at — a cr-published CR read its STAGE AGE
 *             from its DRAFT date, exactly the failure the XACA-0895 anchor
 *             comment says it exists to prevent.
 *
 *   Defect 2: cr-lifecycle-monitor.py's REMINDER_STATE_CONFIG keeps a
 *             SEPARATE idempotency field per pre-submission state
 *             (cr_drafted_reminder_last_at, cr_published_reminder_last_at).
 *             _normalizeCR only projected the drafted field, and the badge
 *             always read that one field regardless of crState — so the
 *             24h+ badge never lit for a cr-published CR even after the
 *             monitor fired and stamped cr_published_reminder_last_at.
 *
 * lcars-cr-tab.js is a browser-only IIFE with no module.exports (unlike
 * lcars-cr-metrics.js / lcars-cr-age-helpers.js, which were already split out
 * for Node testability). Rather than duplicate its logic by hand — a
 * reimplementation would test itself, not the shipped code — this file
 * extracts the exact pure, dependency-free source slices under test directly
 * from the shipped file (by unique start/end text markers) and evaluates
 * them in a vm context. If a marker goes missing (the surrounding code was
 * refactored), extraction fails loudly with a clear error instead of
 * silently testing stale text.
 *
 * Usage:
 *   node --test lcars-ui/tests/test_cr_tab_publish_regression.js
 *
 * No external dependencies. Node ≥18 required (node:test, node:vm built-in).
 */

'use strict';

var test   = require('node:test');
var assert = require('node:assert/strict');
var path   = require('path');
var fs     = require('fs');
var vm     = require('vm');

var CR_TAB_PATH = path.join(__dirname, '../js/lcars-cr-tab.js');
var SCHEMA_PATH = path.join(__dirname, '../../homebrew-tap/share/templates/kanban/cr-schema.json');

var SRC = fs.readFileSync(CR_TAB_PATH, 'utf8');

/** Slice SRC from startMarker (inclusive) up to endMarker (exclusive). */
function slice(startMarker, endMarker) {
    var start = SRC.indexOf(startMarker);
    assert.ok(start !== -1, 'Could not locate start marker in lcars-cr-tab.js: ' + JSON.stringify(startMarker));
    var end = SRC.indexOf(endMarker, start + startMarker.length);
    assert.ok(end !== -1, 'Could not locate end marker in lcars-cr-tab.js: ' + JSON.stringify(endMarker));
    return SRC.slice(start, end);
}

function buildSandbox() {
    var sandbox = {
        // lcars-cr-tab.js calls the global escapeHtml() defined in lcars.js
        // (loaded separately in the browser). Stub is fine — it is not the
        // subject under test here.
        escapeHtml: function (s) { return s === null || s === undefined ? '' : String(s); },
    };
    vm.createContext(sandbox);
    return sandbox;
}

// ─── Extract _normalizeCR (pure — only reads its two params) ──────────────

var normalizeSrc = slice('function _normalizeCR(cr, backlogIdx) {', 'function _getCRItems(');
var normalizeSandbox = buildSandbox();
vm.runInContext(normalizeSrc + '\nthis._normalizeCR = _normalizeCR;', normalizeSandbox);
var _normalizeCR = normalizeSandbox._normalizeCR;
assert.equal(typeof _normalizeCR, 'function', 'Failed to extract _normalizeCR from lcars-cr-tab.js');

// ─── Extract _STAGE_ANCHOR + _computeStageAge (pure — only reads item) ────

var stageAgeSrc = slice('const _STAGE_ANCHOR = {', 'function _stageAgeBadge(');
var stageSandbox = buildSandbox();
vm.runInContext(stageAgeSrc + '\nthis._computeStageAge = _computeStageAge;', stageSandbox);
var _computeStageAge = stageSandbox._computeStageAge;
assert.equal(typeof _computeStageAge, 'function', 'Failed to extract _computeStageAge from lcars-cr-tab.js');

// ─── Extract _DELAY_TERMINAL / _DRAFTED_REMINDER_STATES / ─────────────────
// ─── _REMINDER_LAST_AT_FIELD / _automationBadges (needs escapeHtml stub) ──

var badgeSrc = slice('const _DELAY_TERMINAL = new Set(', 'function _releaseLink(');
var badgeSandbox = buildSandbox();
vm.runInContext(badgeSrc + '\nthis._automationBadges = _automationBadges;', badgeSandbox);
var _automationBadges = badgeSandbox._automationBadges;
assert.equal(typeof _automationBadges, 'function', 'Failed to extract _automationBadges from lcars-cr-tab.js');

// ─── Defect 1: cr_published_at projection ──────────────────────────────────

test('XACA-0895-009 regression: _normalizeCR projects cr_published_at from timestamps.cr_published_at', () => {
    var cr = {
        id: 'CR-TEST-0001',
        crState: 'cr-published',
        timestamps: {
            cr_created_at:   '2026-07-01T00:00:00Z',
            cr_published_at: '2026-08-06T00:00:00Z',
        },
        createdAt: '2026-07-01T00:00:00Z',
        itemIds: [],
    };
    var view = _normalizeCR(cr, {});
    assert.equal(view.cr_published_at, '2026-08-06T00:00:00Z',
        'cr_published_at must come from timestamps.cr_published_at — got: ' + JSON.stringify(view.cr_published_at));
});

test('XACA-0895-009 regression: _normalizeCR does NOT fall back to a top-level cr.cr_published_at', () => {
    // A sibling ticket briefly wrote a top-level alias; the plan explicitly rejects it —
    // timestamps.cr_published_at is the ONLY source. Prove the nested field wins even
    // when a (wrong) top-level field is also present.
    var cr = {
        id: 'CR-TEST-0002',
        crState: 'cr-published',
        cr_published_at: '1999-01-01T00:00:00Z',       // top-level — must be ignored
        timestamps: { cr_published_at: '2026-08-06T00:00:00Z' },
        createdAt: '2026-01-01T00:00:00Z',
        itemIds: [],
    };
    var view = _normalizeCR(cr, {});
    assert.equal(view.cr_published_at, '2026-08-06T00:00:00Z',
        'Expected the nested timestamps.cr_published_at value, not the top-level alias.');
});

test('XACA-0895-009 regression: STAGE AGE for cr-published anchors on cr_published_at, not cr_created_at', () => {
    var NOW = Date.now();
    var oldCreatedAt      = new Date(NOW - 10 * 24 * 60 * 60 * 1000).toISOString(); // 10 days ago
    var recentPublishedAt = new Date(NOW - 1 * 60 * 60 * 1000).toISOString();       // 1 hour ago

    // Chain through the REAL pipeline: raw record -> _normalizeCR -> _computeStageAge.
    // A test that hand-builds a view-object with cr_published_at already present
    // would pass even if _normalizeCR forgot to project it — that is not this
    // regression's failure path. The actual bug lived in _normalizeCR silently
    // dropping the field; only feeding its raw output into _computeStageAge
    // exercises that path.
    var cr = {
        id: 'CR-TEST-0003',
        crState: 'cr-published',
        timestamps: {
            cr_created_at:   oldCreatedAt,
            cr_published_at: recentPublishedAt,
        },
        createdAt: oldCreatedAt,
        itemIds: [],
    };
    var view = _normalizeCR(cr, {});
    var ageDays = _computeStageAge(view);
    assert.ok(ageDays !== null, 'Expected a numeric stage age, got null');
    // The regression this guards: if _normalizeCR never projects cr_published_at,
    // the anchor silently falls back to cr_created_at and age reads ~10 days
    // instead of ~1 hour. A test with both timestamps close together would pass
    // either way and prove nothing — that is why they are 10 days and 1 hour apart.
    assert.ok(ageDays < 1,
        'Expected STAGE AGE computed from cr_published_at (~1h ≈ 0.04d), got ' + ageDays +
        ' days — this matches falling back to the old cr_created_at (~10d), the exact bug being guarded against.');
});

test('sanity: STAGE AGE for cr-drafted still anchors on cr_created_at (unaffected by the cr-published fix)', () => {
    var NOW = Date.now();
    var createdAt = new Date(NOW - 3 * 24 * 60 * 60 * 1000).toISOString(); // 3 days ago
    var item = { crState: 'cr-drafted', cr_created_at: createdAt, addedAt: createdAt };
    var ageDays = _computeStageAge(item);
    assert.ok(ageDays !== null && ageDays > 2.9 && ageDays < 3.1, 'Expected ~3 days, got ' + ageDays);
});

// ─── Defect 2: cr_published_reminder_last_at projection + badge routing ───

// Both badge tests chain through the REAL pipeline (raw record -> _normalizeCR
// -> _automationBadges), for the same reason the STAGE AGE test does above: a
// hand-built view-object with the reminder field already present would pass
// even if _normalizeCR forgot to project it, which is exactly half of Defect 2.

test('XACA-0895-009 regression: 24h+ badge reads cr_published_reminder_last_at for a cr-published CR', () => {
    var cr = {
        id: 'CR-TEST-0004',
        crState: 'cr-published',
        cr_published_reminder_last_at: new Date().toISOString(),
        itemIds: [],
    };
    var view = _normalizeCR(cr, {});
    var html = _automationBadges(view);
    assert.ok(html.indexOf('24h+') !== -1,
        'Expected the 24h+ badge for a cr-published CR whose OWN reminder field is set. Got: ' + JSON.stringify(html));
});

// XACA-0895-016: the badge used to read the literal 'DRAFTED 24h+' for BOTH
// pre-submission states, so a cr-published row rendered a DRAFTED badge next to
// its own PUBLISHED state badge. The label is now per-state. These tests assert
// the contradiction specifically — asserting only that "some 24h+ badge
// rendered" would have passed against the defect.
test('XACA-0895-016: cr-published row does NOT render the contradicting DRAFTED label', () => {
    var cr = {
        id: 'CR-TEST-0004B',
        crState: 'cr-published',
        cr_published_reminder_last_at: new Date().toISOString(),
        itemIds: [],
    };
    var html = _automationBadges(_normalizeCR(cr, {}));
    assert.ok(html.indexOf('DRAFTED') === -1,
        'A cr-published row must not claim DRAFTED — it contradicts the row\'s own state badge. Got: ' + JSON.stringify(html));
    assert.ok(html.indexOf('PUBLISHED 24h+') !== -1,
        'Expected the state-aware PUBLISHED 24h+ label. Got: ' + JSON.stringify(html));
});

test('XACA-0895-016: badge label matches the row state for every reminder-firing state', () => {
    var cases = [
        { state: 'cr-drafted',   field: 'cr_drafted_reminder_last_at',   label: 'DRAFTED 24h+' },
        { state: 'cr-published', field: 'cr_published_reminder_last_at', label: 'PUBLISHED 24h+' },
    ];
    cases.forEach(function (c) {
        var cr = { id: 'CR-TEST-LBL', crState: c.state, itemIds: [] };
        cr[c.field] = new Date().toISOString();
        var html = _automationBadges(_normalizeCR(cr, {}));
        assert.ok(html.indexOf(c.label) !== -1,
            'Expected ' + c.label + ' for ' + c.state + '. Got: ' + JSON.stringify(html));
    });
});

test('XACA-0895-009 regression: badge does NOT fire for cr-published off a foreign cr_drafted_reminder_last_at', () => {
    var cr = {
        id: 'CR-TEST-0005',
        crState: 'cr-published',
        cr_drafted_reminder_last_at: new Date().toISOString(), // leftover from before this CR was published — must be ignored
        itemIds: [],
    };
    var view = _normalizeCR(cr, {});
    var html = _automationBadges(view);
    assert.equal(html, '',
        'A cr-published CR must not read cr_drafted_reminder_last_at for its own badge. Got: ' + JSON.stringify(html));
});

test('sanity: DRAFTED 24h+ badge still fires for cr-drafted off cr_drafted_reminder_last_at (unaffected by the fix)', () => {
    var cr = {
        id: 'CR-TEST-0006',
        crState: 'cr-drafted',
        cr_drafted_reminder_last_at: new Date().toISOString(),
        itemIds: [],
    };
    var view = _normalizeCR(cr, {});
    var html = _automationBadges(view);
    assert.ok(html.indexOf('DRAFTED 24h+') !== -1, 'Expected the badge to still fire for cr-drafted. Got: ' + JSON.stringify(html));
});

test('sanity: no badge for a state with no reminder field mapping (e.g. cr-submitted)', () => {
    var cr = {
        id: 'CR-TEST-0007',
        crState: 'cr-submitted',
        cr_drafted_reminder_last_at:   new Date().toISOString(),
        cr_published_reminder_last_at: new Date().toISOString(),
        itemIds: [],
    };
    var view = _normalizeCR(cr, {});
    var html = _automationBadges(view);
    assert.equal(html, '', 'cr-submitted has no reminder mapping and must never render the badge. Got: ' + JSON.stringify(html));
});

// ─── SSOT: every schema-declared crTimestamps.* field is projected or ─────
// ─── explicitly allow-listed (scope note below) ────────────────────────────

/**
 * KNOWN_UNPROJECTED_TIMESTAMP_FIELDS — timestamps.* fields declared in
 * cr-schema.json's crTimestamps block that _normalizeCR deliberately does
 * NOT surface to the client, with the reason recorded so a future schema
 * addition is a decision, not a silent gap.
 *
 * Scope note (XACA-0895-009): the orchestrator asked for this SSOT check to
 * additionally cover every TOP-LEVEL crContainer field (not just
 * timestamps.*), seeded with cr_published_version / cr_published_title as
 * "already live" allow-list entries. Verified against this checkout:
 * neither field exists anywhere in cr-schema.json or any other tracked file
 * — the only occurrence is a forward-reference comment in kb-cr.sh
 * (_kb_cr_state_strip_spec) noting they arrive in XACA-0896. Broadening the
 * scope further surfaces that crContainer/crTimestamps in cr-schema.json
 * already lag the runtime model by several UNRELATED fields predating this
 * ticket (e.g. cr_confluence_url, cr_rejected_at, cr_held_at, cr_closed_at,
 * delay_flagged_at, both reminder fields, and releaseAssignment are all
 * written by kb-cr.sh/cr-lifecycle-monitor.py but declared nowhere in this
 * schema file; approver is a nested {login,name} object in the schema but
 * _normalizeCR maps flat legacy field names cr_approver_name/cr_approved_by
 * instead). Auditing and correctly allow-listing that full set is a
 * separate, pre-existing body of work, not a XACA-0895 regression — it is
 * intentionally left OUT of this file's scope. See the XACA-0895-009 report
 * for the recommendation to spin it out as its own ticket.
 */
var KNOWN_UNPROJECTED_TIMESTAMP_FIELDS = {
    cr_testing_started_at: (
        'Written by kb-cr start-test (kb-cr.sh) but never surfaced by _normalizeCR. ' +
        'STAGE AGE for "implementing" anchors on cr_dev_started_at instead. Pre-existing ' +
        'gap predating XACA-0895 — out of scope for the cr-published defect class this ' +
        'file targets.'
    ),
};

test('XACA-0895-009 SSOT: every cr-schema.json crTimestamps.* field is projected by _normalizeCR or explicitly allow-listed', () => {
    var schema = JSON.parse(fs.readFileSync(SCHEMA_PATH, 'utf8'));
    assert.ok(schema.crTimestamps && typeof schema.crTimestamps === 'object', 'Expected crTimestamps block in cr-schema.json');

    var declared = Object.keys(schema.crTimestamps).filter(function (k) { return k.indexOf('_') !== 0; });
    assert.ok(declared.length > 0, 'Expected at least one declared crTimestamps field');
    assert.ok(declared.indexOf('cr_published_at') !== -1, 'Expected cr_published_at to be declared (XACA-0895) — schema read did not find it');

    var missing = declared.filter(function (field) {
        var projected = new RegExp('\\bts\\.' + field + '\\b').test(normalizeSrc);
        var allowListed = Object.prototype.hasOwnProperty.call(KNOWN_UNPROJECTED_TIMESTAMP_FIELDS, field);
        return !projected && !allowListed;
    });

    assert.deepEqual(missing, [],
        'crTimestamps field(s) neither projected by _normalizeCR nor recorded in ' +
        'KNOWN_UNPROJECTED_TIMESTAMP_FIELDS: ' + missing.join(', '));
});
