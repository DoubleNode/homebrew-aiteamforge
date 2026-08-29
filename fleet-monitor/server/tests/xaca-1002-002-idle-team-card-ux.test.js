//
//  xaca-1002-002-idle-team-card-ux.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1002 subitem 006 (Testing & Debugging) -- CLIENT-side regression
 * coverage for LCARS_TERMINAL_CARD.createIdleTeamCard() (public/shared/js/
 * lcars-terminal-card.js) and its marker-gated wiring into each of the 5
 * dashboard app files' createTeamCard().
 *
 * Runs against the REAL shipped files under fleet-monitor/server/public/
 * (via tests/helpers/lcars-client-dom-stub.js's vm.Context loader), never a
 * paraphrase of their logic -- same discipline as
 * tests/xaca-0983-013-014-015-lcars-card-ux.test.js and
 * tests/xaca-0990-001-lcars-terminal-card-characterization.test.js, whose
 * house style this file follows.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { createDomStub, loadSharedTerminalCardModule, loadClientApp } = require('./helpers/lcars-client-dom-stub.js');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');
const SHARED_MODULE_PATH = path.join(PUBLIC_ROOT, 'shared', 'js', 'lcars-terminal-card.js');

// lcars-doublenode-app.js is NOT tap-mirrored (XACA-0139 debranding
// exclusion) -- filtering to files that actually exist on disk keeps this
// suite correct in both the dev-team repo (5 files) and the tap (4 files)
// instead of crashing with ENOENT there. Mirrors
// tests/xaca-0983-013-014-015-lcars-card-ux.test.js's CLIENT_FILES pattern.
const ALL_CLIENT_FILES = [
    'lcars/js/lcars-dashboard-app.js',
    'lcars2/js/lcars-academy-app.js',
    'lcars2/js/lcars-all-app.js',
    'lcars2/js/lcars-doublenode-app.js',
    'lcars2/js/lcars-mainevent-app.js'
];
const CLIENT_FILES = ALL_CLIENT_FILES.filter((relPath) => fs.existsSync(path.join(PUBLIC_ROOT, relPath)));

const XSS_NAME = '<img src=x onerror=alert(1)>';
const XSS_TEAMNAME = '<script>alert(document.cookie)</script>';
const XSS_LASTSEEN = '<svg onload=alert(1)>'; // not a parseable date -> formatIdleTimestamp falls back to the raw string

// Classes createIdleTeamCard is allowed to emit -- every one must already
// exist in BOTH shipped stylesheets (asserted in the "zero new CSS" test
// below); this ticket must add none.
const ALLOWED_CLASSES = new Set([
    'team-card',
    'team-header',
    'team-name',
    'status-indicator',
    'idle',
    'session-info',
    'session-detail',
    'session-label',
    'session-value',
    // XACA-1002-012: the status rows use .text-status-idle (--lcars-tan), NOT
    // .text-offline (--lcars-alert-red). Idle is a resting state, not a fault,
    // and red text contradicted the muted tan status dot. .text-status-idle
    // already exists in both theme sheets, so the swap still adds zero CSS --
    // which the "already defined in BOTH shipped stylesheets" test below proves
    // rather than takes on trust.
    'text-status-idle'
]);

function extractClassTokens(html) {
    const tokens = new Set();
    const classAttrRe = /class="([^"]*)"/g;
    let m;
    while ((m = classAttrRe.exec(html)) !== null) {
        for (const cls of m[1].split(/\s+/).filter(Boolean)) {
            tokens.add(cls);
        }
    }
    return tokens;
}

function makeEscapeHtml() {
    // Mirrors what a real browser's `div.textContent = x; return div.innerHTML;`
    // produces -- same rule lcars-client-dom-stub.js's textContentToInnerHtml
    // implements, kept independent here so this file does not depend on that
    // helper's internal implementation detail for its own escaping oracle.
    return function escapeHtml(s) {
        const div = { text: String(s) };
        return div.text
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;');
    };
}

