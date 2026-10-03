//
//  xaca-1387-020-rollups.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1387-020 (design XACA-1427): summary.today / cycle and
 * runners[].today / cycle come from the persisted per-day rollups, NOT from
 * the MAX_JOBS_PER_MACHINE job list, and every job is counted EXACTLY ONCE.
 *
 * Table-driven over job counts around the cap (read from the module, never
 * hard-coded) x delivery scenarios (single pass, re-pushed x3, restart
 * between every push, re-send of ids already evicted from the list), plus
 * the OS multiplier table, month rollover, late arrival, re-send with a
 * different finishedAt, corrupt/missing rollup file, 13-month pruning,
 * ledger sealing, the per-day id bound, future-dated jobs and machine
 * eviction.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const express = require('express');

const {
    createCiRunnerStore, createRollupStore, registerCiRunnersRoutes, validatePush, jobAccounting,
    MAX_JOBS_PER_MACHINE, MAX_JOBS_PER_PUSH, MAX_MACHINES, OFFLINE_THRESHOLD_MS, ROLLUP_FILE_NAME,
} = require('../lib/ci-runners-routes');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1387-020-'));
let seq = 0;
const newFile = () => path.join(TMP, `s${++seq}`, 'ci-runners.json');
const rollupPath = (file) => path.join(path.dirname(file), ROLLUP_FILE_NAME);
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

/** Run fn with console.log/error silenced (the store logs every load/drop). */
function quiet(fn) {
    const l = console.log; const e = console.error;
    console.log = () => {}; console.error = () => {};
    try { return fn(); } finally { console.log = l; console.error = e; }
}

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const RUNNERS = {
    lin: { name: 'm1mini-linux-1', serviceState: 'up', labels: ['self-hosted', 'Linux'], currentJob: null, os: 'Linux' },
    mac: { name: 'm1mini-macos-1', serviceState: 'up', labels: ['self-hosted', 'macOS'], currentJob: null, os: 'macOS' },
    unk: { name: 'runner-x', serviceState: 'up', labels: ['self-hosted'], currentJob: null },
};

/** A completed job ending at endMs, lasting durationSeconds. */
function job(id, runner, endMs, durationSeconds = 120) {
    return {
        id, runner, workflow: 'CI', jobName: 'build', repo: 'DoubleNode/dev-team', runUrl: null,
        startedAt: iso(endMs - durationSeconds * 1000), endedAt: iso(endMs), result: 'success',
        minutes: durationSeconds / 60, durationSeconds,
    };
}

function payload(machine, jobs, runners = [RUNNERS.lin, RUNNERS.mac, RUNNERS.unk]) {
    return validatePush({
        schema_version: 1, machine, reportedAt: '2026-10-20T12:00:00Z', reporterVersion: '1.0.0',
        host: { uptimeSeconds: 1 }, vm: null, runners, jobs,
    });
}

/** n jobs on one runner, 30 min apart, the newest ending at lastEndMs. Newest-first. */
function series(n, runner, lastEndMs, prefix = 'j', durationSeconds = 120) {
    return Array.from({ length: n }, (_, i) => job(`${prefix}-${i}`, runner, lastEndMs - i * 30 * 60 * 1000, durationSeconds));
}

/** Push jobs oldest-first in MAX_JOBS_PER_PUSH chunks; beforeEach(i) may swap the store (restart). */
function pushChunks(getStore, machine, jobs, beforeEach = () => {}) {
    const oldestFirst = jobs.slice().reverse();
    for (let i = 0, k = 0; i < oldestFirst.length; i += MAX_JOBS_PER_PUSH, k++) {
        beforeEach(k);
        getStore().applyPush(payload(machine, oldestFirst.slice(i, i + MAX_JOBS_PER_PUSH)));
    }
}

function openStore(file, clock) {
    const s = createCiRunnerStore(file, { clock });
    quiet(() => s.load());
    return s;
}

