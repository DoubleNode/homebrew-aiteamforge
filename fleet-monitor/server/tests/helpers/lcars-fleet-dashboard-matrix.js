//
//  lcars-fleet-dashboard-matrix.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1110-004: shared "module under test" list + capture/serialize logic
 * for the lcars2 dashboard-unification differential harness. Imported by
 * BOTH:
 *   - tests/scripts/generate-xaca-1110-004-dashboard-baseline.js (one-time,
 *     to produce the checked-in golden file, against the four CURRENT
 *     files)
 *   - tests/xaca-1110-004-dashboard-differential-harness.test.js (every
 *     run, to recompute "actual" and diff it against that golden file)
 * so the baseline and the replay can never silently drift apart -- same
 * split as tests/helpers/lcars-terminal-card-matrix.js /
 * generate-xaca-0990-001-baseline.js, which this file deliberately mirrors.
 *
 * ============================================================================
 * DASHBOARD_TARGETS -- the single knob (see lcars-fleet-dashboard-jsdom-
 * loader.js's file header for the full rationale). XACA-1110-005/-009: all
 * 4 descriptors now point `relPath` at the SAME unified module
 * (lcars2/js/lcars-fleet-dashboard-app.js); what varies per label is
 * `configGlobal`, read from that label's real per-org config file via
 * loadConfigGlobal() (D5: config-via-global) -- never a hand-duplicated JS
 * object, so this matrix can't silently drift from what a browser loads.
 * Because relPath is now identical across all 4 labels, tap-mirror
 * discovery below filters on CONFIG file existence instead (doublenode/
 * mainevent's config files are `lcars-doublenode-*`/`lcars-mainevent-*`
 * basenames, excluded from the tap same as their old app files were).
 * ============================================================================
 */
const fs = require('node:fs');
const path = require('node:path');
const { loadDashboardModule, loadConfigGlobal, MACHINE_FIXTURES } = require('./lcars-fleet-dashboard-jsdom-loader.js');

const PUBLIC_ROOT = path.join(__dirname, '..', '..', 'public');

const UNIFIED_MODULE_REL_PATH = 'lcars2/js/lcars-fleet-dashboard-app.js';

const DASHBOARD_TARGETS_ALL = [
    { label: 'academy', relPath: UNIFIED_MODULE_REL_PATH, configRelPath: 'lcars2/js/lcars-academy-config.js' },
    { label: 'doublenode', relPath: UNIFIED_MODULE_REL_PATH, configRelPath: 'lcars2/js/lcars-doublenode-config.js' },
    { label: 'mainevent', relPath: UNIFIED_MODULE_REL_PATH, configRelPath: 'lcars2/js/lcars-mainevent-config.js' },
    { label: 'all', relPath: UNIFIED_MODULE_REL_PATH, configRelPath: 'lcars2/js/lcars-all-config.js' }
];
// Same tap-mirroring existence filter every suite in this directory uses
// (XACA-0139 debranding excludes doublenode + mainevent from the tap
// mirror) -- keeps this matrix correct in both dev-team and the tap instead
// of throwing ENOENT there. Filters on the CONFIG file now (relPath -- the
// unified module -- exists identically for every label in both repos).
const DASHBOARD_TARGETS = DASHBOARD_TARGETS_ALL
    .filter((t) => fs.existsSync(path.join(PUBLIC_ROOT, t.configRelPath)))
    .map((t) => Object.assign({}, t, { configGlobal: loadConfigGlobal(t.configRelPath) }));

if (DASHBOARD_TARGETS.length !== 4 && DASHBOARD_TARGETS.length !== 2) {
    // 4 in dev-team (all files present), 2 in the tap (academy + all only --
    // see DASHBOARD_TARGETS_ALL comment). Anything else is a silent partial
    // discovery this harness must not paper over.
    throw new Error(
        'lcars-fleet-dashboard-matrix: DASHBOARD_TARGETS resolved to ' + DASHBOARD_TARGETS.length +
            ' target(s) -- expected 4 (dev-team) or 2 (tap). Found: ' +
            JSON.stringify(DASHBOARD_TARGETS.map((t) => t.relPath))
    );
}

// A division registry code with NO STATIC_ORGS entry and no team-registry
// hit -- shared/js/lcars-org-resolution.js's resolve() returns 'UNKNOWN' for
// it, which is the ONLY path that makes getGroupColor()'s per-file
// resolveColor(group, unmappedOrgColor) argument observable (D3): every
// REGISTERED division resolves to a known org and never reaches the
// fallback branch at all. Without a fixture division exercising this
// branch, the differential harness could pass 4/4 today and still miss a
// D3 wiring regression in the unified module -- this is deliberately here
// to prevent that gap, not incidental fixture noise.
const UNMAPPED_DIVISION_CODE = 'ghost-team-xyz';

// One shared `divisions` object fed to renderDivisions() for every target
// (bypassing filterData() deliberately -- filterData's own behavior is
// covered separately by computeFilterDataResults() below). Exercises: an
// LCARS-terminal team (session name matches /lcars/i), a non-LCARS online
// team with a theme color, a service-only LCARS team (session-less,
// lcars_service present), an idle-registered team (XACA-1002), an org-name
// / team-name XSS pair, and the UNMAPPED_DIVISION_CODE division so D3's
// unmappedOrgColor argument is actually reached.
function buildPopulatedDivisionsFixture() {
    return {
        academy: {
            total_sessions: 2,
            projects: {
                core: {
                    teams: {
                        'team-lcars-terminal': {
                            sessions: [{
                                name: 'academy-lcars-main',
                                hostname: 'lcars-host.example.test',
                                windows: 3,
                                uptime_display: '3h 12m',
                                machine_status: 'online',
                                theme_color: '#3fa7ff'
                            }]
                        },
                        'team-plain-online': {
                            sessions: [{
                                name: 'academy-plain',
                                hostname: 'plain-host.example.test',
                                windows: 1,
                                uptime_display: '45m',
                                machine_status: 'online',
                                theme_color: '#ff8800'
                            }]
                        }
                    }
                }
            }
        },
        dns: {
            total_sessions: 0,
            projects: {
                core: {
                    teams: {
                        'team-service-only': {
                            sessions: [],
                            lcars_service: { hostname: 'svc.example.test', port: 8080, reachable: true }
                        },
                        'team-idle': {
                            sessions: [],
                            idle_registered: { teamName: 'Idle Team', lastSeen: '2026-08-01T00:00:00.000Z' }
                        }
                    }
                }
            }
        },
        command: {
            total_sessions: 1,
            projects: {
                core: {
                    teams: {
                        'team-offline': {
                            sessions: [{
                                name: 'command-main',
                                hostname: 'offline-host.example.test',
                                windows: 0,
                                uptime_display: '0m',
                                machine_status: 'offline'
                            }]
                        }
                    }
                }
            }
        },
        // XSS metachars in BOTH the division code (-> organization heading,
        // textContent-only per XACA-0970) and a team name (-> escapeHtml
        // sink) in one division, so a single fixture covers both injection
        // points at once.
        '<img src=x onerror=1>-xss-div': {
            total_sessions: 1,
            projects: {
                core: {
                    teams: {
                        '<script>alert(1)</script>': {
                            sessions: [{
                                name: 'xss-session',
                                hostname: 'xss-host.example.test',
                                windows: 1,
                                uptime_display: '1m',
                                machine_status: 'online'
                            }]
                        }
                    }
                }
            }
        }
    };
}

function withUnmappedDivision(divisions) {
    const copy = Object.assign({}, divisions);
    copy[UNMAPPED_DIVISION_CODE] = {
        total_sessions: 0,
        projects: { core: { teams: { 'team-unmapped-org': { sessions: [], idle_registered: { teamName: 'Unmapped', lastSeen: '2026-08-01T00:00:00.000Z' } } } } }
    };
    return copy;
}

const POPULATED_DIVISIONS_FIXTURE = withUnmappedDivision(buildPopulatedDivisionsFixture());

// getDivisionPriority() battery (D2): every key in the static priority map,
// plus unmapped/prefix-fallback codes the design decision's proof table
// walks through explicitly. teamConfig is left at its default (null) for
// every target -- including 'all' -- which is exactly the condition D2's
// equivalence proof requires ("with teamConfig === null, the `all`
// algorithm and the three-file algorithm return the identical value for
// every possible input").
const PRIORITY_CODES = [
    'command', 'android', 'firebase', 'ios',
    'academy', 'dns', 'freelance', 'legal', 'legal-coparenting',
    'freelance-doublenode-starwords', 'legal-someothersuffix',
    'unregistered-code', UNMAPPED_DIVISION_CODE,
    'COMMAND', 'Freelance'
];

// A fixture fleet-wide payload for filterData() -- divisions both inside
// and outside every target's CONFIG.divisions, plus machines whose
// sessions span both. Independent, hand-computed expected results live in
// the test file (not here) -- filterData()'s correctness is checked
// against a real oracle, not a self-captured golden value, so that
// assertion is non-vacuous even before any golden file exists.
function buildFilterDataFixture() {
    return {
        fleet: {
            total_machines: 2,
            online_machines: 1,
            offline_machines: 1,
            total_sessions: 3,
            divisions: {
                academy: { total_sessions: 1, projects: {} },
                dns: { total_sessions: 1, projects: {} },
                freelance: { total_sessions: 1, projects: {} },
                android: { total_sessions: 0, projects: {} },
                command: { total_sessions: 0, projects: {} },
                firebase: { total_sessions: 0, projects: {} },
                ios: { total_sessions: 0, projects: {} }
            },
            machines: [
                {
                    machine_id: 'filter-fixture-machine-1',
                    status: 'online',
                    sessions: [
                        { name: 's1', division: 'academy' },
                        { name: 's2', division: 'dns' },
                        { name: 's3', division: 'android' }
                    ]
                },
                {
                    machine_id: 'filter-fixture-machine-2',
                    status: 'offline',
                    sessions: [
                        { name: 's4', division: 'freelance' },
                        { name: 's5', division: 'command' }
                    ]
                }
            ]
        },
        last_update: '2026-09-06T00:00:00.000Z'
    };
}

// Serializes a captured DOM state deterministically: real jsdom
// `.innerHTML` is already a faithful, order-preserving serialization (no
// hand-rolled reconstruction needed -- see the loader file's header for why
// this differs from lcars-terminal-card-matrix.js's syntheticOuterHTML()).
function captureContainerInnerHTML(document, containerId) {
    const el = document.getElementById(containerId);
    return el ? el.innerHTML : null;
}

function findSystemToggle(window, container, machineId) {
    return container.querySelector('.status-row-system-toggle[data-machine-id="' + window.CSS.escape(machineId) + '"]');
}

// Runs the full 16-fixture x collapsed/expanded matrix against one loaded
// module and returns { [fixtureId]: { collapsed, expanded } }.
async function captureMachinesMatrix(target) {
    const results = {};
    for (const fixture of MACHINE_FIXTURES) {
        // Fresh module load per fixture -- mirrors every other suite in
        // this directory's per-case createDomStub()/loadClientApp() pattern
        // (lcars-terminal-card-matrix.js's captureCardCase, etc.) so no
        // fixture's DOM/listener state can leak into the next.
        const { window, document, mod } = await loadDashboardModule(target);
        mod.renderMachines([fixture.machine]);
        const container = document.getElementById('machines-list');
        const collapsed = container.innerHTML;

        const toggle = findSystemToggle(window, container, fixture.machine.machine_id);
        if (toggle) {
            toggle.dispatchEvent(new window.MouseEvent('click', { bubbles: true, cancelable: true }));
        }
        const expanded = document.getElementById('machines-list').innerHTML;

        results[fixture.id] = { collapsed: collapsed, expanded: expanded, hadToggle: !!toggle };
    }
    return results;
}

async function captureEmptyStates(target) {
    const { document, mod } = await loadDashboardModule(target);
    mod.renderMachines([]);
    const machinesEmpty = captureContainerInnerHTML(document, 'machines-list');
    mod.renderDivisions({});
    const divisionsEmpty = captureContainerInnerHTML(document, 'divisions-container');
    return { machinesEmpty: machinesEmpty, divisionsEmpty: divisionsEmpty };
}

async function capturePopulatedDivisions(target) {
    const { document, mod } = await loadDashboardModule(target);
    mod.renderDivisions(POPULATED_DIVISIONS_FIXTURE);
    return captureContainerInnerHTML(document, 'divisions-container');
}

async function capturePriorities(target) {
    const { mod } = await loadDashboardModule(target);
    const out = {};
    for (const code of PRIORITY_CODES) {
        out[code] = mod.getDivisionPriority(code);
    }
    return out;
}

// candyOptions.section (the 3rd config knob D5/the design decision doc
// identifies -- 'organizations' for mainevent alone, 'overview' for the
// other three) is set at the DOMContentLoaded call site, not read anywhere
// in the render path this harness otherwise drives -- there is no DOM
// output to capture it from. Rather than a source-text regex (a weaker,
// "the code merely SAYS this" check), this invokes the REAL captured
// DOMContentLoaded handler under controlled spies (LCARS_CORE.init,
// window.fetch, window.setInterval) and reads the actual argument that
// real call site passed at runtime -- see
// tests/helpers/lcars-fleet-dashboard-jsdom-loader.js's
// `captureDomContentLoaded` option. window.setInterval/window.fetch are
// stubbed so this never creates a live timer or issues a real network
// call; the handler is invoked directly (never a real 'DOMContentLoaded'
// dispatch), so nothing here can leak state past this one call.
async function captureCandySection(target) {
    const loadTarget = Object.assign({}, target, { captureDomContentLoaded: true });
    const { window, domContentLoadedHandler } = await loadDashboardModule(loadTarget);
    if (!domContentLoadedHandler) {
        throw new Error('captureCandySection: DOMContentLoaded handler was not captured for ' + target.relPath);
    }
    let captured = undefined;
    window.LCARS_CORE = { init: function (opts) { captured = opts && opts.candyOptions && opts.candyOptions.section; } };
    window.fetch = function () {
        // Shape satisfies BOTH possible consumers of this stub -- fetchFleetData()
        // (`{ fleet: {...} }`) and 'all''s fetchTeamConfig() (`{ teams: {...} }`)
        // -- so neither awaited continuation (which runs AFTER this function
        // has already returned `captured`, since LCARS_CORE.init() always
        // executes synchronously before either file's first `await`) logs a
        // spurious "Could not fetch team config" warning.
        return Promise.resolve({
            ok: true,
            json: () => Promise.resolve({ fleet: { divisions: {}, machines: [] }, teams: {} })
        });
    };
    window.setInterval = function () { return 0; };
    window.clearInterval = function () {};
    const maybePromise = domContentLoadedHandler.call(window);
    // `captured` is already set synchronously by this point on every one of
    // the 4 files' actual DOMContentLoaded bodies -- LCARS_CORE.init() runs
    // before either file's first `await` (verified by reading all four).
    // Still await a returned promise (the 'all' file's handler is async) so
    // its trailing fetchFleetData()/renderDashboard() continuation finishes
    // before this function returns, rather than dangling into whatever
    // runs next.
    if (maybePromise && typeof maybePromise.then === 'function') {
        await maybePromise;
    }
    return captured;
}

// Computes the full { [label]: { machines, emptyStates, populatedDivisions,
// priorities } } result object across every target in DASHBOARD_TARGETS.
async function computeAllResults() {
    const results = {};
    for (const target of DASHBOARD_TARGETS) {
        results[target.label] = {
            machines: await captureMachinesMatrix(target),
            emptyStates: await captureEmptyStates(target),
            populatedDivisions: await capturePopulatedDivisions(target),
            priorities: await capturePriorities(target),
            candySection: await captureCandySection(target)
        };
    }
    return results;
}

// Deterministic JSON serialization -- same recursive key-sort +
// 2-space-indent-plus-trailing-newline convention as
// lcars-terminal-card-matrix.js's stableStringify, reused verbatim (not
// re-required from that file to keep this module's public surface
// self-contained; the two implementations must stay behaviorally
// identical, which is trivial since both are a direct JSON.stringify of a
// key-sorted clone).
function sortKeysDeep(value) {
    if (Array.isArray(value)) {
        return value.map(sortKeysDeep);
    }
    if (value && typeof value === 'object') {
        const sorted = {};
        for (const key of Object.keys(value).sort()) {
            sorted[key] = sortKeysDeep(value[key]);
        }
        return sorted;
    }
    return value;
}

function stableStringify(value) {
    return JSON.stringify(sortKeysDeep(value), null, 2) + '\n';
}

module.exports = {
    PUBLIC_ROOT,
    DASHBOARD_TARGETS,
    UNMAPPED_DIVISION_CODE,
    POPULATED_DIVISIONS_FIXTURE,
    PRIORITY_CODES,
    buildFilterDataFixture,
    captureContainerInnerHTML,
    findSystemToggle,
    captureMachinesMatrix,
    captureEmptyStates,
    capturePopulatedDivisions,
    capturePriorities,
    captureCandySection,
    computeAllResults,
    stableStringify
};
