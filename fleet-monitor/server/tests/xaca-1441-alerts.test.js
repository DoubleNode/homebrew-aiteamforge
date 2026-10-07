//
//  xaca-1441-alerts.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/** XACA-1441-007 -- lib/ci-dispatch-alerts.js (plan D9). Offline; fake clock/logger/emitter. */

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const { createAlerts, DEDUPE_MS, RING_SIZE } = require('../lib/ci-dispatch-alerts');

function setup(over = {}) {
    const clock = { t: Date.UTC(2026, 9, 6, 12, 0, 0) };
    const lines = [];
    const logger = { warn: (m) => lines.push(m), log: (m) => lines.push(m) };
    const alerts = createAlerts(Object.assign({ now: () => clock.t, logger, getEmitter: () => null }, over));
    return { alerts, clock, lines };
}

describe('stub path (no emitFleetNotice)', () => {
    test('logs [CI-DISPATCH] ALERT and records into the ring', () => {
        const { alerts, lines } = setup();
        const r = alerts.raise('ci-no-capacity', { severity: 'high', title: 'No capacity', body: 'm1mini: paused', ref: 'class:long' });
        assert.deepEqual(r, { raised: true, via: 'log' });
        assert.equal(lines.length, 1);
        assert.match(lines[0], /^\[CI-DISPATCH\] ALERT ci-no-capacity \(high\) No capacity -- m1mini: paused$/);
        const l = alerts.list();
        assert.equal(l.length, 1);
        assert.equal(l[0].type, 'ci-no-capacity');
        assert.equal(l[0].severity, 'high');
        assert.equal(l[0].via, 'log');
    });

    test('dedupes per type+ref for 15 min, then fires again; other ref/type is independent', () => {
        const { alerts, clock, lines } = setup();
        assert.equal(DEDUPE_MS, 15 * 60 * 1000);
        assert.equal(alerts.raise('ci-no-capacity', { title: 't', ref: 'class:long' }).raised, true);
        clock.t += DEDUPE_MS - 1;
        assert.deepEqual(alerts.raise('ci-no-capacity', { title: 't', ref: 'class:long' }), { raised: false, deduped: true });
        assert.equal(alerts.raise('ci-no-capacity', { title: 't', ref: 'class:short' }).raised, true);
        assert.equal(alerts.raise('ci-dispatcher-degraded', { title: 't', ref: 'class:long' }).raised, true);
        clock.t += 1;
        assert.equal(alerts.raise('ci-no-capacity', { title: 't', ref: 'class:long' }).raised, true);
        assert.equal(lines.length, 4); // deduped raises neither log nor ring
        assert.equal(alerts.list().length, 4);
    });

    test('ring keeps the newest 50, newest first', () => {
        const { alerts } = setup();
        assert.equal(RING_SIZE, 50);
        for (let i = 0; i < 60; i++) alerts.raise('ci-no-capacity', { title: `a${i}`, ref: `r${i}` });
        const l = alerts.list();
        assert.equal(l.length, 50);
        assert.equal(l[0].title, 'a59');
        assert.equal(l[49].title, 'a10');
    });

    test('list() returns copies', () => {
        const { alerts } = setup();
        alerts.raise('ci-no-capacity', { title: 'x', ref: 'r' });
        alerts.list()[0].title = 'mutated';
        assert.equal(alerts.list()[0].title, 'x');
    });

    test('bad type is refused; unknown severity falls back to warning; text is control-stripped and capped', () => {
        const { alerts } = setup();
        assert.equal(alerts.raise('Bad Type!', { title: 'x' }).raised, false);
        alerts.raise('ci-dispatcher-degraded', { severity: 'bogus', title: 'a\nb\u0000c', body: 'z'.repeat(5000), ref: 'r' });
        const e = alerts.list()[0];
        assert.equal(e.severity, 'warning');
        assert.equal(e.title, 'a b c');
        assert.equal(e.body.length, 1000);
    });
});

describe('emitFleetNotice present', () => {
    test('calls it with the alert, records via=fleet-notice, and does not log the stub line', () => {
        const calls = [];
        const { alerts, lines } = setup({ getEmitter: () => (n) => calls.push(n) });
        const r = alerts.raise('ci-no-capacity', { severity: 'high', title: 'T', body: 'B', ref: 'class:short' });
        assert.deepEqual(r, { raised: true, via: 'fleet-notice' });
        assert.deepEqual(calls, [{ type: 'ci-no-capacity', severity: 'high', title: 'T', body: 'B', ref: 'class:short' }]);
        assert.equal(lines.length, 0);
        assert.equal(alerts.list()[0].via, 'fleet-notice');
    });

    test('dedupe is identical with the emitter present (called once for a repeat)', () => {
        const calls = [];
        const { alerts } = setup({ getEmitter: () => (n) => calls.push(n) });
        alerts.raise('ci-no-capacity', { title: 'T', ref: 'k' });
        alerts.raise('ci-no-capacity', { title: 'T', ref: 'k' });
        assert.equal(calls.length, 1);
    });

    test('a throwing emitter falls back to the log path and never throws', () => {
        const { alerts, lines } = setup({ getEmitter: () => () => { throw new Error('boom'); } });
        const r = alerts.raise('ci-no-capacity', { title: 'T', ref: 'k' });
        assert.deepEqual(r, { raised: true, via: 'log' });
        assert.equal(lines.length, 2);
        assert.match(lines[0], /emitter failed \(boom\)/);
        assert.match(lines[1], /ALERT ci-no-capacity/);
    });

    test('a throwing resolver is treated as absent', () => {
        const { alerts } = setup({ getEmitter: () => { throw new Error('nope'); } });
        assert.equal(alerts.raise('ci-no-capacity', { title: 'T', ref: 'k' }).via, 'log');
    });

    test('the emitter is resolved per raise, so a late-arriving XACA-1400 export is picked up', () => {
        let fn = null;
        const calls = [];
        const { alerts } = setup({ getEmitter: () => fn });
        assert.equal(alerts.raise('ci-no-capacity', { title: 'T', ref: 'a' }).via, 'log');
        fn = (n) => calls.push(n);
        assert.equal(alerts.raise('ci-no-capacity', { title: 'T', ref: 'b' }).via, 'fleet-notice');
        assert.equal(calls.length, 1);
    });
});
