//
//  msg-client.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * msg-client.js — Tier-2 (cross-machine) sealed transport for kb-msg (XACA-0777).
 *
 * CLIENT SIDE ONLY. Two subcommands:
 *
 *   send  — Seal a message record to the RECIPIENT MACHINE's X25519 public key
 *           (libsodium crypto_box_seal) and POST the opaque ciphertext to the
 *           fleet-monitor /api/msg relay. The relay stores bytes it cannot read.
 *
 *   pull  — GET undelivered sealed envelopes addressed to THIS machine, open
 *           each with this machine's private key (crypto_box_seal_open), emit
 *           the decrypted record(s) as JSONL on stdout (for msg-store ingest),
 *           and ack the successfully-opened ids so the relay can drop them.
 *
 * PRIVACY: the relay never sees plaintext — only the recipient machine's private
 * key (which never leaves that machine) can open a sealed envelope. Nothing here
 * ever touches AMB (dev.agentbadges.com).
 *
 * Crypto is done client-side with libsodium directly (same approach as
 * vault-fetch.js): the public key is DERIVED from the stored private key via
 * crypto_scalarmult_base, so we never need the server to hand us our own pubkey.
 *
 * Bearer auth: if a token is configured (env FLEET_AUTH_TOKEN or fleet-config
 * .centralServer.authToken), it is sent as `Authorization: Bearer <token>` on
 * every relay call. Auth gates who may RELAY; sealing gates who may READ.
 */

const fs   = require('fs');

// Reuse slug + private-key storage helpers from vault-keygen.js (same dir).
const kg = require('./vault-keygen.js');


// ── libsodium lazy handle (same pattern as vault-fetch.js / vault-keygen.js) ──
let _sodium = null;
async function ensureSodium() {
    if (_sodium && _sodium.ready === undefined) return _sodium;
    const sodium = require('libsodium-wrappers');
    await sodium.ready;
    _sodium = sodium;
    return sodium;
}

// ── Config resolution ────────────────────────────────────────────────────────

/**
 * Locate the fleet-config.json used by the reporters (for auth token).
 * Delegates to vault-keygen.js so there is exactly ONE definition of where
 * these files live - this used to be a hand-copied duplicate that could drift
 * from the shared one (XACA-0972-015/016).
 */
function fleetConfigPath() {
    return kg.fleetConfigPath();
}

/** Resolve the relay bearer token: env override, else fleet-config. '' if none. */
function resolveAuthToken() {
    if (process.env.FLEET_AUTH_TOKEN) return process.env.FLEET_AUTH_TOKEN;
    try {
        const cfg = JSON.parse(fs.readFileSync(fleetConfigPath(), 'utf8'));
        return (cfg.centralServer && cfg.centralServer.authToken) || '';
    } catch (_) {
        return '';
    }
}

/** Build fetch headers, adding Bearer auth only when a token is configured. */
function authHeaders(extra) {
    const h = Object.assign({ 'Content-Type': 'application/json' }, extra || {});
    const tok = resolveAuthToken();
    if (tok) h['Authorization'] = `Bearer ${tok}`;
    return h;
}

// ── Crypto helpers ───────────────────────────────────────────────────────────

/** Seal plaintext to a recipient's base64 public key. Returns base64 ciphertext. */
async function seal(plaintext, recipientPubKeyB64) {
    const sodium = await ensureSodium();
    const v = sodium.base64_variants.ORIGINAL;
    const msg = sodium.from_string(plaintext);
    const pk  = sodium.from_base64(recipientPubKeyB64, v);
    const box = sodium.crypto_box_seal(msg, pk);
    return sodium.to_base64(box, v);
}

/** Open a sealed box with this machine's stored private key. Returns plaintext,
 *  or null if it cannot be opened (wrong/rotated key, tampered, not for us). */
async function sealOpenLocal(sealedB64, machineSlug) {
    const sodium = await ensureSodium();
    const v  = sodium.base64_variants.ORIGINAL;
    const skB64 = kg.readPrivateKey(machineSlug);
    const sk = sodium.from_base64(skB64, v);
    const pk = sodium.crypto_scalarmult_base(sk);
    const sealed = sodium.from_base64(sealedB64, v);
    let opened;
    try {
        opened = sodium.crypto_box_seal_open(sealed, pk, sk);
    } catch (_) {
        return null;
    }
    if (opened === false || opened == null) return null;
    return sodium.to_string(opened);
}

