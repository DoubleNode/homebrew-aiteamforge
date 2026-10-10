'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { NotifyConfigError, NotifySendError, createProviderRegistry, attemptSend } = require('../lib/notify-providers');
const { createTeamsProvider, buildPayload, renderText } = require('../lib/notify-providers/teams');

const URL_SECRET = 'https://prod-12.westus.logic.azure.com/workflows/abc123SECRETsig?sig=TOPSECRET';
const conn = (over = {}) => ({
    id: 'c1', provider: 'teams', label: 'L',
    params: { shape: 'flow' }, secrets: { webhookUrl: URL_SECRET }, ...over,
});
const msg = { team: 'academy', type: 'x', title: 'Build done', body: 'All green', ref: '', severity: 'info' };

function stub(response) {
    const calls = [];
    const fetchImpl = async (url, opts) => {
        calls.push({ url, opts });
        if (response instanceof Error) throw response;
        return response;
    };
    return { calls, fetchImpl };
}
const ok = (headers = {}) => ({ status: 200, headers: new Headers(headers) });

test('registers with the provider registry', () => {
    const reg = createProviderRegistry();
    reg.register('teams', createTeamsProvider());
    assert.deepEqual(reg.get('teams').secretFields, ['webhookUrl']);
    assert.deepEqual(reg.get('teams').paramFields, ['shape']);
});

test('flow shape payload matches Python parity (Adaptive Card 1.4 envelope)', async () => {
    const s = stub(ok());
    await createTeamsProvider({ fetchImpl: s.fetchImpl }).send(conn(), msg, { signal: undefined });
    assert.equal(s.calls[0].url, URL_SECRET);
    assert.equal(s.calls[0].opts.method, 'POST');
    assert.equal(s.calls[0].opts.redirect, 'manual');
    assert.equal(s.calls[0].opts.headers['Content-Type'], 'application/json');
    assert.deepEqual(JSON.parse(s.calls[0].opts.body), {
        type: 'message',
        attachments: [{
            contentType: 'application/vnd.microsoft.card.adaptive',
            contentUrl: null,
            content: {
                $schema: 'http://adaptivecards.io/schemas/adaptive-card.json',
                type: 'AdaptiveCard',
                version: '1.4',
                body: [{ type: 'TextBlock', text: 'Build done\n\nAll green\n\nacademy · x', wrap: true }],
            },
        }],
    });
});

test('webhook shape payload is {text}', async () => {
    const s = stub(ok());
    await createTeamsProvider({ fetchImpl: s.fetchImpl }).send(conn({ params: { shape: 'webhook' } }), msg, {});
    assert.deepEqual(JSON.parse(s.calls[0].opts.body), { text: 'Build done\n\nAll green\n\nacademy · x' });
});

test('shape defaults to flow when absent', async () => {
    const s = stub(ok());
    const c = conn({ params: {} });
    const p = createTeamsProvider({ fetchImpl: s.fetchImpl });
    p.validate(c);
    await p.send(c, msg, {});
    assert.equal(JSON.parse(s.calls[0].opts.body).type, 'message');
});

test('severity rendering', () => {
    assert.equal(renderText({ ...msg, severity: 'info' }), 'Build done\n\nAll green\n\nacademy · x');
    assert.equal(renderText({ ...msg, severity: 'warning' }), '[WARNING] Build done\n\nAll green\n\nacademy · x');
    assert.equal(renderText({ ...msg, severity: 'critical', body: '' }), '[CRITICAL] Build done\n\nacademy · x');
    assert.equal(renderText({ title: 'T', body: 'B', ref: 'PR-77' }), 'T\n\nB\n\nPR-77');
    assert.equal(renderText({ title: 'T', body: 'B' }), 'T\n\nB', 'no context fields -> no context line');
    assert.deepEqual(buildPayload('webhook', 'x'), { text: 'x' });
});

test('validate failures name the field, never the value', () => {
    const p = createTeamsProvider();
    const bad = [
        conn({ secrets: {} }),
        conn({ secrets: { webhookUrl: 'http://insecure.example.com/hook?sig=NOPE' } }),
        conn({ secrets: { webhookUrl: 'not a url SECRETVAL' } }),
        conn({ params: { shape: 'cardx' } }),
        { id: 'x', provider: 'teams', params: {}, secrets: {} },
    ];
    for (const c of bad) {
        assert.throws(() => p.validate(c), (e) => {
            assert.ok(e instanceof NotifyConfigError);
            assert.match(e.message, /shape|webhookUrl/);
            assert.doesNotMatch(e.message, /NOPE|SECRETVAL|cardx|insecure/);
            return true;
        });
    }
    assert.doesNotThrow(() => p.validate(conn()));
    assert.doesNotThrow(() => p.validate(conn({ params: { shape: 'webhook' } })));
});

