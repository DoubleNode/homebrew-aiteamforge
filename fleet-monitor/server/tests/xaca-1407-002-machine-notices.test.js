//
//  xaca-1407-002-machine-notices.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/** XACA-1407-002 -- machine-offline / machine-recovered tracker. Pure: fake clock, recording emitter. */

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createMachineNoticeTracker, FLAP_WINDOW_MS } = require('../lib/fleet-notice-sources');

const MIN = 60 * 1000;
function setup(over = {}) {
    const clock = { t: Date.UTC(2026, 9, 13, 12, 0, 0) };
    const sent = [];
    const tr = createMachineNoticeTracker(Object.assign({
        emit: (n) => { sent.push(n); }, now: () => clock.t, offlineThresholdMs: 180000,
    }, over));
    return { tr, clock, sent };
}
const info = { label: 'm4mini', lastSeen: '2026-10-13T11:56:00.000Z' };

describe('transitions', () => {
    test('default flap window is 5 minutes and injectable', () => {
        assert.equal(FLAP_WINDOW_MS, 5 * MIN);
        assert.equal(setup().tr.flapWindowMs, 5 * MIN);
        assert.equal(setup({ flapWindowMs: 1000 }).tr.flapWindowMs, 1000);
    });

    test('online -> offline emits exactly ONE critical machine-offline, not one per tick', () => {
        const { tr, clock, sent } = setup();
        assert.equal(tr.observe('m1', 'online', info), 'baseline');
        assert.equal(tr.observe('m1', 'offline', info), 'offline');
        for (let i = 0; i < 20; i++) { clock.t += 30000; assert.equal(tr.observe('m1', 'offline', info), null); }
        assert.equal(sent.length, 1);
        assert.equal(sent[0].type, 'machine-offline');
        assert.equal(sent[0].severity, 'critical');
        assert.equal(sent[0].ref, 'm1');
        assert.match(sent[0].title, /m4mini/);
        assert.match(sent[0].body, /offline threshold 180s/);
    });

    test('warning -> offline also emits; online <-> warning never does', () => {
        const { tr, sent } = setup();
        tr.observe('m1', 'online', info);
        assert.equal(tr.observe('m1', 'warning', info), null);
        assert.equal(tr.observe('m1', 'online', info), null);
        assert.equal(tr.observe('m1', 'warning', info), null);
        assert.equal(sent.length, 0);
        assert.equal(tr.observe('m1', 'offline', info), 'offline');
        assert.equal(sent.length, 1);
    });

    test('offline -> online emits ONE info machine-recovered with the downtime; later ticks are silent', () => {
        const { tr, clock, sent } = setup();
        tr.observe('m1', 'online', info);
        tr.observe('m1', 'offline', info);
        clock.t += 17 * MIN;
        assert.equal(tr.observe('m1', 'online', info), 'recovered');
        for (let i = 0; i < 5; i++) { clock.t += 30000; tr.observe('m1', 'online', info); }
        assert.equal(sent.length, 2);
        assert.equal(sent[1].type, 'machine-recovered');
        assert.equal(sent[1].severity, 'info');
        assert.match(sent[1].body, /after 17m offline/);
    });

    test('offline -> warning counts as recovered (it is reporting again)', () => {
        const { tr, sent } = setup();
        tr.observe('m1', 'online', info);
        tr.observe('m1', 'offline', info);
        assert.equal(tr.observe('m1', 'warning', info), 'recovered');
        assert.equal(sent[1].type, 'machine-recovered');
    });

    test('machines are independent', () => {
        const { tr, sent } = setup();
        tr.observe('a', 'online'); tr.observe('b', 'online');
        tr.observe('a', 'offline', { label: 'a' });
        assert.equal(sent.length, 1);
        tr.observe('b', 'offline', { label: 'b' });
        assert.equal(sent.length, 2);
        assert.deepEqual(sent.map((n) => n.ref), ['a', 'b']);
    });
});

describe('startup behaviour', () => {
    test('a machine first observed already offline (stale at boot) emits nothing -- no restart burst', () => {
        const { tr, clock, sent } = setup();
        for (const id of ['a', 'b', 'c']) assert.equal(tr.observe(id, 'offline', info), 'baseline');
        for (let i = 0; i < 10; i++) { clock.t += 30000; for (const id of ['a', 'b', 'c']) tr.observe(id, 'offline', info); }
        assert.equal(sent.length, 0);
    });

    test('...but its eventual recovery IS announced (its offline predates this process)', () => {
        const { tr, sent } = setup();
        tr.observe('a', 'offline', info);
        assert.equal(tr.observe('a', 'online', info), 'recovered');
        assert.equal(sent.length, 1);
        assert.equal(sent[0].type, 'machine-recovered');
    });

    test('a machine first observed online is a baseline; a brand-new machine does not notify', () => {
        const { tr, sent } = setup();
        assert.equal(tr.observe('new', 'online', info), 'baseline');
        assert.equal(sent.length, 0);
    });
});

