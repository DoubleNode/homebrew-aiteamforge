//
//  xaca-1479-ci-priority-dispatch.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1479-005 / -006 -- manual CI priority lane, dispatcher side.
 *   005: branch -> open-PR ci-priority label resolver (cached, TTL), FAILING TOWARD NORMAL, wired
 *        into the watcher so job records carry `priority` on first sight and refresh per TTL.
 *   006: decide() orders priority-then-FIFO and SURGES mints to cover every job ahead of a
 *        priority job in its label set, strictly within slot capacity, honouring coverage + shadow.
 *
 * NO network: the GitHub transport is a scripted fetch stub or a fake client. Real pool store /
 * assignments / alerts over a temp dir, fake clock and timers. No live server, no launchd.
 */

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');

const {
    createGithubClient, createPriorityResolver, priorityOfLabels, GithubError,
    PRIORITY_TTL_MS, PRIORITY_FAIL_AUDIT_EVERY_MS, PURPOSE_PERMISSIONS,
} = require('../lib/ci-dispatch-github');
const { createWatcher } = require('../lib/ci-dispatch-watcher');
const { createPoolStore } = require('../lib/ci-pool-store');
const { createAssignments } = require('../lib/ci-dispatch-assignments');
const { createAlerts } = require('../lib/ci-dispatch-alerts');
const { createAudit, sanitize } = require('../lib/ci-dispatch-audit');
const { createDispatcher, priorityRank, surgePlan } = require('../lib/ci-dispatcher');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1479-prio-'));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const T0 = Date.UTC(2026, 9, 9, 12, 0, 0);
const OWNER = 'DoubleNode';
const REPO_NAME = 'dev-team';
const REPO = `${OWNER}/${REPO_NAME}`;
const BRANCH = 'feature/xaca-9999';
const POOL = ['self-hosted', 'Linux', 'ARM64', 'fleet-pool'];
let seq = 0;

// ============================================================================
// 005 -- resolver (fake GitHub client)
// ============================================================================

function resolverHarness(opts = {}) {
    const clock = { t: T0 };
    const calls = [];
    const auditRows = [];
    const logs = [];
    const timers = new Map();
    let tid = 0;
    const gh = {
        rate: { mode: 'normal' },
        answer: async () => [],
        getRateState() { return { ...gh.rate }; },
        async listBranchPullLabels(a) { calls.push(a); return gh.answer(a); },
    };
    const r = createPriorityResolver({
        github: gh,
        audit: { append: (event, fields) => auditRows.push(Object.assign({ event }, fields)) },
        log: (level, msg) => logs.push({ level, msg }),
        now: () => clock.t,
        timeoutMs: opts.timeoutMs,
        setTimer: (fn, ms) => { const h = ++tid; timers.set(h, { fn, ms }); return h; },
        clearTimer: (h) => timers.delete(h),
    });
    const resolve = (branch = BRANCH, extra = {}) => r.resolve(Object.assign({ owner: OWNER, repo: REPO_NAME, branch }, extra));
    const fireTimers = () => { for (const [h, t] of [...timers]) { timers.delete(h); t.fn(); } };
    return { r, gh, clock, calls, auditRows, logs, resolve, fireTimers, timers };
}

const pr = (number, ...labels) => ({ number, labels });
const ghErr = (code, status) => new GithubError(code, `fixture ${code}`, status === undefined ? {} : { status });

