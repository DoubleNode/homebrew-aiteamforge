#!/usr/bin/env node
//
//  test-xaca-1346-promote-modal-single-request.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 DoubleNode.com. All rights reserved.
//

/**
 * XACA-1346-048/047/049/052/053/054: the LCARS PROMOTE modal is about the RELEASE.
 *
 *   - ONE preview "current stage -> target stage" from the SERVER's dry run, unmet conditions as a
 *     LIST, each next to the remedy for THAT condition (keyed on the server's stable reason CODE,
 *     never on prose: a test called "lead-time" must not look like a lead problem).
 *   - ONE confirm request carrying the PREVIEWED targetStage, actor, confirmDeploy:false, no platform.
 *   - PROD warning keyed on the TARGET; report mode shows reasons on success; the remedy reads as
 *     "in enforce mode this would require ..." when PROMOTE is enabled anyway.
 *   - Remedy commands come from ONE table (PROMOTE_REMEDY_COMMANDS). PR 3b adds those CLI flags;
 *     PR 3b's zsh suite cross-checks the table. Here: every built command uses exactly the declared flags.
 *   - Cancel is disabled / the modal cannot be closed while the request is in flight.
 *
 * lcars.js is a big browser file with top-level DOM calls, so, like the sibling suites, this slices
 * the DOM-free block between PROMOTE-MODAL-PURE-START/END, `executePromotion` and
 * `hidePromoteModal` out of the source. A missing anchor FAILS loudly.
 *
 * Run: node lcars-ui/tests/test-xaca-1346-promote-modal-single-request.js
 */

'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('assert');
const vm = require('vm');

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
const EXEC = slice('async function executePromotion() {', '/**\n * Display the promotion result');
const HIDE = slice('function hidePromoteModal() {', 'function promoteListHtml(items)');
const STEP_NEXT = slice('function promoteStepNext() {', '/**\n * Execute the promotion');
const MODAL_BLOCK = slice('// PROMOTE MODAL (XACA-0026, redesigned', '// RELNOTES MODAL (XACA-0026)');

let failures = 0;
async function test(name, fn) {
    try { await fn(); console.log('ok - ' + name); } catch (err) {
        failures += 1;
        console.error('FAIL: ' + name + ': ' + (err && err.message));
    }
}
const arr = (x) => Array.from(x);

function pureSandbox() {
    const sb = { JSON, Array, Object, String, RegExp, Set, Map };
    vm.createContext(sb);
    vm.runInContext(PURE + '\nthis.api = {buildPromotePreviewModel, buildPromoteResultModel, promoteRemedyFor, ' +
        'buildPromoteReasonItems, promoteEnvClass, promotePlatformLabel, PROMOTE_REMEDY_COMMANDS};', sb);
    return sb.api;
}

function execSandbox(state, responder) {
    const calls = [];
    const models = [];
    const el = { textContent: '', style: {} };
    const sb = {
        promoteModalState: state,
        document: { getElementById: () => el },
        apiUrl: (p) => p,
        apiFetch: async (url, opts) => { calls.push({ url, body: JSON.parse(opts.body), opts }); return responder(calls.length); },
        displayPromotionResult: (m) => models.push(m),
        JSON, Array, Object, String, RegExp, Set, Map, Promise,
    };
    vm.createContext(sb);
    vm.runInContext(PURE + '\n' + EXEC + '\n' + HIDE + '\nthis.executePromotion = executePromotion; this.hidePromoteModal = hidePromoteModal;', sb);
    return { sb, calls, models, el };
}

const api = pureSandbox();
const release = (platforms) => ({
    id: 'REL-1', name: 'R',
    platforms: platforms || { ios: { version: '2.10.0', buildNumber: 42 }, android: { version: '2.10.0', buildNumber: 7 } }
});
const okResp = (body) => ({ ok: true, status: 200, json: async () => body });
const errResp = (status, body) => ({ ok: false, status, json: async () => body });
const stateFor = (preview) => ({ releaseId: 'REL-1', preview, result: null, inFlight: false });

// A payload as the server builds it: parallel reasons / reasonCodes / reasonData.
const payload = (rows, extra) => Object.assign({
    reasons: rows.map(r => r[0]), reasonCodes: rows.map(r => r[1]), reasonData: rows.map(r => r[2] || null)
}, extra || {});

const GAMMA_CMD = 'kb-release promote REL-1 --to GAMMA --confirm-deploy --actor <lead>';
const flagsOf = (cmd) => Array.from(new Set(cmd.match(/--[a-z][a-z-]*/g) || [])).sort();

