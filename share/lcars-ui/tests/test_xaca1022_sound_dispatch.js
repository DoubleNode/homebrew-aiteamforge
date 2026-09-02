//
//  test_xaca1022_sound_dispatch.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * test_xaca1022_sound_dispatch.js — Node-native headless coverage for the
 * XACA-1022 pointerdown/click sound-dispatch rework in lcars-sound.js.
 *
 * SCOPE: this suite covers control-flow logic only — event-dispatch
 * classification and the pointerdown/click dedupe guard — using a stubbed
 * `document` (a hand-rolled capture/bubble listener registry, not a real
 * DOM) and a stubbed `Audio` class that records play()/pause()/currentTime/
 * volume calls instead of producing sound. It CANNOT and does NOT exercise:
 * real Safari/WebKit pointer-event ordering or timing, real touch-to-scroll
 * disambiguation, or any actual latency number. See the "What remains
 * unverified" list at the bottom of this file (also reported in the
 * XACA-1022-008 test report) for the full rundown of what still needs a
 * human on a real device.
 *
 * NOTE: XACA-1022-006 (an Audio-element pool) was implemented, measured
 * on-device, and REVERTED — the pooled path made time-to-audible worse, not
 * better (see the "Web Audio hybrid evaluation" comment block in
 * lcars-sound.js for the numbers). This suite no longer covers pooling
 * because the shipped file no longer has it; `_playWav` is back to a
 * fresh-Audio-per-call implementation.
 *
 * TWO ENGINE COPIES, BOTH COVERED: fleet-monitor and lcars-ui ship separate
 * copies of this file (not mirrors of one canonical source — there is no
 * build step that keeps them in sync, they are just expected to read
 * identically). Historically they differed by exactly one line:
 * fleet-monitor's `_classifyMatch` alert branch carried an extra
 * `.legend-pill` selector (XACA-0963) that lcars-ui's did not, so the SAME
 * visual pill sounded 'alert' on Fleet Monitor and 'action' on the lcars-ui
 * cockpit. XACA-1022-015 normalized that away — both copies now classify
 * `.legend-pill` as 'action' — and the "cross-engine structural pin" test
 * below asserts the two files are now IDENTICAL, not merely close. This
 * suite still runs the FULL matrix against BOTH files independently rather
 * than assuming that identity holds: a future edit to only one copy should
 * fail this suite loudly, not silently pass because "they're the same file
 * anyway."
 *
 * WHOLE-FILE EVAL, NOT PER-FUNCTION EXTRACTION: unlike
 * test_xaca0920_copy_to_clipboard.js (which extracts one function out of a
 * large multi-purpose file), lcars-sound.js is itself a single self-contained
 * IIFE built for exactly this purpose — extracting a sub-function would still
 * require re-supplying its private closure state (`_muted`,
 * `_pendingContainer`, etc.), which is exactly what
 * evaluating the whole IIFE gives us for free. So this suite reads the
 * ENTIRE shipped file with fs.readFileSync and runs it verbatim in a fresh
 * vm context per test — no hand-reimplemented logic anywhere in this file.
 *
 * The one thing this suite adds to the shipped source is a single-line,
 * marker-anchored splice immediately after the shipped `window.LCARSSound =
 * LCARSSound;` export line: an additional `window.__TEST_HOOKS__ = {...}`
 * object exposing the IIFE's otherwise-private internals — the
 * classification functions (`_classifySound`, and `_classifyMatch` which
 * additionally reports the matched CONTAINER element, XACA-1022-016/017)
 * and the mute/pending-guard state — so assertions can reach them. This is a
 * peephole for observation only — it adds no new logic and calls no shipped
 * function differently than production does. If the export line's exact
 * text ever moves or changes, the marker lookup below fails loudly (an
 * `assert.ok`) rather than silently testing against a stale splice point —
 * mirroring the guarantee test_xaca0920_copy_to_clipboard.js makes for its
 * own start/end markers.
 *
 * Usage:
 *   node --test lcars-ui/tests/test_xaca1022_sound_dispatch.js
 *
 * No external dependencies. Node >=18 required (node:test, node:vm built-in).
 */

'use strict';

var test   = require('node:test');
var assert = require('node:assert/strict');
var path   = require('path');
var fs     = require('fs');
var vm     = require('vm');

var ENGINES = [
    {
        label: 'fleet-monitor',
        filePath: path.join(__dirname, '../../fleet-monitor/server/public/lcars/js/lcars-sound.js'),
        totalClosestCalls: 22,
        distinctSelectors: 20
    },
    {
        label: 'lcars-ui',
        filePath: path.join(__dirname, '../js/lcars-sound.js'),
        totalClosestCalls: 22,
        distinctSelectors: 20
    }
];

// ─── Instrumentation: splice a test-hooks export right after the shipped
// ─── `window.LCARSSound = LCARSSound;` line. Marker-anchored, fails loudly
// ─── if the export line moves (see file header). ───────────────────────────

var EXPORT_MARKER = 'window.LCARSSound = LCARSSound;';

function instrument(rawSrc, label) {
    var idx = rawSrc.indexOf(EXPORT_MARKER);
    assert.ok(idx !== -1,
        '[' + label + '] Could not locate "' + EXPORT_MARKER + '" export marker in lcars-sound.js — ' +
        'has the export line moved/changed? This suite splices its test hooks immediately after it.');

    var hook =
        EXPORT_MARKER + '\n' +
        '    window.__TEST_HOOKS__ = {\n' +
        '        classifySound: _classifySound,\n' +
        '        classifyMatch: _classifyMatch,\n' +
        '        playWav: _playWav,\n' +
        '        isMuted: function () { return _muted; },\n' +
        '        setMuted: function (v) { _muted = v; },\n' +
        '        getPendingContainer: function () { return _pendingContainer; },\n' +
        '        getPendingPointerId: function () { return _pendingPointerId; }\n' +
        '    };\n';

    return rawSrc.slice(0, idx) + hook + rawSrc.slice(idx + EXPORT_MARKER.length);
}

