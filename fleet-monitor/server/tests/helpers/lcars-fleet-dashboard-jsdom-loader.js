//
//  lcars-fleet-dashboard-jsdom-loader.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1110-004: differential-harness loader for the 4 lcars2 dashboard app
 * files (fleet-monitor/server/public/lcars2/js/lcars-{academy,doublenode,
 * mainevent,all}-app.js), BEFORE XACA-1110-005/-009 unify them into one
 * config-parameterized module. This is the safety net the unification
 * depends on -- it must exist and pass at 100% against the four CURRENT
 * files before a single file is collapsed (XACA-1110 design decision doc,
 * D8).
 *
 * Uses jsdom with `runScripts: 'outside-only'` -- the same recipe as
 * tests/xaca-1100-013-render-machines-expand-survives-refresh.test.js,
 * tests/xaca-1031-018-version-aria-label.test.js, and
 * tests/xaca-1092-027-system-panel-sibling-close.test.js -- rather than the
 * hand-rolled DOM stub in tests/helpers/lcars-client-dom-stub.js. jsdom
 * gives a REAL `.outerHTML` (tag names, attribute order, textContent, child
 * order) with no hand-written serializer to keep honest, which is exactly
 * the granularity XACA-1100's differential proof obligation (k079: "diff
 * the full serialized DOM, not just top-level structure") requires. The
 * hand-rolled stub's own `syntheticOuterHTML()` (lcars-terminal-card-matrix.js)
 * exists because that suite predates this file and targets a narrower
 * function pair; there is no reason to reintroduce a reconstructed
 * serializer here when a real one is one `require('jsdom')` away.
 *
 * ============================================================================
 * THE SINGLE KNOB -- read this before touching anything else in this file
 * ============================================================================
 * "The module under test" is a plain descriptor object, not a hardcoded
 * path:
 *
 *   { label, relPath, configGlobal }
 *
 * TODAY (this subitem, XACA-1110-004): `configGlobal` is omitted on every
 * descriptor. Each of the 4 CURRENT files bakes its own `const CONFIG`
 * inside its IIFE and reads no external config, so there is nothing to
 * inject -- loadDashboardModule() below has NO effect when `configGlobal`
 * is absent, exactly as if this parameterization did not exist yet.
 *
 * LATER (XACA-1110-005/-009, once the unified module exists): change ONLY
 * the descriptors passed in from the TEST FILE -- point `relPath` at the
 * single `lcars2/js/lcars-fleet-dashboard-app.js` and supply `configGlobal`
 * (the six-key `window.LCARS_DASHBOARD_CONFIG` object from the design
 * decision doc's "Consolidated config surface" section: `divisions`,
 * `dashboardName`, `emptyMessage`, `machinesEmptyMessage`, `candySection`,
 * `unmappedOrgColor`). loadDashboardModule() already sets
 * `window.LCARS_DASHBOARD_CONFIG = configGlobal` BEFORE running the module
 * source when it is present (see below) -- per D5, "config is passed via a
 * global set before the module loads." NOTHING in this loader, and nothing
 * in the test file's assertions, needs to change for that switch to take
 * effect. That is what makes this harness reusable rather than rewritten.
 */

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { JSDOM } = require('jsdom');

const PUBLIC_ROOT = path.join(__dirname, '..', '..', 'public');

// Real ids the 4 files' renderMachines()/renderDivisions() look up via
// document.getElementById -- the exact set, no more. Every other id the
// real HTML pages define (total-machines, connection-status, stardate, ...)
// is read through updateElement()/updateConnectionStatus(), both of which
// guard `if (el)` before touching it (see lcars-fleet-dashboard-app.js's updateElement() /
// updateConnectionStatus()), so omitting them here is correct, not an oversight -- a real
// getElementById() miss on those ids is exactly what production sees on any
// page section this harness does not exercise.
const SKELETON_HTML =
    '<!doctype html><html><body>' +
    '<div id="organization-nav"></div>' +
    '<div id="divisions-container"></div>' +
    '<div id="machines-list"></div>' +
    '</body></html>';

