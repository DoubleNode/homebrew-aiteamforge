//
//  msg-relay-routes.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Integration tests for the kb-msg cross-machine relay routes (XACA-0777).
 * Uses node --test + supertest. Mirrors vault-routes.test.js style.
 *
 * Routes under test:
 *   POST /api/msg           store a sealed envelope
 *   GET  /api/msg?machine=  list undelivered envelopes for a machine
 *   POST /api/msg/ack       drop delivered envelopes
 *
 * Test isolation: FLEET_MSG_FILE points the store at a per-process temp file so
 * the suite never touches the real data/messages.json.
 *
 * LOAD-BEARING ASSERTION — THE RELAY NEVER DECRYPTS:
 *   1. Structural: the module source contains no `crypto_box_seal_open` and does
 *      not import/export any sealOpen. It cannot read a body even in principle.
 *   2. Behavioral: a full round-trip — seal a record to a recipient keypair,
 *      POST it, GET it back, and sealOpen it CLIENT-SIDE (in the test, standing
 *      in for the recipient machine) — proves the relay only ever handled opaque
 *      ciphertext, and that the stored blob is byte-identical to what was sealed.
 */

const fs   = require('fs');
const path = require('path');
const os   = require('os');

// Point the message store at an isolated temp file BEFORE requiring the module.
const TEST_MSG_FILE = path.join(os.tmpdir(), `msg-relay-${process.pid}-${Date.now()}.json`);
process.env.FLEET_MSG_FILE = TEST_MSG_FILE;

const { test, before, after, beforeEach } = require('node:test');
const assert  = require('node:assert/strict');
const request = require('supertest');
const express = require('express');

const { ensureReady, generateKeypair, seal, sealOpen } = require('../lib/vault-crypto');
const msgRelay = require('../lib/msg-relay-routes');
const { registerMsgRelayRoutes, readStore, writeStore } = msgRelay;

// The Tier-2 CLIENT (fleet-monitor/client/msg-client.js) exports sealOpenLocal,
// the function that must NULL-SKIP a malformed/foreign ciphertext on the pull
// path rather than throwing (XACA-0777-016c). It is required here — across the
// server/client boundary — because that is the load-bearing behavior a relay
// consumer depends on: a bad envelope must never crash the reporter's pull loop.
// Requires fleet-monitor/client/node_modules (libsodium-wrappers) to be
// installed — see fleet-monitor/client/package.json.
const CLIENT_DIR = path.join(__dirname, '..', '..', 'client');
const msgClient = require(path.join(CLIENT_DIR, 'msg-client.js'));
const vaultKeygen = require(path.join(CLIENT_DIR, 'vault-keygen.js'));

// Build a minimal app mounting ONLY the relay routes (the REAL module server.js mounts).
function buildApp() {
    const app = express();
    app.use(express.json({ limit: '10mb' }));
    registerMsgRelayRoutes(app);
    return app;
}

let app;
let recipientKeys;   // { publicKey, privateKey } — stands in for the recipient machine

before(async () => {
    await ensureReady();
    recipientKeys = await generateKeypair();
    app = buildApp();
});

beforeEach(() => {
    // Clean slate: empty the store file.
    try { fs.unlinkSync(TEST_MSG_FILE); } catch (_) { /* fine */ }
});

after(() => {
    try { fs.unlinkSync(TEST_MSG_FILE); } catch (_) { /* fine */ }
    delete process.env.FLEET_AUTH_TOKEN;
});

// Helper: seal a message record and build a POST envelope.
async function sealedEnvelope(overrides = {}) {
    const record = Object.assign({
        id: 'msg-' + Math.random().toString(16).slice(2),
        from_team: 'academy',
        from_terminal: 'chancellor',
        to_team: 'ios',
        to_terminal: 'bridge',
        to: 'ios:bridge',
        body: 'cross-machine hello',
        thread_id: 'thread-1',
        created_at: '2026-07-10T00:00:00Z',
    }, overrides.record || {});
    const ciphertext = await seal(JSON.stringify(record), recipientKeys.publicKey);
    const envelope = Object.assign({
        id: record.id,
        to_team: record.to_team,
        to_terminal: record.to_terminal,
        machine: 'darren-m1pro-mbp',
        from: `${record.from_team}:${record.from_terminal}`,
        ciphertext,
        thread_id: record.thread_id,
        created_at: record.created_at,
    }, overrides.envelope || {});
    return { record, envelope, ciphertext };
}

