//
//  auth-middleware.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Unit + integration tests for the shared API-key auth gate (XACA-0395-004).
 * Uses node --test + supertest. Mirrors vault-routes.test.js style.
 *
 * Covers the auth contract at
 * kanban/plans/XACA-0395/XACA-0395_auth_contract.md:
 *   - missing / invalid / valid credential (both Authorization and X-API-Key)
 *   - both headers present: agree -> use it, disagree -> 401
 *   - byte-exact 401 body across every rejection mode (the non-leak requirement)
 *   - open-when-unset posture (no FLEET_AUTH_TOKEN configured)
 *   - constant-time comparison never throws on a length mismatch (the length
 *     oracle contract §5 forbids)
 *   - the three-state startup notice (absent / blank / set) added by the
 *     XACA-0395-004 correction: a blank/whitespace-only FLEET_AUTH_TOKEN is a
 *     config error that must get a DISTINCT, loud startup warning, while
 *     still resolving to the same open posture as absent (never silently
 *     collapsed back into one state)
 *
 * Test isolation: FLEET_AUTH_TOKEN is a plain env var (no file, no seam module
 * to point elsewhere) — every test that sets it MUST restore it in a
 * try/finally or afterEach, mirroring msg-relay-routes.test.js's convention,
 * so an assertion failure in one test can't leak state into the next.
 */

const { test, describe, beforeEach, afterEach } = require('node:test');
const assert  = require('node:assert/strict');
const request = require('supertest');
const express = require('express');

const authMiddleware = require('../lib/auth-middleware');
const { isAuthorized, requireApiKey, checkApiKey, safeEqual, logAuthStartupNotice } = authMiddleware;

/** Fake logger that records calls instead of writing to real stdout/stderr. */
function fakeLogger() {
    return {
        logCalls: [],
        warnCalls: [],
        log(...args) { this.logCalls.push(args.join(' ')); },
        warn(...args) { this.warnCalls.push(args.join(' ')); },
    };
}

const TEST_TOKEN = 'test-api-key-not-a-real-secret';

// Build a minimal app exercising BOTH adapter shapes: middleware on one route,
// the boolean-guard form on another — mirroring how msg-relay-routes.js uses
// checkApiKey and how subitem 005 will mount requireApiKey elsewhere.
function buildApp() {
    const app = express();
    app.use(express.json());
    app.post('/mw', requireApiKey, (req, res) => res.status(200).json({ ok: true }));
    app.post('/guard', (req, res) => {
        if (!checkApiKey(req, res)) return;
        return res.status(200).json({ ok: true });
    });
    return app;
}

const app = buildApp();

afterEach(() => {
    delete process.env.FLEET_AUTH_TOKEN;
});

// ---------------------------------------------------------------------------
// Open-when-unset posture (contract §7)
// ---------------------------------------------------------------------------

describe('open-when-unset posture', () => {
    test('no FLEET_AUTH_TOKEN configured -> gate is open, request proceeds unauthenticated', async () => {
        delete process.env.FLEET_AUTH_TOKEN;
        const res = await request(app).post('/mw').send({});
        assert.equal(res.status, 200);
    });

    test('FLEET_AUTH_TOKEN set to empty string -> treated as unset, gate stays open', async () => {
        process.env.FLEET_AUTH_TOKEN = '';
        const res = await request(app).post('/mw').send({});
        assert.equal(res.status, 200);
    });

    test('FLEET_AUTH_TOKEN set to whitespace only -> treated as unset, gate stays open', async () => {
        process.env.FLEET_AUTH_TOKEN = '   \t  ';
        const res = await request(app).post('/mw').send({});
        assert.equal(res.status, 200);
    });

    test('guard form (checkApiKey) is equally open when unset', async () => {
        delete process.env.FLEET_AUTH_TOKEN;
        const res = await request(app).post('/guard').send({});
        assert.equal(res.status, 200);
    });
});

// ---------------------------------------------------------------------------
// Closed posture — missing / invalid / valid credential
// ---------------------------------------------------------------------------