// ---------------------------------------------------------------------------
describe('A. over-cap totals x delivery scenarios (table-driven)', () => {
    const NOW = new Date('2026-10-20T12:00:00Z');
    const clock = () => NOW;
    // 30-minute spacing: 750 jobs span ~15.6 days, all inside October.
    const LAST_END = Date.parse('2026-10-17T00:00:00Z');
    const COUNTS = [MAX_JOBS_PER_MACHINE - 1, MAX_JOBS_PER_MACHINE, MAX_JOBS_PER_MACHINE + 1, Math.max(750, MAX_JOBS_PER_MACHINE + 250)];

    const SCENARIOS = {
        'single pass': (file, jobs) => {
            const s = openStore(file, clock);
            pushChunks(() => s, 'm1mini', jobs);
            return s;
        },
        'same window re-pushed x3': (file, jobs) => {
            const s = openStore(file, clock);
            for (let r = 0; r < 3; r++) pushChunks(() => s, 'm1mini', jobs);
            return s;
        },
        'restart (save + fresh store load) before every push': (file, jobs) => {
            let s = openStore(file, clock);
            pushChunks(() => s, 'm1mini', jobs, (k) => {
                if (k === 0) return;
                quiet(() => s.save());
                s = openStore(file, clock);
            });
            quiet(() => s.save());
            return openStore(file, clock);
        },
        're-send of ids already evicted from the job list (also after a restart)': (file, jobs) => {
            let s = openStore(file, clock);
            pushChunks(() => s, 'm1mini', jobs);
            const oldest = jobs.slice(-MAX_JOBS_PER_PUSH); // the oldest: evicted first when n > cap
            s.applyPush(payload('m1mini', oldest));
            quiet(() => s.save());
            s = openStore(file, clock);
            s.applyPush(payload('m1mini', oldest));
            return s;
        },
    };

    for (const n of COUNTS) {
        for (const [name, run] of Object.entries(SCENARIOS)) {
            test(`${n} jobs (cap ${MAX_JOBS_PER_MACHINE}) | ${name}`, () => {
                const file = newFile();
                const jobs = series(n, RUNNERS.lin.name, LAST_END);
                const s = run(file, jobs);
                const out = s.snapshot({ jobsLimit: 500 });
                assert.deepEqual(out.summary.cycle, {
                    jobs: n, minutes: 2 * n, hostedEquivalentMinutes: 2 * n, start: '2026-10-01', end: '2026-10-31',
                });
                assert.deepEqual(out.summary.today, { jobs: 0, minutes: 0, hostedEquivalentMinutes: 0 });
                const lin = out.machines[0].runners.find((r) => r.name === RUNNERS.lin.name);
                assert.deepEqual(lin.cycle, { jobs: n, minutes: 2 * n });
                // the job list is still capped; only the totals escape the cap
                assert.equal(s.machines.get('m1mini').jobs.length, Math.min(n, MAX_JOBS_PER_MACHINE));
            });
        }
    }

    test('the cap is really exercised (guards a vacuous table if the constant grows)', () => {
        assert.ok(COUNTS[COUNTS.length - 1] > MAX_JOBS_PER_MACHINE);
        assert.ok(COUNTS.some((n) => n < MAX_JOBS_PER_MACHINE));
    });

    test('totals match the recentJobs projection while under the cap (one minutes function)', () => {
        const s = openStore(newFile(), clock);
        const jobs = [61, 120, 121, 3599, 0].map((d, i) => job(`d${i}`, RUNNERS.mac.name, LAST_END - i * 60000, d));
        s.applyPush(payload('m1mini', jobs));
        const out = s.snapshot({ jobsLimit: 500 });
        const sum = out.machines[0].recentJobs.reduce((a, j) => a + j.minutes, 0);
        assert.equal(out.summary.cycle.minutes, sum);
        assert.equal(sum, 2 + 2 + 3 + 60 + 0);
        assert.equal(out.summary.cycle.hostedEquivalentMinutes, sum * 10);
        for (const j of jobs) assert.equal(jobAccounting(j, new Map()).minutes, Math.ceil(j.durationSeconds / 60));
    });
});

