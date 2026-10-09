//
//  xaca-1400-007-adversarial.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1400-007 -- adversarial pass over the whole notification hub, part 1:
 * secret leakage, fail-open, cross-team isolation, policy correctness.
 * (Input bounds + persistence live in xaca-1400-007b-adversarial-bounds.test.js.)
 *
 * Tests marked { todo } demonstrate a REAL defect (lib/ is not modified in this
 * subitem); they keep the suite green and are listed in the subitem report.
 */

const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const H = require('./xaca-1400-007-helpers');
const {
    request, fs, path, rand, adm, flt, cfg, pushRoutes, notice, post, mkConn, readLines, sleep, assertNoLeak,
    makeHarness, makeProvider, makeClock, captureConsole, NotifyConfigError, NotifySendError,
    createTestProvider, createNotifyStore, createReceiptLog, createNotifyDispatcher, createProviderRegistry,
} = H;
const policies = require('../lib/notify-policies');
const { wireNotifyHub, registerNotifyRoutes } = require('../lib/notify-routes');

after(() => { H.restoreEnv(); H.cleanup(); });

const CATALOG_TAG = 'notice-types/v1';
const layer = (...types) => ({
    $schema: CATALOG_TAG, schemaVersion: 1,
    types: types.map((t) => (typeof t === 'string' ? { id: t, defaultSeverity: 'warning', description: `type ${t}` } : t)),
});

