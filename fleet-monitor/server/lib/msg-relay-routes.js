//
//  msg-relay-routes.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * kb-msg cross-machine relay routes (XACA-0777), a mountable module shaped like
 * lib/vault-routes.js and mounted from server.js via registerMsgRelayRoutes(app).
 *
 * HARD RULE (mirrors the vault): NO endpoint here ever calls the sealed-box
 * open primitive. The relay is a store-and-forward for OPAQUE sealed envelopes
 * keyed by destination machine. It validates shape/length only — it is
 * STRUCTURALLY unable to read a message body. Only the recipient machine,
 * holding the X25519 private key the envelope was sealed to, can open it. This
 * file deliberately imports isValidSealedBox + ensureReady from vault-crypto and
 * nothing that can decrypt. (A test greps this source to enforce that.)
 *
 * Nothing here touches AMB (dev.agentbadges.com). This is our own internal relay.
 *
 * AUTH: Bearer-token gate on every route. When the server has FLEET_AUTH_TOKEN
 * set, a request MUST carry `Authorization: Bearer <token>` matching it or gets
 * 401. When FLEET_AUTH_TOKEN is unset the gate is open — matching the existing
 * (unauthenticated) posture of the fleet push endpoints in dev/test. Auth gates
 * who may RELAY; sealing gates who may READ. Both are required; neither alone is
 * sufficient.
 *
 * Test isolation: the message store resolves its file path from FLEET_MSG_FILE
 * at module-load time (additive seam, like FLEET_VAULT_FILE). Tests point it at
 * a temp file so they never touch the real data/messages.json.
 */

const fs   = require('fs');
const path = require('path');

const { ensureReady, isValidSealedBox } = require('./vault-crypto');

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const MSG_FILE = process.env.FLEET_MSG_FILE || path.join(__dirname, '..', 'data', 'messages.json');

const SLUG_RE          = /^[a-z][a-z0-9-]*$/;   // machine + team slugs
const MAX_SLUG_LEN     = 64;
const MAX_ID_LEN       = 128;
const MAX_FROM_LEN     = 200;
const MAX_CIPHERTEXT_LEN = 16384;               // base64 chars (~12 KB plaintext ceiling)
const MAX_QUEUE_PER_MACHINE = 2000;             // bound the Fly volume

/** Build a FRESH empty store. Never share the messages array reference across
 *  reads — a shared reference would accumulate pushes when the file is absent. */
function emptyStore() {
    return { version: 1, updated_at: '', messages: [] };
}

// ---------------------------------------------------------------------------
// Store — atomic temp+rename, mirrors vault-store.js
// ---------------------------------------------------------------------------

function readStore() {
    try {
        const raw = fs.readFileSync(MSG_FILE, 'utf8');
        const data = JSON.parse(raw);
        if (!data || !Array.isArray(data.messages)) return emptyStore();
        return data;
    } catch (_) {
        return emptyStore();
    }
}

function writeStore(data) {
    data.updated_at = new Date().toISOString();
    const dir = path.dirname(MSG_FILE);
    try {
        fs.mkdirSync(dir, { recursive: true });
    } catch (_) { /* dir may exist */ }
    const tmp = `${MSG_FILE}.tmp.${process.pid}`;
    fs.writeFileSync(tmp, JSON.stringify(data, null, 2));
    fs.renameSync(tmp, MSG_FILE);
    return true;
}

// ---------------------------------------------------------------------------
// Validation — shape/length ONLY. The relay cannot inspect content.
// ---------------------------------------------------------------------------

