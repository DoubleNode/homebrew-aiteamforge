//
//  xaca-1468-attribution.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1468 -- job attribution (TICKET / TEAM / AGENT) on the CI/CD tab.
 *
 * describe('UI')     -- subitem 011: jsdom render of the REAL lcars-cicd.js.
 * describe('Server') -- subitem 004: ci-runners-routes.js validate + serve.
 */
const { describe, test, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const CICD_JS = path.join(__dirname, '..', 'public', 'lcars', 'js', 'lcars-cicd.js');

function loadImpl() {
    if (!fs.existsSync(CICD_JS)) throw new Error('MISSING IMPLEMENTATION: ' + CICD_JS);
    const dom = new JSDOM('<!doctype html><html><body><div id="cicd-content"></div></body></html>',
        { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(fs.readFileSync(CICD_JS, 'utf8'));
    const api = dom.window.LCARSCICD;
    assert.ok(api, 'window.LCARSCICD must be exposed');
    return { api, el: dom.window.document.getElementById('cicd-content') };
}

function mkJob(id, over) {
    return Object.assign({
        id: id, runner: 'r1', workflow: 'CI', job: 'test', branch: 'feature/x',
        startedAt: '2026-10-02T16:00:00Z', durationSeconds: 60, minutes: 1, result: 'success'
    }, over || {});
}

function render(jobs) {
    const env = loadImpl();
    env.api.render({
        schemaVersion: 1, generatedAt: '2026-10-02T17:00:00Z',
        machines: [{
            machine: 'm', lastReportAt: '2026-10-02T16:59:30Z',
            vm: { name: 'v', status: 'Running', uptimeSeconds: 1 },
            runners: [{ name: 'r', os: 'Linux', service: 'online', busy: false, currentJob: null }],
            recentJobs: jobs
        }]
    }, env.el);
    return env;
}

const norm = (n) => (n.textContent || '').replace(/\s+/g, ' ').trim();
const row = (env, id) => env.el.querySelector('[data-cicd-job="' + id + '"]');
const attr = (env, id, k) => row(env, id).querySelector('.cicd-attr-' + k);
// Visible text of a cell, minus the sr-only "not reported" suffix of the dash.
const visible = (td) => {
    const c = td.cloneNode(true);
    c.querySelectorAll('.cicd-sr-only').forEach(function (n) { n.remove(); });
    return norm(c);
};

describe('UI', () => {
    test('attribution values render in TICKET / TEAM / AGENT cells', () => {
        const env = render([mkJob('1', { attribution: { item: 'XACA-1468', team: 'academy', agent: 'academy:chancellor (Captain Nahla Ake)' } })]);
        assert.equal(visible(attr(env, '1', 'item')), 'XACA-1468');
        assert.equal(visible(attr(env, '1', 'team')), 'academy');
        assert.equal(visible(attr(env, '1', 'agent')), 'academy:chancellor (Captain Nahla Ake)');
    });

    test('column headers: TICKET, TEAM, AGENT in order after BRANCH; row cell count matches header count', () => {
        const env = render([mkJob('1', { attribution: { item: 'XACA-1' + '468' } })]);
        const heads = Array.from(env.el.querySelectorAll('.cicd-jobs th')).map(norm);
        const i = heads.indexOf('BRANCH');
        assert.deepEqual(heads.slice(i, i + 4), ['BRANCH', 'TICKET', 'TEAM', 'AGENT']);
        assert.equal(row(env, '1').children.length, heads.length);
    });

    test('the sr-only caption explains the attribution columns once; AGENT header is plain', () => {
        const env = render([mkJob('1')]);
        const caption = env.el.querySelector('.cicd-jobs caption');
        assert.ok(caption, 'caption exists');
        assert.ok(caption.classList.contains('cicd-sr-only'), 'caption is sr-only');
        assert.match(norm(caption), /Ticket, team and agent come from the commit's Kanban trailers/i);
        assert.match(norm(caption), /agent is the one that made the commit/i);
        const ths = Array.from(env.el.querySelectorAll('.cicd-jobs th'));
        ['TICKET', 'TEAM', 'AGENT'].forEach((name) => {
            const th = ths.find((t) => norm(t) === name);
            assert.ok(th, name + ' header exists');
            assert.equal(th.getAttribute('title'), null, name + ' has no title');
            assert.equal(th.getAttribute('aria-label'), null, name + ' has no aria-label');
        });
    });

    test('AGENT text sits in a .cicd-attr-trunc span whose title is the escaped full value', () => {
        const long = 'academy:chancellor (Captain Nahla Ake of the Federation Academy Engineering Lab)';
        const env = render([mkJob('1', { attribution: { item: 'XACA-1468', team: 'academy', agent: long } })]);
        const span = attr(env, '1', 'agent').querySelector('span.cicd-attr-trunc');
        assert.ok(span, 'truncation span exists');
        assert.equal(span.getAttribute('title'), long);
        assert.equal(norm(span), long);
        // ticket and team cells carry no truncation span
        assert.equal(attr(env, '1', 'item').querySelector('.cicd-attr-trunc'), null);
        // hostile value: the title attribute is escaped, not an injection point
        const evil = '"><img src=x onerror=alert(1)>';
        const env2 = render([mkJob('2', { attribution: { agent: evil } })]);
        const s2 = attr(env2, '2', 'agent').querySelector('span.cicd-attr-trunc');
        assert.equal(s2.getAttribute('title'), evil);
        assert.equal(env2.el.querySelectorAll('img').length, 0);
        assert.equal(env2.el.querySelectorAll('[onerror]').length, 0);
        // unreported agent: dash only, no span
        const env3 = render([mkJob('3')]);
        assert.equal(attr(env3, '3', 'agent').querySelector('.cicd-attr-trunc'), null);
    });

    test('stylesheet caps the truncation span, not the table cell', () => {
        const css = fs.readFileSync(path.join(__dirname, '..', 'public', 'lcars', 'css', 'lcars-dashboards.css'), 'utf8');
        const m = css.match(/\.cicd-jobs \.cicd-attr-trunc\s*\{([^}]*)\}/);
        assert.ok(m, '.cicd-attr-trunc rule exists');
        ['display:\\s*inline-block', 'max-width:\\s*240px', 'overflow:\\s*hidden', 'text-overflow:\\s*ellipsis', 'white-space:\\s*nowrap', 'vertical-align:\\s*bottom']
            .forEach((p) => assert.match(m[1], new RegExp(p)));
        const cell = css.match(/\.cicd-jobs \.cicd-attr-agent\s*\{([^}]*)\}/);
        assert.ok(cell && !/max-width/.test(cell[1]), 'no max-width on the table cell');
    });

    test('hostile values render as text, never markup (every column)', () => {
        const evil = '<img src=x onerror=alert(1)>';
        const env = render([mkJob('1', { attribution: { item: evil, team: evil, agent: '"><script>alert(2)</script>' } })]);
        assert.equal(env.el.querySelectorAll('img').length, 0);
        assert.equal(env.el.querySelectorAll('script').length, 0);
        assert.equal(env.el.querySelectorAll('[onerror]').length, 0);
        assert.equal(visible(attr(env, '1', 'item')), evil);
        assert.equal(visible(attr(env, '1', 'team')), evil);
        assert.equal(visible(attr(env, '1', 'agent')), '"><script>alert(2)</script>');
    });

    test('absent / null / non-object / partial attribution show the em dash', () => {
        const env = render([
            mkJob('none'),
            mkJob('null', { attribution: null }),
            mkJob('str', { attribution: 'XACA-1468' }),
            mkJob('arr', { attribution: ['XACA-1468'] }),
            mkJob('empty', { attribution: {} }),
            mkJob('partial', { attribution: { item: 'XACA-1468', team: null, agent: '' } }),
            mkJob('objval', { attribution: { item: { a: 1 }, team: ['x'], agent: true } })
        ]);
        ['none', 'null', 'str', 'arr', 'empty'].forEach((id) => {
            ['item', 'team', 'agent'].forEach((k) => assert.equal(visible(attr(env, id, k)), '—', id + '/' + k));
        });
        assert.equal(visible(attr(env, 'partial', 'item')), 'XACA-1468');
        assert.equal(visible(attr(env, 'partial', 'team')), '—');
        assert.equal(visible(attr(env, 'partial', 'agent')), '—');
        ['item', 'team', 'agent'].forEach((k) => assert.equal(visible(attr(env, 'objval', k)), '—', 'objval/' + k));
    });

    test('legacy rows (no attribution field) still render every original column', () => {
        const env = render([mkJob('legacy')]);
        const r = row(env, 'legacy');
        assert.ok(r, 'row rendered');
        const text = norm(r);
        ['r1', 'CI / test', 'feature/x', 'success'].forEach((t) => assert.ok(text.includes(t), 'has ' + t + ': ' + text));
    });

    test('empty jobs list placeholder spans the full table width', () => {
        const env = render([]);
        const heads = env.el.querySelectorAll('.cicd-jobs th').length;
        const td = env.el.querySelector('.cicd-jobs tbody td[colspan]');
        assert.ok(td);
        assert.equal(Number(td.getAttribute('colspan')), heads);
    });
});

// ===========================================================================
// Server (subitem 004): ci-runners-routes.js validates, drops-not-rejects, serves.
// ===========================================================================
const os = require('node:os');
const request = require('./helpers/loopback-request');
const express = require('express');

describe('Server', () => {
    // Same auth harness as xaca-1387-005: fleet token for GET, per-host telemetry key for the push.
    const TOKEN = 'xaca1468-fake-fleet-token-0001';
    const SAVED = process.env.FLEET_AUTH_TOKEN;
    process.env.FLEET_AUTH_TOKEN = TOKEN;
    after(() => { if (SAVED === undefined) delete process.env.FLEET_AUTH_TOKEN; else process.env.FLEET_AUTH_TOKEN = SAVED; });
    const { registerCiRunnersRoutes, validatePush } = require('../lib/ci-runners-routes');
    const { createPoolStore } = require('../lib/ci-pool-store');

    const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1468-srv-'));
    let seq = 0;
    process.on('exit', () => { try { fs.rmSync(TMP, { recursive: true, force: true }); } catch (e) { /* best effort */ } });

    function mount() {
        const app = express();
        app.use(express.json({ limit: '10mb' }));
        const log = console.log; console.log = () => {};
        try {
            const dir = path.join(TMP, 's' + (++seq));
            const pool = createPoolStore({ file: path.join(dir, 'ci-pool.json') });
            const store = registerCiRunnersRoutes(app, { file: path.join(dir, 'ci-runners.json'), poolStore: pool });
            const cred = 'fct_' + 'k'.repeat(43);
            pool.upsertMachine('m1mini', {});
            assert.ok(pool.setTelemetrySecret('m1mini', cred).ok);
            return { app, store, cred };
        } finally { console.log = log; }
    }

    const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
    function pushBody(jobs) {
        const now = Date.now();
        return {
            schema_version: 1, machine: 'm1mini', reportedAt: iso(now), reporterVersion: '1.1.0',
            host: { uptimeSeconds: 100 }, vm: null,
            runners: [{ name: 'm1mini-macos-1', serviceState: 'up', labels: ['self-hosted', 'macOS'], currentJob: null }],
            jobs: jobs
        };
    }
    function sjob(id, over) {
        const now = Date.now();
        return Object.assign({
            id: id, runner: 'm1mini-macos-1', workflow: 'CI', jobName: 'build', repo: 'DoubleNode/dev-team',
            runUrl: 'https://github.com/DoubleNode/dev-team/actions/runs/123', startedAt: iso(now - 600000),
            endedAt: iso(now - 300000), result: 'success', minutes: 5, durationSeconds: 300
        }, over || {});
    }
    // Real POST through the route, then the real GET. Returns { post, jobs }.
    async function roundTrip(jobs) {
        const { app, cred } = mount();
        const post = await request(app).post('/api/ci-runners-push').set('Authorization', 'Bearer ' + cred).send(pushBody(jobs));
        const get = await request(app).get('/api/ci-runners').set('Authorization', 'Bearer ' + TOKEN);
        assert.equal(get.status, 200);
        const m = get.body.machines.find((x) => x.machine === 'm1mini');
        return { post: post, jobs: m ? m.recentJobs : [] };
    }
    const byId = (jobs, id) => jobs.find((j) => j.id === id);
    const FULL = { item: 'XACA-1468', team: 'academy', agent: 'academy:chancellor (Captain Nahla Ake)' };

    test('a valid attribution is served on recentJobs[], exactly', async () => {
        const r = await roundTrip([sjob('j1', { attribution: FULL })]);
        assert.equal(r.post.status, 200);
        assert.deepEqual(byId(r.jobs, 'j1').attribution, FULL);
    });

    test('a partial attribution (subset of keys) is kept as-is', async () => {
        const r = await roundTrip([
            sjob('i', { attribution: { item: 'XACA-1468' } }),
            sjob('t', { attribution: { team: 'academy' } }),
            sjob('a', { attribution: { agent: 'someone' } })
        ]);
        assert.deepEqual(byId(r.jobs, 'i').attribution, { item: 'XACA-1468' });
        assert.deepEqual(byId(r.jobs, 't').attribution, { team: 'academy' });
        assert.deepEqual(byId(r.jobs, 'a').attribution, { agent: 'someone' });
    });

    test('no attribution -> the key is absent from the served job', async () => {
        const r = await roundTrip([sjob('plain'), sjob('nul', { attribution: null })]);
        assert.ok(byId(r.jobs, 'plain'));
        assert.ok(!('attribution' in byId(r.jobs, 'plain')));
        assert.ok(byId(r.jobs, 'nul'));
        assert.ok(!('attribution' in byId(r.jobs, 'nul')));
    });

    test('an invalid sub-key drops the WHOLE field; the job is kept; the push is not rejected', async () => {
        const bad = [
            { item: 'xaca-1468', team: 'academy' },                 // item lowercase
            { item: 'XACA-1468', team: 'Academy' },                 // team uppercase
            { item: 'XACA-1468', team: '-academy' },                // team leading dash
            { item: 'XACA-1468', agent: 'ok\nnewline' },            // control char
            { item: 'XACA-1468', agent: '' },                       // empty agent
            { item: 'XACA-1468', team: 'academy', extra: 'x' },     // unknown key
            { item: 'XACA-1468\n' },                                // trailing newline
            { item: 123 }, { team: ['academy'] }, { agent: { a: 1 } },
            {}, [], 'XACA-1468', 7, true
        ];
        const r = await roundTrip(bad.map((a, i) => sjob('b' + i, { attribution: a })));
        assert.equal(r.post.status, 200);
        assert.deepEqual(r.post.body.jobsRejected || [], []);
        for (let i = 0; i < bad.length; i++) {
            const j = byId(r.jobs, 'b' + i);
            assert.ok(j, 'job b' + i + ' must be kept');
            assert.ok(!('attribution' in j), 'attribution must be dropped for case ' + i + ': ' + JSON.stringify(bad[i]));
        }
    });

    test('a hostile agent string over 96 chars is dropped (97 drops, 96 keeps)', async () => {
        const r = await roundTrip([
            sjob('long', { attribution: { item: 'XACA-1468', agent: 'A'.repeat(97) } }),
            sjob('huge', { attribution: { agent: '<img src=x onerror=alert(1)>'.repeat(500) } }),
            sjob('edge', { attribution: { agent: 'B'.repeat(96) } })
        ]);
        assert.ok(byId(r.jobs, 'long') && !('attribution' in byId(r.jobs, 'long')));
        assert.ok(byId(r.jobs, 'huge') && !('attribution' in byId(r.jobs, 'huge')));
        assert.deepEqual(byId(r.jobs, 'edge').attribution, { agent: 'B'.repeat(96) });
    });

    test('validatePush: bad attribution keeps the job in jobs[] and out of jobsRejected', () => {
        const v = validatePush(pushBody([sjob('x', { attribution: { item: 'nope' } }), sjob('y', { attribution: FULL })]));
        assert.equal(v.jobsRejected.length, 0);
        assert.equal(v.jobs.length, 2);
        assert.ok(!('attribution' in v.jobs[0]));
        assert.deepEqual(v.jobs[1].attribution, FULL);
    });

    test('the served attribution is a copy holding only item/team/agent', async () => {
        const r = await roundTrip([sjob('c', { attribution: Object.assign({}, FULL) })]);
        assert.deepEqual(Object.keys(byId(r.jobs, 'c').attribution).sort(), ['agent', 'item', 'team']);
    });

    test('schemaVersion stays 1', async () => {
        const { app, cred } = mount();
        const p = await request(app).post('/api/ci-runners-push').set('Authorization', 'Bearer ' + cred).send(pushBody([sjob('j', { attribution: FULL })]));
        assert.equal(p.status, 200);
        const g = await request(app).get('/api/ci-runners').set('Authorization', 'Bearer ' + TOKEN);
        assert.equal(g.body.schemaVersion, 1);
    });
});
