#!/usr/bin/env node
//
//  test-xaca-1375-promote-cr-notes.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 DoubleNode.com. All rights reserved.
//

/**
 * XACA-1375-014/015/016 (PR #1007 gate round 1), promote modal view models.
 *   014  informational codes (CR_SUPPORT_DISABLED) render under a neutral "Note:" heading and NEVER as
 *        "the gate would refuse" text or a warning toast.
 *   015  `strandedInCR` -> a badge (release card + modal header, existing .archived-badge look);
 *        `configWarning` -> the modal's WARNINGS block.
 *   016  the up-front lead-confirmation warning follows the server's `confirmStage` (GAMMA, or PROD when
 *        the team has no GAMMA), not a hardcoded GAMMA.
 *
 * Like the sibling suites, this slices the DOM-free block out of lcars.js.
 *
 * Run: node lcars-ui/tests/test-xaca-1375-promote-cr-notes.js
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
const MODAL_BLOCK = slice('// PROMOTE MODAL (XACA-0026, redesigned', '// RELNOTES MODAL (XACA-0026)');

let failures = 0;
async function test(name, fn) {
    try { await fn(); console.log('ok - ' + name); } catch (err) {
        failures += 1;
        console.error('FAIL: ' + name + ': ' + (err && err.message));
    }
}

const sb = { JSON, Array, Object, String, RegExp, Set, Map };
vm.createContext(sb);
vm.runInContext(PURE + '\nthis.api = {buildPromotePreviewModel, buildPromoteResultModel, promoteSplitReasons, ' +
    'promoteStrandedBadgeHtml, PROMOTE_NOTES_HEADING};', sb);
const api = sb.api;

const NOTE = 'CR support disabled';
const release = { id: 'REL-1', name: 'R', platforms: { ios: { version: '1.0.0', buildNumber: 1 } } };
const NEUTRAL = 'Note: CR support is off; this release can only leave CR';
const REFUSE_TEXT = /would refuse|would have refused|refused/i;

(async () => {
    // ── 014 ───────────────────────────────────────────────────────────────────────────────
    await test('neutral heading text is exactly the approved wording', () => {
        assert.strictEqual(api.PROMOTE_NOTES_HEADING, NEUTRAL);
    });

    for (const mode of ['report', 'enforce']) {
        await test('preview, stranded CR, ' + mode + ': the note is a NOTE, with no refusal text', () => {
            const m = api.buildPromotePreviewModel(release, {
                allowed: true, mode, from: 'CR', to: 'GAMMA', confirmStage: 'GAMMA',
                reasons: [NOTE], reasonCodes: ['CR_SUPPORT_DISABLED'], reasonData: [{ stage: 'CR' }]
            });
            assert.strictEqual(m.canPromote, true);
            assert.deepStrictEqual(Array.from(m.notes), [NOTE]);
            assert.strictEqual(m.notesHeading, NEUTRAL);
            assert.strictEqual(m.reasonsHeading, null, 'no "would refuse" heading');
            assert.strictEqual(m.reasonItems.length, 0);
            assert.strictEqual(m.reasons.length, 0);
            assert.ok(!REFUSE_TEXT.test(JSON.stringify([m.notesHeading, m.reasonsHeading, m.warnings])));
        });
    }

    await test('preview: a real blocking reason next to the note keeps its refusal wording; the note stays out of it', () => {
        const m = api.buildPromotePreviewModel(release, {
            allowed: false, mode: 'enforce', from: 'CR', to: 'GAMMA', confirmStage: 'GAMMA',
            reasons: [NOTE, 'GAMMA: lead must explicitly confirm the production deploy'],
            reasonCodes: ['CR_SUPPORT_DISABLED', 'GAMMA_CONFIRM_REQUIRED'],
            reasonData: [{ stage: 'CR' }, { stage: 'GAMMA' }]
        });
        assert.strictEqual(m.reasonsHeading, 'This promotion is refused:');
        assert.deepStrictEqual(Array.from(m.reasons), ['GAMMA: lead must explicitly confirm the production deploy']);
        assert.strictEqual(m.reasonItems.length, 1);
        assert.deepStrictEqual(Array.from(m.notes), [NOTE]);
        assert.ok(m.reasonItems[0].remedy && /--to 'GAMMA'|--to GAMMA/.test(m.reasonItems[0].remedy.command));
    });

    await test('result (success): note only -> no warning-toast trigger, no "would have refused" heading', () => {
        const r = api.buildPromoteResultModel('REL-1', { from: 'CR', to: 'GAMMA' }, {
            ok: true, status: 200,
            data: { from: 'CR', to: 'GAMMA', mode: 'enforce', reasons: [NOTE], reasonCodes: ['CR_SUPPORT_DISABLED'], reasonData: [{ stage: 'CR' }] }
        });
        assert.strictEqual(r.success, true);
        assert.strictEqual(r.reasons.length, 0, 'displayPromotionResult warns only when reasons.length > 0');
        assert.strictEqual(r.reasonsHeading, null);
        assert.strictEqual(r.reasonItems.length, 0);
        assert.deepStrictEqual(Array.from(r.notes), [NOTE]);
        assert.strictEqual(r.notesHeading, NEUTRAL);
        assert.ok(!REFUSE_TEXT.test(r.title + r.toast));
    });

    await test('result (success): a REAL report-mode refusal reason still warns, the note does not join it', () => {
        const r = api.buildPromoteResultModel('REL-1', null, {
            ok: true, status: 200,
            data: { from: 'QA', to: 'GAMMA', reasons: ['QA: t1 missing', NOTE], reasonCodes: ['TEST_MISSING', 'CR_SUPPORT_DISABLED'], reasonData: [null, null] }
        });
        assert.deepStrictEqual(Array.from(r.reasons), ['QA: t1 missing']);
        assert.strictEqual(r.reasonsHeading, 'Promoted; the gate would have refused in enforce mode:');
    });

    await test('result (refused): note + a real reason -> reasons are only the real one', () => {
        const r = api.buildPromoteResultModel('REL-1', { from: 'CR', to: 'GAMMA' }, {
            ok: false, status: 409,
            data: { reasons: [NOTE, 'GAMMA: lead must explicitly confirm the production deploy'],
                    reasonCodes: ['CR_SUPPORT_DISABLED', 'GAMMA_CONFIRM_REQUIRED'], reasonData: [null, { stage: 'GAMMA' }] }
        });
        assert.strictEqual(r.success, false);
        assert.deepStrictEqual(Array.from(r.reasons), ['GAMMA: lead must explicitly confirm the production deploy']);
        assert.ok(/^Promotion refused: GAMMA/.test(r.toast));
        assert.deepStrictEqual(Array.from(r.notes), [NOTE]);
    });

    await test('result (refused) with ONLY a note still reports something, never an empty refusal', () => {
        const r = api.buildPromoteResultModel('REL-1', null, {
            ok: false, status: 409,
            data: { reasons: [NOTE], reasonCodes: ['CR_SUPPORT_DISABLED'], reasonData: [null], error: NOTE }
        });
        assert.ok(r.reasons.length === 1 && r.reasonItems.length === 1);
    });

    await test('promoteSplitReasons tolerates missing/malformed arrays', () => {
        for (const bad of [null, undefined, {}, { reasons: 'x' }, { reasons: ['a'] }]) {
            const s = api.promoteSplitReasons(bad);
            assert.ok(Array.isArray(s.blocking.reasons) && Array.isArray(s.notes));
        }
        assert.deepStrictEqual(Array.from(api.promoteSplitReasons({ reasons: ['a'] }).blocking.reasonCodes), ['other']);
    });

    // ── 020 ───────────────────────────────────────────────────────────────────────────────
    await test('020: refused with ONLY a note: the refusal line and toast use data.error, the note stays a note', () => {
        const r = api.buildPromoteResultModel('REL-1', null, {
            ok: false, status: 409,
            data: { reasons: [NOTE], reasonCodes: ['CR_SUPPORT_DISABLED'], reasonData: [null], error: 'board write refused' }
        });
        assert.deepStrictEqual(Array.from(r.reasons), ['board write refused']);
        assert.strictEqual(r.toast, 'Promotion refused: board write refused');
        assert.deepStrictEqual(Array.from(r.notes), [NOTE]);
        assert.ok(!Array.from(r.reasons).includes(NOTE));
    });

    await test('020: only a note and an error that merely ECHOES the note -> "HTTP <status>", never the note', () => {
        const r = api.buildPromoteResultModel('REL-1', null, {
            ok: false, status: 409,
            data: { reasons: [NOTE], reasonCodes: ['CR_SUPPORT_DISABLED'], reasonData: [null], error: NOTE }
        });
        assert.deepStrictEqual(Array.from(r.reasons), ['HTTP 409']);
        assert.strictEqual(r.toast, 'Promotion refused: HTTP 409');
        assert.deepStrictEqual(Array.from(r.notes), [NOTE]);
        assert.ok(!r.reasonItems.some(i => i.text === NOTE));
    });

    await test('020: only a note and no error at all -> "HTTP <status>"', () => {
        const r = api.buildPromoteResultModel('REL-1', null, {
            ok: false, status: 500, data: { reasons: [NOTE], reasonCodes: ['CR_SUPPORT_DISABLED'], reasonData: [null] }
        });
        assert.deepStrictEqual(Array.from(r.reasons), ['HTTP 500']);
    });

    // ── 021 ───────────────────────────────────────────────────────────────────────────────
    const css = fs.readFileSync(path.join(__dirname, '..', 'css', 'lcars.css'), 'utf8');
    const rule = (/\.archived-badge\.release-stranded-badge\s*\{([^}]*)\}/.exec(css) || [])[1] || '';
    const token = (name) => (new RegExp('--' + name + ':\\s*(#[0-9a-fA-F]{6})').exec(css) || [])[1];
    const lum = (hex) => {
        const c = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255)
            .map(v => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)));
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
    };
    const contrast = (a, b) => { const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x); return (hi + 0.05) / (lo + 0.05); };

    await test('021: the stranded badge has its own LCARS orange style via existing tokens', () => {
        assert.ok(rule, 'rule .archived-badge.release-stranded-badge exists');
        assert.ok(/background:\s*var\(--lcars-orange/.test(rule) && /color:\s*var\(--lcars-black/.test(rule));
    });

    await test('021: text/background contrast is at least 4.5:1 and differs from the gray ARCHIVED badge', () => {
        const bg = token('lcars-orange'), fg = token('lcars-black');
        assert.ok(bg && fg, 'tokens resolve');
        assert.ok(contrast(bg, fg) >= 4.5, 'contrast ' + contrast(bg, fg).toFixed(2));
        assert.notStrictEqual(bg.toLowerCase(), '#666666');
    });

    await test('021: the visible text carries the whole meaning without the tooltip', () => {
        const h = api.promoteStrandedBadgeHtml({ strandedInCR: true });
        const visible = h.replace(/<[^>]*>/g, '');
        assert.ok(/STRANDED IN CR/.test(visible) && /CR OFF/.test(visible) && /LEAVE/.test(visible), visible);
    });

    // ── MANDATORY_STAGE_SKIPPED is a REFUSAL, never a note ────────────────────────────────
    const SKIP = 'mandatory stage CR skipped: next enabled stage after QA is CR, not GAMMA';
    await test('MANDATORY_STAGE_SKIPPED renders as a refusal in the preview (not under the Note heading)', () => {
        const m = api.buildPromotePreviewModel(release, {
            allowed: false, mode: 'report', from: 'QA', to: 'GAMMA', confirmStage: 'GAMMA',
            reasons: [SKIP], reasonCodes: ['MANDATORY_STAGE_SKIPPED'], reasonData: [{ stage: 'CR', skipped: ['CR'] }]
        });
        assert.strictEqual(m.canPromote, false);
        assert.strictEqual(m.reasonsHeading, 'This promotion is refused:');
        assert.deepStrictEqual(Array.from(m.reasons), [SKIP]);
        assert.strictEqual(m.notes.length, 0);
        assert.strictEqual(m.notesHeading, null);
    });

    await test('MANDATORY_STAGE_SKIPPED renders as a refusal in the result (409), with its text in the toast', () => {
        const r = api.buildPromoteResultModel('REL-1', { from: 'QA', to: 'GAMMA' }, {
            ok: false, status: 409,
            data: { reasons: [SKIP], reasonCodes: ['MANDATORY_STAGE_SKIPPED'], reasonData: [{ stage: 'CR' }], error: SKIP }
        });
        assert.strictEqual(r.success, false);
        assert.deepStrictEqual(Array.from(r.reasons), [SKIP]);
        assert.strictEqual(r.notes.length, 0);
        assert.strictEqual(r.toast, 'Promotion refused: ' + SKIP);
    });

    // ── 015 ───────────────────────────────────────────────────────────────────────────────
    await test('stranded badge: shown only for strandedInCR === true, static markup, existing badge class', () => {
        const h = api.promoteStrandedBadgeHtml({ strandedInCR: true });
        assert.ok(/class="archived-badge release-stranded-badge"/.test(h) && /STRANDED IN CR/.test(h));
        for (const r of [{ strandedInCR: false }, {}, null, undefined, { strandedInCR: 'true' }]) {
            assert.strictEqual(api.promoteStrandedBadgeHtml(r), '');
        }
    });

    await test('badge is wired into the release card and the promote modal header; notes are rendered', () => {
        assert.ok(/promoteStrandedBadgeHtml\(release\)/.test(source.slice(source.indexOf('function renderReleaseCard('))));
        assert.ok(/\$\{promoteStrandedBadgeHtml\(release\)\}/.test(MODAL_BLOCK));
        assert.ok(/m\.notesHeading/.test(MODAL_BLOCK) && /model\.notesHeading/.test(MODAL_BLOCK));
    });

    await test('configWarning lands in the preview WARNINGS block', () => {
        const w = 'flowConfig.stages.CR is still enabled but teamConfig.crSupport.enabled is not true';
        const m = api.buildPromotePreviewModel(release, { allowed: true, from: 'QA', to: 'GAMMA', configWarning: w, reasons: [] });
        assert.ok(Array.from(m.warnings).indexOf(w) !== -1);
        const none = api.buildPromotePreviewModel(release, { allowed: true, from: 'QA', to: 'GAMMA', reasons: [] });
        assert.ok(!Array.from(none.warnings).some(x => /flowConfig/.test(x)));
        for (const bad of [null, 42, '']) {
            const x = api.buildPromotePreviewModel(release, { allowed: true, from: 'QA', to: 'GAMMA', configWarning: bad, reasons: [] });
            assert.ok(!Array.from(x.warnings).some(y => y === bad && bad !== ''));
        }
    });

    await test('the refused-dry-run fallback preview carries configWarning/confirmStage through', () => {
        assert.ok(/configWarning: data\.configWarning, confirmStage: data\.confirmStage/.test(source));
    });

    // ── 016 ───────────────────────────────────────────────────────────────────────────────
    const warnFor = (to, confirmStage) => Array.from(api.buildPromotePreviewModel(release,
        { allowed: true, from: 'QA', to, confirmStage, reasons: [] }).warnings);

    await test('GAMMA team: GAMMA entry warns up front; PROD entry does not ask for a confirmation', () => {
        assert.ok(warnFor('GAMMA', 'GAMMA').some(x => /GAMMA is live in production: the release lead must confirm/.test(x)));
        assert.ok(!warnFor('PROD', 'GAMMA').some(x => /must confirm/.test(x)));
    });

    await test('no-GAMMA team: PROD entry warns up front (and still carries the PRODUCTION warning)', () => {
        const w = warnFor('PROD', 'PROD');
        assert.ok(w.some(x => /PROD is production: the release lead must confirm the deploy/.test(x)));
        assert.ok(w.some(x => /promotes the release to PRODUCTION/.test(x)));
        assert.ok(!w.some(x => /GAMMA/.test(x)));
    });

    await test('older server without confirmStage: falls back to GAMMA', () => {
        assert.ok(warnFor('GAMMA', undefined).some(x => /GAMMA is live in production/.test(x)));
    });

    await test('no confirmation warning for stages that are not the confirm stage', () => {
        assert.ok(!warnFor('QA', 'GAMMA').some(x => /must confirm/.test(x)));
        assert.ok(!warnFor('CR', 'PROD').some(x => /must confirm/.test(x)));
    });

    if (failures) { process.exit(1); }
})();
