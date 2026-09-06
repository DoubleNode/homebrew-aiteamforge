//
//  xaca-1092-006-degradation-adversarial.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1092-006 -- adversarial regression coverage for graceful degradation
 * against a machine whose reporter never sends the `system{}` block (old
 * reporter, or non-macOS host), and against every hostile/malformed shape
 * a self-reported POST /api/status body could plausibly carry.
 *
 * ── Why this file exists ─────────────────────────────────────────────────
 * Prior to this file, `createMachineItem()` in all 5 client app files
 * (public/lcars2/js/lcars-{academy,all,doublenode,mainevent}-app.js and
 * public/lcars/js/lcars-dashboard-app.js) had ZERO automated test
 * coverage -- tests/xaca-1092-003-machine-health.test.js covers only the
 * pure deriveMachineHealth() function, not the DOM-rendering adapter code
 * that consumes its output. That adapter code is what actually decides
 * whether an absent/malformed system{} block renders as a dash, a false
 * badge, or a literal "NaN"/"undefined"/"[object Object]" reaching the
 * live DOM -- so it is exactly the code this subitem's brief requires be
 * exercised, not just read.
 *
 * ── Route taken ───────────────────────────────────────────────────────────
 * Loads the REAL shipped client files via tests/helpers/lcars-client-dom-stub.js
 * (same discipline as every other *-lcars-*-ux.test.js in this directory),
 * renders createMachineItem() against (a) every case in the frozen fixture
 * tests/fixtures/xaca-1092-system-block-cases.json and (b) hostile shapes
 * the fixture does NOT cover (confirmed absent by inspecting the fixture
 * directly -- see the HAND_BUILT_CASES block below for exactly which ones
 * and why each is missing), then inspects the actual produced HTML/DOM
 * rather than trusting the source reading.
 *
 * XACA-1110 later unified the former 4 per-org lcars2 app files named above
 * into a single config-parameterized module,
 * lcars2/js/lcars-fleet-dashboard-app.js, which ships to the tap unchanged
 * (design decision doc D5) -- so ALL_CLIENT_FILES below is now the same
 * 2 files (v1 + the unified lcars2 module) in both the dev-team repo and
 * the tap, filtered by existsSync exactly like
 * tests/xaca-1002-002-idle-team-card-ux.test.js's CLIENT_FILES pattern.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createDomStub, loadClientApp } = require('./helpers/lcars-client-dom-stub.js');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');
const FIXTURE_PATH = path.join(__dirname, 'fixtures', 'xaca-1092-system-block-cases.json');

// XACA-1110-005/-009: the 4 former lcars2 app files collapsed into ONE
// config-parameterized module, which ships identically to both dev-team
// and the tap (design decision doc D5) -- so this suite's file set is now
// the same 2 files (v1 + the unified lcars2 module) in both repos.
const ALL_CLIENT_FILES = [
    'lcars/js/lcars-dashboard-app.js',
    'lcars2/js/lcars-fleet-dashboard-app.js'
];
const CLIENT_FILES = ALL_CLIENT_FILES.filter((relPath) => fs.existsSync(path.join(PUBLIC_ROOT, relPath)));

const fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));
const FIXTURE_MACHINES = fixture.fleet.machines;

function findFixture(nickname) {
    const m = FIXTURE_MACHINES.find((x) => x.nickname === nickname);
    assert.ok(m, 'fixture case missing: ' + nickname);
    return m;
}

// A minimal, complete machine object -- every field createMachineItem() in
// EITHER tree (v1's 196-line implementation or lcars2's 18-line one) reads
// unconditionally, so hand-built hostile cases don't crash on an unrelated
// missing field and produce a false "defect" that's actually just an
// incomplete fixture.
function baseMachine(overrides) {
    return Object.assign(
        {
            machine_id: '00000000-0000-4000-8000-0000000000ff',
            hostname: 'fixture-hand-built.example.test',
            nickname: 'HandBuilt',
            ip: '192.0.2.99',
            os: 'Darwin',
            status: 'online',
            first_seen: '2026-01-15T00:00:00.000Z',
            last_seen: '2026-09-04T15:00:00.000Z',
            session_count: 0,
            sessions: [],
            uptime_history: [{ timestamp: '2026-09-04T15:00:00.000Z', status: 'online', session_count: 0 }]
        },
        overrides
    );
}

