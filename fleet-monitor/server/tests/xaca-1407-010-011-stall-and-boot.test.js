//
//  xaca-1407-010-011-stall-and-boot.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1407-010 (FM-stall guard) and XACA-1407-011 (boot observation).
 * Pure tracker tests with a fake clock and a recording emitter, plus structural checks on server.js
 * (which binds a port and is never required).
 */

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createMachineNoticeTracker, STALL_THRESHOLD_MS } = require('../lib/fleet-notice-sources');

const SEC = 1000;
function setup(over = {}) {
    const clock = { t: Date.UTC(2026, 9, 13, 12, 0, 0) };
    const sent = [];
    const warns = [];
    const tr = createMachineNoticeTracker(Object.assign({
        emit: (n) => { sent.push(n); }, now: () => clock.t, offlineThresholdMs: 180 * SEC,
        logger: { warn: (m) => warns.push(m), log: (m) => warns.push(m) },
    }, over));
    // one status sweep over {id: status}
    const sweep = (statuses) => { tr.beginSweep(); for (const [id, st] of Object.entries(statuses)) tr.observe(id, st, { label: id }); };
    return { tr, clock, sent, warns, sweep };
}
const types = (sent) => sent.map((n) => `${n.type}:${n.ref}`);

describe('010: FM-stall guard', () => {
    test('default threshold is 90 s (3 ticks)', () => assert.equal(STALL_THRESHOLD_MS, 90 * SEC));

    test('a stall makes every machine look offline: NOTHING is announced, one log line, and no recovered wave', () => {
        const { clock, sent, warns, sweep } = setup();
        const all = { a: 'online', b: 'online', c: 'online' };
        sweep(all);
        clock.t += 10 * 60 * SEC;                       // host slept 10 minutes
        sweep({ a: 'offline', b: 'offline', c: 'offline' });
        assert.deepEqual(sent, []);
        assert.equal(warns.length, 1);
        assert.match(warns[0], /stalled/);
        clock.t += 30 * SEC;                            // heartbeats resume
        sweep({ a: 'online', b: 'online', c: 'online' });
        for (let i = 0; i < 10; i++) { clock.t += 30 * SEC; sweep(all); }
        assert.deepEqual(sent, [], 'no offline wave and no recovered wave');
        assert.equal(warns.length, 1, 'ordinary ticks log nothing');
    });

    test('a genuine outage is not lost: still offline after the grace -> exactly ONE machine-offline', () => {
        const { clock, sent, sweep } = setup();
        sweep({ a: 'online', b: 'online' });
        clock.t += 10 * 60 * SEC;
        sweep({ a: 'offline', b: 'offline' });          // held
        for (let s = 30; s < 180; s += 30) {            // inside the 180 s grace: b heartbeats, a stays down
            clock.t += 30 * SEC; sweep({ a: 'offline', b: 'online' });
        }
        assert.deepEqual(sent, []);
        clock.t += 30 * SEC;                            // grace elapsed (180 s after the stall sweep)
        sweep({ a: 'offline', b: 'online' });
        assert.deepEqual(types(sent), ['machine-offline:a']);
        for (let i = 0; i < 10; i++) { clock.t += 30 * SEC; sweep({ a: 'offline', b: 'online' }); }
        assert.deepEqual(types(sent), ['machine-offline:a'], 'exactly one');
        clock.t += 30 * SEC; sweep({ a: 'online', b: 'online' });
        assert.deepEqual(types(sent), ['machine-offline:a', 'machine-recovered:a'], 'announced offline recovers normally');
    });

    test('a held offline that recovers inside the grace yields no recovered (never announced)', () => {
        const { tr, clock, sent } = setup();
        tr.beginSweep(); tr.observe('a', 'online', {});
        clock.t += 5 * 60 * SEC;
        tr.beginSweep(); assert.equal(tr.observe('a', 'offline', {}), 'held-offline');
        clock.t += 30 * SEC;
        tr.beginSweep(); assert.equal(tr.observe('a', 'online', {}), 'recovered-quiet');
        assert.deepEqual(sent, []);
    });

    test('machines announced offline BEFORE the stall are unaffected: their recovery is still announced', () => {
        const { clock, sent, sweep } = setup();
        sweep({ a: 'online' });
        clock.t += 30 * SEC; sweep({ a: 'offline' });   // genuine, announced
        clock.t += 10 * 60 * SEC; sweep({ a: 'offline' }); // stall sweep
        clock.t += 30 * SEC; sweep({ a: 'online' });
        assert.deepEqual(types(sent), ['machine-offline:a', 'machine-recovered:a']);
    });

    test('a gap at or below the threshold is NOT a stall (normal offline still announces immediately)', () => {
        const { tr, clock, sent, warns } = setup();
        tr.beginSweep(); tr.observe('a', 'online', {});
        clock.t += 90 * SEC;
        assert.equal(tr.beginSweep(), false);
        tr.observe('a', 'offline', {});
        assert.equal(sent.length, 1);
        assert.equal(warns.length, 0);
    });

    test('stallThresholdMs and stallGraceMs are injectable; grace defaults to the offline threshold', () => {
        const { tr, clock, sent } = setup({ stallThresholdMs: 10 * SEC, stallGraceMs: 60 * SEC });
        tr.beginSweep(); tr.observe('a', 'online', {});
        clock.t += 11 * SEC;
        assert.equal(tr.beginSweep(), true);
        tr.observe('a', 'offline', {});
        for (let i = 0; i < 11; i++) { clock.t += 5 * SEC; tr.beginSweep(); assert.equal(tr.observe('a', 'offline', {}), null); } // 55 s: still held
        clock.t += 5 * SEC; tr.beginSweep(); assert.equal(tr.observe('a', 'offline', {}), 'escalated-offline'); // 60 s
        assert.equal(sent.length, 1);
    });

    test('a second stall during the first grace re-opens the grace', () => {
        const { clock, sent, sweep } = setup();
        sweep({ a: 'online' });
        clock.t += 5 * 60 * SEC; sweep({ a: 'offline' });
        clock.t += 100 * SEC; sweep({ a: 'offline' });   // 100 s gap: same stall window, still held
        clock.t += 5 * 60 * SEC; sweep({ a: 'offline' }); // stalled again
        assert.deepEqual(sent, []);
    });
});

