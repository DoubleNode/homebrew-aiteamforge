//
//  xaca-1387-016-contract-shape.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1387-012/016 -- the PRODUCER's GET /api/ci-runners output conforms to the
 * CONSUMER's v1 contract (fleet-monitor/docs/CI-RUNNERS-API-CONTRACT.md,
 * authored by XACA-1388).
 *
 * Three layers, each catching what the others cannot:
 *   A. TABLE-DRIVEN SHAPE. Every key path in the consumer's canonical fixture
 *      (tests/fixtures/xaca-1388-ci-runners-healthy.json) is derived at runtime
 *      -- never transcribed -- and asserted present, with a compatible type, in
 *      our real HTTP output for an equivalent pushed dataset. A rename/removal/
 *      retype on our side fails a row here.
 *   B. CONSUMER ACCEPTANCE. Our real GET output is fed through the shipped
 *      lcars-cicd.js refresh() path in jsdom (same harness style as
 *      xaca-1388-005): it must render runner rows and NOT the
 *      UPDATE FAILED / unavailable states. Covers healthy, stale, offline, empty.
 *   C. SEMANTICS of the server-computed numbers (pure buildContractResponse,
 *      fixed clock): minutes = ceil(durationSeconds/60), hosted multipliers,
 *      UTC day/month windows, summary over ALL stored jobs.
 *
 * Vacuous-green guards: the fixture must yield a non-trivial number of paths,
 * and the set of paths we legitimately cannot check (children of a field we
 * serve as null by decision) is asserted EXACTLY, so coverage cannot shrink
 * silently.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');
const { JSDOM } = require('jsdom');

delete process.env.FLEET_AUTH_TOKEN; // requireApiKey is open when unset (same as the -003 smoke test)
const {
    registerCiRunnersRoutes, buildContractResponse, validatePush,
} = require('../lib/ci-runners-routes');

const FIXTURE_DIR = path.join(__dirname, 'fixtures');
const CICD_JS = path.join(__dirname, '..', 'public', 'lcars', 'js', 'lcars-cicd.js');
const fixture = (name) => JSON.parse(fs.readFileSync(path.join(FIXTURE_DIR, `xaca-1388-ci-runners-${name}.json`), 'utf8'));

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1387-016-'));
let seq = 0;
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

function mount() {
    const app = express();
    app.use(express.json({ limit: '10mb' }));
    const log = console.log; console.log = () => {};
    try {
        const store = registerCiRunnersRoutes(app, { file: path.join(TMP, `s${++seq}`, 'ci-runners.json') });
        return { app, store };
    } finally { console.log = log; }
}

// ---------------------------------------------------------------------------
// The equivalent dataset: the healthy fixture's machine, expressed as a PUSH.
// Timestamps are relative to the real clock so the real GET route (which
// stamps generatedAt with new Date()) sees fresh data and today's jobs.
// ---------------------------------------------------------------------------
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const RUN = (n) => `https://github.com/DoubleNode/dev-team/actions/runs/${n}`;

function healthyPush(nowMs) {
    const ago = (s) => iso(nowMs - s * 1000);
    const job = (id, runner, startAgo, dur, over = {}) => ({
        id, runner, workflow: 'bats', jobName: 'bats', repo: 'DoubleNode/dev-team',
        runUrl: RUN(1000 + Number(id.slice(-1))), startedAt: ago(startAgo), endedAt: ago(startAgo - dur),
        result: 'success', minutes: Math.round((dur / 60) * 100) / 100,
        branch: 'develop', event: 'push', durationSeconds: dur, jobUrl: `${RUN(1000 + Number(id.slice(-1)))}/job/${2000 + Number(id.slice(-1))}`,
        ...over,
    });
    return {
        schema_version: 1, machine: 'm1mini', reportedAt: ago(1), reporterVersion: '1.1.0',
        host: { uptimeSeconds: 864000, hostname: 'M1Mini.local', disk: { path: '/', totalBytes: 494000000000, freeBytes: 120000000000 } },
        vm: { name: 'ci-linux', state: 'running' },
        runners: [
            { name: 'm1mini-linux-1', os: 'Linux', busy: true, serviceState: 'up', labels: ['self-hosted', 'Linux', 'ARM64', 'm1mini'],
                currentJob: { id: 'a1b2c3d4-0000-4000-8000-000000000001', workflow: 'shell-suite', jobName: 'shell-suite (1/2)',
                    repo: 'DoubleNode/dev-team', branch: 'feature/xaca-1388', startedAt: ago(470), runUrl: RUN(1), jobUrl: `${RUN(1)}/job/2` } },
            { name: 'm1mini-linux-2', os: 'Linux', busy: false, serviceState: 'up', labels: ['self-hosted', 'Linux', 'ARM64', 'm1mini'], currentJob: null },
            // os/busy omitted on purpose: an older reporter -- the server derives them.
            { name: 'm1mini-macos-1', serviceState: 'up', labels: ['self-hosted', 'macOS', 'ARM64', 'm1mini'], currentJob: null },
        ],
        jobs: [
            job('j-0001', 'm1mini-linux-2', 1200, 271),
            job('j-0002', 'm1mini-macos-1', 1800, 125, { result: 'failure', event: 'pull_request', branch: 'feature/xaca-1386' }),
            job('j-0003', 'm1mini-linux-1', 2400, 60, { result: 'cancelled', durationSeconds: undefined, jobUrl: undefined,
                runUrl: `${RUN(1003)}/job/2003` }), // older reporter: duration + jobUrl derived
        ],
    };
}

