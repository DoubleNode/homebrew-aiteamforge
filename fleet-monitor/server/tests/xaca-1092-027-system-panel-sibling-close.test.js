//
//  xaca-1092-027-system-panel-sibling-close.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1092-027 [Test] -- the QA gate on PR #822 found that the
 * sibling-panel-close transition inside toggleSystemPanel() (all 5
 * renderers) has NO automated coverage: when SYSTEM panel B is opened while
 * panel A is already open, toggleSystemPanel() looks up A's toggle via
 * `document.querySelector('.status-row-system-toggle[data-machine-id="' +
 * CSS.escape(expandedSystemMachineId) + '"]')` (lcars2) / the equivalent
 * `.machine-system-container[data-machine-id="..."]` lookup (v1) and flips
 * its aria-expanded back to "false" as a side effect of opening B.
 *
 * tests/helpers/lcars-client-dom-stub.js's hand-rolled DOM shim cannot
 * exercise this path: `documentStub` has no querySelector() at all, and
 * FakeElement.querySelector() only ever matches a bare `.class` selector
 * against ONE element's own innerHTML string -- it has no notion of a
 * document-wide tree to search, so it cannot resolve an
 * attribute-qualified, cross-element selector like
 * `.status-row-system-toggle[data-machine-id="..."]` naturally.  The gate
 * verified the actual transition manually against real jsdom (opening B
 * correctly flips A's aria-expanded true -> false) -- the CODE IS CORRECT;
 * this file closes the coverage gap rather than the code gap.
 *
 * ── Why jsdom instead of extending the hand-rolled stub ─────────────────
 * A real, document-wide `document.querySelector()` (with attribute-selector
 * matching against elements that were never explicitly registered anywhere)
 * is exactly the kind of "small selector grammar against one element's own
 * innerHTML string" the hand stub deliberately is NOT (see that file's own
 * header comment). Building a second, cross-element index inside the stub
 * to support this one call site would (a) touch code every other suite in
 * this directory depends on for its own, already-passing assertions, and
 * (b) still only be an approximation of `CSS.escape()` + real attribute-
 * selector semantics, which is exactly the part of this path most likely to
 * hide a real defect. jsdom is a real, spec-compliant DOM/CSSOM/Selectors
 * implementation (real `document.querySelector`, real `CSS.escape`, real
 * event dispatch/bubbling) already used for exactly this class of problem
 * by tests/xaca-1031-007-version-badge-ui.test.js and
 * tests/xaca-1060-008-machine-filter-jsdom.test.js -- this file follows
 * their loader discipline (real shipped HTML/JS off disk, patched with an
 * ADDITIVE `window.__lcarsTestExports` tail, `runScripts: 'outside-only'` +
 * wait-for-'load' to dodge the DOMContentLoaded fetch/setInterval hang both
 * of those files document) rather than inventing a third approach.
 *
 * Both machines in every test below are appended into the SAME real
 * document (lcars2: a `#machine-status-list` container; v1: the real
 * `#machines-list` container out of the shipped lcars-dashboard.html) --
 * that is the one fact this whole test class depends on: it is what makes
 * `document.querySelector()` inside the production code able to find "the
 * other" machine's toggle at all, exactly as it would on the real
 * dashboard page.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');
const { CREATE_MACHINE_ITEM_EXPORT_PROPERTY } = require('./helpers/lcars-client-dom-stub');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');

const LCARS2_APP_FILES_ALL = [
    'lcars2/js/lcars-academy-app.js',
    'lcars2/js/lcars-all-app.js',
    'lcars2/js/lcars-doublenode-app.js',
    'lcars2/js/lcars-mainevent-app.js'
];
// lcars-doublenode-app.js is tap-excluded (XACA-0139 debranding) -- same
// existence filter every other suite in this directory uses.
const LCARS2_APP_FILES = LCARS2_APP_FILES_ALL.filter((rel) => fs.existsSync(path.join(PUBLIC_ROOT, rel)));

const RICH_APP_FILE = 'lcars/js/lcars-dashboard-app.js';
const RICH_HTML_FILE = 'lcars/lcars-dashboard.html';

