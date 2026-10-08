//
//  xaca-1392-006-adversarial.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1392-006 -- independent adversarial coverage of the accessory registry.
 * Every test uses a private mkdtemp dir; the real server/data/ is never touched.
 */

const { test, describe, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const request = require('supertest');
const express = require('express');

const acc = require('../lib/accessories');
const { registerAccessoriesRoutes } = require('../lib/accessories-routes');

const SERVER_JS = fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8');

let tmp;
let file;
beforeEach(() => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1392-006-'));
    file = path.join(tmp, 'data', 'accessories.json');
});
afterEach(() => { fs.rmSync(tmp, { recursive: true, force: true }); });

const MID_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; // data-link host
const MID_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; // attached
const MID_C = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

const UPS = (over) => Object.assign({ name: 'CP1500PFCLCDa', id: 19333121, percent: 85, charging: false, minutes_remaining: 40, present: true }, over || {});
const POWER = (source, ups) => ({ source, ups: ups === undefined ? UPS() : ups });
const machine = (id, status, power) => ({ machine_id: id, hostname: `h-${id.slice(0, 4)}`, status, system: power === undefined ? {} : { power } });
const mapOf = (...ms) => new Map(ms.map((m) => [m.machine_id, m]));
const writeRaw = (body) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, body); };

describe('1 stale data-link host', () => {
    test('host was on_battery, then goes stale (warning, offline, vanished): accessory unknown, attached machines not on_battery', () => {
        for (const stale of ['warning', 'offline', 'gone']) {
            const reg = acc.createRegistry({ file: path.join(tmp, `s-${stale}.json`) });
            const id = reg.upsertFromReport(MID_A, POWER('ups'));
            reg.attach(id, MID_B);
            let r = reg.derive(mapOf(machine(MID_A, 'online', POWER('ups')), machine(MID_B, 'online')));
            assert.equal(r.machines.get(MID_B).display_status, 'on_battery');
            const hostRec = stale === 'gone' ? null : machine(MID_A, stale, POWER('ups')); // stale record still CARRIES source ups
            r = reg.derive(mapOf(...[hostRec, machine(MID_B, 'online')].filter(Boolean)));
            assert.equal(r.accessories[0].state, 'unknown', stale);
            assert.equal(r.machines.get(MID_B).power_state, 'unknown', stale);
            assert.equal(r.machines.get(MID_B).display_status, 'online', stale);
            assert.equal(r.machines.get(MID_B).power_reason, null, stale);
            assert.equal(r.accessories[0].history[0].from, 'on_battery');
            assert.equal(r.accessories[0].history[0].to, 'unknown');
        }
    });
});

describe('2 precedence', () => {
    let reg, id;
    beforeEach(() => {
        reg = acc.createRegistry({ file });
        id = reg.upsertFromReport(MID_A, POWER('ac'));
        reg.attach(id, MID_B);
    });
    const disp = (bStatus, hostSource) =>
        reg.derive(mapOf(machine(MID_A, 'online', POWER(hostSource)), machine(MID_B, bStatus))).machines.get(MID_B);

    test('offline + on_battery -> offline, power_state still on_battery, no reason shown', () => {
        const m = disp('offline', 'ups');
        assert.equal(m.display_status, 'offline');
        assert.equal(m.power_state, 'on_battery');
        assert.equal(m.power_reason, null);
    });
    test('warning + on_battery -> on_battery with reason', () => {
        const m = disp('warning', 'ups');
        assert.equal(m.display_status, 'on_battery');
        assert.equal(m.power_reason.accessory_id, id);
    });
    test('warning + ac -> warning; online + ac -> online; online + on_battery -> on_battery', () => {
        assert.equal(disp('warning', 'ac').display_status, 'warning');
        assert.equal(disp('online', 'ac').display_status, 'online');
        assert.equal(disp('online', 'ups').display_status, 'on_battery');
    });
    test('offline + ac -> offline', () => {
        assert.equal(disp('offline', 'ac').display_status, 'offline');
    });
    test('derive never mutates the machine records (status keeps heartbeat meaning)', () => {
        const ms = mapOf(machine(MID_A, 'online', POWER('ups')), machine(MID_B, 'warning'));
        const before = JSON.stringify([...ms.values()]);
        reg.derive(ms);
        assert.equal(JSON.stringify([...ms.values()]), before);
    });
});