function validateEnvelope(body) {
    const errors = [];
    const { id, to_team, machine, ciphertext, from, to_terminal } = body || {};

    if (!id || typeof id !== 'string' || id.length > MAX_ID_LEN) {
        errors.push(`id is required (string, max ${MAX_ID_LEN} chars)`);
    }
    if (!machine || typeof machine !== 'string' || !SLUG_RE.test(machine) || machine.length > MAX_SLUG_LEN) {
        errors.push('machine must be a slug matching ^[a-z][a-z0-9-]*$');
    }
    if (!to_team || typeof to_team !== 'string' || !SLUG_RE.test(to_team) || to_team.length > MAX_SLUG_LEN) {
        errors.push('to_team must be a slug matching ^[a-z][a-z0-9-]*$');
    }
    // to_terminal is optional (null == broadcast); if present it's a bounded string.
    if (to_terminal != null && (typeof to_terminal !== 'string' || to_terminal.length > MAX_SLUG_LEN)) {
        errors.push(`to_terminal must be a string ≤ ${MAX_SLUG_LEN} chars or null`);
    }
    if (from != null && (typeof from !== 'string' || from.length > MAX_FROM_LEN)) {
        errors.push(`from must be a string ≤ ${MAX_FROM_LEN} chars`);
    }
    if (!ciphertext || typeof ciphertext !== 'string' || ciphertext.length > MAX_CIPHERTEXT_LEN) {
        errors.push(`ciphertext is required (base64 string, max ${MAX_CIPHERTEXT_LEN} chars)`);
    } else if (!isValidSealedBox(ciphertext)) {
        // Structural check ONLY: decodes to >= crypto_box_SEALBYTES (48). This
        // does NOT and cannot verify the content — the relay never decrypts.
        errors.push('ciphertext is not a valid sealed box (must be base64 ORIGINAL, ≥ 48 bytes)');
    }
    return errors;
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

/**
 * Bearer-token gate. Returns true if authorized (or auth is disabled because no
 * server token is configured); otherwise writes a 401 and returns false.
 */
function requireBearer(req, res) {
    const expected = process.env.FLEET_AUTH_TOKEN;
    if (!expected) return true;  // open posture when no server token configured
    const header = req.get ? req.get('authorization') : (req.headers && req.headers.authorization);
    const presented = (header || '').replace(/^Bearer\s+/i, '');
    if (presented && presented === expected) return true;
    res.status(401).json({ error: 'Unauthorized', code: 'missing_or_bad_bearer' });
    return false;
}

// ---------------------------------------------------------------------------
// Route registration
// ---------------------------------------------------------------------------

/**
 * Register all /api/msg* routes on the given Express app (or router).
 * @param {import('express').Application|import('express').Router} app
 */
function registerMsgRelayRoutes(app) {

    /**
     * POST /api/msg
     * Accept a SEALED envelope and store it keyed by destination machine.
     * Body: { id, to_team, to_terminal?, machine, from?, ciphertext, thread_id?, created_at? }
     * The relay stores opaque ciphertext and validates shape/length ONLY.
     * 201 on store; 400 on validation failure; 401 without valid bearer.
     */
    app.post('/api/msg', async (req, res) => {
        if (!requireBearer(req, res)) return;
        try {
            await ensureReady();  // isValidSealedBox needs sodium initialized

            const errors = validateEnvelope(req.body);
            if (errors.length > 0) {
                return res.status(400).json({ error: 'Validation failed', details: errors });
            }

            const { id, to_team, to_terminal, machine, from, ciphertext, thread_id, created_at } = req.body;

            const store = readStore();

            // Idempotent: same (machine, id) is a no-op re-post.
            const dup = store.messages.find(m => m.machine === machine && m.id === id);
            if (dup) {
                return res.status(200).json({ stored: true, duplicate: true, id });
            }

            const queued = store.messages.filter(m => m.machine === machine).length;
            if (queued >= MAX_QUEUE_PER_MACHINE) {
                return res.status(429).json({
                    error: `Relay queue for machine '${machine}' is full (${MAX_QUEUE_PER_MACHINE})`,
                    code:  'queue_full',
                });
            }

            store.messages.push({
                id,
                to_team,
                to_terminal: to_terminal != null ? to_terminal : null,
                machine,
                from: from || null,
                ciphertext,                       // OPAQUE — stored, never opened here
                thread_id: thread_id || null,
                created_at: created_at || new Date().toISOString(),
                stored_at:  new Date().toISOString(),
            });
            writeStore(store);

            console.log(`[MSG] Relayed sealed envelope for machine '${machine}' (to_team=${to_team})`);
            return res.status(201).json({ stored: true, id });
        } catch (error) {
            console.error('Error storing relay message:', error);
            return res.status(500).json({ error: 'Internal server error' });
        }
    });

    /**
     * GET /api/msg?machine=<slug>
     * Return undelivered sealed envelopes for the requesting machine. The relay
     * returns ciphertext ONLY — never plaintext (it holds no key). The client
     * decrypts locally and acks via POST /api/msg/ack.
     * 400 without machine; 401 without valid bearer.
     */
    app.get('/api/msg', (req, res) => {
        if (!requireBearer(req, res)) return;
        try {
            const { machine } = req.query;
            if (!machine || !SLUG_RE.test(String(machine))) {
                return res.status(400).json({ error: 'machine query parameter (slug) is required', code: 'missing_machine' });
            }
            const store = readStore();
            const messages = store.messages.filter(m => m.machine === machine);
            return res.json({ machine, messages, total: messages.length });
        } catch (error) {
            console.error('Error listing relay messages:', error);
            return res.status(500).json({ error: 'Internal server error' });
        }
    });

    /**
     * POST /api/msg/ack
     * Drop delivered envelopes after the client has opened them locally.
     * Body: { machine, ids: [ "<id>", ... ] }
     * 400 on bad body; 401 without valid bearer.
     */
    app.post('/api/msg/ack', (req, res) => {
        if (!requireBearer(req, res)) return;
        try {
            const { machine, ids } = req.body || {};
            if (!machine || !SLUG_RE.test(String(machine))) {
                return res.status(400).json({ error: 'machine (slug) is required', code: 'missing_machine' });
            }
            if (!Array.isArray(ids)) {
                return res.status(400).json({ error: 'ids must be an array', code: 'bad_ids' });
            }
            const idSet = new Set(ids);
            const store = readStore();
            const before = store.messages.length;
            store.messages = store.messages.filter(
                m => !(m.machine === machine && idSet.has(m.id))
            );
            const acked = before - store.messages.length;
            writeStore(store);
            return res.json({ acked });
        } catch (error) {
            console.error('Error acking relay messages:', error);
            return res.status(500).json({ error: 'Internal server error' });
        }
    });
}

module.exports = {
    registerMsgRelayRoutes,
    // exported for tests
    MSG_FILE,
    validateEnvelope,
    requireBearer,
    readStore,
    writeStore,
};
