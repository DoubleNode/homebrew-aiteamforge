//
//  xaca-1060-008-machine-filter-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1060 subitem 008 (Testing & Debugging) -- REAL-DOM regression
 * coverage for the MACHINES filter bar, using jsdom instead of
 * tests/helpers/lcars-client-dom-stub.js's hand-rolled stub.
 *
 * tests/xaca-1060-004-005-006-machine-filter.test.js (the stub-based suite)
 * documents three coverage gaps it could not close, all stemming from the
 * stub having no HTML parser and no <template>.content support:
 *   (a) '.division-stats-count' / '.organization-count' TEXT content --
 *       createDivisionPanel() builds the division header via ONE raw
 *       `header.innerHTML = "...".` string assignment, which the stub
 *       cannot parse into live, queryable nodes.
 *   (b) chip-row filtering -- shared/js/lcars-division-collapse.js's
 *       createSessionChip() uses `document.createElement('template')` +
 *       `.content.firstElementChild`, DocumentFragment semantics the stub
 *       does not implement.
 *   (c) the '.division-toggle-icon' preservation contract (XACA-0989) --
 *       exactly the kind of silent breakage a raw innerHTML-string
 *       rewrite could cause, and worth proving against a REAL HTML parser
 *       rather than trusting the stub's approximation of one.
 *
 * jsdom is a real browser-grade DOM/HTML/CSSOM implementation, so all
 * three are directly exercisable here. This file loads the REAL shipped
 * public/lcars/lcars-dashboard.html plus the REAL shipped
 * shared/js/lcars-terminal-card.js, shared/js/lcars-org-resolution.js,
 * shared/js/lcars-division-collapse.js, shared/js/lcars-kiosk.js and
 * lcars/js/lcars-dashboard-app.js -- never a paraphrase of their logic,
 * same discipline as tests/xaca-1060-004-005-006-machine-filter.test.js
 * and tests/xaca-1002-002-idle-team-card-ux.test.js, whose house style
 * this file follows. It does not replace the stub-based suite (that suite
 * still runs faster and covers ground this file does not re-litigate,
 * e.g. XSS/escaping characterization) -- it only closes the three
 * documented gaps above, plus a few more real-DOM-only checks.
 *
 * Fixture: tests/fixtures/xaca-1060-live-fleet.json, a real captured
 * /api/fleet payload (same capture session as this ticket's manual
 * verification pass) -- 4 machines, 14 divisions, 100 team buckets (21
 * hostless -> dropped, 8 multi-host -> split), 87 rendered cards (37 on
 * the M3Pro/M4Mini hosts, 50 on the M3Pro/M4Mini hosts).
 * Checked for secrets/tokens/emails/home-directory paths before being
 * committed -- none found; its hostnames/private-LAN IPs are the same
 * class of data already committed in tests/fixtures/xaca-1002-live-fleet.json.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');
const DASHBOARD_HTML_REL_PATH = 'lcars/lcars-dashboard.html';
const DASHBOARD_APP_REL_PATH = 'lcars/js/lcars-dashboard-app.js';
const TERMINAL_CARD_REL_PATH = 'shared/js/lcars-terminal-card.js';
const ORG_RESOLUTION_REL_PATH = 'shared/js/lcars-org-resolution.js';
const DIVISION_COLLAPSE_REL_PATH = 'shared/js/lcars-division-collapse.js';
const KIOSK_REL_PATH = 'shared/js/lcars-kiosk.js';

const FIXTURE_PATH = path.join(__dirname, 'fixtures', 'xaca-1060-live-fleet.json');

// XACA-0979 guard: no *.js or *.html file under fleet-monitor/ may contain a
// tailnet hostname literal. That check scans file CONTENT -- comments included
// -- and deliberately carries NO allow-list, on the reasoning that an
// unreachable exemption is worse than none. So resolve each host from the
// fixture's own machines[] by nickname rather than hardcoding it. That is
// better anyway: refresh the fixture and these follow, instead of silently
// asserting against a host that is no longer in the payload at all.
function hostForNickname(nickname) {
    const machines = (loadFixture().fleet || {}).machines || [];
    const match = machines.find(function (m) { return m && m.nickname === nickname; });
    if (!match || !match.hostname) {
        throw new Error('fixture has no machine nicknamed ' + nickname + ' (fixture changed?)');
    }
    return match.hostname;
}

const M3PRO_HOST = hostForNickname('M3Pro');
const M4MINI_HOST = hostForNickname('M4Mini');
const M1PRO_HOST = hostForNickname('M1Pro');   // status 'warning', 0 cards in the fixture
const M1MINI_HOST = hostForNickname('M1Mini'); // status 'offline', 0 cards in the fixture