describe('3 volatile ups.id', () => {
    test('id changes across reports: one accessory, attachments/nickname/history preserved, persisted', () => {
        let t = Date.parse('2026-10-08T12:00:00Z');
        const reg = acc.createRegistry({ file, now: () => new Date(t++) });
        const id = reg.upsertFromReport(MID_A, POWER('ac', UPS({ id: 19333121 })));
        reg.attach(id, MID_B);
        reg.setNickname(id, 'Rack UPS');
        reg.derive(mapOf(machine(MID_A, 'online', POWER('ups')), machine(MID_B, 'online')));
        const hist = reg.get(id).history.length;
        assert.ok(hist >= 1);
        for (const newId of [53280768, '53280768', 0, 7]) {
            assert.equal(reg.upsertFromReport(MID_A, POWER('ac', UPS({ id: newId }))), id);
        }
        assert.equal(reg.size(), 1);
        const rec = reg.get(id);
        assert.equal(rec.upsId, '7');
        assert.equal(rec.nickname, 'Rack UPS');
        assert.deepEqual(rec.attachedMachineIds, [MID_A, MID_B]);
        assert.equal(rec.history.length, hist);
        const reg2 = acc.createRegistry({ file });
        reg2.load();
        assert.equal(reg2.get(id).upsId, '7');
        assert.equal(reg2.get(id).nickname, 'Rack UPS');
    });
});

describe('4 no-ops', () => {
    test('ups:null (each valid source) and absent power: no create, no detach, no state change, no write', () => {
        const reg = acc.createRegistry({ file });
        for (const p of [POWER('ac', null), POWER('ups', null), POWER('battery', null), null, undefined, {}, 'x', 5, []]) {
            assert.equal(reg.upsertFromReport(MID_A, p), null);
        }
        assert.equal(reg.size(), 0);
        assert.equal(fs.existsSync(file), false);

        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        reg.attach(id, MID_B);
        reg.detach(id, MID_A);
        reg.derive(mapOf(machine(MID_A, 'online', POWER('ups')), machine(MID_B, 'online')));
        const before = JSON.stringify(reg.get(id));
        for (const p of [POWER('ac', null), POWER('ups', null), null, undefined, {}]) reg.upsertFromReport(MID_A, p);
        assert.equal(JSON.stringify(reg.get(id)), before);
        assert.deepEqual(reg.get(id).attachedMachineIds, [MID_B]);
        assert.equal(reg.get(id).state, 'on_battery');
    });
});

