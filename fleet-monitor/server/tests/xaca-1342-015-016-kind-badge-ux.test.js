'use strict';
/**
 * XACA-1342-015 / -016 — SECRETS ONLY engine badge must be readable, and its
 * meaning must not live only in a hover tooltip.
 *
 * -015: the first version drew --lcars-dark text on --lcars-surface (1.15:1).
 *       Contrast is computed here from the REAL stylesheets and theme tokens,
 *       against every surface-token value the theme file defines (normal and
 *       high-contrast), in both the lcars and lcars2 variants.
 * -016: a visible explanatory line is rendered in the card body.
 */
const fs = require('fs');
const path = require('path');
const { test } = require('node:test');
const assert = require('node:assert/strict');

const PUBLIC = path.join(__dirname, '..', 'public');
const VARIANTS = [
    { name: 'lcars',  css: 'lcars/css/lcars-dashboards.css', theme: 'lcars/css/lcars-fleet-theme.css',  js: 'lcars/js/lcars-engines.js' },
    { name: 'lcars2', css: 'lcars2/css/lcars-fleet.css',     theme: 'lcars2/css/lcars-fleet-theme.css', js: 'lcars2/js/lcars-engines.js' },
];
const AA_NORMAL_TEXT = 4.5;

function read(rel) { return fs.readFileSync(path.join(PUBLIC, rel), 'utf8'); }

function ruleBody(css, selector) {
    const i = css.indexOf(selector + ' {');
    assert.notEqual(i, -1, `rule ${selector} not found`);
    return css.slice(i, css.indexOf('}', i));
}

function prop(body, name) {
    const m = body.match(new RegExp('(?:^|\\n)\\s*' + name + ':\\s*([^;]+);'));
    assert.ok(m, `property ${name} missing`);
    return m[1].trim();
}

function tokenValues(theme, token) {
    const re = new RegExp('--' + token + ':\\s*(#[0-9a-fA-F]{6})', 'g');
    const out = [];
    let m;
    while ((m = re.exec(theme)) !== null) out.push(m[1].toLowerCase());
    assert.ok(out.length > 0, `token --${token} has no hex definition`);
    return out;
}

function hexToRgb(h) { return [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16)); }

function luminance(rgb) {
    const c = rgb.map((v) => {
        const x = v / 255;
        return x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

function contrast(a, b) {
    const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
}

function resolveColor(value, theme) {
    const v = value.match(/^var\(--([a-z0-9-]+)\)$/);
    if (v) return tokenValues(theme, v[1])[0];
    assert.match(value, /^#[0-9a-fA-F]{6}$/, `unsupported color value ${value}`);
    return value.toLowerCase();
}

function composite(bgValue, under) {
    const m = bgValue.match(/^rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)$/);
    if (!m) return under;
    const a = parseFloat(m[4]);
    return [1, 2, 3].map((i, k) => Math.round(a * parseInt(m[i], 10) + (1 - a) * under[k]));
}

for (const v of VARIANTS) {
    test(`${v.name}: SECRETS ONLY badge meets WCAG AA on every surface token value (-015)`, () => {
        const theme = read(v.theme);
        const body = ruleBody(read(v.css), '.engine-card-kind-badge');
        const fg = hexToRgb(resolveColor(prop(body, 'color'), theme));
        const surfaces = tokenValues(theme, 'lcars-surface');
        assert.ok(surfaces.length >= 2, 'expected normal + high-contrast surface definitions');
        for (const s of surfaces) {
            const bg = composite(prop(body, 'background'), hexToRgb(s));
            const ratio = contrast(fg, bg);
            assert.ok(ratio >= AA_NORMAL_TEXT, `${v.name} badge on ${s}: ${ratio.toFixed(2)}:1 < ${AA_NORMAL_TEXT}`);
        }
    });

    test(`${v.name}: badge no longer uses --lcars-dark text (-015 regression)`, () => {
        const body = ruleBody(read(v.css), '.engine-card-kind-badge');
        assert.doesNotMatch(prop(body, 'color'), /lcars-dark/);
    });

    test(`${v.name}: visible explanatory note meets WCAG AA on every surface token value (-016)`, () => {
        const theme = read(v.theme);
        const body = ruleBody(read(v.css), '.engine-card-kind-note');
        const fg = hexToRgb(resolveColor(prop(body, 'color'), theme));
        for (const s of tokenValues(theme, 'lcars-surface')) {
            const ratio = contrast(fg, hexToRgb(s));
            assert.ok(ratio >= AA_NORMAL_TEXT, `${v.name} note on ${s}: ${ratio.toFixed(2)}:1`);
        }
    });

    test(`${v.name}: secret-only card body renders a visible note, not only a title tooltip (-016)`, () => {
        const js = read(v.js);
        const i = js.indexOf("kindNote.className = 'engine-card-kind-note'");
        assert.notEqual(i, -1, 'engine-card-kind-note element not created');
        const guard = js.lastIndexOf("if (engine.kind === 'secret-only')", i);
        assert.ok(guard !== -1 && i - guard < 300, 'note must be gated on kind === secret-only');
        assert.match(js.slice(i, i + 300), /textContent = '[^']*secrets only[^']*'/i);
        assert.match(js.slice(i, i + 300), /body\.appendChild\(kindNote\)/);
    });
}
