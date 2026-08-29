//
//  xaca-1002-001-registered-team-buckets.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1002 subitem 006 (Testing & Debugging) -- SERVER-side regression
 * coverage for "materialize a card for every registered-but-currently-idle
 * terminal": resolveRegistryKey() and ensureRegisteredTeamBuckets() in
 * server.js, wired into parseFleetData() after the machine/session loop and
 * before machineList is built.
 *
 * ── Why this tests tests/helpers/app-factory.js's mirror, not server.js
 *    directly ──────────────────────────────────────────────────────────
 * server.js has no module.exports and calls app.listen() unconditionally at
 * import time (see every other suite in this directory's header comment on
 * why they all use app-factory.js's createApp() instead of require()-ing
 * server.js). resolveRegistryKey and ensureRegisteredTeamBuckets have been
 * added to that mirror in the SAME diff as this test file, copied verbatim
 * from server.js's real implementation (see app-factory.js's own "Mirrored
 * from server.js's ... -- MUST stay in sync" comments at both the
 * resolveRegistryKey definition and the ensureRegisteredTeamBuckets
 * definition inside createApp()). Every number asserted below was measured
 * by actually RUNNING this code against the fixtures (never hand-derived
 * from the ticket description) -- see the "count it, don't assert it"
 * discipline in skills/Project Planner/SKILL.md.
 *
 * ── Fixtures ───────────────────────────────────────────────────────────
 * tests/fixtures/xaca-1002-live-registered-teams.json and
 * xaca-1002-live-fleet.json are verbatim captures of GET /api/registered-
 * teams and GET /api/fleet against the REAL deployed fleet-monitor, taken
 * BEFORE any XACA-1002 code existed (so xaca-1002-live-fleet.json's
 * fleet.divisions is exactly the "before" state ensureRegisteredTeamBuckets
 * must be applied to, not a value this suite invents). Copied into the repo
 * so this suite has no dependency on /private/tmp or a live network call.
 *
 * ── ensureRegisteredTeamBuckets() is exercised TWO ways here ────────────
 *   1. Directly: `createApp({ registeredTeams }).ensureRegisteredTeamBuckets
 *      (divisions)` against a hand-built or fixture-derived `divisions`
 *      object -- this is how the +28/never-overwrite/roster-bounded/
 *      malformed/determinism tests below work, since it lets a test control
 *      the exact pre-existing `divisions` shape and `registeredTeams` Map
 *      insertion order without needing to replay a full machine/session
 *      history through POST /api/status.
 *   2. Through the full pipeline: GET /api/fleet via supertest, exercising
 *      parseFleetData()'s real call site (after the machine loop, before
 *      machineList) -- used where a test needs live-session interplay.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { createApp, helpers } = require('./helpers/app-factory.js');

const fleetFixture = require('./fixtures/xaca-1002-live-fleet.json');
const regFixture = require('./fixtures/xaca-1002-live-registered-teams.json');

// ============================================================================
// Shared helpers
// ============================================================================

function countTeams(divisions) {
    let n = 0;
    for (const dk of Object.getOwnPropertyNames(divisions)) {
        for (const pk of Object.getOwnPropertyNames(divisions[dk].projects)) {
            n += Object.getOwnPropertyNames(divisions[dk].projects[pk].teams).length;
        }
    }
    return n;
}

function perDivisionTeamCounts(divisions) {
    const out = {};
    for (const dk of Object.getOwnPropertyNames(divisions)) {
        let n = 0;
        for (const pk of Object.getOwnPropertyNames(divisions[dk].projects)) {
            n += Object.getOwnPropertyNames(divisions[dk].projects[pk].teams).length;
        }
        out[dk] = n;
    }
    return out;
}

function cloneFixtureDivisions() {
    return structuredClone(fleetFixture.fleet.divisions);
}

function registeredTeamsFromFixture() {
    const map = new Map();
    for (const t of regFixture.teams) {
        map.set(t.team, t);
    }
    return map;
}

function snapshotLiveDivisions(divisions) {
    const liveDivisions = {};
    for (const dk of Object.getOwnPropertyNames(divisions)) {
        const projects = (divisions[dk] && divisions[dk].projects) || {};
        liveDivisions[dk] = Object.getOwnPropertyNames(projects);
    }
    return liveDivisions;
}

// ============================================================================
// Harness sanity -- the fixture-derived numbers every test below depends on,
// MEASURED here (not asserted from the ticket description) so a corrupted
// or truncated fixture fails loudly and specifically instead of producing
// confusing downstream failures.
// ============================================================================