describe('005 resolver: label -> priority', () => {
    test('ci-priority:critical -> critical, with a resolved audit line', async () => {
        const h = resolverHarness();
        h.gh.answer = async () => [pr(12, 'bug', 'ci-priority:critical')];
        assert.equal(await h.resolve(), 'critical');
        assert.equal(h.auditRows.length, 1);
        assert.equal(h.auditRows[0].event, 'priority');
        assert.equal(h.auditRows[0].priority, 'critical');
        assert.equal(h.auditRows[0].reason, 'resolved');
        assert.equal(h.auditRows[0].prNumber, 12);
    });

    test('ci-priority:high -> high; both labels on one PR -> critical (highest wins)', async () => {
        const h = resolverHarness();
        h.gh.answer = async () => [pr(1, 'ci-priority:high')];
        assert.equal(await h.resolve('b1'), 'high');
        h.gh.answer = async () => [pr(2, 'ci-priority:high', 'ci-priority:critical')];
        assert.equal(await h.resolve('b2'), 'critical');
    });

    test('a PR with NO ci-priority label -> normal and NO audit line (the plain default, not a failure)', async () => {
        const h = resolverHarness();
        h.gh.answer = async () => [pr(3, 'enhancement', 'priority:critical')];   // the TICKET's own label is not ours
        assert.equal(await h.resolve(), 'normal');
        assert.equal(h.auditRows.length, 0);
    });

    test('two PRs agreeing on a label -> that label', async () => {
        const h = resolverHarness();
        h.gh.answer = async () => [pr(4, 'ci-priority:high'), pr(5, 'ci-priority:high')];
        assert.equal(await h.resolve(), 'high');
    });

    test('priorityOfLabels: exact names only; any other ci-priority:* is malformed', () => {
        assert.equal(priorityOfLabels([]), 'normal');
        assert.equal(priorityOfLabels(['ci-priority:critical']), 'critical');
        for (const bad of ['ci-priority:urgent', 'CI-Priority:Critical', 'ci-priority:', 'ci-priority:normal', ' ci-priority:high']) {
            assert.deepEqual(priorityOfLabels([bad]), { malformed: true }, bad);
        }
    });

    test('the pulls purpose is least privilege: Pull requests read, nothing else', () => {
        assert.deepEqual(PURPOSE_PERMISSIONS.pulls, { pull_requests: 'read' });
    });
});

describe('005 resolver: every failure resolves NORMAL and writes an audit line', () => {
    const cases = [
        ['network error', (h) => { h.gh.answer = async () => { throw ghErr('NETWORK'); }; }, 'error'],
        ['primary/secondary rate limit', (h) => { h.gh.answer = async () => { throw ghErr('RATE_LIMITED', 429); }; }, 'rate-limited'],
        ['client already suspended (no call made)', (h) => { h.gh.rate = { mode: 'suspended' }; h.gh.answer = async () => [pr(1, 'ci-priority:critical')]; }, 'rate-limited'],
        ['HTTP 403 (missing Pull requests: read)', (h) => { h.gh.answer = async () => { throw ghErr('HTTP', 403); }; }, 'permission'],
        ['HTTP 422 on the down-scoped token mint', (h) => { h.gh.answer = async () => { throw ghErr('HTTP', 422); }; }, 'permission'],
        ['HTTP 404', (h) => { h.gh.answer = async () => { throw ghErr('NOT_INSTALLED', 404); }; }, 'not-found'],
        ['HTTP 500', (h) => { h.gh.answer = async () => { throw ghErr('HTTP', 500); }; }, 'error'],
        ['non-Error throw', (h) => { h.gh.answer = async () => { throw 'boom'; }; }, 'error'],   // eslint-disable-line no-throw-literal
        ['no open PR for the branch', (h) => { h.gh.answer = async () => []; }, 'no-pr'],
        ['two PRs with conflicting ci-priority labels', (h) => { h.gh.answer = async () => [pr(1, 'ci-priority:critical'), pr(2, 'ci-priority:high')]; }, 'conflicting-prs'],
        ['one labelled PR + one unlabelled PR (conflict)', (h) => { h.gh.answer = async () => [pr(1, 'ci-priority:critical'), pr(2)]; }, 'conflicting-prs'],
        ['malformed label', (h) => { h.gh.answer = async () => [pr(1, 'ci-priority:urgent')]; }, 'malformed-label'],
        ['malformed label alongside a valid one', (h) => { h.gh.answer = async () => [pr(1, 'ci-priority:critical', 'ci-priority:URGENT')]; }, 'malformed-label'],
        ['malformed response body', (h) => { h.gh.answer = async () => ({ not: 'an array' }); }, 'bad-response'],
    ];
    for (const [name, arrange, reason] of cases) {
        test(`${name} -> normal, audit reason ${reason}`, async () => {
            const h = resolverHarness();
            arrange(h);
            assert.equal(await h.resolve(), 'normal');
            const rows = h.auditRows.filter((a) => a.reason === reason);
            assert.equal(rows.length, 1, JSON.stringify(h.auditRows));
            assert.equal(rows[0].priority, 'normal');
            assert.equal(rows[0].repo, REPO);
            assert.equal(rows[0].branch, BRANCH);
            assert.equal(h.auditRows.some((a) => a.priority !== 'normal'), false, 'a failure never audits an upward priority');
        });
    }

    test('a hung lookup resolves NORMAL at the timeout (audit timeout) and the late answer only fills the cache', async () => {
        const h = resolverHarness({ timeoutMs: 5000 });
        let release;
        h.gh.answer = () => new Promise((res) => { release = res; });
        const p = h.resolve();
        await Promise.resolve();
        assert.equal(h.timers.size, 1);
        h.fireTimers();
        assert.equal(await p, 'normal');
        assert.ok(h.auditRows.some((a) => a.reason === 'timeout'));
        release([pr(9, 'ci-priority:critical')]);
        await new Promise((r) => setImmediate(r));
        assert.equal(h.r.peek({ owner: OWNER, repo: REPO_NAME, branch: BRANCH }), 'critical');
    });

    test('403 warns ONCE per installation owner, across branches and repeats', async () => {
        const h = resolverHarness();
        h.gh.answer = async () => { throw ghErr('HTTP', 403); };
        await h.resolve('a');
        await h.resolve('b');
        h.clock.t += PRIORITY_TTL_MS + 1;
        await h.resolve('a');
        assert.equal(h.logs.filter((l) => l.level === 'warn' && /Pull requests: read/.test(l.msg)).length, 1);
    });

    test('repeated failure audit lines are rate-limited per (repo, branch, reason), with a suppressed count', async () => {
        const h = resolverHarness();
        h.gh.answer = async () => { throw ghErr('HTTP', 403); };
        for (let i = 0; i < 5; i++) {        // 5 lookups, each past the cache TTL, inside one audit window
            await h.resolve();
            h.clock.t += PRIORITY_TTL_MS + 1;
        }
        assert.equal(h.calls.length, 5, 'the cache expired each time, so GitHub really was asked 5 times');
        assert.equal(h.auditRows.length, 1, 'but only one audit line in the window');
        h.clock.t = T0 + PRIORITY_FAIL_AUDIT_EVERY_MS + 1;
        await h.resolve();
        assert.equal(h.auditRows.length, 2);
        assert.equal(h.auditRows[1].suppressed, 4);
    });

    test('a missing branch / owner never calls GitHub and is normal', async () => {
        const h = resolverHarness();
        assert.equal(await h.r.resolve({ owner: OWNER, repo: REPO_NAME, branch: null }), 'normal');
        assert.equal(await h.r.resolve({}), 'normal');
        assert.equal(h.calls.length, 0);
    });
});