// ---------------------------------------------------------------------------
describe('B. hosted-equivalent multiplier (table-driven)', () => {
    const NOW = new Date('2026-10-20T12:00:00Z');
    const CASES = [
        { runner: RUNNERS.mac, mult: 10, os: 'macOS' },
        { runner: RUNNERS.lin, mult: 1, os: 'Linux' },
        { runner: RUNNERS.unk, mult: 1, os: null },
    ];
    for (const c of CASES) {
        test(`${c.os || 'unknown'} -> x${c.mult}`, () => {
            const s = openStore(newFile(), () => NOW);
            // 3 jobs of 61 s -> 2 billed minutes each, ending today
            const jobs = [0, 1, 2].map((i) => job(`${c.runner.name}-${i}`, c.runner.name, Date.parse('2026-10-20T11:00:00Z') - i * 60000, 61));
            s.applyPush(payload('m1mini', jobs, [c.runner]));
            const out = s.snapshot();
            assert.deepEqual(out.summary.today, { jobs: 3, minutes: 6, hostedEquivalentMinutes: 6 * c.mult });
            assert.equal(out.summary.cycle.hostedEquivalentMinutes, 6 * c.mult);
            assert.deepEqual(out.machines[0].runners[0].today, { jobs: 3, minutes: 6 });
            assert.equal(out.machines[0].runners[0].os, c.os);
        });
    }
    test('mixed: 1 macOS + 1 Linux + 1 unknown job', () => {
        const s = openStore(newFile(), () => NOW);
        const end = Date.parse('2026-10-20T11:00:00Z');
        s.applyPush(payload('m1mini', [job('a', RUNNERS.mac.name, end, 60), job('b', RUNNERS.lin.name, end, 60), job('c', RUNNERS.unk.name, end, 60)]));
        assert.deepEqual(s.snapshot().summary.today, { jobs: 3, minutes: 3, hostedEquivalentMinutes: 12 });
    });
});

// ---------------------------------------------------------------------------
describe('C. month rollover', () => {
    test('last day of M + first of M+1: cycle is only M+1, today correct, survives a restart', () => {
        const file = newFile();
        let now = new Date('2026-10-31T23:30:00Z');
        const clock = () => now;
        let s = openStore(file, clock);
        // more than the cap on Oct 31-ish so the old month is busy too
        const oct = series(MAX_JOBS_PER_MACHINE + 100, RUNNERS.mac.name, Date.parse('2026-10-31T23:00:00Z'), 'oct', 60)
            .filter((j) => j.endedAt.startsWith('2026-10'));
        pushChunks(() => s, 'm1mini', oct);
        assert.equal(s.snapshot().summary.cycle.jobs, oct.length);
        const octToday = oct.filter((j) => j.endedAt.startsWith('2026-10-31')).length;
        assert.equal(s.snapshot().summary.today.jobs, octToday);

        now = new Date('2026-11-01T06:00:00Z');
        const nov = [job('nov-0', RUNNERS.mac.name, Date.parse('2026-11-01T01:00:00Z'), 60), job('nov-1', RUNNERS.lin.name, Date.parse('2026-11-01T05:00:00Z'), 120)];
        s.applyPush(payload('m1mini', nov.concat(oct.slice(0, 10)))); // the reporter's window still carries Oct 31 jobs
        quiet(() => s.save());
        s = openStore(file, clock);
        const out = s.snapshot();
        assert.deepEqual(out.summary.cycle, { jobs: 2, minutes: 3, hostedEquivalentMinutes: 12, start: '2026-11-01', end: '2026-11-30' });
        assert.deepEqual(out.summary.today, { jobs: 2, minutes: 3, hostedEquivalentMinutes: 12 });
        const mac = out.machines[0].runners.find((r) => r.name === RUNNERS.mac.name);
        assert.deepEqual([mac.today, mac.cycle], [{ jobs: 1, minutes: 1 }, { jobs: 1, minutes: 1 }]);
        // October's bucket is retained (history), just not in this cycle
        assert.ok(s.rollups.toJSON().machines.m1mini['2026-10-31']);
    });
});

