//
//  xaca-1400-007b-adversarial-bounds.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1400-007 -- adversarial pass, part 2: input bounds and persistence.
 * Tests marked { todo } demonstrate a REAL defect (see the subitem report).
 */

const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const H = require('./xaca-1400-007-helpers');
const {
    request, fs, path, rand, adm, flt, cfg, pushRoutes, notice, post, mkConn, readLines,
    makeHarness, makeProvider, createReceiptLog, createNotifyStore, createProviderRegistry, createTestProvider,
} = H;

after(() => { H.restoreEnv(); H.cleanup(); });

const CATALOG_TAG = 'notice-types/v1';
const manyTypes = (n, prefix = 't') => ({
    $schema: CATALOG_TAG, schemaVersion: 1,
    types: Array.from({ length: n }, (_, i) => ({ id: `${prefix}${String(i).padStart(4, '0')}`, defaultSeverity: 'info', description: `d${i}` })),
});
const typeIds = (n, prefix = 't') => manyTypes(n, prefix).types.map((t) => t.id);

async function routedHarness(providerOpts) {
    const p = makeProvider('t1', providerOpts);
    const h = makeHarness({ providers: [p] });
    mkConn(h, 'conn-a', 't1');
    await pushRoutes(h, 'team-a', { 'pr-merged': ['conn-a'] });
    return { h, p };
}

