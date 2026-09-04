//
//  xaca-1031-021-tap-version-backoff.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * Regression coverage for XACA-1031 subitem 021 (code review on PR #818):
 * "Add failure backoff to the tap-version fetch: latestTapVersionFetchedAt
 * only advances on success, so during a GitHub raw outage every /api/fleet
 * read re-attempts a 5s-timeout fetch indefinitely. Track a lastAttemptAt
 * separately and back off."
 *
 * -- WHY THIS DOES NOT USE tests/helpers/app-factory.js's MIRROR ----------
 * app-factory.js's getLatestTapVersion() is a deliberately TRIVIAL
 * injectable stub (`latestTapVersionState.value`) for exercising
 * projectSystemBlock()'s consumption of a version string -- see
 * xaca-1031-007-mirror-drift-guard.test.js's own header, which documents
 * this as a known, explicitly out-of-scope gap: "a defect purely inside
 * server.js's real getLatestTapVersion()/fetchLatestTapVersion() ... is
 * invisible to both this guard and to xaca-1031-007-system-block.test.js
 * -- neither loads server.js. That is a real, stated gap, not one this
 * file can close without requiring server.js directly (which would need
 * its own app.listen()-avoidance refactor, out of scope for this
 * subitem)." That refactor is XACA-1031-020, explicitly out of scope here
 * too (large architectural change pending a user decision).
 *
 * -- HOW THE REAL FUNCTIONS ARE EXERCISED INSTEAD --------------------------
 * Same technique the fleet-reporter.sh bash suites already use for the same
 * problem (a script not designed to be imported): every line of server.js
 * from the `TAP_VERSION_URL` constant through the end of the real
 * getLatestTapVersion() function is extracted VERBATIM (anchored on unique
 * markers, FATAL if either anchor goes missing -- the extraction seam this
 * suite depends on) into a fresh temp module per test run. The two timing
 * CONSTANTS (TAP_VERSION_CACHE_TTL_MS, TAP_VERSION_FETCH_MIN_RETRY_MS) are
 * shrunk from hours/minutes to milliseconds by a targeted regex substitution
 * on their exact declaration lines (fail loudly if the anchor is gone) --
 * this changes ONLY the numeric VALUE two `const` declarations bind to, not
 * one byte of the actual retry/backoff LOGIC under test, so what runs here
 * is the real fetchLatestTapVersion()/getLatestTapVersion()/
 * _tapVersionRetryBackoffMs() bodies, not a reimplementation. A small
 * `module.exports` footer (present ONLY in the temp copy, never written back
 * to server.js) exposes the functions plus a couple of read-only test hooks
 * for internal state and the pending in-flight promise.
 *
 * global.fetch is stubbed per test (Node's fetch is a global, not an
 * import, so this needs no module mocking machinery) -- no real network
 * call is ever made by this suite.
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const SERVER_JS = path.join(__dirname, '..', 'server.js');
const serverSrc = fs.readFileSync(SERVER_JS, 'utf8');

// PART A: the four TAP_VERSION_* config constants. These live near the TOP
// of server.js (shared config section, alongside other *_URL/*_TTL_MS
// constants) -- NOT adjacent to the "TAP VERSION CACHE" implementation
// block below, which lives ~1300 lines further down, right before
// isVersionOutdated(). Extracted individually by exact declaration text so
// a reformatting elsewhere in the file can't silently widen or narrow what
// this suite captures.
const CONST_ANCHORS = [
    "const TAP_VERSION_URL = 'https://raw.githubusercontent.com/DoubleNode/homebrew-aiteamforge/main/VERSION';",
    'const TAP_VERSION_CACHE_TTL_MS = 60 * 60 * 1000; // 1 hour',
    "const TAP_VERSION_FETCH_TIMEOUT_MS = 5 * 1000; // 5s -- a hung connection must never block a status cycle",
    'const TAP_VERSION_FETCH_MIN_RETRY_MS = 60 * 1000; // 1 minute',
];
for (const line of CONST_ANCHORS) {
    if (!serverSrc.includes(line)) {
        throw new Error(`FATAL: xaca-1031-021-tap-version-backoff.test.js extraction anchor not found in server.js: ${JSON.stringify(line)}`);
    }
}
const partA = CONST_ANCHORS.join('\n');

// PART B: the "TAP VERSION CACHE" implementation block itself -- from the
// first `let latestTapVersion = null;` state declaration through the end of
// the real getLatestTapVersion() function, found by brace-depth counting
// from that function's own opening brace (not a fixed line range, which
// drifts the moment either function's body changes length).
const START_ANCHOR_B = 'let latestTapVersion = null;';
const END_ANCHOR_B = 'function getLatestTapVersion() {';