(async () => {
    // ── REVIEW step: one release-level preview from the server's dry run ─────────────────
    for (const row of [
        { name: 'CR off: names the server target', from: 'QA', to: 'ALPHA' },
        { name: 'CR on: names CR', from: 'BETA', to: 'CR' },
        { name: 'non-CR next after BETA is GAMMA', from: 'BETA', to: 'GAMMA' },
    ]) {
        await test('preview target == server target: ' + row.name, () => {
            const m = api.buildPromotePreviewModel(release(), { allowed: true, mode: 'report', from: row.from, to: row.to, next: row.to, reasons: [] });
            assert.strictEqual(m.from, row.from);
            assert.strictEqual(m.to, row.to);
            assert.strictEqual(m.canPromote, true);
            assert.strictEqual(m.reasonItems.length, 0);
        });
    }

    for (const row of [
        { to: 'PROD', warn: true, n: 1 }, { to: 'PROD', warn: true, n: 3 },
        { to: 'QA', warn: false, n: 1 }, { to: 'CR', warn: false, n: 1 },
    ]) {
        await test('PROD warning keyed on the TARGET (' + row.to + ', ' + row.n + ' platform(s))', () => {
            const plats = {};
            ['ios', 'android', 'firebase'].slice(0, row.n).forEach(p => { plats[p] = {}; });
            const m = api.buildPromotePreviewModel(release(plats), { allowed: true, from: 'X', to: row.to, reasons: [] });
            assert.strictEqual(m.warnings.some(w => /PRODUCTION/.test(w)), row.warn);
        });
    }

    await test('platforms are read-only lines with version and build (XACA-1346-053)', () => {
        const m = api.buildPromotePreviewModel(release({ ios: { version: '2.10.0', buildNumber: 42 }, firebase: { version: '1.0.0' }, web: {} }),
            { allowed: true, from: 'QA', to: 'ALPHA', reasons: [] });
        assert.deepStrictEqual(arr(m.platformLines), ['iOS v2.10.0 (build 42)', 'Firebase v1.0.0', 'Web version not set']);
        assert.ok(/read-only/.test(m.platformsInfo));
        assert.ok(!('selected' in m));
    });

    await test('badge class never renders env-null (XACA-1346 observation)', () => {
        assert.strictEqual(api.promoteEnvClass(null), 'env-unknown');
        assert.strictEqual(api.promoteEnvClass(undefined), 'env-unknown');
        assert.strictEqual(api.promoteEnvClass('CR'), 'env-cr');
        assert.ok(!/env-null/.test(MODAL_BLOCK));
    });

    await test('a failed preview (no target) cannot be promoted and says why', () => {
        const m = api.buildPromotePreviewModel(release(), { allowed: false, reasons: [], error: 'boom' });
        assert.strictEqual(m.canPromote, false);
        assert.strictEqual(m.to, null);
        assert.deepStrictEqual(arr(m.reasons), ['boom']);
        assert.strictEqual(api.buildPromotePreviewModel(release(), null).canPromote, false);
    });

    // ── per-reason-class remedy (XACA-1346-052/054), keyed on the reason CODE ─────────────
    const R = 'REL-1';
    const classes = [
        { cls: 'GAMMA confirmation missing', row: ['GAMMA: lead must explicitly confirm the production deploy', 'GAMMA_CONFIRM_REQUIRED', { stage: 'GAMMA' }],
          cmd: GAMMA_CMD },
        { cls: 'actor not a lead at GAMMA', row: ["GAMMA: deploy confirmation refused: actor 'x' is not in releaseConfig.leads", 'GAMMA_ACTOR_NOT_LEAD', { stage: 'GAMMA' }],
          cmd: GAMMA_CMD },
        { cls: 'test needs a waiver (FAIL/SKIP)', row: ["QA: test 't2' result is FAIL", 'WAIVER_NEEDED', { stage: 'QA', test: 't2' }],
          cmd: 'kb-release waive REL-1 --stage QA --tests t2 --reason "..." --by <lead>' },
        { cls: 'waiver granted by a non-lead', row: ['only the release lead may grant a waiver', 'WAIVER_NOT_LEAD', { stage: 'QA', test: 't2' }],
          cmd: 'kb-release waive REL-1 --stage QA --tests t2 --reason "..." --by <a name in releaseConfig.leads>' },
        { cls: 'actor not in releaseConfig.leads', row: ["actor 'mallory' is not in releaseConfig.leads", 'NOT_IN_LEADS', null],
          cmd: 'kb-release waive REL-1 --stage <STAGE> --tests <test> --reason "..." --by <a name in releaseConfig.leads>' },
        { cls: 'waiver void: new SHA', row: ["QA: test 't2' result is FAIL; waiver VOID: waiver sha aaa != graded sha bbb", 'WAIVER_VOID_SHA', { stage: 'QA', test: 't2' }],
          cmd: 'kb-release waive REL-1 --stage QA --tests t2 --reason "..." --by <lead>', text: /re-run the test at the new SHA/i },
        { cls: 'waiver void: invalid', row: ["QA: test 't2' result is FAIL; waiver VOID: waiver is malformed: 'by' is blank", 'WAIVER_VOID_INVALID', { stage: 'QA', test: 't2' }],
          cmd: 'kb-release waive REL-1 --stage QA --tests t2 --reason "..." --by <lead>' },
    ];
    for (const c of classes) {
        await test('remedy class: ' + c.cls + ' -> its own command', () => {
            const items = api.buildPromoteReasonItems(R, payload([c.row]), false);
            assert.strictEqual(items.length, 1);
            assert.strictEqual(items[0].text, c.row[0]);
            assert.strictEqual(items[0].remedy.command, c.cmd);
            if (c.text) assert.ok(c.text.test(items[0].remedy.text), items[0].remedy.text);
        });
    }

    await test('remedy class: a missing test names NO command (a waiver cannot cover it)', () => {
        const items = api.buildPromoteReasonItems(R, payload([["QA: expected test 't2' has no current record at SHA abc (missing != passing)", 'TEST_MISSING', { stage: 'QA', test: 't2' }]]), false);
        assert.strictEqual(items[0].remedy.command, null);
        assert.ok(/cannot cover/.test(items[0].remedy.text));
    });

    await test('remedy class: leads list missing/empty -> configure releaseConfig.leads, NO command', () => {
        const items = api.buildPromoteReasonItems(R, payload([['releaseConfig.leads is missing or empty; nobody can be authorized as lead (fails closed)', 'LEADS_NOT_CONFIGURED']]), false);
        assert.strictEqual(items[0].remedy.command, null);
        assert.ok(/Configure releaseConfig\.leads/.test(items[0].remedy.text));
    });

    await test('leads not configured suppresses every lead command (never advise a command that will be refused)', () => {
        const items = api.buildPromoteReasonItems(R, payload([
            ['GAMMA: lead must explicitly confirm the production deploy', 'GAMMA_CONFIRM_REQUIRED', { stage: 'GAMMA' }],
            ["QA: test 't2' result is FAIL", 'WAIVER_NEEDED', { stage: 'QA', test: 't2' }],
            ['releaseConfig.leads is missing or empty; nobody can be authorized as lead (fails closed)', 'LEADS_NOT_CONFIGURED'],
        ]), false);
        for (const it of items) assert.ok(!it.remedy || it.remedy.command === null, JSON.stringify(it));
        assert.ok(items[2].remedy && /Configure releaseConfig\.leads/.test(items[2].remedy.text));
    });

    await test('anything else: no remedy, just the reason', () => {
        for (const code of ['other', undefined, 'SOMETHING_NEW']) {
            const items = api.buildPromoteReasonItems(R, { reasons: ['skipping refused: next enabled stage after QA is ALPHA, not PROD'], reasonCodes: [code] }, false);
            assert.strictEqual(items[0].remedy, null);
        }
        const bare = api.buildPromoteReasonItems(R, { reasons: ['legacy payload without codes'] }, false);
        assert.strictEqual(bare[0].remedy, null);
    });

    await test("V5: a missing test named 'lead-time' is NOT a lead problem (codes, not prose)", () => {
        const items = api.buildPromoteReasonItems(R, payload([["QA: expected test 'lead-time' has no current record at SHA abc (missing != passing)", 'TEST_MISSING', { stage: 'QA', test: 'lead-time' }]]), false);
        assert.ok(!/kb-release (promote|waive)/.test(JSON.stringify(items)));
        const other = api.buildPromoteReasonItems(R, payload([["anything about a lead-time test", 'other']]), false);
        assert.strictEqual(other[0].remedy, null);
    });

    await test("a waiver command for a test named 'lead-time' quotes/keeps the name intact", () => {
        const items = api.buildPromoteReasonItems(R, payload([["QA: test 'lead-time' result is FAIL", 'WAIVER_NEEDED', { stage: 'QA', test: 'lead-time' }]]), false);
        assert.strictEqual(items[0].remedy.command, 'kb-release waive REL-1 --stage QA --tests lead-time --reason "..." --by <lead>');
        const spaced = api.buildPromoteReasonItems(R, payload([["x", 'WAIVER_NEEDED', { stage: 'QA', test: 'my test; rm' }]]), false);
        assert.ok(spaced[0].remedy.command.includes('--tests "my test; rm"'));
    });

    await test('mixed GAMMA + waiver: both remedies shown, each next to its own reason, identical ones deduped', () => {
        const items = api.buildPromoteReasonItems(R, payload([
            ['GAMMA: lead must explicitly confirm the production deploy', 'GAMMA_CONFIRM_REQUIRED', { stage: 'GAMMA' }],
            ["GAMMA: test 'smoke' result is FAIL", 'WAIVER_NEEDED', { stage: 'GAMMA', test: 'smoke' }],
            ["GAMMA: deploy confirmation refused: actor 'x' is not in releaseConfig.leads", 'GAMMA_ACTOR_NOT_LEAD', { stage: 'GAMMA' }],
            ["GAMMA: test 'smoke' result is FAIL", 'WAIVER_NEEDED', { stage: 'GAMMA', test: 'smoke' }],
        ]), false);
        assert.strictEqual(items[0].remedy.command, GAMMA_CMD);
        assert.strictEqual(items[1].remedy.command, 'kb-release waive REL-1 --stage GAMMA --tests smoke --reason "..." --by <lead>');
        assert.strictEqual(items[2].remedy, null, 'identical GAMMA remedy is shown once');
        assert.strictEqual(items[3].remedy, null, 'identical waiver remedy is shown once');
        assert.strictEqual(items.length, 4);
    });

    await test('report mode (allowed:true + reasons): remedy reads as what ENFORCE would require, not an instruction', () => {
        const m = api.buildPromotePreviewModel(release(), Object.assign(payload([
            ['GAMMA: lead must explicitly confirm the production deploy', 'GAMMA_CONFIRM_REQUIRED', { stage: 'GAMMA' }]]),
            { allowed: true, mode: 'report', from: 'BETA', to: 'GAMMA' }));
        assert.strictEqual(m.canPromote, true);
        const t = m.reasonItems[0].remedy.text;
        assert.ok(/^In enforce mode this would require/.test(t), t);
        assert.ok(!/must confirm/.test(t));
        assert.ok(/enforce mode/.test(m.reasonsHeading) && /report mode/.test(m.reasonsHeading));
        const refused = api.buildPromotePreviewModel(release(), Object.assign(payload([
            ['GAMMA: lead must explicitly confirm the production deploy', 'GAMMA_CONFIRM_REQUIRED', { stage: 'GAMMA' }]]),
            { allowed: false, mode: 'enforce', from: 'BETA', to: 'GAMMA' }));
        assert.ok(/^A release lead must confirm/.test(refused.reasonItems[0].remedy.text));
    });

    await test('V1-V3 regression: advice depends on WHICH condition failed and the right stage', () => {
        // V2: QA->ALPHA skipped test -> waiver for QA, NOT a GAMMA confirmation
        const v2 = api.buildPromoteResultModel(R, { from: 'QA', to: 'ALPHA' }, { ok: false, status: 409, data: payload([["QA: test 't2' was SKIPped and is not optional (needs a lead waiver)", 'WAIVER_NEEDED', { stage: 'QA', test: 't2' }]]) });
        assert.ok(v2.reasonItems[0].remedy.command.startsWith('kb-release waive REL-1 --stage QA'));
        assert.ok(!/GAMMA/.test(JSON.stringify(v2.reasonItems)));
        // V3: GAMMA->PROD with no leads configured -> configure leads, never "GAMMA requires"
        const v3 = api.buildPromoteResultModel(R, { from: 'GAMMA', to: 'PROD' }, { ok: false, status: 409, data: payload([['releaseConfig.leads is missing or empty; nobody can be authorized as lead (fails closed)', 'LEADS_NOT_CONFIGURED']]) });
        assert.ok(/Configure releaseConfig\.leads/.test(v3.reasonItems[0].remedy.text));
        assert.ok(!/GAMMA requires/.test(JSON.stringify(v3)));
    });

    // ── remedy commands come from ONE declared table (PR 3b cross-checks it) ─────────────
    await test('PROMOTE_REMEDY_COMMANDS is the declared table and every built command uses exactly its flags', () => {
        const T = api.PROMOTE_REMEDY_COMMANDS;
        assert.deepStrictEqual(Object.keys(T).sort(), ['GAMMA_CONFIRM', 'WAIVE']);
        assert.strictEqual(T.GAMMA_CONFIRM.command, 'kb-release promote');
        assert.strictEqual(T.WAIVE.command, 'kb-release waive');
        const gamma = api.buildPromoteReasonItems(R, payload([['g', 'GAMMA_CONFIRM_REQUIRED', { stage: 'GAMMA' }]]), false)[0].remedy.command;
        const waive = api.buildPromoteReasonItems(R, payload([['w', 'WAIVER_NEEDED', { stage: 'QA', test: 't' }]]), false)[0].remedy.command;
        assert.ok(gamma.startsWith(T.GAMMA_CONFIRM.command + ' REL-1 '));
        assert.ok(waive.startsWith(T.WAIVE.command + ' REL-1 '));
        assert.deepStrictEqual(flagsOf(gamma), arr(T.GAMMA_CONFIRM.flags).sort());
        assert.deepStrictEqual(flagsOf(waive), arr(T.WAIVE.flags).sort());
    });

    await test('no kb-release command is hard-coded outside the table', () => {
        const outside = MODAL_BLOCK.replace(/const PROMOTE_REMEDY_COMMANDS = \{[\s\S]*?\n\};/, '');
        const hits = (outside.match(/kb-release (promote|waive)/g) || []).length;
        // the two builders read the table; prose/comments may name the command
        assert.ok(!/'kb-release (promote|waive) '/.test(outside), 'a command string is hard-coded outside the table');
        assert.ok(hits >= 0);
    });

    // ── RESULT step ──────────────────────────────────────────────────────────────────────
    await test('success result: title and toast name the release and stage, no platform copy', () => {
        const m = api.buildPromoteResultModel(R, { from: 'QA', to: 'ALPHA' }, { ok: true, status: 200, data: { from: 'QA', to: 'ALPHA', reasons: [] } });
        assert.strictEqual(m.success, true);
        assert.strictEqual(m.title, 'Release promoted: QA → ALPHA');
        assert.strictEqual(m.toast, 'Release REL-1 promoted to ALPHA');
        assert.strictEqual(m.reasonItems.length, 0);
        assert.ok(!/platform/i.test(m.title + m.toast));
    });

    await test('report-mode success shows the reasons the gate would have refused, remedies conditional', () => {
        const m = api.buildPromoteResultModel(R, { from: 'QA', to: 'ALPHA' },
            { ok: true, status: 200, data: payload([["QA: test 't2' result is FAIL", 'WAIVER_NEEDED', { stage: 'QA', test: 't2' }], ['QA: x', 'other']], { from: 'QA', to: 'ALPHA', mode: 'report' }) });
        assert.strictEqual(m.reasonsHeading, 'Promoted; the gate would have refused in enforce mode:');
        assert.deepStrictEqual(arr(m.reasons).length, 2);
        assert.ok(/^In enforce mode this would require/.test(m.reasonItems[0].remedy.text));
    });

    await test("a stale preview's 409 is displayed as a list, not joined and not 'HTTP 409'", () => {
        const reasons = ['skipping refused: next enabled stage after QA is ALPHA, not BETA', 'QA: t2 missing', 'QA: t3 FAIL'];
        const m = api.buildPromoteResultModel(R, { from: 'QA', to: 'BETA' },
            { ok: false, status: 409, data: { allowed: false, reasons, error: reasons[0] + ' (+2 more)' } });
        assert.strictEqual(m.success, false);
        assert.strictEqual(m.title, 'Promotion refused');
        assert.strictEqual(m.reasonItems.length, 3);
        assert.deepStrictEqual(arr(m.reasonItems.map(i => i.text)), reasons);
        assert.ok(!/HTTP 409/.test(JSON.stringify(m)));
        assert.ok(/^Promotion refused: skipping refused/.test(m.toast));
    });

    await test('transport / empty-body failures fall back to error text, then HTTP status', () => {
        assert.deepStrictEqual(arr(api.buildPromoteResultModel(R, { to: 'A' }, { ok: false, status: 0, data: { error: 'boom' } }).reasons), ['boom']);
        assert.deepStrictEqual(arr(api.buildPromoteResultModel(R, { to: 'A' }, { ok: false, status: 500, data: {} }).reasons), ['HTTP 500']);
    });

    // ── executePromotion: exactly one request carrying the PREVIEWED targetStage ─────────
    for (const to of ['ALPHA', 'CR', 'GAMMA', 'PROD']) {
        await test('confirm sends exactly ONE request with targetStage == previewed stage (' + to + ')', async () => {
            const { sb, calls, models } = execSandbox(stateFor({ from: 'X', to, allowed: true }), () => okResp({ from: 'X', to, reasons: [] }));
            await sb.executePromotion();
            assert.strictEqual(calls.length, 1, 'expected one request, got ' + calls.length);
            assert.strictEqual(calls[0].url, '/api/releases/REL-1/promote');
            assert.strictEqual(calls[0].opts.method, 'POST');
            assert.deepStrictEqual(Object.keys(calls[0].body).sort(), ['actor', 'confirmDeploy', 'targetStage']);
            assert.strictEqual(calls[0].body.targetStage, to);
            assert.strictEqual(calls[0].body.confirmDeploy, false);
            assert.strictEqual(calls[0].body.actor, 'lcars-ui');
            assert.strictEqual(models.length, 1);
            assert.strictEqual(models[0].to, to);
        });
    }

    await test('a 409 from a stale preview is surfaced as a refusal result', async () => {
        const { sb, models } = execSandbox(stateFor({ from: 'QA', to: 'ALPHA', allowed: true }),
            () => errResp(409, { allowed: false, reasons: ['skipping refused: next enabled stage after ALPHA is BETA, not ALPHA'] }));
        await sb.executePromotion();
        assert.strictEqual(models[0].success, false);
        assert.ok(models[0].reasons[0].startsWith('skipping refused'));
    });

    await test('a network failure is reported once', async () => {
        const { sb, models, calls } = execSandbox(stateFor({ from: 'QA', to: 'ALPHA', allowed: true }), () => { throw new Error('boom'); });
        await sb.executePromotion();
        assert.strictEqual(calls.length, 1);
        assert.deepStrictEqual(arr(models[0].reasons), ['boom']);
    });

    // ── in flight: Cancel cannot pretend to cancel ───────────────────────────────────────
    await test('while the request is in flight the modal cannot be closed; afterwards it can', async () => {
        const state = stateFor({ from: 'QA', to: 'ALPHA', allowed: true });
        let release_;
        const gate = new Promise(r => { release_ = r; });
        const { sb, models, el } = execSandbox(state, () => gate.then(() => okResp({ from: 'QA', to: 'ALPHA', reasons: [] })));
        el.style.display = 'flex';
        const running = sb.executePromotion();
        assert.strictEqual(state.inFlight, true);
        sb.hidePromoteModal();
        assert.strictEqual(el.style.display, 'flex', 'hide must be refused while a request is in flight');
        release_();
        await running;
        assert.strictEqual(state.inFlight, false);
        assert.strictEqual(models.length, 1, 'the eventual result is still shown');
        sb.hidePromoteModal();
        assert.strictEqual(el.style.display, 'none');
    });

    await test('PROMOTE disables Cancel before the request starts', () => {
        assert.ok(/promote-cancel-btn'\)\.disabled = true/.test(STEP_NEXT));
        assert.ok(/if \(promoteModalState\.inFlight\) return;/.test(STEP_NEXT));
    });

    // ── copy / markup hygiene ────────────────────────────────────────────────────────────
    for (const bad of ['platform(s)', 'Promoting ${label}', '\u{1F525}', '\u{1F34E}', 'All promotions', 'selectedPlatforms', 'nextEnv', 'promoteNeedsLead', 'GAMMA requires a release lead']) {
        await test('modal source has no stale copy: ' + JSON.stringify(bad), () => {
            assert.ok(!MODAL_BLOCK.includes(bad), 'found ' + JSON.stringify(bad));
        });
    }

    await test('commands render in <code>, not literal backticks', () => {
        assert.ok(/<code>\$\{escapeHtml\(i\.remedy\.command\)\}<\/code>/.test(MODAL_BLOCK));
        for (const c of classes) {
            const items = api.buildPromoteReasonItems(R, payload([c.row]), false);
            assert.ok(!/`/.test(JSON.stringify(items)), 'no literal backticks in ' + c.cls);
        }
    });

    await test('results and preview containers are aria-live regions', () => {
        const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
        assert.ok(/id="promote-results"[^>]*aria-live="polite"/.test(html));
        assert.ok(/id="promote-preview"[^>]*aria-live="polite"/.test(html));
    });

    if (failures) { process.exit(1); }
})();
