//
//  xaca-1473-serial-identity.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1473 -- UPS serial identity.
 *
 * describe('sanitizer') (XACA-1473-003): sanitizePowerBlock accepts an OPTIONAL
 * ups.serial matching ^[A-Za-z0-9._-]{1,64}$. A bad serial drops ONLY the
 * serial key (deliberate exception to XACA-1391's "any invalid field nulls
 * the whole ups" rule); an absent serial adds no key (never null).
 * Exercised through the app-factory mirror, which
 * xaca-1031-007-mirror-drift-guard.test.js ties to server.js.
 *
 * describe('identity & migration') (XACA-1473-004 / -011): revised D2. Ids are
 * permanent: a machine+name accessory that later reports a serial ADOPTS it in place
 * (same id, so power-guard policies pinning acc_1b9f710a9764b3ff keep matching); only
 * an accessory first discovered with a serial gets a serial-derived id.
 */
const { describe, test } = require('node:test');
const assert = require('node:assert/strict');
const request = require('./helpers/loopback-request');
const { createApp, helpers } = require('./helpers/app-factory.js');

const { normalizeSystemBlock } = helpers;
const GUID = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

function goodUps(over) {
    return Object.assign({
        name: 'CP1500PFCLCDa',
        id: 19333121,
        percent: 100,
        charging: false,
        minutes_remaining: 52,
        present: true
    }, over);
}
function baseUps() { return goodUps(); }

async function roundTrip(system) {
    const { app } = createApp({ machines: new Map() });
    const post = await request(app).post('/api/status').send({
        machine: { machine_id: GUID, hostname: 'runabout', ip: '10.0.0.5', os: 'Darwin' },
        sessions: [],
        system
    });
    assert.equal(post.status, 200);
    const res = await request(app).get('/api/fleet');
    return res.body.fleet.machines.find((m) => m.machine_id === GUID);
}

describe('sanitizer', () => {
    const VALID = ['CXXRT7000254', 'a', 'A.b_c-9', 'x'.repeat(64)];
    for (const serial of VALID) {
        test(`valid serial passes through unchanged: ${serial.slice(0, 20)}`, () => {
            const out = normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ serial }) } });
            assert.deepEqual(out.power, { source: 'ups', ups: goodUps({ serial }) });
            assert.equal(out.power.ups.serial, serial);
        });
    }

    const INVALID = [
        ['number', 12345],
        ['null', null],
        ['boolean', true],
        ['object', { a: 1 }],
        ['array', ['CXX']],
        ['empty string', ''],
        ['space', 'CXX 123'],
        ['slash', 'CXX/123'],
        ['control char', 'CXX\n123'],
        ['unicode', 'CXXé123'],
        ['too long (65)', 'x'.repeat(65)],
        ['hostile oversized', 'z'.repeat(5000)]
    ];
    for (const [label, serial] of INVALID) {
        test(`invalid serial (${label}) drops ONLY the serial; other ups fields intact`, () => {
            const out = normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ serial }) } });
            assert.deepEqual(out.power, { source: 'ups', ups: baseUps() });
            assert.equal(has(out.power.ups, 'serial'), false);
        });
    }

    test('absent serial: output identical to pre-1473 (no serial key, not null)', () => {
        const out = normalizeSystemBlock({ power: { source: 'ups', ups: goodUps() } });
        assert.deepEqual(out.power, { source: 'ups', ups: baseUps() });
        assert.equal(has(out.power.ups, 'serial'), false);
    });

    test('a valid serial does NOT rescue an otherwise-invalid ups (rule kept for existing fields)', () => {
        const out = normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ serial: 'CXX1', percent: 101 }) } });
        assert.deepEqual(out.power, { source: 'ups', ups: null });
    });

    test('serial on ups:null / non-object ups is ignored (no leak)', () => {
        const out = normalizeSystemBlock({ power: { source: 'ac', ups: null, serial: 'CXX1' } });
        assert.deepEqual(out.power, { source: 'ac', ups: null });
    });

    test('unknown extra keys still stripped alongside a serial', () => {
        const out = normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ serial: 'CXX1', evil: 'x' }) } });
        assert.deepEqual(out.power.ups, goodUps({ serial: 'CXX1' }));
    });

    test('projection round trip (POST -> /api/fleet): valid serial reaches the fleet', async () => {
        const m = await roundTrip({ versions: {}, power: { source: 'ups', ups: goodUps({ serial: 'CXXRT7000254' }) } });
        assert.deepEqual(m.system.power, { source: 'ups', ups: goodUps({ serial: 'CXXRT7000254' }) });
    });

    test('projection round trip: invalid serial dropped, rest of ups survives', async () => {
        const m = await roundTrip({ versions: {}, power: { source: 'ups', ups: goodUps({ serial: 'bad serial!' }) } });
        assert.deepEqual(m.system.power, { source: 'ups', ups: baseUps() });
    });

    test('projection round trip: absent serial stays absent', async () => {
        const m = await roundTrip({ versions: {}, power: { source: 'ups', ups: goodUps() } });
        assert.equal(has(m.system.power.ups, 'serial'), false);
    });
});

