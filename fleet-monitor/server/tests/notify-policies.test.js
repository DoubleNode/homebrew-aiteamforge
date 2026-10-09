//
//  notify-policies.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
    SEVERITIES, DEFAULT_DEDUPE_WINDOW_SECONDS, severityRank, isValidSeverity,
    quietHoursDecision, createDedupeTracker, createRateLimiter,
} = require('../lib/notify-policies');

function fakeClock(startIso = '2026-10-09T12:00:00Z') {
    let t = Date.parse(startIso);
    const clock = () => new Date(t);
    clock.advance = (sec) => { t += sec * 1000; };
    return clock;
}

const utc = (iso) => new Date(iso);
const QH_NIGHT = { start: '22:00', end: '07:00', timezone: 'UTC' }; // spans midnight
const QH_DAY = { start: '09:00', end: '17:00', timezone: 'UTC' };   // same day

// ------------------------------------------------------------------ severity

test('severity helpers', () => {
    assert.deepEqual(SEVERITIES, ['info', 'warning', 'high', 'critical']);
    assert.equal(severityRank('info'), 0);
    assert.equal(severityRank('critical'), 3);
    assert.equal(severityRank('nope'), -1);
    assert.equal(isValidSeverity('high'), true);
    assert.equal(isValidSeverity('HIGH'), false);
    assert.equal(isValidSeverity(undefined), false);
    assert.equal(DEFAULT_DEDUPE_WINDOW_SECONDS, 300);
});

// --------------------------------------------------------------- quiet hours

test('quiet hours: absent config never suppresses', () => {
    assert.deepEqual(quietHoursDecision('info', undefined, utc('2026-10-09T03:00:00Z')), { suppress: false });
    assert.deepEqual(quietHoursDecision('info', null, utc('2026-10-09T03:00:00Z')), { suppress: false });
});

test('quiet hours: same-day window, start inclusive, end exclusive', () => {
    const d = (hhmm) => quietHoursDecision('info', QH_DAY, utc(`2026-10-09T${hhmm}:00Z`));
    assert.equal(d('08:59').suppress, false);
    assert.deepEqual(d('09:00'), { suppress: true, reason: 'quiet-hours' });
    assert.equal(d('12:00').suppress, true);
    assert.equal(d('16:59').suppress, true);
    assert.equal(d('17:00').suppress, false);
});

test('quiet hours: window spanning midnight', () => {
    const d = (iso) => quietHoursDecision('warning', QH_NIGHT, utc(iso)).suppress;
    assert.equal(d('2026-10-09T21:59:00Z'), false);
    assert.equal(d('2026-10-09T22:00:00Z'), true);
    assert.equal(d('2026-10-09T23:59:00Z'), true);
    assert.equal(d('2026-10-10T00:00:00Z'), true);
    assert.equal(d('2026-10-10T06:59:00Z'), true);
    assert.equal(d('2026-10-10T07:00:00Z'), false);
    assert.equal(d('2026-10-10T12:00:00Z'), false);
});

test('quiet hours: critical always bypasses; every lower severity is suppressed', () => {
    const inside = utc('2026-10-09T23:00:00Z');
    assert.deepEqual(quietHoursDecision('critical', QH_NIGHT, inside), { suppress: false });
    for (const sev of ['info', 'warning', 'high']) {
        assert.deepEqual(quietHoursDecision(sev, QH_NIGHT, inside), { suppress: true, reason: 'quiet-hours' }, sev);
    }
});

test('quiet hours: evaluated in the configured zone', () => {
    const qh = { start: '22:00', end: '07:00', timezone: 'America/Chicago' };
    // 2026-10-09 is CDT (UTC-5): 03:00Z = 22:00 local (inside), 02:59Z = 21:59 (outside)
    assert.equal(quietHoursDecision('info', qh, utc('2026-10-10T03:00:00Z')).suppress, true);
    assert.equal(quietHoursDecision('info', qh, utc('2026-10-10T02:59:00Z')).suppress, false);
    // Same UTC instant in UTC zone would be outside the 22-07 window at 12:00Z
    assert.equal(quietHoursDecision('info', qh, utc('2026-10-09T12:00:00Z')).suppress, false);
});