async function getOurs({ ageSeconds = 0, empty = false } = {}) {
    const { app, store } = mount();
    if (!empty) {
        const now = Date.now();
        // applyPush with an injected receipt time models a machine last heard from ageSeconds ago.
        store.applyPush(validatePush(healthyPush(now)), new Date(now - ageSeconds * 1000));
    }
    const g = await request(app).get('/api/ci-runners');
    assert.equal(g.status, 200);
    return g.body;
}

// ---------------------------------------------------------------------------
// A. Table-driven shape
// ---------------------------------------------------------------------------

/** All key paths in a document. Arrays are walked by EVERY element (union). */
function keyPaths(doc) {
    const out = new Map(); // path -> Set(type)
    const typeOf = (v) => (v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v);
    (function walk(v, p) {
        if (p) {
            if (!out.has(p)) out.set(p, new Set());
            out.get(p).add(typeOf(v));
        }
        if (Array.isArray(v)) v.forEach((e) => walk(e, `${p}[]`));
        else if (v && typeof v === 'object') for (const k of Object.keys(v)) walk(v[k], p ? `${p}.${k}` : k);
    })(doc, '');
    return out;
}

/** Values of our document at a path; ancestors that are null are reported separately. */
function resolve(doc, p) {
    const segs = p.split('.');
    let cur = [{ v: doc }];
    const nullAncestor = [];
    let missing = 0;
    for (let i = 0; i < segs.length; i++) {
        const isArr = segs[i].endsWith('[]');
        const key = isArr ? segs[i].slice(0, -2) : segs[i];
        const next = [];
        for (const { v } of cur) {
            if (v === null) { nullAncestor.push(segs.slice(0, i).join('.')); continue; }
            if (!Object.prototype.hasOwnProperty.call(v, key)) { missing++; continue; }
            const val = v[key];
            if (isArr && Array.isArray(val)) val.forEach((e) => next.push({ v: e }));
            else next.push({ v: val });
        }
        cur = next;
    }
    return { values: cur.map((c) => c.v), nullAncestor, missing };
}

// Contract-sanctioned nullability (CI-RUNNERS-API-CONTRACT.md comments + rule 3
// "absent != zero"), plus fields the producer serves null by decision
// (2026-10-02: fallback, runner/vm uptimeSeconds, hostname/jobUrl/branch/event
// when the reporter did not supply them).
const NULL_ALLOWED = new Set([
    'fallback', 'fallback.macos.value', 'fallback.linux.value', 'summary',
    'machines[].hostname', 'machines[].uptimeSeconds', 'machines[].vm', 'machines[].vm.uptimeSeconds', 'machines[].disk',
    'machines[].runners[].os', 'machines[].runners[].uptimeSeconds', 'machines[].runners[].currentJob',
    'machines[].runners[].currentJob.branch', 'machines[].runners[].currentJob.runUrl', 'machines[].runners[].currentJob.jobUrl',
    'machines[].recentJobs[].os', 'machines[].recentJobs[].branch', 'machines[].recentJobs[].event',
    'machines[].recentJobs[].runUrl', 'machines[].recentJobs[].jobUrl',
]);
// Contract amendment (XACA-1387, contract owner approved 2026-10-02): job id is string | number.
const EXTRA_TYPES = {
    'machines[].runners[].currentJob.id': ['string', 'number'],
    'machines[].recentJobs[].id': ['string', 'number'],
};
// Served null BY DECISION (2026-10-02) -- the producer cannot supply them yet.
const DECIDED_NULL = ['fallback', 'machines[].runners[].uptimeSeconds', 'machines[].vm.uptimeSeconds'];
// Paths we cannot reach because an ancestor is null BY DECISION. Asserted exactly.
const EXPECTED_UNREACHABLE = [
    'fallback.checkedAt', 'fallback.linux', 'fallback.linux.armed', 'fallback.linux.value',
    'fallback.macos', 'fallback.macos.armed', 'fallback.macos.value',
];

