//
//  xaca-1391-system-power.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1391-004 -- server-side coverage for the optional `system.power`
 * block (UPS / power-source telemetry). Exercises normalizeSystemBlock()
 * (POST /api/status ingestion) and projectSystemBlock() (GET /api/fleet)
 * via tests/helpers/app-factory.js's mirror, which
 * xaca-1031-007-mirror-drift-guard.test.js ties byte-for-byte to server.js
 * (sanitizePowerBlock is in that guard's list).
 *
 * Contract: power ABSENT = unknown (never "ac"); bad source drops the whole
 * leaf; bad ups -> ups:null with source kept; minutes_remaining null = no
 * estimate, 0 = real data.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { createApp, helpers } = require('./helpers/app-factory.js');

const { normalizeSystemBlock } = helpers;
const GUID = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

function goodUps(over) {
    return Object.assign({
        name: 'Back-UPS ES 600M1',
        id: 19333121,
        percent: 100,
        charging: false,
        minutes_remaining: 52,
        present: true
    }, over);
}

const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

test('valid ac with ups null is kept', () => {
    const out = normalizeSystemBlock({ power: { source: 'ac', ups: null } });
    assert.deepEqual(out.power, { source: 'ac', ups: null });
});

test('valid ups source with full ups object is kept verbatim', () => {
    const out = normalizeSystemBlock({ power: { source: 'ups', ups: goodUps() } });
    assert.deepEqual(out.power, { source: 'ups', ups: goodUps() });
});

test('valid battery source is kept', () => {
    const out = normalizeSystemBlock({ power: { source: 'battery', ups: null } });
    assert.deepEqual(out.power, { source: 'battery', ups: null });
});

test('missing ups field normalizes to ups:null (source retained)', () => {
    const out = normalizeSystemBlock({ power: { source: 'ac' } });
    assert.deepEqual(out.power, { source: 'ac', ups: null });
});

for (const bad of ['AC', 'wall', '', null, 5, ['ac'], {}, undefined]) {
    test(`malformed source ${JSON.stringify(bad)} drops the whole power leaf`, () => {
        const out = normalizeSystemBlock({ power: { source: bad, ups: goodUps() } });
        assert.equal(has(out, 'power'), false);
    });
}

for (const bad of ['ac', 7, true, [], null]) {
    test(`non-object power ${JSON.stringify(bad)} is dropped`, () => {
        const out = normalizeSystemBlock({ power: bad });
        assert.equal(has(out, 'power'), false);
    });
}

const badFields = {
    // XACA-1391-010: control chars in name; negative / unsafe / non-token ids
    name: ['', 42, null, 'x'.repeat(65), 'UPS\u0000', 'a\nb', 'x\u007f'],
    id: [null, '', 1.5, 'y'.repeat(33), {}, true, -7, 1e21, Number.MAX_SAFE_INTEGER + 2, 'a b', 'id"x'],
    percent: [-1, 101, 55.5, '80', null],
    charging: ['true', 1, null],
    present: ['yes', 0, null],
    minutes_remaining: [-1, 1.5, '30', 525601, undefined]
};
for (const [field, values] of Object.entries(badFields)) {
    for (const v of values) {
        test(`ups.${field} = ${JSON.stringify(v)} -> ups:null, source kept`, () => {
            const ups = goodUps();
            if (v === undefined) delete ups[field]; else ups[field] = v;
            const out = normalizeSystemBlock({ power: { source: 'ups', ups } });
            assert.deepEqual(out.power, { source: 'ups', ups: null });
        });
    }
}

for (const bad of ['str', 5, [], true]) {
    test(`non-object ups ${JSON.stringify(bad)} -> ups:null, source kept`, () => {
        const out = normalizeSystemBlock({ power: { source: 'ups', ups: bad } });
        assert.deepEqual(out.power, { source: 'ups', ups: null });
    });
}

test('XACA-1391-010: ids the reporter can emit are still accepted (0, MAX_SAFE_INTEGER, 0123 string)', () => {
    for (const id of [0, Number.MAX_SAFE_INTEGER, '0123', '12345678901234567', 'a_b.c:d-1']) {
        const out = normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ id }) } });
        assert.equal(out.power.ups.id, id);
    }
});

test('XACA-1391-010: printable unicode name is accepted', () => {
    const out = normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ name: 'UPS\u00e9\u2122' }) } });
    assert.equal(out.power.ups.name, 'UPS\u00e9\u2122');
});

test('string ups.id (short) is accepted', () => {
    const out = normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ id: 'abc-123' }) } });
    assert.equal(out.power.ups.id, 'abc-123');
});

test('name at exactly 64 chars is kept; 65 rejected (ups:null)', () => {
    const at = normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ name: 'n'.repeat(64) }) } });
    assert.equal(at.power.ups.name.length, 64);
    const over = normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ name: 'n'.repeat(65) }) } });
    assert.equal(over.power.ups, null);
});