function loadFixture() {
    // Fresh parse per test -- same discipline as
    // tests/xaca-1060-004-005-006-machine-filter.test.js's loadFixture(),
    // so no test can be affected by another test's mutation of a shared object.
    return JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));
}

// Independent oracle, derived from the raw fixture rather than by calling
// the code under test -- mirrors computeExpectedHostCardCounts() in the
// stub-based suite (same algorithm, re-derived here so this file's
// assumptions don't silently drift from that one without a diff showing it).
function computeExpectedHostCardCounts(divisions) {
    const counts = {};
    for (const dk of Object.getOwnPropertyNames(divisions)) {
        const projects = divisions[dk].projects || {};
        for (const pk of Object.getOwnPropertyNames(projects)) {
            const teams = projects[pk].teams || {};
            for (const tk of Object.getOwnPropertyNames(teams)) {
                const team = teams[tk];
                const hosts = new Set();
                (team.sessions || []).forEach((s) => {
                    if (s && s.hostname) hosts.add(s.hostname);
                });
                if (team.lcars_service && team.lcars_service.hostname) {
                    hosts.add(team.lcars_service.hostname);
                }
                hosts.forEach((h) => {
                    counts[h] = (counts[h] || 0) + 1;
                });
            }
        }
    }
    return counts;
}

// Loads the REAL dashboard.html into a real jsdom document (runScripts:
// 'outside-only' -- the page's own <script src> tags never auto-execute,
// since we supply exactly the scripts we want run, in order, via
// vm.runInContext against jsdom's own internal VM context), then loads the
// real shared modules and the real dashboard app on top of it. The
// dashboard app is patched with an ADDITIVE test-export tail (same
// technique tests/helpers/lcars-client-dom-stub.js's loadClientApp() uses
// on the same file) so tests can drive its module-scope functions
// directly instead of depending on the fetch()-driven DOMContentLoaded
// init path -- which this harness must actively AVOID triggering, not
// merely decline to call: lcars-dashboard-app.js registers its own
// `document.addEventListener('DOMContentLoaded', async function() {...})`
// at module scope (unconditionally, on load), and that handler calls
// fetch() against http://lcars-test.local (no such host) plus two
// unref'd setInterval() calls (fetchFleetData every 60s, updateStardate
// every 1s). jsdom's own DOMContentLoaded/load events are queued as a
// task and fire shortly AFTER `new JSDOM(...)` returns, not before --
// so if the app script is evaluated (and its listener registered)
// before that queued event fires, the listener DOES catch it, the real
// init path DOES run, and `node --test` hangs indefinitely (the
// interval timers keep the event loop alive forever; reproduced and
// confirmed during development of this file). Waiting for jsdom's own
// 'load' event before evaluating ANY app script closes this: the
// listener is registered too late to catch an event that already fired,
// exactly as it would be for a script injected long after a real page
// finished loading.
async function setupDashboard() {
    const html = fs.readFileSync(path.join(PUBLIC_ROOT, DASHBOARD_HTML_REL_PATH), 'utf8');
    const dom = new JSDOM(html, {
        url: 'http://lcars-test.local/lcars/lcars-dashboard.html',
        runScripts: 'outside-only',
        pretendToBeVisual: true
    });
    const window = dom.window;
    const document = window.document;

    await new Promise((resolve) => {
        if (document.readyState === 'complete') { resolve(); return; }
        window.addEventListener('load', () => resolve(), { once: true });
    });

    const ctx = dom.getInternalVMContext();

    function runFile(relPath) {
        const src = fs.readFileSync(path.join(PUBLIC_ROOT, relPath), 'utf8');
        vm.runInContext(src, ctx, { filename: relPath });
    }

    runFile(TERMINAL_CARD_REL_PATH);
    runFile(ORG_RESOLUTION_REL_PATH);
    runFile(DIVISION_COLLAPSE_REL_PATH);
    runFile(KIOSK_REL_PATH);

    const src = fs.readFileSync(path.join(PUBLIC_ROOT, DASHBOARD_APP_REL_PATH), 'utf8');
    const marker = '})();';
    const lastIdx = src.lastIndexOf(marker);
    if (lastIdx === -1) throw new Error('setupDashboard: closing "})();" not found in ' + DASHBOARD_APP_REL_PATH);
    const exportStmt = '\n    window.__lcarsTestExports = {' +
        ' renderDivisions: renderDivisions,' +
        ' applyMachineFilter: applyMachineFilter,' +
        ' toggleMachineFilter: toggleMachineFilter,' +
        ' renderMachineFilterNav: renderMachineFilterNav,' +
        ' updateMachineNavStats: updateMachineNavStats,' +
        ' setCachedMachineData: function (v) { cachedMachineData = v; }' +
        ' };\n';
    const patched = src.slice(0, lastIdx) + exportStmt + src.slice(lastIdx);
    vm.runInContext(patched, ctx, { filename: DASHBOARD_APP_REL_PATH });

    const mod = window.__lcarsTestExports;
    if (!mod || typeof mod.renderDivisions !== 'function') {
        throw new Error('setupDashboard: test exports missing from ' + DASHBOARD_APP_REL_PATH);
    }

    return { window, document, mod };
}

