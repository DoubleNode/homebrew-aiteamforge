//
//  xaca-1300-003-token-reports.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1300-003 — fleet store for weekly token aggregates.
 *
 * Mounts the REAL lib/token-reports-routes.js (the module server.js mounts)
 * on a bare express app. No port is bound and no server runs as a team.
 * The store root is an isolated temp dir via FLEET_TOKEN_REPORTS_DIR.
 *
 * Covers: ingest + schema validation, durable per-(machine, week) storage,
 * idempotent re-send, final-record protection (design §6), out-of-order
 * refusal, missing-machine reporting (absence is never zero), history index,
 * and the auth gate on the POST AND both GET forms (index + ?week=, user
 * decision 2026-09-22 — see the module doc comment in
 * lib/token-reports-routes.js for why the GETs were re-gated).
 */

const fs   = require('fs');
const path = require('path');
const os   = require('os');

const TEST_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'xaca1300-003-'));
process.env.FLEET_TOKEN_REPORTS_DIR = TEST_DIR;
delete process.env.FLEET_AUTH_TOKEN;

const { test, beforeEach, after } = require('node:test');
const assert  = require('node:assert/strict');
const request = require('supertest');
const express = require('express');

const { registerTokenReportsRoutes, isoWeekOf, lastCompletedWeek } = require('../lib/token-reports-routes');

let fleetRoster = [];
function buildApp() {
    const app = express();
    app.use(express.json({ limit: '10mb' }));
    registerTokenReportsRoutes(app, { listFleetMachines: () => fleetRoster });
    return app;
}
const app = buildApp();

function tok(input, output, cc, cr) {
    return { input, output, cache_creation: cc, cache_read: cr, total: input + output + cc + cr };
}

function record(over = {}) {
    return Object.assign({
        schema_version: 1,
        record_type: 'kb-token-report.weekly',
        machine: 'm-alpha.example',
        week: '2026-W38',
        week_start: '2026-09-14T00:00:00Z',
        week_end: '2026-09-21T00:00:00Z',
        generated_at: '2026-09-22T14:00:00Z',
        generator: { script: 'kb-token-report', version: '1' },
        final: true,
        coverage: { complete: true, files_scanned: 10 },
        rows: [{ account: 'acct-a', team: 'synthteam', model: 'claude-opus-5', role: 'main',
                 session_class: 'ticket', agent_type: null, day: '2026-09-15',
                 sessions: 1, messages: 3, tokens: tok(1, 2, 3, 4) }],
        tickets: { state: 'ok', items: [{ ticket_id: 'SYN-0001', tokens: tok(1, 1, 1, 1), sessions: 1 }] },
        first_turn_context: { n: 0, median: null, p90: null, min: null, max: null },
    }, over);
}

function post(rec, machineId = 'uuid-alpha', hostname = 'm-alpha.example') {
    return request(app).post('/api/token-reports').send({ machine_id: machineId, hostname, record: rec });
}

beforeEach(() => {
    fs.rmSync(TEST_DIR, { recursive: true, force: true });
    fs.mkdirSync(TEST_DIR, { recursive: true });
    fleetRoster = [];
    delete process.env.FLEET_AUTH_TOKEN;
});

after(() => {
    fs.rmSync(TEST_DIR, { recursive: true, force: true });
    delete process.env.FLEET_AUTH_TOKEN;
});

// ── ingest + durable storage ───────────────────────────────────────────────

test('first POST stores the record durably on disk (201 stored)', async () => {
    const res = await post(record());
    assert.equal(res.status, 201);
    assert.equal(res.body.action, 'stored');
    const onDisk = JSON.parse(fs.readFileSync(path.join(TEST_DIR, 'uuid-alpha', '2026-W38.json'), 'utf8'));
    assert.equal(onDisk.record.week, '2026-W38');
    assert.equal(onDisk.hostname, 'm-alpha.example');
    assert.equal(fs.readdirSync(path.join(TEST_DIR, 'uuid-alpha')).filter(f => f.includes('.tmp.')).length, 0,
        'atomic write leaves no temp file behind');
});

test('identical re-send is idempotent (200 unchanged, file untouched)', async () => {
    await post(record());
    const p = path.join(TEST_DIR, 'uuid-alpha', '2026-W38.json');
    const before = fs.readFileSync(p, 'utf8');
    const res = await post(record());
    assert.equal(res.status, 200);
    assert.equal(res.body.action, 'unchanged');
    assert.equal(fs.readFileSync(p, 'utf8'), before);
});

test('a newer re-run of the same week replaces it (200 replaced)', async () => {
    await post(record());
    const res = await post(record({ generated_at: '2026-09-23T00:00:00Z', rows: [] }));
    assert.equal(res.status, 200);
    assert.equal(res.body.action, 'replaced');
    const got = await request(app).get('/api/token-reports?week=2026-W38');
    assert.deepEqual(got.body.machines[0].record.rows, []);
});

