//
//  vault-routes.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Integration tests for Secret Vault API routes (XACA-0537-004).
 * Uses node --test + supertest. Mirrors fleet-routes.test.js style.
 *
 * Routes under test:
 *   GET    /api/vault/machines
 *   POST   /api/vault/machines
 *   PUT    /api/vault/machines/:id
 *   DELETE /api/vault/machines/:id[?confirm=true]
 *   GET    /api/vault/secrets
 *   GET    /api/vault/secrets/:engineSlug/:accountSlug/ciphertext
 *   POST   /api/vault/secrets
 *   PUT    /api/vault/secrets/:engineSlug/:accountSlug
 *   DELETE /api/vault/secrets/:engineSlug/:accountSlug[?confirm=true]
 *
 * Test isolation strategy (XACA-0537-006):
 *   Both vault-store and engines-store honor additive env-var path overrides
 *   (FLEET_VAULT_FILE / FLEET_ENGINES_FILE). This suite sets BOTH to unique
 *   per-process temp paths BEFORE requiring the stores, so it NEVER touches the
 *   real data/vault.json or data/engines.json. Because each test file uses its
 *   own temp paths, the suite is parallel-safe and needs no --test-concurrency=1.
 *   beforeEach() wipes the vault for a clean per-test slate; after() removes the
 *   temp artifacts.
 *
 * IMPORTANT: libsodium-wrappers initializes asynchronously. Routes call
 * vaultEnsureReady() internally. Tests that POST ciphertexts need valid sealed
 * blobs — we generate them via vault-crypto's seal() helper (which also awaits
 * sodium.ready). The before() hook ensures sodium is ready before any test runs.
 *
 * NO-PLAINTEXT GUARANTEE ASSERTION: List endpoints (GET /api/vault/secrets) must
 * never contain a `sealed` field. Tests assert this structurally.
 */

const fs       = require('fs');
const path     = require('path');
const os       = require('os');

// Point both stores at isolated temp files BEFORE requiring them. The stores
// resolve their file constants at module-load time, so these env vars must be
// set first. This suite never reads/writes the real data/*.json.
const TEST_VAULT_FILE   = path.join(os.tmpdir(), `vault-routes-vault-${process.pid}-${Date.now()}.json`);
const TEST_ENGINES_FILE = path.join(os.tmpdir(), `vault-routes-engines-${process.pid}-${Date.now()}.json`);
process.env.FLEET_VAULT_FILE   = TEST_VAULT_FILE;
process.env.FLEET_ENGINES_FILE = TEST_ENGINES_FILE;

const { test, before, after, beforeEach } = require('node:test');
const assert   = require('node:assert/strict');
const request  = require('supertest');
const express  = require('express');

// Vault dependencies (resolve their file paths from the env vars set above).
const vaultStore     = require('../lib/vault-store');
const { ensureReady, generateKeypair, seal, sealOpen } = require('../lib/vault-crypto');
const enginesStore   = require('../lib/engines-store');

// XACA-0537-012: Import the REAL vault routes module that server.js mounts. The
// previous version of this suite re-implemented the handlers inline, so it
// tested a copy rather than shipped code — route/server.js divergence could go
// undetected. By mounting registerVaultRoutes here we exercise the same handlers
// that production serves.
const { registerVaultRoutes } = require('../lib/vault-routes');

const { VAULT_FILE } = vaultStore;

// ---------------------------------------------------------------------------
// Build a minimal Express app that mounts ONLY the vault routes — using the REAL
// router module (lib/vault-routes.js), the same one server.js mounts. This
// avoids loading all of server.js (which calls listen, setInterval, etc.) while
// still exercising the shipped vault handlers + real vault-store/vault-crypto
// wiring. The middleware matches server.js (express.json with a 10mb limit).
// ---------------------------------------------------------------------------

function createVaultApp() {
    const app = express();
    app.use(express.json({ limit: '10mb' }));
    registerVaultRoutes(app);
    return app;
}

// ---------------------------------------------------------------------------
// Test state
// ---------------------------------------------------------------------------

// engines-store resolves ENGINES_FILE from FLEET_ENGINES_FILE (set above), so the
// store and these tests agree on the isolated temp path. We seed our test engine
// into THIS temp file — never the real data/engines.json.
const ENGINES_FILE = TEST_ENGINES_FILE;

let app;
let testPublicKey; // base64 32-byte X25519 pubkey for a test machine
let savedConsoleLog;

