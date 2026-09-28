//
//  xaca-1342-025-secret-only-account-validation.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Route tests for XACA-1342-025 (UX advisory folded in after PR #974):
 * fleet-monitor/server/lib/engines-routes.js's validateAccountBody() and the
 * POST/PUT account handlers now treat a secret-only engine (`kind:
 * "secret-only"`, e.g. release-notify / release-wiki -- see engines-store.js
 * isSecretOnlyEngine()) differently from a normal AI engine:
 *
 *   - account_id is OPTIONAL for a secret-only engine's account. When
 *     omitted/blank, the server defaults it to the account slug rather than
 *     requiring an admin to invent an Anthropic-style account id for a
 *     webhook/token secret.
 *   - auth_type is REFUSED for a secret-only engine's account -- only
 *     absent/null is accepted, even a value that would otherwise be a valid
 *     enum member (oauth_token / api_key / gateway_token) -- so no
 *     OAuth/API-key/gateway state is ever recorded for a secret.
 *
 * A normal AI engine (no `kind`, or `kind !== 'secret-only'`) keeps its prior
 * behavior completely unchanged: account_id required, auth_type optional but
 * validated against the enum when present. That existing behavior is already
 * covered end-to-end by tests/engines-auth-type.test.js; this file adds a
 * small number of confirming cases alongside the new secret-only path so a
 * regression in the shared validateAccountBody() signature/branching shows up
 * here too, not only there.
 *
 * Test isolation (XACA-0537-006 pattern, same as engines-auth-type.test.js):
 * engines-store.js resolves its file path from FLEET_ENGINES_FILE at
 * module-load time, set to a unique per-process temp path BEFORE requiring
 * the store or the routes module. This suite never touches the real
 * data/engines.json.
 *
 * Auth: POST/PUT are gated by requireAdminKey (auth-middleware.js), but with
 * FLEET_ADMIN_TOKEN/FLEET_AUTH_TOKEN unset the gate is OPEN -- same posture
 * engines-auth-type.test.js and xaca-1342-013-secret-only-engine-skip.test.js
 * rely on, so no Authorization header is sent here either.
 */

const fs   = require('fs');
const path = require('path');
const os   = require('os');

// Point the engines store at an isolated temp file BEFORE requiring it.
const TEST_ENGINES_FILE = path.join(os.tmpdir(), `xaca1342-025-engines-${process.pid}-${Date.now()}.json`);
process.env.FLEET_ENGINES_FILE = TEST_ENGINES_FILE;

const { test, before, beforeEach, after } = require('node:test');
const assert  = require('node:assert/strict');
const request = require('supertest');
const express = require('express');

const enginesStore = require('../lib/engines-store');

// XACA-0537-012 pattern: import the REAL routes module server.js mounts,
// not an inline re-implementation, so this exercises shipped code.
const { registerEnginesRoutes, validateAccountBody } = require('../lib/engines-routes');

const ENGINES_FILE = TEST_ENGINES_FILE;

const SECRET_ENGINE_SLUG = 'xaca1342-025-release-notify';
const AI_ENGINE_SLUG     = 'xaca1342-025-ai-engine';

let app;
let savedConsoleLog;

function createEngineApp() {
    const a = express();
    a.use(express.json({ limit: '1mb' }));
    registerEnginesRoutes(a);
    return a;
}

// Seed a fresh secret-only engine and a fresh normal AI engine before each
// test -- keeps every test independent of what a previous one wrote.
function seedEngines() {
    const now = new Date().toISOString();
    const registry = enginesStore.readEngines();
    registry.engines = registry.engines.filter(
        e => e.slug !== SECRET_ENGINE_SLUG && e.slug !== AI_ENGINE_SLUG
    );
    registry.engines.push({
        slug: SECRET_ENGINE_SLUG,
        name: 'Release Notify (test)',
        kind: 'secret-only',
        updated_at: now,
        accounts: []
    });
    registry.engines.push({
        slug: AI_ENGINE_SLUG,
        name: 'AI Engine (test)',
        // no `kind` -- a normal AI engine, matching the real anthropic seed shape
        updated_at: now,
        accounts: []
    });
    registry.updated_at = now;
    enginesStore.writeEngines(registry);
}