// ── Relay HTTP ───────────────────────────────────────────────────────────────

/**
 * Resolve the relay base URL. XACA-0972-015.
 *
 * An explicit --server (opts.server) ALWAYS wins - that precedence is
 * load-bearing, because _kb_msg_relay_url in kanban-helpers.sh already resolves
 * the URL shell-side and passes it in on every call. The shared resolver is the
 * defense-in-depth default underneath it, for any call site that forgets.
 *
 * There is no localhost fallback. This module used to carry
 * `process.env.FLEET_MONITOR_URL || 'http://localhost:3000'` in a
 * module-level constant, which was wrong twice over: nothing listens on :3000
 * on a fleet machine, so "not configured" surfaced as "fetch failed"; and being
 * module-level, it read the environment once at REQUIRE time and could never be
 * exercised per-test. Resolve lazily, here, at use time.
 *
 * @param {{ server?: string }} opts
 * @returns {string} base URL with no trailing slash
 * @throws {Error} with .code = 'FLEET_URL_UNRESOLVED' when nothing resolves,
 *                 carrying the one canonical actionable message.
 */
function serverBase(opts) {
    const explicit = opts && opts.server;
    if (explicit) return explicit.replace(/\/+$/, '');

    const resolved = kg.resolveFleetUrl();
    if (!resolved) {
        const err = new Error(kg.unresolvedFleetUrlMessage('msg-client'));
        err.code = 'FLEET_URL_UNRESOLVED';
        throw err;
    }
    return resolved.replace(/\/+$/, '');
}

/** Fetch a registered machine's public key from the vault machine registry. */
async function fetchMachinePubKey(base, machineSlug) {
    const res = await fetch(`${base}/api/vault/machines`, { headers: authHeaders() });
    if (!res.ok) {
        throw new Error(`vault machine registry returned HTTP ${res.status}`);
    }
    const body = await res.json();
    const machines = (body && body.machines) || [];
    const m = machines.find(x => x.id === machineSlug);
    if (!m) {
        throw new Error(`machine '${machineSlug}' is not registered in the vault (run vault-keygen on it)`);
    }
    return m.public_key;
}

// ── Subcommands ──────────────────────────────────────────────────────────────

async function cmdSend(opts) {
    if (!opts.to || !opts.machine || !opts.body || !opts.fromTeam || !opts.fromTerminal) {
        throw new Error('send requires --to, --machine, --from-team, --from-terminal, --body');
    }
    const base = serverBase(opts);

    // Parse the address into to_team / to_terminal (null => broadcast).
    let toTeam, toTerminal;
    if (opts.to.includes(':')) {
        [toTeam, toTerminal] = opts.to.split(/:(.*)/s);
        if (toTerminal === '' || toTerminal === '*') toTerminal = null;
    } else {
        toTeam = opts.to; toTerminal = null;
    }

    const nowIso = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
    const record = {
        id:            opts.id || cryptoRandomHex(),
        from_team:     opts.fromTeam,
        from_terminal: opts.fromTerminal,
        to_team:       toTeam,
        to_terminal:   toTerminal,
        to:            toTerminal ? `${toTeam}:${toTerminal}` : toTeam,
        body:          opts.body,
        thread_id:     opts.thread || cryptoRandomHex(),
        origin:        'relay',
        created_at:    nowIso,
        read_at:       null,
        acked:         false,
    };

    const pubKey    = await fetchMachinePubKey(base, opts.machine);
    const ciphertext = await seal(JSON.stringify(record), pubKey);

    const envelope = {
        id:          record.id,
        to_team:     toTeam,
        to_terminal: toTerminal,
        machine:     opts.machine,
        from:        `${opts.fromTeam}:${opts.fromTerminal}`,
        ciphertext,
        thread_id:   record.thread_id,
        created_at:  record.created_at,
    };

    const res = await fetch(`${base}/api/msg`, {
        method:  'POST',
        headers: authHeaders(),
        body:    JSON.stringify(envelope),
    });
    let body = null;
    try { body = await res.json(); } catch (_) { /* non-JSON */ }
    if (res.status >= 200 && res.status < 300) {
        process.stdout.write(`✓ Sealed + relayed to ${opts.to} (machine ${opts.machine}). ` +
            `Recipient pulls it on its next reporter cycle (~30-60s).\n`);
        return 0;
    }
    process.stderr.write(`Relay POST failed: HTTP ${res.status} ${JSON.stringify(body || {})}\n`);
    return 1;
}

