//
//  xaca-0990-001-lcars-terminal-card-characterization.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-0990-001: characterization baseline for isLcarsTerminal() and
 * createServiceOnlyLcarsCard(), captured BEFORE those two byte-identical
 * (md5 f8f39c4b8e953998cbc1cf3f6d5ba17b / 8589317f7526bceafe0406c52a3f77a5)
 * functions are extracted out of the 5 client app files into
 * fleet-monitor/server/public/shared/js/lcars-terminal-card.js. The parent
 * refactor (XACA-0990) must produce byte-identical BEHAVIOR before and
 * after -- this suite is the evidence for that claim, replayed against
 * whichever files exist post-refactor.
 *
 * ── Loading strategy (read this before touching the extraction) ──────────
 * Reuses tests/helpers/lcars-client-dom-stub.js's createDomStub() +
 * loadClientApp() -- the same vm.Context loader XACA-0983-013/014/015
 * already ships (see that file's own header comment for the full
 * rationale: no jsdom dependency in package.json, reads the REAL shipped
 * file off disk, appends a `window.__lcarsTestExports = {...}` line just
 * before the closing `})();`, runs it in a hand-rolled DOM stub).
 * `isLcarsTerminal` was added to that loader's export list as part of this
 * ticket -- an additive-only change to a test helper (not to any of the 5
 * production app files or their HTML pages). The existing
 * XACA-0983-013-014-015 suite was re-run after that edit: still 52/52.
 *
 * The actual matrix definitions + capture/serialize logic live in
 * tests/helpers/lcars-terminal-card-matrix.js, imported by BOTH this test
 * and tests/scripts/generate-xaca-0990-001-baseline.js -- one definition of
 * "what a case is and how it's captured", so the golden file and the
 * replay can never hand-drift apart.
 *
 * ── How to re-run / replay after the extraction ───────────────────────────
 *   cd fleet-monitor/server
 *   node --test tests/xaca-0990-001-lcars-terminal-card-characterization.test.js
 *
 * This recomputes the full matrix against whatever the 5 files (or their
 * post-refactor equivalents -- see CLIENT_FILES in the matrix helper, which
 * existence-filters against disk) actually do RIGHT NOW and diffs the
 * result, byte-for-byte on disk, against the checked-in golden file
 * tests/xaca-0990-001-lcars-terminal-card-baseline.json. A clean pass here
 * after the extraction is exactly the evidence the parent ticket needs.
 *
 * To regenerate the golden file after a PROVEN, INTENTIONAL behavior change
 * (never to make a failing test pass):
 *   node tests/scripts/generate-xaca-0990-001-baseline.js
 * then review the diff of that JSON file like any other code change before
 * committing it.
 *
 * ── Correctness posture ───────────────────────────────────────────────────
 * - Vacuity guards assert a positive, exact executed-case count (10 x 5 for
 *   isLcarsTerminal, 9 x 5 for createServiceOnlyLcarsCard) so a loader that
 *   silently resolves to zero files cannot report a reassuring green run.
 * - The primary comparison is a real on-disk byte diff (fs.writeFileSync
 *   the actual output, fs.readFileSync both files, string-compare) -- not
 *   solely an in-memory assert.deepStrictEqual that could be fooled by
 *   object identity/reference reuse.
 * - A permanent negative-control test (below) clones the parsed golden
 *   baseline, flips one leaf value, and asserts the comparison this suite
 *   uses actually detects that mutation -- proving the diff mechanism can
 *   fail, not just that it happens to pass today.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {
    CLIENT_FILES,
    ISLCARS_CASES,
    CARD_CASES,
    computeAllResults,
    stableStringify
} = require('./helpers/lcars-terminal-card-matrix.js');

const BASELINE_PATH = path.join(__dirname, 'xaca-0990-001-lcars-terminal-card-baseline.json');

test('harness sanity: CLIENT_FILES did not degrade to zero files', () => {
    // Same tap-mirroring existence-filter guard as XACA-0983-013/014/015:
    // 5/5 in dev-team, 4/4 in homebrew-tap (lcars-doublenode excluded).
    // Either way it must be nonzero or every loop below silently runs 0
    // iterations and reports a trivially green suite instead of a broken
    // PUBLIC_ROOT / file-existence assumption.
    assert.ok(CLIENT_FILES.length > 0, 'CLIENT_FILES resolved to zero files');
    assert.ok(CLIENT_FILES.length <= 5, 'CLIENT_FILES somehow exceeds the known 5-file universe');
});

test('harness sanity: input matrices are the sizes this suite claims to cover', () => {
    assert.equal(ISLCARS_CASES.length, 10, 'isLcarsTerminal matrix must have exactly 10 cases');
    assert.equal(CARD_CASES.length, 9, 'createServiceOnlyLcarsCard matrix must have exactly 9 cases');
});

// Computed once for the whole suite -- re-used by the count guard, the
// cross-file identity check, and the golden-file diff below.
const ACTUAL_RESULTS = computeAllResults();
const ACTUAL_JSON = stableStringify(ACTUAL_RESULTS);

