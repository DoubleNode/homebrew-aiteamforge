//
//  xaca-1031-018-version-aria-label.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * Regression coverage for XACA-1031-018 ([UX] NICE-TO-HAVE): lcars2's
 * compact version indicator used title="aiteamforge version" as its only
 * extra labelling -- a title attribute on a non-focusable <span> has weak
 * and inconsistent screen-reader support. The fix restructures BOTH version
 * renderers (the rich lcars/js labelled row AND the compact lcars2/js
 * inline span) to build the version element with document.createElement +
 * textContent + setAttribute instead of string-interpolating it into
 * innerHTML, then attaches an aria-label mirroring the full visible text
 * (version + outdated/up-to-date/unknown state), in the SAME phrasing on
 * both surfaces.
 *
 * WHY THE DOM-API RESTRUCTURE (not just bolting aria-label onto the old
 * innerHTML template): installedVersionText is a remote machine's own
 * self-reported string (POST /api/status) -- untrusted. Interpolating it
 * into a NEW quoted attribute (aria-label="...") inside an innerHTML string
 * would need an escapeAttr() call, extending the XACA-0416-004 invariant
 * comment to a value it didn't previously touch in lcars2/js (that file
 * deliberately has no escapeAttr() defined at all -- "no untrusted value
 * reaches a quoted attribute in this file"). Going through
 * createElement()/textContent/setAttribute() instead means the browser
 * handles escaping structurally at the DOM-API boundary -- setAttribute()
 * and textContent literally cannot be made to produce markup -- so no
 * escaper is needed for the new attribute at all. THE XSS PROOF group below
 * exists specifically to demonstrate that guarantee, not just describe it.
 *
 * ── Method ──────────────────────────────────────────────────────────────
 * Same jsdom "run outside-only, wait for the load event, patch a
 * window.__lcarsTestExports tail before the closing IIFE" recipe as
 * tests/xaca-1031-007-version-badge-ui.test.js and
 * tests/xaca-1031-015-016-017-ux-followups.test.js, generalized here with
 * an optional `srcOverride` so the MUTATION KILL group can run the exact
 * same harness against a deliberately-broken in-memory copy of the real
 * source, without ever touching the file on disk.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');

const RICH_APP_REL_PATH = 'lcars/js/lcars-dashboard-app.js';

const ALL_LCARS2_MINIMAL_FILES = [
    'lcars2/js/lcars-academy-app.js',
    'lcars2/js/lcars-all-app.js',
    'lcars2/js/lcars-doublenode-app.js',
    'lcars2/js/lcars-mainevent-app.js'
];
// doublenode is NOT tap-mirrored (XACA-0139) -- same existence filter as
// the sibling XACA-1031 suites.
const LCARS2_MINIMAL_FILES = ALL_LCARS2_MINIMAL_FILES.filter((rel) => fs.existsSync(path.join(PUBLIC_ROOT, rel)));
// One representative lcars2 file for tests that don't need to run across
// all four (the cross-file byte-identity test elsewhere already proves
// they're identical over the createMachineItem() extent this ticket
// touches, so re-running every assertion 4x here would be redundant).
const LCARS2_REPRESENTATIVE = LCARS2_MINIMAL_FILES[0];

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

// ============================================================================
// Shared loader -- mirrors the sibling XACA-1031 suites' setupApp() exactly,
// with one addition: an optional `srcOverride` so the MUTATION KILL group
// can execute a deliberately-broken in-memory copy of the real source
// through the identical jsdom harness, without writing to or reverting any
// file on disk.
// ============================================================================
async function setupApp(relPath, exportNames, srcOverride) {
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
    const src = srcOverride !== undefined ? srcOverride : fs.readFileSync(path.join(PUBLIC_ROOT, relPath), 'utf8');
    const marker = '})();';
    const lastIdx = src.lastIndexOf(marker);
    if (lastIdx === -1) throw new Error('setupApp: closing "})();" not found in ' + relPath);
    const exportStmt = '\n    window.__lcarsTestExports = { ' +
        exportNames.map((name) => name + ': ' + name).join(', ') +
        ' };\n';
    const patched = src.slice(0, lastIdx) + exportStmt + src.slice(lastIdx);
    vm.runInContext(patched, ctx, { filename: relPath });

    const mod = window.__lcarsTestExports;
    if (!mod || typeof mod.createMachineItem !== 'function') {
        throw new Error('setupApp: test exports missing from ' + relPath);
    }
    return { window, document, mod };
}

