//
//  notify-receipts.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Notification receipt log (XACA-1400-005, EPIC-0068 D5/D6).
 *
 * Append-only JSONL under the fleet_data volume (server/data/).
 *
 *  - Receipts NEVER contain destinations, params, secrets, title or body:
 *    newReceipt() strips every key outside the allowlist (defense in depth).
 *  - append() failures THROW an error naming the error type only; callers
 *    surface it. Never silent, never echoing the foreign message.
 *  - recent() tolerates a corrupt/truncated line anywhere in the file.
 *  - One-generation size rotation: file > maxBytes moves to "<file>.1".
 */

const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');

const DEFAULT_MAX_BYTES = 5 * 1024 * 1024;
const ALLOWED = ['id', 'ts', 'team', 'type', 'ref', 'severity', 'connectionId',
    'provider', 'ok', 'error', 'suppressed', 'providerMessageId', 'stage'];
const SUPPRESSED = ['dedupe', 'rate-limit', 'quiet-hours', 'severity-gate'];
// Async-delivery providers (imessage) write two receipts per send, same providerMessageId.
const STAGES = ['accepted', 'delivered', 'failed'];

function createReceiptLog(opts = {}) {
    const file = opts.file
        || process.env.FLEET_NOTIFY_RECEIPTS_FILE
        || path.join(__dirname, '..', 'data', 'notify-receipts.jsonl');
    const clock = opts.clock || (() => new Date());
    const maxBytes = Number.isFinite(opts.maxBytes) && opts.maxBytes > 0 ? opts.maxBytes : DEFAULT_MAX_BYTES;

    function newReceipt(fields = {}) {
        const r = {
            id: 'ntc-' + crypto.randomBytes(6).toString('hex'),
            ts: new Date(clock()).toISOString(),
        };
        for (const k of ALLOWED) {
            if (k === 'id' || k === 'ts') continue;
            if (fields[k] !== undefined) r[k] = fields[k];
        }
        r.ok = r.ok === true;
        r.error = r.ok ? '' : String(r.error == null ? '' : r.error);
        if (r.suppressed !== undefined && !SUPPRESSED.includes(r.suppressed)) delete r.suppressed;
        if (r.stage !== undefined && !STAGES.includes(r.stage)) delete r.stage;
        if (r.providerMessageId !== undefined && typeof r.providerMessageId !== 'string') delete r.providerMessageId;
        return r;
    }

    function rotateIfNeeded() {
        let size = 0;
        try { size = fs.statSync(file).size; } catch (_) { return; }
        if (size > maxBytes) fs.renameSync(file, file + '.1');
    }

    function endsWithoutNewline() {
        let fd;
        try {
            fd = fs.openSync(file, 'r');
            const size = fs.fstatSync(fd).size;
            if (size === 0) return false;
            const buf = Buffer.alloc(1);
            fs.readSync(fd, buf, 0, 1, size - 1);
            return buf[0] !== 0x0a;
        } catch (_) { return false; } finally {
            if (fd !== undefined) { try { fs.closeSync(fd); } catch (_) { /* ignore */ } }
        }
    }

    function append(receipt) {
        try {
            const clean = {};
            for (const k of ALLOWED) if (receipt && receipt[k] !== undefined) clean[k] = receipt[k];
            fs.mkdirSync(path.dirname(file), { recursive: true });
            rotateIfNeeded();
            // A torn last line (crash / ENOSPC mid-write) has no newline; start a fresh line
            // so the new receipt is not glued onto the fragment.
            const lead = endsWithoutNewline() ? '\n' : '';
            fs.appendFileSync(file, lead + JSON.stringify(clean) + '\n', { mode: 0o600 });
            return clean;
        } catch (err) {
            const type = (err && err.constructor && err.constructor.name) || 'Error';
            throw new Error(`notify receipt write failed (${type})`);
        }
    }

    function recent({ team, limit = 50 } = {}) {
        const out = [];
        // Live file first, then the previous generation, newest first: a rotation must not blank the view.
        for (const f of [file, file + '.1']) {
            if (out.length >= limit) break;
            let text;
            try { text = fs.readFileSync(f, 'utf8'); } catch (_) { continue; }
            const lines = text.split('\n');
            for (let i = lines.length - 1; i >= 0 && out.length < limit; i--) {
                if (!lines[i].trim()) continue;
                let rec;
                try { rec = JSON.parse(lines[i]); } catch (_) { continue; }
                if (!rec || typeof rec !== 'object' || Array.isArray(rec)) continue;
                if (team && rec.team !== team) continue;
                out.push(rec);
            }
        }
        return out;
    }

    return { file, newReceipt, append, recent };
}

module.exports = { createReceiptLog, ALLOWED_FIELDS: ALLOWED, SUPPRESSED_REASONS: SUPPRESSED, STAGES };
