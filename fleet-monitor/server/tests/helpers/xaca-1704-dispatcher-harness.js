'use strict';
// Shared harness for XACA-1704-003/-014: real store + assignments + dispatcher over a temp dir, fake clock, no network.
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('node:assert/strict');
const { after } = require('node:test');

const { createPoolStore, GIB } = require('../../lib/ci-pool-store');
const { createAssignments } = require('../../lib/ci-dispatch-assignments');
const { createAudit } = require('../../lib/ci-dispatch-audit');
const { createAlerts } = require('../../lib/ci-dispatch-alerts');
const { createDispatcher } = require('../../lib/ci-dispatcher');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1704-disp-'));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const T0 = Date.UTC(2026, 10, 1, 12, 0, 0);
const REPO = 'DoubleNode/dev-team';
const CREDS = { FLEET_CI_DISPATCHER: '1', GITHUB_APP_CLIENT_ID: 'Iv-test-client', GITHUB_APP_PRIVATE_KEY: 'not-a-real-key-fixture' };
const POOL_M1MINI = ['self-hosted', 'macOS', 'ARM64', 'fleet-pool', 'm1mini'];
const POOL_LINUX = ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'];
const CAP = { memTotalBytes: 16 * GIB, memReclaimableBytes: 4 * GIB, memFreePct: 45, swapUsedBytes: 100, swapTotalBytes: 3 * GIB, load1: 1, load5: 1, load15: 1, ncpu: 10, vmState: 'running' };
let seq = 0;

const job = (jobId, labels) => ({
    key: `${REPO}#${jobId}#1`, owner: 'DoubleNode', repo: 'dev-team', runId: 5, runAttempt: 1, jobId, name: 'unit', labels: labels.slice(),
    status: 'queued', conclusion: null, runnerName: null, createdAt: new Date(T0 - 60000).toISOString(), firstSeenAt: new Date(T0).toISOString(),
    inProgressAt: null, completedAt: null, run: { event: 'push', repoFullName: REPO, headRepoFullName: REPO },
});

/** machines: id -> {cap, slots}. Real store/assignments/dispatcher, fake clock, no network. */
function build(machines) {
    const dir = path.join(TMP, `s${++seq}`);
    fs.mkdirSync(dir, { recursive: true });
    const clock = { t: T0 };
    const store = createPoolStore({ file: path.join(dir, 'ci-pool.json'), logger: { error() {} } });
    store.load();
    assert.equal(store.updateConfig({ allowlist: [REPO] }).ok, true);
    const reports = new Map();
    for (const [id, spec] of Object.entries(machines)) {
        assert.equal(store.upsertMachine(id, { enabled: true }).ok, true);
        assert.equal(store.upsertMachine(id, { paused: false }, { by: 'operator', now: T0 }).ok, true);
        reports.set(id, {
            receivedAt: T0 - 4000, capacity: Object.assign({}, CAP, spec.cap), agentVersion: '1.0.0',
            slots: spec.slots || [{ os: 'macOS', index: 1, state: 'idle', assignmentId: null }, { os: 'Linux', index: 1, state: 'idle', assignmentId: null }],
        });
    }
    const auditFile = path.join(dir, 'audit.jsonl');
    const audit = createAudit({ path: auditFile, keep: 2, now: () => new Date(clock.t) });
    const github = { async generateJitConfig() { return { runnerId: 1, encodedJitConfig: 'JITSENTINEL' }; }, async deleteRunner() { return { deleted: true }; } };
    const assignments = createAssignments({ file: path.join(dir, 'state.json'), github, audit, now: () => clock.t, logger: { error() {}, warn() {} } });
    const logger = { log() {}, warn() {}, error() {} };
    const alerts = createAlerts({ now: () => clock.t, logger, getEmitter: () => null });
    const dispatcher = createDispatcher({
        env: CREDS, store, assignments, alerts, audit, reports, logger, now: () => clock.t,
        watcher: { async runCycle() { return 15000; }, stop() {} }, setTimer: () => ({}), clearTimer() {},
        routeCoverage: () => ({ missing: [], configured: true }),
    });
    const auditRows = () => (fs.existsSync(auditFile) ? fs.readFileSync(auditFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
    return { store, reports, dispatcher, clock, auditRows, alerts };
}
module.exports = { build, job, POOL_M1MINI, POOL_LINUX, GIB, T0 };
