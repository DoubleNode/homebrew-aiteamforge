'use strict';

// XACA-1465-002: ci-fallback-reader. Fake github + fake clock/timers; zero network.

const test = require('node:test');
const assert = require('node:assert/strict');
const { createFallbackReader, classifySwitchValue } = require('../lib/ci-fallback-reader');

const DN = (variable, label) => ({ owner: 'DoubleNode', repo: 'dev-team', variable, label });
const DEFAULTS = [DN('CI_LINUX_RUNNER', 'LINUX'), DN('CI_MACOS_RUNNER', 'MACOS'), DN('CI_LINUX_RUNNER_HEAVY', 'LINUX HEAVY')];
const SELF = '["self-hosted","fleet-pool","m1mini"]';

function gh(status, extra = {}) { const e = new Error('x'); e.name = 'GithubError'; e.code = extra.code || 'HTTP'; e.status = status; return e; }

/** handler(variable, call) -> result | throws. Records every call. */
function fakeGithub(handler) {
    const calls = [];
    return {
        calls,
        async getRepoVariable(owner, repo, name, o = {}) {
            const call = { owner, repo, name, etag: o.etag };
            calls.push(call);
            return handler(name, call, calls.length);
        },
    };
}
const ok = (value, etag = 'W/"e1"') => ({ found: true, value, updatedAt: null, etag });

function harness({ handler, switches = DEFAULTS, intervalMs = 300000, minRefreshIntervalMs = 30000, github } = {}) {
    let t = Date.parse('2026-10-10T12:00:00Z');
    const timers = [];
    let list = switches;
    const g = github === undefined ? fakeGithub(handler) : github;
    const logs = [];
    const reader = createFallbackReader({
        github: g,
        store: { getFallbackSwitches: () => list.map((s) => ({ ...s })) },
        now: () => t,
        logger: { warn: (m) => logs.push(m) },
        intervalMs, minRefreshIntervalMs,
        setTimer: (fn, ms) => { const h = { fn, ms, cleared: false }; timers.push(h); return h; },
        clearTimer: (h) => { h.cleared = true; },
    });
    return { reader, g, timers, logs, advance: (ms) => { t += ms; }, setList: (l) => { list = l; }, nowIso: () => new Date(t).toISOString() };
}

// ---------------------------------------------------------------- classifier

test('classifier matrix', () => {
    const cases = [
        [{ found: true, value: SELF }, true],
        [{ found: false }, false],
        [{ found: true, value: '' }, false],
        [{ found: true, value: '   ' }, null],
        [{ found: true, value: '\n' }, null],
        [{ found: true, value: 'ubuntu-latest' }, null],
        [{ found: true, value: '"ubuntu-latest"' }, null],
        [{ found: true, value: '["ubuntu-latest"]' }, null],
        [{ found: true, value: '[]' }, null],
        [{ found: true, value: '{}' }, null],
        [{ found: true, value: '[1,"self-hosted"]' }, null],
        [{ found: true, value: '["Self-Hosted"]' }, true],
        [{ found: true, value: '["SELF-HOSTED","x"]' }, true],
        [{ found: true, value: '[' }, null],
        [{ weird: 1 }, null],
        [undefined, null],
    ];
    for (const [input, armed] of cases) {
        assert.equal(classifySwitchValue(input).armed, armed, JSON.stringify(input));
    }
});

test('classifier: malformed always carries a short fixed reason and never echoes the value', () => {
    const evil = '<script>alert(1)</script>' + 'x'.repeat(500);
    const r = classifySwitchValue({ found: true, value: evil });
    assert.equal(r.armed, null);
    assert.ok(r.reason && r.reason.length < 60);
    assert.ok(!r.reason.includes('script'));
    assert.equal(classifySwitchValue({ found: false }).reason, null);
});

test('classifier: labels are capped', () => {
    const many = ['self-hosted', ...Array.from({ length: 30 }, (_, i) => 'l' + 'a'.repeat(100) + i)];
    const r = classifySwitchValue({ found: true, value: JSON.stringify(many) });
    assert.equal(r.armed, true);
    assert.ok(r.labels.length <= 10);
    assert.ok(r.labels.every((l) => l.length <= 64));
});

