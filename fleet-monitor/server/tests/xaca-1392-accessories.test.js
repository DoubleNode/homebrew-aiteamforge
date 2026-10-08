//
//  xaca-1392-accessories.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1392 -- Fleet Monitor accessory registry (EPIC-0067 item 2/5).
 *
 * 001  model + persistence (atomic write, missing/corrupt file, tap/git exclusion)
 * 002  auto-discovery from system.power.ups
 * 003  attachment API + auth tier
 * 004  derived state, precedence, transition history
 * 005  wiring into server.js (static) + projections
 *
 * Every test uses a private temp directory. Nothing here touches the real
 * fleet-monitor/server/data/accessories.json.
 */

const { test, describe, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const acc = require('../lib/accessories');

const SERVER_DIR = path.join(__dirname, '..');
const REPO_ROOT = path.join(SERVER_DIR, '..', '..');

let tmp;
let file;
beforeEach(() => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1392-'));
    file = path.join(tmp, 'data', 'accessories.json');
});
afterEach(() => { fs.rmSync(tmp, { recursive: true, force: true }); });

const MID_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const MID_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

// ===========================================================================
// 001 -- model + persistence
// ===========================================================================
describe('001 persistence', () => {
    test('missing file loads as an empty registry (and does not create the file)', () => {
        const reg = acc.createRegistry({ file });
        const r = reg.load();
        assert.equal(r.status, 'missing');
        assert.equal(reg.size(), 0);
        assert.equal(fs.existsSync(file), false);
    });

    test('corrupt file loads empty, never throws, and is moved aside (not overwritten)', () => {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, '{"accessories": {not json');
        const reg = acc.createRegistry({ file });
        const r = reg.load();
        assert.equal(r.status, 'corrupt');
        assert.equal(reg.size(), 0);
        assert.equal(fs.existsSync(file), false, 'bad file moved aside');
        const aside = fs.readdirSync(path.dirname(file)).filter((f) => f.startsWith('accessories.json.corrupt-'));
        assert.equal(aside.length, 1);
        assert.equal(fs.readFileSync(path.join(path.dirname(file), aside[0]), 'utf8'), '{"accessories": {not json');
    });

    test('wrong-shape JSON (array / missing accessories key) is treated as corrupt', () => {
        for (const body of ['[]', '{"schemaVersion":1}', '"x"', 'null']) {
            fs.mkdirSync(path.dirname(file), { recursive: true });
            fs.writeFileSync(file, body);
            const reg = acc.createRegistry({ file });
            assert.equal(reg.load().status, 'corrupt', body);
            assert.equal(reg.size(), 0);
        }
    });

    test('a malformed record is skipped; good records survive', () => {
        const id = acc.accessoryId(MID_A, 'Good UPS');
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, JSON.stringify({
            schemaVersion: 1,
            accessories: {
                [id]: { type: 'ups', dataLinkMachineId: MID_A, upsId: '1', name: 'Good UPS', attachedMachineIds: [MID_A] },
                acc_deadbeefdeadbeef: { type: 'ups', dataLinkMachineId: MID_A, upsId: '1', name: 'Good UPS' }, // id does not match identity
                bogus: 'nope',
            },
        }));
        const reg = acc.createRegistry({ file });
        const r = reg.load();
        assert.equal(r.status, 'ok');
        assert.equal(r.loaded, 1);
        assert.equal(r.skipped, 2);
        assert.equal(reg.get(id).name, 'Good UPS');
    });

    test('save() is atomic: round-trips, leaves no temp file, creates the data dir', () => {
        const reg = acc.createRegistry({ file });
        reg.upsertFromReport(MID_A, { source: 'ac', ups: { name: 'UPS', id: 1, percent: 100, charging: false, minutes_remaining: 60, present: true } });
        assert.equal(reg.save(), true);
        const names = fs.readdirSync(path.dirname(file));
        assert.deepEqual(names, ['accessories.json'], 'no .tmp-* left behind');
        const reg2 = acc.createRegistry({ file });
        assert.equal(reg2.load().status, 'ok');
        assert.equal(reg2.size(), 1);
        assert.deepEqual(reg2.list()[0].attachedMachineIds, [MID_A]);
    });

    test('a failed write leaves the previous file intact and no partial/temp file', () => {
        const reg = acc.createRegistry({ file });
        reg.upsertFromReport(MID_A, { source: 'ac', ups: { name: 'UPS', id: 1, percent: 100, charging: false, minutes_remaining: 60, present: true } });
        reg.save();
        const before = fs.readFileSync(file, 'utf8');
        // Make rename fail by turning the destination into a directory.
        const realRename = fs.renameSync;
        fs.renameSync = () => { throw new Error('simulated rename failure'); };
        let ok;
        try {
            reg.upsertFromReport(MID_B, { source: 'ac', ups: { name: 'UPS 2', id: 2, percent: 50, charging: true, minutes_remaining: 30, present: true } });
            ok = reg.save();
        } finally { fs.renameSync = realRename; }
        assert.equal(ok, false);
        assert.equal(fs.readFileSync(file, 'utf8'), before, 'old file untouched');
        assert.deepEqual(fs.readdirSync(path.dirname(file)), ['accessories.json'], 'temp cleaned up');
        assert.equal(reg.size(), 2, 'in-memory state kept');
        assert.equal(reg.flushIfDirty(), true, 'dirty flag survives so the next flush retries and succeeds');
        assert.equal(acc.createRegistry({ file }).load().loaded, 2);
    });

    test('file path is injectable: the default is the real data path, an override never touches it', () => {
        assert.match(acc.DEFAULT_FILE, /fleet-monitor[\\/]server[\\/]data[\\/]accessories\.json$/);
        const reg = acc.createRegistry({ file });
        assert.equal(reg.file, file);
        assert.notEqual(reg.file, acc.DEFAULT_FILE);
    });
});

