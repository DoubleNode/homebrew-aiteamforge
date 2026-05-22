//
//  vault-crypto.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * vault-crypto.js
 * XACA-0537-003: libsodium-wrappers helper for Secret Vault.
 *
 * Wraps the async init requirement so callers cannot accidentally call
 * crypto_box_seal / crypto_box_seal_open before the WASM module is ready.
 * All exported functions await `sodium.ready` internally — callers just await
 * the returned promise and they're safe.
 *
 * DESIGN NOTE (from SECRET-VAULT-DESIGN.md §3.3):
 *   libsodium-wrappers initializes ASYNCHRONOUSLY. Any code touching crypto
 *   MUST `await sodium.ready` before calling any crypto_* function. This
 *   module bakes in that requirement so it cannot be forgotten.
 *
 * Encoding: base64 ORIGINAL variant (standard +/ with = padding) everywhere.
 * Mixed variants are a silent corruption bug — see design doc §3.5.
 *
 * SERVER RULE: the server NEVER calls sealOpen(). It holds no private key.
 * sealOpen is exported exclusively for use in tests and client-side tooling.
 */

const sodium = require('libsodium-wrappers');

/** A single shared ready-promise — initializes once, reused. */
const sodiumReady = sodium.ready;

/**
 * Ensure sodium WASM is initialized. Await this before any crypto call.
 * @returns {Promise<void>}
 */
async function ensureReady() {
    await sodiumReady;
}

/**
 * Generate a new X25519 keypair for a machine.
 * @returns {Promise<{ publicKey: string, privateKey: string }>} base64 ORIGINAL
 */
async function generateKeypair() {
    await sodiumReady;
    const kp = sodium.crypto_box_keypair();
    return {
        publicKey:  sodium.to_base64(kp.publicKey,  sodium.base64_variants.ORIGINAL),
        privateKey: sodium.to_base64(kp.privateKey, sodium.base64_variants.ORIGINAL),
    };
}

/**
 * Seal a plaintext message to a recipient's X25519 public key.
 * Produces an anonymous sealed box — the server never calls this; this is for
 * client-side tooling and tests only.
 *
 * @param {string} plaintext          UTF-8 string to seal.
 * @param {string} recipientPublicKeyB64  base64 ORIGINAL of the 32-byte X25519 public key.
 * @returns {Promise<string>}         base64 ORIGINAL of the sealed box bytes.
 */
async function seal(plaintext, recipientPublicKeyB64) {
    await sodiumReady;
    const msg = sodium.from_string(plaintext);
    const pk  = sodium.from_base64(recipientPublicKeyB64, sodium.base64_variants.ORIGINAL);
    const box = sodium.crypto_box_seal(msg, pk);
    return sodium.to_base64(box, sodium.base64_variants.ORIGINAL);
}

/**
 * Open a sealed box using the recipient's keypair.
 * SERVER MUST NEVER CALL THIS. Private keys never leave the machine that owns them.
 * Exported for client-side tooling and tests only.
 *
 * @param {string} sealedB64          base64 ORIGINAL of the sealed box.
 * @param {string} publicKeyB64       base64 ORIGINAL of the recipient's 32-byte public key.
 * @param {string} privateKeyB64      base64 ORIGINAL of the recipient's 32-byte private key.
 * @returns {Promise<string>}         Decrypted UTF-8 plaintext.
 * @throws if the ciphertext is tampered, truncated, or the wrong key is used.
 */
async function sealOpen(sealedB64, publicKeyB64, privateKeyB64) {
    await sodiumReady;
    const sealed = sodium.from_base64(sealedB64, sodium.base64_variants.ORIGINAL);
    const pk     = sodium.from_base64(publicKeyB64,  sodium.base64_variants.ORIGINAL);
    const sk     = sodium.from_base64(privateKeyB64, sodium.base64_variants.ORIGINAL);
    const opened = sodium.crypto_box_seal_open(sealed, pk, sk);
    return sodium.to_string(opened);
}

/**
 * Fail LOUD if sodium WASM is not yet initialized.
 *
 * The sync validators below cannot await `sodium.ready`, so a caller who forgot
 * `await ensureReady()` would otherwise hit an undefined `sodium.from_base64`
 * (or undefined `crypto_box_SEALBYTES`) and get a silent `false` — making VALID
 * input look rejected (XACA-0537-011, review of PR #452). Throwing instead makes
 * the missing-await contract violation obvious at the call site rather than
 * surfacing as a confusing downstream validation failure. Genuinely-invalid
 * base64 still returns `false` via the try/catch inside each validator.
 *
 * @throws {Error} when sodium is not initialized.
 */
function assertReady() {
    if (typeof sodium.from_base64 !== 'function' ||
        typeof sodium.crypto_box_SEALBYTES !== 'number') {
        throw new Error(
            'vault-crypto: sodium WASM not initialized — await ensureReady() ' +
            'before calling isValid32ByteKey/isValidSealedBox.'
        );
    }
}

/**
 * Validate that a base64 string (ORIGINAL variant) decodes to exactly 32 bytes.
 * Used to validate machine public keys.
 *
 * @param {string} b64
 * @returns {boolean}
 * @throws {Error} if called before `ensureReady()` (see assertReady).
 */
function isValid32ByteKey(b64) {
    assertReady();
    try {
        const bytes = sodium.from_base64(b64, sodium.base64_variants.ORIGINAL);
        return bytes.length === 32;
    } catch (_) {
        return false;
    }
}

/**
 * Validate that a base64 string (ORIGINAL variant) decodes to at least
 * crypto_box_SEALBYTES (48 bytes). Used to validate sealed ciphertexts.
 *
 * @param {string} b64
 * @returns {boolean}
 * @throws {Error} if called before `ensureReady()` (see assertReady).
 */
function isValidSealedBox(b64) {
    assertReady();
    try {
        const bytes = sodium.from_base64(b64, sodium.base64_variants.ORIGINAL);
        return bytes.length >= sodium.crypto_box_SEALBYTES;
    } catch (_) {
        return false;
    }
}

/**
 * The crypto_box_SEALBYTES constant (48) — overhead per sealed box.
 * Callers can reference this without importing sodium directly.
 */
function getSealBytes() {
    return sodium.crypto_box_SEALBYTES;
}

module.exports = {
    ensureReady,
    generateKeypair,
    seal,
    sealOpen,
    isValid32ByteKey,
    isValidSealedBox,
    getSealBytes,
};
