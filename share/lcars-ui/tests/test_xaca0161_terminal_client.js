//
//  test_xaca0161_terminal_client.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * test_xaca0161_terminal_client.js — XACA-0161-004.
 *
 * Unit tests for the cockpit transport (`js/lcars-terminal-client.js`).
 *
 * Usage:
 *   node --test lcars-ui/tests/test_xaca0161_terminal_client.js
 *
 * WHAT THESE TESTS ARE FOR
 * ========================
 * The properties under test are the ones whose failure mode is SILENT. A
 * reused ticket does not throw — the upgrade is simply refused and the pane
 * stays blank. A `ws://` URL works perfectly on a desktop and dies one second
 * in on the iPad this ticket exists to serve. Ctrl+C becoming Enter looks like
 * the user mistyped. None of these announce themselves, so each gets a test
 * that fails loudly instead.
 *
 * WHAT THESE TESTS ARE NOT
 * ========================
 * They are not evidence that a pane works. That was established separately by
 * driving the real stack — a live ttyd 1.7.7 over the real LCARS proxy with
 * real minted tickets. These cover the client-side logic that the live rig
 * cannot reach from Node (URL refusal, backoff shape, the keyboard shim).
 *
 * No external dependencies. Node >= 18 (node:test is built-in).
 */

'use strict';

var test = require('node:test');
var assert = require('node:assert/strict');
var path = require('path');

var CLIENT_PATH = path.join(__dirname, '../js/lcars-terminal-client.js');
var client = require(CLIENT_PATH);

// ─── Test doubles ──────────────────────────────────────────────────────────────

var HTTPS_LOC = { protocol: 'https:', host: 'darren-m3pro.tail1234.ts.net:8203' };
var HTTP_LOC = { protocol: 'http:', host: 'localhost:8203' };

/** Minimal fake WebSocket that records what was sent and lets a test drive
 *  open/message/close by hand. */
function FakeSocket(url, protocols) {
    this.url = url;
    this.protocols = protocols;
    this.sent = [];
    this.readyState = 0;
    this.closed = false;
    FakeSocket.instances.push(this);
}
FakeSocket.instances = [];
FakeSocket.reset = function () { FakeSocket.instances = []; };
FakeSocket.prototype.send = function (d) { this.sent.push(d); };
FakeSocket.prototype.close = function () { this.closed = true; };
FakeSocket.prototype.fireOpen = function () { this.readyState = 1; if (this.onopen) this.onopen(); };
FakeSocket.prototype.fireMessage = function (data) { if (this.onmessage) this.onmessage({ data: data }); };
FakeSocket.prototype.fireClose = function (code) {
    this.readyState = 3;
    if (this.onclose) this.onclose({ code: code || 1006 });
};

/** fetch double that mints a new ticket each call and counts calls. */
function makeMintFetch(opts) {
    opts = opts || {};
    var state = { calls: 0, bodies: [] };
    var fn = function (url, init) {
        state.calls += 1;
        state.bodies.push(init && init.body);
        if (opts.failWith) {
            return Promise.resolve({ ok: false, status: opts.failWith, json: function () { return Promise.resolve({}); } });
        }
        var n = state.calls;
        return Promise.resolve({
            ok: true,
            status: 200,
            json: function () {
                return Promise.resolve({
                    terminal: 'engineering',
                    ticket: 'ticket-number-' + n,
                    expiresInSeconds: 30,
                    wsPath: '/terminal/engineering/ws'
                });
            }
        });
    };
    fn.state = state;
    return fn;
}

function makeTransport(fetchImpl, overrides) {
    overrides = overrides || {};
    var timers = [];
    var deps = {
        fetchImpl: fetchImpl,
        WebSocketImpl: FakeSocket,
        location: overrides.location || HTTPS_LOC,
        setTimeoutImpl: function (fn) { timers.push(fn); return timers.length; },
        clearTimeoutImpl: function () {},
        textDecoder: new TextDecoder(),
        random: function () { return 0.5; }
    };
    var statuses = [];
    var outputs = [];
    var errors = [];
    var t = client.createTerminalTransport('engineering', deps, {
        onStatus: function (s, d) { statuses.push([s, d]); },
        onOutput: function (o) { outputs.push(o); },
        onError: function (e) { errors.push(e); }
    });
    t._timers = timers;
    t._statuses = statuses;
    t._outputs = outputs;
    t._errors = errors;
    return t;
}

function encodeFrame(cmdChar, payload) {
    return new TextEncoder().encode(cmdChar + payload).buffer;
}

// ─── buildWsUrl: the transport-security property ───────────────────────────────