// ---------------------------------------------------------------------------
// XACA-1473-004 / -011: registry identity & migration (revised D2)
// ---------------------------------------------------------------------------
const fs = require('fs');
const os = require('os');
const path = require('path');
const express = require('express');
const { beforeEach, afterEach } = require('node:test');
const acc = require('../lib/accessories');

describe('identity & migration', () => {
    const MID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; // data-link host
    const MID_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; // attached peer
    const NAME = 'CP1500PFCLCDa';
    const SERIAL = 'CXXRT7000254'; // real M1Mini CP1500 serial (fixture m1mini-ioreg-hid-power.txt)
    const P = (ups, source) => ({ source: source || 'ac', ups: Object.assign({ name: NAME, id: 53280768, percent: 100, charging: false, minutes_remaining: 52, present: true }, ups || {}) });
    const onDisk = (f) => JSON.parse(fs.readFileSync(f, 'utf8')).accessories;

    let tmp, file;
    beforeEach(() => {
        tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1473-004-'));
        file = path.join(tmp, 'data', 'accessories.json');
    });
    afterEach(() => { fs.rmSync(tmp, { recursive: true, force: true }); });

    /** Mirrors server.js's POST /api/status tail (as xaca-1394-001 does). */
    function appFor(reg, machines) {
        const app = express();
        app.use(express.json());
        app.post('/api/status', (req, res) => {
            const mk = req.body.machine_id;
            if (req.body.power) machines.get(mk).system = { power: req.body.power };
            try {
                const p = machines.get(mk).system.power;
                if (p) reg.upsertFromReport(mk, p);
            } catch (e) { /* mirrors server.js */ }
            let statusAccessories;
            try { statusAccessories = reg.statusAccessoriesFor(reg.derive(machines).accessories, mk); } catch (e) { /* omit */ }
            res.status(200).json({ success: true, ...(statusAccessories ? { accessories: statusAccessories } : {}) });
        });
        return app;
    }

    test('id formulas: name id unchanged from XACA-1392; serial id is a distinct domain with the same shape', () => {
        const crypto = require('crypto');
        const legacy = 'acc_' + crypto.createHash('sha256').update(`${MID}\u0000${NAME}`, 'utf8').digest('hex').slice(0, 16);
        assert.equal(acc.accessoryId(MID, NAME), legacy);
        const sid = acc.accessoryIdForSerial(MID, SERIAL);
        assert.match(sid, acc.ACCESSORY_ID_RE);
        assert.notEqual(sid, acc.accessoryId(MID, SERIAL)); // a UPS NAMED like the serial cannot collide
        assert.notEqual(sid, legacy);
    });

    test('XACA-1473-011: power-guard contract -- a machine+name accessory keeps its id after a serialed report (state file + /api/status accessories[])', async () => {
        // Seed exactly as an XACA-1392 server would have: a serial-less report.
        // (M1Mini's real machine UUID is not in the repo, so the pinned acc_1b9f710a9764b3ff
        // cannot be reproduced literally; the unchanged formula is asserted instead.)
        const reg = acc.createRegistry({ file });
        const oldId = reg.upsertFromReport(MID, P());
        assert.equal(oldId, acc.accessoryId(MID, NAME));
        reg.attach(oldId, MID_B);
        reg.setNickname(oldId, 'Rack UPS');
        const machines = new Map([[MID, { machine_id: MID, status: 'online', system: { power: P() } }],
            [MID_B, { machine_id: MID_B, status: 'online', system: {} }]]);
        reg.derive(machines); // unknown -> ac transition into history
        const before = reg.get(oldId);
        assert.equal(before.history.length, 1);

        // New reporter: same UPS now carries its serial, and goes on battery.
        const app = appFor(reg, machines);
        const resHost = await request(app).post('/api/status').send({ machine_id: MID, power: P({ serial: SERIAL, percent: 77 }, 'ups') });
        const resPeer = await request(app).post('/api/status').send({ machine_id: MID_B });
        for (const res of [resHost, resPeer]) {
            assert.equal(res.status, 200);
            assert.equal(res.body.accessories.length, 1);
            assert.equal(res.body.accessories[0].id, oldId); // the id power-guard pins
            assert.equal(res.body.accessories[0].nickname, 'Rack UPS');
            assert.equal(res.body.accessories[0].state, 'on_battery');
        }
        // Persisted state: one record, same id, serial adopted, everything else kept.
        const disk = onDisk(file);
        assert.deepEqual(Object.keys(disk), [oldId]);
        assert.equal(disk[oldId].serial, SERIAL);
        assert.equal(disk[oldId].nickname, 'Rack UPS');
        assert.deepEqual(disk[oldId].attachedMachineIds, [MID, MID_B]);
        assert.deepEqual(disk[oldId].history.slice(-1), before.history); // old history kept, new transition prepended
        assert.equal(disk[oldId].createdAt, before.createdAt);
        // ...and it survives a restart with the same id.
        const reg2 = acc.createRegistry({ file });
        assert.equal(reg2.load().loaded, 1);
        assert.equal(reg2.get(oldId).serial, SERIAL);
        assert.equal(reg2.upsertFromReport(MID, P({ serial: SERIAL })), oldId);
    });

    test('first discovered WITH a serial -> machine+name id (rollback-safe), serial stored on it', () => {
        const reg = acc.createRegistry({ file });
        const id = reg.upsertFromReport(MID, P({ serial: SERIAL }));
        assert.equal(id, acc.accessoryId(MID, NAME));
        assert.notEqual(id, acc.accessoryIdForSerial(MID, SERIAL));
        assert.equal(reg.get(id).serial, SERIAL);
        assert.equal(onDisk(file)[id].serial, SERIAL);
        assert.deepEqual(reg.get(id).attachedMachineIds, [MID]);
    });

    test('second same-name UPS with a different serial gets the serial-derived id; both coexist and keep their ids', () => {
        const reg = acc.createRegistry({ file });
        const a = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        const b = reg.upsertFromReport(MID, P({ serial: 'SERIALB2' }));
        assert.equal(a, acc.accessoryId(MID, NAME));
        assert.equal(b, acc.accessoryIdForSerial(MID, 'SERIALB2'));
        assert.deepEqual(Object.keys(onDisk(file)).sort(), [a, b].sort());
        const reg2 = acc.createRegistry({ file });
        assert.deepEqual(reg2.load(), { loaded: 2, skipped: 0, status: 'ok' });
        assert.equal(reg2.upsertFromReport(MID, P({ serial: 'SERIALA1' })), a);
        assert.equal(reg2.upsertFromReport(MID, P({ serial: 'SERIALB2' })), b);
        assert.equal(reg2.get(a).serial, 'SERIALA1');
        assert.equal(reg2.get(b).serial, 'SERIALB2');
    });

    test('rollback: the PRE-1473 load rule (d40debc3 cleanRecord) keeps a first-discovered-with-serial record; only the 2nd same-name UPS is lost', () => {
        // Re-implementation of the d40debc3 cleanRecord id gate, verbatim in substance:
        // type, machine id, upsId, name checks, then id === accessoryId(machine, name).
        // Unknown keys (serial) were simply not copied into the cleaned record.
        const oldServerKeeps = (id, r) => acc.ACCESSORY_ID_RE.test(id) && r !== null && typeof r === 'object'
            && r.type === 'ups'
            && typeof r.dataLinkMachineId === 'string' && !!r.dataLinkMachineId && r.dataLinkMachineId.length <= 128
            && typeof r.upsId === 'string' && !!r.upsId
            && typeof r.name === 'string' && !!r.name && r.name.length <= 64
            && acc.accessoryId(r.dataLinkMachineId, r.name) === id;
        const reg = acc.createRegistry({ file });
        const a = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        reg.setNickname(a, 'Rack UPS');
        reg.attach(a, MID_B);
        const b = reg.upsertFromReport(MID, P({ serial: 'SERIALB2' }));
        const disk = onDisk(file);
        assert.equal(oldServerKeeps(a, disk[a]), true);   // survives rollback with nickname/attachments
        assert.equal(disk[a].nickname, 'Rack UPS');
        assert.deepEqual(disk[a].attachedMachineIds, [MID, MID_B]);
        assert.equal(oldServerKeeps(b, disk[b]), false);  // documented, unavoidable: old server would merge them anyway
    });

    test('no serial (old reporter) behaves exactly as XACA-1392: machine+name id, no serial key', () => {
        const reg = acc.createRegistry({ file });
        const id = reg.upsertFromReport(MID, P());
        assert.equal(id, acc.accessoryId(MID, NAME));
        assert.equal(has(reg.get(id), 'serial'), false);
        assert.equal(has(onDisk(file)[id], 'serial'), false);
        assert.equal(reg.upsertFromReport(MID, P({ id: 1 })), id);
        assert.equal(reg.size(), 1);
    });

    test('idempotent: repeated serialed reports keep one record, one id, seq advances', () => {
        const reg = acc.createRegistry({ file });
        const id = reg.upsertFromReport(MID, P());
        for (let i = 0; i < 5; i++) assert.equal(reg.upsertFromReport(MID, P({ serial: SERIAL, id: 1000 + i })), id);
        assert.equal(reg.size(), 1);
        assert.equal(reg.get(id).serial, SERIAL);
        assert.equal(reg._records.get(id).seq, 6);
    });

    test('two same-model UPSes with different serials on one machine -> two accessories', () => {
        const reg = acc.createRegistry({ file });
        const a = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        const b = reg.upsertFromReport(MID, P({ serial: 'SERIALB2' }));
        assert.notEqual(a, b);
        assert.equal(reg.size(), 2);
        assert.equal(reg.upsertFromReport(MID, P({ serial: 'SERIALA1' })), a);
        assert.equal(reg.upsertFromReport(MID, P({ serial: 'SERIALB2' })), b);
    });

    test('migration interaction: X adopted by serial A; a later B (same name) creates a NEW accessory and never steals X', () => {
        const reg = acc.createRegistry({ file });
        const x = reg.upsertFromReport(MID, P());
        reg.setNickname(x, 'Left');
        assert.equal(reg.upsertFromReport(MID, P({ serial: 'SERIALA1' })), x);
        const b = reg.upsertFromReport(MID, P({ serial: 'SERIALB2' }));
        assert.equal(b, acc.accessoryIdForSerial(MID, 'SERIALB2'));
        assert.equal(reg.get(x).serial, 'SERIALA1');
        assert.equal(reg.get(x).nickname, 'Left');
        assert.equal(reg.get(b).nickname, null);
        assert.equal(reg.size(), 2);
    });

    test('no-serial report for an accessory already holding a serial: matches it by name, never erases the serial', () => {
        const reg = acc.createRegistry({ file });
        const x = reg.upsertFromReport(MID, P());
        reg.upsertFromReport(MID, P({ serial: SERIAL }));
        assert.equal(reg.upsertFromReport(MID, P()), x); // reporter rolled back / ioreg failed this cycle
        assert.equal(reg.size(), 1);
        assert.equal(reg.get(x).serial, SERIAL);
        assert.equal(onDisk(file)[x].serial, SERIAL);
        // Same for an accessory FIRST discovered with a serial (minted on the name id, serial stored).
        const reg2 = acc.createRegistry({ file: path.join(tmp, 'b.json') });
        const s = reg2.upsertFromReport(MID, P({ serial: SERIAL }));
        assert.equal(reg2.upsertFromReport(MID, P()), s);
        assert.equal(reg2.size(), 1);
        assert.equal(reg2.get(s).serial, SERIAL);
    });

    test('no-serial report when two same-name accessories exist is AMBIGUOUS: no update, no new accessory, logged', () => {
        const logs = [];
        const reg = acc.createRegistry({ file, log: (m) => logs.push(m) });
        const a = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        const b = reg.upsertFromReport(MID, P({ serial: 'SERIALB2' }));
        const seqA = reg._records.get(a).seq, seqB = reg._records.get(b).seq;
        assert.equal(reg.upsertFromReport(MID, P()), null);
        assert.equal(reg.size(), 2);
        assert.equal(reg._records.get(a).seq, seqA);
        assert.equal(reg._records.get(b).seq, seqB);
        assert.ok(logs.some((l) => /matches 2 accessories/.test(l)), logs.join('\n'));
        // derive: an ambiguous report says nothing about either UPS -> unknown, never ac.
        const machines = new Map([[MID, { machine_id: MID, status: 'online', system: { power: P() } }]]);
        for (const v of reg.derive(machines).accessories) assert.equal(v.state, 'unknown');
    });

    test('derive: a report carrying ANOTHER serial does not drive this accessory (same name)', () => {
        const reg = acc.createRegistry({ file });
        const a = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }, 'ups'));
        const b = reg.upsertFromReport(MID, P({ serial: 'SERIALB2' }, 'ups'));
        const machines = new Map([[MID, { machine_id: MID, status: 'online', system: { power: P({ serial: 'SERIALB2' }, 'ups') } }]]);
        const byId = new Map(reg.derive(machines).accessories.map((v) => [v.id, v]));
        assert.equal(byId.get(b).state, 'on_battery');
        assert.equal(byId.get(a).state, 'unknown');
    });

    test('serial is scoped to the data-link machine (same serial on another host is another accessory)', () => {
        const reg = acc.createRegistry({ file });
        const a = reg.upsertFromReport(MID, P({ serial: SERIAL }));
        const b = reg.upsertFromReport(MID_B, P({ serial: SERIAL }));
        assert.notEqual(a, b);
        assert.equal(reg.size(), 2);
    });

    test('persistence round-trip: reload preserves serial and id for adopted AND serial-minted records', () => {
        const reg = acc.createRegistry({ file });
        const x = reg.upsertFromReport(MID, P());
        reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        const s = reg.upsertFromReport(MID, P({ serial: 'SERIALB2' }));
        reg.flushIfDirty();
        const reg2 = acc.createRegistry({ file });
        assert.deepEqual(reg2.load(), { loaded: 2, skipped: 0, status: 'ok' });
        assert.equal(reg2.get(x).serial, 'SERIALA1');
        assert.equal(reg2.get(s).serial, 'SERIALB2');
        assert.equal(reg2.upsertFromReport(MID, P({ serial: 'SERIALA1' })), x);
        assert.equal(reg2.upsertFromReport(MID, P({ serial: 'SERIALB2' })), s);
        assert.equal(reg2.size(), 2);
    });

    test('load: a pre-1473 file with no serial fields loads unchanged', () => {
        const id = acc.accessoryId(MID, NAME);
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, JSON.stringify({ schemaVersion: 1, accessories: { [id]: { type: 'ups', name: NAME, dataLinkMachineId: MID, upsId: '1', attachedMachineIds: [MID], nickname: 'Old' } } }));
        const reg = acc.createRegistry({ file });
        assert.deepEqual(reg.load(), { loaded: 1, skipped: 0, status: 'ok' });
        assert.equal(has(reg.get(id), 'serial'), false);
        assert.equal(reg.get(id).nickname, 'Old');
    });

    test('load: malformed stored serial -- name-id record keeps loading (serial dropped, re-adopted later); serial-id record is rejected', () => {
        const nameId = acc.accessoryId(MID, NAME);
        const serialId = acc.accessoryIdForSerial(MID_B, 'GOODSERIAL');
        const base = (mid, serial) => ({ type: 'ups', name: NAME, dataLinkMachineId: mid, upsId: '1', attachedMachineIds: [mid], serial });
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, JSON.stringify({ schemaVersion: 1, accessories: {
            [nameId]: base(MID, 'bad serial!'),
            [serialId]: base(MID_B, 12345), // non-string: cannot verify a serial-derived id
        } }));
        const reg = acc.createRegistry({ file });
        assert.deepEqual(reg.load(), { loaded: 1, skipped: 1, status: 'ok' });
        assert.equal(has(reg.get(nameId), 'serial'), false);
        assert.equal(reg.get(serialId), null);
        assert.equal(reg.upsertFromReport(MID, P({ serial: SERIAL })), nameId); // re-adopts in place
        assert.equal(reg.get(nameId).serial, SERIAL);
    });

    test('load: a serial-derived id whose stored serial does not hash to it is rejected', () => {
        const serialId = acc.accessoryIdForSerial(MID, 'SERIALA1');
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, JSON.stringify({ schemaVersion: 1, accessories: {
            [serialId]: { type: 'ups', name: NAME, dataLinkMachineId: MID, upsId: '1', serial: 'SERIALB2' },
        } }));
        const reg = acc.createRegistry({ file });
        assert.deepEqual(reg.load(), { loaded: 0, skipped: 1, status: 'ok' });
    });
});