test('harness sanity: live fixtures resolve to 11 registered teams and 68 pre-existing team cards', () => {
    assert.equal(regFixture.teams.length, 11, 'expected 11 teams in the registered-teams fixture');
    assert.equal(countTeams(cloneFixtureDivisions()), 68, 'expected 68 pre-existing team cards in the fleet fixture');
});

// ============================================================================
// Requirement 1: resolver table -- all 11 live registry keys resolve to the
// EXACT (division, project) pair documented in the XACA-1002 ticket.
// liveDivisions is snapshotted from the fixture's pre-idle-materialization
// divisions, exactly as ensureRegisteredTeamBuckets() itself does -- see
// server.js's header comment on resolveRegistryKey for why rule 1 (exact
// division match) depends on reading a SNAPSHOT, not the live divisions.
// ============================================================================

const LIVE_DIVISIONS_SNAPSHOT = snapshotLiveDivisions(fleetFixture.fleet.divisions);

// project: undefined means "_default" (resolveRegistryKey's own contract --
// see server.js's header comment); expressed as undefined here rather than
// the literal string '_default' so this table matches what resolveRegistryKey
// actually returns.
const RESOLVER_TABLE = [
    { key: 'dns', division: 'dns', project: undefined },
    { key: 'academy', division: 'academy', project: undefined },
    { key: 'android', division: 'android', project: undefined },
    { key: 'command', division: 'command', project: undefined },
    { key: 'firebase', division: 'firebase', project: undefined },
    { key: 'ios', division: 'ios', project: undefined },
    { key: 'freelance-doublenode-appplanning', division: 'freelance-appplanning', project: 'doublenode-appplanning' },
    { key: 'freelance-doublenode-starwords', division: 'freelance-starwords', project: 'doublenode-starwords' },
    { key: 'freelance-doublenode-workstats', division: 'freelance-workstats', project: 'doublenode-workstats' },
    { key: 'legal-coparenting', division: 'legal', project: 'coparenting' },
    { key: 'medical-general', division: 'medical', project: 'general' }
];

test('harness sanity: RESOLVER_TABLE covers exactly the fixture registry keys, no more, no fewer', () => {
    const fixtureKeys = regFixture.teams.map((t) => t.team).sort();
    const tableKeys = RESOLVER_TABLE.map((r) => r.key).sort();
    assert.deepEqual(tableKeys, fixtureKeys, 'RESOLVER_TABLE must cover exactly the 11 live registry keys');
});

for (const { key, division, project } of RESOLVER_TABLE) {
    test(`resolveRegistryKey('${key}') -> division '${division}', project ${project === undefined ? '_default (undefined)' : "'" + project + "'"}`, () => {
        const result = helpers.resolveRegistryKey(key, LIVE_DIVISIONS_SNAPSHOT);
        assert.equal(result.division, division);
        assert.equal(result.project, project);
    });
}

// ============================================================================
// Requirement 2: +28 buckets against the live fixture, 7/7/7/7 split,
// total_sessions unchanged at every division.
// ============================================================================

test('ensureRegisteredTeamBuckets on the live fixture: exactly +28 buckets (7 dns, 7 x 3 freelance), total_sessions unchanged', () => {
    const divisions = cloneFixtureDivisions();
    const before = countTeams(divisions);
    const beforePerDivision = perDivisionTeamCounts(divisions);
    const beforeTotalSessions = {};
    for (const dk of Object.getOwnPropertyNames(divisions)) {
        beforeTotalSessions[dk] = divisions[dk].total_sessions;
    }

    const factory = createApp({ registeredTeams: registeredTeamsFromFixture() });
    factory.ensureRegisteredTeamBuckets(divisions);

    const after = countTeams(divisions);
    assert.equal(before, 68, 'precondition: fixture must start at 68 (see harness sanity test)');
    assert.equal(after, 96, 'expected exactly 96 team cards after materializing idle buckets');
    assert.equal(after - before, 28, 'expected exactly +28 new team cards');

    const afterPerDivision = perDivisionTeamCounts(divisions);
    const diffs = {};
    for (const dk of Object.getOwnPropertyNames(afterPerDivision)) {
        const d = afterPerDivision[dk] - (beforePerDivision[dk] || 0);
        if (d !== 0) diffs[dk] = d;
    }
    assert.deepEqual(
        diffs,
        { dns: 7, 'freelance-appplanning': 7, 'freelance-starwords': 7, 'freelance-workstats': 7 },
        'expected the +28 to land as exactly 7 new cards in each of dns/freelance-appplanning/freelance-starwords/freelance-workstats and 0 anywhere else'
    );

    // total_sessions must be byte-identical for every division -- an idle
    // bucket contributes zero sessions.
    for (const dk of Object.getOwnPropertyNames(divisions)) {
        assert.equal(
            divisions[dk].total_sessions,
            beforeTotalSessions[dk] || 0,
            `division '${dk}' total_sessions must be unchanged`
        );
    }
});