describe('closed posture — middleware form (requireApiKey)', () => {
    beforeEach(() => {
        process.env.FLEET_AUTH_TOKEN = TEST_TOKEN;
    });

    test('missing credential -> 401', async () => {
        const res = await request(app).post('/mw').send({});
        assert.equal(res.status, 401);
    });

    test('wrong Bearer credential -> 401', async () => {
        const res = await request(app).post('/mw')
            .set('Authorization', 'Bearer wrong-value-but-16-plus-chars')
            .send({});
        assert.equal(res.status, 401);
    });

    test('valid Bearer credential -> 200', async () => {
        const res = await request(app).post('/mw')
            .set('Authorization', `Bearer ${TEST_TOKEN}`)
            .send({});
        assert.equal(res.status, 200);
    });

    test('Bearer scheme is case-insensitive', async () => {
        const res = await request(app).post('/mw')
            .set('Authorization', `bEaReR ${TEST_TOKEN}`)
            .send({});
        assert.equal(res.status, 200);
    });

    test('valid X-API-Key credential -> 200', async () => {
        const res = await request(app).post('/mw')
            .set('X-API-Key', TEST_TOKEN)
            .send({});
        assert.equal(res.status, 200);
    });

    test('wrong X-API-Key credential -> 401', async () => {
        const res = await request(app).post('/mw')
            .set('X-API-Key', 'wrong-value-but-16-plus-chars-x')
            .send({});
        assert.equal(res.status, 401);
    });

    test('bare Authorization header with no Bearer prefix is rejected (narrows old behavior)', async () => {
        const res = await request(app).post('/mw')
            .set('Authorization', TEST_TOKEN)
            .send({});
        assert.equal(res.status, 401);
    });

    test('Authorization with a non-Bearer scheme falls through to X-API-Key rather than 401ing immediately', async () => {
        const res = await request(app).post('/mw')
            .set('Authorization', 'Basic dXNlcjpwYXNz')
            .set('X-API-Key', TEST_TOKEN)
            .send({});
        assert.equal(res.status, 200);
    });

    test('credential shorter than 16 chars is rejected as malformed shape', async () => {
        const res = await request(app).post('/mw')
            .set('X-API-Key', 'short')
            .send({});
        assert.equal(res.status, 401);
    });

    test('credential containing a comma (simulated Node duplicate-header join) is rejected', async () => {
        const res = await request(app).post('/mw')
            .set('Authorization', 'Bearer aaaaaaaaaaaaaaaa, Bearer bbbbbbbbbbbbbbbb')
            .send({});
        assert.equal(res.status, 401);
    });
});

describe('closed posture — guard form (checkApiKey)', () => {
    beforeEach(() => {
        process.env.FLEET_AUTH_TOKEN = TEST_TOKEN;
    });

    test('missing credential -> 401', async () => {
        const res = await request(app).post('/guard').send({});
        assert.equal(res.status, 401);
    });

    test('valid Bearer credential -> 200', async () => {
        const res = await request(app).post('/guard')
            .set('Authorization', `Bearer ${TEST_TOKEN}`)
            .send({});
        assert.equal(res.status, 200);
    });
});

// ---------------------------------------------------------------------------
// Both headers present (contract §3.4)
// ---------------------------------------------------------------------------

describe('both Authorization and X-API-Key present', () => {
    beforeEach(() => {
        process.env.FLEET_AUTH_TOKEN = TEST_TOKEN;
    });

    test('both agree and are valid -> 200', async () => {
        const res = await request(app).post('/mw')
            .set('Authorization', `Bearer ${TEST_TOKEN}`)
            .set('X-API-Key', TEST_TOKEN)
            .send({});
        assert.equal(res.status, 200);
    });

    test('both valid-shape but DISAGREE -> 401 (never try one then the other)', async () => {
        const res = await request(app).post('/mw')
            .set('Authorization', `Bearer ${TEST_TOKEN}`)
            .set('X-API-Key', 'a-different-valid-shape-credential-value')
            .send({});
        assert.equal(res.status, 401);
    });

    test('X-API-Key correct, Authorization wrong -> 401 (disagreement wins even when one side is right)', async () => {
        const res = await request(app).post('/mw')
            .set('Authorization', 'Bearer some-other-valid-shape-value-here')
            .set('X-API-Key', TEST_TOKEN)
            .send({});
        assert.equal(res.status, 401);
    });
});

// ---------------------------------------------------------------------------
// Byte-exact 401 body + headers across every rejection mode (contract §4, L2)
// ---------------------------------------------------------------------------