// ─── Fake DOM primitives ────────────────────────────────────────────────────

/**
 * A target node stub. `.closest(selector)` returns itself for any selector
 * in `matchSelectors`, null otherwise — this tests "does this selector map
 * to this sound type", not real CSS matching (which _classifySound doesn't
 * do either; it delegates to the real DOM's closest() in production).
 *
 * The "container" a plain makeTarget() resolves to is always the target
 * object itself (closest() returns `this`) — fine for the original
 * identity-based tests, but it can't express "two DIFFERENT DOM nodes that
 * both resolve to the SAME logical container", which is exactly the
 * XACA-1022-016 retarget scenario. Use makeTargetWithContainer() for that.
 */
function makeTarget(matchSelectors) {
    var set = new Set(matchSelectors || []);
    return {
        closest: function (sel) { return set.has(sel) ? this : null; }
    };
}

/**
 * A target node stub whose `.closest(selector)` resolves to an explicitly
 * supplied `container` object (which may be a DIFFERENT object than the
 * target itself), for any selector in `matchSelectors`. This is what lets a
 * test simulate a DOM mutation/retarget between pointerdown and click — two
 * distinct target objects that both resolve to the same matched container —
 * without which the container-based dedupe guard (XACA-1022-016/017) can't
 * be distinguished from the old raw-identity guard in a stubbed DOM.
 */
function makeTargetWithContainer(matchSelectors, container) {
    var set = new Set(matchSelectors || []);
    return {
        closest: function (sel) { return set.has(sel) ? container : null; }
    };
}

/**
 * A `document` stub supporting exactly what lcars-sound.js uses:
 * addEventListener(type, fn, true|{capture,once}) and getElementById (always
 * null — no toggle-pill DOM exists in this suite). `_dispatch(type, evt)`
 * runs ALL capture-phase listeners for that type, in registration order,
 * THEN all bubble-phase listeners, in registration order — reproducing real
 * DOM semantics for listeners registered on a single node (capture always
 * precedes bubble on the same node, regardless of registration order; see
 * the _unlockPool doc comment in the shipped file for why that ordering is
 * load-bearing here).
 */
function makeDocument() {
    var listeners = { capture: {}, bubble: {} };

    function normalize(opts) {
        if (opts === true) return { capture: true, once: false };
        if (opts && typeof opts === 'object') return { capture: !!opts.capture, once: !!opts.once };
        return { capture: false, once: false };
    }

    function addEventListener(type, fn, opts) {
        var n = normalize(opts);
        var bucket = n.capture ? listeners.capture : listeners.bubble;
        if (!bucket[type]) bucket[type] = [];
        bucket[type].push({ fn: fn, once: n.once });
    }

    function dispatch(type, evt) {
        ['capture', 'bubble'].forEach(function (phase) {
            var bucket = listeners[phase][type];
            if (!bucket) return;
            bucket.slice().forEach(function (entry) {
                entry.fn(evt);
                if (entry.once) {
                    var idx = bucket.indexOf(entry);
                    if (idx !== -1) bucket.splice(idx, 1);
                }
            });
        });
    }

    return {
        addEventListener: addEventListener,
        getElementById: function () { return null; },
        _dispatch: dispatch
    };
}

/**
 * Fake `Audio` constructor. `currentTime`/`volume` are getter/setter pairs
 * so every write is recorded. `.play()` sets `paused = false`
 * SYNCHRONOUSLY (matching the real HTMLMediaElement contract the shipped
 * code's own comments rely on) and returns a resolved Promise so
 * `.then()`/`.catch()` chains in the shipped code don't throw.
 * `playSequence` records every instance in play() call order, across all
 * types.
 */
function makeAudioClass(created, playSequence) {
    return function Audio(src) {
        var _currentTime = 0;
        var _volume = 1;
        var self = this;

        this.src = src;
        this.paused = true;
        this.preload = '';
        this.playCalls = 0;
        this.pauseCalls = 0;
        this.currentTimeHistory = [];
        this.volumeHistory = [];

        Object.defineProperty(this, 'currentTime', {
            get: function () { return _currentTime; },
            set: function (v) { _currentTime = v; self.currentTimeHistory.push(v); }
        });
        Object.defineProperty(this, 'volume', {
            get: function () { return _volume; },
            set: function (v) { _volume = v; self.volumeHistory.push(v); }
        });

        this.play = function () {
            self.paused = false;
            self.playCalls++;
            playSequence.push(self);
            return Promise.resolve();
        };
        this.pause = function () {
            self.paused = true;
            self.pauseCalls++;
        };

        created.push(this);
    };
}

/**
 * Builds a fresh vm environment for one engine copy: reads + instruments the
 * shipped file, evaluates it with document/window/navigator/localStorage/
 * console/btoa/Audio stubbed, and returns the LCARSSound public API plus the
 * spliced test hooks and observation arrays.
 */
