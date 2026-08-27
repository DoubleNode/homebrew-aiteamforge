//
//  lcars-terminal-client.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * lcars-terminal-client.js — XACA-0161-004: the transport half of the iPad
 * cockpit. Everything here is DOM-free and dependency-injected so the whole
 * ticket/reconnect/codec surface is unit-testable in Node; `terminal.html`
 * owns the DOM and xterm.js wiring and calls into this.
 *
 * WHAT THIS TALKS TO
 * ==================
 * `lcars_terminal.py` + the four route handlers in `server.py` (XACA-0161-003).
 * Read that module's docstring before changing anything here — the contract is
 * theirs, not ours. The three facts that shape every line below:
 *
 *   1. MINT is an authenticated POST:  POST /api/terminal/ticket
 *      {"terminal": "<name>"} -> {"ticket", "expiresInSeconds", "wsPath"}
 *   2. REDEEM is a query-string nonce: GET /terminal/<name>/ws?ticket=<nonce>
 *      upgraded to a WebSocket. The nonce is SINGLE-USE, ~30s TTL, and bound
 *      to exactly one terminal name.
 *   3. DISCOVERY is a GATED GET:      GET /api/terminals
 *
 * WHY THERE IS NO TICKET CACHE, AND WHY THAT IS NOT AN OVERSIGHT
 * ==============================================================
 * A ticket is burned by its first redemption and expires in 30 seconds. Both
 * properties are load-bearing (a query-string credential for a root-equivalent
 * shell is only acceptable BECAUSE it is worthless a moment later), and both
 * make caching actively wrong:
 *
 *   * Minting at page load is a bug. By the time a human taps a pane the
 *     ticket is long dead, and the failure is a silent refused upgrade.
 *     `connect()` therefore mints INSIDE the connect call, every time.
 *   * Reusing a ticket on reconnect is a bug. The old one was burned by the
 *     connection that just dropped. Every retry in `_scheduleReconnect()`
 *     goes back through `connect()` and mints a fresh one — there is no path
 *     in this file that redeems a nonce twice.
 *   * Sharing a ticket between panes is a bug. Tickets are terminal-bound, so
 *     each pane owns its own transport and mints for its own terminal.
 *
 * If you are adding a retry, a resume, or a "reconnect faster" optimisation:
 * it must call `connect()`. Anything that stashes `this._ticket` for later is
 * reintroducing the exact failure this comment exists to prevent.
 *
 * WHY THE SCHEME IS ALWAYS wss:, WITH NO ws: FALLBACK
 * ===================================================
 * Measured on a real iPad during the XACA-0161 device spike (evaluation §7.1):
 * Apple bug FB21416603 tears down a `ws://` connection to a local-network host
 * roughly one second after the handshake when the page is running in PWA
 * `display: standalone`. `wss://` survived 90s+ under the identical setup. TLS
 * is the mitigation that makes this feature work at all, not hardening we can
 * defer, so `buildWsUrl()` REFUSES to compose a URL from a non-HTTPS page
 * rather than emitting a `ws://` one that would appear to work on a desktop
 * and then die in the user's hand on the device this ticket is for.
 *
 * Loopback is not carved out. `http://localhost` is a "secure context" by
 * browser policy, which tempts exactly this exception — but a localhost carve
 * out is a second transport path that only ever runs on a developer's machine,
 * so the path the iPad uses would be the one nobody exercises. One path,
 * exercised by everyone, is worth more than a convenient desktop fallback.
 *
 * TTYD WIRE PROTOCOL (measured against live ttyd 1.7.7, 2026-08-26)
 * =================================================================
 * Verified by connecting to a real ttyd and logging every frame, not read off
 * a changelog. Subprotocol `tty` is negotiated. Then:
 *
 *   client -> server   first message is RAW JSON, no command prefix:
 *                      {"AuthToken":"","columns":N,"rows":N}
 *                      thereafter each message is one command char + payload:
 *                        '0' INPUT   '1' RESIZE {"columns":N,"rows":N}
 *                        '2' PAUSE   '3' RESUME
 *   server -> client   BINARY frames, first byte is a command char:
 *                        '0' OUTPUT  '1' SET_WINDOW_TITLE  '2' SET_PREFERENCES
 *
 * `AuthToken` is empty on purpose: ttyd runs without `-c`, so its own token
 * endpoint returns `{"token": ""}` and its in-band token is a no-op. The gate
 * is the LCARS ticket plus the proxy-injected `X-WEBAUTH-USER`; ttyd's token
 * is not, and must never be mistaken for, authentication.
 *
 * KEEPALIVE: DO NOT ADD ONE
 * =========================
 * ttyd/lws runs `ping=5, hangup=10` — it PINGs every 5s and drops a client
 * that misses a PONG for 10s. Browsers answer PING frames in the network
 * stack automatically, so an application-level heartbeat here would add
 * traffic and change nothing. The real-world consequence to design around is
 * that a main thread stalled >10s loses the socket, which is why reconnect is
 * automatic and visible rather than something the user has to know about.
 */