test('quiet hours: DST transition in America/Chicago uses the right offset', () => {
    const qh = { start: '06:30', end: '07:30', timezone: 'America/Chicago' };
    // Spring forward is 2026-03-08. Before: CST (UTC-6). After: CDT (UTC-5).
    assert.equal(quietHoursDecision('info', qh, utc('2026-03-07T12:29:00Z')).suppress, false); // 06:29 CST
    assert.equal(quietHoursDecision('info', qh, utc('2026-03-07T12:30:00Z')).suppress, true);  // 06:30 CST
    assert.equal(quietHoursDecision('info', qh, utc('2026-03-07T13:29:00Z')).suppress, true);  // 07:29 CST
    assert.equal(quietHoursDecision('info', qh, utc('2026-03-07T13:30:00Z')).suppress, false); // 07:30 CST
    assert.equal(quietHoursDecision('info', qh, utc('2026-03-08T11:29:00Z')).suppress, false); // 06:29 CDT
    assert.equal(quietHoursDecision('info', qh, utc('2026-03-08T11:30:00Z')).suppress, true);  // 06:30 CDT
    assert.equal(quietHoursDecision('info', qh, utc('2026-03-08T12:29:00Z')).suppress, true);  // 07:29 CDT
    assert.equal(quietHoursDecision('info', qh, utc('2026-03-08T12:30:00Z')).suppress, false); // 07:30 CDT
    // Fall back 2026-11-01 (CDT -> CST): 07:29 CST = 13:29Z
    assert.equal(quietHoursDecision('info', qh, utc('2026-11-01T13:29:00Z')).suppress, true);
    assert.equal(quietHoursDecision('info', qh, utc('2026-11-01T13:30:00Z')).suppress, false);
});

test('quiet hours: midnight local renders as 00:00, not 24:00', () => {
    const qh = { start: '23:30', end: '00:30', timezone: 'America/Chicago' };
    assert.equal(quietHoursDecision('info', qh, utc('2026-10-10T05:00:00Z')).suppress, true);  // 00:00 CDT
    assert.equal(quietHoursDecision('info', qh, utc('2026-10-10T05:30:00Z')).suppress, false); // 00:30 CDT
});

test('quiet hours: invalid timezone is NOT suppressed and warns', () => {
    for (const tz of ['Mars/Olympus', '', undefined, null, 42, '+05:00']) {
        const r = quietHoursDecision('info', { start: '22:00', end: '07:00', timezone: tz }, utc('2026-10-09T23:00:00Z'));
        assert.deepEqual(r, { suppress: false, warning: 'invalid-timezone' }, String(tz));
    }
});

test('quiet hours: non-canonical zone casing is rejected like Python', () => {
    const r = quietHoursDecision('info', { start: '22:00', end: '07:00', timezone: 'america/chicago' }, utc('2026-10-09T23:00:00Z'));
    assert.equal(r.warning, 'invalid-timezone');
});

test('quiet hours: malformed or equal start/end warns, never suppresses', () => {
    const now = utc('2026-10-09T23:00:00Z');
    for (const bad of [
        { start: '24:00', end: '07:00', timezone: 'UTC' },
        { start: '9:00', end: '17:00', timezone: 'UTC' },
        { start: '22:00\n', end: '07:00', timezone: 'UTC' },
        { start: '22:00', end: 700, timezone: 'UTC' },
        { start: '10:00', end: '10:00', timezone: 'UTC' },
    ]) {
        assert.deepEqual(quietHoursDecision('info', bad, now), { suppress: false, warning: 'invalid-quiet-hours' }, JSON.stringify(bad));
    }
});

test('quiet hours: invalid severity or time warns, never suppresses', () => {
    assert.deepEqual(quietHoursDecision('bogus', QH_NIGHT, utc('2026-10-09T23:00:00Z')), { suppress: false, warning: 'invalid-severity' });
    assert.deepEqual(quietHoursDecision('info', QH_NIGHT, new Date('nope')), { suppress: false, warning: 'invalid-time' });
});

