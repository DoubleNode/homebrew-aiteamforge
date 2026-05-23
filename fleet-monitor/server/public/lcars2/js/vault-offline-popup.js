//
//  vault-offline-popup.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * Vault Offline-Mode Warning Popup (XACA-0538-005)
 *
 * Shows a one-time, dismissible LCARS-styled warning popup when the server
 * reports that secrets are currently being served from the env-var failover
 * path rather than the encrypted vault.
 *
 * ==========================================================================
 * MODE-SIGNAL INTERFACE CONTRACT (for XACA-0539 to implement)
 * ==========================================================================
 *
 *   Endpoint:   GET /api/vault/mode
 *   Auth:       none (consistent with existing /api/vault/* non-auth policy)
 *   Response:   JSON
 *     {
 *       "mode":   "vault" | "env_failover",
 *       "source": <string>   // human-readable description, e.g. "encrypted vault" or
 *                            // "environment variable fallback (FLEET_VAULT_KEY)"
 *     }
 *
 *   Popup trigger:  mode === "env_failover"
 *   No-popup cases: mode === "vault" (or any other value)
 *                   endpoint returns 404 (XACA-0539 not yet deployed)
 *                   endpoint returns any non-2xx status
 *                   network error / timeout
 *                   malformed JSON
 *                   field absent from response body
 *
 * This module is fully defensive: any absent/unreachable/unexpected signal
 * must NEVER throw an uncaught error or block LCARS startup.
 * ==========================================================================
 *
 * Usage (called from lcars-fleet-core.js initSystems):
 *   window.VaultOfflinePopup && window.VaultOfflinePopup.check();
 */

(function (global) {
    'use strict';

    // Endpoint this module polls once per session
    var MODE_ENDPOINT = '/api/vault/mode';

    // Session-gate: only show once per page load, regardless of poll count
    var _shown = false;

    // -------------------------------------------------------------------------
    // Style injection — scoped to .vault-offline-popup-overlay
    // No shared CSS or .html file is touched.
    // -------------------------------------------------------------------------

    function _injectStyles() {
        if (document.getElementById('vault-offline-popup-styles')) return;

        var style = document.createElement('style');
        style.id = 'vault-offline-popup-styles';
        style.textContent = [
            '.vault-offline-popup-overlay {',
            '    position: fixed;',
            '    top: 0; left: 0; right: 0; bottom: 0;',
            '    background: rgba(0, 0, 0, 0.82);',
            '    display: flex;',
            '    align-items: center;',
            '    justify-content: center;',
            '    z-index: 9900;',
            '    opacity: 0;',
            '    visibility: hidden;',
            '    transition: opacity 0.3s ease, visibility 0.3s ease;',
            '}',
            '.vault-offline-popup-overlay.vop-active {',
            '    opacity: 1;',
            '    visibility: visible;',
            '}',
            '.vault-offline-popup-box {',
            '    background: var(--lcars-darker, #0d0d1a);',
            '    border: 2px solid var(--lcars-amber, #ffcc00);',
            '    border-radius: 12px;',
            '    max-width: 460px;',
            '    width: 92%;',
            '    transform: scale(0.9);',
            '    transition: transform 0.3s ease;',
            '    font-family: var(--font-primary, "Share Tech Mono", monospace);',
            '}',
            '.vault-offline-popup-overlay.vop-active .vault-offline-popup-box {',
            '    transform: scale(1);',
            '}',
            '.vault-offline-popup-header {',
            '    background: var(--lcars-amber, #ffcc00);',
            '    padding: 14px 20px;',
            '    border-top-left-radius: 10px;',
            '    border-top-right-radius: 10px;',
            '    display: flex;',
            '    align-items: center;',
            '    gap: 10px;',
            '}',
            '.vault-offline-popup-icon {',
            '    font-size: 18px;',
            '    line-height: 1;',
            '    color: var(--lcars-black, #000000);',
            '}',
            '.vault-offline-popup-title {',
            '    font-size: 14px;',
            '    font-weight: 700;',
            '    color: var(--lcars-black, #000000);',
            '    letter-spacing: 2px;',
            '    text-transform: uppercase;',
            '    flex: 1;',
            '}',
            '.vault-offline-popup-body {',
            '    padding: 22px 22px 18px 22px;',
            '}',
            '.vault-offline-popup-lead {',
            '    font-size: 13px;',
            '    color: var(--lcars-peach, #ffcc99);',
            '    line-height: 1.65;',
            '    margin-bottom: 14px;',
            '}',
            '.vault-offline-popup-lead strong {',
            '    color: var(--lcars-amber, #ffcc00);',
            '}',
            '.vault-offline-popup-detail {',
            '    font-size: 11px;',
            '    color: var(--lcars-tan, #cc9966);',
            '    line-height: 1.55;',
            '    letter-spacing: 0.4px;',
            '    border-top: 1px solid var(--lcars-surface, #252540);',
            '    padding-top: 12px;',
            '}',
            '.vault-offline-popup-footer {',
            '    padding: 14px 22px 18px 22px;',
            '    display: flex;',
            '    justify-content: flex-end;',
            '}',
            '.vault-offline-popup-dismiss {',
            '    background: var(--lcars-amber, #ffcc00);',
            '    border: none;',
            '    border-radius: 6px;',
            '    padding: 9px 22px;',
            '    font-family: inherit;',
            '    font-size: 12px;',
            '    font-weight: 700;',
            '    color: var(--lcars-black, #000000);',
            '    letter-spacing: 1.5px;',
            '    text-transform: uppercase;',
            '    cursor: pointer;',
            '    transition: background 0.15s ease;',
            '}',
            '.vault-offline-popup-dismiss:hover {',
            '    background: var(--lcars-orange, #ff9900);',
            '}'
        ].join('\n');

        document.head.appendChild(style);
    }

    // -------------------------------------------------------------------------
    // DOM construction
    // -------------------------------------------------------------------------

    function _buildPopup() {
        var overlay = document.createElement('div');
        overlay.className = 'vault-offline-popup-overlay';
        overlay.id = 'vault-offline-popup-overlay';
        overlay.setAttribute('role', 'alertdialog');
        overlay.setAttribute('aria-modal', 'true');
        overlay.setAttribute('aria-labelledby', 'vop-title');

        var box = document.createElement('div');
        box.className = 'vault-offline-popup-box';

        // Header
        var header = document.createElement('div');
        header.className = 'vault-offline-popup-header';

        var icon = document.createElement('span');
        icon.className = 'vault-offline-popup-icon';
        icon.setAttribute('aria-hidden', 'true');
        icon.textContent = '⚠'; // warning triangle

        var title = document.createElement('span');
        title.className = 'vault-offline-popup-title';
        title.id = 'vop-title';
        title.textContent = 'Vault Offline Mode Active';

        header.appendChild(icon);
        header.appendChild(title);

        // Body
        var body = document.createElement('div');
        body.className = 'vault-offline-popup-body';

        var lead = document.createElement('p');
        lead.className = 'vault-offline-popup-lead';
        lead.innerHTML = 'Secrets are currently served from the ' +
            '<strong>environment-variable failover path</strong>, ' +
            'not the encrypted vault. Vault delivery is unavailable or degraded.';

        var detail = document.createElement('p');
        detail.className = 'vault-offline-popup-detail';
        detail.textContent = 'ADVISORY: Check vault connectivity and machine registration. ' +
            'Secrets sourced from env-vars are less isolated than sealed vault entries. ' +
            'This warning is shown once per session and does not repeat on refresh ' +
            'while the failover condition persists.';

        body.appendChild(lead);
        body.appendChild(detail);

        // Footer
        var footer = document.createElement('div');
        footer.className = 'vault-offline-popup-footer';

        var dismiss = document.createElement('button');
        dismiss.className = 'vault-offline-popup-dismiss';
        dismiss.textContent = 'Acknowledged';
        dismiss.addEventListener('click', function () {
            _hide(overlay);
        });

        footer.appendChild(dismiss);

        box.appendChild(header);
        box.appendChild(body);
        box.appendChild(footer);
        overlay.appendChild(box);

        // Also dismiss on backdrop click
        overlay.addEventListener('click', function (e) {
            if (e.target === overlay) {
                _hide(overlay);
            }
        });

        // Dismiss on Escape
        document.addEventListener('keydown', function handler(e) {
            if ((e.key === 'Escape' || e.key === 'Esc') && overlay.classList.contains('vop-active')) {
                _hide(overlay);
                document.removeEventListener('keydown', handler);
            }
        });

        return overlay;
    }

    function _show() {
        _injectStyles();

        // Remove any stale instance before inserting
        var old = document.getElementById('vault-offline-popup-overlay');
        if (old && old.parentNode) {
            old.parentNode.removeChild(old);
        }

        var overlay = _buildPopup();
        document.body.appendChild(overlay);

        // Trigger transition on next frame
        requestAnimationFrame(function () {
            requestAnimationFrame(function () {
                overlay.classList.add('vop-active');
            });
        });

        console.warn('[VaultOfflinePopup] OFFLINE MODE ACTIVE — secrets served from env-var failover');
    }

    function _hide(overlay) {
        overlay.classList.remove('vop-active');
        setTimeout(function () {
            if (overlay.parentNode) {
                overlay.parentNode.removeChild(overlay);
            }
        }, 350);
    }

    // -------------------------------------------------------------------------
    // Mode signal fetch — fully defensive
    // -------------------------------------------------------------------------

    /**
     * Fetch /api/vault/mode once. If mode === "env_failover" and the popup
     * has not been shown this session, display the warning popup.
     *
     * All error paths are silent — a broken or absent endpoint MUST NOT
     * throw an uncaught error or block startup.
     */
    function check() {
        // Only show once per page load
        if (_shown) return;

        try {
            fetch(MODE_ENDPOINT, {
                method: 'GET',
                headers: { 'Accept': 'application/json' },
                // Short timeout so a missing endpoint doesn't stall startup
                signal: (typeof AbortSignal !== 'undefined' && AbortSignal.timeout)
                    ? AbortSignal.timeout(4000)
                    : undefined
            })
            .then(function (res) {
                // 404 = XACA-0539 not yet deployed; treat as "no signal, no popup"
                if (!res.ok) return null;
                return res.json();
            })
            .then(function (data) {
                if (!data) return;
                if (typeof data !== 'object') return;
                if (data.mode !== 'env_failover') return;

                // Gate: only show once per session
                _shown = true;
                _show();
            })
            .catch(function () {
                // Network error, timeout, or JSON parse failure — silent, no popup
            });
        } catch (e) {
            // Synchronous guard: if fetch itself throws (very old runtime), absorb it
        }
    }

    // -------------------------------------------------------------------------
    // Public API
    // -------------------------------------------------------------------------

    global.VaultOfflinePopup = {
        check: check
    };

})(window);