function addAccount(engineSlug, body) {
    return request(app).post(`/api/engines/${engineSlug}/accounts`).send(body);
}

function updateAccount(engineSlug, slug, body) {
    return request(app).put(`/api/engines/${engineSlug}/accounts/${slug}`).send(body);
}

before(() => {
    savedConsoleLog = console.log;
    console.log = () => {};

    assert.ok(!ENGINES_FILE.includes(path.join('data', 'engines.json')),
        'must not point at real data/engines.json');

    app = createEngineApp();
});

after(() => {
    if (savedConsoleLog) console.log = savedConsoleLog;
    try { fs.unlinkSync(ENGINES_FILE); } catch (_) { /* ignore */ }
    const dir = path.dirname(ENGINES_FILE);
    const base = path.basename(ENGINES_FILE);
    try {
        for (const entry of fs.readdirSync(dir)) {
            if (entry.startsWith(`${base}.tmp.`)) {
                try { fs.unlinkSync(path.join(dir, entry)); } catch (_) { /* ignore */ }
            }
        }
    } catch (_) { /* ignore */ }
});

beforeEach(() => {
    seedEngines();
});

// ===========================================================================
// validateAccountBody() -- pure unit tests, secretOnly option
// ===========================================================================

test('validateAccountBody: secretOnly true, account_id omitted -- no error', () => {
    const errors = validateAccountBody(
        { slug: 'x', nickname: 'X', env_var_name: 'RELEASE_X_Y' },
        { secretOnly: true }
    );
    assert.deepEqual(errors, []);
});

test('validateAccountBody: secretOnly true, auth_type provided (even a valid enum value) -- error', () => {
    const errors = validateAccountBody(
        { slug: 'x', nickname: 'X', env_var_name: 'RELEASE_X_Y', auth_type: 'oauth_token' },
        { secretOnly: true }
    );
    assert.ok(errors.some(e => e.includes('auth_type')), JSON.stringify(errors));
});

test('validateAccountBody: secretOnly false (default/omitted options), account_id required -- unchanged', () => {
    const errors = validateAccountBody({ slug: 'x', nickname: 'X', env_var_name: 'ENV_X' });
    assert.ok(errors.some(e => e.includes('account_id')), JSON.stringify(errors));
});

// ===========================================================================
// POST /api/engines/:engineSlug/accounts -- secret-only engine
// ===========================================================================

test('POST secret-only engine account -- account_id omitted defaults to the slug', async () => {
    const res = await addAccount(SECRET_ENGINE_SLUG, {
        slug: 'firebase-cr-approver',
        nickname: 'Firebase CR Approver',
        env_var_name: 'RELEASE_FIREBASE_CR_APPROVER'
    });
    assert.equal(res.status, 201, JSON.stringify(res.body));
    assert.equal(res.body.account_id, 'firebase-cr-approver', 'account_id must default to the account slug');

    const engine = enginesStore.findEngine(SECRET_ENGINE_SLUG);
    const account = engine.accounts.find(a => a.slug === 'firebase-cr-approver');
    assert.equal(account.account_id, 'firebase-cr-approver', 'stored account_id must also default to the slug');
});

test('POST secret-only engine account -- an explicitly supplied account_id is kept verbatim', async () => {
    const res = await addAccount(SECRET_ENGINE_SLUG, {
        slug: 'ios-confluence',
        account_id: 'custom-account-label',
        nickname: 'iOS Confluence',
        env_var_name: 'RELEASE_IOS_CONFLUENCE'
    });
    assert.equal(res.status, 201, JSON.stringify(res.body));
    assert.equal(res.body.account_id, 'custom-account-label');
});

test('POST secret-only engine account -- a supplied auth_type is REJECTED even when it is a valid enum value', async () => {
    const res = await addAccount(SECRET_ENGINE_SLUG, {
        slug: 'rejected-auth-type',
        nickname: 'Rejected',
        env_var_name: 'RELEASE_REJECTED_AUTH_TYPE',
        auth_type: 'api_key'
    });
    assert.equal(res.status, 400);
    assert.ok(
        res.body.details.some(d => d.includes('auth_type')),
        `expected an auth_type validation error, got: ${JSON.stringify(res.body.details)}`
    );

    const engine = enginesStore.findEngine(SECRET_ENGINE_SLUG);
    assert.equal(engine.accounts.find(a => a.slug === 'rejected-auth-type'), undefined,
        'a rejected POST must not create the account');
});

