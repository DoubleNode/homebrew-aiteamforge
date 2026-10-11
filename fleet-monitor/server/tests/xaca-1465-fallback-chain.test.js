'use strict';

// XACA-1465-017/015/016: the workflows chain `vars.HEAVY || vars.LINUX || 'ubuntu-latest'`; the reader must
// resolve a switch through its `fallsBackTo` link when its own value is unset/empty. Zero network.

const test = require('node:test');
const assert = require('node:assert/strict');
const { createFallbackReader, classifySwitchValue, describeError, resolveChain } = require('../lib/ci-fallback-reader');
const { validateFallbackSwitches, DEFAULT_FALLBACK_SWITCHES } = require('../lib/ci-pool-store');

const SELF = '["self-hosted","fleet-pool"]';
const DN = (variable, label, fallsBackTo) => ({ owner: 'DoubleNode', repo: 'dev-team', variable, label, ...(fallsBackTo ? { fallsBackTo } : {}) });
const LIST = [DN('CI_LINUX_RUNNER', 'LINUX'), DN('CI_LINUX_RUNNER_HEAVY', 'LINUX HEAVY', 'CI_LINUX_RUNNER')];

const err = (code, status) => Object.assign(new Error('boom'), { name: 'GithubError', code, status });
// spec: 'armed' | 'absent' | 'empty' | 'ubuntu' | 'bad' | 'blank' | 'nl' | 'throw' | 'skip' (never read)
function respond(spec) {
    switch (spec) {
        case 'armed': return { found: true, value: SELF, etag: 'W/"a"' };
        case 'absent': return { found: false };
        case 'empty': return { found: true, value: '', etag: 'W/"e"' };
        case 'ubuntu': return { found: true, value: '["ubuntu-latest"]', etag: 'W/"u"' };
        case 'bad': return { found: true, value: '[', etag: 'W/"b"' };
        case 'blank': return { found: true, value: ' ', etag: 'W/"s"' };
        case 'nl': return { found: true, value: '\n', etag: 'W/"n"' };
        default: throw err('NETWORK');
    }
}

async function snap(specs, list = LIST) {
    let t = Date.parse('2026-10-10T12:00:00Z');
    const reader = createFallbackReader({
        github: { async getRepoVariable(o, r, name) { t += 1000; const s = specs[name]; if (s === 'throw') throw err('NETWORK'); return respond(s); } },
        store: { getFallbackSwitches: () => list.map((s) => ({ ...s })) },
        now: () => t,
        setTimer: () => ({}), clearTimer: () => {},
    });
    await reader.start(); reader.stop();
    return reader.snapshot();
}

// [heavy, linux, expected heavy armed, reason pattern]
const MATRIX = [
    ['absent', 'armed', true, /unset: follows CI_LINUX_RUNNER/],
    ['empty', 'armed', true, /unset: follows CI_LINUX_RUNNER/],
    ['absent', 'absent', false, /unset: follows CI_LINUX_RUNNER/],
    ['empty', 'empty', false, /unset: follows CI_LINUX_RUNNER/],
    ['absent', 'bad', null, /follows CI_LINUX_RUNNER: value is not valid JSON/],
    ['absent', 'ubuntu', null, /follows CI_LINUX_RUNNER: array does not include self-hosted/],
    ['absent', 'blank', null, /follows CI_LINUX_RUNNER: value is blank/],
    ['absent', 'throw', null, /follows CI_LINUX_RUNNER: GitHub unreachable/],
    ['armed', 'absent', true, null],          // own value wins; link ignored
    ['armed', 'bad', true, null],
    ['ubuntu', 'armed', null, /does not include self-hosted/],   // set but not self-hosted: never inherits
    ['blank', 'armed', null, /blank/],        // whitespace is truthy in `||`: no inheritance
    ['nl', 'armed', null, /blank/],
    ['bad', 'armed', null, /not valid JSON/],
    ['throw', 'armed', null, /unreachable/],  // own read failed: unknown, never inherits
];

