'use strict';

/**
 * XACA-1622-003b: native GitHub REST reader for the tap-writer lock (lib/tap-lock-github.js) and
 * the source selection in lib/tap-lock-watcher.js.
 *
 * Fleet Monitor production (Fly.io) has no git and no scripts/kb-tap-lock.sh, so the checker-backed
 * watcher was a silent no-op there. These tests pin the REST reader's semantics, including a PARITY
 * test against the real `kb-tap-lock.sh status --check` over real lock commits in a fixture bare repo.
 *
 * No network: fetch is always injected. Git fixtures use HOME/GIT_CONFIG_GLOBAL in a temp dir and
 * never export GIT_DIR/GIT_WORK_TREE.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const W = require('../lib/tap-lock-watcher');
const G = require('../lib/tap-lock-github');

const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');
const CHECKER = path.join(REPO_ROOT, 'scripts', 'kb-tap-lock.sh');
const REF = 'refs/locks/tap-writer';
const SHA = 'a'.repeat(40);
const SHA2 = 'b'.repeat(40);
const T0 = Date.UTC(2026, 10, 8, 12, 0, 0);          // fake clock (ms)
const T0S = T0 / 1000;
const TOKEN = 'ghp_SUPERSECRETTOKEN1234567890';

function rec(over = {}) {
    return Object.assign({
        holder: 'publisher-1', host: 'h1', user: 'u', pid: 42, nonce: 'n', ref: REF,
        acquired_at: '2026-11-08T10:00:00Z', acquired_epoch: T0S - 30, run_url: 'https://github.com/o/r/actions/runs/1',
    }, over);
}
const msg = (r) => `kb-tap-lock: acquire\n\n${typeof r === 'string' ? r : JSON.stringify(r)}\n`;

function resp(status, body, headers = {}) {
    const text = typeof body === 'string' ? body : JSON.stringify(body);
    const h = {}; for (const k of Object.keys(headers)) h[k.toLowerCase()] = headers[k];
    return { status, ok: status >= 200 && status < 300, headers: { get: (k) => (h[String(k).toLowerCase()] === undefined ? null : h[String(k).toLowerCase()]) }, text: async () => text };
}

/** Fake GitHub: refs = array for matching-refs; commits = {sha: message}. Records every call. */
function fakeGitHub({ refs = [], commits = {}, refsResp, commitResp } = {}) {
    const calls = [];
    const fetchImpl = async (url, init) => {
        calls.push({ url, init });
        if (/\/git\/matching-refs\//.test(url)) return refsResp ? refsResp(url, init) : resp(200, refs);
        const m = url.match(/\/git\/commits\/([0-9a-f]+)$/);
        if (m) {
            if (commitResp) return commitResp(url, init);
            return commits[m[1]] === undefined ? resp(404, { message: 'Not Found' }) : resp(200, { sha: m[1], message: commits[m[1]] });
        }
        return resp(500, 'unexpected');
    };
    return { fetchImpl, calls };
}
const lockRef = (sha = SHA, type = 'commit', ref = REF) => ({ ref, node_id: 'x', url: 'u', object: { sha, type, url: 'u' } });
const read = (gh, o = {}) => G.readTapLockViaGitHub(Object.assign({ fetchImpl: gh.fetchImpl, now: () => T0, cache: new Map() }, o));

// ---------------------------------------------------------------------------------------------
test('free: empty array -> state free, no commit fetch, request is a plain GET with the documented headers', async () => {
    const gh = fakeGitHub({ refs: [] });
    const r = await read(gh);
    assert.equal(r.state, 'free');
    assert.equal(r.lock_sha, '');
    assert.equal(r.break_cmd, '');
    assert.equal(gh.calls.length, 1);
    assert.equal(gh.calls[0].url, 'https://api.github.com/repos/DoubleNode/homebrew-aiteamforge/git/matching-refs/locks/tap-writer');
    assert.equal(gh.calls[0].init.method, 'GET');
    assert.equal(gh.calls[0].init.headers.Accept, 'application/vnd.github+json');
    assert.equal(gh.calls[0].init.headers['User-Agent'], 'fleet-monitor-tap-lock-watcher');
    assert.equal(gh.calls[0].init.headers['X-GitHub-Api-Version'], '2022-11-28');
    assert.equal('Authorization' in gh.calls[0].init.headers, false, 'no token -> no Authorization header');
});

test('exact-ref filter: a PREFIX match (refs/locks/tap-writer-x) must not count as the lock', async () => {
    const gh = fakeGitHub({ refs: [lockRef(SHA, 'commit', 'refs/locks/tap-writer-x'), lockRef(SHA2, 'commit', 'refs/locks/tap-writer/sub')] });
    const r = await read(gh);
    assert.equal(r.state, 'free');
    assert.equal(gh.calls.length, 1, 'no commit fetched for a non-matching ref');
});

test('exact ref is picked out of a mixed prefix result', async () => {
    const gh = fakeGitHub({ refs: [lockRef(SHA2, 'commit', 'refs/locks/tap-writer-x'), lockRef(SHA)], commits: { [SHA]: msg(rec()) } });
    const r = await read(gh);
    assert.equal(r.state, 'young');
    assert.equal(r.lock_sha, SHA);
});

test('young: fields, age, stale_after and break_cmd match the checker contract', async () => {
    const gh = fakeGitHub({ refs: [lockRef()], commits: { [SHA]: msg(rec()) } });
    const r = await read(gh);
    assert.equal(r.state, 'young');
    assert.equal(r.ref, REF);
    assert.equal(r.lock_sha, SHA);
    assert.equal(r.holder, 'publisher-1');
    assert.equal(r.host, 'h1');
    assert.equal(r.run_url, 'https://github.com/o/r/actions/runs/1');
    assert.equal(r.acquired_at, '2026-11-08T10:00:00Z');
    assert.equal(r.age, 30);
    assert.equal(r.stale_after, 3600);
    assert.equal(r.break_cmd, `scripts/kb-tap-lock.sh break --force --expect ${SHA}`);
    assert.equal(r.reason, '');
});

test('stale: age > stale_after (strict); exactly stale_after is still young', async () => {
    const mk = (age) => fakeGitHub({ refs: [lockRef()], commits: { [SHA]: msg(rec({ acquired_epoch: T0S - age })) } });
    assert.equal((await read(mk(7200))).state, 'stale');
    assert.equal((await read(mk(3601))).state, 'stale');
    assert.equal((await read(mk(3600))).state, 'young');
    const custom = await read(mk(120), { staleAfterSec: 60 });
    assert.equal(custom.state, 'stale');
    assert.equal(custom.stale_after, 60);
});

test('skew: small negative age -> age 0 young; beyond tolerance -> unreadable', async () => {
    const small = await read(fakeGitHub({ refs: [lockRef()], commits: { [SHA]: msg(rec({ acquired_epoch: T0S + 60 })) } }));
    assert.equal(small.state, 'young');
    assert.equal(small.age, 0);
    const edge = await read(fakeGitHub({ refs: [lockRef()], commits: { [SHA]: msg(rec({ acquired_epoch: T0S + 300 })) } }));
    assert.equal(edge.state, 'young', 'exactly the tolerance is accepted (checker uses -gt)');
    const big = await read(fakeGitHub({ refs: [lockRef()], commits: { [SHA]: msg(rec({ acquired_epoch: T0S + 301 })) } }));
    assert.equal(big.state, 'unreadable');
    assert.match(big.reason, /negative beyond clock-skew/);
    assert.equal(big.lock_sha, SHA, 'sha is still reported so a human can act');
    const wide = await read(fakeGitHub({ refs: [lockRef()], commits: { [SHA]: msg(rec({ acquired_epoch: T0S + 901 })) } }), { skewSec: 1000 });
    assert.equal(wide.state, 'young');
});

test('garbage / missing record and bad epoch fail closed with a reason', async () => {
    const cases = {
        'no record line': { m: 'kb-tap-lock: acquire\n\nnot json at all\n', re: /lock record unreadable/ },
        'garbage record': { m: msg('{garbage'), re: /age unknown/ },
        'epoch is text': { m: msg(rec({ acquired_epoch: 'abc' })), re: /age unknown/ },
        'epoch is decimal': { m: msg('{"holder":"x","acquired_epoch":12.5}'), re: /age unknown/ },
        'epoch missing': { m: msg('{"holder":"x"}'), re: /age unknown/ },
        'empty message': { m: '', re: /lock record unreadable/ },
    };
    for (const [name, c] of Object.entries(cases)) {
        const r = await read(fakeGitHub({ refs: [lockRef()], commits: { [SHA]: c.m } }));
        assert.equal(r.state, 'unreadable', name);
        assert.match(r.reason, c.re, name);
        assert.equal(r.lock_sha, SHA, `${name}: sha kept`);
        assert.equal(r.age, null, name);
    }
});

test('record = FIRST line starting with { (a later one is ignored)', async () => {
    const m = `subject\n\n${JSON.stringify(rec({ holder: 'first' }))}\n${JSON.stringify(rec({ holder: 'second' }))}\n`;
    const r = await read(fakeGitHub({ refs: [lockRef()], commits: { [SHA]: m } }));
    assert.equal(r.holder, 'first');
});

test('object.type other than commit -> unreadable', async () => {
    const r = await read(fakeGitHub({ refs: [lockRef(SHA, 'tag')] }));
    assert.equal(r.state, 'unreadable');
    assert.match(r.reason, /tag object, not a commit/);
});

test('malformed sha in the ref object -> unreadable (never interpolated into a URL)', async () => {
    const gh = fakeGitHub({ refs: [lockRef('../../etc/passwd')] });
    const r = await read(gh);
    assert.equal(r.state, 'unreadable');
    assert.equal(gh.calls.length, 1);
});

test('HTTP and transport failures are unreadable with a reason', async () => {
    const cases = {
        'matching-refs 404': [{ refsResp: () => resp(404, { message: 'Not Found' }) }, /HTTP 404/],
        'matching-refs 500': [{ refsResp: () => resp(500, 'boom') }, /HTTP 500/],
        'matching-refs 403 rate limit': [{ refsResp: () => resp(403, { message: 'API rate limit exceeded' }, { 'X-RateLimit-Reset': '1793000000' }) }, /rate limit.*X-RateLimit-Reset=1793000000/],
        'matching-refs 429': [{ refsResp: () => resp(429, '') }, /rate limit/],
        'matching-refs non-JSON': [{ refsResp: () => resp(200, '<html>nope</html>') }, /not valid JSON/],
        'matching-refs object not array': [{ refsResp: () => resp(200, { ref: REF }) }, /not an array/],
        'matching-refs throws': [{ refsResp: () => { throw new TypeError('socket hang up'); } }, /request failed \(TypeError\)/],
        'commit 500': [{ refs: [lockRef()], commitResp: () => resp(500, 'x') }, /HTTP 500/],
        'commit 403 rate limit': [{ refs: [lockRef()], commitResp: () => resp(403, '', { 'x-ratelimit-reset': '1793000000' }) }, /rate limit.*1793000000/],
        'commit non-JSON': [{ refs: [lockRef()], commitResp: () => resp(200, 'garbage') }, /not valid JSON/],
        'commit without message': [{ refs: [lockRef()], commitResp: () => resp(200, { sha: SHA }) }, /no message/],
        'commit throws': [{ refs: [lockRef()], commitResp: () => { throw new Error('ECONNRESET'); } }, /request failed \(Error\)/],
    };
    for (const [name, [cfg, re]] of Object.entries(cases)) {
        const r = await read(fakeGitHub(cfg));
        assert.equal(r.state, 'unreadable', name);
        assert.match(r.reason, re, name);
    }
});

test('timeout: a fetch that never settles -> unreadable "timed out" (AbortController + race)', async () => {
    let aborted = false;
    const fetchImpl = (url, init) => new Promise(() => { init.signal.addEventListener('abort', () => { aborted = true; }); });
    const r = await G.readTapLockViaGitHub({ fetchImpl, now: () => T0, timeoutMs: 25, cache: new Map() });
    assert.equal(r.state, 'unreadable');
    assert.match(r.reason, /timed out/);
    assert.equal(aborted, true, 'the request was aborted');
});

test('no fetch implementation -> unreadable, never throws', async () => {
    const saved = globalThis.fetch;
    try {
        globalThis.fetch = undefined;
        const r2 = await G.readTapLockViaGitHub({ now: () => T0 });
        assert.equal(r2.state, 'unreadable');
        assert.match(r2.reason, /no fetch/);
    } finally { globalThis.fetch = saved; }
});

test('commit cache: two polls on the same sha -> ONE commit fetch (held lock = 1 req/poll)', async () => {
    const gh = fakeGitHub({ refs: [lockRef()], commits: { [SHA]: msg(rec()) } });
    const cache = new Map();
    const r1 = await G.readTapLockViaGitHub({ fetchImpl: gh.fetchImpl, now: () => T0, cache });
    const r2 = await G.readTapLockViaGitHub({ fetchImpl: gh.fetchImpl, now: () => T0 + 60000, cache });
    const commitCalls = gh.calls.filter((c) => /\/commits\//.test(c.url)).length;
    const refCalls = gh.calls.filter((c) => /matching-refs/.test(c.url)).length;
    assert.equal(commitCalls, 1);
    assert.equal(refCalls, 2);
    assert.equal(r1.age, 30);
    assert.equal(r2.age, 90, 'age is recomputed from the cached record against the new clock');
    // a different sha is fetched
    const gh2 = fakeGitHub({ refs: [lockRef(SHA2)], commits: { [SHA2]: msg(rec()) } });
    await G.readTapLockViaGitHub({ fetchImpl: gh2.fetchImpl, now: () => T0, cache });
    assert.equal(gh2.calls.filter((c) => /\/commits\//.test(c.url)).length, 1);
});

test('failed commit fetches are NOT cached', async () => {
    let fail = true;
    const gh = fakeGitHub({ refs: [lockRef()], commitResp: () => (fail ? resp(500, 'x') : resp(200, { message: msg(rec()) })) });
    const cache = new Map();
    const a = await G.readTapLockViaGitHub({ fetchImpl: gh.fetchImpl, now: () => T0, cache });
    fail = false;
    const b = await G.readTapLockViaGitHub({ fetchImpl: gh.fetchImpl, now: () => T0, cache });
    assert.equal(a.state, 'unreadable');
    assert.equal(b.state, 'young');
});

test('token: sent as Bearer only when set, and never appears in any reason or notice', async () => {
    const withTok = fakeGitHub({ refs: [lockRef()], commits: { [SHA]: msg(rec()) } });
    await read(withTok, { token: TOKEN });
    for (const c of withTok.calls) assert.equal(c.init.headers.Authorization, `Bearer ${TOKEN}`);

    // failure paths that could echo the token: thrown error text, HTTP body, rate-limit reset header
    const leaky = [
        { refsResp: () => { throw new Error(`connect failed using ${TOKEN}`); } },
        { refsResp: () => resp(403, `Bad credentials ${TOKEN}`, { 'x-ratelimit-reset': TOKEN }) },
        { refs: [lockRef()], commitResp: () => resp(200, `${TOKEN} not json`) },
    ];
    for (const cfg of leaky) {
        const r = await read(fakeGitHub(cfg), { token: TOKEN });
        assert.equal(r.state, 'unreadable');
        assert.equal(JSON.stringify(r).includes(TOKEN), false, `leak in ${JSON.stringify(r)}`);
    }

    // through the watcher: the notice an operator receives
    const emitted = [];
    const cfg = W.resolveTapLockConfig({ FLEET_TAP_LOCK_WATCH: '1', FLEET_TAP_LOCK_GITHUB_TOKEN: TOKEN }, { exists: () => false });
    assert.equal(cfg.githubToken, TOKEN);
    const clock = { t: T0 };
    const w = W.createTapLockWatcher({
        config: cfg, emit: (n) => { emitted.push(n); }, now: () => clock.t,
        fetchImpl: async () => { throw new Error(`boom ${TOKEN}`); },
        logger: { log() {}, warn() {} },
    });
    await w.pollOnce(); clock.t += 300000; await w.pollOnce();
    assert.equal(emitted.length, 1, 'unreadable twice -> one notice');
    assert.equal(JSON.stringify(emitted).includes(TOKEN), false);
    assert.equal(JSON.stringify(cfg.reason).includes(TOKEN), false);
});

test('field extraction mirrors the checker: redacts url credentials, strips control chars, no commas in values', () => {
    assert.equal(G.recordField('{"holder":"a b","host":"h"}', 'holder'), 'a b');
    assert.equal(G.recordField('{"holder": "x" , "pid": 7}', 'pid'), '7');
    assert.equal(G.recordField('{"holder":"x"}', 'nope'), '');
});

test('run_url with embedded credentials is redacted like the checker does', async () => {
    const r = await read(fakeGitHub({ refs: [lockRef()], commits: { [SHA]: msg(rec({ run_url: 'https://user:tok@github.com/o/r' })) } }));
    assert.equal(r.run_url, 'https://***@github.com/o/r');
});

// ---------------------------------------------------------------------------------------------
// Source selection
test('source selection matrix: SOURCE x checker present/absent x WATCH 0/1/unset', () => {
    const rows = [];
    for (const source of [undefined, 'auto', 'github', 'checker']) {
        for (const present of [true, false]) {
            for (const watch of [undefined, '0', '1']) {
                const env = {};
                if (source !== undefined) env.FLEET_TAP_LOCK_SOURCE = source;
                if (watch !== undefined) env.FLEET_TAP_LOCK_WATCH = watch;
                const c = W.resolveTapLockConfig(env, { exists: () => present });
                const expSource = source === 'github' ? 'github' : source === 'checker' ? 'checker' : (present ? 'checker' : 'github');
                const expEnabled = watch === '0' ? false : watch === '1' ? true : present;
                assert.equal(c.source, expSource, `source for ${JSON.stringify({ source, present, watch })}`);
                assert.equal(c.enabled, expEnabled, `enabled for ${JSON.stringify({ source, present, watch })}`);
                rows.push(c);
            }
        }
    }
    assert.equal(rows.length, 24);
    // the Fly.io case: WATCH=1, no checker, default source -> github, enabled, NOT a "missing checker" alert
    const fly = W.resolveTapLockConfig({ FLEET_TAP_LOCK_WATCH: '1' }, { exists: () => false });
    assert.deepEqual([fly.enabled, fly.source], [true, 'github']);
    assert.doesNotMatch(fly.reason, /missing/);
    // unknown SOURCE text behaves like auto
    assert.equal(W.resolveTapLockConfig({ FLEET_TAP_LOCK_SOURCE: 'bogus', FLEET_TAP_LOCK_WATCH: '1' }, { exists: () => false }).source, 'github');
    assert.equal(W.resolveTapLockConfig({ FLEET_TAP_LOCK_SOURCE: 'bogus' }, { exists: () => true }).source, 'checker');
});

test('config: default interval stays 5 min; stale/skew env honoured with safe fallbacks', () => {
    const c = W.resolveTapLockConfig({}, { exists: () => false });
    assert.equal(c.intervalMs, 5 * 60 * 1000);
    assert.equal(c.staleAfterSec, 3600);
    assert.equal(c.skewSec, 300);
    const d = W.resolveTapLockConfig({ KB_TAP_LOCK_STALE_AFTER: '120', KB_TAP_LOCK_CHECK_SKEW: '10' }, { exists: () => false });
    assert.equal(d.staleAfterSec, 120);
    assert.equal(d.skewSec, 10);
    assert.equal(W.resolveTapLockConfig({ KB_TAP_LOCK_STALE_AFTER: '0x', KB_TAP_LOCK_CHECK_SKEW: '-3' }, { exists: () => false }).staleAfterSec, 3600);
});

test('watcher over the github source: stale alert with break cmd, GET-only, startup log names source', async () => {
    const cfg = W.resolveTapLockConfig({ FLEET_TAP_LOCK_WATCH: '1' }, { exists: () => false });
    const gh = fakeGitHub({ refs: [lockRef()], commits: { [SHA]: msg(rec({ acquired_epoch: T0S - 7200, holder: 'dead-run' })) } });
    const emitted = []; const logs = [];
    const w = W.createTapLockWatcher({
        config: cfg, emit: (n) => { emitted.push(n); }, now: () => T0, fetchImpl: gh.fetchImpl,
        runner: async () => { throw new Error('checker must not run'); },
        logger: { log: (m) => logs.push(m), warn() {} },
    });
    w.start(); w.stop();
    assert.ok(logs.some((l) => /enabled/.test(l) && /source=github/.test(l) && /polling every 300s/.test(l)), JSON.stringify(logs));
    assert.equal(await w.pollOnce(), 'stale');
    assert.equal(emitted.length, 1);
    assert.equal(emitted[0].type, 'tap-lock-stale');
    assert.match(emitted[0].title, /dead-run/);
    assert.match(emitted[0].body, new RegExp(`break --force --expect ${SHA}`));
    assert.ok(emitted[0].ref.startsWith(`tap-writer:${SHA.slice(0, 12)}:1`));
    assert.ok(gh.calls.length >= 1 && gh.calls.every((c) => c.init.method === 'GET'));
    // then released -> cleared
    gh.calls.length = 0;
    const gh2 = fakeGitHub({ refs: [] });
    const w2 = W.createTapLockWatcher({ config: cfg, emit: (n) => { emitted.push(n); }, now: () => T0, fetchImpl: gh2.fetchImpl, logger: { log() {}, warn() {} } });
    assert.equal(await w2.pollOnce(), 'free');
});

test('watcher: checker source still uses the runner and never touches fetch', async () => {
    const cfg = W.resolveTapLockConfig({ FLEET_TAP_LOCK_WATCH: '1', FLEET_TAP_LOCK_SOURCE: 'checker' }, { exists: () => true });
    let ran = 0;
    const w = W.createTapLockWatcher({
        config: cfg, emit() {}, exists: () => true,
        runner: async () => { ran++; return { rc: 0, stdout: 'state=free\n' }; },
        fetchImpl: async () => { throw new Error('fetch must not run'); }, logger: { log() {}, warn() {} },
    });
    assert.equal(await w.pollOnce(), 'free');
    assert.equal(ran, 1);
});

// ---------------------------------------------------------------------------------------------
describe_static();
function describe_static() {
    const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'tap-lock-github.js'), 'utf8')
        .replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
    test('static: the GitHub reader is GET-only (no other HTTP verb, no write endpoints)', () => {
        const methods = src.match(/method:\s*['"`][A-Za-z]+['"`]/g) || [];
        assert.deepEqual(methods, ["method: 'GET'"]);
        assert.doesNotMatch(src, /\b(POST|PUT|PATCH|DELETE)\b/);
        assert.doesNotMatch(src, /child_process|execFile|spawn/);
        assert.doesNotMatch(src, /\/git\/refs\b|\/git\/(blobs|trees|tags)\b/, 'only matching-refs and commits are read');
    });
    test('negative control: the guard flags a write verb', () => {
        assert.deepEqual("fetch(u,{method: 'DELETE'})".match(/method:\s*['"`][A-Za-z]+['"`]/g), ["method: 'DELETE'"]);
    });
}

// ---------------------------------------------------------------------------------------------
// PARITY against the real checker over real lock commits.
const haveTools = ['git', 'bash'].every((t) => spawnSync(t, ['--version'], { encoding: 'utf8' }).status === 0);
const PD = { skip: !haveTools ? 'SKIP: git and/or bash not available' : (!fs.existsSync(CHECKER) ? 'SKIP: scripts/kb-tap-lock.sh absent' : false) };

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1622-003b.'));
test.after(() => { try { fs.rmSync(TMP, { recursive: true, force: true }); } catch (_) { /* best effort */ } });
fs.mkdirSync(path.join(TMP, 'home'));
fs.writeFileSync(path.join(TMP, 'gitconfig'), '');
const ENV = {
    PATH: process.env.PATH, HOME: path.join(TMP, 'home'), GIT_CONFIG_GLOBAL: path.join(TMP, 'gitconfig'),
    GIT_CONFIG_NOSYSTEM: '1', GIT_TERMINAL_PROMPT: '0', KB_TAP_LOCK_REF: REF, KB_TAP_LOCK_STATE_FILE: path.join(TMP, 'state'),
};
function git(cwd, args, input) {
    const r = spawnSync('git', args, { cwd, env: ENV, encoding: 'utf8', input });
    assert.equal(r.status, 0, `git ${args.join(' ')} failed: ${r.stderr}`);
    return r.stdout;
}
let seq = 0;
function plantMessage(server, message) {
    const m = path.join(TMP, `mint${++seq}.git`);
    git(TMP, ['init', '--bare', '-q', m]);
    const tree = git(m, ['hash-object', '-t', 'tree', '-w', '/dev/null']).trim();
    const sha = git(m, ['-c', 'user.name=t', '-c', 'user.email=t@l', 'commit-tree', tree], message).trim();
    git(m, ['push', '-q', '--force', server, `${sha}:${REF}`]);
    return sha;
}

test('PARITY: REST reader == real `kb-tap-lock.sh status --check` over real lock commits', PD, async () => {
    const nowS = () => Math.floor(Date.now() / 1000);
    const messages = {
        young: () => msg(rec({ acquired_epoch: nowS() - 45 })),
        stale: () => msg(rec({ acquired_epoch: nowS() - 7200, holder: 'dead-run', host: 'runner-9' })),
        'stale + url creds': () => msg(rec({ acquired_epoch: nowS() - 5000, run_url: 'https://u:t@github.com/o/r/actions/runs/9' })),
        'small skew': () => msg(rec({ acquired_epoch: nowS() + 120 })),
        'large skew': () => msg(rec({ acquired_epoch: nowS() + 4000 })),
        garbage: () => 'kb-tap-lock: acquire\n\n{garbage\n',
        'no record': () => 'kb-tap-lock: acquire\n\nnothing here\n',
        'bad epoch': () => msg(rec({ acquired_epoch: 'soon' })),
        'decimal epoch': () => msg('{"holder":"x","acquired_epoch":12.5,"run_url":"u"}'),
        'record after prose': () => `kb-tap-lock: acquire\n\nsome prose\n${JSON.stringify(rec({ acquired_epoch: nowS() - 10, holder: 'later-line' }))}\n`,
        'two records': () => `s\n\n${JSON.stringify(rec({ acquired_epoch: nowS() - 10, holder: 'first' }))}\n${JSON.stringify(rec({ holder: 'second' }))}\n`,
    };
    for (const [name, make] of Object.entries(messages)) {
        const server = path.join(TMP, `tap${++seq}.git`);
        git(TMP, ['init', '--bare', '-q', server]);
        const message = make();
        const sha = plantMessage(server, message);

        const run = spawnSync('bash', [CHECKER, 'status', '--check'], { env: Object.assign({}, ENV, { KB_TAP_LOCK_URL: server }), encoding: 'utf8' });
        const real = W.classify({ rc: run.status, stdout: run.stdout });

        // serve the message exactly as stored in the commit object
        const stored = git(server, ['cat-file', 'commit', sha]).split('\n\n').slice(1).join('\n\n');
        const gh = fakeGitHub({ refs: [lockRef(sha)], commits: { [sha]: stored } });
        const mine = await G.readTapLockViaGitHub({ fetchImpl: gh.fetchImpl, now: Date.now, cache: new Map() });

        assert.equal(mine.state, real.state, `${name}: state (checker said ${real.state}, reason=${real.reason})`);
        assert.equal(mine.lock_sha, real.lock_sha, `${name}: lock_sha`);
        assert.equal(mine.holder, real.holder, `${name}: holder`);
        assert.equal(mine.host, real.host, `${name}: host`);
        assert.equal(mine.run_url, real.run_url, `${name}: run_url`);
        assert.equal(mine.acquired_at, real.acquired_at, `${name}: acquired_at`);
        assert.equal(mine.break_cmd, real.break_cmd, `${name}: break_cmd`);
        assert.equal(mine.reason, real.reason, `${name}: reason`);
        assert.equal(String(mine.stale_after), real.stale_after, `${name}: stale_after`);
        if (real.age === '') assert.equal(mine.age, null, `${name}: age empty`);
        else assert.ok(Math.abs(mine.age - Number(real.age)) <= 2, `${name}: age ${mine.age} vs ${real.age}`);
    }
});

test('PARITY: a free server is free in both', PD, async () => {
    const server = path.join(TMP, `tap${++seq}.git`);
    git(TMP, ['init', '--bare', '-q', server]);
    const run = spawnSync('bash', [CHECKER, 'status', '--check'], { env: Object.assign({}, ENV, { KB_TAP_LOCK_URL: server }), encoding: 'utf8' });
    const real = W.classify({ rc: run.status, stdout: run.stdout });
    const mine = await G.readTapLockViaGitHub({ fetchImpl: fakeGitHub({ refs: [] }).fetchImpl, now: Date.now, cache: new Map() });
    assert.equal(real.state, 'free');
    assert.equal(mine.state, 'free');
    assert.equal(mine.break_cmd, real.break_cmd);
});
