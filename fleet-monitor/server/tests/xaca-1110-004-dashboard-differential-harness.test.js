//
//  xaca-1110-004-dashboard-differential-harness.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1110-004: the safety net XACA-1110-005/-009 (unifying the 4 lcars2
 * dashboard app files into one config-parameterized module) depends on.
 * Must exist and pass at 100% against the four CURRENT files BEFORE a
 * single file is collapsed -- see
 * ~/dev-team/kanban/plans/XACA-1110/XACA-1110-design-decision.md.
 *
 * ── Regression bar (XACA-1100, k079) ───────────────────────────────────────
 * Drive old and new renderers with identical inputs across a fixture x
 * collapsed/expanded matrix, diff the FULL serialized DOM (tag names,
 * attributes, textContent, child order) -- not "does it render", not "is
 * the top-level structure the same". XACA-1100 achieved 32/32 (16 machine
 * fixtures x 2 states). This suite matches that bar in shape (16 fixtures x
 * 2 states x 4 targets = 128 renderMachines() combinations, see
 * tests/helpers/lcars-fleet-dashboard-jsdom-loader.js's MACHINE_FIXTURES)
 * and extends it to the render surfaces this ticket's config knobs
 * actually touch -- renderDivisions() (org grouping, resolveColor's
 * unmappedOrgColor argument -- D3), the machines/divisions empty-state
 * messages (D4), getDivisionPriority() (D2), and candyOptions.section (a
 * 4th config knob the original inputs did not flag).
 *
 * ── The golden-baseline rule (design decision D8) ──────────────────────────
 * Two SEPARATE golden artifacts are in play here, with different rules:
 *
 *   1. tests/xaca-1110-004-dashboard-render-baseline.json -- a NEW artifact
 *      THIS subitem introduces (via
 *      tests/scripts/generate-xaca-1110-004-dashboard-baseline.js),
 *      capturing the 4 CURRENT files' render output. Freely regenerable
 *      *by this subitem, right now* -- there is no pre-existing value to
 *      protect yet. Once committed, it becomes the frozen reference
 *      XACA-1110-005/-009 must reproduce.
 *
 *   2. tests/xaca-0990-001-lcars-terminal-card-baseline.json -- a
 *      PRE-EXISTING artifact from a different ticket (XACA-0990). D8 is
 *      explicit: "Do NOT simply regenerate it. Instead, subitem 004 must:
 *      load the unified module four times, once per config, and assert
 *      each run reproduces the EXISTING golden entry for the file it
 *      replaces." The "XACA-0990 golden-baseline reproduction check"
 *      section below does exactly that, read-only against file (2) --
 *      never writing to it, never regenerating it.
 *
 * ── The single knob (parameterize on the module under test) ───────────────
 * See tests/helpers/lcars-fleet-dashboard-jsdom-loader.js's file header and
 * tests/helpers/lcars-fleet-dashboard-matrix.js's DASHBOARD_TARGETS. TODAY:
 * 4 descriptors, one per current file. AFTER XACA-1110-005/-009: change
 * ONLY DASHBOARD_TARGETS (relPath -> the unified module,
 * configGlobal -> the D5 six-key config object) -- this test file does not
 * change.
 *
 * ── Anti-vacuity ────────────────────────────────────────────────────────
 * Two PERMANENT negative-control tests below prove this harness can fail,
 * not just that it happens to pass today:
 *   - "negative control: a mutated golden baseline is detected" mutates the
 *     PARSED golden JSON in memory and re-runs the same string-diff this
 *     suite's real comparison uses (mirrors
 *     xaca-0990-001-lcars-terminal-card-characterization.test.js's own
 *     negative control).
 *   - "negative control: a mutated SOURCE FILE is detected" goes one layer
 *     deeper -- it mutates a real app file's source TEXT (never touching
 *     the file on disk; same srcOverride technique as
 *     tests/xaca-1100-013-render-machines-expand-survives-refresh.test.js)
 *     and drives it through the REAL loader -> capture -> golden-compare
 *     pipeline end to end, proving the whole pipeline (not just the final
 *     string-diff step) reacts to a real behavior change.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const {
    DASHBOARD_TARGETS,
    UNMAPPED_DIVISION_CODE,
    PRIORITY_CODES,
    buildFilterDataFixture,
    captureContainerInnerHTML,
    capturePriorities,
    captureCandySection,
    computeAllResults,
    stableStringify
} = require('./helpers/lcars-fleet-dashboard-matrix.js');
const { loadDashboardModule, MACHINE_FIXTURES, PUBLIC_ROOT } = require('./helpers/lcars-fleet-dashboard-jsdom-loader.js');
const { loadClientApp, createDomStub } = require('./helpers/lcars-client-dom-stub.js');
const { ISLCARS_CASES, CARD_CASES, captureIsLcarsTerminalCase, captureCardCase } = require('./helpers/lcars-terminal-card-matrix.js');

