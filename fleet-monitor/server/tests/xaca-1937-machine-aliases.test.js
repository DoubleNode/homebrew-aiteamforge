//
//  xaca-1937-machine-aliases.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1937: CI pool machines renamed m1mini -> romulus, m4mini -> vulcan, with a dual-name window
 * (closes under XACA-1936). Real pool store / assignments / placement / policy / dispatcher / routes over
 * temp dirs; fake GitHub, fake clock. No network, no real data dir, no server process.
 *
 * The pre-existing m1mini/m4mini tests are deliberately unchanged: they now prove the old names still work.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const request = require('./helpers/loopback-request');

const FLEET = 'xaca1937-fake-fleet-token-aaaaaaaa';
const ADMIN = 'xaca1937-fake-admin-token-bbbbbbbb';
const SAVED = { a: process.env.FLEET_AUTH_TOKEN, b: process.env.FLEET_ADMIN_TOKEN, c: process.env.FLEET_CI_DISPATCHER };
process.env.FLEET_AUTH_TOKEN = FLEET;
process.env.FLEET_ADMIN_TOKEN = ADMIN;
delete process.env.FLEET_CI_DISPATCHER;

const A = require('../lib/ci-machine-aliases');
const S = require('../lib/ci-pool-store');
const plc = require('../lib/ci-dispatch-placement');
const pol = require('../lib/ci-dispatch-policy');
const { createAssignments } = require('../lib/ci-dispatch-assignments');
const { createAlerts } = require('../lib/ci-dispatch-alerts');
const { createDispatcher } = require('../lib/ci-dispatcher');
const { registerCiPoolRoutes } = require('../lib/ci-pool-routes');
const { registerCiRunnersRoutes } = require('../lib/ci-runners-routes');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1937-'));
after(() => {
    fs.rmSync(TMP, { recursive: true, force: true });
    for (const [k, v] of [['FLEET_AUTH_TOKEN', SAVED.a], ['FLEET_ADMIN_TOKEN', SAVED.b], ['FLEET_CI_DISPATCHER', SAVED.c]]) {
        if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
});

let seq = 0;
const newDir = () => { const d = path.join(TMP, `s${++seq}`); fs.mkdirSync(d, { recursive: true }); return d; };
const quiet = { error() {}, log() {}, warn() {} };
const HASH_A = 'a'.repeat(64);
const HASH_B = 'b'.repeat(64);
const HASH_C = 'c'.repeat(64);

/** A full machine record as an old (pre-rename) ci-pool.json holds it. */
const oldRecord = (over = {}) => Object.assign({
    enabled: true, paused: true, pausedBy: 'operator', pausedAt: '2026-11-20T10:00:00.000Z', pauseReason: 'maintenance',
    prefers: 'short', thresholds: { memFreePct: 20 }, keyHash: HASH_A, telemetryKeyHash: HASH_B,
    mode: 'live', repos: ['DoubleNode/dev-team'],
}, over);
function writePool(file, machines) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify({ schemaVersion: 1, config: S.defaultConfig(), machines }));
}