test('minutes_remaining 0 is preserved (real data), null preserved (no estimate)', () => {
    const zero = normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ minutes_remaining: 0 }) } });
    assert.strictEqual(zero.power.ups.minutes_remaining, 0);
    const nul = normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ minutes_remaining: null }) } });
    assert.strictEqual(nul.power.ups.minutes_remaining, null);
});

test('percent 0 and charging:false/present:false survive (falsy is data)', () => {
    const out = normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ percent: 0, charging: false, present: false }) } });
    assert.strictEqual(out.power.ups.percent, 0);
    assert.strictEqual(out.power.ups.charging, false);
    assert.strictEqual(out.power.ups.present, false);
});

test('extra fields are stripped at both power and ups level', () => {
    const out = normalizeSystemBlock({
        power: { source: 'ups', extra: 'x', ups: Object.assign(goodUps(), { serial: 'SECRET' }) }
    });
    assert.deepEqual(Object.getOwnPropertyNames(out.power).sort(), ['source', 'ups']);
    assert.deepEqual(Object.getOwnPropertyNames(out.power.ups).sort(),
        ['charging', 'id', 'minutes_remaining', 'name', 'percent', 'present']);
});

test('power ABSENT stays absent (property not present, not just falsy), never synthesized as ac', () => {
    assert.equal(has(normalizeSystemBlock({ versions: {}, cores: 8 }), 'power'), false);
    assert.equal(has(normalizeSystemBlock({}), 'power'), false);
    assert.equal(has(normalizeSystemBlock(undefined), 'power'), false);
});

test('normalized output does not alias the input power object', () => {
    const input = { power: { source: 'ups', ups: goodUps() } };
    const out = normalizeSystemBlock(input);
    assert.notEqual(out.power, input.power);
    assert.notEqual(out.power.ups, input.power.ups);
});

// ---- route-level round trip (reads res.body, never server memory) ----

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

test('projection round trip: ups power reaches /api/fleet with the same shape (0 minutes kept)', async () => {
    const m = await roundTrip({ versions: {}, power: { source: 'ups', ups: goodUps({ minutes_remaining: 0 }) } });
    assert.deepEqual(m.system.power, { source: 'ups', ups: goodUps({ minutes_remaining: 0 }) });
});

test('projection round trip: ac / ups:null reaches /api/fleet', async () => {
    const m = await roundTrip({ versions: {}, power: { source: 'ac', ups: null } });
    assert.deepEqual(m.system.power, { source: 'ac', ups: null });
});

test('projection round trip: absent power stays absent in /api/fleet', async () => {
    const m = await roundTrip({ versions: {}, cores: 8 });
    assert.equal(has(m.system, 'power'), false);
});

test('projection round trip: malformed source never reaches /api/fleet', async () => {
    const m = await roundTrip({ versions: {}, power: { source: 'bogus', ups: goodUps() } });
    assert.equal(has(m.system, 'power'), false);
});

test('projection round trip: hostile oversized name collapses to ups:null', async () => {
    const m = await roundTrip({ versions: {}, power: { source: 'ups', ups: goodUps({ name: 'z'.repeat(5000) }) } });
    assert.deepEqual(m.system.power, { source: 'ups', ups: null });
});

// ---- XACA-1391-005 adversarial gaps ----

for (const [label, v] of [['NaN', NaN], ['Infinity', Infinity], ['-Infinity', -Infinity]]) {
    for (const field of ['percent', 'minutes_remaining', 'id']) {
        test(`ups.${field} = ${label} -> ups:null, source kept`, () => {
            const out = normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ [field]: v }) } });
            assert.deepEqual(out.power, { source: 'ups', ups: null });
        });
    }
}

test('boolean-as-string / number charging+present are rejected', () => {
    for (const bad of ['false', 'true', 0, 1, 'False']) {
        assert.equal(normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ charging: bad }) } }).power.ups, null);
        assert.equal(normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ present: bad }) } }).power.ups, null);
    }
});

test('source of the wrong TYPE (array / object / String object / case variant) drops the leaf', () => {
    for (const bad of [['ac'], { toString() { return 'ac'; } }, new String('ac'), 'AC', 'ac ', ' ac', 'Ups']) {
        assert.equal(has(normalizeSystemBlock({ power: { source: bad, ups: null } }), 'power'), false);
    }
});

test('percent boundary 0 and 100 kept; -0 serializes as 0', () => {
    assert.equal(normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ percent: 0 }) } }).power.ups.percent, 0);
    assert.equal(normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ percent: 100 }) } }).power.ups.percent, 100);
    // -0 is carried through but serializes as 0 on the wire.
    assert.equal(JSON.stringify(normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ percent: -0 }) } }).power.ups.percent), '0');
});

