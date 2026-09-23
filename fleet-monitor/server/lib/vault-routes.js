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
 * Auth: the 6 mutating routes below (POST/PUT/DELETE machines, POST/PUT/DELETE
 * secrets) are gated at the ADMIN tier with requireAdminKey from
 * ./auth-middleware (XACA-0395-005 added the gate; XACA-0398-003 moved it from
 * the fleet tier to the admin tier). Registering or rotating a recipient, and
 * writing or deleting a seal, therefore needs FLEET_ADMIN_TOKEN (or the LCARS
 * unlock session), not merely a fleet machine's config.
 *
 * The 4 GET routes (mode, machine list, secret list, ciphertext delivery) are
 * UNGATED by a recorded decision (XACA-0398-005; contract §6 "Recorded
 * deviation"), not by oversight. See each route's own comment for what it
 * discloses and what would reverse the decision. Do not read "vault routes are
 * gated" as "all vault routes are gated."
 *
 * PRODUCTION CAVEAT: every gate here is OPEN until FLEET_AUTH_TOKEN or
 * FLEET_ADMIN_TOKEN is set on the server (contract §7). Until the XACA-0398-006
 * cutover sets them in production, anyone who can reach the port can register a
 * recipient, so the premises below do not yet hold there.
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
const { requireAdminKey } = require('./auth-middleware');

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
     * GET /api/vault/mode
     * XACA-0539: Report whether the server is delivering secrets from the
     * encrypted vault store or from the env-var failover path.
     *
     * Per VAULT-MODE-SIGNAL-CONTRACT.md:
     *   - mode = "vault"        → store initialized from vault.json (normal)
     *   - mode = "env_failover" → vault.json absent/unreadable; env-var fallback
     *
     * Auth: none, by decision (XACA-0398-005). This endpoint is read-only and
     * never returns any credential material: it discloses only whether the
     * server is in vault or env-failover mode. `source` is a human-readable
     * label only.
     *
     * Always returns 200; both states are valid operational states, not errors.
     */
    app.get('/api/vault/mode', (req, res) => {
        try {
            const modeInfo = vaultStore.getVaultMode();
            res.json(modeInfo);
        } catch (error) {
            // Defensive catch — getVaultMode is designed not to throw, but guard
            // against unexpected runtime failures so this never emits a 5xx for a
            // normal operational state.
            console.error('Error reading vault mode:', error);
            // Return env_failover on unexpected error (conservative — better to
            // surface the warning popup than silently claim vault is healthy).
            res.json({
                mode:   'env_failover',
                source: 'environment variable fallback (FLEET_VAULT_KEY)',
            });
        }
    });

    /**
     * GET /api/vault/machines
     * List all registered vault machines.
     * Returns metadata only: id, label, public_key, registered_at, updated_at.
     * Public keys are non-secret; safe to return (design doc §7.1).
     *
     * Auth: none, by decision (XACA-0398-005). DISCLOSES to an uncredentialed
     * caller: the full vault recipient roster (machine slugs and labels, which
     * name the operator's hosts), each recipient's X25519 public key, and
     * enrollment and rotation times. No secret material. The public key lets a
     * caller seal TO a machine, never open anything. The host roster is already
     * public through GET /api/fleet.
     *
     * Consumers: LCARS vault-seal.js and vault-migrate-env-keys.js read this
     * list to choose seal recipients. Neither sends a credential today, so
     * gating it would break sealing. Being public is also a detection aid: an
     * attacker-registered recipient appears here, and every seal is made to
     * EVERY machine in this list at seal time. Review this list before sealing.
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
    app.post('/api/vault/machines', requireAdminKey, async (req, res) => {
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
    app.put('/api/vault/machines/:id', requireAdminKey, async (req, res) => {
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
    app.delete('/api/vault/machines/:id', requireAdminKey, (req, res) => {
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
     *
     * Auth: none, by decision (XACA-0398-005). DISCLOSES to an uncredentialed
     * caller: which (engine, account) secrets exist, meaning the engine names
     * and the account slugs (these name teams and billing accounts), the
     * operator-chosen labels, create and update times (when a key was last
     * rotated), and which machines can decrypt each one. No ciphertext, no
     * plaintext. This is an accepted residual (credential design §5.2).
     * vault-migrate-env-keys.js reads it without a credential (as of
     * XACA-0398-005), so gating it needs that client changed first. Revisit
     * together with the ciphertext route below.
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
     *
     * AUTH DECISION: UNGATED (XACA-0398-005, re-evaluated 2026-09-23). This is a
     * recorded deviation from contract §6: the route returns ciphertext (fails
     * R2), and its caller could present a credential (fails R3).
     *
     *   Premise. The `sealed` blob is an anonymous libsodium sealed box. Only the
     *   holder of the recipient's X25519 PRIVATE key can open it, and that key
     *   never leaves the machine (Keychain, or a 0600 file). "Registered
     *   recipient" is enforced by who the blob was sealed TO, not by an auth
     *   check here. That holds only while an attacker cannot become a recipient.
     *   Registration and rotation (POST/PUT /api/vault/machines) are now
     *   ADMIN-tier (XACA-0398-003). Sealing is client-side and point-in-time: a
     *   seal covers only the machines registered when it was made. A recipient
     *   registered later gets no copy until an operator re-seals.
     *   THE PREMISE DOES NOT HOLD IN PRODUCTION until XACA-0398-006 sets
     *   FLEET_ADMIN_TOKEN (or at least FLEET_AUTH_TOKEN). Until then the gate is
     *   open and anyone can register a recipient.
     *
     *   What this leaks to an uncredentialed caller: a blob that cannot be opened
     *   without the private key, its sealed_at, and whether (engine, account,
     *   machine) exists (the 404 codes). The last two are already public through
     *   GET /api/vault/secrets. Nothing new.
     *
     *   What a fleet-tier gate would buy: very little. Every party that could open
     *   the blob already holds the private key on a fleet machine, and so can
     *   read that machine's fleet-config.json (0600, same user). A stolen key
     *   from a backup usually comes with that file too. The admin token passes
     *   the fleet tier (admin is a superset), so the gate does not help against
     *   admin compromise either.
     *   What it would cost: vault-fetch.js sends NO credential today
     *   (kg.fleetFetchInit() is { redirect: 'manual' } only). A 401 is treated
     *   as unreachable (exit 4). cc-account-routing.sh then falls back to the
     *   stale cache, then to the env var, and then REFUSES to launch a declared
     *   team (XACA-1312). Gating before every consumer runs a vault-fetch that
     *   sends the token is a fleet-wide launch outage.
     *
     *   Residual risk if the ADMIN token is compromised: the attacker registers
     *   their own public key. That recipient is visible in the public GET
     *   /api/vault/machines. The next operator seal (LCARS vault-seal.js or
     *   vault-migrate-env-keys.js, both of which seal to EVERY listed machine)
     *   then includes the attacker, who fetches the blob here. With the admin
     *   token they could do so even if this route were gated. The mitigation is
     *   to review the recipient list before sealing and to rotate the admin
     *   token. Gating this route is not the mitigation.
     *
     *   REVERSE THIS (gate with requireApiKey, the fleet tier) when ALL of these
     *   hold: (1) vault-fetch.js sends the fleet token from fleet-config.json
     *   authToken; (2) every consumer runs a tap release that includes (1); (3)
     *   production has FLEET_AUTH_TOKEN set. Reverse sooner if the sealed box
     *   stops being sufficient on its own, for example a need for
     *   harvest-now-decrypt-later resistance or a recipient private key found
     *   stored anywhere except the machine. Do NOT add a per-recipient identity
     *   check here: the server has no machine credential to check it against.
     *
     * STRUCTURED ERROR `code` field (additive, machine-readable — XACA-0538-003):
     *   Each error carries a stable `code` so the A.4.2/A.4.3 vault-fetch client can
     *   branch WITHOUT string-matching human-readable `message` text:
     *     'missing_machine_id'    (400) — caller bug; supply ?machine_id=<id>.
     *     'secret_not_found'      (404) — no such (engine, account) secret exists.
     *     'no_ciphertext_for_machine' (404) — secret exists but has no copy for this
     *                                          machine; re-seal client-side (§4.3).
     *     'internal_error'        (500) — unexpected server fault; details suppressed.
     */
    app.get('/api/vault/secrets/:engineSlug/:accountSlug/ciphertext', (req, res) => {
        try {
            const { engineSlug, accountSlug } = req.params;
            const { machine_id }              = req.query;

            if (!machine_id) {
                return res.status(400).json({
                    error: 'machine_id query parameter is required',
                    code:  'missing_machine_id',
                });
            }

            const secret = vaultStore.findSecret(engineSlug, accountSlug);
            if (!secret) {
                return res.status(404).json({
                    error: `Secret '${engineSlug}/${accountSlug}' not found`,
                    code:  'secret_not_found',
                });
            }

            const ct = secret.ciphertexts.find(c => c.machine_id === machine_id);
            if (!ct) {
                return res.status(404).json({
                    error:   `No ciphertext for machine '${machine_id}' on secret '${engineSlug}/${accountSlug}'`,
                    code:    'no_ciphertext_for_machine',
                    message: 'Machine may have been registered after this secret was last sealed. Re-seal the secret client-side to include this machine (design doc §4.3).'
                });
            }

            // Return ciphertext for client-side decryption. NEVER call sealOpen here.
            // The server holds no private key and cannot open this blob.
            res.json({
                machine_id: ct.machine_id,
                sealed:     ct.sealed,
                sealed_at:  ct.sealed_at,
            });
        } catch (error) {
            console.error('Error fetching secret ciphertext:', error);
            res.status(500).json({ error: 'Internal server error', code: 'internal_error' });
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
    app.post('/api/vault/secrets', requireAdminKey, async (req, res) => {
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
    app.put('/api/vault/secrets/:engineSlug/:accountSlug', requireAdminKey, async (req, res) => {
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
    app.delete('/api/vault/secrets/:engineSlug/:accountSlug', requireAdminKey, (req, res) => {
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