// ---------------------------------------------------------------------------
describe('D. late arrival + re-send with a different finishedAt', () => {
    const NOW = new Date('2026-10-20T12:00:00Z');
    test('a job pushed 15 days after it finished is counted in ITS day (cycle, not today)', () => {
        const s = openStore(newFile(), () => NOW);
        s.applyPush(payload('m1mini', [job('late', RUNNERS.lin.name, Date.parse('2026-10-05T10:00:00Z'))]));
        const out = s.snapshot();
        assert.equal(out.summary.cycle.jobs, 1);
        assert.equal(out.summary.today.jobs, 0);
        assert.equal(s.rollups.toJSON().machines.m1mini['2026-10-05'].jobs, 1);
    });
    test('first write wins: same id re-sent with a different finishedAt stays in its first day, counted once', () => {
        const file = newFile();
        let s = openStore(file, () => NOW);
        s.applyPush(payload('m1mini', [job('x', RUNNERS.lin.name, Date.parse('2026-10-19T10:00:00Z'), 120)]));
        s.applyPush(payload('m1mini', [job('x', RUNNERS.lin.name, Date.parse('2026-10-20T10:00:00Z'), 600)]));
        quiet(() => s.save());
        s = openStore(file, () => NOW);
        s.applyPush(payload('m1mini', [job('x', RUNNERS.lin.name, Date.parse('2026-10-20T11:00:00Z'), 900)]));
        const out = s.snapshot();
        assert.deepEqual(out.summary.cycle, { jobs: 1, minutes: 2, hostedEquivalentMinutes: 2, start: '2026-10-01', end: '2026-10-31' });
        assert.equal(out.summary.today.jobs, 0);
    });
    test('...also once the first version was evicted from the job list', () => {
        const s = openStore(newFile(), () => NOW);
        s.applyPush(payload('m1mini', [job('x', RUNNERS.lin.name, Date.parse('2026-10-02T10:00:00Z'))]));
        // MAX_JOBS_PER_MACHINE newer jobs push 'x' out of the list
        pushChunks(() => s, 'm1mini', series(MAX_JOBS_PER_MACHINE, RUNNERS.lin.name, Date.parse('2026-10-20T00:00:00Z'), 'n', 60)
            .map((j, i) => ({ ...j, endedAt: iso(Date.parse('2026-10-20T00:00:00Z') - i * 1000), startedAt: iso(Date.parse('2026-10-20T00:00:00Z') - i * 1000 - 60000) })));
        assert.ok(!s.machines.get('m1mini').jobs.some((j) => j.id === 'x'), 'precondition: x evicted');
        s.applyPush(payload('m1mini', [job('x', RUNNERS.lin.name, Date.parse('2026-10-20T11:00:00Z'))]));
        assert.equal(s.snapshot().summary.cycle.jobs, MAX_JOBS_PER_MACHINE + 1);
        assert.equal(s.rollups.toJSON().machines.m1mini['2026-10-02'].jobs, 1);
    });
});

// ---------------------------------------------------------------------------
describe('E. corrupt / missing rollup file -> rebuilt from stored jobs, GET never 500', () => {
    const NOW = new Date('2026-10-20T12:00:00Z');
    const seedFiles = (n) => {
        const file = newFile();
        const s = openStore(file, () => NOW);
        pushChunks(() => s, 'm1mini', series(n, RUNNERS.lin.name, Date.parse('2026-10-17T00:00:00Z')));
        quiet(() => s.save());
        return file;
    };
    const CORRUPTIONS = {
        'missing file (first deploy)': (rf) => fs.unlinkSync(rf),
        'truncated JSON': (rf) => fs.writeFileSync(rf, '{"schema_version":1,"machines":{'),
        'wrong schema_version': (rf) => fs.writeFileSync(rf, JSON.stringify({ schema_version: 99, machines: {} })),
        'machines not an object': (rf) => fs.writeFileSync(rf, JSON.stringify({ schema_version: 1, machines: [] })),
        'every bucket lies (jobs != ids.length)': (rf) => {
            const d = JSON.parse(fs.readFileSync(rf, 'utf8'));
            for (const b of Object.values(d.machines.m1mini)) b.jobs += 1000;
            fs.writeFileSync(rf, JSON.stringify(d));
        },
    };
    for (const [name, corrupt] of Object.entries(CORRUPTIONS)) {
        test(name, async () => {
            const n = MAX_JOBS_PER_MACHINE + 50;
            const file = seedFiles(n);
            corrupt(rollupPath(file));
            fs.writeFileSync(`${rollupPath(file)}.tmp-4242`, '{partial');
            const app = express();
            app.use(express.json());
            quiet(() => registerCiRunnersRoutes(app, { file, clock: () => NOW }));
            const g = await request(app).get('/api/ci-runners');
            assert.equal(g.status, 200);
            // history older than the job list is gone; the list's jobs are recounted, once
            assert.equal(g.body.summary.cycle.jobs, MAX_JOBS_PER_MACHINE);
            assert.equal(g.body.summary.cycle.minutes, 2 * MAX_JOBS_PER_MACHINE);
            assert.ok(!fs.existsSync(`${rollupPath(file)}.tmp-4242`), 'orphaned rollup temp swept');
        });
    }
    test('one bad bucket is dropped and only that day is rebuilt; good days keep over-cap history', () => {
        const n = MAX_JOBS_PER_MACHINE + 100;
        const file = seedFiles(n);
        const rf = rollupPath(file);
        const d = JSON.parse(fs.readFileSync(rf, 'utf8'));
        const days = Object.keys(d.machines.m1mini).sort();
        const newest = days[days.length - 1];
        const expectNewest = d.machines.m1mini[newest].jobs;
        d.machines.m1mini[newest].hostedEquivalentMinutes = -1;
        fs.writeFileSync(rf, JSON.stringify(d));
        const s = openStore(file, () => NOW);
        // the newest day is fully inside the job list, so its rebuild is exact
        assert.equal(s.rollups.toJSON().machines.m1mini[newest].jobs, expectNewest);
        assert.equal(s.snapshot().summary.cycle.jobs, n);
    });
});