test('POST secret-only engine account -- auth_type omitted entirely is fine, and still required nickname/env_var_name', async () => {
    const res = await addAccount(SECRET_ENGINE_SLUG, {
        slug: 'missing-nickname',
        env_var_name: 'RELEASE_MISSING_NICKNAME'
    });
    assert.equal(res.status, 400);
    assert.ok(res.body.details.some(d => d.includes('nickname')), JSON.stringify(res.body.details));
});

// ===========================================================================
// PUT /api/engines/:engineSlug/accounts/:accountSlug -- secret-only engine
// ===========================================================================

test('PUT secret-only engine account -- omitting account_id keeps the existing (already-defaulted) value', async () => {
    await addAccount(SECRET_ENGINE_SLUG, {
        slug: 'release-wiki-token',
        nickname: 'Release Wiki Token',
        env_var_name: 'RELEASE_RELEASE_WIKI_TOKEN'
    });

    const res = await updateAccount(SECRET_ENGINE_SLUG, 'release-wiki-token', {
        nickname: 'Release Wiki Token (renamed)'
    });
    assert.equal(res.status, 200, JSON.stringify(res.body));
    assert.equal(res.body.account_id, 'release-wiki-token', 'account_id must be preserved, not blanked');
    assert.equal(res.body.nickname, 'Release Wiki Token (renamed)');
});

test('PUT secret-only engine account -- explicitly blanking account_id re-defaults it to the slug', async () => {
    await addAccount(SECRET_ENGINE_SLUG, {
        slug: 'blank-account-id',
        account_id: 'some-custom-value',
        nickname: 'Blank Account Id',
        env_var_name: 'RELEASE_BLANK_ACCOUNT_ID'
    });

    const res = await updateAccount(SECRET_ENGINE_SLUG, 'blank-account-id', { account_id: '' });
    assert.equal(res.status, 200, JSON.stringify(res.body));
    assert.equal(res.body.account_id, 'blank-account-id', 'blanked account_id must re-default to the slug');
});

test('PUT secret-only engine account -- a supplied auth_type is REJECTED', async () => {
    await addAccount(SECRET_ENGINE_SLUG, {
        slug: 'put-rejected-auth-type',
        nickname: 'Put Rejected',
        env_var_name: 'RELEASE_PUT_REJECTED_AUTH_TYPE'
    });

    const res = await updateAccount(SECRET_ENGINE_SLUG, 'put-rejected-auth-type', { auth_type: 'gateway_token' });
    assert.equal(res.status, 400);
    assert.ok(
        res.body.details.some(d => d.includes('auth_type')),
        `expected an auth_type validation error, got: ${JSON.stringify(res.body.details)}`
    );

    const engine = enginesStore.findEngine(SECRET_ENGINE_SLUG);
    const account = engine.accounts.find(a => a.slug === 'put-rejected-auth-type');
    assert.equal('auth_type' in account, false, 'a rejected PUT must not persist auth_type');
});

test('PUT secret-only engine account -- explicit auth_type: null is accepted as a no-op', async () => {
    await addAccount(SECRET_ENGINE_SLUG, {
        slug: 'put-null-auth-type',
        nickname: 'Put Null',
        env_var_name: 'RELEASE_PUT_NULL_AUTH_TYPE'
    });

    const res = await updateAccount(SECRET_ENGINE_SLUG, 'put-null-auth-type', { auth_type: null });
    assert.equal(res.status, 200, JSON.stringify(res.body));
    assert.equal('auth_type' in res.body, false);
});

// ===========================================================================
// XACA-1342-028 -- a LEGACY stored auth_type on a secret-only account must
// be clearable via PUT auth_type: null (the edit modal cannot offer a way
// to pick a value -- Auth Type is hidden for secret-only engines -- but it
// must still offer a way to CLEAR a value stored before this engine became
// secret-only, or before XACA-1342-025 hid the field). The route itself
// (validateAccountBody + the PUT handler above) already accepts null and
// deletes the key for a secret-only account -- this seeds the "legacy"
// precondition directly into the store, bypassing POST/PUT validation
// (which would refuse to ever create such a state), to prove the CLEAR
// path a real stray record would need actually works end-to-end.
// ===========================================================================