// ---------------------------------------------------------------------------
// Structural no-decrypt guarantee
// ---------------------------------------------------------------------------

test('module never imports/exports a decrypt primitive (structural no-read guarantee)', () => {
    const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'msg-relay-routes.js'), 'utf8');
    assert.ok(!/crypto_box_seal_open/.test(src), 'relay source must not reference crypto_box_seal_open');
    assert.ok(!/\bsealOpen\b/.test(src), 'relay source must not reference sealOpen');
    assert.ok(!('sealOpen' in msgRelay), 'relay module must not export sealOpen');
});

// ---------------------------------------------------------------------------
// POST /api/msg — store opaque ciphertext
// ---------------------------------------------------------------------------

test('POST /api/msg stores a sealed envelope and returns 201', async () => {
    const { envelope } = await sealedEnvelope();
    const res = await request(app).post('/api/msg').send(envelope);
    assert.equal(res.status, 201);
    assert.equal(res.body.stored, true);
    assert.equal(res.body.id, envelope.id);
});

test('POST /api/msg stores the ciphertext byte-identically (opaque store)', async () => {
    const { envelope, ciphertext } = await sealedEnvelope();
    await request(app).post('/api/msg').send(envelope).expect(201);
    // Inspect the on-disk store — the blob must equal exactly what we sealed.
    const store = JSON.parse(fs.readFileSync(TEST_MSG_FILE, 'utf8'));
    assert.equal(store.messages.length, 1);
    assert.equal(store.messages[0].ciphertext, ciphertext);
    // And there is no plaintext body field anywhere in the stored record.
    assert.ok(!('body' in store.messages[0]), 'stored envelope must not contain a plaintext body');
});

test('POST /api/msg is idempotent for the same (machine, id)', async () => {
    const { envelope } = await sealedEnvelope();
    await request(app).post('/api/msg').send(envelope).expect(201);
    const res = await request(app).post('/api/msg').send(envelope);
    assert.equal(res.status, 200);
    assert.equal(res.body.duplicate, true);
    const store = JSON.parse(fs.readFileSync(TEST_MSG_FILE, 'utf8'));
    assert.equal(store.messages.length, 1);
});

test('POST /api/msg rejects a non-sealed-box ciphertext (400)', async () => {
    const { envelope } = await sealedEnvelope();
    envelope.ciphertext = 'dG9vc2hvcnQ=';  // valid base64 but < 48 bytes
    const res = await request(app).post('/api/msg').send(envelope);
    assert.equal(res.status, 400);
    assert.match(JSON.stringify(res.body.details), /sealed box/);
});

test('POST /api/msg rejects a bad machine slug (400)', async () => {
    const { envelope } = await sealedEnvelope();
    envelope.machine = 'Not A Slug';
    const res = await request(app).post('/api/msg').send(envelope);
    assert.equal(res.status, 400);
});

test('POST /api/msg rejects a bad to_team slug (400)', async () => {
    const { envelope } = await sealedEnvelope();
    envelope.to_team = 'BADTEAM!';
    const res = await request(app).post('/api/msg').send(envelope);
    assert.equal(res.status, 400);
});

test('POST /api/msg returns 429 when a machine\'s queue is full (XACA-0777-016a)', async () => {
    const MACHINE = 'queue-full-machine';
    // Seed the store directly (bypassing HTTP) with MAX_QUEUE_PER_MACHINE dummy
    // entries for one machine — cheaper than 2000 real seal+POST round-trips,
    // and it still exercises the REAL readStore/writeStore the route uses.
    const seeded = readStore();
    for (let i = 0; i < 2000; i++) {
        seeded.messages.push({
            id: `seed-${i}`,
            to_team: 'ios',
            to_terminal: 'bridge',
            machine: MACHINE,
            from: 'academy:chancellor',
            ciphertext: 'x'.repeat(64),   // never validated on this path — seeded directly
            thread_id: null,
            created_at: new Date().toISOString(),
            stored_at: new Date().toISOString(),
        });
    }
    writeStore(seeded);

    const { envelope } = await sealedEnvelope({ envelope: { machine: MACHINE, id: 'one-too-many' } });
    const res = await request(app).post('/api/msg').send(envelope);
    assert.equal(res.status, 429);
    assert.equal(res.body.code, 'queue_full');

    // The queue must not have grown past the cap.
    const after = readStore();
    assert.equal(after.messages.filter(m => m.machine === MACHINE).length, 2000);
});