// ===========================================================================
describe('1. secret leakage', () => {
    test('provider validate() text carrying the secret is scrubbed on create AND update', async () => {
        const p = makeProvider('leaky', {
            validate(c) {
                const t = c.secrets.token;
                if (!t) throw new NotifyConfigError('token required');
                if (t.startsWith('bad-')) throw new NotifyConfigError(`rejected ${t} for ${c.id}`);
                return undefined;
            },
        });
        const h = makeHarness({ providers: [p] });
        const SEC = 'bad-' + rand();
        const cap = captureConsole();
        let r1; let r2; let up;
        try {
            r1 = await adm(request(h.app).post('/api/notify/connections'))
                .send({ id: 'c1', provider: 'leaky', label: 'l', secrets: { token: SEC } });
            r2 = await adm(request(h.app).post('/api/notify/connections'))
                .send({ id: 'c2', provider: 'leaky', label: 'l', secrets: { token: 'good-1' } });
            up = await adm(request(h.app).put('/api/notify/connections/c2')).send({ secrets: { token: SEC } });
        } finally { cap.restore(); }
        assert.equal(r1.status, 400);
        assert.match(r1.body.message, /\[redacted\]/);
        assert.equal(r2.status, 201);
        assert.equal(up.status, 400);
        assert.match(up.body.message, /\[redacted\]/);
        assertNoLeak(assert, [['create', r1.text], ['update', up.text], ['console', cap.lines.join('\n')],
            ['store', fs.existsSync(h.storeFile) ? fs.readFileSync(h.storeFile, 'utf8') : '']], [SEC]);
        // the rejected update must not have changed the stored secret
        assert.equal(h.store.resolveConnection('c2').secrets.token, 'good-1');
    });

    test('validate() throwing a non-Error (string / null / number / {message}) never leaks the secret', async () => {
        const SEC = 'tok-' + rand();
        const throwers = {
            str: (c) => { throw `bad ${c.secrets.token}`; },
            nul: () => { throw null; },
            num: () => { throw 42; },
            obj: (c) => { throw { message: `oops ${c.secrets.token}` }; },
        };
        for (const [name, fn] of Object.entries(throwers)) {
            const h = makeHarness({ providers: [makeProvider('thrower', { validate: fn })] });
            const r = await adm(request(h.app).post('/api/notify/connections'))
                .send({ id: 'c1', provider: 'thrower', label: name, secrets: { token: SEC } });
            assert.equal(r.status, 400, `${name}: status`);
            assert.ok(!r.text.includes(SEC), `${name}: leaked secret in response`);
        }
    });

    test('send() rejecting with string/object/Error/null/undefined/null-proto: only the type name is recorded; no secret/title/body anywhere', async () => {
        const h = makeHarness({
            providers: [makeProvider('multi', {
                send: (c) => {
                    const t = c.secrets.token;
                    switch (c.id) {
                        case 's-string': return Promise.reject(`boom ${t}`);
                        case 's-object': return Promise.reject({ token: t, url: `https://hooks.example/${t}` });
                        case 's-error': return Promise.reject(new Error(`fetch failed https://hooks.example/${t}`));
                        case 's-type': return Promise.reject(new TypeError(`bad ${t}`));
                        case 's-null': return Promise.reject(null);
                        case 's-undef': return Promise.reject(undefined);
                        case 's-nproto': return Promise.reject(Object.assign(Object.create(null), { message: t }));
                        default: return Promise.resolve({});
                    }
                },
            }), createTestProvider()],
        });
        const ids = ['s-string', 's-object', 's-error', 's-type', 's-null', 's-undef', 's-nproto'];
        const secrets = {};
        for (const id of ids) { secrets[id] = `SEC-${id}-${rand(6)}`; mkConn(h, id, 'multi', secrets[id]); }
        assert.equal((await pushRoutes(h, 'team-a', { 'pr-merged': ids })).status, 200);
        const TITLE = 'TITLE-' + rand(); const BODY = 'BODY-' + rand();
        const cap = captureConsole();
        let r;
        try { r = await post(h, notice({ title: TITLE, body: BODY })); } finally { cap.restore(); }
        assert.equal(r.status, 200);
        assert.equal(r.body.ok, false);
        assert.equal(r.body.failed, ids.length);
        const err = Object.fromEntries(r.body.receipts.map((x) => [x.connectionId, x.error]));
        assert.equal(err['s-string'], 'provider error (String)');
        assert.equal(err['s-object'], 'provider error (Object)');
        assert.equal(err['s-error'], 'provider error (Error)');
        assert.equal(err['s-type'], 'provider error (TypeError)');
        assert.equal(err['s-null'], 'provider error (Error)');
        assert.equal(err['s-undef'], 'provider error (Error)');
        assert.equal(err['s-nproto'], 'provider error (Error)');
        assertNoLeak(assert, [
            ['response', r.text], ['receipts file', fs.readFileSync(h.receiptFile, 'utf8')],
            ['store file', fs.readFileSync(h.storeFile, 'utf8')], ['console', cap.lines.join('\n')],
        ], [...Object.values(secrets), TITLE, BODY, 'hooks.example']);
    });

    test('a synchronously-throwing send() (non-async provider) is contained as a failed receipt', async () => {
        const p = makeProvider('syncthrow', { rawSend() { throw new Error('sync boom'); } });
        const h = makeHarness({ providers: [p] });
        mkConn(h, 'conn-a', 'syncthrow');
        await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a'] });
        const r = await post(h);
        assert.equal(r.status, 200);
        assert.equal(r.body.delivered, 0);
        assert.equal(r.body.receipts[0].error, 'provider error (Error)');
    });

    test('receipts + store files hold no plaintext secret, title, body or destination param', async () => {
        const SEC = 'plain-' + rand(); const URL_ = 'https://dest.example/' + rand();
        const h = makeHarness({ providers: [makeProvider('dest')] });
        h.store.createConnection({ id: 'conn-a', provider: 'dest', label: 'x', params: { url: URL_ }, secrets: { token: SEC } });
        await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a'] });
        const TITLE = 'TTL-' + rand(); const BODY = 'BDY-' + rand();
        const r = await post(h, notice({ title: TITLE, body: BODY }));
        assert.equal(r.body.delivered, 1);
        assertNoLeak(assert, [['receipts', fs.readFileSync(h.receiptFile, 'utf8')], ['dispatch response', r.text]],
            [SEC, URL_, TITLE, BODY]);
        assertNoLeak(assert, [['store', fs.readFileSync(h.storeFile, 'utf8')]], [SEC, TITLE, BODY]);
        // sanity: the secret is really recoverable through the one sanctioned door
        assert.equal(h.store.resolveConnection('conn-a').secrets.token, SEC);
    });

    test('an unexpected exception inside a handler yields a generic 500, never the exception text', async () => {
        const SEC = 'boom-' + rand();
        const registry = createProviderRegistry();
        registry.register('test', createTestProvider());
        const store = {
            status: () => ({ enabled: true }),
            createConnection() { throw new Error(`kaboom ${SEC}`); },
            listConnections() { throw new TypeError(`cannot read ${SEC}`); },
        };
        const app = H.express(); app.use(H.express.json());
        registerNotifyRoutes(app, {
            store, registry, isRegisteredTeam: () => true,
            receipts: createReceiptLog({ file: path.join(H.TMP, 'stub-receipts.jsonl') }),
        });
        const cap = captureConsole();
        let a; let b;
        try {
            a = await adm(request(app).post('/api/notify/connections')).send({ id: 'x' });
            b = await adm(request(app).get('/api/notify/connections'));
        } finally { cap.restore(); }
        assert.equal(a.status, 500); assert.equal(b.status, 500);
        assert.equal(a.body.error, 'internal_error');
        assertNoLeak(assert, [['a', a.text], ['b', b.text], ['console', cap.lines.join('\n')]], [SEC]);
    });

    test('validation failures name the field but never echo the submitted value', async () => {
        const h = makeHarness();
        const SEC = 'echo-' + rand();
        const r1 = await adm(request(h.app).post('/api/notify/connections'))
            .send({ id: 'c1', provider: 'test', label: 'l', secrets: { bogus: SEC } });
        const r2 = await adm(request(h.app).post('/api/notify/connections'))
            .send({ id: 'c2', provider: 'test', label: 'l', secrets: { token: 12345 }, params: { url: SEC } });
        for (const r of [r1, r2]) assert.equal(r.status, 400);
        assertNoLeak(assert, [['r1', r1.text], ['r2', r2.text]], [SEC]);
    });

    test('an unknown "provider" value is not echoed back in the error',
        async () => {
            const h = makeHarness();
            const SEC = 'echo-' + rand();
            const r = await adm(request(h.app).post('/api/notify/connections')).send({ id: 'c3', provider: SEC, label: 'l' });
            assert.equal(r.status, 400);
            assertNoLeak(assert, [['response', r.text]], [SEC]);
        });

    test('NOTIFY_STORE_KEY material never reaches status, responses or the wire log (valid and malformed keys)', async () => {
        for (const key of ['abcd-SENTINELKEY-' + rand(), H.KEY, 'ZZ' + H.KEY.slice(2)]) {
            const logs = [];
            const app = H.express(); app.use(H.express.json());
            const dir = path.join(H.TMP, 'wire-' + rand(4));
            wireNotifyHub(app, {
                isRegisteredTeam: () => true,
                logger: { log: (m) => logs.push(String(m)) },
                storeOpts: { file: path.join(dir, 's.json'), key },
                receiptOpts: { file: path.join(dir, 'r.jsonl') },
            });
            const srv = require('http').createServer(app);
            await new Promise((r) => srv.listen(0, '127.0.0.1', r));
            let st; let cn;
            try {
                st = await adm(request(srv).get('/api/notify/status'));
                cn = await adm(request(srv).get('/api/notify/connections'));
            } finally { await new Promise((r) => srv.close(r)); }
            assertNoLeak(assert, [['status', st.text], ['connections', cn.text], ['log', logs.join('\n')]],
                [key, key.slice(0, 20)]);
        }
    });

    test('prototype-pollution shaped keys in params/secrets/config/catalog are refused and pollute nothing', async () => {
        const h = makeHarness();
        const raw = async (url, method, text) => flt(adm(request(h.app)[method](url)).set('content-type', 'application/json')).send(text);
        const send = (method, url, text, tier = adm) => tier(request(h.app)[method](url)).set('content-type', 'application/json').send(text);
        const r1 = await send('post', '/api/notify/connections',
            '{"id":"c1","provider":"test","label":"l","params":{"__proto__":{"polluted":1}},"secrets":{"token":"t"}}');
        const r2 = await send('post', '/api/notify/connections',
            '{"id":"c2","provider":"test","label":"l","secrets":{"__proto__":"x","token":"t"}}');
        const r3 = await send('put', '/api/notify/routes/team-a',
            '{"config":{"$schema":"release-notify/v2","version":2,"routes":{"__proto__":["a"]}}}', flt);
        const r4 = await send('put', '/api/notify/routes/team-a',
            '{"config":{"$schema":"release-notify/v2","version":2,"routes":{},"__proto__":{"x":1}}}', flt);
        const r5 = await send('put', '/api/notify/routes/team-a',
            '{"config":{"$schema":"release-notify/v2","version":2,"routes":{}},"catalog":{"$schema":"notice-types/v1","schemaVersion":1,"types":[{"id":"__proto__","defaultSeverity":"info","description":"d"}]}}', flt);
        const r6 = await send('post', '/api/notify',
            '{"team":"team-a","type":"pr-merged","title":"t","body":"b","__proto__":{"x":1}}', flt);
        void raw;
        for (const [i, r] of [r1, r2, r3, r4, r5, r6].entries()) assert.equal(r.status, 400, `case ${i + 1}: ${r.text.slice(0, 120)}`);
        assert.equal({}.polluted, undefined);
        assert.equal(Object.prototype.x, undefined);
        assert.equal(Object.keys(h.store.listConnections()).length, 0);
    });

    test('names that collide with Object.prototype members ("constructor") behave as ordinary ids', async () => {
        const h = makeHarness();
        assert.equal((await adm(request(h.app).get('/api/notify/connections/constructor'))).status, 404);
        assert.equal(h.store.resolveConnection('constructor'), null);
        assert.equal(h.store.getTeamRoutes('constructor'), null);
        assert.equal((await adm(request(h.app).delete('/api/notify/connections/constructor'))).status, 404);
        assert.equal((await adm(request(h.app).put('/api/notify/connections/constructor')).send({ label: 'x' })).status, 404);
        // as a team: unknown to the store until pushed; dispatching an uncatalogued 'constructor' type is a 400, not a crash
        h.teams.add('constructor');
        assert.equal((await post(h, notice({ team: 'constructor' }))).status, 404);
        // as an id + a team-defined notice type named 'constructor'
        const c = await adm(request(h.app).post('/api/notify/connections'))
            .send({ id: 'constructor', provider: 'test', label: 'c', secrets: { token: 't1' } });
        assert.equal(c.status, 201);
        assert.equal((await adm(request(h.app).get('/api/notify/connections/constructor'))).status, 200);
        const bad = await pushRoutes(h, 'constructor', { 'pr-merged': ['constructor'] });
        assert.equal(bad.status, 200);
        const t = await post(h, notice({ team: 'constructor', type: 'constructor' }));
        assert.equal(t.status, 400, 'uncatalogued type named constructor must be rejected');
        assert.equal((await pushRoutes(h, 'constructor', { constructor: ['constructor'] }, undefined, layer('constructor'))).status, 200);
        const ok = await post(h, notice({ team: 'constructor', type: 'constructor' }));
        assert.equal(ok.status, 200);
        assert.equal(ok.body.delivered, 1);
        assert.equal(ok.body.severity, 'warning');
    });

    // -- DEFECTS ----------------------------------------------------------
    test('a malformed JSON body does not echo a fragment of a secret to the response or the server log',
        async () => {
            const h = makeHarness();
            const SEC = 'SUPERSECRETVALUE' + rand(3);
            const cap = captureConsole();
            let r;
            try {
                r = await adm(request(h.app).post('/api/notify/connections'))
                    .set('content-type', 'application/json').send(`{"token":${SEC}}`);
            } finally { cap.restore(); }
            assert.equal(r.status, 400);
            assertNoLeak(assert, [['response', r.text], ['server log', cap.lines.join('\n')]], [SEC.slice(0, 6)]);
        });

    test('a provider send() error text is scrubbed of the connection\'s own secret, as validate() text is',
        async () => {
            const SEC = 'tok-' + rand();
            const h = makeHarness({
                providers: [makeProvider('sloppy', { send: (c) => { throw new NotifySendError(`auth failed for ${c.secrets.token}`); } })],
            });
            mkConn(h, 'conn-a', 'sloppy', SEC);
            await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a'] });
            const r = await post(h);
            assert.equal(r.status, 200);
            assertNoLeak(assert, [['response', r.text], ['receipts', fs.readFileSync(h.receiptFile, 'utf8')]], [SEC]);
        });
});