// ---------------------------------------------------------------------------
describe('alias table', () => {
    test('maps the two renamed machines, frozen, case-insensitive; unknown ids pass through unchanged', () => {
        assert.deepEqual(A.MACHINE_ALIASES, { m1mini: 'romulus', m4mini: 'vulcan' });
        assert.equal(Object.isFrozen(A.MACHINE_ALIASES), true);
        assert.equal(A.canonicalMachine('m1mini'), 'romulus');
        assert.equal(A.canonicalMachine('M4Mini'), 'vulcan');
        assert.equal(A.canonicalMachine('romulus'), 'romulus');
        assert.equal(A.canonicalMachine('m9mini'), 'm9mini');
        assert.equal(A.canonicalMachine('Studio-1'), 'Studio-1', 'unknown ids are not even lowercased');
        assert.equal(A.canonicalMachine('m1mini '), 'm1mini ', 'no trimming: a padded name is not the machine');
        assert.deepEqual(A.aliasesOf('romulus'), ['m1mini']);
        assert.deepEqual(A.aliasesOf('Vulcan'), ['m4mini']);
        assert.deepEqual(A.aliasesOf('m1mini'), []);
        assert.deepEqual(A.aliasesOf('m9mini'), []);
    });
    test('hostLabelsOf: primary first, then the other names, lowercased; unaliased machines are untouched', () => {
        assert.deepEqual(A.hostLabelsOf({ id: 'romulus' }), ['romulus', 'm1mini']);
        assert.deepEqual(A.hostLabelsOf({ id: 'M1Mini' }), ['m1mini', 'romulus']);
        assert.deepEqual(A.hostLabelsOf({ id: 'vulcan' }), ['vulcan', 'm4mini']);
        assert.deepEqual(A.hostLabelsOf({ id: 'm9mini' }), ['m9mini']);
        assert.deepEqual(A.hostLabelsOf(null), []);
        assert.equal(plc.hostLabelOf({ id: 'Romulus' }), 'romulus', 'the single-label API is unchanged');
    });
    test('sameMachine: old and new names match; different machines and unaliased case variants do not', () => {
        assert.equal(A.sameMachine('m1mini', 'romulus'), true);
        assert.equal(A.sameMachine('romulus', 'm1mini'), true);
        assert.equal(A.sameMachine('romulus', 'M1MINI'), false, 'identity stays exact-case (the telemetry check always was)');
        assert.equal(A.sameMachine('m1mini', 'vulcan'), false);
        assert.equal(A.sameMachine('m1mini', 'm4mini'), false);
        assert.equal(A.sameMachine('Studio', 'studio'), false, 'unaliased ids keep exact comparison');
        assert.equal(A.sameMachine('m1mini ', 'romulus'), false);
        assert.equal(A.sameMachine(undefined, 'romulus'), false);
    });
});

