#!/usr/bin/env node
//
//  test-xaca-1397-board-refresh-failure.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
// XACA-1397-003: a failed refresh keeps the last good board and shows a banner;
// the empty embedded fallback is used only when no board ever loaded.
// Extracts the real loadBoardData block from lcars.js and runs it against stubs.
// Run: node lcars-ui/tests/test-xaca-1397-board-refresh-failure.js

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const src = fs.readFileSync(path.join(__dirname, '..', 'js', 'lcars.js'), 'utf8');
const start = src.indexOf('// XACA-1397-003: a refresh that fails');
const end = src.indexOf('function loadEmbeddedData()', start);
assert(start > 0 && end > start, 'loadBoardData block not found in lcars.js');
const block = src.slice(start, end);

function makeEl() {
    return { children: [], hidden: false, className: '', textContent: '', attrs: {}, offsetHeight: 0,
        setAttribute(k, v) { this.attrs[k] = v; },
        appendChild(c) { this.children.push(c); return c; },
        querySelector(sel) { return this.children.find(c => '.' + c.className.split(' ')[0] === sel) || null; } };
}
function setup() {
    const body = makeEl();
    const rootVars = {};
    const documentElement = { style: { setProperty: (k, v) => { rootVars[k] = v; } } };
    const doc = { body, createElement: makeEl, documentElement,
        getElementById: id => body.children.find(c => c.id === id) || null };
    const calls = { embedded: 0, render: 0, errors: [] };
    const state = { responses: [], signals: [] };
    // Fake timers: nothing fires until the test calls fireTimers().
    const timers = { pending: [], cleared: [] };
    const fakeSetTimeout = (cb, ms) => { const t = { cb, ms }; timers.pending.push(t); return t; };
    const fakeClearTimeout = t => { timers.cleared.push(t); timers.pending = timers.pending.filter(x => x !== t); };
    const fireTimers = () => { const p = timers.pending; timers.pending = []; p.forEach(t => t.cb()); };
    // A response of 'HANG' never resolves on its own; it rejects only when aborted (like real fetch).
    const fetchStub = (url, opts) => {
        const sig = opts && opts.signal;
        state.signals.push(sig);
        const r = state.responses.shift();
        if (r === 'HANG') {
            return new Promise((_, reject) => {
                if (sig) sig.addEventListener('abort', () => {
                    const e = new Error('The operation was aborted'); e.name = 'AbortError'; reject(e);
                });
            });
        }
        if (r instanceof Error) return Promise.reject(r);
        return Promise.resolve(r);
    };
    const fn = new Function('document', 'fetch', 'CONFIG', 'console', 'apiUrl', 'checkAssetVersion',
        'clearPlanDocExistsCache', 'renderBoard', 'updateTimestamp', 'loadEmbeddedData', 'boardData',
        'setTimeout', 'clearTimeout', 'AbortController', 'ASSET_BANNER_ID',
        block + '\nreturn { loadBoardData, getBoard: () => boardData, setBoard: b => { boardData = b; },' +
        ' isInFlight: () => boardLoadInFlight, timeoutMs: () => BOARD_FETCH_TIMEOUT_MS,' +
        ' positionBoardStaleBanner, hideBoardStaleBanner, showBoardStaleBanner };');
    const api = fn(doc, fetchStub, { dataPath: 'x', team: 'academy' },
        { log() {}, error: (...a) => calls.errors.push(a) }, u => u, () => {}, () => {},
        () => { calls.render++; }, () => {}, () => { calls.embedded++; }, null,
        fakeSetTimeout, fakeClearTimeout, AbortController, 'lcars-asset-banner');
    return { api, doc, calls, state, timers, fireTimers, rootVars };
}
const ok = body => ({ ok: true, json: async () => body, headers: { get: () => null } });
const archived = ok({ releases: [] });
const bar = t => t.doc.getElementById('lcars-board-stale-banner');

let n = 0;
async function test(name, fn) { await fn(); n++; console.log('ok - ' + name); }

