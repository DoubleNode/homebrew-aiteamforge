'use strict';
// XACA-1441-004: ci-pool-store (offline, temp dirs only).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const S = require('../lib/ci-pool-store');

const quiet = { error() {} };
function tmpStore() {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1441-pool-'));
    const file = path.join(dir, 'data', 'ci-pool.json');
    return { dir, file, store: S.createPoolStore({ file, logger: quiet }) };
}

test('defaults are dormant and seeded', () => {
    const { store } = tmpStore();
    assert.deepEqual(store.load(), { ok: true, fresh: true });
    const c = store.getConfig();
    assert.deepEqual(c.allowlist, []);
    assert.equal(c.poolLabel, 'fleet-pool');
    assert.deepEqual(c.jobClasses, { 'shell-suite': 'long', bats: 'long', 'pytest-suite': 'long' });
    assert.equal(c.thresholds.memReclaimableBytes, 1.5 * S.GIB);
    assert.equal(c.thresholds.swapUsedBytes, Math.round(2.8 * S.GIB));
    assert.equal(c.thresholds.memFreePct, 35);
    assert.equal(c.thresholds.loadPerCpu, 0.75);
    assert.equal(c.thresholds.pollStaleMs, 30000);
    assert.deepEqual(store.listMachines(), {});
    assert.equal(store.getMachine('m4mini'), null);
    assert.deepEqual(S.validatePool(S.defaultPool()), []);
});

test('a new machine record defaults to enabled:false, not paused', () => {
    const { store } = tmpStore();
    assert.equal(store.upsertMachine('m4mini', { prefers: 'long' }).ok, true);
    const m = store.getMachine('m4mini');
    assert.equal(m.enabled, false);
    assert.equal(m.paused, false);
    assert.equal(m.keyHash, null);
    assert.equal(m.prefers, 'long');
});

test('round-trip through disk', () => {
    const { store, file } = tmpStore();
    assert.equal(store.updateConfig({ allowlist: ['DoubleNode/dev-team'], poolLabel: 'p1' }).ok, true);
    assert.equal(store.upsertMachine('m1mini', { enabled: true, prefers: 'short', thresholds: { swapUsedBytes: 4 * S.GIB } }).ok, true);
    assert.equal(store.setHostSecret('m1mini', 'host-secret-1').ok, true);
    const again = S.createPoolStore({ file, logger: quiet });
    assert.deepEqual(again.load(), { ok: true });
    assert.deepEqual(again.getConfig(), store.getConfig());
    assert.deepEqual(again.listMachines(), store.listMachines());
    assert.equal(again.getMachine('m1mini').enabled, true);
});

test('atomic write: no temp file left, file mode 0600, rollback when the write fails', () => {
    const { store, file, dir } = tmpStore();
    store.upsertMachine('a', { enabled: true });
    assert.deepEqual(fs.readdirSync(path.dirname(file)), ['ci-pool.json']);
    assert.equal(fs.statSync(file).mode & 0o777, 0o600);

    // make the data dir unwritable by replacing it with a file's parent clash
    const blocked = S.createPoolStore({ file: path.join(dir, 'ci-pool.json', 'nested', 'x.json'), logger: quiet });
    fs.writeFileSync(path.join(dir, 'ci-pool.json'), 'x');
    const r = blocked.upsertMachine('b', { enabled: true });
    assert.equal(r.ok, false);
    assert.equal(blocked.getMachine('b'), null);            // rolled back in memory
});

test('rejects bad shapes (fail closed) and leaves state untouched', () => {
    const { store } = tmpStore();
    store.upsertMachine('a', {});
    const before = JSON.stringify(store.listMachines());
    const bad = [
        () => store.upsertMachine('a', { enabled: 'yes' }),
        () => store.upsertMachine('a', { paused: 1 }),
        () => store.upsertMachine('a', { prefers: 'medium' }),
        () => store.upsertMachine('a', { surprise: true }),
        () => store.upsertMachine('a', { keyHash: 'a'.repeat(64) }),     // hash only via setHostSecret
        () => store.upsertMachine('a', { pausedBy: 'me' }),              // server-set only
        () => store.upsertMachine('a', { thresholds: { memFreePct: 101 } }),
        () => store.upsertMachine('a', { thresholds: { bogus: 1 } }),
        () => store.upsertMachine('a', { thresholds: { pollStaleMs: 1.5 } }),
        () => store.upsertMachine('a', { thresholds: { loadPerCpu: NaN } }),
        () => store.upsertMachine('../x', {}),
        () => store.upsertMachine('__proto__', {}),
        () => store.upsertMachine('a', null),
        () => store.updateConfig({ allowlist: ['not-a-repo'] }),
        () => store.updateConfig({ allowlist: ['a/b', 'A/B'] }),
        () => store.updateConfig({ jobClasses: { bats: 'medium' } }),
        () => store.updateConfig({ poolLabel: 'bad label' }),
        () => store.updateConfig({ unknown: 1 }),
        () => store.updateConfig({ thresholds: { memFreePct: 35 } }),    // partial config.thresholds is incomplete
    ];
    bad.forEach((f, i) => assert.equal(f().ok, false, `case ${i}`));
    assert.equal(JSON.stringify(store.listMachines()), before);
    assert.equal(store.getConfig().poolLabel, 'fleet-pool');
});