function baseIdle(overrides) {
    return Object.assign(
        {
            team: 'academy',
            teamName: 'STARFLEET ACADEMY',
            terminal: 'training',
            registeredAt: '2026-01-01T00:00:00.000Z',
            lastSeen: '2026-02-17T02:21:40.590Z'
        },
        overrides
    );
}

function loadSharedModuleFresh() {
    const { ctx } = createDomStub();
    vm.createContext(ctx);
    loadSharedTerminalCardModule(ctx);
    return ctx;
}

test('harness sanity: the tap-mirroring existence filter did not degrade to zero files', () => {
    assert.ok(CLIENT_FILES.length > 0, 'CLIENT_FILES resolved to zero files -- PUBLIC_ROOT is likely wrong: ' + PUBLIC_ROOT);
    assert.ok(CLIENT_FILES.length <= ALL_CLIENT_FILES.length, 'CLIENT_FILES somehow exceeds the known file list');
});

// ============================================================================
// Requirement 7: createIdleTeamCard renders the expected DOM.
// ============================================================================

test('createIdleTeamCard renders team name, NO ACTIVE SESSION, team, IDLE (REGISTERED), and last-seen -- no Port/Machine row', () => {
    const ctx = loadSharedModuleFresh();
    const card = ctx.window.LCARS_TERMINAL_CARD.createIdleTeamCard('training', baseIdle(), makeEscapeHtml());

    assert.equal(card.tagName, 'DIV');
    assert.equal(card.className, 'team-card');
    assert.ok(card.innerHTML.includes('training'), 'team/terminal name must render');
    assert.ok(card.innerHTML.includes('NO ACTIVE SESSION'), 'must render the no-session marker text');
    assert.ok(card.innerHTML.includes('STARFLEET ACADEMY'), 'team (idle.teamName) must render');
    assert.ok(card.innerHTML.includes('IDLE (REGISTERED)'), 'must render the idle status text');
    assert.ok(!card.innerHTML.includes('unknown'), 'a valid lastSeen must not fall back to "unknown"');

    // No Port row, no Machine row -- an idle-registered team has neither.
    assert.ok(!card.innerHTML.includes('>Port<'), 'must NOT render a Port row');
    assert.ok(!card.innerHTML.includes('>Machine<'), 'must NOT render a Machine row');
});

test('createIdleTeamCard falls back to "unknown" for a missing lastSeen, never fabricates a placeholder', () => {
    const ctx = loadSharedModuleFresh();
    const card = ctx.window.LCARS_TERMINAL_CARD.createIdleTeamCard('training', baseIdle({ lastSeen: undefined }), makeEscapeHtml());
    assert.ok(card.innerHTML.includes('unknown'), 'missing lastSeen must render literally as "unknown"');
});

// ============================================================================
// Requirement 8: escapeHtml is required -- a non-function throws TypeError
// (mirrors createServiceOnlyLcarsCard's guard, per
// tests/xaca-0990-001-lcars-terminal-card-characterization.test.js's
// pattern for that sibling function), plus a valid-escapeHtml control.
// ============================================================================

test('createIdleTeamCard rejects a non-function escapeHtml with TypeError', () => {
    const ctx = loadSharedModuleFresh();
    const idle = baseIdle();
    const originalCreateElement = ctx.document.createElement;

    const badCases = [
        { label: 'omitted', args: ['training', idle] },
        { label: 'null', args: ['training', idle, null] },
        { label: 'non-function (string)', args: ['training', idle, 'not-a-function'] }
    ];

    for (const { label, args } of badCases) {
        let createElementCalls = 0;
        ctx.document.createElement = function (...callArgs) {
            createElementCalls += 1;
            return originalCreateElement.apply(this, callArgs);
        };
        try {
            assert.throws(
                () => ctx.window.LCARS_TERMINAL_CARD.createIdleTeamCard(...args),
                // Cross-realm: the shared module runs inside a vm.createContext()
                // realm, so `instanceof TypeError` is false even though `.name`
                // reads 'TypeError' -- same cross-realm-safe match
                // xaca-0990-001's equivalent guard test uses.
                (err) => err.name === 'TypeError' && /escapeHtml must be a function/.test(err.message),
                'expected a TypeError naming escapeHtml for the "' + label + '" case'
            );
            assert.equal(createElementCalls, 0, 'no DOM node should be constructed before the escapeHtml guard throws (case: ' + label + ')');
        } finally {
            ctx.document.createElement = originalCreateElement;
        }
    }
});

