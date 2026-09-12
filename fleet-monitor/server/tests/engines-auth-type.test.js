//
//  engines-auth-type.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Route tests for XACA-1178-004: optional `auth_type` on Fleet Monitor engine
 * accounts (`fleet-monitor/server/lib/engines-routes.js`).
 *
 * Schema decision this implements (XACA-0282-012 §2.2, §8): `auth_type`
 * belongs to the ACCOUNT, not the team — Fleet Monitor is its home of record.
 * It is optional, validated only when present, one of `oauth_token` |
 * `api_key` | `gateway_token`, stored and returned verbatim. No engine-level
 * change, no schema `version` bump (plan D5).
 *
 * Covers:
 *   POST /api/engines/:engineSlug/accounts
 *     - 400 for an invalid auth_type value
 *     - 201 for each of the three valid values, stored verbatim
 *     - 201 with auth_type omitted entirely — the key must be ABSENT from
 *       the stored/returned account, never persisted as null
 *   PUT /api/engines/:engineSlug/accounts/:accountSlug
 *     - 400 for an invalid auth_type value
 *     - 200 for each of the three valid values, stored verbatim
 *     - an absent auth_type in the PUT body KEEPS the existing value
 *     - an explicit `auth_type: null` in the PUT body REMOVES the key
 *     - an existing account with no auth_type survives an unrelated-field
 *       PUT (one that never mentions auth_type) with the key still absent
 *
 * Test isolation (XACA-0537-006 pattern, same as engine-vault-linkage.test.js):
 *   engines-store.js resolves its file path from FLEET_ENGINES_FILE at
 *   module-load time, so that env var is set to a unique per-process temp
 *   path BEFORE requiring the store or the routes module. This suite never
 *   touches the real data/engines.json and is parallel-safe against other
 *   suites (each uses its own temp path / fixture slug prefix).
 *
 * Auth: POST/PUT are gated by requireApiKey (auth-middleware.js), but with
 * FLEET_AUTH_TOKEN unset the gate is OPEN (contract §7) — same posture
 * engine-vault-linkage.test.js's DELETE tests rely on, so no Authorization
 * header is sent here either.
 */

const fs   = require('fs');
const path = require('path');
const os   = require('os');

// Point the engines store at an isolated temp file BEFORE requiring it.
const TEST_ENGINES_FILE = path.join(os.tmpdir(), `auth-type-engines-${process.pid}-${Date.now()}.json`);
process.env.FLEET_ENGINES_FILE = TEST_ENGINES_FILE;

const { test, before, beforeEach, after } = require('node:test');
const assert  = require('node:assert/strict');
const request = require('supertest');
const express = require('express');

const enginesStore = require('../lib/engines-store');

// XACA-0537-012 pattern: import the REAL routes module server.js mounts,
// not an inline re-implementation, so this exercises shipped code.
const { registerEnginesRoutes } = require('../lib/engines-routes');

const ENGINES_FILE = TEST_ENGINES_FILE;

// Unique fixture prefix so this suite never collides with another test file's
// fixtures if they ever share a data directory.
const ENG_SLUG = 'at-test-engine';

let app;
let savedConsoleLog;

function createEngineApp() {
    const a = express();
    a.use(express.json({ limit: '1mb' }));
    registerEnginesRoutes(a);
    return a;
}

// Seed a fresh engine with zero accounts before each test — keeps every test
// independent of what a previous one wrote (slugs, auth_type values, etc.).
function seedEmptyEngine() {
    const now = new Date().toISOString();
    const registry = enginesStore.readEngines();
    registry.engines = registry.engines.filter(e => e.slug !== ENG_SLUG);
    registry.engines.push({
        slug: ENG_SLUG,
        name: 'Auth-Type Test Engine',
        updated_at: now,
        accounts: []
    });
    registry.updated_at = now;
    enginesStore.writeEngines(registry);
}

function addAccount(body) {
    return request(app).post(`/api/engines/${ENG_SLUG}/accounts`).send(body);
}

function updateAccount(slug, body) {
    return request(app).put(`/api/engines/${ENG_SLUG}/accounts/${slug}`).send(body);
}

before(() => {
    // Same rationale as engine-vault-linkage.test.js: the real handlers log a
    // console.log success line per operation; under node's parallel test
    // runner that can corrupt the parent's IPC framing. Muted for the suite.
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
    seedEmptyEngine();
});

// ===========================================================================
// POST /api/engines/:engineSlug/accounts — auth_type
// ===========================================================================

test('POST account — invalid auth_type value returns 400', async () => {
    const res = await addAccount({
        slug: 'post-bogus',
        account_id: 'acct-post-bogus',
        nickname: 'Post Bogus',
        env_var_name: 'POST_BOGUS_KEY',
        auth_type: 'bogus'
    });
    assert.equal(res.status, 400);
    assert.ok(
        res.body.details.some(d => d.includes('auth_type')),
        `expected an auth_type validation error, got: ${JSON.stringify(res.body.details)}`
    );
});