// ---------------------------------------------------------------------------
// XACA-1473-005 (Testing & Debugging): adversarial identity / migration cases
// ---------------------------------------------------------------------------
describe('adversarial identity & migration (XACA-1473-005)', () => {
    const MID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const MID_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const NAME = 'CP1500PFCLCDa';
    const P = (ups, source) => ({ source: source || 'ac', ups: Object.assign({ name: NAME, id: 53280768, percent: 100, charging: false, minutes_remaining: 52, present: true }, ups || {}) });
    let tmp, file;
    beforeEach(() => {
        tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1473-005-'));
        file = path.join(tmp, 'data', 'accessories.json');
    });
    afterEach(() => { fs.rmSync(tmp, { recursive: true, force: true }); });

    test('a serialed report never adopts a same-name record that lives on a DIFFERENT data-link machine', () => {
        const reg = acc.createRegistry({ file });
        const x = reg.upsertFromReport(MID, P());
        const y = reg.upsertFromReport(MID_B, P({ serial: 'SERIALA1' }));
        assert.notEqual(x, y);
        assert.equal(reg.size(), 2);
        assert.equal(Object.prototype.hasOwnProperty.call(reg.get(x), 'serial'), false);
        assert.equal(reg.get(y).dataLinkMachineId, MID_B);
    });

    test('name change on a serialed record: matched by serial, same id, name frozen (id hashes it), no duplicate; survives reload', () => {
        const reg = acc.createRegistry({ file });
        const x = reg.upsertFromReport(MID, P());
        reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        assert.equal(reg.upsertFromReport(MID, P({ serial: 'SERIALA1', name: 'Renamed UPS' })), x);
        assert.equal(reg.size(), 1);
        assert.equal(reg.get(x).name, NAME);
        reg.flushIfDirty();
        const reg2 = acc.createRegistry({ file });
        assert.equal(reg2.load().loaded, 1);
        assert.equal(reg2.get(x).serial, 'SERIALA1');
    });

    test('rapid alternation serialed / serial-less / serialed: one record, serial never erased, seq advances every time', () => {
        const reg = acc.createRegistry({ file });
        const ids = [];
        for (const s of [undefined, 'SERIALA1', undefined, undefined, 'SERIALA1', undefined]) {
            ids.push(reg.upsertFromReport(MID, P(s ? { serial: s } : {})));
        }
        assert.equal(new Set(ids).size, 1);
        assert.equal(reg.size(), 1);
        assert.equal(reg.get(ids[0]).serial, 'SERIALA1');
        assert.equal(reg.get(ids[0]).seq, 6);
    });

    test('hand-edited file with BOTH a name-id record already holding serial S and a serial-id record for S: loads, resolves deterministically, never creates a third', () => {
        const nameId = acc.accessoryId(MID, NAME);
        const serialId = acc.accessoryIdForSerial(MID, 'SERIALA1');
        const rec = (serial) => ({ type: 'ups', name: NAME, dataLinkMachineId: MID, upsId: '1', attachedMachineIds: [MID], serial });
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, JSON.stringify({ schemaVersion: 1, accessories: { [nameId]: rec('SERIALA1'), [serialId]: rec('SERIALA1') } }));
        const reg = acc.createRegistry({ file });
        assert.deepEqual(reg.load(), { loaded: 2, skipped: 0, status: 'ok' });
        const first = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        const second = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        assert.equal(first, second);                 // deterministic
        assert.ok([nameId, serialId].includes(first));
        assert.equal(reg.size(), 2);                 // no third record
    });

    test('ambiguous serial-less report leaves derived state coherent: no stale on_battery/ac on either record', () => {
        const reg = acc.createRegistry({ file });
        reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }, 'ups'));
        reg.upsertFromReport(MID, P({ serial: 'SERIALB2' }, 'ups'));
        const machines = new Map([[MID, { machine_id: MID, status: 'online', system: { power: P({}, 'ups') } }]]);
        reg.derive(machines);
        for (const v of reg.derive(machines).accessories) assert.equal(v.state, 'unknown');
    });
});

