//
//  xaca-1154-006-kiosk-enable-exit-movement-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1154 subitem 006 -- jsdom coverage for public/shared/js/lcars-kiosk.js:
 *
 *   (a) enable/disable persistence (isEnabled()/setEnabled(), the
 *       'lcars-kiosk-enabled' localStorage key, the literal-string read
 *       that avoids the classic `Boolean("false") === true` trap)
 *   (b) init() gating (the fail-closed choke point) -- plus a lightweight
 *       characterization check on the two dashboard app.js call sites'
 *       defense-in-depth guard
 *   (c) the exit-event matrix (KIOSK_EXIT_EVENTS_IMMEDIATE /
 *       KIOSK_EXIT_EVENTS_MOVEMENT) -- this is the behaviour the subitem
 *       is named for. Includes a regression guard proving the matrix
 *       fails against the pre-fix 4-event handler
 *       (['click','mousedown','keydown','touchstart']).
 *   (d) the movement-accumulation threshold, the gap-reset window, and the
 *       _kioskMoveAccumEventType latch that stops a browser's paired
 *       pointermove+mousemove events (same physical motion, same deltas,
 *       ~1-3ms apart) from being double-counted and silently halving the
 *       effective threshold.
 *   (e) the exit-restart resurrection guard: exitKioskMode() only
 *       restarts idle monitoring when `isEnabled()` is also true, so a
 *       manual kiosk entry (LCARS_KIOSK.enter() / the #kiosk-enter-btn
 *       FAB) taken while the preference is OFF does not resurrect idle
 *       monitoring and silently re-seize the dashboard later.
 *
 * (d) and (e) had ZERO test coverage before this file.
 *
 * Every behaviour below is proven falsifiable: either by asserting the
 * inverse first (a throwing assert.throws around the wrong answer), or --
 * for the five regressions this subitem exists to catch -- by running the
 * exact same assertion against an intentionally-mutated IN-MEMORY copy of
 * the module source (never the file on disk) that reproduces the bug the
 * assertion targets, and confirming THAT run fails. Mutator functions
 * throw loudly if their target text is not found, so a future refactor
 * that changes the mutated shape fails this file instead of silently
 * testing nothing.
 *
 * Harness technique (movement events, the 100ms exit-handler attach
 * delay, and the timer-leak footgun from LCARS_KIOSK.enter()) borrowed
 * from two scratchpad probes built earlier in this session
 * (smoke.js / dblcount.js) -- reused here as a pattern, not imported.
 * jsdom-in-this-repo house style follows
 * tests/xaca-1060-008-machine-filter-jsdom.test.js.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');
const KIOSK_REL_PATH = 'shared/js/lcars-kiosk.js';
const KIOSK_ABS_PATH = path.join(PUBLIC_ROOT, KIOSK_REL_PATH);
const KIOSK_ENABLED_STORAGE_KEY = 'lcars-kiosk-enabled';

const DASHBOARD_APP_FILES = [
    'lcars2/js/lcars-fleet-dashboard-app.js',
    'lcars/js/lcars-dashboard-app.js',
];

// ============================================================================
// Harness
// ============================================================================

function loadKioskSource() {
    return fs.readFileSync(KIOSK_ABS_PATH, 'utf8');
}

// Loads a FRESH copy of lcars-kiosk.js into a brand-new jsdom window/document.
// Optional `mutate(src) => src` intentionally breaks the shipped source
// IN MEMORY ONLY (the file on disk is never touched) to prove a test would
// have caught the regression it targets.
function freshKiosk(mutate) {
    const raw = loadKioskSource();
    const src = mutate ? mutate(raw) : raw;
    const dom = new JSDOM(
        '<!doctype html><body><button id="kiosk-enter-btn"></button></body>',
        { runScripts: 'outside-only', url: 'https://lcars-test.local/' }
    );
    const window = dom.window;
    window.eval(src);
    if (!window.LCARS_KIOSK) {
        throw new Error('freshKiosk: window.LCARS_KIOSK did not attach -- mutation broke module load');
    }
    return { dom, window, document: window.document, K: window.LCARS_KIOSK };
}