test('buildWsUrl composes a wss:// URL with the ticket in the query string', function () {
    var url = client.buildWsUrl(HTTPS_LOC, 'engineering', 'abc123');
    assert.equal(url,
        'wss://darren-m3pro.tail1234.ts.net:8203/terminal/engineering/ws?ticket=abc123');
});

test('buildWsUrl REFUSES to build a ws:// URL from an http page', function () {
    assert.throws(
        function () { client.buildWsUrl(HTTP_LOC, 'engineering', 'abc123'); },
        function (err) { return err.code === 'INSECURE_ORIGIN'; });
});

test('buildWsUrl has no localhost carve-out', function () {
    // The tempting exception. http://localhost is a "secure context" per
    // browser policy, but a loopback fallback would be a second transport
    // path that only ever runs on a developer machine.
    assert.throws(
        function () { client.buildWsUrl({ protocol: 'http:', host: 'localhost:8203' }, 'engineering', 't'); },
        function (err) { return err.code === 'INSECURE_ORIGIN'; });
    assert.throws(
        function () { client.buildWsUrl({ protocol: 'http:', host: '127.0.0.1:8203' }, 'engineering', 't'); },
        function (err) { return err.code === 'INSECURE_ORIGIN'; });
});

test('buildWsUrl never emits a ws:// scheme for ANY input it accepts', function () {
    // Property-style: whatever it returns, it is wss.
    var hosts = ['a.ts.net', 'b.local:9000', '10.0.0.4:8203'];
    hosts.forEach(function (h) {
        var u = client.buildWsUrl({ protocol: 'https:', host: h }, 'chancellor', 'tk');
        assert.ok(u.startsWith('wss://'), 'expected wss:// for host ' + h + ', got ' + u);
    });
});

test('buildWsUrl percent-encodes the ticket', function () {
    var url = client.buildWsUrl(HTTPS_LOC, 'engineering', 'a b&c=d');
    assert.ok(url.endsWith('?ticket=a%20b%26c%3Dd'), url);
});

test('buildWsUrl rejects a terminal name that is not a bare identifier', function () {
    ['../etc', 'a/b', 'a?b', '', 'a b'].forEach(function (bad) {
        assert.throws(function () { client.buildWsUrl(HTTPS_LOC, bad, 'tk'); });
    });
});

test('buildWsUrl refuses to build a URL with no ticket', function () {
    assert.throws(function () { client.buildWsUrl(HTTPS_LOC, 'engineering', ''); });
});

// ─── ttyd codec (shapes measured against live ttyd 1.7.7) ──────────────────────

test('encodeHandshake is raw JSON with NO command prefix', function () {
    var h = client.encodeHandshake(100, 30);
    assert.equal(h.charAt(0), '{', 'handshake must not be command-prefixed');
    assert.deepEqual(JSON.parse(h), { AuthToken: '', columns: 100, rows: 30 });
});

test('encodeInput prefixes INPUT with "0"', function () {
    assert.equal(client.encodeInput('ls\r'), '0ls\r');
});

test('encodeResize prefixes RESIZE with "1" and sends columns/rows', function () {
    var r = client.encodeResize(120, 40);
    assert.equal(r.charAt(0), '1');
    assert.deepEqual(JSON.parse(r.slice(1)), { columns: 120, rows: 40 });
});

test('decodeFrame classifies OUTPUT / TITLE / PREFS from binary frames', function () {
    var dec = new TextDecoder();
    assert.deepEqual(client.decodeFrame(encodeFrame('0', 'hello'), dec),
        { type: 'output', payload: 'hello' });
    assert.deepEqual(client.decodeFrame(encodeFrame('1', 'my-title'), dec),
        { type: 'title', payload: 'my-title' });
    assert.deepEqual(client.decodeFrame(encodeFrame('2', '{ }'), dec),
        { type: 'prefs', payload: '{ }' });
});

test('decodeFrame tolerates an empty frame instead of throwing', function () {
    assert.equal(client.decodeFrame(new Uint8Array([]), new TextDecoder()).type, 'empty');
});

// ─── The Ctrl+C shim (xterm.js #5721, absent from every stable release) ────────

test('isIpadCtrlC matches the iPad hardware-keyboard Ctrl+C event', function () {
    assert.equal(client.isIpadCtrlC(
        { type: 'keydown', ctrlKey: true, key: 'c', keyCode: 13 }), true);
});

test('isIpadCtrlC does NOT swallow a plain Enter keypress', function () {
    // The regression that matters: over-matching here would break the single
    // most-used key in a terminal.
    assert.equal(client.isIpadCtrlC(
        { type: 'keydown', ctrlKey: false, key: 'Enter', keyCode: 13 }), false);
});