// Real shared modules the 4 app files depend on for a correct render,
// loaded into the SAME vm context before the app file itself -- same
// "actual shipped source, loaded ahead of the client script" rule as
// tests/helpers/lcars-client-dom-stub.js's loadSharedTerminalCardModule/
// loadMachineHealthModule/loadFleetCoreModule. lcars-org-resolution.js is
// ADDITIONAL to that helper's list: it is required for
// getOrganizationGroup()/getGroupColor() (renderDivisions()'s org-grouping
// path) to resolve real organizations instead of logging a loud
// "UNKNOWN" fallback (lcars-fleet-dashboard-app.js's getGroupColor()) on every division.
const SHARED_MODULE_REL_PATHS = [
    'shared/js/lcars-org-resolution.js',
    'shared/js/lcars-terminal-card.js',
    'lcars2/js/lcars-machine-health.js',
    'lcars2/js/lcars-fleet-core.js'
];

function readPublicFile(relPath) {
    return fs.readFileSync(path.join(PUBLIC_ROOT, relPath), 'utf8');
}

// Loads one dashboard module descriptor into a fresh jsdom context and
// returns { window, document, mod } where `mod` is
// window.__lcarsTestExports -- renderMachines, renderDivisions, filterData
// (null for a config where it does not apply -- see D1), getDivisionPriority,
// CONFIG (the file's own baked-in config object, read-only), and
// setTeamConfig (null unless the loaded source declares a `teamConfig`
// variable -- pre-XACA-1110 this meant only lcars-all-app.js; the unified
// module (D1) now always declares `let teamConfig = null;` regardless of
// which config it is loaded with, so this is non-null for every config
// today. XACA-1100-016's CREATE_MACHINE_ITEM_EXPORT_PROPERTY typeof-guard is
// the precedent for this detection pattern).
//
// `target.srcOverride`, when given, replaces the on-disk source with an
// in-memory string BEFORE the export tail is appended -- used by the
// anti-vacuity negative control and the D1.4 async-DOMContentLoaded pinning
// test to mutate source text without ever touching a file on disk (same
// param shape as tests/xaca-1100-013-render-machines-expand-survives-refresh
// .test.js's setupApp(relPath, srcOverride)).
async function loadDashboardModule(target) {
    const dom = new JSDOM(SKELETON_HTML, {
        url: 'http://lcars-test.local/lcars2/' + path.basename(target.relPath),
        runScripts: 'outside-only',
        pretendToBeVisual: true
    });
    const window = dom.window;
    const document = window.document;

    await new Promise((resolve) => {
        if (document.readyState === 'complete') {
            resolve();
            return;
        }
        window.addEventListener('load', () => resolve(), { once: true });
    });

    const ctx = dom.getInternalVMContext();

    SHARED_MODULE_REL_PATHS.forEach(function (relPath) {
        vm.runInContext(readPublicFile(relPath), ctx, { filename: relPath });
    });

    if (target.configGlobal) {
        // D5: config-via-global, set BEFORE the module loads. Inert today
        // (no current descriptor sets this) -- see file header.
        window.LCARS_DASHBOARD_CONFIG = target.configGlobal;
    }

    // D1.4 accepted-behavior-change pinning support (XACA-1110-004): when
    // requested, intercept the app file's OWN `document.addEventListener(
    // 'DOMContentLoaded', ...)` call so the test can invoke that handler
    // directly, under fully-controlled spies (fetch/setInterval/LCARS_CORE),
    // instead of dispatching a real event -- a real dispatch would leave
    // live setInterval() timers running against this jsdom window with
    // nothing to ever clear them. The handler is captured, NOT forwarded to
    // the real addEventListener, so it never fires on its own.
    if (target.captureDomContentLoaded) {
        window.__lcarsCapturedDOMContentLoaded = null;
        const realAddEventListener = document.addEventListener.bind(document);
        document.addEventListener = function (type, handler, opts) {
            if (type === 'DOMContentLoaded') {
                window.__lcarsCapturedDOMContentLoaded = handler;
                return;
            }
            return realAddEventListener(type, handler, opts);
        };
    }

    const src = target.srcOverride !== undefined ? target.srcOverride : readPublicFile(target.relPath);
    const marker = '})();';
    const lastIdx = src.lastIndexOf(marker);
    if (lastIdx === -1) {
        throw new Error('loadDashboardModule: closing "})();" not found in ' + target.relPath);
    }

    const exportStmt =
        '\n    window.__lcarsTestExports = {' +
        ' renderMachines: renderMachines,' +
        ' renderDivisions: renderDivisions,' +
        ' filterData: (typeof filterData !== "undefined") ? filterData : null,' +
        ' getDivisionPriority: getDivisionPriority,' +
        ' CONFIG: (typeof CONFIG !== "undefined") ? CONFIG : null,' +
        ' setTeamConfig: (typeof teamConfig !== "undefined")' +
        '     ? function (v) { teamConfig = v; } : null' +
        ' };\n';

    const patched = src.slice(0, lastIdx) + exportStmt + src.slice(lastIdx);
    vm.runInContext(patched, ctx, { filename: target.relPath });

    const mod = window.__lcarsTestExports;
    if (!mod || typeof mod.renderMachines !== 'function' || typeof mod.renderDivisions !== 'function' ||
        typeof mod.getDivisionPriority !== 'function') {
        throw new Error('loadDashboardModule: required exports missing from ' + target.relPath);
    }
    return { window, document, mod, domContentLoadedHandler: window.__lcarsCapturedDOMContentLoaded || null };
}

