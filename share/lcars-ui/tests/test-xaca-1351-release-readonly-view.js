#!/usr/bin/env node
//
//  test-xaca-1351-release-readonly-view.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 DoubleNode.com. All rights reserved.
//

/**
 * XACA-1351-001/-002/-003: the LCARS Releases tab is READ-ONLY.
 *   - The PROMOTE button, modal markup and promote machinery are gone (promotion happens only through the
 *     gated server endpoint, driven by the kb-release CLI).
 *   - computeReleaseStageTestTotals() counts release.tests[] per stage and per result; its numbers must
 *     equal what `jq` computes from the same array.
 *   - releaseLifecycleHtml() renders stage / stage status / test totals / CR link+state / expected approval
 *     from the record, escapes every value, and never turns a MISSING field into a zero.
 *
 * Extracts the real functions from lcars.js (brace-matched, unmodified) and runs them on stubs.
 *
 * Run: node lcars-ui/tests/test-xaca-1351-release-readonly-view.js
 */

'use strict';

const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const vm = require('vm');

const ROOT = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(ROOT, 'js', 'lcars.js'), 'utf8');
const indexHtml = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');
const css = fs.readFileSync(path.join(ROOT, 'css', 'lcars.css'), 'utf8');

let failures = 0;
function check(name, actual, expected) {
    const a = JSON.stringify(actual);
    const e = JSON.stringify(expected);
    if (a === e) {
        console.log('ok - ' + name);
    } else {
        failures += 1;
        console.error('FAIL: ' + name + '\n  expected ' + e + '\n  actual   ' + a);
    }
}

/** Slice `function name(...) {...}` out of lcars.js by brace matching. */
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

const sandbox = {};
vm.createContext(sandbox);
// escapeHtml is DOM-backed in lcars.js (textContent -> innerHTML); this stub escapes the same three
// characters. escapeAttr is the real one.
vm.runInContext(
    'function escapeHtml(t) { return String(t == null ? "" : t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }\n' +
    extractFunction('escapeAttr') + '\n' +
    extractFunction('computeReleaseStageTestTotals') + '\n' +
    extractFunction('releaseLifecycleHtml') + '\n' +
    extractFunction('promoteStrandedBadgeHtml') + '\n',
    sandbox);
const totals = sandbox.computeReleaseStageTestTotals;
const html = sandbox.releaseLifecycleHtml;
const stranded = sandbox.promoteStrandedBadgeHtml;

function rec(stage, result, extra) {
    return Object.assign({ id: 'T', stage: stage, type: 'Automated', ts: '2026-10-01T00:00:00Z', env: 'ci',
        sha: 'a'.repeat(40), test: 't', result: result, runBy: 'x', notes: '', parent: null, supersededBy: null }, extra || {});
}

// --- fixtures -------------------------------------------------------------------------------------------
const NORMAL = [
    rec('DEV', 'PASS'), rec('DEV', 'PASS'), rec('DEV', 'PASS'), rec('DEV', 'FAIL', { notes: 'x', supersededBy: 'T0009' }),
    rec('QA', 'PASS'), rec('QA', 'PASS'), rec('QA', 'SKIP', { notes: 'x' }),
];
const MIXED = NORMAL.concat([
    rec('WEIRD', 'PASS'),                // unknown stage
    rec(undefined, 'FAIL'),              // missing stage
    rec('GAMMA', 'MAYBE'),               // unknown result
    null, 'junk', 7, [],                 // not records
    rec('__proto__', 'PASS'),            // hostile stage key
]);

function byStage(t, s) { return t.rows.filter((r) => r.stage === s)[0]; }

// --- computeReleaseStageTestTotals ----------------------------------------------------------------------
const tn = totals(NORMAL);
check('normal: recorded', tn.recorded, true);
check('normal: stage order is canonical (DEV, QA)', tn.rows.map((r) => r.stage), ['DEV', 'QA']);
check('normal: DEV counts', [byStage(tn, 'DEV').total, byStage(tn, 'DEV').pass, byStage(tn, 'DEV').fail, byStage(tn, 'DEV').skip], [4, 3, 1, 0]);
check('normal: QA counts', [byStage(tn, 'QA').total, byStage(tn, 'QA').pass, byStage(tn, 'QA').fail, byStage(tn, 'QA').skip], [3, 2, 0, 1]);
check('normal: superseded is informational and still counted', [byStage(tn, 'DEV').superseded, byStage(tn, 'DEV').fail], [1, 1]);
check('normal: overall equals the sum of the rows', [tn.overall.total, tn.overall.pass, tn.overall.fail, tn.overall.skip], [7, 5, 1, 1]);