describe('001 git + tap-mirror exclusion (the two lists must match one-for-one)', () => {
    const gitignore = fs.readFileSync(path.join(REPO_ROOT, '.gitignore'), 'utf8');
    const syncTap = fs.readFileSync(path.join(REPO_ROOT, 'sync-tap.sh'), 'utf8');
    for (const suffix of ['accessories.json', 'accessories.json.tmp-*', 'accessories.json.corrupt-*']) {
        test(`.gitignore, sync_dir find, and RUNTIME-STATE-GUARD all list ${suffix}`, () => {
            assert.ok(gitignore.includes(`fleet-monitor/server/data/${suffix}\n`), '.gitignore');
            assert.ok(syncTap.includes(`-not -path "*/fleet-monitor/server/data/${suffix}" \\`), 'sync_dir find');
            assert.ok(syncTap.includes(`fleet-monitor/server/data/${suffix}|\\`), 'runtime-state guard case list');
        });
    }
});

// ===========================================================================
// shared helpers for 002-005
// ===========================================================================
const UPS = (over) => Object.assign({ name: 'Back-UPS ES 600M1', id: 19333121, percent: 85, charging: false, minutes_remaining: 40, present: true }, over || {});
const POWER = (source, ups) => ({ source, ups: ups === undefined ? UPS() : ups });
const machine = (id, status, power) => ({ machine_id: id, hostname: `h-${id.slice(0, 4)}`, status, system: power === undefined ? {} : { power } });
const mapOf = (...ms) => new Map(ms.map((m) => [m.machine_id, m]));

