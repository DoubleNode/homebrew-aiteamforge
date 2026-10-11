//
//  ci-fallback-reader.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

// XACA-1465-002: reads the CI routing repo variables (CI_LINUX_RUNNER, ...) through the GitHub App
// client and keeps an in-memory, per-switch state that GET /api/ci-runners serves as `fallback`.
//
// Invariants (plan Requirements 2, 3, 9):
//   * armed === true ONLY for a JSON array of strings that includes exactly "self-hosted".
//     Anything else is null (UNKNOWN): invalid JSON / whitespace-only break fromJSON() in the workflow;
//     values that parse but are not an array with self-hosted (e.g. "ubuntu-latest") are UNKNOWN as a
//     conservative choice -- the dashboard cannot tell which hosted image, or whether the workflow tolerates it.
//   * "self-hosted" is matched case-insensitively (GitHub runner labels are).
//   * XACA-1465-017: the workflows CHAIN switches (`vars.HEAVY || vars.LINUX || 'ubuntu-latest'`). A switch
//     with `fallsBackTo` whose own value is unset/empty resolves through the link (resolveChain).
//   * A transient failure keeps the last good value AND its original checkedAt, so the UI's STALE
//     marker shows the age. A never-read switch stays armed:null / checkedAt:null.
//   * Reads are timer-driven, never per request. refreshNow() is throttled + coalesced so viewers
//     cannot drive GitHub API spend (the rate budget is shared with the dispatcher).
//   * Never throws, never logs tokens, never echoes a raw variable value.

// 5 min: routing variables change on operator action (rarely); conditional GETs answering 304 are
// cheap but the rate budget is shared with the dispatcher, so polling faster buys nothing. A
// successful 304 bumps checkedAt (so the UI's STALE marker only appears when reads FAIL), and the
// REFRESH pill (min interval below) covers "I just changed it".
const DEFAULT_INTERVAL_MS = 5 * 60 * 1000;
const DEFAULT_MIN_REFRESH_MS = 30 * 1000;
const MAX_LABELS = 10;
const MAX_LABEL_LEN = 64;
const MAX_VALUE_LEN = 200;

const REASON = Object.freeze({
    NOT_JSON: 'value is not valid JSON',
    NOT_ARRAY: 'value is not a JSON array',
    BLANK: 'value is blank (breaks fromJSON)',
    NOT_STRINGS: 'array contains non-string entries',
    NO_SELF_HOSTED: 'array does not include self-hosted',
    NOT_READ: 'not read yet',
    NOT_CONFIGURED: 'GitHub App credentials not configured',
    KEY_INVALID: 'GitHub App key rejected',
    UNREACHABLE: 'GitHub unreachable',
    RATE_LIMITED: 'GitHub rate limit reached',
    BAD_RESPONSE: 'GitHub returned a malformed response',
    BAD_SWITCH: 'switch definition is invalid',
    NOT_SUPPORTED: 'unexpected variable result',
});

/**
 * Pure. `res` is a getRepoVariable() result ({found:false} | {found:true,value}) or a bare string value.
 * @returns {{armed:true, labels:string[]} | {armed:false, reason:null} | {armed:null, reason:string}}
 */
function classifySwitchValue(res) {
    let value;
    if (typeof res === 'string') value = res;
    else if (res && typeof res === 'object' && res.found === false) return { armed: false, reason: null, absent: true };
    else if (res && typeof res === 'object' && res.found === true && typeof res.value === 'string') value = res.value;
    else return { armed: null, reason: REASON.NOT_SUPPORTED };

    if (value === '') return { armed: false, reason: null, absent: true };   // falsy in Actions `||`: the next link takes over
    if (value.trim() === '') return { armed: null, reason: REASON.BLANK };    // truthy in `||`, so fromJSON(' ') fails
    let parsed;
    try { parsed = JSON.parse(value); } catch (_) { return { armed: null, reason: REASON.NOT_JSON }; }
    if (!Array.isArray(parsed)) return { armed: null, reason: REASON.NOT_ARRAY };
    if (!parsed.every((e) => typeof e === 'string')) return { armed: null, reason: REASON.NOT_STRINGS };
    if (!parsed.some((e) => e.toLowerCase() === 'self-hosted')) return { armed: null, reason: REASON.NO_SELF_HOSTED };
    return {
        armed: true,
        labels: parsed.slice(0, MAX_LABELS).map((s) => s.slice(0, MAX_LABEL_LEN).replace(/[\u0000-\u001f\u007f]/g, '')),
    };
}

