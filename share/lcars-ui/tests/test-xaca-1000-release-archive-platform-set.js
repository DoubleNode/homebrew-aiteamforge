#!/usr/bin/env node
//
//  test-xaca-1000-release-archive-platform-set.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * Regression test for XACA-1000: `isReleaseComplete` in lcars-ui/js/lcars.js
 * must treat EVERY platform a release declares as load-bearing, with no
 * hardcoded ios/android/firebase list.
 *
 * Background: the predicate used to require one of ios/android/firebase to be
 * present before a release could be considered complete. Academy, Command,
 * DNS, Finance, Legal and Medical all declare their single platform as
 * "other", so every release those teams cut evaluated incomplete forever. The
 * ARCHIVE button is rendered by a ternary that emits '' (not a disabled
 * control) when this returns false, so those teams saw no button and no
 * explanation for its absence. Reported against REL-2026-Q3-013.
 *
 * The same hardcoded list caused the opposite error: platforms outside the
 * list were never inspected, so a release with ios at PROD and other at DEV
 * evaluated complete and could be archived mid-pipeline. Both directions are
 * covered below.
 *
 * PARITY: this predicate is duplicated in Python as `is_release_complete` in
 * lcars-ui/server.py, which is the actual archive gate — the JS copy only
 * decides whether the button renders. If they disagree, the UI either offers a
 * button the API refuses or hides one it would have accepted. The CASES table
 * below is intentionally the same set of scenarios asserted by
 * TestIsReleaseComplete in lcars-ui/tests/test_server.py; keep the two in sync
 * when either changes.
 *
 * lcars-ui/js/lcars.js is a large browser file with top-level DOM calls and no
 * jsdom/jest harness in this repo, so this test does NOT `require()` the whole
 * file. It source-slices the pure, DOM-free `isReleaseComplete` declaration
 * between two textual anchors and evaluates that slice in isolation. If either
 * anchor goes missing (renamed/removed/moved), the test fails loudly rather
 * than silently skipping.
 *
 * Run:
 *   node lcars-ui/tests/test-xaca-1000-release-archive-platform-set.js
 *
 * Not wired into an automated JS runner — this repo has no jest/mocha config
 * for lcars-ui. Exits non-zero on any failure so it is CI-runnable as a plain
 * shell step.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const LCARS_JS_PATH = path.join(__dirname, '..', 'js', 'lcars.js');
const source = fs.readFileSync(LCARS_JS_PATH, 'utf8');

const START_ANCHOR = 'function isReleaseComplete(release) {';
const END_ANCHOR = 'async function loadReleases() {';

const startIdx = source.indexOf(START_ANCHOR);
const endIdx = source.indexOf(END_ANCHOR);

if (startIdx === -1 || endIdx === -1 || endIdx <= startIdx) {
    console.error(
        'FAIL: could not locate isReleaseComplete in lcars-ui/js/lcars.js. ' +
        'The function may have been renamed or moved — update this test\'s ' +
        'anchors (START_ANCHOR/END_ANCHOR) to match.'
    );
    process.exit(1);
}

const slice = source.slice(startIdx, endIdx);

// Guard against the anchors silently capturing a stale/duplicate copy: the
// slice must contain the generalized implementation, not the old hardcoded
// list. Without this, a leftover pre-XACA-1000 definition earlier in the file
// could be the one under test and every assertion below would pass vacuously.
if (slice.indexOf('requiredPlatforms') !== -1) {
    console.error(
        'FAIL: the extracted isReleaseComplete still references ' +
        '`requiredPlatforms` — XACA-1000 removed the hardcoded ' +
        'ios/android/firebase list. Either the fix was reverted or the anchors ' +
        'are matching a stale copy of the function.'
    );
    process.exit(1);
}

// eslint-disable-next-line no-new-func
const factory = new Function(`${slice}\nreturn { isReleaseComplete };`);
const { isReleaseComplete } = factory();

/** Build a release dict from a platform→environment mapping. */
function release(platformEnvs) {
    const platforms = {};
    Object.keys(platformEnvs).forEach((name) => {
        platforms[name] = { environment: platformEnvs[name] };
    });
    return { platforms };
}

let failures = 0;

function check(name, input, expected) {
    let actual;
    try {
        actual = isReleaseComplete(input);
    } catch (e) {
        failures++;
        console.error(`FAIL: ${name} — threw ${e.name}: ${e.message}`);
        return;
    }
    if (actual === expected) {
        console.log(`ok - ${name}`);
    } else {
        failures++;
        console.error(`FAIL: ${name} — expected ${expected}, got ${actual}`);
    }
}

// --- Cases mirrored from TestIsReleaseComplete (test_server.py) -------------

const CASES = [
    // XACA-0238 invariants — preserved unchanged by XACA-1000.
    ['all mobile platforms PLANNED is not complete',
        release({ ios: 'PLANNED', android: 'PLANNED', firebase: 'PLANNED' }), false],
    ['single mobile platform PLANNED is not complete',
        release({ ios: 'PLANNED' }), false],
    ['all mobile platforms PROD is complete',
        release({ ios: 'PROD', android: 'PROD', firebase: 'PROD' }), true],
    ['one mobile platform at DEV blocks completion',
        release({ ios: 'PROD', android: 'DEV', firebase: 'PROD' }), false],
    ['one mobile platform at PLANNED blocks completion',
        release({ ios: 'PROD', android: 'PLANNED', firebase: 'PROD' }), false],
    ['partial mobile set, all at PROD, is complete',
        release({ ios: 'PROD' }), true],

    // Empty / malformed input.
    ['empty platforms object is not complete', { platforms: {} }, false],
    ['missing platforms key is not complete', {}, false],
    ['platform with no environment key is not complete',
        { platforms: { other: {} } }, false],

    // XACA-1000 — the defect this test exists for.
    ['non-mobile platform alone at PROD IS complete',
        release({ other: 'PROD' }), true],
    ['non-mobile platform below PROD blocks completion',
        release({ ios: 'PROD', other: 'DEV' }), false],
    ['multiple non-mobile platforms all at PROD is complete',
        release({ other: 'PROD', docs: 'PROD', infra: 'PROD' }), true],
    ['one lagging non-mobile platform blocks its siblings',
        release({ other: 'PROD', docs: 'QA', infra: 'PROD' }), false],
];

CASES.forEach(([name, input, expected]) => check(name, input, expected));

// Mid-pipeline environments are never complete.
['QA', 'ALPHA', 'BETA', 'GAMMA'].forEach((env) => {
    check(`mobile platforms at ${env} are not complete`,
        release({ ios: env, android: env }), false);
    check(`non-mobile platform at ${env} is not complete`,
        release({ other: env }), false);
});

if (failures > 0) {
    console.error(`\n${failures} test(s) failed.`);
    process.exit(1);
}
console.log('\nAll isReleaseComplete parity tests passed.');