test('createIdleTeamCard still succeeds with a valid escapeHtml (control)', () => {
    const ctx = loadSharedModuleFresh();
    const card = ctx.window.LCARS_TERMINAL_CARD.createIdleTeamCard('training', baseIdle(), (s) => String(s));
    assert.ok(card, 'a valid escapeHtml function must produce a card, not throw');
    assert.equal(card.tagName, 'DIV');
});

// ============================================================================
// Requirement 9: XSS -- markup in name/teamName/lastSeen is escaped, not
// rendered.
// ============================================================================

test('createIdleTeamCard escapes XSS markup in name, teamName, and lastSeen', () => {
    const ctx = loadSharedModuleFresh();
    const idle = baseIdle({ teamName: XSS_TEAMNAME, lastSeen: XSS_LASTSEEN });
    const card = ctx.window.LCARS_TERMINAL_CARD.createIdleTeamCard(XSS_NAME, idle, makeEscapeHtml());

    assert.ok(!card.innerHTML.includes('<img'), 'raw <img> from name must not survive into innerHTML: ' + card.innerHTML);
    assert.ok(card.innerHTML.includes('&lt;img'), 'escaped form of name should be present');

    assert.ok(!card.innerHTML.includes('<script>'), 'raw <script> from teamName must not survive into innerHTML: ' + card.innerHTML);
    assert.ok(card.innerHTML.includes('&lt;script&gt;'), 'escaped form of teamName should be present');

    assert.ok(!card.innerHTML.includes('<svg'), 'raw <svg> from lastSeen (invalid date, raw-string fallback) must not survive into innerHTML: ' + card.innerHTML);
    assert.ok(card.innerHTML.includes('&lt;svg'), 'escaped form of lastSeen should be present');
});

// ============================================================================
// Requirement 10: not actionable -- no tabindex, no role="button", no click
// and no keydown listener.
// ============================================================================

test('createIdleTeamCard is not actionable: no tabindex, no role, no click/keydown listeners', () => {
    const ctx = loadSharedModuleFresh();
    const card = ctx.window.LCARS_TERMINAL_CARD.createIdleTeamCard('training', baseIdle(), makeEscapeHtml());

    assert.equal(card.getAttribute('tabindex'), null, 'must not be focusable');
    assert.equal(card.getAttribute('role'), null, 'must not claim role="button"');
    assert.equal(card.listenerCount('click'), 0, 'must have no click listener');
    assert.equal(card.listenerCount('keydown'), 0, 'must have no keydown listener');
    assert.ok(!card.classList.contains('lcars-clickable'), 'must not carry the clickable styling hook');
});

// ============================================================================
// Requirement 11: marker-gated routing -- a bucket with idle_registered
// renders the idle card; a session-less bucket with NO marker and no
// lcars_service still falls through to the original empty-card fallback.
// ============================================================================