test('providerMessageId from response headers, omitted otherwise', async () => {
    const p1 = createTeamsProvider({ fetchImpl: stub(ok({ 'x-ms-workflow-run-id': 'run-1' })).fetchImpl });
    assert.deepEqual(await p1.send(conn(), msg, {}), { providerMessageId: 'run-1' });
    const p2 = createTeamsProvider({ fetchImpl: stub(ok({ 'x-ms-request-id': 'req-9' })).fetchImpl });
    assert.deepEqual(await p2.send(conn(), msg, {}), { providerMessageId: 'req-9' });
    const p3 = createTeamsProvider({ fetchImpl: stub(ok()).fetchImpl });
    assert.deepEqual(await p3.send(conn(), msg, {}), {});
});

test('non-2xx (incl. 3xx under manual redirect) -> NotifySendError with status only', async () => {
    for (const status of [202, 302, 400, 429, 500]) {
        const p = createTeamsProvider({ fetchImpl: stub({ status, headers: new Headers() }).fetchImpl });
        if (status === 202) { await p.send(conn(), msg, {}); continue; }
        await assert.rejects(p.send(conn(), msg, {}), (e) => {
            assert.ok(e instanceof NotifySendError);
            assert.equal(e.message, `teams returned HTTP ${status}`);
            return true;
        });
    }
});

test('network error -> error type only, no URL/secret/foreign text', async () => {
    const foreign = new TypeError(`fetch failed for ${URL_SECRET} TOPSECRET`);
    const p = createTeamsProvider({ fetchImpl: stub(foreign).fetchImpl });
    await assert.rejects(p.send(conn(), msg, {}), (e) => {
        assert.ok(e instanceof NotifySendError);
        assert.equal(e.message, 'teams transport error (TypeError)');
        assert.doesNotMatch(e.message, /TOPSECRET|logic\.azure|abc123/);
        return true;
    });
});

test('signal is passed to fetch and abort is honoured', async () => {
    const ac = new AbortController();
    const fetchImpl = (url, opts) => new Promise((_res, rej) => {
        assert.equal(opts.signal, ac.signal);
        opts.signal.addEventListener('abort', () => {
            const e = new Error(`aborted ${url}`); e.name = 'AbortError'; rej(e);
        }, { once: true });
    });
    const p = createTeamsProvider({ fetchImpl });
    const pending = p.send(conn(), msg, { signal: ac.signal });
    ac.abort();
    await assert.rejects(pending, (e) => {
        assert.ok(e instanceof NotifySendError);
        assert.equal(e.message, 'teams transport error (AbortError)');
        assert.doesNotMatch(e.message, /TOPSECRET|logic\.azure/);
        return true;
    });
});

test('attemptSend surfaces only safe text end to end', async () => {
    const p = createTeamsProvider({ fetchImpl: stub(new Error(URL_SECRET)).fetchImpl });
    const r = await attemptSend(p, conn(), msg, undefined);
    assert.equal(r.ok, false);
    assert.doesNotMatch(r.error, /TOPSECRET|logic\.azure/);
    const bad = await attemptSend(p, conn({ secrets: { webhookUrl: 'http://x.example/TOPSECRET' } }), msg, undefined);
    assert.equal(bad.ok, false);
    assert.doesNotMatch(bad.error, /TOPSECRET/);
});

test('webhookUrl host allowlist: Microsoft endpoints only (XACA-1401 user decision)', () => {
    const p = createTeamsProvider({ fetchImpl: stub(ok()).fetchImpl });
    for (const good of [
        'https://prod-12.westus.logic.azure.com/workflows/x',
        'https://contoso.webhook.office.com/webhookb2/x',
        'https://prod-00.api.powerplatform.com/powerautomate/x',
        'https://x.powerautomate.com/x',
    ]) p.validate(conn({ secrets: { webhookUrl: good } }));
    for (const bad of [
        'https://anything.example.org/x',
        'https://logic.azure.com/x',
        'https://evil-logic.azure.com.attacker.example/x',
        'https://xlogic.azure.com/x',
        'https://u:p@prod.logic.azure.com/x',
        'https://prod.logic.azure.com:8443/x',
    ]) {
        assert.throws(() => p.validate(conn({ secrets: { webhookUrl: bad } })),
            (e) => e instanceof NotifyConfigError && !e.message.includes(bad), bad);
    }
});