// XACA-1092 changed lcars2's createMachineItem() to return a
// DocumentFragment containing [div.status-row, div.status-row-detail] (the
// detail block must be a SIBLING of the row, not a child of it -- .status-
// row is a single flex row also used by non-machine listings, UX spec §1)
// instead of returning the div.status-row element directly, as it did when
// this suite was written. Unwrap here, once, so assertions that walk
// `.children` (element-order checks below) or otherwise need the row
// itself keep running against the actual .status-row element, completely
// unchanged in intent or strength. Only the lcars2 minimal renderers
// changed shape -- the rich renderer (setupRichApp() above) still returns
// its container Element directly, so this helper is a no-op for anything
// that isn't a fragment.
function unwrapStatusRow(node) {
    if (node && node.nodeType === 11 /* Node.DOCUMENT_FRAGMENT_NODE */) {
        const row = node.querySelector('.status-row');
        if (!row) throw new Error('unwrapStatusRow: expected a .status-row descendant in the returned fragment');
        return row;
    }
    return node;
}

function readRealSource(relPath) {
    return fs.readFileSync(path.join(PUBLIC_ROOT, relPath), 'utf8');
}

async function setupRichApp(srcOverride) {
    return setupApp(RICH_APP_REL_PATH, ['createMachineItem', 'escapeHtml'], srcOverride);
}

async function setupLcars2App(relPath, srcOverride) {
    return setupApp(relPath, ['createMachineItem', 'escapeHtml'], srcOverride);
}

// Expected aria-label phrasing -- ONE function, used to build the expected
// string for both renderers' assertions below, so a phrasing mismatch
// between the two surfaces (the ticket's explicit "same phrasing in both
// renderers" requirement) shows up as a test failure rather than two
// separately-hand-typed strings drifting apart unnoticed.
function expectedAriaLabel(installedVersionText, outdated) {
    const stateText = outdated === true ? 'outdated' : outdated === false ? 'up to date' : 'update status unknown';
    return 'AITeamForge version ' + installedVersionText + ', ' + stateText;
}

const VERSION_STATE_CASES = [
    { label: 'outdated:true', versions: { aiteamforge: '0.9.0', latest: '0.20.3', outdated: true }, outdated: true },
    { label: 'outdated:false', versions: { aiteamforge: '0.20.3', latest: '0.20.3', outdated: false }, outdated: false },
    { label: 'outdated key absent', versions: { aiteamforge: '0.15.0' }, outdated: undefined }
];

// ============================================================================
// RICH renderer (lcars/js/lcars-dashboard-app.js) -- labelled row
// ============================================================================

for (const c of VERSION_STATE_CASES) {
    test('XACA-1031-018 rich renderer: ' + c.label + ' -- .machine-version-value carries an aria-label mirroring the visible text', async () => {
        const { mod } = await setupRichApp();
        const machine = baseMachine({ system: { schema_version: 1, versions: c.versions } });
        const container = mod.createMachineItem(machine);

        const label = container.querySelector('.machine-version-label');
        const value = container.querySelector('.machine-version-value');
        assert.ok(label, 'expected .machine-version-label to still exist -- class name must be preserved (XACA-1031-015 depends on it)');
        assert.ok(value, 'expected .machine-version-value to still exist -- class name must be preserved (XACA-1031-015 depends on it)');
        assert.equal(label.textContent, 'Version:');
        assert.equal(value.textContent, c.versions.aiteamforge);

        const ariaLabel = value.getAttribute('aria-label');
        assert.equal(ariaLabel, expectedAriaLabel(c.versions.aiteamforge, c.outdated),
            'aria-label must mirror the full visible text (version + state), in the shared phrasing');
    });
}