const BASELINE_PATH = path.join(__dirname, 'xaca-1110-004-dashboard-render-baseline.json');
const XACA_0990_BASELINE_PATH = path.join(__dirname, 'xaca-0990-001-lcars-terminal-card-baseline.json');

// Computed once, lazily, and reused across every test that needs it -- CJS
// test files cannot use top-level `await`, so this is a memoized async
// getter rather than a top-level `const ACTUAL_RESULTS = await ...`.
let actualResultsPromise = null;
function getActualResults() {
    if (!actualResultsPromise) {
        actualResultsPromise = computeAllResults();
    }
    return actualResultsPromise;
}

// ============================================================================
// Harness sanity
// ============================================================================

test('harness sanity: DASHBOARD_TARGETS resolves to a known-good count', () => {
    // 4 in dev-team (all 4 files present), 2 in the tap (academy + all only
    // -- XACA-0139 excludes doublenode + mainevent). Any other count is a
    // silent partial discovery this suite must not paper over -- see
    // lcars-fleet-dashboard-matrix.js's own throw for the same invariant,
    // asserted here too so a failure surfaces as a named test, not a
    // require()-time crash with a less discoverable stack.
    assert.ok(
        DASHBOARD_TARGETS.length === 4 || DASHBOARD_TARGETS.length === 2,
        'DASHBOARD_TARGETS must resolve to 4 (dev-team) or 2 (tap) targets, found ' + DASHBOARD_TARGETS.length
    );
});

test('harness sanity: MACHINE_FIXTURES matches the XACA-1100 regression bar (16 fixtures)', () => {
    assert.equal(MACHINE_FIXTURES.length, 16, 'MACHINE_FIXTURES must have exactly 16 entries');
    const ids = new Set(MACHINE_FIXTURES.map((f) => f.id));
    assert.equal(ids.size, 16, 'every fixture id must be unique');
});

test('harness sanity: golden baseline file is byte-exact on disk, not merely equivalent when parsed', () => {
    assert.ok(fs.existsSync(BASELINE_PATH), 'golden baseline missing -- run node tests/scripts/generate-xaca-1110-004-dashboard-baseline.js');
    const raw = fs.readFileSync(BASELINE_PATH, 'utf8');
    const roundTripped = stableStringify(JSON.parse(raw));
    assert.strictEqual(
        raw,
        roundTripped,
        'golden baseline raw bytes differ from its canonical serialisation -- investigate before ' +
            'restoring it; do NOT regenerate to make this pass.'
    );
});

// ============================================================================
// The core differential comparison: 16 fixtures x collapsed/expanded x 4
// targets, plus empty states, populated divisions, and priorities -- ALL
// diffed byte-for-byte against the checked-in golden baseline.
// ============================================================================

test('actual dashboard render output matches the golden baseline exactly', async () => {
    const actual = await getActualResults();
    const actualJson = stableStringify(actual);

    const golden = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
    // Restricted to the labels DASHBOARD_TARGETS actually discovered (tap
    // parity, same reasoning as xaca-0990-001's file-existence restriction)
    // -- never regenerated to make a narrower comparison pass.
    const goldenSubset = {};
    for (const target of DASHBOARD_TARGETS) {
        assert.ok(
            Object.prototype.hasOwnProperty.call(golden, target.label),
            'discovered target "' + target.label + '" has no corresponding golden baseline entry'
        );
        goldenSubset[target.label] = golden[target.label];
    }
    const goldenJson = stableStringify(goldenSubset);

    // Round-trip both sides through real temp files, same as
    // xaca-0990-001's own comparison, so this cannot be fooled by
    // accidental shared object references between actual/golden.
    const actualTmpPath = path.join(os.tmpdir(), 'xaca-1110-004-actual-' + process.pid + '.json');
    const goldenTmpPath = path.join(os.tmpdir(), 'xaca-1110-004-golden-subset-' + process.pid + '.json');
    fs.writeFileSync(actualTmpPath, actualJson, 'utf8');
    fs.writeFileSync(goldenTmpPath, goldenJson, 'utf8');
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
            'actual dashboard render output diverges from golden baseline at line ' + firstDiffLine + '\n' +
                '  actual: ' + JSON.stringify(actualLines[firstDiffLine - 1]) + '\n' +
                '  golden: ' + JSON.stringify(goldenLines[firstDiffLine - 1])
        );
    }
    assert.equal(actualOnDisk, goldenOnDisk);
});

