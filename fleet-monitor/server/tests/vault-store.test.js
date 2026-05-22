//
//  vault-store.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Unit tests for vault-store.js and vault-crypto.js.
 * Uses node --test (built-in runner, Node >= 18). No external test framework.
 *
 * IMPORTANT: libsodium-wrappers initializes ASYNC. All tests that touch seal/open
 * MUST call `await ensureReady()` (or `await sodium.ready`) before any crypto call.
 * Tests that only exercise store I/O (no seal/open) do NOT need the await.
 *
 * TEST ISOLATION (XACA-0537-006):
 *   This suite NEVER touches the real data/vault.json. It sets FLEET_VAULT_FILE
 *   to a unique per-process temp path BEFORE requiring vault-store, so the store
 *   resolves its VAULT_FILE constant to the temp file. This makes the suite
 *   hermetic and parallel-safe (every test file uses its own temp path), so the
 *   --test-concurrency=1 crutch is no longer required. The temp file is removed
 *   in after(); each test starts clean via beforeEach() unlinking it.
 *
 *   The FLEET_VAULT_FILE override is additive — production behavior with the env
 *   var unset is byte-identical to before this change.
 */

const fs     = require('fs');
const path   = require('path');
const os     = require('os');

// Point the store at an isolated temp file BEFORE requiring it. vault-store
// resolves VAULT_FILE at module-load time, so this env var must be set first.
const TEST_VAULT_FILE = path.join(os.tmpdir(), `vault-store-test-${process.pid}-${Date.now()}.json`);
process.env.FLEET_VAULT_FILE = TEST_VAULT_FILE;

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

// ---- vault-crypto (wraps libsodium) ----------------------------------------
const vaultCrypto = require('../lib/vault-crypto');
const { ensureReady, generateKeypair, seal, sealOpen, isValid32ByteKey, isValidSealedBox, getSealBytes } = vaultCrypto;

// ---- vault-store (resolves VAULT_FILE from FLEET_VAULT_FILE set above) -------
const vaultStore = require('../lib/vault-store');
const {
    readVault,
    writeVault,
    findMachine,
    findSecret,
    upsertMachine,
    removeMachine,
    upsertSecret,
    removeSecret,
    validateMachineFields,
    validateSecretFields,
    validateCiphertextFields,
    VAULT_FILE,
} = vaultStore;

// ---------------------------------------------------------------------------
// Test suite setup: isolated temp vault file (never the real data/vault.json)
// ---------------------------------------------------------------------------

before(() => {
    // Hard guard: the store must be resolving to our temp file, NOT the real
    // data/vault.json. If this fails, the FLEET_VAULT_FILE seam was bypassed.
    assert.equal(VAULT_FILE, TEST_VAULT_FILE, 'VAULT_FILE must resolve to the isolated temp path');
    assert.ok(!VAULT_FILE.includes(path.join('data', 'vault.json')), 'must not point at real data/vault.json');
    // Start with no file so the suite exercises auto-seed behavior.
    try { fs.unlinkSync(VAULT_FILE); } catch (_) {}
});

after(() => {
    // Remove our temp artifact (and any leftover .tmp from interrupted writes).
    try { fs.unlinkSync(VAULT_FILE); } catch (_) {}
    const dir = path.dirname(VAULT_FILE);
    const base = path.basename(VAULT_FILE);
    try {
        for (const f of fs.readdirSync(dir)) {
            if (f.startsWith(`${base}.tmp.`)) {
                try { fs.unlinkSync(path.join(dir, f)); } catch (_) {}
            }
        }
    } catch (_) {}
});

beforeEach(() => {
    // Each test starts with a clean empty vault.
    try { fs.unlinkSync(VAULT_FILE); } catch (_) {}
});

// ---------------------------------------------------------------------------
// vault-crypto: sodium ready + encoding guards
// ---------------------------------------------------------------------------

test('vault-crypto: ensureReady resolves without throwing', async () => {
    await assert.doesNotReject(() => ensureReady());
});

test('vault-crypto: getSealBytes returns 48', async () => {
    await ensureReady();
    assert.equal(getSealBytes(), 48);
});

test('vault-crypto: generateKeypair returns base64 public+private keys', async () => {
    await ensureReady();
    const kp = await generateKeypair();
    assert.ok(typeof kp.publicKey === 'string', 'publicKey must be a string');
    assert.ok(typeof kp.privateKey === 'string', 'privateKey must be a string');
    // Each should decode to 32 bytes.
    assert.ok(isValid32ByteKey(kp.publicKey),  'publicKey must be 32 bytes');
    assert.ok(isValid32ByteKey(kp.privateKey), 'privateKey must be 32 bytes');
});

