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
    // Locate the body's opening brace by first walking PAST the parameter
    // list, matching parens rather than scanning for the first '{'. A
    // default parameter value that is itself an object literal (e.g.
    // `renderReleaseCard(release, flowConfig = null, projectEnvironments =
    // {})`) contains a `{}` that balances to zero immediately, so a naive
    // `source.indexOf('{', start)` finds that `{}` instead of the function
    // body and returns an empty/truncated slice — caught while wiring up
    // renderReleaseCard for XACA-1001-006 (its extraction silently produced
    // an 8-char "body" that was just the tail of the signature, and the
    // generated Function source then failed with a bare "Unexpected token
    // 'return'" from the real body's now-dangling statements).
    const parenOpen = source.indexOf('(', start);
    let parenDepth = 0;
    let parenClose = -1;
    for (let i = parenOpen; i < source.length; i++) {
        const ch = source[i];
        if (ch === '(') parenDepth++;
        else if (ch === ')') {
            parenDepth--;
            if (parenDepth === 0) { parenClose = i; break; }
        }
    }
    if (parenClose === -1) {
        throw new Error(`unbalanced parens while locating ${name}'s parameter list`);
    }
    const bodyStart = source.indexOf('{', parenClose);
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
let jsAttrEscape;
let announceToScreenReader;
let renderReleaseCard;
let __flush;
let __state;
let isReleaseCompleteSrc;

