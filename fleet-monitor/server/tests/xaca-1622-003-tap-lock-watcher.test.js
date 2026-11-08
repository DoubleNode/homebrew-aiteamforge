//
//  xaca-1622-003-tap-lock-watcher.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/** XACA-1622-003 -- stale tap-writer-lock watcher. Pure: fake clock, fake runner, recording emitter. */

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const W = require('../lib/tap-lock-watcher');

const MIN = 60 * 1000;
const SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const SHA_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const BREAK_CMD = 'scripts/kb-tap-lock.sh break --force --expect ' + SHA_A;

function stdoutFor(state, extra = {}) {
    const f = Object.assign({
        state, ref: 'refs/locks/tap-writer', lock_sha: SHA_A, holder: 'tap-publisher#42', host: 'runner-7',
        run_url: 'https://github.com/DoubleNode/dev-team/actions/runs/42?check_suite_focus=true',
        acquired_at: '2026-11-08T01:00:00Z', age: 39900, stale_after: 3600, break_cmd: BREAK_CMD, reason: '',
    }, extra);
    return Object.keys(f).map((k) => `${k}=${f[k]}`).join('\n') + '\n';
}
const FREE = { rc: 0, stdout: stdoutFor('free') };
const YOUNG = { rc: 0, stdout: stdoutFor('young', { age: 100 }) };
const STALE = { rc: 1, stdout: stdoutFor('stale') };
const UNREADABLE = { rc: 2, stdout: stdoutFor('unreadable', { reason: 'ls-remote failed' }) };

function setup(over = {}) {
    const clock = { t: Date.UTC(2026, 10, 8, 12, 0, 0) };
    const sent = [];
    const calls = [];
    const script = { next: FREE };
    const runner = async (spec) => { calls.push(spec); const n = script.next; if (n instanceof Error) throw n; return n; };
    const config = Object.assign(W.resolveTapLockConfig({ FLEET_TAP_LOCK_WATCH: '1' }, { exists: () => true }), over.config || {});
    const w = W.createTapLockWatcher({
        emit: (n) => { sent.push(n); }, now: () => clock.t, config, runner, exists: over.exists || (() => true),
        logger: { log() {}, warn() {} }, baseEnv: { PATH: '/usr/bin', HOME: '/h' },
    });
    const poll = async (next, advance = 5 * MIN) => { if (next !== undefined) script.next = next; clock.t += advance; return w.pollOnce(); };
    return { w, clock, sent, calls, script, poll };
}