describe('011: boot observation', () => {
    test('first sweep is never a stall, whatever the clock says', () => {
        const { tr, warns } = setup();
        assert.equal(tr.beginSweep(), false);
        assert.equal(warns.length, 0);
    });

    test('boot sweep baselines a stale machine OFFLINE, so its first heartbeat produces machine-recovered', () => {
        const { clock, sent, sweep } = setup();
        sweep({ a: 'offline', b: 'online' });            // boot sweep over machines loaded from disk
        assert.deepEqual(sent, [], 'boot sweep emits nothing');
        assert.equal(clock.t > 0, true);
    });

    test('boot sweep + heartbeat: recovered is sent; WITHOUT the boot sweep the heartbeat is swallowed (the 011 gap)', () => {
        const withBoot = setup();
        withBoot.sweep({ a: 'offline' });
        withBoot.clock.t += 5 * SEC;
        withBoot.tr.observe('a', 'online', { label: 'a' });   // /api/status heartbeat
        assert.deepEqual(types(withBoot.sent), ['machine-recovered:a']);

        const noBoot = setup();
        noBoot.tr.observe('a', 'online', { label: 'a' });     // heartbeat before any sweep
        assert.deepEqual(noBoot.sent, [], 'baselined online: recovery lost');
    });

    test('the boot sweep does not open a stall grace for the following tick', () => {
        const { clock, sent, sweep } = setup();
        sweep({ a: 'online' });                           // boot
        clock.t += 30 * SEC;
        sweep({ a: 'offline' });                          // genuine, announced at once
        assert.deepEqual(types(sent), ['machine-offline:a']);
    });
});

describe('server.js wiring (structural)', () => {
    const src = fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8');

    test('every status sweep begins with beginSweep()', () => {
        const fn = src.slice(src.indexOf('function updateMachineStatuses()'));
        assert.match(fn.slice(0, 400), /machineNotices\.beginSweep\(\);\s*const now = Date\.now\(\);/);
    });

    test('a boot-time updateMachineStatuses() runs after machines load and BEFORE app.listen()', () => {
        const load = src.indexOf('\nloadMachineData();');
        const boot = src.indexOf('XACA-1407-011');
        const listen = src.indexOf('app.listen(PORT');
        assert.ok(load > 0 && boot > load && listen > boot, `${load} ${boot} ${listen}`);
        const between = src.slice(boot, listen);
        assert.match(between, /\nupdateMachineStatuses\(\);\n/);
    });
});
