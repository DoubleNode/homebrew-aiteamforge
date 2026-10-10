//
//  test-xaca-1485-release-leads-render.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 DoubleNode.com. All rights reserved.
//

/**
 * Node-native headless coverage for the XACA-1485-003 Release Leads roster editor
 * (loadReleaseLeads / _renderReleaseLeads / onReleaseLeadAdd / onReleaseLeadRemove) and
 * its reuse of the XACA-1482 lead modal. Same harness as
 * test-xaca-1482-release-gates-render.js: extracts the marked block (RELEASE GATES through
 * the end of RELEASE LEADS), stubs document/apiFetch/apiUrl/CONFIG/setTimeout.
 *
 * Usage: node --test lcars-ui/tests/test-xaca-1485-release-leads-render.js
 */

'use strict';

var test   = require('node:test');
var assert = require('node:assert/strict');
var path   = require('path');
var fs     = require('fs');
var vm     = require('vm');

var SRC = fs.readFileSync(path.join(__dirname, '../js/lcars.js'), 'utf8');

var START_MARKER = '// =============================================================================\n// RELEASE GATES — XACA-1482-003';
var LEADS_MARKER = '// =============================================================================\n// RELEASE LEADS — XACA-1485-003';
var END_MARKER   = '// =============================================================================\n// BOARD SETTINGS — XACA-1083-005';

function extractSrc() {
    var start = SRC.indexOf(START_MARKER);
    assert.ok(start !== -1, 'Could not locate RELEASE GATES block start marker in lcars.js');
    var leads = SRC.indexOf(LEADS_MARKER, start);
    assert.ok(leads !== -1, 'Could not locate RELEASE LEADS block marker in lcars.js');
    var end = SRC.indexOf(END_MARKER, leads);
    assert.ok(end !== -1, 'Could not locate BOARD SETTINGS end marker in lcars.js');
    return SRC.slice(start, end);
}
var blockSrc = extractSrc();

var ELEMENT_IDS = [
    'release-leads-list', 'release-leads-empty', 'release-leads-input', 'release-leads-add',
    'release-leads-status', 'release-leads-error-row', 'release-leads-error-text',
    // release gates section (loadReleaseGateEnforcement is re-called after a change)
    'release-gates-team-label', 'release-gates-checkbox', 'release-gates-default',
    'release-gates-status', 'release-gates-error-row', 'release-gates-error-text',
    // shared lead modal
    'release-gates-lead-modal', 'release-gates-lead-title', 'release-gates-lead-consequence',
    'release-gates-lead-select', 'release-gates-lead-confirm', 'release-gates-lead-cancel',
    'release-gates-lead-close',
];

/**
 * HTMLCollection-like: indexed + length + item(), but NOT an Array (no map/forEach/filter),
 * so code that does Array.isArray(el.children) or el.children.forEach misbehaves like it
 * would in a real browser (XACA-1485-012).
 */
function makeCollection(arr) {
    var c = { length: arr.length, item: function (i) { return arr[i] || null; } };
    arr.forEach(function (x, i) { c[i] = x; });
    c[Symbol.iterator] = function () { return arr[Symbol.iterator](); };
    return c;
}
function kidsOf(el) { return Array.from(el.children); }

function makeElement(id) {
    var kids = [];
    var el = {
        id: id, checked: false, disabled: false, onchange: null, onclick: null, onkeydown: null,
        className: '', value: '', style: { display: '' }, focusCount: 0, attrs: {},
        innerHTMLWrites: 0,
        appendChild: function (c) { kids.push(c); return c; },
        setAttribute: function (k, v) { el.attrs[k] = v; },
        focus: function () { el.focusCount++; },
    };
    var text = '';
    Object.defineProperty(el, 'textContent', {
        get: function () { return text; },
        set: function (v) { text = v; if (v === '') kids.length = 0; },
    });
    Object.defineProperty(el, 'children', {
        get: function () { return makeCollection(kids); },
    });
    // Names are user data: nothing may ever assign innerHTML.
    Object.defineProperty(el, 'innerHTML', {
        get: function () { return ''; },
        set: function () { el.innerHTMLWrites++; },
    });
    return el;
}