describe('5 persistence', () => {
    test('empty, whitespace, truncated, wrong-type files load as empty without throwing', () => {
        const bodies = ['', '   \n', '{"schemaVersion":1,"accessories":{"acc_', '{"accessories":[]}', '{"accessories":null}',
            '{"accessories":"x"}', '[1,2]', '123', 'true', '\u0000\u0000', '{"accessories":{}}x'];
        for (const body of bodies) {
            fs.rmSync(path.dirname(file), { recursive: true, force: true });
            writeRaw(body);
            const reg = acc.createRegistry({ file });
            let r;
            assert.doesNotThrow(() => { r = reg.load(); }, JSON.stringify(body));
            assert.equal(reg.size(), 0, JSON.stringify(body));
            assert.ok(['corrupt', 'ok'].includes(r.status), JSON.stringify(body));
        }
    });

    test('a directory sitting at the file path (unreadable) loads empty, does not throw', () => {
        fs.mkdirSync(file, { recursive: true });
        const reg = acc.createRegistry({ file });
        assert.doesNotThrow(() => reg.load());
        assert.equal(reg.size(), 0);
    });

    test('records whose id does not match machine+name are rejected; tampered name/machine too', () => {
        const id = acc.accessoryId(MID_A, 'UPS-1');
        const good = { type: 'ups', dataLinkMachineId: MID_A, upsId: '1', name: 'UPS-1' };
        writeRaw(JSON.stringify({ schemaVersion: 1, accessories: {
            [id]: good,
            [acc.accessoryId(MID_A, 'UPS-2')]: Object.assign({}, good),
            [acc.accessoryId(MID_B, 'UPS-1')]: Object.assign({}, good),
            'acc_0000000000000000': Object.assign({}, good),
            'ACC_0000000000000000': Object.assign({}, good),
            [id.toUpperCase()]: Object.assign({}, good),
            '__proto__': Object.assign({}, good),
            'constructor': Object.assign({}, good),
        } }));
        const reg = acc.createRegistry({ file });
        const r = reg.load();
        assert.equal(r.loaded, 1);
        assert.deepEqual(reg.list().map((x) => x.id), [id]);
        assert.equal(Object.getPrototypeOf({}), Object.prototype);
        assert.equal({}.name, undefined);
    });

    test('hostile persisted fields are clamped: attachments, history, nickname, state', () => {
        const id = acc.accessoryId(MID_A, 'U');
        writeRaw(JSON.stringify({ schemaVersion: 1, accessories: { [id]: {
            type: 'ups', dataLinkMachineId: MID_A, upsId: '1', name: 'U',
            attachedMachineIds: Array.from({ length: 500 }, (_, i) => `m${i}`).concat(['../x', '', 5, null, '__proto__', 'a b']),
            history: Array.from({ length: 500 }, () => ({ at: 'x', from: 'ac', to: 'on_battery' })).concat([{ at: 'x', to: 'bogus' }, null, 'x']),
            nickname: 'n'.repeat(500), state: 'exploded', lastReading: { source: 'evil', percent: 1.5, charging: 'yes' },
        } } }));
        const reg = acc.createRegistry({ file });
        reg.load();
        const r = reg.get(id);
        assert.equal(r.attachedMachineIds.length, acc.MAX_ATTACHED);
        assert.ok(r.attachedMachineIds.every((m) => acc.MACHINE_ID_RE.test(m)));
        assert.equal(r.history.length, acc.MAX_HISTORY);
        assert.equal(r.nickname.length, acc.NICKNAME_MAX);
        assert.equal(r.state, 'unknown');
        assert.deepEqual(r.lastReading, { source: null, percent: null, charging: null, minutes_remaining: null, present: null, observedAt: null });
    });

    test('successful saves leave only accessories.json (no .tmp-*), across many saves', () => {
        const reg = acc.createRegistry({ file });
        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        for (let i = 0; i < 20; i++) { reg.setNickname(id, `n${i}`); reg.attach(id, `m${i}`); }
        assert.equal(reg.save(), true);
        assert.deepEqual(fs.readdirSync(path.dirname(file)), ['accessories.json']);
        JSON.parse(fs.readFileSync(file, 'utf8'));
    });

    test('a failing write (rename onto a directory) removes its temp file and keeps the registry in memory', () => {
        const reg = acc.createRegistry({ file });
        reg.upsertFromReport(MID_A, POWER('ac'));
        fs.rmSync(file);
        fs.mkdirSync(file); // rename onto a directory fails
        assert.equal(reg.save(), false);
        assert.equal(reg.size(), 1);
        assert.deepEqual(fs.readdirSync(path.dirname(file)), ['accessories.json']);
    });

    test('corrupt file is preserved aside and the new registry then saves a clean file', () => {
        writeRaw('{broken');
        const reg = acc.createRegistry({ file });
        reg.load();
        reg.upsertFromReport(MID_A, POWER('ac'));
        const names = fs.readdirSync(path.dirname(file));
        assert.ok(names.includes('accessories.json'));
        assert.equal(names.filter((n) => n.startsWith('accessories.json.corrupt-')).length, 1);
    });
});

