//
//  test-xaca-1482-release-gates-render.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 DoubleNode.com. All rights reserved.
//

/**
 * Node-native headless coverage for the XACA-1482-003 Release Gates checkbox
 * (loadReleaseGateEnforcement / _renderReleaseGateEnforcement /
 * _renderReleaseGatesFailClosed / onReleaseGatesChange) in lcars.js.
 * Same harness as test-xaca-1083-005-board-settings-render.js: extracts the
 * marked block, stubs document/apiFetch/apiUrl/CONFIG/prompt, fails loudly if
 * the markers move.
 *
 * Usage: node --test lcars-ui/tests/test-xaca-1482-release-gates-render.js
 */

'use strict';

var test   = require('node:test');
var assert = require('node:assert/strict');
var path   = require('path');
var fs     = require('fs');
var vm     = require('vm');

var SRC = fs.readFileSync(path.join(__dirname, '../js/lcars.js'), 'utf8');

var START_MARKER = '// =============================================================================\n// RELEASE GATES — XACA-1482-003';
var END_MARKER   = '// =============================================================================\n// BOARD SETTINGS — XACA-1083-005';

function extractSrc() {
    var start = SRC.indexOf(START_MARKER);
    assert.ok(start !== -1, 'Could not locate RELEASE GATES block start marker in lcars.js');
    var end = SRC.indexOf(END_MARKER, start + START_MARKER.length);
    assert.ok(end !== -1, 'Could not locate RELEASE GATES block end marker in lcars.js');
    return SRC.slice(start, end);
}
var blockSrc = extractSrc();

var ELEMENT_IDS = [
    'release-gates-team-label', 'release-gates-checkbox', 'release-gates-default',
    'release-gates-status', 'release-gates-error-row', 'release-gates-error-text',
];

function makeElement() {
    return { checked: false, disabled: false, onchange: null, textContent: '', className: '', style: { display: '' } };
}

/** opts: fetchImpl (required), promptImpl, team */
function makeEnv(opts) {
    var elements = {};
    ELEMENT_IDS.forEach(function (id) { elements[id] = makeElement(); });
    var apiFetchCalls = [];
    var promptCalls = [];
    var sandbox = {
        console: { log: function () {}, warn: function () {}, error: function () {} },
        document: { getElementById: function (id) { return Object.prototype.hasOwnProperty.call(elements, id) ? elements[id] : null; } },
        CONFIG: { team: (opts.team !== undefined ? opts.team : 'academy') },
        apiUrl: function (p) { return p; },
        apiFetch: function (url, init) { apiFetchCalls.push({ url: url, init: init }); return opts.fetchImpl(url, init); },
        prompt: function (msg) { promptCalls.push(msg); return opts.promptImpl ? opts.promptImpl(msg) : null; },
        JSON: JSON,
    };
    vm.createContext(sandbox);
    vm.runInContext(blockSrc, sandbox, { filename: 'lcars-release-gates-extract.js' });
    return { sandbox: sandbox, el: elements, apiFetchCalls: apiFetchCalls, promptCalls: promptCalls };
}

function resp(status, body) {
    return { ok: status >= 200 && status < 300, status: status, json: function () { return Promise.resolve(body); } };
}
function getOnly(status, body) { return function () { return Promise.resolve(resp(status, body)); }; }
function ok(mode, explicit, warn) { return { team: 'academy', mode: mode, explicit: explicit, configWarning: warn || null }; }

function assertFailClosed(env) {
    assert.equal(env.el['release-gates-checkbox'].checked, true);
    assert.equal(env.el['release-gates-checkbox'].disabled, true);
    assert.equal(env.el['release-gates-checkbox'].onchange, null);
    assert.equal(env.el['release-gates-error-row'].style.display, '');
    assert.notEqual(env.el['release-gates-error-text'].textContent, '');
    assert.equal(env.el['release-gates-default'].style.display, 'none');
}

// GET returns (mode, explicit); POST delegates to postImpl.
function seeded(mode, explicit, postImpl, promptImpl) {
    return makeEnv({
        promptImpl: promptImpl,
        fetchImpl: function (url, init) {
            if (init && init.method === 'POST') return postImpl(url, init);
            return Promise.resolve(resp(200, ok(mode, explicit)));
        },
    });
}
function postsOf(env) {
    return env.apiFetchCalls.filter(function (c) { return c.init && c.init.method === 'POST'; });
}

test('report (explicit) -> unchecked, enabled, no badge, status text', async function () {
    var env = makeEnv({ fetchImpl: getOnly(200, ok('report', true)) });
    await env.sandbox.loadReleaseGateEnforcement();
    assert.equal(env.el['release-gates-team-label'].textContent, 'academy');
    assert.equal(env.el['release-gates-checkbox'].checked, false);
    assert.equal(env.el['release-gates-checkbox'].disabled, false);
    assert.equal(env.el['release-gates-default'].style.display, 'none');
    assert.equal(env.el['release-gates-status'].textContent, 'Gates report-only (explicit)');
    assert.equal(env.el['release-gates-error-row'].style.display, 'none');
    assert.equal(typeof env.el['release-gates-checkbox'].onchange, 'function');
});