test('XACA-1031-018 rich renderer: aiteamforge absent -> NO version element at all, no aria-label anywhere for it', async () => {
    const { mod } = await setupRichApp();
    const machine = baseMachine({ system: { schema_version: 1, versions: {} } });
    const container = mod.createMachineItem(machine);
    assert.equal(container.querySelector('.machine-version-row'), null);
    assert.equal(container.querySelector('.machine-version-label'), null);
    assert.equal(container.querySelector('.machine-version-value'), null);
});

test('XACA-1031-018 rich renderer: system absent entirely -> no version element, card renders cleanly', async () => {
    const { mod } = await setupRichApp();
    const machine = baseMachine({});
    const container = mod.createMachineItem(machine);
    assert.equal(container.querySelector('.machine-version-row'), null);
    assert.ok(container.querySelector('.machine-row-header'), 'sanity: the rest of the card must still render');
    assert.ok(container.querySelector('.machine-row-footer'), 'sanity: the rest of the card must still render');
});

test('XACA-1031-018 rich renderer: element order is unchanged -- version row still sits directly after the GUID row and before the backup panel', async () => {
    // The backup panel is driven by a MODULE-LEVEL `backupStatus` variable
    // (populated at runtime by an async GET /api/backup-status fetch), not
    // by anything on the `machine` object itself -- there is no
    // machine.backup_status field to pass in. To render the panel in this
    // harness, inject a direct assignment into an in-memory copy of the
    // real source, in the same closure scope, right before the
    // window.__lcarsTestExports tail setupApp() itself appends. This is
    // additive (nothing removed/altered) and scoped to this one test.
    const realSrc = readRealSource(RICH_APP_REL_PATH);
    const marker = '})();';
    const lastIdx = realSrc.lastIndexOf(marker);
    assert.notEqual(lastIdx, -1, 'sanity: closing "})();" must be found in the real source');
    const injectedSrc = realSrc.slice(0, lastIdx) +
        "\n    backupStatus = { boards: { academy: { lastAction: 'backed_up', lastCheck: Date.now(), lastBackup: Date.now() } } };\n" +
        realSrc.slice(lastIdx);

    const { mod } = await setupRichApp(injectedSrc);
    const machine = baseMachine({
        sessions: [{ division: 'academy' }],
        // XACA-1092 added a SEPARATE, orthogonal system-telemetry section
        // (`.machine-system-container` / `.machine-system-no-data`) that
        // renders as an extra sibling whenever `schema_version` is present
        // on `system` -- real, intentional behavior, unrelated to what this
        // test checks. This test is strictly about the VERSION row's
        // position, so `schema_version` is omitted here to avoid
        // incidentally exercising that unrelated feature; `versions` alone
        // is all createMachineItem() needs to render the version row.
        system: { schema_version: 1, versions: { aiteamforge: '0.9.0', latest: '0.20.3', outdated: true } }
    });
    const container = mod.createMachineItem(machine);
    const row = container.querySelector('.machine-row');
    assert.ok(row.querySelector('.machine-backup-container'), 'sanity: the backup panel must actually be present, or this test proves nothing about its position');
    const classNames = Array.from(row.children).map((el) => el.className.split(' ')[0]);
    // Fixed shape this ticket must not disturb: header, nickname row, GUID
    // row, THEN the version row, THEN the backup panel, THEN the footer.
    // Confirmed by hand against the pre-change source
    // (commit 58356c4204bbcbb6615580c24a8097cf27635087) to render this
    // exact same sequence before this ticket's changes.
    assert.deepEqual(classNames, [
        'machine-row-header',
        'machine-nickname-row',
        'machine-guid',
        'machine-version-row',
        'machine-backup-container',
        // XACA-1092: the system-telemetry section is a NEW sibling this
        // ticket adds. It is asserted here, with `schema_version` kept in the
        // fixture, rather than dodged by removing that key -- `schema_version`
        // present with no health fields IS the day-one state for the whole
        // fleet, so a fixture without it would stop guarding the real card.
        // This test's own intent is unchanged and still enforced: the version
        // row sits directly after the GUID row.
        'machine-system-no-data',
        'machine-row-footer'
    ]);
});