test('vault-crypto: isValid32ByteKey returns true for 32-byte base64', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    assert.ok(isValid32ByteKey(publicKey));
});

test('vault-crypto: isValid32ByteKey returns false for wrong-length input', async () => {
    await ensureReady();
    // 31 bytes base64-encoded
    const short = Buffer.alloc(31).toString('base64');
    assert.ok(!isValid32ByteKey(short));
    // 33 bytes
    const long = Buffer.alloc(33).toString('base64');
    assert.ok(!isValid32ByteKey(long));
});

test('vault-crypto: isValid32ByteKey returns false for non-base64 garbage', async () => {
    await ensureReady();
    assert.ok(!isValid32ByteKey('not-base64!!!'));
});

test('vault-crypto: isValidSealedBox returns true for a real sealed box', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    const sealedB64 = await seal('hello', publicKey);
    assert.ok(isValidSealedBox(sealedB64));
});

test('vault-crypto: isValidSealedBox returns false for short input (< 48 bytes)', async () => {
    await ensureReady();
    // 47 bytes
    const short = Buffer.alloc(47).toString('base64');
    assert.ok(!isValidSealedBox(short));
});

test('vault-crypto: seal + sealOpen round-trip produces original plaintext', async () => {
    await ensureReady();
    const kp = await generateKeypair();
    const plaintext = 'sk-ant-super-secret-key-12345';
    const sealedB64 = await seal(plaintext, kp.publicKey);
    const opened    = await sealOpen(sealedB64, kp.publicKey, kp.privateKey);
    assert.equal(opened, plaintext);
});

test('vault-crypto: sealOpen throws on tampered ciphertext', async () => {
    await ensureReady();
    const kp = await generateKeypair();
    const sealedB64 = await seal('secret', kp.publicKey);
    // Flip a byte in the middle of the decoded bytes and re-encode.
    const bytes = Buffer.from(sealedB64, 'base64');
    bytes[24] ^= 0xff;
    const tampered = bytes.toString('base64');
    await assert.rejects(() => sealOpen(tampered, kp.publicKey, kp.privateKey));
});

test('vault-crypto: sealOpen throws with wrong private key', async () => {
    await ensureReady();
    const kp1 = await generateKeypair();
    const kp2 = await generateKeypair();
    const sealedB64 = await seal('secret', kp1.publicKey);
    // Attempt to open with kp2's keys — must fail.
    await assert.rejects(() => sealOpen(sealedB64, kp2.publicKey, kp2.privateKey));
});

// ---------------------------------------------------------------------------
// readVault: auto-seed on missing file
// ---------------------------------------------------------------------------

test('readVault: auto-seeds empty vault when vault.json is missing', () => {
    // beforeEach already deleted vault.json
    assert.ok(!fs.existsSync(VAULT_FILE), 'pre-condition: vault.json should not exist');
    const vault = readVault();
    assert.equal(vault.version, 1);
    assert.ok(typeof vault.updated_at === 'string' && vault.updated_at.length > 0, 'updated_at must be set');
    assert.deepEqual(vault.machines, []);
    assert.deepEqual(vault.secrets, []);
    // File should now exist on disk.
    assert.ok(fs.existsSync(VAULT_FILE), 'vault.json should be created after seed');
});

test('readVault: returns existing data when file already exists', () => {
    const payload = {
        version: 1,
        updated_at: '2026-01-01T00:00:00.000Z',
        machines: [{ id: 'm-test', label: 'Test', public_key: 'x', registered_at: '', updated_at: '' }],
        secrets: [],
    };
    fs.writeFileSync(VAULT_FILE, JSON.stringify(payload));
    const vault = readVault();
    assert.equal(vault.machines.length, 1);
    assert.equal(vault.machines[0].id, 'm-test');
});

// ---------------------------------------------------------------------------
// writeVault: atomic write round-trip
// ---------------------------------------------------------------------------

test('writeVault: returns true and persists data', () => {
    const data = {
        version: 1,
        updated_at: new Date().toISOString(),
        machines: [],
        secrets: [],
    };
    const ok = writeVault(data);
    assert.ok(ok);
    assert.ok(fs.existsSync(VAULT_FILE));
    const read = JSON.parse(fs.readFileSync(VAULT_FILE, 'utf8'));
    assert.equal(read.version, 1);
    assert.deepEqual(read.machines, []);
});

