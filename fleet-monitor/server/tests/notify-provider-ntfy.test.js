'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { createNtfyProvider, DEFAULT_SERVER } = require('../lib/notify-providers/ntfy');
const { NotifyConfigError, NotifySendError, attemptSend } = require('../lib/notify-providers');

const TOPIC = 'secret-topic_42';
const TOKEN = 'tk_sekret_token';
const conn = (o = {}) => ({ id: 'c1', provider: 'ntfy', label: 'n', params: {}, secrets: { topic: TOPIC }, ...o });
const msg = (o = {}) => ({ team: 'academy', type: 't', title: 'Title', body: 'Body', ref: '', severity: 'info', ...o });
function stub(status = 200, json = { id: 'abc123' }) {
    const calls = [];
    const f = async (url, opts) => { calls.push({ url, opts, json: JSON.parse(opts.body) }); return { status, json: async () => json }; };
    return { f, calls };
}

test('priority mapping for all severities', async () => {
    const want = { info: 2, warning: 3, high: 4, critical: 5 };
    for (const [sev, p] of Object.entries(want)) {
        const { f, calls } = stub();
        await createNtfyProvider({ fetchImpl: f }).send(conn(), msg({ severity: sev }), {});
        assert.strictEqual(calls[0].json.priority, p);
        assert.ok(calls[0].json.tags.includes(sev));
    }
});

test('default server, JSON payload and providerMessageId', async () => {
    const { f, calls } = stub();
    const r = await createNtfyProvider({ fetchImpl: f }).send(conn(), msg({ ref: 'https://x.example/a' }), {});
    assert.strictEqual(calls[0].url, DEFAULT_SERVER + '/');
    assert.strictEqual(calls[0].opts.method, 'POST');
    assert.deepStrictEqual(
        { topic: calls[0].json.topic, title: calls[0].json.title, message: calls[0].json.message, click: calls[0].json.click },
        { topic: TOPIC, title: 'Title', message: 'Body', click: 'https://x.example/a' });
    assert.strictEqual(calls[0].opts.headers.Authorization, undefined);
    assert.deepStrictEqual(r, { providerMessageId: 'abc123' });
});

test('self-hosted https server is used', async () => {
    const { f, calls } = stub();
    await createNtfyProvider({ fetchImpl: f }).send(conn({ params: { server: 'https://ntfy.corp.example:8443' } }), msg(), {});
    assert.strictEqual(calls[0].url, 'https://ntfy.corp.example:8443/');
});

test('http server is rejected (validate and send)', async () => {
    const p = createNtfyProvider({ fetchImpl: async () => { throw new Error('must not fetch'); } });
    const c = conn({ params: { server: 'http://ntfy.local' } });
    assert.throws(() => p.validate(c), (e) => e instanceof NotifyConfigError && /server/.test(e.message) && !e.message.includes('ntfy.local'));
    await assert.rejects(p.send(c, msg(), {}), NotifySendError);
});

test('bearer token header', async () => {
    const { f, calls } = stub();
    await createNtfyProvider({ fetchImpl: f }).send(conn({ secrets: { topic: TOPIC, token: TOKEN } }), msg(), {});
    assert.strictEqual(calls[0].opts.headers.Authorization, `Bearer ${TOKEN}`);
});

test('validate failures name fields only', () => {
    const p = createNtfyProvider({});
    for (const topic of [undefined, '', 'has space', 'a/b', 'x'.repeat(65)]) {
        assert.throws(() => p.validate(conn({ secrets: { topic } })), (e) => e instanceof NotifyConfigError && /topic/.test(e.message) && (!topic || !e.message.includes(topic)));
    }
    assert.throws(() => p.validate(conn({ params: { server: 'not a url' } })), NotifyConfigError);
    assert.throws(() => p.validate(conn({ secrets: { topic: TOPIC, token: 5 } })), (e) => /token/.test(e.message));
    assert.doesNotThrow(() => p.validate(conn()));
});

test('topic is a secret field, server a param', () => {
    const p = createNtfyProvider({});
    assert.ok(p.secretFields.includes('topic') && p.secretFields.includes('token'));
    assert.deepStrictEqual(p.paramFields, ['server']);
});

test('abort signal is passed to fetch', async () => {
    const ac = new AbortController();
    let seen;
    const f = (url, opts) => new Promise((_, reject) => {
        seen = opts.signal;
        opts.signal.addEventListener('abort', () => reject(Object.assign(new Error(`aborted ${url} ${TOPIC}`), { name: 'AbortError' })));
    });
    const p = createNtfyProvider({ fetchImpl: f }).send(conn(), msg(), { signal: ac.signal });
    ac.abort();
    await assert.rejects(p, (e) => e instanceof NotifySendError && /AbortError/.test(e.message) && !e.message.includes(TOPIC));
    assert.strictEqual(seen, ac.signal);
});

test('non-2xx gives status-only error', async () => {
    const s = stub(403, { error: `forbidden ${TOPIC}` });
    await assert.rejects(createNtfyProvider({ fetchImpl: s.f }).send(conn(), msg(), {}), (e) => e instanceof NotifySendError && e.message === 'ntfy returned HTTP 403');
});

test('errors never contain topic, token or URL (via attemptSend)', async () => {
    const f = async () => { throw new TypeError(`fetch failed https://ntfy.sh/${TOPIC} ${TOKEN}`); };
    const c = conn({ secrets: { topic: TOPIC, token: TOKEN } });
    const r = await attemptSend(createNtfyProvider({ fetchImpl: f }), c, msg(), undefined);
    assert.strictEqual(r.ok, false);
    for (const bad of [TOPIC, TOKEN, 'ntfy.sh', 'https://']) assert.ok(!r.error.includes(bad), r.error);
});