test('weeks are stored independently — a new week never touches another', async () => {
    await post(record());
    await post(record({ week: '2026-W39', final: false, generated_at: '2026-09-23T00:00:00Z' }));
    const idx = await request(app).get('/api/token-reports');
    assert.deepEqual(idx.body.entries.map(e => [e.week, e.final]), [['2026-W38', true], ['2026-W39', false]]);
});

// ── final protection (design §6) ───────────────────────────────────────────

test('a stored final record is NOT replaced by a partial (409)', async () => {
    await post(record());
    const res = await post(record({ final: false, generated_at: '2026-09-23T00:00:00Z', rows: [] }));
    assert.equal(res.status, 409);
    assert.equal(res.body.reason, 'final_not_replaceable_by_partial');
    const got = await request(app).get('/api/token-reports?week=2026-W38');
    assert.equal(got.body.machines[0].record.rows.length, 1, 'stored final survived');
});

test('a stored final record is NOT replaced by a final-but-incomplete one (409)', async () => {
    await post(record());
    const res = await post(record({ generated_at: '2026-09-23T00:00:00Z', coverage: { complete: false } }));
    assert.equal(res.status, 409);
    assert.equal(res.body.reason, 'final_not_replaceable_by_incomplete');
});

test('a partial week is replaced by its final record', async () => {
    await post(record({ final: false, generated_at: '2026-09-20T00:00:00Z' }));
    const res = await post(record());
    assert.equal(res.status, 200);
    assert.equal(res.body.action, 'replaced');
    assert.equal(res.body.final, true);
});

test('an older record than the stored one is refused (out-of-order delivery)', async () => {
    await post(record({ final: false, generated_at: '2026-09-20T00:00:00Z' }));
    const res = await post(record({ final: false, generated_at: '2026-09-19T00:00:00Z', rows: [] }));
    assert.equal(res.status, 409);
    assert.equal(res.body.reason, 'older_than_stored');
});

// ── validation: never coerce ───────────────────────────────────────────────

test('schema_version other than 1 is refused (422), nothing stored', async () => {
    const res = await post(record({ schema_version: 2 }));
    assert.equal(res.status, 422);
    assert.equal(fs.existsSync(path.join(TEST_DIR, 'uuid-alpha')), false);
});

test('tokens.total that does not equal the four-field sum is rejected (400)', async () => {
    const bad = record();
    bad.rows[0].tokens.total += 1;
    const res = await post(bad);
    assert.equal(res.status, 400);
    assert.match(res.body.error, /total/);
});

test('a missing core token field is rejected, never read as 0', async () => {
    const bad = record();
    delete bad.rows[0].tokens.cache_read;
    assert.equal((await post(bad)).status, 400);
});

test('ticket item totals are checked too', async () => {
    const bad = record();
    bad.tickets.items[0].tokens.output = -1;
    assert.equal((await post(bad)).status, 400);
});

test('rows must be present (an empty week is [], not absent)', async () => {
    const bad = record();
    delete bad.rows;
    assert.equal((await post(bad)).status, 400);
    assert.equal((await post(record({ rows: [] }))).status, 201);
});

test('record.machine must match the submitting hostname', async () => {
    const res = await post(record({ machine: 'someone-else' }));
    assert.equal(res.status, 400);
});

test('path-traversal machine_id is rejected', async () => {
    const res = await post(record(), '../evil');
    assert.equal(res.status, 400);
    assert.equal(fs.readdirSync(TEST_DIR).length, 0);
});

test('bad week string is rejected', async () => {
    assert.equal((await post(record({ week: '2026-38' }))).status, 400);
    assert.equal((await request(app).get('/api/token-reports?week=../x')).status, 400);
});

// ── missing machines: absence is never zero ────────────────────────────────

test('a fleet machine with no record for the week is "missing" with record:null', async () => {
    fleetRoster = [{ machine_id: 'uuid-alpha', hostname: 'm-alpha.example' },
                   { machine_id: 'uuid-beta', hostname: 'm-beta.example' }];
    await post(record());
    const res = await request(app).get('/api/token-reports?week=2026-W38');
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.summary, { reported: 1, final: 1, partial: 0, missing: 1 });
    const beta = res.body.machines.find(m => m.machine_id === 'uuid-beta');
    assert.equal(beta.status, 'missing');
    assert.equal(beta.record, null);
    assert.equal('rows' in beta, false, 'no zero rows fabricated for a missing machine');
});

test('a machine that reported other weeks but not this one is missing for this one', async () => {
    await post(record());
    const res = await request(app).get('/api/token-reports?week=2026-W37');
    assert.equal(res.body.machines.length, 1);
    assert.equal(res.body.machines[0].status, 'missing');
    assert.deepEqual(res.body.machines[0].roster_sources, ['token-reports']);
});

