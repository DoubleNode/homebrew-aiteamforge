'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { createPushoverProvider, LIMITS } = require('../lib/notify-providers/pushover');
const { NotifyConfigError, NotifySendError, attemptSend } = require('../lib/notify-providers');

const TOK = 'APPTOKEN-sekret-123';
const USR = 'USERKEY-sekret-456';
const conn = (over = {}) => ({ id: 'c1', provider: 'pushover', label: 'p', params: {}, secrets: { appToken: TOK, userKey: USR }, ...over });
const msg = (over = {}) => ({ team: 'academy', type: 't', title: 'Title', body: 'Body', ref: '', severity: 'info', ...over });
function stub(status = 200, json = { status: 1, request: 'req-1' }) {
    const calls = [];
    const f = async (url, opts) => { calls.push({ url, opts, form: new URLSearchParams(opts.body) }); return { status, json: async () => json }; };
    return { f, calls };
}

test('priority mapping for all severities', async () => {
    const want = { info: '-1', warning: '0', high: '1', critical: '2' };
    for (const [sev, p] of Object.entries(want)) {
        const { f, calls } = stub();
        await createPushoverProvider({ fetchImpl: f }).send(conn(), msg({ severity: sev }), {});
        assert.strictEqual(calls[0].form.get('priority'), p);
        assert.strictEqual(calls[0].url, 'https://api.pushover.net/1/messages.json');
        assert.strictEqual(calls[0].opts.method, 'POST');
    }
});

test('emergency sets retry/expire; others do not', async () => {
    let s = stub();
    await createPushoverProvider({ fetchImpl: s.f }).send(conn(), msg({ severity: 'critical' }), {});
    assert.strictEqual(s.calls[0].form.get('retry'), '60');
    assert.strictEqual(s.calls[0].form.get('expire'), '3600');
    s = stub();
    await createPushoverProvider({ fetchImpl: s.f }).send(conn(), msg({ severity: 'high' }), {});
    assert.strictEqual(s.calls[0].form.get('retry'), null);
});

test('form fields, device, url and providerMessageId', async () => {
    const { f, calls } = stub();
    const r = await createPushoverProvider({ fetchImpl: f }).send(conn({ params: { device: 'iphone' } }), msg({ ref: 'https://x.example/a' }), {});
    const form = calls[0].form;
    assert.strictEqual(form.get('token'), TOK);
    assert.strictEqual(form.get('user'), USR);
    assert.strictEqual(form.get('device'), 'iphone');
    assert.strictEqual(form.get('url'), 'https://x.example/a');
    assert.strictEqual(form.get('title'), 'Title');
    assert.deepStrictEqual(r, { providerMessageId: 'req-1' });
});

test('truncates to Pushover limits', async () => {
    const { f, calls } = stub();
    await createPushoverProvider({ fetchImpl: f }).send(conn(), msg({ title: 'T'.repeat(400), body: 'B'.repeat(3000), ref: 'https://x.example/' + 'a'.repeat(900) }), {});
    const form = calls[0].form;
    assert.strictEqual(Array.from(form.get('title')).length, LIMITS.title);
    assert.strictEqual(Array.from(form.get('message')).length, LIMITS.message);
    assert.ok(Array.from(form.get('url')).length <= LIMITS.url);
});

test('validate fails closed with field names only', () => {
    const p = createPushoverProvider({});
    assert.throws(() => p.validate(conn({ secrets: { userKey: USR } })), (e) => e instanceof NotifyConfigError && /appToken/.test(e.message) && !e.message.includes(USR));
    assert.throws(() => p.validate(conn({ secrets: { appToken: TOK } })), (e) => e instanceof NotifyConfigError && /userKey/.test(e.message) && !e.message.includes(TOK));
    assert.throws(() => p.validate(conn({ params: { device: 'bad device!' } })), (e) => e instanceof NotifyConfigError && /device/.test(e.message) && !e.message.includes('bad device'));
    assert.doesNotThrow(() => p.validate(conn()));
});

test('abort signal is passed to fetch and abort rejects safely', async () => {
    const ac = new AbortController();
    let seen;
    const f = (url, opts) => new Promise((_, reject) => {
        seen = opts.signal;
        opts.signal.addEventListener('abort', () => reject(Object.assign(new Error(`aborted ${url} ${TOK}`), { name: 'AbortError' })));
    });
    const p = createPushoverProvider({ fetchImpl: f }).send(conn(), msg(), { signal: ac.signal });
    ac.abort();
    await assert.rejects(p, (e) => e instanceof NotifySendError && /AbortError/.test(e.message) && !e.message.includes(TOK) && !e.message.includes('pushover.net'));
    assert.strictEqual(seen, ac.signal);
});

test('non-2xx and status!=1 give status-only errors', async () => {
    let s = stub(429, { status: 0, errors: [`bad token ${TOK}`] });
    await assert.rejects(createPushoverProvider({ fetchImpl: s.f }).send(conn(), msg(), {}), (e) => e instanceof NotifySendError && e.message === 'pushover returned HTTP 429');
    s = stub(200, { status: 0, errors: [`user ${USR}`] });
    await assert.rejects(createPushoverProvider({ fetchImpl: s.f }).send(conn(), msg(), {}), (e) => e instanceof NotifySendError && !e.message.includes(USR));
});

test('errors never contain secrets or URL (via attemptSend)', async () => {
    const f = async () => { throw new TypeError(`fetch failed https://api.pushover.net/?token=${TOK}&user=${USR}`); };
    const r = await attemptSend(createPushoverProvider({ fetchImpl: f }), conn(), msg(), undefined);
    assert.strictEqual(r.ok, false);
    for (const bad of [TOK, USR, 'pushover.net', 'https://']) assert.ok(!r.error.includes(bad), r.error);
    assert.match(r.error, /TypeError/);
});
