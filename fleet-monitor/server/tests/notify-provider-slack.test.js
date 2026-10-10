'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { NotifyConfigError, NotifySendError, attemptSend, createProviderRegistry } = require('../lib/notify-providers');
const { createSlackProvider, buildPayload, SEVERITY_COLORS } = require('../lib/notify-providers/slack');

const URL_OK = 'https://hooks.slack.com/services/T000/B000/SECRETXYZ';
const conn = (url = URL_OK) => ({ id: 'c1', provider: 'slack', label: 'L', params: {}, secrets: { webhookUrl: url } });
const msg = (o = {}) => ({ team: 'academy', type: 'release', title: 'Title', body: 'Body', ref: '', severity: 'info', ...o });

function stubFetch(result) {
    const calls = [];
    const fn = async (url, init) => {
        calls.push({ url, init });
        if (typeof result === 'function') return result(url, init);
        return result || { ok: true, status: 200 };
    };
    fn.calls = calls;
    return fn;
}

test('registers cleanly and declares webhookUrl as secret', () => {
    const p = createSlackProvider();
    createProviderRegistry().register('slack', p);
    assert.deepEqual(p.secretFields, ['webhookUrl']);
    assert.deepEqual(p.paramFields, []);
});

test('send posts Block Kit payload in an attachment with fallback text', async () => {
    const f = stubFetch();
    const p = createSlackProvider({ fetchImpl: f });
    const r = await p.send(conn(), msg({ ref: 'https://example.com/pr/1' }), { signal: new AbortController().signal });
    assert.deepEqual(r, {});
    assert.equal(f.calls.length, 1);
    assert.equal(f.calls[0].url, URL_OK);
    assert.equal(f.calls[0].init.method, 'POST');
    assert.ok(f.calls[0].init.signal);
    const body = JSON.parse(f.calls[0].init.body);
    assert.equal(body.text, 'Title\nBody');
    const [att] = body.attachments;
    assert.equal(att.color, SEVERITY_COLORS.info);
    assert.deepEqual(att.blocks.map((b) => b.type), ['header', 'section', 'context']);
    assert.equal(att.blocks[0].text.text, 'Title');
    assert.equal(att.blocks[1].text.text, 'Body');
    assert.match(att.blocks[2].elements[0].text, /academy \| release \| info/);
    assert.match(att.blocks[2].elements[1].text, /^<https:\/\/example\.com\/pr\/1\|/);
});

test('colour per severity, unknown severity falls back to info', () => {
    for (const sev of ['info', 'warning', 'high', 'critical']) {
        assert.equal(buildPayload(msg({ severity: sev })).attachments[0].color, SEVERITY_COLORS[sev]);
    }
    assert.equal(new Set(Object.values(SEVERITY_COLORS)).size, 4);
    assert.equal(buildPayload(msg({ severity: 'bogus' })).attachments[0].color, SEVERITY_COLORS.info);
});

test('truncates to Slack limits and escapes mrkdwn', () => {
    const p = buildPayload(msg({ title: 'T'.repeat(500), body: 'B'.repeat(5000) }));
    const [h, s] = p.attachments[0].blocks;
    assert.equal(Array.from(h.text.text).length, 150);
    assert.ok(h.text.text.endsWith('…'));
    assert.equal(Array.from(s.text.text).length, 3000);
    assert.ok(p.text.length <= 3000);
    const e = buildPayload(msg({ body: '<!channel> a & b' }));
    assert.equal(e.attachments[0].blocks[1].text.text, '&lt;!channel&gt; a &amp; b');
});

test('empty body omits section; non-URL ref is plain text; empty title handled', () => {
    const p = buildPayload(msg({ body: '  ', ref: 'XACA-1', title: '' }));
    const blocks = p.attachments[0].blocks;
    assert.deepEqual(blocks.map((b) => b.type), ['header', 'context']);
    assert.equal(blocks[0].text.text, '(no title)');
    assert.equal(blocks[1].elements[1].text, 'ref: XACA-1');
});

test('validate failures are field-name only and never echo the value', () => {
    const p = createSlackProvider();
    const bad = [
        undefined, '', '   ', 'not a url',
        'http://hooks.slack.com/services/T/B/X',
        'https://evil.example.com/services/T/B/X',
        'https://hooks.slack.com.evil.com/services/T/B/X',
        'https://user:pw@hooks.slack.com/services/T/B/X',
        'https://hooks.slack.com:8443/services/T/B/X',
        'https://hooks.slack.com/other/T/B/X',
        'https://hooks.slack.com/services/',
    ];
    for (const u of bad) {
        assert.throws(() => p.validate({ id: 'c', secrets: { webhookUrl: u } }), (e) => {
            assert.ok(e instanceof NotifyConfigError);
            assert.match(e.message, /webhookUrl/);
            if (typeof u === 'string' && u.trim()) assert.ok(!e.message.includes(u));
            return true;
        }, String(u));
    }
    assert.doesNotThrow(() => p.validate(conn()));
    assert.throws(() => p.validate({ secrets: {} }), NotifyConfigError);
});

test('non-2xx yields status code only', async () => {
    const p = createSlackProvider({ fetchImpl: stubFetch({ ok: false, status: 404, text: async () => URL_OK }) });
    await assert.rejects(p.send(conn(), msg(), {}), (e) => {
        assert.ok(e instanceof NotifySendError);
        assert.match(e.message, /404/);
        assert.ok(!e.message.includes('SECRETXYZ') && !e.message.includes('hooks.slack.com'));
        return true;
    });
});

test('network error records type only, never the URL', async () => {
    const f = stubFetch(() => { throw new TypeError(`fetch failed ${URL_OK}`); });
    const p = createSlackProvider({ fetchImpl: f });
    await assert.rejects(p.send(conn(), msg(), {}), (e) => {
        assert.ok(e instanceof NotifySendError);
        assert.match(e.message, /TypeError/);
        assert.ok(!e.message.includes('SECRETXYZ') && !e.message.includes('hooks.slack.com'));
        return true;
    });
});

test('abort is honoured', async () => {
    const ac = new AbortController();
    const f = (url, init) => new Promise((_, reject) => {
        init.signal.addEventListener('abort', () => reject(new Error(`aborted ${url}`)), { once: true });
    });
    const p = createSlackProvider({ fetchImpl: f });
    const pending = p.send(conn(), msg(), { signal: ac.signal });
    ac.abort();
    await assert.rejects(pending, (e) => {
        assert.ok(e instanceof NotifySendError);
        assert.match(e.message, /aborted/);
        assert.ok(!e.message.includes('hooks.slack.com'));
        return true;
    });
});

test('attemptSend end-to-end: no URL in any outcome', async () => {
    const p = createSlackProvider({ fetchImpl: stubFetch({ ok: false, status: 500 }) });
    const r = await attemptSend(p, conn(), msg(), new AbortController().signal);
    assert.equal(r.ok, false);
    assert.ok(!r.error.includes('SECRETXYZ'));
    const ok = await attemptSend(createSlackProvider({ fetchImpl: stubFetch() }), conn(), msg(), undefined);
    assert.deepEqual(ok, { ok: true, error: '' });
    const inv = await attemptSend(p, conn('http://x'), msg(), undefined);
    assert.equal(inv.ok, false);
});
