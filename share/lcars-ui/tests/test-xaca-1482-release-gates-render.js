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
 * marked block, stubs document/apiFetch/apiUrl/CONFIG/setTimeout, fails loudly if
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
    'release-gates-lead-modal', 'release-gates-lead-select', 'release-gates-lead-confirm',
    'release-gates-lead-cancel', 'release-gates-lead-close',
];

function makeElement(id) {
    var el = {
        id: id, checked: false, disabled: false, onchange: null, onclick: null, onkeydown: null,
        textContent: '', className: '', value: '', style: { display: '' }, children: [], focusCount: 0,
        appendChild: function (c) { el.children.push(c); return c; },
        focus: function () { el.focusCount++; },
    };
    // Real <select>: clearing textContent drops the options.
    var text = '';
    Object.defineProperty(el, 'textContent', {
        get: function () { return text; },
        set: function (v) { text = v; if (v === '') el.children = []; },
    });
    return el;
}

/** opts: fetchImpl (required), team, noModal (omit the modal markup) */
function makeEnv(opts) {
    var elements = {};
    ELEMENT_IDS.forEach(function (id) { elements[id] = makeElement(id); });
    elements['release-gates-lead-modal'].style.display = 'none';
    if (opts.noModal) {
        ['release-gates-lead-modal', 'release-gates-lead-select', 'release-gates-lead-confirm',
         'release-gates-lead-cancel', 'release-gates-lead-close'].forEach(function (id) { delete elements[id]; });
    }
    var apiFetchCalls = [];
    var timers = [];
    var refresh = { paused: 0, resumed: 0 };
    var sandbox = {
        console: { log: function () {}, warn: function () {}, error: function () {} },
        document: {
            getElementById: function (id) { return Object.prototype.hasOwnProperty.call(elements, id) ? elements[id] : null; },
            createElement: function () { return makeElement('opt'); },
        },
        CONFIG: { team: (opts.team !== undefined ? opts.team : 'academy') },
        apiUrl: function (p) { return p; },
        apiFetch: function (url, init) { apiFetchCalls.push({ url: url, init: init }); return opts.fetchImpl(url, init); },
        setTimeout: function (fn, ms) { timers.push({ fn: fn, ms: ms }); return timers.length; },
        pauseAutoRefresh: function () { refresh.paused++; },
        resumeAutoRefresh: function () { refresh.resumed++; },
        // window.prompt must never be reached any more; fail loudly if it is.
        prompt: function () { throw new Error('window.prompt must not be used (XACA-1482-011)'); },
        JSON: JSON,
    };
    vm.createContext(sandbox);
    vm.runInContext(blockSrc, sandbox, { filename: 'lcars-release-gates-extract.js' });
    return { sandbox: sandbox, el: elements, apiFetchCalls: apiFetchCalls, timers: timers, refresh: refresh };
}

function resp(status, body) {
    return { ok: status >= 200 && status < 300, status: status, json: function () { return Promise.resolve(body); } };
}
function getOnly(status, body) { return function () { return Promise.resolve(resp(status, body)); }; }
function ok(mode, explicit, warn, extra) {
    var b = { team: 'academy', mode: mode, explicit: explicit, configWarning: warn || null, writable: true, leads: ['Nahla', 'Reno'] };
    if (extra) Object.keys(extra).forEach(function (k) { b[k] = extra[k]; });
    return b;
}

function assertFailClosed(env) {
    assert.equal(env.el['release-gates-checkbox'].checked, true);
    assert.equal(env.el['release-gates-checkbox'].disabled, true);
    assert.equal(env.el['release-gates-checkbox'].onchange, null);
    assert.equal(env.el['release-gates-error-row'].style.display, '');
    assert.notEqual(env.el['release-gates-error-text'].textContent, '');
    assert.equal(env.el['release-gates-default'].style.display, 'none');
}

