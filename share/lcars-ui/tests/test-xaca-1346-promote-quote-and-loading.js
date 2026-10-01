#!/usr/bin/env node
//
//  test-xaca-1346-promote-quote-and-loading.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 DoubleNode.com. All rights reserved.
//

/**
 * XACA-1346-057/-058: every interpolated arg of a remedy command (release id, stage, test name) is POSIX
 * single-quoted so a pasted command cannot run anything the release/test name smuggles in.
 *   'x' -> 'x',  embedded ' -> '\''
 * Proven two ways: (1) exact expected strings for a table of hostile inputs; (2) a REAL /bin/sh reads the
 * quoted word back and must produce the original bytes (a $(id) that executed would print the uid, not
 * the literal text).
 *
 * XACA-1346-056: the promote modal opens IMMEDIATELY in a "Checking gate..." state with PROMOTE disabled
 * while the dryRun preview loads, and a second click must not start a second preview.
 *
 * Like the sibling suite, this slices the DOM-free block (and promoteRelease) out of lcars.js.
 *
 * Run: node lcars-ui/tests/test-xaca-1346-promote-quote-and-loading.js
 */

'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('assert');
const vm = require('vm');
const { execFileSync } = require('child_process');

const source = fs.readFileSync(path.join(__dirname, '..', 'js', 'lcars.js'), 'utf8');

function slice(startAnchor, endAnchor) {
    const s = source.indexOf(startAnchor);
    const e = source.indexOf(endAnchor, s + 1);
    if (s === -1 || e === -1) {
        console.error('FAIL: could not locate anchors ' + JSON.stringify(startAnchor) + ' .. ' + JSON.stringify(endAnchor));
        process.exit(1);
    }
    return source.slice(s, e);
}

const PURE = slice('// >>> PROMOTE-MODAL-PURE-START', '// <<< PROMOTE-MODAL-PURE-END');
const PROMOTE_FN = slice('async function promoteRelease(releaseId) {', '/**\n * Hide the promote modal.');
const STEP_NEXT = slice('function promoteStepNext() {', '/**\n * Execute the promotion');

let failures = 0;
let passed = 0;
async function test(name, fn) {
    try { await fn(); passed += 1; console.log('ok - ' + name); } catch (err) {
        failures += 1;
        console.error('FAIL: ' + name + ': ' + (err && err.message));
    }
}

function pureApi() {
    const sb = { JSON, Array, Object, String, RegExp, Set, Map };
    vm.createContext(sb);
    vm.runInContext(PURE + '\nthis.api = {promoteQuoteArg, promoteGammaCommand, promoteWaiveCommand, ' +
        'promoteBeginPreview, promoteLoadingModel, buildPromoteReasonItems};', sb);
    return sb.api;
}
const api = pureApi();

// ── (1) quoting ──────────────────────────────────────────────────────────────────────────
const HOSTILE = [
    ['plain', 'lead-time', "'lead-time'"],
    ['space', 'my test', "'my test'"],
    ['command substitution', '$(id)', "'$(id)'"],
    ['backticks', '`id`', "'`id`'"],
    ['variable', '$HOME ${IFS}', "'$HOME ${IFS}'"],
    ['history bang', 'a!b !!', "'a!b !!'"],
    ['double quote', 'say "hi"', "'say \"hi\"'"],
    ['single quote', "it's", "'it'\\''s'"],
    ['both quotes', `a'b"c`, `'a'\\''b"c'`],
    ['only a single quote', "'", "''\\'''"],
    ['semicolon + redirect', 'x; rm -rf / > /dev/null', "'x; rm -rf / > /dev/null'"],
    ['backslash', 'a\\b', "'a\\b'"],
    ['newline', 'a\nb', "'a\nb'"],
    ['empty', '', "''"],
];

for (const [name, input, expected] of HOSTILE) {
    test('promoteQuoteArg(' + name + ') -> exact POSIX single-quoted word', () => {
        assert.strictEqual(api.promoteQuoteArg(input), expected);
    });
    test('promoteQuoteArg(' + name + ') is inert: a real /bin/sh reads back the original bytes', () => {
        const out = execFileSync('/bin/sh', ['-c', 'printf %s ' + api.promoteQuoteArg(input)], { encoding: 'utf8' });
        assert.strictEqual(out, input);
    });
}

test('numbers and non-strings are stringified, never executed', () => {
    assert.strictEqual(api.promoteQuoteArg(42), "'42'");
});

