//
//  xaca-1089-005-server-mirror-drift-guard.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1089-005 (Testing & Debugging): drift guard for the two XACA-1089
 * route handlers that tests/helpers/app-factory.js hand-mirrors from
 * server.js.
 *
 * WHY THIS SUITE EXISTS: server.js has no `module.exports` and calls
 * `app.listen()` unconditionally at require-time -- it cannot be
 * `require()`d by a test process. Every test in this directory therefore
 * exercises app-factory.js's mirrored copy of each handler, never the file
 * that ships. XACA-1089-002 (POST /api/team-register) and XACA-1089-003
 * (GET /api/registered-teams + enrichTeamMachineEntry) both hand-mirrored
 * their handlers into app-factory.js, and a manual diff at the time of
 * XACA-1089-005 confirmed they agree with server.js today -- but nothing
 * enforced that, and the next edit to either side (a bug fix applied to
 * only one copy, a new validation branch added to only one copy) would
 * desync silently: every existing route test would stay green because it
 * is asserting behavior against the mirror, not against what ships.
 *
 * This is the same failure shape as XACA-1063's `_hc_host_matches` /
 * `_kb_host_matches` mirror (tests/test-xaca-1063-host-ownership-gate.sh),
 * and uses the same fix shape: extract each side's body, normalize away the
 * documented allowed divergences (comments, console.* logging, the
 * saveRegisteredTeams() persistence call), assert equality, and prove the
 * comparison is load-bearing with a negative control that deliberately
 * desyncs one side and confirms the guard actually flips to failing.
 *
 * SCOPE: the two XACA-1089 handlers only (POST /api/team-register,
 * GET /api/registered-teams, and the enrichTeamMachineEntry() helper the
 * GET handler depends on). app-factory.js mirrors many other server.js
 * routes that predate XACA-1089 -- a suite-wide drift guard covering all of
 * them was judged out of scope for this subitem; see the XACA-1089-005
 * retrospective for the reasoning and a precise follow-up recommendation.
 */

const fs = require('fs');
const path = require('path');
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { extractBlock, normalizeBody, stripInlineComment } = require('./helpers/mirror-drift');

const SERVER_JS = path.join(__dirname, '..', 'server.js');
const APP_FACTORY_JS = path.join(__dirname, 'helpers', 'app-factory.js');

const serverSrc = fs.readFileSync(SERVER_JS, 'utf8');
const mirrorSrc = fs.readFileSync(APP_FACTORY_JS, 'utf8');