// ---------------------------------------------------------------------------
// GET /api/msg — deliver ciphertext to the requesting machine
// ---------------------------------------------------------------------------

test('GET /api/msg returns envelopes for the requested machine only', async () => {
    const a = await sealedEnvelope({ envelope: { machine: 'darren-m1pro-mbp' } });
    const b = await sealedEnvelope({ envelope: { machine: 'darren-m4-mini' } });
    await request(app).post('/api/msg').send(a.envelope).expect(201);
    await request(app).post('/api/msg').send(b.envelope).expect(201);

    const res = await request(app).get('/api/msg').query({ machine: 'darren-m1pro-mbp' });
    assert.equal(res.status, 200);
    assert.equal(res.body.total, 1);
    assert.equal(res.body.messages[0].machine, 'darren-m1pro-mbp');
});

test('GET /api/msg requires a machine slug (400)', async () => {
    const res = await request(app).get('/api/msg');
    assert.equal(res.status, 400);
});

// ---------------------------------------------------------------------------
// Round-trip: relay only ever handled ciphertext; recipient opens it locally
// ---------------------------------------------------------------------------

test('round-trip: seal -> POST -> GET -> sealOpen (recipient) recovers the record', async () => {
    const { record, envelope } = await sealedEnvelope({ record: { body: 'the secret is 42' } });
    await request(app).post('/api/msg').send(envelope).expect(201);

    const res = await request(app).get('/api/msg').query({ machine: envelope.machine });
    const sealedFromRelay = res.body.messages[0].ciphertext;

    // The recipient machine (here: the test, holding the private key) opens it.
    const opened = await sealOpen(sealedFromRelay, recipientKeys.publicKey, recipientKeys.privateKey);
    const recovered = JSON.parse(opened);
    assert.equal(recovered.body, 'the secret is 42');
    assert.equal(recovered.id, record.id);
});

// ---------------------------------------------------------------------------
// POST /api/msg/ack — drop delivered envelopes
// ---------------------------------------------------------------------------

test('POST /api/msg/ack removes delivered envelopes', async () => {
    const a = await sealedEnvelope();
    const b = await sealedEnvelope();
    await request(app).post('/api/msg').send(a.envelope).expect(201);
    await request(app).post('/api/msg').send(b.envelope).expect(201);

    const ack = await request(app).post('/api/msg/ack')
        .send({ machine: a.envelope.machine, ids: [a.envelope.id] });
    assert.equal(ack.status, 200);
    assert.equal(ack.body.acked, 1);

    const res = await request(app).get('/api/msg').query({ machine: a.envelope.machine });
    assert.equal(res.body.total, 1);
    assert.equal(res.body.messages[0].id, b.envelope.id);
});

test('POST /api/msg/ack is idempotent — re-acking an already-dropped id is a safe no-op (XACA-0777-016b)', async () => {
    const { envelope } = await sealedEnvelope();
    await request(app).post('/api/msg').send(envelope).expect(201);

    const first = await request(app).post('/api/msg/ack')
        .send({ machine: envelope.machine, ids: [envelope.id] });
    assert.equal(first.status, 200);
    assert.equal(first.body.acked, 1);

    // Re-ack the SAME id — it is no longer in the store. Must not error, must
    // not go negative, must report 0 acked (best-effort re-pull/re-ack safety:
    // the reporter's pull loop may legitimately re-ack after a retry).
    const second = await request(app).post('/api/msg/ack')
        .send({ machine: envelope.machine, ids: [envelope.id] });
    assert.equal(second.status, 200);
    assert.equal(second.body.acked, 0);

    // And acking an id that was NEVER stored is equally a safe no-op.
    const neverStored = await request(app).post('/api/msg/ack')
        .send({ machine: envelope.machine, ids: ['never-existed'] });
    assert.equal(neverStored.status, 200);
    assert.equal(neverStored.body.acked, 0);
});