// -------------------------------------------------------------------- dedupe

test('dedupe: check is read-only until record() opens the window', () => {
    const clock = fakeClock();
    const d = createDedupeTracker({ clock });
    assert.equal(d.check('academy', 'ci-failed', 'PR-1', 300).duplicate, false);
    assert.equal(d.check('academy', 'ci-failed', 'PR-1', 300).duplicate, false, 'check alone must not record');
    assert.equal(d.size(), 0);
    assert.equal(d.record('academy', 'ci-failed', 'PR-1', 300).recorded, true);
    assert.equal(d.check('academy', 'ci-failed', 'PR-1', 300).duplicate, true);
});

test('dedupe: duplicate within the window, fresh after it (boundary inclusive of expiry)', () => {
    const clock = fakeClock();
    const d = createDedupeTracker({ clock });
    d.record('academy', 't', 'r', 300);
    clock.advance(299);
    assert.equal(d.check('academy', 't', 'r', 300).duplicate, true);
    clock.advance(1); // exactly 300s
    assert.equal(d.check('academy', 't', 'r', 300).duplicate, false);
    assert.equal(d.size(), 0, 'expired entry dropped on read');
});

test('dedupe: a suppressed duplicate does not refresh the window', () => {
    const clock = fakeClock();
    const d = createDedupeTracker({ clock });
    d.record('a', 't', 'r', 300);
    clock.advance(200);
    assert.equal(d.check('a', 't', 'r', 300).duplicate, true); // check only, no record
    clock.advance(101);
    assert.equal(d.check('a', 't', 'r', 300).duplicate, false);
});

test('dedupe: window 0 disables; absent window defaults to 300s', () => {
    const clock = fakeClock();
    const d = createDedupeTracker({ clock });
    assert.equal(d.record('a', 't', 'r', 0).recorded, false);
    assert.equal(d.check('a', 't', 'r', 0).duplicate, false);
    assert.equal(d.size(), 0);

    d.record('a', 't', 'r', undefined);
    clock.advance(299);
    assert.equal(d.check('a', 't', 'r', undefined).duplicate, true);
    clock.advance(1);
    assert.equal(d.check('a', 't', 'r', undefined).duplicate, false);
});

test('dedupe: invalid window fails toward delivery', () => {
    const d = createDedupeTracker({ clock: fakeClock() });
    for (const w of [-1, NaN, Infinity, 'x', null]) {
        assert.equal(d.record('a', 't', 'r', w).recorded, false, String(w));
        assert.equal(d.check('a', 't', 'r', w).duplicate, false, String(w));
    }
});

test('dedupe: team, type and ref each distinguish keys', () => {
    const d = createDedupeTracker({ clock: fakeClock() });
    d.record('academy', 'ci', 'r1', 300);
    assert.equal(d.check('academy', 'ci', 'r1', 300).duplicate, true);
    assert.equal(d.check('ios', 'ci', 'r1', 300).duplicate, false);
    assert.equal(d.check('academy', 'deploy', 'r1', 300).duplicate, false);
    assert.equal(d.check('academy', 'ci', 'r2', 300).duplicate, false);
});

test('dedupe: key format and missing ref keyed as empty string (matches Python)', () => {
    const d = createDedupeTracker({ clock: fakeClock() });
    assert.equal(d.check('academy', 'ci', 'PR-9', 300).key, 'academy|ci|PR-9');
    for (const missing of [undefined, null, '']) {
        assert.equal(d.check('academy', 'ci', missing, 300).key, 'academy|ci|', String(missing));
    }
    d.record('academy', 'ci', undefined, 300);
    assert.equal(d.check('academy', 'ci', '', 300).duplicate, true, 'undefined and "" share a key');
    assert.equal(d.check('academy', 'ci', null, 300).duplicate, true);
    assert.equal(d.check('academy', 'ci', 'PR-9', 300).duplicate, false);
});

