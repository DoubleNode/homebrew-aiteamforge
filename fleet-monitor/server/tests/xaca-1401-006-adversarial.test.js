//
//  xaca-1401-006-adversarial.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1401-006 -- adversarial pass over the five notify providers
 * (teams, slack, email, pushover, ntfy): end-to-end secret leakage through the
 * real store + dispatcher + routes, abort/timeout, fail-closed validation,
 * payload integrity, Teams parity with kanban-hooks/release_notify_teams.py.
 * No real network: fetch is stubbed, email uses an injected transport (the one
 * exception is a loopback-only TCP server that proves an aborted SMTP send
 * really closes its socket).
 */

const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const net = require('net');
const { execFileSync } = require('child_process');
const H = require('./xaca-1400-007-helpers');
const {
    request, fs, adm, pushRoutes, notice, post, rand, sleep, assertNoLeak, makeHarness, captureConsole,
    NotifyConfigError,
} = H;
const { createTeamsProvider, buildPayload: teamsPayload } = require('../lib/notify-providers/teams');
const { createSlackProvider, buildPayload: slackPayload } = require('../lib/notify-providers/slack');
const { createEmailProvider } = require('../lib/notify-providers/email');
const { createPushoverProvider } = require('../lib/notify-providers/pushover');
const { createNtfyProvider } = require('../lib/notify-providers/ntfy');

after(() => { H.restoreEnv(); H.cleanup(); });

const SEVS = ['info', 'warning', 'high', 'critical'];

// ---------------------------------------------------------------------------
// Per-provider fixtures
// ---------------------------------------------------------------------------
const SPECS = {
    teams: {
        params: { shape: 'flow' },
        secrets: { webhookUrl: 'https://prod-01.westus.logic.azure.com/workflows/WFSECRET123/triggers/manual?sig=SIGSECRET456' },
        ignore: ['flow'],
    },
    slack: {
        params: {},
        secrets: { webhookUrl: 'https://hooks.slack.com/services/T0AAA/B0BBB/SLACKSECRET789' },
    },
    email: {
        params: { host: 'smtp.corp-zq.example', port: 587, from: 'ops-sender@corp-zq.example', to: 'rcpt-one@corp-zq.example' },
        secrets: { user: 'smtpuser-zq', pass: 'smtppass-zq' },
    },
    pushover: {
        params: { device: 'pixel-secretdev' },
        secrets: { appToken: 'APPTOKENSECRET1', userKey: 'USERKEYSECRET2' },
    },
    ntfy: {
        params: { server: 'https://ntfy.corp-zq.example' },
        secrets: { topic: 'topic-secret-abc', token: 'tk_secrettoken9' },
    },
};

function needlesOf(name) {
    const s = SPECS[name];
    const out = [];
    for (const o of [s.secrets, s.params]) {
        for (const v of Object.values(o)) if (typeof v === 'string' && v.length > 4 && !(s.ignore || []).includes(v)) out.push(v);
    }
    if (name === 'teams') out.push('WFSECRET123', 'SIGSECRET456');
    if (name === 'slack') out.push('SLACKSECRET789');
    return out;
}

/** Build a provider wired to a controllable `io` stub. */
function build(name, io) {
    const fetchImpl = (url, opts) => { io.requests.push({ url, opts }); return io.fetchBehavior(url, opts); };
    switch (name) {
    case 'teams': return createTeamsProvider({ fetchImpl });
    case 'slack': return createSlackProvider({ fetchImpl });
    case 'pushover': return createPushoverProvider({ fetchImpl });
    case 'ntfy': return createNtfyProvider({ fetchImpl });
    case 'email':
        return createEmailProvider({
            createTransport: (opts) => {
                io.transportOpts = opts;
                return {
                    sendMail: (mail) => { io.mails.push(mail); return io.mailBehavior(mail); },
                    close: () => { io.closed += 1; },
                };
            },
        });
    default: throw new Error('bad provider');
    }
}
const newIo = () => ({ requests: [], mails: [], closed: 0, transportOpts: null,
    fetchBehavior: async () => ({ status: 200, ok: true, headers: new Headers(), json: async () => ({ status: 1, request: 'r1', id: 'i1' }) }),
    mailBehavior: async () => ({ messageId: '<m@x>' }) });

function harnessFor(name, io, dispatcherOpts) {
    const h = makeHarness({ providers: [build(name, io)], dispatcherOpts });
    const spec = SPECS[name];
    h.store.createConnection({ id: 'c1', provider: name, label: 'c1', params: { ...spec.params }, secrets: { ...spec.secrets } });
    return h;
}
async function route(h) {
    const r = await pushRoutes(h, 'team-a', { 'pr-merged': ['c1'] });
    assert.equal(r.status, 200);
}