test('NEGATIVE CONTROL: without calling ensureRegisteredTeamBuckets, the +28 assertion fails (proves the positive test is not vacuous)', () => {
    const divisions = cloneFixtureDivisions();
    const before = countTeams(divisions);
    // Pre-XACA-1002 behavior: parseFleetData never called ensureRegisteredTeamBuckets
    // at all, so `divisions` is never touched here.
    const after = countTeams(divisions);
    assert.throws(
        () => assert.equal(after - before, 28),
        /28/,
        'the +28 assertion must fail when the idle-bucket materialization step never runs'
    );
});

// ============================================================================
// Requirement 3: never-overwrite -- a bucket already created by a live
// session (or an lcars_service) is left completely untouched and does NOT
// gain an idle_registered marker, even when a registry entry names that
// exact team.
// ============================================================================

test('ensureRegisteredTeamBuckets never overwrites a bucket a live session already claimed', () => {
    const liveSession = { name: 'academy-engineering', windows: 2 };
    const divisions = {
        academy: {
            name: 'academy',
            total_sessions: 1,
            projects: {
                _default: {
                    name: null,
                    teams: {
                        // Already claimed by a live session -- 'engineering' is
                        // ALSO one of the registry's terminal names below.
                        engineering: { name: 'engineering', sessions: [liveSession] }
                    }
                }
            }
        }
    };
    const registeredTeams = new Map();
    registeredTeams.set('academy', {
        team: 'academy',
        teamName: 'STARFLEET ACADEMY',
        terminals: { engineering: {}, training: {} }, // engineering collides, training is new
        registeredAt: '2026-01-01T00:00:00.000Z',
        lastSeen: '2026-01-02T00:00:00.000Z'
    });

    const factory = createApp({ registeredTeams });
    factory.ensureRegisteredTeamBuckets(divisions);

    const engineering = divisions.academy.projects._default.teams.engineering;
    assert.deepEqual(engineering.sessions, [liveSession], 'the live session must be untouched');
    assert.ok(!('idle_registered' in engineering), 'a live bucket must never gain an idle_registered marker');

    const training = divisions.academy.projects._default.teams.training;
    assert.ok(training, 'the genuinely new terminal must still be materialized');
    assert.equal(training.idle_registered.team, 'academy');
    assert.equal(training.idle_registered.terminal, 'training');
});

test('ensureRegisteredTeamBuckets never overwrites a bucket an lcars_service already claimed', async () => {
    const machines = new Map();
    machines.set('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', {
        machine_id: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
        hostname: 'runabout',
        ip: '10.0.0.5',
        os: 'Darwin',
        status: 'online',
        sessions: [],
        session_count: 0,
        first_seen: new Date().toISOString(),
        last_seen: new Date().toISOString(),
        uptime_history: [],
        lcars_services: [
            { session_name: 'academy-lcars', division: 'academy', project: null, team: 'lcars', port: 8203, reachable: true, source: 'portfile' }
        ]
    });
    const registeredTeams = new Map();
    registeredTeams.set('academy', {
        team: 'academy',
        teamName: 'STARFLEET ACADEMY',
        terminals: { lcars: {}, chancellor: {} }, // 'lcars' collides with the service record
        registeredAt: '2026-01-01T00:00:00.000Z',
        lastSeen: '2026-01-02T00:00:00.000Z'
    });
    const { app } = createApp({ machines, registeredTeams });

    const res = await request(app).get('/api/fleet');
    assert.equal(res.status, 200);

    const lcarsTeam = res.body.fleet.divisions.academy.projects._default.teams.lcars;
    assert.equal(lcarsTeam.lcars_service.port, 8203, 'the service-only bucket must be untouched');
    assert.ok(!('idle_registered' in lcarsTeam), 'a bucket already claimed by lcars_service must never gain an idle_registered marker');

    const chancellorTeam = res.body.fleet.divisions.academy.projects._default.teams.chancellor;
    assert.ok(chancellorTeam, 'the genuinely new terminal must still be materialized');
    assert.equal(chancellorTeam.idle_registered.team, 'academy');
});

