//
//  xaca-1100-022-guard-hoisted-single-error.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1100-022 [Review] -- the `window.LCARS_CORE.machines` guard inside
 * each lcars2 minimal renderer's `renderMachines()` used to live INSIDE
 * `sortedMachines.forEach(...)`, re-evaluating (and, on failure,
 * re-logging) once PER MACHINE on every refresh tick -- roughly 120
 * identical `console.error` calls/min for a ten-machine fleet on the 5s
 * poll, burying every other diagnostic. On failure it also left
 * `#machines-list` completely blank, which an operator reads as "no
 * machines" (the `machines.length === 0` empty-state message never fires,
 * because `machines.length` is NOT 0 -- the renderer is just broken) --
 * a false negative on an operator-facing fleet dashboard.
 *
 * This file proves the fix on the real shipped source, for all 4 lcars2
 * app files:
 *   1. The guard now fires exactly ONCE per `renderMachines()` call when
 *      `window.LCARS_CORE.machines` is absent, regardless of how many
 *      machines are passed in -- not once per machine.
 *   2. `#machines-list` gets a VISIBLE error message on that path (the
 *      same `.empty-message` idiom the `machines.length === 0` branch
 *      already uses, plus a `.render-error` modifier -- see
 *      lcars-fleet-theme.css), so "renderer broken" is now
 *      distinguishable from "no machines" by anyone looking at the page,
 *      not just by someone with devtools open.
 *   3. The happy path (core present) still renders every machine and logs
 *      no error at all -- this file does not merely prove the failure
 *      path improved, it proves it did not regress the success path.
 *
 * ── Route taken ───────────────────────────────────────────────────────────
 * Same jsdom "run outside-only, wait for the real load event, patch an
 * ADDITIVE window.__lcarsTestExports tail before the closing IIFE" recipe
 * as tests/xaca-1100-013-render-machines-expand-survives-refresh.test.js,
 * with one deliberate difference: the "core absent" scenario here never
 * loads lcars-fleet-core.js into the vm context at all (rather than
 * loading it and then deleting/breaking window.LCARS_CORE afterward) --
 * that is the most faithful simulation of the real-world failure mode this
 * guard exists for: lcars-fleet-core.js failing to load / not being
 * present in the page's <script> tag order ahead of the app script.
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
// variants keep being exercised (this suite's renderMachines()/LCARS_CORE
// guard coverage does not actually depend on CONFIG, but every other
// lcars2 suite in this directory follows this same shape, and dropping to
// a single un-parameterized case would silently narrow coverage relative
// to before unification).
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

// 5 machines -- enough to make "once per render" and "once per machine"
// produce clearly different, unmistakable counts (1 vs 5) without
// overfitting the assertion to any particular fleet size.
function fiveMachines() {
    const machines = [];
    for (let i = 0; i < 5; i++) {
        machines.push({
            machine_id: 'xaca-1100-022-fixture-machine-' + i,
            hostname: 'xaca-1100-022-' + i + '.example.test',
            status: i % 2 === 0 ? 'online' : 'offline',
            session_count: i,
            system: {}
        });
    }
    return machines;
}

// Loads one of the 4 lcars2 minimal renderer files into a real jsdom
// document with the REAL #machines-list container id renderMachines()
// looks up, patched with an additive test-export tail exposing
// renderMachines() itself. `loadCore` controls whether
// lcars2/js/lcars-fleet-core.js is loaded into the SAME vm context first --
// false reproduces the real-world "core failed to load" scenario this
// guard exists to catch; true is the ordinary/happy-path load order every
// real HTML page uses.
async function setupApp(target, loadCore) {
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

    if (loadCore) {
        const coreSrc = fs.readFileSync(path.join(PUBLIC_ROOT, 'lcars2/js/lcars-fleet-core.js'), 'utf8');
        vm.runInContext(coreSrc, ctx, { filename: 'lcars2/js/lcars-fleet-core.js' });
    }
    // else: window.LCARS_CORE is left entirely undefined -- the failure
    // mode under test.

    if (target.configGlobal) {
        window.LCARS_DASHBOARD_CONFIG = target.configGlobal;
    }

    const src = fs.readFileSync(path.join(PUBLIC_ROOT, relPath), 'utf8');
    const marker = '})();';
    const lastIdx = src.lastIndexOf(marker);
    if (lastIdx === -1) throw new Error('setupApp: closing "})();" not found in ' + relPath);
    const exportStmt = '\n    window.__lcarsTestExports = { renderMachines: renderMachines };\n';
    const patched = src.slice(0, lastIdx) + exportStmt + src.slice(lastIdx);
    vm.runInContext(patched, ctx, { filename: relPath });

    const mod = window.__lcarsTestExports;
    if (!mod || typeof mod.renderMachines !== 'function') {
        throw new Error('setupApp: renderMachines export missing from ' + relPath);
    }
    return { window, document, mod };
}

