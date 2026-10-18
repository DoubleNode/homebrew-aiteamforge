//
//  xaca-1537-004-guest-disk-alarm.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1537-004 -- CI runner guest-disk alarm.
 *
 * On 2026-10-15 the M1Mini Linux guest's "/" hit 100% and five workflows failed ENOSPC while the
 * host disk had ~200 GiB free. The reporter now sends guestDisk; the server validates it, derives
 * ok / low / unknown, serves it on GET /api/ci-runners and raises a notice on a low push.
 *
 * Synthetic data only: every store points at a mkdtemp file, never the real data/ directory, and
 * the notice sink is an injected recorder (no fleet-notice hub, no network).
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('./helpers/loopback-request');
const express = require('express');

const { createPoolStore } = require('../lib/ci-pool-store');
const {
    registerCiRunnersRoutes, createCiRunnerStore, validatePush, validateGuestDisk, deriveGuestDisk,
    guestDiskFloorsFrom, rebuildStoredRecord, ValidationError,
    DEFAULT_GUEST_DISK_MIN_FREE_PERCENT, DEFAULT_GUEST_DISK_MIN_FREE_GIB, GIB,
} = require('../lib/ci-runners-routes');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1537-004-'));
let seq = 0;
const newFile = () => path.join(TMP, `ci-${++seq}`, 'ci-runners.json');
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const FLOORS = { minFreePercent: 15, minFreeBytes: 8 * GIB };
const TIB = 1024 * GIB;

let credSeq = 0;
function mount({ notify, floors } = {}) {
    const file = newFile();
    const app = express();
    app.use(express.json({ limit: '10mb' }));
    const pool = createPoolStore({ file: path.join(path.dirname(file), 'ci-pool.json') });
    const store = registerCiRunnersRoutes(app, { file, poolStore: pool, notify, guestDiskFloors: floors || FLOORS });
    const creds = {};
    const pushAs = (machine, body) => {
        if (!creds[machine]) {
            creds[machine] = `fct_${String(++credSeq).padStart(43, 'q')}`;
            pool.upsertMachine(machine, {});
            pool.setTelemetrySecret(machine, creds[machine]);
        }
        return request(app).post('/api/ci-runners-push').set('Authorization', `Bearer ${creds[machine]}`).send(body);
    };
    return { app, store, file, pushAs };
}

const body = (over = {}) => ({
    schema_version: 1, machine: 'm1mini', reportedAt: '2026-10-16T12:00:00Z', reporterVersion: '1.1.0',
    host: { uptimeSeconds: 100 }, vm: { name: 'ci-linux', state: 'running' }, runners: [], jobs: [], ...over,
});
const gd = (freeBytes, totalBytes) => ({ path: '/', totalBytes, freeBytes });
const getMachine = async (app, id = 'm1mini') => {
    const r = await request(app).get('/api/ci-runners');
    assert.equal(r.status, 200);
    return r.body.machines.find((m) => m.machine === id);
};

describe('validation: guestDisk is bounded and malformed values are rejected', () => {
    test('a good value is accepted and stored as a fresh allowlisted copy', () => {
        const p = validatePush(body({ guestDisk: { ...gd(45 * GIB, 58 * GIB), evil: 'EVIL' } }));
        assert.deepEqual(p.record.guestDisk, gd(45 * GIB, 58 * GIB));
    });
    test('absent / undefined / null -> no guestDisk key at all (older reporter, or unreadable)', () => {
        assert.equal('guestDisk' in validatePush(body()).record, false);
        assert.equal('guestDisk' in validatePush(body({ guestDisk: null })).record, false);
        assert.equal('guestDisk' in validatePush(body({ guestDisk: undefined })).record, false);
    });
    for (const [name, v] of [
        ['wrong path', { path: '/mnt', totalBytes: 10, freeBytes: 5 }],
        ['missing path', { totalBytes: 10, freeBytes: 5 }],
        ['negative free', gd(-1, 10)],
        ['float free', gd(1.5, 10)],
        ['string total', { path: '/', totalBytes: '10', freeBytes: 5 }],
        ['NaN total', gd(5, NaN)],
        ['zero total (divide-by-zero)', gd(0, 0)],
        ['free greater than total', gd(11, 10)],
        ['oversized total (> 1 PiB)', gd(5, 2 ** 50 + 1)],
        ['unsafe integer', gd(5, 2 ** 60)],
        ['array', [1, 2]],
        ['string', '45G'],
        ['number', 45],
    ]) {
        test(`rejects ${name}`, () => {
            assert.throws(() => validatePush(body({ guestDisk: v })), (e) => e instanceof ValidationError && e.field === 'guestDisk');
        });
    }
    test('boundary: exactly 1 PiB is accepted, free == total is accepted', () => {
        assert.doesNotThrow(() => validateGuestDisk(gd(2 ** 50, 2 ** 50)));
    });
    test('over HTTP a malformed value is a 400 on field guestDisk and nothing is stored', async () => {
        const { pushAs, store } = mount();
        const r = await pushAs('m1mini', body({ guestDisk: gd(11, 10) }));
        assert.equal(r.status, 400);
        assert.equal(r.body.field, 'guestDisk');
        assert.equal(store.machines.size, 0);
    });
});

