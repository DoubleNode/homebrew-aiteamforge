//
//  tap-lock-github.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Native GitHub REST reader for the tap-writer lock (XACA-1622).
 *
 * Why: Fleet Monitor production runs on Fly.io from a build context that contains only
 * fleet-monitor/server (no git, no scripts/kb-tap-lock.sh), so the checker-backed watcher is a
 * silent no-op there. This module reads the same lock over HTTPS and returns the SAME result
 * shape the tracker already consumes from `kb-tap-lock.sh status --check`:
 *   {state: free|young|stale|unreadable, ref, lock_sha, holder, host, run_url, acquired_at,
 *    age, stale_after, break_cmd, reason}
 * Semantics deliberately mirror scripts/kb-tap-lock.sh (kb_tap_lock_check): the record is the
 * first message line starting with '{', fields are extracted with the same flat-JSON rule,
 * negative age within KB_TAP_LOCK_CHECK_SKEW is clamped to 0, beyond it is unreadable, stale is
 * age > stale_after, and ANYTHING not positively classifiable is unreadable (fail closed).
 * A parity test pins this against the real script.
 *
 * STRICTLY READ-ONLY: HTTP GET only. It never takes, frees or breaks the lock and never writes
 * to GitHub. break_cmd is display text for a human operator, nothing here executes it.
 *
 * Request budget: the anonymous GitHub limit is 60 req/h per IP. At the default 5 min poll
 * interval the uncached worst case is 2 requests/poll = 24 req/h; commits are immutable so the
 * message is cached by sha and a held lock costs 1 request/poll (12 req/h).
 *
 * The token (optional) travels only in the Authorization header and is scrubbed from every
 * reason string.
 */

const API_BASE = 'https://api.github.com';
const DEFAULT_OWNER = 'DoubleNode';
const DEFAULT_REPO = 'homebrew-aiteamforge';
const DEFAULT_REF = 'refs/locks/tap-writer';
const DEFAULT_STALE_AFTER_SEC = 3600;
const DEFAULT_SKEW_SEC = 300;
const DEFAULT_GITHUB_TIMEOUT_MS = 15 * 1000;
const CACHE_MAX = 32;
const SHA_RE = /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/i;

const defaultCache = new Map();   // "owner/repo@sha" -> commit message

/** Same cleaning as the checker's key=value emitter: drop control chars, redact user:tok@ URLs. */
function clean(v, max = 500) {
    // eslint-disable-next-line no-control-regex
    return String(v === undefined || v === null ? '' : v).replace(/[\u0000-\u001f\u007f]/g, '')
        .replace(/:\/\/[^/@ ]*@/g, '://***@').trim().slice(0, max);
}

function scrubToken(text, token) {
    let s = String(text);
    if (token) s = s.split(String(token)).join('***');
    return s;
}

/** Mirror of _kb_tap_lock_field: split on ',', first piece with "name": value, value = [^",}]*. */
function recordField(record, name) {
    const re = new RegExp(`.*"${name}"\\s*:\\s*"?([^",}]*)"?`);
    for (const piece of String(record).split(',')) {
        const m = piece.match(re);
        if (m) return m[1];
    }
    return '';
}

/** Mirror of the checker's record pick: first message line beginning with '{'. */
function findRecord(message) {
    for (const line of String(message).split('\n')) {
        if (line.startsWith('{')) return line;
    }
    return '';
}

function buildResult(state, ref, sha, record, age, reason, staleAfter) {
    const f = (name) => (record ? clean(recordField(record, name)) : '');
    return {
        state,
        ref,
        lock_sha: sha || '',
        holder: f('holder'),
        host: f('host'),
        run_url: f('run_url'),
        acquired_at: f('acquired_at'),
        age: age === null || age === undefined ? null : age,
        stale_after: staleAfter,
        break_cmd: sha ? `scripts/kb-tap-lock.sh break --force --expect ${sha}` : '',
        reason: reason || '',
    };
}

/** GET + parse. Resolves {error} (reason text) or {status, headers, text}; never rejects. */
async function httpGet(fetchImpl, url, headers, timeoutMs) {
    const ac = new AbortController();
    let timer;
    const timeout = new Promise((resolve) => {
        timer = setTimeout(() => { try { ac.abort(); } catch (_) { /* ignore */ } resolve({ error: `request timed out after ${Math.round(timeoutMs / 1000)}s` }); }, timeoutMs);
    });
    const request = (async () => {
        try {
            const res = await fetchImpl(url, { method: 'GET', headers, signal: ac.signal });
            const text = await res.text();
            return { status: res.status, headers: res.headers, text: String(text === undefined || text === null ? '' : text) };
        } catch (e) {
            return { error: `request failed (${clean(e && (e.name || e.code) || 'Error', 60)})` };
        }
    })();
    try {
        return await Promise.race([request, timeout]);
    } finally {
        clearTimeout(timer);
    }
}

function headerOf(headers, name) {
    try {
        return headers && typeof headers.get === 'function' ? headers.get(name) : null;
    } catch (_) { return null; }
}

/** Non-200 -> reason text. */
function statusReason(res) {
    const s = res.status;
    if (s === 403 || s === 429) {
        let r = `GitHub API rate limit or access denied (HTTP ${s})`;
        const reset = headerOf(res.headers, 'x-ratelimit-reset');
        if (reset) {
            const n = Number(reset);
            const iso = Number.isFinite(n) && n > 0 ? ` (${new Date(n * 1000).toISOString()})` : '';
            r += `; rate limit resets X-RateLimit-Reset=${clean(reset, 20)}${iso}`;
        }
        return r;
    }
    if (s === 404) return 'GitHub API HTTP 404 (repository not found or not visible without a token)';
    return `GitHub API HTTP ${s}`;
}