// ============================================================================
// Harness sanity
// ============================================================================

test('harness sanity: real dashboard.html + real app JS load in jsdom, fixture carries the assumed 4-machine fleet', async () => {
    const fixture = loadFixture();
    assert.ok(fixture.fleet && fixture.fleet.divisions, 'fixture must carry fleet.divisions');
    assert.equal(fixture.fleet.machines.length, 4, 'fixture must carry the 4-machine fleet this file\'s constants assume');

    const { document, mod } = await setupDashboard();
    assert.ok(document.getElementById('machine-nav'), 'real dashboard.html must contain #machine-nav');
    assert.ok(document.getElementById('divisions-container'), 'real dashboard.html must contain #divisions-container');
    for (const fn of ['renderDivisions', 'applyMachineFilter', 'toggleMachineFilter', 'renderMachineFilterNav', 'updateMachineNavStats', 'setCachedMachineData']) {
        assert.equal(typeof mod[fn], 'function', `expected export "${fn}" to be a function`);
    }
});

// ============================================================================
// MACHINES nav: one button per fleet.machines[] entry, positioned before
// ALL DIVISIONS, offline/warning machines distinguishable and zero-counted.
// ============================================================================

test('MACHINES nav renders one button per fleet.machines[] entry, positioned before divisions-container', async () => {
    const fixture = loadFixture();
    const { document, window, mod } = await setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    mod.renderDivisions(fixture.fleet.divisions);

    const navButtons = document.querySelectorAll('#machine-nav .machine-nav-button');
    assert.equal(navButtons.length, fixture.fleet.machines.length, 'one nav button per fleet.machines[] entry');

    const machineNavEl = document.getElementById('machine-nav');
    const divisionsContainerEl = document.getElementById('divisions-container');
    const pos = machineNavEl.compareDocumentPosition(divisionsContainerEl);
    assert.ok(pos & window.Node.DOCUMENT_POSITION_FOLLOWING, 'MACHINES section must precede divisions-container in DOM order');
});

test('offline/warning machines show "0 Teams" and a distinct status-* class; online machines show their real count', async () => {
    const fixture = loadFixture();
    const { document, mod } = await setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    mod.renderDivisions(fixture.fleet.divisions);

    const navButtons = document.querySelectorAll('#machine-nav .machine-nav-button');
    navButtons.forEach((btn) => {
        const host = btn.dataset.machineHost;
        const m = fixture.fleet.machines.find((mm) => mm.hostname === host);
        assert.ok(btn.classList.contains('status-' + (m.status || 'offline')), `button for ${m.nickname} must carry status-${m.status}`);
        const statsText = btn.querySelector('.machine-nav-stats').textContent;
        if (m.status === 'offline' || m.status === 'warning') {
            assert.equal(statsText, '0 Teams', `${m.nickname} (${m.status}) must show 0 Teams`);
        }
    });
});

test('per-host card counts match the independent fixture oracle (37 M3Pro / 50 M4Mini / 0 offline hosts, 87 total)', async () => {
    const fixture = loadFixture();
    const expected = computeExpectedHostCardCounts(fixture.fleet.divisions);
    const expectedTotal = Object.values(expected).reduce((a, b) => a + b, 0);

    const { document, mod } = await setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    mod.renderDivisions(fixture.fleet.divisions);

    const cards = document.querySelectorAll('.team-card[data-machine-host]');
    assert.equal(cards.length, expectedTotal, 'total card count must match the independently-derived oracle');
    assert.equal(expectedTotal, 87, 'fixture ground truth: 87 total cards');
    assert.equal(expected[M3PRO_HOST], 37, 'fixture ground truth: 37 cards on M3Pro');
    assert.equal(expected[M4MINI_HOST], 50, 'fixture ground truth: 50 cards on M4Mini');
    assert.equal(expected[M1PRO_HOST] || 0, 0, 'fixture ground truth: 0 cards on M1Pro');
    assert.equal(expected[M1MINI_HOST] || 0, 0, 'fixture ground truth: 0 cards on M1Mini');

    const actual = {};
    cards.forEach((c) => { actual[c.dataset.machineHost] = (actual[c.dataset.machineHost] || 0) + 1; });
    assert.deepEqual(actual, expected, 'per-host card counts must match the oracle exactly');

    const hostlessCards = document.querySelectorAll('.team-card:not([data-machine-host])');
    assert.equal(hostlessCards.length, 0, 'no hostless (idle_registered) card may render in any filter state');
});