test('NEGATIVE CONTROL: a never-overwrite-less variant clobbers the live session (proves the guard is load-bearing)', () => {
    // A hand-rolled scratch reproduction of ensureRegisteredTeamBuckets with
    // the never-overwrite guard removed -- NOT the real implementation, and
    // never wired into app-factory.js or server.js. Exists only to prove the
    // positive test above is not vacuous: without the guard, the exact same
    // input produces a clobbered bucket.
    function buggyEnsureNoOverwriteGuard(divisions, registeredTeams) {
        for (const [registryKey, teamData] of registeredTeams.entries()) {
            const terminals = teamData.terminals;
            const division = registryKey;
            const projectKey = '_default';
            if (!divisions[division]) divisions[division] = { name: division, total_sessions: 0, projects: {} };
            if (!divisions[division].projects[projectKey]) divisions[division].projects[projectKey] = { name: null, teams: {} };
            for (const terminalName of Object.keys(terminals)) {
                // BUG: no "already exists" check -- always (re)writes.
                divisions[division].projects[projectKey].teams[terminalName] = {
                    name: terminalName,
                    sessions: [],
                    idle_registered: { team: registryKey, terminal: terminalName }
                };
            }
        }
    }

    const liveSession = { name: 'academy-engineering', windows: 2 };
    const divisions = {
        academy: { name: 'academy', total_sessions: 1, projects: { _default: { name: null, teams: { engineering: { name: 'engineering', sessions: [liveSession] } } } } }
    };
    const registeredTeams = new Map();
    registeredTeams.set('academy', { team: 'academy', terminals: { engineering: {} } });

    buggyEnsureNoOverwriteGuard(divisions, registeredTeams);

    const engineering = divisions.academy.projects._default.teams.engineering;
    assert.throws(
        () => assert.deepEqual(engineering.sessions, [liveSession]),
        undefined,
        'without the never-overwrite guard, the live session must have been clobbered'
    );
    assert.ok('idle_registered' in engineering, 'the buggy variant mislabels the live bucket as idle -- exactly the regression the real guard prevents');
});

// ============================================================================
// Requirement 4: roster-bounded -- a terminal absent from the registry's
// `terminals` object is never materialized. No phantom team can appear.
// ============================================================================

test('ensureRegisteredTeamBuckets is bounded strictly by the registry terminals object -- no phantom teams', () => {
    const divisions = {};
    const registeredTeams = new Map();
    registeredTeams.set('academy', {
        team: 'academy',
        teamName: 'STARFLEET ACADEMY',
        terminals: { chancellor: {}, engineering: {} },
        registeredAt: 'r',
        lastSeen: 'l'
    });

    const factory = createApp({ registeredTeams });
    factory.ensureRegisteredTeamBuckets(divisions);

    const materialized = Object.getOwnPropertyNames(divisions.academy.projects._default.teams).sort();
    assert.deepEqual(materialized, ['chancellor', 'engineering'], 'exactly the two registered terminals, nothing invented');
    assert.ok(!('training' in divisions.academy.projects._default.teams), 'a terminal not in the registry must never appear');
    assert.ok(!('medical' in divisions.academy.projects._default.teams), 'a terminal not in the registry must never appear');
});

// ============================================================================
// Requirement 5: malformed-registry resilience -- a bad record is skipped
// individually without aborting the whole report.
// ============================================================================

test('ensureRegisteredTeamBuckets skips malformed registry records individually without crashing or aborting', () => {
    const divisions = {};
    const registeredTeams = new Map();
    registeredTeams.set('nullrecord', null);
    registeredTeams.set('missingterm', { teamName: 'x' }); // no terminals field at all
    registeredTeams.set('arrayterm', { teamName: 'x', terminals: ['a', 'b'] }); // terminals is an array
    registeredTeams.set('emptyname', { teamName: 'x', terminals: { '': {}, valid: {} } }); // one empty terminal name
    registeredTeams.set('goodrecord', { teamName: 'Good', terminals: { alpha: {} }, registeredAt: 'r', lastSeen: 'l' });

    const factory = createApp({ registeredTeams });
    assert.doesNotThrow(() => factory.ensureRegisteredTeamBuckets(divisions), 'a malformed record must never abort the whole pass');

    assert.ok(!('nullrecord' in divisions), 'a null registry record must be skipped entirely');
    assert.ok(!('missingterm' in divisions), 'a record with no terminals object must be skipped entirely');
    assert.ok(!('arrayterm' in divisions), 'a record whose terminals is an array must be skipped entirely');

    assert.ok('emptyname' in divisions, 'a record with one bad terminal name must still process its OTHER, valid terminals');
    const emptynameTeams = Object.getOwnPropertyNames(divisions.emptyname.projects._default.teams);
    assert.deepEqual(emptynameTeams, ['valid'], 'the empty-string terminal name must be skipped, the valid one kept');

    assert.ok('goodrecord' in divisions, 'a well-formed record sharing the same pass as malformed ones must still be processed');
    assert.deepEqual(Object.getOwnPropertyNames(divisions.goodrecord.projects._default.teams), ['alpha']);
});

