//
//  notify-policies.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

const fs = require('fs');
const path = require('path');

/**
 * Notification dispatcher policies (XACA-1400-004, EPIC-0068 D6).
 *
 * Pure policy building blocks the dispatcher composes. No I/O, no network.
 * Semantics mirror kanban-hooks/release_notify_routing.py (XACA-1399), which
 * is the source of truth: SEVERITIES, DEFAULT_DEDUPE_WINDOW_SECONDS, the
 * HH:MM grammar, [start,end) quiet hours that may span midnight, and the
 * dedupe key "team|type|ref" with a missing/empty ref keyed as "".
 *
 * STATE IS IN-MEMORY. A server restart resets every dedupe and rate window.
 * Acceptable for the MVP (worst case: one extra notice after a restart).
 *
 * Policy order, enforced by the dispatcher not here: quiet-hours (notice-level)
 * -> per connection: dedupe -> resolve -> rate limit.
 *
 * Quiet hours
 *  - critical ALWAYS bypasses quiet hours. It does NOT bypass dedupe or the
 *    rate limiter: those apply to every severity (the plan scopes the
 *    critical bypass to quiet hours only).
 *  - Bad input fails TOWARD DELIVERY but VISIBLY: an unknown timezone,
 *    malformed/equal start/end, bad severity or bad clock returns
 *    { suppress: false, warning: '<code>' } so the dispatcher can surface it.
 *    A broken config must never silently swallow a notice, nor silently read
 *    as "not quiet".
 *
 * Dedupe is PER CONNECTION: the key is team|type|ref|connectionId (the
 *  connectionId part is optional so the Python-style team|type|ref key still
 *  works standalone). A connection that already delivered inside the window is
 *  suppressed; a connection that failed is attempted again.
 *  WHEN is a key recorded? check() is READ-ONLY. record() is a separate call
 *  the dispatcher makes only for a connection that DELIVERED.
 *  Therefore none of these open a window: quiet-hours suppression,
 *  rate-limit suppression, or a send that failed/timed out.
 *  A failure can never hide a later retry, and a quiet-hours notice is not
 *  swallowed forever once quiet hours end. A dedupe-suppressed notice does
 *  NOT refresh the window (fixed window from the first delivery).
 *  Caveat: check and record are not atomic across awaited deliveries; two
 *  identical notices in flight at once can both pass. Acceptable for MVP.
 *
 * Rate limiter: sliding-window log per connection. Denied attempts are not
 * counted (a denied notice does not extend its own penalty).
 *
 * Memory is bounded everywhere (entry caps, oldest evicted first).
 */

const SEVERITIES = ['info', 'warning', 'high', 'critical']; // ascending
const DEFAULT_DEDUPE_WINDOW_SECONDS = 300;
const DEFAULT_DEDUPE_MAX_ENTRIES = 10000;
const DEFAULT_RATE_LIMIT = 20;
const DEFAULT_RATE_WINDOW_SECONDS = 600;
const DEFAULT_RATE_MAX_CONNECTIONS = 1000;

// Same grammar as Python HHMM_RE; the (?![\s\S]) is "end of string" (no
// trailing newline, unlike $).
const HHMM_RE = /^([01][0-9]|2[0-3]):([0-5][0-9])(?![\s\S])/;

function severityRank(s) {
    return SEVERITIES.indexOf(s);
}

function isValidSeverity(s) {
    return typeof s === 'string' && SEVERITIES.includes(s);
}

function nowMs(clock) {
    return +new Date(clock());
}

// ---------------------------------------------------------------- quiet hours

function minutes(hhmm) {
    const m = typeof hhmm === 'string' ? HHMM_RE.exec(hhmm) : null;
    return m ? parseInt(m[1], 10) * 60 + parseInt(m[2], 10) : null;
}

const MAX_ZONE_LENGTH = 64;
const formatters = new Map(); // zone -> Intl.DateTimeFormat | null (invalid)
const FORMATTER_CAP = 64;