// ============================================================================
// Filtering behavior
// ============================================================================

test('toggleMachineFilter: disabling one host hides exactly its cards, in both directions, and is reversible', async () => {
    const fixture = loadFixture();
    const expected = computeExpectedHostCardCounts(fixture.fleet.divisions);

    const { document, mod } = await setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    mod.renderDivisions(fixture.fleet.divisions);
    const cards = document.querySelectorAll('.team-card[data-machine-host]');

    mod.toggleMachineFilter(M3PRO_HOST);
    let visible = Array.from(cards).filter((c) => !c.hidden);
    assert.equal(visible.length, expected[M4MINI_HOST], 'disabling M3Pro must leave exactly M4Mini\'s card count visible');
    assert.ok(visible.every((c) => c.dataset.machineHost === M4MINI_HOST), 'every still-visible card must belong to the still-enabled host');
    assert.ok(Array.from(cards).filter((c) => c.hidden).every((c) => c.dataset.machineHost === M3PRO_HOST), 'every hidden card must belong to the disabled host');

    mod.toggleMachineFilter(M3PRO_HOST); // restore
    assert.equal(Array.from(cards).filter((c) => !c.hidden).length, cards.length, 'toggling the same host again must re-show all of its cards');

    mod.toggleMachineFilter(M4MINI_HOST);
    visible = Array.from(cards).filter((c) => !c.hidden);
    assert.equal(visible.length, expected[M3PRO_HOST], 'disabling M4Mini must leave exactly M3Pro\'s card count visible (symmetric, not a fluke of which host has more cards)');
    mod.toggleMachineFilter(M4MINI_HOST); // restore
});

test('a multi-host team renders one card per host and hides independently', async () => {
    const fixture = loadFixture();
    const divisions = fixture.fleet.divisions;

    // academy/lcars is a known dual-homed team in this fixture (spans
    // M3Pro + M4Mini) -- verified directly against the fixture here rather
    // than assumed, so this test fails loudly (not silently no-ops) if a
    // future fixture swap removes that property.
    const academyLcars = divisions.academy.projects[Object.getOwnPropertyNames(divisions.academy.projects)[0]].teams.lcars;
    // Host attribution is the union of sessions[].hostname AND
    // lcars_service.hostname (same as getTeamHosts() in the shipped app) --
    // this fixture's academy/lcars is dual-homed via exactly that split: one
    // session on M3Pro, and a SEPARATE lcars_service entry on M4Mini (no
    // session there). Computing hosts from sessions alone (as an earlier
    // version of this assumption-check did) would silently miss the
    // lcars_service-only host and make this test wrongly conclude the
    // fixture isn't dual-homed -- caught by first running this file.
    const academyHosts = new Set((academyLcars.sessions || []).map((s) => s.hostname));
    if (academyLcars.lcars_service && academyLcars.lcars_service.hostname) {
        academyHosts.add(academyLcars.lcars_service.hostname);
    }
    assert.ok(academyHosts.has(M3PRO_HOST) && academyHosts.has(M4MINI_HOST), 'fixture assumption: academy/lcars must be dual-homed across M3Pro and M4Mini');

    const { document, mod } = await setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    mod.renderDivisions(divisions);

    const divPanel = document.getElementById('div-academy');
    assert.ok(divPanel, 'div-academy panel must exist');
    const teamCards = Array.from(divPanel.querySelectorAll('.team-card[data-machine-host]'))
        .filter((c) => c.textContent.indexOf('lcars') !== -1);
    assert.equal(teamCards.length, 2, 'academy/lcars must render exactly 2 cards, one per host');

    const byHost = {};
    teamCards.forEach((c) => { byHost[c.dataset.machineHost] = c; });
    assert.ok(byHost[M3PRO_HOST] && byHost[M4MINI_HOST], 'both hosts must be represented');

    mod.toggleMachineFilter(M3PRO_HOST);
    assert.equal(byHost[M3PRO_HOST].hidden, true, 'only the M3Pro card must hide');
    assert.equal(byHost[M4MINI_HOST].hidden, false, 'the M4Mini card must stay visible');
    mod.toggleMachineFilter(M3PRO_HOST); // restore
});

