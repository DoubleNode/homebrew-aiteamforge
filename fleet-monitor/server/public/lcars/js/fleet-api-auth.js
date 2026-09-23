//
//  fleet-api-auth.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * fleet-api-auth.js — XACA-0398-003: central fetch wrapper + LCARS unlock
 * dialog for fleet-monitor's ADMIN-tier routes.
 *
 * IDENTICAL COPIES live at public/lcars/js/ and public/lcars2/js/ (same
 * convention as vault-offline-popup.js). Edit one, copy to the other; the
 * test suite fails if they drift.
 *
 * WHAT IT DOES
 *   apiFetch(url, init) is a drop-in for fetch(). For a SAME-ORIGIN request:
 *     - sends `credentials: 'same-origin'` so the HttpOnly session cookie
 *       rides along;
 *     - adds `X-Fleet-CSRF: 1` on POST/PUT/PATCH/DELETE (CSRF layer 2 —
 *       the server refuses the cookie without it);
 *     - on a 401 from a mutating call, opens the unlock dialog ONCE, and if
 *       the operator unlocks, retries the request ONCE. A second 401 is
 *       returned to the caller as-is (no loop). Cancelling returns the
 *       original 401 so the caller's existing error path runs.
 *   A cross-origin URL is passed straight to fetch() with nothing added.
 *
 * THE TOKEN (read before changing anything here)
 *   The operator pastes the ADMIN token into the dialog. It is POSTed once to
 *   /api/auth/login, the input is cleared immediately, and it is never
 *   stored: not in a variable that outlives the call, not in localStorage or
 *   sessionStorage, not in the DOM. The server answers with an HttpOnly
 *   cookie this script cannot read. That is the whole point — see
 *   kanban/plans/XACA-0398/XACA-0398_credential_design.md §2.1 option E and
 *   the auth contract §3.6.
 *
 * NETWORK FAILURE
 *   fetch() rejects (no response). apiFetch re-throws the original error,
 *   tagged `err.isNetworkFailure = true`, so existing call-site catch blocks
 *   still run. It never opens the unlock dialog for a network failure — a
 *   down server is not a locked one.
 *
 * TESTABILITY
 *   Node tests call createFleetApiAuth({ fetch, document, location }) with
 *   fakes (jsdom). The browser wires one instance onto window.FleetApiAuth
 *   and window.fleetApiFetch.
 */

