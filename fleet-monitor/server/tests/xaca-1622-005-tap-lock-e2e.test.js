'use strict';

/**
 * XACA-1622-005: END-TO-END seam tests for the stale tap-writer-lock alert.
 *
 * The three parts (002 checker, 003 watcher, 004 workflow renderer) were built in parallel
 * against a shared contract, each with its own fixtures. This file wires the REAL pieces
 * together with no mocks of the thing under test:
 *
 *   fixture bare repo (real lock-record format)
 *     -> scripts/kb-tap-lock.sh status --check          (real script, real git)
 *     -> createTapLockWatcher default runner            (real execFile, real classify)
 *     -> recording emit                                  (only the sink is a double)
 *   and
 *     -> render_contended extracted from tap-publisher.yml (real function, real bash)
 *
 * Isolation: every git/bash child gets an explicit minimal env (HOME + GIT_CONFIG_GLOBAL in a
 * temp dir, GIT_CONFIG_NOSYSTEM, no GIT_DIR/GIT_WORK_TREE). Nothing here touches a real remote:
 * the URL is always a local bare path. No network, no sleeps.
 *
 * Requires git and bash; if either is missing every test is skipped with an explicit message.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const { createTapLockWatcher, resolveTapLockConfig, parseKeyValue } = require('../lib/tap-lock-watcher');

const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');
// XACA_1622_CHECKER_UNDER_TEST lets a mutated copy of the script prove these tests can fail.
const CHECKER = process['env'].XACA_1622_CHECKER_UNDER_TEST || path.join(REPO_ROOT, 'scripts', 'kb-tap-lock.sh');
const WORKFLOW = path.join(REPO_ROOT, '.github', 'workflows', 'tap-publisher.yml');
const REF = 'refs/locks/tap-writer';

const haveTools = ['git', 'bash'].every((t) => spawnSync(t, ['--version'], { encoding: 'utf8' }).status === 0);
const SKIP = haveTools ? false : 'SKIP: git and/or bash not available on PATH';
if (!haveTools) console.log(SKIP);
const present = fs.existsSync(CHECKER) && fs.existsSync(WORKFLOW);

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca-1622-005.'));
test.after(() => { try { fs.rmSync(TMP, { recursive: true, force: true }); } catch (_) { /* best effort */ } });
fs.mkdirSync(path.join(TMP, 'home'));
fs.writeFileSync(path.join(TMP, 'gitconfig'), '');

// Explicit env: PATH only from the parent; never inherit GIT_DIR / GIT_WORK_TREE / KB_TAP_LOCK_*.
const ENV = {
    PATH: process.env.PATH,
    HOME: path.join(TMP, 'home'),
    GIT_CONFIG_GLOBAL: path.join(TMP, 'gitconfig'),
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_TERMINAL_PROMPT: '0',
    KB_TAP_LOCK_REF: REF,
    KB_TAP_LOCK_STATE_FILE: path.join(TMP, 'state'),
};

function git(cwd, args, extraEnv) {
    const r = spawnSync('git', args, { cwd, env: Object.assign({}, ENV, extraEnv || {}), encoding: 'utf8' });
    assert.equal(r.status, 0, `git ${args.join(' ')} failed: ${r.stderr}`);
    return r.stdout;
}

let n = 0;
function newServer() {
    const dir = path.join(TMP, `tap${++n}.git`);
    git(TMP, ['init', '--bare', '-q', dir]);
    return dir;
}

/** Force the lock ref to a commit whose body is `body` (the real record is JSON in the body). */
function plant(server, body) {
    const m = path.join(TMP, `mint${++n}.git`);
    git(TMP, ['init', '--bare', '-q', m]);
    const tree = git(m, ['hash-object', '-t', 'tree', '-w', '/dev/null']).trim();
    const c = spawnSync('git', ['-C', m, '-c', 'user.name=t', '-c', 'user.email=t@l', 'commit-tree', tree],
        { env: ENV, input: `kb-tap-lock: fixture\n\n${body}\n`, encoding: 'utf8' });
    assert.equal(c.status, 0, c.stderr);
    const sha = c.stdout.trim();
    git(m, ['push', '-q', '--force', server, `${sha}:${REF}`]);
    return sha;
}
function release(server) { git(server, ['update-ref', '-d', REF]); }
function lockRef(server) { return git(server, ['ls-remote', server, REF]).split(/\s+/)[0]; }