/** Fixed human-readable reason for a thrown client error. Never includes err.message. */
function describeError(err, owner) {
    const code = err && err.code;
    const status = err && Number.isInteger(err.status) ? err.status : null;
    if (code === 'NOT_INSTALLED') return typeof owner === 'string' && owner ? `GitHub App not installed for ${owner}` : 'GitHub App not installed';
    if (code === 'NOT_CONFIGURED') return REASON.NOT_CONFIGURED;
    if (code === 'KEY_INVALID') return REASON.KEY_INVALID;
    if (code === 'RATE_LIMITED') return REASON.RATE_LIMITED;
    if (code === 'BAD_RESPONSE') return REASON.BAD_RESPONSE;
    if (code === 'BAD_REPO' || code === 'BAD_ARGS') return REASON.BAD_SWITCH;
    if (status === 403 || status === 401 || status === 422) {
        return `GitHub returned HTTP ${status} (App may lack Variables: read)`;
    }
    if (status !== null && status >= 100 && status <= 599) return `GitHub returned HTTP ${status}`;
    return REASON.UNREACHABLE;
}

/** Runner-label JSON that always parses: drops trailing labels (never cuts mid-string) to fit MAX_VALUE_LEN. */
function fitLabels(labels) {
    let l = labels.slice();
    while (l.length > 1 && JSON.stringify(l).length > MAX_VALUE_LEN) l.pop();
    const out = JSON.stringify(l);
    return out.length <= MAX_VALUE_LEN ? out : JSON.stringify(l.map((x) => x.slice(0, 40)).slice(0, 1));
}

/**
 * Pure. rows: [{sw, st}]; st = {armed, reason, labels, error, checkedAt, absent}. Returns Map(row -> resolved)
 * of {armed, reason, labels, error, checkedAt}. A switch whose own value is absent/empty and that declares
 * fallsBackTo takes its state from the link; the chain ends at the workflow's literal (HOSTED).
 * Missing link / cycle / unknown link => UNKNOWN (fail safe).
 */
function resolveChain(rows) {
    const byKey = new Map(rows.map((r) => [switchKey(r.sw), r]));
    const memo = new Map();
    const older = (a, b) => (a === null || b === null ? null : (a < b ? a : b));
    function resolve(row, trail) {
        if (memo.has(row)) return memo.get(row);
        const { sw, st } = row;
        let out = { armed: st.armed, reason: st.reason, labels: st.labels, error: st.error, checkedAt: st.checkedAt };
        if (st.armed !== null && st.absent === true && typeof sw.fallsBackTo === 'string') {
            const k = `${sw.owner}/${sw.repo}/${sw.fallsBackTo}`.toLowerCase();
            const link = byKey.get(k);
            if (!link || trail.has(k)) {
                out = { armed: null, reason: `follows ${sw.fallsBackTo}, which is not configured`, labels: undefined, error: st.error, checkedAt: st.checkedAt };
            } else {
                const t = new Set(trail);
                t.add(k);
                const l = resolve(link, t);
                out = l.armed === null
                    ? { armed: null, reason: `follows ${sw.fallsBackTo}: ${l.reason || REASON.NOT_READ}`, labels: undefined, error: st.error || l.error, checkedAt: older(st.checkedAt, l.checkedAt) }
                    : { armed: l.armed, reason: `unset: follows ${sw.fallsBackTo}`, labels: l.armed === true ? l.labels : undefined, error: st.error || l.error, checkedAt: older(st.checkedAt, l.checkedAt) };
            }
        }
        memo.set(row, out);
        return out;
    }
    const res = new Map();
    for (const r of rows) res.set(r, resolve(r, new Set([switchKey(r.sw)])));
    return res;
}

