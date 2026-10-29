//
//  test_xaca1667_close_override_ui.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 DoubleNode.com. All rights reserved.
//

/**
 * XACA-1667-004: the EDIT STATE dialog shows the server's close-guard refusal verbatim and offers the audited override.
 *
 * The shipped _doSubmitTransition is extracted from lcars-ui/js/lcars-cr-tab.js by text markers (never re-implemented)
 * and run in a vm context against a minimal fake DOM and a scripted apiFetch. What is pinned:
 *   - a 409 that carries closeBlocked shows UI wording built from the structured releaseId (-014; never the CLI text,
 *     never the "modified by another session" text), an override reason box and a CLOSE ANYWAY button in the danger
 *     variant (-015), and no RELOAD button (nothing is stale); without a releaseId the server message is kept;
 *   - an ordinary 409 is unchanged (stale text, RELOAD, no override controls);
 *   - CLOSE ANYWAY with an empty reason sends nothing, marks the box invalid and shows the "Reason required" text the
 *     box is linked to by aria-describedby (-016); Enter in the box triggers CLOSE ANYWAY; #cr-sc-error is role=alert;
 *   - CLOSE ANYWAY with a reason resubmits the SAME payload plus {override: true, reason}.
 *
 * Usage: node --test lcars-ui/tests/test_xaca1667_close_override_ui.js
 */

'use strict';

var test   = require('node:test');
var assert = require('node:assert/strict');
var fs     = require('node:fs');
var path   = require('node:path');
var vm     = require('node:vm');

var SRC = fs.readFileSync(path.join(__dirname, '..', 'js', 'lcars-cr-tab.js'), 'utf8');

function slice(startMarker, endMarker) {
    var start = SRC.indexOf(startMarker);
    assert.ok(start !== -1, 'start marker not found: ' + startMarker);
    var end = SRC.indexOf(endMarker, start + startMarker.length);
    assert.ok(end !== -1, 'end marker not found: ' + endMarker);
    return SRC.slice(start, end);
}

var STALE = 'This CR was modified by another session. Reload to see the latest state.';
var BLOCKED = 'CR CR-1 is linked to release REL-1, whose close-out has not closed its CRs yet. run `kb-release close-out REL-1` instead.';

function fakeEl() {
    return { value: '', style: {}, attrs: {}, listeners: {}, focused: false,
             setAttribute: function (k, v) { this.attrs[k] = v; },
             focus: function () { this.focused = true; },
             addEventListener: function (ev, fn) { this.listeners[ev] = fn; } };
}

// An errorDiv whose innerHTML is parsed just enough to hand back the controls that the markup declares.
function fakeErrorDiv() {
    var controls = {};
    var div = { style: {}, _html: '',
        get innerHTML() { return this._html; },
        set innerHTML(h) {
            this._html = h; controls = {};
            ['cr-sc-override-reason', 'cr-sc-override-btn', 'cr-sc-override-hint', 'cr-sc-reload-btn', 'cr-sc-retry-btn'].forEach(function (id) {
                if (h.indexOf('id="' + id + '"') !== -1) controls['#' + id] = fakeEl();
            });
        },
        querySelector: function (sel) { return controls[sel] || null; } };
    return div;
}

function harness(response) {
    var fetched = [];
    var submitBtn = { disabled: false, textContent: '', dataset: {} };
    var sandbox = {
        escapeHtml: function (s) { return String(s); },
        apiUrl: function (u) { return u; },
        document: { getElementById: function () { return null; } },
        apiFetch: function (url, opts) {
            fetched.push(JSON.parse(opts.body));
            var r = response(fetched.length);
            return Promise.resolve({ status: r.status, ok: r.status === 200, json: function () { return Promise.resolve(r.body); } });
        },
        loadBoardData: undefined, renderChangeReqList: function () {}, _hideCRStateChangeDialog: function () {},
        _hideCRDocModal: function () {}, setTimeout: setTimeout, Object: Object, JSON: JSON, encodeURIComponent: encodeURIComponent,
    };
    vm.createContext(sandbox);
    var src = slice('// ── _crTransition409Message:start ──', '// ── _crTransition409Message:end ──') + '\n' +
              slice('function _doSubmitTransition(', 'function _hideCRStateChangeDialog()');
    vm.runInContext(src + '\nthis._doSubmitTransition = _doSubmitTransition;', sandbox);
    var errorDiv = fakeErrorDiv();
    return { sandbox: sandbox, fetched: fetched, errorDiv: errorDiv, submitBtn: submitBtn,
             submit: function (payload) { sandbox._doSubmitTransition('CR-1', payload, submitBtn, errorDiv, {}); } };
}