// ===========================================================================
describe('5. input bounds', () => {
    test('route-type cap: 64 notice types accepted, 65 refused (and the refusal stores nothing)', async () => {
        const h = makeHarness();
        const ids = typeIds(65);
        const mk = (n) => Object.fromEntries(ids.slice(0, n).map((id) => [id, []]));
        assert.equal((await pushRoutes(h, 'team-a', mk(64), undefined, manyTypes(64))).status, 200);
        const before = JSON.stringify(h.store.getTeamRoutes('team-a'));
        const r = await pushRoutes(h, 'team-a', mk(65), undefined, manyTypes(64));
        assert.equal(r.status, 400);
        assert.match(r.body.message, /at most 64/);
        assert.equal(JSON.stringify(h.store.getTeamRoutes('team-a')), before);
    });

    test('connections-per-type cap: 16 accepted, 17 / duplicates / non-strings / malformed ids refused', async () => {
        const h = makeHarness();
        const ids = Array.from({ length: 17 }, (_, i) => `c${String(i).padStart(2, '0')}`);
        assert.equal((await pushRoutes(h, 'team-a', { 'pr-merged': ids.slice(0, 16) })).status, 200);
        assert.equal((await pushRoutes(h, 'team-a', { 'pr-merged': ids })).status, 400);
        for (const bad of [['c01', 'c01'], [1], [null], [['c01']], ['UPPER'], ['has space'], ['a'.repeat(33)], ['-lead'], 'c01', { 0: 'c01' }, null]) {
            assert.equal((await pushRoutes(h, 'team-a', { 'pr-merged': bad })).status, 400, JSON.stringify(bad));
        }
    });

    test('a hostile routes object with 20,000 malformed keys is refused promptly with a bounded error body', async () => {
        const h = makeHarness();
        const routes = {};
        for (let i = 0; i < 20000; i += 1) routes[`BAD_${i}`] = ['x'];
        const t0 = Date.now();
        const r = await pushRoutes(h, 'team-a', routes);
        assert.equal(r.status, 400);
        assert.ok(r.text.length < 2000, `error body ${r.text.length} bytes`);
        assert.ok(Date.now() - t0 < 5000, 'validation did not take pathological time');
    });

    test('a hostile routes object with 20,000 VALID-looking unknown types is refused with a bounded error body', async () => {
        const h = makeHarness();
        const routes = Object.fromEntries(typeIds(20000, 'u').map((id) => [id, []]));
        const r = await pushRoutes(h, 'team-a', routes);
        assert.equal(r.status, 400);
        assert.ok(r.text.length < 2000);
    });

    test('team notice-type catalog is bounded (a fleet-key holder cannot bloat the store with thousands of types)',
        async () => {
            const h = makeHarness();
            const r = await pushRoutes(h, 'team-a', {}, undefined, manyTypes(3000));
            const size = fs.existsSync(h.storeFile) ? fs.statSync(h.storeFile).size : 0;
            assert.equal(r.status, 400, `accepted 3,000 catalog types; store file is now ${size} bytes`);
        });

    test('label / param / secret length bounds are exact; id grammar bounds are exact', async () => {
        const h = makeHarness({ providers: [makeProvider('t1')] });
        const mk = (over) => adm(request(h.app).post('/api/notify/connections'))
            .send({ id: 'c-' + rand(3), provider: 't1', label: 'l', secrets: { token: 't' }, ...over });
        assert.equal((await mk({ label: 'x'.repeat(200) })).status, 201);
        assert.equal((await mk({ label: 'x'.repeat(201) })).status, 400);
        assert.equal((await mk({ label: '   ' })).status, 400);
        assert.equal((await mk({ params: { url: 'u'.repeat(4096) } })).status, 201);
        assert.equal((await mk({ params: { url: 'u'.repeat(4097) } })).status, 400);
        assert.equal((await mk({ secrets: { token: 's'.repeat(4096) } })).status, 201);
        assert.equal((await mk({ secrets: { token: 's'.repeat(4097) } })).status, 400);
        assert.equal((await mk({ id: 'a' + 'b'.repeat(31) })).status, 201);
        assert.equal((await mk({ id: 'a' + 'b'.repeat(32) })).status, 400);
        for (const id of ['', '-x', 'UP', 'a_b', 'a.b', 'a b', '../x', 'a/b', 'a\nb', 'ok\n', null, 5, ['a'], { a: 1 }]) {
            assert.equal((await mk({ id })).status, 400, `id ${JSON.stringify(id)}`);
        }
        for (const bad of [null, 'str', 5, [], [1]]) {
            assert.equal((await mk({ params: bad })).status, 400, `params ${JSON.stringify(bad)}`);
            assert.equal((await mk({ secrets: bad })).status, 400, `secrets ${JSON.stringify(bad)}`);
        }
        assert.equal((await mk({ secrets: { token: 123 } })).status, 400);
        assert.equal((await mk({ secrets: { token: ['a'] } })).status, 400);
    });

    test('unicode / NUL / astral / lone-surrogate secrets survive an encrypt-decrypt round trip exactly', () => {
        const h = makeHarness({ providers: [makeProvider('t1')] });
        const values = ['\u{1F510}'.repeat(1000), 'nul\u0000inside', 'café'.repeat(500), '\ud800 lone', '  padded  ', 'line\nbreak\r\n', '‮RTL'];
        values.forEach((v, i) => {
            h.store.createConnection({ id: `u${i}`, provider: 't1', label: 'u', secrets: { token: v } });
            // lone surrogates cannot survive UTF-8; everything else must be byte-exact
            const got = h.store.resolveConnection(`u${i}`).secrets.token;
            if (v === '\ud800 lone') assert.equal(got, '� lone'); else assert.equal(got, v);
        });
    });

    test('a secret of whitespace only is stored, but "" / null clear the field', () => {
        const h = makeHarness({ providers: [makeProvider('t1', { validate: () => {} })] });
        h.store.createConnection({ id: 'c1', provider: 't1', label: 'l', secrets: { token: '   ' } });
        assert.equal(h.store.resolveConnection('c1').secrets.token, '   ');
        h.store.updateConnection('c1', { secrets: { token: '' } });
        assert.deepEqual(h.store.resolveConnection('c1').secrets, {});
    });

    test('notice field bounds: title 200/201, body 4000/4001, ref 128/129, grammar, control chars, unknown fields', async () => {
        const { h, p } = await routedHarness();
        const ok = async (over) => (await post(h, notice({ ref: 'R-' + rand(3), ...over }))).status;
        assert.equal(await ok({ title: 'x'.repeat(200) }), 200);
        assert.equal(await ok({ title: 'x'.repeat(201) }), 400);
        assert.equal(await ok({ title: '   ' }), 400);
        assert.equal(await ok({ title: '' }), 400);
        assert.equal(await ok({ body: 'b'.repeat(4000) }), 200);
        assert.equal(await ok({ body: 'b'.repeat(4001) }), 400);
        assert.equal(await ok({ body: '' }), 200, 'empty body allowed');
        assert.equal((await post(h, notice({ ref: 'a'.repeat(128) }))).status, 200);
        assert.equal((await post(h, notice({ ref: 'a'.repeat(129) }))).status, 400);
        for (const ref of ['PR-1\n', 'a b', '|x', '-x', '', 'a\u0000b', 'a‮b', 'é', 5, ['a'], null]) {
            assert.equal((await post(h, notice({ ref }))).status, 400, `ref ${JSON.stringify(ref)}`);
        }
        for (const n of [{ team: 'Team-A' }, { team: 'team-a\n' }, { team: '' }, { team: 5 }, { type: 'PR' }, { type: 'a'.repeat(33) }, { type: 'pr_merged' },
            { title: 5 }, { body: null }, { extra: 1 }, { team: ['team-a'] }]) {
            assert.equal((await post(h, notice(n))).status, 400, JSON.stringify(n));
        }
        for (const bad of [null, [], 'str', 5]) {
            const r = await flt(request(h.app).post('/api/notify')).set('content-type', 'application/json').send(JSON.stringify(bad));
            assert.ok(r.status >= 400 && r.status < 500, `body ${JSON.stringify(bad)} -> ${r.status}`);
        }
        const before = p.calls.length;
        // control characters / bidi / astral / NUL in title+body reach the provider byte-exact and never reach receipts
        const T = 'T\u0000\u001b[31m‮\u{1F600}\nx'; const B = 'B\u0000\r\n \u{1F600}';
        const r = await post(h, notice({ ref: 'R-ctl', title: T, body: B }));
        assert.equal(r.status, 200);
        assert.equal(p.calls.length, before + 1);
        assert.equal(p.calls[before].message.title, T);
        assert.equal(p.calls[before].message.body, B);
        const rtext = fs.readFileSync(h.receiptFile, 'utf8');
        assert.ok(!rtext.includes(JSON.stringify(T).slice(1, -1)) && !rtext.includes(JSON.stringify(B).slice(1, -1)));
        for (const line of readLines(h.receiptFile)) {
            const rec = JSON.parse(line);
            assert.ok(!('title' in rec) && !('body' in rec));
        }
    });

    test('GET /api/notify/receipts: limit and team parameters are strictly validated', async () => {
        const { h } = await routedHarness();
        for (let i = 0; i < 5; i += 1) await post(h, notice({ ref: `R-${i}` }));
        const get = (q) => adm(request(h.app).get('/api/notify/receipts' + q));
        for (const q of ['?limit=0', '?limit=201', '?limit=-1', '?limit=abc', '?limit=1e2', '?limit=50.5', '?limit=%2050', '?limit=',
            '?limit=1&limit=2', '?limit[]=1', '?limit[a]=1', '?limit=99999', '?team=', '?team=Team-A', '?team[]=team-a', '?team=a&team=b', '?team=team-a%0A']) {
            assert.equal((await get(q)).status, 400, q);
        }
        assert.equal((await get('?limit=200')).status, 200);
        assert.equal((await get('?limit=0050')).body.receipts.length, 5);
        const two = await get('?limit=2');
        assert.deepEqual(two.body.receipts.map((x) => x.ref), ['R-4', 'R-3'], 'newest first');
        assert.equal((await get('?team=team-b')).body.receipts.length, 0);
        assert.equal((await get('?team=team-a&limit=1')).body.receipts.length, 1);
        assert.equal((await get('')).body.receipts.length, 5, 'default limit');
    });

    test('quiet hours / dedupeWindow / severityOverrides / aliases structural abuse is refused with bounded, value-free messages', async () => {
        const h = makeHarness();
        const SEC = 'echo-' + rand();
        const bad = [
            { quietHours: { start: '25:00', end: '01:00', timezone: 'UTC' } },
            { quietHours: { start: '01:00', end: '01:00', timezone: 'UTC' } },
            { quietHours: { start: '01:00', end: '02:00', timezone: SEC } },
            { quietHours: { start: '01:00', end: '02:00', timezone: 'Not/AZone' } },
            { quietHours: { start: '01:00\n', end: '02:00', timezone: 'UTC' } },
            { quietHours: { start: '01:00', end: '02:00' } },
            { quietHours: [] },
            { severityOverrides: { 'pr-merged': SEC } },
            { severityOverrides: { 'no-such-type': 'info' } },
            { aliases: { ok: { provider: 'slack', target: { secretRef: SEC } } } },
            { aliases: { ok: { provider: 'slack', target: { secretRef: 'https://hooks.example/' + SEC } } } },
            { aliases: { ok: { provider: 'slack', target: { secretRef: 'vault:a/b', extra: SEC } } } },
            { unexpected: SEC },
        ];
        for (const extra of bad) {
            const r = await pushRoutes(h, 'team-a', {}, extra);
            assert.equal(r.status, 400, JSON.stringify(extra).slice(0, 80));
            assert.ok(!r.text.includes(SEC), `value echoed for ${JSON.stringify(extra).slice(0, 60)}`);
            assert.ok(r.text.length < 1500);
        }
        assert.equal(h.store.getTeamRoutes('team-a'), null);
    });
});

