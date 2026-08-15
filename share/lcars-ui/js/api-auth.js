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
 * SAME-ORIGIN GUARD (review finding 018): `apiFetch()` attaches the key only
 * when the target URL is same-origin (or relative, which is same-origin by
 * construction). Every call site in this repo today passes a relative path
 * built by `apiUrl()`, so nothing changes for them — the guard exists so that
 * a FUTURE call site written as `apiFetch('https://someone-else.example/x',
 * {method:'POST'})` cannot ship AITEAMFORGE_API_KEY to a foreign host. This is
 * the client-side mirror of the server-side ACAO P0 above: the server stops a
 * foreign origin READING the key, this stops our own code SENDING it there.
 * A cross-origin call is not blocked — it is simply passed through to plain
 * `fetch()` with no credential attached.
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
 * Failure UX, network-level (XACA-0395-015): a 401 is a SERVER response —
 * `fetch()` resolves normally and the check above runs. A network-level
 * failure (server unreachable, DNS failure, connection refused, a dropped
 * connection mid-request) is different in kind: `fetch()`'s promise itself
 * REJECTS, so there is no `response` and no status code to inspect. Before
 * this fix, a mutating call site with no local `.catch()` (most of the 86
 * migrated call sites) got no signal at all on this failure class — a
 * silently dead button indistinguishable from success, which is exactly the
 * defect this ticket's acceptance bar rules out. `apiFetch()` now notifies
 * once via the same notifier path as the 401 case, with a DISTINCT message
 * (a down server is not a rejected key, and the 401 copy would misdirect the
 * user into checking a key that was never the problem), then re-throws the
 * original error unchanged so any EXISTING local `.catch()` still runs
 * exactly as before. To avoid double-notifying at call sites that already
 * have their own local error toast, the re-thrown error is tagged
 * `err.isNetworkFailure = true` — the network-failure analogue of the
 * `err.status === 401` marker call sites already check (see daily-overview.js
 * `_handleDismiss`/`_handleComplete` and the calendar handlers in lcars.js).
 * A future/updated call site can check it the same way; today's call sites
 * that predate this fix have been updated alongside it.
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

    // XACA-0395-015: distinct from AUTH_FAILURE_MESSAGE on purpose — a server
    // that cannot be reached is not a rejected key, and reusing the auth copy
    // would send the user to check a key that was never the problem. Fixed
    // constant, no interpolation — never carries the key, its length, or any
    // prefix/suffix of it (same rule as AUTH_FAILURE_MESSAGE above).
    var NETWORK_FAILURE_MESSAGE =
        'Action not completed — could not reach the server. ' +
        'Check your network connection and try again.';

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
     * Best-effort extraction of the target URL from whatever `fetch()`'s
     * first argument happens to be: a string, a `URL`, or a `Request`.
     * Returns null for any shape we do not recognise — callers treat null as
     * "cannot verify", which fails CLOSED (no credential attached).
     */
    function requestUrlString(input) {
        if (typeof input === 'string') {
            return input;
        }
        if (input && typeof input.url === 'string') {
            return input.url;   // Request
        }
        if (input && typeof input.href === 'string') {
            return input.href;  // URL
        }
        return null;
    }

    /**
     * True when `input` targets this page's own origin — review finding 018.
     *
     * Three cases, in the order they are decided:
     *   1. A relative URL ('/api/todos', 'foo/bar', '?x=1', '#frag', '') is
     *      same-origin by construction. No resolution needed, and this is
     *      what every current call site passes.
     *   2. A protocol-relative ('//host/path') or absolute ('https://host/x')
     *      URL is resolved against the page and its origin compared. Note
     *      '//host/path' MUST NOT be treated as relative: it keeps the
     *      scheme but replaces the host, which is exactly the leak this
     *      guard exists to stop.
     *   3. No base URL and no `URL` constructor available (a non-browser
     *      host that also injected no baseHref) -> unverifiable -> false.
     *      Withholding a credential can only cause a 401, which is visible
     *      and recoverable; sending one to the wrong host is not.
     *
     * @param {*} input - fetch()'s first argument
     * @param {string} [baseHref] - page URL to resolve against (tests inject this)
     */
    function isSameOriginTarget(input, baseHref) {
        var raw = requestUrlString(input);
        if (raw === null) {
            return false;
        }
        var url = String(raw).trim();
        if (url === '') {
            return true;   // resolves to the current document
        }
        // XACA-0395 review finding — NO "looks relative" string heuristic here.
        //
        // The previous cut short-circuited to `true` for anything without a
        // scheme that did not start with '//'. That is not what a URL parser
        // does, and four hostile forms slipped through it, each verified
        // against the shipped function to return sameOrigin=true while
        // actually resolving to http://evil.com:
        //
        //     \\evil.com/x        WHATWG normalises '\' -> '/', so this is '//evil.com/x'
        //     /\evil.com/x        same normalisation
        //     /<TAB>/evil.com/x   tab is STRIPPED, leaving '//evil.com/x'
        //     /<LF>/evil.com/x    newline is stripped likewise
        //
        // Any string test for "is this relative?" diverges from WHATWG
        // resolution, and the divergence is the bypass. The only safe form is
        // to RESOLVE and compare origins — let the parser decide.
        var base = baseHref ||
            ((typeof location !== 'undefined' && location && location.href) ? location.href : null);
        if (typeof URL === 'undefined') {
            return false;  // cannot verify -> fail closed
        }
        // With no page context (Node tests, workers without `location`) resolve
        // against a synthetic origin instead of failing closed: a genuinely
        // relative URL stays same-origin, while anything that RESOLVES to
        // another host is still correctly rejected. The comparison is
        // base-relative, so the synthetic value never leaks into a decision.
        var effectiveBase = base || 'http://lcars-same-origin.invalid/';
        try {
            return new URL(url, effectiveBase).origin === new URL(effectiveBase).origin;
        } catch (e) {
            return false;
        }
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
     * @param {string} [deps.baseHref] - page URL the same-origin guard resolves against (default: location.href)
     */
    function createApiAuthClient(deps) {
        deps = deps || {};
        var fetchImpl = deps.fetch || (typeof fetch !== 'undefined' ? fetch : undefined);
        var baseHref = deps.baseHref || null;
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
                // Cached for the life of this client ONLY on an authoritative
                // answer (mirrors the server's resolve-once-at-startup
                // posture — contract §2). A page reload picks up a rotated
                // key; this module does not poll.
                //
                // Review finding 021: this used to cache the null from a
                // FAILED lookup too. One transient blip fetching
                // GET /api/auth-key — a dropped connection during a server
                // restart, a 502 from the funnel — therefore poisoned the
                // cache for the life of the page, and every mutation after
                // it 401'd until the user thought to reload. The user-visible
                // symptom (a dead button) is identical to a real auth
                // failure, so nobody would diagnose it as transient.
                //
                // Two outcomes, deliberately treated differently:
                //   * 2xx that says {"apiKey": null} -> AUTHORITATIVE "this
                //     machine has no key configured" (open posture). Cached;
                //     re-asking on every mutation would be pure noise.
                //   * anything else (network error, non-2xx, unparseable
                //     body) -> NOT an answer. The cache is cleared so the
                //     next mutating call retries once, and a blip self-heals
                //     without a reload. This stays resolve-once-on-success;
                //     it is not a per-call fetch.
                var pending = fetchImpl(endpoint, { method: 'GET' })
                    .then(function (r) {
                        if (!r || !r.ok) {
                            throw new Error(
                                'auth-key lookup failed: ' + (r ? ('HTTP ' + r.status) : 'no response')
                            );
                        }
                        return r.json();
                    })
                    .then(function (data) { return (data && data.apiKey) ? data.apiKey : null; })
                    .catch(function () {
                        // Only clear OUR entry — a newer in-flight lookup
                        // may already have replaced it.
                        if (keyPromise === pending) {
                            keyPromise = null;
                        }
                        return null;
                    });
                keyPromise = pending;
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

        // XACA-0395-015 — same notifier path as notifyAuthFailure(), distinct
        // message (see NETWORK_FAILURE_MESSAGE above).
        function notifyNetworkFailure() {
            var notifier = resolveNotifier();
            if (notifier) {
                notifier(NETWORK_FAILURE_MESSAGE, 'error', 8000);
                return;
            }
            if (typeof console !== 'undefined' && console.error) {
                console.error('[LCARS AUTH] ' + NETWORK_FAILURE_MESSAGE);
            }
        }

        /**
         * Drop-in replacement for `fetch(input, init)`. GET/HEAD (and any
         * method not in MUTATING_METHODS) pass straight through untouched —
         * no key lookup, no extra round trip. Mutating methods await the
         * cached key, attach it, and surface a non-silent error on 401 (a
         * response WAS received) or on a network-level failure (fetch()'s
         * promise itself rejected — see notifyNetworkFailure() above,
         * XACA-0395-015). Either way the returned promise still resolves or
         * rejects exactly as plain `fetch()` would; only the notify side
         * effect is added.
         *
         * Review finding 018: a mutating call to a NON-same-origin URL is
         * also passed straight through, with no key lookup and no credential
         * attached. It behaves exactly like plain `fetch()` — the call is
         * not blocked, it just never carries AITEAMFORGE_API_KEY off this
         * origin. There are no such call sites today; this is the guard that
         * keeps it that way.
         */
        function apiFetch(input, init) {
            var method = normalizeMethod(init);
            if (!isMutatingMethod(method)) {
                return fetchImpl(input, init);
            }
            if (!isSameOriginTarget(input, baseHref)) {
                if (typeof console !== 'undefined' && console.warn) {
                    console.warn(
                        '[LCARS AUTH] apiFetch: credential withheld — target is not same-origin:',
                        requestUrlString(input)
                    );
                }
                return fetchImpl(input, init);
            }
            return resolveKey().then(function (key) {
                var opts = mergeAuthHeader(init, key);
                return fetchImpl(input, opts).then(function (response) {
                    if (response && response.status === 401) {
                        notifyAuthFailure();
                    }
                    return response;
                }, function (networkErr) {
                    // fetch() itself rejected — no response, no status code.
                    // Notify once via the same path as a 401, then rethrow
                    // UNCHANGED so any existing local .catch() still runs and
                    // behaves exactly as it did before this fix (requirement:
                    // must not swallow the error).
                    notifyNetworkFailure();
                    if (networkErr && typeof networkErr === 'object') {
                        networkErr.isNetworkFailure = true;
                    }
                    throw networkErr;
                });
            });
        }

        return {
            apiFetch: apiFetch,
            resolveKey: resolveKey,
            notifyAuthFailure: notifyAuthFailure,
            notifyNetworkFailure: notifyNetworkFailure,
            _resetKeyCacheForTests: function () { keyPromise = null; },
        };
    }

    var sharedExports = {
        createApiAuthClient: createApiAuthClient,
        isMutatingMethod: isMutatingMethod,
        normalizeMethod: normalizeMethod,
        mergeAuthHeader: mergeAuthHeader,
        isSameOriginTarget: isSameOriginTarget,
        requestUrlString: requestUrlString,
        AUTH_FAILURE_MESSAGE: AUTH_FAILURE_MESSAGE,
        NETWORK_FAILURE_MESSAGE: NETWORK_FAILURE_MESSAGE,
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
