//
//  xaca-1474-sidebar-button-color-rule.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1474 regression guard -- every Fleet Monitor sidebar button must have a
 * colour rule.
 *
 * A `.sidebar-button` with no `[data-section="X"]` background rule is
 * transparent and paints whatever the sidebar frame is, so it reads as blank
 * space rather than a button. This has now happened twice: ANALYTICS
 * (XACA-0963 follow-up) and CI/CD (XACA-1388 added the button, XACA-1474 fixed
 * the missing rule). The same omission also loses the inverted `.active`
 * state (black background, coloured text).
 *
 * Method: pure source inspection (no jsdom, no layout). Reads the REAL shipped
 * lcars/lcars-dashboard.html and lcars/css/lcars-fleet.css, derives the set of
 * sidebar sections from the HTML (never a hand-kept list, so a newly added
 * button is covered automatically), and asserts each has
 *   (1) a `.sidebar-button[data-section="X"]` rule declaring a background, and
 *   (2) a `.sidebar-button[data-section="X"].active` rule declaring a background.
 *
 * It also asserts (3) the base background is NOT the sidebar frame's colour.
 * The frame is painted by lcars-fleet-theme.css with --fleet-body-primary, so a
 * button coloured to match it is exactly as invisible as one with no rule --
 * the first XACA-1474 fix chose blue, which is that colour, and only a render
 * caught it. The frame colour is read from the theme file, not hard-coded, and
 * both sides are RESOLVED before comparing (var() chains followed through the
 * stylesheets' custom properties, whitespace/case normalised, #rgb expanded),
 * so `#9999ff`, `#99F` or `var( --lcars-blue )` are caught as well as the
 * exact token the theme uses (XACA-1474-008).
 *
 * Vacuous-green guard: the discovered-section count has a floor, and the
 * parser is itself exercised against known-good and known-bad CSS.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');
const HTML = path.join(PUBLIC_ROOT, 'lcars', 'lcars-dashboard.html');
const CSS = path.join(PUBLIC_ROOT, 'lcars', 'css', 'lcars-fleet.css');
const THEME_CSS = path.join(PUBLIC_ROOT, 'lcars', 'css', 'lcars-fleet-theme.css');

// Sections that legitimately have no colour rule of their own. Empty on
// purpose: add a section here ONLY with a comment saying why it is exempt.
const NO_COLOR_RULE_ALLOWLIST = new Set([]);

// Any element type (div today; a future <button>/<a> must not slip past).
function sidebarSections(html) {
    const sections = [];
    const re = /<[a-z][a-z0-9-]*\b[^>]*\bclass="([^"]*)"[^>]*>/gi;
    let m;
    while ((m = re.exec(html)) !== null) {
        if (!/(^|\s)sidebar-button(\s|$)/.test(m[1])) continue;
        const s = /\bdata-section="([^"]+)"/.exec(m[0]);
        if (s) sections.push(s[1]);
    }
    return sections;
}