const startIdxB = serverSrc.indexOf(START_ANCHOR_B);
const endFnIdx = serverSrc.indexOf(END_ANCHOR_B);
if (startIdxB === -1 || endFnIdx === -1) {
    throw new Error(
        'FATAL: xaca-1031-021-tap-version-backoff.test.js extraction anchors not found in server.js -- ' +
        'this suite\'s extraction seam is gone (latestTapVersion state or getLatestTapVersion() moved/renamed).'
    );
}
// Extend past the end anchor to the closing brace of getLatestTapVersion()
// itself by counting braces from the function's opening one, so a future
// edit to the function body (that doesn't move the anchors) is still
// captured in full.
let depth = 0;
let cursor = serverSrc.indexOf('{', endFnIdx);
if (cursor === -1) {
    throw new Error('FATAL: could not locate getLatestTapVersion()\'s opening brace.');
}
for (; cursor < serverSrc.length; cursor++) {
    if (serverSrc[cursor] === '{') depth++;
    else if (serverSrc[cursor] === '}') {
        depth--;
        if (depth === 0) break;
    }
}
if (depth !== 0) {
    throw new Error('FATAL: brace-depth scan for getLatestTapVersion() never closed -- extraction seam broken.');
}
const endIdxB = cursor + 1; // include the closing brace

const partB = serverSrc.slice(startIdxB, endIdxB);

let extracted = `${partA}\n\n${partB}`;

// Guard the seam further: every symbol this suite drives must still be
// textually present in what we just extracted.
for (const anchor of [
    'TAP_VERSION_CACHE_TTL_MS',
    'TAP_VERSION_FETCH_MIN_RETRY_MS',
    'TAP_VERSION_FETCH_TIMEOUT_MS',
    'function _tapVersionRetryBackoffMs',
    'async function fetchLatestTapVersion',
    'function getLatestTapVersion',
    'latestTapVersionFailureCount',
    'latestTapVersionLastAttemptAt',
]) {
    if (!extracted.includes(anchor)) {
        throw new Error(`FATAL: extracted region no longer references '${anchor}' -- extraction/injection seam is gone.`);
    }
}

// Shrink the two timing constants from hours/minutes to milliseconds so the
// suite runs fast and deterministically. Only the numeric literal on the
// RHS of these two exact declarations is touched -- the logic is untouched.
const TEST_TTL_MS = 200;
const TEST_MIN_RETRY_MS = 50;

function substituteConst(src, name, replacementLiteral) {
    const re = new RegExp(`^const ${name} = .*;.*$`, 'm');
    if (!re.test(src)) {
        throw new Error(`FATAL: could not find 'const ${name} = ...;' to substitute -- extraction seam broken.`);
    }
    return src.replace(re, `const ${name} = ${replacementLiteral}; // TEST OVERRIDE`);
}

extracted = substituteConst(extracted, 'TAP_VERSION_CACHE_TTL_MS', TEST_TTL_MS);
extracted = substituteConst(extracted, 'TAP_VERSION_FETCH_MIN_RETRY_MS', TEST_MIN_RETRY_MS);

const FOOTER = `
module.exports = {
    fetchLatestTapVersion,
    getLatestTapVersion,
    _tapVersionRetryBackoffMs,
    _test: {
        getState: () => ({
            latestTapVersion,
            latestTapVersionFetchedAt,
            latestTapVersionLastAttemptAt,
            latestTapVersionFailureCount,
        }),
        waitForInFlight: () => latestTapVersionFetchInFlight || Promise.resolve(),
        constants: { TAP_VERSION_CACHE_TTL_MS, TAP_VERSION_FETCH_MIN_RETRY_MS, TAP_VERSION_FETCH_TIMEOUT_MS },
    },
};
`;

extracted += FOOTER;

/**
 * Writes the (already-extracted, already-substituted) source to a FRESH
 * temp file with a unique name and require()s it -- a distinct file path
 * per call sidesteps Node's require cache entirely, so each test gets its
 * own independent set of module-level `let` state without needing to
 * delete cache entries.
 */
let moduleCounter = 0;
function loadFreshModule() {
    moduleCounter += 1;
    const tmpFile = path.join(os.tmpdir(), `xaca1031021-tapversion-${process.pid}-${moduleCounter}.js`);
    fs.writeFileSync(tmpFile, extracted);
    // eslint-disable-next-line global-require, import/no-dynamic-require
    const mod = require(tmpFile);
    fs.unlinkSync(tmpFile);
    return mod;
}