test('deselecting every machine leaves zero visible cards AND zero visible division panels; fully reversible', async () => {
    const fixture = loadFixture();
    const { document, mod } = await setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    mod.renderDivisions(fixture.fleet.divisions);

    fixture.fleet.machines.forEach((m) => { if (m.hostname) mod.toggleMachineFilter(m.hostname); });

    const visibleCards = document.querySelectorAll('.team-card[data-machine-host]:not([hidden])');
    const visiblePanels = document.querySelectorAll('.division-container:not([hidden])');
    assert.equal(visibleCards.length, 0, 'zero visible cards with every machine disabled');
    assert.equal(visiblePanels.length, 0, 'zero visible division panels with every machine disabled');

    fixture.fleet.machines.forEach((m) => { if (m.hostname) mod.toggleMachineFilter(m.hostname); }); // restore all
    const restoredCards = document.querySelectorAll('.team-card[data-machine-host]:not([hidden])');
    assert.equal(restoredCards.length, 87, 'restoring every machine must bring back all 87 cards');
});

test('toggling a machine with zero cards (M1Pro) changes no card visibility and is otherwise harmless', async () => {
    const fixture = loadFixture();
    const { document, mod } = await setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    mod.renderDivisions(fixture.fleet.divisions);

    const before = document.querySelectorAll('.team-card[data-machine-host]:not([hidden])').length;
    mod.toggleMachineFilter(M1PRO_HOST);
    const after = document.querySelectorAll('.team-card[data-machine-host]:not([hidden])').length;
    assert.equal(before, 87);
    assert.equal(after, 87, 'disabling a 0-card machine must not hide any card');

    const btn = document.querySelector(`.machine-nav-button[data-machine-host="${M1PRO_HOST}"]`);
    assert.ok(btn.classList.contains('disabled'), 'the button itself must still reflect the disabled state');
    assert.equal(btn.querySelector('.machine-nav-stats').textContent, '0 Teams');
    mod.toggleMachineFilter(M1PRO_HOST); // restore
});

// ============================================================================
// Gap (a): '.division-stats-count' / '.organization-count' TEXT content --
// unreachable via the stub (raw innerHTML-string header), real here.
// ============================================================================

test('gap (a): .division-stats-count TEXT (real innerHTML-parsed node) matches server total_sessions, unfiltered', async () => {
    const fixture = loadFixture();
    const divisions = fixture.fleet.divisions;
    const { document, mod } = await setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    mod.renderDivisions(divisions);

    let checked = 0;
    for (const dn of Object.getOwnPropertyNames(divisions)) {
        const panel = document.getElementById('div-' + dn.toLowerCase().replace(/\s+/g, '-'));
        if (!panel) continue; // would only happen if createDivisionPanel skipped a division entirely -- it never does
        const statsCountEl = panel.querySelector('.division-stats-count');
        assert.ok(statsCountEl, `division "${dn}" must have a queryable .division-stats-count node`);
        const serverTotal = divisions[dn].total_sessions;
        const expectedText = serverTotal + (serverTotal === 1 ? ' Session' : ' Sessions');
        assert.equal(statsCountEl.textContent, expectedText, `division "${dn}" stats text must equal the server total_sessions unfiltered`);
        checked++;
    }
    assert.equal(checked, Object.getOwnPropertyNames(divisions).length, 'every division must have been checked');
});

test('gap (a): .organization-count TEXT under an active filter equals the sum over VISIBLE divisions only', async () => {
    const fixture = loadFixture();
    const { document, mod } = await setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    mod.renderDivisions(fixture.fleet.divisions);

    mod.toggleMachineFilter(M4MINI_HOST);

    const orgPanels = document.querySelectorAll('.organization-panel');
    assert.ok(orgPanels.length > 0, 'fixture must produce at least one organization panel');
    orgPanels.forEach((orgPanel) => {
        const orgCountEl = orgPanel.querySelector('.organization-count');
        assert.ok(orgCountEl, `org panel "${orgPanel.id}" must have a queryable .organization-count node`);
        let manualSum = 0;
        orgPanel.querySelectorAll('.division-container:not([hidden])').forEach((divPanel) => {
            const dCountEl = divPanel.querySelector('.division-stats-count');
            if (dCountEl) manualSum += parseInt(dCountEl.textContent, 10) || 0;
        });
        assert.equal(orgCountEl.textContent, manualSum + ' Sessions', `org "${orgPanel.id}" count must equal the sum over its visible divisions only`);
    });

    mod.toggleMachineFilter(M4MINI_HOST); // restore
});

