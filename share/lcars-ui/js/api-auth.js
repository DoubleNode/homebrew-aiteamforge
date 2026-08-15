//
//  api-auth.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * api-auth.js — XACA-0395-007: central fetch wrapper injecting the LCARS
 * API-key auth header on state-mutating requests.
 *
 * Why one wrapper instead of editing 86 call sites: `lcars-ui/server.py`'s
 * `_auth_gate()` (XACA-0395-003) checks every POST/PUT/PATCH/DELETE for an
 * `Authorization: Bearer <key>` (or `X-API-Key: <key>`) header once a key is
 * configured on this machine. The browser UI has 86 mutating `fetch()` call
 * sites across lcars-ui/. Editing all 86 by hand is the failure mode this
 * file exists to avoid — new UI code should inherit the auth behavior by
 * calling `apiFetch()` instead of `fetch()`, not by remembering to add a
 * header every time.
 *
 * Key delivery (plan D5 — read before assuming this is more than it is):
 * `apiFetch()` lazily fetches GET /api/auth-key (server.py, XACA-0395-007)
 * once per page load and caches the result in memory. That key is delivered
 * to the browser from the SAME origin it is presented back to, so it is NOT
 * a secret from this page's user — it authenticates the deployment (stops an
 * off-origin/off-host caller), not the person. Real per-user auth is
 * XACA-0082, a separate, larger ticket. Do not read more security value into
 * this than that.
 *
 * P0 CORRECTION (post-review): "not a secret from this page's user" is a
 * different, much narrower claim than "readable by any origin the user's
 * browser visits" — the first cut of GET /api/auth-key made the second claim
 * true by accident via `Access-Control-Allow-Origin: *`, which would have let
 * a hostile page read the key cross-origin and replay it. Fixed server-side
 * only (no client change needed here, since this module only ever calls the
 * endpoint same-origin): the endpoint now sends no ACAO header at all (so a
 * browser withholds the response body from a foreign origin regardless) and
 * separately 403s a request whose `Origin` doesn't match its own `Host`. See
 * `serve_auth_key()` / `_origin_matches_host()` in server.py. This module's
 * `resolveKey()` degrades gracefully either way — a non-2xx response is
 * already treated as "no key", so a 403 (which should never happen for a
 * legitimate same-origin caller) surfaces as an unauthenticated mutating
 * call and the existing 401 → `notify()` failure path, not a crash.
 *
 * Failure UX (this ticket's open [UX] gate, XACA-0395-012): a 401 from a
 * mutating call is never silent. `apiFetch()` surfaces it via the existing
 * `showToast(message, 'error', duration)` LCARS pattern (lcars.js) when
 * available, and falls back to `console.error()` otherwise (e.g. before
 * lcars.js has finished loading). The message never contains the key, its
 * length, or any prefix of it — see AUTH_FAILURE_MESSAGE below, which is a
 * fixed constant with no interpolation of anything credential-shaped.
 *
 * Testability: the browser wires a module-level singleton onto
 * `window.apiFetch` / `window.lcarsApiAuth`. Node tests instead call the
 * exported `createApiAuthClient(deps)` factory directly with an injected
 * fake `fetch` and `notify`, so the suite never touches a real network or
 * the DOM. See lcars-ui/tests/test_api_auth.js.
 */

(function () {
    'use strict';

    var MUTATING_METHODS = { POST: true, PUT: true, PATCH: true, DELETE: true };

    var AUTH_KEY_ENDPOINT = '/api/auth-key';

    // Fixed constant, no interpolation — must never carry the key, its
    // length, or any prefix/suffix of it (contract §8 L2/L3, ticket scope C).
    var AUTH_FAILURE_MESSAGE =
        'Action not completed — the server rejected this request\'s API key. ' +
        'If this keeps happening, ask an admin to check the LCARS API key on this machine.';

    function normalizeMethod(init) {
        var m = (init && init.method) || 'GET';
        return String(m).toUpperCase();
    }

    function isMutatingMethod(method) {
        return !!MUTATING_METHODS[method];
    }

    /**
     * Returns a NEW options object (never mutates `init`) with `Authorization:
     * Bearer <key>` set when `key` is truthy. Works whether `init.headers` is
     * absent, a plain object, an array of pairs, or a Headers instance.
     */
    function mergeAuthHeader(init, key) {
        var opts = {};
        if (init) {
            for (var k in init) {
                if (Object.prototype.hasOwnProperty.call(init, k)) {
                    opts[k] = init[k];
                }
            }
        }
        if (!key) {
            return opts;
        }
        var HeadersCtor = (typeof Headers !== 'undefined') ? Headers : null;
        if (HeadersCtor) {
            var headers = new HeadersCtor(opts.headers || {});
            headers.set('Authorization', 'Bearer ' + key);
            opts.headers = headers;
        } else {
            // No Headers global (very old environment) — fall back to a
            // plain-object merge. Existing header names are preserved as-is;
            // this repo's call sites all use plain-object headers today.
            var merged = {};
            var existing = opts.headers || {};
            for (var hk in existing) {
                if (Object.prototype.hasOwnProperty.call(existing, hk)) {
                    merged[hk] = existing[hk];
                }
            }
            merged.Authorization = 'Bearer ' + key;
            opts.headers = merged;
        }
        return opts;
    }

    /**
     * Factory — builds an independent apiFetch client. Isolated per-instance
     * key cache and injectable fetch/notify so tests never share state and
     * never touch a real network or the DOM.
     *
     * @param {Object} deps
     * @param {Function} [deps.fetch] - fetch implementation (default: global fetch)
     * @param {Function} [deps.notify] - (message, type, duration) => void (default: window.showToast, else console.error)
     * @param {string} [deps.endpoint] - key-delivery endpoint (default: /api/auth-key)
     */
    function createApiAuthClient(deps) {
        deps = deps || {};
        var fetchImpl = deps.fetch || (typeof fetch !== 'undefined' ? fetch : undefined);
        // Injected override ONLY. The window.showToast fallback deliberately does
        // NOT happen here — see resolveNotifier() below. Resolving it at
        // construction captured `undefined` (lcars.js loads later) and silently
        // disabled every auth-failure toast on the page.
        var notifyImpl = deps.notify || null;
        var endpoint = deps.endpoint || AUTH_KEY_ENDPOINT;
        var keyPromise = null;

        function resolveKey() {
            if (!fetchImpl) {
                return Promise.resolve(null);
            }
            if (!keyPromise) {
                // Cached for the life of this client (mirrors the server's
                // resolve-once-at-startup posture — contract §2). A page
                // reload picks up a rotated key; this module does not poll.
                keyPromise = fetchImpl(endpoint, { method: 'GET' })
                    .then(function (r) { return (r && r.ok) ? r.json() : null; })
                    .then(function (data) { return (data && data.apiKey) ? data.apiKey : null; })
                    .catch(function () { return null; });
            }
            return keyPromise;
        }

        /**
         * Resolve the notifier AT CALL TIME, not at construction time.
         *
         * XACA-0395 [UX] gate fix — this was a real, permanent silent-failure bug,
         * not a theoretical one. `createApiAuthClient({})` runs when this file is
         * parsed (index.html loads it early, deliberately, so it is defined before
         * every mutating call site). But `showToast` is defined by lcars.js, which
         * loads ~2600 lines LATER in the same document. Capturing
         * `window.showToast` into a closure variable at construction therefore
         * captured `undefined` and never re-checked it — so every 401 across all
         * 86 migrated call sites degraded to console.error() for the WHOLE page
         * session. That is precisely the "silently dead button" this ticket set
         * out to prevent.
         *
         * A property lookup here (rather than a captured value) turns what looked
         * like a transient load-order race into a non-issue: by the time a user
         * can trigger a mutation, lcars.js has long since loaded.
         *
         * An injected `deps.notify` still wins — that is what the unit tests use,
         * and it is why they passed while the browser path was broken: Node has no
         * `window` at all, so the test's precondition ("no window") differs from
         * the browser's ("window exists, showToast not yet defined") even though
         * both produced the same symptom in a narrow test.
         */
        function resolveNotifier() {
            if (typeof notifyImpl === 'function') {
                return notifyImpl;
            }
            if (typeof window !== 'undefined' && typeof window.showToast === 'function') {
                return window.showToast;
            }
            return null;
        }

        function notifyAuthFailure() {
            var notifier = resolveNotifier();
            if (notifier) {
                notifier(AUTH_FAILURE_MESSAGE, 'error', 8000);
                return;
            }
            if (typeof console !== 'undefined' && console.error) {
                console.error('[LCARS AUTH] ' + AUTH_FAILURE_MESSAGE);
            }
        }

        /**
         * Drop-in replacement for `fetch(input, init)`. GET/HEAD (and any
         * method not in MUTATING_METHODS) pass straight through untouched —
         * no key lookup, no extra round trip. Mutating methods await the
         * cached key, attach it, and surface a non-silent error on 401.
         */
        function apiFetch(input, init) {
            var method = normalizeMethod(init);
            if (!isMutatingMethod(method)) {
                return fetchImpl(input, init);
            }
            return resolveKey().then(function (key) {
                var opts = mergeAuthHeader(init, key);
                return fetchImpl(input, opts).then(function (response) {
                    if (response && response.status === 401) {
                        notifyAuthFailure();
                    }
                    return response;
                });
            });
        }

        return {
            apiFetch: apiFetch,
            resolveKey: resolveKey,
            notifyAuthFailure: notifyAuthFailure,
            _resetKeyCacheForTests: function () { keyPromise = null; },
        };
    }

    var sharedExports = {
        createApiAuthClient: createApiAuthClient,
        isMutatingMethod: isMutatingMethod,
        normalizeMethod: normalizeMethod,
        mergeAuthHeader: mergeAuthHeader,
        AUTH_FAILURE_MESSAGE: AUTH_FAILURE_MESSAGE,
        AUTH_KEY_ENDPOINT: AUTH_KEY_ENDPOINT,
    };

    // Browser export — one page-lifetime singleton client. `window.apiFetch`
    // is the drop-in that the 86 mechanically-swept call sites use in place
    // of `fetch`; `window.lcarsApiAuth` exposes the rest for anything that
    // needs the lower-level pieces (or a manual key-cache reset in devtools).
    if (typeof window !== 'undefined') {
        var defaultClient = createApiAuthClient({});
        window.apiFetch = defaultClient.apiFetch;
        var lcarsApiAuth = {};
        for (var k1 in sharedExports) {
            if (Object.prototype.hasOwnProperty.call(sharedExports, k1)) {
                lcarsApiAuth[k1] = sharedExports[k1];
            }
        }
        for (var k2 in defaultClient) {
            if (Object.prototype.hasOwnProperty.call(defaultClient, k2)) {
                lcarsApiAuth[k2] = defaultClient[k2];
            }
        }
        window.lcarsApiAuth = lcarsApiAuth;
    }

    // Node export so unit tests can require() this file directly and build
    // isolated clients via createApiAuthClient() (same SSOT pattern as
    // lcars-cr-age-helpers.js / lcars-cr-metrics.js).
    if (typeof module !== 'undefined' && module.exports) {
        module.exports = sharedExports;
    }

}());
