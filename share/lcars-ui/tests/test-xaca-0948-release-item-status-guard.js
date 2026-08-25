#!/usr/bin/env node
//
//  test-xaca-0948-release-item-status-guard.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * Regression test for XACA-0948-005: `resolveReleaseItemStatusDisplay` in
 * lcars-ui/js/lcars.js must never throw on a missing/unresolved/unknown
 * item.status, and must never render a raw, non-canonical status token
 * straight into a CSS class name.
 *
 * Background: `item.status` in the Releases-tab items panel used to be an
 * always-present string sourced from the manifest. Under
 * ITEM_STATUS_CONTRACT.md §1.5 it is now resolved live from the board and
 * can legitimately be `null` (server reports `statusResolution:
 * "unresolved"`) or a non-canonical recorded token (contract §1.4, e.g.
 * 'backlog'/'pending' — returned verbatim, never coerced). The prior code
 * did `item.status.toUpperCase()` unguarded inside a `.map()` over every
 * item in the release — one row without a status threw a TypeError, killed
 * the whole `.map()`, and the panel rendered "Error loading items" for
 * every item, not just the offending one.
 *
 * Also covers two UX-gate follow-up findings filed against the same PR
 * (XACA-0948-016, XACA-0948-017):
 *   - XACA-0948-017: the display LABEL normalizes underscores to spaces
 *     ('in_review' -> "IN REVIEW") while the CSS class keeps the raw token
 *     ('in_review', so `status-in_review` styling still matches).
 *   - XACA-0948-016: an 'unresolved' row's status span gets a generic
 *     explanatory `statusTitle` tooltip (the server's statusResolution flag
 *     has no reason code, so the text does not promise a specific cause);
 *     every other status gets an empty statusTitle (no tooltip).
 *
 * lcars-ui/js/lcars.js is a large browser file with top-level DOM calls
 * (document.addEventListener, etc.) and no existing jsdom/jest harness in
 * this repo, so this test does NOT `require()` the whole file. Instead it
 * extracts just the pure, DOM-free `RELEASE_ITEM_STATUS_CLASSES` constant
 * and `resolveReleaseItemStatusDisplay` function by source-slicing between
 * two textual anchors, and evaluates that slice in isolation. If either
 * anchor goes missing (the function is renamed/removed/moved), the test
 * fails loudly rather than silently skipping.
 *
 * Run:
 *   node lcars-ui/tests/test-xaca-0948-release-item-status-guard.js
 *
 * Not currently wired into an automated JS test runner — this repo has no
 * jest/mocha config for lcars-ui. Run manually or via `node <path>`; exits
 * non-zero on any failure so it is CI-runnable as a plain shell step.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const LCARS_JS_PATH = path.join(__dirname, '..', 'js', 'lcars.js');
const source = fs.readFileSync(LCARS_JS_PATH, 'utf8');

const START_ANCHOR = 'const RELEASE_ITEM_STATUS_CLASSES = new Set([';
const END_ANCHOR = 'async function loadReleaseItems(releaseId) {';

const startIdx = source.indexOf(START_ANCHOR);
const endIdx = source.indexOf(END_ANCHOR);

if (startIdx === -1 || endIdx === -1 || endIdx <= startIdx) {
    console.error(
        'FAIL: could not locate RELEASE_ITEM_STATUS_CLASSES / ' +
        'resolveReleaseItemStatusDisplay in lcars-ui/js/lcars.js. ' +
        'The function may have been renamed or moved — update this test\'s ' +
        'anchors (START_ANCHOR/END_ANCHOR) to match.'
    );
    process.exit(1);
}

// Slice out just the const + function declaration (pure, no DOM deps) and
// evaluate it in this Node process. No document/window stubbing needed
// because this slice never touches either.
const slice = source.slice(startIdx, endIdx);
// eslint-disable-next-line no-new-func
const factory = new Function(
    `${slice}\nreturn { RELEASE_ITEM_STATUS_CLASSES, resolveReleaseItemStatusDisplay };`
);
const { resolveReleaseItemStatusDisplay } = factory();

const UNRESOLVED_TITLE = 'Status could not be resolved from a team board (e.g. a dangling item ID, missing team, or unreadable board data). Counted as incomplete pending resolution.';

let failures = 0;