const switchKey = (s) => `${s.owner}/${s.repo}/${s.variable}`.toLowerCase();

function createFallbackReader(opts = {}) {
    const { github, store } = opts;
    const now = typeof opts.now === 'function' ? opts.now : () => Date.now();
    const logger = opts.logger || null;
    const intervalMs = Number.isFinite(opts.intervalMs) && opts.intervalMs > 0 ? opts.intervalMs : DEFAULT_INTERVAL_MS;
    const minRefreshMs = Number.isFinite(opts.minRefreshIntervalMs) && opts.minRefreshIntervalMs >= 0
        ? opts.minRefreshIntervalMs : DEFAULT_MIN_REFRESH_MS;
    const setTimer = typeof opts.setTimer === 'function' ? opts.setTimer : (fn, ms) => setTimeout(fn, ms);
    const clearTimer = typeof opts.clearTimer === 'function' ? opts.clearTimer : (h) => clearTimeout(h);

    const states = new Map();      // lowercased owner/repo/variable -> state
    let timer = null;
    let running = false;           // start() called
    let inflight = null;           // Promise of the read in progress
    let rereadQueued = false;      // list changed mid-read
    let lastStartedAt = null;      // ms, when the last read STARTED

    const iso = () => new Date(now()).toISOString();
    const log = (level, msg) => {
        try { if (logger && typeof logger[level] === 'function') logger[level](msg); } catch (_) { /* logging never breaks a read */ }
    };

    function currentList() {
        try {
            const l = store && typeof store.getFallbackSwitches === 'function' ? store.getFallbackSwitches() : [];
            return Array.isArray(l) ? l : [];
        } catch (_) { return []; }
    }

    function freshState(sw) {
        return {
            owner: sw.owner, repo: sw.repo, variable: sw.variable, label: sw.label, fallsBackTo: sw.fallsBackTo,
            absent: false, armed: null, reason: REASON.NOT_READ, labels: undefined, checkedAt: null, etag: null, error: null, loggedError: null,
        };
    }

    /** Align states with the store list: drop removed, add new (never-read), refresh labels. */
    function sync(list) {
        const keep = new Set();
        for (const sw of list) {
            const k = switchKey(sw);
            keep.add(k);
            const st = states.get(k);
            if (!st) states.set(k, freshState(sw));
            else { st.label = sw.label; st.fallsBackTo = sw.fallsBackTo; }
        }
        for (const k of Array.from(states.keys())) if (!keep.has(k)) states.delete(k);
    }

    async function readOne(st) {
        try {
            const res = await github.getRepoVariable(st.owner, st.repo, st.variable, { etag: st.etag || undefined });
            if (res && res.notModified) {
                // A 304 only confirms a value we hold an etag for. Without one (never read, or the last
                // answer was a 404 / carried no etag) it is nonsensical: it must not stamp a check time.
                if (st.etag === null || st.checkedAt === null) throw Object.assign(new Error('unexpected 304'), { code: 'BAD_RESPONSE' });
                st.checkedAt = iso();      // confirmed still current
                st.error = null;
                st.loggedError = null;
                return;
            }
            const c = classifySwitchValue(res);
            st.armed = c.armed;
            st.absent = c.absent === true;
            st.reason = c.armed === null ? c.reason : null;
            st.labels = c.armed === true ? c.labels : undefined;
            st.etag = res && res.found === true && typeof res.etag === 'string' ? res.etag : null;
            st.checkedAt = iso();
            st.error = null;
            st.loggedError = null;
        } catch (err) {
            const why = describeError(err, st.owner);
            st.error = why;
            if (st.checkedAt === null) st.reason = why;           // never read: the error IS the reason
            if (st.loggedError !== why) {                          // once per state change, not per tick
                st.loggedError = why;
                log('warn', `[ci-fallback] ${st.owner}/${st.repo} ${st.variable}: ${why}`);
            }
        }
    }

    async function runRead() {
        lastStartedAt = now();
        try {
            do {
                rereadQueued = false;
                const list = currentList();
                sync(list);
                for (const sw of list) {
                    const st = states.get(switchKey(sw));
                    if (st) await readOne(st);                     // sequential; one failure never stops the rest
                }
            } while (rereadQueued);
        } catch (err) {
            log('warn', `[ci-fallback] read cycle failed: ${describeError(err)}`);
        }
    }

    /** Join the in-flight read or start one. Resolves {ran:true, coalesced?}. */
    function readOnce() {
        if (inflight) return inflight.then(() => ({ ran: true, coalesced: true }));
        inflight = runRead().finally(() => { inflight = null; });
        return inflight.then(() => ({ ran: true }));
    }

    function schedule() {
        if (!running || timer !== null) return;
        timer = setTimer(tick, intervalMs);
        if (timer && typeof timer.unref === 'function') timer.unref();
    }

    async function tick() {
        timer = null;
        if (!running) return;
        try { await readOnce(); } finally { schedule(); }   // next tick only after this one ends: ticks never overlap
    }

    function start() {
        if (!github || running) return Promise.resolve();
        running = true;
        const first = readOnce().then(() => undefined);
        first.then(schedule, schedule);
        return first;
    }

    function stop() {
        running = false;
        if (timer !== null) { try { clearTimer(timer); } catch (_) { /* ignore */ } timer = null; }
    }

    async function refreshNow({ force = false } = {}) {
        if (!github) return { ran: false, disabled: true };
        if (inflight) return readOnce();
        if (!force && lastStartedAt !== null) {
            const since = now() - lastStartedAt;
            if (since < minRefreshMs) {
                return { ran: false, throttled: true, retryAfterSec: Math.max(1, Math.ceil((minRefreshMs - since) / 1000)) };
            }
        }
        return readOnce();
    }

    /** Admin edited the switch list: re-read promptly (bypasses the min interval; coalesces with a read in flight). */
    function onSwitchesChanged() {
        if (!github) return Promise.resolve({ ran: false, disabled: true });
        sync(currentList());                                       // removed switches vanish immediately
        if (inflight) { rereadQueued = true; return inflight.then(() => ({ ran: true, coalesced: true })); }
        return readOnce();
    }

    function snapshot() {
        if (!github) return null;
        const rawRows = currentList().map((sw) => {
            const st = states.get(switchKey(sw)) || freshState(sw);
            return { sw, st };
        });
        const resolved = resolveChain(rawRows);
        const rows = rawRows.map((r) => ({ sw: r.sw, st: Object.assign({}, resolved.get(r)) }));
        const find = (variable) => rows.find(({ sw }) =>
            sw.owner.toLowerCase() === 'doublenode' && sw.repo.toLowerCase() === 'dev-team' && sw.variable === variable);
        // v1 contract shape: {armed, value} (value = runner-label JSON only when armed, else null); null = unknown/absent.
        const legacy = (variable) => {
            const hit = find(variable);
            if (!hit || hit.st.armed === null) return null;
            return { armed: hit.st.armed, value: hit.st.armed === true && hit.st.labels ? fitLabels(hit.st.labels) : null };
        };
        const legacyHits = [find('CI_LINUX_RUNNER'), find('CI_MACOS_RUNNER')].filter(Boolean);
        let checkedAt = null;
        if (legacyHits.length && legacyHits.every(({ st }) => st.checkedAt)) {
            checkedAt = legacyHits.map(({ st }) => st.checkedAt).sort()[0];   // oldest wins (ISO sorts lexically)
        }
        return {
            linux: legacy('CI_LINUX_RUNNER'),
            macos: legacy('CI_MACOS_RUNNER'),
            checkedAt,
            switches: rows.map(({ sw, st }) => ({
                owner: sw.owner, repo: sw.repo, variable: sw.variable, label: sw.label,
                armed: st.armed, reason: st.reason, error: st.error, checkedAt: st.checkedAt,
                ...(typeof sw.fallsBackTo === 'string' ? { fallsBackTo: sw.fallsBackTo } : {}),
            })),
        };
    }

    return { start, stop, refreshNow, onSwitchesChanged, snapshot };
}

module.exports = {
    createFallbackReader, classifySwitchValue, describeError, resolveChain, REASON,
    DEFAULT_INTERVAL_MS, DEFAULT_MIN_REFRESH_MS,
};
