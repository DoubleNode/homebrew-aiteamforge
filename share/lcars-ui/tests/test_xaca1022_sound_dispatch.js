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
 * TWO ENGINE COPIES, BOTH COVERED: fleet-monitor and lcars-ui ship separate,
 * diverged copies of this file (not mirrors of one canonical source). They
 * differ by exactly one line: fleet-monitor's `_classifySound` alert branch
 * carries a `.legend-pill` selector (XACA-0963) that lcars-ui's does not,
 * which changes what `.legend-pill` classifies as between the two copies.
 * This suite runs the FULL matrix against BOTH files and asserts that
 * divergence explicitly (see the "legend-pill parity" tests) — normalizing
 * it away in a test would be a false pass on real, intentional behavior.
 *
 * WHOLE-FILE EVAL, NOT PER-FUNCTION EXTRACTION: unlike
 * test_xaca0920_copy_to_clipboard.js (which extracts one function out of a
 * large multi-purpose file), lcars-sound.js is itself a single self-contained
 * IIFE built for exactly this purpose — extracting a sub-function would still
 * require re-supplying its private closure state (`_muted`,
 * `_pendingPointerTarget`, etc.), which is exactly what
 * evaluating the whole IIFE gives us for free. So this suite reads the
 * ENTIRE shipped file with fs.readFileSync and runs it verbatim in a fresh
 * vm context per test — no hand-reimplemented logic anywhere in this file.
 *
 * The one thing this suite adds to the shipped source is a single-line,
 * marker-anchored splice immediately after the shipped `window.LCARSSound =
 * LCARSSound;` export line: an additional `window.__TEST_HOOKS__ = {...}`
 * object exposing the IIFE's otherwise-private internals (the
 * classification function, the mute/pending-pointer state) so
 * assertions can reach them. This is a peephole for observation only — it
 * adds no new logic and calls no shipped function differently than
 * production does. If the export line's exact text ever moves or changes,
 * the marker lookup below fails loudly (an `assert.ok`) rather than silently
 * testing against a stale splice point — mirroring the guarantee
 * test_xaca0920_copy_to_clipboard.js makes for its own start/end markers.
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
        legendPillType: 'alert',       // XACA-0963: fleet-monitor's alert branch carries .legend-pill
        totalClosestCalls: 22,
        distinctSelectors: 20
    },
    {
        label: 'lcars-ui',
        filePath: path.join(__dirname, '../js/lcars-sound.js'),
        legendPillType: 'action',      // lacks the XACA-0963 alert-branch line — falls through to action group
        totalClosestCalls: 21,
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
        '        playWav: _playWav,\n' +
        '        isMuted: function () { return _muted; },\n' +
        '        setMuted: function (v) { _muted = v; },\n' +
        '        getPendingPointerTarget: function () { return _pendingPointerTarget; },\n' +
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
 */
function makeTarget(matchSelectors) {
    var set = new Set(matchSelectors || []);
    return {
        closest: function (sel) { return set.has(sel) ? this : null; }
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

function dispatchPointercancel(env, pointerId) {
    env.doc._dispatch('pointercancel', { pointerId: pointerId });
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
        assert.equal(env.hooks.getPendingPointerTarget(), null, 'guard must not be armed for a non-primary button');
    });

    test(P + 'e.isPrimary === false (secondary touch contact) plays nothing on pointerdown', function () {
        var env = wrapPlay(buildEnv(engine));
        var target = makeTarget(['.card']);
        dispatchPointerdown(env, target, { isPrimary: false, pointerId: 7 });
        assert.equal(env.dispatchLog.length, 0);
        assert.equal(env.hooks.getPendingPointerTarget(), null);
    });

    test(P + 'pointercancel clears the guard; a later unrelated click is not swallowed', function () {
        var env = wrapPlay(buildEnv(engine));
        var targetA = makeTarget(['.sidebar-button']);
        var targetB = makeTarget(['.btn-lcars']);

        dispatchPointerdown(env, targetA, { pointerId: 5 });
        assert.equal(env.dispatchLog.length, 1);
        assert.equal(env.hooks.getPendingPointerTarget(), targetA);

        dispatchPointercancel(env, 5);
        assert.equal(env.hooks.getPendingPointerTarget(), null, 'pointercancel must clear the guard');

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
        assert.equal(env.hooks.getPendingPointerTarget(), targetA);

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

    // ─── legend-pill parity: intentional, pre-existing divergence ─────────

    test(P + 'classify: .legend-pill -> ' + engine.legendPillType + ' (intentional cross-engine divergence, do not normalize)',
        function () {
            var env = buildEnv(engine);
            assert.equal(env.hooks.classifySound(makeTarget(['.legend-pill'])), engine.legendPillType);
        });

    if (engine.label === 'fleet-monitor') {
        test(P + 'FINDING: the action-group .legend-pill line is dead code, shadowed by the earlier alert-group entry',
            function () {
                // fleet-monitor's _classifySound lists '.legend-pill' TWICE:
                // once in the alert-group condition (XACA-0963) and again,
                // unconditionally, in the action-group condition further
                // down. Because the alert-group `if` runs first and already
                // returns 'alert' for any target matching '.legend-pill',
                // the action-group's own '.legend-pill' check can never be
                // reached for such a target — it is unreachable/dead code.
                // This is PRE-EXISTING (not introduced by this ticket's
                // diff) and out of this ticket's scope to fix; recorded here
                // so it isn't rediscovered as a surprise later. It does NOT
                // affect lcars-ui, which only lists '.legend-pill' once (in
                // the action group), where it IS reachable.
                var env = buildEnv(engine);
                assert.equal(env.hooks.classifySound(makeTarget(['.legend-pill'])), 'alert',
                    'a target matching ONLY .legend-pill resolves via the alert group, never reaching the action group\'s own .legend-pill check');
            });
    }

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

test('the two engine copies differ by exactly the one documented .legend-pill line', function () {
    var fleetSrc = fs.readFileSync(ENGINES[0].filePath, 'utf8').split('\n');
    var lcarsSrc = fs.readFileSync(ENGINES[1].filePath, 'utf8').split('\n');

    // A full diff algorithm is unnecessary here: the two files are expected
    // to be IDENTICAL except for one inserted line in fleet-monitor. If a
    // real diff ever grows beyond that, this file-length delta assertion
    // catches it immediately (loudly, not silently), even though it doesn't
    // itself pinpoint the new difference — `diff` in a terminal does that.
    assert.equal(fleetSrc.length, lcarsSrc.length + 1,
        'fleet-monitor should have exactly one MORE line than lcars-ui (the XACA-0963 .legend-pill alert-branch line). ' +
        'If this fails, the two copies have diverged further than this suite assumes — re-run `diff` on both files ' +
        'and update either the source files or this pin.');

    var legendLine = fleetSrc.filter(function (l) { return l.indexOf('XACA-0963') !== -1; });
    assert.equal(legendLine.length, 1, 'expected exactly one XACA-0963-tagged line in fleet-monitor\'s copy');
    assert.ok(legendLine[0].indexOf(".closest('.legend-pill')") !== -1,
        'the extra fleet-monitor line should be the .legend-pill closest() check');
});

ENGINES.forEach(function (engine) {
    test('[' + engine.label + '] _classifySound has the expected total closest() call count (' + engine.totalClosestCalls + ')',
        function () {
            var src = fs.readFileSync(engine.filePath, 'utf8');
            var start = src.indexOf('function _classifySound(target) {');
            assert.ok(start !== -1, '[' + engine.label + '] could not locate _classifySound() — has it been renamed?');
            var end = src.indexOf('\n    // XACA-1022: press/click dedupe guard.', start);
            assert.ok(end !== -1, '[' + engine.label + '] could not locate the dedupe-guard comment marking the end of _classifySound()');
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
// This static scan walks every `<label ... for="...">` in fleet-monitor's
// shipped HTML and collects the class/id/data-* selectors of its DOM
// ancestors (a small hand-rolled tag-stack parser — sufficient for this
// codebase's well-formed, non-self-closing-div markup; it is NOT a general
// HTML parser). It then checks those ancestor selectors against the ACTUAL
// selector list _classifySound uses (parsed from the shipped file itself, so
// this test does not go stale if new selectors are added later).
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
    var start = src.indexOf('function _classifySound(target) {');
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

test('label-for double-play investigation: every <label for=> in fleet-monitor\'s shipped HTML has a NON-sound-mapped ancestor chain',
    function () {
        var fleetSoundSrc = fs.readFileSync(ENGINES[0].filePath, 'utf8');
        var soundSelectors = extractClassifySelectors(fleetSoundSrc);
        assert.ok(soundSelectors.size > 0, 'sanity: expected to extract at least one selector from _classifySound()');

        function walk(dir, out) {
            fs.readdirSync(dir, { withFileTypes: true }).forEach(function (entry) {
                var full = path.join(dir, entry.name);
                if (entry.isDirectory()) { walk(full, out); return; }
                if (entry.isFile() && entry.name.endsWith('.html')) out.push(full);
            });
        }

        var publicDir = path.join(__dirname, '../../fleet-monitor/server/public');
        var htmlFiles = [];
        walk(publicDir, htmlFiles);
        assert.ok(htmlFiles.length > 0, 'sanity: expected to find at least one HTML file under fleet-monitor/server/public');

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
                    file + ': label for="' + forId + '" matched by scan regex but not by the ancestor-walk parser — ' +
                    'investigate the tag-stack parser, don\'t assume this is safe.');
                checked++;
                var hazard = ancestorSelectorsIntersectSoundMap(ancestors, soundSelectors);
                if (hazard) {
                    hazards.push({ file: path.relative(publicDir, file), forId: forId, selector: hazard });
                }
            }
        });

        assert.ok(checked > 0, 'sanity: expected to find and check at least one <label for=> element');

        // XACA-1022-008 finding: as of this writing, every `<label for=>` in
        // fleet-monitor's shipped HTML sits inside a `.modal-overlay` /
        // `.modal-content` / `.modal-body` / `.form-group` chain (the
        // engines-add/engines-edit account modals, replicated near-
        // identically across lcars/lcars-dashboard.html and the four
        // lcars2/lcars-*.html variants). None of those ancestor classes
        // appear in _classifySound's selector list, so the label-for
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

// ═════════════════════════════════════════════════════════════════════════
// What remains UNVERIFIED by this suite (see also the XACA-1022-008 report):
//   - Real Safari/WebKit pointerdown->click event ORDERING and timing on an
//     actual iPhone (this suite's document stub enforces capture-before-
//     bubble by construction; it does not prove real WebKit does the same
//     for touch-originated events under load).
//   - Real touch-to-scroll gesture disambiguation (pointercancel timing is
//     simulated by direct dispatch, not by an actual finger-drag).
//   - Any actual latency number (pointerdown-to-audible-tone). This suite
//     has no audio output and no wall clock measurement; that is the
//     probe/xaca-1022-audio-latency.html harness's job, on a real device.
// A human needs a real iPhone in mobile Safari (Fleet Monitor's stated
// target surface) to close both of the above.
// ═════════════════════════════════════════════════════════════════════════