test('executed-case count is positive and matches the expected matrix size exactly', async () => {
    const actual = await getActualResults();
    let executedMachineCombos = 0;
    for (const target of DASHBOARD_TARGETS) {
        const perTarget = actual[target.label];
        assert.ok(perTarget, 'missing results for ' + target.label);
        const fixtureCount = Object.keys(perTarget.machines).length;
        assert.equal(fixtureCount, 16, target.label + ': expected exactly 16 machine fixtures');
        executedMachineCombos += fixtureCount * 2; // collapsed + expanded
    }
    const expectedTotal = DASHBOARD_TARGETS.length * 16 * 2;
    console.log(
        'XACA-1110-004: executed ' + executedMachineCombos + ' machine collapsed/expanded combinations across ' +
        DASHBOARD_TARGETS.length + ' target(s) (expected ' + expectedTotal + ')'
    );
    assert.ok(executedMachineCombos > 0, 'executed combination count must be positive');
    assert.equal(executedMachineCombos, expectedTotal, 'executed combination count must equal the expected matrix size exactly');
});

test('fixtures with no `system` block have IDENTICAL collapsed/expanded capture (no toggle exists)', async () => {
    // Sanity check on the matrix's own semantics, not a golden-diff: a
    // machine with no `system` key renders no SYSTEM toggle
    // (buildSystemSectionHtml's static "no data" line), so clicking a
    // (non-existent) toggle is a no-op and collapsed === expanded BY
    // CONSTRUCTION. If this ever stopped being true, the matrix's
    // "collapsed/expanded" framing for these 2 fixtures would be
    // misleading, not merely uninteresting.
    const target = DASHBOARD_TARGETS[0];
    for (const fixtureId of ['no_system_online', 'no_system_offline']) {
        const fixture = MACHINE_FIXTURES.find((f) => f.id === fixtureId);
        const { window, document, mod } = await loadDashboardModule(target);
        mod.renderMachines([fixture.machine]);
        const container = document.getElementById('machines-list');
        const collapsed = container.innerHTML;
        const toggle = container.querySelector('.status-row-system-toggle[data-machine-id="' + window.CSS.escape(fixture.machine.machine_id) + '"]');
        assert.equal(toggle, null, fixtureId + ': must have no SYSTEM toggle');
        assert.equal(document.getElementById('machines-list').innerHTML, collapsed, fixtureId + ': collapsed capture must be stable with no toggle to click');
    }
});

// ============================================================================
// Anti-vacuity: negative controls (PERMANENT regression tests)
// ============================================================================

test('negative control: a mutated golden baseline is detected as a real divergence', () => {
    const golden = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
    const label = DASHBOARD_TARGETS[0].label;
    const mutated = JSON.parse(JSON.stringify(golden));
    // Flip one deeply-nested leaf: a captured machine-render HTML string.
    const originalValue = mutated[label].machines.full_healthy_baseline.collapsed;
    mutated[label].machines.full_healthy_baseline.collapsed = originalValue + '<!-- MUTATED -->';

    const goldenJson = stableStringify(golden);
    const mutatedJson = stableStringify(mutated);
    assert.notStrictEqual(
        goldenJson,
        mutatedJson,
        'harness bug: a mutated baseline must serialize differently from the original'
    );
});