// LCARS_KIOSK.enter() leaves a rotation setInterval running, and
// startIdleMonitoring() leaves an idle setTimeout pending -- an
// un-torn-down instance hangs `node --test` indefinitely (reproduced
// once already while building this file's scratchpad prior art).
function teardown(instance) {
    try { instance.K.destroy(); } catch (e) { /* best effort */ }
    try { instance.window.close(); } catch (e) { /* best effort */ }
}

function wait(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

// A generic Event carries every property the kiosk handlers actually read
// (`.type`, and optionally `.key`/`.movementX`/`.movementY` defined below)
// without depending on jsdom shipping real PointerEvent/WheelEvent/
// TouchEvent constructors for every event name in the exit matrix.
function immediateEvent(window, type, key) {
    const ev = new window.Event(type, { bubbles: true, cancelable: true });
    if (key !== undefined) {
        Object.defineProperty(ev, 'key', { value: key, configurable: true });
    }
    return ev;
}

function moveEvent(window, type, dx, dy) {
    const ev = new window.Event(type, { bubbles: true, cancelable: true });
    Object.defineProperty(ev, 'movementX', { value: dx, configurable: true });
    Object.defineProperty(ev, 'movementY', { value: dy, configurable: true });
    return ev;
}

// jsdom's window.localStorage is Proxy-backed (confirmed empirically: shadowing
// getItem/setItem via Object.defineProperty(window.localStorage, ...) reports
// success but the override is silently discarded -- reads/writes keep hitting
// the real implementation underneath). Replacing the whole `localStorage`
// property on window with a plain object sidesteps the proxy entirely and is
// the only override that actually takes effect.
function installFakeLocalStorage(window, opts) {
    opts = opts || {};
    const store = { value: opts.initial === undefined ? null : opts.initial };
    const fake = {
        getItem: opts.getItemThrows
            ? function () { throw new Error(opts.getItemThrows); }
            : function () { return store.value; },
        setItem: opts.setItemThrows
            ? function () { throw new Error(opts.setItemThrows); }
            : function (key, val) { store.value = val; },
        removeItem: function () { store.value = null; },
    };
    Object.defineProperty(window, 'localStorage', { value: fake, configurable: true, writable: true });
    return fake;
}

// Enters kiosk mode and waits past the 100ms exit-handler attach delay
// (_setupKioskExitHandler) so a dispatched event afterward is actually
// observed by the exit listeners.
async function enterAndArm(instance) {
    instance.K.enter();
    assert.equal(instance.K.isActive(), true, 'setup: enter() must activate kiosk');
    await wait(150);
}

// ============================================================================
// Mutators -- each throws loudly if its target text is not found, rather
// than silently no-op'ing and turning its regression guard vacuous.
// ============================================================================

function mutateNaiveIsEnabled(src) {
    const re = /function isEnabled\(\) \{[\s\S]*?\n    \}/;
    if (!re.test(src)) throw new Error('mutateNaiveIsEnabled: isEnabled() shape changed, update this test');
    return src.replace(
        re,
        "function isEnabled() {\n" +
        "        var stored = _lsGet(KIOSK_ENABLED_STORAGE_KEY);\n" +
        "        if (stored === null) return KIOSK_CONFIG.enabled;\n" +
        "        return Boolean(stored); // BUG: Boolean('false') === true\n" +
        "    }"
    );
}

function mutateRemoveLsGetTryCatch(src) {
    const re = /function _lsGet\(key\) \{[\s\S]*?\n    \}/;
    if (!re.test(src)) throw new Error('mutateRemoveLsGetTryCatch: _lsGet() shape changed, update this test');
    return src.replace(re, 'function _lsGet(key) {\n        return localStorage.getItem(key);\n    }');
}

function mutateRemoveInitGate(src) {
    const re = /function init\(\) \{[\s\S]*?\n    \}/;
    if (!re.test(src)) throw new Error('mutateRemoveInitGate: init() shape changed, update this test');
    return src.replace(re, 'function init() {\n        startIdleMonitoring();\n    }');
}

function mutatePreFix4EventHandler(src) {
    let out = src;
    out = out.replace(
        /const KIOSK_EXIT_EVENTS_IMMEDIATE = \[[^\]]*\];/,
        "const KIOSK_EXIT_EVENTS_IMMEDIATE = ['click', 'mousedown', 'keydown', 'touchstart'];"
    );
    out = out.replace(
        /const KIOSK_EXIT_EVENTS_MOVEMENT = \[[^\]]*\];/,
        'const KIOSK_EXIT_EVENTS_MOVEMENT = [];'
    );
    if (out === src) throw new Error('mutatePreFix4EventHandler: exit-event constants shape changed, update this test');
    return out;
}