for (const relPath of CLIENT_FILES) {
    test(`createTeamCard(${relPath}) routes a bucket with idle_registered to the idle card`, () => {
        const { ctx } = createDomStub();
        const mod = loadClientApp(relPath, ctx);

        const data = { idle_registered: baseIdle() };
        const card = mod.createTeamCard('training', data);

        assert.ok(card.innerHTML.includes('IDLE (REGISTERED)'), 'a marked bucket must render the idle card: ' + relPath);
        assert.ok(card.innerHTML.includes('NO ACTIVE SESSION'), relPath);
    });

    test(`createTeamCard(${relPath}) does NOT mislabel a session-less, marker-less, service-less bucket as idle`, () => {
        const { ctx } = createDomStub();
        const mod = loadClientApp(relPath, ctx);

        // No sessions, no lcars_service, no idle_registered marker -- the
        // original "nothing to show yet" fallback, e.g. a team the registry
        // has never heard of and no machine has ever reported.
        const card = mod.createTeamCard('mystery', {});

        assert.equal(card.innerHTML, '', 'a genuinely empty bucket must fall through to the original empty card: ' + relPath);
        assert.ok(!card.innerHTML.includes('IDLE (REGISTERED)'), relPath);
    });

    test(`createTeamCard(${relPath}) prefers the live-session card over idle_registered when both are present (never-overwrite reflected client-side too)`, () => {
        const { ctx } = createDomStub();
        const mod = loadClientApp(relPath, ctx);

        const data = {
            sessions: [
                { name: 'academy-training', hostname: 'runabout', machine_status: 'online', windows: 1, uptime_display: '1h 0m', lcars_port: 8080 }
            ],
            idle_registered: baseIdle() // must be structurally impossible to reach server-side (never-overwrite), but prove the client also prefers the live session if it ever did co-occur
        };
        const card = mod.createTeamCard('training', data);
        assert.ok(!card.innerHTML.includes('IDLE (REGISTERED)'), 'a bucket with a live session must never render as idle: ' + relPath);
    });
}

// ============================================================================
// Requirement 12: single implementation -- the function BODY exists exactly
// once in the repo (the shared module); the 5 app files hold only
// delegating shims.
// ============================================================================

test('createIdleTeamCard body exists exactly once in the repo (shared module only)', () => {
    // "IDLE (REGISTERED)" is the render-state's distinguishing literal --
    // it can only appear where the actual card-building logic lives. Plain
    // split/length counting (not a regex) so the literal parentheses need no
    // escaping and cannot be misread as a regex group.
    const DISTINGUISHING_LITERAL = 'IDLE (REGISTERED)';
    const countOccurrences = (src) => src.split(DISTINGUISHING_LITERAL).length - 1;

    const sharedSrc = fs.readFileSync(SHARED_MODULE_PATH, 'utf8');
    assert.equal(countOccurrences(sharedSrc), 1, 'the shared module must define the idle-card body exactly once');

    for (const relPath of CLIENT_FILES) {
        const src = fs.readFileSync(path.join(PUBLIC_ROOT, relPath), 'utf8');
        assert.equal(countOccurrences(src), 0, `${relPath} must NOT contain a duplicated copy of the idle-card body`);

        assert.ok(
            /function createIdleTeamCard\(name, idle\) \{\s*return LCARS_TERMINAL_CARD\.createIdleTeamCard\(name, idle, escapeHtml\);\s*\}/.test(src),
            `${relPath} must hold only a one-line delegating shim to LCARS_TERMINAL_CARD.createIdleTeamCard`
        );
    }
});

// ============================================================================
// Requirement 13: zero new CSS -- the card uses only pre-existing classes,
// and every one of them is already defined in BOTH shipped stylesheets.
// ============================================================================

test('createIdleTeamCard uses only pre-existing, already-defined CSS classes', () => {
    const ctx = loadSharedModuleFresh();
    const card = ctx.window.LCARS_TERMINAL_CARD.createIdleTeamCard('training', baseIdle(), makeEscapeHtml());

    const usedClasses = new Set([...extractClassTokens(card.innerHTML), ...card.className.split(/\s+/).filter(Boolean)]);
    for (const cls of usedClasses) {
        assert.ok(ALLOWED_CLASSES.has(cls), `unexpected class "${cls}" -- not in the pre-existing allowed set: ${[...ALLOWED_CLASSES].join(', ')}`);
    }
    assert.ok(usedClasses.size > 0, 'sanity: the card must actually emit some classes');
});