test('a corrupt stored record surfaces as 500, never as "missing"', async () => {
    await post(record());
    fs.writeFileSync(path.join(TEST_DIR, 'uuid-alpha', '2026-W38.json'), '{torn');
    const res = await request(app).get('/api/token-reports?week=2026-W38');
    assert.equal(res.status, 500);
});

test('week=last resolves to the last completed ISO week', async () => {
    const res = await request(app).get('/api/token-reports?week=last');
    assert.equal(res.body.week, lastCompletedWeek());
    assert.equal(isoWeekOf(new Date('2026-09-22T12:00:00Z')), '2026-W39');
    assert.equal(lastCompletedWeek(new Date('2026-09-22T12:00:00Z')), '2026-W38');
    assert.equal(isoWeekOf(new Date('2027-01-01T00:00:00Z')), '2026-W53');
});

// ── default-oauth labelling + account totals (read time only) ─────────────

const { resolveDefaultOauth } = require('../lib/token-reports-routes');
const OAUTH_MAP_FILE = path.join(os.tmpdir(), `xaca1300-003-oauth-${process.pid}.json`);

function writeOauthMap(machines) {
    fs.writeFileSync(OAUTH_MAP_FILE, JSON.stringify({ machines }));
    process.env.FLEET_TOKEN_OAUTH_MAP = OAUTH_MAP_FILE;
}

function oauthRecord(machine, hash, rows) {
    return record({ machine, coverage: { complete: true, default_oauth_account_hash: hash }, rows });
}

function row(account, sessionClass, total) {
    return { account, team: 'synthteam', model: 'm', role: 'main', session_class: sessionClass,
             agent_type: null, day: '2026-09-15', sessions: 1, messages: 1, tokens: tok(0, 0, 0, total) };
}

test('resolveDefaultOauth: stated, unmapped, login-changed, conflict — never a guess', () => {
    const map = {
        'syn-a': { aliases: ['syn-a-local'], default_oauth_account: 'acct-1', provenance: 'user-stated', login_hash_observed: 'aaaa1111' },
        'syn-b': { default_oauth_account: null, provenance: 'not stated', login_hash_observed: 'bbbb2222' },
        'syn-c': { default_oauth_account: 'acct-1', login_hash_observed: 'cccc3333' },
        'syn-d': { default_oauth_account: 'acct-2', login_hash_observed: 'cccc3333' },
    };
    const r = (m, h) => resolveDefaultOauth(map, { machine: m, coverage: { default_oauth_account_hash: h } });
    assert.equal(r('syn-a.tailnet.example', 'aaaa1111').resolved_as, 'acct-1');
    assert.equal(r('SYN-A-LOCAL.local', 'aaaa1111').resolved_as, 'acct-1', 'alias + case-insensitive short name');
    assert.equal(r('syn-a', 'aaaa1111').provenance, 'user-stated');
    assert.equal(r('syn-b', 'bbbb2222').resolved_as, 'default-oauth:unmapped');
    assert.equal(r('syn-zzz', 'ffff0000').resolved_as, 'default-oauth:unmapped');
    assert.equal(r('syn-a', 'eeee9999').resolved_as, 'default-oauth:login-changed');
    assert.equal(r('syn-c', 'cccc3333').resolved_as, 'default-oauth:conflict', 'one login stated as two accounts');
    assert.equal(r('syn-d', 'cccc3333').resolved_as, 'default-oauth:conflict');
});

test('GET week: default-oauth rows labelled per machine, stored record untouched', async () => {
    writeOauthMap({ 'm-alpha': { default_oauth_account: 'acct-1', provenance: 'user-stated', login_hash_observed: 'aaaa1111' } });
    await post(oauthRecord('m-alpha.example', 'aaaa1111', [row('default-oauth', 'ticket', 10), row('acct-2', 'ticket', 5)]));
    await post(oauthRecord('m-beta.example', 'bbbb2222', [row('default-oauth', 'other', 7)]), 'uuid-beta', 'm-beta.example');
    const res = await request(app).get('/api/token-reports?week=2026-W38');
    assert.equal(res.status, 200);
    assert.equal(res.body.account_totals['acct-1'].total, 10);
    assert.equal(res.body.account_totals['acct-2'].total, 5);
    assert.equal(res.body.account_totals['default-oauth:unmapped'].total, 7);
    assert.equal('default-oauth' in res.body.account_totals, false);
    const alpha = res.body.machines.find(m => m.machine_id === 'uuid-alpha');
    assert.equal(alpha.default_oauth.resolved_as, 'acct-1');
    assert.equal(alpha.record.rows[0].account, 'default-oauth', 'the stored row is never rewritten');
    delete process.env.FLEET_TOKEN_OAUTH_MAP;
});