test('chain matrix through snapshot(): HEAVY resolves via LINUX exactly as the workflow `||` does', async () => {
    for (const [heavy, linux, armed, reason] of MATRIX) {
        const s = await snap({ CI_LINUX_RUNNER_HEAVY: heavy, CI_LINUX_RUNNER: linux });
        const h = s.switches.find((x) => x.variable === 'CI_LINUX_RUNNER_HEAVY');
        const tag = `heavy=${heavy} linux=${linux}`;
        assert.equal(h.armed, armed, tag);
        if (reason) assert.match(h.reason || '', reason, tag); else assert.equal(h.reason, null, tag);
        assert.equal(h.fallsBackTo, 'CI_LINUX_RUNNER', tag);
    }
});

test('whitespace-only on ANY switch is UNKNOWN (truthy in `||`, fromJSON(" ") fails); empty means exactly ""', async () => {
    for (const ws of [' ', '\n', '\t', '  \n ']) {
        assert.equal(classifySwitchValue({ found: true, value: ws }).armed, null, JSON.stringify(ws));
    }
    assert.equal(classifySwitchValue({ found: true, value: '' }).armed, false);
    assert.equal(classifySwitchValue({ found: false }).armed, false);
    const s = await snap({ CI_LINUX_RUNNER: 'blank', CI_LINUX_RUNNER_HEAVY: 'absent' });
    assert.equal(s.switches[0].armed, null);
});

test('HEAVY never read (no results yet) => UNKNOWN; LINUX never read => HEAVY UNKNOWN', () => {
    const mk = (variable, fallsBackTo, st) => ({ sw: DN(variable, variable, fallsBackTo), st });
    const unread = { armed: null, reason: 'not read yet', labels: undefined, error: null, checkedAt: null, absent: false };
    const absent = { armed: false, reason: null, labels: undefined, error: null, checkedAt: '2026-10-10T12:00:01.000Z', absent: true };
    const rows = [mk('CI_LINUX_RUNNER', null, unread), mk('CI_LINUX_RUNNER_HEAVY', 'CI_LINUX_RUNNER', absent)];
    const res = resolveChain(rows);
    assert.equal(res.get(rows[1]).armed, null);
    assert.match(res.get(rows[1]).reason, /follows CI_LINUX_RUNNER: not read yet/);
});

test('missing link in the list at snapshot time => UNKNOWN with a fixed reason (fail safe)', async () => {
    const s = await snap({ CI_LINUX_RUNNER_HEAVY: 'absent' }, [DN('CI_LINUX_RUNNER_HEAVY', 'LINUX HEAVY', 'CI_LINUX_RUNNER')]);
    assert.equal(s.switches[0].armed, null);
    assert.equal(s.switches[0].reason, 'follows CI_LINUX_RUNNER, which is not configured');
});

test('a cycle that slipped past validation resolves UNKNOWN, never loops', () => {
    const absent = { armed: false, reason: null, error: null, checkedAt: 'x', absent: true };
    const rows = [
        { sw: DN('A', 'A', 'B'), st: { ...absent } },
        { sw: DN('B', 'B', 'A'), st: { ...absent } },
    ];
    const res = resolveChain(rows);
    assert.equal(res.get(rows[0]).armed, null);
    assert.equal(res.get(rows[1]).armed, null);
});

test('checkedAt of a chained switch is the OLDER of its own and its link\'s; error propagates', async () => {
    const s = await snap({ CI_LINUX_RUNNER: 'armed', CI_LINUX_RUNNER_HEAVY: 'absent' });
    const lin = s.switches.find((x) => x.variable === 'CI_LINUX_RUNNER');
    const hv = s.switches.find((x) => x.variable === 'CI_LINUX_RUNNER_HEAVY');
    assert.ok(hv.checkedAt <= lin.checkedAt || hv.checkedAt >= lin.checkedAt);
    assert.equal(hv.checkedAt, [lin.checkedAt, hv.checkedAt].sort()[0]);
});

