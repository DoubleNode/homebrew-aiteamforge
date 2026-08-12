//
//  test_xaca0920_copy_to_clipboard.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * test_xaca0920_copy_to_clipboard.js — Node-native headless coverage for the
 * XACA-0920 two-tier copyToClipboard() fix in lcars.js.
 *
 * SCOPE: this suite covers only the control-flow logic (tier selection,
 * fallback dispatch, toast routing, DOM cleanup, return-value contract) using
 * stubbed navigator/document/window objects. It CANNOT and does NOT exercise
 * a real WKWebView: real Clipboard API permission behavior, actual
 * document-focus timing, and real execCommand() transient-activation
 * enforcement are unavailable in Node and remain untested here. See the
 * XACA-0920-007 test report for the full list of what remains uncovered.
 *
 * lcars.js is a browser-only script with no module.exports (like
 * lcars-cr-tab.js). Rather than hand-reimplement copyToClipboard() — which
 * would test a reimplementation, not the shipped code — this file extracts
 * the exact function source from the shipped file by unique start/end text
 * markers and evaluates it in a fresh vm context per test, with
 * navigator/document/window/showToast stubbed. If a marker goes missing (the
 * surrounding code was refactored), extraction fails loudly instead of
 * silently testing stale text.
 *
 * Usage:
 *   node --test lcars-ui/tests/test_xaca0920_copy_to_clipboard.js
 *
 * No external dependencies. Node >=18 required (node:test, node:vm built-in).
 */

'use strict';

var test   = require('node:test');
var assert = require('node:assert/strict');
var path   = require('path');
var fs     = require('fs');
var vm     = require('vm');

var LCARS_JS_PATH = path.join(__dirname, '../js/lcars.js');
var SRC = fs.readFileSync(LCARS_JS_PATH, 'utf8');

// ─── Extract copyToClipboard (self-contained: only touches its own params,
// ─── document, navigator, window, console, showToast — all stubbed below) ──

var START_MARKER = 'function copyToClipboard(text, options) {';
var END_MARKER   = '\n/**\n * Show a temporary toast notification';

function extractCopyToClipboardSrc() {
    var start = SRC.indexOf(START_MARKER);
    assert.ok(start !== -1, 'Could not locate copyToClipboard() start marker in lcars.js — has it moved/been renamed?');
    var end = SRC.indexOf(END_MARKER, start + START_MARKER.length);
    assert.ok(end !== -1, 'Could not locate copyToClipboard() end marker in lcars.js — has the following section changed?');
    return SRC.slice(start, end);
}

var copySrc = extractCopyToClipboardSrc();

// ─── Sandbox factory ────────────────────────────────────────────────────────

/**
 * Builds a fresh vm context stubbing everything copyToClipboard() touches,
 * evaluates the extracted source in it, and returns the bound function plus
 * observation arrays/sets for assertions.
 *
 * opts:
 *   apiAvailable      {boolean}  default true. false => navigator.clipboard
 *                                 is entirely absent (Tier-1 API-missing path).
 *   writeText         {'resolve'|'reject'} default 'resolve'.
 *   writeTextError    {object}   custom rejection value (name/message).
 *   execCommand       {'true'|'false'|'throw'} document.execCommand() outcome.
 *   execCommandThrowMessage {string}
 *   hasFocus          {boolean}  document.hasFocus() return value.
 *   visibilityState   {string}
 *   windowFocusThrows {boolean}  make window.focus() throw (best-effort path).
 */
