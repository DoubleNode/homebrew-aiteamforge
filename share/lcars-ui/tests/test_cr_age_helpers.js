/**
 * test_cr_age_helpers.js — Node-native unit tests for lcars-cr-age-helpers.js
 *
 * XACA-0335 [Review] follow-up: Coverage for the AGE column helpers extracted
 * from lcars-cr-tab.js. Validates boundary buckets in formatRelativeAge,
 * terminal-state suppression and timestamp fallback in computeCRAgeMs, and
 * the canonical-set invariant against lcars-cr-tab.js SAVED_VIEWS.
 *
 * Usage:
 *   node --test lcars-ui/tests/test_cr_age_helpers.js
 *
 * No external dependencies. Node ≥18 required (node:test is built-in).
 */

'use strict';

var test   = require('node:test');
var assert = require('node:assert/strict');
var path   = require('path');
var fs     = require('fs');

// ─── Load module ───────────────────────────────────────────────────────────────

var HELPERS_PATH = path.join(__dirname, '../js/lcars-cr-age-helpers.js');
var helpers      = require(HELPERS_PATH);

var formatRelativeAge   = helpers.formatRelativeAge;
var computeCRAgeMs      = helpers.computeCRAgeMs;
var AGE_TERMINAL_STATES = helpers.AGE_TERMINAL_STATES;

// ─── Helpers ───────────────────────────────────────────────────────────────────

var MIN  = 60 * 1000;
var HOUR = 60 * MIN;
var DAY  = 24 * HOUR;
var WEEK = 7  * DAY;

// Fixed-clock helper so tests don't drift with wall-clock.
var FIXED_NOW = Date.UTC(2026, 4, 6, 12, 0, 0); // 2026-05-06T12:00:00Z

function tsAgo(ms) {
    return new Date(FIXED_NOW - ms).toISOString();
}

// ─── formatRelativeAge — boundary buckets ──────────────────────────────────────

test('formatRelativeAge: 0ms → "0m"', () => {
    assert.equal(formatRelativeAge(0), '0m');
});

test('formatRelativeAge: 30m → "30m"', () => {
    assert.equal(formatRelativeAge(30 * MIN), '30m');
});

test('formatRelativeAge: 59m → "59m" (last minute before hour bucket)', () => {
    assert.equal(formatRelativeAge(59 * MIN + 59 * 1000), '59m');
});

test('formatRelativeAge: 60m → "1h" (boundary: minutes → hours)', () => {
    assert.equal(formatRelativeAge(60 * MIN), '1h');
});

test('formatRelativeAge: 23h → "23h"', () => {
    assert.equal(formatRelativeAge(23 * HOUR), '23h');
});

test('formatRelativeAge: 23h59m → "23h" (last hour before day bucket)', () => {
    assert.equal(formatRelativeAge(23 * HOUR + 59 * MIN), '23h');
});

test('formatRelativeAge: 24h → "1d" (boundary: hours → days)', () => {
    assert.equal(formatRelativeAge(24 * HOUR), '1d');
});

test('formatRelativeAge: 6d → "6d"', () => {
    assert.equal(formatRelativeAge(6 * DAY), '6d');
});

test('formatRelativeAge: 6d23h → "6d" (last day before week bucket)', () => {
    assert.equal(formatRelativeAge(6 * DAY + 23 * HOUR), '6d');
});

test('formatRelativeAge: 7d → "1w" (boundary: days → weeks)', () => {
    assert.equal(formatRelativeAge(7 * DAY), '1w');
});

test('formatRelativeAge: 21d → "3w"', () => {
    assert.equal(formatRelativeAge(21 * DAY), '3w');
});

test('formatRelativeAge: 29d → "4w" (last day before month bucket)', () => {
    assert.equal(formatRelativeAge(29 * DAY), '4w');
});

test('formatRelativeAge: 30d → "1mo" (boundary: days → months)', () => {
    assert.equal(formatRelativeAge(30 * DAY), '1mo');
});

test('formatRelativeAge: 60d → "2mo"', () => {
    assert.equal(formatRelativeAge(60 * DAY), '2mo');
});

test('formatRelativeAge: 365d → "12mo"', () => {
    assert.equal(formatRelativeAge(365 * DAY), '12mo');
});

test('formatRelativeAge: negative duration clamps to "0m" (clock-skew tolerance)', () => {
    assert.equal(formatRelativeAge(-1000), '0m');
});

test('formatRelativeAge: -1h clamps to "0m"', () => {
    assert.equal(formatRelativeAge(-1 * HOUR), '0m');
});

// ─── computeCRAgeMs — happy path ──────────────────────────────────────────────

test('computeCRAgeMs: active state with cr_created_at returns positive ms', () => {
    var item = { crState: 'cr-submitted', cr_created_at: tsAgo(2 * HOUR) };
    var got  = computeCRAgeMs(item, FIXED_NOW);
    assert.equal(got, 2 * HOUR);
});

test('computeCRAgeMs: now defaults to Date.now() when omitted', () => {
    // Construct a CR created 1 hour ago using real wall-clock
    var item = { crState: 'cr-submitted', cr_created_at: new Date(Date.now() - HOUR).toISOString() };
    var got  = computeCRAgeMs(item);
    // Allow for a small delta from test execution time
    assert.ok(got !== null, 'should not be null');
    assert.ok(got >= HOUR - 1000 && got <= HOUR + 1000, 'should be ~1h ±1s, got ' + got);
});

// ─── computeCRAgeMs — terminal-state suppression ──────────────────────────────