/**
 * HAND-BUILT hostile cases -- confirmed ABSENT from
 * tests/fixtures/xaca-1092-system-block-cases.json by inspecting every one
 * of its 11 cases directly (`jq` over the fixture, this session). The
 * fixture's HostileDefensive case already covers: cores as a non-numeric
 * string, load_average as a bare non-array string, swap_used_bytes: null,
 * disk.free as a non-numeric string, versions.outdated as a non-boolean
 * string ("yes"), and negative memory.pressure_percent. It does NOT cover
 * any of the following, so they are constructed here:
 *
 *   - `system` key entirely ABSENT from the machine object (the fixture's
 *     SystemBlockAbsentOldReporter uses `system: {}`, which is a DIFFERENT
 *     shape per contract §3 rule 1 -- {} is what the SERVER normalizes an
 *     absent block to, but a raw machine object with no `system` key at
 *     all is what every renderer's `machine.system || {}` guard exists to
 *     handle, and it was never actually exercised).
 *   - `system: null` explicitly.
 *   - `system.versions: {}` (coordinator-flagged gap, 2026-09-04): a valid,
 *     HEALTHY payload per contract §3a ("the server injects into it -- it
 *     must exist as a target"), truthy, and the exact shape that shipped a
 *     false badge in a sibling session when guarded by container
 *     truthiness instead of a leaf existence-check.
 *   - `system.disk: {}` / `system.memory: {}` present-but-empty containers,
 *     for the same container-truthiness reason, in isolation from the
 *     versions{} case.
 *   - `load_average: []`, `load_average: [null]` -- array-shaped but
 *     empty/hostile-element, distinct from HostileDefensive's non-array
 *     string.
 *   - `cores: 0` and `cores: -1` -- division-by-zero / negative-denominator
 *     hazards for the load-per-core normalization.
 *   - Falsy-zero data points NOT already covered by IdleZeroHealthy:
 *     confirmed IdleZeroHealthy already carries swap_used_bytes:0,
 *     load_average:[0,0,0], disk.percent:0, versions.outdated:false (see
 *     the fixture directly) -- no separate case needed for those; the
 *     assertions below read that existing case instead of duplicating it.
 *   - HTML-injection in `hostname`, run through every fixture-populated
 *     shape's renderer, not just the plain no-system-block case.
 */
