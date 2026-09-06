//
//  xaca-1100-013-render-machines-expand-survives-refresh.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1100-013 [Review] -- the `deps` object each of the 4 lcars2 minimal
 * renderers assembles at its REAL renderMachines() call site
 * (window.LCARS_CORE.machines.createMachineItem(machine, { ... })) was
 * completely untested. Every existing suite that exercises createMachineItem
 * (xaca-1031-007/-015-016-017/-018, xaca-1092-006/-021-022/-027) calls
 * `mod.createMachineItem(machine)` directly and lets a test-harness WRAPPER
 * (tests/helpers/lcars-client-dom-stub.js's CREATE_MACHINE_ITEM_EXPORT_PROPERTY,
 * XACA-1100-016) reconstruct its own `deps` object rather than going through
 * renderMachines() itself. The PR #826 review round proved that gap with a
 * mutation: changing the real call site's
 * `isSystemExpanded: expandedSystemMachineId === machine.machine_id` to a
 * hardcoded `isSystemExpanded: false`, IDENTICALLY across all four call
 * sites (they are byte-identical -- see
 * tests/xaca-1031-015-016-017-ux-followups.test.js's cross-file
 * byte-identity test), passed the entire suite. Nothing caught it, because
 * nothing tests the wiring at the call site -- only the reconstructed
 * harness deps, and the harness's own fallback always supplies a CORRECT
 * `isSystemExpanded`, never the mutated one.
 *
 * That mutation is not academic: it reintroduces the exact regression
 * XACA-1092-027/XACA-1092-005 exist to prevent -- lcars-*-app.js:39's own
 * comment says expandedSystemMachineId is deliberately a string (not an
 * element reference) "so expand state survives renderMachines() rebuilding
 * the list every refresh tick". A hardcoded `isSystemExpanded: false` means
 * every SYSTEM panel silently collapses on the very next refresh tick after
 * a user opens one -- exactly the failure mode this whole call-site
 * indirection was built to avoid.
 *
 * ── What this file does differently from every other createMachineItem
 * suite in this directory ──────────────────────────────────────────────
 * It calls the REAL production entry point, `renderMachines()` -- exported
 * from the real shipped app file, not reconstructed -- and drives the exact
 * sequence the regression depends on:
 *   1. renderMachines([machine])                    -- first render, collapsed
 *   2. click the real SYSTEM toggle                 -- opens it (real
 *                                                       toggleSystemPanel(),
 *                                                       wired by the real
 *                                                       click listener
 *                                                       createMachineItem()
 *                                                       attaches)
 *   3. renderMachines([machine]) AGAIN               -- the "refresh tick"
 *                                                       lcars-*-app.js:39
 *                                                       describes; rebuilds
 *                                                       #machines-list from
 *                                                       scratch
 *   4. assert the freshly-rebuilt toggle/indicator/panel are STILL expanded
 *
 * Step 4 is exactly what a reconstructed-deps test structurally cannot
 * observe: reconstructing `deps` in the test (as every prior suite does) is
 * what created this blind spot in the first place, because the
 * reconstruction always builds a CORRECT deps object -- it can never
 * exercise whatever the real call site actually wires in.
 *
 * ── Method ────────────────────────────────────────────────────────────
 * Same jsdom "run outside-only, wait for the real load event, patch an
 * ADDITIVE window.__lcarsTestExports tail before the closing IIFE" recipe
 * as tests/xaca-1092-027-system-panel-sibling-close.test.js, with two
 * differences: (a) this file exports `renderMachines` itself (a real,
 * always-defined local function in all 4 lcars2 files -- no typeof guard
 * needed, unlike createMachineItem which only 1 of 5 files still defines
 * locally) instead of reconstructing a `deps`-assembly wrapper, and (b) the
 * container id is `machines-list` (the real id renderMachines() looks up
 * via document.getElementById), not `machine-status-list`.
 *
 * The MUTATION KILL group below reproduces the reviewer's exact finding:
 * it mutates the real call-site source text in-memory (never touching the
 * file on disk) and proves the positive test above would fail against it,
 * for both the value-mutation the reviewer used (isSystemExpanded: false)
 * and a second, distinct dropped-key mutation (the isSystemExpanded line
 * removed from the object literal entirely -- `deps.isSystemExpanded` then
 * reads `undefined`, coerced the same way by createMachineItem's `!!`, but
 * exercising a different kind of call-site defect: an omitted wire, not a
 * wrong value).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');