// ===========================================================================
describe('1. no secret leak end-to-end (store + dispatcher + routes)', () => {
    const NAME_ENC = (all) => all.map((n) => encodeURIComponent(n));
    const fetchModes = (all) => ({
        http500: async () => ({ status: 500, ok: false, headers: new Headers(), json: async () => ({ status: 0, errors: all }) }),
        http404: async () => ({ status: 404, ok: false, headers: new Headers(), text: async () => all.join(' ') }),
        http302: async () => ({ status: 302, ok: false, headers: new Headers({ location: all[0] }) }),
        http200BadBody: async () => ({ status: 200, ok: true, headers: new Headers(), json: async () => ({ status: 0, errors: all }) }),
        jsonThrows: async () => ({ status: 200, ok: true, headers: new Headers(), json: async () => { throw new SyntaxError(`bad json ${all.join(' ')}`); } }),
        foreignError: async () => { throw new TypeError(`fetch failed ${all.join(' ')}`, { cause: new Error(all.join(' ')) }); },
        foreignString: async () => { throw `boom ${all.join(' ')}`; }, // eslint-disable-line no-throw-literal
        foreignNameEncoded: async () => { const e = new Error('x'); e.name = `Err:${NAME_ENC(all).join(':')}`; throw e; },
        abortError: async () => { throw new DOMException(`aborted ${all.join(' ')}`, 'AbortError'); },
        nullThrow: async () => { throw null; }, // eslint-disable-line no-throw-literal
    });
    const mailModes = (all) => ({
        reject: async () => { const e = new Error(`535 auth failed for ${all.join(' ')}`); e.code = 'EAUTH'; e.response = all.join(' '); throw e; },
        rejectString: async () => { throw `bad ${all.join(' ')}`; }, // eslint-disable-line no-throw-literal
        rejectNull: async () => { throw null; }, // eslint-disable-line no-throw-literal
        syncThrow: () => { throw new Error(`sync ${all.join(' ')}`); },
    });

    for (const name of Object.keys(SPECS)) {
        const all = needlesOf(name);
        const modes = name === 'email' ? mailModes(all) : fetchModes(all);
        for (const [mode, behavior] of Object.entries(modes)) {
            // Teams/Slack never read the response body, so a 200 is a success there.
            if (['teams', 'slack', 'ntfy'].includes(name) && ['http200BadBody', 'jsonThrows'].includes(mode)) continue;
            test(`${name} / ${mode}: receipt, response, console, connection views carry no secret/param/title/body`, async () => {
                const io = newIo();
                if (name === 'email') io.mailBehavior = behavior; else io.fetchBehavior = behavior;
                const h = harnessFor(name, io);
                await route(h);
                const TITLE = 'TITLE-' + rand(); const BODY = 'BODY-' + rand();
                const cap = captureConsole();
                let r; let conns; let rec;
                try {
                    r = await post(h, notice({ title: TITLE, body: BODY, ref: 'REF-' + rand(4) }));
                    conns = await adm(request(h.app).get('/api/notify/connections'));
                    rec = await adm(request(h.app).get('/api/notify/receipts?limit=50'));
                } finally { cap.restore(); }
                assert.equal(r.status, 200);
                assert.equal(r.body.ok, false);
                assert.equal(r.body.failed, 1);
                assert.ok(r.body.receipts[0].error.length > 0, 'failure must carry a non-empty error');
                const needles = [...all, ...NAME_ENC(all), TITLE, BODY];
                // The connections view legitimately lists non-secret params; secrets must still never appear.
                assertNoLeak(assert, [['connections view', conns.text]], Object.values(SPECS[name].secrets));
                assertNoLeak(assert, [
                    ['response', r.text], ['receipts endpoint', rec.text],
                    ['receipt file', fs.readFileSync(h.receiptFile, 'utf8')], ['console', cap.lines.join('\n')],
                ], needles);
            });
        }
    }

    test('stored secrets are encrypted at rest for every provider (no plaintext in store file)', () => {
        for (const name of Object.keys(SPECS)) {
            const h = harnessFor(name, newIo());
            const raw = fs.readFileSync(h.storeFile, 'utf8');
            for (const v of Object.values(SPECS[name].secrets)) assert.ok(!raw.includes(v), `${name}: plaintext secret in store`);
        }
    });

    test('success path: receipt and response carry no secret either (providerMessageId only)', async () => {
        for (const name of Object.keys(SPECS)) {
            const io = newIo();
            const h = harnessFor(name, io);
            await route(h);
            const r = await post(h, notice());
            assert.equal(r.body.ok, true, name);
            assertNoLeak(assert, [[name, r.text]], needlesOf(name));
        }
    });

    test('provider-level: foreign error NAME is not copied verbatim (defence in depth, direct send)', async () => {
        const secret = 'SEKRET-' + rand(4);
        for (const name of ['teams', 'slack', 'pushover', 'ntfy']) {
            const io = newIo();
            io.fetchBehavior = async () => { const e = new Error('x'); e.name = `https://h.example/${encodeURIComponent(secret)}`; throw e; };
            const p = build(name, io);
            const spec = SPECS[name];
            await assert.rejects(
                () => p.send({ id: 'c', params: spec.params, secrets: spec.secrets }, { title: 't', body: 'b', severity: 'info' }, { signal: new AbortController().signal }),
                (e) => !e.message.includes(secret) && !e.message.includes('https://'), name);
        }
    });
});