test('executed-case count is positive and matches the expected matrix size exactly', () => {
    const perFileExpected = ISLCARS_CASES.length + CARD_CASES.length; // 19
    const expectedTotal = perFileExpected * CLIENT_FILES.length;

    let executedTotal = 0;
    for (const relPath of CLIENT_FILES) {
        const perFile = ACTUAL_RESULTS[relPath];
        assert.ok(perFile, 'missing results for ' + relPath);
        const isLcarsCount = Object.keys(perFile.isLcarsTerminal).length;
        const cardCount = Object.keys(perFile.createServiceOnlyLcarsCard).length;
        assert.equal(isLcarsCount, ISLCARS_CASES.length, relPath + ': isLcarsTerminal case count mismatch');
        assert.equal(cardCount, CARD_CASES.length, relPath + ': createServiceOnlyLcarsCard case count mismatch');
        executedTotal += isLcarsCount + cardCount;
    }

    console.log(
        'XACA-0990-001: executed ' + executedTotal + ' cases across ' + CLIENT_FILES.length + ' files ' +
        '(expected ' + expectedTotal + ')'
    );
    assert.ok(executedTotal > 0, 'executed case count must be positive');
    assert.equal(executedTotal, expectedTotal, 'executed case count must equal the expected matrix size exactly');
});

test('all 5 client files produce IDENTICAL isLcarsTerminal + createServiceOnlyLcarsCard output', () => {
    // This is the load-bearing assertion for the refactor premise: if any
    // file differs here, the "byte-identical across 5 files" premise the
    // extraction plan depends on is WRONG and the refactor must not proceed
    // as currently scoped. Report the exact failing case, not just "some
    // file differs somewhere".
    const [referencePath, ...restPaths] = CLIENT_FILES;
    const reference = ACTUAL_RESULTS[referencePath];

    for (const relPath of restPaths) {
        const candidate = ACTUAL_RESULTS[relPath];

        for (const caseId of Object.keys(reference.isLcarsTerminal)) {
            assert.deepStrictEqual(
                candidate.isLcarsTerminal[caseId],
                reference.isLcarsTerminal[caseId],
                'DIVERGENCE: isLcarsTerminal case "' + caseId + '" differs between ' +
                    referencePath + ' and ' + relPath + ' -- the byte-identical premise is WRONG for this case.'
            );
        }
        for (const caseId of Object.keys(reference.createServiceOnlyLcarsCard)) {
            assert.deepStrictEqual(
                candidate.createServiceOnlyLcarsCard[caseId],
                reference.createServiceOnlyLcarsCard[caseId],
                'DIVERGENCE: createServiceOnlyLcarsCard case "' + caseId + '" differs between ' +
                    referencePath + ' and ' + relPath + ' -- the byte-identical premise is WRONG for this case.'
            );
        }
    }
});

test('actual output matches the checked-in golden baseline byte-for-byte on disk', () => {
    assert.ok(
        fs.existsSync(BASELINE_PATH),
        'golden baseline missing at ' + BASELINE_PATH + ' -- run node tests/scripts/generate-xaca-0990-001-baseline.js'
    );

    // Round-trip the "actual" output through a real temp file before
    // comparing, rather than trusting an in-memory string/object -- so this
    // assertion cannot be fooled by accidental shared references between
    // the computed value and the loaded baseline.
    const actualTmpPath = path.join(os.tmpdir(), 'xaca-0990-001-actual-' + process.pid + '.json');
    fs.writeFileSync(actualTmpPath, ACTUAL_JSON, 'utf8');

    const actualOnDisk = fs.readFileSync(actualTmpPath, 'utf8');
    const goldenOnDisk = fs.readFileSync(BASELINE_PATH, 'utf8');

    fs.rmSync(actualTmpPath, { force: true });

    if (actualOnDisk !== goldenOnDisk) {
        const actualLines = actualOnDisk.split('\n');
        const goldenLines = goldenOnDisk.split('\n');
        let firstDiffLine = -1;
        const maxLines = Math.max(actualLines.length, goldenLines.length);
        for (let i = 0; i < maxLines; i++) {
            if (actualLines[i] !== goldenLines[i]) {
                firstDiffLine = i + 1;
                break;
            }
        }
        assert.fail(
            'actual output diverges from golden baseline at line ' + firstDiffLine + '\n' +
            '  actual: ' + JSON.stringify(actualLines[firstDiffLine - 1]) + '\n' +
            '  golden: ' + JSON.stringify(goldenLines[firstDiffLine - 1])
        );
    }

    assert.equal(actualOnDisk, goldenOnDisk);
});

test('negative control: a mutated golden baseline is detected as a real divergence', () => {
    // Permanent regression-proof for the diff mechanism above: clone the
    // parsed golden baseline, flip one deeply-nested leaf value, and
    // confirm the SAME string-diff style comparison used above actually
    // fails on it. This is the harness's own "can this check ever go red"
    // proof -- a malformed check that always reports the reassuring result
    // would pass the tests above vacuously; this test would catch that.
    const golden = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
    const referencePath = CLIENT_FILES[0];

    const mutated = JSON.parse(JSON.stringify(golden));
    mutated[referencePath].isLcarsTerminal.null_teamData = !mutated[referencePath].isLcarsTerminal.null_teamData;

    const mutatedJson = stableStringify(mutated);
    const goldenJson = stableStringify(golden);

    assert.notEqual(
        mutatedJson,
        goldenJson,
        'sanity: mutating null_teamData must actually change the serialized output'
    );

    // The real diff mechanism the suite relies on: assert.deepStrictEqual
    // against the (correct) ACTUAL_RESULTS must now throw, because
    // `mutated` no longer matches reality.
    assert.throws(
        () => {
            assert.deepStrictEqual(mutated[referencePath], ACTUAL_RESULTS[referencePath]);
        },
        (err) => err instanceof assert.AssertionError,
        'expected the mutated baseline to fail comparison against the real actual results'
    );

    console.log('XACA-0990-001 negative control: mutated null_teamData boolean -- comparison correctly FAILED as expected.');
});