test('PUT secret-only engine account -- a LEGACY stored auth_type is cleared by auth_type: null', async () => {
    // Seed the legacy state directly via the store -- validateAccountBody()
    // would reject `auth_type` on a POST/PUT to this engine, so a real stray
    // record (e.g. from before this engine was marked secret-only) can only
    // be reproduced by writing the registry file directly, not through the API.
    const now = new Date().toISOString();
    const registry = enginesStore.readEngines();
    const engine = registry.engines.find(e => e.slug === SECRET_ENGINE_SLUG);
    engine.accounts.push({
        slug: 'legacy-auth-type',
        account_id: 'legacy-auth-type',
        nickname: 'Legacy Auth Type',
        env_var_name: 'RELEASE_LEGACY_AUTH_TYPE',
        auth_type: 'api_key', // the legacy stray value under test
        created_at: now,
        updated_at: now,
        last_validated_at: null
    });
    enginesStore.writeEngines(registry);

    const preEngine = enginesStore.findEngine(SECRET_ENGINE_SLUG);
    const preAccount = preEngine.accounts.find(a => a.slug === 'legacy-auth-type');
    assert.equal(preAccount.auth_type, 'api_key', 'fixture setup must actually seed the legacy auth_type');

    // This mirrors what the fixed lcars-engines.js submitEditAccount() now
    // sends for a secret-only engine's account (XACA-1342-028): nickname/
    // env_var_name unchanged, no account_id (blank -> re-defaults to slug),
    // and an explicit auth_type: null to clear the stray value -- never the
    // pre-fix `{}` (key omitted), which the PUT handler treats as "keep the
    // existing value" and would leave the legacy auth_type in place.
    const res = await updateAccount(SECRET_ENGINE_SLUG, 'legacy-auth-type', {
        nickname: 'Legacy Auth Type',
        env_var_name: 'RELEASE_LEGACY_AUTH_TYPE',
        auth_type: null
    });
    assert.equal(res.status, 200, JSON.stringify(res.body));
    assert.equal('auth_type' in res.body, false, 'response must not carry a cleared auth_type');

    const postEngine = enginesStore.findEngine(SECRET_ENGINE_SLUG);
    const postAccount = postEngine.accounts.find(a => a.slug === 'legacy-auth-type');
    assert.equal('auth_type' in postAccount, false, 'persisted account must no longer carry auth_type');
});

// ===========================================================================
// Regression -- a normal AI engine's validation is completely unchanged
// ===========================================================================

test('POST AI engine account -- account_id is still required (unchanged)', async () => {
    const res = await addAccount(AI_ENGINE_SLUG, {
        slug: 'darren-personal',
        nickname: 'Darren Personal',
        env_var_name: 'ANTHROPIC_API_KEY_DARREN'
    });
    assert.equal(res.status, 400);
    assert.ok(
        res.body.details.some(d => d.includes('account_id is required')),
        `expected an account_id-required error, got: ${JSON.stringify(res.body.details)}`
    );
});

test('POST AI engine account -- a valid auth_type is still accepted and stored verbatim (unchanged)', async () => {
    const res = await addAccount(AI_ENGINE_SLUG, {
        slug: 'darren-personal',
        account_id: 'acc_01AbCdEf',
        nickname: 'Darren Personal',
        env_var_name: 'ANTHROPIC_API_KEY_DARREN',
        auth_type: 'oauth_token'
    });
    assert.equal(res.status, 201, JSON.stringify(res.body));
    assert.equal(res.body.auth_type, 'oauth_token');
    assert.equal(res.body.account_id, 'acc_01AbCdEf');
});

test('PUT AI engine account -- account_id blanked out is still a validation error (unchanged)', async () => {
    await addAccount(AI_ENGINE_SLUG, {
        slug: 'darren-work',
        account_id: 'acc_02XyZ',
        nickname: 'Darren Work',
        env_var_name: 'ANTHROPIC_API_KEY_DARREN_WORK'
    });

    const res = await updateAccount(AI_ENGINE_SLUG, 'darren-work', { account_id: '' });
    assert.equal(res.status, 400);
    assert.ok(res.body.details.some(d => d.includes('account_id')), JSON.stringify(res.body.details));
});