// ---------------------------------------------------------------------------
describe('pool store migration', () => {
    test('an old-name record is renamed on load with EVERY field carried, persisted, and idempotent', () => {
        const file = path.join(newDir(), 'ci-pool.json');
        writePool(file, { m1mini: oldRecord(), m4mini: oldRecord({ keyHash: HASH_C, telemetryKeyHash: null, repos: null, mode: 'shadow' }), studio: S.defaultMachine() });
        const store = S.createPoolStore({ file, logger: quiet });
        assert.deepEqual(store.load(), { ok: true });
        assert.deepEqual(Object.keys(store.listMachines()).sort(), ['romulus', 'studio', 'vulcan']);
        assert.deepEqual(store.getMachine('romulus'), oldRecord());
        assert.deepEqual(store.getMachine('vulcan'), oldRecord({ keyHash: HASH_C, telemetryKeyHash: null, repos: null, mode: 'shadow' }));
        assert.deepEqual(store.lastMigration().renamed, [{ from: 'm1mini', to: 'romulus' }, { from: 'm4mini', to: 'vulcan' }]);
        // Persisted: the file on disk now holds only the new names.
        const disk = JSON.parse(fs.readFileSync(file, 'utf8'));
        assert.deepEqual(Object.keys(disk.machines).sort(), ['romulus', 'studio', 'vulcan']);
        // Idempotent: a second load renames nothing and changes nothing.
        const before = fs.readFileSync(file, 'utf8');
        const again = S.createPoolStore({ file, logger: quiet });
        assert.deepEqual(again.load(), { ok: true });
        assert.deepEqual(again.lastMigration().renamed, []);
        assert.equal(fs.readFileSync(file, 'utf8'), before);
    });

    test('lookups and admin writes by the OLD id resolve to the renamed record (no second record is created)', () => {
        const file = path.join(newDir(), 'ci-pool.json');
        writePool(file, { m1mini: oldRecord() });
        const store = S.createPoolStore({ file, logger: quiet });
        store.load();
        assert.equal(store.resolveId('m1mini'), 'romulus');
        assert.deepEqual(store.getMachine('m1mini'), store.getMachine('romulus'));
        assert.equal(store.upsertMachine('m1mini', { paused: false }).ok, true);
        assert.deepEqual(Object.keys(store.listMachines()), ['romulus']);
        assert.equal(store.getMachine('romulus').paused, false);
        assert.equal(store.setHostSecret('m1mini', 'fresh-secret').ok, true);
        assert.equal(store.verifyHostSecret('romulus', 'fresh-secret'), true);
        assert.equal(store.getMachine('m9mini'), null, 'unknown names resolve to nothing');
    });

    test('an agent key issued under m1mini still authenticates, now as romulus', async () => {
        const dir = newDir();
        const poolFile = path.join(dir, 'ci-pool.json');
        // Issue a real fcp_ key under the OLD name through the real mint route, as before the deploy.
        const pre = world(dir, { load: false });
        pre.pool.load();
        assert.equal((await admin(request(pre.app).put('/api/ci-pool/machines/m1mini')).send({ enabled: true })).status, 200);
        const key = (await admin(request(pre.app).post('/api/ci-pool/machines/m1mini/key'))).body.key;
        assert.match(key, /^fcp_/);
        assert.deepEqual(Object.keys(JSON.parse(fs.readFileSync(poolFile, 'utf8')).machines), ['m1mini']);
        // "Deploy": a fresh process loads the same file.
        const post = world(dir);
        assert.deepEqual(Object.keys(post.pool.listMachines()), ['romulus']);
        const r = await bearer(request(post.app).post('/api/ci-pool/agent/poll'), key).send({ schemaVersion: 1, agentVersion: '1.0.0', capacity: { memTotalBytes: 17179869184, memReclaimableBytes: 4080000000, memFreePct: 45, swapUsedBytes: 100, swapTotalBytes: 3221225472, load1: 1.2, load5: 1, load15: 1, ncpu: 10, teamSessions: 6, vmState: 'running' }, slots: [{ os: 'Linux', index: 1, state: 'idle', assignmentId: null }] });
        assert.equal(r.status, 200, JSON.stringify(r.body));
        assert.equal(post.pool.verifyHostSecret('romulus', key), true);
    });

    test('both old and new records present: the new one is kept, the old one is NOT merged, logged and saved aside', () => {
        const file = path.join(newDir(), 'ci-pool.json');
        // Old key FIRST in the file, so key order cannot be what decides the winner.
        writePool(file, { m1mini: oldRecord({ keyHash: HASH_A }), romulus: oldRecord({ keyHash: HASH_C, enabled: false, prefers: 'long' }) });
        const errors = [];
        const store = S.createPoolStore({ file, logger: { error: (m) => errors.push(m), log() {} } });
        assert.deepEqual(store.load(), { ok: true });
        assert.deepEqual(Object.keys(store.listMachines()), ['romulus']);
        const kept = store.getMachine('romulus');
        assert.equal(kept.keyHash, HASH_C, 'the new record is kept as-is');
        assert.equal(kept.enabled, false);
        assert.equal(kept.prefers, 'long', 'no field of the old record leaked in');
        const mig = store.lastMigration();
        assert.deepEqual(mig.conflicts, [{ from: 'm1mini', to: 'romulus' }]);
        assert.equal(errors.length, 1);
        assert.match(errors[0], /both 'm1mini' and 'romulus'.*kept 'romulus'.*WITHOUT merging/);
        const aside = JSON.parse(fs.readFileSync(mig.conflictsFile, 'utf8'));
        assert.equal(aside.conflicts[0].from, 'm1mini');
        assert.equal(aside.conflicts[0].record.keyHash, HASH_A, 'the dropped record is recoverable from the side file');
    });

    test('side file cannot be written: the pool file is NOT rewritten, so the old record is not lost (PR #1400 review)', () => {
        const file = path.join(newDir(), 'ci-pool.json');
        writePool(file, { m1mini: oldRecord({ keyHash: HASH_A }), romulus: oldRecord({ keyHash: HASH_C }) });
        const before = fs.readFileSync(file, 'utf8');
        const errors = [];
        const store = S.createPoolStore({ file, logger: { error: (m) => errors.push(m), log() {} } });
        const realWrite = fs.writeFileSync;
        fs.writeFileSync = function (p, ...rest) {
            if (String(p).includes('.alias-conflict-')) throw Object.assign(new Error('EACCES: simulated'), { code: 'EACCES' });
            return realWrite.call(this, p, ...rest);
        };
        try { assert.deepEqual(store.load(), { ok: true }); } finally { fs.writeFileSync = realWrite; }
        assert.equal(fs.readFileSync(file, 'utf8'), before, 'ci-pool.json still holds both records on disk');
        assert.equal(store.lastMigration().conflictsFile, null);
        assert.ok(errors.some((m) => /alias migration NOT persisted/.test(m)), errors.join('\n'));
        assert.deepEqual(Object.keys(store.listMachines()).sort(), ['m1mini', 'romulus'], 'the old record is kept in memory too');
        assert.equal(store.listMachines().m1mini.keyHash, HASH_A);
    });

    // PR #1400 round 2 (review + test gates): after a failed side file, NO later write may persist the
    // pool without the old record. Every writer the store exposes, each on a fresh store.
    const WRITERS = {
        updateConfig: (s) => s.updateConfig({ poolLabel: 'fleet-pool' }),
        upsertMachine: (s) => s.upsertMachine('romulus', { enabled: true }),
        setHostSecret: (s) => s.setHostSecret('romulus', 'host-secret-xaca1937'),
        clearHostSecret: (s) => s.clearHostSecret('romulus'),
        setTelemetrySecret: (s) => s.setTelemetrySecret('romulus', 'telemetry-secret-xaca1937'),
        clearTelemetrySecret: (s) => s.clearTelemetrySecret('romulus'),
        setFallbackSwitches: (s) => s.setFallbackSwitches([]),
    };
    for (const [name, write] of Object.entries(WRITERS)) {
        test(`side file failed, then ${name}(): the saved pool still holds the old record`, () => {
            const file = path.join(newDir(), 'ci-pool.json');
            writePool(file, { m1mini: oldRecord({ keyHash: HASH_A }), romulus: oldRecord({ keyHash: HASH_C }) });
            const store = S.createPoolStore({ file, logger: { error() {}, log() {} } });
            const realWrite = fs.writeFileSync;
            fs.writeFileSync = function (p, ...rest) {
                if (String(p).includes('.alias-conflict-')) throw Object.assign(new Error('EACCES: simulated'), { code: 'EACCES' });
                return realWrite.call(this, p, ...rest);
            };
            try { store.load(); } finally { fs.writeFileSync = realWrite; }
            const r = write(store);
            assert.equal(r && r.ok, true, `${name} failed: ${JSON.stringify(r)}`);
            const disk = JSON.parse(fs.readFileSync(file, 'utf8')).machines;
            assert.deepEqual(Object.keys(disk).sort(), ['m1mini', 'romulus'], `${name} saved a pool without m1mini`);
            assert.equal(disk.m1mini.keyHash, HASH_A, `${name} changed the old record`);
        });
    }

    test('a case variant (M1Mini) is not an alias: never renamed, so it cannot be dropped as a conflict later (PR #1400 test)', () => {
        const p = { schemaVersion: 1, config: S.defaultConfig(), machines: { M1Mini: oldRecord({ keyHash: HASH_A }), romulus: oldRecord({ keyHash: HASH_C }) } };
        assert.deepEqual(S.migrateAliases(p), { renamed: [], conflicts: [] });
        assert.deepEqual(Object.keys(p.machines).sort(), ['M1Mini', 'romulus']);
        assert.equal(p.machines.M1Mini.keyHash, HASH_A);
    });

    test('migrateAliases is a no-op on a pool with no old names (unknown names unaffected)', () => {
        const p = { schemaVersion: 1, config: S.defaultConfig(), machines: { studio: S.defaultMachine(), m9mini: S.defaultMachine() } };
        assert.deepEqual(S.migrateAliases(p), { renamed: [], conflicts: [] });
        assert.deepEqual(Object.keys(p.machines), ['studio', 'm9mini']);
    });
});