const HAND_BUILT_CASES = {
    SystemKeyEntirelyAbsent: (() => {
        const m = baseMachine({ nickname: 'SystemKeyEntirelyAbsent' });
        delete m.system; // no `system` property at all, not even {}
        return m;
    })(),
    SystemExplicitNull: baseMachine({ nickname: 'SystemExplicitNull', system: null }),
    VersionsEmptyObjectHealthPopulated: baseMachine({
        nickname: 'VersionsEmptyObjectHealthPopulated',
        system: {
            schema_version: 1,
            versions: {}, // truthy, but no `aiteamforge` key -- must render as if versions were absent
            os_name: 'macOS',
            os_version: '27.0',
            cores: 11,
            memory: { used: 1000000000, total: 2000000000, pressure_percent: 50 },
            swap_used_bytes: 0,
            disk: { used: 100, free: 300, percent: 25 },
            load_average: [1.0, 1.0, 1.0]
        }
    }),
    VersionsEmptyObjectHealthAlsoAbsent: baseMachine({
        nickname: 'VersionsEmptyObjectHealthAlsoAbsent',
        system: { schema_version: 1, versions: {} }
    }),
    DiskEmptyObject: baseMachine({
        nickname: 'DiskEmptyObject',
        system: { schema_version: 1, versions: { aiteamforge: '0.17.9', latest: '0.17.9', outdated: false }, disk: {} }
    }),
    MemoryEmptyObject: baseMachine({
        nickname: 'MemoryEmptyObject',
        system: { schema_version: 1, versions: { aiteamforge: '0.17.9', latest: '0.17.9', outdated: false }, memory: {} }
    }),
    LoadAverageEmptyArray: baseMachine({
        nickname: 'LoadAverageEmptyArray',
        system: { schema_version: 1, versions: { aiteamforge: '0.17.9', latest: '0.17.9', outdated: false }, cores: 8, load_average: [] }
    }),
    LoadAverageNullElement: baseMachine({
        nickname: 'LoadAverageNullElement',
        system: { schema_version: 1, versions: { aiteamforge: '0.17.9', latest: '0.17.9', outdated: false }, cores: 8, load_average: [null, null, null] }
    }),
    CoresZero: baseMachine({
        nickname: 'CoresZero',
        system: {
            schema_version: 1,
            versions: { aiteamforge: '0.17.9', latest: '0.17.9', outdated: false },
            cores: 0,
            load_average: [4.0, 4.0, 4.0]
        }
    }),
    CoresNegative: baseMachine({
        nickname: 'CoresNegative',
        system: {
            schema_version: 1,
            versions: { aiteamforge: '0.17.9', latest: '0.17.9', outdated: false },
            cores: -1,
            load_average: [4.0, 4.0, 4.0]
        }
    }),
    HostnameHtmlInjectionNoSystem: baseMachine({
        nickname: 'HostnameHtmlInjectionNoSystem',
        hostname: '<img src=x onerror=alert(1)>'
    }),
    HostnameHtmlInjectionWithSystem: baseMachine({
        nickname: 'HostnameHtmlInjectionWithSystem',
        hostname: '<svg onload=alert(1)>',
        system: {
            schema_version: 1,
            versions: { aiteamforge: '0.17.8', latest: '0.17.9', outdated: true },
            cores: 4,
            swap_used_bytes: 40 * 1024 * 1024 * 1024, // over critical -> CRITICAL badge path too
            load_average: [20, 20, 20]
        }
    })
};

// Forbidden literals: none of these strings may ever reach rendered HTML,
// for ANY case in this file. This is a grep over the ACTUAL produced
// string, not an inference from reading the source.
const FORBIDDEN_LITERALS = ['NaN', 'undefined', '[object Object]'];

// XACA-1092-006: both XACA-1031-018's version indicator (lcars2's
// insertBefore(versionEl, item.lastElementChild), v1's
// insertBefore/appendChild version row) and XACA-1092-005's own health
// badge (item.appendChild(badgeEl)) are spliced onto `item` via the DOM
// API AFTER `item.innerHTML = "..."` has already run. tests/helpers/
// lcars-client-dom-stub.js's FakeElement.innerHTML getter (by design, see
// its own comments) only ever returns the last raw STRING assigned via
// `.innerHTML =` -- it does not serialize `.children` (the array
// appendChild()/insertBefore() actually populate) back into that string,
// the same real-vs-string-baked distinction querySelector() draws
// elsewhere in that file. Reading only `child.innerHTML` therefore misses
// both the version indicator and the health badge entirely, which does not
// mean "not rendered" -- it means "rendered somewhere renderMachine()
// wasn't looking". This composes both sources so assertions inspect what a
// real browser would actually show.
function serializeFakeChild(node) {
    if (!node || typeof node !== 'object') return '';
    const tag = String(node.tagName || 'DIV').toLowerCase();
    let attrs = '';
    if (node.className) attrs += ' class="' + node.className + '"';
    if (node._attrs instanceof Map) {
        node._attrs.forEach((value, name) => {
            attrs += ' ' + name + '="' + value + '"';
        });
    }
    let inner;
    if (Array.isArray(node.children) && node.children.length > 0) {
        inner = node.children.map(serializeFakeChild).join('');
    } else {
        // textContent's setter already populated _innerHTML with the
        // WHATWG-escaped serialization (see textContentToInnerHtml in the
        // stub) -- reading _innerHTML covers both the textContent path and
        // a plain `.innerHTML = "..."` string assignment identically.
        inner = node._innerHTML || '';
    }
    return '<' + tag + attrs + '>' + inner + '</' + tag + '>';
}