// ===========================================================================
describe('2. abort / timeout', () => {
    const hungFetch = (io) => (url, opts) => new Promise((_, reject) => {
        io.signal = opts.signal;
        const onAbort = () => { io.settled = true; reject(new DOMException('aborted', 'AbortError')); };
        if (opts.signal.aborted) onAbort(); else opts.signal.addEventListener('abort', onAbort, { once: true });
    });

    for (const name of ['teams', 'slack', 'pushover', 'ntfy']) {
        test(`${name}: dispatcher timeout aborts the SAME signal handed to fetch and the pending request is cancelled`, async () => {
            const io = newIo();
            io.fetchBehavior = hungFetch(io);
            const h = harnessFor(name, io, { sendTimeoutMs: 40 });
            await route(h);
            const r = await post(h);
            assert.equal(r.body.receipts[0].error, 'send timed out');
            assert.ok(io.signal instanceof AbortSignal);
            assert.equal(io.signal.aborted, true);
            await sleep(20);
            assert.equal(io.settled, true, 'fetch promise must be settled by the abort, not left hanging');
        });

        test(`${name}: an already-aborted signal makes send() reject without success`, async () => {
            const io = newIo();
            io.fetchBehavior = hungFetch(io);
            const p = build(name, io);
            const ac = new AbortController(); ac.abort();
            const spec = SPECS[name];
            await assert.rejects(() => p.send({ id: 'c', params: spec.params, secrets: spec.secrets }, { title: 't', body: 'b', severity: 'info' }, { signal: ac.signal }));
        });
    }

    test('email: dispatcher timeout closes the transport and the send rejects', async () => {
        const io = newIo();
        io.mailBehavior = () => new Promise(() => {});
        const h = harnessFor('email', io, { sendTimeoutMs: 40 });
        await route(h);
        const r = await post(h);
        assert.equal(r.body.receipts[0].error, 'send timed out');
        await sleep(20);
        assert.ok(io.closed >= 1, 'transport.close must be called on abort');
        assert.ok(io.transportOpts.socket, 'a destroyable socket is supplied to nodemailer');
        assert.equal(io.transportOpts.socket.destroyed, true);
    });

    test('email: pre-aborted signal never builds a transport', async () => {
        const io = newIo();
        const p = build('email', io);
        const ac = new AbortController(); ac.abort();
        const spec = SPECS.email;
        await assert.rejects(() => p.send({ id: 'c', params: spec.params, secrets: spec.secrets }, { title: 't' }, { signal: ac.signal }), /aborted/);
        assert.equal(io.transportOpts, null);
    });

    test('REGRESSION email: abort really closes the in-flight SMTP socket (real nodemailer, loopback only)', async () => {
        let serverClosedAt = 0;
        const srv = net.createServer((s) => { s.on('close', () => { serverClosedAt = Date.now(); }); s.on('error', () => {}); });
        await new Promise((r) => srv.listen(0, '127.0.0.1', r));
        try {
            const p = createEmailProvider();
            const ac = new AbortController();
            const t0 = Date.now();
            setTimeout(() => ac.abort(), 100);
            await assert.rejects(() => p.send({ id: 'c', params: { host: '127.0.0.1', port: srv.address().port, from: 'a@b.co', to: 'c@d.co', secure: 'starttls' }, secrets: {} },
                { title: 't', body: 'b', severity: 'info' }, { signal: ac.signal }), /aborted/);
            await sleep(300);
            assert.ok(serverClosedAt > 0, 'server never saw the client socket close');
            assert.ok(serverClosedAt - t0 < 1000, 'socket closed promptly after abort');
        } finally { srv.close(); }
    });
});