(function (global) {
    'use strict';

    var MUTATING = { POST: true, PUT: true, PATCH: true, DELETE: true };
    var CSRF_HEADER = 'X-Fleet-CSRF';
    var LOGIN_URL = '/api/auth/login';
    var LOGOUT_URL = '/api/auth/logout';
    var SESSION_URL = '/api/auth/session';

    // Fixed strings. Never interpolate anything credential-shaped into these.
    var MSG_REJECTED = 'Token not accepted. Check it and try again.';
    var MSG_RATE_LIMITED = 'Too many failed attempts. Wait 15 minutes and try again.';
    var MSG_NETWORK = 'Could not reach the server. Check your connection and try again.';
    var MSG_UNEXPECTED = 'Unlock failed. Try again.';
    // XACA-0398-019: a 403 from /api/auth/login is the server's CSRF check
    // refusing this page (Origin/Host mismatch, stripped Sec-Fetch-Site…).
    // Retrying the same page cannot fix that, so don't tell them to.
    var MSG_FORBIDDEN = 'Could not verify this page — reload and try again.';
    var MSG_EMPTY = 'Enter the admin token.';

    function createFleetApiAuth(deps) {
        deps = deps || {};
        var doFetch = deps.fetch || (typeof fetch !== 'undefined' ? fetch.bind(global) : null);
        var doc = deps.document || (typeof document !== 'undefined' ? document : null);
        var loc = deps.location || (typeof location !== 'undefined' ? location : null);

        var pendingUnlock = null; // shared promise so concurrent 401s open ONE dialog

        // ------------------------------------------------------------------
        // Request helpers
        // ------------------------------------------------------------------

        function methodOf(init) {
            return String((init && init.method) || 'GET').toUpperCase();
        }

        function isSameOrigin(url) {
            if (!loc) return true;
            try {
                return new URL(String(url), loc.href).origin === loc.origin;
            } catch (_) {
                return false;
            }
        }

        function withAuthOptions(init) {
            var opts = {};
            if (init) {
                for (var k in init) {
                    if (Object.prototype.hasOwnProperty.call(init, k)) opts[k] = init[k];
                }
            }
            opts.credentials = 'same-origin';
            if (MUTATING[methodOf(init)]) {
                if (typeof Headers !== 'undefined') {
                    var h = new Headers(opts.headers || {});
                    h.set(CSRF_HEADER, '1');
                    opts.headers = h;
                } else {
                    var merged = {};
                    var existing = opts.headers || {};
                    for (var name in existing) {
                        if (Object.prototype.hasOwnProperty.call(existing, name)) merged[name] = existing[name];
                    }
                    merged[CSRF_HEADER] = '1';
                    opts.headers = merged;
                }
            }
            return opts;
        }

        function tagNetwork(err) {
            try { err.isNetworkFailure = true; } catch (_) { /* frozen error */ }
            return err;
        }

        async function send(url, init) {
            try {
                return await doFetch(url, withAuthOptions(init));
            } catch (err) {
                throw tagNetwork(err);
            }
        }

        /**
         * Drop-in replacement for fetch() on fleet-monitor admin calls.
         * @returns {Promise<Response>}
         */
        async function apiFetch(url, init) {
            if (!isSameOrigin(url)) {
                return doFetch(url, init);
            }
            var resp = await send(url, init);
            if (resp.status !== 401 || !MUTATING[methodOf(init)]) {
                return resp;
            }
            var unlocked = await unlock();
            if (!unlocked) return resp;
            return send(url, init); // retry exactly once
        }

        // ------------------------------------------------------------------
        // Session endpoints
        // ------------------------------------------------------------------

        async function getSession() {
            try {
                var r = await doFetch(SESSION_URL, { credentials: 'same-origin' });
                if (!r.ok) return null;
                return await r.json();
            } catch (_) {
                return null;
            }
        }

        /** POST the token. Returns 'ok' | 'rejected' | 'forbidden' | 'rate_limited' | 'network' | 'gate_open' | 'error'. */
        async function submitToken(token) {
            var body = JSON.stringify({ token: token });
            token = null; // drop our reference as early as possible
            var r;
            try {
                r = await doFetch(LOGIN_URL, {
                    method: 'POST',
                    credentials: 'same-origin',
                    headers: { 'Content-Type': 'application/json', 'X-Fleet-CSRF': '1' },
                    body: body,
                });
            } catch (_) {
                return 'network';
            } finally {
                body = null;
            }
            if (r.ok) return 'ok';
            if (r.status === 401) return 'rejected';
            if (r.status === 403) return 'forbidden';
            if (r.status === 429) return 'rate_limited';
            if (r.status === 409) return 'gate_open';
            return 'error';
        }

        async function logout() {
            try {
                await doFetch(LOGOUT_URL, {
                    method: 'POST',
                    credentials: 'same-origin',
                    headers: { 'X-Fleet-CSRF': '1' },
                });
            } catch (_) { /* best effort */ }
            removeStatusChip();
        }

        // ------------------------------------------------------------------
        // Unlock dialog
        // ------------------------------------------------------------------

        function injectStyles() {
            if (!doc || doc.getElementById('fleet-unlock-styles')) return;
            var style = doc.createElement('style');
            style.id = 'fleet-unlock-styles';
            style.textContent = [
                '.fleet-unlock-overlay {',
                '    position: fixed; top: 0; left: 0; right: 0; bottom: 0;',
                '    background: rgba(0, 0, 0, 0.82);',
                '    display: flex; align-items: center; justify-content: center;',
                '    z-index: 10050;',
                '}',
                '.fleet-unlock-box {',
                '    background: var(--lcars-darker, #0d0d1a);',
                '    border: 2px solid var(--lcars-orange, #ff9900);',
                '    border-radius: 12px;',
                '    max-width: 440px; width: 92%;',
                '    font-family: var(--font-primary, "Share Tech Mono", monospace);',
                '}',
                '.fleet-unlock-header {',
                '    background: var(--lcars-orange, #ff9900);',
                '    padding: 14px 20px;',
                '    border-top-left-radius: 10px; border-top-right-radius: 10px;',
                '}',
                '.fleet-unlock-title {',
                '    margin: 0; font-size: 14px; font-weight: 700;',
                '    color: var(--lcars-black, #000000);',
                '    letter-spacing: 2px; text-transform: uppercase;',
                '}',
                '.fleet-unlock-body { padding: 20px 22px 8px 22px; }',
                '.fleet-unlock-lead {',
                '    margin: 0 0 14px 0; font-size: 13px; line-height: 1.6;',
                '    color: var(--lcars-peach, #ffcc99);',
                '}',
                '.fleet-unlock-label {',
                '    display: block; margin-bottom: 6px; font-size: 11px;',
                '    letter-spacing: 1.5px; text-transform: uppercase;',
                '    color: var(--lcars-tan, #cc9966);',
                '}',
                '.fleet-unlock-input {',
                '    width: 100%; box-sizing: border-box; padding: 9px 10px;',
                '    background: var(--lcars-black, #000000);',
                '    border: 1px solid var(--lcars-tan, #cc9966); border-radius: 6px;',
                '    color: var(--lcars-peach, #ffcc99); font-family: inherit; font-size: 13px;',
                '}',
                '.fleet-unlock-input:focus-visible, .fleet-unlock-btn:focus-visible {',
                '    outline: 2px solid var(--lcars-amber, #ffcc00); outline-offset: 2px;',
                '}',
                // XACA-0398-017: NOT --lcars-red. Both shipped themes define
                // it as #cc4444, which is 4.11:1 on --lcars-darker (fails AA
                // 4.5:1 for 12px text). --lcars-alert-red (#ff6666) is 6.74:1.
                // The global --lcars-red is left alone — the whole UI uses it.
                // tests/xaca-0398-003-fleet-api-auth.test.js checks every
                // dialog text/background pair against BOTH theme files.
                '.fleet-unlock-error {',
                '    min-height: 18px; margin: 8px 0 0 0; font-size: 12px;',
                '    color: var(--lcars-alert-red, #ff6666);',
                '}',
                '.fleet-unlock-note {',
                '    margin: 10px 0 0 0; font-size: 11px; line-height: 1.5;',
                '    color: var(--lcars-tan, #cc9966);',
                '}',
                '.fleet-unlock-footer {',
                '    padding: 14px 22px 18px 22px;',
                '    display: flex; justify-content: flex-end; gap: 10px;',
                '}',
                '.fleet-unlock-btn {',
                '    border: none; border-radius: 6px; padding: 9px 20px;',
                '    font-family: inherit; font-size: 12px; font-weight: 700;',
                '    letter-spacing: 1.5px; text-transform: uppercase; cursor: pointer;',
                '    color: var(--lcars-black, #000000);',
                '}',
                '.fleet-unlock-btn[disabled] { opacity: 0.6; cursor: wait; }',
                '.fleet-unlock-cancel { background: var(--lcars-tan, #cc9966); }',
                '.fleet-unlock-submit { background: var(--lcars-orange, #ff9900); }',
                '.fleet-unlock-submit:hover { background: var(--lcars-amber, #ffcc00); }',
                '.fleet-unlock-chip {',
                '    position: fixed; right: 16px; bottom: 16px; z-index: 10040;',
                '    background: var(--lcars-orange, #ff9900); color: var(--lcars-black, #000000);',
                '    border: none; border-radius: 14px; padding: 6px 14px;',
                '    font-family: var(--font-primary, "Share Tech Mono", monospace);',
                '    font-size: 11px; font-weight: 700; letter-spacing: 1.5px;',
                '    text-transform: uppercase; cursor: pointer;',
                '}',
                '.fleet-unlock-chip:focus-visible { outline: 2px solid var(--lcars-amber, #ffcc00); outline-offset: 2px; }'
            ].join('\n');
            doc.head.appendChild(style);
        }

        function el(tag, className, attrs) {
            var node = doc.createElement(tag);
            if (className) node.className = className;
            if (attrs) {
                for (var a in attrs) {
                    if (Object.prototype.hasOwnProperty.call(attrs, a)) node.setAttribute(a, attrs[a]);
                }
            }
            return node;
        }

        /**
         * XACA-0398-018: take everything behind the overlay out of the
         * accessibility tree and out of interaction while the modal is open,
         * so a screen-reader virtual cursor cannot wander into the dashboard.
         * Sets `inert` (the real fix) plus aria-hidden="true" (fallback for
         * engines without inert) on every body child EXCEPT the overlay.
         * Returns a function that restores each node's ORIGINAL attributes —
         * a node that was already inert/aria-hidden stays that way.
         */
        function hideBackground(overlay) {
            var saved = [];
            var kids = doc.body.children;
            for (var i = 0; i < kids.length; i++) {
                var node = kids[i];
                if (node === overlay) continue;
                saved.push({
                    node: node,
                    inert: node.getAttribute('inert'),
                    ariaHidden: node.getAttribute('aria-hidden'),
                });
                node.setAttribute('inert', '');
                node.setAttribute('aria-hidden', 'true');
            }
            return function restore() {
                for (var j = 0; j < saved.length; j++) {
                    var s = saved[j];
                    if (s.inert === null) s.node.removeAttribute('inert');
                    else s.node.setAttribute('inert', s.inert);
                    if (s.ariaHidden === null) s.node.removeAttribute('aria-hidden');
                    else s.node.setAttribute('aria-hidden', s.ariaHidden);
                }
                saved = [];
            };
        }

        /**
         * Open the unlock dialog. Resolves true once the server accepted the
         * token (cookie set), false if the operator cancelled.
         * Concurrent callers share one dialog.
         */
        function unlock() {
            if (pendingUnlock) return pendingUnlock;
            if (!doc || !doc.body) return Promise.resolve(false);
            pendingUnlock = new Promise(function (resolve) {
                openDialog(resolve);
            }).then(function (result) {
                pendingUnlock = null;
                return result;
            });
            return pendingUnlock;
        }

        function openDialog(resolve) {
            injectStyles();
            var previouslyFocused = doc.activeElement;

            var overlay = el('div', 'fleet-unlock-overlay', { id: 'fleet-unlock-overlay' });
            var box = el('div', 'fleet-unlock-box', {
                role: 'dialog',
                'aria-modal': 'true',
                'aria-labelledby': 'fleet-unlock-title',
                'aria-describedby': 'fleet-unlock-lead',
            });

            var header = el('div', 'fleet-unlock-header');
            var title = el('h2', 'fleet-unlock-title', { id: 'fleet-unlock-title' });
            title.textContent = 'Admin Access Required';
            header.appendChild(title);

            var form = el('form', 'fleet-unlock-form', { novalidate: 'novalidate' });
            var body = el('div', 'fleet-unlock-body');
            var lead = el('p', 'fleet-unlock-lead', { id: 'fleet-unlock-lead' });
            lead.textContent = 'This action needs the fleet admin token. Unlocking keeps admin actions ' +
                'available in this browser for 8 hours.';
            var label = el('label', 'fleet-unlock-label', { for: 'fleet-unlock-token' });
            label.textContent = 'Admin token';
            // type=password + autocomplete=current-password lets a password
            // manager fill it. The value is cleared right after the POST.
            var input = el('input', 'fleet-unlock-input', {
                id: 'fleet-unlock-token',
                name: 'token',
                type: 'password',
                autocomplete: 'current-password',
                spellcheck: 'false',
                autocapitalize: 'off',
                'aria-describedby': 'fleet-unlock-error',
            });
            var errorEl = el('p', 'fleet-unlock-error', { id: 'fleet-unlock-error', role: 'alert', 'aria-live': 'assertive' });
            var note = el('p', 'fleet-unlock-note');
            note.textContent = 'The token is exchanged for a session cookie and is not stored by this page.';
            body.appendChild(lead);
            body.appendChild(label);
            body.appendChild(input);
            body.appendChild(errorEl);
            body.appendChild(note);

            var footer = el('div', 'fleet-unlock-footer');
            var cancelBtn = el('button', 'fleet-unlock-btn fleet-unlock-cancel', { type: 'button' });
            cancelBtn.textContent = 'Cancel';
            var submitBtn = el('button', 'fleet-unlock-btn fleet-unlock-submit', { type: 'submit' });
            submitBtn.textContent = 'Unlock';
            footer.appendChild(cancelBtn);
            footer.appendChild(submitBtn);

            form.appendChild(body);
            form.appendChild(footer);
            box.appendChild(header);
            box.appendChild(form);
            overlay.appendChild(box);
            doc.body.appendChild(overlay);
            var restoreBackground = hideBackground(overlay);

            var closed = false;
            function close(result) {
                if (closed) return;
                closed = true;
                input.value = '';
                doc.removeEventListener('keydown', onKeydown, true);
                if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
                restoreBackground();
                if (previouslyFocused && typeof previouslyFocused.focus === 'function') {
                    try { previouslyFocused.focus(); } catch (_) { /* element gone */ }
                }
                resolve(result);
            }

            function focusables() {
                return [input, cancelBtn, submitBtn].filter(function (n) { return !n.disabled; });
            }

            function onKeydown(e) {
                if (e.key === 'Escape' || e.key === 'Esc') {
                    e.preventDefault();
                    e.stopPropagation();
                    close(false);
                    return;
                }
                if (e.key === 'Tab') {
                    // Keep focus inside the dialog (aria-modal).
                    var list = focusables();
                    if (!list.length) return;
                    var first = list[0];
                    var last = list[list.length - 1];
                    if (e.shiftKey && doc.activeElement === first) {
                        e.preventDefault();
                        last.focus();
                    } else if (!e.shiftKey && doc.activeElement === last) {
                        e.preventDefault();
                        first.focus();
                    } else if (list.indexOf(doc.activeElement) === -1) {
                        e.preventDefault();
                        first.focus();
                    }
                }
            }
            doc.addEventListener('keydown', onKeydown, true);

            cancelBtn.addEventListener('click', function () { close(false); });

            form.addEventListener('submit', async function (e) {
                e.preventDefault();
                var value = input.value;
                input.value = '';
                if (!value || !value.trim()) {
                    errorEl.textContent = MSG_EMPTY;
                    input.focus();
                    return;
                }
                errorEl.textContent = '';
                submitBtn.disabled = true;
                cancelBtn.disabled = true;
                input.disabled = true;
                var outcome = await submitToken(value);
                value = null;
                submitBtn.disabled = false;
                cancelBtn.disabled = false;
                input.disabled = false;
                if (outcome === 'ok' || outcome === 'gate_open') {
                    close(true);
                    if (outcome === 'ok') showStatusChip();
                    return;
                }
                errorEl.textContent =
                    outcome === 'rejected' ? MSG_REJECTED :
                    outcome === 'forbidden' ? MSG_FORBIDDEN :
                    outcome === 'rate_limited' ? MSG_RATE_LIMITED :
                    outcome === 'network' ? MSG_NETWORK : MSG_UNEXPECTED;
                input.focus();
            });

            input.focus();
        }

        // ------------------------------------------------------------------
        // Unlocked-state chip: shown only while this browser holds a session,
        // so kiosk/read-only screens (which never unlock) never see it. It is
        // the logout affordance.
        // ------------------------------------------------------------------

        function removeStatusChip() {
            if (!doc) return;
            var chip = doc.getElementById('fleet-unlock-chip');
            if (chip && chip.parentNode) chip.parentNode.removeChild(chip);
        }

        function showStatusChip() {
            if (!doc || !doc.body || doc.getElementById('fleet-unlock-chip')) return;
            injectStyles();
            var chip = el('button', 'fleet-unlock-chip', {
                id: 'fleet-unlock-chip',
                type: 'button',
                'aria-label': 'Admin unlocked. Lock admin actions in this browser.',
                title: 'Admin unlocked — click to lock',
            });
            chip.textContent = 'Admin unlocked · Lock';
            chip.addEventListener('click', function () { logout(); });
            doc.body.appendChild(chip);
        }

        async function refreshStatus() {
            var s = await getSession();
            if (s && s.gate === 'closed' && s.authenticated) showStatusChip();
            else removeStatusChip();
        }

        return {
            apiFetch: apiFetch,
            unlock: unlock,
            logout: logout,
            getSession: getSession,
            refreshStatus: refreshStatus,
            isSameOrigin: isSameOrigin,
            _withAuthOptions: withAuthOptions,
        };
    }

    if (typeof module !== 'undefined' && module.exports) {
        module.exports = { createFleetApiAuth: createFleetApiAuth };
    }

    if (global && typeof global.document !== 'undefined' && !global.FleetApiAuth) {
        var instance = createFleetApiAuth();
        global.FleetApiAuth = instance;
        global.fleetApiFetch = instance.apiFetch;
        var start = function () { instance.refreshStatus(); };
        if (global.document.readyState === 'loading') {
            global.document.addEventListener('DOMContentLoaded', start);
        } else {
            start();
        }
    }
})(typeof window !== 'undefined' ? window : this);