for (const validType of ['oauth_token', 'api_key', 'gateway_token']) {
    test(`POST account — auth_type "${validType}" is accepted and stored verbatim`, async () => {
        const slug = `post-${validType.replace(/_/g, '-')}`;
        const res = await addAccount({
            slug,
            account_id: `acct-${slug}`,
            nickname: `Post ${validType}`,
            env_var_name: `POST_${validType.toUpperCase()}_KEY`,
            auth_type: validType
        });
        assert.equal(res.status, 201);
        assert.equal(res.body.auth_type, validType, 'response must echo auth_type verbatim');

        // Verify what actually landed on disk, not just the response.
        const engine = enginesStore.findEngine(ENG_SLUG);
        const account = engine.accounts.find(a => a.slug === slug);
        assert.equal(account.auth_type, validType, 'stored account must carry auth_type verbatim');
    });
}

test('POST account — auth_type omitted entirely: key is ABSENT, never stored as null', async () => {
    const res = await addAccount({
        slug: 'post-omitted',
        account_id: 'acct-post-omitted',
        nickname: 'Post Omitted',
        env_var_name: 'POST_OMITTED_KEY'
    });
    assert.equal(res.status, 201);
    assert.equal('auth_type' in res.body, false, 'response must not carry an auth_type key at all');

    const engine = enginesStore.findEngine(ENG_SLUG);
    const account = engine.accounts.find(a => a.slug === 'post-omitted');
    assert.equal('auth_type' in account, false, 'stored account must not carry an auth_type key at all (not even null)');
});

// ===========================================================================
// PUT /api/engines/:engineSlug/accounts/:accountSlug — auth_type
// ===========================================================================

test('PUT account — invalid auth_type value returns 400', async () => {
    await addAccount({
        slug: 'put-bogus',
        account_id: 'acct-put-bogus',
        nickname: 'Put Bogus',
        env_var_name: 'PUT_BOGUS_KEY'
    });

    const res = await updateAccount('put-bogus', { auth_type: 'not-a-real-type' });
    assert.equal(res.status, 400);
    assert.ok(
        res.body.details.some(d => d.includes('auth_type')),
        `expected an auth_type validation error, got: ${JSON.stringify(res.body.details)}`
    );
});

for (const validType of ['oauth_token', 'api_key', 'gateway_token']) {
    test(`PUT account — auth_type "${validType}" is accepted and stored verbatim`, async () => {
        const slug = `put-${validType.replace(/_/g, '-')}`;
        await addAccount({
            slug,
            account_id: `acct-${slug}`,
            nickname: `Put ${validType}`,
            env_var_name: `PUT_${validType.toUpperCase()}_KEY`
        });

        const res = await updateAccount(slug, { auth_type: validType });
        assert.equal(res.status, 200);
        assert.equal(res.body.auth_type, validType, 'response must echo auth_type verbatim');

        const engine = enginesStore.findEngine(ENG_SLUG);
        const account = engine.accounts.find(a => a.slug === slug);
        assert.equal(account.auth_type, validType, 'stored account must carry auth_type verbatim');
    });
}

test('PUT account — omitting auth_type from the body KEEPS the existing value', async () => {
    const slug = 'put-keep-existing';
    await addAccount({
        slug,
        account_id: `acct-${slug}`,
        nickname: 'Put Keep Existing',
        env_var_name: 'PUT_KEEP_EXISTING_KEY',
        auth_type: 'oauth_token'
    });

    // Update an unrelated field only — auth_type is not in this body at all.
    const res = await updateAccount(slug, { nickname: 'Put Keep Existing (renamed)' });
    assert.equal(res.status, 200);
    assert.equal(res.body.auth_type, 'oauth_token', 'response must keep the pre-existing auth_type');
    assert.equal(res.body.nickname, 'Put Keep Existing (renamed)', 'the field actually sent must still update');

    const engine = enginesStore.findEngine(ENG_SLUG);
    const account = engine.accounts.find(a => a.slug === slug);
    assert.equal(account.auth_type, 'oauth_token', 'stored account must keep the pre-existing auth_type');
});

test('PUT account — explicit auth_type: null REMOVES the key entirely', async () => {
    const slug = 'put-clear';
    await addAccount({
        slug,
        account_id: `acct-${slug}`,
        nickname: 'Put Clear',
        env_var_name: 'PUT_CLEAR_KEY',
        auth_type: 'api_key'
    });

    const res = await updateAccount(slug, { auth_type: null });
    assert.equal(res.status, 200);
    assert.equal('auth_type' in res.body, false, 'response must not carry an auth_type key after clearing');

    const engine = enginesStore.findEngine(ENG_SLUG);
    const account = engine.accounts.find(a => a.slug === slug);
    assert.equal('auth_type' in account, false, 'stored account must not carry an auth_type key after clearing (not even null)');
});

test('PUT account — an account with no auth_type survives an unrelated-field PUT with the key still absent', async () => {
    const slug = 'put-never-had-one';
    await addAccount({
        slug,
        account_id: `acct-${slug}`,
        nickname: 'Never Had One',
        env_var_name: 'PUT_NEVER_HAD_ONE_KEY'
        // No auth_type at creation.
    });

    const res = await updateAccount(slug, { nickname: 'Never Had One (renamed)' });
    assert.equal(res.status, 200);
    assert.equal('auth_type' in res.body, false, 'response must not gain an auth_type key from an unrelated update');

    const engine = enginesStore.findEngine(ENG_SLUG);
    const account = engine.accounts.find(a => a.slug === slug);
    assert.equal('auth_type' in account, false, 'stored account must still have no auth_type key');
    assert.equal(account.nickname, 'Never Had One (renamed)', 'the field actually sent must still update');
});