describe('6 auth + path ids', () => {
    const FLEET = 'test-fleet-token-not-a-real-secret';
    const ADMIN = 'test-admin-token-not-a-real-secret';
    let app, reg, saved, id;
    beforeEach(() => {
        saved = { f: process.env.FLEET_AUTH_TOKEN, a: process.env.FLEET_ADMIN_TOKEN };
        process.env.FLEET_AUTH_TOKEN = FLEET;
        process.env.FLEET_ADMIN_TOKEN = ADMIN;
        reg = acc.createRegistry({ file });
        const machines = mapOf(machine(MID_A, 'online', POWER('ac')), machine(MID_B, 'online'));
        id = reg.upsertFromReport(MID_A, POWER('ac'));
        app = express();
        app.use(express.json());
        registerAccessoriesRoutes(app, { registry: reg, refresh: () => reg.derive(machines), machineExists: (m) => machines.has(m) });
    });
    afterEach(() => {
        for (const [k, v] of [['FLEET_AUTH_TOKEN', saved.f], ['FLEET_ADMIN_TOKEN', saved.a]]) {
            if (v === undefined) delete process.env[k]; else process.env[k] = v;
        }
    });
    const bearer = (t) => ({ Authorization: `Bearer ${t}` });

    test('no credential / fleet key / wrong key / other schemes: 401 or 403 on every mutation, state untouched', async () => {
        const calls = [
            (h) => request(app).put(`/api/accessories/${id}/machines/${MID_B}`).set(h),
            (h) => request(app).delete(`/api/accessories/${id}/machines/${MID_A}`).set(h),
            (h) => request(app).put(`/api/accessories/${id}/nickname`).set(h).send({ nickname: 'x' }),
        ];
        const before = JSON.stringify(reg.get(id));
        for (const call of calls) {
            for (const h of [{}, bearer(FLEET), bearer('nope'), { Authorization: 'Basic abc' }, { 'X-API-Key': FLEET }]) {
                const res = await call(h);
                assert.ok([401, 403].includes(res.status), `${res.status} ${JSON.stringify(h)}`);
            }
        }
        assert.equal(JSON.stringify(reg.get(id)), before);
    });

    test('admin key succeeds on all three', async () => {
        assert.equal((await request(app).put(`/api/accessories/${id}/machines/${MID_B}`).set(bearer(ADMIN))).status, 200);
        assert.equal((await request(app).put(`/api/accessories/${id}/nickname`).set(bearer(ADMIN)).send({ nickname: 'ok' })).status, 200);
        assert.equal((await request(app).delete(`/api/accessories/${id}/machines/${MID_B}`).set(bearer(ADMIN))).status, 200);
    });

    test('traversal / garbage ids -> 400 (never 200, never 500); nothing mutated', async () => {
        const before = JSON.stringify(reg.get(id));
        const garbage = ['..%2F..%2Fetc', 'acc_zzzzzzzzzzzzzzzz', 'acc_0123', `${id}x`, id.toUpperCase(), 'a%20b', '__proto__', 'constructor'];
        for (const g of garbage) {
            for (const res of [
                await request(app).put(`/api/accessories/${g}/machines/${MID_B}`).set(bearer(ADMIN)),
                await request(app).delete(`/api/accessories/${g}/machines/${MID_B}`).set(bearer(ADMIN)),
                await request(app).put(`/api/accessories/${g}/nickname`).set(bearer(ADMIN)).send({ nickname: 'x' }),
            ]) assert.equal(res.status, 400, g);
        }
        for (const g of ['..%2F..%2Fetc', 'a%20b', '__proto__', '.hidden']) {
            const res = await request(app).put(`/api/accessories/${id}/machines/${g}`).set(bearer(ADMIN));
            assert.equal(res.status, 400, g);
            assert.equal((await request(app).delete(`/api/accessories/${id}/machines/${g}`).set(bearer(ADMIN))).status, 400, g);
        }
        assert.equal(JSON.stringify(reg.get(id)), before);
    });

    test('malformed percent-encoding in the path never yields a 500', async () => {
        for (const g of ['%00', '%', '%E0%A4%A', '%2e%2e']) { // %2e%2e is URL-normalised to '..' client-side -> route miss (404)
            const res = await request(app).put(`/api/accessories/${g}/nickname`).set(bearer(ADMIN)).send({ nickname: 'x' });
            assert.ok(res.status >= 400 && res.status < 500, `${g} -> ${res.status}`);
        }
    });

    test('unknown (well-formed) accessory -> 404 on all three; unknown machine attach -> 404', async () => {
        const ghost = acc.accessoryId(MID_C, 'ghost');
        assert.equal((await request(app).put(`/api/accessories/${ghost}/machines/${MID_B}`).set(bearer(ADMIN))).status, 404);
        assert.equal((await request(app).delete(`/api/accessories/${ghost}/machines/${MID_B}`).set(bearer(ADMIN))).status, 404);
        assert.equal((await request(app).put(`/api/accessories/${ghost}/nickname`).set(bearer(ADMIN)).send({ nickname: 'x' })).status, 404);
        assert.equal((await request(app).put(`/api/accessories/${id}/machines/${MID_C}`).set(bearer(ADMIN))).status, 404);
    });

    test('nickname bodies: missing body, array, number, object, __proto__ key, prototype-ish strings', async () => {
        const put = (b) => request(app).put(`/api/accessories/${id}/nickname`).set(bearer(ADMIN)).send(b);
        assert.equal((await request(app).put(`/api/accessories/${id}/nickname`).set(bearer(ADMIN))).status, 200); // no body clears
        for (const b of [{ nickname: 5 }, { nickname: ['a'] }, { nickname: { a: 1 } }, { nickname: true }, { nickname: 'x'.repeat(65) }, { nickname: 'a\nb' }]) {
            assert.equal((await put(b)).status, 400, JSON.stringify(b));
        }
        for (const n of ['__proto__', 'constructor', 'toString', '  padded  ', 'é中文😀']) {
            const res = await put({ nickname: n });
            assert.equal(res.status, 200, n);
            assert.equal(res.body.accessory.nickname, n.trim());
        }
        const polluted = await request(app).put(`/api/accessories/${id}/nickname`).set(bearer(ADMIN))
            .set('Content-Type', 'application/json').send('{"__proto__":{"polluted":1},"nickname":"ok"}');
        assert.equal(polluted.status, 200);
        assert.equal({}.polluted, undefined);
    });

    test('GET stays open and returns 200 with a well-formed body', async () => {
        const res = await request(app).get('/api/accessories');
        assert.equal(res.status, 200);
        assert.equal(res.body.total, 1);
    });
});