test('minutes_remaining boundary: 525600 kept, 525601 and MAX_SAFE_INTEGER rejected', () => {
    assert.equal(normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ minutes_remaining: 525600 }) } }).power.ups.minutes_remaining, 525600);
    assert.equal(normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ minutes_remaining: Number.MAX_SAFE_INTEGER }) } }).power.ups, null);
});

test('prototype-pollution names in power / ups never pollute and are never copied', () => {
    const hostile = JSON.parse('{"power":{"source":"ups","__proto__":{"polluted":1},"constructor":{"prototype":{"polluted":2}},'
        + '"ups":{"name":"A","id":1,"percent":5,"charging":false,"minutes_remaining":1,"present":true,'
        + '"__proto__":{"polluted":3},"constructor":{"prototype":{"polluted":4}}}}}');
    const out = normalizeSystemBlock(hostile);
    assert.equal({}.polluted, undefined);
    assert.equal(Object.prototype.polluted, undefined);
    assert.deepEqual(Object.keys(out.power), ['source', 'ups']);
    assert.deepEqual(Object.keys(out.power.ups).sort(), ['charging', 'id', 'minutes_remaining', 'name', 'percent', 'present']);
    assert.equal(Object.getPrototypeOf(out.power), Object.prototype);
});

test('__proto__ as the power value itself is dropped / harmless', () => {
    const out = normalizeSystemBlock(JSON.parse('{"power":{"__proto__":{"source":"ac"}}}'));
    assert.equal(has(out, 'power'), false);
    assert.equal({}.source, undefined);
});

test('huge nested payload under power/ups is stripped, output stays tiny', () => {
    let deep = { leaf: 1 };
    for (let i = 0; i < 5000; i++) deep = { n: deep };
    const junk = 'q'.repeat(1000000);
    const out = normalizeSystemBlock({ power: { source: 'ac', ups: goodUps({ extra: deep, junk }), deep, junk } });
    const s = JSON.stringify(out.power);
    assert.ok(s.length < 300, `power block grew to ${s.length} bytes`);
    assert.equal(has(out.power, 'deep'), false);
    assert.equal(has(out.power.ups, 'junk'), false);
});

test('over-long hostile string id rejected; markup in a short name passes as inert data', () => {
    assert.equal(normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ id: '<script>'.repeat(10) }) } }).power.ups, null);
    const out = normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ name: '<b>"x"' }) } });
    assert.equal(out.power.ups.name, '<b>"x"');
    // XACA-1391-010: a control character (NUL) is no longer inert data -- ups:null
    assert.equal(normalizeSystemBlock({ power: { source: 'ups', ups: goodUps({ name: '<b>"x"\u0000' }) } }).power.ups, null);
});

// ---- UI tolerance: system.power must not leak into the machine cards ----
// Traced 2026-10-08: the dashboards read machine.system by NAMED leaf only
// (disk, swap_used_bytes, load_average, cores, memory, os_*, model, arch,
// versions) and machineSystemToHealthInput() builds a 4-field allowlist; no
// for-in/Object iteration over system{}. This guard pins that: no file that
// consumes machine.system may mention `power`. A later ticket that
// deliberately renders power must update this test in the same diff.
test('UI consumers of machine.system never reference system.power (no leak into cards)', () => {
    const fs = require('node:fs');
    const path = require('node:path');
    const vm = require('node:vm');
    const pub = path.join(__dirname, '..', 'public');
    for (const rel of ['lcars/js/lcars-dashboard-app.js', 'lcars2/js/lcars-fleet-core.js',
        'lcars2/js/lcars-fleet-dashboard-app.js', 'lcars2/js/lcars-machine-health.js']) {
        const src = fs.readFileSync(path.join(pub, rel), 'utf8');
        assert.equal(/power/i.test(src), false, `${rel} mentions "power"`);
    }
    const sandbox = { window: {} };
    vm.runInNewContext(fs.readFileSync(path.join(pub, 'lcars2/js/lcars-machine-health.js'), 'utf8'), sandbox);
    const derive = sandbox.window.LCARS_MACHINE_HEALTH.deriveMachineHealth;
    const base = { diskPercentUsed: 40, swapUsedBytes: 0, loadAvg1: 1, coreCount: 8 };
    assert.deepEqual(
        JSON.parse(JSON.stringify(derive(Object.assign({ power: { source: 'ups' } }, base)))),
        JSON.parse(JSON.stringify(derive(base))));
});

test('projection round trip: hostile JSON (proto name, null percent) cannot alter /api/fleet shape', async () => {
    const body = '{"versions":{},"power":{"source":"ups","__proto__":{"polluted":1},'
        + '"ups":{"name":"A","id":1,"percent":null,"charging":false,"minutes_remaining":1,"present":true}}}';
    const m = await roundTrip(JSON.parse(body));
    assert.deepEqual(m.system.power, { source: 'ups', ups: null });
    assert.equal({}.polluted, undefined);
});