test('writeVault: no .tmp file left behind after successful write', () => {
    const data = { version: 1, updated_at: new Date().toISOString(), machines: [], secrets: [] };
    writeVault(data);
    const dir = path.dirname(VAULT_FILE);
    // The store writes `${VAULT_FILE}.tmp.${pid}`. Derive the prefix from the
    // actual file basename so this assertion stays valid regardless of the
    // (now temp-isolated) path — a hardcoded 'vault.json.tmp.' would never match.
    const tmpPrefix = `${path.basename(VAULT_FILE)}.tmp.`;
    const tmpFiles = fs.readdirSync(dir).filter(f => f.startsWith(tmpPrefix));
    assert.equal(tmpFiles.length, 0, 'no .tmp files should remain after successful write');
});

// ---------------------------------------------------------------------------
// findMachine / findSecret: lookup helpers
// ---------------------------------------------------------------------------

test('findMachine: returns null when vault is empty', () => {
    const result = findMachine('m-air');
    assert.equal(result, null);
});

test('findMachine: returns machine when it exists', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    upsertMachine({ id: 'm-air', label: 'MacBook Air', public_key: publicKey });
    const found = findMachine('m-air');
    assert.ok(found !== null);
    assert.equal(found.id, 'm-air');
    assert.equal(found.label, 'MacBook Air');
});

test('findMachine: returns null for unknown id', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    upsertMachine({ id: 'm-air', label: 'Air', public_key: publicKey });
    assert.equal(findMachine('m-mini'), null);
});

test('findSecret: returns null when vault is empty', () => {
    const result = findSecret('anthropic', 'personal');
    assert.equal(result, null);
});

test('findSecret: returns secret by (engine_slug, account_slug)', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    upsertMachine({ id: 'm-air', label: 'Air', public_key: publicKey });
    const sealedB64 = await seal('sk-ant-test', publicKey);
    upsertSecret({
        engine_slug:  'anthropic',
        account_slug: 'personal',
        label:        'Anthropic personal key',
        ciphertexts:  [{ machine_id: 'm-air', sealed: sealedB64 }],
    });
    const found = findSecret('anthropic', 'personal');
    assert.ok(found !== null);
    assert.equal(found.engine_slug, 'anthropic');
    assert.equal(found.account_slug, 'personal');
});

test('findSecret: returns null when key pair does not match', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    const sealedB64 = await seal('test', publicKey);
    upsertMachine({ id: 'm-air', label: 'Air', public_key: publicKey });
    upsertSecret({
        engine_slug:  'anthropic',
        account_slug: 'personal',
        ciphertexts:  [{ machine_id: 'm-air', sealed: sealedB64 }],
    });
    assert.equal(findSecret('anthropic', 'work'), null);
    assert.equal(findSecret('openai', 'personal'), null);
});

// ---------------------------------------------------------------------------
// upsertMachine: add + update
// ---------------------------------------------------------------------------

test('upsertMachine: creates new machine with server-set timestamps', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    const before = new Date();
    const result = upsertMachine({ id: 'm-air', label: 'MacBook Air', public_key: publicKey });
    assert.ok(result.ok, JSON.stringify(result.errors));
    assert.ok(result.machine);
    assert.equal(result.machine.id, 'm-air');
    assert.ok(new Date(result.machine.registered_at) >= before);
    assert.ok(new Date(result.machine.updated_at) >= before);
});

test('upsertMachine: updates existing machine without changing registered_at', async () => {
    await ensureReady();
    const { publicKey: pk1 } = await generateKeypair();
    const { publicKey: pk2 } = await generateKeypair();
    upsertMachine({ id: 'm-air', label: 'Old Label', public_key: pk1 });
    const original = findMachine('m-air');
    const originalRegisteredAt = original.registered_at;

    // Small delay so timestamps differ.
    await new Promise(r => setTimeout(r, 5));

    const result = upsertMachine({ id: 'm-air', label: 'New Label', public_key: pk2 });
    assert.ok(result.ok);
    assert.equal(result.machine.label, 'New Label');
    assert.equal(result.machine.public_key, pk2);
    assert.equal(result.machine.registered_at, originalRegisteredAt, 'registered_at must not change on update');
    assert.notEqual(result.machine.updated_at, originalRegisteredAt);
});

test('upsertMachine: returns errors for missing id', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    const result = upsertMachine({ label: 'Air', public_key: publicKey });
    assert.ok(!result.ok);
    assert.ok(result.errors.some(e => e.includes('id')));
});

