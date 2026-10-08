//
//  xaca-1444-pr1101-r1.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1444 PR #1101 round 1 (subitems 012, 017, 018, 019):
 *   012  banner kind is decided by the server's gated per-job `noEligibleMachine`, proven on bodies
 *        produced by the REAL dispatcher (shadow / live <120 s / live >=120 s / field absent).
 *   017  jobs picked up by PERSISTENT runners are exposed as running[] and rendered as running rows,
 *        deduped against JIT assignments by repo#jobId.
 *   018  focus survives a card refresh for every control, and a poll-age-only change never rebuilds.
 *   019  the pause dialog is modal: background inert while open, restored on close.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const { JSDOM } = require('jsdom');
const { createPoolStore } = require('../lib/ci-pool-store');
const { createAssignments } = require('../lib/ci-dispatch-assignments');
const { createAlerts } = require('../lib/ci-dispatch-alerts');
const { createDispatcher } = require('../lib/ci-dispatcher');

const PUB = path.join(__dirname, '..', 'public', 'shared', 'js');
const QUEUE_JS = fs.readFileSync(path.join(PUB, 'lcars-ci-queue.js'), 'utf8');
const POOL_JS = fs.readFileSync(path.join(PUB, 'lcars-ci-pool.js'), 'utf8');
const T0 = Date.UTC(2026, 9, 7, 18, 0, 0);
const REPO = 'DoubleNode/dev-team';
const LABELS = ['self-hosted', 'macOS', 'ARM64', 'fleet-pool', 'm1mini'];
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1444-r1-'));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));
let seq = 0;

function world(mode) {
    const dir = path.join(TMP, `w${++seq}`);
    fs.mkdirSync(dir, { recursive: true });
    const clock = { t: T0 };
    const store = createPoolStore({ file: path.join(dir, 'p.json'), logger: { error() {} } });
    store.load();
    store.updateConfig({ allowlist: [REPO] });
    store.upsertMachine('m1mini', { enabled: true });
    const gh = { async generateJitConfig() { return { runnerId: 1, encodedJitConfig: 'X' }; }, async deleteRunner() { return { deleted: true }; } };
    const assignments = createAssignments({ file: path.join(dir, 's.json'), github: gh, audit: { append() {} }, now: () => clock.t, logger: { error() {}, warn() {} } });
    const lg = { log() {}, warn() {}, error() {} };
    const alerts = createAlerts({ now: () => clock.t, logger: lg, getEmitter: () => null });
    const reports = new Map();
    const refresh = () => reports.set('m1mini', { receivedAt: clock.t - 2000, slots: [{ os: 'macOS', index: 1, state: 'busy', assignmentId: 'a' }, { os: 'macOS', index: 2, state: 'idle', assignmentId: null }], capacity: {} });
    refresh();
    const d = createDispatcher({
        env: { FLEET_CI_DISPATCHER: mode, GITHUB_APP_CLIENT_ID: 'x', GITHUB_APP_PRIVATE_KEY: 'y' }, store, assignments, alerts,
        watcher: { async runCycle() { return 15000; }, stop() {} }, reports, logger: lg, now: () => clock.t, audit: { append() {} },
        setTimer: () => ({}), clearTimer() {},
    });
    return { d, clock, refresh, assignments };
}
const jobRec = (i, minutesOld, extra) => Object.assign({
    key: `${REPO}#${i}#1`, owner: 'DoubleNode', repo: 'dev-team', runId: 5, runAttempt: 1, jobId: i, name: 'unit', labels: LABELS.slice(),
    status: 'queued', conclusion: null, runnerName: null, createdAt: new Date(T0 - minutesOld * 60000).toISOString(),
    firstSeenAt: new Date(T0).toISOString(), inProgressAt: null, completedAt: null,
    branch: 'main', workflow: 'CI', url: `https://github.com/${REPO}/actions/runs/5/job/${i}`,
    run: { event: 'push', repoFullName: REPO, headRepoFullName: REPO },
}, extra || {});