// True when `css` has a rule whose selector list contains exactly `selector`
// and whose body declares a `background` (shorthand or longhand).
function hasBackgroundRule(css, selector) {
    const stripped = css.replace(/\/\*[\s\S]*?\*\//g, '');
    const re = /([^{}]+)\{([^{}]*)\}/g;
    let m;
    while ((m = re.exec(stripped)) !== null) {
        const selectors = m[1].split(',').map((s) => s.trim());
        if (selectors.includes(selector) && /(^|[;\s])background(-color)?\s*:/.test(m[2])) return true;
    }
    return false;
}

// The `background` value of the LAST rule whose selector list contains exactly
// `selector` (later rules win), or null when there is none.
function backgroundValue(css, selector) {
    const stripped = css.replace(/\/\*[\s\S]*?\*\//g, '');
    const re = /([^{}]+)\{([^{}]*)\}/g;
    let m;
    let value = null;
    while ((m = re.exec(stripped)) !== null) {
        const selectors = m[1].split(',').map((s) => s.trim());
        if (!selectors.includes(selector)) continue;
        const d = /(?:^|[;\s])background(?:-color)?\s*:\s*([^;]+)/.exec(m[2]);
        if (d) value = d[1].trim();
    }
    return value;
}

// Custom-property defaults across `sheets`, in load order. The FIRST definition
// of a name wins: that is the :root default, and later ones live in media or
// org-override blocks that do not apply to the default render.
function customProperties(...sheets) {
    const vars = new Map();
    for (const sheet of sheets) {
        const re = /(--[a-z0-9-]+)\s*:\s*([^;{}]+);/gi;
        let m;
        while ((m = re.exec(sheet.replace(/\/\*[\s\S]*?\*\//g, ''))) !== null) {
            const name = m[1].toLowerCase();
            if (!vars.has(name)) vars.set(name, m[2].trim());
        }
    }
    return vars;
}

// Resolve a CSS colour value to a comparable form: follows var() chains (and
// their fallbacks), lower-cases, collapses whitespace and expands #rgb to
// #rrggbb. Returns null for an unresolvable var() with no fallback.
function resolveColor(value, vars, depth = 0) {
    if (value == null || depth > 10) return null;
    const v = value.trim().toLowerCase().replace(/\s+/g, ' ');
    const ref = /^var\(\s*(--[a-z0-9-]+)\s*(?:,\s*(.+?))?\s*\)$/.exec(v);
    if (ref) {
        if (vars.has(ref[1])) return resolveColor(vars.get(ref[1]), vars, depth + 1);
        return ref[2] === undefined ? null : resolveColor(ref[2], vars, depth + 1);
    }
    const short = /^#([0-9a-f])([0-9a-f])([0-9a-f])$/.exec(v);
    if (short) return `#${short[1]}${short[1]}${short[2]}${short[2]}${short[3]}${short[3]}`;
    return v;
}

const html = fs.readFileSync(HTML, 'utf8');
const css = fs.readFileSync(CSS, 'utf8');
const vars = customProperties(fs.readFileSync(THEME_CSS, 'utf8'), css);
const frameColor = resolveColor('var(--fleet-body-primary)', vars);
const sections = sidebarSections(html);

test('harness sanity: sidebar sections were discovered (not vacuous)', () => {
    assert.ok(sections.length >= 6, `expected >= 6 sidebar buttons in lcars-dashboard.html, found ${sections.length}`);
    assert.ok(sections.includes('cicd'), 'the CI/CD button (the XACA-1474 subject) must be discovered');
    assert.equal(new Set(sections).size, sections.length, 'duplicate data-section on sidebar buttons');
});

test('harness sanity: sidebarSections finds buttons of any element type', () => {
    const sample = '<div class="sidebar-button" data-section="a"></div>' +
        '<button type="button" class="sidebar-button active" data-section="b"></button>' +
        '<a href="#" class="sidebar-button" data-section="c"></a>' +
        '<div class="sidebar-button-group" data-section="no"></div>';
    assert.deepEqual(sidebarSections(sample), ['a', 'b', 'c']);
});

test('harness sanity: hasBackgroundRule distinguishes present from absent', () => {
    const sample = '/* .sidebar-button[data-section="ghost"] { background: red; } */\n' +
        '.sidebar-button[data-section="a"] { background: var(--x); }\n' +
        '.sidebar-button[data-section="b"] { color: red; }\n' +
        '.sidebar-button[data-section="c"].active, .other { background: #000; }';
    assert.equal(hasBackgroundRule(sample, '.sidebar-button[data-section="a"]'), true);
    assert.equal(hasBackgroundRule(sample, '.sidebar-button[data-section="b"]'), false, 'no background declared');
    assert.equal(hasBackgroundRule(sample, '.sidebar-button[data-section="ghost"]'), false, 'commented-out rule must not count');
    assert.equal(hasBackgroundRule(sample, '.sidebar-button[data-section="c"].active'), true, 'selector lists are split');
});

test('harness sanity: the sidebar frame colour was discovered (not vacuous)', () => {
    assert.match(String(frameColor), /^#[0-9a-f]{6}$/, `--fleet-body-primary did not resolve to a hex colour (got ${frameColor})`);
    // Every spelling of the frame colour must resolve to the same value.
    const blue = resolveColor('var(--lcars-blue)', vars);
    assert.equal(blue, frameColor, 'the frame is expected to be --lcars-blue; update this sanity check if the theme changed');
    for (const spelling of [blue.toUpperCase(), `#${blue[1]}${blue[3]}${blue[5]}`, 'var( --lcars-blue )', 'VAR(--LCARS-BLUE)', `var(--no-such-var, ${blue})`]) {
        if (spelling.length === 4 && !/^#(.)\1(.)\2(.)\3$/.test(blue)) continue; // #rgb only exists for doubled digits
        assert.equal(resolveColor(spelling, vars), frameColor, `"${spelling}" must resolve to the frame colour`);
    }
    assert.equal(resolveColor('var(--no-such-var)', vars), null);
    assert.notEqual(resolveColor('var(--lcars-teal)', vars), frameColor);
    const sample = '.b[x="1"] { background: red; }\n.b[x="1"] { color: #000; background: var(--y); }';
    assert.equal(backgroundValue(sample, '.b[x="1"]'), 'var(--y)', 'the later rule wins');
    assert.equal(backgroundValue(sample, '.b[x="2"]'), null);
});

for (const section of sections) {
    if (NO_COLOR_RULE_ALLOWLIST.has(section)) continue;
    test(`XACA-1474: sidebar button "${section}" has a background rule and an .active rule`, () => {
        const base = `.sidebar-button[data-section="${section}"]`;
        assert.ok(hasBackgroundRule(css, base),
            `${base} has no background rule in lcars-fleet.css -- the button would render as the sidebar's own colour`);
        assert.ok(hasBackgroundRule(css, `${base}.active`),
            `${base}.active has no background rule in lcars-fleet.css -- the active state would not invert`);
        const bg = backgroundValue(css, base);
        const resolved = resolveColor(bg, vars);
        assert.ok(resolved !== null, `${base} background ${bg} does not resolve to a colour`);
        assert.notEqual(resolved, frameColor,
            `${base} background ${bg} resolves to the sidebar frame colour ${frameColor} (--fleet-body-primary) -- the button would still read as blank space`);
    });
}
