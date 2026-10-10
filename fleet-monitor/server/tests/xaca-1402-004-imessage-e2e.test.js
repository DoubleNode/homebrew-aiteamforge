//
//  xaca-1402-004-imessage-e2e.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1402-004: the FM half (wireNotifyHub + queue + routes) and the Mac relay half
 * (client/imessage-relay.js) were built separately against a pinned contract. Here they
 * run against EACH OTHER over real HTTP on 127.0.0.1.
 *
 * Nothing real is touched: execFile is a stub (no osascript against Messages, no real send),
 * the only network peer is an in-process FM bound to 127.0.0.1:0, and every secret/recipient is
 * an obvious fake. The one real osascript use (darwin only) runs a PURE-RETURN script that
 * echoes argv, to prove the `--` argv layout survives the real osascript option parser.
 */

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const { execFile: realExecFile } = require('child_process');
const express = require('express');

const FLEET = 'fleet-' + crypto.randomBytes(8).toString('hex');
const SAVED = {
    a: process.env.FLEET_ADMIN_TOKEN, f: process.env.FLEET_AUTH_TOKEN,
    u: process.env.FLEET_MONITOR_URL, h: process.env.HOME,
};
process.env.FLEET_AUTH_TOKEN = FLEET;
delete process.env.FLEET_ADMIN_TOKEN;

const { wireNotifyHub } = require('../lib/notify-routes');
const { createImessageQueue, MAX_WAIT_S, TTL_MS } = require('../lib/notify-imessage-queue');
const { createDeliveryReceiptSink } = require('../lib/notify-imessage-routes');
const { createReceiptLog } = require('../lib/notify-receipts');
const relay = require('../../client/imessage-relay.js');

const RECIP = '+15550001234';
const KEY = crypto.randomBytes(32).toString('hex');
const HOSTILE_BODY = 'he said "hi"\\ \\" ; do shell script "x" & `id` $(id) \'q\' 😀 é\n-l oops\nline3\t--';