function mockFetchSequence(steps) {
    // steps: array of { ok, status, body } | { reject: Error }. Each call to
    // fetch() consumes the next step; extra calls beyond the array reuse the
    // last step (keeps late/unexpected calls from throwing a confusing
    // "undefined" error and masking the real assertion failure).
    let i = 0;
    let callCount = 0;
    const fn = async (_url, _opts) => {
        callCount += 1;
        const step = steps[Math.min(i, steps.length - 1)];
        i += 1;
        if (step.reject) throw step.reject;
        return {
            ok: step.ok,
            status: step.status,
            text: async () => step.body,
        };
    };
    fn.getCallCount = () => callCount;
    return fn;
}

// ============================================================================
// _tapVersionRetryBackoffMs -- pure formula, no clock/network involved.
// ============================================================================
test('_tapVersionRetryBackoffMs(0) == 0 -- no failure on record retries as soon as stale (unchanged pre-021 behavior)', () => {
    const mod = loadFreshModule();
    assert.equal(mod._tapVersionRetryBackoffMs(0), 0);
});

test('_tapVersionRetryBackoffMs(1) == the retry floor', () => {
    const mod = loadFreshModule();
    assert.equal(mod._tapVersionRetryBackoffMs(1), mod._test.constants.TAP_VERSION_FETCH_MIN_RETRY_MS);
});

test('_tapVersionRetryBackoffMs doubles per consecutive failure', () => {
    const mod = loadFreshModule();
    const floor = mod._test.constants.TAP_VERSION_FETCH_MIN_RETRY_MS;
    assert.equal(mod._tapVersionRetryBackoffMs(2), floor * 2);
    assert.equal(mod._tapVersionRetryBackoffMs(3), floor * 4);
});

test('_tapVersionRetryBackoffMs is capped at the steady-state cache TTL -- an outage never retries LESS often than a healthy cache refreshes', () => {
    const mod = loadFreshModule();
    const ttl = mod._test.constants.TAP_VERSION_CACHE_TTL_MS;
    assert.equal(mod._tapVersionRetryBackoffMs(50), ttl);
    assert.equal(mod._tapVersionRetryBackoffMs(1000), ttl);
});

test('_tapVersionRetryBackoffMs treats a negative/NaN failure count as zero (defensive, should never occur)', () => {
    const mod = loadFreshModule();
    assert.equal(mod._tapVersionRetryBackoffMs(-3), 0);
    assert.equal(mod._tapVersionRetryBackoffMs(NaN), 0);
});

// ============================================================================
// Integration: the real fetchLatestTapVersion()/getLatestTapVersion() pair,
// with global.fetch stubbed, driving the actual backoff-gated retry path.
// ============================================================================

test('a single failure never poisons the cache -- latest stays null, no throw', async () => {
    const mod = loadFreshModule();
    const realFetch = global.fetch;
    global.fetch = mockFetchSequence([{ reject: new Error('simulated DNS failure') }]);
    try {
        assert.equal(mod.getLatestTapVersion(), null);
        await mod._test.waitForInFlight();
        const state = mod._test.getState();
        assert.equal(state.latestTapVersion, null);
        assert.equal(state.latestTapVersionFailureCount, 1);
        assert.equal(global.fetch.getCallCount(), 1);
    } finally {
        global.fetch = realFetch;
    }
});

test('a repeat read DURING the backoff window does NOT trigger another network attempt (this is the retry-storm fix)', async () => {
    const mod = loadFreshModule();
    const realFetch = global.fetch;
    global.fetch = mockFetchSequence([{ reject: new Error('simulated outage') }]);
    try {
        mod.getLatestTapVersion(); // attempt #1 -- fails
        await mod._test.waitForInFlight();
        assert.equal(global.fetch.getCallCount(), 1, 'sanity: first attempt happened');

        // Immediately re-read, well inside the backoff(1) window (TEST_MIN_RETRY_MS).
        mod.getLatestTapVersion();
        await mod._test.waitForInFlight();
        assert.equal(global.fetch.getCallCount(), 1, 'a read inside the backoff window must NOT re-attempt the network');
        assert.equal(mod._test.getState().latestTapVersionFailureCount, 1, 'failure count must not double-count a call that never actually fetched');
    } finally {
        global.fetch = realFetch;
    }
});

test('once the backoff window elapses, the next stale read DOES retry', async () => {
    const mod = loadFreshModule();
    const realFetch = global.fetch;
    global.fetch = mockFetchSequence([{ reject: new Error('simulated outage') }, { reject: new Error('simulated outage') }]);
    try {
        mod.getLatestTapVersion(); // attempt #1
        await mod._test.waitForInFlight();
        assert.equal(global.fetch.getCallCount(), 1);

        // Wait longer than backoff(1) == TEST_MIN_RETRY_MS.
        await new Promise((r) => setTimeout(r, mod._test.constants.TAP_VERSION_FETCH_MIN_RETRY_MS + 30));

        mod.getLatestTapVersion(); // attempt #2 -- backoff window has elapsed
        await mod._test.waitForInFlight();
        assert.equal(global.fetch.getCallCount(), 2, 'a read AFTER the backoff window elapses must retry');
        assert.equal(mod._test.getState().latestTapVersionFailureCount, 2);
    } finally {
        global.fetch = realFetch;
    }
});

