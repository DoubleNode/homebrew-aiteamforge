//
//  ci-dispatch-audit.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Append-only audit log for the CI dispatcher (XACA-1441-006, plan D8, Requirement 11).
 * File: data/ci-dispatch-audit.jsonl, one JSON object per line.
 *
 * Secrets can never land here, by two independent layers:
 *   1. FIELD ALLOWLIST per event type: any key not listed is dropped, so a JIT config,
 *      token or private key passed by a careless caller is never even considered.
 *   2. VALUE SCAN: any string value that looks secret-shaped (JWT, GitHub token prefixes,
 *      PEM header, base64 run >= 200 chars) is replaced wholesale with "[redacted]".
 *      Non-scalar values (objects/arrays) are dropped, so nothing can hide inside one.
 *
 * Atomicity: each event is ONE appendFileSync of "<json>\n" (O_APPEND), so concurrent
 * writers cannot interleave inside a line. No fsync (cheap; a crash may lose the last line).
 *
 * Rotation: when the live file plus the next line would exceed maxBytes, rename
 * .jsonl -> .jsonl.1 -> .jsonl.2 ...; `keep` is the number of ROTATED generations retained
 * (the oldest is deleted), in addition to the live file.
 *
 * I/O failures never throw into the dispatcher: append() returns null and lastError holds
 * the cause. Callers that must not proceed unaudited can check the return value.
 */

const realFs = require('fs');
const nodePath = require('path');

const DEFAULT_MAX_BYTES = 5 * 1024 * 1024;
const DEFAULT_KEEP = 3;
const MAX_VALUE_LEN = 512;
const MAX_LINE_BYTES = 8 * 1024;

const BASE_FIELDS = ['id', 'repo', 'jobId', 'runAttempt', 'runnerName', 'runnerId', 'machine', 'state', 'reason'];

// Per event type. Unknown events fall back to BASE_FIELDS. `ts` and `event` are always set by us.
const EVENT_FIELDS = {
  'assign':     BASE_FIELDS.concat(['runId', 'jobName', 'labelSet']),
  'state':      BASE_FIELDS.concat(['from', 'to']),
  'reject':     BASE_FIELDS.concat(['runId', 'jobName', 'runEvent']),
  'expire':     BASE_FIELDS,
  'deregister': BASE_FIELDS.concat(['ok', 'httpStatus']),
  'alert':      BASE_FIELDS.concat(['jobClass', 'waitedMs']),
  'pause':      BASE_FIELDS.concat(['paused', 'by'])
};

const SECRET_PATTERNS = [
  /eyJ[A-Za-z0-9_-]{8,}/,                       // JWT: base64url of {"
  /eyIu[A-Za-z0-9+/_-]{8,}/,                    // JIT config: base64 of {".runner":… (never eyJ; XACA-1441-020)
  /\bgh[pousr]_[A-Za-z0-9]{8,}/,                 // ghp_ gho_ ghu_ ghs_ ghr_
  /github_pat_[A-Za-z0-9_]{8,}/,
  /-----BEGIN [A-Z ]*-----/,                     // PEM
  /[A-Za-z0-9+/_-]{200,}={0,2}/                  // long base64 / base64url run
];

function looksSecret(s) {
  for (const re of SECRET_PATTERNS) if (re.test(s)) return true;
  return false;
}

/** Scalar-only, secret-scanned, length-capped. Returns undefined to drop. */
function cleanValue(v) {
  if (typeof v === 'number') return Number.isFinite(v) ? v : undefined;
  if (typeof v === 'boolean' || v === null) return v;
  if (typeof v !== 'string') return undefined;
  if (looksSecret(v)) return '[redacted]';
  return v.length > MAX_VALUE_LEN ? v.slice(0, MAX_VALUE_LEN) : v;
}

function sanitize(event, fields, ts) {
  const name = (typeof event === 'string' && /^[a-z][a-z0-9:._-]{0,63}$/.test(event)) ? event : 'invalid-event';
  const allowed = EVENT_FIELDS[name] || BASE_FIELDS;
  const out = { ts: ts, event: name };
  const src = (fields && typeof fields === 'object') ? fields : {};
  for (const k of allowed) {
    if (!Object.prototype.hasOwnProperty.call(src, k)) continue;
    const c = cleanValue(src[k]);
    if (c !== undefined) out[k] = c;
  }
  return out;
}

function createAudit(opts) {
  const o = opts || {};
  if (typeof o.path !== 'string' || !o.path) throw new Error('createAudit: path required');
  const fs = o.fs || realFs;
  const file = o.path;
  const maxBytes = Number.isFinite(o.maxBytes) && o.maxBytes > 0 ? o.maxBytes : DEFAULT_MAX_BYTES;
  const keep = Number.isInteger(o.keep) && o.keep >= 0 ? o.keep : DEFAULT_KEEP;
  const now = typeof o.now === 'function' ? o.now : function () { return new Date(); };
  const state = { lastError: null };

  function sizeOf(p) {
    try { return fs.statSync(p).size; } catch (_) { return 0; }
  }

  function rotate() {
    if (keep === 0) { try { fs.unlinkSync(file); } catch (_) { /* absent */ } return; }
    try { fs.unlinkSync(file + '.' + keep); } catch (_) { /* absent */ }
    for (let i = keep - 1; i >= 1; i--) {
      try { fs.renameSync(file + '.' + i, file + '.' + (i + 1)); } catch (_) { /* gap is fine */ }
    }
    fs.renameSync(file, file + '.1');
  }

  function append(event, fields) {
    try {
      const t = now();
      const ts = (t instanceof Date ? t : new Date(t)).toISOString();
      let line = JSON.stringify(sanitize(event, fields, ts));
      if (Buffer.byteLength(line) > MAX_LINE_BYTES) {
        line = JSON.stringify({ ts: ts, event: 'oversize-dropped' });
      }
      line += '\n';
      fs.mkdirSync(nodePath.dirname(file), { recursive: true });
      const cur = sizeOf(file);
      if (cur > 0 && cur + Buffer.byteLength(line) > maxBytes) rotate();
      fs.appendFileSync(file, line, { mode: 0o600 });
      return JSON.parse(line);
    } catch (e) {
      state.lastError = e;
      return null;
    }
  }

  function readLines(p) {
    let raw;
    try { raw = fs.readFileSync(p, 'utf8'); } catch (_) { return []; }
    return raw.split('\n').filter(Boolean);
  }

  /** Last n events, oldest first. Spans rotated generations; unparsable lines are skipped. */
  function tail(n) {
    const want = Number.isInteger(n) && n > 0 ? n : 100;
    const out = [];
    const files = [file];
    for (let i = 1; i <= keep; i++) files.push(file + '.' + i);
    for (const p of files) {
      const lines = readLines(p);
      for (let i = lines.length - 1; i >= 0 && out.length < want; i--) {
        try { out.unshift(JSON.parse(lines[i])); } catch (_) { /* torn line */ }
      }
      if (out.length >= want) break;
    }
    return out;
  }

  return {
    append: append,
    tail: tail,
    get lastError() { return state.lastError; },
    path: file
  };
}

module.exports = {
  createAudit: createAudit,
  sanitize: sanitize,
  looksSecret: looksSecret,
  EVENT_FIELDS: EVENT_FIELDS,
  DEFAULT_MAX_BYTES: DEFAULT_MAX_BYTES,
  DEFAULT_KEEP: DEFAULT_KEEP
};