// ===========================================================================
describe('2. fail-open', () => {
    const variants = {
        'missing': undefined,
        'throws': () => { throw new Error('registry down SENTINEL'); },
        'returns 1': () => 1,
        'returns "true"': () => 'true',
        'returns {}': () => ({}),
        'returns Promise<true>': () => Promise.resolve(true),
        'returns null': () => null,
    };
    for (const [label, fn] of Object.entries(variants)) {
        test(`isRegisteredTeam ${label}: PUT/GET/POST all refuse (404), nothing is stored or sent`, async () => {
            const h = makeHarness({ isRegisteredTeam: fn });
            mkConn(h, 'conn-a');
            const cap = captureConsole();
            let put; let get; let pst;
            try {
                put = await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a'] });
                get = await flt(request(h.app).get('/api/notify/routes/team-a'));
                pst = await post(h);
            } finally { cap.restore(); }
            assert.equal(put.status, 404); assert.equal(get.status, 404); assert.equal(pst.status, 404);
            assert.equal(h.store.getTeamRoutes('team-a'), null);
            assert.equal(readLines(h.receiptFile).length, 0);
            assertNoLeak(assert, [['responses', put.text + get.text + pst.text], ['console', cap.lines.join('\n')]], ['SENTINEL']);
        });
    }

    test('isRegisteredTeam === true is the only passing value (control)', async () => {
        const h = makeHarness({ isRegisteredTeam: () => true });
        assert.equal((await pushRoutes(h, 'team-a', {})).status, 200);
    });

    test('disabled store (missing / short / malformed / 31-byte key): every state-bearing route answers 503, no file is written', async () => {
        for (const key of [undefined, '', '   ', 'short', 'g'.repeat(64), H.KEY.slice(2), Buffer.alloc(31)]) {
            const h = makeHarness({ key });
            assert.deepEqual(Object.keys(h.store.status()).sort(), ['enabled', 'reason']);
            const reqs = [
                adm(request(h.app).get('/api/notify/connections')),
                adm(request(h.app).post('/api/notify/connections')).send({ id: 'c1', provider: 'test', label: 'l' }),
                adm(request(h.app).get('/api/notify/connections/c1')),
                adm(request(h.app).put('/api/notify/connections/c1')).send({ label: 'x' }),
                adm(request(h.app).delete('/api/notify/connections/c1')),
                flt(request(h.app).put('/api/notify/routes/team-a')).send({ config: cfg({}) }),
                flt(request(h.app).get('/api/notify/routes/team-a')),
                flt(request(h.app).post('/api/notify')).send(notice()),
            ];
            for (const r of await Promise.all(reqs)) assert.equal(r.status, 503, `key=${String(key).slice(0, 8)}: ${r.req.method} ${r.req.path}`);
            assert.equal(fs.existsSync(h.storeFile), false);
            assert.equal(fs.existsSync(h.receiptFile), false);
            assert.throws(() => h.store.resolveConnection('c1'), /disabled/);
        }
    });

    test('a store opened WITHOUT a key over an existing valid file never mutates it and never delivers', async () => {
        const dir = path.join(H.TMP, 'nokey-' + rand(4));
        const p1 = makeProvider('t1');
        const h1 = makeHarness({ dir, providers: [p1] });
        mkConn(h1, 'conn-a', 't1');
        await pushRoutes(h1, 'team-a', { 'pr-merged': ['conn-a'] });
        const before = fs.readFileSync(h1.storeFile);
        const p2 = makeProvider('t1');
        const h2 = makeHarness({ dir, key: undefined, providers: [p2] });
        assert.equal(h2.store.status().enabled, false);
        assert.equal((await post(h2)).status, 503);
        // the in-process dispatcher (bypassing HTTP) must still fail closed: no plaintext, no send
        const out = await h2.dispatcher.dispatch(notice());
        assert.equal(out.delivered, 0);
        assert.equal(out.receipts[0].error, 'connection lookup failed');
        assert.equal(p2.calls.length, 0);
        assert.ok(before.equals(fs.readFileSync(h2.storeFile)), 'store file bytes changed');
    });

    test('a store with a key that was valid at boot cannot be "disabled mid-flight"; a resolve that throws disabled becomes a failed receipt, not a send', async () => {
        const p = makeProvider('t1');
        const h = makeHarness({ providers: [p] });
        mkConn(h, 'conn-a', 't1');
        await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a'] });
        const real = h.store.resolveConnection;
        h.store.resolveConnection = () => { throw new (require('../lib/notify-store').NotifyStoreDisabledError)('flipped'); };
        const out = await h.dispatcher.dispatch(notice());
        h.store.resolveConnection = real;
        assert.equal(out.delivered, 0);
        assert.equal(out.receipts[0].error, 'connection lookup failed');
        assert.equal(p.calls.length, 0);
    });

    describe('corrupt store file on load', () => {
        const goodConn = (h, id) => mkConn(h, id);
        const cases = {
            'garbage text': () => 'this is not json {{{',
            'truncated JSON': (good) => good.slice(0, Math.floor(good.length / 2)),
            'empty file': () => '',
            'JSON array root': () => '[]',
            'wrong schema version': () => JSON.stringify({ version: 99, connections: {}, routes: {} }),
        };
        // Per-entry corruption (D3): the bad entry is quarantined, the original bytes are kept aside,
        // and the file is rewritten without it. The sole connection here is the bad one, so the hub is empty.
        const entryCases = {
            'connection id mismatch': (good) => { const j = JSON.parse(good); j.connections['conn-a'].id = 'other'; return JSON.stringify(j); },
            'secrets not an object': (good) => { const j = JSON.parse(good); j.connections['conn-a'].secrets = 'plain'; return JSON.stringify(j); },
        };
        for (const [name, mutate] of Object.entries(entryCases)) {
            test(`${name}: entry quarantined, original preserved aside, hub enabled, reported, writable`, () => {
                const dir = path.join(H.TMP, 'corrupt-' + rand(4));
                const h1 = makeHarness({ dir });
                goodConn(h1, 'conn-a');
                const bad = mutate(fs.readFileSync(h1.storeFile, 'utf8'));
                fs.writeFileSync(h1.storeFile, bad);
                const h2 = makeHarness({ dir });
                assert.equal(h2.store.status().enabled, true);
                assert.deepEqual(h2.store.listConnections(), []);
                assert.equal(h2.store.status().recovered.quarantined, 1);
                const aside = fs.readdirSync(dir).filter((f) => f.startsWith('store.json.corrupt-'));
                assert.equal(aside.length, 1, 'exactly one .corrupt- file');
                assert.equal(fs.readFileSync(path.join(dir, aside[0]), 'utf8'), bad, 'original bytes preserved');
                goodConn(h2, 'conn-b');
                assert.equal(h2.store.listConnections().length, 1);
            });
        }
        for (const [name, mutate] of Object.entries(cases)) {
            test(`${name}: moved aside intact, hub comes up empty + enabled, and is writable again`, () => {
                const dir = path.join(H.TMP, 'corrupt-' + rand(4));
                const h1 = makeHarness({ dir });
                goodConn(h1, 'conn-a');
                const good = fs.readFileSync(h1.storeFile, 'utf8');
                const bad = mutate(good);
                fs.writeFileSync(h1.storeFile, bad);
                const h2 = makeHarness({ dir });
                assert.equal(h2.store.status().enabled, true);
                assert.deepEqual(h2.store.listConnections(), []);
                const aside = fs.readdirSync(dir).filter((f) => f.startsWith('store.json.corrupt-'));
                assert.equal(aside.length, 1, 'exactly one .corrupt- file');
                assert.equal(fs.readFileSync(path.join(dir, aside[0]), 'utf8'), bad, 'original bytes preserved');
                assert.equal(fs.existsSync(h2.storeFile), false, 'no partial file left in place');
                goodConn(h2, 'conn-b'); // store is usable
                assert.equal(h2.store.listConnections().length, 1);
            });
        }

        test('a store file made of valid JSON with prototype keys loads without polluting', () => {
            const dir = path.join(H.TMP, 'corrupt-' + rand(4));
            fs.mkdirSync(dir, { recursive: true });
            fs.writeFileSync(path.join(dir, 'store.json'),
                '{"version":1,"connections":{},"routes":{"__proto__":{"polluted":1},"team-a":{"config":{},"catalog":{}}}}');
            const h = makeHarness({ dir });
            assert.equal({}.polluted, undefined);
            assert.equal(h.store.getTeamRoutes('team-a') !== null, true);
        });

        test('one malformed secret envelope must not take every other connection down with it',
            () => {
                const dir = path.join(H.TMP, 'blast-' + rand(4));
                const h1 = makeHarness({ dir });
                mkConn(h1, 'conn-a'); mkConn(h1, 'conn-b');
                const j = JSON.parse(fs.readFileSync(h1.storeFile, 'utf8'));
                j.connections['conn-a'].secrets.token = { iv: 5, tag: 'x', ct: 'y' };
                fs.writeFileSync(h1.storeFile, JSON.stringify(j));
                const h2 = makeHarness({ dir });
                assert.ok(h2.store.getConnection('conn-b'), 'healthy connection conn-b survived');
            });

        test('a corrupt store file is reported (log line), not silently replaced by an empty hub',
            () => {
                const dir = path.join(H.TMP, 'silent-' + rand(4));
                fs.mkdirSync(dir, { recursive: true });
                fs.writeFileSync(path.join(dir, 's.json'), 'garbage');
                const logs = [];
                const cap = captureConsole();
                try {
                    wireNotifyHub(H.express(), {
                        isRegisteredTeam: () => true, logger: { log: (m) => logs.push(String(m)), warn: (m) => logs.push(String(m)), error: (m) => logs.push(String(m)) },
                        storeOpts: { file: path.join(dir, 's.json'), key: H.KEY }, receiptOpts: { file: path.join(dir, 'r.jsonl') },
                    });
                } finally { cap.restore(); }
                const all = logs.concat(cap.lines).join('\n');
                assert.match(all, /corrupt|moved aside|discard/i, `no operator-visible trace; saw: ${all}`);
            });
    });

    test('tampered ciphertext on ONE connection: that connection fails with a fixed phrase, the others still deliver', async () => {
        const p = makeProvider('t1');
        const h = makeHarness({ providers: [p] });
        mkConn(h, 'conn-a', 't1', 'sec-a'); mkConn(h, 'conn-b', 't1', 'sec-b');
        const j = JSON.parse(fs.readFileSync(h.storeFile, 'utf8'));
        const ct = Buffer.from(j.connections['conn-a'].secrets.token.ct, 'base64'); ct[0] ^= 0xff;
        j.connections['conn-a'].secrets.token.ct = ct.toString('base64');
        fs.writeFileSync(h.storeFile, JSON.stringify(j));
        const h2 = makeHarness({ dir: h.dir, providers: [p] });
        await pushRoutes(h2, 'team-a', { 'pr-merged': ['conn-a', 'conn-b'] });
        const r = await post(h2);
        assert.equal(r.status, 200);
        assert.equal(r.body.ok, true);
        assert.equal(r.body.delivered, 1);
        assert.equal(r.body.failed, 1);
        const by = Object.fromEntries(r.body.receipts.map((x) => [x.connectionId, x]));
        assert.equal(by['conn-a'].error, 'connection secrets unreadable');
        assert.equal(by['conn-b'].ok, true);
        assert.deepEqual(p.calls.map((c) => c.id), ['conn-b']);
        assertNoLeak(assert, [['response', r.text]], ['sec-a', 'sec-b']);
    });

    test('ciphertext swapped between two connections (same field) is rejected by the AAD binding', async () => {
        const p = makeProvider('t1');
        const h = makeHarness({ providers: [p] });
        mkConn(h, 'conn-a', 't1', 'sec-a'); mkConn(h, 'conn-b', 't1', 'sec-b');
        const j = JSON.parse(fs.readFileSync(h.storeFile, 'utf8'));
        j.connections['conn-a'].secrets.token = j.connections['conn-b'].secrets.token;
        fs.writeFileSync(h.storeFile, JSON.stringify(j));
        const h2 = makeHarness({ dir: h.dir, providers: [p] });
        assert.throws(() => h2.store.resolveConnection('conn-a'), /cannot decrypt/);
        assert.equal(h2.store.resolveConnection('conn-b').secrets.token, 'sec-b');
    });

    test('wrong-key restart: reads stay public-safe, dispatch fails closed with fixed text, update 500s without secrets, old ciphertext survives other writes', async () => {
        const p = makeProvider('t1');
        const dir = path.join(H.TMP, 'wrongkey-' + rand(4));
        const h1 = makeHarness({ dir, providers: [p] });
        mkConn(h1, 'conn-a', 't1', 'sec-a');
        await pushRoutes(h1, 'team-a', { 'pr-merged': ['conn-a'] });
        const k1 = JSON.parse(fs.readFileSync(h1.storeFile, 'utf8')).connections['conn-a'].secrets.token;
        const key2 = require('crypto').randomBytes(32).toString('hex');
        const h2 = makeHarness({ dir, key: key2, providers: [p] });
        assert.equal(h2.store.listConnections().length, 1);
        const d = await post(h2);
        assert.equal(d.status, 200);
        assert.equal(d.body.delivered, 0);
        assert.equal(d.body.receipts[0].error, 'connection secrets unreadable');
        const up = await adm(request(h2.app).put('/api/notify/connections/conn-a')).send({ label: 'renamed' });
        assert.equal(up.status, 500);
        assert.equal(up.body.error, 'decrypt_failed');
        assertNoLeak(assert, [['update', up.text], ['dispatch', d.text]], ['sec-a', key2, H.KEY]);
        // unrelated write under the wrong key must preserve the old ciphertext byte for byte
        assert.equal((await pushRoutes(h2, 'team-a', { 'pr-merged': ['conn-a'] }, { dedupeWindow: 5 })).status, 200);
        assert.deepEqual(JSON.parse(fs.readFileSync(h2.storeFile, 'utf8')).connections['conn-a'].secrets.token, k1);
        // and the operator can still delete it (escape hatch)
        assert.equal((await adm(request(h2.app).delete('/api/notify/connections/conn-a'))).status, 200);
    });

    test('route to a connection deleted after push, or to one that never existed: failed receipt, 200, no throw', async () => {
        const p = makeProvider('t1');
        const h = makeHarness({ providers: [p] });
        mkConn(h, 'conn-a', 't1'); mkConn(h, 'conn-b', 't1');
        await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a', 'conn-b', 'ghost'] });
        h.store.deleteConnection('conn-a');
        const r = await post(h);
        assert.equal(r.status, 200);
        assert.equal(r.body.delivered, 1);
        const err = Object.fromEntries(r.body.receipts.map((x) => [x.connectionId, x.error]));
        assert.equal(err['conn-a'], 'unknown connection');
        assert.equal(err.ghost, 'unknown connection');
        assert.equal(p.calls.length, 1);
    });

    test('a stored connection whose provider is no longer registered fails closed ("unknown provider"), nothing sent', async () => {
        const dir = path.join(H.TMP, 'noprov-' + rand(4));
        const h1 = makeHarness({ dir, providers: [makeProvider('gone'), createTestProvider()] });
        mkConn(h1, 'conn-a', 'gone');
        await pushRoutes(h1, 'team-a', { 'pr-merged': ['conn-a'] });
        const h2 = makeHarness({ dir });
        const r = await post(h2);
        assert.equal(r.status, 200);
        assert.equal(r.body.receipts[0].error, 'unknown provider');
        assert.equal(r.body.delivered, 0);
    });

    test('auth matrix: no credential => 401 everywhere; the fleet key is refused on every admin route', async () => {
        const h = makeHarness();
        const admin = [['get', '/api/notify/status'], ['get', '/api/notify/connections'], ['post', '/api/notify/connections'],
            ['get', '/api/notify/connections/x'], ['put', '/api/notify/connections/x'], ['delete', '/api/notify/connections/x'],
            ['get', '/api/notify/receipts']];
        const fleet = [['put', '/api/notify/routes/team-a'], ['get', '/api/notify/routes/team-a'], ['post', '/api/notify']];
        for (const [m, u] of [...admin, ...fleet]) {
            assert.equal((await request(h.app)[m](u).send({})).status, 401, `no key ${m} ${u}`);
            assert.equal((await request(h.app)[m](u).set('x-api-key', 'wrong-' + rand()).send({})).status, 401, `bad key ${m} ${u}`);
        }
        for (const [m, u] of admin) {
            const s = (await flt(request(h.app)[m](u)).send({})).status;
            assert.ok(s === 401 || s === 403, `fleet key on admin route ${m} ${u} -> ${s}`);
        }
        for (const [m, u] of fleet) {
            const s = (await adm(request(h.app)[m](u)).send({})).status;
            assert.notEqual(s, 401, `admin key on fleet route ${m} ${u}`);
        }
    });
});

