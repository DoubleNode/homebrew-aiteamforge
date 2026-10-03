#!/usr/bin/env node
//
//  test-xaca-1397-reconcile-status.js
//  XACA-1397-004: Workflow tab handling of reconciledInProgress freshness.
//  Extracts the real updateReconcileStatusNote from lcars.js and runs it on stubs.
// Run: node lcars-ui/tests/test-xaca-1397-reconcile-status.js

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const src = fs.readFileSync(path.join(__dirname, '..', 'js', 'lcars.js'), 'utf8');
const start = src.indexOf('function updateReconcileStatusNote(');
const end = src.indexOf('/**\n * Update column visibility', start);
assert(start > 0 && end > start, 'updateReconcileStatusNote not found in lcars.js');
const block = src.slice(start, end);

function makeEl() {
    return { children: [], className: '', textContent: '', attrs: {},
        setAttribute(k, v) { this.attrs[k] = v; },
        appendChild(c) { c.parentNode = this; this.children.push(c); return c; },
        removeChild(c) { this.children = this.children.filter(x => x !== c); c.parentNode = null; return c; },
        querySelector(sel) { return this.children.find(c => '.' + c.className === sel) || null; } };
}
const doc = { createElement: makeEl };
const fns = new Function('document', block + '\nreturn { updateReconcileStatusNote, reconcileLaneForcedVisible };')(doc);
const fn = fns.updateReconcileStatusNote;

// XACA-1397-011: the REAL updateKanbanColumnVisibility on stub columns.
const vstart = src.indexOf('function updateKanbanColumnVisibility(');
const vend = src.indexOf('/**\n * Update the hidden columns indicator badge', vstart);
assert(vstart > 0 && vend > vstart, 'updateKanbanColumnVisibility not found in lcars.js');
const vblock = src.slice(vstart, vend);
const COLS = ['needs_reconnect', 'paused', 'ready', 'planning', 'coding', 'testing', 'commit', 'pr_review'];
const PRIO = { needs_reconnect: 'important', ready: 'critical', coding: 'critical', paused: 'important' };
function visibility(counts, forced, showAll) {
    const els = {};
    COLS.forEach(c => {
        const set = new Set();
        els[c] = { classList: { toggle(k, on) { if (on) set.add(k); else set.delete(k); }, has: k => set.has(k) } };
    });
    const board = { attrs: {}, classList: { toggle() {} }, setAttribute(k, v) { this.attrs[k] = v; } };
    const d = { querySelector: sel => {
        if (sel === '.kanban-board') return board;
        const m = sel.match(/data-status="(\w+)"/);
        return m ? els[m[1]] : null;
    } };
    let hidden = null;
    const f = new Function('document', 'KANBAN_COLUMNS', 'COLUMN_PRIORITY', 'showAllKanbanColumns',
        'updateHiddenColumnsIndicator', vblock + '\nreturn updateKanbanColumnVisibility;')(
        d, COLS, PRIO, !!showAll, n => { hidden = n; });
    f(counts, forced);
    return { els, board, hidden };
}
// Live text = the .reconcile-status-text child (what a screen reader announces);
// the age lives in the aria-hidden .reconcile-status-age sibling.
const liveText = note => note.querySelector('.reconcile-status-text').textContent;
const ageText = note => note.querySelector('.reconcile-status-age').textContent;
const run = data => { const col = makeEl(); const state = fn(col, data); return { col, state }; };

let n = 0;
function test(name, f) { f(); n++; console.log('ok - ' + name); }