// Slugs for the engine+account we'll use in secrets tests.
// We need a real entry in engines.json. We seed one and clean up after.
const TEST_ENGINE_SLUG  = 'test-vault-engine';
const TEST_ACCOUNT_SLUG = 'test-vault-account';

before(async () => {
    // XACA-0537-012: Now that the REAL handlers run (they emit per-operation
    // `console.log` success lines that the old inline stubs did not), silence
    // console.log for the duration of the suite. Under node's parallel test
    // runner the child process shares its stdout with the structured IPC channel;
    // a flood of handler logs corrupts the parent's message framing ("Unable to
    // deserialize cloned data"). Muting here keeps production logging intact while
    // preventing test-runner IPC corruption. (Restored in after().)
    savedConsoleLog = console.log;
    console.log = () => {};

    // 0. Hard guard: stores must be using our isolated temp files, never real data.
    assert.equal(VAULT_FILE, TEST_VAULT_FILE, 'VAULT_FILE must resolve to isolated temp path');
    assert.ok(!VAULT_FILE.includes(path.join('data', 'vault.json')), 'must not point at real data/vault.json');
    assert.ok(!ENGINES_FILE.includes(path.join('data', 'engines.json')), 'must not point at real data/engines.json');

    // 1. Ensure sodium is ready before any test runs.
    await ensureReady();

    // 2. Generate a test keypair; save the public key for use across tests.
    const kp = await generateKeypair();
    testPublicKey = kp.publicKey;

    // 3. Start with no vault file (auto-seed on first read).
    try { fs.unlinkSync(VAULT_FILE); } catch (_) {}

    // 4. Seed a test engine+account into the ISOLATED engines temp file.
    //    readEngines() auto-seeds the temp file (default 'anthropic' seed), then
    //    we append our test engine.
    const registry = enginesStore.readEngines();
    const existingEngine = registry.engines.find(e => e.slug === TEST_ENGINE_SLUG);
    if (!existingEngine) {
        const now = new Date().toISOString();
        registry.engines.push({
            slug: TEST_ENGINE_SLUG,
            name: 'Test Vault Engine',
            accounts: [{
                slug:           TEST_ACCOUNT_SLUG,
                account_id:     'test-account-id',
                nickname:       'Test Account',
                env_var_name:   'TEST_VAULT_KEY',
                created_at:     now,
                updated_at:     now,
                last_validated_at: null
            }],
            updated_at: now
        });
        registry.updated_at = now;
        enginesStore.writeEngines(registry);
    }

    // 5. Create the vault test app.
    app = createVaultApp();
});

after(() => {
    // Restore console.log (muted in before() — see note there).
    if (savedConsoleLog) console.log = savedConsoleLog;

    // Remove temp artifacts (and any leftover .tmp from interrupted writes).
    for (const f of [VAULT_FILE, ENGINES_FILE]) {
        try { fs.unlinkSync(f); } catch (_) {}
        const dir = path.dirname(f);
        const base = path.basename(f);
        try {
            for (const entry of fs.readdirSync(dir)) {
                if (entry.startsWith(`${base}.tmp.`)) {
                    try { fs.unlinkSync(path.join(dir, entry)); } catch (_) {}
                }
            }
        } catch (_) {}
    }
});

beforeEach(() => {
    // Each test starts with a fresh empty vault.
    try { fs.unlinkSync(VAULT_FILE); } catch (_) {}
});

// ---------------------------------------------------------------------------
// Helper: register a machine and return its public key
// ---------------------------------------------------------------------------
async function registerMachine(id, label, publicKey) {
    const res = await request(app)
        .post('/api/vault/machines')
        .send({ id, label, public_key: publicKey });
    assert.equal(res.status, 201, `registerMachine failed: ${JSON.stringify(res.body)}`);
    return res.body;
}

// ---------------------------------------------------------------------------
// Helper: build a valid ciphertext entry (real sealed box)
// ---------------------------------------------------------------------------
async function makeSealed(plaintext, recipientPublicKeyB64) {
    return seal(plaintext, recipientPublicKeyB64);
}

// ===========================================================================
// MACHINE REGISTRATION TESTS
// ===========================================================================

test('POST /api/vault/machines — happy path registers machine and returns 201', async () => {
    const res = await request(app)
        .post('/api/vault/machines')
        .send({ id: 'm-air', label: 'MacBook Air', public_key: testPublicKey });

    assert.equal(res.status, 201);
    assert.equal(res.body.id, 'm-air');
    assert.equal(res.body.label, 'MacBook Air');
    assert.equal(res.body.public_key, testPublicKey);
    assert.ok(res.body.registered_at);
    assert.ok(res.body.updated_at);
});

