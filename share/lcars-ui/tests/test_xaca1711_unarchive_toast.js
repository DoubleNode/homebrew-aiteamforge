//
//  test_xaca1711_unarchive_toast.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 DoubleNode.com. All rights reserved.
//

/**
 * XACA-1711-012: a successful UNARCHIVE surfaces the server's restoredAssignments / skippedAssignments
 * (toast + announceToScreenReader) instead of discarding them.
 *
 * The shipped summarizeUnarchiveAssignments + toggleReleaseArchive are extracted from lcars-ui/js/lcars.js by text
 * markers (never re-implemented) and run in a vm context against a scripted apiFetch and recording stubs.
 *
 * Usage: node --test lcars-ui/tests/test_xaca1711_unarchive_toast.js
 */

'use strict';

var test   = require('node:test');
var assert = require('node:assert/strict');
var fs     = require('node:fs');
var path   = require('node:path');
var vm     = require('node:vm');

var SRC = fs.readFileSync(path.join(__dirname, '..', 'js', 'lcars.js'), 'utf8');
var START = SRC.indexOf('function summarizeUnarchiveAssignments(');
var END = SRC.indexOf('// RELEASE ASSIGNMENT MODAL');
assert.ok(START !== -1 && END > START, 'markers not found');
var CODE = SRC.slice(START, END);

function run(body, status) {
    var toasts = [], announced = [], loads = 0;
    var sandbox = {
        CONFIG: { team: 'academy' },
        apiUrl: function (u) { return u; },
        apiFetch: function () {
            return Promise.resolve({ ok: (status || 200) === 200, status: status || 200,
                                     json: function () { return Promise.resolve(body); } });
        },
        loadReleases: function () { loads++; },
        showToast: function (m, t, d) { toasts.push({ message: m, type: t, duration: d }); },
        announceToScreenReader: function (m) { announced.push(m); },
        alert: function () {}, console: { log: function () {}, error: function () {} },
        encodeURIComponent: encodeURIComponent, Array: Array
    };
    vm.createContext(sandbox);
    vm.runInContext(CODE + '\nthis.toggleReleaseArchive = toggleReleaseArchive;', sandbox);
    return sandbox.toggleReleaseArchive('REL-1').then(function () {
        return { toasts: toasts, announced: announced, loads: loads };
    });
}

test('restored only: success toast with the count, announced too', async function () {
    var r = await run({ success: true, archived: false, restoredAssignments: ['A-1', 'A-2'], skippedAssignments: [] });
    assert.equal(r.toasts.length, 1);
    assert.equal(r.toasts[0].message, 'Restored 2 assignment(s).');
    assert.equal(r.toasts[0].type, 'success');
    assert.equal(r.announced.length, 1);
    assert.ok(r.announced[0].startsWith('Release unarchived'));
    assert.ok(r.announced[0].includes('Restored 2 assignment(s).'));
    assert.equal(r.loads, 1);
});

test('restored + skipped: warning toast names the skipped ids and reasons; announced with the same text', async function () {
    var r = await run({ success: true, archived: false, restoredAssignments: ['A-1'],
        skippedAssignments: [{ itemId: 'A-2', reason: 'reassigned', currentReleaseId: 'REL-9' },
                             { itemId: null, reason: 'malformed-trail-entry' }] });
    assert.equal(r.toasts.length, 1);
    assert.equal(r.toasts[0].type, 'warning');
    assert.equal(r.toasts[0].message,
        'Restored 1 assignment(s). 2 skipped: A-2 (reassigned), unknown item (malformed-trail-entry).');
    assert.ok(r.announced[0].includes(r.toasts[0].message));
});

test('skipped list is capped at 5 with "and K more"', async function () {
    var skipped = [];
    for (var i = 1; i <= 8; i++) skipped.push({ itemId: 'S-' + i, reason: 'reassigned' });
    var r = await run({ success: true, archived: false, restoredAssignments: [], skippedAssignments: skipped });
    var m = r.toasts[0].message;
    assert.ok(m.includes('S-5 (reassigned)') && !m.includes('S-6'), m);
    assert.ok(m.includes('8 skipped') && m.includes('and 3 more'), m);
});

test('legacy unarchive response (no fields): no crash, no toast, plain announcement', async function () {
    var r = await run({ success: true, archived: false, message: 'Release unarchived successfully' });
    assert.equal(r.toasts.length, 0);
    assert.equal(r.announced[0], 'Release unarchived and returned to the active list.');
});

test('archive path is unchanged even if the fields were somehow present', async function () {
    var r = await run({ success: true, archived: true, restoredAssignments: ['A-1'] });
    assert.equal(r.toasts.length, 0);
    assert.equal(r.announced[0], 'Release archived.');
});