// ===========================================================================
// 002 -- auto-discovery
// ===========================================================================
describe('002 auto-discovery', () => {
    test('first report creates exactly one accessory; a repeat updates it, no duplicate', () => {
        const reg = acc.createRegistry({ file });
        const id1 = reg.upsertFromReport(MID_A, POWER('ac'));
        const id2 = reg.upsertFromReport(MID_A, POWER('ac', UPS({ percent: 80 })));
        assert.equal(id1, id2);
        assert.equal(reg.size(), 1);
        assert.equal(reg.get(id1).lastReading.percent, 80);
        assert.equal(reg.get(id1).nickname, null);
        assert.equal(reg.get(id1).name, 'Back-UPS ES 600M1');
        assert.equal(reg.get(id1).type, 'ups');
    });

    test('same name + CHANGED ups.id (pmset id is volatile) -> same accessory, id attribute updated, attachments preserved', () => {
        const reg = acc.createRegistry({ file });
        const a = reg.upsertFromReport(MID_A, POWER('ac', UPS({ name: 'CP1500PFCLCDa', id: 19333121 })));
        reg.attach(a, MID_B);
        reg.setNickname(a, 'Rack UPS');
        const b = reg.upsertFromReport(MID_A, POWER('ac', UPS({ name: 'CP1500PFCLCDa', id: 53280768 })));
        assert.equal(a, b);
        assert.equal(reg.size(), 1);
        assert.equal(reg.get(a).upsId, '53280768');
        assert.deepEqual(reg.get(a).attachedMachineIds, [MID_A, MID_B]);
        assert.equal(reg.get(a).nickname, 'Rack UPS');
        // integer vs string form of the same id is likewise not an identity question
        reg.upsertFromReport(MID_A, POWER('ac', UPS({ name: 'CP1500PFCLCDa', id: '53280768' })));
        assert.equal(reg.size(), 1);
        // the changed id is persisted and survives a restart
        const reg2 = acc.createRegistry({ file });
        reg2.load();
        assert.equal(reg2.get(a).upsId, '53280768');
    });

    test('different name on the same machine -> distinct accessory', () => {
        const reg = acc.createRegistry({ file });
        const a = reg.upsertFromReport(MID_A, POWER('ac', UPS({ name: 'CP1500PFCLCDa', id: 1 })));
        const b = reg.upsertFromReport(MID_A, POWER('ac', UPS({ name: 'Back-UPS ES 600M1', id: 1 })));
        assert.notEqual(a, b);
        assert.equal(reg.size(), 2);
    });

    test('same name on DIFFERENT machines -> distinct accessories', () => {
        const reg = acc.createRegistry({ file });
        const a = reg.upsertFromReport(MID_A, POWER('ac', UPS({ name: 'CP1500PFCLCDa' })));
        const b = reg.upsertFromReport(MID_B, POWER('ac', UPS({ name: 'CP1500PFCLCDa' })));
        assert.notEqual(a, b);
        assert.equal(reg.size(), 2);
    });

    test('identity is machine + name only: accessoryId() ignores everything else and is acc_ + 16 hex', () => {
        assert.match(acc.accessoryId(MID_A, 'CP1500PFCLCDa'), /^acc_[0-9a-f]{16}$/);
        assert.equal(acc.accessoryId(MID_A, 'CP1500PFCLCDa'), acc.accessoryId(MID_A, 'CP1500PFCLCDa'));
        assert.notEqual(acc.accessoryId(MID_A, 'CP1500PFCLCDa'), acc.accessoryId(MID_B, 'CP1500PFCLCDa'));
        assert.notEqual(acc.accessoryId(MID_A, 'CP1500PFCLCDa'), acc.accessoryId(MID_A, 'Other'));
    });

    test('data-link host is auto-attached on creation', () => {
        const reg = acc.createRegistry({ file });
        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        assert.deepEqual(reg.get(id).attachedMachineIds, [MID_A]);
        assert.equal(reg.get(id).dataLinkMachineId, MID_A);
    });

    test('an operator detach of the data-link host is NOT undone by the next report', () => {
        const reg = acc.createRegistry({ file });
        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        reg.detach(id, MID_A);
        reg.upsertFromReport(MID_A, POWER('ac'));
        assert.deepEqual(reg.get(id).attachedMachineIds, []);
    });

    test('power ABSENT is a no-op: nothing created, existing accessory state not mutated', () => {
        const reg = acc.createRegistry({ file });
        assert.equal(reg.upsertFromReport(MID_A, undefined), null);
        assert.equal(reg.upsertFromReport(MID_A, null), null);
        assert.equal(reg.size(), 0);
        const id = reg.upsertFromReport(MID_A, POWER('ups'));
        reg.derive(mapOf(machine(MID_A, 'online', POWER('ups'))));
        assert.equal(reg.get(id).state, 'on_battery');
        const before = JSON.stringify(reg.get(id));
        reg.upsertFromReport(MID_A, undefined);
        assert.equal(JSON.stringify(reg.get(id)), before, 'absent power changed nothing');
    });

    test('ups:null with a valid source does NOT detach or delete an existing accessory', () => {
        const reg = acc.createRegistry({ file });
        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        reg.attach(id, MID_B);
        reg.upsertFromReport(MID_A, POWER('ac', null));
        reg.upsertFromReport(MID_A, POWER('ups', null));
        assert.equal(reg.size(), 1);
        assert.deepEqual(reg.get(id).attachedMachineIds, [MID_A, MID_B]);
        assert.equal(reg.get(id).lastReading.percent, 85, 'last good reading kept');
    });

    test('source "battery" laptop with no ups is not an accessory', () => {
        const reg = acc.createRegistry({ file });
        assert.equal(reg.upsertFromReport(MID_A, { source: 'battery', ups: null }), null);
        assert.equal(reg.size(), 0);
    });

    test('hostile machine ids / ups shapes are rejected, not stored', () => {
        const reg = acc.createRegistry({ file });
        for (const bad of [null, 42, '', '../etc', 'a'.repeat(200), { x: 1 }]) {
            assert.equal(reg.upsertFromReport(bad, POWER('ac')), null);
        }
        assert.equal(reg.upsertFromReport(MID_A, { source: 'ac', ups: { name: 7, id: 1 } }), null);
        assert.equal(reg.size(), 0);
    });

    test('registry is capped; existing accessories keep updating at the cap', () => {
        const reg = acc.createRegistry({ file });
        for (let i = 0; i < acc.MAX_ACCESSORIES; i++) reg.upsertFromReport(MID_A, POWER('ac', UPS({ name: `UPS-${i}` })));
        assert.equal(reg.size(), acc.MAX_ACCESSORIES);
        assert.equal(reg.upsertFromReport(MID_A, POWER('ac', UPS({ name: 'overflow' }))), null);
        assert.notEqual(reg.upsertFromReport(MID_A, POWER('ac', UPS({ name: 'UPS-0', percent: 1 }))), null);
    });

    test('creation persists immediately (survives a restart)', () => {
        const reg = acc.createRegistry({ file });
        reg.upsertFromReport(MID_A, POWER('ac'));
        assert.equal(acc.createRegistry({ file }).load().loaded, 1);
    });
});