// XACA-1110-005/-009: the 4 former lcars2 app files collapsed into ONE
// config-parameterized module -- re-pointed at that module, parameterized
// over the 4 per-org configs instead of 4 files, so the same 4 behavioral
// variants keep being exercised (this suite's renderMachines()/
// isSystemExpanded call-site wiring does not actually depend on CONFIG,
// but every other lcars2 suite in this directory follows this same shape,
// and dropping to a single un-parameterized case would silently narrow
// coverage relative to before unification).
const UNIFIED_MODULE_REL_PATH = 'lcars2/js/lcars-fleet-dashboard-app.js';
const LCARS2_APP_TARGETS_ALL = [
    { label: 'academy', relPath: UNIFIED_MODULE_REL_PATH, configRelPath: 'lcars2/js/lcars-academy-config.js' },
    { label: 'doublenode', relPath: UNIFIED_MODULE_REL_PATH, configRelPath: 'lcars2/js/lcars-doublenode-config.js' },
    { label: 'mainevent', relPath: UNIFIED_MODULE_REL_PATH, configRelPath: 'lcars2/js/lcars-mainevent-config.js' },
    { label: 'all', relPath: UNIFIED_MODULE_REL_PATH, configRelPath: 'lcars2/js/lcars-all-config.js' }
];
// doublenode/mainevent configs are tap-excluded (XACA-0139 debranding) --
// same existence filter every other suite in this directory uses, now
// applied to the CONFIG file rather than the (identical-everywhere) app
// file.
function loadConfigGlobalForTest(relPath) {
    const sandbox = { window: {} };
    vm.createContext(sandbox);
    vm.runInContext(fs.readFileSync(path.join(PUBLIC_ROOT, relPath), 'utf8'), sandbox, { filename: relPath });
    return sandbox.window.LCARS_DASHBOARD_CONFIG;
}
const LCARS2_APP_FILES = LCARS2_APP_TARGETS_ALL
    .filter((t) => fs.existsSync(path.join(PUBLIC_ROOT, t.configRelPath)))
    .map((t) => Object.assign({}, t, { configGlobal: loadConfigGlobalForTest(t.configRelPath) }));

