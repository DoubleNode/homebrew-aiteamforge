//
//  xaca-1092-021-022-ux-mustfix.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * Regression coverage for the two [UX] MUST-FIX findings the gate filed
 * against PR #822 (XACA-1092's system-telemetry cards), plus their fix.
 *
 *   XACA-1092-021 (WCAG 2.1.1 Keyboard, Level A): the SYSTEM disclosure
 *   toggle in all 5 renderers (.status-row-system-toggle in the 4 lcars2
 *   files, .machine-system-status in v1) shipped as a plain clickable <div>
 *   with no tabindex, no role=button, no keydown handler, and no
 *   aria-expanded. Fixed by mirroring the existing keyboard-activation
 *   shape already used for the LCARS-terminal card (see
 *   card.setAttribute('tabindex', '0') / the keydown block near
 *   XACA-0983-014 in every one of these same 5 files) -- tabindex="0",
 *   role="button", aria-expanded reflecting the real .expanded state (kept
 *   in sync on every open/close, not just set once at render time), and
 *   Enter/Space activation with Space's default (page scroll) prevented.
 *
 *   XACA-1092-022 (WCAG 1.4.3 AA contrast): the muted "not reported" field
 *   values (.machine-system-row-value-empty) and the "SYSTEM: NO DATA
 *   REPORTED" line (.status-row-system-no-data in lcars2,
 *   .machine-system-no-data in v1) used opacity:0.5/0.6 tan text, which
 *   blends to well under the 4.5:1 AA minimum against their real
 *   backgrounds. Fixed by raising the opacity high enough to clear 4.5:1
 *   with margin -- see the per-selector comments below for exactly which
 *   background each class actually composites onto (they are NOT all the
 *   same: lcars2's no-data line sits on the page background var(--lcars-
 *   black), v1's sits on .machine-row's var(--lcars-dark), and both
 *   -value-empty classes sit on their SYSTEM panel's var(--lcars-darker)).
 *
 * ── Method ────────────────────────────────────────────────────────────────
 * XACA-1092-021 renders createMachineItem() through the REAL shipped client
 * files via tests/helpers/lcars-client-dom-stub.js (same discipline as
 * tests/xaca-0983-013-014-015-lcars-card-ux.test.js's keyboard-access
 * suite, which this file's assertions are deliberately modeled on) and
 * dispatches real keydown events at the toggle node the production code
 * itself attached the listener to.
 *
 * XACA-1092-022 reads the REAL shipped CSS text off disk (never a
 * hardcoded hex/opacity guess) and applies a hand-written WCAG relative-
 * luminance/contrast calculator plus a standard alpha-compositing blend --
 * same "read real source, compute by hand" method
 * tests/xaca-1031-015-016-017-ux-followups.test.js uses for its own
 * contrast proof (that file's helpers are not imported here; this file
 * re-implements its own small copy, matching that file's own precedent of
 * not leaning on a prior suite's private helpers).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createDomStub, loadClientApp } = require('./helpers/lcars-client-dom-stub.js');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');

// XACA-1110-005/-009: the 4 former lcars2 minimal renderers collapsed into
// ONE config-parameterized module. createMachineItem() itself lives in the
// shared core (lcars-fleet-core.js) and does not depend on CONFIG.
const LCARS2_APP_FILES_ALL = [
    'lcars2/js/lcars-fleet-dashboard-app.js'
];
const LCARS2_APP_FILES = LCARS2_APP_FILES_ALL.filter((rel) => fs.existsSync(path.join(PUBLIC_ROOT, rel)));
const RICH_APP_FILE = 'lcars/js/lcars-dashboard-app.js';
const ALL_APP_FILES = LCARS2_APP_FILES.concat([RICH_APP_FILE]);

const LCARS2_CSS_FILE = 'lcars2/css/lcars-fleet-theme.css';
const RICH_CSS_FILE = 'lcars/css/lcars-fleet-theme.css';

// A machine whose system{} block populates every health group, so
// buildSystemSectionHtml() takes the "real interactive toggle" branch
// (groupsHtml !== '') in every renderer -- not the static no-data line,
// which carries no toggle at all by design (already covered by
// tests/xaca-1092-006-degradation-adversarial.test.js's VersionsOnlyDayOne
// case, unaffected by this ticket).
function interactiveMachine(overrides) {
    return Object.assign(
        {
            machine_id: '11111111-2222-4333-8444-555555555555',
            hostname: 'must-fix-021.example.test',
            nickname: 'MustFix021',
            ip: '192.0.2.42',
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
        },
        overrides
    );
}

// A machine with NO `system` key at all -- the no-toggle path -- used only
// for the negative control confirming the static no-data state never gains
// a false keyboard affordance.
function noSystemMachine(overrides) {
    const m = interactiveMachine(overrides);
    delete m.system;
    return m;
}

// Locates the SYSTEM toggle node + the scope its own keydown/click handler
// operates on ("item" for v1, "detail" for lcars2), using the SAME
// selector/traversal the production code itself uses, so a test dispatch
// against the returned node invokes the REAL listener the renderer
// attached -- not a lookalike found by some other path.
function renderAndFindToggle(relPath, mod, machine) {
    const result = mod.createMachineItem(machine);
    if (relPath === RICH_APP_FILE) {
        // v1: createMachineItem() returns the container element directly;
        // container.children[0] is `item` (the .machine-row), which is
        // also what createMachineItem()'s own code now queries from (see
        // XACA-1092-021's comment at the systemToggle call site).
        const item = result.children[0];
        assert.ok(item, 'v1 createMachineItem() must return a container whose first child is the machine row');
        const toggle = item.querySelector('.machine-system-status');
        return { scope: item, toggle };
    }
    // lcars2: createMachineItem() returns a DocumentFragment whose second
    // child is the sibling `.status-row-detail` block (see XACA-1092-004/
    // -005's own comment on why the detail block is a sibling, not a
    // child, of `.status-row`) -- but ONLY when buildSystemSectionHtml()
    // produced non-empty HTML. A machine with no `system` key at all (the
    // negative-control case) has NO detail sibling whatsoever, so `result.
    // children[1]` is legitimately undefined here, not a bug.
    assert.ok(result && Array.isArray(result.children), 'lcars2 createMachineItem() must return a fragment-like object with .children');
    const detail = result.children[1] || null;
    const toggle = detail ? detail.querySelector('.status-row-system-toggle') : null;
    return { scope: detail, toggle };
}

function panelAndIndicatorSelectors(relPath) {
    return relPath === RICH_APP_FILE
        ? { panel: '.machine-system-details-panel', indicator: '.system-expand-indicator' }
        : { panel: '.status-row-system-panel', indicator: '.status-row-system-indicator' };
}

// ============================================================================
// XACA-1092-021: keyboard accessibility of the SYSTEM toggle
// ============================================================================

ALL_APP_FILES.forEach((relPath) => {
    test(`XACA-1092-021: SYSTEM toggle is focusable and carries role=button (${relPath})`, () => {
        const { ctx } = createDomStub();
        const mod = loadClientApp(relPath, ctx);
        const { toggle } = renderAndFindToggle(relPath, mod, interactiveMachine());

        assert.ok(toggle, 'expected an interactive SYSTEM toggle node for a machine with populated health groups');
        assert.equal(toggle.getAttribute('tabindex'), '0');
        assert.equal(toggle.getAttribute('role'), 'button');
    });

    test(`XACA-1092-021: SYSTEM toggle starts aria-expanded="false" when its panel starts collapsed (${relPath})`, () => {
        const { ctx } = createDomStub();
        const mod = loadClientApp(relPath, ctx);
        const { toggle } = renderAndFindToggle(relPath, mod, interactiveMachine());

        assert.equal(toggle.getAttribute('aria-expanded'), 'false');
    });

    test(`XACA-1092-021: Enter opens the panel, sets aria-expanded="true", and its default is prevented (${relPath})`, () => {
        const { ctx } = createDomStub();
        const mod = loadClientApp(relPath, ctx);
        const { scope, toggle } = renderAndFindToggle(relPath, mod, interactiveMachine());
        const { panel, indicator } = panelAndIndicatorSelectors(relPath);

        const evt = toggle.dispatch('keydown', { key: 'Enter', keyCode: 13 });

        assert.equal(evt.defaultPrevented, true, 'Enter must call preventDefault, matching the LCARS-terminal card precedent');
        assert.equal(toggle.getAttribute('aria-expanded'), 'true', 'aria-expanded must flip to true once the panel is open');
        assert.ok(scope.querySelector(panel).classList.contains('expanded'), 'the panel itself must gain .expanded');
        assert.ok(scope.querySelector(indicator).classList.contains('expanded'), 'the chevron indicator must gain .expanded too');
    });

    test(`XACA-1092-021: Space toggles the SAME open panel closed again, sets aria-expanded="false", and its default is prevented (so Space never scrolls the page) (${relPath})`, () => {
        const { ctx } = createDomStub();
        const mod = loadClientApp(relPath, ctx);
        const { scope, toggle } = renderAndFindToggle(relPath, mod, interactiveMachine());
        const { panel, indicator } = panelAndIndicatorSelectors(relPath);

        toggle.dispatch('keydown', { key: 'Enter', keyCode: 13 }); // open first
        const evt = toggle.dispatch('keydown', { key: ' ', keyCode: 32 }); // close via Space

        assert.equal(evt.defaultPrevented, true, 'Space must be prevented so it does not scroll the page');
        assert.equal(toggle.getAttribute('aria-expanded'), 'false', 'aria-expanded must flip back to false once the panel is closed');
        assert.ok(!scope.querySelector(panel).classList.contains('expanded'), 'the panel must lose .expanded on close');
        assert.ok(!scope.querySelector(indicator).classList.contains('expanded'), 'the chevron indicator must lose .expanded too');
    });

    test(`XACA-1092-021: an irrelevant key neither toggles the panel nor calls preventDefault (${relPath})`, () => {
        const { ctx } = createDomStub();
        const mod = loadClientApp(relPath, ctx);
        const { scope, toggle } = renderAndFindToggle(relPath, mod, interactiveMachine());
        const { panel } = panelAndIndicatorSelectors(relPath);

        const evt = toggle.dispatch('keydown', { key: 'a', keyCode: 65 });

        assert.equal(evt.defaultPrevented, false);
        assert.equal(toggle.getAttribute('aria-expanded'), 'false');
        assert.ok(!scope.querySelector(panel).classList.contains('expanded'));
    });

    test(`XACA-1092-021 negative control: the static "SYSTEM: NO DATA REPORTED" line (no health groups) never gains a false keyboard affordance (${relPath})`, () => {
        const { ctx } = createDomStub();
        const mod = loadClientApp(relPath, ctx);
        const { toggle } = renderAndFindToggle(relPath, mod, noSystemMachine());

        assert.equal(toggle, null, 'a machine with no `system` key at all has no SYSTEM section, let alone an interactive toggle');
    });
});

// ============================================================================
// XACA-1092-022: contrast of the muted SYSTEM-panel text
// ============================================================================
// WCAG 2.x relative luminance / contrast ratio, and standard "over" alpha
// compositing -- textbook implementations applied only to hex/opacity
// values read out of the real CSS files below, never hardcoded, so a
// future palette or opacity edit is what this suite would catch.
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

function relativeLuminance({ r, g, b }) {
    return 0.2126 * channelToLinear(r) + 0.7152 * channelToLinear(g) + 0.0722 * channelToLinear(b);
}

function contrastRatio(rgbA, rgbB) {
    const lA = relativeLuminance(rgbA);
    const lB = relativeLuminance(rgbB);
    const lighter = Math.max(lA, lB);
    const darker = Math.min(lA, lB);
    return (lighter + 0.05) / (darker + 0.05);
}

// Standard "source-over" alpha compositing of a semi-transparent
// foreground directly onto an opaque background -- exactly what `color:
// var(--x); opacity: N;` on an element with no background of its own
// produces once the browser paints it.
function blendOver(fg, bg, alpha) {
    return {
        r: alpha * fg.r + (1 - alpha) * bg.r,
        g: alpha * fg.g + (1 - alpha) * bg.g,
        b: alpha * fg.b + (1 - alpha) * bg.b
    };
}

const WCAG_AA_NORMAL_TEXT = 4.5;

// Reads a `--var-name: #hex;` declaration out of the real CSS source --
// never hardcoded -- so a future palette edit invalidates this suite
// instead of silently going stale.
function readRootHexVar(cssText, varName) {
    const re = new RegExp('--' + varName + ':\\s*(#[0-9a-fA-F]{6})\\s*[;,]');
    const m = re.exec(cssText);
    if (!m) throw new Error('readRootHexVar: could not find --' + varName + ' in the stylesheet');
    return m[1];
}

// Reads the `opacity: N;` declaration out of ONE specific selector's real
// CSS rule block (not the first `opacity:` anywhere in the file -- these
// stylesheets define `opacity` on many unrelated selectors).
function readSelectorOpacity(cssText, selector) {
    const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const blockRe = new RegExp(escaped + '\\s*\\{([^}]*)\\}');
    const blockMatch = blockRe.exec(cssText);
    if (!blockMatch) throw new Error('readSelectorOpacity: could not find rule block for ' + selector);
    const opacityMatch = /opacity:\s*([0-9.]+)\s*;/.exec(blockMatch[1]);
    if (!opacityMatch) throw new Error('readSelectorOpacity: no opacity declaration inside ' + selector + '\'s rule block');
    return parseFloat(opacityMatch[1]);
}

let lcars2CssText;
let richCssText;

test('XACA-1092-022 harness sanity: both real stylesheets this suite reads exist and are non-trivial', () => {
    lcars2CssText = fs.readFileSync(path.join(PUBLIC_ROOT, LCARS2_CSS_FILE), 'utf8');
    richCssText = fs.readFileSync(path.join(PUBLIC_ROOT, RICH_CSS_FILE), 'utf8');
    assert.ok(lcars2CssText.length > 1000, LCARS2_CSS_FILE + ' read unexpectedly small -- PUBLIC_ROOT likely wrong');
    assert.ok(richCssText.length > 1000, RICH_CSS_FILE + ' read unexpectedly small -- PUBLIC_ROOT likely wrong');
});

// ── lcars2: .machine-system-row-value-empty on its SYSTEM panel's
//    var(--lcars-darker) background ──────────────────────────────────────
test('XACA-1092-022: lcars2 .machine-system-row-value-empty clears 4.5:1 against var(--lcars-darker)', () => {
    const tan = hexToRgb(readRootHexVar(lcars2CssText, 'lcars-tan'));
    const darker = hexToRgb(readRootHexVar(lcars2CssText, 'lcars-darker'));
    const opacity = readSelectorOpacity(lcars2CssText, '.machine-system-row-value-empty');

    // Pin the exact value this fix computed and shipped -- not just "some
    // value that happens to pass today" -- so a future edit that changes
    // the number without recomputing contrast is caught even if it
    // happens to still clear 4.5:1 by coincidence.
    assert.equal(opacity, 0.75, 'expected the computed opacity:0.75 fix, not the pre-fix 0.5 or an unreviewed value');

    const oldRatio = contrastRatio(blendOver(tan, darker, 0.5), darker);
    const newRatio = contrastRatio(blendOver(tan, darker, opacity), darker);

    assert.ok(oldRatio < WCAG_AA_NORMAL_TEXT, 'sanity: the pre-fix opacity:0.5 must actually fail 4.5:1 (was ~2.6-2.7:1), or this is not testing what it claims to');
    assert.ok(newRatio >= WCAG_AA_NORMAL_TEXT, `computed contrast ${newRatio.toFixed(2)}:1 must clear the ${WCAG_AA_NORMAL_TEXT}:1 AA minimum`);
});

// ── lcars2: .status-row-system-no-data on the PAGE background
//    var(--lcars-black), NOT the panel's var(--lcars-darker) -- this line
//    is a sibling of `.status-row`, not a child of `.status-row-system-
//    panel` (see XACA-1092-004/-005's DocumentFragment comment) ──────────
test('XACA-1092-022: lcars2 .status-row-system-no-data clears 4.5:1 against var(--lcars-black)', () => {
    const tan = hexToRgb(readRootHexVar(lcars2CssText, 'lcars-tan'));
    const black = hexToRgb(readRootHexVar(lcars2CssText, 'lcars-black'));
    const opacity = readSelectorOpacity(lcars2CssText, '.status-row-system-no-data');

    assert.equal(opacity, 0.75, 'expected the computed opacity:0.75 fix, not the pre-fix 0.6 or an unreviewed value');

    const oldRatio = contrastRatio(blendOver(tan, black, 0.6), black);
    const newRatio = contrastRatio(blendOver(tan, black, opacity), black);

    assert.ok(oldRatio < WCAG_AA_NORMAL_TEXT, 'sanity: the pre-fix opacity:0.6 must actually fail 4.5:1 (was ~3.3-3.4:1), or this is not testing what it claims to');
    assert.ok(newRatio >= WCAG_AA_NORMAL_TEXT, `computed contrast ${newRatio.toFixed(2)}:1 must clear the ${WCAG_AA_NORMAL_TEXT}:1 AA minimum`);
});

// ── v1: .machine-system-row-value-empty on its SYSTEM panel's
//    var(--lcars-darker) background -- same background as lcars2's copy ──
test('XACA-1092-022: v1 .machine-system-row-value-empty clears 4.5:1 against var(--lcars-darker)', () => {
    const tan = hexToRgb(readRootHexVar(richCssText, 'lcars-tan'));
    const darker = hexToRgb(readRootHexVar(richCssText, 'lcars-darker'));
    const opacity = readSelectorOpacity(richCssText, '.machine-system-row-value-empty');

    assert.equal(opacity, 0.75, 'expected the computed opacity:0.75 fix, not the pre-fix 0.5 or an unreviewed value');

    const oldRatio = contrastRatio(blendOver(tan, darker, 0.5), darker);
    const newRatio = contrastRatio(blendOver(tan, darker, opacity), darker);

    assert.ok(oldRatio < WCAG_AA_NORMAL_TEXT, 'sanity: the pre-fix opacity:0.5 must actually fail 4.5:1 (was ~2.6-2.7:1), or this is not testing what it claims to');
    assert.ok(newRatio >= WCAG_AA_NORMAL_TEXT, `computed contrast ${newRatio.toFixed(2)}:1 must clear the ${WCAG_AA_NORMAL_TEXT}:1 AA minimum`);
});

// ── v1: .machine-system-no-data on `.machine-row`'s var(--lcars-dark)
//    background -- UNLIKE lcars2's copy, this line is baked directly into
//    `.machine-row`'s own innerHTML (no sibling container wraps the
//    no-data case), so it composites onto a LIGHTER background than
//    lcars2's page-black, and needs a higher opacity to compensate ───────
test('XACA-1092-022: v1 .machine-system-no-data clears 4.5:1 against var(--lcars-dark), the lighter of the two no-data backgrounds', () => {
    const tan = hexToRgb(readRootHexVar(richCssText, 'lcars-tan'));
    const dark = hexToRgb(readRootHexVar(richCssText, 'lcars-dark'));
    const opacity = readSelectorOpacity(richCssText, '.machine-system-no-data');

    assert.equal(opacity, 0.8, 'expected the computed opacity:0.8 fix (higher than the other 3 selectors, because this background is lighter), not the pre-fix 0.6 or an unreviewed value');

    const oldRatio = contrastRatio(blendOver(tan, dark, 0.6), dark);
    const newRatio = contrastRatio(blendOver(tan, dark, opacity), dark);

    assert.ok(oldRatio < WCAG_AA_NORMAL_TEXT, 'sanity: the pre-fix opacity:0.6 must actually fail 4.5:1 (was ~3.2-3.3:1), or this is not testing what it claims to');
    assert.ok(newRatio >= WCAG_AA_NORMAL_TEXT, `computed contrast ${newRatio.toFixed(2)}:1 must clear the ${WCAG_AA_NORMAL_TEXT}:1 AA minimum`);
});