// Runs `fn` with console.error replaced by a counting spy (never forwarded
// to the real console -- these calls are the EXPECTED diagnostic this test
// exists to count, not test-run noise worth printing) and returns
// { result, calls } where `calls` is the array of argument-lists the spy
// captured.
function withCapturedConsoleError(fn) {
    const calls = [];
    const orig = console.error;
    console.error = function (...args) { calls.push(args); };
    try {
        const result = fn();
        return { result, calls };
    } finally {
        console.error = orig;
    }
}

// ============================================================================
// Core absent: exactly ONE console.error per render, not one per machine.
// ============================================================================

LCARS2_APP_FILES.forEach((target) => {
    test(`XACA-1100-022: renderMachines() with LCARS_CORE.machines absent logs exactly ONE console.error for a 5-machine render (${target.label}: ${target.relPath})`, async () => {
        const { mod } = await setupApp(target, false);

        const { calls } = withCapturedConsoleError(() => {
            mod.renderMachines(fiveMachines());
        });

        assert.equal(calls.length, 1,
            'expected exactly one console.error call for the whole render (the guard was hoisted above the forEach) -- ' +
            'got ' + calls.length + '; if this is 5, the guard is still inside the forEach and re-firing per machine');
        assert.match(String(calls[0][0]), /lcars-fleet-core\.js is not/,
            'the single console.error call must be the LCARS_CORE-missing diagnostic, not some other message');
    });

    test(`XACA-1100-022: renderMachines() with LCARS_CORE.machines absent logs exactly ONE console.error across TWO successive renders (simulated refresh ticks) -- proves it re-evaluates once per CALL, not once ever (${target.label}: ${target.relPath})`, async () => {
        const { mod } = await setupApp(target, false);

        const { calls } = withCapturedConsoleError(() => {
            mod.renderMachines(fiveMachines());
            mod.renderMachines(fiveMachines());
        });

        assert.equal(calls.length, 2,
            'expected exactly one console.error per renderMachines() CALL (2 calls -> 2 logs) -- proves the guard still ' +
            'runs on every render (it is not memoized/one-shot), it just no longer runs once PER MACHINE within a render');
    });
});

// ============================================================================
// Core absent: a VISIBLE error message is painted into the container.
// ============================================================================

LCARS2_APP_FILES.forEach((target) => {
    test(`XACA-1100-022: renderMachines() with LCARS_CORE.machines absent paints a visible render-error message into #machines-list, not a blank container (${target.label}: ${target.relPath})`, async () => {
        const { document, mod } = await setupApp(target, false);

        withCapturedConsoleError(() => {
            mod.renderMachines(fiveMachines());
        });

        const container = document.getElementById('machines-list');
        assert.notEqual(container.innerHTML.trim(), '',
            'the container must not be silently blank when the renderer is broken -- that reads to an operator as ' +
            '"no machines detected", a false negative on a fleet dashboard');

        // Same idiom as the machines.length === 0 branch (a <p class="empty-message">
        // in the container), plus the .render-error modifier that distinguishes
        // "renderer broken" from "genuinely no machines" via LCARS_CORE red
        // (see lcars-fleet-theme.css's .empty-message.render-error rule).
        const errorPara = container.querySelector('p.empty-message.render-error');
        assert.ok(errorPara, 'expected a <p class="empty-message render-error"> in the container on the LCARS_CORE-absent path');
        assert.match(errorPara.textContent, /unavailable|failed to load|renderer/i,
            'the visible message must actually say something is broken, not just be an empty styled paragraph');

        // Must NOT be mistakable for the genuine "no machines" empty state --
        // that would silently recreate the exact false-negative this fix exists
        // to prevent.
        assert.notEqual(errorPara.textContent.trim(), 'No machines detected',
            'the render-error message must read differently than the genuine empty-fleet message');
    });
});

// ============================================================================
// Happy path (core present): unaffected -- no error logged, all 5 machines
// render, no render-error message. Proves the hoist did not regress success.
// ============================================================================

LCARS2_APP_FILES.forEach((target) => {
    test(`XACA-1100-022: renderMachines() with LCARS_CORE.machines present renders all 5 machines and logs NOTHING (${target.label}: ${target.relPath})`, async () => {
        const { document, mod } = await setupApp(target, true);

        const { calls } = withCapturedConsoleError(() => {
            mod.renderMachines(fiveMachines());
        });

        assert.equal(calls.length, 0, 'the happy path must not log any console.error at all');

        const container = document.getElementById('machines-list');
        assert.equal(container.querySelectorAll('.status-row').length, 5,
            'all 5 machines must still render when LCARS_CORE.machines is present -- the hoisted guard must not ' +
            'short-circuit the successful path');
        assert.equal(container.querySelector('.render-error'), null,
            'no render-error message should appear when rendering succeeded');
    });
});