// ============================================================================
// Requirement 6: DETERMINISM / insertion-order regression -- DO NOT SKIP.
// resolveRegistryKey's rule 1 must read a SNAPSHOT of divisions taken once
// at the top of ensureRegisteredTeamBuckets, not the live, still-mutating
// `divisions` object -- otherwise the answer depends on registeredTeams'
// Map insertion order.
// ============================================================================

function buildFooRegistry(order) {
    const registeredTeams = new Map();
    const data = {
        'foo-bar': { team: 'foo-bar', teamName: 'FooBar', terminals: { alpha: {}, beta: {} }, registeredAt: 'r', lastSeen: 'l' },
        foo: { team: 'foo', teamName: 'Foo', terminals: { alpha: {}, beta: {} }, registeredAt: 'r', lastSeen: 'l' }
    };
    for (const key of order) {
        registeredTeams.set(key, data[key]);
    }
    return registeredTeams;
}

function runFooCase(order) {
    const divisions = {};
    const factory = createApp({ registeredTeams: buildFooRegistry(order) });
    factory.ensureRegisteredTeamBuckets(divisions);
    return divisions;
}

test('ensureRegisteredTeamBuckets is insertion-order independent for registry keys "foo-bar"/"foo" against empty live divisions', () => {
    const orderA = runFooCase(['foo-bar', 'foo']);
    const orderB = runFooCase(['foo', 'foo-bar']);

    assert.deepStrictEqual(orderA, orderB, 'the materialized bucket set must be identical regardless of Map insertion order');

    for (const divisions of [orderA, orderB]) {
        assert.equal(countTeams(divisions), 4, 'expected exactly 4 buckets: foo/_default/{alpha,beta} and foo/bar/{alpha,beta}');
        assert.deepEqual(
            Object.getOwnPropertyNames(divisions.foo.projects._default.teams).sort(),
            ['alpha', 'beta'],
            'foo/_default must hold the "foo" registry entry\'s terminals'
        );
        assert.deepEqual(
            Object.getOwnPropertyNames(divisions.foo.projects.bar.teams).sort(),
            ['alpha', 'beta'],
            'foo/bar must hold the "foo-bar" registry entry\'s terminals'
        );
        assert.equal(divisions.foo.projects._default.teams.alpha.idle_registered.team, 'foo');
        assert.equal(divisions.foo.projects.bar.teams.alpha.idle_registered.team, 'foo-bar');
    }
});

test('NEGATIVE CONTROL: reading LIVE (mutating) divisions instead of a snapshot reproduces the original order-dependent card-losing bug', () => {
    // Hand-rolled scratch reproduction of the PRE-FIX resolveRegistryKey/
    // ensureRegisteredTeamBuckets pairing: rule 1 reads `divisions` directly
    // (the object THIS SAME LOOP is mutating) instead of a snapshot taken up
    // front. NOT the real implementation -- never wired into app-factory.js
    // or server.js. Exists only to prove the determinism test above is not
    // vacuous: reproduces the exact "foo-bar processed first silently merges
    // foo's terminals into foo/bar, losing 2 cards" failure server.js's own
    // header comment on ensureRegisteredTeamBuckets describes.
    function buggyEnsureLiveRead(divisions, registeredTeams) {
        for (const [registryKey, teamData] of registeredTeams.entries()) {
            const terminals = teamData.terminals;
            let division, project;
            if (divisions[registryKey]) {
                // BUG: reads the live, still-mutating `divisions` for rule 1.
                const projects = Object.getOwnPropertyNames(divisions[registryKey].projects);
                project = projects.indexOf('_default') !== -1 ? undefined : (projects.length === 1 ? projects[0] : undefined);
                division = registryKey;
            } else if (registryKey.indexOf('-') !== -1) {
                const hyphenIdx = registryKey.indexOf('-');
                division = registryKey.slice(0, hyphenIdx);
                project = registryKey.slice(hyphenIdx + 1);
            } else {
                division = registryKey;
                project = undefined;
            }
            const projectKey = project || '_default';
            if (!divisions[division]) divisions[division] = { name: division, total_sessions: 0, projects: {} };
            if (!divisions[division].projects[projectKey]) divisions[division].projects[projectKey] = { name: project, teams: {} };
            for (const terminalName of Object.keys(terminals)) {
                if (divisions[division].projects[projectKey].teams[terminalName]) continue;
                divisions[division].projects[projectKey].teams[terminalName] = { name: terminalName, sessions: [], idle_registered: { team: registryKey } };
            }
        }
    }

    function runBuggyFooCase(order) {
        const divisions = {};
        buggyEnsureLiveRead(divisions, buildFooRegistry(order));
        return divisions;
    }

    const buggyOrderFooBarFirst = runBuggyFooCase(['foo-bar', 'foo']);
    const buggyOrderFooFirst = runBuggyFooCase(['foo', 'foo-bar']);

    // This is the actual failure shape: processing "foo-bar" first creates
    // division "foo" with sole project "bar"; the buggy rule-1 match then
    // makes "foo" (processed second) land its terminals in foo/bar too,
    // where they already exist -- so "foo"'s terminals are silently DROPPED.
    assert.equal(countTeams(buggyOrderFooBarFirst), 2, 'pre-fix bug: "foo-bar" first collapses to only 2 buckets, losing "foo"\'s cards');
    assert.equal(countTeams(buggyOrderFooFirst), 4, 'pre-fix bug: "foo" first happens to produce the correct 4 buckets');

    assert.throws(
        () => assert.deepStrictEqual(buggyOrderFooBarFirst, buggyOrderFooFirst),
        undefined,
        'the determinism assertion must fail against the pre-fix live-divisions-read implementation'
    );
    assert.throws(
        () => assert.equal(countTeams(buggyOrderFooBarFirst), 4),
        /4/,
        'the exact-4-buckets assertion must fail for the "foo-bar" first order under the pre-fix bug'
    );
});