// A machine with a fully-populated system{} block so buildSystemSectionHtml()
// takes the "real interactive toggle" branch (never the static no-data
// line) -- same fixture shape as
// tests/xaca-1092-021-022-ux-mustfix.test.js's interactiveMachine() and
// tests/xaca-1092-027-system-panel-sibling-close.test.js's own copy.
function interactiveMachine() {
    return {
        machine_id: '99999999-8888-4777-8666-555555550013',
        hostname: 'expand-survives-refresh.example.test',
        nickname: 'ExpandSurvivesRefresh',
        ip: '192.0.2.13',
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
// document with the REAL #machines-list container id renderMachines()
// looks up, patched with an additive test-export tail exposing
// renderMachines() itself -- not a reconstructed deps wrapper (see file
// header: reconstructing deps is the blind spot this file exists to close).
// `srcOverride`, when given, replaces the on-disk source with an in-memory
// mutated copy (used by the MUTATION KILL group below) -- same optional
// param shape as tests/xaca-1031-018-version-aria-label.test.js's
// setupApp().
async function setupApp(target, srcOverride) {
    const relPath = target.relPath;
    const dom = new JSDOM('<!doctype html><html><body><div id="machines-list"></div></body></html>', {
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

    if (target.configGlobal) {
        window.LCARS_DASHBOARD_CONFIG = target.configGlobal;
    }

    // The real shipped core, unmodified -- this file's mutations are always
    // to the APP file's call site, never to the core's createMachineItem().
    const coreSrc = fs.readFileSync(path.join(PUBLIC_ROOT, 'lcars2/js/lcars-fleet-core.js'), 'utf8');
    vm.runInContext(coreSrc, ctx, { filename: 'lcars2/js/lcars-fleet-core.js' });

    const src = srcOverride !== undefined ? srcOverride : fs.readFileSync(path.join(PUBLIC_ROOT, relPath), 'utf8');
    const marker = '})();';
    const lastIdx = src.lastIndexOf(marker);
    if (lastIdx === -1) throw new Error('setupApp: closing "})();" not found in ' + relPath);
    // renderMachines is a real, always-defined local function in all 4
    // lcars2 files -- no typeof guard needed (unlike createMachineItem,
    // which only 1 of 5 files still defines locally).
    const exportStmt = '\n    window.__lcarsTestExports = { renderMachines: renderMachines };\n';
    const patched = src.slice(0, lastIdx) + exportStmt + src.slice(lastIdx);
    vm.runInContext(patched, ctx, { filename: relPath });

    const mod = window.__lcarsTestExports;
    if (!mod || typeof mod.renderMachines !== 'function') {
        throw new Error('setupApp: renderMachines export missing from ' + relPath);
    }
    return { window, document, mod };
}

// Finds the SYSTEM toggle for `machineId` inside `container` and returns the
// three elements the expand/collapse state lives on, per
// buildSystemSectionHtml()/toggleSystemPanel()'s own DOM shape.
function findSystemElements(window, container, machineId) {
    const toggle = container.querySelector('.status-row-system-toggle[data-machine-id="' + window.CSS.escape(machineId) + '"]');
    const detail = toggle ? toggle.parentElement : null;
    const indicator = toggle ? toggle.querySelector('.status-row-system-indicator') : null;
    const panel = detail ? detail.querySelector('.status-row-system-panel') : null;
    return { toggle, indicator, panel };
}

function isExpanded(els) {
    return !!(
        els.toggle && els.toggle.getAttribute('aria-expanded') === 'true' &&
        els.indicator && els.indicator.classList.contains('expanded') &&
        els.panel && els.panel.classList.contains('expanded')
    );
}

// Runs the full regression scenario against one already-loaded app module
// and returns whether the SYSTEM panel was still expanded after the SECOND
// renderMachines() call (the "refresh tick" rebuild).
function runExpandSurvivesRefreshScenario(window, document, mod, machine) {
    mod.renderMachines([machine]);
    const container = document.getElementById('machines-list');

    const beforeClick = findSystemElements(window, container, machine.machine_id);
    assert.ok(beforeClick.toggle, 'sanity: interactiveMachine() must produce a real SYSTEM toggle on first render');
    assert.equal(isExpanded(beforeClick), false, 'sanity: SYSTEM panel must start collapsed');

    // Real click dispatch -- exercises the real click listener
    // createMachineItem() attaches, which calls the real toggleSystemPanel().
    beforeClick.toggle.dispatchEvent(new window.MouseEvent('click', { bubbles: true, cancelable: true }));

    const afterClick = findSystemElements(window, container, machine.machine_id);
    assert.equal(isExpanded(afterClick), true, 'sanity: clicking the toggle must expand the panel before any refresh happens');

    // The refresh tick: renderMachines() is called again with the SAME
    // machine data, rebuilding #machines-list from scratch (container.innerHTML
    // = '' inside renderMachines(), then every machine re-rendered). This is
    // the exact call lcars-*-app.js:39's comment describes recurring "every
    // refresh tick".
    mod.renderMachines([machine]);
    const afterRefresh = findSystemElements(window, container, machine.machine_id);
    return isExpanded(afterRefresh);
}

// ============================================================================
// POSITIVE: real call site, real toggle click, real second render.
// ============================================================================

LCARS2_APP_FILES.forEach((target) => {
    test(`XACA-1100-013: renderMachines() wires isSystemExpanded so an opened SYSTEM panel survives a refresh-tick re-render (${target.label}: ${target.relPath})`, async () => {
        const { window, document, mod } = await setupApp(target);
        const survived = runExpandSurvivesRefreshScenario(window, document, mod, interactiveMachine());
        assert.equal(survived, true,
            'the SYSTEM panel opened by a real click must still show expanded (aria-expanded="true" plus both .expanded classes) ' +
            'after renderMachines() rebuilds the list -- if this fails, the real call site\'s ' +
            'isSystemExpanded: expandedSystemMachineId === machine.machine_id wiring is broken');
    });
});

// ============================================================================
// MUTATION KILL -- proves the positive tests above are load-bearing by
// applying the reviewer's exact mutation (and a second, distinct one) to the
// real call-site source text IN-MEMORY, then re-running the identical
// scenario and asserting the regression manifests. Loops over all 4 files,
// matching the reviewer's finding that the mutation was applied
// "consistently across all four call sites".
// ============================================================================

const CALL_SITE_NEEDLE = 'isSystemExpanded: expandedSystemMachineId === machine.machine_id';

LCARS2_APP_FILES.forEach((target) => {
    test(`XACA-1100-013 mutation kill (value), ${target.label}: ${target.relPath}: hardcoding isSystemExpanded: false at the call site makes the SYSTEM panel collapse on refresh (proves the positive test above is load-bearing)`, async () => {
        const realSrc = fs.readFileSync(path.join(PUBLIC_ROOT, target.relPath), 'utf8');
        assert.ok(realSrc.includes(CALL_SITE_NEEDLE),
            'mutation setup: expected to find the exact isSystemExpanded call-site wiring in the real source -- ' +
            'if this fails, the source shape changed and the mutation string needs updating');
        const mutatedSrc = realSrc.replace(CALL_SITE_NEEDLE, 'isSystemExpanded: false');
        assert.notEqual(mutatedSrc, realSrc);

        const { window, document, mod } = await setupApp(target, mutatedSrc);
        const survived = runExpandSurvivesRefreshScenario(window, document, mod, interactiveMachine());
        assert.equal(survived, false,
            'expected the value-mutated call site (isSystemExpanded: false) to fail to preserve expand state across a ' +
            'refresh -- if this now passes, the mutation stopped being effective and this kill test needs review');
    });

    test(`XACA-1100-013 mutation kill (dropped key), ${target.label}: ${target.relPath}: removing the isSystemExpanded key from the call site entirely also makes the SYSTEM panel collapse on refresh`, async () => {
        const realSrc = fs.readFileSync(path.join(PUBLIC_ROOT, target.relPath), 'utf8');
        // Drop the whole line, including its preceding comma, so the object
        // literal stays syntactically valid with 4 keys instead of 5 -- an
        // OMITTED wire, not merely a wrong value.
        const droppedKeyNeedle = ',\n                ' + CALL_SITE_NEEDLE;
        assert.ok(realSrc.includes(droppedKeyNeedle),
            'mutation setup: expected to find the isSystemExpanded call-site line (with its preceding comma) in the real source');
        const mutatedSrc = realSrc.replace(droppedKeyNeedle, '');
        assert.notEqual(mutatedSrc, realSrc);
        assert.ok(!mutatedSrc.includes('isSystemExpanded'), 'mutation setup: isSystemExpanded must be entirely absent from the call site after this mutation');

        const { window, document, mod } = await setupApp(target, mutatedSrc);
        const survived = runExpandSurvivesRefreshScenario(window, document, mod, interactiveMachine());
        assert.equal(survived, false,
            'expected the dropped-key call site (no isSystemExpanded property at all -> deps.isSystemExpanded reads ' +
            'undefined -> !!undefined === false) to fail to preserve expand state across a refresh');
    });
});