describe('7 caps', () => {
    test('256 accessories: overflow dropped, existing keep updating, restart reloads exactly 256', () => {
        const reg = acc.createRegistry({ file });
        for (let i = 0; i < acc.MAX_ACCESSORIES + 50; i++) reg.upsertFromReport(MID_A, POWER('ac', UPS({ name: `ups-${i}` })));
        assert.equal(reg.size(), acc.MAX_ACCESSORIES);
        assert.equal(reg.upsertFromReport(MID_A, POWER('ac', UPS({ name: 'ups-0', percent: 11 }))), acc.accessoryId(MID_A, 'ups-0'));
        assert.equal(reg.get(acc.accessoryId(MID_A, 'ups-0')).lastReading.percent, 11);
        assert.equal(reg.upsertFromReport(MID_B, POWER('ac', UPS({ name: 'other-host' }))), null);
        reg.save();
        const reg2 = acc.createRegistry({ file });
        assert.equal(reg2.load().loaded, acc.MAX_ACCESSORIES);
    });

    test('64 attached: 65th attach -> full; duplicates do not consume slots', () => {
        const reg = acc.createRegistry({ file });
        const id = reg.upsertFromReport(MID_A, POWER('ac')); // 1 attached (host)
        for (let i = 0; i < acc.MAX_ATTACHED - 1; i++) assert.equal(reg.attach(id, `m${i}`).ok, true);
        assert.equal(reg.get(id).attachedMachineIds.length, acc.MAX_ATTACHED);
        assert.deepEqual(reg.attach(id, 'm0'), { ok: true, changed: false });
        assert.deepEqual(reg.attach(id, 'overflow'), { ok: false, code: 'full' });
        assert.equal(reg.get(id).attachedMachineIds.length, acc.MAX_ATTACHED);
    });

    test('history holds at 50 under 500 flaps, newest first; view() agrees', () => {
        let t = Date.parse('2026-10-08T00:00:00Z');
        const reg = acc.createRegistry({ file, now: () => new Date(t += 1000) });
        const id = reg.upsertFromReport(MID_A, POWER('ac'));
        let last;
        for (let i = 0; i < 500; i++) last = reg.derive(mapOf(machine(MID_A, 'online', POWER(i % 2 ? 'ac' : 'ups'))));
        assert.equal(reg.get(id).history.length, acc.MAX_HISTORY);
        assert.equal(last.accessories[0].history.length, acc.MAX_HISTORY);
        assert.ok(reg.get(id).history[0].at > reg.get(id).history[49].at);
        const reg2 = acc.createRegistry({ file }); reg2.load();
        assert.ok(reg2.get(id).history.length <= acc.MAX_HISTORY);
    });
});