const te = totals([]);
check('empty tests[]: recorded but no rows and no overall counts', [te.recorded, te.rows.length, te.overall.total, te.invalid], [true, 0, 0, 0]);
for (const missing of [undefined, null, 'x', 5, {}]) {
    const tm = totals(missing);
    check('non-array tests (' + JSON.stringify(missing) + ') is NOT recorded: no rows, overall null', [tm.recorded, tm.rows.length, tm.overall], [false, 0, null]);
}

const tx = totals(MIXED);
check('mixed: unknown stage counted under its own name', byStage(tx, 'WEIRD').pass, 1);
check('mixed: missing stage counted under "(no stage)"', byStage(tx, '(no stage)').fail, 1);
check('mixed: unknown result goes to other, not pass/fail/skip', [byStage(tx, 'GAMMA').other, byStage(tx, 'GAMMA').pass + byStage(tx, 'GAMMA').fail + byStage(tx, 'GAMMA').skip], [1, 0]);
check('mixed: non-object entries are counted invalid, in no stage', [tx.invalid, tx.overall.total], [4, MIXED.length - 4]);
check('mixed: a stage named __proto__ is an ordinary row', [byStage(tx, '__proto__').pass, Object.prototype.hasOwnProperty.call(Object.prototype, 'pass')], [1, false]);
check('mixed: canonical rows precede unknown rows', tx.rows.map((r) => r.stage), ['DEV', 'QA', 'GAMMA', 'WEIRD', '(no stage)', '__proto__']);

// jq cross-check (acceptance: LCARS totals == jq counts from tests[]). Falls back to an independent
// reference counter where jq is not installed, so the assertion count is the same either way.
function jqCounts(tests) {
    const prog = 'group_by(.stage) | map({key: (.[0].stage // "(no stage)"), value: {total: length, pass: (map(select(.result == "PASS")) | length), ' +
        'fail: (map(select(.result == "FAIL")) | length), skip: (map(select(.result == "SKIP")) | length)}}) | from_entries';
    const r = cp.spawnSync('jq', ['-c', prog], { input: JSON.stringify(tests), encoding: 'utf8' });
    if (r.error || r.status !== 0) return null;
    return JSON.parse(r.stdout);
}
function referenceCounts(tests) {
    const out = {};
    tests.forEach((t) => {
        const k = t.stage || '(no stage)';
        out[k] = out[k] || { total: 0, pass: 0, fail: 0, skip: 0 };
        out[k].total++;
        if (t.result === 'PASS') out[k].pass++;
        if (t.result === 'FAIL') out[k].fail++;
        if (t.result === 'SKIP') out[k].skip++;
    });
    return out;
}
const JQ_FIXTURE = NORMAL.concat([rec('WEIRD', 'PASS'), rec(undefined, 'FAIL'), rec('GAMMA', 'MAYBE')]);
const oracle = jqCounts(JQ_FIXTURE) || referenceCounts(JQ_FIXTURE);
const viaLcars = {};
totals(JQ_FIXTURE).rows.forEach((r) => { viaLcars[r.stage] = { total: r.total, pass: r.pass, fail: r.fail, skip: r.skip }; });
const sorted = (o) => Object.getOwnPropertyNames(o).sort().map((k) => [k, o[k]]);
check('totals equal jq group_by(.stage) counts (or the reference counter when jq is absent)', sorted(viaLcars), sorted(oracle));