// Two machines, both with fully-populated system{} blocks so
// buildSystemSectionHtml() takes the "real interactive toggle" branch in
// every renderer (never the static no-data line) -- same fixture shape as
// tests/xaca-1092-021-022-ux-mustfix.test.js's interactiveMachine(), with
// a distinct machine_id/hostname/nickname per call so the two machines are
// never mistaken for each other by any selector in this file.
function interactiveMachine(idSuffix) {
    return {
        machine_id: '99999999-8888-4777-8666-55555555' + idSuffix,
        hostname: 'sibling-close-' + idSuffix + '.example.test',
        nickname: 'SiblingClose' + idSuffix,
        ip: '192.0.2.' + idSuffix,
        os: 'Darwin',
        status: 'online',
        first_seen: '2026-01-15T00:00:00.000Z',
        last_seen: '2026-09-04T15:00:00.000Z',
        session_count: 1,
        sessions: [],
        uptime_history: [{ timestamp: '2026-09-04T15:00:00.000Z', status: 'online', session_count: 1 }],
        system: {
            schema_version: 1,
            versions: { aiteamforge: '0.17.9', latest: '0.17.9', outdated: false },
            os_name: 'macOS',
            os_version: '27.0',
            cores: 8,
            memory: { used: 4000000000, total: 8000000000, pressure_percent: 30 },
            swap_used_bytes: 0,
            disk: { used: 100, free: 300, percent: 25 },
            load_average: [1.0, 1.0, 1.0]
        }
    };
}

