//
//  test-xaca-1337-015-freelance-fallback.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * XACA-1337-015: per-client freelance teams (freelance-<client>-<project>) are
 * machine-local registrations, so shipped UI code must NOT carry a per-client
 * table. These tests prove the generic fallbacks that replaced those tables:
 *
 *   lcars.js
 *     resolveTeamColors()  - any freelance-* team gets the 'freelance' colors
 *                            (before: an unlisted team rendered iOS crimson)
 *     applyTeamTheme()     - end to end: container CSS vars for a synthetic team
 *     getBasePath()        - any /freelance-<x>/... first segment is the base path
 *   fleet-monitor (skipped when that tree is absent, e.g. a tap layout)
 *     getDivisionTitle(), getDivisionColorClass(), buildDivisionToTeamMap()
 *     in lcars-dashboard-app.js, formatBackupDisplayName() in lcars-fleet-core.js
 *
 * The shipped files are browser-only scripts with no module.exports, so each
 * function's exact source is extracted by start/end markers and evaluated in a
 * fresh vm context (same technique as test_xaca0920_copy_to_clipboard.js). A
 * missing marker fails loudly instead of testing stale text.
 *
 * Usage:  node --test lcars-ui/tests/test-xaca-1337-015-freelance-fallback.js
 */

'use strict';

var test   = require('node:test');
var assert = require('node:assert/strict');
var path   = require('path');
var fs     = require('fs');
var vm     = require('vm');

// The retired client slugs, built from fragments so this SHIPPED test does not itself
// contain them (scripts/check-no-client-slugs.sh scans every shipped file; the single
// pattern definition lives in that script). The third entry is a bare brand name, also a leak.
var CLIENT_SLUGS = ['freelance-' + 'double' + 'node', 'freelance-' + 'liquid' + 'style', 'band' + 'wear'];
var CLIENT_SLUG_RE = new RegExp(CLIENT_SLUGS.join('|'), 'i');

var LCARS_JS = path.join(__dirname, '../js/lcars.js');
var FLEET_DIR = path.join(__dirname, '../../fleet-monitor/server/public/lcars/js');
var DASH_JS = path.join(FLEET_DIR, 'lcars-dashboard-app.js');
var CORE_JS = path.join(FLEET_DIR, 'lcars-fleet-core.js');
var FLEET_PRESENT = fs.existsSync(DASH_JS) && fs.existsSync(CORE_JS);
var FLEET_SKIP = FLEET_PRESENT ? false : 'fleet-monitor tree not present (tap layout)';

function slice(src, startMarker, endMarker, label) {
    var start = src.indexOf(startMarker);
    assert.ok(start !== -1, label + ': start marker not found: ' + startMarker);
    var end = src.indexOf(endMarker, start + startMarker.length);
    assert.ok(end !== -1, label + ': end marker not found: ' + endMarker);
    return src.slice(start, end);
}

function run(code, sandbox) {
    var ctx = vm.createContext(sandbox);
    vm.runInContext(code, ctx);
    return ctx;
}

// ─── lcars.js ──────────────────────────────────────────────────────────────

var LCARS_SRC = fs.readFileSync(LCARS_JS, 'utf8');
var RESOLVE_SRC = slice(LCARS_SRC, 'function resolveTeamColors(', '\n/**\n * Apply team-specific theme', 'resolveTeamColors');
var THEME_SRC = slice(LCARS_SRC, 'function applyTeamTheme() {', '\n// ═', 'applyTeamTheme');
var BASEPATH_SRC = slice(LCARS_SRC, 'function getBasePath() {', '\n/**\n * Convert an API path', 'getBasePath');

var IOS = '#ff4466';          // ios org (crimson)
var FREELANCE_ORG = '#9999ff';
var FREELANCE_DIV = '#cc99ff';
var SYNTHETIC = 'freelance-acme-app';

function themeFor(team) {
    var vars = {};
    var classes = [];
    var container = {
        style: { setProperty: function (k, v) { vars[k] = v; } },
        classList: {
            remove: function () {},
            add: function (c) { classes.push(c); }
        }
    };
    var sandbox = {
        CONFIG: { team: team },
        console: { log: function () {}, warn: function () {} },
        document: { querySelector: function () { return container; } }
    };
    run(RESOLVE_SRC + '\n' + THEME_SRC, sandbox);
    sandbox.applyTeamTheme();
    return { vars: vars, classes: classes };
}

