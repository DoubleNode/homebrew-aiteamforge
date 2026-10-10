#!/usr/bin/env node
//
//  test-xaca-1486-mode-memory-excluded.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * Regression coverage for XACA-1486: the global CC-USAGE page ('usage') must
 * never be stored in the per-mode section memory (lcars.modeSections).
 *
 * loadModeSections() and the constants are EXTRACTED from the shipped lcars.js
 * and run in a vm sandbox with a fake localStorage. switchSection() is far too
 * large to sandbox, so its write guard is asserted structurally on the source.
 *
 * Usage: node --test lcars-ui/tests/test-xaca-1486-mode-memory-excluded.js
 */

'use strict';

var test = require('node:test');
var assert = require('node:assert');
var fs = require('fs');
var path = require('path');
var vm = require('vm');

var SRC = fs.readFileSync(path.join(__dirname, '..', 'js', 'lcars.js'), 'utf8');

function slice(startMarker, endMarker) {
    var s = SRC.indexOf(startMarker);
    assert.ok(s !== -1, 'marker not found: ' + startMarker);
    var e = SRC.indexOf(endMarker, s);
    assert.ok(e !== -1, 'end marker not found: ' + endMarker);
    return SRC.slice(s, e);
}

// Brace-balanced extraction of a top-level function declaration.
function fn(name) {
    var s = SRC.indexOf('\nfunction ' + name + '(');
    assert.ok(s !== -1, 'function not found: ' + name);
    var open = SRC.indexOf('{', SRC.indexOf(')', s));
    var depth = 0;
    for (var i = open; i < SRC.length; i++) {
        if (SRC[i] === '{') depth++;
        else if (SRC[i] === '}' && --depth === 0) return SRC.slice(s, i + 1) + '\n';
    }
    throw new Error('unbalanced: ' + name);
}

function makeSandbox(stored) {
    var store = {};
    if (stored !== undefined) store['lcars.modeSections'] = JSON.stringify(stored);
    var sandbox = {
        console: { warn: function () {}, log: function () {} },
        SECTIONS: ['home', 'team-config', 'daily-overview', 'usage', 'backlog'],
        localStorage: {
            getItem: function (k) { return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null; },
            setItem: function (k, v) { store[k] = String(v); }
        }
    };
    vm.createContext(sandbox);
    vm.runInContext(slice('// Global pages that exist in EVERY mode', '// Queue filter state'), sandbox);
    vm.runInContext('const MODE_SECTIONS_KEY = \'lcars.modeSections\';' + fn('loadModeSections') + fn('saveModeSections') +
        fn('pickDefaultSectionForMode') + ';globalThis.loadModeSections = loadModeSections;', sandbox);
    sandbox.__store = store;
    return sandbox;
}

test('MODE_MEMORY_EXCLUDED contains the global usage page', function () {
    var sb = makeSandbox();
    assert.strictEqual(vm.runInContext("MODE_MEMORY_EXCLUDED.has('usage')", sb), true);
});

test('loadModeSections heals a stored {settings:usage} to the mode default and re-saves', function () {
    var sb = makeSandbox({ settings: 'usage', team: 'home' });
    var got = vm.runInContext('loadModeSections()', sb);
    assert.strictEqual(got.settings, 'team-config');
    assert.strictEqual(got.team, 'home');
    assert.strictEqual(JSON.parse(sb.__store['lcars.modeSections']).settings, 'team-config');
});

test('loadModeSections heals usage in every mode', function () {
    var sb = makeSandbox({ team: 'usage', kanban: 'usage', data: 'usage', settings: 'usage' });
    var got = vm.runInContext('loadModeSections()', sb);
    assert.deepStrictEqual(JSON.parse(JSON.stringify(got)),
        { team: 'home', kanban: 'daily-overview', data: 'home', settings: 'team-config' });
});

test('loadModeSections leaves legitimate remembered sections alone', function () {
    var sb = makeSandbox({ settings: 'backlog' });
    assert.strictEqual(vm.runInContext('loadModeSections()', sb).settings, 'backlog');
});

test('switchSection guards the modeSections write and the hash pre-seed on the exclusion set', function () {
    var sw = slice('// Global pages (MODE_MEMORY_EXCLUDED) are not remembered', '// Sync URL hash');
    assert.match(sw, /if \(!MODE_MEMORY_EXCLUDED\.has\(sectionName\)\)/);
    assert.match(sw, /modeSections\[activeMode\] = sectionName/);
    var seed = slice('if (_hashSection) {', 'switchMode(initialMode);');
    assert.match(seed, /MODE_MEMORY_EXCLUDED\.has\(_hashSection\)/);
});

// ─── Behavioural drive (XACA-1486-005) ───────────────────────────────────────
// Runs the REAL switchMode / switchSection / filterSectionsByMode / updateURLHash /
// loadModeSections / modechange listener / hash pre-seed block extracted from lcars.js
// against a minimal fake DOM + localStorage. Not a browser: CSS, animation and the
// data-mode element guard in switchSection (no section elements exist) are NOT exercised.