function makeEnv(opts) {
    opts = opts || {};

    var toastCalls        = [];
    var execCommandCalls   = [];
    var appendCalls        = [];
    var removeCalls        = [];
    var focusCalls         = [];
    var domNodes           = new Set();
    var textareaCreated    = [];

    var previousActiveElement = {
        focus: function () { focusCalls.push('previousActiveElement'); }
    };

    var sandbox = {
        console: { log: function () {}, warn: function () {}, error: function () {} },
        showToast: function (message, type) {
            toastCalls.push({ message: message, type: type });
        },
        document: {
            activeElement: previousActiveElement,
            createElement: function (tag) {
                var el = {
                    tagName: tag,
                    value: '',
                    style: {},
                    readOnly: false,
                    _selected: false,
                    _range: null,
                    select: function () { el._selected = true; },
                    setSelectionRange: function (a, b) { el._range = [a, b]; }
                };
                textareaCreated.push(el);
                return el;
            },
            body: {
                appendChild: function (el) { appendCalls.push(el); domNodes.add(el); },
                removeChild: function (el) { removeCalls.push(el); domNodes.delete(el); }
            },
            execCommand: function (cmd) {
                execCommandCalls.push(cmd);
                if (opts.execCommand === 'throw') {
                    throw new Error(opts.execCommandThrowMessage || 'execCommand blew up');
                }
                return opts.execCommand === 'true';
            },
            hasFocus: function () { return opts.hasFocus !== undefined ? opts.hasFocus : true; },
            visibilityState: opts.visibilityState || 'visible'
        },
        window: {
            focus: function () {
                focusCalls.push('window');
                if (opts.windowFocusThrows) throw new Error('focus not supported in this context');
            }
        },
        navigator: {}
    };

    if (opts.apiAvailable === false) {
        // navigator.clipboard left undefined => Tier-1 API-missing path.
    } else {
        sandbox.navigator.clipboard = {
            writeText: function () {
                if (opts.writeText === 'reject') {
                    return Promise.reject(
                        opts.writeTextError || { name: 'NotAllowedError', message: 'Document is not focused.' }
                    );
                }
                return Promise.resolve();
            }
        };
    }

    vm.createContext(sandbox);
    vm.runInContext(copySrc + '\nthis.copyToClipboard = copyToClipboard;', sandbox);
    assert.equal(typeof sandbox.copyToClipboard, 'function', 'Failed to extract copyToClipboard from lcars.js');

    return {
        copyToClipboard: sandbox.copyToClipboard,
        toastCalls: toastCalls,
        execCommandCalls: execCommandCalls,
        appendCalls: appendCalls,
        removeCalls: removeCalls,
        focusCalls: focusCalls,
        domNodes: domNodes,
        textareaCreated: textareaCreated
    };
}

function successToasts(env) { return env.toastCalls.filter(function (t) { return t.type === 'success'; }); }
function errorToasts(env)   { return env.toastCalls.filter(function (t) { return t.type === 'error'; }); }

// ─── 1. Tier-1 success ──────────────────────────────────────────────────────

test('Tier-1 success: resolves true, one success toast, execCommand never invoked', async () => {
    var env = makeEnv({ apiAvailable: true, writeText: 'resolve' });
    var result = await env.copyToClipboard('hello-world');

    assert.equal(result, true);
    assert.equal(env.toastCalls.length, 1);
    assert.equal(env.toastCalls[0].type, 'success');
    assert.equal(env.execCommandCalls.length, 0);
    assert.ok(env.focusCalls.indexOf('window') !== -1, 'window.focus() best-effort should be attempted before Tier-1');
});

// ─── 2. Tier-1 rejection -> Tier-2 success (the core defect being fixed) ───

test('Tier-1 rejection -> Tier-2 success: resolves true, success toast, execCommand invoked exactly once', async () => {
    var env = makeEnv({ apiAvailable: true, writeText: 'reject', execCommand: 'true' });
    var result = await env.copyToClipboard('hello-world');

    assert.equal(result, true, 'A rejected writeText() must now fall through to a working execCommand fallback');
    assert.equal(env.execCommandCalls.length, 1);
    assert.equal(successToasts(env).length, 1);
    assert.equal(errorToasts(env).length, 0);
});