// --- releaseLifecycleHtml -------------------------------------------------------------------------------
const FULL = {
    id: 'REL-1', stage: 'QA',
    stages: { DEV: { status: 'passed' }, QA: { status: 'running' } },
    tests: NORMAL,
    linkedCRs: [{ crId: 'CR-0001', crTitle: 'T' }],   // real snapshot shape: id + title only
};
// CR state / link / expected approval live on the board's crs[] record (joined by id), not the snapshot.
const CRS = [
    { id: 'CR-0001', crState: 'cr-submitted', cr_confluence_url: 'https://example.atlassian.net/wiki/x',
        timestamps: { cr_approval_expected_at: '2026-10-05T14:00:00Z' } },
    { id: 'CR-0002', crState: 'cr-approved', releaseAssignment: { releaseId: 'REL-1' }, timestamps: {} },
    { id: 'CR-OTHER', crState: 'cr-drafted', releaseAssignment: { releaseId: 'REL-9' } },
];
const h = html(FULL, CRS);
check('renders current stage', h.indexOf('release-lifecycle-current">QA<') !== -1, true);
check('renders per-stage status from stages{}', h.indexOf('status-passed">PASSED<') !== -1 && h.indexOf('status-running">RUNNING<') !== -1, true);
check('renders DEV totals from tests[]', h.indexOf('3 pass</span> / <span class="release-lifecycle-fail">1 fail</span> / <span class="release-lifecycle-skip">0 skip</span> <span class="release-lifecycle-total">(4 total, 1 superseded)') !== -1, true);
check('renders QA totals from tests[]', h.indexOf('2 pass</span> / <span class="release-lifecycle-fail">0 fail</span> / <span class="release-lifecycle-skip">1 skip</span> <span class="release-lifecycle-total">(3 total)') !== -1, true);
check('renders CR id as an https link, with state and expected approval',
    h.indexOf('<a class="release-lifecycle-cr-link" href="https://example.atlassian.net/wiki/x"') !== -1 &&
    h.indexOf('cr-submitted') !== -1 && h.indexOf('2026-10-05T14:00:00Z') !== -1, true);
check('read-only: no button, no input, no onclick handler other than the link stopPropagation',
    /<button|<input|<select|<textarea/.test(h) === false && (h.match(/onclick=/g) || []).length === 1, true);

const hMissing = html({ id: 'REL-2', stage: 'DEV' });
check('missing tests[] renders "tests not recorded", never "0 pass"', hMissing.indexOf('tests not recorded') !== -1 && /0 pass/.test(hMissing) === false, true);
check('missing stages{} renders an em dash status', hMissing.indexOf('—') !== -1, true);
const hEmpty = html({ id: 'REL-3', stage: 'DEV', tests: [], stages: { DEV: { status: 'pending' } } });
check('empty tests[] renders "no results recorded", never "0 pass"', hEmpty.indexOf('no results recorded') !== -1 && /0 pass/.test(hEmpty) === false, true);
check('no linkedCRs renders "none linked"', hMissing.indexOf('none linked') !== -1, true);
check('CR joined via crs[].releaseAssignment.releaseId is shown', h.indexOf('CR-0002') !== -1 && h.indexOf('cr-approved') !== -1, true);
check('a CR assigned to another release is not shown', h.indexOf('CR-OTHER') === -1, true);
check('snapshot-only fields are ignored (state must come from crs[])',
    html({ id: 'R', linkedCRs: [{ crId: 'CR-S', crState: 'cr-approved' }] }, [{ id: 'CR-S' }]).indexOf('cr-approved') === -1, true);
check('a linked CR with no crs[] record says so explicitly',
    html({ id: 'R', linkedCRs: [{ crId: 'CR-GONE' }] }, []).indexOf('CR record not found on this board') !== -1, true);
check('defaults crList to window.boardData.crs', (() => {
    sandbox.window = { boardData: { crs: [{ id: 'CR-W', crState: 'cr-closed' }] } };
    const o = html({ id: 'R', linkedCRs: ['CR-W'] });
    delete sandbox.window;
    return o.indexOf('cr-closed') !== -1;
})(), true);
const hCrBare = html({ stage: 'DEV', linkedCRs: [{ crId: 'CR-9' }] }, [{ id: 'CR-9' }]);
check('a CR with no state / link / expected approval says "not recorded" for each and is not a link',
    (hCrBare.slice(hCrBare.indexOf('release-lifecycle-cr"')).match(/>not recorded</g) || []).length === 2 && hCrBare.indexOf('<a ') === -1 && hCrBare.indexOf('CR-9') !== -1, true);
