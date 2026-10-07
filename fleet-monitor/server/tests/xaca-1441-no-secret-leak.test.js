//
//  xaca-1441-no-secret-leak.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1441-005 -- Requirement 7/11 sentinel test. A sentinel JIT config and a sentinel
 * per-host key go through a full mint > deliver > start > bind > complete cycle, a restart,
 * and every operator route. The sentinels must NOT appear in:
 *   - any file under the data dir (state, pool, audit and every rotated generation, temp files)
 *   - console output (console.* is captured for the duration of the cycle)
 *   - any HTTP response except the ONE poll response that owns the delivery
 * Both sentinels are checked verbatim AND in base64 / base64url / hex / percent-encoded form.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { test, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');

const FLEET = 'xaca1441-leak-fleet-token-aaaaaaaa';
const ADMIN = 'xaca1441-leak-admin-token-bbbbbbbb';
const SAVED = { a: process.env.FLEET_AUTH_TOKEN, b: process.env.FLEET_ADMIN_TOKEN };
process.env.FLEET_AUTH_TOKEN = FLEET;
process.env.FLEET_ADMIN_TOKEN = ADMIN;

const { createPoolStore } = require('../lib/ci-pool-store');
const { createAssignments } = require('../lib/ci-dispatch-assignments');
const { createAudit } = require('../lib/ci-dispatch-audit');
const { registerCiPoolRoutes } = require('../lib/ci-pool-routes');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1441-005-leak-'));
after(() => {
    fs.rmSync(TMP, { recursive: true, force: true });
    for (const [k, v] of [['FLEET_AUTH_TOKEN', SAVED.a], ['FLEET_ADMIN_TOKEN', SAVED.b]]) {
        if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
});

const JIT = 'LEAKTEST-JITCONFIG-SENTINEL-8c41d7f0';
const HOST_KEY = `fcp_${'Zq9'.repeat(14)}Z`.slice(0, 47);            // fcp_ + 43 chars
const T0 = Date.UTC(2026, 9, 6, 12, 0, 0);

/** Every encoding a careless serializer might use. */
function variants(secret) {
    const b = Buffer.from(secret, 'utf8');
    return [
        secret,
        b.toString('base64'), b.toString('base64').replace(/=+$/, ''),
        b.toString('base64url'), b.toString('hex'),
        encodeURIComponent(secret), secret.toLowerCase(),
    ].filter((v, i, a) => a.indexOf(v) === i);
}

function walk(dir) {
    const out = [];
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) out.push(...walk(p)); else out.push(p);
    }
    return out;
}

const poll = (app, key) => request(app).post('/api/ci-pool/agent/poll').set('Authorization', `Bearer ${key}`).send({
    schemaVersion: 1, agentVersion: '1.0.0',
    capacity: { memTotalBytes: 1, memReclaimableBytes: 1, memFreePct: 50, swapUsedBytes: 0, load1: 0.1, ncpu: 8, vmState: 'running' },
    slots: [{ os: 'Linux', index: 1, state: 'idle', assignmentId: null }],
});