test('isIpadCtrlC does NOT match Ctrl+Enter', function () {
    assert.equal(client.isIpadCtrlC(
        { type: 'keydown', ctrlKey: true, key: 'Enter', keyCode: 13 }), false);
});

test('isIpadCtrlC ignores a normal desktop Ctrl+C (keyCode 67)', function () {
    // Desktop already works via xterm's own path; double-handling would send
    // ETX twice.
    assert.equal(client.isIpadCtrlC(
        { type: 'keydown', ctrlKey: true, key: 'c', keyCode: 67 }), false);
});

test('isIpadCtrlC ignores keyup so ETX is sent exactly once', function () {
    assert.equal(client.isIpadCtrlC(
        { type: 'keyup', ctrlKey: true, key: 'c', keyCode: 13 }), false);
});

test('ETX is the single byte 0x03', function () {
    assert.equal(client.ETX.length, 1);
    assert.equal(client.ETX.charCodeAt(0), 3);
});

// ─── Backoff ───────────────────────────────────────────────────────────────────

test('backoffDelay grows with attempt and is capped at 8s', function () {
    var full = function () { return 1; }; // max of the jitter range
    assert.equal(client.backoffDelay(0, full), 500);
    assert.equal(client.backoffDelay(1, full), 1000);
    assert.equal(client.backoffDelay(2, full), 2000);
    assert.ok(client.backoffDelay(10, full) <= 8000, 'must stay capped');
});

test('backoffDelay applies full jitter so panes do not stampede the mint route', function () {
    assert.equal(client.backoffDelay(3, function () { return 0; }), 0);
    assert.ok(client.backoffDelay(3, function () { return 0.5; }) < client.backoffDelay(3, function () { return 1; }));
});

// ─── Ticket lifecycle: the properties with silent failure modes ────────────────

test('connect() mints a ticket at CONNECT time, not at construction', async function () {
    FakeSocket.reset();
    var f = makeMintFetch();
    var t = makeTransport(f);
    assert.equal(f.state.calls, 0, 'constructing a transport must not mint');
    await t.connect();
    assert.equal(f.state.calls, 1);
});

test('connect() mints for its OWN terminal name', async function () {
    FakeSocket.reset();
    var f = makeMintFetch();
    await makeTransport(f).connect();
    assert.deepEqual(JSON.parse(f.state.bodies[0]), { terminal: 'engineering' });
});

test('the minted ticket ends up in the socket URL', async function () {
    FakeSocket.reset();
    var f = makeMintFetch();
    await makeTransport(f).connect();
    assert.ok(FakeSocket.instances[0].url.indexOf('ticket=ticket-number-1') !== -1,
        FakeSocket.instances[0].url);
});

test('the socket requests the "tty" subprotocol', async function () {
    FakeSocket.reset();
    await makeTransport(makeMintFetch()).connect();
    assert.deepEqual(FakeSocket.instances[0].protocols, ['tty']);
});

test('RECONNECT RE-MINTS: a burned ticket is never presented twice', async function () {
    // The single most important test in this file. The old nonce was consumed
    // by the connection that just dropped; reusing it fails closed and silently.
    FakeSocket.reset();
    var f = makeMintFetch();
    var t = makeTransport(f);
    await t.connect();
    FakeSocket.instances[0].fireOpen();
    FakeSocket.instances[0].fireClose(1006);   // drop
    await t._timers[0]();                       // let the scheduled retry run

    assert.equal(f.state.calls, 2, 'reconnect must mint a second ticket');
    var urls = FakeSocket.instances.map(function (s) { return s.url; });
    assert.ok(urls[1].indexOf('ticket-number-2') !== -1, 'reconnect used a fresh ticket');
    assert.equal(new Set(urls).size, urls.length, 'no ticket was reused across sockets');
});

test('the handshake is sent on open, before any input', async function () {
    FakeSocket.reset();
    var t = makeTransport(makeMintFetch());
    await t.connect();
    var s = FakeSocket.instances[0];
    s.fireOpen();
    assert.equal(JSON.parse(s.sent[0]).AuthToken, '');
    t.send('ls\r');
    assert.equal(s.sent[1], '0ls\r');
});

test('output frames reach the onOutput handler decoded', async function () {
    FakeSocket.reset();
    var t = makeTransport(makeMintFetch());
    await t.connect();
    var s = FakeSocket.instances[0];
    s.fireOpen();
    s.fireMessage(encodeFrame('0', 'XACA_OK'));
    assert.deepEqual(t._outputs, ['XACA_OK']);
});