function check(name, item, expected) {
    let actual;
    try {
        actual = resolveReleaseItemStatusDisplay(item);
    } catch (e) {
        failures++;
        console.error(`FAIL: ${name} — threw ${e.name}: ${e.message}`);
        return;
    }
    try {
        assert.deepStrictEqual(actual, expected);
        console.log(`ok - ${name}`);
    } catch (e) {
        failures++;
        console.error(`FAIL: ${name} — expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    }
}

// --- Canonical tokens pass through with a matching class -------------------
// Underscored tokens (in_progress, in_review) get a SPACE in the display
// label (XACA-0948-017) but keep the raw underscored token in statusClass —
// the stylesheet selector is `status-in_progress`/`status-in_review`, not
// `status-in progress`.
check('canonical todo', { status: 'todo' }, { statusClass: 'todo', statusLabel: 'TODO', statusTitle: '' });
check('canonical in_progress (label normalizes underscore to space, class does not)', { status: 'in_progress' }, { statusClass: 'in_progress', statusLabel: 'IN PROGRESS', statusTitle: '' });
check('canonical in_review (widened R2 state; label normalizes underscore to space, class does not)', { status: 'in_review' }, { statusClass: 'in_review', statusLabel: 'IN REVIEW', statusTitle: '' });
check('canonical blocked', { status: 'blocked' }, { statusClass: 'blocked', statusLabel: 'BLOCKED', statusTitle: '' });
check('canonical completed', { status: 'completed' }, { statusClass: 'completed', statusLabel: 'COMPLETED', statusTitle: '' });
check('canonical cancelled', { status: 'cancelled' }, { statusClass: 'cancelled', statusLabel: 'CANCELLED', statusTitle: '' });
check('legacy done', { status: 'done' }, { statusClass: 'done', statusLabel: 'DONE', statusTitle: '' });

// --- THE regression: missing/unresolved status must never throw, and now
// also carries a generic explanatory statusTitle (XACA-0948-016) -----------
check('null status (unresolved row) does not throw, carries generic tooltip', { status: null }, { statusClass: 'unresolved', statusLabel: 'UNRESOLVED', statusTitle: UNRESOLVED_TITLE });
check('undefined status does not throw, carries generic tooltip', {}, { statusClass: 'unresolved', statusLabel: 'UNRESOLVED', statusTitle: UNRESOLVED_TITLE });
check('empty-string status treated as unresolved, carries generic tooltip', { status: '' }, { statusClass: 'unresolved', statusLabel: 'UNRESOLVED', statusTitle: UNRESOLVED_TITLE });
check('whitespace-only status treated as unresolved, carries generic tooltip', { status: '   ' }, { statusClass: 'unresolved', statusLabel: 'UNRESOLVED', statusTitle: UNRESOLVED_TITLE });

// --- Non-canonical recorded tokens (contract §1.4 — never coerced) --------
check('non-canonical backlog token -> status-unknown, label preserved, no tooltip', { status: 'backlog' }, { statusClass: 'unknown', statusLabel: 'BACKLOG', statusTitle: '' });
check('non-canonical pending token -> status-unknown, label preserved, no tooltip', { status: 'pending' }, { statusClass: 'unknown', statusLabel: 'PENDING', statusTitle: '' });
// Non-canonical token that ALSO contains an underscore: label normalizes to
// a space same as a canonical token would, but the class stays 'unknown'
// (not the raw token — see the hostile-token test below for why) and NOT
// 'unknown_status' — this is a distinct axis from the label normalization.
check('non-canonical underscored token -> label normalized, class stays unknown (not the raw token)', { status: 'needs_triage' }, { statusClass: 'unknown', statusLabel: 'NEEDS TRIAGE', statusTitle: '' });

// --- Never interpolates the raw token into the class name ------------------
{
    const dangerous = { status: 'x"><script>alert(1)</script>' };
    let result;
    try {
        result = resolveReleaseItemStatusDisplay(dangerous);
    } catch (e) {
        failures++;
        console.error(`FAIL: hostile status token threw ${e.name}: ${e.message}`);
    }
    if (result) {
        if (result.statusClass === 'unknown') {
            console.log('ok - hostile/non-canonical status token maps to status-unknown, never interpolated verbatim into class name');
        } else {
            failures++;
            console.error(`FAIL: hostile status token produced statusClass=${JSON.stringify(result.statusClass)}, expected 'unknown'`);
        }
        if (result.statusTitle === '') {
            console.log('ok - hostile/non-canonical status token gets no tooltip (only unresolved does)');
        } else {
            failures++;
            console.error(`FAIL: hostile status token produced statusTitle=${JSON.stringify(result.statusTitle)}, expected ''`);
        }
    }
}

if (failures > 0) {
    console.error(`\n${failures} failure(s).`);
    process.exit(1);
}
console.log('\nAll checks passed.');