/**
 * @param {object} [o]
 * @param {Function} [o.fetchImpl]   fetch-compatible (default globalThis.fetch)
 * @param {string} [o.owner] @param {string} [o.repo] @param {string} [o.ref]
 * @param {string} [o.token]         optional; sent only as a Bearer header
 * @param {Function} [o.now]         () => epoch ms
 * @param {number} [o.staleAfterSec] default 3600
 * @param {number} [o.skewSec]       default 300
 * @param {number} [o.timeoutMs]     per request, default 15 s
 * @param {Map} [o.cache]            sha -> message cache (default: module-level)
 */
async function readTapLockViaGitHub(o = {}) {
    const owner = o.owner || DEFAULT_OWNER;
    const repo = o.repo || DEFAULT_REPO;
    const ref = o.ref || DEFAULT_REF;
    const token = o.token ? String(o.token) : '';
    const now = typeof o.now === 'function' ? o.now : Date.now;
    const staleAfter = Number.isFinite(o.staleAfterSec) && o.staleAfterSec > 0 ? Math.floor(o.staleAfterSec) : DEFAULT_STALE_AFTER_SEC;
    const skew = Number.isFinite(o.skewSec) && o.skewSec >= 0 ? Math.floor(o.skewSec) : DEFAULT_SKEW_SEC;
    const timeoutMs = Number.isFinite(o.timeoutMs) && o.timeoutMs > 0 ? o.timeoutMs : DEFAULT_GITHUB_TIMEOUT_MS;
    const cache = o.cache instanceof Map ? o.cache : defaultCache;
    const fetchImpl = typeof o.fetchImpl === 'function' ? o.fetchImpl : globalThis.fetch;

    const unreadable = (sha, record, reason) =>
        buildResult('unreadable', ref, sha, record, null, scrubToken(reason, token), staleAfter);

    if (typeof fetchImpl !== 'function') return unreadable('', '', 'no fetch implementation available');

    try {
        const headers = {
            Accept: 'application/vnd.github+json',
            'User-Agent': 'fleet-monitor-tap-lock-watcher',
            'X-GitHub-Api-Version': '2022-11-28',
        };
        if (token) headers.Authorization = `Bearer ${token}`;
        const seg = encodeURIComponent;
        const base = `${API_BASE}/repos/${seg(owner)}/${seg(repo)}/git`;

        // 1. which commit (if any) does the lock ref point at? matching-refs is a PREFIX match.
        const prefix = ref.replace(/^refs\//, '').split('/').map(seg).join('/');
        const listed = await httpGet(fetchImpl, `${base}/matching-refs/${prefix}`, headers, timeoutMs);
        if (listed.error) return unreadable('', '', listed.error);
        if (listed.status !== 200) return unreadable('', '', statusReason(listed));
        let arr;
        try { arr = JSON.parse(listed.text); } catch (_) { return unreadable('', '', 'matching-refs response was not valid JSON'); }
        if (!Array.isArray(arr)) return unreadable('', '', 'matching-refs response was not an array');
        const hit = arr.find((e) => e && typeof e === 'object' && e.ref === ref);
        if (!hit) return buildResult('free', ref, '', '', null, '', staleAfter);
        const obj = hit.object;
        const sha = obj && typeof obj.sha === 'string' ? obj.sha : '';
        if (!SHA_RE.test(sha)) return unreadable('', '', 'lock ref object had no valid sha');
        if (obj.type !== 'commit') return unreadable(sha, '', `lock ref points at a ${clean(obj.type, 20) || 'unknown'} object, not a commit`);

        // 2. the commit message carries the holder record. Commits are immutable: cache by sha.
        const key = `${owner}/${repo}@${sha}`;
        let message = cache.get(key);
        if (typeof message !== 'string') {
            const got = await httpGet(fetchImpl, `${base}/commits/${sha}`, headers, timeoutMs);
            if (got.error) return unreadable(sha, '', got.error);
            if (got.status !== 200) return unreadable(sha, '', statusReason(got));
            let c;
            try { c = JSON.parse(got.text); } catch (_) { return unreadable(sha, '', 'commit response was not valid JSON'); }
            if (!c || typeof c !== 'object' || typeof c.message !== 'string') return unreadable(sha, '', 'commit response had no message');
            message = c.message;
            if (cache.size >= CACHE_MAX) cache.delete(cache.keys().next().value);
            cache.set(key, message);
        }

        // 3. classify exactly like kb_tap_lock_check.
        const record = findRecord(message);
        if (!record) return unreadable(sha, '', 'lock record unreadable');
        const acq = recordField(record, 'acquired_epoch');
        if (!/^[0-9]+$/.test(acq)) return unreadable(sha, record, 'age unknown');
        let age = Math.floor(now() / 1000) - Number(acq);
        if (!Number.isFinite(age)) return unreadable(sha, record, 'age unknown');
        if (age < 0) {
            if (-age > skew) return unreadable(sha, record, 'age negative beyond clock-skew tolerance');
            age = 0;
        }
        return buildResult(age > staleAfter ? 'stale' : 'young', ref, sha, record, age, '', staleAfter);
    } catch (e) {
        return unreadable('', '', `unexpected error (${clean(e && e.name || 'Error', 60)})`);
    }
}

module.exports = {
    readTapLockViaGitHub, recordField, findRecord,
    DEFAULT_OWNER, DEFAULT_REPO, DEFAULT_REF, DEFAULT_STALE_AFTER_SEC, DEFAULT_SKEW_SEC, DEFAULT_GITHUB_TIMEOUT_MS,
};