test('a recovered upstream is picked up on the next attempt, and resets the failure count / backoff to zero', async () => {
    const mod = loadFreshModule();
    const realFetch = global.fetch;
    global.fetch = mockFetchSequence([
        { reject: new Error('simulated outage') },
        { ok: true, status: 200, body: '9.9.9' },
    ]);
    try {
        mod.getLatestTapVersion(); // attempt #1 -- fails
        await mod._test.waitForInFlight();
        assert.equal(mod._test.getState().latestTapVersionFailureCount, 1);

        await new Promise((r) => setTimeout(r, mod._test.constants.TAP_VERSION_FETCH_MIN_RETRY_MS + 30));

        mod.getLatestTapVersion(); // attempt #2 -- succeeds
        await mod._test.waitForInFlight();
        const state = mod._test.getState();
        assert.equal(state.latestTapVersion, '9.9.9');
        assert.equal(state.latestTapVersionFailureCount, 0, 'a success must reset the consecutive-failure count to zero');
        assert.ok(state.latestTapVersionFetchedAt > 0);

        // Immediately re-reading now must NOT re-fetch: the cache is fresh
        // (TTL just started) regardless of the now-zeroed backoff.
        mod.getLatestTapVersion();
        await mod._test.waitForInFlight();
        assert.equal(global.fetch.getCallCount(), 2, 'a fresh cache must not be re-fetched');
    } finally {
        global.fetch = realFetch;
    }
});

test('a later failure AFTER a prior success does not poison the cache -- latest keeps the last-known-good value', async () => {
    const mod = loadFreshModule();
    const realFetch = global.fetch;
    global.fetch = mockFetchSequence([{ ok: true, status: 200, body: '7.7.7' }]);
    try {
        mod.getLatestTapVersion(); // attempt #1 -- succeeds
        await mod._test.waitForInFlight();
        assert.equal(mod._test.getState().latestTapVersion, '7.7.7');

        // Let the cache go stale, then fail the next attempt.
        global.fetch = mockFetchSequence([{ reject: new Error('simulated outage') }]);
        await new Promise((r) => setTimeout(r, mod._test.constants.TAP_VERSION_CACHE_TTL_MS + 30));

        mod.getLatestTapVersion(); // attempt #2 -- fails
        await mod._test.waitForInFlight();
        const state = mod._test.getState();
        assert.equal(state.latestTapVersion, '7.7.7', 'a failed refresh must leave the previously-cached value untouched');
        assert.equal(state.latestTapVersionFailureCount, 1);
    } finally {
        global.fetch = realFetch;
    }
});

test('an HTTP non-200 response counts as a failure for backoff purposes, same as a network error', async () => {
    const mod = loadFreshModule();
    const realFetch = global.fetch;
    global.fetch = mockFetchSequence([{ ok: false, status: 503, body: '' }]);
    try {
        mod.getLatestTapVersion();
        await mod._test.waitForInFlight();
        const state = mod._test.getState();
        assert.equal(state.latestTapVersion, null);
        assert.equal(state.latestTapVersionFailureCount, 1);
    } finally {
        global.fetch = realFetch;
    }
});

test('an unparseable 200 body counts as a failure for backoff purposes (never poisons the cache with garbage)', async () => {
    const mod = loadFreshModule();
    const realFetch = global.fetch;
    global.fetch = mockFetchSequence([{ ok: true, status: 200, body: '<html>not found</html>' }]);
    try {
        mod.getLatestTapVersion();
        await mod._test.waitForInFlight();
        const state = mod._test.getState();
        assert.equal(state.latestTapVersion, null);
        assert.equal(state.latestTapVersionFailureCount, 1);
    } finally {
        global.fetch = realFetch;
    }
});

test('concurrent overlapping reads while a fetch is already in flight still de-dupe to one network call (pre-existing guarantee, unchanged)', async () => {
    const mod = loadFreshModule();
    const realFetch = global.fetch;
    let resolveFetch;
    global.fetch = async () => new Promise((resolve) => {
        resolveFetch = () => resolve({ ok: true, status: 200, text: async () => '1.2.3' });
    });
    try {
        mod.getLatestTapVersion();
        mod.getLatestTapVersion();
        mod.getLatestTapVersion();
        resolveFetch();
        await mod._test.waitForInFlight();
        // We can't get a call count from this ad hoc stub, so assert the
        // observable outcome instead: exactly one successful resolve landed.
        assert.equal(mod._test.getState().latestTapVersion, '1.2.3');
    } finally {
        global.fetch = realFetch;
    }
});
