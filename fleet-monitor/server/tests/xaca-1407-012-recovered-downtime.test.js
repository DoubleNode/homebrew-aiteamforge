//
//  xaca-1407-012-recovered-downtime.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1407-012 -- machine-recovered reports the machine's REAL downtime (now minus its last
 * heartbeat before the recovering one), not the time since Fleet Monitor noticed. Table-driven over
 * every path by which FM learns of an outage, plus bad lastSeen fallbacks.
 */

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createMachineNoticeTracker } = require('../lib/fleet-notice-sources');

const SEC = 1000, MIN = 60 * SEC, HOUR = 60 * MIN, DAY = 24 * HOUR;
const T0 = Date.UTC(2026, 9, 13, 12, 0, 0);

function mk() {
    const clock = { t: T0 };
    const sent = [];
    const tr = createMachineNoticeTracker({
        emit: (n) => { sent.push(n); }, now: () => clock.t, offlineThresholdMs: 180 * SEC,
        logger: { warn() {}, log() {} },
    });
    const sweep = (st, lastSeen) => { tr.beginSweep(); tr.observe('m', st, { label: 'm', lastSeen }); };
    return { tr, clock, sent, sweep };
}
const iso = (ms) => new Date(ms).toISOString();
// Advance the clock in 30 s ticks (a sweep per tick, as server.js does) so no gap reads as an FM stall.
const advance = (c, ms, st, lastSeen) => { for (let i = 0; i < ms / (30 * SEC); i++) { c.clock.t += 30 * SEC; c.sweep(st, lastSeen); } };
const recovered = (sent) => sent.filter((n) => n.type === 'machine-recovered');

// Each scenario runs the outage by its own path and returns the recovery clock + the lastSeen the
// server would pass at the recovering heartbeat (the machine's previous last_seen).
const SCENARIOS = [
    ['offline before restart, boot-baselined, real 3 days', '3d', (c) => {
        const lastBeat = T0 - 3 * DAY;
        c.sweep('offline', iso(lastBeat));                 // boot sweep: baseline offline, no notice
        c.clock.t += 2 * SEC;                              // heartbeat 2 s after boot
        return { lastSeen: iso(lastBeat) };
    }],
    ['live boot test, real 60 minutes', '1h 0m', (c) => {
        const lastBeat = T0 - 60 * MIN;
        c.sweep('offline', iso(lastBeat));
        c.clock.t += 2 * SEC;
        return { lastSeen: iso(lastBeat) };
    }],
    ['normal offline then recovery, real 10 minutes', '10m', (c) => {
        c.sweep('online', iso(T0));
        const lastBeat = T0;
        advance(c, 3 * MIN, 'online', iso(lastBeat));
        advance(c, 30 * SEC, 'offline', iso(lastBeat));                        // detected ~3.5 min after last beat
        c.clock.t = lastBeat + 10 * MIN;
        return { lastSeen: iso(lastBeat) };
    }],
    ['held by the stall guard, announced later, real ~14 minutes', '14m', (c) => {
        c.sweep('online', iso(T0));
        const lastBeat = T0;
        c.clock.t += 6 * MIN; c.sweep('offline', iso(lastBeat));               // gap 6 min > 90 s: stall, held
        for (let i = 0; i < 6; i++) { c.clock.t += 30 * SEC; c.sweep('offline', iso(lastBeat)); } // grace passes: announced
        c.clock.t = lastBeat + 14 * MIN;
        return { lastSeen: iso(lastBeat) };
    }],
    ['re-offline shortly after recovering (suppressed, then escalated), real 12 minutes', '12m', (c) => {
        c.sweep('online', iso(T0));
        advance(c, 3 * MIN, 'online', iso(T0));
        advance(c, 30 * SEC, 'offline', iso(T0));                              // 1st offline, announced
        c.clock.t += 30 * SEC; c.tr.beginSweep(); c.tr.observe('m', 'online', { label: 'm', lastSeen: iso(T0) }); // recovered
        const lastBeat = c.clock.t;
        advance(c, 3 * MIN, 'online', iso(lastBeat));
        advance(c, 30 * SEC, 'offline', iso(lastBeat));                        // flap: suppressed
        advance(c, 6 * MIN, 'offline', iso(lastBeat));                         // escalates after the window
        c.sent.length = 0;                                                     // only the 2nd recovery matters
        c.clock.t = lastBeat + 12 * MIN;
        return { lastSeen: iso(lastBeat) };
    }],
];

describe('machine-recovered downtime comes from the machine\'s last heartbeat', () => {
    for (const [name, expected, run] of SCENARIOS) {
        test(name, () => {
            const c = mk();
            const { lastSeen } = run(c);
            c.tr.observe('m', 'online', { label: 'm', lastSeen });
            const r = recovered(c.sent);
            assert.equal(r.length, 1, JSON.stringify(c.sent.map((n) => n.type)));
            assert.match(r[0].body, new RegExp(`after ${expected} offline`), r[0].body);
        });
    }
});

describe('bad lastSeen falls back to the tracker\'s own down-since time', () => {
    const cases = [
        ['missing', undefined],
        ['unparseable', 'not-a-date'],
        ['empty string', ''],
        ['non-string', 12345],
        ['in the future', 'FUTURE'],
    ];
    for (const [name, bad] of cases) {
        test(name, () => {
            const c = mk();
            c.sweep('online', iso(T0));
            advance(c, 3 * MIN, 'online', iso(T0));
            advance(c, 30 * SEC, 'offline', iso(T0));             // tracker down-since = T0+3m30
            advance(c, 6 * MIN, 'offline', iso(T0));             // recovers 6 min after FM noticed
            const lastSeen = bad === 'FUTURE' ? iso(c.clock.t + HOUR) : bad;
            c.tr.observe('m', 'online', { label: 'm', lastSeen });
            const r = recovered(c.sent);
            assert.equal(r.length, 1);
            assert.match(r[0].body, /after 6m offline/, r[0].body);
        });
    }
});

describe('the machine-offline body is already accurate (reports the real last heartbeat)', () => {
    test('"Last seen" carries the machine\'s own last_seen, not FM\'s detection time', () => {
        const c = mk();
        c.sweep('online', iso(T0 - 5 * MIN));
        c.clock.t += 40 * SEC;
        c.sweep('offline', iso(T0 - 5 * MIN));
        const off = c.sent.find((n) => n.type === 'machine-offline');
        assert.ok(off.body.includes(iso(T0 - 5 * MIN)), off.body);
    });
});

describe('server.js heartbeat ordering (structural)', () => {
    const src = fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8');
    test('the recovering observe() passes the PREVIOUS last_seen, never this heartbeat\'s own timestamp', () => {
        const i = src.indexOf("machineNotices.observe(machineKey, 'online'");
        const call = src.slice(i, i + 400);
        assert.match(call, /lastSeen: existingMachine \? existingMachine\.last_seen : undefined/);
        assert.ok(!/lastSeen: now\b/.test(call));
        // and it runs after machines.set(), where the stored last_seen becomes the new value
        assert.ok(i > src.indexOf('last_seen: now,'));
    });
});