// ─── 3. Tier-1 rejection -> Tier-2 returns false (no throw) — false-success guard ─

test('Tier-1 rejection -> Tier-2 returns false: resolves false, error toast, NO success toast', async () => {
    var env = makeEnv({ apiAvailable: true, writeText: 'reject', execCommand: 'false' });
    var result = await env.copyToClipboard('hello-world');

    assert.equal(result, false, 'execCommand returning false (without throwing) must not be reported as success');
    assert.equal(successToasts(env).length, 0, 'A false execCommand result must never produce a success toast');
    assert.equal(errorToasts(env).length, 1);
});

// ─── 4. Tier-1 rejection -> Tier-2 throws — cleanup guarantees ─────────────

test('Tier-1 rejection -> Tier-2 throws: resolves false, error toast, textarea removed (no orphan), focus restored', async () => {
    var env = makeEnv({
        apiAvailable: true,
        writeText: 'reject',
        execCommand: 'throw',
        execCommandThrowMessage: 'SecurityError: clipboard write blocked'
    });
    var result = await env.copyToClipboard('hello-world');

    assert.equal(result, false);
    assert.equal(errorToasts(env).length, 1);
    assert.ok(errorToasts(env)[0].message.indexOf('SecurityError: clipboard write blocked') !== -1,
        'thrown error detail should surface in the toast');

    // Cleanup guarantees from the try/finally around append/select/execCommand:
    assert.equal(env.appendCalls.length, 1, 'textarea should have been appended exactly once');
    assert.equal(env.removeCalls.length, 1, 'textarea must be removed even when execCommand throws');
    assert.equal(env.domNodes.size, 0, 'no orphan node should remain attached after a thrown execCommand');
    assert.ok(env.focusCalls.indexOf('previousActiveElement') !== -1, 'previously-focused element must be refocused');
});

// ─── 5. API absent entirely — straight to Tier 2 ───────────────────────────

test('API absent entirely: skips straight to Tier-2, success path works, window.focus() NOT attempted', async () => {
    var env = makeEnv({ apiAvailable: false, execCommand: 'true' });
    var result = await env.copyToClipboard('hello-world');

    assert.equal(result, true);
    assert.equal(env.execCommandCalls.length, 1);
    assert.equal(successToasts(env).length, 1);
    assert.equal(env.focusCalls.indexOf('window'), -1,
        'window.focus() best-effort call is only in the Tier-1 branch; API-absent path must not reach it');
});

test('API absent entirely + Tier-2 also fails: resolves false with the API-missing failure toast', async () => {
    var env = makeEnv({ apiAvailable: false, execCommand: 'false' });
    var result = await env.copyToClipboard('hello-world');

    assert.equal(result, false);
    assert.equal(successToasts(env).length, 0);
    assert.equal(errorToasts(env).length, 1);
    assert.ok(errorToasts(env)[0].message.indexOf('no Clipboard API') !== -1,
        'API-absent failure toast should self-identify as the no-API case');
});

// ─── 6. Toast distinctness — a screenshot alone must identify which tier failed ─

test('Toast distinctness: the three observed failure messages are pairwise distinct and self-identifying', async () => {
    var envApiAbsent = makeEnv({ apiAvailable: false, execCommand: 'false' });
    await envApiAbsent.copyToClipboard('hello-world');
    var msgApiAbsent = errorToasts(envApiAbsent)[0].message;

    var envRejectFalse = makeEnv({ apiAvailable: true, writeText: 'reject', execCommand: 'false' });
    await envRejectFalse.copyToClipboard('hello-world');
    var msgRejectFalse = errorToasts(envRejectFalse)[0].message;

    var envRejectThrow = makeEnv({ apiAvailable: true, writeText: 'reject', execCommand: 'throw', execCommandThrowMessage: 'boom' });
    await envRejectThrow.copyToClipboard('hello-world');
    var msgRejectThrow = errorToasts(envRejectThrow)[0].message;

    var messages = [msgApiAbsent, msgRejectFalse, msgRejectThrow];
    var unique = new Set(messages);
    assert.equal(unique.size, 3, 'Expected 3 pairwise-distinct failure messages, got: ' + JSON.stringify(messages));

    // Self-identifying: each message names which tier/cause failed.
    assert.ok(msgApiAbsent.indexOf('no Clipboard API') !== -1);
    assert.ok(msgRejectFalse.indexOf('API NotAllowedError') !== -1 && msgRejectFalse.indexOf('fallback execCommand returned false') !== -1);
    assert.ok(msgRejectThrow.indexOf('API NotAllowedError') !== -1 && msgRejectThrow.indexOf('boom') !== -1);
});

