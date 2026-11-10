'use strict';
// XACA-1704-014: the ci-no-capacity audit 'alert' event persists WHY each host refused, so a stall is
// explainable after the in-memory alerts ring rolls. The audit is scalar-only, so refusals are one compact string:
//   "<host>:<reason>,<reason>|<host>:<reason>"  (+ "|+N more" when hosts were dropped for length).
const { test } = require('node:test');
const assert = require('node:assert/strict');

const { refusalsAuditText } = require('../lib/ci-dispatcher');
const { build, job, POOL_LINUX, GIB } = require('./helpers/xaca-1704-dispatcher-harness');

/** Park a job with no eligible host, then run past the 120 s no-capacity grace. */
async function stall(s, jobId) {
    s.dispatcher.onJob(job(jobId, POOL_LINUX), 'queued');
    await s.dispatcher.tick();
    s.clock.t += 130000;
    for (const r of s.reports.values()) r.receivedAt = s.clock.t - 4000;
    await s.dispatcher.tick();
}
const alertRows = (s) => s.auditRows().filter((r) => r.event === 'alert' && r.reason === 'ci-no-capacity');

test('the ci-no-capacity audit alert carries per-host refusal reasons', async () => {
    const s = build({
        m1mini: { cap: { swapUsedBytes: 2877 * 1024 * 1024 } },
        m4mini: { cap: { swapUsedBytes: 3 * GIB, memFreePct: 3 } },
    });
    await stall(s, 1);
    const rows = alertRows(s);
    assert.equal(rows.length, 1);
    assert.equal(typeof rows[0].refusals, 'string');
    const parsed = Object.fromEntries(rows[0].refusals.split('|').map((p) => { const [h, r] = p.split(':'); return [h, r.split(',')]; }));
    assert.deepEqual(parsed.m1mini, ['swap-high']);
    assert.deepEqual(parsed.m4mini, ['swap-high', 'mem-free-low']);
});

test('cadence unchanged: one audit alert per incident, not one per tick', async () => {
    const s = build({ m1mini: { cap: { swapUsedBytes: 3 * GIB } } });
    await stall(s, 2);
    s.clock.t += 60000;
    s.reports.get('m1mini').receivedAt = s.clock.t - 4000;
    await s.dispatcher.tick();
    assert.equal(alertRows(s).length, 1);
});

test('bounded: 30 refusing hosts still fit one audit value and never cut a host mid-name', async () => {
    const m = {};
    for (let i = 0; i < 30; i++) m[`host-${String(i).padStart(2, '0')}`] = { cap: { swapUsedBytes: 3 * GIB, memFreePct: 1, load1: 99, load5: 99 } };
    const s = build(m);
    await stall(s, 3);
    const t = alertRows(s)[0].refusals;
    assert.ok(t.length <= 512, String(t.length));
    assert.ok(!t.includes('[redacted]'));
    for (const part of t.split('|')) assert.ok(/^host-\d\d:[a-z,-]+$/.test(part) || /^\+\d+ more$/.test(part), part);
    assert.ok(/\|\+\d+ more$/.test(t) || t.split('|').length === 16, 'truncated text must say how many hosts were dropped');
});

test('no refusals field when every host is eligible-but-excluded is not invented: field absent for non-refusal alerts', async () => {
    const s = build({ m1mini: { cap: { swapUsedBytes: 3 * GIB } } });
    await stall(s, 4);
    const other = s.auditRows().filter((r) => r.event === 'alert' && r.reason !== 'ci-no-capacity');
    for (const r of other) assert.equal(r.refusals, undefined);
});

test('XACA-1789-016: a single host part over the budget is kept with truncated reasons, not dropped', () => {
    const id = 'h'.repeat(128);
    const reasons = Array.from({ length: 12 }, (_, i) => String(i).padStart(2, '0') + 'x'.repeat(38));
    const only = refusalsAuditText({ [id]: reasons });
    assert.ok(only.length <= 480, String(only.length));
    assert.ok(only.startsWith(id + ':'), 'host id present');
    assert.match(only, /,\+\d+ more$/);
    assert.ok(only.includes(reasons[0]), 'whole reasons kept');
    const withOther = refusalsAuditText({ [id]: reasons, other: ['paused'] });
    assert.ok(withOther.length <= 480, String(withOther.length));
    assert.ok(withOther.startsWith(id + ':'));
    assert.ok(withOther.endsWith('|+1 more'), withOther.slice(-30));
    // A later over-budget host is still dropped whole (existing behaviour).
    const later = refusalsAuditText({ a: ['paused'], [id]: reasons });
    assert.equal(later, 'a:paused|+1 more');
});

test('XACA-1789 round 2: the "|+N more" marker is never cut and the row stays <= 480 (length sweep)', () => {
    let checked = 0;
    for (let firstLen = 380; firstLen <= 490; firstLen++) {
        for (let extra = 1; extra <= 3; extra++) {
            const r = { a: ['x'.repeat(Math.max(1, firstLen - 2))] };
            for (let i = 0; i < extra; i++) r['h' + i] = ['paused'];
            const s = refusalsAuditText(r);
            assert.ok(s.length <= 480, `len ${s.length} at firstLen=${firstLen} extra=${extra}`);
            const shown = s.split('|').filter((p) => !/^\+\d+ more$/.test(p)).length;
            if (shown < 1 + extra) assert.match(s, new RegExp(`\\|\\+${1 + extra - shown} more$`), s.slice(-40));
            checked++;
        }
    }
    // Many small hosts: the dropped count is reported, not silently lost.
    const many = {};
    for (let i = 0; i < 40; i++) many['host' + String(i).padStart(2, '0')] = ['swap-high', 'mem-pressure'];
    const s = refusalsAuditText(many);
    assert.ok(s.length <= 480, String(s.length));
    const kept = s.split('|').length - 1;
    assert.match(s, new RegExp(`\\|\\+${40 - kept} more$`), s.slice(-40));
    assert.ok(checked > 300, 'sweep ran');
});