// ===========================================================================
// 003 -- attachment API
// ===========================================================================
describe('003 attachment API', () => {
    const request = require('supertest');
    const express = require('express');
    const { registerAccessoriesRoutes } = require('../lib/accessories-routes');
    const FLEET = 'test-fleet-token-not-a-real-secret';
    const ADMIN = 'test-admin-token-not-a-real-secret';
    let app, reg, machines, saved;

    beforeEach(() => {
        saved = { f: process.env.FLEET_AUTH_TOKEN, a: process.env.FLEET_ADMIN_TOKEN };
        process.env.FLEET_AUTH_TOKEN = FLEET;
        process.env.FLEET_ADMIN_TOKEN = ADMIN;
        reg = acc.createRegistry({ file });
        machines = mapOf(machine(MID_A, 'online', POWER('ac')), machine(MID_B, 'online', POWER('ac', null)));
        app = express();
        app.use(express.json());
        registerAccessoriesRoutes(app, {
            registry: reg,
            refresh: () => reg.derive(machines),
            machineExists: (m) => machines.has(m),
        });
    });
    afterEach(() => {
        for (const [k, v] of [['FLEET_AUTH_TOKEN', saved.f], ['FLEET_ADMIN_TOKEN', saved.a]]) {
            if (v === undefined) delete process.env[k]; else process.env[k] = v;
        }
    });

    const adminH = { Authorization: `Bearer ${ADMIN}` };
    const fleetH = { Authorization: `Bearer ${FLEET}` };

    test('GET shape: {accessories:[...], total} with the documented keys', async () => {
        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        const res = await request(app).get('/api/accessories');
        assert.equal(res.status, 200);
        assert.equal(res.body.total, 1);
        const a = res.body.accessories[0];
        assert.equal(a.id, id);
        assert.deepEqual(Object.keys(a).sort(), ['attached_machine_ids', 'data_link_machine_id', 'display_name', 'history', 'id', 'last_reading', 'name', 'nickname', 'state', 'state_since', 'type']);
        assert.equal(a.state, 'ac');
        assert.deepEqual(a.attached_machine_ids, [MID_A]);
    });

    test('GET is open (same tier as /api/fleet): no credential needed', async () => {
        assert.equal((await request(app).get('/api/accessories')).status, 200);
    });

    test('unauthenticated PUT/DELETE/nickname are rejected (401), state unchanged', async () => {
        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        for (const [m, p] of [['put', `/api/accessories/${id}/machines/${MID_B}`], ['delete', `/api/accessories/${id}/machines/${MID_A}`], ['put', `/api/accessories/${id}/nickname`]]) {
            const res = await request(app)[m](p).send({ nickname: 'x' });
            assert.equal(res.status, 401, `${m} ${p}`);
        }
        assert.deepEqual(reg.get(id).attachedMachineIds, [MID_A]);
        assert.equal(reg.get(id).nickname, null);
    });

    test('the FLEET-tier key is rejected on the admin routes; the admin key is accepted', async () => {
        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        assert.equal((await request(app).put(`/api/accessories/${id}/machines/${MID_B}`).set(fleetH)).status, 401);
        const ok = await request(app).put(`/api/accessories/${id}/machines/${MID_B}`).set(adminH);
        assert.equal(ok.status, 200);
        assert.deepEqual(ok.body.accessory.attached_machine_ids, [MID_A, MID_B]);
    });

    test('PUT and DELETE are idempotent (changed flag), persisted', async () => {
        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        const p1 = await request(app).put(`/api/accessories/${id}/machines/${MID_B}`).set(adminH);
        const p2 = await request(app).put(`/api/accessories/${id}/machines/${MID_B}`).set(adminH);
        assert.equal(p1.body.changed, true);
        assert.equal(p2.status, 200);
        assert.equal(p2.body.changed, false);
        assert.deepEqual(reg.get(id).attachedMachineIds, [MID_A, MID_B]);
        const reloaded = acc.createRegistry({ file });
        reloaded.load();
        assert.deepEqual(reloaded.get(id).attachedMachineIds, [MID_A, MID_B], 'attachment saved');
        const d1 = await request(app).delete(`/api/accessories/${id}/machines/${MID_B}`).set(adminH);
        const d2 = await request(app).delete(`/api/accessories/${id}/machines/${MID_B}`).set(adminH);
        assert.equal(d1.body.changed, true);
        assert.equal(d2.status, 200);
        assert.equal(d2.body.changed, false);
        assert.deepEqual(reg.get(id).attachedMachineIds, [MID_A]);
    });

    test('unknown accessory -> 404 (PUT, DELETE, nickname); malformed ids -> 400', async () => {
        const ghost = 'acc_0123456789abcdef';
        assert.equal((await request(app).put(`/api/accessories/${ghost}/machines/${MID_A}`).set(adminH)).status, 404);
        assert.equal((await request(app).delete(`/api/accessories/${ghost}/machines/${MID_A}`).set(adminH)).status, 404);
        assert.equal((await request(app).put(`/api/accessories/${ghost}/nickname`).set(adminH).send({ nickname: 'x' })).status, 404);
        assert.equal((await request(app).put('/api/accessories/not-an-id/machines/' + MID_A).set(adminH)).status, 400);
        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        assert.equal((await request(app).put(`/api/accessories/${id}/machines/${encodeURIComponent('bad id!')}`).set(adminH)).status, 400);
    });

    test('attaching a machine the server has never seen -> 404; detaching one always works', async () => {
        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        assert.equal((await request(app).put(`/api/accessories/${id}/machines/never-seen-machine`).set(adminH)).status, 404);
        reg._records.get(id).attachedMachineIds.push('gone-machine');
        const res = await request(app).delete(`/api/accessories/${id}/machines/gone-machine`).set(adminH);
        assert.equal(res.status, 200);
        assert.equal(res.body.changed, true);
    });

    test('nickname: set, clear with null, reject overlong / control chars / non-strings', async () => {
        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        const set = await request(app).put(`/api/accessories/${id}/nickname`).set(adminH).send({ nickname: '  Desk UPS ' });
        assert.equal(set.body.accessory.nickname, 'Desk UPS');
        assert.equal(set.body.accessory.display_name, 'Desk UPS');
        const clr = await request(app).put(`/api/accessories/${id}/nickname`).set(adminH).send({ nickname: null });
        assert.equal(clr.body.accessory.nickname, null);
        assert.equal((await request(app).put(`/api/accessories/${id}/nickname`).set(adminH).send({ nickname: 'x'.repeat(65) })).status, 400);
        assert.equal((await request(app).put(`/api/accessories/${id}/nickname`).set(adminH).send({ nickname: 'a\u0007b' })).status, 400);
        assert.equal((await request(app).put(`/api/accessories/${id}/nickname`).set(adminH).send({ nickname: 5 })).status, 400);
    });
});