// ---------------------------------------------------------------------------
// XACA-1473-014: same-model UPS hardware swap keeps the accessory (and its pinned id)
// XACA-1473-015: serial-less report after a rename -- accepted limit, pinned
// ---------------------------------------------------------------------------
describe('hardware swap (XACA-1473-014) & rename limit (XACA-1473-015)', () => {
    const MID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const MID_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const NAME = 'CP1500PFCLCDa';
    const W = acc.SWAP_STALE_MS;
    const P = (ups, source) => ({ source: source || 'ac', ups: Object.assign({ name: NAME, id: 53280768, percent: 100, charging: false, minutes_remaining: 52, present: true }, ups || {}) });
    const onDisk = (f) => JSON.parse(fs.readFileSync(f, 'utf8')).accessories;
    // Same re-implementation of the d40debc3 (pre-1473) cleanRecord id gate as the rollback test above.
    const oldServerKeeps = (id, r) => acc.ACCESSORY_ID_RE.test(id) && r !== null && typeof r === 'object'
        && r.type === 'ups'
        && typeof r.dataLinkMachineId === 'string' && !!r.dataLinkMachineId && r.dataLinkMachineId.length <= 128
        && typeof r.upsId === 'string' && !!r.upsId
        && typeof r.name === 'string' && !!r.name && r.name.length <= 64
        && acc.accessoryId(r.dataLinkMachineId, r.name) === id;

    let tmp, file, t, logs;
    const clock = () => new Date(t);
    const mk = () => acc.createRegistry({ file, now: clock, log: (m) => logs.push(m) });
    beforeEach(() => {
        tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1473-014-'));
        file = path.join(tmp, 'data', 'accessories.json');
        t = Date.parse('2026-10-12T00:00:00.000Z');
        logs = [];
    });
    afterEach(() => { fs.rmSync(tmp, { recursive: true, force: true }); });

    test('W is the server offline threshold (server.js OFFLINE_THRESHOLD_MS), not a new number', () => {
        const src = fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8');
        const m = src.match(/const OFFLINE_THRESHOLD_MS = (\d+) \* 1000;/);
        assert.ok(m, 'OFFLINE_THRESHOLD_MS declaration not found in server.js');
        assert.equal(W, Number(m[1]) * 1000);
        assert.equal(W, 180000);
    });

    test('swap after silence >= W: same id (acc_ name id), nickname, attachments, history kept; replaced serial recorded; persists + reloads; old server still loads it', () => {
        const reg = mk();
        const id = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        assert.equal(id, acc.accessoryId(MID, NAME));
        reg.setNickname(id, 'Rack UPS');
        reg.attach(id, MID_B);
        reg.derive(new Map([[MID, { machine_id: MID, status: 'online', system: { power: P({ serial: 'SERIALA1' }) } }]]));
        const before = reg.get(id);

        t += W; // old unit silent for exactly W
        const swapAt = new Date(t).toISOString();
        assert.equal(reg.upsertFromReport(MID, P({ serial: 'SERIALB2', id: 777 }, 'ups')), id);
        assert.equal(reg.size(), 1);
        const r = reg.get(id);
        assert.equal(r.serial, 'SERIALB2');
        assert.equal(r.upsId, '777');
        assert.equal(r.nickname, 'Rack UPS');
        assert.deepEqual(r.attachedMachineIds, [MID, MID_B]);
        assert.deepEqual(r.history, before.history);
        assert.equal(r.createdAt, before.createdAt);
        assert.deepEqual(r.replacedSerials, [{ serial: 'SERIALA1', until: swapAt }]);
        assert.ok(logs.some((l) => /SERIALA1 replaced by SERIALB2/.test(l)), logs.join('\n'));

        // Flushed immediately; reload keeps everything and keeps matching B on the same id.
        const disk = onDisk(file);
        assert.deepEqual(Object.keys(disk), [id]);
        assert.deepEqual(disk[id].replacedSerials, [{ serial: 'SERIALA1', until: swapAt }]);
        assert.equal(oldServerKeeps(id, disk[id]), true); // rollback-safe: name id survives a pre-1473 server
        const reg2 = mk();
        assert.deepEqual(reg2.load(), { loaded: 1, skipped: 0, status: 'ok' });
        assert.equal(reg2.get(id).serial, 'SERIALB2');
        assert.deepEqual(reg2.get(id).replacedSerials, [{ serial: 'SERIALA1', until: swapAt }]);
        assert.equal(reg2.upsertFromReport(MID, P({ serial: 'SERIALB2' })), id);

        // Power-guard contract: the pinned id now carries the NEW unit's state.
        const machines = new Map([[MID, { machine_id: MID, status: 'online', system: { power: P({ serial: 'SERIALB2' }, 'ups') } }],
            [MID_B, { machine_id: MID_B, status: 'online', system: {} }]]);
        const out = reg2.derive(machines);
        assert.equal(out.accessories[0].id, id);
        assert.equal(out.accessories[0].state, 'on_battery');
        assert.equal(out.machines.get(MID_B).power_state, 'on_battery');
    });

    test('swap at W-1ms does NOT adopt: the old unit is still live, a second accessory is minted on the serial id', () => {
        const reg = mk();
        const id = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        t += W - 1;
        const b = reg.upsertFromReport(MID, P({ serial: 'SERIALB2' }));
        assert.equal(b, acc.accessoryIdForSerial(MID, 'SERIALB2'));
        assert.equal(reg.size(), 2);
        assert.equal(reg.get(id).serial, 'SERIALA1');
        assert.equal(has(reg.get(id), 'replacedSerials'), false);
        assert.equal(has(reg.get(b), 'replacedSerials'), false);
    });

    test('genuine two-UPS host (serials alternating every reporter cycle, < W apart) keeps two accessories, never swaps', () => {
        const reg = mk();
        const a = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        let b = null;
        for (let i = 0; i < 20; i++) {
            t += 60 * 1000;
            const s = i % 3 === 0 ? 'SERIALA1' : 'SERIALB2'; // irregular order, one UPS per cycle
            const got = reg.upsertFromReport(MID, P({ serial: s }));
            if (s === 'SERIALB2') { b = b || got; assert.equal(got, b); } else assert.equal(got, a);
        }
        assert.equal(b, acc.accessoryIdForSerial(MID, 'SERIALB2'));
        assert.equal(reg.size(), 2);
        assert.equal(reg.get(a).serial, 'SERIALA1');
        assert.equal(reg.get(b).serial, 'SERIALB2');
        assert.equal(has(reg.get(a), 'replacedSerials'), false);
        assert.ok(!logs.some((l) => /replaced by/.test(l)), logs.join('\n'));
    });

    test('old unit A returning after a swap while B is still live: two units really are connected -> A is a NEW accessory (serial id)', () => {
        const reg = mk();
        const id = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        t += W;
        assert.equal(reg.upsertFromReport(MID, P({ serial: 'SERIALB2' })), id); // swap A -> B
        t += 60 * 1000;
        const a2 = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        assert.equal(a2, acc.accessoryIdForSerial(MID, 'SERIALA1'));
        assert.equal(reg.get(id).serial, 'SERIALB2');
        assert.equal(reg.size(), 2);
    });

    test('swap back: B silent >= W then A returns -> same id takes A again; trail is [B] (A no longer listed as replaced)', () => {
        const reg = mk();
        const id = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        t += W;
        reg.upsertFromReport(MID, P({ serial: 'SERIALB2' }));
        t += W;
        const backAt = new Date(t).toISOString();
        assert.equal(reg.upsertFromReport(MID, P({ serial: 'SERIALA1' })), id);
        assert.equal(reg.size(), 1);
        assert.equal(reg.get(id).serial, 'SERIALA1');
        assert.deepEqual(reg.get(id).replacedSerials, [{ serial: 'SERIALB2', until: backAt }]);
    });

    test('replacedSerials is bounded to MAX_REPLACED_SERIALS, newest first', () => {
        const reg = mk();
        const id = reg.upsertFromReport(MID, P({ serial: 'S0' }));
        for (let i = 1; i <= acc.MAX_REPLACED_SERIALS + 3; i++) {
            t += W;
            assert.equal(reg.upsertFromReport(MID, P({ serial: `S${i}` })), id);
        }
        const trail = reg.get(id).replacedSerials;
        assert.equal(trail.length, acc.MAX_REPLACED_SERIALS);
        assert.equal(trail[0].serial, `S${acc.MAX_REPLACED_SERIALS + 2}`);
    });

    test('derive() applies the same swap rule as the upsert: stale record + new serial drives that record; at W-1ms it does not', () => {
        for (const [gap, expectSame] of [[W, true], [W - 1, false]]) {
            const reg = acc.createRegistry({ file: path.join(tmp, `d-${gap}.json`), now: clock });
            const start = t;
            const id = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
            t = start + gap;
            // Host's latest report (not yet upserted) carries the new unit, on battery.
            const machines = new Map([[MID, { machine_id: MID, status: 'online', system: { power: P({ serial: 'SERIALB2' }, 'ups') } }]]);
            const v = reg.derive(machines).accessories.find((x) => x.id === id);
            assert.equal(v.state, expectSame ? 'on_battery' : 'unknown', `gap=${gap}`);
            assert.equal(reg.upsertFromReport(MID, P({ serial: 'SERIALB2' }, 'ups')) === id, expectSame, `gap=${gap}`);
            t = start;
        }
    });

    test('limit (pinned): only the machine+name record is swap-adopted -- when the serial-id unit was the last one read, a new serial is minted, not adopted', () => {
        const reg = mk();
        const a = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        t += 60 * 1000;
        const b = reg.upsertFromReport(MID, P({ serial: 'SERIALB2' })); // serial id, read last
        t += W;
        const d = reg.upsertFromReport(MID, P({ serial: 'SERIALD4' }));
        assert.equal(d, acc.accessoryIdForSerial(MID, 'SERIALD4'));
        assert.equal(reg.get(a).serial, 'SERIALA1');
        assert.equal(reg.get(b).serial, 'SERIALB2');
        assert.equal(reg.size(), 3);
    });

    test('both same-name units silent >= W: the machine+name record, if it was the last read, is swap-adopted; an exact tie adopts nothing', () => {
        const reg = mk();
        const a = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        t += 1;
        const b = reg.upsertFromReport(MID, P({ serial: 'SERIALB2' }));
        t += 60 * 1000;
        reg.upsertFromReport(MID, P({ serial: 'SERIALA1' })); // A read last
        t += W;
        assert.equal(reg.upsertFromReport(MID, P({ serial: 'SERIALD4' })), a);
        assert.equal(reg.get(b).serial, 'SERIALB2');

        // Tie: both last observed at the same instant -> cannot tell which unit left.
        const reg2 = acc.createRegistry({ file: path.join(tmp, 'tie.json'), now: clock });
        const a2 = reg2.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        reg2.upsertFromReport(MID, P({ serial: 'SERIALB2' })); // same t: minted on serial id
        t += W;
        const d2 = reg2.upsertFromReport(MID, P({ serial: 'SERIALD4' }));
        assert.equal(d2, acc.accessoryIdForSerial(MID, 'SERIALD4'));
        assert.equal(reg2.get(a2).serial, 'SERIALA1');
    });

    test('a pre-existing serial-id record for B wins over the swap (stored-serial match, step 1)', () => {
        const reg = mk();
        const a = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        const b = reg.upsertFromReport(MID, P({ serial: 'SERIALB2' })); // live sibling -> serial id
        t += 10 * W;
        assert.equal(reg.upsertFromReport(MID, P({ serial: 'SERIALB2' })), b);
        assert.equal(reg.get(a).serial, 'SERIALA1');
        assert.equal(has(reg.get(a), 'replacedSerials'), false);
    });

    test('swap is scoped to the data-link machine and to the name (a different model is a new accessory, as before)', () => {
        const reg = mk();
        const a = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        t += W;
        const other = reg.upsertFromReport(MID_B, P({ serial: 'SERIALB2' }));
        assert.equal(other, acc.accessoryId(MID_B, NAME));
        const model = reg.upsertFromReport(MID, P({ serial: 'SERIALC3', name: 'BR1500MS2' }));
        assert.equal(model, acc.accessoryId(MID, 'BR1500MS2'));
        assert.equal(reg.get(a).serial, 'SERIALA1');
        assert.equal(reg.size(), 3);
    });

    test('load: malformed replacedSerials is dropped, never fatal (non-array, bad entries filtered, empty -> no key)', () => {
        const id = acc.accessoryId(MID, NAME);
        const id2 = acc.accessoryId(MID_B, NAME);
        const rec = (mid, replacedSerials) => ({ type: 'ups', name: NAME, dataLinkMachineId: mid, upsId: '1', attachedMachineIds: [mid], serial: 'SERIALB2', replacedSerials });
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, JSON.stringify({ schemaVersion: 1, accessories: {
            [id]: rec(MID, [{ serial: 'SERIALA1', until: '2026-10-12T00:00:00.000Z', extra: 'x' }, { serial: 'bad serial!', until: 'x' }, { serial: 'OK1' }, 'nope', null, { serial: 'OK2', until: 5 }]),
            [id2]: rec(MID_B, 'not-an-array'),
        } }));
        const reg = mk();
        assert.deepEqual(reg.load(), { loaded: 2, skipped: 0, status: 'ok' });
        assert.deepEqual(reg.get(id).replacedSerials, [{ serial: 'SERIALA1', until: '2026-10-12T00:00:00.000Z' }]);
        assert.equal(has(reg.get(id2), 'replacedSerials'), false);
        assert.equal(reg.get(id2).serial, 'SERIALB2');
        // An all-invalid array also yields no key.
        assert.equal(has(acc.cleanRecord(id, rec(MID, [{ serial: '' }])), 'replacedSerials'), false);
    });

    test('XACA-1473-015 accepted limit: serialed UPS renamed N->N2, then a SERIAL-LESS N2 report mints a separate N2 name-id accessory', () => {
        // The name is the only match key a serial-less report has, and a serialed record's name is
        // frozen (its id hashes it). Pre-1473 a rename re-keyed too, so this is not a regression.
        const reg = mk();
        const x = reg.upsertFromReport(MID, P({ serial: 'SERIALA1' }));
        assert.equal(reg.upsertFromReport(MID, P({ serial: 'SERIALA1', name: 'Renamed UPS' })), x); // serial still matches
        assert.equal(reg.get(x).name, NAME);
        const dup = reg.upsertFromReport(MID, P({ name: 'Renamed UPS' }));
        assert.equal(dup, acc.accessoryId(MID, 'Renamed UPS'));
        assert.notEqual(dup, x);
        assert.equal(reg.size(), 2);
        assert.equal(has(reg.get(dup), 'serial'), false);
        // Once the serial is readable again it is matched by serial to x, not to the duplicate.
        assert.equal(reg.upsertFromReport(MID, P({ serial: 'SERIALA1', name: 'Renamed UPS' })), x);
    });
});
