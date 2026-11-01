//
//  xaca-1459-multi-owner.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1459 -- per-owner GitHub App credentials + per-machine repo binding.
 * Stubbed fetch, real store / placement / routes / dispatcher over a temp dir. NO network.
 * RSA keys are generated at runtime; nothing key-shaped is committed.
 */

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const request = require('./helpers/loopback-request');

const ADMIN = 'xaca1459-fake-admin-token-bbbbbbbb';
const SAVED_ADMIN = process.env.FLEET_ADMIN_TOKEN;
const SAVED_FLEET = process.env.FLEET_AUTH_TOKEN;
process.env.FLEET_ADMIN_TOKEN = ADMIN;
process.env.FLEET_AUTH_TOKEN = 'xaca1459-fake-fleet-token-aaaaaaaa';

const {
    createGithubClient, GithubError, resolveCredentials, credentialOwners, hasAnyCredential,
} = require('../lib/ci-dispatch-github');
const plc = require('../lib/ci-dispatch-placement');
const { createPoolStore, validateMachine } = require('../lib/ci-pool-store');
const { createAssignments } = require('../lib/ci-dispatch-assignments');
const { createAudit } = require('../lib/ci-dispatch-audit');
const { createAlerts } = require('../lib/ci-dispatch-alerts');
const { createDispatcher, hasCredentials, dormantReason } = require('../lib/ci-dispatcher');
const { registerCiPoolRoutes } = require('../lib/ci-pool-routes');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1459-'));
after(() => {
    fs.rmSync(TMP, { recursive: true, force: true });
    if (SAVED_ADMIN === undefined) delete process.env.FLEET_ADMIN_TOKEN; else process.env.FLEET_ADMIN_TOKEN = SAVED_ADMIN;
    if (SAVED_FLEET === undefined) delete process.env.FLEET_AUTH_TOKEN; else process.env.FLEET_AUTH_TOKEN = SAVED_FLEET;
});

const mkPair = () => crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});
const HOME = mkPair();      // DoubleNode (legacy single-App settings)
const BAND = mkPair();      // Contoso
const MAIN = mkPair();      // MainEventEntertainment

const T0 = Date.UTC(2026, 10, 1, 12, 0, 0);

// ---------------------------------------------------------------- credentials