// ===========================================================================
describe('3. validation fails closed and never echoes the value', () => {
    const CAN = 'CANARY-' + rand(4);
    const expectReject = (provider, conn, label) => {
        try { provider.validate(conn); } catch (e) {
            assert.ok(e instanceof NotifyConfigError, `${label}: wrong error type ${e && e.constructor && e.constructor.name}`);
            assert.ok(!e.message.includes(CAN), `${label}: message echoes value`);
            return;
        }
        assert.fail(`${label}: validate accepted bad config`);
    };
    const io = newIo();

    test('teams', () => {
        const p = build('teams', io);
        const ok = { params: {}, secrets: { webhookUrl: 'https://prod-01.westus.logic.azure.com/a' } };
        p.validate(ok);
        const bads = [
            ['http', { secrets: { webhookUrl: `http://x.example/${CAN}` } }],
            ['ftp', { secrets: { webhookUrl: `ftp://x.example/${CAN}` } }],
            ['js', { secrets: { webhookUrl: `javascript:alert('${CAN}')` } }],
            ['empty', { secrets: { webhookUrl: '' } }], ['missing', { secrets: {} }],
            ['number', { secrets: { webhookUrl: 123 } }], ['array', { secrets: { webhookUrl: [`https://x.example/${CAN}`] } }],
            ['object', { secrets: { webhookUrl: { href: CAN } } }],
            ['shape bogus', { params: { shape: `bogus-${CAN}` } }], ['shape array', { params: { shape: ['flow', CAN] } }],
            ['shape number', { params: { shape: 5 } }], ['shape null', { params: { shape: null } }],
        ];
        for (const [label, over] of bads) expectReject(p, { ...ok, ...over, params: { ...ok.params, ...(over.params || {}) }, secrets: over.secrets || ok.secrets }, label);
    });

    test('teams: non-Microsoft https hosts are rejected (allowlist, XACA-1401 user decision)', () => {
        expectReject(build('teams', io), { params: {}, secrets: { webhookUrl: `https://anything.example.org/${CAN}` } }, 'foreign host');
    });

    test('slack: lookalike hosts / scheme / port / creds / path all rejected', () => {
        const p = build('slack', io);
        const ok = 'https://hooks.slack.com/services/T/B/X';
        p.validate({ secrets: { webhookUrl: ok } });
        p.validate({ secrets: { webhookUrl: 'HTTPS://HOOKS.SLACK.COM/services/T/B/X' } });
        const bads = [
            `https://hooks.slack.com.evil.example/services/T/B/${CAN}`, `https://evilhooks.slack.com/services/T/B/${CAN}`,
            `https://hooks.slack.com@evil.example/services/T/B/${CAN}`, `https://hooks.slack.com:8443/services/T/B/${CAN}`,
            `https://user:pw@hooks.slack.com/services/T/B/${CAN}`, `http://hooks.slack.com/services/T/B/${CAN}`,
            `https://hooks.slack.com/other/T/${CAN}`, 'https://hooks.slack.com/services/', 'https://hooks.slack.com/services',
            `https://hooks.slack.com/services/../admin/${CAN}`, `https://hooks.slack.com./services/T/B/${CAN}`,
            `https://hooks.slack.com\\@evil.example/services/T/B/${CAN}`, `https://slack.com/services/T/B/${CAN}`,
            `https://hooks.slack.com.${CAN}.example/services/T/B/X`,
            '', '   ', `not a url ${CAN}`, 123, [ok], { u: ok }, null,
        ];
        for (const b of bads) expectReject(p, { secrets: { webhookUrl: b } }, String(b));
        assert.throws(() => p.validate({}), NotifyConfigError);
        assert.throws(() => p.validate(null), NotifyConfigError);
    });

    test('email: host/port/from/to/secure/credentials; CRLF + header injection rejected', () => {
        const p = build('email', io);
        const base = () => ({ params: { host: 'smtp.example.com', port: 587, from: 'ops@example.com', to: 'a@example.com' }, secrets: {} });
        p.validate(base());
        const mut = (k, v) => { const c = base(); c.params[k] = v; return c; };
        const bads = [
            ['host empty', mut('host', '')], ['host space', mut('host', `bad host ${CAN}`)], ['host crlf', mut('host', `h\r\nRCPT ${CAN}`)],
            ['host number', mut('host', 5)], ['host array', mut('host', [CAN])], ['host semi', mut('host', `h;${CAN}`)],
            ['host long', mut('host', 'a'.repeat(100000))],
            ['port 0', mut('port', 0)], ['port big', mut('port', 65536)], ['port str', mut('port', `587;${CAN}`)],
            ['port frac', mut('port', 1.5)], ['port true', mut('port', true)], ['port array', mut('port', [587])],
            ['port null', mut('port', null)], ['port obj', mut('port', { n: 587 })],
            ['from crlf', mut('from', `a@b.com\r\nBcc: ${CAN}@x.com`)], ['from lf', mut('from', `a@b.com\nBcc: ${CAN}@x.com`)],
            ['from angle', mut('from', `Evil <${CAN}@x.com>`)], ['from number', mut('from', 5)], ['from empty', mut('from', '')],
            ['from u2028', mut('from', `a@b.com\u2028Bcc: ${CAN}@x.com`)], ['from nul', mut('from', `a\u0000@b.com`)],
            ['to crlf', mut('to', `a@b.com\r\nBcc: ${CAN}@x.com`)], ['to array crlf', mut('to', [`a@b.com\r\nBcc: ${CAN}@x.com`])],
            ['to empty', mut('to', '')], ['to []', mut('to', [])], ['to number', mut('to', 5)], ['to object', mut('to', { a: CAN })],
            ['to 21', mut('to', Array.from({ length: 21 }, (_, i) => `u${i}@example.com`))],
            ['to non-string el', mut('to', ['a@b.com', 5])], ['to junk', mut('to', `a@example.com, ${CAN}`)],
            ['secure false', mut('secure', false)], ['secure "false"', mut('secure', 'false')], ['secure none', mut('secure', 'none')],
            ['secure plain', mut('secure', 'plain')], ['secure 0', mut('secure', 0)], ['secure obj', mut('secure', {})],
        ];
        for (const [label, c] of bads) expectReject(p, c, label);
        for (const secrets of [{ user: 'u' }, { pass: 'p' }, { user: 5, pass: 'p' }, { user: 'u', pass: [CAN] }]) {
            const c = base(); c.secrets = secrets; expectReject(p, c, JSON.stringify(secrets));
        }
        assert.throws(() => p.validate(null), NotifyConfigError);
    });

    test('email: address regex is not ReDoS-able (200k-char inputs validate in < 500 ms)', () => {
        const p = build('email', io);
        const t0 = Date.now();
        for (const from of ['a'.repeat(200000), `${'a'.repeat(100000)}@${'b.'.repeat(50000)}`, `a@${'b'.repeat(200000)}`, `${'a@'.repeat(50000)}`]) {
            try { p.validate({ params: { host: 'h.example', port: 25, from, to: 'a@b.co' }, secrets: {} }); } catch (_e) { /* expected */ }
        }
        assert.ok(Date.now() - t0 < 500, `took ${Date.now() - t0} ms`);
    });

    test('email: TLS policy -- requireTLS always, no ignoreTLS/rejectUnauthorized/logger/debug', async () => {
        const i = newIo();
        const p = build('email', i);
        for (const secure of [undefined, 'implicit', 'starttls', true]) {
            await p.send({ id: 'c', params: { ...SPECS.email.params, ...(secure === undefined ? {} : { secure }) }, secrets: SPECS.email.secrets },
                { title: 't', body: 'b', severity: 'info' }, {});
            const o = i.transportOpts;
            assert.equal(o.requireTLS, true);
            for (const k of ['ignoreTLS', 'logger', 'debug', 'tls', 'disableFileAccess']) assert.ok(!(k in o) || k === 'disableFileAccess', `${k} must not be set`);
        }
    });

    test('email: message headers cannot be injected through title/team/type/ref/severity/body', async () => {
        const i = newIo();
        const p = build('email', i);
        const evil = `x\r\nBcc: ${CAN}@evil.example\nCc: ${CAN}@evil.example\u2028Subject: pwn`;
        await p.send({ id: 'c', params: SPECS.email.params, secrets: SPECS.email.secrets },
            { title: evil, body: `line1\r\nline2 ${evil}`, team: evil, type: evil, ref: evil, severity: evil }, {});
        const m = i.mails[0];
        assert.deepEqual(Object.keys(m).sort(), ['from', 'subject', 'text', 'to']);
        assert.deepEqual(m.to, ['rcpt-one@corp-zq.example']);
        assert.equal(m.from, 'ops-sender@corp-zq.example');
        assert.ok(!/[\r\n\u2028\u2029]/.test(m.subject), 'subject must be a single line');
        assert.ok(m.subject.length <= 200);
    });

    test('pushover: secrets and device validated; wrong types rejected', () => {
        const p = build('pushover', io);
        const ok = { params: {}, secrets: { appToken: 'a', userKey: 'u' } };
        p.validate(ok); p.validate({ ...ok, params: { device: 'phone1,tablet_2' } });
        const bads = [
            ['no token', { secrets: { userKey: 'u' } }], ['no user', { secrets: { appToken: 'a' } }],
            ['ws token', { secrets: { appToken: '   ', userKey: 'u' } }], ['num token', { secrets: { appToken: 5, userKey: 'u' } }],
            ['arr user', { secrets: { appToken: 'a', userKey: [CAN] } }],
            ['dev space', { params: { device: `bad dev ${CAN}` } }], ['dev empty el', { params: { device: `a,,${CAN}` } }],
            ['dev long', { params: { device: 'x'.repeat(26) } }], ['dev array', { params: { device: [CAN] } }],
            ['dev number', { params: { device: 5 } }], ['dev crlf', { params: { device: `a\r\n${CAN}` } }],
            ['dev obj', { params: { device: { d: CAN } } }],
        ];
        for (const [label, over] of bads) expectReject(p, { params: over.params || {}, secrets: over.secrets || ok.secrets }, label);
    });

    test('ntfy: server must be https and a string; topic charset; token a clean string', () => {
        const p = build('ntfy', io);
        const ok = { params: {}, secrets: { topic: 'abc_DEF-1' } };
        p.validate(ok); p.validate({ params: { server: 'https://ntfy.example.org:8443' }, secrets: { topic: 't', token: 'tk_abc' } });
        const bads = [
            ['http', { params: { server: `http://ntfy.example/${CAN}` } }], ['ftp', { params: { server: `ftp://x/${CAN}` } }],
            ['no scheme', { params: { server: `ntfy.sh/${CAN}` } }], ['creds', { params: { server: `https://u:${CAN}@ntfy.sh` } }],
            ['query', { params: { server: `https://ntfy.sh/?k=${CAN}` } }], ['hash', { params: { server: `https://ntfy.sh/#${CAN}` } }],
            ['js', { params: { server: `javascript:${CAN}` } }],
            ['server number', { params: { server: 123 } }], ['server array', { params: { server: [`http://${CAN}`] } }],
            ['server object', { params: { server: { u: CAN } } }], ['server true', { params: { server: true } }],
            ['topic empty', { secrets: { topic: '' } }], ['topic missing', { secrets: {} }],
            ['topic slash', { secrets: { topic: `a/${CAN}` } }], ['topic space', { secrets: { topic: `a ${CAN}` } }],
            ['topic dots', { secrets: { topic: `../${CAN}` } }], ['topic long', { secrets: { topic: 'x'.repeat(65) } }],
            ['topic number', { secrets: { topic: 12345 } }], ['topic array', { secrets: { topic: [CAN] } }],
            ['topic query', { secrets: { topic: `a?${CAN}` } }],
            ['token number', { secrets: { topic: 't', token: 5 } }], ['token array', { secrets: { topic: 't', token: [CAN] } }],
            ['token crlf', { secrets: { topic: 't', token: `abc\r\nX-Evil: ${CAN}` } }], ['token lf', { secrets: { topic: 't', token: `abc\n${CAN}` } }],
            ['token non-latin1', { secrets: { topic: 't', token: `tk☃${CAN}` } }],
        ];
        for (const [label, over] of bads) expectReject(p, { params: over.params || {}, secrets: over.secrets || ok.secrets }, label);
    });

    test('validate(connection) with null / non-object connection throws NotifyConfigError, never TypeError', () => {
        for (const name of Object.keys(SPECS)) {
            for (const c of [null, undefined, {}, { params: null, secrets: null }, 'str', 5]) {
                assert.throws(() => build(name, io).validate(c), NotifyConfigError, `${name}: ${JSON.stringify(c)}`);
            }
        }
    });

    test('store layer: unknown param/secret fields and non-string secrets are rejected for every provider', async () => {
        for (const name of Object.keys(SPECS)) {
            const h = harnessFor(name, newIo());
            const mk = (over) => adm(request(h.app).post('/api/notify/connections')).send({
                id: 'n' + rand(3), provider: name, label: 'l', params: { ...SPECS[name].params }, secrets: { ...SPECS[name].secrets }, ...over });
            const unknownP = await mk({ params: { ...SPECS[name].params, bogus: 'x' } });
            assert.equal(unknownP.status, 400, `${name} unknown param`);
            const unknownS = await mk({ secrets: { ...SPECS[name].secrets, bogus: 'x' } });
            assert.equal(unknownS.status, 400, `${name} unknown secret`);
            const k = Object.keys(SPECS[name].secrets)[0];
            const numS = await mk({ secrets: { ...SPECS[name].secrets, [k]: 5 } });
            assert.equal(numS.status, 400, `${name} numeric secret`);
        }
    });
});