test('sentinel JIT config and host key never reach disk, console, or any response but the owning poll', async () => {
    const dir = path.join(TMP, 'data');
    fs.mkdirSync(dir, { recursive: true });
    const clock = { t: T0 };

    // ---- capture console for the whole cycle
    const captured = [];
    const saved = {};
    for (const m of ['log', 'info', 'warn', 'error', 'debug']) {
        saved[m] = console[m];
        console[m] = (...a) => captured.push(a.map((x) => (typeof x === 'string' ? x : JSON.stringify(x))).join(' '));
    }
    const responses = [];            // { label, text }
    let ownerText = null;
    let appHolder = null;

    try {
        const store = createPoolStore({ file: path.join(dir, 'ci-pool.json') });
        store.load();
        store.upsertMachine('m4mini', { enabled: true });
        store.upsertMachine('m1mini', { enabled: true });
        store.setHostSecret('m4mini', HOST_KEY);
        store.setHostSecret('m1mini', `fcp_${'Y'.repeat(43)}`);

        const gh = {
            async generateJitConfig() { return { runnerId: 4242, encodedJitConfig: JIT }; },
            async deleteRunner() { return { deleted: true }; },
        };
        // tiny maxBytes forces audit rotation so rotated generations are scanned too
        const audit = createAudit({ path: path.join(dir, 'ci-dispatch-audit.jsonl'), keep: 2, maxBytes: 600, now: () => new Date(clock.t) });
        const mkAssign = () => createAssignments({ file: path.join(dir, 'ci-dispatch-state.json'), github: gh, audit, now: () => clock.t });
        const assignments = mkAssign();
        const app = express();
        app.use(express.json());
        registerCiPoolRoutes(app, { store, assignments, dispatcher: { isEnabled: () => true }, audit, now: () => clock.t });
        appHolder = app;

        const rec = async (label, p) => { const r = await p; responses.push({ label, text: r.text }); return r; };
        const job = { owner: 'acme', repo: 'widgets', jobId: 100, runId: 5, name: 'shell-suite', labels: ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'] };
        const minted = await assignments.mint({ job, machine: 'm4mini', labels: ['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'm4mini'], os: 'Linux' });
        assert.equal(minted.ok, true);
        const id = minted.assignment.id;

        // before delivery: every operator-visible surface
        await rec('get-pool-pending', request(app).get('/api/ci-pool'));
        await rec('poll-other-machine', poll(app, `fcp_${'Y'.repeat(43)}`));
        await rec('poll-fleet-token-401', poll(app, FLEET));
        await rec('poll-no-key-401', request(app).post('/api/ci-pool/agent/poll').send({}));

        // THE delivery
        const owning = await poll(app, HOST_KEY);
        ownerText = owning.text;
        assert.equal(owning.body.assignments[0].jitConfig, JIT, 'the owning poll does carry it');

        // everything after: state posts, second poll, GET, admin writes
        await rec('poll-second', poll(app, HOST_KEY));
        const st = (state, extra) => request(app).post(`/api/ci-pool/assignments/${id}/state`).set('Authorization', `Bearer ${HOST_KEY}`).send(Object.assign({ state }, extra));
        await rec('state-started', st('started'));
        await rec('state-started-again', st('started'));
        assignments.bindJob({ ...job, runnerName: minted.assignment.runnerName, status: 'in_progress' }, 'in_progress');
        await rec('get-pool-running', request(app).get('/api/ci-pool'));
        await rec('state-illegal-409', st('cancelled'));
        await rec('state-completed', st('completed', { exitCode: 0, reason: 'ok' }));
        await rec('state-other-machine-404', request(app).post(`/api/ci-pool/assignments/${id}/state`).set('Authorization', `Bearer fcp_${'Y'.repeat(43)}`).send({ state: 'started' }));
        await rec('put-machine', request(app).put('/api/ci-pool/machines/m4mini').set('Authorization', `Bearer ${ADMIN}`).send({ paused: true, reason: 'leak test' }));
        await rec('put-config', request(app).put('/api/ci-pool/config').set('Authorization', `Bearer ${ADMIN}`).send({ allowlist: ['acme/widgets'] }));
        await rec('put-bad-400', request(app).put('/api/ci-pool/machines/m4mini').set('Authorization', `Bearer ${ADMIN}`).send({ keyHash: 'x' }));

        // a second minted assignment that expires undelivered, plus a swept DELETE
        const m2 = await assignments.mint({ job: { ...job, jobId: 101 }, machine: 'm4mini', labels: ['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'm4mini'], os: 'Linux' });
        await rec('get-pool-second-pending', request(app).get('/api/ci-pool'));
        clock.t += 61000;
        await assignments.sweep();
        assert.equal(assignments.get(m2.assignment.id).state, 'expired');

        // restart: a fresh instance loads the persisted file
        const assignments2 = mkAssign();
        assert.equal(assignments2.load().ok, true);
        await assignments2.sweep();
        await rec('get-pool-after-restart', request(appHolder).get('/api/ci-pool'));
    } finally {
        for (const m of Object.keys(saved)) console[m] = saved[m];
    }

    const keyHash = crypto.createHash('sha256').update(HOST_KEY).digest('hex');
    const secrets = { jit: variants(JIT), hostKey: variants(HOST_KEY) };
    const hits = [];

    // 1. every file under the data dir (state, pool, audit + rotated generations, any temp file)
    const files = walk(dir);
    assert.equal(files.some((f) => f.endsWith('ci-dispatch-state.json')), true);
    assert.equal(files.some((f) => /ci-dispatch-audit\.jsonl\.\d$/.test(f)), true, 'audit rotated at least once, so rotated files were scanned');
    assert.equal(files.some((f) => f.includes('.tmp-')), false, 'no temp file left behind');
    for (const f of files) {
        const body = fs.readFileSync(f, 'utf8');
        for (const [name, vs] of Object.entries(secrets)) for (const v of vs) if (body.includes(v)) hits.push(`${path.basename(f)} contains ${name} (${v.slice(0, 12)}...)`);
        // ci-pool.json legitimately holds the key's sha256 (that is how keys are verified); no other file may.
        if (!f.endsWith('ci-pool.json') && body.includes(keyHash)) hits.push(`${path.basename(f)} contains the key hash`);
    }

    // 2. console output
    const out = captured.join('\n');
    for (const [name, vs] of Object.entries(secrets)) for (const v of vs) if (out.includes(v)) hits.push(`console contains ${name}`);

    // 3. every response but the owning poll
    assert.equal(responses.length >= 14, true);
    for (const { label, text } of responses) {
        for (const [name, vs] of Object.entries(secrets)) for (const v of vs) if (text.includes(v)) hits.push(`response ${label} contains ${name}`);
        if (text.includes(keyHash)) hits.push(`response ${label} contains the key hash`);
    }
    assert.deepEqual(hits, []);

    // controls: the scan is not vacuous. The owning response does contain the config, and the pool
    // file does hold the key's hash (so the hash scan above would catch it anywhere else).
    assert.equal(ownerText.includes(JIT), true);
    assert.equal(fs.readFileSync(path.join(dir, 'ci-pool.json'), 'utf8').includes(keyHash), true);
});