describe('005 resolver: cache TTL', () => {
    test('within TTL: no second call; after TTL: re-asked, and a removed label drops back to normal', async () => {
        const h = resolverHarness();
        h.gh.answer = async () => [pr(1, 'ci-priority:critical')];
        assert.equal(await h.resolve(), 'critical');
        h.clock.t += PRIORITY_TTL_MS - 1;
        assert.equal(await h.resolve(), 'critical');
        assert.equal(h.calls.length, 1, 'served from cache inside the TTL');
        h.gh.answer = async () => [pr(1)];      // kb-ci-priority normal removed the label
        h.clock.t += 2;
        assert.equal(await h.resolve(), 'normal');
        assert.equal(h.calls.length, 2);
    });

    test('failures are cached too (a missing permission is not re-asked every cycle)', async () => {
        const h = resolverHarness();
        h.gh.answer = async () => { throw ghErr('HTTP', 403); };
        await h.resolve();
        await h.resolve();
        assert.equal(h.calls.length, 1);
    });

    test('the cache is per (owner/repo, branch), and concurrent lookups share one request', async () => {
        const h = resolverHarness();
        h.gh.answer = async (a) => (a.branch === 'hot' ? [pr(1, 'ci-priority:high')] : []);
        const [a, b, c] = await Promise.all([h.resolve('hot'), h.resolve('hot'), h.resolve('cold')]);
        assert.deepEqual([a, b, c], ['high', 'high', 'normal']);
        assert.equal(h.calls.length, 2);
        assert.equal(await h.r.resolve({ owner: OWNER, repo: 'other', branch: 'hot' }), 'high');
        assert.equal(h.calls.length, 3, 'another repo with the same branch name is its own key');
    });
});

// ============================================================================
// 005 -- listBranchPullLabels over a scripted fetch (no network)
// ============================================================================

const { privateKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});
function httpRes(status, body) {
    return { status, headers: { get: () => null }, json: async () => body };
}
function clientHarness(pullsHandler) {
    const calls = [];
    const client = createGithubClient({
        config: { GITHUB_APP_ID: '424242', GITHUB_APP_PRIVATE_KEY: privateKey },
        now: () => T0,
        fetch: async (url, init) => {
            const u = new URL(url);
            const call = { method: init.method, path: u.pathname + u.search, body: init.body ? JSON.parse(init.body) : undefined };
            calls.push(call);
            if (/\/installation$/.test(u.pathname)) return httpRes(200, { id: 777 });
            if (/\/access_tokens$/.test(u.pathname)) return httpRes(201, { token: 'ghs_fixture', expires_at: new Date(T0 + 3600e3).toISOString() });
            if (/\/pulls$/.test(u.pathname)) return pullsHandler(call);
            throw new Error(`unrouted ${call.path}`);
        },
    });
    return { client, calls };
}

describe('005 listBranchPullLabels', () => {
    test('queries open PRs by head=<owner>:<branch> under a pull_requests:read token; returns numbers + label names only', async () => {
        const h = clientHarness(() => httpRes(200, [{ number: 7, title: 'secret-ish title', labels: [{ name: 'ci-priority:high' }, { id: 1 }, null] }]));
        const out = await h.client.listBranchPullLabels({ owner: OWNER, repo: REPO_NAME, branch: 'feature/a b' });
        assert.deepEqual(out, [{ number: 7, labels: ['ci-priority:high'] }]);
        const pulls = h.calls.find((c) => /\/pulls/.test(c.path));
        assert.equal(pulls.path, `/repos/${OWNER}/${REPO_NAME}/pulls?state=open&head=${encodeURIComponent(`${OWNER}:feature/a b`)}&per_page=10`);
        const mint = h.calls.find((c) => /access_tokens/.test(c.path));
        assert.deepEqual(mint.body.permissions, { pull_requests: 'read' });
    });

    test('a 403 throws a GithubError with status (the resolver turns it into NORMAL); the branch is not in the message', async () => {
        const h = clientHarness(() => httpRes(403, { message: 'Resource not accessible by integration' }));
        await assert.rejects(h.client.listBranchPullLabels({ owner: OWNER, repo: REPO_NAME, branch: 'feature/zzz-unique' }),
            (e) => e instanceof GithubError && e.status === 403 && !e.message.includes('zzz-unique'));
    });

    test('bad branch / head owner are refused before any request', async () => {
        const h = clientHarness(() => httpRes(200, []));
        await assert.rejects(h.client.listBranchPullLabels({ owner: OWNER, repo: REPO_NAME, branch: 'a\nb' }), /invalid branch/);
        await assert.rejects(h.client.listBranchPullLabels({ owner: OWNER, repo: REPO_NAME, branch: 'x', headOwner: '../evil' }), /invalid head owner/);
        assert.equal(h.calls.length, 0);
    });

    test('audit allowlists the priority + surge fields (and still drops unknown keys)', () => {
        const p = sanitize('priority', { repo: REPO, branch: 'b', priority: 'normal', reason: 'no-pr', suppressed: 2, token: 'ghs_xxxxxxxxxxxx' }, 'ts');
        assert.deepEqual(p, { ts: 'ts', event: 'priority', repo: REPO, reason: 'no-pr', branch: 'b', priority: 'normal', suppressed: 2 });
        const s = sanitize('surge', { repo: REPO, jobId: 1, labelSet: 'x', priority: 'critical', ahead: 5, target: 6, forJobId: 6, junk: 1 }, 'ts');
        assert.equal(s.ahead, 5); assert.equal(s.target, 6); assert.equal(s.forJobId, 6); assert.equal('junk' in s, false);
    });
});

// ============================================================================
// 005 -- watcher wiring
// ============================================================================

function makeWorld() {
    const world = { queued: [], in_progress: [], jobs: {}, seen: new Map() };
    world.github = {
        getRateState: () => ({ mode: 'normal', resumeAt: null }),
        async conditionalGet({ path: p }) {
            let data; let m;
            if ((m = /\/actions\/runs\?status=(\w+)/.exec(p))) data = { workflow_runs: world[m[1]] };
            else if ((m = /\/actions\/runs\/(\d+)\/jobs/.exec(p))) data = { jobs: world.jobs[m[1]] || [] };
            else throw new Error(`unexpected path ${p}`);
            const body = JSON.stringify(data);
            const notModified = world.seen.get(p) === body;
            world.seen.set(p, body);
            return { status: notModified ? 304 : 200, notModified, data, etag: 'x' };
        },
    };
    return world;
}
const wrun = (id, extra = {}) => ({
    id, run_attempt: 1, event: 'push', updated_at: '2026-10-09T12:00:00Z', head_branch: BRANCH,
    repository: { full_name: REPO }, head_repository: { full_name: REPO }, ...extra,
});
const wjob = (id, extra = {}) => ({
    id, name: `job-${id}`, status: 'queued', conclusion: null, runner_name: null,
    labels: POOL.slice(), created_at: '2026-10-09T11:59:00Z', run_attempt: 1, ...extra,
});

