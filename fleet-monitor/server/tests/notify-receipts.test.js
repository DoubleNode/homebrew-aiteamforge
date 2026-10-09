'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { createReceiptLog } = require('../lib/notify-receipts');

function sandbox(opts = {}) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'notify-receipts-'));
    const file = path.join(dir, 'sub', 'r.jsonl');
    let t = Date.parse('2026-10-09T00:00:00Z');
    const log = createReceiptLog({ file, clock: () => new Date((t += 1000)), ...opts });
    return { dir, file, log };
}
const base = { team: 'academy', type: 'ci', ref: 'REL-1', severity: 'high', connectionId: 'c1', provider: 'test', ok: true };

test('newReceipt builds the shape with id and clock ts', () => {
    const { log } = sandbox();
    const r = log.newReceipt(base);
    assert.match(r.id, /^ntc-[0-9a-f]{12}$/);
    assert.equal(r.ts, '2026-10-09T00:00:01.000Z');
    assert.equal(r.error, '');
    assert.equal(r.ok, true);
});

test('newReceipt strips secrets/params/body/destination/title', () => {
    const { log } = sandbox();
    const r = log.newReceipt({ ...base, secrets: { token: 'S' }, params: { url: 'U' }, body: 'B', title: 'T', destination: 'D', suppressed: 'bogus' });
    for (const k of ['secrets', 'params', 'body', 'title', 'destination', 'suppressed']) assert.ok(!(k in r), k);
    assert.ok(!JSON.stringify(r).match(/"S"|"U"|"B"|"D"/));
    assert.equal(log.newReceipt({ ...base, suppressed: 'dedupe' }).suppressed, 'dedupe');
});

test('failed receipt keeps error text; ok receipt blanks it', () => {
    const { log } = sandbox();
    assert.equal(log.newReceipt({ ...base, ok: false, error: 'nope' }).error, 'nope');
    assert.equal(log.newReceipt({ ...base, ok: true, error: 'stale' }).error, '');
});

test('append + recent: newest first, team filter, limit; append strips extras', () => {
    const { log, file } = sandbox();
    log.append({ ...log.newReceipt(base), secrets: 'LEAK' });
    log.append(log.newReceipt({ ...base, team: 'ios' }));
    log.append(log.newReceipt(base));
    assert.ok(!fs.readFileSync(file, 'utf8').includes('LEAK'));
    assert.equal(log.recent().length, 3);
    assert.equal(log.recent({ team: 'academy' }).length, 2);
    assert.equal(log.recent({ limit: 1 }).length, 1);
    const all = log.recent();
    assert.ok(all[0].ts > all[2].ts);
});

test('recent on missing file is empty; corrupt lines are skipped', () => {
    const { log, file } = sandbox();
    assert.deepEqual(log.recent(), []);
    log.append(log.newReceipt(base));
    fs.appendFileSync(file, '{"id":"ntc-trunc');
    assert.equal(log.recent().length, 1);
    fs.appendFileSync(file, '\nnot json\n');
    log.append(log.newReceipt(base));
    assert.equal(log.recent().length, 2);
});

test('rotation moves to .1 past maxBytes, one generation', () => {
    const { log, file } = sandbox({ maxBytes: 300 });
    for (let i = 0; i < 12; i++) log.append(log.newReceipt(base));
    assert.ok(fs.existsSync(file + '.1'));
    assert.ok(!fs.existsSync(file + '.2'));
    assert.ok(fs.statSync(file).size <= 600);
    assert.ok(log.recent().length >= 1);
});

test('write failure throws naming the type only', () => {
    const { dir } = sandbox();
    const blocker = path.join(dir, 'blocker');
    fs.writeFileSync(blocker, 'x');
    const log = createReceiptLog({ file: path.join(blocker, 'dir', 'r.jsonl') });
    assert.throws(() => log.append(log.newReceipt(base)), (e) => /notify receipt write failed \(\w+\)/.test(e.message) && !e.message.includes(blocker));
});