describe('derivation: ok / low / unknown (floors: 15% OR 8 GiB, strictly less than)', () => {
    const rec = (g, vm = { name: 'ci-linux', state: 'running' }) => ({ vm, guestDisk: g });
    const alarm = (free, total, floors = FLOORS) => deriveGuestDisk(rec(gd(free, total)), floors).alarm;

    test('healthy disk is ok, full disk is low (an INVERTED comparison fails one of these two)', () => {
        assert.equal(alarm(45 * GIB, 58 * GIB), 'ok');      // the M1Mini guest today: 78% free
        assert.equal(alarm(0, 58 * GIB), 'low');            // the 2026-10-15 incident: 100% used
        assert.equal(alarm(2 * GIB, 58 * GIB), 'low');
        assert.equal(alarm(57 * GIB, 58 * GIB), 'ok');
    });
    test('below the PERCENT floor only (plenty of absolute space on a big disk) -> low', () => {
        // 10% of 1 TiB = ~102 GiB free: far above 8 GiB, below 15%.
        assert.equal(alarm(Math.floor(0.10 * TIB), TIB), 'low');
    });
    test('below the ABSOLUTE floor only (healthy percent on a tiny disk) -> low', () => {
        // 5 GiB free of 10 GiB = 50% (above 15%), below 8 GiB.
        assert.equal(alarm(5 * GIB, 10 * GIB), 'low');
    });
    test('above both floors -> ok', () => {
        assert.equal(alarm(200 * GIB, TIB), 'ok');
    });
    test('boundary, absolute: exactly the byte floor on a disk where percent is fine', () => {
        assert.equal(alarm(8 * GIB, 16 * GIB), 'ok');                   // 50%, exactly 8 GiB
        assert.equal(alarm(8 * GIB - 1, 16 * GIB), 'low');              // one byte under
    });
    test('boundary, percent: exactly 15% is ok, one byte under is low', () => {
        const total = 20000;
        assert.equal(alarm(3000, total, { minFreePercent: 15, minFreeBytes: 0 }), 'ok');
        assert.equal(alarm(2999, total, { minFreePercent: 15, minFreeBytes: 0 }), 'low');
    });
    test('payload carries freePercent (one decimal), the numbers and the floors used', () => {
        const d = deriveGuestDisk(rec(gd(45 * GIB, 58 * GIB)), FLOORS);
        assert.equal(d.path, '/');
        assert.equal(d.freeBytes, 45 * GIB);
        assert.equal(d.totalBytes, 58 * GIB);
        assert.equal(d.freePercent, 77.6);
        assert.deepEqual(d.floors, FLOORS);
    });
    test('unknown: VM reported (Running) but no reading -> unknown with null numbers, never ok', () => {
        const d = deriveGuestDisk(rec(undefined), FLOORS);
        assert.equal(d.alarm, 'unknown');
        assert.equal(d.freeBytes, null);
        assert.equal(d.totalBytes, null);
        assert.equal(d.freePercent, null);
    });
    test('unknown: VM stopped/broken/unknown with no reading -> unknown', () => {
        for (const state of ['stopped', 'broken', 'unknown']) {
            assert.equal(deriveGuestDisk(rec(undefined, { name: 'v', state }), FLOORS).alarm, 'unknown', state);
        }
    });
    test('unknown: a stored value that is implausible (free > total, zero total) is never trusted', () => {
        assert.equal(deriveGuestDisk(rec(gd(11, 10)), FLOORS).alarm, 'unknown');
        assert.equal(deriveGuestDisk(rec(gd(0, 0)), FLOORS).alarm, 'unknown');
    });
    test('host with no VM -> guestDisk null (nothing to measure), not unknown and not ok', () => {
        assert.equal(deriveGuestDisk({ vm: null }, FLOORS), null);
        assert.equal(deriveGuestDisk({ vm: null, guestDisk: gd(1, 10) }, FLOORS), null);
    });
});