function watcherSetup(resolvePriority) {
    const world = makeWorld();
    const clock = { t: T0 };
    const events = [];
    const w = createWatcher({
        github: world.github, allowlist: [REPO], now: () => clock.t,
        setTimer: () => 0, clearTimer: () => {}, log: () => {},
        onJob: (rec, change) => events.push({ change, rec }),
        ...(resolvePriority ? { resolvePriority } : {}),
    });
    return { world, clock, events, w };
}

describe('005 watcher: rec.priority on first sight, refreshed per TTL, never throws', () => {
    test('the FIRST queued emit already carries the resolved priority (looked up by run branch + head owner)', async () => {
        const asked = [];
        const s = watcherSetup(async (a) => { asked.push(a); return 'critical'; });
        s.world.queued = [wrun(1)]; s.world.jobs[1] = [wjob(11)];
        await s.w.runCycle();
        assert.equal(s.events[0].change, 'queued');
        assert.equal(s.events[0].rec.priority, 'critical');
        assert.deepEqual(asked[0], { owner: OWNER, repo: REPO_NAME, branch: BRANCH, headOwner: OWNER });
    });

    test('a throwing / rejecting / junk-returning resolver yields normal and the cycle still completes', async () => {
        for (const bad of [async () => { throw new Error('x'); }, () => { throw new Error('sync'); }, async () => 'CRITICAL', async () => ({})]) {
            const s = watcherSetup(bad);
            s.world.queued = [wrun(1)]; s.world.jobs[1] = [wjob(11)];
            const delay = await s.w.runCycle();
            assert.ok(Number.isFinite(delay));
            assert.equal(s.events[0].rec.priority, 'normal');
        }
    });

    test('a label change is picked up for a still-queued job: one priority event, no duplicate queued', async () => {
        let value = 'normal';
        const s = watcherSetup(async () => value);
        s.world.queued = [wrun(1)]; s.world.jobs[1] = [wjob(11), wjob(12)];
        await s.w.runCycle();
        assert.deepEqual(s.events.map((e) => [e.change, e.rec.priority]), [['queued', 'normal'], ['queued', 'normal']]);
        value = 'high';
        s.clock.t += PRIORITY_TTL_MS + 1;
        await s.w.runCycle();
        const pri = s.events.filter((e) => e.change === 'priority');
        assert.equal(pri.length, 2);
        assert.ok(pri.every((e) => e.rec.priority === 'high'));
        await s.w.runCycle();      // unchanged -> silent
        assert.equal(s.events.filter((e) => e.change === 'priority').length, 2);
    });

    test('without a resolver the record shape is unchanged (no priority key)', async () => {
        const s = watcherSetup(null);
        s.world.queued = [wrun(1)]; s.world.jobs[1] = [wjob(11)];
        await s.w.runCycle();
        assert.equal('priority' in s.events[0].rec, false);
    });

    test('end-to-end with the REAL resolver: no PR -> normal + audit; labelled PR -> critical', async () => {
        const auditRows = [];
        const prs = { [BRANCH]: [], 'feature/hot': [pr(5, 'ci-priority:critical')] };
        const r = createPriorityResolver({
            github: { getRateState: () => ({ mode: 'normal' }), listBranchPullLabels: async (a) => prs[a.branch] },
            audit: { append: (event, f) => auditRows.push(Object.assign({ event }, f)) },
            now: () => T0,
        });
        const s = watcherSetup(r.resolve);
        s.world.queued = [wrun(1), wrun(2, { head_branch: 'feature/hot' })];
        s.world.jobs[1] = [wjob(11)]; s.world.jobs[2] = [wjob(21)];
        await s.w.runCycle();
        const by = Object.fromEntries(s.events.map((e) => [e.rec.jobId, e.rec.priority]));
        assert.deepEqual(by, { 11: 'normal', 21: 'critical' });
        assert.ok(auditRows.some((a) => a.reason === 'no-pr' && a.branch === BRANCH));
    });
});