// ============================================================================
// 16-fixture machine matrix (renderMachines() / createMachineItem() surface)
// ============================================================================
// Matches XACA-1100's regression bar in SHAPE (16 fixtures x
// collapsed/expanded = 32 combinations per module under test, full
// serialized DOM) -- see k079 (thok's knowledge base) for the original
// method this reproduces: "drive old and new with identical inputs ... diff
// the full serialized DOM ... 32/32 exact matches." createMachineItem()
// itself is already shared (XACA-1100), so this matrix is not chasing a
// per-file divergence in that function -- it exists so 005/009 cannot
// regress the CALL-SITE wiring (deps assembly, expandedSystemMachineId
// closure) while re-shaping the 4 files into 1, exactly the blind spot
// XACA-1100-013 closed for the pre-unification call sites.
//
// Every fixture is a real, internally-consistent machine object -- no
// fixture asserts a case createMachineItem()/buildSystemSectionHtml() does
// not actually branch on (see the health-threshold comments below, drawn
// from lcars-machine-health.js's own documented constants).
const MACHINE_FIXTURES = [
    {
        id: 'no_system_online',
        machine: baseMachine({ status: 'online', session_count: 1 })
        // No `system` key at all -- an old reporter that predates
        // XACA-1031's version/health feature. hasInstalledVersion is false,
        // healthResult falls back to deriveMachineHealth's own
        // no-input-evaluable path, and buildSystemSectionHtml() takes its
        // static "no data" line -- no SYSTEM toggle exists to click, so
        // this fixture's collapsed and expanded captures are IDENTICAL by
        // construction (see test file assertion), not a test bug.
    },
    {
        id: 'no_system_offline',
        machine: baseMachine({ status: 'offline', session_count: 0 })
    },
    {
        id: 'warning_status_healthy_system',
        machine: baseMachine({
            status: 'warning',
            session_count: 2,
            system: fullSystem({ memoryUsedFrac: 0.3, diskPercent: 20, swapBytes: 0, load: [0.5, 0.4, 0.3] })
        })
        // machine.status ('warning') is a SEPARATE signal from
        // deriveMachineHealth()'s metrics-derived state -- this fixture
        // pins that the two do not get conflated: the status-indicator
        // dot follows machine.status, the health badge follows the
        // (healthy) metrics. fullSystem()'s default `versionOutdated:
        // undefined` -> `outdated: false`, so this fixture ALSO covers the
        // "version current" (up-to-date, green) rendering path -- a
        // separate `version_current` fixture would be redundant with this
        // one, which is why the matrix below has 16 entries, not 17.
    },
    {
        id: 'version_outdated',
        machine: baseMachine({
            status: 'online',
            session_count: 1,
            system: fullSystem({ memoryUsedFrac: 0.4, diskPercent: 30, swapBytes: 0, load: [1, 1, 1], versionOutdated: true })
        })
    },
    {
        id: 'version_outdated_key_absent',
        machine: baseMachine({
            status: 'online',
            session_count: 1,
            // `outdated` key OMITTED (not null) -- lcars-fleet-core.js:1266's
            // hasOwnProperty check is the exact thing this pins: a null-check
            // there would silently render "unknown" as "confirmed current".
            system: fullSystem({ memoryUsedFrac: 0.4, diskPercent: 30, swapBytes: 0, load: [1, 1, 1], versionOutdatedKeyAbsent: true })
        })
    },
    {
        id: 'versions_container_empty',
        machine: baseMachine({
            status: 'online',
            session_count: 1,
            // `system.versions: {}` -- present but aiteamforge itself is
            // absent. hasInstalledVersion must be false (no "vUnknown"
            // indicator), per lcars-fleet-core.js's XACA-1031-006 bugfix
            // comment.
            system: fullSystem({ memoryUsedFrac: 0.4, diskPercent: 30, swapBytes: 0, load: [1, 1, 1], versionsEmpty: true })
        })
    },
    {
        id: 'disk_critical',
        // DISK_CRITICAL_PERCENT = 95 (lcars-machine-health.js:203).
        machine: baseMachine({
            status: 'online',
            session_count: 3,
            system: fullSystem({ memoryUsedFrac: 0.5, diskPercent: 97, swapBytes: 0, load: [1, 1, 1] })
        })
    },
    {
        id: 'disk_warning',
        // DISK_WARNING_PERCENT = 85 (lcars-machine-health.js:202).
        machine: baseMachine({
            status: 'online',
            session_count: 1,
            system: fullSystem({ memoryUsedFrac: 0.5, diskPercent: 88, swapBytes: 0, load: [1, 1, 1] })
        })
    },
    {
        id: 'swap_critical',
        // SWAP_CRITICAL_BYTES = 30 GiB (lcars-machine-health.js:194).
        machine: baseMachine({
            status: 'online',
            session_count: 1,
            system: fullSystem({ memoryUsedFrac: 0.5, diskPercent: 30, swapBytes: 32 * 1024 * 1024 * 1024, load: [1, 1, 1] })
        })
    },
    {
        id: 'swap_warning',
        // SWAP_WARNING_BYTES = 15 GiB (lcars-machine-health.js:193).
        machine: baseMachine({
            status: 'online',
            session_count: 1,
            system: fullSystem({ memoryUsedFrac: 0.5, diskPercent: 30, swapBytes: 16 * 1024 * 1024 * 1024, load: [1, 1, 1] })
        })
    },
    {
        id: 'load_high',
        machine: baseMachine({
            status: 'online',
            session_count: 1,
            system: fullSystem({ memoryUsedFrac: 0.5, diskPercent: 30, swapBytes: 0, load: [16, 15, 14], cores: 4 })
        })
    },
    {
        id: 'all_zero_values',
        // XACA-1092: a collected zero is DATA, not absence -- memory/disk/
        // load all genuinely 0.
        machine: baseMachine({
            status: 'online',
            session_count: 0,
            system: fullSystem({ memoryUsedFrac: 0, diskPercent: 0, swapBytes: 0, load: [0, 0, 0] })
        })
    },
    {
        id: 'xss_hostname',
        machine: baseMachine({
            status: 'online',
            session_count: 1,
            hostname: '<img src=x onerror=1>&"\'lcars-xss.example.test',
            system: fullSystem({ memoryUsedFrac: 0.4, diskPercent: 30, swapBytes: 0, load: [1, 1, 1] })
        })
    },
    {
        id: 'unicode_hostname',
        machine: baseMachine({
            status: 'online',
            session_count: 1,
            hostname: 'café-🚀-machine.example.test',
            system: fullSystem({ memoryUsedFrac: 0.4, diskPercent: 30, swapBytes: 0, load: [1, 1, 1] })
        })
    },
    {
        id: 'high_session_count',
        machine: baseMachine({
            status: 'online',
            session_count: 42,
            system: fullSystem({ memoryUsedFrac: 0.6, diskPercent: 40, swapBytes: 0, load: [2, 2, 2] })
        })
    },
    {
        id: 'full_healthy_baseline',
        // Same shape as tests/xaca-1100-013-render-machines-expand-survives
        // -refresh.test.js's interactiveMachine() -- kept aligned
        // deliberately so this matrix's "collapsed/expanded survives a
        // second renderMachines() call" coverage overlaps, rather than
        // silently diverging from, the existing regression bar for that
        // exact scenario.
        machine: {
            machine_id: '99999999-8888-4777-8666-555555550013',
            hostname: 'expand-survives-refresh.example.test',
            nickname: 'ExpandSurvivesRefresh',
            ip: '192.0.2.13',
            os: 'Darwin',
            status: 'online',
            first_seen: '2026-01-15T00:00:00.000Z',
            last_seen: '2026-09-04T15:00:00.000Z',
            session_count: 1,
            sessions: [],
            uptime_history: [{ timestamp: '2026-09-04T15:00:00.000Z', status: 'online', session_count: 1 }],
            system: {
                schema_version: 1,
                versions: { aiteamforge: '0.17.9', latest: '0.17.9', outdated: false },
                os_name: 'macOS',
                os_version: '27.0',
                cores: 8,
                memory: { used: 4000000000, total: 8000000000, pressure_percent: 30 },
                swap_used_bytes: 0,
                disk: { used: 100, free: 300, percent: 25 },
                load_average: [1.0, 1.0, 1.0]
            }
        }
    }
];