describe('401 response is byte-identical across every rejection reason', () => {
    beforeEach(() => {
        process.env.FLEET_AUTH_TOKEN = TEST_TOKEN;
    });

    const EXPECTED_BODY = { error: 'Unauthorized', code: 'unauthorized' };

    async function rejection(build) {
        const req = request(app).post('/mw');
        build(req);
        return req.send({});
    }

    test('absent credential', async () => {
        const res = await rejection(() => {});
        assert.equal(res.status, 401);
        assert.deepEqual(res.body, EXPECTED_BODY);
        assert.equal(res.headers['content-type'], 'application/json; charset=utf-8');
        assert.equal(res.headers['www-authenticate'], 'Bearer');
        assert.equal(res.headers['access-control-allow-origin'], '*');
    });

    test('wrong credential', async () => {
        const res = await rejection(r => r.set('Authorization', 'Bearer wrong-value-but-16-plus-chars'));
        assert.equal(res.status, 401);
        assert.deepEqual(res.body, EXPECTED_BODY);
    });

    test('malformed credential (bad shape)', async () => {
        const res = await rejection(r => r.set('X-API-Key', 'short'));
        assert.equal(res.status, 401);
        assert.deepEqual(res.body, EXPECTED_BODY);
    });

    test('disagreeing duplicate headers', async () => {
        const res = await rejection(r => r
            .set('Authorization', `Bearer ${TEST_TOKEN}`)
            .set('X-API-Key', 'a-different-valid-shape-credential-value'));
        assert.equal(res.status, 401);
        assert.deepEqual(res.body, EXPECTED_BODY);
    });

    test('all four rejection bodies are byte-identical to one another', async () => {
        const bodies = await Promise.all([
            rejection(() => {}),
            rejection(r => r.set('Authorization', 'Bearer wrong-value-but-16-plus-chars')),
            rejection(r => r.set('X-API-Key', 'short')),
            rejection(r => r
                .set('Authorization', `Bearer ${TEST_TOKEN}`)
                .set('X-API-Key', 'a-different-valid-shape-credential-value')),
        ]);
        const serialized = bodies.map(res => JSON.stringify(res.body));
        assert.ok(serialized.every(s => s === serialized[0]), 'rejection bodies must be byte-identical');
        assert.ok(bodies.every(res => res.status === 401));
    });
});

// ---------------------------------------------------------------------------
// Constant-time comparison — never throws on a length mismatch (contract §5)
// ---------------------------------------------------------------------------

describe('safeEqual', () => {
    test('equal values -> true', () => {
        assert.equal(safeEqual('same-value-here', 'same-value-here'), true);
    });

    test('unequal values, same length -> false, no throw', () => {
        assert.equal(safeEqual('aaaaaaaaaaaaaaaa', 'bbbbbbbbbbbbbbbb'), false);
    });

    test('unequal values, wildly different length -> false, no throw (the length-oracle case)', () => {
        assert.doesNotThrow(() => {
            const result = safeEqual('short-16-chars--', 'a'.repeat(512));
            assert.equal(result, false);
        });
    });

    test('empty vs non-empty -> false, no throw', () => {
        assert.doesNotThrow(() => {
            assert.equal(safeEqual('', 'nonempty-value-here'), false);
        });
    });

    test('a 512-byte credential against a 16-byte expected key -> false, no throw', async () => {
        process.env.FLEET_AUTH_TOKEN = TEST_TOKEN;
        try {
            const res = await request(app).post('/mw')
                .set('X-API-Key', 'a'.repeat(512))
                .send({});
            // 512 chars is within the 16-512 shape bound, so it reaches safeEqual
            // rather than being rejected by shape validation — this is the
            // fault-injection case that would throw ERR_CRYPTO_TIMING_SAFE_EQUAL_LENGTH
            // if the implementation compared raw buffers instead of digests.
            assert.equal(res.status, 401);
        } finally {
            delete process.env.FLEET_AUTH_TOKEN;
        }
    });
});

// ---------------------------------------------------------------------------
// isAuthorized — pure predicate, no res, no side effects
// ---------------------------------------------------------------------------