describe('8 hostile input', () => {
    test('names differing only by case are distinct, deterministic accessories', () => {
        const reg = acc.createRegistry({ file });
        const a = reg.upsertFromReport(MID_A, POWER('ac', UPS({ name: 'APC' })));
        const b = reg.upsertFromReport(MID_A, POWER('ac', UPS({ name: 'apc' })));
        assert.notEqual(a, b);
        assert.equal(reg.upsertFromReport(MID_A, POWER('ac', UPS({ name: 'APC' }))), a);
        assert.equal(reg.size(), 2);
    });

    test('unicode, emoji, max-length (64), whitespace-only, RTL names round-trip through save/load', () => {
        const names = ['ÜPS é', '中文UPS', '🔋'.repeat(32), 'x'.repeat(64), ' ', '‮evil', 'á'];
        const reg = acc.createRegistry({ file });
        const ids = names.map((n) => reg.upsertFromReport(MID_A, POWER('ac', UPS({ name: n }))));
        assert.ok(ids.every(Boolean));
        assert.equal(new Set(ids).size, names.length);
        reg.save();
        const reg2 = acc.createRegistry({ file });
        const r = reg2.load();
        assert.equal(r.loaded, names.length, `skipped=${r.skipped}`);
        for (const [i, n] of names.entries()) assert.equal(reg2.get(ids[i]).name, n);
    });

    test('prototype-ish machine ids and ups names never touch Object.prototype and never crash', () => {
        const reg = acc.createRegistry({ file });
        for (const m of ['constructor', 'toString', 'hasOwnProperty', 'valueOf', 'a__proto__']) {
            const id = reg.upsertFromReport(m, POWER('ac', UPS({ name: '__proto__' })));
            assert.ok(id, m);
            reg.attach(id, 'constructor');
            reg.derive(mapOf(machine(m, 'online', POWER('ups')), machine('constructor', 'online')));
        }
        for (const m of ['__proto__', '_x', '', 'a/b', '..', 'a b', 'x'.repeat(129), 5, null, undefined, {}]) {
            assert.equal(reg.upsertFromReport(m, POWER('ac')), null, String(m));
        }
        assert.equal({}.polluted, undefined);
        assert.equal(Object.keys(Object.prototype).length, 0);
        reg.save();
        const reg2 = acc.createRegistry({ file });
        assert.equal(reg2.load().loaded, 5);
    });

    test('derive tolerates garbage machine records (null system, missing status, wrong-type power)', () => {
        const reg = acc.createRegistry({ file });
        reg.upsertFromReport(MID_A, POWER('ac'));
        for (const m of [
            { machine_id: MID_A, status: 'online' },
            { machine_id: MID_A, status: 'online', system: null },
            { machine_id: MID_A, status: 'online', system: { power: 'ups' } },
            { machine_id: MID_A, status: 'online', system: { power: { source: ['ups'] } } },
            { machine_id: MID_A, status: 'online', system: { power: { source: '__proto__' } } },
        ]) {
            const r = reg.derive(new Map([[MID_A, m]]));
            assert.equal(r.accessories[0].state, 'unknown', JSON.stringify(m));
        }
        assert.doesNotThrow(() => reg.derive(new Map()));
    });

    test('REGRESSION: names over 64 chars are refused at upsert and at load, never truncated under a mismatched id', () => {
        const reg0 = acc.createRegistry({ file });
        assert.equal(reg0.upsertFromReport(MID_A, POWER('ac', UPS({ name: 'n'.repeat(65) }))), null);
        assert.equal(reg0.upsertFromReport(MID_A, POWER('ac', UPS({ name: '' }))), null);
        assert.equal(reg0.size(), 0);
        assert.ok(reg0.upsertFromReport(MID_A, POWER('ac', UPS({ name: 'n'.repeat(64) }))));
        const long = 'n'.repeat(80);
        const id = acc.accessoryId(MID_A, long);
        writeRaw(JSON.stringify({ accessories: { [id]: { type: 'ups', dataLinkMachineId: MID_A, upsId: '1', name: long } } }));
        const reg = acc.createRegistry({ file });
        reg.load();
        assert.equal(reg.size(), 0);
    });
});