test('mutation guard: the malformed branches can never yield true (end-to-end through the reader)', async () => {
    // If classifySwitchValue's malformed branch returned armed:true, the snapshot below would show true.
    for (const bad of ['ubuntu-latest', '"ubuntu-latest"', '["ubuntu-latest"]', '{}', '[1,"self-hosted"]', 'not json']) {
        const h = harness({ handler: () => ok(bad), switches: [DN('CI_LINUX_RUNNER', 'LINUX')] });
        await h.reader.start(); h.reader.stop();
        const snap = h.reader.snapshot();
        assert.notEqual(snap.switches[0].armed, true, bad);
        assert.equal(snap.switches[0].armed, null, bad);
        assert.equal(snap.linux, null, bad);
        assert.ok(snap.switches[0].reason);
    }
});

// ---------------------------------------------------------------- reader

test('reads all switches: armed true/false/null, store order, legacy shape, checkedAt', async () => {
    const h = harness({
        handler: (name) => (name === 'CI_LINUX_RUNNER' ? ok(SELF) : name === 'CI_MACOS_RUNNER' ? { found: false } : ok('bogus')),
    });
    await h.reader.start(); h.reader.stop();
    const s = h.reader.snapshot();
    assert.deepEqual(s.linux, { armed: true, value: '["self-hosted","fleet-pool","m1mini"]' });
    assert.deepEqual(s.macos, { armed: false, value: null });
    assert.equal(s.checkedAt, h.nowIso());
    assert.deepEqual(s.switches.map((x) => [x.variable, x.armed]), [['CI_LINUX_RUNNER', true], ['CI_MACOS_RUNNER', false], ['CI_LINUX_RUNNER_HEAVY', null]]);
    assert.ok(s.switches[2].reason);
    assert.ok(!('etag' in s.switches[0]) && !('value' in s.switches[0]) && !('labels' in s.switches[0]));
    // fresh copy
    s.switches[0].armed = 'tampered';
    assert.equal(h.reader.snapshot().switches[0].armed, true);
});

test('transient failure after a good read keeps value and ORIGINAL checkedAt', async () => {
    let phase = 'good';
    const h = harness({
        handler: () => { if (phase === 'good') return ok(SELF); throw gh(phase === '5xx' ? 502 : 403); },
        switches: [DN('CI_LINUX_RUNNER', 'LINUX'), DN('CI_MACOS_RUNNER', 'MACOS')],
    });
    await h.reader.start();
    const first = h.reader.snapshot().checkedAt;
    h.advance(600000);
    phase = '5xx';
    await h.reader.refreshNow({ force: true });
    let s = h.reader.snapshot();
    assert.equal(s.linux.armed, true);
    assert.equal(s.checkedAt, first, 'checkedAt must not move on failure');
    assert.equal(s.switches[0].error, 'GitHub returned HTTP 502');
    phase = '403';
    await h.reader.refreshNow({ force: true });
    s = h.reader.snapshot();
    assert.equal(s.linux.armed, true);
    assert.equal(s.checkedAt, first);
    assert.match(s.switches[0].error, /HTTP 403.*Variables: read/);
    h.reader.stop();
});

test('never-read switch + failure stays null / checkedAt null / reason present', async () => {
    const h = harness({ handler: () => { throw gh(403); }, switches: [DN('CI_LINUX_RUNNER', 'LINUX'), DN('CI_MACOS_RUNNER', 'MACOS')] });
    await h.reader.start(); h.reader.stop();
    const s = h.reader.snapshot();
    assert.equal(s.linux, null);
    assert.equal(s.checkedAt, null);
    assert.equal(s.switches[0].armed, null);
    assert.equal(s.switches[0].checkedAt, null);
    assert.match(s.switches[0].reason, /HTTP 403/);
});

