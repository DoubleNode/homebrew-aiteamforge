#!/usr/bin/env node
//
//  test-xaca-1000-release-archive-platform-set.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * Regression tests for XACA-1000 and its gate follow-ups, covering the release
 * ARCHIVE control in lcars-ui/js/lcars.js.
 *
 * XACA-1000 — `isReleaseComplete` must treat EVERY platform a release declares
 * as load-bearing, with no hardcoded ios/android/firebase list. The predicate
 * used to require one of those three keys to be present, so releases on the six
 * teams that declare only "other" (Academy, Command, DNS, Finance, Legal,
 * Medical) evaluated incomplete forever. The same list also caused the opposite
 * error: platforms outside it were never inspected, so ios=PROD + other=DEV
 * evaluated complete and could be archived mid-pipeline.
 *
 * XACA-1000-011 / -018 — an incomplete release used to render an EMPTY STRING
 * where the ARCHIVE button goes. `renderArchiveAction` now returns a disabled
 * button whose tooltip names the blocking platforms. That silence is why the
 * original defect went unnoticed: operators could not tell "not yet allowed"
 * from "feature does not exist".
 *
 * XACA-1000-012 — `getPlatformName` had no entry for "other" and fell through
 * to the raw lowercase key.
 *
 * XACA-1000-013 — all three archive-control states carry a `title`.
 *
 * XACA-1000-015 — malformed platform data must yield `false`, not a throw, so
 * this predicate and its Python twin agree on every input.
 *
 * PARITY: `is_release_complete` in lcars-ui/server.py is the actual archive
 * gate; this JS copy only decides whether the button renders. The CASES table
 * below is deliberately the same set of scenarios asserted by
 * TestIsReleaseComplete in lcars-ui/tests/test_server.py — keep them in sync.
 *
 * lcars-ui/js/lcars.js is a large browser file with top-level DOM calls and no
 * jsdom/jest harness in this repo, so this test does NOT `require()` it. It
 * extracts individual pure functions by brace-matching from the `function NAME(`
 * declaration and evaluates them in isolation.
 *
 * Run:
 *   node lcars-ui/tests/test-xaca-1000-release-archive-platform-set.js
 */

'use strict';

const fs = require('fs');
const path = require('path');

const LCARS_JS_PATH = path.join(__dirname, '..', 'js', 'lcars.js');
const source = fs.readFileSync(LCARS_JS_PATH, 'utf8');

let failures = 0;

function fail(msg) {
    failures++;
    console.error(`FAIL: ${msg}`);
}

/**
 * Extract a top-level `function NAME(...) { ... }` by brace matching.
 *
 * Deliberately NOT anchor-slicing between two textual landmarks: an END_ANCHOR
 * silently widens if an unrelated function is later inserted between the two,
 * pulling extra code into the evaluated slice. Brace matching is bounded by the
 * declaration itself. Throws (rather than returning empty) if the function is
 * renamed or removed, so the test fails loudly instead of skipping.
 */
function extractFunction(name) {
    const needle = `\nfunction ${name}(`;
    const start = source.indexOf(needle);
    if (start === -1) {
        throw new Error(
            `could not locate 'function ${name}(' in lcars-ui/js/lcars.js — ` +
            `it may have been renamed, removed, or turned into an expression. ` +
            `Update this test to match.`
        );
    }
    const bodyStart = source.indexOf('{', start);
    let depth = 0;
    for (let i = bodyStart; i < source.length; i++) {
        const ch = source[i];
        if (ch === '{') depth++;
        else if (ch === '}') {
            depth--;
            if (depth === 0) return source.slice(start + 1, i + 1);
        }
    }
    throw new Error(`unbalanced braces while extracting ${name}`);
}

let isReleaseComplete;
let getIncompletePlatforms;
let renderArchiveAction;
let getPlatformName;
let escapeAttr;
let isReleaseCompleteSrc;

try {
    isReleaseCompleteSrc = extractFunction('isReleaseComplete');
    const slices = [
        isReleaseCompleteSrc,
        extractFunction('getIncompletePlatforms'),
        extractFunction('renderArchiveAction'),
        extractFunction('getPlatformName'),
        extractFunction('escapeAttr'),
    ].join('\n\n');

    // escapeHtml() is DOM-backed (textContent -> innerHTML) and cannot run in
    // bare Node. renderArchiveAction uses it only on release.id, which is not
    // the security-sensitive interpolation here — the tooltip goes through
    // escapeAttr, which IS sliced from source and tested for real below.
    const preamble = 'function escapeHtml(t) { return String(t == null ? "" : t)' +
        '.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }\n';

    // eslint-disable-next-line no-new-func
    const factory = new Function(
        preamble + slices +
        '\nreturn { isReleaseComplete, getIncompletePlatforms, renderArchiveAction,' +
        ' getPlatformName, escapeAttr };'
    );
    ({
        isReleaseComplete,
        getIncompletePlatforms,
        renderArchiveAction,
        getPlatformName,
        escapeAttr,
    } = factory());
} catch (e) {
    console.error(`FAIL: ${e.message}`);
    process.exit(1);
}