function tick() { return new Promise(function (r) { setTimeout(r, 5); }); }

test('XACA-1667-004: a close-guard 409 shows the server message, an override reason box and CLOSE ANYWAY (no RELOAD)', async () => {
    var h = harness(function () { return { status: 409, body: { ok: false, conflict: true, closeBlocked: true, releaseId: 'REL-1', error: BLOCKED } }; });
    h.submit({ targetState: 'cr-closed' });
    await tick();
    var html = h.errorDiv.innerHTML;
    assert.ok(html.indexOf('Linked to REL-1, whose close-out has not run.') !== -1, 'UI wording not built from releaseId: ' + html);
    assert.ok(html.indexOf('CLOSE ANYWAY') !== -1 && html.indexOf('recorded in the CR activity log') !== -1, html);
    assert.ok(html.indexOf('kb-release') === -1 && html.indexOf('`') === -1, 'CLI text leaked into the dialog: ' + html);
    assert.ok(html.indexOf('modified by another session') === -1, 'stale-session text shown for a close-guard refusal');
    assert.ok(html.indexOf('id="cr-sc-override-reason"') !== -1 && html.indexOf('id="cr-sc-override-btn"') !== -1);
    assert.ok(html.indexOf('aria-label="Reason for closing this CR outside close-out"') !== -1, 'reason box has no accessible name');
    assert.ok(html.indexOf('cr-sc-reload-btn') === -1, 'RELOAD offered although nothing is stale');
    assert.equal(h.errorDiv.style.display, 'block');
});

test('XACA-1667-014: a close-guard 409 without a releaseId keeps the server message (it may be the only explanation)', async () => {
    var msg = 'cannot evaluate which release waits on CR CR-1 (OSError: x); refusing';
    var h = harness(function () { return { status: 409, body: { ok: false, closeBlocked: true, releaseId: '', error: msg } }; });
    h.submit({ targetState: 'cr-closed' });
    await tick();
    assert.ok(h.errorDiv.innerHTML.indexOf(msg) !== -1, h.errorDiv.innerHTML);
    assert.ok(h.errorDiv.innerHTML.indexOf('id="cr-sc-override-btn"') !== -1);
});

test('XACA-1667-015: CLOSE ANYWAY carries the existing LCARS danger class, not the RELOAD peach one', async () => {
    var h = harness(function () { return { status: 409, body: { ok: false, closeBlocked: true, releaseId: 'REL-1', error: BLOCKED } }; });
    h.submit({ targetState: 'cr-closed' });
    await tick();
    var m = /<button class="([^"]*)" id="cr-sc-override-btn"/.exec(h.errorDiv.innerHTML);
    assert.ok(m, 'no CLOSE ANYWAY button');
    assert.ok(m[1].split(' ').indexOf('lcars-btn-danger') !== -1, 'not the danger variant: ' + m[1]);
    assert.ok(m[1].split(' ').indexOf('cr-sc-reload') === -1, 'still the RELOAD style: ' + m[1]);
    var css = fs.readFileSync(path.join(__dirname, '..', 'css', 'lcars.css'), 'utf8');
    assert.ok(/\.lcars-btn-danger\s*\{/.test(css), 'lcars-btn-danger no longer exists in lcars.css');
});

test('XACA-1667-016: the shipped error box is role=alert', () => {
    assert.ok(/<div id="cr-sc-error" class="cr-sc-error" role="alert"/.test(SRC), 'cr-sc-error is not role=alert');
});

