#!/usr/bin/env node
//
//  test-xaca-1549-orchestration-panel.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 DoubleNode.com. All rights reserved.
//

/**
 * XACA-1549-002/-003/-010: the read-only orchestration panel on the LCARS Releases tab.
 *
 * The token column is pinned to the REAL XACA-1808 writer contract: this test LOADS
 * tests/fixtures/xaca-1808/orchestration-tokens.contract.json (minus its `_comment`) and renders it, so a contract
 * change breaks here instead of silently rendering "tokens unavailable".
 *
 * Loads the real code from lcars.js (the block between the ORCH-PANEL-BEGIN / ORCH-PANEL-END markers, plus
 * escapeAttr, brace-matched and unmodified) and runs it on stubs.
 *
 * Run: node lcars-ui/tests/test-xaca-1549-orchestration-panel.js
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(ROOT, 'js', 'lcars.js'), 'utf8');
const css = fs.readFileSync(path.join(ROOT, 'css', 'lcars.css'), 'utf8');
const TOKENS = JSON.parse(fs.readFileSync(path.join(ROOT, '..', 'tests', 'fixtures', 'xaca-1808', 'orchestration-tokens.contract.json'), 'utf8'));
delete TOKENS._comment;

let failures = 0;
const pending = [];
function check(name, actual, expected) {
    const a = JSON.stringify(actual);
    const e = JSON.stringify(expected);
    if (a === e) {
        console.log('ok - ' + name);
    } else {
        failures++;
        console.error('FAIL: ' + name + '\n  expected ' + e + '\n  actual   ' + a);
    }
}
function truthy(name, cond) { check(name, !!cond, true); }

function extractFunction(name) {
    const start = source.indexOf('\nfunction ' + name + '(');
    if (start === -1) throw new Error('function not found: ' + name);
    const bodyStart = source.indexOf('{', source.indexOf(')', start));
    let depth = 0;
    for (let i = bodyStart; i < source.length; i++) {
        const ch = source[i];
        if (ch === '{') depth++;
        else if (ch === '}') {
            depth--;
            if (depth === 0) return source.slice(start + 1, i + 1);
        }
    }
    throw new Error('unbalanced braces in ' + name);
}

const begin = source.indexOf('// ORCH-PANEL-BEGIN');
const end = source.indexOf('// ORCH-PANEL-END');
if (begin === -1 || end === -1 || end < begin) throw new Error('ORCH-PANEL markers not found in lcars.js');
const orchBlock = source.slice(begin, end);

// Mutable fetch stub so each case can pick its behaviour.
let fetchImpl = async () => { throw new Error('fetch not stubbed'); };
const sandbox = {
    CONFIG: { team: 'academy' },
    boardData: null,
    apiUrl: (p) => p + '?team=academy',
    getDeveloperAvatarUrl: (team, terminal) => (team && terminal) ? 'images/' + team + '_' + terminal + '_avatar.png' : '',
    fetch: (u) => fetchImpl(u),
    document: { querySelectorAll: () => [], querySelector: () => null }
};
vm.createContext(sandbox);
// escapeHtml is DOM-backed in lcars.js; the stub escapes &, <, > like textContent->innerHTML does.
vm.runInContext(
    'function escapeHtml(t) { return String(t == null ? "" : t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }\n' +
    extractFunction('escapeAttr') + '\n' + orchBlock, sandbox);

const panel = sandbox.orchPanelInnerHtml;
const NOW = '2026-11-15T12:00:00Z';

function ticket(over) {
    return Object.assign({ id: 'XACA-1', title: 'A title', terminal: 'alpha', avatar: 'alpha', persona: 'Reno',
        state: 'RUNNING', since: '2026-11-15T11:30:00Z', pendingQuestion: null }, over || {});
}
function run(tickets, over) {
    return Object.assign({ active: true, release: 'REL-1', run: 'RUN-1', startedAt: '2026-11-15T10:00:00Z', closedAt: null,
        coordinator: 'coord', maxParallel: 2, now: NOW, waves: [tickets], lanes: [], events: [], eventsTotal: 0,
        tokens: null, readError: null }, over || {});
}
function count(hay, needle) { return hay.split(needle).length - 1; }

// --- every state chip (text + class), UNKNOWN and a bogus value --------------------------------------------
const STATES = ['QUEUED', 'DISPATCHING', 'RUNNING', 'QUESTION_PENDING', 'IN_REVIEW', 'MERGED_PENDING_DONE', 'DONE',
    'FAILED', 'CRASHED', 'STALLED', 'CANCELLED', 'UNKNOWN'];
// Keep the chip table in lock-step with the Python source of truth.
const pySrc = fs.readFileSync(path.join(ROOT, '..', 'kanban-hooks', 'orchestrator_state.py'), 'utf8');
const pyStates = (pySrc.match(/STATES = \(([^)]*)\)/) || [, ''])[1].match(/"([A-Z_]+)"/g).map((s) => s.replace(/"/g, ''));
check('chip table covers exactly orchestrator_state.py STATES', pyStates.slice().sort(), STATES.slice().sort());
for (const st of STATES) {
    const h = panel(run([ticket({ state: st })]));
    const label = st.replace(/_/g, ' ').replace('MERGED PENDING DONE', 'MERGED, PENDING DONE');
    truthy('state ' + st + ' renders a chip with its text label', h.indexOf('>' + label + '</span>') !== -1 && h.indexOf('orch-chip') !== -1);
}
const bogus = panel(run([ticket({ state: 'EXPLODING' })]));
truthy('bogus state gets an unrecognised chip showing the raw value', bogus.indexOf('orch-chip-unrecognised') !== -1 && bogus.indexOf('UNRECOGNISED: EXPLODING') !== -1);
const bogusEvil = panel(run([ticket({ state: '<img src=x onerror=alert(1)>' })]));
truthy('bogus state value is escaped', bogusEvil.indexOf('<img src=x') === -1);
truthy('missing state renders UNKNOWN, not unrecognised', panel(run([ticket({ state: undefined })])).indexOf('orch-chip-unknown') !== -1);

// --- time in state ----------------------------------------------------------------------------------------
truthy('time in state is since vs server now (30m)', panel(run([ticket()])).indexOf('30m in state') !== -1);

// --- question age thresholds ------------------------------------------------------------------------------
function qHtml(sec) {
    return panel(run([ticket({ state: 'QUESTION_PENDING', pendingQuestion: { threadId: 't', question: 'Which?', askedAt: '2026-11-15T11:00:00Z', ageSeconds: sec } })]));
}
const q9 = qHtml(9 * 60), q11 = qHtml(11 * 60), q31 = qHtml(31 * 60);
truthy('question 9m is neutral', q9.indexOf('orch-question-ok') !== -1 && q9.indexOf('9m') !== -1);
truthy('question 11m is amber with a WAITING text label', q11.indexOf('orch-question-amber') !== -1 && q11.indexOf('QUESTION WAITING') !== -1);
truthy('question 31m is red with an OVERDUE text label', q31.indexOf('orch-question-red') !== -1 && q31.indexOf('QUESTION OVERDUE') !== -1);
check('question severity boundaries 600/601/1800/1801', [600, 601, 1800, 1801].map(sandbox.orchQuestionSeverity), ['ok', 'amber', 'amber', 'red']);
truthy('question age falls back to askedAt vs now when ageSeconds is absent',
    panel(run([ticket({ pendingQuestion: { question: 'q', askedAt: '2026-11-15T11:45:00Z' } })])).indexOf('orch-question-amber') !== -1);

// --- stalled / crashed / failed ---------------------------------------------------------------------------
for (const st of ['STALLED', 'CRASHED', 'FAILED']) {
    const h = panel(run([ticket({ state: st })]));
    truthy(st + ' has its text chip and the alert card style', h.indexOf('orch-chip-' + st.toLowerCase()) !== -1 && h.indexOf('orch-card-alert') !== -1);
    truthy(st + ' label appears once (no duplicate badge beside the chip)', count(h, '>' + st + '<') === 1);
}
truthy('RUNNING has no flag badge or alert style', panel(run([ticket()])).indexOf('orch-card-alert') === -1);

// --- active:false means "no run" OR "run closed": discriminate on `run` (PR #1344 test gate) ---------------
const CLOSED = '2026-11-15T11:00:00Z';
const closedWaves = [[ticket({ id: 'X-1', state: 'DONE' }), ticket({ id: 'X-2', state: 'FAILED' })]];
const closedCases = [
    // [name, payload, expectations]
    ['closed run, no readError, with waves',
        run([], { active: false, closedAt: CLOSED, waves: closedWaves, events: [{ ts: 't', run: 'RUN-1', kind: 'run_end', outcome: 'complete' }], eventsTotal: 1 }),
        { empty: false, error: false, cards: 2, closed: true, feed: true }],
    ['closed run, readError, with waves',
        run([], { active: false, closedAt: CLOSED, waves: closedWaves, readError: 'ledger corrupt' }),
        { empty: false, error: true, cards: 2, closed: true }],
    ['closed run, readError, zero waves: keeps the meta row',
        run([], { active: false, closedAt: CLOSED, waves: [], readError: 'ledger corrupt' }),
        { empty: false, error: true, cards: 0, closed: true, runId: true }],
    ['closed run, no readError, zero waves',
        run([], { active: false, closedAt: CLOSED, waves: [] }),
        { empty: false, error: false, cards: 0, closed: true, runId: true }],
    ['no run at all (server no-run payload)', { active: false, release: 'REL-1' },
        { empty: true, error: false, cards: 0 }],
    ['no run, readError only', { active: false, release: 'REL-1', readError: 'summary malformed' },
        { empty: false, error: true, cards: 0 }],
    ['active:true with no run id is malformed, not empty', { active: true, release: 'REL-1', waves: [] },
        { empty: false, error: true, cards: 0 }],
    ['empty-string run id is no run', { active: false, release: 'REL-1', run: '' },
        { empty: true, error: false, cards: 0 }],
];
for (const [name, payload, exp] of closedCases) {
    const h = panel(payload);
    truthy(name + ': empty state ' + (exp.empty ? 'shown' : 'NOT shown'), (h.indexOf('No orchestration run') !== -1) === exp.empty);
    truthy(name + ': error panel ' + (exp.error ? 'shown' : 'NOT shown'), (h.indexOf('orch-error') !== -1) === exp.error);
    check(name + ': ticket cards', count(h, 'class="orch-card '), exp.cards);
    if (exp.closed) truthy(name + ': meta row says CLOSED <ts>', h.indexOf('CLOSED ' + CLOSED) !== -1);
    if (exp.runId) truthy(name + ': meta row keeps the run id', h.indexOf('RUN RUN-1') !== -1);
    if (exp.feed) truthy(name + ': event feed kept', h.indexOf('EVENT FEED (1)') !== -1);
}
truthy('maxParallel 0 renders as 0, not blank', panel(run([ticket()], { maxParallel: 0 })).indexOf('MAX PARALLEL 0<') !== -1);

// --- empty state, error states: all distinct --------------------------------------------------------------
const emptyHtml = panel({ active: false, release: 'REL-1' });
truthy('empty state text names the release', emptyHtml.indexOf('No orchestration run, start with <code>kb-run REL-1</code>') !== -1);
truthy('empty state falls back to a placeholder without a release id', panel({ active: false }).indexOf('<code>kb-run &lt;REL-ID&gt;</code>') !== -1);
truthy('empty state escapes the release id', panel({ active: false, release: '<b>x' }).indexOf('<b>x') === -1);
truthy('empty state is not an error', emptyHtml.indexOf('orch-error') === -1);

const readErr = panel(run([ticket()], { readError: 'ledger corrupt: line 7' }));
truthy('readError shows the error panel with the reason', readErr.indexOf('orch-error') !== -1 && readErr.indexOf('ledger corrupt: line 7') !== -1);
truthy('readError with partial waves also shows what was sent', readErr.indexOf('orch-card') !== -1 && readErr.indexOf('XACA-1') !== -1);
truthy('readError never renders the empty state', readErr.indexOf('No orchestration run') === -1);
const readErrNoRun = panel({ active: false, release: 'REL-1', readError: 'summary unreadable' });
truthy('readError on an inactive payload is an error, NOT the empty state', readErrNoRun.indexOf('orch-error') !== -1 && readErrNoRun.indexOf('No orchestration run') === -1);

function loadFor(impl) { fetchImpl = impl; return sandbox.orchLoadInnerHtml('REL-1'); }
pending.push((async () => {
    const failFetch = await loadFor(async () => { throw new Error('connection refused'); });
    const non200 = await loadFor(async () => ({ ok: false, status: 500, json: async () => ({}) }));
    const badJson = await loadFor(async () => ({ ok: true, status: 200, json: async () => { throw new SyntaxError('bad'); } }));
    const good = await loadFor(async () => ({ ok: true, status: 200, json: async () => ({ active: false, release: 'REL-1' }) }));
    const calls = [];
    await loadFor(async (u) => { calls.push(u); return { ok: true, json: async () => ({ active: false }) }; });
    truthy('fetch targets the orchestration endpoint', calls[0].indexOf('/api/releases/REL-1/orchestration') === 0);
    truthy('fetch failure is an error panel with the reason', failFetch.indexOf('orch-error') !== -1 && failFetch.indexOf('connection refused') !== -1);
    truthy('non-200 is an error panel naming the status', non200.indexOf('orch-error') !== -1 && non200.indexOf('HTTP 500') !== -1);
    truthy('bad JSON is an error panel', badJson.indexOf('orch-error') !== -1 && badJson.indexOf('not valid JSON') !== -1);
    truthy('fetch failure is NOT the empty state', failFetch.indexOf('No orchestration run') === -1 && non200.indexOf('No orchestration run') === -1);
    truthy('error from fetch differs from the readError render and from empty', failFetch !== readErr && failFetch !== emptyHtml && failFetch !== good);
    truthy('a good empty response is the empty state', good === emptyHtml);
    truthy('a non-object body is an error, not empty', panel(null).indexOf('orch-error') !== -1 && panel([]).indexOf('orch-error') !== -1);
})());

// --- read-only: no action controls ------------------------------------------------------------------------
const full = panel(run([ticket({ state: 'QUESTION_PENDING', pendingQuestion: { question: 'q', ageSeconds: 5 } }), ticket({ id: 'XACA-2', state: 'STALLED' })],
    { events: [{ kind: 'dispatch', run: 'RUN-1', item: 'XACA-1', dispatch: { terminal: 'alpha' }, ts: '2026-11-15T10:01:00Z' }], eventsTotal: 1, tokens: TOKENS }));
truthy('no <button>, <input>, <select>, <form> or onclick in the panel', !/<(button|input|select|textarea|form)\b/i.test(full) && !/onclick/i.test(full));
truthy('shell has no action controls either', !/<(button|input|form)\b/i.test(sandbox.renderOrchestrationPanel('REL-1')));
truthy('event feed is a native <details>', full.indexOf('<details class="orch-events">') !== -1);
truthy('cards are NOT tab stops (they have no action; XACA-1549-016)', count(full, 'tabindex') === 0 && count(full, 'role="group"') === 0);
truthy('cards keep their aria-label', count(full, 'class="orch-card ') === 2 && count(full, 'aria-label="XACA-1 ') === 1);

// --- events newest first ----------------------------------------------------------------------------------
const evHtml = sandbox.orchEventsHtml([{ kind: 'run_start', ts: '1' }, { kind: 'question', ts: '2', item: 'X' }, { kind: 'done', ts: '3', item: 'X' }], 120);
truthy('events display newest first', evHtml.indexOf('>done<') < evHtml.indexOf('>question<') && evHtml.indexOf('>question<') < evHtml.indexOf('>run_start<'));
truthy('event feed header shows shown of total', evHtml.indexOf('EVENT FEED (3 of 120)') !== -1);

// --- escaping ---------------------------------------------------------------------------------------------
const evil = '"><script>alert(1)</script><img src=x onerror=alert(2)>';
const escHtml = panel(run([ticket({ title: evil, id: evil, terminal: evil, persona: evil, avatar: 'a"b', pendingQuestion: { question: evil, ageSeconds: 1 } })],
    { run: evil, coordinator: evil, readError: evil, events: [{ kind: evil, ts: evil, message: evil, item: evil }, { kind: 'state', from: evil, to: evil }, { kind: 'dispatch', item: 'I', dispatch: { terminal: evil, model: evil } }] }));
truthy('malicious strings never produce a live tag', escHtml.indexOf('<script') === -1 && escHtml.indexOf('<img src=x') === -1);
truthy('malicious strings cannot break out of an attribute', !/="[^"]*"><script/.test(escHtml) && escHtml.indexOf('&quot;') !== -1);

// --- token column (real XACA-1808 contract) -------------------------------------------------------------------
const B = (o) => Object.assign({ model: 'claude-fable-5-2', input: 0, cacheCreate: 0, cacheRead: 0, output: 0, turns: 0 }, o || {});
const tot = (b) => b.input + b.cacheCreate + b.cacheRead + b.output;
const clone = (o) => JSON.parse(JSON.stringify(o));
const compact = sandbox.orchCompactNumber;
const CONTRACT_ITEM = Object.getOwnPropertyNames(TOKENS.perItem)[0];                       // XACA-0000
const oneTicket = [ticket({ id: CONTRACT_ITEM })];
const withTok = panel(run(oneTicket, { tokens: TOKENS }));
check('contract fixture item is XACA-0000 (the one the mismatch targets)', CONTRACT_ITEM, 'XACA-0000');
truthy('contract renders (no "tokens unavailable")', withTok.indexOf('tokens unavailable') === -1 && withTok.indexOf('class="orch-tokens"') !== -1);
truthy('per-ticket total comes from the item block', withTok.indexOf('>' + compact(tot(TOKENS.perItem[CONTRACT_ITEM])) + '<') !== -1 &&
    withTok.indexOf('total ' + tot(TOKENS.perItem[CONTRACT_ITEM])) !== -1);
truthy('full numbers in the aria-label', withTok.indexOf('aria-label="Tokens: input ' + TOKENS.perItem[CONTRACT_ITEM].input) !== -1);
truthy('observed model is shown', withTok.indexOf(TOKENS.perItem[CONTRACT_ITEM].model) !== -1);
const runTotal = tot(TOKENS.run);
truthy('RUN TOTAL equals the contract run block total', withTok.indexOf('RUN TOTAL</span> <span class="orch-tokens-total">' + compact(runTotal) + '<') !== -1 &&
    withTok.indexOf('Run total ' + runTotal) !== -1);
// the run block is authoritative: a run block that differs from the perItem sum must win
const divergent = clone(TOKENS); divergent.run = B({ input: 7, cacheCreate: 0, cacheRead: 0, output: 0 });
const hDiv = panel(run(oneTicket, { tokens: divergent }));
truthy('run total is NOT summed from perItem (run block wins)', hDiv.indexOf('Run total 7,') !== -1);
truthy('COORDINATOR shown from its own block (zeros render as 0, not blank)', withTok.indexOf('COORDINATOR</span> <span class="orch-tokens-total">0<') !== -1);
const bigCoord = clone(TOKENS); bigCoord.coordinator = B({ input: 1, cacheCreate: 2, cacheRead: 2400000, output: 3, turns: 4 });
truthy('coordinator total from its block (2400006 -> 2.4M)', panel(run(oneTicket, { tokens: bigCoord })).indexOf('COORDINATOR</span> <span class="orch-tokens-total">2.4M<') !== -1);
const mm = TOKENS.modelMismatch[0];
truthy('modelMismatch badge on the ticket card (expected + observed)', withTok.indexOf(
    'MODEL MISMATCH (expected ' + mm.expected + ', observed ' + mm.observed.join(', ') + ')') !== -1);
const cardOnly = withTok.slice(withTok.indexOf('<li class="orch-card'), withTok.indexOf('</li>'));
truthy('the mismatch badge sits inside the XACA-0000 card', cardOnly.indexOf('MODEL MISMATCH') !== -1 && cardOnly.indexOf('data-ticket-id="XACA-0000"') !== -1);
truthy('summary shows the mismatch count', withTok.indexOf('1 model mismatch(es)') !== -1);
const otherCard = panel(run([ticket({ id: 'XACA-9' })], { tokens: TOKENS }));
truthy('a mismatch for another item is not put on this card', otherCard.indexOf('MODEL MISMATCH (') === -1 && otherCard.indexOf('class="orch-tokens"') === -1);
const evilMm = clone(TOKENS); evilMm.modelMismatch = [{ item: CONTRACT_ITEM, expected: '<b>x</b>', observed: ['"><img src=x onerror=1>'] }];
const hEvil = panel(run(oneTicket, { tokens: evilMm }));
truthy('mismatch badge text is escaped', hEvil.indexOf('<b>x') === -1 && hEvil.indexOf('<img src=x') === -1 && hEvil.indexOf('&lt;b&gt;x') !== -1);
truthy('complete:true shows no PARTIAL, unattributed:0 shows nothing', withTok.indexOf('PARTIAL') === -1 && withTok.indexOf('unattributed') === -1);
const partial = clone(TOKENS); partial.complete = false;
truthy('complete:false shows a PARTIAL text label', panel(run(oneTicket, { tokens: partial })).indexOf('>PARTIAL</span>') !== -1);
const unattr = clone(TOKENS); unattr.unattributed = 2;
truthy('unattributed:2 shows "2 unattributed session(s)"', panel(run(oneTicket, { tokens: unattr })).indexOf('2 unattributed session(s)') !== -1);
const unkModel = clone(TOKENS); unkModel.perItem[CONTRACT_ITEM].model = null; unkModel.run.model = null;
const hUnk = panel(run(oneTicket, { tokens: unkModel }));
truthy('model null shows "model unknown"', hUnk.indexOf('model unknown') !== -1 && hUnk.indexOf('>null<') === -1);
const joined = clone(TOKENS); joined.perItem[CONTRACT_ITEM].model = 'claude-a,claude-b';
truthy('comma-joined models show as-is', panel(run(oneTicket, { tokens: joined })).indexOf('claude-a,claude-b') !== -1);
const noMm = clone(TOKENS); delete noMm.modelMismatch;
truthy('absent modelMismatch is fine (no badge, no count)', panel(run(oneTicket, { tokens: noMm })).indexOf('MODEL MISMATCH') === -1);
const noTok = panel(run(oneTicket, { tokens: null }));
truthy('tokens null renders no token column and no zeros', noTok.indexOf('orch-tokens') === -1 && noTok.indexOf('TOKENS') === -1 && noTok.indexOf('tokens unavailable') === -1);
const absentTok = run(oneTicket); delete absentTok.tokens;
const hAbsent = panel(absentTok);
truthy('tokens absent renders nothing (no column, no summary, no badges)', hAbsent.indexOf('orch-tokens') === -1 && hAbsent.indexOf('RUN TOTAL') === -1 && hAbsent.indexOf('orch-badge') === -1);
const badBlock = (mut) => { const t = clone(TOKENS); mut(t); return t; };
const badCases = {
    'string': 'str', 'number': 5, 'array': [], 'empty object': {},
    'perItem is an array': badBlock(t => { t.perItem = []; }),
    'run missing': badBlock(t => { delete t.run; }),
    'run not a B block': badBlock(t => { t.run = 5; }),
    'run count is a string': badBlock(t => { t.run.input = 'x'; }),
    'coordinator missing': badBlock(t => { delete t.coordinator; }),
    'coordinator is a bare number': badBlock(t => { t.coordinator = 100; }),
    'perItem value negative': badBlock(t => { t.perItem[CONTRACT_ITEM].input = -1; }),
    'perItem model is a number': badBlock(t => { t.perItem[CONTRACT_ITEM].model = 7; }),
    'modelMismatch not a list': badBlock(t => { t.modelMismatch = 'bad'; })
};
for (const name of Object.getOwnPropertyNames(badCases)) {
    const h = panel(run(oneTicket, { tokens: badCases[name] }));
    truthy('malformed tokens (' + name + ') shows "tokens unavailable", no cells, no zeros', h.indexOf('tokens unavailable') !== -1 &&
        h.indexOf('class="orch-tokens"') === -1 && h.indexOf('RUN TOTAL') === -1);
}
truthy('ticket without a perItem entry shows no token cell', panel(run([ticket({ id: 'OTHER' })], { tokens: TOKENS })).indexOf('class="orch-tokens"') === -1);
check('compact number formats', [0, 999, 1000, 1234, 1500000, 2000000000].map(compact), ['0', '999', '1K', '1.2K', '1.5M', '2B']);
truthy('the provisional flags / expectedModel handling is gone', orchBlock.indexOf('expectedModel') === -1 && orchBlock.indexOf('orchFlagBadgeHtml') === -1 &&
    panel(run(oneTicket, { tokens: Object.assign(clone(TOKENS), { flags: ['TOKEN_BUDGET'] }) })).indexOf('TOKEN BUDGET') === -1);

// --- TOKEN_BUDGET comes from the server's top-level tokenBudget (latest token_budget ledger event per scope+item) ----
const budgetItem = { scope: 'item', item: CONTRACT_ITEM, used: 1200, limit: 1000, ts: 't1' };
const budgetRun = { scope: 'run', item: null, used: 9000, limit: 5000, ts: 't2' };
const hBud = panel(run(oneTicket, { tokens: TOKENS, tokenBudget: [budgetItem, budgetRun] }));
const budCard = hBud.slice(hBud.indexOf('<li class="orch-card'), hBud.indexOf('</li>'));
truthy('item budget badge on the ticket card', budCard.indexOf('TOKEN BUDGET (used 1200 &gt; limit 1000)') !== -1);
const sumOnly = hBud.slice(hBud.indexOf('orch-tokens-summary'));
truthy('run budget badge in the run summary, not on a card', sumOnly.indexOf('limit 5000') !== -1 && budCard.indexOf('limit 5000') === -1);
truthy('budget badge shows with tokens null (separate source)', panel(run(oneTicket, { tokens: null, tokenBudget: [budgetItem, budgetRun] })).indexOf('limit 5000') !== -1 &&
    panel(run(oneTicket, { tokens: null, tokenBudget: [budgetItem] })).indexOf('limit 1000') !== -1);
truthy('budget badge shows beside "tokens unavailable"', panel(run(oneTicket, { tokens: 'bad', tokenBudget: [budgetRun] })).indexOf('limit 5000') !== -1);
truthy('no tokenBudget -> no budget badge', panel(run(oneTicket, { tokens: TOKENS, tokenBudget: [] })).indexOf('TOKEN BUDGET') === -1 && panel(run(oneTicket, { tokens: TOKENS })).indexOf('TOKEN BUDGET') === -1);
truthy('malformed tokenBudget entries are dropped, never crash', panel(run(oneTicket, { tokens: TOKENS, tokenBudget: [null, 5, 'x', { scope: 'item' }, { scope: 'bogus', used: 1, limit: 2 }, { scope: 'run', used: 'a', limit: 1 }] })).indexOf('TOKEN BUDGET') === -1 &&
    panel(run(oneTicket, { tokens: TOKENS, tokenBudget: 'nope' })).indexOf('TOKEN BUDGET') === -1);
truthy('budget badge for an item with no token block still lands on its card', panel(run([ticket({ id: 'XACA-9' })], { tokenBudget: [{ scope: 'item', item: 'XACA-9', used: 5, limit: 4 }] })).indexOf('limit 4') !== -1);

// --- XACA-1549-017: event feed reads the ledger envelope {ts, run, kind, ...} ---------------------------------
const roSrc = fs.readFileSync(path.join(ROOT, '..', 'kanban-hooks', 'release_orchestrator.py'), 'utf8');
const kindConsts = {};
for (const m of roSrc.matchAll(/^(KIND_[A-Z_]+(?:\s*,\s*KIND_[A-Z_]+)*)\s*=\s*("[a-z_]+"(?:\s*,\s*"[a-z_]+")*)/gm)) {
    const names = m[1].split(',').map((x) => x.trim());
    const vals = m[2].match(/"([a-z_]+)"/g).map((x) => x.replace(/"/g, ''));
    names.forEach((n, i) => { kindConsts[n] = vals[i]; });
}
const lk = roSrc.slice(roSrc.indexOf('LEDGER_KINDS = {'));
const pyKinds = (lk.slice(0, lk.indexOf('\n}')).match(/KIND_[A-Z_]+(?=:)/g) || []).map((n) => kindConsts[n]);
truthy('python LEDGER_KINDS parsed (every LEDGER_KINDS constant resolved, none undefined, no duplicates)',
    pyKinds.length > 0 && pyKinds.every(Boolean) && new Set(pyKinds).size === pyKinds.length);
check('JS event kind list covers exactly release_orchestrator.py LEDGER_KINDS', vm.runInContext('ORCH_EVENT_KINDS', sandbox).slice().sort(), pyKinds.slice().sort());

const KIND_CASES = {
    run_start: [{ release: 'REL-1', coordinator: 'academy:picard', maxParallel: 3, waves: [] }, ['coordinator=academy:picard', 'maxParallel=3']],
    // full kb-dispatch --json shape (_kb_dispatch_result)
    dispatch: [{ item: 'XACA-7', dispatch: { item: 'XACA-7', terminal: 'engineering', session: 's', window: 2, model: 'sonnet-5', run: 'RUN-1', outcome: 'DISPATCHED', reason: '', observed: { x: 1 }, ts: 't' } }, ['item=XACA-7', 'outcome=DISPATCHED', 'terminal=engineering', 'model=sonnet-5']],
    state: [{ item: 'XACA-7', from: 'RUNNING', to: 'FAILED', detail: 'tests red' }, ['item=XACA-7', 'RUNNING → FAILED', 'detail=tests red']],
    question: [{ item: 'XACA-7', thread: 'thr-1', question: 'Old API or new?', to: 'academy:picard' }, ['item=XACA-7', 'to=academy:picard', 'question=Old API or new?']],
    answer: [{ item: 'XACA-7', thread: 'thr-1', question: 'Old API or new?', answer: 'new', askedBy: 'academy:reno' }, ['item=XACA-7', 'askedBy=academy:reno', 'answer=new']],
    stall: [{ item: 'XACA-7' }, ['item=XACA-7']],
    crash: [{ item: 'XACA-7' }, ['item=XACA-7']],
    failed: [{ item: 'XACA-7' }, ['item=XACA-7']],
    done: [{ item: 'XACA-7' }, ['item=XACA-7']],
    verdict: [{ item: 'XACA-7', verdict: 'ITEM_FAILED', signature: 'sig', detail: 'PR #9 closed' }, ['verdict=ITEM_FAILED', 'item=XACA-7', 'detail=PR #9 closed']],
    run_end: [{ outcome: 'complete', detail: 'all merged' }, ['outcome=complete', 'detail=all merged']],
    lane: [{ item: 'XACA-7', lane: 'lane-2', action: 'assign' }, ['item=XACA-7', 'lane=lane-2', 'action=assign']],
    // orchestrator_monitor MODEL_MISMATCH: fields {item, expected, observed (list)} + the ledger's own signature
    model_mismatch: [{ item: 'XACA-7', expected: 'claude-fable-5-2', observed: ['claude-a', 'claude-b'], signature: 'sig' }, ['item=XACA-7', 'expected=claude-fable-5-2', 'observed=claude-a, claude-b']],
    // TOKEN_BUDGET: {scope, item, used, limit}; flagged in text
    token_budget: [{ scope: 'item', item: 'XACA-7', used: 1200, limit: 1000, signature: 'sig' }, ['scope=item', 'item=XACA-7', 'used=1200', 'limit=1000', 'OVER BUDGET']],
    // send_token_summary: totals/coordinator are objects and must be skipped, never dumped
    token_summary: [{ totals: { model: 'm', input: 1, cacheCreate: 2, cacheRead: 3, output: 4, turns: 5 }, total: 10, coordinator: { model: null, input: 0, cacheCreate: 0, cacheRead: 0, output: 0, turns: 0 },
        complete: false, unattributed: 2, modelMismatch: 1, items: 3 }, ['total=10', 'complete=false', 'unattributed=2', 'modelMismatch=1', 'items=3']],
    // XACA-1880 kb-nudge: {item, text, actor, pane}; rendered by the default branch (item only)
    nudge: [{ item: 'XACA-7', text: 'wake up', actor: 'academy:chancellor', pane: 'engineering:2' }, ['item=XACA-7']]
};
check('table covers every ledger kind', Object.getOwnPropertyNames(KIND_CASES).sort(), pyKinds.slice().sort());
function escHtmlText(t) { return t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
for (const kind of pyKinds) {
    const [fields, wants] = KIND_CASES[kind];
    const h = sandbox.orchEventsHtml([Object.assign({ ts: '2026-11-15T10:00:00Z', run: 'RUN-1', kind: kind }, fields)], 1);
    truthy('event kind ' + kind + ' shows its kind and never "unknown"', h.indexOf('>' + kind + '</span>') !== -1 && h.indexOf('unknown') === -1);
    for (const w of wants) truthy('event kind ' + kind + ' shows ' + w, h.indexOf(escHtmlText(w)) !== -1);
    truthy('event kind ' + kind + ' never dumps [object Object]', h.indexOf('[object') === -1);
}
// dispatch outcomes must be distinguishable (PR #1344 review round 2: DISPATCH_FAILED rendered as DISPATCHED)
const dispatchRow = (outcome, reason) => sandbox.orchEventsHtml([{ ts: 't', run: 'RUN-1', kind: 'dispatch', item: 'X-1',
    dispatch: { item: 'X-1', terminal: 'eng', model: 'sonnet', run: 'RUN-1', outcome: outcome, reason: reason, observed: {}, ts: 't' } }], 1);
const dOk = dispatchRow('DISPATCHED', ''), dRef = dispatchRow('REFUSED', 'LANES_FULL'), dFail = dispatchRow('DISPATCH_FAILED', 'DEADLINE');
truthy('DISPATCHED shows its outcome, no alert', dOk.indexOf('outcome=DISPATCHED') !== -1 && dOk.indexOf('orch-event-alert') === -1 && dOk.indexOf('NOT DISPATCHED') === -1);
truthy('REFUSED shows outcome + nested reason + text alert', dRef.indexOf('outcome=REFUSED') !== -1 && dRef.indexOf('reason=LANES_FULL') !== -1 && dRef.indexOf('NOT DISPATCHED') !== -1 && dRef.indexOf('orch-event-alert') !== -1);
truthy('DISPATCH_FAILED shows outcome + nested reason + text alert', dFail.indexOf('outcome=DISPATCH_FAILED') !== -1 && dFail.indexOf('reason=DEADLINE') !== -1 && dFail.indexOf('NOT DISPATCHED') !== -1);
truthy('the three dispatch outcomes render pairwise different', dOk !== dRef && dRef !== dFail && dOk !== dFail);
const longQ = sandbox.orchEventsHtml([{ ts: 't', kind: 'question', item: 'X-1', question: 'q'.repeat(500) }], 1);
truthy('only token_budget gets the OVER BUDGET flag; others do not', sandbox.orchEventsHtml([{ ts: 't', kind: 'model_mismatch', item: 'X' }], 1).indexOf('OVER BUDGET') === -1 &&
    sandbox.orchEventsHtml([{ ts: 't', kind: 'token_budget', scope: 'run', used: 2, limit: 1 }], 1).indexOf('OVER BUDGET') !== -1);
truthy('a bad model_mismatch observed value is joined or dropped, never [object Object]', sandbox.orchEventsHtml([{ ts: 't', kind: 'model_mismatch', item: 'X', observed: { a: 1 } }], 1).indexOf('[object') === -1);
truthy('long free text is truncated', longQ.indexOf('q'.repeat(200)) === -1 && longQ.indexOf('…') !== -1);
truthy('legacy `type` is only a fallback for events without `kind`', sandbox.orchEventsHtml([{ type: 'legacy', ts: 't' }], 1).indexOf('>legacy</span>') !== -1);
truthy('an event with neither kind nor type is the only "unknown"', sandbox.orchEventsHtml([{ ts: 't' }], 1).indexOf('>unknown</span>') !== -1);
truthy('hostile event fields are escaped', escHtml.indexOf('<img src=x') === -1 && escHtml.indexOf('<script') === -1);

// --- XACA-1549-013: CANCELLED chip contrast ------------------------------------------------------------------
function lum(hex) {
    const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((v) => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4));
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}
const cancelled = css.match(/\.orch-panel \.orch-chip-cancelled \{ background: (#[0-9a-f]{6}); color: #fff; \}/);
truthy('CANCELLED chip rule found with a 6-digit background', !!cancelled);
truthy('CANCELLED chip (white on ' + (cancelled && cancelled[1]) + ') meets WCAG AA 4.5:1', cancelled && 1.05 / (lum(cancelled[1]) + 0.05) >= 4.5);

// --- XACA-1549-012: items in no wave get a labelled trailing wave ---------------------------------------------
const unwaved = panel(run([], { waves: [[ticket({ id: 'A-1' })], [ticket({ id: 'A-9' })]], unwavedWave: 1, readError: 'orchestration.items holds item(s) in no wave: A-9' }));
truthy('unwaved trailing wave is labelled NOT IN ANY WAVE', unwaved.indexOf('NOT IN ANY WAVE') !== -1 && unwaved.indexOf('WAVE 2') === -1 && unwaved.indexOf('WAVE 1') !== -1);
truthy('a normal payload never says NOT IN ANY WAVE', panel(run([ticket()])).indexOf('NOT IN ANY WAVE') === -1);

// --- XACA-1549-015: recovery hint and stale-data marking -----------------------------------------------------
const hintHtml = panel(run([ticket()], { release: 'REL-<7>', readError: 'ledger corrupt' }));
truthy('error panel carries the recovery hint with the escaped release id', hintHtml.indexOf('Check with <code>kb-release-orchestrate status REL-&lt;7&gt;</code>') !== -1);
truthy('data shown beside a readError is marked orch-stale with a text label', hintHtml.indexOf('orch-stale') !== -1 && hintHtml.indexOf('LAST READABLE DATA') !== -1);
truthy('healthy data is not marked stale', panel(run([ticket()])).indexOf('orch-stale') === -1 && panel(run([ticket()])).indexOf('LAST READABLE DATA') === -1);
truthy('a no-run readError still carries the hint', readErrNoRun.indexOf('kb-release-orchestrate status REL-1') !== -1);

// --- XACA-1549-014: unchanged payload does not touch the DOM; focus survives a real change -------------------
function fakePanel() {
    const el = {
        dataset: { orchRelease: 'REL-1' }, writes: 0, _html: '', focused: null,
        get innerHTML() { return this._html; },
        set innerHTML(v) { this._html = v; this.writes++; },
        contains: (n) => n && n.inside === true,
        querySelector: (sel) => {
            if (sel === '.orch-events-summary') return { focus() { el.focused = 'summary'; } };
            return null;
        },
        querySelectorAll: () => []
    };
    return el;
}
const earlier = pending.slice();   // fetchImpl is shared: run after the earlier async block finishes
pending.push((async () => {
    await Promise.all(earlier);
    const el = fakePanel();
    sandbox.document.querySelectorAll = (sel) => sel === '.orch-panel' ? [el] : [];
    sandbox.document.activeElement = null;
    fetchImpl = async () => ({ ok: true, status: 200, json: async () => run([ticket()]) });
    await sandbox.loadOrchestrationPanel('REL-1');
    check('first load writes the DOM once', el.writes, 1);
    await sandbox.loadOrchestrationPanel('REL-1');
    check('an unchanged payload skips the DOM swap entirely', el.writes, 1);
    fetchImpl = async () => ({ ok: true, status: 200, json: async () => run([ticket({ since: '2026-11-15T11:00:00Z' })], { now: '2026-11-15T12:05:00Z' }) });
    sandbox.document.activeElement = { inside: true, classList: { contains: (c) => c === 'orch-events-summary' } };
    await sandbox.loadOrchestrationPanel('REL-1');
    check('a changed payload swaps the DOM', el.writes, 2);
    check('focus on the EVENT FEED summary is restored after the swap', el.focused, 'summary');
    sandbox.document.querySelectorAll = () => [];
    sandbox.document.activeElement = null;
})());

// --- wiring / no new timer --------------------------------------------------------------------------------
truthy('ORCH block adds no setInterval', orchBlock.indexOf('setInterval') === -1);
check('lcars.js setInterval count is unchanged (13 on develop)', count(source, 'setInterval('), 13);
const tick = source.slice(source.indexOf('function startAutoRefresh()'), source.indexOf('function stopAutoRefresh()'));
truthy('the existing auto-refresh tick refreshes the orchestration panels', tick.indexOf('refreshOrchestrationPanels()') !== -1);
truthy('renderReleaseCard calls renderOrchestrationPanel', extractFunction('renderReleaseCard').indexOf('renderOrchestrationPanel(release.id, release)') !== -1);
// --- no fetch for a release without an orchestration summary (XACA-1549 review) -------------------------
const noRun = sandbox.renderOrchestrationPanel('REL-1', { id: 'REL-1', status: 'planned' });
truthy('no orchestration summary -> static empty state', noRun.indexOf('No orchestration run') !== -1);
truthy('no orchestration summary -> shell is NOT hydrated (no data-orch-release)', noRun.indexOf('data-orch-release') === -1);
const withRun = sandbox.renderOrchestrationPanel('REL-2', { id: 'REL-2', orchestration: { activeRunId: 'R1' } });
truthy('orchestration summary present -> shell is hydrated', withRun.indexOf('data-orch-release="REL-2"') !== -1);
const malformedRun = sandbox.renderOrchestrationPanel('REL-3', { id: 'REL-3', orchestration: 'garbage' });
truthy('malformed orchestration still fetches (server reports readError, never a guessed empty)', malformedRun.indexOf('data-orch-release="REL-3"') !== -1 && malformedRun.indexOf('No orchestration run') === -1);

truthy('displayReleases hydrates the panels', extractFunction('displayReleases').indexOf('hydrateOrchestrationPanels(dashboard)') !== -1);
truthy('panel CSS is scoped under .orch-panel', (css.match(/^\.orch-(?!panel[ ,{])[a-z-]+/gm) || []).length === 0);

Promise.all(pending).then(() => {
    if (failures) {
        console.error(failures + ' check(s) failed');
        process.exit(1);
    }
    console.log('all checks passed');
});
