//
//  xaca-0983-013-014-015-lcars-card-ux.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * Coverage for the 3 PROTECTED [UX] follow-ups the evaluator filed against
 * commit bcd728b1's new createServiceOnlyLcarsCard() render state (XACA-0983
 * fix (b)): the UNREACHABLE-service card was reachable via the UX gate but
 * had 3 pre-existing gaps that the new card inherited.
 *
 *   XACA-0983-015 (escaping): name/svc.hostname flowed into innerHTML
 *   unescaped. Covered here for createServiceOnlyLcarsCard only -- the
 *   identical pre-existing gap in createTeamCard's session-based card
 *   (name/session.name/session.hostname) is explicitly OUT of scope for
 *   this ticket (owned by XACA-0416) and is not asserted on here.
 *
 *   XACA-0983-014 (keyboard access): clickable LCARS cards were plain
 *   mouse-only <div>s. Covered for BOTH createServiceOnlyLcarsCard's
 *   reachable branch AND createTeamCard's isOnline branch -- plus an
 *   explicit assertion that the UNREACHABLE / non-clickable branches of
 *   both functions stay non-focusable (they must not lie about being
 *   actionable).
 *
 *   XACA-0983-013 (missing .lcars-offline styling): a CSS-only fix (ported
 *   into lcars/css/lcars-fleet-theme.css and lcars2/css/lcars-fleet-theme.css)
 *   with no client-JS surface to unit test here; it is covered by a static
 *   assertion below that the stylesheets actually loaded by the 5 affected
 *   HTML pages now define the rule, using the same
 *   `.team-card.lcars-terminal.lcars-offline` selector the JS emits.
 *
 * Runs against the REAL shipped files under fleet-monitor/server/public/
 * (via tests/helpers/lcars-client-dom-stub.js's vm.Context loader), not a
 * paraphrase of their logic -- see that helper's file-header comment for
 * why a hand-rolled DOM stub was used instead of adding a jsdom dependency.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createDomStub, loadClientApp } = require('./helpers/lcars-client-dom-stub.js');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');

// lcars-doublenode-app.js is NOT tap-mirrored (XACA-0139 debranding
// exclusion -- sync-tap.sh explicitly filters "lcars-doublenode-*" out of
// the fleet-monitor/server/ mirror), so it does not exist when this suite
// runs from homebrew-tap/fleet-monitor/server/. Filtering to files that
// actually exist on disk, rather than hard-coding all 5, keeps this suite
// correct in BOTH the dev-team repo (5 files) and the tap (4 files) instead
// of crashing with ENOENT in the tap. The vacuity-guard test below ensures
// this filter cannot silently degrade to testing zero files in either repo.
const ALL_CLIENT_FILES = [
    'lcars/js/lcars-dashboard-app.js',
    'lcars2/js/lcars-academy-app.js',
    'lcars2/js/lcars-all-app.js',
    'lcars2/js/lcars-doublenode-app.js',
    'lcars2/js/lcars-mainevent-app.js'
];
const CLIENT_FILES = ALL_CLIENT_FILES.filter((relPath) => fs.existsSync(path.join(PUBLIC_ROOT, relPath)));

const XSS_NAME = '<img src=x onerror=alert(1)>';
const XSS_HOSTNAME = '<script>alert(document.cookie)</script>';

function reachableService() {
    return { reachable: true, hostname: 'runabout.fleet-test.example', port: 8080 };
}

function unreachableService() {
    return { reachable: false, hostname: 'runabout.fleet-test.example', port: 8080 };
}

function onlineSessionData() {
    return {
        sessions: [
            {
                name: 'academy-lcars',
                hostname: 'runabout.fleet-test.example',
                machine_status: 'online',
                windows: 3,
                uptime_display: '2h 14m',
                lcars_port: 8080
            }
        ]
    };
}

test('harness sanity: the tap-mirroring existence filter did not degrade to zero files', () => {
    // Guards the CLIENT_FILES/PAGES_AND_THEIR_CSS existence filters above:
    // in dev-team this should be 5/5, in homebrew-tap 4/4 (doublenode
    // excluded). Either way it must be nonzero, or every test below that
    // loops over these arrays silently runs 0 iterations and reports a
    // trivially green suite instead of a broken PUBLIC_ROOT path.
    assert.ok(CLIENT_FILES.length > 0, 'CLIENT_FILES resolved to zero files -- PUBLIC_ROOT is likely wrong: ' + PUBLIC_ROOT);
    assert.ok(CLIENT_FILES.length <= ALL_CLIENT_FILES.length, 'CLIENT_FILES somehow exceeds the known file list');
});