test('XACA-1031-018 rich renderer: element order when there is no backup panel -- version row sits after the GUID row, before the XACA-1092 system section and the footer', async () => {
    const { mod } = await setupRichApp();
    // schema_version deliberately omitted -- see the comment in the sibling
    // "...before the backup panel" test above: XACA-1092's system-telemetry
    // section is an orthogonal feature this order-only test must not
    // incidentally trip.
    const machine = baseMachine({ system: { schema_version: 1, versions: { aiteamforge: '0.15.0' } } });
    const container = mod.createMachineItem(machine);
    const row = container.querySelector('.machine-row');
    const classNames = Array.from(row.children).map((el) => el.className.split(' ')[0]);
    assert.deepEqual(classNames, [
        'machine-row-header',
        'machine-nickname-row',
        'machine-guid',
        'machine-version-row',
        // XACA-1092: the system-telemetry section is a NEW sibling this
        // ticket adds. It is asserted here, with `schema_version` kept in the
        // fixture, rather than dodged by removing that key -- `schema_version`
        // present with no health fields IS the day-one state for the whole
        // fleet, so a fixture without it would stop guarding the real card.
        // This test's own intent is unchanged and still enforced: the version
        // row sits directly after the GUID row.
        'machine-system-no-data',
        'machine-row-footer'
    ]);
});

// ============================================================================
// LCARS2 renderer (lcars2/js/lcars-*-app.js) -- compact inline span
// ============================================================================

for (const c of VERSION_STATE_CASES) {
    test('XACA-1031-018 lcars2 renderer (' + LCARS2_REPRESENTATIVE + '): ' + c.label + ' -- .status-row-version carries an aria-label mirroring the visible text', async () => {
        const { mod } = await setupLcars2App(LCARS2_REPRESENTATIVE);
        const machine = baseMachine({ system: { schema_version: 1, versions: c.versions } });
        const item = unwrapStatusRow(mod.createMachineItem(machine));

        const versionEl = item.querySelector('.status-row-version');
        assert.ok(versionEl, 'expected .status-row-version to still exist -- class name must be preserved (XACA-1031-016 overflow guard depends on it)');

        const suffix = c.outdated === true ? ' OUTDATED' : c.outdated === false ? '' : ' UNKNOWN';
        assert.equal(versionEl.textContent, 'v' + c.versions.aiteamforge + suffix);

        // title= is deliberately KEPT (see file header) -- the fix ADDS
        // aria-label, it does not remove the sighted-user hover tooltip.
        assert.equal(versionEl.getAttribute('title'), 'aiteamforge version');

        const ariaLabel = versionEl.getAttribute('aria-label');
        assert.equal(ariaLabel, expectedAriaLabel(c.versions.aiteamforge, c.outdated),
            'aria-label must mirror the full visible text (version + state), in the SAME phrasing as the rich renderer');
    });
}

test('XACA-1031-018 lcars2 renderer: aiteamforge absent -> NO version element at all', async () => {
    const { mod } = await setupLcars2App(LCARS2_REPRESENTATIVE);
    const machine = baseMachine({ system: { schema_version: 1, versions: {} } });
    const item = unwrapStatusRow(mod.createMachineItem(machine));
    assert.equal(item.querySelector('.status-row-version'), null);
});

test('XACA-1031-018 lcars2 renderer: system absent entirely -> no version element, card renders cleanly', async () => {
    const { mod } = await setupLcars2App(LCARS2_REPRESENTATIVE);
    const machine = baseMachine({});
    const item = unwrapStatusRow(mod.createMachineItem(machine));
    assert.equal(item.querySelector('.status-row-version'), null);
    assert.ok(item.querySelector('.status-row-hostname'), 'sanity: the rest of the row must still render');
});