// ============================================================================
// SOURCE PARITY: run the assertions against the REAL server.js, not the mirror
// ============================================================================
/**
 * Everything above exercises app-factory.js's mirror of resolveRegistryKey /
 * ensureRegisteredTeamBuckets, for the reason given in this file's header:
 * server.js calls app.listen() unconditionally at import time, so it cannot
 * simply be require()'d.
 *
 * That leaves a hole this block closes. The mirror's "MUST stay in sync with
 * the real implementation" comments are PROSE, not an enforced invariant --
 * nothing fails if someone edits server.js and forgets app-factory.js. The
 * whole suite above would stay green while production shipped the old logic:
 * a passing test over a broken artifact, which is strictly worse than no test,
 * because it actively reports safety. This codebase has repeated datapoints on
 * exactly that sibling-copy drift shape -- server.js's own resolveDivisionKey
 * header comment cites it as the reason that rule has ONE implementation.
 *
 * So: extract the two functions' real source text out of server.js and run the
 * highest-value assertions against THOSE. Reading server.js as text is already
 * house-accepted precedent (see xaca-0395-005-auth-wiring.test.js). This does
 * not replace the mirror-based tests -- it pins the mirror to the artifact, so
 * a drift makes THIS fail loudly instead of passing silently.
 *
 * ensureRegisteredTeamBuckets references `registeredTeams` as a free variable
 * (matching server.js's module scope), so it is injected as the sandbox
 * function's parameter of the same name.
 */
const fs = require('node:fs');
const path = require('node:path');

function extractFunctionSource(src, name) {
    const start = src.indexOf('function ' + name + '(');
    assert.notEqual(start, -1, 'server.js must define function ' + name + '()');
    let depth = 0;
    let j = src.indexOf('{', start);
    for (; j < src.length; j++) {
        if (src[j] === '{') { depth++; } else if (src[j] === '}') { depth--; if (depth === 0) { break; } }
    }
    assert.equal(depth, 0, 'braces must balance while extracting ' + name + '()');
    return src.slice(start, j + 1);
}

function loadRealServerImplementation(registeredTeams) {
    const serverSrc = fs.readFileSync(path.join(__dirname, '..', 'server.js'), 'utf8');
    const body = [
        extractFunctionSource(serverSrc, 'resolveDivisionKey'),
        extractFunctionSource(serverSrc, 'ensureTeamBucket'),
        extractFunctionSource(serverSrc, 'resolveRegistryKey'),
        extractFunctionSource(serverSrc, 'ensureRegisteredTeamBuckets')
    ].join('\n\n');
    // eslint-disable-next-line no-new-func
    return new Function(
        'registeredTeams',
        body + '\nreturn { resolveRegistryKey, ensureRegisteredTeamBuckets };'
    )(registeredTeams);
}

function realRegisteredTeamsMap() {
    const m = new Map();
    for (const t of regFixture.teams) { m.set(t.team, t); }
    return m;
}