test('upsertMachine: rejects invalid slug in id', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    const result = upsertMachine({ id: 'UPPERCASE', label: 'Air', public_key: publicKey });
    assert.ok(!result.ok);
    assert.ok(result.errors.some(e => e.includes('id')));
});

test('upsertMachine: rejects public_key that decodes to wrong length', async () => {
    await ensureReady();
    // 31-byte key, not 32
    const shortKey = Buffer.alloc(31).toString('base64');
    const result = upsertMachine({ id: 'm-air', label: 'Air', public_key: shortKey });
    assert.ok(!result.ok);
    assert.ok(result.errors.some(e => e.includes('public_key')));
});

// ---------------------------------------------------------------------------
// removeMachine
// ---------------------------------------------------------------------------

test('removeMachine: removes existing machine and returns existed=true', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    upsertMachine({ id: 'm-air', label: 'Air', public_key: publicKey });
    const result = removeMachine('m-air');
    assert.ok(result.ok);
    assert.ok(result.existed);
    assert.equal(findMachine('m-air'), null);
});

test('removeMachine: returns existed=false for unknown machine', () => {
    const result = removeMachine('m-nonexistent');
    assert.ok(result.ok);
    assert.ok(!result.existed);
});

// ---------------------------------------------------------------------------
// upsertSecret: add + replace
// ---------------------------------------------------------------------------

test('upsertSecret: creates new secret with server-set timestamps', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    upsertMachine({ id: 'm-air', label: 'Air', public_key: publicKey });
    const sealedB64 = await seal('sk-ant-abc', publicKey);
    const before = new Date();
    const result = upsertSecret({
        engine_slug:  'anthropic',
        account_slug: 'personal',
        label:        'Anthropic key',
        ciphertexts:  [{ machine_id: 'm-air', sealed: sealedB64 }],
    });
    assert.ok(result.ok, JSON.stringify(result.errors));
    assert.ok(result.secret);
    assert.ok(new Date(result.secret.created_at) >= before);
    assert.ok(new Date(result.secret.updated_at) >= before);
    assert.equal(result.secret.ciphertexts.length, 1);
    assert.equal(result.secret.ciphertexts[0].machine_id, 'm-air');
});

test('upsertSecret: replaces ciphertexts on second call (re-seal pattern)', async () => {
    await ensureReady();
    const { publicKey: pk1 } = await generateKeypair();
    const { publicKey: pk2 } = await generateKeypair();
    upsertMachine({ id: 'm-air', label: 'Air', public_key: pk1 });
    upsertMachine({ id: 'm-mini', label: 'Mini', public_key: pk2 });

    const s1 = await seal('secret-v1', pk1);
    upsertSecret({
        engine_slug:  'anthropic',
        account_slug: 'personal',
        ciphertexts:  [{ machine_id: 'm-air', sealed: s1 }],
    });
    const original = findSecret('anthropic', 'personal');
    const originalCreatedAt = original.created_at;

    await new Promise(r => setTimeout(r, 5));

    // Re-seal to BOTH machines.
    const s1v2 = await seal('secret-v2', pk1);
    const s2v2 = await seal('secret-v2', pk2);
    const result = upsertSecret({
        engine_slug:  'anthropic',
        account_slug: 'personal',
        ciphertexts:  [
            { machine_id: 'm-air',  sealed: s1v2 },
            { machine_id: 'm-mini', sealed: s2v2 },
        ],
    });
    assert.ok(result.ok);
    assert.equal(result.secret.created_at, originalCreatedAt, 'created_at must be preserved on upsert');
    assert.equal(result.secret.ciphertexts.length, 2);
});

test('upsertSecret: returns errors for empty ciphertexts', () => {
    const result = upsertSecret({
        engine_slug:  'anthropic',
        account_slug: 'personal',
        ciphertexts:  [],
    });
    assert.ok(!result.ok);
    assert.ok(result.errors.some(e => e.includes('ciphertexts')));
});

test('upsertSecret: returns errors for invalid sealed ciphertext (< 48 bytes)', () => {
    const shortSealed = Buffer.alloc(47).toString('base64');
    const result = upsertSecret({
        engine_slug:  'anthropic',
        account_slug: 'personal',
        ciphertexts:  [{ machine_id: 'm-air', sealed: shortSealed }],
    });
    assert.ok(!result.ok);
    assert.ok(result.errors.some(e => e.includes('sealed')));
});