test('XACA-1031-018 lcars2 renderer: element order is unchanged -- version indicator still sits directly between hostname and session-count', async () => {
    const { mod } = await setupLcars2App(LCARS2_REPRESENTATIVE);
    const machine = baseMachine({ system: { schema_version: 1, versions: { aiteamforge: '0.9.0', latest: '0.20.3', outdated: true } } });
    const item = unwrapStatusRow(mod.createMachineItem(machine));
    const classNames = Array.from(item.children).map((el) => el.className.split(' ')[0]);
    // Confirmed by hand against the pre-change source
    // (commit 58356c4204bbcbb6615580c24a8097cf27635087) to render this
    // exact same sequence before this ticket's changes.
    assert.deepEqual(classNames, ['status-indicator', 'lcars-text-sm', 'lcars-text-xs', 'lcars-text-xs']);
    const versionEl = item.children[2];
    assert.ok(versionEl.classList.contains('status-row-version'));
});

// ============================================================================
// XSS PROOF -- feeds a version string designed to break out of BOTH an
// unquoted textContent context and a quoted attribute string if this were
// still built by string interpolation. Stronger than the pre-existing
// XACA-1031-007 XSS coverage: that suite proves escapeHtml() neutralizes
// the payload as ELEMENT CONTENT. This proves something DOM-API-specific
// that string interpolation (even escaped) does not structurally
// guarantee: setAttribute()'s ATTRIBUTE VALUE holds the literal input
// character-for-character, with no markup created anywhere, regardless of
// what characters it contains.
// ============================================================================

const XSS_VERSION_INPUT = '1.0"><img src=x onerror=alert(1)>';

test('XACA-1031-018 XSS proof, rich renderer: hostile version string creates zero <img> elements and the aria-label attribute holds the literal input verbatim', async () => {
    const { mod } = await setupRichApp();
    const machine = baseMachine({ system: { schema_version: 1, versions: { aiteamforge: XSS_VERSION_INPUT, latest: '9.9.9', outdated: true } } });
    const container = mod.createMachineItem(machine);

    // (a) no markup was created anywhere in the constructed DOM.
    assert.equal(container.querySelectorAll('img').length, 0, 'expected zero <img> elements -- setAttribute()/textContent cannot create markup');

    // (b) the aria-label ATTRIBUTE VALUE contains the literal input string,
    // character-for-character, with the surrounding phrasing exactly as
    // expectedAriaLabel() would build it for any other version string --
    // proving setAttribute() treated the hostile string as inert text, not
    // as markup to be parsed.
    const value = container.querySelector('.machine-version-value');
    assert.ok(value, 'expected the version value element to exist');
    assert.equal(value.getAttribute('aria-label'), expectedAriaLabel(XSS_VERSION_INPUT, true));
    assert.equal(value.textContent, XSS_VERSION_INPUT, 'visible text must also hold the literal input verbatim');

    // Negative-control corroboration: no element in the whole card has the
    // 'onerror' string embedded anywhere as a live attribute name/handler.
    assert.equal(container.querySelectorAll('[onerror]').length, 0);
});

test('XACA-1031-018 XSS proof, lcars2 renderer (' + LCARS2_REPRESENTATIVE + '): hostile version string creates zero <img> elements and the aria-label attribute holds the literal input verbatim', async () => {
    const { mod } = await setupLcars2App(LCARS2_REPRESENTATIVE);
    const machine = baseMachine({ system: { schema_version: 1, versions: { aiteamforge: XSS_VERSION_INPUT, latest: '9.9.9', outdated: true } } });
    const item = unwrapStatusRow(mod.createMachineItem(machine));

    assert.equal(item.querySelectorAll('img').length, 0, 'expected zero <img> elements -- setAttribute()/textContent cannot create markup');

    const versionEl = item.querySelector('.status-row-version');
    assert.ok(versionEl, 'expected the version element to exist');
    assert.equal(versionEl.getAttribute('aria-label'), expectedAriaLabel(XSS_VERSION_INPUT, true));
    assert.equal(versionEl.textContent, 'v' + XSS_VERSION_INPUT + ' OUTDATED', 'visible text must also hold the literal input verbatim');
    assert.equal(item.querySelectorAll('[onerror]').length, 0);
});

