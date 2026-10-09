//
//  notify-store.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Unit tests for lib/notify-store.js (XACA-1400-001). Every file lives under a
 * mkdtemp sandbox; keys are passed explicitly, never read from the real env.
 */

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const { createNotifyStore, parseKey, NotifyCryptoError, NotifyStoreDisabledError, NotifyValidationError, NotifyNotFoundError, NotifyConflictError } = require('../lib/notify-store');

const SENTINEL = 'SENTINEL-s3cret-' + crypto.randomBytes(6).toString('hex');
const KEY_A = crypto.randomBytes(32);
const KEY_B = crypto.randomBytes(32);

class NotifyConfigError extends Error {}
const stubProvider = {
    name: 'stub', paramFields: ['url', 'channel'], secretFields: ['token', 'extra'],
    validate(c) {
        if (!c.params.url) throw new NotifyConfigError('url is required');
        if (c.secrets.token === 'bad') throw new NotifyConfigError(`token rejected: ${c.secrets.token}`);
    },
};
const registry = { has: (n) => n === 'stub', get: (n) => (n === 'stub' ? stubProvider : undefined), names: () => ['stub'] };

let dir;
before(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'notify-store-test-')); });
after(() => { fs.rmSync(dir, { recursive: true, force: true }); });
let n = 0;
const newFile = () => path.join(dir, `store-${++n}.json`);
const mk = (over) => createNotifyStore(Object.assign({ file: newFile(), key: KEY_A, registry }, over));
const good = (over) => Object.assign({ id: 'phone-sms', provider: 'stub', label: 'Phone', params: { url: 'https://x.example' }, secrets: { token: SENTINEL } }, over);

describe('key parsing', () => {
    test('accepts 64 hex and 32-byte base64', () => {
        assert.equal(parseKey(KEY_A.toString('hex')).key.length, 32);
        assert.equal(parseKey(KEY_A.toString('base64')).key.length, 32);
    });
    test('rejects short, empty, garbage', () => {
        for (const bad of [undefined, '', '   ', 'abc', 'zz'.repeat(32), crypto.randomBytes(16).toString('base64')]) {
            assert.ok(parseKey(bad).reason, String(bad));
        }
    });
});

describe('round trip and public view', () => {
    test('create then resolve returns plaintext; public view hides it', () => {
        const s = mk();
        const pub = s.createConnection(good());
        assert.deepEqual(pub.secrets, { token: 'set' });
        assert.ok(!JSON.stringify(pub).includes(SENTINEL));
        assert.ok(!JSON.stringify(s.listConnections()).includes(SENTINEL));
        assert.ok(!JSON.stringify(s.getConnection('phone-sms')).includes(SENTINEL));
        const full = s.resolveConnection('phone-sms');
        assert.deepEqual(full.secrets, { token: SENTINEL });
        assert.deepEqual(full.params, { url: 'https://x.example' });
        assert.equal(full.provider, 'stub');
    });
    test('on-disk file has no plaintext, version 1, routes object, mode 0600', () => {
        const s = mk();
        s.createConnection(good());
        const raw = fs.readFileSync(s.file, 'utf8');
        assert.ok(!raw.includes(SENTINEL));
        const j = JSON.parse(raw);
        assert.equal(j.version, 1);
        assert.deepEqual(j.routes, {});
        assert.deepEqual(Object.keys(j.connections['phone-sms'].secrets.token).sort(), ['ct', 'iv', 'tag']);
        assert.equal(fs.statSync(s.file).mode & 0o777, 0o600);
    });
    test('reload from disk decrypts; routes round-trip untouched', () => {
        const file = newFile();
        const s1 = createNotifyStore({ file, key: KEY_A, registry });
        s1.createConnection(good());
        s1._mutate((d) => { d.routes.academy = { x: 1 }; });
        const s2 = createNotifyStore({ file, key: KEY_A, registry });
        assert.equal(s2.resolveConnection('phone-sms').secrets.token, SENTINEL);
        assert.deepEqual(s2._state().routes, { academy: { x: 1 } });
        s2.updateConnection('phone-sms', { label: 'New' });
        assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')).routes, { academy: { x: 1 } });
    });
    test('fresh IV per value', () => {
        const s = mk();
        s.createConnection(good({ id: 'a1' }));
        s.createConnection(good({ id: 'a2' }));
        const st = s._state().connections;
        assert.notEqual(st.a1.secrets.token.iv, st.a2.secrets.token.iv);
        assert.notEqual(st.a1.secrets.token.ct, st.a2.secrets.token.ct);
    });
});