test('upsertSecret: returns errors for sealed ciphertext exceeding MAX_SEALED_LEN', async () => {
    await ensureReady();
    const oversized = 'A'.repeat(8193);
    const result = upsertSecret({
        engine_slug:  'anthropic',
        account_slug: 'personal',
        ciphertexts:  [{ machine_id: 'm-air', sealed: oversized }],
    });
    assert.ok(!result.ok);
    assert.ok(result.errors.some(e => e.includes('sealed')));
});

// ---------------------------------------------------------------------------
// removeSecret
// ---------------------------------------------------------------------------

test('removeSecret: removes existing secret and returns existed=true', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    upsertMachine({ id: 'm-air', label: 'Air', public_key: publicKey });
    const sealedB64 = await seal('test', publicKey);
    upsertSecret({ engine_slug: 'anthropic', account_slug: 'personal', ciphertexts: [{ machine_id: 'm-air', sealed: sealedB64 }] });
    const result = removeSecret('anthropic', 'personal');
    assert.ok(result.ok);
    assert.ok(result.existed);
    assert.equal(findSecret('anthropic', 'personal'), null);
});

test('removeSecret: returns existed=false for unknown secret', () => {
    const result = removeSecret('anthropic', 'nonexistent');
    assert.ok(result.ok);
    assert.ok(!result.existed);
});

// ---------------------------------------------------------------------------
// validateMachineFields / validateSecretFields: direct validation tests
// ---------------------------------------------------------------------------

test('validateMachineFields: passes for valid machine', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    const errors = validateMachineFields({ id: 'm-air', label: 'MacBook Air', public_key: publicKey });
    assert.deepEqual(errors, []);
});

test('validateMachineFields: fails for id starting with digit', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    const errors = validateMachineFields({ id: '1machine', label: 'X', public_key: publicKey });
    assert.ok(errors.length > 0);
});

test('validateMachineFields: fails for empty label', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    const errors = validateMachineFields({ id: 'm-air', label: '', public_key: publicKey });
    assert.ok(errors.length > 0, 'empty label should fail');
});

test('validateMachineFields: fails for label exceeding MAX_FIELD_LEN', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    const longLabel = 'x'.repeat(201);
    const errors = validateMachineFields({ id: 'm-air', label: longLabel, public_key: publicKey });
    assert.ok(errors.some(e => e.includes('label')));
});

test('validateSecretFields: passes for valid secret', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    const sealedB64 = await seal('val', publicKey);
    const errors = validateSecretFields({
        engine_slug:  'anthropic',
        account_slug: 'personal',
        ciphertexts:  [{ machine_id: 'm-air', sealed: sealedB64 }],
    });
    assert.deepEqual(errors, []);
});

test('validateSecretFields: fails for missing account_slug', async () => {
    await ensureReady();
    const { publicKey } = await generateKeypair();
    const sealedB64 = await seal('val', publicKey);
    const errors = validateSecretFields({
        engine_slug:  'anthropic',
        ciphertexts:  [{ machine_id: 'm-air', sealed: sealedB64 }],
    });
    assert.ok(errors.some(e => e.includes('account_slug')));
});

// ---------------------------------------------------------------------------
// Seal/open integration: store → retrieve → decrypt (proves sealed bytes are valid)
// ---------------------------------------------------------------------------

test('full round-trip: seal plaintext, store sealed box, retrieve, open on machine', async () => {
    await ensureReady();
    const kp = await generateKeypair();
    // Register machine.
    upsertMachine({ id: 'm-laptop', label: 'Laptop', public_key: kp.publicKey });

    // Client-side seal.
    const plaintext = 'sk-ant-test-api-key-goes-here';
    const sealedB64 = await seal(plaintext, kp.publicKey);

    // Store on server.
    const storeResult = upsertSecret({
        engine_slug:  'anthropic',
        account_slug: 'work',
        label:        'Test key',
        ciphertexts:  [{ machine_id: 'm-laptop', sealed: sealedB64 }],
    });
    assert.ok(storeResult.ok, JSON.stringify(storeResult.errors));

    // Machine retrieves its ciphertext and decrypts.
    const stored = findSecret('anthropic', 'work');
    assert.ok(stored !== null);
    const ct = stored.ciphertexts.find(c => c.machine_id === 'm-laptop');
    assert.ok(ct, 'ciphertext for m-laptop must be stored');

    const decrypted = await sealOpen(ct.sealed, kp.publicKey, kp.privateKey);
    assert.equal(decrypted, plaintext, 'decrypted value must match original plaintext');
});