const HEALTHY_PATHS = keyPaths(fixture('healthy'));

describe('A. table-driven shape vs the XACA-1388 healthy fixture', () => {
    let ours;
    const unreachable = new Set();

    test('guard: the fixture yields a non-trivial path table', async () => {
        assert.ok(HEALTHY_PATHS.size >= 50, `only ${HEALTHY_PATHS.size} paths derived`);
        ours = await getOurs();
    });

    for (const [p, fixtureTypes] of HEALTHY_PATHS) {
        test(`path ${p}`, async () => {
            if (!ours) ours = await getOurs();
            const { values, nullAncestor, missing } = resolve(ours, p);
            assert.equal(missing, 0, `${p}: key MISSING from our output (renamed/removed?)`);
            if (values.length === 0) {
                assert.ok(nullAncestor.length > 0, `${p}: no values and no null ancestor`);
                for (const a of nullAncestor) assert.ok(NULL_ALLOWED.has(a), `${p}: ancestor ${a} is null but the contract does not allow it`);
                unreachable.add(p);
                return;
            }
            const allowed = new Set([...fixtureTypes, ...(EXTRA_TYPES[p] || [])]);
            if (NULL_ALLOWED.has(p)) allowed.add('null');
            // An object-or-null field in the fixture must be object-or-null in ours too.
            for (const v of values) {
                const t = v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v;
                assert.ok(allowed.has(t), `${p}: type ${t} not in {${[...allowed].join(',')}}`);
                if (t === 'number') assert.ok(Number.isFinite(v), `${p}: non-finite number`);
            }
            // Every reachable path must carry at least one NON-null value in our
            // equivalent dataset unless it is null by decision -- otherwise the
            // type check above proved nothing.
            if (!DECIDED_NULL.includes(p) && fixtureTypes.has('null') === false) {
                assert.ok(values.some((v) => v !== null), `${p}: only nulls in our output; shape unverified`);
            }
        });
    }

    test('unreachable paths are EXACTLY the children of decided-null fields', () => {
        assert.deepEqual([...unreachable].sort(), [...EXPECTED_UNREACHABLE].sort());
    });

    test('top-level constants', async () => {
        const o = await getOurs();
        assert.equal(o.schemaVersion, 1);
        assert.equal(o.staleAfterSeconds, 180);
        assert.equal(o.offlineAfterSeconds, 600);
        assert.equal(o.fallback, null);
        assert.ok(!Number.isNaN(Date.parse(o.generatedAt)));
    });

    test('empty store matches the empty fixture exactly (bar generatedAt)', async () => {
        const o = await getOurs({ empty: true });
        const f = fixture('empty');
        assert.deepEqual({ ...o, generatedAt: 'X' }, { ...f, generatedAt: 'X' });
    });

    test('stale / offline fixtures: our top-level + machine keys are a superset', async () => {
        for (const [name, age] of [['stale', 300], ['offline', 1200]]) {
            const o = await getOurs({ ageSeconds: age });
            const f = fixture(name);
            for (const k of Object.keys(f)) assert.ok(k in o, `${name}: top-level ${k}`);
            for (const k of Object.keys(f.machines[0])) assert.ok(k in o.machines[0], `${name}: machine ${k}`);
        }
    });
});

// ---------------------------------------------------------------------------
// B. Consumer acceptance -- the shipped lcars-cicd.js renders our output
// ---------------------------------------------------------------------------