test('enforce explicit -> checked, no default badge', async function () {
    var env = makeEnv({ fetchImpl: getOnly(200, ok('enforce', true)) });
    await env.sandbox.loadReleaseGateEnforcement();
    assert.equal(env.el['release-gates-checkbox'].checked, true);
    assert.equal(env.el['release-gates-checkbox'].disabled, false);
    assert.equal(env.el['release-gates-default'].style.display, 'none');
    assert.equal(env.el['release-gates-status'].textContent, 'Gates enforced (explicit)');
});

test('key absent (explicit=false) -> checked + (default) badge', async function () {
    var env = makeEnv({ fetchImpl: getOnly(200, ok('enforce', false)) });
    await env.sandbox.loadReleaseGateEnforcement();
    assert.equal(env.el['release-gates-checkbox'].checked, true);
    assert.equal(env.el['release-gates-default'].style.display, 'inline-block');
    assert.equal(env.el['release-gates-status'].textContent, 'Gates enforced (default)');
});

test('configWarning is shown; box reflects resolved enforce', async function () {
    var env = makeEnv({ fetchImpl: getOnly(200, ok('enforce', true, 'gateEnforcement "bogus" is invalid; treating as enforce')) });
    await env.sandbox.loadReleaseGateEnforcement();
    assert.equal(env.el['release-gates-checkbox'].checked, true);
    assert.equal(env.el['release-gates-checkbox'].disabled, false);
    assert.equal(env.el['release-gates-error-row'].style.display, '');
    assert.match(env.el['release-gates-error-text'].textContent, /invalid/);
});

test('fail-closed: rejected fetch', async function () {
    var env = makeEnv({ fetchImpl: function () { return Promise.reject(new Error('network down')); } });
    await env.sandbox.loadReleaseGateEnforcement();
    assertFailClosed(env);
    assert.match(env.el['release-gates-error-text'].textContent, /network down/);
});

test('fail-closed: HTTP 500 (error key and message key)', async function () {
    var env = makeEnv({ fetchImpl: getOnly(500, { error: 'boom' }) });
    await env.sandbox.loadReleaseGateEnforcement();
    assertFailClosed(env);
    assert.match(env.el['release-gates-error-text'].textContent, /boom/);
    var env2 = makeEnv({ fetchImpl: getOnly(500, { message: 'kaboom' }) });
    await env2.sandbox.loadReleaseGateEnforcement();
    assertFailClosed(env2);
    assert.match(env2.el['release-gates-error-text'].textContent, /kaboom/);
});

test('fail-closed: malformed bodies and non-literal modes', async function () {
    var bodies = [null, 'str', {}, { mode: 'Enforce' }, { mode: 'enforce ' }, { mode: true }, { mode: null }, { mode: 1 }];
    for (var i = 0; i < bodies.length; i++) {
        var env = makeEnv({ fetchImpl: getOnly(200, bodies[i]) });
        await env.sandbox.loadReleaseGateEnforcement();
        assertFailClosed(env);
    }
});

test('server text is written via textContent verbatim (not interpreted as HTML)', async function () {
    var env = makeEnv({ fetchImpl: getOnly(500, { error: '<img src=x onerror=alert(1)>' }) });
    await env.sandbox.loadReleaseGateEnforcement();
    assert.match(env.el['release-gates-error-text'].textContent, /<img src=x/);
    assert.equal(env.el['release-gates-error-text'].innerHTML, undefined);
});

test('uncheck with cancelled prompt -> no fetch, box re-checked', async function () {
    var env = seeded('enforce', true, function () { throw new Error('should not POST'); }, function () { return null; });
    await env.sandbox.loadReleaseGateEnforcement();
    var before = env.apiFetchCalls.length;
    env.el['release-gates-checkbox'].checked = false;
    await env.el['release-gates-checkbox'].onchange();
    assert.equal(env.promptCalls.length, 1);
    assert.equal(env.apiFetchCalls.length, before);
    assert.equal(env.el['release-gates-checkbox'].checked, true);
    assert.equal(env.el['release-gates-checkbox'].disabled, false);
});

test('uncheck with whitespace-only lead -> no fetch, box re-checked', async function () {
    var env = seeded('enforce', true, function () { throw new Error('no'); }, function () { return '   '; });
    await env.sandbox.loadReleaseGateEnforcement();
    var before = env.apiFetchCalls.length;
    env.el['release-gates-checkbox'].checked = false;
    await env.el['release-gates-checkbox'].onchange();
    assert.equal(env.apiFetchCalls.length, before);
    assert.equal(env.el['release-gates-checkbox'].checked, true);
});