function mutateRemoveMovementLatch(src) {
    const re = /if \(_kioskMoveAccumEventType === null\) \{[\s\S]*?\n(\s*)const now = Date\.now\(\);/;
    const m = src.match(re);
    if (!m) throw new Error('mutateRemoveMovementLatch: latch code shape changed, update this test');
    return src.replace(re, m[1] + 'const now = Date.now();');
}

function mutateRemoveResurrectionGuard(src) {
    const needle = 'if (!(options && options.skipRestart) && isEnabled()) {';
    if (src.indexOf(needle) === -1) throw new Error('mutateRemoveResurrectionGuard: exitKioskMode restart condition changed, update this test');
    return src.replace(needle, 'if (!(options && options.skipRestart)) {');
}

// ============================================================================
// (a) Enable/disable persistence
// ============================================================================

test('(a) isEnabled() defaults to true with nothing stored', () => {
    const k = freshKiosk();
    try {
        assert.equal(k.window.localStorage.getItem(KIOSK_ENABLED_STORAGE_KEY), null, 'setup: nothing must be stored yet');
        assert.throws(() => assert.equal(k.K.isEnabled(), false), assert.AssertionError, 'inverted assertion must fail -- proves this is not a vacuous check');
        assert.equal(k.K.isEnabled(), true);
    } finally { teardown(k); }
});

test('(a) setEnabled() round-trips both values through isEnabled() and localStorage', () => {
    const k = freshKiosk();
    try {
        k.K.setEnabled(true);
        assert.equal(k.window.localStorage.getItem(KIOSK_ENABLED_STORAGE_KEY), 'true');
        assert.throws(() => assert.equal(k.K.isEnabled(), false), assert.AssertionError);
        assert.equal(k.K.isEnabled(), true);

        k.K.setEnabled(false);
        assert.equal(k.window.localStorage.getItem(KIOSK_ENABLED_STORAGE_KEY), 'false');
        assert.throws(() => assert.equal(k.K.isEnabled(), true), assert.AssertionError);
        assert.equal(k.K.isEnabled(), false);
    } finally { teardown(k); }
});

function assertFalseStringDisables(k) {
    k.window.localStorage.setItem(KIOSK_ENABLED_STORAGE_KEY, 'false');
    assert.equal(k.K.isEnabled(), false, 'stored "false" must resolve to disabled, not truthy-coerced');
}

test('(a) REGRESSION GUARD: the stored string "false" resolves to disabled, not truthy-coerced', () => {
    const k = freshKiosk();
    try { assertFalseStringDisables(k); } finally { teardown(k); }
});

test('(a) harness self-check: the "false"-string guard genuinely fails against a naive Boolean(stored) implementation', () => {
    const k = freshKiosk(mutateNaiveIsEnabled);
    try {
        assert.throws(
            () => assertFalseStringDisables(k),
            assert.AssertionError,
            'Boolean("false") === true must trip this exact assertion -- if it did not, the guard above is not testing anything'
        );
    } finally { teardown(k); }
});

test('(a) a garbage stored value ("banana") falls back to the in-memory default', () => {
    const k = freshKiosk();
    try {
        k.window.localStorage.setItem(KIOSK_ENABLED_STORAGE_KEY, 'banana');
        assert.throws(() => assert.equal(k.K.isEnabled(), false), assert.AssertionError);
        assert.equal(k.K.isEnabled(), k.K.config.enabled, 'garbage must fall back to KIOSK_CONFIG.enabled');
    } finally { teardown(k); }
});

test('(a) setEnabled() is idempotent in both directions', () => {
    const k = freshKiosk();
    try {
        assert.doesNotThrow(() => { k.K.setEnabled(false); k.K.setEnabled(false); });
        assert.throws(() => assert.equal(k.K.isEnabled(), true), assert.AssertionError);
        assert.equal(k.K.isEnabled(), false);

        assert.doesNotThrow(() => { k.K.setEnabled(true); k.K.setEnabled(true); });
        assert.throws(() => assert.equal(k.K.isEnabled(), false), assert.AssertionError);
        assert.equal(k.K.isEnabled(), true);
    } finally { teardown(k); }
});

test('(a) a throwing localStorage.getItem degrades isEnabled() to the default instead of throwing', () => {
    const k = freshKiosk();
    try {
        installFakeLocalStorage(k.window, { getItemThrows: 'SecurityError: storage disabled' });
        let result;
        assert.doesNotThrow(() => { result = k.K.isEnabled(); }, 'isEnabled() must not propagate a localStorage throw');
        assert.equal(result, k.K.config.enabled);
    } finally { teardown(k); }
});

test('(a) a throwing localStorage.setItem degrades setEnabled() instead of throwing', () => {
    const k = freshKiosk();
    try {
        installFakeLocalStorage(k.window, { setItemThrows: 'QuotaExceededError' });
        assert.doesNotThrow(() => k.K.setEnabled(true), 'setEnabled() must not propagate a localStorage write throw');
        assert.equal(k.K.isActive(), false, 'sanity: setEnabled(true) alone does not enter kiosk');
    } finally { teardown(k); }
});

test('(a) harness self-check: the localStorage-throw guard genuinely fails if _lsGet loses its try/catch', () => {
    const k = freshKiosk(mutateRemoveLsGetTryCatch);
    try {
        installFakeLocalStorage(k.window, { getItemThrows: 'SecurityError: storage disabled' });
        assert.throws(() => k.K.isEnabled(), /SecurityError/, 'without the try/catch, isEnabled() must propagate the storage throw');
    } finally { teardown(k); }
});

// ============================================================================
// (b) init() gating
// ============================================================================

test('(b) init() does NOT start idle monitoring when the preference resolves false', async () => {
    const k = freshKiosk();
    try {
        k.K.setEnabled(false);
        k.K.config.idleTimeout = 30;
        k.K.init();
        await wait(80);
        assert.equal(k.K.isActive(), false, 'init() must be a no-op when the preference is off');
    } finally { teardown(k); }
});

test('(b) init() DOES start idle monitoring when the preference resolves true', async () => {
    const k = freshKiosk();
    try {
        k.K.setEnabled(true);
        k.K.config.idleTimeout = 30;
        k.K.init();
        await wait(80);
        assert.equal(k.K.isActive(), true, 'init() must start idle monitoring when the preference is on');
    } finally { teardown(k); }
});

test('(b) REGRESSION GUARD: without the internal gate, init() starts idle monitoring even when the preference is off', async () => {
    const k = freshKiosk(mutateRemoveInitGate);
    try {
        k.K.setEnabled(false);
        k.K.config.idleTimeout = 30;
        k.K.init();
        await wait(80);
        assert.equal(k.K.isActive(), true, 'ungated init() must start monitoring regardless of preference -- proving the "off" test above is a real guard');
    } finally { teardown(k); }
});

test('(b) setEnabled(true) starts idle monitoring directly, NOT gated through isEnabled()/init() (a stale/failed persistence write must not silently no-op the toggle-ON action)', async () => {
    const k = freshKiosk();
    try {
        // Preference currently reads 'false' in storage, and the persistence
        // WRITE is broken -- isEnabled() will keep reading 'false' no matter
        // what setEnabled() does.
        installFakeLocalStorage(k.window, { initial: 'false', setItemThrows: 'QuotaExceededError' });
        k.K.config.idleTimeout = 30;

        k.K.setEnabled(true);
        assert.equal(k.K.isEnabled(), false, 'setup: the write failed, so isEnabled() still reads the stale stored "false"');

        await wait(80);
        assert.equal(k.K.isActive(), true, 'setEnabled(true) must start idle monitoring directly -- it must not re-derive "should I start?" from isEnabled(), which is stale here');
    } finally { teardown(k); }
});

for (const relPath of DASHBOARD_APP_FILES) {
    test(`(b) call-site defense-in-depth: ${relPath} gates LCARS_KIOSK.init() behind LCARS_KIOSK.isEnabled()`, () => {
        // Characterization on source text, not full execution: these app
        // files register a DOMContentLoaded handler at module scope that
        // calls fetch() against a nonexistent host plus two unref'd
        // setInterval() timers. tests/xaca-1060-008-machine-filter-jsdom
        // .test.js documents (and its harness works around) that executing
        // them without carefully avoiding that path hangs `node --test`
        // indefinitely. Building that same fetch-mocking machinery here
        // would be disproportionate for a "defense in depth" call site
        // whose real safety net -- init()'s own internal gate -- is already
        // exercised directly and exhaustively above.
        const src = fs.readFileSync(path.join(PUBLIC_ROOT, relPath), 'utf8');
        const guardedCallRe = /LCARS_KIOSK\s*&&\s*LCARS_KIOSK\.isEnabled\(\)\s*\)\s*\{\s*LCARS_KIOSK\.init\(\);/;
        assert.match(src, guardedCallRe, `${relPath} must call LCARS_KIOSK.init() only inside an LCARS_KIOSK.isEnabled() guard`);

        // Fail-first proof: an UNguarded call site must not match this pattern.
        const unguarded = 'if (window.LCARS_KIOSK) {\n            LCARS_KIOSK.init();\n        }';
        assert.equal(guardedCallRe.test(unguarded), false, 'sanity: an unguarded call site must not match the guarded pattern');
    });
}

// ============================================================================
// (c) Exit-event matrix -- the behaviour this subitem is named for.
// ============================================================================

const IMMEDIATE_EVENTS_TO_VERIFY = ['click', 'mousedown', 'pointerdown', 'keydown', 'touchstart', 'touchend', 'wheel'];

for (const type of IMMEDIATE_EVENTS_TO_VERIFY) {
    test(`(c) "${type}" exits kiosk mode immediately`, async () => {
        const k = freshKiosk();
        try {
            await enterAndArm(k);
            const key = type === 'keydown' ? 'a' : undefined; // any non-arrow key
            k.document.dispatchEvent(immediateEvent(k.window, type, key));
            assert.equal(k.K.isActive(), false, `${type} must exit kiosk mode`);
        } finally { teardown(k); }
    });
}

test('(c) "scroll" NEVER exits kiosk mode, no matter how many fire', async () => {
    const k = freshKiosk();
    try {
        await enterAndArm(k);
        for (let i = 0; i < 20; i++) {
            k.document.dispatchEvent(immediateEvent(k.window, 'scroll'));
        }
        assert.equal(k.K.isActive(), true, 'scroll must never exit kiosk, even repeated 20x');
    } finally { teardown(k); }
});

test('(c) ArrowLeft / ArrowRight navigate and do not exit kiosk mode', async () => {
    const k = freshKiosk();
    try {
        await enterAndArm(k);
        k.document.dispatchEvent(immediateEvent(k.window, 'keydown', 'ArrowLeft'));
        assert.equal(k.K.isActive(), true, 'ArrowLeft must not exit kiosk');
        k.document.dispatchEvent(immediateEvent(k.window, 'keydown', 'ArrowRight'));
        assert.equal(k.K.isActive(), true, 'ArrowRight must not exit kiosk');
    } finally { teardown(k); }
});

test('(c) a non-arrow keydown DOES exit kiosk mode', async () => {
    const k = freshKiosk();
    try {
        await enterAndArm(k);
        k.document.dispatchEvent(immediateEvent(k.window, 'keydown', 'Escape'));
        assert.equal(k.K.isActive(), false);
    } finally { teardown(k); }
});

test('(c) REGRESSION GUARD: pointerdown/touchend/wheel exit-coverage genuinely fails against the pre-fix 4-event handler', async () => {
    const missingFromOldHandler = ['pointerdown', 'touchend', 'wheel'];
    for (const type of missingFromOldHandler) {
        const k = freshKiosk(mutatePreFix4EventHandler);
        try {
            await enterAndArm(k);
            k.document.dispatchEvent(immediateEvent(k.window, type));
            assert.throws(
                () => assert.equal(k.K.isActive(), false, `${type} must exit kiosk mode`),
                assert.AssertionError,
                `${type} must be an observable gap in the pre-fix 4-event handler for the coverage above to mean anything`
            );
        } finally { teardown(k); }
    }
});

test('(c) sanity: the pre-fix mutation still exits on its own 4 events (mutation is precise, not indiscriminate)', async () => {
    for (const type of ['click', 'mousedown', 'keydown', 'touchstart']) {
        const k = freshKiosk(mutatePreFix4EventHandler);
        try {
            await enterAndArm(k);
            const key = type === 'keydown' ? 'a' : undefined;
            k.document.dispatchEvent(immediateEvent(k.window, type, key));
            assert.equal(k.K.isActive(), false, `${type} must still exit under the pre-fix 4-event handler`);
        } finally { teardown(k); }
    }
});

// ============================================================================
// (d) Movement threshold + double-count regression -- ZERO prior coverage.
// ============================================================================

test('(d) stationary 0/0 movement events never accumulate, regardless of count', async () => {
    const k = freshKiosk();
    try {
        await enterAndArm(k);
        for (let i = 0; i < 50; i++) {
            k.document.dispatchEvent(moveEvent(k.window, 'pointermove', 0, 0));
            k.document.dispatchEvent(moveEvent(k.window, 'mousemove', 0, 0));
        }
        assert.equal(k.K.isActive(), true, '0/0 noise must never accumulate toward the exit threshold');
    } finally { teardown(k); }
});

test('(d) a single worst-case noise event (hypot(3,3)=4.24px) does not cross the threshold', async () => {
    const k = freshKiosk();
    try {
        await enterAndArm(k);
        k.document.dispatchEvent(moveEvent(k.window, 'pointermove', 3, 3));
        assert.equal(k.K.isActive(), true);
    } finally { teardown(k); }
});

test('(d) the real browser pointermove+mousemove pair does not double-count real motion', async () => {
    const k = freshKiosk();
    try {
        await enterAndArm(k);
        // Two noise pairs = 4 events. Double-counted (no latch): 4 x 4.24 = 16.97px >= 10 -> would exit.
        // Correctly latched: only the 2 "pointermove" events count = 8.49px < 10 -> must stay.
        k.document.dispatchEvent(moveEvent(k.window, 'pointermove', 3, 3));
        k.document.dispatchEvent(moveEvent(k.window, 'mousemove', 3, 3));
        k.document.dispatchEvent(moveEvent(k.window, 'pointermove', 3, 3));
        k.document.dispatchEvent(moveEvent(k.window, 'mousemove', 3, 3));
        assert.equal(k.K.isActive(), true, 'two noise pairs delivered as the real browser pair must NOT cross the threshold');
    } finally { teardown(k); }
});

test('(d) REGRESSION GUARD: without the type latch, the browser pair DOES double-count and exits early', async () => {
    const k = freshKiosk(mutateRemoveMovementLatch);
    try {
        await enterAndArm(k);
        k.document.dispatchEvent(moveEvent(k.window, 'pointermove', 3, 3));
        k.document.dispatchEvent(moveEvent(k.window, 'mousemove', 3, 3));
        k.document.dispatchEvent(moveEvent(k.window, 'pointermove', 3, 3));
        k.document.dispatchEvent(moveEvent(k.window, 'mousemove', 3, 3));
        assert.equal(k.K.isActive(), false, 'without the latch, two noise pairs (16.97px double-counted) must incorrectly cross the threshold -- proving the pair test above is a real regression guard');
    } finally { teardown(k); }
});

test('(d) a genuine deliberate move exits kiosk mode', async () => {
    const k = freshKiosk();
    try {
        await enterAndArm(k);
        k.document.dispatchEvent(moveEvent(k.window, 'pointermove', 15, -2));
        k.document.dispatchEvent(moveEvent(k.window, 'mousemove', 15, -2));
        assert.equal(k.K.isActive(), false, 'a hypot(15,-2)=~15.1px move must exit');
    } finally { teardown(k); }
});

test('(d) sparse drift separated by >250ms (KIOSK_MOVEMENT_GAP_RESET_MS) never accumulates', async () => {
    const k = freshKiosk();
    try {
        await enterAndArm(k);
        for (let i = 0; i < 3; i++) {
            k.document.dispatchEvent(moveEvent(k.window, 'pointermove', 3, 3)); // 4.24px, below threshold alone
            assert.equal(k.K.isActive(), true, `iteration ${i}: single noise event must not exit`);
            await wait(300); // exceeds the 250ms gap-reset window -- next event starts a fresh accumulation window
        }
        assert.equal(k.K.isActive(), true, 'three noise events spaced past the gap-reset window must never accumulate to threshold');
    } finally { teardown(k); }
});

test('(d) a tight burst within the gap-reset window DOES accumulate to the threshold', async () => {
    const k = freshKiosk();
    try {
        await enterAndArm(k);
        // Same 4.24px event, same type, fired back-to-back with no gap.
        k.document.dispatchEvent(moveEvent(k.window, 'pointermove', 3, 3));
        k.document.dispatchEvent(moveEvent(k.window, 'pointermove', 3, 3));
        assert.equal(k.K.isActive(), true, 'two events (8.49px) must still be below the 10px threshold');
        k.document.dispatchEvent(moveEvent(k.window, 'pointermove', 3, 3));
        assert.equal(k.K.isActive(), false, 'three tight-burst events (12.7px) must cross the threshold and exit');
    } finally { teardown(k); }
});

// ============================================================================
// (e) Exit-restart resurrection guard -- ZERO prior coverage.
// ============================================================================

test('(e) manual enter() while the preference is OFF does not resurrect idle monitoring on exit', async () => {
    const k = freshKiosk();
    try {
        k.K.setEnabled(false);
        k.K.config.idleTimeout = 30;
        k.K.enter(); // e.g. LCARS_KIOSK.enter() or the #kiosk-enter-btn FAB -- bypasses the preference
        assert.equal(k.K.isActive(), true, 'setup: manual enter() must activate kiosk regardless of preference');
        await wait(150); // past the 100ms exit-handler attach delay
        k.document.dispatchEvent(immediateEvent(k.window, 'click'));
        assert.equal(k.K.isActive(), false, 'setup: click must exit kiosk');
        await wait(80); // past the (reduced) idleTimeout -- if monitoring resurrected, kiosk re-enters here
        assert.equal(k.K.isActive(), false, 'idle monitoring must NOT have been restarted -- kiosk must stay exited with the preference off');
    } finally { teardown(k); }
});

test('(e) a normal exit WITH the preference on still restarts idle monitoring (does not over-block)', async () => {
    const k = freshKiosk();
    try {
        k.K.setEnabled(true);
        k.K.config.idleTimeout = 30;
        k.K.enter();
        assert.equal(k.K.isActive(), true);
        await wait(150);
        k.document.dispatchEvent(immediateEvent(k.window, 'click'));
        assert.equal(k.K.isActive(), false, 'setup: click must exit kiosk');
        await wait(80); // idle monitoring should have restarted and re-armed
        assert.equal(k.K.isActive(), true, 'idle monitoring must restart when the preference is on, re-entering kiosk after the idle timeout');
    } finally { teardown(k); }
});

test('(e) REGRESSION GUARD: without the isEnabled() term, a manual entry with the preference OFF resurrects idle monitoring on exit', async () => {
    const k = freshKiosk(mutateRemoveResurrectionGuard);
    try {
        k.K.setEnabled(false);
        k.K.config.idleTimeout = 30;
        k.K.enter();
        await wait(150);
        k.document.dispatchEvent(immediateEvent(k.window, 'click'));
        assert.equal(k.K.isActive(), false, 'setup: click must exit kiosk');
        await wait(80);
        assert.equal(k.K.isActive(), true, 'without the isEnabled() guard, idle monitoring resurrects and kiosk seizes the dashboard again -- proving the "off" test above is a real regression guard');
    } finally { teardown(k); }
});