describe('update semantics', () => {
    test('omitted secret kept, new value replaces, empty/null clears', () => {
        const s = mk();
        s.createConnection(good({ secrets: { token: SENTINEL, extra: 'E1' } }));
        s.updateConnection('phone-sms', { label: 'L2' });
        assert.deepEqual(s.resolveConnection('phone-sms').secrets, { token: SENTINEL, extra: 'E1' });
        s.updateConnection('phone-sms', { secrets: { extra: 'E2' } });
        assert.deepEqual(s.resolveConnection('phone-sms').secrets, { token: SENTINEL, extra: 'E2' });
        s.updateConnection('phone-sms', { secrets: { extra: '' } });
        assert.deepEqual(s.getConnection('phone-sms').secrets, { token: 'set' });
        s.updateConnection('phone-sms', { secrets: { token: null } });
        assert.deepEqual(s.getConnection('phone-sms').secrets, {});
    });
    test('update rejects provider change, unknown field, missing id; delete works', () => {
        const s = mk();
        s.createConnection(good());
        assert.throws(() => s.updateConnection('phone-sms', { provider: 'other' }), NotifyValidationError);
        assert.throws(() => s.updateConnection('phone-sms', { bogus: 1 }), NotifyValidationError);
        assert.throws(() => s.updateConnection('nope', { label: 'x' }), NotifyNotFoundError);
        assert.equal(s.deleteConnection('phone-sms'), true);
        assert.equal(s.getConnection('phone-sms'), null);
        assert.throws(() => s.deleteConnection('phone-sms'), NotifyNotFoundError);
    });
});

describe('validation', () => {
    test('id pattern, duplicate, unknown provider, unknown param/secret fields', () => {
        const s = mk();
        for (const id of ['Bad', '-x', 'a b', '', 'x'.repeat(64), 5]) {
            assert.throws(() => s.createConnection(good({ id })), NotifyValidationError, String(id));
        }
        s.createConnection(good());
        assert.throws(() => s.createConnection(good()), NotifyConflictError);
        assert.throws(() => s.createConnection(good({ id: 'p2', provider: 'nope' })), /unknown provider/);
        assert.throws(() => s.createConnection(good({ id: 'p3', params: { url: 'u', evil: 1 } })), /unknown param field/);
        assert.throws(() => s.createConnection(good({ id: 'p4', secrets: { token: 't', evil: 'x' } })), /unknown secret field/);
        assert.throws(() => s.createConnection(good({ id: 'p5', secrets: { token: 5 } })), NotifyValidationError);
    });
    test('provider.validate failure maps to validation error with secret scrubbed', () => {
        const s = mk();
        assert.throws(() => s.createConnection(good({ id: 'p6', params: {} })), /url is required/);
        try { s.createConnection(good({ id: 'p7', secrets: { token: 'bad' } })); assert.fail('should throw'); }
        catch (e) {
            assert.ok(e instanceof NotifyValidationError);
            assert.ok(!e.message.includes('bad]') && e.message.includes('[redacted]'));
        }
        assert.equal(s.listConnections().length, 0);
    });
});