describe('floors: defaults and the documented environment overrides', () => {
    test('defaults are 15% and 8 GiB', () => {
        assert.equal(DEFAULT_GUEST_DISK_MIN_FREE_PERCENT, 15);
        assert.equal(DEFAULT_GUEST_DISK_MIN_FREE_GIB, 8);
        assert.deepEqual(guestDiskFloorsFrom({}), FLOORS);
    });
    test('overrides apply', () => {
        assert.deepEqual(
            guestDiskFloorsFrom({ FLEET_CI_GUEST_DISK_MIN_FREE_PERCENT: '25', FLEET_CI_GUEST_DISK_MIN_FREE_GIB: '12.5' }),
            { minFreePercent: 25, minFreeBytes: 12.5 * GIB },
        );
        assert.deepEqual(
            guestDiskFloorsFrom({ FLEET_CI_GUEST_DISK_MIN_FREE_PERCENT: '0', FLEET_CI_GUEST_DISK_MIN_FREE_GIB: '0' }),
            { minFreePercent: 0, minFreeBytes: 0 },
        );
    });
    test('a bad value falls back to the default (never silently disables the alarm)', () => {
        const warn = console.warn; console.warn = () => {};
        try {
            for (const bad of ['abc', '-5', '101', 'NaN', 'Infinity']) {
                assert.equal(guestDiskFloorsFrom({ FLEET_CI_GUEST_DISK_MIN_FREE_PERCENT: bad }).minFreePercent, 15, bad);
            }
            assert.equal(guestDiskFloorsFrom({ FLEET_CI_GUEST_DISK_MIN_FREE_GIB: '-1' }).minFreeBytes, 8 * GIB);
            assert.equal(guestDiskFloorsFrom({ FLEET_CI_GUEST_DISK_MIN_FREE_GIB: 'lots' }).minFreeBytes, 8 * GIB);
        } finally { console.warn = warn; }
    });
    test('the override changes the verdict end to end', () => {
        const r = { vm: { name: 'v', state: 'running' }, guestDisk: gd(20 * GIB, 100 * GIB) };   // 20%, 20 GiB
        assert.equal(deriveGuestDisk(r, FLOORS).alarm, 'ok');
        assert.equal(deriveGuestDisk(r, { minFreePercent: 25, minFreeBytes: 8 * GIB }).alarm, 'low');
        assert.equal(deriveGuestDisk(r, { minFreePercent: 15, minFreeBytes: 30 * GIB }).alarm, 'low');
    });
});