test('dedupe: entry cap evicts the oldest', () => {
    const d = createDedupeTracker({ clock: fakeClock(), maxEntries: 3 });
    for (const r of ['a', 'b', 'c', 'd']) d.record('t', 'x', r, 300);
    assert.equal(d.size(), 3);
    assert.equal(d.check('t', 'x', 'a', 300).duplicate, false, 'oldest evicted');
    assert.equal(d.check('t', 'x', 'b', 300).duplicate, true);
    assert.equal(d.check('t', 'x', 'd', 300).duplicate, true);
});

test('dedupe: re-record moves a key to the young end; expired entries are pruned on record', () => {
    const clock = fakeClock();
    const d = createDedupeTracker({ clock, maxEntries: 3 });
    d.record('t', 'x', 'a', 300);
    d.record('t', 'x', 'b', 300);
    d.record('t', 'x', 'c', 300);
    d.record('t', 'x', 'a', 300); // a is now youngest
    d.record('t', 'x', 'd', 300); // evicts b, not a
    assert.equal(d.check('t', 'x', 'a', 300).duplicate, true);
    assert.equal(d.check('t', 'x', 'b', 300).duplicate, false);

    clock.advance(301);
    d.record('t', 'x', 'z', 300);
    assert.equal(d.size(), 1, 'all expired entries pruned');
});

// -------------------------------------------------------------- rate limiter

test('rate limiter: allows up to limit then denies with retryAfterSeconds', () => {
    const clock = fakeClock();
    const rl = createRateLimiter({ clock, limit: 3, windowSeconds: 60 });
    assert.deepEqual(rl.take('c1'), { allowed: true });
    clock.advance(10);
    assert.deepEqual(rl.take('c1'), { allowed: true });
    clock.advance(10);
    assert.deepEqual(rl.take('c1'), { allowed: true });
    clock.advance(10); // oldest stamp is 30s old -> frees in 30s
    assert.deepEqual(rl.take('c1'), { allowed: false, retryAfterSeconds: 30 });
});

test('rate limiter: denied attempts are not counted; recovers as the window slides', () => {
    const clock = fakeClock();
    const rl = createRateLimiter({ clock, limit: 2, windowSeconds: 60 });
    rl.take('c'); clock.advance(30); rl.take('c');
    clock.advance(1);
    assert.equal(rl.take('c').allowed, false);
    assert.equal(rl.take('c').allowed, false);
    clock.advance(29); // t=60: first stamp (t=0) falls out of the window
    assert.equal(rl.take('c').allowed, true);
    assert.equal(rl.take('c').allowed, false, 'second and third stamps now fill the limit');
    clock.advance(61);
    assert.equal(rl.take('c').allowed, true);
});

test('rate limiter: retryAfterSeconds rounds up and is at least 1', () => {
    const clock = fakeClock();
    const rl = createRateLimiter({ clock, limit: 1, windowSeconds: 10 });
    rl.take('c');
    clock.advance(9.5);
    assert.deepEqual(rl.take('c'), { allowed: false, retryAfterSeconds: 1 });
});

test('rate limiter: connections are isolated', () => {
    const rl = createRateLimiter({ clock: fakeClock(), limit: 1, windowSeconds: 60 });
    assert.equal(rl.take('a').allowed, true);
    assert.equal(rl.take('a').allowed, false);
    assert.equal(rl.take('b').allowed, true);
});

test('rate limiter: defaults are 20 per 600s', () => {
    const clock = fakeClock();
    const rl = createRateLimiter({ clock });
    for (let i = 0; i < 20; i++) assert.equal(rl.take('c').allowed, true, `take ${i}`);
    assert.deepEqual(rl.take('c'), { allowed: false, retryAfterSeconds: 600 });
    clock.advance(600);
    assert.equal(rl.take('c').allowed, true);
});

test('rate limiter: connection cap evicts the least recently used', () => {
    const rl = createRateLimiter({ clock: fakeClock(), limit: 1, windowSeconds: 60, maxConnections: 2 });
    rl.take('a'); rl.take('b');
    rl.take('a'); // touch a (denied, but recency refreshed)
    rl.take('c'); // evicts b
    assert.equal(rl.size(), 2);
    assert.equal(rl.take('a').allowed, false, 'a retained its bucket');
    assert.equal(rl.take('b').allowed, true, 'b was evicted, starts fresh');
});
