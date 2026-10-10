//
//  notify-provider-imessage.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/** XACA-1402-002: the FM-side imessage provider (validate + enqueue; never waits for delivery). */

const test = require('node:test');
const assert = require('node:assert/strict');
const { createImessageProvider, formatText, MAX_TEXT } = require('../lib/notify-providers/imessage');
const { createImessageQueue } = require('../lib/notify-imessage-queue');
const { NotifyConfigError, NotifySendError, attemptSend, defaultRegistry } = require('../lib/notify-providers');

const PHONE = '+15551234567';
const conn = (params = {}) => ({ id: 'im-1', provider: 'imessage', label: 'L', params: { recipient: PHONE, ...params }, secrets: {} });
const msg = (o = {}) => ({ team: 'academy', type: 'pr-merged', title: 'Build broke', body: 'details here', ref: 'PR-1', severity: 'high', ...o });

function fresh() {
    const queue = createImessageQueue();
    return { queue, provider: createImessageProvider({ queue }) };
}

test('shape: no secrets, async delivery, default gate high', () => {
    const { provider } = fresh();
    assert.deepEqual(provider.secretFields, []);
    assert.deepEqual(provider.paramFields, ['recipient', 'minSeverity', 'pool']);
    assert.equal(provider.asyncDelivery, true);
    assert.equal(provider.defaultMinSeverity, 'high');
    assert.ok(defaultRegistry().has('imessage'));
});

test('validate accepts E.164 and Apple ID email', () => {
    const { provider } = fresh();
    for (const r of ['+15551234567', '+442071838750', '+12345678', 'me@icloud.com', 'a.b+c@example.co.uk']) {
        assert.doesNotThrow(() => provider.validate(conn({ recipient: r })), r);
    }
});

test('validate rejects bad recipients with a message that does not echo them', () => {
    const { provider } = fresh();
    const bads = ['', ' +15551234567', '5551234567', '+0555123456', '+1234567', '+1234567890123456', 'a@b', 'me@icloud.com\nBcc:x@y.zz',
        'two words@icloud.com', undefined, null, 42, {}, ['+15551234567'], 'x'.repeat(300) + '@a.com'];
    for (const r of bads) {
        const c = conn(); c.params.recipient = r;
        assert.throws(() => provider.validate(c), (e) => e instanceof NotifyConfigError && /recipient/.test(e.message)
            && (typeof r !== 'string' || r.length < 4 || !e.message.includes(r)), String(r));
    }
    assert.throws(() => provider.validate({ id: 'x', params: undefined }), NotifyConfigError);
});

test('validate minSeverity and pool', () => {
    const { provider } = fresh();
    for (const s of ['info', 'warning', 'high', 'critical', undefined, '']) assert.doesNotThrow(() => provider.validate(conn({ minSeverity: s })));
    for (const s of ['HIGH', 'urgent', 3, {}]) assert.throws(() => provider.validate(conn({ minSeverity: s })), NotifyConfigError);
    assert.doesNotThrow(() => provider.validate(conn({ pool: ['m3pro', 'M4Mini.local'] })));
    assert.doesNotThrow(() => provider.validate(conn({ pool: Array.from({ length: 32 }, (_, i) => `m${i}`) })));
    for (const p of ['m1', [1], ['-bad'], ['has space'], ['a/b'], Array.from({ length: 33 }, (_, i) => `m${i}`), [{}]]) {
        assert.throws(() => provider.validate(conn({ pool: p })), NotifyConfigError, JSON.stringify(p));
    }
});

test('send enqueues and returns the job id immediately', async () => {
    const { queue, provider } = fresh();
    const r = await provider.send(conn(), msg());
    assert.match(r.providerMessageId, /^im-[0-9a-f]{16}$/);
    assert.equal(queue.pool().queued, 1);
    const job = queue.claim('m1');
    assert.equal(job.jobId, r.providerMessageId);
    assert.equal(job.recipient, PHONE);
    assert.equal(job.text, '[HIGH] Build broke\ndetails here');
});

test('send honours the pool allowlist', async () => {
    const { queue, provider } = fresh();
    await provider.send(conn({ pool: ['only-me'] }), msg());
    assert.equal(queue.claim('other'), null);
    assert.ok(queue.claim('only-me'));
});

test('text: severity prefix, no body, and the 1000-character cap with an ellipsis', () => {
    assert.equal(formatText(msg({ body: '' })), '[HIGH] Build broke');
    assert.equal(formatText(msg({ severity: 'critical', title: ' t ', body: ' b ' })), '[CRITICAL] t\nb');
    const long = formatText(msg({ body: 'x'.repeat(5000) }));
    assert.equal(Array.from(long).length, MAX_TEXT);
    assert.ok(long.endsWith('…'));
    const emoji = formatText(msg({ title: 'T', body: '😀'.repeat(2000) }));
    assert.equal(Array.from(emoji).length, MAX_TEXT);
    assert.ok(!/[\ud800-\udbff]$/.test(emoji.slice(0, -1)), 'no split surrogate');
});

test('a full queue is a NotifySendError with a fixed message', async () => {
    const queue = createImessageQueue({ maxActive: 1 });
    const provider = createImessageProvider({ queue });
    await provider.send(conn(), msg());
    await assert.rejects(provider.send(conn(), msg()), (e) => e instanceof NotifySendError && e.message === 'imessage queue is full');
});

test('send re-validates (defence in depth) and attemptSend never leaks the recipient', async () => {
    const { provider } = fresh();
    const bad = conn({ recipient: 'secret-bad-recipient' });
    await assert.rejects(provider.send(bad, msg()), NotifyConfigError);
    const out = await attemptSend(provider, bad, msg(), undefined);
    assert.equal(out.ok, false);
    assert.ok(!out.error.includes('secret-bad-recipient'));
});

test('a fresh provider without an injected queue gets its own (no shared singleton)', async () => {
    const a = createImessageProvider();
    const b = createImessageProvider();
    await a.send(conn(), msg());
    assert.equal(a.queue.pool().queued, 1);
    assert.equal(b.queue.pool().queued, 0);
});

test('receipts: stage is allowlisted and severity-gate is a known suppressed reason', () => {
    const { createReceiptLog, STAGES, SUPPRESSED_REASONS } = require('../lib/notify-receipts');
    const log = createReceiptLog({ file: require('path').join(require('os').tmpdir(), `imsg-r-${process.pid}.jsonl`) });
    assert.deepEqual(STAGES, ['accepted', 'delivered', 'failed']);
    assert.ok(SUPPRESSED_REASONS.includes('severity-gate'));
    assert.equal(log.newReceipt({ stage: 'delivered', ok: true }).stage, 'delivered');
    assert.ok(!('stage' in log.newReceipt({ stage: 'bogus' })));
    assert.equal(log.newReceipt({ suppressed: 'severity-gate' }).suppressed, 'severity-gate');
});
