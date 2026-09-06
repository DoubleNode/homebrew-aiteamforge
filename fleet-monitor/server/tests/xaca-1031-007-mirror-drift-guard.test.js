//
//  xaca-1031-007-mirror-drift-guard.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1031 subitem 007 (Testing & Debugging) -- DRIFT GUARD between
 * server.js's real isVersionOutdated/normalizeSystemBlock/projectSystemBlock
 * and their copies in tests/helpers/app-factory.js.
 *
 * ── WHY THIS FILE EXISTS (coordinator correction, post-completion review) ──
 * tests/helpers/app-factory.js does NOT require() or otherwise load
 * server.js -- `grep -n "require(" tests/helpers/app-factory.js` shows only
 * express/cors/path/fs/os. isVersionOutdated, normalizeSystemBlock, and
 * projectSystemBlock are COPIED into app-factory.js verbatim (server.js has
 * no module.exports and calls app.listen() unconditionally at import time,
 * same reason every other suite in this directory uses this mirror instead
 * of require()-ing server.js directly -- see xaca-1031-007-system-block.
 * test.js's own header for that background).
 *
 * That means xaca-1031-007-system-block.test.js's route-level and
 * isVersionOutdated/normalizeSystemBlock unit tests exercise ONLY THE COPY.
 * A defect introduced in server.js's real implementation, with the mirror
 * left untouched, cannot turn any of those tests red -- they never load
 * server.js at all. Verified directly: mutating server.js's real
 * projectSystemBlock to drop its allowlist-equivalent logic, with
 * app-factory.js untouched, leaves every test in xaca-1031-007-system-block.
 * test.js green (see this ticket's retrospective / PR discussion for the
 * live demonstration). That is precisely the state e77798e1 shipped in:
 * server.js changed, the mirror did not, and nothing failed.
 *
 * This file is the fix for THAT mechanism, not a replacement for the
 * functional suite -- same relationship as scripts/lcars-host-ownership.sh's
 * "Part A0" drift guard (tests/test-xaca-1063-013-022-ownership-gates.sh) to
 * its own functional assertions: Part A0 does not re-test what
 * _lho_host_matches DOES, it proves the copy of _lho_host_matches is
 * SEMANTICALLY IDENTICAL to canonical kanban-helpers.sh's
 * _kb_host_matches, so a future edit to one that is not mirrored to the
 * other is caught immediately, independent of whatever functional tests
 * happen to exist. This file is that same technique -- extract each
 * function body from BOTH files by BRACE-DEPTH matching (never a fixed
 * line range, which drifts the moment either file gets an unrelated edit
 * above the function), normalize away whitespace/indentation/comments, and
 * compare. Same technique, not a second invention.
 *
 * ── SCOPE: what this guard covers, and what it explicitly does NOT ────────
 * isVersionOutdated and normalizeSystemBlock are top-level, non-closure
 * functions in BOTH files -- their extracted+normalized bodies are expected
 * to be, and are, byte-for-byte identical (verified below).
 *
 * projectSystemBlock is DIFFERENT: in server.js it is a top-level function
 * that closes over the module-scope `latestTapVersion` cache via the
 * top-level `getLatestTapVersion()`. In app-factory.js it is defined INSIDE
 * createApp() (see that file's own comment at its definition) so it can
 * close over a PER-TEST-INSTANCE `getLatestTapVersion()` that reads an
 * injectable `latestTapVersionState.value` instead of a real network-backed
 * cache -- the deterministic test seam xaca-1031-007-system-block.test.js's
 * fail-safe test depends on. After normalization (which strips indentation
 * entirely, so the extra nesting level costs nothing) projectSystemBlock's
 * OWN body text -- the `const out = {}`, the schema_version copy, the
 * hasStoredVersions gate, the `const latest = getLatestTapVersion();` call
 * site, the outdated-key-presence logic -- IS byte-comparable and IS
 * asserted identical below. What this guard CANNOT and does NOT cover is
 * getLatestTapVersion() ITSELF: that is a different, deliberately
 * DIFFERENT-BY-DESIGN function in each file (real cache vs. injectable
 * test state), so a defect purely inside server.js's real
 * getLatestTapVersion()/fetchLatestTapVersion() (e.g. a broken cache TTL
 * calculation) is invisible to both this guard and to
 * xaca-1031-007-system-block.test.js -- neither loads server.js. That is a
 * real, stated gap, not one this file can close without requiring
 * server.js directly (which would need its own app.listen()-avoidance
 * refactor, out of scope for this subitem).
 *
 * Also out of scope, same reason: everything in server.js this ticket did
 * NOT touch (POST /api/status's non-system fields, every other route).
 * This guard is scoped to exactly the three functions e77798e1 added/
 * changed for the `system` block.
 *
 * ── The extraction technique is naive in one further way, stated plainly ──
 * _normalizeFnBody strips everything from the first unescaped `//` to end
 * of line on every line, to neutralize comment-text drift (the mirror's
 * comments were deliberately shortened in one place -- see
 * projectSystemBlock's `hasStoredVersions` early-return line -- when they
 * were written; that is allowed drift, code-behavior drift is not). This
 * would incorrectly truncate a line whose STRING CONTENT itself contains
 * `//` (e.g. a URL literal). Verified by inspection: none of the three
 * functions' bodies contain such a literal. Same caveat, same acceptance,
 * as tests/test-xaca-1063-013-022-ownership-gates.sh's own _extract_fn
 * comment ("verified there to have no nested {}/heredocs in the functions
 * it targets").
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const SERVER_JS = path.join(__dirname, '..', 'server.js');
const APP_FACTORY = path.join(__dirname, 'helpers', 'app-factory.js');

// _extractFn <file> <fnName> -- brace-depth function-body extraction,
// anchored on the "function <fnName>(" declaration line REGARDLESS of its
// indentation (so it finds projectSystemBlock whether it is top-level in
// server.js or nested inside createApp() in app-factory.js), and NEVER on a
// fixed line range -- both files' line numbers move independently as either
// one is edited.
function _extractFn(filePath, fnName) {
    const src = fs.readFileSync(filePath, 'utf8');
    const lines = src.split('\n');
    const startRe = new RegExp('^\\s*function\\s+' + fnName + '\\s*\\(');
    let startIdx = -1;
    for (let i = 0; i < lines.length; i++) {
        if (startRe.test(lines[i])) { startIdx = i; break; }
    }
    if (startIdx === -1) return null;

    let depth = 0;
    const collected = [];
    for (let i = startIdx; i < lines.length; i++) {
        const line = lines[i];
        collected.push(line);
        for (const ch of line) {
            if (ch === '{') depth++;
            else if (ch === '}') depth--;
        }
        if (depth === 0) break; // matching closing brace found
    }
    return collected.join('\n');
}

// _normalizeFnBody -- strips per-line trailing comments (from the first
// unescaped "//" onward), leading/trailing whitespace, and blank lines, so
// the comparison is semantic (code + inline logic) rather than textual-
// including-indentation-and-comments. See this file's header for the one
// documented limitation (a "//" inside a string literal would be
// mis-stripped; verified absent from all three target functions).
function _normalizeFnBody(text) {
    return text
        .split('\n')
        .map((l) => l.replace(/\/\/.*$/, ''))
        .map((l) => l.trim())
        .filter((l) => l.length > 0)
        .join('\n');
}

// XACA-1091 review finding: the four isValid* helpers below were mirrored into
// app-factory.js but NOT listed here, which reopened the exact blind spot this
// guard exists to close. Demonstrated by mutation: making isValidPercent() in
// server.js accept everything left ALL 945 tests green, because the behavioural
// suites exercise the app-factory.js MIRROR and only this guard ties that mirror
// back to the shipped file. A validator outside this list can be broken in
// server.js with nothing anywhere going red.
//
// RULE FOR FUTURE EDITS: any function duplicated between server.js and
// app-factory.js belongs in this array. Adding the mirror copy without adding
// the name here is worse than not mirroring at all -- it looks protected.
const DRIFT_GUARDED_FUNCTIONS = [
    'isVersionOutdated',
    'normalizeSystemBlock',
    'projectSystemBlock',
    'isValidByteCount',
    'isValidPercent',
    'isValidLoadAverageComponent',
    'isValidPositiveInteger',
];

for (const fnName of DRIFT_GUARDED_FUNCTIONS) {
    test(`drift guard: ${fnName} extracted a non-empty body from server.js`, () => {
        const body = _extractFn(SERVER_JS, fnName);
        assert.ok(body, `_extractFn found no "function ${fnName}(" in server.js -- extraction anchor is gone`);
        assert.ok(body.length > 0);
    });

    test(`drift guard: ${fnName} extracted a non-empty body from app-factory.js`, () => {
        const body = _extractFn(APP_FACTORY, fnName);
        assert.ok(body, `_extractFn found no "function ${fnName}(" in app-factory.js -- extraction anchor is gone`);
        assert.ok(body.length > 0);
    });

    test(`drift guard: ${fnName} in app-factory.js is semantically identical to server.js's real implementation`, () => {
        const serverBody = _normalizeFnBody(_extractFn(SERVER_JS, fnName));
        const mirrorBody = _normalizeFnBody(_extractFn(APP_FACTORY, fnName));
        assert.equal(mirrorBody, serverBody,
            `${fnName} has drifted between server.js (the shipped implementation) and tests/helpers/app-factory.js ` +
            `(the mirror every route-level test in this directory exercises). Update the mirror to match server.js's ` +
            `real implementation -- see app-factory.js's "mirrored VERBATIM from server.js" comments.`);
    });
}

// ============================================================================
// Negative control: mutate one extracted+normalized body in memory and
// confirm the comparison actually detects it -- proves the assertion above
// is not vacuously equal (e.g. two empty strings, or a comparison that
// silently short-circuits). Mirrors tests/test-xaca-1063-013-022-ownership-
// gates.sh's own negative control for the identical drift-guard shape.
// ============================================================================

test('drift guard negative control: the comparison DOES detect a deliberate divergence (harness is not vacuous)', () => {
    const serverBody = _normalizeFnBody(_extractFn(SERVER_JS, 'isVersionOutdated'));
    // Target the FINAL "return false;" (the equal-versions case, immediately
    // before the function's closing brace) via an end-anchored regex --
    // "return false;" also appears mid-body (the loop's `if (c > l) return
    // false;`), so a plain, non-anchored string replace would silently hit
    // the wrong occurrence.
    const mutated = serverBody.replace(/return false;\n\}$/, 'return true; // MUTATED for negative control\n}');
    assert.notEqual(mutated, serverBody, 'sanity: the mutation must actually change the string, or this negative control proves nothing');
    assert.throws(() => {
        assert.equal(mutated, serverBody);
    }, assert.AssertionError, 'a deliberately mutated body must fail assert.equal against the unmutated original');
});

// ============================================================================
// Documents the scope boundary explicitly, as an executable assertion
// rather than only a comment: getLatestTapVersion is NOT one of the three
// drift-guarded functions, and its two implementations are expected to
// DIFFER (real network-backed cache vs. injectable test seam) -- so this
// test asserts the DIFFERENCE exists, guarding against a future reader
// assuming (wrongly) that the drift guard above also covers it.
// ============================================================================

test('scope boundary: getLatestTapVersion is deliberately NOT drift-guarded -- its two implementations differ by design', () => {
    const serverBody = _normalizeFnBody(_extractFn(SERVER_JS, 'getLatestTapVersion'));
    const mirrorBody = _normalizeFnBody(_extractFn(APP_FACTORY, 'getLatestTapVersion'));
    assert.ok(serverBody, 'expected server.js to define getLatestTapVersion (the real cache)');
    assert.ok(mirrorBody, 'expected app-factory.js to define getLatestTapVersion (the test seam)');
    assert.notEqual(mirrorBody, serverBody,
        'server.js\'s getLatestTapVersion (real network-backed cache) and app-factory.js\'s (a synchronous read of ' +
        'the injectable latestTapVersionState.value) are expected to differ -- if this ever starts passing, the ' +
        'test seam has been replaced with a real network call, which would break the deterministic fail-safe test ' +
        'in xaca-1031-007-system-block.test.js.');
});
