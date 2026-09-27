//
//  xaca-1342-013-secret-only-engine-skip.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Tests for XACA-1342-013: secret-only engines (`kind: "secret-only"`, e.g.
 * release-notify / release-wiki) must be safely handled by the Fleet Monitor
 * engines registry BEFORE any such engine is registered in production
 * engines.json (a later subitem, XACA-1342-014).
 *
 * Covers:
 *   - isSecretOnlyEngine() predicate (engines-store.js) — pure unit tests.
 *   - GET /api/engines still returns a secret-only engine (the Fleet Monitor
 *     Engines tab / vault UI need to see it exists to attach accounts/secrets
 *     to it) — proves category (d), "still safe", is intact.
 *   - POST /api/vault/secrets accepts a secret for an account under a
 *     secret-only engine with NO base_url/probe fields present anywhere on
 *     the engine — proves the vault path never requires AI-probe shape.
 *   - Nothing in engines-store.js's schema/validation rejects an unknown
 *     `kind` field — proves adding it is additive, not a breaking schema change.
 *
 * The picker-exclusion and TEST-CONNECTION-refusal behavior (category (c),
 * the actual "never offered as an AI credential" guarantee) live in
 * lcars-ui/server.py (serve_engines_list / handle_team_account_assign /
 * handle_team_account_test_connection) — a separate Python process from Fleet
 * Monitor — and are covered by lcars-ui/tests/test_xaca1342_013_secret_only_engine.py,
 * not here.
 *
 * Test isolation (XACA-0537-006): FLEET_ENGINES_FILE / FLEET_VAULT_FILE point
 * at unique per-process temp files, set BEFORE requiring the stores — this
 * suite never touches the real data/engines.json or data/vault.json.
 */

const fs   = require('fs');
const path = require('path');
const os   = require('os');

const TEST_VAULT_FILE   = path.join(os.tmpdir(), `xaca1342-013-vault-${process.pid}-${Date.now()}.json`);
const TEST_ENGINES_FILE = path.join(os.tmpdir(), `xaca1342-013-engines-${process.pid}-${Date.now()}.json`);
process.env.FLEET_VAULT_FILE   = TEST_VAULT_FILE;
process.env.FLEET_ENGINES_FILE = TEST_ENGINES_FILE;

const { test, before, after } = require('node:test');
const assert  = require('node:assert/strict');
const request = require('supertest');
const express = require('express');

const vaultStore   = require('../lib/vault-store');
const enginesStore = require('../lib/engines-store');
const { isSecretOnlyEngine } = enginesStore;
const { ensureReady, generateKeypair, seal } = require('../lib/vault-crypto');

const { registerEnginesRoutes } = require('../lib/engines-routes');
const { registerVaultRoutes }   = require('../lib/vault-routes');

const { VAULT_FILE } = vaultStore;
const ENGINES_FILE   = TEST_ENGINES_FILE;

const SECRET_ONLY_ENGINE_SLUG = 'xaca1342-release-notify';
const SECRET_ONLY_ACCOUNT_SLUG = 'academy-notify';
const MACHINE_ID = 'xaca1342-013-test-machine';

function createApp() {
    const app = express();
    app.use(express.json({ limit: '10mb' }));
    registerEnginesRoutes(app);
    registerVaultRoutes(app);
    return app;
}

let app;
let testPublicKey;
let savedConsoleLog;

before(async () => {
    // Silence per-operation console.log noise from the real route handlers —
    // node's parallel test runner shares stdout with its IPC channel (see the
    // identical note in engine-vault-linkage.test.js / vault-routes.test.js).
    savedConsoleLog = console.log;
    console.log = () => {};

    assert.equal(VAULT_FILE, TEST_VAULT_FILE, 'VAULT_FILE must resolve to isolated temp path');
    assert.ok(!VAULT_FILE.includes(path.join('data', 'vault.json')), 'must not point at real data/vault.json');
    assert.ok(!ENGINES_FILE.includes(path.join('data', 'engines.json')), 'must not point at real data/engines.json');

    await ensureReady();
    const kp = await generateKeypair();
    testPublicKey = kp.publicKey;

    // Seed a secret-only engine — deliberately NO base_url / probe_endpoint /
    // probe_model / auth_header anywhere on it, matching the real
    // release-notify/release-wiki shape (secrets only, nothing to probe).
    const registry = enginesStore.readEngines();
    const now = new Date().toISOString();
    registry.engines.push({
        slug: SECRET_ONLY_ENGINE_SLUG,
        name: 'Release Notify (test)',
        kind: 'secret-only',
        accounts: [{
            slug:         SECRET_ONLY_ACCOUNT_SLUG,
            account_id:   'academy-release-notify',
            nickname:     'Academy Release Notify',
            env_var_name: 'ACADEMY_RELEASE_NOTIFY_WEBHOOK',
            created_at:   now,
            updated_at:   now,
            last_validated_at: null
        }],
        created_at: now,
        updated_at: now
    });
    registry.updated_at = now;
    enginesStore.writeEngines(registry);

    // Register the vault machine used by the vault-secret test below.
    const machineResult = vaultStore.upsertMachine({
        id: MACHINE_ID,
        public_key: testPublicKey,
        label: 'xaca1342-013 test machine',
    });
    assert.ok(machineResult.ok, `machine seed failed: ${JSON.stringify(machineResult.errors)}`);

    app = createApp();
});

