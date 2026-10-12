//
//  loopback-request.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Drop-in replacement for `require('supertest')` that never binds the wildcard address (XACA-1065).
 *
 * WHY: supertest 7.x `request(app)` calls `app.listen(0)` (wildcard `::`) and then dials
 * `http://127.0.0.1:<port>`. On macOS a wildcard bind is allowed onto a port another process already holds at
 * 127.0.0.1 only (Tailscale LocalAPI, Encrypt.me, a stale sandbox...), so the request is answered -- or, for a
 * bound-but-not-listening holder, swallowed until ETIMEDOUT -- by a FOREIGN process. A `127.0.0.1`-pinned bind
 * is excluded from such ports by the kernel.
 *
 * HOW: `server.listen(0, '127.0.0.1')` is asynchronous in Node (the host goes through dns.lookup), so
 * `address()` is null synchronously and supertest would fall straight back to a wildcard listen. So
 * `request(app).get(...)` returns a DEFERRED builder: it records every chained call (`.set` `.send` `.expect`...),
 * and only when the chain is consumed (`await` / `.then` / `.end(cb)`) does it create a loopback-pinned server,
 * await 'listening', hand the *listening* server to the real supertest, replay the recorded calls, and close the
 * server again afterwards. Call sites keep the exact supertest surface; no `await` restructuring needed.
 *
 *   const request = require('./helpers/loopback-request');   // instead of require('supertest')
 *
 * An already-listening http.Server (or a URL string) is passed straight through to supertest untouched.
 */

const http = require('http');
const supertest = require('supertest');

const LOOPBACK = '127.0.0.1';
const VERBS = Array.from(new Set(http.METHODS.map((m) => m.toLowerCase()).concat('del')));

function listenLoopback(server) {
    return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(0, LOOPBACK, () => {
            server.removeListener('error', reject);
            // Belt-and-braces (XACA-1065-005): never hand a non-loopback-bound server to supertest.
            const a = server.address();
            if (!a || a.address !== LOOPBACK) {
                const got = JSON.stringify(a);
                return server.close(() => reject(new Error(`loopback-request: XACA-1065 server bound to ${got}, expected ${LOOPBACK}`)));
            }
            resolve();
        });
    });
}

function closeServer(server) {
    return new Promise((resolve) => {
        if (!server.listening) return resolve();
        server.close(() => resolve());
        if (typeof server.closeAllConnections === 'function') server.closeAllConnections();
    });
}

function isListening(app) {
    return typeof app.address === 'function' && !!app.address();
}

// Builds the deferred chain for one HTTP verb call. `calls` is the recorded method-call log.
function deferred(app, verb, verbArgs) {
    const calls = [];
    let started = null;

    // Resolves to { test, cleanup }: a real supertest Test, bound to a loopback-pinned listening server.
    async function materialize() {
        let server = null;
        let owned = false;
        if (typeof app === 'string' || isListening(app)) {
            server = app; // URL string or an already-listening server: nothing to bind.
        } else if (typeof app.listen === 'function' && typeof app.address === 'function') {
            server = app; owned = true; // an http.Server that is not listening yet
        } else {
            server = http.createServer(app); owned = true; // express app / request handler
        }
        if (owned) await listenLoopback(server);
        const cleanup = owned ? () => closeServer(server) : () => Promise.resolve();
        try {
            let test = supertest(server)[verb](...verbArgs);
            for (const [name, args] of calls) {
                const out = test[name](...args);
                if (out && typeof out === 'object') test = out; // every supertest/superagent chain method returns the Test
            }
            return { test, cleanup };
        } catch (e) {
            await cleanup();
            throw e;
        }
    }

    // Runs the chain exactly once; resolves with the response or rejects with supertest's error.
    function run() {
        if (!started) {
            started = materialize().then(({ test, cleanup }) => new Promise((resolve, reject) => {
                test.end((err, res) => {
                    cleanup().then(() => (err ? reject(err) : resolve(res)), reject);
                });
            }));
        }
        return started;
    }

    const handlers = {
        then: (onOk, onErr) => run().then(onOk, onErr),
        catch: (onErr) => run().catch(onErr),
        finally: (fn) => run().finally(fn),
        end: (cb) => {
            // supertest `.end(cb)`: callback style, (err, res).
            const fn = typeof cb === 'function' ? cb : () => {};
            run().then((res) => fn(null, res), (err) => fn(err, err && err.response));
            return proxy;
        },
    };

    const proxy = new Proxy({}, {
        get(_t, prop) {
            if (typeof prop === 'symbol') return undefined;
            if (Object.prototype.hasOwnProperty.call(handlers, prop)) return handlers[prop];
            if (prop === 'expect') {
                // supertest semantics (lib/test.js expect(a, b, c)): unless `a` is an assertion fn, a function in
                // `b` or `c` is an END callback that runs the request. Recording it like any other call would mean
                // the request never runs and the test passes vacuously (XACA-1065-022), so honour it here.
                return (...args) => {
                    const cbAt = typeof args[0] === 'function' ? -1 : [1, 2].find((i) => typeof args[i] === 'function');
                    if (cbAt === undefined || cbAt === -1) { calls.push([prop, args]); return proxy; }
                    calls.push([prop, args.slice(0, cbAt)]);
                    return handlers.end(args[cbAt]);
                };
            }
            return (...args) => { calls.push([prop, args]); return proxy; };
        },
    });
    return proxy;
}

function request(app, options) {
    // Fail closed: passing options through to raw supertest would bind the wildcard again (XACA-1065-017/019).
    if (options !== undefined) {
        throw new Error('loopback-request: request(app, options) is not supported (no test uses it); passing it to supertest would re-bind the wildcard address');
    }
    const obj = {};
    for (const verb of VERBS) obj[verb] = (...args) => deferred(app, verb, args);
    return obj;
}

request.agent = () => {
    throw new Error('loopback-request: request.agent() is not supported (no test uses it); use supertest directly with a pinned server');
};
request.LOOPBACK = LOOPBACK;

module.exports = request;