// ============================================================================
// 006 -- decide(): ordering + surge
// ============================================================================

const ENV_ON = { FLEET_CI_DISPATCHER: '1', GITHUB_APP_CLIENT_ID: 'Iv-test-client', GITHUB_APP_PRIVATE_KEY: 'not-a-real-key-fixture' };
const ENV_SHADOW = Object.assign({}, ENV_ON, { FLEET_CI_DISPATCHER: 'shadow' });

const capacity = () => ({
    memTotalBytes: 17179869184, memReclaimableBytes: 4080000000, memFreePct: 45,
    swapUsedBytes: 100, swapTotalBytes: 3221225472, load1: 1.2, load5: 1, load15: 1, ncpu: 10,
    teamSessions: 6, vmState: 'running',
});
const slots = (n) => Array.from({ length: n }, (_, i) => ({ os: 'Linux', index: i + 1, state: 'idle', assignmentId: null }));

function rec(jobId, over = {}) {
    return Object.assign({
        key: `${REPO}#${jobId}#1`, owner: OWNER, repo: REPO_NAME, runId: 5, runAttempt: 1, jobId,
        name: 'unit', labels: POOL.slice(), status: 'queued', conclusion: null, runnerName: null,
        branch: BRANCH, createdAt: new Date(T0).toISOString(), firstSeenAt: new Date(T0 + jobId * 1000).toISOString(),
        inProgressAt: null, completedAt: null,
        run: { event: 'push', repoFullName: REPO, headRepoFullName: REPO },
    }, over);
}

function setup(opts = {}) {
    const dir = path.join(TMP, `d${++seq}`);
    fs.mkdirSync(dir, { recursive: true });
    const clock = { t: T0 + 60000 };
    const store = createPoolStore({ file: path.join(dir, 'ci-pool.json'), logger: { error() {} } });
    store.load();
    assert.equal(store.updateConfig({ allowlist: [REPO] }).ok, true);
    const machines = opts.machines || { m1mini: {} };
    for (const [id, extra] of Object.entries(machines)) assert.equal(store.upsertMachine(id, Object.assign({ enabled: true, paused: false, prefers: 'short' }, extra)).ok, true);
    const reports = new Map();
    const ghCalls = [];
    const gh = {
        async generateJitConfig(a) { ghCalls.push(['mint', a]); return { runnerId: 9000 + ghCalls.length, encodedJitConfig: `JITSENTINEL-${ghCalls.length}` }; },
        async deleteRunner(a) { ghCalls.push(['delete', a]); return { deleted: true }; },
    };
    const auditRows = [];
    const audit = opts.realAudit
        ? createAudit({ path: path.join(dir, 'audit.jsonl'), now: () => new Date(clock.t) })
        : { append: (event, fields) => auditRows.push(Object.assign({ event }, fields)) };
    const assignments = createAssignments({ file: path.join(dir, 'state.json'), github: gh, audit, now: () => clock.t, logger: { error() {}, warn() {} } });
    const logger = { log() {}, warn() {}, error() {} };
    const alerts = createAlerts({ now: () => clock.t, logger, getEmitter: () => null });
    const watcher = { async runCycle() { return 15000; }, stop() {} };
    const d = createDispatcher({
        env: opts.env || ENV_ON, store, assignments, alerts, audit, watcher, reports, logger, now: () => clock.t,
        setTimer: () => ({}), clearTimer: () => {},
    });
    const report = (id, n) => reports.set(id, { receivedAt: clock.t, capacity: capacity(), slots: slots(n) });
    const mints = () => ghCalls.filter((c) => c[0] === 'mint');
    const mintedJobs = () => assignments.snapshot().slice().sort((a, b) => (a.createdAt < b.createdAt ? -1 : 1)).map((a) => a.intendedJob && a.intendedJob.id);
    return { d, store, assignments, reports, report, clock, ghCalls, auditRows, mints, mintedJobs, audit };
}

/** NORMAL x5 (older) + CRITICAL x1 (newest), one label set. */
function seedFivePlusCritical(s, criticalPriority = 'critical') {
    for (let i = 1; i <= 5; i++) s.d.onJob(rec(i, { priority: 'normal' }), 'queued');
    s.d.onJob(rec(6, { priority: criticalPriority }), 'queued');
}