async function cmdPull(opts) {
    const base = serverBase(opts);
    const slug = opts.machine || kg.defaultMachineSlug();

    const res = await fetch(`${base}/api/msg?machine=${encodeURIComponent(slug)}`, {
        headers: authHeaders(),
    });
    if (!res.ok) {
        process.stderr.write(`Relay pull failed: HTTP ${res.status}\n`);
        return 4;
    }
    const body = await res.json();
    const envelopes = (body && body.messages) || [];
    if (envelopes.length === 0) return 0;

    const openedIds = [];
    const out = [];
    for (const env of envelopes) {
        const plaintext = await sealOpenLocal(env.ciphertext, slug);
        if (plaintext == null) {
            // Cannot open (not for us / rotated key) — leave on relay, do not ack.
            process.stderr.write(`msg-client: could not open envelope ${env.id} (skipped)\n`);
            continue;
        }
        out.push(plaintext);            // decrypted record JSON — one per line
        openedIds.push(env.id);
    }

    // Emit decrypted records as JSONL for msg-store ingest.
    if (out.length) process.stdout.write(out.join('\n') + '\n');

    // Ack the ones we successfully opened so the relay can drop them.
    if (openedIds.length) {
        try {
            await fetch(`${base}/api/msg/ack`, {
                method:  'POST',
                headers: authHeaders(),
                body:    JSON.stringify({ machine: slug, ids: openedIds }),
            });
        } catch (_) { /* best-effort; will re-pull + re-ingest is idempotent */ }
    }
    return 0;
}

// ── Utilities ────────────────────────────────────────────────────────────────

function cryptoRandomHex() {
    return require('crypto').randomBytes(16).toString('hex');
}

function parseArgs(argv) {
    const opts = {};
    const sub = argv[0];
    for (let i = 1; i < argv.length; i++) {
        const a = argv[i];
        switch (a) {
            case '--to':            opts.to = argv[++i]; break;
            case '--machine':       opts.machine = argv[++i]; break;
            case '--from-team':     opts.fromTeam = argv[++i]; break;
            case '--from-terminal': opts.fromTerminal = argv[++i]; break;
            case '--body':          opts.body = argv[++i]; break;
            case '--thread':        opts.thread = argv[++i]; break;
            case '--id':            opts.id = argv[++i]; break;
            case '--server':        opts.server = argv[++i]; break;
            case '-h': case '--help': opts.help = true; break;
            default:
                throw new Error(`Unknown argument: ${a}`);
        }
    }
    return { sub, opts };
}

const HELP = `msg-client — Tier-2 sealed cross-machine transport for kb-msg.

Usage:
  node msg-client.js send  --to <team[:terminal]> --machine <slug>
                           --from-team <t> --from-terminal <t> --body <text>
                           [--thread <id>] [--server <url>]
  node msg-client.js pull  [--machine <slug>] [--server <url>]

send  seals the message to <machine>'s registered public key and POSTs the
      opaque ciphertext to the fleet-monitor /api/msg relay.
pull  fetches sealed envelopes for this machine, opens them locally, prints the
      decrypted records as JSONL (pipe into: msg-store.py ingest), and acks them.

The relay never decrypts. Nothing transits AMB.`;

async function main(argv) {
    let parsed;
    try {
        parsed = parseArgs(argv);
    } catch (err) {
        process.stderr.write(err.message + '\n\n' + HELP + '\n');
        return 2;
    }
    if (parsed.opts.help || !parsed.sub) {
        process.stdout.write(HELP + '\n');
        return parsed.sub ? 0 : 2;
    }
    try {
        if (parsed.sub === 'send') return await cmdSend(parsed.opts);
        if (parsed.sub === 'pull') return await cmdPull(parsed.opts);
        process.stderr.write(`Unknown subcommand: ${parsed.sub}\n\n${HELP}\n`);
        return 2;
    } catch (err) {
        process.stderr.write('Error: ' + err.message + '\n');
        return 1;
    }
}

if (require.main === module) {
    main(process.argv.slice(2)).then((code) => process.exit(code));
}

module.exports = {
    seal,
    sealOpenLocal,
    fetchMachinePubKey,
    resolveAuthToken,
    authHeaders,
    parseArgs,
    cmdSend,
    cmdPull,
    main,
};