// ---------------------------------------------------------------------------
describe('F. retention: 13-month prune, ledger sealing', () => {
    test('buckets older than 13 calendar months are pruned; previous cycle and older-but-retained survive', () => {
        const file = newFile();
        let now = new Date('2025-09-15T12:00:00Z');
        const clock = () => now;
        const s = openStore(file, clock);
        const at = (t) => { now = new Date(t); s.applyPush(payload('m1mini', [job(`j-${t}`, RUNNERS.lin.name, Date.parse(t) - 3600000)])); };
        at('2025-09-15T12:00:00Z'); // 13 months before 2026-10 -> pruned
        at('2025-10-15T12:00:00Z'); // oldest retained month
        at('2026-09-10T12:00:00Z'); // previous cycle, outside the ledger -> sealed
        at('2026-10-01T12:00:00Z'); // current cycle
        now = new Date('2026-10-20T12:00:00Z');
        quiet(() => s.save());
        const saved = JSON.parse(fs.readFileSync(rollupPath(file), 'utf8')).machines.m1mini;
        assert.deepEqual(Object.keys(saved).sort(), ['2025-10-15', '2026-09-10', '2026-10-01']);
        assert.equal(saved['2026-09-10'].ids, null, 'sealed: ids dropped, totals kept');
        assert.equal(saved['2026-09-10'].jobs, 1);
        assert.deepEqual(saved['2026-10-01'].ids, ['j-2026-10-01T12:00:00Z']);
        // a restart keeps the sealed bucket valid
        const s2 = openStore(file, clock);
        assert.equal(s2.rollups.toJSON().machines.m1mini['2026-09-10'].jobs, 1);
        // a job older than the ledger window is not counted (cannot be deduped)
        s2.applyPush(payload('m1mini', [job('ancient', RUNNERS.lin.name, Date.parse('2026-09-10T02:00:00Z'))]));
        assert.equal(s2.rollups.toJSON().machines.m1mini['2026-09-10'].jobs, 1);
        assert.equal(s2.snapshot().summary.cycle.jobs, 1);
    });
    test('a sealed bucket claiming to be inside the ledger window is rejected on load', () => {
        const file = newFile();
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(rollupPath(file), JSON.stringify({ schema_version: 1, machines: { m1mini: {
            '2026-10-19': { jobs: 7, minutes: 7, hostedEquivalentMinutes: 7, runners: { r: { jobs: 7, minutes: 7 } }, ids: null, truncated: false },
        } } }));
        const s = openStore(file, () => new Date('2026-10-20T12:00:00Z'));
        assert.equal(s.rollups.machines.size, 0);
    });
});