test('uncheck with lead -> POST {team,mode:report,actor}; renders from RESPONSE', async function () {
    var env = seeded('enforce', true, function () {
        return Promise.resolve(resp(200, { team: 'academy', mode: 'report', explicit: true, configWarning: null, changed: true }));
    }, function () { return ' picard '; });
    await env.sandbox.loadReleaseGateEnforcement();
    env.el['release-gates-checkbox'].checked = false;
    await env.el['release-gates-checkbox'].onchange();
    var posts = postsOf(env);
    assert.equal(posts.length, 1);
    assert.deepEqual(JSON.parse(posts[0].init.body), { team: 'academy', mode: 'report', actor: 'picard' });
    assert.equal(env.el['release-gates-checkbox'].checked, false);
    assert.equal(env.el['release-gates-checkbox'].disabled, false);
    assert.equal(env.el['release-gates-status'].textContent, 'Gates report-only (explicit)');
});

test('response disagrees with request -> UI trusts the response', async function () {
    var env = seeded('enforce', true, function () { return Promise.resolve(resp(200, ok('enforce', true))); }, function () { return 'picard'; });
    await env.sandbox.loadReleaseGateEnforcement();
    env.el['release-gates-checkbox'].checked = false;
    await env.el['release-gates-checkbox'].onchange();
    assert.equal(env.el['release-gates-checkbox'].checked, true);
});

test('403 -> box reverted to prior state and server reason shown', async function () {
    var env = seeded('enforce', true, function () {
        return Promise.resolve(resp(403, { error: 'nobody is not a release lead' }));
    }, function () { return 'nobody'; });
    await env.sandbox.loadReleaseGateEnforcement();
    env.el['release-gates-checkbox'].checked = false;
    await env.el['release-gates-checkbox'].onchange();
    assert.equal(env.el['release-gates-checkbox'].checked, true);
    assert.equal(env.el['release-gates-checkbox'].disabled, false);
    assert.equal(env.el['release-gates-error-row'].style.display, '');
    assert.match(env.el['release-gates-error-text'].textContent, /not a release lead/);
    assert.equal(env.el['release-gates-status'].textContent, 'Save failed');
});

test('409 with "message" key -> reason shown', async function () {
    var env = seeded('report', true, function () {
        return Promise.resolve(resp(409, { message: 'conflict happened' }));
    });
    await env.sandbox.loadReleaseGateEnforcement();
    env.el['release-gates-checkbox'].checked = true;
    await env.el['release-gates-checkbox'].onchange();
    assert.equal(env.el['release-gates-checkbox'].checked, false); // prior state restored
    assert.match(env.el['release-gates-error-text'].textContent, /conflict happened/);
});

test('malformed 200 on POST -> reverted with error', async function () {
    var env = seeded('enforce', true, function () { return Promise.resolve(resp(200, { mode: 'nope' })); }, function () { return 'picard'; });
    await env.sandbox.loadReleaseGateEnforcement();
    env.el['release-gates-checkbox'].checked = false;
    await env.el['release-gates-checkbox'].onchange();
    assert.equal(env.el['release-gates-checkbox'].checked, true);
    assert.match(env.el['release-gates-error-text'].textContent, /malformed/);
});

test('check -> POST enforce without actor, no prompt', async function () {
    var env = seeded('report', true, function () {
        return Promise.resolve(resp(200, { team: 'academy', mode: 'enforce', explicit: true, configWarning: null, changed: true }));
    });
    await env.sandbox.loadReleaseGateEnforcement();
    env.el['release-gates-checkbox'].checked = true;
    await env.el['release-gates-checkbox'].onchange();
    var body = JSON.parse(postsOf(env)[0].init.body);
    assert.deepEqual(body, { team: 'academy', mode: 'enforce' });
    assert.equal('actor' in body, false);
    assert.equal(env.promptCalls.length, 0);
    assert.equal(env.el['release-gates-checkbox'].checked, true);
});

test('box is disabled while the POST is in flight', async function () {
    var resolvePost;
    var pending = new Promise(function (r) { resolvePost = r; });
    var env = seeded('report', true, function () { return pending; });
    await env.sandbox.loadReleaseGateEnforcement();
    env.el['release-gates-checkbox'].checked = true;
    var p = env.el['release-gates-checkbox'].onchange();
    assert.equal(env.el['release-gates-checkbox'].disabled, true);
    assert.equal(env.el['release-gates-status'].textContent, 'Saving...');
    resolvePost(resp(200, ok('enforce', true)));
    await p;
    assert.equal(env.el['release-gates-checkbox'].disabled, false);
});