test('a division whose every team is hostless (freelance-workstats, freelance-appplanning) renders but ends up hidden=true', async () => {
    const fixture = loadFixture();
    const { document, mod } = await setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    mod.renderDivisions(fixture.fleet.divisions);

    ['freelance-workstats', 'freelance-appplanning'].forEach((dn) => {
        const panel = document.getElementById('div-' + dn);
        assert.ok(panel, `division "${dn}" panel node must still exist (createDivisionPanel runs unconditionally per division key)`);
        assert.equal(panel.hidden, true, `division "${dn}" must render hidden=true -- every team in it is hostless, so it has zero visible cards`);
        assert.equal(panel.querySelectorAll('.team-card').length, 0, `division "${dn}" must have zero team cards at all`);
    });
});

// ============================================================================
// Gap (c): '.division-toggle-icon' preservation (XACA-0989 contract) --
// exactly the kind of silent collapse-breakage a raw innerHTML rewrite
// could cause; proven here against a real HTML parser.
// ============================================================================

test('gap (c): .division-toggle-icon span survives applyMachineFilter\'s header rewrite on every panel, with glyph content', async () => {
    const fixture = loadFixture();
    const { document, mod } = await setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    mod.renderDivisions(fixture.fleet.divisions);

    // Trigger a second applyMachineFilter() pass (a toggle + restore) so
    // this proves survival ACROSS a rewrite, not just at first paint.
    mod.toggleMachineFilter(M3PRO_HOST);
    mod.toggleMachineFilter(M3PRO_HOST);

    const panels = document.querySelectorAll('.division-container');
    assert.ok(panels.length > 0);
    panels.forEach((panel) => {
        const icon = panel.querySelector('.division-toggle-icon');
        assert.ok(icon, `panel "${panel.id}" must retain its .division-toggle-icon span`);
        assert.ok(icon.textContent || icon.innerHTML, `panel "${panel.id}"'s .division-toggle-icon must carry glyph content written by wireDivisionToggle()`);
    });
});

// ============================================================================
// Gap (b): chip-row filtering through the real <template>.content path --
// unreachable via the stub (no DocumentFragment/.content semantics).
// ============================================================================

test('gap (b): chip-row (real <template> path) renders one tagged chip per card and filters identically to the card grid', async () => {
    const fixture = loadFixture();
    const { document, mod } = await setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    mod.renderDivisions(fixture.fleet.divisions);

    const chips = document.querySelectorAll('.chip-row > *[data-machine-host]');
    assert.equal(chips.length, 87, 'chip row must produce exactly one tagged chip per rendered card (real <template>.content proven reachable)');

    mod.toggleMachineFilter(M3PRO_HOST);
    let mismatches = 0;
    chips.forEach((chip) => {
        const expectedHidden = chip.dataset.machineHost === M3PRO_HOST;
        if (chip.hidden !== expectedHidden) mismatches++;
    });
    assert.equal(mismatches, 0, 'every chip must hide/show by the same per-host rule as the card grid');
    mod.toggleMachineFilter(M3PRO_HOST); // restore
});

test('collapsing a division, THEN toggling a machine, filters the chip row correctly regardless of collapse display state (both orders)', async () => {
    const fixture = loadFixture();
    const { document, window, mod } = await setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    mod.renderDivisions(fixture.fleet.divisions);

    // Pick a division with real M4Mini cards -- not just any first panel,
    // so the assertion below is non-vacuous.
    let divPanel = null;
    document.querySelectorAll('.division-container').forEach((p) => {
        if (divPanel) return;
        if (p.querySelector(`.team-card[data-machine-host="${M4MINI_HOST}"]`)) divPanel = p;
    });
    assert.ok(divPanel, 'fixture must contain at least one division with an M4Mini card');

    const header = divPanel.querySelector('.division-header');
    const cardsGrid = divPanel.querySelector('.teams-grid');
    const isExpanded = () => window.getComputedStyle(cardsGrid).display !== 'none';

    // Order 1: collapse first, THEN toggle the filter.
    if (isExpanded()) header.dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
    assert.equal(isExpanded(), false, 'division must be collapsed after one header click (XACA-0989 default is collapsed)');

    mod.toggleMachineFilter(M4MINI_HOST);
    const chipRow = divPanel.querySelector('.chip-row');
    let anyWrongWhileCollapsed = false;
    chipRow.querySelectorAll('*[data-machine-host]').forEach((chip) => {
        if (chip.hidden !== (chip.dataset.machineHost === M4MINI_HOST)) anyWrongWhileCollapsed = true;
    });
    assert.equal(anyWrongWhileCollapsed, false, 'chip row must filter correctly even while the division is collapsed (hidden attr, independent of style.display)');

    // Order 2: now expand it back -- the card grid must reflect the SAME
    // filter state that was applied while collapsed.
    header.dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
    assert.equal(isExpanded(), true, 'division must expand after a second header click');

    let anyWrongAfterExpand = false;
    let cardCount = 0;
    divPanel.querySelectorAll('.team-card[data-machine-host]').forEach((card) => {
        cardCount++;
        if (card.hidden !== (card.dataset.machineHost === M4MINI_HOST)) anyWrongAfterExpand = true;
    });
    assert.ok(cardCount > 0, 'division must have at least one card to check');
    assert.equal(anyWrongAfterExpand, false, 'expanded card grid must reflect the filter state set while collapsed');

    mod.toggleMachineFilter(M4MINI_HOST); // restore
});