// GET returns ok(mode, explicit, null, getExtra); POST delegates to postImpl.
function seeded(mode, explicit, postImpl, getExtra, envOpts) {
    return makeEnv(Object.assign({
        fetchImpl: function (url, init) {
            if (init && init.method === 'POST') return postImpl(url, init);
            return Promise.resolve(resp(200, ok(mode, explicit, null, getExtra)));
        },
    }, envOpts || {}));
}
/** Click the modal button `which` ('confirm' | 'cancel' | 'close'), after the modal has opened. */
function click(env, which) { env.el['release-gates-lead-' + which].onclick(); }
/** Start an uncheck and let the modal open (the handler is parked awaiting the choice). */
async function uncheck(env) {
    env.el['release-gates-checkbox'].checked = false;
    var p = env.el['release-gates-checkbox'].onchange();
    await Promise.resolve();
    return { done: p };   // wrapped: returning the bare promise would await the parked modal
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
    assert.equal(env.el['release-gates-status'].textContent, 'Gates report-only');
    assert.equal(env.el['release-gates-error-row'].style.display, 'none');
    assert.equal(typeof env.el['release-gates-checkbox'].onchange, 'function');
});

test('enforce explicit -> checked, no default badge', async function () {
    var env = makeEnv({ fetchImpl: getOnly(200, ok('enforce', true)) });
    await env.sandbox.loadReleaseGateEnforcement();
    assert.equal(env.el['release-gates-checkbox'].checked, true);
    assert.equal(env.el['release-gates-checkbox'].disabled, false);
    assert.equal(env.el['release-gates-default'].style.display, 'none');
    assert.equal(env.el['release-gates-status'].textContent, 'Gates enforced');
});

