//
//  xaca-1065-loopback-request.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1065-003: the loopback-pinned supertest drop-in (tests/helpers/loopback-request.js).
 * Root cause it guards: supertest binds the WILDCARD address but dials 127.0.0.1, so on macOS a port held by a
 * foreign process at 127.0.0.1 only can answer (or swallow) the request.
 */

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const net = require('net');
const express = require('express');
const request = require('./helpers/loopback-request');

function makeApp(seen) {
    const app = express();
    app.use(express.json());
    app.use((req, _res, next) => { if (seen) seen.push({ local: req.socket.localAddress, family: req.socket.localFamily }); next(); });
    app.get('/hello', (req, res) => res.set('X-Echo', req.get('x-in') || '').json({ ok: true, q: req.query }));
    app.post('/echo', (req, res) => res.status(201).json({ got: req.body }));
    app.get('/teapot', (_req, res) => res.status(418).send('tea'));
    return app;
}

// Spies on every Server#listen call made while fn runs.
async function spyListen(fn) {
    const calls = [];
    const orig = net.Server.prototype.listen;
    net.Server.prototype.listen = function (...args) { calls.push(args); return orig.apply(this, args); };
    try { await fn(); } finally { net.Server.prototype.listen = orig; }
    return calls;
}

describe('XACA-1065 loopback-request helper', () => {
    test('chain replay: set / query / send / multiple expect, awaited', async () => {
        const app = makeApp();
        const r = await request(app).get('/hello').set('x-in', 'abc').query({ a: '1' })
            .expect(200).expect('x-echo', 'abc').expect('Content-Type', /json/);
        assert.deepEqual(r.body, { ok: true, q: { a: '1' } });
        const p = await request(app).post('/echo').send({ n: 5 }).expect(201, { got: { n: 5 } });
        assert.equal(p.status, 201);
    });

    test('.end(cb) style delivers (err, res), and failing expectation reaches cb as err', async () => {
        const app = makeApp();
        const res = await new Promise((resolve, reject) => {
            request(app).get('/hello').expect(200).end((err, r) => (err ? reject(err) : resolve(r)));
        });
        assert.equal(res.body.ok, true);
        const err = await new Promise((resolve) => { request(app).get('/hello').expect(500).end((e) => resolve(e)); });
        assert.ok(err instanceof Error);
        assert.match(err.message, /expected 500/);
    });

    test('.expect(..., cb) runs the request like supertest: trailing fn in arg 2 or 3 is the end callback (XACA-1065-022)', async () => {
        const app = makeApp();
        const viaStatus = await new Promise((resolve, reject) => {
            request(app).get('/hello').expect(200, (err, r) => (err ? reject(err) : resolve(r)));
        });
        assert.equal(viaStatus.body.ok, true);
        const viaHeader = await new Promise((resolve, reject) => {
            request(app).get('/hello').set('x-in', 'v').expect('X-Echo', 'v', (err, r) => (err ? reject(err) : resolve(r)));
        });
        assert.equal(viaHeader.status, 200);
        // The stripped-off assertion still applies: a wrong status reaches the callback as an error.
        const err = await new Promise((resolve) => { request(app).get('/hello').expect(500, (e) => resolve(e)); });
        assert.ok(err instanceof Error);
        assert.match(err.message, /expected 500/);
        // An assertion FUNCTION as the first arg is not an end callback (supertest pushes it as an assert).
        const r = await request(app).get('/hello').expect((res) => { assert.equal(res.status, 200); });
        assert.equal(r.body.ok, true);
    });

    test('.expect(fn) and rejection on a failed expectation (await path)', async () => {
        const app = makeApp();
        let called = 0;
        await request(app).get('/teapot').expect((res) => { called++; assert.equal(res.text, 'tea'); }).expect(418);
        assert.equal(called, 1);
        await assert.rejects(() => request(app).get('/teapot').expect(200), /expected 200/);
        const viaThen = await request(app).get('/teapot').then((r) => r.status);
        assert.equal(viaThen, 418);
        await request(app).get('/teapot').catch(() => assert.fail('must not reject on a plain 418'));
    });

    test('server is pinned to 127.0.0.1: never a wildcard listen, request arrives on 127.0.0.1', async () => {
        const seen = [];
        const app = makeApp(seen);
        const listens = await spyListen(async () => {
            await request(app).get('/hello').expect(200);
            await request(app).post('/echo').send({}).expect(201);
        });
        assert.equal(listens.length, 2);
        for (const args of listens) assert.deepEqual(args.slice(0, 2), [0, '127.0.0.1'], `listen args ${JSON.stringify(args)}`);
        assert.equal(seen.length, 2);
        for (const s of seen) assert.equal(s.local, '127.0.0.1');
    });

    test('one server per request, closed afterwards (no leaked listener)', async () => {
        const app = makeApp();
        const servers = [];
        const origListen = http.Server.prototype.listen;
        http.Server.prototype.listen = function (...a) { servers.push(this); return origListen.apply(this, a); };
        try {
            await Promise.all([1, 2, 3, 4, 5].map(() => request(app).get('/hello').expect(200)));
            await request(app).get('/hello').expect(200);
        } finally { http.Server.prototype.listen = origListen; }
        assert.equal(servers.length, 6);
        assert.equal(new Set(servers).size, 6);
        for (const s of servers) assert.equal(s.listening, false, 'server left listening');
    });

    test('a server is also closed when the expectation fails', async () => {
        const servers = [];
        const origListen = http.Server.prototype.listen;
        http.Server.prototype.listen = function (...a) { servers.push(this); return origListen.apply(this, a); };
        try { await request(makeApp()).get('/teapot').expect(200).then(() => {}, () => {}); } finally { http.Server.prototype.listen = origListen; }
        assert.equal(servers.length, 1);
        assert.equal(servers[0].listening, false);
    });

    test('an already-listening server passes straight through and is left running', async () => {
        const srv = http.createServer(makeApp());
        await new Promise((r) => srv.listen(0, '127.0.0.1', r));
        try {
            const listens = await spyListen(async () => { await request(srv).get('/hello').expect(200); });
            assert.equal(listens.length, 0);
            assert.equal(srv.listening, true);
        } finally { srv.close(); }
    });

    test('FOREIGN holder: the helper reaches OUR app, never the process squatting 127.0.0.1:P', async () => {
        // A foreign-style holder on 127.0.0.1:P answering 503 (what Encrypt.me does on this Mac).
        const holder = http.createServer((_q, res) => { res.statusCode = 503; res.end('foreign'); });
        await new Promise((r) => holder.listen(0, '127.0.0.1', r));
        const P = holder.address().port;
        try {
            // Document the host's behaviour (derive the expectation from the host, no skip): macOS lets a wildcard
            // bind coexist with a 127.0.0.1-only holder (the root cause); Linux refuses it with EADDRINUSE.
            const wild = net.createServer();
            const outcome = await new Promise((resolve) => {
                wild.once('error', (e) => resolve(e.code));
                wild.listen(P, () => resolve('bound'));
            });
            if (wild.listening) wild.close();
            assert.ok(['bound', 'EADDRINUSE'].includes(outcome), `unexpected wildcard outcome ${outcome}`);
            if (process.platform === 'darwin') assert.equal(outcome, 'bound');
            if (process.platform === 'linux') assert.equal(outcome, 'EADDRINUSE');

            // The helper binds pinned to 127.0.0.1 with port 0: it can never be handed P while `holder` lives.
            const ports = new Set();
            for (let i = 0; i < 25; i++) {
                const seen = [];
                const app = makeApp(seen);
                app.get('/port', (req, res) => res.json({ port: req.socket.localPort }));
                const r = await request(app).get('/port').expect(200);
                ports.add(r.body.port);
                assert.equal(seen.length, 1);
                assert.equal(seen[0].local, '127.0.0.1');
            }
            assert.ok(!ports.has(P), 'helper was handed the foreign holder port');
        } finally { holder.close(); }
    });

    test('request.agent is explicitly unsupported (no silent wildcard fallback)', () => {
        assert.throws(() => request.agent(makeApp()), /not supported/);
    });

    test('request(app, options) is explicitly unsupported (no silent wildcard fallback)', () => {
        assert.throws(() => request(makeApp(), { http2: true }), /not supported/);
        assert.throws(() => request(makeApp(), {}), /not supported/);
    });
});