// The bundled IANA zone list (config/iana_zones.json) is a SNAPSHOT of Python's
// zoneinfo.available_timezones() (regenerate: sorted(available_timezones()) as a
// JSON array, one name per line; the drift test in
// tests/xaca-1400-008-review-round1.test.js names any difference); it is the single source of truth for valid zone
// NAMES, so this validator and release_notify_routing._zone agree by
// construction. Fail closed: if the file cannot be read, EVERY zone is invalid
// (push 400s, send-time skips quiet hours) and the cause is logged loudly.
const ZONES_FILE = path.join(__dirname, '..', 'config', 'iana_zones.json');
let ZONE_SET = new Set();
try {
    const list = JSON.parse(fs.readFileSync(ZONES_FILE, 'utf8'));
    if (!Array.isArray(list) || list.length === 0 || !list.every((z) => typeof z === 'string')) {
        throw new Error('expected a non-empty JSON array of strings');
    }
    ZONE_SET = new Set(list);
} catch (err) {
    console.error('[NOTIFY] FATAL: cannot load ' + ZONES_FILE + ' (' + err.message
        + '); every quietHours timezone will be rejected until it is restored');
}

function formatterFor(zone) {
    if (formatters.has(zone)) return formatters.get(zone);
    let fmt = null;
    // Exact, case-sensitive membership in Python's list (rejects offsets, miscased
    // names and miscased ALIASES like 'us/eastern'), AND the runtime must be able
    // to evaluate it (Intl rejects a few listed names such as 'Factory').
    if (typeof zone === 'string' && zone && zone.length <= MAX_ZONE_LENGTH && ZONE_SET.has(zone)) {
        try {
            fmt = new Intl.DateTimeFormat('en-GB', {
                timeZone: zone, hourCycle: 'h23', hour: '2-digit', minute: '2-digit',
            });
        } catch (_) { fmt = null; }
    }
    if (formatters.size >= FORMATTER_CAP) formatters.delete(formatters.keys().next().value);
    formatters.set(zone, fmt);
    return fmt;
}

/**
 * THE timezone validator. The push route (notify-team-routes) and send-time
 * quiet hours (quietHoursDecision) both call this, so a zone accepted at push is
 * honoured at send.
 *
 * Parity with Python release_notify_routing._zone: a zone is valid iff its name
 * is an exact (case-sensitive) member of zoneinfo.available_timezones() -- the
 * bundled config/iana_zones.json -- and is <= 64 chars. Canonical names and
 * aliases ('UTC', 'America/Chicago', 'US/Central') pass; offsets ('+05:00'),
 * miscased names and miscased aliases ('us/central') do not.
 *
 * Caveat: the list is a snapshot of the generating machine's tzdata; a drift
 * test fails when it no longer matches Python's. Also, the JS runtime must be
 * able to evaluate the zone, so a name Python lists but Intl cannot resolve
 * ('Factory') is refused here: stricter than Python, never looser.
 */
function isValidTimeZone(zone) {
    return formatterFor(zone) !== null;
}

function localMinutes(fmt, date) {
    const parts = fmt.formatToParts(date);
    const h = parseInt(parts.find((p) => p.type === 'hour').value, 10) % 24;
    const m = parseInt(parts.find((p) => p.type === 'minute').value, 10);
    return h * 60 + m;
}

/**
 * Should a notice of `severity` be suppressed at `now`?
 * @returns {{suppress: boolean, reason?: 'quiet-hours', warning?: string}}
 */
function quietHoursDecision(severity, quietHours, now) {
    if (!isValidSeverity(severity)) return { suppress: false, warning: 'invalid-severity' };
    if (!quietHours) return { suppress: false };
    const date = now instanceof Date ? now : new Date(now);
    if (Number.isNaN(date.getTime())) return { suppress: false, warning: 'invalid-time' };

    const start = minutes(quietHours.start);
    const end = minutes(quietHours.end);
    if (start === null || end === null || start === end) {
        return { suppress: false, warning: 'invalid-quiet-hours' };
    }
    const fmt = formatterFor(quietHours.timezone);
    if (!fmt) return { suppress: false, warning: 'invalid-timezone' };

    const cur = localMinutes(fmt, date);
    const inside = start < end ? (cur >= start && cur < end) : (cur >= start || cur < end);
    if (!inside || severity === 'critical') return { suppress: false };
    return { suppress: true, reason: 'quiet-hours' };
}

// --------------------------------------------------------------------- dedupe