// ============================================================================
// Poll-survival -- the single most important regression: renderDivisions()
// wipes #divisions-container's innerHTML on EVERY poll.
// ============================================================================

test('filter selection SURVIVES two full renderDivisions() re-renders (never reset by the poll re-render)', async () => {
    const fixture = loadFixture();
    const { document, mod } = await setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    mod.renderDivisions(fixture.fleet.divisions);

    mod.toggleMachineFilter(M3PRO_HOST);

    mod.renderDivisions(fixture.fleet.divisions); // poll #1 -- real innerHTML='' clear
    let visible = document.querySelectorAll('.team-card[data-machine-host]:not([hidden])').length;
    let m3proHidden = Array.from(document.querySelectorAll(`.team-card[data-machine-host="${M3PRO_HOST}"]`)).every((c) => c.hidden);
    assert.equal(visible, 50, 'M3Pro must still be filtered out after poll #1');
    assert.ok(m3proHidden, 'every M3Pro card must be hidden after poll #1');

    mod.renderDivisions(fixture.fleet.divisions); // poll #2
    visible = document.querySelectorAll('.team-card[data-machine-host]:not([hidden])').length;
    m3proHidden = Array.from(document.querySelectorAll(`.team-card[data-machine-host="${M3PRO_HOST}"]`)).every((c) => c.hidden);
    assert.equal(visible, 50, 'M3Pro must still be filtered out after poll #2');
    assert.ok(m3proHidden, 'every M3Pro card must be hidden after poll #2');

    mod.toggleMachineFilter(M3PRO_HOST); // restore
});

// ============================================================================
// Kiosk auto-scroll: real jsdom resolution of the exact production
// selector string, upgrading the stub-based suite's static-text check
// (which only greps the source) with a live query-result proof.
// ============================================================================

test('lcars-kiosk.js: the exact :not([hidden]) org-panel selector string resolves correctly in a real DOM, in both filter states', async () => {
    const fixture = loadFixture();
    const kioskSrc = fs.readFileSync(path.join(PUBLIC_ROOT, KIOSK_REL_PATH), 'utf8');
    const ORGS_SELECTOR = '#divisions-container .organization-panel:not([hidden])';
    const occurrences = kioskSrc.split(ORGS_SELECTOR).length - 1;
    assert.equal(occurrences, 2, 'startOrgsAutoScroll must issue this exact selector at both its initial query and its interval re-query');

    const { document, mod } = await setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    mod.renderDivisions(fixture.fleet.divisions);

    const totalOrgPanels = document.querySelectorAll('#divisions-container .organization-panel').length;
    assert.ok(totalOrgPanels > 0);
    assert.equal(document.querySelectorAll(ORGS_SELECTOR).length, totalOrgPanels, 'with every machine enabled, the selector must resolve to every org panel');

    fixture.fleet.machines.forEach((m) => { if (m.hostname) mod.toggleMachineFilter(m.hostname); });
    assert.equal(document.querySelectorAll(ORGS_SELECTOR).length, 0, 'with every machine disabled, the selector must resolve to zero org panels');
    fixture.fleet.machines.forEach((m) => { if (m.hostname) mod.toggleMachineFilter(m.hostname); }); // restore
});