describe('state machine', () => {
    test('free and young produce nothing', async () => {
        const { poll, sent } = setup();
        await poll(FREE); await poll(YOUNG); await poll(FREE);
        assert.equal(sent.length, 0);
    });

    test('stale -> exactly one alert with holder, age, run url, host, acquired_at and the EXACT break_cmd', async () => {
        const { poll, sent } = setup();
        await poll(STALE);
        assert.equal(sent.length, 1);
        const n = sent[0];
        assert.equal(n.type, 'tap-lock-stale');
        assert.equal(n.severity, 'high');
        assert.match(n.title, /tap-publisher#42/);
        assert.match(n.title, /11h 05m/);
        for (const frag of ['tap-publisher#42', 'runner-7', 'actions/runs/42?check_suite_focus=true', '2026-11-08T01:00:00Z', '11h 05m', BREAK_CMD,
            'Verify that run is dead (check the run URL) before breaking.', 'Nothing breaks this lock automatically.',
            'stale threshold: 1h 00m']) {
            assert.ok(n.body.includes(frag), `body missing ${frag}`);
        }
        assert.ok(!/0h/.test(n.body + n.title), 'no 0hNNm age');
        assert.match(n.title, /^Tap publishing blocked: stale tap-writer lock held by tap-publisher#42 for 11h 05m$/);
        assert.ok(n.title.length <= 200 && n.body.length <= 1000);
        assert.match(n.ref, /^tap-writer:aaaaaaaaaaaa:1$/);
    });

    test('stale body ORDER: details, verify line, never-breaks line, repo-root line, then the command LAST (survives newline flattening)', async () => {
        const { poll, sent } = setup();
        await poll(STALE);
        const lines = sent[0].body.split('\n');
        const iVerify = lines.findIndex((l) => l.startsWith('Verify that run is dead'));
        const iRoot = lines.indexOf('From the dev-team repo root:');
        const iCmd = lines.indexOf(BREAK_CMD);
        const iNever = lines.indexOf('Nothing breaks this lock automatically.');
        assert.ok(iVerify > lines.findIndex((l) => l.startsWith('Age:')), 'verify after the Age line');
        assert.ok(iVerify >= 0 && iVerify < iNever && iNever < iRoot && iRoot + 1 === iCmd && iCmd === lines.length - 1,
            `order wrong: ${JSON.stringify(lines)}`);
        // Delivery flattens newlines (fleet-notices.js clean()): the flattened body must still END with the command.
        assert.ok(sent[0].body.replace(/[\r\n]+/g, ' ').endsWith(BREAK_CMD), 'flattened body must end with the command');
        assert.ok(sent[0].body.indexOf('Verify that run') < sent[0].body.indexOf(BREAK_CMD));
        assert.ok(lines[iCmd].endsWith(SHA_A), 'nothing after the sha on the command line');
    });

    test('Host line kept when present, omitted only when host is empty', async () => {
        const a = setup(); await a.poll(STALE);
        assert.ok(a.sent[0].body.includes('Host: runner-7'));
        const b = setup(); await b.poll({ rc: 1, stdout: stdoutFor('stale', { host: '' }) });
        assert.ok(!/^Host:/m.test(b.sent[0].body), 'no empty Host line');
    });

    test('age format is unified: under an hour reads "2m 05s", never "0h02m"', () => {
        assert.equal(W.formatAge(125), '2m 05s');
        assert.equal(W.formatAge(42), '42s');
        assert.equal(W.formatAge(39900), '11h 05m');
        assert.equal(W.formatAge(3600), '1h 00m');
        assert.equal(W.formatAge(2 * 86400 + 3 * 3600), '2d 3h');
    });

    test('held stale across many polls before reAlertMs -> still ONE alert', async () => {
        const { poll, sent } = setup();
        for (let i = 0; i < 10; i++) await poll(STALE); // 50 min < 60 min
        assert.equal(sent.length, 1);
    });

    test('after reAlertMs -> second alert with a DISTINCT ref (hub dedupe cannot swallow it)', async () => {
        const { poll, sent } = setup();
        for (let i = 0; i < 13; i++) await poll(STALE); // 65 min
        assert.equal(sent.length, 2);
        assert.notEqual(sent[0].ref, sent[1].ref);
        assert.match(sent[1].ref, /:2$/);
        assert.ok(W.DEFAULT_REALERT_MS > 300 * 1000);
    });

    test('stale then release -> exactly one cleared info, then silence', async () => {
        const { poll, sent } = setup();
        await poll(STALE); await poll(FREE); await poll(FREE); await poll(YOUNG);
        assert.equal(sent.length, 2);
        assert.equal(sent[1].type, 'tap-lock-cleared');
        assert.equal(sent[1].severity, 'info');
        assert.match(sent[1].body, /Tap publishing can resume\./);
        assert.ok(!/free or young/.test(sent[1].body));
    });

    test('lock_sha change while stale -> new alert (seq restarts for the new lock)', async () => {
        const { poll, sent } = setup();
        await poll(STALE);
        await poll({ rc: 1, stdout: stdoutFor('stale', { lock_sha: SHA_B }) });
        assert.equal(sent.length, 2);
        assert.match(sent[1].ref, /^tap-writer:bbbbbbbbbbbb:1$/);
    });

    test('one unreadable -> nothing; two consecutive -> one alert; third -> still one', async () => {
        const { poll, sent } = setup();
        await poll(UNREADABLE);
        assert.equal(sent.length, 0);
        await poll(UNREADABLE);
        assert.equal(sent.length, 1);
        assert.match(sent[0].body, /Detail: ls-remote failed/);
        assert.ok(!/ls-remote|consecutive|polls/.test(sent[0].title), 'plain-wording title');
        assert.ok(sent[0].body.includes('From the dev-team repo root, inspect with: scripts/kb-tap-lock.sh status'));
        assert.match(sent[0].body, /for about 10 minutes/, 'derived from interval x threshold');
        assert.ok(!/2 consecutive/.test(sent[0].body));
        await poll(UNREADABLE);
        assert.equal(sent.length, 1);
    });

    test('unreadable minutes are DERIVED from the configured interval', async () => {
        const { poll, sent } = setup({ config: { intervalMs: 3 * MIN } });
        await poll(UNREADABLE); await poll(UNREADABLE);
        assert.match(sent[0].body, /for about 6 minutes/);
    });

    test('a single unreadable blip between healthy polls never alerts (streak resets)', async () => {
        const { poll, sent } = setup();
        for (let i = 0; i < 4; i++) { await poll(UNREADABLE); await poll(FREE); }
        assert.equal(sent.length, 0);
    });

    test('unreadable re-alerts on the interval and clears with one cleared notice', async () => {
        const { poll, sent } = setup();
        for (let i = 0; i < 14; i++) await poll(UNREADABLE);
        assert.equal(sent.length, 2);
        assert.notEqual(sent[0].ref, sent[1].ref);
        await poll(FREE);
        assert.equal(sent.length, 3);
        assert.equal(sent[2].type, 'tap-lock-cleared');
    });

    test('stale -> unreadable (2 polls) emits the unreadable alert, no spurious cleared; then unreadable -> stale emits a stale alert', async () => {
        const { poll, sent } = setup();
        await poll(STALE);
        await poll(UNREADABLE);
        assert.equal(sent.length, 1, 'one blip after a stale alert is held');
        await poll(UNREADABLE);
        assert.equal(sent.length, 2);
        assert.match(sent[1].ref, /^tap-writer:unreadable:/);
        assert.ok(!sent.some((n) => n.type === 'tap-lock-cleared'));
        await poll(STALE);
        assert.equal(sent.length, 3);
        assert.match(sent[2].ref, /^tap-writer:aaaaaaaaaaaa:/);
        assert.ok(!sent.some((n) => n.type === 'tap-lock-cleared'));
    });

    test('an emitter that throws never propagates', async () => {
        const w = W.createTapLockWatcher({
            emit: () => { throw new Error('boom'); }, config: W.resolveTapLockConfig({ FLEET_TAP_LOCK_WATCH: '1' }, { exists: () => true }),
            runner: async () => STALE, exists: () => true, logger: { log() {}, warn() {} },
        });
        await assert.doesNotReject(() => w.pollOnce());
    });
});

describe('fail-closed classification', () => {
    const cases = {
        'timeout': { timedOut: true },
        'spawn error': { error: 'ENOENT' },
        'garbage stdout': { rc: 0, stdout: 'hello\nworld' },
        'missing state (usage error rc 1)': { rc: 1, stdout: 'usage: kb-tap-lock.sh ...' },
        'unknown state': { rc: 0, stdout: 'state=banana\n' },
        'rc/state mismatch (stale with rc 0)': { rc: 0, stdout: stdoutFor('stale') },
        'rc/state mismatch (free with rc 1)': { rc: 1, stdout: stdoutFor('free') },
        'rc/state mismatch (free with rc 2)': { rc: 2, stdout: stdoutFor('free') },
    };
    for (const [name, run] of Object.entries(cases)) {
        test(`${name} -> unreadable`, () => assert.equal(W.classify(run).state, 'unreadable'));
        test(`${name} twice -> one alert`, async () => {
            const { poll, sent } = setup();
            await poll(run); await poll(run);
            assert.equal(sent.length, 1);
            assert.equal(sent[0].type, 'tap-lock-stale');
        });
    }

    test('a runner that throws is unreadable', async () => {
        const { poll, sent, script } = setup();
        script.next = new Error('x');
        await poll(script.next); await poll(script.next);
        assert.equal(sent.length, 1);
    });

    test('a SOURCE that throws counts toward the unreadable streak (2 throws -> 1 unreadable alert), pollOnce never throws', async () => {
        const clock = { t: Date.UTC(2026, 10, 8, 12, 0, 0) };
        const sent = [];
        const config = Object.assign(W.resolveTapLockConfig({ FLEET_TAP_LOCK_WATCH: '1', FLEET_TAP_LOCK_SOURCE: 'github' }, { exists: () => true }), {});
        const w = W.createTapLockWatcher({
            emit: (n) => { sent.push(n); }, now: () => clock.t, config,
            githubReader: async () => { throw new TypeError('boom'); },
            logger: { log() {}, warn() {} }, routeCoverage: () => ({ configured: true, missing: [] }),
        });
        assert.equal(await w.pollOnce(), 'error');
        assert.equal(sent.length, 0, 'one throw tolerated');
        clock.t += 5 * MIN;
        assert.equal(await w.pollOnce(), 'error');
        assert.equal(sent.length, 1);
        assert.equal(sent[0].type, 'tap-lock-stale');
        assert.match(sent[0].body, /Detail: watcher error: TypeError/);
    });

    test('a single source throw between healthy polls never alerts', async () => {
        const clock = { t: 1e9 };
        const sent = [];
        let mode = 'ok';
        const config = W.resolveTapLockConfig({ FLEET_TAP_LOCK_WATCH: '1', FLEET_TAP_LOCK_SOURCE: 'github' }, { exists: () => true });
        const w = W.createTapLockWatcher({
            emit: (n) => { sent.push(n); }, now: () => clock.t, config,
            githubReader: async () => { if (mode === 'throw') throw new Error('x'); return { state: 'free' }; },
            logger: { log() {}, warn() {} }, routeCoverage: () => ({ configured: true, missing: [] }),
        });
        for (let i = 0; i < 3; i++) { mode = 'throw'; await w.pollOnce(); mode = 'ok'; await w.pollOnce(); }
        assert.equal(sent.length, 0);
    });

    test('well-formed pairs classify as reported', () => {
        assert.equal(W.classify(FREE).state, 'free');
        assert.equal(W.classify(YOUNG).state, 'young');
        assert.equal(W.classify(STALE).state, 'stale');
        assert.equal(W.classify(UNREADABLE).state, 'unreadable');
    });
});

describe('parser', () => {
    test('splits on the FIRST "=" only (run_url query strings keep their "=")', () => {
        const kv = W.parseKeyValue('state=stale\nrun_url=https://x/y?a=1&b=2=3\nbreak_cmd=cmd --expect=abc\nnoequals\n=novalue\n');
        assert.equal(kv.run_url, 'https://x/y?a=1&b=2=3');
        assert.equal(kv.break_cmd, 'cmd --expect=abc');
        assert.equal(kv.state, 'stale');
        assert.equal(Object.keys(kv).length, 3);
    });
    test('tolerates CRLF and the first duplicate key wins', () => {
        const kv = W.parseKeyValue('state=free\r\nstate=stale\r\n');
        assert.equal(kv.state, 'free');
    });
    test('formatAge', () => {
        assert.equal(W.formatAge(39900), '11h 05m');
        assert.equal(W.formatAge(42), '42s');
        assert.equal(W.formatAge(300), '5m 00s');
        assert.equal(W.formatAge('junk'), 'unknown age');
    });
});

describe('enablement and invocation', () => {
    test('auto-disabled when the checker is absent: no polling, no runner call, no alert, reason logged', async () => {
        const logs = [];
        const cfg = W.resolveTapLockConfig({}, { exists: () => false });
        assert.equal(cfg.enabled, false);
        assert.match(cfg.reason, /not found/);
        const calls = [];
        const sent = [];
        const w = W.createTapLockWatcher({ emit: (n) => sent.push(n), config: cfg, runner: async (s) => { calls.push(s); return FREE; }, logger: { log: (m) => logs.push(m), warn() {} } });
        w.start();
        assert.equal(await w.pollOnce(), 'disabled');
        w.stop();
        assert.equal(calls.length, 0);
        assert.equal(sent.length, 0);
        assert.ok(logs.some((l) => /disabled/.test(l) && /not found/.test(l)));
    });

    test('FLEET_TAP_LOCK_WATCH=0 disables even when the checker exists; =1 forces on', () => {
        assert.equal(W.resolveTapLockConfig({ FLEET_TAP_LOCK_WATCH: '0' }, { exists: () => true }).enabled, false);
        assert.equal(W.resolveTapLockConfig({}, { exists: () => true }).enabled, true);
        const forced = W.resolveTapLockConfig({ FLEET_TAP_LOCK_WATCH: '1' }, { exists: () => false });
        assert.equal(forced.enabled, true);
        assert.equal(forced.forced, true);
    });

    test('forced on + SOURCE=checker + checker missing -> unreadable alert after 2 polls, runner never spawned', async () => {
        const cfg = W.resolveTapLockConfig({ FLEET_TAP_LOCK_WATCH: '1', FLEET_TAP_LOCK_SOURCE: 'checker' }, { exists: () => false });
        const { poll, sent, calls } = setup({ config: cfg, exists: () => false });
        await poll(FREE); await poll(FREE);
        assert.equal(sent.length, 1);
        assert.equal(sent[0].type, 'tap-lock-stale');
        assert.match(sent[0].body, /missing/);
        assert.equal(calls.length, 0);
    });

    test('invokes the checker with ONLY status --check, the public URL and GIT_TERMINAL_PROMPT=0', async () => {
        const { poll, calls } = setup();
        await poll(FREE);
        assert.equal(calls.length, 1);
        assert.deepEqual(calls[0].args, ['status', '--check']);
        assert.equal(calls[0].env.KB_TAP_LOCK_URL, 'https://github.com/DoubleNode/homebrew-aiteamforge.git');
        assert.equal(calls[0].env.GIT_TERMINAL_PROMPT, '0');
        assert.equal(calls[0].timeoutMs, 60000);
        assert.deepEqual(W.CHECKER_ARGS, ['status', '--check']);
    });

    test('env overrides: url, checker path, interval and reAlert are floored at sane minimums', () => {
        const c = W.resolveTapLockConfig({ FLEET_TAP_LOCK_URL: 'file:///x', FLEET_TAP_LOCK_CHECKER: '/c.sh', FLEET_TAP_LOCK_INTERVAL_MS: '10', FLEET_TAP_LOCK_REALERT_MS: '1000' }, { exists: () => true });
        assert.equal(c.url, 'file:///x');
        assert.equal(c.checkerPath, '/c.sh');
        assert.equal(c.intervalMs, 30000);
        assert.equal(c.reAlertMs, 10 * MIN);
        assert.equal(W.resolveTapLockConfig({}, { exists: () => true }).intervalMs, 5 * MIN);
    });

    test('in-flight guard: an overlapping poll is skipped, not queued', async () => {
        let release; let n = 0;
        const gate = new Promise((r) => { release = r; });
        const w = W.createTapLockWatcher({
            emit() {}, config: W.resolveTapLockConfig({ FLEET_TAP_LOCK_WATCH: '1' }, { exists: () => true }), exists: () => true,
            runner: async () => { n++; await gate; return FREE; }, logger: { log() {}, warn() {} },
        });
        const first = w.pollOnce();
        assert.equal(await w.pollOnce(), 'busy');
        release();
        await first;
        assert.equal(n, 1);
    });

    test('start() schedules an unref()ed timer and stop() cancels it', () => {
        const cfg = W.resolveTapLockConfig({ FLEET_TAP_LOCK_WATCH: '1' }, { exists: () => true });
        const w = W.createTapLockWatcher({ emit() {}, config: cfg, runner: async () => FREE, logger: { log() {}, warn() {} } });
        w.start();
        w.stop(); // would hang the test process if the timer were live and ref'd after stop
    });
});

describe('undelivered alerts are not silent', () => {
    function trackerWith(emitResult) {
        const warns = [];
        const t = W.createTapLockTracker({
            emit: () => emitResult, now: () => Date.UTC(2026, 10, 8, 12, 0, 0),
            logger: { log() {}, warn: (m) => warns.push(m) },
        });
        return { t, warns };
    }
    const flush = () => new Promise((r) => setImmediate(r));

    test('a no-route result (async) logs a loud NOT delivered warning naming the type', async () => {
        const { t, warns } = trackerWith(Promise.resolve({ ok: false, routed: false, reason: 'no-route' }));
        t.observe(W.classify(STALE));
        await flush();
        assert.equal(warns.length, 1, `expected one warning, got ${JSON.stringify(warns)}`);
        assert.match(warns[0], /NOT delivered \(type=tap-lock-stale reason=no-route\)/);
        assert.match(warns[0], /fleet-routes/);
    });

    test('a delivered result logs nothing', async () => {
        const { t, warns } = trackerWith(Promise.resolve({ ok: true, routed: true, delivered: 1 }));
        t.observe(W.classify(STALE));
        await flush();
        assert.deepEqual(warns, []);
    });
});

describe('static: read-only guarantee', () => {
    const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'tap-lock-watcher.js'), 'utf8')
        .replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');

    test('module source never passes break/acquire/release/push (or git write verbs) as an argument', () => {
        assert.doesNotMatch(src, /['"`](break|acquire|release|push)['"`]/);
        assert.doesNotMatch(src, /\bbreak\s+--/);
        assert.doesNotMatch(src, /--force/);
        assert.doesNotMatch(src, /update-ref|git\s+push|send-pack/);
    });
    test('the only checker argument vector in the source is status --check', () => {
        assert.match(src, /Object\.freeze\(\['status', '--check'\]\)/);
        assert.equal((src.match(/CHECKER_ARGS/g) || []).length >= 2, true);
    });
    test('negative control: the guard regex does flag a breaking invocation', () => {
        assert.match("runner({args:['break','--force']})", /['"`](break|acquire|release|push)['"`]/);
    });
});

describe('fleet route coverage warning (XACA-1622-015)', () => {
    function mk(cov, over = {}) {
        const warns = [];
        const config = Object.assign(W.resolveTapLockConfig({ FLEET_TAP_LOCK_WATCH: '1' }, { exists: () => true }), over.config || {});
        const w = W.createTapLockWatcher({
            emit: () => {}, now: () => 1e9, config, runner: async () => FREE, exists: () => true,
            logger: { log() {}, warn: (m) => warns.push(m) }, routeCoverage: cov,
        });
        return { w, warns };
    }
    const routedWarns = (warns) => warns.filter((m) => /WARNING.*not routed/.test(m));

    test('start() warns loudly when the types are not routed', () => {
        const seen = [];
        const { w, warns } = mk((types) => { seen.push(types); return { configured: true, missing: ['tap-lock-stale', 'tap-lock-cleared'] }; });
        w.start(); w.stop();
        assert.deepEqual(seen[0], ['tap-lock-stale', 'tap-lock-cleared']);
        const r = routedWarns(warns);
        assert.equal(r.length, 1);
        assert.match(r[0], /^\[TAP-LOCK\] WARNING/);
        assert.match(r[0], /tap-lock-stale, tap-lock-cleared/);
        assert.match(r[0], /PUT \/api\/notify\/fleet-routes/);
    });

    test('start() is silent when both types are routed', () => {
        const { w, warns } = mk(() => ({ configured: true, missing: [] }));
        w.start(); w.stop();
        assert.equal(routedWarns(warns).length, 0);
    });

    test('names only the MISSING type', () => {
        const { w, warns } = mk(() => ({ configured: true, missing: ['tap-lock-cleared'] }));
        w.start(); w.stop();
        assert.match(routedWarns(warns)[0], /tap-lock-cleared not routed/);
        assert.ok(!/tap-lock-stale/.test(routedWarns(warns)[0]));
    });

    test('hub not wired at start (null) -> deferred to the first poll, then checked exactly once', async () => {
        let ready = false; let calls = 0;
        const { w, warns } = mk(() => { calls += 1; return ready ? { configured: false, missing: ['tap-lock-stale', 'tap-lock-cleared'] } : null; });
        w.start(); w.stop();
        assert.equal(routedWarns(warns).length, 0);
        await w.pollOnce();
        assert.equal(routedWarns(warns).length, 0, 'still not wired');
        ready = true;
        await w.pollOnce(); await w.pollOnce();
        assert.equal(routedWarns(warns).length, 1, 'warned once');
        assert.match(routedWarns(warns)[0], /no fleet routes are set at all/);
        const before = calls;
        await w.pollOnce();
        assert.equal(calls, before, 'no further lookups once resolved');
    });

    test('a throwing coverage accessor never throws out of start() or pollOnce()', async () => {
        const { w } = mk(() => { throw new Error('nope'); });
        w.start(); w.stop();
        assert.equal(await w.pollOnce(), 'free');
    });

    test('a disabled watcher does not check', () => {
        let calls = 0;
        const { w } = mk(() => { calls += 1; return { configured: true, missing: [] }; }, { config: { enabled: false } });
        w.start(); w.stop();
        assert.equal(calls, 0);
    });
});

describe('fleetRouteCoverage accessor (fleet-notices)', () => {
    const FN = require('../lib/fleet-notices');
    test('null before configure; {configured, missing} after; never throws', () => {
        FN._reset();
        assert.equal(FN.fleetRouteCoverage(['a']), null);
        let routes = null;
        FN.configure({ dispatcher: {}, store: { getFleetRoutes: () => routes, catalogTypeIds: () => [] }, logger: { log() {}, warn() {} } });
        assert.deepEqual(FN.fleetRouteCoverage(['tap-lock-stale', 'tap-lock-cleared']), { configured: false, missing: ['tap-lock-stale', 'tap-lock-cleared'] });
        routes = { routes: { 'tap-lock-stale': ['c1'], 'tap-lock-cleared': [] } };
        assert.deepEqual(FN.fleetRouteCoverage(['tap-lock-stale', 'tap-lock-cleared']), { configured: true, missing: ['tap-lock-cleared'] });
        FN.configure({ dispatcher: {}, store: { getFleetRoutes: () => { throw new Error('x'); } }, logger: { log() {}, warn() {} } });
        assert.equal(FN.fleetRouteCoverage(['a']), null);
        FN._reset();
    });
});
