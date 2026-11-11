//
//  xaca-1527-001-payload-too-large.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1527-001 -- the scoped /api/notify error handler maps body-parser's
 * entity.too.large to a fixed 413 (it used to fall through to 500), logging only the type.
 */

const { test, describe, after } = require('node:test');
const assert = require('node:assert/strict');
const H = require('./xaca-1400-007-helpers');
const { request, adm, makeHarness, captureConsole } = H;

after(() => { H.restoreEnv(); H.cleanup(); });

// Harness global express.json() limit is 10mb; this is just over it.
const MARK = 'SECRETBODYMARK';
const oversized = () => JSON.stringify({ pad: MARK + 'x'.repeat(10 * 1024 * 1024 + 1024) });
const post = (h, url) => adm(request(h.app).post(url)).set('Content-Type', 'application/json');

describe('XACA-1527-001 entity.too.large on /api/notify*', () => {
    for (const url of ['/api/notify/connections', '/api/notify']) {
        test(`oversized POST ${url} -> 413 + fixed body`, async () => {
            const h = makeHarness();
            const cap = captureConsole();
            let r;
            try { r = await post(h, url).send(oversized()); } finally { cap.restore(); }
            assert.equal(r.status, 413);
            assert.deepEqual(r.body, { error: 'payload_too_large', message: 'request body too large' });
        });
    }

    test('log line carries only the type, never body content or err.message', async () => {
        const h = makeHarness();
        const cap = captureConsole();
        try { await post(h, '/api/notify/connections').send(oversized()); } finally { cap.restore(); }
        assert.deepEqual(cap.lines, ['[NOTIFY] request error: entity.too.large']);
        assert.ok(!cap.lines.join('\n').includes(MARK));
        assert.ok(!/request entity too large/i.test(cap.lines.join('\n')));
    });

    test('invalid JSON still 400 invalid_json', async () => {
        const h = makeHarness();
        const cap = captureConsole();
        let r;
        try { r = await post(h, '/api/notify/connections').send('{"a": SECRETJSONMARK'); } finally { cap.restore(); }
        assert.equal(r.status, 400);
        assert.equal(r.body.error, 'invalid_json');
        assert.ok(!cap.lines.join('\n').includes('SECRETJSONMARK'));
    });

    test('non-/api/notify route is unaffected (default handler, not the fixed notify body)', async () => {
        const h = makeHarness();
        h.app.post('/api/other', (req, res) => res.json({ ok: true }));
        const cap = captureConsole();
        let r;
        try {
            r = await request(h.app).post('/api/other').set('Content-Type', 'application/json').send(oversized());
        } finally { cap.restore(); }
        assert.equal(r.status, 413); // express default handler, status from body-parser
        assert.notDeepEqual(r.body, { error: 'payload_too_large', message: 'request body too large' });
        assert.ok(!cap.lines.some((l) => l.startsWith('[NOTIFY]')));
    });
});