test('negative control: a mutated CONFIG FILE is detected end-to-end', async () => {
    // The literal anti-vacuity demonstration this subitem requires:
    // introduce a one-character-class mutation into a COPY of one real
    // on-disk source file (never touching the file itself) and confirm the
    // REAL loader -> capture -> compare pipeline this suite uses actually
    // reacts to it, not just the final string-diff step in isolation.
    //
    // XACA-1110-005/-009 UPDATE: D4's `emptyMessage` literal moved OUT of
    // the app module and into each dashboard's own config file (D5 -- the
    // unified module contains NO org registry, so it cannot bake in a
    // per-org string either). The pre-unification version of this test
    // mutated the app file's source text directly; the equivalent mutation
    // target post-unification is the CONFIG file's source text -- same
    // "mutate real on-disk source, run it through the real loading
    // mechanism, diff against golden" method, applied to where this
    // literal actually lives now. relPath (the unified module itself)
    // stays real and unmutated throughout.
    const target = DASHBOARD_TARGETS.find((t) => t.label === 'academy') || DASHBOARD_TARGETS[0];
    const realConfigSrc = fs.readFileSync(path.join(PUBLIC_ROOT, target.configRelPath), 'utf8');

    // Mutate whichever `emptyMessage:` literal this target's config
    // actually has -- a single-character change (one letter) to the
    // config string D4 exists to protect, applied to a real file, not a
    // hand-typed approximation of one.
    const emptyMessageRe = /emptyMessage: '([^']*)'/;
    const match = realConfigSrc.match(emptyMessageRe);
    assert.ok(match, 'could not locate emptyMessage literal in ' + target.configRelPath);
    const original = match[0];
    const mutatedLiteral = original.slice(0, -2) + 'X' + "'"; // flip the last character before the closing quote
    assert.notEqual(mutatedLiteral, original, 'mutation must actually change the literal');
    const mutatedConfigSrc = realConfigSrc.replace(original, mutatedLiteral);
    assert.notEqual(mutatedConfigSrc, realConfigSrc, 'mutated config source must differ from the real file');

    // Run the mutated CONFIG source (never the real file on disk) through
    // the exact same sandboxed loader loadConfigGlobal() uses, to get a
    // real `configGlobal` object carrying the mutated emptyMessage.
    const sandbox = { window: {} };
    vm.createContext(sandbox);
    vm.runInContext(mutatedConfigSrc, sandbox, { filename: target.configRelPath });
    const mutatedConfigGlobal = sandbox.window.LCARS_DASHBOARD_CONFIG;
    assert.ok(mutatedConfigGlobal, 'mutated config source must still assign window.LCARS_DASHBOARD_CONFIG');
    assert.notEqual(mutatedConfigGlobal.emptyMessage, target.configGlobal.emptyMessage, 'mutated configGlobal.emptyMessage must differ from the real one');

    const golden = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
    const goldenDivisionsEmpty = golden[target.label].emptyStates.divisionsEmpty;

    const { document, mod } = await loadDashboardModule(Object.assign({}, target, { configGlobal: mutatedConfigGlobal }));
    mod.renderDivisions({});
    const mutatedDivisionsEmpty = captureContainerInnerHTML(document, 'divisions-container');

    assert.notStrictEqual(
        mutatedDivisionsEmpty,
        goldenDivisionsEmpty,
        'harness bug: a one-character mutation to the config\'s emptyMessage must be detected as a ' +
            'divergence from the golden baseline -- if this assertion itself fails (i.e. the ' +
            'mutated and golden values are EQUAL), the harness is vacuous and cannot be trusted ' +
            'to catch a real regression in XACA-1110-005/-009.'
    );
});

// ============================================================================
// XACA-0990 golden-baseline reproduction check (design decision D8)
// ============================================================================
// "Load the module under test four times, once per config, and assert each
// run reproduces the EXISTING golden entry for the file it replaces." Uses
// the SAME loader (lcars-client-dom-stub's loadClientApp) and the SAME
// matrix (lcars-terminal-card-matrix's ISLCARS_CASES/CARD_CASES) the
// pre-existing xaca-0990-001 suite uses -- parameterized by
// DASHBOARD_TARGETS[i].relPath, so when 005/009 repoint that array at the
// unified module, this exact test (unmodified) asserts the new module
// reproduces the OLD file's golden entry. Read-only against
// xaca-0990-001-lcars-terminal-card-baseline.json -- never written to,
// never regenerated by this subitem.