test('POST /api/msg/ack rejects a non-array ids (400)', async () => {
    const res = await request(app).post('/api/msg/ack').send({ machine: 'darren-m1pro-mbp', ids: 'nope' });
    assert.equal(res.status, 400);
});

// ---------------------------------------------------------------------------
// Bearer auth
// ---------------------------------------------------------------------------

test('with FLEET_AUTH_TOKEN set, a request without a bearer is rejected (401)', async () => {
    process.env.FLEET_AUTH_TOKEN = 'sekret-relay-token';
    try {
        const { envelope } = await sealedEnvelope();
        const noAuth = await request(app).post('/api/msg').send(envelope);
        assert.equal(noAuth.status, 401);

        const getNoAuth = await request(app).get('/api/msg').query({ machine: envelope.machine });
        assert.equal(getNoAuth.status, 401);

        const withAuth = await request(app).post('/api/msg')
            .set('Authorization', 'Bearer sekret-relay-token')
            .send(envelope);
        assert.equal(withAuth.status, 201);
    } finally {
        delete process.env.FLEET_AUTH_TOKEN;
    }
});

test('with FLEET_AUTH_TOKEN set, a wrong bearer is rejected (401)', async () => {
    process.env.FLEET_AUTH_TOKEN = 'sekret-relay-token';
    try {
        const { envelope } = await sealedEnvelope();
        const res = await request(app).post('/api/msg')
            .set('Authorization', 'Bearer wrong-token')
            .send(envelope);
        assert.equal(res.status, 401);
    } finally {
        delete process.env.FLEET_AUTH_TOKEN;
    }
});

// ---------------------------------------------------------------------------
// Pull-path robustness — msg-client.js's sealOpenLocal (XACA-0777-016c)
// ---------------------------------------------------------------------------
// The relay may hand the pull loop an envelope it cannot open (wrong/rotated
// key, tampered bytes, or — since the relay never validates CONTENT, only
// shape/length — an envelope sealed to a different machine entirely). That
// must be a null-skip, never a thrown exception that would break the
// reporter's pull loop for every OTHER (openable) envelope in the batch.

test('sealOpenLocal null-skips malformed ciphertext instead of throwing (XACA-0777-016c)', async () => {
    const recipient = await generateKeypair();
    const origReadPrivateKey = vaultKeygen.readPrivateKey;
    vaultKeygen.readPrivateKey = () => recipient.privateKey;
    try {
        // Not a valid sealed box at all (garbage base64, too short).
        const opened = await msgClient.sealOpenLocal('bm90LWEtc2VhbGVkLWJveA==', 'any-machine');
        assert.equal(opened, null);
    } finally {
        vaultKeygen.readPrivateKey = origReadPrivateKey;
    }
});

test('sealOpenLocal null-skips a ciphertext sealed to a DIFFERENT (foreign) machine (XACA-0777-016c)', async () => {
    const recipient = await generateKeypair();
    const someoneElse = await generateKeypair();
    const origReadPrivateKey = vaultKeygen.readPrivateKey;
    // The envelope is a VALID sealed box — just sealed to someone else's public
    // key. This machine's private key must fail to open it (auth failure),
    // and that failure must surface as null, not an unhandled throw.
    vaultKeygen.readPrivateKey = () => recipient.privateKey;
    try {
        const foreignSealed = await seal(JSON.stringify({ body: 'not for you' }), someoneElse.publicKey);
        const opened = await msgClient.sealOpenLocal(foreignSealed, 'any-machine');
        assert.equal(opened, null);
    } finally {
        vaultKeygen.readPrivateKey = origReadPrivateKey;
    }
});

test('sealOpenLocal opens ciphertext correctly sealed to THIS machine (control case)', async () => {
    const recipient = await generateKeypair();
    const origReadPrivateKey = vaultKeygen.readPrivateKey;
    vaultKeygen.readPrivateKey = () => recipient.privateKey;
    try {
        const sealed = await seal(JSON.stringify({ body: 'for you' }), recipient.publicKey);
        const opened = await msgClient.sealOpenLocal(sealed, 'any-machine');
        assert.equal(JSON.parse(opened).body, 'for you');
    } finally {
        vaultKeygen.readPrivateKey = origReadPrivateKey;
    }
});