// Loads one of the 4 lcars2 minimal renderer files into a real jsdom
// document, patched with an additive test-export tail exposing
// createMachineItem onto window.__lcarsTestExports. Mirrors
// tests/xaca-1031-007-version-badge-ui.test.js's setupMinimalApp() exactly
// (including why LCARS_TERMINAL_CARD/LCARS_MACHINE_HEALTH are still not
// preloaded: createMachineItem() only reaches them through guarded
// `typeof`/truthiness checks, never unconditionally, so their absence here
// degrades the (unrelated) health badge to 'unknown' rather than throwing).
// XACA-1100-002 UPDATE: createMachineItem() itself was extracted out of
// these 4 files into window.LCARS_CORE.machines.createMachineItem
// (lcars-fleet-core.js) -- THAT module IS now preloaded below, since the
// export wrapper's fallback branch calls it unconditionally (not through a
// guarded check the way the two modules above are reached).
async function setupMinimalApp(relPath) {
    const dom = new JSDOM('<!doctype html><html><body><div id="machine-status-list"></div></body></html>', {
        url: 'http://lcars-test.local/' + relPath,
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

    const coreSrc = fs.readFileSync(path.join(PUBLIC_ROOT, 'lcars2/js/lcars-fleet-core.js'), 'utf8');
    vm.runInContext(coreSrc, ctx, { filename: 'lcars2/js/lcars-fleet-core.js' });

    const src = fs.readFileSync(path.join(PUBLIC_ROOT, relPath), 'utf8');
    const marker = '})();';
    const lastIdx = src.lastIndexOf(marker);
    if (lastIdx === -1) throw new Error('setupMinimalApp: closing "})();" not found in ' + relPath);
    // createMachineItem is no longer a local function in these 4 files
    // (XACA-1100-002) -- CREATE_MACHINE_ITEM_EXPORT_PROPERTY (XACA-1100-016:
    // hoisted to tests/helpers/lcars-client-dom-stub.js, shared by 5 test
    // harnesses that each used to retype this string) assembles the same
    // `deps` object the real call site builds (see lcars-*-app.js) and
    // forwards to the shared core, so every `mod.createMachineItem(machine)`
    // call in this suite keeps working unchanged.
    const exportStmt = '\n    window.__lcarsTestExports = { ' + CREATE_MACHINE_ITEM_EXPORT_PROPERTY + ' };\n';
    const patched = src.slice(0, lastIdx) + exportStmt + src.slice(lastIdx);
    vm.runInContext(patched, ctx, { filename: relPath });

    const mod = window.__lcarsTestExports;
    if (!mod || typeof mod.createMachineItem !== 'function') {
        throw new Error('setupMinimalApp: createMachineItem export missing from ' + relPath);
    }
    return { window, document, mod };
}

// Loads the REAL shipped lcars-dashboard.html + lcars-dashboard-app.js
// (v1/"rich" renderer) into jsdom, patched the same additive way. Mirrors
// tests/xaca-1060-008-machine-filter-jsdom.test.js's setupDashboard(),
// trimmed to only what createMachineItem() needs -- LCARS_TERMINAL_CARD/
// LCARS_KIOSK/etc. are all reached only through guarded checks or from
// inside the DOMContentLoaded handler this harness never dispatches (same
// wait-for-'load'-before-eval discipline as that file, for the same reason:
// evaluating the app script before jsdom's own queued 'load' event fires
// would let its unconditional `document.addEventListener('DOMContentLoaded',
// ...)` handler catch that event and run its fetch()+setInterval() init
// path, hanging `node --test` forever).
async function setupRichApp() {
    const html = fs.readFileSync(path.join(PUBLIC_ROOT, RICH_HTML_FILE), 'utf8');
    const dom = new JSDOM(html, {
        url: 'http://lcars-test.local/' + RICH_HTML_FILE,
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
    const src = fs.readFileSync(path.join(PUBLIC_ROOT, RICH_APP_FILE), 'utf8');
    const marker = '})();';
    const lastIdx = src.lastIndexOf(marker);
    if (lastIdx === -1) throw new Error('setupRichApp: closing "})();" not found in ' + RICH_APP_FILE);
    const exportStmt = '\n    window.__lcarsTestExports = { createMachineItem: createMachineItem };\n';
    const patched = src.slice(0, lastIdx) + exportStmt + src.slice(lastIdx);
    vm.runInContext(patched, ctx, { filename: RICH_APP_FILE });

    const mod = window.__lcarsTestExports;
    if (!mod || typeof mod.createMachineItem !== 'function') {
        throw new Error('setupRichApp: createMachineItem export missing from ' + RICH_APP_FILE);
    }
    return { window, document, mod };
}

// Real KeyboardEvent dispatch (not a hand-rolled {type,key} object) --
// exercises the exact keydown listener toggleSystemPanel()'s callers
// attach, matching tests/xaca-1092-021-022-ux-mustfix.test.js's own choice
// of Enter/Space as the activation path (its click listener is
// stopPropagation()-guarded and reachable via bubbling too, but keydown is
// the more direct, already-precedented route and avoids relying on
// bubbling semantics this file does not otherwise need).
function pressEnter(window, el) {
    el.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'Enter', keyCode: 13, bubbles: true, cancelable: true }));
}

// ============================================================================
// lcars2: 4 minimal renderers
// ============================================================================

LCARS2_APP_FILES.forEach((relPath) => {
    test(`XACA-1092-027: opening machine B's SYSTEM panel closes machine A's and flips its aria-expanded to false (${relPath})`, async () => {
        const { window, document, mod } = await setupMinimalApp(relPath);
        const container = document.getElementById('machine-status-list');

        const machineA = interactiveMachine('11111111');
        const machineB = interactiveMachine('22222222');

        const fragA = mod.createMachineItem(machineA);
        const detailA = fragA.children[1];
        assert.ok(detailA, 'sanity: machine A must render a .status-row-detail sibling block');
        container.appendChild(fragA);

        const fragB = mod.createMachineItem(machineB);
        const detailB = fragB.children[1];
        assert.ok(detailB, 'sanity: machine B must render a .status-row-detail sibling block');
        container.appendChild(fragB);

        const toggleA = detailA.querySelector('.status-row-system-toggle');
        const panelA = detailA.querySelector('.status-row-system-panel');
        const indicatorA = detailA.querySelector('.status-row-system-indicator');
        const toggleB = detailB.querySelector('.status-row-system-toggle');
        const panelB = detailB.querySelector('.status-row-system-panel');
        const indicatorB = detailB.querySelector('.status-row-system-indicator');
        assert.ok(toggleA && panelA && indicatorA, 'sanity: machine A must render a real interactive SYSTEM toggle/panel/indicator');
        assert.ok(toggleB && panelB && indicatorB, 'sanity: machine B must render a real interactive SYSTEM toggle/panel/indicator');

        // Both start collapsed.
        assert.equal(toggleA.getAttribute('aria-expanded'), 'false');
        assert.equal(toggleB.getAttribute('aria-expanded'), 'false');

        // Open A.
        pressEnter(window, toggleA);
        assert.equal(toggleA.getAttribute('aria-expanded'), 'true', 'A must open');
        assert.ok(panelA.classList.contains('expanded'));
        assert.ok(indicatorA.classList.contains('expanded'));

        // Open B -- must close A as a side effect (the path under test).
        pressEnter(window, toggleB);
        assert.equal(toggleB.getAttribute('aria-expanded'), 'true', 'B must open');
        assert.ok(panelB.classList.contains('expanded'));
        assert.ok(indicatorB.classList.contains('expanded'));

        assert.equal(toggleA.getAttribute('aria-expanded'), 'false', "A's aria-expanded must flip back to false when B opens");
        assert.ok(!panelA.classList.contains('expanded'), "A's panel must lose .expanded when B opens");
        assert.ok(!indicatorA.classList.contains('expanded'), "A's chevron indicator must lose .expanded when B opens");

        // Closing B directly (the "close myself" branch) must not leave A
        // (already closed) in some inconsistent state, and must not
        // resurrect A.
        pressEnter(window, toggleB);
        assert.equal(toggleB.getAttribute('aria-expanded'), 'false', 'B must close on its own second activation');
        assert.ok(!panelB.classList.contains('expanded'));
        assert.equal(toggleA.getAttribute('aria-expanded'), 'false', 'A must remain closed throughout');
    });
});

// ============================================================================
// v1: rich renderer
// ============================================================================

test(`XACA-1092-027: opening machine B's SYSTEM panel closes machine A's and flips its aria-expanded to false (${RICH_APP_FILE})`, async () => {
    const { window, document, mod } = await setupRichApp();
    const container = document.getElementById('machines-list');
    assert.ok(container, 'sanity: the real dashboard.html must contain #machines-list');

    const machineA = interactiveMachine('33333333');
    const machineB = interactiveMachine('44444444');

    const containerA = mod.createMachineItem(machineA);
    const itemA = containerA.children[0];
    assert.ok(itemA, 'sanity: v1 createMachineItem() must return a container whose first child is the machine row');
    container.appendChild(containerA);

    const containerB = mod.createMachineItem(machineB);
    const itemB = containerB.children[0];
    assert.ok(itemB, 'sanity: v1 createMachineItem() must return a container whose first child is the machine row');
    container.appendChild(containerB);

    const toggleA = itemA.querySelector('.machine-system-status');
    const panelA = itemA.querySelector('.machine-system-details-panel');
    const indicatorA = itemA.querySelector('.system-expand-indicator');
    const toggleB = itemB.querySelector('.machine-system-status');
    const panelB = itemB.querySelector('.machine-system-details-panel');
    const indicatorB = itemB.querySelector('.system-expand-indicator');
    assert.ok(toggleA && panelA && indicatorA, 'sanity: machine A must render a real interactive SYSTEM toggle/panel/indicator');
    assert.ok(toggleB && panelB && indicatorB, 'sanity: machine B must render a real interactive SYSTEM toggle/panel/indicator');

    assert.equal(toggleA.getAttribute('aria-expanded'), 'false');
    assert.equal(toggleB.getAttribute('aria-expanded'), 'false');

    pressEnter(window, toggleA);
    assert.equal(toggleA.getAttribute('aria-expanded'), 'true', 'A must open');
    assert.ok(panelA.classList.contains('expanded'));
    assert.ok(indicatorA.classList.contains('expanded'));

    pressEnter(window, toggleB);
    assert.equal(toggleB.getAttribute('aria-expanded'), 'true', 'B must open');
    assert.ok(panelB.classList.contains('expanded'));
    assert.ok(indicatorB.classList.contains('expanded'));

    assert.equal(toggleA.getAttribute('aria-expanded'), 'false', "A's aria-expanded must flip back to false when B opens");
    assert.ok(!panelA.classList.contains('expanded'), "A's panel must lose .expanded when B opens");
    assert.ok(!indicatorA.classList.contains('expanded'), "A's chevron indicator must lose .expanded when B opens");

    pressEnter(window, toggleB);
    assert.equal(toggleB.getAttribute('aria-expanded'), 'false', 'B must close on its own second activation');
    assert.ok(!panelB.classList.contains('expanded'));
    assert.equal(toggleA.getAttribute('aria-expanded'), 'false', 'A must remain closed throughout');
});