describe('crypto failure modes', () => {
    test('wrong key throws typed error without the value', () => {
        const file = newFile();
        createNotifyStore({ file, key: KEY_A, registry }).createConnection(good());
        const s = createNotifyStore({ file, key: KEY_B, registry });
        assert.throws(() => s.resolveConnection('phone-sms'), (e) => e instanceof NotifyCryptoError && !e.message.includes(SENTINEL));
    });
    test('tampered ciphertext, tag, and iv are rejected', () => {
        for (const part of ['ct', 'tag', 'iv']) {
            const file = newFile();
            createNotifyStore({ file, key: KEY_A, registry }).createConnection(good());
            const j = JSON.parse(fs.readFileSync(file, 'utf8'));
            const buf = Buffer.from(j.connections['phone-sms'].secrets.token[part], 'base64');
            buf[0] ^= 0xff;
            j.connections['phone-sms'].secrets.token[part] = buf.toString('base64');
            fs.writeFileSync(file, JSON.stringify(j));
            const s = createNotifyStore({ file, key: KEY_A, registry });
            assert.throws(() => s.resolveConnection('phone-sms'), NotifyCryptoError, part);
        }
    });
    test('AAD swap between connections and between fields is rejected', () => {
        const file = newFile();
        const s0 = createNotifyStore({ file, key: KEY_A, registry });
        s0.createConnection(good({ id: 'one', secrets: { token: 'AAA', extra: 'EEE' } }));
        s0.createConnection(good({ id: 'two', secrets: { token: 'BBB' } }));
        const j = JSON.parse(fs.readFileSync(file, 'utf8'));
        const orig = JSON.stringify(j);
        // connection swap
        j.connections.two.secrets.token = j.connections.one.secrets.token;
        fs.writeFileSync(file, JSON.stringify(j));
        assert.throws(() => createNotifyStore({ file, key: KEY_A, registry }).resolveConnection('two'), NotifyCryptoError);
        // field swap
        const j2 = JSON.parse(orig);
        j2.connections.one.secrets.token = j2.connections.one.secrets.extra;
        fs.writeFileSync(file, JSON.stringify(j2));
        assert.throws(() => createNotifyStore({ file, key: KEY_A, registry }).resolveConnection('one'), NotifyCryptoError);
    });
});

describe('fail closed', () => {
    test('missing or malformed key -> disabled; refuses everything; nothing written', () => {
        for (const key of [null, '', 'short', 'zz'.repeat(32)]) {
            const file = newFile();
            const s = createNotifyStore({ file, key, registry });
            const st = s.status();
            assert.equal(st.enabled, false);
            assert.ok(st.reason);
            assert.throws(() => s.createConnection(good()), NotifyStoreDisabledError);
            assert.throws(() => s.updateConnection('x', {}), NotifyStoreDisabledError);
            assert.throws(() => s.deleteConnection('x'), NotifyStoreDisabledError);
            assert.throws(() => s.resolveConnection('x'), NotifyStoreDisabledError);
            assert.ok(!fs.existsSync(file));
        }
    });
    test('env NOTIFY_STORE_KEY is the default key source', () => {
        const saved = process.env.NOTIFY_STORE_KEY;
        try {
            process.env.NOTIFY_STORE_KEY = KEY_A.toString('hex');
            assert.equal(createNotifyStore({ file: newFile(), registry }).status().enabled, true);
            delete process.env.NOTIFY_STORE_KEY;
            assert.equal(createNotifyStore({ file: newFile(), registry }).status().enabled, false);
        } finally {
            if (saved === undefined) delete process.env.NOTIFY_STORE_KEY; else process.env.NOTIFY_STORE_KEY = saved;
        }
    });
    test('corrupt file is moved aside; store starts empty', () => {
        const file = newFile();
        fs.writeFileSync(file, '{not json');
        const s = createNotifyStore({ file, key: KEY_A, registry });
        assert.deepEqual(s.listConnections(), []);
        assert.ok(fs.readdirSync(dir).some((f) => f.startsWith(path.basename(file) + '.corrupt-')));
    });
    test('failed write rolls back in-memory state', () => {
        const s = mk({ file: path.join(dir, 'not-a-dir-file') });
        fs.writeFileSync(path.join(dir, 'not-a-dir-file'), 'x'); // load() moves this aside; recreate as a blocker for mkdir
        fs.renameSync(path.join(dir, 'not-a-dir-file'), path.join(dir, 'blocker'));
        const bad = createNotifyStore({ file: path.join(dir, 'blocker', 'sub', 'store.json'), key: KEY_A, registry });
        assert.throws(() => bad.createConnection(good()));
        assert.deepEqual(bad.listConnections(), []);
        assert.ok(s);
    });
});