test('validatePool rejects unknown fields and wrong types at every level', () => {
    const p = () => S.defaultPool();
    let x = p(); x.extra = 1; assert.ok(S.validatePool(x).length);
    x = p(); x.schemaVersion = 2; assert.ok(S.validatePool(x).length);
    x = p(); x.config.extra = 1; assert.ok(S.validatePool(x).length);
    x = p(); delete x.config.thresholds.memFreePct; assert.ok(S.validatePool(x).length);
    x = p(); x.machines.m = { enabled: true }; assert.ok(S.validatePool(x).length);   // missing fields
    x = p(); x.machines.m = Object.assign(S.defaultMachine(), { extra: 1 }); assert.ok(S.validatePool(x).length);
    x = p(); x.machines.m = Object.assign(S.defaultMachine(), { keyHash: 'plaintext-secret' }); assert.ok(S.validatePool(x).length);
    x = p(); x.machines.m = Object.assign(S.defaultMachine(), { pausedAt: 'yesterday-ish' }); assert.ok(S.validatePool(x).length);
    x = p(); x.machines = []; assert.ok(S.validatePool(x).length);
    assert.ok(S.validatePool(null).length);
    assert.ok(S.validatePool('x').length);
});

test('load: corrupt JSON or invalid shape is moved aside and the store starts dormant', () => {
    for (const body of ['{not json', JSON.stringify({ schemaVersion: 1, config: {}, machines: {} })]) {
        const { store, file } = tmpStore();
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, body);
        const r = store.load();
        assert.equal(r.ok, false);
        assert.ok(fs.existsSync(r.movedTo));
        assert.equal(fs.existsSync(file), false);
        assert.deepEqual(store.listMachines(), {});
        assert.equal(store.getConfig().poolLabel, 'fleet-pool');
    }
});

test('pause: server stamps pausedBy/pausedAt; unpause clears; keeps single field', () => {
    const { store } = tmpStore();
    store.upsertMachine('m1mini', { enabled: true });
    const now = Date.parse('2026-10-06T12:00:00Z');
    assert.equal(store.upsertMachine('m1mini', { paused: true, pauseReason: 'swap' }, { by: 'operator', now }).ok, true);
    let m = store.getMachine('m1mini');
    assert.deepEqual([m.paused, m.pausedBy, m.pausedAt, m.pauseReason], [true, 'operator', '2026-10-06T12:00:00.000Z', 'swap']);
    // re-asserting paused does not restamp
    store.upsertMachine('m1mini', { paused: true }, { by: 'other', now: now + 1000 });
    m = store.getMachine('m1mini');
    assert.deepEqual([m.pausedBy, m.pausedAt], ['operator', '2026-10-06T12:00:00.000Z']);
    store.upsertMachine('m1mini', { paused: false });
    m = store.getMachine('m1mini');
    assert.deepEqual([m.paused, m.pausedBy, m.pausedAt, m.pauseReason], [false, null, null, null]);
});

test('host secret: only the sha256 hash is stored; verify is exact', () => {
    const { store, file } = tmpStore();
    assert.equal(store.setHostSecret('nope', 's').ok, false);
    store.upsertMachine('m4mini', {});
    assert.equal(store.verifyHostSecret('m4mini', 's3cret-value'), false);       // none stored yet
    assert.equal(store.setHostSecret('m4mini', 's3cret-value').ok, true);
    const m = store.getMachine('m4mini');
    assert.equal(m.keyHash, S.hashSecret('s3cret-value'));
    assert.match(m.keyHash, /^[0-9a-f]{64}$/);
    assert.equal(fs.readFileSync(file, 'utf8').includes('s3cret-value'), false);   // plaintext never on disk
    assert.equal(store.verifyHostSecret('m4mini', 's3cret-value'), true);
    for (const wrong of ['s3cret-valu', 's3cret-value ', 'S3CRET-VALUE', '', null, undefined, 42]) {
        assert.equal(store.verifyHostSecret('m4mini', wrong), false, String(wrong));
    }
    assert.equal(store.verifyHostSecret('other', 's3cret-value'), false);
    assert.equal(store.setHostSecret('m4mini', '').ok, false);
    assert.equal(store.clearHostSecret('m4mini').ok, true);
    assert.equal(store.verifyHostSecret('m4mini', 's3cret-value'), false);
    assert.throws(() => S.hashSecret(''), TypeError);
});

test('getters return copies (callers cannot mutate store state)', () => {
    const { store } = tmpStore();
    store.upsertMachine('a', { enabled: true });
    const m = store.getMachine('a'); m.enabled = false;
    store.getConfig().allowlist.push('x/y');
    store.listMachines().a.paused = true;
    assert.equal(store.getMachine('a').enabled, true);
    assert.equal(store.getMachine('a').paused, false);
    assert.deepEqual(store.getConfig().allowlist, []);
});

test('createPoolStore requires a file', () => {
    assert.throws(() => S.createPoolStore({}), TypeError);
    assert.throws(() => S.createPoolStore(), TypeError);
});