function renderMachine(exports, machine) {
    const fragment = exports.createMachineItem(machine);
    assert.ok(fragment && Array.isArray(fragment.children), 'createMachineItem must return a fragment-like object with .children');
    const html = fragment.children
        .map((child) => (child.innerHTML || '') + (Array.isArray(child.children) ? child.children.map(serializeFakeChild).join('') : ''))
        .join('\n');
    return { fragment, html };
}

function assertNoForbiddenLiterals(html, context) {
    FORBIDDEN_LITERALS.forEach((literal) => {
        assert.ok(
            !html.includes(literal),
            'forbidden literal "' + literal + '" found in rendered output for ' + context + ':\n' + html
        );
    });
    // A bare, standalone "null" word (not as part of another token) must
    // also never reach the DOM -- checked separately from the array above
    // because "null" as a substring is more prone to false positives
    // (e.g. inside a class name) than the three literals above, so it gets
    // its own word-boundary regex rather than a plain .includes().
    assert.ok(
        !/\bnull\b/.test(html),
        'forbidden literal "null" (word boundary) found in rendered output for ' + context + ':\n' + html
    );
}

function countBadges(html) {
    const matches = html.match(/class="status-badge[^"]*"/g) || [];
    return matches;
}

// XACA-1092-006 (ownership-boundary regression guard, coordinator ruling
// 2026-09-04): XACA-1031 (28cd6829) OWNS tap-version display on the machine
// card -- lcars2's `status-row-version` span (createElement/textContent/
// setAttribute) and v1's `machine-version-row`/`machine-version-label`/
// `machine-version-value` row plus `machine-row-outdated` card-level class.
// XACA-1092 independently built a competing VERSION badge and a four-state
// version LINE ("(version not reported)" / `machine-version-line`
// `machine-version-line-{outdated,current,unknown}` / a `version-outdated`
// badge class) -- three version displays on one card. The user ruled DEFER
// TO XACA-1031: XACA-1092's badge and line were deleted from all 5
// renderers (buildVersionBadgeHtml / buildVersionLineHtml, definitions and
// call sites). XACA-1092 now owns ONLY the health badge and the SYSTEM
// detail panel.
//
// The literals checked below are the SPECIFIC markup XACA-1092's own,
// now-deleted version badge/line used to emit. None of them should ever
// reach rendered HTML again -- if one does, XACA-1092's version display has
// been reintroduced alongside XACA-1031's, which is exactly the
// duplication defect the user ruled against. This is a regression guard
// for an ownership boundary, not a "feature removed, delete the test"
// cleanup -- deleting these assertions outright would leave an accidental
// reintroduction of the duplicate completely uncaught.
function assertNoLegacyVersionMarkers(html, context) {
    assert.ok(
        !html.includes('(version not reported)'),
        'XACA-1092 must not render its own "(version not reported)" line -- that display belongs to XACA-1031 now (deferred per user ruling), and reintroducing it would duplicate XACA-1031\'s own version indicator, for ' + context + ': ' + html
    );
    assert.ok(
        !html.includes('machine-version-line'),
        'XACA-1092\'s deleted `machine-version-line`/`machine-version-line-*` markup must never reappear -- version display is XACA-1031\'s alone, for ' + context + ': ' + html
    );
    assert.ok(
        !html.includes('version-outdated'),
        'XACA-1092\'s deleted `version-outdated` badge class must never reappear -- an OUTDATED cue on the card is XACA-1031\'s `machine-row-outdated`/version-indicator styling, not a second badge from us, for ' + context + ': ' + html
    );
}

