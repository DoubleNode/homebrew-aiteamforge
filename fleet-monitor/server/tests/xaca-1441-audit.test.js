//
//  xaca-1441-audit.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

// XACA-1441-006: audit log field allowlist, secret redaction, rotation, tail. Offline, temp dirs.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { createAudit, sanitize, looksSecret } = require('../lib/ci-dispatch-audit');

function tmp() { return fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1441-audit-')); }
const FIXED = () => new Date('2026-10-06T12:00:00.000Z');

// Sentinels built at runtime so this file itself holds no secret-shaped literal.
const JWT = ['eyJhbGciOiJSUzI1NiJ9', 'eyJpc3MiOiIxMjM0NTYifQ', 'c2lnbmF0dXJlLXNlbnRpbmVs'].join('.');
const GHS = 'ghs_' + 'A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8';
const GHP = 'ghp_' + 'Z9y8X7w6V5u4T3s2R1q0P9o8N7m6L5k4J3i2';
const PAT = 'github_pat_' + '11ABCDEFG0abcdefghijkl_mnopqrstuvwxyz0123456789';
const PEM = '-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----';
const B64 = Buffer.alloc(300, 7).toString('base64');
const SECRETS = [JWT, GHS, GHP, PAT, PEM, B64];

test('append writes one JSONL line with ts and event, allowlisted fields only', () => {
  const d = tmp(); const p = path.join(d, 'a.jsonl');
  const a = createAudit({ path: p, now: FIXED });
  a.append('assign', { id: 'asg1', repo: 'o/r', jobId: 9, runAttempt: 1, runnerName: 'fleet-1', runnerId: 77,
                       machine: 'm4mini', state: 'pending', reason: 'ok' });
  const lines = fs.readFileSync(p, 'utf8').split('\n').filter(Boolean);
  assert.strictEqual(lines.length, 1);
  assert.deepStrictEqual(JSON.parse(lines[0]), {
    ts: '2026-10-06T12:00:00.000Z', event: 'assign', id: 'asg1', repo: 'o/r', jobId: 9, runAttempt: 1,
    runnerName: 'fleet-1', runnerId: 77, machine: 'm4mini', state: 'pending', reason: 'ok'
  });
});

test('unknown fields are dropped, including secret-named ones', () => {
  const out = sanitize('assign', { id: 'x', jitConfig: 'abc', encoded_jit_config: 'abc', token: 't', privateKey: 'k',
                                   nested: { a: 1 }, list: [1], repo: 'o/r' }, 'T');
  assert.deepStrictEqual(out, { ts: 'T', event: 'assign', id: 'x', repo: 'o/r' });
});

test('non-scalar values in allowed fields are dropped; unknown events use base fields only', () => {
  const out = sanitize('assign', { id: { a: 1 }, repo: ['x'], jobId: NaN, state: 's' }, 'T');
  assert.deepStrictEqual(out, { ts: 'T', event: 'assign', state: 's' });
  const u = sanitize('whatever', { id: 'a', runId: 5 }, 'T');
  assert.deepStrictEqual(u, { ts: 'T', event: 'whatever', id: 'a' });
  assert.strictEqual(sanitize('Bad Event!', {}, 'T').event, 'invalid-event');
  assert.strictEqual(sanitize(null, null, 'T').event, 'invalid-event');
});

test('secret-shaped values in ALLOWED fields become [redacted]; innocuous values survive', () => {
  for (const s of SECRETS) {
    assert.strictEqual(looksSecret(s), true);
    assert.strictEqual(sanitize('assign', { reason: s }, 'T').reason, '[redacted]');
    assert.strictEqual(sanitize('assign', { reason: 'prefix ' + s + ' suffix' }, 'T').reason, '[redacted]');
  }
  for (const ok of ['reject:fork', 'o/r', 'fleet-pool', 'a'.repeat(150), 'ghost_story']) {
    assert.strictEqual(looksSecret(ok), false, ok);
  }
});

test('sentinel secrets never appear in the file, via unknown OR allowed fields', () => {
  const d = tmp(); const p = path.join(d, 'a.jsonl');
  const a = createAudit({ path: p, now: FIXED });
  for (const s of SECRETS) {
    a.append('assign', { id: 'i', jitConfig: s, token: s, reason: s, runnerName: s, machine: s });
    a.append('reject', { repo: s, state: s, extra: s });
  }
  const raw = fs.readFileSync(p, 'utf8');
  for (const s of SECRETS) assert.ok(!raw.includes(s.slice(0, 40)), 'leaked: ' + s.slice(0, 12));
  assert.ok(raw.includes('[redacted]'));
  assert.ok(!/BEGIN|ghs_|ghp_|github_pat_|eyJ/.test(raw));
});

test('a realistic JIT config (base64 of {".runner":…}, starts eyIu) is redacted, short or long', () => {
  // XACA-1441-020: JIT configs never start eyJ, so the JWT arm alone cannot see one; the long-run
  // arm only covers values >= 200 chars. A short eyIu fragment must still be redacted.
  const body = JSON.stringify({ '.runner': 'r'.repeat(60), '.credentials': 'c'.repeat(60) });
  const full = Buffer.from(body).toString('base64');
  assert.ok(full.startsWith('eyIu'), 'fixture shape');
  const short = full.slice(0, 40);
  assert.ok(short.length < 200);
  for (const v of [full, short]) assert.equal(sanitize('assign', { reason: v }).reason, '[redacted]');
});

test('file is created with 0600 and parent dir is created on demand', () => {
  const d = tmp(); const p = path.join(d, 'sub', 'deeper', 'a.jsonl');
  const a = createAudit({ path: p });
  assert.ok(a.append('state', { id: 'x' }));
  assert.strictEqual(fs.statSync(p).mode & 0o777, 0o600);
});

test('rotation at threshold keeps exactly `keep` rotated files and drops the oldest', () => {
  const d = tmp(); const p = path.join(d, 'a.jsonl');
  const a = createAudit({ path: p, maxBytes: 600, keep: 3, now: FIXED });
  for (let i = 0; i < 60; i++) a.append('state', { id: 'evt' + String(i).padStart(3, '0'), repo: 'o/r', state: 'pending' });
  const files = fs.readdirSync(d).sort();
  assert.deepStrictEqual(files, ['a.jsonl', 'a.jsonl.1', 'a.jsonl.2', 'a.jsonl.3']);
  for (const f of files) assert.ok(fs.statSync(path.join(d, f)).size <= 600, f);
  // newest line lives in the live file; .1 is newer than .2 is newer than .3
  const first = (f) => JSON.parse(fs.readFileSync(path.join(d, f), 'utf8').split('\n')[0]).id;
  assert.ok(first('a.jsonl') > first('a.jsonl.1'));
  assert.ok(first('a.jsonl.1') > first('a.jsonl.2'));
  assert.ok(first('a.jsonl.2') > first('a.jsonl.3'));
  assert.ok(!fs.existsSync(p + '.4'));
  assert.strictEqual(a.lastError, null);
});

test('rotation: below threshold nothing rotates', () => {
  const d = tmp(); const p = path.join(d, 'a.jsonl');
  const a = createAudit({ path: p, maxBytes: 100000 });
  for (let i = 0; i < 20; i++) a.append('state', { id: 'e' + i });
  assert.deepStrictEqual(fs.readdirSync(d), ['a.jsonl']);
});

test('tail returns last n oldest-first, spans rotated files, skips torn lines', () => {
  const d = tmp(); const p = path.join(d, 'a.jsonl');
  const a = createAudit({ path: p, maxBytes: 400, keep: 3, now: FIXED });
  for (let i = 0; i < 20; i++) a.append('state', { id: 'e' + String(i).padStart(2, '0') });
  assert.ok(fs.existsSync(p + '.1'));
  const t = a.tail(5);
  assert.deepStrictEqual(t.map((x) => x.id), ['e15', 'e16', 'e17', 'e18', 'e19']);
  const wide = a.tail(1000).map((x) => x.id);
  assert.strictEqual(wide[wide.length - 1], 'e19');
  assert.deepStrictEqual(wide, wide.slice().sort());
  fs.appendFileSync(p, '{"torn":\n');
  assert.strictEqual(a.tail(2).length, 2);
  assert.deepStrictEqual(createAudit({ path: path.join(d, 'none.jsonl') }).tail(5), []);
});

test('append never throws on I/O failure; returns null and records lastError', () => {
  const d = tmp();
  const blocker = path.join(d, 'file'); fs.writeFileSync(blocker, 'x');
  const a = createAudit({ path: path.join(blocker, 'a.jsonl') }); // parent is a file
  assert.strictEqual(a.append('state', { id: 'x' }), null);
  assert.ok(a.lastError);
});

test('createAudit requires a path; injected fs is honoured', () => {
  assert.throws(() => createAudit({}), /path required/);
  const calls = [];
  const fake = { mkdirSync() {}, statSync() { throw new Error('nope'); }, appendFileSync(p, l) { calls.push(l); },
                 readFileSync() { return calls.join(''); }, renameSync() {}, unlinkSync() {} };
  const a = createAudit({ path: '/x/a.jsonl', fs: fake, now: FIXED });
  a.append('state', { id: 'z' });
  assert.strictEqual(calls.length, 1);
  assert.strictEqual(a.tail(1)[0].id, 'z');
});