describe('resolveCredentials (001)', () => {
    test('legacy single-App settings alone: non-strict, one complete credential serving any owner', () => {
        const r = resolveCredentials({ GITHUB_APP_CLIENT_ID: 'Iv1', GITHUB_APP_PRIVATE_KEY: HOME.privateKey });
        assert.equal(r.strict, false);
        assert.equal(r.legacy.complete, true);
        assert.deepEqual(credentialOwners({ GITHUB_APP_ID: '7', GITHUB_APP_PRIVATE_KEY: 'x' }), ['*']);
    });

    test('owner-keyed settings: strict, case-insensitive, odd owner names map to env infixes', () => {
        const r = resolveCredentials({
            GITHUB_APP_OWNERS: 'Contoso, Main-Event',
            GITHUB_APP_CONTOSO_CLIENT_ID: 'Iv-b', GITHUB_APP_CONTOSO_PRIVATE_KEY: 'k1',
            GITHUB_APP_MAIN_EVENT_APP_ID: '55', GITHUB_APP_MAIN_EVENT_PRIVATE_KEY: 'k2',
        });
        assert.equal(r.strict, true);
        assert.equal(r.byOwner.get('contoso').issuer, 'Iv-b');
        assert.equal(r.byOwner.get('main-event').issuer, '55');
        assert.deepEqual(credentialOwners({
            GITHUB_APP_OWNERS: 'Contoso', GITHUB_APP_CONTOSO_CLIENT_ID: 'i', GITHUB_APP_CONTOSO_PRIVATE_KEY: 'k',
        }), ['Contoso']);
    });

    test('legacy credential becomes the HOME owner (default DoubleNode, overridable) in strict mode', () => {
        const base = { GITHUB_APP_OWNERS: 'Contoso', GITHUB_APP_CONTOSO_CLIENT_ID: 'i', GITHUB_APP_CONTOSO_PRIVATE_KEY: 'k', GITHUB_APP_CLIENT_ID: 'Iv-home', GITHUB_APP_PRIVATE_KEY: 'hk' };
        assert.deepEqual(credentialOwners(base), ['Contoso', 'DoubleNode']);
        assert.deepEqual(credentialOwners(Object.assign({ GITHUB_APP_HOME_OWNER: 'Acme' }, base)), ['Acme', 'Contoso']);
    });

    test('an explicit per-owner entry for the home owner wins over the legacy settings', () => {
        const r = resolveCredentials({
            GITHUB_APP_OWNERS: 'DoubleNode', GITHUB_APP_DOUBLENODE_CLIENT_ID: 'explicit', GITHUB_APP_DOUBLENODE_PRIVATE_KEY: 'k',
            GITHUB_APP_CLIENT_ID: 'legacy', GITHUB_APP_PRIVATE_KEY: 'hk',
        });
        assert.equal(r.byOwner.get('doublenode').issuer, 'explicit');
    });

    test('partial credentials are present but never complete; malformed owner names are dropped', () => {
        const r = resolveCredentials({ GITHUB_APP_OWNERS: 'Contoso,bad owner!', GITHUB_APP_CONTOSO_CLIENT_ID: 'i' });
        assert.equal(r.byOwner.get('contoso').complete, false);
        assert.equal(r.byOwner.size, 1);
        assert.deepEqual(credentialOwners({ GITHUB_APP_OWNERS: 'Contoso', GITHUB_APP_CONTOSO_PRIVATE_KEY: 'k' }), []);
    });

    test('dormant check = at least one COMPLETE owner credential (legacy, owner-keyed, or neither)', () => {
        const on = { FLEET_CI_DISPATCHER: '1' };
        assert.equal(hasCredentials({}), false);
        assert.equal(hasCredentials({ GITHUB_APP_CLIENT_ID: 'i' }), false);
        assert.equal(hasCredentials({ GITHUB_APP_CLIENT_ID: 'i', GITHUB_APP_PRIVATE_KEY: 'k' }), true);
        assert.equal(hasAnyCredential({ GITHUB_APP_OWNERS: 'Contoso', GITHUB_APP_CONTOSO_APP_ID: '1', GITHUB_APP_CONTOSO_PRIVATE_KEY: 'k' }), true);
        assert.equal(hasCredentials({ GITHUB_APP_OWNERS: 'Contoso', GITHUB_APP_CONTOSO_APP_ID: '1' }), false);   // partial only
        assert.match(dormantReason(Object.assign({ GITHUB_APP_OWNERS: 'Contoso' }, on)), /credentials are not configured/);
        assert.equal(dormantReason(Object.assign({ GITHUB_APP_OWNERS: 'Contoso', GITHUB_APP_CONTOSO_APP_ID: '1', GITHUB_APP_CONTOSO_PRIVATE_KEY: 'k' }, on)), null);
    });
});

// ---------------------------------------------------- credential selection (002/003)

function res(status, body, headers = {}) {
    const h = new Map(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), String(v)]));
    return {
        status,
        headers: { get: (n) => (h.has(n.toLowerCase()) ? h.get(n.toLowerCase()) : null) },
        json: async () => body,
    };
}

/** Records, per request, the owner path and (for JWT calls) the JWT issuer + which key verifies it. */
function githubHarness(config) {
    const seen = [];
    let n = 0;
    const fetchStub = async (url, init) => {
        const u = new URL(url);
        const bearerTok = String(init.headers.Authorization || '').replace(/^Bearer /, '');
        const row = { method: init.method, path: u.pathname, bearer: bearerTok };
        if (bearerTok.split('.').length === 3 && bearerTok.startsWith('eyJ')) {
            const [h, c, s] = bearerTok.split('.');
            row.iss = JSON.parse(Buffer.from(c, 'base64url')).iss;
            row.signedBy = [['home', HOME], ['band', BAND], ['main', MAIN]]
                .filter(([, kp]) => crypto.createVerify('RSA-SHA256').update(`${h}.${c}`).verify(kp.publicKey, Buffer.from(s, 'base64url')))
                .map(([name]) => name);
        }
        seen.push(row);
        if (/\/installation$/.test(u.pathname)) return res(200, { id: u.pathname.includes('/Contoso/') ? 111 : u.pathname.includes('/MainEvent') ? 222 : 333 });
        if (/\/access_tokens$/.test(u.pathname)) return res(201, { token: `ghs_tok${++n}`, expires_at: new Date(T0 + 3600e3).toISOString() });
        return res(200, { workflow_runs: [] }, { etag: '"e1"' });
    };
    const client = createGithubClient({ config, fetch: fetchStub, now: () => T0 });
    return { client, seen };
}