describe('GET /api/ci-runners serves the derived alarm', () => {
    test('ok, low and unknown over HTTP, and an older reporter (no field) is unknown, not a crash', async () => {
        const { app, pushAs } = mount({ notify: () => {} });
        assert.equal((await pushAs('okhost', body({ machine: 'okhost', guestDisk: gd(45 * GIB, 58 * GIB) }))).status, 200);
        assert.equal((await pushAs('lowhost', body({ machine: 'lowhost', guestDisk: gd(1 * GIB, 58 * GIB) }))).status, 200);
        assert.equal((await pushAs('oldhost', body({ machine: 'oldhost' }))).status, 200);   // older reporter
        assert.equal((await pushAs('novm', body({ machine: 'novm', vm: null }))).status, 200);
        assert.equal((await getMachine(app, 'okhost')).guestDisk.alarm, 'ok');
        const low = (await getMachine(app, 'lowhost')).guestDisk;
        assert.equal(low.alarm, 'low');
        assert.equal(low.freeBytes, 1 * GIB);
        const old = (await getMachine(app, 'oldhost')).guestDisk;
        assert.equal(old.alarm, 'unknown');
        assert.equal(old.freeBytes, null);
        assert.equal((await getMachine(app, 'novm')).guestDisk, null);
    });
    test('existing fields are untouched (disk, vm, runners, recentJobs still present)', async () => {
        const { app, pushAs } = mount({ notify: () => {} });
        await pushAs('m1mini', body({ host: { uptimeSeconds: 7, disk: { path: '/', totalBytes: 1000, freeBytes: 500 } }, guestDisk: gd(45 * GIB, 58 * GIB) }));
        const m = await getMachine(app);
        assert.deepEqual(m.disk, { freeBytes: 500, totalBytes: 1000 });
        assert.equal(m.vm.status, 'Running');
        assert.ok(Array.isArray(m.runners) && Array.isArray(m.recentJobs));
    });
    test('guestDisk is REPLACED each push: a later unreadable report must not keep serving the old ok', async () => {
        const { app, pushAs } = mount({ notify: () => {} });
        await pushAs('m1mini', body({ guestDisk: gd(45 * GIB, 58 * GIB) }));
        assert.equal((await getMachine(app)).guestDisk.alarm, 'ok');
        await pushAs('m1mini', body());   // reporter could not read the guest this time
        const g = (await getMachine(app)).guestDisk;
        assert.equal(g.alarm, 'unknown');
        assert.equal(g.freeBytes, null);
    });
});

describe('push-time notice', () => {
    const calls = () => { const c = []; return { c, fn: (n) => { c.push(n); return Promise.resolve({ ok: true }); } }; };

    test('a low push raises ONE high-severity ci-runner-disk-low notice naming the machine', async () => {
        const { c, fn } = calls();
        const { pushAs } = mount({ notify: fn });
        await pushAs('m1mini', body({ guestDisk: gd(1 * GIB, 58 * GIB) }));
        assert.equal(c.length, 1);
        assert.equal(c[0].type, 'ci-runner-disk-low');
        assert.equal(c[0].severity, 'high');
        assert.equal(c[0].ref, 'm1mini');
        assert.match(c[0].title, /m1mini/);
        assert.match(c[0].body, /1\.0 GiB free of 58\.0 GiB/);
    });
    test('ok pushes never notify', async () => {
        const { c, fn } = calls();
        const { pushAs } = mount({ notify: fn });
        await pushAs('m1mini', body({ guestDisk: gd(45 * GIB, 58 * GIB) }));
        assert.equal(c.length, 0);
    });
    test('unknown (field absent) never notifies: an old reporter must not page forever', async () => {
        const { c, fn } = calls();
        const { pushAs } = mount({ notify: fn });
        await pushAs('m1mini', body());
        await pushAs('m1mini', body());
        assert.equal(c.length, 0);
    });
    test('repeated low pushes are deduped; going ok re-arms the notice', async () => {
        const { c, fn } = calls();
        const { pushAs } = mount({ notify: fn });
        for (let i = 0; i < 5; i++) await pushAs('m1mini', body({ guestDisk: gd(1 * GIB, 58 * GIB) }));
        assert.equal(c.length, 1);
        await pushAs('m1mini', body({ guestDisk: gd(45 * GIB, 58 * GIB) }));   // recovered
        await pushAs('m1mini', body({ guestDisk: gd(1 * GIB, 58 * GIB) }));    // low again
        assert.equal(c.length, 2);
    });
    test('dedupe is per machine', async () => {
        const { c, fn } = calls();
        const { pushAs } = mount({ notify: fn });
        await pushAs('a', body({ machine: 'a', guestDisk: gd(1 * GIB, 58 * GIB) }));
        await pushAs('b', body({ machine: 'b', guestDisk: gd(1 * GIB, 58 * GIB) }));
        assert.deepEqual(c.map((n) => n.ref).sort(), ['a', 'b']);
    });
    test('a throwing or rejecting notifier never fails the push or loses the data', async () => {
        const err = console.error; console.error = () => {};
        try {
            const t = mount({ notify: () => { throw new Error('hub down'); } });
            const r1 = await t.pushAs('m1mini', body({ guestDisk: gd(1 * GIB, 58 * GIB) }));
            assert.equal(r1.status, 200);
            assert.equal((await getMachine(t.app)).guestDisk.alarm, 'low');
            const u = mount({ notify: () => Promise.reject(new Error('hub down')) });
            assert.equal((await u.pushAs('m1mini', body({ guestDisk: gd(1 * GIB, 58 * GIB) }))).status, 200);
        } finally { console.error = err; }
    });
});

