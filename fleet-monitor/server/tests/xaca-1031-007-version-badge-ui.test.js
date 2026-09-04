//
//  xaca-1031-007-version-badge-ui.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1031 subitem 007 (Testing & Debugging) -- CLIENT-side regression
 * coverage for createMachineItem()'s version row / OUTDATED badge, added to
 * all five dashboard app files by e77798e1.
 *
 * ── Why jsdom, and why lcars2/js/lcars-academy-app.js as the primary target
 * ────────────────────────────────────────────────────────────────────────
 * The 5 LCARS client apps are plain browser IIFEs with no module.exports and
 * no bundler. lcars-academy-app.js's createMachineItem() (the 18-line
 * "minimal" renderer per e77798e1's commit message) is the simplest of the
 * five and needs nothing beyond `document.createElement`/`.innerHTML` and
 * the file's own escapeHtml() -- so it is loaded here via jsdom (a REAL
 * HTML parser and DOM, not a hand stub) to satisfy the constraint that the
 * fleet-wide-regression, three-state, absent-system, and XSS checks are all
 * asserted against a REAL CONSTRUCTED DOM (querySelectorAll, element counts,
 * textContent), never by eyeballing or regex-matching the HTML string.
 * Same loader technique as tests/xaca-1060-008-machine-filter-jsdom.test.js
 * (wait for jsdom's own 'load' event BEFORE evaluating the app script -- see
 * that file's setupApp()-equivalent header comment for why: the file
 * registers its own `document.addEventListener('DOMContentLoaded', ...)` at
 * module scope unconditionally, and that handler's fetch()+setInterval()
 * calls hang `node --test` forever if the listener is still live when
 * jsdom's queued load event fires).
 *
 * ── Cross-file consistency (constraint: "additive per user ruling... the
 *    5-way duplication is NOT extracted") ─────────────────────────────────
 * The commit deliberately duplicates this logic across all 5 files instead
 * of extracting a shared helper. A future edit to one copy silently NOT
 * applied to the other four is exactly the sibling-drift failure class this
 * codebase has hit repeatedly (see tests/test-xaca-0983-004-fleet-monitor-
 * node-suites.sh's CASE C precedent, which runs the same kind of structural
 * check for a different feature). The "cross-file consistency" tests below
 * assert textual identity of the version-gating block across the 4
 * lcars2/js minimal renderers, and a matching (not text-identical, since the
 * rich renderer's HTML/CSS differs) presence check against
 * lcars/js/lcars-dashboard-app.js.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');
const ACADEMY_APP_REL_PATH = 'lcars2/js/lcars-academy-app.js';

const LCARS2_MINIMAL_FILES = [
    'lcars2/js/lcars-academy-app.js',
    'lcars2/js/lcars-all-app.js',
    'lcars2/js/lcars-doublenode-app.js',
    'lcars2/js/lcars-mainevent-app.js'
].filter((rel) => fs.existsSync(path.join(PUBLIC_ROOT, rel))); // doublenode is NOT tap-mirrored (XACA-0139)

const RICH_APP_REL_PATH = 'lcars/js/lcars-dashboard-app.js';

function baseMachine(overrides) {
    return Object.assign(
        {
            machine_id: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
            hostname: 'runabout',
            status: 'online',
            session_count: 3
        },
        overrides
    );
}

// Loads one of the lcars2 minimal renderer files into a real jsdom document,
// patched with an additive test-export tail exposing createMachineItem (and
// escapeHtml, for direct escaping assertions) onto window.__lcarsTestExports.
// Mirrors tests/xaca-1060-008-machine-filter-jsdom.test.js's setupDashboard()
// load-then-wait-for-'load'-then-eval discipline.
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
    const src = fs.readFileSync(path.join(PUBLIC_ROOT, relPath), 'utf8');
    const marker = '})();';
    const lastIdx = src.lastIndexOf(marker);
    if (lastIdx === -1) throw new Error('setupMinimalApp: closing "})();" not found in ' + relPath);
    const exportStmt = '\n    window.__lcarsTestExports = {' +
        ' createMachineItem: createMachineItem,' +
        ' escapeHtml: escapeHtml' +
        ' };\n';
    const patched = src.slice(0, lastIdx) + exportStmt + src.slice(lastIdx);
    vm.runInContext(patched, ctx, { filename: relPath });

    const mod = window.__lcarsTestExports;
    if (!mod || typeof mod.createMachineItem !== 'function') {
        throw new Error('setupMinimalApp: test exports missing from ' + relPath);
    }
    return { window, document, mod };
}

// ============================================================================
// Constraint #15: system absent entirely -- card renders cleanly, no
// "undefined" anywhere in the constructed DOM.
// ============================================================================

test('createMachineItem: machine.system absent entirely renders no version indicator and no "undefined" text', async () => {
    const { mod } = await setupMinimalApp(ACADEMY_APP_REL_PATH);
    const machine = baseMachine(); // no `system` key at all
    const item = mod.createMachineItem(machine);

    assert.equal(item.querySelectorAll('[title="aiteamforge version"]').length, 0,
        'no version indicator element should be created when system is absent');
    assert.equal(/undefined/.test(item.innerHTML), false, 'rendered markup must never contain the literal string "undefined"');
    assert.equal(item.textContent.indexOf('runabout') !== -1, true, 'the rest of the card must still render');
});

// ============================================================================
// Constraint #13: the fleet-wide regression -- versions: {} (the reporter
// could not resolve its own version) must render NO version row at all, not
// an amber UNKNOWN badge. This is the exact bug that shipped and was caught
// before merge (see e77798e1's "XACA-1031-006 BUGFIX" comment).
// ============================================================================

test('createMachineItem: machine.system.versions: {} (reporter could not resolve) renders NO version indicator (constraint #13, the shipped bug)', async () => {
    const { mod } = await setupMinimalApp(ACADEMY_APP_REL_PATH);
    const machine = baseMachine({ system: { schema_version: 1, versions: {} } });
    const item = mod.createMachineItem(machine);

    assert.equal(item.querySelectorAll('[title="aiteamforge version"]').length, 0,
        'versions: {} is truthy -- gating on container truthiness (the shipped bug) would render a badge here; gating on aiteamforge PRESENCE must not');
    assert.equal(/UNKNOWN/.test(item.innerHTML), false, 'no UNKNOWN badge for a machine with no known version at all');
});

// ============================================================================
// Constraint #14: three-state badge -- outdated true / false / key-absent
// (known version, undeterminable staleness) must render three VISIBLY
// DISTINCT states.
// ============================================================================

test('createMachineItem: outdated:true renders the OUTDATED indicator', async () => {
    const { mod } = await setupMinimalApp(ACADEMY_APP_REL_PATH);
    const machine = baseMachine({ system: { schema_version: 1, versions: { aiteamforge: '0.9.0', latest: '0.20.3', outdated: true } } });
    const item = mod.createMachineItem(machine);

    const indicator = item.querySelector('[title="aiteamforge version"]');
    assert.ok(indicator, 'expected a version indicator element');
    assert.match(indicator.textContent, /OUTDATED/);
    assert.equal(/UNKNOWN/.test(indicator.textContent), false);
});

test('createMachineItem: outdated:false renders confirmed-current with NO badge suffix', async () => {
    const { mod } = await setupMinimalApp(ACADEMY_APP_REL_PATH);
    const machine = baseMachine({ system: { schema_version: 1, versions: { aiteamforge: '0.20.3', latest: '0.20.3', outdated: false } } });
    const item = mod.createMachineItem(machine);

    const indicator = item.querySelector('[title="aiteamforge version"]');
    assert.ok(indicator);
    assert.equal(/OUTDATED/.test(indicator.textContent), false);
    assert.equal(/UNKNOWN/.test(indicator.textContent), false);
    assert.match(indicator.textContent, /^v0\.20\.3$/, 'confirmed-current has no trailing suffix at all');
});

test('createMachineItem: outdated key ABSENT (known version, undeterminable staleness) renders visibly-distinct UNKNOWN, and a null value must not be silently read as confirmed-current (constraint #14)', async () => {
    const { mod } = await setupMinimalApp(ACADEMY_APP_REL_PATH);

    // Case A: key genuinely absent (the real shape the server ever sends).
    const machineAbsent = baseMachine({ system: { schema_version: 1, versions: { aiteamforge: '0.15.0' } } });
    const itemAbsent = mod.createMachineItem(machineAbsent);
    const indicatorAbsent = itemAbsent.querySelector('[title="aiteamforge version"]');
    assert.ok(indicatorAbsent);
    assert.match(indicatorAbsent.textContent, /UNKNOWN/);
    assert.equal(/OUTDATED/.test(indicatorAbsent.textContent), false);

    // Case B: a defensive check -- if a non-boolean/null ever slipped through,
    // it must NOT render as confirmed-current (green, no badge). The code
    // reads `outdated === false` explicitly, so null must fall through to the
    // UNKNOWN branch just like an absent key.
    const machineNull = baseMachine({ system: { schema_version: 1, versions: { aiteamforge: '0.15.0', outdated: null } } });
    const itemNull = mod.createMachineItem(machineNull);
    const indicatorNull = itemNull.querySelector('[title="aiteamforge version"]');
    assert.ok(indicatorNull);
    assert.match(indicatorNull.textContent, /UNKNOWN/, 'outdated:null must render as UNKNOWN, never as confirmed-current');
});

// ============================================================================
// Constraint #16: XSS probe -- a version string carrying a quote and an
// angle bracket must render as INERT TEXT. Assert zero elements created via
// querySelectorAll on the real DOM (not by reading the HTML string).
// ============================================================================

test('createMachineItem: a version string containing a quote and an angle bracket renders as inert text, not markup (constraint #16)', async () => {
    const { mod } = await setupMinimalApp(ACADEMY_APP_REL_PATH);
    const payload = '"><img src=x onerror=alert(1)>';
    const machine = baseMachine({ system: { schema_version: 1, versions: { aiteamforge: payload } } });
    const item = mod.createMachineItem(machine);

    assert.equal(item.querySelectorAll('img').length, 0, 'the payload must not have been parsed into a real <img> element');
    assert.equal(item.querySelectorAll('[onerror]').length, 0, 'no element anywhere in the card may carry an onerror attribute');
    assert.equal(item.querySelectorAll('*').length, 4,
        'exactly the 4 real elements this card creates when a version is known (status-indicator span, hostname span, version indicator span, session-count span) -- the OUTDATED/UNKNOWN suffix is plain text inside the version span, never a separate element, and the payload must not have added any more');
    const indicator = item.querySelector('[title="aiteamforge version"]');
    assert.ok(indicator, 'the indicator element itself must still exist (aiteamforge is present)');
    assert.ok(indicator.textContent.includes(payload),
        'escapeHtml must preserve the payload as literal readable TEXT (DOM textContent decodes entities back to the original characters) -- it must not have been silently dropped or truncated');
});

test('escapeHtml: the exact XSS payload used above round-trips to inert text (direct unit check)', async () => {
    const { mod } = await setupMinimalApp(ACADEMY_APP_REL_PATH);
    const payload = '"><img src=x onerror=alert(1)>';
    const escaped = mod.escapeHtml(payload);
    assert.equal(escaped.includes('<img'), false);
    assert.equal(escaped.includes('onerror='), true, 'the literal text is preserved (as inert text), just not as markup');
    assert.equal(escaped.includes('<'), false, 'no literal "<" must survive escaping');
    assert.equal(escaped.includes('>'), false, 'no literal ">" must survive escaping');
});

// ============================================================================
// Cross-file consistency: the version-gating block must be textually
// identical across the four lcars2 minimal renderers (additive-only, no
// shared helper extracted -- so drift between copies is a real risk this
// suite is the only thing that would catch).
// ============================================================================

test('cross-file consistency: the hasInstalledVersion gate is textually identical across every lcars2 minimal renderer', () => {
    assert.ok(LCARS2_MINIMAL_FILES.length >= 3, 'expected at least 3 lcars2 minimal renderer files to exist on disk');
    const GATE_LINE = 'const hasInstalledVersion = !!sysVersions && sysVersions.aiteamforge !== undefined && sysVersions.aiteamforge !== null;';
    const missing = [];
    for (const rel of LCARS2_MINIMAL_FILES) {
        const src = fs.readFileSync(path.join(PUBLIC_ROOT, rel), 'utf8');
        if (!src.includes(GATE_LINE)) missing.push(rel);
    }
    assert.deepEqual(missing, [], 'every lcars2 minimal renderer must gate on aiteamforge PRESENCE identically: ' + missing.join(', '));
});

test('cross-file consistency: the rich renderer (lcars/js/lcars-dashboard-app.js) gates on the same aiteamforge-presence rule (not container truthiness)', () => {
    const src = fs.readFileSync(path.join(PUBLIC_ROOT, RICH_APP_REL_PATH), 'utf8');
    assert.match(src, /hasInstalledVersion\s*=\s*!!sysVersions\s*&&\s*sysVersions\.aiteamforge\s*!==\s*undefined\s*&&\s*sysVersions\.aiteamforge\s*!==\s*null/,
        'the rich renderer must gate the version row on aiteamforge presence, matching the minimal renderers -- a divergence here would re-introduce the amber-UNKNOWN-on-every-card regression on just this one file');
});