check('a release with no stage renders an em dash, not "undefined"', html({}).indexOf('undefined') === -1 && html({}).indexOf('—') !== -1, true);

for (const bad of [null, undefined, 'str', 5, [], { tests: 'x', stages: 'y', linkedCRs: 'z' }, { tests: [null, 1], stages: { DEV: null }, linkedCRs: [null, 1, 'CR-1', []] }]) {
    let threw = false, out = '';
    try { out = html(bad); } catch (e) { threw = true; }
    check('malformed release ' + JSON.stringify(bad) + ' does not throw and yields markup', threw === false && out.indexOf('release-lifecycle') !== -1, true);
}

// escaping + URL safety
const HOSTILE = '<img src=x onerror=alert(1)>"\'';
const hh = html({ stage: HOSTILE, stages: { [HOSTILE]: { status: HOSTILE } },
    tests: [rec(HOSTILE, 'PASS')],
    linkedCRs: [{ crId: HOSTILE }] }, [{ id: HOSTILE, crState: HOSTILE, timestamps: { cr_approval_expected_at: HOSTILE }, cr_confluence_url: 'https://e.com/"onmouseover="x' }]);
check('hostile values never produce a live tag', /<img/i.test(hh) === false && hh.indexOf('&lt;img') !== -1, true);
check('hostile URL with a quote is not turned into an href', hh.indexOf('href=') === -1, true);
for (const u of ['javascript:alert(1)', 'data:text/html,x', 'vbscript:x', '//evil.example/x', 'ftp://x/y', 'HTTPS://ok.example/x y']) {
    check('CR url ' + JSON.stringify(u) + ' is not an href', html({ linkedCRs: [{ crId: 'CR-1' }] }, [{ id: 'CR-1', cr_confluence_url: u }]).indexOf('href=') === -1, true);
}
check('CR url http:// is an href', html({ linkedCRs: [{ crId: 'CR-1' }] }, [{ id: 'CR-1', cr_confluence_url: 'http://ok.example/x' }]).indexOf('href="http://ok.example/x"') !== -1, true);
check('a hostile stage name that is __proto__ does not crash or pollute', (() => {
    const o = html({ stage: '__proto__', stages: JSON.parse('{"__proto__": {"status": "passed"}}'), tests: [rec('__proto__', 'PASS')] });
    return o.indexOf('release-lifecycle') !== -1 && ({}).status === undefined;
})(), true);

// --- stranded badge survived the modal removal ----------------------------------------------------------
check('stranded badge: renders only for strandedInCR === true', [stranded({ strandedInCR: true }).indexOf('STRANDED IN CR') !== -1, stranded({ strandedInCR: 'true' }), stranded({}), stranded(null)], [true, '', '', '']);

// --- the promote UI is gone -----------------------------------------------------------------------------
const GONE_JS = ['promoteRelease', 'promote-modal', 'promoteModalState', 'executePromotion', 'hidePromoteModal', 'showPromoteLoading',
    'populatePromotePreview', 'buildPromotePreviewModel', 'buildPromoteResultModel', 'buildPromoteReasonItems', 'promoteStepNext',
    'updatePromoteStepIndicator', 'showPromoteStep', 'displayPromotionResult', 'promote-btn', 'PROMOTE-MODAL-PURE'];
GONE_JS.forEach((sym) => check('lcars.js has no ' + sym, source.indexOf(sym), -1));
check('lcars.js never POSTs to /promote', /\/promote['"`]/.test(source), false);
check('index.html has no promote-modal markup or handler', /promote-modal|promote-next-btn|promote-cancel-btn|hidePromoteModal|promoteStepNext/.test(indexHtml), false);
check('lcars.css has no promote-prefixed selectors', /\.promote-/.test(css), false);
check('renderReleaseCard calls the read-only lifecycle block', /\$\{releaseLifecycleHtml\(release\)\}/.test(source.slice(source.indexOf('function renderReleaseCard('))), true);
check('the empty-state hint no longer tells the operator to promote in the UI', source.indexOf('Promote a release platform to DEV') === -1, true);

if (failures > 0) {
    console.error('\n' + failures + ' test(s) failed.');
    process.exit(1);
}
console.log('All XACA-1351 read-only release view tests passed.');