const MULTI = () => ({
    GITHUB_APP_CLIENT_ID: 'Iv-home', GITHUB_APP_PRIVATE_KEY: HOME.privateKey,
    GITHUB_APP_OWNERS: 'Contoso,MainEventEntertainment',
    GITHUB_APP_CONTOSO_CLIENT_ID: 'Iv-band', GITHUB_APP_CONTOSO_PRIVATE_KEY: BAND.privateKey,
    GITHUB_APP_MAINEVENTENTERTAINMENT_APP_ID: '9090', GITHUB_APP_MAINEVENTENTERTAINMENT_PRIVATE_KEY: MAIN.privateKey,
});

describe('credential selection by repo owner (002)', () => {
    test('each owner is signed with ITS OWN key and issuer; no JWT is ever signed by another owner key', async () => {
        const h = githubHarness(MULTI());
        await h.client.getToken({ owner: 'Contoso', repo: 'Contoso-Android', purpose: 'watcher' });
        await h.client.getToken({ owner: 'MainEventEntertainment', repo: 'app', purpose: 'watcher' });
        await h.client.getToken({ owner: 'DoubleNode', repo: 'dev-team', purpose: 'watcher' });
        const jwts = h.seen.filter((r) => r.iss);
        assert.equal(jwts.length, 6);   // installation lookup + token mint, per owner
        const by = (path_) => jwts.filter((r) => r.path.includes(path_));
        assert.ok(by('/Contoso/').every((r) => r.iss === 'Iv-band' && r.signedBy.join() === 'band'));
        assert.ok(jwts.filter((r) => r.path.includes('/MainEventEntertainment/')).every((r) => r.iss === '9090' && r.signedBy.join() === 'main'));
        assert.ok(by('/DoubleNode/').every((r) => r.iss === 'Iv-home' && r.signedBy.join() === 'home'));
    });

    test('owner lookup is case-insensitive', async () => {
        const h = githubHarness(MULTI());
        await h.client.getToken({ owner: 'contoso', repo: 'x', purpose: 'watcher' });
        assert.deepEqual(h.seen.filter((r) => r.iss).map((r) => r.iss), ['Iv-band', 'Iv-band']);
    });

    test('unknown owner FAILS CLOSED with NO_CREDENTIAL: zero fetches, no other owner key used, no secret in the error', async () => {
        const h = githubHarness(MULTI());
        for (const call of [
            () => h.client.getToken({ owner: 'Stranger', repo: 'r', purpose: 'watcher' }),
            () => h.client.getInstallationId('Stranger', 'r'),
            () => h.client.conditionalGet({ owner: 'Stranger', repo: 'r', path: '/repos/Stranger/r/actions/runs' }),
            () => h.client.generateJitConfig({ owner: 'Stranger', repo: 'r', name: 'n', labels: ['a'] }),
            () => h.client.deleteRunner({ owner: 'Stranger', repo: 'r', runnerId: 5 }),
        ]) {
            await assert.rejects(call, (e) => e instanceof GithubError && e.code === 'NO_CREDENTIAL'
                && !/BEGIN|Iv-|9090|MIIE/.test(`${e.message}${e.stack}`));
        }
        assert.equal(h.seen.length, 0);
    });

    test('partial credential for an owner fails closed; the neighbouring complete owner still works', async () => {
        const cfg = Object.assign(MULTI(), { GITHUB_APP_CONTOSO_PRIVATE_KEY: '' });
        const h = githubHarness(cfg);
        await assert.rejects(() => h.client.getToken({ owner: 'Contoso', repo: 'r', purpose: 'watcher' }),
            (e) => e.code === 'NO_CREDENTIAL' && /incomplete/.test(e.message));
        assert.equal(h.seen.length, 0);
        await h.client.getToken({ owner: 'DoubleNode', repo: 'r', purpose: 'watcher' });
        assert.ok(h.seen.length > 0);
    });

    test('caches never cross owners: same repo name under two owners mints two installations and two ETag entries', async () => {
        const h = githubHarness(MULTI());
        const a = { repo: 'shared', purpose: 'watcher' };
        await h.client.conditionalGet(Object.assign({ owner: 'Contoso', path: '/repos/Contoso/shared/actions/runs' }, a));
        await h.client.conditionalGet(Object.assign({ owner: 'DoubleNode', path: '/repos/DoubleNode/shared/actions/runs' }, a));
        const lookups = h.seen.filter((r) => /\/installation$/.test(r.path));
        assert.deepEqual(lookups.map((r) => r.iss), ['Iv-band', 'Iv-home']);
        // a second Contoso call reuses ITS installation + token (cache hit), and sends no other owner's token
        const before = h.seen.length;
        await h.client.conditionalGet(Object.assign({ owner: 'Contoso', path: '/repos/Contoso/shared/actions/runs' }, a));
        assert.equal(h.seen.length, before + 1);
        const last = h.seen[h.seen.length - 1];
        const bandTok = h.seen.find((r) => r.path.includes('/repos/Contoso/shared/actions/runs')).bearer;
        assert.equal(last.bearer, bandTok);
    });

    test('BACKWARD COMPAT: legacy single-App settings alone still serve any owner with the one key', async () => {
        const h = githubHarness({ GITHUB_APP_CLIENT_ID: 'Iv-home', GITHUB_APP_PRIVATE_KEY: HOME.privateKey });
        await h.client.getToken({ owner: 'DoubleNode', repo: 'dev-team', purpose: 'admin' });
        await h.client.getToken({ owner: 'o', repo: 'r', purpose: 'watcher' });
        assert.ok(h.seen.filter((r) => r.iss).every((r) => r.iss === 'Iv-home' && r.signedBy.join() === 'home'));
    });

    test('legacy mode with nothing configured keeps its NOT_CONFIGURED code', async () => {
        const h = githubHarness({});
        await assert.rejects(() => h.client.getToken({ owner: 'o', repo: 'r', purpose: 'watcher' }), (e) => e.code === 'NOT_CONFIGURED');
    });

    test('a mint for an owner without a credential is audited as mint-failed:NO_CREDENTIAL and carries no secret (003)', async () => {
        const h = githubHarness(MULTI());
        const rows = [];
        const a = createAssignments({
            file: path.join(TMP, 'assign.json'), github: h.client, audit: { append: (e, f) => rows.push(Object.assign({ event: e }, f)) },
            now: () => T0, logger: { error() {}, warn() {} },
        });
        const r = await a.mint({
            job: { owner: 'Stranger', repo: 'r', jobId: 1, runId: 2, name: 'unit', labels: ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'] },
            machine: 'm1mini', labels: ['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'm1mini'], os: 'Linux',
        });
        assert.equal(r.ok, false);
        assert.equal(r.code, 'NO_CREDENTIAL');
        assert.ok(rows.some((x) => x.reason === 'mint-failed:NO_CREDENTIAL'));
        assert.equal(h.seen.length, 0);
        assert.equal(JSON.stringify(rows).includes('BEGIN'), false);
    });
});

// ------------------------------------------------------------------- store (004)

describe('machine.repos in the pool store (004)', () => {
    const mk = () => {
        const store = createPoolStore({ file: path.join(TMP, `p${Math.random().toString(36).slice(2)}.json`), logger: { error() {} } });
        store.load();
        return store;
    };

    test('repos is optional: a machine without it validates; null means unbound', () => {
        const store = mk();
        assert.equal(store.upsertMachine('m1pro', { enabled: true }).ok, true);
        assert.equal(store.getMachine('m1pro').repos, undefined);
        assert.equal(store.upsertMachine('m1pro', { repos: null }).ok, true);
    });

    test('accepts a non-empty owner/repo list and persists it', () => {
        const store = mk();
        assert.equal(store.upsertMachine('m1pro', { repos: ['MainEventEntertainment/app', 'MainEventEntertainment/lib'] }).ok, true);
        assert.deepEqual(store.getMachine('m1pro').repos, ['MainEventEntertainment/app', 'MainEventEntertainment/lib']);
    });

    for (const [name, bad] of [
        ['empty array', []], ['a string', 'a/b'], ['a number', 5], ['bare repo name', ['app']], ['non-string entry', [5]],
        ['URL form', ['https://github.com/a/b']], ['path traversal', ['a/..']], ['case-insensitive duplicate', ['A/b', 'a/B']],
        ['too many', Array.from({ length: 51 }, (_, i) => `o/r${i}`)], ['object', {}],
    ]) {
        test(`rejects ${name} and keeps the previous value`, () => {
            const store = mk();
            store.upsertMachine('m1pro', { repos: ['o/keep'] });
            const r = store.upsertMachine('m1pro', { repos: bad });
            assert.equal(r.ok, false);
            assert.deepEqual(store.getMachine('m1pro').repos, ['o/keep']);
        });
    }

    test('validateMachine flags a malformed stored binding', () => {
        const store = mk();
        store.upsertMachine('m1pro', { enabled: true });
        const rec = JSON.parse(JSON.stringify(store.getMachine('m1pro')));
        rec.repos = 'oops';
        assert.ok(validateMachine(rec, 'm1pro').some((e) => /repos/.test(e)));
    });
});

// -------------------------------------------------------------- placement (004)

const POOL = ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'];
const cap = () => ({
    memTotalBytes: 17179869184, memReclaimableBytes: 4080000000, memFreePct: 45, swapUsedBytes: 100,
    swapTotalBytes: 3221225472, load1: 1.2, load5: 1, load15: 1, ncpu: 10, teamSessions: 6, vmState: 'running',
});
const report = () => ({ receivedAt: T0, capacity: cap(), slots: [{ os: 'Linux', index: 1, state: 'idle', assignmentId: null }] });
const job = (owner, repo) => ({ owner, repo, name: 'unit', labels: POOL.slice() });
const machine = (extra) => Object.assign({ enabled: true, paused: false, prefers: null, thresholds: {} }, extra);
const cfg = { now: T0 };
const verdict = (machines, j) => Object.fromEntries(plc.evaluateMachines(machines, { m1mini: report(), m1pro: report(), m4mini: report() }, j, cfg).map((r) => [r.id, r]));

describe('placement binding rules (004)', () => {
    const ME = 'MainEventEntertainment/app';
    const fleet = () => ({
        m1mini: machine(),                         // unbound
        m4mini: machine(),                         // unbound
        m1pro: machine({ repos: [ME] }),           // bound to a Main Event repo
    });

    test('matrix: unbound machines serve unbound repos; the bound repo places ONLY on its bound machine', () => {
        const dn = verdict(fleet(), job('DoubleNode', 'dev-team'));
        assert.equal(dn.m1mini.eligible, true);
        assert.equal(dn.m4mini.eligible, true);
        assert.equal(dn.m1pro.eligible, false);
        assert.deepEqual(dn.m1pro.reasons, ['repo-not-bound']);

        const me = verdict(fleet(), job('MainEventEntertainment', 'app'));
        assert.equal(me.m1pro.eligible, true);
        assert.equal(me.m1mini.eligible, false);
        assert.deepEqual(me.m1mini.reasons, ['repo-reserved']);
        assert.equal(me.m4mini.eligible, false);
    });

    test('binding comparison is case-insensitive', () => {
        const me = verdict(fleet(), job('mainevententertainment', 'APP'));
        assert.equal(me.m1pro.eligible, true);
        assert.equal(me.m1mini.eligible, false);
    });

    test('NO binding anywhere: today behaviour, an unbound machine serves any (allowlisted) repo, e.g. Contoso on m1mini', () => {
        const machines = { m1mini: machine(), m4mini: machine() };
        const v = verdict(machines, job('Contoso', 'Contoso-Android'));
        assert.equal(v.m1mini.eligible, true);
        assert.equal(v.m4mini.eligible, true);
    });

    test('an unbound repo never lands on a bound machine, even when it is the only machine with capacity', () => {
        const machines = { m1pro: machine({ repos: [ME] }) };
        const v = verdict(machines, job('Contoso', 'Contoso-Android'));
        assert.equal(v.m1pro.eligible, false);
        assert.equal(plc.rankCandidates(machines, { m1pro: report() }, job('Contoso', 'Contoso-Android'), cfg).length, 0);
    });

    test('a bound repo with no bound machine ready has no fallback to unbound machines (no placement at all)', () => {
        const machines = fleet();
        machines.m1pro.paused = true;
        const ranked = plc.rankCandidates(machines, { m1mini: report(), m1pro: report(), m4mini: report() }, job('MainEventEntertainment', 'app'), cfg);
        assert.deepEqual(ranked, []);
    });

    test('malformed binding makes the machine ineligible for EVERYTHING and reserves nothing', () => {
        for (const bad of ['oops', [], [5], ['not-a-slug'], {}]) {
            const machines = { m1mini: machine(), m1pro: machine({ repos: bad }) };
            for (const j of [job('DoubleNode', 'dev-team'), job('MainEventEntertainment', 'app')]) {
                const v = verdict(machines, j);
                assert.equal(v.m1pro.eligible, false);
                assert.deepEqual(v.m1pro.reasons, ['binding-malformed']);
                assert.equal(v.m1mini.eligible, true, 'a malformed binding must not reserve repos away from healthy machines');
            }
        }
    });

    test('a job with no repo identity is refused by a bound machine (fail closed) but served by an unbound one', () => {
        const v = verdict(fleet(), { name: 'unit', labels: POOL.slice() });
        assert.equal(v.m1pro.eligible, false);
        assert.equal(v.m1mini.eligible, true);
    });

    test('a repo bound on two machines places on either', () => {
        const machines = { m1pro: machine({ repos: [ME] }), m1mini: machine({ repos: [ME, 'o/other'] }), m4mini: machine() };
        const v = verdict(machines, job('MainEventEntertainment', 'app'));
        assert.equal(v.m1pro.eligible, true);
        assert.equal(v.m1mini.eligible, true);
        assert.equal(v.m4mini.eligible, false);
    });

    test('paired mutation: with the binding removed the same fleet WOULD cross the ownership line', () => {
        const stripped = fleet();
        delete stripped.m1pro.repos;
        const v = verdict(stripped, job('DoubleNode', 'dev-team'));
        assert.equal(v.m1pro.eligible, true, 'without the binding m1pro takes DoubleNode work: the rule above is what prevents it');
    });

    test('host-label pinned DoubleNode job still cannot reach the bound machine', () => {
        const v = verdict(fleet(), Object.assign(job('DoubleNode', 'dev-team'), { labels: [...POOL, 'm1pro'] }));
        assert.equal(v.m1pro.eligible, false);
        assert.ok(v.m1pro.reasons.includes('repo-not-bound'));
    });
});

// ------------------------------------------------------------- routes (005)

function routeSetup() {
    const dir = fs.mkdtempSync(path.join(TMP, 'r-'));
    const store = createPoolStore({ file: path.join(dir, 'ci-pool.json'), logger: { error() {} } });
    store.load();
    store.upsertMachine('m1pro', { enabled: true });
    store.upsertMachine('m1mini', { enabled: true });
    const auditFile = path.join(dir, 'audit.jsonl');
    const audit = createAudit({ path: auditFile, keep: 2, now: () => new Date(T0) });
    const assignments = createAssignments({
        file: path.join(dir, 's.json'), github: { async generateJitConfig() { throw new Error('no'); }, async deleteRunner() { throw new Error('no'); } },
        audit, now: () => T0, logger: { error() {}, warn() {} },
    });
    const app = express();
    app.use(express.json());
    registerCiPoolRoutes(app, { store, assignments, dispatcher: { isEnabled: () => true, alerts: () => [], queue: () => [] }, audit, now: () => T0, logger: { error() {} } });
    const rows = () => (fs.existsSync(auditFile) ? fs.readFileSync(auditFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
    return { app, store, rows };
}
const put = (s, id, body) => request(s.app).put(`/api/ci-pool/machines/${id}`).set('Authorization', `Bearer ${ADMIN}`).send(body);

describe('PUT/GET repos (005)', () => {
    test('PUT accepts repos, echoes it, GET shows binding + bindingState, and the change is audited', async () => {
        const s = routeSetup();
        const r = await put(s, 'm1pro', { repos: ['MainEventEntertainment/app'] });
        assert.equal(r.status, 200);
        assert.deepEqual(r.body.record.repos, ['MainEventEntertainment/app']);
        const g = await request(s.app).get('/api/ci-pool');
        assert.deepEqual(g.body.machines.m1pro.repos, ['MainEventEntertainment/app']);
        assert.equal(g.body.machines.m1pro.bindingState, 'bound');
        assert.equal(g.body.machines.m1mini.repos, null);
        assert.equal(g.body.machines.m1mini.bindingState, 'unbound');
        const b = s.rows().filter((x) => x.event === 'binding');
        assert.equal(b.length, 1);
        assert.equal(b[0].machine, 'm1pro');
        assert.equal(b[0].reason, 'bound:MainEventEntertainment/app');
    });

    test('PUT null unbinds (audited); an identical repeat writes no second audit row', async () => {
        const s = routeSetup();
        await put(s, 'm1pro', { repos: ['o/r'] });
        await put(s, 'm1pro', { repos: ['o/r'] });
        assert.equal(s.rows().filter((x) => x.event === 'binding').length, 1);
        const r = await put(s, 'm1pro', { repos: null });
        assert.equal(r.status, 200);
        assert.equal(r.body.record.repos, null);
        assert.deepEqual(s.rows().filter((x) => x.event === 'binding').map((x) => x.reason), ['bound:o/r', 'unbound']);
    });

    test('malformed repos is 400 and the previous binding survives', async () => {
        const s = routeSetup();
        await put(s, 'm1pro', { repos: ['o/r'] });
        for (const bad of [[], 'o/r', ['bare'], ['o/r', 'O/R'], [1], {}]) {
            const r = await put(s, 'm1pro', { repos: bad });
            assert.equal(r.status, 400, JSON.stringify(bad));
        }
        assert.deepEqual(s.store.getMachine('m1pro').repos, ['o/r']);
        assert.equal(s.rows().filter((x) => x.event === 'binding').length, 1);
    });

    test('repos needs the admin key', async () => {
        const s = routeSetup();
        const r = await request(s.app).put('/api/ci-pool/machines/m1pro').send({ repos: ['o/r'] });
        assert.equal(r.status, 401);
        assert.equal(s.store.getMachine('m1pro').repos, undefined);
    });
});

// ----------------------------------------------- dispatcher audit of refusals (005)

describe('dispatcher audits binding refusals', () => {
    test('a DoubleNode job refused by the bound machine is audited once per (job, machine), and still places on the unbound one', async () => {
        const dir = fs.mkdtempSync(path.join(TMP, 'd-'));
        const clock = { t: T0 };
        const store = createPoolStore({ file: path.join(dir, 'ci-pool.json'), logger: { error() {} } });
        store.load();
        store.updateConfig({ allowlist: ['DoubleNode/dev-team'] });
        store.upsertMachine('m1mini', { enabled: true });
        store.upsertMachine('m1pro', { enabled: true, repos: ['MainEventEntertainment/app'] });
        const reports = new Map([['m1mini', { receivedAt: clock.t, capacity: cap(), slots: report().slots }], ['m1pro', { receivedAt: clock.t, capacity: cap(), slots: report().slots }]]);
        const minted = [];
        const gh = {
            async generateJitConfig(a) { minted.push(a); return { runnerId: 9000 + minted.length, encodedJitConfig: 'JIT' }; },
            async deleteRunner() { return { deleted: true }; },
        };
        const rows = [];
        const audit = { append: (event, fields) => rows.push(Object.assign({ event }, fields)) };
        const assignments = createAssignments({ file: path.join(dir, 's.json'), github: gh, audit, now: () => clock.t, logger: { error() {}, warn() {} } });
        const logger = { log() {}, warn() {}, error() {} };
        const d = createDispatcher({
            env: { FLEET_CI_DISPATCHER: '1', GITHUB_APP_CLIENT_ID: 'i', GITHUB_APP_PRIVATE_KEY: 'k' },
            store, assignments, alerts: createAlerts({ now: () => clock.t, logger, getEmitter: () => null }), audit,
            watcher: { async runCycle() { return 15000; }, stop() {} }, reports, logger, now: () => clock.t,
            setTimer: () => ({}), clearTimer: () => {},
        });
        d.onJob({
            key: 'DoubleNode/dev-team#1#1', owner: 'DoubleNode', repo: 'dev-team', runId: 5, runAttempt: 1, jobId: 1,
            name: 'unit', labels: POOL.slice(), status: 'queued', conclusion: null, runnerName: null,
            createdAt: new Date(T0).toISOString(), firstSeenAt: new Date(T0).toISOString(), inProgressAt: null, completedAt: null,
            run: { event: 'push', repoFullName: 'DoubleNode/dev-team', headRepoFullName: 'DoubleNode/dev-team' },
        }, 'queued');
        await d.tick();
        clock.t += 1000; for (const r of reports.values()) r.receivedAt = clock.t;
        await d.tick();
        const refusals = rows.filter((x) => x.event === 'binding');
        assert.equal(refusals.length, 1, JSON.stringify(refusals));
        assert.equal(refusals[0].machine, 'm1pro');
        assert.equal(refusals[0].reason, 'repo-not-bound');
        assert.equal(refusals[0].repo, 'DoubleNode/dev-team');
        assert.ok(minted.length >= 1, 'placed on the unbound machine');
        const assigned = rows.filter((x) => x.event === 'assign' && x.machine);
        assert.ok(assigned.every((x) => x.machine === 'm1mini'));
    });
});

describe('XACA-1459-016: fallback reader names a missing credential instead of "unreachable"', () => {
    const { describeError } = require('../lib/ci-fallback-reader');
    test('NO_CREDENTIAL maps to a fixed, owner-named string; never err.message, never UNREACHABLE', () => {
        const secretish = new GithubError('NO_CREDENTIAL', 'SECRET-SHOULD-NOT-LEAK');
        const msg = describeError(secretish, 'Contoso');
        assert.equal(msg, 'No GitHub App credential configured for Contoso');
        assert.ok(!msg.includes('SECRET-SHOULD-NOT-LEAK'));
        assert.notEqual(msg, describeError(new Error('socket hang up'), 'Contoso'));   // not the unreachable string
        assert.equal(describeError(secretish), 'No GitHub App credential configured for this owner');
    });
});

describe('mint failure is owner-scoped (PR #1254 test round 4)', () => {
    test("one owner's NO_CREDENTIAL stops only that owner this tick; another owner's same-set job still mints", async () => {
        const dir = fs.mkdtempSync(path.join(TMP, 'mf-'));
        const clock = { t: T0 };
        const store = createPoolStore({ file: path.join(dir, 'ci-pool.json'), logger: { error() {} } });
        store.load();
        store.updateConfig({ allowlist: ['Acme/a', 'Contoso/b'] });
        store.upsertMachine('m1mini', { enabled: true });
        store.upsertMachine('m4mini', { enabled: true });
        const reports = new Map([['m1mini', { receivedAt: clock.t, capacity: cap(), slots: report().slots }], ['m4mini', { receivedAt: clock.t, capacity: cap(), slots: report().slots }]]);
        const attempts = [];
        const gh = {
            async generateJitConfig(a) {
                attempts.push(a.owner);
                if (a.owner === 'Acme') throw new GithubError('NO_CREDENTIAL', 'no credential');
                return { runnerId: 9100 + attempts.length, encodedJitConfig: 'JIT' };
            },
            async deleteRunner() { return { deleted: true }; },
        };
        const rows = [];
        const audit = { append: (event, fields) => rows.push(Object.assign({ event }, fields)) };
        const assignments = createAssignments({ file: path.join(dir, 's.json'), github: gh, audit, now: () => clock.t, logger: { error() {}, warn() {} } });
        const logger = { log() {}, warn() {}, error() {} };
        const d = createDispatcher({
            env: { FLEET_CI_DISPATCHER: '1', GITHUB_APP_CLIENT_ID: 'i', GITHUB_APP_PRIVATE_KEY: 'k' },
            store, assignments, alerts: createAlerts({ now: () => clock.t, logger, getEmitter: () => null }), audit,
            watcher: { async runCycle() { return 15000; }, stop() {} }, reports, logger, now: () => clock.t,
            setTimer: () => ({}), clearTimer: () => {},
        });
        const job = (owner, repo, id, ageMs) => ({
            key: `${owner}/${repo}#${id}#1`, owner, repo, runId: 50 + id, runAttempt: 1, jobId: id,
            name: 'unit', labels: POOL.slice(), status: 'queued', conclusion: null, runnerName: null,
            createdAt: new Date(T0 - ageMs).toISOString(), firstSeenAt: new Date(T0 - ageMs).toISOString(), inProgressAt: null, completedAt: null,
            run: { event: 'push', repoFullName: `${owner}/${repo}`, headRepoFullName: `${owner}/${repo}` },
        });
        // FIFO: both Acme jobs are older than the Contoso job, so the failing owner is tried first.
        d.onJob(job('Acme', 'a', 1, 3000), 'queued');
        d.onJob(job('Acme', 'a', 2, 2000), 'queued');
        d.onJob(job('Contoso', 'b', 3, 1000), 'queued');
        await d.tick();
        assert.equal(attempts.filter((o) => o === 'Acme').length, 1, `failing owner retried within the tick: ${attempts.join(',')}`);
        assert.equal(attempts.filter((o) => o === 'Contoso').length, 1, `other owner starved by the failing owner: ${attempts.join(',')}`);
        const ok = rows.filter((x) => x.event === 'assign' && x.repo === 'Contoso/b' && x.state !== 'mint-failed');
        assert.ok(ok.length >= 1, 'Contoso job minted in the same tick');
    });
});