test('POST /api/vault/machines — 409 on duplicate id', async () => {
    await registerMachine('m-dup', 'First', testPublicKey);

    const res = await request(app)
        .post('/api/vault/machines')
        .send({ id: 'm-dup', label: 'Second', public_key: testPublicKey });

    assert.equal(res.status, 409);
    assert.ok(res.body.error.includes('already registered'));
});

test('POST /api/vault/machines — 400 on bad public_key (not 32-byte base64)', async () => {
    const res = await request(app)
        .post('/api/vault/machines')
        .send({ id: 'm-bad', label: 'Bad Key', public_key: 'bm90YXZhbGlka2V5' }); // 12 bytes

    assert.equal(res.status, 400);
    assert.ok(res.body.details.some(d => d.includes('public_key')));
});

test('POST /api/vault/machines — 400 on invalid slug format', async () => {
    const res = await request(app)
        .post('/api/vault/machines')
        .send({ id: 'Bad-Slug!', label: 'Test', public_key: testPublicKey });

    assert.equal(res.status, 400);
    assert.ok(res.body.details.some(d => d.includes('id')));
});

test('POST /api/vault/machines — 400 on missing label', async () => {
    const res = await request(app)
        .post('/api/vault/machines')
        .send({ id: 'm-nolabel', public_key: testPublicKey });

    assert.equal(res.status, 400);
    assert.ok(res.body.details.some(d => d.includes('label')));
});

test('GET /api/vault/machines — returns empty list when no machines registered', async () => {
    const res = await request(app).get('/api/vault/machines');
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.machines, []);
    assert.equal(res.body.total, 0);
});

test('GET /api/vault/machines — returns registered machine with public_key', async () => {
    await registerMachine('m-list', 'List Test', testPublicKey);

    const res = await request(app).get('/api/vault/machines');
    assert.equal(res.status, 200);
    assert.equal(res.body.total, 1);
    assert.equal(res.body.machines[0].id, 'm-list');
    assert.equal(res.body.machines[0].public_key, testPublicKey);
});

test('PUT /api/vault/machines/:id — updates label', async () => {
    await registerMachine('m-update', 'Original Label', testPublicKey);

    const res = await request(app)
        .put('/api/vault/machines/m-update')
        .send({ label: 'Updated Label' });

    assert.equal(res.status, 200);
    assert.equal(res.body.label, 'Updated Label');
    assert.equal(res.body.id, 'm-update');
});

test('PUT /api/vault/machines/:id — 404 if machine does not exist', async () => {
    const res = await request(app)
        .put('/api/vault/machines/m-ghost')
        .send({ label: 'Ghost' });

    assert.equal(res.status, 404);
});

// ===========================================================================
// MACHINE DELETE TESTS
// ===========================================================================

test('DELETE /api/vault/machines/:id — dry-run without confirm returns usage', async () => {
    await registerMachine('m-dryrun', 'Dry Run Machine', testPublicKey);

    const res = await request(app).delete('/api/vault/machines/m-dryrun');
    assert.equal(res.status, 200);
    assert.equal(res.body.deleted, false);
    assert.ok(res.body.message.includes('confirm=true'));
    assert.ok(Array.isArray(res.body.affected_secrets));
});

test('DELETE /api/vault/machines/:id?confirm=true — removes the machine', async () => {
    await registerMachine('m-todel', 'To Delete', testPublicKey);

    const res = await request(app).delete('/api/vault/machines/m-todel?confirm=true');
    assert.equal(res.status, 200);
    assert.equal(res.body.deleted, true);

    // Verify gone
    const list = await request(app).get('/api/vault/machines');
    assert.equal(list.body.total, 0);
});

test('DELETE /api/vault/machines/:id — 404 for unknown machine', async () => {
    const res = await request(app).delete('/api/vault/machines/m-nobody?confirm=true');
    assert.equal(res.status, 404);
});

// ===========================================================================
// SECRETS: STORE (POST) TESTS
// ===========================================================================