// ===========================================================================
// 004 -- derived state
// ===========================================================================
describe('004 derived state', () => {
    let reg, id, t;
    beforeEach(() => {
        t = Date.parse('2026-10-08T12:00:00Z');
        reg = acc.createRegistry({ file, now: () => new Date(t) });
        id = reg.upsertFromReport(MID_A, POWER('ac'));
        reg.attach(id, MID_B);
    });

    test('source "ups" on the online data-link host => on_battery; "ac" => ac', () => {
        let r = reg.derive(mapOf(machine(MID_A, 'online', POWER('ups')), machine(MID_B, 'online')));
        assert.equal(r.accessories[0].state, 'on_battery');
        r = reg.derive(mapOf(machine(MID_A, 'online', POWER('ac')), machine(MID_B, 'online')));
        assert.equal(r.accessories[0].state, 'ac');
    });

    test('source ups with ups:null (this UPS absent from the latest report) is unknown, not on_battery (XACA-1392-012)', () => {
        const r = reg.derive(mapOf(machine(MID_A, 'online', POWER('ups', null)), machine(MID_B, 'online')));
        assert.equal(r.accessories[0].state, 'unknown');
    });

    test('stale data-link host (warning / offline / missing) => unknown, attached machines NOT yellow on its account', () => {
        for (const status of ['warning', 'offline']) {
            const r = reg.derive(mapOf(machine(MID_A, status, POWER('ups')), machine(MID_B, 'online')));
            assert.equal(r.accessories[0].state, 'unknown', status);
            assert.equal(r.machines.get(MID_B).power_state, 'unknown');
            assert.equal(r.machines.get(MID_B).display_status, 'online', 'not forced yellow, not declared on_battery');
            assert.equal(r.machines.get(MID_B).power_reason, null);
        }
        const gone = reg.derive(mapOf(machine(MID_B, 'online')));
        assert.equal(gone.accessories[0].state, 'unknown');
    });

    test('power absent on the data-link host => unknown, NEVER ac', () => {
        const r = reg.derive(mapOf(machine(MID_A, 'online'), machine(MID_B, 'online')));
        assert.equal(r.accessories[0].state, 'unknown');
        assert.equal(r.machines.get(MID_B).power_state, 'unknown');
    });

    test('data-link host on "battery" (a laptop, not the UPS) => unknown', () => {
        const r = reg.derive(mapOf(machine(MID_A, 'online', POWER('battery', null)), machine(MID_B, 'online')));
        assert.equal(r.accessories[0].state, 'unknown');
    });

    test('per-machine power_state: any on_battery wins; else any unknown; else ac; null when unattached', () => {
        const MID_C = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
        const MID_D = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
        const id2 = reg.upsertFromReport(MID_C, POWER('ac', UPS({ id: 7 })));
        reg.attach(id2, MID_B);
        let r = reg.derive(mapOf(machine(MID_A, 'online', POWER('ups')), machine(MID_B, 'online'), machine(MID_C, 'online', POWER('ac')), machine(MID_D, 'online')));
        assert.equal(r.machines.get(MID_B).power_state, 'on_battery', 'attached to both; one is on battery');
        assert.equal(r.machines.get(MID_C).power_state, 'ac');
        assert.equal(r.machines.get(MID_D).power_state, null);
        r = reg.derive(mapOf(machine(MID_A, 'offline'), machine(MID_B, 'online'), machine(MID_C, 'online', POWER('ac'))));
        assert.equal(r.machines.get(MID_B).power_state, 'unknown', 'one ac + one unknown => unknown');
    });

    test('precedence: offline > on_battery > warning > online (with explicit reason)', () => {
        const up = POWER('ups');
        let r = reg.derive(mapOf(machine(MID_A, 'online', up), machine(MID_B, 'online')));
        let b = r.machines.get(MID_B);
        assert.equal(b.display_status, 'on_battery');
        assert.deepEqual(b.power_reason, { accessory_id: id, accessory_name: 'Back-UPS ES 600M1', percent: 85, minutes_remaining: 40 });
        r = reg.derive(mapOf(machine(MID_A, 'online', up), machine(MID_B, 'warning')));
        assert.equal(r.machines.get(MID_B).display_status, 'on_battery', 'on_battery beats heartbeat warning');
        r = reg.derive(mapOf(machine(MID_A, 'online', up), machine(MID_B, 'offline')));
        b = r.machines.get(MID_B);
        assert.equal(b.display_status, 'offline', 'offline beats on_battery');
        assert.equal(b.power_reason, null);
        assert.equal(b.power_state, 'on_battery', 'the fact is kept; only the display yields to RED');
        r = reg.derive(mapOf(machine(MID_A, 'online', POWER('ac')), machine(MID_B, 'warning')));
        assert.equal(r.machines.get(MID_B).display_status, 'warning');
        r = reg.derive(mapOf(machine(MID_A, 'online', POWER('ac')), machine(MID_B, 'online')));
        assert.equal(r.machines.get(MID_B).display_status, 'online');
    });

    test('display_status for a machine with no accessory equals its heartbeat status', () => {
        const E = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
        for (const st of ['online', 'warning', 'offline']) {
            const r = reg.derive(mapOf(machine(E, st)));
            assert.equal(r.machines.get(E).display_status, st);
        }
    });

    test('transitions are recorded once each, newest first, and fire onTransition', () => {
        const seen = [];
        const hooks = { onTransition: (rec, from, to) => seen.push([from, to]) };
        reg.derive(mapOf(machine(MID_A, 'online', POWER('ac')), machine(MID_B, 'online')), hooks);
        t += 60000;
        reg.derive(mapOf(machine(MID_A, 'online', POWER('ac')), machine(MID_B, 'online')), hooks);
        t += 60000;
        reg.derive(mapOf(machine(MID_A, 'online', POWER('ups')), machine(MID_B, 'online')), hooks);
        assert.deepEqual(seen, [['unknown', 'ac'], ['ac', 'on_battery']]);
        const h = reg.get(id).history;
        assert.equal(h.length, 2);
        assert.deepEqual([h[0].from, h[0].to], ['ac', 'on_battery']);
        assert.equal(h[0].at, new Date(t).toISOString());
        assert.equal(reg.get(id).stateSince, new Date(t).toISOString());
    });

    test('transition history is bounded', () => {
        for (let i = 0; i < acc.MAX_HISTORY * 2 + 3; i++) {
            t += 1000;
            reg.derive(mapOf(machine(MID_A, 'online', POWER(i % 2 ? 'ac' : 'ups')), machine(MID_B, 'online')));
        }
        assert.equal(reg.get(id).history.length, acc.MAX_HISTORY);
    });

    test('a throwing onTransition hook cannot break derivation', () => {
        const r = reg.derive(mapOf(machine(MID_A, 'online', POWER('ac')), machine(MID_B, 'online')), { onTransition() { throw new Error('boom'); } });
        assert.equal(r.accessories[0].state, 'ac');
    });

    test('derived state and history survive a restart', () => {
        reg.derive(mapOf(machine(MID_A, 'online', POWER('ups')), machine(MID_B, 'online')));
        const reg2 = acc.createRegistry({ file });
        reg2.load();
        assert.equal(reg2.get(id).state, 'on_battery');
        assert.equal(reg2.get(id).history.length, 1);
    });
});