test('computeCRAgeMs: deployed-prod returns null', () => {
    var item = { crState: 'deployed-prod', cr_created_at: tsAgo(DAY) };
    assert.equal(computeCRAgeMs(item, FIXED_NOW), null);
});

test('computeCRAgeMs: emergency-deployed returns null', () => {
    var item = { crState: 'emergency-deployed', cr_created_at: tsAgo(DAY) };
    assert.equal(computeCRAgeMs(item, FIXED_NOW), null);
});

test('computeCRAgeMs: cr-rejected returns null', () => {
    var item = { crState: 'cr-rejected', cr_created_at: tsAgo(DAY) };
    assert.equal(computeCRAgeMs(item, FIXED_NOW), null);
});

test('computeCRAgeMs: non-terminal cr-held still returns positive ms', () => {
    var item = { crState: 'cr-held', cr_created_at: tsAgo(DAY) };
    assert.equal(computeCRAgeMs(item, FIXED_NOW), DAY);
});

// ─── computeCRAgeMs — timestamp fallback chain ────────────────────────────────

test('computeCRAgeMs: missing cr_created_at falls back to addedAt', () => {
    var item = { crState: 'cr-submitted', addedAt: tsAgo(3 * HOUR) };
    assert.equal(computeCRAgeMs(item, FIXED_NOW), 3 * HOUR);
});

test('computeCRAgeMs: cr_created_at takes precedence over addedAt when both present', () => {
    var item = {
        crState:        'cr-submitted',
        cr_created_at:  tsAgo(2 * HOUR),
        addedAt:        tsAgo(5 * HOUR),
    };
    assert.equal(computeCRAgeMs(item, FIXED_NOW), 2 * HOUR);
});

test('computeCRAgeMs: empty-string cr_created_at falls through to addedAt', () => {
    var item = {
        crState:        'cr-submitted',
        cr_created_at:  '',
        addedAt:        tsAgo(4 * HOUR),
    };
    assert.equal(computeCRAgeMs(item, FIXED_NOW), 4 * HOUR);
});

test('computeCRAgeMs: both timestamps absent → null', () => {
    var item = { crState: 'cr-submitted' };
    assert.equal(computeCRAgeMs(item, FIXED_NOW), null);
});

test('computeCRAgeMs: both timestamps empty strings → null', () => {
    var item = { crState: 'cr-submitted', cr_created_at: '', addedAt: '' };
    assert.equal(computeCRAgeMs(item, FIXED_NOW), null);
});

// ─── computeCRAgeMs — invalid input ───────────────────────────────────────────

test('computeCRAgeMs: invalid date string → null', () => {
    var item = { crState: 'cr-submitted', cr_created_at: 'garbage-not-a-date' };
    assert.equal(computeCRAgeMs(item, FIXED_NOW), null);
});

test('computeCRAgeMs: null item → null (defensive)', () => {
    assert.equal(computeCRAgeMs(null, FIXED_NOW), null);
});

test('computeCRAgeMs: undefined item → null (defensive)', () => {
    assert.equal(computeCRAgeMs(undefined, FIXED_NOW), null);
});

// ─── AGE_TERMINAL_STATES — set membership and SSOT invariant ──────────────────

test('AGE_TERMINAL_STATES: contains exactly deployed-prod, emergency-deployed, cr-rejected', () => {
    assert.equal(AGE_TERMINAL_STATES.size, 3);
    assert.ok(AGE_TERMINAL_STATES.has('deployed-prod'));
    assert.ok(AGE_TERMINAL_STATES.has('emergency-deployed'));
    assert.ok(AGE_TERMINAL_STATES.has('cr-rejected'));
});

test('AGE_TERMINAL_STATES: does NOT contain non-terminal states', () => {
    assert.ok(!AGE_TERMINAL_STATES.has('cr-drafted'));
    assert.ok(!AGE_TERMINAL_STATES.has('cr-submitted'));
    assert.ok(!AGE_TERMINAL_STATES.has('cr-approved'));
    assert.ok(!AGE_TERMINAL_STATES.has('cr-held'));
    assert.ok(!AGE_TERMINAL_STATES.has('implementing'));
    assert.ok(!AGE_TERMINAL_STATES.has('deployed-dev'));
});

// SSOT INVARIANT: the AGE_TERMINAL_STATES set must match the canonical TERMINAL
// set in lcars-cr-tab.js SAVED_VIEWS['active-pipeline']. We grep the file for
// the literal Set declaration and assert the values match. Catches drift if
// either set is updated without the other.
test('AGE_TERMINAL_STATES: matches canonical TERMINAL set in lcars-cr-tab.js (SSOT)', () => {
    var crTabPath = path.join(__dirname, '../js/lcars-cr-tab.js');
    var src = fs.readFileSync(crTabPath, 'utf8');
    // Match: const TERMINAL = new Set([... ]);  (single line, single quoted strings)
    var match = src.match(/const\s+TERMINAL\s*=\s*new\s+Set\(\[([^\]]+)\]\)/);
    assert.ok(match, 'Expected to find `const TERMINAL = new Set([...])` in lcars-cr-tab.js');
    var canonical = match[1]
        .split(',')
        .map(s => s.trim().replace(/^['"]|['"]$/g, ''))
        .filter(Boolean);
    assert.equal(canonical.length, AGE_TERMINAL_STATES.size,
        'Canonical TERMINAL has ' + canonical.length + ' entries, AGE_TERMINAL_STATES has ' + AGE_TERMINAL_STATES.size);
    for (var i = 0; i < canonical.length; i++) {
        assert.ok(AGE_TERMINAL_STATES.has(canonical[i]),
            'AGE_TERMINAL_STATES is missing canonical state: ' + canonical[i]);
    }
});