CLIENT_FILES.forEach((relPath) => {
    test.describe(relPath + ' -- graceful degradation, adversarial pass', () => {
        let exports;

        test.before(() => {
            const { ctx } = createDomStub();
            exports = loadClientApp(relPath, ctx);
        });

        // ── Every fixture case: no forbidden literal, ever ──────────────
        FIXTURE_MACHINES.forEach((machine) => {
            test('fixture case "' + machine.nickname + '" never renders NaN/undefined/[object Object]/null', () => {
                const { html } = renderMachine(exports, machine);
                assertNoForbiddenLiterals(html, machine.nickname);
            });
        });

        // ── Every hand-built hostile case: no forbidden literal, ever ──
        Object.keys(HAND_BUILT_CASES).forEach((name) => {
            test('hand-built case "' + name + '" never renders NaN/undefined/[object Object]/null', () => {
                const { html } = renderMachine(exports, HAND_BUILT_CASES[name]);
                assertNoForbiddenLiterals(html, name);
            });
        });

        // ── THE shipping-path case: system block entirely absent ───────
        // XACA-1031 (28cd6829) OWNS version display now -- deferred per
        // user ruling, XACA-1092's own "(version not reported)" line was
        // deleted from all 5 renderers. At the wire level system:{} is
        // INDISTINGUISHABLE from a whole-block-absent system (CONTRACT-
        // system-block.md §3 rule 1 normalizes both to `{}`), and
        // XACA-1031's `hasInstalledVersion` gate reads
        // `machine.system && machine.system.versions`, so it renders
        // nothing here either (no `aiteamforge` key to show) -- this case
        // must show ZERO version content from either owner.
        test('SystemBlockAbsentOldReporter: no SYSTEM section, no HEALTH badge, no crash, no version content of our own (XACA-1031 owns version display; this shape has nothing for either owner to show)', () => {
            const machine = findFixture('SystemBlockAbsentOldReporter');
            const { html } = renderMachine(exports, machine);
            assertNoForbiddenLiterals(html, 'SystemBlockAbsentOldReporter');
            assert.equal(countBadges(html).length, 0, 'a machine with system:{} must show zero badges: ' + html);
            assert.ok(!html.includes('SYSTEM'), 'a machine with system:{} must show no SYSTEM toggle/panel/no-data line at all: ' + html);
            assertNoLegacyVersionMarkers(html, 'SystemBlockAbsentOldReporter');
        });

        test('SystemKeyEntirelyAbsent (no `system` key at all, not even {}): identical outcome to system:{}, including NO version content of our own', () => {
            const { html } = renderMachine(exports, HAND_BUILT_CASES.SystemKeyEntirelyAbsent);
            assertNoForbiddenLiterals(html, 'SystemKeyEntirelyAbsent');
            assert.equal(countBadges(html).length, 0, html);
            assert.ok(!html.includes('SYSTEM'), html);
            assertNoLegacyVersionMarkers(html, 'SystemKeyEntirelyAbsent');
        });

        test('SystemExplicitNull: `system: null` degrades identically to `system: {}`, never throws, still renders NO version content of our own', () => {
            const { html } = renderMachine(exports, HAND_BUILT_CASES.SystemExplicitNull);
            assertNoForbiddenLiterals(html, 'SystemExplicitNull');
            assert.equal(countBadges(html).length, 0, html);
            assert.ok(!html.includes('SYSTEM'), html);
            assertNoLegacyVersionMarkers(html, 'SystemExplicitNull');
        });

        // ── VersionsOnlyDayOne / NonMacOSHostVersionsOnly: the actual
        //    day-one production shape for the whole fleet until XACA-1091
        //    ships -- schema_version + versions only, zero health groups ──
        test('VersionsOnlyDayOne: static "SYSTEM: NO DATA REPORTED" line, no chevron, no HEALTH badge, no version content of our own (XACA-1031\'s own OUTDATED indicator is the only version display for this outdated-version fixture case)', () => {
            const machine = findFixture('VersionsOnlyDayOne');
            const { html } = renderMachine(exports, machine);
            assertNoForbiddenLiterals(html, 'VersionsOnlyDayOne');
            assert.equal(countBadges(html).filter((b) => b.includes('health-')).length, 0, 'zero health fields must show NO health badge: ' + html);
            assertNoLegacyVersionMarkers(html, 'VersionsOnlyDayOne');
            // This fixture case has versions.outdated:true with an
            // aiteamforge version present -- XACA-1031's OWN indicator
            // (the only version display XACA-1092 no longer duplicates)
            // must still render here. The aria-label phrasing is identical
            // across all 5 renderers (v1's machine-version-value and
            // lcars2's status-row-version both build it as
            // 'AITeamForge version ' + installedVersionText + ', ' +
            // versionStateText -- see XACA-1031-018), so one substring
            // check covers every renderer in CLIENT_FILES.
            assert.ok(html.includes('AITeamForge version 0.17.8, outdated'), 'XACA-1031 owns version display -- its own OUTDATED indicator must still render for this fixture case: ' + html);
            assert.ok(html.includes('SYSTEM: NO DATA REPORTED'), 'expected the static no-data line: ' + html);
            // Scoped to the SYSTEM toggle's OWN chevron class, never a bare
            // "▶" search -- v1's row already carries an unrelated, always-
            // present `.machine-expand-indicator` chevron for its history
            // disclosure, so a bare glyph search false-positives on every
            // v1 case regardless of the SYSTEM section (caught running this
            // suite: v1's HTML legitimately contains "▶" from that other
            // control even when the SYSTEM no-data line is correctly
            // non-interactive).
            assert.ok(
                !html.includes('system-expand-indicator') && !html.includes('status-row-system-indicator'),
                'the SYSTEM no-data line must not carry its own chevron (non-interactive): ' + html
            );
        });

        test('NonMacOSHostVersionsOnly: same static no-data treatment on a non-macOS host', () => {
            const machine = findFixture('NonMacOSHostVersionsOnly');
            const { html } = renderMachine(exports, machine);
            assertNoForbiddenLiterals(html, 'NonMacOSHostVersionsOnly');
            assert.equal(countBadges(html).length, 0, html);
            assert.ok(html.includes('SYSTEM: NO DATA REPORTED'), html);
        });

        // ── Container truthiness: {} must behave exactly like absent ───
        // SUPERSEDES XACA-1092-002 addendum 2 (2026-09-04, Lal): that
        // ruling required XACA-1092's OWN "(version not reported)" line
        // for versions:{}, when XACA-1092 still owned version display. The
        // later ownership-boundary ruling (this ticket, 2026-09-04) hands
        // ALL version display to XACA-1031 and deletes XACA-1092's line
        // entirely -- so this shape no longer gets a fourth row from us at
        // all. versions:{} has no `aiteamforge` key, and XACA-1031's own
        // `hasInstalledVersion` gate is ALSO keyed on that key's presence
        // (identical logic in both renderers -- see XACA-1031-006), so
        // XACA-1031 has nothing to show here either: neither owner renders
        // ANY version content for this shape. This is not a weakened
        // assertion: the "NO false OUTDATED badge" check is UNCHANGED and
        // still enforced below.
        test('VersionsEmptyObjectHealthPopulated: versions:{} renders health groups normally, NO version content of our own, NO false OUTDATED badge (XACA-1031 also shows nothing here -- no aiteamforge key for either owner)', () => {
            const { html } = renderMachine(exports, HAND_BUILT_CASES.VersionsEmptyObjectHealthPopulated);
            assertNoForbiddenLiterals(html, 'VersionsEmptyObjectHealthPopulated');
            assert.ok(!html.includes('version-outdated'), 'versions:{} (no aiteamforge key) must never produce an OUTDATED badge: ' + html);
            assertNoLegacyVersionMarkers(html, 'VersionsEmptyObjectHealthPopulated');
            // versions:{} has no `aiteamforge` key, so XACA-1031's own
            // hasInstalledVersion gate is false too -- its indicator must
            // not render either. No fabricated vX.X.X token: the absence
            // of a version number is the signal distinguishing "don't know
            // the version at all" from "know the version, not its
            // currency" -- a placeholder like v0.0.0/vundefined/vnull
            // would erase that distinction, for either renderer.
            assert.ok(!html.includes('AITeamForge version'), 'no aiteamforge key present -- XACA-1031\'s own indicator has nothing to show either: ' + html);
            assert.ok(!/v\d/.test(html), 'no version number token of any kind should appear: ' + html);
            assert.ok(!html.includes('vundefined') && !html.includes('vnull'), 'must never fabricate a version token from a missing value: ' + html);
            // Health groups ARE populated in this case (cores/memory/swap/disk/load
            // all present) -- the SYSTEM toggle must still appear.
            assert.ok(html.includes('SYSTEM') && html.includes('▶'), 'health data present -> interactive SYSTEM toggle expected: ' + html);
        });

        test('VersionsEmptyObjectHealthAlsoAbsent: versions:{} plus zero health fields is the day-one shape, not a crash, and renders NO version content of our own (no aiteamforge key for XACA-1031 to show either)', () => {
            const { html } = renderMachine(exports, HAND_BUILT_CASES.VersionsEmptyObjectHealthAlsoAbsent);
            assertNoForbiddenLiterals(html, 'VersionsEmptyObjectHealthAlsoAbsent');
            assert.equal(countBadges(html).length, 0, html);
            assert.ok(html.includes('SYSTEM: NO DATA REPORTED'), html);
            assertNoLegacyVersionMarkers(html, 'VersionsEmptyObjectHealthAlsoAbsent');
            assert.ok(!html.includes('AITeamForge version'), 'no aiteamforge key present -- XACA-1031\'s own indicator has nothing to show either: ' + html);
            assert.ok(!html.includes('version-outdated'), 'no OUTDATED badge for this shape either: ' + html);
        });

        test('DiskEmptyObject: disk:{} renders as absent-disk-group (no group), not as zeros, not as a crash', () => {
            const { html } = renderMachine(exports, HAND_BUILT_CASES.DiskEmptyObject);
            assertNoForbiddenLiterals(html, 'DiskEmptyObject');
            assert.ok(!html.includes('>DISK<'), 'disk:{} has no used/free/percent key -> DISK group must not render at all: ' + html);
        });

        test('MemoryEmptyObject: memory:{} renders as absent-memory row, never "0 B / 0 B"', () => {
            const { html } = renderMachine(exports, HAND_BUILT_CASES.MemoryEmptyObject);
            assertNoForbiddenLiterals(html, 'MemoryEmptyObject');
            assert.ok(!html.includes('0 B / 0 B'), 'memory:{} must not be misread as two collected zeros: ' + html);
        });

        // ── Falsy zero must render as real data, never as "not reported" ─
        // Confirmed via `jq` against the fixture (this session): this case's
        // zeros are swap_used_bytes:0, load_average:[0,0,0], and
        // memory.pressure_percent:0 -- disk.percent is 12 here, NOT 0 (an
        // earlier draft of this test's title/comment wrongly said "disk 0%";
        // corrected to match the actual fixture data rather than an assumed
        // round number).
        test('IdleZeroHealthy: collected zeros (swap 0, load [0,0,0], memory pressure 0%) render as real values, not dashes, not a badge', () => {
            const machine = findFixture('IdleZeroHealthy');
            const { html } = renderMachine(exports, machine);
            assertNoForbiddenLiterals(html, 'IdleZeroHealthy');
            assert.equal(countBadges(html).length, 0, 'an idle, healthy machine must show no badge at all: ' + html);
            assert.ok(!html.includes('not reported'), 'every field is collected (even as zero) -- nothing should read "not reported": ' + html);
            assert.ok(html.includes('0 B'), 'a collected zero swap must render as the plain "0 B" value: ' + html);
            assert.ok(html.includes('0.00'), 'a collected zero load average must render as "0.00", not be treated as absent: ' + html);
            assert.ok(html.includes('(0% pressure)'), 'a collected zero memory.pressure_percent must render as the real "(0% pressure)" figure, not be omitted: ' + html);
        });

        // ── Array-shaped hostile load_average ───────────────────────────
        test('LoadAverageEmptyArray: an empty array degrades like an absent load_average (no LOAD group), no crash', () => {
            const { html } = renderMachine(exports, HAND_BUILT_CASES.LoadAverageEmptyArray);
            assertNoForbiddenLiterals(html, 'LoadAverageEmptyArray');
            assert.ok(!html.includes('>LOAD<'), 'load_average:[] must not render a LOAD group: ' + html);
        });

        test('LoadAverageNullElement: [null,null,null] renders "?" placeholders per element, never NaN/undefined', () => {
            const { html } = renderMachine(exports, HAND_BUILT_CASES.LoadAverageNullElement);
            assertNoForbiddenLiterals(html, 'LoadAverageNullElement');
            // buildLoadGroupHtml's fmtEntry() falls back to '?' for a
            // non-finite-number entry -- the LOAD group DOES render (the
            // array itself is non-empty) with '?' placeholders.
            assert.ok(html.includes('?'), 'a load_average array of nulls should render "?" placeholders: ' + html);
        });

        // ── Division-hazard core counts ──────────────────────────────────
        test('CoresZero: no per-core suffix, no divide-by-zero artifact (Infinity/NaN), health metric unknown not a false badge', () => {
            const { html } = renderMachine(exports, HAND_BUILT_CASES.CoresZero);
            assertNoForbiddenLiterals(html, 'CoresZero');
            assert.ok(!html.includes('Infinity'), 'cores:0 must never produce an Infinity artifact: ' + html);
            assert.ok(!html.includes('× per core'), 'cores:0 has no safe denominator -> no per-core suffix should render: ' + html);
            assert.equal(countBadges(html).filter((b) => b.includes('health-')).length, 0, 'cores:0 makes load UNEVALUABLE, not a false AT RISK/CRITICAL badge: ' + html);
        });

        test('CoresNegative: identical treatment to CoresZero (no safe denominator)', () => {
            const { html } = renderMachine(exports, HAND_BUILT_CASES.CoresNegative);
            assertNoForbiddenLiterals(html, 'CoresNegative');
            assert.ok(!html.includes('× per core'), html);
            assert.equal(countBadges(html).filter((b) => b.includes('health-')).length, 0, html);
        });

        // ── HTML injection in hostname -- untrusted, reporter-controlled ─
        test('HostnameHtmlInjectionNoSystem: hostname is escaped even on the absent-system path', () => {
            const { html } = renderMachine(exports, HAND_BUILT_CASES.HostnameHtmlInjectionNoSystem);
            assert.ok(!html.includes('<img'), 'raw <img> tag must never reach rendered HTML: ' + html);
            assert.ok(html.includes('&lt;img'), 'hostname must be HTML-escaped: ' + html);
        });

        test('HostnameHtmlInjectionWithSystem: hostname is escaped on the fully-populated, CRITICAL-badge path too', () => {
            const { html } = renderMachine(exports, HAND_BUILT_CASES.HostnameHtmlInjectionWithSystem);
            assert.ok(!html.includes('<svg'), 'raw <svg> tag must never reach rendered HTML, even alongside a real badge: ' + html);
            assert.ok(html.includes('&lt;svg'), 'hostname must be HTML-escaped: ' + html);
            assert.ok(html.includes('health-critical'), 'sanity: this case is expected to trigger the CRITICAL badge (swap far over threshold): ' + html);
        });

        // ── HostileDefensive fixture case: mixed wrong types throughout ──
        test('HostileDefensive: wrong-typed cores/load_average/disk.free, null swap, non-boolean outdated -- degrades, never crashes, never fabricates a badge', () => {
            const machine = findFixture('HostileDefensive');
            const { html } = renderMachine(exports, machine);
            assertNoForbiddenLiterals(html, 'HostileDefensive');
            // disk.percent:25 is a genuine number and is the ONLY evaluable
            // metric (cores is a string -> load unknown; swap is null ->
            // swap unknown) -- 25 is well under the 85 warning threshold,
            // so overall health is 'healthy': no health badge.
            assert.equal(countBadges(html).filter((b) => b.includes('health-')).length, 0, 'disk 25% is healthy and the only evaluable metric -- no badge expected: ' + html);
            // outdated: "yes" (a string) must fall into the "unknown" bucket,
            // never match the `=== true` branch.
            assert.ok(!html.includes('version-outdated'), 'a non-boolean outdated value must never produce an OUTDATED badge: ' + html);
            assert.ok(html.includes('update status unknown'), 'a non-boolean outdated value must render the unknown-state version line: ' + html);
        });
    });
});
