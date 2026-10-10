//
//  notify-provider-email.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createEmailProvider } = require('../lib/notify-providers/email');
const { NotifyConfigError, NotifySendError, createProviderRegistry, attemptSend } = require('../lib/notify-providers');

const USER = 'smtp-user-zq';
const PASS = 'smtp-pass-zq';
const conn = (over = {}) => ({
    id: 'c1', provider: 'email', label: 'mail',
    params: { host: 'smtp.example.com', port: 587, from: 'ops@example.com', to: 'a@example.com, b@example.com', ...(over.params || {}) },
    secrets: { user: USER, pass: PASS, ...(over.secrets || {}) },
});
const msg = { team: 'academy', type: 'ci', title: 'Build broke', body: 'details', ref: 'XACA-1', severity: 'high' };

function fake(behavior = {}) {
    const state = { opts: null, mail: null, closed: 0 };
    const createTransport = (opts) => {
        state.opts = opts;
        return {
            sendMail: (mail) => { state.mail = mail; return behavior.sendMail ? behavior.sendMail(mail) : Promise.resolve({ messageId: '<m1@x>' }); },
            close: () => { state.closed += 1; },
        };
    };
    return { state, provider: createEmailProvider({ createTransport }) };
}

test('registers and exposes fields', () => {
    const { provider } = fake();
    const reg = createProviderRegistry();
    reg.register('email', provider);
    assert.deepEqual(provider.secretFields, ['user', 'pass']);
});

test('validate accepts good config incl. array recipients and implicit TLS', () => {
    const { provider } = fake();
    provider.validate(conn());
    provider.validate(conn({ params: { port: 465, to: ['a@example.com'], secure: 'implicit' } }));
    provider.validate(conn({ secrets: { user: '', pass: '' } }));
});

test('validate rejects bad fields naming fields only', () => {
    const { provider } = fake();
    const cases = [
        [{ host: '' }, 'host'], [{ host: 'bad host!' }, 'host'], [{ port: 0 }, 'port'], [{ port: 'x' }, 'port'],
        [{ from: 'nope' }, 'from'], [{ to: 'a@example.com, junk' }, 'to'], [{ to: [] }, 'to'], [{ to: 5 }, 'to'],
        [{ to: 'a@example.com\r\nBcc: x@y.com' }, 'to'],
    ];
    for (const [params, field] of cases) {
        assert.throws(() => provider.validate(conn({ params })), (e) => e instanceof NotifyConfigError && e.message.includes(field), JSON.stringify(params));
    }
    assert.throws(() => provider.validate(conn({ secrets: { user: USER, pass: '' } })), NotifyConfigError);
});

test('validate rejects anything permitting plaintext', () => {
    const { provider } = fake();
    for (const secure of [false, 'false', 'none', 'plain', 'ignore']) {
        assert.throws(() => provider.validate(conn({ params: { secure } })), /secure/, String(secure));
    }
});

test('error messages never contain credentials or addresses', () => {
    const { provider } = fake();
    try { provider.validate(conn({ params: { from: 'bad', to: 'a@example.com' } })); assert.fail(); } catch (e) {
        for (const s of [USER, PASS, 'a@example.com', 'smtp.example.com']) assert.ok(!e.message.includes(s));
    }
});

test('transport options always require TLS and never weaken it', async () => {
    for (const params of [{}, { port: 465 }, { secure: 'starttls' }, { secure: 'implicit', port: 465 }]) {
        const { state, provider } = fake();
        await provider.send(conn({ params }), msg, {});
        const o = state.opts;
        assert.equal(o.requireTLS, true);
        assert.ok(!('ignoreTLS' in o));
        assert.ok(!('tls' in o));
        assert.ok(!('logger' in o) && !('debug' in o));
        assert.ok(o.connectionTimeout > 0 && o.greetingTimeout > 0 && o.socketTimeout > 0);
        assert.deepEqual(o.auth, { user: USER, pass: PASS });
    }
    const a = fake(); await a.provider.send(conn({ params: { port: 465 } }), msg, {});
    assert.equal(a.state.opts.secure, true);
    const b = fake(); await b.provider.send(conn(), msg, {});
    assert.equal(b.state.opts.secure, false);
});

test('send builds mail, returns messageId, closes transport', async () => {
    const { state, provider } = fake();
    const res = await provider.send(conn(), msg, {});
    assert.deepEqual(res, { providerMessageId: '<m1@x>' });
    assert.equal(state.mail.subject, '[HIGH] Build broke');
    assert.deepEqual(state.mail.to, ['a@example.com', 'b@example.com']);
    assert.equal(state.mail.from, 'ops@example.com');
    for (const s of ['Build broke', 'details', 'academy', 'ci', 'XACA-1']) assert.ok(state.mail.text.includes(s));
    assert.ok(state.closed >= 1);
});

test('subject header injection via title is neutralised', async () => {
    const { state, provider } = fake();
    await provider.send(conn(), { ...msg, title: 'x\r\nBcc: evil@e.com' }, {});
    assert.ok(!/[\r\n]/.test(state.mail.subject));
});

test('send failure: code only, no foreign text; transport closed', async () => {
    const err = Object.assign(new Error(`535 auth failed for ${USER}:${PASS} a@example.com smtp.example.com`), { code: 'EAUTH' });
    const { state, provider } = fake({ sendMail: () => Promise.reject(err) });
    await assert.rejects(provider.send(conn(), msg, {}), (e) => {
        assert.ok(e instanceof NotifySendError);
        assert.equal(e.message, 'email send failed (EAUTH)');
        for (const s of [USER, PASS, 'example.com']) assert.ok(!e.message.includes(s));
        return true;
    });
    assert.ok(state.closed >= 1);
});

test('createTransport throwing becomes a scrubbed NotifySendError', async () => {
    const provider = createEmailProvider({ createTransport: () => { throw new Error(`boom ${PASS}`); } });
    await assert.rejects(provider.send(conn(), msg, {}), (e) => e instanceof NotifySendError && !e.message.includes(PASS));
});

test('abort closes transport and rejects with NotifySendError', async () => {
    const { state, provider } = fake({ sendMail: () => new Promise(() => {}) });
    const ac = new AbortController();
    const p = provider.send(conn(), msg, { signal: ac.signal });
    setImmediate(() => ac.abort());
    await assert.rejects(p, (e) => e instanceof NotifySendError && /aborted/.test(e.message));
    assert.ok(state.closed >= 1);
});

test('already-aborted signal never opens a transport', async () => {
    const { state, provider } = fake();
    const ac = new AbortController(); ac.abort();
    await assert.rejects(provider.send(conn(), msg, { signal: ac.signal }), NotifySendError);
    assert.equal(state.opts, null);
});

test('works through attemptSend', async () => {
    const { provider } = fake();
    const r = await attemptSend(provider, conn(), msg, undefined);
    assert.equal(r.ok, true);
    assert.equal(r.providerMessageId, '<m1@x>');
    const bad = await attemptSend(provider, conn({ params: { host: '' } }), msg, undefined);
    assert.equal(bad.ok, false);
});