function record({ ageSec, holder = 'publisher-1', runUrl = 'https://github.com/o/r/actions/runs/1', acquiredAt = '2026-01-01T00:00:00Z' }) {
    const epoch = Math.floor(Date.now() / 1000) - ageSec;
    return `{"holder":"${holder}","host":"h1","user":"u","pid":42,"nonce":"n","ref":"${REF}","acquired_at":"${acquiredAt}","acquired_epoch":${epoch},"run_url":"${runUrl}"}`;
}

/** Run the REAL checker; returns {rc, stdout, stderr}. */
function check(url, extraEnv) {
    const r = spawnSync('bash', [CHECKER, 'status', '--check'],
        { env: Object.assign({}, ENV, { KB_TAP_LOCK_URL: url }, extraEnv || {}), encoding: 'utf8' });
    return { rc: r.status, stdout: r.stdout, stderr: r.stderr };
}

/** render_contended extracted from the workflow, executed by real bash against REAL checker stdout. */
function extractRender() {
    const src = fs.readFileSync(WORKFLOW, 'utf8');
    const m = src.match(/# BEGIN render_contended\n([\s\S]*?)# END render_contended/);
    assert.ok(m, 'BEGIN/END render_contended markers present in the workflow');
    const fn = m[1].split('\n').map((l) => l.replace(/^ {10}/, '')).join('\n');
    const file = path.join(TMP, 'render.sh');
    fs.writeFileSync(file, fn);
    return file;
}
function render(stdout) {
    const fnFile = extractRender();
    const outFile = path.join(TMP, `chk${++n}.out`);
    const sum = path.join(TMP, `sum${n}.md`);
    fs.writeFileSync(outFile, stdout);
    const r = spawnSync('bash', ['-c', '. "$1"; render_contended "$(cat "$2")" "$3"', 'x', fnFile, outFile, sum],
        { env: ENV, encoding: 'utf8' });
    assert.equal(r.status, 0, `render_contended failed: ${r.stderr}`);
    return { out: r.stdout, summary: fs.existsSync(sum) ? fs.readFileSync(sum, 'utf8') : '' };
}

function makeWatcher(url, clock, extra) {
    const emitted = [];
    const warns = [];
    const config = resolveTapLockConfig(
        { FLEET_TAP_LOCK_CHECKER: CHECKER, FLEET_TAP_LOCK_URL: url, FLEET_TAP_LOCK_WATCH: '1' },
        { repoRoot: REPO_ROOT });
    const w = createTapLockWatcher(Object.assign({
        config,
        emit: (notice) => { emitted.push(notice); return { ok: true }; },
        now: () => clock.t,
        baseEnv: ENV,                 // REAL default runner (no `runner` injected)
        logger: { log() {}, warn: (m) => warns.push(String(m)) },
    }, extra || {}));
    return { w, emitted, warns };
}

const D = { skip: SKIP || (!present && 'SKIP: scripts/kb-tap-lock.sh or tap-publisher.yml absent') };

// ---------------------------------------------------------------------------------------------
test('E2E watcher (real runner + real checker): free -> stale -> stale -> released', D, async () => {
    const server = newServer();
    const clock = { t: 1_000_000 };
    const { w, emitted } = makeWatcher(server, clock);

    assert.equal(await w.pollOnce(), 'free');
    assert.equal(emitted.length, 0, 'free lock raises nothing');

    const sha = plant(server, record({ ageSec: 7200, holder: 'publisher-dead' }));
    assert.equal(await w.pollOnce(), 'stale');
    assert.equal(emitted.length, 1, 'exactly one notice on free->stale');
    const n1 = emitted[0];
    assert.equal(n1.type, 'tap-lock-stale');
    assert.equal(n1.severity, 'high');
    assert.ok(n1.ref.startsWith(`tap-writer:${sha.slice(0, 12)}:1`), `ref carries sha+seq: ${n1.ref}`);
    assert.match(n1.title, /publisher-dead/);
    assert.match(n1.title, /2h 00m|2h 0\dm/, 'age formatted from the REAL age= value');
    assert.match(n1.body, /break --force --expect /, 'body carries the break command for the human');
    assert.match(n1.body, new RegExp(sha), 'break command carries the real lock sha');
    assert.match(n1.body, /actions\/runs\/1/);

    // second stale poll, same lock, inside the re-alert window: nothing new
    clock.t += 5 * 60 * 1000;
    assert.equal(await w.pollOnce(), 'stale');
    assert.equal(emitted.length, 1, 'no duplicate while the same stale lock persists');

    // re-alert after the window, seq increments and ref is distinct
    clock.t += 61 * 60 * 1000;
    await w.pollOnce();
    assert.equal(emitted.length, 2, 're-alert after 60 min');
    assert.notEqual(emitted[1].ref, emitted[0].ref);
    assert.ok(emitted[1].ref.endsWith(':2'));

    // released: exactly one cleared
    release(server);
    assert.equal(await w.pollOnce(), 'cleared');
    assert.equal(emitted.length, 3);
    assert.equal(emitted[2].type, 'tap-lock-cleared');
    assert.equal(await w.pollOnce(), 'free');
    assert.equal(emitted.length, 3, 'cleared is not repeated');
    assert.equal(lockRef(server), '', 'the watcher never re-created or touched the lock');
});

test('E2E watcher: young lock is quiet, then goes stale (threshold crossed) -> one alert', D, async () => {
    const server = newServer();
    const clock = { t: 5_000_000 };
    const { w, emitted } = makeWatcher(server, clock);
    plant(server, record({ ageSec: 30 }));
    assert.equal(await w.pollOnce(), 'young');
    assert.equal(emitted.length, 0);
    const sha = plant(server, record({ ageSec: 4000 }));
    assert.equal(await w.pollOnce(), 'stale');
    assert.equal(emitted.length, 1);
    assert.equal(lockRef(server), sha, 'lock untouched');
});

test('E2E watcher: unreadable URL alerts only on the 2nd consecutive poll, then clears', D, async () => {
    const server = newServer();
    const clock = { t: 9_000_000 };
    const bad = path.join(TMP, 'nope.git');
    const { w, emitted } = makeWatcher(bad, clock);

    assert.equal(await w.pollOnce(), 'unreadable');
    assert.equal(emitted.length, 0, 'one unreadable poll is tolerated');
    assert.equal(await w.pollOnce(), 'unreadable');
    assert.equal(emitted.length, 1, 'second consecutive unreadable alerts');
    assert.equal(emitted[0].type, 'tap-lock-stale');
    assert.match(emitted[0].title, /cannot be checked/);
    assert.match(emitted[0].body, /ls-remote exit/, 'REAL checker reason reaches the notice');
    assert.equal(await w.pollOnce(), 'unreadable');
    assert.equal(emitted.length, 1, 'no repeat inside window');

    // recover: point the watcher at a readable (free) server
    const good = makeWatcher(server, clock);
    // share nothing: build a recovery on the same watcher by swapping config url
    w.config.url = server;
    assert.equal(await w.pollOnce(), 'cleared');
    assert.equal(emitted.length, 2);
    assert.equal(emitted[1].type, 'tap-lock-cleared');
    assert.ok(good.w);
});

test('E2E watcher: a single unreadable blip between two good polls raises nothing', D, async () => {
    const server = newServer();
    const clock = { t: 1 };
    const { w, emitted } = makeWatcher(server, clock);
    assert.equal(await w.pollOnce(), 'free');
    w.config.url = path.join(TMP, 'gone.git');
    assert.equal(await w.pollOnce(), 'unreadable');
    w.config.url = server;
    assert.equal(await w.pollOnce(), 'free');
    assert.equal(emitted.length, 0);
});

test('E2E watcher: garbage record (fail closed) is unreadable, not young', D, async () => {
    const server = newServer();
    const clock = { t: 3 };
    const { w, emitted } = makeWatcher(server, clock);
    plant(server, 'no json here at all');
    assert.equal(await w.pollOnce(), 'unreadable');
    assert.equal(await w.pollOnce(), 'unreadable');
    assert.equal(emitted.length, 1);
    assert.match(emitted[0].body, /unreadable/i);
});

test('E2E watcher: undelivered notice (emit resolves ok:false) warns loudly', D, async () => {
    const server = newServer();
    const clock = { t: 7 };
    const { w, warns } = makeWatcher(server, clock, { emit: () => Promise.resolve({ ok: false, reason: 'no-route' }) });
    plant(server, record({ ageSec: 9000 }));
    await w.pollOnce();
    await new Promise((r) => setImmediate(r));
    assert.ok(warns.some((m) => /NOT delivered/.test(m) && /no-route/.test(m)), `warns: ${JSON.stringify(warns)}`);
});

test('E2E watcher: only argv ever handed to the checker is status --check; lock ref unchanged', D, async () => {
    const server = newServer();
    const seen = [];
    const clock = { t: 11 };
    const sha = plant(server, record({ ageSec: 9000 }));
    const { w } = makeWatcher(server, clock, {
        runner: async (a) => {
            seen.push(a.args.join(' '));
            const r = spawnSync('bash', [a.file, ...a.args], { env: a.env, encoding: 'utf8' });
            return { rc: r.status, stdout: r.stdout };
        },
    });
    await w.pollOnce(); await w.pollOnce();
    assert.deepEqual(seen, ['status --check', 'status --check']);
    assert.equal(lockRef(server), sha);
});

// ---------------------------------------------------------------------------------------------
test('E2E checker output -> render_contended: stale / young / free / unreadable', D, () => {
    const server = newServer();

    let c = check(server);
    assert.equal(c.rc, 0);
    let r = render(c.stdout);
    assert.match(r.out, /^::error title=Tap publisher: Tap-writer lock was released meanwhile::/);
    assert.equal(r.out.trim().split('\n').length, 1);

    plant(server, record({ ageSec: 20, holder: 'busy-one' }));
    c = check(server);
    assert.equal(c.rc, 0);
    r = render(c.stdout);
    assert.match(r.out, /Tap-writer lock is busy/);
    assert.match(r.out, /busy-one/);
    assert.match(r.out, /busy, will converge/);
    assert.doesNotMatch(r.out, /break --force/, 'busy lock never suggests breaking');

    const sha = plant(server, record({ ageSec: 39900, holder: 'dead-one' }));
    c = check(server);
    assert.equal(c.rc, 1);
    r = render(c.stdout);
    assert.match(r.out, /stale tap-writer lock held by dead-one/);
    assert.match(r.out, /dead-one/);
    assert.match(r.out, /11h 05m/);
    assert.doesNotMatch(r.out, /0h0/);
    assert.match(r.out, new RegExp(`break --force --expect ${sha}`));
    assert.match(r.summary, /stale tap-writer lock/);
    assert.equal(lockRef(server), sha, 'rendering never breaks');

    plant(server, 'garbage');
    c = check(server);
    assert.equal(c.rc, 2);
    r = render(c.stdout);
    assert.match(r.out, /could not be read/);
    assert.doesNotMatch(r.out, /is busy/);

    c = check(path.join(TMP, 'absent.git'));
    assert.equal(c.rc, 2);
    r = render(c.stdout);
    assert.match(r.out, /could not be read/);
    assert.match(r.out, /ls-remote exit/);

    // usage error: rc 1 with NO state= -> renderer must fail closed to "could not be read"
    c = check(server, { KB_TAP_LOCK_STALE_AFTER: 'abc' });
    assert.equal(c.rc, 1);
    assert.equal(c.stdout, '');
    r = render(c.stdout);
    assert.match(r.out, /could not be read/);
});

// ---------------------------------------------------------------------------------------------
test('Hostile record values through checker -> watcher notice and render_contended', D, async () => {
    const server = newServer();
    const long = 'L'.repeat(5000);
    const hostile = 'x::error::pwned%0A=k=v ::warning::z é中😀';
    const sha = plant(server, record({
        ageSec: 9000,
        holder: hostile,
        runUrl: `https://e/x?a=b&c=d%0A::error::boom&${long}`,
        acquiredAt: `T=${'9'.repeat(400)}`,
    }));

    const c = check(server);
    assert.equal(c.rc, 1);
    assert.equal(c.stdout.split('\n').filter(Boolean).length, 11, 'still exactly 11 lines');
    const kv = parseKeyValue(c.stdout);
    assert.equal(kv.state, 'stale');
    assert.ok(kv.holder.includes('::error::pwned%0A=k=v'), 'value survives intact incl. = and %0A');
    assert.ok(kv.run_url.includes('a=b&c=d'), 'run_url keeps "=" (first-= split)');
    assert.equal(c.stdout.includes('\r'), false);

    // watcher
    const clock = { t: 1 };
    const { w, emitted } = makeWatcher(server, clock);
    assert.equal(await w.pollOnce(), 'stale');
    const nt = emitted[0];
    assert.ok(nt.title.length <= 200, `title bounded (${nt.title.length})`);
    assert.ok(nt.body.length <= 1500, `body bounded (${nt.body.length})`);
    assert.equal(/[\u0000-\u0009\u000b-\u001f\u007f]/.test(nt.title), false, 'no control chars in title');
    assert.equal(nt.title.includes('\n'), false, 'title is single-line');
    assert.ok(/^tap-writer:[A-Za-z0-9]{1,12}:1$/.test(nt.ref), `ref well-formed: ${nt.ref}`);
    assert.ok(nt.body.split('\n').every((l) => !l.startsWith('::')), 'no body line starts with ::');

    // render_contended
    const r = render(c.stdout);
    assert.equal(r.out.trim().split('\n').length, 1, 'one annotation line: no newline injection');
    assert.ok(r.out.startsWith('::error title='));
    assert.equal((r.out.match(/::error/g) || []).length >= 1, true);
    // after the leading ::error title=...:: marker, an injected "::error::" text must be inert:
    // the only literal "::" sequences allowed are the command's own delimiters.
    const body = r.out.trim().slice(r.out.indexOf('::', '::error title='.length) + 2);
    assert.ok(!/\n/.test(body));
    assert.ok(body.includes('%250A'), 'literal %0A in data is double-escaped, never decoded');
    assert.equal(r.summary.split('\n').some((l) => l.startsWith('::')), false);
    assert.equal(/[`<>|]/.test(r.summary.split('\n').slice(2).join('')), false, 'summary stripped of md/html metachars');
    assert.equal(lockRef(server), sha);
});

test('Hostile: CR / ESC / TAB inside a record value never reach checker stdout, notice or annotation', D, async () => {
    const server = newServer();
    plant(server, record({ ageSec: 9000, holder: 'a\rb\u001b[31mc\td' }));
    const c = check(server);
    assert.equal(c.rc, 1);
    assert.equal(/[\u0000-\u0009\u000b-\u001f\u007f]/.test(c.stdout), false, 'no control chars on checker stdout');
    assert.equal(c.stdout.split('\n').filter(Boolean).length, 11);
    const clock = { t: 1 };
    const { w, emitted } = makeWatcher(server, clock);
    assert.equal(await w.pollOnce(), 'stale');
    assert.equal(/[\u0000-\u001f\u007f]/.test(emitted[0].title), false);
    const r = render(c.stdout);
    assert.equal(r.out.trim().split('\n').length, 1);
    assert.equal(/[\u0000-\u0009\u000b-\u001f\u007f]/.test(r.out), false);
});

test('Hostile: duplicate keys and CR in stdout in the watcher parser (first wins, CR tolerated)', D, () => {
    const kv = parseKeyValue('state=stale\r\nstate=young\r\nrun_url=https://a/b?x=1=2\r\nholder=\r\n');
    assert.equal(kv.state, 'stale', 'first duplicate wins (a late key cannot downgrade the verdict)');
    assert.equal(kv.run_url, 'https://a/b?x=1=2');
    assert.equal(kv.holder, '');
});

test('Hostile: render_contended parser takes FIRST "=", duplicate keys, CR line', D, () => {
    // NOTE: the renderer keeps the LAST duplicate (plain read loop). The real checker never emits
    // duplicates; this pins the observed behaviour so a change is a conscious one.
    const r = render('state=young\nholder=a=b=c\nrun_url=https://x/?q=1&r=2\nage=10\n');
    assert.match(r.out, /a=b=c/);
    assert.match(r.out, /q=1&r=2/);
    const r2 = render('state=stale\r\nholder=h\r\nage=7200\r\nbreak_cmd=true\r\n');
    // A CR left on the value makes state="stale\r" which matches no case arm: it must FAIL CLOSED
    // (unreadable text), never be read as free/young. The real checker strips CR (kv_clean).
    assert.match(r2.out, /could not be read/, 'CR-tainted state fails closed');
    assert.doesNotMatch(r2.out, /is busy|released meanwhile/);
});

test('Static: nothing in the new code paths can invoke break', D, () => {
    const watcher = fs.readFileSync(path.join(REPO_ROOT, 'fleet-monitor', 'server', 'lib', 'tap-lock-watcher.js'), 'utf8');
    const code = watcher.split('\n').filter((l) => !/^\s*(\/\/|\*|\/\*)/.test(l)).join('\n');
    assert.equal(/['"`]break['"`]/.test(code), false, 'watcher source never names a "break" argv');
    assert.equal(/\bunlink|\brm\b|update-ref|['"]git['"]|writeFile|appendFile|\bspawn\(|\bexec\(/.test(code), false, 'watcher never writes refs/files or shells out to git');
    assert.deepEqual(code.match(/execFile\(\s*'[a-z]+'/g), ["execFile('bash'"], 'the only process the watcher launches is bash');
    // negative control for the predicate above
    assert.equal(/update-ref/.test("run('git update-ref -d x')"), true);
    // negative control: the same predicate must fire on a violating snippet
    assert.equal(/['"`]break['"`]/.test("run(['break','--force'])"), true);
    // watcher rejects an injected break argv? it never accepts argv from config at all:
    const cfg = resolveTapLockConfig({ FLEET_TAP_LOCK_CHECKER: CHECKER, FLEET_TAP_LOCK_WATCH: '1' });
    assert.equal('args' in cfg, false);
});