function buildEnv(engine) {
    var rawSrc = fs.readFileSync(engine.filePath, 'utf8');
    var src = instrument(rawSrc, engine.label);

    var created = [];
    var playSequence = [];
    var consoleCalls = { log: [], warn: [], error: [] };
    var storage = {};
    var doc = makeDocument();

    var sandbox = {
        console: {
            log: function () { consoleCalls.log.push(Array.prototype.slice.call(arguments)); },
            warn: function () { consoleCalls.warn.push(Array.prototype.slice.call(arguments)); },
            error: function () { consoleCalls.error.push(Array.prototype.slice.call(arguments)); }
        },
        document: doc,
        window: {},
        navigator: {},
        localStorage: {
            getItem: function (k) { return Object.prototype.hasOwnProperty.call(storage, k) ? storage[k] : null; },
            setItem: function (k, v) { storage[k] = String(v); }
        },
        // btoa is a WHATWG/browser global, not a V8-intrinsic one — absent
        // from a bare vm context. Real base64 semantics aren't under test
        // here (WAV-byte correctness is out of this ticket's scope), just
        // "doesn't throw so pool construction can proceed."
        btoa: function (str) { return Buffer.from(str, 'binary').toString('base64'); },
        Audio: makeAudioClass(created, playSequence)
    };

    vm.createContext(sandbox);
    vm.runInContext(src, sandbox);

    var hooks = sandbox.window.__TEST_HOOKS__;
    assert.ok(hooks, '[' + engine.label + '] test hooks were not exported — instrumentation failed');
    assert.equal(typeof sandbox.window.LCARSSound, 'object', '[' + engine.label + '] window.LCARSSound was not exported');

    return {
        engine: engine,
        doc: doc,
        LCARSSound: sandbox.window.LCARSSound,
        hooks: hooks,
        audioCreated: created,
        playSequence: playSequence,
        consoleCalls: consoleCalls
    };
}

/**
 * Wraps the public LCARSSound.play(type) entrypoint to record every type it
 * is actually invoked with. This is the correct "was a sound dispatched"
 * signal for the dispatch/dedupe tests below.
 */
function wrapPlay(env) {
    var log = [];
    var original = env.LCARSSound.play;
    env.LCARSSound.play = function (type) {
        log.push(type);
        return original.call(env.LCARSSound, type);
    };
    env.dispatchLog = log;
    return env;
}

function dispatchPointerdown(env, target, opts) {
    opts = opts || {};
    env.doc._dispatch('pointerdown', {
        target: target,
        button: opts.button !== undefined ? opts.button : 0,
        isPrimary: opts.isPrimary !== undefined ? opts.isPrimary : true,
        pointerId: opts.pointerId !== undefined ? opts.pointerId : 1
    });
}

function dispatchClick(env, target) {
    env.doc._dispatch('click', { target: target });
}

function dispatchPointerup(env, target, opts) {
    opts = opts || {};
    env.doc._dispatch('pointerup', {
        target: target,
        pointerId: opts.pointerId !== undefined ? opts.pointerId : 1
    });
}

function dispatchPointercancel(env, pointerId) {
    env.doc._dispatch('pointercancel', { pointerId: pointerId });
}

function dispatchKeydown(env, target, opts) {
    opts = opts || {};
    env.doc._dispatch('keydown', {
        target: target,
        key: opts.key !== undefined ? opts.key : 'Enter',
        repeat: opts.repeat !== undefined ? opts.repeat : false
    });
}

// ═════════════════════════════════════════════════════════════════════════
// Per-engine test matrix
// ═════════════════════════════════════════════════════════════════════════