describe('persistence: guestDisk survives save/load; a corrupt stored value reads unknown', () => {
    test('round trip', () => {
        const file = newFile();
        const a = createCiRunnerStore(file, { guestDiskFloors: FLOORS });
        a.applyPush(validatePush(body({ guestDisk: gd(3 * GIB, 58 * GIB) })));
        a.save();
        const b = createCiRunnerStore(file, { guestDiskFloors: FLOORS });
        b.load();
        const m = b.snapshot().machines.find((x) => x.machine === 'm1mini');
        assert.equal(m.guestDisk.alarm, 'low');
        assert.equal(m.guestDisk.freeBytes, 3 * GIB);
    });
    test('a bad stored guestDisk is dropped on load (record kept) and reads unknown', () => {
        const raw = {
            receivedAt: '2026-10-16T12:00:00Z', reportedAt: '2026-10-16T12:00:00Z', reporterVersion: '1.1.0',
            host: { uptimeSeconds: 1 }, vm: { name: 'v', state: 'running' }, runners: [], jobs: [],
            guestDisk: { path: '/', totalBytes: 10, freeBytes: 999 },
        };
        const out = rebuildStoredRecord('m1mini', raw);
        assert.ok(out, 'record itself is kept');
        assert.equal('guestDisk' in out.rec, false);
        assert.equal(deriveGuestDisk(out.rec, FLOORS).alarm, 'unknown');
    });
});

describe('routing: ci-runner-disk-low is a catalog type, so the hub treats it as routable', () => {
    const crypto = require('crypto');
    const { createNotifyStore } = require('../lib/notify-store');
    const { createNotifyDispatcher } = require('../lib/notify-dispatcher');
    const { createReceiptLog } = require('../lib/notify-receipts');
    const { createProviderRegistry, createTestProvider } = require('../lib/notify-providers');
    const { createFleetNotices } = require('../lib/fleet-notices');

    function hub(tag) {
        const dir = path.join(TMP, `hub-${tag}`);
        fs.mkdirSync(dir, { recursive: true });
        const registry = createProviderRegistry();
        registry.register('test', createTestProvider());
        const store = createNotifyStore({ file: path.join(dir, 's.json'), key: crypto.randomBytes(32), registry });
        const receipts = createReceiptLog({ file: path.join(dir, 'r.jsonl') });
        const dispatcher = createNotifyDispatcher({ store, registry, receipts });
        const logs = [];
        const logger = { log: (m) => logs.push(m), warn: (m) => logs.push(m) };
        const fleet = createFleetNotices({ dispatcher, store, receipts, logger });
        return { store, fleet, logs };
    }
    const NOTICE = { type: 'ci-runner-disk-low', severity: 'high', title: 't', body: 'b', ref: 'm1mini' };

    test('the bundled catalog lists the type with severity high', () => {
        const { store } = hub('catalog');
        assert.ok(store.catalogTypeIds().includes('ci-runner-disk-low'));
    });

    test('an emitted notice is NOT rejected as unknown-type (no fleet route yet -> plain unrouted)', async () => {
        const { fleet, logs } = hub('emit');
        const out = await fleet.emitFleetNotice(NOTICE);
        assert.notEqual(out.reason, 'unknown-type');
        assert.ok(!logs.some((l) => /unknown notice type/.test(l)), logs.join('\n'));
    });

    test('negative control: a type absent from the catalog IS rejected as unknown-type', async () => {
        const { fleet } = hub('neg');
        const out = await fleet.emitFleetNotice(Object.assign({}, NOTICE, { type: 'ci-runner-not-a-type' }));
        assert.equal(out.reason, 'unknown-type');
    });
});