test('release id is quoted in BOTH commands (a hostile id cannot break out)', () => {
    const id = "REL-1'; touch /tmp/pwned; echo '";
    const gamma = api.promoteGammaCommand(id);
    const waive = api.promoteWaiveCommand(id, { stage: 'QA', test: 't' }, '<lead>');
    for (const cmd of [gamma, waive]) {
        assert.ok(cmd.includes(api.promoteQuoteArg(id)), 'id not quoted in ' + cmd);
        assert.ok(!/ REL-1';/.test(cmd), 'raw id leaked into ' + cmd);
    }
    // Tokenize the whole command with a real shell word-splitter: the id must survive as ONE argv word.
    const argv = execFileSync('/bin/sh', ['-c', 'for a in ' + waive.replace(/--reason "\.\.\." --by <lead>$/, '') + '; do printf "%s\\n" "$a"; done'], { encoding: 'utf8' }).split('\n');
    assert.strictEqual(argv[2], id);
});

test('stage and test name from the server are quoted; placeholders stay bare', () => {
    const c = api.promoteWaiveCommand('REL-1', { stage: "Q'A", test: '$(id)' }, '<lead>');
    assert.strictEqual(c, "kb-release waive 'REL-1' --stage 'Q'\\''A' --tests '$(id)' --reason \"...\" --by <lead>");
    const bare = api.promoteWaiveCommand('REL-1', null, '<lead>');
    assert.ok(bare.includes('--stage <STAGE> --tests <test>'));
});

// ── (2) loading feedback + single preview ────────────────────────────────────────────────
function modalHarness() {
    const els = {};
    const get = (id) => (els[id] = els[id] || { id, innerHTML: '', textContent: '', disabled: false, style: {} });
    const gates = [];
    const fetched = [];
    const calls = { populate: 0, toasts: [] };
    const sb = {
        promoteModalState: { releaseId: null, releaseData: null, currentStep: 1, preview: null, result: null, inFlight: false, loading: false, token: 0 },
        document: { getElementById: get },
        apiUrl: (p) => p,
        escapeHtml: (x) => String(x).replace(/[&<>"']/g, (c) => '&#' + c.charCodeAt(0) + ';'),
        fetch: (url) => { fetched.push(url); return new Promise((res) => gates.push({ kind: 'release', res })); },
        apiFetch: (url, opts) => { fetched.push(url + ' ' + opts.body); return new Promise((res) => gates.push({ kind: 'preview', res })); },
        populatePromotePreview: () => { calls.populate += 1; get('promote-next-btn').disabled = false; get('promote-next-btn').textContent = 'PROMOTE'; },
        updatePromoteStepIndicator: () => {},
        showPromoteStep: () => {},
        showToast: (m) => calls.toasts.push(m),
        console, JSON, Array, Object, String, RegExp, Set, Map, Promise,
    };
    vm.createContext(sb);
    vm.runInContext(PURE + '\n' + PROMOTE_FN +
        '\nfunction hidePromoteModal() { document.getElementById("promote-modal").style.display = "none"; ' +
        'promoteModalState = { releaseId: null, releaseData: null, currentStep: 1, preview: null, result: null, inFlight: false }; }' +
        '\nthis.promoteRelease = promoteRelease; this.hidePromoteModal = hidePromoteModal;', sb);
    const okJson = (body) => ({ ok: true, status: 200, json: async () => body });
    const flush = () => new Promise((r) => setImmediate(r));
    return { sb, get, gates, fetched, calls, okJson, flush };
}

test('modal opens immediately in a loading state: "Checking gate...", PROMOTE disabled, before any response', async () => {
    const h = modalHarness();
    h.sb.promoteRelease('REL-1');          // not awaited: the release fetch is still pending
    assert.strictEqual(h.get('promote-modal').style.display, 'flex');
    assert.ok(h.get('promote-preview').innerHTML.includes('Checking gate…'));
    assert.strictEqual(h.get('promote-next-btn').disabled, true);
    assert.strictEqual(h.get('promote-next-btn').textContent, 'CHECKING GATE…');
    assert.strictEqual(h.sb.promoteModalState.loading, true);
    assert.strictEqual(h.calls.populate, 0);
});

test('a second click while the preview loads starts NO second preview (one release fetch, one dry run)', async () => {
    const h = modalHarness();
    h.sb.promoteRelease('REL-1');
    h.sb.promoteRelease('REL-1');
    h.sb.promoteRelease('REL-1');
    assert.strictEqual(h.fetched.length, 1, 'extra requests: ' + h.fetched.join(' | '));
    h.gates[0].res(h.okJson({ id: 'REL-1' }));
    await h.flush();
    h.sb.promoteRelease('REL-1');          // still loading (dry run pending)
    assert.strictEqual(h.fetched.length, 2);
    assert.ok(/dryRun/.test(h.fetched[1]));
    h.gates[1].res(h.okJson({ allowed: true, from: 'QA', to: 'ALPHA', reasons: [] }));
    await h.flush();
    assert.strictEqual(h.fetched.length, 2);
});

test('when the preview arrives: loading clears, the normal preview populates, PROMOTE follows the verdict', async () => {
    const h = modalHarness();
    h.sb.promoteRelease('REL-1');
    h.gates[0].res(h.okJson({ id: 'REL-1' }));
    await h.flush();
    assert.strictEqual(h.sb.promoteModalState.loading, true, 'still loading until the dry run returns');
    h.gates[1].res(h.okJson({ allowed: true, from: 'QA', to: 'ALPHA', reasons: [] }));
    await h.flush();
    assert.strictEqual(h.sb.promoteModalState.loading, false);
    assert.strictEqual(h.calls.populate, 1);
    assert.strictEqual(h.get('promote-next-btn').textContent, 'PROMOTE');
});

test('release load failure closes the loading modal (no stuck "Checking gate...")', async () => {
    const h = modalHarness();
    h.sb.promoteRelease('REL-1');
    h.gates[0].res({ ok: false, status: 404, json: async () => ({}) });
    await h.flush();
    assert.strictEqual(h.get('promote-modal').style.display, 'none');
    assert.strictEqual(h.calls.toasts.length, 1);
    assert.strictEqual(h.calls.populate, 0);
});

test('closing the modal while loading discards the late response (stale token) and allows a fresh open', async () => {
    const h = modalHarness();
    h.sb.promoteRelease('REL-1');
    h.sb.hidePromoteModal();
    h.gates[0].res(h.okJson({ id: 'REL-1' }));
    await h.flush();
    assert.strictEqual(h.fetched.length, 1, 'no dry run for an abandoned preview');
    assert.strictEqual(h.calls.populate, 0);
    assert.strictEqual(h.get('promote-modal').style.display, 'none');
    h.sb.promoteRelease('REL-2');
    assert.strictEqual(h.fetched.length, 2, 'a fresh open after close starts its own preview');
});

test('promoteBeginPreview: pure guard returns null while loading, a fresh token otherwise', () => {
    const a = api.promoteBeginPreview({ loading: false }, 'R');
    assert.ok(a && a.loading === true && a.releaseId === 'R');
    assert.strictEqual(api.promoteBeginPreview(a, 'R'), null);
    const b = api.promoteBeginPreview({ loading: false }, 'R');
    assert.ok(b.token > a.token);
});

test('PROMOTE step refuses to advance while loading', () => {
    assert.ok(/if \(promoteModalState\.inFlight \|\| promoteModalState\.loading\) return;/.test(STEP_NEXT));
});

// A LOWER bound, not an exact pin: an exact `?v=3.91` match broke this suite on
// the very next lcars.js bump (XACA-1376 -> 3.93). What this test protects is
// that the 3.91 fix is not served under an OLDER cache-buster.
function lcarsJsVersionAtLeast(html, min) {
    const m = /js\/lcars\.js\?v=([0-9]+(?:\.[0-9]+)*)"/.exec(html);
    if (!m) return false;
    const a = m[1].split('.').map(Number);
    const b = min.split('.').map(Number);
    for (let i = 0; i < Math.max(a.length, b.length); i++) {
        const x = a[i] || 0, y = b[i] || 0;
        if (x !== y) return x > y;
    }
    return true;
}

[
    ['equal',            '<script src="js/lcars.js?v=3.91"></script>', true],
    ['higher minor',     '<script src="js/lcars.js?v=3.93"></script>', true],
    ['higher major',     '<script src="js/lcars.js?v=4.0"></script>',  true],
    ['lower is refused', '<script src="js/lcars.js?v=3.90"></script>', false],
    ['missing stamp',    '<script src="js/lcars.js"></script>',        false],
].forEach(([label, html, want]) => {
    test('lcars.js version lower bound: ' + label, () => {
        assert.strictEqual(lcarsJsVersionAtLeast(html, '3.91'), want);
    });
});

test('index.html carries the bumped lcars.js asset version', () => {
    const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
    assert.ok(lcarsJsVersionAtLeast(html, '3.91'));
});

process.on('beforeExit', () => {
    if (failures) { process.exitCode = 1; }
});