function makeEnv(opts) {
    var elements = {};
    ELEMENT_IDS.forEach(function (id) { elements[id] = makeElement(id); });
    elements['release-gates-lead-modal'].style.display = 'none';
    var apiFetchCalls = [];
    var sandbox = {
        console: { log: function () {}, warn: function () {}, error: function () {} },
        document: {
            getElementById: function (id) { return Object.prototype.hasOwnProperty.call(elements, id) ? elements[id] : null; },
            createElement: function () { return makeElement('dyn'); },
        },
        CONFIG: { team: 'academy' },
        apiUrl: function (p) { return p; },
        apiFetch: function (url, init) { apiFetchCalls.push({ url: url, init: init }); return opts.fetchImpl(url, init); },
        setTimeout: function () { return 1; },
        pauseAutoRefresh: function () {},
        resumeAutoRefresh: function () {},
        prompt: function () { throw new Error('window.prompt must not be used'); },
        JSON: JSON,
    };
    vm.createContext(sandbox);
    vm.runInContext(blockSrc, sandbox, { filename: 'lcars-release-leads-extract.js' });
    return { sandbox: sandbox, el: elements, apiFetchCalls: apiFetchCalls };
}

function resp(status, body) {
    return { ok: status >= 200 && status < 300, status: status, json: function () { return Promise.resolve(body); } };
}
function roster(leads, extra) {
    var b = { team: 'academy', leads: leads, configured: leads.length > 0, writable: true, configWarning: null };
    if (extra) Object.keys(extra).forEach(function (k) { b[k] = extra[k]; });
    return b;
}
function isLeadsUrl(url) { return url === '/api/release-leads'; }
function isGateUrl(url) { return url === '/api/release-gate-enforcement'; }

/**
 * GET /api/release-leads -> getBody; POST -> postImpl(init); gate-enforcement GET -> 200 enforce.
 */
function seeded(getBody, postImpl) {
    return makeEnv({
        fetchImpl: function (url, init) {
            if (isGateUrl(url)) {
                return Promise.resolve(resp(200, { team: 'academy', mode: 'enforce', explicit: true, writable: true, leads: [], configWarning: null }));
            }
            if (init && init.method === 'POST') return postImpl(init);
            return Promise.resolve(resp(200, getBody));
        },
    });
}
function postsOf(env) {
    return env.apiFetchCalls.filter(function (c) { return isLeadsUrl(c.url) && c.init && c.init.method === 'POST'; });
}
function names(env) {
    return kidsOf(env.el['release-leads-list']).map(function (row) { return row.children[0].textContent; });
}
function removeButtons(env) {
    return kidsOf(env.el['release-leads-list']).map(function (row) { return row.children[1]; });
}
function assertFailClosed(env) {
    assert.equal(env.el['release-leads-list'].children.length, 0);
    assert.equal(env.el['release-leads-input'].disabled, true);
    assert.equal(env.el['release-leads-add'].disabled, true);
    assert.equal(env.el['release-leads-add'].onclick, null);
    assert.equal(env.el['release-leads-error-row'].style.display, '');
    assert.notEqual(env.el['release-leads-error-text'].textContent, '');
}
/** Let the handler run up to the parked modal. */
async function tick() { await Promise.resolve(); await Promise.resolve(); }
function clickModal(env, which) { env.el['release-gates-lead-' + which].onclick(); }

test('TEAM_SCOPED_PREFIXES includes /api/release-leads', function () {
    var m = /const TEAM_SCOPED_PREFIXES = \[([\s\S]*?)\];/.exec(SRC);
    assert.ok(m, 'TEAM_SCOPED_PREFIXES not found');
    assert.match(m[1], /'\/api\/release-leads'/);
});

test('render: non-empty roster lists names with enabled remove buttons, empty hint hidden', async function () {
    var env = seeded(roster(['Nahla', 'Reno']));
    await env.sandbox.loadReleaseLeads();
    assert.deepEqual(names(env), ['Nahla', 'Reno']);
    removeButtons(env).forEach(function (b) { assert.equal(b.disabled, false); assert.equal(typeof b.onclick, 'function'); });
    assert.equal(removeButtons(env)[0].attrs['aria-label'], 'Remove release lead Nahla');
    assert.equal(env.el['release-leads-empty'].style.display, 'none');
    assert.equal(env.el['release-leads-input'].disabled, false);
    assert.equal(env.el['release-leads-add'].disabled, false);
    assert.equal(env.el['release-leads-error-row'].style.display, 'none');
});

test('render: empty roster shows the empty hint and an enabled add form', async function () {
    var env = seeded(roster([]));
    await env.sandbox.loadReleaseLeads();
    assert.deepEqual(names(env), []);
    assert.equal(env.el['release-leads-empty'].style.display, '');
    assert.equal(env.el['release-leads-input'].disabled, false);
    assert.equal(env.el['release-leads-add'].disabled, false);
});