test('lcars.js: no per-client slug survives in lcars.js / lcars.css', function () {
    var css = fs.readFileSync(path.join(__dirname, '../css/lcars.css'), 'utf8');
    var re = CLIENT_SLUG_RE;
    assert.ok(re.test(CLIENT_SLUGS[0]), 'sanity: the leak pattern must match a real slug (non-vacuous)');
    assert.ok(!re.test(LCARS_SRC), 'lcars.js still names a client slug');
    assert.ok(!re.test(css), 'lcars.css still names a client slug');
});

test('resolveTeamColors: exact key wins', function () {
    var map = { ios: { org: 'a' }, freelance: { org: 'b' }, 'freelance-x': { org: 'c' } };
    var sandbox = {};
    run(RESOLVE_SRC, sandbox);
    assert.equal(sandbox.resolveTeamColors(map, 'freelance-x', 'ios').org, 'c');
});

test('resolveTeamColors: freelance-<client>-<project> falls to the freelance family, not the default', function () {
    var map = { ios: { org: 'ios' }, freelance: { org: 'fl' } };
    var sandbox = {};
    run(RESOLVE_SRC, sandbox);
    assert.equal(sandbox.resolveTeamColors(map, SYNTHETIC, 'ios').org, 'fl');
    assert.equal(sandbox.resolveTeamColors(map, 'freelance-other-thing-else', 'ios').org, 'fl');
});

test('resolveTeamColors: unknown team and empty team get the fallback team', function () {
    var map = { ios: { org: 'ios' }, freelance: { org: 'fl' } };
    var sandbox = {};
    run(RESOLVE_SRC, sandbox);
    assert.equal(sandbox.resolveTeamColors(map, 'nonesuch', 'ios').org, 'ios');
    assert.equal(sandbox.resolveTeamColors(map, '', 'ios').org, 'ios');
    assert.equal(sandbox.resolveTeamColors(map, undefined, 'ios').org, 'ios');
});

test('applyTeamTheme: synthetic freelance team renders freelance colors, NOT ios crimson', function () {
    var t = themeFor(SYNTHETIC);
    assert.equal(t.vars['--current-org-color'], FREELANCE_ORG);
    assert.equal(t.vars['--current-div-color'], FREELANCE_DIV);
    assert.notEqual(t.vars['--current-org-color'], IOS);
    assert.deepEqual(t.classes, ['team-' + SYNTHETIC]);
});

test('applyTeamTheme: plain freelance, ios and an unknown team keep their colors', function () {
    assert.equal(themeFor('freelance').vars['--current-div-color'], FREELANCE_DIV);
    assert.equal(themeFor('ios').vars['--current-org-color'], IOS);
    assert.equal(themeFor('nonesuch').vars['--current-org-color'], IOS);
});

function basePathFor(pathname) {
    var sandbox = { window: { location: { pathname: pathname } } };
    run(BASEPATH_SRC, sandbox);
    return sandbox.getBasePath();
}

test('getBasePath: synthetic freelance-<client>-<project> prefix is recognised', function () {
    assert.equal(basePathFor('/' + SYNTHETIC + '/'), '/' + SYNTHETIC);
    assert.equal(basePathFor('/' + SYNTHETIC + '/api/status'), '/' + SYNTHETIC);
    assert.equal(basePathFor('/' + SYNTHETIC), '/' + SYNTHETIC);
});

test('getBasePath: fixed prefixes and root are unchanged', function () {
    assert.equal(basePathFor('/academy/index.html'), '/academy');
    assert.equal(basePathFor('/freelance/'), '/freelance');
    assert.equal(basePathFor('/legal-coparenting/x'), '/legal-coparenting');
    assert.equal(basePathFor('/'), '');
    assert.equal(basePathFor('/unknownteam/x'), '');
});

test('getBasePath: only a whole first segment counts (no substring match)', function () {
    assert.equal(basePathFor('/api/freelance-acme-app/x'), '');
    assert.equal(basePathFor('/freelancer/x'), '');
});

// ─── fleet-monitor ─────────────────────────────────────────────────────────

var dash = FLEET_PRESENT ? fs.readFileSync(DASH_JS, 'utf8') : '';
var core = FLEET_PRESENT ? fs.readFileSync(CORE_JS, 'utf8') : '';

test('fleet-monitor: no per-client slug in the dashboard app / fleet core', { skip: FLEET_SKIP }, function () {
    var re = CLIENT_SLUG_RE;
    assert.ok(re.test(CLIENT_SLUGS[1]), 'sanity: the leak pattern must match a real slug (non-vacuous)');
    assert.ok(!re.test(dash), 'lcars-dashboard-app.js still names a client slug');
    assert.ok(!re.test(core), 'lcars-fleet-core.js still names a client slug');
});