test('POST /api/vault/secrets — happy path stores secret and returns 201 metadata only', async () => {
    await registerMachine('m-sec', 'Secret Machine', testPublicKey);
    const sealedBox = await makeSealed('sk-test-key-value', testPublicKey);

    const res = await request(app)
        .post('/api/vault/secrets')
        .send({
            engine_slug:  TEST_ENGINE_SLUG,
            account_slug: TEST_ACCOUNT_SLUG,
            label:        'Test API Key',
            ciphertexts:  [{ machine_id: 'm-sec', sealed: sealedBox }]
        });

    assert.equal(res.status, 201);
    assert.equal(res.body.engine_slug, TEST_ENGINE_SLUG);
    assert.equal(res.body.account_slug, TEST_ACCOUNT_SLUG);
    assert.ok(Array.isArray(res.body.machine_ids));
    assert.ok(res.body.machine_ids.includes('m-sec'));
    // No-plaintext guarantee: ciphertexts (with sealed bytes) must NOT be in the response.
    assert.equal(res.body.ciphertexts, undefined, 'POST response must not include ciphertexts array');
    assert.equal(res.body.sealed, undefined, 'POST response must not include sealed field');
});

test('POST /api/vault/secrets — 400 when machine_id not registered', async () => {
    // Use a valid sealed box (passes validateSecretFields) but an unregistered machine_id.
    // The route layer checks machine registration AFTER structural validation.
    const sealedBox = await makeSealed('secret-value', testPublicKey);

    const res = await request(app)
        .post('/api/vault/secrets')
        .send({
            engine_slug:  TEST_ENGINE_SLUG,
            account_slug: TEST_ACCOUNT_SLUG,
            ciphertexts:  [{ machine_id: 'm-unregistered', sealed: sealedBox }]
        });

    assert.equal(res.status, 400);
    assert.ok(res.body.details.some(d => d.includes('m-unregistered')));
});

test('POST /api/vault/secrets — 400 when sealed is too short (< 48 bytes)', async () => {
    await registerMachine('m-short', 'Short Sealed', testPublicKey);

    const res = await request(app)
        .post('/api/vault/secrets')
        .send({
            engine_slug:  TEST_ENGINE_SLUG,
            account_slug: TEST_ACCOUNT_SLUG,
            ciphertexts:  [{ machine_id: 'm-short', sealed: 'dG9vc2hvcnQ=' }] // "tooshort" = 8 bytes
        });

    assert.equal(res.status, 400);
    assert.ok(res.body.details.some(d => d.includes('sealed') || d.includes('48')));
});

test('POST /api/vault/secrets — 400 when sealed exceeds MAX_SEALED_LEN', async () => {
    await registerMachine('m-big', 'Big Sealed', testPublicKey);
    const oversized = 'A'.repeat(vaultStore.MAX_SEALED_LEN + 1);

    const res = await request(app)
        .post('/api/vault/secrets')
        .send({
            engine_slug:  TEST_ENGINE_SLUG,
            account_slug: TEST_ACCOUNT_SLUG,
            ciphertexts:  [{ machine_id: 'm-big', sealed: oversized }]
        });

    assert.equal(res.status, 400);
    assert.ok(res.body.details.some(d => d.includes('sealed')));
});

test('POST /api/vault/secrets — 400 when ciphertexts array exceeds MAX_CIPHERTEXTS', async () => {
    // Build MAX_CIPHERTEXTS + 1 entries. Each needs a registered machine to pass
    // the machine-id lookup — to keep the test fast we just let validateSecretFields
    // catch the array-length violation first (it runs before machine lookups).
    // We generate a dummy sealed payload that passes size validation.
    await ensureReady(); // already done in before(), but harmless to re-await

    // Use the real sealed payload to pass the sealed-box validation in validateSecretFields.
    const sealedBox = await makeSealed('x', testPublicKey);

    const tooMany = [];
    for (let i = 0; i <= vaultStore.MAX_CIPHERTEXTS; i++) {
        tooMany.push({ machine_id: `m-${i}`, sealed: sealedBox });
    }

    const res = await request(app)
        .post('/api/vault/secrets')
        .send({
            engine_slug:  TEST_ENGINE_SLUG,
            account_slug: TEST_ACCOUNT_SLUG,
            ciphertexts:  tooMany
        });

    assert.equal(res.status, 400);
    assert.ok(res.body.details.some(d => d.includes('ciphertexts') || d.includes(String(vaultStore.MAX_CIPHERTEXTS))));
});

test('POST /api/vault/secrets — 409 if secret already exists', async () => {
    await registerMachine('m-dup-s', 'Dup Secret Machine', testPublicKey);
    const sealedBox = await makeSealed('plaintext', testPublicKey);
    const payload = {
        engine_slug:  TEST_ENGINE_SLUG,
        account_slug: TEST_ACCOUNT_SLUG,
        ciphertexts:  [{ machine_id: 'm-dup-s', sealed: sealedBox }]
    };

    await request(app).post('/api/vault/secrets').send(payload);
    const res = await request(app).post('/api/vault/secrets').send(payload);

    assert.equal(res.status, 409);
    assert.ok(res.body.error.includes('already exists'));
});