test('render: configWarning is shown; writable:false disables controls', async function () {
    var env = seeded(roster(['Nahla'], { configWarning: 'releaseConfig.leads has 1 entry that is not a valid name' }));
    await env.sandbox.loadReleaseLeads();
    assert.equal(env.el['release-leads-error-row'].style.display, '');
    assert.match(env.el['release-leads-error-text'].textContent, /not a valid name/);
    assert.equal(env.el['release-leads-add'].disabled, false);

    var env2 = seeded(roster(['Nahla'], { writable: false }));
    await env2.sandbox.loadReleaseLeads();
    assert.equal(env2.el['release-leads-add'].disabled, true);
    assert.equal(env2.el['release-leads-input'].disabled, true);
    assert.equal(removeButtons(env2)[0].disabled, true);
    assert.equal(removeButtons(env2)[0].onclick, null);
    assert.equal(env2.el['release-leads-error-row'].style.display, '');
});

test('fail-closed: non-200, bad JSON, network error, malformed bodies', async function () {
    var env = makeEnv({ fetchImpl: function () { return Promise.resolve(resp(500, { error: 'boom' })); } });
    await env.sandbox.loadReleaseLeads();
    assertFailClosed(env);
    assert.match(env.el['release-leads-error-text'].textContent, /boom/);

    var env2 = makeEnv({ fetchImpl: function () { return Promise.resolve({ ok: true, status: 200, json: function () { return Promise.reject(new Error('bad json')); } }); } });
    await env2.sandbox.loadReleaseLeads();
    assertFailClosed(env2);

    var env3 = makeEnv({ fetchImpl: function () { return Promise.reject(new Error('network down')); } });
    await env3.sandbox.loadReleaseLeads();
    assertFailClosed(env3);
    assert.match(env3.el['release-leads-error-text'].textContent, /network down/);

    var bodies = [null, 'str', {}, { leads: 'Nahla' }, { leads: [1, 2] }, { leads: ['ok', null] }];
    for (var i = 0; i < bodies.length; i++) {
        var e = makeEnv({ fetchImpl: function () { return Promise.resolve(resp(200, bodies[i])); } });
        await e.sandbox.loadReleaseLeads();
        assertFailClosed(e);
    }
});

test('fail-closed load after a good load clears the previously rendered roster', async function () {
    var n = 0;
    var env = makeEnv({ fetchImpl: function () {
        n++;
        return Promise.resolve(n === 1 ? resp(200, roster(['Nahla'])) : resp(503, { error: 'down' }));
    } });
    await env.sandbox.loadReleaseLeads();
    assert.deepEqual(names(env), ['Nahla']);
    await env.sandbox.loadReleaseLeads();
    assertFailClosed(env);
});

test('add on EMPTY roster: no modal, no actor in the POST', async function () {
    var env = seeded(roster([]), function () { return Promise.resolve(resp(200, roster(['Reno'], { changed: true, success: true }))); });
    await env.sandbox.loadReleaseLeads();
    env.el['release-leads-input'].value = '  Reno ';
    await env.sandbox.onReleaseLeadAdd();
    assert.equal(env.el['release-gates-lead-modal'].style.display, 'none');
    var posts = postsOf(env);
    assert.equal(posts.length, 1);
    var body = JSON.parse(posts[0].init.body);
    assert.deepEqual(body, { team: 'academy', op: 'add', name: 'Reno' });
    assert.equal(Object.prototype.hasOwnProperty.call(body, 'actor'), false);
    assert.deepEqual(names(env), ['Reno']);
    assert.equal(env.el['release-leads-input'].value, '');
});

