#!/usr/bin/env node
//
//  test-xaca-0870-model-chart.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * Regression coverage for the XACA-0870 BY MODEL stacked-bar chart in the
 * LCARS Usage Monitor (lcars-ui/index.html + lcars-ui/css/usage-indicator.css),
 * including the gate-round-1 fixes:
 *
 *   010  tooltip clipped — Chart.js drew its tooltip INSIDE the canvas, whose
 *        wrapper is 32px tall with overflow:hidden, so the 2-line tooltip lost
 *        its body line. Fix: built-in tooltip disabled, `external` handler
 *        drives #uw-model-chart-tip, which must live OUTSIDE the wrapper.
 *   011  aria-live churn — the legend was rebuilt every 30s poll even when
 *        unchanged. Fix: content signature; identical content = no DOM rebuild.
 *   012  toggle border contrast < 3:1 (also the copied-from
 *        .usage-account-toggle button rule).
 *   013  legend note text contrast < 4.5:1.
 *   014  toggle target size (24px min-height).
 *
 * Contrast values are READ FROM THE CSS, never hardcoded here, so a later edit
 * that regresses a color fails this suite. The share/legend/tooltip logic is
 * EXTRACTED from the shipped index.html by unique text markers and evaluated
 * in a vm sandbox — this tests the shipped code, not a reimplementation. A
 * missing marker fails loudly instead of silently testing stale text.
 *
 * SCOPE: no real browser. Rendered geometry (does the tooltip actually paint
 * un-clipped at 280/340/400px) is verified separately with Playwright; this
 * file guards the structural cause and the pure logic.
 *
 * Usage:
 *   node lcars-ui/tests/test-xaca-0870-model-chart.js
 *
 * No external dependencies. Node >=18 required (node:test, node:vm built-in).
 */

'use strict';

var test   = require('node:test');
var assert = require('node:assert/strict');
var path   = require('path');
var fs     = require('fs');
var vm     = require('vm');

var INDEX_PATH = path.join(__dirname, '../index.html');
var CSS_PATH   = path.join(__dirname, '../css/usage-indicator.css');
var HTML = fs.readFileSync(INDEX_PATH, 'utf8');
var CSS  = fs.readFileSync(CSS_PATH, 'utf8');

// Panel background measured by the UX evaluator in the rendered widget.
var PANEL_BG = [10, 10, 20];

// ═══════════════════════════════════════════════════════════════════════════
// Color / contrast helpers (WCAG 2.x relative luminance)
// ═══════════════════════════════════════════════════════════════════════════

function parseColor(str) {
    var s = String(str).trim();
    var m = s.match(/var\(\s*--[\w-]+\s*,\s*([^)]+)\)/);
    if (m) s = m[1].trim(); // CSS custom-property fallback is the effective value outside the LCARS root
    m = s.match(/rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)/);
    if (m) {
        return { r: +m[1], g: +m[2], b: +m[3], a: m[4] === undefined ? 1 : +m[4] };
    }
    m = s.match(/#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})\b/);
    if (m) {
        var h = m[1];
        if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
        return { r: parseInt(h.slice(0, 2), 16), g: parseInt(h.slice(2, 4), 16), b: parseInt(h.slice(4, 6), 16), a: 1 };
    }
    throw new Error('Unparseable color: ' + str);
}

function composite(fg, bgRgb) {
    return [
        fg.a * fg.r + (1 - fg.a) * bgRgb[0],
        fg.a * fg.g + (1 - fg.a) * bgRgb[1],
        fg.a * fg.b + (1 - fg.a) * bgRgb[2]
    ];
}