// ===========================================================================
describe('3. cross-team isolation', () => {
    test('team A\'s push cannot touch team B\'s routes, even with a hostile "team" field in the body', async () => {
        const h = makeHarness();
        mkConn(h, 'conn-a'); mkConn(h, 'conn-b');
        await pushRoutes(h, 'team-b', { 'pr-merged': ['conn-b'] });
        const body = { config: cfg({ 'pr-merged': ['conn-a'] }), team: 'team-b', teams: { 'team-b': {} } };
        assert.equal((await flt(request(h.app).put('/api/notify/routes/team-a')).send(body)).status, 200);
        const gb = await flt(request(h.app).get('/api/notify/routes/team-b'));
        assert.deepEqual(gb.body.config.routes, { 'pr-merged': ['conn-b'] });
        const ga = await flt(request(h.app).get('/api/notify/routes/team-a'));
        assert.deepEqual(ga.body.config.routes, { 'pr-merged': ['conn-a'] });
    });

    test('a dispatch for team A uses only team A\'s routes and catalog', async () => {
        const p = makeProvider('t1');
        const h = makeHarness({ providers: [p] });
        mkConn(h, 'conn-a', 't1'); mkConn(h, 'conn-b', 't1');
        await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a'] });
        await pushRoutes(h, 'team-b', { 'pr-merged': ['conn-b'], 'only-b': ['conn-b'] }, undefined, layer('only-b'));
        const ra = await post(h, notice({ team: 'team-a' }));
        assert.deepEqual(ra.body.receipts.map((x) => x.connectionId), ['conn-a']);
        assert.deepEqual(p.calls.map((c) => c.id), ['conn-a']);
        const rx = await post(h, notice({ team: 'team-a', type: 'only-b' }));
        assert.equal(rx.status, 400, 'team A must not see team B\'s private notice type');
    });

    test('dedupe windows are per team: same type + ref in two teams do not suppress each other', async () => {
        const p = makeProvider('t1');
        const h = makeHarness({ providers: [p] });
        mkConn(h, 'conn-a', 't1'); mkConn(h, 'conn-b', 't1');
        await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a'] });
        await pushRoutes(h, 'team-b', { 'pr-merged': ['conn-b'] });
        assert.equal((await post(h, notice({ team: 'team-a' }))).body.delivered, 1);
        assert.equal((await post(h, notice({ team: 'team-b' }))).body.delivered, 1);
        assert.equal((await post(h, notice({ team: 'team-a' }))).body.suppressed, 1);
    });

    test('CHARACTERIZATION (by design, not a defect): the fleet key is fleet-wide, so a registered team CAN overwrite another registered team\'s routes', async () => {
        const h = makeHarness();
        mkConn(h, 'conn-a');
        await pushRoutes(h, 'team-b', { 'pr-merged': ['conn-a'] });
        // any holder of the fleet key can replace team-b's routes via the team-b URL; the route comment says scoping is "well-formed id AND registered team"
        const r = await pushRoutes(h, 'team-b', {});
        assert.equal(r.status, 200);
        assert.deepEqual(h.store.getTeamRoutes('team-b').config.routes, {});
    });

    test('a route-schema-valid id grammar mismatch: every connection id the store accepts must be routable',
        async () => {
            const h = makeHarness();
            // Invariant: a connection id the store accepts is one a team can route to. The store now
            // refuses ids the route schema would refuse (digit-first, >32 chars) at creation time.
            for (const id of ['1password', 'a' + 'b'.repeat(32), 'a' + 'b'.repeat(31)]) {
                const created = await adm(request(h.app).post('/api/notify/connections'))
                    .send({ id, provider: 'test', label: 'l', secrets: { token: 't' } });
                assert.ok([201, 400].includes(created.status), `unexpected create status ${created.status}`);
                if (created.status !== 201) continue;
                const pushed = await pushRoutes(h, 'team-a', { 'pr-merged': [id] });
                assert.equal(pushed.status, 200, `accepted by the store, refused by the route schema: ${pushed.text.slice(0, 160)}`);
            }
            const bad = await adm(request(h.app).post('/api/notify/connections'))
                .send({ id: '1password', provider: 'test', label: 'l', secrets: { token: 't' } });
            assert.equal(bad.status, 400);
        });
});