test('add on non-empty roster: goes through the lead modal and sends the chosen actor', async function () {
    var env = seeded(roster(['Nahla', 'Reno']), function () { return Promise.resolve(resp(200, roster(['Nahla', 'Reno', 'Thok'], { changed: true }))); });
    await env.sandbox.loadReleaseLeads();
    env.el['release-leads-input'].value = 'Thok';
    var p = env.sandbox.onReleaseLeadAdd();
    await tick();
    assert.equal(env.el['release-gates-lead-modal'].style.display, 'flex');
    assert.equal(postsOf(env).length, 0);
    assert.equal(env.el['release-gates-lead-title'].textContent, 'ADD RELEASE LEAD');
    assert.match(env.el['release-gates-lead-consequence'].textContent, /Thok/);
    assert.equal(env.el['release-gates-lead-confirm'].textContent, 'ADD LEAD');
    assert.deepEqual(kidsOf(env.el['release-gates-lead-select']).map(function (o) { return o.value; }), ['Nahla', 'Reno']);
    env.el['release-gates-lead-select'].value = 'Reno';
    clickModal(env, 'confirm');
    await p;
    assert.equal(env.el['release-gates-lead-modal'].style.display, 'none');
    var body = JSON.parse(postsOf(env)[0].init.body);
    assert.deepEqual(body, { team: 'academy', op: 'add', name: 'Thok', actor: 'Reno' });
    assert.deepEqual(names(env), ['Nahla', 'Reno', 'Thok']);
});

test('remove on non-empty roster: modal, chosen actor sent', async function () {
    var env = seeded(roster(['Nahla', 'Reno']), function () { return Promise.resolve(resp(200, roster(['Nahla'], { changed: true }))); });
    await env.sandbox.loadReleaseLeads();
    var p = removeButtons(env)[1].onclick();
    await tick();
    assert.equal(env.el['release-gates-lead-modal'].style.display, 'flex');
    assert.equal(env.el['release-gates-lead-title'].textContent, 'REMOVE RELEASE LEAD');
    env.el['release-gates-lead-select'].value = 'Nahla';
    clickModal(env, 'confirm');
    await p;
    var body = JSON.parse(postsOf(env)[0].init.body);
    assert.deepEqual(body, { team: 'academy', op: 'remove', name: 'Reno', actor: 'Nahla' });
    assert.deepEqual(names(env), ['Nahla']);
});

test('cancelling the modal sends nothing and leaves the roster alone', async function () {
    var env = seeded(roster(['Nahla']), function () { throw new Error('must not POST'); });
    await env.sandbox.loadReleaseLeads();
    env.el['release-leads-input'].value = 'Thok';
    var p = env.sandbox.onReleaseLeadAdd();
    await tick();
    clickModal(env, 'cancel');
    await p;
    assert.equal(postsOf(env).length, 0);
    assert.deepEqual(names(env), ['Nahla']);
    assert.equal(env.el['release-leads-input'].value, 'Thok');
});