test('every class createIdleTeamCard can emit is already defined in BOTH shipped stylesheets (no new CSS needed)', () => {
    const stylesheets = ['lcars/css/lcars-fleet-theme.css', 'lcars2/css/lcars-fleet-theme.css'];
    for (const rel of stylesheets) {
        const cssPath = path.join(PUBLIC_ROOT, rel);
        assert.ok(fs.existsSync(cssPath), `expected stylesheet missing: ${cssPath}`);
        const css = fs.readFileSync(cssPath, 'utf8');
        for (const cls of ALLOWED_CLASSES) {
            // A loose but sufficient existence check: the selector text
            // `.className` must appear somewhere in the stylesheet (as a bare
            // rule or as part of a compound/descendant selector).
            const selector = '.' + cls;
            assert.ok(css.includes(selector), `expected pre-existing selector "${selector}" in ${rel}, but it was not found -- this ticket must add zero new CSS`);
        }
    }
});

// ============================================================================
// GATE FOLLOW-UPS: XACA-1002-012 / -013 (UX findings from PR #789)
// ============================================================================

test('XACA-1002-012: status rows use the tan idle colour, never the alert-red offline colour', () => {
    const ctx = loadSharedModuleFresh();
    const card = ctx.window.LCARS_TERMINAL_CARD.createIdleTeamCard('training', baseIdle(), makeEscapeHtml());

    assert.ok(card.innerHTML.includes('text-status-idle'), 'idle status rows must use .text-status-idle');
    assert.ok(
        !card.innerHTML.includes('text-offline'),
        'idle must NOT use .text-offline -- that is --lcars-alert-red, reserved for a genuine ' +
        'UNREACHABLE failure. Red text here contradicts the muted tan .status-indicator.idle dot ' +
        'and reports a fault where there is none.'
    );

    // The header dot and the status text must agree. That agreement IS the fix;
    // a future edit that changes one without the other reintroduces the defect.
    assert.ok(card.innerHTML.includes('status-indicator idle'), 'header dot stays the tan idle indicator');
});

test('XACA-1002-013: the timestamp row is labelled Last Registered, not Last Seen', () => {
    const ctx = loadSharedModuleFresh();
    const card = ctx.window.LCARS_TERMINAL_CARD.createIdleTeamCard('training', baseIdle(), makeEscapeHtml());

    assert.ok(card.innerHTML.includes('Last Registered:'), 'label must name what the value actually measures');
    assert.ok(
        !card.innerHTML.includes('Last Seen:'),
        'must NOT say "Last Seen" -- idle.lastSeen is written only by POST /api/team-register, ' +
        'so it tracks registration recency and never session activity. A team that has never had ' +
        'a live session still shows a recent value every time its startup script re-registers.'
    );
});

// ============================================================================
// XACA-1002-014: createTeamNameComparator — idle-last ordering, extracted
// ============================================================================

function comparatorTeams() {
    return {
        zulu:    { name: 'zulu',    sessions: [{ name: 'x-zulu', tab_order: 5 }] },
        alpha:   { name: 'alpha',   sessions: [{ name: 'x-alpha', tab_order: 2 }] },
        lcars:   { name: 'lcars',   sessions: [], lcars_service: { port: 8203, reachable: true } },
        bravo:   { name: 'bravo',   sessions: [], idle_registered: { team: 't', teamName: 'T', terminal: 'bravo' } },
        anvil:   { name: 'anvil',   sessions: [], idle_registered: { team: 't', teamName: 'T', terminal: 'anvil' } }
    };
}