(function () {
    'use strict';

    // ---- ttyd protocol constants (measured, see docstring) ----------------
    var TTYD_INPUT = '0';
    var TTYD_RESIZE = '1';
    var TTYD_OUT_OUTPUT = '0';
    var TTYD_OUT_TITLE = '1';
    var TTYD_OUT_PREFS = '2';
    var TTYD_SUBPROTOCOL = 'tty';

    // Reconnect backoff. Capped low (8s) on purpose: this is a hand-held
    // cockpit, and a user who just walked back to the iPad should not wait
    // out a 60s exponential tail before their shell returns.
    var RECONNECT_BASE_MS = 500;
    var RECONNECT_MAX_MS = 8000;
    var RECONNECT_MAX_ATTEMPTS = 6;

    /**
     * Compose the WebSocket URL for a terminal.
     *
     * Throws rather than returning a `ws://` URL when the page is not HTTPS —
     * see the docstring. `loc` is injected (not read off `window`) so the
     * refusal is testable without a browser.
     */
    function buildWsUrl(loc, terminalName, ticket) {
        if (!loc || loc.protocol !== 'https:') {
            var err = new Error(
                'Terminal panes require an HTTPS connection to LCARS. This page was ' +
                'loaded over ' + ((loc && loc.protocol) || 'an unknown protocol') +
                ', so an encrypted terminal socket cannot be opened. Reach LCARS over ' +
                'its https:// address and try again.');
            err.code = 'INSECURE_ORIGIN';
            throw err;
        }
        if (!terminalName || !/^[a-zA-Z0-9_-]+$/.test(terminalName)) {
            throw new Error('Invalid terminal name');
        }
        if (!ticket) {
            throw new Error('A ticket is required to open a terminal socket');
        }
        return 'wss://' + loc.host + '/terminal/' + terminalName +
               '/ws?ticket=' + encodeURIComponent(ticket);
    }

    /**
     * True for the iPad/iOS/visionOS hardware-keyboard Ctrl+C event.
     *
     * WHY THIS SHIM EXISTS, AND WHEN TO DELETE IT
     * -------------------------------------------
     * Safari on iPad/iOS/AppleVisionPro reports `keyCode === 13` (Enter) for
     * Ctrl+C on a hardware keyboard. xterm.js's `evaluateKeyboardEvent()`
     * switches on `keyCode`, so `case 13` sends CR and the user's Ctrl+C
     * silently becomes an Enter keypress — in a terminal, that is not a
     * cosmetic bug.
     *
     * Upstream fixed it (xterm.js #5721) by special-casing `ev.key === 'c' &&
     * ev.ctrlKey` inside `case 13`. VERIFIED 2026-08-26 by extracting
     * `src/common/input/Keyboard.ts` from each release's published sourcemap:
     * the fix is present in the 6.1.0-beta line and ABSENT from 5.4.0, 5.5.0
     * and 6.0.0 — i.e. it is in NO stable release as of this writing. Vendoring
     * the beta of a dependency whose blast radius is a root-equivalent shell is
     * the wrong trade, so we pin stable 6.0.0 and reproduce the upstream
     * condition here, in six lines we own and can test.
     *
     * DELETE THIS (and the `attachCustomKeyEventHandler` call in terminal.html)
     * when the vendored xterm.js is a stable release >= 6.1.0. Check first, in
     * the vendored bundle, that `case 13` tests `ctrlKey` — do not infer it
     * from a version number.
     */
    function isIpadCtrlC(ev) {
        return !!ev && ev.type === 'keydown' && ev.ctrlKey === true &&
               ev.key === 'c' && ev.keyCode === 13;
    }

    /** ETX (^C) — what Ctrl+C must actually put on the wire. Written as an
     *  escape, never a literal control byte: a raw 0x03 in source is invisible
     *  in every editor and diff and survives exactly one careless copy-paste. */
    var ETX = '\x03';

    /**
     * Decode one server->client frame into {type, payload}.
     * `data` is an ArrayBuffer/Uint8Array (ttyd sends binary) or a string.
     */
    function decodeFrame(data, textDecoder) {
        var str;
        if (typeof data === 'string') {
            str = data;
        } else {
            var bytes = (data instanceof Uint8Array) ? data : new Uint8Array(data);
            str = textDecoder.decode(bytes);
        }
        if (!str.length) return { type: 'empty', payload: '' };
        var cmd = str.charAt(0);
        var rest = str.slice(1);
        if (cmd === TTYD_OUT_OUTPUT) return { type: 'output', payload: rest };
        if (cmd === TTYD_OUT_TITLE) return { type: 'title', payload: rest };
        if (cmd === TTYD_OUT_PREFS) return { type: 'prefs', payload: rest };
        return { type: 'unknown', payload: rest };
    }

    function encodeInput(text) { return TTYD_INPUT + text; }
    function encodeResize(cols, rows) {
        return TTYD_RESIZE + JSON.stringify({ columns: cols, rows: rows });
    }
    function encodeHandshake(cols, rows) {
        // Raw JSON, NO command prefix — this one message is special.
        return JSON.stringify({ AuthToken: '', columns: cols, rows: rows });
    }

    /** Full jitter, so N panes reconnecting after one network blip do not
     *  stampede the mint endpoint in lockstep. */
    function backoffDelay(attempt, random) {
        var ceiling = Math.min(RECONNECT_MAX_MS, RECONNECT_BASE_MS * Math.pow(2, attempt));
        return Math.floor((random || Math.random)() * ceiling);
    }

    /**
     * One pane's transport. Owns exactly one terminal's socket lifecycle.
     *
     * deps: { fetchImpl, WebSocketImpl, location, setTimeoutImpl,
     *         clearTimeoutImpl, textDecoder, random, resolveKey }
     * handlers: { onOutput, onTitle, onStatus, onError }
     *
     * `onStatus(state, detail)` states: 'connecting' | 'connected' |
     * 'reconnecting' | 'disconnected' | 'failed'. The UI renders from these
     * and never inspects the socket directly.
     */
    function createTerminalTransport(terminalName, deps, handlers) {
        deps = deps || {};
        handlers = handlers || {};

        var fetchImpl = deps.fetchImpl;
        var WebSocketImpl = deps.WebSocketImpl;
        var loc = deps.location;
        var setTimeoutImpl = deps.setTimeoutImpl || setTimeout;
        var clearTimeoutImpl = deps.clearTimeoutImpl || clearTimeout;
        var textDecoder = deps.textDecoder || (typeof TextDecoder !== 'undefined' ? new TextDecoder() : null);
        var random = deps.random || Math.random;

        var socket = null;
        var attempt = 0;
        var reconnectTimer = null;
        var closedByUs = false;
        var lastSize = { cols: 80, rows: 24 };
        var state = 'disconnected';

        function emitStatus(next, detail) {
            state = next;
            if (handlers.onStatus) handlers.onStatus(next, detail);
        }

        /** Mint a ticket. POST, so the shared apiFetch wrapper attaches the
         *  API key for us — this is the one call in the flow that is
         *  authenticated in the ordinary way. */
        function mintTicket() {
            return fetchImpl('/api/terminal/ticket', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ terminal: terminalName })
            }).then(function (res) {
                if (!res.ok) {
                    var e = new Error('Could not obtain a terminal ticket (HTTP ' + res.status + ')');
                    e.status = res.status;
                    throw e;
                }
                return res.json();
            }).then(function (body) {
                if (!body || !body.ticket) throw new Error('Terminal ticket response was empty');
                return body.ticket;
            });
        }

        /**
         * Mint a FRESH ticket and open a socket with it. Every connection and
         * every reconnection goes through here; see the no-cache rationale in
         * the file docstring.
         */
        function connect() {
            if (socket) return Promise.resolve();
            closedByUs = false;
            emitStatus(attempt > 0 ? 'reconnecting' : 'connecting');

            return mintTicket().then(function (ticket) {
                var url = buildWsUrl(loc, terminalName, ticket);
                var ws = new WebSocketImpl(url, [TTYD_SUBPROTOCOL]);
                ws.binaryType = 'arraybuffer';
                socket = ws;

                ws.onopen = function () {
                    attempt = 0;
                    ws.send(encodeHandshake(lastSize.cols, lastSize.rows));
                    emitStatus('connected');
                };
                ws.onmessage = function (ev) {
                    var frame = decodeFrame(ev.data, textDecoder);
                    if (frame.type === 'output' && handlers.onOutput) handlers.onOutput(frame.payload);
                    else if (frame.type === 'title' && handlers.onTitle) handlers.onTitle(frame.payload);
                };
                ws.onclose = function (ev) {
                    socket = null;
                    if (closedByUs) { emitStatus('disconnected'); return; }
                    scheduleReconnect(ev && ev.code);
                };
                ws.onerror = function () { /* onclose always follows; handle there */ };
            }).catch(function (err) {
                socket = null;
                if (err && err.code === 'INSECURE_ORIGIN') {
                    // Not retryable: no amount of backoff turns http into https.
                    emitStatus('failed', err.message);
                    if (handlers.onError) handlers.onError(err);
                    return;
                }
                scheduleReconnect(null, err);
            });
        }

        function scheduleReconnect(closeCode, err) {
            if (closedByUs) { emitStatus('disconnected'); return; }
            if (attempt >= RECONNECT_MAX_ATTEMPTS) {
                emitStatus('failed', 'Lost connection to this terminal. Tap RECONNECT to try again.');
                if (handlers.onError && err) handlers.onError(err);
                return;
            }
            var delay = backoffDelay(attempt, random);
            attempt += 1;
            emitStatus('reconnecting', 'Reconnecting (attempt ' + attempt + ')...');
            reconnectTimer = setTimeoutImpl(function () {
                reconnectTimer = null;
                // RETURN the promise. A real setTimeout discards it, so this
                // is a no-op in the browser — but it is what lets a test await
                // the retry instead of racing it. Without it the reconnect
                // assertions pass vacuously: the await resolves immediately,
                // before the mint has even been issued.
                return connect();
            }, delay);
        }

        function send(text) {
            if (socket && socket.readyState === 1) socket.send(encodeInput(text));
        }

        function resize(cols, rows) {
            if (!cols || !rows) return;
            lastSize = { cols: cols, rows: rows };
            if (socket && socket.readyState === 1) socket.send(encodeResize(cols, rows));
        }

        function disconnect() {
            closedByUs = true;
            if (reconnectTimer) { clearTimeoutImpl(reconnectTimer); reconnectTimer = null; }
            if (socket) { try { socket.close(); } catch (e) { /* already gone */ } socket = null; }
            emitStatus('disconnected');
        }

        /** User-initiated retry: clears the attempt budget so a manual tap is
         *  never silently swallowed by an exhausted backoff counter. */
        function retryNow() {
            if (reconnectTimer) { clearTimeoutImpl(reconnectTimer); reconnectTimer = null; }
            attempt = 0;
            closedByUs = false;
            if (socket) { try { socket.close(); } catch (e) {} socket = null; }
            return connect();
        }

        return {
            connect: connect,
            disconnect: disconnect,
            retryNow: retryNow,
            send: send,
            resize: resize,
            terminalName: terminalName,
            getState: function () { return state; },
            _attemptCount: function () { return attempt; }
        };
    }

    /**
     * GET /api/terminals — discovery.
     *
     * This is a GATED GET, and `apiFetch()` deliberately attaches the API key
     * only to MUTATING methods, so a plain `apiFetch('/api/terminals')` would
     * 401. The credential is therefore attached explicitly here via the
     * shared key resolver. A WebSocket handshake cannot carry a header (that
     * is why tickets exist at all) but an XHR can, so discovery gets the
     * strong check.
     */
    function fetchTerminals(deps) {
        deps = deps || {};
        var fetchImpl = deps.fetchImpl;
        var resolveKey = deps.resolveKey;
        return Promise.resolve(resolveKey ? resolveKey() : null).then(function (key) {
            var headers = {};
            if (key) headers['X-API-Key'] = key;
            return fetchImpl('/api/terminals', { method: 'GET', headers: headers });
        }).then(function (res) {
            if (!res.ok) {
                var e = new Error('Terminal discovery failed (HTTP ' + res.status + ')');
                e.status = res.status;
                throw e;
            }
            return res.json();
        });
    }

    var exportsObj = {
        buildWsUrl: buildWsUrl,
        isIpadCtrlC: isIpadCtrlC,
        ETX: ETX,
        decodeFrame: decodeFrame,
        encodeInput: encodeInput,
        encodeResize: encodeResize,
        encodeHandshake: encodeHandshake,
        backoffDelay: backoffDelay,
        createTerminalTransport: createTerminalTransport,
        fetchTerminals: fetchTerminals,
        RECONNECT_MAX_ATTEMPTS: RECONNECT_MAX_ATTEMPTS,
        TTYD_SUBPROTOCOL: TTYD_SUBPROTOCOL
    };

    if (typeof window !== 'undefined') window.lcarsTerminalClient = exportsObj;
    if (typeof module !== 'undefined' && module.exports) module.exports = exportsObj;
})();