// ============================================================================
// XACA-0983-015: escaping in createServiceOnlyLcarsCard
// ============================================================================

for (const relPath of CLIENT_FILES) {
    test(`XACA-0983-015: createServiceOnlyLcarsCard escapes an XSS name (${relPath})`, () => {
        const { ctx } = createDomStub();
        const mod = loadClientApp(relPath, ctx);

        const card = mod.createServiceOnlyLcarsCard(XSS_NAME, unreachableService());

        assert.ok(
            !card.innerHTML.includes('<img'),
            'raw <img> tag must not survive into innerHTML: ' + card.innerHTML
        );
        assert.ok(
            card.innerHTML.includes('&lt;img'),
            'escaped form of the name should be present: ' + card.innerHTML
        );
    });

    test(`XACA-0983-015: createServiceOnlyLcarsCard escapes an XSS hostname (${relPath})`, () => {
        const { ctx } = createDomStub();
        const mod = loadClientApp(relPath, ctx);

        const card = mod.createServiceOnlyLcarsCard('academy', {
            reachable: false,
            hostname: XSS_HOSTNAME,
            port: 8080
        });

        assert.ok(
            !card.innerHTML.includes('<script>'),
            'raw <script> tag must not survive into innerHTML: ' + card.innerHTML
        );
        assert.ok(
            card.innerHTML.includes('&lt;script&gt;'),
            'escaped form of the hostname should be present: ' + card.innerHTML
        );
    });
}

test('XACA-0983-015 negative control: string concatenation (the pre-fix pattern) DOES leak markup', () => {
    // This does not call the shipped function -- it reproduces, inline,
    // exactly what createServiceOnlyLcarsCard's innerHTML line looked like
    // before this ticket (raw `+ name +` / `+ (svc.hostname || 'unknown') +`,
    // see the removed lines in this diff). It exists to prove the assertion
    // style above ("!card.innerHTML.includes('<img')") is actually capable
    // of catching the defect, not just checking output shape that happens
    // to always be true.
    const name = XSS_NAME;
    const svc = { hostname: XSS_HOSTNAME, port: 8080 };
    const preFixHtml =
        '<div class="team-name">' + name + '<span class="lcars-badge">LCARS</span></div>' +
        '<span class="session-value">' + (svc.hostname || 'unknown') + '</span>';

    assert.ok(
        preFixHtml.includes('<img'),
        'sanity: the pre-fix concatenation pattern must actually contain a raw <img> tag'
    );
    assert.ok(
        preFixHtml.includes('<script>'),
        'sanity: the pre-fix concatenation pattern must actually contain a raw <script> tag'
    );
});

// ============================================================================
// XACA-0983-014: keyboard access -- createServiceOnlyLcarsCard
// ============================================================================

for (const relPath of CLIENT_FILES) {
    test(`XACA-0983-014: reachable service card is focusable and Enter-activatable (${relPath})`, () => {
        const { ctx, windowOpenCalls } = createDomStub();
        const mod = loadClientApp(relPath, ctx);

        const card = mod.createServiceOnlyLcarsCard('academy', reachableService());

        assert.equal(card.getAttribute('tabindex'), '0');
        assert.equal(card.getAttribute('role'), 'button');
        assert.ok(card.classList.contains('lcars-clickable'));

        const evt = card.dispatch('keydown', { key: 'Enter', keyCode: 13 });
        assert.equal(windowOpenCalls.length, 1);
        assert.equal(windowOpenCalls[0].url, 'http://runabout.fleet-test.example:8080');
        assert.equal(evt.defaultPrevented, true, 'Enter must call preventDefault');
    });

    test(`XACA-0983-014: reachable service card is Space-activatable and Space is prevented (${relPath})`, () => {
        const { ctx, windowOpenCalls } = createDomStub();
        const mod = loadClientApp(relPath, ctx);

        const card = mod.createServiceOnlyLcarsCard('academy', reachableService());
        const evt = card.dispatch('keydown', { key: ' ', keyCode: 32 });

        assert.equal(windowOpenCalls.length, 1, 'Space must activate the card');
        assert.equal(evt.defaultPrevented, true, 'Space must be prevented so it does not scroll the page');
    });

    test(`XACA-0983-014: an irrelevant key does not activate or preventDefault (${relPath})`, () => {
        const { ctx, windowOpenCalls } = createDomStub();
        const mod = loadClientApp(relPath, ctx);

        const card = mod.createServiceOnlyLcarsCard('academy', reachableService());
        const evt = card.dispatch('keydown', { key: 'a', keyCode: 65 });

        assert.equal(windowOpenCalls.length, 0);
        assert.equal(evt.defaultPrevented, false);
    });

    test(`XACA-0983-014: UNREACHABLE service card stays non-focusable and non-activatable (${relPath})`, () => {
        const { ctx, windowOpenCalls } = createDomStub();
        const mod = loadClientApp(relPath, ctx);

        const card = mod.createServiceOnlyLcarsCard('academy', unreachableService());

        assert.equal(card.getAttribute('tabindex'), null, 'UNREACHABLE card must not gain tabindex');
        assert.equal(card.getAttribute('role'), null, 'UNREACHABLE card must not gain role=button');
        assert.ok(!card.classList.contains('lcars-clickable'));
        assert.equal(card.listenerCount('keydown'), 0, 'UNREACHABLE card must have no keydown handler at all');

        card.dispatch('keydown', { key: 'Enter', keyCode: 13 });
        assert.equal(windowOpenCalls.length, 0, 'Enter on an UNREACHABLE card must never open a URL');
    });
}