function makeRouter(opts) {
    opts = opts || {};
    var store = {};
    if (opts.stored !== undefined) store['lcars.modeSections'] = JSON.stringify(opts.stored);
    var doc = new EventTarget();
    doc.querySelector = function () { return null; };
    doc.querySelectorAll = function () { return []; };
    doc.getElementById = function () { return null; };
    doc.documentElement = { setAttribute: function () {} };
    var sandbox = {
        console: { warn: function () {}, log: function () {} },
        document: doc, CustomEvent: CustomEvent, setTimeout: function () {},
        window: {}, hashes: [],
        history: { replaceState: function (a, b, h) { sandbox.hashes.push(h); } },
        localStorage: {
            getItem: function (k) { return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null; },
            setItem: function (k, v) { store[k] = String(v); }
        },
        applyCarouselModeFilter: function () {}, homeFullscreen: false
    };
    // No-op every loader switchSection may call for a section.
    ['stopCarousel', 'stopExportPolling', 'stopImportPolling', 'stopRAGEnginesHealthPolling',
     'renderHomeAnalytics', 'initCarousel', 'loadBackupStatus', 'loadBackupFiles', 'loadReleases',
     'loadEpics', 'loadIntegrations', 'loadRAGEngines', 'initExportImportPanel', 'loadTodos',
     'loadTeamConfig', 'loadBoardSettings', 'loadReleaseGateEnforcement', 'loadReleaseLeads']
        .forEach(function (n) { sandbox[n] = function () {}; });
    vm.createContext(sandbox);
    var code =
        slice('// Tab navigation state', '// Queue filter state') +
        fn('getSectionClass') + fn('switchMode') + fn('filterSectionsByMode') +
        fn('pickDefaultSectionForMode') + fn('loadModeSections') + fn('saveModeSections') +
        fn('updateURLHash') + fn('switchSection') +
        slice("document.addEventListener('modechange'", '// Migration must run') +
        ';globalThis.__api = { switchMode: switchMode, switchSection: switchSection,' +
        ' get activeSection() { return activeSection; }, get activeMode() { return activeMode; },' +
        ' get pending() { return _pendingExcludedHashSection; },' +
        ' startFromHash: function (initialMode, _hashSection) {' +
        slice('if (_hashSection) {', 'switchMode(initialMode);') + 'switchMode(initialMode);' +
        slice('switchMode(initialMode);', '// filterSectionsByMode runs via').replace('switchMode(initialMode);', '') +
        '} };';
    vm.runInContext(code, sandbox);
    sandbox.__store = store;
    sandbox.stored = function () { return JSON.parse(store['lcars.modeSections'] || '{}'); };
    return sandbox;
}

test('flow: SETTINGS -> usage -> KANBAN -> SETTINGS lands on team-config, not usage', function () {
    var sb = makeRouter();
    var api = sb.__api;
    api.switchMode('settings');
    assert.strictEqual(api.activeSection, 'team-config');
    api.switchSection('usage', true);
    assert.strictEqual(api.activeSection, 'usage');
    assert.notStrictEqual(sb.stored().settings, 'usage', 'usage must not be stored for settings');
    api.switchMode('kanban');
    assert.strictEqual(api.activeSection, 'daily-overview');
    api.switchMode('settings');
    assert.strictEqual(api.activeSection, 'team-config');
});

test('flow: a real remembered section still round-trips (non-excluded control)', function () {
    var sb = makeRouter();
    var api = sb.__api;
    api.switchMode('settings');
    api.switchSection('backups', true);
    assert.strictEqual(sb.stored().settings, 'backups');
    api.switchMode('kanban');
    api.switchMode('settings');
    assert.strictEqual(api.activeSection, 'backups');
});

test('flow: a user already stuck with {settings:usage} is healed on next SETTINGS entry', function () {
    var sb = makeRouter({ stored: { settings: 'usage' } });
    sb.__api.switchMode('settings');
    assert.strictEqual(sb.__api.activeSection, 'team-config');
    assert.strictEqual(sb.stored().settings, 'team-config');
});

test('flow: deep-link #settings/usage opens usage once and does not persist', function () {
    var sb = makeRouter();
    var api = sb.__api;
    api.startFromHash('settings', 'usage');
    assert.strictEqual(api.activeSection, 'usage');
    assert.strictEqual(api.pending, null, 'one-shot must be consumed/cleared');
    assert.notStrictEqual(sb.stored().settings, 'usage');
    api.switchMode('kanban');
    api.switchMode('settings');
    assert.strictEqual(api.activeSection, 'team-config', 'second visit must not reopen usage');
});

test('flow: deep-link to a normal section is still persisted (control)', function () {
    var sb = makeRouter();
    sb.__api.startFromHash('settings', 'backups');
    assert.strictEqual(sb.__api.activeSection, 'backups');
    assert.strictEqual(sb.stored().settings, 'backups');
});

test('flow: unconsumed one-shot is cleared after the initial switchMode (mode already active)', function () {
    var sb = makeRouter();
    var api = sb.__api;
    api.switchMode('settings');            // mode already active -> switchMode no-ops, no modechange
    api.startFromHash('settings', 'usage');
    assert.strictEqual(api.pending, null);
    api.switchMode('kanban');
    assert.strictEqual(api.activeSection, 'daily-overview', 'stale one-shot must not hijack a later mode switch');
});

test('TURN GATES OFF button is the danger style, not the confirm style (XACA-1482 class)', function () {
    var html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
    var m = html.match(/<button\b[^>]*\bid="release-gates-lead-confirm"[^>]*>/);
    assert.ok(m, 'release-gates-lead-confirm button not found');
    assert.match(m[0], /class="[^"]*\bmodal-btn-danger\b/);
    assert.doesNotMatch(m[0], /modal-btn-confirm/);
});
