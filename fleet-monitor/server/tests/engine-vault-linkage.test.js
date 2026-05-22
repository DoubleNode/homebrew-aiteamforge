//
//  engine-vault-linkage.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Integration tests for XACA-0537-005: vault status on engine routes + account-deletion
 * referential integrity.
 *
 * Covers:
 *   GET  /api/engines             — has_vault_secret + vault_recipient_count per account
 *   GET  /api/engines/:slug       — same computed fields on single-engine response
 *   DELETE /api/engines/:slug/accounts/:slug  — blocked without ?confirm when vault secret exists
 *                                             — cascades vault secret with ?confirm=true
 *                                             — unaffected (backward compat) when no vault secret
 *
 * Test isolation (XACA-0537-006):
 *   - Both stores honor additive env-var path overrides (FLEET_VAULT_FILE /
 *     FLEET_ENGINES_FILE). This suite sets BOTH to unique per-process temp paths
 *     BEFORE requiring the stores, so it NEVER touches the real data/*.json.
 *     Each test file uses its own temp paths, so the suite is parallel-safe
 *     (no --test-concurrency=1 needed).
 *   - Each test seeds its own fixture state inline.
 *   - Uses a minimal Express app that mounts ONLY the three routes under test —
 *     avoids loading all of server.js (no listen, no setInterval, no timers).
 *
 * RULES (design doc §7 hard rules):
 *   - Routes NEVER return sealed ciphertext; tests assert these fields are absent
 *     from engine/account responses.
 *   - Vault-derived fields (has_vault_secret, vault_recipient_count) are NEVER
 *     persisted into engines.json — tests verify the engines file on disk does not
 *     contain them after a GET.
 */

const fs      = require('fs');
const path    = require('path');
const os      = require('os');

// Point both stores at isolated temp files BEFORE requiring them. The stores
// resolve their file constants at module-load time, so these env vars must be
// set first. This suite never reads/writes the real data/*.json.
const TEST_VAULT_FILE   = path.join(os.tmpdir(), `ev-linkage-vault-${process.pid}-${Date.now()}.json`);
const TEST_ENGINES_FILE = path.join(os.tmpdir(), `ev-linkage-engines-${process.pid}-${Date.now()}.json`);
process.env.FLEET_VAULT_FILE   = TEST_VAULT_FILE;
process.env.FLEET_ENGINES_FILE = TEST_ENGINES_FILE;

const { test, before, after } = require('node:test');
const assert  = require('node:assert/strict');
const request = require('supertest');
const express = require('express');

const vaultStore   = require('../lib/vault-store');
const enginesStore = require('../lib/engines-store');
const { ensureReady, generateKeypair, seal } = require('../lib/vault-crypto');

// XACA-0537-012: Import the REAL engines routes module that server.js mounts.
// The previous version of this suite re-implemented the engine handlers inline,
// so it tested a copy rather than shipped code — route/server.js divergence
// (including the vault-status join and account-deletion referential integrity)
// could go undetected. By mounting registerEnginesRoutes here we exercise the
// same handlers that production serves.
const { registerEnginesRoutes } = require('../lib/engines-routes');

const { VAULT_FILE } = vaultStore;
// engines-store resolves ENGINES_FILE from FLEET_ENGINES_FILE (set above).
const ENGINES_FILE   = TEST_ENGINES_FILE;

// ---------------------------------------------------------------------------
// Test fixture slugs — unique prefix (ev-) to avoid colliding with other suites
// ---------------------------------------------------------------------------

const ENG_SLUG   = 'ev-test-engine';
const ACC_SLUG   = 'ev-test-account';
const ACC2_SLUG  = 'ev-test-account-novault';
const MACHINE_ID = 'ev-test-machine';

// ---------------------------------------------------------------------------
// Minimal Express app: mounts the REAL engines routes module (lib/engines-routes.js),
// the same one server.js mounts. This exercises the shipped vault-status join and
// account-deletion referential-integrity handlers (not an inline copy), while
// avoiding loading all of server.js (no listen, no setInterval, no timers).
// Uses the real vaultStore + enginesStore — same wiring as server.js.
// ---------------------------------------------------------------------------

