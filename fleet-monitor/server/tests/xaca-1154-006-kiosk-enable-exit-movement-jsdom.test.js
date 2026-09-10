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

// XACA-1154-017: an engine that never populates movementX/movementY at all
// (typeof !== 'number' -- the cockpit WKWebView is the unverified real-world
// candidate). A plain window.Event carries neither property by default
// (both read as `undefined`), which already matches that condition without
// any extra work; only clientX/clientY need to be defined.
function clientMoveEvent(window, type, clientX, clientY) {
    const ev = new window.Event(type, { bubbles: true, cancelable: true });
    Object.defineProperty(ev, 'clientX', { value: clientX, configurable: true });
    Object.defineProperty(ev, 'clientY', { value: clientY, configurable: true });
    return ev;
}

// XACA-1154-019: a real (same-window, manually dispatched) StorageEvent --
// the native event only ever fires in OTHER same-origin documents, so a
// single-window jsdom test simulating "another tab wrote this" has to
// dispatch it itself, exactly like a real browser would deliver it TO this
// tab (never causing it, by writing locally).
function storageEvent(window, key, newValue) {
    return new window.StorageEvent('storage', {
        key: key,
        newValue: newValue === undefined ? null : newValue,
        storageArea: window.localStorage,
    });
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
    // XACA-1154-017/018 reshaped the movement handler: the gap check (and
    // its `const now = Date.now();`) moved to the TOP of the handler, ahead
    // of the type-latch check, so it can self-heal a latch whose type
    // stopped firing (see the XACA-1154-018 comment in the shipped
    // source). The latch block itself is now immediately followed by
    // `_kioskMoveAccumLastTime = now;` rather than by the now-relocated
    // `const now = Date.now();` this regex used to anchor on.
    const re = /if \(_kioskMoveAccumEventType === null\) \{[\s\S]*?\n(\s*)_kioskMoveAccumLastTime = now;/;
    const m = src.match(re);
    if (!m) throw new Error('mutateRemoveMovementLatch: latch code shape changed, update this test');
    return src.replace(re, m[1] + '_kioskMoveAccumLastTime = now;');
}

function mutateRemoveResurrectionGuard(src) {
    const needle = 'if (!(options && options.skipRestart) && isEnabled()) {';
    if (src.indexOf(needle) === -1) throw new Error('mutateRemoveResurrectionGuard: exitKioskMode restart condition changed, update this test');
    return src.replace(needle, 'if (!(options && options.skipRestart)) {');
}

// XACA-1154-016: reproduces the pre-hoist attach/remove drift by giving
// stopIdleMonitoring() a DIVERGED inline copy of the idle event list, one
// event ('scroll') short of what startIdleMonitoring() (still using the
// real, hoisted KIOSK_IDLE_EVENTS) actually attached.
function mutateDivergedStopIdleEvents(src) {
    const needle = "function stopIdleMonitoring() {\n        if (_boundResetIdleTimer) {\n            KIOSK_IDLE_EVENTS.forEach(function(eventName) {";
    if (src.indexOf(needle) === -1) throw new Error('mutateDivergedStopIdleEvents: stopIdleMonitoring() shape changed, update this test');
    return src.replace(
        needle,
        "function stopIdleMonitoring() {\n        if (_boundResetIdleTimer) {\n            ['mousemove', 'mousedown', 'keypress', 'keydown', 'touchstart', 'click'].forEach(function(eventName) {"
    );
}

// XACA-1154-020: strips 'scroll' from the shipped KIOSK_IDLE_EVENTS list,
// reproducing what applying the EXIT set's noise evidence to the IDLE list
// would have looked like -- the exact "fix" XACA-1154-020 explains why NOT
// to make.
function mutateIdleListWithoutScroll(src) {
    const needle = "const KIOSK_IDLE_EVENTS = ['mousemove', 'mousedown', 'keypress', 'keydown', 'touchstart', 'scroll', 'click'];";
    if (src.indexOf(needle) === -1) throw new Error('mutateIdleListWithoutScroll: KIOSK_IDLE_EVENTS shape changed, update this test');
    return src.replace(needle, "const KIOSK_IDLE_EVENTS = ['mousemove', 'mousedown', 'keypress', 'keydown', 'touchstart', 'click'];");
}

// XACA-1154-017: removes the clientX/clientY fallback entirely, reverting
// dx/dy determination to the pre-fix `e.movementX || 0` shape -- on an
// engine that never populates movementX/movementY, this always reads 0/0
// and every movement event hits the "pure noise" early return.
function mutateRemoveClientFallback(src) {
    const re = /let dx, dy;\n[\s\S]*?\n(\s*)\/\/ Latch onto the first movement event type/;
    const m = src.match(re);
    if (!m) throw new Error('mutateRemoveClientFallback: dx/dy determination shape changed, update this test');
    const indent = m[1];
    return src.replace(
        re,
        'let dx, dy;\n' +
        indent + 'dx = e.movementX || 0;\n' +
        indent + 'dy = e.movementY || 0;\n' +
        indent + 'if (dx === 0 && dy === 0) return;\n\n' +
        indent + '// Latch onto the first movement event type'
    );
}

// XACA-1154-018: leaves the gap-reset zeroing the distance accumulator (and,
// post-XACA-1154-017, the clientX/clientY fallback baseline) but stops it
// from clearing the latched event type -- the exact pre-fix shape, where a
// latch whose type stopped firing could never self-heal.
function mutateGapResetDoesNotClearLatch(src) {
    const needle =
        'if (now - _kioskMoveAccumLastTime > KIOSK_MOVEMENT_GAP_RESET_MS) {\n' +
        '                _kioskMoveAccumDist = 0;\n' +
        '                _kioskMoveAccumEventType = null;\n' +
        '                _kioskMovePrevClientX = null;\n' +
        '                _kioskMovePrevClientY = null;\n' +
        '            }';
    if (src.indexOf(needle) === -1) throw new Error('mutateGapResetDoesNotClearLatch: gap-reset block shape changed, update this test');
    return src.replace(
        needle,
        'if (now - _kioskMoveAccumLastTime > KIOSK_MOVEMENT_GAP_RESET_MS) {\n' +
        '                _kioskMoveAccumDist = 0;\n' +
        '                _kioskMovePrevClientX = null;\n' +
        '                _kioskMovePrevClientY = null;\n' +
        '            }'
    );
}

// XACA-1154-019: strips the entire cross-tab 'storage' listener.
function mutateRemoveStorageListener(src) {
    const re = /\n {4}window\.addEventListener\('storage', function\(e\) \{[\s\S]*?\n {4}\}\);\n/;
    if (!re.test(src)) throw new Error('mutateRemoveStorageListener: storage listener shape changed, update this test');
    return src.replace(re, '\n');
}

// XACA-1154-021: removes the isKioskActive gate from _applyKioskEnabled(),
// reverting setEnabled(true)/the storage listener's enable path to
// unconditionally calling startIdleMonitoring() even while kiosk is active.
function mutateRemoveSetEnabledGate(src) {
    const needle =
        '            if (!isKioskActive) {\n' +
        '                startIdleMonitoring();\n' +
        '            }\n' +
        '        } else {\n' +
        '            _disableKiosk();\n' +
        '        }\n' +
        '    }';
    if (src.indexOf(needle) === -1) throw new Error('mutateRemoveSetEnabledGate: _applyKioskEnabled() shape changed, update this test');
    return src.replace(
        needle,
        '            startIdleMonitoring();\n' +
        '        } else {\n' +
        '            _disableKiosk();\n' +
        '        }\n' +
        '    }'
    );
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

// ============================================================================
// (f) XACA-1154-016 -- hoisted idle event list (KIOSK_IDLE_EVENTS)
// ============================================================================

test('(f) stopIdleMonitoring() removes every event startIdleMonitoring() attached, including "scroll"', async () => {
    const k = freshKiosk();
    try {
        k.K.config.idleTimeout = 30;
        k.K.setEnabled(true);
        k.K.init();
        await wait(10);
        k.K.destroy(); // -> _disableKiosk() -> stopIdleMonitoring()

        // If a "scroll" listener leaked (attach/remove list drift), this
        // dispatch would call the still-attached resetIdleTimer and silently
        // resurrect the idle timer even though monitoring was just stopped.
        k.document.dispatchEvent(immediateEvent(k.window, 'scroll'));
        await wait(80); // past idleTimeout, if a timer got resurrected it would fire here
        assert.equal(k.K.isActive(), false, 'a "scroll" event after stopIdleMonitoring() must not resurrect idle monitoring / auto-activate kiosk');
    } finally { teardown(k); }
});

test('(f) REGRESSION GUARD: a diverged stop-side event list leaks the "scroll" listener and resurrects idle monitoring', async () => {
    const k = freshKiosk(mutateDivergedStopIdleEvents);
    try {
        k.K.config.idleTimeout = 30;
        k.K.setEnabled(true);
        k.K.init();
        await wait(10);
        k.K.destroy();

        k.document.dispatchEvent(immediateEvent(k.window, 'scroll'));
        await wait(80);
        assert.equal(k.K.isActive(), true, 'with a diverged stop-side list missing "scroll", the leaked listener must resurrect idle monitoring -- proving the test above is a real regression guard for the attach/remove drift XACA-1154-016 eliminated');
    } finally { teardown(k); }
});

// ============================================================================
// (g) XACA-1154-017 -- clientX/clientY movement fallback
// ============================================================================

test('(g) clientX/clientY fallback lets movement exit kiosk when movementX/movementY are absent', async () => {
    const k = freshKiosk();
    try {
        await enterAndArm(k);
        k.document.dispatchEvent(clientMoveEvent(k.window, 'pointermove', 100, 100)); // first sample: baseline only
        assert.equal(k.K.isActive(), true, 'the first fallback sample must establish the baseline only, not exit');
        k.document.dispatchEvent(clientMoveEvent(k.window, 'pointermove', 115, 100)); // dx=15 -> hypot=15px >= 10px threshold
        assert.equal(k.K.isActive(), false, 'a real clientX/clientY delta via the fallback must exit kiosk when movementX/Y are absent');
    } finally { teardown(k); }
});

test('(g) the first fallback sample after a reset never contributes distance, regardless of the clientX/clientY value', async () => {
    const k = freshKiosk();
    try {
        await enterAndArm(k);
        k.document.dispatchEvent(clientMoveEvent(k.window, 'pointermove', 9999, 9999));
        assert.equal(k.K.isActive(), true, 'a baseline-establishing sample must never exit no matter how large clientX/clientY are -- there is no previous point yet to diff against');
    } finally { teardown(k); }
});

test('(g) real movementX/Y === 0 events are NOT diverted through the clientX/clientY fallback', async () => {
    const k = freshKiosk();
    try {
        await enterAndArm(k);
        // movementX/Y ARE present (real 0s) even though clientX/clientY are
        // large -- the native branch must win; this must stay pure noise.
        const ev = moveEvent(k.window, 'pointermove', 0, 0);
        Object.defineProperty(ev, 'clientX', { value: 9999, configurable: true });
        Object.defineProperty(ev, 'clientY', { value: 9999, configurable: true });
        k.document.dispatchEvent(ev);
        assert.equal(k.K.isActive(), true, 'movementX/Y === 0 must stay legitimate stationary noise even when clientX/Y are present and large');
    } finally { teardown(k); }
});

test('(g) REGRESSION GUARD: without the clientX/clientY fallback, movement can never exit kiosk when movementX/movementY are absent', async () => {
    const k = freshKiosk(mutateRemoveClientFallback);
    try {
        await enterAndArm(k);
        k.document.dispatchEvent(clientMoveEvent(k.window, 'pointermove', 100, 100));
        k.document.dispatchEvent(clientMoveEvent(k.window, 'pointermove', 400, 400)); // a huge, unmistakably real 424px move
        assert.equal(k.K.isActive(), true, 'without the fallback, movementX/Y-absent engines must be permanently unable to exit kiosk via movement -- proving the tests above are real regression guards, and this is exactly the "load-bearing half silently inert" risk XACA-1154-017 exists to close');
    } finally { teardown(k); }
});

// ============================================================================
// (h) XACA-1154-018 -- self-healing latch on gap reset
// ============================================================================

test('(h) a latched type that stops firing self-heals via the gap reset instead of permanently blocking exit', async () => {
    const k = freshKiosk();
    try {
        await enterAndArm(k);
        // Latches onto 'pointermove' with a single noise-magnitude event
        // (4.24px, below the 10px threshold alone).
        k.document.dispatchEvent(moveEvent(k.window, 'pointermove', 3, 3));
        assert.equal(k.K.isActive(), true, 'setup: single 4.24px event must not exit yet');

        // 'pointermove' never fires again; only 'mousemove' arrives, after a
        // gap exceeding KIOSK_MOVEMENT_GAP_RESET_MS (250ms).
        await wait(300);
        k.document.dispatchEvent(moveEvent(k.window, 'mousemove', 15, -2)); // ~15.1px, alone crosses the threshold
        assert.equal(k.K.isActive(), false, 'a real "mousemove" event arriving >250ms after the latched "pointermove" type went quiet must self-heal the latch and exit kiosk');
    } finally { teardown(k); }
});

test('(h) REGRESSION GUARD: without clearing the latch on a gap reset, a stale latch permanently blocks exit from the other type', async () => {
    const k = freshKiosk(mutateGapResetDoesNotClearLatch);
    try {
        await enterAndArm(k);
        k.document.dispatchEvent(moveEvent(k.window, 'pointermove', 3, 3));
        assert.equal(k.K.isActive(), true, 'setup: latches onto "pointermove"');
        await wait(300);
        k.document.dispatchEvent(moveEvent(k.window, 'mousemove', 15, -2));
        assert.equal(k.K.isActive(), true, 'without clearing the latch on the gap reset, "mousemove" must stay permanently rejected by the stale "pointermove" latch -- proving the test above is a real regression guard for the exact bug XACA-1154-018 describes');
    } finally { teardown(k); }
});

// ============================================================================
// (i) XACA-1154-019 -- cross-tab 'storage' preference sync
// ============================================================================

test('(i) a "storage" event to newValue "false" stops idle monitoring in this tab', async () => {
    const k = freshKiosk();
    try {
        k.K.setEnabled(true);
        k.K.config.idleTimeout = 30;
        k.K.init();
        await wait(80);
        assert.equal(k.K.isActive(), true, 'setup: idle monitoring auto-activated kiosk');

        // A same-window write never fires 'storage' locally -- only the event
        // itself needs to be simulated, matching what the browser delivers
        // FROM another tab's write (never caused by this tab's own write).
        k.window.localStorage.setItem(KIOSK_ENABLED_STORAGE_KEY, 'false');
        k.window.dispatchEvent(storageEvent(k.window, KIOSK_ENABLED_STORAGE_KEY, 'false'));

        assert.equal(k.K.isActive(), false, 'a cross-tab disable via "storage" must stop/exit kiosk in this tab too');
        await wait(80);
        assert.equal(k.K.isActive(), false, 'idle monitoring must stay off after the cross-tab disable');
    } finally { teardown(k); }
});

test('(i) a "storage" event to newValue "true" re-arms idle monitoring in this tab', async () => {
    const k = freshKiosk();
    try {
        k.K.setEnabled(false);
        k.K.config.idleTimeout = 30;

        k.window.localStorage.setItem(KIOSK_ENABLED_STORAGE_KEY, 'true');
        k.window.dispatchEvent(storageEvent(k.window, KIOSK_ENABLED_STORAGE_KEY, 'true'));

        await wait(80);
        assert.equal(k.K.isActive(), true, 'a cross-tab enable via "storage" must (re)arm idle monitoring in this tab');
    } finally { teardown(k); }
});

test('(i) a "storage" event reflects onto #kiosk-mode-toggle when the element is present', () => {
    const k = freshKiosk();
    try {
        const toggle = k.document.createElement('input');
        toggle.type = 'checkbox';
        toggle.id = 'kiosk-mode-toggle';
        toggle.checked = true;
        k.document.body.appendChild(toggle);

        k.window.localStorage.setItem(KIOSK_ENABLED_STORAGE_KEY, 'false');
        k.window.dispatchEvent(storageEvent(k.window, KIOSK_ENABLED_STORAGE_KEY, 'false'));

        assert.equal(toggle.checked, false, 'the checkbox must be updated to reflect the cross-tab change');
    } finally { teardown(k); }
});

test('(i) a "storage" event with no #kiosk-mode-toggle in the document is a clean no-op, not a throw', () => {
    const k = freshKiosk();
    try {
        assert.equal(k.document.getElementById('kiosk-mode-toggle'), null, 'setup: no toggle present in this minimal DOM');
        assert.doesNotThrow(() => {
            k.window.localStorage.setItem(KIOSK_ENABLED_STORAGE_KEY, 'false');
            k.window.dispatchEvent(storageEvent(k.window, KIOSK_ENABLED_STORAGE_KEY, 'false'));
        }, 'a missing toggle element must never throw out of the storage handler');
    } finally { teardown(k); }
});

test('(i) a "storage" event for an unrelated key is ignored', async () => {
    const k = freshKiosk();
    try {
        k.K.setEnabled(true);
        k.K.config.idleTimeout = 30;
        k.K.init();
        await wait(80);
        assert.equal(k.K.isActive(), true, 'setup: kiosk auto-activated');

        k.window.dispatchEvent(storageEvent(k.window, 'some-other-localstorage-key', 'false'));
        assert.equal(k.K.isActive(), true, 'a storage event for an unrelated key must not affect kiosk state');
    } finally { teardown(k); }
});

test('(i) REGRESSION GUARD: without the storage listener, a cross-tab preference change is never observed', async () => {
    const k = freshKiosk(mutateRemoveStorageListener);
    try {
        k.K.setEnabled(true);
        k.K.config.idleTimeout = 30;
        k.K.init();
        await wait(80);
        assert.equal(k.K.isActive(), true, 'setup: kiosk auto-activated');

        k.window.localStorage.setItem(KIOSK_ENABLED_STORAGE_KEY, 'false');
        k.window.dispatchEvent(storageEvent(k.window, KIOSK_ENABLED_STORAGE_KEY, 'false'));

        assert.equal(k.K.isActive(), true, 'without the storage listener, this tab must stay oblivious to the cross-tab change -- proving the tests above are real regression guards');
    } finally { teardown(k); }
});

// ============================================================================
// (j) XACA-1154-020 -- "scroll" stays on the idle list (asymmetry reasoning)
// ============================================================================

test('(j) "scroll" continues to reset the idle countdown, preventing kiosk activation while the user scrolls', async () => {
    const k = freshKiosk();
    try {
        k.K.config.idleTimeout = 60;
        k.K.setEnabled(true);
        k.K.init();
        for (let i = 0; i < 6; i++) {
            await wait(20);
            k.document.dispatchEvent(immediateEvent(k.window, 'scroll'));
        }
        assert.equal(k.K.isActive(), false, 'kiosk must not activate while "scroll" events keep resetting the idle countdown');
    } finally { teardown(k); }
});

test('(j) REGRESSION GUARD: without "scroll" in the idle list, the countdown elapses and kiosk activates despite continuous scrolling', async () => {
    const k = freshKiosk(mutateIdleListWithoutScroll);
    try {
        k.K.config.idleTimeout = 60;
        k.K.setEnabled(true);
        k.K.init();
        for (let i = 0; i < 6; i++) {
            await wait(20);
            k.document.dispatchEvent(immediateEvent(k.window, 'scroll'));
        }
        assert.equal(k.K.isActive(), true, 'without "scroll" in the idle list, continuous scrolling must fail to prevent kiosk activation -- proving the test above is a real regression guard, and the empirical reason XACA-1154-020 keeps "scroll" in this list (see the code comment at KIOSK_IDLE_EVENTS)');
    } finally { teardown(k); }
});

// ============================================================================
// (k) XACA-1154-021 -- setEnabled(true) gated on !isKioskActive
// ============================================================================

// "keypress" is unique to KIOSK_IDLE_EVENTS -- neither KIOSK_EXIT_EVENTS_IMMEDIATE
// nor KIOSK_EXIT_EVENTS_MOVEMENT ever attach it, so a document.addEventListener
// call for it can only originate from startIdleMonitoring() (directly, or via
// _applyKioskEnabled()/setEnabled()).
function countKeypressAttaches(document) {
    let count = 0;
    const orig = document.addEventListener.bind(document);
    document.addEventListener = function (type, listener, opts) {
        if (type === 'keypress') count++;
        return orig(type, listener, opts);
    };
    return () => count;
}

test('(k) setEnabled(true) does not re-arm idle-monitoring listeners while kiosk is currently active', async () => {
    const k = freshKiosk();
    try {
        await enterAndArm(k);
        const getCount = countKeypressAttaches(k.document);

        k.K.setEnabled(true);
        assert.equal(getCount(), 0, 'setEnabled(true) while kiosk is active must not re-arm idle-tracking listeners');
    } finally { teardown(k); }
});

test('(k) REGRESSION GUARD: without the isKioskActive gate, setEnabled(true) re-arms idle-monitoring listeners even while kiosk is active', async () => {
    const k = freshKiosk(mutateRemoveSetEnabledGate);
    try {
        await enterAndArm(k);
        const getCount = countKeypressAttaches(k.document);

        k.K.setEnabled(true);
        assert.ok(getCount() > 0, 'without the gate, setEnabled(true) must re-arm idle listeners even while kiosk is active -- proving the test above is a real regression guard');
    } finally { teardown(k); }
});