function snapshotLiveDivisions(divisions) {
    const snap = {};
    for (const dk of Object.getOwnPropertyNames(divisions)) {
        const projects = (divisions[dk] && divisions[dk].projects) || {};
        snap[dk] = Object.getOwnPropertyNames(projects);
    }
    return snap;
}

function countAllTeams(divisions) {
    let n = 0;
    for (const dk of Object.getOwnPropertyNames(divisions)) {
        for (const pk of Object.getOwnPropertyNames(divisions[dk].projects)) {
            n += Object.getOwnPropertyNames(divisions[dk].projects[pk].teams).length;
        }
    }
    return n;
}

test('SOURCE PARITY: the REAL server.js resolveRegistryKey resolves all 11 live registry keys correctly', () => {
    const real = loadRealServerImplementation(realRegisteredTeamsMap());
    const divisions = JSON.parse(JSON.stringify(fleetFixture.fleet.divisions));
    const snap = snapshotLiveDivisions(divisions);

    const EXPECTED = {
        'dns': ['dns', '_default'],
        'academy': ['academy', '_default'],
        'android': ['android', '_default'],
        'command': ['command', '_default'],
        'firebase': ['firebase', '_default'],
        'ios': ['ios', '_default'],
        'freelance-doublenode-appplanning': ['freelance-appplanning', 'doublenode-appplanning'],
        'freelance-doublenode-starwords': ['freelance-starwords', 'doublenode-starwords'],
        'freelance-doublenode-workstats': ['freelance-workstats', 'doublenode-workstats'],
        'legal-coparenting': ['legal', 'coparenting'],
        'medical-general': ['medical', 'general']
    };

    for (const registryKey of Object.getOwnPropertyNames(EXPECTED)) {
        const r = real.resolveRegistryKey(registryKey, snap);
        assert.equal(r.division, EXPECTED[registryKey][0], registryKey + ' -> division');
        assert.equal(r.project || '_default', EXPECTED[registryKey][1], registryKey + ' -> project');
    }
});

test('SOURCE PARITY: the REAL server.js adds exactly 28 idle buckets and inflates no session count', () => {
    const real = loadRealServerImplementation(realRegisteredTeamsMap());
    const divisions = JSON.parse(JSON.stringify(fleetFixture.fleet.divisions));

    const before = countAllTeams(divisions);
    const totalsBefore = JSON.stringify(
        Object.fromEntries(Object.getOwnPropertyNames(divisions).map(dk => [dk, divisions[dk].total_sessions]))
    );

    real.ensureRegisteredTeamBuckets(divisions);

    const after = countAllTeams(divisions);
    const totalsAfter = JSON.stringify(
        Object.fromEntries(Object.getOwnPropertyNames(divisions).map(dk => [dk, divisions[dk].total_sessions]))
    );

    assert.equal(before, 68, 'live fixture baseline team-card count');
    assert.equal(after, 96, 'after materialization');
    assert.equal(after - before, 28, 'REAL server.js must add exactly the 28 measured invisible terminals');
    assert.equal(totalsAfter, totalsBefore, 'no division total_sessions may change');

    const perDivision = {};
    for (const dk of Object.getOwnPropertyNames(divisions)) {
        for (const pk of Object.getOwnPropertyNames(divisions[dk].projects)) {
            for (const tk of Object.getOwnPropertyNames(divisions[dk].projects[pk].teams)) {
                const t = divisions[dk].projects[pk].teams[tk];
                if (t.idle_registered) {
                    perDivision[dk] = (perDivision[dk] || 0) + 1;
                    assert.ok(Array.isArray(t.sessions) && t.sessions.length === 0, 'idle bucket has empty sessions');
                    assert.equal(t.lcars_service, undefined, 'idle bucket must never carry an lcars_service');
                }
            }
        }
    }
    assert.deepStrictEqual(perDivision, {
        'dns': 7,
        'freelance-appplanning': 7,
        'freelance-starwords': 7,
        'freelance-workstats': 7
    }, 'the 7/7/7/7 split measured against the real deployment');
});