test('resize before connect is remembered and applied in the handshake', async function () {
    FakeSocket.reset();
    var t = makeTransport(makeMintFetch());
    t.resize(123, 45);
    await t.connect();
    var s = FakeSocket.instances[0];
    s.fireOpen();
    assert.deepEqual(JSON.parse(s.sent[0]), { AuthToken: '', columns: 123, rows: 45 });
});

test('an INSECURE_ORIGIN failure is terminal, not retried forever', async function () {
    FakeSocket.reset();
    var f = makeMintFetch();
    var t = makeTransport(f, { location: HTTP_LOC });
    await t.connect();
    assert.equal(t.getState(), 'failed');
    assert.equal(t._timers.length, 0, 'must not schedule a retry it can never win');
    assert.ok(/HTTPS/.test(t._statuses[t._statuses.length - 1][1]),
        'the user must be told what to do about it');
});

test('a deliberate disconnect() does not trigger the reconnect path', async function () {
    FakeSocket.reset();
    var f = makeMintFetch();
    var t = makeTransport(f);
    await t.connect();
    FakeSocket.instances[0].fireOpen();
    t.disconnect();
    FakeSocket.instances[0].fireClose(1000);
    assert.equal(t.getState(), 'disconnected');
    assert.equal(f.state.calls, 1, 'closing a pane must not mint again');
});

/** Drive sockets that never reach `open` until the transport gives up.
 *
 *  NOTE the deliberate absence of `fireOpen()`. A socket that OPENS resets the
 *  attempt counter — correctly, because a connection that came up and later
 *  dropped is a fresh incident, not a continuation of the previous one. An
 *  earlier draft of these tests called fireOpen() in this loop and could never
 *  exhaust the budget; the test was wrong, not the transport. Exhaustion is
 *  reached only by repeatedly failing to establish at all.
 */
async function exhaustReconnectBudget(t) {
    for (var i = 0; i < client.RECONNECT_MAX_ATTEMPTS + 2; i++) {
        var s = FakeSocket.instances[FakeSocket.instances.length - 1];
        s.fireClose(1006);
        var next = t._timers.shift();
        if (!next) break;
        await next();
    }
}

test('an OPEN socket resets the attempt budget', async function () {
    FakeSocket.reset();
    var t = makeTransport(makeMintFetch());
    await t.connect();
    FakeSocket.instances[0].fireClose(1006);      // fail once -> attempt = 1
    assert.equal(t._attemptCount(), 1);
    await t._timers.shift()();
    FakeSocket.instances[1].fireOpen();           // success
    assert.equal(t._attemptCount(), 0, 'a successful open must clear the backoff');
});

test('reconnect gives up after a bounded number of attempts', async function () {
    FakeSocket.reset();
    var t = makeTransport(makeMintFetch());
    await t.connect();
    await exhaustReconnectBudget(t);
    assert.equal(t.getState(), 'failed');
});

test('retryNow() clears an exhausted attempt budget so a manual tap works', async function () {
    FakeSocket.reset();
    var f = makeMintFetch();
    var t = makeTransport(f);
    await t.connect();
    await exhaustReconnectBudget(t);
    assert.equal(t.getState(), 'failed');
    var before = f.state.calls;
    await t.retryNow();
    assert.equal(f.state.calls, before + 1, 'a manual retry must mint a fresh ticket');
    assert.notEqual(t.getState(), 'failed');
});

test('a failed mint surfaces as a retry, not a crash', async function () {
    FakeSocket.reset();
    var t = makeTransport(makeMintFetch({ failWith: 503 }));
    await t.connect();
    assert.equal(t.getState(), 'reconnecting');
});

// ─── Discovery ────────────────────────────────────────────────────────────────

test('fetchTerminals attaches the API key explicitly (apiFetch skips GETs)', async function () {
    var seen = null;
    await client.fetchTerminals({
        fetchImpl: function (url, init) {
            seen = { url: url, init: init };
            return Promise.resolve({ ok: true, status: 200, json: function () { return Promise.resolve({ terminals: [] }); } });
        },
        resolveKey: function () { return Promise.resolve('a-resolved-api-key-value'); }
    });
    assert.equal(seen.url, '/api/terminals');
    assert.equal(seen.init.headers['X-API-Key'], 'a-resolved-api-key-value');
});

test('fetchTerminals raises with the status when discovery is refused', async function () {
    await assert.rejects(
        client.fetchTerminals({
            fetchImpl: function () { return Promise.resolve({ ok: false, status: 401, json: function () { return Promise.resolve({}); } }); },
            resolveKey: function () { return Promise.resolve('k'); }
        }),
        function (err) { return err.status === 401; });
});