let dir, server, base, seq = 0;
before(async () => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1402-004-')); });
after(() => {
    if (server) server.close();
    fs.rmSync(dir, { recursive: true, force: true });
    for (const [k, v] of [['FLEET_ADMIN_TOKEN', SAVED.a], ['FLEET_AUTH_TOKEN', SAVED.f], ['FLEET_MONITOR_URL', SAVED.u], ['HOME', SAVED.h]]) {
        if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
});

/** A fresh FM (own queue/receipts/store) on a real loopback port. Returns helpers. */
async function startFm(connParams = {}, queueOpts = {}) {
    const id = ++seq;
    const logs = [];
    const logger = { log: (m) => logs.push(String(m)), warn: (m) => logs.push(String(m)), error: (m) => logs.push(String(m)) };
    const clock = queueOpts.clock || (() => Date.now());
    const receiptsFile = path.join(dir, `r-${id}.jsonl`);
    const receipts = createReceiptLog({ file: receiptsFile });
    const queue = createImessageQueue({ onSettle: createDeliveryReceiptSink(receipts, logger), ...queueOpts, clock });
    const app = express();
    app.use(express.json({ limit: '10mb' }));
    const hub = wireNotifyHub(app, {
        isRegisteredTeam: (t) => t === 'academy', logger,
        storeOpts: { file: path.join(dir, `s-${id}.json`), key: KEY },
        receiptOpts: { file: receiptsFile }, imessageQueue: queue, imessageSweepMs: 3600 * 1000,
    });
    hub.store.createConnection({ id: 'im-main', provider: 'imessage', label: 'Phone', params: { recipient: RECIP, ...connParams }, secrets: {} });
    hub.store.setTeamRoutes('academy', { config: { $schema: 'release-notify/v2', version: 2, routes: { 'pr-merged': ['im-main'] } } });
    const srv = await new Promise((res) => { const s = http.createServer(app); s.listen(0, '127.0.0.1', () => res(s)); });
    const url = `http://127.0.0.1:${srv.address().port}`;
    const hdr = { 'x-api-key': FLEET, 'content-type': 'application/json' };
    const call = async (method, p, body) => {
        const r = await fetch(url + p, { method, headers: hdr, body: body === undefined ? undefined : JSON.stringify(body) });
        const text = await r.text();
        let json = null; try { json = JSON.parse(text); } catch (_) { /* 204 */ }
        return { status: r.status, json, text };
    };
    return {
        url, queue, logs, receiptsFile, call, srv,
        notify: (over = {}) => call('POST', '/api/notify', { team: 'academy', type: 'pr-merged', title: 'T-e2e', body: 'B-e2e', ref: 'PR-' + (++seq), severity: 'high', ...over }),
        receipts: () => fs.readFileSync(receiptsFile, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)),
        close: () => new Promise((r) => { srv.closeAllConnections && srv.closeAllConnections(); srv.close(r); }),
    };
}

/** Real fetch with a recorder; `tweak(url, init)` may rewrite what is sent AFTER it is recorded. */
function recordingFetch(tweak) {
    const calls = [];
    const fn = async (url, init) => {
        const rec = { url, method: init.method, headers: { ...init.headers }, body: init.body ? JSON.parse(init.body) : null, redirect: init.redirect };
        calls.push(rec);
        const init2 = tweak ? tweak(rec, { ...init, headers: { ...init.headers } }) : init;
        const res = await fetch(url, init2);
        rec.status = res.status;
        return res;
    };
    fn.calls = calls;
    return fn;
}
const noWait = (rec, init) => { init.body = JSON.stringify({ ...rec.body, waitSeconds: 0 }); return init; };

function execStub(plan) {
    const sends = [];
    const probes = [];
    const fn = (file, args, opts, cb) => {
        const isProbe = args[1] === relay.PROBE_SCRIPT;
        (isProbe ? probes : sends).push({ file, args, opts });
        const r = (isProbe ? {} : plan && plan(args, sends.length)) || {};
        setImmediate(() => cb(r.err || null, isProbe ? '1\n' : (r.stdout || ''), r.stderr || ''));
    };
    fn.sends = sends; fn.probes = probes;
    return fn;
}

function relayDeps(machine, over = {}) {
    const logs = [];
    const deps = relay.makeDeps({
        execFile: over.execFile, fetch: over.fetch, log: (l) => logs.push(l), platform: 'darwin',
        sleep: over.sleep || (async () => {}), now: over.now, signal: over.signal,
    });
    return { deps, state: { base: over.base, machineId: machine, probe: null }, logs };
}

// ── 1. Happy path + seam checks ──────────────────────────────────────────────

describe('notify -> claim -> send -> ack -> delivered receipt', () => {
    test('relay and FM agree on URL, auth header, field names and the receipt trail', async () => {
        const fm = await startFm();
        try {
            const sent = await fm.notify({ title: 'Deploy done', body: HOSTILE_BODY });
            assert.equal(sent.status, 200, sent.text);
            const accepted = sent.json.receipts[0];
            assert.equal(accepted.stage, 'accepted');
            assert.equal(accepted.ok, true);

            const f = recordingFetch();
            const exec = execStub();
            const { deps, state } = relayDeps('mac-alpha', { execFile: exec, fetch: f, base: fm.url });
            const r = await relay.runCycle(deps, state);
            assert.equal(r.outcome, 'sent');
            assert.equal(r.jobId, accepted.providerMessageId);

            // SEAM: URL derivation, method, auth, field names.
            assert.equal(f.calls.length, 2);
            const [claim, ack] = f.calls;
            assert.equal(claim.url, `${fm.url}/api/notify/imessage/claim`);
            assert.equal(ack.url, `${fm.url}/api/notify/imessage/ack`);
            assert.equal(claim.method, 'POST');
            assert.equal(claim.headers.Authorization, `Bearer ${FLEET}`);
            assert.equal(claim.headers['Content-Type'], 'application/json');
            assert.equal(claim.redirect, 'manual');
            assert.deepEqual(claim.body, { machineId: 'mac-alpha', waitSeconds: 25 });
            assert.equal(claim.status, 200);
            assert.deepEqual(ack.body, { machineId: 'mac-alpha', jobId: accepted.providerMessageId, ok: true });
            assert.equal(ack.headers.Authorization, `Bearer ${FLEET}`);
            assert.equal(ack.status, 200);

            // The receipt trail: accepted then delivered, same providerMessageId.
            const mine = fm.receipts().filter((x) => x.providerMessageId === accepted.providerMessageId);
            assert.deepEqual(mine.map((x) => [x.stage, x.ok]), [['accepted', true], ['delivered', true]]);
            assert.equal(mine[1].provider, 'imessage');

            // Admin receipts endpoint (what the UI reads) shows the same.
            const list = await fm.call('GET', '/api/notify/receipts?team=academy');
            assert.equal(list.status, 200);
            assert.ok(list.json.receipts.some((x) => x.stage === 'delivered' && x.providerMessageId === accepted.providerMessageId));

            // Pool endpoint saw the relay.
            const pool = await fm.call('GET', '/api/notify/imessage/pool');
            assert.equal(pool.json.relays.find((x) => x.machineId === 'mac-alpha').lastAckOk, true);
            assert.equal(pool.json.queued + pool.json.leased, 0);
        } finally { await fm.close(); }
    });

    test('hostile text reaches execFile as ONE intact argv element after `--`; no shell, no interpolation', async () => {
        const fm = await startFm();
        try {
            const title = 'T "q" \\ \' 🚀';
            await fm.notify({ title, body: HOSTILE_BODY });
            const exec = execStub();
            const { deps, state } = relayDeps('mac-alpha', { execFile: exec, fetch: recordingFetch(), base: fm.url });
            assert.equal((await relay.runCycle(deps, state)).outcome, 'sent');
            assert.equal(exec.sends.length, 1);
            const s = exec.sends[0];
            assert.equal(s.file, '/usr/bin/osascript');
            assert.equal(s.args.length, 5);
            assert.deepEqual(s.args.slice(0, 3), ['-e', relay.SEND_SCRIPT, '--']);
            assert.equal(s.args[3], `[HIGH] ${title}\n${HOSTILE_BODY}`);
            assert.equal(s.args[4], RECIP);
            assert.ok(!relay.SEND_SCRIPT.includes('oops') && !relay.SEND_SCRIPT.includes(RECIP), 'script is constant');
            assert.equal(s.opts.shell, undefined);
        } finally { await fm.close(); }
    });

    test('a message over the 1000-character cap arrives truncated, intact and never split mid-emoji', async () => {
        const fm = await startFm();
        try {
            await fm.notify({ title: 'Long', body: '😀'.repeat(1500) });
            const exec = execStub();
            const { deps, state } = relayDeps('mac-alpha', { execFile: exec, fetch: recordingFetch(), base: fm.url });
            await relay.runCycle(deps, state);
            const text = exec.sends[0].args[3];
            assert.equal(Array.from(text).length, 1000);
            assert.ok(text.endsWith('…'));
            assert.ok(!/[\ud800-\udbff](?![\udc00-\udfff])/.test(text), 'no lone surrogate');
            assert.ok(!/[\udc00-\udfff]/.test(text.replace(/[\ud800-\udbff][\udc00-\udfff]/g, '')), 'no lone low surrogate');
        } finally { await fm.close(); }
    });

    test('relay timing contract: claim timeout exceeds the server max long-poll; waitSeconds is accepted by the server', () => {
        assert.equal(relay.WAIT_SECONDS, MAX_WAIT_S);
        assert.ok(relay.CLAIM_TIMEOUT_MS > MAX_WAIT_S * 1000, `claim timeout ${relay.CLAIM_TIMEOUT_MS} must exceed ${MAX_WAIT_S * 1000}`);
        assert.ok(relay.CLAIM_TIMEOUT_MS - MAX_WAIT_S * 1000 >= 5000, 'at least 5 s of margin for network latency');
    });

    test('resolveBase: the reporter-style FLEET_MONITOR_API (.../api/status) and FLEET_MONITOR_URL both resolve to the FM base', () => {
        const home = fs.mkdtempSync(path.join(dir, 'home-'));
        process.env.HOME = home; // no fleet-config candidates under the real home
        delete process.env.FLEET_MONITOR_URL;
        assert.equal(relay.resolveBase({ FLEET_MONITOR_API: 'http://127.0.0.1:4321/api/status' }), 'http://127.0.0.1:4321');
        process.env.FLEET_MONITOR_URL = 'http://127.0.0.1:4322/';
        assert.equal(relay.resolveBase({}), 'http://127.0.0.1:4322');
        delete process.env.FLEET_MONITOR_URL;
        process.env.HOME = SAVED.h;
    });
});

// ── 2. Failure, requeue, failover ────────────────────────────────────────────

describe('send failure -> ack ok:false -> requeue -> failover', () => {
    test('relay A fails; A is held off by the failover grace; relay B delivers; only one delivered receipt', async () => {
        const fm = await startFm();
        try {
            const sent = await fm.notify();
            const jobId = sent.json.receipts[0].providerMessageId;

            const fA = recordingFetch();
            const execA = execStub(() => ({ err: Object.assign(new Error('Command failed: osascript ... ' + RECIP), { code: 1, stderr: '' }) }));
            const a = relayDeps('mac-a', { execFile: execA, fetch: fA, base: fm.url });
            const r1 = await relay.runCycle(a.deps, a.state);
            assert.equal(r1.outcome, 'send_failed');
            const ackBody = fA.calls[1].body;
            assert.deepEqual(ackBody, { machineId: 'mac-a', jobId, ok: false, errorType: 'osascript_exit_1' });
            assert.equal(fA.calls[1].status, 200, 'server accepts the relay errorType');
            assert.ok(!fm.receipts().some((x) => x.stage === 'failed'), 'requeued, not failed');
            assert.ok(!JSON.stringify(a.logs).includes(RECIP), 'relay log never carries the recipient');

            // A immediately re-claims with a short wait: held off by the grace.
            const a2 = relayDeps('mac-a', { execFile: execStub(), fetch: recordingFetch(noWait), base: fm.url });
            assert.equal((await relay.runCycle(a2.deps, a2.state)).outcome, 'idle');

            const fB = recordingFetch();
            const execB = execStub();
            const b = relayDeps('mac-b', { execFile: execB, fetch: fB, base: fm.url });
            const r2 = await relay.runCycle(b.deps, b.state);
            assert.equal(r2.outcome, 'sent');
            assert.equal(r2.jobId, jobId);
            assert.equal(JSON.parse(JSON.stringify(fB.calls[0].body)).machineId, 'mac-b');

            const trail = fm.receipts().filter((x) => x.providerMessageId === jobId).map((x) => [x.stage, x.ok]);
            assert.deepEqual(trail, [['accepted', true], ['delivered', true]]);
        } finally { await fm.close(); }
    });

    test('three failures exhaust the attempts: a failed receipt carries the relay errorType and no payload', async () => {
        const fm = await startFm();
        try {
            const sent = await fm.notify({ title: 'SECRET-TITLE-xyz', body: 'SECRET-BODY-xyz' });
            const jobId = sent.json.receipts[0].providerMessageId;
            const mk = (id) => relayDeps(id, {
                execFile: execStub(() => ({ err: Object.assign(new Error('x'), { code: 1, stderr: 'execution error: Not authorised to send Apple events to Messages. (-1743)' }) })),
                fetch: recordingFetch(), base: fm.url,
            });
            for (const id of ['mac-a', 'mac-b', 'mac-a']) {
                const x = mk(id);
                assert.equal((await relay.runCycle(x.deps, x.state)).outcome, 'send_failed', id);
            }
            const trail = fm.receipts().filter((x) => x.providerMessageId === jobId);
            assert.deepEqual(trail.map((x) => [x.stage, x.ok]), [['accepted', true], ['failed', false]]);
            assert.match(trail[1].error, /not_authorized/);
            const blob = fs.readFileSync(fm.receiptsFile, 'utf8') + fm.logs.join('\n');
            for (const leak of [RECIP, 'SECRET-TITLE-xyz', 'SECRET-BODY-xyz', FLEET]) assert.ok(!blob.includes(leak), `leaked ${leak}`);
        } finally { await fm.close(); }
    });
});

// ── 3. Severity gate ─────────────────────────────────────────────────────────

describe('severity gate end to end', () => {
    test('below minSeverity: suppressed severity-gate receipt, nothing claimable, relay sees no job', async () => {
        const fm = await startFm();
        try {
            for (const severity of ['info', 'warning']) {
                const r = await fm.notify({ severity });
                if (r.status !== 200) continue; // a severity name this hub does not define is a 400, not a gate case
                assert.equal(r.json.receipts[0].suppressed, 'severity-gate', severity);
                assert.equal(r.json.receipts[0].ok, false);
            }
            const pool = await fm.call('GET', '/api/notify/imessage/pool');
            assert.equal(pool.json.queued + pool.json.leased, 0);
            const { deps, state } = relayDeps('mac-a', { execFile: execStub(), fetch: recordingFetch(noWait), base: fm.url });
            assert.equal((await relay.runCycle(deps, state)).outcome, 'idle');
            const listed = (await fm.call('GET', '/api/notify/receipts?team=academy')).json.receipts;
            assert.ok(listed.some((x) => x.suppressed === 'severity-gate'));
        } finally { await fm.close(); }
    });

    test('a notice with NO severity field is evaluated against the gate, not crashed or silently queued', async () => {
        const fm = await startFm();
        try {
            const r = await fm.call('POST', '/api/notify', { team: 'academy', type: 'pr-merged', title: 'T', body: 'B', ref: 'PR-nosev' });
            assert.equal(r.status, 200, r.text);
            const rec = r.json.receipts[0];
            assert.ok(rec.suppressed === 'severity-gate' || rec.stage === 'accepted', JSON.stringify(rec));
            const pool = await fm.call('GET', '/api/notify/imessage/pool');
            assert.equal(pool.json.queued, rec.stage === 'accepted' ? 1 : 0);
        } finally { await fm.close(); }
    });

    test('connection minSeverity=warning lets a warning notice through to the relay', async () => {
        const fm = await startFm({ minSeverity: 'warning' });
        try {
            const r = await fm.notify({ severity: 'warning' });
            assert.equal(r.json.receipts[0].stage, 'accepted');
            const { deps, state } = relayDeps('mac-a', { execFile: execStub(), fetch: recordingFetch(), base: fm.url });
            assert.equal((await relay.runCycle(deps, state)).outcome, 'sent');
        } finally { await fm.close(); }
    });
});

// ── 4. Auth failures and backoff ─────────────────────────────────────────────

describe('wrong or missing token', () => {
    const strip = (rec, init) => { delete init.headers.Authorization; return init; };
    const wrong = (rec, init) => { init.headers.Authorization = 'Bearer not-the-token'; return init; };

    for (const [label, tweak] of [['wrong token', wrong], ['no token', strip]]) {
        test(`${label}: FM answers 401 on claim and ack; relay reports error, sends nothing, and the 401 body leaks nothing`, async () => {
            const fm = await startFm();
            try {
                await fm.notify();
                const f = recordingFetch(tweak);
                const exec = execStub();
                const { deps, state, logs } = relayDeps('mac-a', { execFile: exec, fetch: f, base: fm.url });
                const r = await relay.runCycle(deps, state);
                assert.equal(r.outcome, 'error');
                assert.equal(f.calls[0].status, 401);
                assert.equal(exec.sends.length, 0);
                assert.ok(logs.some((l) => /claim http=401/.test(l)));
                const pool = await fm.call('GET', '/api/notify/imessage/pool');
                assert.equal(pool.json.queued, 1, 'job still waiting');
                // An unauthenticated ack is also refused.
                const ackRes = await fetch(`${fm.url}/api/notify/imessage/ack`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ machineId: 'mac-a', jobId: 'x', ok: true }) });
                assert.equal(ackRes.status, 401);
                assert.ok(!(await ackRes.text()).includes(FLEET));
            } finally { await fm.close(); }
        });
    }

    test('runLoop backs off exponentially on repeated 401 instead of tight-looping', async () => {
        const fm = await startFm();
        try {
            const f = recordingFetch(wrong);
            const ac = new AbortController();
            const sleeps = [];
            const deps = relay.makeDeps({
                execFile: execStub(), fetch: f, log: () => {}, platform: 'darwin', signal: ac.signal,
                sleep: async (ms) => { sleeps.push(ms); if (sleeps.length >= 4) ac.abort(); },
            });
            await relay.runLoop(deps, { resolveBase: () => fm.url, resolveMachineId: () => 'mac-a' });
            assert.deepEqual(sleeps, [5000, 10000, 20000, 40000]);
            assert.ok(f.calls.every((c) => c.status === 401));
            assert.equal(f.calls.length, 4, 'exactly one request per backoff step');
        } finally { await fm.close(); }
    });
});