// --- Anti-vacuity guard (XACA-1000-017) ------------------------------------
// The original guard string-matched the identifier `requiredPlatforms`, which a
// reintroduced list under any other name would slip straight past. Assert the
// SEMANTIC property instead: a predicate that is correct by XACA-1000's
// definition has no business naming a specific platform at all. This catches a
// hardcoded list regardless of what the variable is called, and it also catches
// a stale duplicate definition being picked up by the extractor.
['ios', 'android', 'firebase', 'web'].forEach((platform) => {
    if (new RegExp(`['"\`]${platform}['"\`]`, 'i').test(isReleaseCompleteSrc)) {
        fail(
            `isReleaseComplete mentions the platform literal '${platform}'. ` +
            `XACA-1000 removed the hardcoded platform list; the predicate must ` +
            `check every DECLARED platform without naming any of them. Either ` +
            `the fix was reverted or a hardcoded list was reintroduced.`
        );
    }
});

function check(name, actual, expected) {
    if (actual === expected) {
        console.log(`ok - ${name}`);
    } else {
        fail(`${name} — expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    }
}

function checkPredicate(name, input, expected) {
    let actual;
    try {
        actual = isReleaseComplete(input);
    } catch (e) {
        fail(`${name} — threw ${e.name}: ${e.message}`);
        return;
    }
    check(name, actual, expected);
}

/** Build a release dict from a platform→environment mapping. */
function release(platformEnvs) {
    const platforms = {};
    Object.keys(platformEnvs).forEach((name) => {
        platforms[name] = { environment: platformEnvs[name] };
    });
    return { id: 'REL-TEST-001', platforms };
}

// --- isReleaseComplete: cases mirrored from test_server.py ------------------

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

    // Empty / malformed input (XACA-1000-015).
    ['empty platforms object is not complete', { platforms: {} }, false],
    ['missing platforms key is not complete', {}, false],
    ['null release is not complete', null, false],
    ['undefined release is not complete', undefined, false],
    ['platform with no environment key is not complete',
        { platforms: { other: {} } }, false],
    ['platforms as an array is not complete', { platforms: [] }, false],
    ['platforms as a non-empty array is not complete',
        { platforms: [{ environment: 'PROD' }] }, false],
    ['platforms as a string is not complete', { platforms: 'PROD' }, false],
    ['platform value as a string is not complete',
        { platforms: { other: 'PROD' } }, false],
    ['platform value as null is not complete',
        { platforms: { other: null } }, false],

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

CASES.forEach(([name, input, expected]) => checkPredicate(name, input, expected));

['QA', 'ALPHA', 'BETA', 'GAMMA'].forEach((env) => {
    checkPredicate(`mobile platforms at ${env} are not complete`,
        release({ ios: env, android: env }), false);
    checkPredicate(`non-mobile platform at ${env} is not complete`,
        release({ other: env }), false);
});

// --- getIncompletePlatforms (XACA-1000-011) --------------------------------

check('getIncompletePlatforms: complete release has no blockers',
    getIncompletePlatforms(release({ other: 'PROD' })).length, 0);
check('getIncompletePlatforms: names the single blocker',
    JSON.stringify(getIncompletePlatforms(release({ ios: 'PROD', android: 'QA' }))),
    JSON.stringify([{ name: 'android', environment: 'QA' }]));
check('getIncompletePlatforms: names every blocker',
    getIncompletePlatforms(release({ ios: 'DEV', android: 'QA', firebase: 'PROD' })).length, 2);
check('getIncompletePlatforms: missing environment reports unknown',
    JSON.stringify(getIncompletePlatforms({ platforms: { other: {} } })),
    JSON.stringify([{ name: 'other', environment: 'unknown' }]));
check('getIncompletePlatforms: malformed platforms yields empty array',
    getIncompletePlatforms({ platforms: 'nope' }).length, 0);

// --- renderArchiveAction (XACA-1000-011 / -013 / -018) ---------------------

const archivedHtml = renderArchiveAction(release({ other: 'PROD' }), true);
check('archived state renders UNARCHIVE', /UNARCHIVE/.test(archivedHtml), true);
check('archived state is not disabled', /disabled/.test(archivedHtml), false);
check('archived state has a tooltip', /title="[^"]+"/.test(archivedHtml), true);

const completeHtml = renderArchiveAction(release({ other: 'PROD' }), false);
check('complete state renders an enabled ARCHIVE', /ARCHIVE/.test(completeHtml), true);
check('complete state is not disabled', /disabled/.test(completeHtml), false);
check('complete state is clickable', /toggleReleaseArchive/.test(completeHtml), true);
check('complete state has a tooltip', /title="[^"]+"/.test(completeHtml), true);

const incompleteHtml = renderArchiveAction(release({ ios: 'PROD', android: 'QA' }), false);
// THE core regression: this branch used to return ''.
check('incomplete state is NOT an empty string', incompleteHtml.length > 0, true);
check('incomplete state renders a button', /<button/.test(incompleteHtml), true);
check('incomplete state is disabled', /disabled/.test(incompleteHtml), true);
check('incomplete state is NOT clickable',
    /toggleReleaseArchive/.test(incompleteHtml), false);
check('incomplete tooltip names the blocking platform',
    /Android/.test(incompleteHtml), true);
check('incomplete tooltip names the blocking environment',
    /QA/.test(incompleteHtml), true);
check('incomplete tooltip does not name a passing platform',
    /iOS/.test(incompleteHtml), false);

const noPlatformsHtml = renderArchiveAction({ id: 'REL-X', platforms: {} }, false);
check('no-platforms state still renders a disabled button',
    /<button[^>]*disabled/.test(noPlatformsHtml), true);
check('no-platforms tooltip explains the absence',
    /declares no platforms/.test(noPlatformsHtml), true);

// Tooltip must be attribute-escaped, not merely HTML-escaped: escapeHtml leaves
// quotes alone, which would break out of title="..." (the XACA-0416 lesson).
const quoteRelease = { id: 'REL-Q', platforms: {} };
quoteRelease.platforms['ev"il onmouseover=alert(1) x='] = { environment: 'DEV' };
const quotedHtml = renderArchiveAction(quoteRelease, false);
// The quote from the platform name must appear as the &quot; ENTITY inside the
// title attribute. If it appeared raw it would close the attribute early and
// everything after it would become live markup.
check('tooltip escapes the double quote as an entity',
    /title="[^"]*&quot;[^"]*"/.test(quotedHtml), true);
// And the attribute value, read up to its real closing quote, must not contain
// a raw one — this is the assertion that would actually fail on a breakout.
check('title attribute value contains no raw double quote',
    quotedHtml.split('title="')[1].split('"')[0].indexOf('\u0022') === -1, true);
// escapeHtml() alone would pass neither: it leaves quotes untouched by design.
check('payload is inert text inside the attribute, not markup',
    /onmouseover=alert\(1\)[^"]*"/.test(quotedHtml) &&
        quotedHtml.indexOf('ev\u0022il') === -1, true);

// --- getPlatformName (XACA-1000-012) --------------------------------------

check('getPlatformName maps ios', getPlatformName('ios'), 'iOS');
check('getPlatformName maps android', getPlatformName('android'), 'Android');
check('getPlatformName maps firebase', getPlatformName('firebase'), 'Firebase');
check('getPlatformName maps other (XACA-1000-012)', getPlatformName('other'), 'Other');
check('getPlatformName title-cases an unmapped key',
    getPlatformName('docs'), 'Docs');
check('getPlatformName tolerates null', getPlatformName(null), '');
check('getPlatformName tolerates undefined', getPlatformName(undefined), '');
check('getPlatformName is case-insensitive', getPlatformName('OTHER'), 'Other');

// --- escapeAttr (XACA-1000-013) -------------------------------------------

check('escapeAttr escapes double quotes', escapeAttr('a"b'), 'a&quot;b');
check('escapeAttr escapes single quotes', escapeAttr("a'b"), 'a&#39;b');
check('escapeAttr escapes ampersand first', escapeAttr('&<>'), '&amp;&lt;&gt;');
check('escapeAttr handles null', escapeAttr(null), '');
check('escapeAttr does not double-escape a plain string',
    escapeAttr('Android is at QA, not PROD'), 'Android is at QA, not PROD');

if (failures > 0) {
    console.error(`\n${failures} test(s) failed.`);
    process.exit(1);
}
console.log('\nAll XACA-1000 archive-control tests passed.');