// ===========================================================================
describe('4. payload integrity', () => {
    const SEND = (name, io, message, spec = SPECS[name]) =>
        build(name, io).send({ id: 'c', params: spec.params, secrets: spec.secrets }, message, { signal: new AbortController().signal });
    const lastJson = (io) => JSON.parse(io.requests[io.requests.length - 1].opts.body);

    test('severity maps distinctly for all four severities on every provider', async () => {
        const seen = { teams: new Set(), slack: new Set(), email: new Set(), pushover: new Set(), ntfy: new Set() };
        for (const sev of SEVS) {
            const msg = { team: 'academy', type: 'ci', title: 'T', body: 'B', ref: 'R', severity: sev };
            let io = newIo(); await SEND('teams', io, msg);
            const t = lastJson(io).attachments[0].content.body[0].text;
            assert.equal(t.startsWith(`[${sev.toUpperCase()}]`), sev !== 'info', `teams ${sev}`);
            seen.teams.add(t.split('\n')[0]);
            io = newIo(); await SEND('slack', io, msg); seen.slack.add(lastJson(io).attachments[0].color);
            io = newIo(); await SEND('email', io, msg);
            assert.match(io.mails[0].subject, new RegExp(`^\\[${sev.toUpperCase()}\\]`)); seen.email.add(io.mails[0].subject);
            io = newIo(); await SEND('pushover', io, msg);
            const f = new URLSearchParams(io.requests[0].opts.body);
            seen.pushover.add(f.get('priority'));
            assert.equal(f.has('retry') && f.has('expire'), sev === 'critical');
            assert.equal(f.has('retry'), f.get('priority') === '2');
            io = newIo(); await SEND('ntfy', io, msg);
            const nj = lastJson(io); seen.ntfy.add(nj.priority); assert.equal(nj.tags[0], sev);
        }
        for (const [n, s] of Object.entries(seen)) assert.equal(s.size, 4, `${n}: severities collapse to ${[...s]}`);
        assert.deepEqual([...seen.pushover], ['-1', '0', '1', '2']);
        assert.deepEqual([...seen.ntfy], [2, 3, 4, 5]);
    });

    test('unknown / hostile severity is defined behaviour (no throw, no prototype lookup) on every provider', async () => {
        const weird = ['bogus', '', undefined, null, 42, {}, [], '__proto__', 'constructor', 'toString', 'hasOwnProperty', 'CRITICAL', ' critical'];
        for (const name of Object.keys(SPECS)) {
            for (const severity of weird) {
                const io = newIo();
                await SEND(name, io, { team: 't', type: 'x', title: 'T', body: 'B', severity });
                if (name === 'pushover') assert.ok(['-1'].includes(new URLSearchParams(io.requests[0].opts.body).get('priority')), `pushover ${String(severity)}`);
                if (name === 'ntfy') assert.equal(lastJson(io).priority, 2, `ntfy ${String(severity)}`);
                if (name === 'slack') assert.equal(lastJson(io).attachments[0].color, '#2eb67d', `slack ${String(severity)}`);
            }
        }
    });

    test('missing / non-string message fields do not crash any provider', async () => {
        for (const name of Object.keys(SPECS)) {
            for (const msg of [{}, null, undefined, { title: 5, body: {}, ref: [], team: 5, type: null }]) {
                await SEND(name, newIo(), msg);
            }
        }
    });

    test('slack: mrkdwn control sequences in body/meta/ref are neutralised in EVERY text field', () => {
        const evil = '<!channel> <!here> <@U123> <!subteam^S1> <https://evil.example|click> &amp;';
        const pl = slackPayload({ team: evil, type: evil, title: evil, body: evil, ref: `https://x.example/a>|<!channel> b`, severity: 'info' });
        const att = pl.attachments[0];
        const texts = [];
        for (const b of att.blocks) {
            if (b.text) texts.push(b.text);
            for (const e of b.elements || []) texts.push(e);
        }
        for (const t of texts.filter((x) => x.type === 'mrkdwn')) {
            assert.ok(!/<!(channel|here|subteam)/.test(t.text.replace(/<https:\/\/x\.example[^>]*\|[^>]*>/, '')), `unescaped mention in block: ${t.text}`);
            assert.ok(!t.text.includes('<@U123>'));
        }
        const link = att.blocks[att.blocks.length - 1].elements[1].text;
        assert.match(link, /^<https:\/\/x\.example\/a%3E%7C%3C!channel%3E%20b\|/);
        // REGRESSION: the top-level `text` is rendered as mrkdwn by Slack and was not escaped.
        assert.ok(!/<!channel>|<!here>|<@U123>|<!subteam/.test(pl.text), `top-level text carries live mention: ${pl.text}`);
        assert.ok(!pl.text.includes('<https://evil.example|click>'));
    });

    test('slack: oversize and surrogate-boundary truncation stay within Slack limits', () => {
        const emoji = '\u{1F600}';
        const pl = slackPayload({ title: emoji.repeat(1000), body: emoji.repeat(10000), team: 'x'.repeat(5000), ref: 'y'.repeat(5000), severity: 'high' });
        const [hdr, sec, ctx] = pl.attachments[0].blocks;
        assert.ok(Array.from(hdr.text.text).length <= 150);
        assert.ok(Array.from(sec.text.text).length <= 3000);
        assert.ok(Array.from(pl.text).length <= 3000);
        for (const e of ctx.elements) assert.ok(e.text.length <= 700);
        assert.equal(JSON.parse(JSON.stringify(pl)).attachments[0].blocks[0].text.text, hdr.text.text, 'round-trips as valid JSON/UTF-16');
        assert.equal(slackPayload({ title: '   ', body: '' }).attachments[0].blocks[0].text.text, '(no title)');
    });

    test('pushover: title/message/url limits and emoji-boundary truncation', async () => {
        const io = newIo();
        await SEND('pushover', io, { title: '\u{1F600}'.repeat(1000), body: '\u{1F600}'.repeat(5000), ref: 'https://x.example/' + 'a'.repeat(2000), severity: 'critical' });
        const f = new URLSearchParams(io.requests[0].opts.body);
        assert.ok(Array.from(f.get('title')).length <= 250);
        assert.ok(Array.from(f.get('message')).length <= 1024);
        assert.ok(Array.from(f.get('url')).length <= 512);
        const io2 = newIo();
        await SEND('pushover', io2, { title: 'T', body: 'B', ref: 'javascript:alert(1)' });
        assert.ok(!new URLSearchParams(io2.requests[0].opts.body).has('url'), 'non-http ref never becomes a clickable url');
        const io3 = newIo();
        await SEND('pushover', io3, { title: 'T', body: 'B', ref: 'PR-1' });
        assert.ok(!new URLSearchParams(io3.requests[0].opts.body).has('url'));
    });

    test('pushover: credentials travel in the POST body only, never in the URL', async () => {
        const io = newIo();
        await SEND('pushover', io, { title: 'T', body: 'B' });
        assert.ok(!io.requests[0].url.includes('APPTOKENSECRET1') && !io.requests[0].url.includes('USERKEYSECRET2'));
        assert.equal(io.requests[0].opts.redirect, 'manual');
    });

    test('ntfy: topic in body only, bearer header only when token set, click only for http(s) refs, hostile team tag dropped', async () => {
        let io = newIo();
        await SEND('ntfy', io, { title: 'T', body: 'B', ref: 'javascript:alert(1)', team: 'a b/c', severity: 'high' });
        let j = lastJson(io);
        assert.ok(!('click' in j));
        assert.deepEqual(j.tags, ['high']);
        assert.ok(!io.requests[0].url.includes('topic-secret-abc'));
        assert.equal(io.requests[0].opts.headers.Authorization, 'Bearer tk_secrettoken9');
        io = newIo();
        await SEND('ntfy', io, { title: 'T', body: 'B', ref: 'https://x.example/p', team: 'academy' }, { params: {}, secrets: { topic: 'tt' } });
        j = lastJson(io);
        assert.equal(j.click, 'https://x.example/p');
        assert.deepEqual(j.tags, ['info', 'academy']);
        assert.ok(!('Authorization' in io.requests[0].opts.headers));
        assert.equal(io.requests[0].url, 'https://ntfy.sh/');
    });

    test('REGRESSION ntfy: a mistyped server param must NOT silently fall back to public ntfy.sh', () => {
        const p = build('ntfy', newIo());
        for (const server of [123, true, ['https://x.example'], { u: 'https://x.example' }]) {
            assert.throws(() => p.validate({ params: { server }, secrets: { topic: 'secret-topic' } }), NotifyConfigError, JSON.stringify(server));
        }
    });

    test('email: body lines, oversize title, severity mapping and defined subject', async () => {
        const io = newIo();
        await SEND('email', io, { team: 'academy', type: 'ci', title: 'T'.repeat(5000), body: 'B', ref: 'R'.repeat(5000), severity: 'critical' });
        const m = io.mails[0];
        assert.ok(m.subject.length <= 200);
        assert.ok(m.text.split('\n')[0].length <= 500);
        assert.match(m.text, /Severity: CRITICAL/);
        assert.ok(m.text.split('\n').find((l) => l.startsWith('Ref: ')).length <= 205);
    });

    test('redirects are never followed by any HTTP provider', async () => {
        for (const name of ['teams', 'slack', 'pushover', 'ntfy']) {
            const io = newIo();
            await SEND(name, io, { title: 'T', body: 'B' });
            assert.ok(['manual', 'error'].includes(io.requests[0].opts.redirect), `${name}: ${io.requests[0].opts.redirect}`);
            assert.equal(io.requests[0].opts.method, 'POST');
        }
    });
});