test('headless gate/scheduled rows with no map row total as unattributed:headless_route_unknown', async () => {
    writeOauthMap({});
    await post(oauthRecord('m-alpha.example', 'aaaa1111', [
        row('unattributed:not_in_map', 'gate', 3), row('unattributed:not_in_map', 'scheduled', 4),
        row('unattributed:not_in_map', 'other', 5)]));
    const res = await request(app).get('/api/token-reports?week=2026-W38');
    assert.equal(res.body.account_totals['unattributed:headless_route_unknown'].total, 7);
    assert.equal(res.body.account_totals['unattributed:not_in_map'].total, 5);
    delete process.env.FLEET_TOKEN_OAUTH_MAP;
});

test('missing machines are listed beside the totals, contributing nothing', async () => {
    writeOauthMap({});
    fleetRoster = [{ machine_id: 'uuid-beta', hostname: 'm-beta.example' }];
    await post(record());
    const res = await request(app).get('/api/token-reports?week=2026-W38');
    assert.deepEqual(res.body.missing_machines, ['m-beta.example']);
    delete process.env.FLEET_TOKEN_OAUTH_MAP;
});

test('a present-but-corrupt oauth map is a 500, never silently "unmapped"', async () => {
    fs.writeFileSync(OAUTH_MAP_FILE, '{not json');
    process.env.FLEET_TOKEN_OAUTH_MAP = OAUTH_MAP_FILE;
    await post(record());
    assert.equal((await request(app).get('/api/token-reports?week=2026-W38')).status, 500);
    delete process.env.FLEET_TOKEN_OAUTH_MAP;
    fs.rmSync(OAUTH_MAP_FILE, { force: true });
});

test('the shipped config parses and every entry carries provenance', () => {
    const shipped = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'config', 'token-oauth-accounts.json'), 'utf8'));
    const entries = Object.entries(shipped.machines);
    assert.ok(entries.length >= 1);
    for (const [k, v] of entries) {
        assert.equal(typeof v.provenance, 'string', `${k} provenance`);
        assert.ok(v.default_oauth_account === null || typeof v.default_oauth_account === 'string', k);
    }
});

// ── auth ───────────────────────────────────────────────────────────────────

test('POST is gated when FLEET_AUTH_TOKEN is set: no key 401, wrong key 401, right key 201', async () => {
    process.env.FLEET_AUTH_TOKEN = 'synthetic-test-token';
    assert.equal((await post(record())).status, 401, 'no key');
    const wrong = await request(app).post('/api/token-reports')
        .set('Authorization', 'Bearer nope-not-it')
        .send({ machine_id: 'uuid-alpha', hostname: 'm-alpha.example', record: record() });
    assert.equal(wrong.status, 401, 'wrong key');
    const ok = await request(app).post('/api/token-reports')
        .set('Authorization', 'Bearer synthetic-test-token')
        .send({ machine_id: 'uuid-alpha', hostname: 'm-alpha.example', record: record() });
    assert.equal(ok.status, 201);
});

test('GET /api/token-reports (index) is gated: no key 401, wrong key 401, right key 200', async () => {
    process.env.FLEET_AUTH_TOKEN = 'synthetic-test-token';
    const noKey = await request(app).get('/api/token-reports');
    assert.equal(noKey.status, 401, 'no key');
    assert.deepEqual(noKey.body, { error: 'Unauthorized', code: 'unauthorized' });
    const wrongKey = await request(app).get('/api/token-reports').set('X-API-Key', 'nope-not-it');
    assert.equal(wrongKey.status, 401, 'wrong key');
    const rightKey = await request(app).get('/api/token-reports').set('Authorization', 'Bearer synthetic-test-token');
    assert.equal(rightKey.status, 200, 'right key');
});

test('GET /api/token-reports?week=... is gated: no key 401, wrong key 401, right key 200', async () => {
    process.env.FLEET_AUTH_TOKEN = 'synthetic-test-token';
    await request(app).post('/api/token-reports')
        .set('Authorization', 'Bearer synthetic-test-token')
        .send({ machine_id: 'uuid-alpha', hostname: 'm-alpha.example', record: record() });
    const noKey = await request(app).get('/api/token-reports?week=2026-W38');
    assert.equal(noKey.status, 401, 'no key');
    const wrongKey = await request(app).get('/api/token-reports?week=2026-W38').set('X-API-Key', 'nope-not-it');
    assert.equal(wrongKey.status, 401, 'wrong key');
    const rightKey = await request(app).get('/api/token-reports?week=2026-W38').set('Authorization', 'Bearer synthetic-test-token');
    assert.equal(rightKey.status, 200, 'right key');
    assert.equal(rightKey.body.week, '2026-W38');
});