describe('isAuthorized', () => {
    afterEach(() => {
        delete process.env.FLEET_AUTH_TOKEN;
    });

    test('returns true when unset', () => {
        delete process.env.FLEET_AUTH_TOKEN;
        assert.equal(isAuthorized({ get: () => undefined }), true);
    });

    test('returns false for a fake req with no matching header', () => {
        process.env.FLEET_AUTH_TOKEN = TEST_TOKEN;
        assert.equal(isAuthorized({ get: () => undefined }), false);
    });

    test('returns true for a fake req presenting the correct Bearer credential', () => {
        process.env.FLEET_AUTH_TOKEN = TEST_TOKEN;
        const req = { get: (name) => (name.toLowerCase() === 'authorization' ? `Bearer ${TEST_TOKEN}` : undefined) };
        assert.equal(isAuthorized(req), true);
    });
});

// ---------------------------------------------------------------------------
// logAuthStartupNotice — three distinct states, distinguishable in the logs
// (XACA-0395-004 correction). ABSENT and BLANK both yield OPEN posture —
// unchanged — but must never be logged identically: a blank/whitespace-only
// FLEET_AUTH_TOKEN on this env-only, no-file-fallback, internet-facing
// server is a configuration error, not an ordinary "unconfigured" state.
// ---------------------------------------------------------------------------

describe('logAuthStartupNotice', () => {
    afterEach(() => {
        delete process.env.FLEET_AUTH_TOKEN;
    });

    test('ABSENT -> the exact contract §7 open-posture line, via warn, no CONFIG ERROR wording', () => {
        delete process.env.FLEET_AUTH_TOKEN;
        const logger = fakeLogger();
        const state = logAuthStartupNotice(logger);
        assert.equal(state, 'absent');
        assert.equal(logger.logCalls.length, 0);
        assert.equal(logger.warnCalls.length, 1);
        assert.equal(
            logger.warnCalls[0],
            '[fleet-monitor] AUTH: gate OPEN — no API key configured; state-mutating routes are UNAUTHENTICATED'
        );
        assert.ok(!/CONFIG ERROR/.test(logger.warnCalls[0]), 'the absent-case line must not use CONFIG ERROR wording');
    });

    test('BLANK (empty string) -> a DISTINCT CONFIG ERROR line, not the absent-case line', () => {
        process.env.FLEET_AUTH_TOKEN = '';
        const logger = fakeLogger();
        const state = logAuthStartupNotice(logger);
        assert.equal(state, 'blank');
        assert.equal(logger.warnCalls.length, 1);
        assert.match(logger.warnCalls[0], /CONFIG ERROR/);
        assert.match(logger.warnCalls[0], /set but blank/i);
        assert.notEqual(
            logger.warnCalls[0],
            '[fleet-monitor] AUTH: gate OPEN — no API key configured; state-mutating routes are UNAUTHENTICATED',
            'blank must not collapse into the same line as absent'
        );
    });

    test('BLANK (whitespace-only) -> same distinct CONFIG ERROR line as empty string', () => {
        process.env.FLEET_AUTH_TOKEN = '   \t  ';
        const logger = fakeLogger();
        const state = logAuthStartupNotice(logger);
        assert.equal(state, 'blank');
        assert.match(logger.warnCalls[0], /CONFIG ERROR/);
    });

    test('BLANK warning never contains the raw env var value or its length', () => {
        process.env.FLEET_AUTH_TOKEN = '   \t  '; // 6 chars of whitespace
        const logger = fakeLogger();
        logAuthStartupNotice(logger);
        assert.ok(!/\t/.test(logger.warnCalls[0]), 'warning must not echo the raw whitespace value');
        assert.ok(!/\b6\b/.test(logger.warnCalls[0]), 'warning must not echo the value length');
    });

    test('BLANK still yields OPEN posture on isAuthorized (posture unchanged by this correction)', () => {
        process.env.FLEET_AUTH_TOKEN = '   ';
        assert.equal(isAuthorized({ get: () => undefined }), true);
    });

    test('SET -> "AUTH: gate ACTIVE" via log(), not warn(), and nothing else', () => {
        process.env.FLEET_AUTH_TOKEN = TEST_TOKEN;
        const logger = fakeLogger();
        const state = logAuthStartupNotice(logger);
        assert.equal(state, 'set');
        assert.deepEqual(logger.logCalls, ['[fleet-monitor] AUTH: gate ACTIVE']);
        assert.equal(logger.warnCalls.length, 0);
    });

    test('default logger (no arg) does not throw — exercises the real console path', () => {
        delete process.env.FLEET_AUTH_TOKEN;
        assert.doesNotThrow(() => logAuthStartupNotice());
    });
});