// ===========================================================================
// 005 -- wiring into server.js (it cannot be require()d: static checks of the call sites)
// ===========================================================================
describe('005 server.js wiring', () => {
    const src = fs.readFileSync(path.join(SERVER_DIR, 'server.js'), 'utf8');

    test('registry is loaded at startup from the injectable path', () => {
        assert.match(src, /createAccessoryRegistry\(\{[\s\S]*?FLEET_ACCESSORIES_FILE/);
        assert.match(src, /accessoryRegistry\.load\(\)/);
    });

    test('POST /api/status upserts from the STORED (sanitized) power block, after machines.set', () => {
        const post = src.slice(src.indexOf("app.post('/api/status'"));
        const iSet = post.indexOf('machines.set(machineKey');
        const iUpsert = post.indexOf('accessoryRegistry.upsertFromReport(machineKey, storedPower)');
        const iRes = post.indexOf('res.status(200)');
        assert.ok(iSet > 0 && iUpsert > iSet && iRes > iUpsert);
        assert.match(post, /machines\.get\(machineKey\)\.system\.power/);
    });

    test('parseFleetData derives AFTER updateMachineStatuses and exposes additive keys', () => {
        const fn = src.slice(src.indexOf('function parseFleetData()'), src.indexOf('function deriveAccessoryState()'));
        assert.ok(fn.indexOf('updateMachineStatuses()') < fn.indexOf('deriveAccessoryState()'));
        for (const k of ['power_state:', 'display_status:', 'power_reason:', 'accessories: power.accessories']) assert.ok(fn.includes(k), k);
        assert.match(fn, /status: m\.status,/, 'status keeps its heartbeat meaning');
    });

    test('/api/machines/list carries display_status + power_state; routes are registered', () => {
        const list = src.slice(src.indexOf("app.get('/api/machines/list'"));
        assert.match(list.slice(0, 900), /display_status: m\.display_status/);
        assert.match(list.slice(0, 900), /power_state: m\.power_state/);
        assert.match(src, /registerAccessoriesRoutes\(app, \{/);
    });

    test('dirty accessories are flushed on the save interval and on SIGTERM/SIGINT', () => {
        assert.ok((src.match(/accessoryRegistry\.flushIfDirty\(\)/g) || []).length >= 3);
    });
});

// ===========================================================================
// XACA-1392-012 [Blocking] -- state counts only when the host's LATEST report still contains THIS UPS
// ===========================================================================
describe('012 latest report must contain this UPS', () => {
    const NAME = 'Back-UPS ES 600M1';
    const OTHER = 'Some Other UPS';
    // Row: how the host's latest report presents the UPS x the reported source.
    const presence = {
        'same name':       (src) => ({ source: src, ups: UPS({ name: NAME }) }),
        'ups:null':        (src) => ({ source: src, ups: null }),
        'power absent':    () => undefined,
        'different name':  (src) => ({ source: src, ups: UPS({ name: OTHER }) }),
    };
    // Expected accessory state for [presence][source].
    const expected = {
        'same name':      { ac: 'ac', ups: 'on_battery', battery: 'unknown' },
        'ups:null':       { ac: 'unknown', ups: 'unknown', battery: 'unknown' },
        'power absent':   { ac: 'unknown', ups: 'unknown', battery: 'unknown' },
        'different name': { ac: 'unknown', ups: 'unknown', battery: 'unknown' },
    };
    for (const [pname, build] of Object.entries(presence)) {
        for (const src of ['ac', 'ups', 'battery']) {
            test(`${pname} x source ${src} => accessory ${expected[pname][src]}`, () => {
                const reg = acc.createRegistry({ file });
                const id = reg.upsertFromReport(MID_A, POWER('ac', UPS({ name: NAME })));
                reg.attach(id, MID_B);
                const r = reg.derive(mapOf(machine(MID_A, 'online', build(src)), machine(MID_B, 'online')));
                const want = expected[pname][src];
                assert.equal(r.accessories[0].state, want);
                const b = r.machines.get(MID_B);
                if (want === 'on_battery') {
                    assert.equal(b.power_state, 'on_battery');
                    assert.equal(b.display_status, 'on_battery');
                    assert.ok(b.power_reason);
                } else {
                    assert.equal(b.power_state, want);
                    assert.equal(b.display_status, 'online', 'heartbeat-online only; never on_battery');
                    assert.equal(b.power_reason, null);
                }
            });
        }
    }

    test('exact repro: on_battery, then a link-lost report (source ac, ups:null) => unknown, NOT green on power grounds', () => {
        const reg = acc.createRegistry({ file });
        const id = reg.upsertFromReport(MID_A, POWER('ups'));
        reg.attach(id, MID_B);
        let r = reg.derive(mapOf(machine(MID_A, 'online', POWER('ups')), machine(MID_B, 'online')));
        assert.equal(r.accessories[0].state, 'on_battery');
        assert.equal(r.machines.get(MID_B).power_state, 'on_battery');
        // link lost: the reporter now says AC with no UPS. The upsert side is a no-op...
        assert.equal(reg.upsertFromReport(MID_A, { source: 'ac', ups: null }), null);
        assert.equal(reg.size(), 1, 'not deleted');
        assert.deepEqual(reg.get(id).attachedMachineIds, [MID_A, MID_B], 'not detached');
        // ...and the DERIVED state degrades to unknown.
        r = reg.derive(mapOf(machine(MID_A, 'online', { source: 'ac', ups: null }), machine(MID_B, 'online')));
        assert.equal(r.accessories[0].state, 'unknown');
        const b = r.machines.get(MID_B);
        assert.equal(b.power_state, 'unknown');
        assert.notEqual(b.power_state, 'ac', 'must not read as AC');
        assert.equal(b.power_reason, null);
        // history shows on_battery -> unknown, never on_battery -> ac
        assert.deepEqual([reg.get(id).history[0].from, reg.get(id).history[0].to], ['on_battery', 'unknown']);
        // link restored with the same UPS => back to on_battery
        r = reg.derive(mapOf(machine(MID_A, 'online', POWER('ups')), machine(MID_B, 'online')));
        assert.equal(r.accessories[0].state, 'on_battery');
    });

    test('restart with no new report: persisted host record re-derives sanely; an aged (offline) host is unknown', () => {
        const reg = acc.createRegistry({ file });
        const id = reg.upsertFromReport(MID_A, POWER('ups'));
        reg.derive(mapOf(machine(MID_A, 'online', POWER('ups'))));
        const reg2 = acc.createRegistry({ file });
        reg2.load();
        assert.equal(reg2.get(id).state, 'on_battery', 'persisted reading kept until re-derived');
        const r = reg2.derive(mapOf(machine(MID_A, 'offline', POWER('ups'))));
        assert.equal(r.accessories[0].state, 'unknown');
    });
});

// ===========================================================================
// XACA-1392-013 [Advisory] -- reads do not write
// ===========================================================================
describe('013 reads do not flush', () => {
    test('derive() with no state transition after a heartbeat does not write accessories.json', () => {
        const reg = acc.createRegistry({ file });
        reg.upsertFromReport(MID_A, POWER('ac', UPS({ percent: 85 })));       // creation flushes
        reg.derive(mapOf(machine(MID_A, 'online', POWER('ac'))));             // unknown -> ac: a transition, flushes
        const onDisk = () => JSON.parse(fs.readFileSync(file, 'utf8')).accessories;
        const pct = () => Object.values(onDisk())[0].lastReading.percent;
        assert.equal(pct(), 85);

        let writes = 0;
        const realWrite = fs.writeFileSync;
        fs.writeFileSync = function (...a) { writes++; return realWrite.apply(this, a); };
        try {
            reg.upsertFromReport(MID_A, POWER('ac', UPS({ percent: 70 })));   // heartbeat: dirty only
            for (let i = 0; i < 3; i++) reg.derive(mapOf(machine(MID_A, 'online', POWER('ac')))); // /api/fleet reads
            assert.equal(writes, 0, 'reads wrote the file');
            assert.equal(pct(), 85, 'disk still holds the last flushed reading');
            assert.equal(reg.flushIfDirty(), true);                           // the 30 s interval / shutdown
            assert.equal(writes, 1);
            assert.equal(pct(), 70);
            assert.equal(reg.flushIfDirty(), true);
            assert.equal(writes, 1, 'clean registry does not write');
        } finally { fs.writeFileSync = realWrite; }
    });

    test('a state transition read DOES flush immediately (and carries the pending reading)', () => {
        const reg = acc.createRegistry({ file });
        reg.upsertFromReport(MID_A, POWER('ac', UPS({ percent: 85 })));
        reg.derive(mapOf(machine(MID_A, 'online', POWER('ac'))));
        reg.upsertFromReport(MID_A, POWER('ups', UPS({ percent: 60 })));
        reg.derive(mapOf(machine(MID_A, 'online', POWER('ups'))));           // ac -> on_battery
        const rec = Object.values(JSON.parse(fs.readFileSync(file, 'utf8')).accessories)[0];
        assert.equal(rec.state, 'on_battery');
        assert.equal(rec.lastReading.percent, 60);
    });
});
