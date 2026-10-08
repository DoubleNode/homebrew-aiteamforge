//
//  xaca-1444-derive.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1444-001/011 -- lib/ci-pool-derive.js: the pure machine-state, queue-age and
 * no-capacity derivations. Every rule in the header comment has a case here.
 */

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const d = require('../lib/ci-pool-derive');
const { labelSetKey, normalizeLabels } = require('../lib/ci-dispatch-placement');

const NOW = Date.UTC(2026, 9, 7, 18, 0, 0);
const idle = { os: 'Linux', index: 1, state: 'idle', assignmentId: null };
const busy = { os: 'Linux', index: 2, state: 'busy', assignmentId: 'a_1' };
const broken = { os: 'Linux', index: 3, state: 'broken', assignmentId: null };
const rep = (over = {}) => Object.assign({ receivedAt: NOW - 5000, slots: [idle], capacity: {} }, over);
const st = (machine, report, over = {}) => d.deriveMachineState(machine, report, Object.assign({ nowMs: NOW, pollStaleMs: 30000 }, over));
const M = (over = {}) => Object.assign({ enabled: true, paused: false }, over);

describe('deriveMachineState', () => {
    test('disabled: not enabled, whatever else is true (paused, busy, no report)', () => {
        assert.equal(st(M({ enabled: false }), rep()).state, 'disabled');
        assert.equal(st(M({ enabled: false, paused: true }), rep({ slots: [busy] })).state, 'disabled');
        assert.equal(st(M({ enabled: false }), null).state, 'disabled');
        assert.equal(st(null, null).state, 'disabled');
    });

    test('enabled: accepting, fresh poll, an online slot, no stale marker', () => {
        assert.deepEqual(st(M(), rep()), { state: 'enabled', reason: 'accepting' });
        assert.equal(st(M(), rep({ pauseMarker: 'absent' })).state, 'enabled');
        assert.equal(st(M(), rep({ slots: [broken, idle] })).state, 'enabled');
    });

    test('draining: pause requested while slots are busy, or the host marker says draining / has not confirmed', () => {
        assert.equal(st(M({ paused: true }), rep({ slots: [idle, busy] })).state, 'draining');
        assert.equal(st(M({ paused: true }), rep({ slots: [{ os: 'Linux', index: 1, state: 'starting', assignmentId: 'a_2' }] })).state, 'draining');
        assert.equal(st(M({ paused: true }), rep({ slots: [{ os: 'Linux', index: 1, state: 'cleaning', assignmentId: null }] })).state, 'draining');
        assert.equal(st(M({ paused: true }), rep({ pauseMarker: 'draining' })).state, 'draining');
        assert.equal(st(M({ paused: true }), rep({ pauseMarker: 'absent' })).state, 'draining');
        assert.equal(st(M({ paused: true }), rep({ pauseMarker: 'resuming' })).state, 'draining');
    });

    test('paused: pause requested, zero busy slots, marker confirms (or an older agent sends none)', () => {
        assert.deepEqual(st(M({ paused: true }), rep({ pauseMarker: 'paused' })), { state: 'paused', reason: 'marker-confirms' });
        assert.deepEqual(st(M({ paused: true }), rep()), { state: 'paused', reason: 'drained' });
    });

    test('resuming: accepting is requested but the host/poll has not caught up', () => {
        assert.equal(st(M(), rep({ pauseMarker: 'resuming' })).state, 'resuming');
        assert.equal(st(M(), rep({ pauseMarker: 'paused' })).state, 'resuming');
        assert.equal(st(M(), rep({ pauseMarker: 'draining' })).state, 'resuming');
        assert.equal(st(M(), rep({ receivedAt: NOW - 31000 })).state, 'resuming');
        assert.equal(st(M(), rep({ slots: [] })).state, 'resuming');
        assert.equal(st(M(), rep({ slots: [broken] })).state, 'resuming');
    });

    test('unknown: insufficient data is never reported as zero or healthy', () => {
        assert.deepEqual(st(M(), null), { state: 'unknown', reason: 'no-report' });
        assert.equal(st(M({ paused: true }), null).state, 'unknown');
        assert.equal(st(M({ paused: true }), rep({ receivedAt: NOW - 60000 })).state, 'unknown');
        assert.equal(st(M(), rep({ pauseMarker: 'corrupt' })).state, 'unknown');
        assert.equal(st(M({ paused: true }), rep({ pauseMarker: 'corrupt' })).state, 'unknown');
        assert.equal(st(M(), { slots: [idle] }).state, 'unknown');   // report without a timestamp
    });

    test('pollStaleMs boundary is inclusive and per-machine overridable by the caller', () => {
        assert.equal(st(M(), rep({ receivedAt: NOW - 30000 })).state, 'enabled');
        assert.equal(st(M(), rep({ receivedAt: NOW - 30001 })).state, 'resuming');
        assert.equal(st(M(), rep({ receivedAt: NOW - 60000 }), { pollStaleMs: 90000 }).state, 'enabled');
    });

    test('every result is one of the six documented states', () => {
        const machines = [M(), M({ paused: true }), M({ enabled: false }), null];
        const reports = [null, rep(), rep({ slots: [busy] }), rep({ pauseMarker: 'corrupt' }), rep({ receivedAt: 1 })];
        for (const m of machines) for (const r of reports) assert.equal(d.MACHINE_STATES.includes(st(m, r).state), true);
    });
});

describe('deriveCapability', () => {
    test('only an agent-reported value is believed; everything else is unknown', () => {
        assert.equal(d.deriveCapability(null), 'unknown');
        assert.equal(d.deriveCapability(rep()), 'unknown');
        assert.equal(d.deriveCapability(rep({ capability: 'dormant' })), 'dormant');
        assert.equal(d.deriveCapability(rep({ capability: 'enabled' })), 'enabled');
        assert.equal(d.deriveCapability(rep({ capability: 'banana' })), 'unknown');
    });
});