// ===========================================================================
describe('5. Teams parity with kanban-hooks/release_notify_teams.py', () => {
    const PY = `${process.env.HOME}/dev-team/kanban-hooks`;
    let havePython = true;
    try { execFileSync('python3', ['-I', '--version'], { stdio: 'ignore' }); } catch (_e) { havePython = false; }
    const pyPayload = (shape, text) => JSON.parse(execFileSync('python3', ['-I', '-c',
        'import sys,json; sys.path.insert(0, sys.argv[1]); import release_notify_teams as t; print(json.dumps(t.build_payload(sys.argv[2], sys.argv[3])))',
        PY, shape, text], { encoding: 'utf8' }));

    for (const shape of ['flow', 'webhook']) {
        for (const text of ['hello', '[HIGH] Title\n\nBody with "quotes" ☃ \u{1F600}', '', '<b>x</b> & y']) {
            test(`payload parity shape=${shape} text=${JSON.stringify(text).slice(0, 20)}`, { skip: !havePython }, () => {
                assert.deepEqual(JSON.parse(JSON.stringify(teamsPayload(shape, text))), pyPayload(shape, text));
            });
        }
    }

    test('wire request: POST, JSON content-type, manual redirect, body equals the payload; ids from the same headers', async () => {
        const io = newIo();
        io.fetchBehavior = async () => ({ status: 202, ok: true, headers: new Headers({ 'x-ms-request-id': 'req-9' }) });
        const p = build('teams', io);
        const res = await p.send({ id: 'c', params: { shape: 'webhook' }, secrets: SPECS.teams.secrets }, { title: 'T', body: 'B', severity: 'high' }, {});
        const rq = io.requests[0];
        assert.equal(rq.opts.method, 'POST');
        assert.equal(rq.opts.headers['Content-Type'], 'application/json');
        assert.equal(rq.opts.redirect, 'manual');
        assert.deepEqual(JSON.parse(rq.opts.body), { text: '[HIGH] T\n\nB' });
        assert.deepEqual(res, { providerMessageId: 'req-9' });
        io.fetchBehavior = async () => ({ status: 200, ok: true, headers: new Headers({ 'x-ms-workflow-run-id': 'wf-1', 'x-ms-request-id': 'req-9' }) });
        assert.deepEqual(await p.send({ id: 'c', params: {}, secrets: SPECS.teams.secrets }, { title: 'T' }, {}), { providerMessageId: 'wf-1' });
    });

    test('status handling matches Python: only 2xx succeeds (1xx/3xx/4xx/5xx and non-integer fail)', async () => {
        for (const status of [100, 199, 300, 301, 302, 400, 401, 429, 500, 503, undefined, null, 'ok', 200.5]) {
            const io = newIo();
            io.fetchBehavior = async () => ({ status, ok: false, headers: new Headers() });
            await assert.rejects(() => build('teams', io).send({ id: 'c', params: {}, secrets: SPECS.teams.secrets }, { title: 'T' }, {}), /teams returned HTTP/, String(status));
        }
        for (const status of [200, 201, 202, 204, 299]) {
            const io = newIo();
            io.fetchBehavior = async () => ({ status, ok: true, headers: new Headers() });
            await build('teams', io).send({ id: 'c', params: {}, secrets: SPECS.teams.secrets }, { title: 'T' }, {});
        }
    });

    test('Teams text carries a team · type · ref context line (XACA-1401 user decision; deliberate divergence from Python)', async () => {
        const io = newIo();
        await build('teams', io).send({ id: 'c', params: { shape: 'webhook' }, secrets: SPECS.teams.secrets },
            { team: 'academy', type: 'pr-merged', title: 'PR merged', body: 'details', ref: 'PR-77', severity: 'info' }, {});
        const text = JSON.parse(io.requests[0].opts.body).text;
        assert.equal(text, 'PR merged\n\ndetails\n\nacademy · pr-merged · PR-77');
    });
});