describe('9 projection stays additive', () => {
    // server.js is not importable (it listens on load and owns hard-coded data paths), so the
    // projection is verified against its source text; an end-to-end run needs a sandboxed host.
    test('parseFleetData machine projection keeps `status: m.status` and adds only power_state/display_status/power_reason', () => {
        const start = SERVER_JS.indexOf('system: projectSystemBlock(m.system),');
        assert.ok(start > 0);
        const tail = SERVER_JS.slice(start, SERVER_JS.indexOf('}));', start));
        const keys = [...tail.matchAll(/^\s{12}(\w+):/gm)].map((x) => x[1]);
        assert.deepEqual(keys, ['power_state', 'display_status', 'power_reason']);
        const head = SERVER_JS.slice(Math.max(0, start - 2500), start);
        assert.match(head, /status: m\.status,/);
        assert.doesNotMatch(SERVER_JS, /\bstatus:\s*power\./);
        assert.match(SERVER_JS, /display_status: \(power\.machines\.get\(m\.machine_id\) \|\| \{\}\)\.display_status \|\| m\.status/);
    });

    test('fleet payload keeps the `fleet` shape; accessories is a top-level sibling', () => {
        assert.match(SERVER_JS, /machines: machineList\n\s+\},\n\s+activityLog: activityLog,[\s\S]{0,300}accessories: power\.accessories,/);
    });

    test('derive output for a machine with no accessory degrades to heartbeat status and null power fields', () => {
        const reg = acc.createRegistry({ file });
        for (const st of ['online', 'warning', 'offline']) {
            const m = reg.derive(mapOf(machine(MID_C, st))).machines.get(MID_C);
            assert.deepEqual(m, { power_state: null, display_status: st, power_reason: null });
        }
    });
});