ENGINES.forEach(function (engine) {
    var P = '[' + engine.label + '] ';

    // ─── Dispatch: pointerdown plays, click dedupes, keyboard fallback ─────

    test(P + 'pointerdown on a sound-mapped element plays once, at pointerdown', function () {
        var env = wrapPlay(buildEnv(engine));
        var target = makeTarget(['.sidebar-button']);
        dispatchPointerdown(env, target);
        assert.deepEqual(env.dispatchLog, ['nav'], 'exactly one sound should have been dispatched');
    });

    test(P + 'the trailing click for the same press does NOT double-play', function () {
        var env = wrapPlay(buildEnv(engine));
        var target = makeTarget(['.sidebar-button']);
        dispatchPointerdown(env, target);
        assert.equal(env.dispatchLog.length, 1);
        dispatchClick(env, target); // same target object, identity match
        assert.equal(env.dispatchLog.length, 1, 'the trailing click must be swallowed by the dedupe guard');
    });

    test(P + 'a click with no preceding pointerdown DOES play (keyboard Enter/Space, XACA-1022-002)', function () {
        var env = wrapPlay(buildEnv(engine));
        var target = makeTarget(['.btn-lcars']);
        dispatchClick(env, target);
        assert.deepEqual(env.dispatchLog, ['action'], 'a bare click (no pointerdown ever seen) must still produce sound');
    });

    test(P + 'e.button !== 0 (right/middle click) plays nothing on pointerdown', function () {
        var env = wrapPlay(buildEnv(engine));
        var target = makeTarget(['.card']);
        dispatchPointerdown(env, target, { button: 2 });
        assert.equal(env.dispatchLog.length, 0);
        assert.equal(env.hooks.getPendingContainer(), null, 'guard must not be armed for a non-primary button');
    });

    test(P + 'e.isPrimary === false (secondary touch contact) plays nothing on pointerdown', function () {
        var env = wrapPlay(buildEnv(engine));
        var target = makeTarget(['.card']);
        dispatchPointerdown(env, target, { isPrimary: false, pointerId: 7 });
        assert.equal(env.dispatchLog.length, 0);
        assert.equal(env.hooks.getPendingContainer(), null);
    });

    test(P + 'pointercancel clears the guard; a later unrelated click is not swallowed', function () {
        var env = wrapPlay(buildEnv(engine));
        var targetA = makeTarget(['.sidebar-button']);
        var targetB = makeTarget(['.btn-lcars']);

        dispatchPointerdown(env, targetA, { pointerId: 5 });
        assert.equal(env.dispatchLog.length, 1);
        assert.equal(env.hooks.getPendingContainer(), targetA);

        dispatchPointercancel(env, 5);
        assert.equal(env.hooks.getPendingContainer(), null, 'pointercancel must clear the guard');

        dispatchClick(env, targetB); // unrelated target, no pointerdown ever recorded for it
        assert.equal(env.dispatchLog.length, 2, 'the unrelated click on B must not be swallowed by a stale guard');
    });

    test(P + 'guard does not leak: pointerdown on A with no matching click, then a click on B still plays', function () {
        var env = wrapPlay(buildEnv(engine));
        var targetA = makeTarget(['.card']);
        var targetB = makeTarget(['.toast-close']);

        dispatchPointerdown(env, targetA, { pointerId: 9 });
        assert.equal(env.dispatchLog.length, 1, 'A\'s pointerdown plays');
        // No click and no pointercancel ever arrives for A (e.g. focus moved
        // away). The guard is still holding A's identity.
        assert.equal(env.hooks.getPendingContainer(), targetA);

        dispatchClick(env, targetB); // click on a DIFFERENT, unrelated target
        assert.equal(env.dispatchLog.length, 2,
            'B\'s click must still play — the guard only matches identical targets, not "a pointerdown happened somewhere"');
    });

    test(P + '_muted suppresses both pointerdown and click dispatch', function () {
        var env = wrapPlay(buildEnv(engine));
        env.hooks.setMuted(true);
        var target = makeTarget(['.sidebar-button']);
        dispatchPointerdown(env, target);
        assert.equal(env.dispatchLog.length, 0);
        dispatchClick(env, target);
        assert.equal(env.dispatchLog.length, 0);
    });

    test(P + '#sound-toggle produces no sound via pointerdown or click (matched, then deliberately skipped)', function () {
        var env = wrapPlay(buildEnv(engine));
        var target = makeTarget(['#sound-toggle']);
        dispatchPointerdown(env, target, { pointerId: 3 });
        assert.equal(env.dispatchLog.length, 0, 'pointerdown on #sound-toggle must stay silent');
        dispatchClick(env, target);
        assert.equal(env.dispatchLog.length, 0, 'click on #sound-toggle must stay silent too');
    });

    // ─── XACA-1022-016: container-based dedupe survives a same-press retarget ─

    test(P + 'a DOM retarget between pointerdown and click does NOT double-play, as long as both resolve to the same container',
        function () {
            var env = wrapPlay(buildEnv(engine));
            var container = {}; // the logical control both nodes below resolve to via closest()
            var pressNode = makeTargetWithContainer(['.sidebar-button'], container);
            var clickNode = makeTargetWithContainer(['.sidebar-button'], container); // a DIFFERENT object — e.g. a hover-swapped icon

            dispatchPointerdown(env, pressNode);
            assert.equal(env.dispatchLog.length, 1, 'pointerdown plays');
            assert.equal(env.hooks.getPendingContainer(), container, 'guard should hold the CONTAINER, not the raw target object');

            dispatchClick(env, clickNode); // different node identity, same matched container
            assert.equal(env.dispatchLog.length, 1,
                'the trailing click must still be deduped even though its e.target is a different object than pointerdown\'s, ' +
                'because both resolve to the same container — this is what container-based (not raw e.target) matching buys us');
        });

    test(P + 'a click whose matched container differs from the pending one is NOT treated as the trailing click',
        function () {
            var env = wrapPlay(buildEnv(engine));
            var containerA = {};
            var containerB = {};
            var pressNode = makeTargetWithContainer(['.card'], containerA);
            var clickNode = makeTargetWithContainer(['.toast-close'], containerB);

            dispatchPointerdown(env, pressNode);
            assert.equal(env.dispatchLog.length, 1);

            dispatchClick(env, clickNode);
            assert.equal(env.dispatchLog.length, 2,
                'a click resolving to a genuinely different container must still play its own sound');
        });

    // ─── XACA-1022-017: pointerup landing elsewhere clears the guard ───────

    test(P + 'pointerup on a DIFFERENT container than the pending one clears the guard (drag-away release)',
        function () {
            var env = wrapPlay(buildEnv(engine));
            var targetA = makeTarget(['.sidebar-button']);
            var elsewhere = makeTarget(['.totally-unmapped-thing']); // release landed off any sound-mapped element

            dispatchPointerdown(env, targetA, { pointerId: 11 });
            assert.equal(env.dispatchLog.length, 1);
            assert.equal(env.hooks.getPendingContainer(), targetA);

            dispatchPointerup(env, elsewhere, { pointerId: 11 });
            assert.equal(env.hooks.getPendingContainer(), null,
                'a release that resolves to neither the pending container nor any container at all must clear the guard');

            // No click ever follows this abandoned press (real browsers fire
            // neither `click` nor `pointercancel` for a drag-away release).
            // A LATER, independent keyboard click on the SAME element A must
            // still produce sound — proving the guard did not stay stuck.
            dispatchClick(env, targetA);
            assert.equal(env.dispatchLog.length, 2,
                'a later keyboard click on A must not be swallowed by the abandoned press\'s stale guard');
        });

    test(P + 'pointerup on the SAME container as the pending one leaves the guard alone (normal press-and-release)',
        function () {
            var env = wrapPlay(buildEnv(engine));
            var target = makeTarget(['.sidebar-button']);

            dispatchPointerdown(env, target, { pointerId: 12 });
            assert.equal(env.dispatchLog.length, 1);

            dispatchPointerup(env, target, { pointerId: 12 });
            assert.equal(env.hooks.getPendingContainer(), target,
                'pointerup resolving to the SAME container must NOT clear the guard — click (which fires next, per spec) ' +
                'is what consumes it; an unconditional clear here would double-play every normal press');

            dispatchClick(env, target); // the real trailing click for this same press
            assert.equal(env.dispatchLog.length, 1, 'the trailing click must still be deduped');
        });

    test(P + 'pointerup for an UNRELATED pointerId does not touch the guard', function () {
        var env = wrapPlay(buildEnv(engine));
        var target = makeTarget(['.sidebar-button']);

        dispatchPointerdown(env, target, { pointerId: 20 });
        assert.equal(env.dispatchLog.length, 1);

        dispatchPointerup(env, makeTarget(['.totally-unmapped-thing']), { pointerId: 999 }); // different pointer entirely
        assert.equal(env.hooks.getPendingContainer(), target, 'an unrelated pointerId must not clear this guard');

        dispatchClick(env, target);
        assert.equal(env.dispatchLog.length, 1, 'the real trailing click is still deduped');
    });

    // ─── XACA-1022-014: keydown Enter/Space plays for handlers that never dispatch click ─

    test(P + 'keydown Enter on a classified element plays, with no preceding pointerdown or click', function () {
        var env = wrapPlay(buildEnv(engine));
        var target = makeTarget(['.legend-pill']);
        dispatchKeydown(env, target, { key: 'Enter' });
        assert.deepEqual(env.dispatchLog, ['action'],
            'a keydown-only activation (handler calls switchSection() directly, never .click()) must still sound');
    });

    test(P + "keydown Space (both ' ' and legacy 'Spacebar') on a classified element plays", function () {
        var env = wrapPlay(buildEnv(engine));
        dispatchKeydown(env, makeTarget(['.legend-pill']), { key: ' ' });
        assert.equal(env.dispatchLog.length, 1, "key ' ' must trigger sound");

        var env2 = wrapPlay(buildEnv(engine));
        dispatchKeydown(env2, makeTarget(['.legend-pill']), { key: 'Spacebar' });
        assert.equal(env2.dispatchLog.length, 1, "legacy key 'Spacebar' must also trigger sound");
    });

    test(P + 'keydown Enter followed by the resulting .click() (sibling pills that call this.click() from onkeydown) does NOT double-play',
        function () {
            var env = wrapPlay(buildEnv(engine));
            var target = makeTarget(['.legend-pill']);
            dispatchKeydown(env, target, { key: 'Enter' });
            assert.equal(env.dispatchLog.length, 1, 'keydown plays once');
            dispatchClick(env, target); // simulates this.click() called from the element's own onkeydown handler
            assert.equal(env.dispatchLog.length, 1,
                'the click a sibling onkeydown handler triggers via .click() must be deduped by the same container guard');
        });

    test(P + 'keydown with e.repeat=true (held key) does not re-play', function () {
        var env = wrapPlay(buildEnv(engine));
        var target = makeTarget(['.legend-pill']);
        dispatchKeydown(env, target, { key: 'Enter' });
        assert.equal(env.dispatchLog.length, 1);
        dispatchKeydown(env, target, { key: 'Enter', repeat: true });
        assert.equal(env.dispatchLog.length, 1, 'auto-repeat keydown must be ignored');
    });

    test(P + 'keydown on a non-activation key (e.g. Tab) does not play', function () {
        var env = wrapPlay(buildEnv(engine));
        dispatchKeydown(env, makeTarget(['.legend-pill']), { key: 'Tab' });
        assert.equal(env.dispatchLog.length, 0);
    });

    test(P + 'keydown is suppressed while muted', function () {
        var env = wrapPlay(buildEnv(engine));
        env.hooks.setMuted(true);
        dispatchKeydown(env, makeTarget(['.legend-pill']), { key: 'Enter' });
        assert.equal(env.dispatchLog.length, 0);
    });

    // ─── XACA-1022-019: the guard is consumed even when the click is muted ─

    test(P + 'a click evaluated while muted still consumes the guard (does not leak forward once unmuted)', function () {
        var env = wrapPlay(buildEnv(engine));
        var target = makeTarget(['.sidebar-button']);

        dispatchPointerdown(env, target); // unmuted — arms the guard and plays once
        assert.equal(env.dispatchLog.length, 1);
        assert.equal(env.hooks.getPendingContainer(), target);

        env.hooks.setMuted(true);
        dispatchClick(env, makeTarget(['.totally-unmapped-thing'])); // ANY click, muted, unrelated target
        assert.equal(env.dispatchLog.length, 1, 'no sound plays while muted');
        assert.equal(env.hooks.getPendingContainer(), null,
            'the guard must be consumed the instant this click was evaluated, even though _muted short-circuited before ' +
            'classification — consuming it BEFORE the _muted check is exactly XACA-1022-019\'s fix');

        env.hooks.setMuted(false);
        dispatchClick(env, target); // a later click on the ORIGINAL element, now unmuted
        assert.equal(env.dispatchLog.length, 2,
            'since the guard was already consumed by the muted click, this later click on the original element is treated ' +
            'as a fresh, unmatched click and must play — proving the guard did not survive past the muted evaluation');
    });

    // ─── Classification: every distinct closest() selector branch ─────────

    var COMMON_NAV = [
        '.sidebar-button', '.sidebar-submenu-item', '.analytics-page-pill', '.sidebar-link'
    ];
    var COMMON_ALERT = [
        '.status-btn', '.status-indicator', '[data-priority]', '[data-category]', '[data-tag]',
        '.candy-pill:not([data-candy])'
    ];
    var COMMON_ACTION = [
        '.kanban-card', '.card', '.toggle-columns-btn', '.toast-close', '.summary-card',
        '.btn-lcars', '.lcars-button', '.kiosk-fab'
    ];

    COMMON_NAV.forEach(function (sel) {
        test(P + 'classify: ' + sel + ' -> nav', function () {
            var env = buildEnv(engine);
            assert.equal(env.hooks.classifySound(makeTarget([sel])), 'nav');
        });
    });

    COMMON_ALERT.forEach(function (sel) {
        test(P + 'classify: ' + sel + ' -> alert', function () {
            var env = buildEnv(engine);
            assert.equal(env.hooks.classifySound(makeTarget([sel])), 'alert');
        });
    });

    COMMON_ACTION.forEach(function (sel) {
        test(P + 'classify: ' + sel + ' -> action', function () {
            var env = buildEnv(engine);
            assert.equal(env.hooks.classifySound(makeTarget([sel])), 'action');
        });
    });

    test(P + 'classify: #sound-toggle -> null (matched by alert group, then deliberately skipped)', function () {
        var env = buildEnv(engine);
        assert.equal(env.hooks.classifySound(makeTarget(['#sound-toggle'])), null);
    });

    test(P + 'classify: an unmapped element -> null', function () {
        var env = buildEnv(engine);
        assert.equal(env.hooks.classifySound(makeTarget(['.totally-unmapped-thing'])), null);
    });

    // XACA-1022-016 (UX dissent): #fleet-offline-indicator carries .legend-pill,
    // so the normalization above would sweep it into 'action'. Its own markup
    // comment calls it a persistent OFFLINE cue "escalating to a red alert state
    // above zero" — a status indicator, not a general button — so it is matched
    // by the ALERT group ahead of the action branch. This test pins that ordering:
    // if someone removes the alert-group entry, the .legend-pill action entry
    // silently takes over and the red-alert cue starts sounding like a button.
    test(P + 'classify: #fleet-offline-indicator -> alert (beats its own .legend-pill action match)', function () {
        var env = buildEnv(engine);
        assert.equal(env.hooks.classifySound(makeTarget(['#fleet-offline-indicator', '.legend-pill'])), 'alert');
    });

    // ─── legend-pill normalization (XACA-1022-015) ─────────────────────────
    //
    // Historically fleet-monitor's alert-group condition carried an EXTRA
    // '.legend-pill' entry (XACA-0963) that lcars-ui's did not, so the same
    // visual pill sounded 'alert' on Fleet Monitor and 'action' on the
    // lcars-ui cockpit — and, because that alert-group check ran first,
    // fleet-monitor's own action-group '.legend-pill' entry (present in both
    // copies) was unreachable dead code. That divergence is now normalized:
    // '.legend-pill' classifies as 'action' in BOTH copies, via the single
    // action-group entry that already existed in both. This is a
    // user-perceptible behaviour change on Fleet Monitor's SETTINGS and ADMIN
    // utility-bar pills (alert -> action). NOT the SOUND pill (#sound-toggle
    // classifies as null, silent before and after) and NOT the OFFLINE
    // indicator (#fleet-offline-indicator is matched by the alert group ahead
    // of this one, deliberately — see below) — see the comment above
    // _classifyMatch's action branch in lcars-sound.js for the full
    // rationale. Do NOT reintroduce the alert-group line.

    test(P + 'classify: .legend-pill -> action (normalized across both engines, XACA-1022-015)', function () {
        var env = buildEnv(engine);
        assert.equal(env.hooks.classifySound(makeTarget(['.legend-pill'])), 'action');
    });

    // ─── _playWav return contract ──────────────────────────────────────────

    test(P + '_playWav returns a fresh Audio element per call (overlapping plays do not share state)', function () {
        var env = buildEnv(engine);
        var first = env.hooks.playWav('nav');
        var second = env.hooks.playWav('nav');
        assert.ok(first, 'first play should return an Audio element');
        assert.ok(second, 'second play should return an Audio element');
        assert.notEqual(first, second,
            'each call must create a fresh Audio instance so overlapping plays are not truncated (restored pre-XACA-1022-006 behaviour)');
    });

    test(P + '_playWav returns null for an unknown sound type', function () {
        var env = buildEnv(engine);
        assert.equal(env.hooks.playWav('not-a-real-type'), null);
    });
});

