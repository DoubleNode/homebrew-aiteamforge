//
//  vault-routes.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Secret Vault API routes (XACA-0537-004), extracted from server.js into a
 * mountable module (XACA-0537-012).
 *
 * Implements design doc §7 (fleet-monitor/docs/SECRET-VAULT-DESIGN.md).
 *
 * HARD RULE: no endpoint returns plaintext. No endpoint calls crypto_box_seal_open.
 * The server holds opaque ciphertext sealed to machine public keys; only the
 * machine with the matching private key can open it. Routes validate shape and
 * length of ciphertext — they intentionally cannot verify content.
 *
 * Auth caveat: none of these routes are authenticated in A.4.1 (Non-Goals §1,
 * Residual Risk R1). EPIC-0019 layers transport auth on top. Routes are shaped
 * so auth middleware can wrap them without reshaping the contracts.
 *
 * Wiring: this module requires the same store singletons as server.js
 * (vault-store, vault-crypto, engines-store). Those stores resolve their file
 * paths from FLEET_VAULT_FILE / FLEET_ENGINES_FILE at module-load time, so the
 * test-isolation seam is preserved: a caller that sets those env vars before
 * requiring this module gets isolated temp files.
 */

const vaultStore = require('./vault-store');
const { ensureReady: vaultEnsureReady } = require('./vault-crypto');
const enginesStore = require('./engines-store');

/**
 * Register all /api/vault/* routes on the given Express app (or router).
 *
 * @param {import('express').Application|import('express').Router} app
 */
