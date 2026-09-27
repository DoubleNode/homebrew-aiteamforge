//
//  test-xaca-1083-005-board-settings-render.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * test-xaca-1083-005-board-settings-render.js — Node-native headless coverage
 * for the XACA-1083-005 board-settings checkbox render/save logic in
 * lcars.js (loadBoardSettings / _renderBoardSettings /
 * _renderBoardSettingsFailClosed / saveBoardSettingsFlag).
 *
 * SCOPE: this suite covers the fail-closed rendering contract described in
 * the block comment above BOARD_SETTINGS_FIELDS in lcars.js — the render
 * logic, not real browser DOM/CSS or a real network. It stubs
 * document.getElementById with a fixed id->element map, and stubs
 * apiFetch/apiUrl/CONFIG the way the extracted code expects to find them as
 * globals. If the marker text below goes missing (the surrounding code was
 * refactored), extraction fails loudly instead of silently testing stale
 * text — same convention as test_xaca0920_copy_to_clipboard.js.
 *
 * Usage:
 *   node --test lcars-ui/tests/test-xaca-1083-005-board-settings-render.js
 *
 * No external dependencies. Node >=18 required (node:test, node:vm built-in).
 */

'use strict';

var test   = require('node:test');
var assert = require('node:assert/strict');
var path   = require('path');
var fs     = require('fs');
var vm     = require('vm');

var LCARS_JS_PATH = path.join(__dirname, '../js/lcars.js');
var SRC = fs.readFileSync(LCARS_JS_PATH, 'utf8');

// ─── Extract the whole BOARD SETTINGS block (self-contained: only touches
// ─── document.getElementById, apiFetch, apiUrl, CONFIG, console — all
// ─── stubbed below) ──────────────────────────────────────────────────────

var START_MARKER = '// =============================================================================\n// BOARD SETTINGS — XACA-1083-005';
var END_MARKER   = '\n// =============================================================================\n// CHANGE REQ SECTION — XACA-0292-006';

function extractBoardSettingsSrc() {
    var start = SRC.indexOf(START_MARKER);
    assert.ok(start !== -1, 'Could not locate BOARD SETTINGS block start marker in lcars.js — has it moved/been renamed?');
    var end = SRC.indexOf(END_MARKER, start + START_MARKER.length);
    assert.ok(end !== -1, 'Could not locate BOARD SETTINGS block end marker in lcars.js — has the following section changed?');
    return SRC.slice(start, end);
}

var boardSettingsSrc = extractBoardSettingsSrc();

// ─── Fake DOM ───────────────────────────────────────────────────────────────

var ELEMENT_IDS = [
    'board-settings-team-label',
    'board-settings-epic-checkbox', 'board-settings-epic-status',
    'board-settings-epic-default',
    'board-settings-release-checkbox', 'board-settings-release-status',
    'board-settings-release-default',
    'board-settings-cutoff-line', 'board-settings-cutoff-value',
    'board-settings-cutoff-none-line',
    'board-settings-error-row', 'board-settings-error-text',
];

function makeElement() {
    return {
        checked: false,
        disabled: false,
        onchange: null,
        textContent: '',
        className: '',
        title: '',
        style: { display: '' },
        _attrs: {},
        setAttribute: function (name, value) { this._attrs[name] = value; },
        getAttribute: function (name) {
            return Object.prototype.hasOwnProperty.call(this._attrs, name) ? this._attrs[name] : null;
        },
        removeAttribute: function (name) { delete this._attrs[name]; },
    };
}

function makeDom() {
    var elements = {};
    ELEMENT_IDS.forEach(function (id) { elements[id] = makeElement(); });
    return {
        elements: elements,
        getElementById: function (id) {
            return Object.prototype.hasOwnProperty.call(elements, id) ? elements[id] : null;
        },
    };
}

// ─── Sandbox factory ────────────────────────────────────────────────────────

/**
 * opts:
 *   fetchImpl {function(url, init) -> Promise<fakeResponse>} required.
 */