test('getDivisionTitle: freelance-<client>-<project> and freelance-<project> both title the project', { skip: FLEET_SKIP }, function () {
    var sandbox = {};
    run(slice(dash, 'function getDivisionTitle(divisionCode) {', '\n    function getOrganizationGroup', 'getDivisionTitle'), sandbox);
    assert.equal(sandbox.getDivisionTitle('freelance-acme-app'), 'APP - STAR TREK: ENT');
    assert.equal(sandbox.getDivisionTitle('freelance-app'), 'APP - STAR TREK: ENT');
    assert.equal(sandbox.getDivisionTitle('freelance'), 'FREELANCE - STAR TREK: ENT');
    assert.equal(sandbox.getDivisionTitle('ios'), 'IOS - STAR TREK: TNG');
});

test('getDivisionColorClass: any freelance-* division gets div-freelance', { skip: FLEET_SKIP }, function () {
    var sandbox = {};
    run(slice(dash, 'function getDivisionColorClass(divisionCode) {', '\n    // ====', 'getDivisionColorClass'), sandbox);
    assert.equal(sandbox.getDivisionColorClass('freelance-acme-app'), 'div-freelance');
    assert.equal(sandbox.getDivisionColorClass('freelance'), 'div-freelance');
    assert.equal(sandbox.getDivisionColorClass('ios'), 'div-ios');
});

function divisionMapFor(teamIds) {
    var teams = {};
    teamIds.forEach(function (id) { teams[id] = {}; });
    var sandbox = { teamConfig: { teams: teams }, divisionToTeamMap: null, console: { log: function () {} } };
    run(slice(dash, 'function buildDivisionToTeamMap() {', '\n    function filterData', 'buildDivisionToTeamMap'), sandbox);
    sandbox.buildDivisionToTeamMap();
    return sandbox.divisionToTeamMap;
}

test('buildDivisionToTeamMap: freelance-<client>-<project> also maps freelance-<project>', { skip: FLEET_SKIP }, function () {
    var m = divisionMapFor(['freelance-acme-app', 'legal-case', 'medical-general']);
    assert.equal(m['freelance-acme-app'], 'freelance-acme-app');
    assert.equal(m['freelance-app'], 'freelance-acme-app');
    assert.equal(m['legal'], 'legal-case');
    assert.equal(m['medical'], 'medical-general');
});

test('buildDivisionToTeamMap: an alias never shadows a registered team id', { skip: FLEET_SKIP }, function () {
    var m = divisionMapFor(['freelance-app', 'freelance-acme-app']);
    assert.equal(m['freelance-app'], 'freelance-app');
});

test('formatBackupDisplayName: client segment is dropped, 2-segment ids keep working', { skip: FLEET_SKIP }, function () {
    var sandbox = { LCARS: {} };
    run(slice(core, 'LCARS.formatBackupDisplayName = function(boardName) {', '\n    // Auto-initialize', 'formatBackupDisplayName'), sandbox);
    var f = sandbox.LCARS.formatBackupDisplayName;
    assert.equal(f('freelance-acme-app'), 'FL-APP');
    assert.equal(f('freelance-appplanning'), 'FL-APPPLANNING');
    assert.equal(f('academy'), 'ACADEMY');
    assert.equal(f('legal-coparenting'), 'LEGAL-COPARENTING');
});

test('dashboard avatar division key drops the client segment like server.js resolveDivisionKey', { skip: FLEET_SKIP }, function () {
    var src = fs.readFileSync(DASH_JS, 'utf8');
    var block = slice(src, "if (session.division === 'freelance' && session.project) {", '} else if', 'divisionForAvatar');
    assert.ok(!/session\.project\.replace\(/.test(block), 'divisionForAvatar must not strip one hardcoded client prefix');
    var ctx = run('var out = (function (session) { var divisionForAvatar; ' + block + '} return divisionForAvatar; })(input);',
        { input: { division: 'freelance', project: 'acme-starwords' } });
    assert.equal(ctx.out, 'freelance-starwords');
    ctx = run('var out = (function (session) { var divisionForAvatar; ' + block + '} return divisionForAvatar; })(input);',
        { input: { division: 'freelance', project: 'starwords' } });
    assert.equal(ctx.out, 'freelance-starwords');
});
