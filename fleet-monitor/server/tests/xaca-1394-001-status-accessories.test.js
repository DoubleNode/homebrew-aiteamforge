//
//  xaca-1394-001-status-accessories.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1394-001 -- POST /api/status 200 response carries `accessories[]` (EPIC-0067 item 4/5).
 *
 * server.js listens on require, so (like the xaca-1392 suites) the route tail is exercised
 * through a minimal express harness that calls the SAME registry code path, and a static
 * guard pins that server.js uses the identical fail-closed construction.
 */

const { test, describe, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const express = require('express');
const request = require('supertest');

const acc = require('../lib/accessories');
const SERVER_JS = fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8');

const MID_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; // data-link host
const MID_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const MID_C = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'; // unattached

const UPS = (o) => Object.assign({ name: 'CP1500PFCLCDa', id: 1, percent: 85, charging: false, minutes_remaining: 40, present: true }, o || {});
const POWER = (source, ups) => ({ source, ups: ups === undefined ? UPS() : ups });
const machine = (id, status, power) => ({ machine_id: id, hostname: `h-${id.slice(0, 4)}`, status, system: power === undefined ? {} : { power } });
const mapOf = (...ms) => new Map(ms.map((m) => [m.machine_id, m]));

let tmp, file;
beforeEach(() => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1394-001-'));
    file = path.join(tmp, 'data', 'accessories.json');
});
afterEach(() => { fs.rmSync(tmp, { recursive: true, force: true }); });

/** Harness mirroring server.js's /api/status tail. `deriveFn` is injectable to force a throw. */
function appFor(reg, machines, deriveFn) {
    const app = express();
    app.use(express.json());
    app.post('/api/status', (req, res) => {
        const machineKey = req.body.machine_id;
        try {
            const p = machines.get(machineKey).system.power;
            if (p) reg.upsertFromReport(machineKey, p);
        } catch (e) { /* mirrors server.js: upsert failure never blocks */ }
        let statusAccessories;
        try {
            statusAccessories = reg.statusAccessoriesFor((deriveFn || (() => reg.derive(machines)))().accessories, machineKey);
        } catch (e) { /* omit key */ }
        res.status(200).json({ success: true, ...(statusAccessories ? { accessories: statusAccessories } : {}) });
    });
    return app;
}
const post = (app, id) => request(app).post('/api/status').send({ machine_id: id });