describe('flap damping', () => {
    test('offline -> recovered -> offline inside the window: second offline suppressed, and so is its recovery', () => {
        const { tr, clock, sent } = setup();
        tr.observe('m1', 'online', info);
        tr.observe('m1', 'offline', info);                       // 1: offline
        clock.t += 4 * MIN; tr.observe('m1', 'online', info);    // 2: recovered
        clock.t += 1 * MIN;
        assert.equal(tr.observe('m1', 'offline', info), 'suppressed-offline');
        clock.t += 1 * MIN;
        assert.equal(tr.observe('m1', 'online', info), 'recovered-quiet');
        assert.deepEqual(sent.map((n) => n.type), ['machine-offline', 'machine-recovered']);
    });

    test('a suppressed offline is NOT lost: still down one window later it is emitted exactly once', () => {
        const { tr, clock, sent } = setup();
        tr.observe('m1', 'online', info);
        tr.observe('m1', 'offline', info);
        clock.t += MIN; tr.observe('m1', 'online', info);
        clock.t += MIN; assert.equal(tr.observe('m1', 'offline', info), 'suppressed-offline');
        clock.t += FLAP_WINDOW_MS - 30000; assert.equal(tr.observe('m1', 'offline', info), null);
        assert.equal(sent.length, 2);
        clock.t += 30000;
        assert.equal(tr.observe('m1', 'offline', info), 'escalated-offline');
        clock.t += MIN; assert.equal(tr.observe('m1', 'offline', info), null);
        assert.deepEqual(sent.map((n) => n.type), ['machine-offline', 'machine-recovered', 'machine-offline']);
        // and its recovery is announced, because the operator now holds an offline
        assert.equal(tr.observe('m1', 'online', info), 'recovered');
        assert.equal(sent.length, 4);
    });

    test('an offline AFTER the window has passed since recovery is announced normally', () => {
        const { tr, clock, sent } = setup();
        tr.observe('m1', 'online', info);
        tr.observe('m1', 'offline', info);
        clock.t += MIN; tr.observe('m1', 'online', info);
        clock.t += FLAP_WINDOW_MS;
        assert.equal(tr.observe('m1', 'offline', info), 'offline');
        assert.equal(sent.length, 3);
    });

    test('a machine that keeps bouncing yields one pair then silence (sliding window)', () => {
        const { tr, clock, sent } = setup();
        tr.observe('m1', 'online', info);
        tr.observe('m1', 'offline', info);
        for (let i = 0; i < 6; i++) {
            clock.t += 2 * MIN; tr.observe('m1', 'online', info);
            clock.t += 2 * MIN; tr.observe('m1', 'offline', info);
        }
        assert.equal(sent.length, 2, sent.map((n) => n.type).join(','));
    });

    test('flapWindowMs 0 disables damping', () => {
        const { tr, sent } = setup({ flapWindowMs: 0 });
        tr.observe('m1', 'online'); tr.observe('m1', 'offline'); tr.observe('m1', 'online'); tr.observe('m1', 'offline');
        assert.deepEqual(sent.map((n) => n.type), ['machine-offline', 'machine-recovered', 'machine-offline']);
    });
});

describe('robustness', () => {
    test('bad ids / statuses are ignored; a throwing or rejecting emitter never propagates', async () => {
        const { tr } = setup();
        assert.equal(tr.observe('', 'online'), null);
        assert.equal(tr.observe(undefined, 'online'), null);
        assert.equal(tr.observe('m1', 'weird'), null);
        const warns = [];
        const boom = createMachineNoticeTracker({ emit: () => { throw new Error('boom'); }, logger: { warn: (m) => warns.push(m) } });
        boom.observe('m1', 'online'); boom.observe('m1', 'offline');
        assert.equal(warns.length, 1);
        assert.ok(!/boom/.test(warns[0]) || /Error/.test(warns[0]));
        const rej = createMachineNoticeTracker({ emit: () => Promise.reject(new Error('nope')) });
        rej.observe('m1', 'online'); rej.observe('m1', 'offline');
        await new Promise((r) => setImmediate(r)); // an unhandled rejection would fail the run
    });

    test('control characters in labels are stripped from title/body', () => {
        const { tr, sent } = setup();
        tr.observe('m1', 'online');
        tr.observe('m1', 'offline', { label: 'bad\nname\u0000x', lastSeen: 'now\r\n' });
        assert.ok(!/[\u0000-\u001f]/.test(sent[0].title + sent[0].body));
    });

    test('forget() drops state so a re-added machine baselines again', () => {
        const { tr, sent } = setup();
        tr.observe('m1', 'online');
        tr.forget('m1');
        assert.equal(tr.observe('m1', 'offline'), 'baseline');
        assert.equal(sent.length, 0);
    });
});

describe('server.js wiring (structural; server.js binds a port so it is never required)', () => {
    const src = fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8');
    const fn = src.slice(src.indexOf('function updateMachineStatuses()'), src.indexOf('function cleanupLegacyMachines()'));

    test('the tick observes every machine each pass (outside the changed-status branch)', () => {
        assert.match(fn, /machineNotices\.observe\(hostname, data\.status,/);
        const obsIdx = fn.indexOf('machineNotices.observe');
        const branchEnd = fn.indexOf('Log status change to history');
        assert.ok(obsIdx > branchEnd, 'observe must come after, not inside, the previousStatus !== status block');
    });

    test('/api/status observes the heartbeat as online right after machines.set (the recovery edge)', () => {
        assert.match(src, /machineNotices\.observe\(machineKey, 'online',/);
        assert.ok(src.indexOf("machineNotices.observe(machineKey, 'online'") > src.indexOf('system: normalizeSystemBlock(system)'));
    });

    test('legacy cleanup forgets removed machines', () => {
        assert.match(src, /machines\.delete\(key\);\s*machineNotices\.forget\(key\);/);
    });
});