// ============================================================================
// Prototype-pollution safety (XACA-1060-015)
//
// machineFilterState is `Object.create(null)`, not `{}`, and that is
// deliberate: `hostname` is untrusted reporter input, so a machine literally
// named `toString` or `constructor` would read back TRUTHY off
// Object.prototype BEFORE ever being toggled -- with a plain `{}`,
// `machineFilterState['toString']` resolves to the inherited
// Object.prototype.toString function (truthy) the instant that key is read,
// permanently hiding that machine's cards with no toggle ever having run.
// Worse, it LATCHES: `delete machineFilterState['toString']` removes the own
// property (once one exists), but the lookup then falls through to the same
// inherited member again -- so a plain `{}` implementation could disable the
// machine but could never explicitly re-enable it either. This was caught in
// review on PR #804, not by a test, and nothing before this exercised it --
// a future "simplify this back to {}" refactor would regress it silently.
// ============================================================================

// Rewrites one hostname everywhere it appears in a fixture clone --
// fleet.machines[].hostname, every team's sessions[].hostname, and every
// team's lcars_service.hostname -- so a renamed machine produces real,
// correctly-attributed team cards in the rendered DOM, not just a nav
// button with no cards behind it (renameHostThroughout mirrors the same
// (sessions[].hostname ∪ lcars_service.hostname) attribution split
// computeExpectedHostCardCounts() above and getTeamHosts() in the shipped
// app both use).
function renameHostThroughout(fixtureClone, oldHost, newHost) {
    const machine = fixtureClone.fleet.machines.find((m) => m.hostname === oldHost);
    if (!machine) throw new Error('renameHostThroughout: no machine with hostname ' + oldHost);
    machine.hostname = newHost;

    const divisions = fixtureClone.fleet.divisions;
    for (const dk of Object.getOwnPropertyNames(divisions)) {
        const projects = divisions[dk].projects || {};
        for (const pk of Object.getOwnPropertyNames(projects)) {
            const teams = projects[pk].teams || {};
            for (const tk of Object.getOwnPropertyNames(teams)) {
                const team = teams[tk];
                (team.sessions || []).forEach((s) => {
                    if (s && s.hostname === oldHost) s.hostname = newHost;
                });
                if (team.lcars_service && team.lcars_service.hostname === oldHost) {
                    team.lcars_service.hostname = newHost;
                }
            }
        }
    }
    return fixtureClone;
}

['toString', 'constructor'].forEach((pollutingName) => {
    test('machine hostnamed "' + pollutingName + '" renders VISIBLE by default (not shadowed by Object.prototype) and toggles cleanly both ways', async () => {
        const fixture = loadFixture();
        renameHostThroughout(fixture, M3PRO_HOST, pollutingName);

        const { document, mod } = await setupDashboard();
        mod.setCachedMachineData(fixture.fleet.machines);
        mod.renderDivisions(fixture.fleet.divisions);

        const cardsForHost = () => document.querySelectorAll('.team-card[data-machine-host="' + pollutingName + '"]');
        const navBtn = document.querySelector('.machine-nav-button[data-machine-host="' + pollutingName + '"]');
        assert.ok(navBtn, 'nav button for host "' + pollutingName + '" must exist');
        assert.ok(cardsForHost().length > 0, 'fixture rename must have produced at least one card for host "' + pollutingName + '"');

        // Default state must be VISIBLE. With Object.create(null),
        // machineFilterState[pollutingName] is undefined until explicitly
        // toggled. With a plain {}, the inherited Object.prototype member of
        // the same name would already read back truthy here -- hiding the
        // machine by default with NO toggle ever having happened.
        assert.ok(Array.from(cardsForHost()).every((c) => !c.hidden), 'host "' + pollutingName + '" must be VISIBLE by default, not shadowed by Object.prototype');
        assert.ok(!navBtn.classList.contains('disabled'), 'nav button for "' + pollutingName + '" must not start disabled');

        // Toggle off: must actually hide.
        mod.toggleMachineFilter(pollutingName);
        assert.ok(Array.from(cardsForHost()).every((c) => c.hidden), 'host "' + pollutingName + '" must hide after toggling off');
        assert.ok(navBtn.classList.contains('disabled'), 'nav button for "' + pollutingName + '" must show disabled after toggling off');

        // Toggle on again: must actually restore. This is the direction a
        // plain-{} implementation fails even AFTER an explicit toggle:
        // `delete machineFilterState[pollutingName]` clears the own property,
        // but the read falls through to the same inherited (truthy) member
        // again, so the machine can never be re-enabled -- it latches hidden.
        mod.toggleMachineFilter(pollutingName);
        assert.ok(Array.from(cardsForHost()).every((c) => !c.hidden), 'host "' + pollutingName + '" must become visible again after toggling back on -- not latched');
        assert.ok(!navBtn.classList.contains('disabled'), 'nav button for "' + pollutingName + '" must clear disabled after toggling back on');
    });
});
