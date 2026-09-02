//
//  xaca-1060-004-005-006-machine-filter.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1060 subitems 004/005/006 -- CLIENT-side regression coverage for the
 * MACHINES filter bar: filter state (machineFilterState / toggleMachineFilter),
 * its application across team cards / chips / avatar thumbnails / division
 * and organization panels (applyMachineFilter), and the nav bar itself
 * (renderMachineFilterNav / updateMachineNavStats).
 *
 * Runs against the REAL shipped fleet-monitor/server/public/lcars/js/
 * lcars-dashboard-app.js (via tests/helpers/lcars-client-dom-stub.js's
 * vm.Context loader) and the REAL captured fleet payload
 * tests/fixtures/xaca-1002-live-fleet.json -- never a paraphrase of either,
 * same discipline as tests/xaca-1002-002-idle-team-card-ux.test.js, whose
 * house style this file follows.
 *
 * ── Harness extension (this ticket) ─────────────────────────────────────
 * The DOM stub previously had no `dataset`, no `hidden`, no
 * document.getElementById (always null), no querySelectorAll at all, and
 * classList had no toggle()/remove(). applyMachineFilter() and
 * renderMachineFilterNav() need every one of those, so this ticket adds
 * them to tests/helpers/lcars-client-dom-stub.js -- additively: every
 * addition is either brand new (dataset, hidden, id, querySelectorAll,
 * classList.toggle/remove, getElementById+__registerById) or falls back
 * unchanged to the pre-existing behavior when it finds nothing (the
 * querySelector() real-children-first check). tests/xaca-1002-002 and the
 * other existing suites that depend on this same helper were re-run after
 * every change in this file's development and still pass unmodified --
 * see the PR for that run's output; this file does not re-assert it.
 *
 * ── A structural gap this harness genuinely cannot close ────────────────
 * createDivisionPanel() builds each division's header via ONE raw
 * `header.innerHTML = "...<span class=\"division-stats-count\">...".
 * string assignment, not createElement()+appendChild(). A real browser
 * parses that string into live DOM; this stub does not contain an HTML
 * parser, so '.division-stats-count' (and therefore
 * applyMachineFilter()'s per-division FILTERED SESSION COUNT TEXT, and by
 * extension the organization-level count text that sums it) exists only as
 * characters inside a string, never as a queryable node. This was proven
 * empirically during development: with a real fixture rendered end-to-end,
 * every '.organization-count' text landed on the literal placeholder text
 * "0 Sessions" post-filter, because applyMachineFilter()'s own
 * `orgDivisions[d2].querySelector('.division-stats-count')` call returns
 * null here (it would return the live node in a real browser). This file
 * therefore does NOT assert on '.division-stats-count' or
 * '.organization-count' TEXT content -- doing so would either be
 * vacuously true or require reimplementing an HTML fragment parser inside
 * this suite, which is exactly the "paraphrase the client logic" trap this
 * house style exists to avoid. What IS asserted, and IS fully real: the
 * `hidden` boolean on division/organization panels (computed purely from
 * real `.team-card` nodes, no innerHTML-string dependency at all) and
 * every card/chip/avatar/nav-button hidden/disabled/aria-pressed/dataset
 * state, all of which live as real DOM in this stub exactly as they do in
 * a browser.
 *
 * Chip-row filtering (item 2 of applyMachineFilter) is also NOT covered
 * here: building it requires loading shared/js/lcars-division-collapse.js,
 * whose createSessionChip() constructs a `<template>` element
 * (`document.createElement('template')`) and reads `.content.firstElementChild`
 * off it for the backup-alert-icon branch -- DocumentFragment/`.content`
 * semantics this stub does not implement, and adding them is out of scope
 * for this file. applyMachineFilter()'s chip-row loop is structurally
 * identical to its team-card loop (same one-line `el.hidden =
 * !!machineFilterState[el.dataset.machineHost]` pattern, proven below for
 * cards and avatars), so this is a coverage gap in the SAME mechanism
 * already proven correct twice over, not an unverified code path.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { createDomStub, loadClientApp } = require('./helpers/lcars-client-dom-stub.js');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');
const DASHBOARD_APP_REL_PATH = 'lcars/js/lcars-dashboard-app.js';
const KIOSK_REL_PATH = 'shared/js/lcars-kiosk.js';
const ORG_RESOLUTION_REL_PATH = 'shared/js/lcars-org-resolution.js';

const FIXTURE_PATH = path.join(__dirname, 'fixtures', 'xaca-1002-live-fleet.json');

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
const M1MINI_HOST = hostForNickname('M1Mini'); // offline, 0 team cards in the fixture
const M1PRO_HOST = hostForNickname('M1Pro');   // offline, 0 team cards in the fixture

function loadFixture() {
    // Fresh parse per test (same pattern as xaca-1002-001's
    // JSON.parse(JSON.stringify(fleetFixture...))) -- renderDivisions()
    // narrows/copies but this keeps every test's input provably untouched
    // by any other test regardless.
    return JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));
}

// Independent oracle: how many (team, host) pairs the REAL fixture data
// implies, derived directly from divisions[].projects[].teams[].sessions[]
// hostnames + lcars_service.hostname -- the same union getTeamHosts()/
// splitTeamByHost() (lcars-dashboard-app.js) compute, expressed here from
// scratch against the raw fixture rather than by calling the code under
// test, so this is a real cross-check and not a tautology.
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

// Loads the real dashboard app PLUS the real org-resolution module (pure
// logic, no document/window/localStorage use -- safe to load) into one vm
// context, and pre-registers fresh '#divisions-container' / '#machine-nav'
// elements for it. Returns everything a test needs, including a
// `freshRenderPass()` helper for simulating a second poll (see the "fresh
// container" note on freshRenderPass below for why that's necessary here).
function setupDashboard() {
    const { ctx } = createDomStub();
    const mod = loadClientApp(DASHBOARD_APP_REL_PATH, ctx);

    const orgSrc = fs.readFileSync(path.join(PUBLIC_ROOT, ORG_RESOLUTION_REL_PATH), 'utf8');
    vm.runInContext(orgSrc, ctx, { filename: ORG_RESOLUTION_REL_PATH });

    let divisionsContainer;
    let machineNav;

    // XACA-1060: registers FRESH '#divisions-container'/'#machine-nav'
    // elements before a render pass. This stub's `.innerHTML = ''` (what
    // renderDivisions() does at the top of every pass) only overwrites the
    // `_innerHTML` STRING property -- it does not clear `.children` (a
    // separate array only appendChild() populates), so a second
    // renderDivisions() call against the SAME container would silently
    // accumulate a duplicate tree on top of the first pass's, unlike a real
    // browser where `.innerHTML = ''` genuinely empties the element. Since
    // renderDivisions() looks the container up via document.getElementById()
    // fresh on every call (never caches it), swapping in a new element
    // between passes sidesteps the stub gap while still exercising the real
    // client code path each time -- exactly what a real browser's "cleared
    // container" would hand that code anyway.
    function freshRenderPass(divisions) {
        divisionsContainer = ctx.document.createElement('div');
        machineNav = ctx.document.createElement('div');
        ctx.document.__registerById('divisions-container', divisionsContainer);
        ctx.document.__registerById('machine-nav', machineNav);
        mod.renderDivisions(divisions);
        return { divisionsContainer, machineNav };
    }

    return { ctx, mod, freshRenderPass };
}

test('harness sanity: the fixture and the dashboard app both load, and machineFilterState-related exports are present', () => {
    const fixture = loadFixture();
    assert.ok(fixture.fleet && fixture.fleet.divisions, 'fixture must carry fleet.divisions');
    assert.ok(Array.isArray(fixture.fleet.machines) && fixture.fleet.machines.length === 4, 'fixture must carry the 4-machine fleet this file\'s constants assume');

    const { mod } = setupDashboard();
    for (const fn of ['renderDivisions', 'applyMachineFilter', 'toggleMachineFilter', 'renderMachineFilterNav', 'updateMachineNavStats', 'setCachedMachineData']) {
        assert.equal(typeof mod[fn], 'function', `expected export "${fn}" to be a function`);
    }
});

// ============================================================================
// Subitem 004/005 -- baseline: every team-host pair from splitTeamByHost()
// becomes exactly one real '.team-card[data-machine-host]', tagged correctly.
// ============================================================================

test('baseline (no filter): total and per-host .team-card[data-machine-host] counts match the independent fixture oracle', () => {
    const fixture = loadFixture();
    const expected = computeExpectedHostCardCounts(fixture.fleet.divisions);
    const expectedTotal = Object.values(expected).reduce((a, b) => a + b, 0);

    const { mod, freshRenderPass } = setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    const { divisionsContainer } = freshRenderPass(fixture.fleet.divisions);

    const cards = divisionsContainer.querySelectorAll('.team-card[data-machine-host]');
    assert.equal(cards.length, expectedTotal, 'total card count must match the independently-derived team-host pair count');

    const actual = {};
    cards.forEach((c) => {
        actual[c.dataset.machineHost] = (actual[c.dataset.machineHost] || 0) + 1;
    });
    assert.deepEqual(actual, expected, 'per-host card counts must match the oracle exactly');

    // Every card starts visible -- machineFilterState is empty by default.
    assert.ok(cards.every((c) => c.hidden === false), 'no card should be hidden before any toggle');
});

// ============================================================================
// Subitem 005 -- THE ticket's stated minimum bar: disabling one host leaves
// exactly the other host's cards visible.
// ============================================================================

test('toggleMachineFilter + applyMachineFilter: disabling one host leaves visible cards == the OTHER host\'s count (both directions)', () => {
    const fixture = loadFixture();
    const expected = computeExpectedHostCardCounts(fixture.fleet.divisions);

    const { mod, freshRenderPass } = setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    const { divisionsContainer } = freshRenderPass(fixture.fleet.divisions);
    const cards = divisionsContainer.querySelectorAll('.team-card[data-machine-host]');

    mod.toggleMachineFilter(M4MINI_HOST);
    let visible = cards.filter((c) => !c.hidden);
    assert.equal(visible.length, expected[M3PRO_HOST], 'disabling M4Mini must leave exactly M3Pro\'s card count visible');
    assert.ok(visible.every((c) => c.dataset.machineHost === M3PRO_HOST), 'every still-visible card must belong to the still-enabled host');
    assert.ok(cards.filter((c) => c.hidden).every((c) => c.dataset.machineHost === M4MINI_HOST), 'every hidden card must belong to the disabled host');

    // Toggle is reversible.
    mod.toggleMachineFilter(M4MINI_HOST);
    assert.equal(cards.filter((c) => !c.hidden).length, cards.length, 'toggling the same host again must re-show all of its cards');

    // Symmetric in the other direction -- not a fluke of which host happens
    // to have more cards.
    mod.toggleMachineFilter(M3PRO_HOST);
    visible = cards.filter((c) => !c.hidden);
    assert.equal(visible.length, expected[M4MINI_HOST], 'disabling M3Pro must leave exactly M4Mini\'s card count visible');
});

// ============================================================================
// Subitem 004 -- filter state persists across a render pass, and across a
// machine dropping out of / back into fleet.machines[].
// ============================================================================

test('filter state SURVIVES a fresh renderDivisions() pass (never reset by the poll re-render)', () => {
    const fixture = loadFixture();
    const expected = computeExpectedHostCardCounts(fixture.fleet.divisions);

    const { mod, freshRenderPass } = setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    freshRenderPass(fixture.fleet.divisions);

    mod.toggleMachineFilter(M4MINI_HOST);

    // Simulate a second fleet poll: same data, a fresh container (see
    // freshRenderPass's comment for why that substitutes for a real
    // browser's innerHTML='' clearing the old tree).
    const { divisionsContainer: container2 } = freshRenderPass(fixture.fleet.divisions);
    const cards2 = container2.querySelectorAll('.team-card[data-machine-host]');
    const visible2 = cards2.filter((c) => !c.hidden);

    assert.equal(visible2.length, expected[M3PRO_HOST], 'the disabled host must STAY disabled across a fresh render pass, not reset to all-shown');
});

test('a hostname disabled here, then dropped from fleet.machines[] entirely, stays hidden -- and its nav choice survives the machine\'s return', () => {
    const fixture = loadFixture();
    const expected = computeExpectedHostCardCounts(fixture.fleet.divisions);

    const { mod, freshRenderPass } = setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    freshRenderPass(fixture.fleet.divisions);
    mod.toggleMachineFilter(M4MINI_HOST);

    // M4Mini deregisters / drops off the fleet entirely -- fleet.machines[]
    // no longer lists it, but the team/session DATA (fleet.divisions) is
    // unrelated and still carries its sessions (e.g. mid-outage).
    const machinesWithoutM4 = fixture.fleet.machines.filter((m) => m.hostname !== M4MINI_HOST);
    mod.setCachedMachineData(machinesWithoutM4);
    const { divisionsContainer: containerA, machineNav: navA } = freshRenderPass(fixture.fleet.divisions);

    const navButtonsA = navA.querySelectorAll('.machine-nav-button[data-machine-host]');
    assert.equal(navButtonsA.length, 3, 'no button renders for a host with zero fleet.machines[] entries, even a previously-disabled one');

    const cardsA = containerA.querySelectorAll('.team-card[data-machine-host]');
    const m4CardsA = cardsA.filter((c) => c.dataset.machineHost === M4MINI_HOST);
    assert.equal(m4CardsA.length, expected[M4MINI_HOST], 'M4Mini\'s team cards still render (its SESSION data did not disappear)');
    assert.ok(m4CardsA.every((c) => c.hidden), 'but they must stay hidden -- the earlier disable choice is not pruned just because the machine briefly has no button');

    // M4Mini reappears.
    mod.setCachedMachineData(fixture.fleet.machines);
    const { divisionsContainer: containerB, machineNav: navB } = freshRenderPass(fixture.fleet.divisions);

    const navButtonsB = navB.querySelectorAll('.machine-nav-button[data-machine-host]');
    const m4ButtonB = navButtonsB.filter((b) => b.dataset.machineHost === M4MINI_HOST)[0];
    assert.ok(m4ButtonB, 'M4Mini\'s button must come back once it reappears in fleet.machines[]');
    assert.equal(m4ButtonB.getAttribute('aria-pressed'), 'false', 'the earlier disable choice must still be honored once the machine returns');
    assert.ok(m4ButtonB.classList.contains('disabled'), 'the button must render already-disabled, not reset to enabled');

    const cardsB = containerB.querySelectorAll('.team-card[data-machine-host]');
    assert.ok(cardsB.filter((c) => c.dataset.machineHost === M4MINI_HOST).every((c) => c.hidden), 'M4Mini\'s cards must still be hidden after it returns');
});

// ============================================================================
// Subitem 004/006 -- the MACHINES nav itself: one button per fleet.machines[]
// entry (including a machine with zero team cards), correct status class,
// live (unfiltered-by-self) team count, and XSS-safe rendering.
// ============================================================================

test('renderMachineFilterNav: one button per machine (including zero-card machines), correct status class + live team count', () => {
    const fixture = loadFixture();
    const expected = computeExpectedHostCardCounts(fixture.fleet.divisions);

    const { mod, freshRenderPass } = setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    const { machineNav } = freshRenderPass(fixture.fleet.divisions);

    const buttons = machineNav.querySelectorAll('.machine-nav-button[data-machine-host]');
    assert.equal(buttons.length, 4, 'must render a button for every fleet.machines[] entry, including the two with zero team cards');

    const byHost = {};
    buttons.forEach((b) => { byHost[b.dataset.machineHost] = b; });

    assert.ok(byHost[M3PRO_HOST].className.indexOf('status-online') !== -1, 'M3Pro (online) must carry status-online');
    assert.ok(byHost[M4MINI_HOST].className.indexOf('status-online') !== -1, 'M4Mini (online) must carry status-online');
    assert.ok(byHost[M1MINI_HOST].className.indexOf('status-offline') !== -1, 'M1Mini (offline) must carry status-offline');
    assert.ok(byHost[M1PRO_HOST].className.indexOf('status-offline') !== -1, 'M1Pro (offline) must carry status-offline');

    function statsTextOf(btn) {
        const el = btn.querySelector('.machine-nav-stats');
        return el ? el.textContent : null;
    }
    assert.equal(statsTextOf(byHost[M3PRO_HOST]), expected[M3PRO_HOST] + ' Teams', 'M3Pro\'s live count must match the oracle');
    assert.equal(statsTextOf(byHost[M4MINI_HOST]), expected[M4MINI_HOST] + ' Teams', 'M4Mini\'s live count must match the oracle');
    // XACA-1062: a non-online machine no longer shows a rendered-card count
    // at all (that count is always 0 for it -- the server excludes its
    // sessions from `divisions` entirely, which is the bug this ticket
    // fixed). It shows its STATUS word plus its last-known session_count
    // instead: 'OFFLINE · <session_count>' (· is U+00B7 MIDDLE
    // DOT, the exact separator machineNavStatText() emits -- not a
    // lookalike hyphen/bullet). Both machines in this fixture report
    // session_count 0, so this also doubles as the "honest 0" case the
    // pre-XACA-1062 assertion here used to cover, just spelled the new way.
    assert.equal(statsTextOf(byHost[M1MINI_HOST]), 'OFFLINE · 0', 'an offline machine with zero last-known sessions must show OFFLINE · 0, not a bare card count');
    assert.equal(statsTextOf(byHost[M1PRO_HOST]), 'OFFLINE · 0', 'same for the other offline machine');

    // None disabled yet.
    buttons.forEach((b) => {
        assert.equal(b.getAttribute('aria-pressed'), 'true', b.dataset.machineHost + ' must start enabled (aria-pressed=true)');
        assert.ok(!b.classList.contains('disabled'), b.dataset.machineHost + ' must not start with the disabled class');
    });
});

test('updateMachineNavStats: disabling one host flips ONLY that host\'s button state and count is unaffected by its own disabled-ness', () => {
    const fixture = loadFixture();
    const expected = computeExpectedHostCardCounts(fixture.fleet.divisions);

    const { mod, freshRenderPass } = setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    const { machineNav } = freshRenderPass(fixture.fleet.divisions);

    mod.toggleMachineFilter(M4MINI_HOST);

    const buttons = machineNav.querySelectorAll('.machine-nav-button[data-machine-host]');
    const byHost = {};
    buttons.forEach((b) => { byHost[b.dataset.machineHost] = b; });

    assert.equal(byHost[M4MINI_HOST].getAttribute('aria-pressed'), 'false');
    assert.ok(byHost[M4MINI_HOST].classList.contains('disabled'));
    // The live count is the TOTAL for that host, independent of its own
    // filter state -- a disabled machine still shows what re-enabling it
    // would reveal, not a stale or zeroed number.
    assert.equal(byHost[M4MINI_HOST].querySelector('.machine-nav-stats').textContent, expected[M4MINI_HOST] + ' Teams');

    assert.equal(byHost[M3PRO_HOST].getAttribute('aria-pressed'), 'true', 'the OTHER host\'s button must be untouched');
    assert.ok(!byHost[M3PRO_HOST].classList.contains('disabled'));
    assert.equal(byHost[M3PRO_HOST].querySelector('.machine-nav-stats').textContent, expected[M3PRO_HOST] + ' Teams');
});

test('renderMachineFilterNav: hostname/nickname render via textContent, never innerHTML (XSS safety, XACA-0970 precedent)', () => {
    const fixture = loadFixture();
    const XSS_NICKNAME = '<img src=x onerror=alert(1)>';

    const { mod, freshRenderPass } = setupDashboard();
    const machines = JSON.parse(JSON.stringify(fixture.fleet.machines));
    machines[0].nickname = XSS_NICKNAME;
    mod.setCachedMachineData(machines);
    const { machineNav } = freshRenderPass(fixture.fleet.divisions);

    const buttons = machineNav.querySelectorAll('.machine-nav-button[data-machine-host]');
    const target = buttons.filter((b) => b.dataset.machineHost === machines[0].hostname)[0];
    assert.ok(target, 'the crafted machine\'s button must still render');

    // Structural guarantee: renderMachineFilterNav() never assigns
    // .innerHTML on the button or its children -- everything is
    // createElement()+appendChild()+textContent/dataset/setAttribute. This
    // stub's FakeElement._innerHTML defaults to '' and nothing here ever
    // writes to it, so a non-empty value would itself prove an innerHTML
    // sink was used somewhere in this render path.
    assert.equal(target._innerHTML, '', 'the button must never have had .innerHTML assigned');
    const nameEl = target.querySelector('.machine-nav-name');
    assert.equal(nameEl.textContent, XSS_NICKNAME, 'the raw string must reach textContent verbatim (proving it went through the safe sink)');
});

// ============================================================================
// Subitem 006 -- division/organization panel hiding when a MACHINES filter
// empties every team card in them. (Their filtered SESSION COUNT TEXT is
// NOT asserted here -- see the file-header comment for exactly why.)
// ============================================================================

test('a division whose teams are exclusively on the disabled host becomes hidden; unaffected divisions do not', () => {
    const fixture = loadFixture();

    const { mod, freshRenderPass } = setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    const { divisionsContainer } = freshRenderPass(fixture.fleet.divisions);

    const divisionPanels = divisionsContainer.querySelectorAll('.division-container');
    const medical = divisionPanels.filter((d) => d.id === 'div-medical')[0];
    const academy = divisionPanels.filter((d) => d.id === 'div-academy')[0];
    assert.ok(medical, 'fixture must contain the medical division this test targets');
    assert.ok(academy, 'fixture must contain the academy division this test targets');

    assert.equal(medical.hidden, false, 'medical starts visible (unfiltered)');
    mod.toggleMachineFilter(M4MINI_HOST);
    assert.equal(medical.hidden, true, 'medical (M4Mini-only in this fixture) must hide once M4Mini is disabled');
    assert.equal(academy.hidden, false, 'academy (has M3Pro cards too) must stay visible');

    mod.toggleMachineFilter(M4MINI_HOST); // re-enable
    assert.equal(medical.hidden, false, 'medical must come back once M4Mini is re-enabled');
});

test('an organization panel hides once every division inside it is hidden', () => {
    const fixture = loadFixture();

    const { mod, freshRenderPass } = setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    const { divisionsContainer } = freshRenderPass(fixture.fleet.divisions);

    const orgPanels = divisionsContainer.querySelectorAll('.organization-panel');
    assert.ok(orgPanels.length > 0, 'must render at least one organization panel');

    // Find the org panel that actually contains div-medical (structural
    // lookup, not a hardcoded org id -- robust to lcars-org-resolution.js's
    // exact grouping, which this file does not otherwise assert on).
    const medicalOrg = orgPanels.filter((org) =>
        org.querySelectorAll('.division-container').some((d) => d.id === 'div-medical')
    )[0];
    assert.ok(medicalOrg, 'exactly one organization panel must contain the medical division');

    const otherDivisionsInThatOrg = medicalOrg.querySelectorAll('.division-container').filter((d) => d.id !== 'div-medical');

    assert.equal(medicalOrg.hidden, false, 'starts visible (unfiltered)');
    mod.toggleMachineFilter(M4MINI_HOST);

    if (otherDivisionsInThatOrg.length === 0) {
        // medical is the only division in its org -- disabling its only
        // host must hide the whole org panel.
        assert.equal(medicalOrg.hidden, true, 'an org panel whose only division just emptied must hide too');
    } else {
        // A future fixture/org-resolution change could group other
        // divisions alongside medical; either way the invariant being
        // tested is "hidden iff every division inside is hidden", not a
        // specific org membership.
        const allHidden = otherDivisionsInThatOrg.every((d) => d.hidden);
        assert.equal(medicalOrg.hidden, allHidden, 'org panel hidden state must track whether ALL its divisions are hidden');
    }
});

// ============================================================================
// Subitem 006 -- division avatar-grid: one avatar per HOST a team is
// attributed to (not just sessions[0]), filtered the same way as cards.
// ============================================================================

test('createDivisionAvatarGrid: a dual-homed team gets one avatar per host, filtered independently per host', () => {
    const fixture = loadFixture();
    // finance/lcars in this fixture has REAL sessions (not just
    // lcars_service) on BOTH hosts -- confirmed against the fixture during
    // development -- so it is a genuine two-avatar case, not a
    // service-only entry (which correctly gets NO avatar; see the
    // createDivisionAvatarGrid comment on why).
    const financeProjects = fixture.fleet.divisions.finance.projects;
    const financeProjectKey = Object.getOwnPropertyNames(financeProjects)[0];
    const financeLcars = financeProjects[financeProjectKey].teams.lcars;
    const financeHosts = new Set((financeLcars.sessions || []).map((s) => s.hostname));
    assert.ok(financeHosts.has(M3PRO_HOST) && financeHosts.has(M4MINI_HOST), 'fixture assumption: finance/lcars has real sessions on both hosts');

    const { mod, freshRenderPass } = setupDashboard();
    mod.setCachedMachineData(fixture.fleet.machines);
    mod.setTeamConfig({ teams: { finance: { terminals: { lcars: { avatar: 'lcars' } } } } });
    mod.setDivisionToTeamMap({ finance: 'finance' });
    const { divisionsContainer } = freshRenderPass(fixture.fleet.divisions);

    const avatars = divisionsContainer.querySelectorAll('.org-avatar-thumb[data-machine-host]');
    assert.equal(avatars.length, 2, 'finance/lcars must produce exactly one avatar per host (2), not one for sessions[0] only');

    const byHost = {};
    avatars.forEach((a) => { byHost[a.dataset.machineHost] = a; });
    assert.ok(byHost[M3PRO_HOST] && byHost[M4MINI_HOST], 'both hosts must be represented');
    assert.equal(byHost[M3PRO_HOST].hidden, false);
    assert.equal(byHost[M4MINI_HOST].hidden, false);

    mod.toggleMachineFilter(M4MINI_HOST);
    assert.equal(byHost[M3PRO_HOST].hidden, false, 'the M3Pro avatar must stay visible');
    assert.equal(byHost[M4MINI_HOST].hidden, true, 'only the M4Mini avatar must hide');

    mod.toggleMachineFilter(M4MINI_HOST);
    assert.equal(byHost[M4MINI_HOST].hidden, false, 'must come back once re-enabled');
});

// ============================================================================
// Kiosk fix (subitem 006) -- static text check only. lcars-kiosk.js is a
// third IIFE this harness does not load (its ORGS auto-scroll depends on
// setInterval/window timers this stub does not model, and loading it just
// to assert a selector string would add a large amount of unrelated stub
// surface for a check that is really about the literal query text). This
// guards specifically against a future accidental revert of the
// :not([hidden]) exclusion at BOTH call sites named in the ticket.
// ============================================================================

test('lcars-kiosk.js startOrgsAutoScroll: both organization-panel queries exclude [hidden] panels', () => {
    const src = fs.readFileSync(path.join(PUBLIC_ROOT, KIOSK_REL_PATH), 'utf8');

    const filtered = src.match(/#divisions-container \.organization-panel:not\(\[hidden\]\)/g) || [];
    assert.equal(filtered.length, 2, 'expected exactly 2 occurrences: startOrgsAutoScroll\'s initial query and its setInterval re-query');

    // stopOrgsAutoScroll's cleanup query (strips the scroll-highlight class
    // from every panel) is DELIBERATELY left unfiltered -- ticket scope was
    // only the two auto-scroll TARGETING queries named above, not this
    // teardown sweep. So exactly ONE plain (non-:not) occurrence must
    // remain, not zero -- a stray extra one would mean a THIRD targeting
    // site crept in unfixed; zero would mean this test's own expectation
    // about stopOrgsAutoScroll's scope is stale.
    const unfiltered = src.match(/document\.querySelectorAll\('#divisions-container \.organization-panel'\)/g) || [];
    assert.equal(unfiltered.length, 1, 'expected exactly 1 remaining plain query: stopOrgsAutoScroll\'s cleanup sweep, unchanged by design');
});

// ============================================================================
// XACA-1062 -- offline/warning machines show STATUS · last-known
// session_count instead of a bare (always-zero) rendered-card count; online
// machines are unchanged. Covers plan-doc verification-checklist items not
// already exercised above: warning-is-not-offline, singular vs plural
// stat/aria-label text, aria-label status conveyance for both online and
// non-online, poll-to-poll stability, fail-closed on an unrecognized/missing
// status, and agreement between the two call sites (renderMachineFilterNav()'s
// first paint and updateMachineNavStats()'s per-pass refresh). · below is
// U+00B7 MIDDLE DOT -- the exact separator machineNavStatText() emits, not a
// lookalike hyphen/bullet.
// ============================================================================

// Clones fixture.fleet.machines so a test can mutate one entry's
// status/session_count without perturbing another test's independent
// loadFixture() read of the same on-disk fixture -- same pattern the
// existing XSS test above (`JSON.parse(JSON.stringify(fixture.fleet.machines))`)
// already uses for the identical reason.
function cloneMachines(fixture) {
    return JSON.parse(JSON.stringify(fixture.fleet.machines));
}

test('a "warning" machine shows WARNING · <last-known session_count>, never collapsed into OFFLINE', () => {
    const fixture = loadFixture();
    const machines = cloneMachines(fixture);
    const m1pro = machines.find((m) => m.hostname === M1PRO_HOST);
    m1pro.status = 'warning';
    m1pro.session_count = 44;

    const { mod, freshRenderPass } = setupDashboard();
    mod.setCachedMachineData(machines);
    const { machineNav } = freshRenderPass(fixture.fleet.divisions);

    const btn = machineNav.querySelectorAll('.machine-nav-button[data-machine-host]').filter((b) => b.dataset.machineHost === M1PRO_HOST)[0];
    assert.ok(btn, 'M1Pro\'s button must still render');
    assert.ok(btn.className.indexOf('status-warning') !== -1, 'must carry status-warning');
    assert.ok(btn.className.indexOf('status-offline') === -1, 'must NOT also carry status-offline');
    assert.equal(btn.querySelector('.machine-nav-stats').textContent, 'WARNING · 44', 'a warning machine\'s stat line must read WARNING, not OFFLINE');
    assert.equal(btn.getAttribute('aria-label'), 'Toggle team cards for M1Pro (Warning, last known 44 sessions)');
});

// XACA-1062-012 regression: session_count is coerced IDENTICALLY at both
// call sites, so the "these two sites cannot disagree" invariant is
// structural rather than contingent on the server always emitting a number.
//
// Why this test calls the two sites SEPARATELY instead of doing a normal
// render pass: updateMachineNavStats() runs at the tail of every render pass
// and OVERWRITES what renderMachineFilterNav() wrote, so after a full pass
// site 2 always wins and a divergence is invisible. It becomes visible when
// site 2 does NOT run -- which is exactly what happens on renderDivisions()'s
// early-exit paths (they return before applyMachineFilter()), and #machine-nav
// is a sibling OUTSIDE #divisions-container, so those buttons survive the
// early exit still showing site 1's text. Driving each site directly is the
// only way to assert the two agree rather than asserting that the later one
// ran last.
//
// Teeth: with Number() removed from site 1, the string '1' makes site 1 emit
// 'last known 1 sessions' (because '1' === 1 is false) while site 2 emits
// 'last known 1 session'. Reverting the coercion fails this test.
test('XACA-1062-012: a STRING session_count renders identically at both call sites (render vs. stats-refresh)', () => {
    const fixture = loadFixture();
    const machines = cloneMachines(fixture);
    const m1mini = machines.find((m) => m.hostname === M1MINI_HOST);
    m1mini.status = 'offline';
    m1mini.session_count = '1'; // STRING, not number -- the provenance this module does not control

    const { ctx, mod } = setupDashboard();
    const machineNav = ctx.document.createElement('div');
    const divisionsContainer = ctx.document.createElement('div');
    ctx.document.__registerById('machine-nav', machineNav);
    ctx.document.__registerById('divisions-container', divisionsContainer);

    // Site 1 in isolation.
    mod.renderMachineFilterNav(machines);
    const btn = machineNav.querySelectorAll('.machine-nav-button[data-machine-host]')
        .filter((b) => b.dataset.machineHost === M1MINI_HOST)[0];
    assert.ok(btn, 'M1Mini\'s button must render');
    const site1Stat = btn.querySelector('.machine-nav-stats').textContent;
    const site1Aria = btn.getAttribute('aria-label');

    // Site 2 in isolation, over the same button.
    mod.updateMachineNavStats();
    const site2Stat = btn.querySelector('.machine-nav-stats').textContent;
    const site2Aria = btn.getAttribute('aria-label');

    assert.equal(site1Stat, site2Stat, 'stat text must be identical at both call sites for a string session_count');
    assert.equal(site1Aria, site2Aria, 'aria-label must be identical at both call sites for a string session_count');
    assert.equal(site1Stat, 'OFFLINE \u00b7 1', 'string \'1\' must render as OFFLINE \u00b7 1');
    assert.equal(site1Aria, 'Toggle team cards for M1Mini (Offline, last known 1 session)',
        'string \'1\' must pluralise as SINGULAR at both sites -- the latent aria bug the coercion closes');
});

// XACA-1062-012 regression, garbage arm: a non-numeric session_count must
// floor to 0 at BOTH sites rather than being interpolated verbatim into
// user-visible text ('OFFLINE \u00b7 abc').
test('XACA-1062-012: a non-numeric session_count floors to 0 identically at both call sites', () => {
    const fixture = loadFixture();
    const machines = cloneMachines(fixture);
    const m1mini = machines.find((m) => m.hostname === M1MINI_HOST);
    m1mini.status = 'offline';
    m1mini.session_count = 'abc';

    const { ctx, mod } = setupDashboard();
    const machineNav = ctx.document.createElement('div');
    const divisionsContainer = ctx.document.createElement('div');
    ctx.document.__registerById('machine-nav', machineNav);
    ctx.document.__registerById('divisions-container', divisionsContainer);

    mod.renderMachineFilterNav(machines);
    const btn = machineNav.querySelectorAll('.machine-nav-button[data-machine-host]')
        .filter((b) => b.dataset.machineHost === M1MINI_HOST)[0];
    const site1Stat = btn.querySelector('.machine-nav-stats').textContent;
    mod.updateMachineNavStats();
    const site2Stat = btn.querySelector('.machine-nav-stats').textContent;

    assert.equal(site1Stat, site2Stat, 'garbage session_count must render identically at both sites');
    assert.equal(site1Stat, 'OFFLINE \u00b7 0', 'non-numeric session_count must floor to 0, never interpolate verbatim');
});

test('singular last-known session count: aria-label says "1 session", not "1 sessions"', () => {
    const fixture = loadFixture();
    const machines = cloneMachines(fixture);
    const m1mini = machines.find((m) => m.hostname === M1MINI_HOST);
    m1mini.session_count = 1; // stays 'offline'

    const { mod, freshRenderPass } = setupDashboard();
    mod.setCachedMachineData(machines);
    const { machineNav } = freshRenderPass(fixture.fleet.divisions);

    const btn = machineNav.querySelectorAll('.machine-nav-button[data-machine-host]').filter((b) => b.dataset.machineHost === M1MINI_HOST)[0];
    assert.equal(btn.querySelector('.machine-nav-stats').textContent, 'OFFLINE · 1');
    assert.equal(btn.getAttribute('aria-label'), 'Toggle team cards for M1Mini (Offline, last known 1 session)', 'singular "session", not "1 sessions"');
});

test('an online machine with exactly one rendered card shows "1 Team" (singular), aria-label conveys Online', () => {
    // A minimal, hand-built single-team/single-host fixture -- none of this
    // suite's real fixture hosts happen to have exactly 1 card, and the
    // singular-vs-plural branch is otherwise unexercised. Schema mirrors
    // tests/xaca-1002-001-registered-team-buckets.test.js's minimal
    // divisions literals. Hostname deliberately does NOT match `.ts.net`
    // (tests/test-xaca-0979-lcars-link-host-guard.sh forbids that pattern
    // anywhere in a fleet-monitor .js file, comments included, with no
    // allow-list) -- a synthetic non-tailnet-shaped name sidesteps it
    // entirely rather than needing an exemption.
    const SYNTHETIC_HOST = 'synthetic-single-card-host';
    const divisions = {
        academy: {
            name: 'academy',
            total_sessions: 1,
            projects: {
                _default: {
                    name: null,
                    teams: {
                        engineering: {
                            name: 'engineering',
                            sessions: [{ name: 'academy-engineering', division: 'academy', hostname: SYNTHETIC_HOST, machine_status: 'online' }]
                        }
                    }
                }
            }
        }
    };
    const machines = [{ hostname: SYNTHETIC_HOST, nickname: 'SyntheticOne', status: 'online', session_count: 1 }];

    const { mod, freshRenderPass } = setupDashboard();
    mod.setCachedMachineData(machines);
    const { machineNav, divisionsContainer } = freshRenderPass(divisions);

    const cards = divisionsContainer.querySelectorAll('.team-card[data-machine-host]');
    assert.equal(cards.length, 1, 'sanity: exactly one card must render for this synthetic single-team fixture');

    const btn = machineNav.querySelectorAll('.machine-nav-button[data-machine-host]')[0];
    assert.equal(btn.querySelector('.machine-nav-stats').textContent, '1 Team', 'singular "Team", not "1 Teams"');
    assert.equal(btn.getAttribute('aria-label'), 'Toggle team cards for SyntheticOne (Online)');
});

test('fail-closed: an unrecognized or entirely missing status is treated as Offline, never as Online', () => {
    const fixture = loadFixture();

    // Variant 1: status is a value this build does not recognize.
    const machinesUnknown = cloneMachines(fixture);
    const m1 = machinesUnknown.find((m) => m.hostname === M1MINI_HOST);
    m1.status = 'rebooting'; // not 'online', not 'warning' -- must fall back to Offline
    m1.session_count = 7;

    const { mod: modA, freshRenderPass: freshA } = setupDashboard();
    modA.setCachedMachineData(machinesUnknown);
    const { machineNav: navA } = freshA(fixture.fleet.divisions);
    const btnA = navA.querySelectorAll('.machine-nav-button[data-machine-host]').filter((b) => b.dataset.machineHost === M1MINI_HOST)[0];
    assert.equal(btnA.querySelector('.machine-nav-stats').textContent, 'OFFLINE · 7', 'an unrecognized status word must still read as OFFLINE, not be echoed verbatim or treated as online');
    assert.ok(btnA.getAttribute('aria-label').indexOf('(Offline, last known 7 sessions)') !== -1, 'aria-label must also fail closed to Offline');

    // Variant 2: status field entirely absent.
    const machinesMissing = cloneMachines(fixture);
    const m2 = machinesMissing.find((m) => m.hostname === M1PRO_HOST);
    delete m2.status;
    m2.session_count = 3;

    const { mod: modB, freshRenderPass: freshB } = setupDashboard();
    modB.setCachedMachineData(machinesMissing);
    const { machineNav: navB } = freshB(fixture.fleet.divisions);
    const btnB = navB.querySelectorAll('.machine-nav-button[data-machine-host]').filter((b) => b.dataset.machineHost === M1PRO_HOST)[0];
    assert.ok(btnB.className.indexOf('status-offline') !== -1, 'a missing status must be normalized to offline for the CSS class too');
    assert.equal(btnB.querySelector('.machine-nav-stats').textContent, 'OFFLINE · 3', 'a missing status must still show OFFLINE, not crash or read blank');
});

test('renderMachineFilterNav()\'s first-paint stat/aria-label for a non-online machine already agrees with updateMachineNavStats()\'s post-filter refresh', () => {
    const fixture = loadFixture();
    const machines = cloneMachines(fixture);
    const m1pro = machines.find((m) => m.hostname === M1PRO_HOST);
    m1pro.status = 'warning';
    m1pro.session_count = 44;

    // Site #1 in isolation: call renderMachineFilterNav() directly against a
    // bare container, exactly as renderDivisions() does BEFORE any team
    // cards exist for the pass (cardCount is unreachable at this call site --
    // see the source comment on its navStats.textContent assignment).
    const { ctx, mod } = setupDashboard();
    const firstPaintNav = ctx.document.createElement('div');
    ctx.document.__registerById('machine-nav', firstPaintNav);
    mod.renderMachineFilterNav(machines);
    const firstPaintBtn = firstPaintNav.querySelectorAll('.machine-nav-button[data-machine-host]').filter((b) => b.dataset.machineHost === M1PRO_HOST)[0];
    const firstPaintText = firstPaintBtn.querySelector('.machine-nav-stats').textContent;
    const firstPaintAria = firstPaintBtn.getAttribute('aria-label');

    // Site #2, the real production sequence: renderDivisions() ->
    // renderMachineFilterNav() -> applyMachineFilter() -> updateMachineNavStats().
    const { mod: mod2, freshRenderPass } = setupDashboard();
    mod2.setCachedMachineData(machines);
    const { machineNav: finalNav } = freshRenderPass(fixture.fleet.divisions);
    const finalBtn = finalNav.querySelectorAll('.machine-nav-button[data-machine-host]').filter((b) => b.dataset.machineHost === M1PRO_HOST)[0];
    const finalText = finalBtn.querySelector('.machine-nav-stats').textContent;
    const finalAria = finalBtn.getAttribute('aria-label');

    assert.equal(firstPaintText, 'WARNING · 44', 'sanity: first paint must already carry the real text for a non-online machine (cardCount is irrelevant to it, so there is no placeholder gap)');
    assert.equal(firstPaintText, finalText, 'renderMachineFilterNav() and updateMachineNavStats() must never disagree on stat text for the same machine data');
    assert.equal(firstPaintAria, finalAria, 'the two call sites must never disagree on aria-label either');
});

test('a non-online machine\'s stat text survives multiple full renderDivisions() re-renders unchanged (no drift back to a placeholder)', () => {
    const fixture = loadFixture();
    const machines = cloneMachines(fixture);
    const m1pro = machines.find((m) => m.hostname === M1PRO_HOST);
    m1pro.status = 'warning';
    m1pro.session_count = 44;

    const { mod, freshRenderPass } = setupDashboard();
    mod.setCachedMachineData(machines);

    function statTextFor(nav) {
        const btn = nav.querySelectorAll('.machine-nav-button[data-machine-host]').filter((b) => b.dataset.machineHost === M1PRO_HOST)[0];
        return btn.querySelector('.machine-nav-stats').textContent;
    }

    const { machineNav: nav1 } = freshRenderPass(fixture.fleet.divisions); // poll #1
    const text1 = statTextFor(nav1);
    assert.equal(text1, 'WARNING · 44', 'poll #1 must already carry the real text');

    const { machineNav: nav2 } = freshRenderPass(fixture.fleet.divisions); // poll #2
    assert.equal(statTextFor(nav2), text1, 'poll #2 must not have drifted from poll #1\'s text');

    const { machineNav: nav3 } = freshRenderPass(fixture.fleet.divisions); // poll #3, for good measure
    assert.equal(statTextFor(nav3), text1, 'poll #3 must still match');
});

test('toggling a warning machine changes no card visibility, and its own stat text is unaffected by its own toggle state', () => {
    const fixture = loadFixture();
    const machines = cloneMachines(fixture);
    const m1pro = machines.find((m) => m.hostname === M1PRO_HOST);
    m1pro.status = 'warning';
    m1pro.session_count = 44;

    const { mod, freshRenderPass } = setupDashboard();
    mod.setCachedMachineData(machines);
    const { divisionsContainer, machineNav } = freshRenderPass(fixture.fleet.divisions);

    const visibleBefore = divisionsContainer.querySelectorAll('.team-card[data-machine-host]').filter((c) => !c.hidden).length;

    mod.toggleMachineFilter(M1PRO_HOST);

    const visibleAfter = divisionsContainer.querySelectorAll('.team-card[data-machine-host]').filter((c) => !c.hidden).length;
    assert.equal(visibleAfter, visibleBefore, 'disabling a 0-card warning machine must not hide any card');

    const btn = machineNav.querySelectorAll('.machine-nav-button[data-machine-host]').filter((b) => b.dataset.machineHost === M1PRO_HOST)[0];
    assert.ok(btn.classList.contains('disabled'), 'button must still reflect the disabled state');
    assert.equal(btn.querySelector('.machine-nav-stats').textContent, 'WARNING · 44', 'stat text must be unaffected by the machine\'s own toggle state');

    mod.toggleMachineFilter(M1PRO_HOST); // restore
    assert.equal(btn.querySelector('.machine-nav-stats').textContent, 'WARNING · 44', 'still unaffected after re-enabling');
});