describe('006 ordering', () => {
    test('priorityRank: critical < high < normal; missing / unknown / prototype names rank as normal', () => {
        assert.equal(priorityRank({ priority: 'critical' }), 0);
        assert.equal(priorityRank({ priority: 'high' }), 1);
        for (const p of [undefined, null, 'normal', 'CRITICAL', 'urgent', 'constructor', '__proto__', 7, {}]) {
            assert.equal(priorityRank({ priority: p }), 2, String(p));
        }
        assert.equal(priorityRank(null), 2);
    });

    test('queue order is priority then FIFO: the newest CRITICAL is minted for FIRST', async () => {
        const s = setup();
        s.report('m1mini', 6);
        seedFivePlusCritical(s);
        await s.d.tick();
        assert.equal(s.mintedJobs()[0], 6, 'critical job gets the first runner');
        assert.deepEqual(s.mintedJobs().slice(1), [1, 2, 3, 4, 5], 'then strict FIFO');
    });

    test('high sorts after critical and before normal; a TTL priority event re-orders a tracked job', async () => {
        const s = setup();
        s.report('m1mini', 3);
        s.d.onJob(rec(1, { priority: 'normal' }), 'queued');
        s.d.onJob(rec(2, { priority: 'high' }), 'queued');
        s.d.onJob(rec(3, { priority: 'normal' }), 'queued');
        s.d.onJob(rec(3, { priority: 'critical' }), 'priority');   // label added later
        await s.d.tick();
        assert.deepEqual(s.mintedJobs(), [3, 2, 1]);
    });
});

describe('006 surge', () => {
    test('NORMAL x5 older + CRITICAL x1 newest, ample slots: 6 mints, all audited as surge, within cap', async () => {
        const s = setup({ realAudit: true });
        s.report('m1mini', 8);
        seedFivePlusCritical(s);
        await s.d.tick();
        assert.equal(s.mints().length, 6, 'covers the critical job and all 5 ahead of it');
        const surge = s.audit.tail(100).filter((a) => a.event === 'surge');
        assert.equal(surge.length, 6);
        assert.ok(surge.every((a) => a.priority === 'critical' && a.target === 6 && a.ahead === 5 && a.forJobId === 6));
        assert.equal(surge.filter((a) => a.reason === 'surge:priority-job').length, 1);
        assert.equal(surge.filter((a) => a.reason === 'surge:job-ahead').length, 5);
        assert.ok(s.reports.get('m1mini').slots.length >= s.mints().length);
    });

    test('slot cap < 6: mints EXACTLY up to the cap (3), never past it, critical first', async () => {
        const s = setup();
        s.report('m1mini', 3);
        seedFivePlusCritical(s);
        await s.d.tick();
        assert.equal(s.mints().length, 3);
        assert.deepEqual(s.mintedJobs(), [6, 1, 2]);
        await s.d.tick();          // same capacity report: those 3 slots are now reserved
        assert.equal(s.mints().length, 3, 'a second tick does not over-mint past the reserved slots');
    });

    test('cap spread over two machines is honoured as one total (2 + 2 = 4 mints for 6 jobs)', async () => {
        const s = setup({ machines: { m1mini: {}, m4mini: {} } });
        s.report('m1mini', 2); s.report('m4mini', 2);
        seedFivePlusCritical(s);
        await s.d.tick();
        assert.equal(s.mints().length, 4);
        assert.equal(s.mintedJobs()[0], 6);
    });

    test('a ticket with no label: normal, FIFO, and NO surge audit', async () => {
        const s = setup();
        s.report('m1mini', 8);
        for (let i = 1; i <= 6; i++) s.d.onJob(rec(i), 'queued');   // no priority field at all
        await s.d.tick();
        assert.deepEqual(s.mintedJobs(), [1, 2, 3, 4, 5, 6]);
        assert.equal(s.auditRows.filter((a) => a.event === 'surge').length, 0);
    });

    test('coverage: runners already outstanding for the 5 older jobs => the critical job gets exactly ONE new mint', async () => {
        const s = setup();
        s.report('m1mini', 8);
        for (let i = 1; i <= 5; i++) s.d.onJob(rec(i, { priority: 'normal' }), 'queued');
        await s.d.tick();
        assert.equal(s.mints().length, 5);
        s.d.onJob(rec(6, { priority: 'critical' }), 'queued');
        await s.d.tick();
        assert.equal(s.mints().length, 6, 'no double-mint for jobs that are already covered');
        assert.equal(s.mintedJobs()[5], 6, 'the new runner is minted FOR the critical job');
        const surge = s.auditRows.filter((a) => a.event === 'surge');
        assert.equal(surge.length, 1);
        assert.equal(surge[0].jobId, 6);
    });

    test('shadow mode: priority is ordered and decided, but NOTHING is minted and no surge is audited', async () => {
        const s = setup({ env: ENV_SHADOW });
        s.report('m1mini', 8);
        seedFivePlusCritical(s);
        await s.d.tick();
        assert.equal(s.mints().length, 0);
        assert.equal(s.auditRows.filter((a) => a.event === 'surge').length, 0);
    });

    test('a per-host shadow machine never receives a surge mint', async () => {
        const s = setup({ machines: { m1mini: { mode: 'shadow' } } });
        s.report('m1mini', 8);
        seedFivePlusCritical(s);
        await s.d.tick();
        assert.equal(s.mints().length, 0);
    });

    test('across label sets sharing a host: the priority set gets the one free slot, not the alphabetically-first normal set', async () => {
        const s = setup();
        s.report('m1mini', 1);
        // 'arm64,fleet-pool,linux,m1mini,self-hosted' sorts BEFORE 'arm64,fleet-pool,linux,self-hosted'.
        s.d.onJob(rec(1, { labels: POOL.concat(['m1mini']), priority: 'normal' }), 'queued');
        s.d.onJob(rec(2, { priority: 'high' }), 'queued');
        await s.d.tick();
        assert.deepEqual(s.mintedJobs(), [2]);
    });

    test('surgePlan: target = newest priority job position; window excludes covered jobs; no priority => absent', () => {
        const key = (l) => l.join(',');
        const recs = [1, 2, 3, 4].map((i) => ({ key: `k${i}`, jobId: i, labels: ['a'], priority: i === 3 ? 'high' : 'normal' }));
        const plan = surgePlan(recs, new Set(['k1']), key);
        const sg = plan.get('a');
        assert.equal(sg.target, 3);
        assert.equal(sg.priority, 'high');
        assert.deepEqual([...sg.windowKeys], ['k2', 'k3']);
        assert.equal(sg.uncoveredInWindow, 2);
        assert.equal(surgePlan(recs.map((r) => Object.assign({}, r, { priority: 'normal' })), new Set(), key).size, 0);
    });

    test('kanban priority does NOT leak in: a job record carrying only unrelated fields stays normal', async () => {
        const s = setup();
        s.report('m1mini', 1);
        s.d.onJob(rec(1), 'queued');
        s.d.onJob(rec(2, { kanbanPriority: 'critical', labels: POOL.slice() }), 'queued');
        await s.d.tick();
        assert.deepEqual(s.mintedJobs(), [1]);
    });
});