test('XACA-1002-014: idle-registered teams sort AFTER live ones, LCARS still first', () => {
    const ctx = loadSharedModuleFresh();
    const teams = comparatorTeams();
    const order = Object.getOwnPropertyNames(teams).sort(
        ctx.window.LCARS_TERMINAL_CARD.createTeamNameComparator(teams)
    );

    assert.equal(order[0], 'lcars', 'LCARS terminal keeps its first position');
    assert.deepStrictEqual(order.slice(1, 3), ['alpha', 'zulu'], 'live teams next, alphabetical (no tab_order tier in lcars2)');
    assert.deepStrictEqual(order.slice(3), ['anvil', 'bravo'], 'idle teams last, alphabetical among themselves');

    // The point of the tier: an idle team must never outrank a live one just
    // because its name sorts earlier. "anvil" < "alpha" is false, but "anvil"
    // < "zulu" is true -- pre-fix it would have landed between them.
    assert.ok(order.indexOf('anvil') > order.indexOf('zulu'), 'idle "anvil" must not jump ahead of live "zulu"');
});

test('XACA-1002-014: useTabOrder preserves the dashboard skin\'s extra tier, and lcars2 still lacks it', () => {
    const ctx = loadSharedModuleFresh();
    const teams = comparatorTeams();

    // With the tier: zulu(5) vs alpha(2) -> alpha first by tab_order, which
    // here agrees with alphabetical. Use a case where they DISAGREE so the
    // tier is actually observable rather than coincidentally matching.
    const t = {
        aaa: { name: 'aaa', sessions: [{ name: 'x', tab_order: 9 }] },
        zzz: { name: 'zzz', sessions: [{ name: 'x', tab_order: 1 }] }
    };

    const withTier = Object.getOwnPropertyNames(t).sort(
        ctx.window.LCARS_TERMINAL_CARD.createTeamNameComparator(t, { useTabOrder: true })
    );
    assert.deepStrictEqual(withTier, ['zzz', 'aaa'], 'dashboard skin orders by tab_order, NOT alphabetically');

    const withoutTier = Object.getOwnPropertyNames(t).sort(
        ctx.window.LCARS_TERMINAL_CARD.createTeamNameComparator(t)
    );
    assert.deepStrictEqual(withoutTier, ['aaa', 'zzz'], 'lcars2 skins order alphabetically, as they always did');

    // This pair diverging is the whole reason useTabOrder exists: extracting
    // one "obviously correct" shared comparator would have silently dropped
    // the dashboard tier and reordered every card in that skin.
    assert.notDeepStrictEqual(withTier, withoutTier, 'the two skins must remain observably different');
});

test('XACA-1002-014: the comparator has exactly ONE implementation — no inline copies survive in the app files', () => {
    // The five app files previously each carried their own inline comparator
    // body (four byte-identical, the dashboard one subtly different). This
    // module exists to stop exactly that, so assert the bodies are gone rather
    // than trusting the refactor.
    for (const relPath of CLIENT_FILES) {
        const src = fs.readFileSync(path.join(PUBLIC_ROOT, relPath), 'utf8');
        assert.ok(
            !src.includes('const aIsLcars'),
            relPath + ' still contains an inline comparator body -- it must delegate to ' +
            'LCARS_TERMINAL_CARD.createTeamNameComparator instead'
        );
        assert.ok(
            src.includes('LCARS_TERMINAL_CARD.createTeamNameComparator('),
            relPath + ' must call the shared comparator'
        );
    }

    // ...and the real body lives in the shared module.
    const shared = fs.readFileSync(SHARED_MODULE_PATH, 'utf8');
    assert.ok(shared.includes('function createTeamNameComparator('), 'shared module holds the implementation');
});

test('XACA-1002-014: only the dashboard skin opts into the tab_order tier', () => {
    const dashboard = 'lcars/js/lcars-dashboard-app.js';
    for (const relPath of CLIENT_FILES) {
        const src = fs.readFileSync(path.join(PUBLIC_ROOT, relPath), 'utf8');
        const optsIn = src.includes('useTabOrder: true');
        if (relPath === dashboard) {
            assert.ok(optsIn, 'the dashboard skin must keep its tab_order tier');
        } else {
            assert.ok(!optsIn, relPath + ' must NOT gain a tab_order tier it never had');
        }
    }
});