function makeEnv(opts) {
    opts = opts || {};
    var dom = makeDom();
    var consoleCalls = { log: [], warn: [], error: [] };
    var apiFetchCalls = [];

    var sandbox = {
        console: {
            log: function () { consoleCalls.log.push(Array.prototype.slice.call(arguments)); },
            warn: function () { consoleCalls.warn.push(Array.prototype.slice.call(arguments)); },
            error: function () { consoleCalls.error.push(Array.prototype.slice.call(arguments)); },
        },
        document: { getElementById: dom.getElementById },
        CONFIG: { team: (opts.team !== undefined ? opts.team : 'academy') },
        apiUrl: function (p) { return p; },
        apiFetch: function (url, init) {
            apiFetchCalls.push({ url: url, init: init });
            return opts.fetchImpl(url, init);
        },
        setTimeout: function () { /* no-op: tests don't wait out the 2s "Saved" fade */ },
        JSON: JSON,
    };
    sandbox.global = sandbox;
    vm.createContext(sandbox);
    vm.runInContext(boardSettingsSrc, sandbox, { filename: 'lcars-board-settings-extract.js' });

    return {
        sandbox: sandbox,
        dom: dom,
        consoleCalls: consoleCalls,
        apiFetchCalls: apiFetchCalls,
    };
}

function fakeJsonResponse(status, body) {
    return {
        ok: status >= 200 && status < 300,
        status: status,
        json: function () { return Promise.resolve(body); },
    };
}

var GOOD_RESPONSE = {
    team: 'academy',
    requireEpicOnStart: true,
    requireReleaseOnStart: false,
    requireEpicOnStartExplicit: false,   // resolved via fail-closed default -> "(default)" badge
    requireReleaseOnStartExplicit: true, // explicitly set by the team -> no badge
    grandfatherCutoff: '2026-09-26T22:02:39Z',
    loadError: null,
};

// ─── Tests ──────────────────────────────────────────────────────────────────

test('loadBoardSettings: normal response renders checkboxes, cutoff, team label, and default badges', async function () {
    var env = makeEnv({ fetchImpl: function () { return Promise.resolve(fakeJsonResponse(200, GOOD_RESPONSE)); } });

    await env.sandbox.loadBoardSettings();

    assert.equal(env.dom.elements['board-settings-team-label'].textContent, 'academy');
    assert.equal(env.dom.elements['board-settings-epic-checkbox'].checked, true);
    assert.equal(env.dom.elements['board-settings-epic-checkbox'].disabled, false);
    assert.equal(env.dom.elements['board-settings-release-checkbox'].checked, false);
    assert.equal(env.dom.elements['board-settings-release-checkbox'].disabled, false);

    // requireEpicOnStartExplicit=false -> "(default)" badge shown
    assert.equal(env.dom.elements['board-settings-epic-default'].style.display, 'inline-block');
    // requireReleaseOnStartExplicit=true -> no badge
    assert.equal(env.dom.elements['board-settings-release-default'].style.display, 'none');

    // XACA-1083-019: ONE shared cutoff line (not a per-row duplicate) —
    // human-formatted UTC text visible, raw ISO value preserved for
    // precision on <time datetime="">/title.
    assert.equal(env.dom.elements['board-settings-cutoff-value'].textContent, '26 Sep 2026, 22:02 UTC');
    assert.equal(env.dom.elements['board-settings-cutoff-value'].getAttribute('datetime'), '2026-09-26T22:02:39Z');
    assert.equal(env.dom.elements['board-settings-cutoff-value'].title, '2026-09-26T22:02:39Z');
    assert.equal(env.dom.elements['board-settings-cutoff-line'].style.display, '');
    assert.equal(env.dom.elements['board-settings-cutoff-none-line'].style.display, 'none');

    // No load error -> error row hidden
    assert.equal(env.dom.elements['board-settings-error-row'].style.display, 'none');
    assert.equal(env.dom.elements['board-settings-error-text'].textContent, '');

    // Both checkboxes get a live onchange handler wired for the toggle path
    assert.equal(typeof env.dom.elements['board-settings-epic-checkbox'].onchange, 'function');
    assert.equal(typeof env.dom.elements['board-settings-release-checkbox'].onchange, 'function');
});

test('loadBoardSettings: loadError in an otherwise-200 response renders BOTH boxes checked+disabled with a visible error (never unchecked)', async function () {
    var errorResponse = Object.assign({}, GOOD_RESPONSE, {
        loadError: 'board_settings.json at /tmp/x could not be parsed: bad json — fails closed to true/true',
        requireEpicOnStart: true,
        requireReleaseOnStart: true,
    });
    var env = makeEnv({ fetchImpl: function () { return Promise.resolve(fakeJsonResponse(200, errorResponse)); } });

    await env.sandbox.loadBoardSettings();

    assert.equal(env.dom.elements['board-settings-epic-checkbox'].checked, true);
    assert.equal(env.dom.elements['board-settings-epic-checkbox'].disabled, true);
    assert.equal(env.dom.elements['board-settings-release-checkbox'].checked, true);
    assert.equal(env.dom.elements['board-settings-release-checkbox'].disabled, true);
    assert.equal(env.dom.elements['board-settings-epic-checkbox'].onchange, null);
    assert.equal(env.dom.elements['board-settings-release-checkbox'].onchange, null);

    assert.equal(env.dom.elements['board-settings-error-row'].style.display, '');
    assert.match(env.dom.elements['board-settings-error-text'].textContent, /fails closed/);

    // A load-time failure must never surface the "(default)" badge — that
    // badge means "a real explicit read", which this response is not.
    assert.equal(env.dom.elements['board-settings-epic-default'].style.display, 'none');
    assert.equal(env.dom.elements['board-settings-release-default'].style.display, 'none');
});