test('absent fields (older server): no note, state absent', () => {
    const r = run({ backlog: [] });
    assert.strictEqual(r.state, 'absent');
    assert.strictEqual(r.col.children.length, 0);
});
test('fresh: no note', () => {
    const r = run({ reconciledInProgress: [], reconciledInProgressAgeMs: 500, reconciledInProgressStale: false });
    assert.strictEqual(r.state, 'fresh');
    assert.strictEqual(r.col.children.length, 0);
});
test('cold + stale + empty: "Reconciling" note, accessible', () => {
    const r = run({ reconciledInProgress: [], reconciledInProgressAgeMs: null, reconciledInProgressStale: true });
    assert.strictEqual(r.state, 'cold');
    const note = r.col.children[0];
    assert(/Reconciling/.test(liveText(note)));
    assert.strictEqual(note.attrs.role, 'status');
    assert.strictEqual(note.attrs['aria-live'], 'polite');
});
test('cold + failures >= 3: "Reconcile unavailable" instead of "Reconciling", still accessible', () => {
    const r = run({ reconciledInProgress: [], reconciledInProgressAgeMs: null, reconciledInProgressStale: true,
        reconciledInProgressError: 'helper-failed', reconciledInProgressFailures: 3 });
    assert.strictEqual(r.state, 'unavailable');
    const note = r.col.children[0];
    assert(/Reconcile unavailable .* may be incomplete/.test(liveText(note)));
    assert(!/Reconciling/.test(liveText(note)));
    assert.strictEqual(note.attrs.role, 'status');
    assert.strictEqual(note.attrs['aria-live'], 'polite');
});
test('cold + 1-2 failures: still "Reconciling" (transient)', () => {
    for (const f of [0, 1, 2]) {
        const r = run({ reconciledInProgress: [], reconciledInProgressAgeMs: null, reconciledInProgressStale: true,
            reconciledInProgressError: f ? 'timeout' : null, reconciledInProgressFailures: f });
        assert.strictEqual(r.state, 'cold', 'failures=' + f);
        assert(/Reconciling/.test(liveText(r.col.children[0])));
    }
});
test('cold + error present but no failure count (partial server): unavailable', () => {
    const r = run({ reconciledInProgress: [], reconciledInProgressAgeMs: null, reconciledInProgressStale: true,
        reconciledInProgressError: 'timeout' });
    assert.strictEqual(r.state, 'unavailable');
});
test('older server (no new fields) cold: unchanged "Reconciling"', () => {
    const r = run({ reconciledInProgress: [], reconciledInProgressAgeMs: null, reconciledInProgressStale: true });
    assert.strictEqual(r.state, 'cold');
});
test('stale with data keeps age note even with failures', () => {
    const r = run({ reconciledInProgress: [{ id: 'X' }], reconciledInProgressAgeMs: 5000, reconciledInProgressStale: true,
        reconciledInProgressError: 'helper-failed', reconciledInProgressFailures: 9 });
    assert.strictEqual(r.state, 'stale');
});
test('stale with data: age note', () => {
    const r = run({ reconciledInProgress: [{ id: 'X' }], reconciledInProgressAgeMs: 42000, reconciledInProgressStale: true });
    assert.strictEqual(r.state, 'stale');
    assert(/42s old/.test(ageText(r.col.children[0])));
    assert(!/old/.test(liveText(r.col.children[0])), 'age must NOT be in the live text');
    assert.strictEqual(r.col.children[0].querySelector('.reconcile-status-age').attrs['aria-hidden'], 'true');
});
test('re-render replaces the note, never stacks', () => {
    const col = makeEl();
    const d = { reconciledInProgress: [], reconciledInProgressAgeMs: null, reconciledInProgressStale: true };
    fn(col, d); fn(col, d);
    assert.strictEqual(col.children.length, 1);
    fn(col, { reconciledInProgress: [], reconciledInProgressAgeMs: 1, reconciledInProgressStale: false });
    assert.strictEqual(col.children.length, 0);
});
test('malformed list does not throw', () => {
    const r = run({ reconciledInProgress: 'x', reconciledInProgressStale: true, reconciledInProgressAgeMs: null });
    assert.strictEqual(r.state, 'cold');
});

test('cold/unavailable force the NEEDS RECONNECT lane visible; every other state does not', () => {
    assert.deepStrictEqual(fns.reconcileLaneForcedVisible('cold'), ['needs_reconnect']);
    assert.deepStrictEqual(fns.reconcileLaneForcedVisible('unavailable'), ['needs_reconnect']);
    for (const st of ['fresh', 'stale', 'absent', undefined, null, 'bogus']) {
        assert.deepStrictEqual(fns.reconcileLaneForcedVisible(st), [], String(st));
    }
});
test('lane visibility: fresh + empty stays hidden (default behaviour unchanged)', () => {
    const r = visibility({ needs_reconnect: 0 }, fns.reconcileLaneForcedVisible('fresh'));
    assert(r.els.needs_reconnect.classList.has('hidden-empty'));
    assert(r.els.needs_reconnect.classList.has('empty'));
    const old = visibility({ needs_reconnect: 0 });   // no 2nd arg: older call shape
    assert(old.els.needs_reconnect.classList.has('hidden-empty'));
});
test('lane visibility: cold + empty shows the lane and is NOT marked empty (narrow-viewport CSS hides .empty)', () => {
    for (const st of ['cold', 'unavailable']) {
        const r = visibility({ needs_reconnect: 0 }, fns.reconcileLaneForcedVisible(st));
        const c = r.els.needs_reconnect.classList;
        assert(!c.has('hidden-empty'), st + ' must not be hidden');
        assert(!c.has('empty'), st + ' must not carry .empty');
        assert(c.has('priority-important'));
    }
});
test('lane visibility: forcing the lane never un-hides OTHER empty columns and counts it as visible', () => {
    const base = visibility({ needs_reconnect: 0 }, []);
    const forced = visibility({ needs_reconnect: 0 }, ['needs_reconnect']);
    assert.strictEqual(Number(forced.board.attrs['data-visible-columns']),
        Number(base.board.attrs['data-visible-columns']) + 1);
    assert.strictEqual(forced.hidden, base.hidden - 1);
    assert(forced.els.paused.classList.has('hidden-empty'));
});
test('lane visibility: a lane with cards is visible regardless of the forced list', () => {
    const r = visibility({ needs_reconnect: 2 }, []);
    assert(!r.els.needs_reconnect.classList.has('hidden-empty'));
    assert(!r.els.needs_reconnect.classList.has('empty'));
});
test('renderKanban wires the note state into the visibility call (source guard)', () => {
    assert(/reconcileState = updateReconcileStatusNote\(reconnectCol, boardData\)/.test(src));
    assert(/updateKanbanColumnVisibility\(columnCardCounts, reconcileLaneForcedVisible\(reconcileState\)\)/.test(src));
});

