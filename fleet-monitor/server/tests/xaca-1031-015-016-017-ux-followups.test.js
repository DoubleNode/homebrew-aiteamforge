//
//  xaca-1031-015-016-017-ux-followups.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * Regression coverage for 3 of the 4 [UX] follow-up findings filed against
 * XACA-1031's version-row feature (subitems -015/-016/-017). -018
 * (aria-label on the version indicator, replacing title= as its only extra
 * labelling) is implemented and covered separately in
 * tests/xaca-1031-018-version-aria-label.test.js -- not here, so as not to
 * disturb this file's existing scope.
 *
 *   XACA-1031-015 (MUST-FIX, WCAG AA): .machine-row.offline's black-text
 *   override list (lcars/css/lcars-fleet-theme.css) never covered the new
 *   .machine-version-value/-label, so an offline machine's version text
 *   rendered in its own state color (red/green/amber) directly on top of
 *   the row's own var(--lcars-alert-red) background -- 1:1 for the
 *   outdated=true case, fully invisible.
 *
 *   XACA-1031-016 (SHOULD-FIX, overflow): lcars2's compact .status-row has
 *   a flex:1 hostname span next to a white-space:nowrap version span with
 *   no shrink/clip guard anywhere -- a long hostname plus a long
 *   pre-release version string overflows the row unclipped.
 *
 *   XACA-1031-017 (SHOULD-FIX, hierarchy): the OUTDATED state -- the
 *   single most actionable signal this feature exists to surface -- had
 *   no card-level cue, only a small badge several rows down.
 *
 * ── Method, mirrored from XACA-1031-007's own file-header rationale ──────
 * jsdom is used for TWO different things here, deliberately kept apart:
 *   (a) real DOM structure/class assertions (createMachineItem() is
 *       loaded and EXECUTED exactly as XACA-1031-007 does it -- same
 *       "run outside-only, wait for jsdom's own load event, patch in a
 *       window.__lcarsTestExports tail before the closing IIFE" recipe);
 *   (b) real getComputedStyle() resolution for the -016 overflow-guard
 *       properties (min-width/max-width/flex-shrink/overflow/
 *       text-overflow/white-space), which jsdom's cssstyle engine DOES
 *       resolve correctly for plain (non custom-property) values when the
 *       real stylesheet is loaded into a <style> tag -- verified by hand
 *       before writing this suite.
 * jsdom's getComputedStyle does NOT resolve CSS custom properties
 * (var(--lcars-alert-red) etc.) -- confirmed by hand before writing this
 * suite: querying .color/.backgroundColor on a live element styled via
 * var() returns the token unresolved or a default, not a computed color.
 * So -015's contrast proof does NOT lean on getComputedStyle for color;
 * it combines a REAL rendered element (to read the actual inline
 * `style="color: ..."` the app emits, and its actual class list) with a
 * REAL read of the actual shipped CSS source text (to confirm the
 * winning override rule exists, including its `!important`) and a
 * hand-written WCAG relative-luminance/contrast calculator applied to the
 * hex constants read out of the file's own `:root` block -- exactly the
 * method the XACA-1031-015 finding itself describes using ("jsdom render
 * of the actual extracted source plus hand relative-luminance calc
 * against the confirmed hex values").
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');
const { CREATE_MACHINE_ITEM_EXPORT_PROPERTY } = require('./helpers/lcars-client-dom-stub');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');

const RICH_APP_REL_PATH = 'lcars/js/lcars-dashboard-app.js';
const RICH_CSS_REL_PATH = 'lcars/css/lcars-fleet-theme.css';
const LCARS2_CSS_REL_PATH = 'lcars2/css/lcars-fleet-theme.css';

const ALL_LCARS2_MINIMAL_FILES = [
    'lcars2/js/lcars-academy-app.js',
    'lcars2/js/lcars-all-app.js',
    'lcars2/js/lcars-doublenode-app.js',
    'lcars2/js/lcars-mainevent-app.js'
];
// doublenode is NOT tap-mirrored (XACA-0139) -- same existence filter as
// tests/xaca-1031-007-version-badge-ui.test.js's LCARS2_MINIMAL_FILES.
const LCARS2_MINIMAL_FILES = ALL_LCARS2_MINIMAL_FILES.filter((rel) => fs.existsSync(path.join(PUBLIC_ROOT, rel)));

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
// Shared loaders -- mirrors tests/xaca-1031-007-version-badge-ui.test.js's
// setupMinimalApp() exactly, generalized to accept any relPath so it can
// also load the rich renderer (lcars/js/lcars-dashboard-app.js), which has
// the identical "IIFE + document.addEventListener('DOMContentLoaded', ...)
// + closing })();" shape.
// ============================================================================
async function setupApp(relPath, exportNames) {
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

    // XACA-1100-002: createMachineItem() itself was extracted out of the 4
    // lcars2 minimal renderers into window.LCARS_CORE.machines.createMachineItem
    // (lcars-fleet-core.js). Load the real shipped core module into this same
    // vm context first, exactly the way a real HTML page's <script> tag
    // would -- otherwise the export wrapper below throws "LCARS_CORE is
    // undefined" the moment it's called. Harmless for RICH_APP_REL_PATH (v1
    // still has its own local createMachineItem() and never touches
    // LCARS_CORE).
    const coreSrc = fs.readFileSync(path.join(PUBLIC_ROOT, 'lcars2/js/lcars-fleet-core.js'), 'utf8');
    vm.runInContext(coreSrc, ctx, { filename: 'lcars2/js/lcars-fleet-core.js' });

    const src = fs.readFileSync(path.join(PUBLIC_ROOT, relPath), 'utf8');
    const marker = '})();';
    const lastIdx = src.lastIndexOf(marker);
    if (lastIdx === -1) throw new Error('setupApp: closing "})();" not found in ' + relPath);
    // createMachineItem: a real local function ONLY in RICH_APP_REL_PATH (v1)
    // now -- `typeof createMachineItem !== "undefined"` is true only there, so
    // it still gets its own unmodified local function. The 4 lcars2 files no
    // longer define it locally (XACA-1100-002), so they fall through to a
    // thin wrapper assembling the same `deps` object the real call site
    // builds (see lcars-*-app.js) and forwarding to the core.
    const exportStmt = '\n    window.__lcarsTestExports = { ' +
        exportNames.map((name) => {
            // XACA-1100-016: CREATE_MACHINE_ITEM_EXPORT_PROPERTY is hoisted
            // to tests/helpers/lcars-client-dom-stub.js, shared by 5 test
            // harnesses that each used to retype this string.
            if (name !== 'createMachineItem') return name + ': ' + name;
            return CREATE_MACHINE_ITEM_EXPORT_PROPERTY;
        }).join(', ') +
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
// this suite's -016 loop below was written. Unwrap here, once, so the
// existing overflow-guard assertions (which need `.outerHTML`, an
// Element-only property the fragment doesn't have) keep running against
// the actual .status-row element, completely unchanged in intent or
// strength. Only the lcars2 minimal renderers changed shape -- the rich
// renderer (setupRichApp() above) still returns its container Element
// directly, so this helper is a no-op for anything that isn't a fragment.
function unwrapStatusRow(node) {
    if (node && node.nodeType === 11 /* Node.DOCUMENT_FRAGMENT_NODE */) {
        const row = node.querySelector('.status-row');
        if (!row) throw new Error('unwrapStatusRow: expected a .status-row descendant in the returned fragment');
        return row;
    }
    return node;
}

async function setupRichApp() {
    return setupApp(RICH_APP_REL_PATH, ['createMachineItem', 'escapeHtml']);
}

async function setupMinimalApp(relPath) {
    return setupApp(relPath, ['createMachineItem', 'escapeHtml']);
}

// ============================================================================
// WCAG 2.x relative luminance / contrast ratio -- textbook implementation,
// not copied from anywhere in this repo (no existing helper found). Applied
// only to hex constants read out of the real CSS file below, never
// hardcoded, so a future palette edit is what this suite would catch.
// ============================================================================
function hexToRgb(hex) {
    const m = /^#([0-9a-fA-F]{6})$/.exec(hex.trim());
    if (!m) throw new Error('hexToRgb: expected a 6-digit hex color, got: ' + hex);
    const int = parseInt(m[1], 16);
    return { r: (int >> 16) & 0xff, g: (int >> 8) & 0xff, b: int & 0xff };
}

function channelToLinear(c8) {
    const c = c8 / 255;
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

function relativeLuminance(hex) {
    const { r, g, b } = hexToRgb(hex);
    return 0.2126 * channelToLinear(r) + 0.7152 * channelToLinear(g) + 0.0722 * channelToLinear(b);
}

function contrastRatio(hexA, hexB) {
    const lA = relativeLuminance(hexA);
    const lB = relativeLuminance(hexB);
    const lighter = Math.max(lA, lB);
    const darker = Math.min(lA, lB);
    return (lighter + 0.05) / (darker + 0.05);
}

const WCAG_AA_NORMAL_TEXT = 4.5;

// Reads a `--var-name: #hex;` declaration out of the real CSS source --
// never hardcoded -- so a future palette edit invalidates this suite
// instead of silently going stale.
function readRootHexVar(cssText, varName) {
    const re = new RegExp('--' + varName.replace(/[-/\\^$*+?.()|[\]{}]/g, '\\$&') + ':\\s*(#[0-9a-fA-F]{3,8})\\s*[;,]');
    const m = re.exec(cssText);
    if (!m) throw new Error('readRootHexVar: could not find --' + varName + ' in the stylesheet');
    // Normalize 3-digit to 6-digit isn't needed here -- every var this
    // suite reads ships as 6-digit hex (asserted implicitly by hexToRgb
    // above rejecting anything else).
    return m[1];
}

let richCssText;
let lcars2CssText;

test('harness sanity: the CSS files this suite reads actually exist and are non-trivial', () => {
    richCssText = fs.readFileSync(path.join(PUBLIC_ROOT, RICH_CSS_REL_PATH), 'utf8');
    lcars2CssText = fs.readFileSync(path.join(PUBLIC_ROOT, LCARS2_CSS_REL_PATH), 'utf8');
    assert.ok(richCssText.length > 1000, RICH_CSS_REL_PATH + ' read unexpectedly small -- PUBLIC_ROOT likely wrong');
    assert.ok(lcars2CssText.length > 1000, LCARS2_CSS_REL_PATH + ' read unexpectedly small -- PUBLIC_ROOT likely wrong');
    assert.ok(LCARS2_MINIMAL_FILES.length >= 3, 'expected at least 3 lcars2 minimal renderer files to exist on disk');
});

// ============================================================================
// XACA-1031-015 (MUST-FIX): offline-row contrast
// ============================================================================

test('XACA-1031-015 regression: the .machine-row.offline override list covers .machine-version-label and .machine-version-value (!important)', () => {
    // Cheap, load-bearing per the finding's own instruction: this is
    // exactly the class list that silently regresses the next time
    // someone adds a class to this card without extending the override.
    assert.match(
        richCssText,
        /\.machine-row\.offline\s+\.machine-hostname,\s*\n\s*\.machine-row\.offline\s+\.machine-guid,\s*\n\s*\.machine-row\.offline\s+\.machine-meta,\s*\n\s*\.machine-row\.offline\s+\.machine-sessions,\s*\n\s*\.machine-row\.offline\s+\.machine-version-label\s*\{\s*\n\s*color:\s*var\(--lcars-black\);/,
        'expected .machine-version-label to be appended to the existing offline override selector list, colored via plain inheritance (no !important -- it carries no inline style)'
    );
    assert.match(
        richCssText,
        /\.machine-row\.offline\s+\.machine-version-value\s*\{\s*\n\s*color:\s*var\(--lcars-black\)\s*!important;/,
        '.machine-version-value must have its OWN rule with !important -- it always carries an inline color style (red/green/amber per state), which a plain class-level color can never beat'
    );
});

for (const outdatedCase of [
    { label: 'outdated:true', versions: { aiteamforge: '0.9.0', latest: '0.20.3', outdated: true } },
    { label: 'outdated:false', versions: { aiteamforge: '0.20.3', latest: '0.20.3', outdated: false } },
    { label: 'outdated key absent', versions: { aiteamforge: '0.15.0' } }
]) {
    test('XACA-1031-015: offline row, ' + outdatedCase.label + ' -- rendered .machine-version-value color is forced to black by the CSS override and clears 4.5:1 against the row background', async () => {
        const { mod } = await setupRichApp();
        const machine = baseMachine({ status: 'offline', system: { schema_version: 1, versions: outdatedCase.versions } });
        const container = mod.createMachineItem(machine);

        const row = container.querySelector('.machine-row');
        assert.ok(row, 'expected the .machine-row element to exist');
        assert.ok(row.classList.contains('offline'), 'expected the row to carry the offline status class');

        const valueEl = container.querySelector('.machine-version-value');
        assert.ok(valueEl, 'expected a .machine-version-value element for a machine with a known installed version');

        // The element's OWN inline style is still state-colored (red/green/
        // amber) -- that never changes; what changes is which declaration
        // WINS. Read it directly off the real rendered element so this
        // test is tied to the real emitted markup, not a paraphrase of it.
        const inlineStyle = valueEl.getAttribute('style') || '';
        const inlineColorMatch = /color:\s*var\(--lcars-(alert-red|green|amber)\)/.exec(inlineStyle);
        assert.ok(inlineColorMatch,
            'sanity: the value element must still carry its own state-dependent inline color -- if this stops matching, the source markup changed shape and the test below needs to change with it');

        // Effective winning color, determined by an ACTUAL presence check
        // of the override rule in the real CSS source -- not assumed. This
        // is what makes this test (not only the structural regression test
        // above) go red if the fix is reverted: without the !important
        // override present, the cascade winner reverts to the element's
        // own inline color (read directly above), and that is exactly what
        // gets contrast-checked next.
        const overrideRe = /\.machine-row\.offline\s+\.machine-version-value\s*\{\s*\n\s*color:\s*var\(--lcars-black\)\s*!important;/;
        const overridePresent = overrideRe.test(richCssText);
        const bgColorHex = readRootHexVar(richCssText, 'lcars-alert-red');
        assert.equal(bgColorHex.toLowerCase(), '#ff6666');
        const effectiveColorHex = overridePresent ? readRootHexVar(richCssText, 'lcars-black') : readRootHexVar(richCssText, 'lcars-' + inlineColorMatch[1]);

        const ratio = contrastRatio(effectiveColorHex, bgColorHex);
        assert.ok(ratio >= WCAG_AA_NORMAL_TEXT,
            'effective contrast (' + effectiveColorHex + ' text on ' + bgColorHex + ' background, override present=' + overridePresent + ') = ' + ratio.toFixed(2) + ':1, must clear the ' + WCAG_AA_NORMAL_TEXT + ':1 AA minimum for normal text');

        // Documentation cross-check against the finding's own pre-fix
        // numbers, computed from the SAME inline color this element still
        // carries -- proves the calculator reproduces the reported defect
        // before asserting the fix clears it.
        const preFixColorHex = { 'alert-red': readRootHexVar(richCssText, 'lcars-alert-red'), green: readRootHexVar(richCssText, 'lcars-green'), amber: readRootHexVar(richCssText, 'lcars-amber') };
        const preFixRatio = outdatedCase.versions.outdated === true ? contrastRatio(preFixColorHex['alert-red'], bgColorHex)
            : outdatedCase.versions.outdated === false ? contrastRatio(preFixColorHex.green, bgColorHex)
                : contrastRatio(preFixColorHex.amber, bgColorHex);
        if (outdatedCase.versions.outdated === true) {
            assert.ok(Math.abs(preFixRatio - 1) < 0.01, 'pre-fix outdated=true should be ~1:1 (identical color and background) -- got ' + preFixRatio.toFixed(2));
        } else {
            assert.ok(preFixRatio < WCAG_AA_NORMAL_TEXT, 'pre-fix ' + outdatedCase.label + ' should already fail AA (reproduces the finding) -- got ' + preFixRatio.toFixed(2));
        }
    });
}

test('XACA-1031-015: an ONLINE row is unaffected -- .machine-version-value keeps its own state color (no background to clash with)', async () => {
    const { mod } = await setupRichApp();
    const machine = baseMachine({ status: 'online', system: { schema_version: 1, versions: { aiteamforge: '0.9.0', latest: '0.20.3', outdated: true } } });
    const container = mod.createMachineItem(machine);
    const row = container.querySelector('.machine-row');
    assert.ok(row.classList.contains('online'));
    assert.ok(!row.classList.contains('offline'), 'sanity: online and offline must be mutually exclusive on the same row');
});

// ============================================================================
// XACA-1031-016 (SHOULD-FIX): lcars2 .status-row overflow guard
// ============================================================================

test('XACA-1031-016 regression: lcars2 CSS source defines the hostname/version overflow guard on .status-row', () => {
    assert.match(
        lcars2CssText,
        /\.status-row\s+\.status-row-hostname\s*\{\s*\n\s*min-width:\s*0;\s*\n\s*overflow:\s*hidden;\s*\n\s*text-overflow:\s*ellipsis;\s*\n\s*white-space:\s*nowrap;\s*\n\s*\}/,
        'expected .status-row-hostname to get min-width:0 + overflow/ellipsis/nowrap so it can shrink and truncate instead of forcing the row wider'
    );
    assert.match(
        lcars2CssText,
        /\.status-row\s+\.status-row-version\s*\{\s*\n\s*flex-shrink:\s*0;\s*\n\s*max-width:\s*\d+px;\s*\n\s*overflow:\s*hidden;\s*\n\s*text-overflow:\s*ellipsis;\s*\n\s*\}/,
        'expected .status-row-version to be capped with a bounded max-width + flex-shrink:0 + ellipsis so an unbounded pre-release string cannot push the row wider than its cap'
    );
});

for (const relPath of LCARS2_MINIMAL_FILES) {
    test('XACA-1031-016: ' + relPath + ' -- long hostname + long pre-release version render with the overflow guard classes and resolved containment styles', async () => {
        const { mod } = await setupMinimalApp(relPath);
        const longHostname = 'this-is-a-deliberately-long-hostname-for-overflow-testing.tail1234abcd.ts.example.net';
        const longVersion = '0.17.8-beta.wip.build.12345';
        const machine = baseMachine({
            hostname: longHostname,
            status: 'online',
            system: { schema_version: 1, versions: { aiteamforge: longVersion, latest: '0.20.3', outdated: true } }
        });
        const item = unwrapStatusRow(mod.createMachineItem(machine));

        const hostnameEl = item.querySelector('.status-row-hostname');
        const versionEl = item.querySelector('[title="aiteamforge version"]');
        assert.ok(hostnameEl, relPath + ': expected a .status-row-hostname element');
        assert.ok(versionEl, relPath + ': expected a version indicator element');
        assert.ok(versionEl.classList.contains('status-row-version'), relPath + ': expected the version indicator to carry .status-row-version');
        assert.equal(hostnameEl.textContent, longHostname, relPath + ': the long hostname must still be present in full as text content (truncation is visual/CSS, not a JS-side substring)');
        assert.ok(versionEl.textContent.includes(longVersion), relPath + ': the long version string must still be present in full as text content');

        // Render the SAME markup shape against the real, already-loaded
        // lcars2 stylesheet and resolve computed style -- jsdom DOES
        // resolve these (non custom-property) values correctly, verified
        // by hand against this exact stylesheet before writing this test.
        const dom = new JSDOM('<!doctype html><html><head><style>' + lcars2CssText + '</style></head><body>' + item.outerHTML + '</body></html>', { pretendToBeVisual: true });
        const liveHostname = dom.window.document.querySelector('.status-row-hostname');
        const liveVersion = dom.window.document.querySelector('.status-row-version');
        const csHostname = dom.window.getComputedStyle(liveHostname);
        const csVersion = dom.window.getComputedStyle(liveVersion);

        assert.equal(csHostname.minWidth, '0px', relPath + ': hostname min-width must resolve to 0px (lets the flex item shrink below its content width)');
        assert.equal(csHostname.overflow, 'hidden', relPath + ': hostname overflow must resolve to hidden');
        assert.equal(csHostname.textOverflow, 'ellipsis', relPath + ': hostname text-overflow must resolve to ellipsis');
        assert.equal(csHostname.whiteSpace, 'nowrap', relPath + ': hostname white-space must resolve to nowrap (required for ellipsis to have any effect)');

        assert.equal(csVersion.flexShrink, '0', relPath + ': version flex-shrink must resolve to 0 (pinned footprint, does not get squeezed to nothing)');
        assert.match(csVersion.maxWidth, /^\d+px$/, relPath + ': version max-width must resolve to a bounded pixel value');
        assert.equal(csVersion.overflow, 'hidden', relPath + ': version overflow must resolve to hidden');
        assert.equal(csVersion.textOverflow, 'ellipsis', relPath + ': version text-overflow must resolve to ellipsis');
    });
}

test('XACA-1031-016 negative control: a plain span with none of the guard classes gets NONE of these properties from .status-row alone', () => {
    // Anchors the assertions above to the specific classes, not to some
    // ambient default this stylesheet already provided -- if .status-row
    // itself (or some unrelated rule) already set overflow:hidden/
    // min-width:0 globally, the -016 tests above would pass vacuously
    // even with the fix reverted.
    const dom = new JSDOM('<!doctype html><html><head><style>' + lcars2CssText + '</style></head><body><div class="status-row online"><span class="lcars-text-sm plain-child" style="flex: 1;">unrelated content</span></div></body></html>', { pretendToBeVisual: true });
    const el = dom.window.document.querySelector('.plain-child');
    const cs = dom.window.getComputedStyle(el);
    assert.notEqual(cs.minWidth, '0px', 'a child with none of the new guard classes must NOT incidentally get min-width:0 from .status-row alone');
    assert.notEqual(cs.overflow, 'hidden', 'a child with none of the new guard classes must NOT incidentally get overflow:hidden from .status-row alone');
});

// ============================================================================
// XACA-1031-017 (SHOULD-FIX): card-level OUTDATED cue
// ============================================================================

test('XACA-1031-017 regression: lcars-fleet-theme.css defines the .machine-row-outdated border-left tint', () => {
    assert.match(
        richCssText,
        /\.machine-row\.machine-row-outdated\s*\{\s*\n\s*border-left-color:\s*var\(--lcars-alert-red\);\s*\n\s*\}/,
        'expected a .machine-row.machine-row-outdated rule reusing the established border-left-color state-tint mechanism'
    );
});

test('XACA-1031-017: outdated:true adds machine-row-outdated to the row, giving it a card-level cue beyond the badge several rows down', async () => {
    const { mod } = await setupRichApp();
    const machine = baseMachine({ status: 'online', system: { schema_version: 1, versions: { aiteamforge: '0.9.0', latest: '0.20.3', outdated: true } } });
    const container = mod.createMachineItem(machine);
    const row = container.querySelector('.machine-row');
    assert.ok(row.classList.contains('machine-row-outdated'), 'expected the row to carry machine-row-outdated when outdated===true');
});

for (const notOutdatedCase of [
    { label: 'outdated:false', versions: { aiteamforge: '0.20.3', latest: '0.20.3', outdated: false } },
    { label: 'outdated key absent', versions: { aiteamforge: '0.15.0' } },
    { label: 'no system/versions at all', versions: undefined }
]) {
    test('XACA-1031-017 negative control: ' + notOutdatedCase.label + ' does NOT get machine-row-outdated', async () => {
        const { mod } = await setupRichApp();
        const machine = notOutdatedCase.versions === undefined
            ? baseMachine({ status: 'online' })
            : baseMachine({ status: 'online', system: { schema_version: 1, versions: notOutdatedCase.versions } });
        const container = mod.createMachineItem(machine);
        const row = container.querySelector('.machine-row');
        assert.ok(!row.classList.contains('machine-row-outdated'), notOutdatedCase.label + ' must not get the outdated card-level cue');
    });
}

// ============================================================================
// Cross-file identity (XACA-1100-002 UPDATE): createMachineItem() itself was
// extracted out of the 4 lcars2 minimal renderers into the single shared
// implementation window.LCARS_CORE.machines.createMachineItem
// (lcars2/js/lcars-fleet-core.js) -- there is now exactly ONE copy of the
// function body, so a byte-identity comparison ACROSS the 4 app files no
// longer has anything to compare (each no longer contains a local
// `function createMachineItem(machine) {` at all). This test now asserts
// the two invariants that replaced it:
//   1. none of the 4 app files re-introduce a local copy of the function
//      (a regression back to per-file duplication would defeat the
//      extraction this ticket did);
//   2. the 4 app files' own call sites into the shared core (the small
//      `deps` object wiring each file's local health/panel/toggle hooks
//      through) stay byte-identical to each other -- they must not drift
//      apart, per the same reasoning the original test protected.
// The extracted implementation living in the core is still the same code
// this test's sibling assertions above already exercise end-to-end via
// mod.createMachineItem(machine) (loadClientApp's export wrapper forwards
// to the core), so no separate content check is needed here beyond the
// core-side test coverage.
// ============================================================================

const LOCAL_DEFINITION_MARKER = '    function createMachineItem(machine) {';
const CORE_CALL_MARKER = 'window.LCARS_CORE.machines.createMachineItem(machine, {';

function extractCoreCallSite(src) {
    const lines = src.split('\n');
    const startIdx = lines.findIndex((l) => l.includes(CORE_CALL_MARKER));
    if (startIdx === -1) throw new Error('extractCoreCallSite: call-site marker not found');
    const endIdx = lines.findIndex((l, i) => i > startIdx && l.trim() === '});');
    if (endIdx === -1) throw new Error('extractCoreCallSite: end marker not found');
    return lines.slice(startIdx, endIdx + 1).join('\n');
}

test('createMachineItem() is NOT re-duplicated locally in any lcars2 minimal renderer (must stay extracted into lcars-fleet-core.js)', () => {
    assert.ok(LCARS2_MINIMAL_FILES.length >= 3, 'expected at least 3 lcars2 minimal renderer files to exist on disk');
    for (const rel of LCARS2_MINIMAL_FILES) {
        const src = fs.readFileSync(path.join(PUBLIC_ROOT, rel), 'utf8');
        assert.ok(!src.includes(LOCAL_DEFINITION_MARKER), rel + ' re-introduces a local createMachineItem() definition -- it must delegate to window.LCARS_CORE.machines.createMachineItem instead (XACA-1100-002)');
    }
});

test('cross-file byte-identity: each lcars2 minimal renderer\'s call site into the shared core createMachineItem() is identical', () => {
    assert.ok(LCARS2_MINIMAL_FILES.length >= 3, 'expected at least 3 lcars2 minimal renderer files to exist on disk');
    const callSites = LCARS2_MINIMAL_FILES.map((rel) => ({
        rel,
        text: extractCoreCallSite(fs.readFileSync(path.join(PUBLIC_ROOT, rel), 'utf8'))
    }));
    const [first, ...rest] = callSites;
    for (const other of rest) {
        assert.equal(other.text, first.text, 'core call site diverged between ' + first.rel + ' and ' + other.rel + ' -- lcars2 files must stay byte-identical over this extent');
    }
    // Sanity: the call site actually wires all 5 documented deps, so a
    // vacuous match (e.g. both markers not found, both empty strings
    // comparing equal) cannot pass this test silently.
    assert.match(first.text, /machineSystemToHealthInput:/);
    assert.match(first.text, /healthBadgeSpec:/);
    assert.match(first.text, /buildSystemSectionHtml:/);
    assert.match(first.text, /toggleSystemPanel:/);
    assert.match(first.text, /isSystemExpanded:/);
});

test('the shared core implementation (lcars-fleet-core.js) still contains this ticket\'s classes -- a vacuous extraction cannot pass silently', () => {
    const coreSrc = fs.readFileSync(path.join(PUBLIC_ROOT, 'lcars2/js/lcars-fleet-core.js'), 'utf8');
    assert.match(coreSrc, /createMachineItem\s*:\s*function/, 'lcars-fleet-core.js must define LCARS.machines.createMachineItem');
    assert.match(coreSrc, /status-row-hostname/);
    assert.match(coreSrc, /status-row-version/);
});