test('refused POST (403 and 409): roster unchanged, reason shown, still editable', async function () {
    var cases = [
        [403, { success: false, error: 'Mallory is not a release lead', code: 'NOT_IN_LEADS' }, /isn't a release lead/],
        [409, { success: false, error: 'refusing to remove Nahla: it is the last release lead', code: 'LAST_LEAD' }, /last release lead/],
    ];
    for (var i = 0; i < cases.length; i++) {
        var c = cases[i];
        var env = seeded(roster(['Nahla', 'Reno']), function () { return Promise.resolve(resp(c[0], c[1])); });
        await env.sandbox.loadReleaseLeads();
        var p = removeButtons(env)[0].onclick();
        await tick();
        clickModal(env, 'confirm');
        await p;
        assert.deepEqual(names(env), ['Nahla', 'Reno']);
        assert.equal(env.el['release-leads-error-row'].style.display, '');
        assert.match(env.el['release-leads-error-text'].textContent, c[2]);
        assert.equal(env.el['release-leads-add'].disabled, false);
        assert.equal(removeButtons(env)[0].disabled, false);
    }
});

test('names are rendered as text, never as HTML', async function () {
    var evil = '<img src=x onerror=alert(1)>&amp;';
    var env = seeded(roster([evil]));
    await env.sandbox.loadReleaseLeads();
    assert.deepEqual(names(env), [evil]);
    assert.equal(env.el['release-leads-list'].innerHTMLWrites, 0);
    assert.equal(env.el['release-leads-list'].children[0].innerHTMLWrites, 0);
    assert.equal(removeButtons(env)[0].attrs['aria-label'], 'Remove release lead ' + evil);
});

test('successful change re-calls loadReleaseGateEnforcement; changed:false does not', async function () {
    var env = seeded(roster([]), function () { return Promise.resolve(resp(200, roster(['Reno'], { changed: true }))); });
    await env.sandbox.loadReleaseLeads();
    env.el['release-leads-input'].value = 'Reno';
    await env.sandbox.onReleaseLeadAdd();
    await tick();
    assert.equal(env.apiFetchCalls.filter(function (c) { return isGateUrl(c.url); }).length, 1);

    var env2 = seeded(roster([]), function () { return Promise.resolve(resp(200, roster(['Reno'], { changed: false }))); });
    await env2.sandbox.loadReleaseLeads();
    env2.el['release-leads-input'].value = 'Reno';
    await env2.sandbox.onReleaseLeadAdd();
    await tick();
    assert.equal(env2.apiFetchCalls.filter(function (c) { return isGateUrl(c.url); }).length, 0);
});

test('client-side name validation sends nothing', async function () {
    var env = seeded(roster([]), function () { throw new Error('must not POST'); });
    await env.sandbox.loadReleaseLeads();
    var bad = ['', '   ', 'a'.repeat(65), 'tab\tname', 'nl\nname',
        'zw\u200bsp', 'rlo\u202ename', 'ls\u2028name', 'ps\u2029name', 'bom\ufeffname'];
    for (var i = 0; i < bad.length; i++) {
        env.el['release-leads-input'].value = bad[i];
        await env.sandbox.onReleaseLeadAdd();
    }
    assert.equal(postsOf(env).length, 0);
    assert.equal(env.el['release-leads-status'].className.indexOf('error') !== -1, true);
});

test('1482 enforcement copy now points at the roster editor / kb-release leads', function () {
    assert.doesNotMatch(SRC, /Ask an Academy admin/);
    assert.match(SRC, /kb-release leads <team> add <name>/);
});

test('mid-POST: ADD and every per-row REMOVE are disabled (children is an HTMLCollection, not an Array)', async function () {
    var release;
    var gate = new Promise(function (r) { release = r; });
    var env = seeded(roster(['Nahla', 'Reno']), function () {
        return gate.then(function () { return resp(200, roster(['Nahla'], { changed: true })); });
    });
    await env.sandbox.loadReleaseLeads();
    assert.equal(Array.isArray(env.el['release-leads-list'].children), false);
    env.el['release-leads-input'].value = 'Thok';
    var p = env.sandbox.onReleaseLeadAdd();
    await tick();
    clickModal(env, 'confirm'); // lead picked -> POST starts and parks on `gate`
    await tick();
    assert.equal(postsOf(env).length, 1);
    assert.equal(env.el['release-leads-add'].disabled, true);
    assert.equal(env.el['release-leads-input'].disabled, true);
    removeButtons(env).forEach(function (b) { assert.equal(b.disabled, true, 'REMOVE must be disabled mid-POST'); });
    release();
    await p;
});

test('mid-POST re-enable never unlocks the last lead REMOVE', async function () {
    var env = seeded(roster(['Nahla']));
    await env.sandbox.loadReleaseLeads();
    env.sandbox._setReleaseLeadsControlsDisabled(true);
    removeButtons(env).forEach(function (b) { assert.equal(b.disabled, true); });
    env.sandbox._setReleaseLeadsControlsDisabled(false);
    assert.equal(removeButtons(env)[0].disabled, true);
    assert.equal(env.el['release-leads-add'].disabled, false);
});

test('last lead: REMOVE is disabled with an explanatory title; two leads re-enable it', async function () {
    var env = seeded(roster(['Nahla']));
    await env.sandbox.loadReleaseLeads();
    var b = removeButtons(env)[0];
    assert.equal(b.disabled, true);
    assert.match(b.title, /last release lead cannot be removed/);
    assert.match(b.attrs['aria-description'], /add another lead first/);
    await env.sandbox.onReleaseLeadRemove('Nahla');   // defensive: sends nothing, no modal
    assert.equal(postsOf(env).length, 0);
    assert.equal(env.el['release-gates-lead-modal'].style.display, 'none');

    var env2 = seeded(roster(['Nahla', 'Reno']));
    await env2.sandbox.loadReleaseLeads();
    removeButtons(env2).forEach(function (x) { assert.equal(x.disabled, false); assert.equal(x.title, undefined); });
});

test('buttons use the settings-page lcars-button classes, not the modal-scoped modal-btn', async function () {
    var env = seeded(roster(['Nahla', 'Reno']));
    await env.sandbox.loadReleaseLeads();
    removeButtons(env).forEach(function (x) {
        assert.match(x.className, /\blcars-button\b/);
        assert.doesNotMatch(x.className, /modal-btn/);
    });
    var html = fs.readFileSync(path.join(__dirname, '../index.html'), 'utf8');
    assert.match(html, /class="lcars-button team-config-save-btn" id="release-leads-add"/);
});
