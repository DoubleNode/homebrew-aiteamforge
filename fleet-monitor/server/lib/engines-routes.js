//
//  engines-routes.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * AI Engines Registry API routes (XACA-0281), extracted from server.js into a
 * mountable module (XACA-0537-012).
 *
 * Generic, multi-engine ready registry (Anthropic today; OpenAI/Ollama/etc.
 * later). Accounts carry only metadata — never actual key values.
 *
 * XACA-0537-005: GET /api/engines and GET /api/engines/:engineSlug join each
 * account against the vault at request time to add two ADDITIVE computed fields
 * (has_vault_secret, vault_recipient_count) — these are NEVER persisted into
 * engines.json. DELETE .../accounts/:accountSlug enforces referential integrity
 * with the vault (blocks/cascades vault secrets).
 *
 * Auth (XACA-0395-005): EPIC-0019 transport auth has now landed. The 3
 * mutating routes below (POST accounts, PUT account, DELETE account) are
 * gated with the shared requireApiKey middleware from ./auth-middleware —
 * additive only, no signature or contract change. The GET routes stay
 * UNGATED (out of this ticket's mutating-verb scope, contract §6) — they
 * return only account metadata, never a key value.
 *
 * Wiring: this module requires the same store singletons as server.js
 * (engines-store, vault-store). Those stores resolve their file paths from
 * FLEET_ENGINES_FILE / FLEET_VAULT_FILE at module-load time, so the
 * test-isolation seam is preserved: a caller that sets those env vars before
 * requiring this module gets isolated temp files.
 */

const enginesStore = require('./engines-store');
const vaultStore = require('./vault-store');
const { requireApiKey } = require('./auth-middleware');

/**
 * Validation helpers for engines routes.
 */
const ACCOUNT_SLUG_RE    = /^[a-z][a-z0-9-]*$/;
const ENV_VAR_NAME_RE    = /^[A-Z][A-Z0-9_]*$/;
const MAX_FIELD_LEN      = 200;
const MAX_SLUG_LEN       = 64;

/**
 * Valid values for the optional `auth_type` account field (XACA-1178-004).
 * Describes how the token behind `env_var_name` authenticates — set per
 * account, never per team (XACA-0282-012 §2.1: an account's token type is
 * fixed when it is minted, not by who uses it).
 * `none` is reserved for XACA-0283 (keyless endpoints) and is deliberately
 * not accepted here — it only makes sense once `env_var_name` becomes
 * optional, which is out of scope for this ticket.
 */
const VALID_AUTH_TYPES = ['oauth_token', 'api_key', 'gateway_token'];

function validateAccountBody(body) {
    const errors = [];
    const { slug, account_id, nickname, env_var_name, auth_type } = body;

    if (!slug || typeof slug !== 'string') {
        errors.push('slug is required');
    } else if (!ACCOUNT_SLUG_RE.test(slug)) {
        errors.push('slug must match ^[a-z][a-z0-9-]*$');
    } else if (slug.length > MAX_SLUG_LEN) {
        errors.push(`slug max length is ${MAX_SLUG_LEN}`);
    }

    if (!account_id || typeof account_id !== 'string' || !account_id.trim()) {
        errors.push('account_id is required and must be non-empty');
    } else if (account_id.trim().length > MAX_FIELD_LEN) {
        errors.push(`account_id max length is ${MAX_FIELD_LEN}`);
    }

    if (!nickname || typeof nickname !== 'string' || !nickname.trim()) {
        errors.push('nickname is required and must be non-empty');
    } else if (nickname.trim().length > MAX_FIELD_LEN) {
        errors.push(`nickname max length is ${MAX_FIELD_LEN}`);
    }

    if (!env_var_name || typeof env_var_name !== 'string') {
        errors.push('env_var_name is required');
    } else if (!ENV_VAR_NAME_RE.test(env_var_name)) {
        errors.push('env_var_name must match ^[A-Z][A-Z0-9_]*$');
    } else if (env_var_name.length > MAX_FIELD_LEN) {
        errors.push(`env_var_name max length is ${MAX_FIELD_LEN}`);
    }

    // auth_type is optional: absent or null is valid (POST omits the key;
    // PUT treats null as "remove the key" — see the PUT handler below).
    // Anything else provided must be one of the three enum values.
    if (auth_type !== undefined && auth_type !== null) {
        if (typeof auth_type !== 'string' || !VALID_AUTH_TYPES.includes(auth_type)) {
            errors.push(`auth_type must be one of: ${VALID_AUTH_TYPES.join(', ')}`);
        }
    }

    return errors;
}

/**
 * Register all /api/engines* routes on the given Express app (or router).
 *
 * @param {import('express').Application|import('express').Router} app
 */
function registerEnginesRoutes(app) {
    /**
     * GET /api/engines
     * Return the full engines registry (version, updated_at, engines with accounts).
     *
     * XACA-0537-005: Each account in the response includes two computed fields
     * derived from the vault at request time (never persisted into engines.json):
     *   has_vault_secret: boolean  — true if a vault secret exists for this account
     *   vault_recipient_count: number — number of per-machine ciphertext entries
     * These fields are ADDITIVE. All existing fields are preserved unchanged.
     */
    app.get('/api/engines', (req, res) => {
        try {
            const registry = enginesStore.readEngines();
            const vault = vaultStore.readVault();

            const enginesWithVaultStatus = registry.engines.map(engine => ({
                ...engine,
                accounts: engine.accounts.map(account => {
                    const secret = vault.secrets.find(
                        s => s.engine_slug === engine.slug && s.account_slug === account.slug
                    );
                    return {
                        ...account,
                        has_vault_secret:      secret !== undefined,
                        vault_recipient_count: secret ? secret.ciphertexts.length : 0,
                    };
                }),
            }));

            res.json({
                version: registry.version,
                updated_at: registry.updated_at,
                engines: enginesWithVaultStatus
            });
        } catch (error) {
            console.error('Error reading engines registry:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    /**
     * GET /api/engines/:engineSlug
     * Return a single engine with its accounts.
     *
     * XACA-0537-005: Same vault-status join as GET /api/engines — each account
     * carries has_vault_secret and vault_recipient_count computed at request time.
     */
    app.get('/api/engines/:engineSlug', (req, res) => {
        try {
            const { engineSlug } = req.params;
            const engine = enginesStore.findEngine(engineSlug);
            if (!engine) {
                return res.status(404).json({ error: `Engine '${engineSlug}' not found` });
            }

            const vault = vaultStore.readVault();
            const engineWithVaultStatus = {
                ...engine,
                accounts: engine.accounts.map(account => {
                    const secret = vault.secrets.find(
                        s => s.engine_slug === engineSlug && s.account_slug === account.slug
                    );
                    return {
                        ...account,
                        has_vault_secret:      secret !== undefined,
                        vault_recipient_count: secret ? secret.ciphertexts.length : 0,
                    };
                }),
            };

            res.json(engineWithVaultStatus);
        } catch (error) {
            console.error('Error reading engine:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    /**
     * POST /api/engines/:engineSlug/accounts
     * Add a new account to an engine.
     * Body: { slug, account_id, nickname, env_var_name, auth_type? }
     * `auth_type` (XACA-1178-004) is optional: oauth_token | api_key | gateway_token.
     * When provided it is validated and stored verbatim; when absent the key is
     * omitted from the stored account entirely (never stored as null).
     * Returns 201 + new account on success.
     * Returns 404 if engineSlug unknown, 409 on slug collision, 400 on validation failure.
     */
    app.post('/api/engines/:engineSlug/accounts', requireApiKey, (req, res) => {
        try {
            const { engineSlug } = req.params;
            const registry = enginesStore.readEngines();
            const engineIdx = registry.engines.findIndex(e => e.slug === engineSlug);
            if (engineIdx === -1) {
                return res.status(404).json({ error: `Engine '${engineSlug}' not found` });
            }

            const errors = validateAccountBody(req.body);
            if (errors.length > 0) {
                return res.status(400).json({ error: 'Validation failed', details: errors });
            }

            const { slug, account_id, nickname, env_var_name, auth_type } = req.body;
            const engine = registry.engines[engineIdx];

            // 409 on slug collision
            if (engine.accounts.some(a => a.slug === slug)) {
                return res.status(409).json({ error: `Account slug '${slug}' already exists in engine '${engineSlug}'` });
            }

            const now = new Date().toISOString();
            const newAccount = {
                slug,
                account_id: account_id.trim(),
                nickname: nickname.trim(),
                env_var_name,
                // Include auth_type only when provided (never store null) —
                // XACA-1178-004 / XACA-0282-012 §2.2.
                ...(auth_type !== undefined && auth_type !== null ? { auth_type } : {}),
                created_at: now,
                updated_at: now,
                last_validated_at: null
            };

            engine.accounts.push(newAccount);
            engine.updated_at = now;
            registry.updated_at = now;

            if (!enginesStore.writeEngines(registry)) {
                return res.status(500).json({ error: 'Failed to save engines registry' });
            }

            console.log(`✓ Added account '${slug}' to engine '${engineSlug}'`);
            res.status(201).json(newAccount);
        } catch (error) {
            console.error('Error adding account:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    /**
     * PUT /api/engines/:engineSlug/accounts/:accountSlug
     * Update an existing account (account_id, nickname, env_var_name, auth_type are mutable; slug is immutable).
     * `auth_type` (XACA-1178-004): absent in the body keeps the existing value, `null` removes the
     * key entirely, and anything else is validated against the enum.
     * Returns the updated account; 404 if engine or account missing; 400 on validation failure.
     */
    app.put('/api/engines/:engineSlug/accounts/:accountSlug', requireApiKey, (req, res) => {
        try {
            const { engineSlug, accountSlug } = req.params;
            const registry = enginesStore.readEngines();
            const engineIdx = registry.engines.findIndex(e => e.slug === engineSlug);
            if (engineIdx === -1) {
                return res.status(404).json({ error: `Engine '${engineSlug}' not found` });
            }

            const engine = registry.engines[engineIdx];
            const accountIdx = engine.accounts.findIndex(a => a.slug === accountSlug);
            if (accountIdx === -1) {
                return res.status(404).json({ error: `Account '${accountSlug}' not found in engine '${engineSlug}'` });
            }

            // Validate only the fields provided — build a merged candidate for validation.
            // auth_type has three-way semantics (absent/null/value), not the plain
            // "provided overrides existing" merge the other fields use — see the PUT
            // doc comment above and XACA-0282-012 §2.2.
            const existing = engine.accounts[accountIdx];
            const candidate = {
                slug: accountSlug, // slug is immutable
                account_id:   req.body.account_id  !== undefined ? req.body.account_id  : existing.account_id,
                nickname:     req.body.nickname     !== undefined ? req.body.nickname     : existing.nickname,
                env_var_name: req.body.env_var_name !== undefined ? req.body.env_var_name : existing.env_var_name,
                auth_type:    req.body.auth_type    !== undefined ? req.body.auth_type    : existing.auth_type
            };

            const errors = validateAccountBody(candidate);
            if (errors.length > 0) {
                return res.status(400).json({ error: 'Validation failed', details: errors });
            }

            const now = new Date().toISOString();
            const updatedAccount = {
                ...existing,
                account_id:   candidate.account_id.trim(),
                nickname:     candidate.nickname.trim(),
                env_var_name: candidate.env_var_name,
                updated_at:   now
            };

            if (req.body.auth_type === null) {
                delete updatedAccount.auth_type;
            } else if (req.body.auth_type !== undefined) {
                updatedAccount.auth_type = req.body.auth_type;
            }
            // else: absent from the body — existing.auth_type (or its absence) is
            // already carried forward via the `...existing` spread above.

            engine.accounts[accountIdx] = updatedAccount;
            engine.updated_at = now;
            registry.updated_at = now;

            if (!enginesStore.writeEngines(registry)) {
                return res.status(500).json({ error: 'Failed to save engines registry' });
            }

            console.log(`✓ Updated account '${accountSlug}' in engine '${engineSlug}'`);
            res.json(engine.accounts[accountIdx]);
        } catch (error) {
            console.error('Error updating account:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    /**
     * DELETE /api/engines/:engineSlug/accounts/:accountSlug
     * Remove an account from an engine.
     * Requires ?confirm=true to execute; without it returns usage info for a confirmation prompt.
     * Response always includes a `usage` field listing teams currently referencing this account
     * (populated in a future phase when machines push team-paths attribution data).
     * Returns { deleted: true, slug, usage } on success; 404 if engine or account missing.
     *
     * XACA-0537-005: Referential integrity with the secret vault.
     * If the account has vault secret(s), deletion is BLOCKED without ?confirm=true.
     * The dry-run response includes a `vault_secrets` array listing the blocking secrets
     * (engine_slug, account_slug only — no ciphertext is ever returned here).
     * With ?confirm=true AND vault secret(s) present, the vault secret(s) are also
     * removed (cascade delete) before the account is deleted from engines.json.
     * Accounts WITHOUT vault secrets: behavior is unchanged (backward compatible).
     */
    app.delete('/api/engines/:engineSlug/accounts/:accountSlug', requireApiKey, (req, res) => {
        try {
            const { engineSlug, accountSlug } = req.params;
            const { confirm } = req.query;

            const registry = enginesStore.readEngines();
            const engineIdx = registry.engines.findIndex(e => e.slug === engineSlug);
            if (engineIdx === -1) {
                return res.status(404).json({ error: `Engine '${engineSlug}' not found` });
            }

            const engine = registry.engines[engineIdx];
            const accountIdx = engine.accounts.findIndex(a => a.slug === accountSlug);
            if (accountIdx === -1) {
                return res.status(404).json({ error: `Account '${accountSlug}' not found in engine '${engineSlug}'` });
            }

            // Build usage list: teams referencing this account.
            // Phase A.3+ will populate this from machine-pushed attribution data.
            // For now returns empty array — the shape is established for forward compatibility.
            const usage = [];

            // XACA-0537-005: Check for blocking vault secrets (referential integrity).
            const blockingVaultSecret = vaultStore.findSecret(engineSlug, accountSlug);
            const vaultSecrets = blockingVaultSecret
                ? [{ engine_slug: blockingVaultSecret.engine_slug, account_slug: blockingVaultSecret.account_slug }]
                : [];

            if (confirm !== 'true') {
                // Dry-run: return usage info without deleting, so the UI can prompt the user.
                // Include vault_secrets so the caller knows deletion is blocked and why.
                return res.status(200).json({
                    deleted: false,
                    slug: accountSlug,
                    message: vaultSecrets.length > 0
                        ? 'Account has vault secret(s). Send ?confirm=true to cascade-delete vault secret(s) and the account.'
                        : 'Send ?confirm=true to execute deletion',
                    usage,
                    vault_secrets: vaultSecrets,
                });
            }

            // ?confirm=true path — cascade: remove vault secret(s) first, then the account.
            if (vaultSecrets.length > 0) {
                const vaultResult = vaultStore.removeSecret(engineSlug, accountSlug);
                if (!vaultResult.ok) {
                    return res.status(500).json({ error: 'Failed to remove vault secret(s) before account deletion' });
                }
                console.log(`✓ Cascade-deleted vault secret for '${engineSlug}/${accountSlug}'`);
            }

            engine.accounts.splice(accountIdx, 1);
            const now = new Date().toISOString();
            engine.updated_at = now;
            registry.updated_at = now;

            if (!enginesStore.writeEngines(registry)) {
                return res.status(500).json({ error: 'Failed to save engines registry' });
            }

            console.log(`✓ Deleted account '${accountSlug}' from engine '${engineSlug}'`);
            res.json({ deleted: true, slug: accountSlug, usage, vault_secrets: vaultSecrets });
        } catch (error) {
            console.error('Error deleting account:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });
}

module.exports = { registerEnginesRoutes, validateAccountBody };