describe('007 queue() priority field (additive)', () => {
    test('every queue item carries priority: critical/high pass through, missing/unknown/non-string -> normal', () => {
        const s = setup();
        s.d.onJob(rec(1, { priority: 'critical' }), 'queued');
        s.d.onJob(rec(2, { priority: 'high' }), 'queued');
        s.d.onJob(rec(3, { priority: 'normal' }), 'queued');
        s.d.onJob(rec(4), 'queued');
        s.d.onJob(rec(5, { priority: 'URGENT' }), 'queued');
        s.d.onJob(rec(6, { priority: 7 }), 'queued');
        s.d.onJob(rec(7, { priority: 'constructor' }), 'queued');
        const by = Object.fromEntries(s.d.queue().map((q) => [q.jobId, q]));
        assert.deepEqual([1, 2, 3, 4, 5, 6, 7].map((i) => by[i].priority), ['critical', 'high', 'normal', 'normal', 'normal', 'normal', 'normal']);
        for (const q of Object.values(by)) {
            assert.ok(['critical', 'high', 'normal'].includes(q.priority));
            for (const k of ['key', 'repo', 'jobId', 'name', 'jobClass', 'waitingMs', 'noCapacityMs', 'noEligibleMachine', 'branch', 'workflow', 'url', 'labels', 'status', 'runnerName', 'machine']) assert.ok(k in q, `existing field ${k} kept`);
        }
    });

    test('a TTL priority event updates the reported priority', () => {
        const s = setup();
        s.d.onJob(rec(1, { priority: 'normal' }), 'queued');
        s.d.onJob(rec(1, { priority: 'critical' }), 'priority');
        assert.equal(s.d.queue()[0].priority, 'critical');
    });
});