function registerVaultRoutes(app) {
    // ============================================================================
    // SECRET VAULT API (XACA-0537-004)
    // ============================================================================

    /**
     * GET /api/vault/machines
     * List all registered vault machines.
     * Returns metadata only: id, label, public_key, registered_at, updated_at.
     * Public keys are non-secret; safe to return (design doc §7.1).
     */
    app.get('/api/vault/machines', (req, res) => {
        try {
            const vault = vaultStore.readVault();
            res.json({
                machines: vault.machines,
                total:    vault.machines.length
            });
        } catch (error) {
            console.error('Error listing vault machines:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    /**
     * POST /api/vault/machines
     * Register a new machine with its public key.
     * Body: { id, label, public_key }
     * Validates: id slug RE + length, label non-empty ≤ MAX_FIELD_LEN,
     *            public_key base64 (ORIGINAL) decoding to exactly 32 bytes.
     * Returns 201 + new machine on success; 409 if id already exists.
     * Requires await ensureReady() before base64/crypto validation.
     */
    app.post('/api/vault/machines', async (req, res) => {
        try {
            await vaultEnsureReady();

            const errors = vaultStore.validateMachineFields(req.body);
            if (errors.length > 0) {
                return res.status(400).json({ error: 'Validation failed', details: errors });
            }

            const { id } = req.body;
            const existing = vaultStore.findMachine(id);
            if (existing) {
                return res.status(409).json({ error: `Machine id '${id}' already registered` });
            }

            const result = vaultStore.upsertMachine(req.body);
            if (!result.ok) {
                return res.status(500).json({ error: 'Failed to save vault', details: result.errors });
            }

            console.log(`✓ Registered vault machine '${id}'`);
            res.status(201).json(result.machine);
        } catch (error) {
            console.error('Error registering vault machine:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    /**
     * PUT /api/vault/machines/:id
     * Update label and/or rotate public_key for an existing machine.
     * id is immutable; bumps updated_at.
     * NOTE: rotating the key here does NOT re-seal existing secrets (design doc §5.4).
     * Body: { label?, public_key? } — merges with existing fields for validation.
     * Returns 404 if machine not found.
     */
    app.put('/api/vault/machines/:id', async (req, res) => {
        try {
            await vaultEnsureReady();

            const { id } = req.params;
            const existing = vaultStore.findMachine(id);
            if (!existing) {
                return res.status(404).json({ error: `Machine '${id}' not found` });
            }

            // Merge with existing fields so partial-body updates validate correctly.
            const candidate = {
                id,
                label:      req.body.label      !== undefined ? req.body.label      : existing.label,
                public_key: req.body.public_key  !== undefined ? req.body.public_key  : existing.public_key,
            };

            const errors = vaultStore.validateMachineFields(candidate);
            if (errors.length > 0) {
                return res.status(400).json({ error: 'Validation failed', details: errors });
            }

            const result = vaultStore.upsertMachine(candidate);
            if (!result.ok) {
                return res.status(500).json({ error: 'Failed to save vault', details: result.errors });
            }

            console.log(`✓ Updated vault machine '${id}'`);
            res.json(result.machine);
        } catch (error) {
            console.error('Error updating vault machine:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    /**
     * DELETE /api/vault/machines/:id?confirm=true
     * Deregister a machine.
     * Without ?confirm=true: dry-run — lists sealed ciphertext copies still in vault
     * for this machine_id so the caller can see what orphaned data will remain
     * (per design doc §4.4 — orphaned copies are harmless unless the private key leaked).
     * With ?confirm=true: removes the machine. Existing ciphertext copies are NOT
     * cascade-deleted (design doc §4.4).
     */
    app.delete('/api/vault/machines/:id', (req, res) => {
        try {
            const { id }      = req.params;
            const { confirm } = req.query;

            const existing = vaultStore.findMachine(id);
            if (!existing) {
                return res.status(404).json({ error: `Machine '${id}' not found` });
            }

            // Collect which secrets still have ciphertext for this machine_id.
            const vault = vaultStore.readVault();
            const affectedSecrets = vault.secrets
                .filter(s => s.ciphertexts.some(ct => ct.machine_id === id))
                .map(s => ({ engine_slug: s.engine_slug, account_slug: s.account_slug }));

            if (confirm !== 'true') {
                return res.status(200).json({
                    deleted: false,
                    id,
                    message: 'Send ?confirm=true to execute deregistration',
                    affected_secrets: affectedSecrets,
                    note: 'Existing ciphertext copies for this machine will become orphaned (harmless unless private key leaked — see design doc §4.4).'
                });
            }

            const result = vaultStore.removeMachine(id);
            if (!result.ok) {
                return res.status(500).json({ error: 'Failed to save vault' });
            }

            console.log(`✓ Deregistered vault machine '${id}'`);
            res.json({
                deleted: true,
                id,
                affected_secrets: affectedSecrets
            });
        } catch (error) {
            console.error('Error deregistering vault machine:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    /**
     * GET /api/vault/secrets
     * List sealed secrets — METADATA ONLY.
     * Returns: engine_slug, account_slug, label, created_at, updated_at,
     *          and machine_ids that have a ciphertext copy.
     * NEVER returns the `sealed` ciphertext bytes on this endpoint.
     * This is the no-plaintext guarantee: the list endpoint makes it structurally
     * impossible to read secret content through the API (design doc §7.2).
     */
    app.get('/api/vault/secrets', (req, res) => {
        try {
            const vault = vaultStore.readVault();
            const metadata = vault.secrets.map(s => ({
                engine_slug:  s.engine_slug,
                account_slug: s.account_slug,
                label:        s.label,
                created_at:   s.created_at,
                updated_at:   s.updated_at,
                machine_ids:  s.ciphertexts.map(ct => ct.machine_id),
            }));
            res.json({
                secrets: metadata,
                total:   metadata.length
            });
        } catch (error) {
            console.error('Error listing vault secrets:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    /**
     * GET /api/vault/secrets/:engineSlug/:accountSlug/ciphertext?machine_id=<id>
     * Deliver the sealed ciphertext for ONE machine so it can decrypt locally.
     * Returns { machine_id, sealed, sealed_at } for the requested recipient.
     * 404 if the secret doesn't exist, or if no ciphertext copy exists for
     * that machine_id (e.g. registered after the secret was last sealed — §4.3).
     * This endpoint returns ciphertext — NEVER plaintext. The machine decrypts
     * locally using its private key (which never leaves the machine).
     * This is the endpoint cc-launch (A.4.3) calls at boot.
     */
    app.get('/api/vault/secrets/:engineSlug/:accountSlug/ciphertext', (req, res) => {
        try {
            const { engineSlug, accountSlug } = req.params;
            const { machine_id }              = req.query;

            if (!machine_id) {
                return res.status(400).json({ error: 'machine_id query parameter is required' });
            }

            const secret = vaultStore.findSecret(engineSlug, accountSlug);
            if (!secret) {
                return res.status(404).json({ error: `Secret '${engineSlug}/${accountSlug}' not found` });
            }

            const ct = secret.ciphertexts.find(c => c.machine_id === machine_id);
            if (!ct) {
                return res.status(404).json({
                    error:   `No ciphertext for machine '${machine_id}' on secret '${engineSlug}/${accountSlug}'`,
                    message: 'Machine may have been registered after this secret was last sealed. Re-seal the secret client-side to include this machine (design doc §4.3).'
                });
            }

            // Return ciphertext for client-side decryption. NEVER call sealOpen here.
            res.json({
                machine_id: ct.machine_id,
                sealed:     ct.sealed,
                sealed_at:  ct.sealed_at,
            });
        } catch (error) {
            console.error('Error fetching secret ciphertext:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    /**
     * POST /api/vault/secrets
     * Store a new sealed secret.
     * Body: { engine_slug, account_slug, label?, ciphertexts: [{ machine_id, sealed, sealed_at? }] }
     * Validation:
     *   - engine_slug / account_slug: slug format, exist in engines.json
     *   - ciphertexts: non-empty, ≤ MAX_CIPHERTEXTS entries
     *   - each machine_id: registered in vault
     *   - each sealed: base64 (ORIGINAL), ≥ 48 bytes, ≤ MAX_SEALED_LEN chars
     * 409 if (engine_slug, account_slug) already exists — use PUT to replace.
     * 201 on creation.
     */
    app.post('/api/vault/secrets', async (req, res) => {
        try {
            await vaultEnsureReady();

            const errors = vaultStore.validateSecretFields(req.body);
            if (errors.length > 0) {
                return res.status(400).json({ error: 'Validation failed', details: errors });
            }

            const { engine_slug, account_slug, ciphertexts } = req.body;

            // Validate engine + account exist in engines.json (design doc §6.3).
            const engine = enginesStore.findEngine(engine_slug);
            if (!engine) {
                return res.status(400).json({ error: `Engine '${engine_slug}' not found in engines registry` });
            }
            const account = enginesStore.findAccount(engine_slug, account_slug);
            if (!account) {
                return res.status(400).json({ error: `Account '${account_slug}' not found in engine '${engine_slug}'` });
            }

            // Validate every machine_id in ciphertexts is registered (design doc §6.4).
            const unknownMachines = ciphertexts
                .map(ct => ct.machine_id)
                .filter(mid => !vaultStore.findMachine(mid));
            if (unknownMachines.length > 0) {
                return res.status(400).json({
                    error:   'Validation failed',
                    details: unknownMachines.map(mid => `ciphertext machine_id '${mid}' is not a registered vault machine`)
                });
            }

            // 409 if secret already exists — caller must use PUT to re-seal.
            const existing = vaultStore.findSecret(engine_slug, account_slug);
            if (existing) {
                return res.status(409).json({
                    error:   `Secret '${engine_slug}/${account_slug}' already exists`,
                    message: 'Use PUT /api/vault/secrets/:engineSlug/:accountSlug to replace the ciphertext array (re-seal)'
                });
            }

            const result = vaultStore.upsertSecret(req.body);
            if (!result.ok) {
                return res.status(500).json({ error: 'Failed to save vault', details: result.errors });
            }

            console.log(`✓ Stored vault secret '${engine_slug}/${account_slug}' (${ciphertexts.length} recipient(s))`);
            // Return secret metadata — never the sealed ciphertext array.
            res.status(201).json({
                engine_slug:  result.secret.engine_slug,
                account_slug: result.secret.account_slug,
                label:        result.secret.label,
                created_at:   result.secret.created_at,
                updated_at:   result.secret.updated_at,
                machine_ids:  result.secret.ciphertexts.map(ct => ct.machine_id),
            });
        } catch (error) {
            console.error('Error storing vault secret:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    /**
     * PUT /api/vault/secrets/:engineSlug/:accountSlug
     * Replace the ciphertext array for an existing secret (re-seal / value-rotation /
     * add-machine landing on the server). Same validation as POST.
     * Bumps updated_at; preserves created_at.
     * 404 if the secret does not exist.
     */
    app.put('/api/vault/secrets/:engineSlug/:accountSlug', async (req, res) => {
        try {
            await vaultEnsureReady();

            const { engineSlug, accountSlug } = req.params;

            const existing = vaultStore.findSecret(engineSlug, accountSlug);
            if (!existing) {
                return res.status(404).json({ error: `Secret '${engineSlug}/${accountSlug}' not found` });
            }

            // Build the full secret object for validation (merging slugs from params).
            const candidate = Object.assign({}, req.body, {
                engine_slug:  engineSlug,
                account_slug: accountSlug,
            });

            const errors = vaultStore.validateSecretFields(candidate);
            if (errors.length > 0) {
                return res.status(400).json({ error: 'Validation failed', details: errors });
            }

            // Validate engine + account still exist.
            if (!enginesStore.findEngine(engineSlug)) {
                return res.status(400).json({ error: `Engine '${engineSlug}' not found in engines registry` });
            }
            if (!enginesStore.findAccount(engineSlug, accountSlug)) {
                return res.status(400).json({ error: `Account '${accountSlug}' not found in engine '${engineSlug}'` });
            }

            // Validate every machine_id in ciphertexts is registered.
            const { ciphertexts } = candidate;
            const unknownMachines = ciphertexts
                .map(ct => ct.machine_id)
                .filter(mid => !vaultStore.findMachine(mid));
            if (unknownMachines.length > 0) {
                return res.status(400).json({
                    error:   'Validation failed',
                    details: unknownMachines.map(mid => `ciphertext machine_id '${mid}' is not a registered vault machine`)
                });
            }

            const result = vaultStore.upsertSecret(candidate);
            if (!result.ok) {
                return res.status(500).json({ error: 'Failed to save vault', details: result.errors });
            }

            console.log(`✓ Re-sealed vault secret '${engineSlug}/${accountSlug}' (${ciphertexts.length} recipient(s))`);
            res.json({
                engine_slug:  result.secret.engine_slug,
                account_slug: result.secret.account_slug,
                label:        result.secret.label,
                created_at:   result.secret.created_at,
                updated_at:   result.secret.updated_at,
                machine_ids:  result.secret.ciphertexts.map(ct => ct.machine_id),
            });
        } catch (error) {
            console.error('Error replacing vault secret:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    /**
     * DELETE /api/vault/secrets/:engineSlug/:accountSlug?confirm=true
     * Remove a secret entirely.
     * Without ?confirm=true: dry-run — returns what would be deleted.
     * With ?confirm=true: executes deletion.
     * 404 if not found.
     */
    app.delete('/api/vault/secrets/:engineSlug/:accountSlug', (req, res) => {
        try {
            const { engineSlug, accountSlug } = req.params;
            const { confirm }                 = req.query;

            const existing = vaultStore.findSecret(engineSlug, accountSlug);
            if (!existing) {
                return res.status(404).json({ error: `Secret '${engineSlug}/${accountSlug}' not found` });
            }

            if (confirm !== 'true') {
                return res.status(200).json({
                    deleted:      false,
                    engine_slug:  engineSlug,
                    account_slug: accountSlug,
                    message:      'Send ?confirm=true to execute deletion',
                    machine_ids:  existing.ciphertexts.map(ct => ct.machine_id)
                });
            }

            const result = vaultStore.removeSecret(engineSlug, accountSlug);
            if (!result.ok) {
                return res.status(500).json({ error: 'Failed to save vault' });
            }

            console.log(`✓ Deleted vault secret '${engineSlug}/${accountSlug}'`);
            res.json({
                deleted:      true,
                engine_slug:  engineSlug,
                account_slug: accountSlug
            });
        } catch (error) {
            console.error('Error deleting vault secret:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });
}

module.exports = { registerVaultRoutes };
