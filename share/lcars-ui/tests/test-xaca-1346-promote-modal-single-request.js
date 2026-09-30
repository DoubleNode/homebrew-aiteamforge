#!/usr/bin/env node
//
//  test-xaca-1346-promote-modal-single-request.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 DoubleNode.com. All rights reserved.
//

/**
 * XACA-1346-048/047/049: the LCARS PROMOTE modal is about the RELEASE, not its platforms.
 *
 *   - ONE preview "current stage -> target stage" taken from the SERVER's dry run (so the
 *     target names CR when CR is next), unmet conditions listed as a LIST.
 *   - ONE confirm request carrying the PREVIEWED targetStage (a stale preview is refused by the
 *     server with 409, never skipped past), actor and confirmDeploy:false, no platform.
 *   - The PROD warning is keyed on the TARGET stage.
 *   - Report mode shows the reasons on success; a refusal shows a list and, for GAMMA / lead-only
 *     refusals, the CLI path forward (the UI never confirms a deploy; leads are CLI-attested).
 *   - No platform-plural copy, no per-platform icon, no "HTTP 409" when reasons exist.
 *
 * lcars.js is a big browser file with top-level DOM calls, so, like the sibling suites, this slices
 * the DOM-free block between PROMOTE-MODAL-PURE-START/END and `executePromotion` out of the
 * source and evaluates only those. A missing anchor FAILS loudly.
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
const MODAL_BLOCK = slice('// PROMOTE MODAL (XACA-0026, redesigned', '// RELNOTES MODAL (XACA-0026)');

let failures = 0;
async function test(name, fn) {
    try { await fn(); console.log('ok - ' + name); } catch (err) {
        failures += 1;
        console.error('FAIL: ' + name + ': ' + (err && err.message));
    }
}

function pureSandbox() {
    const sb = { JSON, Array, Object, String, RegExp };
    vm.createContext(sb);
    vm.runInContext(PURE + '\nthis.api = {buildPromotePreviewModel, buildPromoteResultModel, promotePathForward, promotePlatformLabel};', sb);
    return sb.api;
}

function execSandbox(preview, responder) {
    const calls = [];
    const models = [];
    const el = { textContent: '', style: {} };
    const sb = {
        promoteModalState: { releaseId: 'REL-1', preview: preview, result: null },
        document: { getElementById: () => el },
        apiUrl: (p) => p,
        apiFetch: async (url, opts) => { calls.push({ url, body: JSON.parse(opts.body), opts }); return responder(calls.length); },
        displayPromotionResult: (m) => models.push(m),
        JSON, Array, Object, String, RegExp, Promise,
    };
    vm.createContext(sb);
    vm.runInContext(PURE + '\n' + EXEC + '\nthis.executePromotion = executePromotion;', sb);
    return { sb, calls, models };
}

const api = pureSandbox();
const release = (platforms) => ({ id: 'REL-1', name: 'R', platforms: platforms || { ios: {}, android: {} } });
const okResp = (body) => ({ ok: true, status: 200, json: async () => body });
const errResp = (status, body) => ({ ok: false, status, json: async () => body });

(async () => {
    // ── REVIEW step: one release-level preview from the server's dry run ─────────────────
    for (const row of [
        { name: 'CR off: preview names the server target', from: 'QA', to: 'ALPHA' },
        { name: 'CR on: preview names CR', from: 'BETA', to: 'CR' },
        { name: 'non-CR next after BETA is GAMMA', from: 'BETA', to: 'GAMMA' },
    ]) {
        await test('preview target == server target: ' + row.name, () => {
            const m = api.buildPromotePreviewModel(release(), { allowed: true, mode: 'report', from: row.from, to: row.to, next: row.to, reasons: [] });
            assert.strictEqual(m.from, row.from);
            assert.strictEqual(m.to, row.to);
            assert.strictEqual(m.canPromote, true);
            assert.deepStrictEqual(m.reasons, []);
        });
    }

    for (const row of [
        { to: 'PROD', warn: true, platforms: { ios: {} } },
        { to: 'PROD', warn: true, platforms: { ios: {}, android: {}, firebase: {} } },
        { to: 'QA', warn: false, platforms: { ios: {} } },
        { to: 'CR', warn: false, platforms: { ios: {} } },
    ]) {
        await test('PROD warning keyed on the TARGET (' + row.to + ', ' + Object.keys(row.platforms).length + ' platform(s) on the release)', () => {
            const m = api.buildPromotePreviewModel(release(row.platforms), { allowed: true, from: 'X', to: row.to, reasons: [] });
            assert.strictEqual(m.warnings.some(w => /PRODUCTION/.test(w)), row.warn);
        });
    }

    await test('platforms are read-only information with proper labels, not a selection', () => {
        const m = api.buildPromotePreviewModel(release({ ios: {}, android: {}, firebase: {}, web: {} }), { allowed: true, from: 'QA', to: 'ALPHA', reasons: [] });
        assert.strictEqual(m.platformsInfo, 'Platforms moving together: iOS, Android, Firebase, Web');
        assert.strictEqual(api.promotePlatformLabel('ios'), 'iOS');
        assert.ok(!('selected' in m));
    });

    await test('unmet conditions are listed (enforce refusal)', () => {
        const reasons = ['QA: test t2 missing', 'QA: test t3 FAIL', 'QA: waiver void'];
        const m = api.buildPromotePreviewModel(release(), { allowed: false, mode: 'enforce', from: 'QA', to: 'ALPHA', reasons });
        assert.strictEqual(m.canPromote, false);
        assert.deepStrictEqual(m.reasons, reasons);
        assert.ok(Array.isArray(m.reasons) && /refused/.test(m.reasonsHeading));
    });

    await test('report mode: reasons shown, promotion still allowed, heading says so', () => {
        const m = api.buildPromotePreviewModel(release(), { allowed: true, mode: 'report', from: 'QA', to: 'ALPHA', reasons: ['QA: test t2 missing'] });
        assert.strictEqual(m.canPromote, true);
        assert.deepStrictEqual(m.reasons, ['QA: test t2 missing']);
        assert.ok(/enforce mode/.test(m.reasonsHeading) && /report mode/.test(m.reasonsHeading));
    });

    await test('GAMMA preview: warning + explicit CLI path forward (the UI never confirms a deploy)', () => {
        const m = api.buildPromotePreviewModel(release(), { allowed: true, from: 'BETA', to: 'GAMMA', reasons: [] });
        assert.ok(m.warnings.some(w => /GAMMA/.test(w) && /lead/.test(w)));
        assert.strictEqual(m.pathForward,
            "GAMMA requires a release lead's deploy confirmation: run `kb-release promote REL-1 --confirm-deploy --actor <lead>`");
        assert.strictEqual(api.buildPromotePreviewModel(release(), { allowed: true, from: 'QA', to: 'ALPHA', reasons: [] }).pathForward, null);
    });

    await test('a failed preview (no target) cannot be promoted and says why', () => {
        const m = api.buildPromotePreviewModel(release(), { allowed: false, reasons: [], error: 'boom' });
        assert.strictEqual(m.canPromote, false);
        assert.strictEqual(m.to, null);
        assert.deepStrictEqual(Array.from(m.reasons), ['boom']);
        assert.strictEqual(api.buildPromotePreviewModel(release(), null).canPromote, false);
    });

    // ── RESULT step ──────────────────────────────────────────────────────────────────────
    await test('success result: title and toast name the release and stage, no platform copy', () => {
        const m = api.buildPromoteResultModel('REL-1', { from: 'QA', to: 'ALPHA' }, { ok: true, status: 200, data: { from: 'QA', to: 'ALPHA', reasons: [] } });
        assert.strictEqual(m.success, true);
        assert.strictEqual(m.title, 'Release promoted: QA → ALPHA');
        assert.strictEqual(m.toast, 'Release REL-1 promoted to ALPHA');
        assert.strictEqual(m.reasons.length, 0);
        assert.ok(!/platform/i.test(m.title + m.toast));
    });

    await test('report-mode success shows the reasons the gate would have refused', () => {
        const m = api.buildPromoteResultModel('REL-1', { from: 'QA', to: 'ALPHA' },
            { ok: true, status: 200, data: { from: 'QA', to: 'ALPHA', mode: 'report', reasons: ['QA: t2 missing', 'QA: t3 FAIL'] } });
        assert.strictEqual(m.reasonsHeading, 'Promoted; the gate would have refused in enforce mode:');
        assert.deepStrictEqual(m.reasons, ['QA: t2 missing', 'QA: t3 FAIL']);
    });

    await test("a stale preview's 409 is displayed as a list, not joined and not 'HTTP 409'", () => {
        const reasons = ['skipping refused: next enabled stage after QA is ALPHA, not BETA', 'QA: t2 missing', 'QA: t3 FAIL'];
        const m = api.buildPromoteResultModel('REL-1', { from: 'QA', to: 'BETA' },
            { ok: false, status: 409, data: { allowed: false, reasons, error: reasons[0] + ' (+2 more)' } });
        assert.strictEqual(m.success, false);
        assert.strictEqual(m.title, 'Promotion refused');
        assert.deepStrictEqual(m.reasons, reasons);
        assert.ok(!m.reasons.join('').includes('; '));
        assert.ok(!/HTTP 409/.test(JSON.stringify(m)));
        assert.ok(/^Promotion refused: skipping refused/.test(m.toast));
    });

    await test('lead-only refusal on a non-GAMMA target also gets the path forward', () => {
        const m = api.buildPromoteResultModel('REL-1', { from: 'QA', to: 'ALPHA' },
            { ok: false, status: 409, data: { reasons: ["only the release lead may grant a waiver"] } });
        assert.ok(/kb-release promote REL-1 --confirm-deploy --actor <lead>/.test(m.pathForward));
    });

    await test('GAMMA refusal carries the path forward; an ordinary refusal does not', () => {
        const g = api.buildPromoteResultModel('REL-9', { from: 'BETA', to: 'GAMMA' },
            { ok: false, status: 409, data: { reasons: ['GAMMA: lead must explicitly confirm the production deploy'] } });
        assert.ok(g.pathForward.includes('kb-release promote REL-9 --confirm-deploy --actor <lead>'));
        const o = api.buildPromoteResultModel('REL-9', { from: 'QA', to: 'ALPHA' },
            { ok: false, status: 409, data: { reasons: ['QA: t2 missing'] } });
        assert.strictEqual(o.pathForward, null);
    });

    await test('transport / empty-body failures fall back to error text, then HTTP status', () => {
        assert.deepStrictEqual(Array.from(api.buildPromoteResultModel('R', { to: 'A' }, { ok: false, status: 0, data: { error: 'boom' } }).reasons), ['boom']);
        assert.deepStrictEqual(Array.from(api.buildPromoteResultModel('R', { to: 'A' }, { ok: false, status: 500, data: {} }).reasons), ['HTTP 500']);
    });

    // ── executePromotion: exactly one request carrying the PREVIEWED targetStage ─────────
    for (const to of ['ALPHA', 'CR', 'GAMMA', 'PROD']) {
        await test('confirm sends exactly ONE request with targetStage == previewed stage (' + to + ')', async () => {
            const { sb, calls, models } = execSandbox({ from: 'X', to, allowed: true }, () => okResp({ from: 'X', to, reasons: [] }));
            await sb.executePromotion();
            assert.strictEqual(calls.length, 1, 'expected one request, got ' + calls.length);
            assert.strictEqual(calls[0].url, '/api/releases/REL-1/promote');
            assert.strictEqual(calls[0].opts.method, 'POST');
            assert.deepStrictEqual(Object.keys(calls[0].body).sort(), ['actor', 'confirmDeploy', 'targetStage']);
            assert.strictEqual(calls[0].body.targetStage, to);
            assert.strictEqual(calls[0].body.confirmDeploy, false);
            assert.strictEqual(calls[0].body.actor, 'lcars-ui');
            assert.strictEqual(models.length, 1);
            assert.strictEqual(models[0].to, to);   // preview target == POSTed targetStage == result label
        });
    }

    await test('a 409 from a stale preview is surfaced as a refusal result', async () => {
        const { sb, models } = execSandbox({ from: 'QA', to: 'ALPHA', allowed: true },
            () => errResp(409, { allowed: false, reasons: ['skipping refused: next enabled stage after ALPHA is BETA, not ALPHA'] }));
        await sb.executePromotion();
        assert.strictEqual(models[0].success, false);
        assert.ok(models[0].reasons[0].startsWith('skipping refused'));
    });

    await test('a network failure is reported once', async () => {
        const { sb, models, calls } = execSandbox({ from: 'QA', to: 'ALPHA', allowed: true }, () => { throw new Error('boom'); });
        await sb.executePromotion();
        assert.strictEqual(calls.length, 1);
        assert.deepStrictEqual(Array.from(models[0].reasons), ['boom']);
    });

    // ── copy: no platform-plural labels / per-platform icon left in the modal ────────────
    for (const bad of ['platform(s)', 'Promoting ${label}', '\u{1F525}', '\u{1F34E}', 'All promotions', 'selectedPlatforms', 'nextEnv']) {
        await test('modal source has no per-platform copy: ' + JSON.stringify(bad), () => {
            assert.ok(!MODAL_BLOCK.includes(bad), 'found ' + JSON.stringify(bad));
        });
    }

    if (failures) { process.exit(1); }
})();