test('XACA-0990 golden-baseline reproduction: each dashboard target reproduces its existing golden entry', () => {
    assert.ok(
        fs.existsSync(XACA_0990_BASELINE_PATH),
        'xaca-0990-001 golden baseline missing at ' + XACA_0990_BASELINE_PATH
    );
    const golden0990 = JSON.parse(fs.readFileSync(XACA_0990_BASELINE_PATH, 'utf8'));

    for (const target of DASHBOARD_TARGETS) {
        assert.ok(
            Object.prototype.hasOwnProperty.call(golden0990, target.relPath),
            'xaca-0990-001 golden baseline has no entry for "' + target.relPath + '" -- the module under ' +
                'test descriptor must supply the ORIGINAL relPath it replaces so this check has something ' +
                'to compare against.'
        );
        const goldenEntry = golden0990[target.relPath];
        const { ctx } = createDomStub();
        const mod = loadClientApp(target.relPath, ctx);

        for (const c of ISLCARS_CASES) {
            const actualValue = captureIsLcarsTerminalCase(target.relPath, c.teamData);
            assert.deepStrictEqual(
                actualValue,
                goldenEntry.isLcarsTerminal[c.id],
                'DIVERGENCE: ' + target.relPath + ' isLcarsTerminal case "' + c.id +
                    '" no longer reproduces the xaca-0990-001 golden entry'
            );
        }
        for (const c of CARD_CASES) {
            const actualValue = captureCardCase(target.relPath, c.name, c.svc);
            assert.deepStrictEqual(
                actualValue,
                goldenEntry.createServiceOnlyLcarsCard[c.id],
                'DIVERGENCE: ' + target.relPath + ' createServiceOnlyLcarsCard case "' + c.id +
                    '" no longer reproduces the xaca-0990-001 golden entry'
            );
        }
        void mod;
    }
});

test('harness sanity: xaca-0990-001 golden baseline VALUES are untouched by this subitem (only the keys were re-mapped)', () => {
    // This subitem's own generator (generate-xaca-1110-004-dashboard-
    // baseline.js) writes ONLY xaca-1110-004-dashboard-render-baseline.json
    // -- never RECAPTURES xaca-0990-001's file. Design decision D8's one
    // explicit exception assigns subitem 005 the job of RE-KEYING this
    // baseline's 4 lcars2 entries (they were byte-identical across all 4
    // former files, verified before the re-key) into ONE entry filed under
    // the unified module's path -- collapsing 4 keys -> 1 pointing at the
    // SAME value, never recapturing it. So the expected shape shrank from
    // 5 top-level entries (v1 + 4 lcars2) to exactly 2 (v1 + the unified
    // lcars2 module) -- pin that exact shape, not a loose lower bound, and
    // assert the unified entry is a REAL, non-trivial value (not a stub
    // dropped in by a re-keying mistake).
    const raw = fs.readFileSync(XACA_0990_BASELINE_PATH, 'utf8');
    const parsed = JSON.parse(raw);
    assert.deepStrictEqual(
        Object.getOwnPropertyNames(parsed).sort(),
        ['lcars/js/lcars-dashboard-app.js', 'lcars2/js/lcars-fleet-dashboard-app.js'],
        'xaca-0990-001 golden baseline must cover exactly the v1 file plus the one unified lcars2 module post-re-key'
    );
    const unifiedEntry = parsed['lcars2/js/lcars-fleet-dashboard-app.js'];
    assert.ok(unifiedEntry && unifiedEntry.isLcarsTerminal && unifiedEntry.createServiceOnlyLcarsCard,
        'the re-keyed unified-module entry must still carry real isLcarsTerminal/createServiceOnlyLcarsCard data, not an empty stub');
});

// ============================================================================
// filterData(): real hand-computed oracle (not a self-captured golden value)
// ============================================================================