// ============================================================================
// XACA-0983-014: keyboard access -- createTeamCard (session-based card)
// ============================================================================

for (const relPath of CLIENT_FILES) {
    test(`XACA-0983-014: online session-based LCARS card is focusable and keyboard-activatable (${relPath})`, () => {
        const { ctx, windowOpenCalls } = createDomStub();
        const mod = loadClientApp(relPath, ctx);

        const card = mod.createTeamCard('academy', onlineSessionData());

        assert.equal(card.getAttribute('tabindex'), '0');
        assert.equal(card.getAttribute('role'), 'button');

        const evt = card.dispatch('keydown', { key: 'Enter', keyCode: 13 });
        assert.equal(windowOpenCalls.length, 1);
        assert.equal(windowOpenCalls[0].url, 'http://runabout.fleet-test.example:8080');
        assert.equal(evt.defaultPrevented, true);
    });

    test(`XACA-0983-014: offline session-based LCARS card stays non-focusable (${relPath})`, () => {
        const { ctx, windowOpenCalls } = createDomStub();
        const mod = loadClientApp(relPath, ctx);

        const data = onlineSessionData();
        data.sessions[0].machine_status = 'offline';

        const card = mod.createTeamCard('academy', data);

        assert.equal(card.getAttribute('tabindex'), null);
        assert.equal(card.getAttribute('role'), null);
        assert.equal(card.listenerCount('keydown'), 0);

        card.dispatch('keydown', { key: 'Enter', keyCode: 13 });
        assert.equal(windowOpenCalls.length, 0);
    });
}

test('XACA-0983-014 negative control: dispatch() on a card with no keydown listener is a true negative', () => {
    // Sanity check on the test harness itself: a card that never had
    // addEventListener('keydown', ...) called on it must produce zero
    // window.open calls when dispatch() runs -- proving "no listener
    // registered" and "listener registered but declines to act" are
    // distinguishable, not just always green.
    const { document: doc, windowOpenCalls } = createDomStub();
    const card = doc.createElement('div');
    card.dispatch('keydown', { key: 'Enter', keyCode: 13 });
    assert.equal(windowOpenCalls.length, 0);
    assert.equal(card.listenerCount('keydown'), 0);
});

// ============================================================================
// XACA-0983-013: .lcars-offline styling actually loaded by the 5 pages
// ============================================================================

const OFFLINE_RULE_SELECTOR = '.team-card.lcars-terminal.lcars-offline';

const CSS_FILES_UNDER_TEST = ['lcars/css/lcars-fleet-theme.css', 'lcars2/css/lcars-fleet-theme.css'];

