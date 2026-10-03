//
//  test_cr_tab_completed_state.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 DoubleNode.com. All rights reserved.
//

/**
 * XACA-1390-002: the v2 terminal CR state `cr-completed` (XACA-1348) must be
 * known to every enumeration of CR states in the LCARS CR tab. Before this
 * change an unknown state silently fell through: badge styled as DRAFTED,
 * sort rank 99 (below cr-held), STAGE AGE anchored on the created date, the
 * ACTIVE PIPELINE view counting it as in-flight, and no filter pill.
 *
 * Same technique as test_cr_tab_publish_regression.js: slice the shipped
 * source and evaluate it in a vm context (no reimplementation).
 *
 * Usage: node --test lcars-ui/tests/test_cr_tab_completed_state.js
 */

'use strict';

var test   = require('node:test');
var assert = require('node:assert/strict');
var path   = require('path');
var fs     = require('fs');
var vm     = require('vm');

var read = function (rel) { return fs.readFileSync(path.join(__dirname, rel), 'utf8'); };
var TAB  = read('../js/lcars-cr-tab.js');
var CSS  = read('../css/lcars-cr-tab.css');
var HTML = read('../index.html');
var BAR  = read('../js/lcars-filter-bar.js');

function slice(src, startMarker, endMarker) {
    var start = src.indexOf(startMarker);
    assert.ok(start !== -1, 'start marker missing: ' + JSON.stringify(startMarker));
    var end = src.indexOf(endMarker, start + startMarker.length);
    assert.ok(end !== -1, 'end marker missing: ' + JSON.stringify(endMarker));
    return src.slice(start, end);
}

function evalIn(code, expose) {
    var sb = { escapeHtml: function (s) { return String(s); } };
    vm.createContext(sb);
    vm.runInContext(code + '\n' + expose, sb);
    return sb;
}

test('sort rank: cr-completed is ranked with the deployed tier, ahead of pre-submission states', () => {
    var sb = evalIn(slice(TAB, 'const CR_STATE_ORDER = {', 'const PRIORITY_ORDER'), 'this.O = CR_STATE_ORDER;');
    var O = sb.O;
    assert.notEqual(O['cr-completed'], undefined, 'cr-completed must have an explicit rank (default is 99)');
    assert.ok(O['cr-completed'] > O['emergency-deployed'], 'completed follows the deploy states');
    assert.ok(O['cr-completed'] < O['cr-published'] && O['cr-completed'] < O['cr-drafted'], 'above pre-submission');
    assert.ok(O['cr-completed'] < O['cr-held'], 'must not sink below cr-held');
    var ranks = Object.getOwnPropertyNames(O).map(function (k) { return O[k]; });
    assert.equal(new Set(ranks).size, ranks.length, 'ranks must stay unique');
});

test('badge: cr-completed maps to its own class, not the DRAFTED fallback', () => {
    var code = slice(TAB, 'const CR_STATE_CLASS = {', 'function _typeBadge') +
               slice(TAB, 'function _stateBadge(', '/**\n     * XACA-1239: "APPROVAL WAIVED"');
    var sb = evalIn(code, 'this.C = CR_STATE_CLASS; this.badge = _stateBadge;');
    assert.equal(sb.C['cr-completed'], 'cr-state-completed');
    var html = sb.badge('cr-completed');
    assert.match(html, /cr-state-completed/);
    assert.match(html, /CR COMPLETED/);
    assert.doesNotMatch(html, /cr-state-drafted/);
});

test('css: .cr-state-completed rule exists and differs from deployed-prod', () => {
    var m = CSS.match(/\.cr-state-completed\s*\{([^}]*)\}/);
    assert.ok(m, '.cr-state-completed rule missing');
    var p = CSS.match(/\.cr-state-deployed-prod\s*\{([^}]*)\}/);
    assert.ok(p);
    assert.notEqual(m[1].trim(), p[1].trim());
    assert.match(m[1], /color:/);
});

test('STAGE AGE: cr-completed anchors on cr_completed_at', () => {
    var code = slice(TAB, 'const _STAGE_ANCHOR = {', '    /**\n     * Render a stage-age badge');
    var sb = evalIn(code, 'this.age = _computeStageAge;');
    var now = Date.now(), DAY = 86400000;
    var iso = function (d) { return new Date(now - d * DAY).toISOString(); };
    var age = sb.age({
        crState: 'cr-completed',
        cr_created_at: iso(30), cr_deployed_prod_at: iso(10), cr_completed_at: iso(1),
    });
    assert.ok(age > 0.9 && age < 1.1, 'expected ~1d from cr_completed_at, got ' + age);
});

test('ACTIVE PIPELINE view and DELAYED badge treat cr-completed as terminal', () => {
    var m = TAB.match(/const TERMINAL = new Set\(\[([^\]]*)\]\)/);
    assert.ok(m && /'cr-completed'/.test(m[1]), 'ACTIVE PIPELINE TERMINAL set lacks cr-completed');
    var d = TAB.match(/const _DELAY_TERMINAL = new Set\(\[([^\]]*)\]\)/);
    assert.ok(d && /'cr-completed'/.test(d[1]), '_DELAY_TERMINAL lacks cr-completed');
});

test('EDIT STATE: cr-completed is selectable and declares a (field-less) entry', () => {
    var sb = evalIn(slice(TAB, 'const _CR_STATES = [', '    /**\n     * Locate the raw CR record'),
        'this.S = _CR_STATES; this.F = _CR_STATE_FIELDS;');
    assert.ok(sb.S.indexOf('cr-completed') !== -1);
    assert.ok(Array.isArray(sb.F['cr-completed']));
    assert.equal(sb.F['cr-completed'].length, 0);
});

test('state filter: cr-completed is NOT hidden under ALL (only cr-closed is)', () => {
    var body = slice(TAB, "if (s.stateFilter === 'all') {", '} else if (s.stateFilter)');
    assert.doesNotMatch(body, /cr-completed/);
});

test('index.html: COMPLETED filter pill exists', () => {
    assert.match(HTML, /<button class="filter-pill" data-cr-state="cr-completed">COMPLETED<\/button>/);
});

test('filter-bar dropdown: cr-completed is deliberately not an active state', () => {
    var set = slice(BAR, 'const CR_ACTIVE_STATES = new Set([', ']);');
    assert.doesNotMatch(set, /cr-completed/);
    assert.match(BAR, /XACA-1390: cr-completed/);
});