// ═════════════════════════════════════════════════════════════════════════
// Cross-engine structural pins
// ═════════════════════════════════════════════════════════════════════════

test('the two engine copies are now IDENTICAL (XACA-1022-015 normalized the last divergence)', function () {
    // Historically this pin asserted the two files differed by exactly the
    // one documented .legend-pill alert-branch line (XACA-0963). That line
    // is now removed from fleet-monitor's copy (see the legend-pill
    // normalization comment above _classifyMatch's action branch in
    // lcars-sound.js), and no other divergence has ever existed between
    // these two files — so the correct pin is now byte-for-byte equality,
    // not a one-line delta. If this ever fails, the two copies have
    // diverged again; re-run `diff` on both files to see how, and either
    // fix the file that drifted or, if the divergence is intentional this
    // time, replace this assertion with one that documents the new,
    // deliberate difference (as this file's header comment used to for
    // XACA-0963) rather than silently loosening it.
    var fleetSrc = fs.readFileSync(ENGINES[0].filePath, 'utf8');
    var lcarsSrc = fs.readFileSync(ENGINES[1].filePath, 'utf8');
    assert.equal(fleetSrc, lcarsSrc,
        'fleet-monitor and lcars-ui copies of lcars-sound.js must be byte-for-byte identical post-XACA-1022-015 — run ' +
        '`diff fleet-monitor/server/public/lcars/js/lcars-sound.js lcars-ui/js/lcars-sound.js` to see what drifted.');
});