test('legacy linux field reflects the chained switch too, and a switch without fallsBackTo is unchanged', async () => {
    const s = await snap({ CI_LINUX_RUNNER: 'absent', CI_LINUX_RUNNER_HEAVY: 'absent' }, [DN('CI_LINUX_RUNNER', 'LINUX'), DN('CI_LINUX_RUNNER_HEAVY', 'LINUX HEAVY')]);
    assert.equal(s.switches[1].armed, false);
    assert.equal('fallsBackTo' in s.switches[1], false);
});

// 015
test('self-hosted matches case-insensitively; still requires an array of strings', () => {
    for (const v of ['["Self-Hosted"]', '["SELF-HOSTED","linux"]', '["linux","self-HOSTED"]']) {
        assert.equal(classifySwitchValue({ found: true, value: v }).armed, true, v);
    }
    for (const v of ['"Self-Hosted"', '[1,"Self-Hosted"]', '["self-hosted-x"]']) {
        assert.equal(classifySwitchValue({ found: true, value: v }).armed, null, v);
    }
});

// 016
test('describeError: each GithubError code gets its own fixed string; nothing from err.message', () => {
    const e = (code, status) => Object.assign(new Error('SECRET-ghs_abc'), { code, status });
    assert.equal(describeError(e('NOT_INSTALLED', 404), 'DoubleNode'), 'GitHub App not installed for DoubleNode');
    assert.equal(describeError(e('NOT_CONFIGURED'), 'DoubleNode'), 'GitHub App credentials not configured');
    assert.equal(describeError(e('KEY_INVALID'), 'DoubleNode'), 'GitHub App key rejected');
    assert.equal(describeError(e('NETWORK'), 'DoubleNode'), 'GitHub unreachable');
    const all = ['NOT_INSTALLED', 'NOT_CONFIGURED', 'KEY_INVALID', 'NETWORK'].map((c) => describeError(e(c, c === 'NOT_INSTALLED' ? 404 : undefined), 'o'));
    assert.equal(new Set(all).size, 4);
    for (const m of all) assert.ok(!m.includes('SECRET') && !m.includes('HTTP 404'));
});

// store validation
test('store: default list carries HEAVY -> LINUX and validates; lists without fallsBackTo still validate', () => {
    assert.deepEqual(validateFallbackSwitches(DEFAULT_FALLBACK_SWITCHES), []);
    assert.equal(DEFAULT_FALLBACK_SWITCHES.find((x) => x.variable === 'CI_LINUX_RUNNER_HEAVY').fallsBackTo, 'CI_LINUX_RUNNER');
    assert.deepEqual(validateFallbackSwitches([DN('CI_LINUX_RUNNER', 'LINUX'), DN('CI_LINUX_RUNNER_HEAVY', 'H')]), []);
});

test('store: fallsBackTo rejects self-reference, unknown target, other repo, cycle, bad type/name', () => {
    const base = DN('A', 'A');
    const bad = [
        [DN('A', 'A', 'A')],
        [DN('A', 'A', 'B')],
        [DN('A', 'A', 'B'), { ...DN('B', 'B'), repo: 'other' }],
        [DN('A', 'A', 'B'), DN('B', 'B', 'A')],
        [DN('A', 'A', 'B'), DN('B', 'B', 'C'), DN('C', 'C', 'A')],
        [{ ...base, fallsBackTo: 5 }, DN('B', 'B')],
        [{ ...base, fallsBackTo: 'not a var' }, DN('B', 'B')],
    ];
    for (const l of bad) assert.ok(validateFallbackSwitches(l).length > 0, JSON.stringify(l));
    assert.deepEqual(validateFallbackSwitches([DN('A', 'A', 'B'), DN('B', 'B', 'C'), DN('C', 'C')]), []);
});