test('loadBoardSettings: non-200 HTTP response fails closed with the server error message', async function () {
    var env = makeEnv({
        fetchImpl: function () { return Promise.resolve(fakeJsonResponse(400, { error: 'Unknown team: bogus' })); },
    });

    await env.sandbox.loadBoardSettings();

    assert.equal(env.dom.elements['board-settings-epic-checkbox'].checked, true);
    assert.equal(env.dom.elements['board-settings-epic-checkbox'].disabled, true);
    assert.match(env.dom.elements['board-settings-error-text'].textContent, /Unknown team: bogus/);
});

test('loadBoardSettings: a rejected fetch (network failure) fails closed rather than throwing', async function () {
    var env = makeEnv({ fetchImpl: function () { return Promise.reject(new Error('network down')); } });

    await env.sandbox.loadBoardSettings();

    assert.equal(env.dom.elements['board-settings-epic-checkbox'].checked, true);
    assert.equal(env.dom.elements['board-settings-epic-checkbox'].disabled, true);
    assert.equal(env.dom.elements['board-settings-release-checkbox'].checked, true);
    assert.equal(env.dom.elements['board-settings-release-checkbox'].disabled, true);
    assert.match(env.dom.elements['board-settings-error-text'].textContent, /network down/);
});

test('saveBoardSettingsFlag: on success, re-renders from the RESPONSE (not the click) and shows Saved', async function () {
    // Server's fresh re-read (POST response) deliberately disagrees with what
    // was clicked (simulating a concurrent writer) — the UI must trust the
    // response, not the click.
    var postResponse = Object.assign({}, GOOD_RESPONSE, {
        success: true,
        requireEpicOnStart: false,
        requireEpicOnStartExplicit: true,
    });
    var saveEnv = makeEnv({ fetchImpl: function () { return Promise.resolve(fakeJsonResponse(200, postResponse)); } });
    await saveEnv.sandbox.loadBoardSettings(); // seeds initial render + _lastGoodBoardSettings
    saveEnv.dom.elements['board-settings-epic-checkbox'].checked = true; // user clicks it on

    var epicField = {
        key: 'requireEpicOnStart',
        explicitKey: 'requireEpicOnStartExplicit',
        checkboxId: 'board-settings-epic-checkbox',
        statusId: 'board-settings-epic-status',
        defaultBadgeId: 'board-settings-epic-default',
    };
    await saveEnv.sandbox.saveBoardSettingsFlag(epicField);

    // Rendered from the response, which said false — not from the click, which said true.
    assert.equal(saveEnv.dom.elements['board-settings-epic-checkbox'].checked, false);
    assert.equal(saveEnv.dom.elements['board-settings-epic-checkbox'].disabled, false);
    assert.equal(saveEnv.dom.elements['board-settings-epic-status'].textContent, 'Saved');
    assert.equal(saveEnv.dom.elements['board-settings-epic-status'].className, 'team-config-status saved');

    // POST body carried the click's requested value, JSON-boolean typed.
    var postCall = saveEnv.apiFetchCalls.find(function (c) { return c.init && c.init.method === 'POST'; });
    assert.ok(postCall, 'expected a POST call');
    var body = JSON.parse(postCall.init.body);
    assert.equal(body.team, 'academy');
    assert.equal(body.requireEpicOnStart, true);
    assert.equal(typeof body.requireEpicOnStart, 'boolean');
});