// Same tap-mirroring caveat as CLIENT_FILES above: lcars2/lcars-doublenode.html
// (and its app.js) are excluded from the homebrew-tap mirror, so this filters
// to pages that actually exist on disk in whichever repo the suite runs in.
const ALL_PAGES_AND_THEIR_CSS = {
    'lcars/lcars-dashboard.html': ['lcars/css/lcars-fleet.css', 'lcars/css/lcars-fleet-theme.css'],
    'lcars2/lcars-index.html': ['lcars2/css/lcars-fleet.css', 'lcars2/css/lcars-fleet-theme.css'],
    'lcars2/lcars-all.html': ['lcars2/css/lcars-fleet.css', 'lcars2/css/lcars-fleet-theme.css'],
    'lcars2/lcars-doublenode.html': ['lcars2/css/lcars-fleet.css', 'lcars2/css/lcars-fleet-theme.css'],
    'lcars2/lcars-mainevent.html': ['lcars2/css/lcars-fleet.css', 'lcars2/css/lcars-fleet-theme.css']
};
const PAGES_AND_THEIR_CSS = Object.fromEntries(
    Object.entries(ALL_PAGES_AND_THEIR_CSS).filter(([htmlRelPath]) => fs.existsSync(path.join(PUBLIC_ROOT, htmlRelPath)))
);

test('harness sanity: the HTML-page existence filter did not degrade to zero pages', () => {
    assert.ok(
        Object.keys(PAGES_AND_THEIR_CSS).length > 0,
        'PAGES_AND_THEIR_CSS resolved to zero pages -- PUBLIC_ROOT is likely wrong: ' + PUBLIC_ROOT
    );
});

for (const cssRelPath of CSS_FILES_UNDER_TEST) {
    test(`XACA-0983-013: ${cssRelPath} defines a rule for ${OFFLINE_RULE_SELECTOR}`, () => {
        const css = fs.readFileSync(path.join(PUBLIC_ROOT, cssRelPath), 'utf8');
        assert.ok(
            css.includes(OFFLINE_RULE_SELECTOR),
            `expected selector "${OFFLINE_RULE_SELECTOR}" to appear in ${cssRelPath}`
        );
        // The pre-existing 3-selector "black text" rule this fix sits next
        // to must still be intact -- guards against the exact accidental
        // deletion caught and fixed during this ticket's own development.
        assert.ok(
            css.includes('.team-card.lcars-terminal .detail-value'),
            `expected the pre-existing .detail-value text-color rule to still be present in ${cssRelPath}`
        );
    });
}

for (const [htmlRelPath, expectedCss] of Object.entries(PAGES_AND_THEIR_CSS)) {
    test(`XACA-0983-013: ${htmlRelPath} loads a stylesheet that styles ${OFFLINE_RULE_SELECTOR}`, () => {
        const html = fs.readFileSync(path.join(PUBLIC_ROOT, htmlRelPath), 'utf8');
        const loadedCss = expectedCss.filter((cssRelPath) => html.includes(path.basename(cssRelPath)));
        assert.ok(
            loadedCss.length > 0,
            `${htmlRelPath} does not appear to <link> any of: ${expectedCss.join(', ')}`
        );
        const anyStyled = loadedCss.some((cssRelPath) => {
            const css = fs.readFileSync(path.join(PUBLIC_ROOT, cssRelPath), 'utf8');
            return css.includes(OFFLINE_RULE_SELECTOR);
        });
        assert.ok(anyStyled, `none of ${htmlRelPath}'s loaded stylesheets style ${OFFLINE_RULE_SELECTOR}`);
    });
}

test('XACA-0983-013 negative control: styles.css alone (the pre-fix reachable stylesheet) is not loaded by any of the 5 pages', () => {
    // This is the actual pre-fix bug shape: styles.css DOES style
    // .team-card.lcars-terminal.lcars-offline, but none of the 5 pages
    // load styles.css -- so "the selector exists somewhere in the repo"
    // was never sufficient. Confirms the positive assertions above are
    // checking the right thing (stylesheets actually reachable from the
    // page) and not a weaker "exists anywhere" check that would have
    // passed even on the original bug.
    const stylesCss = fs.readFileSync(path.join(PUBLIC_ROOT, 'styles.css'), 'utf8');
    assert.ok(stylesCss.includes(OFFLINE_RULE_SELECTOR), 'sanity: styles.css still styles the offline card');

    for (const htmlRelPath of Object.keys(PAGES_AND_THEIR_CSS)) {
        const html = fs.readFileSync(path.join(PUBLIC_ROOT, htmlRelPath), 'utf8');
        assert.ok(
            !html.includes('href="styles.css"') && !html.includes('href="/styles.css"') && !html.includes('/styles.css"'),
            `${htmlRelPath} unexpectedly loads styles.css`
        );
    }
});