// ===========================================================================
// SECRETS: LIST (GET) — NO-PLAINTEXT GUARANTEE
// ===========================================================================

test('GET /api/vault/secrets — returns metadata only, never sealed ciphertext', async () => {
    await registerMachine('m-list-s', 'List Secrets Machine', testPublicKey);
    const sealedBox = await makeSealed('secret-value', testPublicKey);

    await request(app)
        .post('/api/vault/secrets')
        .send({
            engine_slug:  TEST_ENGINE_SLUG,
            account_slug: TEST_ACCOUNT_SLUG,
            label:        'Listed Secret',
            ciphertexts:  [{ machine_id: 'm-list-s', sealed: sealedBox }]
        });

    const res = await request(app).get('/api/vault/secrets');
    assert.equal(res.status, 200);
    assert.equal(res.body.total, 1);

    const s = res.body.secrets[0];
    assert.equal(s.engine_slug, TEST_ENGINE_SLUG);
    assert.equal(s.account_slug, TEST_ACCOUNT_SLUG);
    assert.ok(Array.isArray(s.machine_ids));
    assert.ok(s.machine_ids.includes('m-list-s'));

    // NO-PLAINTEXT GUARANTEE: sealed field must be absent from list response.
    assert.equal(s.sealed, undefined, 'GET /api/vault/secrets must not include sealed field');
    // ciphertexts array must also be absent.
    assert.equal(s.ciphertexts, undefined, 'GET /api/vault/secrets must not include ciphertexts array');
});

test('GET /api/vault/secrets — returns empty list when vault has no secrets', async () => {
    const res = await request(app).get('/api/vault/secrets');
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.secrets, []);
    assert.equal(res.body.total, 0);
});

// ===========================================================================
// SECRETS: CIPHERTEXT DELIVERY (GET /.../ciphertext)
// ===========================================================================

test('GET /api/vault/secrets/:engine/:account/ciphertext — returns sealed blob for registered machine', async () => {
    await registerMachine('m-deliver', 'Delivery Machine', testPublicKey);
    const sealedBox = await makeSealed('the-secret', testPublicKey);

    await request(app)
        .post('/api/vault/secrets')
        .send({
            engine_slug:  TEST_ENGINE_SLUG,
            account_slug: TEST_ACCOUNT_SLUG,
            ciphertexts:  [{ machine_id: 'm-deliver', sealed: sealedBox }]
        });

    const res = await request(app)
        .get(`/api/vault/secrets/${TEST_ENGINE_SLUG}/${TEST_ACCOUNT_SLUG}/ciphertext?machine_id=m-deliver`);

    assert.equal(res.status, 200);
    assert.equal(res.body.machine_id, 'm-deliver');
    assert.equal(res.body.sealed, sealedBox);
    // The returned sealed value is ciphertext — not plaintext. No decryption happens server-side.
});

test('GET /api/vault/secrets/:engine/:account/ciphertext — 404 if no ciphertext for that machine', async () => {
    await registerMachine('m-other', 'Other Machine', testPublicKey);
    const sealedBox = await makeSealed('the-secret', testPublicKey);

    await request(app)
        .post('/api/vault/secrets')
        .send({
            engine_slug:  TEST_ENGINE_SLUG,
            account_slug: TEST_ACCOUNT_SLUG,
            ciphertexts:  [{ machine_id: 'm-other', sealed: sealedBox }]
        });

    const kp2 = await generateKeypair();
    await request(app)
        .post('/api/vault/machines')
        .send({ id: 'm-late', label: 'Late Machine', public_key: kp2.publicKey });

    // m-late was registered after the secret was sealed — no ciphertext for it.
    const res = await request(app)
        .get(`/api/vault/secrets/${TEST_ENGINE_SLUG}/${TEST_ACCOUNT_SLUG}/ciphertext?machine_id=m-late`);

    assert.equal(res.status, 404);
    assert.ok(res.body.error.includes('m-late'));
});

test('GET /api/vault/secrets/:engine/:account/ciphertext — 404 if secret does not exist', async () => {
    const res = await request(app)
        .get(`/api/vault/secrets/no-engine/no-account/ciphertext?machine_id=m-x`);
    assert.equal(res.status, 404);
});

test('GET /api/vault/secrets/:engine/:account/ciphertext — 400 if machine_id missing', async () => {
    const res = await request(app)
        .get(`/api/vault/secrets/${TEST_ENGINE_SLUG}/${TEST_ACCOUNT_SLUG}/ciphertext`);
    assert.equal(res.status, 400);
    assert.ok(res.body.error.includes('machine_id'));
});