function luminance(rgb) {
    var c = rgb.map(function (v) {
        v = v / 255;
        return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

function contrast(a, b) {
    var la = luminance(a), lb = luminance(b);
    var hi = Math.max(la, lb), lo = Math.min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
}

// ── CSS rule lookup: the TOP-LEVEL (unindented) rule for an exact selector ──
function ruleBody(selector) {
    var needle = '\n' + selector + ' {';
    var idx = CSS.indexOf(needle);
    assert.ok(idx !== -1, 'CSS rule not found for selector: ' + selector);
    assert.equal(CSS.indexOf(needle, idx + 1), -1, 'CSS selector appears more than once at top level: ' + selector);
    var open = idx + needle.length;
    var close = CSS.indexOf('}', open);
    return CSS.slice(open, close).replace(/\/\*[\s\S]*?\*\//g, '');
}

function declValue(selector, prop) {
    var body = ruleBody(selector);
    var re = new RegExp('(?:^|[;\\s])' + prop.replace(/-/g, '\\-') + '\\s*:\\s*([^;]+);');
    var m = body.match(re);
    assert.ok(m, 'Property "' + prop + '" not found in rule ' + selector);
    return m[1].trim();
}

function colorOf(selector, prop) {
    var v = declValue(selector, prop);
    var m = v.match(/(var\([^)]*\)|rgba?\([^)]*\)|#[0-9a-fA-F]{3,6}\b)/);
    assert.ok(m, 'No color token in ' + selector + ' { ' + prop + ': ' + v + ' }');
    return parseColor(m[1]);
}

// ═══════════════════════════════════════════════════════════════════════════
// 012 / 013 / 014 — contrast + target size, read from the CSS
// ═══════════════════════════════════════════════════════════════════════════

var BTN        = '.uw-model-chart-period-btn';
var BTN_PRESS  = '.uw-model-chart-period-btn[aria-pressed="true"]';
var BTN_HOVER  = '.uw-model-chart-period-btn:hover:not([aria-pressed="true"])';
var BTN_FOCUS  = '.uw-model-chart-period-btn:focus-visible';
var ACCT       = '.usage-account-toggle button';
var ACCT_HOVER = '.usage-account-toggle button:hover:not(.active)';

// Both toggle buttons share one class, so every state row is asserted per button
// (a per-id override added later would have to be caught by adding it here).
var NON_TEXT_ROWS = [];
['TODAY', '7-DAY'].forEach(function (btn) {
    NON_TEXT_ROWS.push({ name: btn + ' unpressed border',     sel: BTN,       prop: 'border' });
    NON_TEXT_ROWS.push({ name: btn + ' hover border',         sel: BTN_HOVER, prop: 'border-color' });
    NON_TEXT_ROWS.push({ name: btn + ' focus-visible outline', sel: BTN_FOCUS, prop: 'outline' });
    NON_TEXT_ROWS.push({ name: btn + ' pressed border',       sel: BTN_PRESS, prop: 'border-color' });
});
NON_TEXT_ROWS.push({ name: 'account toggle unpressed border', sel: ACCT,       prop: 'border' });
NON_TEXT_ROWS.push({ name: 'account toggle hover border',     sel: ACCT_HOVER, prop: 'border-color' });

NON_TEXT_ROWS.forEach(function (row) {
    test('012 non-text contrast >= 3:1 — ' + row.name, function () {
        var c = contrast(composite(colorOf(row.sel, row.prop), PANEL_BG), PANEL_BG);
        assert.ok(c >= 3, row.name + ' contrast ' + c.toFixed(2) + ':1 < 3:1');
    });
});

test('012 hover border is visibly distinct from the rest border (both toggles)', function () {
    [[BTN, BTN_HOVER], [ACCT, ACCT_HOVER]].forEach(function (pair) {
        var rest  = contrast(composite(colorOf(pair[0], 'border'), PANEL_BG), PANEL_BG);
        var hover = contrast(composite(colorOf(pair[1], 'border-color'), PANEL_BG), PANEL_BG);
        assert.ok(hover - rest >= 1, pair[1] + ' hover (' + hover.toFixed(2) + ') not distinct from rest (' + rest.toFixed(2) + ')');
    });
});

var PRESSED_BG = function () { return composite(colorOf(BTN_PRESS, 'background'), PANEL_BG); };

var TEXT_ROWS = [
    { name: 'legend default text',     sel: '.uw-model-chart-legend',       bg: function () { return PANEL_BG; } },
    { name: 'legend label',            sel: '.uw-model-chart-legend-label', bg: function () { return PANEL_BG; } },
    { name: 'legend note',             sel: '.uw-model-chart-legend-note',  bg: function () { return PANEL_BG; } },
    { name: 'unpressed button text',   sel: BTN,                            bg: function () { return PANEL_BG; } },
    { name: 'pressed button text',     sel: BTN_PRESS,                      bg: PRESSED_BG }
];

TEXT_ROWS.forEach(function (row) {
    test('013 text contrast >= 4.5:1 — ' + row.name, function () {
        var bg = row.bg();
        var c = contrast(composite(colorOf(row.sel, 'color'), bg), bg);
        assert.ok(c >= 4.5, row.name + ' contrast ' + c.toFixed(2) + ':1 < 4.5:1');
    });
});

test('014 toggle buttons have a >= 24px min-height target, content centred', function () {
    var mh = declValue(BTN, 'min-height');
    var px = parseFloat(mh);
    assert.ok(/px$/.test(mh) && px >= 24, 'min-height is "' + mh + '", want >= 24px');
    assert.equal(declValue(BTN, 'align-items'), 'center');
});

// ═══════════════════════════════════════════════════════════════════════════
// Source extraction from index.html
// ═══════════════════════════════════════════════════════════════════════════

function sliceBetween(src, startMarker, endMarker, label) {
    var start = src.indexOf(startMarker);
    assert.ok(start !== -1, 'Start marker for ' + label + ' not found in index.html — moved/renamed?');
    var end = src.indexOf(endMarker, start + startMarker.length);
    assert.ok(end !== -1, 'End marker for ' + label + ' not found in index.html — surrounding code changed?');
    return src.slice(start, end);
}

var CONSTS_SRC = sliceBetween(HTML,
    "var _MODEL_TIERS = ['Opus', 'Sonnet', 'Haiku', 'Fable'];",
    '\n    function renderByModel(byModel) {', 'tier constants');

var CHART_SRC = sliceBetween(HTML,
    'var _MODEL_CHART_COLORS = {',
    '    // ── Period toggle (TODAY / 7-DAY)', 'model-chart logic');

// Only the function definitions + constants are evaluated; renderByModelChart
// is defined but never called without a DOM in the logic tests below.
function makeSandbox(extra) {
    var ctx = {
        formatCost: function (v) { return '$' + Number(v).toFixed(2); },
        formatTokens: function (v) { return String(v); },
        window: {},
        console: console,
        Math: Math
    };
    Object.keys(extra || {}).forEach(function (k) { ctx[k] = extra[k]; });
    vm.createContext(ctx);
    vm.runInContext(CONSTS_SRC + '\n' + CHART_SRC +
        '\n;this.__api = { computeShares: _uwModelChartComputeShares, renderLegend: _uwModelChartRenderLegend,' +
        ' tipExternal: _uwModelChartTooltipExternal, pctStr: _uwModelChartPctStr };', ctx);
    return ctx.__api;
}

// ═══════════════════════════════════════════════════════════════════════════
// Share logic (_uwModelChartComputeShares)
// ═══════════════════════════════════════════════════════════════════════════

var REAL = { tiers: {
    Opus:   { today_cost_usd: 42.10, today_tokens: 120000, last_7d_cost_usd: 1658.51, last_7d_tokens: 4200000 },
    Sonnet: { today_cost_usd: 3.20,  today_tokens: 30000,  last_7d_cost_usd: 148.01,  last_7d_tokens: 900000 },
    Haiku:  { today_cost_usd: 0.02,  today_tokens: 5000,   last_7d_cost_usd: 1.99,    last_7d_tokens: 40000 },
    Fable:  { today_cost_usd: 0,     today_tokens: 0,      last_7d_cost_usd: 0,       last_7d_tokens: 0 }
} };

function pctOf(result, key) {
    var e = result.entries.filter(function (x) { return x.key === key; })[0];
    return e ? e.pct : undefined;
}

var SHARE_ROWS = [
    {
        name: 'real 7-day data -> 91.7 / 8.2 / 0.11 by cost',
        input: REAL, period: 'last_7d',
        check: function (r, api) {
            assert.equal(r.basis, 'cost');
            assert.equal(api.pctStr(pctOf(r, 'Opus')), '91.7%');
            assert.equal(api.pctStr(pctOf(r, 'Sonnet')), '8.2%');
            assert.equal(api.pctStr(pctOf(r, 'Haiku')), '0.11%');
            assert.equal(pctOf(r, 'Fable'), 0);
        }
    },
    {
        name: 'all-zero -> basis null (genuine no-usage, not no-data)',
        input: { tiers: { Opus: { last_7d_cost_usd: 0, last_7d_tokens: 0 }, Sonnet: {} } }, period: 'last_7d',
        check: function (r) { assert.ok(r); assert.equal(r.basis, null); assert.equal(r.total, 0); }
    },
    {
        name: 'cost $0 but tokens > 0 -> tokens fallback',
        input: { tiers: { Opus: { today_cost_usd: 0, today_tokens: 300 }, Sonnet: { today_cost_usd: 0, today_tokens: 100 } } },
        period: 'today',
        check: function (r) {
            assert.equal(r.basis, 'tokens');
            assert.equal(pctOf(r, 'Opus'), 75);
            assert.equal(pctOf(r, 'Sonnet'), 25);
        }
    },
    { name: 'undefined payload -> null', input: undefined, period: 'last_7d', check: function (r) { assert.equal(r, null); } },
    { name: 'tiers missing -> null',     input: {},        period: 'last_7d', check: function (r) { assert.equal(r, null); } },
    { name: 'tiers not an object -> null', input: { tiers: 'x' }, period: 'last_7d', check: function (r) { assert.equal(r, null); } },
    {
        name: 'malformed numbers (NaN / negative / string) are treated as 0',
        input: { tiers: { Opus: { last_7d_cost_usd: NaN }, Sonnet: { last_7d_cost_usd: -5 }, Haiku: { last_7d_cost_usd: '9' }, Fable: { last_7d_cost_usd: 4 } } },
        period: 'last_7d',
        check: function (r) {
            assert.equal(r.basis, 'cost');
            assert.equal(pctOf(r, 'Fable'), 100);
            assert.equal(pctOf(r, 'Opus'), 0);
        }
    },
    {
        name: 'Other included only when the SELECTED period has Other data (7-day yes)',
        input: { tiers: { Opus: { today_cost_usd: 1, last_7d_cost_usd: 9 }, Other: { today_cost_usd: 0, today_tokens: 0, last_7d_cost_usd: 1 } } },
        period: 'last_7d',
        check: function (r) {
            assert.ok(r.entries.some(function (e) { return e.key === 'Other'; }));
            assert.equal(pctOf(r, 'Other'), 10);
        }
    },
    {
        name: 'Other excluded when the SELECTED period has no Other data (today no)',
        input: { tiers: { Opus: { today_cost_usd: 1, last_7d_cost_usd: 9 }, Other: { today_cost_usd: 0, today_tokens: 0, last_7d_cost_usd: 1 } } },
        period: 'today',
        check: function (r) {
            assert.ok(!r.entries.some(function (e) { return e.key === 'Other'; }));
            assert.equal(pctOf(r, 'Opus'), 100);
        }
    }
];

SHARE_ROWS.forEach(function (row) {
    test('shares — ' + row.name, function () {
        var api = makeSandbox();
        row.check(api.computeShares(row.input, row.period), api);
    });
});

// ═══════════════════════════════════════════════════════════════════════════
// 011 — legend content signature + empty-state wording
// ═══════════════════════════════════════════════════════════════════════════

function makeFakeDom() {
    var counters = { removeChild: 0, appendChild: 0 };
    function makeEl(tag) {
        var el = {
            tagName: tag, className: '', style: {}, attrs: {}, children: [], hidden: false,
            setAttribute: function (k, v) { this.attrs[k] = String(v); },
            appendChild: function (c) { counters.appendChild++; this.children.push(c); return c; },
            removeChild: function (c) {
                counters.removeChild++;
                var i = this.children.indexOf(c);
                if (i !== -1) this.children.splice(i, 1);
                return c;
            },
            addEventListener: function () {}
        };
        Object.defineProperty(el, 'firstChild', { get: function () { return this.children[0] || null; } });
        Object.defineProperty(el, 'textContent', {
            get: function () {
                return this._text !== undefined && this.children.length === 0
                    ? this._text
                    : this.children.map(function (c) { return c.textContent; }).join(' ');
            },
            set: function (v) { this.children = []; this._text = String(v); }
        });
        return el;
    }
    return { counters: counters, makeEl: makeEl };
}

function legendApi() {
    var dom = makeFakeDom();
    var api = makeSandbox({ document: { createElement: dom.makeEl, getElementById: function () { return null; } } });
    return { api: api, dom: dom, legend: dom.makeEl('div') };
}

test('011 identical data rendered twice -> legend NOT rebuilt the second time', function () {
    var h = legendApi();
    var result = h.api.computeShares(REAL, 'last_7d');
    h.api.renderLegend(h.legend, result);
    var afterFirst = { rm: h.dom.counters.removeChild, add: h.dom.counters.appendChild };
    assert.ok(afterFirst.add > 0, 'first render appended nothing — fake DOM not exercised');
    var firstText = h.legend.textContent;

    // Fresh result object with the same content (as a new poll payload would produce)
    h.api.renderLegend(h.legend, h.api.computeShares(JSON.parse(JSON.stringify(REAL)), 'last_7d'));
    assert.equal(h.dom.counters.removeChild, afterFirst.rm, 'legend children were removed on an identical re-render');
    assert.equal(h.dom.counters.appendChild, afterFirst.add, 'legend children were appended on an identical re-render');
    assert.equal(h.legend.textContent, firstText);
    assert.match(firstText, /OPUS 91\.7%/);
    assert.match(firstText, /HAIKU 0\.11%/);
});

test('011 changed data -> legend IS rebuilt', function () {
    var h = legendApi();
    h.api.renderLegend(h.legend, h.api.computeShares(REAL, 'last_7d'));
    var before = h.dom.counters.appendChild;
    h.api.renderLegend(h.legend, h.api.computeShares(REAL, 'today'));
    assert.ok(h.dom.counters.appendChild > before, 'period change did not rebuild the legend');
});

test('011 basis change alone (cost -> tokens) rebuilds and adds the note', function () {
    var h = legendApi();
    h.api.renderLegend(h.legend, { basis: 'cost', total: 1, entries: [{ key: 'Opus', pct: 100 }] });
    h.api.renderLegend(h.legend, { basis: 'tokens', total: 1, entries: [{ key: 'Opus', pct: 100 }] });
    assert.match(h.legend.textContent, /by tokens \(no cost data\)/);
});

var EMPTY_ROWS = [
    { name: 'tiers absent -> data unavailable', input: undefined, want: 'No per-model data available' },
    { name: 'tiers malformed -> data unavailable', input: { tiers: 42 }, want: 'No per-model data available' },
    { name: 'all-zero -> no usage', input: { tiers: { Opus: { last_7d_cost_usd: 0 } } }, want: 'No usage in this period' }
];
EMPTY_ROWS.forEach(function (row) {
    test('legend empty state — ' + row.name, function () {
        var h = legendApi();
        h.api.renderLegend(h.legend, h.api.computeShares(row.input, 'last_7d'));
        assert.equal(h.legend.textContent, row.want);
    });
});

// ═══════════════════════════════════════════════════════════════════════════
// 010 — tooltip: structural guard against the exact clip cause
// ═══════════════════════════════════════════════════════════════════════════

test('010 chart options disable the canvas tooltip and set an external handler', function () {
    var body = sliceBetween(HTML, 'function renderByModelChart(byModel) {', '    // ── Period toggle', 'renderByModelChart');
    var m = body.match(/tooltip\s*:\s*\{([^{}]*)\}/);
    assert.ok(m, 'no plugins.tooltip block in renderByModelChart chartOptions');
    assert.match(m[1], /\benabled\s*:\s*false\b/, 'tooltip.enabled is not false — the canvas tooltip would clip in the 32px wrapper');
    assert.match(m[1], /\bexternal\s*:\s*_uwModelChartTooltipExternal\b/, 'tooltip.external handler not wired');
    assert.match(HTML, /function _uwModelChartTooltipExternal\(context\)/);
});

function ancestorsOf(markup, id) {
    var VOID = { br: 1, hr: 1, img: 1, input: 1, meta: 1, link: 1, source: 1, wbr: 1 };
    var stack = [];
    var clean = markup.replace(/<!--[\s\S]*?-->/g, '');
    var re = /<(\/?)([a-zA-Z][\w-]*)([^>]*)>/g;
    var m;
    while ((m = re.exec(clean)) !== null) {
        var closing = m[1] === '/', tag = m[2].toLowerCase(), attrs = m[3];
        if (closing) {
            // pop to the matching tag
            for (var i = stack.length - 1; i >= 0; i--) {
                if (stack[i].tag === tag) { stack.length = i; break; }
            }
            continue;
        }
        var cls = (attrs.match(/class="([^"]*)"/) || [])[1] || '';
        var elId = (attrs.match(/id="([^"]*)"/) || [])[1] || '';
        if (elId === id) return stack.map(function (s) { return s.cls; });
        if (!VOID[tag] && !/\/\s*$/.test(attrs)) stack.push({ tag: tag, cls: cls });
    }
    return null;
}

test('010 #uw-model-chart-tip is inside .uw-model-chart-block but NOT inside .uw-model-chart-wrap', function () {
    var section = sliceBetween(HTML, '<section class="usage-section usage-by-model"', '</section>', 'BY MODEL section');
    var anc = ancestorsOf(section, 'uw-model-chart-tip');
    assert.ok(anc, '#uw-model-chart-tip element not found in the BY MODEL markup');
    var has = function (c) { return anc.some(function (a) { return a.split(/\s+/).indexOf(c) !== -1; }); };
    assert.ok(has('uw-model-chart-block'), 'tip is not inside .uw-model-chart-block (its positioning container)');
    assert.ok(!has('uw-model-chart-wrap'), 'tip is inside .uw-model-chart-wrap — overflow:hidden will clip it (the 010 bug)');
    assert.match(section, /id="uw-model-chart-tip"[^>]*role="tooltip"|role="tooltip"[^>]*id="uw-model-chart-tip"/);
});

test('010 CSS: block is the positioning container; wrap still clips (so the tip must stay out)', function () {
    assert.equal(declValue('.uw-model-chart-block', 'position'), 'relative');
    assert.equal(declValue('.uw-model-chart-tip', 'position'), 'absolute');
    assert.equal(declValue('.uw-model-chart-tip', 'pointer-events'), 'none');
    assert.equal(declValue('.uw-model-chart-tip[hidden]', 'display'), 'none');
});

// ── 010 behaviour: the external handler's text + horizontal clamp ───────────
function tipHarness(opts) {
    var dom = makeFakeDom();
    var tip = dom.makeEl('div');
    tip.hidden = true;
    tip.offsetWidth = opts.tipW;
    var block = dom.makeEl('div');
    block.clientWidth = opts.blockW;
    block.getBoundingClientRect = function () { return { left: 100, top: 50, right: 100 + opts.blockW, bottom: 150 }; };
    var wrap = { getBoundingClientRect: function () { return { left: 100, top: 80, right: 100 + opts.blockW, bottom: 112 }; } };
    var canvas = { parentNode: wrap, getBoundingClientRect: function () { return { left: 100, top: 80 }; } };
    var api = makeSandbox({ document: {
        createElement: dom.makeEl,
        getElementById: function (id) { return id === 'uw-model-chart-tip' ? tip : (id === 'uw-model-chart-block' ? block : null); }
    } });
    return { api: api, tip: tip, canvas: canvas };
}

function ctxFor(h, seg, opacity, ds) {
    return {
        chart: { canvas: h.canvas },
        tooltip: {
            opacity: opacity, caretX: seg.x,
            dataPoints: [{ dataset: ds, element: { x: seg.x, base: seg.base } }]
        }
    };
}

var DS_HAIKU = { label: 'HAIKU', _truePct: 0.110033, _basis: 'cost', _cost: 1.99, _tokens: 40000 };
var DS_TOK   = { label: 'OPUS', _truePct: 75, _basis: 'tokens', _cost: 0, _tokens: 300 };

var CLAMP_ROWS = [
    { name: 'segment at far right edge clamps to blockW - tipW', seg: { x: 256, base: 252 }, blockW: 256, tipW: 180, wantLeft: 76 },
    { name: 'segment at far left edge clamps to 0',              seg: { x: 4, base: 0 },     blockW: 256, tipW: 180, wantLeft: 0 },
    { name: 'mid segment is centred on the segment midpoint',    seg: { x: 200, base: 100 }, blockW: 400, tipW: 100, wantLeft: 100 },
    { name: 'tip wider than block pins to 0',                    seg: { x: 150, base: 100 }, blockW: 120, tipW: 200, wantLeft: 0 }
];
CLAMP_ROWS.forEach(function (row) {
    test('010 external handler clamp — ' + row.name, function () {
        var h = tipHarness({ blockW: row.blockW, tipW: row.tipW });
        h.api.tipExternal(ctxFor(h, row.seg, 1, DS_HAIKU));
        assert.equal(h.tip.hidden, false);
        assert.equal(h.tip.style.left, row.wantLeft + 'px');
        assert.equal(h.tip.style.top, (112 - 50 + 4) + 'px', 'tip not placed just below the bar wrapper');
    });
});

test('010 external handler: two lines, TRUE pct, textContent (tier / pct · cost · tokens)', function () {
    var h = tipHarness({ blockW: 256, tipW: 150 });
    h.api.tipExternal(ctxFor(h, { x: 250, base: 246 }, 1, DS_HAIKU));
    assert.equal(h.tip.children.length, 2);
    assert.equal(h.tip.children[0].textContent, 'HAIKU');
    assert.equal(h.tip.children[1].textContent, '0.11% · $1.99 · 40000 tokens');
});

test('010 external handler: tokens basis appends "(by tokens)"', function () {
    var h = tipHarness({ blockW: 256, tipW: 150 });
    h.api.tipExternal(ctxFor(h, { x: 100, base: 0 }, 1, DS_TOK));
    assert.equal(h.tip.children[1].textContent, '75.0% (by tokens) · $0.00 · 300 tokens');
});

test('010 external handler hides on opacity 0 and on missing dataPoints', function () {
    var h = tipHarness({ blockW: 256, tipW: 150 });
    h.api.tipExternal(ctxFor(h, { x: 100, base: 0 }, 1, DS_TOK));
    assert.equal(h.tip.hidden, false);
    h.api.tipExternal(ctxFor(h, { x: 100, base: 0 }, 0, DS_TOK));
    assert.equal(h.tip.hidden, true);
    h.api.tipExternal(ctxFor(h, { x: 100, base: 0 }, 1, DS_TOK));
    h.api.tipExternal({ chart: { canvas: h.canvas }, tooltip: { opacity: 1, dataPoints: [] } });
    assert.equal(h.tip.hidden, true);
});

test('015 reduced motion: chart options drop animation when prefers-reduced-motion matches', function () {
    var body = sliceBetween(HTML, 'function renderByModelChart(byModel) {', '    // ── Period toggle', 'renderByModelChart');
    assert.match(body, /if \(_uwModelChartPrefersReducedMotion\(\)\) chartOptions\.animation = false;/);
    assert.match(HTML, /matchMedia\('\(prefers-reduced-motion: reduce\)'\)\.matches/);
});