(async () => {
    await test('failure after a good load keeps boardData, shows accessible banner, no embedded fallback', async () => {
        const t = setup();
        t.state.responses.push(ok({ team: 'academy', backlog: [1, 2, 3] }), archived, new Error('boom'));
        assert.strictEqual(await t.api.loadBoardData(), true);
        const renders = t.calls.render;
        assert.strictEqual(await t.api.loadBoardData(), false);
        assert.strictEqual(t.api.getBoard().backlog.length, 3);
        assert.strictEqual(t.calls.embedded, 0);
        assert.strictEqual(t.calls.render, renders, 'must not re-render on failure');
        const b = bar(t);
        assert(b && !b.hidden);
        assert.strictEqual(b.attrs.role, 'status');
        assert.strictEqual(b.attrs['aria-live'], 'polite');
        assert(/Unable to refresh board .* showing last loaded data \(as of .+\)/.test(b.children[0].textContent));
        assert(/academy/.test(String(t.calls.errors[0][0])), 'console.error includes team');
        assert.strictEqual(t.calls.errors[0][1].message, 'boom');
    });
    await test('HTTP error and non-object JSON also keep the board; repeat failures do not stack banners', async () => {
        const t = setup();
        t.state.responses.push(ok({ team: 'academy', backlog: [1] }), archived,
            { ok: false, status: 504 }, ok(null), new Error('x'));
        await t.api.loadBoardData();
        await t.api.loadBoardData();
        await t.api.loadBoardData();
        await t.api.loadBoardData();
        assert.strictEqual(t.api.getBoard().backlog.length, 1);
        assert.strictEqual(t.doc.body.children.filter(c => c.id === 'lcars-board-stale-banner').length, 1);
        assert.strictEqual(t.calls.embedded, 0);
    });
    await test('next success clears the banner', async () => {
        const t = setup();
        t.state.responses.push(ok({ backlog: [1] }), archived, new Error('x'),
            ok({ backlog: [1, 2] }), archived);
        await t.api.loadBoardData();
        await t.api.loadBoardData();
        assert(!bar(t).hidden);
        assert.strictEqual(await t.api.loadBoardData(), true);
        assert(bar(t).hidden);
        assert.strictEqual(t.api.getBoard().backlog.length, 2);
    });
    await test('XACA-1397-019: first-ever load failing shows the first-load banner (not silent)', async () => {
        const t = setup();
        t.state.responses.push(new Error('down'));
        assert.strictEqual(await t.api.loadBoardData(), false);
        assert.strictEqual(t.calls.embedded, 1);
        const b = bar(t);
        assert(b && !b.hidden, 'banner must be visible');
        assert.strictEqual(b.attrs.role, 'status');
        assert.strictEqual(b.attrs['aria-live'], 'polite');
        assert.strictEqual(b.children[0].textContent, 'Unable to load board \u2014 retrying\u2026');
        assert(!/showing last loaded data/.test(b.children[0].textContent));
    });
    await test('XACA-1397-019: next success after a failed first load clears the banner and renders the real board', async () => {
        const t = setup();
        t.state.responses.push(new Error('down'), ok({ team: 'academy', backlog: [1, 2, 3] }), archived);
        await t.api.loadBoardData();
        assert(!bar(t).hidden);
        const renders = t.calls.render;
        assert.strictEqual(await t.api.loadBoardData(), true);
        assert(bar(t).hidden, 'banner cleared');
        assert.strictEqual(t.api.getBoard().backlog.length, 3);
        assert.strictEqual(t.calls.render, renders + 1);
        assert.strictEqual(t.calls.embedded, 1, 'fallback not used again');
        // A later failure now gets the refresh wording, not first-load wording.
        t.state.responses.push(new Error('again'));
        await t.api.loadBoardData();
        assert(/showing last loaded data/.test(bar(t).children[0].textContent));
    });
    await test('XACA-1397-019: repeated first-load failures keep ONE banner', async () => {
        const t = setup();
        t.state.responses.push(new Error('a'), { ok: false, status: 502 }, new Error('c'));
        await t.api.loadBoardData(); await t.api.loadBoardData(); await t.api.loadBoardData();
        assert.strictEqual(t.doc.body.children.filter(c => c.id === 'lcars-board-stale-banner').length, 1);
    });
    await test('XACA-1397-019: embedded placeholder is labelled, not a real-looking team', async () => {
        const s2 = src.indexOf('function loadEmbeddedData()');
        const e2 = src.indexOf('\n}\n', s2);
        const board = new Function('renderBoard', 'var boardData = null;\n' + src.slice(s2, e2 + 3) +
            '\nloadEmbeddedData(); return boardData;')(() => {});
        assert.strictEqual(board.boardUnavailable, true);
        assert.strictEqual(board.ship, 'BOARD UNAVAILABLE');
        assert.strictEqual(board.lastUpdated, undefined, 'no fake last-updated');
        assert.deepStrictEqual(board.backlog, []);
    });
    await test('hung fetch is aborted by the timeout, keeps last-good board, shows banner, frees in-flight', async () => {
        const t = setup();
        t.state.responses.push(ok({ team: 'academy', backlog: [1, 2] }), archived, 'HANG');
        assert.strictEqual(await t.api.loadBoardData(), true);
        const p = t.api.loadBoardData();               // never resolves by itself
        assert.strictEqual(t.api.isInFlight(), true);
        assert.strictEqual(t.timers.pending.length, 1);
        assert.strictEqual(t.timers.pending[0].ms, 25000);
        assert.strictEqual(t.api.timeoutMs(), 25000);
        t.fireTimers();                                // 25 s elapse
        assert.strictEqual(await p, false);
        assert.strictEqual(t.api.isInFlight(), false, 'in-flight flag must clear so auto-refresh resumes');
        assert.strictEqual(t.api.getBoard().backlog.length, 2);
        assert.strictEqual(t.calls.embedded, 0);
        const b = bar(t);
        assert(b && !b.hidden, 'banner shown on timeout');
        assert.strictEqual(t.calls.errors[0][1].name, 'AbortError');
        assert.strictEqual(t.state.signals[2] && t.state.signals[2].aborted, true);
    });
    await test('timer is cleared on success and on failure (no leaked timer)', async () => {
        const t = setup();
        t.state.responses.push(ok({ backlog: [1] }), archived, new Error('x'));
        await t.api.loadBoardData();
        assert.strictEqual(t.timers.pending.length, 0);
        await t.api.loadBoardData();
        assert.strictEqual(t.timers.pending.length, 0);
        assert.strictEqual(t.timers.cleared.length, 2);
    });
    await test('first-ever hung load times out into the placeholder AND the first-load banner (XACA-1397-019)', async () => {
        const t = setup();
        t.state.responses.push('HANG');
        const p = t.api.loadBoardData();
        t.fireTimers();
        assert.strictEqual(await p, false);
        assert.strictEqual(t.calls.embedded, 1);
        assert(bar(t) && !bar(t).hidden);
        assert.strictEqual(bar(t).children[0].textContent, 'Unable to load board \u2014 retrying\u2026');
        assert.strictEqual(t.calls.errors[0][1].name, 'AbortError');
        assert.strictEqual(t.api.isInFlight(), false);
    });
    await test('overlapping loads: in-flight stays true until the LAST one settles (counter, not boolean)', async () => {
        const t = setup();
        t.state.responses.push('HANG', ok({ backlog: [1] }), archived);
        const slow = t.api.loadBoardData();            // hangs
        assert.strictEqual(t.api.isInFlight(), true);
        assert.strictEqual(await t.api.loadBoardData(), true);   // overlapping load finishes first
        assert.strictEqual(t.api.isInFlight(), true, 'the hung load is still running');
        t.fireTimers();                                // abort the hung one
        await slow;
        assert.strictEqual(t.api.isInFlight(), false);
    });
    await test('stale-board bar stacks under the MEASURED asset bar; no gap when absent; follows wrap/hide', async () => {
        const t = setup();
        const pos = () => t.api.positionBoardStaleBanner();
        pos();
        assert.strictEqual(t.rootVars['--lcars-board-stale-top'], '8px', 'no asset bar: no gap');
        assert.strictEqual(t.rootVars['--lcars-board-stale-h'], '0px', 'no stale bar: no reserve');
        const asset = makeEl(); asset.id = 'lcars-asset-banner'; asset.offsetHeight = 52;
        t.doc.body.appendChild(asset);
        pos();
        assert.strictEqual(t.rootVars['--lcars-board-stale-top'], '68px', '8 + 52 + 8');
        asset.offsetHeight = 104;                      // <=600px: the bar wraps to two rows
        pos();
        assert.strictEqual(t.rootVars['--lcars-board-stale-top'], '120px', 'wrapped asset bar is cleared, not overlapped');
        asset.hidden = true;                           // dismissed
        pos();
        assert.strictEqual(t.rootVars['--lcars-board-stale-top'], '8px', 'hidden asset bar leaves no gap');
    });
    await test('showing/hiding the stale-board bar publishes/clears its modal-reserve height', async () => {
        const t = setup();
        t.api.showBoardStaleBanner('10:00:00');
        const b = bar(t);
        b.offsetHeight = 36;
        t.api.positionBoardStaleBanner();
        assert.strictEqual(t.rootVars['--lcars-board-stale-h'], '44px', 'height + 8px gap');
        t.api.hideBoardStaleBanner();
        assert.strictEqual(t.rootVars['--lcars-board-stale-h'], '0px');
    });
    await test('CSS: offset comes from the measured var (no fixed 56px), reserve includes the stale bar', async () => {
        const css = fs.readFileSync(path.join(__dirname, '..', 'css', 'lcars.css'), 'utf8');
        const m = css.match(/\.lcars-asset-banner\.lcars-board-stale-banner \{([^}]*)\}/);
        assert(m, 'stale-banner rule present');
        assert(/top:\s*var\(--lcars-board-stale-top,\s*8px\)/.test(m[1]));
        assert(!/top:\s*56px/.test(m[1]));
        assert(/padding-top: calc\(var\(--lcars-asset-banner-h, 56px\) \+ var\(--lcars-board-stale-h, 0px\) \+ 16px\)/.test(css));
        assert(/max-height: min\(90vh, calc\(100vh - var\(--lcars-asset-banner-h, 56px\) - var\(--lcars-board-stale-h, 0px\) - 32px\)\)/.test(css));
        const js = fs.readFileSync(path.join(__dirname, '..', 'js', 'lcars.js'), 'utf8');
        for (const fnName of ['showAssetBanner', 'hideAssetBanner', 'refreshAssetBannerMode']) {
            const i = js.indexOf('function ' + fnName + '(');
            const body = js.slice(i, js.indexOf('\n}\n', i));
            assert(/positionBoardStaleBanner\(\)/.test(body), fnName + ' must re-stack the stale-board bar');
        }
    });
    console.log('PASS ' + n + ' tests');
})().catch(e => { console.error(e); process.exit(1); });
