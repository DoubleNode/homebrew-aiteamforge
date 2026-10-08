//
//  xaca-1444-ci-queue-ui-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1444-003 / -011 -- jsdom render tests for the CI queue view, queue-age
 * summary and no-capacity banner (public/shared/js/lcars-ci-queue.js).
 *
 * Loads the REAL shipped module. A missing file FAILS (loadImpl throws); it is
 * never skipped. Data comes from the wave-1 /api/ci-pool fixtures plus a
 * minimal assignment sample shaped like ci-dispatch-assignments view().
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const QUEUE_JS = path.join(__dirname, '..', 'public', 'shared', 'js', 'lcars-ci-queue.js');
const QUEUE_CSS = path.join(__dirname, '..', 'public', 'shared', 'css', 'lcars-ci-queue.css');
const FIXTURE_DIR = path.join(__dirname, 'fixtures');

function fixture(name) {
    return JSON.parse(fs.readFileSync(path.join(FIXTURE_DIR, 'xaca-1444-ci-pool-' + name + '.json'), 'utf8'));
}

function loadImpl() {
    if (!fs.existsSync(QUEUE_JS)) throw new Error('MISSING IMPLEMENTATION: ' + QUEUE_JS);
    const dom = new JSDOM('<!doctype html><html><body><div id="cicd-queue"></div></body></html>',
        { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(fs.readFileSync(QUEUE_JS, 'utf8'));
    const api = dom.window.LCARSCIQueue;
    assert.ok(api && typeof api.render === 'function', 'window.LCARSCIQueue.render must be exposed');
    const el = dom.window.document.getElementById('cicd-queue');
    return {
        window: dom.window, document: dom.window.document, el,
        render: (body) => api.render(body, el, { document: dom.window.document, now: Date.parse('2026-10-07T18:02:10.000Z') }),
    };
}

const norm = (n) => (n.textContent || '').replace(/\s+/g, ' ').trim();
const rows = (env) => Array.from(env.el.querySelectorAll('tbody tr'));
const banner = (env) => env.el.querySelector('[data-ciq-banner]');
const seq = (env) => parseInt(banner(env).getAttribute('data-ciq-announce-seq'), 10);

function mkJob(id, over) {
    return Object.assign({
        key: 'DoubleNode/dev-team#' + id + '#1', repo: 'DoubleNode/dev-team', jobId: id, name: 'unit-' + id,
        jobClass: 'short', waitingMs: 95000, noCapacityMs: 0,
    }, over || {});
}
function mkAssign(jobId, machine, over) {
    return Object.assign({
        id: 'a' + jobId, machine, repo: 'DoubleNode/dev-team', state: 'running',
        intendedJob: { id: jobId, name: 'unit-' + jobId, runId: 9 }, boundJob: null,
    }, over || {});
}
function base(over) {
    return Object.assign({
        serverTime: '2026-10-07T18:02:10.000Z', dispatcherEnabled: true, queue: [], assignments: [],
        noCapacity: { active: false, since: null, queuedCount: 0, oldestQueuedAt: null },
        queueAge: [], queueAgeThresholdSec: 900, alerts: [],
    }, over || {});
}

test('implementation and stylesheet exist (vacuous-green guard)', () => {
    assert.ok(fs.existsSync(QUEUE_JS), 'lcars-ci-queue.js missing');
    assert.ok(fs.existsSync(QUEUE_CSS), 'lcars-ci-queue.css missing');
    assert.ok(!/#[0-9a-fA-F]{3,8}\b/.test(fs.readFileSync(QUEUE_CSS, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')), 'css must use tokens, not raw hex');
    assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML|document\.write/.test(fs.readFileSync(QUEUE_JS, 'utf8').replace(/\/\/.*$/gm, '')), 'no HTML string sinks');
});

test('null / missing body renders nothing and does not throw', () => {
    const env = loadImpl();
    env.render(null);
    env.render(undefined);
    assert.equal(env.el.children.length, 0);
});

test('row per queued job, with machine from assignments or the text "waiting"', () => {
    const env = loadImpl();
    env.render(base({
        queue: [mkJob(1), mkJob(2), mkJob(3)],
        assignments: [
            mkAssign(1, 'm1mini'),
            mkAssign(2, 'm4mini', { state: 'expired' }),                       // terminal: ignored
            mkAssign(3, 'm2mini', { intendedJob: null, boundJob: { id: 3, name: 'x', runId: 1 } }),
        ],
    }));
    const r = rows(env);
    assert.equal(r.length, 3);
    const cells = (tr) => Array.from(tr.children).map(norm);
    assert.deepEqual(cells(r[0]).filter((_, i) => i !== 4), ['DoubleNode/dev-team', 'unit-1', '—', 'queued', 'm1mini']);
    assert.equal(cells(r[1])[5], 'waiting');
    assert.equal(cells(r[2])[5], 'm2mini');
    assert.equal(cells(r[0])[4], 'waiting 1 min');
    const table = env.el.querySelector('table');
    assert.ok(table.querySelector('caption'));
    const ths = Array.from(table.querySelectorAll('th'));
    assert.equal(ths.length, 6);
    assert.deepEqual(ths.map(norm), ['Repo', 'Workflow / job', 'Branch', 'Status', 'Waiting / running for', 'Machine']);
    assert.ok(ths.every((t) => t.getAttribute('scope') === 'col'));
    assert.equal(env.el.querySelector('[data-ciq-scroll]').getAttribute('tabindex'), '0');
    assert.equal(env.el.querySelector('[data-ciq-empty]').hidden, true);
});

test('empty queue shows "No queued or running jobs" and no banner', () => {
    const env = loadImpl();
    env.render(base());
    assert.equal(rows(env).length, 0);
    const empty = env.el.querySelector('[data-ciq-empty]');
    assert.equal(empty.hidden, false);
    assert.equal(norm(empty), 'No queued or running jobs');
    assert.equal(banner(env).hidden, true);
    assert.equal(seq(env), 0);
});

test('no-capacity fixture: banner, 44 queued, queue-age group flagged over threshold', () => {
    const env = loadImpl();
    const body = fixture('no-capacity');
    env.render(body);
    assert.equal(rows(env).length, 44);
    const b = banner(env);
    assert.equal(b.hidden, false);
    assert.equal(b.getAttribute('role'), 'status');
    assert.equal(b.getAttribute('aria-live'), 'polite');
    assert.equal(b.getAttribute('data-ciq-kind'), 'both');
    const text = norm(b);
    assert.match(text, /waiting/i);
    assert.match(text, /44 queued/);
    assert.match(text, /since 17:43 UTC/);
    const g = env.el.querySelector('[data-ciq-group="arm64,fleet-pool,m1mini,macos,self-hosted"]');
    assert.ok(g, 'queue-age group rendered');
    assert.equal(g.getAttribute('data-ciq-over'), '1');
    const gt = norm(g);
    assert.match(gt, /44 queued/);
    assert.match(gt, /oldest 34 min/);
    assert.match(gt, /▲ over the 15 min threshold/); // glyph + text, not colour alone
});

test('age-only case (machines busy): banner says waiting too long, not "no machine"', () => {
    const env = loadImpl();
    env.render(base({
        queue: [mkJob(1, { waitingMs: 1920000 }), mkJob(2)],
        assignments: [mkAssign(2, 'm1mini')],
        noCapacity: { active: true, since: '2026-10-07T17:45:00.000Z', queuedCount: 1, oldestQueuedAt: '2026-10-07T17:30:00.000Z' },
        queueAge: [{ labels: 'fleet-pool,m1mini', host: 'm1mini', depth: 2, oldestQueuedAt: '2026-10-07T17:30:00.000Z', oldestWaitSec: 1920, overThreshold: true }],
    }));
    const b = banner(env);
    assert.equal(b.getAttribute('data-ciq-kind'), 'age');
    assert.match(norm(b.querySelector('[data-ciq-headline]')), /waiting too long/i);
    assert.doesNotMatch(norm(b.querySelector('[data-ciq-headline]')), /no CI machine/i);
});

test('no-machine case (no aged group) distinguished from age case', () => {
    const env = loadImpl();
    env.render(base({
        queue: [mkJob(1, { noCapacityMs: 130000 })],
        noCapacity: { active: true, since: '2026-10-07T18:00:00.000Z', queuedCount: 1, oldestQueuedAt: '2026-10-07T17:59:00.000Z' },
    }));
    assert.equal(banner(env).getAttribute('data-ciq-kind'), 'nomachine');
    assert.match(norm(banner(env).querySelector('[data-ciq-headline]')), /no CI machine can take them/);
});

test('banner announces once across identical renders, again on flip', () => {
    const env = loadImpl();
    const active = fixture('no-capacity');
    env.render(active);
    assert.equal(seq(env), 1);
    const headNode = banner(env).querySelector('[data-ciq-headline]');
    env.render(active);
    env.render(JSON.parse(JSON.stringify(active)));
    assert.equal(seq(env), 1, 'identical polls must not re-announce');
    assert.equal(banner(env).querySelector('[data-ciq-headline]'), headNode);
    // count changes alone do not touch the announced headline
    const more = JSON.parse(JSON.stringify(active));
    more.noCapacity.queuedCount = 50;
    env.render(more);
    assert.equal(seq(env), 1);
    assert.match(norm(banner(env)), /50 queued/);
    assert.equal(banner(env).querySelector('[data-ciq-detail]').getAttribute('aria-live'), 'off');
    // flip to clear, then back
    env.render(base());
    assert.equal(seq(env), 2);
    assert.equal(banner(env).hidden, true);
    assert.equal(norm(banner(env).querySelector('[data-ciq-headline]')), '');
    env.render(active);
    assert.equal(seq(env), 3);
});

test('hostile strings create no elements and no handlers; non-github URL not linked', () => {
    const env = loadImpl();
    const evil = '<img src=x onerror="window.__pwned=1"><script>window.__pwned=1</script>';
    env.render(base({
        queue: [
            mkJob(1, { repo: evil, name: evil, branch: evil, url: 'javascript:window.__pwned=1' }),
            mkJob(2, { name: 'ok', url: 'https://evil.example.com/x' }),
            mkJob(3, { name: 'gh', url: 'https://github.com/DoubleNode/dev-team/actions/runs/1/job/3' }),
        ],
        assignments: [mkAssign(1, evil)],
        noCapacity: { active: true, since: evil, queuedCount: 3, oldestQueuedAt: null },
        queueAge: [{ labels: evil, host: evil, depth: 3, oldestWaitSec: 2000, overThreshold: true }],
    }));
    assert.equal(env.el.querySelectorAll('img, script, iframe, svg').length, 0);
    assert.equal(env.el.querySelectorAll('[onerror], [onclick], [onload]').length, 0);
    assert.equal(env.window.__pwned, undefined);
    const links = Array.from(env.el.querySelectorAll('a'));
    assert.equal(links.length, 1, 'only the github.com URL is linked');
    assert.equal(links[0].getAttribute('href'), 'https://github.com/DoubleNode/dev-team/actions/runs/1/job/3');
    assert.equal(links[0].getAttribute('rel'), 'noopener noreferrer');
    assert.ok(norm(rows(env)[0]).includes('<img'), 'hostile text shown literally');
});

test('re-render preserves focus and scroll, patches rows in place, no duplicates', () => {
    const env = loadImpl();
    const gh = 'https://github.com/DoubleNode/dev-team/actions/runs/1/job/';
    const body = base({ queue: [mkJob(1, { url: gh + '1' }), mkJob(2, { url: gh + '2' }), mkJob(3, { url: gh + '3' })] });
    env.render(body);
    const scroll = env.el.querySelector('[data-ciq-scroll]');
    scroll.scrollLeft = 37;
    const link2 = env.el.querySelector('tr[data-ciq-job="DoubleNode/dev-team#2"] a');
    link2.focus();
    assert.equal(env.document.activeElement, link2);
    const row2 = link2.closest('tr');

    const next = JSON.parse(JSON.stringify(body));
    next.queue[1].waitingMs = 125000;
    next.assignments = [mkAssign(2, 'm1mini')];
    env.render(next);
    env.render(next);

    assert.equal(rows(env).length, 3);
    assert.equal(env.el.querySelector('[data-ciq-scroll]'), scroll, 'scroll container kept');
    assert.equal(scroll.scrollLeft, 37);
    assert.equal(env.document.activeElement, link2, 'focus kept');
    assert.equal(link2.closest('tr'), row2, 'row node reused');
    assert.equal(norm(row2.children[4]), 'waiting 2 min');
    assert.equal(norm(row2.children[5]), 'm1mini');

    // a job leaving the queue removes only its row
    next.queue.shift();
    env.render(next);
    assert.equal(rows(env).length, 2);
    assert.equal(env.document.activeElement, link2);
});

test('null fields render an em dash with aria-label "not reported", never 0', () => {
    const env = loadImpl();
    env.render(base({
        queue: [{ key: 'k1', repo: null, jobId: 1, name: null, waitingMs: null, noCapacityMs: null }],
        noCapacity: { active: true, since: null, queuedCount: null, oldestQueuedAt: null },
        queueAge: [{ labels: 'a,b', host: null, depth: null, oldestWaitSec: null, overThreshold: false }],
    }));
    const r = rows(env)[0];
    for (const i of [0, 1, 2, 4]) {
        const c = r.children[i];
        assert.equal(norm(c), '—', 'cell ' + i);
        assert.equal(c.firstElementChild.getAttribute('aria-label'), 'not reported');
    }
    assert.ok(!/(^|\s)0(\s|$)/.test(norm(env.el.querySelector('[data-ciq-age]'))), 'no fabricated zero in queue age');
    assert.match(norm(banner(env)), /since —/);
    assert.ok(!/ 0 queued/.test(norm(banner(env))));
});

test('draining fixture renders without error', () => {
    const env = loadImpl();
    env.render(fixture('draining'));
    env.render(fixture('mixed'));
    assert.equal(env.el.querySelectorAll('[data-ciq="root"]').length, 1);
});

// ---- running jobs (assignments with state 'running'), same table ----
const RUN_URL = 'https://github.com/DoubleNode/dev-team/actions/runs/9/job/7';
function mkRunning(jobId, machine, over) {
    return mkAssign(jobId, machine, Object.assign({
        boundAt: '2026-10-07T17:50:10.000Z',
        boundJob: { id: jobId, name: 'unit-' + jobId, runId: 9, branch: 'feature/x', workflow: 'CI', url: RUN_URL },
    }, over || {}));
}

test('running assignment renders a row with machine, "running" status and a labelled duration', () => {
    const env = loadImpl();
    env.render(base({ queue: [mkJob(1)], assignments: [mkRunning(7, 'm4mini')] }));
    const r = rows(env);
    assert.equal(r.length, 2);
    const run = r.find((tr) => tr.getAttribute('data-ciq-status') === 'running');
    const c = Array.from(run.children).map(norm);
    assert.deepEqual(c, ['DoubleNode/dev-team', 'unit-7', 'feature/x', 'running', 'running for 12 min', 'm4mini']);
    assert.equal(run.children[1].querySelector('a').getAttribute('href'), RUN_URL);
    assert.equal(run.getAttribute('data-ciq-machine'), 'm4mini');
    assert.equal(r.find((tr) => tr.getAttribute('data-ciq-status') === 'queued').children[3].textContent, 'queued');
    // pending / terminal assignments never become rows
    env.render(base({ assignments: [mkAssign(8, 'm1mini', { state: 'started' }), mkRunning(9, 'm1mini', { state: 'completed' })] }));
    assert.equal(rows(env).length, 0);
    assert.equal(env.el.querySelector('[data-ciq-empty]').hidden, false);
});

test('a job moving queued -> running reuses its row (same node), no duplicate', () => {
    const env = loadImpl();
    env.render(base({ queue: [mkJob(7)], assignments: [mkAssign(7, 'm4mini', { state: 'started' })] }));
    const before = rows(env);
    assert.equal(before.length, 1);
    assert.equal(before[0].getAttribute('data-ciq-status'), 'queued');
    env.render(base({ queue: [], assignments: [mkRunning(7, 'm4mini')] }));
    const mid = rows(env);
    assert.equal(mid.length, 1);
    assert.equal(mid[0], before[0], 'same row node');
    assert.equal(mid[0].getAttribute('data-ciq-status'), 'running');
    assert.equal(norm(mid[0].children[3]), 'running');
    // transient overlap (queue still lists it while the assignment is running): one row, running wins
    env.render(base({ queue: [mkJob(7)], assignments: [mkRunning(7, 'm4mini')] }));
    assert.equal(rows(env).length, 1);
    assert.equal(rows(env)[0], before[0]);
    assert.equal(rows(env)[0].getAttribute('data-ciq-status'), 'running');
});

test('hostile strings in boundJob create no elements and no unsafe links', () => {
    const env = loadImpl();
    const evil = '<img src=x onerror=alert(1)><script>alert(2)</script>';
    env.render(base({ assignments: [mkRunning(7, evil, {
        repo: 'DoubleNode/dev-team',
        boundJob: { id: 7, name: evil, runId: 9, branch: evil, workflow: evil, url: 'javascript:alert(3)' },
    })] }));
    assert.equal(rows(env).length, 1);
    assert.equal(env.el.querySelectorAll('img, script, iframe').length, 0);
    assert.equal(env.el.querySelectorAll('a').length, 0, 'non-github url is not linked');
    assert.equal(norm(rows(env)[0].children[1]), evil);
    assert.equal(norm(rows(env)[0].children[5]), evil);
    env.render(base({ assignments: [mkRunning(7, 'm1', { boundJob: { id: 7, name: 'n', url: 'https://github.com.evil.example/x' } })] }));
    assert.equal(env.el.querySelectorAll('a').length, 0, 'lookalike host is not linked (prefix is https://github.com/ exactly)');
});

// XACA-1444-005 checklist gap: an old payload without noCapacity / queueAge renders as before (no banner, no throw).
test('legacy v1 body (no noCapacity / queueAge / queueAgeThresholdSec) renders the queue and no banner', () => {
    const env = loadImpl();
    const legacy = base({ queue: [mkJob(1), mkJob(2)] });
    for (const k of ['noCapacity', 'queueAge', 'queueAgeThresholdSec']) delete legacy[k];
    env.render(legacy);
    assert.equal(rows(env).length, 2);
    assert.equal(banner(env).hidden, true, 'banner stays hidden without the derived fields');
});

// XACA-1444-005 REGRESSION (found in a real-browser render): the dashboard ships <div id="cicd-queue" hidden>, and the
// module never cleared `hidden`, so the queue table and the no-capacity / queue-age banners were invisible in the
// real page while every jsdom test (which used a container without the attribute) stayed green.
test('the container exactly as the dashboard ships it (hidden) becomes visible on a valid body', () => {
    const html = fs.readFileSync(path.join(__dirname, '..', 'public', 'lcars', 'lcars-dashboard.html'), 'utf8');
    const m = html.match(/<div id="cicd-queue"([^>]*)><\/div>/);
    assert.ok(m, 'dashboard has the cicd-queue container');
    assert.match(m[1], /\bhidden\b/, 'premise: the shipped container starts hidden');
    const dom = new JSDOM('<!doctype html><html><body><div id="cicd-queue"' + m[1] + '></div></body></html>', { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(fs.readFileSync(QUEUE_JS, 'utf8'));
    const el = dom.window.document.getElementById('cicd-queue');
    assert.equal(el.hidden, true);
    dom.window.LCARSCIQueue.render(base({ queue: [mkJob(1)], noCapacity: { active: true, since: '2026-10-07T18:00:00.000Z', queuedCount: 1, oldestQueuedAt: null } }), el, { document: dom.window.document });
    assert.equal(el.hidden, false, 'a valid body must show the container');
    assert.equal(el.querySelectorAll('tbody tr').length, 1);
});