test('network error maps to fixed "GitHub unreachable"; one failure does not stop the others', async () => {
    const h = harness({
        handler: (name) => { if (name === 'CI_LINUX_RUNNER') throw new Error('ECONNRESET secret-token-abc'); return ok(SELF); },
    });
    await h.reader.start(); h.reader.stop();
    const s = h.reader.snapshot();
    assert.equal(s.switches[0].reason, 'GitHub unreachable');
    assert.equal(s.switches[1].armed, true);
    assert.equal(s.switches[2].armed, true);
    assert.ok(!JSON.stringify(s).includes('secret-token'));
});

test('errors are logged once per state change, not every tick, and never leak the message', async () => {
    const h = harness({ handler: () => { throw gh(500); }, switches: [DN('CI_LINUX_RUNNER', 'LINUX')] });
    await h.reader.start();
    await h.reader.refreshNow({ force: true });
    await h.reader.refreshNow({ force: true });
    h.reader.stop();
    assert.equal(h.logs.length, 1);
});

test('304 sends the stored etag and bumps checkedAt, keeping classification', async () => {
    let n = 0;
    const h = harness({
        switches: [DN('CI_LINUX_RUNNER', 'LINUX')],
        handler: (name, call) => { n++; return n === 1 ? ok(SELF, 'W/"abc"') : { notModified: true, etag: call.etag }; },
    });
    await h.reader.start();
    const t1 = h.reader.snapshot().switches[0].checkedAt;
    h.advance(60000);
    await h.reader.refreshNow();
    h.reader.stop();
    assert.equal(h.g.calls[0].etag, undefined);
    assert.equal(h.g.calls[1].etag, 'W/"abc"');
    const s = h.reader.snapshot();
    assert.equal(s.linux.armed, true);
    assert.notEqual(s.switches[0].checkedAt, t1);
    assert.equal(s.switches[0].checkedAt, h.nowIso());
});

test('github null: start is a no-op, snapshot null, zero calls', async () => {
    const h = harness({ github: null });
    await h.reader.start();
    assert.equal(h.reader.snapshot(), null);
    assert.equal(h.timers.length, 0);
    assert.equal((await h.reader.refreshNow()).ran, false);
    await h.reader.onSwitchesChanged();
    h.reader.stop();
});

test('refreshNow: throttled inside the min interval with ZERO extra github calls', async () => {
    const h = harness({ handler: () => ok(SELF) });
    await h.reader.start();
    const base = h.g.calls.length;
    h.advance(10000);
    const r = await h.reader.refreshNow();
    assert.equal(r.ran, false);
    assert.equal(r.throttled, true);
    assert.equal(r.retryAfterSec, 20);
    for (let i = 0; i < 5; i++) await h.reader.refreshNow();
    assert.equal(h.g.calls.length, base);
    h.advance(25000);
    assert.deepEqual(await h.reader.refreshNow(), { ran: true });
    assert.equal(h.g.calls.length, base + 3);
    h.reader.stop();
});

test('refreshNow: concurrent callers share ONE read', async () => {
    let release;
    const gate = new Promise((r) => { release = r; });
    const h = harness({ handler: async () => { await gate; return ok(SELF); }, switches: [DN('CI_LINUX_RUNNER', 'LINUX')] });
    const p0 = h.reader.start();
    const [a, b] = await Promise.all([h.reader.refreshNow({ force: true }), h.reader.refreshNow()].map((p) => { release(); return p; }));
    await p0;
    assert.equal(a.ran, true); assert.equal(b.ran, true);
    assert.equal(a.coalesced, true); assert.equal(b.coalesced, true);
    assert.equal(h.g.calls.length, 1, 'only one read happened');
    h.reader.stop();
});

test('ticks never overlap: next timer is armed only after the read finishes', async () => {
    let release; let active = 0; let maxActive = 0;
    const gate = new Promise((r) => { release = r; });
    const h = harness({
        switches: [DN('CI_LINUX_RUNNER', 'LINUX')],
        handler: async () => { active++; maxActive = Math.max(maxActive, active); await gate; active--; return ok(SELF); },
    });
    const first = h.reader.start();
    assert.equal(h.timers.length, 0, 'no timer while the first read is running');
    release();
    await first;
    await new Promise((r) => setImmediate(r));
    assert.equal(h.timers.length, 1);
    assert.equal(h.timers[0].ms, 300000);
    h.timers[0].fn(); h.timers[0].fn();            // a double-fire coalesces onto one read
    await new Promise((r) => setImmediate(r));
    assert.equal(maxActive, 1);
    h.reader.stop();
});