test('saveBoardSettingsFlag: on failure, reverts to the last known-good server state and shows an error (no optimistic success)', async function () {
    var env = makeEnv({ fetchImpl: function () { return Promise.resolve(fakeJsonResponse(200, GOOD_RESPONSE)); } });
    await env.sandbox.loadBoardSettings();

    // GOOD_RESPONSE.requireEpicOnStart === true; user unchecks it, POST fails.
    env.dom.elements['board-settings-epic-checkbox'].checked = false;

    var failingEnv = makeEnv({ fetchImpl: function () { return Promise.resolve(fakeJsonResponse(500, { success: false, error: 'write failed' })); } });
    await failingEnv.sandbox.loadBoardSettings(); // seed _lastGoodBoardSettings
    failingEnv.dom.elements['board-settings-epic-checkbox'].checked = false;

    var epicField = {
        key: 'requireEpicOnStart',
        explicitKey: 'requireEpicOnStartExplicit',
        checkboxId: 'board-settings-epic-checkbox',
        statusId: 'board-settings-epic-status',
        defaultBadgeId: 'board-settings-epic-default',
    };
    await failingEnv.sandbox.saveBoardSettingsFlag(epicField);

    // Reverted to last known-good (true), NOT left at the failed click (false).
    assert.equal(failingEnv.dom.elements['board-settings-epic-checkbox'].checked, true);
    assert.equal(failingEnv.dom.elements['board-settings-epic-checkbox'].disabled, false);
    assert.equal(failingEnv.dom.elements['board-settings-epic-status'].textContent, 'Save failed');
    assert.equal(failingEnv.dom.elements['board-settings-epic-status'].className, 'team-config-status error');
    assert.match(failingEnv.dom.elements['board-settings-error-text'].textContent, /write failed/);
});

test('saveBoardSettingsFlag: disables the checkbox for the duration of the POST', async function () {
    var resolvePost;
    var pending = new Promise(function (resolve) { resolvePost = resolve; });
    var env = makeEnv({ fetchImpl: function () { return Promise.resolve(fakeJsonResponse(200, GOOD_RESPONSE)); } });
    await env.sandbox.loadBoardSettings();

    var inFlightEnv = makeEnv({
        fetchImpl: function (url, init) {
            if (init && init.method === 'POST') return pending;
            return Promise.resolve(fakeJsonResponse(200, GOOD_RESPONSE));
        },
    });
    await inFlightEnv.sandbox.loadBoardSettings();
    inFlightEnv.dom.elements['board-settings-epic-checkbox'].checked = false;

    var epicField = {
        key: 'requireEpicOnStart',
        explicitKey: 'requireEpicOnStartExplicit',
        checkboxId: 'board-settings-epic-checkbox',
        statusId: 'board-settings-epic-status',
        defaultBadgeId: 'board-settings-epic-default',
    };
    var savePromise = inFlightEnv.sandbox.saveBoardSettingsFlag(epicField);

    // While the POST is in flight, the checkbox must be disabled.
    assert.equal(inFlightEnv.dom.elements['board-settings-epic-checkbox'].disabled, true);
    assert.equal(inFlightEnv.dom.elements['board-settings-epic-status'].textContent, 'Saving...');

    resolvePost(fakeJsonResponse(200, Object.assign({}, GOOD_RESPONSE, { success: true, requireEpicOnStart: false })));
    await savePromise;

    assert.equal(inFlightEnv.dom.elements['board-settings-epic-checkbox'].disabled, false);
});

test('loadBoardSettings: missing/invalid grandfatherCutoff renders the fail-closed "no items are exempt" line, never blank or Invalid Date (XACA-1083-018/019)', async function () {
    var casesEl = [null, undefined, '', 'not-a-real-timestamp'];
    for (var i = 0; i < casesEl.length; i++) {
        var badCutoffResponse = Object.assign({}, GOOD_RESPONSE, { grandfatherCutoff: casesEl[i] });
        var env = makeEnv({ fetchImpl: function () { return Promise.resolve(fakeJsonResponse(200, badCutoffResponse)); } });

        await env.sandbox.loadBoardSettings();

        // The fail-closed alternate line is shown, the normal templated
        // sentence is hidden -- never left rendering "Invalid Date" or "--".
        assert.equal(env.dom.elements['board-settings-cutoff-line'].style.display, 'none', 'case ' + i);
        assert.equal(env.dom.elements['board-settings-cutoff-none-line'].style.display, '', 'case ' + i);
        assert.doesNotMatch(env.dom.elements['board-settings-cutoff-value'].textContent, /Invalid Date/, 'case ' + i);
    }
});

test('loadBoardSettings: a loadError response also renders the fail-closed cutoff line, not a stale prior value', async function () {
    var errorResponse = Object.assign({}, GOOD_RESPONSE, {
        loadError: 'board_settings.json could not be parsed — fails closed to true/true',
    });
    var env = makeEnv({ fetchImpl: function () { return Promise.resolve(fakeJsonResponse(200, errorResponse)); } });

    await env.sandbox.loadBoardSettings();

    assert.equal(env.dom.elements['board-settings-cutoff-line'].style.display, 'none');
    assert.equal(env.dom.elements['board-settings-cutoff-none-line'].style.display, '');
});