const PAIRS = [
    {
        name: 'POST /api/team-register',
        re: /app\.post\(\s*['"]\/api\/team-register['"][^\n]*=>\s*\{/,
    },
    {
        name: 'GET /api/registered-teams',
        re: /app\.get\(\s*['"]\/api\/registered-teams['"][^\n]*=>\s*\{/,
    },
    {
        name: 'enrichTeamMachineEntry',
        re: /function enrichTeamMachineEntry\(entry\)\s*\{/,
    },
];

test('mirror-drift guard: extraction produces non-empty bodies on both sides', () => {
    for (const { name, re } of PAIRS) {
        const serverBody = extractBlock(serverSrc, re);
        const mirrorBody = extractBlock(mirrorSrc, re);
        assert.ok(serverBody.length > 20, `${name}: server.js block unexpectedly tiny/empty`);
        assert.ok(mirrorBody.length > 20, `${name}: app-factory.js block unexpectedly tiny/empty`);
    }
});

test('mirror-drift guard: app-factory.js handlers are semantically identical to server.js', () => {
    for (const { name, re } of PAIRS) {
        const serverBody = normalizeBody(extractBlock(serverSrc, re));
        const mirrorBody = normalizeBody(extractBlock(mirrorSrc, re));
        assert.equal(
            mirrorBody,
            serverBody,
            `${name}: tests/helpers/app-factory.js's mirrored handler has drifted from ` +
            `server.js's real one. Every test exercising this route is testing the ` +
            `MIRROR, not the shipping file -- re-sync app-factory.js's copy (or, if the ` +
            `divergence is deliberate, add it to ALLOWED_DIVERGENT_LINES in ` +
            `tests/helpers/mirror-drift.js with a comment explaining why it is safe).`
        );
    }
});

test('mirror-drift guard negative control: the comparison actually detects a deliberate divergence', () => {
    // Proves the equality check above is load-bearing, not an
    // always-true comparator (e.g. a typo'd variable compared to itself).
    // Mirrors tests/test-xaca-1063-host-ownership-gate.sh's own drift-guard
    // negative control.
    for (const { name, re } of PAIRS) {
        const serverBody = normalizeBody(extractBlock(serverSrc, re));
        const mutated = `${serverBody} EXTRA_TOKEN_THAT_MUST_NOT_MATCH`;
        assert.notEqual(
            mutated,
            serverBody,
            `${name}: negative control itself is broken -- mutated body equals original`
        );
    }
});

test('mirror-drift guard negative control: known-allowed divergences do not mask unrelated drift', () => {
    // Proves the ALLOWED_DIVERGENT_LINES/console.*/comment filters are not
    // so broad they would hide a real behavioral change smuggled in on an
    // adjacent line. Deliberately mutates a non-filtered, behaviorally
    // significant line (the field list destructured from req.body) on one
    // side only and confirms the guard's equality check still fails.
    const { re } = PAIRS[0]; // POST /api/team-register
    const serverBody = normalizeBody(extractBlock(serverSrc, re));
    const desynced = serverBody.replace('const { team,', 'const { team, EXTRA_FIELD_INJECTED,');
    assert.notEqual(
        desynced,
        serverBody,
        'negative control: a mutation to a real (non-comment, non-console, non-persistence) ' +
        'line was not detected -- the normalizer is stripping more than the documented allowlist'
    );
});


// ---------------------------------------------------------------------------
// XACA-1089-015 ([Review], PR #832): normalizeBody() stripped only WHOLE-LINE
// comments, so `foo(); // note` present in one copy and absent from the other
// tripped a false drift alarm. Fixed by stripInlineComment().
//
// The naive fix (`line.split('//')[0]`) is worse than the bug: server.js's
// team-register handler contains, INSIDE a guarded block,
//     fleetMonitorUrl: fleetMonitorUrl || 'http://localhost:3000',
// which naive stripping truncates to `'http:` -- discarding the rest of the
// line from comparison on BOTH sides, so the guard would pass having compared
// less than it claims. The string-awareness below is the load-bearing part,
// and the second test is what proves it.
// ---------------------------------------------------------------------------

test('XACA-1089-015: an inline trailing comment is stripped, so it cannot trip a false drift alarm', () => {
    assert.equal(stripInlineComment('foo(); // note'), 'foo();');
    assert.equal(stripInlineComment('const x = 1;   // trailing'), 'const x = 1;');
    // A comment-only line collapses to empty and is dropped by the length filter.
    assert.equal(stripInlineComment('// whole-line comment'), '');
    // Two bodies differing ONLY by an inline comment must normalize equal.
    assert.equal(
        normalizeBody('const a = 1;\nfoo(); // only here\nconst b = 2;'),
        normalizeBody('const a = 1;\nfoo();\nconst b = 2;')
    );
});

test('XACA-1089-015 REGRESSION GUARD: a // inside a string literal is NOT treated as a comment', () => {
    // The exact line from server.js's guarded team-register block.
    const real = "fleetMonitorUrl: fleetMonitorUrl || 'http://localhost:3000',";
    assert.equal(stripInlineComment(real), real, 'a URL inside a string must survive untouched');

    assert.equal(stripInlineComment('const u = "https://example.com";'), 'const u = "https://example.com";');
    assert.equal(stripInlineComment('const t = `a//b`;'), 'const t = `a//b`;');
    // Escaped quote must not end the string early and expose the // to stripping.
    assert.equal(stripInlineComment("const s = 'it\\'s http://x';"), "const s = 'it\\'s http://x';");
    // String first, THEN a real trailing comment: only the comment goes.
    assert.equal(stripInlineComment("const u = 'http://x'; // note"), "const u = 'http://x';");
});

test('XACA-1089-015: the real guarded blocks still normalize non-empty and still match', () => {
    // Belt-and-braces: the fix must not have emptied or altered the real
    // comparison the rest of this suite depends on.
    for (const { name, re } of PAIRS) {
        const a = normalizeBody(extractBlock(serverSrc, re));
        const b = normalizeBody(extractBlock(mirrorSrc, re));
        assert.ok(a.length > 0, `${name}: server-side block normalized to empty`);
        assert.ok(b.length > 0, `${name}: mirror-side block normalized to empty`);
        assert.equal(a, b, `${name}: blocks must still match after the 015 fix`);
    }
    // The URL line the naive fix would have truncated must survive normalization.
    assert.ok(
        normalizeBody(extractBlock(serverSrc, PAIRS[0].re)).includes("'http://localhost:3000'"),
        'the http:// string literal inside the guarded block must survive normalizeBody'
    );
});