test('filterData() filters divisions and machine sessions to CONFIG.divisions exactly', async () => {
    const fixture = buildFilterDataFixture();

    // `null` for a machine means filterData() must DROP it entirely --
    // lcars-fleet-dashboard-app.js's filterData() `.filter(m => m.session_count > 0)`
    // removes any machine whose sessions ALL belong to divisions outside
    // CONFIG.divisions, rather than keeping it with an empty sessions array.
    const expectedByLabel = {
        academy: { divisions: ['academy'], machine1Divisions: ['academy'], machine2Divisions: null },
        doublenode: { divisions: ['dns', 'freelance'], machine1Divisions: ['dns'], machine2Divisions: ['freelance'] },
        mainevent: { divisions: ['android', 'command', 'firebase', 'ios'], machine1Divisions: ['android'], machine2Divisions: ['command'] }
    };

    for (const target of DASHBOARD_TARGETS) {
        const { mod } = await loadDashboardModule(target);
        if (target.label === 'all') {
            assert.equal(mod.filterData, null, "'all' must not define filterData -- D1: nothing to filter for an unbounded dashboard");
            continue;
        }
        const expected = expectedByLabel[target.label];
        assert.ok(expected, 'no hand-computed expectation registered for target "' + target.label + '"');

        const filtered = mod.filterData(fixture);
        assert.deepStrictEqual(
            Object.keys(filtered.fleet.divisions).sort(),
            expected.divisions.slice().sort(),
            target.label + ': filtered division set mismatch'
        );

        const byId = new Map(filtered.fleet.machines.map((m) => [m.machine_id, m]));
        const m1 = byId.get('filter-fixture-machine-1');
        const m2 = byId.get('filter-fixture-machine-2');

        if (expected.machine1Divisions === null) {
            assert.equal(m1, undefined, target.label + ': machine 1 must be dropped entirely (0 sessions survive filtering)');
        } else {
            assert.ok(m1, target.label + ': machine 1 must survive filtering');
            assert.deepStrictEqual(m1.sessions.map((s) => s.division), expected.machine1Divisions, target.label + ': machine 1 filtered sessions mismatch');
        }
        if (expected.machine2Divisions === null) {
            assert.equal(m2, undefined, target.label + ': machine 2 must be dropped entirely (0 sessions survive filtering)');
        } else {
            assert.ok(m2, target.label + ': machine 2 must survive filtering');
            assert.deepStrictEqual(m2.sessions.map((s) => s.division), expected.machine2Divisions, target.label + ': machine 2 filtered sessions mismatch');
        }
        assert.equal(filtered.fleet.machines.length, [expected.machine1Divisions, expected.machine2Divisions].filter((x) => x !== null).length, target.label + ': total surviving machine count mismatch');
    }
});

// ============================================================================
// getDivisionPriority(): D2 equivalence proof, run for real (not just read)
// ============================================================================

test('getDivisionPriority() returns IDENTICAL values across all 4 targets for every code (D2)', async () => {
    const perTarget = {};
    for (const target of DASHBOARD_TARGETS) {
        perTarget[target.label] = await capturePriorities(target);
    }
    const labels = Object.keys(perTarget);
    const [referenceLabel, ...restLabels] = labels;
    for (const code of PRIORITY_CODES) {
        const referenceValue = perTarget[referenceLabel][code];
        for (const label of restLabels) {
            assert.equal(
                perTarget[label][code],
                referenceValue,
                'DIVERGENCE: getDivisionPriority("' + code + '") differs between ' + referenceLabel + ' (' +
                    referenceValue + ') and ' + label + ' (' + perTarget[label][code] + ') -- D2\'s equivalence ' +
                    'proof (teamConfig === null) is violated for a real input.'
            );
        }
    }
    // UNMAPPED_DIVISION_CODE is exactly the code the prefix-fallback branch
    // and the static map's `|| 100` both agree on (D2's proof table) --
    // pin its value explicitly, not just its cross-target equality.
    assert.equal(perTarget[referenceLabel][UNMAPPED_DIVISION_CODE], 100);
});

// ============================================================================
// candyOptions.section: the 4th config knob (functional, via a real
// DOMContentLoaded invocation -- see captureCandySection's own doc comment)
// ============================================================================

test('candyOptions.section matches the design decision table exactly', async () => {
    const expected = { academy: 'overview', doublenode: 'overview', mainevent: 'organizations', all: 'overview' };
    for (const target of DASHBOARD_TARGETS) {
        const section = await captureCandySection(target);
        assert.ok(
            Object.prototype.hasOwnProperty.call(expected, target.label),
            'no expected candySection registered for target "' + target.label + '"'
        );
        assert.equal(section, expected[target.label], target.label + ': candyOptions.section mismatch');
    }
});