after(() => {
    if (savedConsoleLog) console.log = savedConsoleLog;
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

// ---------------------------------------------------------------------------
// isSecretOnlyEngine() — pure predicate unit tests
// ---------------------------------------------------------------------------

test('isSecretOnlyEngine: true for kind === "secret-only"', () => {
    assert.equal(isSecretOnlyEngine({ slug: 'x', kind: 'secret-only' }), true);
});

test('isSecretOnlyEngine: false for a normal AI engine (no kind field)', () => {
    assert.equal(isSecretOnlyEngine({ slug: 'anthropic', base_url: 'https://api.anthropic.com' }), false);
});

test('isSecretOnlyEngine: false for any other kind value', () => {
    assert.equal(isSecretOnlyEngine({ slug: 'x', kind: 'ai' }), false);
});

test('isSecretOnlyEngine: false for null/undefined engine (fail-closed on bad input, not throw)', () => {
    assert.equal(isSecretOnlyEngine(null), false);
    assert.equal(isSecretOnlyEngine(undefined), false);
});

// ---------------------------------------------------------------------------
// GET /api/engines — secret-only engine still visible (category d: safe)
// ---------------------------------------------------------------------------

test('GET /api/engines includes the secret-only engine with kind intact, no base_url anywhere', async () => {
    const res = await request(app).get('/api/engines');
    assert.equal(res.status, 200);

    const engine = res.body.engines.find(e => e.slug === SECRET_ONLY_ENGINE_SLUG);
    assert.ok(engine, 'secret-only engine must still be returned by GET /api/engines (Engines tab + vault UI need it)');
    assert.equal(engine.kind, 'secret-only');
    assert.equal(engine.base_url, undefined, 'a secret-only engine must never carry a base_url');
    assert.equal(engine.probe_endpoint, undefined);
    assert.equal(engine.probe_model, undefined);

    const account = engine.accounts.find(a => a.slug === SECRET_ONLY_ACCOUNT_SLUG);
    assert.ok(account, 'the secret-only engine account must still be present');
    // Additive vault-status join (XACA-0537-005) must still work generically —
    // no special-casing required for a secret-only engine's accounts.
    assert.equal(account.has_vault_secret, false);
    assert.equal(account.vault_recipient_count, 0);
});

test('adding kind to engines.json passes existing schema/validation unchanged (additive field)', () => {
    // readEngines() does no schema validation beyond JSON.parse — confirmed by
    // reading it back and finding our extra `kind` field untouched.
    const registry = enginesStore.readEngines();
    const engine = registry.engines.find(e => e.slug === SECRET_ONLY_ENGINE_SLUG);
    assert.equal(engine.kind, 'secret-only');
});

// ---------------------------------------------------------------------------
// POST /api/vault/secrets — vault path never requires AI-probe shape (category d)
// ---------------------------------------------------------------------------

test('POST /api/vault/secrets accepts a secret for the secret-only engine account', async () => {
    const sealed = await seal('https://example.invalid/webhook-token', testPublicKey);

    const res = await request(app)
        .post('/api/vault/secrets')
        .send({
            engine_slug:  SECRET_ONLY_ENGINE_SLUG,
            account_slug: SECRET_ONLY_ACCOUNT_SLUG,
            label: 'test webhook secret',
            ciphertexts: [{ machine_id: MACHINE_ID, sealed }],
        });

    assert.equal(res.status, 201, JSON.stringify(res.body));
    assert.equal(res.body.engine_slug, SECRET_ONLY_ENGINE_SLUG);
    assert.equal(res.body.account_slug, SECRET_ONLY_ACCOUNT_SLUG);
    // Never returns the sealed ciphertext.
    assert.equal(res.body.sealed, undefined);

    // GET /api/engines now reports has_vault_secret: true for this account.
    const listRes = await request(app).get('/api/engines');
    const engine = listRes.body.engines.find(e => e.slug === SECRET_ONLY_ENGINE_SLUG);
    const account = engine.accounts.find(a => a.slug === SECRET_ONLY_ACCOUNT_SLUG);
    assert.equal(account.has_vault_secret, true);
    assert.equal(account.vault_recipient_count, 1);
});