// Stable machine_id per fixture id so re-runs (and the negative control
// copy) are deterministic -- a real (fixed, not random) UUID-shaped string,
// distinct per fixture so 16 machines never collide if ever rendered
// together.
function machineIdFor(fixtureId) {
    const hash = String(fixtureId)
        .split('')
        .reduce(function (acc, ch) { return (acc * 31 + ch.charCodeAt(0)) >>> 0; }, 7);
    const hex = hash.toString(16).padStart(8, '0');
    return '00000000-0000-4000-8000-' + hex.padEnd(12, '0');
}

function baseMachine(overrides) {
    const id = machineIdFor(overrides.id || overrides.hostname || 'fixture');
    return Object.assign(
        {
            machine_id: id,
            hostname: 'host-' + id + '.example.test',
            nickname: null,
            ip: '192.0.2.1',
            os: 'Darwin',
            first_seen: '2026-01-01T00:00:00.000Z',
            last_seen: '2026-09-04T15:00:00.000Z',
            sessions: [],
            uptime_history: []
        },
        overrides
    );
}

function fullSystem(opts) {
    const memoryTotal = 8000000000;
    const versions = opts.versionsEmpty
        ? {}
        : {
            aiteamforge: '0.17.9',
            latest: opts.versionOutdated ? '0.18.0' : '0.17.9'
        };
    if (!opts.versionsEmpty && !opts.versionOutdatedKeyAbsent) {
        versions.outdated = !!opts.versionOutdated;
    }
    return {
        schema_version: 1,
        versions: versions,
        os_name: 'macOS',
        os_version: '27.0',
        cores: opts.cores || 8,
        memory: {
            used: Math.round(memoryTotal * opts.memoryUsedFrac),
            total: memoryTotal,
            pressure_percent: Math.round(opts.memoryUsedFrac * 100)
        },
        swap_used_bytes: opts.swapBytes,
        disk: {
            used: opts.diskPercent,
            free: 100 - opts.diskPercent,
            percent: opts.diskPercent
        },
        load_average: opts.load
    };
}