// ── 5. Adversarial queue edges over real HTTP ────────────────────────────────

describe('queue edge cases through the wire', () => {
    test('concurrent claims from many machines: exactly one wins a single job', async () => {
        const fm = await startFm();
        try {
            await fm.notify();
            const ids = Array.from({ length: 12 }, (_, i) => `mac-${i}`);
            const rs = await Promise.all(ids.map((m) => fm.call('POST', '/api/notify/imessage/claim', { machineId: m, waitSeconds: 0 })));
            assert.equal(rs.filter((r) => r.status === 200).length, 1);
            assert.equal(rs.filter((r) => r.status === 204).length, 11);
        } finally { await fm.close(); }
    });

    test('concurrent claims with two jobs: two winners, distinct jobs', async () => {
        const fm = await startFm();
        try {
            await fm.notify(); await fm.notify();
            const rs = await Promise.all(['a', 'b', 'c', 'd'].map((m) => fm.call('POST', '/api/notify/imessage/claim', { machineId: `mac-${m}`, waitSeconds: 0 })));
            const won = rs.filter((r) => r.status === 200);
            assert.equal(won.length, 2);
            assert.notEqual(won[0].json.jobId, won[1].json.jobId);
        } finally { await fm.close(); }
    });

    test('duplicate ack: the second is 409 and does not add a second delivered receipt', async () => {
        const fm = await startFm();
        try {
            const sent = await fm.notify();
            const jobId = sent.json.receipts[0].providerMessageId;
            await fm.call('POST', '/api/notify/imessage/claim', { machineId: 'mac-a', waitSeconds: 0 });
            const a1 = await fm.call('POST', '/api/notify/imessage/ack', { machineId: 'mac-a', jobId, ok: true });
            const a2 = await fm.call('POST', '/api/notify/imessage/ack', { machineId: 'mac-a', jobId, ok: true });
            assert.equal(a1.status, 200);
            assert.equal(a2.status, 409);
            assert.equal(fm.receipts().filter((x) => x.stage === 'delivered').length, 1);
            // The relay treats that 409 as "drop", not as an error to retry.
            const f = recordingFetch();
            const { deps, state, logs } = relayDeps('mac-a', { fetch: f, base: fm.url });
            assert.equal(await relay.ackJob(deps, state, jobId, { ok: true }), 'dropped');
            assert.equal(f.calls.length, 1, 'no retry on 409');
            assert.ok(logs.some((l) => /lease_not_held/.test(l)));
        } finally { await fm.close(); }
    });

    test('ack after the job TTL: 409, a failed (ttl_expired) receipt, and no delivered receipt', async () => {
        const t = { now: Date.parse('2026-10-10T12:00:00Z') };
        const fm = await startFm({}, { clock: () => t.now });
        try {
            const sent = await fm.notify();
            const jobId = sent.json.receipts[0].providerMessageId;
            const c = await fm.call('POST', '/api/notify/imessage/claim', { machineId: 'mac-a', waitSeconds: 0 });
            assert.equal(c.status, 200);
            t.now += TTL_MS + 1000;
            const a = await fm.call('POST', '/api/notify/imessage/ack', { machineId: 'mac-a', jobId, ok: true });
            assert.equal(a.status, 409);
            const trail = fm.receipts().filter((x) => x.providerMessageId === jobId);
            assert.deepEqual(trail.map((x) => x.stage), ['accepted', 'failed']);
            assert.match(trail[1].error, /ttl_expired/);
        } finally { await fm.close(); }
    });

    test('ack after the lease expired and ANOTHER machine re-claimed: the late first holder gets 409, the new holder wins', async () => {
        const t = { now: Date.parse('2026-10-10T12:00:00Z') };
        const fm = await startFm({}, { clock: () => t.now });
        try {
            const sent = await fm.notify();
            const jobId = sent.json.receipts[0].providerMessageId;
            await fm.call('POST', '/api/notify/imessage/claim', { machineId: 'mac-a', waitSeconds: 0 });
            t.now += 61 * 1000;
            const c2 = await fm.call('POST', '/api/notify/imessage/claim', { machineId: 'mac-b', waitSeconds: 0 });
            assert.equal(c2.status, 200);
            assert.equal(c2.json.attempt, 2);
            const late = await fm.call('POST', '/api/notify/imessage/ack', { machineId: 'mac-a', jobId, ok: true });
            assert.equal(late.status, 409);
            const ok = await fm.call('POST', '/api/notify/imessage/ack', { machineId: 'mac-b', jobId, ok: true });
            assert.equal(ok.status, 200);
            assert.equal(fm.receipts().filter((x) => x.stage === 'delivered').length, 1);
        } finally { await fm.close(); }
    });

    test('pool allowlist excludes a machine over the wire: the excluded relay idles, the listed one delivers', async () => {
        const fm = await startFm({ pool: ['mac-allowed'] });
        try {
            await fm.notify();
            const out = relayDeps('mac-outsider', { execFile: execStub(), fetch: recordingFetch(noWait), base: fm.url });
            assert.equal((await relay.runCycle(out.deps, out.state)).outcome, 'idle');
            const inn = relayDeps('mac-allowed', { execFile: execStub(), fetch: recordingFetch(), base: fm.url });
            assert.equal((await relay.runCycle(inn.deps, inn.state)).outcome, 'sent');
        } finally { await fm.close(); }
    });

    test('a relay that disconnects mid long-poll is not handed a job enqueued afterwards', async () => {
        const fm = await startFm();
        try {
            const ac = new AbortController();
            const p = fetch(`${fm.url}/api/notify/imessage/claim`, { method: 'POST', headers: { 'x-api-key': FLEET, 'content-type': 'application/json' }, body: JSON.stringify({ machineId: 'mac-dead', waitSeconds: 20 }), signal: ac.signal }).catch(() => 'aborted');
            await new Promise((r) => setTimeout(r, 150));
            ac.abort();
            assert.equal(await p, 'aborted');
            await new Promise((r) => setTimeout(r, 100));
            await fm.notify();
            await new Promise((r) => setTimeout(r, 100));
            const pool = await fm.call('GET', '/api/notify/imessage/pool');
            assert.equal(pool.json.leased, 0, 'job must not be leased to a vanished client');
            assert.equal(pool.json.queued, 1);
        } finally { await fm.close(); }
    });

    test('the real relay long-poll (waitSeconds 25) wakes immediately when a job is enqueued mid-wait', async () => {
        const fm = await startFm();
        try {
            const f = recordingFetch();
            const { deps, state } = relayDeps('mac-a', { execFile: execStub(), fetch: f, base: fm.url });
            const t0 = Date.now();
            const cycle = relay.runCycle(deps, state);
            await new Promise((r) => setTimeout(r, 300));
            await fm.notify();
            const r = await cycle;
            assert.equal(r.outcome, 'sent');
            assert.equal(f.calls[0].body.waitSeconds, 25);
            assert.ok(Date.now() - t0 < 5000, 'woke by enqueue, not by the 25 s deadline');
        } finally { await fm.close(); }
    });

    test('shutdown mid long-poll: the relay returns idle and a later job is not leased to it', async () => {
        const fm = await startFm();
        try {
            const ac = new AbortController();
            const { deps, state } = relayDeps('mac-a', { execFile: execStub(), fetch: recordingFetch(), base: fm.url, signal: ac.signal });
            const cycle = relay.runCycle(deps, state);
            await new Promise((r) => setTimeout(r, 200));
            ac.abort();
            assert.equal((await cycle).outcome, 'idle');
            await new Promise((r) => setTimeout(r, 100));
            await fm.notify();
            await new Promise((r) => setTimeout(r, 100));
            const pool = await fm.call('GET', '/api/notify/imessage/pool');
            assert.equal(pool.json.leased, 0);
            assert.equal(pool.json.queued, 1);
        } finally { await fm.close(); }
    });

    test('malformed recipients are refused when the connection is created, without echoing them', async () => {
        const fm = await startFm();
        try {
            const bad = ['', ' +15550001234', '+15550001234 ', '5550001234', '+0555000123', '+1555', 'tel:+15550001234',
                'a@b', 'a b@c.com', 'a@c.com\nBcc: x@y.com', 'x'.repeat(250) + '@c.com', '+15550001234\n', '+1555000123456789012'];
            for (const recipient of bad) {
                const r = await fm.call('POST', '/api/notify/connections', { id: 'c-bad', provider: 'imessage', label: 'x', params: { recipient }, secrets: {} });
                assert.equal(r.status, 400, JSON.stringify(recipient));
                if (recipient.length > 3) assert.ok(!r.text.includes(recipient.trim()), 'recipient echoed');
            }
        } finally { await fm.close(); }
    });
});