test('key absent (explicit=false) -> checked + (default) badge', async function () {
    var env = makeEnv({ fetchImpl: getOnly(200, ok('enforce', false)) });
    await env.sandbox.loadReleaseGateEnforcement();
    assert.equal(env.el['release-gates-checkbox'].checked, true);
    assert.equal(env.el['release-gates-default'].style.display, 'inline-block');
    assert.equal(env.el['release-gates-status'].textContent, 'Gates enforced');
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

test('uncheck opens the lead modal listing exactly the server leads; no prompt, no fetch yet', async function () {
    var env = seeded('enforce', true, function () { throw new Error('should not POST yet'); });
    await env.sandbox.loadReleaseGateEnforcement();
    var before = env.apiFetchCalls.length;
    var p = (await uncheck(env)).done;
    assert.equal(env.el['release-gates-lead-modal'].style.display, 'flex');
    assert.deepEqual(env.el['release-gates-lead-select'].children.map(function (o) { return o.value; }), ['Nahla', 'Reno']);
    assert.deepEqual(env.el['release-gates-lead-select'].children.map(function (o) { return o.textContent; }), ['Nahla', 'Reno']);
    assert.equal(env.el['release-gates-lead-select'].focusCount, 1);   // focus moves in
    assert.equal(env.refresh.paused, 1);
    assert.equal(env.apiFetchCalls.length, before);
    click(env, 'cancel');
    await p;
});

test('empty leads -> no modal, no fetch, box re-checked, hint shown', async function () {
    var env = seeded('enforce', true, function () { throw new Error('no'); }, { leads: [] });
    await env.sandbox.loadReleaseGateEnforcement();
    var before = env.apiFetchCalls.length;
    await (await uncheck(env)).done;
    assert.equal(env.el['release-gates-lead-modal'].style.display, 'none');
    assert.equal(env.apiFetchCalls.length, before);
    assert.equal(env.el['release-gates-checkbox'].checked, true);
    assert.equal(env.el['release-gates-checkbox'].disabled, false);
    assert.equal(env.el['release-gates-status'].textContent,
        "No release leads are configured for this team \u2014 add one in the Release leads roster below (or: kb-release leads <team> add <name>) first.");
});

test('absent / malformed leads field (older server) behaves like empty leads', async function () {
    var bodies = [undefined, null, 'Nahla', {}, [7, null, '  ']];
    for (var i = 0; i < bodies.length; i++) {
        var env = seeded('enforce', true, function () { throw new Error('no'); }, { leads: bodies[i] });
        await env.sandbox.loadReleaseGateEnforcement();
        await (await uncheck(env)).done;
        assert.equal(env.el['release-gates-lead-modal'].style.display, 'none');
        assert.equal(postsOf(env).length, 0);
        assert.equal(env.el['release-gates-checkbox'].checked, true);
    }
});

test('modal confirm POSTs {team,mode:report,actor:<selected lead>}; renders from RESPONSE', async function () {
    var env = seeded('enforce', true, function () {
        return Promise.resolve(resp(200, { team: 'academy', mode: 'report', explicit: true, configWarning: null, changed: true, writable: true, leads: ['Nahla', 'Reno'] }));
    });
    await env.sandbox.loadReleaseGateEnforcement();
    var p = (await uncheck(env)).done;
    env.el['release-gates-lead-select'].value = 'Reno';
    click(env, 'confirm');
    await p;
    var posts = postsOf(env);
    assert.equal(posts.length, 1);
    assert.deepEqual(JSON.parse(posts[0].init.body), { team: 'academy', mode: 'report', actor: 'Reno' });
    assert.equal(env.el['release-gates-lead-modal'].style.display, 'none');
    assert.equal(env.refresh.resumed, 1);
    assert.equal(env.el['release-gates-checkbox'].checked, false);
    assert.equal(env.el['release-gates-checkbox'].disabled, false);
    assert.ok(env.el['release-gates-checkbox'].focusCount >= 1);       // focus back on the checkbox
});

test('modal confirm with the default selection posts the first lead', async function () {
    var env = seeded('enforce', true, function () { return Promise.resolve(resp(200, ok('report', true))); });
    await env.sandbox.loadReleaseGateEnforcement();
    var p = (await uncheck(env)).done;
    click(env, 'confirm');
    await p;
    assert.equal(JSON.parse(postsOf(env)[0].init.body).actor, 'Nahla');
});

['cancel', 'close', 'backdrop', 'escape'].forEach(function (how) {
    test('modal ' + how + ' -> no fetch, box re-checked, "Unchanged" note, focus returns', async function () {
        var env = seeded('enforce', true, function () { throw new Error('no POST'); });
        await env.sandbox.loadReleaseGateEnforcement();
        var before = env.apiFetchCalls.length;
        var p = (await uncheck(env)).done;
        var overlay = env.el['release-gates-lead-modal'];
        if (how === 'cancel' || how === 'close') click(env, how);
        else if (how === 'backdrop') overlay.onclick({ target: overlay });
        else overlay.onkeydown({ key: 'Escape' });
        await p;
        assert.equal(overlay.style.display, 'none');
        assert.equal(env.apiFetchCalls.length, before);
        assert.equal(env.el['release-gates-checkbox'].checked, true);
        assert.equal(env.el['release-gates-checkbox'].disabled, false);
        assert.equal(env.el['release-gates-status'].textContent, 'Unchanged \u2014 gates still enforced.');
        assert.ok(env.el['release-gates-checkbox'].focusCount >= 1);
        assert.equal(env.refresh.resumed, 1);
    });
});

test('click inside the dialog (not the backdrop) does not close it', async function () {
    var env = seeded('enforce', true, function () { throw new Error('no'); });
    await env.sandbox.loadReleaseGateEnforcement();
    var p = (await uncheck(env)).done;
    env.el['release-gates-lead-modal'].onclick({ target: env.el['release-gates-lead-select'] });
    assert.equal(env.el['release-gates-lead-modal'].style.display, 'flex');
    click(env, 'cancel');
    await p;
});

test('Tab / Shift+Tab are trapped inside the dialog', async function () {
    var env = seeded('enforce', true, function () { throw new Error('no'); });
    await env.sandbox.loadReleaseGateEnforcement();
    var p = (await uncheck(env)).done;
    var overlay = env.el['release-gates-lead-modal'];
    var prevented = 0;
    function tab(target, shift) { overlay.onkeydown({ key: 'Tab', shiftKey: !!shift, target: target, preventDefault: function () { prevented++; } }); }
    var confirm = env.el['release-gates-lead-confirm'];
    var close = env.el['release-gates-lead-close'];
    tab(confirm, false);                       // last -> first
    assert.equal(close.focusCount, 1);
    tab(close, true);                          // first -> last
    assert.equal(confirm.focusCount, 1);
    assert.equal(prevented, 2);
    click(env, 'cancel');
    await p;
});

test('missing modal markup fails closed: no POST, box re-checked', async function () {
    var env = seeded('enforce', true, function () { throw new Error('no'); }, null, { noModal: true });
    await env.sandbox.loadReleaseGateEnforcement();
    await (await uncheck(env)).done;
    assert.equal(postsOf(env).length, 0);
    assert.equal(env.el['release-gates-checkbox'].checked, true);
});

test('window.prompt is gone from the release-gates block', function () {
    assert.equal(/\bprompt\s*\(/.test(blockSrc.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '')), false);
});

test('writable:false -> checked + disabled, no handler, configWarning visible', async function () {
    var env = makeEnv({ fetchImpl: getOnly(200, ok('enforce', false, 'releaseConfig is str, not an object; the gate treats it as enforce', { writable: false, leads: [] })) });
    await env.sandbox.loadReleaseGateEnforcement();
    assert.equal(env.el['release-gates-checkbox'].checked, true);
    assert.equal(env.el['release-gates-checkbox'].disabled, true);
    assert.equal(env.el['release-gates-checkbox'].onchange, null);
    assert.equal(env.el['release-gates-error-row'].style.display, '');
    assert.match(env.el['release-gates-error-text'].textContent, /not an object/);
});

test('writable:false without a configWarning still shows a visible explanation', async function () {
    var env = makeEnv({ fetchImpl: getOnly(200, ok('enforce', false, null, { writable: false })) });
    await env.sandbox.loadReleaseGateEnforcement();
    assert.equal(env.el['release-gates-checkbox'].disabled, true);
    assert.equal(env.el['release-gates-error-row'].style.display, '');
    assert.notEqual(env.el['release-gates-error-text'].textContent, '');
});

test('only writable === false disables: true, absent (old server) and non-boolean keep the box enabled', async function () {
    var variants = [{ writable: true }, { writable: undefined }, { writable: 'false' }, { writable: 0 }, { writable: null }];
    for (var i = 0; i < variants.length; i++) {
        var body = ok('enforce', true, null, variants[i]);
        if (variants[i].writable === undefined) delete body.writable;
        var env = makeEnv({ fetchImpl: getOnly(200, body) });
        await env.sandbox.loadReleaseGateEnforcement();
        assert.equal(env.el['release-gates-checkbox'].disabled, false, JSON.stringify(variants[i]));
        assert.equal(typeof env.el['release-gates-checkbox'].onchange, 'function');
    }
});

test('status text never repeats (default)/(explicit); the badge carries default-ness', async function () {
    var combos = [['enforce', false], ['enforce', true], ['report', true], ['report', false]];
    for (var i = 0; i < combos.length; i++) {
        var env = makeEnv({ fetchImpl: getOnly(200, ok(combos[i][0], combos[i][1])) });
        await env.sandbox.loadReleaseGateEnforcement();
        assert.doesNotMatch(env.el['release-gates-status'].textContent, /default|explicit|\(/);
        assert.equal(env.el['release-gates-default'].style.display, combos[i][1] ? 'none' : 'inline-block');
    }
});

test('successful save flashes "Saved" (class saved) then restores the label after 2 s', async function () {
    var env = seeded('enforce', true, function () {
        return Promise.resolve(resp(200, ok('report', true, null, { changed: true })));
    });
    await env.sandbox.loadReleaseGateEnforcement();
    var p = (await uncheck(env)).done;
    click(env, 'confirm');
    await p;
    var st = env.el['release-gates-status'];
    assert.equal(st.textContent, 'Saved');
    assert.equal(st.className, 'team-config-status saved');
    assert.equal(env.timers.length, 1);
    assert.equal(env.timers[0].ms, 2000);
    env.timers[0].fn();
    assert.equal(st.textContent, 'Gates report-only');
    assert.equal(st.className, 'team-config-status');
});

test('the "Saved" timeout does not clobber a newer status', async function () {
    var env = seeded('report', true, function () { return Promise.resolve(resp(200, ok('enforce', true))); });
    await env.sandbox.loadReleaseGateEnforcement();
    env.el['release-gates-checkbox'].checked = true;
    await env.el['release-gates-checkbox'].onchange();
    env.el['release-gates-status'].textContent = 'Saving...';
    env.el['release-gates-status'].className = 'team-config-status saving';
    env.timers[0].fn();
    assert.equal(env.el['release-gates-status'].textContent, 'Saving...');
});

test('a failed save never flashes Saved', async function () {
    var env = seeded('report', true, function () { return Promise.resolve(resp(500, { error: 'boom' })); });
    await env.sandbox.loadReleaseGateEnforcement();
    env.el['release-gates-checkbox'].checked = true;
    await env.el['release-gates-checkbox'].onchange();
    assert.equal(env.timers.length, 0);
    assert.equal(env.el['release-gates-status'].textContent, 'Save failed');
});

test('403 code LEADS_NOT_CONFIGURED -> plain message, box reverted', async function () {
    var env = seeded('enforce', true, function () {
        return Promise.resolve(resp(403, { success: false, error: 'releaseConfig.leads is missing or empty; nobody can be authorized as lead (fails closed)', code: 'LEADS_NOT_CONFIGURED' }));
    });
    await env.sandbox.loadReleaseGateEnforcement();
    var p = (await uncheck(env)).done;
    click(env, 'confirm');
    await p;
    assert.equal(env.el['release-gates-checkbox'].checked, true);
    assert.equal(env.el['release-gates-checkbox'].disabled, false);
    assert.equal(env.el['release-gates-error-text'].textContent,
        "Save failed: No release leads are configured for this team, so gates can't be turned off. Add a lead in the Release leads roster below, or run: kb-release leads <team> add <name>");
    assert.equal(env.el['release-gates-status'].textContent, 'Save failed');
});

test('403 code NOT_IN_LEADS -> plain message', async function () {
    var env = seeded('enforce', true, function () {
        return Promise.resolve(resp(403, { success: false, error: "actor 'x' is not in releaseConfig.leads", code: 'NOT_IN_LEADS' }));
    });
    await env.sandbox.loadReleaseGateEnforcement();
    var p = (await uncheck(env)).done;
    click(env, 'confirm');
    await p;
    assert.equal(env.el['release-gates-error-text'].textContent, "Save failed: That name isn't a release lead for this team.");
});

test('unknown code and no code fall back to the server error text (textContent, verbatim)', async function () {
    var bodies = [{ error: '<b>raw</b> server text', code: 'SOMETHING_NEW' }, { error: '<b>raw</b> server text' },
                  { error: '<b>raw</b> server text', code: 'constructor' }, { error: '<b>raw</b> server text', code: 7 }];
    for (var i = 0; i < bodies.length; i++) {
        var env = seeded('enforce', true, function () { return Promise.resolve(resp(403, bodies[i])); });
        await env.sandbox.loadReleaseGateEnforcement();
        var p = (await uncheck(env)).done;
        click(env, 'confirm');
        await p;
        assert.equal(env.el['release-gates-error-text'].textContent, 'Save failed: <b>raw</b> server text');
        assert.equal(env.el['release-gates-error-text'].innerHTML, undefined);
    }
});

test('response disagrees with request -> UI trusts the response', async function () {
    var env = seeded('enforce', true, function () { return Promise.resolve(resp(200, ok('enforce', true))); });
    await env.sandbox.loadReleaseGateEnforcement();
    var p = (await uncheck(env)).done;
    click(env, 'confirm');
    await p;
    assert.equal(env.el['release-gates-checkbox'].checked, true);
});

test('403 -> box reverted to prior state and server reason shown', async function () {
    var env = seeded('enforce', true, function () {
        return Promise.resolve(resp(403, { error: 'nobody is not a release lead' }));
    });
    await env.sandbox.loadReleaseGateEnforcement();
    var p = (await uncheck(env)).done;
    click(env, 'confirm');
    await p;
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
    var env = seeded('enforce', true, function () { return Promise.resolve(resp(200, { mode: 'nope' })); });
    await env.sandbox.loadReleaseGateEnforcement();
    var p = (await uncheck(env)).done;
    click(env, 'confirm');
    await p;
    assert.equal(env.el['release-gates-checkbox'].checked, true);
    assert.match(env.el['release-gates-error-text'].textContent, /malformed/);
});

test('check -> POST enforce without actor, no modal', async function () {
    var env = seeded('report', true, function () {
        return Promise.resolve(resp(200, { team: 'academy', mode: 'enforce', explicit: true, configWarning: null, changed: true }));
    });
    await env.sandbox.loadReleaseGateEnforcement();
    env.el['release-gates-checkbox'].checked = true;
    await env.el['release-gates-checkbox'].onchange();
    var body = JSON.parse(postsOf(env)[0].init.body);
    assert.deepEqual(body, { team: 'academy', mode: 'enforce' });
    assert.equal('actor' in body, false);
    assert.equal(env.el['release-gates-lead-modal'].style.display, 'none');
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