function loadUi() {
    assert.ok(fs.existsSync(CICD_JS), `MISSING consumer: ${CICD_JS}`);
    const dom = new JSDOM('<!doctype html><html><body><div id="cicd-content"></div></body></html>',
        { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(fs.readFileSync(CICD_JS, 'utf8'));
    const el = dom.window.document.getElementById('cicd-content');
    return { dom, api: dom.window.LCARSCICD, el };
}

async function renderOurs(body) {
    const env = loadUi();
    env.dom.window.fetch = () => Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(JSON.parse(JSON.stringify(body))) });
    const warn = env.dom.window.console.warn; env.dom.window.console.warn = () => {};
    try { await env.api.refresh(); } finally { env.dom.window.console.warn = warn; }
    return env;
}

describe('B. the XACA-1388 UI accepts and renders our real GET output', () => {
    for (const [label, age, status] of [['healthy', 0, 'ONLINE'], ['stale', 300, 'STALE'], ['offline', 1200, 'OFFLINE']]) {
        test(`${label}: renders machine ${status} with runner rows, no UPDATE FAILED`, async () => {
            const { el } = await renderOurs(await getOurs({ ageSeconds: age }));
            assert.equal(el.querySelector('[data-cicd-update-failed]'), null, 'UPDATE FAILED badge shown -- payload rejected');
            assert.equal(el.querySelector('[data-cicd-unavailable]'), null);
            assert.equal(/CI DATA UNAVAILABLE/.test(el.textContent), false);
            const card = el.querySelector('[data-cicd-machine="m1mini"]');
            assert.ok(card, 'machine card rendered');
            assert.equal(card.getAttribute('data-cicd-status'), status);
            assert.equal(el.querySelectorAll('[data-cicd-runner]').length, 3, 'runner rows rendered');
            assert.equal(el.querySelectorAll('tr[data-cicd-job]').length, 3, 'job rows rendered');
            if (label === 'healthy') {
                const busy = el.querySelector('[data-cicd-runner="m1mini-linux-1"]');
                assert.equal(busy.getAttribute('data-cicd-status'), 'BUSY');
                assert.equal(el.querySelector('[data-cicd-runner="m1mini-macos-1"]').getAttribute('data-cicd-status'), 'IDLE');
                // string GUID id passes through the UI's esc() into the hook attribute intact
                assert.ok(el.querySelector('tr[data-cicd-job="j-0001"]'));
                // fallback null -> UNKNOWN pills, never "armed" (contract rule 3)
                assert.equal(el.querySelector('[data-cicd-fallback="linux"]').getAttribute('data-cicd-state'), 'UNKNOWN');
            }
        });
    }
    test('empty: renders the "no CI runners reporting" state, not a failure', async () => {
        const { el } = await renderOurs(await getOurs({ empty: true }));
        assert.ok(el.querySelector('[data-cicd-empty]'));
        assert.equal(el.querySelector('[data-cicd-update-failed]'), null);
    });
    test('control: the harness CAN detect a rejected payload (schemaVersion removed)', async () => {
        const body = await getOurs();
        delete body.schemaVersion;
        const { el } = await renderOurs(body);
        assert.ok(el.querySelector('[data-cicd-update-failed]'), 'harness would be vacuous without this');
    });
});

// ---------------------------------------------------------------------------
// C. Semantics (pure, fixed clock)
// ---------------------------------------------------------------------------