// ===========================================================================
// SECRETS: CIPHERTEXT DELIVERY — HARDENING (XACA-0538-003)
//
// The delivery endpoint already shipped in XACA-0537. These tests AUDIT and
// HARDEN it: prove the no-plaintext guarantee structurally, lock the structured
// machine-readable `code` field added in 003 so the A.4.2/A.4.3 vault-fetch
// client can branch on error category without parsing message text, and confirm
// slug/machine_id inputs cannot inject into store lookups.
// ===========================================================================

// The set of field names a plaintext leak would plausibly use. The delivery
// response must contain NONE of these — only { machine_id, sealed, sealed_at }.
const PLAINTEXT_LEAK_FIELDS = [
    'plaintext', 'plain', 'value', 'secret', 'decrypted', 'opened',
    'cleartext', 'unsealed', 'content', 'data', 'private_key', 'privateKey',
];

test('GET .../ciphertext — happy path returns ONLY {machine_id, sealed, sealed_at} (no plaintext-shaped field)', async () => {
    await registerMachine('m-noplain', 'No Plaintext Machine', testPublicKey);
    const sealedBox = await makeSealed('super-secret-api-key', testPublicKey);

    await request(app)
        .post('/api/vault/secrets')
        .send({
            engine_slug:  TEST_ENGINE_SLUG,
            account_slug: TEST_ACCOUNT_SLUG,
            ciphertexts:  [{ machine_id: 'm-noplain', sealed: sealedBox }]
        });

    const res = await request(app)
        .get(`/api/vault/secrets/${TEST_ENGINE_SLUG}/${TEST_ACCOUNT_SLUG}/ciphertext?machine_id=m-noplain`);

    assert.equal(res.status, 200);

    // STRUCTURAL no-plaintext guarantee: the response body's key set is EXACTLY
    // the three ciphertext-delivery fields. Anything else is a regression.
    assert.deepEqual(
        Object.keys(res.body).sort(),
        ['machine_id', 'sealed', 'sealed_at'].sort(),
        'delivery response must expose only machine_id/sealed/sealed_at'
    );

    // Belt-and-suspenders: none of the plaintext-shaped field names are present.
    for (const f of PLAINTEXT_LEAK_FIELDS) {
        assert.equal(res.body[f], undefined, `delivery response must not include a '${f}' field`);
    }

    // The delivered `sealed` is the exact opaque ciphertext we stored — byte-equal,
    // not decrypted. The server returned what it holds; it never opened it.
    assert.equal(res.body.sealed, sealedBox);

    // And prove it really IS ciphertext: it only decrypts with the recipient's
    // PRIVATE key (which the server never has). We open it here in the TEST using
    // the test-only keypair to confirm the blob is a genuine sealed box, never
    // touching server code.
    const kp = await generateKeypair();
    // The original sealed box was sealed to testPublicKey; opening with a DIFFERENT
    // keypair must fail — confirming it's recipient-scoped ciphertext, not plaintext.
    await assert.rejects(
        sealOpen(res.body.sealed, kp.publicKey, kp.privateKey),
        'sealed blob must NOT open with a non-recipient key (it is genuine ciphertext)'
    );
});