// ---------------------------------------------------------------------------
describe('placement / policy / mint labels', () => {
    const NOW = 1700000000000;
    const GB = 1024 ** 3;
    const rep = () => ({ receivedAt: NOW, capacity: { memReclaimableBytes: 8 * GB, swapUsedBytes: 0, memFreePct: 50, load1: 0.1, ncpu: 8, vmState: 'running' }, slots: [{ os: 'Linux', state: 'idle' }] });
    const machines = { romulus: { enabled: true, paused: false }, vulcan: { enabled: true, paused: false } };
    const reports = { romulus: rep(), vulcan: rep() };
    const rank = (labels) => plc.rankCandidates(machines, reports, { name: 'b', labels }, { now: NOW }).map((r) => r.id);
    const mint = (labels, id) => plc.mintLabels({ labels }, Object.assign({ id }, machines[id]), { poolLabel: 'fleet-pool' });

    test('a job on the OLD host label places on the renamed machine and its runner carries that old label', () => {
        assert.deepEqual(rank(['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'm1mini']), ['romulus']);
        assert.deepEqual(mint(['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'm1mini'], 'romulus'), ['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'm1mini']);
    });
    test('a job on the NEW host label gets the new label; a pool-only job gets the primary new name', () => {
        assert.deepEqual(mint(['self-hosted', 'Linux', 'ARM64', 'romulus'], 'romulus'), ['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'romulus']);
        assert.deepEqual(mint(['self-hosted', 'Linux', 'ARM64', 'fleet-pool'], 'romulus'), ['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'romulus']);
        assert.deepEqual(mint(['self-hosted', 'Linux', 'ARM64', 'm1mini', 'romulus'], 'romulus'), ['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'romulus', 'm1mini']);
    });
    test('an old label of ANOTHER machine still never mints here (no cross-host pickup)', () => {
        assert.equal(mint(['self-hosted', 'Linux', 'ARM64', 'm4mini'], 'romulus'), null);
        assert.deepEqual(rank(['self-hosted', 'Linux', 'ARM64', 'm4mini']), ['vulcan']);
    });
    test('policy: old and new names of ONE machine are one host; two machines are still ambiguous; unknown labels still rejected', () => {
        const hostLabels = Object.keys(machines).flatMap((id) => plc.hostLabelsOf({ id }));
        const ctx = { allowlist: ['DoubleNode/dev-team'], poolLabel: 'fleet-pool', hostLabels };
        const job = (labels) => ({ owner: 'DoubleNode', repo: 'dev-team', labels, run: { event: 'push', repoFullName: 'DoubleNode/dev-team', headRepoFullName: 'DoubleNode/dev-team' } });
        const v = pol.evaluateJob(job(['self-hosted', 'Linux', 'ARM64', 'm1mini']), ctx);
        assert.equal(v.accept, true);
        assert.equal(v.viaHostLabel, true, 'a static old-label job is accepted on its host label');
        assert.equal(pol.evaluateJob(job(['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'm1mini', 'romulus']), ctx).accept, true);
        assert.equal(pol.evaluateJob(job(['self-hosted', 'Linux', 'ARM64', 'm1mini', 'vulcan']), ctx).reason, 'label:ambiguous');
        assert.equal(pol.evaluateJob(job(['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'm9mini']), ctx).reason, 'label:unknown');
    });
});

// ---------------------------------------------------------------------------
describe('dispatcher end to end', () => {
    const T0 = Date.UTC(2026, 10, 23, 12, 0, 0);
    const REPO = 'DoubleNode/dev-team';
    const ENV_ON = { FLEET_CI_DISPATCHER: '1', GITHUB_APP_CLIENT_ID: 'Iv-test-client', GITHUB_APP_PRIVATE_KEY: 'not-a-real-key-fixture' };
    const capacity = { memTotalBytes: 17179869184, memReclaimableBytes: 4080000000, memFreePct: 45, swapUsedBytes: 100, swapTotalBytes: 3221225472, load1: 1.2, load5: 1, load15: 1, ncpu: 10, teamSessions: 6, vmState: 'running' };
    const rec = (jobId, labels, over = {}) => Object.assign({
        key: `${REPO}#${jobId}#1`, owner: 'DoubleNode', repo: 'dev-team', runId: 5, runAttempt: 1, jobId,
        name: 'unit', labels, status: 'queued', conclusion: null, runnerName: null,
        createdAt: new Date(T0).toISOString(), firstSeenAt: new Date(T0 + jobId).toISOString(), inProgressAt: null, completedAt: null,
        run: { event: 'push', repoFullName: REPO, headRepoFullName: REPO },
    }, over);

    /** Pool file written with the OLD name (as production holds it today), then loaded: the real upgrade path. */
    function setup() {
        const dir = newDir();
        const poolFile = path.join(dir, 'ci-pool.json');
        writePool(poolFile, { m1mini: oldRecord({ paused: false, pausedBy: null, pausedAt: null, pauseReason: null, thresholds: {}, repos: null, mode: 'live' }) });
        const store = S.createPoolStore({ file: poolFile, logger: quiet });
        store.load();
        assert.equal(store.updateConfig({ allowlist: [REPO] }).ok, true);
        const clock = { t: T0 };
        const ghCalls = [];
        const gh = {
            async generateJitConfig(a) { ghCalls.push(a); return { runnerId: 9000 + ghCalls.length, encodedJitConfig: `JITSENTINEL-${ghCalls.length}` }; },
            async deleteRunner() { return { deleted: true }; },
        };
        const audit = { append() {} };
        const assignments = createAssignments({ file: path.join(dir, 'state.json'), github: gh, audit, now: () => clock.t, logger: quiet });
        const reports = new Map([['romulus', { receivedAt: T0, capacity, slots: [{ os: 'Linux', index: 1, state: 'idle', assignmentId: null }] }]]);
        const alerts = createAlerts({ now: () => clock.t, logger: quiet, getEmitter: () => null });
        const watcher = { async runCycle() { return 15000; }, stop() {} };
        const d = createDispatcher({ env: ENV_ON, store, assignments, alerts, audit, watcher, reports, logger: quiet, now: () => clock.t, setTimer: () => ({}), clearTimer() {} });
        return { d, ghCalls, assignments };
    }

    for (const [name, labels, wantHost] of [
        ['a pool job on the OLD label (fleet-pool,m1mini)', ['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'm1mini'], 'm1mini'],
        ['a static job on the OLD label (self-hosted,Linux,ARM64,m1mini)', ['self-hosted', 'Linux', 'ARM64', 'm1mini'], 'm1mini'],
        ['a job on the NEW label (romulus)', ['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'romulus'], 'romulus'],
        ['a fleet-pool-only job', ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'], 'romulus'],
    ]) {
        test(`${name} is minted on romulus as fcp-romulus-*, carrying the ${wantHost} label`, async () => {
            const s = setup();
            s.d.onJob(rec(1, labels), 'queued');
            await s.d.tick();
            assert.equal(s.ghCalls.length, 1, 'exactly one runner minted');
            const m = s.ghCalls[0];
            assert.match(m.name, /^fcp-romulus-[0-9a-f]+$/);
            assert.ok(m.labels.includes(wantHost), `labels ${m.labels} include ${wantHost}`);
            for (const l of labels) assert.ok(m.labels.map((x) => x.toLowerCase()).includes(l.toLowerCase()), `runner labels cover job label ${l}`);
            assert.equal(s.assignments.snapshot()[0].machine, 'romulus');
        });
    }

    test('a pre-deploy fcp-m1mini-* runner and a persistent m1mini-* runner both map to romulus in running[]', async () => {
        const s = setup();
        const pool = ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'];
        s.d.onJob(rec(7, pool, { status: 'in_progress', runnerName: 'fcp-m1mini-ab12cd34', inProgressAt: new Date(T0).toISOString() }), 'in_progress');
        s.d.onJob(rec(8, pool, { status: 'in_progress', runnerName: 'm1mini-linux-1', inProgressAt: new Date(T0).toISOString() }), 'in_progress');
        s.d.onJob(rec(9, pool, { status: 'in_progress', runnerName: 'm9mini-linux-1', inProgressAt: new Date(T0).toISOString() }), 'in_progress');
        const byJob = Object.fromEntries(s.d.running().map((r) => [r.jobId, r.machine]));
        assert.deepEqual(byJob, { 7: 'romulus', 8: 'romulus', 9: null });
    });
});

describe('assignments minted before the deploy', () => {
    test('a persisted m1mini assignment is cancelled/reported by the romulus agent', () => {
        const dir = newDir();
        const file = path.join(dir, 'state.json');
        const id = 'a_12345678-1234-1234-1234-123456789abc';
        const t = Date.now();
        fs.writeFileSync(file, JSON.stringify({ schemaVersion: 1, assignments: [{
            id, machine: 'm1mini', os: 'Linux', repo: 'DoubleNode/dev-team', runnerId: 42, runnerName: 'fcp-m1mini-ab12cd34',
            labels: ['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'm1mini'], state: 'delivered', createdAt: t - 1000, deliveredAt: t - 500,
        }] }));
        const a = createAssignments({ file, now: () => t, logger: quiet, github: { async generateJitConfig() { throw new Error('no'); }, async deleteRunner() { return { deleted: true }; } } });
        a.load();
        assert.deepEqual(a.cancelListFor('romulus', t), [id], 'the renamed agent is told to kill the old listener');
        assert.deepEqual(a.cancelListFor('vulcan', t), []);
        assert.notEqual(a.report(id, 'romulus', { state: 'failed' }).status, 'notfound');
        assert.equal(a.report(id, 'vulcan', { state: 'failed' }).status, 'notfound', 'another machine still cannot touch it');
    });
});

// ---------------------------------------------------------------------------
const bearer = (r, token) => r.set('Authorization', `Bearer ${token}`);
const admin = (r) => bearer(r, ADMIN);

function world(dir, opts = {}) {
    const pool = S.createPoolStore({ file: path.join(dir, 'ci-pool.json'), logger: quiet });
    if (opts.load !== false) pool.load();
    const assignments = createAssignments({
        file: path.join(dir, 'state.json'), logger: quiet,
        github: { async generateJitConfig() { throw new Error('GitHub must not be called'); }, async deleteRunner() { throw new Error('GitHub must not be called'); } },
    });
    const app = express();
    app.use(express.json({ limit: '10mb' }));
    registerCiPoolRoutes(app, { store: pool, assignments, dispatcher: { isEnabled: () => false }, logger: quiet });
    const runnerStore = registerCiRunnersRoutes(app, { file: path.join(dir, 'ci-runners.json'), poolStore: pool });
    return { app, pool, runnerStore };
}

describe('telemetry push and admin routes under the old name', () => {
    const payload = (machine, jobs = []) => ({
        schema_version: 1, machine, reportedAt: '2026-11-23T12:00:00Z', reporterVersion: '1.0.0',
        host: { uptimeSeconds: 10 }, vm: null,
        runners: [{ name: 'm1mini-linux-1', serviceState: 'up', labels: ['self-hosted'], currentJob: null }], jobs,
    });

    test('the reporter pushing machine:"m1mini" with romulus\'s telemetry key is accepted and stored under romulus', async () => {
        const dir = newDir();
        writePool(path.join(dir, 'ci-pool.json'), { m1mini: oldRecord({ telemetryKeyHash: null }) });
        const w = world(dir);
        const mintRes = await admin(request(w.app).post('/api/ci-pool/machines/m1mini/telemetry-key'));
        assert.equal(mintRes.status, 200);
        assert.equal(mintRes.body.machine, 'romulus', 'the admin route echoes the record it acted on');
        const key = mintRes.body.key;
        for (const name of ['m1mini', 'romulus']) {
            const r = await bearer(request(w.app).post('/api/ci-runners-push'), key).send(payload(name));
            assert.equal(r.status, 200, `${name}: ${JSON.stringify(r.body)}`);
            assert.equal(r.body.machine, 'romulus');
        }
        assert.deepEqual([...w.runnerStore.machines.keys()], ['romulus'], 'no phantom m1mini machine');
        const other = await bearer(request(w.app).post('/api/ci-runners-push'), key).send(payload('vulcan'));
        assert.equal(other.status, 403, 'still cannot write another machine');
        assert.equal((await bearer(request(w.app).post('/api/ci-runners-push'), key).send(payload('M1MINI'))).status, 403, 'case variant still refused');
        const unknown = await bearer(request(w.app).post('/api/ci-runners-push'), key).send(payload('m9mini'));
        assert.equal(unknown.status, 403);
    });

    test('a stored pre-rename m1mini telemetry record is folded into romulus (jobs + rollups), not left as a phantom', () => {
        const dir = newDir();
        const w = world(dir);
        const store = w.runnerStore;
        const job = { id: 'job-1', runner: 'm1mini-linux-1', repo: 'DoubleNode/dev-team', workflow: 'CI', jobName: 'unit', runUrl: null, result: 'success', minutes: 10, startedAt: '2026-11-23T11:00:00Z', endedAt: '2026-11-23T11:10:00Z' };
        const { validatePush } = require('../lib/ci-runners-routes');
        const now = new Date('2026-11-23T12:00:00Z');
        const first = store.applyPush(validatePush(payload('m1mini', [job])), now);
        assert.equal(first.jobsAccepted, 1);
        assert.deepEqual([...store.machines.keys()], ['m1mini']);
        const second = store.applyPush(validatePush(payload('romulus', [job])), new Date('2026-11-23T12:01:00Z'));
        assert.equal(second.jobsDuplicate, 1, 'the old record\'s jobs dedupe the new push');
        assert.deepEqual([...store.machines.keys()], ['romulus']);
        assert.equal(store.machines.get('romulus').jobs.length, 1);
        assert.equal(store.rollups.machines.has('m1mini'), false);
        assert.equal(store.rollups.machines.has('romulus'), true, 'rollup history moved with the record');
    });

    test('PUT /api/ci-pool/machines/m1mini after the rename edits romulus, never creates an m1mini record', async () => {
        const dir = newDir();
        writePool(path.join(dir, 'ci-pool.json'), { m1mini: oldRecord() });
        const w = world(dir);
        const r = await admin(request(w.app).put('/api/ci-pool/machines/m1mini')).send({ paused: false });
        assert.equal(r.status, 200, JSON.stringify(r.body));
        assert.equal(r.body.machine, 'romulus');
        assert.deepEqual(Object.keys(w.pool.listMachines()), ['romulus']);
        assert.equal(w.pool.getMachine('romulus').paused, false);
    });
});