function createEngineApp() {
    const app = express();
    app.use(express.json({ limit: '1mb' }));
    registerEnginesRoutes(app);
    return app;
}

// ---------------------------------------------------------------------------
// Suite state
// ---------------------------------------------------------------------------

let app;
let testPublicKey;
let savedConsoleLog;

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

before(async () => {
    // XACA-0537-012: The REAL engine handlers emit per-operation `console.log`
    // success lines that the old inline stubs did not. Under node's parallel test
    // runner the child shares stdout with the structured IPC channel; a flood of
    // handler logs corrupts the parent's message framing ("Unable to deserialize
    // cloned data"). Mute console.log for the suite (production logging is intact;
    // this only affects the test process). Restored in after().
    savedConsoleLog = console.log;
    console.log = () => {};

    // Hard guard: stores must be using our isolated temp files, never real data.
    assert.equal(VAULT_FILE, TEST_VAULT_FILE, 'VAULT_FILE must resolve to isolated temp path');
    assert.ok(!VAULT_FILE.includes(path.join('data', 'vault.json')), 'must not point at real data/vault.json');
    assert.ok(!ENGINES_FILE.includes(path.join('data', 'engines.json')), 'must not point at real data/engines.json');

    await ensureReady();

    const kp = await generateKeypair();
    testPublicKey = kp.publicKey;

    app = createEngineApp();
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

// ---------------------------------------------------------------------------
// Helper: seed fresh test fixture (engine + two accounts) into engines.json.
// Additive — preserves any other entries (so concurrent suite test files
// that seeded their own fixtures are not disturbed).
// ---------------------------------------------------------------------------

function seedEngineFixture() {
    const now = new Date().toISOString();
    const registry = enginesStore.readEngines();
    // Remove stale copy of our test engine if present, then re-add fresh.
    registry.engines = registry.engines.filter(e => e.slug !== ENG_SLUG);
    registry.engines.push({
        slug:       ENG_SLUG,
        name:       'EV Test Engine',
        updated_at: now,
        accounts: [
            {
                slug:              ACC_SLUG,
                account_id:        'ev-acc-id',
                nickname:          'EV Test Account',
                env_var_name:      'EV_TEST_KEY',
                created_at:        now,
                updated_at:        now,
                last_validated_at: null,
            },
            {
                slug:              ACC2_SLUG,
                account_id:        'ev-acc2-id',
                nickname:          'EV No-Vault Account',
                env_var_name:      'EV_TEST_KEY2',
                created_at:        now,
                updated_at:        now,
                last_validated_at: null,
            },
        ],
    });
    registry.updated_at = now;
    enginesStore.writeEngines(registry);
}

// Helper: wipe vault.json so it auto-seeds to empty on next read.
function wipeVault() {
    try { fs.unlinkSync(VAULT_FILE); } catch (_) {}
}

// ---------------------------------------------------------------------------
// Helper: seed a vault machine + secret directly via the store.
// ---------------------------------------------------------------------------

async function seedVaultSecret(engineSlug, accountSlug, machineId, pubKey) {
    const machineResult = vaultStore.upsertMachine({ id: machineId, label: 'Test Machine', public_key: pubKey });
    assert.ok(machineResult.ok, `upsertMachine failed: ${JSON.stringify(machineResult.errors)}`);

    const sealedBox = await seal('test-secret-value', pubKey);
    const secretResult = vaultStore.upsertSecret({
        engine_slug:  engineSlug,
        account_slug: accountSlug,
        label:        'Test Secret',
        ciphertexts:  [{ machine_id: machineId, sealed: sealedBox }],
    });
    assert.ok(secretResult.ok, `upsertSecret failed: ${JSON.stringify(secretResult.errors)}`);
    return secretResult.secret;
}

// ===========================================================================
// GET /api/engines — vault status fields
// ===========================================================================

test('GET /api/engines — account WITH vault secret has has_vault_secret:true and correct vault_recipient_count', async () => {
    wipeVault();
    seedEngineFixture();
    await seedVaultSecret(ENG_SLUG, ACC_SLUG, MACHINE_ID, testPublicKey);

    const res = await request(app).get('/api/engines');
    assert.equal(res.status, 200);

    const engine  = res.body.engines.find(e => e.slug === ENG_SLUG);
    assert.ok(engine, 'test engine should be present');
    const account = engine.accounts.find(a => a.slug === ACC_SLUG);
    assert.ok(account, 'test account should be present');

    assert.equal(account.has_vault_secret,      true,  'has_vault_secret must be true');
    assert.equal(account.vault_recipient_count, 1,     'vault_recipient_count must be 1 (one machine)');
});

test('GET /api/engines — account WITHOUT vault secret has has_vault_secret:false and vault_recipient_count:0', async () => {
    wipeVault();
    seedEngineFixture();
    // No vault secret seeded.

    const res = await request(app).get('/api/engines');
    assert.equal(res.status, 200);

    const engine  = res.body.engines.find(e => e.slug === ENG_SLUG);
    const account = engine.accounts.find(a => a.slug === ACC_SLUG);

    assert.equal(account.has_vault_secret,      false, 'has_vault_secret must be false when no secret');
    assert.equal(account.vault_recipient_count, 0,     'vault_recipient_count must be 0 when no secret');
});

test('GET /api/engines — existing account fields are preserved (ADDITIVE check)', async () => {
    wipeVault();
    seedEngineFixture();

    const res = await request(app).get('/api/engines');
    assert.equal(res.status, 200);

    const engine  = res.body.engines.find(e => e.slug === ENG_SLUG);
    const account = engine.accounts.find(a => a.slug === ACC_SLUG);

    // All original fields must still be present and correct.
    assert.equal(account.slug,         ACC_SLUG,          'slug preserved');
    assert.equal(account.account_id,   'ev-acc-id',       'account_id preserved');
    assert.equal(account.nickname,     'EV Test Account', 'nickname preserved');
    assert.equal(account.env_var_name, 'EV_TEST_KEY',     'env_var_name preserved');
    assert.ok('created_at' in account,        'created_at preserved');
    assert.ok('updated_at' in account,        'updated_at preserved');
    assert.ok('last_validated_at' in account, 'last_validated_at preserved');

    // Vault-derived fields are present.
    assert.ok('has_vault_secret'      in account, 'has_vault_secret field present');
    assert.ok('vault_recipient_count' in account, 'vault_recipient_count field present');
});

test('GET /api/engines — no sealed/ciphertext fields in account response (no-plaintext rule)', async () => {
    wipeVault();
    seedEngineFixture();
    await seedVaultSecret(ENG_SLUG, ACC_SLUG, MACHINE_ID, testPublicKey);

    const res = await request(app).get('/api/engines');
    assert.equal(res.status, 200);

    const engine  = res.body.engines.find(e => e.slug === ENG_SLUG);
    const account = engine.accounts.find(a => a.slug === ACC_SLUG);

    assert.equal(account.sealed,      undefined, 'sealed must NOT appear in account');
    assert.equal(account.ciphertexts, undefined, 'ciphertexts must NOT appear in account');
});

test('GET /api/engines — two accounts on same engine have independent vault status', async () => {
    wipeVault();
    seedEngineFixture();
    // Seed a vault secret only for ACC_SLUG, not ACC2_SLUG.
    await seedVaultSecret(ENG_SLUG, ACC_SLUG, MACHINE_ID, testPublicKey);

    const res = await request(app).get('/api/engines');
    assert.equal(res.status, 200);

    const engine   = res.body.engines.find(e => e.slug === ENG_SLUG);
    const withSec  = engine.accounts.find(a => a.slug === ACC_SLUG);
    const noSec    = engine.accounts.find(a => a.slug === ACC2_SLUG);

    assert.equal(withSec.has_vault_secret,      true,  'ACC_SLUG has vault secret');
    assert.equal(withSec.vault_recipient_count, 1,     'ACC_SLUG has 1 recipient');
    assert.equal(noSec.has_vault_secret,        false, 'ACC2_SLUG has no vault secret');
    assert.equal(noSec.vault_recipient_count,   0,     'ACC2_SLUG has 0 recipients');
});

// ===========================================================================
// GET /api/engines/:engineSlug — vault status fields
// ===========================================================================

test('GET /api/engines/:engineSlug — account WITH vault secret returns has_vault_secret:true', async () => {
    wipeVault();
    seedEngineFixture();
    await seedVaultSecret(ENG_SLUG, ACC_SLUG, MACHINE_ID, testPublicKey);

    const res = await request(app).get(`/api/engines/${ENG_SLUG}`);
    assert.equal(res.status, 200);

    const account = res.body.accounts.find(a => a.slug === ACC_SLUG);
    assert.ok(account, 'account should be present');
    assert.equal(account.has_vault_secret,      true, 'has_vault_secret must be true');
    assert.equal(account.vault_recipient_count, 1,    'vault_recipient_count must be 1');
});

test('GET /api/engines/:engineSlug — account WITHOUT vault secret returns false/0', async () => {
    wipeVault();
    seedEngineFixture();

    const res = await request(app).get(`/api/engines/${ENG_SLUG}`);
    assert.equal(res.status, 200);

    const account = res.body.accounts.find(a => a.slug === ACC_SLUG);
    assert.equal(account.has_vault_secret,      false, 'has_vault_secret must be false');
    assert.equal(account.vault_recipient_count, 0,     'vault_recipient_count must be 0');
});

test('GET /api/engines/:engineSlug — existing account fields preserved (ADDITIVE check)', async () => {
    wipeVault();
    seedEngineFixture();

    const res = await request(app).get(`/api/engines/${ENG_SLUG}`);
    assert.equal(res.status, 200);

    const account = res.body.accounts.find(a => a.slug === ACC_SLUG);
    assert.equal(account.slug,         ACC_SLUG,          'slug preserved');
    assert.equal(account.account_id,   'ev-acc-id',       'account_id preserved');
    assert.equal(account.nickname,     'EV Test Account', 'nickname preserved');
    assert.equal(account.env_var_name, 'EV_TEST_KEY',     'env_var_name preserved');
    assert.ok('created_at' in account,        'created_at preserved');
    assert.ok('updated_at' in account,        'updated_at preserved');
    assert.ok('last_validated_at' in account, 'last_validated_at preserved');
});

test('GET /api/engines/:engineSlug — 404 for unknown engine', async () => {
    wipeVault();
    seedEngineFixture();

    const res = await request(app).get('/api/engines/no-such-engine');
    assert.equal(res.status, 404);
});

// ===========================================================================
// DELETE /api/engines/:engineSlug/accounts/:accountSlug — referential integrity
// ===========================================================================

test('DELETE account — dry-run (no confirm) is BLOCKED with vault_secrets list when vault secret exists', async () => {
    wipeVault();
    seedEngineFixture();
    await seedVaultSecret(ENG_SLUG, ACC_SLUG, MACHINE_ID, testPublicKey);

    const res = await request(app).delete(`/api/engines/${ENG_SLUG}/accounts/${ACC_SLUG}`);
    assert.equal(res.status, 200);
    assert.equal(res.body.deleted, false, 'dry-run must not delete');
    assert.ok(Array.isArray(res.body.vault_secrets), 'vault_secrets array must be present');
    assert.equal(res.body.vault_secrets.length, 1, 'one blocking vault secret');
    assert.equal(res.body.vault_secrets[0].engine_slug,  ENG_SLUG,  'blocking secret engine_slug matches');
    assert.equal(res.body.vault_secrets[0].account_slug, ACC_SLUG,  'blocking secret account_slug matches');
    // Blocked message must mention the vault secret.
    assert.ok(res.body.message.includes('vault secret'), 'message must mention vault secret');
});

test('DELETE account — cascade with ?confirm=true removes vault secret AND account', async () => {
    wipeVault();
    seedEngineFixture();
    await seedVaultSecret(ENG_SLUG, ACC_SLUG, MACHINE_ID, testPublicKey);

    // Confirm delete exists before.
    assert.ok(vaultStore.findSecret(ENG_SLUG, ACC_SLUG), 'vault secret must exist before deletion');

    const res = await request(app).delete(`/api/engines/${ENG_SLUG}/accounts/${ACC_SLUG}?confirm=true`);
    assert.equal(res.status, 200);
    assert.equal(res.body.deleted, true, 'account must be deleted');
    assert.equal(res.body.vault_secrets.length, 1, 'vault_secrets in response lists the cascaded secret');

    // Account must be gone from engines.json.
    const engine = enginesStore.findEngine(ENG_SLUG);
    assert.ok(engine, 'engine still exists');
    assert.equal(engine.accounts.find(a => a.slug === ACC_SLUG), undefined, 'account must be gone from engine');

    // Vault secret must also be gone.
    assert.equal(vaultStore.findSecret(ENG_SLUG, ACC_SLUG), null, 'vault secret must be removed on cascade');
});

test('DELETE account — dry-run without vault secret returns vault_secrets:[] (backward compat)', async () => {
    wipeVault();
    seedEngineFixture();
    // ACC2_SLUG has no vault secret.

    const res = await request(app).delete(`/api/engines/${ENG_SLUG}/accounts/${ACC2_SLUG}`);
    assert.equal(res.status, 200);
    assert.equal(res.body.deleted, false);
    assert.deepEqual(res.body.vault_secrets, [], 'vault_secrets must be empty array when no vault secret');
    assert.ok(!res.body.message.includes('vault secret'), 'message must not mention vault when no vault secret');
});

test('DELETE account — ?confirm=true without vault secret deletes account and returns vault_secrets:[] (backward compat)', async () => {
    wipeVault();
    seedEngineFixture();

    const res = await request(app).delete(`/api/engines/${ENG_SLUG}/accounts/${ACC2_SLUG}?confirm=true`);
    assert.equal(res.status, 200);
    assert.equal(res.body.deleted, true);
    assert.deepEqual(res.body.vault_secrets, [], 'vault_secrets must be empty when no vault secret');

    // Account must be gone.
    const engine = enginesStore.findEngine(ENG_SLUG);
    assert.equal(engine.accounts.find(a => a.slug === ACC2_SLUG), undefined, 'account must be gone');

    // The other account must still be there.
    assert.ok(engine.accounts.find(a => a.slug === ACC_SLUG), 'unrelated account must survive');
});

test('DELETE account — 404 for unknown engine', async () => {
    wipeVault();
    seedEngineFixture();

    const res = await request(app).delete('/api/engines/no-such-engine/accounts/some-account?confirm=true');
    assert.equal(res.status, 404);
});

test('DELETE account — 404 for unknown account in known engine', async () => {
    wipeVault();
    seedEngineFixture();

    const res = await request(app).delete(`/api/engines/${ENG_SLUG}/accounts/no-such-account?confirm=true`);
    assert.equal(res.status, 404);
});

// ===========================================================================
// Backward-compat: engines.json on disk must NOT contain vault-derived fields
// ===========================================================================

test('GET /api/engines does NOT persist vault-derived fields into engines.json', async () => {
    wipeVault();
    seedEngineFixture();
    await seedVaultSecret(ENG_SLUG, ACC_SLUG, MACHINE_ID, testPublicKey);

    // Hit the route to trigger the join.
    await request(app).get('/api/engines');

    // Read engines.json raw and verify no vault fields were written.
    const raw = JSON.parse(fs.readFileSync(ENGINES_FILE, 'utf8'));
    const engine  = raw.engines.find(e => e.slug === ENG_SLUG);
    const account = engine.accounts.find(a => a.slug === ACC_SLUG);

    assert.equal(account.has_vault_secret,      undefined, 'has_vault_secret must NOT be in engines.json');
    assert.equal(account.vault_recipient_count, undefined, 'vault_recipient_count must NOT be in engines.json');
});