// ============================================================================
// MUTATION KILL -- proves the aria-label assertions above are load-bearing,
// not vacuous. Strips the real setAttribute('aria-label', ...) call out of
// an IN-MEMORY copy of the real source (the file on disk is never touched)
// and re-runs the harness against that mutated copy: the version element
// must still render (nothing else broke), but aria-label must now be
// absent -- exactly the condition that would make the positive tests above
// fail if this fix were ever reverted.
// ============================================================================

test('XACA-1031-018 mutation kill, rich renderer: removing the aria-label setAttribute call makes aria-label disappear (proves the positive test above is load-bearing)', async () => {
    const realSrc = readRealSource(RICH_APP_REL_PATH);
    const needle = "versionValue.setAttribute('aria-label', 'AITeamForge version ' + installedVersionText + ', ' + versionStateText);\n";
    assert.ok(realSrc.includes(needle), 'mutation setup: expected to find the exact aria-label setAttribute call in the real source -- if this fails, the source shape changed and the mutation string needs updating');
    const mutatedSrc = realSrc.replace(needle, '');
    assert.notEqual(mutatedSrc, realSrc);

    const { mod } = await setupRichApp(mutatedSrc);
    const machine = baseMachine({ system: { schema_version: 1, versions: { aiteamforge: '0.9.0', latest: '0.20.3', outdated: true } } });
    const container = mod.createMachineItem(machine);
    const value = container.querySelector('.machine-version-value');
    assert.ok(value, 'sanity: the version value element must still exist -- only the aria-label call was removed');
    assert.equal(value.getAttribute('aria-label'), null, 'with the setAttribute call removed, aria-label must be absent -- this is the exact condition that fails the positive test above');
});

test('XACA-1031-018 mutation kill, lcars2 renderer: removing the aria-label setAttribute call makes aria-label disappear (proves the positive test above is load-bearing)', async () => {
    const realSrc = readRealSource(LCARS2_REPRESENTATIVE);
    const needle = "versionEl.setAttribute('aria-label', 'AITeamForge version ' + installedVersionText + ', ' + versionStateText);\n";
    assert.ok(realSrc.includes(needle), 'mutation setup: expected to find the exact aria-label setAttribute call in the real source -- if this fails, the source shape changed and the mutation string needs updating');
    const mutatedSrc = realSrc.replace(needle, '');
    assert.notEqual(mutatedSrc, realSrc);

    const { mod } = await setupLcars2App(LCARS2_REPRESENTATIVE, mutatedSrc);
    const machine = baseMachine({ system: { schema_version: 1, versions: { aiteamforge: '0.9.0', latest: '0.20.3', outdated: true } } });
    const item = unwrapStatusRow(mod.createMachineItem(machine));
    const versionEl = item.querySelector('.status-row-version');
    assert.ok(versionEl, 'sanity: the version element must still exist -- only the aria-label call was removed');
    assert.equal(versionEl.getAttribute('title'), 'aiteamforge version', 'sanity: title= must still be intact -- only the aria-label call was removed');
    assert.equal(versionEl.getAttribute('aria-label'), null, 'with the setAttribute call removed, aria-label must be absent -- this is the exact condition that fails the positive test above');
});

// ============================================================================
// Cross-renderer phrasing consistency -- the ticket's explicit requirement
// that both surfaces announce consistently. Runs the SAME state through
// both renderers and asserts the aria-label text (not just its presence)
// matches exactly.
// ============================================================================

for (const c of VERSION_STATE_CASES) {
    test('XACA-1031-018 cross-renderer consistency: ' + c.label + ' -- rich and lcars2 aria-label text are identical', async () => {
        const machine = baseMachine({ system: { schema_version: 1, versions: c.versions } });

        const { mod: richMod } = await setupRichApp();
        const richContainer = richMod.createMachineItem(machine);
        const richAriaLabel = richContainer.querySelector('.machine-version-value').getAttribute('aria-label');

        const { mod: lcars2Mod } = await setupLcars2App(LCARS2_REPRESENTATIVE);
        const lcars2Item = unwrapStatusRow(lcars2Mod.createMachineItem(machine));
        const lcars2AriaLabel = lcars2Item.querySelector('.status-row-version').getAttribute('aria-label');

        assert.equal(richAriaLabel, lcars2AriaLabel);
    });
}
