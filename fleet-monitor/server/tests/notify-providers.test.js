'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
    NotifyError, NotifyConfigError, NotifySendError,
    createProviderRegistry, attemptSend, defaultRegistry, createTestProvider,
} = require('../lib/notify-providers');

const conn = { id: 'c1', provider: 'test', label: 'L', params: {}, secrets: { token: 'tok-SECRET' } };
const msg = { team: 'academy', type: 'x', title: 't', body: 'b', ref: '', severity: 'info' };

test('error classes form a hierarchy', () => {
    assert.ok(new NotifyConfigError('a') instanceof NotifyError);
    assert.ok(new NotifySendError('a') instanceof NotifyError);
});

test('default registry holds the test provider plus the XACA-1401 channels', () => {
    const reg = defaultRegistry();
    assert.deepEqual(reg.names(), ['email', 'ntfy', 'pushover', 'slack', 'teams', 'test']);
    assert.equal(reg.has('sms'), false);
    assert.throws(() => reg.get('sms'), (e) => e instanceof NotifyConfigError && /unknown provider/.test(e.message));
});

test('register validates provider shape', () => {
    const reg = createProviderRegistry();
    const ok = { name: 'a', paramFields: [], secretFields: [], validate() {}, async send() { return {}; } };
    assert.throws(() => reg.register('a', { ...ok, validate: null }), NotifyConfigError);
    assert.throws(() => reg.register('a', { ...ok, send: 1 }), NotifyConfigError);
    assert.throws(() => reg.register('a', { ...ok, secretFields: 'x' }), NotifyConfigError);
    assert.throws(() => reg.register('b', ok), NotifyConfigError); // name mismatch
    assert.throws(() => reg.register('Bad Name', ok), NotifyConfigError);
    reg.register('a', ok);
    assert.throws(() => reg.register('a', ok), NotifyConfigError); // duplicate
    assert.equal(reg.get('a'), ok);
});

test('test provider validates token and records calls', async () => {
    const p = createTestProvider();
    assert.throws(() => p.validate({ secrets: { token: ' ' } }), NotifyConfigError);
    const r = await attemptSend(p, conn, msg);
    assert.equal(r.ok, true);
    assert.equal(r.error, '');
    assert.equal(r.providerMessageId, 'test-1');
    assert.equal(p.calls.length, 1);
    assert.ok(!JSON.stringify(p.calls).includes('tok-SECRET'));
});

test('test provider can be told to fail; NotifyError text passes through', async () => {
    const p = createTestProvider();
    p.failNext(1);
    const r = await attemptSend(p, conn, msg);
    assert.equal(r.ok, false);
    assert.match(r.error, /forced failure/);
    assert.equal((await attemptSend(p, conn, msg)).ok, true);
});

test('validate failure short-circuits before send', async () => {
    const p = createTestProvider();
    const r = await attemptSend(p, { ...conn, secrets: {} }, msg);
    assert.equal(r.ok, false);
    assert.equal(p.calls.length, 0);
});

test('foreign exception text (with a secret) is NOT in the error', async () => {
    class WeirdTransportError extends Error {}
    const bad = {
        name: 'bad', paramFields: [], secretFields: [], validate() {},
        async send() { throw new WeirdTransportError('POST https://hooks.example/SECRET-URL-123 failed'); },
    };
    const r = await attemptSend(bad, conn, msg);
    assert.equal(r.ok, false);
    assert.equal(r.error, 'provider error (WeirdTransportError)');
    assert.ok(!r.error.includes('SECRET'));
    const sync = { ...bad, validate() { throw new TypeError('token=SECRET-ABC'); } };
    assert.equal((await attemptSend(sync, conn, msg)).error, 'provider error (TypeError)');
});