function bodyOf(w) {
    return { serverTime: new Date(w.clock.t).toISOString(), machines: {}, assignments: w.assignments.snapshot(), queue: w.d.queue(), running: w.d.running(),
        noCapacity: w.d.noCapacity(), queueAge: w.d.queueAge(), queueAgeThresholdSec: w.d.queueAgeThresholdSec() };
}
function renderQueue(body) {
    const dom = new JSDOM('<div id="q" hidden></div>', { runScripts: 'outside-only' });
    dom.window.eval(QUEUE_JS);
    const c = dom.window.document.getElementById('q');
    dom.window.LCARSCIQueue.render(body, c, { document: dom.window.document });
    return c;
}
const kindOf = (c) => c.querySelector('[data-ciq-banner]').getAttribute('data-ciq-kind');

async function scenario(mode, minutesOld, steps) {
    const w = world(mode);
    for (let i = 1; i <= 44; i++) w.d.onJob(jobRec(i, minutesOld), 'queued');
    await w.d.tick();
    for (const advance of steps) { w.clock.t += advance; w.refresh(); await w.d.tick(); }
    return w;
}

describe('012: banner kind from a body produced by the REAL dispatcher', () => {
    const cases = [
        { name: 'shadow, 32 min old (2026-10-07)', mode: 'shadow', age: 32, steps: [5000], kind: 'age', flag: false },
        { name: 'live, noCapSince < 120 s, 32 min old (2026-10-07)', mode: '1', age: 32, steps: [5000], kind: 'age', flag: false },
        { name: 'live, noCapSince >= 120 s, 32 min old', mode: '1', age: 32, steps: [5000, 130000], kind: 'both', flag: true },
        { name: 'live, noCapSince >= 120 s, young jobs', mode: '1', age: 2, steps: [5000, 130000], kind: 'nomachine', flag: true },
        { name: 'shadow, young jobs: nothing to say', mode: 'shadow', age: 2, steps: [5000, 130000], kind: 'none', flag: false },
    ];
    for (const c of cases) {
        test(c.name, async () => {
            const w = await scenario(c.mode, c.age, c.steps);
            const body = bodyOf(w);
            assert.ok(body.queue.length > 0);
            assert.ok(body.queue.every((q) => typeof q.noEligibleMachine === 'boolean'), 'server emits the explicit boolean on every item');
            assert.equal(body.queue.some((q) => q.noEligibleMachine), c.flag);
            assert.equal(kindOf(renderQueue(body)), c.kind);
        });
    }
    test('the flag is exactly the noCapacity() gate: summary and per-job flag cannot disagree', async () => {
        for (const [mode, steps] of [['shadow', [5000]], ['1', [5000]], ['1', [5000, 130000]]]) {
            const w = await scenario(mode, 2, steps);
            const body = bodyOf(w);
            assert.equal(body.queue.some((q) => q.noEligibleMachine), body.noCapacity.active, `${mode} ${steps}`);
        }
    });
    test('field absent (older server): falls back to noCapacity.active minus queue-age-only', async () => {
        const aged = bodyOf(await scenario('1', 32, [5000]));
        aged.queue.forEach((q) => { delete q.noEligibleMachine; });
        assert.ok(aged.queue.every((q) => q.noCapacityMs > 0), 'raw ungated noCapacityMs is present and must NOT decide the kind');
        assert.equal(kindOf(renderQueue(aged)), 'age');
        const young = bodyOf(await scenario('1', 2, [5000, 130000]));
        young.queue.forEach((q) => { delete q.noEligibleMachine; });
        assert.equal(kindOf(renderQueue(young)), 'nomachine');
    });
});