describe('C. server-computed numbers', () => {
    const NOW = new Date('2026-10-15T12:00:00Z');
    const rec = (jobs, runners) => ({
        machine: 'm', receivedAt: '2026-10-15T11:59:30.000Z', reportedAt: '2026-10-15T11:59:30Z', reporterVersion: '1',
        host: { uptimeSeconds: 5 }, vm: { name: 'v', state: 'broken' }, runners, jobs,
    });
    const r = (name, extra = {}) => ({ name, serviceState: 'up', labels: [], currentJob: null, os: null, busy: null, ...extra });
    const j = (id, runner, start, end, extra = {}) => ({
        id, runner, workflow: 'w', jobName: 'w', repo: 'o/r', runUrl: null, startedAt: start, endedAt: end,
        result: 'success', minutes: 0, branch: null, event: null, durationSeconds: null, jobUrl: null, ...extra,
    });
    const jobs = [
        j('t1', 'lin', '2026-10-15T10:00:00Z', '2026-10-15T10:04:31Z'),           // 271 s -> 5 min, Linux
        j('t2', 'mac', '2026-10-15T09:00:00Z', '2026-10-15T09:02:05Z'),           // 125 s -> 3 min, macOS x10
        j('t3', 'lin', '2026-10-15T08:00:00Z', '2026-10-15T08:01:00Z'),           // 60 s  -> 1 min (exact, no round-up)
        j('c1', 'mac', '2026-10-01T00:00:00Z', '2026-10-01T00:00:01Z'),           // 1 s -> 1 min, cycle only
        j('y1', 'lin', '2026-10-14T23:59:00Z', '2026-10-15T00:00:30Z'),           // ended today (UTC) -> today
        j('p1', 'lin', '2026-09-30T23:00:00Z', '2026-09-30T23:30:00Z'),           // last month -> excluded
        j('gone', 'retired-runner', '2026-10-15T07:00:00Z', '2026-10-15T07:00:00Z', { durationSeconds: 0 }), // 0 min, no row
    ];
    const out = buildContractResponse([rec(jobs, [r('lin', { labels: ['Linux'] }), r('mac', { os: 'macOS' })])], NOW, { jobsLimit: 1 });

    test('summary.today / cycle sum ALL stored jobs (jobsLimit=1 does not truncate them)', () => {
        assert.equal(out.machines[0].recentJobs.length, 1);
        // today: t1 5 + t2 3 + t3 1 + y1 2 (90 s) + gone 0 = 11 min; hosted 5 + 30 + 1 + 2 + 0 = 38
        assert.deepEqual(out.summary.today, { jobs: 5, minutes: 11, hostedEquivalentMinutes: 38 });
        // cycle adds c1 (1 min macOS -> 10)
        assert.deepEqual(out.summary.cycle, { jobs: 6, minutes: 12, hostedEquivalentMinutes: 48, start: '2026-10-01', end: '2026-10-31' });
    });
    test('per-runner today / cycle', () => {
        const [lin, mac] = out.machines[0].runners;
        assert.deepEqual([lin.today, lin.cycle], [{ jobs: 3, minutes: 8 }, { jobs: 3, minutes: 8 }]);
        assert.deepEqual([mac.today, mac.cycle], [{ jobs: 1, minutes: 3 }, { jobs: 2, minutes: 4 }]);
    });
    test('job projection: duration derived, ceil minutes, finishedAt, os from runner', () => {
        const all = buildContractResponse([rec(jobs, [r('lin', { labels: ['Linux'] }), r('mac', { os: 'macOS' })])], NOW, { jobsLimit: 50 })
            .machines[0].recentJobs;
        const t1 = all.find((x) => x.id === 't1');
        assert.deepEqual([t1.durationSeconds, t1.minutes, t1.finishedAt, t1.os, t1.job], [271, 5, '2026-10-15T10:04:31Z', 'Linux', 'w']);
        assert.equal(all.find((x) => x.id === 't2').os, 'macOS');
        assert.equal(all.find((x) => x.id === 'gone').os, null, 'unknown OS stays null (absent != guessed)');
    });
    test('URL split: a job-level runUrl becomes runUrl (run) + jobUrl (job)', () => {
        const o = buildContractResponse([rec([j('u', 'lin', '2026-10-15T10:00:00Z', '2026-10-15T10:01:00Z',
            { runUrl: 'https://github.com/o/r/actions/runs/9/attempts/2/job/7' })], [r('lin')])], NOW).machines[0].recentJobs[0];
        assert.equal(o.runUrl, 'https://github.com/o/r/actions/runs/9/attempts/2');
        assert.equal(o.jobUrl, 'https://github.com/o/r/actions/runs/9/attempts/2/job/7');
    });
    test('vm state maps to Lima-style status; unknown OS derivation', () => {
        assert.equal(out.machines[0].vm.status, 'Broken');
        assert.equal(out.machines[0].vm.uptimeSeconds, null);
        assert.equal(out.machines[0].runners[0].os, 'Linux', 'derived from labels');
    });
    test('generatedAt is the injected clock; no machines -> summary null', () => {
        assert.equal(out.generatedAt, NOW.toISOString());
        assert.equal(buildContractResponse([], NOW).summary, null);
    });
});