describe('accessories[] on the 200', () => {
    test('attached machine gets its accessory with derived state and reading', async () => {
        const reg = acc.createRegistry({ file });
        const machines = mapOf(machine(MID_A, 'online', POWER('ups')), machine(MID_B, 'online'), machine(MID_C, 'online'));
        const id = reg.upsertFromReport(MID_A, POWER('ups'));
        reg.attach(id, MID_B);
        const res = await post(appFor(reg, machines), MID_B);
        assert.equal(res.status, 200);
        assert.equal(res.body.accessories.length, 1);
        const a = res.body.accessories[0];
        assert.equal(a.id, id);
        assert.equal(a.state, 'on_battery');
        assert.equal(a.percent, 85);
        assert.equal(a.minutes_remaining, 40);
        assert.equal(typeof a.observedAt, 'string');
        assert.equal(a.seq, 1);
        assert.equal(a.type, 'ups');
    });

    test('unattached machine gets [] (key present)', async () => {
        const reg = acc.createRegistry({ file });
        const machines = mapOf(machine(MID_A, 'online', POWER('ups')), machine(MID_C, 'online'));
        reg.upsertFromReport(MID_A, POWER('ups'));
        const res = await post(appFor(reg, machines), MID_C);
        assert.equal(res.status, 200);
        assert.deepEqual(res.body.accessories, []);
    });

    test('empty registry still yields []', async () => {
        const reg = acc.createRegistry({ file });
        const res = await post(appFor(reg, mapOf(machine(MID_C, 'online'))), MID_C);
        assert.deepEqual(res.body.accessories, []);
    });

    test('two machines attached to one UPS both get it', async () => {
        const reg = acc.createRegistry({ file });
        const machines = mapOf(machine(MID_A, 'online', POWER('ac')), machine(MID_B, 'online'));
        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        reg.attach(id, MID_B);
        const app = appFor(reg, machines);
        const a = await post(app, MID_A);
        const b = await post(app, MID_B);
        assert.equal(a.body.accessories[0].id, id);
        assert.equal(b.body.accessories[0].id, id);
        assert.equal(b.body.accessories[0].state, 'ac');
    });

    test('state is the registry-derived value: reporter source "battery" => unknown, never on_battery', async () => {
        const reg = acc.createRegistry({ file });
        const machines = mapOf(machine(MID_A, 'online', POWER('battery')));
        reg.upsertFromReport(MID_A, POWER('battery'));
        const res = await post(appFor(reg, machines), MID_A);
        assert.equal(res.body.accessories[0].state, 'unknown');
    });

    test('offline data-link host => derived unknown (never a stale on_battery)', async () => {
        const reg = acc.createRegistry({ file });
        const id = reg.upsertFromReport(MID_A, POWER('ups'));
        reg.attach(id, MID_B);
        const machines = mapOf(machine(MID_A, 'offline', POWER('ups')), machine(MID_B, 'online'));
        const res = await post(appFor(reg, machines), MID_B);
        assert.equal(res.body.accessories[0].state, 'unknown');
        assert.equal(res.body.accessories[0].percent, 85); // last reading still reported; observedAt lets the client judge freshness
    });

    test('no reading yet => null fields, state unknown', () => {
        const reg = acc.createRegistry({ file });
        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        reg.attach(id, MID_B);
        reg._records.get(id).lastReading = null;
        const out = reg.statusAccessoriesFor(reg.derive(mapOf(machine(MID_A, 'online'), machine(MID_B, 'online'))).accessories, MID_B);
        assert.equal(out[0].state, 'unknown');
        assert.equal(out[0].percent, null);
        assert.equal(out[0].minutes_remaining, null);
        assert.equal(out[0].observedAt, null);
    });

    test('derive throwing => key OMITTED and still a 200', async () => {
        const reg = acc.createRegistry({ file });
        const machines = mapOf(machine(MID_B, 'online'));
        const res = await post(appFor(reg, machines, () => { throw new Error('boom'); }), MID_B);
        assert.equal(res.status, 200);
        assert.equal(res.body.success, true);
        assert.equal('accessories' in res.body, false);
    });
});

describe('seq', () => {
    test('increments on every stored reading and persists across reload', () => {
        const reg = acc.createRegistry({ file });
        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        assert.equal(reg.get(id).seq, 1);
        reg.upsertFromReport(MID_A, POWER('ac'));
        reg.upsertFromReport(MID_A, POWER('ups'));
        assert.equal(reg.get(id).seq, 3);
        reg.save();
        const reg2 = acc.createRegistry({ file });
        reg2.load();
        assert.equal(reg2.get(id).seq, 3);
        reg2.upsertFromReport(MID_A, POWER('ac'));
        assert.equal(reg2.get(id).seq, 4);
    });

    test('a no-op report (ups:null) does not bump seq', () => {
        const reg = acc.createRegistry({ file });
        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        reg.upsertFromReport(MID_A, POWER('ac', null));
        assert.equal(reg.get(id).seq, 1);
    });

    test('legacy record without seq loads as 0 and continues', () => {
        const reg = acc.createRegistry({ file });
        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        reg.save();
        const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
        const recs = raw.accessories;
        const rec = Array.isArray(recs) ? recs.find((r) => r.id === id) : recs[id];
        delete rec.seq;
        fs.writeFileSync(file, JSON.stringify(raw));
        const reg2 = acc.createRegistry({ file });
        reg2.load();
        assert.equal(reg2.get(id).seq, 0);
        reg2.upsertFromReport(MID_A, POWER('ac'));
        assert.equal(reg2.get(id).seq, 1);
    });

    test('garbage seq (negative, float, string) loads as 0', () => {
        for (const bad of [-5, 1.5, 'x', null]) {
            assert.equal(acc.cleanRecord(acc.accessoryId(MID_A, 'N'), {
                type: 'ups', name: 'N', dataLinkMachineId: MID_A, upsId: '1', seq: bad,
            }).seq, 0);
        }
    });
});

describe('server.js wiring (static)', () => {
    test('fail-closed construction is present in the /api/status handler', () => {
        assert.match(SERVER_JS, /statusAccessories = accessoryRegistry\.statusAccessoriesFor\(deriveAccessoryStateOrThrow\(\)\.accessories, machineKey\)/);
        assert.match(SERVER_JS, /\.\.\.\(statusAccessories \? \{ accessories: statusAccessories \} : \{\}\)/);
    });
});