// connectionId (optional) makes the key per-connection: team|type|ref|connectionId.
// Omitted, the key is the Python-compatible team|type|ref.
function dedupeKey(team, type, ref, connectionId) {
    const base = `${team}|${type}|${ref || ''}`;
    return connectionId === undefined ? base : `${base}|${connectionId}`;
}

function createDedupeTracker(opts = {}) {
    const clock = opts.clock || (() => new Date());
    const maxEntries = Number.isInteger(opts.maxEntries) && opts.maxEntries > 0
        ? opts.maxEntries : DEFAULT_DEDUPE_MAX_ENTRIES;
    const seen = new Map(); // key -> expiresAtMs (insertion order = age)

    function resolveWindow(windowSeconds) {
        if (windowSeconds === undefined) return DEFAULT_DEDUPE_WINDOW_SECONDS;
        // Invalid values fail toward delivery (treated as disabled).
        if (!Number.isFinite(windowSeconds) || windowSeconds < 0) return 0;
        return windowSeconds;
    }

    function prune(t) {
        // Front-prune expired entries; stops at the first live one, and the
        // hard cap below bounds anything mixed windows leave behind.
        for (const [k, exp] of seen) {
            if (exp > t) break;
            seen.delete(k);
        }
    }

    /** READ-ONLY. Does not open a window. */
    function check(team, type, ref, windowSeconds, connectionId) {
        const key = dedupeKey(team, type, ref, connectionId);
        if (resolveWindow(windowSeconds) === 0) return { duplicate: false, key };
        const exp = seen.get(key);
        const t = nowMs(clock);
        if (exp === undefined) return { duplicate: false, key };
        if (exp <= t) { seen.delete(key); return { duplicate: false, key }; }
        return { duplicate: true, key };
    }

    /** Open the window. Call only after a successful delivery. */
    function record(team, type, ref, windowSeconds, connectionId) {
        const key = dedupeKey(team, type, ref, connectionId);
        const w = resolveWindow(windowSeconds);
        if (w === 0) return { recorded: false, key };
        const t = nowMs(clock);
        prune(t);
        seen.delete(key); // re-insert at the young end
        seen.set(key, t + w * 1000);
        while (seen.size > maxEntries) seen.delete(seen.keys().next().value);
        return { recorded: true, key };
    }

    return { check, record, size: () => seen.size };
}

// ----------------------------------------------------------------- rate limit

function createRateLimiter(opts = {}) {
    const clock = opts.clock || (() => new Date());
    const limit = Number.isInteger(opts.limit) && opts.limit > 0 ? opts.limit : DEFAULT_RATE_LIMIT;
    const windowSeconds = Number.isFinite(opts.windowSeconds) && opts.windowSeconds > 0
        ? opts.windowSeconds : DEFAULT_RATE_WINDOW_SECONDS;
    const maxConnections = Number.isInteger(opts.maxConnections) && opts.maxConnections > 0
        ? opts.maxConnections : DEFAULT_RATE_MAX_CONNECTIONS;
    const windowMs = windowSeconds * 1000;
    const buckets = new Map(); // connectionId -> [ts, ...] ascending, <= limit long

    /** Consume one slot for `connectionId`, or say when to retry. */
    function take(connectionId) {
        const t = nowMs(clock);
        const key = String(connectionId);
        let stamps = buckets.get(key);
        if (!stamps) {
            stamps = [];
        } else {
            buckets.delete(key); // re-insert below so eviction order = recency
        }
        while (stamps.length && stamps[0] <= t - windowMs) stamps.shift();

        let result;
        if (stamps.length >= limit) {
            const retryMs = stamps[0] + windowMs - t;
            result = { allowed: false, retryAfterSeconds: Math.max(1, Math.ceil(retryMs / 1000)) };
        } else {
            stamps.push(t);
            result = { allowed: true };
        }
        buckets.set(key, stamps);
        while (buckets.size > maxConnections) buckets.delete(buckets.keys().next().value);
        return result;
    }

    return { take, size: () => buckets.size };
}

module.exports = {
    SEVERITIES,
    DEFAULT_DEDUPE_WINDOW_SECONDS,
    severityRank,
    isValidSeverity,
    quietHoursDecision,
    isValidTimeZone,
    createDedupeTracker,
    createRateLimiter,
};