describe('queue age + no-capacity', () => {
    const hostOf = (labels) => ((normalizeLabels(labels) || []).includes('m1mini') ? 'm1mini' : null);
    const job = (id, minutesAgo, labels = ['self-hosted', 'macOS', 'ARM64', 'fleet-pool', 'm1mini']) =>
        ({ labels, createdAt: new Date(NOW - minutesAgo * 60000).toISOString(), firstSeenAt: new Date(NOW - 60000).toISOString(), jobId: id });

    test('groups by label set, reports depth + oldest wait, flags the threshold', () => {
        const jobs = [job(1, 32), job(2, 5), job(3, 1, ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'])];
        const q = d.computeQueueAge(jobs, NOW, 15 * 60000, hostOf, labelSetKey);
        assert.equal(q.length, 2);
        assert.deepEqual(q[0], {
            labels: 'arm64,fleet-pool,m1mini,macos,self-hosted', host: 'm1mini', depth: 2,
            oldestQueuedAt: new Date(NOW - 32 * 60000).toISOString(), oldestWaitSec: 32 * 60, overThreshold: true,
        });
        assert.equal(q[1].host, null);
        assert.equal(q[1].overThreshold, false);
    });

    test('exactly at the threshold counts as over; one second under does not', () => {
        assert.equal(d.computeQueueAge([job(1, 15)], NOW, 15 * 60000, hostOf, labelSetKey)[0].overThreshold, true);
        assert.equal(d.computeQueueAge([job(1, 15)], NOW, 15 * 60000 + 1000, hostOf, labelSetKey)[0].overThreshold, false);
    });

    test('createdAt wins over firstSeenAt (a restart must not reset the clock); firstSeenAt is the fallback; no timestamp = unknown, never over', () => {
        const q1 = d.computeQueueAge([{ labels: ['a'], createdAt: new Date(NOW - 20 * 60000).toISOString(), firstSeenAt: new Date(NOW).toISOString() }], NOW, 900000, hostOf, labelSetKey);
        assert.equal(q1[0].oldestWaitSec, 1200);
        const q2 = d.computeQueueAge([{ labels: ['a'], createdAt: 'garbage', firstSeenAt: new Date(NOW - 60000).toISOString() }], NOW, 900000, hostOf, labelSetKey);
        assert.equal(q2[0].oldestWaitSec, 60);
        const q3 = d.computeQueueAge([{ labels: ['a'] }], NOW, 900000, hostOf, labelSetKey);
        assert.deepEqual([q3[0].oldestWaitSec, q3[0].oldestQueuedAt, q3[0].overThreshold], [null, null, false]);
    });

    test('empty queue -> []', () => {
        assert.deepEqual(d.computeQueueAge([], NOW, 1000, hostOf, labelSetKey), []);
        assert.deepEqual(d.computeQueueAge(undefined, NOW, 1000, hostOf, labelSetKey), []);
    });

    test('noCapacity: inactive when nothing is starved', () => {
        const jobs = [job(1, 2)];
        const q = d.computeQueueAge(jobs, NOW, 900000, hostOf, labelSetKey);
        assert.deepEqual(d.computeNoCapacity(jobs.map((rec) => ({ rec, noCapSince: null })), q, 900000, labelSetKey),
            { active: false, since: null, queuedCount: 0, oldestQueuedAt: null });
    });

    test('noCapacity: active on queue age alone (the 2026-10-07 shape: busy runners, nothing "ineligible")', () => {
        const jobs = Array.from({ length: 44 }, (_, i) => job(i, 32 - i * 0.1));
        const q = d.computeQueueAge(jobs, NOW, 900000, hostOf, labelSetKey);
        const nc = d.computeNoCapacity(jobs.map((rec) => ({ rec, noCapSince: null })), q, 900000, labelSetKey);
        assert.equal(nc.active, true);
        assert.equal(nc.queuedCount, 44);
        assert.equal(nc.oldestQueuedAt, new Date(NOW - 32 * 60000).toISOString());
        assert.equal(nc.since, new Date(NOW - 32 * 60000 + 900000).toISOString());   // when the oldest crossed the threshold
    });

    test('noCapacity: active on noCapSince alone, since = the earliest noCapSince, counts only starved jobs', () => {
        const a = job(1, 1); const b = job(2, 1, ['self-hosted', 'Linux', 'ARM64', 'fleet-pool']);
        const q = d.computeQueueAge([a, b], NOW, 900000, hostOf, labelSetKey);
        const nc = d.computeNoCapacity([{ rec: a, noCapSince: NOW - 200000 }, { rec: b, noCapSince: null }], q, 900000, labelSetKey);
        assert.equal(nc.active, true);
        assert.equal(nc.queuedCount, 1);
        assert.equal(nc.since, new Date(NOW - 200000).toISOString());
    });
});

describe('queueAgeThresholdMs', () => {
    test('default 15 min; env override in seconds; junk or out-of-range falls back to the default', () => {
        assert.equal(d.queueAgeThresholdMs({}), 900000);
        assert.equal(d.queueAgeThresholdMs(null), 900000);
        assert.equal(d.queueAgeThresholdMs({ FLEET_CI_QUEUE_AGE_ALERT_SEC: '60' }), 60000);
        for (const bad of ['abc', '0', '-5', '10', '99999999']) assert.equal(d.queueAgeThresholdMs({ FLEET_CI_QUEUE_AGE_ALERT_SEC: bad }), 900000);
    });
});
