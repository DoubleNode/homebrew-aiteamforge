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
 * This recomputes the full matrix against whatever files actually exist in
 * THIS checkout right now (see CLIENT_FILES in the matrix helper, which
 * existence-filters against disk -- 5 files in dev-team, 3 in the
 * homebrew-tap mirror; see identifyKnownFileSet()'s doc comment there) and
 * diffs the result, byte-for-byte on disk, against the golden-entries
 * subset of the checked-in golden file
 * tests/xaca-0990-001-lcars-terminal-card-baseline.json that corresponds to
 * those files. A clean pass here after the extraction is exactly the
 * evidence the parent ticket needs, in EITHER repo.
 *
 * To regenerate the golden file after a PROVEN, INTENTIONAL behavior change
 * (never to make a failing test pass):
 *   node tests/scripts/generate-xaca-0990-001-baseline.js
 * then review the diff of that JSON file like any other code change before
 * committing it.
 *
 * ── Correctness posture ───────────────────────────────────────────────────
 * - The discovered CLIENT_FILES set is itself an assertion (harness sanity
 *   test below, via identifyKnownFileSet()): it must equal EXACTLY one of
 *   two known-good sets -- the full 5 (dev-team) or the specific 3 (tap,
 *   XACA-0139 excludes doublenode + mainevent). Any other set -- including
 *   an accidental shrink in dev-team, or a tap mirror gaining/losing a file
 *   -- fails loudly, naming what's missing/unexpected, rather than silently
 *   adapting to whatever happens to exist on disk.
 * - Every discovered file must have a corresponding entry in the golden
 *   baseline (harness sanity test below) -- a discovered file absent from
 *   the golden is a failure, not a skip.
 * - Vacuity guards assert a positive, exact executed-case count (10 x N for
 *   isLcarsTerminal, 9 x N for createServiceOnlyLcarsCard, N being the
 *   INDEPENDENTLY known size of whichever known-good set matched -- NOT
 *   derived from CLIENT_FILES.length itself, which is the value being
 *   verified) so a loader that silently resolves to zero (or the wrong
 *   nonzero number of) files cannot report a reassuring green run.
 * - The primary comparison is a real on-disk byte diff (fs.writeFileSync
 *   the actual output, fs.readFileSync both files, string-compare) of the
 *   golden baseline RESTRICTED to the entries for files that actually exist
 *   here -- not the whole 5-key golden object, which would always fail in
 *   the tap's 3-file checkout -- and not solely an in-memory
 *   assert.deepStrictEqual that could be fooled by object identity/
 *   reference reuse.
 * - A permanent negative-control test (below) clones the parsed golden
 *   baseline, flips one leaf value, and asserts the comparison this suite
 *   uses actually detects that mutation -- proving the diff mechanism can
 *   fail, not just that it happens to pass today.
 * - createServiceOnlyLcarsCard's escapeHtml-must-be-a-function TypeError
 *   guard is a genuinely NEW logic path introduced by this refactor (it did
 *   not exist in any of the 5 original copies -- see
 *   lcars-terminal-card.js's own doc comment). It is therefore tested
 *   SEPARATELY, below, outside the matrix/golden-diff machinery entirely --
 *   adding it to the matrix would require regenerating the pre-refactor
 *   golden baseline, which would destroy the baseline's entire reason for
 *   existing.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const {
    CLIENT_FILES,
    KNOWN_GOOD_FILE_SETS,
    identifyKnownFileSet,
    ISLCARS_CASES,
    CARD_CASES,
    computeAllResults,
    stableStringify
} = require('./helpers/lcars-terminal-card-matrix.js');
const { createDomStub, loadSharedTerminalCardModule } = require('./helpers/lcars-client-dom-stub.js');

const BASELINE_PATH = path.join(__dirname, 'xaca-0990-001-lcars-terminal-card-baseline.json');

// Computed once, up front, so every test below (including the vacuity
// guard's expected-count math) shares the SAME verdict on which known-good
// set was discovered -- never re-derived per test in a way that could
// silently diverge.
let MATCHED_FILE_SET = null;
let MATCHED_FILE_SET_ERROR = null;
try {
    MATCHED_FILE_SET = identifyKnownFileSet(CLIENT_FILES);
} catch (err) {
    MATCHED_FILE_SET_ERROR = err;
}

test('harness sanity: CLIENT_FILES matches exactly one known-good file set', () => {
    // This is the fix for XACA-0990 gate finding 1: the old version of this
    // suite only checked CLIENT_FILES.length > 0, which is satisfied by
    // ANY nonzero existence-filter result -- including the tap's 3-file
    // reality, which then went on to fail the whole-object byte diff
    // against a 5-key golden file, AND would equally have satisfied an
    // accidental 5->4 shrink in dev-team. identifyKnownFileSet() makes the
    // file SET itself the assertion: it must equal one of exactly two
    // literal, hardcoded arrays (KNOWN_GOOD_FILE_SETS), or this throws,
    // naming exactly what was missing / unexpected.
    if (MATCHED_FILE_SET_ERROR) {
        assert.fail(MATCHED_FILE_SET_ERROR.message);
    }
    assert.ok(MATCHED_FILE_SET, 'CLIENT_FILES must resolve to a known-good set');
    console.log(
        'XACA-0990-001: discovered file set matches "' + MATCHED_FILE_SET.label + '" ' +
        '(' + MATCHED_FILE_SET.files.length + ' files)'
    );
});

test('harness sanity: every discovered file has a corresponding golden baseline entry', () => {
    // Explicit, not merely implied by the fact that CLIENT_FILES is a
    // subset of ALL_CLIENT_FILES and the golden covers all 5: a discovered
    // file absent from the golden must fail here, not silently pass
    // through a golden-subset comparison that only ever looks at keys the
    // golden happens to have.
    assert.ok(
        fs.existsSync(BASELINE_PATH),
        'golden baseline missing at ' + BASELINE_PATH + ' -- run node tests/scripts/generate-xaca-0990-001-baseline.js'
    );
    const golden = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
    for (const relPath of CLIENT_FILES) {
        assert.ok(
            Object.prototype.hasOwnProperty.call(golden, relPath),
            'discovered file "' + relPath + '" has no corresponding entry in the golden baseline -- ' +
                'the golden file must cover every file this suite can ever discover on disk.'
        );
    }
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
    assert.ok(
        MATCHED_FILE_SET,
        'file set must resolve to a known-good set before an expected count can be computed ' +
            '(see the "CLIENT_FILES matches exactly one known-good file set" test above)'
    );

    const perFileExpected = ISLCARS_CASES.length + CARD_CASES.length; // 19
    // XACA-0990 gate finding 2 fix: the previous version computed
    // `expectedTotal = perFileExpected * CLIENT_FILES.length` -- i.e. it
    // derived the number it was checking FROM the very value being
    // checked, so it held true at any nonzero CLIENT_FILES length and could
    // never detect a shrink. MATCHED_FILE_SET.files.length instead comes
    // from a hardcoded literal array in KNOWN_GOOD_FILE_SETS -- a number
    // fixed in source, independent of what CLIENT_FILES resolved to at
    // runtime -- so a discovered set that is merely "a nonzero subset" but
    // NOT one of the two known-good shapes fails one test earlier (the
    // harness-sanity test above), and even if it somehow got here with the
    // wrong count, this multiplication no longer self-satisfies.
    const expectedTotal = perFileExpected * MATCHED_FILE_SET.files.length;

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
        '(expected ' + expectedTotal + ', file set "' + MATCHED_FILE_SET.label + '")'
    );
    assert.ok(executedTotal > 0, 'executed case count must be positive');
    assert.equal(executedTotal, expectedTotal, 'executed case count must equal the expected matrix size exactly');
});

test('all client files produce IDENTICAL isLcarsTerminal + createServiceOnlyLcarsCard output', () => {
    // This is the load-bearing assertion for the refactor premise: if any
    // file differs here, the "byte-identical across files" premise the
    // extraction plan depends on is WRONG and the refactor must not proceed
    // as currently scoped. Report the exact failing case, not just "some
    // file differs somewhere". Runs across whatever CLIENT_FILES resolved
    // to (already proven to be one of the two known-good sets above).
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

test('actual output matches the checked-in golden baseline byte-for-byte, restricted to files present here', () => {
    assert.ok(
        fs.existsSync(BASELINE_PATH),
        'golden baseline missing at ' + BASELINE_PATH + ' -- run node tests/scripts/generate-xaca-0990-001-baseline.js'
    );

    // XACA-0990 gate finding 1 fix: compare only the golden entries for
    // files that actually exist in THIS checkout. Comparing the full
    // 5-key golden object here would always fail in the tap, where only 3
    // of the 5 app files are mirrored (XACA-0139 debranding) -- the golden
    // file itself must stay the untouched pre-refactor artifact (never
    // regenerated to make this narrower comparison pass). This restriction
    // can never mask an accidental shrink: the file SET itself was already
    // asserted, above, to be one of exactly two known-good shapes, and
    // every discovered file was already asserted to have a golden entry --
    // this test only narrows WHICH already-validated entries get diffed.
    const golden = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
    const goldenSubset = {};
    for (const relPath of CLIENT_FILES) {
        goldenSubset[relPath] = golden[relPath];
    }
    const goldenSubsetJson = stableStringify(goldenSubset);

    // Round-trip BOTH sides through real temp files before comparing,
    // rather than trusting in-memory strings/objects -- so this assertion
    // cannot be fooled by accidental shared references between the
    // computed value and the loaded baseline.
    const actualTmpPath = path.join(os.tmpdir(), 'xaca-0990-001-actual-' + process.pid + '.json');
    const goldenTmpPath = path.join(os.tmpdir(), 'xaca-0990-001-golden-subset-' + process.pid + '.json');
    fs.writeFileSync(actualTmpPath, ACTUAL_JSON, 'utf8');
    fs.writeFileSync(goldenTmpPath, goldenSubsetJson, 'utf8');

    const actualOnDisk = fs.readFileSync(actualTmpPath, 'utf8');
    const goldenOnDisk = fs.readFileSync(goldenTmpPath, 'utf8');

    fs.rmSync(actualTmpPath, { force: true });
    fs.rmSync(goldenTmpPath, { force: true });

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
            'actual output diverges from golden baseline (subset for ' + CLIENT_FILES.length +
            ' discovered file(s)) at line ' + firstDiffLine + '\n' +
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

test('negative control: an unknown discovered file set is rejected loudly by identifyKnownFileSet', () => {
    // Proves identifyKnownFileSet() itself can fail, not just that it
    // happens to succeed today -- mirrors the golden-mutation negative
    // control above, but for the file-set guard (XACA-0990 gate finding 1).
    assert.throws(
        () => identifyKnownFileSet(['lcars2/js/lcars-academy-app.js']),
        (err) => err instanceof Error && /matches NEITHER known-good/.test(err.message),
        'a 1-file set (neither the 5-file nor the 3-file known-good set) must be rejected'
    );
    assert.throws(
        () => identifyKnownFileSet([...KNOWN_GOOD_FILE_SETS['dev-team (5 files)'], 'lcars2/js/unexpected-app.js']),
        (err) => err instanceof Error && /matches NEITHER known-good/.test(err.message),
        'the 5-file set PLUS one unexpected extra file must be rejected'
    );
});

// ============================================================================
// XACA-0990 gate finding 5: createServiceOnlyLcarsCard's escapeHtml-must-be-
// a-function TypeError guard is a genuinely NEW logic path (it did not exist
// pre-refactor -- see lcars-terminal-card.js's own doc comment), so it must
// NOT be added to the characterization matrix/golden-diff machinery above --
// doing so would force a baseline regeneration and destroy the
// characterization suite's entire correctness argument. It is exercised
// here instead, as an independent, separate test against the shared module
// directly (not through any of the 5 client-app shims).
// ============================================================================

test('LCARS_TERMINAL_CARD.createServiceOnlyLcarsCard rejects a non-function escapeHtml with TypeError', () => {
    const { ctx } = createDomStub();
    vm.createContext(ctx);
    loadSharedTerminalCardModule(ctx);

    const svc = { reachable: true, hostname: 'runabout.example.com', port: 8080 };
    const originalCreateElement = ctx.document.createElement;

    // Covers: escapeHtml omitted entirely, explicit null, and a non-function
    // value (a string) -- the three cases the ticket calls out by name.
    const badEscapeHtmlCases = [
        { label: 'omitted', args: ['academy', svc] },
        { label: 'null', args: ['academy', svc, null] },
        { label: 'non-function (string)', args: ['academy', svc, 'not-a-function'] }
    ];

    for (const { label, args } of badEscapeHtmlCases) {
        let createElementCalls = 0;
        ctx.document.createElement = function (...callArgs) {
            createElementCalls += 1;
            return originalCreateElement.apply(this, callArgs);
        };

        try {
            assert.throws(
                () => {
                    ctx.window.LCARS_TERMINAL_CARD.createServiceOnlyLcarsCard(...args);
                },
                // NOTE: the shared module runs inside a vm.createContext()
                // realm (see lcars-client-dom-stub.js), so the TypeError it
                // throws is that REALM's TypeError, not this file's --
                // `err instanceof TypeError` is false across realms even
                // though `err.name === 'TypeError'` and it behaves exactly
                // like one. Match on `.name`, the same cross-realm-safe
                // pattern real cross-context error checking requires.
                (err) => err.name === 'TypeError' && /escapeHtml must be a function/.test(err.message),
                'expected a TypeError naming escapeHtml for the "' + label + '" case'
            );
            assert.equal(
                createElementCalls,
                0,
                'no DOM node should be constructed before the escapeHtml guard throws (case: ' + label + ')'
            );
        } finally {
            ctx.document.createElement = originalCreateElement;
        }
    }

    console.log('XACA-0990 finding 5: escapeHtml TypeError guard covered for omitted/null/non-function -- no DOM node constructed in any case.');
});

test('LCARS_TERMINAL_CARD.createServiceOnlyLcarsCard still succeeds with a valid escapeHtml (control)', () => {
    // Sanity control for the test above: proves the guard is specifically
    // about "not a function", not an overzealous throw that also rejects
    // valid input.
    const { ctx } = createDomStub();
    vm.createContext(ctx);
    loadSharedTerminalCardModule(ctx);

    const svc = { reachable: true, hostname: 'runabout.example.com', port: 8080 };
    const identityEscapeHtml = (s) => String(s);

    const card = ctx.window.LCARS_TERMINAL_CARD.createServiceOnlyLcarsCard('academy', svc, identityEscapeHtml);
    assert.ok(card, 'a valid escapeHtml function must produce a card, not throw');
    assert.equal(card.tagName, 'DIV');
});
