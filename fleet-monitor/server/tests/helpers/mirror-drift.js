//
//  mirror-drift.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * Shared extraction/normalization helpers for the XACA-1089-005 mirror-drift
 * guard (tests/xaca-1089-005-server-mirror-drift-guard.test.js).
 *
 * WHY THIS EXISTS: server.js has no `module.exports` and calls `app.listen()`
 * unconditionally at require-time (no `require.main === module` guard), so
 * it cannot be `require()`d by a test process. Every route test in this
 * directory therefore exercises tests/helpers/app-factory.js's hand-mirrored
 * copy of each handler, NOT the file that ships. Nothing before this guard
 * enforced that the two copies stay in agreement -- a future edit to either
 * side's handler could silently desync while every existing test stays
 * green (it is asserting against the mirror, not the original). This is the
 * same shape of risk as lcars-health-check.sh's byte-for-byte-guarded mirror
 * of kanban-helpers.sh's host-comparison primitives (tests/test-xaca-1063-
 * host-ownership-gate.sh, 84 assertions / 9 negative controls) -- same
 * fix shape too: extract each side's body, normalize away the KNOWN allowed
 * divergences, and assert equality, proven non-vacuous by a negative
 * control that deliberately desyncs one side and confirms the guard flips.
 *
 * SCOPE: covers the two XACA-1089 handlers (POST /api/team-register,
 * GET /api/registered-teams) plus the enrichTeamMachineEntry() helper GET
 * depends on. It does not attempt to cover every mirrored handler in
 * app-factory.js (there are many, most pre-dating XACA-1089) -- see the
 * ticket's own subitem 005 scope note for why a suite-wide guard was judged
 * out of scope for this pass.
 *
 * LIMITATION (documented, not hidden -- same posture as the shell
 * precedent's own accepted-limitations section): extractBlock() is a
 * brace-depth TEXT matcher, not a JS parser. It counts every `{`/`}`
 * character in the slice, including ones inside string/template literals.
 * Verified by inspection that none of the three extracted bodies contain an
 * UNBALANCED brace inside a string (the one template-literal interpolation,
 * `${vaultStore.SLUG_RE}`, contributes a balanced pair). A future edit that
 * introduces a literal `{` or `}` inside a string without its pair on the
 * same extracted body would miscount and could throw or silently truncate --
 * the throw case fails loud (desirable); the silent-truncation case would
 * not. Re-verify by inspection if either handler's string literals change.
 */

/**
 * Extract the `{ ... }` block that begins at the first `{` found at or after
 * the first match of `startRe` in `src`, tracking brace depth back to zero.
 * Throws if `startRe` does not match -- deliberately: a route/function
 * rename should fail the guard loudly, not silently compare nothing.
 *
 * @param {string} src
 * @param {RegExp} startRe
 * @returns {string} the block including its enclosing braces
 */
function extractBlock(src, startRe) {
    const m = startRe.exec(src);
    if (!m) {
        throw new Error(`mirror-drift: start pattern not found: ${startRe}`);
    }
    const braceIdx = src.indexOf('{', m.index);
    if (braceIdx === -1) {
        throw new Error(`mirror-drift: no '{' found after match of ${startRe}`);
    }
    let depth = 0;
    let i = braceIdx;
    for (; i < src.length; i++) {
        if (src[i] === '{') depth++;
        else if (src[i] === '}') {
            depth--;
            if (depth === 0) { i++; break; }
        }
    }
    if (depth !== 0) {
        throw new Error(`mirror-drift: unbalanced braces scanning from ${startRe}`);
    }
    return src.slice(braceIdx, i);
}

// Lines that are ALLOWED to differ between server.js and the test mirror,
// because they are real, deliberate divergences -- not drift:
//   - full-line comments and blank lines (prose, not behavior)
//   - console.log/console.error calls (server.js logs; the in-memory test
//     double intentionally does not)
//   - saveRegisteredTeams() (server.js persists to disk; the test double
//     has no file I/O by design -- see app-factory.js's own header comment)
// Anything else surviving this filter is asserted byte-identical (after
// whitespace/newline normalization) between the two copies.
const ALLOWED_DIVERGENT_LINES = new Set(['saveRegisteredTeams();']);

/**
 * Normalize an extracted block for cross-file comparison: drop comment-only
 * lines, blank lines, console.* calls, and the one documented persistence
 * divergence, then collapse all remaining whitespace (including newlines)
 * to single spaces so pure reformatting (e.g. an object literal collapsed
 * from multi-line to single-line) does not register as drift.
 *
 * @param {string} body
 * @returns {string}
 */
/**
 * Strip a TRAILING `//` comment from one line, but ONLY when the `//` is not
 * inside a string literal (XACA-1089-015).
 *
 * A naive `line.split('//')[0]` is actively harmful here, not merely
 * incomplete: `server.js`'s team-register handler contains
 *   fleetMonitorUrl: fleetMonitorUrl || 'http://localhost:3000',
 * INSIDE a guarded block. Naive stripping truncates that to `'http:` on both
 * sides -- which silently discards every character after it on that line,
 * so a real divergence later in the same line would stop being compared at
 * all. The guard would still pass, having compared less than it claims to.
 *
 * Known limitation, recorded rather than hidden: a `//` inside a REGEX
 * literal (e.g. `/a\/\/b/`) is not distinguished from a comment. No line in
 * either guarded block contains one today, and an empty regex `//` is not
 * valid JS, so the exposure is theoretical -- but if one is ever introduced,
 * this returns a shortened line for BOTH files identically, so it degrades to
 * the same "compares less than it claims" failure described above rather than
 * to a false alarm.
 *
 * @param {string} line
 * @returns {string}
 */
function stripInlineComment(line) {
    let quote = null;
    let escaped = false;
    for (let i = 0; i < line.length; i++) {
        const ch = line[i];
        if (escaped) { escaped = false; continue; }
        if (ch === '\\') { escaped = true; continue; }
        if (quote !== null) {
            if (ch === quote) quote = null;
            continue;
        }
        if (ch === '\'' || ch === '"' || ch === '`') { quote = ch; continue; }
        if (ch === '/' && line[i + 1] === '/') return line.slice(0, i).trim();
    }
    return line;
}

function normalizeBody(body) {
    const lines = body
        .split('\n')
        .map((l) => l.trim())
        // XACA-1089-015: strip inline trailing comments BEFORE the emptiness
        // filter, so a comment-only line collapses to '' and is dropped by the
        // length check below -- the previous `startsWith('//')` filter caught
        // only whole-line comments and left `foo(); // note` intact, which
        // would trip a false drift alarm if one copy carried the note.
        .map((l) => stripInlineComment(l))
        .filter((l) => l.length > 0)
        .filter((l) => !l.startsWith('console.'))
        .filter((l) => !ALLOWED_DIVERGENT_LINES.has(l));
    return lines.join(' ').replace(/\s+/g, ' ').trim();
}

module.exports = { extractBlock, normalizeBody, stripInlineComment, ALLOWED_DIVERGENT_LINES };
