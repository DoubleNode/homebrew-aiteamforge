//
//  vault-seal.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

// === XACA-0538-001: Browser-side sealed-box helper for the Secret Vault (lcars2 variant) ===
//
// EPIC-0016 Phase A.4.2 — seals a secret value to every registered vault machine
// using libsodium crypto_box_seal (anonymous X25519 sealed boxes), mirroring the
// Node-side crypto in client/vault-keygen.js. See fleet-monitor/docs/SECRET-VAULT-DESIGN.md.
//
// HARD RULES enforced here:
//   * Plaintext is sealed CLIENT-SIDE. Only base64 ciphertext leaves the browser.
//   * The plaintext is never logged, never stored on window/state, and is best-effort
//     zeroized after use.
//   * libsodium-wrappers initializes ASYNCHRONOUSLY — every entry point awaits
//     window.sodium.ready before touching crypto (design doc §3.3; the #1 footgun).
//
// Load order (plain <script> tags, before this file):
//   js/vendor/libsodium.js            -> sets window.libsodium (base wasm provider)
//   js/vendor/libsodium-wrappers.js   -> sets window.sodium    (high-level wrapper)
//
// Exposes window.LCARS_VAULT_SEAL.

(function() {
    'use strict';

    var MACHINES_API = '/api/vault/machines';

    // base64 ORIGINAL variant — MUST match what the server validates and what
    // vault-keygen registered public keys with (design doc §6 / §7.3).
    var X25519_KEY_BYTES = 32;

    /**
     * Resolve the ready libsodium handle. Throws a clear error if the vendor
     * scripts were not loaded.
     * @returns {Promise<object>} ready sodium instance
     */
    async function ensureSodium() {
        if (typeof window.sodium === 'undefined' || !window.sodium.ready) {
            throw new Error(
                'libsodium not loaded — ensure js/vendor/libsodium.js and ' +
                'js/vendor/libsodium-wrappers.js are included before vault-seal.js'
            );
        }
        await window.sodium.ready; // #1 footgun if skipped (design doc §3.3)
        return window.sodium;
    }

    /**
     * Fetch the list of registered vault machines.
     * @returns {Promise<Array<{id:string, public_key:string, label?:string}>>}
     * @throws {Error} on network / HTTP error
     */
    async function fetchMachines() {
        var resp = await fetch(MACHINES_API);
        if (!resp.ok) {
            var detail;
            try { detail = (await resp.json()).error; } catch (_) { detail = null; }
            throw new Error(detail || ('Could not list vault machines (HTTP ' + resp.status + ')'));
        }
        var data = await resp.json();
        return (data && data.machines) ? data.machines : [];
    }

    /**
     * Seal a secret string to every registered machine. Returns the ciphertexts
     * array shaped for POST/PUT /api/vault/secrets. The caller is responsible for
     * clearing the secret string from its own scope afterward.
     *
     * @param {string} secret plaintext secret value (never logged, never persisted)
     * @param {Array<{id:string, public_key:string}>} machines registered recipients
     * @returns {Promise<Array<{machine_id:string, sealed:string, sealed_at:string}>>}
     * @throws {Error} if there are no machines, or a public key is malformed
     */
    async function sealToMachines(secret, machines) {
        if (!Array.isArray(machines) || machines.length === 0) {
            throw new Error(
                'No vault machines registered — register a machine first ' +
                '(run vault-keygen on each machine), then save again.'
            );
        }

        var sodium = await ensureSodium();
        var ORIGINAL = sodium.base64_variants.ORIGINAL;

        // Encode the plaintext to bytes exactly once; zeroize after sealing.
        var secretBytes = sodium.from_string(secret);
        var sealedAt = new Date().toISOString();
        var ciphertexts = [];

        try {
            for (var i = 0; i < machines.length; i++) {
                var m = machines[i];
                if (!m || !m.id || !m.public_key) {
                    throw new Error('Vault machine entry is missing id or public_key');
                }

                var pubBytes;
                try {
                    pubBytes = sodium.from_base64(m.public_key, ORIGINAL);
                } catch (_) {
                    pubBytes = null;
                }
                if (!pubBytes || pubBytes.length !== X25519_KEY_BYTES) {
                    throw new Error(
                        "Machine '" + m.id + "' has an invalid public key " +
                        '(expected ' + X25519_KEY_BYTES + '-byte base64 X25519)'
                    );
                }

                // Anonymous sealed box: crypto_box_seal(message, recipientPubKey).
                // Mirrors the Node side; only the holder of the matching private
                // key can open it (design doc §3 / §4).
                var sealedBytes = sodium.crypto_box_seal(secretBytes, pubBytes);
                ciphertexts.push({
                    machine_id: m.id,
                    sealed:     sodium.to_base64(sealedBytes, ORIGINAL),
                    sealed_at:  sealedAt,
                });
            }
        } finally {
            // Best-effort zeroize the plaintext bytes from memory.
            try { sodium.memzero(secretBytes); } catch (_) { /* non-fatal */ }
        }

        return ciphertexts;
    }

    /**
     * Convenience: fetch machines + seal in one call.
     * @param {string} secret
     * @returns {Promise<Array<{machine_id:string, sealed:string, sealed_at:string}>>}
     */
    async function sealSecret(secret) {
        var machines = await fetchMachines();
        return sealToMachines(secret, machines);
    }

    window.LCARS_VAULT_SEAL = {
        ensureSodium: ensureSodium,
        fetchMachines: fetchMachines,
        sealToMachines: sealToMachines,
        sealSecret: sealSecret,
    };

})();

// === /XACA-0538-001 ===