// ===========================================================================
describe('6. persistence', () => {
    test('25 concurrent route pushes + 25 concurrent connection creates: the file is valid JSON and complete, no temp files remain', async () => {
        const teams = Array.from({ length: 25 }, (_, i) => `team-${String.fromCharCode(97 + i)}`);
        const h = makeHarness({ providers: [makeProvider('t1')], teams });
        const reqs = [
            ...teams.map((t) => pushRoutes(h, t, { 'pr-merged': ['conn-a'] })),
            ...Array.from({ length: 25 }, (_, i) => adm(request(h.app).post('/api/notify/connections'))
                .send({ id: `c${i}`, provider: 't1', label: 'l', secrets: { token: `tok-${i}` } })),
        ];
        const res = await Promise.all(reqs);
        assert.ok(res.every((r) => r.status === 200 || r.status === 201), res.map((r) => r.status).join(','));
        const j = JSON.parse(fs.readFileSync(h.storeFile, 'utf8'));
        assert.equal(Object.keys(j.routes).length, 25);
        assert.equal(Object.keys(j.connections).length, 25);
        assert.deepEqual(fs.readdirSync(h.dir).filter((f) => f.includes('.tmp-')), []);
        // a fresh process-equivalent reload sees all of it
        const again = createNotifyStore({ file: h.storeFile, key: H.KEY, registry: h.registry });
        assert.equal(again.listConnections().length, 25);
        for (let i = 0; i < 25; i += 1) assert.equal(again.resolveConnection(`c${i}`).secrets.token, `tok-${i}`);
    });

    test('10 racing pushes to the SAME team leave exactly one coherent winner (no merged/torn config)', async () => {
        const h = makeHarness();
        const sets = Array.from({ length: 10 }, (_, i) => ({ 'pr-merged': [`c${i}`], 'build-failed': [`c${i}`] }));
        const res = await Promise.all(sets.map((s) => pushRoutes(h, 'team-a', s)));
        assert.ok(res.every((r) => r.status === 200));
        const stored = JSON.parse(fs.readFileSync(h.storeFile, 'utf8')).routes['team-a'].config.routes;
        assert.ok(sets.some((s) => JSON.stringify(s) === JSON.stringify(stored)), 'stored routes equal one pushed set');
        assert.equal(stored['pr-merged'][0], stored['build-failed'][0]);
    });

    test('store and receipt files are mode 0600 (including a receipts file recreated by rotation)', async () => {
        const { h } = await routedHarness();
        await post(h);
        assert.equal(fs.statSync(h.storeFile).mode & 0o777, 0o600);
        assert.equal(fs.statSync(h.receiptFile).mode & 0o777, 0o600);
        const r = createReceiptLog({ file: path.join(h.dir, 'rot.jsonl'), maxBytes: 100 });
        for (let i = 0; i < 4; i += 1) r.append(r.newReceipt({ team: 'team-a', type: 'pr-merged', connectionId: 'c', ok: true }));
        assert.equal(fs.statSync(path.join(h.dir, 'rot.jsonl')).mode & 0o777, 0o600);
        assert.equal(fs.statSync(path.join(h.dir, 'rot.jsonl.1')).mode & 0o777, 0o600);
    });

    test('persist failure (unwritable directory): typed 500 with no secret, in-memory state unchanged, store recovers afterwards', { skip: process.getuid && process.getuid() === 0 ? 'root ignores chmod' : false }, async () => {
        const dir = path.join(H.TMP, 'ro-' + rand(4));
        fs.mkdirSync(dir, { recursive: true });
        const h = makeHarness({ dir, providers: [makeProvider('t1')] });
        mkConn(h, 'keep', 't1');
        const SEC = 'ro-secret-' + rand();
        fs.chmodSync(dir, 0o500);
        try {
            const r = await adm(request(h.app).post('/api/notify/connections'))
                .send({ id: 'new1', provider: 't1', label: 'l', secrets: { token: SEC } });
            assert.equal(r.status, 500);
            assert.equal(r.body.error, 'persist_failed');
            assert.ok(!r.text.includes(SEC));
            assert.equal(h.store.getConnection('new1'), null, 'memory not mutated by a failed persist');
            assert.equal((await pushRoutes(h, 'team-a', {})).status, 500);
            assert.equal(h.store.getTeamRoutes('team-a'), null);
            assert.equal((await adm(request(h.app).delete('/api/notify/connections/keep'))).status, 500);
            assert.ok(h.store.getConnection('keep'), 'delete that failed to persist did not remove it from memory');
        } finally { fs.chmodSync(dir, 0o700); }
        assert.equal((await adm(request(h.app).post('/api/notify/connections'))
            .send({ id: 'new2', provider: 't1', label: 'l', secrets: { token: 'x' } })).status, 201);
        assert.deepEqual(fs.readdirSync(dir).filter((f) => f.includes('.tmp-')), []);
    });

    test('receipt rotation: many appends never leave an invalid line in either generation', () => {
        const file = path.join(H.TMP, 'rot-' + rand(4) + '.jsonl');
        const r = createReceiptLog({ file, maxBytes: 600 });
        for (let i = 0; i < 80; i += 1) r.append(r.newReceipt({ team: 'team-a', type: 'pr-merged', connectionId: `c${i}`, ok: i % 2 === 0, error: 'e' }));
        for (const f of [file, file + '.1']) {
            assert.ok(fs.existsSync(f), f);
            for (const line of readLines(f)) JSON.parse(line);
        }
        assert.ok(fs.statSync(file).size <= 600 + 400, 'live generation stays near the cap');
        assert.equal(fs.existsSync(file + '.2'), false, 'exactly one old generation');
    });

    test('receipts: a corrupt line anywhere (start/middle/end/binary) is skipped, the rest are returned newest-first', () => {
        const file = path.join(H.TMP, 'corrupt-' + rand(4) + '.jsonl');
        const good = (n) => JSON.stringify({ id: `ntc-${n}`, team: 'team-a', ok: true });
        fs.writeFileSync(file, ['{"truncated', good(1), '\u0000\u0001garbage', good(2), '[1,2]', 'null', '"str"', good(3), '{"x":'].join('\n'));
        const out = createReceiptLog({ file }).recent({ limit: 50 });
        assert.deepEqual(out.map((x) => x.id), ['ntc-3', 'ntc-2', 'ntc-1']);
    });

    test('receipts: allowlist strips every non-allowlisted key, forged suppressed values, and non-string provider ids', () => {
        const r = createReceiptLog({ file: path.join(H.TMP, 'al-' + rand(4) + '.jsonl') });
        const rec = r.newReceipt({
            team: 'team-a', type: 'pr-merged', connectionId: 'c', ok: false, error: 'x', title: 'T', body: 'B', url: 'https://d', token: 's',
            params: { a: 1 }, secrets: { b: 2 }, suppressed: 'because', providerMessageId: { evil: 1 },
        });
        assert.deepEqual(Object.keys(rec).sort(), ['connectionId', 'error', 'id', 'ok', 'team', 'ts', 'type']);
        const forged = r.append({ ...rec, title: 'T', body: 'B', url: 'u', __proto__: { x: 1 } });
        assert.ok(!('title' in forged) && !('url' in forged));
        assert.equal(r.newReceipt({ ok: 'yes' }).ok, false, 'truthy non-boolean ok is not ok');
        assert.equal(r.newReceipt({ ok: true, error: 'ignored' }).error, '', 'a successful receipt carries no error text');
    });

    test('a receipt whose append truncates (torn final line) must not swallow the NEXT receipt',
        () => {
            const file = path.join(H.TMP, 'torn-' + rand(4) + '.jsonl');
            const r = createReceiptLog({ file });
            const a = r.append(r.newReceipt({ team: 'team-a', type: 'pr-merged', connectionId: 'c1', ok: true }));
            fs.appendFileSync(file, '{"id":"ntc-torn","ts":"2026-06-15T12:00'); // ENOSPC / crash mid-write: no newline
            const b = r.append(r.newReceipt({ team: 'team-a', type: 'pr-merged', connectionId: 'c2', ok: true }));
            const ids = r.recent({ limit: 50 }).map((x) => x.id);
            assert.ok(ids.includes(b.id), `receipt ${b.id} was written but is invisible to recent(); visible: ${JSON.stringify(ids)} (first: ${a.id})`);
        });

    test('GET /receipts after a rotation still shows recent history from the previous generation',
        () => {
            const file = path.join(H.TMP, 'view-' + rand(4) + '.jsonl');
            const r = createReceiptLog({ file, maxBytes: 450 });
            const ids = [];
            for (let i = 0; i < 6; i += 1) ids.push(r.append(r.newReceipt({ team: 'team-a', type: 'pr-merged', connectionId: `c${i}`, ok: true })).id);
            const onDisk = readLines(file).length + readLines(file + '.1').length;
            const visible = r.recent({ limit: 50 }).length;
            assert.equal(visible, onDisk, `${onDisk} receipts on disk across both generations but recent() returns ${visible}`);
        });

    test('receipt log pointed at an unwritable location: append throws a type-only error naming no path', () => {
        const dir = path.join(H.TMP, 'rcpt-dir-' + rand(4));
        fs.mkdirSync(dir);
        const r = createReceiptLog({ file: dir }); // the "file" is a directory
        assert.throws(() => r.append(r.newReceipt({ ok: true })), (e) => /receipt write failed \(\w+\)$/.test(e.message) && !e.message.includes(dir));
    });
});
