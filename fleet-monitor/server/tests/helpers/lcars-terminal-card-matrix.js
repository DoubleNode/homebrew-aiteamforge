//
//  lcars-terminal-card-matrix.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-0990-001: shared input matrix + capture/serialize logic for
 * characterizing isLcarsTerminal() and createServiceOnlyLcarsCard() across
 * the 5 client apps under fleet-monitor/server/public/{lcars,lcars2}/js/,
 * BEFORE those two byte-identical functions are extracted into
 * fleet-monitor/server/public/shared/js/lcars-terminal-card.js (XACA-0990).
 *
 * This module is imported by BOTH:
 *   - scripts/generate-xaca-0990-001-baseline.js (one-time, to produce the
 *     checked-in golden file)
 *   - xaca-0990-001-lcars-terminal-card-characterization.test.js (every
 *     run, to recompute "actual" and diff it against that golden file)
 * so there is exactly one definition of the matrix and the capture logic --
 * the baseline and the replay can never silently drift apart from each other
 * by using two hand-written copies of the same cases.
 *
 * Loading strategy (no production-code change required):
 *   Reuses tests/helpers/lcars-client-dom-stub.js's createDomStub() +
 *   loadClientApp() -- the same vm.Context loader XACA-0983-013/014/015
 *   already ships, which reads the REAL shipped client file off disk,
 *   appends a `window.__lcarsTestExports = {...}` line just before the
 *   file's closing `})();`, and runs it in a hand-rolled DOM stub (no
 *   jsdom dependency in package.json). isLcarsTerminal was added to that
 *   loader's export list as part of this ticket (additive change to a test
 *   helper only -- the existing XACA-0983-013/014/015 suite was re-run
 *   after that edit and still passes 52/52).
 *
 * Every case creates a FRESH createDomStub()/loadClientApp() pair (mirrors
 * the existing suite's per-test pattern) so windowOpenCalls and any DOM
 * state from one case can never leak into the next.
 */

const fs = require('node:fs');
const path = require('node:path');
const { createDomStub, loadClientApp } = require('./lcars-client-dom-stub.js');

const PUBLIC_ROOT = path.join(__dirname, '..', '..', 'public');

// XACA-1110-005/-009: the former 4 byte-near-identical lcars2 dashboard app
// files collapsed into ONE config-parameterized module
// (lcars2/js/lcars-fleet-dashboard-app.js), which ships to BOTH dev-team
// and the tap identically (it is required by academy + all, which are
// themselves tap-shipped -- see the design decision doc, D5). v1's
// lcars/js/lcars-dashboard-app.js is untouched by this ticket. So this
// suite's file set is now the SAME 2 files in both repos -- the
// dev-team/tap split that used to exist here (5 files vs. 3) no longer
// applies to lcars2 at all.
const ALL_CLIENT_FILES = [
    'lcars/js/lcars-dashboard-app.js',
    'lcars2/js/lcars-fleet-dashboard-app.js'
];
const CLIENT_FILES = ALL_CLIENT_FILES.filter((relPath) => fs.existsSync(path.join(PUBLIC_ROOT, relPath)));

// The one -- and ONLY one -- file set this suite may ever legitimately run
// against post-unification (see ALL_CLIENT_FILES comment above: dev-team
// and the tap now carry the identical 2 files, so there is nothing left to
// distinguish two entries by). identifyKnownFileSet() below turns "whatever
// exists" into an assertion: the discovered set must equal this literal
// array exactly, or the suite fails loudly naming what's missing/unexpected
// -- same XACA-0990-gate-finding-1 protection as before unification, now
// against a single known-good shape instead of two.
const KNOWN_GOOD_FILE_SETS = {
    'dev-team + tap (2 files -- lcars2 unified post-XACA-1110)': [
        'lcars/js/lcars-dashboard-app.js',
        'lcars2/js/lcars-fleet-dashboard-app.js'
    ]
};

// Returns { label, files } for the KNOWN_GOOD_FILE_SETS entry that exactly
// matches discoveredFiles (order-independent), or throws a descriptive
// Error naming what was unexpected / what was missing from the closest known
// set. `files` on the returned object is the literal array from
// KNOWN_GOOD_FILE_SETS -- a fixed constant in source, NOT derived from
// discoveredFiles.length -- so callers that need an "expected count" can use
// files.length as a number that is independent of the very thing being
// verified (see the characterization test's vacuity guard).
function identifyKnownFileSet(discoveredFiles) {
    const discoveredSorted = [...discoveredFiles].sort();
    for (const [label, files] of Object.entries(KNOWN_GOOD_FILE_SETS)) {
        const knownSorted = [...files].sort();
        const matches =
            discoveredSorted.length === knownSorted.length &&
            discoveredSorted.every((f, i) => f === knownSorted[i]);
        if (matches) {
            return { label: label, files: files };
        }
    }

    const allKnownFiles = new Set(Object.values(KNOWN_GOOD_FILE_SETS).flat());
    const unexpected = discoveredFiles.filter((f) => !allKnownFiles.has(f));
    // XACA-0990 re-review finding 2: rank by SYMMETRIC difference, not by
    // missing-count alone. A superset (e.g. the tap's 3 files plus one that
    // should not be there) has missing.length === 0, so a missing-only rank
    // named it "closest" and then reported "missing: []" -- true, useless,
    // and actively misleading for what is the likeliest real failure. Both
    // halves of the difference are now ranked and reported.
    const ranked = Object.entries(KNOWN_GOOD_FILE_SETS)
        .map(([label, files]) => {
            const missing = files.filter((f) => !discoveredFiles.includes(f));
            const extra = discoveredFiles.filter((f) => !files.includes(f));
            return { label: label, missing: missing, extra: extra };
        })
        .sort((a, b) => (a.missing.length + a.extra.length) - (b.missing.length + b.extra.length));
    const closest = ranked[0];

    throw new Error(
        'CLIENT_FILES resolved to a file set that matches NEITHER known-good ' +
            'configuration.\n' +
            'Discovered (' + discoveredFiles.length + '): ' + JSON.stringify(discoveredSorted) + '\n' +
            (unexpected.length > 0
                ? 'File(s) not in ANY known set: ' + JSON.stringify(unexpected) + '\n'
                : '') +
            'Closest known set "' + closest.label + '":\n' +
            '  missing from discovered: ' + JSON.stringify(closest.missing) + '\n' +
            '  present but not in that set: ' + JSON.stringify(closest.extra)
    );
}

// ============================================================================
// isLcarsTerminal(teamData) input matrix -- 10 cases
// ============================================================================
const ISLCARS_CASES = [
    { id: 'null_teamData', teamData: null },
    { id: 'undefined_teamData', teamData: undefined },
    { id: 'session_name_lowercase_lcars', teamData: { sessions: [{ name: 'my-lcars-session' }] } },
    { id: 'session_name_uppercase_LCARS', teamData: { sessions: [{ name: 'MY-LCARS-SESSION' }] } },
    { id: 'session_name_mixedcase_MyLcarsThing', teamData: { sessions: [{ name: 'MyLcarsThing' }] } },
    {
        id: 'sessions_present_none_matching',
        teamData: { sessions: [{ name: 'academy-main' }, { name: 'other-session' }] }
    },
    { id: 'sessions_empty_array', teamData: { sessions: [] } },
    {
        id: 'no_sessions_lcars_service_present',
        teamData: { lcars_service: { hostname: 'runabout.example.com', port: 8080, reachable: true } }
    },
    { id: 'neither_sessions_nor_service', teamData: { some_other_field: 'x' } },
    {
        id: 'lcars_service_and_matching_session_both_true',
        teamData: {
            sessions: [{ name: 'team-lcars' }],
            lcars_service: { hostname: 'runabout.example.com', port: 8080, reachable: true }
        }
    }
];

// ============================================================================
// createServiceOnlyLcarsCard(name, svc) input matrix -- 9 cases
// ============================================================================
const XSS_METACHARS = '<img src=x onerror=1>&"\'';

const CARD_CASES = [
    { id: 'reachable_true', name: 'academy', svc: { reachable: true, hostname: 'runabout.example.com', port: 8080 } },
    { id: 'reachable_false', name: 'academy', svc: { reachable: false, hostname: 'runabout.example.com', port: 8080 } },
    {
        id: 'reachable_null',
        name: 'academy',
        svc: { reachable: null, hostname: 'runabout.example.com', port: 8080 }
    },
    {
        // reachable key entirely absent -- svc.reachable is undefined
        id: 'reachable_undefined',
        name: 'academy',
        svc: { hostname: 'runabout.example.com', port: 8080 }
    },
    {
        id: 'hostname_missing_unreachable',
        name: 'academy',
        svc: { reachable: false, port: 8080 }
    },
    {
        // reachable === true but hostname is missing -- must take the
        // `if (reachable && svc.hostname)` guard's ELSE branch: no
        // lcars-clickable class, no tabindex/role, no click/keydown listeners.
        id: 'reachable_true_hostname_missing',
        name: 'academy',
        svc: { reachable: true, port: 8080 }
    },
    {
        id: 'xss_name',
        name: XSS_METACHARS,
        svc: { reachable: false, hostname: 'runabout.example.com', port: 8080 }
    },
    {
        id: 'xss_hostname',
        name: 'academy',
        svc: { reachable: false, hostname: XSS_METACHARS, port: 8080 }
    },
    {
        id: 'port_numeric_high',
        name: 'academy',
        svc: { reachable: true, hostname: 'runabout.example.com', port: 65535 }
    }
];

// Builds a deterministic outerHTML-equivalent string from a FakeElement.
// FakeElement (lcars-client-dom-stub.js) has no real outerHTML getter, so
// this reconstructs it from tagName + className + sorted attributes + title
// + innerHTML -- everything the production code actually sets on the card.
function syntheticOuterHTML(el) {
    const tag = (el.tagName || 'DIV').toLowerCase();
    const attrs = [];
    if (el.className) {
        attrs.push('class="' + el.className + '"');
    }
    const attrNames = Array.from(el._attrs.keys()).sort();
    for (const attrName of attrNames) {
        attrs.push(attrName + '="' + el.getAttribute(attrName) + '"');
    }
    if (el.title) {
        attrs.push('title="' + el.title + '"');
    }
    const attrStr = attrs.length ? ' ' + attrs.join(' ') : '';
    return '<' + tag + attrStr + '>' + el.innerHTML + '</' + tag + '>';
}

function captureIsLcarsTerminalCase(relPath, teamData) {
    const { ctx } = createDomStub();
    const mod = loadClientApp(relPath, ctx);
    return mod.isLcarsTerminal(teamData);
}

function captureCardCase(relPath, name, svc) {
    const { ctx, windowOpenCalls } = createDomStub();
    const mod = loadClientApp(relPath, ctx);
    const card = mod.createServiceOnlyLcarsCard(name, svc);

    const clickListenerCount = card.listenerCount('click');
    const keydownListenerCount = card.listenerCount('keydown');

    const enterEvt = card.dispatch('keydown', { key: 'Enter', keyCode: 13 });
    const enterOpenCountAfter = windowOpenCalls.length;
    const enterOpenUrl = enterOpenCountAfter > 0 ? windowOpenCalls[windowOpenCalls.length - 1].url : null;

    const spaceEvt = card.dispatch('keydown', { key: ' ', keyCode: 32 });
    const spaceOpenCountAfter = windowOpenCalls.length;

    const clickOpenCountBefore = windowOpenCalls.length;
    card.dispatch('click', {});
    const clickOpenCountAfter = windowOpenCalls.length;

    return {
        outerHTML: syntheticOuterHTML(card),
        className: card.className,
        title: card.title,
        tabindex: card.getAttribute('tabindex'),
        role: card.getAttribute('role'),
        clickListenerCount: clickListenerCount,
        keydownListenerCount: keydownListenerCount,
        enterActivated: enterOpenCountAfter > 0,
        enterDefaultPrevented: enterEvt.defaultPrevented,
        enterOpenUrl: enterOpenUrl,
        spaceActivated: spaceOpenCountAfter > enterOpenCountAfter,
        spaceDefaultPrevented: spaceEvt.defaultPrevented,
        clickActivated: clickOpenCountAfter > clickOpenCountBefore
    };
}

// Computes the full { [relPath]: { isLcarsTerminal: {...}, createServiceOnlyLcarsCard: {...} } }
// result object across every file in CLIENT_FILES.
function computeAllResults() {
    const results = {};
    for (const relPath of CLIENT_FILES) {
        const perFile = { isLcarsTerminal: {}, createServiceOnlyLcarsCard: {} };
        for (const c of ISLCARS_CASES) {
            perFile.isLcarsTerminal[c.id] = captureIsLcarsTerminalCase(relPath, c.teamData);
        }
        for (const c of CARD_CASES) {
            perFile.createServiceOnlyLcarsCard[c.id] = captureCardCase(relPath, c.name, c.svc);
        }
        results[relPath] = perFile;
    }
    return results;
}

// Deterministic JSON serialization: recursively sorts object keys so the
// output is stable regardless of property insertion order, then
// JSON.stringify's with 2-space indent + trailing newline for a clean
// on-disk diff.
function sortKeysDeep(value) {
    if (Array.isArray(value)) {
        return value.map(sortKeysDeep);
    }
    if (value && typeof value === 'object') {
        const sorted = {};
        for (const key of Object.keys(value).sort()) {
            sorted[key] = sortKeysDeep(value[key]);
        }
        return sorted;
    }
    return value;
}

function stableStringify(value) {
    return JSON.stringify(sortKeysDeep(value), null, 2) + '\n';
}

module.exports = {
    PUBLIC_ROOT,
    ALL_CLIENT_FILES,
    CLIENT_FILES,
    KNOWN_GOOD_FILE_SETS,
    identifyKnownFileSet,
    ISLCARS_CASES,
    CARD_CASES,
    XSS_METACHARS,
    syntheticOuterHTML,
    captureIsLcarsTerminalCase,
    captureCardCase,
    computeAllResults,
    stableStringify
};