// ---------------------------------------------------------------------------
describe('G. bounds: ids/day cap, future-dated, machine eviction', () => {
    const NOW = new Date('2026-10-20T12:00:00Z');
    test('over maxIdsPerDay: truncated, NOT counted, and re-sends still never double count', () => {
        const r = createRollupStore(null, { maxIdsPerDay: 5 });
        const end = Date.parse('2026-10-20T10:00:00Z');
        const outcomes = quiet(() => Array.from({ length: 7 }, (_, i) => r.recordJob('m', job(`t${i}`, 'r', end - i * 1000), new Map(), NOW.getTime())));
        assert.deepEqual(outcomes, ['counted', 'counted', 'counted', 'counted', 'counted', 'truncated', 'truncated']);
        for (let k = 0; k < 3; k++) {
            for (let i = 0; i < 7; i++) quiet(() => r.recordJob('m', job(`t${i}`, 'r', end - i * 1000), new Map(), NOW.getTime()));
        }
        const b = r.toJSON().machines.m['2026-10-20'];
        assert.equal(b.jobs, 5);
        assert.equal(b.truncated, true);
        assert.equal(r.totals('m', '2026-10-20', '2026-10').today.jobs, 5);
    });
    test('a job dated past today+1 is not counted (no unbounded future buckets)', () => {
        const s = openStore(newFile(), () => NOW);
        s.applyPush(payload('m1mini', [job('f', RUNNERS.lin.name, Date.parse('2026-10-25T00:00:00Z')), job('ok', RUNNERS.lin.name, Date.parse('2026-10-21T01:00:00Z'))]));
        assert.deepEqual(Object.keys(s.rollups.toJSON().machines.m1mini), ['2026-10-21']);
    });
    test('evicting an offline machine at the cap drops its rollups too', () => {
        const file = newFile();
        let now = new Date('2026-10-20T10:00:00Z');
        const s = openStore(file, () => now);
        for (let i = 0; i < MAX_MACHINES; i++) {
            now = new Date(Date.parse('2026-10-20T10:00:00Z') + i * 1000);
            s.applyPush(payload(`m${i}`, [job(`j${i}`, RUNNERS.lin.name, Date.parse('2026-10-20T09:00:00Z'))]));
        }
        assert.ok(s.rollups.machines.has('m0'));
        now = new Date(Date.parse('2026-10-20T10:00:00Z') + OFFLINE_THRESHOLD_MS + 60000);
        // keep m1..m63 live so m0 is the only offline candidate
        for (let i = 1; i < MAX_MACHINES; i++) s.applyPush(payload(`m${i}`, []));
        quiet(() => s.applyPush(payload('newcomer', [job('nj', RUNNERS.lin.name, Date.parse('2026-10-20T09:30:00Z'))])));
        assert.ok(!s.machines.has('m0'));
        assert.ok(!s.rollups.machines.has('m0'), 'evicted machine rollups dropped');
        quiet(() => s.save());
        const saved = JSON.parse(fs.readFileSync(rollupPath(file), 'utf8')).machines;
        assert.ok(!('m0' in saved) && 'newcomer' in saved);
        assert.equal(s.snapshot().summary.cycle.jobs, MAX_MACHINES); // m1..m63 + newcomer
    });
});

// ---------------------------------------------------------------------------
describe('H. persistence wiring', () => {
    test('store.save() (the one call server.js makes) writes the rollups file, atomically', () => {
        const file = newFile();
        const s = openStore(file, () => new Date('2026-10-20T12:00:00Z'));
        s.applyPush(payload('m1mini', [job('a', RUNNERS.lin.name, Date.parse('2026-10-20T10:00:00Z'))]));
        quiet(() => s.save());
        assert.deepEqual(fs.readdirSync(path.dirname(file)).sort(), [ROLLUP_FILE_NAME, 'ci-runners.json']);
        const d = JSON.parse(fs.readFileSync(rollupPath(file), 'utf8'));
        assert.equal(d.schema_version, 1);
        assert.deepEqual(d.machines.m1mini['2026-10-20'].ids, ['a']);
    });
    test('server.js persists through ciRunnersStore.save() on the timer and both signals', () => {
        const src = fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8');
        assert.equal((src.match(/ciRunnersStore\.save\(\)/g) || []).length, 3);
    });
});