// Fix each fixture's `machine_id`/`hostname` (baseMachine ran before the
// fixture literal's own overrides were known at module-eval time above for
// entries that pass explicit hostname/system but rely on baseMachine's
// default id/hostname) -- re-derive a stable id from the fixture's `id` so
// every fixture (including the ones supplying only `status`/`session_count`
// overrides) gets a deterministic, collision-free machine_id independent of
// object key insertion order.
MACHINE_FIXTURES.forEach(function (fixture) {
    // 'full_healthy_baseline' intentionally carries its OWN hand-set
    // machine_id/hostname, matching xaca-1100-013's interactiveMachine()
    // fixture verbatim (see its own comment above) -- normalizing it here
    // would silently break that deliberate alignment. Every other fixture
    // is built via baseMachine(), which needs this pass to assign its
    // real, stable, collision-free id (baseMachine has no access to the
    // fixture's own `id` field at construction time).
    if (fixture.id === 'full_healthy_baseline') {
        return;
    }
    fixture.machine.machine_id = machineIdFor(fixture.id);
    if (!fixture.machine.hostname || /^host-00000000-/.test(fixture.machine.hostname)) {
        fixture.machine.hostname = fixture.id + '.example.test';
    }
});

// XACA-1110-004: the regression bar this harness must match (XACA-1100's
// k079 method) is stated in fixture-count terms -- "16 fixtures x
// collapsed/expanded". Assert the count here, loudly, rather than letting a
// future edit silently drift the matrix to 15 or 17 while every test that
// iterates MACHINE_FIXTURES.length keeps passing regardless of count.
if (MACHINE_FIXTURES.length !== 16) {
    throw new Error(
        'lcars-fleet-dashboard-jsdom-loader: MACHINE_FIXTURES must have exactly 16 ' +
            'entries (the XACA-1100 regression bar this harness matches) -- found ' +
            MACHINE_FIXTURES.length + '. Update this check if the bar itself changes.'
    );
}

// XACA-1110-005/-009: reads one of the 4 real per-org config files
// (lcars2/js/lcars-{academy,doublenode,mainevent,all}-config.js) in an
// isolated sandbox and returns the `window.LCARS_DASHBOARD_CONFIG` object
// it assigns -- the single source of truth for a target's `configGlobal`
// (D5: config-via-global). Reading the REAL shipped file rather than a
// hand-duplicated JS literal means this matrix can never silently drift
// from what a browser actually loads.
function loadConfigGlobal(relPath) {
    const sandbox = { window: {} };
    vm.createContext(sandbox);
    vm.runInContext(readPublicFile(relPath), sandbox, { filename: relPath });
    if (!sandbox.window.LCARS_DASHBOARD_CONFIG) {
        throw new Error('loadConfigGlobal: ' + relPath + ' did not set window.LCARS_DASHBOARD_CONFIG');
    }
    return sandbox.window.LCARS_DASHBOARD_CONFIG;
}

module.exports = {
    PUBLIC_ROOT,
    SKELETON_HTML,
    SHARED_MODULE_REL_PATHS,
    loadDashboardModule,
    loadConfigGlobal,
    MACHINE_FIXTURES,
    machineIdFor
};