// ============================================================================
// D1.4: the accepted DOMContentLoaded async behavior change -- pinned, not
// assumed.
//
// XACA-1110-005/-009 UPDATE: the pre-unification pair of tests here
// (source-checking the 3 filtered files for "no await today", then
// source-mutating one into an async copy to prove the wrapping was safe)
// exercised a PREMISE about the 4 separate, then-still-synchronous files,
// as a precondition check before doing the actual unification. That
// premise has now been ACTED ON: the real unified module's
// DOMContentLoaded handler is unconditionally async (D1.4's accepted
// change), for every config, including the 3 filtered ones. There is no
// longer a non-async copy on disk to source-mutate into an async one and
// diff against -- relPath is identical across all 4 labels. The tests
// below assert the REALIZED form of the same D1.4 claim directly against
// the real, already-async module: (1) the handler really is async for
// every target, and (2) for a filtered dashboard, the real async handler's
// observable call sequence is byte-for-byte what a synchronous handler
// would have produced -- no fetchTeamConfig() network call, and
// init/fetch/setInterval in the same order -- while 'all' does perform
// that extra call, proving isUnbounded actually gates it rather than the
// branch being dead code.
// ============================================================================

const FILTERED_LABELS = ['academy', 'doublenode', 'mainevent'];

test('D1.4 pinning: the unified module\'s DOMContentLoaded handler is async for every dashboard (accepted non-change, realized)', () => {
    for (const target of DASHBOARD_TARGETS) {
        const src = fs.readFileSync(path.join(PUBLIC_ROOT, target.relPath), 'utf8');
        assert.ok(
            /document\.addEventListener\('DOMContentLoaded', async function\(\)/.test(src),
            target.relPath + ": DOMContentLoaded handler is expected to be async for every dashboard (D1.4) -- " +
                'target "' + target.label + '" did not match'
        );
    }
});

test('D1.4 functional check: a filtered dashboard\'s real (async) handler produces the SAME observable call sequence a synchronous one would; \'all\' alone performs the extra team-config fetch', async () => {
    async function runAndCapture(target) {
        const events = [];
        const { window, domContentLoadedHandler } = await loadDashboardModule(
            Object.assign({}, target, { captureDomContentLoaded: true })
        );
        assert.ok(domContentLoadedHandler, target.label + ': DOMContentLoaded handler was not captured');
        window.LCARS_CORE = { init: (opts) => events.push(['init', JSON.stringify(opts)]) };
        window.fetch = (url) => {
            events.push(['fetch', String(url)]);
            return Promise.resolve({
                ok: true,
                // Shape satisfies both possible consumers -- fetchFleetData()
                // (`{ fleet: {...} }`) and fetchTeamConfig() (`{ teams: {...} }`)
                // -- so neither continuation logs a spurious warning.
                json: () => Promise.resolve({ fleet: { divisions: {}, machines: [] }, teams: {} })
            });
        };
        window.setInterval = (fn, ms) => { events.push(['setInterval', ms]); return 0; };
        window.clearInterval = () => {};
        const isAsync = domContentLoadedHandler.constructor.name === 'AsyncFunction';
        const maybePromise = domContentLoadedHandler.call(window);
        if (maybePromise && typeof maybePromise.then === 'function') {
            await maybePromise;
        }
        return { events, isAsync };
    }

    for (const label of FILTERED_LABELS) {
        const target = DASHBOARD_TARGETS.find((t) => t.label === label);
        if (!target) continue; // tap-excluded (doublenode/mainevent) -- skip what does not exist here

        const { events, isAsync } = await runAndCapture(target);
        assert.equal(isAsync, true, target.label + ": today's handler must be an AsyncFunction (D1.4)");
        const teamConfigFetches = events.filter((e) => e[0] === 'fetch' && String(e[1]).includes('/api/team-config'));
        assert.equal(teamConfigFetches.length, 0, target.label + ': a filtered (non-unbounded) dashboard must issue ZERO team-config fetches (D1)');
        const fleetFetches = events.filter((e) => e[0] === 'fetch' && String(e[1]).includes('/api/fleet'));
        assert.equal(fleetFetches.length, 1, target.label + ': expected exactly one fleet-data fetch');
        assert.deepStrictEqual(
            events.map((e) => e[0]),
            // init -> fetchFleetData() -> refreshTimer's setInterval -> the
            // stardate setInterval -- the real handler body's exact order.
            ['init', 'fetch', 'setInterval', 'setInterval'],
            'DIVERGENCE: ' + target.label + " the async handler's observable call TYPE sequence " +
                '(LCARS_CORE.init / fetch / setInterval x2) does not match what a synchronous handler would ' +
                'have produced -- D1.4\'s "non-change in practice" claim does not hold for this dashboard.'
        );
        assert.ok(events.length > 0, target.label + ': sanity -- must have captured at least one event');
    }

    const allTarget = DASHBOARD_TARGETS.find((t) => t.label === 'all');
    if (allTarget) {
        const { events, isAsync } = await runAndCapture(allTarget);
        assert.equal(isAsync, true, "'all': today's handler must be an AsyncFunction (D1.4)");
        assert.deepStrictEqual(
            events.map((e) => e[0]),
            ['init', 'fetch', 'fetch', 'setInterval', 'setInterval'],
            "'all' (isUnbounded) must perform the team-config fetch BEFORE the fleet-data fetch -- proving D1's " +
                'isUnbounded branch actually gates fetchTeamConfig() rather than it being dead code'
        );
        assert.match(String(events[1][1]), /\/api\/team-config$/, "'all': the first fetch must be the team-config endpoint");
        assert.match(String(events[2][1]), /\/api\/fleet$/, "'all': the second fetch must be the fleet-data endpoint");
    }
});

// ============================================================================
// D5 residual-risk mitigation: enforce the tap-exclusion naming invariant
// ============================================================================
// "Add an assertion that the tap-shipped lcars2/js/ set contains no
// doublenode/mainevent literal. Cheap, and it converts a naming convention
// into an enforced invariant." (design decision, D5 "Residual risk").

function resolveTapLcars2JsDir() {
    // This worktree's homebrew-tap submodule may be uninitialized (an empty
    // gitlink checkout) -- verified true for THIS worktree at the time this
    // suite was written. Falling back to the main dev-team repo's own tap
    // checkout mirrors the documented worktree lesson (never trust a
    // worktree's own possibly-uninitialized tap; reference the main repo's)
    // rather than reporting a false pass OR a false failure caused purely
    // by worktree state.
    const candidates = [
        path.join(PUBLIC_ROOT, '..', '..', '..', 'homebrew-tap', 'fleet-monitor', 'server', 'public', 'lcars2', 'js'),
        path.join(os.homedir(), 'dev-team', 'homebrew-tap', 'fleet-monitor', 'server', 'public', 'lcars2', 'js')
    ];
    for (const dir of candidates) {
        if (fs.existsSync(dir) && fs.readdirSync(dir).length > 0) {
            return dir;
        }
    }
    return null;
}

test('D5 invariant: tap-shipped lcars2/js/ files carry no doublenode/mainevent BASENAME and no org-doublenode/org-mainevent CSS class literal (comment mentions are allowed)', (t) => {
    const tapDir = resolveTapLcars2JsDir();
    if (!tapDir) {
        t.skip('homebrew-tap lcars2/js not resolvable from this worktree or the main repo -- see resolveTapLcars2JsDir()');
        return;
    }
    const files = fs.readdirSync(tapDir).filter((f) => f.endsWith('.js'));
    assert.ok(files.length > 0, 'resolved tap dir has no .js files: ' + tapDir);
    for (const file of files) {
        assert.ok(
            !/doublenode|mainevent/i.test(file),
            'tap-shipped file "' + file + '" carries a doublenode/mainevent literal in its BASENAME -- ' +
                'sync-tap.sh\'s exclusion is basename-only (D5); this file would leak branding.'
        );
        const content = fs.readFileSync(path.join(tapDir, file), 'utf8');
        // A comment mentioning "doublenode"/"mainevent" (e.g. explaining
        // why a file is EXCLUDED) is expected and fine; a literal CSS class
        // or config value shipping the other dashboards' identity is not.
        // This check is intentionally narrow (exact org class literals from
        // D3) rather than a blanket content ban, which would false-positive
        // on the many legitimate doc comments already in these files.
        assert.ok(
            !/org-doublenode|org-mainevent/.test(content),
            'tap-shipped file "' + file + '" contains an org-doublenode/org-mainevent CSS class literal -- ' +
                'D5\'s "no org registry in the unified module" constraint is violated.'
        );
    }
});