// ===========================================================================
describe('4. policy correctness', () => {
    async function twoConnHarness(over) {
        const p = makeProvider('t1', over && over.provider);
        const h = makeHarness({ providers: [p], ...(over && over.harness) });
        mkConn(h, 'conn-a', 't1'); mkConn(h, 'conn-b', 't1');
        return { h, p };
    }

    test('two concurrent identical notices both deliver (documented MVP gap); the third is deduped', async () => {
        const { h, p } = await twoConnHarness({ provider: { send: async () => { await sleep(15); return {}; } } });
        await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a'] });
        const [r1, r2] = await Promise.all([post(h), post(h)]);
        assert.equal(r1.body.delivered, 1);
        assert.equal(r2.body.delivered, 1, 'documented: check/record are not atomic across awaited deliveries');
        const r3 = await post(h);
        assert.equal(r3.body.suppressed, 1);
        assert.equal(p.calls.length, 2);
    });

    test('failed sends DO consume rate-limit slots; the window then re-opens; suppressions consume none', async () => {
        const clock = makeClock();
        const p = makeProvider('t1', { send: async () => { throw new NotifySendError('upstream down'); } });
        const h = makeHarness({ providers: [p], clock,
            dispatcherOpts: { rateLimiter: policies.createRateLimiter({ limit: 2, clock: () => clock.date() }) } });
        mkConn(h, 'conn-a', 't1');
        await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a'] });
        const n = (i) => notice({ ref: `PR-${i}` });
        const a = await post(h, n(1)); const b = await post(h, n(2)); const c = await post(h, n(3));
        assert.equal(a.body.failed, 1); assert.equal(b.body.failed, 1);
        assert.equal(c.body.suppressed, 1);
        assert.equal(c.body.receipts[0].suppressed, 'rate-limit');
        assert.equal(p.calls.length, 2, 'rate-limited notice reached no provider');
        clock.advance(601 * 1000);
        assert.equal((await post(h, n(4))).body.failed, 1, 'window re-opened (send attempted again)');
        assert.equal(p.calls.length, 3);
    });

    test('quiet-hours / dedupe suppression consumes no rate slot and opens no dedupe window', async () => {
        const clock = makeClock('2026-06-15T03:00:00.000Z'); // 23:00 America/New_York
        const p = makeProvider('t1');
        const h = makeHarness({ providers: [p], clock,
            dispatcherOpts: { rateLimiter: policies.createRateLimiter({ limit: 1, clock: () => clock.date() }) } });
        mkConn(h, 'conn-a', 't1');
        await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a'] }, { quietHours: { start: '22:00', end: '07:00', timezone: 'America/New_York' } });
        for (let i = 0; i < 5; i += 1) {
            const r = await post(h, notice({ ref: 'PR-Q' }));
            assert.equal(r.body.receipts[0].suppressed, 'quiet-hours');
        }
        assert.equal(p.calls.length, 0);
        clock.set('2026-06-15T12:00:00.000Z'); // 08:00 local -> awake
        const ok = await post(h, notice({ ref: 'PR-Q' }));
        assert.equal(ok.body.delivered, 1, 'quiet-hours suppression must not poison dedupe or the rate limiter');
        // critical bypasses quiet hours but NOT the rate limiter / dedupe
        clock.set('2026-06-15T03:00:00.000Z');
        const crit = await post(h, notice({ ref: 'PR-C', severity: 'critical' }));
        assert.equal(crit.body.receipts[0].suppressed, 'rate-limit');
    });

    test('one connection rate-limited, the other delivers: partial result, dedupe recorded', async () => {
        const clock = makeClock();
        const rl = policies.createRateLimiter({ limit: 1, clock: () => clock.date() });
        const { h, p } = await twoConnHarness({ harness: { clock, dispatcherOpts: { rateLimiter: rl } } });
        rl.take('conn-a'); // pre-spend conn-a
        await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a', 'conn-b'] });
        const r = await post(h);
        assert.equal(r.body.delivered, 1); assert.equal(r.body.suppressed, 1); assert.equal(r.body.failed, 0);
        assert.equal(r.body.ok, true);
        assert.deepEqual(p.calls.map((c) => c.id), ['conn-b']);
        assert.equal((await post(h)).body.receipts.every((x) => x.suppressed === 'dedupe'), true);
    });

    test('a send that times out is ONE failed receipt; when it later resolves or rejects nothing else is written', async () => {
        const unhandled = [];
        const onUnhandled = (e) => unhandled.push(e);
        process.on('unhandledRejection', onUnhandled);
        try {
            let mode = 'slow-ok';
            const p = makeProvider('t1', {
                send: () => new Promise((resolve, reject) => {
                    if (mode === 'slow-ok') setTimeout(() => resolve({ providerMessageId: 'late-1' }), 70);
                    else if (mode === 'slow-fail') setTimeout(() => reject(new Error('late failure')), 70);
                    else resolve({ providerMessageId: 'fast' });
                }),
            });
            const h = makeHarness({ providers: [p], dispatcherOpts: { sendTimeoutMs: 20 } });
            mkConn(h, 'conn-a', 't1');
            await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a'] });
            const r1 = await post(h, notice({ ref: 'PR-T1' }));
            assert.equal(r1.body.delivered, 0);
            assert.equal(r1.body.receipts[0].error, 'send timed out');
            const before = readLines(h.receiptFile).length;
            mode = 'slow-fail';
            const r2 = await post(h, notice({ ref: 'PR-T2' }));
            assert.equal(r2.body.receipts[0].error, 'send timed out');
            await sleep(120); // both late settlements land here
            assert.equal(readLines(h.receiptFile).length, before + 1, 'late settlement wrote no further receipt');
            assert.deepEqual(unhandled, []);
            // a timed-out notice opened no dedupe window: the retry is attempted
            mode = 'fast';
            const r3 = await post(h, notice({ ref: 'PR-T1' }));
            assert.equal(r3.body.delivered, 1);
        } finally { process.removeListener('unhandledRejection', onUnhandled); }
    });

    test('a provider that never settles cannot hang the request past the timeout', async () => {
        const p = makeProvider('t1', { send: () => new Promise(() => {}) });
        const h = makeHarness({ providers: [p], dispatcherOpts: { sendTimeoutMs: 25 } });
        mkConn(h, 'conn-a', 't1');
        await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a'] });
        const t0 = Date.now();
        const r = await post(h);
        assert.ok(Date.now() - t0 < 2000);
        assert.equal(r.body.receipts[0].error, 'send timed out');
    });

    test('dedupeWindow edge values accepted/refused at the route boundary', async () => {
        const h = makeHarness();
        for (const w of [0, 1, 300, 86400]) assert.equal((await pushRoutes(h, 'team-a', {}, { dedupeWindow: w })).status, 200, `window ${w}`);
        for (const w of [-1, 1.5, 86401, '300', null, true, [], {}, 1e21]) {
            assert.equal((await pushRoutes(h, 'team-a', {}, { dedupeWindow: w })).status, 400, `window ${JSON.stringify(w)}`);
        }
    });

    test('dedupeWindow 0 disables dedupe end to end; a tampered non-numeric stored window fails toward delivery', async () => {
        const p = makeProvider('t1');
        const h = makeHarness({ providers: [p] });
        mkConn(h, 'conn-a', 't1');
        await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a'] }, { dedupeWindow: 0 });
        assert.equal((await post(h)).body.delivered, 1);
        assert.equal((await post(h)).body.delivered, 1);
        // tamper the stored config directly (bypasses validation) -> NaN / Infinity / negative / string
        for (const bad of ['abc', -5, null, Infinity]) {
            h.store._mutate((d) => { d.routes['team-a'].config.dedupeWindow = bad; });
            assert.equal((await post(h)).body.delivered, 1, `window ${String(bad)} must not suppress`);
        }
    });

    test('dedupe tracker boundaries: expiry is exclusive at the exact instant, record is read-after-check only, memory is capped', () => {
        const clock = makeClock();
        const t = policies.createDedupeTracker({ clock: () => clock.date(), maxEntries: 3 });
        assert.equal(t.check('a', 'x', 'r', 1).duplicate, false);
        t.record('a', 'x', 'r', 1);
        clock.advance(999);
        assert.equal(t.check('a', 'x', 'r', 1).duplicate, true);
        clock.advance(1);
        assert.equal(t.check('a', 'x', 'r', 1).duplicate, false, 'expired exactly at window end');
        for (let i = 0; i < 10; i += 1) t.record('a', 'x', `r${i}`, 600);
        assert.ok(t.size() <= 3);
        assert.equal(t.check('a', 'x', 'r0', 600).duplicate, false, 'evicted oldest fails toward delivery');
        assert.equal(t.check('a', 'x', 'r9', 600).duplicate, true);
        // window 0 / NaN / Infinity / negative never record
        for (const w of [0, NaN, Infinity, -1]) assert.equal(t.record('a', 'x', 'z', w).recorded, false);
    });

    test('quiet hours across DST transitions (America/New_York) and fail-toward-delivery on bad input', () => {
        const q = (iso, sev = 'info', qh) => policies.quietHoursDecision(sev, qh || { start: '01:30', end: '03:30', timezone: 'America/New_York' }, new Date(iso));
        // spring forward 2026-03-08: 02:00 EST -> 03:00 EDT
        assert.equal(q('2026-03-08T06:29:00Z').suppress, false); // 01:29 EST
        assert.equal(q('2026-03-08T06:30:00Z').suppress, true);  // 01:30 EST
        assert.equal(q('2026-03-08T06:59:00Z').suppress, true);  // 01:59 EST
        assert.equal(q('2026-03-08T07:00:00Z').suppress, true);  // 03:00 EDT (02:xx never existed)
        assert.equal(q('2026-03-08T07:29:00Z').suppress, true);  // 03:29 EDT
        assert.equal(q('2026-03-08T07:30:00Z').suppress, false); // 03:30 EDT, end exclusive
        // fall back 2026-11-01: 01:00-02:00 happens twice
        const fb = { start: '01:30', end: '02:30', timezone: 'America/New_York' };
        assert.equal(q('2026-11-01T05:29:00Z', 'info', fb).suppress, false); // 01:29 EDT
        assert.equal(q('2026-11-01T05:30:00Z', 'info', fb).suppress, true);  // 01:30 EDT
        assert.equal(q('2026-11-01T06:30:00Z', 'info', fb).suppress, true);  // 01:30 EST (repeat)
        assert.equal(q('2026-11-01T07:29:00Z', 'info', fb).suppress, true);  // 02:29 EST
        assert.equal(q('2026-11-01T07:30:00Z', 'info', fb).suppress, false); // 02:30 EST
        // critical always bypasses
        assert.equal(q('2026-03-08T06:45:00Z', 'critical').suppress, false);
        // bad zone / bad severity / bad time / equal bounds: deliver + warn, never swallow
        for (const tz of ['', 'utc', 'Nope/Zone', '+05:00', 'EST5EDT/../x', null, 5]) {
            const d = q('2026-06-15T12:00:00Z', 'info', { start: '01:00', end: '02:00', timezone: tz });
            assert.equal(d.suppress, false, `tz ${JSON.stringify(tz)}`);
            assert.equal(d.warning, 'invalid-timezone');
        }
        assert.equal(policies.quietHoursDecision('bogus', { start: '01:00', end: '02:00', timezone: 'UTC' }, new Date()).warning, 'invalid-severity');
        assert.equal(policies.quietHoursDecision('info', { start: '01:00', end: '02:00', timezone: 'UTC' }, new Date('x')).warning, 'invalid-time');
        assert.equal(policies.quietHoursDecision('info', { start: '01:00', end: '01:00', timezone: 'UTC' }, new Date()).warning, 'invalid-quiet-hours');
        assert.equal(policies.quietHoursDecision('info', { start: '24:00', end: '01:00', timezone: 'UTC' }, new Date()).warning, 'invalid-quiet-hours');
    });

    test('severity precedence: caller > override > catalog default; invalid caller severity is a 400, never silently replaced', async () => {
        const h = makeHarness({ providers: [makeProvider('t1')] });
        mkConn(h, 'conn-a', 't1');
        await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a'], 'build-failed': ['conn-a'] }, { severityOverrides: { 'build-failed': 'critical' } });
        assert.equal((await post(h, notice({ ref: 'a1' }))).body.severity, 'info');
        assert.equal((await post(h, notice({ ref: 'a2', type: 'build-failed' }))).body.severity, 'critical');
        assert.equal((await post(h, notice({ ref: 'a3', type: 'build-failed', severity: 'info' }))).body.severity, 'info');
        for (const s of ['CRITICAL', 'urgent', '', null, 3, ['info']]) {
            assert.equal((await post(h, notice({ ref: 'a4', severity: s }))).status, 400, `severity ${JSON.stringify(s)}`);
        }
    });

    test('no route / route-nowhere are explicit 200 routed:false, an unknown type is 400, no routes pushed is 404', async () => {
        const h = makeHarness();
        assert.equal((await post(h)).status, 404);
        await pushRoutes(h, 'team-a', { 'build-failed': [] });
        const a = await post(h, notice({ type: 'pr-merged' }));
        assert.equal(a.status, 200); assert.equal(a.body.routed, false); assert.equal(a.body.reason, 'no-route');
        const b = await post(h, notice({ type: 'build-failed' }));
        assert.equal(b.body.reason, 'route-nowhere');
        assert.equal((await post(h, notice({ type: 'not-a-type' }))).status, 400);
        assert.equal(readLines(h.receiptFile).length, 0);
    });

    test('receipt write failure: delivered anyway, caller gets 500 + the computed result (not silent)', async () => {
        const p = makeProvider('t1');
        const h = makeHarness({ providers: [p] });
        mkConn(h, 'conn-a', 't1');
        await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a'] });
        fs.mkdirSync(h.receiptFile); // a directory where the file should be
        const cap = captureConsole();
        let r;
        try { r = await post(h); } finally { cap.restore(); }
        assert.equal(r.status, 500);
        assert.equal(r.body.error, 'receipt_write_failed');
        assert.equal(r.body.result.delivered, 1);
        assert.equal(p.calls.length, 1);
        assert.match(JSON.stringify(r.body), /receipt write failed/);
    });
});