test('stop() cancels the pending timer and prevents rescheduling', async () => {
    const h = harness({ handler: () => ok(SELF), switches: [DN('CI_LINUX_RUNNER', 'LINUX')] });
    await h.reader.start();
    await new Promise((r) => setImmediate(r));
    const t = h.timers[h.timers.length - 1];
    h.reader.stop();
    assert.equal(t.cleared, true);
    const n = h.timers.length;
    await t.fn();
    assert.equal(h.timers.length, n, 'no reschedule after stop');
});

test('checkedAt is the OLDEST of linux+macos; null if either never read', async () => {
    let fail = false;
    const h = harness({
        switches: [DN('CI_LINUX_RUNNER', 'LINUX'), DN('CI_MACOS_RUNNER', 'MACOS')],
        handler: (name) => { if (fail && name === 'CI_MACOS_RUNNER') throw gh(500); return ok(SELF); },
    });
    await h.reader.start();
    const t1 = h.nowIso();
    h.advance(120000);
    fail = true;
    await h.reader.refreshNow({ force: true });
    const s = h.reader.snapshot();
    assert.equal(s.checkedAt, t1, 'macos stayed at t1, linux moved on');
    h.reader.stop();

    const h2 = harness({
        switches: [DN('CI_LINUX_RUNNER', 'LINUX'), DN('CI_MACOS_RUNNER', 'MACOS')],
        handler: (name) => { if (name === 'CI_MACOS_RUNNER') throw gh(500); return ok(SELF); },
    });
    await h2.reader.start(); h2.reader.stop();
    assert.equal(h2.reader.snapshot().checkedAt, null);
});

test('list change via onSwitchesChanged adds new (never-read) and removes old; linux/macos null when removed', async () => {
    const h = harness({ handler: () => ok(SELF), switches: DEFAULTS });
    await h.reader.start();
    const android = { owner: 'MainEventEntertainment', repo: 'MainEventApp-Android', variable: 'CI_RUNNER', label: 'ANDROID' };
    h.setList([DN('CI_MACOS_RUNNER', 'MACOS'), android]);
    // snapshot reflects the new list at once; the new switch is never-read
    let s = h.reader.snapshot();
    assert.equal(s.linux, null);
    assert.deepEqual(s.switches.map((x) => x.variable), ['CI_MACOS_RUNNER', 'CI_RUNNER']);
    assert.equal(s.switches[1].armed, null);
    assert.equal(s.switches[1].reason, 'not read yet');
    assert.equal(s.switches[1].checkedAt, null);
    const before = h.g.calls.length;
    await h.reader.onSwitchesChanged();            // bypasses the min interval
    assert.equal(h.g.calls.length, before + 2);
    assert.deepEqual(h.g.calls.slice(-2).map((c) => c.owner + '/' + c.repo + '/' + c.name),
        ['DoubleNode/dev-team/CI_MACOS_RUNNER', 'MainEventEntertainment/MainEventApp-Android/CI_RUNNER']);
    s = h.reader.snapshot();
    assert.equal(s.switches[1].armed, true);
    h.reader.stop();
});

test('onSwitchesChanged during a read queues one follow-up read', async () => {
    let release; const gate = new Promise((r) => { release = r; });
    let first = true;
    const h = harness({
        switches: [DN('CI_LINUX_RUNNER', 'LINUX')],
        handler: async () => { if (first) { first = false; await gate; } return ok(SELF); },
    });
    const p = h.reader.start();
    h.setList([DN('CI_MACOS_RUNNER', 'MACOS')]);
    const c = h.reader.onSwitchesChanged();
    release();
    await Promise.all([p, c]);
    assert.ok(h.g.calls.some((x) => x.name === 'CI_MACOS_RUNNER'), 'new list was read');
    h.reader.stop();
});
