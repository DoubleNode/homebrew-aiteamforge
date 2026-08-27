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

// Same tap-mirroring existence filter XACA-0983-013/014/015 uses: 5 files in
// dev-team, 4 in homebrew-tap (lcars-doublenode-app.js is XACA-0139-excluded
// from the tap mirror). Filtering to what actually exists on disk keeps this
// module correct in both repos instead of throwing ENOENT in the tap.
const ALL_CLIENT_FILES = [
    'lcars/js/lcars-dashboard-app.js',
    'lcars2/js/lcars-academy-app.js',
    'lcars2/js/lcars-all-app.js',
    'lcars2/js/lcars-doublenode-app.js',
    'lcars2/js/lcars-mainevent-app.js'
];
const CLIENT_FILES = ALL_CLIENT_FILES.filter((relPath) => fs.existsSync(path.join(PUBLIC_ROOT, relPath)));

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
    ISLCARS_CASES,
    CARD_CASES,
    XSS_METACHARS,
    syntheticOuterHTML,
    captureIsLcarsTerminalCase,
    captureCardCase,
    computeAllResults,
    stableStringify
};