// ── 6. Real osascript argv parsing (darwin, PURE-RETURN script, never Messages) ──

describe('osascript argv layout (real osascript, echo script only)', { skip: process.platform !== 'darwin' && 'needs macOS osascript' }, () => {
    const ECHO = 'on run argv\n\treturn ((count of argv) as text) & "|" & (item 1 of argv) & "|" & (item 2 of argv)\nend run';
    // Route the relay's real argv through a real osascript, but swap the SEND script (which would
    // talk to Messages) for the echo script. Everything else about the argv is the relay's own.
    const echoExec = (captured) => (file, args, opts, cb) => {
        const swapped = args.map((a) => (a === relay.SEND_SCRIPT ? ECHO : a));
        realExecFile(file, swapped, opts, (err, stdout, stderr) => { captured.push({ err, stdout }); cb(err, stdout, stderr); });
    };

    for (const text of ['plain', '-l oops', '--', '-e', 'a\nb "q" \\ \' $(id) 😀']) {
        test(`text ${JSON.stringify(text)} survives as argv item 1`, async () => {
            const cap = [];
            const r = await relay.sendMessage(echoExec(cap), text, '+15550001234');
            assert.equal(r.ok, true, JSON.stringify(cap[0] && cap[0].err && cap[0].err.code));
            assert.equal(cap[0].stdout.replace(/\n$/, ''), `2|${text}|+15550001234`);
        });
    }
});