try {
    isReleaseCompleteSrc = extractFunction('isReleaseComplete');
    const slices = [
        isReleaseCompleteSrc,
        extractFunction('getIncompletePlatforms'),
        extractFunction('renderArchiveAction'),
        extractFunction('getPlatformName'),
        extractFunction('escapeAttr'),
        extractFunction('jsAttrEscape'),
        extractFunction('announceToScreenReader'),
        // XACA-1001-006: renderReleaseCard is the actual PROMOTE/EDIT/DELETE
        // markup source (renderArchiveAction only covers the ARCHIVE button).
        // getReleaseEnvironments and buildItemTagsHtml are its two dependencies
        // that are not already sliced above; both are extracted UNMODIFIED so
        // the onclick strings tested below are exactly what ships, not a
        // reimplementation of them.
        extractFunction('getReleaseEnvironments'),
        extractFunction('buildItemTagsHtml'),
        extractFunction('renderReleaseCard'),
    ].join('\n\n');

    // escapeHtml() is DOM-backed (textContent -> innerHTML) and cannot run in
    // bare Node. renderArchiveAction uses it only on release.id, which is not
    // the security-sensitive interpolation here — the tooltip goes through
    // escapeAttr, which IS sliced from source and tested for real below.
    // announceToScreenReader is the first sliced function that touches the DOM,
    // so the factory gets a minimal document/window stub. It is deliberately
    // minimal — just enough to observe what the function DOES (element created,
    // attributes set, appended once, text written on a timer) rather than
    // simulating a browser.
    const preamble = 'function escapeHtml(t) { return String(t == null ? "" : t)' +
        '.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }\n' +
        'var __els = {}; var __appended = []; var __timers = []; var __nextTimer = 1;\n' +
        'var document = {\n' +
        '  body: { appendChild: function (el) { __appended.push(el); __els[el.id] = el; } },\n' +
        '  getElementById: function (id) { return __els[id] || null; },\n' +
        '  createElement: function () {\n' +
        '    return { id: "", textContent: "", style: { cssText: "" }, _attrs: {},\n' +
        '             setAttribute: function (k, v) { this._attrs[k] = v; } };\n' +
        '  }\n' +
        '};\n' +
        'var window = {\n' +
        '  setTimeout: function (fn) { var h = __nextTimer++; __timers.push({h: h, fn: fn, live: true}); return h; },\n' +
        '  clearTimeout: function (h) { __timers.forEach(function (t) { if (t.h === h) t.live = false; }); }\n' +
        '};\n' +
        // XACA-1001-012: mark each timer consumed (live = false) BEFORE
        // calling it, not just when clearTimeout() cancels it. A real
        // setTimeout firing is a one-shot event -- calling __flush() again
        // later must NOT re-run it. The original stub only ever set
        // live = false from clearTimeout(), so a timer that had already
        // fired stayed "live" forever and was RE-FIRED on every later
        // __flush() call in the same test run. That is precisely why the two
        // checks this ticket targets ("second message replaces the first",
        // "rapid consecutive calls announce the last message only") could
        // pass by TIMER-ORDERING ALONE even with clearTimeout() completely
        // broken: a stale already-fired timer would refire and repaint
        // stale text, then a genuinely-live later timer would refire right
        // after it and paint over it again, landing on the right answer for
        // the wrong reason. Surfaced by the new pre-flush live-timer-count
        // assertion below, which is meaningless against the old stub (it
        // counts every timer ever created that was never explicitly
        // cancelled, fired or not).
        'function __flush() { __timers.filter(function (t) { return t.live; })' +
        '.forEach(function (t) { t.live = false; t.fn(); }); }\n' +
        'function __state() { return { els: __els, appended: __appended, timers: __timers }; }\n' +
        // XACA-1001-006: minimal stand-ins for renderReleaseCard's two global
        // dependencies. CANONICAL_STAGES is a plain data constant (copied
        // verbatim, not reimplemented logic). releasesState is a stub with just
        // the one member renderReleaseCard reads (expandedReleases). Test
        // release objects deliberately carry no `tags` and no `targetDate`, so
        // buildItemTagsHtml short-circuits before touching `document` and the
        // formatTargetDate branch is never taken -- neither needs a fuller stub.
        'var CANONICAL_STAGES = ["DEV", "QA", "ALPHA", "BETA", "GAMMA", "PROD"];\n' +
        'var releasesState = { expandedReleases: new Set() };\n';

    // eslint-disable-next-line no-new-func
    const factory = new Function(
        preamble + slices +
        '\nreturn { isReleaseComplete, getIncompletePlatforms, renderArchiveAction,' +
        ' getPlatformName, escapeAttr, jsAttrEscape, announceToScreenReader,' +
        ' renderReleaseCard, __flush, __state };'
    );
    ({
        isReleaseComplete,
        getIncompletePlatforms,
        renderArchiveAction,
        getPlatformName,
        escapeAttr,
        jsAttrEscape,
        announceToScreenReader,
        renderReleaseCard,
        __flush,
        __state,
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

// XACA-1001-012 (Task A): the two checks below used to be a single assertion,
// `/disabled/.test(incompleteHtml) === true`. Since XACA-1001 converted this
// button to `aria-disabled="true"`, that regex matches the substring "disabled"
// INSIDE "aria-disabled" -- it would pass identically for `aria-disabled`,
// `data-disabled`, or even a typo'd `not-disabled`. It passed before Wave 1
// (native `disabled`) and passes after (aria-disabled) without distinguishing
// them, so it stopped proving anything the moment the markup changed under it.
// Split into two checks that assert what the ticket actually changed:
//   1. the SPECIFIC attribute the button must carry now
//   2. the ABSENCE of the old native attribute, via a regex anchored on
//      whitespace-then-"disabled" so it does not also match "aria-disabled"
//      (there is no whitespace immediately before "disabled" in that string).
const incompleteHtml = renderArchiveAction(release({ ios: 'PROD', android: 'QA' }), false);
// THE core regression: this branch used to return ''.
check('incomplete state is NOT an empty string', incompleteHtml.length > 0, true);
check('incomplete state renders a button', /<button/.test(incompleteHtml), true);
check('incomplete state carries aria-disabled="true"',
    /aria-disabled="true"/.test(incompleteHtml), true);
check('incomplete state carries NO native disabled attribute',
    /<button[^>]*\sdisabled[\s>]/.test(incompleteHtml), false);
check('incomplete state is NOT clickable',
    /toggleReleaseArchive/.test(incompleteHtml), false);
check('incomplete tooltip names the blocking platform',
    /Android/.test(incompleteHtml), true);
check('incomplete tooltip names the blocking environment',
    /QA/.test(incompleteHtml), true);
check('incomplete tooltip does not name a passing platform',
    /iOS/.test(incompleteHtml), false);

// Same substring hazard as above: `/<button[^>]*disabled/` matches
// "aria-disabled" too, so it cannot tell an aria-disabled button apart from a
// native-disabled one. Split the same way.
const noPlatformsHtml = renderArchiveAction({ id: 'REL-X', platforms: {} }, false);
check('no-platforms state still renders an aria-disabled button',
    /<button[^>]*aria-disabled="true"/.test(noPlatformsHtml), true);
check('no-platforms state carries NO native disabled attribute',
    /<button[^>]*\sdisabled[\s>]/.test(noPlatformsHtml), false);
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

// --- onclick JS-string-literal escaping (XACA-1000-021) --------------------
// THREE escapers, THREE contexts, not interchangeable. The release id lands
// inside a JS STRING LITERAL within an HTML attribute --
// toggleReleaseArchive('<id>') -- where escapeHtml is NOT sufficient: it is
// textContent->innerHTML and leaves ' and \\ untouched, so an id can close the
// string and execute. This shipped wrong in the first cut of
// renderArchiveAction and was caught in review, so it gets a regression test.
const evilId = "x'); alert(document.cookie); ('";
const evilArchived = renderArchiveAction({ id: evilId, platforms: {} }, true);
const evilComplete = renderArchiveAction(
    { id: evilId, platforms: { other: { environment: 'PROD' } } }, false);

// A substring check is NOT the right assertion here and was wrong in the first
// draft of this test: the correctly-escaped output still CONTAINS "'); alert"
// as a substring, because the escaped form is  \'); alert  . The property that
// actually matters is that the id cannot TERMINATE the JS string it sits in.
// So: walk to the first UNESCAPED quote after toggleReleaseArchive(' and assert
// the call closes immediately there — i.e. the whole id stayed inside one string.
function firstUnescapedQuoteEndsTheCall(html) {
    const open = "toggleReleaseArchive('";
    const start = html.indexOf(open);
    if (start === -1) return false;
    let i = start + open.length;
    while (i < html.length) {
        if (html[i] === '\\') { i += 2; continue; }   // escaped char: skip both
        if (html[i] === "'") break;                    // first unescaped quote
        i++;
    }
    // The argument string must close, the CALL must close, and the onclick
    // ATTRIBUTE must end right there. Checking only for "')" is VACUOUS -- a
    // successful breakout also produces "');" at that point (the injected id
    // closes the string and the call, then runs its own statements). Requiring
    // the attribute's closing double-quote immediately after is what separates
    // "the id ended the string" from "the id escaped the string". Verified by
    // reverting the fix: this assertion passes with escapeHtml under the
    // 2-char form and fails under the 3-char form.
    return html.slice(i, i + 3) === "')\"";
}

check('onclick: a hostile release id cannot terminate the JS string (archived)',
    firstUnescapedQuoteEndsTheCall(evilArchived), true);
check('onclick: a hostile release id cannot terminate the JS string (complete)',
    firstUnescapedQuoteEndsTheCall(evilComplete), true);
// Positive control: the escaped form must actually be present, so the test
// above cannot pass merely because the id was dropped entirely.
check('onclick: the id is present in escaped form, not silently discarded',
    /\\'\); alert/.test(evilArchived), true);
check('jsAttrEscape escapes a single quote for a JS string literal',
    jsAttrEscape("a'b"), "a\\'b");
check('jsAttrEscape escapes a backslash first',
    jsAttrEscape('a\\b'), 'a\\\\b');
// escapeHtml would NOT have caught this -- that is the whole point.
check('escapeAttr alone is insufficient for a JS string literal (it leaves \\ )',
    escapeAttr('a\\b'), 'a\\b');

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

// --- Disabled-state styling (XACA-1000-020) --------------------------------
// A disabled ARCHIVE button that LOOKS identical to the live buttons beside it
// defeats the point of rendering it at all. The CSS lives in a separate file
// from the markup, so `git diff -- lcars-ui/js` cannot show this gap; assert it
// here, against the stylesheet, or nothing does.
const CSS_PATH = path.join(__dirname, '..', 'css', 'lcars.css');
const css = fs.readFileSync(CSS_PATH, 'utf8');

check('stylesheet has a :disabled rule for .release-action-btn',
    /\.release-action-btn:disabled\s*\{/.test(css), true);
check('disabled action buttons get a not-allowed cursor',
    /\.release-action-btn:disabled\s*\{[^}]*cursor:\s*not-allowed/.test(css), true);
check('disabled action buttons are visually dimmed',
    /\.release-action-btn:disabled\s*\{[^}]*opacity:/.test(css), true);
// The base .release-action-btn:hover rule has no :not(:disabled) guard, so a
// disabled button would otherwise LIGHTEN on hover while being inert.
check('the disabled hover state is neutralised',
    /\.release-action-btn:disabled:hover\s*\{/.test(css), true);
// pointer-events:none would kill the native tooltip, which is the entire
// explanation channel for why the archive is blocked.
const disabledRule = (css.match(/\.release-action-btn:disabled\s*\{[^}]*\}/) || [''])[0];
check('disabled rule does NOT use pointer-events:none (it would suppress the tooltip)',
    /pointer-events:\s*none/.test(disabledRule), false);
// XACA-1001: the .release-card.archived group used to use pointer-events:none
// to dim PROMOTE/EDIT/DELETE, which killed hover (and with it the `title`
// tooltip) and is no longer safe now that click-through is guarded in JS
// instead of blocked by the browser. Assert the specific rule block that
// covers those three buttons, not the whole file, so an unrelated
// pointer-events:none elsewhere in the stylesheet cannot mask a regression.
const archivedActionRule = (css.match(
    /\.release-card\.archived \.release-action-btn\.edit-btn,[\s\S]*?\{[^}]*\}/
) || [''])[0];
check('archived-card action-button rule exists',
    archivedActionRule.length > 0, true);
check('archived-card action-button rule does NOT use pointer-events:none' +
    ' (it would kill hover and silence the reason tooltip)',
    /pointer-events:\s*none/.test(archivedActionRule), false);

// --- click guard on aria-disabled PROMOTE/EDIT/DELETE (XACA-1001-006) ------
//
// The safety-critical property Wave 1 introduced: an aria-disabled button is
// still a live element that fires `click`. Making it inert is the JOB of the
// leading `if (this.getAttribute('aria-disabled') === 'true') return;` guard
// inside each onclick -- the browser will not do it for us. If that guard is
// ever weakened or removed, this ticket's fix makes previously-safe controls
// clickable, which is strictly worse than the native `disabled` it replaced.
//
// This must exercise the ACTUAL rendered onclick STRING from renderReleaseCard
// -- not a hand-written reimplementation of the guard, which would prove
// nothing about the shipped markup. The onclick text is identical between the
// archived and active renders (only the surrounding aria-disabled/title/
// aria-describedby attributes differ); what changes is what `this.getAttribute`
// would actually return in each case, which is exactly what is stubbed below,
// keyed off the REAL attribute value read back out of each render.

/** Locate a `<button class="EXACT">...` tag and return its outer markup. */
function extractButtonTag(html, exactClassAttr) {
    const marker = 'class="' + exactClassAttr + '"';
    const markerIdx = html.indexOf(marker);
    if (markerIdx === -1) return null;
    const tagStart = html.lastIndexOf('<button', markerIdx);
    const tagEnd = html.indexOf('>', markerIdx);
    if (tagStart === -1 || tagEnd === -1) return null;
    return html.slice(tagStart, tagEnd + 1);
}

function getAttr(tag, name) {
    const m = tag && tag.match(new RegExp(name + '="([^"]*)"'));
    return m ? m[1] : null;
}

/** A call-count spy with no real Jest/Sinon dependency in this repo. */
function makeSpy() {
    const spy = function () { spy.callCount++; };
    spy.callCount = 0;
    return spy;
}

/**
 * Execute a real extracted onclick attribute string against a stub `this`
 * (the button) whose getAttribute('aria-disabled') returns exactly what was
 * read back from the actual rendered tag. The three action functions are
 * passed in as parameters so the Function constructor's global-scope body can
 * see the spies without polluting the real global object.
 */
function runOnclick(onclickSrc, ariaDisabledValue, spies) {
    const btn = {
        getAttribute: function (name) {
            return name === 'aria-disabled' ? ariaDisabledValue : null;
        },
    };
    const evt = { stopPropagation: function () {} };
    // eslint-disable-next-line no-new-func
    const fn = new Function(
        'event', 'promoteRelease', 'showEditReleaseModal', 'deleteRelease', onclickSrc
    );
    fn.call(btn, evt, spies.promoteRelease, spies.showEditReleaseModal, spies.deleteRelease);
}

const archivedCardRelease = {
    id: 'REL-CARD-ARCH', name: 'Archived Card Release',
    status: 'archived', platforms: {},
};
const activeCardRelease = {
    id: 'REL-CARD-ACTIVE', name: 'Active Card Release',
    status: 'active', platforms: { other: { environment: 'DEV' } },
};
const archivedCardHtml = renderReleaseCard(archivedCardRelease);
const activeCardHtml = renderReleaseCard(activeCardRelease);

function checkGuardedButton(label, exactClassAttr, fnName) {
    const archivedTag = extractButtonTag(archivedCardHtml, exactClassAttr);
    const activeTag = extractButtonTag(activeCardHtml, exactClassAttr);
    if (!archivedTag || !activeTag) {
        fail(`${label}: could not locate <button class="${exactClassAttr}"> in ` +
            `rendered renderReleaseCard() markup — it may have been renamed.`);
        return;
    }

    const archivedOnclick = getAttr(archivedTag, 'onclick');
    const activeOnclick = getAttr(activeTag, 'onclick');
    const archivedAria = getAttr(archivedTag, 'aria-disabled');
    const activeAria = getAttr(activeTag, 'aria-disabled');

    check(`${label}: archived render carries aria-disabled="true"`, archivedAria, 'true');
    check(`${label}: active render carries no aria-disabled attribute`, activeAria, null);

    // NEGATIVE CONTROL: guard active -> the real handler must NOT call fnName.
    let spies = { promoteRelease: makeSpy(), showEditReleaseModal: makeSpy(), deleteRelease: makeSpy() };
    runOnclick(archivedOnclick, archivedAria, spies);
    check(`${label}: guard active (aria-disabled="true") blocks ${fnName}()`,
        spies[fnName].callCount, 0);

    // POSITIVE CONTROL (mandatory pairing): guard inactive -> the SAME
    // extracted handler source, run against the non-archived render's actual
    // attribute state, MUST call fnName. Without this, "blocked" above could
    // just as easily mean "the eval silently failed" or "the spy was never
    // wired" -- only the pair proves the negative control is measuring the
    // guard and not a broken harness.
    spies = { promoteRelease: makeSpy(), showEditReleaseModal: makeSpy(), deleteRelease: makeSpy() };
    runOnclick(activeOnclick, activeAria, spies);
    check(`${label}: guard inactive (no aria-disabled) lets ${fnName}() run`,
        spies[fnName].callCount, 1);

    // aria-describedby must resolve to a real rendered .sr-only span, or the
    // reason text is announced to nobody -- a dangling reference is invisible
    // to every check above.
    const archivedDescribedBy = getAttr(archivedTag, 'aria-describedby');
    check(`${label}: archived render has an aria-describedby id`,
        !!archivedDescribedBy, true);
    if (archivedDescribedBy) {
        const spanRe = new RegExp(
            '<span id="' + archivedDescribedBy + '" class="sr-only">[^<]*</span>'
        );
        check(`${label}: aria-describedby id resolves to a rendered .sr-only span`,
            spanRe.test(archivedCardHtml), true);
    }

    // Inert buttons carry BOTH title and aria-describedby; enabled buttons
    // carry NEITHER -- either half missing/leaking is a regression.
    check(`${label}: archived render has a title tooltip`,
        /title="[^"]+"/.test(archivedTag), true);
    check(`${label}: active render has NO title attribute`,
        /\stitle="/.test(activeTag), false);
    check(`${label}: active render has NO aria-describedby attribute`,
        /aria-describedby=/.test(activeTag), false);
}

checkGuardedButton('PROMOTE', 'release-action-btn promote-btn', 'promoteRelease');
checkGuardedButton('EDIT', 'release-action-btn edit-btn', 'showEditReleaseModal');
checkGuardedButton('DELETE', 'release-action-btn danger delete-btn', 'deleteRelease');

// ARCHIVE is a deliberate exception (see renderArchiveAction's XACA-1001
// comment): its inert branch has NO action call behind the guard at all, so
// a "spy not called" negative control would pass trivially -- there is
// nothing to call, which proves nothing about whether a guard works. That is
// precisely the false-confidence failure mode this whole task exists to
// prevent, so do NOT write that check here. Assert the STRUCTURAL property
// instead: the rendered markup contains no reference to toggleReleaseArchive
// at all when the button is inert. A future reader must not mistake a
// passing ARCHIVE check here for proof that ARCHIVE's guard is load-bearing
// -- it is decorative, kept only for attribute uniformity across all four
// controls (see the comment in renderArchiveAction).
const incompleteCardRelease = {
    id: 'REL-CARD-INCOMPLETE', name: 'Incomplete Card Release',
    status: 'active', platforms: { ios: 'PROD', android: 'QA' },
};
const incompleteCardHtml = renderReleaseCard(incompleteCardRelease);
const incompleteArchiveTag = extractButtonTag(incompleteCardHtml, 'release-action-btn archive-btn');
check('ARCHIVE (structural only, NOT a guard-effectiveness proof): inert render' +
    ' carries aria-disabled="true"', getAttr(incompleteArchiveTag, 'aria-disabled'), 'true');
check('ARCHIVE (structural only): inert render calls toggleReleaseArchive nowhere' +
    ' in the whole card (there is nothing for the guard to gate)',
    /toggleReleaseArchive/.test(incompleteCardHtml), false);

// --- announceToScreenReader (XACA-1000-025) --------------------------------
// This was the only function added in round 2 with no coverage at all. It is
// the entire accessibility affordance for archive/unarchive — a sighted user
// sees the card re-render, a screen-reader user has nothing else — so an
// untested version of it is an affordance nobody can prove exists.

announceToScreenReader('Release archived.');
let st = __state();
const region = st.els['lcars-sr-announcer'];

check('announce: creates the live region', !!region, true);
check('announce: region has role=status', region && region._attrs.role, 'status');
check('announce: region is polite, not assertive',
    region && region._attrs['aria-live'], 'polite');
check('announce: region is atomic', region && region._attrs['aria-atomic'], 'true');
check('announce: region is appended to the document exactly once',
    st.appended.length, 1);
// Visually hidden but still in the accessibility tree — display:none or
// visibility:hidden would remove it and silence the announcement entirely.
check('announce: region is visually hidden without leaving the a11y tree',
    /position:absolute/.test(region.style.cssText) &&
        !/display:\s*none/.test(region.style.cssText) &&
        !/visibility:\s*hidden/.test(region.style.cssText), true);
// The text is written on a timer, not synchronously: a live region whose text
// is unchanged is not re-announced, so it is cleared first.
check('announce: text is empty until the timer fires', region.textContent, '');
__flush();
check('announce: text is set after the timer fires',
    region.textContent, 'Release archived.');

// Second call must reuse the same region rather than stacking new ones.
announceToScreenReader('Release unarchived and returned to the active list.');
st = __state();
check('announce: reuses the existing region (no duplicate appended)',
    st.appended.length, 1);
// XACA-1001-012: PRE-FLUSH check. The prior version of this test only ever
// checked "text is empty until the timer fires" right after the FIRST
// announceToScreenReader() call ever made (above). A regression where a
// SECOND (or later) call skipped the clear-before-set step would go
// undetected by that alone, because __flush() fires in push order regardless
// and the eventual textContent would look identical either way. Check it
// again here, before flushing, on a call that is not the first.
check('announce: text is cleared again on a RE-announce, before its timer fires',
    st.els['lcars-sr-announcer'].textContent, '');
__flush();
check('announce: second message replaces the first',
    st.els['lcars-sr-announcer'].textContent,
    'Release unarchived and returned to the active list.');

// A pending set must be cancelled so rapid consecutive calls announce the LAST
// message, not an interleaving of both.
announceToScreenReader('first');
announceToScreenReader('second');
// XACA-1001-012: PRE-FLUSH check. __flush() fires every LIVE timer in PUSH
// ORDER -- so if clearTimeout() were entirely broken, the 'first' timer would
// still be pushed before the 'second' timer, __flush would run 'first' then
// 'second' in that order, and the FINAL textContent would still read 'second'
// by push-order coincidence, not because cancellation worked. The check below
// (on the post-flush textContent alone, as this test used to read) cannot
// tell those two cases apart. Counting LIVE timers BEFORE flushing can: it is
// what actually proves the pending 'first' timer was cancelled rather than
// merely outrun.
check('announce: rapid consecutive calls leave exactly ONE live timer pending',
    __state().timers.filter(function (t) { return t.live; }).length, 1);
__flush();
check('announce: rapid consecutive calls announce the last message only',
    __state().els['lcars-sr-announcer'].textContent, 'second');

// XACA-1001-012: identical-message round-trip. Assistive tech does not
// re-announce a live region whose text is unchanged -- that is the entire
// reason the clear-then-set sequence exists, and nothing above covers it:
// every prior case announces a DIFFERENT string than what preceded it, so a
// regression that skipped the clear specifically when the new message equals
// the old one would still pass every check above. Announcing the same string
// twice must still go 'X' -> '' -> 'X'.
announceToScreenReader('X');
__flush();
check('announce: identical-message round-trip — first announce sets the text',
    __state().els['lcars-sr-announcer'].textContent, 'X');
announceToScreenReader('X');
check('announce: identical-message round-trip — re-announce clears before its timer fires',
    __state().els['lcars-sr-announcer'].textContent, '');
__flush();
check('announce: identical-message round-trip — re-announce sets the text again',
    __state().els['lcars-sr-announcer'].textContent, 'X');

// Empty/absent messages must be a no-op, not an empty announcement.
const beforeCount = __state().timers.filter(function (t) { return t.live; }).length;
announceToScreenReader('');
announceToScreenReader(null);
announceToScreenReader(undefined);
check('announce: empty/null/undefined messages are a no-op',
    __state().timers.filter(function (t) { return t.live; }).length, beforeCount);

if (failures > 0) {
    console.error(`\n${failures} test(s) failed.`);
    process.exit(1);
}
console.log('\nAll XACA-1000 archive-control tests passed.');