ENGINES.forEach(function (engine) {
    test('[' + engine.label + '] _classifyMatch has the expected total closest() call count (' + engine.totalClosestCalls + ')',
        function () {
            var src = fs.readFileSync(engine.filePath, 'utf8');
            var start = src.indexOf('function _classifyMatch(target) {');
            assert.ok(start !== -1, '[' + engine.label + '] could not locate _classifyMatch() — has it been renamed?');
            var end = src.indexOf('\n    // XACA-1022: press/click dedupe guard.', start);
            assert.ok(end !== -1, '[' + engine.label + '] could not locate the dedupe-guard comment marking the end of _classifyMatch()');
            var body = src.slice(start, end);
            var matches = body.match(/\.closest\(/g) || [];
            assert.equal(matches.length, engine.totalClosestCalls,
                'closest() call count drifted for ' + engine.label + ' — recount the branches and update ' +
                'this suite\'s COMMON_NAV/COMMON_ALERT/COMMON_ACTION lists and ENGINES[].totalClosestCalls to match.');
        });
});

// ═════════════════════════════════════════════════════════════════════════
// Investigation: <label for=> double-play vector (static analysis on the
// real, shipped fleet-monitor HTML — not a vm/sandbox test).
//
// closest() walks ANCESTORS. Clicking a <label for="x"> dispatches a SECOND
// trusted click on the associated input #x. If a label and its input share a
// sound-mapped ancestor, the pointerdown/click identity guard (which matches
// on `e.target`, not "was any click already handled this tick") would NOT
// catch the synthetic input-click, because its target is the input element,
// not the label — a real double-play.
//
// This static scan walks every `<label ... for="...">` in a surface's
// shipped HTML and collects the class/id/data-* selectors of its DOM
// ancestors (a small hand-rolled tag-stack parser — sufficient for this
// codebase's well-formed, non-self-closing-div markup; it is NOT a general
// HTML parser). It then checks those ancestor selectors against the ACTUAL
// selector list that surface's OWN _classifyMatch uses (parsed from the
// shipped file itself, so this test does not go stale if new selectors are
// added later).
//
// XACA-1022-018: this scan originally walked ONLY
// fleet-monitor/server/public/**/*.html against fleet-monitor's engine copy.
// lcars-ui/index.html was never scanned, so a future lcars-ui-only markup
// change nesting a <label for=> inside a sound-mapped ancestor would have
// shipped with no automated guard on that surface. It now also runs against
// lcars-ui/index.html, checked against lcars-ui's own engine copy — kept as
// a SEPARATE extraction per surface (not one shared selector set) so this
// stays correct if the two engine copies ever diverge again in the future,
// even though XACA-1022-015 made them byte-identical today.
// ═════════════════════════════════════════════════════════════════════════

var VOID_TAGS = new Set([
    'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
    'link', 'meta', 'param', 'source', 'track', 'wbr'
]);

function extractAncestorSelectorsFromAttrs(attrs) {
    var selectors = [];
    var classMatch = attrs.match(/\bclass=["']([^"']*)["']/);
    if (classMatch) {
        classMatch[1].split(/\s+/).filter(Boolean).forEach(function (c) { selectors.push('.' + c); });
    }
    var idMatch = attrs.match(/\bid=["']([^"']*)["']/);
    if (idMatch && idMatch[1]) selectors.push('#' + idMatch[1]);
    var dataAttrRe = /\bdata-[a-zA-Z0-9-]+(?==|\s|\/|>)/g;
    var dm;
    while ((dm = dataAttrRe.exec(attrs))) selectors.push('[' + dm[0] + ']');
    return selectors;
}

/**
 * Returns an array of ancestor-selector-arrays (one per ancestor element, in
 * outer-to-inner order) for the FIRST `<label ... for="<forId>">` found in
 * `html`, or null if no such label exists in this file.
 */
function findLabelAncestorSelectors(html, forId) {
    var tagRe = /<(\/?)([a-zA-Z][a-zA-Z0-9-]*)((?:[^>"']|"[^"]*"|'[^']*')*)>/g;
    var stack = [];
    var m;
    var forAttrRe = new RegExp('\\bfor=["\']' + forId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '["\']');

    while ((m = tagRe.exec(html))) {
        var closing = m[1] === '/';
        var tagName = m[2].toLowerCase();
        var attrs = m[3] || '';
        var selfClosing = /\/\s*$/.test(attrs);

        if (closing) {
            for (var i = stack.length - 1; i >= 0; i--) {
                if (stack[i].tag === tagName) { stack.splice(i); break; }
            }
            continue;
        }

        if (tagName === 'label' && forAttrRe.test(attrs)) {
            return stack.map(function (s) { return s.selectors; });
        }

        if (!VOID_TAGS.has(tagName) && !selfClosing) {
            stack.push({ tag: tagName, selectors: extractAncestorSelectorsFromAttrs(attrs) });
        }
    }
    return null;
}

/** Extracts every distinct closest() selector string from a lcars-sound.js source. */
function extractClassifySelectors(src) {
    var start = src.indexOf('function _classifyMatch(target) {');
    var end = src.indexOf('\n    // XACA-1022: press/click dedupe guard.', start);
    var body = src.slice(start, end);
    var re = /\.closest\(\s*['"]([^'"]+)['"]\s*\)/g;
    var out = new Set();
    var m;
    while ((m = re.exec(body))) {
        // Strip a trailing :not(...) / :xxx pseudo-class to the leading
        // simple selector for a CONSERVATIVE match — over-flagging a
        // possible hazard for manual review beats silently clearing one
        // because of an unevaluated :not().
        var raw = m[1];
        var simple = raw.split(':')[0];
        out.add(simple);
    }
    return out;
}

function ancestorSelectorsIntersectSoundMap(ancestorSelectorLists, soundSelectors) {
    for (var i = 0; i < ancestorSelectorLists.length; i++) {
        var sels = ancestorSelectorLists[i];
        for (var j = 0; j < sels.length; j++) {
            if (soundSelectors.has(sels[j])) return sels[j];
        }
    }
    return null;
}

function walkHtmlFiles(dir, out) {
    fs.readdirSync(dir, { withFileTypes: true }).forEach(function (entry) {
        var full = path.join(dir, entry.name);
        if (entry.isDirectory()) { walkHtmlFiles(full, out); return; }
        if (entry.isFile() && entry.name.endsWith('.html')) out.push(full);
    });
}

/**
 * Runs the label-for double-play scan for one surface: `htmlFiles` (relative
 * to `relativeToDir` for reporting) checked against the selector set
 * extracted from `engineFilePath`'s own _classifyMatch. Shared by both the
 * fleet-monitor (many files, directory walk) and lcars-ui (single file)
 * surfaces below (XACA-1022-018) so the scan logic exists in exactly one
 * place instead of being duplicated per surface.
 */
function scanLabelForHazards(label, engineFilePath, htmlFiles, relativeToDir) {
    var soundSrc = fs.readFileSync(engineFilePath, 'utf8');
    var soundSelectors = extractClassifySelectors(soundSrc);
    assert.ok(soundSelectors.size > 0, '[' + label + '] sanity: expected to extract at least one selector from _classifyMatch()');
    assert.ok(htmlFiles.length > 0, '[' + label + '] sanity: expected at least one HTML file to scan');

    var labelForRe = /<label\b[^>]*\bfor=["']([^"']+)["']/g;
    var checked = 0;
    var hazards = [];

    htmlFiles.forEach(function (file) {
        var html = fs.readFileSync(file, 'utf8');
        var seenIdsInFile = new Set();
        var m;
        labelForRe.lastIndex = 0;
        while ((m = labelForRe.exec(html))) {
            var forId = m[1];
            if (seenIdsInFile.has(forId)) continue; // dedupe repeated for= within one file (none observed, defensive)
            seenIdsInFile.add(forId);
            var ancestors = findLabelAncestorSelectors(html, forId);
            assert.ok(ancestors !== null,
                '[' + label + '] ' + file + ': label for="' + forId + '" matched by scan regex but not by the ' +
                'ancestor-walk parser — investigate the tag-stack parser, don\'t assume this is safe.');
            checked++;
            var hazard = ancestorSelectorsIntersectSoundMap(ancestors, soundSelectors);
            if (hazard) {
                hazards.push({ file: path.relative(relativeToDir, file), forId: forId, selector: hazard });
            }
        }
    });

    assert.ok(checked > 0, '[' + label + '] sanity: expected to find and check at least one <label for=> element');
    return hazards;
}

test('label-for double-play investigation: every <label for=> in fleet-monitor\'s shipped HTML has a NON-sound-mapped ancestor chain',
    function () {
        var publicDir = path.join(__dirname, '../../fleet-monitor/server/public');
        var htmlFiles = [];
        walkHtmlFiles(publicDir, htmlFiles);

        var hazards = scanLabelForHazards('fleet-monitor', ENGINES[0].filePath, htmlFiles, publicDir);

        // XACA-1022-008 finding: as of this writing, every `<label for=>` in
        // fleet-monitor's shipped HTML sits inside a `.modal-overlay` /
        // `.modal-content` / `.modal-body` / `.form-group` chain (the
        // engines-add/engines-edit account modals, replicated near-
        // identically across lcars/lcars-dashboard.html and the four
        // lcars2/lcars-*.html variants). None of those ancestor classes
        // appear in _classifyMatch's selector list, so the label-for
        // double-play vector does NOT currently manifest anywhere in this
        // codebase. If this assertion ever fails, that is a REAL new
        // double-play hazard introduced by markup change — do not silence
        // it by loosening the selector match; go add a
        // stopPropagation/target-check fix to the click dispatch and file a
        // ticket, per the XACA-1022-008 task instructions.
        assert.equal(hazards.length, 0,
            'found <label for=> element(s) inside a sound-mapped ancestor — real double-play risk: ' +
            JSON.stringify(hazards));
    });

test('label-for double-play investigation (XACA-1022-018): every <label for=> in lcars-ui/index.html has a NON-sound-mapped ancestor chain',
    function () {
        // Extends the scan above to lcars-ui's own shipped markup, checked
        // against lcars-ui's own engine copy (ENGINES[1]) — previously this
        // suite only ever walked fleet-monitor/server/public/**/*.html, so a
        // lcars-ui-only markup change nesting a <label for=> inside a
        // sound-mapped ancestor would have shipped with no automated guard
        // on this surface at all.
        var lcarsUiDir = path.join(__dirname, '..');
        var htmlFiles = [path.join(lcarsUiDir, 'index.html')];

        var hazards = scanLabelForHazards('lcars-ui', ENGINES[1].filePath, htmlFiles, lcarsUiDir);

        // Measured at write time (XACA-1022-018): 31 distinct <label for=>
        // ids in lcars-ui/index.html, none of them inside an ancestor that
        // matches any of _classifyMatch's 20 distinct selectors — every one
        // sits inside plain layout/modal wrappers (e.g. .secrets-export-*,
        // .team-config-*, .modal-*) that carry no sound-mapped class. If
        // this assertion ever fails, that is a REAL new double-play hazard
        // introduced by an index.html markup change — do not silence it by
        // loosening the selector match; fix the click dispatch and file a
        // ticket, same as the fleet-monitor investigation above.
        assert.equal(hazards.length, 0,
            'found <label for=> element(s) inside a sound-mapped ancestor in lcars-ui/index.html — real double-play risk: ' +
            JSON.stringify(hazards));
    });

// ═════════════════════════════════════════════════════════════════════════
// What remains UNVERIFIED by this suite (see also the XACA-1022-008 report):
//   - Real Safari/WebKit pointerdown->click event ORDERING and timing on an
//     actual iPhone (this suite's document stub enforces capture-before-
//     bubble by construction; it does not prove real WebKit does the same
//     for touch-originated events under load).
//   - Real touch-to-scroll gesture disambiguation (pointercancel timing is
//     simulated by direct dispatch, not by an actual finger-drag).
//   - The real pointerdown -> pointerup -> click ORDERING the XACA-1022-017
//     pointerup guard relies on (a click firing AFTER its gesture's
//     pointerup is asserted from the DOM event-order spec in this file's
//     comments, not observed on a real device — this suite's stub dispatches
//     events in whatever order a test tells it to, it does not enforce or
//     verify the browser's own ordering).
//   - The real keydown -> click ORDERING the XACA-1022-014 keyboard-fallback
//     guard relies on (that a capture-phase `document` keydown listener runs
//     before an inline `onkeydown` attribute's `this.click()` call, and
//     before a native <button>'s own Enter/Space activation) — reasoned from
//     the DOM event-phase spec, not observed in a real browser.
//   - Any actual latency number (pointerdown-to-audible-tone). This suite
//     has no audio output and no wall clock measurement; that is the
//     probe/xaca-1022-audio-latency.html harness's job, on a real device.
// A human needs a real iPhone in mobile Safari (Fleet Monitor's stated
// target surface) to close all of the above.
// ═════════════════════════════════════════════════════════════════════════