test('XACA-1667-004: an ordinary 409 is unchanged (stale text, RELOAD, no override controls)', async () => {
    var h = harness(function () { return { status: 409, body: { ok: false, conflict: true, error: 'CR was modified by another writer', currentUpdatedAt: 'x' } }; });
    h.submit({ targetState: 'cr-approved' });
    await tick();
    var html = h.errorDiv.innerHTML;
    assert.ok(html.indexOf(STALE) !== -1);
    assert.ok(html.indexOf('cr-sc-reload-btn') !== -1);
    assert.ok(html.indexOf('cr-sc-override') === -1, 'override offered for a non-close-guard 409');
});

test('XACA-1667-004: CLOSE ANYWAY with an empty reason sends nothing and marks the box invalid', async () => {
    var h = harness(function () { return { status: 409, body: { ok: false, closeBlocked: true, error: BLOCKED } }; });
    h.submit({ targetState: 'cr-closed' });
    await tick();
    var btn = h.errorDiv.querySelector('#cr-sc-override-btn');
    var box = h.errorDiv.querySelector('#cr-sc-override-reason');
    box.value = '   ';
    btn.listeners.click();
    await tick();
    assert.equal(h.fetched.length, 1, 'an override without a reason was submitted');
    assert.equal(box.attrs['aria-invalid'], 'true');
    assert.equal(box.focused, true);
    assert.ok(h.errorDiv.innerHTML.indexOf('aria-describedby="cr-sc-override-hint"') !== -1, 'box not linked to the hint');
    assert.ok(/id="cr-sc-override-hint"[^>]*display:none[^>]*>Reason required</.test(h.errorDiv.innerHTML), 'hint text missing or visible up front');
    assert.equal(h.errorDiv.querySelector('#cr-sc-override-hint').style.display, 'inline', 'hint not shown on the empty submit');
});

test('XACA-1667-016: Enter in the reason box triggers CLOSE ANYWAY (empty: hint, no request; filled: resubmit)', async () => {
    var h = harness(function (n) {
        return n === 1 ? { status: 409, body: { ok: false, closeBlocked: true, releaseId: 'REL-1', error: BLOCKED } } : { status: 200, body: { ok: true, cr: { id: 'CR-1' } } };
    });
    h.submit({ targetState: 'cr-closed' });
    await tick();
    var box = h.errorDiv.querySelector('#cr-sc-override-reason');
    assert.equal(typeof box.listeners.keydown, 'function', 'no keydown handler on the reason box');
    var prevented = 0;
    box.listeners.keydown({ key: 'a', preventDefault: function () { prevented++; } });
    assert.equal(h.fetched.length, 1, 'a non-Enter key submitted');
    box.value = ' ';
    box.listeners.keydown({ key: 'Enter', preventDefault: function () { prevented++; } });
    assert.equal(h.fetched.length, 1, 'Enter with an empty reason submitted');
    assert.equal(h.errorDiv.querySelector('#cr-sc-override-hint').style.display, 'inline');
    box.value = 'because';
    box.listeners.keydown({ key: 'Enter', preventDefault: function () { prevented++; } });
    await tick();
    assert.equal(prevented, 2, 'Enter default not prevented');
    assert.equal(h.fetched.length, 2);
    assert.equal(h.fetched[1].override, true);
    assert.equal(h.fetched[1].reason, 'because');
});

test('XACA-1667-004: CLOSE ANYWAY with a reason resubmits the same payload plus {override, reason}', async () => {
    var h = harness(function (n) {
        return n === 1 ? { status: 409, body: { ok: false, closeBlocked: true, error: BLOCKED } } : { status: 200, body: { ok: true, cr: { id: 'CR-1' } } };
    });
    h.submit({ targetState: 'cr-closed', expectedUpdatedAt: 'u1', actor: 'lcars-ui' });
    await tick();
    h.errorDiv.querySelector('#cr-sc-override-reason').value = '  closed by hand  ';
    h.errorDiv.querySelector('#cr-sc-override-btn').listeners.click();
    await tick();
    assert.equal(h.fetched.length, 2);
    assert.deepEqual(h.fetched[1], { targetState: 'cr-closed', expectedUpdatedAt: 'u1', actor: 'lcars-ui', override: true, reason: 'closed by hand' });
    assert.equal(h.fetched[0].override, undefined, 'the first attempt must not carry an override');
});