// XACA-1397-020: persistent note, live text only changes with the semantic state.
const dat = (over) => Object.assign({ reconciledInProgress: [{ id: 'X' }], reconciledInProgressAgeMs: 1000,
    reconciledInProgressStale: true }, over);
test('XACA-1397-020: repeated stale renders keep the SAME node and the SAME live text while age ticks', () => {
    const col = makeEl();
    fn(col, dat({ reconciledInProgressAgeMs: 1000 }));
    const note = col.children[0];
    const textEl = note.querySelector('.reconcile-status-text');
    let writes = 0, val = textEl.textContent;
    Object.defineProperty(textEl, 'textContent', { get: () => val, set: v => { writes++; val = v; } });
    for (const ms of [2000, 3000, 45000, 61000]) {
        fn(col, dat({ reconciledInProgressAgeMs: ms }));
        assert.strictEqual(col.children.length, 1);
        assert.strictEqual(col.children[0], note, 'node must not be replaced');
        assert.strictEqual(col.children[0].querySelector('.reconcile-status-text'), textEl);
    }
    assert.strictEqual(writes, 0, 'live text must not be rewritten on an age tick');
    assert.strictEqual(liveText(note), 'Reconcile data may be out of date');
    assert(/61s old/.test(ageText(note)), 'age still refreshed (outside the live text)');
});
test('XACA-1397-020: repeated cold renders do not replace the node', () => {
    const col = makeEl();
    const d = { reconciledInProgress: [], reconciledInProgressAgeMs: null, reconciledInProgressStale: true };
    fn(col, d);
    const note = col.children[0];
    fn(col, d); fn(col, d);
    assert.strictEqual(col.children[0], note);
    assert.strictEqual(col.children.length, 1);
});
test('XACA-1397-020: a state change updates the SAME node text; fresh removes it; stale again recreates', () => {
    const col = makeEl();
    fn(col, { reconciledInProgress: [], reconciledInProgressAgeMs: null, reconciledInProgressStale: true });
    const note = col.children[0];
    assert(/Reconciling/.test(liveText(note)));
    fn(col, dat({}));
    assert.strictEqual(col.children[0], note);
    assert.strictEqual(liveText(note), 'Reconcile data may be out of date');
    fn(col, { reconciledInProgress: [], reconciledInProgressAgeMs: null, reconciledInProgressStale: true,
        reconciledInProgressError: 'helper-failed', reconciledInProgressFailures: 3 });
    assert.strictEqual(col.children[0], note);
    assert(/unavailable/.test(liveText(note)));
    assert.strictEqual(ageText(note), '', 'age cleared when not stale');
    fn(col, dat({ reconciledInProgressStale: false }));
    assert.strictEqual(col.children.length, 0, 'fresh removes the note');
    fn(col, dat({}));
    assert.strictEqual(col.children.length, 1);
});
test('XACA-1397-020: board re-render keeps the note (clear helper skips it; cards go before it)', () => {
    const cstart = src.indexOf('function clearKanbanColumnKeepingNote(');
    const cend = src.indexOf('function renderKanbanColumns()', cstart);
    assert(cstart > 0 && cend > cstart, 'clear helper not found');
    const clear = new Function(src.slice(cstart, cend) + '\nreturn clearKanbanColumnKeepingNote;')();
    const mk = cls => ({ classList: { contains: k => k === cls }, parentNode: null });
    const col = { childNodes: [], removeChild(c) { this.childNodes = this.childNodes.filter(x => x !== c); c.parentNode = null; } };
    const card = mk('kanban-card'), noteEl = mk('reconcile-status-note');
    [card, noteEl].forEach(c => { c.parentNode = col; col.childNodes.push(c); });
    clear(col);
    assert.deepStrictEqual(col.childNodes, [noteEl]);
    assert(/clearKanbanColumnKeepingNote\(container\)/.test(src), 'renderKanbanColumns must use it');
    assert(/reconnectCol\.insertBefore\(card, reconnectCol\.querySelector\('\.reconcile-status-note'\)\)/.test(src));
});
console.log(n + ' passed');