test('GET .../ciphertext — 400 missing machine_id carries code=missing_machine_id', async () => {
    const res = await request(app)
        .get(`/api/vault/secrets/${TEST_ENGINE_SLUG}/${TEST_ACCOUNT_SLUG}/ciphertext`);
    assert.equal(res.status, 400);
    assert.equal(res.body.code, 'missing_machine_id');
    // structured error: JSON with a human `error`, no stack trace / internal path.
    assert.equal(typeof res.body.error, 'string');
    assert.ok(!/at \w+ \(/.test(res.body.error), 'error must not contain a stack frame');
});

test('GET .../ciphertext — 404 unknown secret carries code=secret_not_found', async () => {
    const res = await request(app)
        .get(`/api/vault/secrets/no-such-engine/no-such-account/ciphertext?machine_id=m-x`);
    assert.equal(res.status, 404);
    assert.equal(res.body.code, 'secret_not_found');
    assert.equal(typeof res.body.error, 'string');
});

test('GET .../ciphertext — 404 no-copy-for-machine carries code=no_ciphertext_for_machine + re-seal hint', async () => {
    await registerMachine('m-have', 'Has Copy', testPublicKey);
    const sealedBox = await makeSealed('the-secret', testPublicKey);
    await request(app)
        .post('/api/vault/secrets')
        .send({
            engine_slug:  TEST_ENGINE_SLUG,
            account_slug: TEST_ACCOUNT_SLUG,
            ciphertexts:  [{ machine_id: 'm-have', sealed: sealedBox }]
        });

    // Register a machine AFTER the secret was sealed — it has no copy (§4.3).
    const kpLate = await generateKeypair();
    await request(app)
        .post('/api/vault/machines')
        .send({ id: 'm-nocopy', label: 'No Copy Yet', public_key: kpLate.publicKey });

    const res = await request(app)
        .get(`/api/vault/secrets/${TEST_ENGINE_SLUG}/${TEST_ACCOUNT_SLUG}/ciphertext?machine_id=m-nocopy`);

    assert.equal(res.status, 404);
    assert.equal(res.body.code, 'no_ciphertext_for_machine');
    // The §4.3 re-seal hint must be present so the client can guide the operator.
    assert.ok(res.body.message && res.body.message.includes('Re-seal'),
        'no-copy 404 must carry the §4.3 re-seal hint in message');
    // And the two distinct 404s must be DISTINGUISHABLE by code (the whole point
    // of the additive field) — secret_not_found vs. no_ciphertext_for_machine.
    assert.notEqual(res.body.code, 'secret_not_found');
});

test('GET .../ciphertext — distinct codes let a client branch secret-missing vs no-copy without message parsing', async () => {
    await registerMachine('m-branch', 'Branch Machine', testPublicKey);
    const sealedBox = await makeSealed('v', testPublicKey);
    await request(app)
        .post('/api/vault/secrets')
        .send({
            engine_slug:  TEST_ENGINE_SLUG,
            account_slug: TEST_ACCOUNT_SLUG,
            ciphertexts:  [{ machine_id: 'm-branch', sealed: sealedBox }]
        });

    // Case A: secret exists, machine has no copy → no_ciphertext_for_machine
    const noCopy = await request(app)
        .get(`/api/vault/secrets/${TEST_ENGINE_SLUG}/${TEST_ACCOUNT_SLUG}/ciphertext?machine_id=m-ghost-recipient`);
    assert.equal(noCopy.status, 404);
    assert.equal(noCopy.body.code, 'no_ciphertext_for_machine');

    // Case B: secret does not exist at all → secret_not_found
    const noSecret = await request(app)
        .get(`/api/vault/secrets/${TEST_ENGINE_SLUG}/ghost-account/ciphertext?machine_id=m-branch`);
    assert.equal(noSecret.status, 404);
    assert.equal(noSecret.body.code, 'secret_not_found');
});

test('GET .../ciphertext — slug/machine_id are matched by exact string, no lookup injection', async () => {
    await registerMachine('m-inject', 'Injection Test', testPublicKey);
    const sealedBox = await makeSealed('inj', testPublicKey);
    await request(app)
        .post('/api/vault/secrets')
        .send({
            engine_slug:  TEST_ENGINE_SLUG,
            account_slug: TEST_ACCOUNT_SLUG,
            ciphertexts:  [{ machine_id: 'm-inject', sealed: sealedBox }]
        });

    // A machine_id that is a substring/regex-ish of the real one must NOT match —
    // lookups are `===`, not pattern matches. These are safe 404s, never a 200.
    for (const probe of ['m-inj', 'm-inject.*', '.*', 'm-inject ']) {
        const res = await request(app)
            .get(`/api/vault/secrets/${TEST_ENGINE_SLUG}/${TEST_ACCOUNT_SLUG}/ciphertext?machine_id=${encodeURIComponent(probe)}`);
        assert.equal(res.status, 404,
            `machine_id probe '${probe}' must not match the real recipient`);
        assert.equal(res.body.code, 'no_ciphertext_for_machine');
    }

    // A wildcard-ish account slug must not resolve to the real secret either.
    const wildAccount = await request(app)
        .get(`/api/vault/secrets/${TEST_ENGINE_SLUG}/${encodeURIComponent('.*')}/ciphertext?machine_id=m-inject`);
    assert.equal(wildAccount.status, 404);
    assert.equal(wildAccount.body.code, 'secret_not_found');

    // Sanity: the exact, correct request still succeeds (proves the 404s above are
    // genuine non-matches, not a broken endpoint).
    const ok = await request(app)
        .get(`/api/vault/secrets/${TEST_ENGINE_SLUG}/${TEST_ACCOUNT_SLUG}/ciphertext?machine_id=m-inject`);
    assert.equal(ok.status, 200);
    assert.equal(ok.body.sealed, sealedBox);
});

// ===========================================================================
// SECRETS: DELETE TESTS
// ===========================================================================

test('DELETE /api/vault/secrets — dry-run without confirm returns info', async () => {
    await registerMachine('m-sdry', 'Dry Run Secret Machine', testPublicKey);
    const sealedBox = await makeSealed('dry-run-secret', testPublicKey);

    await request(app)
        .post('/api/vault/secrets')
        .send({
            engine_slug:  TEST_ENGINE_SLUG,
            account_slug: TEST_ACCOUNT_SLUG,
            ciphertexts:  [{ machine_id: 'm-sdry', sealed: sealedBox }]
        });

    const res = await request(app)
        .delete(`/api/vault/secrets/${TEST_ENGINE_SLUG}/${TEST_ACCOUNT_SLUG}`);

    assert.equal(res.status, 200);
    assert.equal(res.body.deleted, false);
    assert.ok(res.body.message.includes('confirm=true'));
    assert.ok(Array.isArray(res.body.machine_ids));
    assert.ok(res.body.machine_ids.includes('m-sdry'));
});

test('DELETE /api/vault/secrets?confirm=true — removes secret', async () => {
    await registerMachine('m-srem', 'Remove Secret Machine', testPublicKey);
    const sealedBox = await makeSealed('remove-me', testPublicKey);

    await request(app)
        .post('/api/vault/secrets')
        .send({
            engine_slug:  TEST_ENGINE_SLUG,
            account_slug: TEST_ACCOUNT_SLUG,
            ciphertexts:  [{ machine_id: 'm-srem', sealed: sealedBox }]
        });

    const res = await request(app)
        .delete(`/api/vault/secrets/${TEST_ENGINE_SLUG}/${TEST_ACCOUNT_SLUG}?confirm=true`);

    assert.equal(res.status, 200);
    assert.equal(res.body.deleted, true);

    const list = await request(app).get('/api/vault/secrets');
    assert.equal(list.body.total, 0);
});

test('DELETE /api/vault/secrets — 404 for unknown secret', async () => {
    const res = await request(app)
        .delete('/api/vault/secrets/no-engine/no-account?confirm=true');
    assert.equal(res.status, 404);
});

// ===========================================================================
// PUT /api/vault/secrets — re-seal / replace ciphertext array
// ===========================================================================

test('PUT /api/vault/secrets — replaces ciphertext array (re-seal)', async () => {
    await registerMachine('m-reseal', 'Re-seal Machine', testPublicKey);
    const kp2 = await generateKeypair();
    await request(app)
        .post('/api/vault/machines')
        .send({ id: 'm-new-recipient', label: 'New Recipient', public_key: kp2.publicKey });

    const sealedBox1 = await makeSealed('original-value', testPublicKey);
    await request(app)
        .post('/api/vault/secrets')
        .send({
            engine_slug:  TEST_ENGINE_SLUG,
            account_slug: TEST_ACCOUNT_SLUG,
            ciphertexts:  [{ machine_id: 'm-reseal', sealed: sealedBox1 }]
        });

    // Re-seal to both machines
    const sealedBox2a = await makeSealed('new-value', testPublicKey);
    const sealedBox2b = await makeSealed('new-value', kp2.publicKey);

    const res = await request(app)
        .put(`/api/vault/secrets/${TEST_ENGINE_SLUG}/${TEST_ACCOUNT_SLUG}`)
        .send({
            label:       'Updated Label',
            ciphertexts: [
                { machine_id: 'm-reseal',        sealed: sealedBox2a },
                { machine_id: 'm-new-recipient',  sealed: sealedBox2b }
            ]
        });

    assert.equal(res.status, 200);
    assert.equal(res.body.machine_ids.length, 2);
    assert.ok(res.body.machine_ids.includes('m-reseal'));
    assert.ok(res.body.machine_ids.includes('m-new-recipient'));
    assert.equal(res.body.label, 'Updated Label');
    // No sealed bytes in response.
    assert.equal(res.body.ciphertexts, undefined);
    assert.equal(res.body.sealed, undefined);
});

test('PUT /api/vault/secrets — 404 if secret does not exist', async () => {
    await registerMachine('m-put404', 'Put 404', testPublicKey);
    const sealedBox = await makeSealed('x', testPublicKey);

    const res = await request(app)
        .put(`/api/vault/secrets/${TEST_ENGINE_SLUG}/nonexistent-account`)
        .send({ ciphertexts: [{ machine_id: 'm-put404', sealed: sealedBox }] });

    assert.equal(res.status, 404);
});
