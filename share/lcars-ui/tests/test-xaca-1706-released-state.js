#!/usr/bin/env node
//
//  test-xaca-1706-released-state.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 DoubleNode.com. All rights reserved.
//

/**
 * XACA-1706: LCARS shows the terminal release status 'released' (written by XACA-1726 when a close-out
 * completes at PROD).
 *   - releaseLifecycleHtml(): RELEASED pill in the read-only head; the "stages change via kb-release" hint
 *     is dropped for released releases and kept for every other status.
 *   - displayReleases(): released releases leave the Active and Planned tabs and appear on a RELEASED tab.
 *   - Release-assign modal and the toggle button wiring treat 'released' as terminal.
 *
 * Extracts the real functions from lcars.js (brace-matched, unmodified) and runs them on stubs.
 *
 * Run: node lcars-ui/tests/test-xaca-1706-released-state.js
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(ROOT, 'js', 'lcars.js'), 'utf8');
const indexHtml = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');
const css = fs.readFileSync(path.join(ROOT, 'css', 'lcars.css'), 'utf8');

let failures = 0;
function check(name, actual, expected) {
    const a = JSON.stringify(actual);
    const e = JSON.stringify(expected);
    if (a === e) {
        console.log('ok - ' + name);
    } else {
        failures += 1;
        console.error('FAIL: ' + name + '\n  expected ' + e + '\n  actual   ' + a);
    }
}

function extractFunction(name) {
    const start = source.indexOf('\nfunction ' + name + '(');
    if (start === -1) throw new Error('function not found: ' + name);
    const bodyStart = source.indexOf('{', source.indexOf(')', start));
    let depth = 0;
    for (let i = bodyStart; i < source.length; i++) {
        const ch = source[i];
        if (ch === '{') depth++;
        else if (ch === '}') {
            depth--;
            if (depth === 0) return source.slice(start + 1, i + 1);
        }
    }
    throw new Error('unbalanced braces in ' + name);
}

// --- sandbox: real functions, stub DOM -------------------------------------------------------------------
const dashboard = { innerHTML: '' };
const sandbox = {
    document: { getElementById: (id) => (id === 'releases-dashboard' ? dashboard : null) },
    releasesState: { statusFilter: 'active', expandedReleases: new Set() },
    releaseSearchText: '',
    renderReleaseCard: (r) => '<card id="' + r.id + '">' + r.id + '</card>',
    itemMatchesSearch: () => true,
    bindItemTagClicks: () => {},
    checkPlanDocsButtons: () => {},
    populateReleaseFilterOptions: () => {},
    loadReleaseItems: () => {},
};
vm.createContext(sandbox);
vm.runInContext(
    'function escapeHtml(t) { return String(t == null ? "" : t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }\n' +
    extractFunction('escapeAttr') + '\n' +
    extractFunction('computeReleaseStageTestTotals') + '\n' +
    extractFunction('isReleaseReleased') + '\n' +
    extractFunction('releaseLifecycleHtml') + '\n' +
    extractFunction('formatAbsoluteTime') + '\n' +
    extractFunction('displayReleases') + '\n',
    sandbox);

const lifecycle = sandbox.releaseLifecycleHtml;
const HINT = 'stages change via kb-release';

// --- lifecycle head --------------------------------------------------------------------------------------
const relReleased = { id: 'R1', status: 'released', stage: 'PROD' };
const headReleased = lifecycle(relReleased, []);
check('released: head carries the RELEASED pill', /release-released-badge"[^>]*>RELEASED<\/span>/.test(headReleased), true);
check('released: the kb-release hint is dropped', headReleased.indexOf(HINT), -1);
check('released: still read-only', headReleased.indexOf('read-only') !== -1, true);
check('released: pill sits inside the lifecycle head',
    /<div class="release-lifecycle-head">.*release-released-badge.*<\/div>/.test(headReleased.split('release-lifecycle-row')[0]), true);

for (const status of ['active', 'planned', 'archived', undefined, null, 'RELEASED', 'released ', 7]) {
    const h = lifecycle({ id: 'R2', status: status, stage: 'QA' }, []);
    check('status ' + JSON.stringify(status) + ': no pill, hint kept',
        [h.indexOf('RELEASED</span>') === -1, h.indexOf(HINT) !== -1], [true, true]);
}

// --- tab filtering ---------------------------------------------------------------------------------------
const REL = [
    { id: 'LIVE', status: 'active', platforms: { ios: { environment: 'QA' } } },
    { id: 'PLAN', status: 'active', platforms: { ios: { environment: 'PLANNED' } } },
    { id: 'SHIP', status: 'released', platforms: { ios: { environment: 'PROD' } } },
    { id: 'SHIP2', status: 'released', platforms: { ios: { environment: 'PLANNED' } } },
];
function tab(filter) {
    sandbox.releasesState.statusFilter = filter;
    dashboard.innerHTML = '';
    sandbox.displayReleases(REL.map((r) => Object.assign({}, r)), null, {});
    return (dashboard.innerHTML.match(/id="([A-Z0-9]+)"/g) || []).map((m) => m.slice(4, -1));
}
check('Active tab excludes released', tab('active'), ['LIVE']);
check('Planned tab excludes released (even one with all-PLANNED platforms)', tab('planned'), ['PLAN']);
check('Released tab lists only released', tab('released').sort(), ['SHIP', 'SHIP2']);
sandbox.releasesState.statusFilter = 'released';
dashboard.innerHTML = '';
sandbox.displayReleases([REL[0]], null, {});
check('Released tab empty state', /No Released Releases/.test(dashboard.innerHTML), true);

// --- static wiring ---------------------------------------------------------------------------------------
check('index.html has the RELEASED toggle button', /id="releases-released-btn"[^>]*toggleReleasesStatusFilter\('released'\)/.test(indexHtml), true);
check('toggle highlight handles the released filter',
    /function updateReleasesStatusToggle[\s\S]*?filter === 'released' && releasedBtn/.test(source), true);
check('released tab fetches the non-archived list from the server', /statusFilter === 'archived' \? 'archived' : 'active'/.test(source), true);
check('assign modal excludes released', /allReleases\.filter\(r => r\.status !== 'archived' && !isReleaseReleased\(r\)\)/.test(source), true);
check('card header renders the pill', /const archivedBadge = \(isArchived[^\n]*\+ releasedBadge \+/.test(source), true);
const cardBody = extractFunction('renderReleaseCard');
check('renderReleaseCard carries the pill without helper calls (harness-extractable)',
    [/release-released-badge[^>]*>RELEASED</.test(cardBody), cardBody.indexOf('releasedPillHtml')], [true, -1]);

// EXECUTE the real renderReleaseCard (same slice set as test-xaca-1000) in its own context: a released release
// renders the pill, every other status does not. A source regex alone lets a `false ? pill : ''` mutant survive.
const cardCtx = {};
vm.createContext(cardCtx);
vm.runInContext(
    'var releasePlatformConfig = {};\n' +
    'function escapeHtml(t) { return String(t == null ? "" : t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }\n' +
    'var CANONICAL_STAGES = ["DEV", "QA", "ALPHA", "BETA", "GAMMA", "PROD"];\n' +
    'var releasesState = { expandedReleases: new Set() };\n' +
    ['isReleaseComplete', 'getIncompletePlatforms', 'renderArchiveAction', 'getPlatformName', 'escapeAttr',
        'jsAttrEscape', 'getReleaseEnvironments', 'buildItemTagsHtml', 'promoteStrandedBadgeHtml',
        'computeReleaseStageTestTotals', 'releaseLifecycleHtml', 'renderReleaseCard']
        .map(extractFunction).join('\n\n'),
    cardCtx);
// The pill renders TWICE on a released card: the header badge (the expression under test) and the lifecycle head
// (releaseLifecycleHtml). Counting both keeps a mutant of the header expression from hiding behind the other one.
const PILL = /release-released-badge"[^>]*>RELEASED<\/span>/g;
const pills = (h) => (h.match(PILL) || []).length;
const cardReleased = cardCtx.renderReleaseCard({ id: 'RC1', status: 'released', stage: 'PROD' });
const cardLive = cardCtx.renderReleaseCard({ id: 'RC2', status: 'in_progress', stage: 'QA' });
const cardArchived = cardCtx.renderReleaseCard({ id: 'RC3', status: 'archived', stage: 'PROD' });
check('executed renderReleaseCard: released card has the header pill AND the lifecycle pill', pills(cardReleased), 2);
check('executed renderReleaseCard: in_progress card has no RELEASED pill', pills(cardLive), 0);
check('executed renderReleaseCard: archived card has ARCHIVED but no RELEASED pill',
    [cardArchived.indexOf('>ARCHIVED</span>') !== -1, pills(cardArchived)], [true, 0]);

// --- sort: released (like archived) after the live releases; newest first among released ------------------
function order(list) {
    sandbox.releasesState.statusFilter = 'all';
    dashboard.innerHTML = '';
    sandbox.displayReleases(list.map((r) => Object.assign({}, r)), null, {});
    return (dashboard.innerHTML.match(/id="([A-Z0-9]+)"/g) || []).map((m) => m.slice(4, -1));
}
check('sort: released after live (live earliest-first), released newest-first',
    order([
        { id: 'OLDSHIP', status: 'released', targetDate: '2026-01-01' },
        { id: 'LATE', status: 'active', targetDate: '2026-09-01' },
        { id: 'NEWSHIP', status: 'released', targetDate: '2026-06-01' },
        { id: 'SOON', status: 'active', targetDate: '2026-03-01' },
    ]),
    ['SOON', 'LATE', 'NEWSHIP', 'OLDSHIP']);
check('css defines the RELEASED pill modifier', /\.archived-badge\.release-released-badge\s*\{[^}]*--lcars-green/.test(css), true);

// --- [UX] released cards lock EDIT and DELETE with the archived pattern -----------------------------------
const REASON = 'Released releases are read-only \u2014 the shipped record is preserved';
const btn = (h, cls) => (h.match(new RegExp('<button class="release-action-btn[^"]*' + cls + '[^>]*>', 'g')) || [])[0] || '';
const editBtn = (h) => btn(h, 'edit-btn');
const delBtn = (h) => btn(h, 'delete-btn');
check('released: EDIT is aria-disabled with the released reason as title',
    [/aria-disabled="true"/.test(editBtn(cardReleased)), editBtn(cardReleased).indexOf(REASON) !== -1], [true, true]);
check('released: DELETE is aria-disabled with the released reason as title',
    [/aria-disabled="true"/.test(delBtn(cardReleased)), delBtn(cardReleased).indexOf(REASON) !== -1], [true, true]);
check('released: sr-only reason spans exist for edit and delete',
    [/id="release-edit-reason-RC1" class="sr-only">Released releases are read-only/.test(cardReleased),
     /id="release-delete-reason-RC1" class="sr-only">Released releases are read-only/.test(cardReleased)], [true, true]);
check('released: aria-describedby points at the reason spans',
    [editBtn(cardReleased).indexOf('aria-describedby="release-edit-reason-RC1"') !== -1,
     delBtn(cardReleased).indexOf('aria-describedby="release-delete-reason-RC1"') !== -1], [true, true]);
check('in_progress: EDIT and DELETE are unaffected (no aria-disabled, no reason)',
    [editBtn(cardLive).indexOf('aria-disabled="true"') === -1, delBtn(cardLive).indexOf('aria-disabled="true"') === -1,
     cardLive.indexOf('release-delete-reason-') === -1], [true, true, true]);
check('archived: keeps its own (unarchive) reason, not the released one',
    [delBtn(cardArchived).indexOf('Unarchive it to delete') !== -1, cardArchived.indexOf(REASON) === -1], [true, true]);

if (failures > 0) {
    console.error('\n' + failures + ' test(s) failed.');
    process.exit(1);
}
console.log('All XACA-1706 released-state tests passed.');