test('SOURCE PARITY: the REAL server.js is insertion-order deterministic (snapshot, not live divisions)', () => {
    function runRealWithOrder(order) {
        const rt = new Map();
        for (const k of order) {
            rt.set(k, { team: k, teamName: k.toUpperCase(), terminals: { alpha: {}, beta: {} }, registeredAt: 't', lastSeen: 't' });
        }
        const real = loadRealServerImplementation(rt);
        const divisions = {};
        real.ensureRegisteredTeamBuckets(divisions);
        const out = [];
        for (const dk of Object.getOwnPropertyNames(divisions)) {
            for (const pk of Object.getOwnPropertyNames(divisions[dk].projects)) {
                for (const tk of Object.getOwnPropertyNames(divisions[dk].projects[pk].teams)) {
                    out.push(dk + '/' + pk + '/' + tk);
                }
            }
        }
        return out.sort();
    }

    const barFirst = runRealWithOrder(['foo-bar', 'foo']);
    const fooFirst = runRealWithOrder(['foo', 'foo-bar']);

    assert.deepStrictEqual(barFirst, fooFirst, 'REAL server.js must be independent of registry Map insertion order');
    assert.equal(barFirst.length, 4, 'both registries keep their own buckets; none are merged away');
    assert.deepStrictEqual(barFirst, [
        'foo/_default/alpha', 'foo/_default/beta', 'foo/bar/alpha', 'foo/bar/beta'
    ]);
});

// ============================================================================
// GATE FOLLOW-UPS: XACA-1002-015 / -016 (edge cases raised in PR #789 review)
// ============================================================================

test('XACA-1002-015: a hyphenated OWN id splits on the first hyphen — the fleet-wide convention, pinned', () => {
    const real = loadRealServerImplementation(realRegisteredTeamsMap());

    // A team whose own id contains a hyphen but is NOT <div>-<project>.
    // Rule 3 splits it, matching lcars-ui/server.py's _split_team_id() and
    // kb-init-team's ASSET_DIR default, both of which split any team id on
    // its first hyphen with no per-team table. This test PINS that agreement:
    // if someone "fixes" resolveRegistryKey to stop splitting, it diverges
    // from asset resolution and this fails loudly.
    assert.deepStrictEqual(
        real.resolveRegistryKey('main-event', {}),
        { division: 'main', project: 'event' },
        'no live division => rule 3 splits at the first hyphen (fleet convention)'
    );

    // Rule 1 is the ONLY escape, and only once that division is already live.
    // Documented as structurally unavailable to a never-yet-started team --
    // which is exactly the population this function serves. Recorded, not fixed:
    // a liveDivisions check on the split half would make an idle team land in
    // its own division then JUMP divisions on first start.
    assert.deepStrictEqual(
        real.resolveRegistryKey('main-event', { 'main-event': ['_default'] }),
        { division: 'main-event', project: undefined },
        'once live as its own division, rule 1 wins and the id is NOT split'
    );

    // Guard against silent regression of the real-world case rule 3 exists for.
    assert.deepStrictEqual(
        real.resolveRegistryKey('legal-coparenting', {}),
        { division: 'legal', project: 'coparenting' }
    );
});

test('XACA-1002-016: degenerate registry keys resolve safely and are never materialized', () => {
    const real = loadRealServerImplementation(realRegisteredTeamsMap());

    // Empty key: rule 4 returns an empty division, which ensureRegisteredTeamBuckets'
    // `if (!division)` skip-guard drops. Unreachable through POST /api/team-register
    // (its truthy check rejects it) but reachable from legacy persisted registry
    // data written before that validation existed.
    assert.deepStrictEqual(real.resolveRegistryKey('', {}), { division: '', project: undefined });

    // "freelance-" with nothing after it: rest is the empty string, so the project
    // collapses to _default via the falsy fallback rather than producing a bucket
    // keyed on an empty project name.
    const bare = real.resolveRegistryKey('freelance-', {});
    assert.equal(bare.division, 'freelance', 'resolveDivisionKey treats an empty project as no project');
    assert.ok(!bare.project, 'empty project must be falsy so projectKey collapses to _default');

    // End-to-end: a registry carrying BOTH degenerate keys must materialize
    // nothing for the empty one and must not throw.
    const rt = new Map();
    rt.set('', { team: '', teamName: 'EMPTY', terminals: { alpha: {} }, registeredAt: 't', lastSeen: 't' });
    rt.set('freelance-', { team: 'freelance-', teamName: 'BARE', terminals: { beta: {} }, registeredAt: 't', lastSeen: 't' });
    const realWithDegenerate = loadRealServerImplementation(rt);

    const divisions = {};
    assert.doesNotThrow(() => realWithDegenerate.ensureRegisteredTeamBuckets(divisions));

    assert.equal(divisions[''], undefined, 'the empty-key entry must materialize NO division');
    assert.ok(divisions['freelance'], 'the bare freelance- entry still materializes under _default');
    assert.ok(divisions['freelance'].projects['_default'].teams['beta'], 'its terminal lands in _default');
    assert.equal(countAllTeams(divisions), 1, 'exactly one bucket total — the empty key contributed none');
});