describe('017: persistent-runner running jobs', () => {
    test('picked-up pool jobs are exposed as running[] with the machine resolved from the runner name', async () => {
        const w = world('shadow');
        w.d.onJob(jobRec(1, 3), 'queued');
        w.d.onJob(jobRec(2, 3), 'queued');
        w.d.onJob(jobRec(3, 3), 'queued');
        await w.d.tick();
        w.d.onJob(jobRec(1, 3, { status: 'in_progress', runnerName: 'm1mini-macos-1', inProgressAt: new Date(T0).toISOString() }), 'pickup');
        w.d.onJob(jobRec(2, 3, { status: 'in_progress', runnerName: 'some-other-runner\u0007x' }), 'in_progress');
        const run = w.d.running();
        assert.deepEqual(run.map((r) => r.jobId).sort(), [1, 2]);
        const a = run.find((r) => r.jobId === 1);
        assert.equal(a.machine, 'm1mini');
        assert.equal(a.runnerName, 'm1mini-macos-1');
        assert.equal(a.repo, REPO);
        assert.equal(a.branch, 'main');
        assert.equal(a.workflow, 'CI');
        assert.match(a.url, /^https:\/\/github\.com\//);
        const b = run.find((r) => r.jobId === 2);
        assert.equal(b.machine, null);
        assert.equal(b.runnerName, 'some-other-runner x', 'control characters are replaced');
        assert.deepEqual(w.d.queue().map((q) => q.jobId), [3], 'queue[] semantics unchanged: still-queued jobs only');
        w.d.onJob(jobRec(1, 3, { status: 'completed' }), 'completed');
        assert.deepEqual(w.d.running().map((r) => r.jobId), [2]);
    });

    test('a non-pool job is never shown as running', async () => {
        const w = world('shadow');
        w.d.onJob(jobRec(9, 1, { labels: ['self-hosted', 'macOS'], status: 'in_progress', runnerName: 'x' }), 'in_progress');
        assert.deepEqual(w.d.running(), []);
    });

    test('dormant dispatcher: running() is empty', () => {
        const dir = path.join(TMP, `w${++seq}`);
        fs.mkdirSync(dir, { recursive: true });
        const store = createPoolStore({ file: path.join(dir, 'p.json'), logger: { error() {} } });
        store.load();
        const lg = { log() {}, warn() {}, error() {} };
        const d = createDispatcher({ env: {}, store, assignments: { snapshot: () => [], bindJob() {} }, alerts: createAlerts({ now: () => T0, logger: lg, getEmitter: () => null }),
            watcher: { async runCycle() { return 1; }, stop() {} }, reports: new Map(), logger: lg, now: () => T0, audit: { append() {} }, setTimer: () => ({}), clearTimer() {} });
        assert.deepEqual(d.running(), []);
    });

    test('UI: a persistent-runner job renders as a running row (runner name when machine is null); JIT + persistent never duplicate', () => {
        const body = {
            serverTime: new Date(T0).toISOString(), machines: {}, queue: [],
            assignments: [{ machine: 'm4mini', repo: REPO, state: 'running', boundJob: { id: 7, name: 'jit', branch: 'b', url: null }, boundAt: new Date(T0 - 60000).toISOString() }],
            running: [
                { key: `${REPO}#7#1`, repo: REPO, jobId: 7, name: 'jit', branch: 'b', workflow: 'CI', url: null, runnerName: 'fcp-x', machine: 'm4mini', startedAt: new Date(T0 - 60000).toISOString() },
                { key: `${REPO}#8#1`, repo: REPO, jobId: 8, name: 'persistent', branch: 'main', workflow: 'CI', url: null, runnerName: 'weird-runner-1', machine: null, startedAt: new Date(T0 - 90000).toISOString() },
                { key: `${REPO}#9#1`, repo: REPO, jobId: 9, name: 'persistent2', branch: 'main', workflow: 'CI', url: null, runnerName: 'm1mini-linux-2', machine: 'm1mini', startedAt: null },
            ],
        };
        const c = renderQueue(body);
        const rows = Array.from(c.querySelectorAll('tbody tr'));
        assert.equal(rows.length, 3, 'job 7 appears once');
        const by = (n) => rows.find((r) => r.textContent.includes(n));
        assert.equal(by('jit').getAttribute('data-ciq-status'), 'running');
        assert.equal(by('jit').getAttribute('data-ciq-machine'), 'm4mini');
        assert.equal(by('persistent').getAttribute('data-ciq-status'), 'running');
        assert.match(by('persistent').lastElementChild.textContent, /weird-runner-1/);
        assert.equal(by('persistent2').getAttribute('data-ciq-machine'), 'm1mini');
        // a job that is both in running[] and (stale) queue[] shows once, as running
        body.queue = [{ key: `${REPO}#8#1`, repo: REPO, jobId: 8, name: 'persistent', waitingMs: 1000, noEligibleMachine: false }];
        assert.equal(renderQueue(body).querySelectorAll('tbody tr').length, 3);
    });
});

function poolDom() {
    const dom = new JSDOM('<!doctype html><body><nav id="nav"><button id="bg">bg</button></nav><div id="p"></div></body>', { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(POOL_JS);
    return dom;
}
const machine = (over) => Object.assign({ enabled: true, paused: false, pausedBy: null, pausedAt: null, pauseReason: null, hasKey: true, capacity: null, slots: [],
    lastPollAt: new Date(T0 - 5000).toISOString(), pauseMarker: null, pauseDrift: null, state: 'enabled', stateReason: 'accepting', capability: 'dormant' }, over);
const poolBody = (m, t) => ({ schemaVersion: 1, serverTime: new Date(t || T0).toISOString(), machines: m, assignments: [] });

describe('018: focus survives a refresh for every control', () => {
    const rows = [
        { control: 'pause', m: machine({}) },
        { control: 'resume', m: machine({ paused: true, state: 'paused' }) },
        { control: 'enable', m: machine({ enabled: false, state: 'disabled', capability: 'unknown' }) },
        { control: 'enable-blocked', m: machine({ enabled: false, state: 'disabled', capability: 'dormant' }) },
        { control: 'copy', m: machine({ enabled: false, state: 'disabled', capability: 'dormant' }) },
    ];
    for (const row of rows) {
        test(`${row.control}: same logical control is focused after a re-render with a new poll age`, () => {
            const dom = poolDom();
            const doc = dom.window.document, el = doc.getElementById('p');
            dom.window.LCARSCIPool.render(poolBody({ mx: row.m }), el, { document: doc });
            const find = () => el.querySelector('[data-cicd-pool-control="mx:' + row.control + '"]');
            const before = find();
            assert.ok(before, row.control + ' control exists');
            before.focus();
            assert.equal(doc.activeElement, before);
            dom.window.LCARSCIPool.render(poolBody({ mx: row.m }, T0 + 30000), el, { document: doc });
            assert.equal(doc.activeElement, find(), 'focus stays on the same logical control');
            assert.notEqual(doc.activeElement, doc.body);
        });
    }
    test('poll-age-only change patches the text in place and does NOT rebuild the card', () => {
        const dom = poolDom();
        const doc = dom.window.document, el = doc.getElementById('p');
        const m = machine({});
        dom.window.LCARSCIPool.render(poolBody({ mx: m }), el, { document: doc });
        const btn = el.querySelector('[data-cicd-pool-control="mx:pause"]');
        const age = el.querySelector('[data-cicd-pool-age]');
        const was = age.textContent;
        dom.window.LCARSCIPool.render(poolBody({ mx: m }, T0 + 30000), el, { document: doc });
        assert.equal(el.querySelector('[data-cicd-pool-control="mx:pause"]'), btn, 'same button node');
        assert.equal(el.querySelector('[data-cicd-pool-age]'), age, 'same age node');
        assert.notEqual(age.textContent, was);
        assert.match(age.textContent, /ago/);
    });
    test('a real state change still rebuilds and lands focus on the card\'s first control', () => {
        const dom = poolDom();
        const doc = dom.window.document, el = doc.getElementById('p');
        dom.window.LCARSCIPool.render(poolBody({ mx: machine({}) }), el, { document: doc });
        el.querySelector('[data-cicd-pool-control="mx:pause"]').focus();
        dom.window.LCARSCIPool.render(poolBody({ mx: machine({ paused: true, state: 'paused' }) }), el, { document: doc });
        assert.equal(doc.activeElement, el.querySelector('[data-cicd-pool-control="mx:resume"]'));
    });
});

describe('019: the pause dialog is modal', () => {
    test('background is inert + aria-hidden while open, the live region is not, everything is restored on close; confirm is distinct', () => {
        const dom = poolDom();
        const doc = dom.window.document, el = doc.getElementById('p');
        dom.window.LCARSCIPool.render(poolBody({ mx: machine({}) }), el, { document: doc });
        const opener = el.querySelector('[data-cicd-pool-control="mx:pause"]');
        opener.click();
        const dlg = el.querySelector('[role="dialog"]');
        assert.ok(dlg);
        assert.equal(doc.getElementById('nav').hasAttribute('inert'), true, 'sibling outside the widget is inert');
        assert.equal(el.querySelector('[data-cicd-pool-list]').hasAttribute('inert'), true, 'the card list is inert');
        assert.equal(el.querySelector('[data-cicd-pool-status]').hasAttribute('inert'), false, 'the live region keeps announcing');
        assert.equal(dlg.closest('[inert]'), null, 'the dialog itself is never inert');
        const confirm = dlg.querySelector('[data-cicd-pool-dlg="confirm"]');
        const cancel = dlg.querySelector('[data-cicd-pool-dlg="cancel"]');
        assert.ok(confirm.classList.contains('cicd-pool-btn-caution'));
        assert.ok(!cancel.classList.contains('cicd-pool-btn-caution'));
        assert.match(confirm.textContent, /❚❚/, 'not colour alone: a glyph marks the confirming action');
        // a click on a background control while open is ignored (fallback for engines without inert)
        const calls = [];
        el.querySelector('[data-cicd-pool-list]').dispatchEvent(new dom.window.Event('x'));
        opener.click();
        assert.equal(el.querySelectorAll('[role="dialog"]').length, 1);
        cancel.click();
        assert.equal(el.querySelector('[role="dialog"]'), null);
        assert.equal(doc.getElementById('nav').hasAttribute('inert'), false);
        assert.equal(el.querySelector('[data-cicd-pool-list]').hasAttribute('inert'), false);
        assert.equal(doc.getElementById('nav').hasAttribute('aria-hidden'), false);
        assert.equal(calls.length, 0);
        assert.equal(doc.activeElement, el.querySelector('[data-cicd-pool-control="mx:pause"]'), 'focus returns to the invoking control');
    });
});

// ---- XACA-1444-022: the dialog's inert/aria-hidden is released on EVERY teardown path ----------------------
const CICD_JS = fs.readFileSync(path.join(__dirname, '..', 'public', 'lcars', 'js', 'lcars-cicd.js'), 'utf8');
const tick = () => new Promise((r) => setTimeout(r, 0));
function dlgDom() {
    const dom = new JSDOM('<!doctype html><body><nav id="nav"><button id="bg">bg</button></nav><aside id="pre" aria-hidden="true">x</aside>' +
        '<div id="cicd-content"></div><div id="cicd-pool"></div><div id="cicd-queue" hidden></div></body>', { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(POOL_JS);
    const doc = dom.window.document, el = doc.getElementById('cicd-pool');
    const okFetch = async () => ({ ok: true, status: 200, json: async () => ({}) });
    dom.window.LCARSCIPool.render(poolBody({ mx: machine({}) }), el, { document: doc, fetch: okFetch });
    el.querySelector('[data-cicd-pool-control="mx:pause"]').click();
    assert.ok(el.querySelector('[role="dialog"]'), 'dialog open');
    assert.equal(doc.getElementById('nav').hasAttribute('inert'), true, 'precondition: background inert');
    return { dom, doc, el, okFetch };
}
// Nothing may still be inert, and aria-hidden may survive ONLY where it pre-existed (#pre); decorative glyph spans are ignored.
function assertUsable(doc, why) {
    assert.deepEqual(Array.from(doc.querySelectorAll('[inert]')).map((e) => e.id || e.tagName), [], why + ': nothing inert');
    const hidden = Array.from(doc.querySelectorAll('[aria-hidden="true"]')).filter((e) => e.tagName !== 'SPAN').map((e) => e.id || e.tagName);
    assert.deepEqual(hidden, ['pre'], why + ': only the pre-existing aria-hidden remains');
}
const goodBody = () => poolBody({ mx: machine({}) });
const PATHS = [
    ['cancel', async (c) => { c.el.querySelector('[data-cicd-pool-dlg="cancel"]').click(); }],
    ['escape', async (c) => { c.el.querySelector('[data-cicd-pool-dlg="cancel"]').dispatchEvent(new c.dom.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); }],
    ['normal confirm', async (c) => { c.el.querySelector('[data-cicd-pool-dlg="confirm"]').click(); await tick(); await tick(); }],
    ['render(null)', async (c) => { c.dom.window.LCARSCIPool.render(null, c.el, { document: c.doc }); }],
    ['render(malformed)', async (c) => { c.dom.window.LCARSCIPool.render({ machines: 'nope' }, c.el, { document: c.doc }); }],
    ['render throwing', async (c) => {
        const bad = { machines: { get mx() { throw new Error('boom'); } } };
        assert.throws(() => c.dom.window.LCARSCIPool.render(bad, c.el, { document: c.doc }), /boom/);
    }],
    ['container cleared by the tab', async (c) => { c.el.innerHTML = ''; await tick(); }],
    ['dialog node removed', async (c) => { c.el.querySelector('[data-cicd-pool-dialog-host]').innerHTML = ''; await tick(); }],
    ['explicit teardown()', async (c) => { c.dom.window.LCARSCIPool.teardown(); }],
];
describe('022: inert is released on every teardown path', () => {
    for (const [name, act] of PATHS) {
        test(name + ': page usable afterwards, pre-existing aria-hidden kept, next render works', async () => {
            const c = dlgDom();
            await act(c);
            assertUsable(c.doc, name);
            c.dom.window.LCARSCIPool.render(goodBody(), c.el, { document: c.doc, fetch: c.okFetch });
            assert.equal(c.el.hidden, false);
            assert.ok(c.el.querySelector('[data-cicd-pool-control="mx:pause"]'), 'pool view rendered again');
            assertUsable(c.doc, name + ' + re-render');
        });
    }
    test('belt-and-braces: a render with recorded inert but no dialog in the container releases it', async () => {
        const c = dlgDom();
        const host = c.el.querySelector('[data-cicd-pool-dialog-host]');
        host.removeChild(host.firstChild);   // synchronous: the observer has not run yet, the render must heal on its own
        c.dom.window.LCARSCIPool.render(goodBody(), c.el, { document: c.doc });
        assertUsable(c.doc, 'belt');
    });
    for (const failure of ['http500', 'http404', 'reject', 'badbody']) {
        test('real lcars-cicd refresh failure (' + failure + ') releases the dashboard', async () => {
            const c = dlgDom();
            const w = c.dom.window;
            w.eval(QUEUE_JS);
            w.fetch = async (u) => {
                if (String(u).indexOf('/api/ci-pool') === -1) return { ok: false, status: 500, json: async () => ({}) };
                if (failure === 'reject') throw new Error('net');
                if (failure === 'badbody') return { ok: true, status: 200, json: async () => ({ machines: null }) };
                return { ok: false, status: failure === 'http404' ? 404 : 500, json: async () => ({}) };
            };
            w.eval(CICD_JS);
            await w.LCARSCICD.refresh();
            assert.equal(c.el.hidden, true, 'pool container hidden by the tab');
            assertUsable(c.doc, failure);
        });
    }
});