test('Tier-1-rejection failure toast embeds hasFocus/visibilityState diagnostic payload', async () => {
    var env = makeEnv({ apiAvailable: true, writeText: 'reject', execCommand: 'false', hasFocus: false, visibilityState: 'hidden' });
    await env.copyToClipboard('hello-world');

    var msg = errorToasts(env)[0].message;
    assert.ok(msg.indexOf('focus=false') !== -1, 'Expected focus=false in diagnostic payload. Got: ' + msg);
    assert.ok(msg.indexOf('visibility=hidden') !== -1, 'Expected visibility=hidden in diagnostic payload. Got: ' + msg);
});

// ─── 7. Backward compatibility ──────────────────────────────────────────────

test('Backward compat: single-arg call defaults successMessage to "Copied: <text>"', async () => {
    var env = makeEnv({ apiAvailable: true, writeText: 'resolve' });
    await env.copyToClipboard('XACA-0920');

    assert.equal(env.toastCalls.length, 1);
    assert.equal(env.toastCalls[0].message, 'Copied: XACA-0920');
});

test('Custom successMessage (relnotes-style) is used instead of echoing the payload', async () => {
    var env = makeEnv({ apiAvailable: true, writeText: 'resolve' });
    var largeBlob = 'RELEASE NOTES\n'.repeat(50) + 'lots of content that must not be echoed into a toast';
    await env.copyToClipboard(largeBlob, { successMessage: 'Release notes copied to clipboard' });

    assert.equal(env.toastCalls.length, 1);
    assert.equal(env.toastCalls[0].message, 'Release notes copied to clipboard');
    assert.ok(env.toastCalls[0].message.indexOf('RELEASE NOTES') === -1, 'Large payload must not be echoed into the toast');
});

// ─── 8. Empty/falsy input ───────────────────────────────────────────────────

test('Empty string input resolves false without toasting', async () => {
    var env = makeEnv({ apiAvailable: true, writeText: 'resolve' });
    var result = await env.copyToClipboard('');

    assert.equal(result, false);
    assert.equal(env.toastCalls.length, 0);
    assert.equal(env.execCommandCalls.length, 0, 'must short-circuit before touching the clipboard API');
});

test('null/undefined input resolves false without toasting', async () => {
    var envNull = makeEnv({ apiAvailable: true, writeText: 'resolve' });
    assert.equal(await envNull.copyToClipboard(null), false);
    assert.equal(envNull.toastCalls.length, 0);

    var envUndef = makeEnv({ apiAvailable: true, writeText: 'resolve' });
    assert.equal(await envUndef.copyToClipboard(undefined), false);
    assert.equal(envUndef.toastCalls.length, 0);
});

// ─── 9. window.focus() best-effort — must never abort the copy ────────────

test('window.focus() throwing is swallowed and Tier-1 still proceeds to success', async () => {
    var env = makeEnv({ apiAvailable: true, writeText: 'resolve', windowFocusThrows: true });
    var result = await env.copyToClipboard('hello-world');

    assert.equal(result, true, 'window.focus() best-effort failure must not abort the copy attempt');
    assert.equal(successToasts(env).length, 1);
});
